# Katzensteg Pi Extension

Local Pi package for experimenting with Katzensteg embed integration.

## Install locally into Pi

```bash
pi install ~/dev/katzensteg/tools/pi-extension
```

For a one-off run against the local pi surface port:

```bash
cd ~/dev/pi-terminal-surfaces
./pi-test.sh --no-session --no-extensions --tui-mode regular \
  -e ~/dev/katzensteg/tools/pi-extension/extensions/katzensteg-panel.ts
```

## Current status

This extension currently requires the local pi `terminal-surfaces-upstream` worktree and a rebuilt Katzensteg producer with presentation-generation support. Repeat the command above with `--tui-mode fullscreen` to test the other renderer.

The integration supports:

- floating and inline panels using pi's generic surface API
- title dragging, border/corner resizing, and a top-right close button
- Katzensteg `--embed-jsonl` producer launch
- committed geometry and clipping, with stale-position filtering
- keyboard input, pointer capture, and cancellation releases
- post-render graphics writes and synchronous image cleanup on disposal
- size and profile controls

The actual extension entrypoint lives in `extensions/katzensteg-panel.ts`.

## Commands

```text
/katzensteg-panel                  # toggle panel
/katzensteg-panel open            # open with remembered/default profile
/katzensteg-panel open sonic
/katzensteg-panel inline sonic
/katzensteg-panel close
/katzensteg-panel size small
/katzensteg-panel size medium
/katzensteg-panel size large
/katzensteg-panel profile sonic
```

Click the body to focus the producer. Drag the title to move the floating panel; drag an edge or corner to resize it. Click `×` to close it. Ctrl+G returns focus to the composer (or use the configured surface-release binding). Escape remains available to the game or application. Size presets resize the existing overlay without restarting the producer.

Each `open` adds a floating panel. New panels are offset and receive a higher
graphics depth using Katzensteg's existing `z_base`. `close`, `size`, `profile`,
and the close side of `toggle` target the most recently opened or clicked panel;
each panel's `×` closes that panel. Clicking a panel raises its graphics and
overlay together. The surface API reports coverage from higher overlays, including
their borders. The extension forwards that coverage to the producer. Tool-result
image cropping is handled separately by the pi renderer.

For a local smoke test without a game installation, use `/katzensteg-panel open probe.embed.basic_sdl`. The demo exits on its own after its configured run. Test terminal resize, movement beyond the bottom edge followed by another drag, closing while streaming, and inline scrolling in both pi modes.

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
- `KATZENSTEG_PANEL_WINDOW_POLICY` overrides the profile's producer window policy.
- `KATZENSTEG_PANEL_REAL_WINDOW` overrides the profile's real-window visibility.
- `KATZENSTEG_PANEL_Z_BASE` overrides the embed `z_base` (default: `-100`, to keep Pi overlay text chrome above Katzensteg full-frame placements).

The live panel uses `file_whole` upload transport with a temp upload path under the system temp directory.

The extension queues pending batches until pi commits its next render; it does not cache images or replay old file uploads after terminal damage. Continuous full-frame producers are expected to restore their output on the next update. Recovery for sparse or paused producers is deferred until a real failure warrants it. Pending output is bounded at 64 MiB; exceeding that stops the producer rather than silently dropping resource operations.

Without `KATZENSTEG_BIN`, the extension prefers `zig-out/bin/katzensteg` from this repo and otherwise falls back to `katzensteg` from `$PATH`.

## Agent interaction

Rebuild Katzensteg with `zig build -Doptimize=Debug`, then reload the pi extension.
Open a game with `/katzensteg-panel open mi2` or `/katzensteg-panel inline mi2`.
The agent can also open panels directly, using the same opening path as the command:

- `katzensteg_open`: open a floating panel with a `profile` and optional `args`
  array, for example `{"profile":"mi2"}`. Returns the new panel ID once the UI
  exists; the game can still be starting. Uses the current size preset.
- `katzensteg_panels`: list attached live panels and their IDs.
- `katzensteg_observe`: return the latest full game image as a PNG, with native
  image dimensions, a capture frame ID, and a timestamp in milliseconds since
  the Unix epoch. Set `afterFrame` to wait for a newer capture. If the game is
  paused, the timeout can return the same image with `newerFrame: false`.
- `katzensteg_act`: run an ordered sequence of `move`, `click`, `key`, and `wait`
  actions, then return an observation. Coordinates are zero-based pixels in the
  screenshot, independent of panel size, position, or clipping. For example:
  `{"actions":[{"type":"move","x":240,"y":130},{"type":"wait","ms":300}]}`.

Omit `panel` when exactly one live panel is attached. With multiple panels,
provide the ID returned by `katzensteg_panels`. These IDs only identify current
pi panels; they are not persistent sessions.

Keys are taps, not persistent holds. Supported names are `enter`, `escape`,
`space`, `tab`, `backspace`, the four arrows, and `f1` through `f8`; single
printable ASCII characters also work. Clicks hold the button for 60 ms. A call
accepts at most 16 actions and 10 seconds of explicit waits. Only one agent
operation can run per panel. Human keyboard or pointer input cancels it and
releases any held mouse button before forwarding human input. Closing or
replacing the panel also cancels outstanding operations.

The pi producer enables `KATZENSTEG_OBSERVE=1`. Katzensteg retains one owned RGBA
frame at application-window resolution. Sprite presentations are composed for
observation without changing their terminal presentation. Snapshot requests copy
that retained frame to a separate temporary file, which the extension encodes
as PNG and deletes after reading. This cache is for observation; it does not
replay terminal graphics after damage. OpenGL/Vulkan external-framebuffer
observation is not supported yet.

A capture ID counts retained frames, not game simulation steps. Input is queued
through Katzensteg's input model; a subsequent image does not prove the game has
finished responding. Use a short wait or another observation when needed.

The macOS preload preserves the calling library's `dlopen` search paths, including
`@loader_path` and `@rpath`, so SDL compatibility libraries can load their dependencies.
