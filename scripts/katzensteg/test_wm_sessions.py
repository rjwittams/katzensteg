#!/usr/bin/env python3
"""Byte/state scenarios for session windows against a private cleat daemon."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import socket
import struct
import sys
import subprocess
import tempfile
import termios
import time
import unittest

from test_wm_placeholder_host import Screen

BINARY = None
WM = None
REAL_PRODUCER = False

# Fixed positioned-window geometry used by the PTY and content assertions.
FIXTURE_ROWS = 40
FIXTURE_COLS = 100
CONTENT_COLUMNS = slice(1, FIXTURE_COLS - 5)


class SessionWindows(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wm-session-")
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_RENDER_DRIVER="software", KATZENSTEG_REAL_WINDOW="hide", KATZENSTEG_PROFILE_DIR=str(Path(__file__).resolve().parents[2] / "profiles"), CLEAT_RUNTIME_DIR=str(self.root), KATZENSTEG_CLEAT_BINARY=BINARY, KATZENSTEG_OUTPUT_PROFILE="file_whole")
        for name in ("CLEAT_DAEMON", "CLEAT_SESSION", "CLEAT_OUTPUT_DAEMON", "KATZENSTEG_WM_ATTACH"):
            self.env.pop(name, None)
        self.daemon_log = open(self.root / "daemon.log", "w+")
        self.daemon = subprocess.Popen([BINARY, "--runtime-root", str(self.root), "--server", "default", "serve"], stdout=self.daemon_log, stderr=self.daemon_log, env=self.env)
        self.wms = []
        self.peers = []
        deadline = time.monotonic() + 5
        while not any(p.is_socket() for p in self.root.rglob("*")):
            self.assertIsNone(self.daemon.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        # A real PTY program exits through a private sentinel, independently of
        # WM input (which belongs to a later ticket).
        self.cleat("launch", "wm-test", "--size", "100x40", "--cmd", f"stty -echo; printf SESSION_TEXT; while test ! -e {self.root}/end; do sleep .02; done")

    def tearDown(self):
        for peer in self.peers:
            peer.close()
        for proc, master, slave, _ in self.wms:
            if proc.poll() is None:
                os.write(master, b"\x1dQ")
                deadline = time.monotonic() + 3
                while proc.poll() is None and time.monotonic() < deadline:
                    if select.select([master], [], [], 0.02)[0]:
                        try:
                            os.read(master, 65536)
                        except OSError as err:
                            if err.errno != errno.EIO:
                                raise
                if proc.poll() is None:
                    proc.kill()
            proc.wait(timeout=5)
            os.close(master)
            os.close(slave)
        self.daemon.terminate()
        self.daemon.wait(timeout=5)
        self.daemon_log.close()
        self.temp.cleanup()

    def cleat(self, *args):
        result = subprocess.run([BINARY, "--server", "default", *args], env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def start(self, extra_env=None, profiles=(), presentation="positioned", requests=("--attach", "wm-test")):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", FIXTURE_ROWS, FIXTURE_COLS, 1000, 800))
        env = dict(self.env, **(extra_env or {}))
        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        proc = subprocess.Popen([WM, "--listen", str(self.root / f"wm-{len(self.wms)}.sock"), "--presentation", presentation, *profiles, *requests], stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=controlling_terminal)
        wm = (proc, master, slave, Screen())
        self.wms.append(wm)
        return wm

    def pump(self, wm):
        proc, master, _, screen = wm
        if select.select([master], [], [], 0.02)[0]:
            try:
                data = os.read(master, 65536)
            except OSError as err:
                if err.errno != errno.EIO:
                    raise
                data = b""
            screen.feed(data)
            # Known outer default background enables the production image band.
            queries = screen.raw.count(b"\x1b]11;?")
            answered = getattr(screen, "background_queries", 0)
            if queries > answered:
                os.write(master, b"\x1b]11;rgb:1212/3434/5656\x1b\\" * (queries - answered))
                screen.background_queries = queries
            queries = screen.raw.count(b"\x1b]10;?")
            answered = getattr(screen, "foreground_queries", 0)
            if queries > answered:
                os.write(master, b"\x1b]10;rgb:abab/cdcd/efef\x1b\\" * (queries - answered))
                screen.foreground_queries = queries
        return proc, screen

    def until(self, wm, predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while not predicate(wm[3]):
            proc, screen = self.pump(wm)
            self.assertLess(time.monotonic(), deadline, (proc.poll(), bytes(screen.raw[-4000:])))
            # A process may exit with restoration bytes still buffered in the PTY.

    @staticmethod
    def text(screen, row):
        return "".join(screen.cells.get((row, col), (" ",))[0] for col in range(1, 101))

    @staticmethod
    def content_text(screen, row):
        # The 100x40 fixture starts with content at columns 2..95. Chrome at
        # columns 1 and 96 must not participate in program-output assertions.
        return SessionWindows.text(screen, row)[CONTENT_COLUMNS]

    def title_visible(self, screen):
        return "wm-test" in self.text(screen, 2)

    def test_scrollback_wheel_keys_title_and_typing(self):
        # #120: real PTY history reaches the painted WM cells; the title follows
        # viewport state, and input restores the bottom before reaching the PTY.
        command = (f"stty -echo; printf HISTORY_WAIT; while test ! -e {self.root}/history-go; do sleep .02; done; "
                   "i=1; while [ $i -le 100 ]; do printf 'HISTORY_%03d\\n' $i; i=$((i+1)); done; "
                   "printf 'HISTORY_READY\\n'; read line; printf 'TYPED_%s\\n' \"$line\"; sleep 30")
        wm = self.start(requests=("--term", command))
        self.until(wm, lambda s: "HISTORY_WAIT" in self.content_text(s, 4))
        (self.root / "history-go").touch()
        visible = lambda s, marker: any(marker in self.content_text(s, row) for row in range(4, 39))
        self.until(wm, lambda s: visible(s, "HISTORY_READY"))
        bottom_first = self.content_text(wm[3], 4).strip()
        self.assertTrue(bottom_first.startswith("HISTORY_"), bottom_first)
        first_number = int(bottom_first.removeprefix("HISTORY_"))
        os.write(wm[1], b"\x1b[<64;2;4M")
        self.until(wm, lambda s: f"HISTORY_{first_number - 3:03d}" in self.content_text(s, 4) and "[scrollback]" in self.text(s, 2))
        os.write(wm[1], b"\x1b[6;2~")
        self.until(wm, lambda s: visible(s, "HISTORY_READY") and "[scrollback]" not in self.text(s, 2))
        os.write(wm[1], b"\x1b[5;2~")
        self.until(wm, lambda s: "[scrollback]" in self.text(s, 2) and self.content_text(s, 4).strip() != bottom_first)
        self.assertFalse(visible(wm[3], "HISTORY_READY"))
        os.write(wm[1], b"x")
        self.until(wm, lambda s: visible(s, "HISTORY_READY") and "[scrollback]" not in self.text(s, 2))
        os.write(wm[1], b"\x1b[<64;2;4M" + b"y\r")
        self.until(wm, lambda s: visible(s, "TYPED_xy") and "[scrollback]" not in self.text(s, 2))

    def test_tracking_program_receives_modified_wheel(self):
        # No modifier bypasses mouse tracking: the program receives a real
        # SGR wheel report, which it prints back as hex into the WM content.
        command = ("python3 -c 'import os,tty; tty.setraw(0); "
                   "os.write(1,b\"\\x1b[?1000h\\x1b[?1006hMOUSE_READY\"); "
                   "data=os.read(0,64); os.write(1,b\"MOUSE_BYTES_\"+data.hex().encode()); "
                   "import time; time.sleep(30)'")
        wm = self.start(requests=("--term", command))
        self.until(wm, lambda s: "MOUSE_READY" in self.content_text(s, 4))
        os.write(wm[1], b"\x1b[<72;2;4M")
        self.until(wm, lambda s: "MOUSE_BYTES_1b5b3c37323b313b314d" in self.content_text(s, 4))
        self.assertNotIn("[scrollback]", self.text(wm[3], 2))

    def test_text_close_detaches_program_exit_closes_and_quit_detaches(self):
        wm = self.start()
        # Attach paints the session's text inside the shared window content
        # rectangle, not in chrome or the desktop status row.
        self.until(wm, lambda s: "SESSION_TEXT" in self.text(s, 4))
        self.assertEqual(self.text(wm[3], 4)[1:13], "SESSION_TEXT")
        self.assertTrue(self.title_visible(wm[3]))
        # Closing detaches; the daemon still lists the running program.
        os.write(wm[1], b"\x1dq")
        self.until(wm, lambda s: not self.title_visible(s))
        self.assertIn("wm-test", self.cleat("list"))
        again = self.start()
        self.until(again, lambda s: "SESSION_TEXT" in self.text(s, 4))
        # Program exit removes the window without a lifecycle poll of cleat.
        (self.root / "end").touch()
        self.until(again, lambda s: not self.title_visible(s))
        self.cleat("launch", "wm-test", "--cmd", "sleep 30")
        third = self.start()
        self.until(third, self.title_visible)
        os.write(third[1], b"\x1dQ")
        self.until(third, lambda s: b"\x1b[?1049l" in s.raw)
        self.assertIn("wm-test", self.cleat("list"))

    def launch_prompt(self, wm, text):
        os.write(wm[1], b"\x1dn" + text.encode() + b"\r")

    def test_launch_command_and_attach_by_allocated_id(self):
        # #119: starting through CLI allocates an id, paints real PTY output,
        # and leaves a durable session that another WM attaches to by that id.
        wm = self.start(requests=("--term", "printf STARTED_FROM_WM; sleep 30"))
        self.until(wm, lambda s: "STARTED_FROM_WM" in self.text(s, 4))
        session_id = self.text(wm[3], 2).split("katzensteg wm ", 1)[1].split("│")[0].strip()
        self.assertTrue(session_id)
        self.assertNotEqual(session_id, "wm-test")
        again = self.start(requests=("--attach", session_id))
        self.until(again, lambda s: "STARTED_FROM_WM" in self.text(s, 4))
        self.assertIn(session_id, self.text(again[3], 2))

    def test_prompt_forms_start_shell_command_and_attach(self):
        # Generate every prompt spelling against a real daemon. Shell forms
        # must create a controller attachment and expose the allocated id.
        for form in ("term", "!", "term printf PROMPT_COMMAND; sleep 30", "!printf PROMPT_COMMAND; sleep 30", "attach wm-test", "@wm-test"):
            with self.subTest(form=form):
                wm = self.start({}, requests=())
                self.until(wm, lambda s: "wm windows=0" in self.text(s, 40))
                self.launch_prompt(wm, form)
                expected = "SESSION_TEXT" if form.startswith(("attach", "@")) else "PROMPT_COMMAND" if "printf" in form else None
                if expected is not None:
                    self.until(wm, lambda s: expected in self.text(s, 4))
                else:
                    self.until(wm, lambda s: "katzensteg wm " in self.text(s, 2))
                    session_id = self.text(wm[3], 2).split("katzensteg wm ", 1)[1].split("│")[0].strip()
                    state = json.loads(self.cleat("inspect", session_id, "--json"))
                    self.assertEqual(state["attachments"][0]["role"], "controller")
                    self.assertEqual(state["terminal"], {"cols": 94, "rows": 34})
                self.assertNotIn("launch failed", self.text(wm[3], 40))
                os.write(wm[1], b"\x1dQ")
                self.until(wm, lambda s: b"\x1b[?1049l" in s.raw)

    def test_unknown_id_reports_failure_without_window_and_can_retry(self):
        # #119: a failed request consumes no window slot. A subsequent attach
        # paints at the first window's position and clears the failure row.
        for requests in (("--attach", "missing-session"), ()):
            with self.subTest(requests=requests):
                wm = self.start(requests=requests)
                if not requests:
                    self.until(wm, lambda s: "wm windows=0" in self.text(s, 40))
                    self.launch_prompt(wm, "@missing-session")
                self.until(wm, lambda s: "launch failed" in self.text(s, 40))
                self.assertNotIn("missing-session", self.text(wm[3], 2))
                self.assertNotIn("katzensteg wm", self.text(wm[3], 1))
                self.launch_prompt(wm, "attach wm-test")
                self.until(wm, lambda s: "SESSION_TEXT" in self.text(s, 4))
                self.assertTrue(self.title_visible(wm[3]))
                self.assertNotIn("launch failed", self.text(wm[3], 40))

    def test_unknown_prompt_id_keeps_existing_producer_and_reports_failure(self):
        # An asynchronous refusal must remain the status event after focus and
        # viewport reconciliation, while the established producer stays visible.
        wm = self.start(requests=())
        self.until(wm, lambda s: "wm windows=0" in self.text(s, 40))
        self.producer(wm)
        self.until(wm, lambda s: "producer" in self.text(s, 2))
        self.launch_prompt(wm, "@missing-session")
        self.until(wm, lambda s: "launch failed" in self.text(s, 40))
        self.assertIn("producer", self.text(wm[3], 2))
        self.assertNotIn("missing-session", self.text(wm[3], 3))
    def test_session_keys_paste_and_interrupt_reach_program(self):
        # Issue #118: type a command through the WM and observe its result in
        # the mirror. Ctrl-C must interrupt a running command in that session.
        self.cleat("launch", "wm-input", "--cmd", "exec /bin/sh")
        wm = self.start(requests=("--attach", "wm-input"))
        self.until(wm, lambda s: "wm-input" in self.text(s, 2))
        os.write(wm[1], b"printf 'INPUT_%s\\n' OK\r")
        self.until(wm, lambda s: any("INPUT_OK" in self.text(s, row) for row in range(4, 38)))
        # Paste reaches the program through the same WM route.
        os.write(wm[1], b"\x1b[200~printf 'PASTE_%s\\n' OK\x1b[201~\r")
        self.until(wm, lambda s: any("PASTE_OK" in self.text(s, row) for row in range(4, 38)))
        # Assemble the interrupt marker only in the trap, so command echo
        # cannot satisfy it. The PTY may echo ^C before the marker.
        os.write(wm[1], b"trap 'printf \"INT%s\\n\" ERRUPTED' INT; printf 'RUN_%s\\n' READY; sleep 30\r")
        self.until(wm, lambda s: any(self.content_text(s, row).strip() == "RUN_READY" for row in range(4, 38)))
        os.write(wm[1], b"\x03")
        self.until(wm, lambda s: any("INTERRUPTED" in self.content_text(s, row) for row in range(4, 38)))

    def test_held_key_is_released_when_menu_arms(self):
        # A real raw-mode program enables kitty events and focus reporting.
        # Arming the WM menu must emit focus lost and the held key's release;
        # cancelling returns focus, while the outer release stays consumed.
        program = self.root / "input.py"
        received = self.root / "input.received"
        program.write_text("""import os, pathlib, select, sys, tty
