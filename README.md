# Wineforge Engines

Auditable build recipes for Wine-compatible runtimes. This repository contains
manifests, CI workflows, and build tooling; it does not contain third-party
source archives or runtime binaries in Git history.

The first supported source families are CodeWeavers CrossOver sources 24.0.7
and 25.1.1. A version produces separate artifacts:

- `linux-x86_64`, executed natively on x86-64 Linux;
- `macos-x86_64`, an Intel Mach-O runtime that Apple Silicon can execute through
  Rosetta 2.

One source version does **not** imply one byte-identical cross-platform binary.
The manifests describe a source input; the platform build records describe the
derived artifacts and their build environments.

## Trust model

Every build:

1. downloads source from the manifest's HTTPS URL;
2. verifies its pinned SHA-256 before extraction;
3. rejects unsafe archive paths;
4. verifies and applies the manifest's version- and target-scoped source patches;
5. builds Wine's install dependency graph on a platform-specific GitHub-hosted
   runner, excluding test-only executables from runtime builds;
6. records the runner image, tools, configuration, source and patch digests,
   and artifact digest in `build-info.json`;
7. emits an SPDX JSON SBOM and SHA-256 checksum;
8. uploads GitHub artifact attestations for both the runtime and SBOM; and
9. uploads a reference record and SBOM, while keeping compiled engine upload
   disabled by default.

Each artifact also includes a `*.runtime.json` manifest for Wineforge. The
manifest contains the archive digest, target platform, translation mode and the
runtime-relative Wine executable path. It is generated only after packaging so
its digest describes the exact archive delivered to the user.

The pinned source digests were independently calculated from the official
CodeWeavers HTTPS archive on 2026-08-13. CodeWeavers did not publish checksum
sidecars at the corresponding `.sha256` URLs, so these are repository trust
pins, not publisher signatures. Maintainers must verify a source change through
an independently authenticated channel before changing a digest.

Attestation proves which workflow produced bytes; it does not prove that source
or output is free of vulnerabilities. See [SECURITY.md](SECURITY.md).

## Build locally

Normal development validation is intentionally lightweight:

```sh
./scripts/validate.sh
DRY_RUN=1 ./scripts/build-engine.sh 25.1.1 linux-x86_64
```

Use **Actions → Build engines → Run workflow** for shared verification. The
workflow can build one version for both platforms without uploading compiled
engines. Release publication is separately gated by the protected `release`
environment and the manifest's `redistribution.status` field.

To retain compiled engines from Actions for private use, run the workflow from
a **private fork** and enable `upload_engine_artifacts`. Public repositories
refuse that option unless the same run is publishing a separately approved
release. This keeps the auditable build workflow reusable without turning the
public upstream repository into a binary redistribution channel.

For an independent local build, Linux uses a digest-pinned Podman/Docker image
and macOS uses the native host toolchain:

```sh
./scripts/build-local.sh 24.0.7 linux-x86_64 --runtime podman
./scripts/build-local.sh 24.0.7 macos-x86_64
```

Apple Silicon hosts may supply an isolated x86_64 library prefix with
`WINEFORGE_DEPS_PREFIX`. Host build tools still come from Homebrew, while
dependency flags are resolved from that prefix's pkg-config metadata. This
keeps third-party library search paths out of Wine's freestanding preloader.
Homebrew `make` and `bash` are required for this mode so macOS does not strip
the dependency environment before running build-time helpers.
`build-local.sh` automatically re-executes under Rosetta and selects Apple's
classic linker compatibility mode when the host is Apple Silicon.

Every build must initialize a disposable fresh prefix and run `cmd /c ver`
before packaging. A compiler-successful engine that cannot load its Windows
runtime is rejected and no artifact is emitted. CrossOver 24 additionally
includes a compatibility backport that keeps delay-load IAT pointers in a
writable `.didat` section when building with modern Binutils.

macOS builds use Wine's combined `i386,x86_64` architecture mode and also run
the 32-bit `syswow64\\cmd.exe` during acceptance. This keeps the Unix runtime
64-bit for current macOS while proving that PE32 applications work before an
artifact is created.

Managed output is stored under `local-builds/` by default. It includes the
engine, runtime manifest, checksum, reference record, work tree, and a marker
understood by `wineforge engine prune-artifacts`. See
[docs/reproducibility.md](docs/reproducibility.md) for CI comparison.

## CI dependency policy

Action dependencies are pinned to immutable commit SHAs. System toolchains are
selected by an explicit runner label and package list. GitHub-hosted macOS images
are rolling rather than content-addressed, so current builds are auditable but
not claimed byte-for-byte reproducible. Each build captures the exact image and
tool versions. The next hardening milestone is a signed, content-addressed Linux
builder image and a versioned macOS toolchain bundle; see
[docs/reproducibility.md](docs/reproducibility.md).

## Verify a downloaded artifact

```sh
shasum -a 256 -c wineforge-engine-25.1.1-macos-x86_64.tar.gz.sha256
gh attestation verify wineforge-engine-25.1.1-macos-x86_64.tar.gz \
  --repo OWNER/wineforge-engines
```

## Licensing

The build automation is MIT licensed. CrossOver source and each bundled
component retain their own licences. A click-through or user acceptance does
not create redistribution rights. Runtime releases remain disabled until a
reviewed licence inventory marks the relevant manifest `approved`. See
[THIRD_PARTY.md](THIRD_PARTY.md).
