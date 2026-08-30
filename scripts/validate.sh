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

source_cache_test="$preparation_test/source-cache"
mkdir -p -- "$source_cache_test/fixture/sources/wine" "$source_cache_test/bin"
printf 'cached source fixture\n' > "$source_cache_test/fixture/sources/wine/README"
tar -czf "$source_cache_test/source.tar.gz" -C "$source_cache_test/fixture" sources
cat > "$source_cache_test/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=
[[ -z ${WINEFORGE_TEST_CURL_ARGUMENTS:-} ]] || printf '%s\n' "$*" >> "$WINEFORGE_TEST_CURL_ARGUMENTS"
while (( $# )); do
  case "$1" in
    --output) output=${2:?missing output}; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]]
count=0
[[ ! -f "$WINEFORGE_TEST_CURL_COUNT" ]] || count=$(<"$WINEFORGE_TEST_CURL_COUNT")
printf '%s\n' "$((count + 1))" > "$WINEFORGE_TEST_CURL_COUNT"
if [[ ${WINEFORGE_TEST_CURL_FAIL_ONCE:-0} == 1 && $count == 0 ]]; then
  head -c 32 "$WINEFORGE_TEST_SOURCE_ARCHIVE" > "$output"
  exit 7
fi
cp -- "$WINEFORGE_TEST_SOURCE_ARCHIVE" "$output"
EOF
cat > "$source_cache_test/bin/shasum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do file=$argument; done
if cmp -s -- "$file" "$WINEFORGE_TEST_SOURCE_ARCHIVE"; then
  digest=$WINEFORGE_TEST_SOURCE_SHA256
else
  digest=0000000000000000000000000000000000000000000000000000000000000000
fi
printf '%s  %s\n' "$digest" "$file"
EOF
chmod 755 "$source_cache_test/bin/curl" "$source_cache_test/bin/shasum"
source_sha256=$(jq -er '.source.sha256' "$repo_dir/engines/crossover-25.1.1.json")
for destination in first second; do
  if ! PATH="$source_cache_test/bin:$PATH" \
    WINEFORGE_SOURCE_CACHE="$source_cache_test/cache" \
    WINEFORGE_TEST_CURL_COUNT="$source_cache_test/curl-count" \
    WINEFORGE_TEST_SOURCE_ARCHIVE="$source_cache_test/source.tar.gz" \
    WINEFORGE_TEST_SOURCE_SHA256="$source_sha256" \
    "$repo_dir/scripts/fetch-source.sh" 25.1.1 "$source_cache_test/$destination" \
    >/dev/null; then
    printf 'source-cache fixture fetch failed\n' >&2
    failures=$((failures + 1))
    break
  fi
done
if [[ $(<"$source_cache_test/curl-count") != 1 ]]; then
  printf 'verified engine source was downloaded more than once\n' >&2
  failures=$((failures + 1))
fi

resume_test="$preparation_test/source-resume"
mkdir -p -- "$resume_test"
if PATH="$source_cache_test/bin:$PATH" \
  WINEFORGE_SOURCE_CACHE="$resume_test/cache" \
  WINEFORGE_TEST_CURL_COUNT="$resume_test/curl-count" \
  WINEFORGE_TEST_CURL_ARGUMENTS="$resume_test/curl-arguments" \
  WINEFORGE_TEST_CURL_FAIL_ONCE=1 \
  WINEFORGE_TEST_SOURCE_ARCHIVE="$source_cache_test/source.tar.gz" \
  WINEFORGE_TEST_SOURCE_SHA256="$source_sha256" \
  "$repo_dir/scripts/fetch-source.sh" 25.1.1 "$resume_test/failed" \
  >/dev/null 2>&1; then
  printf 'interrupted source download unexpectedly succeeded\n' >&2
  failures=$((failures + 1))
fi
if ! find "$resume_test/cache" -maxdepth 1 -type f -name '*.part' | grep -q .; then
  printf 'interrupted source download did not preserve its partial file\n' >&2
  failures=$((failures + 1))
