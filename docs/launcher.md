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

## Injection

The SDL adapter fragments (`adapter.sdl2_preload`, `adapter.sdl3_preload`) name
Katzensteg's SDL library for each injection mechanism and platform:

```json
"sdl_adapter": {
  "api": "sdl2",
  "preload": { "linux": "{repo}/zig-out/lib/libkatzensteg-sdl2.so", "macos": "{repo}/zig-out/lib/libkatzensteg-sdl2.dylib" },
  "dynapi": { "linux": "{repo}/zig-out/lib/libkatzensteg-sdl2-dynapi.so", "macos": "{repo}/zig-out/lib/libkatzensteg-sdl2-dynapi.dylib", "windows": "{repo}/zig-out/bin/katzensteg-sdl2.dll" }
}
```

The profile field `injection` selects the mechanism, and the launcher sets the
matching variable:

| `injection` | Linux | macOS | Windows |
| --- | --- | --- | --- |
| `preload` | `LD_PRELOAD` | `DYLD_INSERT_LIBRARIES` | unavailable |
| `dynapi` | `SDL_DYNAMIC_API` / `SDL3_DYNAMIC_API` | same | same |
| `auto` (default) | `preload` | `preload` | `dynapi` |

With `dynapi`, SDL loads the library on its first call and hands it SDL's jump
table. Katzensteg asks the loading SDL to fill the table and keeps that copy as
the real functions, then substitutes its wrappers. It exports only
`SDL_DYNAPI_entry` and removes the variable, so child processes start without
it. The application needs an SDL built with its dynamic API, which is the
default, and must export `SDL_DYNAPI_entry` from the module that holds the
table: `SDL2.dll`/`SDL3.dll` and shared libraries do; applications that link SDL
statically on Windows do not. Only calls that go through SDL are covered,
including SDL's GL swap; applications that render through GL, Vulkan or Metal
directly still need platform hooks.

`KATZENSTEG_INJECTION=auto|preload|dynapi` overrides the profile for one launch,
and `--dry-run` prints the selected mechanism. A variable set explicitly in a
profile's `env` takes precedence over the adapter's library.

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

`KATZENSTEG_REPO` explicitly selects the repository for default profile lookup and
`{repo}` expansion. Otherwise, a launcher in `<repo>/zig-out/bin` prefers its own
repository when that directory contains `profiles/`, even when run from another
checkout. If the executable's inferred repository has no `profiles/`, the launcher
falls back to the current directory when it contains `profiles/`. If neither does,
it uses the executable's inferred repository.

## Real App Profiles

Real app profiles often assume:

- local source checkouts under `~/dev`
- patched app branches that expose output/input paths Katzensteg can currently exercise
- ROM, game, or media files that are not stored in this repository
- platform-specific build products

Always run `--dry-run` before trying a real app profile on a new machine. It shows the resolved command and environment without starting the target.

For the current app matrix, see `docs/external-projects.md`.


## WM External Clients

The WM can host producers connected through a local Unix socket alongside profiles it launches itself:

```sh
./zig-out/bin/katzensteg-wm --listen /tmp/my-wm.sock
./zig-out/bin/katzensteg-wm --listen /tmp/my-wm.sock --session probe.embed.basic_sdl
```

`--listen` must precede profiles or `--session`. Leading `~/` in the socket address is expanded by the WM. Binding happens before terminal initialization. An existing socket or file is never replaced; normal shutdown removes the socket created by this host. Listener mode stays available after the last window exits, including when started with initial profiles.

In another shell, select that WM and launch an existing profile:

```sh
export KATZENSTEG_TARGET="jsonl:/tmp/my-wm.sock"
./zig-out/bin/katzensteg probe.embed.basic_sdl
```

An unset target preserves standalone behaviour. An explicit invalid, unavailable or rejected target fails before the application starts, without opening or resetting the shell terminal. Leading `~/` in the address is expanded by the launcher. Registration has a five-second deadline. `--dry-run` reports the destination without connecting. Explicit `--embed-jsonl` takes precedence over the inherited target, so WM-owned and pi-owned launches keep using their existing pipes.

