import pathlib
import platform
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
    "SDL_PollEvent",
    "SDL_PeepEvents",
    "SDL_GetKeyboardState",
    "SDL_GetMouseState",
    "SDL_GetRelativeMouseState",
    "SDL_UpperBlit",
    "dlopen",
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
        return ROOT / "zig-out" / "lib" / "libkatzensteg-unlinked.so"

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

    @unittest.skipUnless(platform.system() == "Linux", "Linux ELF preload export test")
    def test_unlinked_preload_exports_linux_sdl_interpose_symbols(self):
        lib_path = self.preload_path()
        self.assertTrue(
            lib_path.exists(),
            f"{lib_path} does not exist; run `zig build -Dvulkan=false` first",
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
            f"{lib_path} does not exist; run `zig build -Dvulkan=false` first",
        )

        needed = needed_libraries(lib_path)
        self.assertNotIn("libGL.so.1", needed)

    @unittest.skipUnless(platform.system() == "Linux", "Linux ELF preload dependency test")
    def test_unlinked_preload_uses_system_libyuv_for_portable_fast_paths(self):
        lib_path = self.preload_path()
        self.assertTrue(
            lib_path.exists(),
            f"{lib_path} does not exist; run `zig build -Dvulkan=false` first",
        )

        needed = needed_libraries(lib_path)
        self.assertIn("libyuv.so", needed)


if __name__ == "__main__":
    unittest.main()
