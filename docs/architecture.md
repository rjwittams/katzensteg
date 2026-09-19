# Katzensteg Architecture

Katzensteg is currently an injected runtime plus a launcher.

The launcher starts a target application from a JSON profile. The runtime is injected into that process with `LD_PRELOAD` on Linux or `DYLD_INSERT_LIBRARIES` on macOS. Once inside the process, Katzensteg intercepts the SDL2 presentation/input surface that the application exposes, mirrors the rendered output into terminal graphics, and routes terminal input back into SDL where supported.

## Current Support Boundary

The current support boundary is defined by tested workloads, not by a blanket API guarantee.

The best-tested paths are:

- SDL2 software and renderer output used by the current probes and patched app profiles.
- SDL keyboard and mouse event paths used by those profiles.
- Terminal graphics output using kitty-compatible protocol support.

Several larger applications in the smoke matrix needed app-side patches or build modes so they expose an SDL2 renderer/input path. OpenGL and Vulkan capture work exists in the tree, and some profiles exercise those paths, but none of this should be read as arbitrary SDL2, OpenGL, or Vulkan application support.

## Main Pieces

### Launcher

`zig-out/bin/katzensteg` is the normal entry point. It:

- loads and resolves JSON profiles from `profiles/`
- expands local path placeholders
- writes runtime configuration
- prepares the target environment
- redirects target output away from the terminal when needed
- starts the target process
- performs best-effort terminal cleanup after exit

The launcher should be the place to encode repeatable run policy. Avoid adding new ad hoc run scripts when a launcher profile would do.

### Runtime

The runtime lives under `src/katzensteg/`. It owns:

- SDL2 capture and replay state for tested paths
- frame composition
- terminal graphics output
- keyboard and mouse input mapping
- logging
- platform interposer glue

The runtime must not write diagnostics to stdout or stderr during a captured run, because those streams may be part of the terminal presentation.

#### Producer Threading

In queued batch mode, app threads may copy payloads and enqueue commands, but the queued replay worker owns `FrameBuilder`, `RenderBatchSink`, batch control application, placement/reproject/delete state, and presentation status writes. WM control messages (`attach`, `viewport`, `detach`, `shutdown`, and forwarded `input`) are consumed and applied from the worker path. App-side SDL input APIs read protected input state; they must not drain or apply batch control messages.

OpenGL/Vulkan framebuffer capture may still run on the app render thread to perform GPU readback, but it should publish copied framebuffer payloads to the worker rather than mutate presentation state directly. Any new runtime state that is touched from both app threads and the worker needs an explicit owner, mutex, or atomic before use.

#### Replay Payloads And Overload

`replay_payloads.zig` owns copied command data from allocation until retirement. Its 64 MiB live-data budget includes producer copies, queued uploads, and data being processed by the worker. Producers wait for capacity before allocating; all planes of a YUV upload reserve capacity together. A command larger than the budget is admitted only when no other payload is live. Reusable idle buffers have a separate 64 MiB cache limit. These limits do not include application memory or the frame builder's texture and presentation storage.

The replay worker protects a frame from the moment it starts a texture upload or drawing command through completion of its present. Later obsolete draws and presents can be retired while that frame is processing. After retirement, a full texture replacement can supersede earlier uploads across a consecutive sequence of uploads. Surviving draws, presents, resource lifecycle commands, and state commands stop that optimization. Partial updates remain necessary unless a later full replacement overwrites them. Shutdown closes payload admission and wakes waiting producers.

#### Renderer Pixels And Input Coordinates

SDL2 renderer capture samples `SDL_GetRendererOutputSize` on the app thread and sends size changes through the command queue. The frame builder composes in renderer pixels and tracks logical window dimensions separately. Moving a window between displays can change its pixel dimensions without changing its logical size. Terminal mouse mapping uses the logical dimensions; input expressed in observation-image pixels is converted by the input model before the SDL adapter projects it into events.

SDL2 polling and waiting consume the same canonical input model. `SDL_WaitEvent` and `SDL_WaitEventTimeout` use native waits of at most 8 ms between checks for terminal or host input. Native window and application events remain available, including streaming clients' frame-ready notifications. Null event pointers check availability without consuming an event.

### Window Manager Sessions

