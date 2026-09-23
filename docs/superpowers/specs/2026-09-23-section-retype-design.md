# `section retype`, and `info` naming each section's type

## Why

QUEUE item 13, capability 5: normalize `S_NON_LAZY_SYMBOL_POINTERS` and
`S_SYMBOL_STUBS` to `S_REGULAR`, one `flags` write per section. The evidence
for it is one line of Celeste 64's `COMPAT_WRITEUP.md` ("Section Type
Normalization"). It changed `__got` and `__stubs` to `S_REGULAR` because
"modern section types that 10.9's dyld doesn't recognize" needed it. Nothing
else in the item 13 research names a section type.

The queue entry names a tension: `grow` refuses a section type it does not
recognise, so the two features must agree on ordering. The item 13 audit says
the tension is still live and that `src/grow.c:808-813` refuses images that
carry these two types.

**Reading the code and measuring on 10.9 shows both claims are wrong, and so
is Celeste's reason.** What follows is the evidence, split into what is known
and what is assumed.

### What `grow` actually refuses

`mg_classify_cb` refuses a section when `type > S_INIT_FUNC_OFFSETS`
(`src/grow.c:809`). `S_INIT_FUNC_OFFSETS` is `0x16` (`src/mach_compat.h:102`).
`S_NON_LAZY_SYMBOL_POINTERS` is `0x6` and `S_SYMBOL_STUBS` is `0x8`
(`/usr/include/mach-o/loader.h:463,467`). Both are below the bound, so `grow`
accepts them, and it accepts `S_REGULAR` (`0x0`) too. The audit said these
types are "higher-numbered types than `S_INIT_FUNC_OFFSETS`", and they are not.

Measured on 2026-09-23 with the current build. `tests/fixture.macho` carries
`__TEXT,__stubs` (flags `0x80000408`) and `__DATA,__nl_symbol_ptr` (flags
`0x6`). A `dylib append` with a 3000-byte path had to grow the header, and it
exited 0 and verified. `grown_binary_runs_test` already grows host-linked
executables, and every one of them has a `__stubs` and a `__got`. **The
tension does not exist for any type this statement touches.**

### What dyld on 10.9 does with these types

Known: the source. The source is `dyld-239.4`, fetched from
`apple-oss-distributions/dyld`. This host runs `dyld-239.5` (from `what
/usr/lib/dyld`, on 10.9.5 13F1911), and no `239.5` tag is published. dyld picks
one of two loaders per image. An image with `LC_DYLD_INFO[_ONLY]` loads through
`ImageLoaderMachOCompressed`, and one without it loads through
`ImageLoaderMachOClassic`.

| type | compressed image (what drydock emits) | classic image |
|---|---|---|
| `S_NON_LAZY_SYMBOL_POINTERS` | **never read.** Neither `ImageLoaderMachO.cpp` nor `ImageLoaderMachOCompressed.cpp` mentions it. Binding comes from the opcode streams. | **load-bearing.** `bindIndirectSymbolPointers` (`ImageLoaderMachOClassic.cpp:1695-1720`) finds the pointers to bind *by this type*, using `reserved1` into the indirect symbol table. |
| `S_SYMBOL_STUBS` | read only in `updateOptimizedLazyPointers` (`ImageLoaderMachOCompressed.cpp:1598-1655`). It is called only `if ( fInSharedCache )` (`:889-890`), and no app image is in the shared cache. | read only when paired with `S_ATTR_SELF_MODIFYING_CODE` and `reserved2 == 5`, the i386 fast-stub form (`:1344,1414,1727,1829,1970`). An x86_64 image never has that. |

Snow Leopard's `dyld-132.13` `ImageLoaderMachOCompressed.cpp` mentions neither
type (only `S_LAZY_SYMBOL_POINTERS`, at `:1012`), so an older target does not
change the answer.

