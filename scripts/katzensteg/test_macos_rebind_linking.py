import pathlib
import re
import subprocess
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "macOS-only Mach-O linking checks")
class MacosRebindLinkingTests(unittest.TestCase):
    def rebind_path(self):
        return ROOT / "zig-out" / "lib" / "libkatzensteg-sdl2-rebind.dylib"

    def legacy_path(self):
        return ROOT / "zig-out" / "lib" / "libkatzensteg-sdl2.dylib"

    def otool_l(self, path):
        return subprocess.check_output(["otool", "-L", str(path)], text=True)

    def nm_undefined(self, path):
        return subprocess.check_output(["nm", "-u", str(path)], text=True)

    def test_rebind_artifact_exists(self):
        self.assertTrue(self.rebind_path().exists())

    def test_rebind_artifact_does_not_load_sdl2(self):
        self.assertNotIn("libSDL2", self.otool_l(self.rebind_path()))

    def test_rebind_artifact_has_no_undefined_sdl_symbols(self):
        undefined = self.nm_undefined(self.rebind_path())
        self.assertIsNone(re.search(r"\b_SDL_", undefined))

    def test_legacy_sdl2_artifact_remains_available_alongside_rebind(self):
        self.assertTrue(self.legacy_path().exists())
        output = self.otool_l(self.legacy_path())
        self.assertIn("libkatzensteg-sdl2.dylib", output)


if __name__ == "__main__":
    unittest.main()
