#!/usr/bin/env python3
"""End-to-end checks of the SDL2 audio adapter, audio model and local device sink.

Runs the SDL2 `probe.audio.*` profiles through the launcher on SDL's `disk`
driver, as test_audio_probes.py does. The disk file is what the local device
sink played; KATZENSTEG_AUDIO_TAP_FILE makes the preload record the tap as
<base>.<sequence>.raw and .times (one u64 nanosecond time per block) when each
stream closes. The dynapi class repeats the gain-0 and reopen checks through
SDL_DYNAMIC_API. Set KS_SDL2_COMPAT_LIBRARY_PATH to an LD_LIBRARY_PATH that
puts sdl2-compat's libSDL2 (and its SDL3) first to run on sdl2-compat too.

Needs `zig build` first.
"""
import math
import os
from pathlib import Path
import re
import statistics
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import audio_tone_analysis as tone  # noqa: E402
import test_audio_probes as probes  # noqa: E402

PROFILES = ("probe.audio.callback", "probe.audio.queue", "probe.audio.legacy")
REOPEN_PROFILE = "probe.audio.reopen"

# SDL's disk driver sleeps whole milliseconds per buffer, so its period lies
# between the truncated and the exact buffer duration.
CADENCE_SLACK = 0.05
MAX_GAP_PERIODS = 4
# A single late wakeup of SDL's disk thread on a busy host can exceed four
# short (10 ms) periods; a real stall in the audio path is far longer, and
# the median and data/wall checks still pin the cadence.
MIN_MAX_GAP_MS = 100

COMPAT_LIBRARY_PATH = os.environ.get("KS_SDL2_COMPAT_LIBRARY_PATH", "")


