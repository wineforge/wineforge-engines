#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 022

if (( $# != 2 )); then
  printf 'usage: %s VERSION TARGET\n' "$0" >&2
  exit 64
fi

version=$1
target=$2
repo_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
manifest="$repo_dir/engines/crossover-$version.json"
work_dir=${WINEFORGE_WORK_DIR:-"$repo_dir/work/$version-$target"}
dist_dir=${WINEFORGE_DIST_DIR:-"$repo_dir/dist"}

case "$target" in
  linux-x86_64) expected_host='x86_64-linux-gnu' ;;
  macos-x86_64) expected_host='x86_64-apple-darwin' ;;
  *) printf 'unsupported target: %s\n' "$target" >&2; exit 64 ;;
esac

# CrossOver 24 sources use `bool` as a C identifier. GCC 15 defaults to C23,
# where `bool` is a keyword, so keep PE compilation on the source-compatible
# language version. Callers may override this for newer source trees.
export CROSSCFLAGS=${CROSSCFLAGS:-'-g -O2 -std=gnu17'}

[[ -f "$manifest" ]] || { printf 'unsupported version: %s\n' "$version" >&2; exit 64; }

configure_args=(
  --prefix=/
  "--host=$expected_host"
)
if [[ "$target" == macos-x86_64 ]]; then
  # Modern WoW64 keeps the Unix runtime 64-bit while producing both i386 and
  # x86_64 Windows modules for PE32 compatibility on current macOS.
  configure_args+=(--enable-archs=i386,x86_64 --without-alsa --without-cups --without-dbus --without-oss --without-pulse --without-sane --without-wayland --without-x)
else
  configure_args+=(--enable-win64)
fi

if [[ ${DRY_RUN:-0} == 1 ]]; then
  printf 'version=%s\ntarget=%s\ncross_cflags=%s\nconfigure=' \
    "$version" "$target" "$CROSSCFLAGS"
  printf ' %q' "${configure_args[@]}"
  printf '\n'
  exit 0
fi

