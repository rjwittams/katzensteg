"""Native CPU connector checks using separately executed, terminal-free peers."""
import os
import ctypes as C
import json
from pathlib import Path
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Peer:
    def __init__(self, mode, path, command=None, env=None):
        self.process = subprocess.Popen(
            command or [str(ROOT / "zig-out/bin/katzensteg-jackstay-probe"), mode, str(path)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, bufsize=0, env=env,
        )

    def read(self):
        if not select.select([self.process.stdout], [], [], 8)[0]:
            raise AssertionError("Timed out waiting for connector")
        result = self.process.stdout.readline().decode().strip()
        if not result:
            raise AssertionError(self.process.stderr.read().decode())
        return result

    def send(self, command):
        self.process.stdin.write((command + "\n").encode())
        self.process.stdin.flush()
        return self.read()

    def finish(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=8)
        if self.process.returncode:
            raise AssertionError(self.process.stderr.read().decode())

    def cleanup(self):
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.wait()
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


class CpuConnections(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        check = subprocess.run([str(ROOT / "zig-out/bin/katzensteg"), "--dry-run", "jackstay-source"], capture_output=True)
        if b"JackstayUnavailable" in check.stderr:
            raise unittest.SkipTest("build with -Djackstay=true to exercise CPU connectors")
        if check.returncode:
            raise AssertionError(check.stderr.decode())

    def peers(self, path, mode="publish"):
        publisher = Peer(mode, path)
        self.addCleanup(publisher.cleanup)
        self.assertEqual(publisher.read(), "ready")
        consumer = Peer("consume", path)
        self.addCleanup(consumer.cleanup)
        self.assertEqual(consumer.read(), "ready")
        return publisher, consumer

    def test_held_frame_survives_resize_and_connection_close(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            path = Path(tmp) / "source"
            publisher, consumer = self.peers(path)
            self.assertEqual(publisher.send("1 7"), "published")
            self.assertEqual(consumer.send("hold"), "1 7")
            self.assertEqual(publisher.send("2 9"), "published")
            self.assertEqual(consumer.send("next"), "2 9")
            self.assertEqual(consumer.send("held"), "1 7")
            self.assertEqual(consumer.send("close"), "closed")
            self.assertEqual(consumer.send("held"), "1 7")
            consumer.finish()
            publisher.finish()
            self.assertFalse(path.exists())

    def test_injected_publisher_preserves_signals_and_unloads(self):
        from test_injected_io import SOURCE
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            folder = Path(tmp)
            source = folder / "probe.c"
            source.write_text('#include <stdlib.h>\n#include <unistd.h>\n' + SOURCE.replace(
                "present(4, 4, pixels, sizeof(pixels));",
                'present(4, 4, pixels, sizeof(pixels)); assert(access(getenv("KATZENSTEG_PUBLISH"), F_OK) == 0);'))
            command = ["cc", "-pthread", str(source), "-o", str(folder / "probe")]
            if sys.platform != "darwin":
                command.append("-ldl")
            subprocess.run(command, check=True, capture_output=True)
            library = ROOT / "zig-out/lib" / ("libkatzensteg-core.dylib" if sys.platform == "darwin" else "libkatzensteg-core.so")
            result = subprocess.run([str(folder / "probe"), str(library)], env=dict(os.environ, KATZENSTEG_PUBLISH=str(folder / "source")), start_new_session=True, capture_output=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual(result.stdout + result.stderr, b"")
            self.assertFalse((folder / "source").exists())

    def test_app_publishes_without_a_controlling_terminal(self):
        for profile in ("probe.embed.basic_sdl", "probe.embed.basic_sdl3"):
            for mode in ("sync_compose", "queued_replay"):
                with self.subTest(profile=profile, mode=mode), tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
                    path = Path(tmp) / "source"
                    env = dict(os.environ, KATZENSTEG_REPO=str(ROOT), KATZENSTEG_TARGET=f"jackstay:{path}", SDL_VIDEODRIVER="dummy", SDL_RENDER_DRIVER="software", KATZENSTEG_REAL_WINDOW="hide", KATZENSTEG_INTERCEPT_MODE=mode, COLUMNS="12", LINES="4")
                    app = Peer("", path, command=[str(ROOT / "zig-out/bin/katzensteg"), profile], env=env)
                    self.addCleanup(app.cleanup)
                    deadline = time.monotonic() + 8
                    while not path.exists() and app.process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertTrue(path.exists(), "in-process publisher never became ready")
                    consumer = Peer("consume", path)
                    self.addCleanup(consumer.cleanup)
                    self.assertEqual(consumer.read(), "ready")
                    frame = consumer.send("next")
                    self.assertEqual(int(frame.split()[0]), 640)
                    consumer.finish()
                    app.cleanup()

    def test_native_consumer_uses_existing_presentation_and_observation(self):
        for placeholder in (False, True):
            with self.subTest(placeholder=placeholder), tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
                path = Path(tmp) / "source"
                publisher = Peer("publish", path)
                self.addCleanup(publisher.cleanup)
                self.assertEqual(publisher.read(), "ready")
                self.assertEqual(publisher.send("2 42"), "published")
                env = dict(os.environ, KATZENSTEG_REPO=str(ROOT), KATZENSTEG_OBSERVE="1")
                consumer = Peer("", path, command=[str(ROOT / "zig-out/bin/katzensteg"), "--embed-jsonl", "jackstay-source", str(path)], env=env)
                self.addCleanup(consumer.cleanup)
                attach = dict(type="attach", window_id="main", aspect="fit", id_ranges=dict(image=[[10000,19999]], placement=[[20000,29999]]), rect_cells=dict(row=1, col=1, rows=10, cols=20), upload=dict(profile="file_whole", path=str(Path(tmp) / "upload"), high_water=4096))
                if placeholder:
                    for key in ("rect_cells", "aspect", "id_ranges"):
                        del attach[key]
                    attach["placeholder"] = dict(image_id=777, cols=20, rows=10)
                consumer.process.stdin.write((json.dumps(attach) + "\n").encode())
                uploaded = False
                while True:
                    message = json.loads(consumer.read())
                    if message["type"] == "frame_batch":
                        uploaded |= bool(message["groups"]["uploads"])
                    if message["type"] == "presentation_status":
                        self.assertEqual(message["source_px"], dict(w=2, h=1))
                        self.assertFalse(message["input_supported"])
                        break
                self.assertTrue(uploaded)
                snapshot = Path(tmp) / "snapshot.rgba"
                consumer.process.stdin.write((json.dumps(dict(type="observe", window_id="main", request_id=1, path=str(snapshot), format="rgba")) + "\n").encode())
                while True:
                    message = json.loads(consumer.read())
                    if message["type"] == "observation":
                        self.assertEqual(message["width"], 2)
                        break
                self.assertEqual(snapshot.read_bytes(), bytes([42]) * 8)
                consumer.process.stdin.write(b'{"type":"shutdown"}\n')
                consumer.finish()
                publisher.finish()
            self.assertFalse(path.exists())

    def test_slow_consumer_and_abrupt_exit(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            publisher, consumer = self.peers(Path(tmp) / "source")
            self.assertEqual(publisher.send("1 1"), "published")
            self.assertEqual(consumer.send("hold"), "1 1")
            for value in range(2, 100):
                self.assertEqual(publisher.send(f"1 {value}"), "published")
            self.assertEqual(consumer.send("next"), "1 99")
            self.assertEqual(consumer.send("held"), "1 1")
            consumer.process.kill()
            consumer.process.wait()
            publisher.finish()

    def test_capacity_pause_recovers_after_held_frame_release(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            publisher, consumer = self.peers(Path(tmp) / "source", "publish-small")
            self.assertEqual(publisher.send("8192 7"), "published")
            self.assertEqual(consumer.send("hold"), "8192 7")
            self.assertEqual(publisher.send("16384 9"), "dropped")
            self.assertEqual(consumer.send("poll"), "polled")
            self.assertEqual(publisher.send("16384 9"), "dropped")
            self.assertEqual(consumer.send("held"), "8192 7")
            self.assertEqual(consumer.send("release"), "released")
            deadline = time.monotonic() + 5
            while publisher.send("16384 9") != "published":
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            self.assertEqual(consumer.send("next"), "16384 9")
            consumer.finish()
            publisher.finish()

    def test_host_shutdown_cancels_stalled_source_setup(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            path = str(Path(tmp) / "source")
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.settimeout(5)
                consumer = Peer("", path, command=[str(ROOT / "zig-out/bin/katzensteg"), "--embed-jsonl", "jackstay-source", path])
                self.addCleanup(consumer.cleanup)
                stream = listener.accept()[0]
                fd = C.c_int32(stream.detach())
                suffix = "dylib" if sys.platform == "darwin" else "so"
                library = C.CDLL(str(ROOT / "zig-out/lib" / f"libjackstay.{suffix}"))
                library.ft_source_bootstrap_accept.argtypes = [C.POINTER(C.c_int32), C.c_void_p, C.POINTER(C.c_void_p)]
                server = C.c_void_p()
                self.assertEqual(library.ft_source_bootstrap_accept(C.byref(fd), None, C.byref(server)), 0)
                self.assertIsNone(server.value)
                # Bootstrap is complete; deliberately stall cancellable CPU setup.
                with socket.socket(fileno=fd.value):
                    consumer.process.stdin.write(b'{"type":"shutdown"}\n')
                    consumer.finish()

    def test_host_shutdown_during_bootstrap_uses_bounded_exit(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            path = str(Path(tmp) / "source")
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.settimeout(5)
                consumer = Peer("", path, command=[str(ROOT / "zig-out/bin/katzensteg"), "--embed-jsonl", "jackstay-source", path])
                self.addCleanup(consumer.cleanup)
                with listener.accept()[0]:
                    started = time.monotonic()
                    consumer.process.stdin.write(b'{"type":"shutdown"}\n')
                    consumer.process.wait(timeout=4)
                    self.assertLess(time.monotonic() - started, 4)
                    # Bootstrap currently has no cancellation handle. The launcher
                    # forces exit after its grace period; never claim clean exit.
                    self.assertNotEqual(consumer.process.returncode, 0)

    def test_optional_input_does_not_hide_bootstrap_protocol_failure(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            path = str(Path(tmp) / "source")
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(path)
                listener.listen(1)
                listener.settimeout(5)
                consumer = Peer("", path, command=[str(ROOT / "zig-out/bin/katzensteg"), "--embed-jsonl", "jackstay-source", path])
                self.addCleanup(consumer.cleanup)
                with listener.accept()[0] as peer:
                    peer.sendall(b"not a bootstrap reply")
                consumer.process.wait(timeout=8)
                self.assertNotEqual(consumer.process.returncode, 0)

    def test_two_independent_consumers(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            path = Path(tmp) / "source"
            publisher = Peer("publish", path)
            self.addCleanup(publisher.cleanup)
            self.assertEqual(publisher.read(), "ready")
            consumers = [Peer("consume-one", path) for _ in range(2)]
            for consumer in consumers:
                self.addCleanup(consumer.cleanup)
                self.assertEqual(consumer.read(), "ready")
            self.assertEqual(publisher.send("1 33"), "published")
            for consumer in consumers:
                self.assertEqual(consumer.send("next"), "1 33")
                consumer.finish()
            publisher.finish()

    def test_publisher_shutdown_waits_for_bounded_bootstrap(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            path = Path(tmp) / "source"
            publisher = Peer("publish", path)
            self.addCleanup(publisher.cleanup)
            self.assertEqual(publisher.read(), "ready")
            with socket.socket(socket.AF_UNIX) as stalled:
                stalled.connect(str(path))
                time.sleep(0.05)
                publisher.finish()
            self.assertFalse(path.exists())

    def test_publisher_exit_wakes_consumer(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            publisher, consumer = self.peers(Path(tmp) / "source")
            consumer.process.stdin.write(b'next\n')
            publisher.process.kill()
            publisher.process.wait(timeout=5)
            consumer.process.wait(timeout=5)
            self.assertIn(b"Closed", consumer.process.stderr.read())

    def test_no_consumer_and_existing_endpoint(self):
        with tempfile.TemporaryDirectory(prefix="ks-js-", dir="/tmp") as tmp:
            path = Path(tmp) / "source"
            publisher = Peer("publish", path)
            self.addCleanup(publisher.cleanup)
            self.assertEqual(publisher.read(), "ready")
            inode = path.stat().st_ino
            other = Peer("publish", path)
            self.addCleanup(other.cleanup)
            other.process.wait(timeout=8)
            self.assertNotEqual(other.process.returncode, 0)
            self.assertEqual(path.stat().st_ino, inode)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(publisher.send("1 3"), "published")
            publisher.finish()


if __name__ == "__main__":
    unittest.main()
