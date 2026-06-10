const std = @import("std");
const builtin = @import("builtin");
const yaml = @import("yaml");

pub const Method = enum { GET, POST, PUT, DELETE };

pub const LabelConfig = struct {
    name: []const u8,
    query: []const u8,
};

pub const MetricConfig = struct {
    name: []const u8,
    items_query: []const u8 = ".",
    value_query: []const u8,
    labels: []const LabelConfig = &.{},
};

pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

pub const TargetConfig = struct {
    name: []const u8,
    uri: []const u8,
    method: Method = .GET,
    use_bearer_token_from: ?[]const u8 = null,
    bearer_token: ?[]const u8 = null,
    headers: []const Param = &.{},
    form_params: []const Param = &.{},
    period_seconds: u32,
    metrics: []const MetricConfig,
};

pub const Config = struct {
    targets: []TargetConfig,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub const Error = error{InvalidConfig} || std.mem.Allocator.Error;

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) Error!Config {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| {
        logError("cannot read config file {s}: {t}", .{ path, err });
        return error.InvalidConfig;
    };
    defer allocator.free(source);
    return parse(allocator, source);
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var doc: yaml.Yaml = .{ .source = source };
    defer doc.deinit(allocator);
    doc.load(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            logError("invalid YAML: {t}", .{err});
            return error.InvalidConfig;
        },
    };

    if (doc.docs.items.len == 0) return fail("empty config document", .{});
    const root = doc.docs.items[0].asMap() orelse return fail("config root must be a map", .{});
    const targets_node = root.get("targets") orelse return fail("missing 'targets'", .{});
    const targets_list = targets_node.asList() orelse return fail("'targets' must be a list", .{});

    var targets: std.ArrayList(TargetConfig) = .empty;
    for (targets_list) |node| {
        try targets.append(aa, try parseTarget(aa, node));
    }

    return .{ .targets = try targets.toOwnedSlice(aa), .arena = arena };
}

fn parseTarget(aa: std.mem.Allocator, node: yaml.Yaml.Value) Error!TargetConfig {
    const map = node.asMap() orelse return fail("target must be a map", .{});
    const name = try requiredString(aa, map, "name", "target");

    var target: TargetConfig = .{
        .name = name,
        .uri = try requiredString(aa, map, "uri", name),
        .period_seconds = undefined,
        .metrics = undefined,
    };

    if (try optionalString(aa, map, "method", name)) |m| {
        target.method = std.meta.stringToEnum(Method, m) orelse
            return fail("target {s}: invalid method '{s}' (want GET/POST/PUT/DELETE)", .{ name, m });
    }
    target.use_bearer_token_from = try optionalString(aa, map, "useBearerTokenFrom", name);
    target.headers = try parseParams(aa, map, "headers", name);
    target.form_params = try parseParams(aa, map, "formParams", name);

    const period_str = try requiredString(aa, map, "periodSeconds", name);
    const period = std.fmt.parseInt(i64, period_str, 10) catch
        return fail("target {s}: periodSeconds must be an integer, got '{s}'", .{ name, period_str });
    if (period <= 0) return fail("target {s}: periodSeconds must be > 0, got {d}", .{ name, period });
    target.period_seconds = std.math.cast(u32, period) orelse
        return fail("target {s}: periodSeconds too large", .{name});

    const metrics_node = map.get("metrics") orelse return fail("target {s}: missing 'metrics'", .{name});
    const metrics_list = metrics_node.asList() orelse return fail("target {s}: 'metrics' must be a list", .{name});
    var metrics: std.ArrayList(MetricConfig) = .empty;
    for (metrics_list) |metric_node| {
        try metrics.append(aa, try parseMetric(aa, metric_node, name));
    }
    target.metrics = try metrics.toOwnedSlice(aa);

    return target;
}

fn parseMetric(aa: std.mem.Allocator, node: yaml.Yaml.Value, target_name: []const u8) Error!MetricConfig {
    const map = node.asMap() orelse return fail("target {s}: metric must be a map", .{target_name});
    const name = try requiredString(aa, map, "name", target_name);

    var metric: MetricConfig = .{
        .name = name,
        .value_query = try requiredString(aa, map, "valueQuery", name),
    };
    if (try optionalString(aa, map, "itemsQuery", name)) |q| metric.items_query = q;

    if (map.get("labels")) |labels_node| {
        const labels_list = labels_node.asList() orelse return fail("metric {s}: 'labels' must be a list", .{name});
        var labels: std.ArrayList(LabelConfig) = .empty;
        for (labels_list) |label_node| {
            const label_map = label_node.asMap() orelse return fail("metric {s}: label must be a map", .{name});
            try labels.append(aa, .{
                .name = try requiredString(aa, label_map, "name", name),
                .query = try requiredString(aa, label_map, "query", name),
            });
        }
        metric.labels = try labels.toOwnedSlice(aa);
    }

    return metric;
}

