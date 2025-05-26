const std = @import("std");

pub const MetricType = enum {
    gauge,
    counter,
};

pub const Label = struct {
    name: []const u8,
    value: []const u8,
};

pub const Metric = struct {
    name: []const u8,
    type: MetricType,
    value: f64,
    labels: []Label,
    help: ?[]const u8,
};

pub const MetricsRegistry = struct {
    metrics: std.StringHashMap(Metric),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) MetricsRegistry {
        return .{
            .metrics = std.StringHashMap(Metric).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *MetricsRegistry) void {
        var it = self.metrics.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Free label values
            for (entry.value_ptr.labels) |label| {
                self.allocator.free(label.value);
            }
            if (entry.value_ptr.labels.len > 0) {
                self.allocator.free(entry.value_ptr.labels);
            }
        }
        self.metrics.deinit();
    }

    pub fn updateMetric(self: *MetricsRegistry, metric: Metric) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.generateKey(metric.name, metric.labels);
        
        // Check if we're updating an existing key
        const result = try self.metrics.getOrPut(key);
        if (result.found_existing) {
            // Key already exists, free the newly generated key
            self.allocator.free(key);
            
            // Free old metric's label values
            const old_metric = result.value_ptr.*;
            for (old_metric.labels) |label| {
                self.allocator.free(label.value);
            }
            if (old_metric.labels.len > 0) {
                self.allocator.free(old_metric.labels);
            }
        }
        // Update the value
        result.value_ptr.* = metric;
    }

    fn generateKey(self: *MetricsRegistry, name: []const u8, labels: []Label) ![]u8 {
        var key = std.ArrayList(u8).init(self.allocator);
        try key.appendSlice(name);

        for (labels) |label| {
            try key.append('_');
            try key.appendSlice(label.name);
            try key.append('=');
            try key.appendSlice(label.value);
        }

        return key.toOwnedSlice();
    }

    pub fn exportPrometheus(self: *MetricsRegistry, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.metrics.iterator();
        while (it.next()) |entry| {
            const metric = entry.value_ptr.*;

            // Write help text if available
            if (metric.help) |help| {
                try writer.print("# HELP {s} {s}\n", .{ metric.name, help });
            }

            // Write type
            const type_str = switch (metric.type) {
                .gauge => "gauge",
                .counter => "counter",
            };
            try writer.print("# TYPE {s} {s}\n", .{ metric.name, type_str });

            // Write metric value
            try writer.print("{s}", .{metric.name});

            if (metric.labels.len > 0) {
                try writer.writeAll("{");
                for (metric.labels, 0..) |label, i| {
                    if (i > 0) try writer.writeAll(",");
                    try writer.print("{s}=\"{s}\"", .{ label.name, label.value });
                }
                try writer.writeAll("}");
            }

            try writer.print(" {d}\n", .{metric.value});
        }
    }
};

test "MetricsRegistry - init and deinit" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();
    
    try std.testing.expectEqual(@as(usize, 0), registry.metrics.count());
}

test "MetricsRegistry - update single metric" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const metric = Metric{
        .name = "test_metric",
        .type = .gauge,
        .value = 42.0,
        .labels = &[_]Label{},
        .help = "Test metric",
    };

    try registry.updateMetric(metric);
    try std.testing.expectEqual(@as(usize, 1), registry.metrics.count());
}

test "MetricsRegistry - update metric with labels" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var labels = [_]Label{
        .{ .name = "method", .value = "GET" },
        .{ .name = "status", .value = "200" },
    };

    const metric = Metric{
        .name = "http_requests_total",
        .type = .counter,
        .value = 123.0,
        .labels = labels[0..],
        .help = "Total HTTP requests",
    };

    try registry.updateMetric(metric);
    try std.testing.expectEqual(@as(usize, 1), registry.metrics.count());
}

test "MetricsRegistry - export prometheus format" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Add a metric without labels
    const metric1 = Metric{
        .name = "simple_gauge",
        .type = .gauge,
        .value = 3.14,
        .labels = &[_]Label{},
        .help = "A simple gauge",
    };
    try registry.updateMetric(metric1);

    // Add a metric with labels
    var labels = [_]Label{
        .{ .name = "env", .value = "prod" },
    };
    const metric2 = Metric{
        .name = "labeled_counter",
        .type = .counter,
        .value = 99.0,
        .labels = labels[0..],
        .help = null,
    };
    try registry.updateMetric(metric2);

    // Export to buffer
    var buffer = std.ArrayList(u8).init(std.testing.allocator);
    defer buffer.deinit();

    try registry.exportPrometheus(buffer.writer());
    
    const output = buffer.items;
    
    // Check that output contains expected metric formats
    try std.testing.expect(std.mem.indexOf(u8, output, "# HELP simple_gauge A simple gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE simple_gauge gauge") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "simple_gauge 3.14") != null);
    
    try std.testing.expect(std.mem.indexOf(u8, output, "# TYPE labeled_counter counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "labeled_counter{env=\"prod\"} 99") != null);
}

test "MetricsRegistry - thread safety" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const ThreadContext = struct {
        registry: *MetricsRegistry,
        id: u32,

        fn worker(ctx: *@This()) !void {
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                const metric = Metric{
                    .name = "concurrent_metric",
                    .type = .counter,
                    .value = @floatFromInt(ctx.id * 100 + i),
                    .labels = &[_]Label{},
                    .help = null,
                };
                try ctx.registry.updateMetric(metric);
            }
        }
    };

    // Start multiple threads
    var threads: [4]std.Thread = undefined;
    var contexts: [4]ThreadContext = undefined;
    for (&threads, &contexts, 0..) |*thread, *ctx, i| {
        ctx.* = ThreadContext{
            .registry = &registry,
            .id = @intCast(i),
        };
        thread.* = try std.Thread.spawn(.{}, ThreadContext.worker, .{ctx});
    }

    // Wait for all threads
    for (threads) |thread| {
        thread.join();
    }

    // Should have at least one metric (last update wins due to same key)
    try std.testing.expect(registry.metrics.count() >= 1);
}

test "MetricsRegistry - multiple distinct metrics" {
    var registry = MetricsRegistry.init(std.testing.allocator);
    defer registry.deinit();

    // Different metric names
    const metrics = [_]Metric{
        .{
            .name = "cpu_usage",
            .type = .gauge,
            .value = 75.5,
            .labels = &[_]Label{},
            .help = null,
        },
        .{
            .name = "memory_usage",
            .type = .gauge,
            .value = 60.2,
            .labels = &[_]Label{},
            .help = null,
        },
        .{
            .name = "disk_usage",
            .type = .gauge,
            .value = 85.0,
            .labels = &[_]Label{},
            .help = null,
        },
    };

    for (metrics) |metric| {
        try registry.updateMetric(metric);
    }

    try std.testing.expectEqual(@as(usize, 3), registry.metrics.count());
}