fi
if ! PATH="$source_cache_test/bin:$PATH" \
  WINEFORGE_SOURCE_CACHE="$resume_test/cache" \
  WINEFORGE_TEST_CURL_COUNT="$resume_test/curl-count" \
  WINEFORGE_TEST_CURL_ARGUMENTS="$resume_test/curl-arguments" \
  WINEFORGE_TEST_CURL_FAIL_ONCE=1 \
  WINEFORGE_TEST_SOURCE_ARCHIVE="$source_cache_test/source.tar.gz" \
  WINEFORGE_TEST_SOURCE_SHA256="$source_sha256" \
  "$repo_dir/scripts/fetch-source.sh" 25.1.1 "$resume_test/resumed" \
  >/dev/null; then
  printf 'source download did not resume after interruption\n' >&2
  failures=$((failures + 1))
fi
if [[ $(<"$resume_test/curl-count") != 2 ]] || \
  ! grep -q -- '--continue-at -' "$resume_test/curl-arguments"; then
  printf 'source retry did not use the preserved partial download\n' >&2
  failures=$((failures + 1))
fi

if [[ $(uname -s) == Darwin ]]; then
  homebrew_setup_test="$preparation_test/homebrew-setup"
  mkdir -p -- "$homebrew_setup_test/prefix/bin"
  cat > "$homebrew_setup_test/prefix/bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --prefix) printf '%s\n' "$WINEFORGE_TEST_HOMEBREW_PREFIX" ;;
  list)
    [[ ! -f "$WINEFORGE_TEST_HOMEBREW_INSTALLED" ]] || \
      printf '%s 1.0\n' "${3:?missing formula}"
    ;;
  install)
    shift
    printf '%s\n' "$@" > "$WINEFORGE_TEST_HOMEBREW_INSTALL_LOG"
    : > "$WINEFORGE_TEST_HOMEBREW_INSTALLED"
    ;;
  *) exit 64 ;;
esac
EOF
  chmod 755 "$homebrew_setup_test/prefix/bin/brew"
  setup_command=("$repo_dir/scripts/setup-macos-deps.sh" --yes)
  if [[ $(uname -m) == arm64 ]]; then
    setup_command=(arch -x86_64 "${setup_command[@]}")
  fi
  for iteration in first second; do
    if ! WINEFORGE_INTEL_BREW="$homebrew_setup_test/prefix/bin/brew" \
      WINEFORGE_INTEL_BREW_PREFIX="$homebrew_setup_test/prefix" \
      WINEFORGE_TEST_HOMEBREW_PREFIX="$homebrew_setup_test/prefix" \
      WINEFORGE_TEST_HOMEBREW_INSTALLED="$homebrew_setup_test/installed" \
      WINEFORGE_TEST_HOMEBREW_INSTALL_LOG="$homebrew_setup_test/install-log" \
      "${setup_command[@]}" >"$homebrew_setup_test/$iteration-output"; then
      printf 'Intel Homebrew dependency setup fixture failed\n' >&2
      failures=$((failures + 1))
      break
    fi
  done
  if [[ $(wc -l < "$homebrew_setup_test/install-log") -ne 7 ]] || \
    ! grep -q 'already installed' "$homebrew_setup_test/second-output"; then
    printf 'Intel Homebrew dependency setup was not idempotent\n' >&2
    failures=$((failures + 1))
  fi
fi

macos_preflight_test="$preparation_test/macos-preflight"
mkdir -p -- "$macos_preflight_test/bin" "$macos_preflight_test/brew/include" \
  "$macos_preflight_test/brew/lib" "$macos_preflight_test/brew/llvm/bin" \
  "$macos_preflight_test/brew/bison/bin"
printf 'synthetic arm64 library\n' > "$macos_preflight_test/brew/lib/libfreetype.dylib"
cat > "$macos_preflight_test/bin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --prefix)
    case "${2:-}" in
      '') printf '%s\n' "$WINEFORGE_TEST_BREW_PREFIX" ;;
      llvm) printf '%s\n' "$WINEFORGE_TEST_BREW_PREFIX/llvm" ;;
      bison) printf '%s\n' "$WINEFORGE_TEST_BREW_PREFIX/bison" ;;
      *) printf '%s\n' "$WINEFORGE_TEST_BREW_PREFIX" ;;
    esac
    ;;
  list)
    [[ ${WINEFORGE_TEST_MISSING_FORMULAE:-0} == 1 ]] || \
      printf '%s 1.0\n' "${3:-formula}"
    ;;
  *) exit 64 ;;
