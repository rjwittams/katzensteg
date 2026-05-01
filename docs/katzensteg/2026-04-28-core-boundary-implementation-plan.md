# Katzensteg Core Boundary Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents are explicitly requested and available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the current SDL2 preload/runtime artifact into a thin SDL2 adapter plus a shared Katzensteg core while preserving current payload-copy and conversion timing.

**Architecture:** Add Katzensteg-owned core boundary types, move runtime-facing command state off SDL2 ABI types, then introduce `libkatzensteg-core` and `libkatzensteg-sdl2`. Keep SDL-style renderer replay in core, but express it with core handles, rects, formats, and blend modes.

**Tech Stack:** Zig 0.15.2, C interposer shims, SDL2, Vulkan loader layer, existing Python unittest scripts, file-level Zig tests.

**Status 2026-04-30:** Implemented on branch `adapter-split`. The core now builds as `libkatzensteg-core`, the SDL2 interposer builds as `libkatzensteg-sdl2`, profiles point at the SDL2 adapter preload, and the Vulkan layer resolves external framebuffer presentation through the core ABI with `KATZENSTEG_CORE_LIB` available for runtime loading.

---

## Files

- Create: `src/katzensteg/core_types.zig`
  Core handle/value/format/blend definitions and constructors.
- Create: `src/katzensteg/sdl2_adapter.zig`
  SDL2-to-core mapping helpers for handles, rects, points, formats, blend modes, and event/window constants.
- Create: `src/katzensteg/core_exports.zig`
  Exported core ABI entry points such as shutdown and external framebuffer presentation.
- Modify: `src/katzensteg/intercept_sink.zig`
  Convert command union and queued ownership helpers from SDL2 types to core types.
- Modify: `src/katzensteg/frame_builder.zig`
  Replace SDL2 structs/constants in retained renderer state with core types while preserving existing composition behavior.
- Modify: `src/katzensteg/runtime.zig`
  Remove SDL2 ABI imports from core runtime state. Move SDL event ABI fill/read behavior to adapter side or an adapter-facing helper.
- Modify: `src/katzensteg/preload.zig`
  Make this the SDL2 adapter implementation that maps SDL2 calls to core commands.
- Modify: `src/katzensteg/real_sdl.zig`
  Keep adapter-only real dispatch helpers.
- Modify: `src/katzensteg/interpose_linux.c`, `src/katzensteg/interpose_macos.c`
  Keep SDL2 interpose exports in the SDL2 adapter library.
- Modify: `src/katzensteg/katzensteg_linux.map`
  Split export maps or restrict exports per library.
- Modify: `src/katzensteg/vulkan_layer.c`
  Resolve core external framebuffer entry points from `libkatzensteg-core`.
- Modify: `build.zig`
  Build `libkatzensteg-core`, `libkatzensteg-sdl2`, and compatibility artifacts as needed.
- Modify: `profiles/*.json`
  Point `adapter.sdl2_preload` fragments at `libkatzensteg-sdl2`.
- Modify: `scripts/katzensteg/test_linux_preload_exports.py`
  Verify SDL2 adapter/core export separation.

## Chunk 1: Core Boundary Types

### Task 1: Add core type definitions

- [x] **Step 1: Write compile-time tests for core formats and optional provenance**

Add tests in `src/katzensteg/core_types.zig` covering:

- Known semantic pixel format construction.
- Unknown semantic pixel format with retained producer token.
- Blend semantic construction.
- Producer-token storage behind a compile-time constant or default constructor.

Run:

```bash
zig test src/katzensteg/core_types.zig
```

Expected initially: FAIL because the file or symbols do not exist.

- [x] **Step 2: Implement `core_types.zig`**

Define:

- `pub const CoreHandle = usize`
- `pub const CoreRect = extern struct { x: i32, y: i32, w: i32, h: i32 }`
- `pub const CorePoint = extern struct { x: i32, y: i32 }`
- `pub const CoreColor = extern struct { r: u8, g: u8, b: u8, a: u8 }`
- `pub const ProducerApi = enum { sdl2, sdl3, gl, vulkan, external }`
- `pub const PixelSemanticFormat = enum { rgba8, bgra8, xrgb8888, argb8888, rgb565, rgba4444, i420, yv12, nv12, nv21, a2b10g10r10_unorm_pack32, unknown }`
- `pub const ProducerFormatToken = union(enum) { sdl2: u32, sdl3: u32, vulkan: u32, gl: struct { format: u32, type: u32 } }`
- `pub const BlendSemanticMode = enum { none, blend, add, mod, mul, unknown }`
- `pub const ProducerBlendToken = union(enum) { sdl2: i32, sdl3: u32 }`

