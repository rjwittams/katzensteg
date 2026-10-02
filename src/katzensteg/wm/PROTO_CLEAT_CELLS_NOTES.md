# PROTOTYPE — a cleat session painted as cells in the desktop WM

Throwaway, for rjwittams/katzensteg#97. Not for merging.

**Question:** does painting a live cleat session as cells in a rectangle of the
desktop WM hold up (repaint cost, clipping, the cursor, wide characters)?

## Run

```sh
(cd ~/dev/cleat && cargo build --release -p cleat --lib)
zig build -Doptimize=Debug -Dproto-cleat=$HOME/dev/cleat
cleat launch ks-proto --size 80x24 --cmd zsh
KATZENSTEG_PROTO_CLEAT=ks-proto ./zig-out/bin/katzensteg-wm probe.input
```

The library must match the installed `cleat` (`cleat --version` shows the
commit and protocol). Numbers go to `/tmp/katzensteg-proto-cells.log`.

- Click the window to focus it and type. Click elsewhere to give keys back.
- Drag the title to move. Drag `◢` to resize; the session is resized on release.
- `▲` lowers it under the producer windows; a click on any part still showing raises it.
- The wheel scrolls cleat's scrollback.

## What it does

- Attaches as a controller through `cleat_provider.h`, daemon backend.
- Keeps a mirror of the visible grid, fed by full-replace, row-replace and scroll-copy operations.
- Paints dirty rows on each update, and everything after any desktop redraw.
- Polls cleat once per WM loop turn (the 20 ms tick); the wake callback only counts.
- Above the producers, its rectangle is handed to them as an occlusion rectangle.
  Below them, its cells are skipped wherever a producer window's rectangle covers them.

## Not done

Images inside the session, pointer events into the session, paste, selection,
hyperlinks, underline styles and colours, cursor shapes, a real place in the
WM's window order (it is either above all producers or below all).

## Verdict

_To fill in._
