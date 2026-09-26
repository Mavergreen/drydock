# Output that 10.9's `codesign` can re-sign

QUEUE item 30 (`docs/superpowers/QUEUE.md`, "## Item 30"). `fixups set
classic` writes an image that 10.9's `codesign_allocate` refuses, and
ad-hoc re-signing is a required step in known port flows (QUEUE item 13, "A
documentation gap"). This spec measures what 10.9's tool requires, finds
every Drydock statement that breaks it, and designs one fix for all of them.
Nothing here is implemented yet.

Evidence is tagged the way `docs/minimum-os-version.md` tags it:
**MEASURED** on this 10.9.5 host (13F1911), **SOURCED** from a named file in
a named upstream release, and **NOT VERIFIED** where neither was possible.

## Why

### The tool

- **MEASURED.** `codesign` runs
  `/Library/Developer/CommandLineTools/usr/bin/codesign_allocate`; its
  path appears in every refusal. The package is
  `com.apple.pkg.CLTools_Executables` 6.2.0.0.1.1424975374, and the binary
  carries the string `cctools-862`.
- **SOURCED.** [apple-oss-distributions/cctools](https://github.com/apple-oss-distributions/cctools),
  tag `cctools-862`:
  - `libstuff/ofile.c`, `check_Mach_O`: rejects any load command it does
    not know;
  - `libstuff/checkout.c`, `dyld_order()` (lines 313–560): the order check,
    for `MH_DYLIB` and for any image with `MH_DYLDLINK`;
  - `misc/codesign_allocate.c`, `setup_code_signature()`, and
    `libstuff/writeout.c`: the writer.
- Every refusal string quoted below is in the binary (`strings`), and every
  refusal was reproduced with the real tool.

### "unknown load command N" is the index, not the command

`Mach_O_error(ofile, "malformed object (unknown load command %u)", i)`
(`ofile.c:5959`) prints the loop index `i`. SOURCED, and MEASURED two ways:

- Mantle, ReactiveObjC, Squirrel and libGLESv2 say `4`, and ShipIt and
  chrome_crashpad_handler say `5`. In each, that is the 0-based index of
  `LC_DYLD_CHAINED_FIXUPS`, the first load command 10.9's cctools does not
  know.
- A 10.9-linked dylib with one command's `cmd` patched says `7` for
  `LC_BUILD_VERSION` at index 7. It says `12` for `LC_DYLD_EXPORTS_TRIE` and
  for `LC_DYLD_CHAINED_FIXUPS` at index 12, and `9` for `LC_NOTE` at index 9.

**What 10.9's cctools knows** (SOURCED, the `case LC_` labels of
`check_Mach_O`): everything up to `LC_LINKER_OPTIMIZATION_HINT` (0x2e),
including `LC_VERSION_MIN_MACOSX`, `LC_MAIN`, `LC_SOURCE_VERSION`,
`LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`, `LC_DYLIB_CODE_SIGN_DRS`,
`LC_LINKER_OPTION` and `LC_ENCRYPTION_INFO_64`. It does not know:
`LC_VERSION_MIN_TVOS`, `LC_VERSION_MIN_WATCHOS`, `LC_NOTE`,
`LC_BUILD_VERSION`, `LC_DYLD_EXPORTS_TRIE`, `LC_DYLD_CHAINED_FIXUPS`,
`LC_FILESET_ENTRY`, `LC_ATOM_INFO` or anything later.

**Drydock already removes the three that real images carry.**
- `fixups set classic` strips `LC_DYLD_CHAINED_FIXUPS`,
  `LC_DYLD_EXPORTS_TRIE` and `LC_BUILD_VERSION` (`src/declassify.h`).
- Both `minos` statements replace `LC_BUILD_VERSION` with
  `LC_VERSION_MIN_MACOSX` (README), and `target 10.9` always derives
  `minos at-most 10.9`.
- `load-command delete build-version` removes it by hand.

MEASURED: after `fixups set classic`, none of the six images has an
unknown command, and every refusal moves on to the order. A 10.9 dylib given
an `LC_BUILD_VERSION` signs and verifies after `target 10.9`. Nothing in
Drydock removes the others, but no real image seen here carries them.

### The order

`dyld_order()` walks a running offset from `__LINKEDIT`'s `fileoff` and
requires each piece that is present to start exactly there. In order:

| # | piece | from | refusal when out of place |
|---|---|---|---|
| 1 | dyld info: rebase, bind, weak bind, lazy bind, export, **as one block** | `LC_DYLD_INFO[_ONLY]` | `dyld_info out of place` |
| 2 | local relocations | `LC_DYSYMTAB` | `local relocation entries out of place` |
| 3 | split info | `LC_SEGMENT_SPLIT_INFO` | `split info data out of place` |
| 4 | function starts | `LC_FUNCTION_STARTS` | `function starts data out of place` |
| 5 | data in code | `LC_DATA_IN_CODE` | `data in code info out of place` |
| 6 | code-signing DRs | `LC_DYLIB_CODE_SIGN_DRS` | `code signing DRs info out of place` |
| 7 | linker optimization hints | `LC_LINKER_OPTIMIZATION_HINT` | `linker optimization hint info out of place` |
| 8 | symbol table: locals, then defined externals, then undefined | `LC_SYMTAB`, `LC_DYSYMTAB` | `symbol table out of place`, `local symbols out of place`, … |
| 9 | two-level hints | `LC_TWOLEVEL_HINTS` | `hints table out of place` |
| 10 | external relocations | `LC_DYSYMTAB` | `external relocation entries out of place` |
| 11 | indirect symbol table | `LC_DYSYMTAB` | `indirect symbol table out of place` |
| 12 | table of contents, module table, reference table | `LC_DYSYMTAB` | `… out of place` |
| 13 | string table | `LC_SYMTAB` | `string table out of place` |
| 14 | code signature, at the next multiple of 16 | `LC_CODE_SIGNATURE` | `code signature data out of place` |
| 15 | end of file | | `link edit information does not fill the __LINKEDIT segment` |

The other checks, all SOURCED, and each marked where it was also MEASURED:

- **`__LINKEDIT` ends the file:** `fileoff + filesize` must equal the file
  size, or the refusal is `the __LINKEDIT segment does not cover the end of
  the file`.
- **The dyld info block starts at `__LINKEDIT`'s `fileoff`.** The check is
  on `rebase_off`, or on `bind_off` when there are no rebases. The block
  ends at the end of the last piece present, taken in the order export,
  lazy bind, weak bind, bind, rebase. Nothing checks what lies between.
- **No gaps.** There are exactly two exceptions:
  - after an odd count of 64-bit indirect symbols, the string table (or
    the table of contents, module table or reference table) may start at
    the next multiple of 8;
  - the code signature starts at the next multiple of 16.
  MEASURED: 8 bytes inserted before the rebase stream, after the export
  trie, before the symbol table, or before the string table are each
  refused, and so are 16 bytes after the string table. The 8-rounding after
  an odd indirect table is accepted, and 8 more bytes past it are refused.
- **No alignment of the streams themselves.** MEASURED: Mantle's lowered
  streams at their odd lengths (2,934 and 8,081 bytes), packed back to
  back, sign and verify. `dyldinfo` reads them identically.
- **A zero-size piece still has a place.** Split info, function starts and
  data in code are skipped only when their `dataoff` is 0. DRs and linker
  hints are never skipped. MEASURED: an empty `LC_DATA_IN_CODE` whose
  `dataoff` is not the running offset is refused.
- **At most one** of each command above, and exactly one `LC_ID_DYLIB` in
  a dylib.

### What `codesign_allocate` silently assumes

The order check is not the whole contract. `setup_code_signature()`
(`codesign_allocate.c:353–385`) copies the dyld info as one block, from its
first byte to its last. But it counts the input's symbolic data as the
**sum** of the five stream sizes (`:453–458`). `writeout.c:700–712` then
copies the file up to `object_size - input_sym_info_size` verbatim, and
writes the pieces after that. If the five streams do not tile their block
exactly, everything after the block shifts by the difference, and nothing
reports it. SOURCED, and MEASURED:

- **8 zero bytes between the rebase and bind streams** of a clang-built
  dylib: `codesign_allocate` exits 0. The signed file's `__LINKEDIT`
  extends 8 bytes past the end of the file, `codesign -v` fails, and dyld
  refuses it: `segment __LINKEDIT extends to 17920 which is past end of file
  17912`.
- **Mantle, in order, then `objc-methods set absolute`**, which leaves its
  old rebase stream zeroed inside the block (2,936 bytes). This
  `codesign --force --sign -` exits 0 **and `codesign -v` passes**, but
  `dyldinfo -rebase -bind` lists 817 lines where the unsigned file had
  1,253. The rebase and bind streams were corrupted under a valid signature.

So **`codesign -v` passing is not evidence of a correct re-sign.** Drydock's
own check must include this condition (Decision 5), and any real-world proof
must compare the streams after signing, not only verify the signature.

### What Drydock writes today

Each row below is MEASURED with this repo's `drydock-macho-rewrite` at
88e846f, except where it says SOURCED.

| statement | what it does to `__LINKEDIT` | 10.9's `codesign_allocate` |
|---|---|---|
| `fixups set classic` | appends the rebase and bind streams, each 8-aligned, **past the end of the file, after the code signature** (`md_declassify_buf`, "Append data at end of file"). It leaves the export trie where it was, and the chained-fixups blob at `__LINKEDIT`'s start with nothing pointing at it (2,816 bytes in Mantle). It extends `__LINKEDIT` over the streams. | `dyld_info out of place`, all six images: `rebase_off` is not `__LINKEDIT`'s `fileoff`. Past that, the streams after the signature would fail at the end of the file. |
| `objc-methods set absolute` | puts its new rebase stream at `__LINKEDIT`'s start and zeroes the old one where it lies (`mma_insert`). | on the lowered frameworks, `link edit information does not fill the __LINKEDIT segment` (the lowering's bind stream still follows the signature). On an input in order, it **signs corrupt**, as above. |
| `import redirect`, when the bind stream must grow | moves the bind stream to the end of the file and zeroes the old one (`src/redirect.c`). | SOURCED only: after the signature, and a hole inside the block. |
| any header grow (`mg_grow_header`) whose rebuilt export trie is larger | appends the trie at the end of the file. On a signed lzfse, in order, `dylib append` moved a 464-byte trie, rebuilt as 470 bytes, past the signature. | `function starts data out of place` |
| `load-command delete codesig` | drops the command and leaves its blob, which nothing now points at. | `link edit information does not fill the __LINKEDIT segment` |
| `load-command delete code-sign-drs` | drops the command and leaves its 64 bytes between function starts and the symbol table. | `symbol table out of place` |

