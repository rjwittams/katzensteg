# Roadmap

Katzensteg is an alpha project. The near-term goal is not broad arbitrary native-app support; it is a reliable, understandable path for real SDL2 applications and selected patched workloads to run inside kitty-compatible terminals.

## Current Baseline

- Pure SDL2 output/input is the reliable path.
- The launcher and profile system are the normal way to run targets.
- Keyboard and mouse input work for the main tested paths.
- Real workloads include emulator, adventure-game, stream-client, and SDL probe targets.
- Some larger targets need app-side SDL2 patches or build modes.
- Linux support is active and should be verified against the smoke matrix.

## Phase 1: Stabilize The Public Path

Goals:

- Keep `probe.input` as the first bring-up target.
- Keep SDL2 software/renderer capture reliable.
- Keep terminal cleanup and log output predictable.
- Make profile dry-runs clear enough to diagnose missing local setup.
- Remove stale or misleading docs and scripts.
- Add tests for non-trivial launcher/runtime behavior.

## Phase 2: Real App Smoke Matrix

Goals:

- Keep RetroArch SDL2 profiles working.
- Keep ScummVM and small SDL apps working.
- Keep Moonlight/Chiaki streaming profiles useful as stress tests.
- Track which profiles require app-side patches.
- Make `bootstrap_external_projects.py` a more reliable doctor for local setup while staying honest that it is not a package manager.

## Phase 3: Linux Readiness

Goals:

- Make a fresh Linux checkout build Katzensteg.
- Verify `probe.input` first.
- Verify at least one emulator profile.
- Keep Linux linker/toolchain assumptions documented.
- Establish a repeatable profiling workflow.

## Phase 4: Runtime Boundaries

Goals:

- Keep SDL2 adapter behavior separate from reusable runtime behavior.
- Preserve one owner for terminal graphics state, input, image lifetime, and logging.
- Keep platform-specific interposer code isolated.
- Make future SDL3 or deeper Vulkan work possible without muddling the current SDL2 baseline.

## Phase 5: Performance And Formats

Goals:

- Reduce avoidable frame copies.
- Improve format conversion paths.
- Keep file/direct terminal transport choices measurable.
- Profile terminal upload cost separately from application render/decode cost.
- Preserve slower-but-correct fallbacks while experimenting.

## Deferred

These areas are real, but should not be presented as stable user-facing features yet:

- richer terminal chrome/control surfaces
- multi-window host/compositor experiments
- general host/embedding protocols
- arbitrary OpenGL/Vulkan application support
- external surface import paths such as dmabuf or IOSurface