The shell launcher owns and reaps its application; the WM owns only its connection. Host disconnection or a window-close request terminates the application after a short grace period. Shell interruption also terminates and reaps it. Application stdin, profile-selected stdout/stderr and exit status remain separate from the rendering connection. This path currently requires an existing profile; arbitrary executable capture and reconnectable sessions are not implemented.

A client starts with one UTF-8 JSON line:

```json
{"type":"register","version":1,"title":"Monkey Island 2"}
```

The host replies with `{"type":"registered","version":1,"session_id":1}`, followed by the existing embedded `hello` and `attach` messages. The session ID is host-assigned and increases for each registration; the producer's window ID remains `main`. Subsequent traffic uses the existing embedded control and presentation protocols. Titles must contain 1–128 UTF-8 bytes without control characters. Registration is limited to 1,024 bytes, 16 pending clients and five seconds per handshake. Invalid registrations and excess connections are closed without disturbing existing windows.

The socket is mode `0600` and is a trusted, same-user rendering connection, like the existing embedded pipes. It carries terminal presentation commands, not an untrusted remote-display protocol. Incomplete registrations never block the event loop. Socket control output is buffered up to 512 KiB per client; exceeding that limit closes its control direction. Closing a window requests shutdown and drains final presentation output. On WM quit, external clients have two seconds to finish before their sockets are closed.

The host reuses completed slots (32 by default) after draining traffic and deleting that slot's graphics. Cleanup uses Kitty's image-ID range deletion, confirmed against the local Kitty implementation; terminals hosting the WM need support for that operation. Session IDs remain distinct when slots are reused.

## Hosted presentation modes in the WM

The normal WM can exercise either producer presentation mode:

```bash
# Existing positioned-image mode (the default):
./zig-out/bin/katzensteg-wm sonic mi2

# Unicode placeholder mode in the WM's own windows:
KATZENSTEG_REAL_WINDOW=hide ./zig-out/bin/katzensteg-wm \
  --presentation placeholder sonic mi2
```

Both commands run the same WM: window borders, movement, resizing, focus,
layouts, input routing and lifecycle handling. `--presentation positioned`
selects the default explicitly. Presentation selection is global for now;
initial profiles, interactive launches with Ctrl-] then `n`, and external registrations
through `--listen` all use the selected mode.

In placeholder mode the WM allocates a separate image ID for each producer,
fits a grid to the source aspect ratio inside the window, and draws Kitty
Unicode placeholder cells. The producer uploads frames bounded by the grid's physical pixel size under
that stable ID and reissues one `a=p,U=1` virtual placement per frame. The WM
positions and stacks the text grids, including clearing cells vacated by moved
or closed windows. Moving or raising a window does not change its producer's
virtual placement; resizing sends a new grid size when needed.

Press Ctrl-] before each WM command: `h/j/k/l` move, `H/J/K/L` resize, Tab
cycles focus, `t` tiles, `c` cascades, and `n` opens the launch prompt. `q` closes
the focused producer; `Q` quits the whole WM. Escape returns to the producer,
and a doubled Ctrl-] sends one literal tap. Mouse focus and title/border
controls work as in positioned mode. The WM translates content mouse events
into the grid's local coordinates before forwarding them. Hiding real SDL
windows avoids their mouse focus taking precedence over forwarded input.

This requires a terminal supporting Kitty Unicode placeholders, truecolour
text and the WM's selected image-upload medium. No Claude Code plugin, separate
placeholder drawer, image-ID argument or second terminal is needed.

### Producer control interface

Other hosts can select the same mode through the existing `--embed-jsonl`
producer connection:

```json
{"type":"attach","window_id":"main","placeholder":{"image_id":777,"cols":60,"rows":20,"target_px":{"w":600,"h":400}},"upload":{"profile":"file_whole","path":"/tmp/host-owned-upload.rgba"}}
{"type":"viewport","window_id":"main","placeholder":{"image_id":777,"cols":40,"rows":12,"target_px":{"w":400,"h":240}}}
```

The placeholder object replaces `rect_cells`, `aspect`, `id_ranges`, terminal
geometry, clipping and z-order. IDs are 1–16777215; grid dimensions are 1–297.
The host owns allocation, text placement, aspect fitting, terminal output and
upload-file cleanup. `frame_batch` responses use the existing groups and
presentation status reports source pixels without an absolute terminal
rectangle. A viewport may resize or refresh the same image; changing image
ownership or presentation kind requires a new attach. Setting
`refresh_placements: true` on a placeholder viewport re-uploads the retained
frame and reissues its virtual placement, even if the application has stopped
drawing. A cell-only change reissues the placement. Changing `target_px`
recomposes the retained scene at the new size, even without an application frame.

`target_px` is an optional upload-size bound in physical pixels. Each axis must
be 1–16384, with at most 16,777,216 pixels in total. It preserves source aspect
and never requests an upscale. Without it, producers retain their original
presentation resolution. SDL scenes are composed directly at the chosen size;
source textures, completed draw commands and cursor state are retained so a
full-resolution observation can be composed on demand. Already captured external
framebuffers are resized before upload. This does not change their GPU readback
path. Source metadata and input coordinates remain independent of upload size.

Input uses the existing messages. For `terminal_bytes`, pointer coordinates
are one-based positions within the virtual grid; keyboard bytes are unchanged.
The existing `source_pointer` message is also available. Detach and shutdown
retain their existing meanings.


## Headless placeholder host

An application that draws its own placeholder cells can use the WM's headless
frontend for producer management and graphics delivery. For example, a
restricted plugin can start or reuse a host with one process call:

```sh
./zig-out/bin/katzensteg-wm --headless --background
```

The command returns discovery JSON on stdout once the host is listening:

```json
{"pid":123,"port":456,"token":"...","tty":"/dev/ttys007","host_file":"/tmp/katzensteg-wm-501/....json","version":1}
```

Without `--background`, the host runs in the foreground and publishes only its
discovery file. `--tty /dev/ttys007` selects an explicit terminal. Otherwise it
resolves its controlling terminal to a concrete device path, then tries the
terminal of `--parent-pid` or `CLAUDE_PID` and walks ancestors. The concrete
device is opened before a background host detaches; the `/dev/tty` alias is
never retained across detach.
`--host-file <absolute-path>` overrides the discovery path; `--http
127.0.0.1:<port>` overrides the default ephemeral port. Other bind addresses are
rejected.

Hosts use a private directory under `/tmp/katzensteg-wm-<uid>`. A lifetime lock
per terminal prevents duplicate hosts, and discovery files have mode 0600 and
are published atomically. Repeated background starts authenticate with the
existing host before returning its descriptor. The host changes no terminal
modes, reads no keyboard input, and writes no borders, placeholder cells or
cursor movement. It emits file-upload graphics commands with quiet responses
and deletes only its own images. Small writes reduce interference with the
application's terminal output; they cannot guarantee atomic output between
independent writers.

### Direct-terminal command mode

Direct SDL2/SDL3 takeover sessions accept **Ctrl-]** as an attention key. Release
it, then press `q` to request app exit, or Escape to return to the app. Press
Ctrl-] twice to send one literal Ctrl-] tap. Holding the prefix does not count as
a second press when the terminal reports key releases.

Entering command mode releases held keys and mouse buttons and reports focus
loss to SDL. A command row covers the bottom terminal row without resizing the
game. It shows `q Quit`, `Esc Return` and the configured prefix for a literal
tap. Unknown keys leave it armed and display a hint; there is no timeout. Click
and release on Quit or Return to choose that action. Other mouse input and
bracketed pastes are discarded while armed. The row updates even when the game
is not drawing, and follows terminal resizes. The desktop WM uses the same
prefix and decoder, with its own commands shown in the existing status row.
Bare letters and Tab reach the focused producer. The launch prompt accepts
both legacy bytes and Kitty keyboard reports.

