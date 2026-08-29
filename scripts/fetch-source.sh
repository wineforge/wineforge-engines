#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 022

if (( $# != 2 )); then
  printf 'usage: %s VERSION DESTINATION\n' "$0" >&2
  exit 64
fi

version=$1
destination=$2
repo_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_dir/engines/crossover-$version.json"

if [[ ! -f "$manifest" ]]; then
  printf 'unsupported version: %s\n' "$version" >&2
  exit 64
fi

for command_name in curl jq shasum tar; do
  command -v "$command_name" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$command_name" >&2
    exit 69
  }
done

url=$(jq -er '.source.url' "$manifest")
expected_sha256=$(jq -er '.source.sha256' "$manifest")
if [[ -n ${WINEFORGE_SOURCE_CACHE:-} ]]; then
  cache_dir=$WINEFORGE_SOURCE_CACHE
elif [[ $(uname -s) == Darwin ]]; then
  cache_dir=${HOME:?HOME is required}/Library/Caches/Wineforge/engine-sources
else
  cache_dir=${XDG_CACHE_HOME:-${HOME:?HOME is required}/.cache}/wineforge/engine-sources
fi
if [[ -L "$cache_dir" ]]; then
  printf 'source cache must not be a symlink: %s\n' "$cache_dir" >&2
  exit 65
fi
mkdir -p -- "$cache_dir"
cache_dir=$(CDPATH= cd -- "$cache_dir" && pwd -P)
[[ "$cache_dir" != / ]] || { printf 'refusing root source cache\n' >&2; exit 65; }
archive="$cache_dir/$expected_sha256.tar.gz"
partial="$archive.part"
for candidate in "$archive" "$partial"; do
  if [[ -L "$candidate" || -e "$candidate" && ! -f "$candidate" ]]; then
    printf 'unsafe source-cache entry: %s\n' "$candidate" >&2
    exit 65
  fi
done

if [[ -f "$archive" ]]; then
  actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    rm -f -- "$archive"
  else
    printf 'using cached engine source %s\n' "$archive"
  fi
fi

if [[ ! -f "$archive" ]]; then
  if [[ -f "$partial" ]]; then
    partial_sha256=$(shasum -a 256 "$partial" | awk '{print $1}')
    if [[ "$partial_sha256" == "$expected_sha256" ]]; then
      mv -- "$partial" "$archive"
    fi
  fi
fi

if [[ ! -f "$archive" ]]; then
  curl_status=0
  curl --fail --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --continue-at - --output "$partial" "$url" || \
    curl_status=$?
  if (( curl_status == 33 )); then
    rm -f -- "$partial"
    curl --fail --location --proto '=https' --tlsv1.2 \
      --retry 3 --retry-all-errors --output "$partial" "$url"
  elif (( curl_status != 0 )); then
    exit "$curl_status"
  fi
  actual_sha256=$(shasum -a 256 "$partial" | awk '{print $1}')
  if [[ "$actual_sha256" != "$expected_sha256" ]]; then
    rm -f -- "$partial"
    printf 'source digest mismatch: expected %s, got %s\n' \
      "$expected_sha256" "$actual_sha256" >&2
    exit 65
  fi
  mv -- "$partial" "$archive"
fi
actual_sha256=$(shasum -a 256 "$archive" | awk '{print $1}')
if [[ "$actual_sha256" != "$expected_sha256" ]]; then
  printf 'source digest mismatch: expected %s, got %s\n' \
    "$expected_sha256" "$actual_sha256" >&2
  exit 65
fi

while IFS= read -r member; do
  case "$member" in
    /*|../*|*/../*|*/..)
      printf 'unsafe archive path: %s\n' "$member" >&2
      exit 65
      ;;
  esac
done < <(tar -tzf "$archive")

if [[ -e "$destination" ]]; then
  printf 'destination already exists: %s\n' "$destination" >&2
  exit 73
fi
mkdir -p -- "$destination"
tar -xzf "$archive" -C "$destination" --no-same-owner
printf '%s\n' "$actual_sha256" > "$destination/SOURCE.sha256"
