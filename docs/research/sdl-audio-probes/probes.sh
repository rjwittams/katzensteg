#!/usr/bin/env bash
# Build and run the SDL audio interception probes.
#
#   probes.sh fetch   clone SDL 2.32.10, SDL 3.4.16, sdl2-compat 2.32.74 into $WORK/src
#   probes.sh deps    build them into $WORK/prefix/{sdl2,sdl3,compat}
#   probes.sh build   build probes and interposers into $WORK/out
#   probes.sh run     run every experiment into $WORK/runs and analyse it
#
# WORK defaults to ~/sdl-audio-probes. Needs cmake, ninja, a C compiler and
# python3 with numpy. Experimental code: not part of the Katzensteg build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$HOME/sdl-audio-probes}"
SRC="$WORK/src"
PFX="$WORK/prefix"
OUT="$WORK/out"
RUNS="$WORK/runs"

fetch() {
    mkdir -p "$SRC"
    clone() { [ -d "$SRC/$2" ] || GIT_LFS_SKIP_SMUDGE=1 git clone -q --depth 1 -b "$3" "$1" "$SRC/$2"; }
    clone https://github.com/libsdl-org/SDL.git SDL2 release-2.32.10
    clone https://github.com/libsdl-org/SDL.git SDL3 release-3.4.16
    clone https://github.com/libsdl-org/sdl2-compat.git sdl2-compat release-2.32.74
    for d in SDL2 SDL3 sdl2-compat; do echo "$d $(git -C "$SRC/$d" rev-parse HEAD)"; done
}

deps() {
    local common=(-G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo)
    cmake -S "$SRC/SDL2" -B "$WORK/build/SDL2" "${common[@]}" -DCMAKE_INSTALL_PREFIX="$PFX/sdl2" \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF -DSDL_VIDEO=OFF -DSDL_RENDER=OFF \
        -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_SENSOR=OFF -DSDL_HIDAPI=OFF
    cmake --build "$WORK/build/SDL2" && cmake --install "$WORK/build/SDL2"
    cmake -S "$SRC/SDL3" -B "$WORK/build/SDL3" "${common[@]}" -DCMAKE_INSTALL_PREFIX="$PFX/sdl3" \
        -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_TEST_LIBRARY=OFF \
        -DSDL_VIDEO=OFF -DSDL_RENDER=OFF -DSDL_GPU=OFF -DSDL_CAMERA=OFF -DSDL_JOYSTICK=OFF \
        -DSDL_HAPTIC=OFF -DSDL_SENSOR=OFF -DSDL_HIDAPI=OFF -DSDL_UNIX_CONSOLE_BUILD=ON
    cmake --build "$WORK/build/SDL3" && cmake --install "$WORK/build/SDL3"
    cmake -S "$SRC/sdl2-compat" -B "$WORK/build/compat" "${common[@]}" -DCMAKE_INSTALL_PREFIX="$PFX/compat" \
        -DCMAKE_PREFIX_PATH="$PFX/sdl3" -DSDL2COMPAT_TESTS=OFF -DSDL2COMPAT_X11=OFF
    cmake --build "$WORK/build/compat" && cmake --install "$WORK/build/compat"
}

build() {
    mkdir -p "$OUT"
    local cf=(-O2 -g -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -I"$HERE")
    cc "${cf[@]}" -I"$PFX/sdl2/include/SDL2" "$HERE/probe_sdl2.c" -o "$OUT/probe_sdl2" \
        -L"$PFX/sdl2/lib" -lSDL2 -lm
    cc "${cf[@]}" -I"$PFX/sdl3/include" "$HERE/probe_sdl3.c" -o "$OUT/probe_sdl3" \
        -L"$PFX/sdl3/lib" -lSDL3 -lm
    cc "${cf[@]}" -fPIC -shared -I"$PFX/sdl2/include/SDL2" "$HERE/katz_sdl2.c" \
        -o "$OUT/katz_sdl2.so" -ldl -lpthread
    cc "${cf[@]}" -fPIC -shared -I"$PFX/sdl2/include/SDL2" "$HERE/katz_sdl2.c" \
        -Wl,--version-script="$HERE/katz_sdl2_ver.map" -o "$OUT/katz_sdl2_ver.so" -ldl -lpthread
    cc "${cf[@]}" -fPIC -shared -DKATZ_SDL3_OBSERVE -I"$PFX/sdl3/include" "$HERE/katz_sdl3.c" \
        -o "$OUT/katz_sdl3_preload.so" -ldl -lpthread
    cc "${cf[@]}" -fPIC -shared -DKATZ_SDL3_OBSERVE -DKATZ_SYMVER -I"$PFX/sdl3/include" "$HERE/katz_sdl3.c" \
        -Wl,--version-script="$HERE/katz_sdl3_symver.map" -o "$OUT/katz_sdl3_symver.so" -ldl -lpthread
    cc "${cf[@]}" -fPIC -shared -fvisibility=hidden -DKATZ_DYNAPI -I"$PFX/sdl3/include" \
        -I"$SRC/SDL3/src/dynapi" "$HERE/katz_sdl3.c" -o "$OUT/katz_sdl3_dynapi.so" -ldl -lpthread
    echo "built into $OUT"
}

