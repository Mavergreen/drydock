# Relative Objective-C method lists, made absolute

Item 13 capability 6 (`docs/superpowers/QUEUE.md`, "## Item 13"). The queue
calls it "not a statement, a subsystem". This spec designs the whole
subsystem and splits it into four milestones. Each one ships working, tested
software. Milestone 1 has landed (439e1cc..9082c8f).

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

### 1. Where the new lists live: a new segment just before `__LINKEDIT`

The candidates, and why each loses or wins:

- **`__LINKEDIT`**: read-only, and the runtime writes into method lists.
  Rebases into `__LINKEDIT` are also nonsense to dyld. **Rejected.**
- **In place**: 24-byte entries do not fit in 12-byte slots, and the relative
  lists live in `__TEXT,__objc_methlist`, which is read-only. **Rejected.**
- **Growing `__DATA`**: every segment after it would move in vm, and code
  addresses `__DATA` RIP-relatively. When `__DATA` happens to be the last
  segment before `__LINKEDIT`, growing it still means inserting an 80-byte
  `section_64` mid-command, and placing file-backed bytes after any zerofill
  section (`__bss`, `__common`), which a segment cannot hold. **Rejected.**
- **The tail slack of an existing writable segment**: this works only when
  the slack happens to be big enough. It is a fallback that would decide
  per binary whether the feature works. **Rejected** as the mechanism.
- **A new segment appended after `__LINKEDIT`**: `codesign_allocate`
  requires `__LINKEDIT` to be the last segment in the file, and ad-hoc
  re-signing is mandatory in every known port's flow (QUEUE item 13, "A
  documentation gap"). **Rejected.**
- **A new segment inserted immediately before `__LINKEDIT`, in load-command
  order, vm order and file order: chosen.** It is the layout `ld` itself
  would have produced. The new segment takes `__LINKEDIT`'s old `vmaddr`
  and `fileoff`, and `__LINKEDIT` moves up by the new segment's page-rounded
  size S, in both vm and file.

Why the chosen layout is cheap:

- **No existing vm address changes except `__LINKEDIT`'s.** Nothing points
  into `__LINKEDIT` by vm address. dyld derives its base as
  `vmaddr + slide - fileoff`, and every load command reaches `__LINKEDIT`
  by **file offset**.
- **Every `__LINKEDIT` file offset shifts uniformly.** `src/linkedit.h`'s
  `ml_bump_all(im, insert, grow)` already does exactly this. It bumps
  every field at or past `insert`, and its list is the one `mg_verify`
  watches. This subsystem reuses it with `insert = __LINKEDIT's old
  fileoff`.
- **Section ordinals are untouched.** `__LINKEDIT` has no sections, so the
  new section's 1-based ordinal is one past every existing one. No
  `n_sect` moves.
- **The only index that moves is `__LINKEDIT`'s own segment index**, which
  goes up by one. No rebase or bind opcode may name `__LINKEDIT`. The
  statement checks this in all four opcode streams and refuses if one does.

