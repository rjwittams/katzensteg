# Luchs

`luchs` is an SDL-backed local HTML fragment viewer for Katzensteg experiments.

First slice:

```bash
luchs path/to/fragment.html
```

The initial implementation presents through SDL so Katzensteg can intercept it like any other SDL workload. Browser/CDP frame capture will be layered in after the SDL presentation skeleton is working.

The CDP helper lives under `tools/luchs/cdp/`. It uses an installed Chromium-family browser rather than building or bundling Chromium.

```bash
node tools/luchs/cdp/luchs-cdp.mjs tools/luchs/testdata/static.html > /tmp/luchs-frame.bin
```

Set `LUCHS_BROWSER=/path/to/chrome` when browser discovery is not enough.
