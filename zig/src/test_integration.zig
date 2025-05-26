const std = @import("std");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const poller = @import("poller.zig");
const jq = @import("jq.zig");

test "Integration - full pipeline from config to metrics" {
    const test_yaml =
        \\targets:
        \\  - name: integration-test
        \\    uri: http://example.com/api
        \\    method: GET
        \\    periodSeconds: 30
        \\    metrics:
        \\      - name: test_gauge
        \\        valueQuery: .value
        \\        labels:
        \\          - name: status
        \\            query: .status
    ;

    // Write test config file
    const test_file = "test_integration.yaml";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer {
        file.close();
        std.fs.cwd().deleteFile(test_file) catch {};
    }
    try file.writeAll(test_yaml);

    // Load config
    var cfg = try config.loadConfig(std.testing.allocator, test_file);
    defer cfg.deinit();

    // Initialize registry
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Test JSON response
    const json_response = 
        \\{"value": 42.5, "status": "healthy"}
    ;

    // Create poller and process the metric
    var p = poller.Poller.init(std.testing.allocator, cfg.targets[0], &registry);
    defer p.deinit();

    try p.processMetric(json_response, cfg.targets[0].metrics[0]);

    // Verify metric was created
    try std.testing.expectEqual(@as(usize, 1), registry.metrics.count());

    // Export and verify Prometheus format
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try registry.exportPrometheus(buffer.writer());
    const output = buffer.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "test_gauge{status=\"healthy\"} 42.5") != null);
}

test "Integration - multiple metrics from single response" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const json_response = 
        \\{
        \\  "server": "web-01",
        \\  "metrics": {
        \\    "cpu": 65.3,
        \\    "memory": 78.2,
        \\    "disk": 45.0
        \\  }
        \\}
    ;

    var label_configs = [_]config.LabelConfig{
        .{ .name = "server", .query = ".server" },
    };

    var metric_configs = [_]config.MetricConfig{
        .{
            .name = "system_cpu",
            .valueQuery = ".metrics.cpu",
            .labels = label_configs[0..],
        },
        .{
            .name = "system_memory",
            .valueQuery = ".metrics.memory",
            .labels = label_configs[0..],
        },
        .{
            .name = "system_disk",
            .valueQuery = ".metrics.disk",
            .labels = label_configs[0..],
        },
    };

    const target = config.TargetConfig{
        .name = "system-metrics",
        .uri = "http://localhost:9100/metrics",
        .method = "GET",
        .periodSeconds = 60,
        .metrics = metric_configs[0..],
    };

    var p = poller.Poller.init(std.testing.allocator, target, &registry);
    defer p.deinit();

    // Process all metrics
    for (metric_configs) |metric_config| {
        try p.processMetric(json_response, metric_config);
    }

    // Should have 3 metrics
    try std.testing.expectEqual(@as(usize, 3), registry.metrics.count());

    // Export and verify
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try registry.exportPrometheus(buffer.writer());
    const output = buffer.items;

    try std.testing.expect(std.mem.indexOf(u8, output, "system_cpu{server=\"web-01\"} 65.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "system_memory{server=\"web-01\"} 78.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "system_disk{server=\"web-01\"} 45") != null);
}

test "Integration - JQ complex queries" {
    var proc = try jq.JqProcessor.init();
    defer proc.deinit();

    const complex_json = 
        \\{
        \\  "results": [
        \\    {"name": "a", "value": 10},
        \\    {"name": "b", "value": 20},
        \\    {"name": "c", "value": 30}
        \\  ],
        \\  "metadata": {
        \\    "total": 60,
        \\    "average": 20
        \\  }
        \\}
    ;

    // Test array filtering
    try proc.compile(".results[] | select(.value > 15) | .value");
    const result1 = try proc.execute(std.testing.allocator, complex_json);
    defer std.testing.allocator.free(result1);
    try std.testing.expect(std.mem.indexOf(u8, result1, "20") != null);
    try std.testing.expect(std.mem.indexOf(u8, result1, "30") != null);

    // Test calculated value
    var proc2 = try jq.JqProcessor.init();
    defer proc2.deinit();
    try proc2.compile(".metadata.total / .metadata.average");
    const result2 = try proc2.execute(std.testing.allocator, complex_json);
    defer std.testing.allocator.free(result2);
    try std.testing.expectEqualStrings("3", result2);
}

test "Integration - error handling" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const target = config.TargetConfig{
        .name = "test",
        .uri = "http://example.com",
        .method = "GET",
        .periodSeconds = 60,
        .metrics = &[_]config.MetricConfig{},
    };

    var p = poller.Poller.init(std.testing.allocator, target, &registry);
    defer p.deinit();

    // Test with invalid JSON
    const invalid_json = "not valid json";
    const metric_config = config.MetricConfig{
        .name = "test_metric",
        .valueQuery = ".value",
        .labels = &[_]config.LabelConfig{},
    };

    const result = p.processMetric(invalid_json, metric_config);
    try std.testing.expectError(jq.JqError.InvalidJson, result);

    // Registry should still be empty
    try std.testing.expectEqual(@as(usize, 0), registry.metrics.count());
}

test "Integration - concurrent metric updates" {
    var registry = metrics.MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const ThreadContext = struct {
        registry: *metrics.MetricsRegistry,
        thread_id: u32,

        fn worker(ctx: @This()) !void {
            const json_data = try std.fmt.allocPrint(
                std.testing.allocator,
                \\{{"thread_id": {d}, "value": {d}}}
            ,
                .{ ctx.thread_id, ctx.thread_id * 10 },
            );
            defer std.testing.allocator.free(json_data);

            var label_configs = [_]config.LabelConfig{
                .{ .name = "thread", .query = ".thread_id" },
            };

            const metric_config = config.MetricConfig{
                .name = "concurrent_test",
                .valueQuery = ".value",
                .labels = label_configs[0..],
            };

            const target = config.TargetConfig{
                .name = "test",
                .uri = "http://example.com",
                .method = "GET",
                .periodSeconds = 60,
                .metrics = &[_]config.MetricConfig{},
            };

            var p = poller.Poller.init(std.testing.allocator, target, ctx.registry);
            defer p.deinit();

            try p.processMetric(json_data, metric_config);
        }
    };

    // Start multiple threads
    var threads: [5]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| {
        const ctx = ThreadContext{
            .registry = &registry,
            .thread_id = @intCast(i),
        };
        thread.* = try std.Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Should have 5 different metrics (one per thread)
    try std.testing.expectEqual(@as(usize, 5), registry.metrics.count());
}