Set `KATZENSTEG_COMMAND_KEY='^X'` to choose another control key, or `none` to
disable the mode. The inheritable profile field is `runtime.command_key`, with
the same caret notation. Environment configuration overrides the profile.
Legacy terminals cannot distinguish some control keys from Tab, Enter or
Escape, and `^@` uses the NUL encoding shared with Ctrl-Space. Ctrl-] avoids
these ambiguities. Kitty reports match the base-layout
position plus modifiers when available.

Quit first queues an SDL quit event. The launcher allows 1.5 seconds for exit,
then sends TERM and, after another 250 ms, KILL if necessary. For a direct
session these signals target the launched child, which shares the terminal's
foreground process group with its caller. Terminal settings are restored after
forced termination. Launch through `katzensteg` for this supervision; direct
preload diagnostics can only offer the app the SDL quit event.

Hosted producers and terminal-free Jackstay publishers keep command mode
disabled, even when the environment sets a key. Their host owns input routing.
Wrapping an application still passes Ctrl-C through unchanged.

### Wrapping the application

`--wrap` runs a command on an inner PTY while the WM owns the outer terminal's
output. Options for the WM go before `--wrap`; all arguments after it (and an
optional `--`) belong to the child:

```sh
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 ./zig-out/bin/katzensteg-wm --wrap -- \
  claude --plugin-dir tools/claude-code-plugin
```

The child inherits `KATZENSTEG_WM_HOST`, containing the same discovery JSON as
the background host returns. A cooperating plugin uses this descriptor instead
of discovering a host on its inner PTY. HTTP, client registration, producer
launch, placeholder grid sizing and panel input keep their existing contracts.
Discovery and `/health` describe the outer terminal, including its cell pixels.

The outer terminal is raw while wrapping. Input bytes, including Ctrl-C, pass
unchanged to the child; the child's terminal modes determine their meaning.
Cell and pixel dimensions propagate to the inner PTY. On child exit the WM
drains output, closes its producers, restores the outer terminal modes and
returns the child's exit status. Wrapper termination or terminal loss also
cleans up the child. Wrapping is foreground-only and cannot share a terminal
with another headless host.

The relay keeps bounded input/output buffers and forwards child output without
building a screen model. Its graphics enter the stream only after complete
UTF-8 and escape sequences, including the last command of a chunked kitty
upload. Incomplete sequences delay graphics, not child output. Producer frames
are dropped while insertion is unsafe, then the latest retained frame is
requested. Both uploads and image deletions use the relay. Graphics commands
use quiet replies (`q=2`) and never move the cursor.

Terminal clears (`CSI 2 J` / `CSI 3 J`) request retained frames. Periodic idle
refresh defaults to off in wrap mode; pass `--idle-refresh-ms <ms>` before
`--wrap` to enable a fallback. This serialization covers the child stream and
WM graphics; unrelated processes writing directly to the outer device still
bypass it.

### Shared-terminal output

Before presenting a frame, the host checks `TIOCOUTQ`. If output is queued,
it drops the entire batch before writing any bytes and restores the producer's
latest retained frame once the queue clears. Recovery also works when periodic
idle refresh is disabled. Session order rotates so several panels can share
quiet intervals. Unsupported queue queries retain the small-write behavior.
This reduces opportunities for interleaving; a queue check does not lock out
another writer, and lifecycle cleanup writes remain best-effort.

### HTTP clients and sessions

Every request requires `Authorization: Bearer <token>`. Missing or incorrect
authorization returns 401 with an empty body. Requests and responses use JSON.
The HTTP adapter supports bounded requests, without keepalive or chunked bodies.

