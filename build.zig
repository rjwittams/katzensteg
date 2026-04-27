const std = @import("std");
const builtin = @import("builtin");

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

    const kitty_show_ppm = b.addExecutable(.{
        .name = "kitty-show-ppm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/kitty-show-ppm/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kitty_show_ppm.root_module.addImport("termscene", termscene_mod);
    b.installArtifact(kitty_show_ppm);

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
    katzensteg_lib.root_module.strip = false;
    katzensteg_lib.root_module.omit_frame_pointer = false;
    katzensteg_lib.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    katzensteg_lib.linkSystemLibrary("SDL2");
    katzensteg_lib.addCSourceFile(.{ .file = b.path("tools/katzensteg/interpose_macos.c") });
    if (target.result.os.tag == .macos) {
        katzensteg_lib.addCSourceFile(.{ .file = b.path("tools/katzensteg/yuv_convert_macos.c") });
        katzensteg_lib.linkFramework("Accelerate");
        katzensteg_lib.linkFramework("OpenGL");
    }
    b.installArtifact(katzensteg_lib);

    const katzensteg_unlinked_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-unlinked",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/katzensteg/preload.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_unlinked_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_unlinked_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl_mod);
    katzensteg_unlinked_lib.root_module.strip = false;
    katzensteg_unlinked_lib.root_module.omit_frame_pointer = false;
    katzensteg_unlinked_lib.linker_allow_shlib_undefined = true;
    katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("tools/katzensteg/interpose_macos.c") });
    if (target.result.os.tag == .macos) {
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("tools/katzensteg/yuv_convert_macos.c") });
        katzensteg_unlinked_lib.linkFramework("Accelerate");
        katzensteg_unlinked_lib.linkFramework("OpenGL");
    }
    b.installArtifact(katzensteg_unlinked_lib);
    if (target.result.os.tag == .macos and builtin.os.tag == .macos) {
        const katzensteg_unlinked_dsym_cmd = b.addSystemCommand(&.{"dsymutil"});
        katzensteg_unlinked_dsym_cmd.addFileArg(katzensteg_unlinked_lib.getEmittedBin());
        katzensteg_unlinked_dsym_cmd.addArg("-o");
        const katzensteg_unlinked_dsym = katzensteg_unlinked_dsym_cmd.addOutputDirectoryArg("libkatzensteg-unlinked.dylib.dSYM");
        const install_katzensteg_unlinked_dsym = b.addInstallDirectory(.{
            .source_dir = katzensteg_unlinked_dsym,
            .install_dir = .lib,
            .install_subdir = "libkatzensteg-unlinked.dylib.dSYM",
        });
        b.getInstallStep().dependOn(&install_katzensteg_unlinked_dsym.step);

        const katzensteg_dsym_step = b.step("katzensteg-dsym", "Generate and install dSYM for Katzensteg preload library");
        katzensteg_dsym_step.dependOn(&install_katzensteg_unlinked_dsym.step);
    }

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

    const katzensteg_input_probe = b.addExecutable(.{
        .name = "katzensteg-input-probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_input_probe.addCSourceFile(.{ .file = b.path("tools/katzensteg/test/input_probe.c") });
    katzensteg_input_probe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
    katzensteg_input_probe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    katzensteg_input_probe.linkSystemLibrary("SDL2");
    b.installArtifact(katzensteg_input_probe);

    const katzensteg_gl_probe = b.addExecutable(.{
        .name = "katzensteg-gl-probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_gl_probe.addCSourceFile(.{ .file = b.path("tools/katzensteg/test/gl_probe.c") });
    katzensteg_gl_probe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
    katzensteg_gl_probe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    katzensteg_gl_probe.linkSystemLibrary("SDL2");
    if (target.result.os.tag == .macos) {
        katzensteg_gl_probe.linkFramework("OpenGL");
    } else {
        katzensteg_gl_probe.linkSystemLibrary("GL");
    }
    b.installArtifact(katzensteg_gl_probe);

    const katzensteg_vulkan_layer = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-vulkan-layer",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_vulkan_layer.addCSourceFile(.{ .file = b.path("tools/katzensteg/vulkan_layer.c") });
    katzensteg_vulkan_layer.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    b.installArtifact(katzensteg_vulkan_layer);

    const katzensteg_vulkan_probe = b.addExecutable(.{
        .name = "katzensteg-vulkan-probe",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_vulkan_probe.addCSourceFile(.{ .file = b.path("tools/katzensteg/test/vulkan_probe.c") });
    katzensteg_vulkan_probe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    katzensteg_vulkan_probe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
    katzensteg_vulkan_probe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    katzensteg_vulkan_probe.linkSystemLibrary("SDL2");
    katzensteg_vulkan_probe.linkSystemLibrary("vulkan");
    b.installArtifact(katzensteg_vulkan_probe);

    const katzensteg_launcher = b.addExecutable(.{
        .name = "katzensteg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/katzensteg/launcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(katzensteg_launcher);

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

    const kitty_show_ppm_cmd = b.addRunArtifact(kitty_show_ppm);
    if (b.args) |args| kitty_show_ppm_cmd.addArgs(args);
    const kitty_show_ppm_step = b.step("kitty-show-ppm", "Show a P6 PPM fullscreen via kitty graphics");
    kitty_show_ppm_step.dependOn(&kitty_show_ppm_cmd.step);

    const basic_sdl_demo_cmd = b.addRunArtifact(basic_sdl_demo);
    if (b.args) |args| basic_sdl_demo_cmd.addArgs(args);
    const basic_sdl_demo_step = b.step("basic-sdl-demo", "Run the basic SDL2 demo used for Katzensteg bring-up");
    basic_sdl_demo_step.dependOn(&basic_sdl_demo_cmd.step);

    const katzensteg_input_probe_build_step = b.step("katzensteg-input-probe", "Build the SDL2 input probe used for Katzensteg input injection work");
    katzensteg_input_probe_build_step.dependOn(&katzensteg_input_probe.step);

    const katzensteg_input_probe_cmd = b.addRunArtifact(katzensteg_input_probe);
    if (b.args) |args| katzensteg_input_probe_cmd.addArgs(args);
    const katzensteg_input_probe_step = b.step("run-katzensteg-input-probe", "Run the SDL2 input probe used for Katzensteg input injection work");
    katzensteg_input_probe_step.dependOn(&katzensteg_input_probe_cmd.step);

    const katzensteg_gl_probe_build_step = b.step("katzensteg-gl-probe", "Build the SDL2 OpenGL probe used for Katzensteg GL capture work");
    katzensteg_gl_probe_build_step.dependOn(&katzensteg_gl_probe.step);

    const katzensteg_gl_probe_cmd = b.addRunArtifact(katzensteg_gl_probe);
    if (b.args) |args| katzensteg_gl_probe_cmd.addArgs(args);
    const katzensteg_gl_probe_step = b.step("run-katzensteg-gl-probe", "Run the SDL2 OpenGL probe used for Katzensteg GL capture work");
    katzensteg_gl_probe_step.dependOn(&katzensteg_gl_probe_cmd.step);

    const katzensteg_vulkan_layer_build_step = b.step("katzensteg-vulkan-layer", "Build the Vulkan capture layer used by Katzensteg");
    katzensteg_vulkan_layer_build_step.dependOn(&katzensteg_vulkan_layer.step);

    const katzensteg_vulkan_probe_build_step = b.step("katzensteg-vulkan-probe", "Build the SDL2 Vulkan probe used for Katzensteg Vulkan capture work");
    katzensteg_vulkan_probe_build_step.dependOn(&katzensteg_vulkan_probe.step);

    const katzensteg_vulkan_probe_cmd = b.addRunArtifact(katzensteg_vulkan_probe);
    if (b.args) |args| katzensteg_vulkan_probe_cmd.addArgs(args);
    const katzensteg_vulkan_probe_step = b.step("run-katzensteg-vulkan-probe", "Run the SDL2 Vulkan probe used for Katzensteg Vulkan capture work");
    katzensteg_vulkan_probe_step.dependOn(&katzensteg_vulkan_probe_cmd.step);
}
