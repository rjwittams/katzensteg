const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ttytris",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    if (optimize == .Debug) {
        exe.root_module.strip = false;
        exe.root_module.omit_frame_pointer = false;
    }

    b.installArtifact(exe);

    const termscene_demo = b.addExecutable(.{
        .name = "termscene-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/termscene_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(termscene_demo);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ttytris");
    run_step.dependOn(&run_cmd.step);

    const debug_exe = b.addExecutable(.{
        .name = "ttytris-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    debug_exe.root_module.strip = false;
    debug_exe.root_module.omit_frame_pointer = false;
    b.installArtifact(debug_exe);

    const debug_run_cmd = b.addRunArtifact(debug_exe);
    if (b.args) |args| debug_run_cmd.addArgs(args);
    const debug_run_step = b.step("debug-run", "Run ttytris with Debug symbols");
    debug_run_step.dependOn(&debug_run_cmd.step);

    const termscene_demo_cmd = b.addRunArtifact(termscene_demo);
    if (b.args) |args| termscene_demo_cmd.addArgs(args);
    const termscene_demo_step = b.step("termscene-demo", "Run termscene feature demo");
    termscene_demo_step.dependOn(&termscene_demo_cmd.step);
}
