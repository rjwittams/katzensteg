#!/usr/bin/env python3
"""Exercise the normal WM hosting SDL producers in placeholder mode.

Requires `zig build`. Uses an isolated controlling PTY and SDL dummy windows.
Checks host text, producer graphics, overlap, moves, resize and routed input.
It does not replace visual testing in a Kitty-compatible terminal.
"""
import codecs
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time
import unicodedata
import unittest

REPO = Path(__file__).resolve().parents[2]
GLYPH = "\U0010eeee"


class Screen:
    """Small recorder for the cursor/SGR/text sequences emitted by this WM."""
    def __init__(self):
        self.pending = ""
        self.raw = bytearray()
        self.row = self.col = 1
        self.fg = None
        self.cells = {}
        self.placements = {}
        self.frames = {}
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data):
        self.raw.extend(data)
        self.pending += self.decoder.decode(data)
        while self.pending:
            s = self.pending
            if s.startswith("\x1b_G"):
                end = s.find("\x1b\\")
                if end < 0:
                    return
                header = s[3:end].split(";", 1)[0]
                fields = dict(field.split("=", 1) for field in header.split(",") if "=" in field)
                if fields.get("a") == "p":
                    assert fields.get("U") == "1", fields
                    assert not any(k in fields for k in ("x", "y", "z", "C")), fields
                    self.placements[int(fields["i"])] = (int(fields["c"]), int(fields["r"]))
                if fields.get("a") == "t":
                    image = int(fields["i"])
                    self.frames[image] = self.frames.get(image, 0) + 1
                self.pending = s[end + 2:]
                continue
            if s.startswith("\x1b["):
                match = re.match(r"\x1b\[([0-?]*)([ -/]*)([@-~])", s)
                if not match:
                    return
                params, _, command = match.groups()
                if command in ("H", "f"):
                    self.row, self.col = map(int, params.split(";")) if params else (1, 1)
                elif command == "J" and params == "2":
                    self.cells.clear()
                elif command == "m":
                    codes = [int(x or 0) for x in params.split(";")]
                    i = 0
                    while i < len(codes):
                        if codes[i] in (0, 39):
                            self.fg = None
                        if codes[i:i + 2] == [38, 2]:
                            r, g, b = codes[i + 2:i + 5]
                            self.fg = (r << 16) | (g << 8) | b
                            i += 4
                        i += 1
                self.pending = s[match.end():]
                continue
            if s[0] == "\x1b":
                if len(s) < 3:
                    return
                raise AssertionError(repr(s[:80]))
            char = s[0]
            self.pending = s[1:]
            if char == "\r":
                self.col = 1
            elif char == "\n":
                self.row += 1
            elif unicodedata.category(char).startswith("M"):
                pass
            elif ord(char) >= 32:
                self.cells[self.row, self.col] = (char, self.fg)
                self.col += 1


