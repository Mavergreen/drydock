# `dylib retype`, `imports`, and an `insert_dylib` wrapper — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `dylib retype PATH KIND` statement, a read-only `machorewrite imports FILE` verb, and a `compat/insert_dylib.sh` wrapper presenting `Wowfunhappy/insert_dylib`'s command line over them.

**Architecture:** `retype` generalizes the existing one-way `dylib reexport`, which already rewrites a dylib load command's `cmd` field. `imports` reuses `src/ordinals.c`'s bind-opcode walker by making it observable, rather than growing a second walk that could disagree with the first. The wrapper is the seventh in `compat/`, with its grammar in `compat/translate.sh` like the other six.

**Tech Stack:** C99, `/bin/sh`, CMake + CTest, shipyard's cross toolchain. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-20-insert-dylib-retype-imports-design.md`

## Global Constraints

- **Deployment floor is macOS 10.9.5**, x86_64. 64-bit Mach-O only; 32-bit stays refused.
- **`machorewrite` never writes its input.** Every mutating form takes `FILE OUT` and refuses an `OUT` equal to `FILE`.
- **The bare `FILE OUT` form takes no flags.** Do not add any. `imports` takes no flags either.
- **Exit codes:** `ok=0`, `EX_REFUSED=1`, `EX_FAIL=2`. `imports` uses `EX_REFUSED` for anything it declines.
- **Do not add a `spec:` comment tag** citing this plan or its spec. Queue item 7 is removing the tag and the 25 existing citations. Where a comment needs a reason, state the reason.
- **Prefer a test to a comment.** This repo treats a comment that claims more than the code does as a defect. Comment density in `compat/` is a known problem; do not add to it.
- **`tests/EXPECTED` must not move.** `tests/characterize.sh` hashes a fixed pipeline's output bytes. Nothing in this plan changes that pipeline. If the digest moves, you broke something — do not re-record it.
- **Commit messages** end with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

---

## File Structure

| file | responsibility | task |
|---|---|---|
| `src/ordinals.h` / `.c` | gains the kind-name table (`mo_kind_from_name`, `mo_kind_name`) beside `mo_is_ordinal_lc`, so "which kinds bear ordinals" has one home | 1 |
| `src/script.h` / `.c` | `MS_RETYPE` op, the `dylib retype` table row, KIND validation at parse time | 2 |
| `src/rewrite.h` / `.c` | `mr_change.reexport` becomes `mr_change.retype_to` | 3 |
| `src/edit.c` | lowers `MS_RETYPE`; `MS_REEXPORT` keeps working through the same field | 3 |
| `cli/machorewrite.c` | `--capabilities` advertises the kinds; the `imports` verb dispatches | 4, 6 |
| `src/imports.h` / `.c` | **new** — walks an image's bind streams and reports rows | 5, 6 |
| `compat/translate.sh` | `insert_dylib` flag grammar | 7 |
| `compat/insert_dylib.sh` | **new** — the wrapper | 7 |
| `tests/insert_dylib_test.sh` | **new** — wrapper behaviour + pinned-fork differential | 8 |

---

### Task 1: One home for the dylib kind names

`mo_is_ordinal_lc` already decides which four dylib load commands bear an ordinal. The name↔constant mapping belongs beside it so a second list cannot drift from the first — the mistake `ordinals.h`'s own header describes.

