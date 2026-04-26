#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FFPLAY_BIN="${FFPLAY_BIN:-ffplay}"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/ffplay-katzensteg.out}"

if ! command -v "$FFPLAY_BIN" >/dev/null 2>&1; then
  echo "ffplay binary not found: $FFPLAY_BIN" >&2
  echo "Install ffmpeg/ffplay, or set FFPLAY_BIN=/path/to/ffplay." >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_LIB" ]]; then
  echo "Katzensteg dylib not found: $KATZENSTEG_LIB" >&2
  echo "Build ttytris first: zig build" >&2
  exit 1
fi

rm -f "$OUTPUT_LOG" /tmp/katzensteg-*.log /tmp/katzensteg-composite.ppm
if [[ -n "${KATZENSTEG_INSPECT_SOCKET:-}" ]]; then
  rm -f "$KATZENSTEG_INSPECT_SOCKET"
fi

if [[ $# -gt 0 ]]; then
  ffplay_args=("$@")
else
  ffplay_args=(
    -f lavfi
    -i "${FFPLAY_TEST_SOURCE:-testsrc2=size=640x360:rate=60}"
  )
fi

env_args=(
  KATZENSTEG_INTERCEPT_MODE="${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
  KATZENSTEG_COMPOSITE_MODE="${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
  KATZENSTEG_OUTPUT_PROFILE="${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
  SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-software}"
)

case "$(uname -s)" in
  Darwin)
    env_args+=(DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB")
    preload_name=DYLD_INSERT_LIBRARIES
    ;;
  *)
    env_args+=(LD_PRELOAD="$KATZENSTEG_LIB")
    preload_name=LD_PRELOAD
    ;;
esac

if [[ -n "${KATZENSTEG_INSPECT_SOCKET:-}" ]]; then
  env_args+=(KATZENSTEG_INSPECT_SOCKET="$KATZENSTEG_INSPECT_SOCKET")
fi
if [[ -n "${KATZENSTEG_COMPOSITE_DEBUG:-}" ]]; then
  env_args+=(KATZENSTEG_COMPOSITE_DEBUG="$KATZENSTEG_COMPOSITE_DEBUG")
fi
if [[ -n "${KATZENSTEG_TRACE_SDL:-}" ]]; then
  env_args+=(KATZENSTEG_TRACE_SDL="$KATZENSTEG_TRACE_SDL")
fi
if [[ -n "${KATZENSTEG_STATS:-}" ]]; then
  env_args+=(KATZENSTEG_STATS="$KATZENSTEG_STATS")
fi

echo "Running ffplay test source with Katzensteg"
echo "  FFPLAY_BIN=$FFPLAY_BIN"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  $preload_name=$KATZENSTEG_LIB"
echo "  KATZENSTEG_INTERCEPT_MODE=${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
echo "  KATZENSTEG_COMPOSITE_MODE=${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
echo "  KATZENSTEG_OUTPUT_PROFILE=${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
echo "  SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}"
echo "  OUTPUT_LOG=$OUTPUT_LOG"
if [[ -n "${KATZENSTEG_INSPECT_SOCKET:-}" ]]; then
  echo "  KATZENSTEG_INSPECT_SOCKET=$KATZENSTEG_INSPECT_SOCKET"
fi
if [[ -n "${KATZENSTEG_COMPOSITE_DEBUG:-}" ]]; then
  echo "  KATZENSTEG_COMPOSITE_DEBUG=$KATZENSTEG_COMPOSITE_DEBUG"
fi
if [[ -n "${KATZENSTEG_TRACE_SDL:-}" ]]; then
  echo "  KATZENSTEG_TRACE_SDL=$KATZENSTEG_TRACE_SDL"
fi
if [[ -n "${KATZENSTEG_STATS:-}" ]]; then
  echo "  KATZENSTEG_STATS=$KATZENSTEG_STATS"
fi

exec env "${env_args[@]}" "$FFPLAY_BIN" "${ffplay_args[@]}" > "$OUTPUT_LOG" 2>&1
