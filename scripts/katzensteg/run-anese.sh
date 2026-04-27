#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"
ANESE_BIN="${ANESE_BIN:-$HOME/dev/ANESE/build/anese}"
DEFAULT_ROM="$HOME/dev/ANESE/roms/tests/cpu/instr_misc/rom_singles/01-abs_x_wrap.nes"
ROM_PATH="${1:-$DEFAULT_ROM}"

if [[ ! -x "$ANESE_BIN" ]]; then
  echo "ANESE binary not found: $ANESE_BIN" >&2
  echo "Build it first in ~/dev/ANESE/build, or set ANESE_BIN=/path/to/anese" >&2
  exit 1
fi

if [[ ! -f "$KATZENSTEG_LIB" ]]; then
  echo "Katzensteg dylib not found: $KATZENSTEG_LIB" >&2
  echo "Build Katzensteg first: zig build" >&2
  exit 1
fi

if [[ ! -f "$ROM_PATH" ]]; then
  echo "ROM not found: $ROM_PATH" >&2
  exit 1
fi

rm -f /tmp/katzensteg-*.log

echo "Running ANESE under Katzensteg"
echo "  ANESE_BIN=$ANESE_BIN"
echo "  ROM_PATH=$ROM_PATH"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  KATZENSTEG_STATS=${KATZENSTEG_STATS:-1}"
echo

script -q /dev/null \
  env \
  KATZENSTEG_STATS="${KATZENSTEG_STATS:-1}" \
  DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB" \
  "$ANESE_BIN" "$ROM_PATH"

echo
echo "Latest Katzensteg log:"
ls -1t /tmp/katzensteg-*.log 2>/dev/null | head -n 1 || true
