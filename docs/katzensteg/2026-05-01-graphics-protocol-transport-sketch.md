# Graphics Protocol Transport Sketch

Date: 2026-05-01
Status: Design sketch

A unified design for the transport layer beneath the kitty graphics protocol. Replaces per-frame APC uploads for surface-rate workloads with registered swapchain surfaces over an out-of-band sidechannel, while keeping APC as the always-available fallback. Subsumes the Phase 6 "External Texture Future" roadmap item and supersedes the per-frame caching direction explored in [`2026-04-22-file-transport-cache-notes.md`](2026-04-22-file-transport-cache-notes.md).

## Motivation

The current protocol is PTY-only. Every transport mode — `t=d` direct in-APC, `t=f` regular file, `t=t` temp file, `t=s` shared memory object — communicates pixel data either inside the PTY stream or via a path that has to be sent over the PTY stream. That works for ssh, for tmux pass-through, for any byte-shuffling intermediary, and it is the right floor.

It is not the right ceiling. Katzensteg's hot-path workloads are all surface-rate:

- RetroArch / emulators presenting at 60 Hz
- Moonlight and Chiaki streaming decoded video at 60–120 Hz
- gamescope wrapping AAA Vulkan content
- Native SDL/GL/Vulkan applications under preload

For all of these, the producer already has the pixels on a GPU surface. The current protocol forces a CPU readback, an RGBA / PNG pack, a base64 encode, an APC framing, a PTY write, an APC parse on the terminal side, a base64 decode, a CPU upload back to a texture, and a draw. None of that is necessary on a local machine where producer and terminal share GPU memory.

Phase 6 of the roadmap calls this out: the end state is a terminal that can represent external surfaces (IOSurface, dmabuf, D3D shared resources) with explicit format, colorspace, damage, lifetime, and sync metadata. This note sketches the substrate that gets there, plus the colorspace and format rules needed to make the boundary tractable.

The constraint everything fits inside: APC over PTY remains the always-available transport. Anything new is opt-in, negotiated at startup, and falls through to APC on any failure or capability mismatch.

## Substrate

Four pieces:

1. **Out-of-band sidechannel.** A real Unix socket on POSIX, a real named pipe on Windows. Path / pipe name advertised via an environment variable the terminal sets on its child PTYs (the same pattern as `KITTY_LISTEN_ON`, `WAYLAND_DISPLAY`, `SSH_AUTH_SOCK`). If the env var is missing or the connect fails, the client uses APC and never thinks about it again. No PTY-tunnelled handshake, no APC-based capability discovery for the new transport.
2. **Handshake and capability negotiation.** Magic + version + endianness probe, then capability tuples. The terminal advertises supported `(transport_kind, pixel_format, colorspace, transfer, alpha_mode)` tuples. The client picks one. For swapchain modes the server then sends the client an fd / handle for a shared control ring, and accepts client-allocated surface fds back over the same channel.
3. **Sealed shared ring.** Backed by `memfd_create` with `F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_SEAL` on Linux; equivalent isolation primitives on macOS and Windows (see below). Carries small control messages — placement deltas, swapchain reallocations, error / recovery, optional damage hints, atomic frame-index counters. Not a pixel transport.
4. **Registered swapchain surfaces with platform fences.** Pixel data lives in client-allocated GPU surfaces (dmabuf / IOSurface / D3D shared resource). Client registers a swapchain group with the terminal once, then drives presentation in steady state by signalling a timeline fence and atomic-storing the current index in the ring header. Terminal's redraw loop samples whatever the most recently presented surface is.

Existing APC remains the fallback. A client that discovers no sidechannel, or whose advertised tuples do not match the terminal's, transmits frames as it always has.

## Per-platform handle types

- **Linux / Wayland / DRM**: dmabuf fd (DRM PRIME), passed via SCM_RIGHTS over the Unix socket. Fence is a `sync_file` fd for explicit sync, alongside the dmabuf. Modifiers and `DRM_FORMAT_*` codes negotiated in the handshake. Implicit dmabuf sync is being phased out across the stack — explicit per-frame sync_file is the path forward.
- **macOS**: IOSurface, exported as a mach port via `IOSurfaceCreateMachPort`, sent over the Unix socket as an SCM_RIGHTS-equivalent mach right. Fence is an `MTLSharedEvent`, also a mach port. Terminal wraps the IOSurface as `MTLTexture` for compositing.
- **Windows**: NT HANDLE from `IDXGIResource1::CreateSharedHandle` with `D3D11_RESOURCE_MISC_SHARED_NTHANDLE`. Cross-process duplication via the named-pipe authentication path: client connects to the terminal's named pipe, terminal calls `GetNamedPipeClientProcessId` and `OpenProcess(PROCESS_DUP_HANDLE)`, then `DuplicateHandle` to bring the client's surface handle into its own address space. Same pattern for the fence (`ID3D12Fence` / `ID3D11Fence` shared HANDLE).

The shared-ring fd uses the same passing mechanism as the surfaces on each platform. One channel, one mechanism, several types of capability flowing through it.

