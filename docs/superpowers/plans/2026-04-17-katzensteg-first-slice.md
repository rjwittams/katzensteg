# Katzensteg First Slice Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first working Katzensteg slice: a preload library that interposes a minimal SDL2 renderer surface, opens `/dev/tty` directly, logs to a file, forwards all real SDL calls, and mirrors a small custom SDL2 test program into kitty output at `SDL_RenderPresent` using `termscene`.

**Architecture:** Katzensteg is implemented as a thin SDL interposition/runtime layer plus an SDL-aware frame builder. The frame builder accumulates `RenderClear` and `RenderCopy` state until `RenderPresent`, then translates that frame into stable `termscene` scene nodes and flushes through the kitty backend. The first slice uses direct tty mode only; helper handoff is deferred.

**Tech Stack:** Zig, SDL2 C ABI interposition via `dlsym(RTLD_NEXT)`, kitty graphics protocol, `termscene`, Unix `/dev/tty`, dynamic library build output.

---

## File Structure

### New files
- `tools/katzensteg/preload.zig` — shared library entrypoint and exported SDL2 interposition symbols for the first slice.
- `tools/katzensteg/runtime.zig` — process-global Katzensteg runtime state, direct tty init, teardown, log file setup, kitty/termscene ownership.
- `tools/katzensteg/sdl2.zig` — explicit SDL2 type and function declarations used by the preload library.
- `tools/katzensteg/real_sdl.zig` — `dlsym(RTLD_NEXT, ...)` resolution and typed wrappers for real SDL functions used in slice 1.
- `tools/katzensteg/frame_builder.zig` — SDL-aware per-frame state (`clear color`, render copies, texture bookkeeping) and translation into termscene scene submissions.
- `tools/katzensteg/log.zig` — file-based logging utility with first-occurrence suppression helpers.
- `tools/katzensteg/direct_tty.zig` — `/dev/tty` open, termios/raw mode, alt-screen and kitty keyboard mode lifecycle.
- `tools/katzensteg/test/basic_sdl_demo.zig` — tiny custom SDL2 test program that uses only the supported first-slice APIs.

### Existing files to modify
- `build.zig` — add build targets for `libkatzensteg.so` and the basic SDL2 demo executable; wire `termscene` as a module dependency for Katzensteg code.
- `README.md` — add current Katzensteg first-slice usage notes after implementation lands.
- `src/termscene/scene.zig` — only if the first slice reveals a genuinely generic scene-identity/submission gap.
- `src/termscene/kitty/backend.zig` — only if the first slice reveals a genuinely generic kitty backend need.

### Notes on boundaries
- Keep SDL-specific concepts out of `src/termscene/` unless they prove clearly generic.
- Keep exported SDL symbols only in `tools/katzensteg/preload.zig`.
- Keep `/dev/tty` and termios logic out of `preload.zig`; it belongs in `direct_tty.zig` and `runtime.zig`.
- Keep logging out of stdout/stderr entirely.

## Chunk 1: Build scaffolding and controlled test target

### Task 1: Add build targets for Katzensteg and the basic SDL test app

**Files:**
- Modify: `build.zig`
- Create: `tools/katzensteg/test/basic_sdl_demo.zig`

- [ ] **Step 1: Add a placeholder shared-library target to `build.zig`**

Add a `libkatzensteg.so` target rooted at `tools/katzensteg/preload.zig`.
Also add a `basic-sdl-demo` executable target rooted at `tools/katzensteg/test/basic_sdl_demo.zig`.
Wire the existing `termscene` module import into the library target.

- [ ] **Step 2: Create the basic SDL demo with a trivial `main` that returns immediately**

File: `tools/katzensteg/test/basic_sdl_demo.zig`

Use a tiny Zig executable stub first so build wiring can be verified before SDL details are added.

- [ ] **Step 3: Run the build to verify target wiring fails only on missing source/import details you expect**

Run: `zig build -Doptimize=Debug`

Expected: either success for scaffolding or narrow compile errors pointing at the new Katzensteg files.

- [ ] **Step 4: Commit scaffolding**

```bash
git add build.zig tools/katzensteg/test/basic_sdl_demo.zig
git commit -m "Add Katzensteg build scaffolding"
```

### Task 2: Turn the basic SDL demo into the first-slice reference app

**Files:**
- Modify: `tools/katzensteg/test/basic_sdl_demo.zig`

- [ ] **Step 1: Write the demo to use only supported first-slice SDL APIs**

