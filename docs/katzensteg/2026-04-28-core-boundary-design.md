# Katzensteg Core Boundary Design

## Goal

Split Katzensteg's preload-side implementation into an SDL2 adapter and a shared core without lowering producer fidelity, adding avoidable pixel copies, or forcing earlier image conversion.

The split should make the boundary provable: SDL2 ABI bindings and real SDL dispatch belong in the SDL2 adapter; runtime state, frame composition, terminal presentation, payload ownership, logging, diagnostics, and external framebuffer presentation belong in the core.

Status as of 2026-04-30: this boundary is implemented for the current SDL2 and Vulkan paths. The core artifact is `libkatzensteg-core`, the SDL2 interposer artifact is `libkatzensteg-sdl2`, and bundled profiles now preload the SDL2 adapter. The Vulkan layer can resolve the core external-framebuffer ABI through `RTLD_DEFAULT`, an explicit `KATZENSTEG_CORE_LIB`, or a core library next to the layer.

## Boundary

The core should be adapter-ABI neutral, not a lowest-common-denominator graphics model. It may contain producer-shaped subsystems such as SDL-style renderer replay, SDL-window-driven GL presentation state, Vulkan/external framebuffer presentation, input routing, image conversion, and future GPU-facing paths.

The core should not import SDL2/SDL3 ABI bindings, call SDL real-dispatch helpers, or retain live foreign pointers as semantic state. Adapters translate foreign API observations into Katzensteg-owned handles, values, and commands.

Initial library shape:

```text
libkatzensteg-core
  runtime singleton, config, logging sink, frame builder,
  payload pool, terminal backend, input routing state,
  diagnostics, external framebuffer presentation ABI

libkatzensteg-sdl2
  SDL2 interpose exports, SDL2 real dispatch, SDL2 event ABI,
  SDL2 object/value mapping, SDL-window-driven GL capture trigger

libkatzensteg-vulkan-layer
  Vulkan layer entry points and presented-frame capture,
  calling the core external framebuffer ABI
```

`libkatzensteg-sdl2` can depend on `libkatzensteg-core`. The Vulkan layer should call core entry points directly and should not require the SDL2 adapter unless a launch profile intentionally combines both.

On macOS and other plugin-style hosts, profiles should set `KATZENSTEG_CORE_LIB` when the Vulkan layer may be loaded without the SDL2 adapter already bringing the core into the process. This keeps runtime loading explicit for Python, Lua, Love2D, and similar embedding scenarios.

## Core Types

Core commands use Katzensteg-owned types:

- `CoreHandle`: an opaque integer identity for windows, renderers, textures, and future producer objects.
- `CoreRect`, `CorePoint`, `CoreColor`: small value types copied from producer ABI structs.
- `ProducerApi`: source family such as SDL2, SDL3, GL, Vulkan, or external.
- `PixelFormat`: semantic-first pixel format description with optional producer provenance.
- `BlendMode`: semantic-first blend mode description with optional producer provenance.
- Renderer replay commands that remain SDL-renderer-shaped where that is the real producer model.

For the first pass, adapters can map foreign object pointers to `CoreHandle` using pointer integer value. This avoids a new table lookup on hot paths while removing foreign pointer types from core state. A real handle table can be added later behind the same type if stable non-pointer identities become necessary.

## Pixel Formats And Blend Modes

Pixel formats should use a common semantic description where Katzensteg understands the bytes. Examples:

- `rgba8`
- `bgra8`
- `xrgb8888`
- `argb8888`
- `rgb565`
- `rgba4444`
- `i420`
- `yv12`
- `nv12`
- `nv21`
- `a2b10g10r10_unorm_pack32`
- `unknown`

Adapters map known SDL2, SDL3, Vulkan, or GL constants into this semantic model. They may also attach an optional producer token such as `sdl2(u32)`, `sdl3(u32)`, `vulkan(u32)`, or `gl(format,type)`.

The producer token is provenance, not the primary rendering key unless the semantic value is `unknown`. It is useful for logs, inspector metadata, unsupported-format diagnostics, and future mapping work. A later build option can compile producer tokens out for lean builds; call sites should use constructors so the storage layout can change at comptime without spreading conditionals.

