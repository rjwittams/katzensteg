# Development

## Toolchain

Use Zig 0.16.0.

```sh
zig version
```

`build.zig.zon` pins the libxev fork at an immutable commit. Its
`darwin-tty-readiness` branch carries the kqueue terminal-readiness patch on top
of upstream Zig 0.16 support. Install system dependencies through the host OS
package manager.

Common dependencies:

- SDL2 development headers and libraries
- SDL3 development headers and libraries
- libyuv on Linux
- Vulkan loader and headers when working on Vulkan capture

## Build

```sh
zig build
```

To skip Vulkan while bringing up a machine:

```sh
zig build -Dvulkan=false
```

This is diagnostic-only. Once Vulkan dependencies are available, switch back to
the default `zig build` and `zig build test` before relying on the result.

## Tests

Run Zig unit tests:

```sh
zig build test
```

Run Python regression helpers:

```sh
python3 -m unittest discover -s scripts/katzensteg -p 'test_*.py'
```

For broader local verification:

```sh
zig build
zig build test
python3 -m unittest discover -s scripts/katzensteg -p 'test_*.py'
scripts/katzensteg/bootstrap_external_projects.py --doctor-only --root ~/dev
```

### Capture CPU benchmark

`benchmark_capture.py` launches a fixed SDL2 workload through the normal
launcher on an isolated PTY. It draws 3,000 small rectangles per frame for
120 frames, using the SDL dummy driver and file uploads at 320×240 pixels.

```sh
python3 scripts/katzensteg/benchmark_capture.py
```

Compare `cpu_ms_per_frame` across the three runs before and after a change,
using the same build mode. Process CPU includes the replay worker. The script
checks that every submitted frame was uploaded, so dropping frames cannot
produce a misleading improvement. `--frames`, `--rectangles`, and `--runs`
adjust the workload; `--build-prefix` selects an isolated build's `bin` and
`lib` directories. Timing is diagnostic, not a CI threshold. This measures
capture and presentation overhead, not terminal-emulator CPU or GPU readback.

## Runtime I/O

Standalone programs use the I/O capability supplied by `std.process.Init`.
The injected runtime and its logger each own a static `std.Io.Threaded` backend
initialized with `init_single_threaded`. These backends do not install SIGIO or
SIGPIPE handlers, allocate a worker pool, or support asynchronous tasks. The
runtime still uses its existing OS threads; the desktop WM still uses libxev.

`src/platform/` keeps file and directory operations attached to an explicit I/O
capability. Raw descriptor operations preserve `WouldBlock` so the existing
transport queues retain control of backpressure. Mutexes and conditions use
pthread primitives, including timed condition waits. Owners destroy these
objects after their users have stopped.

`test_injected_io.py` loads the core library into an ordinary C process and
checks that startup, threaded logging, and shutdown preserve the application's
SIGIO and SIGPIPE handlers. `test_embed_render_batches.py` covers SDL2 and SDL3
with both synchronous composition and queued replay.

## Logs

Runtime diagnostics go to `/tmp/katzensteg-*`.

```sh
ls /tmp/katzensteg-*.log
ls /tmp/katzensteg-*.out
```

Do not write diagnostics from captured runtime paths to stdout or stderr. The terminal may be using those streams for graphics output.

## Profiles Over Scripts

Prefer adding or fixing a launcher profile over adding a one-off shell script. Profiles make app launch behavior inspectable through `--dry-run` and keep repeated setup in one place.

## Useful First Checks

On a new machine:

```sh
zig build
./zig-out/bin/katzensteg --dry-run probe.input
./zig-out/bin/katzensteg probe.input
```

If that works, move on to real app profiles only after checking `docs/external-projects.md`.

## Probe Dry-Run Checks

Use dry-runs to confirm probe wiring and adapter selection before interactive runs.

```sh
./zig-out/bin/katzensteg --dry-run probe.embed.basic_sdl
./zig-out/bin/katzensteg --dry-run probe.embed.basic_sdl3
./zig-out/bin/katzensteg --dry-run probe.input
./zig-out/bin/katzensteg --dry-run probe.input.sdl3
./zig-out/bin/katzensteg --dry-run probe.gl
./zig-out/bin/katzensteg --dry-run probe.gl.sdl3
./zig-out/bin/katzensteg --dry-run probe.metal       # macOS
./zig-out/bin/katzensteg --dry-run probe.metal.sdl3  # macOS
./zig-out/bin/katzensteg --dry-run probe.vulkan
./zig-out/bin/katzensteg --dry-run probe.vulkan.sdl3
```

## Git Hooks

Enable the repo hooks to catch local workflow mistakes such as agent-prefixed
commit messages and branch names:

```sh
git config core.hooksPath .githooks
```
