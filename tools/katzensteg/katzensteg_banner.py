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

KATZENSTEG_ART = r""" _         _                     _
| |       | |                   | |
| | ____ _| |_ _______ _ __  ___| |_ ___  __ _
| |/ / _` | __|_  / _ \ '_ \/ __| __/ _ \/ _` |
|   < (_| | |_ / /  __/ | | \__ \ ||  __/ (_| |
|_|\_\__,_|\__/___\___|_| |_|___/\__\___|\__, |
                                          __/ |
                                         |___/"""

GREEN = (34, 255, 100)
AMBER = (255, 200, 60)
SPARK = (200, 255, 220)  # bright white-green for the initial scan line

# Phase boundaries (seconds, global time)
T_SPARK_END = 0.3
T_SCAN_END = 0.9
T_STABILIZE_END = 1.6
T_INTRO_END = T_STABILIZE_END
# Boundary blend half-width: each transition crossfades over 2*BLEND seconds.
BLEND = 0.05


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
    """Rotating diagonal sweep between GREEN and AMBER."""
    ang = t * 0.7
    u = x * math.cos(ang) + y * math.sin(ang)
    wave = 0.5 * math.sin(u * 0.35 - t * 1.2) + 0.5
    wave = max(0.0, min(1.0, wave))
    return lerp3(GREEN, AMBER, wave)


# --- Layout helpers ---------------------------------------------------------


def term_width() -> int:
    return shutil.get_terminal_size(fallback=(80, 24)).columns


def centre(s: str, w: int, visible_len: int) -> str:
    pad = max(0, (w - visible_len) // 2)
    return " " * pad + s


def art_lines() -> List[str]:
    raw = [ln.rstrip() for ln in KATZENSTEG_ART.splitlines()]
    while raw and not raw[0].strip():
        raw.pop(0)
    while raw and not raw[-1].strip():
        raw.pop()
    return raw or [""]


# --- Phase: spark ----------------------------------------------------------


def render_spark(t_phase: float, term_w: int, no_color: bool) -> List[str]:
    """Single bright horizontal line at the vertical centre of the art
    block, with a fast flicker."""
    lines = art_lines()
    h = len(lines)
    w = max(len(ln) for ln in lines)
    centre_row = h // 2
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
    w_letters = max(len(ln) for ln in lines)
    centre_row = (h - 1) / 2.0
    half_extent = p * (centre_row + 0.5)
    out: List[str] = []
    for yi, line in enumerate(lines):
        d = abs(yi - centre_row)
        if d > half_extent:
            out.append(centre("", term_w, w_letters))
            continue
        edge = max(0.0, 1.0 - (d / max(half_extent, 0.001)))
        beam = 0.4 + 0.6 * edge
        if no_color:
            out.append(centre(line, term_w, w_letters))
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
        out.append(centre("".join(parts), term_w, w_letters))
    return out


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
    sat = p
    lines = art_lines()
    w_letters = max(len(ln) for ln in lines)
    out: List[str] = []
    for yi, line in enumerate(lines):
        if no_color:
            out.append(centre(line, term_w, w_letters))
            continue
        parts: List[str] = []
        for xi, ch in enumerate(line):
            if ch == " ":
                parts.append(" ")
                continue
            r, g, b = sample_gradient(float(xi), float(yi), t_global)
            r = int(lerp(GREEN[0], r, sat) * brightness)
            g = int(lerp(GREEN[1], g, sat) * brightness)
            b = int(lerp(GREEN[2], b, sat) * brightness)
            parts.append(BOLD + rgb_fg(r, g, b) + ch + RESET)
        out.append(centre("".join(parts), term_w, w_letters))
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


# --- Phase: steady ---------------------------------------------------------


def render_steady(t_global: float, term_w: int, no_color: bool) -> List[str]:
    lines = art_lines()
    w_letters = max(len(ln) for ln in lines)
    pulse = 0.5 + 0.5 * math.sin(t_global * 1.6)
    brightness = 0.65 + 0.35 * pulse
    out: List[str] = []
    for yi, line in enumerate(lines):
        if no_color:
            out.append(centre(line, term_w, w_letters))
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
        out.append(centre("".join(parts), term_w, w_letters))

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


# --- Dispatcher ------------------------------------------------------------


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
    """Line-wise crossfade from a to b. Character-level blending would
    require parsing ANSI; line-wise is fine because BLEND ≈ 100 ms."""
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


# --- Entrypoint --------------------------------------------------------------


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


if __name__ == "__main__":
    raise SystemExit(main())
