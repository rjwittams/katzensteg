# Katzensteg Inspector UI designer handoff

## Purpose

Design a web-based developer tool for inspecting how **Katzensteg** captures SDL 2D rendering and turns it into terminal graphics output.

This should feel closer to **browser dev tools / perf tooling** than to an end-user app.

The goal is not just to show logs. The goal is to help us answer:

- what did SDL ask for?
- what internal representation did Katzensteg choose?
- what terminal commands/images did that turn into?
- what did it cost in time / bytes / placements / frame drops?
- what strategy changes might improve correctness or performance?

This document is intentionally based on the **data we want to expose**, not just what is already exposed today.

---

## Project context

### Useful references

These are useful background references for understanding the APIs and graphics model the inspector is visualizing.

- SDL renderer API overview and related docs:
  - https://wiki.libsdl.org/SDL2/CategoryRender
  - https://wiki.libsdl.org/SDL2/SDL_RenderCopy
  - https://wiki.libsdl.org/SDL2/SDL_RenderPresent
  - https://wiki.libsdl.org/SDL2/SDL_UpdateTexture
  - https://wiki.libsdl.org/SDL2/SDL_LockTexture
  - https://wiki.libsdl.org/SDL2/SDL_SetTextureBlendMode
- Kitty graphics protocol spec:
  - https://sw.kovidgoyal.net/kitty/graphics-protocol/

The designer does not need to become an SDL or kitty expert, but these links help explain the kinds of operations, resources, and output artifacts that will show up in the inspector.

### What Katzensteg is

Katzensteg is an SDL interception/render bridge inside the `ttytris` repo.

At a high level, an application thinks it is drawing with SDL's 2D renderer API. Katzensteg sits in the middle, observes those SDL calls, reconstructs the meaning of the frame, and then re-renders the result into a terminal using the kitty graphics protocol via the `termscene` engine and related backend code.

So the inspector is not just looking at one renderer. It is visualizing a translation pipeline:

1. SDL-side commands and resources
2. Katzensteg interpretation / queueing / batching / fallback decisions
3. terminal-side uploads, image ids, placements, and output strategy

It interposes selected SDL 2D renderer APIs, captures semantic draw operations, and re-renders them into a terminal using the kitty graphics protocol via the `termscene` engine and related backend code.

The current system can:

- observe SDL renderer calls such as texture updates, render copies, clears, fills, and present
- preserve semantic information long enough to choose different output strategies
- choose between direct sprite-style output and framebuffer/composite fallback depending on unsupported blend modes and similar constraints
- upload images to kitty-compatible terminals using multiple transport strategies
- queue/replay intercepted SDL commands on a worker thread in some modes
- drop stale frame-local work in queued replay mode

### Why we need an inspector

This project now has enough moving parts that plain logs are no longer enough.

We need tooling to understand:

- why a frame used a given render strategy
- when/why fallback to framebuffer composition occurred
- which SDL textures were uploaded, copied, modulated, blended, or reused
- how SDL-side resources map to kitty-side image ids / placements / uploads
- where time and bandwidth are going
- what work happened on producer thread vs replay/worker vs render/present
- which commands/frames were skipped or dropped
- how different terminals and output modes behave

The intended inspector should help us make rendering and performance decisions, not just debug crashes.

---

## Intended audience

Primarily:

- engine/rendering developers
- performance/debugging developers
- contributors working on Katzensteg / termscene internals

Secondarily:

- future contributors who need to understand the runtime behavior quickly

This is a **developer tool**, not a user-facing polished consumer product.

---

## Core mental model

The UI should help users navigate these layers:

1. **SDL layer**
   - textures
   - renderer state
   - draw commands
   - frame boundaries (`SDL_RenderPresent`)

2. **Katzensteg interpretation layer**
   - queueing / replay mode
   - strategy choice
   - fallback reasons
   - frame-local vs persistent work

3. **Composition/render layer**
   - sprite path vs fullscreen composite vs tiled/strip composite
   - dirtying / batching / frame dropping
   - per-frame command counts and timings

4. **Kitty/terminal layer**
   - image uploads
   - image ids
   - placements
   - source rects / destination rects
   - transport mode
   - output bytes / command volume

5. **Cross-layer mapping**
   - what SDL texture/update/copy turned into what kitty image upload / placement sequence
   - how one selected visual region or resource propagates across layers

---

## Primary user workflows

The UI should support these workflows well.

### 1. Inspect a frame and explain it

A developer should be able to select a frame and answer:

- what commands were in this frame?
- did we use sprite mode or composite mode?
- if composite, why?
- how much work happened?
- what got uploaded/placed?
- what resources were touched?

### 2. Understand performance cost over time

A developer should be able to answer:

- when did queue depth spike?
- when were frames skipped or dropped?
- which frames were expensive?
- were uploads, placements, or composition the dominant cost?
- how did behavior differ between menu vs gameplay?

### 3. Trace SDL -> kitty mapping

A developer should be able to answer:

- which SDL texture corresponds to this kitty image or placement?
- did a texture update turn into a new upload?
- which copy operations forced fallback?
- how much reuse did we get vs churn?

