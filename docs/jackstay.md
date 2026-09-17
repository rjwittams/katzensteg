# Jackstay CPU connectors

Katzensteg can publish an app's composed video to Jackstay, or present a Jackstay
source through its existing terminal and hosted-panel paths. The connectors are
optional, support macOS/Linux, and carry CPU RGBA/BGRA video. A publisher does
not need a terminal or a consumer. SDL2 and SDL3 publishers can also accept
cooperative keyboard and mouse input when the publisher explicitly enables it.
One source endpoint negotiates media and optional input. The KS presenter requests
input by default and remains observation-only when the source refuses it cleanly.

## Build

The dependency revision and C ABI are pinned in
[`profiles/jackstay-dependency.json`](../profiles/jackstay-dependency.json).
Prepare the ABI 0.8 headers and shared library, then enable the connectors:

```sh
python3 scripts/katzensteg/prepare_jackstay.py --prefix /tmp/ks-jackstay
zig build -Djackstay=true -Djackstay-prefix=/tmp/ks-jackstay
zig build test -Djackstay=true -Djackstay-prefix=/tmp/ks-jackstay
```

The helper clones the pinned revision and runs a locked Cargo release build.
`--source /path/to/checkout` instead uses a clean checkout at that exact revision.
The installed package includes the library in `zig-out/lib`; runtime ABI checking
rejects mismatches. A normal build requires neither Jackstay headers nor its
library. Selecting either connector in a disabled build reports
`JackstayUnavailable` before launching a child.

## Publish and present

Start a publisher using an existing app profile:

```sh
KATZENSTEG_TARGET=jackstay:/tmp/ks-sonic.sock ./zig-out/bin/katzensteg sonic
```

The path must be absolute (or start with `~/`) and must not already exist. Socket
creation and the file-log entry `Jackstay publication ready: ...` indicate that
setup connections can be accepted; the first frame follows when the app renders.
`--dry-run` prints the selected destination without opening it. Startup failures
are recorded in the app's Katzensteg log; they do not terminate the app.

In another terminal, present that source:

```sh
./zig-out/bin/katzensteg jackstay-source /tmp/ks-sonic.sock
```

For a WM panel, start a listening WM and launch the same source into it:

```sh
./zig-out/bin/katzensteg-wm --listen /tmp/ks-viewer-wm.sock
# From another shell:
KATZENSTEG_TARGET=jsonl:/tmp/ks-viewer-wm.sock \
  ./zig-out/bin/katzensteg jackstay-source /tmp/ks-sonic.sock
```

A pi or Claude workspace already supplying `KATZENSTEG_TARGET` can use that same
`katzensteg jackstay-source /tmp/ks-sonic.sock` command. Use the enabled checkout's
launcher explicitly if a different build is on PATH. The source uses the existing
positioned/placeholder producer protocol and observation requests. Hosts label it
as observation-only unless input admission succeeds; moving and resizing its
panel still work in either case.

This source accepts a Jackstay shared-bootstrap source socket, followed by generic
CPU media setup. The earlier raw media/two-path interface is replaced; source and
presenter must both speak bootstrap. Porthole's session
selection and authorization preface is not implemented here. The existing
`jackstay-viewer` profile remains available for its SDL viewer.

## Ownership and limits

`src/jackstay/` owns the C handles, setup endpoints and frame leases. The publisher
runs in the app process, after source composition and before terminal layout or
Kitty encoding. It publishes source dimensions and Unix-time nanoseconds. Native
app input stays enabled. Audio is not transported by these connectors.
The consumer acquires on a worker, copies into a bounded latest-frame mailbox,
then releases the lease before presentation. Bootstrap runs on a setup worker:
its absolute timeout is five seconds, with up to five more seconds for input
admission. It has no cancellation handle. CPU attachment and frame waits remain
cancellable independently of host control. Unexpected setup disconnect ends acquisition;
it never proves that a remote frame lease can be reclaimed.

Local endpoints use mode 0600 and check the peer's effective UID. Both peers open
their own connection; mappings and grants are never forwarded by a launcher.
Existing socket paths are never replaced automatically. After an unclean exit,
remove the abandoned endpoint yourself before restarting.

