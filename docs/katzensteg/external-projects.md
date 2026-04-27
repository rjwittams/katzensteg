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
| ANESE | `https://github.com/daniel5151/ANESE.git` | `https://github.com/rjwittams/ANESE.git` |

## Projects

### RetroArch

- Local checkout: `/Users/robert/dev/RetroArch`
- Current local branch: `robert/macos-sdl2-video-pr-cleanup`
- Pushed fork branch: `rjwittams/macos-sdl2-video-output`
- Local state: dirty; the pushed branch contains the two committed macOS/SDL2 commits, but the currently tested tree also has uncommitted GL/Vulkan/windowing work.
- Uncommitted source changes:
  - `Makefile.common`
  - `gfx/common/vulkan_common.c`
  - `gfx/common/vulkan_common.h`
  - `gfx/drivers/sdl2_gfx.c`
  - `gfx/drivers/vulkan.c`
  - `gfx/drivers_context/sdl_gl_ctx.c`
  - `gfx/video_driver.c`
  - `gfx/video_driver.h`
  - `ui/drivers/cocoa/cocoa_common.m`
  - `ui/drivers/ui_cocoa.m`
- Untracked local artifacts:
  - `RetroArch.app/`
  - crash logs
  - Metal shader build products
  - `gfx/drivers_context/sdl_vk_ctx.c`
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
- Next cleanup:
  - Split uncommitted work into at least SDL2 software, SDL GL, SDL Vulkan, and Cocoa/windowing commits.
  - Decide whether `gfx/drivers_context/sdl_vk_ctx.c` is source or a local experiment before committing.
  - Keep generated app bundles, crash logs, and shader products out of source branches.
  - Use `docs/katzensteg/retroarch-agent-handoff.md` as the handoff prompt for splitting this work.

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
  - `config.xml`
  - `run-cannonball-ks.sh`
- Local change shape:
  - CMake adjustments
  - stdint portability/build fixes
  - local launcher/config files
- Launcher profile coverage:
  - no Katzensteg launcher profile yet
  - local script exists in the Cannonball checkout
- Next cleanup:
  - Add a Katzensteg launcher profile if Cannonball remains a useful smoke target.

### Chiaki NG

- Local checkout: `/Users/robert/dev/chiaki-ng`
- Current local branch: `macos-sdl-client-build`
- Pushed fork branch: none yet; current changes are uncommitted.
- Local state: dirty.
- Uncommitted source changes:
  - `CMakeLists.txt`
  - `test/CMakeLists.txt`
  - modified `third-party/cpp-steam-tools` submodule state
- Untracked local files:
  - `.codex-tmp/`
  - `scripts/run-chiaki-sdl-from-gui.py`
  - `sdl/`
  - `test/macos_no_cpp_steam_tools_dylib.cmake`
- Local change shape:
  - CMake changes
  - SDL client/proxy work
  - Steam tools test/build changes
- Launcher profile coverage:
  - `chiaki.sdl`
  - `chiaki.sdl.child`
- Next cleanup:
  - Separate build-system changes from the SDL client/proxy code.
  - Decide whether the Python wrapper script should live in the fork or be replaced by a launcher feature.
  - Record exact submodule commit/state before pushing a branch.

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

- Done:
  - created `rjwittams` fork remotes for RetroArch, Moonlight Qt, ScummVM, Cannonball, Chiaki NG, and ANESE
  - pushed RetroArch committed app-side work to `rjwittams/macos-sdl2-video-output`
  - pushed Moonlight SDL renderer work to `rjwittams/macos-sdl-renderer-output`
  - pushed Cannonball macOS build fixes to `rjwittams/macos-sdl2-build-fixes`
  - moved Moonlight dirty work from `master` to `macos-sdl-renderer-output`
  - moved Cannonball dirty work from `master` to `macos-sdl2-build-fixes`
  - moved Chiaki dirty work from `main` to `macos-sdl-client-build`
- Still needed:
  - split and commit dirty work in RetroArch and Chiaki NG
  - push those branch commits to the `rjwittams` forks
  - decide whether Cannonball needs a first-class launcher profile
  - add bootstrap metadata after source branches settle