The WM host keeps window state separate from the producer's channel and optional owned child process. `wm/client.zig` owns channel descriptors: separate control/presentation pipes for WM-launched producers, or one duplex socket. Closing socket control half-closes the write direction so final presentation batches can still be drained. Borrowed channel files must not be closed directly.

Only WM-owned children are waited for and reaped. Their exit determines session lifetime; a session without an owned child ends at presentation EOF. Presentation allocation and initial attach share one path, as do focus, layout and input routing. The WM exposes external registration through `--listen`; the launcher selects it with `KATZENSTEG_TARGET=jsonl:<socket-path>`. Destination selection is separate from the JSONL transport. The shell launcher supervises its application and relays runtime pipes over the socket, leaving its own terminal alone. Explicit `--embed-jsonl` takes precedence over inherited target selection. Socket control writes retain partial output in a bounded buffer and flush from the host event loop. Session slots are reused only after presentation EOF, readiness callbacks, queued batches and graphics cleanup have completed; each new connection receives a fresh host session ID.

### Profiles

Profiles are JSON files under `profiles/`. They define target commands, inheritance, platform-specific values, runtime policy, and local setup details.

Hidden profiles are reusable fragments. Visible profiles are direct launch targets.

### External App Forks

Some real workloads need patched application branches to expose paths that are useful to Katzensteg. Those forks are tracked in `docs/external-projects.md`; their code does not live in this repository.

### Host-drawn placeholder grids

An attached producer can target a Unicode placeholder grid using a host-owned
image ID, cell dimensions and an optional physical-pixel upload bound. The runtime
retains the last completed SDL scene in `PresentationSnapshot`: source textures,
draw commands and cursor data, with their original coordinate system. Display
frames are composed directly at the bounded resolution, avoiding an intermediate
framebuffer sized to a high-DPI real window. Observation composes the retained
scene at source resolution on demand. Texture updates after a present cannot
alter that completed snapshot.

`RenderBatchSink` owns the current presentation pixels and transmits them under
the stable ID followed by one virtual placement. Pixel-size changes recompose
from the retained scene; cell-only changes reissue the virtual placement. Refresh
and resize do not advance observation frame IDs. External framebuffer conversion
remains in the present path; its captured pixels are retained and resized before
upload. Earlier GPU readback sizing is unchanged by this interface addition.
Detach or presentation replacement deletes the owned image.

The WM exercises this mode through its normal desktop and session lifecycle.
With `--presentation placeholder`, each owned or externally registered session
receives a stable image ID and the dimensions of the WM's fitted content grid.
The WM renders those cells as text, handles overlap and vacated-cell cleanup,
and translates mouse input into grid-local coordinates. Producer graphics do
not carry terminal position, clipping or z-order. Selection is global initially;
image ownership and grid state live on each session.

The WM also has a headless frontend for applications that draw their own
placeholder cells. The desktop and headless frontends share `wm/producer.zig`
for process/channel ownership, `wm/client.zig` for buffered control output, and
`wm/producer_control.zig` for attach, viewport and input serialization. Desktop
layout and terminal input remain in `wm_host.zig`. The headless frontend never
constructs `DirectTty` and deletes only its own images. The ordinary background
host leaves input modes to the application. Optional `--wrap` mode uses
`wm/wrap.zig` to run that application on an inner PTY and temporarily makes the
outer terminal raw. It relays input unchanged and restores the saved modes on
exit.

The headless frontend exposes authenticated loopback HTTP. Each client owns a
registration socket and a set of sessions; image IDs are allocated by the
terminal's shared host. Each client can bind to a parent PID; process exit or
lease expiry closes that client's sessions. The shared host exits after its
no-client timeout. Its output uses a concrete terminal device opened before
detach, and a session's graphics failure does not propagate through cleanup to
stop the host. Deferred HTTP observation requests have a two-second deadline
and leave producer draining and other clients running. The frontend accepts the
exact grid drawn by its client and does no aspect fitting. Source metadata and
terminal cell pixel dimensions let the client do that fitting. Graphics writes
use file uploads and small APC batches; concurrent terminal writers remain a
protocol limitation, not an atomicity guarantee.

