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

KATZENSTEG_ART = r""" __           __                            __
|  |--.---.-.|  |_.-----.-----.-----.-----.|  |_.-----.-----.
|    <|  _  ||   _|-- __|  -__|     |__ --||   _|  -__|  _  |
|__|__|___._||____|_____|_____|__|__|_____||____|_____|___  |
                                                      |_____|"""

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
    for line in KATZENSTEG_ART.splitlines():
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