Known: a measurement, taken on this 10.9.5 host on 2026-09-23. A throwaway
patcher in the session scratchpad changed only the `SECTION_TYPE` byte:

| image | retyped | result |
|---|---|---|
| `tests/fixture.macho` (compressed) | `__nl_symbol_ptr` | runs, exit 0 |
| same | `__stubs` | runs, exit 0 |
| same | both | runs, exit 0; `DYLD_PRINT_BINDINGS` shows the same binds |
| a `-mmacosx-version-min=10.9` link (compressed, both `__got` and `__nl_symbol_ptr`) | `__got`, `__nl_symbol_ptr`, `__stubs` | runs, exit 0 |
| a `-mmacosx-version-min=10.5` link (**classic**: no `LC_DYLD_INFO`) | `__got` | **SIGSEGV (exit 139)**: `errno`'s pointer is never bound |
| same | `__stubs` | runs, exit 0 |
| same | `__la_symbol_ptr` (out of scope; for contrast) | `dyld: lazy pointer not found`, exit 133 |

So:

- **On a compressed image, normalizing either type changes nothing that 10.9's
  dyld does.** It is safe, and as far as dyld is concerned it is also inert.
- **On a classic image, normalizing `S_NON_LAZY_SYMBOL_POINTERS` is unsafe**:
  the pointers go unbound and the first use crashes. Normalizing
  `S_SYMBOL_STUBS` there is safe on x86_64.
- **Celeste's reason does not hold.** Both types date from Mac OS X 10.0/10.1
  and are in the 10.9 SDK's `loader.h`. 10.9's dyld recognises them.

Assumed, not known:

- That `dyld-239.5` matches `239.4` in these functions. The measurement ran on
  239.5 and agrees with the 239.4 source.
- That nothing else in a 10.9 process reads these types. dyld is not the only
  reader. The Objective-C runtime, CoreSymbolication, crash reporting and lldb
  were not checked. The last of these is the one likely to notice: a debugger
  names a stub call through `S_SYMBOL_STUBS` and `reserved2`, and retyping
  costs that.
- Why Celeste made the change. Their binary also had its method lists
  rewritten, a segment renamed and an instruction patched, all at the same
  time. The retype may have been a harmless step taken while chasing a
  different fault.

What the plan measures (Task 6): a host-linked 10.9 binary, with every
section `info` reports as either type retyped, runs with the same stdout,
stderr and exit status as its input. On this host that means `dyld-239.5`. On
CI's `macos-26` runner it means whatever dyld runs the x86_64 slice there.

### What this means for the feature

The statement costs little (one byte per section) and is safe under one
rule: refuse on an image with no `LC_DYLD_INFO[_ONLY]`. On 10.9 it does
nothing observable. It gives parity with a published recipe that people will
follow. It does not fix any failure anyone has shown. The first question for
the owner is whether to build it at all.

The `info` change is useful either way. Today no query shows a section's type,
so no one can check Celeste's claim, or this spec, without otool.

## What changes

### 1. `info` names each section's type

A new line under each `    sectname=` line, indented **six** spaces, one
level deeper:

```
LC[1] LC_SEGMENT_64 cmdsize=552
  segname=__TEXT vmaddr=0x100000000 vmsize=0x1000 fileoff=0 filesize=4096 nsects=6
    sectname=__text
      type=regular
    sectname=__stubs
      type=symbol-stubs
```

It is a separate line, not a `type=` field on the sectname line.
`tests/cli_test.sh:2426` extracts names with `sed -n 's/^    sectname=//p'`,
and `:2443` asserts `grep -qx '    sectname=ABCDEFGHIJKLMNOP'`. A trailing
field would break both. The precedent is the info-queries spec's rule: thin
output changes only by **added** lines, nested deeper, so that no existing
grep can match them.

