# Metal capture status

The macOS-only `libkatzensteg-metal-layer.dylib` now hooks `CAMetalLayer`
drawables and Metal command-buffer presentation. It copies supported BGRA
drawables to shared buffers and publishes compact rows through
`ks_katzensteg_present_external_framebuffer`. The existing queued framebuffer
path owns terminal presentation. This is narrow probe-level support; real-app
acceptance with the Porthole native viewer is tracked in
[issue #57](https://github.com/rjwittams/katzensteg/issues/57).

## Test targets

- `katzensteg-metal-probe` and `katzensteg-metal-probe-sdl3` are macOS-only SDL
  probes that create an SDL Metal view, configure the backing `CAMetalLayer`,
  acquire a drawable with `nextDrawable`, render into it, and present with
  `-[MTLCommandBuffer presentDrawable:]`.
- The Porthole native capture viewer in `~/dev/porthole/tools/capture-viewer-sdl`
  is a stronger real-app target. It wraps IOSurfaces as Metal textures, GPU-waits
  on an `MTLSharedEvent`, blits into the drawable, then calls `presentDrawable:`.
  A capture hook inserted into the same command buffer should naturally run after
  the viewer's wait and blit.

## Implemented path

1. The macOS build produces `libkatzensteg-metal-layer.dylib`; the SDL2 and
   SDL3 Metal probe profiles load it with `DYLD_INSERT_LIBRARIES` and enable
   `KATZENSTEG_METAL_CAPTURE`.
2. The layer hooks Objective-C methods:
   - `-[CAMetalLayer nextDrawable]` to observe drawable/layer metadata.
   - `-[MTLCommandBuffer presentDrawable:]`.
   - `-[MTLCommandBuffer presentDrawable:atTime:]`.
   - `-[MTLCommandBuffer presentDrawable:afterMinimumDuration:]`.
3. On present, encode a copy from `drawable.texture` to a CPU-visible
   `MTLBuffer`, then add a completion handler that compacts rows and calls
   `ks_katzensteg_present_external_framebuffer`.
4. Only `MTLPixelFormatBGRA8Unorm` and `MTLPixelFormatBGRA8Unorm_sRGB` pass
   the current format check. Other formats are skipped with a file-log entry.

## Limits and follow-up

- The completion handler publishes copied pixels into the queued framebuffer
  path. It must not write to the terminal or mutate presentation state itself.
- The layer aligns Metal row pitch and compacts rows before calling core. A
  strided core API is not needed for this producer.
- The `nextDrawable` hook sets `framebufferOnly = NO` before obtaining a
  drawable; capture skips and logs an incompatible drawable if one remains.
- Hook installation scans Metal command queue and buffer classes. Filtering
  drawables to selected windows or profiles is not yet specified.
- The Porthole native viewer's shared-event and IOSurface path needs the real
  workload check in #57 before claiming support beyond the probes.
