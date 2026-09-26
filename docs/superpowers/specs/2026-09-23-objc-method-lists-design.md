# Relative Objective-C method lists, made absolute

Item 13 capability 6 (`docs/superpowers/QUEUE.md`, "## Item 13"). The queue
calls it "not a statement, a subsystem". This spec designs the whole
subsystem and splits it into four milestones. Each one ships working, tested
software. Milestones 1 and 2 have landed (439e1cc..9082c8f, da5f03a..f818638).

## Why

**What 10.9 cannot read.** Since roughly macOS 11 / iOS 14 the linker
emits method lists in a *relative* form. The list header's
`entsizeAndFlags` has its high bit set (`0x80000000`), and each entry is 12
bytes: three `int32` offsets, each measured from the field that holds it. The
three offsets are:

- **name**: to a selector reference (a `SEL *` slot in `__objc_selrefs`);
- **types**: to the type-encoding C string;
- **imp**: to the implementation, where 0 means no IMP.

10.9 ships objc4-551. That runtime reads the entry size as
`entsizeAndFlags & ~3`, and the local objc4-532 mirror in
`Mavericks-Porting-Resources/mavericks-legacy-support/src/objc_read_class_pair.c:143`
does exactly the same. A relative list header of `0x8000000c` therefore
reads as a 2 GB stride. The first method lookup against such a class walks off
into unmapped memory. Nothing checks for this and nothing reports it: the
process dies at class realization, after `fixups set classic` and
`segment rename` have already done everything right.

**Evidence from other projects.** Celeste 64's `COMPAT_WRITEUP.md` (via
`.superpowers/research-ilife-iwork-backports.md` §2 row 11) records this as
the step "standing between `declassify` succeeding and a modern Obj-C binary
actually *running*". Its method: entsize 12 → 24, each entry rewritten as
three 8-byte pointers, the result relocated into a new `__MLDATA` segment,
and new rebase entries added. That writeup is not on this host. Neither
`Mavericks-Porting-Resources` nor any local sibling repo contains method-list
code (`git grep -n -i "entsize\|method_list"`; the positive control is
`objc_read_class_pair.c:112`, which the same grep finds). The audit
(`item13-audit.md`) confirms the same for this repo: `git grep -n entsize`
returns nothing.

**What `absolute` means here.** It is the 24-byte `method_t { SEL name;
const char *types; IMP imp; }` of objc4-551, where `name` is the selector's
**C string**. The 10.9 runtime's `fixupMethodList` interns each name through
`sel_registerName` and **writes the result back into the entry**, then sorts
the list in place. That is published objc4-551 source, not something
measured here. Milestone 3's live test is what proves it on this host. It
has one consequence that decides the placement question below: **the new
lists must be writable.**

## Decisions

### 1. Where the new lists live: the end of the segment before `__LINKEDIT`

*Revised 2026-09-25, after measuring real binaries. The first version of
this decision inserted a new `__MLDATA` segment; "The road not taken"
below says why it lost and what would bring it back.*

**The evidence that decided it.** The only x86_64 images on this host with
relative lists are three frameworks in `~/Downloads/OpenCode.app` (Mantle,
ReactiveObjC, Squirrel; macOS 12.0 target, chained fixups). After
`fixups set classic`, all three:

- are dylibs (`MH_DYLIB`), with **16, 24 and 16 bytes** of header pad, and
  had exactly that before lowering too: current linkers leave almost none;
- have four segments, `__TEXT`, `__DATA_CONST`, `__DATA`, `__LINKEDIT`, in
  that order in load commands, vm and file;
- have a writable `__DATA` whose `filesize` equals its `vmsize`, so its
  `__bss` is already file-backed zeros and `__DATA` ends exactly where
  `__LINKEDIT` begins, in vm and in file;
- carry `LC_CODE_SIGNATURE`, and neither `LC_FUNCTION_STARTS` nor
  `LC_SEGMENT_SPLIT_INFO`.

**The mechanism.** Call the segment immediately before `__LINKEDIT`, in
load-command order, D. The statement appends the converted lists past D's
end:

1. If D's `filesize` is less than its `vmsize` (a zerofill tail, common in
   executables with a large `__bss` or `__common`), D's file backing is
   first extended to its `vmsize` with Z zero bytes. The bytes were zero in
   memory already, so nothing the program sees changes; the file grows by Z.
