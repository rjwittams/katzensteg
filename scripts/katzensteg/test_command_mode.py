#!/usr/bin/env python3
"""Command routing and bounded quit on isolated PTYs, with real SDL adapters."""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]

class CommandMode(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='ks-command-', dir='/tmp')
        cls.root = Path(cls.tmp.name)
        profiles = {}
        for version in (2, 3):
            binary = cls.root / f'app{version}'
            flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', f'sdl{version}'], text=True))
            subprocess.run(['cc', str(ROOT/'scripts/katzensteg/fixtures/command_mode_app.c'), '-o', str(binary)] + (['-DUSE_SDL3'] if version == 3 else []) + flags, check=True)
            profiles[f'test.command{version}'] = {'extends': [f'adapter.sdl{version}_preload'], 'target': str(binary)}
        (cls.root/'profiles.json').write_text(json.dumps({'profiles': profiles}))
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()

    def run_app(self, version, ignore=False, command_key="^]", intercept_mode="queued_replay"):
        case = tempfile.TemporaryDirectory(prefix='case-', dir=self.root)
        self.addCleanup(case.cleanup)
        folder = Path(case.name)
        master, slave = pty.openpty()
        self.addCleanup(os.close, master)
        self.addCleanup(os.close, slave)
        original = termios.tcgetattr(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 960, 480))
        env = dict(os.environ, KATZENSTEG_PROFILE_DIR=f'{ROOT / "profiles"}:{self.root}', KATZENSTEG_REPO=str(ROOT),
                   KS_COMMAND_REPORT=str(folder/'events'), SDL_VIDEODRIVER='dummy', SDL_RENDER_DRIVER='software',
                   KATZENSTEG_REAL_WINDOW='hide', KATZENSTEG_OUTPUT_PROFILE='direct_apc', KATZENSTEG_COMMAND_KEY=command_key, KATZENSTEG_INTERCEPT_MODE=intercept_mode)
        env.pop('KATZENSTEG_TARGET', None)
        if ignore: env['KS_IGNORE_QUIT'] = '1'
        # Keep the controlling session alive after launcher exit, including on macOS.
        supervisor_code = 'import subprocess,sys,signal; from pathlib import Path; r=Path(sys.argv[1]); signal.signal(signal.SIGHUP,signal.SIG_IGN); p=subprocess.Popen(sys.argv[2:]); (r/"pid").write_text(str(p.pid)); c=p.wait(); (r/"exit").write_text(str(c)); signal.pause()'
        def ctty():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        supervisor = subprocess.Popen([sys.executable, '-c', supervisor_code, str(folder), str(ROOT/'zig-out/bin/katzensteg'), f'test.command{version}'], env=env, stdin=slave, stdout=slave, stderr=slave, preexec_fn=ctty)
        def cleanup():
            try: os.killpg(supervisor.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            supervisor.wait()
        self.addCleanup(cleanup)
        def events(): return (folder/'events').read_text() if (folder/'events').exists() else ''
        def wait(predicate, timeout=8):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if select.select([master], [], [], .02)[0]:
                    with (folder/'terminal').open('ab') as output: output.write(os.read(master, 65536))
                if predicate(): return
            self.fail(f'timed out; events={events()!r}; exited={(folder/"exit").read_text() if (folder/"exit").exists() else None}')
        wait(lambda: 'ready ' in events())
        return folder, master, slave, original, events, wait

    def test_focus_cancel_literal_and_graceful_quit(self):
        for version in (2, 3):
            with self.subTest(sdl=version):
                folder, master, slave, original, events, wait = self.run_app(version)
                os.write(master, b'\x1b[?31u\x1b[119;1:1u\x1b[<0;2;2M')
                wait(lambda: 'key 26 1' in events())
                os.write(master, b'\x1b[93;5:1u')
                wait(lambda: 'focus 0 keys 0 buttons 0 flags 0' in events())
                os.write(master, b'\x1b[200~q\x1b\x1d\x1b[201~\x1b[27;1:1u')
                wait(lambda: 'focus 1 keys 0 buttons 0 flags 1' in events())
                self.assertNotIn('quit', events())
                os.write(master, b'\x1b[119;1:2u\x1b[119;1:3u\x1b[93;5:3u\x1b[27;1:3u\x1d\x1d')
                wait(lambda: 'key 48 0' in events())
                self.assertEqual(events().count('key 26 1'), 1)
                self.assertEqual(events().count('key 48 1'), 1)
                os.write(master, b'\x1dq')
                wait(lambda: (folder/'exit').exists())
                self.assertEqual((folder/'exit').read_text(), '0')
                self.assertIn('quit', events())
                self.assertEqual(termios.tcgetattr(slave), original)

    def test_menu_updates_without_another_game_frame(self):
        for mode in ('queued_replay', 'sync_compose'):
            with self.subTest(mode=mode):
                folder, master, slave, _, events, wait = self.run_app(2, intercept_mode=mode)
                def output(): return (folder/'terminal').read_bytes()
                os.write(master, b'\x1d')
                wait(lambda: b'q Quit | Esc Return | ^] Literal' in output())
                self.assertIn(b'\x1b[24;1H', output())
                layers = re.findall(rb',z=(-?\d+)', output())
                self.assertTrue(layers, 'expected the initial game image placement')
                self.assertTrue(all(int(z) < -1073741824 for z in layers), layers)
                os.write(master, b'x')
                wait(lambda: b'Unknown key' in output())
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 1200, 600))
                wait(lambda: b'\x1b[30;1H' in output())
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 20, 40, 480, 400))
                wait(lambda: b'\x1b[20;1H' in output())
                # Clicking Return consumes both halves of the click.
                os.write(master, b'\x1b[<0;13;20M\x1b[<0;13;20m')
                wait(lambda: 'focus 1' in events() and b'\x1b[40X' in output())
                os.write(master, b'\x1dq')
                wait(lambda: (folder/'exit').exists())
                self.assertEqual((folder/'exit').read_text(), '0')

    def test_none_passes_attention_and_q_to_the_app(self):
        folder, master, _, _, events, wait = self.run_app(2, command_key='none')
        os.write(master, b'\x1dq')
        wait(lambda: 'key 20 0' in events())
        self.assertIn('key 48 1', events())
        self.assertNotIn('quit', events())
        self.assertFalse((folder/'exit').exists())

    def test_hosted_producer_ignores_environment_command_key(self):
        with tempfile.TemporaryDirectory(dir=self.root) as tmp:
            report = Path(tmp)/'events'
            env = dict(os.environ, KATZENSTEG_PROFILE_DIR=f'{ROOT / "profiles"}:{self.root}', KATZENSTEG_REPO=str(ROOT),
                       KS_COMMAND_REPORT=str(report), SDL_VIDEODRIVER='dummy', SDL_RENDER_DRIVER='software',
                       KATZENSTEG_REAL_WINDOW='hide', KATZENSTEG_COMMAND_KEY='^]')
            proc = subprocess.Popen([str(ROOT/'zig-out/bin/katzensteg'), '--embed-jsonl', 'test.command2'],
                                    env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                def send(value):
                    proc.stdin.write((json.dumps(value)+'\n').encode()); proc.stdin.flush()
                send({'type': 'attach', 'window_id': 'main', 'placeholder': {'image_id': 777, 'cols': 20, 'rows': 10},
                      'upload': {'profile': 'file_whole', 'path': str(Path(tmp)/'pixels'), 'high_water': 4096}})
                send({'type': 'input', 'window_id': 'main', 'event': 'terminal_bytes', 'bytes': '\x1dq'})
                deadline = time.monotonic() + 8
                while not report.exists() or 'key 20 0' not in report.read_text():
                    self.assertLess(time.monotonic(), deadline)
                    self.assertIsNone(proc.poll())
                    if select.select([proc.stdout], [], [], .02)[0]: os.read(proc.stdout.fileno(), 65536)
                self.assertIn('key 48 1', report.read_text())
                self.assertNotIn('quit', report.read_text())
                send({'type': 'shutdown'})
                out, err = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, 0, err.decode())
            finally:
                if proc.poll() is None: proc.kill()
                proc.communicate()

    def test_ignored_quit_and_sigterm_are_bounded_and_restore_tty(self):
        folder, master, slave, original, events, wait = self.run_app(2, ignore=True)
        os.write(master, b'\x1dq')
        wait(lambda: (folder/'exit').exists(), timeout=5)
        self.assertIn('quit', events())
        self.assertEqual((folder/'exit').read_text(), '137')
        self.assertEqual(termios.tcgetattr(slave), original)

if __name__ == '__main__': unittest.main()
