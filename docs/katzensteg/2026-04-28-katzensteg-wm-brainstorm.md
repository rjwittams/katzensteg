# Katzensteg WM Brainstorm

Date: 2026-04-28
Status: fun/product/protocol brainstorm; not an implementation plan yet

## Idea

Build a tiny standalone Katzensteg window manager / compositor, tentatively:

```bash
katzensteg wm
```

This would be outside Pi. It would be a protocol pressure-test host for all the things that are awkward to validate inside Pi first:

- multiple producers
- multiple windows per producer
- multiple placements per window
- attach/detach/reattach lifecycle
- moving/resizing placements
- input focus and input routing
- process lifecycle policy
- socket/shared producers
- cleanup and crash recovery
- producer-created windows

The Pi extension can remain product-shaped and conservative. `katzensteg wm` can be the experimental host where the protocol is stressed until the abstractions become obvious.

## Why this might be useful

Current Pi integration proves that a Pi-owned rectangle can host Katzensteg/Kitty graphics. The next hard problems are host-level, not merely rendering-level:

- what if one producer has multiple logical windows?
- what if a window is shown in two places?
- what if a placement is closed but the producer should keep running?
- what if a process should suspend on blur and resume on focus?
- what if input should route to a visual only while focused?
- what if the app opens a new window dynamically?
- what if a producer crashes before polite cleanup?

A standalone WM can exercise those cases without coupling early design mistakes to Pi.

## Possible first shape

Very rough first version:

- full-terminal host
- simple menu/list of launchable profiles
- launch profile as owned producer
- attach producer window to a placement rectangle
- close placement vs kill producer
- focus placement
- show protocol/debug log
- basic resize/move, even if keyboard-only at first

Later:

- mouse move/resize
- floating windows
- tiling layouts
- status bar placements
- socket/shared producer registry
- multi-window producer support
- attach one producer window to multiple placements
- input routing and coordinate translation
- lifecycle policy experiments

## Conceptual model

Keep the same model discussed for Pi:

- **ProducerSession**: process/service connection
- **ProducerWindow**: logical visual output from a producer
- **Placement**: host-owned location where a window is shown
- **Attachment**: protocol relationship between a window and placement
- **InputFocus**: which placement receives keyboard/mouse events
- **LifecyclePolicy**: what happens on close, blur, detach, idle, crash

The WM is the reference host that makes these objects visible and debuggable.

## Input experiments

The WM would be a good place to nail down input semantics:

- first click selects/focuses placement
- focused placement can receive raw mouse/keyboard
- Escape exits visual focus back to WM
- terminal mouse events map to placement-local cell/pixel/normalized coordinates
- visual focus state is obvious in chrome
- debug pane shows translated input events

Possible event families:

- raw pointer/key events for SDL/game/web-like producers
- semantic host interactions: select region, draw path, inspect point
- producer-authored semantic controls: buttons, nodes, chart points

This could become the proving ground for multimodal terminal-agent interaction later.

## Process lifecycle experiments

The WM can test lifecycle policies before they become profile schema:

```json
{
  "lifecycle": {
    "ownership": "owned | shared | external",
    "on_close": "detach | terminate_tree | keep_alive",
    "on_blur": "continue | suspend_tree | detach | throttle",
    "on_focus": "resume_tree | reattach",
    "idle_timeout_ms": 30000
  }
}
```

Interesting cases:

- games/audio producers suspended with `SIGSTOP` on blur and resumed with `SIGCONT`
- monitors continue running while unfocused
- inline-style windows detach when offscreen/hidden
- shared socket producers stay alive after all placements close
- owned producers die with their last placement unless pinned

## Terminal programs via cleat

A particularly interesting extension: host terminal programs inside the WM.

If cleat can use Ghostty terminal state internally and expose what the screen should be, then the WM could support:

```text
terminal program -> pty -> cleat/Ghostty screen model -> Katzensteg WM placement
```

That means the same host could place:

- normal terminal programs
- SDL/preload apps
- graph/rendering helpers
- web/CEF helpers
- status widgets

For terminal programs, input routes to the PTY. For graphics producers, input routes through the Katzensteg input protocol. The host model stays the same: producer/window/placement/focus/lifecycle.

## Dynamic app windows

If an intercepted app creates additional SDL/windows, the runtime could eventually emit lifecycle messages such as:

```json
{ "type": "window_created", "window_id": "...", "title": "...", "preferred_size": { ... } }
{ "type": "window_closed", "window_id": "..." }
```

The WM would decide where to place the new window instead of the runtime hardcoding a single `main` surface forever.

This is useful even for in-process applications, not just external producer services.

## Themes

This should be useful, but also fun. Themes could be part of the point.

Possible theme targets:

- **DESQView / DOS TUI**
  - box drawing, hotkeys, tiled panes, help/status bars

- **Classic Mac**
  - menu bar, close box, resize handle, monochrome-ish chrome

- **Amiga Workbench**
  - blue/orange/gray palette, chunky beveled gadgets, draggable screens/windows vibe

- **NeXTSTEP**
  - grayscale beveled panels, shelf/dock, crisp minimalism

- **X11 twm / Motif**
  - stippled title bars, primitive resize handles, hostile-but-charming controls

- **Plan 9 rio**
  - simple text-first windowing, mouse-chord-ish interaction, minimal decoration

- **Lisp Machine / Symbolics Genera**
  - listener, inspector, object browser, mouse-sensitive text, structured panes
  - commands like `Describe Window`, `Inspect Producer`, `Suspend Process`, `Expose`, `Bury`, `Edit Definition`
  - especially appropriate/funny as the RMS theme

Themes should be more than colors. They might control:

- border/titlebar style
- menu/status bar style
- focus indicator
- resize handles
- pointer/cursor affordances
- default layout behavior
- whether chrome is text-cell-only or Kitty-graphics-enhanced

## Why not now

This is not the next urgent implementation task. The immediate work is still stabilizing the embed protocol, process-tree lifetime, cleanup semantics, and Pi extension behavior.

But this idea is worth preserving because it gives a concrete future host for testing the hard cases before they are baked into Pi or agent-facing APIs.
