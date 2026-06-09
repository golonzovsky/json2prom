const std = @import("std");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const jq = @import("jq.zig");

const http_timeout_seconds = 10;

pub const CompiledMetric = struct {
    name: []const u8,
    items_query: jq.Query,
    value_query: jq.Query,
    label_queries: []jq.Query,
    gauge: *metrics.Gauge,

    pub fn compile(allocator: std.mem.Allocator, registry: *metrics.Registry, mc: config.MetricConfig) !CompiledMetric {
        var items_query = jq.Query.compile(mc.itemsQuery) catch |err| {
            config.logError("metric {s}: invalid itemsQuery '{s}'", .{ mc.name, mc.itemsQuery });
            return err;
        };
        errdefer items_query.deinit();
        var value_query = jq.Query.compile(mc.valueQuery) catch |err| {
            config.logError("metric {s}: invalid valueQuery '{s}'", .{ mc.name, mc.valueQuery });
            return err;
        };
        errdefer value_query.deinit();

        var label_queries: std.ArrayList(jq.Query) = .empty;
        errdefer {
            for (label_queries.items) |*q| q.deinit();
            label_queries.deinit(allocator);
        }
        const label_names = try allocator.alloc([]const u8, mc.labels.len + 1);
        defer allocator.free(label_names);
        label_names[0] = "target";
        for (mc.labels, label_names[1..]) |label, *label_name| {
            label_name.* = label.name;
            const q = jq.Query.compile(label.query) catch |err| {
                config.logError("metric {s}: invalid label query '{s}'", .{ mc.name, label.query });
                return err;
            };
            try label_queries.append(allocator, q);
        }

        const gauge = try registry.gauge(mc.name, label_names);
        return .{
            .name = mc.name,
            .items_query = items_query,
            .value_query = value_query,
            .label_queries = try label_queries.toOwnedSlice(allocator),
            .gauge = gauge,
        };
    }

    pub fn deinit(self: *CompiledMetric, allocator: std.mem.Allocator) void {
        self.items_query.deinit();
        self.value_query.deinit();
        for (self.label_queries) |*q| q.deinit();
        allocator.free(self.label_queries);
    }
};

pub fn evaluateMetric(allocator: std.mem.Allocator, target_name: []const u8, cm: *CompiledMetric, root: jq.c.jv) !void {
    cm.gauge.reset();

    const items = try cm.items_query.exec(allocator, root);
    defer jq.freeResults(allocator, items);

    for (items) |item| {
        const values = try cm.value_query.exec(allocator, item);
        defer jq.freeResults(allocator, values);
        if (values.len == 0) {
            std.log.warn("[{s}] metric {s}: valueQuery returned no result, skipping item", .{ target_name, cm.name });
            continue;
        }
        const value = jq.toNumber(values[0]) orelse {
            const text = try jq.toLabelString(allocator, values[0]);
            defer allocator.free(text);
            std.log.warn("[{s}] metric {s}: value is not a number or boolean ({s}: {s}), skipping item", .{ target_name, cm.name, jq.kindName(values[0]), text });
            continue;
        };

        const label_values = try allocator.alloc([]const u8, cm.label_queries.len + 1);
        var owned: usize = 1;
        defer {
            for (label_values[1..owned]) |v| allocator.free(v);
            allocator.free(label_values);
        }
        label_values[0] = target_name;
        for (cm.label_queries, label_values[1..]) |*query, *out| {
            const results = try query.exec(allocator, item);
            defer jq.freeResults(allocator, results);
            out.* = if (results.len > 0)
                try jq.toLabelString(allocator, results[0])
            else
                try allocator.dupe(u8, "");
            owned += 1;
        }

        try cm.gauge.set(label_values, value);
    }
}

pub fn urlEncode(allocator: std.mem.Allocator, params: []const config.Param) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    for (params, 0..) |param, i| {
        if (i > 0) try aw.writer.writeByte('&');
        try writeUrlEncoded(&aw.writer, param.name);
        try aw.writer.writeByte('=');
        try writeUrlEncoded(&aw.writer, param.value);
    }
    return aw.toOwnedSlice();
}

fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try w.writeByte(byte),
        else => try w.print("%{X:0>2}", .{byte}),
    };
}

