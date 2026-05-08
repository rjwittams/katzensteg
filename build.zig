const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const is_macos = target.result.os.tag == .macos;
    const use_llvm: ?bool = if (target.result.os.tag == .linux) true else null;
    const enable_vulkan = b.option(bool, "vulkan", "Build Vulkan capture layer and probe") orelse true;
    const default_preload_options = b.addOptions();
    default_preload_options.addOption(bool, "use_c_real_sdl", target.result.os.tag == .linux);
    const test_preload_options = b.addOptions();
    test_preload_options.addOption(bool, "use_c_real_sdl", false);
    const rebind_preload_options = b.addOptions();
    rebind_preload_options.addOption(bool, "use_c_real_sdl", true);

    const termscene_mod = b.createModule(.{
        .root_source_file = b.path("src/termscene/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    const katzensteg_sdl_mod = b.createModule(.{
        .root_source_file = b.path("src/katzensteg/sdl2.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run Katzensteg and termscene unit tests");

    const exe = b.addExecutable(.{
        .name = "ttytris",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/ttytris/main.zig"),
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
        .use_llvm = use_llvm,
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
        .use_llvm = use_llvm,
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
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/kitty-show-ppm/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kitty_show_ppm.root_module.addImport("termscene", termscene_mod);
    b.installArtifact(kitty_show_ppm);

    const katzensteg_core_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-core",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/katzensteg/core_exports.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_core_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_core_lib.root_module.strip = false;
    katzensteg_core_lib.root_module.omit_frame_pointer = false;
    if (is_macos) {
        katzensteg_core_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_core_lib.linkFramework("Accelerate");
    } else if (target.result.os.tag == .linux) {
        katzensteg_core_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_core_lib.version_script = b.path("src/katzensteg/katzensteg_core_linux.map");
        katzensteg_core_lib.linkSystemLibrary("yuv");
    }
    b.installArtifact(katzensteg_core_lib);

    const katzensteg_sdl2_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-sdl2",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/katzensteg/preload.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_sdl2_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_sdl2_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl_mod);
    katzensteg_sdl2_lib.root_module.addImport("katzensteg_build_options", default_preload_options.createModule());
    katzensteg_sdl2_lib.root_module.strip = false;
    katzensteg_sdl2_lib.root_module.omit_frame_pointer = false;
    katzensteg_sdl2_lib.linker_allow_shlib_undefined = true;
    if (is_macos) {
        katzensteg_sdl2_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_macos.c") });
        katzensteg_sdl2_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_sdl2_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_sdl2_lib.linkFramework("Accelerate");
        katzensteg_sdl2_lib.linkFramework("OpenGL");
    } else if (target.result.os.tag == .linux) {
        katzensteg_sdl2_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_sdl2_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_sdl2_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_linux.c") });
        katzensteg_sdl2_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_linux.c") });
        katzensteg_sdl2_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl_linux.c") });
        katzensteg_sdl2_lib.version_script = b.path("src/katzensteg/katzensteg_sdl2_linux.map");
        katzensteg_sdl2_lib.linkSystemLibrary("yuv");
    }
    b.installArtifact(katzensteg_sdl2_lib);

    if (is_macos) {
        const katzensteg_sdl2_rebind_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "katzensteg-sdl2-rebind",
            .use_llvm = use_llvm,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/katzensteg/preload.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        katzensteg_sdl2_rebind_lib.root_module.addImport("termscene", termscene_mod);
        katzensteg_sdl2_rebind_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl_mod);
        katzensteg_sdl2_rebind_lib.root_module.addImport("katzensteg_build_options", rebind_preload_options.createModule());
        katzensteg_sdl2_rebind_lib.root_module.strip = false;
        katzensteg_sdl2_rebind_lib.root_module.omit_frame_pointer = false;
        katzensteg_sdl2_rebind_lib.linker_allow_shlib_undefined = true;
        katzensteg_sdl2_rebind_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_sdl2_rebind_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_sdl2_rebind_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl_macos.c") });
        katzensteg_sdl2_rebind_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/darwin_rebinder.c") });
        katzensteg_sdl2_rebind_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/sdl2_rebind_macos.c") });
        katzensteg_sdl2_rebind_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/preload_macos_rebind.c") });
        katzensteg_sdl2_rebind_lib.linkFramework("Accelerate");
        katzensteg_sdl2_rebind_lib.linkFramework("OpenGL");
        b.installArtifact(katzensteg_sdl2_rebind_lib);
    }

    const katzensteg_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/katzensteg/preload.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl_mod);
    katzensteg_lib.root_module.addImport("katzensteg_build_options", default_preload_options.createModule());
    katzensteg_lib.root_module.strip = false;
    katzensteg_lib.root_module.omit_frame_pointer = false;
    if (is_macos) katzensteg_lib.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    katzensteg_lib.linkSystemLibrary("SDL2");
    if (is_macos) {
        katzensteg_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_macos.c") });
        katzensteg_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_lib.linkFramework("Accelerate");
        katzensteg_lib.linkFramework("OpenGL");
    } else if (target.result.os.tag == .linux) {
        katzensteg_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_linux.c") });
        katzensteg_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_linux.c") });
        katzensteg_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl_linux.c") });
        katzensteg_lib.version_script = b.path("src/katzensteg/katzensteg_linux.map");
        katzensteg_lib.linkSystemLibrary("yuv");
    }
    b.installArtifact(katzensteg_lib);

    const katzensteg_unlinked_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-unlinked",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/katzensteg/preload.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_unlinked_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_unlinked_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl_mod);
    katzensteg_unlinked_lib.root_module.addImport("katzensteg_build_options", default_preload_options.createModule());
    katzensteg_unlinked_lib.root_module.strip = false;
    katzensteg_unlinked_lib.root_module.omit_frame_pointer = false;
    katzensteg_unlinked_lib.linker_allow_shlib_undefined = true;
    if (is_macos) {
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_macos.c") });
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_unlinked_lib.linkFramework("Accelerate");
        katzensteg_unlinked_lib.linkFramework("OpenGL");
    } else if (target.result.os.tag == .linux) {
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_linux.c") });
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_linux.c") });
        katzensteg_unlinked_lib.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl_linux.c") });
        katzensteg_unlinked_lib.version_script = b.path("src/katzensteg/katzensteg_linux.map");
        katzensteg_unlinked_lib.linkSystemLibrary("yuv");
    }
    b.installArtifact(katzensteg_unlinked_lib);
    if (is_macos and builtin.os.tag == .macos) {
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
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/probes/basic_sdl_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    basic_sdl_demo.root_module.addImport("katzensteg_sdl", katzensteg_sdl_mod);
    if (is_macos) basic_sdl_demo.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    basic_sdl_demo.linkSystemLibrary("SDL2");
    b.installArtifact(basic_sdl_demo);

    const katzensteg_input_probe = b.addExecutable(.{
        .name = "katzensteg-input-probe",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_input_probe.addCSourceFile(.{ .file = b.path("examples/probes/input_probe.c") });
    if (is_macos) {
        katzensteg_input_probe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
        katzensteg_input_probe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    katzensteg_input_probe.linkSystemLibrary("SDL2");
    b.installArtifact(katzensteg_input_probe);

    const katzensteg_gl_probe = b.addExecutable(.{
        .name = "katzensteg-gl-probe",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_gl_probe.addCSourceFile(.{ .file = b.path("examples/probes/gl_probe.c") });
    if (is_macos) {
        katzensteg_gl_probe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
        katzensteg_gl_probe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    katzensteg_gl_probe.linkSystemLibrary("SDL2");
    if (is_macos) {
        katzensteg_gl_probe.linkFramework("OpenGL");
    } else {
        katzensteg_gl_probe.linkSystemLibrary("GL");
    }
    b.installArtifact(katzensteg_gl_probe);

    if (enable_vulkan) {
        const katzensteg_vulkan_layer = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "katzensteg-vulkan-layer",
            .use_llvm = use_llvm,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        katzensteg_vulkan_layer.addCSourceFile(.{ .file = b.path("src/katzensteg/vulkan_layer.c") });
        katzensteg_vulkan_layer.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        if (is_macos) katzensteg_vulkan_layer.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        b.installArtifact(katzensteg_vulkan_layer);

        const katzensteg_vulkan_probe = b.addExecutable(.{
            .name = "katzensteg-vulkan-probe",
            .use_llvm = use_llvm,
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        katzensteg_vulkan_probe.addCSourceFile(.{ .file = b.path("examples/probes/vulkan_probe.c") });
        if (is_macos) {
            katzensteg_vulkan_probe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
            katzensteg_vulkan_probe.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
            katzensteg_vulkan_probe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        }
        katzensteg_vulkan_probe.linkSystemLibrary("SDL2");
        katzensteg_vulkan_probe.linkSystemLibrary("vulkan");
        b.installArtifact(katzensteg_vulkan_probe);

        const katzensteg_vulkan_layer_build_step = b.step("katzensteg-vulkan-layer", "Build the Vulkan capture layer used by Katzensteg");
        katzensteg_vulkan_layer_build_step.dependOn(&katzensteg_vulkan_layer.step);

        const katzensteg_vulkan_probe_build_step = b.step("katzensteg-vulkan-probe", "Build the SDL2 Vulkan probe used for Katzensteg Vulkan capture work");
        katzensteg_vulkan_probe_build_step.dependOn(&katzensteg_vulkan_probe.step);

        const katzensteg_vulkan_probe_cmd = b.addRunArtifact(katzensteg_vulkan_probe);
        if (b.args) |args| katzensteg_vulkan_probe_cmd.addArgs(args);
        const katzensteg_vulkan_probe_step = b.step("run-katzensteg-vulkan-probe", "Run the SDL2 Vulkan probe used for Katzensteg Vulkan capture work");
        katzensteg_vulkan_probe_step.dependOn(&katzensteg_vulkan_probe_cmd.step);
    }

    const katzensteg_launcher = b.addExecutable(.{
        .name = "katzensteg",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/katzensteg/launcher.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_launcher.root_module.addImport("termscene", termscene_mod);
    b.installArtifact(katzensteg_launcher);
    const katzensteg_proxy = b.addExecutable(.{
        .name = "katzensteg-proxy",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/katzensteg/launcher.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_proxy.root_module.addImport("termscene", termscene_mod);
    b.installArtifact(katzensteg_proxy);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run ttytris");
    run_step.dependOn(&run_cmd.step);

    const debug_exe = b.addExecutable(.{
        .name = "ttytris-debug",
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/ttytris/main.zig"),
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

    addUnitTest(b, test_step, "termscene-protocol-test", "src/termscene/kitty/protocol.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-config-test", "src/katzensteg/config.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-log-test", "src/katzensteg/log.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-render-batch-protocol-test", "src/katzensteg/render_batch_protocol.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-attach-protocol-test", "src/katzensteg/attach_protocol.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-terminal-batch-applier-test", "src/katzensteg/terminal_batch_applier.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-wm-host-test", "src/katzensteg/wm_host.zig", target, optimize, use_llvm, .{
        .termscene = termscene_mod,
        .link_libc = true,
    });
    addUnitTest(b, test_step, "katzensteg-render-batch-sink-test", "src/katzensteg/render_batch_sink.zig", target, optimize, use_llvm, .{
        .termscene = termscene_mod,
    });
    addUnitTest(b, test_step, "katzensteg-frame-builder-test", "src/katzensteg/frame_builder.zig", target, optimize, use_llvm, .{
        .termscene = termscene_mod,
        .katzensteg_sdl = katzensteg_sdl_mod,
        .link_libc = true,
    });
    addUnitTest(b, test_step, "katzensteg-runtime-test", "src/katzensteg/runtime.zig", target, optimize, use_llvm, .{
        .termscene = termscene_mod,
        .katzensteg_sdl = katzensteg_sdl_mod,
        .link_libc = true,
        .link_sdl2 = true,
    });
    addUnitTest(b, test_step, "katzensteg-preload-test", "src/katzensteg/preload.zig", target, optimize, use_llvm, .{
        .termscene = termscene_mod,
        .katzensteg_sdl = katzensteg_sdl_mod,
        .katzensteg_build_options = test_preload_options.createModule(),
        .link_libc = true,
        .link_sdl2 = true,
        .link_opengl = true,
    });
    addUnitTest(b, test_step, "katzensteg-launcher-profiles-test", "src/katzensteg/launcher_profiles.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-launcher-context-test", "src/katzensteg/launcher/context.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-wm-cli-test", "src/katzensteg/wm/cli.zig", target, optimize, use_llvm, .{});
    addUnitTest(b, test_step, "katzensteg-attach-host-test", "src/katzensteg/attach_host.zig", target, optimize, use_llvm, .{
        .termscene = termscene_mod,
        .link_libc = true,
    });
    addUnitTest(b, test_step, "katzensteg-launcher-test", "src/katzensteg/launcher.zig", target, optimize, use_llvm, .{
        .termscene = termscene_mod,
    });
}

const UnitTestOptions = struct {
    termscene: ?*std.Build.Module = null,
    katzensteg_sdl: ?*std.Build.Module = null,
    katzensteg_build_options: ?*std.Build.Module = null,
    link_libc: bool = false,
    link_sdl2: bool = false,
    link_opengl: bool = false,
};

fn addUnitTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    use_llvm: ?bool,
    options: UnitTestOptions,
) void {
    const unit_test = b.addTest(.{
        .name = name,
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
            .link_libc = options.link_libc,
        }),
    });
    if (options.termscene) |mod| unit_test.root_module.addImport("termscene", mod);
    if (options.katzensteg_sdl) |mod| unit_test.root_module.addImport("katzensteg_sdl", mod);
    if (options.katzensteg_build_options) |mod| unit_test.root_module.addImport("katzensteg_build_options", mod);
    if (options.link_sdl2) {
        if (target.result.os.tag == .macos) unit_test.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        unit_test.linkSystemLibrary("SDL2");
    }
    if (options.link_opengl) {
        if (target.result.os.tag == .macos) {
            unit_test.linkFramework("OpenGL");
        } else if (target.result.os.tag == .linux) {
            unit_test.linkSystemLibrary("GL");
        }
    }
    const run_unit_test = b.addRunArtifact(unit_test);
    test_step.dependOn(&run_unit_test.step);
}
