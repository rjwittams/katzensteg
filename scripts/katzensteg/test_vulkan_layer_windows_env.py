import ctypes
import os
import pathlib
import platform
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
WINDOWS_SOURCE = ROOT / "src" / "katzensteg" / "vulkan_layer_windows.c"


@unittest.skipUnless(platform.system() == "Windows", "Windows Vulkan layer OS services")
class VulkanLayerWindowsEnvTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        zig = shutil.which("zig")
        if zig is None:
            raise unittest.SkipTest("zig is required to compile the Windows layer services")
        cls.tmpdir = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        cls.lib_path = pathlib.Path(cls.tmpdir.name) / "vulkan_layer_windows_test.dll"
        subprocess.check_call([
            zig, "cc", "-shared", "-O2", "-DKS_LAYER_OS_HIDDEN=__declspec(dllexport)",
            str(WINDOWS_SOURCE), "-o", str(cls.lib_path),
        ])
        cls.lib = ctypes.CDLL(str(cls.lib_path))
        cls.lib.ks_layer_os_scrub_list_env.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        cls.lib.ks_layer_os_scrub_list_env.restype = None
        cls.lib.ks_layer_os_unsetenv.argtypes = [ctypes.c_char_p]
        cls.lib.ks_layer_os_unsetenv.restype = None
        cls.lib.ks_layer_os_global_symbol.argtypes = [ctypes.c_char_p]
        cls.lib.ks_layer_os_global_symbol.restype = ctypes.c_void_p
        cls.lib.ks_layer_os_own_directory.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        cls.lib.ks_layer_os_own_directory.restype = ctypes.c_bool

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "lib"):
            ctypes.windll.kernel32.FreeLibrary(ctypes.c_void_p(cls.lib._handle))
        if hasattr(cls, "tmpdir"):
            cls.tmpdir.cleanup()

    def tearDown(self):
        os.environ.pop("KATZENSTEG_TEST_LIST", None)
        ctypes.windll.kernel32.SetEnvironmentVariableW("KATZENSTEG_TEST_LIST", None)

    def process_env(self, name):
        # What a child process inherits: the Win32 environment block.
        buf = ctypes.create_unicode_buffer(1024)
        n = ctypes.windll.kernel32.GetEnvironmentVariableW(name, buf, len(buf))
        return buf.value if n else None

    def set_env(self, name, value):
        # The DLL's C runtime reads its own copy, initialised from the block.
        ctypes.cdll.msvcrt._putenv_s(name.encode(), value.encode())
        ctypes.windll.kernel32.SetEnvironmentVariableW(name, value)

    def test_scrub_removes_only_the_named_layer(self):
        self.set_env("KATZENSTEG_TEST_LIST", "VK_LAYER_OTHER;VK_LAYER_KATZENSTEG_capture;VK_LAYER_LAST")

        self.lib.ks_layer_os_scrub_list_env(b"KATZENSTEG_TEST_LIST", b"VK_LAYER_KATZENSTEG_capture")

        self.assertEqual("VK_LAYER_OTHER;VK_LAYER_LAST", self.process_env("KATZENSTEG_TEST_LIST"))

    def test_scrub_unsets_an_emptied_list(self):
        self.set_env("KATZENSTEG_TEST_LIST", "VK_LAYER_KATZENSTEG_capture")

        self.lib.ks_layer_os_scrub_list_env(b"KATZENSTEG_TEST_LIST", b"VK_LAYER_KATZENSTEG_capture")

        self.assertIsNone(self.process_env("KATZENSTEG_TEST_LIST"))

    def test_unsetenv_removes_the_variable_for_children(self):
        self.set_env("KATZENSTEG_TEST_LIST", "1")

        self.lib.ks_layer_os_unsetenv(b"KATZENSTEG_TEST_LIST")

        self.assertIsNone(self.process_env("KATZENSTEG_TEST_LIST"))

    def test_global_symbol_searches_loaded_modules(self):
        self.assertIsNotNone(self.lib.ks_layer_os_global_symbol(b"GetProcAddress"))
        self.assertIsNone(self.lib.ks_layer_os_global_symbol(b"ks_no_such_symbol"))

    def test_own_directory_is_the_library_directory(self):
        buf = ctypes.create_string_buffer(1024)

        self.assertTrue(self.lib.ks_layer_os_own_directory(buf, len(buf)))
        self.assertEqual(pathlib.Path(self.tmpdir.name).resolve(), pathlib.Path(buf.value.decode()).resolve())


if __name__ == "__main__":
    unittest.main()
