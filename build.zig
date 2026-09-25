const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("platform", .{ .root_source_file = b.path("src/platform/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const is_macos = target.result.os.tag == .macos;
    const is_windows = target.result.os.tag == .windows;
    const use_llvm: ?bool = if (target.result.os.tag == .linux) true else null;
    const enable_vulkan = b.option(bool, "vulkan", "Build Vulkan capture layer and probe") orelse true;
    const enable_jackstay = b.option(bool, "jackstay", "Build optional CPU Jackstay connectors") orelse false;
    const jackstay_prefix = b.option([]const u8, "jackstay-prefix", "Prepared pinned Jackstay dependency prefix");
    const features = b.addOptions();
    features.addOption(bool, "jackstay", enable_jackstay);
    const jackstay_mod = b.addModule("jackstay", .{
        .root_source_file = b.path("src/jackstay/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    jackstay_mod.addOptions("features", features);
    jackstay_mod.addImport("platform", b.modules.get("platform").?);
    if (enable_jackstay) {
        if (target.result.os.tag != .macos and target.result.os.tag != .linux) @panic("Jackstay CPU connectors require macOS or Linux");
        const prefix = jackstay_prefix orelse @panic("-Djackstay=true requires -Djackstay-prefix; see docs/jackstay.md");
        const library = if (is_macos) "libjackstay.dylib" else "libjackstay.so";
        jackstay_mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
        // Link the prepared file directly: -ljackstay also makes Zig inject
        // its build directory as an automatic runtime search path.
        jackstay_mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", library }) });
        // Installed artifacts resolve Jackstay within their own package.
        jackstay_mod.addRPathSpecial(if (is_macos) "@loader_path/../lib" else "$ORIGIN/../lib");
        jackstay_mod.addRPathSpecial(if (is_macos) "@loader_path" else "$ORIGIN");
        const install = b.addInstallLibFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", library }) }, library);
        b.getInstallStep().dependOn(&install.step);
    }
    const default_preload_options = b.addOptions();
    default_preload_options.addOption(bool, "use_c_real_sdl", target.result.os.tag == .linux);
    default_preload_options.addOption(bool, "dynapi", false);
    const test_preload_options = b.addOptions();
    test_preload_options.addOption(bool, "use_c_real_sdl", false);
    test_preload_options.addOption(bool, "dynapi", false);
    const rebind_preload_options = b.addOptions();
    rebind_preload_options.addOption(bool, "use_c_real_sdl", true);
    rebind_preload_options.addOption(bool, "dynapi", false);
    // SDL_DYNAMIC_API builds take every real SDL function from the jump table
    // of the SDL that loads them.
    const dynapi_preload_options = b.addOptions();
    dynapi_preload_options.addOption(bool, "use_c_real_sdl", true);
    dynapi_preload_options.addOption(bool, "dynapi", true);
    // Windows builds of the SDL probes link the official development
    // package (the x86_64-w64-mingw32 directory of SDL2-devel-*-mingw).
    const sdl2_prefix = b.option([]const u8, "sdl2-prefix", "SDL2 development prefix with include/ and lib/ (Windows)");
    windows_sdl_prefixes = .{
        .sdl2 = sdl2_prefix,
        .sdl3 = b.option([]const u8, "sdl3-prefix", "SDL3 development prefix with include/ and lib/ (Windows)"),
    };

    const termscene_mod = projectModule(b, .{
        .root_source_file = b.path("src/termscene/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const xev_mod = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    }).module("xev");

    const katzensteg_sdl2_mod = projectModule(b, .{
        .root_source_file = b.path("src/katzensteg/sdl2.zig"),
        .target = target,
        .optimize = optimize,
    });
    const katzensteg_sdl3_mod = projectModule(b, .{
        .root_source_file = b.path("src/katzensteg/sdl3.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run Katzensteg and termscene unit tests");
    const test_library_dir = if (enable_jackstay) b.pathJoin(&.{ jackstay_prefix.?, "lib" }) else null;
    addUnitTest(b, test_step, "jackstay-test", "src/jackstay/tests.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    if (enable_jackstay) {
        const probe = b.addExecutable(.{ .name = "katzensteg-jackstay-probe", .use_llvm = use_llvm, .root_module = projectModule(b, .{
            .root_source_file = b.path("src/jackstay/probe.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        b.installArtifact(probe);
        b.step("jackstay-probe", "Build the Jackstay cross-process fixture").dependOn(&b.addInstallArtifact(probe, .{}).step);
    }
    if (enable_jackstay) addUnitTest(b, test_step, "katzensteg-jackstay-input-test", "src/katzensteg/jackstay_input_executor_test.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    if (enable_jackstay) addUnitTest(b, test_step, "katzensteg-jackstay-controller-test", "src/katzensteg/jackstay_input_controller_test.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    addUnitTest(b, test_step, "platform-test", "src/platform/tests.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    if (target.result.os.tag == .windows) addUnitTest(b, test_step, "platform-windows-test", "src/platform/windows.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });

    // On macOS, Zig emits debug-map binaries (no inline __DWARF); a UUID-matched
    // .dSYM bundle must sit next to each dylib for Instruments / lldb to symbolicate
    // it. Generate one for every Katzensteg dylib a profile may preload, not just one
    // variant. dsymutil is a host tool, so this only runs when building on macOS.
    const dsym_step: ?*std.Build.Step = if (is_macos and builtin.os.tag == .macos)
        b.step("katzensteg-dsym", "Generate and install dSYMs for Katzensteg dylibs (macOS symbolication)")
    else
        null;

    const exe = b.addExecutable(.{
        .name = "ttytris",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
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
        .root_module = projectModule(b, .{
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
        .root_module = projectModule(b, .{
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
        .root_module = projectModule(b, .{
            .root_source_file = b.path("examples/kitty-show-ppm/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    kitty_show_ppm.root_module.addImport("termscene", termscene_mod);
    b.installArtifact(kitty_show_ppm);

    // The standalone termscene programs need only the terminal and file
    // adapters, so this step also builds on Windows, where the preload
    // runtime does not yet.
    const termscene_examples_step = b.step("termscene-examples", "Build and install the standalone termscene example programs");
    for ([_]*std.Build.Step.Compile{ exe, termscene_demo, kitty_placement_repro, kitty_show_ppm }) |example| {
        termscene_examples_step.dependOn(&b.addInstallArtifact(example, .{}).step);
    }

    const katzensteg_core_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-core",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("src/katzensteg/core_exports.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_core_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_core_lib.root_module.strip = false;
    katzensteg_core_lib.root_module.omit_frame_pointer = false;
    if (enable_jackstay) {
        const consumer = b.addExecutable(.{ .name = "katzensteg-jackstay", .use_llvm = use_llvm, .root_module = projectModule(b, .{
            .root_source_file = b.path("src/katzensteg/jackstay_consumer.zig"),
            .target = target,
            .optimize = optimize,
        }) });
        consumer.root_module.addImport("termscene", termscene_mod);
        if (is_macos) {
            consumer.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
            consumer.root_module.linkFramework("Accelerate", .{});
        } else {
            consumer.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
            consumer.root_module.linkSystemLibrary("yuv", .{});
        }
        b.installArtifact(consumer);
    }
    if (is_macos) {
        katzensteg_core_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_core_lib.root_module.linkFramework("Accelerate", .{});
    } else if (target.result.os.tag == .linux) {
        katzensteg_core_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_core_lib.version_script = b.path("src/katzensteg/katzensteg_core_linux.map");
        katzensteg_core_lib.root_module.linkSystemLibrary("yuv", .{});
    }
    b.installArtifact(katzensteg_core_lib);
    if (dsym_step) |s| installDsym(b, katzensteg_core_lib, s);

    var katzensteg_metal_layer_install_step: ?*std.Build.Step = null;
    if (is_macos) {
        const layer = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "katzensteg-metal-layer",
            .use_llvm = use_llvm,
            .root_module = projectModule(b, .{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        layer.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/metal_layer.m"), .flags = &.{"-fobjc-arc"} });
        layer.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        layer.root_module.linkFramework("Foundation", .{});
        layer.root_module.linkFramework("Metal", .{});
        layer.root_module.linkFramework("QuartzCore", .{});
        layer.root_module.linkSystemLibrary("objc", .{});
        const install_layer = b.addInstallArtifact(layer, .{});
        b.getInstallStep().dependOn(&install_layer.step);
        if (dsym_step) |s| installDsym(b, layer, s);
        katzensteg_metal_layer_install_step = &install_layer.step;
    }

    const katzensteg_sdl2_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-sdl2",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("src/katzensteg/preload.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_sdl2_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_sdl2_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl2_mod);
    // Windows has no preload: its only SDL2 library is the dynamic API one.
    katzensteg_sdl2_lib.root_module.addImport("katzensteg_build_options", (if (is_windows) dynapi_preload_options else default_preload_options).createModule());
    katzensteg_sdl2_lib.root_module.strip = false;
    katzensteg_sdl2_lib.root_module.omit_frame_pointer = false;
    katzensteg_sdl2_lib.linker_allow_shlib_undefined = true;
    if (is_macos) {
        katzensteg_sdl2_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_macos.c") });
        katzensteg_sdl2_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_sdl2_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_sdl2_lib.root_module.linkFramework("Accelerate", .{});
        katzensteg_sdl2_lib.root_module.linkFramework("OpenGL", .{});
    } else if (target.result.os.tag == .linux) {
        katzensteg_sdl2_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_sdl2_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_sdl2_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_linux.c") });
        katzensteg_sdl2_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_linux.c") });
        katzensteg_sdl2_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl_linux.c") });
        katzensteg_sdl2_lib.version_script = b.path("src/katzensteg/katzensteg_sdl2_linux.map");
        katzensteg_sdl2_lib.root_module.linkSystemLibrary("yuv", .{});
    } else if (is_windows) {
        addDynapiSources(b, katzensteg_sdl2_lib, target, "dynapi_sdl2.c");
    }
    b.installArtifact(katzensteg_sdl2_lib);
    if (dsym_step) |s| installDsym(b, katzensteg_sdl2_lib, s);
    const sdl_dynapi_step = b.step("sdl-dynapi", "Build the SDL_DYNAMIC_API libraries, the launcher and the basic SDL demos");
    if (is_windows) {
        sdl_dynapi_step.dependOn(&b.addInstallArtifact(katzensteg_sdl2_lib, .{}).step);
    }

    const katzensteg_sdl3_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-sdl3",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("src/katzensteg/preload_sdl3.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_sdl3_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_sdl3_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl3_mod);
    katzensteg_sdl3_lib.root_module.addImport("katzensteg_build_options", (if (is_windows) dynapi_preload_options else default_preload_options).createModule());
    katzensteg_sdl3_lib.root_module.strip = false;
    katzensteg_sdl3_lib.root_module.omit_frame_pointer = false;
    katzensteg_sdl3_lib.linker_allow_shlib_undefined = true;
    if (is_macos) {
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_sdl3_macos.c") });
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl3_macos.c") });
        katzensteg_sdl3_lib.root_module.linkFramework("Accelerate", .{});
        katzensteg_sdl3_lib.root_module.linkFramework("OpenGL", .{});
    } else if (target.result.os.tag == .linux) {
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_sdl3_linux.c") });
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_linux.c") });
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl3_linux.c") });
        katzensteg_sdl3_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl3_compat.c") });
        katzensteg_sdl3_lib.version_script = b.path("src/katzensteg/katzensteg_sdl3_linux.map");
        katzensteg_sdl3_lib.root_module.linkSystemLibrary("yuv", .{});
    } else if (is_windows) {
        addDynapiSources(b, katzensteg_sdl3_lib, target, "dynapi_sdl3.c");
    }
    b.installArtifact(katzensteg_sdl3_lib);
    if (dsym_step) |s| installDsym(b, katzensteg_sdl3_lib, s);
    if (is_windows) {
        sdl_dynapi_step.dependOn(&b.addInstallArtifact(katzensteg_sdl3_lib, .{}).step);
    } else {
        // Linux and macOS keep their preload libraries and add one dynamic
        // API library per SDL version with the same build/install policy.
        inline for (.{
            .{ .name = "katzensteg-sdl2-dynapi", .root = "src/katzensteg/preload.zig", .sdl = katzensteg_sdl2_mod, .glue = "dynapi_sdl2.c" },
            .{ .name = "katzensteg-sdl3-dynapi", .root = "src/katzensteg/preload_sdl3.zig", .sdl = katzensteg_sdl3_mod, .glue = "dynapi_sdl3.c" },
        }) |adapter| {
            const lib = b.addLibrary(.{
                .linkage = .dynamic,
                .name = adapter.name,
                .use_llvm = use_llvm,
                .root_module = projectModule(b, .{
                    .root_source_file = b.path(adapter.root),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            lib.root_module.addImport("termscene", termscene_mod);
            lib.root_module.addImport("katzensteg_sdl", adapter.sdl);
            lib.root_module.addImport("katzensteg_build_options", dynapi_preload_options.createModule());
            lib.root_module.strip = false;
            lib.root_module.omit_frame_pointer = false;
            addDynapiSources(b, lib, target, adapter.glue);
            b.installArtifact(lib);
            if (dsym_step) |s| installDsym(b, lib, s);
            sdl_dynapi_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
        }
    }

    if (is_macos) {
        const katzensteg_sdl2_rebind_lib = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "katzensteg-sdl2-rebind",
            .use_llvm = use_llvm,
            .root_module = projectModule(b, .{
                .root_source_file = b.path("src/katzensteg/preload.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        katzensteg_sdl2_rebind_lib.root_module.addImport("termscene", termscene_mod);
        katzensteg_sdl2_rebind_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl2_mod);
        katzensteg_sdl2_rebind_lib.root_module.addImport("katzensteg_build_options", rebind_preload_options.createModule());
        katzensteg_sdl2_rebind_lib.root_module.strip = false;
        katzensteg_sdl2_rebind_lib.root_module.omit_frame_pointer = false;
        katzensteg_sdl2_rebind_lib.linker_allow_shlib_undefined = true;
        katzensteg_sdl2_rebind_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_sdl2_rebind_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_sdl2_rebind_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl_macos.c") });
        katzensteg_sdl2_rebind_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/darwin_rebinder.c") });
        katzensteg_sdl2_rebind_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/sdl2_rebind_macos.c") });
        katzensteg_sdl2_rebind_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/preload_macos_rebind.c") });
        katzensteg_sdl2_rebind_lib.root_module.linkFramework("Accelerate", .{});
        katzensteg_sdl2_rebind_lib.root_module.linkFramework("OpenGL", .{});
        b.installArtifact(katzensteg_sdl2_rebind_lib);
        if (dsym_step) |s| installDsym(b, katzensteg_sdl2_rebind_lib, s);
    }

    const katzensteg_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("src/katzensteg/preload.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl2_mod);
    katzensteg_lib.root_module.addImport("katzensteg_build_options", default_preload_options.createModule());
    katzensteg_lib.root_module.strip = false;
    katzensteg_lib.root_module.omit_frame_pointer = false;
    if (is_macos) katzensteg_lib.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    katzensteg_lib.root_module.linkSystemLibrary("SDL2", .{});
    if (is_macos) {
        katzensteg_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_macos.c") });
        katzensteg_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_lib.root_module.linkFramework("Accelerate", .{});
        katzensteg_lib.root_module.linkFramework("OpenGL", .{});
    } else if (target.result.os.tag == .linux) {
        katzensteg_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_linux.c") });
        katzensteg_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_linux.c") });
        katzensteg_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl_linux.c") });
        katzensteg_lib.version_script = b.path("src/katzensteg/katzensteg_linux.map");
        katzensteg_lib.root_module.linkSystemLibrary("yuv", .{});
    }
    b.installArtifact(katzensteg_lib);
    if (dsym_step) |s| installDsym(b, katzensteg_lib, s);

    const katzensteg_unlinked_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "katzensteg-unlinked",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("src/katzensteg/preload.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_unlinked_lib.root_module.addImport("termscene", termscene_mod);
    katzensteg_unlinked_lib.root_module.addImport("katzensteg_sdl", katzensteg_sdl2_mod);
    katzensteg_unlinked_lib.root_module.addImport("katzensteg_build_options", default_preload_options.createModule());
    katzensteg_unlinked_lib.root_module.strip = false;
    katzensteg_unlinked_lib.root_module.omit_frame_pointer = false;
    katzensteg_unlinked_lib.linker_allow_shlib_undefined = true;
    if (is_macos) {
        katzensteg_unlinked_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_macos.c") });
        katzensteg_unlinked_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_unlinked_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
        katzensteg_unlinked_lib.root_module.linkFramework("Accelerate", .{});
        katzensteg_unlinked_lib.root_module.linkFramework("OpenGL", .{});
    } else if (target.result.os.tag == .linux) {
        katzensteg_unlinked_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        katzensteg_unlinked_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
        katzensteg_unlinked_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/interpose_linux.c") });
        katzensteg_unlinked_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_linux.c") });
        katzensteg_unlinked_lib.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl_linux.c") });
        katzensteg_unlinked_lib.version_script = b.path("src/katzensteg/katzensteg_linux.map");
        katzensteg_unlinked_lib.root_module.linkSystemLibrary("yuv", .{});
    }
    b.installArtifact(katzensteg_unlinked_lib);
    if (dsym_step) |s| installDsym(b, katzensteg_unlinked_lib, s);

    const basic_sdl_demo = b.addExecutable(.{
        .name = "basic-sdl-demo",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("examples/probes/sdl2/basic_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    basic_sdl_demo.root_module.addImport("katzensteg_sdl", katzensteg_sdl2_mod);
    // On Windows this links the import library, so the demo loads SDL2.dll
    // rather than static libSDL2.a.
    linkSdl(b, basic_sdl_demo.root_module, target, "SDL2", sdl2_prefix);
    b.installArtifact(basic_sdl_demo);
    sdl_dynapi_step.dependOn(&b.addInstallArtifact(basic_sdl_demo, .{}).step);
    const basic_sdl3_demo = b.addExecutable(.{
        .name = "basic-sdl3-demo",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("examples/probes/sdl3/basic_demo.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    basic_sdl3_demo.root_module.addImport("katzensteg_sdl", katzensteg_sdl3_mod);
    linkSdl(b, basic_sdl3_demo.root_module, target, "SDL3", windows_sdl_prefixes.sdl3);
    b.installArtifact(basic_sdl3_demo);
    sdl_dynapi_step.dependOn(&b.addInstallArtifact(basic_sdl3_demo, .{}).step);

    const katzensteg_input_probe = b.addExecutable(.{
        .name = "katzensteg-input-probe",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_input_probe.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl2/input_probe.c") });
    if (is_macos) {
        katzensteg_input_probe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
        katzensteg_input_probe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    katzensteg_input_probe.root_module.linkSystemLibrary("SDL2", .{});
    b.installArtifact(katzensteg_input_probe);

    const katzensteg_input_probe_sdl3 = b.addExecutable(.{
        .name = "katzensteg-input-probe-sdl3",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_input_probe_sdl3.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl3/input_probe.c") });
    if (is_macos) {
        katzensteg_input_probe_sdl3.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        katzensteg_input_probe_sdl3.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    katzensteg_input_probe_sdl3.root_module.linkSystemLibrary("SDL3", .{});
    b.installArtifact(katzensteg_input_probe_sdl3);
    const katzensteg_dlopen_probe_sdl3 = b.addExecutable(.{
        .name = "katzensteg-dlopen-probe-sdl3",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_dlopen_probe_sdl3.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl3/dlopen_probe.c") });
    if (is_macos) {
        katzensteg_dlopen_probe_sdl3.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    } else if (target.result.os.tag == .linux) {
        katzensteg_dlopen_probe_sdl3.root_module.addIncludePath(.{ .cwd_relative = "/usr/local/include" });
        katzensteg_dlopen_probe_sdl3.root_module.linkSystemLibrary("dl", .{});
    }
    b.installArtifact(katzensteg_dlopen_probe_sdl3);

    const katzensteg_gl_probe = b.addExecutable(.{
        .name = "katzensteg-gl-probe",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_gl_probe.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl2/gl_probe.c") });
    if (is_macos) {
        katzensteg_gl_probe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
        katzensteg_gl_probe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    katzensteg_gl_probe.root_module.linkSystemLibrary("SDL2", .{});
    if (is_macos) {
        katzensteg_gl_probe.root_module.linkFramework("OpenGL", .{});
    } else {
        katzensteg_gl_probe.root_module.linkSystemLibrary("GL", .{});
    }
    b.installArtifact(katzensteg_gl_probe);
    const katzensteg_gl_probe_sdl3 = b.addExecutable(.{
        .name = "katzensteg-gl-probe-sdl3",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_gl_probe_sdl3.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl3/gl_probe.c") });
    if (is_macos) {
        katzensteg_gl_probe_sdl3.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        katzensteg_gl_probe_sdl3.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    katzensteg_gl_probe_sdl3.root_module.linkSystemLibrary("SDL3", .{});
    if (is_macos) {
        katzensteg_gl_probe_sdl3.root_module.linkFramework("OpenGL", .{});
    } else {
        katzensteg_gl_probe_sdl3.root_module.linkSystemLibrary("GL", .{});
    }
    b.installArtifact(katzensteg_gl_probe_sdl3);

    var katzensteg_metal_probe: ?*std.Build.Step.Compile = null;
    var katzensteg_metal_probe_sdl3: ?*std.Build.Step.Compile = null;
    if (is_macos) {
        const probe = b.addExecutable(.{
            .name = "katzensteg-metal-probe",
            .use_llvm = use_llvm,
            .root_module = projectModule(b, .{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        probe.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl2/metal_probe.m") });
        probe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
        probe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        probe.root_module.linkSystemLibrary("SDL2", .{});
        probe.root_module.linkFramework("Foundation", .{});
        probe.root_module.linkFramework("Metal", .{});
        probe.root_module.linkFramework("QuartzCore", .{});
        b.installArtifact(probe);
        katzensteg_metal_probe = probe;

        const probe_sdl3 = b.addExecutable(.{
            .name = "katzensteg-metal-probe-sdl3",
            .use_llvm = use_llvm,
            .root_module = projectModule(b, .{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        probe_sdl3.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl3/metal_probe.m") });
        probe_sdl3.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        probe_sdl3.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        probe_sdl3.root_module.linkSystemLibrary("SDL3", .{});
        probe_sdl3.root_module.linkFramework("Foundation", .{});
        probe_sdl3.root_module.linkFramework("Metal", .{});
        probe_sdl3.root_module.linkFramework("QuartzCore", .{});
        b.installArtifact(probe_sdl3);
        katzensteg_metal_probe_sdl3 = probe_sdl3;
    }

    // luchs is macOS-only here (WKWebView capture helper) and is due to move
    // out of this repo; other targets do not build it.
    var install_luchs_step: ?*std.Build.Step = null;
    var install_luchs_helper_step: ?*std.Build.Step = null;
    if (is_macos) {
        const luchs = b.addExecutable(.{
            .name = "luchs",
            .use_llvm = use_llvm,
            .root_module = projectModule(b, .{
                .root_source_file = b.path("tools/luchs/src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        luchs.root_module.addImport("katzensteg_sdl", katzensteg_sdl2_mod);
        luchs.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        luchs.root_module.linkSystemLibrary("SDL2", .{});
        const install_luchs = b.addInstallArtifact(luchs, .{});
        b.getInstallStep().dependOn(&install_luchs.step);
        install_luchs_step = &install_luchs.step;
        if (builtin.os.tag == .macos) {
            const luchs_helper_cmd = b.addSystemCommand(&.{"swiftc"});
            luchs_helper_cmd.addArgs(&.{ "-O", "-parse-as-library", "-framework", "Cocoa", "-framework", "WebKit" });
            luchs_helper_cmd.addFileArg(b.path("tools/luchs/native/macos/LuchsWebviewCapture.swift"));
            luchs_helper_cmd.addArg("-o");
            const luchs_helper_bin = luchs_helper_cmd.addOutputFileArg("luchs-webview-capture");
            const install_luchs_helper = b.addInstallBinFile(luchs_helper_bin, "luchs-webview-capture");
            install_luchs_helper_step = &install_luchs_helper.step;
            b.getInstallStep().dependOn(&install_luchs_helper.step);
        }
    }

    if (enable_vulkan) {
        const katzensteg_vulkan_layer = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "katzensteg-vulkan-layer",
            .use_llvm = use_llvm,
            .root_module = projectModule(b, .{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        katzensteg_vulkan_layer.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/vulkan_layer.c") });
        katzensteg_vulkan_layer.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/env_scrub.c") });
        if (is_macos) katzensteg_vulkan_layer.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        b.installArtifact(katzensteg_vulkan_layer);

        const katzensteg_vulkan_probe = b.addExecutable(.{
            .name = "katzensteg-vulkan-probe",
            .use_llvm = use_llvm,
            .root_module = projectModule(b, .{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        katzensteg_vulkan_probe.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl2/vulkan_probe.c") });
        if (is_macos) {
            katzensteg_vulkan_probe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
            katzensteg_vulkan_probe.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
            katzensteg_vulkan_probe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        }
        katzensteg_vulkan_probe.root_module.linkSystemLibrary("SDL2", .{});
        katzensteg_vulkan_probe.root_module.linkSystemLibrary("vulkan", .{});
        b.installArtifact(katzensteg_vulkan_probe);

        const katzensteg_vulkan_probe_sdl3 = b.addExecutable(.{
            .name = "katzensteg-vulkan-probe-sdl3",
            .use_llvm = use_llvm,
            .root_module = projectModule(b, .{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        katzensteg_vulkan_probe_sdl3.root_module.addCSourceFile(.{ .file = b.path("examples/probes/sdl3/vulkan_probe.c") });
        if (is_macos) {
            katzensteg_vulkan_probe_sdl3.root_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
            katzensteg_vulkan_probe_sdl3.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        }
        katzensteg_vulkan_probe_sdl3.root_module.linkSystemLibrary("SDL3", .{});
        katzensteg_vulkan_probe_sdl3.root_module.linkSystemLibrary("vulkan", .{});
        b.installArtifact(katzensteg_vulkan_probe_sdl3);

        const katzensteg_vulkan_layer_build_step = b.step("katzensteg-vulkan-layer", "Build the Vulkan capture layer used by Katzensteg");
        katzensteg_vulkan_layer_build_step.dependOn(&katzensteg_vulkan_layer.step);

        const katzensteg_vulkan_probe_build_step = b.step("katzensteg-vulkan-probe", "Build the SDL2 Vulkan probe used for Katzensteg Vulkan capture work");
        katzensteg_vulkan_probe_build_step.dependOn(&katzensteg_vulkan_probe.step);
        const katzensteg_vulkan_probe_sdl3_build_step = b.step("katzensteg-vulkan-probe-sdl3", "Build the SDL3 Vulkan probe used for Katzensteg Vulkan capture work");
        katzensteg_vulkan_probe_sdl3_build_step.dependOn(&katzensteg_vulkan_probe_sdl3.step);

        const katzensteg_vulkan_probe_cmd = b.addRunArtifact(katzensteg_vulkan_probe);
        if (b.args) |args| katzensteg_vulkan_probe_cmd.addArgs(args);
        const katzensteg_vulkan_probe_step = b.step("run-katzensteg-vulkan-probe", "Run the SDL2 Vulkan probe used for Katzensteg Vulkan capture work");
        katzensteg_vulkan_probe_step.dependOn(&katzensteg_vulkan_probe_cmd.step);
        const katzensteg_vulkan_probe_sdl3_cmd = b.addRunArtifact(katzensteg_vulkan_probe_sdl3);
        if (b.args) |args| katzensteg_vulkan_probe_sdl3_cmd.addArgs(args);
        const katzensteg_vulkan_probe_sdl3_step = b.step("run-katzensteg-vulkan-probe-sdl3", "Run the SDL3 Vulkan probe used for Katzensteg Vulkan capture work");
        katzensteg_vulkan_probe_sdl3_step.dependOn(&katzensteg_vulkan_probe_sdl3_cmd.step);
    }

    const katzensteg_launcher = b.addExecutable(.{
        .name = "katzensteg",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("src/katzensteg/launcher.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_launcher.root_module.addImport("termscene", termscene_mod);
    b.installArtifact(katzensteg_launcher);
    sdl_dynapi_step.dependOn(&b.addInstallArtifact(katzensteg_launcher, .{}).step);
    const katzensteg_wm = b.addExecutable(.{
        .name = "katzensteg-wm",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path("src/katzensteg/wm/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    katzensteg_wm.root_module.addImport("termscene", termscene_mod);
    const katzensteg_wm_host_mod = projectModule(b, .{
        .root_source_file = b.path("src/katzensteg/wm_host.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    katzensteg_wm_host_mod.addImport("termscene", termscene_mod);
    katzensteg_wm_host_mod.addImport("xev", xev_mod);
    katzensteg_wm.root_module.addImport("wm_host", katzensteg_wm_host_mod);
    b.installArtifact(katzensteg_wm);
    const katzensteg_proxy = b.addExecutable(.{
        .name = "katzensteg-proxy",
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
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
        .root_module = projectModule(b, .{
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
    const basic_sdl3_demo_cmd = b.addRunArtifact(basic_sdl3_demo);
    if (b.args) |args| basic_sdl3_demo_cmd.addArgs(args);
    const basic_sdl3_demo_step = b.step("basic-sdl3-demo", "Run the basic SDL3 demo used for Katzensteg bring-up");
    basic_sdl3_demo_step.dependOn(&basic_sdl3_demo_cmd.step);

    const katzensteg_input_probe_build_step = b.step("katzensteg-input-probe", "Build the SDL2 input probe used for Katzensteg input injection work");
    katzensteg_input_probe_build_step.dependOn(&katzensteg_input_probe.step);
    const katzensteg_input_probe_sdl3_build_step = b.step("katzensteg-input-probe-sdl3", "Build the SDL3 input probe used for Katzensteg input injection work");
    katzensteg_input_probe_sdl3_build_step.dependOn(&katzensteg_input_probe_sdl3.step);
    const katzensteg_dlopen_probe_sdl3_build_step = b.step("katzensteg-dlopen-probe-sdl3", "Build the SDL3 dlopen probe used for Katzensteg dynamic SDL loading coverage");
    katzensteg_dlopen_probe_sdl3_build_step.dependOn(&katzensteg_dlopen_probe_sdl3.step);

    const katzensteg_input_probe_cmd = b.addRunArtifact(katzensteg_input_probe);
    if (b.args) |args| katzensteg_input_probe_cmd.addArgs(args);
    const katzensteg_input_probe_step = b.step("run-katzensteg-input-probe", "Run the SDL2 input probe used for Katzensteg input injection work");
    katzensteg_input_probe_step.dependOn(&katzensteg_input_probe_cmd.step);
    const katzensteg_input_probe_sdl3_cmd = b.addRunArtifact(katzensteg_input_probe_sdl3);
    if (b.args) |args| katzensteg_input_probe_sdl3_cmd.addArgs(args);
    const katzensteg_input_probe_sdl3_step = b.step("run-katzensteg-input-probe-sdl3", "Run the SDL3 input probe used for Katzensteg input injection work");
    katzensteg_input_probe_sdl3_step.dependOn(&katzensteg_input_probe_sdl3_cmd.step);
    const katzensteg_dlopen_probe_sdl3_cmd = b.addRunArtifact(katzensteg_dlopen_probe_sdl3);
    if (b.args) |args| katzensteg_dlopen_probe_sdl3_cmd.addArgs(args);
    const katzensteg_dlopen_probe_sdl3_step = b.step("run-katzensteg-dlopen-probe-sdl3", "Run the SDL3 dlopen probe used for Katzensteg dynamic SDL loading coverage");
    katzensteg_dlopen_probe_sdl3_step.dependOn(&katzensteg_dlopen_probe_sdl3_cmd.step);

    const katzensteg_gl_probe_build_step = b.step("katzensteg-gl-probe", "Build the SDL2 OpenGL probe used for Katzensteg GL capture work");
    katzensteg_gl_probe_build_step.dependOn(&katzensteg_gl_probe.step);
    const katzensteg_gl_probe_sdl3_build_step = b.step("katzensteg-gl-probe-sdl3", "Build the SDL3 OpenGL probe used for Katzensteg GL capture work");
    katzensteg_gl_probe_sdl3_build_step.dependOn(&katzensteg_gl_probe_sdl3.step);
    if (katzensteg_metal_layer_install_step) |install_step| {
        const katzensteg_metal_layer_build_step = b.step("katzensteg-metal-layer", "Build the Metal capture layer used by Katzensteg");
        katzensteg_metal_layer_build_step.dependOn(install_step);
    }
    if (katzensteg_metal_probe) |probe| {
        const katzensteg_metal_probe_build_step = b.step("katzensteg-metal-probe", "Build the SDL2 Metal probe used for Katzensteg Metal capture work");
        katzensteg_metal_probe_build_step.dependOn(&probe.step);
    }
    if (katzensteg_metal_probe_sdl3) |probe| {
        const katzensteg_metal_probe_sdl3_build_step = b.step("katzensteg-metal-probe-sdl3", "Build the SDL3 Metal probe used for Katzensteg Metal capture work");
        katzensteg_metal_probe_sdl3_build_step.dependOn(&probe.step);
    }

    const katzensteg_gl_probe_cmd = b.addRunArtifact(katzensteg_gl_probe);
    if (b.args) |args| katzensteg_gl_probe_cmd.addArgs(args);
    const katzensteg_gl_probe_step = b.step("run-katzensteg-gl-probe", "Run the SDL2 OpenGL probe used for Katzensteg GL capture work");
    katzensteg_gl_probe_step.dependOn(&katzensteg_gl_probe_cmd.step);
    const katzensteg_gl_probe_sdl3_cmd = b.addRunArtifact(katzensteg_gl_probe_sdl3);
    if (b.args) |args| katzensteg_gl_probe_sdl3_cmd.addArgs(args);
    const katzensteg_gl_probe_sdl3_step = b.step("run-katzensteg-gl-probe-sdl3", "Run the SDL3 OpenGL probe used for Katzensteg GL capture work");
    katzensteg_gl_probe_sdl3_step.dependOn(&katzensteg_gl_probe_sdl3_cmd.step);
    if (katzensteg_metal_probe) |probe| {
        const katzensteg_metal_probe_cmd = b.addRunArtifact(probe);
        if (b.args) |args| katzensteg_metal_probe_cmd.addArgs(args);
        const katzensteg_metal_probe_step = b.step("run-katzensteg-metal-probe", "Run the SDL2 Metal probe used for Katzensteg Metal capture work");
        katzensteg_metal_probe_step.dependOn(&katzensteg_metal_probe_cmd.step);
    }
    if (katzensteg_metal_probe_sdl3) |probe| {
        const katzensteg_metal_probe_sdl3_cmd = b.addRunArtifact(probe);
        if (b.args) |args| katzensteg_metal_probe_sdl3_cmd.addArgs(args);
        const katzensteg_metal_probe_sdl3_step = b.step("run-katzensteg-metal-probe-sdl3", "Run the SDL3 Metal probe used for Katzensteg Metal capture work");
        katzensteg_metal_probe_sdl3_step.dependOn(&katzensteg_metal_probe_sdl3_cmd.step);
    }

    if (install_luchs_step) |install_step| {
        const luchs_build_step = b.step("luchs", "Build the SDL-backed web fragment viewer");
        luchs_build_step.dependOn(install_step);
        if (install_luchs_helper_step) |step| luchs_build_step.dependOn(step);
    }

    addUnitTest(b, test_step, "termscene-shared-memory-test", "src/termscene/kitty/shared_memory.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    addUnitTest(b, test_step, "termscene-profile-test", "src/termscene/kitty_tests.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    addUnitTest(b, test_step, "termscene-protocol-test", "src/termscene/kitty/protocol.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-config-test", "src/katzensteg/config.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-log-test", "src/katzensteg/log.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-render-batch-protocol-test", "src/katzensteg/render_batch_protocol.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-attach-protocol-test", "src/katzensteg/attach_protocol.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-terminal-batch-applier-test", "src/katzensteg/terminal_batch_applier.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-wm-command-input-test", "src/katzensteg/wm_command_input.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-wm-host-test", "src/katzensteg/wm_host.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
        .xev = xev_mod,
        .link_libc = true,
    });
    addUnitTest(b, test_step, "katzensteg-render-batch-sink-test", "src/katzensteg/render_batch_sink.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
    });
    addUnitTest(b, test_step, "katzensteg-frame-builder-test", "src/katzensteg/frame_builder.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
        .katzensteg_sdl = katzensteg_sdl2_mod,
        .link_libc = true,
    });
    addUnitTest(b, test_step, "katzensteg-runtime-test", "src/katzensteg/runtime.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
        .katzensteg_sdl = katzensteg_sdl2_mod,
        .link_libc = true,
        .link_sdl2 = true,
    });
    addUnitTest(b, test_step, "katzensteg-sdl2-input-adapter-test", "src/katzensteg/sdl2_input_adapter.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
        .katzensteg_sdl = katzensteg_sdl2_mod,
        .katzensteg_build_options = test_preload_options.createModule(),
        .link_libc = true,
        .link_sdl2 = true,
    });
    addUnitTest(b, test_step, "katzensteg-sdl3-input-adapter-test", "src/katzensteg/sdl3_input_adapter.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
        .katzensteg_sdl = katzensteg_sdl3_mod,
        .katzensteg_build_options = test_preload_options.createModule(),
        .link_libc = true,
        .link_sdl3 = true,
    });
    addUnitTest(b, test_step, "katzensteg-preload-test", "src/katzensteg/preload.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
        .katzensteg_sdl = katzensteg_sdl2_mod,
        .katzensteg_build_options = test_preload_options.createModule(),
        .link_libc = true,
        .link_sdl2 = true,
        .link_opengl = true,
    });
    addUnitTest(b, test_step, "katzensteg-launcher-profiles-test", "src/katzensteg/launcher_profiles.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-launcher-context-test", "src/katzensteg/launcher/context.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-launcher-injection-test", "src/katzensteg/launcher/injection.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-dynapi-test", "src/katzensteg/dynapi.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    addUnitTest(b, test_step, "katzensteg-launcher-destination-test", "src/katzensteg/launcher/destination.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    addUnitTest(b, test_step, "katzensteg-wm-cli-test", "src/katzensteg/wm/cli.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-wm-client-test", "src/katzensteg/wm/client.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    addUnitTest(b, test_step, "katzensteg-wm-listener-test", "src/katzensteg/wm/listener.zig", target, optimize, use_llvm, test_library_dir, .{ .link_libc = true });
    addUnitTest(b, test_step, "katzensteg-wm-event-test", "src/katzensteg/wm/event.zig", target, optimize, use_llvm, test_library_dir, .{});
    addUnitTest(b, test_step, "katzensteg-attach-host-test", "src/katzensteg/attach_host.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
        .link_libc = true,
    });
    addUnitTest(b, test_step, "katzensteg-launcher-test", "src/katzensteg/launcher.zig", target, optimize, use_llvm, test_library_dir, .{
        .termscene = termscene_mod,
    });
    if (is_macos) addUnitTest(b, test_step, "luchs-test", "tools/luchs/src/main.zig", target, optimize, use_llvm, test_library_dir, .{
        .katzensteg_sdl = katzensteg_sdl2_mod,
        .link_sdl2 = true,
    });
}

/// Windows has no system SDL; tests link the development packages given with
/// -Dsdl2-prefix / -Dsdl3-prefix and run with their bin/ on PATH.
var windows_sdl_prefixes: struct { sdl2: ?[]const u8 = null, sdl3: ?[]const u8 = null } = .{};

fn linkSdl(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, name: []const u8, prefix: ?[]const u8) void {
    if (target.result.os.tag == .windows and prefix != null) {
        module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix.?, "lib", b.fmt("lib{s}.dll.a", .{name}) }) });
        return;
    }
    if (target.result.os.tag == .macos) module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    module.linkSystemLibrary(name, .{});
}

const UnitTestOptions = struct {
    termscene: ?*std.Build.Module = null,
    xev: ?*std.Build.Module = null,
    katzensteg_sdl: ?*std.Build.Module = null,
    katzensteg_build_options: ?*std.Build.Module = null,
    link_libc: bool = false,
    link_sdl2: bool = false,
    link_sdl3: bool = false,
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
    test_library_dir: ?[]const u8,
    options: UnitTestOptions,
) void {
    const unit_test = b.addTest(.{
        .name = name,
        .use_llvm = use_llvm,
        .root_module = projectModule(b, .{
            .root_source_file = b.path(root_source_file),
            .target = target,
            .optimize = optimize,
            .link_libc = options.link_libc,
        }),
    });
    // Test executables run from Zig's cache, outside the installed bin/lib tree.
    if (test_library_dir) |dir| unit_test.root_module.addRPath(.{ .cwd_relative = dir });
    if (options.termscene) |mod| unit_test.root_module.addImport("termscene", mod);
    if (options.xev) |mod| unit_test.root_module.addImport("xev", mod);
    if (options.katzensteg_sdl) |mod| unit_test.root_module.addImport("katzensteg_sdl", mod);
    if (options.katzensteg_build_options) |mod| unit_test.root_module.addImport("katzensteg_build_options", mod);
    if (options.link_sdl2) linkSdl(b, unit_test.root_module, target, "SDL2", windows_sdl_prefixes.sdl2);
    if (options.link_sdl3) linkSdl(b, unit_test.root_module, target, "SDL3", windows_sdl_prefixes.sdl3);
    if (options.link_opengl) {
        if (target.result.os.tag == .macos) {
            unit_test.root_module.linkFramework("OpenGL", .{});
        } else if (target.result.os.tag == .linux) {
            unit_test.root_module.linkSystemLibrary("GL", .{});
        } else if (target.result.os.tag == .windows) {
            unit_test.root_module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_sdl.c"), .flags = &.{"-DKS_GL_VIA_LINKED_SDL"} });
        }
    }
    const run_unit_test = b.addRunArtifact(unit_test);
    if (target.result.os.tag == .windows) {
        if (options.link_sdl2) if (windows_sdl_prefixes.sdl2) |prefix| run_unit_test.addPathDir(b.pathJoin(&.{ prefix, "bin" }));
        if (options.link_sdl3) if (windows_sdl_prefixes.sdl3) |prefix| run_unit_test.addPathDir(b.pathJoin(&.{ prefix, "bin" }));
    }
    test_step.dependOn(&run_unit_test.step);
}

/// Install a UUID-matched `<dylib>.dSYM` next to the dylib for Instruments/lldb; wired into both the default install and the `katzensteg-dsym` step.
fn installDsym(b: *std.Build, lib: *std.Build.Step.Compile, dsym_step: *std.Build.Step) void {
    const bundle_name = b.fmt("{s}.dSYM", .{lib.out_filename});
    const dsym_cmd = b.addSystemCommand(&.{"dsymutil"});
    dsym_cmd.addFileArg(lib.getEmittedBin());
    dsym_cmd.addArg("-o");
    const dsym_out = dsym_cmd.addOutputDirectoryArg(bundle_name);
    const install_dsym = b.addInstallDirectory(.{
        .source_dir = dsym_out,
        .install_dir = .lib,
        .install_subdir = bundle_name,
    });
    b.getInstallStep().dependOn(&install_dsym.step);
    dsym_step.dependOn(&install_dsym.step);
}

/// The dynamic API entry point and jump-table backend for one SDL major
/// version, GL resolution through the loading SDL, and the platform's image
/// fast paths.
fn addDynapiSources(b: *std.Build, lib: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, glue: []const u8) void {
    const module = lib.root_module;
    module.addCSourceFile(.{ .file = b.path(b.fmt("src/katzensteg/{s}", .{glue})) });
    if (std.mem.eql(u8, glue, "dynapi_sdl3.c")) module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_sdl3_compat.c") });
    switch (target.result.os.tag) {
        .macos => {
            module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_macos.c") });
            module.linkFramework("Accelerate", .{});
            module.linkFramework("OpenGL", .{});
        },
        .linux => {
            module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_sdl.c") });
            module.addCSourceFile(.{ .file = b.path("src/katzensteg/image_fastpath_portable.c") });
            module.linkSystemLibrary("yuv", .{});
        },
        else => module.addCSourceFile(.{ .file = b.path("src/katzensteg/real_gl_sdl.c") }),
    }
}

fn projectModule(b: *std.Build, options: std.Build.Module.CreateOptions) *std.Build.Module {
    const module = b.createModule(options);
    if (options.root_source_file != null) {
        module.addImport("platform", b.modules.get("platform").?);
        module.addImport("jackstay", b.modules.get("jackstay").?);
    }
    // The platform adapters and C interposers use libc and pthread APIs.
    module.link_libc = true;
    return module;
}
