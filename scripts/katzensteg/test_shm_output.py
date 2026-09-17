#!/usr/bin/env python3
"""Exercise real SDL producers with a terminal that consumes Kitty SHM uploads."""
import base64
import ctypes
import errno
import json
import mmap
import os
from pathlib import Path
import re
import select
import subprocess
import time
import unittest

REPO = Path(__file__).resolve().parents[2]
LIBC = ctypes.CDLL(None, use_errno=True)
# macOS shm_open is variadic; describe only its fixed arguments.
LIBC.shm_open.argtypes = [ctypes.c_char_p, ctypes.c_int]
LIBC.shm_open.restype = ctypes.c_int
LIBC.shm_unlink.argtypes = [ctypes.c_char_p]


def open_shm(name):
    return LIBC.shm_open(name, os.O_RDONLY, ctypes.c_uint(0))


class SharedMemoryOutputTest(unittest.TestCase):
    def test_sdl_consumption_discard_and_shutdown(self):
        for profile in ('probe.embed.basic_sdl', 'probe.embed.basic_sdl3'):
            with self.subTest(profile=profile):
                self.check_producer(profile)

    def check_producer(self, profile):
        env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_RENDER_DRIVER='software',
                   KATZENSTEG_REAL_WINDOW='hide', KATZENSTEG_REPO=str(REPO))
        proc = subprocess.Popen([str(REPO/'zig-out/bin/katzensteg'), '--embed-jsonl', profile],
                                env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        pending = bytearray()
        names = set()
        def send(message):
            proc.stdin.write((json.dumps(message)+'\n').encode())
            proc.stdin.flush()
        def message():
            deadline = time.monotonic() + 8
            while b'\n' not in pending:
                self.assertLess(time.monotonic(), deadline, 'producer stalled')
                self.assertIsNone(proc.poll(), 'producer exited')
                if select.select([proc.stdout], [], [], .1)[0]:
                    pending.extend(os.read(proc.stdout.fileno(), 65536))
            line, _, rest = pending.partition(b'\n')
            pending[:] = rest
            return json.loads(line)
        try:
            send({'type': 'hello', 'protocol': 'katzensteg.embed_jsonl', 'version': 1})
            send({'type': 'attach', 'window_id': 'main',
                  'placeholder': {'image_id': 777, 'cols': 30, 'rows': 10,
                                  'target_px': {'w': 300, 'h': 200}},
                  'upload': {'profile': 'shm'}})
            frames = 0
            # More uploads than the pool can hold: both consumed and discarded
            # frames must release capacity while the producer remains running.
            while frames < 80:
                batch = message()
                if batch.get('type') != 'frame_batch' or not batch['groups']['uploads']:
                    continue
                for upload in batch['groups']['uploads']:
                    match = re.fullmatch(r'\x1b_G([^;]+);([^\x1b]+)\x1b\\', upload)
                    self.assertIsNotNone(match)
                    fields = dict(field.split('=') for field in match[1].split(','))
                    self.assertEqual(fields['t'], 's')
                    name = base64.b64decode(match[2])
                    self.assertNotIn(name, names)
                    names.add(name)
                    fd = open_shm(name)
                    self.assertGreaterEqual(fd, 0, (name, ctypes.get_errno()))
                    try:
                        size = int(fields['s']) * int(fields['v']) * 4
                        self.assertGreaterEqual(os.fstat(fd).st_size, size)
                        with mmap.mmap(fd, size, access=mmap.ACCESS_READ) as pixels:
                            if frames % 2 == 0:
                                self.assertEqual(LIBC.shm_unlink(name), 0)
                                self.assertEqual(len(pixels[:]), size)
                            else:
                                send({'type': 'discard_batch', 'window_id': 'main', 'seq': batch['seq']})
                    finally:
                        os.close(fd)
                frames += 1
            # Stop reading graphics, then request orderly shutdown and drain it.
            send({'type': 'shutdown'})
            proc.communicate(timeout=8)
            for name in names:
                fd = open_shm(name)
                if fd >= 0:
                    os.close(fd)
                    self.fail(f'upload leaked after shutdown: {name!r}')
                self.assertEqual(ctypes.get_errno(), errno.ENOENT)
        finally:
            if proc.poll() is None:
                try:
                    send({'type': 'shutdown'})
                    proc.communicate(timeout=5)
                except (BrokenPipeError, subprocess.TimeoutExpired):
                    proc.kill()
            proc.communicate(timeout=5)
            for name in names:
                LIBC.shm_unlink(name)


if __name__ == '__main__':
    unittest.main()
