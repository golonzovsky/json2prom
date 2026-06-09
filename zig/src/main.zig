const std = @import("std");
const config = @import("config.zig");
const metrics = @import("metrics.zig");
const poller = @import("poller.zig");

const default_listen = "0.0.0.0:9102";

pub const std_options: std.Options = .{ .log_level = .info };

var shutdown_requested: std.atomic.Value(bool) = .init(false);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var config_path: ?[]const u8 = null;
    var listen_addr: []const u8 = default_listen;

    var args = init.minimal.args.iterate();
    const argv0 = args.next() orelse "json2prom";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse return usage(argv0);
        } else if (std.mem.eql(u8, arg, "--listen")) {
            listen_addr = args.next() orelse return usage(argv0);
        } else {
            return usage(argv0);
        }
    }
    const path = config_path orelse return usage(argv0);

    var cfg = try config.load(gpa, io, path);
    defer cfg.deinit();
    try config.resolveBearerTokens(cfg.targets, init.environ_map);

    var registry = metrics.Registry.init(gpa, io);

    var pollers: std.ArrayList(*poller.Poller) = .empty;
    for (cfg.targets) |target| {
        const p = try gpa.create(poller.Poller);
        p.* = try poller.Poller.init(gpa, io, target, &registry);
        try pollers.append(gpa, p);
    }

    const address = std.Io.net.IpAddress.parseLiteral(listen_addr) catch {
        std.log.err("invalid listen address: {s}", .{listen_addr});
        return error.InvalidListenAddress;
    };
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.log.err("cannot listen on {s}: {t}", .{ listen_addr, err });
        return err;
    };

    for (pollers.items) |p| {
        std.log.info("starting poller for target {s} (every {d}s)", .{ p.target.name, p.target.periodSeconds });
        try p.start();
    }

    const server_thread = try std.Thread.spawn(.{}, serve, .{ &server, io, &registry, gpa });
    server_thread.detach();
    std.log.info("listening on {s}", .{listen_addr});

    installSignalHandlers();
    while (!shutdown_requested.load(.acquire)) {
        io.sleep(.fromMilliseconds(200), .awake) catch {};
    }

    std.log.info("shutting down", .{});
    for (pollers.items) |p| p.stop();
    std.process.exit(0);
}

fn usage(argv0: []const u8) error{InvalidUsage} {
    std.log.err("usage: {s} --config <config.yaml> [--listen <addr>] (default {s})", .{ argv0, default_listen });
    return error.InvalidUsage;
}

fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &action, null);
    std.posix.sigaction(.TERM, &action, null);
}

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    shutdown_requested.store(true, .release);
}

fn serve(server: *std.Io.net.Server, io: std.Io, registry: *metrics.Registry, gpa: std.mem.Allocator) void {
    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("accept failed: {t}", .{err});
            return;
        };
        const thread = std.Thread.spawn(.{}, handleConnection, .{ stream, io, registry, gpa }) catch {
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(stream: std.Io.net.Stream, io: std.Io, registry: *metrics.Registry, gpa: std.mem.Allocator) void {
    defer stream.close(io);

    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &recv_buffer);
    var writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var request = server.receiveHead() catch return;
        const keep_alive = request.head.keep_alive;
        handleRequest(&request, registry, gpa) catch return;
        if (!keep_alive) return;
    }
}

fn handleRequest(request: *std.http.Server.Request, registry: *metrics.Registry, gpa: std.mem.Allocator) !void {
    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/metrics")) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try registry.render(&aw.writer);
        try request.respond(aw.written(), .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" }},
        });
    } else if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/health")) {
        try request.respond("OK", .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/plain" }},
        });
    } else {
        try request.respond("Not Found", .{ .status = .not_found });
    }
}
