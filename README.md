# termscene

A Zig scene/diff rendering engine with a kitty terminal backend.

This repo currently contains:

- `src/termscene/` — reusable engine core and kitty backend
- `games/ttytris/` — flashy terminal Tetris built on termscene
- `examples/termscene-demo/` — focused termscene feature demo
- `docs/katzensteg/` — planning docs for the Katzensteg SDL preload bridge
- `tools/katzensteg/` — planned home for the helper/preload bridge implementation

## Build targets

- `zig build run` — run ttytris
- `zig build debug-run` — run ttytris with debug settings
- `zig build termscene-demo` — run the termscene engine demo

## Project direction

The repo is being reframed around **termscene** as the reusable core.

`ttytris` remains in-repo as a game/example and stress test for the engine.

The next ambitious subproject is **Katzensteg**: an SDL2 preload/helper bridge that renders SDL 2D games to a terminal via the kitty graphics protocol.
