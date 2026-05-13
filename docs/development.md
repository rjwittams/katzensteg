# Development

## Toolchain

Use Zig 0.15.2.

```sh
zig version
```

There is no `build.zig.zon` yet. Install system dependencies through the host OS package manager.

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
./zig-out/bin/katzensteg --dry-run probe.vulkan
./zig-out/bin/katzensteg --dry-run probe.vulkan.sdl3
```

## Git Hooks

Enable the repo hooks to catch local workflow mistakes such as agent-prefixed
commit messages and branch names:

```sh
git config core.hooksPath .githooks
```
