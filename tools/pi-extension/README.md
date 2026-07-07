# Katzensteg Pi Extension

Local Pi package for experimenting with Katzensteg embed integration.

## Install locally into Pi

```bash
pi install /Users/robert/dev/katzensteg/tools/pi-extension
```

Or for a one-off run:

```bash
pi -e /Users/robert/dev/katzensteg/tools/pi-extension
```

## Current status

This package is the home for the Pi-side Katzensteg integration work:

- top-right non-capturing overlay panel
- Katzensteg `--embed-jsonl` producer launch
- attach / viewport / detach protocol wiring
- simple size controls

The actual extension entrypoint lives in `extensions/katzensteg-panel.ts`.

## Commands

```text
/katzensteg-panel                  # toggle panel
/katzensteg-panel open            # open with remembered/default profile
/katzensteg-panel open sonic
/katzensteg-panel close
/katzensteg-panel size small
/katzensteg-panel size medium
/katzensteg-panel size large
/katzensteg-panel profile sonic
```

Tokens after the profile are forwarded verbatim to the program launched under
Katzensteg, appended after the profile's own configured args:

```text
/katzensteg-panel inline ffplay ~/dev/k-vids/clip.mp4
/katzensteg-panel open retroarch -L core.dylib game.rom
/katzensteg-panel retroarch -L core.dylib game.rom   # bare profile + args
```

A `--` separator is optional. Use it to forward args only (preferred profile),
or to keep an arg from being read as the profile:

```text
/katzensteg-panel open retroarch -- -L core.dylib    # explicit separator
/katzensteg-panel -- -L core.dylib                   # preferred profile + args
```

## Overrides

- `KATZENSTEG_PANEL_MODE=layout` runs layout-only mode: no Katzensteg process, no raw graphics writes.
- `KATZENSTEG_PANEL_MODE=live` runs the real Katzensteg embed producer. This is the default.
- `KATZENSTEG_BIN` overrides the Katzensteg binary path.
- `KATZENSTEG_PI_PROFILE` sets the default profile used by the panel.
- `KATZENSTEG_PANEL_WINDOW_POLICY` overrides the producer window policy (default: `mirror`, so the real SDL window also renders while the panel is active).
- `KATZENSTEG_PANEL_REAL_WINDOW` overrides real-window visibility (default: `show`).
- `KATZENSTEG_PANEL_Z_BASE` overrides the embed `z_base` (default: `-100`, to keep Pi overlay text chrome above Katzensteg full-frame placements).

The live panel uses `file_whole` upload transport with a temp upload path under the system temp directory.

Without `KATZENSTEG_BIN`, the extension prefers `zig-out/bin/katzensteg` from this repo and otherwise falls back to `katzensteg` from `$PATH`.
