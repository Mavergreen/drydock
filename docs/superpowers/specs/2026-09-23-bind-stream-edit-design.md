# Editing an existing bind stream: `import weaken` and `import flatten`

## Why

QUEUE.md item 13 ranks two gaps first, and they are one subsystem. They are
what `nfzerox/MavericksAppCompatibilityLayer` does to run Keynote 6.6.2,
Pages 5.6.2 and Numbers 3.6.2 on 10.9.5
(`.superpowers/research-ilife-iwork-backports.md` §2, which quotes
`tools/patch_surgical.py`'s docstring):

1. **Weak-import a bind that already exists.** OR
   `BIND_SYMBOL_FLAGS_WEAK_IMPORT` into the symbol opcode of chosen
   `(library, symbol)` binds, so a symbol 10.9 lacks resolves to NULL instead
   of killing the process at launch.
2. **Point a bind at `BIND_SPECIAL_DYLIB_FLAT_LOOKUP`.** Change the ordinal
   of chosen binds to -2, so dyld looks for the symbol in every loaded image
   in load order. An injected stub dylib that defines it is then found.

Their scale is the argument for selecting by pair: Keynote went from "2,989
bindings weakened" (the blanket first attempt) to "63 symbols actually
flat-redirected + 6 libs weak-loaded" once a per-symbol manifest existed. The
blanket attempt broke `_OSAtomicIncrement32Barrier`, which reaches the image
through `libSystem.B.dylib`'s re-exports.

Neither exists today. `src/declassify.c:607` and `:364` write exactly these
two bytes, but only while it *synthesises* a classic stream out of chained
fixups. No statement reaches into a stream that already exists.

**Flat lookup does not duplicate `import redirect`.** `import redirect`
(`src/redirect.h`) names the shim by ordinal. That is two-level and exact,
and it always calls the shim. A flat lookup names no library, so the first
loaded image that defines the symbol wins. The appended shim loads after the
image's own libraries, so the same binary uses the real symbol on a system
that has it and the shim's on 10.9. Item 15's `DYLD_FORCE_FLAT_NAMESPACE`
gives the same result for the whole process, and its central open question is
whether names from two libraries will collide. `import flatten` confines that
risk to the binds a script names. The cost is the one item 15 avoids: it
writes to the file, so the image has to be signed again.

**What the audit changes about the queue's plan for gap 2.** The queue says
to replace a multi-byte `SET_DYLIB_ORDINAL_ULEB` with the one-byte
`SET_DYLIB_SPECIAL_IMM` and pad the gap with `SET_TYPE_IMM(POINTER)` (`0x51`)
no-ops, "worth lifting verbatim". Since then `src/redirect.c` has solved the
same resize problem for the regular bind stream. It re-encodes the ordinal at
its minimum width. When the stream no longer fits where it is, it moves the
stream to the end of `__LINKEDIT` and grows `__LINKEDIT` to cover it. So the
regular stream needs no filler. The lazy stream still does: each lazy program
is addressed by its offset from `__stub_helper`, so none may move
(`src/redirect.c:317-326` refuses a lazy ordinal it cannot re-encode at its
own width). The filler this design uses is not `0x51`; see "The lazy stream's
filler".

## The statements

```
import  weaken   SYMBOL LIB     every bind of SYMBOL from LIB becomes a weak import
import  flatten  SYMBOL LIB     every bind of SYMBOL from LIB becomes a flat lookup
```

Both are new ops on the existing `import` kind, beside
`import redirect SYMBOL FROM-LIB TO-LIB` (`src/script.c:131`). They take the
same first two operands in the same order, and `drydock-macho-rewrite
imports` prints them as its `symbol` and `install_name` columns. A caller that
has filtered `imports` output can therefore write one statement per row
without reshaping anything.

### Selection

A bind is **selected** when both of these hold:

- its symbol, from the most recent `SET_SYMBOL_TRAILING_FLAGS_IMM`, is
  exactly `SYMBOL`, compared byte for byte with no mangling. That is the
  spelling `imports` prints, underscore included.
- its ordinal is a real library ordinal (`>= 1`) whose load command's install
  name is exactly `LIB`. If more than one load command names `LIB`, every one
  of their ordinals is selected, which is `import redirect`'s rule
  (`mrd_moved`, `src/redirect.c:74-77`).

A bind whose ordinal is special (self, main executable, flat lookup) names no
library, so it is never selected. Both operands are required, and neither
takes a wildcard (see Questions). To weaken a whole library, run one statement
for each symbol `imports` lists for it.

The same predicate chooses symbol-table entries: an undefined, non-stab
`nlist_64` named `SYMBOL` whose `GET_LIBRARY_ORDINAL(n_desc)` is one of the
selected ordinals (`mrd_nlist_selected`, `src/redirect.c:195-205`).

### Which streams

- **bind** and **lazy bind**: selected binds are edited.
- **weak bind**: never edited. It names no library, so there is nothing to
  select, and its flags mean something else there
  (`BIND_SYMBOL_FLAGS_NON_WEAK_DEFINITION`). A weak bind of `SYMBOL` is counted
  and reported with a `WARNING:` line, in the words `import redirect` already
  uses (`src/edit.c:207-211`).
- **symbol table**: selected entries are edited too, so `nm -m` and dyld tell
  the same story. `weaken` sets `N_WEAK_REF`. `flatten` sets the library
  ordinal to `DYNAMIC_LOOKUP_ORDINAL` (0xfe), which is what
  `-undefined dynamic_lookup` writes.

### `import weaken`: patched in place, never grows

The flag is the immediate nibble of the symbol opcode itself
(`BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | flags`), so weakening is a
single `|= 0x01` on one byte for each distinct symbol opcode that serves a
selected bind. No byte moves, the file size is unchanged, `__LINKEDIT` is
unchanged, and the row's disturbs mask is `MREL_NONE`.

One symbol opcode can serve binds from two libraries: `ord:1 sym:_x do ord:2
do` binds `_x` from both. Flipping its flag for one bind flips it for both.
When a symbol opcode serves both a selected and an unselected bind, the
statement **refuses** ("they share one symbol opcode"). This is the
symbol-opcode counterpart of `import redirect`'s refusal of a shared lazy
ordinal opcode. No linker emits that shape for a two-level image, since each
undefined name resolves to one library, so refusing costs nothing real and
avoids re-emitting the stream.

A selected bind that is **already weak** counts as matched and is left as it
is. `weaken` is idempotent, and weakening a weak import is not a miss. The
report says how many were already weak.

The walker has to say where the symbol opcode is, and today it does not:
`mo_bind_state` records `at`, `ord_at` and `done_at` (`src/ordinals.h`). It
gains `sym_at`, set only by an observe-only walk, next to `symbol` and `weak`
(`src/ordinals.c:315-326`).

### `import flatten`: `import redirect`, with the target spelled `-2`

`flatten` is `mrd_redirect` with a different target. The bind-stream
algorithm, the lazy-stream rules, the growth and the verification all stay the
same. `mrd_redirect`'s body becomes a static core that takes its target as a
walker-space ordinal (`MO_ORD_FLAT`, the value `mo_bind_observe` reports for
-2) or a library to look up. `mrd_redirect` and a new `mrd_flatten` both call
it.

The target stays in walker space throughout. If the core compared raw `-2`,
it would equal `MO_ORD_EXE` (-2) in the walker's own numbering. The file's
`-2` is written only by the encoder.

- **Regular bind stream.** This is exactly what `import redirect` does. An
  ordinal opcode that serves only selected binds is replaced by one byte,
  `0x3E` (`SET_DYLIB_SPECIAL_IMM | (-2 & 0xF)`). A selected bind that shares
  its opcode with binds that stay gets `0x3E` in front of it and the old
  ordinal restored after it. The result stays in place when it fits.
  Otherwise it moves to the end of `__LINKEDIT`, which grows to cover it
  (`src/redirect.c:352-372`, `:398-406`), and the report says so. Disturbs
  mask: `MREL_FILE_OFF`, the same as `import redirect`.
- **Lazy bind stream.** Patched in place, and it never moves or changes size.
  A lazy program's ordinal opcode sharing with an unselected bind is refused,
  as `import redirect` already does. See below for the opcode's width.

### The lazy stream's filler

A lazy program's ordinal opcode is 1 byte (`SET_DYLIB_ORDINAL_IMM`, ordinals
up to 15) or 1 + ULEB bytes (`SET_DYLIB_ORDINAL_ULEB`, ordinal 16 and up). The
flat-lookup opcode is always 1 byte. For a wider opcode this design writes
**the same `0x3E` in every byte**: two bytes become `3e 3e`. Each copy sets
the same ordinal again, so the extra bytes change nothing.

