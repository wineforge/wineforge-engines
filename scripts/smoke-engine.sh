#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

if (( $# < 2 || $# > 3 )); then
  printf 'usage: %s ENGINE_ROOT WINE_RELATIVE_PATH [--require-wow64]\n' "$0" >&2
  exit 64
fi

engine_root=$1
wine_relative=$2
wow64_mode=${3:-}
if [[ -n "$wow64_mode" && "$wow64_mode" != --require-wow64 ]]; then
  printf 'unknown smoke-test option: %s\n' "$wow64_mode" >&2
  exit 64
fi
wine="$engine_root/$wine_relative"
[[ -x "$wine" ]] || { printf 'Wine executable is not executable: %s\n' "$wine" >&2; exit 66; }
wineserver="$engine_root/bin/wineserver"
[[ -x "$wineserver" ]] || { printf 'wineserver is not executable: %s\n' "$wineserver" >&2; exit 66; }
if [[ "$wow64_mode" == --require-wow64 && ! -x "$engine_root/bin/wineloader" ]]; then
  printf 'CrossOver macOS loader is missing: %s\n' "$engine_root/bin/wineloader" >&2
  printf 'the staged runtime must retain wineloader for child process startup\n' >&2
  exit 70
fi

prefix=$(mktemp -d "${TMPDIR:-/tmp}/wineforge-engine-smoke.XXXXXX")
cleanup() {
  WINEPREFIX="$prefix" "$wineserver" -k >/dev/null 2>&1 || true
  rm -rf -- "$prefix"
}
trap cleanup EXIT HUP INT TERM

output=$(WINEPREFIX="$prefix" WINEDEBUG=-all ROSETTA_ADVERTISE_AVX=1 "$wine" cmd /c ver 2>&1) || {
  printf '%s\n' "$output" >&2
  printf 'fresh-prefix engine acceptance failed\n' >&2
  exit 70
}
printf '%s\n' "$output" | grep -Eq 'Microsoft Windows [0-9]+' || {
  printf '%s\n' "$output" >&2
  printf 'fresh-prefix engine acceptance returned no Windows version\n' >&2
  exit 70
}
printf 'fresh-prefix engine acceptance passed: %s\n' "$(printf '%s\n' "$output" | grep -E 'Microsoft Windows [0-9]+' | tail -1)"

if [[ "$wow64_mode" == --require-wow64 ]]; then
  [[ -f "$engine_root/lib/wine/i386-windows/ntdll.dll" ]] || {
    printf '32-bit Windows runtime module is missing\n' >&2
    exit 70
  }
  [[ -f "$prefix/drive_c/windows/syswow64/cmd.exe" ]] || {
    printf '32-bit cmd.exe was not installed into the fresh prefix\n' >&2
    exit 70
  }
  wow64_output=$(WINEPREFIX="$prefix" WINEDEBUG=-all ROSETTA_ADVERTISE_AVX=1 "$wine" \
    'C:\windows\syswow64\cmd.exe' /c ver 2>&1) || {
    printf '%s\n' "$wow64_output" >&2
    printf '32-bit WoW64 engine acceptance failed\n' >&2
    exit 70
  }
  printf '%s\n' "$wow64_output" | grep -Eq 'Microsoft Windows [0-9]+' || {
    printf '%s\n' "$wow64_output" >&2
    printf '32-bit WoW64 acceptance returned no Windows version\n' >&2
    exit 70
  }
  printf '32-bit WoW64 engine acceptance passed: %s\n' \
    "$(printf '%s\n' "$wow64_output" | grep -E 'Microsoft Windows [0-9]+' | tail -1)"
fi