The demo should do all of the following and nothing broader:
- create a visible SDL window
- create a renderer
- create one streaming/static texture via `SDL_CreateTexture`
- upload pixels via `SDL_UpdateTexture`
- clear each frame to a solid color
- copy the texture to a destination rect
- present in a simple loop for a few seconds
- avoid writing to stdout/stderr

- [ ] **Step 2: Build and run the demo without preload**

Run: `zig build basic-sdl-demo` or equivalent build step once added, then run the produced binary normally.

Expected: visible SDL window with animated or changing texture presentation.

- [ ] **Step 3: Commit the controlled SDL demo**

```bash
git add tools/katzensteg/test/basic_sdl_demo.zig build.zig
git commit -m "Add basic SDL demo for Katzensteg bring-up"
```

## Chunk 2: Direct tty runtime and logging foundation

### Task 3: Add file-based logging with no stdout/stderr usage

**Files:**
- Create: `tools/katzensteg/log.zig`
- Modify: `tools/katzensteg/preload.zig`
- Modify: `tools/katzensteg/runtime.zig`

- [ ] **Step 1: Define a simple logger API in `log.zig`**

The API should support:
- opening a log file lazily
- writing line-oriented messages
- `logOnce(key, message)`-style suppression for repeated unsupported-feature warnings

Keep it minimal for slice 1.

- [ ] **Step 2: Choose and document an initial log file location policy**

Use a simple path for now, such as a temp file under `/tmp` or `$TMPDIR`, with process id in the filename.
Do not overdesign configurability in slice 1.

- [ ] **Step 3: Wire runtime initialization errors and unsupported-feature logs through this logger**

No `stderr` or `stdout` writes should remain in Katzensteg code.

- [ ] **Step 4: Verify the SDL demo still runs with no terminal pollution from Katzensteg**

Expected: no Katzensteg text appears in the terminal via stdout/stderr; log file is created when needed.

- [ ] **Step 5: Commit logging foundation**

```bash
git add tools/katzensteg/log.zig tools/katzensteg/preload.zig tools/katzensteg/runtime.zig
git commit -m "Add file-based logging for Katzensteg"
```

### Task 4: Implement direct tty setup/teardown ownership in the library

**Files:**
- Create: `tools/katzensteg/direct_tty.zig`
- Create: `tools/katzensteg/runtime.zig`
- Modify: `tools/katzensteg/preload.zig`

- [ ] **Step 1: Define direct tty session state in `direct_tty.zig`**

Include:
- tty fd open/close
- saved termios
- raw mode application
- alt screen enable/disable
- kitty keyboard mode enable/disable
- best-effort teardown

- [ ] **Step 2: Add process-global runtime initialization in `runtime.zig`**

Responsibilities:
- lazy init on first meaningful interposed use
- open `/dev/tty`
- initialize direct tty session
- initialize logger
- initialize `termscene.SceneEngine`
- initialize `termscene.kitty.Backend`

- [ ] **Step 3: Add best-effort teardown hooks**

Use minimal, practical teardown for slice 1:
- `atexit` if appropriate
- destructor/finalizer approach if practical in Zig shared library context
- explicit runtime shutdown helper

Do not block the slice on perfect crash handling.

- [ ] **Step 4: Add a tiny non-SDL self-test path if needed during bring-up, then remove or keep private**

If a tiny internal direct-tty smoke helper is needed to validate raw mode/alt screen cleanup, keep it private to Katzensteg implementation and do not turn it into a public project target unless clearly useful.

- [ ] **Step 5: Verify teardown manually**

Manual test:
- preload library loads
- direct tty setup occurs
- process exits cleanly
- shell returns with sane echo/canonical mode restored

- [ ] **Step 6: Commit direct tty runtime**

```bash
git add tools/katzensteg/direct_tty.zig tools/katzensteg/runtime.zig tools/katzensteg/preload.zig
git commit -m "Add direct tty runtime for Katzensteg"
```

## Chunk 3: SDL interposition scaffold with forwarding intact

### Task 5: Declare the minimal SDL2 ABI surface explicitly

**Files:**
- Create: `tools/katzensteg/sdl2.zig`

- [ ] **Step 1: Declare the exact SDL types needed for slice 1**

Include only the minimum required:
- opaque structs for `SDL_Window`, `SDL_Renderer`, `SDL_Texture`
- rect and pixel-format related structs/constants needed by the demo path
- function signatures for the intercepted first-slice API surface

Avoid `translate-c`.

- [ ] **Step 2: Build to verify ABI declarations are accepted by Zig**

Run: `zig build -Doptimize=Debug`

Expected: compile errors, if any, should now move to unresolved implementation references rather than missing SDL declarations.

- [ ] **Step 3: Commit SDL declarations**

