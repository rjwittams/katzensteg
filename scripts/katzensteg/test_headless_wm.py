#!/usr/bin/env python3
"""Headless WM HTTP/PTY regression: real SDL producers, no desktop renderer."""
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import socket
import struct
import sys
import subprocess
import tempfile
import termios
import time
import threading
import unittest
import zlib
import urllib.error
import urllib.request
import fcntl
from concurrent.futures import ThreadPoolExecutor

REPO = Path(__file__).resolve().parents[2]


class HeadlessHostTest(unittest.TestCase):
    def test_default_terminal_is_concrete_before_background_detach(self):
        with tempfile.TemporaryDirectory(prefix="ks-headless-ctty-") as directory:
            master, slave = pty.openpty()
            tty = os.ttyname(slave)
            host_file = Path(directory) / "host.json"
            descriptor = None
            shell = None
            def controlling_terminal():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            try:
                # Keep the session leader alive like an interactive shell.
                # Exiting it would hang up the PTY independently of setsid.
                helper = "import subprocess,sys,signal; r=subprocess.run(sys.argv[1:],capture_output=True); print(r.stdout.decode() if r.returncode == 0 else r.stderr.decode(),flush=True); signal.pause()"
                shell = subprocess.Popen([sys.executable, "-c", helper, str(REPO / "zig-out/bin/katzensteg-wm"), "--headless", "--background", "--host-file", str(host_file)], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=controlling_terminal, env=dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_RENDER_DRIVER="software", KATZENSTEG_REAL_WINDOW="hide"))
                self.assertTrue(select.select([shell.stdout], [], [], 10)[0], "background startup timed out")
                descriptor = json.loads(shell.stdout.readline())
                self.assertEqual(descriptor["tty"], tty)
                def post(path, body, client=None):
                    headers = {"Authorization": "Bearer " + descriptor["token"], "Content-Type": "application/json"}
                    if client:
                        headers["X-Katzensteg-Client"] = client["id"]
                    request = urllib.request.Request(f"http://127.0.0.1:{descriptor['port']}/v1{path}", data=json.dumps(body).encode(), headers=headers)
                    with urllib.request.urlopen(request, timeout=3) as response:
                        return json.loads(response.read())
                client = post("/clients", {})
                session = post("/sessions", {"profile": "probe.embed.basic_sdl"}, client)["id"]
                post(f"/sessions/{session}/grid", {"cols": 30, "rows": 10}, client)
                raw = bytearray()
                deadline = time.monotonic() + 5
                while b"a=p,U=1" not in raw:
                    self.assertLess(time.monotonic(), deadline, "detached host did not deliver graphics")
                    if select.select([master], [], [], 0.05)[0]:
                        raw.extend(os.read(master, 65536))
                self.assertIn(b"a=t", raw)
                post("/client/close", {}, client)
            finally:
                if descriptor:
                    os.kill(descriptor["pid"], signal.SIGTERM)
                    deadline = time.monotonic() + 4
                    while host_file.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                os.close(master)
                os.close(slave)
                if shell is not None:
                    shell.kill()
                    shell.communicate(timeout=5)

    def test_background_startup_race_reuses_one_ready_host(self):
        with tempfile.TemporaryDirectory(prefix="ks-headless-start-") as directory:
            master, slave = pty.openpty()
            host_file = Path(directory) / "host.json"
            argv = [str(REPO / "zig-out/bin/katzensteg-wm"), "--headless", "--background", "--tty", os.ttyname(slave), "--host-file", str(host_file)]
            descriptor = None
            try:
                def start():
                    result = subprocess.run(argv, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    return json.loads(result.stdout)
                with ThreadPoolExecutor(max_workers=2) as workers:
                    descriptors = list(workers.map(lambda _: start(), range(2)))
                descriptor = descriptors[0]
                self.assertEqual(descriptors[0], descriptors[1])
                self.assertEqual(json.loads(host_file.read_text()), descriptor)
                self.assertEqual(host_file.stat().st_mode & 0o777, 0o600)
                self.assertFalse(select.select([master], [], [], 0)[0])
            finally:
                if descriptor is None and host_file.exists():
                    descriptor = json.loads(host_file.read_text())
                if descriptor:
                    os.kill(descriptor["pid"], signal.SIGTERM)
                    deadline = time.monotonic() + 4
                    while host_file.exists() and time.monotonic() < deadline:
                        time.sleep(0.01)
                    self.assertFalse(host_file.exists())
                os.close(master)
                os.close(slave)

    def test_clients_launch_grid_input_external_lifetime_and_graphics(self):
        with tempfile.TemporaryDirectory(prefix="ks-headless-") as directory:
            folder = Path(directory)
            profiles = {name: {"extends": ["probe.input"], "stdout": str(folder / (name + ".log")), "stderr": "stdout"} for name in ("first", "second", "external")}
            (folder / "profiles.json").write_text(json.dumps({"profiles": profiles}))
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 1000, 800))
            original_termios = termios.tcgetattr(slave)
            tty = os.ttyname(slave)
            host_file = folder / "host.json"
            env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_RENDER_DRIVER="software", KATZENSTEG_REAL_WINDOW="hide", KATZENSTEG_PROFILE_DIR=str(REPO / "profiles") + ":" + directory)
            env.pop("KATZENSTEG_TARGET", None)
            env.pop("KATZENSTEG_OBSERVE", None)
            stderr = open(folder / "host.log", "wb")
            proc = subprocess.Popen([str(REPO / "zig-out/bin/katzensteg-wm"), "--headless", "--tty", tty, "--host-file", str(host_file)], env=env, stdin=subprocess.DEVNULL, stdout=stderr, stderr=stderr)
            raw = bytearray()
            external = None
            owner = subprocess.Popen(["/bin/sleep", "60"])

            pump_lock = threading.Lock()
            reader_stop = threading.Event()
            reader_pause = threading.Event()
            def pump():
                with pump_lock:
                    if master < 0:
                        return
                    while select.select([master], [], [], 0)[0]:
                        raw.extend(os.read(master, 65536))

            def read_terminal():
                while not reader_stop.wait(0.005):
                    if not reader_pause.is_set():
                        pump()
            reader = threading.Thread(target=read_terminal)
            reader.start()

            def until(predicate, timeout=6):
                deadline = time.monotonic() + timeout
                while not predicate():
                    pump()
                    if proc.poll() is not None:
                        self.fail((proc.returncode, (folder / "host.log").read_text()))
                    self.assertLess(time.monotonic(), deadline, (folder / "host.log").read_text())
                    time.sleep(0.01)
                pump()

            try:
                until(host_file.exists)
                descriptor = json.loads(host_file.read_text())
                self.assertEqual(host_file.stat().st_mode & 0o777, 0o600)
                self.assertEqual(termios.tcgetattr(slave), original_termios)
                self.assertEqual(raw, b"")

                def api(path, body=None, client=None, token=True, expected=200):
                    headers = {"Content-Type": "application/json"}
                    if token:
                        headers["Authorization"] = "Bearer " + descriptor["token"]
                    if client:
                        headers["X-Katzensteg-Client"] = client["id"]
                    request = urllib.request.Request(f"http://127.0.0.1:{descriptor['port']}/v1{path}", data=None if body is None else json.dumps(body).encode(), headers=headers)
                    try:
                        response = urllib.request.urlopen(request, timeout=3)
                    except urllib.error.HTTPError as err:
                        response = err
                    with response:
                        text = response.read()
                        self.assertIn(response.status, expected if isinstance(expected, tuple) else (expected,), text)
                        return json.loads(text) if text else None

                api("/health", token=False, expected=401)
                health = api("/health")
                self.assertEqual(health["cell_px"], {"w": 10, "h": 20})
                # A stalled HTTP request cannot hold up other clients.
                with socket.create_connection(("127.0.0.1", descriptor["port"])) as stalled:
                    stalled.sendall(b"POST /v1/sessions HTTP/1.1\r\nContent-Length: 4000\r\n\r\n{")
                    api("/health")

                # A second startup reuses the terminal host, including when its
                # caller supplies a different discovery-file path.
                reuse = subprocess.run([str(REPO / "zig-out/bin/katzensteg-wm"), "--headless", "--background", "--tty", tty], env=env, capture_output=True, timeout=5, check=True)
                self.assertEqual(json.loads(reuse.stdout)["pid"], proc.pid)
                api("/clients", {"parent_pid": 0}, expected=400)
                a = api("/clients", {"parent_pid": owner.pid})
                b = api("/clients", {})
                self.assertNotEqual(a["target"], b["target"])
                first = api("/sessions", {"profile": "first"}, a)["id"]
                second = api("/sessions", {"profile": "second"}, b)["id"]
                until(lambda: api("/sessions", client=a)[0]["source_px"] is not None)
                self.assertEqual([s["id"] for s in api("/sessions", client=a)], [first])
                api(f"/sessions/{second}/close", {}, a, expected=404)
                api(f"/sessions/{second}/refresh", {}, a, expected=404)
                api(f"/sessions/{first}/refresh", {}, a, expected=400)
                api(f"/sessions/{first}/grid", {"cols": 0, "rows": 12}, a, expected=400)
                for client, session in ((a, first), (b, second)):
                    api(f"/sessions/{session}/grid", {"cols": 32, "rows": 12}, client)
                until(lambda: all(s["state"] == "ready" for s in api("/sessions", client=a)))
                until(lambda: b"a=p,U=1" in raw)
                # Darwin exposes queued slave output. With a full queue the
                # host must keep serving requests instead of starting a frame
                # write inside another application's partially drained repaint.
                if sys.platform == "darwin":
                    reader_pause.set()
                    filler = os.open(tty, os.O_WRONLY | os.O_NONBLOCK)
                    try:
                        with pump_lock:
                            while True:
                                try:
                                    os.write(filler, b"\x01" * 1024)
                                except BlockingIOError:
                                    break
                        queued = struct.unpack("i", fcntl.ioctl(slave, termios.TIOCOUTQ, struct.pack("i", 0)))[0]
                        self.assertGreater(queued, 0)
                        # Allow an actual producer frame to reach the host.
                        time.sleep(0.1)
                        api("/health")
                        api(f"/sessions/{first}/refresh", {}, a)
                        api("/health")
                    finally:
                        os.close(filler)
                        reader_pause.clear()
                    until(lambda: struct.unpack("i", fcntl.ioctl(slave, termios.TIOCOUTQ, struct.pack("i", 0)))[0] == 0)
                    # Filler bytes are not host output; remove only those before
                    # the final graphics-only output assertion.
                    with pump_lock:
                        raw[:] = raw.replace(b"\x01", b"")
                api(f"/sessions/{first}/refresh", {}, a)
                api(f"/sessions/{second}/observe", {}, a, expected=404)
                observation = api(f"/sessions/{first}/observe", {}, a)
                image_id = api("/sessions", client=a)[0]["image_id"]
                until(lambda: f"s=320,v=208,i={image_id}".encode() in raw)
                # A new session clears whatever an earlier host left under its
                # image id before the producer's first upload reaches the tty.
                self.assertLess(raw.index(f"a=d,d=I,i={image_id},q=2".encode()), raw.index(f"s=320,v=208,i={image_id}".encode()))
                # Physical cell size can change without changing the cell grid.
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 2000, 1600))
                until(lambda: f"s=640,v=416,i={image_id}".encode() in raw)
                unchanged_source = api("/sessions", client=a)[0]["source_px"]
                self.assertEqual(unchanged_source, {"w": observation["width"], "h": observation["height"]})
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 1000, 800))
                capture = Path(observation["path"])
                self.assertEqual(capture.stat().st_mode & 0o777, 0o600)
                self.assertEqual(capture.suffix, ".png")
                self.assertTrue(observation["newer"])
                png = capture.read_bytes()
                self.assertEqual(png[:8], b"\x89PNG\r\n\x1a\n")
                offset, compressed, dimensions = 8, bytearray(), None
                while offset < len(png):
                    size = struct.unpack_from(">I", png, offset)[0]
                    kind = png[offset + 4:offset + 8]
                    payload = png[offset + 8:offset + 8 + size]
                    self.assertEqual(zlib.crc32(kind + payload), struct.unpack_from(">I", png, offset + 8 + size)[0])
                    if kind == b"IHDR":
                        dimensions = struct.unpack(">IIBBBBB", payload)
                    if kind == b"IDAT":
                        compressed.extend(payload)
                    offset += 12 + size
                self.assertEqual(dimensions, (observation["width"], observation["height"], 8, 6, 0, 0, 0))
                self.assertEqual(len(zlib.decompress(compressed)), observation["height"] * (observation["width"] * 4 + 1))
                fresh = api(f"/sessions/{first}/observe", {"after_frame": observation["frame_id"]}, a)
                self.assertGreater(fresh["frame_id"], observation["frame_id"])
                self.assertEqual(fresh["path"], str(capture))
                # A bounded wait for an unreachable frame must not block health.
                with ThreadPoolExecutor(max_workers=1) as workers:
                    start = time.monotonic()
                    waiting = workers.submit(api, f"/sessions/{first}/observe", {"after_frame": 2**53}, a)
                    time.sleep(0.1)
                    api("/health")
                    api(f"/sessions/{first}/observe", {}, a, expected=409)
                    self.assertFalse(waiting.done())
                    stale = waiting.result(timeout=3)
                    self.assertFalse(stale["newer"])
                    self.assertLess(time.monotonic() - start, 3)
                api(f"/sessions/{first}/input", {"events": [
                    {"type": "pointer", "kind": "down", "x": 0, "y": 0, "button": "left"},
                    {"type": "pointer", "kind": "up", "x": 0, "y": 0, "button": "left"},
                    {"type": "key", "key": "a"},
                    {"type": "key", "key": "up", "ctrl": True},
                ]}, a)
                first_log = folder / "first.log"
                until(lambda: "key_down key=A" in first_log.read_text() and "mouse_button_up" in first_log.read_text())
                self.assertIn("x=0 y=0", first_log.read_text())
                self.assertNotIn("key_down key=A", (folder / "second.log").read_text())
                api(f"/sessions/{first}/input", {"events": [{"type": "pointer", "kind": "move", "x": 32, "y": 0}]}, a, expected=400)

                external = subprocess.Popen([str(REPO / "zig-out/bin/katzensteg"), "external"], env=dict(env, KATZENSTEG_TARGET=a["target"]), stdin=subprocess.DEVNULL, stdout=stderr, stderr=stderr)
                until(lambda: len(api("/sessions", client=a)) == 2)
                third = next(s for s in api("/sessions", client=a) if s["id"] != first)
                api(f"/sessions/{third['id']}/grid", {"cols": 20, "rows": 10}, a)
                external_capture = api(f"/sessions/{third['id']}/observe", {}, a)
                self.assertGreater(external_capture["width"], 0)
                self.assertTrue(Path(external_capture["path"]).exists())
                owner.terminate()
                owner.wait(timeout=2)
                until(lambda: api("/sessions", client=a, expected=(200, 403)) is None, timeout=2)
                until(lambda: external.poll() is not None)
                until(lambda: not capture.exists())
                self.assertEqual(api("/sessions", client=b)[0]["state"], "ready")
                api(f"/sessions/{second}/close", {}, b)
                until(lambda: api("/sessions", client=b)[0]["state"] == "exited")
                # Losing the output device exercises both the frame write
                # failure and the cleanup delete that previously killed the host.
                broken = api("/sessions", {"profile": "second"}, b)["id"]
                until(lambda: next(s for s in api("/sessions", client=b) if s["id"] == broken)["source_px"] is not None)
                self.assertEqual(termios.tcgetattr(slave), original_termios)
                pump()
                with pump_lock:
                    os.close(master)
                    master = -1
                api(f"/sessions/{broken}/grid", {"cols": 32, "rows": 12}, b)
                until(lambda: next(s for s in api("/sessions", client=b) if s["id"] == broken)["state"] == "exited")
                self.assertEqual(api("/health")["pid"], proc.pid)
                api("/client/close", {}, b)
                proc.terminate()
                deadline = time.monotonic() + 5
                while proc.poll() is None and time.monotonic() < deadline:
                    pump()
                    time.sleep(0.01)
                self.assertEqual(proc.wait(timeout=1), 0)
                pump()
                self.assertFalse(host_file.exists())
                sequences = re.findall(rb"\x1b_G[^\x1b]*\x1b\\", raw)
                self.assertEqual(b"".join(sequences), raw, "headless host must emit only graphics APCs")
                self.assertTrue(any(b"a=t" in sequence and b"t=f" in sequence for sequence in sequences))
                self.assertTrue(any(b"a=d,d=I" in sequence for sequence in sequences))
                self.assertTrue(all(len(sequence) <= 512 and b"q=2" in sequence for sequence in sequences))
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    deadline = time.monotonic() + 4
                    while proc.poll() is None and time.monotonic() < deadline:
                        pump()
                        time.sleep(0.01)
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
                if external is not None and external.poll() is None:
                    external.terminate()
                    external.wait(timeout=4)
                if owner.poll() is None:
                    owner.terminate()
                    owner.wait(timeout=2)
                reader_stop.set()
                reader.join(timeout=2)
                stderr.close()
                if master >= 0:
                    os.close(master)
                os.close(slave)


if __name__ == "__main__":
    unittest.main()