@unittest.skipIf(sys.platform == "win32", "the disk-driver harness runs on POSIX launcher hosts only")
class Sdl2AudioModelTests(unittest.TestCase):
    library_path = ""
    injection = ""  # the profile's own (preload on Linux and macOS)

    def run_profile(self, directory, profile, **audio_env):
        self.assertTrue(probes.LAUNCHER.exists(), f"{probes.LAUNCHER} is missing; run zig build first")
        self.dir = Path(directory)
        env = probes.disk_env(self.dir / "disk.raw")
        env["KATZENSTEG_AUDIO_TAP_FILE"] = str(self.dir / "tap")
        env.update(audio_env)
        if self.library_path:
            env["LD_LIBRARY_PATH"] = self.library_path
        if self.injection:
            env["KATZENSTEG_INJECTION"] = self.injection
        result = subprocess.run([str(probes.LAUNCHER), profile], env=env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=60)
        self.probe_log = probes.AudioProbeLauncherTests.probe_output(result.stdout + result.stderr)
        files = sorted(p.name for p in self.dir.iterdir())
        self.context = f"profile {profile}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}\nfiles: {files}"
        if sys.platform == "darwin" and "driver=disk" not in self.probe_log:
            self.skipTest(f"this SDL build did not start its disk audio driver\n{self.probe_log}")
        self.assertEqual(result.returncode, 0, self.context)
        self.assertIn("driver=disk", self.probe_log, self.context)
        self.check_runtime()

    def check_runtime(self):
        """Classic SDL2 here; the sdl2-compat subclass checks for sdl2-compat."""

    def tap(self, sequence):
        """The tap's bytes, format and block times for one stream."""
        times_path = self.dir / f"tap.{sequence}.times"
        self.assertTrue(times_path.exists(), f"{times_path.name} was not written\n{self.context}")
        data = (self.dir / f"tap.{sequence}.raw").read_bytes()
        times = times_path.read_bytes()
        return data, tone.guess_format(data), struct.unpack(f"={len(times) // 8}Q", times)

    def assert_tone(self, data, fmt, label, segments):
        stats = tone.tone_stats(tone.decode_raw(data, fmt))
        summary = f"{label}: {tone.describe(stats)}\n{self.context}"
        expected_frames = probes.PROBE_SECONDS / segments * tone.RATE
        self.assertAlmostEqual(stats["freq"], tone.FREQ, delta=probes.FREQ_TOLERANCE_HZ, msg=summary)
        self.assertAlmostEqual(stats["rms"] / tone.EXPECTED_RMS, 1.0, delta=probes.RMS_TOLERANCE, msg=summary)
        self.assertGreater(stats["purity"], probes.MIN_PURITY, summary)
        self.assertEqual((stats["glitches"], stats["dropouts"]), (0, 0), summary)
        self.assertTrue(stats["ch_match"], summary)
        self.assertGreater(stats["active"], probes.MIN_LENGTH * expected_frames, summary)
        self.assertLess(stats["active"], probes.MAX_LENGTH * expected_frames, summary)

    def assert_silent(self, path):
        data = path.read_bytes()
        # Gain 0 writes exact silence: S16 and F32 zero are all-zero bytes.
        self.assertTrue(data and data.count(0) == len(data), f"{path.name} is not silent\n{self.context}")

    def assert_cadence(self, data, fmt, times, label):
        self.assertGreater(len(times), 10, f"{label}: too few blocks\n{self.context}")
        frames = len(data) // (tone.CHANNELS * (4 if fmt == tone.AUDIO_F32 else 2))
        period_ms = frames / len(times) / tone.RATE * 1000
        gaps = [(b - a) / 1e6 for a, b in zip(times, times[1:])]
        median = statistics.median(gaps)
        rate = frames / tone.RATE / ((times[-1] - times[0]) / 1e9 + period_ms / 1000)
        summary = (f"{label}: {len(times)} blocks, period {period_ms:.2f} ms, median gap {median:.2f} ms, "
                   f"max gap {max(gaps):.2f} ms, data/wall {rate:.3f}\n{self.context}")
        self.assertGreaterEqual(median, math.floor(period_ms) * (1 - CADENCE_SLACK), summary)
        self.assertLessEqual(median, period_ms * (1 + CADENCE_SLACK), summary)
        self.assertLess(max(gaps), max(MAX_GAP_PERIODS * period_ms, MIN_MAX_GAP_MS), summary)
        self.assertGreaterEqual(rate, 1 - CADENCE_SLACK, summary)
        self.assertLessEqual(rate, period_ms / math.floor(period_ms) + CADENCE_SLACK, summary)
        return period_ms

    def test_tap_matches_tone_with_steady_cadence(self):
        for profile in PROFILES:
            with self.subTest(profile=profile), tempfile.TemporaryDirectory(prefix="ks-audio-model-") as directory:
                self.run_profile(directory, profile)
                data, fmt, times = self.tap(1)
                self.assert_tone(data, fmt, "tap", 1)
                # At unity gain the device plays exactly what was tapped.
                self.assertGreaterEqual((self.dir / "disk.raw").read_bytes().find(data), 0, f"tap not in disk output\n{self.context}")
                self.assert_cadence(data, fmt, times, "tap")

    def test_gain_zero_silences_the_device_but_not_the_tap(self):
        for profile in PROFILES:
            with self.subTest(profile=profile), tempfile.TemporaryDirectory(prefix="ks-audio-model-") as directory:
                self.run_profile(directory, profile, KATZENSTEG_AUDIO_VOLUME="0")
                data, fmt, _ = self.tap(1)
                self.assert_tone(data, fmt, "tap", 1)
                self.assert_silent(self.dir / "disk.raw")

    def test_close_and_reopen_keeps_the_hooks(self):
        with tempfile.TemporaryDirectory(prefix="ks-audio-model-") as directory:
            self.run_profile(directory, REOPEN_PROFILE, KATZENSTEG_AUDIO_VOLUME="0")
            periods = []
            for sequence in (1, 2):
                data, fmt, times = self.tap(sequence)
                self.assert_tone(data, fmt, f"tap {sequence}", 2)
                periods.append(self.assert_cadence(data, fmt, times, f"tap {sequence}"))
            self.assertFalse((self.dir / "tap.3.times").exists(), self.context)
            # The second open asks for half the buffer, as Flycast does.
            self.assertAlmostEqual(periods[0], 2 * periods[1], delta=0.01, msg=self.context)
            for path in (self.dir / "disk.raw", self.dir / "disk.raw.seg2"):
                self.assert_silent(path)