class PlaceholderHostTest(unittest.TestCase):
    def test_normal_wm_hosts_two_producers(self):
        with tempfile.TemporaryDirectory(prefix="wm-placeholder-") as directory:
            folder = Path(directory)
            # A private executable pair lets the test remove the launcher to
            # exercise a failed interactive launch without touching the build.
            wm = folder / "katzensteg-wm"
            shutil.copy2(REPO / "zig-out/bin/katzensteg-wm", wm)
            launcher = folder / "katzensteg"
            launcher.symlink_to(REPO / "zig-out/bin/katzensteg")
            profiles = {name: {"extends": ["probe.input"], "stdout": str(folder / (name + ".log")), "stderr": "stdout"} for name in ("first", "second")}
            (folder / "profiles.json").write_text(json.dumps({"profiles": profiles}))
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 1000, 800))
            env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_RENDER_DRIVER="software", KATZENSTEG_REAL_WINDOW="hide", KATZENSTEG_OUTPUT_PROFILE="file_whole", KATZENSTEG_PROFILE_DIR=str(REPO / "profiles") + ":" + directory)
            env.pop("KATZENSTEG_TARGET", None)

            def controlling_terminal():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            proc = subprocess.Popen([str(wm), "--presentation", "placeholder", "first", "second"], env=env, stdin=slave, stdout=slave, stderr=slave, preexec_fn=controlling_terminal)
            screen = Screen()

            def pump_until(predicate, timeout=15):
                deadline = time.monotonic() + timeout
                while not predicate():
                    self.assertLess(time.monotonic(), deadline, (proc.poll(), screen.frames, screen.placements, {p.name: p.read_text()[-3000:] for p in folder.glob("*.log")}))
                    ready, _, _ = select.select([master], [], [], 0.05)
                    if ready:
                        try:
                            data = os.read(master, 65536)
                        except OSError as err:
                            if err.errno != errno.EIO:
                                raise
                            data = b""
                        screen.feed(data)
                    if proc.poll() is not None and not predicate():
                        self.fail((proc.returncode, screen.frames))

            try:
                pump_until(lambda: all(screen.frames.get(i, 0) >= 3 for i in (100000, 300000)) and screen.cells.get((20, 50)) == (GLYPH, 300000))
                # The higher window's border is text, not the lower image.
                self.assertEqual(screen.cells[2, 3][0], "┌")
                os.write(master, b"\t")  # Focus second (already on top).
                pump_until(lambda: any(c == "*" for (r, _), (c, _) in screen.cells.items() if r == 3))
                os.write(master, b"\t")  # Raise first over second.
                pump_until(lambda: screen.cells.get((20, 50)) == (GLYPH, 100000))
                before_size = screen.placements[100000]
                os.write(master, b"l")
                pump_until(lambda: screen.cells.get((1, 2), (None,))[0] == "┌" and screen.cells.get((1, 1), (None,))[0] == " ")
                self.assertEqual(screen.placements[100000], before_size, "moving must not resize the virtual placement")
                os.write(master, b"H")
                pump_until(lambda: screen.placements[100000] != before_size)
                # Translate a click on the first displayed source cell to (0,0).
                cells = sorted(pos for pos, value in screen.cells.items() if value == (GLYPH, 100000))
                row, col = cells[0]
                log = folder / "first.log"
                os.write(master, f"\x1b[<0;{col};{row}M".encode())
                pump_until(lambda: "mouse_button_down" in log.read_text())
                os.write(master, f"\x1b[<0;{col};{row}m".encode())
                pump_until(lambda: "mouse_button_up" in log.read_text())
                os.write(master, b"a")
                pump_until(lambda: log.exists() and "key_down key=A" in log.read_text())
                self.assertIn("x=0 y=0", log.read_text())
                second_log = (folder / "second.log").read_text()
                self.assertNotIn("key_down key=A", second_log)
                launcher.unlink()
                os.write(master, b"n")
                # The 100-column status line may truncate the prompt text.
                time.sleep(0.05)
                os.write(master, b"unavailable\r")
                wm_log = Path(f"/tmp/katzensteg-{proc.pid}.log")
                pump_until(lambda: "launch failed: unavailable: FileNotFound" in wm_log.read_text())
                previous_frames = screen.frames[100000]
                pump_until(lambda: screen.frames[100000] > previous_frames)
                os.write(master, b"q")
                pump_until(lambda: proc.poll() is not None)
                # On macOS the controlling slave can become ENOTTY on leader
                # exit. Verify the WM's normal screen restoration on the wire.
                while select.select([master], [], [], 0.05)[0]:
                    try:
                        data = os.read(master, 65536)
                    except OSError as err:
                        if err.errno == errno.EIO:
                            break
                        raise
                    if not data:
                        break
                    screen.feed(data)
                self.assertIn(b"\x1b[?1049l", screen.raw)
            finally:
                if proc.poll() is None:
                    os.write(master, b"\x1b")
                    time.sleep(0.05)
                    os.write(master, b"q")
                    deadline = time.monotonic() + 8
                    while proc.poll() is None and time.monotonic() < deadline:
                        if select.select([master], [], [], 0.05)[0]:
                            os.read(master, 65536)
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
                os.close(master)
                os.close(slave)


if __name__ == "__main__":
    unittest.main()
