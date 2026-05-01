# Katzensteg Launcher Usage

The launcher is meant to replace one-off run scripts without taking over terminal drawing while the target app is running.

## List Profiles

```sh
./zig-out/bin/katzensteg
```

Visible profiles currently include:

- `sonic`
- `sm64ds`
- `smw`
- `jsr`
- `mi2`
- `moonlight.steam`
- `probe.input`
- `probe.vulkan`
- `ffplay.testsrc`
- `anese.test`
- `smb3`
- `cannonball`
- `chiaki.sdl`

Hidden profiles such as `adapter.sdl2_preload` and `runtime.fullscreen_file` are reusable fragments, not direct launch targets.

## Dry Run

```sh
./zig-out/bin/katzensteg sonic --dry-run
./zig-out/bin/katzensteg jsr --dry-run
./zig-out/bin/katzensteg moonlight.steam --dry-run
```

Dry-run prints the resolved target, argv, environment variables, seed files, output log, runtime mode, window policy, composite mode, and output profile.

## Launch

```sh
./zig-out/bin/katzensteg sonic
./zig-out/bin/katzensteg sm64ds
./zig-out/bin/katzensteg mi2
./zig-out/bin/katzensteg moonlight.steam
```

The launcher writes a temporary runtime JSON file, passes it through `KATZENSTEG_CONFIG`, runs the child, then performs a best-effort terminal reset and kitty image clear after exit.

Profiles may also declare seed files. The launcher creates those files only when they do not already exist, so app-managed configs such as RetroArch can keep their own later edits.

Profile string values are resolved by the launcher before spawning the child. `~`, `$HOME`, `${HOME}`, `$ROOT`, `${ROOT}`, `{repo}`, `$PATH`, and `${PATH}` are expanded in paths, args, env values, and seed file fields. A string value may also be written as a platform map, for example:

```json
"VK_LAYER_PATH": {
  "linux": "{repo}/profiles/vulkan/linux",
  "macos": "{repo}/profiles/vulkan/macos"
}
```

When an optional env value, arg, or seed file path has no value for the active platform, that item is omitted. A target with no value for the active platform is treated as a broken profile.

## JSONL Embed Mode

`--embed-jsonl` is an explicit launcher mode for hosts that own the PTY and want Katzensteg render batches on stdout:

```sh
./zig-out/bin/katzensteg --embed-jsonl probe.embed.basic_sdl
```

In this mode, launcher stdout is JSONL protocol output and launcher stdin is JSONL protocol input. The launcher stays quiet, keeps the target program stdout on the normal profile log path, and passes dedicated fds to the preloaded runtime for render batches and control messages.

The first control message that enables graphics is an `attach` for `window_id: "main"` with a cell rect, id ranges, and an upload policy. Until attach is received, the runtime suppresses graphics batches. After attach, the host may send `viewport` to resize or move the presentation rect, or `detach` to remove known placements and suppress future batches while the producer keeps running. `detach` is acknowledged with `{"type":"detached","window_id":"main"}` after cleanup output has been emitted. To close the whole producer session, the host sends `{"type":"shutdown"}` and keeps reading stdout until cleanup/lifecycle output drains or the process exits. The host may choose `direct_apc`, `file_whole`, or `file_offset_ring`; file modes include a shared upload path that the producer writes and the host passes through as terminal graphics APCs. Socket transport, target stdout events, non-kitty side channels, keyboard/mouse focus events, and multiple windows are follow-up work.

Hosts may forward input with `{"type":"input","window_id":"main","event":"terminal_bytes","bytes":"..."}`. The first WM implementation forwards non-command terminal bytes directly. Mouse escape sequences keep their absolute terminal cell coordinates; the runtime maps those cells through the current presentation layout back to SDL coordinates.

## Attach Host Mode

`attach` is the terminal-owning host for a stdio JSONL peer. The peer command is argv-only and starts after `--`:

```sh
./zig-out/bin/katzensteg attach --exec -- ./zig-out/bin/katzensteg --embed-jsonl probe.embed.basic_sdl
./zig-out/bin/katzensteg attach --rect 5,3,80,24 --aspect fit --exec -- ./zig-out/bin/katzensteg --embed-jsonl probe.embed.basic_sdl
```

The outer `katzensteg attach` owns `/dev/tty`, probes terminal graphics capabilities, sends `hello` and `attach` to the peer's stdin, reads `frame_batch` JSONL from the peer's stdout, decodes the batch strings, and writes the resulting terminal bytes to the terminal. `--rect x,y,w,h` uses 1-based terminal cells and maps to `col,row,cols,rows`; `--aspect` accepts `fit`, `stretch`, or `cover`. The inner command can be Katzensteg producer mode, `ssh`, `socat`, or another implementation of the same stdio protocol.

