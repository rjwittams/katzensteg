# Katzensteg Phase 2: Input And SDL Window Policy

Date: 2026-04-25
Status: Draft design

Phase 2 turns Katzensteg from a terminal mirror into an interactive terminal surface. The target is still practical and incremental: keep the SDL preload model, keep the real SDL window available, but make it possible to drive the app from the terminal and eventually hide the real window.

## Goals

- Read terminal keyboard and mouse input in the preloaded process.
- Inject that input into SDL state/events.
- Map terminal mouse coordinates to the captured SDL image.
- Add configurable real-window visibility policy.
- Preserve the current debug path where the real SDL window remains visible.
- Keep terminal drawing owned by the in-process Katzensteg runtime.
- Add a thin launcher only for configuration, supervision, logging, and reset.

## Non-goals

- Do not make a wrapper process own terminal rendering.
- Do not remove the real SDL window path immediately.
- Do not attempt gamepad emulation through terminal input in the first slice.
- Do not require app-specific patches.
- Do not solve hardware renderer interception in this phase.

## Architecture Decision

Use an in-process runtime with an optional thin launcher.

```text
target process + libkatzensteg
  owns terminal input modes
  parses terminal input
  injects SDL events
  owns SDL capture/composition
  owns kitty/ghostty image placement
  owns optional chrome
  applies real-window policy

thin launcher
  sets env/config
  picks preload library
  redirects stdout/stderr
  waits for target process
  restores terminal state after exit/crash
  reports logs/status
```

This avoids coordinating screen drawing across two processes while still giving us a cleaner launch/reset story.

## Terminal Input Model

The runtime should enter a terminal input mode when configured to do so:

- raw or cbreak input
- alternate screen if enabled by mode
- mouse reporting
- focus reporting if useful
- enhanced keyboard protocol where available

The runtime should reserve Katzensteg hotkeys first, then forward unhandled input to SDL.

Example control categories:

- toggle stats
- toggle help/chrome
- toggle inspector
- cycle scaling/layout mode
- cycle real-window mode
- release/capture terminal input
- emergency reset

Conflicts with SDL app keys are unavoidable. The important requirement is that the reserved set is explicit, configurable later, and easy to disable for debugging.

## SDL Event Injection Model

There are two likely mechanisms:

### Hook SDL event polling

Intercept:

- `SDL_PollEvent`
- `SDL_WaitEvent`
- `SDL_WaitEventTimeout`
- possibly `SDL_PeepEvents`

Maintain a Katzensteg synthetic event queue and merge it into the app's SDL event stream.

Advantages:

- precise control over ordering
- works even if app does not expect pushed user events from another thread
- can synthesize events lazily as app polls

Risks:

- more SDL surface to interpose
- must match SDL semantics well enough not to confuse apps

### Use SDL_PushEvent

Push translated input events into SDL's existing queue.

Advantages:

- smaller initial implementation
- uses SDL's own queue machinery

Risks:

- thread/context assumptions
- ordering and wakeup behavior may be less predictable
- may not cover apps using unusual event APIs

Recommended first slice: use a small internal synthetic queue and intercept `SDL_PollEvent` / `SDL_WaitEventTimeout`, then expand only when evidence requires it. `SDL_PushEvent` can remain a fallback or experiment.

## Keyboard Mapping

Terminal keyboard input is not a perfect SDL keyboard model.

Expected limitations:

- key-up is generally not available
- some modifiers may be lossy without enhanced keyboard protocols
- text input and keypress events are distinct in SDL but mixed in many terminal sequences
- terminal escape sequences can conflict with app expectations

Initial mapping should prioritize:

- printable text as `SDL_TEXTINPUT` plus keydown where sensible
- arrows, enter, escape, tab, backspace
- function keys when terminal reports them
- modifiers where terminal protocol makes them clear

Key-up should be conservative. For many SDL apps, keydown/repeat/text is enough for menus and simple controls. Games may need a later stateful "key held until timeout/release surrogate" model.

## Mouse Mapping

Mouse input must be mapped through the current presentation layout:

```text
terminal cell/pixel coordinate
  -> Katzensteg image placement rectangle
  -> composed framebuffer coordinate
  -> SDL logical/output coordinate
  -> app event coordinate
```

The mapping must account for:

- terminal cell pixel size
- image placement size
- aspect-preserving letterbox/pillarbox
- Retina backing scale vs logical SDL window size
- renderer output size
- current Katzensteg layout/chrome

Phase 2 should add one debug log line or inspector record that shows these sizes together for a frame:

- `SDL_GetWindowSize`
- `SDL_GetRendererOutputSize`
- captured framebuffer size
- terminal pixel/cell target
- image placement rectangle
- mouse mapped coordinate

## Real SDL Window Policy

Introduce a policy variable, likely:

```text
KATZENSTEG_REAL_WINDOW=visible|hidden|offscreen|minimized
```

### visible

Current behavior. The real SDL window remains visible and useful for debugging.

### hidden

Create the SDL window but hide it after creation or suppress show/raise calls.

Likely hooks:

- `SDL_CreateWindow`
- `SDL_ShowWindow`
- `SDL_HideWindow`
- `SDL_RaiseWindow`
- possibly `SDL_SetWindowFullscreen`

### offscreen

Create the SDL window at a position outside the visible desktop or move it there after creation.

This may preserve more renderer behavior than hidden windows, but can be platform-specific.

### minimized

Allow the platform window to exist but keep it minimized. This may break render/update behavior in some apps or platforms, so it should be tested rather than assumed.

### no-window

Not a Phase 2 target. Many SDL renderers and apps assume a real window exists. It is a later research topic.

Recommended first slice: implement `visible` and one non-visible mode only, probably `hidden` or `offscreen`, then test against RetroArch, ScummVM, Moonlight, and a tiny SDL demo.

## Chrome Implications

Chrome should remain in-process so it shares one terminal scene with the captured SDL image.

Useful early chrome:

- pre-start splash/status
- one-line stats
- help overlay
- border/layout around a smaller captured image
- log tail area fed by launcher redirection

Text over image may be limited by terminal graphics z-order behavior. If terminal layering is not portable enough, we can:

- keep text outside the image area
- reserve side/bottom chrome bands
- composite overlay text into the image when needed

## Thin Launcher

The launcher should not draw. It should:

- choose preload library
- set app presets
- redirect stdout/stderr
- pass config through environment
- wait for child exit
- restore terminal state
- print log paths

It can stay alive behind the app like a shell/supervisor. The preloaded runtime should still work without it.

## Suggested Implementation Slices

### Slice 1: terminal mode ownership and reset

- add in-process terminal raw/mouse mode setup
- add a reset path on normal exit
- add launcher-side reset after child exit
- prove terminal is restored after clean exit and common crash cases

### Slice 2: basic keyboard injection

- intercept core SDL event polling calls
- inject arrows, enter, escape, tab, backspace, printable text
- test against SDL demo menus and at least one real app menu

### Slice 3: mouse injection

- parse terminal mouse reports
- map to current image rectangle
- inject SDL mouse motion/button/wheel events
- add coordinate debug logs

### Slice 4: real-window policy

- add `visible` and one non-visible mode
- intercept minimal SDL window calls
- verify rendering still works in terminal
- verify app does not lose necessary focus/input behavior

### Slice 5: first chrome controls

- add stats/help hotkey
- add a simple layout mode with reserved text area
- keep image placement and input mapping consistent across layout changes

## Validation Matrix

Test each slice against:

- tiny SDL test app
- RetroArch emulator workload
- ScummVM
- Moonlight software-decode SDL path

For each target, record:

- terminal renders
- real window behavior
- keyboard input works
- mouse input works
- terminal resets after exit
- logs explain selected modes and sizes

## Risks

- Terminal keyboard protocols may not provide enough release/modifier fidelity for some games.
- Hidden/minimized SDL windows may stop rendering on some platforms or backends.
- macOS Retina scaling may keep causing coordinate mismatches until all size concepts are logged together.
- Apps that read input outside SDL will not be handled by SDL event injection.
- stdout/stderr output can still corrupt terminal display without launcher redirection or runtime handling.

## Open Questions

- Should the first non-visible window mode be `hidden` or `offscreen`?
- How should key repeat and key-up be represented for game controls?
- Should input capture be enabled by default for specific app presets only?
- How should a user temporarily release input back to the shell?
- Which hotkeys should be reserved by default?
- Should launcher stdout/stderr redirection use log files first, or pipes so the runtime can tail them live?