fn parseParams(aa: std.mem.Allocator, map: yaml.Yaml.Map, key: []const u8, target_name: []const u8) Error![]Param {
    const node = map.get(key) orelse return &.{};
    const param_map = node.asMap() orelse return fail("target {s}: '{s}' must be a map", .{ target_name, key });

    var params: std.ArrayList(Param) = .empty;
    for (param_map.keys(), param_map.values()) |k, v| {
        const value = v.asScalar() orelse
            return fail("target {s}: {s}.{s} must be a string", .{ target_name, key, k });
        try params.append(aa, .{
            .name = try aa.dupe(u8, k),
            .value = try aa.dupe(u8, value),
        });
    }
    return params.toOwnedSlice(aa);
}

fn requiredString(aa: std.mem.Allocator, map: yaml.Yaml.Map, key: []const u8, context: []const u8) Error![]u8 {
    return try optionalString(aa, map, key, context) orelse
        fail("{s}: missing required field '{s}'", .{ context, key });
}

fn optionalString(aa: std.mem.Allocator, map: yaml.Yaml.Map, key: []const u8, context: []const u8) Error!?[]u8 {
    const node = map.get(key) orelse return null;
    const scalar = node.asScalar() orelse return fail("{s}: '{s}' must be a scalar", .{ context, key });
    return try aa.dupe(u8, scalar);
}

fn fail(comptime fmt: []const u8, args: anytype) error{InvalidConfig} {
    logError("config: " ++ fmt, args);
    return error.InvalidConfig;
}

// The test runner fails any test that logs at error level.
pub fn logError(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) std.log.warn(fmt, args) else std.log.err(fmt, args);
}

/// `env` needs a `get([]const u8) ?[]const u8` method; pass `init.environ_map`.
pub fn resolveBearerTokens(targets: []TargetConfig, env: anytype) error{MissingBearerToken}!void {
    for (targets) |*target| {
        const env_name = target.use_bearer_token_from orelse continue;
        const token = env.get(env_name) orelse "";
        if (token.len == 0) {
            logError("config: target {s}: useBearerTokenFrom is set but environment variable {s} is missing or empty", .{ target.name, env_name });
            return error.MissingBearerToken;
        }
        target.bearer_token = token;
    }
}

test "full config with all fields" {
    const source =
        \\targets:
        \\  - name: test-target
        \\    uri: https://example.com/api
        \\    method: POST
        \\    useBearerTokenFrom: MY_TOKEN
        \\    headers:
        \\      X-Custom: abc
        \\      X-Other: def
        \\    formParams:
        \\      grant_type: client_credentials
        \\    periodSeconds: 30
        \\    metrics:
        \\      - name: test_metric
        \\        itemsQuery: .items[]
        \\        valueQuery: .value
        \\        labels:
        \\          - name: label1
        \\            query: .label1
        \\          - name: label2
        \\            query: .label2
    ;

    var cfg = try parse(std.testing.allocator, source);
    defer cfg.deinit();

    try std.testing.expectEqual(1, cfg.targets.len);
    const target = cfg.targets[0];
    try std.testing.expectEqualStrings("test-target", target.name);
    try std.testing.expectEqualStrings("https://example.com/api", target.uri);
    try std.testing.expectEqual(Method.POST, target.method);
    try std.testing.expectEqualStrings("MY_TOKEN", target.use_bearer_token_from.?);
    try std.testing.expectEqual(30, target.period_seconds);

    try std.testing.expectEqual(2, target.headers.len);
    try std.testing.expectEqualStrings("X-Custom", target.headers[0].name);
    try std.testing.expectEqualStrings("abc", target.headers[0].value);
    try std.testing.expectEqual(1, target.form_params.len);
    try std.testing.expectEqualStrings("grant_type", target.form_params[0].name);

    const metric = target.metrics[0];
    try std.testing.expectEqualStrings("test_metric", metric.name);
    try std.testing.expectEqualStrings(".items[]", metric.items_query);
    try std.testing.expectEqualStrings(".value", metric.value_query);
    try std.testing.expectEqual(2, metric.labels.len);
    try std.testing.expectEqualStrings("label1", metric.labels[0].name);
    try std.testing.expectEqualStrings(".label1", metric.labels[0].query);
}

