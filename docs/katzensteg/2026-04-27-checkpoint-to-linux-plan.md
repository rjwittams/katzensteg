# Katzensteg Checkpoint To Linux Plan

Date: 2026-04-27
Status: Working plan after checkpoint `f225958`

## Goal

Turn the current Katzensteg proof-of-concept tree into a repeatable project that can be checked out, built, profiled, and run on a new machine, then ported to Linux without depending on ad hoc local scripts and untracked forks.

## Current State

The repository is checkpointed at `f225958 checkpoint katzensteg runtime work`.

Current proof points:

- SDL2 apps can be mirrored into kitty/ghostty on macOS.
- RetroArch SDL2 software-rendered cores are usable.
- OpenGL and Vulkan framebuffer capture paths have basic coverage.
- Moonlight can stream through the terminal when launched through an SDL path.
- Terminal mouse and keyboard input work at a useful fallback level.
- Gamepad background input works without forcing the real SDL window to be focused.
- The embedded inspector has been demoted while the external `whiskers` direction is in flight.

Known messy areas:

- Launcher profiles are too close to shell-script transliterations.
- Environment variables still do most of the actual runtime configuration.
- App forks and local builds are not organized under stable remotes/branches.
- The repo is still named and structured around `ttytris`, even though Katzensteg is now the real project.
- Banner prototype files are useful but not central.
- Linux assumptions are not yet encoded in the build, launcher, or adapter split.

## Principles

- Checkpoint first, refactor second.
- Keep direct preload use working while the launcher improves.
- Do not hide real mechanics behind opaque profiles. Dry-run output must show the resolved launch plan, env, config, paths, and logs.
- Profiles describe intent; the launcher owns repeated mechanics.
- External app forks must be reproducible from GitHub, not remembered from local paths.
- Linux work should begin after checkout/build reproducibility is in place.

## Phase 1: Make The Launcher Useful Instead Of Script-Shaped

Goal: make `katzensteg <profile>` the normal path for repeated local testing without turning profiles into worse shell scripts.

### Decisions

- Profiles should describe app identity and app-specific facts:
  - executable/profile family
  - ROM/game/core/app args
  - renderer/capture intent
  - unusual app quirks
- Launcher defaults should cover:
  - stdout/stderr log path
  - stderr-to-stdout behavior
  - common temp cleanup
  - terminal reset
  - SDL preload library
  - generated `KATZENSTEG_CONFIG`
  - default terminal-only runtime settings
- Environment variables remain:
  - compatibility override path
  - debugging escape hatch
  - final process boundary

### Tasks

- [x] Add a resolved launch-plan struct separate from raw parsed profile data.
- [ ] Add launch defaults for logs, cleanup, preload, and runtime config. Logs and runtime config now default; preload selection remains explicit.
- [x] Make `--dry-run` print the resolved launch plan, not just counts.
- [x] Simplify existing profiles after defaults exist.
- [x] Keep old scripts as shims or comparison paths until profiles prove equivalent.
- [x] Add one smoke profile that does not require SDL for launcher regression tests.

### Verification

- [x] `zig test tools/katzensteg/launcher.zig`
- [x] `zig test tools/katzensteg/launcher_profiles.zig`
- [x] `zig build -freference-trace`
- [x] `./zig-out/bin/katzensteg retroarch.sonic --dry-run`
- [x] `./zig-out/bin/katzensteg probe.input --dry-run`
- [ ] Manual run: `probe.input`
- [ ] Manual run: `retroarch.sonic`

## Phase 2: Inventory And Fork External App Code

Goal: make every modified or assumed external project explicit and reproducible.

### Inventory Targets

Start with:

- RetroArch
- Moonlight
- ScummVM
- Cannonball
- any local libretro core builds that differ from upstream packages
- any helper configs required for SDL2, Vulkan, or software renderer paths

### For Each Project

Record:

- local path
- upstream remote
- current branch
- local uncommitted changes
- patches needed for Katzensteg
- build command
- installed binary/core path
- launcher profiles depending on it
- platform scope: macOS only, Linux only, or both

### Tasks

- [x] Create `docs/katzensteg/external-projects.md`.
- [x] Add one section per external project.
- [ ] For each project, create or confirm a `rjwittams` GitHub fork.
- [ ] Push local branches to those forks with names describing the app-side change, not Katzensteg itself. Most branches should be named around macOS build fixes or end-to-end SDL output support.
- [ ] Update launcher profiles to use stable checkout conventions where practical.

### Verification

- [ ] Every launcher profile has a documented source project.
- [ ] Every documented fork has a remote URL and branch name.
- [ ] A clean clone can identify what to build without reading local shell history.

## Phase 3: New Machine Bootstrap

Goal: make a fresh machine setup boring.

### Shape

Add a small bootstrap layer that can:

- clone the main Katzensteg repo
- clone known external forks into predictable paths
- print or run build commands
- verify required tools and libraries
- generate local launcher profile overrides

This should not become a giant cross-platform package manager. It should be explicit, inspectable, and easy to repair.

### Tasks