# run <name> <libpath> <probe> <args...>; env vars come from the caller.
run1() {
    local name="$1" libpath="$2"
    shift 2
    local dir="$RUNS/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    local pre="${LD_PRELOAD:-}" dyn="${SDL3_DYNAMIC_API:-}"
    (
        unset LD_PRELOAD SDL3_DYNAMIC_API
        export LD_LIBRARY_PATH="$libpath"
        export SDL_AUDIODRIVER=disk SDL_AUDIO_DRIVER=disk
        export SDL_DISKAUDIOFILE="$dir/disk.raw" SDL_AUDIO_DISK_OUTPUT_FILE="$dir/disk.raw"
        export KATZ_LOG="$dir/katz.log" KATZ_TAP_FILE="$dir/tap"
        echo "LD_PRELOAD=$pre SDL3_DYNAMIC_API=$dyn KATZ_GAIN=${KATZ_GAIN:-} $*" >"$dir/cmd"
        timeout 30 env ${pre:+LD_PRELOAD="$pre"} ${dyn:+SDL3_DYNAMIC_API="$dyn"} "$@" \
            >"$dir/probe.out" 2>"$dir/probe.err"
        echo "exit=$?" >>"$dir/probe.out"
    ) || echo "exit=$?" >>"$dir/probe.out"
}

