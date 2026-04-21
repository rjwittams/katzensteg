# termscene

A Zig scene/diff rendering engine with a kitty terminal backend.

This repo currently contains:

- `src/termscene/` — reusable engine core and kitty backend
- `games/ttytris/` — flashy terminal Tetris built on termscene
- `examples/termscene-demo/` — focused termscene feature demo
- `docs/katzensteg/` — planning docs for the Katzensteg SDL preload bridge
- `tools/katzensteg/` — Katzensteg SDL preload bridge implementation

## Build targets

- `zig build run` — run ttytris
- `zig build debug-run` — run ttytris with debug settings
- `zig build termscene-demo` — run the termscene engine demo
- `zig build` — also builds `libkatzensteg` and the basic SDL bring-up demo
- `zig build basic-sdl-demo` — run the custom SDL2 demo used for Katzensteg bring-up

## Project direction

The repo is being reframed around **termscene** as the reusable core.

`ttytris` remains in-repo as a game/example and stress test for the engine.

The next ambitious subproject is **Katzensteg**: an SDL2 preload/helper bridge that renders SDL 2D games to a terminal via the kitty graphics protocol.

## Katzensteg first-slice bootstrap

Current first-slice behavior:
- direct `/dev/tty` mode only
- file-based logging only (no stdout/stderr diagnostics)
- real SDL window remains visible for comparison/debugging
- terminal mirroring currently targets a small custom SDL2 demo and the minimal supported renderer API surface
- if no real controlling tty is available, Katzensteg fails soft and the SDL app continues normally

Build:

```bash
zig build -Doptimize=Debug
```

Run the SDL bring-up demo normally:

```bash
./zig-out/bin/basic-sdl-demo
```

Run it under Katzensteg preload on macOS from a real terminal session:

```bash
DYLD_INSERT_LIBRARIES="$PWD/zig-out/lib/libkatzensteg.dylib" ./zig-out/bin/basic-sdl-demo
```

Katzensteg logs to a file under `/tmp`, for example:

```bash
ls /tmp/katzensteg-*.log
```
