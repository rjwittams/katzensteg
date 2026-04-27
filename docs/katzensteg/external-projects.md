# Katzensteg External Project Inventory

This tracks local app forks used to test end-to-end SDL, OpenGL, Vulkan, and streaming paths. Branch names should describe the app-side change, not Katzensteg itself.

## Branch Naming

Use names like:

- `macos-sdl2-video-output`
- `macos-sdl2-build-fixes`
- `macos-sdl-renderer-hwdecode`
- `sdl-output-probe`
- `macos-vulkan-sdl-output`

Avoid names that only say the branch is for Katzensteg. The useful question is what the fork changes in the target project.

## Projects

### RetroArch

- Local checkout: `/Users/robert/dev/RetroArch`
- Upstream remote: `https://github.com/libretro/RetroArch.git`
- Proposed fork remote: `https://github.com/rjwittams/RetroArch.git`
- Current local branch: `robert/macos-sdl2-video-pr-cleanup`
- Suggested branch names:
  - `macos-sdl2-video-output`
  - `macos-vulkan-sdl-output`
  - `macos-gl-sdl-output`
- Local change shape:
  - macOS build and bundle work
  - SDL2 video path changes
  - GL/Vulkan context and video-driver changes
  - Cocoa bootstrap/window behavior changes
- Repo-local launch coverage:
  - `retroarch.sonic`
  - `retroarch.melonds.sm64ds`
  - legacy scripts for Sonic, bsnes/SMW, melonDS, and Vulkan/Flycast
- Notes:
  - Treat generated `RetroArch.app`, crash logs, shader build products, and bundled resources as local artifacts unless deliberately packaging a release.

### Moonlight Qt

- Local checkout: `/Users/robert/dev/moonlight-qt`
- Upstream remote: `https://github.com/moonlight-stream/moonlight-qt.git`
- Proposed fork remote: `https://github.com/rjwittams/moonlight-qt.git`
- Current local branch: `master`
- Suggested branch names:
  - `macos-sdl-renderer-hwdecode`
  - `macos-sdl-renderer-output`
- Local change shape:
  - SDL video renderer changes
  - hardware decode / format-handling experiments
  - local Qt build artifacts
- Repo-local launch coverage:
  - `moonlight.steam_big_picture`
  - legacy Steam Big Picture script
- Notes:
  - Do not carry generated qmake files, `app/release`, bundled app output, or built third-party libraries into source branches.

### ScummVM

- Local checkout: `/Users/robert/dev/scummvm`
- Upstream remote: `https://github.com/scummvm/scummvm.git`
- Proposed fork remote: `https://github.com/rjwittams/scummvm.git`
- Current local branch: `master`
- Suggested branch name:
  - `sdl2-surface-renderer-macos`
- Local change shape:
  - currently clean in the local checkout
  - used mainly to validate SDL surface/software output behavior
- Repo-local launch coverage:
  - `scummvm.monkey2`
  - legacy Monkey Island 2 script

### Cannonball

- Local checkout: `/Users/robert/dev/cannonball`
- Upstream remote: `https://github.com/djyt/cannonball.git`
- Proposed fork remote: `https://github.com/rjwittams/cannonball.git`
- Current local branch: `master`
- Suggested branch name:
  - `macos-sdl2-build-fixes`
- Local change shape:
  - CMake adjustments
  - stdint portability/build fixes
  - local config and launcher script
- Repo-local launch coverage:
  - no launcher profile yet
  - local script exists in the Cannonball checkout

### Chiaki NG

- Local checkout: `/Users/robert/dev/chiaki-ng`
- Upstream remote: `https://github.com/streetpea/chiaki-ng.git`
- Proposed fork remote: `https://github.com/rjwittams/chiaki-ng.git`
- Current local branch: `main`
- Suggested branch names:
  - `macos-sdl-client-build`
  - `macos-sdl-output-option`
- Local change shape:
  - CMake changes
  - SDL client/proxy work
  - Steam tools test/build changes
- Repo-local launch coverage:
  - legacy `run-chiaki-sdl-from-gui.sh`
- Notes:
  - `.codex-tmp` and CMake build trees are local artifacts.

### ANESE

- Local checkout: `/Users/robert/dev/ANESE`
- Upstream remote: `https://github.com/daniel5151/ANESE.git`
- Proposed fork remote: `https://github.com/rjwittams/ANESE.git`
- Current local branch: `master`
- Suggested branch name:
  - `sdl-output-probe`
- Local change shape:
  - currently clean in the local checkout
  - used as a small emulator target through a legacy script
- Repo-local launch coverage:
  - legacy `run-anese.sh`

### FFplay

- Local checkout: Homebrew/system install, not a forked local project.
- Repo-local launch coverage:
  - legacy `run-ffplay-testsrc.sh`
- Notes:
  - Keep this as a runtime smoke target rather than a source fork unless FFmpeg-specific changes become necessary.

## Next Steps

- Add `rjwittams` fork remotes once the fork URLs are confirmed.
- Split local dirty changes into focused branches using the suggested names above.
- Add launcher profiles for useful script-only targets: bsnes/SMW, Vulkan/Flycast, Cannonball, Chiaki, ANESE, and ffplay testsrc.
- Generate a bootstrap script after branch names and checkout locations settle.