## Ring layout

The shared ring is a fixed-size sealed mapping. Both endpoints hold an fd / handle to it; both `mmap` / `MapViewOfFile` it. Layout, cache-line padded with line size 128 (covers Apple Silicon's 128-byte lines and contemporary x86/ARM 64-byte lines):

```
offset 0   [line 0]  u32 magic
                     u32 version
                     u32 ring_size
                     u32 flags
                     ... immutable header bytes ...
                     padding to next 128-byte boundary

offset 128 [line 1]  u64 current_index        // producer-written, consumer-read
                     u64 current_fence_value
                     padding to 128

offset 256 [line 2]  u64 consumed_index       // consumer-written, producer-read
                     padding to 128

offset 384 [line 3]  control message ring     // SPSC, length-prefixed records
                     ...
```

Each contended counter on its own cache line so that producer writes do not ping-pong the consumer's cache. Each side keeps a *cached* copy of the other side's counter on its own line (DPDK / LMAX Disruptor trick), reading the shared one only when the cached value says the ring is full or empty. Drops cross-core traffic by an order of magnitude under load. `alignas(128)` on each counter; `static_assert` the offsets so the compiler cannot quietly repack.

C11 `atomic_*` operations on the shared counters are cross-process safe in practice on every platform that matters, even though ISO C and C++ formally only define same-process semantics. `futex`, `io_uring`, and every real shared-memory IPC depend on this.

Records in the control ring are length-prefixed and never straddle the wrap boundary; pad to end with a skip record if the next record would cross. Frame data does not flow through this ring — only control deltas.

## Colorspace and format negotiation

The terminal advertises a list of `(pixel_format, colorspace, transfer, alpha_mode)` tuples in the handshake. The client picks one. If none of the terminal's tuples matches what the client has, **the client converts** before submitting. The terminal never tone-maps, never does gamut compression, never interprets ICC profiles. It samples.

This is a deliberate inversion of the typical compositor / colour-management model. A terminal as universal CMS is a non-starter — every implementation will get it subtly different and clients will end up writing terminal-specific workarounds, which is worse than the status quo. Clients that have content in non-trivial colorspaces already have a render pipeline; one more shader pass is trivial.

### Mandatory tuples

Tiered by mode:

- **Any terminal claiming graphics-protocol support** must advertise `(R8G8B8A8 byte-order, sRGB primaries, sRGB transfer, premultiplied alpha)`. Matches what the existing spec implicitly assumes.
- **Any terminal advertising swapchain / surface modes** must additionally advertise `(R16G16B16A16_FLOAT, sRGB primaries, linear transfer, premultiplied alpha)`. Linear-light extended-range premultiplied F16 — scRGB-style — is what GPU compositing math actually wants, and it is HDR-capable without forcing the terminal to tone-map. A client with PQ or HLG content maps into linear-light before submitting; the terminal's own display output stage handles "what does my display do."

### Optional tuples

Advertised but not required:

- BT.2020 PQ direct (HDR10 forward path for terminals on HDR displays)
- Display P3, 8-bit and 10-bit
- 10-bit unorm with various transfers
- NV12 / P010 / YUV422 (avoids client-side chroma upsample for video workloads)
- ICC-tagged buffers

A terminal that wants to take HDR-direct on capable displays opts in. A terminal that does not, never has to think about tone-mapping. A client that has HDR content and finds no HDR tuple offered, tone-maps into linear F16 and submits that.

### Format and colorspace are orthogonal

`(format, colorspace, transfer, alpha)` is a tuple, not a single enum. Clients pick a tuple; advertising every interesting combination does not create a combinatorial explosion because most combinations are nonsensical and only a handful are actually useful. Vulkan `VK_KHR_swapchain_colorspace` and DXGI `(DXGI_FORMAT, DXGI_COLOR_SPACE_TYPE)` already model this; clients are used to it.

## Spec-one-thing-and-stop

A handful of details are the same class of bug — implementations differ silently and clients write per-terminal workarounds. Pick one in each case and never look back.

- **Alpha**: premultiplied, always. The current protocol is silent on this and it shows; implementations differ on edge fringing for transparent PNGs. Premultiplied is what compositing math wants and what every modern GPU pipeline produces.
- **Channel order**: byte-order RGBA. The first byte is R, second G, third B, fourth A. On little-endian platforms this is `DRM_FORMAT_ABGR8888` when read as a `uint32`. Speak in bytes, not in `uint32` patterns. Half the existing kitty-protocol-implementing terminals get this wrong because the spec says "32-bit RGBA" and people implement it as a native-endian uint32.
- **Fence semantics**: timeline semaphore, monotonic u64 value. Producer signals the fence with value V and atomic-store-releases V into the ring header. Consumer load-acquires V, waits for the fence to reach ≥ V, then samples. Vulkan timeline semaphores, MTLSharedEvent, and D3D12 fences are all this shape; sync_file binary semaphores can be wrapped as a degenerate timeline.
- **Endianness of ring header fields**: little-endian for `u32` / `u64` fields. Every relevant platform is little-endian; clients on weird hardware do their own byteswap. No endianness-probe-then-reorient dance in the hot path.

## Per-frame regimes

Negotiated at handshake; the terminal's advertised capabilities decide which is reachable.

1. **Full APC** (existing protocol). Per frame: encode + base64 + PTY write. Always available; never goes away. Used over ssh, through tmux pass-through, when the sidechannel is not reachable, and for one-shot static images where the per-frame cost does not matter.
2. **Ring + kick**. Client writes pixel data to the shared ring (or an associated mapping for larger transfers), sends one short control-ring record — "image_id I, slot N, offset O, size S, fence value V." Better than APC for clients with many small one-shot uploads; not the steady-state shape for surface-rate workloads.
3. **Registered swapchain, fence-driven**. Client registers a swapchain group with the terminal once over the sidechannel. Per frame: render into the next surface, signal the fence, atomic-store-release the new index and fence value into the ring header. **Zero protocol messages per frame.** Terminal's redraw loop load-acquires the index, waits on the fence, samples. Per-frame cost is what a Wayland subsurface client pays.

Mode 3 is the one this design exists for. Mode 2 is a useful intermediate. Mode 1 is the floor and stays the floor.

## Lifecycle

Surfaces are registered with an `image_id`. Once registered, the existing protocol's placement system (`a=p`) references them by id — display, move, hide, delete all behave as the existing spec describes. The sidechannel only carries the *transport* delta, not the placement model.

Sidechannel disconnect (process exit, unexpected close) drops all surface registrations from that client. The terminal removes any visible placements that referenced them and, for any further operations the client attempts, falls back to APC.

The terminal may evict a registration under resource pressure — GPU memory, descriptor budget, surface count limits — by sending a control-ring message to the client. The client either re-registers or falls back to APC for that image_id.

The shared ring lives for the connection. No quota negotiation: ring size is fixed at creation. Backpressure is "tail would lap head; client either waits, drops the frame, or falls back to APC for this transfer."

## What this supersedes

- **Phase 6 "External Texture Future"** in [`2026-04-25-roadmap.md`](2026-04-25-roadmap.md) collapses onto §Substrate piece 4.
- **The file-transport tile-cache experiment** documented in [`2026-04-22-file-transport-cache-notes.md`](2026-04-22-file-transport-cache-notes.md) does not generalise once swapchain surfaces are available. Tile caching solves a problem that exists for static-grid 2D content (NES/SNES/GB emulation, some pixel-art ScummVM workloads) and not for the workloads Katzensteg actually targets — anything 3D destroys pixel-grid temporal coherence, and video codecs already exploit motion-compensated coherence in motion-vector space far better than a fixed-grid tile cache could. Kept in the docs as a record of the experiment.
- **Per-frame APC for surface-rate workloads** stops being the assumed shape. APC remains the floor and the fallback, not the steady-state path.

## Out of scope

- Authentication of the sidechannel beyond "is this a process the same user could otherwise observe." `SO_PEERCRED` / `getpeereid` / `GetNamedPipeClientProcessId` for "is the connecting process from the same user as the terminal" is fine for v1; cryptographic capability tokens are a separate question.
- A native subsurface / compositor-handover mode (the terminal hands a region of its window to a subordinate compositor client). Loses the protocol's identity for that image and conflicts with text overlay and z-ordering. Possible later, deliberately not in this design.
- Re-spec of the placement model. Existing `a=p, x, y, z, c, r` etc. work on registered surfaces unchanged.
- Networked transports. Anything not local-machine drops to APC, by definition.

## Open questions

- Whether the swapchain's surface count is client-chosen, terminal-chosen, or negotiated. Client-chosen subject to a terminal-advertised maximum is probably right — the client knows whether it wants double or triple buffering — but this needs validation against the actual rendering loops in Katzensteg's preload path.
- Whether the per-frame counter should be a single `(index, fence_value)` pair or split into "submitted" and "ready" pairs, for the case where the producer wants to publish a frame index ahead of the GPU finishing it. Splitting allows the terminal to predict scheduling without busy-waiting; complicates the consumer.
- Whether placement deltas should ride the shared control ring or stay on the PTY APC stream. PTY keeps the protocol single-source-of-truth for placement state but adds ordering questions when a fast-path frame and a slow-path placement update interleave. Probably PTY for v1, ring-only as a v2 optimisation if the ordering shows up in measurement.
- Damage / partial-update hints when the producer knows only a subregion changed. Trivial to add as a control-ring message; unclear whether terminals can use them efficiently without breaking the swapchain abstraction.

## See also

- [`2026-04-25-roadmap.md`](2026-04-25-roadmap.md) — Phase 6 External Texture Future.
- [`2026-04-22-file-transport-cache-notes.md`](2026-04-22-file-transport-cache-notes.md) — superseded tile-cache experiment.
- [`2026-04-28-stdio-render-batch-protocol.md`](2026-04-28-stdio-render-batch-protocol.md) — adjacent: the producer-to-host JSONL embedding protocol, same control/data split philosophy from the other side of the runtime.
