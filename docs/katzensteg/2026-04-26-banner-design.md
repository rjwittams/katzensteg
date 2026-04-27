# Katzensteg Launcher Banner — Design

## Goal

A short, themed terminal banner shown when the user starts the katzensteg
launcher. The banner sets an 80s-CRT mood (green/amber on black) and reads
"katzensteg" in a thin outline letterform similar to the visual reference
sketch.

The Python file at `tools/katzensteg/katzensteg_banner.py` is a **prototype**:
its job is to let us iterate on look-and-feel quickly. Once the visual is
right, the same animation gets ported to Zig and integrated into
`tools/katzensteg/launcher.zig`.

## Scope

In scope:
- Visual prototype in Python (single file).
- One fixed title: `katzensteg`.
- Brief power-on intro animation followed by a steady-state loop.
- Two run modes: looping (for iteration / showcase) and one-shot (for the
  launcher hand-off).

Out of scope:
- Multi-string support / arbitrary text input.
- Runtime font selection (no `figlet` dependency at runtime).
- Tagline, subtitle, footer, nerd-font glyphs.
- Sound / non-terminal output.
- The Zig port itself (separate plan, separate session).

## No runtime font dependency

`figlet` was used in the previous prototype but is not used here. The title
is fixed, so we generate ASCII art **once at dev time** (using whatever tool
gives us the look we want) and paste it into the source as a single
multiline constant. The Zig port will embed the same constant. This avoids
both the runtime dependency and the inconsistent quality of the figlet font
catalog.

If we later decide we want a slightly different letterform, we regenerate
the constant. It is just a string.

## Visual targets

- **Palette**: green primary `(34, 255, 100)`, amber secondary
  `(255, 200, 60)`, pure black background. Bright white-green for the spark
  phase only.
- **Letterform**: thin outline style, ~6 rows tall. Each glyph is hollow,
  drawn from short stroke segments rather than filled blocks (matches the
  reference sketch).
- **Steady state**: letters lit at full brightness, with a slow rotating
  green↔amber gradient sweeping across the art and a gentle ~1.6 Hz
  brightness pulse. A dim coloured underline row sits beneath the letters
  as a faint glow.

## Animation: CRT power-on intro

Total intro length ≈ 2.5 seconds, then steady-state.

| Phase | Time (s) | Effect |
|---|---|---|
| 1. Spark | 0.0 – 0.3 | Black field. A single bright white-green horizontal line appears at vertical centre, faintly flickering. |
| 2. Vertical scan | 0.3 – 0.9 | The line expands top-and-bottom, revealing the letter rows progressively. Letters appear in dim flat green, no gradient yet. The currently-revealed row is brightened by a vertical gaussian "beam" so the scan is visible. |
| 3. Stabilize | 0.9 – 1.6 | Beam fades. Brightness ramps to full. Gradient rotation engages and the green↔amber sweep starts moving across the letters. |
| 4. Steady state | 1.6 + | Final look: full-brightness outline letters + slow rotating green/amber gradient + gentle pulse + dim coloured underline row. Loops indefinitely. |

Phase boundaries are smooth, not hard cuts — each phase fades into the next
across ≈100 ms so the eye does not see a discrete step.

## Code layout (Python prototype)

Single file, replacing the current contents of `katzensteg_banner.py`.
Roughly 250 lines, organised top-to-bottom as:

1. **Constants**
   - `KATZENSTEG_ART`: multiline string holding the chosen ASCII art.
   - `GREEN`, `AMBER`, `SPARK` colour tuples.
   - Phase timings: `T_SPARK_END`, `T_SCAN_END`, `T_STABILIZE_END`.

2. **ANSI / colour helpers**
   - `rgb_fg(r, g, b) -> str`
   - `reset() -> str`
   - `lerp(a, b, t)`, `lerp3(a, b, t)` for tuple interpolation.
   - `clear_screen() -> str`, `cursor_home() -> str`.

3. **Gradient sampler**
   - `sample_gradient(x, y, t) -> (r, g, b)`: rotating diagonal sweep
     between GREEN and AMBER. Single source of truth for the steady-state
     colour at any pixel.

4. **Phase renderers** — one function per phase. Each takes the local
   phase time `t_phase`, the global time `t_global` (for animations that
   keep running across phases), terminal width, and returns a list of
   ANSI-painted lines.
   - `render_spark(t_phase, term_w) -> list[str]`
   - `render_scan(t_phase, t_global, term_w) -> list[str]`
   - `render_stabilize(t_phase, t_global, term_w) -> list[str]`
   - `render_steady(t_global, term_w) -> list[str]`

5. **Orchestrator**
   - `render(t_global, term_w) -> list[str]`: picks the phase from
     elapsed time and delegates. Handles the smooth fade between phases by
     blending the two adjacent renderers near each boundary.

6. **Main loop / CLI**
   - `argparse` with: `--fps` (default 30), `--play-once` (run intro then
     exit on first steady-state frame), `--once-after SECONDS` (render a
     single frame at time T and exit — useful for screenshots and visual
     iteration), `--no-color` (also honours the `NO_COLOR` env var).
   - Loop: clear screen, render frame, sleep to maintain fps, exit on
     Ctrl-C or when the chosen exit condition fires.

## CLI surface

```
katzensteg_banner.py [--fps N] [--play-once | --once-after S] [--no-color]
```

- Default: loop the intro then steady-state forever.
- `--play-once`: run the intro, render the first steady-state frame, exit.
  This is what the launcher will eventually invoke.
- `--once-after S`: render the frame at `t_global = S` exactly once and
  exit. For visual iteration on a specific phase.
- `--no-color`: degrade to plain ASCII without colour codes.

## What is dropped vs. the previous prototype

- `figlet` invocation, font catalogue, auto-font sizing.
- Mode flags (`-m 0..3`), `--tour`, `--lofi`, `--truecolor`.
- Nerd font / Powerline glyphs.
- Subtitle and footer lines.
- 256-colour and 16-colour fallback paths (we only render in truecolour;
  if the terminal cannot do truecolour the user gets `--no-color` plain
  text).

## Open questions / deferred

- Final choice of letterform constant: pick during prototyping, paste into
  the constant before declaring the prototype done.
- Whether the launcher in Zig blocks on the banner finishing or kicks it
  off concurrently while it sets up: deferred to the Zig port.
