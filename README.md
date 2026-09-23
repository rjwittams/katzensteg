# Katzensteg

Katzensteg puts native application graphics in your terminal.

It currently works by launching applications with the Katzensteg runtime injected into the process, using `LD_PRELOAD` on Linux and `DYLD_INSERT_LIBRARIES` on macOS. The runtime captures tested SDL2/SDL3 and graphics presentation paths and sends them to a terminal or a host.

The current practical support boundary is workload-specific. Several larger test applications have needed app-side patches or build modes so they expose a capturable output/input path. The current proving ground is games and emulators: RetroArch, ScummVM, Moonlight, Chiaki, small SDL probes, and similar workloads.

This is alpha software. It is already useful for experiments and demos, but the interfaces, profiles, and supported app matrix are still moving.

Project site: <https://katzensteg.dev>

## What Works Today

- SDL2 and SDL3 software and renderer paths used by the current probes and patched app profiles.
- Keyboard and mouse input for the main tested paths.
- Launcher profiles for repeatable app runs.
- Direct terminal output, hosted panels and optional Jackstay CPU publishing.
- Kitty-compatible output in terminals such as Kitty and Ghostty, with additional compatibility testing in WezTerm and iTerm2.

OpenGL, Vulkan and Metal capture work exists for specific experiments and profiles. These paths do not imply support for arbitrary applications using those APIs.

## Try It

Build with Zig 0.16.0:

```sh
zig build
```

List available profiles:

```sh
./zig-out/bin/katzensteg
```

Run the SDL input probe:

```sh
./zig-out/bin/katzensteg probe.input
```

Preview a profile without launching it:

```sh
./zig-out/bin/katzensteg --dry-run probe.input
```

If you use one checkout regularly, an alias keeps the commands short:

```sh
alias ks="$HOME/dev/katzensteg/zig-out/bin/katzensteg"
ks --dry-run probe.input
ks probe.input
```

Use the explicit `./zig-out/bin/katzensteg` path when testing a different worktree.

For real app profiles, start with `--dry-run`. Many of them expect local app checkouts, game/media data, or platform-specific setup that is intentionally not stored in this repository.

## Requirements

- Zig 0.16.0.
- SDL2 and SDL3 development headers and libraries.
- A terminal with kitty graphics protocol support.
- libyuv on Linux.
- Vulkan loader and headers for Vulkan capture.

`build.zig.zon` pins the libxev fork used by the desktop WM. SDL, Vulkan and
other system libraries still come from the host package manager.

## Running Apps

The `katzensteg` launcher is the normal entry point. Profiles live in `profiles/` and describe how to start a target app, what runtime policy to use, and which local paths or environment settings are needed.

Useful commands:

```sh
./zig-out/bin/katzensteg
./zig-out/bin/katzensteg --dry-run <profile>
./zig-out/bin/katzensteg <profile>
```

See `docs/launcher.md` for profile details.

## External Projects

Some useful targets need local source checkouts or Katzensteg-specific app branches. The helper in `scripts/katzensteg/bootstrap_external_projects.py` is meant to make that less mysterious: it records the expected repositories, fork remotes, branches, build notes, and profile names for the current smoke-test matrix.

It is not a package manager and it is not mature. Treat it as pre-alpha automation: useful for checking what a local machine is missing, but still expected to break as it sees more systems and more setups.

Useful starting points:

```sh
scripts/katzensteg/bootstrap_external_projects.py --doctor-only --root ~/dev
scripts/katzensteg/bootstrap_external_projects.py --dry-run --root ~/dev
```

See `docs/external-projects.md` for the current external app inventory.

## Development

Run the Zig unit tests:

```sh
zig build test
```

Run the Python regression helpers:

```sh
python3 -m unittest discover -s scripts/katzensteg -p 'test_*.py'
```

Runtime logs go to `/tmp/katzensteg-*`.

## Docs

- `docs/roadmap.md` - current work, tracked next steps, and later directions.
- `docs/architecture.md` - current architecture and support boundary.
- `docs/launcher.md` - launcher and profile usage.
- `docs/external-projects.md` - external app fork inventory.
- `docs/development.md` - build, test, and logging notes.
