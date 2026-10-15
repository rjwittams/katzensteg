#!/usr/bin/env python3
"""End-to-end checks of the SDL3 audio adapter.

Runs test_sdl2_audio_model.py's tap, gain-0 and reopen checks on the SDL3
bound-stream and device-stream probes (the tap is the F32 postmix block),
plus a probe that installs its own postmix. The dynapi class repeats them
through SDL3_DYNAMIC_API.

Needs `zig build` first.
"""
from pathlib import Path
import re
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import test_sdl2_audio_model as sdl2  # noqa: E402


class Sdl3AudioModelTests(sdl2.Sdl2AudioModelTests):
    profiles = ("probe.audio.sdl3.bound", "probe.audio.sdl3.devstream", "probe.audio.sdl3.devstream_callback")
    reopen_profile = "probe.audio.sdl3.reopen"

    def test_app_postmix_is_chained(self):
        with tempfile.TemporaryDirectory(prefix="ks-audio-sdl3-") as directory:
            self.run_profile(directory, "probe.audio.sdl3.app_postmix", KATZENSTEG_AUDIO_VOLUME="0")
            match = re.search(r"app_postmix_calls=(\d+)", self.probe_log)
            self.assertIsNotNone(match, self.context)
            self.assertGreater(int(match.group(1)), 10, self.context)
            data, fmt, _ = self.tap(1)
            self.assert_tone(data, fmt, "tap", 1)
            self.assert_silent(self.dir / "disk.raw")


class Sdl3DynapiAudioModelTests(Sdl3AudioModelTests):
    injection = "dynapi"

    def test_tap_matches_tone_with_steady_cadence(self):
        self.skipTest("covered through preload")


if __name__ == "__main__":
    unittest.main()