**Names.** The segment is `__MLDATA` (prior art: Celeste 64). Its one section
is `__objc_const`, the section `ld` used for absolute method lists before
relative ones existed. It is deliberately not `__objc_methlist`, so a
converted image never looks like it still needs converting (Decision 6).
The segment's protection is `initprot = maxprot = VM_PROT_READ |
VM_PROT_WRITE`, and the section is `S_REGULAR` with `align = 3`.

**How this meets the grow machinery.** The new segment's load command needs
152 bytes of header pad (`segment_command_64` + one `section_64`). The pad
comes from `mg_ensure_pad`, the same as for every other statement, so a short
pad on a PIE executable grows through `__PAGEZERO` and is announced on stderr.
A dylib with a short pad is refused, as it is for every other statement.
Growth happens **before** the walk that finds the lists. Growth changes file
offsets but no vm address, and doing it first means the walk sees final
offsets. A later grow, from a later statement, sees an ordinary
`LC_SEGMENT_64` with an `S_REGULAR` section. `mg_classify` accepts that, and
`mg_grow_header` shifts it the same way it shifts every other segment.
Milestone 2 tests that composition.

**Where the new rebase stream goes.** `REBASE_OPCODE_DONE` ends a stream, so
new entries cannot be appended after the old stream. The stream is rewritten:
the old opcodes up to their `DONE`, then the new ones, then `DONE`. The new
stream is placed at the **start** of the moved `__LINKEDIT`, in the same
insertion. The file becomes:

```
[ ... | __MLDATA: S bytes | __LINKEDIT: new rebase stream (R bytes, 8-aligned) | old __LINKEDIT ... ]
```

The insertion is S + R bytes. `ml_bump_all` moves every offset by that
amount, then `rebase_off`/`rebase_size` are pointed at the new stream. The old
stream's bytes are zeroed where they now sit. `__LINKEDIT` still ends the file
and the code signature, if there is one, still ends `__LINKEDIT`, so
`codesign --force` can re-sign. This is the same room-making `import redirect`
does, moved to the other end of `__LINKEDIT`. The start is used here because
the insertion is already happening there, and the end would put the stream
after the signature.

### 2. Fixups: classic only, and after `fixups set classic`

`method-lists set absolute` **refuses an image with `LC_DYLD_CHAINED_FIXUPS`**
(`EX_REFUSED`), saying `fixups set classic first`. The reasons:

- On a chained image every pointer the walk follows (class list entries,
  `isa`, `data`, `baseMethods`, the selector references) is an encoded chain
  link, not an address. Converting there would mean threading new links
  through a new segment's `dyld_chained_starts_in_segment`, which
  `fixups set classic` would then have to lower in any case.
- `grow` already refuses chained images (`src/grow.h`, `mg_ensure_pad`), and
  this statement may need to grow.
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
whose new segment would be index 16 or higher is refused.

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
method-lists: 4 relative, 0 absolute
method-lists: none
method-lists: not walked: the image has chained fixups; fixups set classic first
method-lists: not walked: the method list at 0x1000009a0 claims 268435456 entries, which runs past its segment
```

The counts are **distinct lists reachable by the walk in Decision 4**, which is
exactly what the statement converts. `info` still exits 0 on a "not walked"
line: it is a query, and the line is its answer. No existing consumer greps
a flush-left `method-lists:`: the flush-left patterns in use are `^LC\[`,
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
   - Every segment other than `__LINKEDIT` and the new one has identical
     load-command fields.
   - Bytes below the insertion are identical except for the load-command
     region and the repointed 8-byte slots.
   - The old `__LINKEDIT` bytes reappear S + R later, identical except for
     the zeroed old rebase stream.
   - Every `ml_each_off` field other than `rebase_off` moved by exactly S + R.
   - `__LINKEDIT` is the last segment and ends the file.
   - No two segments overlap in vm.
4. **`mg_plausible`** runs through the existing gate. The row declares
   `MREL_FILE_OFF | MREL_HEADER_PAD`, and `me_note_disturbed` adds
   `MREL_BASE_REL` itself when a grow happened.
5. **On 10.9 itself:** milestone 3 runs a converted binary and checks its
   output.

## Milestones

Each one is its own plan, written when the previous one lands.

**M1: see the lists (read-only).** `src/objc_meth.[ch]` holds the walk
(Decision 4) with its refusals. `info` prints the `method-lists:` line.
`tests/relmeth_fixture.h` + `tests/mkrelmeth.c` build a synthetic fixture.
Deliverable: `info` answers "does this binary have relative method lists, and
how many?" on any classic image. **Landed: 439e1cc..9082c8f.**

**M2: `method-lists set absolute`.**

- `src/rebase.[ch]` (`mrb_`): a complete classic rebase-opcode decoder,
  covering all nine opcodes. Nothing in the repo has one: `md_next_rebase`
  reads only the two opcodes its own encoder emits. It also gets an encoder
  for sorted slots.