tty.setraw(0)
os.write(1, b'\\x1b[>3u\\x1b[?1004hKEYS_READY')
root = pathlib.Path(sys.argv[1])
with (root / 'input.received').open('ab', buffering=0) as output:
    while not (root / 'end').exists():
        if select.select([0], [], [], .02)[0]:
            output.write(os.read(0, 4096))
""")
        self.cleat("launch", "wm-keys", "--cmd", f"{sys.executable} {program} {self.root}")
        wm = self.start(requests=("--attach", "wm-keys"))
        self.until(wm, lambda s: "KEYS_READY" in self.text(s, 4))
        os.write(wm[1], b"\x1b[?3u\x1b[119;5:1u\x1d")
        deadline = time.monotonic() + 5
        while not received.exists() or b"\x1b[119;5:3u" not in received.read_bytes():
            self.pump(wm)
            self.assertLess(time.monotonic(), deadline, received.read_bytes() if received.exists() else None)
        data = received.read_bytes()
        self.assertIn(b"\x1b[119;5u", data)
        self.assertIn(b"\x1b[O", data)
        self.assertLess(data.index(b"\x1b[O"), data.index(b"\x1b[119;5:3u"))
        os.write(wm[1], b"\x1b[27u\x1b[119;5:3u")
        deadline = time.monotonic() + 5
        while not received.read_bytes().endswith(b"\x1b[I"):
            self.pump(wm)
            self.assertLess(time.monotonic(), deadline, received.read_bytes())
        self.assertEqual(received.read_bytes().count(b"\x1b[119;5:3u"), 1)

    def test_real_sdl_producer_and_session_in_both_orders(self):
        if not REAL_PRODUCER:
            self.skipTest("full-build SDL producer scenario is enabled by CI")
        from test_wm_placeholder_host import GLYPH
        # A real producer emits kitty image uploads. The byte recorder also
        # tracks its virtual-placement cells, so covering is tested on output.
        wm = self.start(profiles=("probe.input",), presentation="placeholder")
        def session_content(screen):
            return [screen.cells.get((r, c), (" ",))[0] for r in range(5, 39) for c in range(4, 98)]
        self.until(wm, lambda s: s.frames.get(100000, 0) > 0 and "SESSION_TEXT" in self.text(s, 5) and GLYPH not in session_content(s))
        self.assertNotIn(GLYPH, session_content(wm[3]))
        os.write(wm[1], b"\x1d\t")  # Focus the already higher session.
        self.until(wm, lambda s: "*katzensteg wm wm-test" in self.text(s, 3))
        os.write(wm[1], b"\x1d\t")  # Raise the producer above the session.
        self.until(wm, lambda s: "SESSION_TEXT" not in self.text(s, 5) and GLYPH in session_content(s))
        before = wm[3].frames.get(100000, 0)
        self.until(wm, lambda s: s.frames.get(100000, 0) > before)
        self.assertNotIn("SESSION_TEXT", self.text(wm[3], 5))
        os.write(wm[1], b"\x1d\t")
        self.until(wm, lambda s: "SESSION_TEXT" in self.text(s, 5) and GLYPH not in session_content(s))
        before = wm[3].frames.get(100000, 0)
        self.until(wm, lambda s: s.frames.get(100000, 0) > before)
        self.assertNotIn(GLYPH, session_content(wm[3]))
        os.write(wm[1], b"\x1dQ")
        self.until(wm, lambda s: b"\x1b[?1049l" in s.raw)

    def test_prompt_profile_still_launches_producer(self):
        if not REAL_PRODUCER:
            self.skipTest("full-build SDL producer scenario is enabled by CI")
        # #119: an ordinary profile name in the widened prompt still starts
        # the producer, observable as real kitty image frames.
        wm = self.start(requests=(), presentation="placeholder")
        self.until(wm, lambda s: "wm windows=0" in self.text(s, 40))
        self.launch_prompt(wm, "probe.input")
        self.until(wm, lambda s: s.frames.get(100000, 0) > 0 and any("probe.input" in self.text(s, row) for row in range(1, 40)))
        self.assertTrue(any("probe.input" in self.text(wm[3], row) for row in range(1, 40)))

    def test_resize_geometry_and_controller_role(self):
        wm = self.start()
        self.until(wm, lambda s: "SESSION_TEXT" in self.text(s, 4))
        state = json.loads(self.cleat("inspect", "wm-test", "--json"))
        self.assertEqual(state["terminal"], {"cols": 94, "rows": 34})
        self.assertTrue(state["attachments"])
        other = self.start()
        self.until(other, lambda s: "SESSION_TEXT" in self.text(s, 4))
        state = json.loads(self.cleat("inspect", "wm-test", "--json"))
        self.assertEqual([a["role"] for a in state["attachments"]], ["controller", "controller"])
        # Change the outer pixel size and cell grid. Settled content dimensions
        # and outer cell pixels reach the session, without an aspect lock.
        fcntl.ioctl(wm[2], termios.TIOCSWINSZ, struct.pack("HHHH", 30, 80, 960, 720))
        deadline = time.monotonic() + 5
        while True:
            self.pump(wm)
            state = json.loads(self.cleat("inspect", "wm-test", "--json"))
            if state["terminal"] == {"cols": 78, "rows": 25}:
                break
            self.assertLess(time.monotonic(), deadline, state)
        self.until(wm, lambda s: "SESSION_TEXT" in self.text(s, 4))

    def test_program_receives_outer_cell_pixels_on_attach_and_resize(self):
        # A real program asks its VT for cell pixels. Its response proves the
        # report reached the daemon's terminal, rather than local render metadata.
        program = self.root / "geometry.py"
        response = self.root / "geometry.response"
        program.write_text("""import os, pathlib, select, sys, time, tty
