# Katzensteg Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild `tools/katzensteg/katzensteg_banner.py` as a focused Python prototype that plays a CRT power-on intro and lands on a glowing 80s-terminal steady-state banner for the title `katzensteg`. Iterate visually until the look is right, then this becomes the reference for a Zig port.

**Architecture:** Single Python file, stdlib-only. Title is a baked ASCII-art constant (no `figlet` runtime dep). Four phase renderers (Spark, Vertical Scan, Stabilize, Steady) are dispatched by an orchestrator from elapsed time, with linear blending across phase boundaries. Truecolour-only render path; degrades to plain ASCII via `--no-color` / `NO_COLOR`.

**Tech Stack:** Python 3 (stdlib only — `argparse`, `math`, `os`, `shutil`, `sys`, `time`, `dataclasses`, `unittest`). ANSI 24-bit colour escapes.

---

## Files

- **Replace**: `tools/katzensteg/katzensteg_banner.py` (entire contents — current prototype is discarded).
- **Create**: `tools/katzensteg/test_katzensteg_banner.py` — `unittest` tests for pure functions and dispatch logic. Visual phases are checked manually via `--once-after`.

The existing `tools/katzensteg/katzensteg_banner.py` is overwritten in Task 1; do not preserve any of its current functions.

## Visual review protocol

Several tasks finish with a "visual review" step. The protocol is:

1. From `tools/katzensteg/`, run the listed `python3 katzensteg_banner.py --once-after <T>` command.
2. Inspect the rendered frame in the terminal. The expected description is given in each task.
3. If it matches, mark the step done. If it doesn't, **stop and report** before continuing — visual choices propagate forward and the user may want to adjust direction (e.g. swap the art constant, retune timings or colours) before later phases are built on top.

Visual review is the gate for all rendering tasks. There is no automated assertion that "it looks right".

---

## Task 1: Skeleton with baked art constant

Replace the existing prototype with a minimal new file that defines the art constant, the colour/timing constants, and a stub `main()` that prints the static art so we can confirm the constant is correctly embedded.

**Files:**
- Replace: `tools/katzensteg/katzensteg_banner.py`

- [ ] **Step 1: Generate the ASCII art**

From `tools/katzensteg/`, run:

```bash
figlet -f chunky katzensteg
```