esac
EOF
cat > "$macos_preflight_test/bin/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${*: -1}" in
  *libfreetype*) printf '%s: Mach-O 64-bit dynamically linked shared library %s\n' \
    "${*: -1}" "${WINEFORGE_TEST_FREETYPE_ARCH:-arm64}" ;;
  *) exec /usr/bin/file "$@" ;;
esac
EOF
cat > "$macos_preflight_test/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "$WINEFORGE_TEST_CURL_MARKER"
exit 99
EOF
chmod 755 "$macos_preflight_test/bin/brew" "$macos_preflight_test/bin/file" \
  "$macos_preflight_test/bin/curl"
if PATH="$macos_preflight_test/bin:$PATH" \
  WINEFORGE_BREW="$macos_preflight_test/bin/brew" \
  WINEFORGE_TEST_BREW_PREFIX="$macos_preflight_test/brew" \
  WINEFORGE_TEST_CURL_MARKER="$macos_preflight_test/curl-called" \
  WINEFORGE_WORK_DIR="$macos_preflight_test/work" \
  WINEFORGE_DIST_DIR="$macos_preflight_test/dist" \
  "$repo_dir/scripts/build-engine.sh" 25.1.1 macos-x86_64 \
  >"$macos_preflight_test/output" 2>&1; then
  printf 'arm64 dependency preflight unexpectedly succeeded\n' >&2
  failures=$((failures + 1))
fi
if [[ -e "$macos_preflight_test/curl-called" ]] || \
  ! grep -q 'FreeType.*x86_64' "$macos_preflight_test/output"; then
  printf 'macOS dependency architecture was not rejected before download\n' >&2
  failures=$((failures + 1))
fi
rm -f -- "$macos_preflight_test/curl-called"
if PATH="$macos_preflight_test/bin:$PATH" \
  WINEFORGE_BREW="$macos_preflight_test/bin/brew" \
  WINEFORGE_TEST_BREW_PREFIX="$macos_preflight_test/brew" \
  WINEFORGE_TEST_CURL_MARKER="$macos_preflight_test/curl-called" \
  WINEFORGE_TEST_FREETYPE_ARCH=x86_64 \
  WINEFORGE_TEST_MISSING_FORMULAE=1 \
  WINEFORGE_WORK_DIR="$macos_preflight_test/missing-work" \
  WINEFORGE_DIST_DIR="$macos_preflight_test/missing-dist" \
  "$repo_dir/scripts/build-engine.sh" 25.1.1 macos-x86_64 \
  >"$macos_preflight_test/missing-output" 2>&1; then
  printf 'missing dependency preflight unexpectedly succeeded\n' >&2
  failures=$((failures + 1))
fi
if [[ -e "$macos_preflight_test/curl-called" ]] || \
  ! grep -q 'bison jq llvm mingw-w64 pkg-config freetype gnutls' \
    "$macos_preflight_test/missing-output"; then
  printf 'macOS dependencies were not reported together before download\n' >&2
  failures=$((failures + 1))
fi

loader_test="$preparation_test/macos-loader"
mkdir -p -- "$loader_test/bin"
printf 'synthetic loader\n' > "$loader_test/bin/wine"
chmod 755 "$loader_test/bin/wine"
"$repo_dir/scripts/normalize-macos-loader.sh" "$loader_test"
"$repo_dir/scripts/normalize-macos-loader.sh" "$loader_test"
if [[ ! -x "$loader_test/bin/wineloader" || ! -L "$loader_test/bin/wine" || \
      $(readlink "$loader_test/bin/wine") != wineloader ]]; then
  printf 'macOS loader names were not normalized idempotently\n' >&2
  failures=$((failures + 1))
fi

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

if ! grep -Fq '+            if (check_bus_option(L"Enable IOHID", 0)) iohid_driver_init();' \
  "$repo_dir/patches/24.0.7/0007-winebus-disable-iohid-by-default.patch"; then
  printf 'macOS IOHID backend is not disabled by default\n' >&2
  failures=$((failures + 1))
fi

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
