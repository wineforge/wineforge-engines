#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 022

usage() {
  printf 'usage: %s VERSION TARGET [--runtime auto|docker|podman|native] [--store DIRECTORY] [--source-cache DIRECTORY]\n' "$0" >&2
}

if (( $# < 2 )); then usage; exit 64; fi
invocation_arguments=("$@")
version=$1
target=$2
shift 2
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'invalid version: %s\n' "$version" >&2
  exit 64
}
runtime=auto
repo_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
store="$repo_dir/local-builds"
source_cache=
while (( $# )); do
  case "$1" in
    --runtime) runtime=${2:?missing runtime}; shift 2 ;;
    --store) store=${2:?missing store}; shift 2 ;;
    --source-cache) source_cache=${2:?missing source cache}; shift 2 ;;
    *) usage; exit 64 ;;
  esac
done

case "$target" in
  linux-x86_64)
    if [[ "$runtime" == auto ]]; then
      if command -v podman >/dev/null 2>&1; then runtime=podman
      elif command -v docker >/dev/null 2>&1; then runtime=docker
      else printf 'Podman or Docker is required for Linux builds\n' >&2; exit 69
      fi
    fi
    case "$runtime" in podman|docker) ;; *) printf 'Linux builds require Podman or Docker\n' >&2; exit 64 ;; esac
    ;;
  macos-x86_64)
    [[ "$runtime" == auto ]] && runtime=native
    [[ "$runtime" == native ]] || { printf 'macOS engines require a native macOS build\n' >&2; exit 64; }
    [[ $(uname -s) == Darwin ]] || { printf 'macOS engines require a macOS host\n' >&2; exit 69; }
    if [[ $(uname -m) == arm64 && ${WINEFORGE_ROSETTA_REEXEC:-0} != 1 ]]; then
      command -v arch >/dev/null 2>&1 || { printf 'arch is required for Rosetta builds\n' >&2; exit 69; }
      exec arch -x86_64 env \
        WINEFORGE_ROSETTA_REEXEC=1 \
        LDFLAGS="${LDFLAGS:+$LDFLAGS }-Wl,-ld_classic" \
        "$0" "${invocation_arguments[@]}"
    fi
    ;;
  *) printf 'unsupported target: %s\n' "$target" >&2; exit 64 ;;
esac

if [[ -z "$source_cache" ]]; then
  if [[ $(uname -s) == Darwin ]]; then
    source_cache=${HOME:?HOME is required}/Library/Caches/Wineforge/engine-sources
  else
    source_cache=${XDG_CACHE_HOME:-${HOME:?HOME is required}/.cache}/wineforge/engine-sources
  fi
fi
if [[ -L "$source_cache" ]]; then
  printf 'source cache must not be a symlink: %s\n' "$source_cache" >&2
  exit 65
fi
mkdir -p -- "$source_cache"
source_cache=$(CDPATH= cd -- "$source_cache" && pwd -P)
[[ "$source_cache" != / ]] || { printf 'refusing root source cache\n' >&2; exit 65; }

build_id="crossover-$version-$target"
if [[ -L "$store" ]]; then
  printf 'build store must not be a symlink: %s\n' "$store" >&2
  exit 65
fi
mkdir -p -- "$store"
store=$(CDPATH= cd -- "$store" && pwd -P)
[[ "$store" != / ]] || { printf 'refusing root build store\n' >&2; exit 65; }
output_dir="$store/$build_id"
[[ ! -e "$output_dir" ]] || { printf 'managed build already exists: %s\n' "$output_dir" >&2; exit 73; }
mkdir -- "$output_dir"
cleanup() {
  status=$?
  if (( status != 0 )); then rm -rf -- "$output_dir"; fi
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

if [[ "$runtime" == native ]]; then
  WINEFORGE_WORK_DIR="$output_dir/work" \
    WINEFORGE_DIST_DIR="$output_dir/dist" \
    WINEFORGE_SOURCE_CACHE="$source_cache" \
    "$repo_dir/scripts/build-engine.sh" "$version" "$target"
else
  image="wineforge-engine-builder-linux-x86_64:ubuntu-24.04"
  "$runtime" build --platform linux/amd64 \
    --file "$repo_dir/containers/linux/Containerfile" --tag "$image" "$repo_dir"
  "$runtime" run --rm --platform linux/amd64 \
    --user "$(id -u):$(id -g)" \
    --volume "$repo_dir:/workspace:ro" \
    --volume "$output_dir:/output" \
    --volume "$source_cache:/source-cache" \
    --env WINEFORGE_WORK_DIR=/output/work \
    --env WINEFORGE_DIST_DIR=/output/dist \
    --env WINEFORGE_SOURCE_CACHE=/source-cache \
    --env WINEFORGE_JOBS="${WINEFORGE_JOBS:-2}" \
    "$image" ./scripts/build-engine.sh "$version" "$target"
fi

artifact="$output_dir/dist/wineforge-engine-$version-$target.tar.gz"
if command -v shasum >/dev/null 2>&1; then
  artifact_sha256=$(shasum -a 256 "$artifact" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  artifact_sha256=$(sha256sum "$artifact" | awk '{print $1}')
else
  printf 'shasum or sha256sum is required\n' >&2
  exit 69
fi
jq -n \
  --arg id "$build_id" \
  --arg sha256 "$artifact_sha256" \
  '{schema_version: 1, kind: "build-artifacts", id: $id,
    artifact_sha256: $sha256}' \
  > "$output_dir/.wineforge-build-artifacts.json"
trap - EXIT HUP INT TERM
printf 'created managed build %s\n' "$output_dir"
printf 'prune with: wineforge engine prune-artifacts --store %q --id %q --yes\n' "$store" "$build_id"
