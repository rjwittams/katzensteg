#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RETROARCH_BIN="${RETROARCH_BIN:-$HOME/dev/RetroArch/RetroArch.app/Contents/MacOS/RetroArch}"
CORE_PATH="${CORE_PATH:-$HOME/Library/Application Support/RetroArch/cores/flycast_libretro.dylib}"
ROM_PATH="${ROM_PATH:-$HOME/roms/JGR/Jet Grind Radio (USA).cue}"
BASE_CONFIG_PATH="${BASE_CONFIG_PATH:-/tmp/retroarch-sdl2.cfg}"
CONFIG_PATH="${CONFIG_PATH:-/tmp/retroarch-sdl2-vulkan.cfg}"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"
KATZENSTEG_VULKAN_LAYER="${KATZENSTEG_VULKAN_LAYER:-$ROOT/zig-out/lib/libkatzensteg-vulkan-layer.dylib}"
KATZENSTEG_VULKAN_LOADER="${KATZENSTEG_VULKAN_LOADER:-/opt/homebrew/lib/libvulkan.1.dylib}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/retro-vulkan.out}"

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
if [[ ! -f "$KATZENSTEG_VULKAN_LAYER" ]]; then
  echo "Katzensteg Vulkan layer not found: $KATZENSTEG_VULKAN_LAYER" >&2
  echo "Run: zig build" >&2
  exit 1
fi
if [[ -n "$KATZENSTEG_VULKAN_LOADER" && ! -f "$KATZENSTEG_VULKAN_LOADER" ]]; then
  echo "Katzensteg Vulkan loader override not found: $KATZENSTEG_VULKAN_LOADER" >&2
  exit 1
fi

if [[ -f "$BASE_CONFIG_PATH" ]]; then
  cp "$BASE_CONFIG_PATH" "$CONFIG_PATH"
else
  : > "$CONFIG_PATH"
fi
cat >> "$CONFIG_PATH" <<'CFG'
video_driver = "vulkan"
video_context_driver = "sdl_vk"
input_driver = "sdl2"
joypad_driver = "sdl2"
CFG

rm -f "$OUTPUT_LOG" /tmp/katzensteg-*.log /tmp/katzensteg-composite.ppm

env_args=(
  -u KATZENSTEG_COMPOSITE_DEBUG
  -u KATZENSTEG_TRACE_SDL
  -u KATZENSTEG_TRACE_VULKAN
  -u KATZENSTEG_STATS
  KATZENSTEG_INTERCEPT_MODE="${KATZENSTEG_INTERCEPT_MODE:-queued_replay}"
  KATZENSTEG_COMPOSITE_MODE="${KATZENSTEG_COMPOSITE_MODE:-fullscreen}"
  KATZENSTEG_OUTPUT_PROFILE="${KATZENSTEG_OUTPUT_PROFILE:-file_whole}"
  KATZENSTEG_VULKAN_CAPTURE="${KATZENSTEG_VULKAN_CAPTURE:-1}"
  KATZENSTEG_VULKAN_LOADER="$KATZENSTEG_VULKAN_LOADER"
  KATZENSTEG_INPUT="${KATZENSTEG_INPUT:-1}"
  KATZENSTEG_INPUT_CLAIM="${KATZENSTEG_INPUT_CLAIM:-1}"
  VK_LAYER_PATH="$ROOT/profiles"
  VK_INSTANCE_LAYERS=VK_LAYER_KATZENSTEG_capture
  RETROARCH_COCOA_BOOTSTRAP_WINDOW=0
  DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB"
)

if is_enabled "${KATZENSTEG_COMPOSITE_DEBUG:-}"; then
  env_args+=(KATZENSTEG_COMPOSITE_DEBUG=1)
fi
if is_enabled "${KATZENSTEG_TRACE_SDL:-}"; then
  env_args+=(KATZENSTEG_TRACE_SDL=1)
fi
if is_enabled "${KATZENSTEG_TRACE_VULKAN:-}"; then
  env_args+=(KATZENSTEG_TRACE_VULKAN=1)
fi
if is_enabled "${KATZENSTEG_STATS:-}"; then
  env_args+=(KATZENSTEG_STATS=1)
fi
if [[ -n "${KATZENSTEG_REAL_WINDOW:-}" ]]; then
  env_args+=(KATZENSTEG_REAL_WINDOW="$KATZENSTEG_REAL_WINDOW")
fi

retroarch_args=(
  -L "$CORE_PATH"
  -c "$CONFIG_PATH"
  "$ROM_PATH"
)
if is_enabled "${RETROARCH_VERBOSE:-}"; then
  retroarch_args=(--verbose "${retroarch_args[@]}")
fi

echo "Running RetroArch Vulkan with Katzensteg"
echo "  RETROARCH_BIN=$RETROARCH_BIN"
echo "  CORE_PATH=$CORE_PATH"
echo "  ROM_PATH=$ROM_PATH"
echo "  CONFIG_PATH=$CONFIG_PATH"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  KATZENSTEG_VULKAN_LAYER=$KATZENSTEG_VULKAN_LAYER"
echo "  KATZENSTEG_VULKAN_CAPTURE=${KATZENSTEG_VULKAN_CAPTURE:-1}"
echo "  KATZENSTEG_VULKAN_LOADER=$KATZENSTEG_VULKAN_LOADER"
echo "  OUTPUT_LOG=$OUTPUT_LOG"
if is_enabled "${KATZENSTEG_TRACE_VULKAN:-}"; then
  echo "  KATZENSTEG_TRACE_VULKAN=1"
fi

exec env "${env_args[@]}" "$RETROARCH_BIN" "${retroarch_args[@]}" > "$OUTPUT_LOG" 2>&1
