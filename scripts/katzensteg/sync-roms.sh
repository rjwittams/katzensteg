#!/usr/bin/env bash
# sync-roms.sh — push ~/roms/ to a remote host via rsync.
#
# Defaults are conservative: no deletes, dry-run unless --apply is passed,
# and runtime state files (.sav, .state, .srm, .auto.sav) are excluded so
# per-host save files do not clobber each other.
#
# Examples:
#   ./sync-roms.sh                       # dry-run, default src + remote
#   ./sync-roms.sh --apply               # actually push
#   ./sync-roms.sh --apply mmx.sfc       # push a single file
#   KATZENSTEG_ROMS_REMOTE=other:roms/ ./sync-roms.sh --apply
#
# Direction is one-way push (local -> remote). Use --pull to invert.
set -euo pipefail

SRC_DEFAULT="$HOME/roms/"
REMOTE_DEFAULT="feta:roms/"

src="${KATZENSTEG_ROMS_SRC:-$SRC_DEFAULT}"
remote="${KATZENSTEG_ROMS_REMOTE:-$REMOTE_DEFAULT}"
mode_args=(--dry-run)
direction=push

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)  mode_args=(); shift ;;
    --pull)   direction=pull; shift ;;
    --help|-h)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)  break ;;
  esac
done

# Optional positional ROM-path narrowing: append each as src/<arg> -> dest preserving structure.
extras=("$@")

excludes=(
  --exclude='*.sav' --exclude='*.state' --exclude='*.srm' --exclude='*.auto.sav'
  --exclude='.DS_Store'
)

if [[ ${#mode_args[@]} -gt 0 ]]; then
  echo "DRY RUN — re-run with --apply to actually transfer." >&2
fi

if [[ "$direction" == push ]]; then
  if [[ ${#extras[@]} -gt 0 ]]; then
    for path in "${extras[@]}"; do
      rsync -ahP "${mode_args[@]}" "${excludes[@]}" "$src$path" "$remote$path"
    done
  else
    rsync -ahP "${mode_args[@]}" "${excludes[@]}" "$src" "$remote"
  fi
else
  if [[ ${#extras[@]} -gt 0 ]]; then
    for path in "${extras[@]}"; do
      rsync -ahP "${mode_args[@]}" "${excludes[@]}" "$remote$path" "$src$path"
    done
  else
    rsync -ahP "${mode_args[@]}" "${excludes[@]}" "$remote" "$src"
  fi
fi