### 4. Compare strategies and terminals

Eventually, a developer should be able to compare:

- fullscreen composite vs tiled_strip
- direct APC vs file_whole
- kitty vs Ghostty
- sync compose vs queued replay

Even if v1 does not implement side-by-side diff, the design should leave room for comparison workflows.

### 5. Tune configuration

The tool should leave room for configuration tweaking / live controls, even if the full backend/config protocol is not settled yet.

Examples:

- composite mode
- intercept mode
- output transport profile
- present FPS cap
- future render heuristics
- future batching/dirtying knobs

We do not know the final config surface yet, but the design should assume a future **Controls / Config** area exists.

---

## Important concepts the UI should make visible

### Sessions

A capture belongs to a runtime session with configuration and environment context.

Session-level context should include concepts like:

- terminal identity
- graphics capability results
- chosen output profile
- chosen composite mode
- chosen intercept mode
- whether capture was enabled
- runtime flags/settings snapshot

### Timeline / frames

Frames are the central navigation unit.

A frame is conceptually centered on an SDL `RenderPresent`, though queued replay / dropped work means not every upstream present necessarily becomes a fully realized terminal present.

We want timeline views for:

- present duration
- queue depth
- skipped presents
- dropped stale frames/batches
- upload bytes
- upload count
- placement count
- fallback mode markers
- maybe blend/fallback markers

### Resources

Resources include at least:

- SDL textures
- terminal image ids
- placements
- transport-side uploads

We want to inspect both the **SDL-side image data** and the **kitty-side result**, ideally with visual previews where possible.

This is important.

The UI should eventually make it easy to see:

- SDL texture contents / updates
- resulting uploaded kitty image contents
- mapping from one to the other
- source/destination rect usage
- whether a texture was reused, reuploaded, or transformed into a batch/strip/fullscreen composite

### Commands / events

Events are the fine-grained data layer under frames.

Important event classes include:

- SDL texture updates
- texture lock/unlock captures
- render copy / copy ex
- fill rects / lines / points
- render clear
- present
- queue enqueue/dequeue
- stale frame-local drops
- fallback decisions
- upload events
- placement events

### Render strategy

The tool should make render strategy obvious.

Current and likely modes include concepts like:

- sprite-ish scene output
- fullscreen composite
- tiled/strip composite
- future dirty-rect/tile-cache modes
- future scroll/motion-aware modes

### Fallback reasons

One especially valuable feature is explaining *why* a frame used a costlier path.

Examples:

- unsupported blend mode encountered
- destination-dependent operation requires composition
- terminal compatibility/transport constraints
- forced config override

---

## Data model to assume/plan for

This section describes the kinds of data the UI should be designed around.

Not all of this exists yet. Please treat it as the intended model.

### Session JSON shape (conceptual)

```json
{
  "session_id": "2026-04-23T21:17:09Z-92285",
  "terminal": {
    "identity": "ghostty",
    "graphics_basic": "supported",
    "file_whole": "supported",
    "file_offset": "unsupported"
  },
  "config": {
    "intercept_mode": "queued_replay",
    "composite_mode": "fullscreen",
    "output_profile": "file_whole",
    "present_fps": 0
  }
}
```

### Frame JSON shape (conceptual)

```json
{
  "id": 1842,
  "ts_ns": 1713900000123456789,
  "present_ns": 11234000,
  "queue_depth": 17,
  "skipped_presents": 42,
  "dropped_frame_batches": 3,
  "render_strategy": "fullscreen_composite",
  "fallback_reasons": [
    {
      "kind": "unsupported_blend_mode",
      "value": "add",
      "texture_key": "0x98f005b80"
    }
  ],
  "counts": {
    "copies": 46,
    "fills": 0,
    "lines": 0,
    "uploads": 1,
    "placements": 1
  },
  "bytes": {
    "uploaded": 2362368
  },
  "timing": {
    "producer_ns": 800000,
    "replay_ns": 300000,
    "compose_ns": 5200000,
    "emit_ns": 4100000
  }
}
```

### Resource JSON shape (conceptual)

```json
{
  "textures": [
    {
      "texture_key": "0x98f005b80",
      "size": [256, 224],
      "format": "ARGB8888",
      "blend_mode": "add",
      "color_mod": [255, 255, 255],
      "alpha_mod": 255,
      "last_updated_frame": 1842,
      "update_count": 812
    }
  ],
  "kitty_images": [
    {
      "image_id": 10423,
      "source": "composite_fullscreen",
      "size": [879, 672],
      "uploaded_frame": 1842,
      "transport": "file_whole"
    }
  ],
  "placements": [
    {
      "placement_id": 4401,
      "image_id": 10423,
      "src_rect": [0, 0, 879, 672],
      "dest_cells": [1, 1, 161, 48],
      "frame": 1842
    }
  ]
}
```

### Event JSON shape (conceptual)

```json
{
  "ts_ns": 1713900000123000000,
  "thread": "worker",
  "kind": "upload",
  "frame_id": 1842,
  "payload": {
    "image_id": 10423,
    "bytes": 2362368,
    "transport": "file_whole",
    "w": 879,
    "h": 672
  }
}
```

