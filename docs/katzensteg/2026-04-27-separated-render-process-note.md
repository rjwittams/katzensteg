# Separated Render Process Note

Katzensteg should keep an explicit path for a separated render process. This is different from the current preload/in-process model: the CLI harness owns the agent session, terminal scrollback, and process supervision, while a child render process owns graphics, image encoding, and terminal image placement.

The near-term use case is agent CLIs embedding a robust visualization channel. An agent can write a small LÖVE, pygame, Manim, or custom GL/EGL program; the harness launches it as a render process; the render process receives geometry and input; and it emits terminal-ready output that the harness can safely pass through.

## Transport Shape

The control channel should be transport-neutral:

- `stdio`: simplest embedding path for agent CLIs and interpreter subprocesses.
- socket: better for attach/reconnect, process supervision, multi-client inspection, and cases where stdout/stderr need to remain application-owned.

The protocol should not depend on either transport. A harness should be able to select stdio or socket based on where it is running and how much lifecycle control it needs.

## Responsibility Split

The render process should be able to produce complete terminal image APCs itself. This keeps each CLI harness from needing to understand Kitty, iTerm2, Sixel, placeholders, image ids, placement ids, or terminal-specific escaping. The harness only needs to know when bytes are safe to write to the terminal.

The harness sends:

- terminal geometry and capability hints
- input events
- lifecycle/control messages
- optional output mode preferences

The render process sends:

- terminal-ready byte sequences, when running in encoded-terminal mode
- optional fallback text/placeholders
- optional frame descriptors, when a harness or remote client wants to encode/present images itself
- status and error messages

This suggests two output modes:

- `encoded_terminal`: render process emits complete APC/escape output for direct terminal passthrough.
- `frame_descriptor`: render process emits image paths, shared-memory handles, dimensions, format, and placement metadata for another presenter.

## Backend Notes

LÖVE is a good pressure test for an SDL3 adapter and for agent-authored interactive Lua programs. Pygame likely exercises SDL2 plus software-surface and OpenGL display paths. Manim is probably a file/frame producer first: it can use OpenGL directly, read back frames, and produce images or videos, so its initial integration may be closer to `frame_descriptor` than live input.

This path should not replace preload capture. It gives Katzensteg a cleaner authoring story for agent-generated visualizations while preserving the in-process path for existing apps and games.

See `2026-04-28-stdio-render-batch-protocol.md` for the first-cut stdio/JSONL render batch shape that keeps the existing preload launcher path and lets an embedding client choose geometry while Katzensteg still constructs terminal graphics protocol bytes.
