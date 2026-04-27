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

## Current Smoke Status

The current profile set has been smoke-tested on macOS. The known meaningful exceptions are Moonlight-specific:

- `moonlight.steam`: terminal streaming works, but terminal mouse input does not yet appear to hit Moonlight's input path.
- `moonlight.steam`: mixed-Retina setups can intermittently produce a renderer-output/window-size mismatch that shows the top-left quarter of the stream in the terminal.

Those two Moonlight issues are tracked as post-Linux investigations in the checkpoint plan.

## Profile Search

By default, the launcher looks for profiles in:

```text
{repo}/tools/katzensteg/profiles
```

`{repo}` is resolved from the current working directory when run from the repo, or from `zig-out/bin/katzensteg` when run elsewhere.

Overrides:

```sh
KATZENSTEG_PROFILE_DIR=/path/to/profiles ./zig-out/bin/katzensteg
KATZENSTEG_REPO=/path/to/ttytris ./zig-out/bin/katzensteg sonic
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
