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

| Project | Fork | Purpose | Profile coverage | Notes |
| --- | --- | --- | --- | --- |
| RetroArch | [`rjwittams/RetroArch`](https://github.com/rjwittams/RetroArch) | Emulator workloads through SDL2, GL-adjacent, and Vulkan-adjacent paths | `sonic`, `smw`, `sm64ds`, `jsr` | Uses forked branches for macOS video/input and context-driver behavior. |
| ScummVM | [`rjwittams/scummvm`](https://github.com/rjwittams/scummvm) | SDL software/surface behavior | `mi2` | Currently useful without app-side patches. |
| Moonlight Qt | [`rjwittams/moonlight-qt`](https://github.com/rjwittams/moonlight-qt) | Streaming/video workload through an SDL renderer path | `moonlight.steam` | Uses an SDL renderer-output branch; mouse behavior remains an open investigation. |
| Cannonball | [`rjwittams/cannonball`](https://github.com/rjwittams/cannonball) | Simple SDL app target | `cannonball` | Uses a small build-fix branch. |
| Chiaki NG | [`rjwittams/chiaki-ng`](https://github.com/rjwittams/chiaki-ng) | Stream client prototype | `chiaki.sdl` | Uses an SDL stream-only frontend branch. |
| ANESE | [`rjwittams/ANESE`](https://github.com/rjwittams/ANESE) | Small SDL emulator target | `anese.test`, `smb3` | Currently useful without app-side patches. |

## Local Data

Game data, ROMs, credentials, pairing state, and media are intentionally not tracked here. Profiles should use local paths or private profile directories for that data.

Use `--dry-run` to inspect what a profile expects before launching it.
