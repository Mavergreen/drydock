# Growing a dylib's header, and code that addresses its own header

Every statement that adds or lengthens a load command needs header pad, and
`mg_ensure_pad` (`src/grow.h`) grows the pad when it is short. Today it can
only grow a PIE executable: it lowers the image base into `__PAGEZERO`, and a
dylib or bundle has none (`ERROR: only MH_EXECUTE can be grown`).

This spec does two things, in four milestones:

- **It fixes a bug in the executable grow** (QUEUE item 29). Code that reaches
  its own header by RIP-relative distance breaks silently when the header
  moves. The fix is to warn first (M0), then repair (M1).
- **It adds a second route for `MH_DYLIB` and `MH_BUNDLE`** (QUEUE item 31),
  so that `dylib insert`, `dylib append`, `dylib replace`, `rpath append`,
  `rpath insert`, `rpath replace`, `minos if-absent` and every later
  statement that needs pad work on frameworks with no change of their own
  (M2, proven in M3).

The design was reviewed adversarially before approval. The review covered
1517 10.9 system images and 150 app images, and found the header-reference
problem. That review's findings are folded in below.

## Why

**Real dylibs have almost no pad.** Measured 2026-09-25: the three x86_64
frameworks in `~/Downloads/OpenCode.app` (Mantle, ReactiveObjC, Squirrel;
macOS 12 target) have 16, 24 and 16 bytes. An `LC_LOAD_DYLIB` or `LC_RPATH`
for a realistic path needs 50 to 100.

**The work that needs it:**

- `docs/macl-case-study.md` row 23: MACL injects its stub library "into the
  main binary and every framework". The case study credits `dylib insert`
  with this, but on a framework with 16 bytes of pad Drydock refuses today.
  Row 9, injecting a bundled CoreUI, has the same shape.
- Mavergreen swift-runtime's README tells users to run
  `rpath replace /usr/lib/swift /usr/local/mavergreen/swift-runtime/lib/swift`.
  The new path is 32 bytes longer.
- objc-methods (`specs/2026-09-23-objc-method-lists-design.md`, Decision 1)
  abandoned its first layout for the same reason. It does **not** change
  back once this lands; that spec says why.

**What the existing grow refuses.** `mg_classify` over 321 real dylibs,
thinned to x86_64:

| where | accepted | refused: `LC_SEGMENT_SPLIT_INFO` | refused: chained fixups |
|---|---|---|---|
| 10.9 system (`/usr/lib`, `/System/Library/Frameworks`) | 2 | 283 | 0 |
| app frameworks (`/Applications`, `~/Downloads`) | 24 | 3 (Sparkle ×2, RegexKit) | 4 |

**The header-reference bug, reproduced.** A ten-line executable calls
`getsectiondata(&_mh_execute_header, "__DATA", "__data", …)`. After
`rpath append` of a 3000-byte path:

- Drydock grows its header by 4096 and exits 0;
- `verify` passes;
- the binary segfaults (exit 139).

The same program asking `_dyld_get_image_header(0)` instead, grown the same
way, runs.

