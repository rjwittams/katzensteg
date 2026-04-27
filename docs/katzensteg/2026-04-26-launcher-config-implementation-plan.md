# Katzensteg Launcher Config Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a typed Katzensteg config model and shell-like launcher that replaces duplicated run-script policy while preserving current environment-variable workflows.

**Architecture:** Add typed runtime and launch config modules, then add a `katzensteg` launcher executable that resolves profiles into child process environment plus a generated `KATZENSTEG_CONFIG` JSON file. Keep runtime terminal presentation in-process; the launcher only draws before launch and after child exit.

**Tech Stack:** Zig 0.15.2, existing `std.json` runtime config handoff, POSIX process spawning, current Katzensteg preload/runtime modules, optional TOML parser investigation before choosing profile syntax.

---

## Source Documents

- Design: `docs/katzensteg/2026-04-26-launcher-config-design.md`
- Roadmap: `docs/katzensteg/2026-04-25-roadmap.md`
- Input/window policy: `docs/katzensteg/2026-04-25-phase-2-input-window-policy.md`

## File Map

- Create `tools/katzensteg/config.zig`: typed runtime config structs, field metadata, JSON parsing, environment override helpers.
- Create `tools/katzensteg/launcher.zig`: launcher entry point, CLI parsing, profile resolution, process spawn, terminal pre/post output.
- Create `tools/katzensteg/launcher_profiles.zig`: profile structs, inheritance resolver, path/env expansion, profile file parser facade.
- Create `tools/katzensteg/profiles/example.json` or `tools/katzensteg/profiles/example.toml`: initial profile examples.
- Modify `tools/katzensteg/runtime.zig`: replace local `RuntimeConfig` and config parsing with `config.zig`.
- Modify `tools/katzensteg/preload.zig`: consume config helpers where preload-only env parsing should be shared or documented.
- Modify `build.zig`: build/install `katzensteg` launcher executable and add focused test steps if useful.
- Modify representative scripts as compatibility shims after the launcher exists:
  - `tools/katzensteg/run-retroarch-sonic.sh`
  - `tools/katzensteg/run-retroarch-vulkan.sh`
  - `tools/katzensteg/run-scummvm-monkey2.sh`
  - `tools/katzensteg/run-moonlight-steam-big-picture.sh`

## Chunk 1: Runtime Config Module

### Task 1: Move Existing Runtime Config Into `config.zig`

**Files:**
- Create: `tools/katzensteg/config.zig`
- Modify: `tools/katzensteg/runtime.zig`
- Test: `zig test tools/katzensteg/config.zig`

- [ ] **Step 1: Write config tests for existing fields**

Cover JSON parsing for:

- `composite_mode`
- `intercept_mode`
- `window_policy`
- `real_window`
- `present_fps`

Expected behavior: defaults match current `runtime.zig`; JSON overrides defaults; invalid values are logged and ignored.

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```sh
zig test tools/katzensteg/config.zig
```

Expected: fail because `config.zig` does not exist yet.

- [ ] **Step 3: Implement `RuntimeConfig` in `config.zig`**

Move the existing `RuntimeConfig` shape and parsing helpers from `runtime.zig` into `config.zig`. Keep behavior identical.

- [ ] **Step 4: Wire `runtime.zig` to use `config.zig`**

Replace the local `RuntimeConfig` definition and local `loadConfig` call with `config.loadRuntimeConfig`.

- [ ] **Step 5: Verify behavior**

Run:

```sh
zig test tools/katzensteg/config.zig
zig build -freference-trace
```

Expected: tests pass and the project builds.

- [ ] **Step 6: Commit**

```sh
git add tools/katzensteg/config.zig tools/katzensteg/runtime.zig build.zig
git commit -m "refactor: split katzensteg runtime config"
```

Only include `build.zig` if this task needed build-file changes.

### Task 2: Add Runtime Field Metadata

**Files:**
- Modify: `tools/katzensteg/config.zig`
- Test: `zig test tools/katzensteg/config.zig`

- [ ] **Step 1: Add tests for metadata lookup**

Test that metadata exists for each initial runtime field and exposes:

- field name
- environment override name
- default mutability class
- hot-apply or restart-required classification

- [ ] **Step 2: Implement metadata structs**

Add a small table of `RuntimeFieldMetadata` values. Prefer simple static data over reflection-heavy machinery.

- [ ] **Step 3: Classify existing fields**

Initial classification:

- hot apply: `window_policy`, `real_window`, `present_fps`
- restart required for now: `composite_mode`, `intercept_mode`

This can be relaxed later as runtime support grows.