- The segment insertion (Decision 1), the conversion (Decisions 2–3), the
  verification (Decision 7), the new row in `MS_TABLE_ROWS`, and
  `me_apply`'s lowering and log lines:

  ```
    method-lists set absolute
        converted 4 relative method lists (5 methods) into __MLDATA,__objc_const: 1 class, 1 metaclass, 1 category, 1 protocol
        added 13 rebases; __LINKEDIT 256 -> 344 bytes, moved up 4096
  ```

- The fixture gains variants: no pad on a dylib, a code signature,
  `LC_SEGMENT_SPLIT_INFO`, a segment after `__LINKEDIT`, a bind naming
  `__LINKEDIT`'s index, a selref that is a bind, and an IMP that is not a
  function start. `mkrelmeth entries FILE` becomes the oracle: it resolves
  each fixed slot's list independently of `src/`.
- Tests: `tests/rebase_test.c`, `tests/objc_meth_test.c`,
  `tests/cli_test.sh`, and `tests/script_test.c`'s
  `test_disturbs_matches_the_spec_table`.

**M3: prove it on 10.9.** A new mode, `mkrelmeth relativize IN OUT`, rewrites
a real 10.9-linked Objective-C program's absolute lists into relative ones.
The program is `tests/relmeth_prog.m`: a class, a class method, a category and
a protocol, and every method is sent a message so each selector has a
selector reference. The rewrite works in place (12n + 8 ≤ 24n + 8), and uses
`src/rebase.c` to drop the rebases that fell inside the compacted region, so
the result stays PIE-correct. `tests/relmeth_runs_test.sh`:

- **positive control:** the relativized program does *not* print its expected
  output on 10.9;
- after `method-lists set absolute`, it prints exactly the original's output
  and exits 0.

On a host whose runtime reads relative lists (macOS 11+), the positive
control cannot fail, so it prints `SKIP` with the reason, keyed on
`sw_vers -productVersion`. This follows memory "Check CI, not just local
suites": a test can be unfalsifiable on the host it was written on.

**M4: `target 10.9` derives it, then README.**

- `me_expand_10_9` gains the sixth detection (Decision 6) and
  `ME_TARGET_MAX` goes to 6.
- New tests in `tests/cli_test.sh`'s target block and `tests/edit_test.c`.
- **The final task is the only README change in the whole subsystem**, and
  it changes only these lines:
  - the Statements block row;
  - the "cannot miss" paragraph;
  - the `target` table row;
  - "each of `target 10.9`'s five detections" → six;
  - the `method-lists:` line in the `info` example.

## Fixtures: why synthetic, and what cannot be proved here

The host `ld` (10.9) cannot emit relative method lists, and no modern
toolchain runs here. `tests/relmeth_fixture.h` therefore lays one out by
hand, in the style of `tests/mkswift.c` and `tests/mkchained.c`. It is shared
by the hermetic test (built in memory) and by `tests/mkrelmeth.c` (written to
a file for the shell suites). Its layout, with every offset fixed, is in the
plan's Task 1. M3 adds the only on-host proof against a real linker's output,
by producing the relative form from a real binary.

**Only a real modern binary can settle these, so they must be validated
elsewhere:**

- that ld64 and ld-prime put relative lists in `__TEXT,__objc_methlist`,
  and for which owners. Protocols in particular.
- that in an app binary (as opposed to the shared cache) `name` is always a
  selector-reference offset and never direct;
- that real linker output meets Decision 1's preconditions: `__LINKEDIT`
  last, fewer than 16 segments, and 152 bytes of header pad or a
  `__PAGEZERO` to grow through;
- Swift `@objc` classes' `class_ro_t` in practice;
- whether any real binary has lists this walk does not reach
  (`__objc_catlist2`, Swift stub classes);
- the whole pipeline on a real macOS 11+ app, run on 10.9:
  `target 10.9` + stub dylibs + ad-hoc re-sign. The *running* can happen on
  this host if such a binary is carried here. The *building* cannot.

## Files shared with plans drafting in parallel