The pattern (code that takes the header's address RIP-relatively) is in:

- 19 of 302 executables on this host;
- 53 of 1517 10.9 system images;
- 63 of 150 app images.

Among them: AppKit and CoreFoundation, which read their own sections that
way; CFNetwork's `lazy_load_dylib`; libc++, which passes `&__dso_handle` to
`__cxa_atexit`; and a 10.12-SDK iTunes bundle, which passes it to
`os_log`. The Claude Code executable has 7, all `&__mh_execute_header`
passed to `__cxa_atexit`, where it is only an identity key.

## Decisions

### 1. Two routes, one rule

`mg_grow_header` chooses its route by file type:

- `MH_EXECUTE` with `MH_PIE`: **lower** the image base, as today.
- `MH_DYLIB` or `MH_BUNDLE`: **raise** the contents, below.
- Anything else: refused, as today.

**The raise.** Define:

- `__TEXT` is the segment with `fileoff` 0 and `filesize` > 0 (as
  `mg_patch_cb` identifies it), and **base** is its `vmaddr`;
- F is the first section's file offset (`mg_first_sect_off`);
- G is the shortfall, rounded up to a 4 KB page (`MG_PAGE`).

G zero bytes are inserted at file offset F. Everything from F to the end of
the file moves up by G, in file and in vm. The header and load commands stay
at file offset 0 and at base.

**Why most existing machinery already applies.** Measured from the base,
both routes move every section up by G. The executable route does it by
moving the base down, the dylib route by moving the contents up. So every
structure that stores a distance from the base gains G in both routes, and
`grow`'s existing walkers for those apply unchanged:

- `__unwind_info` (`mg_unwind_walk`);
- the export trie (`mg_trie_walk`);
- the leading `LC_FUNCTION_STARTS` delta;
- `LC_DATA_IN_CODE` (`mg_dice_walk`);
- `S_INIT_FUNC_OFFSETS` (`mg_init_offsets_pass`).

What differs is absolute vm addresses, and in opposite halves:

- **The dylib route** moves the content, so it adds G to every absolute
  address that names content, and leaves header-namers alone.
- **The executable route** moves the header, so content-namers stay put, and
  every absolute address that names the header must *lose* G: the
  `__mh_execute_header` symbol, and any rebased data pointer to the header.
  Before M1 the executable route adjusted none of these. M1 moves the symbol;
  data pointers to the header need the complete rebase decoder and are QUEUE
  item 29's remaining half. 46 of 838 executables on this host have one; the
  Claude Code executable has none.

**The one rule.** Anything that names the header (address exactly base, or
base-relative offset exactly 0) moves with the header. Anything that names
content (base + F or above) moves with the content. Anything strictly
between is refused. On the dylib route the header does not move, so
header-namers are unchanged; on the executable route the content does not
move, so content-namers are unchanged.

The adversarial review measured every symbol, rebase value, export offset
and RIP-relative target in all 1667 images: none falls strictly inside
(base, base + F). Every reference to the header names exactly base. The rule
also refuses:

- any `__TEXT` section whose `addr − base` differs from its `offset`;
- any section whose `addr` is below the first section's.

**The header does not move with the content.** So a *distance* from content
to the header changes by G, in both routes. In the executable route the
header moves down by G while code stays put. In the dylib route the code
moves up by G while the header stays put. Decision 3 handles those
distances.

**Confirmation needs function boundaries and, ideally, data-in-code.**
Decision 3's sweep starts at a function start and must not decode data as
instructions. The 10.9 toolchain writes no `LC_DATA_IN_CODE` entries and
puts switch jump tables inside `__text`, so a candidate that follows such a
table within its own function cannot be confirmed, and the grow refuses.
None of Claude Code's 7 is in that position. Expect it among 10.9 system
dylibs in M2 and M3.

### 2. What changes on the raise route

| structure | change | by |
|---|---|---|
| every segment except `__TEXT`: `vmaddr` | +G | new |
| every segment: `fileoff`, when ≥ F (a zerofill-only segment keeps `fileoff` 0) | +G | new, matching `ml_bump` |
| `__TEXT`: `vmsize`, `filesize` | +G | new |
| each section: `addr` | +G (a zerofill section's `offset` stays 0) | new |
| each section: `offset`, `reloff`; every `__LINKEDIT` offset | +G | existing, `mg_each_fileoff` |
| the pointer value at every rebase target | +G if it names content; unchanged if exactly base | new |
| symbol `n_value`: `N_SECT` symbols | +G if it names content | new |
| stabs: `N_BNSYM`, named `N_FUN`, `N_STSYM`, `N_LCSYM`, `N_SLINE`, and `N_SO`/`N_SOL` with `n_sect != 0` | +G if it names content | new |
| stabs: `N_ENSYM` (a size), `N_OSO` (a timestamp), unnamed `N_FUN`, `N_GSYM`, `N_OPT`, `N_OLEVEL`, `N_AST` | unchanged | — |
| any other stab type | refused | — |
| `LC_ROUTINES_64.init_address` | +G | new |
| unwind info, function starts, data-in-code, `__init_offsets` | +G | existing walkers |
| export trie, regular and stub-and-resolver entries | +G | existing walker |
| export trie, `EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE` entries | **unchanged**: an absolute value, not an offset | fix to the existing walkers (affects the executable route too; M0) |
| RIP-relative displacements from content to the header | −G | Decision 3 (M1) |
| `LC_UUID` | replaced, Decision 5 | new |
| `LC_SEGMENT_SPLIT_INFO` | the load command is deleted, Decision 4 | new |
| rebase and bind opcodes (segment index + offset within it) | none: segments move whole, and none may target `__TEXT` | — |
| content-to-content RIP-relative code, `__eh_frame`, LSDA tables, `S_DTRACE_DOF` (offsets from the DOF section itself), Swift metadata, relative Objective-C method lists, TLV descriptors' `offset` | none: both ends move together | — |
| `LC_CODE_SIGNATURE` | offset bumped; the signature is invalid, as after every edit | existing |

**Why the list is complete.** A dylib always slides, so dyld must be told
about every absolute address in it. So an absolute address can live only:

- at a rebase target (handled);
- at a bind target, which dyld overwrites (nothing to do; a lazy pointer's
  initial stub-helper address is itself a rebase target, and the review
  found every weak-bind slot paired with a rebase or a bind);
- in a symbol or a load-command field (handled).

An absolute address in `__TEXT` would need a text relocation, which
Decision 6 refuses. Every other address is a distance:

- from the base (handled by the existing walkers);
- between two pieces of content (invariant);
- between content and the header (Decision 3).

The last kind **cannot be found from linker metadata**. Decision 3 finds
them in code. They could also exist in data, as a constant
`sym − __dso_handle` with no rebase: no scan can find those. None was found
in the 1667 images, but none can be ruled out. That is the residual risk,
named here so no reader mistakes the scan for a proof.

The review's per-structure evidence for this table (every section kind, load
command and export form it checked, with counts) is summarized in the
Appendix.

### 3. Code that addresses its own header (M0 warns, M1 repairs)

**Finding them: a scan that cannot miss an instruction form.** In 64-bit
mode every RIP-relative operand is a ModRM byte with `(b & 0xC7) == 0x05`,
then a disp32 with no SIB, then 0, 1, 2 or 4 bytes of immediate. The scan
covers every section with `S_ATTR_PURE_INSTRUCTIONS` or
`S_ATTR_SOME_INSTRUCTIONS`, at every byte position. For each immediate
length in {0, 1, 2, 4}, a position is a **candidate** if its target is
exactly base.

It over-reports but never under-reports. On an 80-image sample it flagged 6
images, against 5 found by a scan for `lea` alone.

**M0 (the stop-gap, on the executable route, the only one that exists
yet): any candidate is announced, and the grow proceeds.** One line per
candidate, on stderr, beside the grow's own announcement:

```
LABEL: warning: code at 0x1000028b2 addresses the image's own header; after this grow it points 0x1000 bytes past it (QUEUE item 29)
```

*Owner's decision, 2026-09-25:* warn rather than refuse. A fresh Claude
Code download has 7 candidates, all `&__mh_execute_header` passed to
`__cxa_atexit` as an identity key, which is why grown copies run. Refusing
would stop Drydock growing the binary it was built for until M1 lands. The
warning makes item 29 visible instead of silent. M1, next, repairs every
candidate, and removes the warning with it.

**M1 (the repair): confirm each candidate is an instruction, then patch it.**
The candidate's containing function is found through `LC_FUNCTION_STARTS`.
From that function's start, an x86-64 instruction-length decoder sweeps
linearly to the candidate, skipping `LC_DATA_IN_CODE` ranges.

- If the sweep lands on an instruction whose ModRM and displacement are
  exactly the candidate's, it is confirmed. The patch is
  `disp32 −= G` in both routes, since in both the header ends up G bytes
  closer to the code than before.
- If the sweep does not land there, or the image has no
  `LC_FUNCTION_STARTS` to anchor it, the candidate is unexplained and the
  grow refuses.

The decoder is a new, self-contained module. Its oracle is independent of
it: on this host, the decoder's instruction boundaries must equal
`otool -tV`'s over every function of a corpus of real 10.9 binaries. This
is a test, not a runtime dependency.

After M1, verification (Decision 7) re-runs the scan on the output. In
both routes, a reference that was missed would now target the new base
plus G, so:

- no candidate may target new base + G;
- every patched instruction must target the new base.

### 4. `LC_SEGMENT_SPLIT_INFO` is dropped on the raise route

Split info lists every cross-segment reference in a dylib, so that
`update_dyld_shared_cache` can pack the dylib's `__TEXT` and `__DATA` into
separate regions of the shared cache and patch those references. Nothing
reads it when a dylib loads from its own file, and 10.9's dyld never reads
it. After a raise its recorded positions are stale.

| after a raise | loading from disk | a shared-cache build |
|---|---|---|
| stale split info (never an option) | works | corrupts the cache |
| re-based | works | works, if the re-basing is right; no test here could tell |
| **dropped (chosen)** | works | skips this dylib, safely |
| refused (today) | growth never happens | — |

Dropping is the only choice whose result this subsystem's tests can fully
check. It removes the 16-byte load command, which adds 16 bytes of pad, and
leaves the payload as dead bytes in `__LINKEDIT`. The input keeps its split
info, since Drydock never writes its input.

**Mechanics:**

- The drop is its own step. `mi_each_lc` forbids editing `cmd`, `cmdsize`
  or `ncmds` from a callback.
- It happens on the working copy **before** `mg_snapshot_take`. Otherwise
  `mg_verify` would count one fewer watched offset afterwards: `ml_each_off`
  visits split info's `dataoff`.
- `mg_classify` gains a route argument, since split info is accepted on one
  route and refused on the other. It cannot move into
  `ML_PLAIN_OFFSET_LCS`: `linkedit.h`'s duplicate-case guard forbids it.
- The executable route still refuses split info, as today.

**Nothing else can name split info today.** The `lc delete` vocabulary
(`src/lc_kinds.c`'s `LC_STRIP_KINDS`) has no word for it. `src/rewrite.c`'s
comment that a grow never changes the set of load commands becomes false;
M2 corrects it and adds a test pinning that no statement can name split
info. If the vocabulary ever grows to include it, that test fails first.

### 5. `LC_UUID` is replaced on the raise route

The executable route moves no vm address, so an image's dSYM stays valid.
A raise moves every content address by G. The old dSYM would then give wrong
symbols for every frame, and lldb and `atos` would trust it because the UUID
matches. A wrong answer is worse than a missing one, so **the raise replaces
the UUID**:

- It is derived deterministically, so the same input and G always give the
  same output: the first 16 bytes of SHA-256 over the old UUID and G, with
  the version nibble set to 4 and the variant bits to RFC 4122.
- The announcement says so (Decision 8).

The executable route keeps its UUID.

*Controller's ruling, not the owner's; recorded so it can be reversed.* The
alternative, keeping the UUID and warning in the announcement, is one line
to switch to.

### 6. Refusals

`EX_REFUSED`, with the reason on stderr and nothing written, before
anything is mutated:

- anything `mg_classify` refuses today, except split info on the raise route;
- chained fixups (`fixups set classic` first), as today;
- a slice that is not x86_64, as today;
- **no `LC_DYLD_INFO[_ONLY]`** (raise route). Only compressed dyld info
  guarantees that every absolute address is a rebase target. This also
  covers every image with old-style relocation entries: all 24 such images
  surveyed are classic, built for 10.5 or earlier;
- a rebase whose type is not `REBASE_TYPE_POINTER` (the 32-bit types hold
  32-bit values);
- a rebase target past its segment's `filesize`: its value must be read from
  the file;
- a rebase or bind whose target lies in `__TEXT` (a text relocation);
- a rebase value, symbol, export offset or RIP-relative target strictly
  inside (base, base + F), or a rebase value outside every segment;
- `LC_ENCRYPTION_INFO[_64]` with `cryptid` ≠ 0;
- a segment with `SG_PROTECTED_VERSION_1`;
- `LC_UNIXTHREAD` or `LC_THREAD` in a dylib or bundle;
- a header-reference candidate the decoder cannot confirm, from M1 on. (M0
  warns on every candidate instead; the raise route arrives in M2, after
  the repair exists);
- the existing ULEB-widening refusal of the function-starts leading delta.
  **Except** that a leading delta of 0 means an empty list and is left
  alone. Seventeen codeless umbrella frameworks (Cocoa, Carbon, …) have
  that, and are refused today for the wrong reason;
- the export trie's existing widen-append path, unchanged.

None of the refusals added here fired on the three motivating frameworks.

### 7. Verification

Every grow verifies itself and refuses, writing nothing, on any difference.
Checks 1–3 derive their expectations from Decision 2's table, so they catch
slips in the implementation but not a row missing from the table. Checks 4–6
are independent of the table, and exist to catch exactly that.

1. **Relation.** `mg_snapshot_take` / `mg_verify` gain a delta, 0 for the
   executable route and G for the raise. Every base-relative structure and
   every `mg_each_fileoff` offset must resolve at its old vm address plus the
   delta, or at base if it named the header.
2. **Absolute addresses** (raise). Decode old and new rebase targets,
   symbols, segment and section addresses, and `LC_ROUTINES_64`. Each must
   equal its old value plus G, or its old value if it named the header. The
   rebase targets must be the same set, at the same segment offsets.
3. **Bytes.** From F onward, the new file equals the old one moved up by G,
   except at the fields Decision 2 names and the instructions Decision 3
   patched. Below F, the load commands are compared command by command, and
   each is byte-identical except for those fields, the replaced UUID, and
   the deleted split info. The rest of the pad is zero.
4. **Independent oracles.**
   - Every `S_MOD_INIT_FUNC_POINTERS` / `S_MOD_TERM_FUNC_POINTERS` value and
     `LC_ROUTINES_64.init_address` is a function start.
   - Every `__la_symbol_ptr` value lies in `__stub_helper`.
   - For every regular export, base + trie offset equals the `n_value` of
     the same-named `N_SECT | N_EXT` symbol. Two structures, adjusted by two
     different code paths, must agree.
5. **The header-reference scan** (Decision 3), re-run on the output.
6. **`mg_plausible`**, as today, and **no two segments overlap in vm**.

### 8. What the user sees

Growth stays automatic and announced. The raise route's line:

```
LABEL: grew the header pad by 4096 bytes (16 -> 4112 available); contents raised by 0x1000; new UUID
LABEL: grew the header pad by 4096 bytes (16 -> 4128 available); contents raised by 0x1000; new UUID; dropped LC_SEGMENT_SPLIT_INFO
LABEL: grew the header pad by 4096 bytes (16 -> 4112 available); contents raised by 0x1000; new UUID; repaired 3 references to the header
```

The executable route keeps its line, plus the M1 clause when it patches:
`image base 0x100000000 -> 0xfffff000; repaired 3 references to the header`.
Tests match the stable prefix, `grew the header pad by`.

`src/relations.h` gains a row for the raise: it moves every absolute
content address and may remove a load command. Every statement re-parses
afterward, so no new relation bit is expected. The plan confirms that.

### 9. The rebase decoder is shared with objc-methods M2

The raise needs every rebase target, with its type, in stream order.
objc-methods M2 landed `src/rebase.[ch]` (da5f03a..f818638, with
`mrb_has_type` added in bfe68ef): `mrb_slot {off, seg, type}` and an
`mrb_decode` that bounds the segment index.

That interface sees no segment geometry. So the raise itself refuses a type
other than `REBASE_TYPE_POINTER`, and checks that offset + 8 ≤ the segment's
`filesize` (Decision 6).

Whichever plan executes first builds the module. This subsystem adds an
oracle test to it: its output equals
`/Library/Developer/CommandLineTools/usr/bin/dyldinfo -rebase` over the 10.9
`/usr/lib` dylibs. The review's independent decoder handled 6.6 million
targets there, so the oracle is practical. It runs locally and SKIPs where
`dyldinfo` or the dylibs are absent.

## Milestones

Each milestone gets its own plan, written when the previous one lands.

**M0: warn about header references when growing an executable** (item 29's
stop-gap). This covers:

- the scan of Decision 3;
- the warning, on the existing route;
- the export-trie `KIND_ABSOLUTE` fix;
- the leading-zero function-starts fix;
- a regression test: the item 29 reproduction must now grow with a warning
  naming its reference, and the `_dyld_get_image_header` control must grow
  with no warning and run.

M0 is small, touches `src/grow.[ch]`, `src/trie.[ch]`, a new scan module
and tests, and ships before the rest. The leading-zero fix covers
`mg_collect` too, or verify fails the grow.

**M1: repair header references.** This covers:

- the instruction-length decoder, with its `otool -tV` oracle;
- confirmation and patching on the executable route;
- scan-based verification (check 5).

The item 29 reproduction now grows and runs.

**M2: the raise route.** It also carries two items M1's final review
handed on (2026-09-25):

- **Enforce the one rule's strictly-inside refusal on both routes.** A RIP
  target, rebase value or symbol strictly inside (base, base + F) must
  refuse. M0 and M1 enforce only the exact-base case; `mhr_code` takes an
  exact target. Give the scan a range (lo, hi) and report each candidate's
  target. None of the 1,059 x86_64 executables on this host has such a
  target, but a `movl __mh_execute_header+16(%rip)` grows silently wrong.
- **Interfaces to generalise:** `mg_verify_refs` scans for "the old base",
  which equals "new base + G" only on the executable route; on the raise
  route the snapshot's base is the new base. Write it as new base + G. The
  repair loop in `mg_grow_header` is inline and needs factoring;
  `mhr_confirm` is hard-wired to the exact base; the snapshot carries no
  delta or G (check 1).

This covers:

- Decisions 1, 2, 4, 5, 6, 7 and 8;
- `mg_classify`'s route argument;
- the shared rebase decoder (Decision 9).

Header-reference repair from M1 applies to it unchanged.

**M3: proof on real dylibs, and documentation.** This covers the real-run
test below, and the documentation updates.

## Testing

| what | where | milestone |
|---|---|---|
| the scan finds every form (all four immediate lengths), and never misses a planted reference | `tests/grow_test.c` | M0 |
| item 29's reproduction grows with the warning; its control grows silently and runs | `tests/grown_binary_runs_test.sh` | M0 |
| `KIND_ABSOLUTE` exports and a leading-zero function-starts list are left alone | `tests/grow_test.c` | M0 |
| the decoder's instruction boundaries equal `otool -tV`'s on the corpus | new, local, SKIPs without `otool` or the corpus | M1 |
| item 29's reproduction grows and runs, printing the same as the original | `tests/grown_binary_runs_test.sh` | M1 |
| each row of Decision 2, on a hand-built dylib fixture carrying that structure; the mutation that skips its fix-up fails a named test | `tests/grow_test.c` | M2 |
| the rule: a `__dso_handle` rebase, a `__mh_dylib_header` symbol and export offset 0 unchanged; content at base + F raised | `tests/grow_test.c` | M2 |
| stabs: `N_ENSYM`, `N_OSO` unchanged on a `-g` fixture | `tests/grow_test.c` | M2 |
| each refusal in Decision 6 leaves the buffer untouched | `tests/grow_test.c` | M1–M2 |
| each of the six verification checks catches a planted error | `tests/grow_test.c` | M2 |
| `dylib append`, `dylib insert`, `rpath replace` on a no-pad dylib fixture: success, announced, `verify` passes | `tests/cli_test.sh` | M2 |
| Sparkle (no compressed dyld info): refused with Decision 6's reason | local end-to-end | M2 |
| the executable route is byte-for-byte unchanged on every existing grow fixture without header references, except, from M1, the `__mh_execute_header` symbol's value | existing suites | M0–M2 |
| **real 10.9 system dylibs run by Apple's programs, and host-built fixture dylibs run by a driver** | new `tests/grown_dylib_runs_test.sh` | M3 |

**Real dylibs, run (M3).** The test grows copies of dylibs to force a raise
(`dylib append` of a long path), runs a program against each copy, and
compares its output with a run against the original.

- **Apple's dylibs, Apple's programs, invoked by absolute path.** For
  example, `/usr/lib/libxml2.2.dylib` (split info, 2544 bytes of pad) under
  `/usr/bin/xmllint`, and `Foundation` under `/usr/bin/plutil`. The absolute
  path matters: `xmllint` on `PATH` here is pkgsrc's, which loads its own
  libxml2 and never touches the copy.
- **Host-built fixture dylibs, run by a small driver.** These cover what no
  10.9 system dylib has, or no Apple program exercises:
  - a thread-local variable (0 of 1517 system images have one);
  - `dlsym` through the export trie;
  - `&__dso_handle` and `getsectiondata(&_mh_dylib_header, …)`, plus a data
    pointer to `__dso_handle`, whose values must agree before and after;
  - a C++ exception thrown across grown code;
  - static initializers.

  Fixtures cover both F < G and F > G, since the failure mode of a missed
  header reference differs between them.
- **Positive control, every run.** `DYLD_PRINT_LIBRARIES` must name the grown
  copy's scratch path, or the run fails. The review confirmed on this host
  that dyld loads the scratch copy, not the shared cache's, for both
  `DYLD_LIBRARY_PATH` and `DYLD_FRAMEWORK_PATH`.
- **Signatures.** Every 10.9 system dylib is signed, and a grown copy's
  signature is invalid. The review found that such a copy loads on 10.9 from
  an unhardened process, so the run covers that deliberately.
- **Where it runs.** The test SKIPs, printing the reason, when the host is
  not 10.9 on x86_64: CI's `macos-26-arm64` runner can run neither. Per
  memory "Check CI, not just local suites", that runner's result is a
  separate gate.

**End to end, locally (M3):** `dylib append` and `rpath replace` on a
lowered copy of Mantle succeed and pass `drydock-macho-rewrite verify`.

## Documentation (M3)

- `README.md`'s grow paragraph.
- `compat/README.md`'s rows saying a dylib is refused, for example the
  `insert_dylib` row about a real dylib with no `__PAGEZERO`.
- `docs/macl-case-study.md` rows 9 and 23, so they are true.
- QUEUE items 29 and 31 marked done.
- Why the routes work moves into `src/grow.h`'s top comment, which already
  explains the executable route, because this spec is deleted once
  implemented. That means the one rule, the completeness argument with its
  residual risk, and the header-reference repair.

## Out of scope

- 32-bit, arm64 and chained fixups: refused.
- Re-basing split info (Decision 4). Dropping it on the executable route
  too is a later decision.
- Reclaiming pad by deleting other load commands (UUID, source version).
  That frees about 50 bytes, which is not enough for the motivating cases,
  and deleting the UUID costs crash symbolication.
- Data constants measured from the header (Decision 2's residual risk).

## Approaches that lost

- **Reclaim only**: see Out of scope.
- **Reclaim, then raise**: a policy layer and two paths to test, for no
  gain. The raise must be correct anyway.
- **For header references, refuse**: considered for M0 and declined, since
  it would refuse a fresh Claude Code. As a permanent answer it would also
  refuse about 40% of app frameworks, mostly C++ ones.
- **For header references, patch without confirming**: a false-positive
  candidate would be corrupted. Confirmation by decoding is what makes
  patching safe.

## Appendix: coverage the review measured

The review's survey (1517 system and 150 app images, every rebase and bind
stream decoded, 6.6 million rebase targets read) checked these and found
them correctly handled by the table above:

- lazy, non-lazy and lazy-dylib pointers;
- `__mod_init_func` and `__mod_term_func`;
- `__interpose`, `__cfstring`, `__dyld`, `__objc_imageinfo`;
- Objective-C lists and refs;
- the TLV sections;
- `S_INIT_FUNC_OFFSETS`;
- stubs and stub helpers;
- every unwind-info entry kind;
- `__eh_frame` and LSDA;
- DTrace DOF (3038 probe offsets, all relative to the DOF section);
- export re-exports and resolvers;
- `N_INDR`;
- `LC_ROUTINES_64`, `LC_DYLIB_CODE_SIGN_DRS`, `LC_CODE_SIGNATURE`;
- the indirect symbol table;
- the `__IMAGE`, `__UNICODE`, `__RESTRICT` and `__LLVM` segments;
- a `__TEXT` at nonzero `vmaddr`.

It found no instance of:

- text relocations or zerofill `__TEXT` sections;
- section relocations, a module table or `LC_TWOLEVEL_HINTS`;
- `LC_ENCRYPTION_INFO_64`, or `LC_UNIXTHREAD` in a dylib.
