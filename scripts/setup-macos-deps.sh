#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 022

usage() {
  printf 'usage: %s [--yes]\n' "$0" >&2
}

assume_yes=0
while (( $# )); do
  case "$1" in
    --yes) assume_yes=1; shift ;;
    *) usage; exit 64 ;;
  esac
done

[[ $(uname -s) == Darwin ]] || {
  printf 'Intel Homebrew setup is available only on macOS\n' >&2
  exit 69
}
[[ $(uname -m) == x86_64 ]] || {
  printf 'Intel Homebrew setup must run under Rosetta (x86_64)\n' >&2
  exit 69
}

intel_brew=${WINEFORGE_INTEL_BREW:-/usr/local/bin/brew}
expected_prefix=${WINEFORGE_INTEL_BREW_PREFIX:-/usr/local}
formulae=(bison freetype gnutls jq llvm mingw-w64 pkg-config)

confirm_setup() {
  local answer
  if (( assume_yes )); then return 0; fi
  if [[ ! -t 0 ]]; then
    printf 'Intel Homebrew is missing; rerun with --setup-macos-deps after reviewing the setup notice\n' >&2
    return 1
  fi
  printf '\nWineforge needs x86_64 build dependencies.\n'
  printf 'It will install Intel Homebrew in /usr/local and will not modify Apple Silicon Homebrew in /opt/homebrew.\n'
  printf 'The official installer may request administrator access to prepare /usr/local.\n'
  printf 'Continue? [y/N] '
  IFS= read -r answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}

if [[ ! -x "$intel_brew" ]]; then
  if [[ "$intel_brew" != /usr/local/bin/brew ]]; then
    printf 'configured Intel Homebrew executable does not exist: %s\n' "$intel_brew" >&2
    exit 69
  fi
  if [[ -e /usr/local/Homebrew || -L /usr/local/bin/brew ]]; then
    printf 'an incomplete or ambiguous Homebrew installation exists beneath /usr/local\n' >&2
    printf 'Wineforge will not overwrite it; repair or remove it manually, then retry\n' >&2
    exit 73
  fi
  confirm_setup || {
    printf 'Intel Homebrew setup was not approved\n' >&2
    exit 69
  }

  printf 'Installing Intel Homebrew in /usr/local. Apple Silicon Homebrew in /opt/homebrew is separate and unchanged.\n'
  if ! /usr/bin/sudo -n -v 2>/dev/null; then
    printf 'Administrator access is needed once to prepare /usr/local.\n'
    /usr/bin/sudo -v
  fi
  installer_dir=$(mktemp -d "${TMPDIR:-/tmp}/wineforge-homebrew-install.XXXXXX")
  cleanup() { rm -rf -- "$installer_dir"; }
  trap cleanup EXIT HUP INT TERM
  /usr/bin/curl --fail --silent --show-error --location \
    --output "$installer_dir/install.sh" \
    https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
  NONINTERACTIVE=1 CI=1 /bin/bash "$installer_dir/install.sh"
  trap - EXIT HUP INT TERM
  cleanup
fi

actual_prefix=$("$intel_brew" --prefix)
if [[ "$actual_prefix" != "$expected_prefix" ]]; then
  printf 'refusing unexpected Intel Homebrew prefix: %s (expected %s)\n' \
    "$actual_prefix" "$expected_prefix" >&2
  exit 69
fi

missing_formulae=()
for formula in "${formulae[@]}"; do
  if [[ -z $("$intel_brew" list --versions "$formula" 2>/dev/null) ]]; then
    missing_formulae+=("$formula")
  fi
done

if (( ${#missing_formulae[@]} )); then
  printf 'Installing missing Intel Homebrew build dependencies:'
  printf ' %s' "${missing_formulae[@]}"
  printf '\n'
  "$intel_brew" install "${missing_formulae[@]}"
else
  printf 'Intel Homebrew build dependencies are already installed.\n'
fi

printf 'Intel Homebrew is ready at %s. Apple Silicon Homebrew was not modified.\n' \
  "$actual_prefix"
