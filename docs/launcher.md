# Launcher And Profiles

Use the `katzensteg` launcher for normal runs.

```sh
./zig-out/bin/katzensteg
./zig-out/bin/katzensteg --dry-run <profile>
./zig-out/bin/katzensteg <profile>
```

The launcher exists so app-specific setup is repeatable. It resolves profiles, prepares the target environment, writes runtime configuration, redirects logs when needed, and starts the target application.

## Build First

```sh
zig build
```

Then list visible profiles:

```sh
./zig-out/bin/katzensteg
```

Start with the input probe on a new machine:

```sh
./zig-out/bin/katzensteg --dry-run probe.input
./zig-out/bin/katzensteg probe.input
```

## Profile Files

Profiles live in `profiles/*.json`.

A profile may:

- name a target executable
- provide arguments
- set environment values
- inherit reusable hidden fragments
- choose runtime policy
- seed local config files
- use platform-specific values

Hidden profiles are fragments such as adapter/runtime defaults. Visible profiles are intended to be run directly.

## Search Paths

By default, the launcher reads:

```text
{repo}/profiles
```

Overrides:

```sh
KATZENSTEG_PROFILE_DIR=/path/to/profiles ./zig-out/bin/katzensteg
KATZENSTEG_REPO=/path/to/katzensteg ./zig-out/bin/katzensteg probe.input
```

`KATZENSTEG_PROFILE_DIR` may be used for local/private profile sets without committing machine-specific paths to the repository.

## Real App Profiles

Real app profiles often assume:

- local source checkouts under `~/dev`
- patched app branches that expose pure SDL2 output/input
- ROM, game, or media files that are not stored in this repository
- platform-specific build products

Always run `--dry-run` before trying a real app profile on a new machine. It shows the resolved command and environment without starting the target.

For the current app matrix, see `docs/external-projects.md`.
