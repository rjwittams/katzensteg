"""Exercise caller-relative lookup through the built macOS preload libraries."""
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "macOS-only loader checks")
class MacosDlopenTests(unittest.TestCase):
    def test_caller_search_paths_and_vulkan_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            caller = root / "caller"
            deps = caller / "deps"
            deps.mkdir(parents=True)
            (root / "leaf.c").write_text("int value(void) { return 42; }\n")
            (root / "caller.c").write_text('''
#include <dlfcn.h>
#include <stdio.h>
int load_requested(const char *path) {
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "%s\\n", dlerror()); return 1; }
    int (*value)(void) = dlsym(handle, "value");
    int result = !value || value() != 42;
    dlclose(handle);
    return result;
}
''')
            (root / "main.c").write_text('''
extern int load_requested(const char *);
int main(int argc, char **argv) { return argc == 2 ? load_requested(argv[1]) : 2; }
''')
            def compile(*args):
                subprocess.run(["clang", "-O0", *map(str, args)], check=True, capture_output=True)

            leaf = deps / "libks-loader-test.dylib"
            compile("-dynamiclib", root / "leaf.c", "-o", leaf)
            sibling = caller / "libks-loader-sibling.dylib"
            compile("-dynamiclib", root / "leaf.c", "-o", sibling)
            library = caller / "libcaller.dylib"
            compile("-dynamiclib", root / "caller.c", "-Wl,-rpath,@loader_path/deps", "-o", library)
            executable = root / "probe"
            compile(root / "main.c", library, "-o", executable)
            for adapter in (None, "sdl2", "sdl3", "sdl2-rebind"):
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(("DYLD_", "KATZENSTEG_"))}
                if adapter:
                    preload = ROOT / "zig-out" / "lib" / f"libkatzensteg-{adapter}.dylib"
                    self.assertTrue(preload.exists(), f"Run zig build first: {preload}")
                    sdl = "sdl3" if adapter == "sdl3" else "sdl2"
                    libdir = subprocess.check_output(
                        ["pkg-config", "--variable=libdir", sdl], text=True).strip()
                    sdl_library = pathlib.Path(libdir) / ("libSDL3.dylib" if sdl == "sdl3" else "libSDL2.dylib")
                    env["DYLD_INSERT_LIBRARIES"] = f"{preload}:{sdl_library}"
                    # Allow sdl2-compat itself to start even with the broken hook.
                    # The fixture libraries exist only in the caller's directory.
                    env["DYLD_FALLBACK_LIBRARY_PATH"] = subprocess.check_output(
                        ["pkg-config", "--variable=libdir", "sdl3"], text=True).strip()
                cases = ["@loader_path/libks-loader-sibling.dylib",
                         "@rpath/libks-loader-test.dylib", "libks-loader-test.dylib",
                         str(leaf)]
                if adapter:
                    env["KATZENSTEG_VULKAN_LOADER"] = str(leaf)
                    cases.append("libvulkan.dylib")
                for path in cases:
                    with self.subTest(adapter=adapter, path=path):
                        result = subprocess.run([str(executable), path], env=env,
                                                capture_output=True, text=True, timeout=5)
                        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
