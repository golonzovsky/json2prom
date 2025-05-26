const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "json2prom",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link with libjq
    exe.linkSystemLibrary("jq");
    exe.linkLibC();

    // Add yaml parsing dependency
    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("yaml", yaml.module("yaml"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_step = b.step("test", "Run unit tests");

    // Config tests
    const config_tests = b.addTest(.{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_tests.root_module.addImport("yaml", yaml.module("yaml"));

    // JQ tests
    const jq_tests = b.addTest(.{
        .root_source_file = b.path("src/jq.zig"),
        .target = target,
        .optimize = optimize,
    });
    jq_tests.linkSystemLibrary("jq");
    jq_tests.linkLibC();

    // Metrics tests
    const metrics_tests = b.addTest(.{
        .root_source_file = b.path("src/metrics.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Poller tests
    const poller_tests = b.addTest(.{
        .root_source_file = b.path("src/poller.zig"),
        .target = target,
        .optimize = optimize,
    });
    poller_tests.linkSystemLibrary("jq");
    poller_tests.linkLibC();
    poller_tests.root_module.addImport("yaml", yaml.module("yaml"));

    // Integration tests
    const integration_tests = b.addTest(.{
        .root_source_file = b.path("src/test_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_tests.linkSystemLibrary("jq");
    integration_tests.linkLibC();
    integration_tests.root_module.addImport("yaml", yaml.module("yaml"));

    const run_config_tests = b.addRunArtifact(config_tests);
    const run_jq_tests = b.addRunArtifact(jq_tests);
    const run_metrics_tests = b.addRunArtifact(metrics_tests);
    const run_poller_tests = b.addRunArtifact(poller_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);

    test_step.dependOn(&run_config_tests.step);
    test_step.dependOn(&run_jq_tests.step);
    test_step.dependOn(&run_metrics_tests.step);
    test_step.dependOn(&run_poller_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
