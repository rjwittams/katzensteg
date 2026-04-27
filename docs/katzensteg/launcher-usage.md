# Katzensteg Launcher Usage

The launcher is meant to replace one-off run scripts without taking over terminal drawing while the target app is running.

## List Profiles

```sh
./zig-out/bin/katzensteg
```

Visible profiles currently include:

- `probe.input`
- `retroarch.sonic`
- `retroarch.melonds.sm64ds`
- `scummvm.monkey2`
- `moonlight.steam_big_picture`

Hidden profiles such as `adapter.sdl2_preload` and `runtime.fullscreen_file` are reusable fragments, not direct launch targets.

## Dry Run

```sh
./zig-out/bin/katzensteg retroarch.melonds.sm64ds --dry-run
./zig-out/bin/katzensteg scummvm.monkey2 --dry-run
./zig-out/bin/katzensteg moonlight.steam_big_picture --dry-run
```

Dry-run prints the resolved target, argument count, environment count, output log, and runtime window policy.

## Launch

```sh
./zig-out/bin/katzensteg retroarch.sonic
./zig-out/bin/katzensteg retroarch.melonds.sm64ds
./zig-out/bin/katzensteg scummvm.monkey2
./zig-out/bin/katzensteg moonlight.steam_big_picture
```

The launcher writes a temporary runtime JSON file, passes it through `KATZENSTEG_CONFIG`, runs the child, then performs a best-effort terminal reset and kitty image clear after exit.

## Profile Search

By default, the launcher looks for profiles in:

```text
{repo}/tools/katzensteg/profiles
```

`{repo}` is resolved from the current working directory when run from the repo, or from `zig-out/bin/katzensteg` when run elsewhere.

Overrides:

```sh
KATZENSTEG_PROFILE_DIR=/path/to/profiles ./zig-out/bin/katzensteg
KATZENSTEG_REPO=/path/to/ttytris ./zig-out/bin/katzensteg retroarch.sonic
```

## Logs

Current profile logs:

- `retroarch.sonic`: `/tmp/retro-sonic.out`
- `retroarch.melonds.sm64ds`: `/tmp/retro-sm64ds-melonds.out`
- `scummvm.monkey2`: `/tmp/scummvm.out`
- `moonlight.steam_big_picture`: `/tmp/moonlight-katzensteg.out`
- `probe.input`: `/tmp/katzensteg-input-probe.out`
