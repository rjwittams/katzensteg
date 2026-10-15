#!/usr/bin/env python3
"""Each audio probe, launched with a Jackstay target, read back by a C ABI consumer.

The consumer selects video at the handshake, then the playback track when its
added notice arrives, and reads the ring and notices until the publication
ends. It checks the tone, monotonic sample positions, host-time stamps and the
track lifecycle across a reopen.

Build with Jackstay enabled; KATZENSTEG_JACKSTAY_PREFIX names the matching
prepared dependency.
"""
import ctypes as C
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import audio_tone_analysis as tone  # noqa: E402
import test_audio_probes as probes  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]

ADDED, REMOVED, UPDATED = 1, 2, 3
DISCONTINUITY, RECONFIGURATION, GAP = 1, 2, 4
SAMPLE_S16, SAMPLE_F32 = 2, 4


class AudioFormat(C.Structure):
    _fields_ = [("rate", C.c_uint32), ("channels", C.c_uint16), ("layout", C.c_uint8), ("sample", C.c_uint8)]
class AudioDescriptor(C.Structure):
    _fields_ = [("format", AudioFormat), ("block_frames", C.c_uint32), ("blocks", C.c_uint32)]
class TrackOffer(C.Structure):
    _fields_ = [("id", C.c_uint64), ("kind", C.c_char_p), ("label", C.c_char_p), ("descriptor", C.c_void_p), ("descriptor_len", C.c_size_t), ("direction", C.c_uint32), ("reserved", C.c_uint32), ("audio", AudioDescriptor)]
class TrackSelection(C.Structure):
    _fields_ = [("id", C.c_uint64), ("required", C.c_uint32), ("write", C.c_uint32)]
class TrackAdmission(C.Structure):
    _fields_ = [("id", C.c_uint64), ("result", C.c_uint32), ("reserved", C.c_uint32)]
class TrackNotice(C.Structure):
    _fields_ = [("type", C.c_uint32), ("reserved", C.c_uint32), ("track", TrackOffer)]
class AudioBlock(C.Structure):
    _fields_ = [("cursor", C.c_uint64), ("sample_position", C.c_uint64), ("host_time_ns", C.c_uint64), ("samples", C.c_void_p), ("samples_len", C.c_size_t), ("format", AudioFormat), ("frames", C.c_uint32), ("generation", C.c_uint32), ("flags", C.c_uint32), ("reserved", C.c_uint32)]

P = C.POINTER
SIGNATURES = {
    "ft_local_connection_adopt": [P(C.c_int32), P(C.c_void_p)],
    "ft_local_connection_destroy": [P(C.c_void_p)],
    "ft_handshake_connect_local": [P(C.c_void_p), P(C.c_void_p)],
    "ft_handshake_offer_describe": [C.c_void_p, P(C.c_char_p), P(C.c_uint32), P(P(TrackOffer)), P(C.c_size_t)],
    "ft_handshake_select": [P(C.c_void_p), P(TrackSelection), C.c_size_t, C.c_uint32, P(TrackAdmission), P(C.c_void_p), P(C.c_void_p), P(C.c_int32), P(C.c_void_p), C.c_void_p, C.c_void_p, P(C.c_void_p)],
    "ft_tracks_next": [C.c_void_p, C.c_uint32, P(TrackNotice)],
    "ft_tracks_select": [C.c_void_p, P(TrackSelection), P(TrackAdmission), P(C.c_uint32), P(C.c_void_p), P(C.c_void_p)],
    "ft_tracks_destroy": [P(C.c_void_p)],
    "ft_playback_reader_create": [C.c_void_p, C.c_uint64, P(C.c_void_p)],
    "ft_playback_reader_read": [C.c_void_p, P(AudioBlock)],
    "ft_playback_reader_destroy": [P(C.c_void_p)],
    "ft_playback_ring_destroy": [P(C.c_void_p)],
    "ft_playback_doorbell_destroy": [P(C.c_void_p)],
}


