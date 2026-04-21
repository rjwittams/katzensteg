const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const termscene_mod = b.createModule(.{
        .root_source_file = b.path("src/termscene/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const katzensteg_sdl_mod = b.createModule(.{
        .root_source_file = b.path("tools/katzensteg/sdl2.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ttytris",
        .root_module = b.createModule(.{
            .root_source_file = b.path("games/ttytris/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("termscene", termscene_mod);

    if (optimize == .Debug) {
        exe.root_module.strip = false;
        exe.root_module.omit_frame_pointer = false;
    }

    b.installArtifact(exe);

    const termscene_demo = b.addExecutable(.{
        .name = "termscene-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/termscene-demo/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    termscene_demo.root_module.addImport("termscene", termscene_mod);
    b.installArtifact(termscene_demo);

    const kitty_placement_repro = b.addExecutable(.{
        .name = "kitty-placement-repro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/kitty-placement-repro/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kitty_placement_repro.root_module.addImport("termscene", termscene_mod);
    b.installArtifact(kitty_placement_repro);

    const katzensteg_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/katzensteg/preload.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl_mod);
    katzensteg_lib.linker_allow_shlib_undefined = true;
    katzensteg_lib.addCSourceFile(.{ .file = b.path("tools/katzensteg/interpose_macos.c") });
    b.installArtifact(katzensteg_lib);

    const basic_sdl_demo = b.addExecutable(.{
        .name = "basic-sdl-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/katzensteg/test/basic_sdl_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    basic_sdl_demo.root_module.addImport("katzensteg_sdl", katzensteg_sdl_mod);
    basic_sdl_demo.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    basic_sdl_demo.linkSystemLibrary("SDL2");
    b.installArtifact(basic_sdl_demo);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ttytris");
    run_step.dependOn(&run_cmd.step);

    const debug_exe = b.addExecutable(.{
        .name = "ttytris-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("games/ttytris/main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    debug_exe.root_module.addImport("termscene", termscene_mod);
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

    const kitty_placement_repro_cmd = b.addRunArtifact(kitty_placement_repro);
    if (b.args) |args| kitty_placement_repro_cmd.addArgs(args);
    const kitty_placement_repro_step = b.step("kitty-placement-repro", "Run the standalone kitty placement semantics repro");
    kitty_placement_repro_step.dependOn(&kitty_placement_repro_cmd.step);

    const basic_sdl_demo_cmd = b.addRunArtifact(basic_sdl_demo);
    if (b.args) |args| basic_sdl_demo_cmd.addArgs(args);
    const basic_sdl_demo_step = b.step("basic-sdl-demo", "Run the basic SDL2 demo used for Katzensteg bring-up");
    basic_sdl_demo_step.dependOn(&basic_sdl_demo_cmd.step);
}
