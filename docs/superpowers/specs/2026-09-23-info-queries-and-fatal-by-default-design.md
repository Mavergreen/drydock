# Queryable detections, and unmatched-is-fatal by default

## Why

Two findings, from reading the code behind README.md's three `XXX` markers.

**`target 10.9` is smaller than its framing.** All five statements it derives
are safe to write unconditionally: `fixups set classic` returns
`MDCL_PASSTHROUGH`, a nonzero success, on an image with no chained fixups
(`src/edit.c:431-434`); `version-min set 10.9` is append-if-absent by
construction (`src/version_min.h:47-50`), making the `!f.version_min` guard
redundant with the operation; `segment rename __DATA_CONST __DATA` is harmless
on a `__DATA_CONST` carrying no `__objc_` sections, because the two segments
carry identical `initprot` and 10.9's dyld hardens neither (`src/segname.h:34-40`);
and `swift-abi set legacy` already decides per record which to touch. So the
same five lines produce the same output bytes on every binary, and `target`
buys four lines of boilerplate and knowing that `fixups set classic` goes
first.

What `target` really provides is the *explanation*, and that is unobtainable
any other way: `info` prints segnames and `nsects` but never section names
(`cli/drydock-macho-rewrite.c:393-398`), so "does `__DATA_CONST` carry
`__objc_*`?" cannot be asked; and `mswift_stable_tagged_image`
(`src/swift_retag.h:116`) is called only from `me_expand_10_9`, so the Swift
tag cannot be asked at all. A statement exists because a query is missing.

**`fatal-warnings` is the wrong default.** It is opt-in only to preserve
`fix_macho` and `change_dylib` exiting 0 when an operation matched nothing.
That default costs the tool's own interface its integrity, and it shows:
`compat/rename_segment.sh:227` scrapes stderr for the exact string
`drydock-macho-rewrite: segment <OLD> matched nothing` to recover a verdict the
exit code should have carried.

The repo already has the mechanism for letting a wrapper differ from its
upstream — `compat/README.md:422`, "the adopted divergences", six rows each
held by a named test. Nothing new needs inventing.

## What changes

### 1. `info` answers every detection, on thin files and fat containers

`cmd_info` is a bare `mi_open` today and fails on a fat container. It grows an
`mfat_parse` path printing one block per 64-bit slice under a slice header,
looping the existing `info_cb` per slice. The header is flush left, so it
cannot be mistaken for any line belonging to a load command:

```
slice x86_64: 41216 bytes, 18 load commands, filetype=2
```

A slice that is not a 64-bit Mach-O is named and skipped, matching the wording
`me_run_fat` already uses for one (`slice NAME: 32-bit; passed through
unchanged` / `slice NAME: not a 64-bit Mach-O; …`) rather than inventing a
second vocabulary for the same fact.

**A thin file's output is byte-identical to today's** — no slice header, no
reordering. That is the compatibility requirement, not an aspiration:
`compat/insert_dylib.sh:91,101` greps `^LC\[[0-9]*\] LC_CODE_SIGNATURE ` and
`^  ordinal=[0-9]* path=`, `tests/differential.sh:260` calls this "stable
output", and `tests/bake_mavericks_shim_test.sh` reads four separate shapes
from it.

Two new lines. `sectname=` is indented **four** spaces, one level deeper than
today's two-space `  segname=`, so that no existing grep can match it;
`swift-abi:` is flush left, beside `header pad:`, because it describes the
image rather than a load command:

```
LC[3] LC_SEGMENT_64 cmdsize=712
  segname=__DATA_CONST vmaddr=0x… vmsize=0x… fileoff=… filesize=… nsects=4
    sectname=__objc_classlist
    sectname=__objc_protolist
swift-abi: class records carry the stable-ABI tag
```

Section lines are printed for every `LC_SEGMENT_64`, not only `__DATA_CONST` —
the query answers what is there, and the caller decides what it means.
`sectname` is 16 bytes and need not be NUL-terminated, the same trap
`me_target_lc` wraps with `strncmp`.

The `swift-abi:` line is per-image, from `mswift_stable_tagged_image`, and is
printed in both states so its absence is never ambiguous.

With these, all five of `target`'s findings are queryable.

### 2. `info --thin`, for the wrappers that gate on today's failure

`info --thin FILE` refuses a fat container (exit 1, `mi_open`'s
"not a readable 64-bit Mach-O") and is otherwise today's `info`.

Four wrappers reproduce their upstreams' thin-only refusal by gating on `info`
exiting nonzero. One helper covers three of them:
`mw_thin_only` (`compat/drydock-macho-rewrite-compat.sh:307`) switches to
`info --thin`, which covers `patch_macho.sh:184`, `add_version_min.sh:97` and
`retag_swift_classes.sh:138`. `rename_segment.sh:204`'s inline call switches
too.

The gate must keep intercepting **only** `EX_REFUSED` (1) and letting
`EX_FAIL` (2) fall through, which is what `mw_thin_only`'s comment records and
what makes `add_version_min <dir>` still exit 2 on both sides.

`--capabilities` prints `verb info`; it must advertise the flag, since
`tests/cli_test.sh` asserts capability lines by name.

