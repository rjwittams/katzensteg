# How a text window should cover an image beneath it

Research for rjwittams/katzensteg#100 (map: #89). Facts with citations; no choice made.

Sources read, all local checkouts:

| Source | Revision |
|---|---|
| katzensteg | `5b517c4` (main) |
| `~/dev/zellij`, branch `feat/kitty-image-plumbing` | `d262df5` (2026-05-20) |
| `~/dev/kitty` | `c126e227` (2026-06-09) |
| `~/dev/ghostty`, branch `cleat-integration` | `64daa599` (2026-07-04); `~/dev/ghostty.main` `7092b394` has the same layering code |
| `~/dev/kitty-image-tests` | `183c0e1` |

Nothing here was run in a real terminal. Every terminal claim is from source unless marked otherwise.

## Short answer

- The split route is exact only when every cut lands on a whole source pixel. Otherwise each piece is stretched by a slightly different factor and the picture moves by up to one source pixel at each cut. With a small source shown large, one source pixel is several screen pixels.
- The z-index route works in both kitty and Ghostty by their source: an image with `z < INT32_MIN/2` is drawn under the background of any cell that has a non-default background, and over cells that have the default background.
- katzensteg already uses that band in direct sessions (`command_menu.contentZ`), checked by hand in Ghostty in PR #53.
- The two terminals disagree on what "non-default background" means. kitty compares colour values, Ghostty asks whether a background was set at all.

## 1. What zellij did

Zellij (the fork) splits. It never uses the below-background z band: no `i32::MIN` or equivalent appears in `zellij-server/src`.

- `zellij-server/src/output/image_fragment.rs:361-380` `visible_image_fragments` walks the floating panes above an image and clips each fragment against each pane.
- `image_fragment.rs:88-190` `clip_kitty_explicit_fragment` cuts an explicit placement into up to four pieces (top, bottom, left, right) around the covering pane. Same shape as katzensteg's `appendRectMinus`.
- Source arithmetic, `image_fragment.rs:49-63`: the offset is `scale_u32` (floor of `total*kept/original`), the extent is `scale_u32_extent` (ceiling of the same). So the right or bottom piece starts at `floor(removed*src/cells)` and its extent is `ceil(kept*src/cells)`. Same rounding class as katzensteg, with the same overlap at the cut.
- The same floor/ceil pair is used when a placement is clipped by the viewport, `zellij-server/src/panes/pane_image_scene.rs:1112-1139`.
- Placeholder images are clipped by dropping the covered cells, nothing else: `image_fragment.rs:309-337`.

The aspect subtlety it recorded is about one-dimensional sizing, not about the cut arithmetic:

- A kitty placement may give only `c` or only `r`. The terminal then works out the other dimension in pixels from the image's aspect ratio. Zellij models this in `zellij-server/src/panes/kitty.rs:1991-2054` and keeps `columns_specified` / `rows_specified` so the wire form keeps the intent (`kitty.rs:2777-2780`).
- A split piece cannot keep that intent. `image_fragment.rs:72-78` `promote_split_explicit_chunk_to_bounded_geometry` forces both `c` and `r` on every piece. A piece with both is stretched to fill whole cells.
- The test `kitty.rs:4701` `naive_bounded_conversion_for_one_dimensional_geometry_does_not_preserve_rendered_pixel_size` writes the effect down: a 16x9 image with `c=10` on 10x20 cells renders 100x56 px, but the derived box is 10x3 cells = 100x60 px. Promoting to `c+r` changes the rendered height from 56 to 60. That is the image moving when a pane covers it.
- `kitty.rs:4751` `bounded_conversion_with_offsets_can_preserve_one_dimensional_rendered_pixel_size` records a possible repair (keep the box, account for the 4 px of slack with an offset). It is a test of arithmetic only; I found no code in the split path that applies it.
- Commits: `c2f5eab6` "preserve kitty one-dimensional sizing semantics", `14e1cbe8` "improve kitty explicit geometry and placement flow", `7f16c48` "phase image output through fragments", `bbf44b4` "cover explicit kitty occlusion fragments", `da076f2` "Stabilize split kitty fragment ids".
- The removed doc `docs/kitty-graphics-checklist.md` (deleted in `8e6190b6`) lists "Floating-pane clipping (coarse first pass)" and says explicit sizing fidelity "was materially improved by preserving sizing intent on output and matching Zellij's internal occupancy prediction to the one-dimensional sizing mode" (lines 46-47, 177 at `8e6190b6^`).

