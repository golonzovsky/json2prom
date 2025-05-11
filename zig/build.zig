const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig",
        .root_module = exe_mod,
    });

    // zig-yaml
    const yaml_dep = b.dependency("zig-yaml", .{});
    exe.addModule("yaml", yaml_dep.module("yaml"));

    // zig‑clap (command‑line flags)
    const clap_dep = b.dependency("clap", .{}); // pulled via `git submodule add https://github.com/Hejsil/zig-clap extern/zig-clap`
    exe.addModule("clap", clap_dep.module("clap"));

    // libjq (C)
    const jq_cflags = [_][]const u8{"-DJQ_STATIC"};
    const jqlib = b.addStaticLibrary("jq", null);
    jqlib.addCSourceFiles(.{
        .root = "extern/jq",
    }, jq_cflags);
    exe.linkLibrary(jqlib);
    exe.addIncludePath("extern/jq");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
