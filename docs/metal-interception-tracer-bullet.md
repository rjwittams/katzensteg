# Metal interception tracer bullet

## Scope

Build a macOS-only Metal capture layer that proves the same external
framebuffer pipeline used by OpenGL and Vulkan can capture frames from native
Metal presentation.

The first supported shape is intentionally narrow:

- `CAMetalLayer` drawables.
- `-[MTLCommandBuffer presentDrawable:]` and timed variants.
- `MTLPixelFormatBGRA8Unorm` / `MTLPixelFormatBGRA8Unorm_sRGB`.
- SDL2/SDL3 Metal probes and the Porthole native capture viewer presentation
  style.
- Queued publication into Katzensteg, not direct terminal mutation from Metal
  callback threads.

## Implementation outline

1. Add `libkatzensteg-metal-layer.dylib`.
2. Enable it from profiles with `DYLD_INSERT_LIBRARIES` and
   `KATZENSTEG_METAL_CAPTURE=1`.
3. Swizzle Objective-C methods at runtime:
   - `-[CAMetalLayer nextDrawable]` to force/observe capture-compatible layer
     state.
   - command-buffer `presentDrawable:` methods to insert a readback blit before
     the app's present operation.
4. In the present hook:
   - skip unsupported pixel formats.
   - allocate/reuse a shared `MTLBuffer` with aligned row pitch.
   - encode `copyFromTexture:toBuffer:` on the app command buffer.
   - add a completion handler that compacts rows to tightly packed BGRA.
   - call `ks_katzensteg_present_external_framebuffer(width, height, bgra8, ...)`.

## Risks and decisions

- `MTLCommandBuffer` is a protocol backed by private concrete classes, so hooks
  must be installed by class enumeration/lazy swizzling rather than static C
  interpose.
- `CAMetalLayer.framebufferOnly` must be `NO` before drawables are created for
  blit/readback to be valid. First version may force this and log once.
- Completion handlers run on Metal/driver-managed threads. The core entry point
  must resolve to the queued path in normal profiles; direct terminal presentation
  from the callback thread is out of scope.
- Metal row pitch alignment should stay inside the Metal layer for now. Do not
  expand the core framebuffer API until there is a second producer that needs
  strided publication.

## Verification notes

- `KATZENSTEG_TRACE_METAL=1` writes `/tmp/katzensteg-metal-<pid>.log` from the
  Metal layer. A successful tracer-bullet run should show the constructor,
  command queue / command buffer hook installation, and `queued first Metal
  capture <w>x<h>`.
- Running `probe.metal` from a non-interactive command runner can still leave
  `/tmp/katzensteg-probe-metal.out` with only the probe startup line. That means
  direct terminal rendering could not initialize and there was no attached batch
  viewport; it does not by itself mean the Metal hook failed.
