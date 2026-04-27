#!/usr/bin/env bash
set -euo pipefail

GAMESCOPE_DIR="${GAMESCOPE_DIR:-$HOME/dev/gamescope}"
GAMESCOPE_BIN="${GAMESCOPE_BIN:-$GAMESCOPE_DIR/build-sdl/src/gamescope}"
STEAM_ROOT="${STEAM_ROOT:-$HOME/.local/share/Steam}"
APP_ID="${APP_ID:-1486920}"
SLR_ENTRY="${SLR_ENTRY:-$STEAM_ROOT/steamapps/common/SteamLinuxRuntime_4/_v2-entry-point}"
PROTON_BIN="${PROTON_BIN:-$STEAM_ROOT/steamapps/common/Proton - Experimental/proton}"
GAME_EXE="${GAME_EXE:-$STEAM_ROOT/steamapps/common/Tempest Rising/Tempest/Binaries/Win64/Tempest-Win64-Shipping.exe}"
OUTPUT_LOG="${OUTPUT_LOG:-/tmp/gamescope-tempest-outside-ks.out}"

if [[ ! -x "$GAMESCOPE_BIN" ]]; then
  echo "gamescope binary not found or not executable: $GAMESCOPE_BIN" >&2
  exit 1
fi
if [[ ! -x "$SLR_ENTRY" ]]; then
  echo "Steam Linux Runtime entry point not found or not executable: $SLR_ENTRY" >&2
  exit 1
fi
if [[ ! -x "$PROTON_BIN" ]]; then
  echo "Proton binary not found or not executable: $PROTON_BIN" >&2
  exit 1
fi
if [[ ! -f "$GAME_EXE" ]]; then
  echo "Tempest executable not found: $GAME_EXE" >&2
  exit 1
fi

env_unset_args=(
  -u LD_PRELOAD
  -u DYLD_INSERT_LIBRARIES
  -u KATZENSTEG_VULKAN_CAPTURE
  -u KATZENSTEG_TRACE_VULKAN
  -u KATZENSTEG_TRACE_SDL
  -u VK_INSTANCE_LAYERS
)

env_assign_args=(
  PATH="$GAMESCOPE_DIR/build-sdl/src:$PATH"
  STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
  STEAM_COMPAT_DATA_PATH="$STEAM_ROOT/steamapps/compatdata/$APP_ID"
  SteamAppId="$APP_ID"
  SteamGameId="$APP_ID"
)

if [[ "${USE_GAMESCOPE_WSI:-0}" == "1" ]]; then
  env_assign_args+=(
    ENABLE_GAMESCOPE_WSI=1
    VK_LAYER_PATH="${VK_LAYER_PATH:-$GAMESCOPE_DIR/build-sdl/layer}"
  )
else
  env_unset_args+=(
    -u ENABLE_GAMESCOPE_WSI
    -u VK_LAYER_PATH
  )
fi

gamescope_args=(
  --backend sdl
  -W "${GAMESCOPE_WIDTH:-1280}"
  -H "${GAMESCOPE_HEIGHT:-720}"
  -w "${GAME_WIDTH:-1280}"
  -h "${GAME_HEIGHT:-720}"
)
if [[ "${GAMESCOPE_STEAM:-0}" == "1" ]]; then
  gamescope_args+=(--steam)
fi
if [[ -n "${GAMESCOPE_VIRTUAL_CONNECTOR_STRATEGY:-}" ]]; then
  gamescope_args+=(--virtual-connector-strategy "$GAMESCOPE_VIRTUAL_CONNECTOR_STRATEGY")
fi
if [[ "${GAMESCOPE_DEBUG_FOCUS:-0}" == "1" ]]; then
  gamescope_args+=(--debug-focus)
fi
if [[ "${GAMESCOPE_DEBUG_EVENTS:-0}" == "1" ]]; then
  gamescope_args+=(--debug-events)
fi

command_args=(
  "$GAMESCOPE_BIN"
  "${gamescope_args[@]}"
  --
  "$SLR_ENTRY"
  --verb=waitforexitandrun
  --
  "$PROTON_BIN"
  waitforexitandrun
  "$GAME_EXE"
)

echo "Running Tempest Rising under gamescope outside Katzensteg"
echo "  GAMESCOPE_BIN=$GAMESCOPE_BIN"
echo "  SLR_ENTRY=$SLR_ENTRY"
echo "  PROTON_BIN=$PROTON_BIN"
echo "  GAME_EXE=$GAME_EXE"
echo "  USE_GAMESCOPE_WSI=${USE_GAMESCOPE_WSI:-0}"
echo "  GAMESCOPE_STEAM=${GAMESCOPE_STEAM:-0}"
echo "  GAMESCOPE_VIRTUAL_CONNECTOR_STRATEGY=${GAMESCOPE_VIRTUAL_CONNECTOR_STRATEGY:-}"
echo "  GAMESCOPE_DEBUG_FOCUS=${GAMESCOPE_DEBUG_FOCUS:-0}"
echo "  GAMESCOPE_DEBUG_EVENTS=${GAMESCOPE_DEBUG_EVENTS:-0}"
echo "  OUTPUT_LOG=$OUTPUT_LOG"

env "${env_unset_args[@]}" "${env_assign_args[@]}" "${command_args[@]}" "$@" > "$OUTPUT_LOG" 2>&1