Add constructors such as `pixelFormat(semantic, source)` and `blendMode(semantic, source)` so call sites do not depend on whether provenance is stored.

- [x] **Step 3: Run core type tests**

Run:

```bash
zig test src/katzensteg/core_types.zig
```

Expected: PASS.

- [x] **Step 4: Commit**

```bash
git add src/katzensteg/core_types.zig
git commit -m "Add Katzensteg core boundary types"
```

## Chunk 2: SDL2 Mapping Helpers

### Task 2: Add SDL2-to-core mapping helpers

- [x] **Step 1: Write tests for SDL2 mappings**

Create tests in `src/katzensteg/sdl2_adapter.zig` for:

- Pointer-to-handle mapping using integer value.
- `SDL_Rect` to `CoreRect`.
- Known SDL2 pixel formats to semantic pixel formats with source token.
- Unknown SDL2 pixel format to `unknown` with source token.
- Known SDL2 blend modes to semantic blend modes.

Run:

```bash
zig test --dep katzensteg_sdl -Mroot=src/katzensteg/sdl2_adapter.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig -lc
```

Expected initially: FAIL because helpers do not exist.

- [x] **Step 2: Implement mapping helpers**

Add helpers:

- `handleFromPtr(ptr: anytype) CoreHandle`
- `rectFromSdl(rect: ?*const sdl.SDL_Rect) ?core.CoreRect`
- `pointFromSdl(point: ?*const sdl.SDL_Point) ?core.CorePoint`
- `pixelFormatFromSdl2(format: u32) core.PixelFormat`
- `blendModeFromSdl2(mode: i32) core.BlendMode`
- `handleToPtr` helpers only where adapter code still needs to call real SDL.

Keep this file adapter-side: it may import `katzensteg_sdl` and `real_sdl`.

- [x] **Step 3: Run SDL2 mapping tests**

Run:

```bash
zig test --dep katzensteg_sdl -Mroot=src/katzensteg/sdl2_adapter.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig -lc
```

Expected: PASS.

- [x] **Step 4: Commit**

```bash
git add src/katzensteg/sdl2_adapter.zig
git commit -m "Add SDL2 adapter mapping helpers"
```

## Chunk 3: Command Boundary Without SDL2 ABI Types

### Task 3: Convert intercept commands to core types

- [x] **Step 1: Add/adjust tests around command cloning**

In `src/katzensteg/intercept_sink.zig`, add tests or update existing tests to verify queued command cloning still owns payload bytes for:

- `update_texture`
- `update_yuv_texture`
- `update_nv_texture`
- `external_framebuffer_present`

Run the targeted file test:

```bash
zig test --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/intercept_sink.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig -lc -lSDL2
```

Expected initially: FAIL once command fields are changed but call sites are not updated.

- [x] **Step 2: Replace `Command` SDL2 field types**

Convert command fields:

- SDL pointers become `core.CoreHandle`.
- `sdl.SDL_Rect` becomes `core.CoreRect`.
- `sdl.SDL_Point` becomes `core.CorePoint`.
- Texture formats become `core.PixelFormat`.
- Blend modes become `core.BlendMode`.

Keep payload buffers as byte slices and plane slices; do not introduce conversions.

- [x] **Step 3: Remove `real_sdl` sizing from generic clone paths where possible**

For update commands that currently call `SDL_QueryTexture` to infer byte counts, prefer dimensions already recorded in core texture state. If a size still cannot be known without SDL2, keep that query in the SDL2 adapter before emitting the command. Do not let `intercept_sink.zig` import `real_sdl`.

- [x] **Step 4: Update adapter call sites in `preload.zig`**

Map SDL2 ABI values to core types before calling `intercept_sink`.

- [x] **Step 5: Run targeted tests**

Run:

```bash
zig test --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/intercept_sink.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig -lc -lSDL2
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add src/katzensteg/intercept_sink.zig src/katzensteg/preload.zig
git commit -m "Move intercept commands to core-owned types"
```

## Chunk 4: Frame Builder Core Types

### Task 4: Remove SDL2 structs/constants from frame builder state

- [x] **Step 1: Run existing frame builder tests**