```bash
git add tools/katzensteg/sdl2.zig
git commit -m "Add minimal SDL2 ABI declarations for Katzensteg"
```

### Task 6: Resolve real SDL symbols via `dlsym(RTLD_NEXT, ...)`

**Files:**
- Create: `tools/katzensteg/real_sdl.zig`
- Modify: `tools/katzensteg/preload.zig`

- [ ] **Step 1: Add typed real-SDL symbol loading wrappers in `real_sdl.zig`**

Implement lazy symbol resolution for the slice-1 functions:
- `SDL_CreateWindow`
- `SDL_CreateRenderer`
- `SDL_CreateTexture`
- `SDL_UpdateTexture`
- `SDL_RenderClear`
- `SDL_RenderCopy`
- `SDL_RenderPresent`

- [ ] **Step 2: Export matching C ABI symbols from `preload.zig` that only forward**

At this stage, every interposed function should:
- initialize runtime if needed
- call the real SDL symbol
- return the real result unchanged

No terminal rendering side effects yet.

- [ ] **Step 3: Verify preload forwarding against the basic SDL demo**

Run the demo under preload with the shared library preloaded.

Expected:
- demo behaves normally in the real SDL window
- no crashes from interposition
- runtime/log initialization is stable

- [ ] **Step 4: Commit forwarding-only interposition scaffold**

```bash
git add tools/katzensteg/preload.zig tools/katzensteg/real_sdl.zig
git commit -m "Add SDL forwarding interposition scaffold for Katzensteg"
```

## Chunk 4: Texture bookkeeping and SDL-aware frame builder

### Task 7: Add texture bookkeeping for explicit upload textures

**Files:**
- Create: `tools/katzensteg/frame_builder.zig`
- Modify: `tools/katzensteg/runtime.zig`
- Modify: `tools/katzensteg/preload.zig`

- [ ] **Step 1: Define Katzensteg texture records in `frame_builder.zig`**

Each texture record should minimally hold:
- SDL texture pointer identity
- texture dimensions and format metadata needed for upload/use
- kitty image id
- upload status

- [ ] **Step 2: Record textures created through `SDL_CreateTexture`**

Interposed `SDL_CreateTexture` should still forward first, then register bookkeeping if creation succeeded.

- [ ] **Step 3: Implement `SDL_UpdateTexture` side effects**

After forwarding successfully, update Katzensteg’s texture record and ensure kitty image upload/registration is performed using the direct tty runtime backend.

Assume whole-texture updates are enough for slice 1 if the custom demo is written accordingly.

- [ ] **Step 4: Verify texture upload bookkeeping with the custom SDL demo**

Expected:
- no crashes
- texture records exist
- kitty image registrations occur
- real SDL window still behaves correctly

- [ ] **Step 5: Commit explicit upload texture bookkeeping**

```bash
git add tools/katzensteg/frame_builder.zig tools/katzensteg/runtime.zig tools/katzensteg/preload.zig
git commit -m "Track SDL textures and kitty image uploads in Katzensteg"
```

### Task 8: Record pending frame state from `RenderClear` and `RenderCopy`

**Files:**
- Modify: `tools/katzensteg/frame_builder.zig`
- Modify: `tools/katzensteg/preload.zig`

- [ ] **Step 1: Add frame state fields for clear color and render-copy list**

The frame-builder should minimally track:
- whether a clear happened this frame
- current clear color
- ordered list of render-copy ops

- [ ] **Step 2: Implement `SDL_RenderClear` side effects as frame-state mutation only**

Do not emit terminal operations here.
Record the frame’s clear color/background intent.

- [ ] **Step 3: Implement `SDL_RenderCopy` side effects as recorded draw ops only**

Record:
- texture reference
- source rect
- destination rect
- draw order index

Do not emit terminal operations here.

- [ ] **Step 4: Verify frame accumulation under the custom SDL demo**

Expected:
- clear color recorded each frame
- render-copy list populated each frame
- real SDL output unchanged

- [ ] **Step 5: Commit frame accumulation logic**

```bash
git add tools/katzensteg/frame_builder.zig tools/katzensteg/preload.zig
 git commit -m "Record SDL frame state for Katzensteg present-time translation"
```

## Chunk 5: Present-time translation into termscene

### Task 9: Translate the pending frame into stable termscene scene nodes

**Files:**
- Modify: `tools/katzensteg/frame_builder.zig`
- Modify: `tools/katzensteg/runtime.zig`
- Modify: `src/termscene/scene.zig` (only if a clearly generic gap appears)

- [ ] **Step 1: Define stable `NodeKey` strategy for Katzensteg scene submission**