run() {
    rm -rf "$RUNS"
    mkdir -p "$RUNS"
    local s2="$PFX/sdl2/lib" s3="$PFX/sdl3/lib" compat="$PFX/compat/lib:$PFX/sdl3/lib"
    local k2="$OUT/katz_sdl2.so" k3="$OUT/katz_sdl3_preload.so" k3d="$OUT/katz_sdl3_dynapi.so"
    local p2="$OUT/probe_sdl2" p3="$OUT/probe_sdl3"

    # Baselines without interposition.
    run1 base-sdl2-callback "$s2" "$p2" callback
    run1 base-sdl3-bound "$s3" "$p3" bound

    for gain in 1 0; do
        for mode in callback queue legacy; do
            LD_PRELOAD="$k2" KATZ_GAIN=$gain run1 "sdl2-$mode-g$gain" "$s2" "$p2" "$mode"
            LD_PRELOAD="$k2" KATZ_GAIN=$gain run1 "compat-$mode-g$gain" "$compat" "$p2" "$mode"
        done
        LD_PRELOAD="$k2" KATZ_GAIN=$gain run1 "sdl2-queue-f32-g$gain" "$s2" "$p2" queue --f32
        for mode in bound devstream devstream-cb; do
            LD_PRELOAD="$k3" KATZ_GAIN=$gain run1 "sdl3-$mode-g$gain" "$s3" "$p3" "$mode"
            SDL3_DYNAMIC_API="$k3d" KATZ_GAIN=$gain run1 "sdl3dyn-$mode-g$gain" "$s3" "$p3" "$mode"
        done
    done
    LD_PRELOAD="$k3" KATZ_GAIN=0 run1 "sdl3-bound-s16-g0" "$s3" "$p3" bound --s16

    # Close and reopen mid-run.
    for mode in callback queue legacy; do
        LD_PRELOAD="$k2" KATZ_GAIN=0 run1 "sdl2-$mode-reopen-g0" "$s2" "$p2" "$mode" --reopen
        LD_PRELOAD="$k2" KATZ_GAIN=0 run1 "compat-$mode-reopen-g0" "$compat" "$p2" "$mode" --reopen
    done
    for mode in bound devstream devstream-cb; do
        LD_PRELOAD="$k3" KATZ_GAIN=0 run1 "sdl3-$mode-reopen-g0" "$s3" "$p3" "$mode" --reopen
    done

    # App postmix chaining.
    LD_PRELOAD="$k3" KATZ_GAIN=0 run1 "sdl3-bound-apppostmix-g0" "$s3" "$p3" bound --app-postmix
    SDL3_DYNAMIC_API="$k3d" KATZ_GAIN=0 run1 "sdl3dyn-devstream-apppostmix-g0" "$s3" "$p3" devstream --app-postmix

    # sdl2-compat double interception: does the SDL3 layer see compat's calls?
    # KATZ_GAIN=0.5: disk rms 0.5x means one layer scaled, 0.25x means two.
    local k2v="$OUT/katz_sdl2_ver.so" k3v="$OUT/katz_sdl3_symver.so"
    for mode in callback queue; do
        # unversioned SDL3 preload: exports collide with SDL2 names
        LD_PRELOAD="$k3" KATZ_GAIN=0.5 run1 "compat-$mode-preload3only" "$compat" "$p2" "$mode"
        LD_PRELOAD="$k2:$k3" KATZ_GAIN=0.5 run1 "compat-$mode-preload2then3" "$compat" "$p2" "$mode"
        LD_PRELOAD="$k3:$k2" KATZ_GAIN=0.5 run1 "compat-$mode-preload3then2" "$compat" "$p2" "$mode"
        # SDL3 preload exported only as hidden SDL_x@SDL3_0.0.0
        LD_PRELOAD="$k3v" KATZ_GAIN=0.5 run1 "compat-$mode-preload3vonly" "$compat" "$p2" "$mode"
        LD_PRELOAD="$k2:$k3v" KATZ_GAIN=0.5 run1 "compat-$mode-preload2then3v" "$compat" "$p2" "$mode"
        LD_PRELOAD="$k3v:$k2" KATZ_GAIN=0.5 run1 "compat-$mode-preload3vthen2" "$compat" "$p2" "$mode"
        # SDL3_DYNAMIC_API reaches compat's SDL3 calls through SDL3's jump table
        SDL3_DYNAMIC_API="$k3d" KATZ_GAIN=0.5 run1 "compat-$mode-dynapi3only" "$compat" "$p2" "$mode"
        LD_PRELOAD="$k2" SDL3_DYNAMIC_API="$k3d" KATZ_GAIN=0.5 run1 "compat-$mode-preload2-dynapi3" "$compat" "$p2" "$mode"
    done
    # Both preloads in a native SDL3 process and a classic SDL2 process.
    LD_PRELOAD="$k2:$k3v" KATZ_GAIN=0.5 run1 "sdl3-bound-preload2then3v" "$s3" "$p3" bound
    LD_PRELOAD="$k3v:$k2" KATZ_GAIN=0.5 run1 "sdl3-bound-preload3vthen2" "$s3" "$p3" bound
    LD_PRELOAD="$k2v:$k3v" KATZ_GAIN=0.5 run1 "sdl3-bound-preload2vthen3v" "$s3" "$p3" bound
    LD_PRELOAD="$k3v:$k2v" KATZ_GAIN=0.5 run1 "sdl3-devstream-preload3vthen2v" "$s3" "$p3" devstream
    LD_PRELOAD="$k2v:$k3v" KATZ_GAIN=0.5 run1 "sdl2-callback-preload2vthen3v" "$s2" "$p2" callback
    LD_PRELOAD="$k2v:$k3v" KATZ_GAIN=0.5 run1 "compat-callback-preload2vthen3v" "$compat" "$p2" callback

    python3 -I "$HERE/analyze.py" "$RUNS"
}

case "${1:-}" in
fetch) fetch ;;
deps) deps ;;
build) build ;;
run) run ;;
*) echo "usage: $0 fetch|deps|build|run" >&2; exit 2 ;;
esac