**Files:**
- Modify: `src/ordinals.h` (after `mo_is_ordinal_lc`'s declaration, ~line 71)
- Modify: `src/ordinals.c` (after `mo_is_ordinal_lc`'s definition, ~line 14)
- Test: `tests/relations_test.c` (it already links `machorewritecore` and tests small pure predicates)

**Interfaces:**
- Consumes: nothing.
- Produces: `uint32_t mo_kind_from_name(const char *name)` → the `LC_*` constant, or `0` when `name` is not one of the four. `const char *mo_kind_name(uint32_t cmd)` → `"load"`/`"weak"`/`"reexport"`/`"upward"`, or `NULL`.

- [ ] **Step 1: Write the failing test**

Append to `tests/relations_test.c`, and add `test_dylib_kind_names();` to its `main`:

```c
static void test_dylib_kind_names(void) {
    static const char *names[] = { "load", "weak", "reexport", "upward" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        uint32_t cmd = mo_kind_from_name(names[i]);
        CHECK(cmd != 0, "mo_kind_from_name(%s) returned 0", names[i]);
        CHECK(mo_is_ordinal_lc(cmd), "%s is not ordinal-bearing", names[i]);
        CHECK(mo_kind_name(cmd) && strcmp(mo_kind_name(cmd), names[i]) == 0,
              "%s did not round-trip", names[i]);
    }
    /* mo_map_build refuses an image carrying LC_LAZY_LOAD_DYLIB because its
     * ordinal slotting has never been exercised. Accepting it here would let
     * `dylib retype` emit images this tool's own verbs refuse. */
    CHECK(mo_kind_from_name("lazy") == 0, "lazy was accepted as a kind");
    CHECK(mo_kind_name(LC_LAZY_LOAD_DYLIB) == NULL, "lazy was named");
    CHECK(mo_kind_from_name("") == 0, "empty string was accepted");
    CHECK(mo_kind_from_name("LOAD") == 0, "kind names are not case-folded");
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
shipyard-cmake --preset native-local && shipyard-cmake --build --preset native-local
ctest --test-dir build-native -R relations_test --output-on-failure
```
Expected: build failure — `mo_kind_from_name` undeclared.

- [ ] **Step 3: Implement**

In `src/ordinals.h`, immediately after `int mo_is_ordinal_lc(uint32_t cmd);`:

```c
/* The four kinds mo_is_ordinal_lc counts, by the name a `dylib retype`
 * statement spells them with. LC_LAZY_LOAD_DYLIB is deliberately absent: see
 * mo_map_build, which refuses an image carrying one. */
uint32_t mo_kind_from_name(const char *name);
const char *mo_kind_name(uint32_t cmd);
```

In `src/ordinals.c`, after `mo_is_ordinal_lc`:

```c
static const struct { const char *name; uint32_t cmd; } MO_KINDS[] = {
    { "load",     LC_LOAD_DYLIB },
    { "weak",     LC_LOAD_WEAK_DYLIB },
    { "reexport", LC_REEXPORT_DYLIB },
    { "upward",   LC_LOAD_UPWARD_DYLIB },
};

uint32_t mo_kind_from_name(const char *name) {
    if (!name) return 0;
    for (size_t i = 0; i < sizeof MO_KINDS / sizeof MO_KINDS[0]; i++)
        if (strcmp(name, MO_KINDS[i].name) == 0) return MO_KINDS[i].cmd;
    return 0;
}

const char *mo_kind_name(uint32_t cmd) {
    for (size_t i = 0; i < sizeof MO_KINDS / sizeof MO_KINDS[0]; i++)
        if (cmd == MO_KINDS[i].cmd) return MO_KINDS[i].name;
    return NULL;
}
```

Add `#include <string.h>` to `src/ordinals.c` if it is not already there.

- [ ] **Step 4: Run it and watch it pass**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native -R relations_test --output-on-failure
```
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add src/ordinals.h src/ordinals.c tests/relations_test.c
git commit -m "feat(ordinals): name the four ordinal-bearing dylib kinds in one place"
```

---

### Task 2: `dylib retype PATH KIND` parses

**Files:**
- Modify: `src/script.h` (op enum, ~line 41)
- Modify: `src/script.c` (`MS_TABLE_ROWS`, ~line 117; operand validation in `ms_parse`)
- Test: `tests/script_test.c`

**Interfaces:**
- Consumes: `mo_kind_from_name` (Task 1).
- Produces: `MS_RETYPE` op constant; a parsed `ms_stmt` with `.kind == MS_DYLIB`, `.op == MS_RETYPE`, `.a == PATH`, `.b == KIND`.

- [ ] **Step 1: Write the failing test**

Append to `tests/script_test.c`, and call it from `main`:

```c
static void test_dylib_retype(void) {
    ms_script s; char err[256] = {0};
    const char *ok = "dylib retype /usr/lib/libfoo.dylib weak\n";
    CHECK(ms_parse(ok, strlen(ok), &s, err, sizeof err) == 0,
          "retype rejected: %s", err);
    CHECK(s.n == 1, "wanted 1 statement, got %d", s.n);
    CHECK(s.stmts[0].kind == MS_DYLIB && s.stmts[0].op == MS_RETYPE,
          "wrong kind/op");
    CHECK(strcmp(s.stmts[0].a, "/usr/lib/libfoo.dylib") == 0, "wrong path");
    CHECK(strcmp(s.stmts[0].b, "weak") == 0, "wrong kind operand");
    ms_free(&s);

    /* Each of the four is accepted. */
    const char *kinds[] = { "load", "weak", "reexport", "upward" };
    for (size_t i = 0; i < 4; i++) {
        char line[128];
        snprintf(line, sizeof line, "dylib retype /x %s\n", kinds[i]);
        err[0] = 0;
        CHECK(ms_parse(line, strlen(line), &s, err, sizeof err) == 0,
              "%s rejected: %s", kinds[i], err);
        ms_free(&s);
    }

    /* lazy is refused BY NAME, and the message says why. */
    const char *lazy = "dylib retype /x lazy\n";
    err[0] = 0;
    CHECK(ms_parse(lazy, strlen(lazy), &s, err, sizeof err) == -1,
          "lazy was accepted");
    CHECK(strstr(err, "lazy") != NULL, "message does not name lazy: %s", err);
    CHECK(strstr(err, "line 1") != NULL, "message does not name the line: %s", err);

    /* An unknown kind is refused and the message lists what is accepted. */
    const char *bogus = "dylib retype /x sideways\n";
    err[0] = 0;
    CHECK(ms_parse(bogus, strlen(bogus), &s, err, sizeof err) == -1,
          "unknown kind accepted");
    CHECK(strstr(err, "upward") != NULL, "message does not list the kinds: %s", err);

    /* Arity is two. */
    const char *short_form = "dylib retype /x\n";
    err[0] = 0;
    CHECK(ms_parse(short_form, strlen(short_form), &s, err, sizeof err) == -1,
          "one-operand retype accepted");

    /* rpath has no retype: it bears no cmd kind to change. */
    const char *rp = "rpath retype /x weak\n";
    err[0] = 0;
    CHECK(ms_parse(rp, strlen(rp), &s, err, sizeof err) == -1,
          "rpath retype accepted");
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native -R script_test --output-on-failure
```
Expected: build failure — `MS_RETYPE` undeclared.

- [ ] **Step 3: Implement**

In `src/script.h`, extend the op enum (append; do not renumber existing values):

```c
enum { MS_DELETE, MS_RENAME, MS_SET, MS_REPLACE, MS_APPEND,
       MS_INSERT, MS_REEXPORT, MS_PROFILE_10_9, MS_RETYPE };
```

In `src/script.c`, add a row to `MS_TABLE_ROWS` immediately after the `reexport` row. `flag`/`modes`/`ops_ord` are vestigial (see `src/script.h`'s note) — a new row carries nothing rather than inventing values for a verb grammar that no longer exists:

```c
  R("dylib",        MS_DYLIB,        "retype",   MS_RETYPE,       2, NULL,        0,             0, MREL_NONE) \
```

Add `#include "ordinals.h"` to `src/script.c`, and validate the KIND operand where `ms_parse` already validates `version-min set`'s operand:

```c
if (MS_TABLE[found].k == MS_DYLIB && MS_TABLE[found].o == MS_RETYPE &&
    mo_kind_from_name(fields[3]) == 0) {
    if (strcmp(fields[3], "lazy") == 0)
        snprintf(err, errsz,
                 "line %d: dylib retype: 'lazy' is not a retype target -- an "
                 "image carrying LC_LAZY_LOAD_DYLIB is refused, because whether "
                 "it takes a slot in the ordinal sequence has never been "
                 "established", lineno);
    else
        snprintf(err, errsz,
                 "line %d: dylib retype: unknown kind '%s'; accepted: load, "
                 "weak, reexport, upward", lineno, fields[3]);
    goto fail;
}
```

Match the surrounding code's spelling of `lineno`, the error buffer and the failure path — read the `version-min` validation immediately above and follow it exactly rather than assuming these names.

- [ ] **Step 4: Run it and watch it pass**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native -R script_test --output-on-failure
```
Expected: PASS.

- [ ] **Step 5: Commit**

```sh
git add src/script.h src/script.c tests/script_test.c
git commit -m "feat(script): parse dylib retype PATH KIND, refusing lazy by name"
```

---

### Task 3: `dylib retype` rewrites the load command

`src/rewrite.c` already writes `ndc->cmd = LC_REEXPORT_DYLIB` when `mr_change.reexport` is set. Generalize that field; `reexport` becomes one value it can hold.

**Files:**
- Modify: `src/rewrite.h` (the `mr_change` struct, ~line 20)
- Modify: `src/rewrite.c` (the promotion site, ~line 332)
- Modify: `src/edit.c` (the `MS_DYLIB`/`MS_RPATH` lowering, ~line 290)
- Test: `tests/cli_test.sh`

**Interfaces:**
- Consumes: `MS_RETYPE` (Task 2), `mo_kind_from_name`/`mo_kind_name` (Task 1).
- Produces: `mr_change.retype_to` — a `uint32_t` `LC_*` constant, `0` for "no retype". Replaces `mr_change.reexport`.

- [ ] **Step 1: Write the failing test**

Add to `tests/cli_test.sh`, following the file's existing case style (read a neighbouring case and match its helper names and output conventions):

```sh
# dylib retype: every direction, and the byte count never moves.
for k in weak reexport upward load; do
    before=$(wc -c < "$T/in")
    printf 'dylib retype /usr/lib/libSystem.B.dylib %s\n' "$k" \
        | "$BIN/machorewrite" "$T/in" "$T/out.$k" 2>/dev/null
    check_rc 0 "retype to $k"
    after=$(wc -c < "$T/out.$k")
    [ "$before" = "$after" ] \
        || fail "retype to $k changed the file size: $before -> $after"
    "$BIN/machorewrite" verify "$T/out.$k" >/dev/null 2>&1 \
        || fail "retype to $k produced an image verify refuses"
done

# Round trip: weak then load is the original bytes, byte for byte.
printf 'dylib retype /usr/lib/libSystem.B.dylib weak\n' \
    | "$BIN/machorewrite" "$T/in" "$T/w1" 2>/dev/null
printf 'dylib retype /usr/lib/libSystem.B.dylib load\n' \
    | "$BIN/machorewrite" "$T/w1" "$T/w2" 2>/dev/null
cmp -s "$T/in" "$T/w2" \
    || fail "retype weak then load did not round-trip to the original bytes"

# `dylib reexport PATH` still means what it always meant.
printf 'dylib reexport /usr/lib/libSystem.B.dylib\n' \
    | "$BIN/machorewrite" "$T/in" "$T/r1" 2>/dev/null
printf 'dylib retype /usr/lib/libSystem.B.dylib reexport\n' \
    | "$BIN/machorewrite" "$T/in" "$T/r2" 2>/dev/null
cmp -s "$T/r1" "$T/r2" \
    || fail "dylib reexport and dylib retype ... reexport disagree"

# A path that is not present is a miss, not a silent success.
printf 'dylib retype /nope.dylib weak\n' \
    | "$BIN/machorewrite" "$T/in" "$T/miss" 2>"$T/miss.err"
grep -q 'matched nothing' "$T/miss.err" \
    || fail "retype of an absent path did not report a miss"
```

- [ ] **Step 2: Run it and watch it fail**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native -R cli_test --output-on-failure
```
Expected: FAIL — `dylib retype` reaches `edit.c`'s `unknown` arm.

- [ ] **Step 3: Implement**

In `src/rewrite.h`, replace the `reexport` field. Update the struct's own comment so it describes what the field now does:

```c
/* One dylib-path (or rpath) operation. new_path == NULL deletes the command
 * naming old_path; "" leaves the path alone; anything else rewrites it,
 * growing the command if the longer string needs it. `retype_to` is an LC_*
 * constant to rewrite the command's kind to (what "" is for), or 0 to leave
 * the kind alone; never set for an rpath. */
typedef struct {
    const char *old_path;
    const char *new_path;
    uint32_t    retype_to;       /* always 0 for an rpath change */
} mr_change;
```

In `src/rewrite.c`, at the promotion site:

```c
            if (ctx->ops->dylib_change->retype_to) {
                ndc->cmd = ctx->ops->dylib_change->retype_to;
                if (ctx->verbose)
                    printf("  Retype: %s -> %s\n",
                           ctx->ops->dylib_change->old_path,
                           mo_kind_name(ctx->ops->dylib_change->retype_to));
            }
```

In `src/edit.c`, in the `MS_DYLIB`/`MS_RPATH` switch:

```c
        case MS_REEXPORT: if (rpath) goto unknown;
                          change.old_path = st->a; change.new_path = "";
                          change.retype_to = LC_REEXPORT_DYLIB; break;
        case MS_RETYPE:   if (rpath) goto unknown;
                          change.old_path = st->a; change.new_path = "";
                          change.retype_to = mo_kind_from_name(st->b);
                          break;
```

`ms_parse` has already refused any KIND `mo_kind_from_name` would answer 0 for, so this cannot store 0 — but do not add a comment saying so. Add a test instead, in `tests/edit_test.c`, that calls the lowering with each kind and asserts `retype_to` is non-zero.

Then grep for every other reader of the old field name and update it:

```sh
git grep -n 'reexport' -- src cli compat tests
```

- [ ] **Step 4: Run the whole suite**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native --output-on-failure
```
Expected: all tests pass, **including `characterize`** — if `tests/EXPECTED` moved, stop and find out why.

- [ ] **Step 5: Commit**

```sh
git add src/rewrite.h src/rewrite.c src/edit.c tests/cli_test.sh tests/edit_test.c
git commit -m "feat(dylib): retype a dylib load command to any ordinal-bearing kind"
```

---

### Task 4: `--capabilities` advertises the kinds

A wrapper must discover the accepted KIND set rather than hard-code it.

**Files:**
- Modify: `cli/machorewrite.c` (`print_capabilities`)
- Test: `tests/cli_test.sh`

**Interfaces:**
- Consumes: `mo_kind_name` (Task 1).
- Produces: a `dylib-kinds load weak reexport upward` line in `--capabilities` output.

- [ ] **Step 1: Write the failing test**

```sh
"$BIN/machorewrite" --capabilities > "$T/caps"
grep -q '^statement dylib retype 2$' "$T/caps" \
    || fail "--capabilities does not advertise dylib retype"
grep -q '^dylib-kinds load weak reexport upward$' "$T/caps" \
    || fail "--capabilities does not advertise the retype kinds"
grep -q 'lazy' "$T/caps" \
    && fail "--capabilities advertises lazy as a kind"
```

- [ ] **Step 2: Run it and watch it fail**

```sh
ctest --test-dir build-native -R cli_test --output-on-failure
```
Expected: FAIL on the `dylib-kinds` line. The `statement dylib retype 2` line should already pass — it is generated from `MS_TABLE`.

- [ ] **Step 3: Implement**

In `print_capabilities`, after the `verb` lines:

```c
    {
        static const uint32_t kinds[] = { LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB,
                                          LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB };
        size_t i;
        printf("dylib-kinds");
        for (i = 0; i < sizeof kinds / sizeof kinds[0]; i++)
            printf(" %s", mo_kind_name(kinds[i]));
        printf("\n");
    }
```

- [ ] **Step 4: Run it and watch it pass**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native -R cli_test --output-on-failure
```

- [ ] **Step 5: Commit**

```sh
git add cli/machorewrite.c tests/cli_test.sh
git commit -m "feat(cli): advertise the retype kinds in --capabilities"
```

---

### Task 5: The bind walker becomes observable

`mo_bind_stream` decodes every bind opcode in order to renumber. The reporter needs the same decode to observe. One walk, two consumers — the argument `ordinals.h` already makes about `mo_map_build`.

**Files:**
- Modify: `src/ordinals.h` (declare the observer types)
- Modify: `src/ordinals.c` (`mo_bind_stream`, ~line 160)
- Test: `tests/relations_test.c`

**Interfaces:**
- Consumes: nothing.
- Produces:

```c
enum { MO_ORD_SELF = -1, MO_ORD_EXE = -2, MO_ORD_FLAT = -3 };

typedef struct {
    int         ordinal;   /* >= 1, or one of MO_ORD_* */
    const char *symbol;    /* the current trailing-flags symbol, or NULL */
    int         weak;      /* the current symbol's WEAK_IMPORT flag */
} mo_bind_state;

typedef void (*mo_bind_obs)(const mo_bind_state *st, void *ctx);

int mo_bind_walk(uint8_t *base, uint32_t size, const int *map, int nold,
                 const char *what, long *changed,
                 mo_bind_obs obs, void *ctx);
```

`map == NULL` means observe only: the walk writes nothing. `obs == NULL` means renumber only. `mo_bind_stream` becomes a thin call into this with `obs = NULL`.

- [ ] **Step 1: Write the failing test**

Append to `tests/relations_test.c`. Build the stream by hand so the test owns its ground truth and needs no fixture:

```c
struct seen { int n; int ord[8]; char sym[8][32]; int weak[8]; };

static void note(const mo_bind_state *st, void *ctx) {
    struct seen *s = ctx;
    if (s->n >= 8) return;
    s->ord[s->n] = st->ordinal;
    s->weak[s->n] = st->weak;
    snprintf(s->sym[s->n], sizeof s->sym[0], "%s", st->symbol ? st->symbol : "");
    s->n++;
}

static void test_bind_walk_observes(void) {
    uint8_t stream[] = {
        BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | 2,
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | BIND_SYMBOL_FLAGS_WEAK_IMPORT,
        '_','N','S','B','e','e','p','\0',
        BIND_OPCODE_SET_TYPE_IMM | BIND_TYPE_POINTER,
        BIND_OPCODE_DO_BIND,
        BIND_OPCODE_SET_DYLIB_SPECIAL_IMM | (BIND_SPECIAL_DYLIB_FLAT_LOOKUP & BIND_IMMEDIATE_MASK),
        BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0,
        '_','m','e','m','c','p','y','\0',
        BIND_OPCODE_DO_BIND,
        BIND_OPCODE_DONE,
    };
    uint8_t copy[sizeof stream];
    memcpy(copy, stream, sizeof stream);

    struct seen s = {0};
    int rc = mo_bind_walk(copy, (uint32_t)sizeof copy, NULL, 0, "test", NULL,
                          note, &s);
    CHECK(rc == 0, "observe-only walk returned %d", rc);
    CHECK(s.n == 2, "saw %d binds, wanted 2", s.n);
    CHECK(s.ord[0] == 2, "first ordinal %d, wanted 2", s.ord[0]);
    CHECK(strcmp(s.sym[0], "_NSBeep") == 0, "first symbol '%s'", s.sym[0]);
    CHECK(s.weak[0] == 1, "first bind not reported weak");
    CHECK(s.ord[1] == MO_ORD_FLAT, "second ordinal %d, wanted FLAT", s.ord[1]);
    CHECK(strcmp(s.sym[1], "_memcpy") == 0, "second symbol '%s'", s.sym[1]);
    CHECK(s.weak[1] == 0, "second bind reported weak");

    /* An observe-only walk writes NOTHING. This is the invariant that lets the
     * reporter share the renumberer's decoder. */
    CHECK(memcmp(copy, stream, sizeof stream) == 0,
          "observe-only walk modified the stream");
}
```

- [ ] **Step 2: Run it and watch it fail**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native -R relations_test --output-on-failure
```
Expected: build failure — `mo_bind_walk` undeclared.

- [ ] **Step 3: Implement**

Rename `mo_bind_stream` to `mo_bind_walk`, add the two new parameters, and make it non-static (declare it in `ordinals.h` with the types above).

Inside the loop, maintain an `mo_bind_state st = { 0, NULL, 0 };`:

- `BIND_OPCODE_SET_DYLIB_ORDINAL_IMM` / `_ULEB`: set `st.ordinal` to the value **after** any renumbering.
- `BIND_OPCODE_SET_DYLIB_SPECIAL_IMM`: sign-extend `imm` from 4 bits and map `0`→`MO_ORD_SELF`, `-1`→`MO_ORD_EXE`, `-2`→`MO_ORD_FLAT`.
- `BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM`: set `st.symbol` to the name, and `st.weak = (imm & BIND_SYMBOL_FLAGS_WEAK_IMPORT) != 0`.
- `BIND_OPCODE_DO_BIND`, `DO_BIND_ADD_ADDR_ULEB`, `DO_BIND_ADD_ADDR_IMM_SCALED`, `DO_BIND_ULEB_TIMES_SKIPPING_ULEB`: if `obs`, call `obs(&st, ctx)`.

Guard every renumbering write with `if (map)`. Leave the existing refusals (unknown opcode, ordinal out of range, ordinal no longer fits) exactly as they are — but an out-of-range check that reads `nold` must not fire when `map == NULL`, since an observe-only walk has no map to be out of range of.

- [ ] **Step 4: Run the whole suite**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native --output-on-failure
```
Expected: all pass. The renumbering tests are the regression surface here — if `change_dylib_test` or `cli_test` fails, the refactor changed behaviour.

- [ ] **Step 5: Commit**

```sh
git add src/ordinals.h src/ordinals.c tests/relations_test.c
git commit -m "refactor(ordinals): one bind decoder, for the renumberer and an observer"
```

---

### Task 6: `machorewrite imports FILE`

**Files:**
- Create: `src/imports.h`, `src/imports.c`
- Modify: `cli/machorewrite.c` (dispatch, `usage`, `--capabilities`, and the "two surviving verb words" comment — it becomes three)
- Modify: `CMakeLists.txt` (add `src/imports.c` to `machorewritecore`)
- Test: `tests/cli_test.sh`

**Interfaces:**
- Consumes: `mo_bind_walk`, `MO_ORD_*`, `mo_kind_name` (Tasks 1, 5); `mi_open`/`mi_each_lc`/`mi_close` (`src/image.h`); `mfat_parse`/`mfat_get` (`src/fat.h`).
- Produces:

```c
#define MIMP_OK        0
#define MIMP_REFUSED (-1)   /* chained fixups, or not a readable 64-bit Mach-O */

typedef struct {
    const char *arch;          /* slice arch name; "-" for a thin image */
    int         ordinal;       /* >= 1, or an MO_ORD_* value */
    const char *kind;          /* "load"/"weak"/..., or "-" for a special ordinal */
    const char *install_name;  /* or "-" for a special ordinal */
    const char *symbol;
    int         weak;
} mimp_row;

typedef void (*mimp_row_fn)(const mimp_row *row, void *ctx);

int mimp_report(uint8_t *buf, size_t size, mimp_row_fn fn, void *ctx);
```

`buf` is **not** `const`, deliberately: `mo_bind_walk` takes `uint8_t *` because
its other caller renumbers in place. Rather than cast a `const` away here — the
kind of cast nobody revisits — the parameter is honest about the type it
forwards, and Task 5's observe-only test is what establishes the buffer is not
written.

`mimp_report` handles both thin images and fat containers, emitting one row set per 64-bit slice. A slice it cannot read is skipped, matching `fix_macho`'s standing "skip this arch" convention — not refused, because one unreadable slice in a container should not suppress the readable ones.

- [ ] **Step 1: Write the failing test**

Add to `tests/cli_test.sh`:

```sh
"$BIN/machorewrite" imports "$T/in" > "$T/imp" 2>"$T/imp.err"
check_rc 0 "imports on the fixture"

# The header row is the contract. Columns may be APPENDED; never reordered,
# renamed or removed.
head -1 "$T/imp" | grep -q '^arch	ordinal	kind	install_name	symbol	weak$' \
    || fail "imports header row changed: $(head -1 "$T/imp")"

# A consumer selects by NAME, not position. This is the test that fails if
# anyone reorders the columns later.
sym=$(awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)c[$i]=i} NR==2{print $c["symbol"]}' "$T/imp")
[ -n "$sym" ] || fail "no symbol in the first data row"

# Every data row has exactly as many fields as the header.
awk -F'\t' 'NR==1{n=NF} NF!=n{print NR; exit 1}' "$T/imp" \
    || fail "imports emitted a ragged row"

# Deterministic: same input, same bytes.
"$BIN/machorewrite" imports "$T/in" > "$T/imp2" 2>/dev/null
cmp -s "$T/imp" "$T/imp2" || fail "imports is not deterministic"

# Not a Mach-O is a refusal, not a crash or an empty success.
"$BIN/machorewrite" imports "$HERE/not-a-macho.txt" >/dev/null 2>&1
check_rc 1 "imports refuses a non-Mach-O"

# A chained-fixups image is refused BY NAME and points somewhere useful.
"$BIN/mkchained" "$T/chained" 2>/dev/null
"$BIN/machorewrite" imports "$T/chained" >/dev/null 2>"$T/ch.err"
check_rc 1 "imports refuses a chained-fixups image"
grep -q 'fixups set' "$T/ch.err" \
    || fail "the chained refusal does not name the remedy: $(cat "$T/ch.err")"

# An image with no bind stream at all is a SUCCESSFUL report of zero rows --
# header line present, exit 0. Not a refusal, and not empty output.
#
# Build the fixture by deleting the dyld-info load command from $T/in. Get the
# statement's exact spelling from `machorewrite --capabilities | grep '^statement
# load-command'` -- do NOT guess it. If no statement can remove it, build the
# fixture in C beside tests/mkimplausible.c instead. Either way this case must
# exist: "no imports" and "refused to look" are the two outcomes a consumer most
# needs told apart, and they are one exit code away from each other.
"$BIN/machorewrite" imports "$T/nobind" > "$T/nb.out" 2>/dev/null
check_rc 0 "imports on an image with no bind stream"
[ "$(wc -l < "$T/nb.out" | tr -d ' ')" = 1 ] \
    || fail "wanted the header row alone, got $(wc -l < "$T/nb.out") lines"

# A fat container reports every 64-bit slice, and the arch column distinguishes them.
"$BIN/makefat" "$T/fat" "$T/in" "$T/in" 2>/dev/null
"$BIN/machorewrite" imports "$T/fat" > "$T/fatimp" 2>/dev/null
check_rc 0 "imports on a fat container"
narch=$(awk -F'\t' 'NR>1{print $1}' "$T/fatimp" | sort -u | wc -l | tr -d ' ')
[ "$narch" -ge 1 ] || fail "fat imports named no arch"
```

Read `tests/cli_test.sh`'s existing cases for the real names of `check_rc`, `fail`, `$T`, `$HERE` and the fixture builders, and match them. `mkchained` and `makefat` are existing test helpers — confirm their argument order before use.

- [ ] **Step 2: Run it and watch it fail**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native -R cli_test --output-on-failure
```
Expected: FAIL — `machorewrite: unknown verb 'imports'`.

- [ ] **Step 3: Implement**

`src/imports.c`:
1. `mfat_parse` the buffer. If it is fat, loop slices with `mfat_get` and recurse into each 64-bit slice with its arch name from `src/arch_names.h`; otherwise treat the whole buffer as one slice with arch `"-"`.
2. Per slice: walk load commands. Build an ordinal→(install_name, kind) table exactly as `mo_map_build` walks it — every command `mo_is_ordinal_lc` counts, in load-command order, 1-based.
3. Find `LC_DYLD_INFO` or `LC_DYLD_INFO_ONLY`. If the slice has `LC_DYLD_CHAINED_FIXUPS` instead, return `MIMP_REFUSED`.
4. Call `mo_bind_walk` with `map = NULL` over each of `bind_off/bind_size`, `weak_bind_off/weak_bind_size` and `lazy_bind_off/lazy_bind_size`, with an observer that fills an `mimp_row` and calls `fn`.
5. Bounds-check every offset/size pair against the slice before walking — `mo_fits(off, len, size)` already exists at `src/ordinals.c:254`; export it rather than writing a second one.

The per-slice core, concretely:

```c
struct slice_ctx {
    const char  *arch;
    const char  *names[MO_MAX_DYLIBS + 1];   /* install_name at ordinal i */
    uint32_t     cmds[MO_MAX_DYLIBS + 1];    /* LC_* kind at ordinal i */
    int          n;                          /* ordinals seen: 1..n */
    mimp_row_fn  fn;
    void        *ctx;
};

static int collect_lc(const struct load_command *lc, void *vctx) {
    struct slice_ctx *s = vctx;
    if (mo_is_ordinal_lc(lc->cmd) && s->n < MO_MAX_DYLIBS) {
        const struct dylib_command *dc = (const struct dylib_command *)lc;
        s->n++;
        s->names[s->n] = mo_lc_str_at(lc, dc->dylib.name.offset);
        s->cmds[s->n]  = lc->cmd;
    }
    return 0;
}

static void emit(const mo_bind_state *st, void *vctx) {
    struct slice_ctx *s = vctx;
    mimp_row row;
    row.arch   = s->arch;
    row.symbol = st->symbol ? st->symbol : "-";
    row.weak   = st->weak;
    row.ordinal = st->ordinal;
    if (st->ordinal >= 1 && st->ordinal <= s->n) {
        row.kind         = mo_kind_name(s->cmds[st->ordinal]);
        row.install_name = s->names[st->ordinal] ? s->names[st->ordinal] : "-";
    } else {
        /* A special ordinal (flat/self/exe) names no library, and an ordinal
         * past what the load commands declare is a malformed stream we report
         * rather than resolve. */
        row.kind = "-";
        row.install_name = "-";
    }
    s->fn(&row, s->ctx);
}
```

`cmd_imports` in `cli/machorewrite.c` prints `row.ordinal` as the decimal ordinal for `>= 1`, and as `self`/`exe`/`flat` for the three `MO_ORD_*` values.

In `cli/machorewrite.c`, add `cmd_imports` printing the header row then one row per callback, and dispatch it beside `info` and `verify`:

```c
    if (strcmp(verb, "imports") == 0) {
        if (argc != 3) { fprintf(stderr, "usage: %s imports FILE\n", argv[0]); return EX_FAIL; }
        return cmd_imports(argv[2]);
    }
```

Add `machorewrite imports FILE` to `usage()`, `printf("verb imports\n")` to `print_capabilities`, and update the comment that reads "THE TWO SURVIVING VERB WORDS ARE THE ONLY SHADOWS LEFT" — there are now three, and `machorewrite imports out` would read a file named `imports` only through `./imports`.

- [ ] **Step 4: Run the whole suite**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native --output-on-failure
```

- [ ] **Step 5: Commit**

```sh
git add src/imports.h src/imports.c cli/machorewrite.c CMakeLists.txt tests/cli_test.sh
git commit -m "feat(cli): an imports verb reporting every bind as TSV"
```

---

### Task 7: The `insert_dylib` wrapper

**Files:**
- Create: `compat/insert_dylib.sh`
- Modify: `compat/translate.sh` (the flag grammar)
- Modify: `compat/README.md` (the divergence table)
- Modify: `CMakeLists.txt` (stage the wrapper into the build dir like the other six)
- Modify: `.github/workflows/release.yml` (add `insert_dylib` to the staged artifact list)

**Interfaces:**
- Consumes: `dylib retype` (Task 3); `machorewrite-compat.sh`'s `mw_translate`, `mw_prepare`, `mw_run_to_tmp`, `mw_finish`, `MW_NCMDS`, `MW_CHANGED`.
- Produces: `compat/insert_dylib.sh`, accepting `insert_dylib [flags] dylib_path binary_path [new_binary_path]`.

**Flag mapping (from the fork at `bd221b8`):**

| flag | statements |
|---|---|
| (none) | `dylib append PATH` |
| `--weak` | `dylib append PATH`, `dylib retype PATH weak` |
| `--strip-codesig` | adds `load-command delete codesig` |
| `--no-strip-codesig` | suppresses it, no prompt |
| `--inplace` | OUT is the input path |
| `--overwrite` | suppresses the "already exists" prompt |
| `--all-yes` | every prompt answers yes |

Default output is `<binary_path>_patched` — appended, from the fork's `asprintf`. Its README says "prepended" and is wrong; do not follow the README.

- [ ] **Step 1: Write the failing test**

Create `tests/insert_dylib_test.sh` following `tests/wrapper_test.sh`'s structure:

```sh
# The core act: append, and the binary still verifies.
"$BIN/insert_dylib" --all-yes /usr/lib/libfoo.dylib "$T/in" "$T/out"
check_rc 0 "plain insert"
"$BIN/machorewrite" verify "$T/out" >/dev/null || fail "output does not verify"
"$BIN/machorewrite" imports "$T/out" >/dev/null || fail "output has no readable imports"

# --weak emits LC_LOAD_WEAK_DYLIB, and `imports` is how we can tell.
"$BIN/insert_dylib" --all-yes --weak /usr/lib/libfoo.dylib "$T/in" "$T/wk"
check_rc 0 "weak insert"
"$BIN/machorewrite" imports "$T/wk" \
    | awk -F'\t' 'NR==1{for(i=1;i<=NF;i++)c[$i]=i}
                  NR>1 && $c["install_name"]=="/usr/lib/libfoo.dylib" {print $c["kind"]}' \
    | grep -qx weak \
    || fail "--weak did not produce a weak dylib command"

# Default output path is <input>_patched, APPENDED.
cp "$T/in" "$T/dflt"
"$BIN/insert_dylib" --all-yes /usr/lib/libfoo.dylib "$T/dflt"
check_rc 0 "default output"
[ -f "$T/dflt_patched" ] || fail "default output is not <input>_patched"

# --inplace writes the input.
cp "$T/in" "$T/ip"
"$BIN/insert_dylib" --all-yes --inplace /usr/lib/libfoo.dylib "$T/ip"
check_rc 0 "inplace"
cmp -s "$T/in" "$T/ip" && fail "--inplace did not change the file"

# No tty and no --all-yes is a refusal, not a hang. The codesig prompt is the
# one the fixture reaches.
"$BIN/insert_dylib" /usr/lib/libfoo.dylib "$T/in" "$T/nt" </dev/null >/dev/null 2>"$T/nt.err"
check_rc 1 "no tty, no --all-yes"
grep -qi 'tty\|all-yes' "$T/nt.err" || fail "the no-tty refusal does not say why"

# 32-bit input is refused, and says so. This is a DECLARED divergence from the
# fork, which handles it.
"$BIN/insert_dylib" --all-yes /usr/lib/libfoo.dylib "$HERE/fixture32.macho" >/dev/null 2>"$T/32.err"
check_rc 1 "32-bit refused"
grep -qi '32' "$T/32.err" || fail "the 32-bit refusal does not name the reason"
```

If no 32-bit fixture exists, generate one in the test the way the other suites generate theirs, or drop that case and record it in the divergence table as untested — do not fake it.

- [ ] **Step 2: Run it and watch it fail**

```sh
sh tests/insert_dylib_test.sh build-native/
```
Expected: FAIL — no `insert_dylib` in the build directory.

- [ ] **Step 3: Implement**

`compat/insert_dylib.sh`, modelled on `compat/change_dylib.sh` — same `MW_DIR` discovery, same `machorewrite-compat.sh` sourcing, same exit-code forwarding. Its header comment states, in two sentences, that this wrapper has **no known callers** (so `tests/known-callers.sh` is silent for it) and that it emulates a tool this repo never shipped.

Prompts read `/dev/tty`, never stdin — stdin is the statement channel. With `--all-yes`, nothing is asked. With no `/dev/tty` and no `--all-yes`, refuse with a message naming `--all-yes`.

Add the grammar to `compat/translate.sh` beside the other six tools' grammars, following their structure exactly.

**Do not extend `tests/compat-sweep.sh`.** It refuses to write `tests/compat-matrix.tsv` by name (`compat-sweep.sh:23,169`); that matrix is a frozen reference for the six historical tools and regenerating it to admit a seventh would destroy what it exists to preserve. `insert_dylib` gets its own sweep if it wants one.

Register the wrapper in `CMakeLists.txt` the way the six are, and add `insert_dylib` to `release.yml`'s staged artifact list — an artifact missing it is a name that cannot run.

- [ ] **Step 4: Run the whole suite**

```sh
shipyard-cmake --build --preset native-local
ctest --test-dir build-native --output-on-failure
sh tests/insert_dylib_test.sh build-native/
```

- [ ] **Step 5: Commit**

```sh
git add compat/insert_dylib.sh compat/translate.sh compat/README.md \
        CMakeLists.txt .github/workflows/release.yml tests/insert_dylib_test.sh
git commit -m "feat(compat): an insert_dylib wrapper over append and retype"
```

---

### Task 8: Differential against the pinned fork

Proves the interface claim rather than asserting it.

**Files:**
- Create: `tests/insert-dylib-diff.sh`
- Modify: `tests/README.md` (say what it is and why it is not a ctest)

**Interfaces:**
- Consumes: `compat/insert_dylib.sh` (Task 7).
- Produces: a by-hand differential runner, pinned to `Wowfunhappy/insert_dylib` at `bd221b8`.

- [ ] **Step 1: Write the runner**

Model it on `tests/differential.sh`'s structure and its "why this is not a ctest" header. It is not a ctest for the same reason: it needs an external build and a corpus, and CI has neither.

It compares **interface behaviour only** — exit code, stdout, stderr shape, which output path was written, and whether the result is a valid Mach-O. It does **not** compare output bytes; `docs/prior-art.md` records four checks this side makes that the fork does not, and the fork's README states its expansion path is unverified.

The pin lives in the script as a constant, with the commit subject beside it, so moving it is a reviewable diff:

```sh
# The fork this wrapper's interface is copied from. Moving this pin is a
# deliberate act: re-read main.c's option table and default output path first.
FORK_COMMIT=bd221b8   # "Fixes for some executables"
```

- [ ] **Step 2: Run it against a real corpus**

```sh
git clone https://github.com/Wowfunhappy/insert_dylib /tmp/idl
git -C /tmp/idl checkout bd221b8
# build per the fork's Xcode project, then:
sh tests/insert-dylib-diff.sh /tmp/idl/build/insert_dylib build-native/insert_dylib /Applications
```
Expected: every interface difference is either absent or already named in `compat/README.md`'s divergence table. **A difference that is not in the table is a finding — report it, do not add it to the table to make the run green.**

- [ ] **Step 3: Record what it found**

Add any genuine divergences to `compat/README.md`, each naming the test that pins it.

- [ ] **Step 4: Commit**

```sh
git add tests/insert-dylib-diff.sh tests/README.md compat/README.md
git commit -m "test(compat): differential insert_dylib against the fork at bd221b8"
```

---

## Final verification

- [ ] `ctest --test-dir build-native --output-on-failure` — all green, `characterize` included.
- [ ] `ctest --test-dir build-cross --output-on-failure` — the cross build too.
- [ ] `git grep -n 'spec: docs/superpowers/specs/2026-09-20'` returns **nothing**. This plan's spec is not cited from source.
- [ ] `git diff --stat main -- tests/EXPECTED` is empty.
- [ ] Push to `main` and confirm both `release` and `conventions` are green on GitHub. Local green is not the gate: this repo has had a day of red `main` behind a green local suite.
