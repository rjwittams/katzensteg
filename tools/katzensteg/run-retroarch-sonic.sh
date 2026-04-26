#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RETROARCH_BIN="${RETROARCH_BIN:-$HOME/dev/RetroArch/retroarch}"
CORE_PATH="${CORE_PATH:-$HOME/Library/Application Support/RetroArch/cores/genesis_plus_gx_libretro.dylib}"
CONFIG_PATH="${CONFIG_PATH:-/tmp/retroarch-sdl2.cfg}"
ROM_PATH="${ROM_PATH:-$HOME/roms/Sonic The Hedgehog (USA, Europe).md}"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/retro-sonic.out}"

is_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

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

rm -f "$OUTPUT_LOG" /tmp/katzensteg-*.log /tmp/katzensteg-composite.ppm
if [[ -n "${KATZENSTEG_INSPECT_SOCKET:-}" ]]; then
  rm -f "$KATZENSTEG_INSPECT_SOCKET"
fi

env_args=(
  -u KATZENSTEG_COMPOSITE_DEBUG
  -u KATZENSTEG_TRACE_SDL
  -u KATZENSTEG_STATS
  -u KATZENSTEG_INSPECT_SOCKET
  KATZENSTEG_INTERCEPT_MODE="${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
  KATZENSTEG_COMPOSITE_MODE="${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
  KATZENSTEG_OUTPUT_PROFILE="${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
  SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-software}"
  DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB"
)

if is_enabled "${KATZENSTEG_COMPOSITE_DEBUG:-}"; then
  env_args+=(KATZENSTEG_COMPOSITE_DEBUG=1)
fi
if is_enabled "${KATZENSTEG_TRACE_SDL:-}"; then
  env_args+=(KATZENSTEG_TRACE_SDL=1)
fi
if is_enabled "${KATZENSTEG_STATS:-}"; then
  env_args+=(KATZENSTEG_STATS=1)
fi
if [[ -n "${KATZENSTEG_INSPECT_SOCKET:-}" ]]; then
  env_args+=(KATZENSTEG_INSPECT_SOCKET="$KATZENSTEG_INSPECT_SOCKET")
fi

retroarch_args=(
  -L "$CORE_PATH"
  -c "$CONFIG_PATH"
  "$ROM_PATH"
)
if is_enabled "${RETROARCH_VERBOSE:-}"; then
  retroarch_args=(--verbose "${retroarch_args[@]}")
fi

echo "Running RetroArch + Genesis Plus GX + Sonic with Katzensteg"
echo "  RETROARCH_BIN=$RETROARCH_BIN"
echo "  CORE_PATH=$CORE_PATH"
echo "  CONFIG_PATH=$CONFIG_PATH"
echo "  ROM_PATH=$ROM_PATH"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  KATZENSTEG_INTERCEPT_MODE=${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
echo "  KATZENSTEG_COMPOSITE_MODE=${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
echo "  KATZENSTEG_OUTPUT_PROFILE=${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
echo "  SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}"
echo "  OUTPUT_LOG=$OUTPUT_LOG"
if is_enabled "${KATZENSTEG_COMPOSITE_DEBUG:-}"; then
  echo "  KATZENSTEG_COMPOSITE_DEBUG=1"
fi
if is_enabled "${KATZENSTEG_TRACE_SDL:-}"; then
  echo "  KATZENSTEG_TRACE_SDL=1"
fi
if is_enabled "${KATZENSTEG_STATS:-}"; then
  echo "  KATZENSTEG_STATS=1"
fi
if [[ -n "${KATZENSTEG_INSPECT_SOCKET:-}" ]]; then
  echo "  KATZENSTEG_INSPECT_SOCKET=$KATZENSTEG_INSPECT_SOCKET"
fi
if is_enabled "${RETROARCH_VERBOSE:-}"; then
  echo "  RETROARCH_VERBOSE=1"
fi

exec env "${env_args[@]}" "$RETROARCH_BIN" "${retroarch_args[@]}" > "$OUTPUT_LOG" 2>&1
