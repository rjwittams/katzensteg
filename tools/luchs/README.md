# Luchs

`luchs` is an SDL-backed local HTML fragment viewer for Katzensteg experiments.

Current slice:

```bash
luchs path/to/fragment.html
```

The current executable presents a synthetic frame source through SDL so Katzensteg can intercept it like any other SDL workload. This keeps `luchs` useful outside a terminal as a real window while giving Katzensteg an immediate capture path.

The next renderer backend is native WebView, not Chromium/CDP. On macOS that means a `WKWebView` helper that emits raw BGRA/RGBA frames to the SDL presenter. Linux can follow with WebKitGTK when the dependency is available.

The intended internal split is:

- renderer backend: test pattern now, native WebView next
- presenter backend: SDL now, direct Katzensteg core later

On macOS:

```bash
luchs --renderer=native-webview path/to/fragment.html
```

The helper binary is installed next to `luchs` as `luchs-webview-capture`. Direct helper invocation emits one frame by default; `luchs` invokes it with a bounded frame count and FPS so it streams repeated `LUCHS_RAW_FRAME` headers plus raw RGBA bytes. `luchs` consumes that pipe internally and keeps helper stderr away from the terminal render stream.
