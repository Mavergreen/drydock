# Edited outputs on Apple Silicon

Whether what Drydock writes runs on a modern Mac, natively (arm64) and under
Rosetta 2 (x86_64), with its signature left stale, stripped, or re-signed.
There, unlike on 10.9, the kernel enforces code signing for every process.
Measured 2026-10-05. Claims are tagged as in `docs/minimum-os-version.md`:

- **MEASURED** means run on the host below;
- **SOURCED** means read in this repository's `src/` or in a named document;
- **INFERRED** means reasoning or recollection that was not checked.

The run's own scripts and logs were scratch and are not kept.
`tests/apple_silicon_signing_test.sh` rebuilds the subjects and reruns the
rows the guidance rests on; it runs on any Apple Silicon Mac with Rosetta,
CI's macos-26 runner included, and skips elsewhere.

## The host

- An Apple M1 with Rosetta 2, running **macOS 27.0, build 26A428**.
  - The build number is the one recorded at the time; no `sw_vers` or
    kernel version string was kept with the results.
  - MEASURED: the subjects clang built there with no deployment flag declare
    `LC_BUILD_VERSION` minos 27.0, sdk 27.0. Clang infers that minimum from
    the SDK (SOURCED: `docs/minimum-os-version.md`), so the SDK was 27.0.
  - INFERRED: since the jump to year numbers, a build's leading number is
    the Darwin major, one below the macOS version (macOS 15 builds are 24A…,
    macOS 26's are 25A…). So 26A428 is macOS 27.0, not 26, which agrees with
    the SDK.
- `drydock-macho-rewrite` from commit 14f6c0b, built with host clang.
- Subjects: a dylib, a program linked against it, a program that `dlopen`s
  it, and a program alone, built for each arch with `-Wl,-headerpad,0x4000`
  (see "Drydock and a default arm64 output", below).
- The edit is `dylib append /usr/lib/libz.1.dylib`. Every run used a fresh
  copy of the file.
- MEASURED: arm64 `ld` signs its output ad hoc ("linker-signed"), and an
  arm64 process carries `CS_KILL` by default (`csops` status 0x22020201).
  x86_64 `ld` does not sign, so the x86_64 subjects were signed ad hoc
  before editing, to have a signature to leave stale.

## The matrix

MEASURED. ok = ran correctly; KILL = SIGKILL (exit 137); ABRT = SIGABRT from
dyld (exit 134); NULL = `dlopen` returned NULL.

| State | arm64 linked | arm64 dlopen | arm64 program | x86_64 linked | x86_64 dlopen | x86_64 program |
|---|---|---|---|---|---|---|
| 1 as built | ok | ok | ok | ok (unsigned) | ok (unsigned) | ok (unsigned) |
| 1u `codesign --remove-signature` | ABRT ¹ | NULL ¹ | KILL ² | as 1 | as 1 | as 1 |
| 2 re-signed ad hoc | ok | ok | ok | ok | ok | ok |
| 3 Drydock edit, signature stale | KILL ³ | KILL ³ | KILL ³ | ok ⁴ | ok ⁴ | ok ⁴ |
| 3u Drydock edit of an unsigned file | — | — | — | ok | ok | ok |
| 4 as 3, then `load-command delete codesig` | ABRT ¹ | NULL ¹ | KILL ² | ok | ok | ok |
| 5 as 3, then `codesign -s - -f` | ok | ok | ok | ok | ok | ok |
| 6 one flipped code byte, signature kept | KILL ³ | KILL ³ | KILL ³ | ok ⁴ | ok ⁴ | ok ⁴ |

Hosts signed with a flag, MEASURED (linked and `dlopen` alike):

| Host | dylib stale | stripped | re-signed | flipped |
|---|---|---|---|---|
| x86_64, `-o kill` | KILL ³ | ok | ok | KILL ³ |
| arm64, `-o kill` | KILL ³ | ABRT ¹ / NULL ¹ | ok | KILL ³ |
| either, `-o runtime` | KILL ³ | refused ⁵ | **refused ⁶** | refused ⁶ |

A program signed `-o kill` or `-o runtime` and then edited or flipped is
KILLed on both arches.

1. dyld: `Library not loaded: … (missing code signature in <UUID> '…')`;
   `dlerror()` carries the same text.
2. No stderr. Kernel: `AMFI: … Attempt to execute completely unsigned code
   (must be at least ad-hoc signed).`
3. No stderr. Kernel: `CODE SIGNING: cs_invalid_page(…): … denying page
   sending SIGKILL`, naming the edited header page (for 6, the flipped one).
4. The kernel logs `rejecting invalid page` for Rosetta's `oahd-helper` and
   `CS_VALID` drops, but without `CS_KILL` nothing is killed.
5. `… not valid for use in process: mapped file has no cdhash, completely
   unsigned?`
6. `… not valid for use in process: mapping process and mapped file
   (non-platform) have different Team IDs`; kernel: `AMFI: Library
   Validation failed`.

## Answers

1. **A stale x86_64 output is killed under Rosetta only in a host with
   `CS_KILL`** (signed `-o kill` or `-o runtime`). In an ordinary host it
   runs, as does a flipped code page. A stripped one runs everywhere but a
   hardened-runtime host. Unsigned x86_64 runs under Rosetta; unsigned arm64
   does not. MEASURED.
2. **A stripped arm64 output is refused.** A program is SIGKILLed by AMFI
   (²), with no dyld text; a linked dylib aborts in dyld and a `dlopen`ed
   one returns NULL (¹). The text is "missing code signature", not "code
   signature invalid". `codesign -s - -f` afterwards is enough, except in a
   hardened-runtime host. MEASURED.
3. **The sdk field matters under Rosetta, not on arm64.** arm64: a stale
   dylib is killed at sdk 0.0, 10.9 and 12.3, under either version command.
   x86_64 in a `-o kill` host follows 10.9's rule
   (`docs/minimum-os-version.md`): `LC_BUILD_VERSION` sdk 0.0, 0.1, 10.4,
   10.5 and 10.8 ran (sdk 0.0 three times in three), 10.9 and 10.10 were
   killed. With `LC_VERSION_MIN_MACOSX`, sdk 0.0 falls back to the minimum:
   minos 10.9 was killed, 10.8 ran. MEASURED.
4. **Two version commands: a dylib loads, a program dies.** A dylib with
   both `LC_VERSION_MIN_MACOSX` and `LC_BUILD_VERSION` `dlopen`s on both
   arches. A program with both, even validly re-signed, is SIGKILLed at exec
   with no dyld or AMFI text (MEASURED); that this is xnu's
   two-version-command check (SOURCED in `docs/minimum-os-version.md`) is
   INFERRED. A file with no version command runs on both arches, as program
   and as dylib, so arm64 does not demand a platform. `minos if-absent` on
   an `LC_BUILD_VERSION` file leaves one `LC_VERSION_MIN_MACOSX`, which
   runs. MEASURED.
5. **A minimum above the host is not refused.** minos 99.0, in either
   command, runs as a program and as a `dlopen`ed dylib on both arches.
   MEASURED.
6. **Quarantine blocks everything ad hoc, edited or not.** A quarantined
   program, whether ad hoc, stale, stripped or re-signed, is SIGKILLed, and
   a quarantined dylib's `dlopen` returns NULL (the arm64 stale one is
   KILLed first); Gatekeeper puts up a dialog each time. Edited files are
   not treated differently from re-signed ones. Without quarantine, runs are
   as in the matrix. MEASURED.

