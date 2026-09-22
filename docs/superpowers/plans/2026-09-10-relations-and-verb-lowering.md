# Relations and Verb Lowering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Declare what points at what as data, derive from it both "which operations carry follow-up work" and "which checks apply to this run", and make the CLI verbs build an `ms_script` and call `me_run` instead of carrying a second grammar.

**Architecture:** One new module, `src/relations.c` (`mrel_`), holding five relation declarations and the derivation over them. The operation table created by the edit-scripts work gains a "disturbs" column, becoming the single place a new operation declares its consequences; `DYLIB_OPS` merges into it. The hand-written `mr_is_rename_only` is proved equivalent-modulo-an-enumerated-list against the derivation, then deleted.

**Tech Stack:** C99, stock 10.9 AppleClang 6.0, CMake + ctest. Hermetic C unit tests in the `trie_test.c`/`linkedit_test.c` idiom; CLI behaviour in `tests/cli_test.sh`.

**Spec:** `docs/superpowers/specs/2026-09-10-relations-and-verb-lowering-design.md`

**Depends on:** `docs/superpowers/plans/2026-09-10-edit-scripts.md` having landed. `MS_TABLE`, `ms_script`, `ms_stmt` and `me_run` all come from it; every task here consumes one of those four names. **That dependency is satisfied** — all four exist at HEAD: `MS_TABLE` (`src/script.c:75-92`, fifteen rows), `ms_script` (`src/script.h:58-67`), `ms_stmt` (`src/script.h:50`), `me_run` (`src/edit.h:71-72`).

**Amended 2026-09-13**, against a drift scan of `HEAD`. Five items shipped between this plan being written and being executed, and the spec carries an amendment: the derived applicability governs **both** front-ends, not only `mr_process_thin`'s gate site (Decision 5), relations are evaluated per slice (Decision 6), `needs_renumber` stays hand-written (Decision 7), and `target 10.9` declares `MREL_NONE` (Decision 8). Task 6 is new and Task 7 was Task 6.

## Global Constraints

- **`tests/EXPECTED` is a characterization reference and is never edited.** `tests/characterize.sh` must keep reproducing `ad12bdd780da4131f81a808e6d08b688e2034f37e434772f81df023332b39792`. It covers emitted bytes: this plan changes *which checks run*, never what gets written, so a moved digest is a real defect.
- **The six `compat/` wrappers' stdout must stay byte-identical.** `tests/known-callers.sh` and `tests/wrapper_test.sh` are the gates. The verbs' `printf` calls do not move in this plan.
- **The tools must never move a byte of file data.** Two reviewed exceptions: `-grow`'s memmove after the load commands, and the export-trie append past `__LINKEDIT`'s end.
- **POSIX `/bin/sh` only** in `compat/*.sh` and test scripts. No `[[`, `local`, `+=`, arrays, `<<<`, `$'...'`, `function`, `source`, `shopt`.
- **Stock 10.9 AppleClang 6.0, warning-free** (`-Wall -Wextra` on new targets).
- **A comment or doc that claims more than the code does is a defect.** This repo means it literally, and this plan deletes a predicate whose replacement must be *proved* rather than asserted.
- **Relations declare referent and liveness only.** No relation declares a check or a repair function; repair code does not move. That is Decision 1, and widening it is out of scope.
- **CI is a gate, not an afterthought.** After each task's push, read `gh run
  list --repo Mavergreen/macho-tools --limit 3`. Local green is not CI
  green: item 6 shipped a `cli_test` assertion that was red on `main` for a day
  because it named `arch arm64` as unsatisfiable while the fixture is built for
  the *host*, so it inverted on GitHub's `macos-26-arm64` runner and could not
  fail on any x86_64 machine. **A mutation proof is only valid in the
  environment the mutation ran in.** Suspect host-dependence in any assertion
  that something is absent, refused, or unsatisfiable. NOTE: the `conventions`
  job is already red on a pre-existing rule that belongs to item 4 (`no workflow
  builds the release body with the shared generator (release-notes.sh)`) — that
  one is not yours; the `release` job's `build` must stay green.
- **Pass test suites an ABSOLUTE build dir.** `tests/cli_test.sh` accepts a
  relative one and then silently fails 11 assertions.
- **A grep is evidence only once you have seen it return a hit on a case you
  know exists.** State a negative only after a positive control. Five false
  claims in item 6 came from empty greps: one missed a backtick, one missed
  backticks around an identifier, `exit [0-9]` matched only literal digits and
  missed `exit "$mw_rc"`, `grep -c calloc` counted the comment stating the count
  (3 for an answer of 2), and one missed a phrase spanning a line break.
- **State the scope with every count.** Three agents miscounted the same string
  at three unstated scopes in item 6. Rows are not lines; `#include` is not a
  comment.