class Consumer:
    """Selects the playback track, then records every block and notice."""

    def __init__(self, lib, path):
        self.lib, self.blocks, self.notices, self.track = lib, [], [], None
        self.tracks, self.ring, self.doorbell, self.reader = C.c_void_p(), C.c_void_p(), C.c_void_p(), C.c_void_p()
        stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stream.connect(str(path))
        fd = C.c_int32(stream.detach())
        connection, offer = C.c_void_p(), C.c_void_p()
        assert lib.ft_local_connection_adopt(C.byref(fd), C.byref(connection)) == 0
        assert lib.ft_handshake_connect_local(C.byref(connection), C.byref(offer)) == 0
        label, clock, tracks, count = C.c_char_p(), C.c_uint32(), P(TrackOffer)(), C.c_size_t()
        assert lib.ft_handshake_offer_describe(offer, C.byref(label), C.byref(clock), C.byref(tracks), C.byref(count)) == 0
        assert clock.value == 3, clock.value  # host time
        # Playback is announced after the handshake, on the tracks channel.
        assert [tracks[i].kind for i in range(count.value)] == [b"video"]
        selection, admission = TrackSelection(id=tracks[0].id, required=1), TrackAdmission()
        media, client, affordances, status = C.c_void_p(), C.c_void_p(), C.c_void_p(), C.c_int32()
        assert lib.ft_handshake_select(C.byref(offer), C.byref(selection), 1, 0, C.byref(admission), C.byref(media), C.byref(client), C.byref(status), C.byref(affordances), None, None, C.byref(self.tracks)) == 0
        assert admission.result == 0, admission.result
        lib.ft_local_connection_destroy(C.byref(media))

    def poll(self):
        """Reads ready blocks and notices; False once the publication ended."""
        notice = TrackNotice()
        while True:
            status = self.lib.ft_tracks_next(self.tracks, 0, C.byref(notice))
            if status == 1:  # EMPTY
                break
            if status != 0:
                return False
            self.notices.append((notice.type, notice.track.id, notice.track.label, notice.track.audio.format.sample))
            if notice.type == ADDED and self.track is None:
                self.track = (notice.track.id, notice.track.label, notice.track.audio.format.sample)
                selection, admission, position = TrackSelection(id=notice.track.id, required=1), TrackAdmission(), C.c_uint32()
                assert self.lib.ft_tracks_select(self.tracks, C.byref(selection), C.byref(admission), C.byref(position), C.byref(self.ring), C.byref(self.doorbell)) == 0
                assert admission.result == 0, admission.result
        if self.ring and not self.reader:
            # Start at the ring's oldest block.
            assert self.lib.ft_playback_reader_create(self.ring, 2**63, C.byref(self.reader)) == 0
        block = AudioBlock()
        while self.reader and self.lib.ft_playback_reader_read(self.reader, C.byref(block)) == 0:
            samples = C.string_at(block.samples, block.samples_len) if block.samples_len else b""
            self.blocks.append((block.sample_position, block.host_time_ns, block.frames, block.format.sample, block.format.rate, block.flags, block.generation, samples))
        return True

    def close(self):
        for name, handle in (("ft_playback_reader_destroy", self.reader), ("ft_playback_ring_destroy", self.ring),
                             ("ft_playback_doorbell_destroy", self.doorbell), ("ft_tracks_destroy", self.tracks)):
            getattr(self.lib, name)(C.byref(handle))