One more thing seen in the code, not recorded there as a known issue: every split piece inherits `x_offset` and `y_offset` from the original (`..chunk.clone()` in `image_fragment.rs:121-184`), so a right or bottom piece of a placement with `X=`/`Y=` would apply the offset again.

Not found: any zellij note about cut-edge rounding, seams, or Ghostty specifically.

## 2. Where the pieces can drift in katzensteg

The route: `placeClippedBatch` (`src/katzensteg/frame_builder.zig:1879-1888`) calls `clippedPlacementPieces` (`:1912-1951`), which cuts the destination cell rectangle around each occlusion (`appendRectMinus`, `:1953-1966`) and gives each piece a source rectangle from `sourceRectForCellFragment` (`:1984-1994`). `placeClippedPieces` (`:1890-1905`) emits one `a=p` per piece with its own `c`, `r`, `x`, `y`, `w`, `h` (`src/termscene/kitty/protocol.zig:105-119`).

### Source rectangle rounding: the one real source of drift

`sourceRectForCellFragment`, with `W` = destination columns, `sw` = source width, piece covering cell offsets `[a, b)`:

```
src_x0 = source.x + floor(a * sw / W)
src_x1 = source.x + ceil (b * sw / W)
```

Rows likewise. The true source coordinate at a cell boundary `a` is `a*sw/W`. When that is not an integer:

- the piece left of the cut ends at `ceil`, the piece right of it starts at `floor`, so the two pieces share one source column (or row);
- each piece's widened source is stretched onto the piece's exact cell box, so the content at the cut is displaced by `frac(a*sw/W)` source pixels, falling off linearly to the piece's far edge;
- each piece ends up with its own scale factor, `(b-a)*cell_px / (src_x1-src_x0)`, a little different from the unsplit `W*cell_px/sw`.

In screen pixels the displacement is below one source pixel, that is below `W*cell_px/sw`. A 320 px wide source shown 1600 px wide can move 5 px at a cut. A source at or above the display size moves less than 1 px.

It is exact when `W` divides `a*sw` for every cut column and `H` divides `a*sh` for every cut row. A sufficient condition is that the source is a whole multiple of the destination cell grid, for example a source of exactly `W*cell_w` by `H*cell_h` pixels.

When that holds today:

- GL capture asks for that size: `externalFramebufferUploadSize` (`frame_builder.zig:2117-2121`, used at `src/katzensteg/preload.zig:954`) returns `divRound(dest.w*term_w, cols)` (`:3986-3997`), which is `W*cell_w` only if the terminal's pixel width divided by its columns is a whole number.
- Otherwise the batch route uploads the framebuffer at its own size (`presentCompositeFullscreenBatch`, `:2350-2371`: `uploadRgba(image_id, fb.rgba, fb.width, fb.height)`), so it is exact only by accident.

### Each piece scaled independently

Both terminals stretch a `c`+`r` placement's source rectangle to exactly `c*cell_w` by `r*cell_h`, with no aspect preservation:

- Ghostty: `src/terminal/kitty/graphics_storage.zig:1079-1087`; the shader maps the source rectangle's corners to the destination's corners (`src/renderer/shaders/glsl/image.v.glsl`).
- kitty: `kitty/graphics.c:1248-1252` (dest), `:818-824` (source as fractions of the image).

So pieces always abut on screen with no gap and no overlap; cells are whole pixels in both. Independent scaling adds no error of its own. It is what turns a rounded source edge into a displacement.

### Aspect-fitted image that does not fill whole cells

This does not arise in katzensteg. `fit` rounds the image to whole cells and lets the terminal stretch: `containedCellRect` (`frame_builder.zig:3952-3970`) uses `@round(display_w / cell_w)`, and `writePlace` never emits `X=`/`Y=` cell offsets. The picture's aspect is therefore off by up to half a cell in each axis, split or not. The zellij effect (a one-dimensional placement promoted to `c+r`) cannot occur because every katzensteg placement already carries both `c` and `r`.

`cover` crops the source with floating-point cell sizes and `@ceil` (`batchSourceRectForAspect`, `:2419-2438`); the same crop applies split or unsplit.

### Cell pixel size not an integer