pub const Poller = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    target: config.TargetConfig,
    client: std.http.Client,
    compiled: []CompiledMetric,
    extra_headers: []std.http.Header,
    auth_header: ?[]u8,
    form_body: ?[]u8,
    running: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, target: config.TargetConfig, registry: *metrics.Registry) !Poller {
        var compiled: std.ArrayList(CompiledMetric) = .empty;
        errdefer {
            for (compiled.items) |*cm| cm.deinit(allocator);
            compiled.deinit(allocator);
        }
        for (target.metrics) |mc| {
            try compiled.append(allocator, try CompiledMetric.compile(allocator, registry, mc));
        }

        const extra_headers = try allocator.alloc(std.http.Header, target.headers.len);
        errdefer allocator.free(extra_headers);
        for (target.headers, extra_headers) |header, *out| {
            out.* = .{ .name = header.name, .value = header.value };
        }

        const auth_header = if (target.bearerToken) |token|
            try std.fmt.allocPrint(allocator, "Bearer {s}", .{token})
        else
            null;
        errdefer if (auth_header) |h| allocator.free(h);

        const form_body = if (target.formParams.len > 0)
            try urlEncode(allocator, target.formParams)
        else
            null;
        errdefer if (form_body) |b| allocator.free(b);

        return .{
            .allocator = allocator,
            .io = io,
            .target = target,
            .client = .{ .allocator = allocator, .io = io },
            .compiled = try compiled.toOwnedSlice(allocator),
            .extra_headers = extra_headers,
            .auth_header = auth_header,
            .form_body = form_body,
        };
    }

    pub fn deinit(self: *Poller) void {
        self.stop();
        self.client.deinit();
        for (self.compiled) |*cm| cm.deinit(self.allocator);
        self.allocator.free(self.compiled);
        self.allocator.free(self.extra_headers);
        if (self.auth_header) |h| self.allocator.free(h);
        if (self.form_body) |b| self.allocator.free(b);
    }

    pub fn start(self: *Poller) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, pollLoop, .{self});
    }

    pub fn stop(self: *Poller) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn pollLoop(self: *Poller) void {
        while (self.running.load(.acquire)) {
            self.scrape();

            var remaining_ms: u64 = @as(u64, self.target.periodSeconds) * 1000;
            while (remaining_ms > 0 and self.running.load(.acquire)) {
                const chunk = @min(remaining_ms, 250);
                self.io.sleep(.fromMilliseconds(@intCast(chunk)), .awake) catch {};
                remaining_ms -= chunk;
            }
        }
    }

    fn scrape(self: *Poller) void {
        self.scrapeInner() catch |err| {
            std.log.err("[{s}] scrape failed: {t}", .{ self.target.name, err });
        };
    }

    fn scrapeInner(self: *Poller) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();

        const result = try self.fetchWithTimeout(&aw.writer);
        if (result.status.class() != .success) {
            std.log.err("[{s}] HTTP {d} from {s}, skipping cycle", .{ self.target.name, @intFromEnum(result.status), self.target.uri });
            return;
        }

        const root = jq.parseJson(aw.written()) catch {
            std.log.err("[{s}] response is not valid JSON, skipping cycle", .{self.target.name});
            return;
        };
        defer jq.c.jv_free(root);

        for (self.compiled) |*cm| {
            try evaluateMetric(self.allocator, self.target.name, cm, root);
        }
    }

    // std.http.Client has no timeout option, so race the fetch against a deadline and cancel it.
    fn fetchWithTimeout(self: *Poller, response_writer: *std.Io.Writer) !std.http.Client.FetchResult {
        var done: std.Io.Event = .unset;
        var future = try self.io.concurrent(doFetch, .{ self, response_writer, &done });
        const deadline: std.Io.Clock.Timestamp = .fromNow(self.io, .{ .raw = .fromSeconds(http_timeout_seconds), .clock = .awake });
        while (true) {
            done.waitTimeout(self.io, .{ .deadline = deadline }) catch |err| {
                // waitTimeout reports spurious wakeups as Timeout; only trust it past the deadline
                if (err == error.Timeout and std.Io.Clock.Timestamp.now(self.io, .awake).compare(.lt, deadline)) continue;
                if (future.cancel(self.io)) |_| {} else |_| {}
                return err;
            };
            return future.await(self.io);
        }
    }

    fn doFetch(self: *Poller, response_writer: *std.Io.Writer, done: *std.Io.Event) std.http.Client.FetchError!std.http.Client.FetchResult {
        defer done.set(self.io);
        return self.client.fetch(.{
            .location = .{ .url = self.target.uri },
            .method = switch (self.target.method) {
                .GET => .GET,
                .POST => .POST,
                .PUT => .PUT,
                .DELETE => .DELETE,
            },
            .payload = self.form_body,
            .extra_headers = self.extra_headers,
            .headers = .{
                .authorization = if (self.auth_header) |h| .{ .override = h } else .default,
                .content_type = if (self.form_body != null) .{ .override = "application/x-www-form-urlencoded" } else .default,
            },
            .response_writer = response_writer,
        });
    }
};