Run:

```bash
zig test --dep termscene -Mroot=src/katzensteg/frame_builder.zig -Mtermscene=src/termscene/mod.zig -lc
```

Expected before edits: PASS or record current failures.

- [x] **Step 2: Convert retained state types**

In `src/katzensteg/frame_builder.zig`:

- Replace retained `sdl.SDL_Rect` with `core.CoreRect`.
- Replace renderer/window/texture pointer keys with `core.CoreHandle`.
- Replace pixel format integers with `core.PixelFormat`.
- Replace blend mode integers with `core.BlendMode`.

Preserve existing conversion behavior:

- Texture bytes are converted only where current code already converts.
- External framebuffer conversion remains in `presentExternalFramebuffer`.
- `SDL_CreateTextureFromSurface` behavior stays as-is for this pass.

- [x] **Step 3: Update composition helpers**

Update helper functions that perform rectangle math and blend-mode decisions to use semantic core values. Keep the fast paths equivalent.

- [x] **Step 4: Run frame builder tests**

Run:

```bash
zig test --dep termscene -Mroot=src/katzensteg/frame_builder.zig -Mtermscene=src/termscene/mod.zig -lc
```

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add src/katzensteg/frame_builder.zig
git commit -m "Use core types in frame builder"
```

## Chunk 5: Runtime/Core Export Split

### Task 5: Move core exports and remove SDL2 imports from runtime core

- [x] **Step 1: Add a no-SDL-import check**

Create or update a script/test that fails if these files import `katzensteg_sdl` or `real_sdl`:

- `src/katzensteg/runtime.zig`
- `src/katzensteg/intercept_sink.zig`
- `src/katzensteg/frame_builder.zig`
- `src/katzensteg/core_exports.zig`

Run:

```bash
python3 -m unittest scripts/katzensteg/test_linux_preload_exports.py
```

Expected initially: FAIL until imports are removed or the check is added with current failures.

- [x] **Step 2: Create `core_exports.zig`**

Move core ABI exports from `preload.zig` where they are not SDL2-specific:

- `ks_katzensteg_shutdown`
- `ks_katzensteg_present_external_rgba`
- `ks_katzensteg_present_external_framebuffer`

Keep names stable for Vulkan layer compatibility.

- [x] **Step 3: Move SDL event ABI handling to adapter side**

Keep `SDL_PollEvent`, `SDL_PeepEvents`, `SDL_GetKeyboardState`, `SDL_GetMouseState`, and related ABI fill logic in `preload.zig` or an adapter-owned helper. Runtime should expose adapter-neutral input events/state, not SDL event structs.

- [x] **Step 4: Run the no-SDL-import check**

Run:

```bash
python3 -m unittest scripts/katzensteg/test_linux_preload_exports.py
```

Expected: PASS for the import boundary checks.

- [x] **Step 5: Commit**

```bash
git add src/katzensteg/runtime.zig src/katzensteg/core_exports.zig src/katzensteg/preload.zig scripts/katzensteg/test_linux_preload_exports.py
git commit -m "Separate core exports from SDL2 adapter"
```

## Chunk 6: Build And Profile Split

### Task 6: Build separate core and SDL2 adapter libraries

- [x] **Step 1: Update build artifacts**

In `build.zig`:

- Add dynamic library `katzensteg-core`.
- Add dynamic library `katzensteg-sdl2`.
- Link `katzensteg-sdl2` against `katzensteg-core`.
- Keep platform-specific C sources with the adapter unless they are core-only.
- Keep LLVM codegen behavior on Linux unchanged.
- Keep compatibility artifacts only if needed by existing profiles during transition.

- [x] **Step 2: Split Linux export maps**

Create separate export-map behavior:

- Core exports only `ks_katzensteg_*` core ABI symbols needed by adapters/layers.
- SDL2 adapter exports `SDL_*`, `dlopen` where needed, and any adapter-local `ks_SDL_*` bridge symbols hidden or local as appropriate.

- [x] **Step 3: Update profiles**

Change `adapter.sdl2_preload` profile fragments to point at:

- Linux: `{repo}/zig-out/lib/libkatzensteg-sdl2.so`
- macOS: `{repo}/zig-out/lib/libkatzensteg-sdl2.dylib`

- [x] **Step 4: Build**

Run:

```bash
zig build -Doptimize=Debug
```

Expected: PASS.

- [x] **Step 5: Run export tests**

Run:

```bash
python3 -m unittest scripts/katzensteg/test_linux_preload_exports.py
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add build.zig src/katzensteg/katzensteg_linux.map profiles scripts/katzensteg/test_linux_preload_exports.py
git commit -m "Build separate Katzensteg core and SDL2 adapter"
```

## Chunk 7: Vulkan Layer Rewire

### Task 7: Resolve external framebuffer presentation from core

- [x] **Step 1: Update Vulkan layer lookup**

In `src/katzensteg/vulkan_layer.c`, make lookup target the core ABI contract. Prefer `RTLD_DEFAULT` if the launcher ensures core is loaded, or explicitly document/load `libkatzensteg-core` if needed by the platform.

- [x] **Step 2: Verify frame format preservation**

Ensure `ExternalFramebufferFormat` or its replacement core type still carries:

- RGBA8
- BGRA8
- A2B10G10R10_UNORM_PACK32

Do not convert in the Vulkan layer.

- [x] **Step 3: Build with Vulkan enabled**

Run:

```bash
zig build -Doptimize=Debug
```

Expected: PASS.

- [x] **Step 4: Dry-run Vulkan profile**

Run:

```bash
./zig-out/bin/katzensteg --dry-run probe.vulkan
```

Expected: environment includes SDL2 adapter preload plus Vulkan layer variables, with core available through the adapter dependency or explicit load path.

- [x] **Step 5: Commit**

```bash
git add src/katzensteg/vulkan_layer.c src/katzensteg/frame_builder.zig src/katzensteg/core_types.zig
git commit -m "Route Vulkan framebuffer presentation through core"
```

## Chunk 8: End-To-End Verification

### Task 8: Verify behavior and copy/conversion boundaries

- [x] **Step 1: Run full build**

Run:

```bash
zig build -Doptimize=Debug
```

Expected: PASS.

- [x] **Step 2: Run Python checks**

Run:

```bash
python3 -m unittest discover -s scripts/katzensteg -p 'test_*.py'
```

Expected: PASS.

- [x] **Step 3: Run focused Zig file tests**

Run:

```bash
zig test src/katzensteg/core_types.zig
zig test --dep katzensteg_sdl -Mroot=src/katzensteg/sdl2_adapter.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig -lc
zig test --dep termscene -Mroot=src/katzensteg/frame_builder.zig -Mtermscene=src/termscene/mod.zig -lc
zig test --dep termscene --dep katzensteg_sdl -Mroot=src/katzensteg/intercept_sink.zig -Mtermscene=src/termscene/mod.zig -Mkatzensteg_sdl=src/katzensteg/sdl2.zig -lc -lSDL2
```

Expected: PASS.

- [x] **Step 4: Dry-run representative profiles**

Run:

```bash
./zig-out/bin/katzensteg --dry-run probe.input
./zig-out/bin/katzensteg --dry-run probe.vulkan
./zig-out/bin/katzensteg --dry-run sonic
```

Expected: preload paths point to `libkatzensteg-sdl2`; Vulkan profiles include Vulkan layer variables.

- [x] **Step 5: Audit copy/conversion sites**

Run:

```bash
rg -n "alloc\\(|acquirePayloadBuffer|@memcpy|ConvertSurfaceFormat|ToRgba|presentExternalFramebuffer|enqueue" src/katzensteg
```

Expected: no new adapter-ingress conversion buffer; expected payload ownership copies are documented in the design.

Observed 2026-04-30: copy sites are still the expected queued payload ownership paths, frame-builder texture/external-framebuffer conversion and composition storage, GL capture buffers, and input/launcher metadata copies. `SDL_CreateTextureFromSurface` still uses the existing SDL conversion path and remains a separate profiling task.

- [x] **Step 6: Commit final docs updates**

```bash
git add docs/katzensteg/2026-04-28-core-boundary-design.md docs/katzensteg/2026-04-28-core-boundary-implementation-plan.md
git commit -m "Document Katzensteg core boundary split plan"
```

## Execution Notes

- Keep `SDL_CreateTextureFromSurface` behavior unchanged in this pass.
- Keep GL capture SDL-window-driven in the SDL2 adapter.
- Do not introduce SDL3 symbols or profiles in this pass.
- Do not move image conversion earlier to simplify the boundary.
- Do not replace pointer-value handles with a table unless a correctness issue requires it.
- If a new pixel copy is introduced, stop and document why it is unavoidable before continuing.