- [ ] **Step 4: Verify**

Run:

```sh
zig test tools/katzensteg/config.zig
zig build -freference-trace
```

Expected: metadata tests and build pass.

- [ ] **Step 5: Commit**

```sh
git add tools/katzensteg/config.zig
git commit -m "feat: describe katzensteg runtime config fields"
```

### Task 3: Expand Runtime Config Coverage

**Files:**
- Modify: `tools/katzensteg/config.zig`
- Modify: `tools/katzensteg/runtime.zig`
- Modify: `tools/katzensteg/preload.zig` if shared parsing is useful
- Test: `zig test tools/katzensteg/config.zig`

- [ ] **Step 1: Add tests for env-compatible fields**

Add tests for parsing and env override behavior for:

- `input`
- `input_claim`
- `gamepad_background`
- `stats`
- `image_gc`
- `kitty_debug_replies`
- `composite_dump`
- `composite_debug`
- `output_profile`
- `file_transport`
- `file_transport_max_bytes`
- `gl_capture`
- `vulkan_capture`

- [ ] **Step 2: Implement parsing without changing defaults**

Defaults must preserve current behavior when no config/env is provided.

- [ ] **Step 3: Update runtime/preload consumers incrementally**

Replace ad hoc `std.c.getenv` parsing only where doing so is low-risk. Keep env names compatible.

- [ ] **Step 4: Verify**

Run:

```sh
zig test tools/katzensteg/config.zig
zig build -freference-trace
```

Expected: tests pass; existing scripts still launch with their env variables.

- [ ] **Step 5: Commit**

```sh
git add tools/katzensteg/config.zig tools/katzensteg/runtime.zig tools/katzensteg/preload.zig
git commit -m "feat: expand katzensteg runtime config coverage"
```

## Chunk 2: Launcher Skeleton

### Task 4: Add Minimal `katzensteg` Launcher Executable

**Files:**
- Create: `tools/katzensteg/launcher.zig`
- Modify: `build.zig`
- Test: `zig build katzensteg-launcher-help` if adding a build step, otherwise `zig build -freference-trace`

- [ ] **Step 1: Write a help-output test or smoke step**

Expected command:

```sh
zig build -freference-trace
./zig-out/bin/katzensteg --help
```

Expected output should include `katzensteg [options] <target>`.

- [ ] **Step 2: Add launcher executable to `build.zig`**

Build name: `katzensteg`.

- [ ] **Step 3: Implement CLI skeleton**

Support:

- `katzensteg --help`
- `katzensteg [options] <target>`
- useful error for unknown commands

A non-profile target can remain unsupported in this task, but the CLI shape should be direct target syntax.

- [ ] **Step 4: Verify**

Run:

```sh
zig build -freference-trace
./zig-out/bin/katzensteg --help
./zig-out/bin/katzensteg retroarch.sonic
```

Expected: build passes; help prints; unknown targets return a controlled resolution error.

- [ ] **Step 5: Commit**

```sh
git add build.zig tools/katzensteg/launcher.zig
git commit -m "feat: add katzensteg launcher skeleton"
```

### Task 5: Add Profile Structs and JSON/ZON Parser First

**Files:**
- Create: `tools/katzensteg/launcher_profiles.zig`
- Create: `tools/katzensteg/profiles/example.json`
- Modify: `tools/katzensteg/launcher.zig`
- Test: `zig test tools/katzensteg/launcher_profiles.zig`

- [ ] **Step 1: Investigate TOML cost before coding parser support**

Check whether the repo already has a TOML parser dependency or whether adding one is simple. If not, start with JSON/ZON profile syntax and keep the parser behind a facade.

- [ ] **Step 2: Write tests for profile parsing**

Cover:

- target
- args
- cwd
- env map
- stdout/stderr policy
- runtime config subsection

- [ ] **Step 3: Implement profile structs**

Keep the first syntax small. Do not implement every script quirk yet.

- [ ] **Step 4: Connect launcher to profile loader**

`katzensteg [options] <target>` should search repo-local profiles first and print the resolved profile without spawning.

- [ ] **Step 5: Verify**

Run:

```sh
zig test tools/katzensteg/launcher_profiles.zig
zig build -freference-trace
./zig-out/bin/katzensteg example --dry-run
```

Expected: tests pass; dry-run prints resolved launch/runtime config.

- [ ] **Step 6: Commit**

```sh
git add tools/katzensteg/launcher_profiles.zig tools/katzensteg/launcher.zig tools/katzensteg/profiles/example.json
git commit -m "feat: load katzensteg launcher profiles"
```

### Task 6: Add Profile Inheritance