`chunky` is the starting candidate (closest to the reference image's outline-block style at a usable scale). If the engineer thinks another figlet font is a better match to the reference image, they may try `block`, `smshadow`, or `shadow` and pick one. **Pick exactly one.** Capture its raw output for use in Step 2.

- [ ] **Step 2: Write the new file**

Replace the entire contents of `tools/katzensteg/katzensteg_banner.py` with:

```python
#!/usr/bin/env python3
"""
katzensteg banner — CRT power-on intro into an 80s terminal steady-state.

Single-file Python prototype, stdlib only. The title is a baked ASCII-art
constant; no runtime font dependency.

Usage:
  python3 katzensteg_banner.py                    # loop forever
  python3 katzensteg_banner.py --play-once        # intro then one frame
  python3 katzensteg_banner.py --once-after 1.2   # one frame at t=1.2s
  python3 katzensteg_banner.py --no-color         # plain ASCII
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import sys
import time
from typing import List, Tuple

# --- Constants ---------------------------------------------------------------

# Replace the body of this string with the figlet output captured in Step 1.
# Keep leading/trailing newlines off; preserve internal whitespace exactly.
KATZENSTEG_ART = r"""<<PASTE FIGLET OUTPUT HERE>>"""

GREEN = (34, 255, 100)
AMBER = (255, 200, 60)
SPARK = (200, 255, 220)  # bright white-green for the initial scan line

# Phase boundaries (seconds, global time)
T_SPARK_END = 0.3
T_SCAN_END = 0.9
T_STABILIZE_END = 1.6
# Boundary blend half-width: each transition crossfades over 2*BLEND seconds.
BLEND = 0.05


# --- Entrypoint --------------------------------------------------------------


def main() -> int:
    art_lines = [ln for ln in KATZENSTEG_ART.splitlines() if ln.strip() or True]
    for line in art_lines:
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Then replace `<<PASTE FIGLET OUTPUT HERE>>` with the raw figlet output from Step 1, preserving its exact whitespace. The triple-quoted raw string is fine for embedding the multi-line block; no escaping needed unless the art happens to contain a `"""` (it won't).

- [ ] **Step 3: Verify the art prints**

```bash
cd tools/katzensteg
python3 katzensteg_banner.py
```

Expected: `katzensteg` printed in the chosen figlet font, no colour, no animation. Confirm the letters are not garbled and there are no leading blank lines.

- [ ] **Step 4: Commit**

```bash
git add tools/katzensteg/katzensteg_banner.py
git commit -m "katzensteg: rebuild banner as baked-art prototype skeleton"
```

---

## Task 2: ANSI helpers and gradient sampler with tests

Add the colour primitives and the gradient function, with unit tests for the deterministic math.

**Files:**
- Modify: `tools/katzensteg/katzensteg_banner.py` (insert helpers below the constants block, above `main`)
- Create: `tools/katzensteg/test_katzensteg_banner.py`

- [ ] **Step 1: Write the failing tests**

Create `tools/katzensteg/test_katzensteg_banner.py`:

```python
import unittest

import katzensteg_banner as kb


class TestLerp(unittest.TestCase):
    def test_lerp_endpoints(self):
        self.assertEqual(kb.lerp(0.0, 10.0, 0.0), 0.0)
        self.assertEqual(kb.lerp(0.0, 10.0, 1.0), 10.0)

    def test_lerp_midpoint(self):
        self.assertEqual(kb.lerp(0.0, 10.0, 0.5), 5.0)


class TestLerp3(unittest.TestCase):
    def test_lerp3_endpoints(self):
        a = (0, 0, 0)
        b = (100, 200, 50)
        self.assertEqual(kb.lerp3(a, b, 0.0), (0, 0, 0))
        self.assertEqual(kb.lerp3(a, b, 1.0), (100, 200, 50))

    def test_lerp3_clamps(self):
        # t outside [0, 1] is clamped.
        a = (0, 0, 0)
        b = (100, 100, 100)
        self.assertEqual(kb.lerp3(a, b, -1.0), (0, 0, 0))
        self.assertEqual(kb.lerp3(a, b, 2.0), (100, 100, 100))


class TestRgbFg(unittest.TestCase):
    def test_format(self):
        self.assertEqual(kb.rgb_fg(34, 255, 100), "\x1b[38;2;34;255;100m")


class TestSampleGradient(unittest.TestCase):
    def test_returns_rgb_tuple_in_range(self):
        for t in (0.0, 0.5, 1.0, 3.7):
            for x in (0.0, 10.0, 50.0):
                for y in (0.0, 3.0):
                    r, g, b = kb.sample_gradient(x, y, t)
                    self.assertTrue(0 <= r <= 255)
                    self.assertTrue(0 <= g <= 255)
                    self.assertTrue(0 <= b <= 255)

    def test_deterministic(self):
        # Same inputs -> same output.
        a = kb.sample_gradient(5.0, 2.0, 1.0)
        b = kb.sample_gradient(5.0, 2.0, 1.0)
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd tools/katzensteg
python3 -m unittest test_katzensteg_banner -v
```

Expected: `AttributeError: module 'katzensteg_banner' has no attribute 'lerp'` (or similar).

- [ ] **Step 3: Implement helpers**

In `tools/katzensteg/katzensteg_banner.py`, between the `BLEND = 0.05` line and the `# --- Entrypoint ---` comment, insert:

```python
# --- ANSI / colour helpers --------------------------------------------------


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def lerp3(
    a: Tuple[int, int, int], b: Tuple[int, int, int], t: float
) -> Tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    return (
        int(lerp(a[0], b[0], t)),
        int(lerp(a[1], b[1], t)),
        int(lerp(a[2], b[2], t)),
    )


def rgb_fg(r: int, g: int, b: int) -> str:
    return f"\x1b[38;2;{r};{g};{b}m"


RESET = "\x1b[0m"
BOLD = "\x1b[1m"


# --- Gradient sampler -------------------------------------------------------


def sample_gradient(x: float, y: float, t: float) -> Tuple[int, int, int]:
    """Rotating diagonal sweep between GREEN and AMBER. Single source of
    truth for the steady-state colour at any (x, y) at time t."""
    ang = t * 0.7
    u = x * math.cos(ang) + y * math.sin(ang)
    wave = 0.5 * math.sin(u * 0.35 - t * 1.2) + 0.5
    wave = max(0.0, min(1.0, wave))
    return lerp3(GREEN, AMBER, wave)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
python3 -m unittest test_katzensteg_banner -v
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add tools/katzensteg/katzensteg_banner.py tools/katzensteg/test_katzensteg_banner.py
git commit -m "katzensteg: add colour helpers and gradient sampler"
```

---

## Task 3: Steady-state renderer + early CLI scaffolding

Build the destination look first so it can be visually confirmed before the intro phases are layered on. Add just enough CLI to support `--once-after`.

**Files:**
- Modify: `tools/katzensteg/katzensteg_banner.py`

- [ ] **Step 1: Add terminal-size detection and centring helpers**

After the gradient sampler block, insert:

```python
# --- Layout helpers ---------------------------------------------------------


def term_width() -> int:
    return shutil.get_terminal_size(fallback=(80, 24)).columns


def centre(s: str, w: int, visible_len: int) -> str:
    pad = max(0, (w - visible_len) // 2)
    return " " * pad + s


def art_lines() -> List[str]:
    raw = [ln.rstrip() for ln in KATZENSTEG_ART.splitlines()]
    # Trim leading and trailing fully-blank lines.
    while raw and not raw[0].strip():
        raw.pop(0)
    while raw and not raw[-1].strip():
        raw.pop()
    return raw or [""]
```

- [ ] **Step 2: Add the steady-state renderer**

Insert after the layout helpers:

```python
# --- Phase: steady ---------------------------------------------------------


def render_steady(t_global: float, term_w: int, no_color: bool) -> List[str]:
    lines = art_lines()
    pulse = 0.5 + 0.5 * math.sin(t_global * 1.6)
    brightness = 0.65 + 0.35 * pulse
    out: List[str] = []
    for yi, line in enumerate(lines):
        visible = len(line)
        if no_color:
            out.append(centre(line, term_w, visible))
            continue
        parts: List[str] = []
        for xi, ch in enumerate(line):
            if ch == " ":
                parts.append(" ")
                continue
            r, g, b = sample_gradient(float(xi), float(yi), t_global)
            r = int(r * brightness)
            g = int(g * brightness)
            b = int(b * brightness)
            parts.append(BOLD + rgb_fg(r, g, b) + ch + RESET)
        out.append(centre("".join(parts), term_w, visible))

    # Underline glow row beneath the letters.
    w_letters = max(len(ln) for ln in lines)
    under_brightness = 0.35 + 0.25 * pulse
    if no_color:
        out.append(centre("─" * w_letters, term_w, w_letters))
    else:
        under_parts: List[str] = []
        for xi in range(w_letters):
            r, g, b = sample_gradient(float(xi), float(len(lines)), t_global * 0.8)
            r = int(r * under_brightness)
            g = int(g * under_brightness)
            b = int(b * under_brightness)
            under_parts.append(rgb_fg(r, g, b) + "─" + RESET)
        out.append(centre("".join(under_parts), term_w, w_letters))
    return out
```

- [ ] **Step 3: Replace `main` with a CLI that supports `--once-after`**

Replace the existing `main` body with:

```python
def parse_args(argv: List[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description="katzensteg CRT banner")
    ap.add_argument("--fps", type=float, default=30.0)
    group = ap.add_mutually_exclusive_group()
    group.add_argument(
        "--play-once",
        action="store_true",
        help="run the intro and exit on the first steady-state frame",
    )
    group.add_argument(
        "--once-after",
        type=float,
        default=None,
        metavar="SECONDS",
        help="render a single frame at t=SECONDS and exit",
    )
    ap.add_argument(
        "--no-color",
        action="store_true",
        help="disable ANSI colour (also honours NO_COLOR env)",
    )
    return ap.parse_args(argv)


def main(argv: List[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    no_color = args.no_color or bool(os.environ.get("NO_COLOR"))
    w = term_width()
    if args.once_after is not None:
        for line in render_steady(args.once_after, w, no_color):
            print(line)
        return 0
    # Looping main loop is added in Task 8.
    for line in render_steady(0.0, w, no_color):
        print(line)
    return 0
```

- [ ] **Step 4: Visual review (steady state)**

```bash
cd tools/katzensteg
python3 katzensteg_banner.py --once-after 5
```

Expected: `katzensteg` rendered in the chosen ASCII font, with each non-space character coloured somewhere on the green↔amber gradient (so the title shows a smooth horizontal/diagonal colour sweep). A coloured `─` underline row sits beneath the letters. Brightness is mid-to-high (no pulse motion since this is one frame). Confirm the title is centred in the terminal.

If the colours look wrong, the gradient is mis-tuned. If the art looks wrong, the constant from Task 1 needs reconsideration — **stop and report** rather than continuing to layer intro phases on a broken base.

- [ ] **Step 5: Run tests**

```bash
python3 -m unittest test_katzensteg_banner -v
```

Expected: all Task 2 tests still pass.

- [ ] **Step 6: Commit**

```bash
git add tools/katzensteg/katzensteg_banner.py
git commit -m "katzensteg: add steady-state renderer and once-after CLI"
```

---

## Task 4: Stabilize phase

The stabilize phase ramps brightness from low to full and engages the gradient rotation. At its end the output should be visually identical to `render_steady` at the same `t_global`.

**Files:**
- Modify: `tools/katzensteg/katzensteg_banner.py`

- [ ] **Step 1: Add the stabilize renderer**

After `render_steady`, insert:

```python
# --- Phase: stabilize ------------------------------------------------------


def render_stabilize(
    t_phase: float, t_global: float, term_w: int, no_color: bool
) -> List[str]:
    """t_phase ranges 0..(T_STABILIZE_END - T_SCAN_END). Brightness ramps
    from ~0.25 at t_phase=0 to the steady ~0.65+pulse at t_phase=end."""
    duration = T_STABILIZE_END - T_SCAN_END
    p = max(0.0, min(1.0, t_phase / duration))
    pulse = 0.5 + 0.5 * math.sin(t_global * 1.6)
    target = 0.65 + 0.35 * pulse
    brightness = lerp(0.25, target, p)
    # Gradient saturation ramps in: at p=0 colours collapse toward green;
    # at p=1 we use the full sweep.
    sat = p
    lines = art_lines()
    out: List[str] = []
    for yi, line in enumerate(lines):
        visible = len(line)
        if no_color:
            out.append(centre(line, term_w, visible))
            continue
        parts: List[str] = []
        for xi, ch in enumerate(line):
            if ch == " ":
                parts.append(" ")
                continue
            r, g, b = sample_gradient(float(xi), float(yi), t_global)
            # Desaturate toward GREEN by `1 - sat`.
            r = int(lerp(GREEN[0], r, sat) * brightness)
            g = int(lerp(GREEN[1], g, sat) * brightness)
            b = int(lerp(GREEN[2], b, sat) * brightness)
            parts.append(BOLD + rgb_fg(r, g, b) + ch + RESET)
        out.append(centre("".join(parts), term_w, visible))
    # Underline glow grows in over the phase.
    w_letters = max(len(ln) for ln in lines)
    under_brightness = lerp(0.0, 0.35 + 0.25 * pulse, p)
    if no_color:
        out.append(centre("─" * w_letters, term_w, w_letters))
    else:
        under_parts: List[str] = []
        for xi in range(w_letters):
            r, g, b = sample_gradient(float(xi), float(len(lines)), t_global * 0.8)
            r = int(lerp(GREEN[0], r, sat) * under_brightness)
            g = int(lerp(GREEN[1], g, sat) * under_brightness)
            b = int(lerp(GREEN[2], b, sat) * under_brightness)
            under_parts.append(rgb_fg(r, g, b) + "─" + RESET)
        out.append(centre("".join(under_parts), term_w, w_letters))
    return out
```

- [ ] **Step 2: Wire `--once-after` to dispatch by phase**

Replace the `if args.once_after is not None:` block in `main` with:

```python
    if args.once_after is not None:
        for line in render_at(args.once_after, w, no_color):
            print(line)
        return 0
```

And add this new function above `parse_args`:

```python
def render_at(t_global: float, term_w: int, no_color: bool) -> List[str]:
    """Dispatch to the phase active at t_global. Phase blending arrives
    in Task 7; for now the dispatch is a hard cut."""
    if t_global < T_SPARK_END:
        # Spark phase not implemented yet — fall through to scan.
        return render_stabilize(0.0, t_global, term_w, no_color)
    if t_global < T_SCAN_END:
        # Scan phase not implemented yet — fall through to stabilize.
        return render_stabilize(0.0, t_global, term_w, no_color)
    if t_global < T_STABILIZE_END:
        return render_stabilize(t_global - T_SCAN_END, t_global, term_w, no_color)
    return render_steady(t_global, term_w, no_color)
```

- [ ] **Step 3: Visual review (stabilize start, mid, end)**

Run all three:

```bash
python3 katzensteg_banner.py --once-after 0.95
python3 katzensteg_banner.py --once-after 1.25
python3 katzensteg_banner.py --once-after 1.55
```

Expected:
- `--once-after 0.95`: very dim green letters, almost no amber, no underline glow.
- `--once-after 1.25`: medium brightness, gradient half-engaged (some amber visible), faint underline.
- `--once-after 1.55`: nearly identical to steady-state at t=1.6, visible underline.

`--once-after 1.6` (steady) and `--once-after 1.59` (end of stabilize) should look almost the same — confirm there's no jarring brightness/colour jump between them.

- [ ] **Step 4: Commit**

```bash
git add tools/katzensteg/katzensteg_banner.py
git commit -m "katzensteg: add stabilize phase and phase dispatch"
```

---

## Task 5: Vertical scan phase

The vertical scan reveals the letter rows progressively. A "beam" — a row index that sweeps from the centre outward to top and bottom — controls which rows are visible. Rows above/below the beam are blank.

**Files:**
- Modify: `tools/katzensteg/katzensteg_banner.py`

- [ ] **Step 1: Add the scan renderer**

After `render_stabilize`, insert:

```python
# --- Phase: vertical scan --------------------------------------------------


def render_scan(
    t_phase: float, t_global: float, term_w: int, no_color: bool
) -> List[str]:
    """Reveals letter rows from the vertical centre outward. t_phase
    ranges 0..(T_SCAN_END - T_SPARK_END)."""
    duration = T_SCAN_END - T_SPARK_END
    p = max(0.0, min(1.0, t_phase / duration))
    lines = art_lines()
    h = len(lines)
    centre_row = (h - 1) / 2.0
    # Beam half-extent grows from 0 to (h/2 + 0.5) over the phase.
    half_extent = p * (centre_row + 0.5)
    out: List[str] = []
    for yi, line in enumerate(lines):
        visible = len(line)
        # Distance from centre row.
        d = abs(yi - centre_row)
        if d > half_extent:
            out.append(" " * visible)
            continue
        # Brightness falls off near the leading edge of the beam (gaussian-ish).
        edge = max(0.0, 1.0 - (d / max(half_extent, 0.001)))
        beam = 0.4 + 0.6 * edge
        if no_color:
            out.append(centre(line, term_w, visible))
            continue
        parts: List[str] = []
        for xi, ch in enumerate(line):
            if ch == " ":
                parts.append(" ")
                continue
            r = int(GREEN[0] * beam)
            g = int(GREEN[1] * beam)
            b = int(GREEN[2] * beam)
            parts.append(rgb_fg(r, g, b) + ch + RESET)
        out.append(centre("".join(parts), term_w, visible))
    # No underline yet during scan.
    return out
```

- [ ] **Step 2: Wire scan into the dispatcher**

In `render_at`, replace the `if t_global < T_SCAN_END` branch:

```python
    if t_global < T_SCAN_END:
        return render_scan(t_global - T_SPARK_END, t_global, term_w, no_color)
```

- [ ] **Step 3: Visual review (scan progression)**

```bash
python3 katzensteg_banner.py --once-after 0.35
python3 katzensteg_banner.py --once-after 0.55
python3 katzensteg_banner.py --once-after 0.85
```

Expected:
- `--once-after 0.35`: only the middle 1–2 letter rows visible, dim green.
- `--once-after 0.55`: about half the rows visible (middle band), still dim green, no amber.
- `--once-after 0.85`: nearly all rows visible, brighter — should flow visually into the stabilize start at 0.95.

- [ ] **Step 4: Commit**

```bash
git add tools/katzensteg/katzensteg_banner.py
git commit -m "katzensteg: add vertical scan phase"
```

---

## Task 6: Spark phase

A single bright white-green horizontal line at the vertical centre, with mild flicker. This is the moment before the scan begins.

**Files:**
- Modify: `tools/katzensteg/katzensteg_banner.py`

- [ ] **Step 1: Add the spark renderer**

After `render_scan`, insert:

```python
# --- Phase: spark ----------------------------------------------------------


def render_spark(t_phase: float, term_w: int, no_color: bool) -> List[str]:
    """Single bright horizontal line at the vertical centre of the art
    block, with a fast flicker."""
    lines = art_lines()
    h = len(lines)
    w = max(len(ln) for ln in lines)
    centre_row = h // 2
    # Flicker: brightness modulated by a fast sine plus a soft envelope.
    flicker = 0.7 + 0.3 * math.sin(t_phase * 60.0)
    envelope = max(0.0, min(1.0, t_phase / T_SPARK_END))
    brightness = flicker * (0.5 + 0.5 * envelope)
    out: List[str] = []
    for yi in range(h):
        if yi != centre_row:
            out.append(" " * w)
            continue
        if no_color:
            out.append(centre("─" * w, term_w, w))
            continue
        r = int(SPARK[0] * brightness)
        g = int(SPARK[1] * brightness)
        b = int(SPARK[2] * brightness)
        line = rgb_fg(r, g, b) + ("─" * w) + RESET
        out.append(centre(line, term_w, w))
    return out
```

- [ ] **Step 2: Wire spark into the dispatcher**

In `render_at`, replace the `if t_global < T_SPARK_END` branch:

```python
    if t_global < T_SPARK_END:
        return render_spark(t_global, term_w, no_color)
```

- [ ] **Step 3: Visual review (spark)**

```bash
python3 katzensteg_banner.py --once-after 0.05
python3 katzensteg_banner.py --once-after 0.15
python3 katzensteg_banner.py --once-after 0.25
```

Expected: only a single horizontal line visible at the vertical centre of where the title will be, in bright white-green. Brightness varies slightly between the three frames (flicker). No letters visible.

- [ ] **Step 4: Commit**

```bash
git add tools/katzensteg/katzensteg_banner.py
git commit -m "katzensteg: add spark phase"
```

---

## Task 7: Phase blending and dispatch tests

Smooth the hard cuts between phases by linearly blending each pair's outputs across a `2*BLEND` window straddling the boundary. Also add tests for the dispatch logic.

**Files:**
- Modify: `tools/katzensteg/katzensteg_banner.py`
- Modify: `tools/katzensteg/test_katzensteg_banner.py`

- [ ] **Step 1: Add a phase index helper and tests for it**

In `test_katzensteg_banner.py`, append:

```python
class TestPhaseFor(unittest.TestCase):
    def test_spark(self):
        self.assertEqual(kb.phase_for(0.0), "spark")
        self.assertEqual(kb.phase_for(0.29), "spark")

    def test_scan(self):
        self.assertEqual(kb.phase_for(0.31), "scan")
        self.assertEqual(kb.phase_for(0.89), "scan")

    def test_stabilize(self):
        self.assertEqual(kb.phase_for(0.91), "stabilize")
        self.assertEqual(kb.phase_for(1.59), "stabilize")

    def test_steady(self):
        self.assertEqual(kb.phase_for(1.61), "steady")
        self.assertEqual(kb.phase_for(120.0), "steady")
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
python3 -m unittest test_katzensteg_banner -v
```

Expected: `AttributeError: module 'katzensteg_banner' has no attribute 'phase_for'`.

- [ ] **Step 3: Add `phase_for` and a blending dispatcher**

In `katzensteg_banner.py`, replace the existing `render_at` with:

```python
def phase_for(t_global: float) -> str:
    if t_global < T_SPARK_END:
        return "spark"
    if t_global < T_SCAN_END:
        return "scan"
    if t_global < T_STABILIZE_END:
        return "stabilize"
    return "steady"


def _render_phase(name: str, t_global: float, term_w: int, no_color: bool) -> List[str]:
    if name == "spark":
        return render_spark(t_global, term_w, no_color)
    if name == "scan":
        return render_scan(t_global - T_SPARK_END, t_global, term_w, no_color)
    if name == "stabilize":
        return render_stabilize(
            t_global - T_SCAN_END, t_global, term_w, no_color
        )
    return render_steady(t_global, term_w, no_color)


def _blend_lines(a: List[str], b: List[str], t: float) -> List[str]:
    """Pick from a or b per line based on threshold t (0..1). With colour
    on, character-level interpolation requires parsing ANSI; instead we
    line-wise crossfade by simply choosing b for the first int(t*len(b))
    lines and a for the rest. Good enough for short transitions because
    the BLEND window is ~100 ms."""
    if t <= 0.0:
        return a
    if t >= 1.0:
        return b
    n = max(len(a), len(b))
    cut = int(round(t * n))
    out: List[str] = []
    for i in range(n):
        a_line = a[i] if i < len(a) else ""
        b_line = b[i] if i < len(b) else ""
        out.append(b_line if i < cut else a_line)
    return out


def render_at(t_global: float, term_w: int, no_color: bool) -> List[str]:
    name = phase_for(t_global)
    boundaries = (
        ("spark", "scan", T_SPARK_END),
        ("scan", "stabilize", T_SCAN_END),
        ("stabilize", "steady", T_STABILIZE_END),
    )
    for prev, nxt, boundary in boundaries:
        if abs(t_global - boundary) <= BLEND:
            t = (t_global - (boundary - BLEND)) / (2 * BLEND)
            a = _render_phase(prev, t_global, term_w, no_color)
            b = _render_phase(nxt, t_global, term_w, no_color)
            return _blend_lines(a, b, t)
    return _render_phase(name, t_global, term_w, no_color)
```

- [ ] **Step 4: Run tests to verify all pass**

```bash
python3 -m unittest test_katzensteg_banner -v
```

Expected: every test passes including the new `TestPhaseFor` cases.

- [ ] **Step 5: Visual review (boundary smoothness)**

Sample frames straddling each boundary:

```bash
python3 katzensteg_banner.py --once-after 0.27
python3 katzensteg_banner.py --once-after 0.30
python3 katzensteg_banner.py --once-after 0.33
python3 katzensteg_banner.py --once-after 0.87
python3 katzensteg_banner.py --once-after 0.90
python3 katzensteg_banner.py --once-after 0.93
python3 katzensteg_banner.py --once-after 1.57
python3 katzensteg_banner.py --once-after 1.60
python3 katzensteg_banner.py --once-after 1.63
```

Expected: across each triple, the visual change should be continuous — no frame should look dramatically different from its neighbours.

- [ ] **Step 6: Commit**

```bash
git add tools/katzensteg/katzensteg_banner.py tools/katzensteg/test_katzensteg_banner.py
git commit -m "katzensteg: blend phase boundaries and add dispatch tests"
```

---

## Task 8: Animated main loop, `--play-once`, and CLI tests

Replace the placeholder body of `main` with a real animation loop driven by wall-clock time, supporting indefinite looping and `--play-once`.

**Files:**
- Modify: `tools/katzensteg/katzensteg_banner.py`
- Modify: `tools/katzensteg/test_katzensteg_banner.py`

- [ ] **Step 1: Write CLI tests**

Append to `test_katzensteg_banner.py`:

```python
import io
import contextlib


class TestCli(unittest.TestCase):
    def _run(self, argv):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = kb.main(argv)
        return rc, buf.getvalue()

    def test_once_after_returns_zero_and_prints(self):
        rc, out = self._run(["--once-after", "5", "--no-color"])
        self.assertEqual(rc, 0)
        self.assertTrue(out.strip())

    def test_no_color_omits_escape_codes(self):
        _, out = self._run(["--once-after", "5", "--no-color"])
        self.assertNotIn("\x1b[", out)

    def test_once_after_with_color_emits_escape_codes(self):
        _, out = self._run(["--once-after", "5"])
        self.assertIn("\x1b[", out)
```

- [ ] **Step 2: Run tests to verify state**

```bash
python3 -m unittest test_katzensteg_banner -v
```

Expected: the `TestCli` tests pass already (since `--once-after` was wired in Task 3). If any fail, fix before continuing.

- [ ] **Step 3: Replace `main` with the animated loop**

Replace `main` with:

```python
T_INTRO_END = T_STABILIZE_END  # alias for readability


def _emit_frame(lines: List[str], use_clear: bool) -> None:
    if use_clear:
        sys.stdout.write("\x1b[H\x1b[2J")
    sys.stdout.write("\n".join(lines))
    sys.stdout.write("\n")
    sys.stdout.flush()


def main(argv: List[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    no_color = args.no_color or bool(os.environ.get("NO_COLOR"))
    w = term_width()

    if args.once_after is not None:
        _emit_frame(render_at(args.once_after, w, no_color), use_clear=False)
        return 0

    use_clear = sys.stdout.isatty()
    period = 1.0 / max(args.fps, 1.0)
    t0 = time.time()
    try:
        while True:
            t = time.time() - t0
            _emit_frame(render_at(t, w, no_color), use_clear=use_clear)
            if args.play_once and t >= T_INTRO_END:
                return 0
            time.sleep(period)
    except KeyboardInterrupt:
        sys.stdout.write(RESET + "\n")
        return 0
```

- [ ] **Step 4: Run all tests**

```bash
python3 -m unittest test_katzensteg_banner -v
```

Expected: all tests pass (existing tests should be unaffected by the loop change since `--once-after` short-circuits before the loop).

- [ ] **Step 5: Visual review (full animation)**

```bash
python3 katzensteg_banner.py
```

Expected: spark line appears, expands vertically into letter rows, brightness ramps and gradient engages, then loops in steady state with a slow rotating green↔amber sweep + gentle pulse. Press Ctrl-C; terminal returns to a clean prompt with no leftover colour bleed.

Then:

```bash
python3 katzensteg_banner.py --play-once
```

Expected: same intro plays once, exits on its own at ~1.6 s, leaving the final steady frame visible above the prompt.

- [ ] **Step 6: Commit**

```bash
git add tools/katzensteg/katzensteg_banner.py tools/katzensteg/test_katzensteg_banner.py
git commit -m "katzensteg: animated main loop and play-once mode"
```

---

## Task 9: Final review and tidy-up

Sanity-check the prototype end-to-end and remove any leftover scaffolding before declaring it done.

**Files:**
- Modify (if needed): `tools/katzensteg/katzensteg_banner.py`

- [ ] **Step 1: Re-read the file top-to-bottom**

Open `tools/katzensteg/katzensteg_banner.py` and confirm:
- The module docstring at the top still reflects what the file does.
- There are no lingering comments referring to "Task N" or "Step N".
- The order of declarations is: constants → ANSI/colour helpers → gradient sampler → layout helpers → phase renderers (spark, scan, stabilize, steady) → dispatcher (`phase_for`, `render_at`, `_render_phase`, `_blend_lines`) → CLI (`parse_args`, `_emit_frame`, `main`).
- No unused imports.

If anything is out of place, move it. If a comment is stale, delete it.

- [ ] **Step 2: Final visual sweep**

```bash
cd tools/katzensteg
python3 katzensteg_banner.py
# Watch one full cycle including ~5 s of steady state, then Ctrl-C.
python3 katzensteg_banner.py --play-once
NO_COLOR=1 python3 katzensteg_banner.py --once-after 2
```

Expected: looping run looks polished and matches the design (CRT power-on into glowing rotating-gradient steady state). `--play-once` exits cleanly. `NO_COLOR=1` produces a clean plain-text frame with no escape codes.

- [ ] **Step 3: Run all tests**

```bash
python3 -m unittest test_katzensteg_banner -v
```

Expected: every test passes.

- [ ] **Step 4: Commit (if any tidy-up)**

If Step 1 produced changes:

```bash
git add tools/katzensteg/katzensteg_banner.py
git commit -m "katzensteg: tidy banner prototype"
```

If no changes were needed, skip the commit.

- [ ] **Step 5: Hand off**

Report to the user that the prototype is ready and ask whether to iterate on the visual look (e.g. swap the figlet font in `KATZENSTEG_ART`, retune `T_*` timings, adjust palette) or move on to planning the Zig port.
