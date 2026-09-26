# External Projects

Katzensteg's most useful tests are real applications, but several of those applications need local forks or build modes so they expose an output/input path Katzensteg can currently exercise. This document tracks those external projects and explains what the bootstrap helper is trying to verify.

The external projects are not vendored into this repository.

## Why Forks Exist

Some larger targets normally prefer Cocoa, Qt, OpenGL, Vulkan, Metal, or other platform-specific frontends. For Katzensteg testing, they may need patches that:

- enable an SDL2 video driver on a platform where it is not normally offered
- force a software or SDL renderer path
- make SDL input available
- avoid an extra native bootstrap window
- add small build fixes for local development

Branch names should describe the app-side change, not Katzensteg itself. Good examples:

- `macos-sdl2-video-output`
- `macos-sdl-renderer-output`
- `macos-sdl-client-build`
- `macos-vulkan-sdl-output`

## Bootstrap Helper

`scripts/katzensteg/bootstrap_external_projects.py` is pre-alpha automation for checking the expected local smoke-test workspace.

It is meant to report:

- expected local checkout paths
- upstream and fork remotes
- expected branches
- profile names that use each project
- obvious missing build/runtime pieces
- notes for manual build steps

It is not a package manager, and it should be expected to break until it has been tested on more machines.

Useful commands:

```sh
scripts/katzensteg/bootstrap_external_projects.py --doctor-only --root ~/dev
scripts/katzensteg/bootstrap_external_projects.py --dry-run --root ~/dev
```

## Current Matrix

| Project | Fork | Branch | Purpose | Profile coverage | Windows | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| RetroArch | [`rjwittams/RetroArch`](https://github.com/rjwittams/RetroArch) | `macos-sdl2-window-contexts` | Emulator workloads through SDL2, GL-adjacent, and Vulkan-adjacent paths | `sonic`, `smw`, `sm64ds`, `jsr` | not yet tried | Uses forked branches for macOS video/input and context-driver behavior. |
| Flycast | [`rjwittams/flycast`](https://github.com/rjwittams/flycast) | `libretro-hide-symbols` | Dreamcast libretro core used by RetroArch profiles | `jsr` | not yet tried | Needed on Linux to avoid libretro core linking issues. |
| ScummVM | upstream | `master` | SDL software/surface behavior | `mi2`, `scummvm.launcher`, `bass` | builds; run pending | Currently useful without app-side patches. |
| Moonlight Qt | [`rjwittams/moonlight-qt`](https://github.com/rjwittams/moonlight-qt) | `macos-sdl-renderer-output` | Streaming/video workload through an SDL renderer path | `moonlight.steam` | not yet tried | Uses an SDL renderer-output branch; mouse behavior remains an open investigation. |
| Cannonball | [`rjwittams/cannonball`](https://github.com/rjwittams/cannonball) | `windows-sdl2-build` | Simple SDL app target | `cannonball` | builds; blocked on ROMs | `windows-sdl2-build` is `macos-sdl2-build-fixes` plus a Windows CMake target. |
| Chiaki NG | [`rjwittams/chiaki-ng`](https://github.com/rjwittams/chiaki-ng) | `macos-sdl-client-build` | Stream client prototype | `chiaki.sdl` | not yet tried | Uses an SDL stream-only frontend branch. |
| ANESE | upstream | `master` | Small SDL emulator target | `anese.test`, `anese.2048` | working | Currently useful without app-side patches. |

## Windows

Status observed on Beaufort (Windows 11) on 2026-09-25, running each app
through the launcher with `injection=dynapi` in a Wheelhouse Cleat pane, with
the official SDL 2.32.10 `SDL2.dll`. See [development.md](development.md#windows)
for building Katzensteg itself.

`SDL_DYNAMIC_API` only reaches an SDL that exports `SDL_DYNAPI_entry` from a
shared library, so every Windows build here links `SDL2.dll` through the
import library in the official Visual C++ development package
(`SDL2-devel-<version>-VC.zip`) and runs with the official `SDL2.dll` copied
beside the executable. An application that links SDL statically cannot be
used this way.

The bootstrap helper's Windows build commands run in `cmd.exe` and expect an
x64 Visual Studio developer prompt (Visual Studio 2022 Build Tools with the C++
workload provide `cl`, `msbuild`, CMake and Ninja) and `SDL2` set to the
development package's `SDL2-<version>` directory. Its doctor checks for
`%SDL2%\lib\x64\SDL2.dll` and the Windows build outputs.

- **ANESE** (upstream `master`, unmodified): builds with MSVC, CMake and
  Ninja. The `anese.2048` profile runs the homebrew 2048 demo that ships in
  `roms/demos`. The title screen and the game render in the pane; Enter starts
  a game and the arrow keys move the tiles. Arrow keys arrive without
  releases from Wheelhouse (flotilla-org/wheelhouse#85), so a direction
  registers once until another key is pressed.
- **Cannonball** (`windows-sdl2-build`): the fork's `win64-sdl2.cmake` target
  builds with MSVC against the SDL2 development package and header-only Boost,
  renders through SDL's surface path, and takes DirectInput from the Windows
  SDK. It links `SDL2.dll`. Without the OutRun revision B ROMs, which are not
  freely available, it exits before its first SDL call, so nothing has been
  rendered on Windows yet.
- **ScummVM** (upstream `master`, unmodified): builds with MSVC through
  `create_project` and MSBuild, with only the `sky` and `queen` engines (the
  freeware games) and no optional libraries, and links `SDL2.dll`. The
  `bass` profile runs the freeware Beneath a Steel Sky from
  `$HOME/roms/bass`, and `scummvm.launcher` shows the launcher without game
  data. Neither has been run in a pane yet.

Katzensteg changes this needed: `$HOME` in profiles falls back to
`USERPROFILE`, `KATZENSTEG_PROFILE_DIR` separates directories with `;`,
initialization runs on a large stack because MSVC applications reserve only
1 MiB for their main thread, and projected input events carry the
application's SDL window ID, which ANESE requires.

## Jackstay capture viewer

`jackstay-viewer` in `profiles/jackstay.json` is a local development profile.
It expects a Porthole checkout under `~/dev/porthole` and a separately built
SDL capture viewer at `target/capture-viewer-sdl/capture-viewer-sdl` inside that
checkout. Katzensteg's build and bootstrap helper do not build this viewer.
Follow the Porthole checkout's build instructions and pass its connection
arguments after the profile name. Use a private profile override if the viewer
is built elsewhere; `katzensteg --dry-run jackstay-viewer` shows the resolved path.

## Local Data

Game data, ROMs, credentials, pairing state, and media are intentionally not tracked here. Profiles should use local paths or private profile directories for that data.

Use `--dry-run` to inspect what a profile expects before launching it.

Optional native CPU publishing and presentation are documented in
[Jackstay connectors](jackstay.md), including the pinned dependency build.