test "defaults for optional fields" {
    const source =
        \\targets:
        \\  - name: minimal
        \\    uri: https://example.com
        \\    periodSeconds: 10
        \\    metrics:
        \\      - name: simple_metric
        \\        valueQuery: .count
    ;

    var cfg = try parse(std.testing.allocator, source);
    defer cfg.deinit();

    const target = cfg.targets[0];
    try std.testing.expectEqual(Method.GET, target.method);
    try std.testing.expectEqual(null, target.use_bearer_token_from);
    try std.testing.expectEqual(0, target.headers.len);
    try std.testing.expectEqual(0, target.form_params.len);

    const metric = target.metrics[0];
    try std.testing.expectEqualStrings(".", metric.items_query);
    try std.testing.expectEqual(0, metric.labels.len);
}

test "multiple targets" {
    const source =
        \\targets:
        \\  - name: target1
        \\    uri: https://api1.com
        \\    periodSeconds: 60
        \\    metrics:
        \\      - name: metric1
        \\        valueQuery: .val
        \\  - name: target2
        \\    uri: https://api2.com
        \\    method: POST
        \\    periodSeconds: 120
        \\    metrics:
        \\      - name: metric2
        \\        valueQuery: .data
    ;

    var cfg = try parse(std.testing.allocator, source);
    defer cfg.deinit();

    try std.testing.expectEqual(2, cfg.targets.len);
    try std.testing.expectEqualStrings("target1", cfg.targets[0].name);
    try std.testing.expectEqual(60, cfg.targets[0].period_seconds);
    try std.testing.expectEqualStrings("target2", cfg.targets[1].name);
    try std.testing.expectEqual(Method.POST, cfg.targets[1].method);
}

test "missing required fields" {
    const cases = [_][]const u8{
        // missing name
        \\targets:
        \\  - uri: https://example.com
        \\    periodSeconds: 10
        \\    metrics:
        \\      - name: m
        \\        valueQuery: .v
        ,
        // missing uri
        \\targets:
        \\  - name: t
        \\    periodSeconds: 10
        \\    metrics:
        \\      - name: m
        \\        valueQuery: .v
        ,
        // missing periodSeconds
        \\targets:
        \\  - name: t
        \\    uri: https://example.com
        \\    metrics:
        \\      - name: m
        \\        valueQuery: .v
        ,
        // missing valueQuery
        \\targets:
        \\  - name: t
        \\    uri: https://example.com
        \\    periodSeconds: 10
        \\    metrics:
        \\      - name: m
        ,
        // missing metrics
        \\targets:
        \\  - name: t
        \\    uri: https://example.com
        \\    periodSeconds: 10
        ,
    };
    for (cases) |source| {
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, source));
    }
}

test "periodSeconds must be positive" {
    const cases = [_][]const u8{ "0", "-5", "abc" };
    for (cases) |period| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            \\targets:
            \\  - name: t
            \\    uri: https://example.com
            \\    periodSeconds: {s}
            \\    metrics:
            \\      - name: m
            \\        valueQuery: .v
        , .{period});
        defer std.testing.allocator.free(source);
        try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, source));
    }
}

test "invalid method rejected" {
    const source =
        \\targets:
        \\  - name: t
        \\    uri: https://example.com
        \\    method: PATCH
        \\    periodSeconds: 10
        \\    metrics:
        \\      - name: m
        \\        valueQuery: .v
    ;
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, source));
}

const FakeEnv = struct {
    name: []const u8,
    value: []const u8,

    fn get(self: @This(), key: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, key, self.name)) self.value else null;
    }
};

test "bearer token resolution" {
    var targets = [_]TargetConfig{.{
        .name = "t",
        .uri = "https://example.com",
        .use_bearer_token_from = "MY_TOKEN",
        .period_seconds = 10,
        .metrics = &.{},
    }};

    try resolveBearerTokens(&targets, FakeEnv{ .name = "MY_TOKEN", .value = "s3cret" });
    try std.testing.expectEqualStrings("s3cret", targets[0].bearer_token.?);

    targets[0].bearer_token = null;
    try std.testing.expectError(
        error.MissingBearerToken,
        resolveBearerTokens(&targets, FakeEnv{ .name = "OTHER", .value = "x" }),
    );
    try std.testing.expectError(
        error.MissingBearerToken,
        resolveBearerTokens(&targets, FakeEnv{ .name = "MY_TOKEN", .value = "" }),
    );
}

test "no bearer config needs no env" {
    var targets = [_]TargetConfig{.{
        .name = "t",
        .uri = "https://example.com",
        .period_seconds = 10,
        .metrics = &.{},
    }};
    try resolveBearerTokens(&targets, FakeEnv{ .name = "X", .value = "y" });
    try std.testing.expectEqual(null, targets[0].bearer_token);
}