`0x51` (the queue's filler) is not used. It sets the bind *type*, and
`mo_bind_walk` starts every stream at type 0 (`memset`, `src/ordinals.c:201`).
A lazy program that never sets a type would therefore read back as type 1
after the edit. dyld would not care, since its lazy binder assumes pointer
type, but `import redirect`'s verification compares `type` bind by bind
(`mrd_same`, `src/redirect.c:181-184`) and would correctly refuse. A repeated
`0x3E` is a no-op that requires no knowledge of the state outside the opcode.
It is the flat-lookup counterpart of what `import redirect` already does for a
real ordinal that is narrower than its slot: `mu_encode_fixed` pads the ULEB
with redundant continuation bytes (`src/uleb.c:25-33`).

### Ordering between the two

`MACL` does both to the same pair: it flattens, so a stub can satisfy the
symbol, and it weakens, so a symbol no stub covers resolves to NULL. Once a
bind is flattened it names no library, so `import weaken SYMBOL LIB` no
longer selects it. **`weaken` has to come before `flatten`.** `flatten` keeps
the weak flag, and its verification already checks that (`x->weak !=
y->weak`, `src/redirect.c:181`).

Written in the wrong order, `weaken` matches nothing and refuses by default,
which surfaces the mistake. The refusal's per-slice report adds one line when
the slice has a flat-lookup bind of `SYMBOL`:

```
      no bind of _x names that library here
      1 bind of _x is a flat lookup, which names no library: weaken before flatten
```

### Matched, unmatched, and fat files

Under the existing refuse-by-default rule (README "Directives"), a statement
**matched** when the number of selected binds in the bind and lazy streams
plus selected symbol-table entries is above zero in at least one selected
slice. Already-weak binds count. Weak-bind occurrences do not, because those
binds are never selected. This is `import redirect`'s count
(`src/edit.c:402`).

A statement that matched nothing prints `drydock-macho-rewrite: import weaken
SYMBOL LIB matched nothing` on stderr and refuses the run (exit 1, nothing
written) unless the script has `allow-unmatched`. A `LIB` the slice does not
load is not an error: that slice contributes zero, the same as
`import redirect`'s FROM-LIB. `import redirect`'s TO-LIB check does not apply,
because neither new statement has a TO-LIB.

**Fat files: per slice**, through the existing `me_run_fat` loop. Each
selected 64-bit slice runs the statement against its own load commands and
ordinals, and the counts are summed in `me_verdict.renamed` across slices. The
verdict is taken in the last selected slice. `arch` directives select slices
as they do for every statement. When `flatten` grows one slice's bind stream,
the slice's size changes, and `me_run_fat` already re-places slices whose size
changed (`me_fat_placed`).

### Refusals, besides matched-nothing

Both statements refuse, with nothing written, in each of these cases:

| condition | message (after `drydock-macho-rewrite: import weaken: ` / `...flatten: `) |
|---|---|
| not a readable 64-bit Mach-O | `the image is not a readable 64-bit Mach-O` |
| `LC_DYLD_CHAINED_FIXUPS` | `the image uses LC_DYLD_CHAINED_FIXUPS; put \`fixups set classic\` before this statement` |
| `LC_LAZY_LOAD_DYLIB` | the existing ordinal-sequence message |
| a dylib name offset past its cmdsize | the existing message |
| no `MH_TWOLEVEL` | `flat namespace: no import names a library, so there is none to weaken` / `flatten` |
| no `LC_DYLD_INFO[_ONLY]` | `no LC_DYLD_INFO: this image binds through relocation entries, which import weaken does not rewrite` |
| a stream or `LC_SYMTAB` out of bounds | the existing messages |
| **weaken**: a symbol opcode serving a selected and an unselected bind | `cannot weaken SYMBOL in the bind stream from this library without also weakening its bind from ordinal N: they share one symbol opcode; refusing` (`lazy bind stream` for the lazy stream) |
| **flatten**: a lazy ordinal opcode serving a selected and an unselected bind | `import redirect`'s existing message |
| **flatten**: the bind stream must grow but `__LINKEDIT` does not end the image | `import redirect`'s existing message |

The first seven checks are the same for all three `import` statements. They
move, with their text unchanged, into a shared bind-selection module
(`src/bindsel.[ch]`, `mbs_`). `import redirect`'s messages stay byte-identical.

### Verification after the rewrite

Neither statement trusts its own write. Each works on a copy, walks the copy
again with `mo_bind_observe`, and refuses on any difference from what it
meant to do:

- **Both.** The bind and lazy streams have the same number of binds, in the
  same order. Every bind has the same symbol, segment, offset, type, addend,
  count, skip and DO-opcode bytes. Every lazy bind is at the same offset from
  the stream's start.
- **weaken.** Every selected bind reads back `weak == 1`, and every other
  bind's `weak` is unchanged. Every bind's ordinal is unchanged. Every symbol
  opcode is at the same offset. The weak-bind stream is byte-identical. The
  file size and every stream's offset and size are unchanged.
- **flatten.** Every selected bind reads back `MO_ORD_FLAT`, and every other
  bind's ordinal is unchanged. Every `weak` is unchanged. The lazy and
  weak-bind streams have not moved, and the weak-bind stream is
  byte-identical. This is `mrd_same`, which already exists.
- **Symbol table.** Every entry is byte-identical except the selected ones,
  whose `n_desc` is the expected value.

The weak-bind comparison is the one that catches a hostile file whose
weak-bind table overlaps the bind stream. `tests/mkbindstream.c alias` builds
that file, and `import redirect` is already tested against it.

After the whole run, `src/edit.c`'s final verify runs as it always has.
`flatten`'s `MREL_FILE_OFF` is what makes that verify run when a statement
only moved a stream.

### The report

Indented under the statement line, in the existing report style:

```
  import weaken _a_gone /usr/local/lib/liba.dylib
      weakened 2 binds (bind 1, lazy 1) and 1 nlist entry from ordinal 1
      1 already weak, left as it was
  import flatten _a_gone /usr/local/lib/liba.dylib
      flattened 2 binds (bind 1, lazy 1) and 1 nlist entry from ordinal 1 to flat lookup
      bind stream rewritten in place (48 bytes)
```

`flatten` reuses `me_log_redirect`. When the target is `MO_ORD_FLAT`, the verb
reads "flattened" and the destination reads "flat lookup". Output from
`import redirect` is unchanged byte for byte.

### The query

**`drydock-macho-rewrite imports` already shows both results, and no new
query is needed.** Its `weak` column is `mo_bind_state.weak`
(`cli/drydock-macho-rewrite.c:571`). A flat-lookup bind prints `flat` in the
`ordinal` column and `-` in `kind` and `install_name` (`:576-586`). The tests
state each result as "`imports` before, with exactly these cells changed,
equals `imports` after". That one comparison asserts both that the edit
happened and that nothing else changed.

No query reports the symbol table's `N_WEAK_REF` or its ordinal. The tests
read them through `tests/mkbindstream.c`, which gains a `weakref` subcommand
beside its existing `nlist`. See Questions.

`--capabilities` advertises `statement import weaken 2` and `statement import
flatten 2` automatically, because it is generated from `MS_TABLE_ROWS`.

## Testing

TDD throughout: each change's test is written first and fails for the stated
reason. Every assertion is mutation-proven against a confirmed rebuild.

| what | where |
|---|---|
| `mo_bind_state.sym_at` names the symbol opcode, across a DONE | `tests/relations_test.c`, `test_bind_walk_reports_positions_and_slots` |
| the extraction changes no `import redirect` behaviour | `tests/import_redirect_test.sh`, unchanged |
| both rows parse, with their arity and operand order, and are advertised | `tests/script_test.c`, `tests/cli_test.sh` |
| both rows' disturbs masks | `tests/script_test.c`, `test_disturbs_matches_the_spec_table` |
| weaken: a regular bind, `imports` changes in exactly one cell, in place | `tests/bind_edit_test.sh` (new) |
| weaken: a missing data symbol kills the process before and is NULL after | `tests/bind_edit_test.sh`, run against a rebuilt library that lacks it |
| weaken: a lazy bind, in place, launches under `DYLD_BIND_AT_LAUNCH` | `tests/bind_edit_test.sh` |
| weaken: symbol table `N_WEAK_REF` | `tests/bind_edit_test.sh`, via `mkbindstream weakref` |
| weaken: already weak leaves the output byte-identical to the input | `tests/bind_edit_test.sh`, a `weak_import` fixture |
| weaken: shared symbol opcode refused; separate ones select one library | `tests/bind_edit_test.sh`, `mkbindstream set` |
| weaken: weak-bind warning, weak table overlapping bind caught by verification | `tests/bind_edit_test.sh`, `mkbindstream set weak`, `alias` |
| both: chained fixups, flat namespace refused | `tests/bind_edit_test.sh` |
| both: matched nothing refuses, `allow-unmatched` reports | `tests/bind_edit_test.sh` |
| both: fat, every slice | `tests/bind_edit_test.sh`, `makefat` |
| flatten: regular in place, `imports` cells, nlist 254 | `tests/bind_edit_test.sh` |
| flatten: the shim's definition is used when the library lacks the symbol, the library's when it has it | `tests/bind_edit_test.sh`, runtime, `DYLD_LIBRARY_PATH` swaps the library |
| flatten: a 2-byte ULEB lazy ordinal becomes `3e 3e`, in place, and still binds | `tests/bind_edit_test.sh`, sixteen-library fixture, `mkbindstream hex` |
| flatten: bind stream grows and moves, and the report says so | `tests/bind_edit_test.sh`, `mkbindstream set` with no slack |
| flatten: shared lazy ordinal refused | `tests/bind_edit_test.sh` |
| weaken then flatten: a covered symbol calls the shim, an uncovered one is NULL | `tests/bind_edit_test.sh`, runtime |
| flatten then weaken: refused, with the ordering hint | `tests/bind_edit_test.sh` |

Runtime cases assert nothing that depends on how a particular dyld behaves.
Every "before" is run the same way as its "after". Lazy cases run under
`DYLD_BIND_AT_LAUNCH=1`, which forces 10.9's dyld to bind lazily-bound symbols
at launch. dyld4, on CI's `macos-26-arm64`, already binds at launch.

## Out of scope

- **Wildcards** (`*` for SYMBOL or LIB). See Questions.
- **`compat/bake-mavericks-shim.sh`** keeps using `import redirect`. Whether
  it should ever emit `flatten` depends on item 15's collision question.
- **Re-signing.** Both statements invalidate an existing
  `LC_CODE_SIGNATURE`, as every statement that writes bytes does. The
  documentation gap about re-signing is item 13's "documentation gap" note,
  and belongs with item 6.
- **Chained-fixups images.** They are refused and pointed at
  `fixups set classic`, as `import redirect` is. Editing a chained import
  table is a different subsystem.
- **A new `info` line.** `imports` already answers.

## Files this shares with plans drafting in parallel

- `src/script.c`, `src/script.h` (`MS_TABLE_ROWS`, the op enum), and
  `tests/script_test.c`, `tests/cli_test.sh` (both pin the row count at 17).
  `minos set` and `section retype` add rows too. Whichever lands second
  rebases the count.
- `src/edit.c`'s `me_apply` switch, which `minos set` and `section retype`
  also extend.
- `README.md`'s Statements block and its "can match nothing" list.
- `CMakeLists.txt`'s `add_library(drydockcore ...)` source line.
- Item 6's comment sweep: `src/redirect.c`, `src/redirect.h` and
  `src/ordinals.h` are edited here. Whichever lands second rebases.

## Questions for the owner

1. **Spelling.** The options are `import weaken SYMBOL LIB` /
   `import flatten SYMBOL LIB` (this design), `import redirect SYMBOL LIB flat`
   (a keyword in TO-LIB, which takes the name `flat` away from install names),
   or the research note's `bind weaken -lib L -symbol S` (a new kind whose
   flags are unlike every other statement's). **Recommendation: the two new
   `import` ops.** They share a kind and an operand order with
   `import redirect`, and one row of `imports` becomes one statement.
2. **Wildcards.** Should SYMBOL or LIB accept `*` (never both at once)?
   `import weaken * LIB` would pair naturally with `dylib retype LIB weak`.
   **Recommendation: not now.** MACL's blanket weakening is the documented
   regression, a caller can loop over `imports`, and adding it later is one
   small task confined to `mbs_select` and `mbs_selected`.
3. **The lazy filler.** The queue text says to lift the `0x51` trick
   verbatim. This design writes repeated `0x3E` instead, for the verification
   reason above. **Recommendation: `0x3E`.** Say so if the queue's wording is
   a constraint rather than a suggestion.
4. **Weaken-then-flatten ordering.** The options are two statements with the
   order enforced by matched-nothing plus the hint (this design), `weaken`
   also selecting a flat-lookup bind of SYMBOL (which loses its LIB
   selectivity), or one combined statement. **Recommendation: this design.**
   It keeps the statements orthogonal, and the wrong order cannot pass
   silently.
5. **A symbol-table query.** No query shows `N_WEAK_REF` or an nlist
   ordinal, so the tests use a fixture helper. **Recommendation: no new
   query.** dyld reads the bind streams, not the symbol table, for an
   `LC_DYLD_INFO` image, and `imports` reports what dyld uses.