| file | this subsystem | also touched by |
|---|---|---|
| `src/script.c`, `src/script.h` | M2: one `MS_TABLE_ROWS` row, one kind enum, its value check | minos set; bind-stream edit; section retype |
| `tests/script_test.c` | M2: the disturbs table | the same three |
| `src/edit.c` | M2: `me_apply` case; M4: `me_expand_10_9`, `ME_TARGET_MAX` | minos set / target (the same expansion) |
| `cli/drydock-macho-rewrite.c` | M1: `info_image`'s new line | minos set, if it adds an `info` line |
| `src/grow.c` | **not edited.** M2 calls `mg_ensure_pad` and never asserts its stderr wording | item 6's comment sweep (its stderr strings); section retype (`mg_classify`) |
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
| `info`'s `method-lists:` line, in all four shapes and once per fat slice | `tests/cli_test.sh` | M1 |
| every rebase opcode decoded; the encoder round-trips | `tests/rebase_test.c` | M2 |
| conversion: oracle-equal entries in order, every new pointer rebased, `__LINKEDIT` moved intact, nothing written on refusal | `tests/objc_meth_test.c`, `tests/cli_test.sh` | M2 |
| conversion then a grow (`dylib append` on no pad) still verifies | `tests/cli_test.sh` | M2 |
| a relativized real program fails on 10.9; converted, it runs | `tests/relmeth_runs_test.sh` | M3 |
| `target 10.9` derives it on classic and chained images, last, and not again after it ran | `tests/cli_test.sh`, `tests/edit_test.c` | M4 |

## Out of scope

- arm64 and arm64e slices. 10.9 is x86_64 only. The statement refuses
  other CPU types, and `target` never derives it for them.
- Converting on chained images (Decision 2), and walking them for `info`.
- Relative-list forms seen only in the dyld shared cache.
- Other modern Objective-C metadata 10.9 may reject, such as
  `objc_image_info` flag bits and `__objc_catlist2`. Not investigated.
- Removing the dead relative lists from `__TEXT`.

## Questions for the owner

1. **Statement spelling.** `method-lists set absolute` mirrors
   `fixups set classic` and `swift-abi set legacy`. The alternative is
   `objc-methods set absolute`. *Recommend `method-lists set absolute`*: the
   `info` line and the statement then share the word.
2. **Segment and section names.** *Recommend `__MLDATA,__objc_const`*:
   Celeste's segment name as prior art, and the section `ld` historically used
   for absolute lists. A name ending in `__objc_methlist` would make a
   converted image look unconverted to a section-name reading.
3. **`LC_SEGMENT_SPLIT_INFO`.** Keep it, with its offset bumped, or refuse?
   `grow` refuses it. Here only `__LINKEDIT`'s vm moves, and split info
   describes references between existing sections, all of which keep their
   ordinals. It only matters to shared-cache building. *Recommend keep*:
   refusing would reject nearly every framework a modern Xcode builds.
4. **An IMP that is not in `LC_FUNCTION_STARTS`: refuse, or warn?**
   *Recommend refuse*: refusing matches `mg_plausible`'s use of that table,
   and a wrong IMP only shows up as a crash later.
5. **Dead relative lists in `__TEXT`: leave or zero?** *Recommend leave*.
   Zeroing gains nothing on 10.9, and it would break anything this walk does
   not reach that still points there, such as Swift stub-class categories.
6. **Which real binaries validate M3/M4 elsewhere, and who builds them?**
   *Recommend two small apps* built with a current Xcode, one targeting
   macOS 11.0 (classic fixups plus relative lists) and one targeting 13.0
   (chained plus relative), each with a Swift `@objc` class, a category and a
   protocol with optional methods. Add TaskExplorer, the
   `~/Downloads` worked example QUEUE cites, as the first real app. Carried
   here, they can be run here.
7. **Should `info` (and the chained branch of `target`'s detection) decode
   chained pointers**, making the count exact before `fixups set classic`?
   `md_cf_rebase_target` already does the arithmetic, but the per-segment
   pointer format means parsing `dyld_chained_starts_in_image` a second time.
   *Recommend not now*: Decision 6's section-name branch is safe, because the
   statement makes the exact decision, and the chained-fixture work is large.
