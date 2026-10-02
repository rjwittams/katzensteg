# What cleat gives a client that is not a terminal

Research for rjwittams/katzensteg#90 (map: #89). Source: `~/dev/cleat`
(`flotilla-org/cleat`) at `f04ce23`. Paths below are relative to that checkout;
`src/` means `crates/cleat/src/`. Nothing here was run; it is a reading of code
and docs.

## Short answer

Cleat has two attach transports on one per-daemon socket. The older one streams
raw PTY bytes and suits a client that is itself a terminal. The newer "packet"
transport sends a rendered cell grid as row-level diffs, takes structured input,
and is what a non-terminal client uses. A C ABI over the packet transport
already exists (`libcleat` cdylib plus `cleat_provider.h`), and a C GUI
application (Wheelhouse) consumes it today.

## Transports and packets

One daemon, one socket: `<state-root>/<daemon-name>/socket` (`src/runtime.rs:163`,
README.md:89-100). A named pipe on Windows (`src/platform/ipc/windows.rs:118-125`).
The socket speaks HTTP/1.1; attach endpoints upgrade the connection
(`src/http_uds.rs:505-541`).

### Packet transport (`Upgrade: cleat-packet/1`)

- Open with `POST /connect`, JSON body `{selectors, screen_activity_stable_ms}`,
  headers `Connection: Upgrade`, `Upgrade: cleat-packet/1`
  (`src/provider_daemon.rs:672-705`, daemon side `src/session.rs:2900-2940`).
- After `101`, the daemon sends `ControlHello` then a `DirectorySnapshot`
  (`src/session.rs:2929-2930`).
- Frame: `channel u32 LE | msg_type u8 | len u32 LE | payload`, 9-byte header,
  payload at most 4 MiB (`src/packet.rs:61-62`, `292-299`).
- Payloads are **postcard**-encoded serde structs (`src/packet.rs:274-284`).
  There is no schema file; the Rust types are the definition.
- Protocol version 9. The hello advertises `min_supported_version == version`,
  so client and daemon must match exactly (`src/packet.rs:12`, `70-80`;
  docs/multiplayer-attachments.md:113-114).
- Channel 0 is control; each attached session gets a client-chosen non-zero
  channel on the same connection (`src/packet.rs:13`, `src/provider_daemon.rs:1-12`).

Message types (`src/packet.rs:15-34`):

| id | name | direction | payload type |
|---|---|---|---|
| 1 | CONTROL_HELLO | d→c | `ControlHello` |
| 2 / 3 | DIRECTORY_SNAPSHOT / DELTA | d→c | `DirectorySnapshot` / `DirectoryDelta` |
| 4 / 5 | OPEN_CHANNEL / CLOSE_CHANNEL | c→d | `OpenChannel` / `CloseChannel` |
| 6 | CONTROL_ERROR | d→c | `ControlError {channel, message}` |
| 7 / 8 | ACTIVITY_SNAPSHOT / EVENT | d→c | `ActivitySnapshot` / `ActivityEvent` |
| 16 | SESSION_RENDER | d→c | `RenderPacket` |
| 17 | SESSION_ACK | c→d | `Ack {generation}` |
| 18 | SESSION_INPUT | c→d | `Input {event: TerminalInputEvent}` |
| 19 | SESSION_RESIZE | c→d | `Resize {cols, rows}` |
| 20 | SESSION_VIEWPORT | c→d | `Viewport {command}` |
| 21 | SESSION_ROLE | both | `RoleRequest` up, `RoleState` down |
| 22 | SESSION_VIEW_STATE | d→c | `ViewState` |
| 23 | SESSION_SIZE_POLICY | c→d | `Option<Resize>` |
| 24 | SESSION_IMAGE | d→c | `ImageChunk` |
| 25 / 26 | SESSION_IMAGE_FILE / _RESULT | d→c / c→d | `ImageFile` / `ImageFileResult` |

### Raw-stream transport (`Upgrade: cleat-attach/1`)

- `POST /sessions/{id}/attach` or `/watch` with JSON `AttachRequest {cols, rows,
  capabilities {color_level, kitty_keyboard}, identity, take, strict}`
  (`src/http_uds.rs:85-109`, `444-447`; `src/session.rs:2955-3074`).