`mg_grow_header` without a trie rebuild keeps the order. MEASURED: a signed
10.9 executable, grown 4096 bytes, still passes.

### Does 10.9 need a valid signature at all?

MEASURED here with a clang-built dylib and executable (sdk 10.9), each
ad-hoc signed. A stale signature comes from a header-only edit made after
signing (`rpath append`). The rows repeat and agree with
`docs/minimum-os-version.md`, "Every sdk check in 10.9.5's own code".

| image | from an unsigned host | from a host signed with `-o kill` |
|---|---|---|
| dylib, valid signature | loads | loads |
| dylib, **stale** signature | loads | **SIGKILL** (`denying page sending SIGKILL`) |
| dylib, signature removed (command and blob) | loads | loads |
| dylib, re-signed with 10.9's `codesign` | loads | loads |

| executable | runs |
|---|---|
| valid signature, with or without the kill flag | yes |
| stale signature | yes |
| stale signature, signed with `-o kill` | **no, exit 137** |
| signature removed | yes, even one first signed with `-o kill` |

So 10.9 needs no signature, but a **well-formed stale** one can kill.
`docs/minimum-os-version.md` adds that a dylib with sdk below 10.9 has its
signature ignored, and that a malformed one is harmless.

The real inputs carry modern signatures: CodeDirectory v=20500, flags
0x10000, which is the hardened runtime and not the kill flag. Mantle's
hash type is sha256.
Observed once, NOT VERIFIED as a rule: lowered Mantle, still carrying that
signature, printed `dyld: Registered code signature for …`, which is dyld's
failure message, from a kill-flagged host, and was not killed. It then
stopped at a missing symbol. So a modern signature may simply never register
on 10.9.

