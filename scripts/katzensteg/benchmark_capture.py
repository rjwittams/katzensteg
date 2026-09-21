#!/usr/bin/env python3
"""Measure fixed-work SDL2 capture cost on an isolated PTY; requires zig build.

Run the same command before and after a change. CPU milliseconds per submitted
frame are the comparison metric, not CPU percentage (which varies with FPS).
This is a benchmark, not a machine-dependent timing gate for CI.
"""
import argparse
import errno
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
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--frames', type=int, default=120)
    parser.add_argument('--rectangles', type=int, default=3000)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--build-prefix', type=Path, default=ROOT / 'zig-out')
    args = parser.parse_args()
    if min(args.frames, args.rectangles, args.runs) < 1:
        parser.error('frames, rectangles and runs must be positive')
    prefix = args.build_prefix.resolve()
    with tempfile.TemporaryDirectory(prefix='ks-capture-bench-') as directory:
        folder = Path(directory)
        binary = folder / 'app'
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'sdl2'], text=True))
        subprocess.run(['cc', '-O2', str(ROOT / 'scripts/katzensteg/fixtures/capture_benchmark.c'),
                        '-o', str(binary), *flags], check=True)
        report = folder / 'report.json'
        profiles = {'bench.capture': {'extends': ['adapter.sdl2_preload', 'runtime.fullscreen_file'],
                    'target': str(binary), 'args': [str(args.frames), str(args.rectangles)],
                    'stdout': str(report), 'stderr': str(folder / 'stderr'),
                    'env': {
                        'DYLD_INSERT_LIBRARIES': {'macos': str(prefix / 'lib/libkatzensteg-sdl2.dylib')},
                        'LD_PRELOAD': {'linux': str(prefix / 'lib/libkatzensteg-sdl2.so')},
                    }}}
        (folder / 'profiles.json').write_text(json.dumps({'profiles': profiles}))
        env = dict(os.environ, SDL_VIDEODRIVER='dummy', SDL_RENDER_DRIVER='software',
                   KATZENSTEG_REPO=str(ROOT), KATZENSTEG_PROFILE_DIR=f'{ROOT / "profiles"}:{folder}',
                   KATZENSTEG_REAL_WINDOW='hide', KATZENSTEG_OUTPUT_PROFILE='file_whole',
                   KATZENSTEG_INTERCEPT_MODE='queued_replay')
        for name in ('KATZENSTEG_TARGET', 'KATZENSTEG_WHISKERS_SOCKET', 'KATZENSTEG_STATS',
                     'KATZENSTEG_TRACE_BLOCKING'):
            env.pop(name, None)
        for run in range(args.runs):
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 320, 240))

            def controlling_terminal():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            proc = subprocess.Popen([str(prefix / 'bin/katzensteg'), 'bench.capture'],
                                    stdin=slave, stdout=slave, stderr=slave, env=env,
                                    preexec_fn=controlling_terminal)
            output = bytearray()

            def read_output():
                try:
                    return os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        return b''  # Linux PTY EOF.
                    raise

            try:
                deadline = time.monotonic() + max(30, args.frames * .2)
                while proc.poll() is None:
                    if time.monotonic() > deadline:
                        raise TimeoutError('capture workload did not finish')
                    if select.select([master], [], [], .02)[0]:
                        output.extend(read_output())
                while select.select([master], [], [], 0)[0]:
                    data = read_output()
                    if not data:
                        break
                    output.extend(data)
                if proc.returncode:
                    raise RuntimeError(f'launcher exited {proc.returncode}: {output[-2000:]!r}')
                result = json.loads(report.read_text())
                uploads = sum(b'a=t,' in header and b's=' in header for header in
                              re.findall(rb'\x1b_G([^;\x1b]*)', output))
                result.update(run=run + 1, uploads=uploads,
                              cpu_ms_per_frame=result['cpu_seconds'] * 1000 / args.frames)
                print(json.dumps(result), flush=True)
                if uploads < args.frames + 1:
                    raise RuntimeError('frames were dropped; reduce workload before comparing CPU cost')
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                os.close(master)
                os.close(slave)


if __name__ == '__main__':
    main()
