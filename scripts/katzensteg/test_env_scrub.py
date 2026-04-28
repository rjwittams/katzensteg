import ctypes
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
ENV_SCRUB_SOURCE = ROOT / "src" / "katzensteg" / "env_scrub.c"
VULKAN_LAYER_SOURCE = ROOT / "src" / "katzensteg" / "vulkan_layer.c"


class EnvScrubTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc = shutil.which("cc")
        if cc is None:
            raise unittest.SkipTest("cc is required to compile env scrub tests")
        cls.tmpdir = tempfile.TemporaryDirectory()
        cls.env_lib_path = pathlib.Path(cls.tmpdir.name) / "libenv_scrub.so"
        subprocess.check_call(
            [
                cc,
                "-shared",
                "-fPIC",
                "-O2",
                "-DKS_ENV_SCRUB_API=",
                str(ENV_SCRUB_SOURCE),
                "-o",
                str(cls.env_lib_path),
            ]
        )
        cls.env_lib = ctypes.CDLL(str(cls.env_lib_path))
        cls.env_lib.ks_scrub_colon_env_entry.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        cls.env_lib.ks_scrub_colon_env_entry.restype = None
        cls.libc = ctypes.CDLL(None)
        cls.libc.getenv.argtypes = [ctypes.c_char_p]
        cls.libc.getenv.restype = ctypes.c_char_p

        cls.vulkan_lib_path = pathlib.Path(cls.tmpdir.name) / "libvulkan_layer_test.so"
        subprocess.check_call(
            [
                cc,
                "-shared",
                "-fPIC",
                "-O2",
                "-DKS_VULKAN_LAYER_TESTING",
                str(VULKAN_LAYER_SOURCE),
                str(ENV_SCRUB_SOURCE),
                "-o",
                str(cls.vulkan_lib_path),
            ]
        )

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "tmpdir"):
            cls.tmpdir.cleanup()

    def tearDown(self):
        for name in (
            "KATZENSTEG_TEST_LIST",
            "KATZENSTEG_VULKAN_CAPTURE",
            "KATZENSTEG_TRACE_VULKAN",
            "VK_INSTANCE_LAYERS",
        ):
            os.environ.pop(name, None)

    def c_getenv(self, name):
        value = self.libc.getenv(name.encode())
        return None if value is None else value.decode()

    def test_scrub_colon_env_entry_removes_only_exact_match(self):
        os.environ["KATZENSTEG_TEST_LIST"] = "/tmp/other.so:/tmp/libkatzensteg-unlinked.so:/tmp/another.so"

        self.env_lib.ks_scrub_colon_env_entry(
            b"KATZENSTEG_TEST_LIST",
            b"/tmp/libkatzensteg-unlinked.so",
        )

        self.assertEqual("/tmp/other.so:/tmp/another.so", self.c_getenv("KATZENSTEG_TEST_LIST"))

    def test_scrub_colon_env_entry_unsets_empty_result(self):
        os.environ["KATZENSTEG_TEST_LIST"] = "/tmp/libkatzensteg-unlinked.so"

        self.env_lib.ks_scrub_colon_env_entry(
            b"KATZENSTEG_TEST_LIST",
            b"/tmp/libkatzensteg-unlinked.so",
        )

        self.assertIsNone(self.c_getenv("KATZENSTEG_TEST_LIST"))

    def test_vulkan_layer_latches_flags_before_scrubbing_child_env(self):
        os.environ["KATZENSTEG_VULKAN_CAPTURE"] = "1"
        os.environ["KATZENSTEG_TRACE_VULKAN"] = "1"
        os.environ["VK_INSTANCE_LAYERS"] = "VK_LAYER_OTHER:VK_LAYER_KATZENSTEG_capture:VK_LAYER_LAST"

        vulkan_lib = ctypes.CDLL(str(self.vulkan_lib_path))
        vulkan_lib.ks_vulkan_test_capture_enabled.restype = ctypes.c_int
        vulkan_lib.ks_vulkan_test_trace_enabled.restype = ctypes.c_int

        self.assertEqual(1, vulkan_lib.ks_vulkan_test_capture_enabled())
        self.assertEqual(1, vulkan_lib.ks_vulkan_test_trace_enabled())
        self.assertIsNone(self.c_getenv("KATZENSTEG_VULKAN_CAPTURE"))
        self.assertIsNone(self.c_getenv("KATZENSTEG_TRACE_VULKAN"))
        self.assertEqual("VK_LAYER_OTHER:VK_LAYER_LAST", self.c_getenv("VK_INSTANCE_LAYERS"))

    def test_vulkan_layer_preserves_a2b10g10r10_format_for_present_layer(self):
        format_lib_path = pathlib.Path(self.tmpdir.name) / "libvulkan_layer_format_test.so"
        shutil.copy2(self.vulkan_lib_path, format_lib_path)
        vulkan_lib = ctypes.CDLL(str(format_lib_path))
        vulkan_lib.ks_vulkan_test_external_format_for_vk.argtypes = [ctypes.c_int]
        vulkan_lib.ks_vulkan_test_external_format_for_vk.restype = ctypes.c_int

        self.assertEqual(2, vulkan_lib.ks_vulkan_test_external_format_for_vk(64))

    def test_preload_constructor_removes_only_katzensteg_from_ld_preload(self):
        if platform.system() != "Linux":
            self.skipTest("Linux preload env scrub test")

        lib_path = ROOT / "zig-out" / "lib" / "libkatzensteg-unlinked.so"
        self.assertTrue(
            lib_path.exists(),
            f"{lib_path} does not exist; run `zig build` first",
        )
        keep_path = "/usr/lib/libm.so.6"

        env = os.environ.copy()
        env["LD_PRELOAD"] = f"{lib_path}:{keep_path}"
        output = subprocess.check_output(["/usr/bin/env"], env=env, text=True)

        self.assertIn(f"LD_PRELOAD={keep_path}\n", output)
        self.assertNotIn(str(lib_path), output)


if __name__ == "__main__":
    unittest.main()