# The virtual paced device sleeps to absolute deadlines on the monotonic
# clock, so its blocks keep the nominal rate far tighter than SDL's drivers
# (the dummy and disk drivers drift 0.7% to 4%).
VIRTUAL_RATE_TOLERANCE = 0.002
VIRTUAL_GAP_TOLERANCE = 0.02


class Sdl2VirtualDeviceTests(Sdl2AudioModelTests):
    """KATZENSTEG_AUDIO_DEVICE=virtual: nothing reaches SDL's (disk) device,
    and the virtual paced device drains the app on Katzensteg's clock."""

    def run_virtual(self, directory, profile):
        self.run_profile(directory, profile, KATZENSTEG_AUDIO_DEVICE="virtual")
        self.assertFalse((self.dir / "disk.raw").exists(), f"a real device was opened\n{self.context}")

    def assert_exact_cadence(self, data, fmt, times, label):
        period_ms = self.assert_cadence(data, fmt, times, label)
        # The fitted block period is immune to the jitter of single wakeups.
        slope_ms = statistics.linear_regression(range(len(times)), times).slope / 1e6
        median = statistics.median((b - a) / 1e6 for a, b in zip(times, times[1:]))
        summary = f"{label}: period {period_ms:.3f} ms, fitted {slope_ms:.4f} ms, median gap {median:.3f} ms\n{self.context}"
        self.assertAlmostEqual(slope_ms / period_ms, 1.0, delta=VIRTUAL_RATE_TOLERANCE, msg=summary)
        self.assertAlmostEqual(median / period_ms, 1.0, delta=VIRTUAL_GAP_TOLERANCE, msg=summary)
        return period_ms

    def test_tap_matches_tone_with_steady_cadence(self):
        for profile in PROFILES:
            with self.subTest(profile=profile), tempfile.TemporaryDirectory(prefix="ks-audio-virtual-") as directory:
                self.run_virtual(directory, profile)
                data, fmt, times = self.tap(1)
                self.assert_tone(data, fmt, "tap", 1)
                self.assert_exact_cadence(data, fmt, times, "tap")

    def test_gain_zero_silences_the_device_but_not_the_tap(self):
        self.skipTest("no local device plays")

    def test_close_and_reopen_keeps_the_hooks(self):
        with tempfile.TemporaryDirectory(prefix="ks-audio-virtual-") as directory:
            self.run_virtual(directory, REOPEN_PROFILE)
            periods = []
            for sequence in (1, 2):
                data, fmt, times = self.tap(sequence)
                self.assert_tone(data, fmt, f"tap {sequence}", 2)
                periods.append(self.assert_exact_cadence(data, fmt, times, f"tap {sequence}"))
            self.assertAlmostEqual(periods[0], 2 * periods[1], delta=0.01, msg=self.context)


class Sdl2DynapiVirtualDeviceTests(Sdl2VirtualDeviceTests):
    """The virtual device's open, pause and close through SDL_DYNAMIC_API."""

    injection = "dynapi"


class Sdl2DynapiAudioModelTests(Sdl2AudioModelTests):
    """The same wrappers through SDL_DYNAMIC_API; device-facing checks only."""

    injection = "dynapi"

    def test_tap_matches_tone_with_steady_cadence(self):
        self.skipTest("covered through preload")


@unittest.skipUnless(COMPAT_LIBRARY_PATH, "set KS_SDL2_COMPAT_LIBRARY_PATH to run the probes on sdl2-compat")
class Sdl2CompatAudioModelTests(Sdl2AudioModelTests):
    library_path = COMPAT_LIBRARY_PATH

    def check_runtime(self):
        # sdl2-compat reports SDL 2.32.50 and later; classic SDL2 stops below.
        match = re.search(r"linked SDL (\d+)\.(\d+)\.(\d+)", self.probe_log)
        self.assertIsNotNone(match, self.context)
        self.assertGreaterEqual(tuple(int(v) for v in match.groups()), (2, 32, 50), f"not sdl2-compat\n{self.context}")


if __name__ == "__main__":
    unittest.main()