root = pathlib.Path(sys.argv[1])
tty.setraw(0)
os.write(1, b'PIXELS_READY')
while not (root / 'end').exists():
    os.write(1, b'\\x1b[16t')
    data = b''
    deadline = time.monotonic() + 1
    while not data.endswith(b't') and time.monotonic() < deadline:
        if select.select([0], [], [], .02)[0]:
            data += os.read(0, 100)
    if data:
        (root / 'geometry.response').write_bytes(data)
    time.sleep(.02)
""")
        self.cleat("launch", "wm-pixels", "--size", "100x40", "--cmd", f"{sys.executable} {program} {self.root}")
        wm = self.start(requests=("--attach", "wm-pixels"))
        self.until(wm, lambda s: "PIXELS_READY" in self.text(s, 4))
        def await_response(expected):
            deadline = time.monotonic() + 5
            while not response.exists() or response.read_bytes() != expected:
                self.pump(wm)
                self.assertLess(time.monotonic(), deadline, response.read_bytes() if response.exists() else None)
        await_response(b"\x1b[6;20;10t")
        fcntl.ioctl(wm[2], termios.TIOCSWINSZ, struct.pack("HHHH", 30, 80, 960, 720))
        await_response(b"\x1b[6;24;12t")

    def test_version_mismatch_refuses_session_and_producer_still_opens(self):
        # Executable boundary fake reports a different protocol before any
        # provider is opened. Both versions must be visible in the status row.
        fake = self.root / "version-fixture"
        fake.write_text("#!/usr/bin/env python3\nprint('cleat 0.1.0 (protocol 999, vt ghostty)')\n")
        fake.chmod(0o755)
        wm = self.start({"KATZENSTEG_CLEAT_BINARY": str(fake)})
        self.until(wm, lambda s: "mismatch" in self.text(s, 40))
        # ABI/protocol are pinned by profiles/cleat-dependency.json; update
        # these expectations together with that pin when upgrading cleat.
        self.assertIn("library 10/11", self.text(wm[3], 40))
        self.assertIn("installed 10/999", self.text(wm[3], 40))
        self.assertFalse(self.title_visible(wm[3]))
        self.producer(wm)
        self.until(wm, lambda s: "producer" in self.text(s, 2))

    def producer(self, wm):
        # Socket boundary fake: speaks the real external producer protocol.
        peer = socket.socket(socket.AF_UNIX)
        peer.settimeout(5)
        peer.connect(str(self.root / f"wm-{self.wms.index(wm)}.sock"))
        self.peers.append(peer)
        peer.sendall(b'{"type":"register","version":1,"title":"producer"}\n')
        pending = b""
        while b'"type":"attach"' not in pending:
            pending += peer.recv(65536)
        peer.sendall(b'{"type":"presentation_status","window_id":"main","ready_to_show":true,"input_supported":true}\n')
        return peer

    def test_mixed_windows_cover_in_both_orders_and_modes(self):
        # Generate both image-cover policies and both window orders. A higher
        # producer clears session text under its content; raising the session
        # restores its cells and clips the producer to the shared outer rect.
        for force_split in ("0", "1"):
            with self.subTest(force_split=force_split):
                wm = self.start({"KATZENSTEG_WM_SPLIT_IMAGES": force_split})
                self.until(wm, lambda s: "SESSION_TEXT" in self.text(s, 4))
                self.producer(wm)
                self.until(wm, lambda s: "producer" in self.text(s, 3) and "SESSION_TEXT" not in self.text(s, 4))
                self.assertNotIn("SESSION_TEXT", self.text(wm[3], 4))
                # Tab raises the session from the same focus/order list.
                os.write(wm[1], b"\x1d\t")
                self.until(wm, lambda s: "SESSION_TEXT" in self.text(s, 4) and "producer" not in self.text(s, 3))
                self.assertNotIn("producer", self.text(wm[3], 3))
                os.write(wm[1], b"\x1d\t")
                self.until(wm, lambda s: "producer" in self.text(s, 3) and "SESSION_TEXT" not in self.text(s, 4))
                self.assertNotIn("SESSION_TEXT", self.text(wm[3], 4))
                os.write(wm[1], b"\x1dQ")
                self.until(wm, lambda s: b"\x1b[?1049l" in s.raw)


class ScreenContentAssertions(unittest.TestCase):
    def test_program_markers_exclude_chrome_and_cannot_match_command_echo(self):
        # Session content assertions ignore window borders. A complete marker
        # exists only in trap output, which may follow the terminal's ^C echo.
        screen = Screen()
        rows = ("RUN_READY", 'trap \'printf "INT%s\\n" ERRUPTED\' INT', "^CINTERRUPTED")
        for row, text in enumerate(rows, 4):
            screen.feed((f"\x1b[{row};1H│" + text.ljust(94) + "│").encode())
        self.assertEqual(SessionWindows.content_text(screen, 4).strip(), "RUN_READY")
        self.assertNotIn("INTERRUPTED", SessionWindows.content_text(screen, 5))
        self.assertIn("INTERRUPTED", SessionWindows.content_text(screen, 6))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--wm", required=True)
    parser.add_argument("--real-producer", action="store_true")
    args, remaining = parser.parse_known_args()
    BINARY = str(Path(args.binary).resolve())
    WM = str(Path(args.wm).resolve())
    REAL_PRODUCER = args.real_producer
    unittest.main(argv=[__file__, *remaining])
