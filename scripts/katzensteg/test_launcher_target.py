#!/usr/bin/env python3
"""Launcher/socket integration using a small producer in place of SDL."""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[2]
LAUNCHER = REPO / "zig-out/bin/katzensteg"

PRODUCER = r'''
import json, os, signal, sys, time
from pathlib import Path
config = json.loads(Path(os.environ['KATZENSTEG_CONFIG']).read_text())
Path(sys.argv[2]).write_text(str(os.getpid()))
if sys.argv[1] == 'hold':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while True: time.sleep(.05)
control = os.fdopen(config['presentation_control_fd'])
assert json.loads(control.readline()) == {'marker': 'control'}
os.write(config['presentation_fd'], b'presentation-only\n')
print('stdout:' + sys.stdin.readline().strip(), flush=True)
print('stderr:application', file=sys.stderr, flush=True)
sys.exit(7)
'''


class LauncherTargetTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ks-target-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.pidfile = self.root / "app.pid"
        app = self.root / "app.py"
        app.write_text(PRODUCER)
        (self.root / "profiles.json").write_text(json.dumps({"profiles": {
            name: {"target": sys.executable, "args": [str(app), name, str(self.pidfile)],
                   "stdout": "inherit", "stderr": "inherit"}
            for name in ("output", "hold")
        }}))
        self.env = dict(os.environ, KATZENSTEG_PROFILE_DIR=str(self.root),
                        KATZENSTEG_TARGET="jsonl:" + str(self.root / "host.sock"))

    def launch(self, profile="output", options=()):
        proc = subprocess.Popen([str(LAUNCHER), *options, profile], env=self.env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        self.addCleanup(self.cleanup_process, proc)
        return proc

    def cleanup_process(self, proc):
        if proc.poll() is None:
            if self.pidfile.exists():
                try:
                    os.kill(int(self.pidfile.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.kill()
        proc.communicate()

    def host(self):
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(server.close)
        server.bind(str(self.root / "host.sock"))
        server.listen()
        server.settimeout(5)
        return server

    def accept(self, server):
        peer, _ = server.accept()
        self.addCleanup(peer.close)
        peer.settimeout(5)
        line = bytearray()
        while not line.endswith(b'\n'):
            line += peer.recv(1)
        registration = json.loads(line)
        self.assertEqual(registration['type'], 'register')
        peer.sendall(b'{"type":"registered","version":1,"session_id":1}\n'
                     b'{"marker":"control"}\n')
        return peer

    def await_app(self):
        deadline = time.monotonic() + 5
        while not self.pidfile.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(self.pidfile.exists())
        # Let the producer install its signal handler after recording its PID.
        time.sleep(.05)
        return int(self.pidfile.read_text())

    def test_output_input_and_exit_status_are_separate_from_presentation(self):
        server = self.host()
        proc = self.launch()
        peer = self.accept(server)
        stdout, stderr = proc.communicate(b'55\n', timeout=5)
        self.assertEqual(proc.returncode, 7)
        self.assertEqual(stdout, b'stdout:55\n')
        self.assertEqual(stderr, b'stderr:application\n')
        chunks = []
        while data := peer.recv(4096):
            chunks.append(data)
        self.assertEqual(b''.join(chunks), b'presentation-only\n')

    def test_unavailable_target_does_not_spawn(self):
        proc = self.launch()
        stdout, stderr = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 69)
        self.assertEqual(stdout, b'')
        self.assertIn(b'cannot connect to target', stderr)
        self.assertFalse(self.pidfile.exists())

    def test_explicit_stdio_ignores_invalid_inherited_target(self):
        self.env['KATZENSTEG_TARGET'] = 'invalid:target'
        proc = self.launch(options=('--embed-jsonl',))
        stdout, _ = proc.communicate(b'{"marker":"control"}\n', timeout=5)
        self.assertEqual(proc.returncode, 7)
        self.assertIn(b'presentation-only\n', stdout)
        self.assertTrue(self.pidfile.exists())

    def test_host_loss_terminates_and_reaps_app(self):
        server = self.host()
        proc = self.launch('hold')
        peer = self.accept(server)
        pid = self.await_app()
        peer.close()
        proc.communicate(timeout=6)
        self.assertNotEqual(proc.returncode, 0)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_shell_interrupt_terminates_and_reaps_app(self):
        server = self.host()
        proc = self.launch('hold')
        self.accept(server)
        pid = self.await_app()
        proc.send_signal(signal.SIGINT)
        proc.communicate(timeout=6)
        self.assertEqual(proc.returncode, 130)
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_rejected_registration_does_not_spawn(self):
        server = self.host()
        proc = self.launch()
        peer, _ = server.accept()
        peer.sendall(b'{"type":"registered","version":2,"session_id":1}\n')
        peer.close()
        proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 69)
        self.assertFalse(self.pidfile.exists())


if __name__ == '__main__':
    unittest.main()
