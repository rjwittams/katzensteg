#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RETROARCH_BIN="${RETROARCH_BIN:-$HOME/dev/RetroArch/retroarch}"
CORE_PATH="${CORE_PATH:-$HOME/Library/Application Support/RetroArch/cores/bsnes_libretro.dylib}"
CONFIG_PATH="${CONFIG_PATH:-/tmp/retroarch-sdl2.cfg}"
ROM_PATH="${ROM_PATH:-$HOME/roms/smw.smc}"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"

if [[ ! -x "$RETROARCH_BIN" ]]; then
  echo "RetroArch binary not found or not executable: $RETROARCH_BIN" >&2
  exit 1
fi
if [[ ! -f "$CORE_PATH" ]]; then
  echo "RetroArch core not found: $CORE_PATH" >&2
  exit 1
fi
if [[ ! -f "$ROM_PATH" ]]; then
  echo "ROM not found: $ROM_PATH" >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_LIB" ]]; then
  echo "Katzensteg dylib not found: $KATZENSTEG_LIB" >&2
  exit 1
fi


echo "Running RetroArch + bsnes + SMW with Katzensteg"
echo "  RETROARCH_BIN=$RETROARCH_BIN"
echo "  CORE_PATH=$CORE_PATH"
echo "  CONFIG_PATH=$CONFIG_PATH"
echo "  ROM_PATH=$ROM_PATH"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  KATZENSTEG_INTERCEPT_MODE=${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
echo "  KATZENSTEG_COMPOSITE_MODE=${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
echo "  KATZENSTEG_OUTPUT_PROFILE=${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
echo "  SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}"

exec env \
  KATZENSTEG_COMPOSITE_DEBUG=1 \
  KATZENSTEG_INTERCEPT_MODE="${KATZENSTEG_INTERCEPT_MODE:-queued_replay}" \
  KATZENSTEG_COMPOSITE_MODE="${KATZENSTEG_COMPOSITE_MODE:-fullscreen}" \
  KATZENSTEG_OUTPUT_PROFILE="${KATZENSTEG_OUTPUT_PROFILE:-file_whole}" \
  SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-software}" \
  DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB" \
  "$RETROARCH_BIN" \
    -L "$CORE_PATH" \
    --verbose \
    -c "$CONFIG_PATH" \
    "$ROM_PATH" \
    > /tmp/retro.out 2>&1
