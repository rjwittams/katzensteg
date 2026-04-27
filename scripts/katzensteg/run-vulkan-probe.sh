#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE_BIN="${PROBE_BIN:-$ROOT/zig-out/bin/katzensteg-vulkan-probe}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/katzensteg-vulkan-probe.out}"

case "$(uname -s)" in
  Linux)
    KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.so}"
    KATZENSTEG_VULKAN_LAYER="${KATZENSTEG_VULKAN_LAYER:-$ROOT/zig-out/lib/libkatzensteg-vulkan-layer.so}"
    PRELOAD_ENV=(LD_PRELOAD="$KATZENSTEG_LIB")
    ;;
  Darwin)
    KATZENSTEG_LIB="${KATZENSTEG_LIB:-$ROOT/zig-out/lib/libkatzensteg-unlinked.dylib}"
    KATZENSTEG_VULKAN_LAYER="${KATZENSTEG_VULKAN_LAYER:-$ROOT/zig-out/lib/libkatzensteg-vulkan-layer.dylib}"
    PRELOAD_ENV=(DYLD_INSERT_LIBRARIES="$KATZENSTEG_LIB")
    ;;
  *)
    echo "Unsupported platform for Vulkan probe runner: $(uname -s)" >&2
    exit 1
    ;;
esac

if [[ ! -x "$PROBE_BIN" ]]; then
  echo "Vulkan probe not found or not executable: $PROBE_BIN" >&2
  echo "Run: zig build" >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_LIB" ]]; then
  echo "Katzensteg preload library not found: $KATZENSTEG_LIB" >&2
  exit 1
fi
if [[ ! -f "$KATZENSTEG_VULKAN_LAYER" ]]; then
  echo "Katzensteg Vulkan layer not found: $KATZENSTEG_VULKAN_LAYER" >&2
  exit 1
fi

rm -f "$OUTPUT_LOG" /tmp/katzensteg-*.log /tmp/katzensteg-composite.ppm

MANIFEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/katzensteg-vulkan-layer.XXXXXX")"
cleanup_manifest_dir() {
  rm -rf "$MANIFEST_DIR"
}
trap cleanup_manifest_dir EXIT

cat > "$MANIFEST_DIR/VK_LAYER_KATZENSTEG_capture.json" <<EOF
{
  "file_format_version": "1.2.0",
  "layer": {
    "name": "VK_LAYER_KATZENSTEG_capture",
    "type": "GLOBAL",
    "library_path": "$KATZENSTEG_VULKAN_LAYER",
    "api_version": "1.0.0",
    "implementation_version": "1",
    "description": "Katzensteg Vulkan capture layer",
    "functions": {
      "vkGetInstanceProcAddr": "vkGetInstanceProcAddr",
      "vkGetDeviceProcAddr": "vkGetDeviceProcAddr"
    }
  }
}
EOF

echo "Running SDL2 Vulkan probe with Katzensteg"
echo "  PROBE_BIN=$PROBE_BIN"
echo "  KATZENSTEG_LIB=$KATZENSTEG_LIB"
echo "  KATZENSTEG_VULKAN_LAYER=$KATZENSTEG_VULKAN_LAYER"
echo "  VK_LAYER_PATH=$MANIFEST_DIR"
echo "  OUTPUT_LOG=$OUTPUT_LOG"

env \
  KATZENSTEG_INTERCEPT_MODE="${KATZENSTEG_INTERCEPT_MODE:-queued_replay}" \
  KATZENSTEG_COMPOSITE_MODE="${KATZENSTEG_COMPOSITE_MODE:-fullscreen}" \
  KATZENSTEG_OUTPUT_PROFILE="${KATZENSTEG_OUTPUT_PROFILE:-file_whole}" \
  KATZENSTEG_INPUT="${KATZENSTEG_INPUT:-1}" \
  KATZENSTEG_INPUT_CLAIM="${KATZENSTEG_INPUT_CLAIM:-1}" \
  KATZENSTEG_VULKAN_CAPTURE="${KATZENSTEG_VULKAN_CAPTURE:-1}" \
  VK_LAYER_PATH="$MANIFEST_DIR" \
  VK_INSTANCE_LAYERS=VK_LAYER_KATZENSTEG_capture \
  "${PRELOAD_ENV[@]}" \
  "$PROBE_BIN" "$@" > "$OUTPUT_LOG" 2>&1