- Frame: `tag u8 | len u32 LE | payload` (`src/protocol.rs:146-152`, `271-277`).
  Tags: 2 Input (bytes), 3 Output (raw PTY bytes), 4 Resize (cols, rows u16 LE),
  9 Error (UTF-8), 10 SeatState (JSON) (`src/protocol.rs:175-181`).
- On attach the daemon sends a replay: VT escape sequences, produced by
  Ghostty's formatter, that repaint current terminal state (modes, scrolling
  region, cursor, styles, palette) into a terminal (`src/vt/ghostty.rs:493-513`;
  `src/session.rs:2989-2996`). The client must be, or contain, a VT emulator.
- One controller at most; extra attaches become watchers
  (`src/session.rs:2962-3003`). Docs call this the "old raw-stream attach
  endpoint" with an "exclusive compatibility policy"
  (docs/multiplayer-attachments.md:37-38).

## What a packet client receives

A rendered cell grid as diffs. No raw PTY bytes on this transport.

`RenderPacket {update: TerminalRenderUpdate, links, view}` (`src/packet.rs:230-234`).
`TerminalRenderUpdate` (`src/provider.rs:137-151`) carries:

- `cols`, `rows`, `geometry`, `viewport_kind` (live normal, live alternate,
  scrollback), `scrollback_offset_rows`, `scrollbar` (total rows, viewport top,
  at-bottom), `render_generation`
- `terminal_modes`: alternate screen, application cursor keys, mouse tracking
  mode and report format (`include/cleat_provider.h:301-310`)
- `cursor`: col, row, visible, style, blink (`src/provider.rs:567-574`)
- `dirty` and `ops`. Op kinds: `FullVisibleReplace`, `RowReplace`, `ScrollCopy`
  (`src/provider.rs:62-78`). The header comment says scrolling "currently falls
  back to full visible replacement until Ghostty exposes scroll/copy damage"
  (`include/cleat_provider.h:620-626`).
- Each row holds cells; each cell holds `graphemes: Vec<u32>` and a style with
  resolved fg/bg RGB, the original palette-or-RGB colour tags, flags (bold,
  italic, faint, blink, inverse, invisible, strikethrough, overline, underline),
  underline style and colour, width (narrow, wide, spacer), hyperlink id
  (`src/provider.rs:81-119`, `497-510`, `547-553`).
- `image_resources` and `image_placements`: kitty-graphics images the session's
  program drew, as descriptors plus cell and pixel placement
  (`src/provider.rs:154-162`, `205-223`). Bytes arrive before the render that
  references them, as a file offer (hard-linkable local path) or 64 KiB chunks
  (`docs/adr/0005-retained-image-delivery.md`; `src/packet.rs:36-59`).

Delivery is ack-gated: one unacknowledged render per channel; the daemon
coalesces while waiting, so a slow client gets fewer, larger diffs
(`src/provider_daemon.rs:5-7`; `src/session.rs:3897-3907`, `4256-4263`). Client
output backlog is capped at 4 MiB (`src/session.rs:48`).

Not in the packet: window title. `CONTEXT.md:122-126` says the Update Packet
carries title, cwd, palette and selection, but `TerminalRenderUpdate` has no
such fields and there is no `title` in `src/provider.rs`, `src/packet.rs` or
`src/vt/mod.rs`. Cwd is available from `GET /sessions/{id}`
(`src/protocol.rs:83-90`).

## What a client gets on attach

- A `RoleState` (granted role, controller identity, participants, exclusive
  holder, fixed size), then a full-dirty render of the visible grid
  (`src/session.rs:4153-4202`; `src/packet.rs:154-155`;
  `include/cleat_provider.h:614-617`).
- Scrollback is not pushed. A client moves its own view with
  `Viewport {Top | Bottom | DeltaRows(n)}`; the daemon captures that history
  window and sends it as a render with `view.status = History`
  (`src/provider.rs:388-392`; `src/session.rs:4038-4064`, `4273-4295`). Each
  attachment has an independent history position; browsing does not move the
  live view or other clients (docs/multiplayer-attachments.md:91-110). Limits:
  128 history views per session, one history capture per 34 ms per channel,
  32,768 cells per capture (docs/multiplayer-attachments.md:97-102).
- Wheel events from a watcher, or when the program has no mouse tracking, are
  turned into history scrolling daemon-side (`src/session.rs:3934-3966`).
