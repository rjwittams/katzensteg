#!/usr/bin/env python3
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class AttachExecSmoke(unittest.TestCase):
    def test_attach_exec_can_host_embed_jsonl_peer(self):
        if not sys.stdin.isatty():
            self.skipTest("attach exec smoke needs a controlling terminal")

        launcher = REPO / "zig-out" / "bin" / "katzensteg"
        demo = REPO / "zig-out" / "bin" / "basic-sdl-demo"
        self.assertTrue(launcher.exists(), f"missing launcher: {launcher}")
        self.assertTrue(demo.exists(), f"missing demo: {demo}")

        env = os.environ.copy()
        env.setdefault("KATZENSTEG_REPO", str(REPO))
        proc = subprocess.Popen(
            [
                str(launcher),
                "attach",
                "--exec",
                "--",
                str(launcher),
                "--embed-jsonl",
                "probe.embed.basic_sdl",
            ],
            cwd=REPO,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            time.sleep(3.0)
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)
        finally:
            stdout = proc.stdout.read() if proc.stdout is not None else ""
            stderr = proc.stderr.read() if proc.stderr is not None else ""
            if proc.stdout is not None:
                proc.stdout.close()
            if proc.stderr is not None:
                proc.stderr.close()

        self.assertNotIn('"type":"frame_batch"', stdout)
        self.assertNotIn("katzensteg: launching", stdout)
        self.assertNotIn("Traceback", stderr)


if __name__ == "__main__":
    unittest.main()
