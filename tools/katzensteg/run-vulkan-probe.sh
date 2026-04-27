#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"
KATZENSTEG_VULKAN_LAYER="${KATZENSTEG_VULKAN_LAYER:-$ROOT/zig-out/lib/libkatzensteg-vulkan-layer.dylib}"
PROBE_BIN="${PROBE_BIN:-$ROOT/zig-out/bin/katzensteg-vulkan-probe}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/katzensteg-vulkan-probe.out}"

if [[ ! -x "$PROBE_BIN" ]]; then
  echo "Vulkan probe not found or not executable: $PROBE_BIN" >&2
  echo "Run: zig build" >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_LIB" ]]; then
  echo "Katzensteg dylib not found: $KATZENSTEG_LIB" >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_VULKAN_LAYER" ]]; then
  echo "Katzensteg Vulkan layer not found: $KATZENSTEG_VULKAN_LAYER" >&2
  exit 1
fi

rm -f "$OUTPUT_LOG" /tmp/katzensteg-*.log /tmp/katzensteg-composite.ppm

echo "Running SDL2 Vulkan probe with Katzensteg"
echo "  PROBE_BIN=$PROBE_BIN"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  KATZENSTEG_VULKAN_LAYER=$KATZENSTEG_VULKAN_LAYER"
echo "  OUTPUT_LOG=$OUTPUT_LOG"

exec env \
  KATZENSTEG_INTERCEPT_MODE="${KATZENSTEG_INTERCEPT_MODE:-queued_replay}" \
  KATZENSTEG_COMPOSITE_MODE="${KATZENSTEG_COMPOSITE_MODE:-fullscreen}" \
  KATZENSTEG_OUTPUT_PROFILE="${KATZENSTEG_OUTPUT_PROFILE:-file_whole}" \
  KATZENSTEG_INPUT="${KATZENSTEG_INPUT:-1}" \
  KATZENSTEG_INPUT_CLAIM="${KATZENSTEG_INPUT_CLAIM:-1}" \
  KATZENSTEG_VULKAN_CAPTURE="${KATZENSTEG_VULKAN_CAPTURE:-1}" \
  VK_LAYER_PATH="$ROOT/tools/katzensteg" \
  VK_INSTANCE_LAYERS=VK_LAYER_KATZENSTEG_capture \
  DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB" \
  "$PROBE_BIN" "$@" > "$OUTPUT_LOG" 2>&1
