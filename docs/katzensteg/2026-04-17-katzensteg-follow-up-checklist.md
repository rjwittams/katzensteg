# Katzensteg Follow-up Checklist

Date: 2026-04-17
Status: Working notes

This note captures things we now know from bringing Katzensteg from a tiny controlled demo to a shared-linked upstream SDL renderer test target (`testsprite2`).

It is intentionally practical: a checklist of known gaps, future improvements, and constraints to keep in mind while broadening support.

## What is working now

- direct-tty mode can mirror real SDL renderer output into kitty/ghostty
- a shared-linked `testsprite2` can be interposed on macOS
- the mirror is recognizably correct enough to use upstream-like renderer tests as probes
- current supported/partially supported SDL surface includes:
  - `SDL_CreateWindow`
  - `SDL_CreateRenderer`
  - `SDL_CreateTexture`
  - `SDL_CreateTextureFromSurface`
  - `SDL_UpdateTexture`
  - `SDL_SetTextureColorMod`
  - `SDL_SetTextureAlphaMod`
  - `SDL_SetTextureBlendMode`
  - `SDL_SetRenderDrawColor`
  - `SDL_RenderClear`
  - `SDL_RenderFillRect`
  - `SDL_RenderDrawPoint`
  - `SDL_RenderDrawLine` (axis-aligned only for now)
  - `SDL_RenderCopy`
  - `SDL_RenderSetViewport`
  - `SDL_RenderSetClipRect`
  - `SDL_RenderPresent`
- a standalone kitty placement repro exists and is useful for isolating protocol behavior
- a background-only debug mode exists and is useful for proving layer-coverage issues
- kitty protocol handling is now centralized in `src/termscene/kitty/protocol.zig`

## Known current fidelity gaps

### Motion and placement
- sprite movement is cell-snapped, so smooth SDL pixel motion appears jerky
- future mitigation ideas:
  - transparent padding around images
  - source-offset tricks within a larger image footprint
  - subcell phase atlases / precomputed offset variants
  - kitty-specific offset features if they fit the protocol/backend cleanly

### Line rendering
- ortholinear lines are currently represented as cell-thick rects, not pixel-thin lines
- diagonal lines are intentionally skipped for now
- future improvement path:
  - Bresenham-style rasterization into terminal cells
  - cell coverage estimation
  - alpha/coverage tiles for thinner-looking lines
  - run merging so rasterized lines do not explode into too many tiny sprites

### Blending / modulation / z-order feel
- some modulation/blending cases are only approximate
- layer interactions can still look wrong when primitive approximations overlap textured copies
- suspicious cases should get tiny dedicated repros rather than being debugged only through large apps

### Edge/corner artifacts
- there are still likely off-by-one / clip-rounding artifacts near edges and corners
- example: isolated unexpected cell in a corner should be investigated with a tiny repro later

## Known architecture / platform constraints

### macOS interposition constraints
- upstream SDL test binaries may link SDL statically into the executable by default
- those binaries are poor targets for our current dyld interpose approach
- for useful upstream probing on macOS, prefer shared-linked test executables

### Direct tty mode behavior
- direct-tty mode writes to `/dev/tty`
- app stdout/stderr can still visibly interfere with rendering
- for noisy programs, redirect stdout/stderr during testing
- helper/handoff mode remains the longer-term answer for cleaner ownership

### Kitty protocol discipline
- placement/image semantics are subtle and should stay centralized in the protocol helper
- avoid scattering raw APC string building around the codebase again
- exact placement identity must remain explicit: `(image_id, placement_id)`

## Future transport / performance topics

### File transport / big image transport
- framebuffer-style workloads may eventually need non-inline transports
- likely direction:
  - append image payloads into a file/buffer
  - use the relevant kitty/file transport when appropriate
  - keep inline raw RGBA as fallback
- transport choice should remain capability-aware and degrade gracefully

### Frame diffing / dirty region detection
- framebuffer-heavy apps may benefit a lot from dirty-rect or frame-diff logic
- even crude dirty-rect detection would likely help before anything very sophisticated
- this is especially relevant for emulator-like workloads

### Texture/cache policy
- when broader app support arrives, re-check texture upload churn and image lifetime policy
- cached solid-color images are already useful; similar caching ideas may help other repeated assets

## Debugging tools worth keeping

- `examples/kitty-placement-repro/main.zig`
- `KATZENSTEG_BG_ONLY=1`
- shared-linked SDL test build recipe for `testsprite2`
- file-based Katzensteg logs in `/tmp/katzensteg-<pid>.log`

These are useful enough to keep around until helper/handoff mode and more complete renderer fidelity exist.

## Testing guidance going forward

When a visual bug appears, prefer this order:

1. determine whether it is:
   - protocol-level
   - backend retained-state logic
   - SDL primitive approximation
   - viewport/clip rounding
2. isolate with the smallest possible repro
3. only then generalize the fix back into Katzensteg

In particular, do not use large real applications as the only debugging surface for:
- line rasterization issues
- subcell motion problems
- blend/modulation oddities
- corner/cell clipping artifacts

## Candidate later milestones

- `SDL_RenderCopyEx` approximation/support
- `SDL_RenderGeometry` policy
- better line rasterization
- subcell motion quality pass
- file transport / large-frame transport path
- frame diffing / dirty-region updates
- helper/handoff mode for cleaner terminal ownership
- trying a framebuffer-heavy app or emulator as a stress test
