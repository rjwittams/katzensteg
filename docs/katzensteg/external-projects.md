# Katzensteg External Project Inventory

Date: 2026-04-27

This tracks local app forks used to test end-to-end SDL, OpenGL, Vulkan, and streaming paths. Branch names should describe the app-side change, not Katzensteg itself.

## Branch Naming

Use names like:

- `macos-sdl2-video-output`
- `macos-sdl2-build-fixes`
- `macos-sdl-renderer-output`
- `macos-sdl-client-build`
- `macos-vulkan-sdl-output`

Avoid names that only say the branch is for Katzensteg. The useful question is what the fork changes in the target project.

## Fork Remote Status

Forks now exist under `rjwittams` and each local checkout has a separate `rjwittams` remote. Upstream remains `origin`.

| Project | Upstream `origin` | Fork remote |
| --- | --- | --- |
| RetroArch | `https://github.com/libretro/RetroArch.git` | `https://github.com/rjwittams/RetroArch.git` |
| Moonlight Qt | `https://github.com/moonlight-stream/moonlight-qt.git` | `https://github.com/rjwittams/moonlight-qt.git` |
| ScummVM | `https://github.com/scummvm/scummvm.git` | `https://github.com/rjwittams/scummvm.git` |
| Cannonball | `https://github.com/djyt/cannonball.git` | `https://github.com/rjwittams/cannonball.git` |
| Chiaki NG | `https://github.com/streetpea/chiaki-ng.git` | `https://github.com/rjwittams/chiaki-ng.git` |
| cpp-steam-tools | `https://github.com/streetpea/cpp-steam-tools.git` | `https://github.com/rjwittams/cpp-steam-tools.git` |
| ANESE | `https://github.com/daniel5151/ANESE.git` | `https://github.com/rjwittams/ANESE.git` |

## Projects

### RetroArch

- Local checkout: `/Users/robert/dev/RetroArch`
- Current local branch: `robert/macos-sdl2-video-pr-cleanup`
- Pushed fork branches:
  - `rjwittams/macos-sdl2-video-output`
  - `rjwittams/macos-sdl2-window-contexts`
- Local state: source clean; dirty only due to generated local app/crash/shader artifacts.
- Pushed source commits:
  - `fa50e7ede8 macOS: allow SDL2 video and input drivers`
  - `a2288506a7 build: link QuartzCore on macOS`
  - `bf65b03bf9 macos: allow suppressing Cocoa bootstrap window`
  - `dbaa28eae4 video: remember window owner across driver switches`
  - `212d08c630 video: prefer SDL GL context for SDL-owned windows`
  - `0a5f8ab0eb video: add SDL Vulkan context driver`
- Untracked local artifacts:
  - `RetroArch.app/`
  - crash logs
  - Metal shader build products
- Local change shape:
  - macOS build and bundle work
  - SDL2 video and input path changes
  - OpenGL/Vulkan context-driver changes
  - Cocoa bootstrap/window behavior changes
- Launcher profile coverage:
  - `sonic`
  - `sm64ds`
  - `smw`
  - `jsr`
- Linux core requirements:
  - `genesis_plus_gx_libretro.so` for Sonic
  - `melonds_libretro.so` for SM64DS
  - `bsnes_libretro.so` for SMW
  - `flycast_libretro.so` for JSR
  - Source-built RetroArch defaults to a user cores directory such as `~/.config/retroarch/cores`; use RetroArch's Online Updater > Core Downloader entries printed by the bootstrap doctor.
  - Also run RetroArch's Online Updater for its supporting assets: Core Info Files, Controller Profiles, Assets, Databases, and any GLSL/slang shader packages needed by a core. These live under user-configurable RetroArch directories, so the bootstrap doctor does not currently try to prove they are complete.
  - Distro packages such as Arch's `libretro-genesis-plus-gx libretro-melonds libretro-bsnes libretro-flycast` are a fallback, but the RetroArch config or `LIBRETRO_DIRECTORY` must point at the system core directory.
  - On hardened Linux setups, some downloaded libretro cores may be rejected by `dlopen` if they request an executable stack. The bootstrap doctor checks the Linux melonDS core for this and prints `patchelf --clear-execstack <core>` when needed.
- Next cleanup:
  - Keep generated app bundles, crash logs, and shader products out of source branches.
  - Re-test launcher profiles from a clean checkout when bootstrap metadata exists.

### Moonlight Qt

- Local checkout: `/Users/robert/dev/moonlight-qt`
- Current local branch: `macos-sdl-renderer-output`
- Pushed fork branch: `rjwittams/macos-sdl-renderer-output`
- Local state: dirty only due to generated qmake/build artifacts.
- Pushed source commit:
  - `fd8f5171 sdl: fall back to RGB for unsupported texture formats`
- Untracked local artifacts:
  - qmake cache/stash and generated Makefiles
  - `app/Moonlight.app/`
  - `app/release/`
  - built third-party static libraries and release dirs
- Local change shape:
  - SDL video renderer output path
  - hardware decode / format-handling experiments
- Launcher profile coverage:
  - `moonlight.steam`
- Known Katzensteg limitations:
  - terminal streaming works, but terminal mouse input does not yet appear to hit Moonlight's input path
  - mixed-Retina setups can intermittently produce a renderer-output/window-size mismatch that shows the top-left quarter of the stream
