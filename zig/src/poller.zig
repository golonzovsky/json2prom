const std = @import("std");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const jq = @import("jq.zig");

pub const Poller = struct {
    target: config.TargetConfig,
    registry: *metrics.MetricsRegistry,
    allocator: std.mem.Allocator,
    client: std.http.Client,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, target: config.TargetConfig, registry: *metrics.MetricsRegistry) Poller {
        return .{
            .target = target,
            .registry = registry,
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Poller) void {
        self.client.deinit();
    }

    pub fn start(self: *Poller) !void {
        self.running.store(true, .monotonic);
        const thread = try std.Thread.spawn(.{}, pollLoop, .{self});
        thread.detach();
    }

    pub fn stop(self: *Poller) void {
        self.running.store(false, .monotonic);
    }

    fn pollLoop(self: *Poller) void {
        std.log.info("Poll loop started for {s}", .{self.target.name});
        while (self.running.load(.monotonic)) {
            std.log.info("Polling {s}...", .{self.target.name});
            self.poll() catch |err| {
                std.log.err("Poll error for {s}: {}", .{ self.target.name, err });
            };

            std.time.sleep(self.target.periodSeconds * std.time.ns_per_s);
        }
        std.log.info("Poll loop ended for {s}", .{self.target.name});
    }

    fn poll(self: *Poller) !void {
        // Make HTTP request
        std.log.info("Parsing URI: {s}", .{self.target.uri});
        const uri = try std.Uri.parse(self.target.uri);
        
        std.log.info("Allocating server header buffer", .{});
        const server_header_buffer = try self.allocator.alloc(u8, 16 * 1024);
        defer self.allocator.free(server_header_buffer);

        std.log.info("Opening HTTP connection", .{});
        var req = try self.client.open(.GET, uri, .{
            .server_header_buffer = server_header_buffer,
        });
        defer req.deinit();

        std.log.info("Sending request", .{});
        try req.send();
        try req.finish();
        try req.wait();

        if (req.response.status != .ok) {
            return error.HttpError;
        }

        // Read response body
        const body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(body);

        // Process metrics
        for (self.target.metrics) |metric_config| {
            try self.processMetric(body, metric_config);
        }
    }

    pub fn processMetric(self: *Poller, json_data: []const u8, metric_config: config.MetricConfig) !void {
        var jq_proc = try jq.JqProcessor.init();
        defer jq_proc.deinit();

        // Get metric value
        try jq_proc.compile(metric_config.valueQuery);
        const value_str = try jq_proc.execute(self.allocator, json_data);
        defer self.allocator.free(value_str);

        const value = try std.fmt.parseFloat(f64, std.mem.trim(u8, value_str, "\" \n"));

        // Get labels
        var labels = std.ArrayList(metrics.Label).init(self.allocator);
        defer labels.deinit();

        for (metric_config.labels) |label_config| {
            var label_proc = try jq.JqProcessor.init();
            defer label_proc.deinit();

            try label_proc.compile(label_config.query);
            const label_value_raw = try label_proc.execute(self.allocator, json_data);
            defer self.allocator.free(label_value_raw);

            // Trim and duplicate the value so it's owned by the label
            const trimmed = std.mem.trim(u8, label_value_raw, "\" \n");
            const label_value = try self.allocator.dupe(u8, trimmed);

            try labels.append(.{
                .name = label_config.name,
                .value = label_value,
            });
        }

        // Update metric in registry
        const metric = metrics.Metric{
            .name = metric_config.name,
            .type = .gauge,
            .value = value,
            .labels = try labels.toOwnedSlice(),
            .help = null,
        };

        try self.registry.updateMetric(metric);
    }
};

test "Poller - processMetric with simple value" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const target = config.TargetConfig{
        .name = "test",
        .uri = "http://example.com",
        .method = "GET",
        .periodSeconds = 60,
        .metrics = &[_]config.MetricConfig{},
    };

    var poller = Poller.init(std.testing.allocator, target, &registry);
    defer poller.deinit();

    const json_data = 
        \\{"temperature": 25.5, "humidity": 60}
    ;

    const metric_config = config.MetricConfig{
        .name = "room_temperature",
        .valueQuery = ".temperature",
        .labels = &[_]config.LabelConfig{},
    };

    try poller.processMetric(json_data, metric_config);
    
    try std.testing.expectEqual(@as(usize, 1), registry.metrics.count());
}

test "Poller - processMetric with labels" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const target = config.TargetConfig{
        .name = "test",
        .uri = "http://example.com",
        .method = "GET",
        .periodSeconds = 60,
        .metrics = &[_]config.MetricConfig{},
    };

    var poller = Poller.init(std.testing.allocator, target, &registry);
    defer poller.deinit();

    const json_data = 
        \\{"sensor": {"location": "living_room", "type": "temp", "value": 22.3}}
    ;

    var label_configs = [_]config.LabelConfig{
        .{ .name = "location", .query = ".sensor.location" },
        .{ .name = "type", .query = ".sensor.type" },
    };

    const metric_config = config.MetricConfig{
        .name = "sensor_reading",
        .valueQuery = ".sensor.value",
        .labels = label_configs[0..],
    };

    try poller.processMetric(json_data, metric_config);
    
    try std.testing.expectEqual(@as(usize, 1), registry.metrics.count());
}

test "Poller - init and deinit" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const target = config.TargetConfig{
        .name = "test-target",
        .uri = "http://localhost:8080/metrics",
        .method = "GET",
        .periodSeconds = 30,
        .metrics = &[_]config.MetricConfig{},
    };

    var poller = Poller.init(std.testing.allocator, target, &registry);
    defer poller.deinit();

    try std.testing.expectEqual(false, poller.running.load(.monotonic));
    try std.testing.expectEqualStrings("test-target", poller.target.name);
}

test "Poller - processMetric with array data" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const target = config.TargetConfig{
        .name = "test",
        .uri = "http://example.com",
        .method = "GET",
        .periodSeconds = 60,
        .metrics = &[_]config.MetricConfig{},
    };

    var poller = Poller.init(std.testing.allocator, target, &registry);
    defer poller.deinit();

    const json_data = 
        \\{"metrics": [{"name": "cpu", "value": 45.2}, {"name": "memory", "value": 78.9}]}
    ;

    const metric_config = config.MetricConfig{
        .name = "system_metric",
        .valueQuery = ".metrics[0].value",
        .labels = &[_]config.LabelConfig{},
    };

    try poller.processMetric(json_data, metric_config);
    
    try std.testing.expectEqual(@as(usize, 1), registry.metrics.count());
}

test "Poller - processMetric with nested labels" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const target = config.TargetConfig{
        .name = "test",
        .uri = "http://example.com",
        .method = "GET",
        .periodSeconds = 60,
        .metrics = &[_]config.MetricConfig{},
    };

    var poller = Poller.init(std.testing.allocator, target, &registry);
    defer poller.deinit();

    const json_data = 
        \\{
        \\  "server": {
        \\    "name": "web-01",
        \\    "datacenter": "us-east",
        \\    "stats": {
        \\      "requests_per_second": 1523.7
        \\    }
        \\  }
        \\}
    ;

    var label_configs = [_]config.LabelConfig{
        .{ .name = "server", .query = ".server.name" },
        .{ .name = "dc", .query = ".server.datacenter" },
    };

    const metric_config = config.MetricConfig{
        .name = "http_rps",
        .valueQuery = ".server.stats.requests_per_second",
        .labels = label_configs[0..],
    };

    try poller.processMetric(json_data, metric_config);
    
    try std.testing.expectEqual(@as(usize, 1), registry.metrics.count());
}
