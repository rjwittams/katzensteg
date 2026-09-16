# Jackstay CPU connectors

Katzensteg can publish an app's composed video to Jackstay, or present a Jackstay
source through its existing terminal and hosted-panel paths. The connectors are
optional, support macOS/Linux, and carry CPU RGBA/BGRA video. A publisher does
not need a terminal or a consumer. Sources are observation-only: there is no
remote input executor yet.

## Build

The dependency revision and C ABI are pinned in
[`profiles/jackstay-dependency.json`](../profiles/jackstay-dependency.json).
Prepare the header and shared library, then enable the connectors:

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
app input and audio stay with the app; neither is transported in this connector.
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
interaction channels and GPU transport are outside this implementation. Direct
endpoints work without a registry.

## Verification

```sh
python3 scripts/katzensteg/test_jackstay.py
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
