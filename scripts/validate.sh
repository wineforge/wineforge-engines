#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

repo_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
failures=0

for command_name in bash jq python3 shasum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
done

if ! grep -Eq '^FROM ubuntu@sha256:[a-f0-9]{64}$' \
  "$repo_dir/containers/linux/Containerfile"; then
  printf 'Linux builder base image is not digest-pinned\n' >&2
  failures=$((failures + 1))
fi

while IFS= read -r script; do
  bash -n "$script"
done < <(find "$repo_dir/scripts" -type f -name '*.sh' -print | LC_ALL=C sort)

preparation_test=$(mktemp -d "${TMPDIR:-/tmp}/wineforge-prepare-test.XXXXXX")
cleanup() { rm -rf -- "$preparation_test"; }
trap cleanup EXIT HUP INT TERM

reference_test="$preparation_test/reference"
mkdir -p -- "$reference_test/stage/bin" "$reference_test/stage/share/wineforge"
printf 'synthetic executable\n' > "$reference_test/stage/bin/wine"
chmod 755 "$reference_test/stage/bin/wine"
printf 'synthetic archive\n' > "$reference_test/engine.tar.gz"
jq -n '{schema_version: 1, version: "1.0.0", target: "linux-x86_64",
  source: {url: "https://example.invalid/source", sha256: ("0" * 64)},
  builder: {runner_image: "test", compiler: "cc", make: "make"},
  configure: "--prefix=/", source_patches: [], executable: "ELF"}' \
  > "$reference_test/stage/share/wineforge/build-info.json"
"$repo_dir/scripts/generate-reference.py" \
  "$reference_test/stage" "$reference_test/engine.tar.gz" \
  "$reference_test/local.json"
"$repo_dir/scripts/compare-reference.py" \
  "$reference_test/local.json" "$reference_test/local.json" --require-exact

mkdir -- "$preparation_test/wine"
"$repo_dir/scripts/prepare-source.sh" "$preparation_test/wine"
"$repo_dir/scripts/prepare-source.sh" "$preparation_test/wine"
if ! grep -q '^#define WINDEBUG_WHAT_HAPPENED_MESSAGE' \
  "$preparation_test/distversion.h" || \
  ! grep -q '^#define WINDEBUG_USER_SUGGESTION_MESSAGE' \
  "$preparation_test/distversion.h"; then
  printf 'source preparation did not create the required definitions\n' >&2
  failures=$((failures + 1))
fi

for manifest in "$repo_dir"/engines/crossover-*.json; do
  manifest_version=$(jq -er '.source.version' "$manifest")
  if ! jq -e --arg version "$manifest_version" '
    .schema_version == 1 and
    (.id | test("^[a-z0-9][a-z0-9.-]+$")) and
    (.source.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) and
    (.source.url | test("^https://media\\.codeweavers\\.com/")) and
    (.source.sha256 | test("^[a-f0-9]{64}$")) and
    (.source.source_date_epoch | type == "number") and
    (.build.source_subdirectory == "sources/wine") and
    (.build.targets == ["linux-x86_64", "macos-x86_64"]) and
    (.build.patches | type == "array") and
    (all(.build.patches[];
      (.path | test("^patches/" + $version + "/[a-z0-9][a-z0-9.-]+\\.patch$")) and
      (.sha256 | test("^[a-f0-9]{64}$")) and
      (.provenance | type == "string" and length > 0) and
      (.targets | type == "array" and length > 0) and
      ((.targets - ["linux-x86_64", "macos-x86_64"]) | length == 0))) and
    (.redistribution.status as $status |
      (["review_required", "approved", "prohibited"] | index($status)) != null)
  ' "$manifest" >/dev/null; then
    printf 'invalid manifest: %s\n' "$manifest" >&2
    failures=$((failures + 1))
  fi

  while IFS= read -r patch_spec; do
    patch_path=$(jq -er '.path' <<<"$patch_spec")
    expected_patch_sha256=$(jq -er '.sha256' <<<"$patch_spec")
    if [[ ! -f "$repo_dir/$patch_path" || -L "$repo_dir/$patch_path" ]]; then
      printf 'unsafe or missing patch: %s\n' "$patch_path" >&2
      failures=$((failures + 1))
      continue
    fi
    actual_patch_sha256=$(shasum -a 256 "$repo_dir/$patch_path" | awk '{print $1}')
    if [[ "$actual_patch_sha256" != "$expected_patch_sha256" ]]; then
      printf 'patch digest mismatch: %s\n' "$patch_path" >&2
      failures=$((failures + 1))
    fi
  done < <(jq -c '.build.patches[]' "$manifest")
done

dry_run=$(
  DRY_RUN=1 "$repo_dir/scripts/build-engine.sh" 24.0.7 macos-x86_64
)
if ! grep -q '^cross_cflags=-g -O2 -std=gnu17$' <<<"$dry_run"; then
  printf 'source-compatible MinGW C language version is not configured\n' >&2
  failures=$((failures + 1))
fi

if rg -n -i '(private application|customer name|personal path)' "$repo_dir" \
  --glob '!**/scripts/validate.sh' >/dev/null; then
  printf 'repository-neutrality placeholder found in tracked content\n' >&2
  failures=$((failures + 1))
fi

if (( failures != 0 )); then
  exit 1
fi

printf 'manifests and shell syntax are valid\n'
