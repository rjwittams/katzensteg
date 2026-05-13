# Probe Scenario Contracts

## Naming

- Use `probe.<domain>[.sdl3][.variant]` launcher profile naming.
- Use stable API-kind labels in logs/docs:
  - `render.streaming_texture`
  - `render.surface_texture`
  - `input.custom_cursor`
  - `opengl.context_swap`
  - `vulkan.instance_surface_present`

## Pass Criteria

- Probe starts and exits cleanly.
- Required API-kind path is actually exercised in code (not just profile wiring).
- No stdout/stderr writes from preload runtime itself (probe binaries may log).
- Dry-run profile resolves the intended adapter:
  - SDL2 probes use `adapter.sdl2_preload`
  - SDL3 probes use `adapter.sdl3_preload`

## Logging

- Probe startup line should identify probe kind and frontend.
- Optional frame logging should be stable and grep-friendly.