2. D's `vmsize` and `filesize` grow by S, the page-rounded size of the
   converted lists. The lists occupy D's old end, `D.vmaddr + old vmsize`,
   onward.
3. `__LINKEDIT` moves up by S in vm and by Z + S in file, and the new rebase
   stream (R bytes) goes at its start, as below.

Why this is cheap:

- **No load command is added**, so header pad does not matter. A dylib,
  which can never grow its header (see below), converts as readily as an
  executable, and an executable never needs to grow through `__PAGEZERO`.
- **No existing vm address changes except `__LINKEDIT`'s.** Nothing points
  into `__LINKEDIT` by vm address. dyld derives its base as
  `vmaddr + slide - fileoff`, and every load command reaches `__LINKEDIT`
  by **file offset**.
- **Every `__LINKEDIT` file offset shifts uniformly.** `src/linkedit.h`'s
  `ml_bump_all(im, insert, grow)` already does exactly this, over the list
  `mg_verify` watches, with `insert = __LINKEDIT's old fileoff`.
- **No segment index and no section ordinal changes.** Every rebase and bind
  opcode keeps meaning what it meant, so no opcode stream needs checking for
  a moved index.
- **The lists are writable**, because D must be (the refusal below), and the
  10.9 runtime writes into method lists.

**The lists belong to no section.** D's section headers are untouched; the
new bytes sit past its last section. dyld maps segments, not sections, and
the runtime reaches a method list only through the pointer in its
`class_ro_t`, `category_t` or `protocol_t`, so neither needs a section.
Drydock's own `mg_plausible` checks function starts, not section membership.
The costs are to readers: `otool` and similar tools will not attribute the
bytes to any section, and nothing in the image names them as converted
lists. Decision 6's idempotence does not need a name: a converted image's
walk finds no relative lists.

**Refusals specific to this mechanism** (`EX_REFUSED`, nothing written):

- D is not writable (`initprot` lacks `VM_PROT_WRITE`);
- D does not end where `__LINKEDIT` begins, in vm or (after step 1) in file;
- `__LINKEDIT` is not the last segment;
- D's segment index is 16 or higher, since the rebase opcode's segment
  index is a 4-bit immediate (Decision 2).

None of these fired on the three real frameworks. If a real binary trips
the first, that is the signal to revisit this decision, below.

**How this meets the grow machinery.** The statement never grows the
header. A **later** statement that grows it (on an executable) sees D as an
ordinary `LC_SEGMENT_64` whose bytes run past its last section.
`mg_grow_header` shifts every segment's file offset uniformly, so the tail
moves with D. Milestone 2 tests that composition (`dylib append` on an
executable with no pad, after the conversion).

**Where the new rebase stream goes.** `REBASE_OPCODE_DONE` ends a stream, so
new entries cannot be appended after the old stream. The stream is rewritten:
the old opcodes up to their `DONE`, then the new ones, then `DONE`. The new
stream is placed at the **start** of the moved `__LINKEDIT`, in the same
insertion. The file becomes:

```
[ ... | D: old bytes | Z zeros | converted lists, S bytes | __LINKEDIT: new rebase stream (R bytes, 16-aligned) | old __LINKEDIT ... ]
```

R is padded to 16, not 8: `codesign_allocate` requires the code signature's
`dataoff` 16-aligned, and Z and S are already whole pages, so R is the only
term that can move it off that alignment.

The insertion at `__LINKEDIT`'s old file offset is Z + S + R bytes.
`ml_bump_all` moves every offset by that amount, then
`rebase_off`/`rebase_size` are pointed at the new stream. The old stream's
bytes are zeroed where they now sit. `__LINKEDIT` still ends the file and the
code signature, if there is one, still ends `__LINKEDIT`, so this statement
leaves the image as re-signable as it found it. On the real frameworks that
is not re-signable with 10.9's `codesign_allocate`: `fixups set classic`,
which must run first, leaves its streams out of the order that tool
requires (QUEUE item 30). This is the same room-making
`import redirect` does, moved to the other end of `__LINKEDIT`.

**The candidates that lost:**

- **`__LINKEDIT`**: read-only, and the runtime writes into method lists.
  Rebases into `__LINKEDIT` are also nonsense to dyld.