This decides the shape of the fix: **placing the streams in order is
necessary and sufficient to re-sign.** A statement that strips a signature
already exists (`load-command delete codesig`), and needs only to stop
orphaning the blob (Decision 3). Signing inside Drydock is not needed
(Out of scope).

### The fix, proven by hand first

A prototype, written apart from `src/`, rewrote `__LINKEDIT` into the order
above. It dropped bytes nothing points at, and kept each piece's bytes and
size. It was run on the six real images after `fixups set classic`
(Mantle `3b59fda2`, ReactiveObjC `35e4e688`, Squirrel `03ef80b1`, ShipIt
`a233da31`, chrome_crashpad_handler `ff634765`, libGLESv2 `cbcf071c`, by
SHA-256; OpenCode.app's frameworks, as in the objc-methods spec). MEASURED:

- All six sign with 10.9's `codesign --force --sign -`, and `codesign -v`
  passes, whether the stale signature is kept at the end or the command and
  blob are removed.
- `dyldinfo -rebase -bind -weak_bind -lazy_bind -export` is identical
  between the lowered image and its packed, signed copy: 1,031, 4,258, 1,615,
  1,154, 3,693 and 25,848 lines. So are `nm -ap` and `otool -Iv`.
- Loading gets exactly as far as before: each image stops at the same
  missing 10.9 symbol or library, so dyld reads the moved streams.
- **The objc-methods chain:** `fixups set classic` then `objc-methods set
  absolute` refuses to sign ("does not fill"). The same chain followed by
  the prototype signs and verifies. `dyldinfo` is identical between the
  unpacked chain output and its packed, signed copy (1,296, 6,206 and 1,985
  lines), `drydock-macho-rewrite verify` says OK, and `info` counts 32, 143
  and 27 absolute lists.
- **Runs on 10.9.** Ghidra 12.0.3's x86_64 `lzfse` (`b089fca1`) and
  `demangler_gnu_v2_41` (`c471fdf3`) are chained executables. `target 10.9`,
  `dylib append` of a one-instruction `____chkstk_darwin` shim, and
  `import redirect ____chkstk_darwin /usr/lib/libSystem.B.dylib SHIM` lower
  them. That run left the export trie after the bind stream, from a grow.
  The prototype, 10.9's `codesign`, then `codesign -v` all passed.
  The packed, signed `lzfse -decode` restores, byte for byte, a file the
  unpacked build encoded, and the demangler prints `foo::bar()`.

## Decisions

### 1. One pass, after the last statement, puts `__LINKEDIT` in order

A new function, `mlo_pack`, rewrites a slice's `__LINKEDIT` into the order
of Decision 2. `me_statements` calls it once per slice, after the slice's
last statement and before `mg_plausible`'s gate, when the run disturbed
`MREL_FILE_OFF`, whether declared or observed (Decision 4). It moves no byte
below `__LINKEDIT`'s `fileoff`.

Why one pass at the end:

- **Five writers break the order today** (the table above), for five
  different reasons. One pass fixes all five, and any sixth, without
  teaching each writer where things go.
- **The writers keep their verifiers.** `objc-methods`' layout check (its
  spec's Decision 7: "the old `__LINKEDIT` bytes reappear Z + S + R
  later") and `import redirect`'s re-walk stay true of what those statements
  do. The pass verifies itself separately (Decision 5).
- **Nothing between statements needs the order.** dyld reads by offset.
  MEASURED: the lowered, out-of-order images load exactly as far as the
  ordered ones, and `objc-methods` accepts the lowered image as it is (M2 ran
  on it).

**The road not taken: each statement keeps the order itself.** The lowering
would place its streams at `__LINKEDIT`'s start and move everything after
them. `objc-methods` would replace the rebase stream in place. `import
redirect` would grow the bind stream in place. `mg_grow_header` would re-pack
after a larger trie. `load-command delete` would cut out its blob. That is
five placement algorithms and five changes to verifiers that are correct
today, for the same end state. Choose it only if some statement comes to
**need** the order in its input. None does.

**Also not taken: an explicit statement** (`linkedit pack`). The pass is
needed after exactly the statements that disturb `__LINKEDIT`, so a
statement would be something every script must remember, in the right place,
for no case where leaving it out is right.

### 2. The order, and what the pass does with each piece

The pass writes the pieces in ld64's order, which is the order of the table
in "Why". Two modern pieces are slotted where the current cctools wants
them: `LC_DYLD_CHAINED_FIXUPS`' blob, then `LC_DYLD_EXPORTS_TRIE`'s, right
after the dyld info (SOURCED: `cctools-1035.1.102`
`libstuff/checkout.c:483–535`). So an image that still has chained fixups is
also left in the order a current `codesign_allocate` wants. **NOT
VERIFIED:** no current `codesign` is on this host.

- **Each piece keeps its bytes and its size.** The pass concatenates. The
  only gaps it writes are the two `dyld_order()` allows: the 8-rounding
  after an odd indirect table, **only where the input already had it**, and
  zeros up to a 16-byte boundary before the code signature.
- **Bytes nothing points at are dropped**: the chained-fixups blob the
  lowering orphans, the old streams `objc-methods`, `import redirect` and
  a grow leave zeroed, the blob of a deleted `LC_CODE_SIGNATURE` or
  `LC_DYLIB_CODE_SIGN_DRS`, and alignment slack. "Points at" is
  `ml_each_off`'s list (`src/linkedit.h`) plus sizes.
- **The symbol and string tables move with everything else.** Nothing
  inside them, or inside any other piece this pass moves, is a file offset.
  `n_strx` is relative to `stroff`, indirect entries are symbol indices,
  export-trie child offsets are relative to the trie, and relocations are
  segment-relative. So a table that sat between the lowering's streams
  and the rest is simply placed in its turn.
- **`__LINKEDIT`'s `filesize`** becomes the new length, and the file ends
  there. `vmsize` is left alone when it still covers `filesize`. Otherwise it
  is rounded up to the page (4 KB for x86_64, 16 KB for arm64), and the pass
  declines if that would overlap the next segment in vm.
- **An image already in order is left byte-identical.** The pass is
  idempotent.
- **The pass declines, leaving `__LINKEDIT` as it is and saying why**, when
  it cannot account for every byte it would move:
  - `__LINKEDIT` is not the last segment in the file, or does not end it;
  - a section's file range lies in `__LINKEDIT`;
  - a load command carries a file offset it does not know: `LC_NOTE`,
    `LC_ATOM_INFO`, the function-variant commands, or any command
    `ml_each_off` does not cover that is not known to carry none;
  - two pieces overlap;
  - growing `vmsize` would overlap the next segment;
  - there is no `LC_DYSYMTAB`. `dyld_order()` does not apply then;
    `symbol_string_at_end()` does, and no dyld image seen lacks one.

  Declining is not a refusal of the run (Decision 6).

### 3. `LC_CODE_SIGNATURE`: keep the stale blob, last; delete means delete

- **The pass keeps an existing signature**, moving its blob to the end, at
  the next multiple of 16. That is where `codesign_allocate` expects it, and
  where `codesign --force` replaces it. MEASURED: all six real images and
  the fixtures re-sign with the stale blob kept.
- **`load-command delete codesig` and `delete code-sign-drs` now drop
  their bytes too.** The row gains `MREL_FILE_OFF`, so the pass runs and
  finds the blob unreferenced. MEASURED today: both deletions leave an image
  10.9 cannot re-sign. With the change, the output is what the prototype
  signed ("signature removed" above), and it loads from a kill-flagged host
  too.

Why keep it rather than drop it:

- **Dropping is already one statement away**, and deleting a user's
  signature as a side effect of `fixups set classic` would make a later
  explicit `load-command delete codesig` match nothing and refuse the run.
- **Keeping changes nothing for loading.** Today's output already carries
  the same stale signature. Whether `target 10.9` should strip it is
  Question 2.

**The road not taken: refuse a signed input.** Every real input is signed,
so that would refuse every real input.

**Also not taken: drop the signature bytes but keep the command.** A command
pointing at nothing is neither re-signable nor honest.

### 4. When the pass runs

It runs when the slice's run disturbed `MREL_FILE_OFF`: declared by
`fixups`, `import redirect`, `objc-methods` and, after Decision 3,
`load-command delete`; or observed, which `me_note_disturbed` already adds
for any grow.

- **A run that never touched `__LINKEDIT` never moves it.** A `dylib
  replace` on some other linker's out-of-order image leaves that image as it
  was. This is the README's "minimally modified copy".
- **A disturbed run whose `__LINKEDIT` is already in order is left
  byte-identical** (Decision 2), so passing a statement through costs
  nothing.
- **Per slice**, like every other statement, so a fat file's other slices
  are not touched.

**The road not taken: always, whenever the output is out of order.** That
would re-lay an image the script never asked to have its `__LINKEDIT`
touched. The only images that would gain are out-of-order inputs that no
Drydock statement disturbed, and none has been seen.

### 5. The verifier: `mlo_check`, a pure function

`src/linkedit_order.[ch]` (`mlo_`) gets `mlo_check(const mi_image *,
mlo_verdict *)`. It reads, allocates nothing, and returns either "in order"
or the **first** reason, in `codesign_allocate`'s own words, with the
load-command index where one applies. It checks, in the order
`codesign_allocate` does:

1. **Every load command is one 10.9's cctools knows** (the list in "Why"),
   or the reason is `unknown load command N` (index, as the tool counts)
   with the command's name.
2. At most one `LC_SYMTAB`, `LC_DYSYMTAB`, `LC_CODE_SIGNATURE`,
   `LC_DYLD_INFO[_ONLY]`, `LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`,
   `LC_DYLIB_CODE_SIGN_DRS`, `LC_SEGMENT_SPLIT_INFO`,
   `LC_LINKER_OPTIMIZATION_HINT`, and one `__LINKEDIT`.
3. `__LINKEDIT` ends the file.
4. `dyld_order()`, rule for rule, including the zero-`dataoff` exemptions,
   the symbol-index order, the 8-rounding and the 16-rounding.
5. **Drydock's own addition: the five dyld-info streams tile their block**:
   the sum of the sizes equals last end minus first start. This is what
   `writeout` silently assumes ("What `codesign_allocate` silently
   assumes").
6. **Drydock's own addition: `__LINKEDIT`'s `fileoff` is a multiple of
   16.** `checkout` rounds the absolute offset before the signature, while
   `codesign_allocate` rounds the size sum. They agree only then. SOURCED
   only: linkers page-align segment file offsets, so no image seen here
   violates it.

An image without `LC_DYSYMTAB` gets the verdict "not checked", not a guess.

Where it is used:

- **As `mlo_pack`'s postcondition.** After packing, `mlo_check` must say "in
  order", or the only reason left must be an unknown load command, which the
  pass cannot fix. The pass also checks that each piece's bytes are
  identical at its new offset, that nothing below `__LINKEDIT` changed, and
  that the load commands differ only in offset fields and `__LINKEDIT`'s
  `filesize` and `vmsize`. Any other outcome is `MR_FAIL`, and nothing is
  written.
- **In `info`**: one new line, `resign 10.9: ok`, or `resign 10.9:
  dyld_info out of place`, or `resign 10.9: unknown load command 4
  (LC_DYLD_CHAINED_FIXUPS)`.
- **In every test that asserts re-signability**, on every host. It never
  runs `codesign`.

**The road not taken: run `codesign_allocate` and read its answer.** CI runs
on macos-26 arm64, whose `codesign_allocate` knows every modern command and
would pass what 10.9 refuses. A check that depends on the host's tool is
unfalsifiable exactly where the suite runs most. The real tool is instead
the **oracle** for `mlo_check`'s verdicts, on 10.9 (Testing).

### 6. What the edit reports

- When the pass moved anything, one line under the run: `__LINKEDIT
  re-packed in codesign_allocate's order: N bytes, M unreferenced bytes
  dropped`.
- When the pass declined, or when the result is still not re-signable on
  10.9 (an unknown load command remains): one line saying why, in
  `mlo_check`'s words.
- **Not a refusal.** The output is written. Signing may happen on a newer
  host, whose tool knows commands 10.9's does not. That is Question 3.
- A run that did not trigger the pass prints nothing new, so every existing
  single-statement stdout, including the compat wrappers', is unchanged.

### 7. The lowering pads its streams to 8

`md_declassify_buf` pads each emitted stream to a multiple of 8, and the
padding counts in `rebase_size` and `bind_size`, as ld64's does: the 10.9
dylib built here has 7 bytes of rebase opcodes in an 8-byte `rebase_size`.
The zeros are `*_OPCODE_DONE`.
After the pass, the symbol table then stays 8-aligned. That is the only
alignment a `nlist_64` array has ever had from a linker, and consumers not
tested here (`strip`, older `otool`, `lipo`) may assume it.

**The road not taken: leave the odd lengths.** MEASURED to work with dyld,
`dyldinfo`, `nm`, `otool -Iv` and `codesign` on 10.9, so this is hygiene,
not a fix. It is cheap only because the lowering owns those two streams.

### 8. Later statements keep the order by construction

The pass runs after the last statement, so no statement has to preserve
anything. What each of today's breakers becomes:

| statement | after this design |
|---|---|
| `fixups set classic` | streams appended as now, packed at the end |
| `objc-methods set absolute` | its zeroed old stream is unreferenced, so it is dropped; its 16-byte stream pad becomes unnecessary but stays |
| `import redirect` (grow) | the moved stream is packed back into place |
| a grow with a larger trie | the trie is packed back after the bind streams |
| `load-command delete codesig`/`code-sign-drs` | the orphaned blob is dropped |

The objc-methods spec's claim that it "leaves the image as re-signable as it
found it" is wrong on an ordered input, because of the tiling hole. M3
corrects that sentence.

## Testing

### Unit fixtures, hermetic (every host, CI included)

- **`tests/mklinkedit.c`** (new), in the style of `tests/mkchained.c`:
  a hand-laid x86_64 dylib, with bytes and no linker. It has `LC_ID_DYLIB`,
  `LC_DYLD_INFO_ONLY` with all five streams, `LC_FUNCTION_STARTS`, an empty
  `LC_DATA_IN_CODE`, `LC_DYLIB_CODE_SIGN_DRS`, `LC_SYMTAB` with locals,
  externals and undefineds, `LC_DYSYMTAB` with an odd indirect count, and an
  `LC_CODE_SIGNATURE` blob. Its canonical layout is the order table's.
  `mklinkedit make VARIANT OUT` writes one of the layouts below. Each was
  measured against 10.9's tool while this spec was written, on a
  clang-built 10.9 dylib with the same pieces less a weak-bind stream:

  | variant | 10.9's `codesign_allocate` |
  |---|---|
  | canonical | accepts |
  | bind before rebase; 8 bytes before rebase | `dyld_info out of place` |
  | export trie between two streams; 8 bytes after the trie; symbol table before function starts; function starts last | `function starts data out of place` |
  | empty data-in-code at the wrong `dataoff` | `data in code info out of place` |
  | 8 bytes before the symbol table; string table first | `symbol table out of place` |
  | 8 bytes before the string table past the 8-rounding | `string table out of place` |
  | odd indirect table, string table at the 8-rounding | accepts |
  | signature off 16, or 16 bytes late | `code signature data out of place` |
  | bytes after the signature or the string table | `link edit information does not fill …` |
  | 8 bytes inside the dyld-info block | **accepts, then writes a corrupt file** |
  | one command patched to `LC_BUILD_VERSION`, `LC_NOTE`, `LC_DYLD_EXPORTS_TRIE` | `unknown load command N` |

- **`tests/linkedit_order_test.c`**: `mlo_check`'s verdict on every
  variant; `mlo_pack` on every "refuses" variant gives an image `mlo_check`
  accepts with every piece's bytes intact; the pack is a byte-identical
  no-op on the canonical one; and each decline case.
- **`tests/cli_test.sh`**:
  - `fixups set classic` on a `mkchained` variant that gains `LC_SYMTAB`,
    `LC_DYSYMTAB` and `LC_ID_DYLIB` (`make-signable`; the current fixture
    has none, and 10.9's tool refuses it for that before any order);
  - `objc-methods set absolute` on `mkrelmeth`'s `codesig` variant;
  - `load-command delete codesig` and `code-sign-drs`;
  - a `dylib append` whose grow rebuilds a larger trie;
  - `import redirect`'s grow case (`tests/mkbindstream.c`);
  - each asserting `info`'s `resign 10.9: ok`, and `imports`/`exports`
    unchanged.
- **`tests/script_test.c`**: `test_disturbs_matches_the_spec_table` pins
  `load-command delete`'s new `MREL_FILE_OFF`.

### The oracle, on 10.9 only

**`tests/codesign_order_test.sh`** runs `codesign_allocate -i F -a x86_64
16384 -o OUT` directly, with no signing and no keychain, on every
`mklinkedit` variant and every packed output. It requires the tool's
verdict to equal `mlo_check`'s. For every accepted file it also requires
each `__LINKEDIT` piece in OUT to be byte-identical at the offset OUT's load
commands give. That catches the silent corruption, which exit status cannot.

It exits 77 (SKIP), with the reason, unless the tool carries the string
`cctools-862`. On any other tool the verdicts legitimately differ (it knows
`LC_BUILD_VERSION`), and this follows memory "Check CI, not just local
suites".

### Real binaries, on 10.9, by hand (M4)

On fresh copies, never the originals:

- the six OpenCode.app images and the two Ghidra executables;
- `target 10.9`, then for the three frameworks `objc-methods set absolute`,
  then for the Ghidra pair the shim lines above;
- then `codesign --force --sign -` and `codesign -v`;
- then `dyldinfo -rebase -bind -weak_bind -lazy_bind -export`, `nm -ap` and
  `otool -Iv`, compared before and after signing;
- then run both Ghidra tools.

The expected figures are the prototype's, in "The fix, proven by hand
first". Recorded in this spec, as the objc-methods spec records M2's run.

### CI

macos-26 arm64 runs everything above except the oracle, which skips. The
fixtures are bytes, so nothing a host compiler contributes (pad, arch,
layout) enters a verdict. `mlo_check`'s answer is the same on every host by
construction, which is why it, and not the host's `codesign`, is the check.

## Milestones

Each one is its own plan. Tasks are sized for one implementer subagent each,
TDD and mutation-proved per `.superpowers/sdd/2026-09-26-deferred-items/constraints.md`.

**M1: the verifier.**
1. `tests/mklinkedit.c`: the canonical dylib and its variants.
2. `src/linkedit_order.[ch]`: `mlo_check`, rules 2–6 of Decision 5, with
   `tests/linkedit_order_test.c`.
3. Rule 1, the known-command list, with the unknown-command variants.
4. `info`'s `resign 10.9:` line; `tests/cli_test.sh`.
5. `tests/codesign_order_test.sh`, the 10.9 oracle.

**M2: the pass.**
1. `mlo_pack` on a buffer: the layout of Decision 2, with its
   postconditions; unit tests on every "refuses" variant, and the no-op.
2. The declines (Decision 2's list), each a test.
3. The call in `me_statements`, per slice, gated as in Decision 4, and the
   report lines of Decision 6.
4. `load-command delete` gains `MREL_FILE_OFF`; the `script_test` pin; CLI
   tests for `codesig` and `code-sign-drs`.
5. CLI tests for the lowering (`mkchained make-signable`), `objc-methods`,
   the trie-growing grow and `import redirect`'s grow.

**M3: the lowering's padding, and the words.**
1. Decision 7, with its test (sizes are multiples of 8, and `dyldinfo`-
   equivalent streams through `mkchained check`).
2. README:
   - a "Re-signing" paragraph: 10.9's `codesign` works on Drydock's output;
     sign last; `resign 10.9:` says whether it will;
   - `load-command delete codesig` now removes the signature's bytes.
3. `compat/README.md`: `change_dylib -strip-lc codesig`/`code-sign-drs` and
   `patch_macho` now write different bytes from the originals, and why
   (subject to Question 1).
4. `docs/codesign-order.md`: the durable part of "Why" (the order, the
   silent assumption, the index meaning, the signature table), since this
   spec is deleted once implemented. The objc-methods spec's re-signing
   sentence is corrected.

**M4: the real-world run on 10.9**, as in Testing, recorded here. QUEUE item
30 is then closed.

## What could not be verified here

- **Any current `codesign_allocate`.** Decision 2's slots for the chained
  blob and the export trie come from source only.
- **Snow Leopard.** `cctools-782`'s `checkout.c` (SOURCED) has the same
  core order, but its `ofile.c` knows neither `LC_VERSION_MIN_MACOSX`,
  `LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`, `LC_MAIN`, `LC_SOURCE_VERSION`
  nor `LC_DYLIB_CODE_SIGN_DRS`. So 10.6's own `codesign` could not re-sign a
  typical 10.9 output whatever the order, and every `minos` statement adds
  one of those. Which cctools 10.6's last Xcode shipped is NOT VERIFIED
  (782 is inferred), and there is no 10.6 host here. The pass's order is a
  superset, so it will not stand in the way. A per-tool known-command list
  in `mlo_check` is the natural extension when it matters.
- **Rule 6** of Decision 5 (a `fileoff` that is not a multiple of 16): no
  image seen has one, so it is SOURCED only.
- **`import redirect`'s grow path** is in the "breaks today" table from its
  source (`src/redirect.c`), not from a run. M2's CLI test measures it.
- **Whether a modern (sha256) stale signature ever registers on 10.9**:
  observed not to, once.

## Out of scope

- **Signing inside Drydock** (QUEUE item 20.1). With this fix, 10.9's own
  `codesign` does it.
- **Removing load commands 10.9's cctools does not know** beyond the three
  Drydock already removes. None has been seen in a real input.
  `resign 10.9:` names any that remain.
- **32-bit images**, which Drydock refuses.

## Files shared with plans drafting in parallel

| file | this design | notes |
|---|---|---|
| `src/edit.c` | M2: one call after the statement loop, per slice | `me_statements`; nothing else in it changes |
| `src/script.c`, `tests/script_test.c` | M2: `load-command delete`'s mask | one row |
| `src/declassify.c` | M3: stream padding | two roundings |
| `cli/drydock-macho-rewrite.c` | M1: one `info` line | appended at the end of `info_image` |
| `CMakeLists.txt`, `tests/cli_test.sh` | new sources, appended blocks | |
| `README.md`, `compat/README.md` | M3 only | |

## Questions for the owner

1. **Compat wrappers change bytes.** After Decision 3, `change_dylib
   -strip-lc codesig` (and `code-sign-drs`) writes a file without the orphaned
   blob. That makes it re-signable, and different from what the original
   `change_dylib` wrote. `patch_macho` likewise writes the packed layout, not
   the original's appended one. The 2026-09-10 compat matrix is a dated
   record, not a live assertion, so no test breaks, but it is a divergence.
   **Recommended: accept both, recorded as deliberate divergences in
   `compat/README.md`.** The original behaviour is exactly the bug.
2. **Should `target 10.9` strip a signature?** It could derive `load-command
   delete codesig` whenever the image is signed. Stripping is never worse for
   loading (the measured tables), but it destroys information, and the port
   flows re-sign anyway. `target` today derives only what 10.9 needs to load,
   and a stale signature blocks loading only under a kill-flagged host.
   **Recommended: no.** Revisit if a real port meets a kill-flagged host.
3. **Refuse, or only report, an output 10.9 cannot re-sign?** Decision 6
   reports: when the pass declines, or an unknown command remains, the file
   is still written. The alternative is a refusal unless a new directive
   (`allow-unsignable`) is given. **Recommended: report only.** Signing may
   happen on a newer host, and until now no output of `fixups set classic`
   has been re-signable on 10.9 at all.
