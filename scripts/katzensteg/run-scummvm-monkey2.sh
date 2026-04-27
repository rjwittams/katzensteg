#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCUMMVM_BIN="${SCUMMVM_BIN:-/opt/homebrew/bin/scummvm}"
SCUMMVM_GAME_ID="${SCUMMVM_GAME_ID:-monkey2}"
SCUMMVM_GAME_PATH="${SCUMMVM_GAME_PATH:-$HOME/roms/mi2}"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"

if [[ ! -x "$SCUMMVM_BIN" ]]; then
  echo "ScummVM binary not found or not executable: $SCUMMVM_BIN" >&2
  echo "Set SCUMMVM_BIN=/path/to/scummvm if needed." >&2
  exit 1
fi
if [[ ! -d "$SCUMMVM_GAME_PATH" ]]; then
  echo "ScummVM game path not found: $SCUMMVM_GAME_PATH" >&2
  echo "Set SCUMMVM_GAME_PATH=/path/to/monkey2-data if needed." >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_LIB" ]]; then
  echo "Katzensteg dylib not found: $KATZENSTEG_LIB" >&2
  echo "Build Katzensteg first: zig build -Doptimize=ReleaseFast" >&2
  exit 1
fi


echo "Running ScummVM + Monkey Island 2 with Katzensteg"
echo "  SCUMMVM_BIN=$SCUMMVM_BIN"
echo "  SCUMMVM_GAME_ID=$SCUMMVM_GAME_ID"
echo "  SCUMMVM_GAME_PATH=$SCUMMVM_GAME_PATH"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  KATZENSTEG_INTERCEPT_MODE=${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
echo "  KATZENSTEG_COMPOSITE_MODE=${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
echo "  KATZENSTEG_OUTPUT_PROFILE=${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
echo "  KATZENSTEG_COMPOSITE_DEBUG=${KATZENSTEG_COMPOSITE_DEBUG:-1}"
echo "  KATZENSTEG_TRACE_SDL=${KATZENSTEG_TRACE_SDL:-1}"
echo "  SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}"
echo "  SCUMMVM_GFX_MODE=${SCUMMVM_GFX_MODE:-surfacesdl}"
echo "  SCUMMVM_RENDERER=${SCUMMVM_RENDERER:-software}"
echo "  output=/tmp/scummvm.out"

SCUMMVM_ARGS=(
  --no-fullscreen
  --gfx-mode="${SCUMMVM_GFX_MODE:-surfacesdl}"
  --renderer="${SCUMMVM_RENDERER:-software}"
  --path="$SCUMMVM_GAME_PATH"
  "$SCUMMVM_GAME_ID"
)

exec env \
  KATZENSTEG_COMPOSITE_DEBUG="${KATZENSTEG_COMPOSITE_DEBUG:-1}" \
  KATZENSTEG_INTERCEPT_MODE="${KATZENSTEG_INTERCEPT_MODE:-queued_replay}" \
  KATZENSTEG_COMPOSITE_MODE="${KATZENSTEG_COMPOSITE_MODE:-fullscreen}" \
  KATZENSTEG_OUTPUT_PROFILE="${KATZENSTEG_OUTPUT_PROFILE:-file_whole}" \
  KATZENSTEG_TRACE_SDL="${KATZENSTEG_TRACE_SDL:-1}" \
  SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-software}" \
  DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB" \
  "$SCUMMVM_BIN" "${SCUMMVM_ARGS[@]}" \
    "$@" \
    > /tmp/scummvm.out 2>&1