**Files:**
- Modify: `tools/katzensteg/launcher_profiles.zig`
- Modify: `tools/katzensteg/profiles/example.json`
- Test: `zig test tools/katzensteg/launcher_profiles.zig`

- [ ] **Step 1: Add inheritance tests**

Cover deterministic merge behavior:

- inherited fragments apply in listed order
- profile-local fields win
- env maps merge
- args arrays replace

- [ ] **Step 2: Implement resolver**

Keep cycles and missing fragments as explicit errors.

- [ ] **Step 3: Verify**

Run:

```sh
zig test tools/katzensteg/launcher_profiles.zig
zig build -freference-trace
```

Expected: inheritance tests pass.

- [ ] **Step 4: Commit**

```sh
git add tools/katzensteg/launcher_profiles.zig tools/katzensteg/profiles/example.json
git commit -m "feat: resolve katzensteg launcher profile inheritance"
```

## Chunk 3: Process Launch and Runtime Handoff

### Task 7: Generate Runtime JSON and Spawn Child

**Files:**
- Modify: `tools/katzensteg/launcher.zig`
- Modify: `tools/katzensteg/launcher_profiles.zig`
- Test: manual dry-run and a harmless command profile

- [ ] **Step 1: Add a harmless test profile**

Use a command such as `/usr/bin/env` or `/bin/echo` so process spawning can be tested without SDL.

- [ ] **Step 2: Generate temporary runtime JSON**

Write resolved runtime config to a temp file and add `KATZENSTEG_CONFIG=<path>` to the child environment.

- [ ] **Step 3: Spawn the child**

Use Zig process APIs. Preserve cwd and env behavior from the resolved profile.

- [ ] **Step 4: Add log redirection**

Support stdout/stderr to terminal, file, and stderr-to-stdout.

- [ ] **Step 5: Verify**

Run:

```sh
zig build -freference-trace
./zig-out/bin/katzensteg example.env-test
```

Expected: child receives generated `KATZENSTEG_CONFIG` and configured env.

- [ ] **Step 6: Commit**

```sh
git add tools/katzensteg/launcher.zig tools/katzensteg/launcher_profiles.zig tools/katzensteg/profiles/example.json
git commit -m "feat: launch processes from katzensteg profiles"
```

### Task 8: Add Preflight, Cleanup, and Terminal Reset

**Files:**
- Modify: `tools/katzensteg/launcher.zig`
- Modify: `tools/katzensteg/launcher_profiles.zig`

- [ ] **Step 1: Add profile cleanup fields**

Support removal of stale known temp paths before launch. Do not glob widely in the first version.

- [ ] **Step 2: Add preflight output**

Print target, args, key env choices, log paths, and generated config path before spawning.

- [ ] **Step 3: Add post-exit output**

After child exit, print exit code/signal and log paths.

- [ ] **Step 4: Add terminal reset**

Emit conservative reset sequences after child exit. Keep runtime exit hooks too; this is a second layer.

- [ ] **Step 5: Verify**

Run a harmless profile and interrupt it with Ctrl-C. Confirm terminal state is usable afterwards.

- [ ] **Step 6: Commit**

```sh
git add tools/katzensteg/launcher.zig tools/katzensteg/launcher_profiles.zig
git commit -m "feat: add katzensteg launcher supervision"
```

## Chunk 4: Migrate Representative Profiles

### Task 9: Migrate Sonic RetroArch Profile

**Files:**
- Create or modify: `tools/katzensteg/profiles/retroarch.json`
- Modify: `tools/katzensteg/run-retroarch-sonic.sh`

- [ ] **Step 1: Encode current script behavior as a profile**

Preserve current user-edited behavior in `run-retroarch-sonic.sh`, including `RETROARCH_COCOA_BOOTSTRAP_WINDOW=0` if present.

- [ ] **Step 2: Convert script to a shim**

The script should call `zig-out/bin/katzensteg retroarch.sonic` or build first if that matches current script style.

- [ ] **Step 3: Verify**

Run:

```sh
zig build -freference-trace
tools/katzensteg/run-retroarch-sonic.sh
```

Expected: Sonic launches through the same terminal path as before.

- [ ] **Step 4: Commit**

```sh
git add tools/katzensteg/profiles/retroarch.json tools/katzensteg/run-retroarch-sonic.sh
git commit -m "feat: launch retroarch sonic via katzensteg profile"
```

### Task 10: Migrate Vulkan RetroArch Profile

**Files:**
- Modify: `tools/katzensteg/profiles/retroarch.json`
- Modify: `tools/katzensteg/run-retroarch-vulkan.sh`