Wrap mode sends all host graphics through the same bounded output buffer as
the child's bytes. `wm/output_boundary.zig` tracks insertion boundaries without
buffering whole escape strings or modelling the screen. UTF-8, control strings
and chunked kitty uploads can span reads; graphics wait until they complete.
The host keeps servicing HTTP and draining producers under terminal backpressure.
An explicit discovery descriptor in `KATZENSTEG_WM_HOST` lets plugins attach to
the wrapping host instead of starting a second host for the inner PTY.

Structured keyboard requests join terminal bytes and pointer requests at the
canonical input model. Every source hands it a native key in the Jackstay
vocabulary (`src/katzensteg/native_key.zig`): a DOM code or logical key name,
an action, modifiers and, once inside the model, a press identity. The model
binds the key once with static US-layout tables, keeps held presses so a repeat
or release reuses its down binding, and projects the result into the SDL-shaped
queue. SDL adapters refine bindings against the live keymap; presenters forward
the native key without translating SDL numbers back into names. The HTTP
adapter does not inject SDL events directly.

The input model also owns the local app/command routing state. A direct tty
owner installs its attention-key binding; hosted and terminal-free models leave
it disabled. A consumed press stays consumed through repeat and release, even
across a routing change. Entering command mode retires queued local app work,
releases held keys/buttons and queues focus loss. The SDL adapters project
focus, quit, event ranges and state reads from that model. Bracketed paste is
framed at the source so its contents cannot execute commands.

Command quit has two outputs: a model event for SDL and a one-byte notification
to the launcher over a private inherited socket. The launcher owns the grace
period and TERM/KILL escalation. The runtime does not kill its host process or
write a command response to the terminal. Command-mode hints remain model
state for the later presentation overlay.

Terminal keyboard reports are decoded by `src/katzensteg/terminal_keys.zig`,
one decoder for the legacy xterm forms and the kitty keyboard protocol. The
direct tty pushes the protocol flags (disambiguated escapes, event types,
alternate keys, all keys as escape codes, associated text) after entering the
alternate screen and queries them; the reply tells the model whether reports
carry real press, repeat and release actions, base-layout positions and text.
Without the protocol every key is a whole tap, and a lone Escape or an Alt
prefix is resolved by the tty read timeout. The WM host decodes its own hotkeys
from either encoding, forwards reports unchanged, and replays the terminal's
reply to each producer once so their parsers read the same semantics.

Mouse reports use the same path. The direct tty asks for SGR-pixel reports
(mode 1016) when it knows the terminal's pixel size and confirms the switch
with DECRQM; the reply sets the model's units, and the launcher reset and tty
teardown restore cell reports. A pixel report becomes a fractional cell through
the terminal cell size the input target carries (`cell_px`, from the tty or the
host's terminal geometry), so the same presentation layout places cell and
pixel reports and the sub-cell position survives into the precise mouse fields.
Terminals disagree on the first pixel's coordinate (xterm counts from 1 like
cells, kitty and Ghostty from 0); `termscene`'s capabilities module owns that
quirk and hosts pass it to the target as `pixel_origin`.
The WM host converts pixel reports to cells for its own hit testing and drags,
forwards them unchanged (grid-local pixels for placeholder sessions), and
replays the DECRQM reply to each producer once.

### Shared-memory terminal uploads

`termscene/kitty/shared_memory.zig` owns POSIX upload objects for both the direct
backend and the hosted batch sink. Objects have private permissions and unique
names. The terminal unlinks each name after mapping it; the producer reaps its
tracking entry only after the name disappears. Names are never reused, and a
pipe write does not count as consumption. No timeout releases submitted pixels.

Outstanding uploads have a 64-object, 64 MiB admission budget. One oversized
image or complete scene may exceed it only when there are no outstanding
uploads. Hosted scenes reserve their whole upload set before changing cached
images or placements. Pressure rejects new frames without overwriting pending
ones. Composition failures release unsent objects; teardown releases leftovers.
An uncatchable producer termination can leave named objects behind.

Hosts selecting `shm` must send
`{"type":"discard_batch","window_id":"main","seq":N}` when they discard a
complete batch before any of its graphics reach the terminal or an output queue.
The producer releases only that batch's objects. Headless wrap mode uses this
when host graphics cannot be inserted at a safe boundary. Partially submitted
batches must never be reported as discarded. The desktop WM and pi consume
uploads in order, including those whose placements are no longer visible.
Refreshes create new upload objects; an old SHM APC cannot be replayed after its
name has been consumed.
