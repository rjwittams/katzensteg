# CLAUDE.md

Orientation for coding agents working in this repo. Keep this file short: it's an entry point, not a manual. Current tracked project docs live directly under `docs/`, especially the architecture, roadmap, launcher, external-project, and development notes.

## What this repo is

Two things, in one Zig + C codebase:

- **`termscene`** (`src/termscene/`) — reusable terminal graphics engine. Scene model, types, backend abstraction, kitty-protocol backend.
- **`Katzensteg`** (`src/katzensteg/`) — the active workstream. A preload library (`LD_PRELOAD` on Linux, `DYLD_INSERT_LIBRARIES` on macOS) that interposes on SDL2 / GL / (optionally) Vulkan calls from a target app and mirrors its output to a terminal via `/dev/tty`. Includes a launcher, a JSON profile system, frame composition, and a client to a separate inspector service.

Demos in-repo: `ttytris` (Tetris stress test on termscene), `termscene-demo`, `basic-sdl-demo` (SDL bring-up target), plus a couple of kitty-protocol repro tools.

The browser inspector and Python proxy that used to live here have been removed on purpose — the canonical inspector is the separate **`whiskers`** repo (`~/dev/whiskers`). This repo carries only producer-side instrumentation and `whiskers_client.zig`. Connect via `KATZENSTEG_WHISKERS_SOCKET=/tmp/whiskers.sock`. Do not re-introduce an embedded inspector here.

## Repo layout

```
src/termscene/      reusable engine + kitty backend
src/katzensteg/     preload runtime, launcher, frame builder, inspector client, C interposers
examples/           ttytris, termscene-demo, kitty-* repros
profiles/           JSON launcher profiles (retroarch, moonlight, scummvm, chiaki, media, probes, …)
                    plus platform Vulkan layer manifests under profiles/vulkan/
scripts/katzensteg/ Python helpers + tests; legacy run-*.sh wrappers (see "Running things")
docs/              current project docs; historical/agent-oriented notes are archived outside the repo
.github/workflows/  claude-code-review.yml — automated PR review
```

## Build

- Zig **0.15.2** is the expected toolchain for current Linux work. Verify with `zig version`; do not assume a distro Zig package is acceptable if it differs.
- No `build.zig.zon` yet; system libs (SDL2, libyuv on Linux) are required.
- Linux currently forces LLVM codegen in `build.zig`. Do not flip this back to non-LLVM/system-linker experiments casually: current Arch/CachyOS toolchains have hit `.sframe` relocation failures on that path.

```bash
zig build -Doptimize=Debug          # default full build, including Vulkan
zig build test                      # default unit-test gate
```

`zig build -Dvulkan=false` is only a narrow diagnostic for hosts that are actively
missing Vulkan dependencies, or for isolating non-Vulkan failures. Do not use it
as the main verification command, and do not stop there after build-system,
profile, launcher, Linux packaging, or Vulkan-adjacent changes. If you use the
reduced build, state why and follow it with the default Vulkan-enabled
`zig build` / `zig build test` as soon as dependencies allow.

Artifacts (under `zig-out/`):

- `bin/katzensteg` — the launcher (canonical entry point for running apps).
- `bin/katzensteg-proxy` — proxy used by some profiles.
- `bin/basic-sdl-demo`, `bin/ttytris`, `bin/termscene-demo` — demos.
- `bin/katzensteg-{gl,input,vulkan}-probe` — probe binaries.
- `lib/libkatzensteg.so` — fully linked preload.
- `lib/libkatzensteg-unlinked.so` — preload that allows unresolved SDL/GL symbols (used by most profiles).
- `lib/libkatzensteg-vulkan-layer.so` — Vulkan capture layer.

## Running things

**Use the launcher.** It resolves a JSON profile, expands `{repo}` / `{home}`, sets `LD_PRELOAD` / `DYLD_INSERT_LIBRARIES`, and execs the target.

