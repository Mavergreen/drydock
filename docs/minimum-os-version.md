# The declared minimum OS version

What a Mach-O's declared minimum OS (`LC_VERSION_MIN_MACOSX.version`,
`LC_BUILD_VERSION.minos`) and its `sdk` field have meant across macOS eras,
what each OS actually does with them, and why that matters for Drydock.

Researched 2026-09-23. Every claim is tagged:

- **SOURCED**: with a link, or a file in a named upstream release.
- **MEASURED**: on a 10.9.5 host (13F1911), with the command or method.
- **INFERRED**: reasoning or recollection that was not checked.

Upstream sources:
- dyld: [apple-oss-distributions/dyld](https://github.com/apple-oss-distributions/dyld), tags `dyld-239.4` (10.9) through `dyld-1340`.
- ld64: [apple-oss-distributions/ld64](https://github.com/apple-oss-distributions/ld64).
- xnu: [apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu).
- CF: [apple-oss-distributions/CF](https://github.com/apple-oss-distributions/CF), `CF-855`.
- [nfzerox/MavericksAppCompatibilityLayer](https://github.com/nfzerox/MavericksAppCompatibilityLayer).

The host's `otool` cannot decode `LC_BUILD_VERSION` (0x32), so the measured
surveys used a small fat-aware load-command parser.

## Summary

1. **No macOS dyld, in any version, refuses a binary because its minimum is
   above the running OS.** SOURCED: every dyld tag from 239 to 1340. The only such
   refusal is in the iOS simulator build ("app was built for iOS … which is newer
   than this simulator", `#if TARGET_IPHONE_SIMULATOR`, `dyld-353.2.1/src/dyld.cpp`).
   On macOS the minimum only decorates error messages.
2. **The kernel never compares the minimum with the running OS.** SOURCED:
   xnu `mach_loader.c`. From 10.15, however, it rejects a *main executable* that
   carries two version commands (see "Kernel", below).
3. **LaunchServices on 10.9 reads and stores the Mach-O minimum but does not
   enforce it.** It enforces `LSMinimumSystemVersion` from `Info.plist`.
   MEASURED.
4. **On 10.9, what matters is the `sdk` field, not the minimum.** Frameworks
   key linked-on-or-after behaviour on the sdk. dyld uses the sdk to decide
   whether to register a dylib's code signature. SOURCED and MEASURED.
5. **Real software, Apple's included, ships declared minimums above the OS it
   supports,** and runs there. MEASURED.

## What shipped binaries declared, by toolchain era

| Era | Load command | `sdk` field | Deciding rule |
|---|---|---|---|
| A. ld64 ≤ 97 (Xcode ≤ 3.2) | **none** | — | `LC_VERSION_MIN_MACOSX` unknown to ld64-85/95/97 (SOURCED, `git grep`: 0 hits) |
| B. ld64-123 (Xcode 4.1–4.4) | `LC_VERSION_MIN_MACOSX` | **0** | written only when ld64 itself was built for ≥ 10.7; `copyVersionLoadCommand` sets the sdk word to 0 (SOURCED, `ld64-123.2.1/src/ld/HeaderAndLoadCommands.hpp`) |
| C. ld64-133 to 409 (Xcode 4.5–9) | `LC_VERSION_MIN_MACOSX` | the SDK version | `cmd->set_sdk(_options.sdkVersion())` (SOURCED, ld64-136) |
| D. ld64-409 and later (Xcode 10+) | `LC_BUILD_VERSION` **only when the minimum is ≥ 10.14**; below that, still `LC_VERSION_MIN_MACOSX` | SDK | `shouldUseBuildVersion`: `minOSvers >= 0x000A0E00` for macOS (SOURCED, `ld64-957.1/src/ld/Options.cpp`, `PlatformSupport.cpp`) |
| E. arm64 (Xcode 12+) | always `LC_BUILD_VERSION` | SDK | "all arm64 variants are new and use LC_BUILD_VERSION" (same function); clang raises an arm64 macOS target to at least 11.0 (SOURCED, LLVM `Triple.cpp` `getMinimumSupportedOSVersion`) |
| F. chained fixups | `LC_BUILD_VERSION` (minimum ≥ 12) | SDK | default at minimum ≥ 12 (SOURCED, `ld64-957.1/src/ld/ld.hpp`); x86_64 main executables only from 13 (`Options.cpp`) |

Observations on real binaries, MEASURED unless marked:

- **New linkers still write `LC_VERSION_MIN_MACOSX` below 10.14.** Recent
  third-party builds declare 10.6–10.9 in `LC_VERSION_MIN_MACOSX` with sdk
  13.2–26.5. INFERRED: Xcode 26's own floor is 11.0 (SOURCED, Apple's Xcode system
  requirements), so those builds came from command-line flags or older floors.
- **An x86_64 minimum of 10.14 or more gives `LC_BUILD_VERSION` only.** Example:
  ripgrep declaring `LC_BUILD_VERSION` 10.15, sdk 10.15.6, and it runs on 10.9.5.
- **Universal2 slices differ as a rule.** The usual pairing is x86_64
  `LC_VERSION_MIN_MACOSX` 10.9 and arm64 `LC_BUILD_VERSION` 11.0 (e.g. XQuartz,
  sdk 13.2 on both). A minimum, and the choice of command, is per slice.
- **Where the default comes from.**
  - Apple's archived *SDK Compatibility Guide*: by default Xcode sets the
    deployment target to the base SDK's OS, and the base SDK to the newest one
    supported. SOURCED:
    <https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/cross_development/Configuring/configuring.html>
  - Modern clang, given no flag, infers the target from the SDK's
    `SDKSettings.json`. SOURCED: clang `Darwin.cpp`, `inferDeploymentTargetFromSDK`.
  - So an unconsidered build declares roughly its SDK, and a deliberate one declares
    something lower. The gap between the minimum and the sdk is the tell.
- **Xcode deployment floors.**
  - SOURCED: Xcode 14–16: 10.13; Xcode 26: 11; Xcode 27: 12.
  - INFERRED: Xcode 12–13: 10.9; earlier ones lower.
  - Since Xcode 14, a stock Xcode cannot produce a 10.9-minimum binary.
- **By distributor.**
  - *Apple, on 10.9 itself:* uniformly `LC_VERSION_MIN_MACOSX` 10.9 sdk 10.9.
    That covers 562/564 slices in `/usr/bin`, 198/204 in `/usr/lib` and 1097/1151
    in `/System/Library/Frameworks`. The stragglers declare 10.4–10.8, e.g.
    `libnetsnmp` at 10.7 with sdk 0, an era-B build.
  - *Apple, shipping for older OSes:* iTunes 12.8 runs on 10.9.5
    (`LSMinimumSystemVersion` 10.9.5, main executable 10.9 sdk 10.12), yet it bundles
    extensions declaring 10.10–10.12.
  - *Keynote 9.1:* its main binary and 13 frameworks declare 10.13 in
    `LC_VERSION_MIN_MACOSX`, as era D predicts for a 10.13 target. SOURCED:
    MavericksAppCompatibilityLayer `JOURNEY.md`, `tools/patch_min_version.py`.
  - *App Store and Developer ID apps:* the minimum is set deliberately to the oldest
    supported OS (INFERRED). `LSMinimumSystemVersion` and the Mach-O value drift
    apart: measured pairs include 10.6.0 vs 10.9, and 10.9.0 vs 10.8.
  - *Package managers default to the build host's OS.*
    - pkgsrc sets nothing (SOURCED, `mk/platform/Darwin.mk`); 1599 slices measured
      here declare 10.9.
    - MacPorts' `macosx_deployment_target` defaults to the current OS (SOURCED,
      `portfile.7`).
    - Homebrew passes `-mmacosx-version-min` of the bottling OS (SOURCED,
      `extend/os/mac/extend/ENV/std.rb`, `shims/super/cc`).
  - *Declaring nothing:* era-A builds and non-Apple linkers, e.g. Go 1.4's
    toolchain, a GLib stack bundled in VMware Fusion, one kext.

## Apple's documented recommendation

- **Every era** (SOURCED, the guide above): set the deployment target
  (`MACOSX_DEPLOYMENT_TARGET`, Xcode's *macOS Deployment Target*,
  `-mmacosx-version-min`) to the oldest OS you support, build against the newest
  SDK, and guard newer APIs with weak linking and availability macros. The guide
  describes failure on an older OS as *missing symbols*. It never describes a
  loader gate.
- **ld64 409 and later:** `-platform_version macos MIN SDK` sets both fields. SOURCED.
- **`@available`:** it compares against the *running* OS, not the declared
  minimum. INFERRED.
- **`LSMinimumSystemVersion`:** the documented user-facing gate. SOURCED:
  <https://developer.apple.com/documentation/bundleresources/information-property-list/lsminimumsystemversion>

## What each OS does with the fields

**dyld on 10.9 (dyld-239.4).** SOURCED unless marked.

- It recognises only `LC_VERSION_MIN_MACOSX`. `LC_BUILD_VERSION` lacks the
  `LC_REQ_DYLD` bit, so it is silently ignored. MEASURED: the 10.15 ripgrep above runs.
- **The minimum appears only in an error string.** "cannot load … because it was
  built for OS version A.B (load command 0x… is unknown)" fires only when an
  unknown `LC_REQ_DYLD` command is present, and names a version only if
  `LC_VERSION_MIN_MACOSX` exists (`ImageLoaderMachO.cpp`).
- **The sdk decides code-signature registration.** `loadCodeSignature`: "ignore
  code signatures in binaries built with pre-10.9 tools". dyld registers a dylib's
  `LC_CODE_SIGNATURE` (`F_ADDFILESIGS`) only if its sdk is ≥ 10.9. `sdkVersion()`
  reads only `LC_VERSION_MIN_*`, and returns 0 when absent (`ImageLoaderMachO.cpp`).
  - A dylib with no `LC_VERSION_MIN_MACOSX`, or with sdk 0, has its signature
    skipped.
  - A dylib with sdk ≥ 10.9 has it registered, so an invalid signature can fail the
    load.
- **`dyld_get_sdk_version`** returns the sdk if nonzero. Otherwise it maps
  libSystem's link-time version through a table in which anything newer than 10.9's
  libSystem maps to 10.9. So a modern binary with no version command looks "linked
  on 10.9".
- **`dyld_get_min_os_version`** returns `LC_VERSION_MIN_MACOSX.version`, or 0. It
  ignores `LC_BUILD_VERSION`.

**Who reads which on 10.9.** MEASURED: a C-locale `grep -l -a` over 2227 Mach-O files in
`/System/Library/{Frameworks,PrivateFrameworks}` and `/usr/lib`, with the sdk API as a
positive control.

- Only `libdyld` (which defines it) and LaunchServices reference the
  minimum-OS API. Nothing under `/Applications`, `/usr/{bin,sbin,libexec}` or
  `/System/Library/CoreServices` does.
- The sdk API is imported by CoreFoundation, Foundation, AVFoundation, libc and
  libxml2, and `_CFExecutableLinkedOnOrAfter` by AppKit, CoreGraphics, CoreText,
  WebKit and more. **On 10.9, linked-on-or-after behaviour keys on the sdk (or
  libSystem's version), never on the minimum.**
- A per-image minimum-keyed SPI (`dyld_minos_at_least`) arrives in 10.14. SOURCED:
  `dyld-1340/include/mach-o/dyld_priv.h`. Minimum-keyed framework behaviour is a
  10.14+ phenomenon.
- Caveat: open-source CF-855 stubs `_CFExecutableLinkedOnOrAfter` to `true`, so the
  shipped logic is known only by its imports.

**LaunchServices and Finder on 10.9.** MEASURED:

- An app whose executable declares 10.12, with no `LSMinimumSystemVersion`, opens and
  runs.
- A 10.9 executable in an app whose `Info.plist` says `LSMinimumSystemVersion`
  10.12 fails: `LSOpenURLsWithRole() failed with error -10825`.
- `lsregister -dump` shows LaunchServices *stored* the Mach-O fields
  (`exec os ver: 10.12`, `exec sdk ver: 10.9`) without gating on them.

**Kernel.**

- 10.9's `mach_loader.c` has no version-command handling at all. SOURCED.
- From 10.15, xnu returns `LOAD_BADMACHO` for a main executable carrying two
  version commands, e.g. `LC_VERSION_MIN_MACOSX` *and* `LC_BUILD_VERSION`
  (`found_version_cmd`). SOURCED.
- 10.14's dyld3 validator rejected that pair too; the check is gone by dyld-750.
  SOURCED.
- **A slice with both commands is a real hazard if an output ever runs on 10.14+.**

**Modern dyld (10.15+).** An x86_64 or i386 binary with no platform command at all
is accepted on macOS. SOURCED: `dyld-750.6/dyld3/MachOFile.cpp`, and
`Header::loadableIntoProcess` later.

**Notarization.** The notary service requires every Mach-O to be linked against
the 10.9 SDK or later, and checks the **sdk** field. SOURCED:
<https://developer.apple.com/forums/thread/659964>. The minimum plays no role
(INFERRED).

## Why another backport project rewrote the minimum

MavericksAppCompatibilityLayer's `tools/patch_min_version.py` says 10.9.5's dyld
refuses binaries claiming a higher `LSMinimumSystemVersion`. That conflates the
plist key, which LaunchServices checks and which was the refusal the project
actually hit (`JOURNEY.md`), with the Mach-O minimum, which dyld does not check.

- Their shipped 10.9 result (iWork 2015) never ran the tool. It launched by
  weakening binds and setting `LSMinimumSystemVersion` to 10.9.0
  (`install_iwork2015.sh`).
- The tool came later, for Keynote 9, with no failing-before or passing-after evidence.
- On every OS they targeted (10.9–10.12), a lowered minimum changes only the
  "built for …" suffix on symbol-not-found errors. INFERRED from dyld 239/353/433.

## What this means for Drydock

Facts that constrain the design:

- **The minimum.** On 10.9 it affects nothing about loading, executing or
  launching. `LSMinimumSystemVersion` does, and it lives outside the Mach-O.
- **The sdk field.** On 10.9 it decides two things: whether dyld registers a dylib's
  code signature, and which linked-on-or-after behaviour the frameworks choose.
- **What binaries arrive with.**
  - An x86_64 slice with a minimum below 10.14 carries `LC_VERSION_MIN_MACOSX`.
  - One at 10.14 or above, including every chained-fixups build, carries
    `LC_BUILD_VERSION` only.
  - An arm64 slice always carries `LC_BUILD_VERSION` at 11.0 or later.
  - Declaring nothing is rare in modern builds.
- **Two version commands in one slice fail on 10.14+** for a main executable.
- **Declared minimums above the supported OS** are ordinary in shipped software.

## Edited, signed images on 10.9

MEASURED on the same host with a small dylib (linked, and `dlopen`ed) and an
executable. Each was ad-hoc signed after its version command was set, then edited.
The sdk was absent, 0.0, 10.8, 10.9 or 12.3. The edit was either Drydock's
`dylib append`, which changes only the header, or one flipped byte in `__TEXT`'s
code. `vm.cs_enforcement`, `cs_force_kill` and `cs_force_hard` were all 0.

- **By default, everything ran.** Every edited dylib and executable exited 0 with
  correct output at every sdk. There was no dyld error and nothing was killed.
- **The sdk rule is real.**
  - For a dylib with sdk ≥ 10.9, dyld registers its stale signature. On the first
    fault of an edited page, the kernel logs
    `CODE SIGNING: cs_invalid_page … allowing (remove VALID) page`, and the process
    loses `CS_VALID` but keeps running.
  - For a dylib with sdk < 10.9, or with no version command, dyld ignores the
    signature. There is no log line.
  - An executable's signature is checked at exec whatever its sdk.
- **It becomes a failure only when the host process is signed with the kill flag**
  (`codesign -o kill`, flags `0x202`).
  - An edited dylib with sdk ≥ 10.9 then gets the process SIGKILLed. The kernel logs
    `denying page sending SIGKILL`.
  - The same edit with sdk < 10.9, or with no version command, runs.
  - An edited executable signed with the kill flag dies at any sdk.
  - Only the host's flag counts; the dylib's own flag does not.
- **A header-only edit is as fatal as a flipped code byte**, because the load commands
  sit on a hashed page of `__TEXT`. With a kill-flagged host it dies inside `dlopen`.
- **Stripping the signature (`load-command delete codesig`) fixed every case**, at
  every sdk, with or without the kill flag.
- **A malformed signature is harmless.** With the SuperBlob magic zeroed, dyld-239
  prints `dyld: Registered code signature for …` (its failure message) and loads
  the dylib as unsigned, even under a kill-flagged host. Only a well-formed but stale
  signature can hurt.

So on 10.9 the sdk decides whether an edited, still-signed dylib can take down a
kill-flagged host, and stripping the signature makes the sdk irrelevant to loading.

Open questions:

- **Modern macOS.** Whether edited x86_64 outputs run under Rosetta, and arm64 ones
  natively, with the signature stale, stripped, or re-signed; and whether the
  two-version-command case is refused there. Not measured.
- **The shipped CoreFoundation.** Its exact `_CFExecutableLinkedOnOrAfter` logic is unknown.
- **LaunchServices' stored minimum.** Whether 10.9 LaunchServices uses it anywhere,
  e.g. in "Open with" filtering, was not observed.
