# Stdio Render Batch Protocol

Date: 2026-04-28
Status: First-cut design

This note defines the first proof path for embedding Katzensteg-rendered visuals inside an agent-owned terminal UI. It uses the existing preload launcher path. The launcher still resolves profiles, sets preload/runtime configuration, redirects target output as needed, and supervises the child. The preloaded runtime still owns capture and terminal graphics protocol construction.

The new piece is an embed presentation mode where the runtime emits renderer-generated render batches to a host-owned stream instead of writing directly to `/dev/tty`.

Embed mode is explicitly requested from the launcher, for example:

```sh
./zig-out/bin/katzensteg --embed-jsonl probe.embed.basic_sdl
```

Profiles may provide embed-friendly runtime defaults, but they should not silently turn a normal human launcher run into a JSONL protocol stream. The launcher flag is the explicit signal that stdout belongs to the embedding client.

## Target Proof

The initial end-to-end proof is:

1. A small test harness launches Katzensteg in embed mode and displays received render batches.
2. Katzensteg captures a tiny SDL2 or pygame program through the normal preload path.
3. A Pi agent extension launches the same profile and chooses whether the visual appears inline in conversation or in a special pane.

Pi is the first integration target because it is expected to be easiest to modify. Open-source Codex is a likely second integration target after the test programs and Pi extension prove the shape.

## Non-Goals

- Do not make this MCP, JSON-RPC, or a socket protocol in the first cut.
- Do not require clients to construct Kitty/iTerm2/Sixel/APC escapes.
- Do not send rich per-operation metadata by default.
- Do not add a stderr event path for the first proof.
- Do not solve target stdout as an interactive event stream in the first visual proof.
- Do not replace the existing direct `/dev/tty` presentation path.

Socket mode, binary framing, richer metadata, stdout event forwarding, input/focus events, and MCP adapters can be later extensions.

## Ownership Model

The PTY owner or embedding client owns:

- conversation UI and terminal layout
- inline-versus-pane placement choice
- target window geometry
- terminal capability detection and upload profile choice
- id ranges granted to the render runtime
- eventual keyboard/mouse/focus routing

The Katzensteg launcher owns:

- profile resolution
- preload/runtime environment setup
- target process supervision
- target stdout redirection or suppression according to launch policy
- launcher quiet mode for embed use
- terminal reset after the target exits or crashes

The preloaded runtime owns:

- SDL/OpenGL/Vulkan capture
- frame composition and frame dropping
- terminal graphics protocol construction
- image id and placement id allocation inside granted ranges
- render batch emission
- direct `/dev/tty` presentation when not in embed mode

In embed mode, the launcher should mostly arrange configuration and file descriptors, then pass through. It should not become the semantic render protocol broker.

## Attach Gate

The runtime should not emit APCs, placements, uploads, or delete batches for a window until the host attaches to that window.

This keeps process launch separate from visual presentation. The target application may create an SDL window and present frames before the embedding client has chosen where that output belongs. In that case the runtime should capture or drop according to normal frame-dropping policy, but it should not write terminal graphics bytes to the batch stream.

The first cut only needs one window, `main`, but the protocol should still frame this as attachment:

```json
{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit","id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
```

After attach, the runtime may emit `frame_batch` messages for that window. If the host later changes layout, it can send another `attach` or `viewport` message for the same `window_id`.

The runtime may send non-graphics lifecycle messages before attach, such as `hello`, `launched`, or later `window_created`. Those messages must not contain terminal graphics bytes.

In `--embed-jsonl` mode, launcher stdin belongs to the embedding protocol. The launcher should pass client JSONL input through to a runtime control fd, while passing runtime JSONL output back to launcher stdout. This keeps the launcher as a byte pump rather than the protocol owner. Target program stdin is not part of the first visual proof.

## Transport And Envelope

The first transport is stdio or a launcher-configured file descriptor.

From the embedding client's perspective, the first transport is stdio:

```text
client -> katzensteg stdin: JSONL control messages such as hello/attach/viewport/shutdown
katzensteg stdout -> client: JSONL lifecycle and frame_batch messages
```

Inside the launcher, those streams may be forwarded to dedicated runtime fds so the target program's own stdout can remain redirected and the runtime does not have to compete with the target for process stdin/stdout.

The first envelope is Katzensteg-native JSONL:

```text
one UTF-8 JSON object per line
no JSON-RPC wrapper
no MCP lifecycle
no binary frame header
```

JSONL is deliberately chosen for the first proof because it is easy to inspect, easy for Python/Node/Rust/Zig harnesses to consume, and friendly to agent-extension code. A later binary framed protocol can carry raw byte chunks if JSON escaping overhead becomes material.

## Opaque Byte Groups

Render output is batched into labeled groups of terminal-ready byte strings. The host understands the group labels and ordering contract. It does not parse Kitty fields, placement ids, image ids, APC payloads, or placeholders.

The main groups are:

- `deletes`
- `uploads`
- `placements`
- `after`

The renderer constructs the terminal protocol bytes. The host schedules them within its own terminal UI frame.

Typical host behavior:

1. write `deletes` at a safe point for old graphics cleanup
2. write `uploads` before the visible placement phase
3. draw host-owned text/chrome as needed
4. write `placements` where the embedded visual should appear
5. write `after` for any renderer-generated trailing cleanup

The exact scheduling is host policy. The protocol only preserves enough grouping to avoid treating a whole frame as a single opaque "blat to screen" blob.

## JSON String Encoding

Terminal byte chunks are represented as JSON strings in the first cut.

This is acceptable for Kitty-style output because the image payload inside Kitty APCs is already base64 ASCII. JSON only has to escape control bytes such as ESC. This avoids double-base64 for the common inline Kitty case.

If a future mode needs arbitrary binary chunks that are not valid as JSON strings, use either:

- an explicit base64 field in JSONL, or
- a later binary framed transport

Do not make double-base64 the default path.

## Windows And Geometry

The protocol includes a `window_id` from the start, even though the first implementation may only support one window. This leaves room for multiple panes, attached views, or future host-managed surfaces without changing every message shape.

The host sends viewport information whenever the target placement changes:

```json
{"type":"viewport","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit"}
```

The runtime should treat this as the current destination policy for that logical render window. Geometry is not assumed to be fullscreen. The host may update it over time as the conversation layout, pane size, or terminal size changes.

This geometry model should not be treated as embed-only. Direct `/dev/tty` mode also needs the same concept over time: terminal menus may shrink a captured window, chrome may reserve space, multiple captured windows may share one terminal, and a user may later break one window out into a different view. The first cut only uses host-provided geometry for stdio embed mode, but the data model should not preclude direct-tty presentation layouts using the same window/viewport concepts.

Initial aspect policies can stay small:

- `stretch`
- `fit`
- `cover`

The first proof should probably use `fit`.

## Id Ranges

The host grants id ranges during handshake. The runtime allocates image ids and placement ids only inside those ranges. The same attach message carries the host-selected upload policy: `direct_apc`, `file_whole`, or `file_offset_ring`. File upload modes include a path that is valid for both the producer process and the terminal host.

Example:

```json
{"type":"hello","protocol":"katzensteg.render.v0","window_id":"main","id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]}}
```

This prevents collisions when the host has its own terminal graphics state or multiple embedded renderers.

Additional id spaces can be added later if the renderer needs them.

## Message Sketch

The first message set can remain intentionally small.

Host to runtime:

```json
{"type":"hello","protocol":"katzensteg.render.v0"}
{"type":"attach","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit","id_ranges":{"image":[[100000,199999]],"placement":[[200000,299999]]},"upload":{"profile":"file_whole","path":"/tmp/tty-graphics-protocol-katzensteg-12345.rgba","high_water":10485760}}
{"type":"viewport","window_id":"main","rect_cells":{"row":4,"col":1,"rows":24,"cols":80},"aspect":"fit"}
{"type":"shutdown"}
```

Runtime to host:

```json
{"type":"hello","protocol":"katzensteg.render.v0","capabilities":{"batch_groups":["deletes","uploads","placements","after"]}}
{"type":"launched","pid":12345}
{"type":"window_created","window_id":"main"}
{"type":"frame_batch","window_id":"main","seq":1,"groups":{"deletes":[],"uploads":["\u001b_G...;\u001b\\"],"placements":["\u001b[4;1H\u001b_G...;\u001b\\"],"after":[]}}
{"type":"status","level":"info","message":"first frame presented"}
```

These examples are illustrative, not a frozen schema. The important first-cut commitments are JSONL, explicit launcher embed mode, `window_id`, host attach before graphics output, host-provided id ranges, host-provided geometry/upload policy, and opaque renderer-generated byte groups.

## Launcher Configuration Implications

Embed mode should be expressed as launch/runtime configuration on the existing profile path.

Conceptual settings:

```text
launcher_ui = quiet
presentation_sink = stdout_batches | fd_batches | tty
target_stdout = file | ignore | inherit
```

The first Pi/test-harness proof likely wants:

```text
launcher flag = --embed-jsonl
launcher_ui = quiet
presentation_sink = stdout_batches
target_stdout = file
```

The exact profile schema can be designed when implementation starts. The important boundary is that the launcher flag arranges protocol stdout and avoids human-oriented output, while the preloaded runtime emits the batch stream after host attach.

## Target Stdout

Target stdout is deliberately not the first visual proof.

Today the launcher redirects target stdout to protect terminal rendering. Embed mode should keep that behavior initially. Later, interactive agent scenarios such as "pick one of these colours" may need target stdout forwarded to the PTY owner as a structured stream or side channel. That should be designed as a separate launch output policy, not folded into the initial graphics batch protocol.

## Open Questions

- Should the first implementation write batches to stdout or to a dedicated fd supplied by the launcher?
- How should host-to-runtime control messages reach the preloaded runtime in stdio mode?
- What is the smallest quiet-mode change needed so launcher output cannot corrupt the embedding host UI?
- Should deletes be purely renderer-scheduled in the first proof, or should the host be able to request a full cleanup batch for a window?
- How should terminal capability hints be represented without forcing the host to understand terminal graphics protocol details?