required_commands=(curl file jq make patch python3 shasum tar)
missing_commands=()
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || missing_commands+=("$command_name")
done
if (( ${#missing_commands[@]} != 0 )); then
  printf 'missing commands required for the engine build:' >&2
  printf ' %s' "${missing_commands[@]}" >&2
  printf '\n' >&2
  exit 69
fi

make_command=make
make_arguments=(-j "${WINEFORGE_JOBS:-2}")
if [[ "$target" == macos-x86_64 ]]; then
  brew_command=${WINEFORGE_BREW:-}
  if [[ -z "$brew_command" && -x /usr/local/bin/brew ]]; then
    brew_command=/usr/local/bin/brew
  elif [[ -z "$brew_command" ]]; then
    brew_command=$(command -v brew || true)
  fi
  [[ -n "$brew_command" && -x "$brew_command" ]] || {
    printf 'Homebrew is required for macOS engine builds\n' >&2
    printf 'rerun build-local.sh with --setup-macos-deps to install the Intel toolchain\n' >&2
    exit 69
  }
  brew_prefix=$("$brew_command" --prefix)
  dependency_prefix=${WINEFORGE_DEPS_PREFIX:-$brew_prefix}
  if [[ -z ${WINEFORGE_DEPS_PREFIX:-} && "$brew_prefix" == /opt/homebrew ]]; then
    printf 'the selected Homebrew prefix contains Apple Silicon libraries, but the engine build requires x86_64\n' >&2
    printf 'rerun build-local.sh with --setup-macos-deps, or set WINEFORGE_DEPS_PREFIX to an isolated x86_64 prefix\n' >&2
    exit 69
  fi
  [[ -d "$dependency_prefix/include" && -d "$dependency_prefix/lib" ]] || {
    printf 'invalid macOS dependency prefix: %s\n' "$dependency_prefix" >&2
    exit 69
  }

  required_formulae=(bison jq llvm mingw-w64 pkg-config)
  if [[ -z ${WINEFORGE_DEPS_PREFIX:-} ]]; then
    required_formulae+=(freetype gnutls)
  else
    required_formulae+=(make bash)
  fi
  missing_formulae=()
  for formula in "${required_formulae[@]}"; do
    if [[ -z $("$brew_command" list --versions "$formula" 2>/dev/null) ]]; then
      missing_formulae+=("$formula")
    fi
  done
  if (( ${#missing_formulae[@]} != 0 )); then
    printf 'missing Homebrew formulae for the macOS engine build:' >&2
    printf ' %s' "${missing_formulae[@]}" >&2
    printf '\nrerun build-local.sh with --setup-macos-deps, or install them together with: %q install' "$brew_command" >&2
    printf ' %q' "${missing_formulae[@]}" >&2
    printf '\n' >&2
    exit 69
  fi

  freetype_library=
  for candidate in "$dependency_prefix/lib/libfreetype.dylib" \
    "$dependency_prefix/lib/libfreetype.6.dylib"; do
    if [[ -f "$candidate" ]]; then
      freetype_library=$candidate
      break
    fi
  done
  if [[ -z "$freetype_library" ]]; then
    printf 'FreeType x86_64 library not found beneath dependency prefix %s\n' \
      "$dependency_prefix" >&2
    exit 69
  fi
  freetype_description=$(file "$freetype_library")
  if [[ "$freetype_description" != *x86_64* ]]; then
    printf 'FreeType must provide x86_64 libraries for the Rosetta build: %s\n' \
      "$freetype_description" >&2
    printf 'use Intel Homebrew in /usr/local or set WINEFORGE_DEPS_PREFIX to an isolated x86_64 prefix\n' >&2
    exit 69
  fi

  export CC='clang -arch x86_64'
  export CXX='clang++ -arch x86_64'
  llvm_prefix=$("$brew_command" --prefix llvm)
  export AR="$llvm_prefix/bin/llvm-ar"
  export RANLIB="$llvm_prefix/bin/llvm-ranlib"
  export PATH="$llvm_prefix/bin:$("$brew_command" --prefix bison)/bin:$PATH"
  export PKG_CONFIG_PATH="$dependency_prefix/lib/pkgconfig:$dependency_prefix/share/pkgconfig:${PKG_CONFIG_PATH:-}"
  if [[ -z ${WINEFORGE_DEPS_PREFIX:-} ]]; then
    export CPPFLAGS="-I$dependency_prefix/include ${CPPFLAGS:-}"
    export LDFLAGS="-L$dependency_prefix/lib ${LDFLAGS:-}"
  else
    export DYLD_LIBRARY_PATH="$dependency_prefix/lib:${DYLD_LIBRARY_PATH:-}"
    make_command=$("$brew_command" --prefix make)/bin/gmake
    make_shell=$("$brew_command" --prefix bash)/bin/bash
    make_arguments+=("SHELL=$make_shell")
  fi
fi

if [[ -e "$work_dir" ]]; then
  printf 'work directory already exists: %s\n' "$work_dir" >&2
  exit 73
fi
mkdir -p -- "$work_dir" "$dist_dir"
"$repo_dir/scripts/fetch-source.sh" "$version" "$work_dir/source"

source_subdirectory=$(jq -er '.build.source_subdirectory' "$manifest")
source_dir="$work_dir/source/$source_subdirectory"
build_dir="$work_dir/build"
stage_dir="$work_dir/stage"
mkdir -p -- "$build_dir" "$stage_dir"
"$repo_dir/scripts/prepare-source.sh" "$source_dir"

patch_evidence='[]'
while IFS= read -r patch_spec; do
  patch_path=$(jq -er '.path' <<<"$patch_spec")
  expected_patch_sha256=$(jq -er '.sha256' <<<"$patch_spec")
  case "$patch_path" in
    "patches/$version/"*.patch) ;;
    *) printf 'unsafe patch path: %s\n' "$patch_path" >&2; exit 65 ;;
  esac
  patch_file="$repo_dir/$patch_path"
  if [[ ! -f "$patch_file" || -L "$patch_file" ]]; then
    printf 'unsafe or missing patch: %s\n' "$patch_path" >&2
    exit 65
  fi
  actual_patch_sha256=$(shasum -a 256 "$patch_file" | awk '{print $1}')
  if [[ "$actual_patch_sha256" != "$expected_patch_sha256" ]]; then
    printf 'patch digest mismatch for %s\n' "$patch_path" >&2
    exit 65
  fi
  patch --batch --forward --directory="$source_dir" -p1 --input="$patch_file"
  patch_evidence=$(jq -c \
    --arg path "$patch_path" \
    --arg sha256 "$actual_patch_sha256" \
    '. + [{path: $path, sha256: $sha256}]' <<<"$patch_evidence")
done < <(jq -c --arg target "$target" \
  '.build.patches[] | select(.targets | index($target))' "$manifest")

(
  cd "$build_dir"
  "$source_dir/configure" "${configure_args[@]}"
  "$make_command" "${make_arguments[@]}" install DESTDIR="$stage_dir"
)

if [[ "$target" == macos-x86_64 ]]; then
  "$repo_dir/scripts/normalize-macos-loader.sh" "$stage_dir"
fi

wine_binary=$(find -L "$stage_dir" -type f \( -name wine -o -name wine64 \) -perm -111 -print | LC_ALL=C sort | head -1)
[[ -n "$wine_binary" ]] || { printf 'installed Wine executable not found\n' >&2; exit 70; }
binary_description=$(file "$wine_binary")
case "$target:$binary_description" in
  linux-x86_64:*ELF*x86-64*|macos-x86_64:*Mach-O*64-bit*x86_64*) ;;
  *) printf 'unexpected runtime architecture: %s\n' "$binary_description" >&2; exit 70 ;;
esac

if [[ "$target" == macos-x86_64 && -n ${WINEFORGE_DEPS_PREFIX:-} ]]; then
  runtime_library_dir="$stage_dir/lib/wine/x86_64-unix"
  mkdir -p -- "$runtime_library_dir"
  find "$dependency_prefix/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.dylib' \
    -exec cp -RP {} "$runtime_library_dir/" \;
fi

wine_relative=${wine_binary#"$stage_dir"/}
if [[ "$target" == macos-x86_64 ]]; then
  "$repo_dir/scripts/smoke-engine.sh" "$stage_dir" "$wine_relative" --require-wow64
else
  "$repo_dir/scripts/smoke-engine.sh" "$stage_dir" "$wine_relative"
fi

mkdir -p -- "$stage_dir/share/wineforge/licenses"
find "$source_dir" -maxdepth 2 -type f \
  \( -iname 'copying*' -o -iname 'license*' -o -iname 'authors*' \) \
  -exec cp -p {} "$stage_dir/share/wineforge/licenses/" \;

source_sha256=$(jq -er '.source.sha256' "$manifest")
source_date_epoch=$(jq -er '.source.source_date_epoch' "$manifest")
compiler_command=${CC:-cc}
compiler_command=${compiler_command%% *}
jq -n \
  --arg version "$version" \
  --arg target "$target" \
  --arg source_sha256 "$source_sha256" \
  --arg source_url "$(jq -er '.source.url' "$manifest")" \
  --arg runner_image "${ImageOS:-unknown}-${ImageVersion:-unknown}" \
  --arg binary_description "$binary_description" \
  --arg configure "$(printf '%q ' "${configure_args[@]}")" \
  --argjson patches "$patch_evidence" \
  --arg cc "$($compiler_command --version 2>/dev/null | head -1 || true)" \
  --arg make "$($make_command --version | head -1)" \
  '{schema_version: 1, version: $version, target: $target,
    source: {url: $source_url, sha256: $source_sha256},
    builder: {runner_image: $runner_image, compiler: $cc, make: $make},
    configure: $configure, source_patches: $patches,
    executable: $binary_description}' \
  > "$stage_dir/share/wineforge/build-info.json"

artifact="$dist_dir/wineforge-engine-$version-$target.tar.gz"
python3 "$repo_dir/scripts/package.py" "$stage_dir" "$artifact" --mtime "$source_date_epoch"
artifact_name=$(basename "$artifact")
artifact_sha256=$(shasum -a 256 "$artifact" | awk '{print $1}')
case "$target" in
  linux-x86_64)
    runtime_platform='linux-x86-64'
    translation='native'
    ;;
  macos-x86_64)
    runtime_platform='macos-x86-64'
    translation='rosetta2'
    ;;
esac
jq -n \
  --arg id "crossover-$version-$target" \
  --arg platform "$runtime_platform" \
  --arg translation "$translation" \
  --arg sha256 "$artifact_sha256" \
  --arg wine_binary "$wine_relative" \
  '{schema_version: 1, id: $id, platform: $platform,
    host_architecture: "x86_64", translation: $translation,
    artifact: {source: {kind: "user-supplied"}, sha256: $sha256},
    wine_binary: $wine_binary,
    environment: {WINEESYNC: "1", WINEMSYNC: "1"},
    license: {
      name: "CrossOver component licences",
      url: "https://www.codeweavers.com/crossover/source",
      acceptance_required: false
    }}' > "$dist_dir/$artifact_name.runtime.json"
(
  cd "$dist_dir"
  printf '%s  %s\n' "$artifact_sha256" "$artifact_name" > "$artifact_name.sha256"
)
python3 "$repo_dir/scripts/generate-reference.py" \
  "$stage_dir" "$artifact" \
  "$dist_dir/wineforge-engine-$version-$target.reference.json"
printf 'created %s\n' "$artifact"