Blend modes follow the same pattern: common semantic modes such as `none`, `blend`, `add`, `mod`, `mul`, and `unknown`, plus optional raw producer token.

This model enables fast-path selection without implying conversion timing. The semantic format describes the bytes; conversion still happens only when a concrete present or composition path needs it.

## Hot-Path Data Flow

The SDL2 adapter performs ABI translation and lifetime protection only:

1. Receive an SDL2 call through the interposed ABI.
2. Call through to real SDL2 where current behavior requires it.
3. Map pointer identities to `CoreHandle`.
4. Map small structs and constants to core value types.
5. Preserve format, blend, pitch, layout, dimensions, and ownership metadata.
6. Emit a core command.

Payload-bearing commands must not gain new avoidable copies:

- `SDL_UpdateTexture`: preserve bytes and pitch. Copy only when queued replay needs ownership beyond the SDL call lifetime, as today.
- `SDL_UpdateYUVTexture` and `SDL_UpdateNVTexture`: preserve planes, pitches, dimensions, and semantic format. Do not collapse to RGBA at adapter ingress.
- `SDL_LockTexture` and `SDL_UnlockTexture`: keep the existing queued replay copy behavior and do not add another boundary copy.
- `SDL_RenderCopy`, `SDL_RenderCopyEx`, and `SDL_RenderGeometryRaw`: keep structural renderer commands. Do not rasterize early.
- External framebuffer presentation: Vulkan and GL paths pass format plus bytes to core; conversion remains in the present/composition path after frame-dropping decisions.

Metadata can be copied by value freely. Pixel payloads should only be copied when the existing lifetime model already required Katzensteg to own them.

## SDL_CreateTextureFromSurface

`SDL_CreateTextureFromSurface` is intentionally out of scope for the boundary pass. The current implementation asks SDL to convert the surface to `ABGR8888` before recording it. That is not full producer-fidelity, but changing it mixes the ABI split with a separate performance project.

Later, handle this as a profiling-heavy fast-path round:

- Measure with Instruments/perf on targets that exercise surface uploads.
- Compare SDL conversion cost against terminal upload and composition cost.
- Add native or libyuv equivalents only where profiling shows benefit.
- Preserve original surface format, pitch, and pixels only after lifetime and copy costs are understood.
- Watch for regressions where avoiding SDL conversion exposes slower Katzensteg conversion, worse cache behavior, or extra copies.

## GL And Vulkan

GL stays under the SDL2 adapter in the first split because the current GL path is SDL-window-driven: capture is triggered around `SDL_GL_SwapWindow`, uses SDL drawable sizing, and then publishes a captured framebuffer to core. A separate GL/EGL/GLX adapter should wait until there is a non-SDL GL producer.

Vulkan is already naturally separate through the loader's implicit layer mechanism. Its boundary should become direct use of the core external framebuffer ABI, not an implicit dependency on the SDL2 preload artifact.

## Performance Proof

The split is acceptable only if it preserves the current conversion and copy timing.

Proof points:

- Add a build/static check that core modules do not import `katzensteg_sdl` or `real_sdl`.
- Add focused tests for SDL2 format mapping, blend mapping, unknown-token preservation, and optional producer-token construction.
- Add focused tests for command cloning/ownership around queued texture updates and external framebuffer enqueue.
- Review copy sites before and after. Expected pixel-copy sites remain queued texture updates, queued YUV/NV plane capture, queued lock/unlock capture, and external framebuffer enqueue.
- Confirm sync paths do not gain adapter-to-core pixel-copy buffers.

Current verification also runs the full `scripts/katzensteg` unittest discovery. The macOS test path treats Vulkan headers and Linux libyuv as platform/dependency-gated checks so the suite still proves the Linux fast paths where they apply without failing unrelated Darwin runs.

## Non-Goals

- Do not add SDL3 support in the same pass.
- Do not redesign `SDL_CreateTextureFromSurface` fidelity or performance in the same pass.
- Do not split direct GL/EGL/GLX support before there is a non-SDL GL producer.
- Do not normalize producer data to a lowest-common-denominator command model.
- Do not move conversions earlier merely to make the boundary look simpler.