1. `GET /v1/health` returns `{pid,tty,version,cell_px:{w,h}|null}`. Cell pixels
   come from terminal geometry via ioctl; no terminal query is emitted.
2. `POST /v1/clients {}` creates a plugin client and returns
   `{id,target,lease_ms}`. Retain its ID and set `KATZENSTEG_TARGET` to the
   returned `jsonl:<socket>` value in that client's shell environment.
   An optional `{"parent_pid":123}` binds this client to a live process.
   The host checks once per second and closes the client when that process
   disappears. This does not bind the shared host or any other client.
3. Send `X-Katzensteg-Client: <id>` with every client-scoped request below.
   `GET /v1/sessions` lists only that client's sessions. Polling every 250–500 ms
   is sufficient for metadata changes; frames stream independently.
4. `POST /v1/client/close {}` closes that client's sessions and listener.
   Every client-scoped request renews a 120-second lease. An idle client can use
   `POST /v1/client/heartbeat {}`. Expired clients are closed, and the host exits
   after 30 seconds without clients. SIGTERM, SIGINT and SIGHUP also shut it down.

The headless CLI takes no profiles or `--listen` argument: sessions belong to
clients, and each client receives its own automatically allocated registration
socket. Ordinary shell launches through `KATZENSTEG_TARGET` appear in that
client's session list, using the same producer interface as HTTP launches.

| Request | Body | Response |
| --- | --- | --- |
| `GET /v1/sessions` | — | Array of `{id,title,image_id,state,source_px,grid}` |
| `POST /v1/sessions` | `{profile,args?:[]}` | `{id}` |
| `POST /v1/sessions/{id}/grid` | `{cols,rows}` | `{}` |
| `POST /v1/sessions/{id}/observe` | `{after_frame?:N}` | `{path,width,height,frame_id,timestamp_ms,newer}` |
| `POST /v1/sessions/{id}/refresh` | `{}` | `{}` |
| `POST /v1/sessions/{id}/input` | `{events:[...]}` | `{}` |
| `POST /v1/sessions/{id}/close` | `{}` | `{}` |

Session IDs are numbers, monotonically allocated during the host lifetime.
State is `starting`, `ready`, `closing` or `exited`. The list is authoritative;
exited records remain for 30 seconds. Clients should remove cells for closing,
exited or absent sessions. Access to another client's session returns 404.
A launch response acknowledges acceptance: later application startup failures
appear as exited sessions. Synchronous errors return 400 with an `error` field, except handler memory
exhaustion, which returns 503 `OutOfMemory`.

A producer starts with a temporary 1×1 virtual grid so it can report source
pixels. Its graphics are withheld until the client supplies the grid it drew.
Grid dimensions must each be 1–297 and are applied exactly and idempotently.
The client owns aspect fitting, using `source_px` and `/health`'s `cell_px`.
If cell pixels are unavailable, the client must choose its own explicit
configuration or fallback. The WM derives `target_px` from the assigned cells
and the terminal's physical cell size. It updates the producer when either
changes, including pixel-only terminal resizes. No HTTP client change is needed.
If terminal pixel dimensions are unknown, it omits the bound rather than guessing.

`POST /v1/sessions/{id}/refresh {}` restores the retained frame and virtual
placement after a terminal clear. It requires an assigned grid. Initial grid
assignment and grid changes also request a restore. Ready sessions with no
recent frames are refreshed every 500 ms; `--idle-refresh-ms <ms>` changes this
interval and `0` disables it. No periodic refresh is requested while frames
arrive within that interval. A failed graphics write closes the affected
session; cleanup failures are logged without stopping the host.