- **In place**: 24-byte entries do not fit in 12-byte slots, and the relative
  lists live in `__TEXT,__objc_methlist`, which is read-only.
- **The tail slack of an existing writable segment, without growing it**:
  works only when the slack happens to be big enough, so it would decide per
  binary whether the feature works.
- **Growing a segment that is not the last before `__LINKEDIT`**: every
  segment after it would move in vm, and code addresses them RIP-relatively.
- **A new segment appended after `__LINKEDIT`**: `codesign_allocate`
  requires `__LINKEDIT` to be the last segment in the file, and ad-hoc
  re-signing is mandatory in every known port's flow (QUEUE item 13, "A
  documentation gap").
- **A new segment inserted immediately before `__LINKEDIT`**: the road not
  taken, below.

**The road not taken: a new `__MLDATA` segment.** This was the first
design, with a section `__objc_const`, placed between D and `__LINKEDIT`,
following Celeste 64's port. It is the layout `ld` would produce, its bytes
are labelled by a section, and a converted image names itself. It needs a
new `LC_SEGMENT_64` plus one `section_64`, **152 bytes of header pad**, and
that is what killed it: every real image measured has 16 to 24. An
executable can get the room, because `mg_ensure_pad` grows its header by
lowering the image base into `__PAGEZERO`, so no vm address moves
(`src/grow.h`). **A dylib has no `__PAGEZERO`**, so `grow` refuses it
(`only MH_EXECUTE can be grown`), and frameworks are exactly where Swift and
Objective-C code arrives.

What it would take to choose it after all:

- **Dylib header growth.** That means the LIEF / `llvm-objcopy` route
  `src/grow.h` deliberately declined: insert space after the load commands
  and move every later byte up in vm, then rewrite everything that holds a
  vm address or a delta from one — rebase, bind, lazy-bind, weak-bind and
  export streams, symbol `n_value`s, `LC_FUNCTION_STARTS`, `__unwind_info`,
  `__eh_frame`, `LC_DATA_IN_CODE`, the Objective-C metadata's own pointers,
  and any absolute pointer in data. That is a subsystem larger than this
  one, and its benefit would reach every statement that adds a load command
  to a dylib, not only this one. If Drydock ever gains it, this decision can
  be revisited on its merits.
- **Or binaries with room.** An image linked with `-headerpad` (or
  `-headerpad_max_install_names`) of 152 bytes or more could take a new
  segment today. Supporting both mechanisms doubles the testing for no
  runtime difference, so it is only worth it if the mechanism above fails
  somewhere the new segment would not.
- **What would force the question:** a real binary whose segment before
  `__LINKEDIT` is read-only, or evidence that some consumer (10.9's dyld or
  objc, `codesign`, a later Drydock statement) mishandles bytes past a
  segment's last section. Neither has been seen.

### 2. Fixups: classic only, and after `fixups set classic`

`objc-methods set absolute` **refuses an image with `LC_DYLD_CHAINED_FIXUPS`**
(`EX_REFUSED`), saying `fixups set classic first`. The reasons:

- On a chained image every pointer the walk follows (class list entries,
  `isa`, `data`, `baseMethods`, the selector references) is an encoded chain
  link, not an address. Converting there would mean threading new links
  through the extended segment's `dyld_chained_starts_in_segment`, which
  `fixups set classic` would then have to lower in any case.
- `target 10.9` already puts `fixups set classic` first (`src/edit.c`,
  `me_expand_10_9`), so the derived order is always right.
  A hand-written script in the wrong order gets a refusal that names the fix.

It also refuses an image without `LC_DYLD_INFO[_ONLY]`, which has no rebase
stream to extend.

**On a classic image, every new pointer gets a rebase.** There are three per
entry (SEL string, types string, IMP), minus any IMP that is 0. Rebases
suffice for all of them: every target is inside the image. No new bind is
ever needed. A selector reference that is a **bind** rather than a rebase is
refused, because it would mean the name comes from another image, and a copied
address would then be wrong.

The repointed method-list slots (`class_ro_t.baseMethods` and the rest)
**already carry a rebase**, since they pointed at `__TEXT` before. Only their
value changes. The statement requires each one to be in the old rebase set.

Opcode encoding stays within what dyld has read since 10.6:
`SET_TYPE_IMM(POINTER)`, `SET_SEGMENT_AND_OFFSET_ULEB`,
`DO_REBASE_ULEB_TIMES` for runs of consecutive pointers, and
`DO_REBASE_IMM_TIMES`. The segment index is a 4-bit immediate, so an image
whose segment D (Decision 1) is index 16 or higher is refused.