Current publisher limits are four resources, one retained frame, one producer
reserve, eight incarnation slots and a 256 MiB Jackstay allocation budget. A
normal consumer reserves one held frame. Publication drops under pressure and
resize can pause until older mappings/frames retire. Pending resize is advanced
by maintenance without repeatedly proposing a replacement. Source composition
and consumer copies accept at most 64 MiB per frame; Jackstay's budget also has
to fit resource multiplicity and metadata. These limits are currently code
settings, not profile options. There are at most eight concurrent setup workers.

Publisher shutdown stops acceptance and joins the bounded setup workers, then
asks Jackstay to drain. Input servers stop before their executor target is freed. If cleanup
cannot complete within the bounded wait, the app logs the failure and retains
the stopped owner until process exit. It does not forcibly reclaim leased
storage. Retrying such retained owners during a long-lived app unload is future
work. The consumer checks setup disconnect at acquisition boundaries, including
the one-second frame-wait timeout.

Registration, graph management, source activation, remote credentials, audio,
GPU transport are outside this implementation. Direct
endpoints work without a registry.

## Cooperative input to an app

Enable input on the app's publication:

```sh
KATZENSTEG_TARGET=jackstay:/tmp/ks-mi2.sock \
KATZENSTEG_PUBLISH_INPUT=1 \
  ./zig-out/bin/katzensteg mi2
```

The Jackstay SDL reference viewer uses that same endpoint:

```sh
/path/to/capture-viewer-sdl --source-socket /tmp/ks-mi2.sock
```

The endpoint must be unused. It uses mode 0600 and same-effective-UID checks.
Media access alone does not authorize input: `KATZENSTEG_PUBLISH_INPUT=1` grants
same-user peers permission to request the matching SDL2/SDL3 executor. Without
that setting, the publisher offers observation only. One remote controller is
admitted at a time; an additional viewer can still observe. This replaces the
old `KATZENSTEG_INPUT_SOCKET` setting.

Bootstrap preserves the original connection for media admission, so Jackstay
sees the consumer's actual kernel PID. Jackstay transfers the separate input
channel internally; KS does not implement framing or FD passing. Each publisher
setup gets a bounded worker, so a stalled peer cannot block frame publication,
maintenance or other viewers.

`src/jackstay/input.zig` owns target, server, client and execution-work handles.
Jackstay owns framing, ordering, epochs and the cleanup barrier. The executor
feeds the canonical KS input model, and SDL adapters project its queue and state.
Transport setup runs on a worker; execution progresses through the app's SDL
input calls, independently of video production.

An execution result means the operation reached the SDL event or state API used
by the app. It does not confirm the app's reaction. Queue admission alone never
completes an operation: if the app stops reading input, execution and cleanup
remain pending. Text and scroll require event delivery. Held keys and buttons can
also settle through state queries. Focus loss, controller close and disconnect
release that controller's holds after outstanding execution settles. A geometry
change releases pointer holds and preserves keyboard holds; stale pointer
geometry is rejected. Completed but unread controller events are discarded at
cleanup, so old presses cannot reappear after reset.

State-acknowledged events remain available to mixed event/state readers until the
768-event retention limit needs space. At that point, KS retires only copies
already delivered through state APIs; unobserved events remain queued. If those
unobserved events exhaust capacity, the executor ends the input connection and
continues pumping cleanup. ABI 0.8 has no executor-side overflow notification, so
KS logs the capacity failure and uses server teardown on its transport thread.
The peer sees a disconnect, which does not confirm cleanup. The listener remains
available, and Jackstay admits a new controller only after cleanup finishes.

Physical keys use DOM codes, logical keys use the current SDL keyboard layout,
and text commits are separate UTF-8 payloads. A key-down stores its resolved SDL
binding; repeats and releases reuse it. The source owns repeat timing. SDL2 text
is split at UTF-8 boundaries into its fixed-size event buffers; SDL3 retains the
whole commit. Line scroll keeps fractional deltas. Pixel/page scroll, unmappable
keys and embedded NUL text return clean unsupported results. Pointer coordinates
are logical window coordinates: SDL2 rounds down to integers, while SDL3 retains
fractional positions. Native pointer activity also updates the canonical position,
so a later remote release or cleanup uses the current location.