katzensteg takes cell size as `terminal_px / terminal_cells` in floating point (`:3960-3961`, `:2425-2426`) and scales a window's pixel extent by `divRound(rect_cells*terminal_pixels, terminal_cells)` (`src/katzensteg/render_batch_sink.zig:581-584`). The terminals use whole-pixel cells: Ghostty divides as integers (`graphics_storage.zig:1070-1071`).

Ghostty reports to the pty the surface size minus explicit padding (`src/termio/Termio.zig:472`, `src/renderer/size.zig:42-44`, `src/termio/Exec.zig:1127-1130`), not `cols*cell_w`. Unless the window happens to be a whole number of cells, `ws_xpixel/cols` is fractional. Then the GL capture size is not a multiple of the cell grid, and the split is inexact even on the one path that tries to match pixels. It does not move piece positions, which are in cells.

Not determined: what kitty reports in `ws_xpixel`; which of these effects the prototype in #97 actually showed. The arithmetic says source rounding. Nobody measured it.

### Other costs of the split route as built

- 64 pieces at most; further fragments are dropped (`:35`, `:1931-1933`).
- The composite gets a new image id each frame (`:2352`), so every frame re-places every piece.

## 3. The z-index route

### The protocol

`~/dev/kitty/docs/graphics-protocol.rst:535-538`: "Negative z-index values mean that the images will be drawn under the text. This allows rendering of text on top of images. Negative z-index values below INT32_MIN/2 (-1,073,741,824) will be drawn under cells with non-default background colors."

### kitty: honoured (read from source)

- `kitty/graphics.c:1267-1272` sorts placements into below (`z < INT32_MIN/2`), negative, positive.
- `kitty/shaders.c:1358-1375` `draw_cells_with_layers`: default backgrounds, then below images, then non-default cell backgrounds (`:1366`), then negative images, then text, then positive images.
- "Non-default" is a comparison of colour values: `kitty/cell_vertex.glsl:316`, `cell_has_default_bg = 1 - step(1, abs(bg_as_uint - bg_colors0))`. A cell with an explicit background equal to the terminal's default background colour counts as default, and the image shows through it. Reverse video swaps the colours first (`:308-313`), so a reversed default cell counts as non-default unless foreground equals background.

### Ghostty: honoured (read from source)

- `src/renderer/image.zig:379-383` splits placements at `minInt(i32) / 2` and at 0.
- `src/renderer/generic.zig:1612-1680`: global background, `kitty_below_bg` images (`:1630-1637`), cell backgrounds (`:1639-1645`), `kitty_below_text` images, text, `kitty_above_text` images.
- A cell's background is drawn opaque when the cell has a background style at all, whatever the colour: `generic.zig:2904-2905`, with `bg_style` from `src/terminal/style.zig:108-126` (null only for `.none`). Cells with no background get alpha 0 (`:2910`) and the image shows. Reversed and selected cells are opaque (`:2891-2895`).
- Exception: with `background-opacity-cells` set and `background-opacity` below 1, explicit backgrounds are translucent (`:2898-2902`) and the image shows through them.

### Recorded tests

- `~/dev/kitty-image-tests` has no test of the below-background band. Its z-order stage places `z=-1`, `0`, `1` only (`smoke/features/z_order.py`, `smoke/sections/explicit.py:931-967`). It does have an explicit-occlusion section for comparing the split route (`smoke/sections/explicit_occlusion.py`).
- katzensteg already depends on the band. `src/katzensteg/command_menu.zig:53-57` `contentZ` maps direct-session z values to `-1,610,612,736 + clamp(z, ±536,870,912)`, used through `directZ` (`frame_builder.zig:565-567`, set at `src/katzensteg/runtime.zig:444`) so the command menu row covers the game image. PR #53 (`5a27003`) lists "Manual Ghostty checks" in its validation. That is a manual check in Ghostty, not an automated one, and none is recorded for kitty.

Confidence: kitty, from source, unverified by test. Ghostty, from source plus the manual check in PR #53. Other terminals: not looked at.

## 4. Unicode placeholders

