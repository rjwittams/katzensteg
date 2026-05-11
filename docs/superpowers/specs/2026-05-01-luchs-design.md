# Luchs Design

## Goal

`luchs` is a local visual fragment viewer that can render HTML first, and later broader fragment types, into a surface Katzensteg can display. It should also remain useful outside a terminal by presenting to a normal window when Katzensteg is not involved.

The name is intentionally broader than "webview" so the tool can later become a generic viewer for HTML, images, Markdown, SVG, or agent-authored fragments.

## Direction

`luchs` should keep a renderer/presenter split internally, while using SDL as the main presenter for as long as that remains practical. SDL is valuable because it gives the same tool a normal-window mode outside Katzensteg and a capture path inside Katzensteg.

Renderer backends produce raw frames and input/event hooks:

- `test-pattern`: bring-up renderer, useful for SDL/Katzensteg smoke tests.
- `native-webview`: current macOS `WKWebView` helper process, producing raw RGBA frames.
- Future Linux WebKitGTK renderer when dependencies and snapshot mechanics are settled.
- Future CEF renderer if we need a heavier, debuggable browser backend with real DevTools support.

Presenter backends consume raw frames:

- `sdl`: current and preferred presenter for the prototype. It creates a normal SDL window, uploads frames to an SDL texture, and calls `SDL_RenderPresent`. Katzensteg can intercept this today through the SDL adapter, and the tool still works as a real window without Katzensteg.
- `katzensteg-core`: possible later presenter. This should wait until a proper app-facing Katzensteg API is useful enough to justify bypassing SDL. It needs non-preload initialization, sink selection, lifecycle hooks, and input/resize routing that do not assume SDL interposition.

This split keeps `luchs` useful now and lets it pressure Katzensteg core later without forcing a premature API.

## Why Not CDP Screenshotting

CDP screenshot and screencast APIs deliver encoded images, usually base64 PNG/JPEG frames. A per-frame PNG loop would force browser encode, helper decode, SDL upload, and terminal encode/composition. That path is useful for one-shot screenshots, but it does not prove the architecture we want for an interactive viewer.

If Chromium becomes interesting later, it should be through a deeper embedded-browser backend such as CEF, not a JavaScript bridge plus screenshot stream. Playwright/CDP can still be useful for tests or automation, but it should not be a `luchs` renderer backend.

## Current Slice

The default renderer is still the synthetic test pattern:

```bash
luchs path/to/fragment.html
```

The useful HTML path on macOS is:

```bash
luchs --renderer=native-webview path/to/fragment.html
```

That loads one local HTML file through the native WebView backend and streams raw frames into the SDL presenter.

The native WebView path runs unbounded by default. Bounded frame counts are useful for smoke profiles and tests, but interactive profiles must not require an explicit `--frames=0` escape hatch. The current slice intentionally does not include a manifest, persistent stdio protocol, hot reload, browser selection UI, multi-window content islands, or a direct Katzensteg core presenter.

## Data Flow

```text
HTML file
  -> native WebView helper
  -> repeated LUCHS_RAW_FRAME headers + raw RGBA bytes
  -> presenter backend
       -> SDL texture + SDL_RenderPresent now
       -> Katzensteg core external framebuffer API later
  -> Katzensteg SDL interposer or future core presenter
  -> terminal direct-tty / embed / future sinks
```

## Katzensteg Core Evolution

The merged core split is a useful foundation, and external framebuffer presentation now has a batch/embed path. That removes one blocker for a direct core presenter, but it does not make that presenter the immediate priority.

For a direct `luchs -> libkatzensteg-core` presenter, core needs:

- explicit runtime initialization for non-preload tools
- presentation sink selection, including direct tty and batch/embed sinks
- lifecycle/shutdown hooks for an owning application
- input and resize routing that does not assume SDL interposition

Until those exist, SDL remains the practical presenter boundary.

## Resize And Embedding

`luchs` currently uses a fixed WebView viewport and SDL window size. Katzensteg can scale the presented surface down, but that is a poor long-term answer for text-heavy content.

Embed hosts need a resize model that can handle both cooperative and non-cooperative children:

- cooperative content can receive a resize/reflow signal and produce a new surface size
- non-cooperative content can be scaled, letterboxed, cropped, or opened externally
- text-oriented fragments should prefer reflow over bitmap scaling where possible

This should probably be explored in window-manager mode after the current refactor settles.

## App Channel

Katzensteg's outer protocol should remain the visual/render protocol. Target application stdin/stdout should only be carried inside an explicit opt-in envelope so normal apps do not corrupt render streams.

Reserved envelope names:

```json
{"type":"app_stdin","data":"..."}
{"type":"app_stdout","stream":"stdout","data":"..."}
{"type":"app_stdout","stream":"stderr","data":"..."}
```

`luchs` does not need this in the current file-based invocation. Later, `luchs` can opt in and interpret `app_stdin` messages as `set_html`, `load_file`, `eval`, resize, or input commands, while sending DOM/application events back as `app_stdout` payloads.

In an agent attach mode, content should probably be identified independently from how it is presented. An agent might provide fragments such as HTML, React, Markdown, Mermaid, images, or generated UI state, then request one or more presentations of the same content:

- inline reflow with terminal text and placeholders
- expanded side panel inside the Katzensteg window manager
- another terminal pane
- a real SDL/WebKit window
- the system browser

This keeps room for multiple content islands and for unloaded/tab-like fragments that are retained but not actively rendered.

## Input And Interactivity

The native WebView path uses the SDL event path:

```text
terminal input
  -> Katzensteg input injection
  -> SDL events delivered to luchs
  -> helper stdin JSONL input messages
  -> DOM mouse/key/wheel/text events in WKWebView
  -> web page interaction
```

This keeps Katzensteg as the terminal input owner and avoids exposing a premature Katzensteg API. Mouse coordinate mapping should use the SDL window dimensions as the WebView viewport dimensions.

The current WebView input bridge is intentionally approximate. It covers basic click, hover, wheel, key, text input, and a synthetic caret well enough for the prototype, but it is not a full browser input stack. Modifier state, selection gestures, IME/composition, clipboard, drag/drop, trusted browser events, and precise text caret behavior remain open.

## Testing

Focused tests should cover:

- argument parsing and backend selection
- unsupported backend errors
- raw frame metadata validation
- SDL presenter smoke through the existing synthetic renderer
- native WebView helper tests around file loading, frame metadata, and basic input
- manual input checks through `tools/luchs/testdata/interactive.html`
- future core presenter tests around app-facing initialization, sink selection, lifecycle, and non-SDL input/resize routing

End-to-end visual verification can start as a manual smoke because the value is proving the renderer-to-presenter-to-Katzensteg path. Once stable, add a script that checks logs or embed JSONL for at least one frame batch.

## Open Questions

- What is the minimum raw-frame transport that avoids extra copies without overbuilding IPC?
- What resize contract should embed hosts offer to cooperative and non-cooperative children?
- What is the right unit of identity for agent-provided content fragments versus their presentations?
- How long can SDL remain the main presenter before a direct Katzensteg core presenter is worth the complexity?
