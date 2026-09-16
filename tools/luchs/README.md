# Luchs

`luchs` is an SDL-backed local HTML fragment viewer for Katzensteg experiments.

Default smoke renderer:

```bash
luchs path/to/fragment.html
```

Without an explicit renderer, `luchs` presents a synthetic frame source through SDL. This keeps a cheap smoke path for the SDL presenter and Katzensteg interception.

HTML renderer on macOS:

```bash
luchs --renderer=native-webview path/to/fragment.html
```

The native WebView renderer uses a `WKWebView` helper that emits raw RGBA frames to the SDL presenter. Linux can follow with WebKitGTK when the dependency and snapshot mechanics are settled.

The intended internal split is:

- renderer backend: test pattern, native WebView
- presenter backend: SDL for now

SDL is intentionally the main presenter for the prototype. It keeps `luchs` useful as a normal window outside a terminal while giving Katzensteg an immediate hook point through SDL interception.

The direct Katzensteg core presenter is a future option, not the next requirement. It should wait until the app-facing core API can initialize outside preload, select sinks, handle lifecycle, and route input/resize without assuming SDL interposition.

The helper binary is installed next to `luchs` as `luchs-webview-capture`. Direct helper invocation emits one frame by default; `luchs` invokes it with a frame count and FPS. Native WebView runs are unbounded by default, while smoke profiles pass an explicit bounded `--frames=N`.

`luchs` forwards SDL mouse, wheel, key, and text-input events to the helper over stdin as JSONL. The helper dispatches those into the page as DOM events. This is intentionally separate from any future app/control stdin channel.

Options for hosting a page in a panel:

```bash
luchs --renderer=native-webview --size=1568x512 --watch page.html
luchs --renderer=native-webview --size=1568x512 https://example.com
```

The page is a local file or an `http(s)` URL. The helper uses WebKit's
default website data store, which is persistent for this binary (under
`~/Library/WebKit`), so a login made in one run, through the panel's own
input, still holds in the next: a private page such as a Claude artifact
renders once the viewer has been signed in.

The helper's window is on screen but fully transparent, on every Space and
above fullscreen apps. WebKit treats an off-screen or covered window as a
hidden page, which stops `requestAnimationFrame` and slows timers, and a
page that waits on a frame (a sign-in form after submit, say) hangs. With
the window visible the page's own clock runs its animations, so the capture
no longer steps them by hand; frames come from `takeSnapshot`, never the
screen. The view identifies itself as Safari, since sign-in providers refuse
a bare WebKit agent as an embedded view.

`window.open` and `target=_blank` get a real second view, the panel's full
size, above the main one. The frames and the input follow the newest popup
while it is open and return to the main view when the page closes it. The
popup keeps its opener, so a sign-in that posts its result back to the
opening page (Google's popup flow does) completes inside the panel.

Input reaches the page as real events. luchs forwards SDL mouse, wheel,
key and text events as JSON lines; the helper turns them into `NSEvent`s
and hands them to the web view's own responder methods, so WebKit does the
hit testing (iframes included), focus, text insertion and shortcuts. A
printable key waits for the text event behind it and is sent as one key
event carrying the layout's characters; key events carry SDL's modifier
bits, so shift+tab, ctrl+c and command shortcuts arrive as such. WebKit
draws no caret in a window that is not key, so a user script draws one at
the selection of the focused field in every frame. `LUCHS_INPUT=bridge`
selects the older bridge that dispatches synthetic DOM events from
JavaScript instead (top document only), and `LUCHS_INPUT_TRACE=1` logs
each delivered event.

Page console output, page errors, popups and navigations are logged one
line each to `/tmp/luchs-console-<pid>.log`, or the path in
`LUCHS_CONSOLE_LOG`. The helper's stdout carries frames and its stderr is
the launcher's, so this file is where a page is debugged from.

- `--size=WxH` sets the frame size (default 800x600). A panel host passes the
  pixel area its cells cover, doubled on high-density displays, so text stays
  legible after the terminal scales the image into the grid.
- `--watch` polls the page file's modification time four times a second and
  asks the helper to reload it on change, bypassing WebKit's cache. Rewriting
  the file is the whole update channel.
- Unbounded native-webview runs present a frame only when its pixels changed,
  plus one a second as a keep-alive, so a static page does not stream. Bounded
  `--frames=N` runs keep every frame so smoke profiles finish on time.
- A bare `--`, as the launcher forwards it, is ignored.

Current limitations:

- the WebView viewport is fixed for the run: no resize after start
- input is a US keyboard layout: the characters on a key event come from the SDL keycode, the text from SDL's text input
- macOS native WebView only
- `--watch` applies to files only; a URL page is loaded once
- no manifest, app channel, or multi-fragment/session protocol yet

Manual input smoke:

```bash
./zig-out/bin/katzensteg probe.embed.luchs_interactive
```

Use the interactive fixture to check click, hover/motion, key, text, and scroll behavior through SDL/Katzensteg. This profile is intentionally unbounded and should run until you quit it. The static smoke profile passes `--frames=180` when a bounded run is useful.
