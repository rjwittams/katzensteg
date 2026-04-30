# Luchs Design

## Goal

`luchs` is a small SDL-backed viewer for local web fragments. The first slice loads one HTML file, renders it through an installed Chromium-family browser using the Chrome DevTools Protocol, copies captured frames into an SDL2 texture, and lets Katzensteg intercept and present that SDL output.

The name is intentionally broader than "webview" so the tool can later become a generic visual viewer for HTML, images, Markdown, SVG, or agent-authored fragments.

## First Slice

The first command is:

```bash
luchs path/to/fragment.html
```

It should:

- resolve a local HTML file path
- start or connect to a prebuilt/system Chromium-family browser through CDP
- load the file into a page
- capture page frames at a conservative fixed size and frame rate
- decode frame pixels into RGBA/BGRA memory
- update one SDL2 texture
- present through SDL2 so Katzensteg can capture it through the existing SDL hook path

The first slice does not need a manifest, persistent stdio protocol, DOM event forwarding, hot reload, or browser selection UI.

## Architecture

`tools/luchs/` owns the viewer. It should be independent of the Katzensteg preload runtime and depend on Katzensteg only by using SDL2 as the presentation boundary.

The first implementation can use a small Node control process for CDP because Glimpse already proves this shape is practical: JSON-ish command/control around native or browser-backed UI without building Chromium. `luchs` should use an installed Chromium-family browser or an explicitly configured executable path. It must not require building Chromium.

The SDL presenter can be implemented in Zig so it fits the repository's build system and existing SDL bindings. A thin CDP helper can stream captured frames to the presenter over stdout or a pipe. If using PNG screenshots first, the presenter decodes PNG into RGBA before uploading to SDL. This is simpler than trying to extract native WebView snapshots cross-platform in the initial proof.

## Data Flow

```text
HTML file
  -> luchs CDP helper
  -> Chromium page
  -> screenshot/frame capture
  -> decoded RGBA/BGRA frame
  -> SDL_UpdateTexture / SDL_RenderPresent
  -> Katzensteg SDL interposer
  -> terminal direct-tty or embed presentation
```

The first slice can tolerate extra copies. Correctness and proof value matter more than frame-rate efficiency. Frame cadence should be capped, for example at 15-30 FPS, so the terminal upload path is not overwhelmed by mostly-static web UI frames.

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

The first slice may be view-only. If input is added early, it should use the existing SDL event path:

```text
terminal input
  -> Katzensteg input injection
  -> SDL events delivered to luchs
  -> CDP Input.dispatchMouseEvent / Input.dispatchKeyEvent
  -> web page interaction
```

This keeps Katzensteg as the terminal input owner and avoids exposing a new Katzensteg API. Mouse coordinate mapping should use the SDL window dimensions as the browser viewport dimensions.

## Alternatives Considered

### Native WebView snapshots

Using WKWebView/WebKitGTK/WebView2 directly would be lighter than Chromium CDP and closer to Glimpse's native-window model. It is not the best first slice because reliable snapshot-to-RGBA frame streaming is platform-specific and Glimpse does not currently expose that as a frame stream.

### Bundled Chromium

Bundling Chromium through Playwright or a similar mechanism avoids depending on a system browser. It adds a large download/install cost, so it should remain a fallback after the system-CDP proof works.

### Direct Katzensteg API

A future libkatzensteg API could accept external frames directly. That is intentionally not part of this design. SDL remains the hook point because the current runtime already captures and presents SDL workloads well.

## Testing

The first implementation should include:

- argument parsing tests for required HTML path and optional browser path
- CDP protocol unit tests around command framing where practical
- frame decoder tests with a tiny known PNG fixture
- a Zig unit test for frame header parsing if frames cross a pipe
- a smoke profile that launches `luchs` with a small HTML fixture through Katzensteg
- `zig build test`

End-to-end visual verification can start as a manual smoke because the value is proving the browser-to-SDL-to-Katzensteg path. Once stable, add a script that checks logs or embed JSONL for at least one `frame_batch`.

## Open Questions

- Which installed browser discovery order is most useful on macOS and Linux?
- Should the first CDP helper launch its own browser process or connect to an existing debugging port?
- Is PNG screenshot capture acceptable for the first proof, or do we need a faster screencast/frame path immediately?
- When the app-channel envelope lands, should it live in the launcher embed protocol first or in a separate attach/host layer?
