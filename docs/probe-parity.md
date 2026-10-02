# SDL Probe Parity Matrix

This matrix tracks probe scenario coverage across SDL2 and SDL3 frontends.
The Windows column records what was observed running each scenario through
`SDL_DYNAMIC_API` in a Wheelhouse Cleat pane (see
[Windows results](#windows-results)).

| Scenario | SDL2 | SDL3 | Windows (SDL2 / SDL3) | Notes |
| --- | --- | --- | --- | --- |
| `embed.basic` | present | present | working / working | `basic-sdl-demo` and `basic-sdl3-demo` |
| `render.streaming_texture` | present | present | working / working | Dynamic texture upload path |
| `render.surface_texture` | present | present | working / working | Surface->texture creation + render |
| `input.base` | present | present | working / working | Poll/peep + keyboard/mouse state |
| `input.custom_cursor` | present | present | working / working | Color cursor create/set/show/free |
| `opengl.context_swap` | present | present | working / working | SDL GL context + swap loop |
| `vulkan.instance_surface_present` | present | present | working / working | Vulkan setup + present loop |
| `metal.layer_drawable_present` | macOS | macOS | unsupported | SDL Metal view + `CAMetalLayer` drawable present loop |
| `input.gamepad_joystick` | present | partial | partial / partial | SDL3 now enumerates + optionally opens a device and counts related events, while staying hardware-agnostic |

## Windows results

Observed on Beaufort (Windows 11, AMD Radeon integrated graphics, reached over
RDP) on 2026-09-25, with the official SDL 2.32.10 and 3.4.16 DLLs, in a
Wheelhouse pane with Cleat's bundled ConPTY. Every run used the launcher
profile named below, `injection=dynapi`, and `file_whole` (`t=f`) uploads to
the pane's ghostty terminal.

- `embed.basic`, `render.streaming_texture`, `render.surface_texture`
  (`probe.embed.basic_sdl`, `probe.embed.basic_sdl3`): the frame fills the
  pane with the clear colour, the centre lines, the streaming texture and the
  blended surface texture. SDL2 draws a square for each key typed and quits on
  `q`; the SDL3 demo exits after its frame count.
- `input.base` (`probe.input`, `probe.input.sdl3`): typed text arrives as
  `key_down`, `text_input` and `key_up`, and arrow keys as `key_down`. Pointer
  motion arrives as `mouse_motion` with pane-relative coordinates. SDL3 also
  showed left and right button down/up and wheel events. Wheelhouse reports
  the real pointer position with every mouse event, so a button press arrives
  only while the pointer is over the pane; in the SDL2 run it was not, the
  runtime received the SGR presses outside the image, and no SDL2 button event
  was observed.
- `input.custom_cursor` (`probe.input.cursor`, `probe.input.sdl3.cursor`):
  the colour cursor is installed and composited into the frame.
- `input.gamepad_joystick` (inside the input probes): SDL enumerates with the
  background-events hint set and reports 0 controllers and 0 joysticks. No
  device was attached, so opening a device and its events were not exercised.
- `opengl.context_swap` (`probe.gl`, `probe.gl.sdl3`): the rotating cube is
  captured through SDL's GL swap. The session's OpenGL is the AMD driver
  (OpenGL 4.6 compatibility profile), not the GDI fallback.
- `vulkan.instance_surface_present` (`probe.vulkan`, `probe.vulkan.sdl3`): the
  Vulkan loader (1.4.309) and AMD ICD are present in the RDP session. The
  capture layer loads from `profiles/vulkan/windows` through `VK_LAYER_PATH`
  and `VK_INSTANCE_LAYERS`, reads back the 960x540 `B8G8R8A8_UNORM` swapchain
  and presents it through the SDL adapter library's runtime.
- `metal.layer_drawable_present`: macOS only.

Not covered on Windows: resizing the pane while a probe runs, and applications
that link SDL statically.

## Current deliberate gaps

- SDL3 input probe still has lighter joystick/gamepad behavior than SDL2.
- Probe implementations remain language-specific (SDL2 C, SDL3 C/Zig) by design; shared ownership is at scenario contract level.
