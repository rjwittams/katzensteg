# Pi Visual Interaction Brainstorm

Date: 2026-04-28
Status: brainstorm / prompts for later design work

This note captures rough product/API ideas from the Pi embed-panel prototype. It is intentionally handwavy. The current implementation is still a debug/proof path, but the prototype makes it easier to see what Katzensteg + Pi could become.

## Core framing

Keep three concepts separate:

- **Producer**: a process or service that can render visuals and/or accept visual input.
- **Window**: a logical visual output from a producer.
- **Placement**: a Pi-owned place where a window is shown, such as a sidebar card, inline conversation block, popup, or status-bar slot.

The current `/katzensteg-panel` prototype mostly conflates these into one owned sidebar panel. Future work should avoid baking that conflation into the protocol or Pi APIs.

## Brainstorm prompts

### 1. Persistent sidebar visuals

Use case: user keeps a persistent process in the sidebar, such as a graph, monitor, game, video, build dashboard, or visualization.

Questions:

- How does Pi present multiple sidebar visuals at once?
- Is there a sidebar selection/focus mode?
- How are cards reordered, resized, pinned, hidden, or killed?
- What is the difference between closing a placement and terminating the producer?
- What status badges are useful: running, suspended, idle, loading, failed, detached?

### 2. Agent-presented visuals

Use case: the agent wants to show the user something: video, SDL, LÖVE, pygame, web/CEF/offscreen browser output, graph, markdown, Mermaid, etc.

Questions:

- Does the agent get a structured `present_visual` tool/API, or is it expected to invoke slash commands?
- How does the agent choose inline vs sidebar vs popup/modal?
- Can an inline visual be promoted/pinned into the sidebar?
- Can the same producer window have multiple placements at once?
- How does the agent know when the visual is ready to show?
- How are expensive/slow visuals represented before launch: ready card, loading spinner, explicit user activation?

### 3. Inline conversation placements

Use case: a visual appears inline in the conversation and remains meaningful in scrollback.

Questions:

- How does Pi allocate and retain geometry for inline visuals?
- What happens when an inline visual scrolls offscreen?
- Should Pi detach when offscreen and reattach when visible again?
- How long should a producer/window remain revivable after its inline placement scrolls away?
- Can a scrolled-back visual be restarted/revived from saved state or content?

### 4. Status-bar / shared service visuals

Use case: tiny persistent visuals in the status bar, such as token counters, background job monitors, or system status.

Questions:

- Is this mostly socket/service mode rather than owned child-process mode?
- Does Pi ensure the producer service is running before attach?
- Does closing/detaching the status placement leave the service alive?
- What config expresses “ensure this producer is up and attach this status window”?
- How does this differ from sidebar placement besides size and policy?

### 5. Multi-window producer services

Use case: one producer/service handles many content requests and returns attachable windows. Examples: graph/DOT viewer, markdown/Mermaid viewer, CEF/web helper, plotting service.

Questions:

- What does `window_created` / `window_ready` / `window_closed` look like?
- How does the agent send content to an already-running producer?
- Can windows be revived after detaching?
- Does producer lifetime follow window lifetime, idle timeout, session lifetime, or explicit user policy?
- Should a single CEF/helper service own many logical windows?

### 6. Input redirection and interaction

Use case: the user interacts with visual placements via mouse/keyboard while preserving Pi’s terminal-first interaction model.

Questions:

- What are the modes: passive, selectable, focused, raw input, semantic input, annotation?
- Does first click select/focus the placement rather than pass through?
- How does Escape or another key reliably return focus to Pi?
- How are terminal mouse events translated to placement-local cell, pixel, or normalized coordinates?
- How does keyboard focus work for SDL/game/web producers?
- How should Pi visually indicate that input is being routed to a visual?

Potential event shape:

```json
{
  "type": "input",
  "window_id": "main",
  "placement_id": "...",
  "kind": "mouse_down",
  "cell": { "row": 4, "col": 12 },
  "normalized": { "x": 0.42, "y": 0.70 },
  "buttons": ["left"],
  "modifiers": []
}
```

### 7. Semantic / multimodal agent interactions

Use case: user gestures over a visual and the agent receives a useful artifact rather than raw SDL-style input.

Examples:

- user draws a path; agent receives SVG/path points
- user selects a region; agent receives coordinates and maybe a cropped image
- user clicks a graph node; agent receives the node id/source location
- user clicks a chart point; agent receives data coordinates
- user annotates a rendered web/app view; agent receives structured annotation data

Questions:

- Which interactions are host/Pi-level annotation tools vs producer-native input?
- How does a producer advertise semantic capabilities?
- How does the agent receive artifacts: tool result, message attachment, file path, JSON event?
- Can semantic input and raw input coexist in one placement?

### 8. Lifecycle and focus policy

Use case: different producers need different behavior when unfocused, detached, or closed.

Important: the current RetroArch “run when unfocused” setup was mainly for testing terminal-to-SDL input redirection while the real app window is unfocused. It should not be treated as the universal desired policy.

Policy ideas:

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

Questions:

- Should games/audio producers default to suspend on blur?
- Should suspension use `SIGSTOP`/`SIGCONT` on the producer process group?
- When is cooperative pause better than hard suspend?
- What happens if the producer holds audio/video/device resources while suspended?
- How does Pi show suspended vs running visuals?
- How does process-tree ownership interact with shared/socket-mode producers?

### 9. Profiles as reusable presentation wrappers

Use case: “present my pygame”, “present this video”, “present this LÖVE project”, “present this web page”, not just fixed named app profiles.

Questions:

- How do profiles apply to arbitrary commands or content?
- What does a profile declare: capture backend, env/preload policy, default placement, lifecycle policy, input policy, readiness behavior?
- How does a profile expose parameters safely?
- What defaults make sense for media, games, web, plots, and app visualizations?

### 10. Ready/loading/dismissible state

Use case: some visuals should not launch immediately, or take time before first frame.

Questions:

- Can a visual card exist in `ready-to-start` state with Start/Dismiss actions?
- What does Pi show while a producer launches but has not attached/presented yet?
- Is first-frame readiness enough, or should producers emit explicit ready/progress messages?
- How are startup errors surfaced inline/sidebar?

## Current useful foundation

The prototype now demonstrates:

- Pi-owned overlay geometry
- raw Kitty graphics replay into Pi-known areas
- viewport updates on resize
- detach cleanup/drain behavior
- close path that does not immediately drop cleanup batches
- basic owned-process launch path

This is enough to start designing higher-level presentation/session abstractions without guessing about terminal placement mechanics.

## Not now

Do not rush to implement the above. Treat this as a prompt list for later API/protocol/product design once the low-level embed path and process lifetime semantics are stable.
