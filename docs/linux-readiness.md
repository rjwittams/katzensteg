# Linux Readiness

Linux support is active, but should be approached as a bring-up matrix rather than a single "works / does not work" state.

## Baseline Requirements

- Zig 0.15.2.
- SDL2 development headers and libraries.
- libyuv.
- Vulkan loader and headers when building Vulkan capture.
- A kitty-compatible terminal.

Linux builds currently use LLVM codegen in `build.zig`. Do not casually flip that path without revalidating linker behavior on the target distribution.

## First Checks

Build:

```sh
zig build
```

If Vulkan dependencies are not ready yet:

```sh
zig build -Dvulkan=false
```

Run the first profile:

```sh
./zig-out/bin/katzensteg --dry-run probe.input
./zig-out/bin/katzensteg probe.input
```

## Smoke Matrix

Recommended order:

| Profile | Purpose |
| --- | --- |
| `probe.input` | SDL/input baseline |
| `ffplay.testsrc` | simple media/external-output stress target |
| `cannonball` | simple SDL app fork |
| `mi2` | ScummVM SDL software/surface path |
| `smb3` | small SDL emulator path |
| `sonic` | RetroArch SDL software path |
| `sm64ds` | RetroArch renderer/context behavior |
| `jsr` | Vulkan-adjacent RetroArch/Flycast path |
| `moonlight.steam` | streaming workload |
| `chiaki.sdl` | SDL stream-client prototype |

Start with `--dry-run` for every real app profile.

## External Projects

Use the bootstrap helper as a doctor, not as a reliable installer:

```sh
scripts/katzensteg/bootstrap_external_projects.py --doctor-only --root ~/dev
```

It should report missing checkouts, branches, build outputs, and obvious local data gaps. It is pre-alpha and expected to need fixes as more Linux environments are tested.

## Profiling

Use Linux `perf` as the baseline profiler once the first SDL probe works. Capture separate profiles for:

- Katzensteg runtime overhead
- app render/decode cost
- terminal upload/presentation cost

The profiling workflow is still being developed; do not block basic smoke testing on a polished profiling setup.
