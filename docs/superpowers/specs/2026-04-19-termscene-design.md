# termscene Design

Date: 2026-04-19
Status: Approved design
Project: ttytris

## Summary

Extract a reusable scene-based dirty sprite engine from ttytris.

The engine will be called `termscene` and will provide:
- a backend-agnostic scene model
- first-class sprite and text primitives
- retained previous-frame diffing with immediate-mode scene submission
- a kitty backend as the first implementation
- a migration path for ttytris to become a client of the engine

The design is intentionally shaped so future backends such as SDL and web canvas can be added later without forcing that abstraction work up front.

## Goals

- Remove direct kitty placement/delete logic from ttytris gameplay code.
- Provide a reusable scene engine for other terminal and non-terminal visual apps.
- Keep client code immediate-mode and simple.
- Make dirty tracking an engine responsibility.
- Treat text as a first-class scene primitive.
- Keep the backend seam clean enough for future SDL/web implementations.

## Non-Goals for v1

- Implementing SDL or web backends now.
- Sprite-font text rendering now.
- A full animation subsystem now.
- Generic rect/panel primitives unless required during migration.
- Dynamic tile sizing implementation now.

## Design Overview

The system is split into three layers:

1. **Scene model**
   - Backend-agnostic description of the desired visual frame.
   - Contains sprite and text nodes.

2. **Diff engine**
   - Retains previous frame state.
   - Computes adds, updates, and removals between frames.

3. **Backend**
   - Applies the diff to a concrete rendering target.
   - v1 backend is kitty.

ttytris will become a producer of scenes rather than a direct emitter of kitty protocol commands.

## Client Model

The engine presents an immediate-mode frame API to clients:

1. begin scene
2. submit sprites
3. submit text
4. flush

Internally, the engine retains prior frame state and performs diffing.

This gives client code a simple model while preserving the performance benefits of a retained dirty sprite engine.

## Scene Primitives

### SpriteNode

A sprite node represents an image-backed visual element.

Fields:
- `key`: stable logical identity across frames
- `image`: image handle
- `source_rect`: crop in image pixel space
- `dest_rect`: destination in logical cell space
- `z`: layer / z order
- `visible`: boolean

Notes:
- The engine does not require a special atlas type.
- Atlases are represented by `image + source_rect`.
- Tetris-specific atlas region selection remains in ttytris, not in the engine.

### TextNode

A text node represents text as a scene primitive.

Fields:
- `key`: stable logical identity across frames
- `content`: string
- `dest`: logical cell position or rect
- `z`: layer / z order
- `style`: text styling information
- `mode`: `terminal`, `sprite_font`, or `auto`
- `visible`: boolean

Initial style scope:
- foreground color
- optional background color

v1 backend behavior:
- kitty backend renders text in terminal text mode
- sprite-font mode is reserved for later work

This keeps text inside the engine’s diff and layout model without forcing font-atlas work into v1.

## Coordinate Model

The engine uses two coordinate spaces:

### Source space
- Image pixels
- Used by `source_rect`

### Destination space
- Logical cells
- Used by `dest_rect` and text destinations

This matches the current ttytris model and leaves room for future backends to map cells to pixels differently.

## Backend Seam

Backends consume **scene diffs**, not raw immediate draw calls.

This keeps:
- scene ownership centralized
- dirty tracking centralized
- backend logic focused on application of changes

Backend responsibilities:
- image registration and lifecycle
- apply sprite adds/updates/removes
- apply text adds/updates/removes
- optional backend-local bookkeeping

Initial backend:
- `KittyBackend`

Future backends:
- `SdlBackend`
- `CanvasBackend`

## Asset Model

### Images
Images are backend resources with:
- handle/id
- width/height metadata
- optional debug label

### Atlas regions
Atlas regions are not a special engine type in v1.
Clients define and manage source rects themselves.

This keeps the engine generic for:
- single-image sprites
- atlases
- sprite sheets
- future font atlases

## Dirty Strategy

The engine diff model is keyed by stable logical keys.

Per frame:
- submitted key absent last frame -> add
- submitted key present but changed -> update
- key present last frame but not submitted this frame -> remove
- unchanged key -> no backend op

This is the core reusable behavior of `termscene`.

## Tetris Integration

ttytris will retain ownership of:
- game rules and board state
- layout policy
- atlas region definitions
- visual semantics (ghost, active glow, sweeps, status text)

The engine will own:
- previous frame retained state
- diffing
- backend application
- image registration lifecycle

Per tick, ttytris will:
- update game state
- begin scene
- submit background, board cells, active piece, ghost, previews, overlays, and text
- flush

After migration, ttytris should no longer call kitty placement/delete helpers directly from gameplay rendering logic.

## Proposed Module Structure

Initial structure inside `src/`:

- `src/termscene/scene.zig`
  - scene model types
  - node submission interfaces
- `src/termscene/diff.zig`
  - previous-frame retention and diff computation
- `src/termscene/backend.zig`
  - backend interface definitions
- `src/termscene/kitty.zig`
  - kitty backend implementation
- `src/termscene/types.zig`
  - shared structs/enums such as rects, colors, keys, handles
- `src/termscene/mod.zig`
  - public entry point

ttytris-specific rendering/layout code remains outside `termscene`.

## API Direction

Exact Zig API names can be finalized in implementation planning, but the intended shape is:

- create engine
- register images
- begin scene
- submit sprite nodes
- submit text nodes
- flush

The external API should feel immediate-mode.
The engine internals should remain retained and diff-based.

## Diagnostics and Debugging

The engine should expose lightweight per-flush statistics such as:
- sprite count submitted
- text count submitted
- sprite adds/updates/removes
- text adds/updates/removes
- backend ops emitted

In debug builds, the engine should validate:
- duplicate keys within a frame
- source rect sanity when image metadata is known
- destination rect sanity
- unsupported text mode handling

These checks should help prevent the kind of rendering/debugging problems encountered during ttytris development.

## Error Handling

Backends should surface errors for:
- image registration/upload failure
- invalid image handle
- unsupported text mode
- backend transport failure

The engine should not silently swallow backend failures.

## Testing Strategy

### Engine unit tests
- sprite diff add/update/remove
- text diff add/update/remove
- mixed sprite/text frame diffs
- duplicate key rejection
- visibility/removal behavior

### Kitty backend tests
- command generation from diffs
- stable placement key handling
- text update/clear behavior

### Integration tests
- migrate existing proof scenes to `termscene`
- a small stress scene
- ttytris scene production smoke coverage

## Migration Strategy

Recommended migration order:

1. Introduce `termscene` core types and diff engine.
2. Implement kitty backend with image registration and sprite diff application.
3. Add text-node support using terminal text mode in kitty backend.
4. Port the existing proof scenes to `termscene`.
5. Port ttytris rendering incrementally:
   - background and atlas registration
   - active/ghost sprites
   - previews
   - board tiles
   - overlays/effects
   - text
6. Delete old direct kitty helper usage from ttytris rendering path.

## Open Questions Deferred to Planning

- Exact public Zig API names and file boundaries.
- Whether `DestRect` should support position-only and rect forms or only rect form.
- Whether the kitty backend should internally batch writes into a single command buffer per flush.
- When to add sprite-font text mode.

## Recommendation

Proceed with a `termscene` extraction built as:
- a generic scene diff core
- a kitty backend first
- first-class text support in the scene model
- ttytris migrated as the first client

This is the best balance between immediate usefulness and future reuse across kitty, SDL, and web canvas targets.
