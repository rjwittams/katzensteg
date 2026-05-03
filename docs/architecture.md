# Katzensteg Architecture

Katzensteg is currently an injected runtime plus a launcher.

The launcher starts a target application from a JSON profile. The runtime is injected into that process with `LD_PRELOAD` on Linux or `DYLD_INSERT_LIBRARIES` on macOS. Once inside the process, Katzensteg intercepts the SDL2 presentation/input surface that the application exposes, mirrors the rendered output into terminal graphics, and routes terminal input back into SDL where supported.

## Current Support Boundary

The reliable path today is pure SDL2 output and input:

- SDL2 software surfaces.
- SDL2 renderer output.
- SDL keyboard and mouse event paths.
- Terminal graphics output using kitty-compatible protocol support.

Several larger applications in the smoke matrix needed app-side patches or build modes so they expose a pure SDL2 renderer/input path. Katzensteg should be documented and tested honestly around that boundary.

OpenGL and Vulkan capture work exists in the tree, and some profiles exercise those paths, but arbitrary GL/Vulkan application support is not the current baseline.

## Main Pieces

### Launcher

`zig-out/bin/katzensteg` is the normal entry point. It:

- loads and resolves JSON profiles from `profiles/`
- expands local path placeholders
- writes runtime configuration
- prepares the target environment
- redirects target output away from the terminal when needed
- starts the target process
- performs best-effort terminal cleanup after exit

The launcher should be the place to encode repeatable run policy. Avoid adding new ad hoc run scripts when a launcher profile would do.

### Runtime

The runtime lives under `src/katzensteg/`. It owns:

- SDL2 capture and replay state
- frame composition
- terminal graphics output
- keyboard and mouse input mapping
- logging
- platform interposer glue

The runtime must not write diagnostics to stdout or stderr during a captured run, because those streams may be part of the terminal presentation.

### Profiles

Profiles are JSON files under `profiles/`. They define target commands, inheritance, platform-specific values, runtime policy, and local setup details.

Hidden profiles are reusable fragments. Visible profiles are direct launch targets.

### External App Forks

Some real workloads need patched application branches to expose SDL2 paths that are useful to Katzensteg. Those forks are tracked in `docs/external-projects.md`; their code does not live in this repository.

## Non-Goals For The Current Public Surface

- Claiming general arbitrary native-app support.
- Treating GL/Vulkan as the stable default path.
- Publishing prototype host/compositor/protocol experiments as user-facing features before they have a release shape.
- Reintroducing one-off launcher scripts for new profiles.