Local input stays enabled, and cleanup preserves native/local holds visible to
the model. The target advertises neither independent contributions nor interaction
cancellation: ordinary SDL release events can commit an application drag, and KS
does not promise native-device isolation. There is no exclusive takeover mode.

Destroying a transport does not confirm cleanup. On shutdown, unresolved work or
cleanup failure leaves the target draining or quarantined (`RecoveryRequired`).
KS logs the failure and retains the stopped owner until process exit. It does not
report clean release after a timeout or automatically replay an uncertain action.

## Input from a KS presenter

Connect the KS presenter to the source:

```sh
./zig-out/bin/katzensteg jackstay-source /tmp/ks-mi2.sock
./zig-out/bin/katzensteg jackstay-source /tmp/ks-mi2.sock --observe
./zig-out/bin/katzensteg jackstay-source /tmp/ks-mi2.sock --require-input
```

The default requests optional cooperative input. A clean refusal, including a
busy controller, preserves video and is logged with its reason. `--observe`
never requests input. `--require-input` fails setup if input cannot be admitted.
Protocol and transport failures fail setup in every mode. Close a controlling
viewer before opening another presenter that requires control.

These commands use normal destination selection: the current terminal, or a
WM/pi/Claude host supplying `KATZENSTEG_TARGET`. The old `--input-socket` argument
is no longer accepted. No second path or registry lookup is needed.

The presenter performs bootstrap and admission on a worker while the main loop
serves host control. It advertises input only after admission. Media attachment
follows bootstrap; frame acquisition and input execution then run independently.
Input disconnect disables forwarding while leaving video running. If media
attachment fails, or setup is abandoned, any admitted input owner is explicitly
closed and polled before destruction.

Closing the presenter requests cleanup and polls for confirmation for up to two
seconds; expiration logs an unconfirmed outcome. Destruction never proves remote
cleanup. A host shutdown during a stalled bootstrap may force process exit under
the existing host/launcher grace deadline because bootstrap cannot be cancelled.
Once bootstrap finishes, stalled media attachment remains cancellable. A forced
exit relies on peer-disconnect cleanup and does not report confirmed release.

Terminal and current hosted key inputs are logical keys, with separate UTF-8 text
events. KS does not infer physical DOM positions from terminal characters.
Structured repeated key-downs become explicit repeats with the same press
identity. Logical shortcuts preserve their modifiers; unsupported target mappings
are logged with their execution sequence, without substitution or replay.
Pointer positions pass through the existing presentation mapping, then scale from
source pixels into the target's logical input extent. Fractional line scroll is
preserved.

The presenter limits outstanding operations to 32 and waits for execution results
before sending more. Its local queue holds at most 8,192 events. Overflow drops
pending work and ends the controller session with cleanup; partial or uncertain
execution also closes input. Focus loss uses a reset and retains assignment.
Button holds remain tracked until release execution succeeds. A rejected release
requests recovery cleanup; subsequent button transitions wait for pending results.
A viewport change releases held pointer buttons and discards only pointer events
captured under an older mapping. Target geometry resets preserve confirmed key
holds and use the new geometry revision for subsequent pointer events.

Focus loss is carried by the existing terminal-byte input message (`ESC [ O`).
The direct terminal requests focus reports, and the desktop WM and pi panel send
this sequence when input focus leaves. It clears pending work and requests a
Jackstay reset; new input is discarded until the reset is confirmed. Hosts that
do not report focus loss, including the current Claude surface integration, still
need that notification to get this barrier. Detach, shutdown and transport loss
also trigger cleanup. Viewport changes alone do not count as focus loss.

## Verification

```sh
python3 scripts/katzensteg/test_jackstay.py
KATZENSTEG_JACKSTAY_PREFIX=/tmp/ks-jackstay \
JACKSTAY_REFERENCE_VIEWER=/path/to/capture-viewer-sdl \
  python3 scripts/katzensteg/test_jackstay_input.py
zig build                      # default, Vulkan enabled; Jackstay disabled
zig build test
```

