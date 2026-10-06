#!/usr/bin/env python3
"""WM failure/recovery scenarios in a private, resource-limited subprocess."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import resource
import select
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

REPO = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "linux", "Linux FD exhaustion and /proc wake counts")
class WmRecoveryTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ks-wm-recovery-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.master, self.slave = pty.openpty()
        self.addCleanup(os.close, self.master)
        self.addCleanup(os.close, self.slave)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 960, 480))
        self.peers = []
        self.addCleanup(lambda: [peer.close() for peer in self.peers])
        self.output = bytearray()

    def start(self):
        def child_setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
            # Only the child gets this limit; the runner keeps its original limit.
            resource.setrlimit(resource.RLIMIT_NOFILE, (32, 32))
        self.path = str(self.root / "listener.sock")
        self.proc = subprocess.Popen(
            [str(REPO / "zig-out/bin/katzensteg-wm"), "--listen", self.path],
            stdin=self.slave, stdout=self.slave, stderr=self.slave,
            preexec_fn=child_setup, env=dict(os.environ, KATZENSTEG_OUTPUT_PROFILE="direct_apc"))
        self.addCleanup(self.stop)
        self.log = Path(f"/tmp/katzensteg-{self.proc.pid}.log")
        self.addCleanup(self.log.unlink, missing_ok=True)
        self.until(lambda: b"windows=0" in self.output)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=5)

    def pump(self):
        if select.select([self.master], [], [], .02)[0]:
            try:
                self.output.extend(os.read(self.master, 65536))
            except OSError as err:
                if err.errno != errno.EIO:
                    raise

    def until(self, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.pump()
            self.assertIsNone(self.proc.poll(), bytes(self.output[-2000:]))
            self.assertLess(time.monotonic(), deadline, bytes(self.output[-2000:]))

    def connect(self, title):
        # Socket boundary fake: speaks the real external producer protocol.
        peer = socket.socket(socket.AF_UNIX)
        self.peers.append(peer)
        peer.settimeout(.3)
        peer.connect(self.path)
        peer.sendall(json.dumps(dict(type="register", version=1, title=title)).encode() + b"\n")
        return peer

    def attached(self, peer):
        data = bytearray()
        deadline = time.monotonic() + 8
        while b'"type":"attach"' not in data:
            self.pump()
            try:
                chunk = peer.recv(65536)
                self.assertTrue(chunk, data)
                data.extend(chunk)
            except socket.timeout:
                pass
            self.assertIsNone(self.proc.poll())
            self.assertLess(time.monotonic(), deadline, data)
        self.assertIn(b'"type":"registered"', data)

    def failures(self):
        return self.log.read_text().count("listener accept failed; retrying in one second: ProcessFdQuotaExceeded") if self.log.exists() else 0

    def wakes(self):
        # Main-thread voluntary context switches count event-loop sleeps/wakes;
        # unlike log count, this also detects a loop spinning between retries.
        text = Path(f"/proc/{self.proc.pid}/task/{self.proc.pid}/status").read_text()
        return int(next(line.split(":")[1] for line in text.splitlines() if line.startswith("voluntary_ctxt_switches:")))

    def test_existing_session_survives_accept_exhaustion_and_recovers(self):
        # #38: EMFILE must preserve an existing session, retry at a bounded rate,
        # and accept a new registration once pressure is released.
        runner_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
        self.start()
        existing = self.connect("existing")
        self.attached(existing)
        # Registered clients stay open rather than expiring as pending clients.
        # One extra queued connection forces accept() itself to encounter EMFILE.
        for index in range(40):
            peer = self.connect(f"pressure-{index}")
            deadline = time.monotonic() + .4
            while time.monotonic() < deadline and not self.failures():
                self.pump()
            if self.failures():
                break
        self.until(lambda: self.failures() > 0)
        before_failures, before_wakes = self.failures(), self.wakes()
        cpu_path = Path(f"/proc/{self.proc.pid}/task/{self.proc.pid}/schedstat")
        before_cpu = int(cpu_path.read_text().split()[0])
        started = time.monotonic()
        while time.monotonic() - started < 2.2:
            self.pump()
            self.assertIsNone(self.proc.poll())
        # A 20ms lifecycle tick allows ~110 wakes; leave scheduler headroom.
        self.assertLessEqual(self.wakes() - before_wakes, 220)
        self.assertLess(int(cpu_path.read_text().split()[0]) - before_cpu, 500_000_000)
        self.assertGreaterEqual(self.failures() - before_failures, 1)
        self.assertLessEqual(self.failures() - before_failures, 3)
        # Input is still routed through the original connection under pressure.
        existing.sendall(b'{"type":"presentation_status","window_id":"main","ready_to_show":true,"input_supported":true}\n')
        os.write(self.master, b"\x1d\t")
        self.until(lambda: b"existing" in self.output)
        os.write(self.master, b"x")
        data = bytearray()
        deadline = time.monotonic() + 5
        while b'"bytes":"x"' not in data:
            self.pump()
            try:
                data.extend(existing.recv(65536))
            except socket.timeout:
                pass
            self.assertLess(time.monotonic(), deadline, data)
        for peer in self.peers[1:]:
            peer.close()
        recovered = self.connect("recovered")
        self.attached(recovered)
        self.assertIsNone(self.proc.poll())
        self.assertEqual(resource.getrlimit(resource.RLIMIT_NOFILE), runner_limit)


if __name__ == "__main__":
    unittest.main()
