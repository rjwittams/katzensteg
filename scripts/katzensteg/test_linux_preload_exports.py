import pathlib
import platform
import json
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]

EXPECTED_EXPORTED_DEFINITIONS = {
    "SDL_Init",
    "SDL_InitSubSystem",
    "SDL_SetHint",
    "SDL_QuitSubSystem",
    "SDL_Quit",
    "SDL_CreateWindow",
    "SDL_GetWindowFlags",
    "SDL_ShowWindow",
    "SDL_HideWindow",
    "SDL_MinimizeWindow",
    "SDL_RestoreWindow",
    "SDL_RaiseWindow",
    "SDL_DestroyWindow",
    "SDL_CreateRenderer",
    "SDL_GetRendererInfo",
    "SDL_DestroyRenderer",
    "SDL_CreateTexture",
    "SDL_CreateTextureFromSurface",
    "SDL_DestroyTexture",
    "SDL_UpdateTexture",
    "SDL_UpdateYUVTexture",
    "SDL_UpdateNVTexture",
    "SDL_LockTexture",
    "SDL_UnlockTexture",
    "SDL_SetTextureColorMod",
    "SDL_SetTextureAlphaMod",
    "SDL_SetTextureBlendMode",
    "SDL_SetRenderDrawColor",
    "SDL_RenderClear",
    "SDL_RenderCopy",
    "SDL_RenderCopyEx",
    "SDL_RenderGeometryRaw",
    "SDL_RenderPresent",
    "SDL_RenderFillRect",
    "SDL_RenderDrawPoint",
    "SDL_RenderDrawLine",
    "SDL_RenderSetViewport",
    "SDL_RenderSetClipRect",
    "SDL_GL_CreateContext",
    "SDL_GL_MakeCurrent",
    "SDL_GL_SwapWindow",
    "SDL_Vulkan_LoadLibrary",
    "SDL_PumpEvents",
    "SDL_PollEvent",
    "SDL_PeepEvents",
    "SDL_GetKeyboardState",
    "SDL_GetMouseState",
    "SDL_GetRelativeMouseState",
    "SDL_UpperBlit",
    "SDL_CreateColorCursor",
    "SDL_SetCursor",
    "SDL_ShowCursor",
    "SDL_FreeCursor",
    "dlopen",
    "ks_katzensteg_shutdown",
    "ks_katzensteg_log_c",
    "ks_katzensteg_present_external_framebuffer",
    "ks_katzensteg_present_external_rgba",
}

EXPECTED_CORE_EXPORTED_DEFINITIONS = {
    "ks_katzensteg_shutdown",
    "ks_katzensteg_log_c",
    "ks_katzensteg_present_external_framebuffer",
    "ks_katzensteg_present_external_rgba",
}


def dynsym_lines(output):
    in_dynsym = False
    for line in output.splitlines():
        if line.startswith("Symbol table '.dynsym'"):
            in_dynsym = True
            continue
        if in_dynsym and line.startswith("Symbol table "):
            return
        if in_dynsym:
            stripped = line.strip()
            if stripped and stripped[0].isdigit():
                yield line


def symbol_name(line):
    name = line.rsplit(maxsplit=1)[-1]
    return name.split("@", maxsplit=1)[0]


def needed_libraries(lib_path):
    output = subprocess.check_output(
        ["readelf", "-dW", str(lib_path)],
        text=True,
    )
    return [
        line.split("[", maxsplit=1)[1].split("]", maxsplit=1)[0]
        for line in output.splitlines()
        if "(NEEDED)" in line
    ]