The connector tests execute separate publisher and consumer processes. They cover
held frames across resize/setup close, bounded capacity pauses and recovery,
slow consumers, abrupt peer exit, endpoint ownership, host cancellation of
stalled setup, and source pixels through both hosted presentation modes. SDL2
and SDL3 publication run in both interception modes without a controlling
terminal. The feature-specific Python suite skips against a disabled launcher.
Plugin protocol tests cover observation-only behavior separately from live UI
validation. Real-game, pi/Claude UI and Porthole-session trials remain manual.

Verified on 2026-09-16: macOS arm64 and Linux x86_64 passed the full
Vulkan-enabled build and Zig tests with Jackstay enabled and disabled, the CPU
connector process tests, and injected-runtime signal-handler checks. Relocated
packages loaded their bundled Jackstay library on both platforms. A Linux
SDL/OpenGL offscreen probe published source-sized frames. macOS also passed the
existing hosted-rendering, headless-WM and launcher-target regressions; pi's 66
and Claude's 13 protocol/unit tests passed. These results do not cover a live
Porthole session or interactive pi/Claude rendering.

Robert also confirmed a live publication working with two KS viewers and with
the SDL reference viewer using its new `--cpu-socket` option.

Publisher and presenter input verified on 2026-09-16 on macOS arm64 and Linux x86_64: default
Vulkan-enabled builds passed with Jackstay enabled and disabled, as did 1,580
enabled Zig tests, 1,448 disabled Zig tests, all ten input process tests, and
the existing media, injected-runtime, launcher and hosted-rendering regressions.
Linux also passed preload export and Vulkan wiring checks. All 66 pi extension
tests passed.

Input tests use a C ABI controller and the independently built Jackstay SDL viewer
against real SDL2/SDL3 fixture processes with the dummy video driver. They cover
execution acknowledgements, source repeats, Unicode commits, event and state
APIs, held modifiers, focus/geometry cleanup, reconnect, abrupt viewer exit,
publisher exit, and input while video is paused. Model tests also cover allocation
failure during cleanup and preservation of local/native holds. Live game and
hardware-input trials remain manual.

The pinned ABI 0.8 dependency includes explicit initialization of the reference
viewer's synthetic SDL events, so CI builds that viewer without a local patch.
Its input transport also stops client heartbeats during graceful close, allowing
the final cleanup acknowledgement to be read after the server closes its socket.

Presenter acceptance also pairs KS with a C source fixture retained from Jackstay's
shared-bootstrap reference example and compiled against the pinned library,
including long Unicode input, logical-key repeat, held-state cleanup on graceful
close, and abrupt producer exit. KS-to-KS tests cover both SDL versions, positioned
and placeholder hosts, and input with video paused. A pseudo-terminal test covers
direct terminal input and focus loss without using the user's terminal.

Review follow-up verified on 2026-09-16 on macOS arm64 and Linux x86_64: full
Vulkan-enabled builds and tests passed with Jackstay enabled (1,599 Zig tests)
and disabled (1,459), along with all 11 input and 11 media process tests. New
coverage crosses the retained-event limit with state-only SDL2/SDL3 readers,
checks native-motion release coordinates, rejects presenter button releases,
and verifies cleanup and fresh admission after executor/presenter overflow.

Shared-bootstrap acceptance also covers observation without controller admission,
optional/required refusal, busy targets, stalled peers, protocol failure, input
disconnect with continuing video, and media-attach failure after input admission.
The C fixture adds only fault-injection modes to the upstream reference source.

Shared-bootstrap adoption verified on 2026-09-17 on macOS arm64 and Linux x86_64:
full Vulkan-enabled builds passed with Jackstay enabled and disabled (1,606 and
1,466 Zig tests). All 19 input cases, 13 media cases and the injected-runtime
signal-handler check passed. This includes the independent SDL viewer, the C
source, and KS at both ends; interactive game and workspace trials remain manual.
