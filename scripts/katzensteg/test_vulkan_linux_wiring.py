import json
import pathlib
import platform
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST_PATH = ROOT / "profiles" / "VK_LAYER_KATZENSTEG_capture.json"
RUNNER_PATH = ROOT / "scripts" / "katzensteg" / "run-vulkan-probe.sh"
RETROARCH_RUNNER_PATH = ROOT / "scripts" / "katzensteg" / "run-retroarch-vulkan.sh"

EXPECTED_VULKAN_LAYER_EXPORTS = {
    "vkNegotiateLoaderLayerInterfaceVersion",
    "vkGetInstanceProcAddr",
    "vkGetDeviceProcAddr",
    "vkEnumerateInstanceLayerProperties",
    "vkEnumerateInstanceExtensionProperties",
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


class VulkanLinuxWiringTests(unittest.TestCase):
    def test_layer_manifest_points_to_linux_shared_object_on_linux(self):
        if platform.system() != "Linux":
            self.skipTest("Linux Vulkan manifest path test")

        manifest = json.loads(MANIFEST_PATH.read_text())

        self.assertEqual(
            "../zig-out/lib/libkatzensteg-vulkan-layer.so",
            manifest["layer"]["library_path"],
        )

    def test_vulkan_probe_runner_uses_linux_preload_defaults_on_linux(self):
        if platform.system() != "Linux":
            self.skipTest("Linux Vulkan runner defaults test")

        script = RUNNER_PATH.read_text()

        self.assertIn("Linux)", script)
        self.assertIn("Darwin)", script)
        self.assertIn("libkatzensteg-unlinked.so", script)
        self.assertIn("libkatzensteg-vulkan-layer.so", script)
        self.assertIn('LD_PRELOAD="$KATZENSTEG_LIB"', script)
        self.assertIn('DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB"', script)
        self.assertIn('VK_LAYER_PATH="$MANIFEST_DIR"', script)
        self.assertIn('"library_path": "'"$KATZENSTEG_VULKAN_LAYER"'"', script)
        self.assertNotIn("exec env", script)

    def test_retroarch_vulkan_runner_uses_linux_preload_defaults_on_linux(self):
        if platform.system() != "Linux":
            self.skipTest("Linux RetroArch Vulkan runner defaults test")

        script = RETROARCH_RUNNER_PATH.read_text()

        self.assertIn("Linux)", script)
        self.assertIn("Darwin)", script)
        self.assertIn("libkatzensteg-unlinked.so", script)
        self.assertIn("libkatzensteg-vulkan-layer.so", script)
        self.assertIn('LD_PRELOAD="$KATZENSTEG_LIB"', script)
        self.assertIn('DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB"', script)
        self.assertIn('VK_LAYER_PATH="$MANIFEST_DIR"', script)
        self.assertIn('"library_path": "'"$KATZENSTEG_VULKAN_LAYER"'"', script)
        self.assertNotIn("exec env", script)

    def test_linux_vulkan_layer_exports_only_loader_entrypoints(self):
        if platform.system() != "Linux":
            self.skipTest("Linux ELF Vulkan layer export test")

        lib_path = ROOT / "zig-out" / "lib" / "libkatzensteg-vulkan-layer.so"
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

        self.assertEqual(EXPECTED_VULKAN_LAYER_EXPORTS, exported_definitions)

    def test_linux_vulkan_layer_does_not_link_vulkan_loader_or_sdl(self):
        if platform.system() != "Linux":
            self.skipTest("Linux ELF Vulkan layer dependency test")

        lib_path = ROOT / "zig-out" / "lib" / "libkatzensteg-vulkan-layer.so"
        self.assertTrue(
            lib_path.exists(),
            f"{lib_path} does not exist; run `zig build` first",
        )

        needed = needed_libraries(lib_path)
        self.assertNotIn("libvulkan.so.1", needed)
        self.assertNotIn("libSDL2-2.0.so.0", needed)


if __name__ == "__main__":
    unittest.main()