## Per arch: strip or re-sign?

- **arm64: re-sign, never strip.** `codesign --force --sign -` is enough.
  A stale signature is fatal in every host, because an arm64 process has
  `CS_KILL`; an unsigned file is refused. MEASURED on the M1; GitHub's
  runner is laxer (below).
- **x86_64: either.** Stripping (`load-command delete codesig`) runs
  everywhere but a hardened-runtime host, where nothing ad hoc runs either.
  A stale signature is fatal only in a `CS_KILL` host, and then only at
  sdk ≥ 10.9 (or, at sdk 0, minos ≥ 10.9): the same rule as 10.9's. So
  stripping stays the one answer that works on 10.9 and on a modern Mac
  alike. MEASURED.

## The hardened runtime

A host signed `-o runtime` rejects every re-signed dylib, by Library
Validation's Team ID check (⁶), so neither stripping nor re-signing the
dylib helps. MEASURED. The fix is the host's own signature:

- re-sign it ad hoc without the runtime: a re-signed dylib runs in such a
  host, `-o kill` included (MEASURED, the rows above);
- or give it the `com.apple.security.cs.disable-library-validation`
  entitlement (INFERRED; not tried).

## GitHub's macos-26 runner

MEASURED by `tests/apple_silicon_signing_test.sh` on GitHub's macos-26 arm64
runner, a virtual machine:

- a linker-signed arm64 process there lacks `CS_KILL`, so an arm64 dylib or
  program left with a stale signature runs;
- an arm64 program with its signature stripped runs;
- dyld still refuses a stripped arm64 dylib (exit 134), a host signed
  `-o kill` still dies of a stale x86_64 dylib (exit 137), and every other
  x86_64 row matches the M1's.

So where an unedited arm64 program lacks `CS_KILL`, the test signs the
arm64 program `-o kill` before the stale edit, which is the flag a real Mac
sets by default, and runs the stripped arm64 program without judging it.
It prints the csops status, `csrutil status` and `kern.bootargs`; on the
runner they were 0x22020001 (no `CS_KILL`), "System Integrity Protection
status: disabled." and an empty `kern.bootargs`. INFERRED: SIP being off is
why the default `CS_KILL` and AMFI's refusal of unsigned code are missing.

## Drydock and a default arm64 output

MEASURED: `ld` leaves 32 bytes of header pad in an arm64 output, less than
the 48 bytes of an `LC_LOAD_DYLIB`, and Drydock refuses to make room:

- a dylib: `only an x86_64 dylib or bundle can be grown (cputype=0x100000c)`;
- a program: `an arm64 image maps 16 KB pages, and this grow lowers the
  image base by 4 KB pages, which arm64 cannot load; refusing`.

Both are `src/grow.c`'s (SOURCED). That is why the subjects above were built
with a 16 KB header pad. The x86_64 builds had 48–72 bytes, enough as built.

Not measured: Developer ID and notarized signatures; only ad hoc ones.