### 3. How selector references resolve

`name` is an offset to an 8-byte slot, normally in `__objc_selrefs`. On a
classic image that slot holds the selector string's unslid vm address, and a
rebase makes it slide. The absolute entry's `name` is **that address**, copied
out of the slot. It is not the slot's own address, because objc4-551 reads
`name` as a `char *`.

Each resolution is checked, and any failure refuses:

- the slot is file-backed, 8-byte aligned, and in the old rebase set;
- its value lands in an `S_CSTRING_LITERALS` section and is NUL-terminated
  within it;
- `types` resolves to the same kind of string;
- `imp` is 0, or lands in a section with `S_ATTR_SOME_INSTRUCTIONS` or
  `S_ATTR_PURE_INSTRUCTIONS`. When `LC_FUNCTION_STARTS` is present, the IMP
  must also be a known function start (`mg_funcstarts_decode` +
  `mg_addr_known`).

**Refused as unknown shapes:**

- a list header with `0x40000000` (shared-cache "selectors are direct");
- any other flag bit outside `0x80000000`;
- a relative entsize other than 12;
- a `baseMethods` pointer with low bits set (a list of lists, which is a
  shared-cache form).

### 4. Which structures carry method lists

This is the walk the 10.9 runtime makes, over every section of these names in
**any** segment. The walk goes by section name and does not look up the
segment first, because after `segment rename __DATA_CONST __DATA` two
segments share a name (`src/swift_retag.c`'s `mswift_find_section_lc`
explains the trap).

| owner | reached from | method-list pointers |
|---|---|---|
| class | `__objc_classlist`, `__objc_nlclslist` → `class_t` → `data & 0x00007ffffffffff8` → `class_ro_t` | `baseMethods` (+32) |
| metaclass | the class's `isa` (+0) → `class_t` → … | `baseMethods` (+32) |
| category | `__objc_catlist`, `__objc_nlcatlist` → `category_t` | `instanceMethods` (+16), `classMethods` (+24) |
| protocol | `__objc_protolist` → `protocol_t` | `instanceMethods` (+24), `classMethods` (+32), `optionalInstanceMethods` (+40), `optionalClassMethods` (+48) |

- Masking `data` drops the Swift tag bits (`src/swift_retag.h`), so the walk
  works before or after `swift-abi set legacy`.
- A record is walked once however many lists name it: a non-lazy class
  appears in both class lists.
- A method list is converted once however many slots name it. Every slot is
  repointed.
- **Protocols are walked even though it is unverified here that any linker
  emits relative lists for them.** The walk costs nothing when none are
  relative, and missing one would crash.
- **Extended method types do not matter.** `protocol_t.extendedMethodTypes` is
  an array of `char *` indexed by method position across the protocol's four
  lists. The conversion **preserves entry order**, so every index still
  names the same method. Milestone 2 has a test that pins the order.
- **`__objc_catlist2` is not walked.** 10.9's runtime never reads it. It holds
  categories on Swift stub classes, which 10.9 cannot load anyway.

### 5. What `info` reports

One flush-left line per image, beside `swift-abi:`, always printed so its
absence is never ambiguous:

```
objc-methods: 4 relative, 0 absolute
objc-methods: none
objc-methods: not walked: the image has chained fixups; fixups set classic first
objc-methods: not walked: the method list at 0x1000009a0 claims 268435456 entries, which runs past its segment
```

The counts are **distinct lists reachable by the walk in Decision 4**, which is
exactly what the statement converts. `info` still exits 0 on a "not walked"
line: it is a query, and the line is its answer. No existing consumer greps
a flush-left `objc-methods:`: the flush-left patterns in use are `^LC\[`,
`^header pad:`, `^swift-abi:` and `^slice `, and `^  ordinal=` is indented
(`compat/insert_dylib.sh:91,101`, `tests/bake_mavericks_shim_test.sh`,
`tests/grown_binary_runs_test.sh:54`, `tests/differential.sh:260`).

### 6. `target 10.9` derives it: the sixth detection

`target 10.9` should derive this statement. Without it, `target 10.9` produces
a binary that loads and then crashes on first message send, which is the
silent-success class this toolkit exists to remove. The rules:

- **The detection runs on the image as `target` finds it, before
  `fixups set classic` has run**, so it has two branches.
  - *Classic image:* derive when the walk finds at least one relative list.
    Why: `relative method lists (N)`. This is exact, and it is the same walk
    the statement makes.
  - *Chained image:* derive when any section named `__objc_methlist` is
    non-empty. Why: `__objc_methlist present under chained fixups`. The
    statement, running after `fixups set classic`, decides exactly, and says
    `nothing to convert` if the section held no reachable relative list.
- **It is derived last**, after `swift-abi set legacy`. `fixups set classic`
  must precede it, and nothing else interacts with it.
- **Idempotence.** A converted image is classic, and its walk finds zero
  relative lists, so a second `target 10.9` derives nothing new. The dead
  lists left in `__TEXT,__objc_methlist` do not matter, because on a classic
  image the detection is the walk and not the section name.
- `ME_TARGET_MAX` becomes 6.
- The statement **cannot miss**, like `swift-abi set legacy`. With nothing
  to convert it is a no-op that says so.

### 7. Verification after the rewrite

The statement verifies its own output and refuses, writing nothing, on any
difference. This is the `import redirect` pattern (`src/redirect.c`, the
re-walk before handing the image back):

1. **Re-walk the output.**
   - It finds zero relative lists.
   - The set of method-list slots equals the input's.
   - Each slot that named a relative list now names a new list whose
     entries, **in order**, resolve to the same (selector string bytes, types
     string bytes, IMP address) as the old list's.
   - Each slot that named an absolute list is unchanged.
2. **Rebases.** Decode the whole new rebase stream. As a set of
   (segment, offset) pairs it must equal the old set plus the new pointer
   slots, exactly, with no duplicates.
3. **Layout.**
   - The load commands are identical except D's `vmsize` and `filesize`,
     `__LINKEDIT`'s `vmaddr`, `fileoff` and `filesize`, and the `ml_each_off`
     fields. `ncmds` and `sizeofcmds` are unchanged.
   - D grew by exactly S in vm and by Z + S in file; `__LINKEDIT` moved by
     exactly S in vm, and its `vmsize` grew to cover its new `filesize`
     wherever the new rebase stream crossed a page (ReactiveObjC 0x15000 to
     0x19000, Squirrel 0xd000 to 0xe000).
   - Bytes below the insertion are identical except for the repointed 8-byte
     slots. The Z bytes are zero.
   - The old `__LINKEDIT` bytes reappear Z + S + R later, identical except for
     the zeroed old rebase stream.
   - Every `ml_each_off` field other than `rebase_off` moved by exactly
     Z + S + R.
   - `__LINKEDIT` is the last segment and ends the file.
   - No two segments overlap in vm.
4. **`mg_plausible` does not run for this statement**, and correctly so. The
   row declares `MREL_FILE_OFF`, and the gate runs `mg_plausible` only for
   statements that disturb base-relative data. This one moves no code and
   no base-relative structure: initializers and unwind entries, which
   `mg_plausible` checks, are untouched. The statement adds no load command,
   so it never disturbs the header pad.
5. **On 10.9 itself:** milestone 3 runs a converted binary and checks its
   output.

## Milestones

Each one is its own plan, written when the previous one lands.

**M1: see the lists (read-only).** `src/objc_meth.[ch]` holds the walk
(Decision 4) with its refusals. `info` prints the `objc-methods:` line.
`tests/relmeth_fixture.h` + `tests/mkrelmeth.c` build a synthetic fixture.
Deliverable: `info` answers "does this binary have relative method lists, and
how many?" on any classic image. **Landed: 439e1cc..9082c8f.**

**M2: `objc-methods set absolute`.**

- `src/rebase.[ch]` (`mrb_`): a complete classic rebase-opcode decoder,
  covering all nine opcodes. Nothing in the repo has one: `md_next_rebase`
  reads only the two opcodes its own encoder emits. It also gets an encoder
  for sorted slots.
- The segment insertion (Decision 1), the conversion (Decisions 2–3), the
  verification (Decision 7), the new row in `MS_TABLE_ROWS`, and
  `me_apply`'s lowering and log lines:

  ```
    objc-methods set absolute
        converted 4 relative method lists (5 methods) onto the end of __DATA: 1 class, 1 metaclass, 1 category, 1 protocol
        added 14 rebases; __DATA grew 4096 bytes; __LINKEDIT 256 -> 344 bytes, moved up 4096
  ```