Use stable identities for:
- one background node
- ordered render-copy nodes by frame slot index for the first slice

Keep the first-slice policy simple and documented in code comments.

- [ ] **Step 2: Implement frame-to-scene submission**

At present time:
- begin a fresh scene submission
- submit a background node representing the clear color
- submit one sprite node per recorded render copy

Use `termscene.SceneEngine` directly.

- [ ] **Step 3: Only extend `termscene` if a generic missing feature is proven**

Examples of acceptable generic extensions:
- cleaner APIs for stable identity submission
- generic background/solid sprite convenience if broadly useful

Do not add SDL-specific concepts to `termscene`.

- [ ] **Step 4: Verify scene submission shape without relying on perfect visual output yet**

Expected:
- no duplicate-key failures in normal frame submission
- stable node identities across frames
- scene diff executes each present

- [ ] **Step 5: Commit present-time scene translation**

```bash
git add tools/katzensteg/frame_builder.zig tools/katzensteg/runtime.zig src/termscene/scene.zig src/termscene/kitty/backend.zig
 git commit -m "Translate Katzensteg frames into termscene scene nodes"
```

### Task 10: Flush kitty updates from `SDL_RenderPresent`

**Files:**
- Modify: `tools/katzensteg/preload.zig`
- Modify: `tools/katzensteg/runtime.zig`

- [ ] **Step 1: Implement `SDL_RenderPresent` as the first true "forward + terminal side effect" anchor**

Sequence:
- translate current frame to scene nodes
- diff via `termscene.SceneEngine`
- apply sprite ops through `termscene.kitty.Backend`
- commit scene state
- clear temporary frame-builder draw-op state
- forward to real SDL present

- [ ] **Step 2: Verify the terminal now mirrors the custom SDL demo in direct mode**

Expected:
- visible SDL window still works
- terminal shows corresponding kitty-rendered content
- repeated presents update retained scene rather than rebuilding terminal state blindly

- [ ] **Step 3: Manually verify `SDL_RenderClear` semantics**

Expected:
- changed clear color changes the background scene element
- terminal output follows the frame model rather than using immediate terminal clears

- [ ] **Step 4: Commit present-time terminal emission**

```bash
git add tools/katzensteg/preload.zig tools/katzensteg/runtime.zig tools/katzensteg/frame_builder.zig
 git commit -m "Flush Katzensteg frames to kitty at SDL_RenderPresent"
```

## Chunk 6: Validation, docs, and handoff readiness

### Task 11: Add conservative unsupported-feature handling

**Files:**
- Modify: `tools/katzensteg/preload.zig`
- Modify: `tools/katzensteg/log.zig`

- [ ] **Step 1: Add log-once handling for unsupported or out-of-scope SDL features encountered in the slice**

Examples:
- unexpected texture creation path
- partial update assumptions violated
- non-default render target if observed

- [ ] **Step 2: Verify unsupported cases fail soft**

Expected:
- real SDL behavior continues
- terminal rendering may degrade or disable
- no stdout/stderr pollution

- [ ] **Step 3: Commit unsupported-feature fail-soft handling**

```bash
git add tools/katzensteg/preload.zig tools/katzensteg/log.zig
 git commit -m "Add fail-soft unsupported feature handling to Katzensteg"
```

### Task 12: Document how to run the first slice

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a short Katzensteg bootstrap section to the README**

Document:
- what the first slice supports
- that it uses direct tty mode only
- that logs go to a file
- how to build and run the custom SDL demo under preload
- that the real SDL window remains visible intentionally in slice 1

- [ ] **Step 2: Build and re-run the documented commands exactly**

Expected: commands in README are accurate and reproducible.

- [ ] **Step 3: Commit README updates**

```bash
git add README.md
 git commit -m "Document Katzensteg first-slice bootstrap flow"
```

### Task 13: Final verification checkpoint for the first slice

**Files:**
- Modify only as needed based on verification findings

- [ ] **Step 1: Run full first-slice verification**

Checklist:
- build succeeds
- custom SDL demo runs normally without preload
- custom SDL demo runs under preload
- real SDL window remains correct
- terminal mirrors the demo through kitty
- teardown returns shell to sane state
- Katzensteg logs only to file

- [ ] **Step 2: Fix any final first-slice issues minimally**

Keep fixes within slice-1 scope. Do not expand feature coverage.

- [ ] **Step 3: Commit the first-slice completion checkpoint**

```bash
git add build.zig README.md tools/katzensteg src/termscene
git commit -m "Complete Katzensteg first slice with direct tty SDL mirroring"
```
