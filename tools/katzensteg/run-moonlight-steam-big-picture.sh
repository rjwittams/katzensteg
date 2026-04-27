#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MOONLIGHT_BIN="${MOONLIGHT_BIN:-$HOME/dev/moonlight-qt/app/Moonlight.app/Contents/MacOS/Moonlight}"
MOONLIGHT_HOST="${MOONLIGHT_HOST:-feta}"
MOONLIGHT_APP="${MOONLIGHT_APP:-Steam Big Picture}"
MOONLIGHT_VIDEO_DECODER="${MOONLIGHT_VIDEO_DECODER:-hardware}"
MOONLIGHT_VIDEO_CODEC="${MOONLIGHT_VIDEO_CODEC:-HEVC}"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/moonlight-katzensteg.out}"

if [[ ! -x "$MOONLIGHT_BIN" ]]; then
  echo "Moonlight binary not found or not executable: $MOONLIGHT_BIN" >&2
  echo "Build Moonlight first, or set MOONLIGHT_BIN=/path/to/Moonlight." >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_LIB" ]]; then
  echo "Katzensteg dylib not found: $KATZENSTEG_LIB" >&2
  echo "Build ttytris first: zig build -Doptimize=ReleaseFast" >&2
  exit 1
fi

rm -f "$OUTPUT_LOG" /tmp/katzensteg-*.log /tmp/katzensteg-composite.ppm

moonlight_args=(
  stream "$MOONLIGHT_HOST" "$MOONLIGHT_APP"
  --display-mode windowed
  --absolute-mouse
  --capture-system-keys never
  --video-decoder "$MOONLIGHT_VIDEO_DECODER"
  --video-codec "$MOONLIGHT_VIDEO_CODEC"
  --no-hdr
)

env_args=(
  KATZENSTEG_INTERCEPT_MODE="${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
  KATZENSTEG_COMPOSITE_MODE="${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
  KATZENSTEG_OUTPUT_PROFILE="${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
  SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-software}"
  VT_FORCE_METAL="${VT_FORCE_METAL:-0}"
  VT_FORCE_INDIRECT="${VT_FORCE_INDIRECT:-1}"
  DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB"
)
if [[ -n "${KATZENSTEG_COMPOSITE_DEBUG:-}" ]]; then
  env_args+=(KATZENSTEG_COMPOSITE_DEBUG="$KATZENSTEG_COMPOSITE_DEBUG")
fi
if [[ -n "${KATZENSTEG_TRACE_SDL:-}" ]]; then
  env_args+=(KATZENSTEG_TRACE_SDL="$KATZENSTEG_TRACE_SDL")
fi
if [[ -n "${KATZENSTEG_STATS:-}" ]]; then
  env_args+=(KATZENSTEG_STATS="$KATZENSTEG_STATS")
fi

echo "Running Moonlight + Steam Big Picture with Katzensteg"
echo "  MOONLIGHT_BIN=$MOONLIGHT_BIN"
echo "  MOONLIGHT_HOST=$MOONLIGHT_HOST"
echo "  MOONLIGHT_APP=$MOONLIGHT_APP"
echo "  MOONLIGHT_VIDEO_DECODER=$MOONLIGHT_VIDEO_DECODER"
echo "  MOONLIGHT_VIDEO_CODEC=$MOONLIGHT_VIDEO_CODEC"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  KATZENSTEG_INTERCEPT_MODE=${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
echo "  KATZENSTEG_COMPOSITE_MODE=${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
echo "  KATZENSTEG_OUTPUT_PROFILE=${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
echo "  SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}"
echo "  VT_FORCE_METAL=${VT_FORCE_METAL:-0}"
echo "  VT_FORCE_INDIRECT=${VT_FORCE_INDIRECT:-1}"
echo "  OUTPUT_LOG=$OUTPUT_LOG"
if [[ -n "${KATZENSTEG_COMPOSITE_DEBUG:-}" ]]; then
  echo "  KATZENSTEG_COMPOSITE_DEBUG=$KATZENSTEG_COMPOSITE_DEBUG"
fi
if [[ -n "${KATZENSTEG_TRACE_SDL:-}" ]]; then
  echo "  KATZENSTEG_TRACE_SDL=$KATZENSTEG_TRACE_SDL"
fi
if [[ -n "${KATZENSTEG_STATS:-}" ]]; then
  echo "  KATZENSTEG_STATS=$KATZENSTEG_STATS"
fi

exec env "${env_args[@]}" "$MOONLIGHT_BIN" "${moonlight_args[@]}" "$@" > "$OUTPUT_LOG" 2>&1
