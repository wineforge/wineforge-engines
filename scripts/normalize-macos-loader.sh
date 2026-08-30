#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if (( $# != 1 )); then
  printf 'usage: %s ENGINE_ROOT\n' "$0" >&2
  exit 64
fi

engine_root=$1
bin_dir="$engine_root/bin"
[[ -d "$bin_dir" && ! -L "$bin_dir" ]] || {
  printf 'unsafe or missing engine bin directory: %s\n' "$bin_dir" >&2
  exit 65
}

normalize_loader() {
  local public_name=$1
  local internal_name=$2
  local public_path="$bin_dir/$public_name"
  local internal_path="$bin_dir/$internal_name"

  if [[ -L "$public_path" && $(readlink "$public_path") == "$internal_name" && \
        -f "$internal_path" && -x "$internal_path" ]]; then
    return
  fi
  if [[ ! -f "$public_path" || -L "$public_path" || ! -x "$public_path" ]]; then
    printf 'installed loader is missing or unsafe: %s\n' "$public_path" >&2
    exit 70
  fi
  if [[ -e "$internal_path" || -L "$internal_path" ]]; then
    printf 'refusing unexpected installed loader path: %s\n' "$internal_path" >&2
    exit 70
  fi

  mv -- "$public_path" "$internal_path"
  ln -s -- "$internal_name" "$public_path"
}

# CrossOver's macOS ntdll may spawn child processes through a loader named
# `wineloader`. Keep that internal name while retaining Wine's conventional
# entry point for manifests and tools.
normalize_loader wine wineloader
if [[ -e "$bin_dir/wine64" || -L "$bin_dir/wine64" ]]; then
  normalize_loader wine64 wineloader64
fi