class LinuxPreloadExportsTests(unittest.TestCase):
    def preload_path(self):
        return ROOT / "zig-out" / "lib" / "libkatzensteg-sdl2.so"

    def core_path(self):
        return ROOT / "zig-out" / "lib" / "libkatzensteg-core.so"

    def test_build_declares_core_and_sdl2_adapter_artifacts(self):
        build_text = (ROOT / "build.zig").read_text()

        for artifact in (
            '.name = "katzensteg-core"',
            '.name = "katzensteg-sdl2"',
        ):
            with self.subTest(artifact=artifact):
                self.assertIn(artifact, build_text)

    def test_sdl2_profile_fragment_points_at_sdl2_adapter_library(self):
        retroarch = json.loads((ROOT / "profiles" / "retroarch.json").read_text())
        fragment = retroarch["profiles"]["adapter.sdl2_preload"]
        env = fragment["env"]

        self.assertEqual(
            "{repo}/zig-out/lib/libkatzensteg-sdl2.dylib",
            env["DYLD_INSERT_LIBRARIES"],
        )
        self.assertEqual(
            "{repo}/zig-out/lib/libkatzensteg-sdl2.so",
            env["LD_PRELOAD"],
        )

    def test_core_exports_are_defined_outside_sdl2_preload_source(self):
        preload_source = ROOT / "src" / "katzensteg" / "preload.zig"
        core_exports_source = ROOT / "src" / "katzensteg" / "core_exports.zig"

        self.assertTrue(core_exports_source.exists())
        preload_text = preload_source.read_text()
        core_exports_text = core_exports_source.read_text()

        for symbol in (
            "ks_katzensteg_shutdown",
            "ks_katzensteg_present_external_rgba",
            "ks_katzensteg_present_external_framebuffer",
        ):
            with self.subTest(symbol=symbol):
                self.assertNotIn(f"pub export fn {symbol}", preload_text)
                self.assertIn(f"pub export fn {symbol}", core_exports_text)

    def test_core_sources_do_not_import_sdl2_or_real_sdl(self):
        for path in (
            ROOT / "src" / "katzensteg" / "core_exports.zig",
            ROOT / "src" / "katzensteg" / "core_commands.zig",
            ROOT / "src" / "katzensteg" / "core_command_dispatch.zig",
            ROOT / "src" / "katzensteg" / "runtime.zig",
            ROOT / "src" / "katzensteg" / "frame_builder.zig",
            ROOT / "src" / "katzensteg" / "input.zig",
        ):
            text = path.read_text()
            for needle in (
                '@import("katzensteg_sdl")',
                '@import("real_sdl.zig")',
            ):
                with self.subTest(path=path.relative_to(ROOT), needle=needle):
                    self.assertNotIn(needle, text)

    def test_runtime_policy_and_lock_helpers_do_not_expose_sdl_pointer_types(self):
        runtime_text = (ROOT / "src" / "katzensteg" / "runtime.zig").read_text()

        forbidden = (
            "terminalRenderingEnabled(self: *const Runtime, window:",
            "realRenderEnabled(self: *const Runtime, window:",
            "realWindowEnabled(self: *const Runtime, window:",
            "realWindowCreateAction(self: *const Runtime, window:",
            "realWindowShowAction(self: *const Runtime, window:",
            "realWindowRestoreAction(self: *const Runtime, window:",
            "shouldCaptureExternalFrame(self: *Runtime, window:",
            "rememberQueuedLock(self: *Runtime, texture: ?*@import(\"katzensteg_sdl\").SDL_Texture",
            "takeQueuedLock(self: *Runtime, texture: ?*@import(\"katzensteg_sdl\").SDL_Texture",
        )
        for needle in forbidden:
            with self.subTest(needle=needle):
                self.assertNotIn(needle, runtime_text)

    def test_runtime_does_not_own_sdl_event_adapter_functions(self):
        runtime_text = (ROOT / "src" / "katzensteg" / "runtime.zig").read_text()
        adapter_text = (ROOT / "src" / "katzensteg" / "sdl2_input_adapter.zig").read_text()

        runtime_forbidden = (
            "popSdlInputEvent",
            "popSdlInputEventInRange",
            "noteRealSdlEvent",
            "mergedKeyboardState",
            "claimedWindowFlags",
            "shouldSuppressSdlEvent",
            "fillSdlEvent",
            "eventIsMouse",
            "applyClaimedInputWindowFlags",
            "shouldSuppressClaimedWindowEvent",
        )
        for needle in runtime_forbidden:
            with self.subTest(needle=needle):
                self.assertNotIn(needle, runtime_text)

        for symbol in (
            "popInputEvent",
            "popInputEventInRange",
            "noteRealEvent",
            "mergedKeyboardState",
            "claimedWindowFlags",
            "shouldSuppressEvent",
        ):
            with self.subTest(symbol=symbol):
                self.assertIn(symbol, adapter_text)

    @unittest.skipUnless(platform.system() == "Linux", "Linux ELF core export test")
    def test_core_library_exports_core_abi_symbols(self):
        lib_path = self.core_path()
        self.assertTrue(
            lib_path.exists(),
            f"{lib_path} does not exist; run `zig build` first",
        )

        output = subprocess.check_output(
            ["readelf", "-Ws", str(lib_path)],
            text=True,
        )

        exported_definitions = {
            symbol_name(line)
            for line in dynsym_lines(output)
            if " UND " not in line and " GLOBAL " in line
        }
        self.assertEqual(EXPECTED_CORE_EXPORTED_DEFINITIONS, exported_definitions)

    @unittest.skipUnless(platform.system() == "Linux", "Linux ELF preload export test")
    def test_unlinked_preload_exports_linux_sdl_interpose_symbols(self):
        lib_path = self.preload_path()
        self.assertTrue(
            lib_path.exists(),
            f"{lib_path} does not exist; run `zig build` first",
        )

        output = subprocess.check_output(
            ["readelf", "-Ws", str(lib_path)],
            text=True,
        )

        for symbol in (
            "SDL_CreateWindow",
            "SDL_RenderPresent",
            "SDL_PollEvent",
            "dlopen",
        ):
            with self.subTest(symbol=symbol):
                matches = [line for line in dynsym_lines(output) if symbol_name(line) == symbol]
                self.assertTrue(matches, f"{symbol} is missing from the symbol table")
                self.assertTrue(
                    any(" UND " not in line for line in matches),
                    f"{symbol} is not exported as a Katzensteg definition: {matches}",
                )

        unresolved_sdl = [
            line
            for line in dynsym_lines(output)
            if " UND " in line and line.rsplit(maxsplit=1)[-1].startswith("SDL_")
        ]
        self.assertEqual([], unresolved_sdl)

        unresolved_ks = [
            line
            for line in dynsym_lines(output)
            if " UND " in line and line.rsplit(maxsplit=1)[-1].startswith("ks_")
        ]
        self.assertEqual([], unresolved_ks)

        exported_definitions = {
            symbol_name(line)
            for line in dynsym_lines(output)
            if " UND " not in line and " GLOBAL " in line
        }
        self.assertEqual(EXPECTED_EXPORTED_DEFINITIONS, exported_definitions)

    @unittest.skipUnless(platform.system() == "Linux", "Linux ELF preload dependency test")
    def test_unlinked_preload_does_not_need_libgl(self):
        lib_path = self.preload_path()
        self.assertTrue(
            lib_path.exists(),
            f"{lib_path} does not exist; run `zig build` first",
        )

        needed = needed_libraries(lib_path)
        self.assertNotIn("libGL.so.1", needed)

    @unittest.skipUnless(platform.system() == "Linux", "Linux ELF preload dependency test")
    def test_unlinked_preload_uses_system_libyuv_for_portable_fast_paths(self):
        lib_path = self.preload_path()
        self.assertTrue(
            lib_path.exists(),
            f"{lib_path} does not exist; run `zig build` first",
        )

        needed = needed_libraries(lib_path)
        self.assertTrue(
            any(name.startswith("libyuv.so") for name in needed),
            f"expected a libyuv.so* NEEDED entry; got: {needed}",
        )


if __name__ == "__main__":
    unittest.main()
