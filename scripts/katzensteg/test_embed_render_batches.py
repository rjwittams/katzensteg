#!/usr/bin/env python3
import json
import os
import subprocess
import time
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class EmbedRenderBatchSmoke(unittest.TestCase):
    def test_basic_sdl_emits_frame_batch_after_attach(self):
        launcher = REPO / "zig-out" / "bin" / "katzensteg"
        demo = REPO / "zig-out" / "bin" / "basic-sdl-demo"
        self.assertTrue(launcher.exists(), f"missing launcher: {launcher}")
        self.assertTrue(demo.exists(), f"missing demo: {demo}")

        env = os.environ.copy()
        env.setdefault("KATZENSTEG_REPO", str(REPO))
        proc = subprocess.Popen(
            [str(launcher), "--embed-jsonl", "probe.embed.basic_sdl"],
            cwd=REPO,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        assert proc.stdin is not None
        assert proc.stdout is not None

        proc.stdin.write(json.dumps({"type": "hello", "protocol": "katzensteg.embed_jsonl", "version": 1}) + "\n")
        proc.stdin.write(
            json.dumps(
                {
                    "type": "attach",
                    "window_id": "main",
                    "rect_cells": {"row": 1, "col": 1, "rows": 24, "cols": 80},
                    "aspect": "contain",
                    "id_ranges": {
                        "image": [[100000, 199999]],
                        "placement": [[200000, 299999]],
                    },
                }
            )
            + "\n"
        )
        proc.stdin.close()

        deadline = time.monotonic() + 8.0
        lines = []
        frame_batch = None
        try:
            while time.monotonic() < deadline:
                line = proc.stdout.readline()
                if not line:
                    if proc.poll() is not None:
                        break
                    time.sleep(0.05)
                    continue
                lines.append(line)
                self.assertTrue(line.startswith("{"), f"launcher wrote non-JSONL stdout: {line!r}")
                message = json.loads(line)
                if message.get("type") == "frame_batch":
                    frame_batch = message
                    break
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)
            if proc.stdout is not None:
                proc.stdout.close()

        stderr = proc.stderr.read() if proc.stderr is not None else ""
        if proc.stderr is not None:
            proc.stderr.close()
        self.assertIsNotNone(frame_batch, f"no frame_batch in stdout={lines!r} stderr={stderr!r}")
        groups = frame_batch["groups"]
        self.assertGreater(len(groups["uploads"]), 0)
        self.assertGreater(len(groups["placements"]), 0)


if __name__ == "__main__":
    unittest.main()
