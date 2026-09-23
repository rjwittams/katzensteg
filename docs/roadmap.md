# Roadmap

Updated 2026-09-23. This page records the work that follows the current
Katzensteg baseline. Linked issues hold acceptance criteria and current status;
the items under "Later directions" are questions to revisit when a concrete
consumer needs them.

## Current baseline

- Launcher profiles start tested SDL2, SDL3, OpenGL, Vulkan and narrow Metal
  workloads. Support is defined by the probe and app matrix, not by arbitrary
  applications using those APIs.
- Direct terminal, desktop WM, pi and Claude hosts can present captured frames.
  External applications can join a listening host through
  `KATZENSTEG_TARGET=jsonl:<socket>`.
- SDL input passes through the canonical input model. Direct sessions and the
  desktop WM have Ctrl-] command mode. [Issue #52](https://github.com/rjwittams/katzensteg/issues/52)
  retains its nesting and extra-command stages.
- Optional Jackstay CPU connectors publish frames and receive cooperative input
  on a shared source endpoint. They do not carry audio. The terminal and hosted
  presenters are adapters; a publisher can run without either.
- File and shared-memory Kitty uploads are available. The desktop WM chooses
  SHM automatically on compatible local macOS hosts; the pi extension still
  needs an explicit output-profile override.

## Concrete next slices

| Work | Tracking |
| --- | --- |
| Recheck idle CPU on the SDL2 input probe after the capture optimizations in PR #54. | [#50](https://github.com/rjwittams/katzensteg/issues/50) |
| Move the pi extension from its local surface-API worktree to a released pi dependency. | [#55](https://github.com/rjwittams/katzensteg/issues/55) |
| Select SHM or file uploads from pi host capabilities. | [#56](https://github.com/rjwittams/katzensteg/issues/56) |
| Validate the existing Metal hook with the Porthole native viewer and record its support boundary. | [#57](https://github.com/rjwittams/katzensteg/issues/57) |
| Define a relocatable install tree before adding Katzensteg to fleet builds. | [#58](https://github.com/rjwittams/katzensteg/issues/58) |

Command-mode nesting and further commands remain in [#52](https://github.com/rjwittams/katzensteg/issues/52).
Host placement policy for inherited launches remains a design direction in
[#31](https://github.com/rjwittams/katzensteg/issues/31). Smaller WM and
diagnostic follow-ups remain in the issue tracker.

## Later directions

- **Audio:** choose whether a direct Katzensteg session needs local sound
  capture/control before Jackstay has audio transport. Define timing, ownership
  and output behavior against a real workload before adding a connector.
- **Remote streams and graph management:** Jackstay and Porthole own transport,
  publication discovery, authorization and graph control. Katzensteg should
  remain a publisher/presenter with terminal details contained in its output
  adapters. The [Jackstay discussion](https://github.com/flotilla-org/jackstay/blob/main/docs/design/publication-registry-and-graphs.md)
  is intentionally not a protocol specification.
- **Pi presentation policy:** profile-dependent source resizing, offscreen
  producer lifetime, image recovery after terminal clears, and inline alignment
  are recorded in [pi-extension-future.md](pi-extension-future.md). A released
  surface API and transport selection come first.
- **Native/GPU capture:** broaden Metal formats and real-app coverage only after
  the current BGRA path is validated. Reducing readback and conversion costs
  across capture, Jackstay and terminal output needs measurements from those
  full paths.
- **Installed and remote use:** the package in #58 is a prerequisite for the
  separate fleet and crew-image work. Fleet signing and rollout, plus adding
  Katzensteg and its Jackstay runtime to container images, remain outside this
  repo's current implementation.

The support boundary and ownership rules live in [architecture.md](architecture.md),
the optional connector contract in [jackstay.md](jackstay.md), and local app
dependencies in [external-projects.md](external-projects.md).

## Issue labels

Use `bug` for observed failures, `enhancement` for new behavior or integration,
`documentation` for doc-only changes, and `from-review` for deferred PR review
findings. `ci-flake` marks a check that fails independently of the proposed
change. These labels can be combined when both meanings apply.
