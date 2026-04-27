# Katzensteg Linux Port Readiness

Date: 2026-04-27

This is the practical checkpoint before trying Katzensteg on a Linux machine. The goal is not to make every target polished first; it is to make checkout, build, launch, and profiling predictable enough that Linux failures are informative.

## Current Baseline

- Katzensteg has a launcher with reusable profiles for SDL software, OpenGL, Vulkan, external framebuffer, and stream-like workloads.
- App-side forks exist under `rjwittams` for the non-trivial targets.
- RetroArch, Moonlight Qt, Cannonball, Chiaki NG, and cpp-steam-tools now have pushed fork branches.
- ScummVM and ANESE currently need no app-side fork patches.

## Next Steps

1. **Bootstrap metadata**
   - Add a machine-readable manifest of external checkouts, remotes, branches, and basic build commands.
   - Include profile names that exercise each checkout, so a new machine can move from clone to smoke test without hunting through shell history.

   Current helper:

   ```sh
   tools/katzensteg/bootstrap_external_projects.py --dry-run
   tools/katzensteg/bootstrap_external_projects.py --root ~/dev
   tools/katzensteg/bootstrap_external_projects.py --root ~/dev retroarch chiaki.sdl
   ```

   On a new machine, clone the Katzensteg repo first, then run the helper from that checkout. The helper intentionally prints build commands as notes rather than trying to become a cross-platform package manager.

2. **Launcher portability pass**
   - Teach profiles about platform-specific preload variables: `DYLD_INSERT_LIBRARIES` on macOS, `LD_PRELOAD` on Linux.
   - Make shared-library names and libretro core suffixes platform-aware: `.dylib` vs `.so`.
   - Keep profile inheritance and runtime config unchanged where possible.

3. **Linux build surface**
   - Build Katzensteg itself on Linux first, including SDL2 headers/libs and the launcher.
   - Verify basic SDL probe and `ffplay.testsrc` before trying larger app forks.
   - Then test RetroArch software SDL, RetroArch GL, RetroArch Vulkan, Cannonball, ScummVM, ANESE, Moonlight, and Chiaki in that order.

4. **Linux accelerated image paths**
   - Do not re-investigate from scalar-only baselines where macOS already proved the shape.
   - Add Linux equivalents for the macOS vImage-backed scale/convert paths, with the same scalar fallback behavior.
   - Prioritize fullscreen scaling and pixel-format conversion paths that already show up hot on macOS profiles.
   - Treat library choice as an implementation detail: likely candidates include SIMD code paths, pixman/libswscale, or platform-specific helpers, but the public Katzensteg path should stay the same.

5. **Terminal capability checks**
   - Re-check kitty graphics transport behavior on Linux terminals: kitty, Ghostty if available, foot/WezTerm if convenient.
   - Confirm file transport, direct APC fallback, keyboard protocol, mouse tracking, alt-screen teardown, and image clear behavior.

6. **Profiling setup**
   - Use Linux `perf` as the baseline profiler.
   - Install/debug symbols for Katzensteg and app forks, and build Katzensteg with enough symbol information for useful call stacks.
   - Consider `hotspot`, `perfetto`, or `samply` as nicer frontends once raw `perf record/report` is producing credible data.

7. **Known deferred gaps**
   - Moonlight terminal mouse path is still not understood.
   - Moonlight mixed-Retina output-size mismatch is macOS-specific but should be recorded as a presentation-layout issue, not treated as Linux blocking.
   - Runtime menu/chrome and richer profile UI can wait until the Linux smoke matrix is real.

## First Linux Smoke Matrix

| Profile | Purpose | Expected first check |
| --- | --- | --- |
| `probe.input` | SDL/input baseline | keyboard, mouse, gamepad event flow |
| `ffplay.testsrc` | non-fork external framebuffer-ish media target | basic terminal image transport |
| `cannonball` | simple SDL app fork | software SDL output and input |
| `mi2` | upstream ScummVM SDL path | surface/software output |
| `smb3` | upstream ANESE emulator | simple emulator SDL path |
| `sonic` | RetroArch SDL software | libretro + terminal-only path |
| `sm64ds` | RetroArch GL/Vulkan-adjacent workload | context driver behavior |
| `jsr` | RetroArch Vulkan | Vulkan capture path |
| `moonlight.steam` | streaming workload | texture formats, decode cost, mouse gap |
| `chiaki.sdl` | prototype SDL stream client | branch portability and launch behavior |

## Success Criteria

- A fresh Linux checkout can build Katzensteg and run at least `probe.input`, `ffplay.testsrc`, and one emulator profile.
- App fork branches can be cloned from `rjwittams` without relying on unpublished local commits.
- First failing Linux runs produce enough launcher output and Katzensteg logs to identify whether the failure is build, preload, terminal capability, SDL interception, GL/Vulkan capture, or app-specific behavior.
