# Item 6, the machine half — design

**Queue item:** 6, "Human code review + excellent documentation". The narration
sweep (`3ce226a..fb241d3`) was its first half. This spec covers what is left
that a machine can do. The human half is the owner's review of the code and
`README.md`, which the owner is editing by hand. It is not in scope, and
nothing here touches `README.md`.

**Measured at:** `d1cab99` (2026-09-23). The queue's own figures were taken at
`3dc64aa` and have drifted. Every number below is from today and states its
scope.

## Goal

Four pieces of work, each independently reviewable:

- **A.** A comment-density pass on the compat wrappers and support files the
  sweep never reached, plus the history markers in `cli/drydock-macho-rewrite.c`.
- **B.** Fix the present-tense citations of the eight retired filenames. Keep
  the past-tense provenance.
- **C.** Make `src/grow.c`'s 50 `macho_grow: ` diagnostics program-neutral,
  with tests written first.
- **D.** Record in `docs/superpowers/QUEUE.md` what this did and what remains.

## The method (binding on every passage in A)

For each passage, find its home in this order:

1. a **test** (the passage states behaviour; the test fails when someone
   reverses it);
2. the **commit message** (history, measurements, "used to", accounts of a
   retired tool);
3. **`compat/README.md`**, whose divergence tables carry a "held by" column
   naming the assertion;
4. only then **one inline sentence**, for something a reader must see at that
   line to avoid breaking it.

A passage is never reworded in place at the same length. Narration is the
expensive class: accounts of retired tools, measured transcripts, quotations
of earlier comment text, and "used to" or "now". Two tells call for a test or
a deletion: a "can't happen" claim, and a list that keeps other files in sync.

**Falsifiable acceptance for A**, per touched file:

- net comment lines go down (measured with the density tool below);
- the first code line sits near the top: within the first 20 lines of a
  wrapper, and the first 30 of a support file;
- every "can't happen" / "unreachable" / "never" claim in the touched text is
  either deleted or names the test that holds it;
- no code line changes in a comment-only edit. The check is
  `git diff -U0 | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'`,
  which must print nothing for a shell file;
- every pointer elsewhere into a deleted passage is repointed (a dense header
  is a hub).

### The density tool

The rule: in shell, a comment line is one whose first non-blank character is
`#`, the shebang excluded. In C, it is a line inside `/* */` or starting `//`,
and preprocessor lines count as code. This is the queue's rule. The plan's
Global Constraints give the script.

## A. What is above the band, today

The sweep left its wrappers at about 50% comment and 1.2 : 1 comment to code,
with the first code at line 16–18. Measured with the density tool at `d1cab99`,
scope `compat/*.sh` and `cli/drydock-macho-rewrite.c`:

| file | total | comment | code | comment : code | first code | in scope |
|---|---|---|---|---|---|---|
| `compat/patch_macho.sh` | 224 | 169 | 45 | 3.8 : 1 | 137 | yes |
| `compat/rename_segment.sh` | 224 | 167 | 44 | 3.8 : 1 | 159 | yes |
| `compat/add_version_min.sh` | 106 | 82 | 21 | 3.9 : 1 | 77 | yes |
| `compat/retag_swift_classes.sh` | 196 | 139 | 52 | 2.7 : 1 | 111 | yes |
| `compat/translate.sh` | 868 | 509 | 326 | 1.6 : 1 | 230 | yes |
| `compat/drydock-macho-rewrite-compat.sh` | 448 | 266 | 164 | 1.6 : 1 | 68 | yes |
| `cli/drydock-macho-rewrite.c` | 868 | 389 | 435 | 0.9 : 1 | 65 | history markers only |
| `compat/change_dylib.sh` | 51 | 25 | 20 | 1.2 : 1 | 18 | no (swept) |
| `compat/fix_macho.sh` | 47 | 21 | 20 | 1.1 : 1 | 16 | no (swept) |
| `compat/insert_dylib.sh` | 164 | 64 | 84 | 0.8 : 1 | 25 | no (below band) |
| `compat/bake-mavericks-shim.sh` | 201 | 41 | 141 | 0.3 : 1 | 33 | no (below band) |

