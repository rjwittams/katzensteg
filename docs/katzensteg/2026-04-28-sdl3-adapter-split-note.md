# SDL3 Adapter Split Note

Katzensteg should treat SDL3 support as pressure to split the preload side by adapter ABI, while keeping a shared runtime core underneath.

The current preload library is effectively an SDL2 adapter plus the reusable Katzensteg runtime in one artifact. SDL3 keeps many familiar `SDL_*` names, but the ABI is not SDL2-compatible: functions have changed signatures and return conventions. For example, SDL3's renderer creation API takes a renderer name instead of the SDL2 index/flags pair. Exporting SDL2 and SDL3 variants of the same symbol from one interposer would be ambiguous and fragile.

The preferred shape is:

```text
libkatzensteg-core.so
  runtime, frame builder, terminal backend, config, payload buffers,
  image conversion, input mapping, logging

libkatzensteg-sdl2.so
  SDL2 exported interpose symbols, SDL2 real dispatch, SDL2-to-core command mapping

libkatzensteg-sdl3.so
  SDL3 exported interpose symbols, SDL3 real dispatch, SDL3-to-core command mapping

libkatzensteg-vulkan-layer.so
  Vulkan layer entry points, presented-frame capture, core external framebuffer path
```

The launcher should select adapters explicitly. An SDL2 app would receive `LD_PRELOAD=.../libkatzensteg-sdl2.so`; an SDL3 app would receive `LD_PRELOAD=.../libkatzensteg-sdl3.so`; a Vulkan path would additionally set the Vulkan layer environment. Profile fragments such as `adapter.sdl2_preload`, `adapter.sdl3_preload`, and `capture.vulkan` keep this selection declarative.

Avoid independently static-linking the core into multiple adapters in the same process. An SDL adapter and Vulkan layer can be active together, and they should share one runtime singleton, one terminal presentation state, one payload buffer pool, and one config view. If each adapter embeds its own core copy, SDL input/window events and Vulkan frame presentation can split into different runtimes.

GL does not need to be split on day one. The current GL path is SDL-window-driven: capture is triggered around `SDL_GL_SwapWindow`, uses SDL drawable sizing, and reads back through GL helpers. Keep that as part of the SDL adapter path until there is a direct GL/EGL/GLX use case that does not go through SDL. Vulkan is already naturally separate because the Vulkan loader discovers it through an implicit layer manifest rather than preload symbol interposition.

Near-term sequence:

1. Move reusable runtime-facing pieces behind an adapter-neutral command boundary.
2. Rename the existing preload artifact conceptually to the SDL2 adapter.
3. Add build/profile support for `libkatzensteg-sdl2`.
4. Add SDL3 bindings, real dispatch, and an SDL3 adapter that maps equivalent calls into the same core commands.
5. Teach profiles and launch planning to select SDL2, SDL3, Vulkan, or combinations explicitly.
6. Revisit a separate GL adapter only after a non-SDL GL producer makes it necessary.

The useful boundary is that adapters observe foreign graphics/input APIs and emit core commands; the core owns terminal rendering, frame dropping, input routing state, payload ownership, image conversion, and diagnostics.