- No replay of past output on this transport. Raw history lives in the
  asciicast recording (`session.cast`), read by `cleat transcript`
  (README.md:118, 141).
- After a reconnect the client re-opens its channels and gets a full render
  again (`src/provider_daemon.rs:439-486`).
- Scrollback depth: `DEFAULT_MAX_SCROLLBACK = 10_000` (`src/vt/ghostty.rs:26`).
  A comment at `src/vt/ghostty_ffi.rs:1292-1296` indicates the value is set as
  Ghostty's `ScrollbackMaxBytes`. I did not determine the effective depth in
  rows.

## Drivers and watchers

The code and C ABI say "controller"; the multiplayer doc says "driver". Same
thing.

- Role is requested in `OpenChannel {role, take, identity}` and changed later
  with `RoleRequest`; the grant comes back as `RoleState` and can change at any
  time (`src/packet.rs:145-182`).
- Several packet controllers may drive at once. `take = true` requests
  exclusivity and demotes the others to watchers without disconnecting them;
  while exclusivity is held, new controller requests are granted watcher
  (`src/attachment_control.rs:26-39`; docs/multiplayer-attachments.md:10-16).
- A controller's keys, text, paste, raw bytes and mouse reach the PTY. A
  watcher's are dropped daemon-side, except wheel (history scroll), focus and
  resize bookkeeping (`src/session.rs:3913-4007`). The client library also
  refuses to send them (`src/provider_daemon.rs:327-349`).
- Watchers get the same renders and may browse history
  (docs/multiplayer-attachments.md:5-6).
- Counts: I found no cap on controllers or watchers. The only stated limit is
  128 history views per session. `CONTEXT.md:151-155` still describes "at most
  one controller"; the code and the newer multiplayer doc supersede it.
- A raw-stream controller and packet controllers exclude each other: a packet
  controller request while a raw-stream client holds the seat is granted
  watcher unless `take` (`src/session.rs:3833-3842`).
- `send-keys` and the other HTTP input endpoints work regardless of roles
  (docs/multiplayer-attachments.md:15-16).

## Resize

- `Resize {cols, rows}` on the session channel (`src/packet.rs:253-256`).
- The PTY size is the minimum cols and minimum rows over controllers. Watchers
  never vote. With no controllers the last size stays
  (`src/attachment_control.rs:106-110`; `src/session.rs:2184-2189`).
- Opening a channel does not resize; the client library sends a `Resize` right
  after `OpenChannel` (`src/provider_daemon.rs:383-386`).
- `SIZE_POLICY Some(Resize)` pins a fixed size, `None` restores automatic
  sizing; controllers only (`src/session.rs:4025-4037`).
- A watcher, or a controller larger than the shared grid, must letterbox or pan
  locally: every render carries the grid's real `cols` and `rows`
  (CONTEXT.md:178-180).
- Cell pixel size reaches the daemon only through
  `TerminalInputEvent::Resize {cols, rows, cell_width_px, cell_height_px}`
  (`src/session.rs:3914-3929`). The earliest controller's cell size becomes the
  PTY's pixel geometry (`src/attachment_control.rs:100-104`). In the C API,
  `cleat_session_update_geometry` on a daemon session only stores the value
  locally (`src/provider_ffi.rs:1557-1560`); the `CLEAT_INPUT_RESIZE` event is
  the path that sends it (`src/provider_ffi.rs:2380-2385`).

## Input

All input is `Input {event: TerminalInputEvent}` (`src/packet.rs:248-250`;
enum at `src/provider.rs:610-618`). The client sends structured events; the
daemon encodes them for the program using the session's live terminal modes
(docs/structured-keyboard.md:3-7).

- **Key**: `TerminalKeyEvent {key, modifiers, consumed_modifiers, action,
  generated_text, platform_keycode, physical_key}` (`src/provider.rs:621-631`).
  `key` is a Unicode scalar, a named key (Enter, Escape, arrows, F-keys...), or
  a W3C code string such as `NumpadEnter`. `physical_key` is an optional W3C
  code such as `KeyW`. Actions are press, repeat, release. The daemon runs
  Ghostty's key encoder, so legacy versus kitty keyboard encoding and
  application cursor mode are chosen for the client. A client that sends a
  structured press must send the release
  (docs/structured-keyboard.md:15-40, 122-123).
