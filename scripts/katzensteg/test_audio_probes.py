#!/usr/bin/env python3
"""End-to-end audio probe checks: launcher profile to SDL's disk driver.

Each `probe.audio.*` profile in profiles/probes.json runs one SDL audio model
(examples/probes/*/audio_probe.c) through the launcher with its SDL adapter
injected. SDL's `disk` driver writes the device output to a file, and the
analysis in audio_tone_analysis.py checks it is the probe's 440 Hz tone.
At the SDL adapters' default volume the device plays the app's samples
unchanged, so these checks hold with audio interception on;
test_sdl2_audio_model.py and test_sdl3_audio_model.py check the interception.

Needs `zig build` first.
"""
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import audio_tone_analysis as tone  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "zig-out" / "bin" / "katzensteg"

# profile -> number of device segments the probe writes (reopen writes two).
SDL2_PROFILES = {
    "probe.audio.callback": 1,
    "probe.audio.queue": 1,
    "probe.audio.legacy": 1,
    "probe.audio.reopen": 2,
}
SDL3_PROFILES = {
    "probe.audio.sdl3.bound": 1,
    "probe.audio.sdl3.devstream": 1,
    "probe.audio.sdl3.devstream_callback": 1,
    "probe.audio.sdl3.reopen": 2,
}
PROBE_SECONDS = 2.0  # the probes' default --secs

RMS_TOLERANCE = 0.03  # relative
PEAK_TOLERANCE = 0.02  # absolute, of full scale
FREQ_TOLERANCE_HZ = 1.0
MIN_PURITY = 0.98
# Callback probes play for a wall-clock interval and the device drains a
# buffer either side, so the length is only roughly the requested time.
MIN_LENGTH = 0.8
MAX_LENGTH = 1.5


def disk_env(output):
    """Launcher environment selecting SDL's disk driver for SDL2 and SDL3."""
    # Drop every KATZENSTEG_* setting from the caller's shell (a custom
    # KATZENSTEG_PROFILE_DIR, a whiskers socket, a proxy profile) so the test
    # always runs this checkout's profiles the same way, then pin the repo.
    env = {key: value for key, value in os.environ.items() if not key.startswith("KATZENSTEG_")}
    env["KATZENSTEG_REPO"] = str(ROOT)
    env["SDL_AUDIODRIVER"] = "disk"  # SDL2
    env["SDL_AUDIO_DRIVER"] = "disk"  # SDL3
    env["SDL_DISKAUDIOFILE"] = str(output)  # SDL2
    env["SDL_AUDIO_DISK_OUTPUT_FILE"] = str(output)  # SDL3
    return env


def synth(seconds=1.0, freq=tone.FREQ, amplitude=tone.AMPLITUDE, channels=tone.CHANNELS):
    frames = int(seconds * tone.RATE)
    x = [amplitude * math.sin(2 * math.pi * freq * i / tone.RATE) for i in range(frames)]
    return [list(x) for _ in range(channels)]


class ToneAnalysisTests(unittest.TestCase):
    """The analysis must tell the probe tone from the failures it guards."""

    def test_clean_tone(self):
        stats = tone.tone_stats(synth())
        self.assertAlmostEqual(stats["freq"], tone.FREQ, delta=0.05)
        self.assertAlmostEqual(stats["rms"], tone.EXPECTED_RMS, delta=0.001)
        self.assertGreater(stats["purity"], 0.99)
        self.assertEqual((stats["glitches"], stats["dropouts"]), (0, 0))
        self.assertTrue(stats["ch_match"])

    def test_wrong_frequency_and_gain(self):
        stats = tone.tone_stats(synth(freq=480.0, amplitude=0.25))
        self.assertAlmostEqual(stats["freq"], 480.0, delta=0.05)
        self.assertAlmostEqual(stats["rms"], tone.EXPECTED_RMS / 2, delta=0.001)
        self.assertLess(stats["purity"], 0.1)

    def test_silence(self):
        stats = tone.tone_stats([[0.0] * 4800] * 2)
        self.assertEqual(stats["active"], 0)
        self.assertEqual(stats["frames"], 4800)

    def test_dropout_and_glitch(self):
        channels = synth()
        for c in channels:
            c[20000:21000] = [0.0] * 1000
        stats = tone.tone_stats(channels)
        self.assertEqual(stats["dropouts"], 1)
        self.assertGreater(stats["glitches"], 0)

    def test_channel_mismatch(self):
        channels = synth()
        channels[1] = [0.0] * len(channels[1])
        self.assertFalse(tone.tone_stats(channels)["ch_match"])

    def test_decode_and_guess_formats(self):
        import array
        s16 = array.array("h", [0, 0, 16384, 16384, -16384, -16384, 32767, 32767])
        f32 = array.array("f", [0.0, 0.0, 0.5, 0.5, -0.5, -0.5, 1.0, 1.0])
        for values in (s16, f32):
            if sys.byteorder != "little":
                values.byteswap()
        s16_bytes, f32_bytes = s16.tobytes(), f32.tobytes()
        self.assertEqual(tone.guess_format(f32_bytes), tone.AUDIO_F32)
        self.assertEqual(tone.guess_format(s16_bytes), tone.AUDIO_S16)
        self.assertEqual(tone.decode_raw(s16_bytes, tone.AUDIO_S16)[0], [0.0, 0.5, -0.5, 32767 / 32768])
        self.assertEqual(tone.decode_raw(f32_bytes, tone.AUDIO_F32)[1], [0.0, 0.5, -0.5, 1.0])


