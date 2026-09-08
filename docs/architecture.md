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

### Window Manager Sessions

The WM host keeps window state separate from the producer's channel and optional owned child process. `wm/client.zig` owns channel descriptors: separate control/presentation pipes for WM-launched producers, or one duplex socket. Closing socket control half-closes the write direction so final presentation batches can still be drained. Borrowed channel files must not be closed directly.

Only WM-owned children are waited for and reaped. Their exit determines session lifetime; a session without an owned child ends at presentation EOF. Presentation allocation and initial attach share one path, as do focus, layout and input routing. The WM exposes external registration through `--listen`; the launcher selects it with `KATZENSTEG_TARGET=jsonl:<socket-path>`. Destination selection is separate from the JSONL transport. The shell launcher supervises its application and relays runtime pipes over the socket, leaving its own terminal alone. Explicit `--embed-jsonl` takes precedence over inherited target selection. Socket control writes retain partial output in a bounded buffer and flush from the host event loop. Session slots are reused only after presentation EOF, readiness callbacks, queued batches and graphics cleanup have completed; each new connection receives a fresh host session ID.

### Profiles

Profiles are JSON files under `profiles/`. They define target commands, inheritance, platform-specific values, runtime policy, and local setup details.

Hidden profiles are reusable fragments. Visible profiles are direct launch targets.

### External App Forks

Some real workloads need patched application branches to expose paths that are useful to Katzensteg. Those forks are tracked in `docs/external-projects.md`; their code does not live in this repository.
