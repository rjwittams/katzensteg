#!/usr/bin/env python3
"""Wrap-mode acceptance on isolated PTYs; never touches the caller's terminal."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
import urllib.request

REPO = Path(__file__).resolve().parents[2]
CHILD = r'''
import fcntl,json,os,sys,termios,tty
from pathlib import Path
root=Path(sys.argv[1])
tty.setraw(0)
(root/'child.json').write_text(json.dumps({'host':json.loads(os.environ['KATZENSTEG_WM_HOST']),'tty':os.ttyname(0),'pid':os.getpid(),'args':sys.argv[2:]}))
os.write(1,b'READY')
while True:
    key=os.read(0,1)
    if key==b'\x03': os.write(1,b'CTRL_C_RECEIVED')
    if key==b's':
        size=fcntl.ioctl(0,termios.TIOCGWINSZ,b'\0'*8)
        (root/'size').write_bytes(size)
    if key==b'w':
        data=(root/'payload').read_bytes()
        while data: data=data[os.write(1,data):]
        (root/'written').write_text('done')
    if key==b'q':
        os.write(1,b'FINAL_OUTPUT')
        sys.exit(37)
    if not key: break
'''

class WrappedProcess:
    """Keep an outer session leader alive so macOS does not revoke its tty."""
    def __init__(self, supervisor, root):
        self.supervisor, self.root = supervisor, root
    @property
    def returncode(self):
        path = self.root/'exit'
        value = path.read_text().strip() if path.exists() else ''
        return int(value) if value else None
    def poll(self): return self.returncode
    def send(self, sig):
        path=self.root/'wrapper.pid'
        if path.exists():
            try: os.kill(int(path.read_text()),sig)
            except ProcessLookupError: pass
    def terminate(self): self.send(signal.SIGTERM)
    def kill(self): self.send(signal.SIGKILL)
    def wait(self, timeout):
        deadline=time.monotonic()+timeout
        while self.returncode is None:
            if time.monotonic()>deadline: raise subprocess.TimeoutExpired('wrapper',timeout)
            time.sleep(.01)
        return self.returncode

class WrapTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ks-wrap-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.master, self.slave = pty.openpty()
        self.addCleanup(lambda: os.close(self.master) if self.master is not None else None)
        self.addCleanup(os.close, self.slave)
        self.original = termios.tcgetattr(self.slave)
        self.size = struct.pack('HHHH', 24, 80, 960, 480)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, self.size)
        self.output = bytearray()
        self.process = None

    def start(self, command=None):
        child = self.root / 'child.py'
        child.write_text(CHILD)
        def ctty():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        supervisor_code = "import subprocess,sys,signal; from pathlib import Path; r=Path(sys.argv[1]); signal.signal(signal.SIGHUP, signal.SIG_IGN); p=subprocess.Popen(sys.argv[2:]); (r/'wrapper.pid').write_text(str(p.pid)); code=p.wait(); (r/'exit').write_text(str(code)); signal.pause()"
        supervisor = subprocess.Popen(
            [sys.executable, '-c', supervisor_code, str(self.root), str(REPO/'zig-out/bin/katzensteg-wm'), '--host-file', str(self.root/'host.json'), '--wrap', '--',
             *(command or [sys.executable, str(child), str(self.root), '--help'])],
            stdin=self.slave, stdout=self.slave, stderr=self.slave, preexec_fn=ctty,
            env=dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_RENDER_DRIVER='software', KATZENSTEG_REAL_WINDOW='hide', KATZENSTEG_REPO=str(REPO)))
        self.process = WrappedProcess(supervisor, self.root)
        def finish_supervisor():
            supervisor.kill()
            deadline = time.monotonic() + 5
            while supervisor.poll() is None and time.monotonic() < deadline:
                self.read()
            supervisor.wait(timeout=1)
        self.addCleanup(finish_supervisor)
        self.addCleanup(self.stop)
        if command is None:
            self.until(lambda: (self.root/'child.json').exists() and b'READY' in self.output)
            self.child = json.loads((self.root/'child.json').read_text())
            self.host = self.child['host']

    def assert_restored(self):
        actual = termios.tcgetattr(self.slave)
        expected = self.original.copy()
        # macOS sets PENDIN when returning to canonical mode: queued input will
        # be reprocessed on the next read. It is kernel state, not a saved mode.
        actual[3] &= ~termios.PENDIN
        expected[3] &= ~termios.PENDIN
        self.assertEqual(actual, expected)

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try: self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)

    def read(self, timeout=.01):
        if self.master is None:
            time.sleep(timeout)
            return
        if select.select([self.master], [], [], timeout)[0]:
            try: self.output.extend(os.read(self.master, 65536))
            except OSError: pass

    def until(self, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while not predicate():
            self.read()
            self.assertLess(time.monotonic(), deadline, bytes(self.output[-1500:]))

    def api(self, path, body=None, client=None):
        headers={'Authorization': 'Bearer '+self.host['token']}
        if client: headers['X-Katzensteg-Client']=client['id']
        req=urllib.request.Request(f"http://127.0.0.1:{self.host['port']}/v1{path}",
                                   data=None if body is None else json.dumps(body).encode(), headers=headers)
        with urllib.request.urlopen(req, timeout=3) as response:
            data=response.read()
            return json.loads(data) if data else None

    def emit(self, payload):
        (self.root/'written').unlink(missing_ok=True)
        (self.root/'payload').write_bytes(payload)
        os.write(self.master,b'w')
        self.until(lambda: (self.root/'written').exists())
        # Drain bytes already written by the child into the relay.
        self.until(lambda: payload in self.output)

    def panel(self):
        client=self.api('/clients', {})
        session=self.api('/sessions', {'profile':'probe.embed.basic_sdl'}, client)['id']
        self.api(f'/sessions/{session}/grid', {'cols':30,'rows':10}, client)
        return client

    def test_input_resize_descriptor_exit_and_restore(self):
        self.start()
        self.assertEqual(self.child['args'], ['--help'])
        self.assertNotEqual(self.child['tty'], os.ttyname(self.slave))
        self.assertEqual(self.host['tty'], os.ttyname(self.slave))
        self.assertEqual(self.api('/health')['cell_px'], {'w':12, 'h':20})
        os.write(self.master,b'\x03')
        self.until(lambda: b'CTRL_C_RECEIVED' in self.output)
        self.assertIsNone(self.process.poll())
        resized=struct.pack('HHHH',40,100,1400,960)
        fcntl.ioctl(self.slave,termios.TIOCSWINSZ,resized)
        deadline=time.monotonic()+3
        while True:
            os.write(self.master,b's')
            time.sleep(.03)
            if (self.root/'size').exists() and (self.root/'size').read_bytes()==resized: break
            self.assertLess(time.monotonic(),deadline)
        os.write(self.master,b'q')
        self.until(lambda: self.process.poll() is not None)
        self.read()
        self.assertEqual(self.process.returncode,37)
        self.assertIn(b'FINAL_OUTPUT',self.output)
        self.assert_restored()
        self.assertFalse((self.root/'host.json').exists())

    def check_graphics_boundary(self, start, end):
        self.start()
        self.emit(start)
        boundary = len(self.output)
        client=self.panel()
        for _ in range(30): self.read(.02)
        self.assertNotIn(b'\x1b_G', self.output[boundary:])
        self.emit(end)
        self.until(lambda: b'a=p,U=1' in self.output)
        data=bytes(self.output)
        self.assertLess(data.index(start)+len(start),data.index(b'a=p,U=1'))
        self.assertLess(data.index(end),data.index(b'a=p,U=1'))
        # Teardown also goes through the relay; deletion must not split OSC.
        self.emit(b'\x1b]closing')
        boundary = len(self.output)
        self.api('/client/close',{},client)
        deadline = time.monotonic() + .5
        while time.monotonic() < deadline: self.read(.02)
        self.assertNotIn(b'\x1b_G', self.output[boundary:])
        self.emit(b'\x07')
        self.until(lambda: b'a=d' in self.output[boundary:])

    def test_graphics_wait_for_string(self):
        self.check_graphics_boundary(b'\x1b]title', b'\x07')

    def test_graphics_wait_for_entire_chunked_upload(self):
        self.check_graphics_boundary(b'\x1b_Gm=1;AAAA\x1b\\', b'\x1b_Gm=0;BBBB\x1b\\')

    def test_backpressure_keeps_http_responsive_and_streams_large_strings(self):
        self.start()
        payload=b'\x1b]'+b'x'*1_000_000+b'\x07'
        (self.root/'payload').write_bytes(payload)
        os.write(self.master,b'w')
        time.sleep(.2) # Stop draining the outer PTY to impose backpressure.
        self.assertEqual(self.api('/health')['tty'],os.ttyname(self.slave))
        self.until(lambda: payload in self.output, timeout=10)
        os.write(self.master,b'q')
        self.until(lambda: self.process.poll() is not None)
        self.assertEqual(self.process.returncode,37)

    def test_exit_drains_large_final_output(self):
        self.start([sys.executable, '-c', "import os,sys; data=b'x'*1000000; exec('while data: data=data[os.write(1,data):]'); sys.exit(19)"])
        self.until(lambda: self.process.poll() is not None)
        for _ in range(5): self.read()
        self.assertEqual(self.process.returncode, 19)
        self.assertEqual(bytes(self.output), b'x'*1000000)
        self.assert_restored()

    def test_terminal_loss_stops_wrapper_and_child(self):
        self.start()
        os.close(self.master)
        self.master = None
        self.until(lambda: self.process.poll() is not None)
        self.assertNotEqual(self.process.returncode, 0)
        with self.assertRaises(ProcessLookupError): os.kill(self.child['pid'], 0)
        self.assertFalse((self.root/'host.json').exists())

    def test_wrapper_termination_restores_terminal(self):
        self.start()
        self.process.terminate()
        self.until(lambda: self.process.poll() is not None)
        self.assertEqual(self.process.returncode, 128 + signal.SIGTERM)
        self.assert_restored()
        self.assertFalse((self.root/'host.json').exists())

    def test_exec_failure_restores_terminal(self):
        self.start(['/definitely/not/a/command'])
        self.until(lambda: self.process.poll() is not None)
        self.assertEqual(self.process.returncode,127)
        self.assert_restored()

if __name__=='__main__':
    unittest.main()
