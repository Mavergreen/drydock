# Output that 10.9's `codesign` can re-sign

QUEUE item 30 (`docs/superpowers/QUEUE.md`, "## Item 30"). `fixups set
classic` writes an image that 10.9's `codesign_allocate` refuses, and
ad-hoc re-signing is a required step in known port flows (QUEUE item 13, "A
documentation gap"). This spec measures what 10.9's tool requires, finds
every Drydock statement that breaks it, and designs one fix for all of them.
Nothing here is implemented yet.

*Revised 2026-09-26 again while its plan was written: every rule below
was implemented and held to 10.9's own tool on 48 hand-built variants
(`docs/superpowers/plans/2026-09-26-classic-fixups-re-signable.md`), and
four claims changed. A piece with data at `dataoff` 0 never reaches the
writer; a string table without symbols is always written corrupt; two more
layouts make the pass decline; and a slice without `LC_DYSYMTAB` needs its
symbol table 16-aligned. Each is marked "(plan)" below.*

*Revised 2026-09-26 after an independent review. The review reproduced the
evidence and made the verifier exact: it now mirrors the tool rule for rule,
and simulates the tool's writer instead of approximating it. It also closed
three paths to silent corruption and settled fat files. The owner's rulings
on the first draft's questions are at the end.*

Evidence is tagged the way `docs/minimum-os-version.md` tags it:
**MEASURED** on this 10.9.5 host (13F1911), **SOURCED** from a named file in
a named upstream release, and **NOT VERIFIED** where neither was possible.

## Why

### The tool

- **MEASURED.** `codesign` runs
  `/Library/Developer/CommandLineTools/usr/bin/codesign_allocate`; its path
  appears in every refusal. The package is
  `com.apple.pkg.CLTools_Executables` 6.2.0.0.1.1424975374, and the binary
  carries the string `cctools-862`.
- **SOURCED.** [apple-oss-distributions/cctools](https://github.com/apple-oss-distributions/cctools),
  tag `cctools-862`:
  - `libstuff/ofile.c`, `check_Mach_O`: the load-command loop;
  - `libstuff/checkout.c`: `check_object`, `dyld_order()` and
    `symbol_string_at_end()`;
  - `misc/codesign_allocate.c`, `setup_code_signature()` and
    `add_code_sig_load_command()`;
  - `libstuff/writeout.c`, `copy_new_symbol_info()`: the writer.
- **Direct use.** `codesign_allocate -i IN -a x86_64 16384 -o OUT` runs the
  tool with no signing and no keychain, and gives the same refusals.

### "unknown load command N" is the index, not the command

`Mach_O_error(ofile, "malformed object (unknown load command %u)", i)`
(`ofile.c:5959`) prints the loop index `i`, and the loop runs in index
order, so the first unknown command is the one named. SOURCED, and MEASURED:

- Mantle, ReactiveObjC, Squirrel and libGLESv2 say `4`, and ShipIt and
  chrome_crashpad_handler say `5`. In each, that is the 0-based index of
  `LC_DYLD_CHAINED_FIXUPS`.
- A 10.9-linked dylib with one command's `cmd` patched says `7` for
  `LC_BUILD_VERSION` at index 7. It says `12` for `LC_DYLD_EXPORTS_TRIE` and
  for `LC_DYLD_CHAINED_FIXUPS` at index 12, and `9` for `LC_NOTE` at index 9.

**What 10.9's cctools knows** (SOURCED, the `case LC_` labels of
`check_Mach_O`): the commands up to `LC_LINKER_OPTIMIZATION_HINT` (0x2e),
**except `LC_FVMFILE` (0x9) and `LC_PREPAGE` (0xa)**, which have no case.
That includes `LC_VERSION_MIN_MACOSX`, `LC_MAIN`, `LC_SOURCE_VERSION`,
`LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`, `LC_DYLIB_CODE_SIGN_DRS`,
`LC_LINKER_OPTION` and `LC_ENCRYPTION_INFO_64`. It does not know:
`LC_VERSION_MIN_TVOS`, `LC_VERSION_MIN_WATCHOS`, `LC_NOTE`,
`LC_BUILD_VERSION`, `LC_DYLD_EXPORTS_TRIE`, `LC_DYLD_CHAINED_FIXUPS`,
`LC_FILESET_ENTRY`, `LC_ATOM_INFO` or anything later.

**Drydock already removes the three that real images carry:**

- `fixups set classic` strips `LC_DYLD_CHAINED_FIXUPS`,
  `LC_DYLD_EXPORTS_TRIE` and `LC_BUILD_VERSION` (`src/declassify.h`);
- both `minos` statements replace `LC_BUILD_VERSION` with
  `LC_VERSION_MIN_MACOSX`, and `target 10.9` always derives `minos at-most
  10.9`;
- `load-command delete build-version` removes it by hand.

MEASURED: after `fixups set classic`, none of the six images has an unknown
command, and every refusal moves on to the order. A 10.9 dylib given an
`LC_BUILD_VERSION` signs and verifies after `target 10.9`.

### The order

For an `MH_DYLIB`, or any image with `MH_DYLDLINK` (every dyld image), that
has an `LC_DYSYMTAB`, `dyld_order()` (`checkout.c:313–560`) walks a running
offset from `__LINKEDIT`'s `fileoff`. Each piece that is present must start
exactly there. Any other image goes to `symbol_string_at_end()`
(`checkout.c:233–309`, 573–699), which requires only that the string table
end the file (before any signature) and the symbol table directly precede it
(or precede the indirect table that precedes it).

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

Every rule, as the source has it (all SOURCED; MEASURED where it says so).
The verifier mirrors each one (Decision 5):

1. **Where the block starts.** If `rebase_off != 0` it must be the running
   offset. Else if `bind_off != 0`, that must be. Else if `export_off != 0`,
   the check fails only when `export_off` differs **and** both
   `weak_bind_size` and `lazy_bind_size` are non-zero (`checkout.c:350–366`,
   verbatim). The block ends at the end of the first non-empty stream in the
   order export, lazy bind, weak bind, bind, rebase. Nothing checks what lies
   inside. The lowering always writes a non-zero `rebase_off`
   (`declassify.c:730`, `:786`).
2. **A zero `dataoff` skips the placement check but not the advance.** For
   split info, function starts and data in code, `dataoff == 0` skips the
   check, but the running offset still advances by `datasize`. DRs and
   linker hints have no exemption. MEASURED: an empty `LC_DATA_IN_CODE`
   whose `dataoff` is not the running offset is refused.
3. **The one rounding inside.** After a 64-bit indirect table with an odd
   count, the **first** of table of contents, module table, reference table
   and string table that is present may start at the running offset
   rounded up to 8, and the file may end at the rounded offset
   (`checkout.c:465–557`). MEASURED: accepted at the rounding, and refused 8
   bytes past it.
4. **The signature** starts at the running offset rounded up to 16.
5. **The end.** The running offset, or its rounded form, must equal the
   file size.
6. **`__LINKEDIT`.** It must exist (`malformed file (no __LINKEDIT
   segment)`), there must be only one, and when its `filesize != 0` it must
   end the file (`the __LINKEDIT segment does not cover the end of the
   file`).
7. **Counts.** Two places refuse a second command of a kind, and the
   first to see one wins:
   - **the ofile loop**, at the index of the second: `LC_SYMTAB`,
     `LC_DYSYMTAB`, `LC_ROUTINES`, `LC_ROUTINES_64`, `LC_TWOLEVEL_HINTS`,
     `LC_SEGMENT_SPLIT_INFO`, `LC_CODE_SIGNATURE`, `LC_FUNCTION_STARTS`,
     `LC_DATA_IN_CODE`, `LC_DYLIB_CODE_SIGN_DRS`,
     `LC_LINKER_OPTIMIZATION_HINT`, `LC_VERSION_MIN_MACOSX` or
     `_IPHONEOS` (one between them), `LC_PREBIND_CKSUM` and `LC_UUID`
     (`ofile.c:3764–4417`, `malformed object (more than one … command)`);
   - **`check_object`** (`checkout.c:106–206`), after the loop:
     `LC_DYLD_INFO[_ONLY]`, `LC_ID_DYLIB` and `__LINKEDIT`
     (`malformed file (more than one …)`). It also requires an `MH_DYLIB`
     to have an `LC_ID_DYLIB` whose `name.offset` is below its `cmdsize`.
8. **Two-level hints.** `ofile.c:6047` requires `nhints == nundefsym`
   whenever both commands are present, **even when `nhints` is 0**.
   `checkout.c:207–216` repeats the check for non-zero `nhints`.
9. **Header room.** An image without `LC_CODE_SIGNATURE` needs 16 bytes
   for one. The check is `sizeofcmds + 16 + sizeof(mach_header_64)` against
   the lowest file offset of any non-empty, non-zerofill section, or of a
   section-less segment with file data (`codesign_allocate.c:700–736`).
   Otherwise the refusal is `larger updated load commands do not fit`.
   MEASURED: `/usr/lib/libgcc_s.10.5.dylib`'s x86_64 slice passes every
   order rule and is refused this way.
10. **Nothing else about gaps.** MEASURED: 8 bytes inserted before the
    rebase stream, after the export trie, before the symbol table, or before
    the string table, are each refused, and so are 16 bytes after the string
    table.
11. **The streams need no alignment.** MEASURED: Mantle's lowered streams,
    at their odd lengths (2,934 and 8,081 bytes) and packed back to back,
    sign and verify, and `dyldinfo` reads them the same.

### What the writer silently assumes

Passing every rule above does not make a re-sign correct.
`codesign_allocate` never updates a piece's offset in the load commands. Its
writer rebuilds the file and must put every piece back exactly where it was.
It does so only when its own arithmetic agrees with the layout, and nothing
checks that it does. SOURCED:

- `setup_code_signature()` counts the input's symbolic data,
  `input_sym_info_size`, as a **sum**:
  - the symbol and string tables, **only when `nsyms != 0`** (`:319`). The
    order rules check the string table whenever `strsize != 0`
    (`checkout.c:535`);
  - **only when there is an `LC_DYSYMTAB`** (`:387–503`): the five stream
    sizes (`:453–458`), every other piece's size, and the odd-indirect pad.
- The writer, `copy_new_symbol_info()` (`writeout.c:735–840`), has two
  branches:
  - **with `LC_DYSYMTAB`** it writes every piece in the order of the table.
    It copies the dyld-info block as one span, from its first byte to its
    last (`codesign_allocate.c:353–385`), and each linkedit-data piece from
    `object_addr + dataoff` even when `dataoff` is 0, as long as
    `datasize` is not (`:400–424`);
  - **without it** it writes only the symbol table, the string table and
    the signature.
- `writeout.c:700–712` copies the file verbatim up to `P = object_size −
  input_sym_info_size`, writes the pieces from `P`, then writes the
  signature at the written size rounded up to 16.
- So **a piece the writer writes must land on its own offset, and a piece
  it does not write must end at or before `P`**, inside the verbatim copy.
  The second case covers the string table when `nsyms == 0`, and every
  piece but the symbol and string tables in an image without
  `LC_DYSYMTAB`.
- If the sum is not the span, everything after the block shifts by the
  difference. The rounding before the signature can absorb a small shift.
  MEASURED (review): in an image without `LC_DYSYMTAB`, a 16-byte hole
  before function starts re-signs harmlessly, because that branch writes
  no function starts.

MEASURED, three outcomes, all with the order rules passing:

| input | `codesign_allocate` | `codesign -v` | the streams afterwards |
|---|---|---|---|
| 8-byte hole between rebase and bind, **absorbed** by the 16-rounding (review's `gap8`) | exit 0 | passes | identical: harmless |
| 8-byte hole between rebase and bind of a clang-built dylib, unsigned, so the tool adds the signature | exit 0 | **fails** | `__LINKEDIT` runs 8 bytes past the end of the file, and dyld refuses it |
| Mantle in order, then `objc-methods set absolute` (its old rebase stream zeroed inside the block, 2,936 bytes) | exit 0 | **passes** | `dyldinfo -rebase -bind` lists 817 lines where the input had 1,253: **corrupt under a valid signature** |

So **`codesign -v` passing is not evidence of a correct re-sign**, and a
rule of thumb such as "the streams tile their block" is neither necessary
nor sufficient. The verifier therefore **simulates the writer** (Decision
5). `cctools-1035.1.102`'s `codesign_allocate.c:553` makes the same sum, so
a current `codesign` corrupts the same inputs. That part is SOURCED only.

### What Drydock writes today

Each row is MEASURED with `drydock-macho-rewrite` at 88e846f, except where
it says SOURCED.

| statement | what it does to `__LINKEDIT` | 10.9's `codesign_allocate` |
|---|---|---|
| `fixups set classic` | It appends the rebase and bind streams, each 8-aligned, **past the end of the file, after the code signature** (`md_declassify_buf`). The export trie stays where it was, and the chained-fixups blob stays at `__LINKEDIT`'s start with nothing pointing at it (2,816 bytes in Mantle). `__LINKEDIT` is extended over the streams. | `dyld_info out of place`, on all six images |
| `objc-methods set absolute` | It puts the new rebase stream at `__LINKEDIT`'s start and zeroes the old one where it lies (`mma_insert`). | On the lowered frameworks: `link edit information does not fill the __LINKEDIT segment`. On an input in order: **accepted, and written corrupt** |
| `import redirect`, when the bind stream must grow | It moves the bind stream to the end of the file and zeroes the old one (`src/redirect.c`). | SOURCED only: the stream lands after the signature, and the move leaves a hole in the block |
| a header grow (`mg_grow_header`) whose rebuilt export trie is larger | It appends the trie at the end of the file. A signed lzfse, in order, grown by `dylib append`: its 464-byte trie, rebuilt at 470 bytes, landed past the signature. | `function starts data out of place` |
| `load-command delete codesig` | It drops the command and leaves the blob. | `link edit information does not fill the __LINKEDIT segment` |
| `load-command delete code-sign-drs` | It drops the command and leaves the 64 DR bytes between function starts and the symbol table. | `symbol table out of place` |

`mg_grow_header` without a trie rebuild keeps the order. MEASURED on a
signed 10.9 executable grown by 4096 bytes. Files that earlier Drydock
versions wrote carry these layouts too, and so do some that no Drydock
wrote: this host's `Dictionary.app` executable ends in 7,700 bytes after its
string table that nothing points at (review's scan).

### Fat files

`checkout()` runs on **every** architecture in a fat file, not only the one
being signed. So one bad slice refuses the whole file. MEASURED (review): an
x86_64 + x86_64h dylib whose x86_64h slice still has chained fixups is
refused with `unknown load command 4` when `-a x86_64` is signed.

### Does 10.9 need a valid signature at all?

MEASURED here with a clang-built dylib and executable (sdk 10.9), each
ad-hoc signed. A stale signature comes from a header-only edit made after
signing (`rpath append`). The results repeat, and agree with,
`docs/minimum-os-version.md`, "Every sdk check in 10.9.5's own code".

| dylib | from an unsigned host | from a host signed with `-o kill` |
|---|---|---|
| valid signature | loads | loads |
| **stale** signature | loads | **SIGKILL** (`denying page sending SIGKILL`) |
| signature removed (command and blob) | loads | loads |
| re-signed with 10.9's `codesign` | loads | loads |

| executable | runs |
|---|---|
| valid signature, with or without the kill flag | yes |
| stale signature | yes |
| stale signature, signed with `-o kill` | **no, exit 137** |
| signature removed | yes, even one first signed with `-o kill` |

So 10.9 needs no signature, but a well-formed stale one can kill. The real
inputs carry modern signatures: CodeDirectory v=20500, flags 0x10000, which
is the hardened runtime, not the kill flag. Mantle's is sha256. NOT VERIFIED
as a rule: seen once, lowered Mantle printed dyld's failure message
`dyld: Registered code signature for …` from a kill-flagged host and was not
killed.

This decides the shape of the fix: **putting `__LINKEDIT` in order is
necessary and sufficient to re-sign.** Stripping already exists as a
statement, and only needs to stop orphaning the blob. Signing inside
Drydock is not needed.

### The fix, proven by hand first

A prototype written apart from `src/` rewrote `__LINKEDIT` into the order
above. It dropped bytes nothing points at, and kept each piece's bytes and
size. It ran on the six real images after `fixups set classic`: Mantle
`3b59fda2`, ReactiveObjC `35e4e688`, Squirrel `03ef80b1`, ShipIt
`a233da31`, chrome_crashpad_handler `ff634765` and libGLESv2 `cbcf071c`, by
SHA-256; these are OpenCode.app's frameworks, as in the objc-methods spec.
MEASURED, and reproduced by the review:

- All six sign with 10.9's `codesign --force --sign -`, and `codesign -v`
  passes, whether the stale signature is kept last or removed.
- The five-stream `dyldinfo` listing is identical between the lowered image
  and its packed, signed copy: 1,031, 4,258, 1,615, 1,154, 3,693 and 25,848
  lines. So are `nm -ap` and `otool -Iv`.
- Each image stops loading at the same missing 10.9 symbol or library as
  before.
- **The objc-methods chain** (`fixups set classic`, then `objc-methods set
  absolute`) refuses to sign. Packed, it signs and verifies:
  - `dyldinfo` is identical (1,296, 6,206 and 1,985 lines);
  - `drydock-macho-rewrite verify` says OK;
  - `info` counts 32, 143 and 27 absolute lists.
- **Runs on 10.9.** Ghidra 12.0.3's x86_64 `lzfse` (`b089fca1`) and
  `demangler_gnu_v2_41` (`c471fdf3`) have chained fixups. Each was lowered
  with `target 10.9`, `dylib append` of a one-instruction
  `____chkstk_darwin` shim, and `import redirect ____chkstk_darwin
  /usr/lib/libSystem.B.dylib SHIM`. Each was then packed, signed, and passed
  `codesign -v`.
  - The packed, signed `lzfse -decode` restores, byte for byte, a file the
    unpacked build encoded.
  - The demangler prints `foo::bar()`.

The prototype was not written to this spec's piece model. It left the stale
offsets of zero-size dyld-info streams, and the review found that its output
then fails with `dyld_info out of place`. Decision 2 specifies that case.

## Decisions

### 1. One pass, at the end of a slice's run, puts `__LINKEDIT` in order

A new function, `mlo_pack`, rewrites a slice's `__LINKEDIT` into the order
of Decision 2. `me_statements` calls it once per slice after the slice's last
statement, and before `mg_plausible`'s gate, when Decision 4 says to. It
never moves a byte below `__LINKEDIT`'s `fileoff`.

Why one pass at the end:

- **Five writers break the order today**, for five different reasons. One
  pass fixes all five, and any sixth, without teaching each writer where
  things go.
- **The writers keep their verifiers.** `objc-methods`' layout check and
  `import redirect`'s re-walk stay true of what those statements do. The
  pass verifies itself (Decision 5).
- **Nothing between statements needs the order.** dyld reads by offset.
  MEASURED: the out-of-order lowered images load exactly as far as the
  ordered ones, and `objc-methods` accepts the lowered image as it is.

**The road not taken: each statement keeps the order itself.** That means
five placement algorithms, and five changes to verifiers that are correct
today, for the same end state. Choose it only if some statement comes to
need the order in its input. None does.

**Also not taken: an explicit statement** (`linkedit pack`). It would be
needed after exactly the runs that disturb `__LINKEDIT`, so it would be a
line every script must remember, for no case where leaving it out is right.

### 2. The piece model: what the pass moves, and where

**The order** is ld64's, the table in "Why". Two modern pieces are slotted
where `cctools-1035.1.102` wants them: `LC_DYLD_CHAINED_FIXUPS`' blob, then
`LC_DYLD_EXPORTS_TRIE`'s, right after the dyld-info block
(`libstuff/checkout.c:483–535`). That way an image that still has chained
fixups is left in a current tool's order. That order also satisfies
`symbol_string_at_end()`, so the pass uses it for images without
`LC_DYSYMTAB` too. The current-tool slots are SOURCED only, since no current
`codesign` is on this host.

**What a piece is.** A piece is a file range some load command names, of
the size it names:

| piece | offset field | size |
|---|---|---|
| rebase, bind, weak bind, lazy bind, export | `LC_DYLD_INFO[_ONLY]` `*_off` | `*_size` |
| split info, function starts, data in code, DRs, linker hints, chained fixups, exports trie | `dataoff` | `datasize` |
| symbol table | `symoff` | `nsyms` × 16 (`nlist_64`) |
| string table | `stroff` | `strsize` |
| two-level hints | `offset` | `nhints` × 4 (`twolevel_hint`) |
| local, external relocations | `locreloff`, `extreloff` | count × 8 |
| indirect symbols | `indirectsymoff` | count × 4 |
| table of contents, module table, reference table | `tocoff`, `modtaboff`, `extrefsymoff` | count × 8, × 56 (`dylib_module_64`), × 4 |
| code signature | `dataoff` | `datasize` |

**Not pieces.**

- `LC_ENCRYPTION_INFO[_64]`'s `cryptoff` names a range of `__TEXT`. It is in
  `ml_each_off`'s list, so it moves when a header grows, but the pass never
  moves it. The postcondition does not count it among "offset fields that
  may differ".
- A piece that lies outside `__LINKEDIT`, and a section with a non-zero
  `reloff`, make the pass decline.

**What the pass writes:**

- **Each piece keeps its bytes and its size.** The pass concatenates the
  pieces in order. It adds only three kinds of padding:
  - the 8-rounding of rule 3, and only where the input already had it;
  - zeros up to the 16-byte boundary before the signature;
  - (plan) in a slice without `LC_DYSYMTAB` that has a signature, zeros up
    to the 16-byte boundary before the symbol table. That branch of the
    writer starts the symbol table at `P = signature − rnd16(symbols +
    strings)`, which is where it lies only if it is 16-aligned. MEASURED:
    `mkrelmeth codesig+split` after `objc-methods`, packed without it,
    re-signs corrupt.
- **A zero-size piece keeps its offset when that offset already passes
  the rules**, so an image in order stays byte-identical. An empty
  dyld-info stream at 0, or a split-info, function-starts or data-in-code
  piece at `dataoff` 0 (rule 2), stays there. Otherwise the piece is
  placed as ld64 writes it, never left stale:
  - an empty dyld-info stream gets offset 0, so rule 1 keys on the first
    stream that exists;
  - an empty linkedit-data piece gets `dataoff` = the running offset. The
    review's scan found an empty `LC_DATA_IN_CODE` at the running offset
    in 3,741 of the host's 3,953 images.
- **Bytes nothing points at are dropped.** These are the chained-fixups
  blob the lowering orphans; the old streams that `objc-methods`, `import
  redirect` and a grow leave zeroed; the blob of a deleted
  `LC_CODE_SIGNATURE` or `LC_DYLIB_CODE_SIGN_DRS`; and alignment slack.
- **Nothing inside a piece is a file offset**, so moving one needs no
  rewriting:
  - `n_strx` is relative to `stroff`;
  - indirect entries, module-table and reference-table entries are
    symbol or module indices;
  - export-trie child offsets are relative to the trie;
  - an x86_64 relocation's `r_address` is relative to the first writable
    segment's vm address.

  So a symbol or string table that sat between the lowering's streams and
  the rest is simply placed in its turn.
- **`__LINKEDIT`'s `filesize`** becomes the new length, and the slice ends
  there. `vmsize` is kept if it still covers `filesize`. Otherwise it is
  rounded up to the page (4 KB for x86_64, 16 KB for arm64).
- **An image already in order comes out byte-identical.** The pass is
  idempotent.

**The pass declines**, leaving `__LINKEDIT` as it is and saying why, when
it cannot account for every byte it would move:

- `__LINKEDIT` is missing, is not the last segment in the file, or does
  not end the slice;
- a piece lies outside `__LINKEDIT`, or two pieces overlap;
- a section has a non-zero `reloff`, or its file range lies in
  `__LINKEDIT`;
- a load command carries a file offset the pass does not know: `LC_NOTE`,
  `LC_ATOM_INFO`, the function-variant commands, or any command
  `ml_each_off` does not cover that is not known to carry none;
- growing `vmsize` would overlap the next segment;
- (plan) the slice has a signature and an `LC_DYSYMTAB`, and `__LINKEDIT`'s
  `fileoff` is not a multiple of 16. The writer rounds the sum of the sizes
  where the order rounds the offset, so no layout would survive;
- (plan) the dyld info has weak-bind, lazy-bind and export opcodes but no
  rebase or bind opcodes. Rule 1 then wants the export trie first, but the
  writer copies the block from the first stream by *field*, the weak-bind
  opcodes, so no layout both passes and survives.

A decline is reported. Whether the run is then refused is Decision 6's
rule, not the pass's.

### 3. `LC_CODE_SIGNATURE`: keep the stale blob, last; delete means delete

- **The pass keeps an existing signature**, moving its blob to the end, at
  the next multiple of 16. That is where `codesign_allocate` expects it, and
  where `codesign --force` replaces it. It also needs no header room
  (rule 9). MEASURED: all six real images, and the fixtures, re-sign with
  the stale blob kept.
- **`load-command delete codesig` and `delete code-sign-drs` now drop the
  bytes too.** Deleting the command removes a piece, which is an observed
  change (Decision 4), so the pass runs and drops the unreferenced blob. The
  script table's mask for `load-command delete` does not change.

Why keep it rather than drop it:

- dropping is one statement away;
- dropping as a side effect of `fixups set classic` would make a later,
  explicit `load-command delete codesig` match nothing and refuse the run;
- today's output already carries the same stale signature, so keeping it
  changes nothing for loading.

`target 10.9` does not strip signatures (owner, below).

**The road not taken: refuse a signed input.** Every real input is signed.

**Also not taken: drop the bytes but keep the command.** A command
pointing at nothing is neither re-signable nor honest.

### 4. When the pass runs: on observed change, and to repair

The pass runs on a slice the script edited when either of these holds:

1. **The run changed a piece.** Compare the slice as read with the slice as
   the last statement left it. The pass runs if the set of pieces differs,
   or any piece's offset, size or bytes, or `__LINKEDIT`'s `fileoff` or
   `filesize`. Examples:
   - a delete of the signature removes a piece, so the pass runs;
   - a grow moves every offset, so it runs;
   - an in-place byte edit changes a piece's bytes, so it runs: a `dylib
     insert`, `delete` or `replace` that renumbers ordinals rewrites
     `SET_DYLIB_ORDINAL` opcodes and `n_desc`, and `import redirect`
     rewrites binds in place. On an image already in order the pass is then
     a byte-identical no-op and prints nothing;
   - `load-command delete uuid` changes no piece, so it does not;
   - neither does `fixups set classic` on an image that is already
     classic, which declares `MREL_FILE_OFF` but changes nothing;
   - nor does `objc-methods set absolute` with nothing to convert, which
     also declares it.
2. **The output would re-sign corrupt** (Decision 5's writer simulation
   fails), whatever changed. This repairs a hole that the input already
   carried: a file an earlier Drydock wrote, or one like `Dictionary`'s. It
   is the only case where the pass touches `__LINKEDIT` that the run
   did not.

**Why observed change, not the script table's declared mask.** The mask
belongs to the statement kind, not to its operand, so `delete uuid` would
trigger the pass as much as `delete codesig`. The mask is also declared by
statements that then do nothing. And the declared-mask report lines that
tests pin today (`cli_test.sh:2933`; `edit_test.c:613–614`, `:1384–1385`,
`:1503`: "this run disturbed sizeofcmds") stay exactly as they are.

A run that changes no piece, on an output that would re-sign correctly,
**never moves `__LINKEDIT`**: the README's "minimally modified copy". Even
out of order, such an output is only reported (Decision 6).

**Slices the script did not select** (`arch`) are never packed. Their
verdict still counts (Decisions 6 and 7).

### 5. The verifier: `mlo_check`, a pure function with every finding

`src/linkedit_order.[ch]` (`mlo_`) provides `mlo_check(const mi_image *,
mlo_verdict *)`. It reads the image and allocates nothing. It **evaluates
every rule independently and records every finding**, instead of stopping
at the first. Each finding says which rule failed, in `codesign_allocate`'s
own words, and the load-command index where one applies. The verdict
derives two things from the findings:

- **`tool_refusal`**: the message 10.9's tool would print, which is the
  first finding in the tool's own order. The tool's order is the ofile loop,
  then `check_object`, then `dyld_order` or `symbol_string_at_end`, then the
  header room.
- **`corrupting`**: every order rule passes and the writer simulation moves
  a piece. The unknown-command and header-room findings are left out on
  purpose: a newer tool knows more commands, and its writer makes the same
  sum.

The rules:

1. **The ofile loop**, in index order, stopping where the tool stops: the
   first command not in the list in "Why" (`unknown load command N
   (LC_NAME)`) or the first second-of-a-kind the loop refuses (rule 7),
   whichever has the lower index. After the loop: the
   hints-versus-`nundefsym` check of rule 8, and the loop's range check for
   every piece the verifier knows (each lies within the file). The loop's
   command-size checks are `mi_wrap`'s already.
2. **`check_object`**: its own duplicates and the `LC_ID_DYLIB`
   requirement of rule 7, and the non-zero hints check.
3. **`__LINKEDIT`**: present, single, and ending the slice when its
   `filesize != 0` (rule 6).
4. **`dyld_order()`** for an `MH_DYLIB` or an `MH_DYLDLINK` image with
   `LC_DYSYMTAB`, and **`symbol_string_at_end()`** otherwise, each rule for
   rule. That covers rules 1–5, including the start clause as written, the
   zero-`dataoff` advance, and the 8-rounding taken only by the first
   present table and allowed at the end.
5. **Header room** (rule 9), only when there is no `LC_CODE_SIGNATURE`.
6. **The writer simulation**, which replaces the first draft's "streams
   tile their block" and "`fileoff` is a multiple of 16" rules. Neither was
   exact: the review's `gap8` passes a tiling rule's failure harmlessly, and
   `libgcc_s.10.5.dylib`'s `__LINKEDIT` sits at file offset 0x298, which is
   not a multiple of 16. The simulation:
   - computes `input_sym_info_size` exactly as `setup_code_signature()`
     does, including the `nsyms != 0` condition and the odd-indirect pad;
   - takes `P = object_size − input_sym_info_size`;
   - lays the pieces out from `P` in `copy_new_symbol_info()`'s order, for
     the `LC_DYSYMTAB` branch or the other one;
   - copies the dyld-info block as its span, and a linkedit-data piece from
     `dataoff` even when that is 0;
   - places the signature at the rounded written size, or at
     `rnd(linkedit_end, 16)` when the tool adds one.

   It passes only if **every piece the writer writes lands on its current
   offset**, **every piece it does not write ends at or before `P`**, and
   the signature's destination equals its `dataoff`. This covers, exactly:
   - a hole the 16-rounding absorbs (passes) and one it does not (fails);
   - a string table with `nsyms == 0`. (plan) MEASURED: always corrupt.
     The order rules put it last, where the writer, which neither counts
     nor writes it, lands something else or nothing, even when the
     16-rounding keeps `P` where it was (`nsyms-0-short-strtab`);
   - (plan) a split-info, function-starts or data-in-code piece with
     `dataoff == 0` and non-zero `datasize` never reaches the writer. The
     load-command loop refuses it first: it overlaps the Mach-O headers
     (MEASURED, `fstarts-dataoff-0`). The simulation compares bytes where
     the load commands say, so it would also call that case harmless: the
     header copied into an unreferenced gap;
   - an image without `LC_DYSYMTAB`, where only the symbol and string
     tables move, and a hole elsewhere is harmless (the review's `nd.in`).

   The simulation is 862's writer only. An image that still carries a
   chained-fixups or exports-trie blob always fails 862's order rules (the
   walk has no slot for it), so `corrupting` can never be set for it, and a
   1035 writer model would never fire.

Where it is used:

- **As `mlo_pack`'s postcondition, on all findings.**
  - The output must not be `corrupting`.
  - Every order rule must pass. (plan) The pass cures where the pieces lie
    and nothing else, so the refusals it may leave are the ones the input
    already had that are not about order: an unknown command, a duplicate,
    a missing `LC_ID_DYLIB`, header room. An image
    that still carries a chained-fixups or exports-trie blob cannot pass
    862's walk, so for it the postcondition checks instead that the pieces
    lie contiguous in Decision 2's order, with those blobs in 1035's
    slots.
  - Each piece's bytes must be identical at its new offset.
  - Nothing below `__LINKEDIT` may change.
  - The load commands must differ only in piece offsets and `__LINKEDIT`'s
    `filesize` and `vmsize`.

  Any other outcome is `MR_FAIL`, with nothing written. This closes the
  first draft's hole, where "only an unknown command left" skipped the
  order checks.
- **On every write** (Decision 6).
- **In `info`** (Decision 7), and in every test that asserts
  re-signability, on every host. It never runs `codesign`.

**The road not taken: run `codesign_allocate` and read its answer.** CI's
macos-26 tool knows every modern command. It would pass what 10.9 refuses,
and it cannot see the corruption at all. The real 10.9 tool is instead the
oracle for `mlo_check` (Testing).

### 6. Refuse the corrupting, report the rest

Before any file is written, `mlo_check` runs on every 64-bit slice of the
output, selected or not.

- **`corrupting` on any slice refuses the run** (`EX_REFUSED`, nothing
  written). This is the controller's ruling. Every host's `codesign_allocate`
  would re-sign such a file corrupt, so "sign it on a newer host" does not
  apply. By Decision 4 an edited slice reaches this only when the pass
  declined, so the refusal names the decline's reason. That includes a
  header-only edit (`dylib replace`, `load-command delete uuid`) of an
  input that is already corrupting and that the pass cannot repair: it is
  refused. An unselected slice is never packed, so the refusal names the
  slice and the remedy: run the script without `arch`, or on that slice.
- **Any other finding is reported, not refused**, and the file is written.
  That covers an unknown command left behind, a declined pass on a file
  that would not corrupt, an out-of-order slice nothing disturbed, and a
  lack of header room. Signing may happen on a newer host.
- **The report** is one line per slice whose bytes the pass changed:
  `__LINKEDIT re-packed in codesign_allocate's order: A -> B bytes, M
  unreferenced bytes dropped`. The pass does not re-state figures a
  statement already printed, so a statement's own figures read as that
  statement's work and the pack's line carries the final size.
- **A remaining finding gets a line only when the pass changed that slice,
  or the run is refused**: `resign 10.9: …`, in `mlo_check`'s words. A
  written slice the pass did not change prints nothing new, whatever its
  findings. So a `dylib replace` on a still-chained input (unknown load
  command) prints what it printed before; `info` is where its verdict is
  read.

The claim this supports, and the only one: **no statement in this version
of Drydock writes a file that `codesign_allocate` would re-sign corrupt.**

### 7. Fat files: a whole-file verdict

Signing a fat file checks every slice (see "Fat files"), so re-signability
is a property of the file.

- **`info`** prints a whole-file line after the per-slice blocks:
  `resign 10.9: ok`, or `resign 10.9: slice x86_64h: unknown load command 4
  (LC_DYLD_CHAINED_FIXUPS)`. Every slice is covered, including slices the
  run skipped and 32-bit slices. `mlo_check` does not model a 32-bit slice,
  so the verdict says `not checked: slice i386 is not a 64-bit Mach-O`
  rather than guess.
- **The edit report** carries the whole-file line only under Decision 6's
  condition: when the pass changed a slice, or the run is refused.
- **Port flows (README):** 10.9 runs only the x86_64 slice. When another
  slice cannot be made re-signable, for instance an arm64 slice with chained
  fixups, `lipo -thin x86_64` before signing on 10.9.

### 8. The lowering pads its streams to 8

`md_declassify_buf` pads each emitted stream to a multiple of 8, and the
pad counts in `rebase_size` and `bind_size`, as ld64's does. The 10.9 dylib
built here has 7 bytes of rebase opcodes in an 8-byte `rebase_size`. The
zeros are `*_OPCODE_DONE`. This is hygiene, not a fix: odd lengths were
MEASURED to work with dyld, `dyldinfo`, `nm`, `otool -Iv` and `codesign` on
10.9. Nor is 8-alignment an invariant of the output. The pass keeps input
sizes, and `mg_grow_header`'s rebuilt trie is not padded (470 bytes,
above). Implemented in M2, beside the pass, so the lowering's tests change
once.

### 9. Later statements keep the order by construction

| statement | after this design |
|---|---|
| `fixups set classic` | streams appended as now, then packed |
| `objc-methods set absolute` | its zeroed old stream is dropped; its 16-byte pad becomes unnecessary but stays |
| `import redirect` (grow) | the moved stream is packed back into place |
| a grow with a larger trie | the trie is packed back after the bind streams |
| `load-command delete codesig` / `code-sign-drs` | the orphaned blob is dropped |

The objc-methods spec's sentence "leaves the image as re-signable as it
found it" is wrong on an ordered input, because of the hole. M3 corrects it.

## Testing

### Unit fixtures, hermetic (every host, CI included)

**`tests/mklinkedit.c`** (new), in the style of `tests/mkchained.c`: a
hand-laid x86_64 dylib, written as bytes with no linker. It has:

- `LC_ID_DYLIB`;
- `LC_DYLD_INFO_ONLY` with all five streams;
- `LC_FUNCTION_STARTS`, an empty `LC_DATA_IN_CODE` at the running offset,
  and `LC_DYLIB_CODE_SIGN_DRS`;
- `LC_SYMTAB` with locals, externals and undefineds, and `LC_DYSYMTAB` with
  an odd indirect count;
- an `LC_CODE_SIGNATURE` blob;
- header room of 16 bytes or more.

`mklinkedit make VARIANT OUT` writes the canonical layout or one variant.
The rows were measured against 10.9's tool on a clang-built dylib with the
same pieces, less a weak-bind stream, except those marked (review), measured
in the review, and (source), taken from the source. M1's oracle confirms the
(source) rows:

| variant | 10.9's `codesign_allocate` |
|---|---|
| canonical | accepts; the pass is a byte-identical no-op |
| bind before rebase; 8 bytes before rebase | `dyld_info out of place` |
| export trie between two streams; 8 bytes after the trie; symbol table before function starts; function starts last | `function starts data out of place` |
| empty data-in-code at a stale `dataoff` | `data in code info out of place` |
| 8 bytes before the symbol table; string table first | `symbol table out of place` |
| string table 8 bytes past the 8-rounding | `string table out of place` |
| odd indirect table, string table at the 8-rounding | accepts |
| signature off 16, or 16 bytes late | `code signature data out of place` |
| bytes after the signature, or after the string table | `link edit information does not fill …` |
| **hole in the block, not absorbable**: 16 bytes between rebase and bind, which no rounding can hide (source; an 8-byte hole the layout did not absorb was measured corrupt) | accepts, then writes a corrupt file (`corrupting`) |
| hole in the block, absorbed: the `gap8` layout (review) | accepts, correct (not `corrupting`) |
| `nsyms == 0` with a string table (plan; two layouts) | accepts, then writes a corrupt file (`corrupting`) |
| function starts with `dataoff == 0`, `datasize != 0` (plan) | `malformed object (… overlaps …)` |
| no `LC_DYSYMTAB`, 16-byte hole before function starts (review, `nd.in`) | accepts, correct |
| `LC_TWOLEVEL_HINTS` with `nhints == 0`, `nundefsym != 0` (source) | `nhints … not the same as nundefsym` |
| no `LC_ID_DYLIB`; `LC_ID_DYLIB` with `name.offset >= cmdsize` (source) | `no LC_ID_DYLIB` / `name.offset … extends past` |
| signature deleted and `sizeofcmds` filling the header (as `libgcc_s.10.5.dylib`) | `larger updated load commands do not fit` |
| `cmd` patched to `LC_BUILD_VERSION`, `LC_NOTE`, `LC_DYLD_EXPORTS_TRIE`; to `LC_FVMFILE`, `LC_PREPAGE` (source) | `unknown load command N` |
| zero-size bind stream with a stale `bind_off` and no rebases (review) | `dyld_info out of place` |
| a fat x86_64 + x86_64h file, one slice chained (review) | whole file refused for the other slice |

The tests that use the fixtures:

- **`tests/linkedit_order_test.c`**:
  - `mlo_check`'s full findings on every variant: every finding, not only
    the first;
  - `mlo_pack` on every out-of-order variant gives an image `mlo_check`
    accepts, with every piece's bytes intact;
  - the no-op on the canonical layout, and on `tests/fixture.macho` (the
    invariant that keeps `tests/EXPECTED` and the known-callers digests
    unchanged: that fixture is unsigned and in order);
  - each decline case.
- **`tests/cli_test.sh`**:
  - `fixups set classic` on a new `mkchained make-signable` variant, with
    `LC_SYMTAB`, `LC_DYSYMTAB` and `LC_ID_DYLIB`. Today's fixture has none,
    and 10.9's tool refuses it for that before any order.
  - `objc-methods set absolute` on a new `mkrelmeth` variant with
    `LC_DYSYMTAB`. No `mkrelmeth` layout has one today, so `resign 10.9:
    ok` could not pass on any of them.
  - `load-command delete codesig` and `code-sign-drs` pack.
  - `delete uuid` does not pack.
  - `dylib insert` on an out-of-order image packs (the ordinal renumbering
    is an in-place byte edit), and on the canonical image is a silent no-op.
  - A `dylib replace` on a still-chained image prints nothing new.
  - A trie-growing grow, and `import redirect`'s grow.
  - A corrupting output is refused: a run that leaves the unabsorbable hole
    with the pass made to decline, and an unselected fat slice carrying
    one.
  - The whole-file `resign 10.9:` on a fat file.
  - In each case: `imports` and `exports` unchanged.
- **`tests/script_test.c`**: unchanged. No row's mask changes.

### Tests and compat output this changes (M2 updates each in the same task)

| where | today | after |
|---|---|---|
| `tests/import_redirect_test.sh:163–168` | the grown bind stream "now lives at file offset 0x…", its offset changed, and `__LINKEDIT` grew | packed back: the review measured `__LINKEDIT` 303 → 296. Assert the stream grew, `resign 10.9: ok`, and the imports. |
| `tests/cli_test.sh:4166` | `__LINKEDIT extended by N bytes` | still the lowering's own figure; the pack line follows with the final size |
| `tests/cli_test.sh:4967` | `__LINKEDIT 512 -> 592 bytes, moved up 4,096` | still objc-methods' own figure; the pack line follows (mkrelmeth has no `LC_DYSYMTAB`, so the pack uses `symbol_string_at_end`'s order) |
| `tests/wrapper_test.sh:915` | `Added LC_DYLD_INFO_ONLY: rebase=OFF+N bind=…` | the offsets are the lowering's, not the output's; the pack line follows |
| `tests/cli_test.sh` ~5028–5066 (objc-methods on skipped or arm64 slices) | no pack noise | still none: nothing changed, so no pack (Decision 4) |
| `patch_macho`, `change_dylib -strip-lc codesig`/`code-sign-drs`, `insert_dylib --strip-codesig`, `bake-mavericks-shim` (signed input) | as today | each prints the re-packed line, and writes packed bytes |
| `compat/README.md:819` (`bake-mavericks-shim`: "leaves the signature's bytes"; the Python truncates) | a divergence | no longer a divergence: both truncate. Delete the row. |
| `compat/README.md`, `bake-mavericks-shim` row "When the stream has to grow, both put it at the end of `__LINKEDIT`", and its summary text `regular table relocated to the end of __LINKEDIT` | true | false after the pack: it now goes back in order. Reword both. |
| `tests/characterize.sh` `EXPECTED`, `tests/known-callers.sh` digests | | unchanged, by the `fixture.macho` invariant above |

### The oracle: a local ctest entry, run on 10.9 before each milestone closes

**`tests/codesign_order_test.sh`**, registered with ctest and
`SKIP_RETURN_CODE 77`. It runs `codesign_allocate -i F -a x86_64 16384 -o
OUT` on every `mklinkedit` variant, and on every output the other suites
pack. Its equality is defined per variant:

- **The tool refuses:** its message equals `mlo_check`'s `tool_refusal`.
- **The tool accepts:** `mlo_check` has no tool refusal. The set of pieces
  whose bytes at their load-command offsets differ between F and OUT equals
  the set the simulation says would move. Those are the pieces other than
  the signature, since the tool legitimately changes the header, the
  signature and `__LINKEDIT`'s sizes. That set is empty exactly when
  `corrupting` is false. The absorbable-hole variant is the case where
  exit status and this set disagree with a naive tiling rule.

It exits 77 with the reason unless the tool carries the string
`cctools-862`: any other tool's verdicts legitimately differ. **A milestone
does not close until this entry has run, not skipped, on the 10.9 host**,
per memory "Check CI, not just local suites".

### Real binaries, on 10.9, by hand (M4)

On fresh copies, never the originals:

- the six OpenCode.app images and the two Ghidra executables;
- `target 10.9`, then `objc-methods set absolute` for the three frameworks,
  then the shim lines for the Ghidra pair;
- `codesign --force --sign -` and `codesign -v`;
- `dyldinfo` (five streams), `nm -ap` and `otool -Iv`, compared before and
  after signing;
- run both Ghidra tools.

The expected figures are the prototype's. The results are recorded in this
spec.

### CI

macos-26 arm64 runs everything except the oracle, which skips. The fixtures
are bytes, so no host fact enters a verdict. `mlo_check` is the same on every
host by construction, which is why it, and not the host's `codesign`, is the
check.

## Milestones

Each is its own plan. Tasks are sized for one implementer subagent each,
TDD and mutation-proved per
`.superpowers/sdd/2026-09-26-deferred-items/constraints.md`. Each milestone
closes only after the 10.9 oracle has run.

**M1: the verifier.**
1. `tests/mklinkedit.c`: the canonical dylib and the order variants.
2. `mlo_check`: `__LINKEDIT`, `check_object` and `dyld_order()`, with every
   finding recorded; `tests/linkedit_order_test.c`.
3. `symbol_string_at_end()`, header room, and the ofile loop (known
   commands, hints).
4. The writer simulation and `corrupting`, with the hole variants and the
   two "settled by the oracle" variants.
5. `info`'s whole-file `resign 10.9:` line, fat included; `cli_test.sh`.
6. `tests/codesign_order_test.sh` as a ctest entry.

**M2: the pass.**
1. `mlo_pack` on a buffer: the piece model and postconditions; unit tests
   on every out-of-order variant, the no-op, and `fixture.macho`.
2. The declines, each a test.
3. Observed-change detection and the call in `me_statements`, per slice,
   with the report line.
4. The refusal of `corrupting` outputs on every write, selected or not.
5. The lowering's 8-padding (Decision 8), `mkchained make-signable`, and
   the lowering's CLI tests, including `wrapper_test.sh:915`.
6. The `mkrelmeth` variant with `LC_DYSYMTAB`; objc-methods, deletes,
   the trie grow and redirect's grow; every row of "Tests and compat output
   this changes".

**M3: the words.**
1. README: a "Re-signing" paragraph (sign last; `resign 10.9:`; `lipo
   -thin` for fat files with an unfixable slice), and `load-command delete
   codesig` now removes the bytes.
2. `compat/README.md`: the divergences, one per affected wrapper
   (`patch_macho`, `change_dylib -strip-lc codesig`/`code-sign-drs`,
   `insert_dylib --strip-codesig`); delete the `bake-mavericks-shim` row at
   `:819`; reword its grow row and summary text.
3. `docs/codesign-order.md`: the durable part of "Why", since this spec is
   deleted once implemented. That means the rules, the writer's assumption,
   the index meaning, fat files, and the signature table. Also correct the
   objc-methods spec's re-signing sentence.

**M4: the real-world run on 10.9**, recorded here. QUEUE item 30 then
closes.

## What could not be verified here

- **Any current `codesign_allocate`.** The slots for the chained blob and
  the trie, and the claim that the same sum corrupts there, are SOURCED
  only.
- **Snow Leopard.** `cctools-782`'s `checkout.c` (SOURCED) has the same
  core order. Its `ofile.c` knows none of `LC_VERSION_MIN_MACOSX`,
  `LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`, `LC_MAIN`, `LC_SOURCE_VERSION`
  and `LC_DYLIB_CODE_SIGN_DRS`. So 10.6's own `codesign` could not re-sign a
  typical 10.9 output in any order, and every `minos` statement adds the
  first of those.
  - Which cctools 10.6's last Xcode shipped is NOT VERIFIED; 782 is
    inferred.
  - The pass's order is a superset of 10.6's, so it will not stand in the
    way.
  - A per-tool known-command list in `mlo_check` is the extension to make
    when it matters.
- **A signature added to an image whose `__LINKEDIT` `fileoff` is not a
  multiple of 16.** `codesign_allocate.c:624–633` sets `filesize =
  rnd(filesize, 16) + datasize`, rounding the size where `dataoff` rounds
  the end. MEASURED (review): on `libgcc_s.10.5.dylib`'s stub (fileoff
  0x298) given header room, the allocated file's `__LINKEDIT` ends 8 bytes
  past the signature. Whether a signature over that verifies was not
  checked. `mlo_check` reports it as a non-corrupting finding,
  `__LINKEDIT fileoff not a multiple of 16`, when there is no
  `LC_CODE_SIGNATURE`. The only image seen with it is refused for header
  room first.
- **`import redirect`'s grow path** is in the "writes today" table from its
  source. The review's `ir/grow` run measured the packed size.
- **Whether a modern (sha256) stale signature ever registers on 10.9**:
  observed not to, once.

## Out of scope

- **Signing inside Drydock** (QUEUE item 20.1). 10.9's own `codesign` does
  it once the output is in order.
- **Removing commands 10.9's cctools does not know**, beyond the three
  Drydock removes. None has been seen in a real input, and `resign 10.9:`
  names any that remain.
- **32-bit slices**, which Drydock does not edit, and `mlo_check` does not
  model.

## Files shared with plans drafting in parallel

| file | this design | notes |
|---|---|---|
| `src/edit.c` | M2: the observed-change snapshot, one call after the statement loop per slice, the pre-write check | `me_statements`, `me_run`, `me_run_fat` |
| `src/declassify.c` | M2: stream padding | two roundings |
| `cli/drydock-macho-rewrite.c` | M1: the `resign 10.9:` line | after the slice blocks |
| `CMakeLists.txt`, `tests/cli_test.sh` | new sources, one ctest entry, appended blocks | |
| `tests/import_redirect_test.sh`, `tests/wrapper_test.sh` | M2: the rows above | |
| `README.md`, `compat/README.md` | M3 only | |

## The owner's answers (2026-09-26)

1. **Compat wrappers change bytes: accepted.** Each is recorded as a
   deliberate divergence in `compat/README.md`: `patch_macho`, `change_dylib
   -strip-lc codesig`/`code-sign-drs`, and `insert_dylib --strip-codesig`.
   So is one more: a wrapper run that matched nothing (`allow-unmatched`)
   on an input that is already corrupting now rewrites that input in place,
   repaired (Decision 4), where the original tool left it as it was. The
   `bake-mavericks-shim` divergence row at `:819` is deleted, because that
   difference no longer exists.
2. **`target 10.9` does not strip signatures.**
3. **Report, not refuse**, for an output 10.9 cannot re-sign, **except** one
   that would re-sign corrupt. That is refused (Decision 6), because no
   host's `codesign_allocate` re-signs it correctly.

No question is open.
