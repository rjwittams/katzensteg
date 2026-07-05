# Metal capture plan

Metal support should follow the existing external-framebuffer path rather than
adding terminal/compositor behavior. The capture layer should publish BGRA/RGBA
frames through `ks_katzensteg_present_external_framebuffer`; `frame_builder`
already converts those formats before terminal presentation.

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

## Proposed implementation

1. Add a macOS-only `libkatzensteg-metal-layer.dylib` built from Objective-C/C
   and linked against `Metal`, `QuartzCore`, `Foundation`, and `objc`.
2. Enable it through launcher profiles with `DYLD_INSERT_LIBRARIES` and
   `KATZENSTEG_METAL_CAPTURE`.
3. Swizzle/interpose Objective-C methods:
   - `-[CAMetalLayer nextDrawable]` to observe drawable/layer metadata.
   - `-[MTLCommandBuffer presentDrawable:]`.
   - `-[MTLCommandBuffer presentDrawable:atTime:]`.
   - `-[MTLCommandBuffer presentDrawable:afterMinimumDuration:]`.
4. On present, encode a copy from `drawable.texture` to a CPU-visible
   `MTLBuffer`, then add a completion handler that compacts rows and calls
   `ks_katzensteg_present_external_framebuffer`.
5. Start with `MTLPixelFormatBGRA8Unorm` and `MTLPixelFormatBGRA8Unorm_sRGB`;
   both map to existing `.bgra8`.

## Open decisions

- Threading: completion handlers should not directly mutate terminal presentation
  state. Prefer the queued external-framebuffer path, or add an explicit exported
  queue-only entry point for foreign GPU callbacks.
- Row layout: Metal copy-to-buffer paths usually need aligned `bytesPerRow`;
  either compact rows in the Metal layer before calling core, or add a strided
  framebuffer export.
- `framebufferOnly`: probes and Porthole set `CAMetalLayer.framebufferOnly = NO`,
  which permits blit/readback. A general capture layer may need to force this
  before the first drawable, with logging when it observes incompatible layers.
- Filtering: decide whether the layer captures every `CAMetalLayer` in-process or
  only drawables from SDL-created windows/profile-marked targets.