- [ ] **Step 1: Model Vulkan layer env**

Include `VK_INSTANCE_LAYERS`, `VK_LAYER_PATH`, and any loader path currently required.

- [ ] **Step 2: Model generated RetroArch config**

Support the current generated Vulkan config append behavior.

- [ ] **Step 3: Convert script to a shim**

Keep the script name stable.

- [ ] **Step 4: Verify**

Run the Vulkan probe or the current RetroArch Vulkan target.

- [ ] **Step 5: Commit**

```sh
git add tools/katzensteg/profiles/retroarch.json tools/katzensteg/run-retroarch-vulkan.sh
git commit -m "feat: launch retroarch vulkan via katzensteg profile"
```

### Task 11: Migrate ScummVM and Moonlight Profiles

**Files:**
- Create or modify: `tools/katzensteg/profiles/scummvm.json`
- Create or modify: `tools/katzensteg/profiles/moonlight.json`
- Modify: `tools/katzensteg/run-scummvm-monkey2.sh`
- Modify: `tools/katzensteg/run-moonlight-steam-big-picture.sh`

- [ ] **Step 1: Encode ScummVM launch behavior**

Preserve renderer/env choices and stdout/stderr handling.

- [ ] **Step 2: Encode Moonlight launch behavior**

Preserve decoder/color-format forcing env choices from the current script.

- [ ] **Step 3: Convert scripts to shims**

Keep current script paths as muscle-memory entry points.

- [ ] **Step 4: Verify manually**

Run both scripts. For Moonlight, a quick connect/display sanity check is enough.

- [ ] **Step 5: Commit**

```sh
git add tools/katzensteg/profiles/scummvm.json tools/katzensteg/profiles/moonlight.json tools/katzensteg/run-scummvm-monkey2.sh tools/katzensteg/run-moonlight-steam-big-picture.sh
git commit -m "feat: launch scummvm and moonlight via katzensteg profiles"
```

## Chunk 5: Documentation and Follow-Up Hooks

### Task 12: Document Launcher Usage

**Files:**
- Modify: `docs/katzensteg/2026-04-26-launcher-config-design.md`
- Create or modify: `docs/katzensteg/launcher-usage.md`

- [ ] **Step 1: Add user-facing usage examples**

Cover:

- list profiles
- dry-run a profile
- launch a profile
- override a runtime option
- find logs after exit

- [ ] **Step 2: Document mutability classes**

Explain hot-apply versus restart-required fields.

- [ ] **Step 3: Verify docs against actual CLI help**

Run:

```sh
./zig-out/bin/katzensteg --help
./zig-out/bin/katzensteg --help
```

Expected: docs and help agree.

- [ ] **Step 4: Commit**

```sh
git add docs/katzensteg/2026-04-26-launcher-config-design.md docs/katzensteg/launcher-usage.md
git commit -m "docs: document katzensteg launcher usage"
```

### Task 13: Leave Hooks for Runtime Control UI

**Files:**
- Modify: `tools/katzensteg/config.zig`
- Modify: `tools/katzensteg/inspector.zig` only if there is a small obvious metadata exposure point

- [ ] **Step 1: Add a config metadata dump helper**

Return field metadata in a simple serializable shape. Do not build the full menu yet.

- [ ] **Step 2: Add tests**

Verify metadata can be serialized without allocation leaks or invalid enum names.

- [ ] **Step 3: Verify**

Run:

```sh
zig test tools/katzensteg/config.zig
zig build -freference-trace
```

Expected: tests and build pass.

- [ ] **Step 4: Commit**

```sh
git add tools/katzensteg/config.zig tools/katzensteg/inspector.zig
git commit -m "feat: expose katzensteg config metadata"
```

## Final Verification

- [ ] Run focused config tests:

```sh
zig test tools/katzensteg/config.zig
zig test tools/katzensteg/launcher_profiles.zig
```

- [ ] Run full build:

```sh
zig build -freference-trace
```

- [ ] Smoke-test non-SDL launcher profile:

```sh
./zig-out/bin/katzensteg example.env-test
```

- [ ] Smoke-test representative app profiles:

```sh
tools/katzensteg/run-retroarch-sonic.sh
tools/katzensteg/run-vulkan-probe.sh
tools/katzensteg/run-scummvm-monkey2.sh
```

- [ ] Confirm terminal reset after normal exit and Ctrl-C.

- [ ] Confirm old env-variable launch path still works without launcher.

Plan complete and saved to `docs/katzensteg/2026-04-26-launcher-config-implementation-plan.md`. Ready to execute?