- Next cleanup:
  - Keep generated qmake files, app bundles, release output, and built third-party libraries untracked.

### ScummVM

- Local checkout: `/Users/robert/dev/scummvm`
- Current local branch: `master`
- Pushed fork branch: none needed yet; local checkout is clean and currently tracks upstream.
- Local state: clean.
- Local change shape:
  - no app-side patch currently required
  - used to validate SDL surface/software output behavior
- Launcher profile coverage:
  - `mi2`
- Next cleanup:
  - Leave as upstream unless a ScummVM-specific SDL fix becomes necessary.

### Cannonball

- Local checkout: `/Users/robert/dev/cannonball`
- Current local branch: `macos-sdl2-build-fixes`
- Pushed fork branch: `rjwittams/macos-sdl2-build-fixes`
- Local state: dirty only due to local config/script files.
- Pushed source commit:
  - `776d0e7 build: fix macOS CMake and static asserts`
- Untracked local files:
  - `run-cannonball-ks.sh`
- Local change shape:
  - CMake adjustments
  - stdint portability/build fixes
  - local launcher/config files
- Launcher profile coverage:
  - `cannonball`
- Next cleanup:
  - Build from the `cmake/` source directory; Linux uses `-DTARGET=linux.cmake`.
  - Launcher config now comes from the generated `build/config.xml`.
  - Required OutRun Revision B ROMs are checked under `roms/` by the bootstrap doctor.

### Chiaki NG

- Local checkout: `/Users/robert/dev/chiaki-ng`
- Current local branch: `macos-sdl-client-build`
- Pushed fork branch: `rjwittams/macos-sdl-client-build`
- Local state: clean except generated `.codex-tmp/` build/test output.
- Pushed source commits:
  - `12d7c18c build: add SDL streamer toggle`
  - `4e0b9dc8 sdl: add prototype stream-only frontend`
- Submodule fork branch:
  - `/Users/robert/dev/chiaki-ng/third-party/cpp-steam-tools`
  - `rjwittams/macos-static-library`
  - pushed commit `c089760 build: use static library on macOS`
- Untracked local files:
  - `.codex-tmp/`
- Local change shape:
  - CMake changes
  - SDL stream-only client prototype
  - Python wrapper that reuses GUI config and forwards to the SDL client
  - cpp-steam-tools macOS static-library link fix
- Launcher profile coverage:
  - `chiaki.sdl`
  - `chiaki.sdl.child`
- Local verification:
  - Configure with a `uv` Python 3.12 venv containing `protobuf`, and set both `PYTHON_EXECUTABLE` and `Python_EXECUTABLE` to that interpreter for nanopb generation.
  - `cmake --build .codex-tmp/build-sdl-prototype-uv --target chiaki-sdl chiaki-sdl-options-test`
  - `ctest --test-dir .codex-tmp/build-sdl-prototype-uv -R chiaki-sdl --output-on-failure`
- Next cleanup:
  - Keep this branch as a prototype Linux/macOS test surface.
  - Eventually give the SDL client the same launch/config behavior as the GUI, which should subsume the Python wrapper.

### ANESE

- Local checkout: `/Users/robert/dev/ANESE`
- Current local branch: `master`
- Pushed fork branch: none needed yet; local checkout is clean and currently tracks upstream.
- Local state: clean.
- Local change shape:
  - no app-side patch currently required
  - used as a small SDL emulator target
- Launcher profile coverage:
  - `anese.test`
  - `smb3`
- Next cleanup:
  - Leave as upstream unless an ANESE-specific SDL/output fix becomes necessary.

### FFplay

- Local checkout: Homebrew/system install, not a forked local project.
- Launcher profile coverage:
  - `ffplay.testsrc`
- Notes:
  - Keep this as a runtime smoke target rather than a source fork unless FFmpeg-specific changes become necessary.

## Current Branch Cleanup State

Linux-port preparation is tracked in `docs/katzensteg/linux-port-readiness.md`.
Bootstrap metadata lives in `profiles/external-projects.json` and can be applied with `scripts/katzensteg/bootstrap_external_projects.py`.

- Done:
  - created `rjwittams` fork remotes for RetroArch, Moonlight Qt, ScummVM, Cannonball, Chiaki NG, and ANESE
  - pushed RetroArch committed app-side work to `rjwittams/macos-sdl2-video-output`
  - pushed RetroArch SDL window/context work to `rjwittams/macos-sdl2-window-contexts`
  - pushed Moonlight SDL renderer work to `rjwittams/macos-sdl-renderer-output`
  - pushed Cannonball macOS build fixes to `rjwittams/macos-sdl2-build-fixes`
  - pushed cpp-steam-tools macOS static-library fix to `rjwittams/macos-static-library`
  - pushed Chiaki NG SDL client prototype to `rjwittams/macos-sdl-client-build`
  - added a first-class `cannonball` Katzensteg launcher profile
  - added bootstrap metadata and a clone/update helper for external checkouts
  - added bootstrap doctor checks for Katzensteg build dependencies, external project outputs, local assets, Cannonball ROMs/config, and RetroArch cores
  - moved Moonlight dirty work from `master` to `macos-sdl-renderer-output`
  - moved Cannonball dirty work from `master` to `macos-sdl2-build-fixes`
  - moved Chiaki dirty work from `main` to `macos-sdl-client-build`
- Still needed:
  - add deeper terminal capability checks beyond local tools, profile paths, and missing assets