@unittest.skipUnless(sys.platform.startswith("linux") or sys.platform == "darwin", "Jackstay connectors are POSIX-only")
class PublishedAudio(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        check = subprocess.run([str(probes.LAUNCHER), "--dry-run", "jackstay-source"], capture_output=True)
        if b"JackstayUnavailable" in check.stderr:
            raise unittest.SkipTest("build with -Djackstay=true to publish audio")
        prefix = Path(os.environ.get("KATZENSTEG_JACKSTAY_PREFIX", str(ROOT / "zig-out")))
        cls.lib = C.CDLL(str(prefix / "lib" / ("libjackstay.dylib" if sys.platform == "darwin" else "libjackstay.so")))
        for name, args in SIGNATURES.items():
            fn = getattr(cls.lib, name)
            fn.argtypes = args
            fn.restype = None if name.endswith("destroy") else C.c_int32
        assert C.sizeof(TrackOffer) == 64 and C.sizeof(AudioBlock) == 64

    def publish(self, profile, **env):
        """Runs `profile` with a Jackstay target to the end, read by a consumer."""
        folder = Path(tempfile.mkdtemp(prefix="ks-audio-js-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, folder, ignore_errors=True)
        path = folder / "source"
        app_env = probes.disk_env(folder / "disk.raw")
        app_env.update(KATZENSTEG_TARGET=f"jackstay:{path}", **env)
        started = time.monotonic_ns()
        app = subprocess.Popen([str(probes.LAUNCHER), profile], env=app_env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(app.stdout.close)
        self.addCleanup(lambda: app.poll() is None and app.kill())
        deadline = time.monotonic() + 10
        while not path.exists():
            if app.poll() is not None:
                self.fail(app.stdout.read().decode(errors="replace"))
            self.assertLess(time.monotonic(), deadline, "the publication never became ready")
            time.sleep(0.005)
        consumer = Consumer(self.lib, path)
        self.addCleanup(consumer.close)
        while consumer.poll():
            self.assertLess(time.monotonic(), deadline + 10, "the publication never ended")
            time.sleep(0.005)
        self.assertEqual(app.wait(timeout=10), 0, app.stdout.read().decode(errors="replace"))
        consumer.window = (started, time.monotonic_ns())
        return consumer

    def check_published(self, consumer, segments, deadlines=True):
        self.assertIsNotNone(consumer.track, "no playback track was offered")
        track_id, label, _ = consumer.track
        self.assertEqual(label, b"default")
        context = f"notices {consumer.notices}, {len(consumer.blocks)} blocks"
        # Updated on each reopen, removed when the publication ends, never re-added.
        updates = [n for n in consumer.notices if n[0] == UPDATED]
        self.assertEqual(len(updates), segments - 1, context)
        self.assertEqual([n[:2] for n in consumer.notices if n[0] != UPDATED], [(ADDED, track_id), (REMOVED, track_id)], context)
        blocks = consumer.blocks
        self.assertTrue(blocks, context)
        for before, after in zip(blocks, blocks[1:]):  # monotonic, without holes
            self.assertEqual(after[0], before[0] + before[2], "sample positions do not follow on")
            self.assertFalse(after[5] & GAP, "the reader was lapped")
        # A reopen starts a new segment with a discontinuity.
        starts = [i for i, b in enumerate(blocks) if i == 0 or b[5] & DISCONTINUITY]
        self.assertEqual(len(starts), segments, f"discontinuities at {starts}")
        start_ns, end_ns = consumer.window
        for first, end in zip(starts, starts[1:] + [len(blocks)]):
            segment = blocks[first:end]
            self.assertTrue(start_ns <= segment[0][1] <= end_ns, "stamps are not host time")
            times = [b[1] for b in segment]
            if deadlines:  # the virtual device's deadlines, exactly
                for block in segment:
                    self.assertAlmostEqual(block[1], times[0] + (block[0] - segment[0][0]) * 10**9 // block[4], delta=1000)
            else:  # stamped as the device runs
                self.assertEqual(times, sorted(times))
            fmt = tone.AUDIO_F32 if segment[0][3] == SAMPLE_F32 else tone.AUDIO_S16
            stats = tone.tone_stats(tone.decode_raw(b"".join(b[7] for b in segment), fmt))
            summary = tone.describe(stats)
            self.assertAlmostEqual(stats["freq"], tone.FREQ, delta=probes.FREQ_TOLERANCE_HZ, msg=summary)
            self.assertAlmostEqual(stats["rms"] / tone.EXPECTED_RMS, 1.0, delta=probes.RMS_TOLERANCE, msg=summary)
            self.assertGreater(stats["purity"], probes.MIN_PURITY, summary)
            self.assertEqual((stats["glitches"], stats["dropouts"]), (0, 0), summary)
        return blocks, starts

    def test_sdl2_probes(self):
        for profile, segments in probes.SDL2_PROFILES.items():
            with self.subTest(profile=profile):
                blocks, starts = self.check_published(self.publish(profile), segments)
                self.assertFalse(any(b[5] & RECONFIGURATION for b in blocks))

    def test_sdl2_reopen_in_another_format_reconfigures(self):
        blocks, starts = self.check_published(self.publish("probe.audio.reopen_f32"), 2)
        self.assertEqual([b[3] for b in (blocks[0], blocks[starts[1]])], [SAMPLE_S16, SAMPLE_F32])
        self.assertEqual([i for i, b in enumerate(blocks) if b[5] & RECONFIGURATION], [starts[1]])
        self.assertEqual(blocks[starts[1]][6], blocks[0][6] + 1)

    def test_sdl3_probes(self):
        # SDL3 has no virtual paced device yet (#176): SDL's dummy device
        # paces it, and blocks are stamped when its postmix runs.
        for profile, segments in probes.SDL3_PROFILES.items():
            with self.subTest(profile=profile):
                blocks, _ = self.check_published(self.publish(profile), segments, deadlines=False)
                self.assertEqual({b[3] for b in blocks}, {SAMPLE_F32})

    def test_opt_out_publishes_video_only(self):
        consumer = self.publish("probe.audio.callback", KATZENSTEG_PUBLISH_AUDIO="0")
        self.assertIsNone(consumer.track)
        self.assertEqual((consumer.notices, consumer.blocks), ([], []))


if __name__ == "__main__":
    unittest.main()
