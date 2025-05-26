const std = @import("std");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const poller = @import("poller.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.log.err("Usage: {s} <config.yaml>", .{args[0]});
        return;
    }

    // Load configuration
    var cfg = try config.loadConfig(allocator, args[1]);
    defer cfg.deinit();

    // Initialize metrics registry
    var registry = metrics.MetricsRegistry.init(allocator);
    defer registry.deinit();

    // Start pollers
    var pollers = std.ArrayList(*poller.Poller).init(allocator);
    defer {
        for (pollers.items) |p| {
            p.stop();
            p.deinit();
            allocator.destroy(p);
        }
        pollers.deinit();
    }

    for (cfg.targets) |target| {
        std.log.info("Starting poller for target: {s}", .{target.name});
        const p = try allocator.create(poller.Poller);
        p.* = poller.Poller.init(allocator, target, &registry);
        try p.start();
        try pollers.append(p);
    }

    // Start HTTP server for Prometheus scraping
    const server_thread = try std.Thread.spawn(.{}, runMetricsServer, .{ &registry, allocator });
    defer server_thread.join();

    // Keep running
    std.log.info("Prometheus JSON proxy started. Press Ctrl+C to stop.", .{});

    // Handle shutdown signal
    _ = std.posix.sigaction(std.posix.SIG.TERM, &.{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    // Wait forever
    while (true) {
        std.time.sleep(std.time.ns_per_s);
    }
}

fn handleSignal(sig: c_int) callconv(.C) void {
    _ = sig;
    std.process.exit(0);
}

fn runMetricsServer(registry: *metrics.MetricsRegistry, allocator: std.mem.Allocator) !void {
    const address = try std.net.Address.parseIp("0.0.0.0", 9090);
    var server = try address.listen(.{});
    defer server.deinit();

    std.log.info("Metrics server listening on :9090/metrics", .{});

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleMetricsRequest, .{ conn, registry, allocator });
        thread.detach();
    }
}

fn handleMetricsRequest(conn: std.net.Server.Connection, registry: *metrics.MetricsRegistry, allocator: std.mem.Allocator) !void {
    defer conn.stream.close();

    var buffer: [4096]u8 = undefined;
    _ = try conn.stream.read(&buffer);

    // Simple HTTP response
    const response_header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n";
    _ = try conn.stream.write(response_header);

    // Export metrics
    var metrics_buffer = std.ArrayList(u8).init(allocator);
    defer metrics_buffer.deinit();

    try registry.exportPrometheus(metrics_buffer.writer());
    _ = try conn.stream.write(metrics_buffer.items);
}