- The fixture gains variants: a dylib with 16 bytes of header pad (which
  must convert: it is the case Decision 1 exists for), D with a zerofill
  tail (`filesize < vmsize`), D read-only, a gap between D and
  `__LINKEDIT`, a segment after `__LINKEDIT`, a code signature,
  `LC_SEGMENT_SPLIT_INFO`, a selref that is a bind, and an IMP that is not a
  function start. `mkrelmeth entries FILE` becomes the oracle: it resolves
  each fixed slot's list independently of `src/`.
- Tests: `tests/rebase_test.c`, `tests/objc_meth_test.c`,
  `tests/cli_test.sh`, and `tests/script_test.c`'s
  `test_disturbs_matches_the_spec_table`.

**Landed: da5f03a..f818638.**

**M3: prove it on 10.9.** A new mode, `mkrelmeth relativize IN OUT`, rewrites
a real 10.9-linked Objective-C program's absolute lists into relative ones.
The program is `tests/relmeth_prog.m`: a class, a class method, a category and
a protocol, and every method is sent a message so each selector has a
selector reference. The rewrite works in place (12n + 8 ≤ 24n + 8), and uses
`src/rebase.c` to drop the rebases that fell inside the compacted region, so
the result stays PIE-correct. `tests/relmeth_runs_test.sh`:

- **positive control:** the relativized program does *not* print its expected
  output on 10.9;
- after `objc-methods set absolute`, it prints exactly the original's output
  and exits 0.

On a host whose runtime reads relative lists (macOS 11+), the positive
control cannot fail, so it prints `SKIP` with the reason, keyed on
`sw_vers -productVersion`. This follows memory "Check CI, not just local
suites": a test can be unfalsifiable on the host it was written on.

**M4: `target 10.9` derives it, then README.**

- `me_expand_10_9` gains the sixth detection (Decision 6) and
  `ME_TARGET_MAX` goes to 6.
- New tests in `tests/cli_test.sh`'s target block and `tests/edit_test.c`.
- **Decision 1's rationale outlives this spec.** Specs are deleted once
  implemented, so M4 moves "why the end of the segment before `__LINKEDIT`",
  its evidence, and "The road not taken" (what dylib header growth would
  take, and what would force the question) into `docs/objc-methods.md`,
  beside `docs/bind-stream-editing.md` and `docs/minimum-os-version.md`.
- **The final task is the only README change in the whole subsystem**, and
  it changes only these lines:
  - the Statements block row;
  - the "cannot miss" paragraph;
  - the `target` table row;
  - "each of `target 10.9`'s five detections" → six;
  - the `objc-methods:` line in the `info` example.

## Fixtures: why synthetic, and what cannot be proved here

The host `ld` (10.9) cannot emit relative method lists, and no modern
toolchain runs here. `tests/relmeth_fixture.h` therefore lays one out by
hand, in the style of `tests/mkswift.c` and `tests/mkchained.c`. It is shared
by the hermetic test (built in memory) and by `tests/mkrelmeth.c` (written to
a file for the shell suites). Its layout, with every offset fixed, is in
`tests/relmeth_fixture.h` itself. M3 adds the only on-host proof against a real linker's output,
by producing the relative form from a real binary.

**What real binaries on this host settled (2026-09-25).** `info` was run
on 510 images in `/Applications`, `~/Downloads` and the system frameworks:

- **x86_64 relative lists come with chained fixups.** Every x86_64 image
  seen with `__objc_methlist` targets macOS 12.0 and has chained fixups
  (OpenCode.app's Mantle, ReactiveObjC and Squirrel frameworks). The one
  x86_64 slice targeting 11.x with classic fixups (TaskExplorer, minos
  11.5, SDK 15.4) has only absolute lists, while its arm64 slice has only
  relative ones. So on x86_64 this statement always runs on an image that
  `fixups set classic` has just lowered, and its input rebase stream is
  usually one Drydock wrote.
- **The walk reads real ld64 output.** After `fixups set classic`, Mantle
  counts 22 relative and 10 absolute lists, ReactiveObjC 137 and 6, and
  Squirrel 20 and 7. Real images **mix both forms** in one image.
- **Protocols carry relative lists** in real output (9 of TaskExplorer's
  arm64 lists), so walking them is required, not defensive.
- **No false refusals.** Every "not walked" line in the 510 was a chained
  image. On Foundation the walk finds a strict superset of the lists
  `otool -ov` prints; the extra 6 are lists of protocols nothing adopts.
- **Every relative entry resolves as Decision 3 requires** (M2's first
  task). A probe written apart from `src/` ran Decision 3's checks and
  Decision 1's refusals on the three frameworks after `fixups set
  classic` (inputs `3b59fda2…`, `35e4e688…`, `03ef80b1…` by SHA-256):
  89, 650 and 124 entries in 22, 137 and 20 relative lists. Every `name`
  is an offset to an 8-byte-aligned, file-backed, rebased selector
  reference holding a C string; every `types` is a C string; every IMP is
  non-zero and in a section of instructions. None carries
  `LC_FUNCTION_STARTS`, so the function-start check does not run on them.
  D is `__DATA`, segment 2, writable, ending where `__LINKEDIT` begins in
  vm and in file, and `__LINKEDIT` ends the file. The conversion adds 267,
  1,950 and 372 rebases. So in these app-side images `name` is never direct.
- **The statement converts all three** (M2's last task). `fixups set
  classic` then `objc-methods set absolute`, in one script, on each
  original framework: exit 0, the statement's own verification passed,
  `info` then counts 0 relative and 32, 143 and 27 absolute lists,
  `drydock-macho-rewrite verify` says OK, and a second reader written
  apart from `src/` reads every slot's methods the same, in the same
  order, before and after. `__DATA` grew 4,096, 20,480 and 4,096 bytes.
  `__LINKEDIT`'s vmsize grew on ReactiveObjC (0x15000 to 0x19000) and
  Squirrel (0xd000 to 0xe000), because the rewritten rebase stream
  outgrew it. Nothing converted has run on 10.9 yet: that is M3.
- **Re-signing is as Decision 1 says** (QUEUE item 30). 10.9's
  `codesign --force --sign -` refuses Mantle, ReactiveObjC and Squirrel
  alike, before the conversion ("dyld_info out of place") and after it. The
  post-conversion "code signature data out of place" reported here earlier
  was this milestone's own bug: the new rebase stream was padded to 8 bytes,
  not 16, so a moved `LC_CODE_SIGNATURE` could land off the 16-byte
  alignment `codesign_allocate` requires (fixed: the new rebase stream is
  16-aligned). After that fix, none of the three still hits that error; all
  three instead hit "link edit information does not fill the __LINKEDIT
  segment" -- consistent with `fixups set classic`'s own layout, QUEUE item
  30's pre-existing problem, since it is unaffected by the conversion.

**Still to validate:**

- that 10.9's dyld and objc, and `codesign`, accept method lists placed past
  the last section of `__DATA` (Decision 1). The fixtures prove Drydock's
  side; M3's run on 10.9 proves the runtime's;
- Swift `@objc` classes' `class_ro_t` in practice;
- lists this walk does not reach: `__objc_catlist2`, Swift stub classes,
  and **runtime-instantiated generic Swift classes**, whose `class_ro_t`
  sits in Swift metadata patterns rather than in `__objc_classlist`. The
  last is harmless with Mavergreen swift-runtime as it stands: its patch
  0003 realizes such a class with an empty `class_rw_t`, so 10.9's objc
  never reads the pattern's method list. If that runtime ever methodizes
  them, a relative list there would reach objc4-532 unconverted;
- the whole pipeline on a real macOS 12+ app, run on 10.9:
  `target 10.9` + stub dylibs + ad-hoc re-sign. With Mavergreen
  swift-runtime installed, a Swift app with an `NSObject` subclass is the
  likeliest real customer. The *running* can happen on this host if such
  a binary is carried here. The *building* cannot.

## Files shared with plans drafting in parallel

| file | this subsystem | also touched by |
|---|---|---|
| `src/script.c`, `src/script.h` | M2: one `MS_TABLE_ROWS` row, one kind enum, its value check | minos set; bind-stream edit; section retype |
| `tests/script_test.c` | M2: the disturbs table | the same three |
| `src/edit.c` | M2: `me_apply` case; M4: `me_expand_10_9`, `ME_TARGET_MAX` | minos set / target (the same expansion) |
| `cli/drydock-macho-rewrite.c` | M1: `info_image`'s new line | minos set, if it adds an `info` line |
| `src/grow.c` | **not edited.** M2 never grows the header (Decision 1) | item 6's comment sweep (its stderr strings); section retype (`mg_classify`) |
| `CMakeLists.txt` | M1–M3: one library source, test targets | all of them |
| `tests/cli_test.sh` | M1–M4: appended blocks | all of them |
| `README.md` | M4's final task only | each plan's final task |

The row, the enum value and the `me_apply` case go at the **end** of their
lists. That keeps merge conflicts with the other plans to adjacent-line
conflicts.

## Testing

| what | where | milestone |
|---|---|---|
| class and metaclass lists found; Swift tag bits masked; a class listed twice walked once | `tests/objc_meth_test.c` | M1 |
| categories and protocols found; a shared list counted once; absolute lists counted apart | `tests/objc_meth_test.c` | M1 |
| chained, direct-selector, bad entsize, list of lists, list past its segment: each refused with its reason | `tests/objc_meth_test.c` | M1 |
| `info`'s `objc-methods:` line, in all four shapes and once per fat slice | `tests/cli_test.sh` | M1 |
| every rebase opcode decoded; the encoder round-trips | `tests/rebase_test.c` | M2 |
| conversion: oracle-equal entries in order, every new pointer rebased, `__LINKEDIT` moved intact, nothing written on refusal | `tests/objc_meth_test.c`, `tests/cli_test.sh` | M2 |
| conversion then a grow (`dylib append` on no pad) still verifies | `tests/cli_test.sh` | M2 |
| a relativized real program fails on 10.9; converted, it runs | `tests/relmeth_runs_test.sh` | M3 |
| `target 10.9` derives it on classic and chained images, last, and not again after it ran | `tests/cli_test.sh`, `tests/edit_test.c` | M4 |

## Out of scope

- arm64 and arm64e slices. 10.9 is x86_64 only. The statement leaves other
  CPU types unchanged, as nothing to convert (owner's ruling, 2026-09-26),
  and `target` never derives it for them.
- Converting on chained images (Decision 2), and walking them for `info`.
- Relative-list forms seen only in the dyld shared cache.
- Other modern Objective-C metadata 10.9 may reject, such as
  `objc_image_info` flag bits and `__objc_catlist2`. Not investigated.
- Removing the dead relative lists from `__TEXT`.

## The owner's answers (2026-09-25)

1. **Statement spelling: `objc-methods set absolute`**, and the `info` line
   is `objc-methods:` (renamed from `method-lists:` in `cff1919`). C++,
   Swift, Rust and Go have methods too, but their dispatch tables are read
   by their own code or their own bundled runtime, never by an OS component
   older than the format. Only Objective-C's lists are read by one (10.9's
   libobjc), so only they need this, and the name says so.
2. **Names: none needed.** Answered `__MLDATA,__objc_const` first, then
   made moot the same day when Decision 1 changed from a new segment to the
   end of the segment before `__LINKEDIT`, because real dylibs have no header
   pad for a new load command. Decision 1 records why, and what would bring
   the new segment back.
3. **`LC_SEGMENT_SPLIT_INFO`: keep it, offset bumped.** Split info
   describes references between existing sections, and none move. None of
   the three real frameworks carries it, but a dylib built for the shared
   cache would, and refusing it would reject a dylib for no runtime reason.
4. **An IMP not in `LC_FUNCTION_STARTS`: refuse.** None of the three real
   frameworks carries `LC_FUNCTION_STARTS`, so on them the check does not
   run and the section-attribute check (`S_ATTR_*_INSTRUCTIONS`) is the only
   one. M2's first task still runs the conversion's resolution checks on
   all three and records the result.
5. **Dead relative lists in `__TEXT`: leave them.**
6. **Real binaries:** the three OpenCode.app frameworks above are M2's
   real-world subjects, converted and re-walked by the statement's own
   verification. M3's run-on-10.9 proof keeps its planned relativized
   program. A current-Xcode app stays on the validate-elsewhere list.
7. **Chained decoding in `info`: not now.** On x86_64 the chained case is
   the common one, but M4's section-name branch still decides correctly,
   and `info` on an unlowered image says why it did not walk.