The name comes from a table over every `SECTION_TYPE` value
`<mach-o/loader.h>` and `src/mach_compat.h` define, `0x0` through `0x16`. Each is the `S_` constant
in lower case, without the `S_`, with `_` written as `-`: `regular`,
`non-lazy-symbol-pointers`, `symbol-stubs`, `init-func-offsets`. A value
outside the table prints as `type=0x%02x`. Attributes (`S_ATTR_*`, the high
bits) are not printed.

Before the change, a sweep of every `info` consumer must confirm that no
pattern can match a line beginning with six spaces and `type=`. The known
consumers are `compat/insert_dylib.sh:91,101`, `compat/rename_segment.sh:195`,
`tests/bake_mavericks_shim_test.sh`, `tests/grown_binary_runs_test.sh:54-56`,
`tests/import_redirect_test.sh:45`, `tests/insert_dylib_test.sh`,
`tests/wrapper_test.sh:344,1012,1615` and `tests/differential.sh:260`. The
unanchored ones (`grep -q LC_CODE_SIGNATURE`, `grep -qF 'path=…'`,
`grep -q '__DATA_F1'`) look for strings no type name contains.

### 2. The grammar

```
section retype SEG,SECT FROM TO
```

- **`SEG,SECT`** is one operand, split at its **first** comma. Each side must
  be 1 to 16 bytes, or the line is a parse error naming the rule. A segment
  name containing a comma cannot be selected. `ms_split` already treats `,`
  as an ordinary word character (`src/script.h`, `mt_quote`'s bare set). The
  two sides are matched against each `section_64`'s own `segname` and
  `sectname` with `strncmp(field, operand, 16)`. That makes the match exact
  for a name up to 16 bytes long, including one that fills all 16 and has no
  NUL: `__go` does not select `__got`. The section's own `segname` is used,
  not the containing command's, because that pair is the section's identity
  (`ld -sectcreate`, `otool -s`). `segment rename` writes both copies, so
  after a rename the two agree.
- **`FROM`** is **required**, and must be `non-lazy-symbol-pointers` or
  `symbol-stubs`. **`TO`** must be `regular`. A name from item 1's table that
  is not in either list is refused with a message listing what is accepted. So
  is a name outside the table.

Why the guard is required, and not inferred from the section's name:

- The statement is safe because of what the section *is*. Retyping
  `S_MOD_INIT_FUNC_POINTERS` would silently drop initialisers. Retyping
  `S_ZEROFILL` would change how the section is laid out in the file. Retyping
  `S_INIT_FUNC_OFFSETS` would turn off both dyld's initialisers and `grow`'s
  re-basing (`src/grow.c:156,249`). A statement that retypes by name alone
  would do any of these to a section someone had named `__got`.
- With the guard, a miss has one meaning: no section has that name *and* that
  type. Running a finished script a second time then misses, because the
  section is `regular` now. That is how `segment rename` behaves too, and the
  default refusal reports it.

Only `TO=regular` is accepted, so there is no reverse direction. Putting
`S_SYMBOL_STUBS` on an arbitrary section is the unsafe direction. The
statement never writes `reserved1` or `reserved2`, so nothing is lost that a
reverse would need, but no reverse is offered.

### 3. What a retype writes, and what it refuses

For each section that matches, the low byte (`SECTION_TYPE`) of `flags`
becomes `TO`. Attributes and `reserved1/2` are left alone. Nothing changes
size or moves, so the row declares `MREL_NONE`, as `segment rename` and
`dylib retype` do.

**Refusal: an image with no `LC_DYLD_INFO` or `LC_DYLD_INFO_ONLY`, when a
section matched.** That is the classic image, where retyping
`S_NON_LAZY_SYMBOL_POINTERS` crashed as measured above. The refusal covers
both FROM types: one rule is simpler to state and to test, and a classic
image is a pre-10.6 artifact, not the workload. It applies only when
something matched. A classic image with no such section is an ordinary miss,
and the refusal names the section it protected. A chained-fixups image also
has no `LC_DYLD_INFO`, so it is refused too. The fix is to write
`fixups set classic` first. The message says so, the same way `grow`'s
chained-fixups refusal names `fixups set classic`.

The refusal is `MR_REFUSED` (exit 1). `allow-unmatched` does not cover it,
because it is not a miss. The same holds for `fixups set classic`'s refusal
(README "Directives").

### 4. Matched, unmatched, refuse-by-default

A section counts as matched when its `segname`, `sectname` and type all equal
the statement's. The count goes through `me_verdict.renamed`, summed across
the selected slices and judged in the last one. That is the path `segment
rename` and `import redirect` take (`src/edit.c:292-320,397-409`). If nothing
matched:

- stderr: `drydock-macho-rewrite: section retype SEG,SECT FROM TO matched nothing`
- exit 1, nothing written, unless the script says `allow-unmatched`

On success the log line under the statement is `      retyped N section(s)`,
following `me_log_*`'s indented follow-up.

### 5. Fat files

The statement runs per selected slice, the same as every other statement.
Without an `arch` directive that means every 64-bit slice, and with one it
means only the named slices. A match in any selected slice counts. A slice
that matches but has no `LC_DYLD_INFO[_ONLY]` refuses the whole run, and the
refusal line names the slice (`me_statements`' existing `in slice NAME`). The
slices are independent: a universal binary's x86_64 and arm64 slices each
have their own `__got`.

### 6. The `grow` tension, resolved

Of the three options (order a retype before a grow, have grow re-classify,
or refuse the combination) **none is needed.** `grow` accepts `0x0`, `0x6`
and `0x8`. A retype only ever turns one accepted type into another, so it can
never create an image `grow` refuses, and it never needs one grown. Imposing
an order would be a rule enforcing nothing. Having grow re-classify would
re-check what it already checks. Refusing the combination would refuse two
operations that do not interact.

That has to be proved, not just argued. Task 6 runs the same two statements
(a retype, and an `rpath append` long enough to force a grow) in both orders.
It requires both runs to succeed, both to have grown the header (from `info`'s
`header pad:` line and `__TEXT` `vmaddr`, never from `grow.c`'s stderr), and
the two outputs to be **byte-identical**. A mutation that makes `grow` refuse
`0x8` must turn that test red.

This plan changes no line of `src/grow.c`.

### 7. `target 10.9` does not derive it

The profile derives what 10.9 needs (`src/edit.c:571-620`, `me_expand_10_9`). Section 1 of "Why"
found that 10.9 needs nothing here, so deriving it would be a guess. Guessing
is the failure the profile's own comment rules out.

## Testing

TDD throughout. Each behaviour's test is written first and proved to fail,
and each is then mutation-proved: break the implementation, rebuild, confirm
the rebuild happened, watch the test go red, restore.

| what | where |
|---|---|
| `type=` line per section, six spaces, from `fixture.macho`'s known types | `tests/cli_test.sh` |
| an unnamed type prints as hex; every named type round-trips name to value | `tests/script_test.c` (the table is shared) |
| no existing `info` consumer matches the new line | sweep with a positive control, recorded in the commit message |
| grammar: split at first comma, 1–16 bytes each side, FROM and TO vocabularies, arity 3 | `tests/script_test.c` |
| row count 17 → 18, `statement section retype 3` advertised, disturbs `MREL_NONE` | `tests/script_test.c`, `tests/cli_test.sh` |
| retype writes only the type byte; attributes and `reserved1/2` survive | `tests/edit_test.c` |
| exact name match (`__go` misses `__got`); a wrong FROM misses | `tests/edit_test.c` |
| unmatched refuses by default, nothing written; `allow-unmatched` continues | `tests/edit_test.c` |
| no `LC_DYLD_INFO[_ONLY]` + a match refuses, nothing written; no match is a plain miss | `tests/edit_test.c` |
| fat: a match in either slice is a match; `arch` limits it; a classic second slice refuses the run | `tests/edit_test.c` |
| end to end on a host-linked binary: `cmp -l` differs in exactly one byte per retyped section | `tests/section_retype_test.sh` (new) |
| retype and grow in either order give byte-identical output | `tests/section_retype_test.sh` |
| the retyped binary runs identically to its input | `tests/section_retype_test.sh` |

## Files shared with plans drafting in parallel

- **`src/grow.c`: not modified.** Task 6 applies a mutation to it and reverts
  it, never committing. Item 6's comment sweep will change `grow.c`'s stderr
  prefixes (`macho_grow:`), so no test in this plan matches `grow.c`'s stderr.
  Growth is read from `info` instead.
- **`src/script.c` / `src/script.h`**: `MS_TABLE_ROWS` and the kind enum. `minos
  set` and the bind-stream edit each add rows too. All three change the row
  count asserted in `tests/script_test.c:367-422` and
  `tests/cli_test.sh:497-510`, and whichever lands later rebases the count.
  Each appends at the end, because `--capabilities`' statement order is frozen
  (`src/script.c:84-88`).
- **`src/edit.c`**: `me_apply`'s switch gets a new `case`. Same for `minos set`
  and bind-stream edit.
- **`tests/script_test.c`**: `test_disturbs_matches_the_spec_table` and
  `test_capabilities_table_round_trips`' dummy-operand gate.
- **`cli/drydock-macho-rewrite.c`**: `info_cb`. `minos set` may add lines under
  `LC_BUILD_VERSION`, which is a different branch of the same function.
- **`CMakeLists.txt`**: the `drydockcore` source list and one `add_test`.
- **`README.md`**: only in the final task, and only the lines this feature adds.
- The ObjC method-list work shares nothing with this plan's code. It will read
  section types, and item 1's table would serve it.

## Out of scope

- `S_LAZY_SYMBOL_POINTERS` and every other type. The evidence names none of
  them, and the lazy case crashed on a classic image.
- A reverse retype, and printing `S_ATTR_*` in `info`.
- 32-bit input and `fat_arch_64`, which stay refused.
- Correcting QUEUE item 13 and the audit, which is the owner's call (question
  2).

## Questions for the owner

1. **Build the statement at all?** On every image drydock can produce, 10.9's
   dyld ignores both types. That is shown by the source and by measurement.
   Celeste's reason for the change is contradicted.
   *Recommendation:* land Task 1 (`info` names types) regardless. Hold Tasks
   2–7 until someone has a binary that fails on 10.9 and runs after a retype.
   If you want parity with Celeste's published recipe anyway, the plan is
   ready and small.
2. **Correct QUEUE item 13 capability 5, and the audit?** Both state a
   `grow` tension that does not exist for these types.
   *Recommendation:* yes. Replace the tension sentence with the measured
   facts and link this spec. Leave the audit alone: it is scratch, not
   repository text.
3. **Refuse a classic image for both FROM types, or only
   `non-lazy-symbol-pointers`?** Retyping stubs on classic x86_64 measured
   safe. *Recommendation:* both, as one rule. Narrow it only if a real classic
   image ever needs stubs retyped.
4. **Accept `lazy-symbol-pointers` as a FROM?** *Recommendation:* no. No
   evidence asks for it, and it crashed on a classic image.
5. **Offer the reverse (`regular` → either type)?** *Recommendation:* no. It
   is the unsafe direction, and a round trip is not something any user needs.
6. **Should `target 10.9` derive it?** *Recommendation:* no, since there is no
   10.9 finding for it to answer.
7. **`info`: type name only, or `flags=0x…` with the attributes too?**
   *Recommendation:* the name only. Anyone who needs attributes has otool, and
   the info-queries spec's rule is to add the query something depends on,
   which here is the type.
8. **Select by the section's own `segname` or by the containing segment's?**
   *Recommendation:* the section's own. They differ only in malformed input or
   an `MH_OBJECT`, and in both cases the section's own copy is the name
   tools report.