### 3. `insert_dylib`'s two prompts start working on fat binaries

`compat/insert_dylib.sh:91,101` calls plain `info` on a possibly-fat binary.
Today a fat file makes `info` fail, the output is empty, and **both interactive
prompts silently do not fire** — no "LC_CODE_SIGNATURE found. Remove it?", no
"already contains a load command for that dylib". After change 1 they fire, on
the union across slices.

That is an improvement, and it is adopted rather than suppressed: a new row in
`compat/README.md`'s adopted-divergences table, with its own held-by test. It
is recorded here because it was found by auditing `info`'s consumers, not
designed for.

### 4. Unmatched becomes fatal by default

**`fatal-warnings` ceases to exist.** Its branch at `src/script.c:345` is
deleted, and nothing replaces it: a `fatal-warnings` line then falls through to
`if (n < 2)` at `src/script.c:368` and reports `unknown statement
'fatal-warnings'`, the generic path any typo hits. There is no migration
message and no special case — the tool has no users yet, and a word that no
longer exists should not leave a marker saying so.

**`allow-unmatched` takes the vacated branch**, verbatim in shape — a
directive taking no operands, refused after any operation — with the field's
default inverted. It is named to mirror the `allow-grow` that commit `e6f6d5f`
removed from the same slot.

Consequences:

- `change_dylib` and `fix_macho` emit `allow-unmatched` in their translations
  (`compat/translate.sh`). Upstream fidelity is preserved exactly, so the
  shipped `mavericksforever.com/claude/install.sh` is unaffected, and the
  divergence stays visible in the wrapper source rather than being adopted.
- **`rename_segment.sh:227` deletes its stderr grep.** Zero renames is now a
  nonzero exit; the wrapper reads the exit code and maps it to its exit 2. This
  is the concrete integrity win — a wrapper stops depending on the wording of a
  human-readable message.
- `bake-mavericks-shim.sh:97-102`'s probe drops its `fatal-warnings` line and
  runs the bare statement.
- `me_target` (`src/edit.c:650-659`) sets `allow_unmatched` on its sub-script
  where it cleared `fatal_warnings`. `target`'s semantics are unchanged.

A test mirrors `test_allow_grow_is_an_unknown_statement`
(`tests/script_test.c:227`), pinning `fatal-warnings` alongside a typo so the
removed word stays no more special than any other unknown.

### 5. `target`'s fate, decided after 1–4 land

Not decided here, and deliberately so. The criterion: with every detection
queryable on thin files and fat containers alike, does `target` still earn
being the one statement whose meaning depends on its input? The reading above
says it is a five-line macro whose report is the part that survives — but the
decision is made against working code, not against this paragraph. No code is
written for this step until 1–4 are done.

### 6. README, then the user

`README.md` is revised to match: `target` added to the Statements block it is
currently missing from (the tool calls it a statement — row 16 of
`MS_TABLE_ROWS`, `src/script.c:130`, and `--capabilities` prints `statement
target 10.9 0`), the `fatal-warnings` section rewritten for `allow-unmatched`,
`info`'s new output and `--thin` documented, and Limitations updated. Then the
file goes back to the user for another editing round.

## Testing

TDD throughout; each change's test is written first.

| what | where |
|---|---|
| thin `info` output is byte-identical to today's | `tests/cli_test.sh`, against a stored transcript |
| fat `info` prints one block per 64-bit slice | `tests/cli_test.sh`, on a hand-built two-slice container |
| `sectname=` lines, including a 16-byte unterminated name | `tests/cli_test.sh` |
| `swift-abi:` line in both states | `tests/cli_test.sh`, tagged and untagged fixtures |
| `info --thin` refuses fat, exit 1 | `tests/cli_test.sh` |
| `--capabilities` advertises the flag | `tests/cli_test.sh` capability-line block |
| `mw_thin_only` still intercepts 1 and passes 2 through | `tests/wrapper_test.sh:2071`, extended |
| `insert_dylib`'s two prompts fire on a fat binary | `tests/wrapper_test.sh`, new |
| `fatal-warnings` is an unknown statement, like a typo | `tests/script_test.c`, mirroring `test_allow_grow_is_an_unknown_statement` |
| `allow-unmatched` parses, and is refused after an operation | `tests/script_test.c` |
| an unmatched operation refuses by default, nothing written | `tests/cli_test.sh` |
| `change_dylib`/`fix_macho` still exit 0 on a miss | `tests/wrapper_test.sh`, existing assertions unchanged |
| `rename_segment` exits 2 on zero renames, with no grep | `tests/wrapper_test.sh` |
| `target`'s expansion never counts as unmatched | `tests/cli_test.sh:4073` block, unchanged |

## Out of scope

- **`version-min set 10.9` never overwrites an existing higher floor.** A
  binary declaring `LC_VERSION_MIN_MACOSX 10.15` gets no correction from the
  statement or from `target`, because the operation is append-if-absent
  (`src/version_min.h:47-50`). Noticed while reading; it is a separate question
  about what the statement should mean, not part of this work.
- 32-bit input and `fat_arch_64` containers stay refused.
- Module prefix readability (`mi_`, `mr_`, `mg_`, …), still deferred.