- **Text**: UTF-8, written to the PTY as is (`src/session.rs:4341`).
- **Paste**: UTF-8 text; the daemon wraps it in bracketed-paste markers when
  the program enabled that mode (`src/session.rs:4342`; `src/vt/ghostty.rs:343-346`).
- **Mouse**: `kind` (press, release, move, wheel), `button`, `buttons` mask,
  `modifiers`, `cell_col`, `cell_row`, `x_px`, `y_px`, wheel deltas
  (`src/provider.rs:686-715`). The daemon scales pixels from the sender's cell
  size to the application's and encodes per the program's mouse mode
  (`src/session.rs:3967-3984`, `4361-4394`).
- **Focus**: union of controller focus, gated by the program's focus-reporting
  mode (docs/multiplayer-attachments.md:23-24).
- **RawBytes**: written to the PTY unchanged (`src/session.rs:4343`).

## Starting and ending a session

- Start: `POST /sessions` with JSON `SessionMetadata {id, vt_engine, cwd, cmd,
  tags, environment, record, initial_size, colors}` (`src/runtime.rs:54-67`;
  `src/session.rs:1189-1231`). The id is client-assignable; launching an id that
  is already live reuses it (README.md:67). Then `OpenChannel` to attach.
- The daemon auto-starts on first use. The client library spawns
  `cleat --runtime-root R --server NAME serve`, finding the `cleat` binary next
  to the current executable, in its parent directory, or on `PATH`
  (`src/session.rs:4664-4681`; `src/platform/daemon.rs:24-49`, `83-117`).
- End: the child process exits. The daemon sends `ControlError {channel,
  "session <id> exited"}` on each attached channel, removes the session from
  the directory, and drops the channels (`src/session.rs:2067-2072`,
  `2126-2139`). The session directory is kept only if it has a recording, which
  makes it recreatable (`src/session.rs:2489-2495`; README.md:106).
- Kill: `DELETE /sessions/{id}` sends a terminate signal to the process tree
  (`src/session.rs:2948-2954`). The C API has no kill call;
  `cleat_session_destroy` only closes the channel (`src/provider_ffi.rs:686-690`,
  `1489-1493`).
- A session survives all clients leaving: "Disconnecting an attachment leaves
  the session running" (docs/multiplayer-attachments.md:28-29). The daemon
  exits after 120 s with no sessions, not with no clients
  (`src/session.rs:54`, `2077-2081`).
- A daemon crash or reboot loses the process; a recorded session can be
  recreated with its history as scrollback and the command re-run
  (docs/adr/0001-session-hosting-and-recreation.md:6-12, 34-36).

## Client library

- The `cleat` crate builds as `rlib` and `cdylib` (`crates/cleat/Cargo.toml:9`),
  so `libcleat.dylib` / `.so` / `cleat.dll`. No `staticlib` target.
- C header: `crates/cleat/include/cleat_provider.h`, ABI version 9
  (line 12). Zig can `@cImport` it.
- Shape: `cleat_provider_open` with `backend = CLEAT_PROVIDER_BACKEND_DAEMON`,
  runtime root and daemon name (lines 158-178, 505);
  `cleat_session_create` (starts the daemon if needed, creates the session,
  opens a channel) or `cleat_session_attach` by id (lines 527-534);
  `cleat_provider_set_wake_callback` (edge-triggered, may fire on a
  library-owned IO thread, lines 506-513); `cleat_session_poll` /
  `cleat_session_render_update` / `cleat_session_release_render_update`
  (lines 587, 627, 646); `cleat_session_send_input`, `_send_input_batch`,
  `_write_bytes`, `_resize`, `_set_role`, `_take_control`, `_set_fixed_size`,
  `_scroll_viewport`, `_connection_state`, `_role`
  (lines 548-606); directory snapshot of the daemon's sessions (lines 523-525);
  image bytes by callback (lines 635-639).
- The library owns a reader thread per daemon connection, reconnects with
  backoff, re-opens channels, and acks a render when the caller consumes it
  (`src/provider_daemon.rs:9-12`, `419-437`; `src/provider_ffi.rs:2038-2041`).
- `cleat_session_snapshot` returns false for daemon sessions; render updates
  are the only grid source, and the client keeps its own grid
  (`include/cleat_provider.h:614-617`).
