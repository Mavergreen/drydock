# Build ingredients

Everything baked into the shipped artifacts, and how a change to it reaches a
release. An *ingredient* is an input to the product; the *own upstream* is the
thing this repo exists to port.

This repo is unusual in the family: **it is its own upstream.** The six tools are
not a port of somebody else's project — they were written for this problem, and
`Mavericks-Porting-Resources` is where they lived before, not what they track.

| Ingredient | Pinned in | Renovate | On a bump |
|---|---|---|---|
| the six tools' C sources (own upstream) | `UPSTREAM_VERSION`, bumped by hand | **untrackable** — nothing external releases them; they are this repo | a hand bump, then a dispatch of `release.yml` with `release=true`, cuts the release as tag `v0.3.0` |
| MacOSX10.9 SDK (x86_64) and MacOSX11.3 SDK (arm64), CMake helpers, compat guard, test runner; on Linux, the 10.9 SDK's `mach-o/` and `mach/` headers the Linux build compiles against | `Mavergreen/shipyard@v1` | ✅ github-actions manager tracks the tag | `@v1` is a *moving* tag: content changes without the pin changing, so nothing auto-repackages |
| Sparkle 1.27.3, in the updater | shipyard's `fetch_sparkle_framework.sh`, pinned by hash there | **untrackable** here: shipyard owns that pin | follows shipyard |
| Linux build image: ubuntu 26.04's gcc, glibc and CMake (build the Linux archive) | `release.yml`'s `linux` job `container:`, `ubuntu:26.04` pinned by digest; `build-info-linux-x86_64.txt` records `build-image`, `build-cc`, `build-libc` and `build-cmake` | ✅ Renovate's github-actions manager tracks the image and its digest | a new image rebuilds and retests the archive; it ships with the next dispatched release. The executable must ask for no x86 ISA level above `x86-64-baseline` (the job builds with `-march=x86-64` and fails on anything higher, as the GitHub runner image's own toolchain gave: `x86-64-v3`, which needs AVX2), and needs a glibc at least as new as the newest `GLIBC_` symbol version it references (2.34 as of 0.3.0); build-info records both as `isa-needed` and `glibc-needed` |
| clang22 22.1.8-mavericks.16's `clang-c` headers, which `drydock-objc receipt` compiles against (nothing of clang22 ships; receipt loads the libclang it is told to at run time; on Linux that libclang, shipped in the archive from .16, needs glibc 2.35 or newer) | `components/objc-receipt-clang/version`, plus `linux-sha256` beside it for the Linux archive | ✅ a custom manager in `.github/renovate.json` tracks `Mavergreen/clang-22` | a bump rebuilds `drydock-objc`; Renovate cannot write `linux-sha256`, so the pins bot writes it on the bump's branch; it ships with the next dispatched release |
| Jansson 2.15.1, the JSON parser compiled into `drydock-objc` (fetched at configure time as GitHub's tarball of the pinned commit, never vendored; its MIT licence ships as `share/doc/drydock/LICENSE-jansson`) | `components/jansson/version`: `REPO`, `REF`, `DIGEST` and the tarball's `SHA256` | ✅ a `git-refs` custom manager in `.github/renovate.json` moves `REF` and `DIGEST` together; `.github/workflows/pins-bot.yml` writes `SHA256` on the bump's branch | a bump changes the analyzer id (the pin is one of its inputs) and rebuilds `drydock-objc`; it ships with the next dispatched release |
| Longboat (CI only: `release.yml`'s `on-target` installs it in the 10.9 guest and runs `longboat sdk install 10.9`, because the clang22 pkg requires its sdk109; nothing of it ships) | `components/longboat/version` | ✅ a custom manager in `.github/renovate.json` tracks `Mavergreen/longboat` | no release: nothing shipped changes |
| Make (CI only: `release.yml`'s `on-target` installs it in the 10.9 guest, because the guest has no Command Line Tools and so no make; nothing of it ships) | `components/make/version` | ✅ a custom manager in `.github/renovate.json` tracks `Mavergreen/make` | no release: nothing shipped changes |
| MacPorts' `libMacportsLegacySupport.a` (CI only: `on-target` unpacks `macports-legacy-support-<version>.pkg`, a `Mavergreen/recaulk` release from before it became Recaulk, in the 10.9 guest and points `LEGACYSUPPORT_A` at it for `legacysupport_rename_test`; nothing of it ships) | `components/macports-legacy-support/version` (`1.5.2-mavericks.6`) | ❌ **untrackable**: retired product line; no current Mavergreen release publishes the un-renamed archive (recaulk builds the same upstream v1.5.2 internally). Reconsider when recaulk's components/macports-legacy-support REF leaves v1.5.2 or recaulk publishes the archive | no release: nothing shipped changes |
| macFUSE 5.5.0's `macfuse-5.5.0-debug.tbz`, from `macfuse/macfuse`'s GitHub release (CI only: `release.yml`'s `modern-smoke` and `linux` jobs fetch it, verify it with `shasum -a 256 -c`, cache it by its pin, and point `MACFUSE_DEBUG_TBZ` at it for `macfuse_golden_test`, which runs `vnodeop replace` on its x86_64 kext; nothing of it ships, and nothing from it is executed) | `components/macfuse-debug/version` (`5.5.0`) and `components/macfuse-debug/sha256` | ❌ **untrackable**, by design: the test's golden sha256 is the output for exactly these bytes, so a newer macFUSE would fail it rather than test it. Reconsider when a newer kext needs `vnodeop replace` and has its own golden | no release: nothing shipped changes |
| `tests/fixture.macho` + `tests/EXPECTED` | committed | **untrackable** — a characterization reference, deliberately frozen | never bumped by a bot; changing it is a deliberate commit that says why |

Not ingredients: `CMakeLists.txt`, the test scripts and the workflows are this
repo's own recipe. A change there is a repackage you cut deliberately. So is
`linux/include/`: this repo's own stand-ins, for the Linux build only, for the
Apple headers the SDK's `mach-o/` and `mach/` headers include and for the three
Apple APIs `src/` calls (`CC_SHA256`, `OSSwapInt32`, and the extended-attribute
calls' Apple argument lists).

## Conformance deviations

`check-artifact-conformance.sh`'s `scheme` check is repo-wide, not per-artifact, so it is declared
unscoped (`- scheme: <reason>`), the same way `mavericks-shipyard`'s own self-upstream deviation is:

- scheme: this repo is its own upstream (no external thing to repackage), so it versions itself directly as semver vX.Y.Z per the self-upstream rule (tag `v0.1.0` for `UPSTREAM_VERSION` `0.1.0`), and there is no -mavericks.N axis to carry. The reason for semver over a date: users write scripts in Drydock's language; a major version says when those may break, which a date cannot.
- arm64:*/bin/drydock-objc: shipyard's compat guard runs `drydock-objc` in product CI on Apple Silicon (macos-26) runners, and developers on Apple Silicon Macs run it to investigate Mavericks artifacts; both need a native arm64 slice. The slice is built on Linux by `release.yml`'s `build` job, and exercised and accepted by its `modern-smoke` job (family check 37), which installs the run's pkg on Apple Silicon and runs the suite, the `objc_` ctest entries among them, natively against the installed arm64 tools.
- macos-runner:release.yml:modern-smoke: it installs the Linux-built pkg on Apple Silicon, runs every installed tool and the standalone archive's, runs the suite on the installed arm64 tools, then `apple_silicon_signing_test`, `chained-fixups.sh`, `macfuse_golden_test.sh`, `characterize.sh check` and equivalence's macos-arm64 outputs; arm64 Mach-O runs only on Apple Silicon macOS. Exit: none while `drydock-objc` ships an arm64 slice (check 37 puts this job on a macos-* runner).
- macos-runner:nib-fixtures.yml:compile: `ibtool` exists only in Xcode, which runs only on macOS, and the fixtures must come from a current Xcode to be NIBArchive nibs. The job runs on the pinned `xcode-27` runner image (macOS 27) with its newest non-beta Xcode, and only by dispatch, never on push. Exit: the compiled fixtures and their digests (`tests/resources/fixtures/MANIFEST.tsv`, which records the exact Xcode version and build) are committed, so no test ever needs macOS for them; re-dispatch only when a fixture XIB, or the pinned runner image or its Xcode, changes.
- on-target:updater: `on-target` installs the pkg in the 10.9 guest and runs every tool in its `bin/`, but not `drydock-updater.app`: a GUI app with no non-GUI mode, so nothing there can run it and see it answer, and its x86_64 slice goes unexercised in CI. Reconsider when shipyard's updater gains a headless probe.

## Why there is no Renovate customManager for the own upstream

Every other repo in the family points a customManager at `UPSTREAM_VERSION` so a
new upstream release opens a bump PR that, once green, cuts a release. There is
nothing to point one at here: no external project publishes these tools, so
there is no datasource that could observe a new version. The pin moves when a
human decides it has, which is the honest arrangement rather than a missing one.

That is also why a release is published by **workflow_dispatch** rather than
auto-cut-on-main: with no upstream bump to trigger it, a release is always a
deliberate act. The tag is derived (`v` plus `UPSTREAM_VERSION`) and created by
the publish, so a tag can never disagree with the version the binaries report.

## Why `tests/EXPECTED` is an ingredient

It is the digest of what the whole pipeline produces from `tests/fixture.macho`,
**recorded from a native build on real 10.9 hardware**. CI has no 10.9 runner, so
every build there is a cross-build; comparing its output against that digest is
what makes "cross ≡ native" checkable. Treating it as an ingredient is the point:
it must change only when someone means it to.

## Upstream release notes

No upstream release notes: Drydock is its own upstream (original Mavergreen code), so
there are no someone-else's notes for a release to link.
