# termscene / katzensteg

A Zig terminal graphics/runtime repo centered on `termscene` and `Katzensteg`.

This repo currently contains:

- `src/termscene/` — reusable engine core and kitty backend
- `tools/katzensteg/` — the main active SDL preload/runtime bridge work
- `games/ttytris/` — in-repo demo/stress game built on termscene
- `examples/termscene-demo/` — focused termscene feature demo
- `docs/katzensteg/` — Katzensteg design notes, plans, and roadmap

## Build targets

- `zig build run` — run ttytris
- `zig build debug-run` — run ttytris with debug settings
- `zig build termscene-demo` — run the termscene engine demo
- `zig build` — also builds `libkatzensteg` and the basic SDL bring-up demo
- `zig build basic-sdl-demo` — run the custom SDL2 demo used for Katzensteg bring-up

## Project direction

- `termscene` is the reusable rendering/core layer.
- `Katzensteg` is the main active runtime/interposition project in this repo.
- `ttytris` remains in-repo as a small demo/stress test, not the architectural center.

Inspector/devtools direction is now split clearly:

- producer-side instrumentation and optional embedded fallback inspector live here in `tools/katzensteg/`
- the canonical inspector service and web UI now live in the separate `whiskers` repo

The embedded inspector in this repo should be treated as fallback/dev-only infrastructure while `whiskers` becomes the primary inspection path.

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

## Inspector status

For current inspection work:

- prefer `whiskers-service` and `~/dev/whiskers/web/inspector`
- use `KATZENSTEG_WHISKERS_SOCKET=/tmp/whiskers.sock` to connect Katzensteg to `whiskers`
- keep `KATZENSTEG_INSPECT_SOCKET=...` only as an embedded fallback/debug path

The copied browser inspector and Python proxy have been removed from this repo on purpose so there is a single canonical web UI.
