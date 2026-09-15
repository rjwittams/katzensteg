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
```

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
- WebView input is a practical JS bridge, not a complete browser input stack
- macOS native WebView only
- file-based HTML input only; no manifest, app channel, or multi-fragment/session protocol yet

Manual input smoke:

```bash
./zig-out/bin/katzensteg probe.embed.luchs_interactive
```

Use the interactive fixture to check click, hover/motion, key, text, and scroll behavior through SDL/Katzensteg. This profile is intentionally unbounded and should run until you quit it. The static smoke profile passes `--frames=180` when a bounded run is useful.
