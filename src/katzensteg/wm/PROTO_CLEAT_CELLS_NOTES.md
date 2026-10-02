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

**It holds up.** Tried in Ghostty on 2026-10-02.

- Painting, typing (kitty key reports, arrows), scrollback, move and resize all work. Not too flickery when dragged.
- Cost at 80x24: one row is about 120 bytes and 20 µs to build; all rows about 2,100 bytes and under 0.5 ms. Cleat coalesces: `seq 1 20000` arrived as 5 updates. Scrolling is always a full replace.
- The window should not have layering of its own. It should be the same kind of window as a producer's, in the one window order, with the same chrome (no separate resize glyph).
- Covering a producer's image works by the existing route: the producer splits its image into explicit placements around the rectangle. In Ghostty the result is very slightly off, as it was in zellij (aspect ratio moving the pieces). That is a question of its own.
- Polling cleat on the 20 ms tick was acceptable to type through.
