# Luchs Design

## Goal

`luchs` is a local visual fragment viewer that can render HTML first, and later broader fragment types, into a surface Katzensteg can display. It should also remain useful outside a terminal by presenting to a normal window when Katzensteg is not involved.

The name is intentionally broader than "webview" so the tool can later become a generic viewer for HTML, images, Markdown, SVG, or agent-authored fragments.

## Direction

`luchs` should be split internally into a renderer backend and a presenter backend.

Renderer backends produce raw frames and input/event hooks:

- `test-pattern`: current bring-up renderer, useful for SDL/Katzensteg smoke tests.
- `native-webview`: macOS `WKWebView` helper process first, producing raw RGBA frames.
- Future Linux WebKitGTK renderer when dependencies and snapshot mechanics are settled.
- Future CEF renderer if we need a heavier, debuggable browser backend with real DevTools support.

Presenter backends consume raw frames:

- `sdl`: first presenter. It creates a normal SDL window, uploads frames to an SDL texture, and calls `SDL_RenderPresent`. Katzensteg can intercept this today through the SDL adapter, and the tool still works as a real window without Katzensteg.
- `katzensteg-core`: future presenter. This should call a proper app-facing Katzensteg API once the core can initialize outside preload, select a presentation sink, and batch/embed external framebuffers.

This split lets `luchs` drive the evolution of Katzensteg core without blocking the immediate viewer on that API work.

## Why Not CDP Screenshotting

CDP screenshot and screencast APIs deliver encoded images, usually base64 PNG/JPEG frames. A per-frame PNG loop would force browser encode, helper decode, SDL upload, and terminal encode/composition. That path is useful for one-shot screenshots, but it does not prove the architecture we want for an interactive viewer.

If Chromium becomes interesting later, it should be through a deeper embedded-browser backend such as CEF, not a JavaScript bridge plus screenshot stream. Playwright/CDP can still be useful for tests or automation, but it should not be a `luchs` renderer backend.

## First Slice

The first command remains:

```bash
luchs path/to/fragment.html
```

Current behavior presents a synthetic SDL frame source. The next useful slice is:

```bash
luchs --renderer=native-webview path/to/fragment.html
```

That should load one local HTML file through the native WebView backend and stream raw frames into the SDL presenter.

The first native WebView slice does not need a manifest, persistent stdio protocol, DOM event forwarding, hot reload, browser selection UI, or a direct Katzensteg core presenter.

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

The merged core split is a useful foundation, but the current exported external framebuffer functions still assume the existing terminal runtime. They require active tty, scene engine, and kitty backend state, and external framebuffer presentation does not yet have the batch/embed path that renderer presents have.

For a direct `luchs -> libkatzensteg-core` presenter, core needs:

- explicit runtime initialization for non-preload tools
- presentation sink selection, including direct tty and batch/embed sinks
- external framebuffer presentation through batch/embed
- lifecycle/shutdown hooks for an owning application
- input and resize routing that does not assume SDL interposition

Until those exist, SDL is the practical presenter boundary.

## App Channel

Katzensteg's outer protocol should remain the visual/render protocol. Target application stdin/stdout should only be carried inside an explicit opt-in envelope so normal apps do not corrupt render streams.

Reserved envelope names:

```json
{"type":"app_stdin","data":"..."}
{"type":"app_stdout","stream":"stdout","data":"..."}
{"type":"app_stdout","stream":"stderr","data":"..."}
```

`luchs` does not need this in the first file-based invocation. Later, `luchs` can opt in and interpret `app_stdin` messages as `set_html`, `load_file`, `eval`, resize, or input commands, while sending DOM/application events back as `app_stdout` payloads.

## Input And Interactivity

The first native WebView slice may be view-only. If input is added early, it should use the SDL event path:

```text
terminal input
  -> Katzensteg input injection
  -> SDL events delivered to luchs
  -> helper stdin JSONL input messages
  -> DOM mouse/key/wheel/text events in WKWebView
  -> web page interaction
```

This keeps Katzensteg as the terminal input owner and avoids exposing a premature Katzensteg API. Mouse coordinate mapping should use the SDL window dimensions as the WebView viewport dimensions.

## Testing

Focused tests should cover:

- argument parsing and backend selection
- unsupported backend errors
- raw frame metadata validation
- SDL presenter smoke through the existing synthetic renderer
- native WebView helper tests around file loading and frame metadata once introduced
- manual input checks through `tools/luchs/testdata/interactive.html`
- future core presenter tests around external framebuffer batch/embed behavior

End-to-end visual verification can start as a manual smoke because the value is proving the renderer-to-presenter-to-Katzensteg path. Once stable, add a script that checks logs or embed JSONL for at least one frame batch.

## Open Questions

- What is the minimum raw-frame transport that avoids extra copies without overbuilding IPC?
- Should the direct core presenter be built only after external framebuffer batch/embed exists, or should `luchs` introduce that core work as its next milestone?
