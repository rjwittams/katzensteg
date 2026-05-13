# SDL Probe Parity Matrix

This matrix tracks probe scenario coverage across SDL2 and SDL3 frontends.

| Scenario | SDL2 | SDL3 | Notes |
| --- | --- | --- | --- |
| `embed.basic` | present | present | `basic-sdl-demo` and `basic-sdl3-demo` |
| `render.streaming_texture` | present | present | Dynamic texture upload path |
| `render.surface_texture` | present | present | Surface->texture creation + render |
| `input.base` | present | present | Poll/peep + keyboard/mouse state |
| `input.custom_cursor` | present | present | Color cursor create/set/show/free |
| `opengl.context_swap` | present | present | SDL GL context + swap loop |
| `vulkan.instance_surface_present` | present | present | Vulkan setup + present loop |
| `input.gamepad_joystick` | present | partial | SDL3 path is intentionally lighter to avoid hardware-dependent failures |

## Current deliberate gaps

- SDL3 input probe still has lighter joystick/gamepad behavior than SDL2.
- Probe implementations remain language-specific (SDL2 C, SDL3 C/Zig) by design; shared ownership is at scenario contract level.
