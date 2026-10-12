#!/usr/bin/env python3
"""Standalone output drains must finish with the target on every platform."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / "zig-out" / "bin" / ("katzensteg.exe" if os.name == "nt" else "katzensteg")

APP = """
from pathlib import Path
import subprocess
import sys
import time

root = Path(sys.argv[2])
if sys.argv[1] == "descendant":
    (root / "ready").touch()
    time.sleep(3)
    (root / "done").touch()
else:
    if sys.argv[1] == "parent":
        subprocess.Popen([sys.executable, __file__, "descendant", str(root)])
        deadline = time.monotonic() + 5
        while not (root / "ready").exists():
            if time.monotonic() > deadline:
                raise RuntimeError("descendant did not start")
            time.sleep(.01)
    # More than one drain buffer on each pipe; neither tail may be lost.
    print("o" * 20000, flush=True)
    print("e" * 20000, file=sys.stderr, flush=True)
    (root / "parent-done").write_text(str(time.monotonic()))
"""


class LauncherOutputTests(unittest.TestCase):
    def test_target_exit_does_not_wait_for_inherited_descendant_pipes(self):
        self.assert_launch_output("parent")

    def test_target_exit_drains_buffered_output_to_eof(self):
        self.assert_launch_output("normal")

    def assert_launch_output(self, mode):
        with tempfile.TemporaryDirectory(prefix="ks-output-") as directory:
            root = Path(directory)
            app = root / "app.py"
            app.write_text(APP)
            stdout = root / "stdout.log"
            stderr = root / "stderr.log"
            (root / "profiles.json").write_text(json.dumps({"profiles": {
                "orphan-output": {
                    "target": sys.executable,
                    "args": [str(app), mode, str(root)],
                    "stdout": str(stdout),
                    "stderr": str(stderr),
                }
            }}))
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("KATZENSTEG_")}
            env["KATZENSTEG_PROFILE_DIR"] = str(root)
            try:
                result = subprocess.run([str(LAUNCHER), "orphan-output"],
                                        env=env, capture_output=True, text=True, timeout=10)
                returned = time.monotonic()
                self.assertEqual(result.returncode, 0, result.stderr)
                parent_done = float((root / "parent-done").read_text())
                self.assertLess(returned - parent_done, 1.5,
                                "launcher waited for a descendant retaining output pipes")
                self.assertEqual(stdout.read_text(), "o" * 20000 + "\n")
                self.assertEqual(stderr.read_text(), "e" * 20000 + "\n")
            finally:
                # The bounded descendant exits naturally; let it finish before
                # removing its directory, including when the assertion fails.
                deadline = time.monotonic() + 6
                while (root / "ready").exists() and not (root / "done").exists():
                    if time.monotonic() > deadline:
                        raise RuntimeError("descendant did not finish")
                    time.sleep(.01)


    @unittest.skipIf(os.name == "nt", "POSIX controlling-terminal boundary")
    def test_program_status_startup_failure_and_hosted_silence(self):
        # Real launcher failures leave an error on its controlling terminal;
        # hosted failures emit no status even when a controlling terminal exists.
        import base64
        import fcntl
        import pty
        import re
        import select
        import termios
        with tempfile.TemporaryDirectory(prefix="ks-status-") as directory:
            root = Path(directory)
            (root / "profiles.json").write_text(json.dumps({"profiles": {
                "missing": {"target": str(root / "absent")},
                "fragment": {},
                "nonzero": {"target": sys.executable, "args": ["-c", "raise SystemExit(7)"]},
            }}))
            env = {k: v for k, v in os.environ.items() if not k.startswith("KATZENSTEG_")}
            env["KATZENSTEG_PROFILE_DIR"] = str(root)
            for profile in ("missing", "fragment", "nonzero"):
                for hosted in (False, True):
                    with self.subTest(profile=profile, hosted=hosted):
                        master, slave = pty.openpty()
                        def ctty():
                            os.setsid()
                            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
                        try:
                            args = [str(LAUNCHER)] + (["--embed-jsonl"] if hosted else []) + [profile]
                            child = subprocess.Popen(args, env=env, stdin=slave, stdout=slave, stderr=slave, preexec_fn=ctty)
                            output = bytearray()
                            deadline = time.monotonic() + 10
                            while child.poll() is None or select.select([master], [], [], 0)[0]:
                                if time.monotonic() > deadline:
                                    child.kill()
                                    child.wait()
                                    self.fail("launcher did not exit")
                                if select.select([master], [], [], .02)[0]:
                                    output.extend(os.read(master, 65536))
                            self.assertNotEqual(child.wait(), 0)
                            reports = [dict(pair.split(b'=', 1) for pair in body.split(b':'))
                                       for body in re.findall(rb'\x1b\]7501;([^\x1b]*)\x1b\\', output)]
                            if hosted:
                                self.assertEqual(reports, [])
                            else:
                                self.assertEqual([r[b'state'] for r in reports], [b'working', b'error'])
                                self.assertEqual(base64.b64decode(reports[-1][b'title']), profile.encode())
                                self.assertTrue(base64.b64decode(reports[-1][b'msg']))
                                self.assertNotIn(b'\x1bc', output)
                        finally:
                            os.close(master)
                            os.close(slave)


if __name__ == "__main__":
    unittest.main()
