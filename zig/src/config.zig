const std = @import("std");
const yaml = @import("yaml");

pub const MetricConfig = struct {
    name: []const u8,
    valueQuery: []const u8,
    labels: []LabelConfig,
};

pub const LabelConfig = struct {
    name: []const u8,
    query: []const u8,
};

pub const TargetConfig = struct {
    name: []const u8,
    uri: []const u8,
    method: []const u8,
    periodSeconds: u32,
    metrics: []MetricConfig,
};

pub const Config = struct {
    targets: []TargetConfig,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Create an arena allocator for all config allocations
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_allocator = arena.allocator();

    const content = try file.readToEndAlloc(arena_allocator, 1024 * 1024);

    var parsed = yaml.Yaml{ .source = content };
    defer parsed.deinit(arena_allocator);

    try parsed.load(arena_allocator);

    // Parse YAML into Config struct using the arena allocator
    const targets = try parseYamlToConfig(arena_allocator, &parsed);

    return Config{
        .targets = targets,
        .arena = arena,
    };
}

fn parseYamlToConfig(allocator: std.mem.Allocator, doc: *yaml.Yaml) ![]TargetConfig {
    if (doc.docs.items.len == 0) return error.NoDocument;

    const root = doc.docs.items[0];
    const targets_node = root.map.get("targets") orelse return error.NoTargets;

    var targets = std.ArrayList(TargetConfig).init(allocator);

    for (targets_node.list) |target_node| {
        const name = try allocator.dupe(u8, target_node.map.get("name").?.string);
        const uri = try allocator.dupe(u8, target_node.map.get("uri").?.string);
        const method = try allocator.dupe(u8, target_node.map.get("method").?.string);
        const periodSeconds: u32 = @intCast(target_node.map.get("periodSeconds").?.int);

        var metrics = std.ArrayList(MetricConfig).init(allocator);

        const metrics_node = target_node.map.get("metrics").?;
        for (metrics_node.list) |metric_node| {
            const metric_name = try allocator.dupe(u8, metric_node.map.get("name").?.string);
            const valueQuery = try allocator.dupe(u8, metric_node.map.get("valueQuery").?.string);

            var labels = std.ArrayList(LabelConfig).init(allocator);

            if (metric_node.map.get("labels")) |labels_node| {
                for (labels_node.list) |label_node| {
                    const label_name = try allocator.dupe(u8, label_node.map.get("name").?.string);
                    const query = try allocator.dupe(u8, label_node.map.get("query").?.string);

                    try labels.append(.{
                        .name = label_name,
                        .query = query,
                    });
                }
            }

            try metrics.append(.{
                .name = metric_name,
                .valueQuery = valueQuery,
                .labels = try labels.toOwnedSlice(),
            });
        }

        try targets.append(.{
            .name = name,
            .uri = uri,
            .method = method,
            .periodSeconds = periodSeconds,
            .metrics = try metrics.toOwnedSlice(),
        });
    }

    return targets.toOwnedSlice();
}

test "loadConfig - valid YAML" {
    const test_yaml =
        \\targets:
        \\  - name: test-target
        \\    uri: https://example.com/api
        \\    method: GET
        \\    periodSeconds: 30
        \\    metrics:
        \\      - name: test_metric
        \\        valueQuery: .value
        \\        labels:
        \\          - name: label1
        \\            query: .label1
        \\          - name: label2
        \\            query: .label2
    ;

    // Write test file
    const test_file = "test_config.yaml";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer {
        file.close();
        std.fs.cwd().deleteFile(test_file) catch {};
    }
    try file.writeAll(test_yaml);

    // Test loading
    var config = try loadConfig(std.testing.allocator, test_file);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 1), config.targets.len);
    
    const target = config.targets[0];
    try std.testing.expectEqualStrings("test-target", target.name);
    try std.testing.expectEqualStrings("https://example.com/api", target.uri);
    try std.testing.expectEqualStrings("GET", target.method);
    try std.testing.expectEqual(@as(u32, 30), target.periodSeconds);
    
    try std.testing.expectEqual(@as(usize, 1), target.metrics.len);
    
    const metric = target.metrics[0];
    try std.testing.expectEqualStrings("test_metric", metric.name);
    try std.testing.expectEqualStrings(".value", metric.valueQuery);
    try std.testing.expectEqual(@as(usize, 2), metric.labels.len);
    
    try std.testing.expectEqualStrings("label1", metric.labels[0].name);
    try std.testing.expectEqualStrings(".label1", metric.labels[0].query);
    try std.testing.expectEqualStrings("label2", metric.labels[1].name);
    try std.testing.expectEqualStrings(".label2", metric.labels[1].query);
}

test "loadConfig - multiple targets" {
    const test_yaml =
        \\targets:
        \\  - name: target1
        \\    uri: https://api1.com
        \\    method: GET
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

    const test_file = "test_multi_config.yaml";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer {
        file.close();
        std.fs.cwd().deleteFile(test_file) catch {};
    }
    try file.writeAll(test_yaml);

    var config = try loadConfig(std.testing.allocator, test_file);
    defer config.deinit();

    try std.testing.expectEqual(@as(usize, 2), config.targets.len);
    
    try std.testing.expectEqualStrings("target1", config.targets[0].name);
    try std.testing.expectEqual(@as(u32, 60), config.targets[0].periodSeconds);
    
    try std.testing.expectEqualStrings("target2", config.targets[1].name);
    try std.testing.expectEqual(@as(u32, 120), config.targets[1].periodSeconds);
}

test "loadConfig - no labels" {
    const test_yaml =
        \\targets:
        \\  - name: no-labels
        \\    uri: https://example.com
        \\    method: GET
        \\    periodSeconds: 10
        \\    metrics:
        \\      - name: simple_metric
        \\        valueQuery: .count
    ;

    const test_file = "test_no_labels.yaml";
    const file = try std.fs.cwd().createFile(test_file, .{});
    defer {
        file.close();
        std.fs.cwd().deleteFile(test_file) catch {};
    }
    try file.writeAll(test_yaml);

    var config = try loadConfig(std.testing.allocator, test_file);
    defer config.deinit();

    const metric = config.targets[0].metrics[0];
    try std.testing.expectEqual(@as(usize, 0), metric.labels.len);
}
