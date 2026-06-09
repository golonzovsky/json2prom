const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("yaml", yaml.module("yaml"));
    exe_mod.linkSystemLibrary("jq", .{});

    const exe = b.addExecutable(.{
        .name = "json2prom",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const test_roots = [_][]const u8{
        "src/config.zig",
        "src/jq.zig",
        "src/metrics.zig",
        "src/poller.zig",
        "src/test_integration.zig",
    };
    for (test_roots) |root| {
        const mod = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addImport("yaml", yaml.module("yaml"));
        mod.linkSystemLibrary("jq", .{});
        const t = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
