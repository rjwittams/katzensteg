# Katzensteg Design Sketch

Date: 2026-04-17
Status: Draft

## Naming

- **Repo / umbrella project:** `termscene`
- **Reusable engine:** `termscene`
- **SDL preload/helper bridge:** `Katzensteg`

Working binary/library names:

- `katzensteg-helper`
- `libkatzensteg.so`

Short internal shorthand such as `ksteg` or `kbr` is acceptable in code if needed, but public-facing naming should prefer `Katzensteg`.

## Planned repo layout

```text
src/
  termscene/
    mod.zig
    types.zig
    backend.zig
    scene.zig
    kitty/
      mod.zig
      backend.zig
      detect.zig

tools/
  katzensteg/
    helper.zig
    preload.zig
    sdl2.zig
    handoff.zig
    input.zig
    compositor.zig
    cache.zig

examples/
  termscene-demo/
    main.zig

games/
  ttytris/
    main.zig
    core.zig
    renderer.zig
```

## Architectural intent

Katzensteg should be built as a bridge *on top of* `termscene`, not as a second unrelated kitty renderer stack.

Preferred conceptual flow:

```text
SDL intercepted calls
  -> Katzensteg runtime/compositor
  -> termscene-compatible scene/composition model
  -> termscene kitty backend
  -> terminal
```

This keeps kitty protocol behavior, placement identity, and capability detection centralized.

## Scope phases

### Phase A — repo/layout reframe
- center repo around `termscene`
- keep `ttytris` under `games/`
- keep focused engine demo under `examples/`

### Phase B — stage 0 / stage 1 only
- terminal-only kitty output test
- fd handoff via `SCM_RIGHTS`

### Phase C — minimum SDL path
- helper
- preload init
- hidden window
- `SDL_RenderCopy`
- `SDL_RenderPresent`
- texture upload/update
- keyboard events

Target: `testsprite2`

### Phase D — modulation/compositor correctness
- color mod
- alpha mod
- blend modes
- flip support
- decide rotation policy for v1

### Phase E — real game target
- NXEngine-evo or similar SDL2 title

## Immediate next deliverable

Before implementation, write a more detailed Katzensteg spec for:
- helper/runtime boundary
- socket handoff message shape
- SDL symbol surface to intercept first
- texture/compositor cache ownership
- resize policy for v1