`compat/rename_segment.sh` changed after the queue was written (`726b360`,
`35338a1`, `0090f23`): 232/190/31 then, 224/167/44 today.

`cli/drydock-macho-rewrite.c` is 868 lines today, down from 1,384 when the
queue counted "22 markers, 7 of them `macho9`". `macho9` now appears twice
(lines 98, 101). This pass takes 17 history passages from it (16 in the
CLI's own task, and line 382–384 in B). The plan lists them by line.

### Where each file's prose goes

The plan has every edit. In summary:

- **Wrapper headers** (`patch_macho`, `rename_segment`, `retag_swift_classes`,
  `add_version_min`) shrink to their four-line usage block plus two sentences
  pointing at `compat/translate.sh` (the grammar) and a `compat/README.md`
  section (the differences, each with its test). `compat/README.md` gains a
  table for `patch_macho`, `retag_swift_classes` and `add_version_min`, the
  three wrappers that have none today. The "WHAT THIS REPLACED" accounts, the
  measured transcripts and the "used to" passages go into the commit messages.
- **The bootstrap prelude** (a five-line comment above the
  `cannot find drydock-macho-rewrite-compat.sh` check, in four wrappers) only
  restates the message it guards. It becomes a test over all eight wrappers
  and the comment goes.
- **`compat/drydock-macho-rewrite-compat.sh`** keeps one sentence per
  function, stating the contract. The fat-container measurement moves to a
  new "Thin only" table in `compat/README.md`, with a held-by column. One
  inline rule stays, placed where awk is used: caller text reaches awk through
  `ENVIRON`, never `-v`.
- **`compat/translate.sh`**: the 211-line header becomes 11 lines. Its
  flag-to-statement table moves to `compat/README.md`. The output contract is
  already held by `tests/translate_test.sh`'s `ok`/`refuses` helpers. The
  divergence list is a copy of `compat/README.md`'s, and it falsely says each
  entry is documented "at its site in `cli/drydock-macho-rewrite.c`"; it goes.
  The in-function comments shrink to one sentence each. Two claims get tests
  that nothing held: the teaching form's `./-FILE.new`, and `MT_PROG` being
  recomputed on every call. One divergence gets a test: fix_macho's
  multibyte `-rename_seg` exits 1 in either locale.
- **`cli/drydock-macho-rewrite.c`**: the removed-verb history, the
  exit-code-renumbering history, and "while `verb edit` stood here" all go to
  the commit message. So does a commit-SHA citation. One claim is false today
  and is corrected: the capabilities contract says "the three read-only
  queries (verify, info, imports)", and `--capabilities` advertises four.
  The two "can never" claims (lines 266, 848) are structural. The first is
  deleted. The second is held by `tests/cli_test.sh`'s `./info` assertions.
  Commit `26d6f8c` (minos-set) added six lines to `info_cb`, so this task's
  line numbers are taken at `26d6f8c`.

### New tests that A adds

| test | holds | file |
|---|---|---|
| every wrapper, symlinked away from its support files, exits 1 naming `DRYDOCK_MACHO_REWRITE_COMPAT_DIR` | the prelude comment's claim | `tests/wrapper_test.sh` |
| `patch_macho notmacho adir` names OUT's problem, not IN's | pre-check order | `tests/wrapper_test.sh` |
| `patch_macho f dangling-symlink` exits 1 and creates nothing | the dangling-symlink refusal | `tests/wrapper_test.sh` |
| `retag_swift_classes good ro/b` counts `good`, errors on `ro/b`, leaves it untouched | the read-only-directory transcript | `tests/wrapper_test.sh` |
| `add_version_min ro/b` exits 2, untouched | the same, forwarded raw | `tests/wrapper_test.sh` |
| `hl_case add_version_min` | its hard-link refusal. A comment in the test claims this is "asserted above", and it is not | `tests/wrapper_test.sh` |
| `fix_macho f -rename_seg __DATA <16 two-byte chars>` exits 1, untouched, under `en_US.UTF-8` and `C` | `${#3}` counts characters | `tests/wrapper_test.sh` |
| `change_dylib -f -delete P` teaches `./-f.new` | `mt_new_name` | `tests/translate_test.sh` |
| one sourced shell translating two tools names each in its usage line | `MT_PROG` per call | `tests/translate_test.sh` |

Each one characterizes behaviour that exists today, so it passes when written.
Its proof is a mutation that makes it fail. The plan names one mutation per
test.

## B. Retired-filename citations

**Scope and pattern.** Files: `src/ cli/ tests/ compat/ CMakeLists.txt`.
Pattern: `git grep -E 'macho_grow\.h|macho_grow_test\.c|(change_dylib|fix_macho|patch_macho|rename_segment|add_version_min|retag_swift_classes)\.c'`.
`\b` must not be used: ERE in `git grep -E` has no `\b`, and a draft of this
count that used it returned 26 lines, omitting every tool-source citation.
The positive control is `git grep -c 'grow\.h' -- src`, which is non-zero.

**Today:** 97 lines (104 occurrences with `-o`) in the code tree; 201
occurrences in the whole tracked tree excluding `docs/superpowers/QUEUE.md`.
The queue's 108 and 199 were at `3dc64aa`.

**The rule.** Provenance in the past tense is kept, because it is history a
reader can trust ("This is compat/rename_segment.c's former …", "Extracted
from change_dylib.c", "compat/fix_macho.c's `-change` used to …"). A
present-tense directive that sends a reader to a file that does not exist is
fixed. It is repointed at the function's current home (`mr_build_lcs_lc` and
`mr_is_deleted` in `src/rewrite.c`, `md_collect_ctx` in `src/declassify.c`,
`tests/grow_test.c`) or deleted. Nothing moves to `PROVENANCE.md`, which is
about the upstream extraction and already names all eight originals.

**Result:** 97 lines before and 49 after. Of the 48 that go, the citation
task fixes 34 in `src/`, `cli/`, `tests/` and `CMakeLists.txt`. The other 14
sit in the `compat/*.sh` headers, and go when the comment pass deletes those
headers. Every survivor is past-tense provenance, or one of the deferred
lines below. The plan gives the per-file target counts. Three of the fixes remove more than a filename:

- `src/grow.c`'s file header narrates its own move from `macho_grow.h`
  ("Nothing else changed in this move; characterize … are the proof"). It is
  deleted to one line.
- `CMakeLists.txt:181-193` explains a warning that existed before "Task 3's
  move". That is a task reference in source, and it goes.
- `src/linkedit.h:36-39` ends "the task that created this module scoped it to
  the latter only". That is also a task reference, and it goes.

One fix corrects a claim, not just a name: `tests/change_dylib_test.sh:1509`
cites "the one approximation it still makes". `mr_change_growth_bytes`'s own
comment says that over-budget case is gone.

## C. `src/grow.c`'s diagnostics

**Count.** `git grep -c 'fprintf(stderr, "macho_grow: ' -- src/grow.c` = **50**
(the queue said 48). Positive control:
`git grep -n 'drydock-macho-rewrite: ' -- tests cli compat` = 12 lines. The
negative `git grep -n 'macho_grow: ' -- tests cli compat` is **not empty**: it
hits `compat/README.md:661`, which quotes the dylib refusal in a table. That
is documentation, not a test, so nothing pins the prefix, but that line has
to change with it. `tests/` and `cli/` are empty.

**The convention.** `src/rewrite.c`'s `mr_report_unmatched` comment:
`"drydock-macho-rewrite: "` is "the one program-specific string in this
file". Every other diagnostic there is program-neutral (`ERROR: ...`),
"because this library does not otherwise know which front end is running it".

**The replacement, per class.** Every one of the 50 becomes `ERROR: `, with
the rest of each message unchanged:

| class | example sites | rewrite.c's sibling | replacement |
|---|---|---|---|
| a refusal after examining the image | `:1067` 32-bit, `:1073` only MH_EXECUTE, `:1079` not PIE, `:1087` arm64, `:1096`, `:1106`, `:1146`, `:792`, `:799`, `:810`, the `implausible --` family | `:585`, `:595`, `:602` (`ERROR: %s: no section data bounds the header pad`) | `ERROR: ` |
| validation failure | `:39`, `:828` | `:1000` (`ERROR: malformed fat file`) | `ERROR: ` |
| internal error / verify FAILED | `:1137`, `:1284`, `:408`–`:439` | `:714`, `:738` | `ERROR: ` |
| allocation failure | `:910`, `:1253`, `:1404` | `:996` (`ERROR: out of memory …`); `:1238` is bare `out of memory` | `ERROR: ` |

One rule for all four classes, for two reasons. rewrite.c's two allocation
messages disagree with each other, and grow.c has no label in scope to print
instead. The strongest precedent is in grow.c itself: `mg_ensure_pad`'s six
refusals (`:63`–`:102`) already begin `ERROR: %s: `. After the change,
`git grep -c 'fprintf(stderr, "ERROR: ' -- src/grow.c` is therefore 56, not 50.
`src/trie.c`'s module prefix (`trie: `) was considered, and the owner asked
for rewrite.c's form. The wording after the prefix is not in scope. That
includes the 32-bit message's "see the comment above this check", which
points a user at source.

**Tests first.** `tests/grow_test.c`'s `stderr_contains_during` learns an
anchor: a needle beginning with `^` must start the line. Without the anchor,
`macho_grow: ERROR: …` would pass. A new
`test_grow_diagnostics_name_no_program` asserts `^ERROR: ` on one message of
each class:

- only MH_EXECUTE;
- not PIE;
- no `__PAGEZERO`;
- 32-bit;
- an unclassified load command (`:792`);
- a classified-but-refused one, chained fixups (`:799`);
- `mg_first_sect_off`'s validation failure (`:39`);
- `mg_plausible`'s un-re-based entry (`:961`).

One CLI-level assertion goes in `tests/wrapper_test.sh`, on the `fix_macho`
non-PIE refusal the suite already runs. The line begins `ERROR: executable is
not PIE`, and no line begins `macho_grow: `. The assertions are shown to fail
against today's text. The prefix change then turns them green, and two
mutations prove them:

- one site reverted, which fails both suites;
- `macho_grow: ERROR: ` doubled, which fails only the anchored check.

The tests and the change ship as one commit, so `main` is never red.

## D. The queue

The row for item 6, and the "Part one" / "Part two" paragraphs, say what was
done. A short new subsection under "Carried out of the narration sweep" gives
the before/after table, the deferred passages, and what remains for the
owner. It follows the queue's own style, with no narration beyond it.

## Deferred, and why

- **`src/declassify.c:2`, `src/version_min.c:2`, `src/version_min.h:10`.**
  These files are excluded (another plan and a just-landed fix own them). All
  three are past-tense provenance and would be kept anyway.
- **`tests/cli_test.sh:1397`** ("add_version_min.c only ever looks for …", a
  present-tense directive). The parallel minos-set plan adds tests to
  `tests/cli_test.sh`. This waits until that plan lands.
- **`tests/cli_test.sh:873`** repoints only if `tests/cli_test.sh` has no
  uncommitted changes when its task runs. Otherwise it is recorded as
  deferred.
- **The `tests/*.sh` headers' own narration** (for example
  `tests/change_dylib_test.sh:44-72`, `tests/wrapper_test.sh:19-22`) is outside
  item 6's named scope, the wrappers. It is left for the owner's review, with
  one exception: `tests/wrapper_test.sh:23-26` points at
  `cli/drydock-macho-rewrite.c`'s `cmd_segment`/`cmd_retag_swift`/`cmd_declassify`,
  which no longer exist, and the translate task repoints it.

## Non-goals

- `README.md`: the owner's.
- The module prefixes (`mi_`, `mr_`, …): a readability decision the queue
  gives to the owner's review.
- Any behaviour change except the 50 diagnostic prefixes.
- A second density sweep of `src/`. The queue's recommendation stands: the two
  big `.c` files run about 1 : 1.
