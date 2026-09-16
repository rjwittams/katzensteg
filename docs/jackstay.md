# Jackstay CPU connectors

Katzensteg can publish an app's composed video to Jackstay, or present a Jackstay
source through its existing terminal and hosted-panel paths. The connectors are
optional, support macOS/Linux, and carry CPU RGBA/BGRA video. A publisher does
not need a terminal or a consumer. SDL2 and SDL3 publishers can also accept
cooperative keyboard and mouse input through an explicitly enabled endpoint.
The KS source presenter remains observation-only.

## Build

The dependency revision and C ABI are pinned in
[`profiles/jackstay-dependency.json`](../profiles/jackstay-dependency.json).
Prepare the ABI 0.7 headers and shared library, then enable the connectors:

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
as observation-only and suppress or reject game input; moving and resizing its
panel still work.

This source accepts a generic Jackstay CPU setup socket. Porthole's session
selection and authorization preface is not implemented here. The existing
`jackstay-viewer` profile remains available for its SDL viewer.

## Ownership and limits

`src/jackstay/` owns the C handles, setup endpoints and frame leases. The publisher
runs in the app process, after source composition and before terminal layout or
Kitty encoding. It publishes source dimensions and Unix-time nanoseconds. Native
app input stays enabled. Audio is not transported by these connectors.
The consumer acquires on a worker, copies into a bounded latest-frame mailbox,
then releases the lease before presentation. Setup and frame waits are cancellable
independently of host control. Unexpected setup disconnect ends acquisition;
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

Shutdown cancels and joins setup workers, then asks Jackstay to drain. If cleanup
cannot complete within the bounded wait, the app logs the failure and retains
the stopped owner until process exit. It does not forcibly reclaim leased
storage. Retrying such retained owners during a long-lived app unload is future
work. The consumer checks setup disconnect at acquisition boundaries, including
the one-second frame-wait timeout.

Registration, graph management, source activation, remote credentials, audio,
source-presenter input forwarding and GPU transport are outside this implementation. Direct
endpoints work without a registry.

## Cooperative input to an app

Enable an input endpoint alongside the app's media publication:

```sh
KATZENSTEG_TARGET=jackstay:/tmp/ks-mi2-media.sock \
KATZENSTEG_INPUT_SOCKET=/tmp/ks-mi2-input.sock \
  ./zig-out/bin/katzensteg mi2
```

The Jackstay SDL reference viewer can connect to both:

```sh
/path/to/capture-viewer-sdl \
  --cpu-socket /tmp/ks-mi2-media.sock --input-socket /tmp/ks-mi2-input.sock
```

Both endpoint paths must be unused. Input uses the same mode-0600, same-effective-UID
checks as media. The host explicitly associates the two paths; opening the media
socket alone grants no input connection. One remote controller is admitted at a
time. This endpoint is available on the SDL2/SDL3 publisher path; the KS
`jackstay-source` presenter does not yet forward terminal, WM, pi or Claude input.

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

Physical keys use DOM codes, logical keys use the current SDL keyboard layout,
and text commits are separate UTF-8 payloads. A key-down stores its resolved SDL
binding; repeats and releases reuse it. The source owns repeat timing. SDL2 text
is split at UTF-8 boundaries into its fixed-size event buffers; SDL3 retains the
whole commit. Line scroll keeps fractional deltas. Pixel/page scroll, unmappable
keys and embedded NUL text return clean unsupported results. Pointer coordinates
are logical window coordinates: SDL2 rounds down to integers, while SDL3 retains
fractional positions.

Local input stays enabled, and cleanup preserves native/local holds visible to
the model. The target advertises neither independent contributions nor interaction
cancellation: ordinary SDL release events can commit an application drag, and KS
does not promise native-device isolation. There is no exclusive takeover mode.

Destroying a transport does not confirm cleanup. On shutdown, unresolved work or
cleanup failure leaves the target draining or quarantined (`RecoveryRequired`).
KS logs the failure and retains the stopped owner until process exit. It does not
report clean release after a timeout or automatically replay an uncertain action.

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

Publisher input verified on 2026-09-16 on macOS arm64 and Linux x86_64: default
Vulkan-enabled builds passed with Jackstay enabled and disabled, as did 1,509
enabled Zig tests, 1,444 disabled Zig tests, all seven input process tests, and
the existing media, injected-runtime, launcher and hosted-rendering regressions.
Linux also passed preload export and Vulkan wiring checks.

Input tests use a C ABI controller and the independently built Jackstay SDL viewer
against real SDL2/SDL3 fixture processes with the dummy video driver. They cover
execution acknowledgements, source repeats, Unicode commits, event and state
APIs, held modifiers, focus/geometry cleanup, reconnect, abrupt viewer exit,
publisher exit, and input while video is paused. Model tests also cover allocation
failure during cleanup and preservation of local/native holds. Live game and
hardware-input trials remain manual.

The ABI 0.7 reference viewer's self-test uses C union initializers that leave some
synthetic keyboard fields uninitialized under GCC. CI applies
[`jackstay-viewer-self-test.patch`](../scripts/katzensteg/fixtures/jackstay-viewer-self-test.patch)
to clear those events explicitly before building the pinned viewer. The patch
changes only its self-test, not the viewer's input adapter or Jackstay protocol;
remove it when the dependency includes the upstream fix.