- **Prefer deleting a passage to paraphrasing it.** Twice in item 6 the original
  comment was more precise than a summary of it, and the summary was then false
  ("the codes this wrapper produces *itself* are all 1" became "there is no
  `exit 2`"). Deletion loses information visibly; paraphrase loses it invisibly
  and leaves something that still reads as authoritative.
- **New comments follow item 6's rules**, since this plan creates a module:
  a surviving load-bearing comment carries a tag from a closed set of two —
  `platform:` for a platform fact that bit us, `spec:` for a pointer to where
  the decision lives — and an interface contract in a header carries no tag.
  Bucket 3 explains WHY; bucket 5 states WHAT. A `spec:` tag must name a target
  that exists. Anything else load-bearing becomes a test whose FAIL message
  carries what the comment would have said.
- **Run the family gates from a shipyard checkout on `main`.** Item 6 reported
  `check-family-conventions: ok` for six tasks from
  `trees/mavericks-shipyard-readme-gate/scripts/`, which is on a feature branch
  and does not contain the `release-notes.sh` check at all. Verify the checkout's
  branch before trusting its verdict.

---

### Task 1: Declare the relations

Data and one derivation function. Nothing consumes it yet, so this task is safe to land on its own and is where a reviewer can argue with the model before any behaviour depends on it.

**Files:**
- Create: `src/relations.h`, `src/relations.c`
- Create: `tests/relations_test.c`
- Modify: `CMakeLists.txt` — add `src/relations.c` to `machotoolcore`; add the `relations_test` target and test

**Interfaces:**
- Consumes: `mi_image` (`src/image.h`).
- Produces:

```c
/* What is pointed AT. A bitmask so an operation can disturb several. */
enum {
    MREL_NONE       = 0,        /* spelled, never defaulted: see ms_disturbs */
    MREL_ORDINAL    = 1u << 0,  /* the ordinal-carrying LC subsequence */
    MREL_BASE_REL   = 1u << 1,  /* the image base */
    MREL_FILE_OFF   = 1u << 2,  /* __LINKEDIT's blobs */
    MREL_FUNC_START = 1u << 3,  /* LC_FUNCTION_STARTS */
    MREL_HEADER_PAD = 1u << 4   /* sizeofcmds, i.e. the first section's offset */
};

/* Which relations are LIVE in this image -- present and therefore checkable. */
unsigned mrel_live(const mi_image *im);

/* Human name for one bit, for diagnostics. NULL if `bit` names no relation. */
const char *mrel_name(unsigned bit);

/* Does mg_plausible have anything to check on THIS image after a run that
 * disturbed `disturbed`? The one expression both front-ends' gate sites use,
 * so there is no second copy to drift: the initializer-and-unwind relation
 * must be LIVE here (MREL_FUNC_START), and the run must have disturbed the
 * base-relative values those offsets are (MREL_BASE_REL). Nonzero means run
 * the gate. */
int mrel_verify_applies(const mi_image *im, unsigned disturbed);
```

`mrel_verify_applies` takes a **slice**, not a container: `mrel_live` has no
single answer for a fat file, so a fat run derives applicability once per
slice, as `me_statements` (`src/edit.c:671`) and `mg_plausible`
(`src/edit.c:676`) already run per slice. That is Decision 6 of the spec.

The two bits are **not** the same bit, and the pairing is the whole content of
the function: `MREL_FUNC_START` is what must be *present to check*, and
`MREL_BASE_REL` is what must have been *disturbed* for the check to have a
question. No operation in Decision 2's table declares `MREL_FUNC_START` —
`mg_plausible` reads `LC_FUNCTION_STARTS`, it never rewrites it — so an
expression that AND-ed a declared mask against `MREL_FUNC_START` would be zero
for every run and the gate would never fire, including for `fixups set classic`
and for a grow. Both of those disturb `MREL_BASE_REL`, which is why that is the
bit the second operand tests.

- [ ] **Step 1: Write the failing test**

`tests/relations_test.c`:

```c
/*
 * tests/relations_test.c — hermetic tests for src/relations.c.
 *
 * Images are built by hand with mi_wrap (same reasoning as linkedit_test), so
 * this is host-agnostic. What is under test is mrel_live: which relations a
 * given image actually has, which is the applicability half of the design.
 *
 * Build: clang -O2 -Wall -Isrc -o /tmp/reltest tests/relations_test.c \
 *   src/relations.c src/image.c && /tmp/reltest
 */
#include "relations.h"
#include "../src/image.h"
#include <stdio.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

static void test_header_pad_is_always_live(void) {
    /* Every Mach-O has a sizeofcmds and a first section, so the header-pad
     * relation is live in every image. If this ever returns 0 the derivation
     * silently stops guarding growth. */
    uint8_t buf[4096]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);   /* helper below */
    CHECK((mrel_live(&im) & MREL_HEADER_PAD) != 0, "header pad is live in a minimal image");
}

static void test_func_start_liveness_follows_the_load_command(void) {
    uint8_t buf[4096]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    CHECK((mrel_live(&im) & MREL_FUNC_START) == 0,
          "no LC_FUNCTION_STARTS -> the func-start relation is NOT live");
    add_function_starts(buf, &im, 0x10);          /* helper below */
    CHECK((mrel_live(&im) & MREL_FUNC_START) != 0,
          "with LC_FUNCTION_STARTS -> it IS live");
}

static void test_ordinal_liveness_follows_ordinal_carrying_commands(void) {
    uint8_t buf[4096]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    CHECK((mrel_live(&im) & MREL_ORDINAL) == 0,
          "no dylib commands -> the ordinal relation is NOT live");
    add_load_dylib(buf, &im, "/usr/lib/libSystem.B.dylib");   /* helper below */
    CHECK((mrel_live(&im) & MREL_ORDINAL) != 0,
          "one LC_LOAD_DYLIB -> it IS live");
}

static void test_names_round_trip(void) {
    CHECK(strcmp(mrel_name(MREL_ORDINAL), "library ordinal") == 0, "ordinal name");
    CHECK(mrel_name(1u << 20) == NULL, "an unknown bit has no name");
}

static void test_verify_applies_needs_a_live_relation_AND_a_disturbance(void) {
    /* Both operands, separately. A run that disturbed nothing has nothing to
     * re-check however live the relation is; a disturbance of the image base
     * has nothing to check in an image that declares no function starts. The
     * two are pinned apart because collapsing them into one bit is the bug
     * that would make this gate never fire. */
    uint8_t buf[4096]; mi_image im;
    build_minimal_image(buf, sizeof buf, &im);
    add_function_starts(buf, &im, 0x10);
    CHECK(mrel_verify_applies(&im, MREL_BASE_REL) != 0,
          "live func-starts + a disturbed image base -> the gate applies");
    CHECK(mrel_verify_applies(&im, 0) == 0,
          "live func-starts + nothing disturbed -> nothing to check");
    CHECK(mrel_verify_applies(&im, MREL_HEADER_PAD) == 0,
          "a disturbed header pad alone moves no base-relative value");
    CHECK(mrel_verify_applies(&im, MREL_ORDINAL | MREL_HEADER_PAD) == 0,
          "ordinals and pad together still move no base-relative value");
    CHECK(mrel_verify_applies(&im, MREL_FILE_OFF | MREL_BASE_REL | MREL_HEADER_PAD) != 0,
          "fixups set classic's own mask -> the gate applies");

    build_minimal_image(buf, sizeof buf, &im);   /* no LC_FUNCTION_STARTS */
    CHECK(mrel_verify_applies(&im, MREL_BASE_REL) == 0,
          "no LC_FUNCTION_STARTS -> nothing to check even after a re-base");
}
```

Write `build_minimal_image`, `add_function_starts` and `add_load_dylib` in this file, following `tests/linkedit_test.c`'s hand-built-image idiom. Do not add a fixture file: a fixture built by the host toolchain would make liveness depend on what the local linker emits, which is the exact failure that made `tests/cli_test.sh`'s build-version fixtures red on the cross runner and green here.

- [ ] **Step 2: Run it and watch it fail to build**

```bash
clang -O2 -Wall -Isrc -o /tmp/reltest tests/relations_test.c src/relations.c src/image.c
```

Expected: failure — `src/relations.h` does not exist.

- [ ] **Step 3: Write `src/relations.h`**

Declare the enum, `mrel_live`, `mrel_name` and `mrel_verify_applies` exactly as in the Interfaces block above. Above the enum, write the five-row table from the spec — relation, referent, and what repairs it today — because the enumerator names alone do not say what is pointed at, and that is the whole content of this module.

State in the header that a relation declares **referent and liveness only**, that no relation declares a check or a repair, and that repair code stays where it is. That is Decision 1 of the spec, and a later reader will otherwise assume the module is half-finished.

- [ ] **Step 4: Write `src/relations.c`**

`mrel_live` walks the load commands once via `mi_each_lc` and sets:

- `MREL_HEADER_PAD` — always; every image has a `sizeofcmds`.
- `MREL_FUNC_START` — when `LC_FUNCTION_STARTS` is present with a non-zero `datasize`.
- `MREL_ORDINAL` — when at least one ordinal-carrying command is present. **Call `mo_is_ordinal_lc` (`src/ordinals.h`); do not re-list the four command kinds.** A second list of which commands carry ordinals is precisely the drift this module exists to prevent, and `mo_is_ordinal_lc` is already the one place that knowledge lives.
- `MREL_FILE_OFF` — when any command from `src/linkedit.h`'s list is present. Build the case labels from that list, the way `ml_bump_lc` does; do not re-list them.
- `MREL_BASE_REL` — when the image has a segment mapping the header, i.e. `mi_image_base` returns 0. Use `mi_image_base`, **not** `mi_text_base`: a dylib links at base 0, and reading that 0 as "no segment maps the header" is the bug that made `mg_plausible` refuse every dylib.

`mrel_verify_applies` is the one expression, and nothing else:

```c
int mrel_verify_applies(const mi_image *im, unsigned disturbed) {
    return (mrel_live(im) & MREL_FUNC_START) != 0 &&
           (disturbed & MREL_BASE_REL) != 0;
}
```

- [ ] **Step 5: Run the tests and watch them pass**

```bash
clang -O2 -Wall -Wextra -Isrc -o /tmp/reltest tests/relations_test.c \
    src/relations.c src/image.c src/ordinals.c && /tmp/reltest
```

Expected: `relations_test: 0 failure(s)`, no warnings.

- [ ] **Step 6: Prove the tests can fail**

Make `mrel_live` return `MREL_HEADER_PAD` unconditionally and confirm the func-start and ordinal tests fail. Revert.

Then change `mrel_verify_applies`' second operand from `MREL_BASE_REL` to `MREL_FUNC_START` — the collapse the Interfaces note warns about — and confirm both of its "the gate applies" assertions fail (the `MREL_BASE_REL` one and the `fixups set classic` mask one) while the four "nothing to check" assertions still pass. Revert. That mutation is the one worth proving can fail: a gate that never fires looks exactly like a gate that is working, from the outside.

Record both mutations and what broke in the task report.

- [ ] **Step 7: Wire into CMake and commit**

```cmake
# Hermetic tests for src/relations.c: hand-built images, no fixture file, so
# liveness never depends on what the host linker emits -- the dependence that
# made cli_test's build-version fixtures pass here and fail on the cross runner.
add_executable(relations_test tests/relations_test.c)
target_compile_options(relations_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(relations_test PRIVATE machotoolcore)
add_test(NAME relations_test COMMAND relations_test)
```

```bash
cmake --build /private/tmp/mm-build/schmonz/macho-tools/native
ctest --test-dir /private/tmp/mm-build/schmonz/macho-tools/native
git add src/relations.h src/relations.c tests/relations_test.c CMakeLists.txt
git commit -m "feat: declare the five relations and which are live in an image"
```

---

### Task 2: One operation table, with a disturbs column

`DYLIB_OPS` merges into the edit-script statement table, and every row gains the referents it disturbs.

**Files:**
- Modify: `src/script.h`, `src/script.c` — the table gains columns
- Modify: `cli/machotool.c` — delete `DYLIB_OPS`; the verb parser and `--capabilities` read the merged table
- Modify: `tests/script_test.c`, `tests/cli_test.sh`

**Interfaces:**
- Consumes: `MS_TABLE` and the `MS_*` enumerators (edit-scripts Task 2); `MREL_*` (Task 1).
- Produces:

```c
/* Referents this operation disturbs, as an MREL_* mask. */
unsigned ms_disturbs(int kind, int op);

/* Enumerate the table for --capabilities and for the verb parser.
 * `flag` is the verb spelling ("-replace") or NULL for script-only rows;
 * `modes` is a bitmask of MS_MODE_DYLIB / MS_MODE_RPATH, 0 when not
 * mode-scoped. Returns 0 when `i` is past the end. */
int ms_table_row(int i, const char **kind, const char **op, int *nargs,
                 const char **flag, unsigned *modes, unsigned *disturbs);
```

Note this widens edit-scripts' `ms_table_row`, which has **three** out-parameters today — `int ms_table_row(int i, const char **kind, const char **op, int *nargs)` (`src/script.h:106`, defined `src/script.c:95`) — to **six**. `i` is an in-parameter, not an out-parameter; the total parameter count goes four → seven. Update both existing callers in the same commit: `print_capabilities`' loop (`cli/machotool.c:418`) and `tests/script_test.c:338`.

- [ ] **Step 1: Write the failing test**

Append to `tests/script_test.c`:

One assertion per `MS_TABLE` row: fifteen, not eleven. `MS_TABLE`
(declared `src/script.c:75-92`, its fifteen rows `:77-91`) already splits
`dylib` from `rpath` and splits `rpath`'s
four operations, and it carries a fifteenth row the spec's prose table folds
away — `{ "target", MS_TARGET, "10.9", MS_PROFILE_10_9, 0 }` (`src/script.c:91`).
The tripwire below demands a mask for every row, so every row gets one here.

```c
static void test_disturbs_matches_the_spec_table(void) {
    /* One assertion per MS_TABLE row -- fifteen. These are the rows the design
     * checked against the code that implements each operation rather than
     * reasoning from the operation's name. Two of them came out the opposite
     * of the design's own first draft, so they are pinned here: a regression
     * would be silent otherwise, because "disturbs nothing" is a
     * plausible-looking answer for every row. */
    CHECK(ms_disturbs(MS_SEGMENT, MS_RENAME) == 0, "segment rename disturbs nothing");
    CHECK(ms_disturbs(MS_SWIFT_ABI, MS_SET) == 0, "swift-abi set disturbs nothing");

    /* reexport is an in-place promotion of LC_LOAD_DYLIB to LC_REEXPORT_DYLIB
     * (src/rewrite.h:20-21; the in-place-ness is in the code, not the header --
     * src/rewrite.c:362-365 sets ndc->cmd on the command already copied at its
     * own position). Both carry ordinals, so membership, order and length of
     * the subsequence are all unchanged. */
    CHECK(ms_disturbs(MS_DYLIB, MS_REEXPORT) == 0, "dylib reexport disturbs nothing");

    /* append lands LAST (src/rewrite.h:48), taking the highest ordinal, so no
     * existing ordinal moves -- only the command region grows. */
    CHECK(ms_disturbs(MS_DYLIB, MS_APPEND) == MREL_HEADER_PAD,
          "dylib append disturbs the header pad only");
    CHECK(ms_disturbs(MS_DYLIB, MS_REPLACE) == MREL_HEADER_PAD,
          "dylib replace keeps its position and ordinal; only a longer path costs pad");

    /* insert lands FIRST (src/rewrite.h:50) and inserted dylibs become
     * ordinals 1..n (src/rewrite.h:44), shifting every existing one. */
    CHECK(ms_disturbs(MS_DYLIB, MS_INSERT) == (MREL_ORDINAL | MREL_HEADER_PAD),
          "dylib insert disturbs ordinals and the pad");
    CHECK(ms_disturbs(MS_DYLIB, MS_DELETE) == (MREL_ORDINAL | MREL_HEADER_PAD),
          "dylib delete disturbs ordinals and the pad");

    /* All four rpath operations, spelled out: LC_RPATH is absent from
     * mo_is_ordinal_lc's four kinds (src/ordinals.c:11-14), so only the
     * command count changes. One row here per MS_TABLE row, because the
     * tripwire below demands a mask per row and "the other three are like
     * this one" is not an assertion. */
    CHECK(ms_disturbs(MS_RPATH, MS_APPEND) == MREL_HEADER_PAD,
          "rpath append: rpath commands carry no ordinal");
    CHECK(ms_disturbs(MS_RPATH, MS_INSERT) == MREL_HEADER_PAD,
          "rpath insert: searched FIRST, but still carries no ordinal");
    CHECK(ms_disturbs(MS_RPATH, MS_REPLACE) == MREL_HEADER_PAD,
          "rpath replace: only a longer path costs pad");
    CHECK(ms_disturbs(MS_RPATH, MS_DELETE) == MREL_HEADER_PAD,
          "rpath delete: frees pad, shifts no ordinal");

    CHECK(ms_disturbs(MS_LOAD_COMMAND, MS_DELETE) == MREL_HEADER_PAD,
          "load-command delete frees pad and moves no section offset");
    CHECK(ms_disturbs(MS_VERSION_MIN, MS_SET) == MREL_HEADER_PAD,
          "version-min set appends a command");

    /* THREE bits, not two. src/declassify.h:32-37: the conversion strips
     * LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS and every LC_BUILD_VERSION,
     * then adds a 48-byte LC_DYLD_INFO_ONLY -- which is "frees pad" and
     * "appends a command", the same two reasons load-command delete and
     * version-min set earn MREL_HEADER_PAD. Leaving the pad bit off made the
     * spec's own table internally inconsistent, and the bit is load-bearing:
     * disturbing the pad is exactly the condition under which allow-grow
     * becomes relevant. */
    CHECK(ms_disturbs(MS_FIXUPS, MS_SET) ==
              (MREL_FILE_OFF | MREL_BASE_REL | MREL_HEADER_PAD),
          "fixups set classic rebuilds __LINKEDIT, re-bases, and costs pad");

    /* target 10.9 declares MREL_NONE, meaning "nothing OF ITS OWN". It is an
     * MS_TABLE row (src/script.c:91), not an ms_script field like allow-grow,
     * so the tripwire demands a mask -- and no static mask can describe it,
     * because it expands at run time against the image in front of it
     * (src/edit.c:476-514, up to five derived statements). Each derived
     * statement declares its own mask and runs through the same accumulation,
     * so the union is computed from what actually ran. A bare 0 here would
     * read as an unreviewed default, which is what the tripwire exists to
     * prevent; MREL_NONE plus this comment is the reviewed answer. */
    CHECK(ms_disturbs(MS_TARGET, MS_PROFILE_10_9) == MREL_NONE,
          "target 10.9 disturbs nothing of its own; its expansion declares its own");
}

static void test_every_row_declares_its_disturbs(void) {
    /* "Nothing" is a real and common answer, so it must be SPELLED. This
     * catches a row added with a default-zero disturbs column that nobody
     * thought about -- which would silently opt the new operation out of
     * every check. */
    int i = 0; const char *k, *o, *f; int n; unsigned modes, d;
    while (ms_table_row(i, &k, &o, &n, &f, &modes, &d)) {
        CHECK(ms_row_disturbs_declared(i),
              "row %d (%s %s) declares its disturbs explicitly", i, k, o);
        i++;
    }
    CHECK(i > 0, "the table is not empty");
}
```

- [ ] **Step 2: Run and watch it fail**

Expected: `ms_disturbs` and `ms_row_disturbs_declared` do not exist.

- [ ] **Step 3: Widen the table**

Each `MS_TABLE` row gains: `flag` (the verb spelling, `NULL` for script-only), `modes`, `disturbs`, and `declared`. Fill `flag` and `modes` from the `DYLIB_OPS` rows being absorbed, and `disturbs` from Task 2 Step 1's values, which are the spec's checked table.

**Make "declared" impossible to skip.** A row is written through a macro that takes the disturbs mask as a required argument and sets `declared = 1`; `ms_row_disturbs_declared` returns that field. A row added without the macro fails `test_every_row_declares_its_disturbs`. This is the tripwire the spec asks for, in the spirit of `linkedit.h`'s link error — weaker, because C cannot make a missing initializer a link error here, so the test is the enforcement and its comment must say so rather than implying the compiler catches it.

- [ ] **Step 4: Point the verb parser and `--capabilities` at the merged table**

Delete `DYLIB_OPS` (`cli/machotool.c:251-257`, its `struct dylib_op` at `:243-249`) and `N_DYLIB_OPS` (`:258`) from `cli/machotool.c`. `cmd_dylib_or_rpath`'s flag matching (`:809-816`) and the capability printer (`print_ops_csv`, `:267-277`) both walk `ms_table_row`, filtering on `modes`.

The `--capabilities` **output text must not change**: it is a documented interface that wrappers read. Assert that in `tests/cli_test.sh`:

```sh
# The merged table must produce the SAME capabilities text as the two tables
# did. This is a documented interface -- compat/machotool-compat.sh probes it --
# so merging the tables is allowed to change where the text comes from and
# not what it says.
"$MACHOTOOL" --capabilities >"$T/caps_merged.out" 2>&1
grep -q "verb dylib ops=replace,delete,append,insert,reexport" "$T/caps_merged.out" \
    && ok "capabilities: dylib op list unchanged by the merge" \
    || bad "capabilities merge" "dylib ops line changed: $(grep "^verb dylib" "$T/caps_merged.out")"
grep -q "verb rpath ops=replace,delete,append,insert" "$T/caps_merged.out" \
    && ok "capabilities: rpath op list unchanged, still omits reexport" \
    || bad "capabilities merge" "rpath ops line changed: $(grep "^verb rpath" "$T/caps_merged.out")"
```

Before writing those two `grep` patterns, run `machotool --capabilities` on the pre-merge build and copy the real lines. Do not trust the patterns above to match verbatim — they are the shape, and the build is the authority.

- [ ] **Step 5: Run everything and watch it pass**

```bash
cmake --build /private/tmp/mm-build/schmonz/macho-tools/native
ctest --test-dir /private/tmp/mm-build/schmonz/macho-tools/native
sh tests/known-callers.sh /private/tmp/mm-build/schmonz/macho-tools/native
```

`known-callers` is the one that matters here: it replays the shapes real callers use, and the verb parser was just rewritten underneath them.

- [ ] **Step 6: Commit**

```bash
git add src/script.h src/script.c cli/machotool.c tests/script_test.c tests/cli_test.sh
git commit -m "refactor: one operation table, carrying what each op disturbs"
```

---

### Task 3: Derive which operations carry follow-up work

**Files:**
- Modify: `src/edit.c` — the follow-up decision reads the table
- Modify: `tests/edit_test.c`

**Interfaces:**
- Consumes: `ms_disturbs` (Task 2).
- Produces: `me_followups(const ms_script *s)` returning the union of every statement's disturbs mask.

`me_followups` is the **declared** union over the statements as parsed, which is not the whole answer and is not meant to be: `target 10.9` declares `MREL_NONE` and expands at run time (`src/edit.c:476-514`), and a header grow disturbs the image base whichever statement asked for it. Task 6 accumulates what the run actually did, statement by statement, and `me_followups` is what it starts from for a script with no `target` and no grow. That split is the spec's "Applicability is evaluated against what the run did, not only what it declared."

- [ ] **Step 1: Write the failing test**

```c
static void test_followups_are_the_union_of_the_statements(void) {
    /* A rename plus a swift-abi retag disturbs nothing; adding one dylib
     * delete makes the whole script disturb ordinals. The union, not the
     * last statement and not the first. */
    ms_script s; char err[256] = {0};
    static const char quiet[] = "segment rename __A __B\nswift-abi set legacy\n";
    CHECK(ms_parse(quiet, sizeof quiet - 1, &s, err, sizeof err) == 0, "parses (%s)", err);
    CHECK(me_followups(&s) == 0, "a quiet script disturbs nothing");
    ms_free(&s);

    static const char loud[] =
        "segment rename __A __B\nswift-abi set legacy\ndylib delete /x.dylib\n";
    CHECK(ms_parse(loud, sizeof loud - 1, &s, err, sizeof err) == 0, "parses (%s)", err);
    CHECK((me_followups(&s) & MREL_ORDINAL) != 0,
          "one dylib delete makes the whole script disturb ordinals");
    ms_free(&s);
}
```

- [ ] **Step 2: Run and watch it fail**

Expected: `me_followups` does not exist.

- [ ] **Step 3: Implement it, and delete what it replaces**

`me_followups` is a loop OR-ing `ms_disturbs(st->kind, st->op)` over the statements.

**There is exactly one site that decides "does this need the ordinal renumbering pass?", it has already been found, and the ruling is that it does NOT move.** No implementer judgement is needed here, and nothing in this step is a search:

```c
/* src/rewrite.c:773 */
int needs_renumber = (ops->n_dylib_inserts > 0) || (nnew - ops->n_dylib_inserts < nold);
```

It stays hand-written, exactly as it is. `nnew` and `nold` come from `mo_map_build` walking *this image* (`src/rewrite.c:768`), so the condition is about what **matched**, not about which operation was asked for. A disturbs mask is a conservative **declaration** about an operation; `needs_renumber` is an exact **observation** about this image. `dylib delete /nonexistent` declares `MREL_ORDINAL` and renumbers nothing, so routing the observation through the declaration would run the pass when nothing matched — a behaviour change bought for uniformity, which is the trade Decision 1 already declined. That is Decision 7 of the spec.

So this step adds `me_followups` and adds no caller that replaces `needs_renumber`. Its two consumers arrive later: the differential harness (Task 4) and the derived gate (Task 6). **Do not** introduce a second kind-testing predicate beside it — a hardcoded test *duplicating* the derivation is the two-lists-disagreeing defect this plan exists to remove; `needs_renumber` is not a duplicate of anything, because no mask can compute it.

- [ ] **Step 4: Run and commit**

```bash
cmake --build /private/tmp/mm-build/schmonz/macho-tools/native
ctest --test-dir /private/tmp/mm-build/schmonz/macho-tools/native
git add src/edit.c tests/edit_test.c
git commit -m "refactor: derive follow-up work from what an operation disturbs"
```

---

### Task 4: The differential harness

Both predicates run side by side, with the spec's expected-difference list asserted. The old predicate stays in control; nothing changes behaviour in this task. This is the task that earns the right to delete `mr_is_rename_only`.

**Files:**
- Create: `tests/rename_only_differential.c`
- Modify: `CMakeLists.txt`
- Modify: `src/rewrite.c` — expose `mr_is_rename_only` to the test (it is `static` at `src/rewrite.c:642` today)

**Interfaces:**
- Consumes: `ms_disturbs`, `me_followups`, `mrel_live`, `mrel_verify_applies`.
- Produces: nothing the shipping code uses. This harness is deleted by Task 7.

- [ ] **Step 1: Write the harness**

For each operation-set shape the suite exercises, compute both answers:

- **old:** `mr_is_rename_only(ops)` — "skip the gate"
- **new:** `!mrel_verify_applies(&im, disturbed)` — "skip the gate" — where `disturbed` is the union of `ms_disturbs` over the shape's statements, plus `MREL_BASE_REL | MREL_FILE_OFF` if the run grew the header

**The "old" column is only defined for four shapes, and the harness must say so.** `mr_is_rename_only` takes an `mr_ops`, and only three `cmd_*` ever build one: `cmd_lc` (`cli/machotool.c:736`), `cmd_dylib_or_rpath` (`:891`) and `cmd_segment` (`:977`), each reaching `mr_apply_file`. So "old" is evaluable for the `lc`, `dylib`, `rpath` and `segment` shapes and for nothing else. `swift-abi set`, `version-min set` and `fixups set classic` never build an `mr_ops` at all — `cmd_minos` (`:660`), `cmd_retag_swift` (`:1027`) and `cmd_declassify` (`:1124`) do not call `mr_apply_file`, and neither does `cmd_grow` (`:583`) — so for those shapes there is no predicate to differ from, and a row claiming "old: runs" would be describing a gate that never ran. Encode that as a third state, not as a guess.

**The "new" column needs an image, and for a fat input it needs a per-slice one.** `mrel_verify_applies` takes a slice (Decision 6). The harness builds one thin image per shape and evaluates against it; where it exercises a fat container it must evaluate once per slice and assert per slice, never once for the container. There is no container-level answer to compare against.

Then assert against the spec's table. Encode it as data, so the list in the test is the list in the spec:

```c
/* The complete expected-difference list from the design (Decision 3), restated
 * against the DERIVATION rather than against mr_process_thin's gate site.
 *
 * `old` has THREE states, not two. mr_is_rename_only takes an mr_ops, and only
 * cmd_lc, cmd_dylib_or_rpath and cmd_segment build one (they are the only three
 * cmd_* that call mr_apply_file). For a shape no verb lowers to an mr_ops there
 * is nothing to compare, and OLD_NA says so instead of inventing "runs".
 *
 * A difference ON this list is expected and asserted. A difference anywhere
 * else FAILS -- that is the whole point of the harness. */
#define OLD_RUNS  0
#define OLD_SKIPS 1
#define OLD_NA    2   /* no mr_ops exists for this shape */

static const struct { const char *shape; int old; int new_skips; } EXPECTED[] = {
    /* --- shapes a verb lowers to an mr_ops: both columns are defined ------ */
    { "segment rename alone",          OLD_SKIPS, 1 },  /* unchanged */
    { "load-command delete alone",     OLD_RUNS,  1 },  /* narrowed */
    { "dylib reexport alone",          OLD_RUNS,  1 },
    { "dylib append alone",            OLD_RUNS,  1 },
    { "dylib replace alone",           OLD_RUNS,  1 },
    { "dylib insert alone",            OLD_RUNS,  1 },
    { "dylib delete alone",            OLD_RUNS,  1 },
    { "rpath append alone",            OLD_RUNS,  1 },
    { "rpath insert alone",            OLD_RUNS,  1 },
    { "rpath replace alone",           OLD_RUNS,  1 },
    { "rpath delete alone",            OLD_RUNS,  1 },
    { "lc delete + dylib delete",      OLD_RUNS,  1 },  /* the union still moves no offset */
    { "segment rename + dylib append", OLD_RUNS,  1 },  /* not rename-only, so old ran */
    { "dylib append that GREW the pad", OLD_RUNS, 0 },  /* a grow disturbs the base */

    /* --- shapes no verb lowers to an mr_ops: "old" is not a thing --------- */
    { "swift-abi set alone",           OLD_NA,    1 },  /* cmd_retag_swift: no mr_ops */
    { "version-min set alone",         OLD_NA,    1 },  /* cmd_minos: no mr_ops */
    { "version-min set that GREW",     OLD_NA,    0 },  /* allow-grow reaches minos */
    { "fixups set classic",            OLD_NA,    0 },  /* cmd_declassify: no mr_ops */
    { "target 10.9 (nothing to do)",   OLD_NA,    1 },  /* empty expansion */
    { "target 10.9 (derives fixups)",  OLD_NA,    0 },  /* the expansion disturbs the base */
};
```

For every `OLD_NA` row the harness asserts **only** the `new_skips` column and asserts that no `mr_ops` is constructed for that shape — it must not call `mr_is_rename_only` on a zeroed `mr_ops` and report the answer as "old", which is the one way this table can lie.

The last two rows are `target 10.9`, whose expansion is image-dependent (`src/edit.c:476-514`), so each needs its own fixture: one image that already targets 10.9 (empty expansion, nothing disturbed) and one carrying `LC_DYLD_CHAINED_FIXUPS` (the expansion derives `fixups set classic`, which disturbs the base). Those two rows are what proves the accumulation, not the declaration, is what the gate reads.

- [ ] **Step 2: Run it**

```bash
cmake --build /private/tmp/mm-build/schmonz/macho-tools/native
ctest --test-dir /private/tmp/mm-build/schmonz/macho-tools/native -R rename_only_differential
```

Expected: passes. **If it does not, stop and report rather than adjusting `EXPECTED` to match what you observed.** The table came from the design; a disagreement means either the model or the design is wrong, and both are decisions above an implementer's pay grade. Adjusting the expectation to fit the output is how a differential test becomes a rubber stamp.

- [ ] **Step 3: Prove the harness can fail**

Add a twenty-first row asserting `{ "segment rename alone", OLD_RUNS, 1 }` — a difference that does not exist, since `mr_is_rename_only` skips exactly that shape. Confirm the harness fails, naming that row. Remove it.

Then run one more mutation, on the `OLD_NA` half, because it is the half a rubber stamp would hide: change `{ "fixups set classic", OLD_NA, 0 }` to `{ "fixups set classic", OLD_NA, 1 }` and confirm the harness fails. If it passes, the harness is not evaluating the `new` column for `OLD_NA` rows at all and the six rows that matter most are decorative. Revert.

Record both mutations and what broke in the task report.

- [ ] **Step 4: Commit**

```bash
git add tests/rename_only_differential.c CMakeLists.txt src/rewrite.c src/rewrite.h
git commit -m "test: prove the derived applicability against mr_is_rename_only"
```

---

### Task 5: Rewrite the scope assertion

`tests/cli_test.sh:2116-2129` asserts `lc -delete uuid` is refused on the implausible fixture, to prove the rename skip is "narrow, not a hole". Task 7 makes that operation skip the gate, so the assertion must move to an operation that genuinely disturbs the relation — **before** Task 7 lands, so the suite is never red.

The exact pieces, measured: the comment at `:2116-2117`, the `cp` at `:2118`, the `if`/`else` at `:2120-2129`, the failure message `"lc -delete uuid was NOT refused, so the gate is gone"` at `:2121`, and the label `"an operation that CAN move an offset still meets the gate"` at `:2124`.

**Files:**
- Modify: `tests/cli_test.sh:2116-2129`

- [ ] **Step 1: Rewrite the case**

Keep the fixture, the structure, and the failure message `"was NOT refused, so the gate is gone"`. Change the operation to one that rebuilds `__LINKEDIT` and re-bases — `fixups set classic` via `machotool edit`, or the `declassify` verb if that is the spelling at the time.

**Do not delete the case.** Its purpose — proving the skip is narrow rather than a hole — is *more* important after Task 7, not less, because the skip gets much wider.

Correct its premise while you are there. The old label reads *"an operation that CAN move an offset still meets the gate"*, and `lc -delete` does not move a section offset: it frees header pad and `mr_build_lcs` repacks the command region. The test passed because the gate ran, not because the premise held. The new comment should say what the new operation actually does and why that makes the claim true this time.

- [ ] **Step 2: Run and commit**

```bash
sh tests/cli_test.sh /private/tmp/mm-build/schmonz/macho-tools/native 2>&1 | tail -1
git add tests/cli_test.sh
git commit -m "test: gate-is-narrow assertion moves to an op that disturbs the relation"
```

---

### Task 6: `edit`'s verify becomes derived, at both of its sites

The spec modelled the gate as one site. At HEAD there are four, and `edit`'s two run `mg_plausible` **unconditionally** — measured: on `tests/mkimplausible.c`'s fixture, `machotool segment f o __DATA __DATA_R9` exits 0 while the identical `segment rename` through `machotool edit` exits 1. Decision 5 rules that the derivation governs `me_run`'s two sites as well as `mr_process_thin`'s, so the verbs keep the exit codes they have today and `edit` stops running a check that has nothing to check.

**This task must land before Task 7.** Task 7 lowers the verbs onto `me_run`; until `edit`'s gate is derived, that lowering imports the unconditional gate into `machotool segment` and `machotool minos` and flips both from 0 to 1 on that fixture, failing `tests/cli_test.sh:2171-2182`'s two assertions.

`mg_grow_header`'s own internal call (`src/grow.c:1432`) is **not in scope and does not move.** A grow disturbs the base-relative relation by definition, so the derivation would run it there anyway.

**What this gives up, stated plainly:** `edit`'s final verify stops being unconditional. `src/edit.c:895-896` says *"Verify the finished image: always, and never subject to `MACHO_NO_VERIFY`"*, and that comment becomes false, so it changes with the code. What survives intact is the property the contract was protecting: **no caller can switch the gate off.** `MACHO_NO_VERIFY` still cannot suppress a verify that applies; what narrows is only *"always"* → *"whenever anything it checks was disturbed"*, and that narrowing is determined by the image and the operations, with no input a caller can supply.

**Files:**
- Modify: `src/edit.c` — `#include "relations.h"` for `MREL_*` and `mrel_verify_applies`; the thin final verify (`:899`) and its comment (`:895-896`); the per-slice verify (`:676`) and its comment (`:674-675`); `me_statements` (`:589`) and `me_target` (`:543`) gain the accumulator
- Modify: `tests/edit_test.c` — five tests pin the unconditional verify, directly or through the report line
- Modify: `CMakeLists.txt` — nothing, if Task 1 already added `src/relations.c` to `machotoolcore` (`:68`). Confirm it did rather than assuming.

**Interfaces:**
- Consumes: `mrel_verify_applies` (Task 1), `ms_disturbs` (Task 2), `me_followups` (Task 3), `me_view` (`src/edit.c:183`), `mg_first_sect_off` (`src/grow.h:93`).
- Produces: no new exported name. `me_statements` and `me_target` each gain one `unsigned *disturbed` in-out parameter; both are `static`.

- [ ] **Step 1: Rewrite the five tests that pin "always", before touching `src/edit.c`**

Three pin the unconditional verify directly; two pin the report line it prints. All five are **rewritten, not deleted** — the same rule Task 5 applies to `cli_test.sh`'s scope assertion.

**(a) `tests/edit_test.c:615`, `test_the_final_verify_ignores_MACHO_NO_VERIFY`.** It runs `segment rename __DATA __DATX` on the `IMPLAUSIBLE` fixture and expects `MR_REFUSED`. A rename disturbs nothing, so after this task that run succeeds — the test would be asserting something false. Rewrite it to pin the surviving property, on an operation for which the claim is true. Keep the name: it is still exactly what the test is about.

```c
/* The final verify has no escape hatch, and that is unchanged. What narrowed
 * is only WHICH runs it applies to: a run that disturbed nothing it checks
 * has nothing to re-decide. MACHO_NO_VERIFY still cannot suppress a verify
 * that applies, and there is no other input a caller can supply that can --
 * the applicability is computed from the image and the operations
 * (mrel_verify_applies). Both halves are pinned here, because the first
 * without the second would be satisfied by a gate that never runs.
 *
 * `fixups set classic` is the operation: on an already-classic image it is a
 * pass-through that changes no byte (see the size assertion in
 * test_the_file_level_operations_run_in_memory), yet it DECLARES
 * MREL_FILE_OFF|MREL_BASE_REL|MREL_HEADER_PAD, because a disturbs mask is a
 * conservative declaration about an operation and not an observation about
 * this image. So the gate applies, and refuses. */
static void test_the_final_verify_ignores_MACHO_NO_VERIFY(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    /* DYLD_INFO so the conversion has something already lowered and passes;
     * IMPLAUSIBLE so the only thing that can refuse is me_run's own verify. */
    uint8_t *img = build_image(IMPLAUSIBLE | DYLD_INFO);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    setenv("MACHO_NO_VERIFY", "1", 1);
    snap before = take(path);
    int rc = run(path, out, "fixups set classic\n");
    unsetenv("MACHO_NO_VERIFY");
    CHECK(rc == MR_REFUSED, "no escape hatch: MACHO_NO_VERIFY=1 does not skip a verify "
          "that applies (got %d; log: %s)", rc, g_log);
    check_untouched("no escape hatch", path, &before);
    CHECK(access(out, F_OK) != 0, "no escape hatch: %s was not created", out);
    CHECK(strstr(g_log, ": verified\n") == NULL,
          "no escape hatch: the log does not claim the image verified (log: %s)", g_log);
    CHECK(strstr(g_log, "refused at verification") != NULL,
          "no escape hatch: the refusal names verification (log: %s)", g_log);

    /* And the other half: the skip is determined by the image and the
     * operations, so MACHO_NO_VERIFY changes NOTHING in either direction. The
     * same fixture, a statement that disturbs nothing, run both ways: same
     * exit code, same OUT, both times. A caller-controlled escape hatch would
     * show up here as a difference. */
    rc = run(path, out, "segment rename __DATA __DATX\n");
    CHECK(rc == 0, "derived skip: a run that disturbs nothing it checks is not "
          "verified and not refused (got %d; log: %s)", rc, g_log);
    CHECK(access(out, F_OK) == 0, "derived skip: OUT was written");
    unlink(out);
    setenv("MACHO_NO_VERIFY", "1", 1);
    int rc2 = run(path, out, "segment rename __DATA __DATX\n");
    unsetenv("MACHO_NO_VERIFY");
    CHECK(rc2 == rc, "not caller-determined: MACHO_NO_VERIFY changes nothing about the "
          "skip (got %d, then %d)", rc, rc2);
    rm_dir();
}
```

**(b) `tests/edit_test.c:590`, `test_an_empty_script_is_refused_sensibly`.** A script of nothing but directives and comments runs no statement, so it disturbs nothing and the gate cannot apply. Its premise is gone, and with it `src/edit.c`'s `s->n == 0` branch (Step 4 deletes that). Rewrite it to pin what is now true, and rename it, updating its call at `tests/edit_test.c:1173`:

```c
/* A script with no statements -- only directives, comments or blank lines --
 * disturbs nothing, so there is nothing for the final verify to re-decide and
 * it does not run. `edit` is not a linter: `machotool verify` is the command
 * that judges an image the caller did not ask to change. The fixture is the
 * IMPLAUSIBLE one precisely so that a gate which DID run would refuse, making
 * this test fail rather than pass vacuously. */
static void test_an_empty_script_disturbs_nothing_and_is_passed_through(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(IMPLAUSIBLE);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    snap before = take(path);
    before.entries++;   /* OUT is the one expected newcomer */
    int rc = run(path, out, "# nothing but a comment\nfatal-warnings\n");
    CHECK(rc == 0, "empty script: a script that disturbs nothing is not verified and "
          "not refused (got %d; log: %s)", rc, g_log);
    check_untouched("empty script: the input", path, &before);
    CHECK(strstr(g_log, "refused at verification") == NULL,
          "empty script: nothing was refused at verification (log: %s)", g_log);
    CHECK(strstr(g_log, "of 0") == NULL,
          "empty script: nothing counts statement 0 of 0 (log: %s)", g_log);
    {
        size_t a = 0, b = 0;
        uint8_t *in = read_file(path, &a), *o = read_file(out, &b);
        CHECK(in && o && a == b && memcmp(in, o, a) == 0,
              "empty script: OUT is byte-identical to the input");
        free(in); free(o);
    }
    rm_dir();
}
```

**(c) `tests/edit_test.c:1003`, `test_fat_a_refusal_in_the_second_slice_writes_nothing`, second half (`:1018-1024`).** It uses `segment rename __DATA __DATX` to reach the per-slice verify, which after this task that statement cannot do. Swap the operation, and correct the paragraph at `:997-1000` of the block comment (`:989-1002`) that explains that route. The first half (`:1010-1016`, `load-command delete uuid`, refused inside the *rewrite's* gate) is **untouched by this task** — Task 7 is what changes it.

```c
    /* Reaching the SLICE's own final verification needs a statement that
     * disturbs something that verify checks: `fixups set classic` declares
     * MREL_BASE_REL, a rename declares nothing. Slice 0 is already classic and
     * plausible, so it passes; slice 1 is already classic and IMPLAUSIBLE, so
     * every statement succeeds and what refuses is that slice's own verify. */
    write_fat(path, DYLD_INFO, IMPLAUSIBLE | DYLD_INFO, 0);
    before = take(path);
    rc = run(path, out, "fixups set classic\n");
    CHECK(rc == MR_REFUSED, "fat: the second slice's own verification refuses the run "
          "(got %d; log: %s)", rc, g_log);
    check_untouched("fat, second slice failed verification", path, &before);
    CHECK(strstr(g_log, "refused at verification of slice arm64") != NULL,
          "fat: the refusal names verification and the slice (log: %s)", g_log);
```

**(d) `tests/edit_test.c:461`, `test_statements_apply_in_order`.** Its script is `load-command delete uuid` + `segment rename`, whose union is `MREL_HEADER_PAD` alone, so its gate now skips and `": verified\n"` is not printed. It asserts report *ordering*, which is still worth pinning, so point it at the line the skip prints (Step 4 defines it):

```c
    const char *first = strstr(g_log, "  load-command delete uuid\n");
    const char *second = strstr(g_log, "  segment rename __DATA __DATX\n");
    /* This script disturbs only the header pad, so the final verify has
     * nothing to re-decide and says so instead of claiming it verified. */
    const char *checked = strstr(g_log, ": nothing this run disturbed is re-checked\n");
    const char *written = strstr(g_log, ": written (");
    CHECK(first && second && first < second,
          "in order: the log names the statements in script order (log: %s)", g_log);
    CHECK(second && checked && second < checked,
          "in order: the verify decision is reported after the last statement (log: %s)", g_log);
    CHECK(checked && written && checked < written,
          "in order: the write is reported after that decision (log: %s)", g_log);
    CHECK(strstr(g_log, ": verified\n") == NULL,
          "in order: the log does not claim a verify that did not run (log: %s)", g_log);
```

**(e) `tests/edit_test.c:1129`, `test_fat_report_accounts_for_every_slice`.** Same cause, per slice: its script is `arch x86_64\nload-command delete uuid`, so replace the `:1138` assertion.

```c
    CHECK(strstr(g_log, "slice x86_64: nothing this run disturbed is re-checked") != NULL,
          "fat, report: the edited slice reports its verify decision (log: %s)", g_log);
```

The report still accounts for every slice, which is what this test is named for.

- [ ] **Step 2: Run and watch the five fail**

```bash
cmake --build /private/tmp/mm-build/schmonz/macho-tools/native
ctest --test-dir /private/tmp/mm-build/schmonz/macho-tools/native -R edit_test --output-on-failure
```

Expected: (a) fails because a rename-only run is still refused, (b) because the empty script is still refused, (c) because `fixups set classic` verifies where the rename used to be the one that reached the slice gate, (d) and (e) because the skip line does not exist yet.

- [ ] **Step 3: Accumulate what the run actually disturbed**

Declared masks are not enough, and the spec says so: *"Applicability is evaluated against what the run did, not only what it declared."* `target 10.9` declares `MREL_NONE` and expands at run time into statements that declare their own (`src/edit.c:476-514`); a header grow disturbs the image base whichever statement asked for it. So the accumulation happens where the statements run, not over `s->stmts`.

Add to `src/edit.c`, above `me_statements`:

```c
/* What one statement actually disturbed: what its row DECLARES, plus what the
 * run is observed to have done. The observation is the first section's file
 * offset -- the header pad's own definition -- because that moving is exactly
 * a grow, and a grow re-bases every base-relative value and moves every
 * __LINKEDIT blob. A declaration alone would miss it; the pad's own bit is
 * not enough, since disturbing the pad and OVERFLOWING it are different
 * events. */
static void me_note_disturbed(unsigned *disturbed, const ms_stmt *st,
                              uint32_t first_before, uint32_t first_after) {
    *disturbed |= ms_disturbs(st->kind, st->op);
    if (first_before != first_after)
        *disturbed |= MREL_BASE_REL | MREL_FILE_OFF;
}
```

`me_statements` takes `unsigned *disturbed` and brackets each statement with it:

```c
        uint32_t first_before = mg_first_sect_off(*pbuf, *psize);
        int rc = stmt->kind == MS_TARGET
            ? me_target(pbuf, psize, path, s, stmt, log, disturbed)
            : me_apply(pbuf, psize, path, s, stmt, log, &v);
        if (rc != 0) {
            /* ... unchanged refusal reporting ... */
        }
        me_note_disturbed(disturbed, stmt, first_before,
                          mg_first_sect_off(*pbuf, *psize));
```

`me_target` takes the same pointer and calls `me_note_disturbed` once per **derived** statement, inside its existing loop over `d[i]`, with the same before/after bracket. That is what makes `target 10.9`'s `MREL_NONE` correct rather than a hole: the row declares nothing of its own, and its expansion declares for itself.

Each of `me_run`'s two paths zeroes one `unsigned disturbed = 0;` and passes its address. A fat container gets **one per slice**, zeroed in `me_fat_slice` before its `me_statements` call — never one shared across the container. That is Decision 6: a slice that disturbed nothing skips its own verify regardless of what its neighbours did.

- [ ] **Step 4: Derive the thin final verify**

Replace `src/edit.c:895-913` — the comment, the call, and the `s->n == 0` branch:

```c
    /* Verify the finished image whenever anything it checks was disturbed, and
     * then never subject to MACHO_NO_VERIFY. The applicability is derived from
     * the relations this image has and what this run was observed to do, so
     * there is no input a CALLER can supply to switch it off -- which is the
     * difference between this and the escape hatch removed during the compat
     * retirement, and the reason the env var is not consulted here.
     * A failure is a refusal -- including an allocation failure inside
     * mg_plausible, which it reports the same way as every other reason it
     * declines (see rewrite.c's comment on that fold).
     * spec: docs/superpowers/specs/2026-09-10-relations-and-verb-lowering-design.md
     * -- Decision 5, the derived applicability governs both front-ends. */
    mi_image vim;
    if (me_view(buf, size, &vim, path, log) != 0) { free(buf); return MR_REFUSED; }
    if (mrel_verify_applies(&vim, disturbed)) {
        if (mg_plausible(buf, size) != 0) {
            me_say(log, "machotool edit: refused at verification, after statement %d of %d; ",
                   s->n, s->n);
            me_say_left(log, path, out);
            free(buf);
            return MR_REFUSED;
        }
        me_say(log, "%s: verified\n", path);
    } else {
        me_say(log, "%s: nothing this run disturbed is re-checked\n", path);
    }
```

Two deletions are deliberate and each has a reason:

- **The `s->n == 0` branch and its "(the script has no statements)" message go.** They are unreachable: a script with no statements runs nothing, so `disturbed` is 0, so the gate cannot apply. A message nothing can produce is worse than no message. Its purpose — never printing "after statement 0 of 0" — is preserved by the branch being gone, and test (b) still asserts `"of 0"` is absent.
- **The report no longer says "verified" when nothing was verified.** That is the repo's own rule about a claim nothing would fail on, applied to a log line. The skip line is what tests (d) and (e) assert.

- [ ] **Step 5: Derive the per-slice verify**

The same change at `src/edit.c:674-681`, against that slice's own `disturbed` and that slice's own image:

```c
    /* Each slice's own verify, on the same derived terms as a thin file's and
     * never subject to MACHO_NO_VERIFY: relations are per SLICE, so a slice
     * that disturbed nothing skips its own verify whatever its neighbours did.
     * spec: docs/superpowers/specs/2026-09-10-relations-and-verb-lowering-design.md
     * -- Decision 6. */
    mi_image sim;
    if (me_view(*pbuf, *psize, &sim, c->path, c->log) != 0) return MR_REFUSED;
    if (mrel_verify_applies(&sim, disturbed)) {
        if (mg_plausible(*pbuf, *psize) != 0) {
            me_say(c->log, "machotool edit: refused at verification of slice %s; ", name);
            me_say_left(c->log, c->path, c->out);
            return MR_REFUSED;
        }
        me_say(c->log, "slice %s: verified\n", name);
    } else {
        me_say(c->log, "slice %s: nothing this run disturbed is re-checked\n", name);
    }
```

The container-level `"%s: verified\n"` at `src/edit.c:812` is **not** this gate — it reports `mfat_parse` revalidating the reassembled container — and does not move.

- [ ] **Step 6: Run everything, and check CI**

```bash
cmake --build /private/tmp/mm-build/schmonz/macho-tools/native
ctest --test-dir /private/tmp/mm-build/schmonz/macho-tools/native
sh tests/cli_test.sh /private/tmp/mm-build/schmonz/macho-tools/native 2>&1 | tail -1
sh tests/known-callers.sh /private/tmp/mm-build/schmonz/macho-tools/native
tests/wrapper_test.sh /private/tmp/mm-build/schmonz/macho-tools/native
sh tests/characterize.sh /private/tmp/mm-build/schmonz/macho-tools/native check
```

`cli_test.sh` and `wrapper_test.sh` must be green **without being edited** in this task: no verb reaches `me_run` yet, so no verb's exit code moves. If either goes red, the accumulator or the gate is reaching the verb path and that is the bug, not the test.

- [ ] **Step 7: Prove the rewritten escape-hatch test can fail**

Reintroduce a caller-controlled escape at the site Step 4 wrote:

```c
    if (mrel_verify_applies(&vim, disturbed) && !getenv("MACHO_NO_VERIFY")) {
```

Confirm test (a)'s first half fails — `MACHO_NO_VERIFY=1` now skips a verify that applies, so `run` returns 0 where it asserted `MR_REFUSED`, and the `access(out)` and `"refused at verification"` assertions fail with it. That is the mutation the rewritten test exists to catch, and it is the one the original test caught too: the property did not change, only its scope. Revert.

Then, separately, make `mrel_verify_applies` return 1 unconditionally and confirm tests (b) and (d) fail — the proof that the skip is real and not just unexercised. Revert.

Record both mutations and what broke in the task report.

- [ ] **Step 8: Commit**

```bash
git add src/edit.c tests/edit_test.c
git commit -m "refactor: edit's verify applies when something it checks was disturbed"
```

```bash
gh run list --repo Mavergreen/macho-tools --limit 3
```

---

### Task 7: Verbs build scripts; `mr_is_rename_only` is deleted

**Files:**
- Modify: `cli/machotool.c` — each `cmd_*` builds an `ms_script` and calls `me_run`
- Modify: `src/rewrite.c` — delete `mr_is_rename_only` and its layout tripwire; the gate's applicability comes from the derivation
- Modify: `tests/cli_test.sh` (`:2204-2223`, `:2232-2240`), `tests/wrapper_test.sh` (`:1180-1184`), `tests/edit_test.c` (`:1010-1016`) — the four remaining `lc -delete uuid`-is-refused premises, per Step 3's table
- Delete: `tests/rename_only_differential.c`; remove its CMake entries
- Modify: `CMakeLists.txt`

**Interfaces:**
- Consumes: everything from Tasks 1–6.

- [ ] **Step 1: Route the verbs**

Each `cmd_*` parses its `argv` into an `ms_script` in memory and calls `me_run`. **Not by generating script text** — round-tripping `argv` through quoting would put a quoting bug on the compat wrappers' path, where today it could only reach `edit`.

**The verbs' `printf` calls do not move.** The wrappers' stdout must stay byte-identical; what changes is how the edit is applied, not how it is described.

- [ ] **Step 2: Run the wrapper gates before anything else**

```bash
cmake --build /private/tmp/mm-build/schmonz/macho-tools/native
sh tests/known-callers.sh /private/tmp/mm-build/schmonz/macho-tools/native
tests/wrapper_test.sh /private/tmp/mm-build/schmonz/macho-tools/native
sh tests/characterize.sh /private/tmp/mm-build/schmonz/macho-tools/native check
```

All four must be green *before* the predicate comes out. If a wrapper's stdout moved, the routing is wrong and deleting the predicate on top of it would confuse two failures.

- [ ] **Step 3: Delete the predicate**

Remove `mr_is_rename_only` (`src/rewrite.c:642-667`) and the `mr_ops_layout_is_still_what_mr_is_rename_only_checks` tripwire that guards it (`src/rewrite.c:639-640`, the typedef spanning two lines) — the tripwire's only purpose was protecting that predicate's conjunction, so it goes with it.

**How the verdict reaches this site — ruled 2026-09-13, see the spec's amendment addendum item 3.** `mr_process_thin` holds an `mr_ops`, not an `ms_script`, so there is no mask lying around for it to read. **Pass the declared mask as a parameter to `mr_apply_image`; do not store it in `mr_ops`.**

The existing signature is at `src/rewrite.h:147-148` — check it before you edit,
it takes an `mr_hits *`, not three `int *`:

```c
/* BEFORE (src/rewrite.h:147-148) */
int mr_apply_image(uint8_t **pbuf, size_t *pfsize, const char *label,
                   const mr_ops *ops, int *out_modified, mr_hits *hits);

/* AFTER -- one added parameter. Every caller must supply it, which is the
 * point: the compiler enforces the coupling the way linkedit.h's link error
 * and MS_TABLE's tripwire enforce theirs. */
int mr_apply_image(uint8_t **pbuf, size_t *pfsize, const char *label,
                   const mr_ops *ops, uint32_t declared_disturbs,
                   int *out_modified, mr_hits *hits);
```

Inside, accumulate rather than trusting the declaration, because applicability is
evaluated against what the run *did*. **A grow is observed, not reported:**
`mg_ensure_pad` (`src/grow.h:122-123`, called at `src/rewrite.c:803`) returns only
success or failure, but it mutates `*pfsize`, so compare across the call:

```c
    uint32_t disturbed = declared_disturbs;
    size_t fsize_before_pad = fsize;
    if (mg_ensure_pad(&buf, &fsize, need_end, ops->allow_grow, label) != 0) {
        /* ... existing failure handling, unchanged ... */
    }
    /* A grow lowers the image base, moving every base-relative value --
     * whichever statement asked for it. platform: mg_ensure_pad reports only
     * pass/fail, so the size change is the only signal that it grew. */
    if (fsize != fsize_before_pad) disturbed |= MREL_BASE_REL;
```

and then, at the gate site (`src/rewrite.c:943-948`, whose guard you are
replacing):

```c
    if (mrel_verify_applies(mrel_live(&im), disturbed) &&
        mg_plausible(buf, fsize) != 0) {
        /* ... existing message, unchanged; note it returns MR_ERROR here ... */
    }
```

Note what left the condition: `!getenv("MACHO_NO_VERIFY")`. It must **stay** —
Decision 5 narrows *when* the gate applies and changes nothing about whether a
caller can suppress one that does.

**One interaction to be aware of, and to report rather than fix.** The two gate
sites disagree about that variable today, and always have: `mr_process_thin`
honours it (the condition above), while `me_run` deliberately ignores it
(`src/edit.c:895-896`, pinned by `tests/edit_test.c:615`). Once Task 7 routes the
verbs through `me_run`, a verb run passes **both** gates, so `MACHO_NO_VERIFY`
will suppress one and not the other — it becomes partially effective rather than
cleanly on or off. That asymmetry is pre-existing, not created here, and
resolving it is a product decision nobody has made. If it produces a surprising
result while you are working, **report it; do not unify the two behaviours on
your own judgement.**

Three reasons this is a parameter and not an `mr_ops` field, and they are the
reasons this item exists: a *derived* value living in a *declaration* struct is
the exact shape that goes stale silently; a parameter makes every caller supply
one at compile time; and the same local accumulation covers the declared and the
observed halves without a second mechanism. Note that adding a field to `mr_ops`
would also have tripped the layout tripwire you are deleting in this very step —
which is not a reason to do it, but is a reason not to do it *quietly*.

`needs_renumber` (`src/rewrite.c:773`) stays exactly as it is — see Task 3 Step 3 and Decision 7. It is not part of this deletion.

**Five assertion blocks go red the moment this site's applicability is derived, and only one of them is Task 5's.** All five turn on `lc -delete uuid` being refused on `mkimplausible`'s fixture, and `load-command delete` disturbs only `MREL_HEADER_PAD`. Measured locations:

| what | where | why it goes red |
|---|---|---|
| the scope assertion | `tests/cli_test.sh:2116-2129` | **Task 5 already rewrote this one** |
| the MR_ERROR fat-slice block | `tests/cli_test.sh:2204-2223` | its `'no known function'` assertion at `:2216` is the per-slice refusal the fat refusal wraps |
| the MR_SKIP/MR_ERROR split | `tests/cli_test.sh:2232-2240` | the same fixture wrapped at `CPU_TYPE_X86`, expecting MR_ERROR |
| `rename_segment`'s narrowness premise | `tests/wrapper_test.sh:1180-1184` | `'no known function'` at `:1182` |
| the fat first-half route | `tests/edit_test.c:1010-1016` | `load-command delete uuid` is expected to be refused *inside the rewrite's own gate*, naming the statement and the slice |

Each needs the same treatment Task 5 gave the first: keep the fixture, the structure and the failure message, and move the operation to one that genuinely disturbs the relation (`fixups set classic`, or a run that grows the header). **Do not delete any of them, and do not add `MACHO_NO_VERIFY` to make them pass** — that would be reintroducing the caller-controlled escape this design distinguishes itself from. Add `tests/cli_test.sh`, `tests/wrapper_test.sh` and `tests/edit_test.c` to this task's Files.

Replace the long comment at `src/rewrite.c:884-942` rather than deleting it. (The `if` it guards is at `:943-948`; the sentence the spec quotes — *"the gate cannot catch anything a rename did; it can only re-decide a property the INPUT already had, and refuse"* — is at `:904-907`, restated at `:933-935`.) It currently explains why a rename-only set skips the gate; the replacement explains the general rule, names the enumerated narrowing, and says plainly what it costs — that `mg_plausible` is defence against rewriter bugs as well as against declared intent, that the case it exists for (`patch_macho`'s chained-fixups conversion, ~94,900 rebases with no self-check of its own) is preserved because that conversion disturbs the relation, and that incidental catches in offset-preserving operations are what is given up.

- [ ] **Step 4: Delete the differential harness**

It has done its job. Leaving it would keep a copy of the deleted predicate alive to compare against, which is the opposite of the point.

- [ ] **Step 5: Run everything**

```bash
ctest --test-dir /private/tmp/mm-build/schmonz/macho-tools/native
sh tests/characterize.sh /private/tmp/mm-build/schmonz/macho-tools/native check
```

The digest must be unmoved: this plan changes which checks run, never what gets written.

- [ ] **Step 6: Commit**

```bash
git add cli/machotool.c src/rewrite.c src/rewrite.h CMakeLists.txt \
    tests/cli_test.sh tests/wrapper_test.sh tests/edit_test.c
git rm tests/rename_only_differential.c
git commit -m "refactor: verbs lower to scripts; applicability is derived, not hand-written"
```

```bash
gh run list --repo Mavergreen/macho-tools --limit 3
```

---

## Self-review

**Spec coverage.** "This mechanism already exists here, twice" → Task 1 Step 4 reuses `mo_is_ordinal_lc` and `linkedit.h`'s list rather than re-listing. "Decision 1: derivation only" → Task 1. "Decision 2: what each operation disturbs" → Task 2, fifteen rows, one assertion per `MS_TABLE` row. "Decision 3" → Tasks 4, 5, 7 in that order: prove, move the assertion, then delete. "Decision 4: verbs build scripts" → Tasks 2 and 7. "Decision 5: the derived applicability governs both front-ends" → Task 6 (`me_run`'s two sites) and Task 7 Step 3 (`mr_process_thin`'s); `src/grow.c:1432` deliberately untouched, and Task 6 says so. "Decision 6: relations are evaluated per slice" → `mrel_verify_applies` takes a slice (Task 1), one accumulator per slice (Task 6 Step 3), the per-slice gate (Task 6 Step 5), and Task 4's per-slice caveat. "Decision 7: `needs_renumber` is not routed through the derivation" → Task 3 Step 3 states the ruling up front, and Task 7 Step 3 restates that it is not part of the deletion. "Decision 8: `target 10.9` declares `MREL_NONE`" → Task 2 Step 1's fifteenth assertion, with the comment saying "nothing of its own", and Task 6 Step 3's per-derived-statement accumulation, which is what makes that true rather than a hole. "The objection this will draw" → Task 7 Step 3's replacement comment and Task 6's Step 4 comment, now load-bearing rather than rhetorical. "Testing" → the differential (Task 4), the declared-disturbs tripwire (Task 2), `known-callers`/`wrapper_test` (Task 6 Step 6 and Task 7 Step 2), `characterize` (Task 7 Step 5).

**Placeholders.** None. Every code step carries its code; the three mutation steps — Task 1 Step 6, Task 4 Step 3 and Task 6 Step 7 — each name two mutations, what to break and what must fail.

**Type consistency.** `mrel_live`, `mrel_name`, `mrel_verify_applies`, `MREL_*`, `ms_disturbs`, `ms_table_row`, `ms_row_disturbs_declared`, `me_followups`, `me_note_disturbed` are spelled identically everywhere they appear. Task 2 widens edit-scripts' `ms_table_row` from **three** out-parameters to **six** (four parameters to seven; `i` is an in-parameter) and says so, with both existing callers — `cli/machotool.c:418` and `tests/script_test.c:338` — updated in the same commit.

**Two ordering constraints, and they are not interchangeable.**

Task 5 must land before Task 7. `cli_test.sh:2116-2129`'s assertion fails the moment the derivation takes over at `mr_process_thin`'s site, and its failure message reads `"the gate is gone"` — which, arriving in the same commit that deletes the predicate, would look exactly like the regression it is not.

Task 6 must also land before Task 7, for a different reason: Task 7 lowers the verbs onto `me_run`, and until `edit`'s gate is derived that import flips `machotool segment` and `machotool minos` from 0 to 1 on `mkimplausible`'s fixture (measured), failing `tests/cli_test.sh:2171-2182`. Task 6 does not depend on Task 5 and Task 5 does not depend on Task 6; both must precede Task 7.

**One thing an implementer of Task 7 should expect and not treat as a surprise.** Deriving `mr_process_thin`'s applicability turns four more assertion blocks red beyond the one Task 5 moved, all of them keyed on `lc -delete uuid` being refused on the implausible fixture. They are enumerated with their measured locations in Task 7 Step 3, and they are rewrites, not deletions.

**One dependency this plan cannot satisfy itself.** Every task consumes `MS_TABLE`, `ms_script` or `me_run` from `plans/2026-09-10-edit-scripts.md`. Starting before that plan merges is not slow, it is impossible.