const TestContext = struct {
    registry: metrics.Registry,
    compiled: CompiledMetric,

    fn init(mc: config.MetricConfig) !TestContext {
        var ctx: TestContext = .{
            .registry = metrics.Registry.init(std.testing.allocator, std.testing.io),
            .compiled = undefined,
        };
        errdefer ctx.registry.deinit();
        ctx.compiled = try CompiledMetric.compile(std.testing.allocator, &ctx.registry, mc);
        return ctx;
    }

    fn evaluate(self: *TestContext, json: []const u8) !void {
        const root = try jq.parseJson(json);
        defer jq.c.jv_free(root);
        try evaluateMetric(std.testing.allocator, "test-target", &self.compiled, root);
    }

    fn render(self: *TestContext) ![]u8 {
        var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer aw.deinit();
        try self.registry.render(&aw.writer);
        return aw.toOwnedSlice();
    }

    fn deinit(self: *TestContext) void {
        self.compiled.deinit(std.testing.allocator);
        self.registry.deinit();
    }
};

test "single item with labels, target label first" {
    var ctx = try TestContext.init(.{
        .name = "evo_percentage",
        .valueQuery = ".percentageUsed",
        .labels = &.{
            .{ .name = "name", .query = ".name" },
            .{ .name = "max_capacity", .query = ".max_capacity" },
        },
    });
    defer ctx.deinit();

    try ctx.evaluate(
        \\{"percentageUsed": 42.5, "name": "Enge", "max_capacity": 80}
    );

    const out = try ctx.render();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\evo_percentage{target="test-target",name="Enge",max_capacity="80"} 42.5
    ) != null);
}

test "itemsQuery iterates multiple results" {
    var ctx = try TestContext.init(.{
        .name = "river_temp",
        .itemsQuery = ".payload[]",
        .valueQuery = ".val",
        .labels = &.{.{ .name = "station", .query = ".loc" }},
    });
    defer ctx.deinit();

    try ctx.evaluate(
        \\{"payload": [{"val": 10.5, "loc": "2243"}, {"val": 11.25, "loc": "2244"}]}
    );

    const out = try ctx.render();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\river_temp{target="test-target",station="2243"} 10.5
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out,
        \\river_temp{target="test-target",station="2244"} 11.25
    ) != null);
}

test "non-numeric values skip the item, booleans convert" {
    var ctx = try TestContext.init(.{
        .name = "m",
        .itemsQuery = ".[]",
        .valueQuery = ".v",
        .labels = &.{.{ .name = "id", .query = ".id" }},
    });
    defer ctx.deinit();

    try ctx.evaluate(
        \\[
        \\  {"id": "num", "v": 7},
        \\  {"id": "yes", "v": true},
        \\  {"id": "no", "v": false},
        \\  {"id": "null", "v": null},
        \\  {"id": "str", "v": "nope"},
        \\  {"id": "missing"}
        \\]
    );

    const out = try ctx.render();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "m{target=\"test-target\",id=\"num\"} 7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "m{target=\"test-target\",id=\"yes\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "m{target=\"test-target\",id=\"no\"} 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"null\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"str\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"missing\"") == null);
}

test "missing label result becomes empty string" {
    var ctx = try TestContext.init(.{
        .name = "m",
        .valueQuery = ".v",
        .labels = &.{.{ .name = "gone", .query = ".does | select(. != null)" }},
    });
    defer ctx.deinit();

    try ctx.evaluate("{\"v\": 1}");

    const out = try ctx.render();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "m{target=\"test-target\",gone=\"\"} 1") != null);
}

test "re-scrape replaces previous series" {
    var ctx = try TestContext.init(.{
        .name = "m",
        .itemsQuery = ".[]",
        .valueQuery = ".v",
        .labels = &.{.{ .name = "id", .query = ".id" }},
    });
    defer ctx.deinit();

    try ctx.evaluate(
        \\[{"id": "a", "v": 1}, {"id": "b", "v": 2}]
    );
    try ctx.evaluate(
        \\[{"id": "b", "v": 3}]
    );

    const out = try ctx.render();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"a\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "m{target=\"test-target\",id=\"b\"} 3") != null);
    try std.testing.expectEqual(@as(usize, 1), ctx.compiled.gauge.series.items.len);
}

test "default itemsQuery uses root" {
    var ctx = try TestContext.init(.{
        .name = "m",
        .valueQuery = ".count",
    });
    defer ctx.deinit();

    try ctx.evaluate("{\"count\": 9}");

    const out = try ctx.render();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "m{target=\"test-target\"} 9") != null);
}

test "compile fails fast on bad query" {
    var registry = metrics.Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    try std.testing.expectError(error.CompileError, CompiledMetric.compile(std.testing.allocator, &registry, .{
        .name = "m",
        .valueQuery = ".[",
    }));
}

test "urlEncode" {
    const encoded = try urlEncode(std.testing.allocator, &.{
        .{ .name = "grant_type", .value = "client credentials" },
        .{ .name = "scope", .value = "a&b=c" },
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("grant_type=client%20credentials&scope=a%26b%3Dc", encoded);
}