@unittest.skipIf(sys.platform == "win32", "the disk-driver harness runs on POSIX launcher hosts only")
class AudioProbeLauncherTests(unittest.TestCase):
    def test_sdl2_probes_reach_the_disk_driver(self):
        self.run_profiles(SDL2_PROFILES)

    def test_sdl3_probes_reach_the_disk_driver(self):
        self.run_profiles(SDL3_PROFILES)

    def test_profiles_inject_their_sdl_adapter(self):
        self.assertTrue(LAUNCHER.exists(), f"{LAUNCHER} is missing; run zig build first")
        variable = "DYLD_INSERT_LIBRARIES" if sys.platform == "darwin" else "LD_PRELOAD"
        for profiles, library in ((SDL2_PROFILES, "libkatzensteg-sdl2."), (SDL3_PROFILES, "libkatzensteg-sdl3.")):
            for profile in profiles:
                with self.subTest(profile=profile):
                    result = subprocess.run([str(LAUNCHER), "--dry-run", profile], env=disk_env(Path("unused")),
                                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
                    report = result.stdout + result.stderr
                    self.assertEqual(result.returncode, 0, report)
                    match = re.search(rf"^\s*{variable}=(.*)$", report, re.MULTILINE)
                    self.assertIsNotNone(match, report)
                    self.assertIn(library, match.group(1))

    def run_profiles(self, profiles):
        self.assertTrue(LAUNCHER.exists(), f"{LAUNCHER} is missing; run zig build first")
        for profile, segments in profiles.items():
            with self.subTest(profile=profile):
                self.check_profile(profile, segments)

    def check_profile(self, profile, segments):
        with tempfile.TemporaryDirectory(prefix="ks-audio-") as directory:
            output = Path(directory) / "disk.raw"
            result = subprocess.run([str(LAUNCHER), profile], env=disk_env(output), stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=60)
            probe_log = self.probe_output(result.stdout + result.stderr)
            context = f"launcher stdout:\n{result.stdout}\nlauncher stderr:\n{result.stderr}\nprobe output:\n{probe_log}"
            if sys.platform == "darwin" and "driver=disk" not in probe_log:
                # Linux CI pins SDL builds with the disk driver; a macOS SDL
                # may be built without it, and SDL_Init then fails.
                self.skipTest(f"this SDL build did not start its disk audio driver\n{probe_log}")
            self.assertEqual(result.returncode, 0, context)
            self.assertIn("driver=disk", probe_log, f"probe did not select SDL's disk audio driver\n{context}")
            files = [output] + [Path(f"{output}.seg2")] * (segments - 1)
            expected_frames = PROBE_SECONDS / segments * tone.RATE
            for path in files:
                self.assertTrue(path.exists(), f"{path.name} was not written\n{context}")
                fmt, stats = tone.analyze_file(path)
                summary = f"{path.name} read as 0x{fmt:04x}: {tone.describe(stats)}\n{context}"
                self.assertGreater(stats["active"], 0, summary)
                self.assertAlmostEqual(stats["freq"], tone.FREQ, delta=FREQ_TOLERANCE_HZ, msg=summary)
                self.assertAlmostEqual(stats["rms"] / tone.EXPECTED_RMS, 1.0, delta=RMS_TOLERANCE, msg=summary)
                self.assertAlmostEqual(stats["peak"], tone.AMPLITUDE, delta=PEAK_TOLERANCE, msg=summary)
                self.assertGreater(stats["purity"], MIN_PURITY, summary)
                self.assertEqual(stats["glitches"], 0, summary)
                self.assertEqual(stats["dropouts"], 0, summary)
                self.assertTrue(stats["ch_match"], summary)
                self.assertGreater(stats["active"], MIN_LENGTH * expected_frames, summary)
                self.assertLess(stats["active"], MAX_LENGTH * expected_frames, summary)

    @staticmethod
    def probe_output(launcher_output):
        """The launcher redirects the target's output to the file it names."""
        match = re.search(r"^\s*output: (.+)$", launcher_output, re.MULTILINE)
        if not match:
            return "<launcher named no output file>"
        try:
            return Path(match.group(1).strip()).read_text(errors="replace")
        except OSError as error:
            return f"<{error}>"


if __name__ == "__main__":
    unittest.main()