This is separate from `--embed-jsonl`: producer mode emits JSONL; attach mode consumes JSONL and presents it. A future `attach --socket <path>` should reuse the same host protocol and terminal presenter path.

## WM Host Mode

`wm` is the first interactive host/compositor for the same JSONL embed path:

```sh
./zig-out/bin/katzensteg wm probe.embed.basic_sdl
./zig-out/bin/katzensteg wm sonic mi2
```

The WM owns `/dev/tty`, draws text window chrome plus a bottom status/debug band, launches each selected profile through `katzensteg --embed-jsonl`, sends `attach` for each inner content rectangle, and applies producer `frame_batch` output inside that rectangle. The producers do not own title bars, borders, status/debug areas, layout, or window lifecycle policy.

The status band is host-owned and stays outside the producer content rect. It currently shows the selected upload profile, outer window geometry, inner content geometry, and the last WM protocol event such as launch, attach, viewport, shutdown, or producer exit.

Current controls:

- `q`: send `shutdown`, drain producer output, restore the terminal
- `Tab`: cycle focus when multiple producers are launched
- click a window: focus it and raise its host chrome
- `h` / `j` / `k` / `l`: move the window left/down/up/right and send `viewport`
- `H` / `J` / `K` / `L`: resize narrower/shorter/taller/wider and send `viewport`
- drag the title bar with mouse button 1: move the window and send `viewport`
- drag the right, bottom, or bottom-right border with mouse button 1: resize the window and send `viewport`

This is intentionally still early. Multi-producer focus, close-vs-detach policy, richer debug UI, and alternate text themes are follow-up work.

Current WM smoke notes:

- `sonic`, `smw`, and `sm64ds` work through the current JSONL SDL renderer path.
- `mi2` exercises the SDL sprite/scene path rather than only the full-frame path; batch scene placements are expected to be translated into the WM content rect.
- `jsr` uses the Vulkan/external-framebuffer path. That path now routes through the JSONL batch presenter in `wm`, but still needs real-profile smoke because it depends on the platform Vulkan layer and RetroArch/Flycast behavior.
- Producer input is wired through `wm` as terminal-byte input for the focused producer. WM command keys and chrome drags remain host-owned, and mouse input is forwarded only when the terminal event lands inside the focused producer content rect. Multi-producer sessions use disjoint image/placement id ranges and per-session file upload paths.

## Current Smoke Status

The current profile set has been smoke-tested on macOS. The known meaningful exceptions are Moonlight-specific:

- `moonlight.steam`: terminal streaming works, but terminal mouse input does not yet appear to hit Moonlight's input path.
- `moonlight.steam`: mixed-Retina setups can intermittently produce a renderer-output/window-size mismatch that shows the top-left quarter of the stream in the terminal.

Those two Moonlight issues are tracked as post-Linux investigations in the checkpoint plan.

## Profile Search

By default, the launcher looks for profiles in:

```text
{repo}/profiles
```

`{repo}` is resolved from the current working directory when run from the repo, or from `zig-out/bin/katzensteg` when run elsewhere.

Overrides:

```sh
KATZENSTEG_PROFILE_DIR=/path/to/profiles ./zig-out/bin/katzensteg
KATZENSTEG_REPO=/path/to/katzensteg ./zig-out/bin/katzensteg sonic
```

## Logs

By default, profile stdout is redirected to `/tmp/katzensteg-<profile-name>.out`, with non-alphanumeric profile characters replaced by `-`. Profile stderr follows stdout unless explicitly configured otherwise.

Current default profile logs:

- `sonic`: `/tmp/katzensteg-sonic.out`
- `sm64ds`: `/tmp/katzensteg-sm64ds.out`
- `smw`: `/tmp/katzensteg-smw.out`
- `jsr`: `/tmp/katzensteg-jsr.out`
- `mi2`: `/tmp/katzensteg-mi2.out`
- `moonlight.steam`: `/tmp/katzensteg-moonlight-steam.out`
- `probe.input`: `/tmp/katzensteg-probe-input.out`
- `probe.vulkan`: `/tmp/katzensteg-probe-vulkan.out`
- `ffplay.testsrc`: `/tmp/katzensteg-ffplay-testsrc.out`
- `anese.test`: `/tmp/katzensteg-anese-test.out`
- `smb3`: `/tmp/katzensteg-smb3.out`
- `cannonball`: `/tmp/katzensteg-cannonball.out`
- `chiaki.sdl`: `/tmp/katzensteg-chiaki-sdl.out`