- Their z-index is fixed at -1 in both terminals: `kitty/graphics.c:1019`, Ghostty `src/renderer/image.zig:520`. They cannot be put in the below-background band. They are drawn over cell backgrounds and under text.
- They do not need it. The image exists only where placeholder cells are. Text written over those cells removes that part of the image, cell by cell.
- Covering causes no drift. Each run of cells takes its source slice from its own row and column numbers, in floating point (`kitty/graphics.c:943-973`; Ghostty `src/terminal/kitty/graphics_unicode.zig:156-250`). Removing cells leaves the remaining cells' slices unchanged.
- Geometry differs from explicit placements: the image is fitted into the `c` by `r` box with its aspect ratio kept, and centred (kitty `graphics.c:943-956`; Ghostty `graphics_unicode.zig:170-189`). Explicit `c+r` placements stretch.
- The WM already has this mode: `PresentationMode.placeholder` (`src/katzensteg/wm_host.zig:450`), cells written at `:1963-1977`. After a covering window moves away the WM must rewrite the placeholder cells.

## 5. What each route costs

### Split route (today)

- WM: computes occlusion rectangles from every drawable window above (`occlusionRectsForSession`, `wm_host.zig:2074-2086`) and resends the viewport on each change. A text window is one more rectangle in that list.
- Producers: the code in section 2; N placements per frame per covered window; the 64-piece cap.
- To make it exact: either size the upload to a whole multiple of the cell grid (needs the terminal's true cell size, which `ws_xpixel/cols` does not give in Ghostty), or cut in source space and keep the pieces' cell boxes exact, which is only possible when the cut is on a whole source pixel.

### z-index route

Who sets z today: the WM sends `z_base = zBaseForSlot(slot)`, `slot * 1000` capped at 1000 slots, so 0 to 1,000,000 (`wm_host.zig:2054-2063`, sent at `:1211` and `:2099`). The producer adds it to its own z in `RenderBatchSink.place` (`render_batch_sink.zig:306`). Producer z values are small: composite 100 (`frame_builder.zig:1834`, `:2368`), scene sprites -100 to 100+i (`:1422-1466`). All positive bases, so today every producer image is above all text, which is why chrome has to be cut around.

What would change:

- WM: add a constant to `z_base` that puts the whole range below `INT32_MIN/2`. The band is about 1.07 thousand million wide and the WM uses one million. `z_base` is already an `i32` on the wire (`src/katzensteg/render_batch_protocol.zig:434`). Producers need no change.
- WM: stop sending occlusion rectangles, or send none for coverers that paint backgrounds. Image over image is ordered by z. `clip_cells` for the terminal edge is still needed.
- WM: every cell that must cover an image needs an explicit background. Today chrome sets only foreground attributes (`renderChrome`, `wm_host.zig:1586`) and cleared areas are plain spaces after `SGR 0` (`:1984`, `:2577-2586`). Status rows use reverse video (`:1712`, `:2537`, `:2617`), which already covers in both terminals.
- Text window cells with the session's default background: painted as default they let the image show through behind the glyphs, in both terminals. The WM has to paint them with an explicit colour. In Ghostty any explicit colour covers. In kitty the colour must differ in value from the outer terminal's default background, so the WM either learns that colour (OSC 11) or picks one that differs.
- An image window above a text window: the cells there must be left with the default background, or the text window's backgrounds cover the image. The WM's cell painter must skip cells where an image window is topmost (the #97 prototype already skips covered cells). Transparent pixels of that image then show the terminal background, not the text window beneath.
- A user's `background-opacity-cells` in Ghostty makes covering cells translucent.

Not determined: behaviour in terminals other than kitty and Ghostty; whether kitty's `transparent_background_colors` or `background_opacity` settings change the cover (not read).

### Placeholder route

- WM: owns the cells of every image window (already does in placeholder mode), repaints them when uncovered. No occlusion rectangles, no z.
- Producers: upload only; geometry is aspect-fitted by the terminal rather than stretched.
- Image over image is not ordered by z (all -1, ties by image id); the WM decides per cell which image's placeholder is written.

## Options

1. Keep splitting, accept the drift.
2. Keep splitting, make it exact: size sources to a whole multiple of the cell grid, which needs a true cell size that Ghostty's `ws_xpixel` does not supply.
3. Move producer images to the below-background band and have the WM paint explicit backgrounds on every covering cell (text windows, chrome). Occlusion rectangles go away. Needs a background colour that differs from the terminal default for kitty.
4. Mixed: below-background band only for image windows that have a text window above them; others stay as now. Keeps images above lower text windows without blanking cells, at the cost of two modes.
5. Placeholder presentation for windows that can be covered by text; covering is by cell replacement.

Open before choosing: a real-terminal check of option 3 in kitty (none recorded), and a measurement of what the #97 prototype showed.
