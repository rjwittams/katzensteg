import ctypes
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "src" / "katzensteg" / "image_fastpath_portable.c"


class PortableImageFastpathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc = shutil.which("cc")
        if cc is None:
            raise unittest.SkipTest("cc is required to compile portable image fastpath tests")
        cls.tmpdir = tempfile.TemporaryDirectory()
        cls.lib_path = pathlib.Path(cls.tmpdir.name) / "libimage_fastpath_portable.so"
        subprocess.check_call(
            [cc, "-shared", "-fPIC", "-O2", str(SOURCE), "-lyuv", "-o", str(cls.lib_path)]
        )
        cls.lib = ctypes.CDLL(str(cls.lib_path))
        byte_ptr = ctypes.POINTER(ctypes.c_uint8)
        cls.lib.ks_fast_i420_to_rgba.argtypes = [
            byte_ptr,
            ctypes.c_int,
            ctypes.c_int,
            byte_ptr,
            ctypes.c_int,
            byte_ptr,
            ctypes.c_int,
            byte_ptr,
            ctypes.c_int,
        ]
        cls.lib.ks_fast_i420_to_rgba.restype = ctypes.c_int
        cls.lib.ks_fast_nv12_to_rgba.argtypes = [
            byte_ptr,
            ctypes.c_int,
            ctypes.c_int,
            byte_ptr,
            ctypes.c_int,
            byte_ptr,
            ctypes.c_int,
        ]
        cls.lib.ks_fast_nv12_to_rgba.restype = ctypes.c_int
        cls.lib.ks_fast_bgra_to_rgba.argtypes = [
            byte_ptr,
            ctypes.c_int,
            ctypes.c_int,
            byte_ptr,
        ]
        cls.lib.ks_fast_bgra_to_rgba.restype = ctypes.c_int
        cls.lib.ks_fast_a2b10g10r10_to_rgba.argtypes = [
            byte_ptr,
            ctypes.c_int,
            ctypes.c_int,
            byte_ptr,
        ]
        cls.lib.ks_fast_a2b10g10r10_to_rgba.restype = ctypes.c_int
        cls.lib.ks_fast_scale_rgba.argtypes = [
            byte_ptr,
            ctypes.c_int,
            ctypes.c_int,
            byte_ptr,
            ctypes.c_int,
            ctypes.c_int,
        ]
        cls.lib.ks_fast_scale_rgba.restype = ctypes.c_int

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "tmpdir"):
            cls.tmpdir.cleanup()

    def test_i420_to_rgba_uses_video_range_bt601_conversion(self):
        y = (ctypes.c_uint8 * 4)(16, 235, 16, 235)
        u = (ctypes.c_uint8 * 1)(128)
        v = (ctypes.c_uint8 * 1)(128)
        dst = (ctypes.c_uint8 * 16)()

        rc = self.lib.ks_fast_i420_to_rgba(dst, 2, 2, y, 2, u, 1, v, 1)

        self.assertEqual(1, rc)
        self.assertEqual(
            [
                0,
                0,
                0,
                255,
                255,
                255,
                255,
                255,
                0,
                0,
                0,
                255,
                255,
                255,
                255,
                255,
            ],
            list(dst),
        )

    def test_nv12_to_rgba_uses_video_range_bt601_conversion(self):
        y = (ctypes.c_uint8 * 4)(16, 235, 16, 235)
        uv = (ctypes.c_uint8 * 2)(128, 128)
        dst = (ctypes.c_uint8 * 16)()

        rc = self.lib.ks_fast_nv12_to_rgba(dst, 2, 2, y, 2, uv, 2)

        self.assertEqual(1, rc)
        self.assertEqual(
            [
                0,
                0,
                0,
                255,
                255,
                255,
                255,
                255,
                0,
                0,
                0,
                255,
                255,
                255,
                255,
                255,
            ],
            list(dst),
        )

    def test_bgra_to_rgba_swaps_blue_and_red_channels(self):
        src = (ctypes.c_uint8 * 8)(10, 20, 30, 40, 50, 60, 70, 80)
        dst = (ctypes.c_uint8 * 8)()

        rc = self.lib.ks_fast_bgra_to_rgba(dst, 2, 1, src)

        self.assertEqual(1, rc)
        self.assertEqual([30, 20, 10, 40, 70, 60, 50, 80], list(dst))

    def test_a2b10g10r10_to_rgba_expands_10_bit_channels(self):
        src = (ctypes.c_uint32 * 3)(
            (3 << 30) | (1023 << 20) | (512 << 10) | 0,
            (0 << 30) | (0 << 20) | (1023 << 10) | 1023,
            (3 << 30) | (0 << 20) | (0 << 10) | 511,
        )
        dst = (ctypes.c_uint8 * 12)()

        rc = self.lib.ks_fast_a2b10g10r10_to_rgba(
            dst,
            3,
            1,
            ctypes.cast(src, ctypes.POINTER(ctypes.c_uint8)),
        )

        self.assertEqual(1, rc)
        self.assertEqual([0, 128, 255, 255, 255, 255, 0, 0, 127, 0, 0, 255], list(dst))

    def test_scale_rgba_uses_nearest_neighbor_mapping(self):
        src = (ctypes.c_uint8 * 16)(
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            10,
            11,
            12,
            13,
            14,
            15,
            16,
        )
        dst = (ctypes.c_uint8 * 24)()

        rc = self.lib.ks_fast_scale_rgba(dst, 3, 2, src, 2, 2)

        self.assertEqual(1, rc)
        self.assertEqual(
            [
                1,
                2,
                3,
                4,
                1,
                2,
                3,
                4,
                5,
                6,
                7,
                8,
                9,
                10,
                11,
                12,
                9,
                10,
                11,
                12,
                13,
                14,
                15,
                16,
            ],
            list(dst),
        )

    def test_fastpaths_reject_invalid_dimensions(self):
        src = (ctypes.c_uint8 * 4)(1, 2, 3, 4)
        dst = (ctypes.c_uint8 * 4)()

        self.assertEqual(0, self.lib.ks_fast_bgra_to_rgba(dst, 0, 1, src))
        self.assertEqual(0, self.lib.ks_fast_a2b10g10r10_to_rgba(dst, 0, 1, src))
        self.assertEqual(0, self.lib.ks_fast_scale_rgba(dst, 1, 1, src, 0, 1))


if __name__ == "__main__":
    unittest.main()
