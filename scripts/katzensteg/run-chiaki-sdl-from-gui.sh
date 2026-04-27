#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
CHIAKI_GUI_SCRIPT="${CHIAKI_GUI_SCRIPT:-$HOME/dev/chiaki-ng/scripts/run-chiaki-sdl-from-gui.py}"
CHIAKI_SDL_BIN="${CHIAKI_SDL_BIN:-$HOME/dev/chiaki-ng/build-sdl/sdl/chiaki-sdl}"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/chiaki-katzensteg.out}"

build_katzensteg_env() {
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

  if [[ -n "${KATZENSTEG_COMPOSITE_DEBUG:-}" ]]; then
    env_args+=(KATZENSTEG_COMPOSITE_DEBUG="$KATZENSTEG_COMPOSITE_DEBUG")
  fi
  if [[ -n "${KATZENSTEG_TRACE_SDL:-}" ]]; then
    env_args+=(KATZENSTEG_TRACE_SDL="$KATZENSTEG_TRACE_SDL")
  fi
  if [[ -n "${KATZENSTEG_STATS:-}" ]]; then
    env_args+=(KATZENSTEG_STATS="$KATZENSTEG_STATS")
  fi
  if [[ "${KATZENSTEG_DYLD_PRINT_LIBRARIES:-}" == "1" ]]; then
    env_args+=(DYLD_PRINT_LIBRARIES=1)
  fi
}

if [[ "${KATZENSTEG_CHIAKI_SDL_PROXY:-}" == "1" ]]; then
  if [[ ! -x "$CHIAKI_SDL_BIN" ]]; then
    echo "chiaki-sdl binary not found or not executable: $CHIAKI_SDL_BIN" >&2
    echo "Set CHIAKI_SDL_BIN=/path/to/chiaki-sdl if needed." >&2
    exit 1
  fi
  if [[ ! -f "$KATZENSTEG_LIB" ]]; then
    echo "Katzensteg dylib not found: $KATZENSTEG_LIB" >&2
    echo "Build Katzensteg first: zig build" >&2
    exit 1
  fi

  build_katzensteg_env
  exec env "${env_args[@]}" "$CHIAKI_SDL_BIN" "$@"
fi

if [[ ! -x "$CHIAKI_GUI_SCRIPT" ]]; then
  echo "Chiaki GUI launcher not found or not executable: $CHIAKI_GUI_SCRIPT" >&2
  echo "Set CHIAKI_GUI_SCRIPT=/path/to/run-chiaki-sdl-from-gui.py if needed." >&2
  exit 1
fi
if [[ ! -x "$CHIAKI_SDL_BIN" ]]; then
  echo "chiaki-sdl binary not found or not executable: $CHIAKI_SDL_BIN" >&2
  echo "Build chiaki-ng SDL first, or set CHIAKI_SDL_BIN=/path/to/chiaki-sdl." >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_LIB" ]]; then
  echo "Katzensteg dylib not found: $KATZENSTEG_LIB" >&2
  echo "Build Katzensteg first: zig build" >&2
  exit 1
fi

rm -f "$OUTPUT_LOG" /tmp/katzensteg-*.log /tmp/katzensteg-composite.ppm

build_katzensteg_env

echo "Running chiaki-sdl from Chiaki GUI settings with Katzensteg"
echo "  CHIAKI_GUI_SCRIPT=$CHIAKI_GUI_SCRIPT"
echo "  CHIAKI_SDL_BIN=$CHIAKI_SDL_BIN"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  $preload_name=$KATZENSTEG_LIB"
echo "  KATZENSTEG_INTERCEPT_MODE=${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
echo "  KATZENSTEG_COMPOSITE_MODE=${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
echo "  KATZENSTEG_OUTPUT_PROFILE=${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
echo "  SDL_RENDER_DRIVER=${SDL_RENDER_DRIVER:-software}"
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
if [[ "${KATZENSTEG_DYLD_PRINT_LIBRARIES:-}" == "1" ]]; then
  echo "  KATZENSTEG_DYLD_PRINT_LIBRARIES=1"
fi

exec env \
  KATZENSTEG_CHIAKI_SDL_PROXY=1 \
  CHIAKI_SDL_BIN="$CHIAKI_SDL_BIN" \
  "$CHIAKI_GUI_SCRIPT" "$@" --sdl-binary "$SELF" > "$OUTPUT_LOG" 2>&1
