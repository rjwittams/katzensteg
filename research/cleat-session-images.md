# How images drawn inside a cleat session reach a client

Research for rjwittams/katzensteg#92 (map: #89). Read-only source inspection on 2026-10-02; nothing was built or run.

Source: `~/dev/cleat` at local `HEAD` `f04ce23` (#231), which is 26 commits behind its tracked `github/main` (`e233d6d`). `image_delivery.rs`, `image_backing.rs` and `kitty_output.rs` are identical on both. Upstream differences that matter here are listed under "Not determined / caveats". Paths below are relative to `~/dev/cleat`; `src/` means `crates/cleat/src/`. The pinned engine is the Ghostty fork `rjwittams/ghostty@c3dbb925` (`tools/ghostty-toolchain.toml:15-16`), source in `.tools/ghostty-src`.

## Short answer

A cleat client never sees the program's graphics commands. The daemon's Ghostty VT engine consumes them, decodes the pixels, and answers the program itself. Clients get *render packets*: a cell grid plus a list of image resources (id, generation, size, format) and a list of resolved, viewport-relative placements. Pixels travel separately, as an immutable file offer or as byte chunks, ahead of the render that references them. Unicode placeholders are already resolved into ordinary placement rectangles by the engine. `cleat attach` then re-encodes all of that as fresh kitty commands with its own ids for its outer terminal.

## 1. What the engine keeps

- Each session has one Ghostty terminal with kitty image storage enabled at 320 MB (`src/vt/ghostty.rs:31,67`; Ghostty default per screen `graphics_storage.zig:134`). When the limit is exceeded Ghostty evicts images (`graphics_storage.zig:1606-1694`).
- All three external media are enabled: file, temp file, shared memory (`src/vt/ghostty.rs:68-70`, `src/vt/ghostty_ffi.rs:1387-1410`). The engine reads them itself at command time, in the daemon process, and copies into owned memory. Shared memory is unlinked by the engine after reading (test asserts this: `src/image_delivery.rs:398-400`). Temp files are deleted only under approved temp directories (`ghostty_ffi.rs:1401-1403`).
- Pixels are kept decoded. PNG (`f=100`) is decoded on intake through cleat's PNG callback and comes out as RGBA (`ghostty_ffi.rs:1193-1214`, `tests/vt.rs:549-577`). Reported `format` is 0 = RGB, 1 = RGBA (`tests/vt.rs:439,565`). The original encoded bytes are not retained (`docs/adr/0005-retained-image-delivery.md:9,21`).
- Identity is `(image_id, generation)`. `image_id` is the program's kitty id; `generation` changes whenever the same id is retransmitted (`ghostty_ffi.rs:1413-1434`, test `:2378-2387`).
- Placements: placement id, z, viewport col/row, grid cols/rows, pixel size, source rect, x/y pixel offsets, and a `VIRTUAL` flag (`src/provider.rs:202-223`, built at `src/vt/ghostty.rs:700-721`).
- What a render reports is filtered. `kitty_image_state` walks placements, skips ones not visible in the viewport, and lists only the images those visible placements use (`ghostty_ffi.rs:1488-1490,1524`). An image that is transmitted but not placed, or placed but scrolled out of view, is not in the update and its pixels are not sent.
- Virtual placements (`a=p,U=1`) are skipped as such (`ghostty_ffi.rs:1501-1503`). Instead a second iterator yields one resolved placement per run of placeholder cells, with viewport position, grid size, pixel size and source rect filled in, flagged virtual (`ghostty_ffi.rs:1528-1574`). A 4x2 placeholder block arrives as two 4x1 placements with `source_y` 0 and 1 (`tests/vt.rs:473-528`).
- Z-order is the placement's `z` field, passed through unchanged. Nothing else orders placements; the CLI emits them in list order with `z=` (`src/kitty_output.rs:156-176`).

## 2. Retained image delivery (ADR 0005)

Defined in `docs/adr/0005-retained-image-delivery.md`, implemented in `src/image_delivery.rs`, `src/image_backing.rs`.

- Capture happens in the session actor in the same command as the render, so the pixels match the descriptor (`src/host/actor.rs:1121-1145`). Each captured generation is written to a daemon-owned file `$TMPDIR/cleat-image-<pid>-<uuid>`, mode 0600, mapped read-only; owned bytes are the fallback if file creation fails (`image_backing.rs:16-19,64-87`). A weak cache shares a generation between viewers and drops it when no viewer holds it (`image_delivery.rs:37-84`).
- On attach: opening a channel takes a full render and starts an `ImageTransfer` with an empty resident set, so every image in the current view is delivered (`src/session.rs:4153,4184-4186,4202`).
- Order on the wire, per image not already resident on that channel: first a file offer `MSG_SESSION_IMAGE_FILE {image_id, generation, len, path}`; the client hard-links the path to a private name, maps it, and replies acquired or not (`image_delivery.rs:137-155,185-204`, `image_backing.rs:88-96`). If refused, ordered 64 KiB `MSG_SESSION_IMAGE` chunks follow (`image_delivery.rs:18,156-171`). The render packet is sent last and commits the set (`image_delivery.rs:173,238-260`).
- Afterwards: each channel has one unacknowledged render at a time (`docs/multiplayer-attachments.md:106`). A new render sends only generations not in the previous committed view; the resident set is replaced by exactly what the new render references (`image_delivery.rs:98-110`). An image that leaves the view and comes back is sent again (`image_delivery.rs:302-303`).
- Budgets: 320 MiB of images per view, on both sides (`image_delivery.rs:17,51-53,104-106`); 4 MiB packet payload limit (`src/packet.rs:62`). A failed capture marks the view stale rather than dropping the client (`session.rs:4228-4243`).
- History views carry owned bytes with the frame and go through the same delivery path, limited to 1 MiB of URI and image bytes per captured frame (`src/vt/ghostty.rs:404`, `session.rs:4276-4288`).
- Client and daemon protocol versions must match exactly (`src/packet.rs:12,72`; `docs/multiplayer-attachments.md:113-115`).

## 3. What a live client sees

There are two client shapes, and neither receives the original commands.

**Library / packet client** (the C ABI in `crates/cleat/include/cleat_provider.h`, or the packet protocol directly). It gets `cleat_render_update` with `image_resources[]` and `image_placements[]` (`cleat_provider.h:393-443`) and fetches pixels with `cleat_session_with_image_resource_data(session, image_id, generation, callback)` (`cleat_provider.h:635`). For daemon sessions that call serves the images committed with the last consumed update (`src/provider_ffi.rs:2021-2031,2085-2089`). The header comment at `cleat_provider.h:629-634` still says "succeeds only for in-process sessions"; the code and `docs/validation-image-delivery-2026-09-17.md:27-33` say otherwise. Ids are the program's ids plus a generation. Pixels are decoded RGB/RGBA. The transport the program used is not visible. The C ABI hands out a borrowed byte pointer, not the backing file path.

**`cleat attach` (CLI)**. It is a packet client that repaints cells and re-encodes images for its outer terminal (`src/kitty_output.rs`):

- New ids: a per-attachment counter starting at 1, one id per `(image_id, generation)` (`kitty_output.rs:114-117`). The program's ids do not reach the outer terminal.
- Upload: `a=t,i=<id>,q=0,f=24|32|100,s=,v=` with `t=f` pointing at the attachment's hard-linked cleat file, falling back to chunked `t=d` (3072-byte chunks) if the terminal reports an error (`kitty_output.rs:192-216,55-62`). Never `t=s`.
- It waits for the outer terminal's `OK` before placing. Replies are parsed out of the input stream and never forwarded to the program (`kitty_output.rs:43-67`, `session.rs:545-551`). No reply within 5 s disables images for that attachment (`kitty_output.rs:68-80`). At most 8 uploads are pending (`kitty_output.rs:119-125`).
- Placement: always explicit, `CSI row;col H` then `a=p,C=1,q=2,i=,p=<index+1>,z=,c=,r=,x=,y=,w=,h=,X=,Y=`, clipped to the attachment's viewport and pan origin (`kitty_output.rs:136-176,242-287`). All current placements are deleted and re-emitted when any change is ready (`kitty_output.rs:150-155`).

The old raw-stream attach endpoint still exists and relays PTY bytes (`docs/multiplayer-attachments.md:37-38`). The same document says Ghostty CLI attach/watch and daemon library sessions use packet attachments.

## 4. Unicode placeholders

- In the grid, the cells are still there: each cell's `graphemes` holds U+10EEEE plus its row/column diacritics, the foreground colour carries the image id as the program wrote it, and the row has `has_kitty_virtual_placeholder` set (`src/provider.rs:81-99`, `src/vt/ghostty.rs:163-209`, `cleat_provider.h:375`).
- In the image list, the same cells appear as resolved placements flagged `TERMINAL_IMAGE_PLACEMENT_VIRTUAL` (section 1).
- The CLI prints a space for any cell containing U+10EEEE (`session.rs:1000-1001`) and draws the resolved placements as ordinary explicit placements. Test: `session.rs:4965-4999` checks one placement results and no placeholder glyph reaches the outer terminal.
- So a client must do one or the other: draw the virtual placements and blank the cells, or pass the cells through to something that understands placeholders. Doing both draws twice; doing neither loses the image.

## 5. What the program is answered

Replies come from the daemon's engine, attached or detached. Packet clients never answer queries; only a raw-stream controller turns on query passthrough (`src/session_runtime.rs:559-566`, `src/host/actor.rs:966,1249-1251`, `session.rs:3025`, `docs/multiplayer-attachments.md:32-35`). Replies stuck in the engine from a replayed recording are discarded at spawn (`session_runtime.rs:91-96`).

- **`a=q`**: Ghostty attempts a full load of the described image and discards it, replying `OK` or an error (`.tools/ghostty-src/src/terminal/kitty/graphics_exec.zig:140-182`). Since file, temp-file and shm media are enabled, probes for those succeed whenever the daemon process can read the object. The answer says nothing about any attached terminal. It is the same with zero clients.
- **Terminal identity**: environment is `TERM=xterm-ghostty` (fallback `xterm-256color`), `TERM_PROGRAM=ghostty`, `COLORTERM=truecolor`, no `TERM_PROGRAM_VERSION`; the launcher's values are removed (`docs/terminal-identity.md:7-40`). DA1 is VT220 with feature 22; DA2 is type 1, version 10 (`ghostty_ffi.rs:1131-1161`). cleat sets no XTVERSION callback, so XTVERSION answers `libghostty` (`stream_terminal.zig:1399-1408`; no `Xtversion` set anywhere in `ghostty_ffi.rs`).
- **Pixel size**: `CSI 14/16/18 t` are answered by the engine from its grid and cell size, with cell size floored at 1 px (`ghostty_ffi.rs:1175-1189`). `TIOCGWINSZ` pixel fields are `cols*cell_w`, `rows*cell_h`, and are zero until some client has reported a cell size (`session_runtime.rs:49-54,140-149,380-389`). The cell size comes from the earliest driver's resize event (`session.rs:3914-3926,2178-2183`, `src/attachment_control.rs:102-104`); the CLI learns it by asking its own terminal `CSI 16 t` (`src/attach_mouse.rs:4`, `session.rs:566-576`). With no driver the last applied grid and cell size stay (`docs/multiplayer-attachments.md:18-20`). A session that has never had a driver reports 1x1 px cells to `16t` and 0 px to `TIOCGWINSZ`.

## 6. Deletion and cleanup

- Program deletes (`a=d`) are applied in the engine. The next render simply omits the placement or resource. The client drops anything the committed render does not reference (`image_delivery.rs:256`); the CLI sends `a=d,d=I` for its retired ids (`kitty_output.rs:180-190`).
- Detach, CLI side: writes `a=d,d=A,q=2` then mode resets, clear and leave alt screen (`session.rs:45-46`). Its hard-linked files are unlinked on drop (`image_backing.rs:145-155`).
- Detach, daemon side: nothing in the engine changes; the session keeps running and keeps its pixels. The channel's resident set goes away, and the daemon's backing file for a generation is unlinked when the last holder drops it (weak cache, `image_delivery.rs:37-46`). A later attach recaptures from the engine and redelivers everything visible.
- Library client reconnect: the provider clears its received images and gets a fresh full delivery (`src/provider_daemon.rs:464-468`).
- Resize: the PTY and engine are resized, history caches cleared, and the render marked fully dirty (`src/vt/ghostty.rs:292-299`, `actor.rs:1040-1044`). Images are not re-sent unless a generation is new; placements are re-resolved each render. The CLI deletes all displayed placements when grid size, pan origin, viewport or screen (main/alt) changes, then re-places (`kitty_output.rs:91-101`).
- Crash: an abruptly killed process can leave `cleat-image-*` files in the temp dir; there is no reclamation yet (ADR 0005:17).

## Not determined / caveats

- What Ghostty does to image placements on reflow, on screen clear, and exactly which image it evicts at the storage limit. I did not read those paths beyond locating them.
- Whether an `a=q` probe with `t=s` unlinks the probe's shm object.
- How ids look to a client when the program uses image numbers (`I=`) or omits an id. Presumably Ghostty-assigned ids; not checked.
- Whether a Ghostty session can still be attached through the raw-stream endpoint, and what a raw client would see. The replay payload is Ghostty's VT formatter output (`src/vt/ghostty.rs:493-513`), and closed cleat issue flotilla-org/cleat#50 records that the formatter drops kitty images.
- Local checkout is behind upstream. Upstream changes relevant here, seen by diff but not studied: #248 forwards a library client's cell pixel size to daemon sessions (at local `HEAD` only packet resize events carry it); #249 defers presentation until synchronized output completes; session transfer between daemons re-encodes engine images as kitty commands (`src/vt/ghostty.rs` upstream); C ABI version goes 9 to 10.
- cleat issue flotilla-org/cleat#206 remains open for a full acceptance audit (multiple viewers, reconnect, history, input media, fallback, cleanup). Its status note says basic delivery works with Katzensteg. No visual GUI assertion was made in cleat's validation (`docs/validation-image-delivery-2026-09-17.md:39`). Sustained 30/60 fps cost is unmeasured (flotilla-org/cleat#229).
- flotilla-org/cleat#216 ("session surfaces") is a brainstorm about cleat compositing Katzensteg panels over a session; related direction, not implemented.

## What this means for the WM

Facts that shape any design:

- Producer id renaming in `src/katzensteg/wm/graphics_output.zig` has nothing to act on unless the WM consumes `cleat attach` output. From cleat the WM gets descriptors and pixels, not commands.
- Placeholders, files and shm used by the program inside the session are cleat's problem and already handled. The WM sees one uniform shape: placements plus decoded pixels.
- Every image generation costs at least: engine copy, daemon file write, then whatever the WM does to show it. A producer streaming frames under a stable id makes a new generation per frame.
- The program's graphics probes succeed regardless of the WM or its terminal. A katzensteg producer's file-transport probes inside a cleat session succeed if the daemon can read its files.
- Someone must report a cell pixel size as a driver, or programs see 0 px (`TIOCGWINSZ`) and 1 px cells (`16t`).

Options, not ranked:

1. **WM as packet client through the C ABI** (`libcleat` provider, daemon backend). Per update: grid, placements, and a byte pointer per `(image_id, generation)`. The WM uploads pixels under WM-owned ids and places them clipped to the window rectangle, as it does for producers. Needs linking a Rust library into the Zig build and an exactly matching cleat version. No file path is exposed, so the WM would write its own file or shm for the outer terminal.
2. **WM speaks the packet protocol itself in Zig.** Same data as option 1, plus the file offer: the WM can hard-link cleat's immutable backing file and hand that path to the outer terminal as `t=f` with no pixel copy in the WM. Costs a protocol implementation that must track cleat's version (postcard-encoded frames, `src/packet.rs:275`; version 9 locally).
3. **WM hosts `cleat attach` in a PTY and treats it as a producer-like byte stream.** The WM would need a VT engine for the cells, would rename cleat's ids (1, 2, 3...) in `graphics_output.zig`, translate cursor-addressed placements into the window rectangle, and answer cleat's `q=0` upload replies within 5 s or lose images. cleat's files are readable `t=f` paths, so pixels need no re-encode.
4. **For the WM's display of virtual placements**, either draw the resolved rectangles as explicit placements (what `cleat attach` does) or re-emit them as the WM's own placeholder cells under a WM id (what the WM's placeholder mode does for producers). The grid cells still contain U+10EEEE and must be blanked or rewritten in both cases.
5. **Upstream work in cleat instead of the WM**: expose the backing path through the C ABI, or the producer-owned shm lease and Jackstay paths that ADR 0005 and flotilla-org/cleat#102 defer. These remove copies but are not available today.