---

## UI areas we want designed

### 1. Global header / session bar

Should likely show:

- current session identity
- terminal / transport / strategy
- whether capture is on or off
- queue health summary
- quick controls for start/stop/clear capture
- eventually config/tweak entry point

### 2. Timeline view

This is important.

Think browser performance timeline / frame track style.

Useful tracks could include:

- frame duration track
- queue depth track
- upload bytes track
- upload count / placement count markers
- skipped/dropped frame markers
- strategy/fallback markers

Frame selection should be easy and central.

### 3. Frame detail panel

Selecting a frame should show:

- summary metrics
- strategy chosen
- fallback reasons
- counts and timings
- associated commands/events
- associated resources/uploads/placements

### 4. Resource inspector

This should make it possible to browse:

- SDL textures
- kitty images
- placements
- mappings between them

We especially want room for visual previews of:

- SDL-side image/texture data
- kitty-side uploaded image data
- maybe source/destination overlays later

### 5. SDL -> kitty mapping view

This is one of the most valuable views conceptually.

The UI should help answer:

- this SDL texture/copy/update became which kitty image(s)?
- which placements are using those image ids?
- did several SDL copies get batched into one strip/composite upload?

This can be a graph/table/drilldown hybrid.

### 6. Event / command log

A dense technical log view should exist.

Likely features:

- per-frame events
- filter by type
- filter by texture/resource id
- timestamps and durations
- ability to inspect payload details

### 7. Config / controls area

Even if not fully implemented yet, leave space in the design for a future controls panel.

Potential controls:

- capture start/stop/clear
- composite mode
- output profile
- present fps cap
- intercept mode
- future experimental flags

---

## Desired interactions

Please design with these interactions in mind:

- scrub/select frames from timeline
- click a frame to inspect it
- hover timeline items for quick summaries
- filter event/command/resource lists
- jump from resource -> frame(s) -> upload(s) -> placement(s)
- jump from frame -> fallback reason -> implicated resource
- inspect latest frame quickly during live refresh
- later: compare two frames or two sessions

---

## Visual/style guidance

### Desired feel

- dark theme
- technical
- high information density
- trustworthy and readable
- inspired by browser dev tools / perf tools
- not playful/cute
- not consumer-product glossy

### Good references in spirit

- Chrome DevTools Performance panel
- Chrome Network panel
- browser Layers/Rendering tools
- Perfetto / tracing UIs
- game engine frame debuggers

### Not the goal

- toy dashboard
- giant-card KPI homepage
- marketing-like charts without drilldown

---

## Constraints / implementation hints

### Current transport

Current first implementation is:

- inspector server inside Katzensteg
- HTTP over Unix domain socket
- optional proxy serving a web page
- curl-friendly endpoints

### Existing endpoint shape today

Current basic endpoints already exist or are planned in this shape:

- `/capture/start`
- `/capture/stop`
- `/capture/clear`
- `/capture/status`
- `/frames`
- `/frame/latest`
- `/resources`
- `/stats`

Please do not assume all rich data is already available; design for growth.

### Current captured data is minimal

Today we only have a small rolling frame capture including things like:

- frame id
- timestamp
- present duration
- queue depth
- skipped present count

The UI should still be designed for richer future data, not just this minimal slice.

---

## Most important future data to plan around

If the UI can gracefully grow into these, that is ideal.

### A. Timing breakdowns

Per frame and/or over time:

- producer/intercept thread time
- queueing overhead
- replay time
- composition time
- upload time
- placement emission time

### B. Resource previews

Eventually we want image preview support for:

- SDL texture contents
- composite buffers
- uploaded kitty images
- potentially tile strips and fullscreen composite snapshots

### C. Mapping / provenance

We want to answer provenance questions like:

- which SDL texture updates fed this kitty image?
- which SDL copies were represented by this composite frame?
- which tiles/strips were batched into this upload?

### D. Strategy diagnostics

We want explicit explanations like:

- frame used fullscreen composite because N copy ops used SDL_BLENDMODE_ADD
- frame used tiled_strip because config forced it
- frame used file_whole because terminal supports it and file_offset is avoided

---

## Suggested information hierarchy

If you need a hierarchy for design emphasis:

1. **Timeline / frame selection**
2. **Selected frame summary and explanation**
3. **Resource + SDL->kitty mapping**
4. **Raw events/commands**
5. **Configuration controls**

---

## Suggested first deliverables from design

What would be most useful from the design work:

1. overall app structure / IA
2. key screens or panels
3. timeline concept
4. selected-frame detail concept
5. resource/mapping concept
6. notes on how the UI should scale as richer data arrives
7. optional implementation-friendly component breakdown

---

## Notes for the designer

Please optimize for:

- clarity of technical cause/effect
- fast navigation between overview and detail
- helping diagnose correctness + performance together
- making SDL-side and kitty-side views feel connected

If there is one sentence to optimize for, it is:

> Help the developer understand what the frame meant, what Katzensteg chose to do with it, and what that cost.
