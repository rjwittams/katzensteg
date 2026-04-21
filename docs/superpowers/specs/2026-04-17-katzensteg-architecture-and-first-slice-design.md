# Katzensteg Architecture and First Slice Design

Date: 2026-04-17
Status: Approved
Project: termscene / Katzensteg

## Summary

Katzensteg is an SDL2 preload/helper bridge for rendering SDL 2D games to a terminal via the kitty graphics protocol.

This design covers:
- an umbrella architecture for Katzensteg
- a detailed first implementation slice

The repo remains centered on `termscene` as the reusable engine. Katzensteg is planned as a tool subproject under `tools/katzensteg/`.

## Naming

- Umbrella repo/project: `termscene`
- Reusable engine: `termscene`
- SDL preload/helper bridge: `Katzensteg`

Planned public-facing names:
- `katzensteg-helper`
- `libkatzensteg.so`

## Goals

- Intercept SDL2 renderer calls and render them to the terminal via kitty graphics.
- Keep the SDL app functioning through the real SDL path while Katzensteg is being brought up.
- Reuse `termscene` for retained diffing and kitty backend behavior wherever practical.
- Allow early development without requiring helper/fd handoff from day one.

## Non-Goals for the First Slice

- Full SDL2 renderer coverage.
- Input synthesis into SDL events.
- Hidden-window enforcement.
- Resize handling.
- Render targets beyond the default target.
- `SDL_CreateTextureFromSurface`.
- `SDL_LockTexture` / `SDL_UnlockTexture`.
- `SDL_RenderCopyEx`.
- `SDL_RenderFillRect`.

## Architecture

### Runtime modes

Katzensteg should support two runtime modes.

#### 1. Direct tty mode
If no handoff socket env var is present, the preload library opens `/dev/tty` itself.

This is the bootstrap and development mode.

In this mode, the library owns:
- tty open
- raw mode
- alternate screen
- kitty keyboard mode
- teardown

#### 2. Helper handoff mode
If a handoff socket env var is present, the preload library receives tty fds from the helper over the socket.

After handoff, the library still performs the same terminal/session setup itself.

The helper remains useful later for:
- supervision
- resize forwarding
- stdout/stderr capture
- safer launch ergonomics

### Terminal lifecycle ownership

The library should own terminal setup and teardown in both modes.

This keeps behavior consistent between direct mode and helper mode and avoids splitting terminal semantics across two different components.

### Rendering architecture

Katzensteg should use a thin SDL-facing frame-builder layer on top of `termscene`.

Conceptual flow:

```text
SDL intercepted calls
  -> Katzensteg frame-builder / runtime
  -> termscene.SceneEngine
  -> termscene kitty backend
  -> terminal
```

Katzensteg is responsible for SDL semantics.

`termscene` is responsible for:
- retained scene diffing
- kitty backend application
- generic backend behavior

If Katzensteg reveals missing generic features in `termscene`, those should be added to `termscene` deliberately rather than duplicated.

## Approach Options Considered

### Approach 1 — Katzensteg-specific retained diff layer
Katzensteg keeps its own retained frame/placement diff and uses only low-level kitty helpers.

Pros:
- maximum local control
- easy to tune around SDL behavior

Cons:
- duplicates scene/diff logic already present in `termscene`
- risks long-term divergence
- weakens the repo’s engine-centered architecture

### Approach 2 — Push SDL semantics directly into `termscene`
Map SDL renderer calls almost directly onto termscene primitives.

Pros:
- aggressive reuse
- fewer layers

Cons:
- likely forces SDL-specific concerns into a generic engine
- not a good boundary for early iteration

### Approach 3 — Thin Katzensteg frame-builder on top of `termscene`
Katzensteg accumulates SDL frame intent, chooses stable scene identities, and submits scene nodes to `termscene`.

Pros:
- reuses `termscene` where it is strongest
- keeps SDL semantics out of the generic engine
- allows selective extension of `termscene` when a feature proves reusable

Cons:
- requires care in stable identity selection
- may expose missing generic engine capabilities

### Recommendation

Use **Approach 3**.

## First Detailed Slice

### Success target
The first detailed slice targets a **small custom SDL2 test program we control**.

It should not target an upstream SDL test app yet.

A small custom test app lets us:
- constrain the SDL feature surface
- avoid stdio noise
- control texture upload and frame behavior precisely
- compare terminal output against the real SDL window

### SDL surface in the first slice
The first slice only needs to support:
- `SDL_CreateWindow`
- `SDL_CreateRenderer`
- `SDL_CreateTexture`
- `SDL_UpdateTexture`
- `SDL_RenderClear`
- `SDL_RenderCopy`
- `SDL_RenderPresent`

All of these should still forward to the real SDL implementation.

Selected ones will additionally produce Katzensteg side effects.

### Visible real window for the first slice
The real SDL window should remain visible during the first slice.

This provides:
- a debugging reference
- semantic comparison against terminal rendering
- a lower-risk bring-up path

### Anchor function
The first meaningful anchor is `SDL_RenderPresent`.

This is where Katzensteg should:
- treat the recorded draw state as a complete frame
- translate it into scene nodes
- submit it to `termscene`
- let `termscene` diff/apply terminal updates
- then still forward to the real SDL present call

### Texture strategy for the first slice
Only explicit upload textures are supported.

Supported path:
- `SDL_CreateTexture`
- `SDL_UpdateTexture`

Not yet supported:
- `SDL_CreateTextureFromSurface`
- `SDL_LockTexture` / `SDL_UnlockTexture`