- [ ] Decide checkout root convention, probably `~/dev/katzensteg-workspace`.
- [ ] Add a manifest of external repos and branches.
- [ ] Add a bootstrap script or Zig launcher subcommand that reads the manifest.
- [ ] Add a doctor command/checklist for local paths, binaries, dylibs/so files, and terminal support.
- [ ] Add documentation for macOS setup first.
- [ ] Add Linux setup once the port begins.

### Verification

- [ ] Fresh checkout can build Katzensteg.
- [ ] Bootstrap can clone or report all external repos.
- [ ] Launcher dry-runs resolve using the expected checkout paths.

## Phase 4: Recenter The Repo Around Katzensteg

Goal: make the repository name and layout match the actual project.

### Candidate Layout

```text
src/katzensteg/
profiles/
examples/ttytris/
examples/probes/
scripts/dev/
docs/katzensteg/
```

Keep this separate from launcher cleanup. Moving files before the launcher boundary is clear will make the same confusion harder to review.

### Tasks

- [ ] Decide final repo name, likely `katzensteg`.
- [ ] Create or rename GitHub repo under `rjwittams`.
- [ ] Move Katzensteg source out of `tools/katzensteg` once the build is stable.
- [ ] Move ttytris into examples or demos.
- [ ] Update build targets, scripts, profile paths, docs, and CI/dev commands.
- [ ] Keep compatibility shims only where they save real friction.

### Verification

- [ ] `zig build -freference-trace`
- [ ] all focused Katzensteg tests
- [ ] launcher dry-runs from outside the repo
- [ ] at least one SDL probe run
- [ ] at least one RetroArch run

## Phase 5: Linux Port

Goal: make Katzensteg work on Linux through the same core concepts, with platform-specific adapter code isolated.

### Main Work Areas

- `LD_PRELOAD` instead of `DYLD_INSERT_LIBRARIES`
- ELF symbol interposition and dynamic loader differences
- SDL2 dynamic loading behavior on Linux
- Vulkan layer discovery and packaging
- OpenGL capture path differences
- kitty/ghostty terminal behavior on Linux
- file transport temp paths and permissions
- controller/input behavior under Linux window systems

### Tasks

- [ ] Split macOS-specific interpose code from platform-neutral preload/runtime code.
- [ ] Add Linux interpose source.
- [ ] Add Linux build outputs for preload library and Vulkan layer.
- [ ] Port launcher environment generation for Linux.
- [ ] Test basic SDL probe.
- [ ] Test RetroArch SDL2 software renderer.
- [ ] Test GL probe.
- [ ] Test Vulkan probe.

### Verification

- [ ] Linux build passes.
- [ ] `LD_PRELOAD` SDL probe renders to terminal.
- [ ] Terminal input works with kitty keyboard protocol or current fallback.
- [ ] RetroArch profile launches from a fresh checkout.

## Phase 6: Profiling Story

Goal: replace macOS Instruments habits with a Linux profiling workflow that is good enough for Katzensteg.

### Recommended Stack

- Use `perf` as the raw sampling foundation.
- Use Hotspot for CPU flamegraph/top-down/caller-callee inspection.
- Use Perfetto when thread timelines, scheduling, ftrace, or cross-process context matter.
- Consider Tracy once Katzensteg has stable frame-stage boundaries worth instrumenting.

### Tasks

- [ ] Add `docs/katzensteg/linux-profiling.md`.
- [ ] Document a standard `perf record` command for Katzensteg runs.
- [ ] Document opening perf data in Hotspot.
- [ ] Document a Perfetto config for thread/scheduling investigation.
- [ ] Decide whether to add optional Tracy zones around capture/build/upload/present stages.

### Verification

- [ ] Capture one Linux CPU profile of the SDL probe.
- [ ] Capture one profile of an emulator workload.
- [ ] Confirm symbols resolve for Katzensteg build outputs.

## Post-Linux Investigations

These are real issues, but they should not block the Linux port unless they turn out to reproduce there.

- Moonlight HiDPI/output-size mismatch: Moonlight uses `SDL_GetRendererOutputSize` and sets the renderer viewport to that output size. On mixed-Retina macOS setups this sometimes appears to choose a 2x backing size even when the visible window is on a non-Retina display, and Katzensteg then shows the top-left quarter of the stream in the terminal. Treat this as a missing explicit transform in the presentation model: texture/frame pixels -> renderer output pixels -> SDL logical window coordinates -> Katzensteg presentation rect -> terminal cells. Add trace coverage for `SDL_GetWindowSize`, `SDL_GetRendererOutputSize`, viewport changes, and texture sizes before changing behavior.
- Moonlight mouse path: terminal mouse injection works in the SDL input probe, ScummVM, and RetroArch mouse tests, but Moonlight does not appear to consume the same path. Investigate whether it uses relative mouse mode, raw/input-grab state, warp APIs, controller-like mouse emulation, or a different SDL event/state query pattern. Keep the first pass diagnostic rather than app-specific.

## Immediate Next Step

Start with Phase 1. The launcher is the current bottleneck for repeatability, and it also defines the shape that external-project inventory and Linux bootstrap will rely on.