```bash
./zig-out/bin/katzensteg                    # list available profiles
./zig-out/bin/katzensteg --dry-run <name>   # show resolved env + argv without running
./zig-out/bin/katzensteg <profile>          # run
```

Useful env vars: `KATZENSTEG_PROFILE_DIR`, `KATZENSTEG_REPO`, `KATZENSTEG_WHISKERS_SOCKET`, `KATZENSTEG_PROXY_PROFILE`.

The `scripts/katzensteg/run-*.sh` wrappers are **legacy**. The intent is the launcher reaches parity and we delete them. Don't add new ones; when fixing something a wrapper does, fix it in the launcher / a profile instead.

Direct preload commands are diagnostic-only. Prefer adding or fixing a launcher profile once a command becomes repeatable.

## Logging

- **File-based only** in the preload path. Do not write to stdout/stderr from inside an interposed app — it corrupts the terminal we're rendering into.
- Logs land at `/tmp/katzensteg-*.log`.

## Testing

State of play:

- `zig build test` runs the core file-level Zig unit suites.
- Python `unittest` scripts live under `scripts/katzensteg/` (`test_bootstrap_external_projects.py`, `test_image_fastpath_portable.py`, `test_linux_preload_exports.py`, `test_katzensteg_banner.py`, and focused smoke/regression tests).
- External app/bootstrap checks via `scripts/katzensteg/bootstrap_external_projects.py --doctor-only --root ~/dev` plus project-specific build modes.

Test coverage is becoming a focus — agents adding non-trivial logic should add tests rather than rely on real-app iteration.

## Docs

Start with `docs/architecture.md` and `docs/roadmap.md` for current direction, `docs/launcher.md` for the profile system, `docs/external-projects.md` for app forks, and `docs/development.md` for build/test/logging.

Historical design notes, implementation plans, and agent-oriented handoffs were moved out of tree to `~/Documents/katzensteg/doc-archive/`.

## Conventions

- Prefer editing the launcher / a profile over adding shell scripts.
- Keep producer-side instrumentation here; new inspector UI work goes in `whiskers`.
- Linux: keep `build.zig`'s LLVM-codegen setting unless you have revalidated the `.sframe`/linker behavior on the target distro.
- Preload code must not write to stdout/stderr (file logging only).
- Vulkan capture should pass the original external framebuffer format through to the preload/present layer (`ExternalFramebufferFormat`) instead of normalizing in `vulkan_layer.c`. Format conversion belongs in the present path so queued stale frames can be dropped before conversion and future format-specific fast paths have one owner.
- For GitHub publishing, use normal `git` and `gh` commands with work-focused branch names, commit messages, and PR titles. Do not prefix PRs or branches with the coding agent name, and do not use workflows that encode agent-specific naming conventions such as `github:yeet`.

## Architecture boundaries

- Treat input as a source/model/adapter pipeline. Platform input sources read raw input; the canonical Katzensteg input model owns event queue, current state, timestamps, routing state, and future Katzensteg-native bindings; SDL interpose functions only project that model into SDL APIs.
- Do not use graphics or presentation code as an input side channel. Frame/composite code may render cursor state it is handed, but must not sample terminal mouse position, SDL state, or mutate input state directly.
- SDL event APIs (`SDL_PollEvent`, `SDL_PeepEvents`, `SDL_PumpEvents`) may refresh input ingestion, but should feed the same canonical input model. Avoid adding parallel event queues or per-API input semantics.
- SDL state APIs (`SDL_GetMouseState`, `SDL_GetKeyboardState`, relative mouse state, etc.) should read from the same model as event APIs. If a program uses a new SDL input API, cover it as another adapter projection, not as a separate behavior path.
- Platform-specific input details belong at the source layer. `/dev/tty` is one source, not the input architecture; keep room for Windows/other terminal input sources.
- Fast paths are acceptable when they preserve ownership boundaries: they may skip work inside a layer, but should not move policy, format conversion, routing, or input semantics into a lower-level layer just because it is convenient.