Observation returns a source-resolution RGBA PNG under the session's private
runtime directory, mode 0600. It atomically replaces the same file on each
capture and is deleted on session or host exit. Placeholder producers retain
the completed scene or external framebuffer automatically; no
`KATZENSTEG_OBSERVE` environment setting is needed.
With `after_frame`, the request waits up to two seconds for a newer retained
frame, then returns the latest available with `newer: false` if necessary.
This wait leaves the host free to deliver frames, process input and serve other
clients. If no frame is available by the deadline, it returns 503 `NoFrame`.
One observation request may be pending per session; a concurrent request gets
409 `ObservationPending`. Frame IDs count captured frames; refreshes do not
advance them. PNG encoding uses stored DEFLATE blocks and runs only on demand.

Input requests preserve event order and validate the complete request before
queuing input. Up to 64 events may be sent together:

```json
{"events":[{"type":"key","key":"escape"}]}
{"events":[{"type":"key","key":"up","ctrl":true,"action":"down"}]}
{"events":[{"type":"key","key":"up","action":"up"}]}
{"events":[{"type":"pointer","kind":"down","x":0,"y":0,"button":"left"},{"type":"pointer","kind":"up","x":0,"y":0,"button":"left"}]}
```

Keys accept single Unicode characters, `enter`/`return`, `escape`, `tab`,
`backspace`, `space`, `delete`, `insert`, arrow names, `home`, `end`, `pageup`,
`pagedown` and `f1`–`f12`. Modifiers are `ctrl`, `shift`, `alt` and `meta`;
`action` is `tap` by default, or `down`/`up` for clients with held-key events.
The producer's canonical input model supplies key events and polling state.
Pointer coordinates are zero-based within the drawn grid. `kind` is `down`,
`move` or `up`; down/up require `left`, `middle` or `right`. The host tracks
button state per session. Out-of-grid coordinates return 400.

Event long-polling and Kitty frame-edit uploads are deferred. The Claude Code
plugin in `tools/claude-code-plugin/` uses the client-scoped interface above.

### Terminal image transport

Ordinary launches select their output transport automatically. On macOS, a
successful Kitty SHM probe makes `shm` the first choice. Otherwise selection
prefers supported file-offset uploads, whole-file uploads, then inline APC.
Linux retains that file preference, with SHM available before the inline
fallback. Terminal compatibility rules still apply, including avoiding file
offsets on Ghostty. The historical `runtime.fullscreen_file` profile name is
retained for compatibility; it no longer forces file transport.

`KATZENSTEG_OUTPUT_PROFILE=auto|shm|file_whole|file_offset_ring|direct_apc`
overrides a launch profile. A profile can also set `runtime.output_profile` to
one of those values. An explicit transport bypasses the automatic choice;
`auto` clears an inherited choice. `KATZENSTEG_FILE_TRANSPORT=0` retains its
legacy direct-output behavior of forcing inline APC, including disabling SHM.

The desktop WM probes and chooses on behalf of its producers. Its JSONL path
still substitutes whole-file uploads for inline output. The headless WM and pi
extension do not own terminal input, so they keep whole-file output by default.
Set `KATZENSTEG_OUTPUT_PROFILE=shm` in the environment of the **host** to use SHM
there. Restart an existing background headless host for the setting to take
effect. These two hosts currently recognize only the SHM override; their other
settings continue to select whole-file output. They do not consume terminal
probe replies from Claude or pi. Hosted automatic negotiation remains follow-up
work.

For example, from the repository root:

```sh
./zig-out/bin/katzensteg mi2
KATZENSTEG_OUTPUT_PROFILE=shm ./zig-out/bin/katzensteg-wm mi2
KATZENSTEG_OUTPUT_PROFILE=shm ./zig-out/bin/katzensteg-wm --wrap -- claude
KATZENSTEG_OUTPUT_PROFILE=shm pi -e ./tools/pi-extension/extensions/katzensteg-panel.ts
```

SHM requires the producer and terminal to share a POSIX shared-memory namespace.
Each upload creates an immutable object and sends one APC containing its encoded
name. Kitty maps and unlinks the object. There is no per-frame `fsync`, but pixels
are still copied into SHM; this is not a GPU-only transport.
