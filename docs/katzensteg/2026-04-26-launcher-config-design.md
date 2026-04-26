# Katzensteg Launcher and Config Design

## Purpose

Katzensteg has grown past one-off launch scripts. The current scripts know about preload libraries, Vulkan layers, RetroArch cores, Moonlight decoder choices, log redirection, cleanup, terminal reset, and app-specific quirks. A launcher should consolidate that policy while keeping the runtime in control of terminal presentation while the target app is running.

The launcher is shell-like:

- It may draw preflight/status output before launching the child.
- It should not draw while the child app and Katzensteg runtime own the terminal.
- It should reset the terminal, report exit/crash status, and point at logs after the child exits.

The runtime remains responsible for simultaneous terminal graphics, input capture, image placement, inspector state, and any in-game chrome.

## Boundaries

### Launcher-Owned

- Resolve named profiles such as `retroarch.sonic`, `retroarch.vulkan.melonds`, `scummvm.monkey2`, or `moonlight.steam`.
- Pick the appropriate preload/intercept components.
- Set launch-only environment such as `DYLD_INSERT_LIBRARIES`, `LD_PRELOAD`, `VK_INSTANCE_LAYERS`, `VK_LAYER_PATH`, and app-specific variables.
- Generate temporary app config files, such as RetroArch configs.
- Generate the runtime config file passed through `KATZENSTEG_CONFIG`.
- Redirect stdout/stderr to logs when requested.
- Remove stale sockets, logs, temporary image files, and generated configs when safe.
- Draw simple preflight and post-exit terminal UI.
- Perform best-effort terminal reset after app exit or crash.

### Runtime-Owned

- SDL/OpenGL/Vulkan interception once the target process is running.
- Terminal image protocol negotiation and output.
- Input capture and synthetic SDL events.
- Window policy and real-window visibility actions.
- Inspector socket, live state, and any future runtime menu/chrome.
- Hot-applying runtime settings where possible.

The launcher should not coordinate screen drawing with the runtime in the first version. If a future side-channel is added, it should be explicit rather than implicit shared terminal writes.

## Config Model

Use two related config layers.

### Launch Config

Launch config describes how to start a program:

- target executable
- arguments
- working directory
- inherited and explicit environment
- stdout/stderr policy
- preload libraries
- Vulkan layer setup
- generated app config files
- cleanup policy
- terminal reset policy

This is launcher-only and is generally not runtime mutable.

### Runtime Config

Runtime config describes Katzensteg behavior after the preload/runtime is active:

- `intercept_mode`
- `composite_mode`
- `window_policy`
- `real_window`
- `present_fps`
- `input`
- `input_claim`
- `gamepad_background`
- `stats`
- `output_profile`
- `file_transport`
- `file_transport_max_bytes`
- `gl_capture`
- `vulkan_capture`
- scaler/filter mode
- inspector/debug/socket paths

The runtime config should be represented by Zig structs with field metadata:

- default value
- environment variable compatibility name
- whether the field can be hot-applied
- whether a change requires restart

This lets the launcher, inspector, and future terminal menu talk about the same settings without inventing separate models.

## File Format

TOML is the preferred human-facing profile format if adding a Zig TOML parser is low-friction. It is easier to read than JSON for launch profiles with repeated app/env sections.

The first implementation can still keep runtime handoff as JSON because `Runtime.loadConfig` already supports `KATZENSTEG_CONFIG` through `std.json`. The launcher can parse profile TOML, resolve inheritance, then write a temporary JSON runtime config for the child.

If TOML support turns out to be awkward, start with JSON or ZON profile files and keep the schema independent of the syntax. The important part is the typed config model, not the parser choice.

Example profile shape:

```toml
[profile.retroarch.sonic]
extends = ["app.retroarch", "render.sdl", "runtime.terminal_only"]
target = "~/dev/RetroArch/RetroArch.app/Contents/MacOS/RetroArch"
args = [
  "-L",
  "~/Library/Application Support/RetroArch/cores/genesis_plus_gx_libretro.dylib",
  "~/roms/sonic.md",
]
stdout = "/tmp/retroarch-sonic.out"
stderr = "stdout"

[profile.retroarch.sonic.env]
RETROARCH_COCOA_BOOTSTRAP_WINDOW = "0"

[runtime.terminal_only]
window_policy = "terminal_only"
real_window = "show"
input = true
input_claim = true
present_fps = 0

[render.vulkan]
vulkan_layer = true
gl_capture = "disabled"
```

## Profile Inheritance

Profiles should compose from small reusable fragments:

- app fragments: RetroArch, ScummVM, Moonlight, Cannonball
- render fragments: SDL, OpenGL capture, Vulkan layer capture
- runtime fragments: mirror, terminal-only, real-only, debug, inspector-enabled
- game fragments: core path, ROM path, app-specific arguments

Resolution should be deterministic:

1. Apply inherited fragments in listed order.
2. Apply profile-local fields last.
3. Merge maps such as environment variables.
4. Replace arrays such as args unless a later append operation is explicitly supported.

Keep the first version simple: full replacement for scalar/array fields, map merge for env.

## Runtime Mutability Classes

Classify settings explicitly.

Hot-apply candidates:

- `window_policy`
- `real_window`
- `input`
- `input_claim`
- `gamepad_background`
- `present_fps`
- `stats`
- scaler/filter mode
- selected debug overlays

Restart-required settings:

- preload library choice
- Vulkan layer activation
- Vulkan loader path
- target app, args, cwd
- generated app config
- stdout/stderr policy
- most app-specific environment
- initial intercept mode, unless later made dynamically switchable

This classification should be visible to future inspector/menu UI so it can show which changes apply immediately and which require relaunch.

## Initial Implementation Phases

### Phase 1: Schema and Runtime Config Coverage

- Create typed Zig config structs for launch and runtime config.
- Expand `Runtime.loadConfig` coverage beyond the current JSON keys.
- Preserve existing environment variables as compatibility overrides.
- Add tests for config parsing, defaults, env override precedence, and mutability metadata.

### Phase 2: Launcher Skeleton

- Add a `katzensteg launch <profile>` command.
- Load a profile file.
- Resolve inheritance.
- Generate runtime JSON.
- Spawn the child with configured env, cwd, args, and log redirection.
- Reset terminal and report status after exit.

### Phase 3: Migrate Existing Scripts

Migrate representative scripts first:

1. `run-retroarch-sonic.sh`
2. `run-retroarch-vulkan.sh`
3. `run-scummvm-monkey2.sh`
4. `run-moonlight-steam-big-picture.sh`

Keep script wrappers as compatibility shims that call the launcher.

### Phase 4: Runtime Control Surface

- Expose live runtime config through the inspector/control path.
- Let a future terminal menu update hot-apply fields.
- Serialize current runtime state back into profile-compatible config where practical.

## Non-Goals For The First Version

- Concurrent launcher and runtime terminal drawing.
- Full terminal chrome/menu system.
- Cross-process arbitration between multiple Katzensteg instances.
- Automatic binary inspection beyond simple profile-selected preload choices.
- Complete replacement of all scripts in the first pass.

## Open Questions

- TOML parser choice for Zig, or whether to start with JSON/ZON profiles and add TOML later.
- Exact installed search paths for user profiles versus repo-local profiles.
- Whether app-specific generated config should be modeled generically or start with small built-in generators for RetroArch.
- Whether terminal reset should live only in the launcher or also remain as a runtime best-effort exit hook.
