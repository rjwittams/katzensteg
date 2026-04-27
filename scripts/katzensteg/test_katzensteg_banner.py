import unittest

import katzensteg_banner as kb


class TestLerp(unittest.TestCase):
    def test_lerp_endpoints(self):
        self.assertEqual(kb.lerp(0.0, 10.0, 0.0), 0.0)
        self.assertEqual(kb.lerp(0.0, 10.0, 1.0), 10.0)

    def test_lerp_midpoint(self):
        self.assertEqual(kb.lerp(0.0, 10.0, 0.5), 5.0)


class TestLerp3(unittest.TestCase):
    def test_lerp3_endpoints(self):
        a = (0, 0, 0)
        b = (100, 200, 50)
        self.assertEqual(kb.lerp3(a, b, 0.0), (0, 0, 0))
        self.assertEqual(kb.lerp3(a, b, 1.0), (100, 200, 50))

    def test_lerp3_clamps(self):
        a = (0, 0, 0)
        b = (100, 100, 100)
        self.assertEqual(kb.lerp3(a, b, -1.0), (0, 0, 0))
        self.assertEqual(kb.lerp3(a, b, 2.0), (100, 100, 100))


class TestRgbFg(unittest.TestCase):
    def test_format(self):
        self.assertEqual(kb.rgb_fg(34, 255, 100), "\x1b[38;2;34;255;100m")


class TestSampleGradient(unittest.TestCase):
    def test_returns_rgb_tuple_in_range(self):
        for t in (0.0, 0.5, 1.0, 3.7):
            for x in (0.0, 10.0, 50.0):
                for y in (0.0, 3.0):
                    r, g, b = kb.sample_gradient(x, y, t)
                    self.assertTrue(0 <= r <= 255)
                    self.assertTrue(0 <= g <= 255)
                    self.assertTrue(0 <= b <= 255)

    def test_deterministic(self):
        a = kb.sample_gradient(5.0, 2.0, 1.0)
        b = kb.sample_gradient(5.0, 2.0, 1.0)
        self.assertEqual(a, b)


class TestPhaseFor(unittest.TestCase):
    def test_spark(self):
        self.assertEqual(kb.phase_for(0.0), "spark")
        self.assertEqual(kb.phase_for(0.29), "spark")

    def test_scan(self):
        self.assertEqual(kb.phase_for(0.31), "scan")
        self.assertEqual(kb.phase_for(0.89), "scan")

    def test_stabilize(self):
        self.assertEqual(kb.phase_for(0.91), "stabilize")
        self.assertEqual(kb.phase_for(1.59), "stabilize")

    def test_steady(self):
        self.assertEqual(kb.phase_for(1.61), "steady")
        self.assertEqual(kb.phase_for(3.59), "steady")

    def test_upgrade(self):
        self.assertEqual(kb.phase_for(3.61), "upgrade")
        self.assertEqual(kb.phase_for(5.59), "upgrade")

    def test_modern_steady(self):
        self.assertEqual(kb.phase_for(5.61), "modern_steady")
        self.assertEqual(kb.phase_for(120.0), "modern_steady")


import io
import contextlib
import os
from unittest import mock


class TestCli(unittest.TestCase):
    def _run(self, argv):
        buf = io.StringIO()
        with mock.patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(buf):
            rc = kb.main(argv)
        return rc, buf.getvalue()

    def test_once_after_returns_zero_and_prints(self):
        rc, out = self._run(["--once-after", "5", "--no-color"])
        self.assertEqual(rc, 0)
        self.assertTrue(out.strip())

    def test_no_color_omits_escape_codes(self):
        _, out = self._run(["--once-after", "5", "--no-color"])
        self.assertNotIn("\x1b[", out)

    def test_once_after_with_color_emits_escape_codes(self):
        _, out = self._run(["--once-after", "5"])
        self.assertIn("\x1b[", out)


if __name__ == "__main__":
    unittest.main()