The custom SDL test program should be written to fit this narrower texture model.

### Kitty-side rendering model
The first slice should use retained kitty images plus per-frame placement rebuilding.

That means:
- textures map to kitty image registrations
- draw calls accumulate frame placements
- `RenderPresent` emits the current frame’s scene state through `termscene`
- `termscene` computes diffs against the previous presented scene

This avoids building a temporary full-frame software compositor that does not match the intended long-term architecture.

## SDL Semantics and Frame Model

### `SDL_RenderClear`
`SDL_RenderClear` should be modeled as:
- “start the pending frame with a solid background color”

It should **not** be treated as an immediate terminal clear operation.

Instead, the frame-builder records the clear color as part of the pending frame model.

At present time, Katzensteg should represent that background as a stable scene element.

### `SDL_RenderCopy`
`SDL_RenderCopy` should record a draw op referencing:
- texture identity
- source rect
- destination rect
- draw order within the pending frame

Katzensteg should not emit terminal protocol immediately from `SDL_RenderCopy`.

### `SDL_RenderPresent`
`SDL_RenderPresent` is the terminal emission point.

At present time, Katzensteg should:
1. start frame translation
2. submit background node from the current clear color
3. submit nodes for the recorded render copies
4. diff through `termscene`
5. apply kitty updates
6. clear the temporary draw-op list for the next frame
7. forward to the real SDL present call

## Component Boundaries

### 1. Interposition layer
Responsibilities:
- export C ABI SDL2 symbols
- resolve real SDL symbols via `dlsym(RTLD_NEXT, ...)`
- maintain global Katzensteg runtime state
- forward all calls to real SDL
- add side effects for selected symbols

This layer should stay thin.

### 2. Runtime/session layer
Responsibilities:
- choose init mode: direct tty or handoff
- own tty read/write fds
- enter raw mode
- enable kitty keyboard / alt screen
- register teardown handlers
- own kitty backend instance
- own `termscene.SceneEngine`

This is the single source of truth for terminal lifecycle.

### 3. SDL frame-builder
Responsibilities:
- track frame-relevant SDL renderer state
- record current clear color
- record texture metadata and kitty image ids
- record `RenderCopy` operations for the current frame
- translate the pending SDL frame into stable scene nodes at present time

This layer is SDL-aware.

### 4. termscene integration layer
Responsibilities:
- choose stable `NodeKey`s for background and blits
- submit sprites into `SceneEngine`
- rely on `termscene` for retained diffing
- request or add generic engine extensions when needed

## Stable Identity Strategy

Katzensteg should choose stable scene identities itself.

That means the SDL frame-builder, not SDL directly, owns the mapping from frame semantics to scene-node identity.

Likely categories include:
- a stable background node identity
- stable identities for repeated blit slots in a frame
- stable identities for long-lived texture-backed visuals where applicable

If this reveals missing generic support in `termscene`, that should be addressed there.

## Error Handling and Logging

### Error handling posture
For the first slice, Katzensteg should fail soft where possible.

If terminal-side setup fails:
- real SDL should still continue working
- Katzensteg should mark terminal rendering inactive
- intercepted calls become effectively pass-through on the terminal side

### Unsupported features
For the first slice, unsupported SDL renderer features should:
- always forward to real SDL
- be ignored or degraded on the terminal side
- be logged conservatively

### Logging policy
Katzensteg should **not** log to stdout or stderr.

All diagnostics should go to a dedicated log file.

Logging should be:
- file-based
- non-spammy
- first-occurrence oriented where possible

This preserves compatibility with:
- redirected app stdout/stderr
- future helper-based output capture
- possible future in-scene log display

## Testing and Milestones

### Milestone 0 — non-SDL experiments
Small non-SDL experiments are acceptable during bring-up for:
- direct `/dev/tty` setup
- raw mode / teardown correctness
- retained kitty placement validation

These are allowed on the path, but they are not the formal first success target.

### Milestone 1 — first detailed slice
Target:
- custom SDL2 test program
- direct tty mode
- visible SDL window
- symbol interposition with forwarding intact
- selected side effects for texture upload, clear, copy, and present
- terminal rendering through Katzensteg frame-builder + `termscene`

Success criteria:
- terminal output visibly tracks the SDL test app
- real SDL window remains a correct reference
- no Katzensteg logging to stdout/stderr
- terminal teardown restores sane shell state
- if terminal setup fails, the SDL app still runs through real SDL

### Milestone 2 — upstream SDL validation
Target a simple upstream SDL2 renderer test app, likely `testsprite2`.

This stage broadens confidence in:
- texture handling
- frame semantics
- repeated render behavior
- correctness of the present-driven scene translation model

### Milestone 3 — helper/handoff mode
Add:
- helper executable
- socket handoff of tty fds
- optional later supervision and resize communication

At this stage helper mode becomes the preferred operational path, while direct tty mode remains useful for development.

## Planned Repo Placement

Planned implementation home:

```text
tools/
  katzensteg/
    helper.zig
    preload.zig
    sdl2.zig
    handoff.zig
    input.zig
    compositor.zig
    cache.zig
```

This keeps:
- `src/termscene/` for the reusable engine
- `examples/` for demos
- `games/` for engine-using games
- `tools/katzensteg/` for the SDL preload/helper bridge

## Immediate Next Step

After this design checkpoint, the next work should be a detailed implementation plan for:
- direct tty bootstrap mode
- interposition scaffolding with forwarding intact
- first custom SDL2 test program
- texture upload + present-driven scene translation path