- Creating a Ghostty session checks the engine is compiled into the *client's*
  build of the library (`src/session.rs:1199`; `src/vt/mod.rs:267-281`). With
  default features `libcleat` links `libghostty-vt`, static when available on
  Unix (README.md:55). Attach-only does not hit that check.
- Existing consumer: Wheelhouse, a C application, links `libcleat` dynamically
  and builds against this header
  (docs/research-wheelhouse-images-2026-09-17.md:9-13).
- There is also a Rust `PacketClient` (`src/packet.rs:335-434`) and a polling
  HTTP surface: `GET /sessions/{id}/snapshot` returns the full grid as JSON,
  `/screen` returns text, `POST /sessions/{id}/input`, `/keys`, `/resize`
  (`src/http_uds.rs:505-541`, `248-259`).

## Not determined

- Effective scrollback depth in rows (see above).
- Whether any cap exists on attachments per session beyond the 128 history
  views. None found.
- Whether `libcleat` is packaged or installed anywhere other than a cargo
  `target/` directory. No prebuilt library was present in the checkout.
- Stability policy for the C ABI and packet protocol. The docs record
  packet versions 7, 8 and 9 as successive recent changes, and both the ABI and
  the protocol require an exact match (docs/multiplayer-attachments.md:113-114;
  docs/adr/0005-retained-image-delivery.md; docs/structured-keyboard.md:110-114).
  I did not date the bumps from git history.
- Behaviour on Linux and Windows for multiplayer: the doc says native
  Linux/Windows runtime validation "remain separate work"
  (docs/multiplayer-attachments.md:148-149).
- Whether the live daemon image path now delivers bytes to C clients. ADR 0005
  says it does as of protocol 8; the header comment at
  `include/cleat_provider.h:628-633` still says the image callback "currently
  succeeds only for in-process sessions", while the code has a daemon branch
  (`src/provider_ffi.rs:2083-2088`). Not exercised here.

## What this means for the WM

Facts that bear on the design:

- The WM would paint from a cell grid with resolved colours, not parse VT.
  Cleat owns the emulator.
- The WM must keep its own copy of each session's grid and apply row ops.
- The WM sends its native-key vocabulary almost directly: cleat's key event
  uses W3C code names, press/repeat/release and modifier bits.
- As a controller, the WM's rectangle sets the PTY size (minimum over
  controllers). As a watcher it must fit or pan a grid it does not size.
- Programs inside the session may draw kitty images. Those arrive as resources
  and placements relative to the grid, with bytes as a local file the WM could
  hand to the outer terminal with `t=f`.
- The session outlives the WM. Closing a WM window and killing the session are
  different operations; the second needs HTTP `DELETE` or the `cleat` CLI.
- Title is not delivered.

Integration options, not ranked:

1. **Link `libcleat` through the C header.** Reuses reconnect, acks, image
   acquisition and session creation. Costs: a Rust cdylib (and, with default
   features, Ghostty VT) in the WM's build and runtime; a library-owned thread
   whose wake callback must be bridged to the WM's libxev loop; exact version
   match with the `cleat` binary, which must be findable beside the WM binary
   or on `PATH`; Wheelhouse is the only known consumer, so the ABI moves with
   its needs.
2. **Reimplement the packet client in Zig.** HTTP upgrade, 9-byte framing and
   a postcard decoder for the types above; socket fd goes straight into libxev.
   Costs: postcard has no schema, so the Zig decoder must track Rust struct
   field order by hand; the protocol is at its third recent version (7, 8, 9)
   and rejects any mismatch; session creation and daemon start need the HTTP JSON
   calls or a `cleat launch` subprocess; image file acquisition would be
   reimplemented.
3. **Poll the HTTP JSON surface.** `GET /snapshot` for the grid, `POST /input`
   and `/resize`. Smallest code. Costs: no push, full grid per poll, no role or
   presence, out-of-band input bypasses the driver model, no images.
4. **Raw-stream attach plus a VT emulator in the WM.** Costs: the WM needs its
   own emulator (for example libghostty-vt), duplicating cleat's; the endpoint
   is the legacy one with a single-controller policy.
5. **Ask cleat for a change.** For example a `staticlib` target, an fd-based
   wake instead of a thread callback, a kill call, or title in the packet.
   These are requests to another repo, not things this repo can do alone.
