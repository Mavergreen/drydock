# Bind-Stream Edit Implementation Plan

> **Revised 2026-09-25 against c8d5c21.** `minos at-most`/`minos if-absent`
> landed since this plan was written, adding two rows after `import
> redirect`'s and moving the baseline row count from 17 to 18. Every place
> that placed a new row, enum value or `me_apply` case "after redirect" now
> says "append after whatever is currently last" instead, and every
> hard-coded row count is now stated relative to what's in the tree, with
> today's value given as an example. The find/replace steps for "17 rows" /
> "Five ... rows" / "seventeen" wording in `src/script.c`/`src/script.h` are
> removed: a comment-policy sweep already generalized that wording.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `import weaken SYMBOL LIB` (OR `BIND_SYMBOL_FLAGS_WEAK_IMPORT` into the selected binds of an existing `LC_DYLD_INFO[_ONLY]` stream) and `import flatten SYMBOL LIB` (re-point them at `BIND_SPECIAL_DYLIB_FLAT_LOOKUP`). Both are refuse-by-default, per slice, and verified after the rewrite.

**Architecture:** First, `import redirect`'s slice scan, selector, event walk and bounds checks move into a shared `src/bindsel.[ch]` (`mbs_`). `import weaken` is a new core, `src/weaken.[ch]` (`mwk_`), which flips one flag byte per symbol opcode in place. `import flatten` is `import redirect`'s core with the target spelled `MO_ORD_FLAT`. The target stays in walker space throughout, so a wide lazy ordinal opcode can be filled with repeated `0x3E`, and a regular stream grows through the existing move-to-end-of-`__LINKEDIT` path.

**Tech Stack:** C99, CMake + CTest (Ninja), POSIX `/bin/sh` test suites, hermetic C test binaries.

**Spec:** `docs/superpowers/specs/2026-09-23-bind-stream-edit-design.md`

## Global Constraints

- **TDD, and every assertion mutation-proven.** Write the test and watch it fail for the stated reason, then implement. After the test passes, mutate the code the assertion guards, rebuild, watch the assertion fail, then revert and rebuild. Each task lists its mutations.
- **This host's clock is skewed: confirm every rebuild.** After any source edit, or any mutation or revert, the build output must name the edited file's object, for example `Building C object CMakeFiles/drydockcore.dir/src/weaken.c.o`. If it prints `ninja: no work to do`, or does not list that object, `touch` the file and rebuild. A mutation measured against a stale binary proves nothing.
- **Build:** `/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j`
- **Test (full):** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native`
- **Test (one suite):** the same, with `-R '^bind_edit_test$' --output-on-failure` (or `^script_test$`, `^relations_test$`, `^cli_test$`, `^import_redirect_test$`).
- **Exit codes:** `EX_REFUSED` / `MR_REFUSED` = 1, `EX_FAIL` / `MR_FAIL` = 2. A refusal writes nothing.
- **Every grep negative needs a positive control:** an assertion that something is *absent* is paired with one showing the same pattern *present* where it should be. Use `git grep` for source sweeps, never `grep -r`, which skips ignored files on this host.
- **In shell suites, capture an exit status with `rc=0; cmd || rc=$?`** (the suites run under `set -eu`).
- **Comments are a last resort.** Prefer a test, then the commit message, then a doc, then one inline sentence. No history narration ("used to", "now", "was"), and no reference to this plan, the spec, a task or a step anywhere in source.
- **Leave `import redirect`'s behaviour and messages byte-identical.** `tests/import_redirect_test.sh` must pass, unchanged, after every task.
- **`README.md` is touched only in Task 8,** and only on the lines this feature adds.
- **Stage explicit paths only.** Never `git add -A` or `git add .`.
- Every commit message ends with exactly these two lines:
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU`
- **Local green is not CI green.** When the owner pushes, check `gh run list`. CI runs on `macos-26-arm64`, where the fixture is arm64 and dyld4 binds at launch. The runtime cases are written so that "before" and "after" run identically on both, and the executor does not rely on that without looking.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `src/ordinals.h`, `src/ordinals.c` | `mo_bind_state.sym_at`: where the symbol opcode in effect sits | 1 |
| `src/bindsel.h`, `src/bindsel.c` (new) | slice scan, `(SYMBOL, LIB)` selector, event walk, bounds, the `who:` message prefix | 2 |
| `src/redirect.h`, `src/redirect.c` | `import redirect` on `bindsel`; then `mrd_flatten` and the walker-space target | 2, 5, 6 |
| `src/weaken.h`, `src/weaken.c` (new) | `import weaken`: plan, flip, verify | 3, 4, 7 |
| `src/script.h`, `src/script.c` | `MS_WEAKEN`, `MS_FLATTEN` and their rows | 3, 5 |
| `src/edit.c` | lowering, `me_import_verdict`, `me_log_weaken`, `me_log_redirect`'s flat wording | 3, 4, 5, 7 |
| `CMakeLists.txt` | the two new sources and the `bind_edit_test` suite | 2, 3 |
| `tests/relations_test.c` | `sym_at` | 1 |
| `tests/script_test.c`, `tests/cli_test.sh` | parse, row count, disturbs, `--capabilities` | 3, 5 |
| `tests/mkbindstream.c` | `weakref` and `hex` subcommands | 3, 6 |
| `tests/bind_edit_test.sh` (new) | everything the two statements do to a real binary | 3–7 |
| `README.md` | Statements, the "can match nothing" list, one subsection | 8 |

**Shared with plans drafting in parallel.** `src/script.[ch]`, `tests/script_test.c` and `tests/cli_test.sh` pin the row count, and `minos set` and `section retype` also add rows, so whichever lands second rebases the count. `src/edit.c`'s `me_apply` switch is shared with both. `README.md`'s Statements block is shared with every one. The `add_library` line in `CMakeLists.txt` is shared with any plan that adds a source. `src/redirect.[ch]`, `src/ordinals.h` and `src/script.c`'s comments may collide with item 6's comment sweep.

---

### Task 1: `mo_bind_state.sym_at`

An editor of the symbol opcode needs to know where it is. The walker records `at`, `ord_at` and `done_at`, but not this.

**Files:**
- Modify: `src/ordinals.h` (the `mo_bind_state` struct, `:249-260` at HEAD c8d5c21 — the `const uint8_t *at, *ord_at, *done_at;` line is at `:255`)
- Modify: `src/ordinals.c:315-326` (`BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM`)
- Test: `tests/relations_test.c`

**Interfaces:**
- Consumes: nothing.
- Produces: `mo_bind_state.sym_at` (`const uint8_t *`): the `SET_SYMBOL_TRAILING_FLAGS_IMM` opcode byte in effect at this bind, `NULL` before any. Set only by an observe-only walk (`map == NULL`), like `symbol` and `weak`.

- [ ] **Step 1: Write the failing test**

In `tests/relations_test.c`, append to the end of `test_bind_walk_reports_positions_and_slots` (after its last `CHECK`, before its closing `}`):

```c
    CHECK(p.st[0].sym_at == stream + 1, "bind 0's symbol opcode is byte 1");
    CHECK(p.st[2].sym_at == stream + 1,
          "bind 2 still binds _a, whose symbol opcode is byte 1, across the DONE");
```

Add a new test after that function:

```c
static void test_bind_walk_reports_the_symbol_opcode_in_effect(void) {
    const uint8_t stream[] = {
        /* 0 */  BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | 1,
        /* 1 */  BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM, '_','a','\0',
        /* 5 */  BIND_OPCODE_DO_BIND,
        /* 6 */  BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | BIND_SYMBOL_FLAGS_WEAK_IMPORT,
                 '_','b','\0',
        /* 10 */ BIND_OPCODE_DO_BIND,
        /* 11 */ BIND_OPCODE_DONE,
    };
    struct places p;
    memset(&p, 0, sizeof p);
    CHECK(mo_bind_observe(stream, (uint32_t)sizeof stream, "test", keep, &p) == 0, "walk failed");
    CHECK(p.n == 2, "saw %d binds, wanted 2", p.n);
    if (p.n != 2) return;
    CHECK(p.st[0].sym_at == stream + 1 && p.st[0].weak == 0,
          "_a's symbol opcode is byte 1, strong");
    CHECK(p.st[1].sym_at == stream + 6 && p.st[1].weak == 1,
          "_b's symbol opcode is byte 6, and its immediate carries WEAK_IMPORT");
}
```

Register it in `main`, directly after `test_bind_walk_reports_positions_and_slots();`:

```c
    test_bind_walk_reports_the_symbol_opcode_in_effect();
```

- [ ] **Step 2: Run it to make sure it fails**

Run the build, then `ctest ... -R '^relations_test$' --output-on-failure`.
Expected: a compile error, `no member named 'sym_at'`.

- [ ] **Step 3: Write the minimal implementation**

In `src/ordinals.h`, change `const uint8_t *at, *ord_at, *done_at;` to:

```c
    const uint8_t *at, *ord_at, *done_at, *sym_at;
```

and in the one-line `spec:` comment directly above it, change `-- the DO opcode, the ordinal opcode in effect and the last DONE (NULL before any)` to `-- the DO opcode, the ordinal and symbol opcodes in effect and the last DONE (NULL before any)`.

In `src/ordinals.c`, in the `BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM` case, change the observe-only branch:

```c
                if (!map) {
                    st.symbol = (const char *)name;
                    st.weak = (imm & BIND_SYMBOL_FLAGS_WEAK_IMPORT) != 0;
                    st.sym_at = op_at;
                }
```

(`op_at` is already declared at the top of the loop as the opcode's own byte.)

- [ ] **Step 4: Run the tests and make sure they pass**

Run the build (confirm `ordinals.c.o` and `relations_test.c.o` rebuilt), then the full `ctest`.
Expected: all PASS.

- [ ] **Step 5: Mutation-prove**

- `st.sym_at = op_at;` → `st.sym_at = name;`: all four new `sym_at` checks FAIL.
- Delete the `st.sym_at = op_at;` line: the same four FAIL, because `sym_at` is `NULL`.

Revert each one, and confirm the rebuild both times.

- [ ] **Step 6: Commit**

```bash
git add src/ordinals.h src/ordinals.c tests/relations_test.c
git commit -m "feat(ordinals): report where the symbol opcode in effect sits

An observe-only walk now records sym_at beside symbol and weak: the
SET_SYMBOL_TRAILING_FLAGS_IMM byte whose immediate holds the weak-import
flag, which is what an editor of that flag writes.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 2: Move `import redirect`'s selection into `src/bindsel.[ch]`

This is a pure refactor, so no behaviour or message changes. The test is `tests/import_redirect_test.sh`, unchanged. It greps a dozen of the messages this task moves.

**Files:**
- Create: `src/bindsel.h`, `src/bindsel.c`
- Modify: `src/redirect.c` (all of `:17-77`, `:113-114`, `:168-170`, `:195-205`, `:211-288`, `:337-338`, `:389`, `:435-440`)
- Modify: `CMakeLists.txt:66` (`add_library`)

**Interfaces:**
- Consumes: `mo_bind_state.sym_at` (Task 1). Not used here, but it travels in `mbs_events`.
- Produces (`src/bindsel.h`):
  - `typedef struct { mo_bind_state *v; size_t n, cap; int oom; } mbs_events;`
  - `typedef struct { const char *names[MO_MAX_DYLIBS + 1]; int n, lazy_load, chained; struct dyld_info_command *di; struct symtab_command *st; struct segment_command_64 *linkedit; } mbs_slice;`
  - `typedef struct { const char *symbol; unsigned char from[MO_MAX_DYLIBS + 1]; int n, nfrom, first; } mbs_sel;`
  - `void mbs_say(const char *who, const char *fmt, ...);` prints `who: ` and then the formatted message, to stderr.
  - `int mbs_open(uint8_t *buf, size_t size, const char *who, mi_image *im, mbs_slice *s);` returns 0 or `MR_REFUSED`.
  - `void mbs_scan(const mi_image *im, mbs_slice *s);`
  - `void mbs_select(const mbs_slice *s, const char *symbol, const char *from, mbs_sel *sel);`
  - `int mbs_bounds(const mbs_slice *s, size_t size, const char *who);` requires `s->di`.
  - `int mbs_walk(const uint8_t *buf, uint32_t off, uint32_t size, const char *stream, const char *who, mbs_events *e);`
  - `void mbs_free(mbs_events *e);`
  - `int mbs_selected(const mbs_sel *sel, const mo_bind_state *b);`
  - `int mbs_nlist_selected(const uint8_t *buf, const struct symtab_command *st, const struct nlist_64 *n, const mbs_sel *sel);`

- [ ] **Step 1: Confirm the baseline**

Run the build and `ctest ... -R '^import_redirect_test$' --output-on-failure`.
Expected: PASS, `import_redirect_test: 0 failure(s)`. This suite is the test for the whole task.

- [ ] **Step 2: Create `src/bindsel.h`**

```c
#ifndef DRYDOCK_BINDSEL_H
#define DRYDOCK_BINDSEL_H
/*
 * mbs_ -- the binds of SYMBOL whose library is LIB, in one 64-bit slice: what
 * the `import` statements select. Each statement's core decides what to do
 * to them. Every refusal is on stderr, prefixed with the caller's `who`.
 */
#include <stddef.h>
#include <stdint.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#include "image.h"
#include "ordinals.h"

typedef struct { mo_bind_state *v; size_t n, cap; int oom; } mbs_events;

typedef struct {
    const char *names[MO_MAX_DYLIBS + 1];
    int n, lazy_load, chained;
    struct dyld_info_command *di;
    struct symtab_command *st;
    struct segment_command_64 *linkedit;
} mbs_slice;

typedef struct {
    const char *symbol;
    unsigned char from[MO_MAX_DYLIBS + 1];
    int n, nfrom, first;
} mbs_sel;

void mbs_say(const char *who, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

/* 0, or MR_REFUSED: not a 64-bit Mach-O, chained fixups, LC_LAZY_LOAD_DYLIB,
 * or a dylib name past its cmdsize. */
int  mbs_open(uint8_t *buf, size_t size, const char *who, mi_image *im, mbs_slice *s);
void mbs_scan(const mi_image *im, mbs_slice *s);
void mbs_select(const mbs_slice *s, const char *symbol, const char *from, mbs_sel *sel);
int  mbs_bounds(const mbs_slice *s, size_t size, const char *who);
int  mbs_walk(const uint8_t *buf, uint32_t off, uint32_t size, const char *stream,
              const char *who, mbs_events *e);
void mbs_free(mbs_events *e);
int  mbs_selected(const mbs_sel *sel, const mo_bind_state *b);
int  mbs_nlist_selected(const uint8_t *buf, const struct symtab_command *st,
                        const struct nlist_64 *n, const mbs_sel *sel);

#endif
```

- [ ] **Step 3: Create `src/bindsel.c`**

Every message below is `src/redirect.c`'s, word for word, with `WHAT ": "` now the `who` argument.

```c
/* bindsel.c -- see bindsel.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bindsel.h"
#include "rewrite.h"
#include "mach_compat.h"

void mbs_say(const char *who, const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "%s: ", who);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
}

static void mbs_collect(const mo_bind_state *st, void *ctx) {
    mbs_events *e = ctx;
    if (e->oom) return;
    if (e->n == e->cap) {
        size_t cap = e->cap ? e->cap * 2 : 64;
        mo_bind_state *v = realloc(e->v, cap * sizeof *v);
        if (!v) { e->oom = 1; return; }
        e->v = v; e->cap = cap;
    }
    e->v[e->n++] = *st;
}

int mbs_walk(const uint8_t *buf, uint32_t off, uint32_t size, const char *stream,
             const char *who, mbs_events *e) {
    memset(e, 0, sizeof *e);
    if (size == 0) return 0;
    if (mo_bind_observe(buf + off, size, stream, mbs_collect, e) != 0) return MR_REFUSED;
    if (e->oom) { mbs_say(who, "out of memory\n"); return MR_FAIL; }
    return 0;
}

void mbs_free(mbs_events *e) {
    free(e->v);
    memset(e, 0, sizeof *e);
}

static int mbs_lc(const struct load_command *lc, void *ctx) {
    mbs_slice *s = ctx;
    if (mo_is_ordinal_lc(lc->cmd) && s->n < MO_MAX_DYLIBS) {
        const struct dylib_command *dc = (const struct dylib_command *)lc;
        s->names[++s->n] = mo_lc_str_at(lc, dc->dylib.name.offset);
    } else if (lc->cmd == LC_LAZY_LOAD_DYLIB) {
        s->lazy_load = 1;
    } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) {
        s->chained = 1;
    } else if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        s->di = (struct dyld_info_command *)lc;
    } else if (lc->cmd == LC_SYMTAB) {
        s->st = (struct symtab_command *)lc;
    } else if (lc->cmd == LC_SEGMENT_64) {
        struct segment_command_64 *sc = (struct segment_command_64 *)lc;
        if (strncmp(sc->segname, "__LINKEDIT", 16) == 0) s->linkedit = sc;
    }
    return 0;
}

void mbs_scan(const mi_image *im, mbs_slice *s) {
    memset(s, 0, sizeof *s);
    mi_each_lc(im, mbs_lc, s);
}

int mbs_open(uint8_t *buf, size_t size, const char *who, mi_image *im, mbs_slice *s) {
    int i;
    if (mi_wrap(buf, size, im) != 0) {
        mbs_say(who, "the image is not a readable 64-bit Mach-O\n");
        return MR_REFUSED;
    }
    mbs_scan(im, s);
    if (s->chained) {
        mbs_say(who, "the image uses LC_DYLD_CHAINED_FIXUPS; put "
                     "`fixups set classic` before this statement\n");
        return MR_REFUSED;
    }
    if (s->lazy_load) {
        mbs_say(who, "LC_LAZY_LOAD_DYLIB present; its place in the ordinal "
                     "sequence has never been established, so refusing rather "
                     "than guessing which library an ordinal names\n");
        return MR_REFUSED;
    }
    for (i = 1; i <= s->n; i++) {
        if (!s->names[i]) {
            mbs_say(who, "dylib load command %d has a name offset past its "
                         "cmdsize; refusing\n", i);
            return MR_REFUSED;
        }
    }
    return 0;
}

void mbs_select(const mbs_slice *s, const char *symbol, const char *from, mbs_sel *sel) {
    int i;
    memset(sel, 0, sizeof *sel);
    sel->symbol = symbol;
    sel->n = s->n;
    for (i = 1; i <= s->n; i++) {
        if (strcmp(s->names[i], from) != 0) continue;
        sel->from[i] = 1;
        sel->nfrom++;
        if (!sel->first) sel->first = i;
    }
}

int mbs_bounds(const mbs_slice *s, size_t size, const char *who) {
    const struct dyld_info_command *di = s->di;
    if (!mo_fits(di->bind_off, di->bind_size, size) ||
        !mo_fits(di->lazy_bind_off, di->lazy_bind_size, size) ||
        !mo_fits(di->weak_bind_off, di->weak_bind_size, size)) {
        mbs_say(who, "a bind stream does not fit within the %zu-byte image; "
                     "refusing\n", size);
        return MR_REFUSED;
    }
    if (s->st && (!mo_fits(s->st->symoff, (uint64_t)s->st->nsyms * sizeof(struct nlist_64), size) ||
                  !mo_fits(s->st->stroff, s->st->strsize, size))) {
        mbs_say(who, "LC_SYMTAB does not fit within the %zu-byte image; "
                     "refusing\n", size);
        return MR_REFUSED;
    }
    return 0;
}

int mbs_selected(const mbs_sel *sel, const mo_bind_state *b) {
    return b->symbol && strcmp(b->symbol, sel->symbol) == 0 &&
           b->ordinal >= 1 && b->ordinal <= sel->n && sel->from[b->ordinal];
}

int mbs_nlist_selected(const uint8_t *buf, const struct symtab_command *st,
                       const struct nlist_64 *n, const mbs_sel *sel) {
    uint8_t type = n->n_type & N_TYPE;
    int ord = GET_LIBRARY_ORDINAL(n->n_desc);
    if ((n->n_type & N_STAB) || (type != N_UNDF && type != N_PBUD)) return 0;
    if (ord < 1 || ord > sel->n || !sel->from[ord]) return 0;
    if ((uint64_t)n->n_un.n_strx >= st->strsize) return 0;
    const char *name = (const char *)buf + st->stroff + n->n_un.n_strx;
    size_t room = st->strsize - n->n_un.n_strx, len = strlen(sel->symbol);
    return room > len && memcmp(name, sel->symbol, len + 1) == 0;
}
```

- [ ] **Step 4: Put `src/redirect.c` on it**

4a. Delete the definitions that moved: `mrd_events`, `mrd_collect`, `mrd_walk`, `mrd_slice`, `mrd_lc`, `mrd_sel`, `mrd_moved` (all of `:17-77`, from `typedef struct { mo_bind_state *v;` through `mrd_moved`'s closing `}`), and `mrd_nlist_selected` (`:195-205`). Add `#include "bindsel.h"` after `#include "redirect.h"`.

4b. Rename mechanically:

```bash
sed -i '' \
  -e 's/mrd_events/mbs_events/g' \
  -e 's/mrd_slice/mbs_slice/g' \
  -e 's/[[:<:]]mrd_sel[[:>:]]/mbs_sel/g' \
  -e 's/mrd_moved(/mbs_selected(/g' \
  -e 's/mrd_nlist_selected(/mbs_nlist_selected(/g' \
  -e 's/fprintf(stderr, WHAT ": /mbs_say(who, "/' \
  -e 's/mrd_walk(\(.*\), \(&[a-z_]*\))/mbs_walk(\1, who, \2)/' \
  -e 's/mi_each_lc(&nim, mrd_lc, &ns);/mbs_scan(\&nim, \&ns);/' \
  src/redirect.c
```

(`[[:<:]]`/`[[:>:]]` are BSD sed's word boundaries; `\b` does not work there.) Check it with a positive and a negative control. `git grep -n 'mbs_say(who, "' src/redirect.c` must print at least one line. `git grep -n 'WHAT ": ' src/redirect.c` and `git grep -nw -e mrd_walk -e mrd_moved -e mrd_lc -e mrd_sel -e mrd_events -e mrd_slice src/redirect.c` must both print nothing. If either prints anything, finish that line by hand.

4c. Thread `who` into the two helpers that print. Change their signatures to:

```c
static int mrd_rewrite_bind(const char *who, const uint8_t *in, uint32_t size,
                            const mbs_events *e, const mbs_sel *sel, int to,
                            mrd_buf *out, size_t *live) {
```

```c
static int mrd_same(const char *who, const char *what, const mbs_events *before,
                    const uint8_t *b0, const mbs_events *after, const uint8_t *a0,
                    const mbs_sel *sel, int to, int same_place) {
```

and pass `who` first at their call sites (`mrd_rewrite_bind(who, buf + di->bind_off, ...)`, `mrd_same(who, "bind", ...)`, `mrd_same(who, "lazy bind", ...)`).

4d. Replace everything from `int mrd_redirect(uint8_t **pbuf` through the closing `}` of the three-walk `if` (the block ending `mbs_free3(&bind, &lazy, &weak);\n        return rc;\n    }`, currently `:211-288`) with:

```c
int mrd_redirect(uint8_t **pbuf, size_t *psize, const char *symbol,
                 const char *from, const char *to, mrd_report *rep) {
    const char *who = WHAT;
    uint8_t *buf = *pbuf;
    size_t size = *psize;
    mi_image im;
    mbs_slice s;
    mbs_sel sel;
    int i, rc;

    memset(rep, 0, sizeof *rep);
    if ((rc = mbs_open(buf, size, who, &im, &s)) != 0) return rc;
    mbs_select(&s, symbol, from, &sel);
    rep->from = sel.first;
    for (i = 1; i <= s.n && !rep->to; i++)
        if (strcmp(s.names[i], to) == 0) rep->to = i;
    if (!rep->to) {
        mbs_say(who, "%s is not a library this image loads; a statement "
                     "before this one must add it (dylib append %s)\n", to, to);
        return MR_REFUSED;
    }
    if (!(im.hdr->flags & MH_TWOLEVEL)) {
        mbs_say(who, "flat namespace: no import names a library, so there "
                     "is none to redirect\n");
        return MR_REFUSED;
    }
    if (sel.nfrom == 0) return 0;
    if (!s.di) {
        mbs_say(who, "no LC_DYLD_INFO: this image binds through relocation "
                     "entries, which import redirect does not rewrite\n");
        return MR_REFUSED;
    }
    if ((rc = mbs_bounds(&s, size, who)) != 0) return rc;

    const struct dyld_info_command *di = s.di;
    mbs_events bind, lazy, weak;
    memset(&bind, 0, sizeof bind); memset(&lazy, 0, sizeof lazy); memset(&weak, 0, sizeof weak);
    if ((rc = mbs_walk(buf, di->bind_off, di->bind_size, "bind", who, &bind)) != 0 ||
        (rc = mbs_walk(buf, di->lazy_bind_off, di->lazy_bind_size, "lazy bind", who, &lazy)) != 0 ||
        (rc = mbs_walk(buf, di->weak_bind_off, di->weak_bind_size, "weak bind", who, &weak)) != 0) {
        mrd_free3(&bind, &lazy, &weak);
        return rc;
    }
```

In the remaining body, `&sel` is already the right argument everywhere. `mrd_free3` stays, with its parameter type renamed by 4b.

4e. In `CMakeLists.txt:66`, add `src/bindsel.c` after `src/imports.c`.

- [ ] **Step 5: Run the tests and make sure they pass**

Run the build (confirm `bindsel.c.o` and `redirect.c.o` compiled, with no warnings under `-Wall`), then the full `ctest`.
Expected: all PASS, including `import_redirect_test: 0 failure(s)`, byte-for-byte on every message it greps.

- [ ] **Step 6: Mutation-prove**

- In `mbs_select`, delete `sel->from[i] = 1;`: `import_redirect_test` FAILs at "regular: import redirect succeeds" (matched nothing).
- In `mbs_open`, change `"put \`fixups set classic\` before this statement"` to `"put fixups first"`: FAILs at "chained fixups: refused, naming fixups set classic as the remedy". This proves the moved text is the text under test.
- In `mbs_bounds`, invert `!mo_fits(di->weak_bind_off, ...)` to `mo_fits(...)`: FAILs across the suite (every redirect refuses).

Revert each one, and confirm the rebuild both times.

- [ ] **Step 7: Commit**

```bash
git add src/bindsel.h src/bindsel.c src/redirect.c CMakeLists.txt
git commit -m "refactor(redirect): move bind selection into src/bindsel

The slice scan, the (symbol, library) selector, the event walk and the
bounds checks leave src/redirect.c for a module the other import
statements can share. Every message is unchanged: import_redirect_test
greps them and passes as it was.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 3: `import weaken SYMBOL LIB`

**Files:**
- Create: `src/weaken.h`, `src/weaken.c`, `tests/bind_edit_test.sh`
- Modify: `src/script.h:43-45` (op enum — append at the end of the list, whatever is currently last), `src/script.c` (`MS_TABLE_ROWS`, append after whatever row is currently last — at HEAD c8d5c21 that's the `minos if-absent` row, `:132`)
- Modify: `src/edit.c:37` (include), `:191-217` (`me_log_redirect` — append `me_log_weaken` directly after it) and `:286` (end of `me_rewrite` — append `me_import_verdict` directly after it), `:410-422` (`case MS_IMPORT`)
- Modify: `CMakeLists.txt:66` and after the `import_redirect_test` `add_test` (`:384-386` at HEAD)
- Modify: `tests/mkbindstream.c` (`weakref`)
- Test: `tests/script_test.c`, `tests/cli_test.sh:494-529` (count check and capability advertisement assertions), `tests/bind_edit_test.sh`

**Interfaces:**
- Consumes: everything in `src/bindsel.h` (Task 2), and `mo_bind_state.sym_at` (Task 1).
- Produces:
  - `MS_WEAKEN`, appended to the op enum at the end of the list — after
    whatever value is currently last. At HEAD c8d5c21 that's `MS_IF_ABSENT`
    (`minos if-absent`), so `MS_WEAKEN` follows it, not `MS_REDIRECT`.
  - Row `R("import", MS_IMPORT, "weaken", MS_WEAKEN, 2, NULL, 0, 0, MREL_NONE)`.
  - `typedef struct { int from; long bind, lazy, nlist; } mwk_report;` (Task 4 appends `already, weak`, and Task 7 appends `flat`.)
  - `int mwk_weaken(uint8_t **pbuf, size_t *psize, const char *symbol, const char *from, mwk_report *rep);` returns 0 with `*rep` filled (`bind + lazy + nlist == 0` when nothing matched in this slice), or `MR_REFUSED`/`MR_FAIL`. On a refusal, `*pbuf` is the image as it was.
  - In `src/edit.c`: `static int me_import_verdict(const ms_script *s, const ms_stmt *st, me_verdict *v, long n);` and `static void me_log_weaken(FILE *log, const mwk_report *r, const char *symbol);`.
  - `mkbindstream weakref FILE SYMBOL` prints `1` or `0`: whether the symbol table's undefined SYMBOL has `N_WEAK_REF`.
  - `tests/bind_edit_test.sh` helpers: `has_import`, `cell`, `view`, `ordinal_of`, `field`, `run`.

- [ ] **Step 1: Write the failing parse tests**

In `tests/script_test.c`, add after `test_import_redirect`:

```c
static void test_import_weaken(void) {
    ms_script s; char err[256] = {0};
    const char *ok = "import weaken _getpid /usr/lib/libSystem.B.dylib\n";
    CHECK(ms_parse(ok, strlen(ok), &s, err, sizeof err) == 0, "weaken rejected: %s", err);
    CHECK(s.n == 1 && s.stmts[0].kind == MS_IMPORT && s.stmts[0].op == MS_WEAKEN,
          "wrong kind/op");
    CHECK(s.n == 1 && strcmp(s.stmts[0].a, "_getpid") == 0 &&
          strcmp(s.stmts[0].b, "/usr/lib/libSystem.B.dylib") == 0 && s.stmts[0].c == NULL,
          "operands are SYMBOL, LIB in that order");
    ms_free(&s);

    const char *one = "import weaken _getpid\n";
    err[0] = 0;
    CHECK(ms_parse(one, strlen(one), &s, err, sizeof err) == -1 &&
          strstr(err, "takes 2 arguments (got 1)") != NULL,
          "one operand refused for arity: %s", err);
}
```

Register `test_import_weaken();` in `main` directly after `test_import_redirect();`. In `test_capabilities_table_round_trips`, read the current row count N from its `CHECK(n_rows == N, "the statement table has N rows...)` line (at HEAD c8d5c21, N is 18 — the `minos` rows already bumped it from the 17 this plan was written against) and change both the `N` and the message to `N+1` (19 at HEAD). This function's leading comment and the `--capabilities` sentence no longer mention a row count at all (a comment-policy sweep already generalized them) — nothing to edit there.

At the end of `test_disturbs_matches_the_spec_table` (after HEAD's own last checks, `ms_disturbs(MS_MINOS, MS_AT_MOST)` and `ms_disturbs(MS_MINOS, MS_IF_ABSENT)`), add:

```c
    CHECK(ms_disturbs(MS_IMPORT, MS_WEAKEN) == MREL_NONE,
          "import weaken sets one flag bit per symbol opcode and n_desc bit in place, "
          "and moves nothing");
```

This function's leading comment, and `test_every_row_declares_its_disturbs`'s, are already count-agnostic at HEAD ("several rows", no "seventeen") — nothing to edit there either.

In `tests/cli_test.sh`, read the current count N from the two `-eq N` checks (`n_statements`/`n_unique`, HEAD c8d5c21: N=18) and the `"exactly N unique statement lines"` message, and bump each to `N+1` (19 at HEAD). The two-line comment directly above them ("`--capabilities' statement lines are generated from MS_TABLE; tests/script_test.c checks the table itself.`") is already count-agnostic at HEAD — a comment-policy sweep rewrote it — so there is nothing to replace there.

After the `statement dylib retype 2` assertion, add:

```sh
echo "$caps" | grep -qxF "statement import weaken 2" \
    && ok "capabilities: import weaken is advertised" \
    || bad "capabilities: import weaken" "no 'statement import weaken 2' line: $(echo "$caps" | grep '^statement import')"
```

- [ ] **Step 2: Run them to make sure they fail**

Run the build.
Expected: `script_test.c` fails to compile, with `use of undeclared identifier 'MS_WEAKEN'`.

- [ ] **Step 3: Add the enum value and the row**

In `src/script.h`, append `MS_WEAKEN` to the end of the op enum, after whatever value is currently last. At HEAD c8d5c21 the enum's last line (`:45`) is `       MS_AT_MOST, MS_IF_ABSENT };`; change it to:

```c
       MS_AT_MOST, MS_IF_ABSENT, MS_WEAKEN };
```

In `src/script.c`, append a new last row to `MS_TABLE_ROWS`, after whatever row is currently last (give that row's line a ` \` continuation). At HEAD c8d5c21 the last row is `minos if-absent` (`:132`):

```c
  R("minos",        MS_MINOS,        "if-absent", MS_IF_ABSENT,   1, NULL,        0,             0, MREL_HEADER_PAD) \
  R("import",       MS_IMPORT,       "weaken",   MS_WEAKEN,       2, NULL,        0,             0, MREL_NONE)
```

The wording this step used to find-and-replace ("17 rows", "Five ... rows", "seventeen") is already gone from `src/script.h`/`src/script.c` at HEAD — a comment-policy sweep (`a6de0c6`/`694881d`/`d3b76b0`) generalized it to count-agnostic phrasing ("One row per ...", "several rows", "every row"). Nothing to do there.

Run the build and `ctest ... -R '^(script_test|cli_test)$' --output-on-failure`.
Expected: `script_test` PASS. `cli_test` PASS on the count and the capability line. The statement exists but cannot run yet.

- [ ] **Step 4: Write the failing end-to-end suite**

Add to `tests/mkbindstream.c`: `weakref` to the usage comment's list (`mkbindstream weakref FILE SYMBOL`) and to its description paragraph (`\`weakref\` prints 1 if the symbol table's undefined SYMBOL carries N_WEAK_REF, else 0.`). Replace the `nlist` branch in `main` with a shared lookup plus both subcommands:

```c
static struct nlist_64 *undef(uint8_t *b, const char *sym) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = b + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
        struct symtab_command *st = (struct symtab_command *)p;
        if (st->cmd != LC_SYMTAB) continue;
        struct nlist_64 *nl = (struct nlist_64 *)(b + st->symoff);
        for (uint32_t k = 0; k < st->nsyms; k++) {
            if ((nl[k].n_type & N_TYPE) != N_UNDF || !(nl[k].n_type & N_EXT)) continue;
            if (strcmp((char *)b + st->stroff + nl[k].n_un.n_strx, sym) == 0) return &nl[k];
        }
    }
    fprintf(stderr, "no undefined %s\n", sym);
    exit(1);
}
```

(placed above `main`), and in `main`:

```c
    if (argc == 4 && strcmp(argv[1], "nlist") == 0) {
        uint8_t *b = slurp(argv[2], &n);
        printf("%d\n", GET_LIBRARY_ORDINAL(undef(b, argv[3])->n_desc));
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "weakref") == 0) {
        uint8_t *b = slurp(argv[2], &n);
        printf("%d\n", (undef(b, argv[3])->n_desc & N_WEAK_REF) ? 1 : 0);
        return 0;
    }
```

Add `| weakref FILE SYMBOL` to the usage `fprintf`.

Create `tests/bind_edit_test.sh`:

```sh
#!/bin/sh
# tests/bind_edit_test.sh -- `import weaken SYMBOL LIB` and
# `import flatten SYMBOL LIB`.
#
# Programs link against v1/liba.dylib. At run time the same install name
# holds lib/liba.dylib, which lacks the a_gone* symbols, as 10.9 lacks a newer
# system's. Facts about a result come from `drydock-macho-rewrite imports`,
# read by column name, and from tests/mkbindstream.c. A runtime case runs its
# "before" and its "after" the same way.
set -eu
BIN="${1:?usage: bind_edit_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "bind_edit_test: $DMR not found" >&2; exit 1; }
[ -x "$BIN/makefat" ] || { echo "bind_edit_test: need makefat in $BIN" >&2; exit 1; }
CC="${CC:-clang}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FF="-mmacosx-version-min=10.9"
T=$(mktemp -d "${TMPDIR:-/tmp}/bind_edit_test.XXXXXX")
T=$(cd "$T" && pwd -P)

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }
reached_end=0
trap 'rc=$?; rm -rf "$T"; if [ "$reached_end" -eq 0 ]; then
    echo "bind_edit_test: FATAL -- aborted early (exit $rc); everything after the last PASS/FAIL line never ran" >&2
fi' EXIT

"$CC" -O2 -o "$T/mkbindstream" "$HERE/mkbindstream.c"
MKB="$T/mkbindstream"

# has_import FILE SYMBOL INSTALL_NAME STREAM -- does `imports` report that row?
has_import() {
    "$DMR" imports "$1" 2>/dev/null | awk -F'\t' -v s="$2" -v l="$3" -v st="$4" '
        NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
        $c["symbol"] == s && $c["install_name"] == l && $c["stream"] == st { f = 1 }
        END { exit !f }'
}
# cell FILE SYMBOL INSTALL_NAME STREAM COLUMN -- that row's COLUMN.
cell() {
    "$DMR" imports "$1" 2>/dev/null | awk -F'\t' -v s="$2" -v l="$3" -v st="$4" -v k="$5" '
        NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
        $c["symbol"] == s && $c["install_name"] == l && $c["stream"] == st { print $c[k]; exit }'
}
# view FILE SYMBOL INSTALL_NAME COLUMN=VALUE... -- `imports`, with those cells
# of every row of SYMBOL from INSTALL_NAME replaced: what the output should be.
view() {
    view_f=$1 view_s=$2 view_l=$3; shift 3
    "$DMR" imports "$view_f" | awk -F'\t' -v OFS='\t' -v s="$view_s" -v l="$view_l" -v sets="$*" '
        NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; n = split(sets, kv, " "); print; next }
        $c["symbol"] == s && $c["install_name"] == l {
            for (k = 1; k <= n; k++) { split(kv[k], p, "="); $c[p[1]] = p[2] } }
        { print }'
}
# ordinal_of FILE INSTALL_NAME -- the ordinal `info` gives that library.
ordinal_of() {
    "$DMR" info "$1" | awk -v p="$2" 'index($0, "  ordinal=") == 1 {
        split($0, a, " path="); o = a[1]; sub("  ordinal=", "", o)
        if (a[2] == p) { print o; exit } }'
}
field() { "$MKB" info "$1" | awk -v k="$2" -v n="$3" '$1 == k { print $n }'; }

# run FILE OUT STATEMENT... -- the statements, one per line, on stdin.
run() {
    run_in=$1 run_out=$2; shift 2
    rm -f "$run_out"
    run_rc=0
    printf '%s\n' "$@" | "$DMR" "$run_in" "$run_out" >"$T/run.out" 2>"$T/run.err" || run_rc=$?
    return 0
}

# --- libraries ----------------------------------------------------------------
mkdir "$T/lib" "$T/v1"
LIBA="$T/lib/liba.dylib" LIBB="$T/lib/libb.dylib" SHIM="$T/lib/libshim.dylib"
V1="$T/v1/liba.dylib"
cat >"$T/a1.c" <<'EOF'
int a_data(void) { return 7; }
int a_fn(void) { return 8; }
int a_gone(void) { return 9; }
int a_gone_fn(void) { return 10; }
int a_gone2(void) { return 11; }
int dup(void) { return 12; }
EOF
cat >"$T/a2.c" <<'EOF'
int a_data(void) { return 7; }
int a_fn(void) { return 8; }
int dup(void) { return 12; }
EOF
cat >"$T/b.c" <<'EOF'
int dup(void) { return 20; }
EOF
cat >"$T/shim.c" <<'EOF'
int a_gone(void) { return 42; }
int a_gone_fn(void) { return 43; }
EOF
"$CC" -dynamiclib $FF -install_name "$LIBA" -o "$V1" "$T/a1.c"
"$CC" -dynamiclib $FF -install_name "$LIBA" -o "$LIBA" "$T/a2.c"
"$CC" -dynamiclib $FF -install_name "$LIBB" -o "$LIBB" "$T/b.c"
"$CC" -dynamiclib $FF -install_name "$SHIM" -o "$SHIM" "$T/shim.c"

# --- programs -----------------------------------------------------------------
# gone: _a_gone is a regular bind, through a data pointer the program reads.
cat >"$T/gone.c" <<'EOF'
int a_gone(void);
int (*volatile p)(void) = a_gone;
int main(void) { return p ? p() : 3; }
EOF
# lazygone: _a_fn and _a_gone_fn are lazy binds; only _a_fn is called.
cat >"$T/lazygone.c" <<'EOF'
int a_fn(void); int a_gone_fn(void);
int main(int argc, char **argv) { (void)argv; return argc > 1 ? a_gone_fn() : a_fn(); }
EOF
cat >"$T/two.c" <<'EOF'
int a_fn(void); int dup(void);
int main(void) { return a_fn() + dup(); }
EOF
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/gone" "$T/gone.c" "$V1"
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/lazygone" "$T/lazygone.c" "$V1"
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/two" "$T/two.c" "$V1" "$LIBB"

# ============================================================================
# weaken: a regular bind
# ============================================================================
has_import "$T/gone" _a_gone "$LIBA" bind && [ "$(cell "$T/gone" _a_gone "$LIBA" bind weak)" = 0 ] \
    && ok "weaken: precondition -- _a_gone is a strong regular bind from liba" \
    || bad "weaken: precondition" "$("$DMR" imports "$T/gone")"
rc=0; "$T/gone" 2>"$T/gone.err" || rc=$?
[ "$rc" -ne 0 ] && grep -q "Symbol not found" "$T/gone.err" \
    && ok "weaken: precondition -- with a_gone missing from liba, the program does not start" \
    || bad "weaken: precondition" "exit $rc: $(cat "$T/gone.err")"
rc=0; DYLD_LIBRARY_PATH="$T/v1" "$T/gone" || rc=$?
[ "$rc" -eq 9 ] && ok "weaken: precondition -- against v1 liba it calls a_gone (exit 9)" \
    || bad "weaken: precondition" "exit $rc against v1"

run "$T/gone" "$T/gone.weak" "import weaken _a_gone $LIBA"
[ "$run_rc" -eq 0 ] && ok "weaken: import weaken succeeds" \
    || bad "weaken: run" "exit $run_rc: $(cat "$T/run.err")"
[ "$(view "$T/gone" _a_gone "$LIBA" weak=1)" = "$("$DMR" imports "$T/gone.weak")" ] \
    && ok "weaken: ... imports changes in exactly one cell, _a_gone's weak" \
    || bad "weaken: imports" "$("$DMR" imports "$T/gone.weak")"
[ "$(field "$T/gone" bind 2)" = "$(field "$T/gone.weak" bind 2)" ] &&
    [ "$(field "$T/gone" bind 3)" = "$(field "$T/gone.weak" bind 3)" ] &&
    [ "$(wc -c <"$T/gone")" = "$(wc -c <"$T/gone.weak")" ] \
    && ok "weaken: ... in place: the bind stream's offset and size, and the file's size, are unchanged" \
    || bad "weaken: in place" "$("$MKB" info "$T/gone.weak")"
[ "$("$MKB" weakref "$T/gone" _a_gone)" = 0 ] && [ "$("$MKB" weakref "$T/gone.weak" _a_gone)" = 1 ] \
    && ok "weaken: ... and the symbol table's undefined _a_gone gains N_WEAK_REF" \
    || bad "weaken: nlist" "was $("$MKB" weakref "$T/gone" _a_gone), now $("$MKB" weakref "$T/gone.weak" _a_gone)"
grep -qF "weakened 1 bind (bind 1, lazy 0) and 1 nlist entry from ordinal $(ordinal_of "$T/gone" "$LIBA")" "$T/run.err" \
    && ok "weaken: ... and the report says what it weakened" \
    || bad "weaken: report" "$(cat "$T/run.err")"
rc=0; "$T/gone.weak" || rc=$?
[ "$rc" -eq 3 ] && ok "weaken: ... the program starts, and a_gone is NULL (exit 3)" \
    || bad "weaken: runs" "exit $rc"
rc=0; DYLD_LIBRARY_PATH="$T/v1" "$T/gone.weak" || rc=$?
[ "$rc" -eq 9 ] && ok "weaken: ... and where liba has a_gone, the weak import still binds it (exit 9)" \
    || bad "weaken: runs against v1" "exit $rc"

# ============================================================================
# weaken: a lazy bind
# ============================================================================
# DYLD_BIND_AT_LAUNCH makes 10.9's dyld bind lazies at launch, as dyld4 does
# anyway, so a missing lazy symbol is seen before main on both.
has_import "$T/lazygone" _a_gone_fn "$LIBA" lazy \
    && ok "weaken lazy: precondition -- _a_gone_fn is a lazy bind from liba" \
    || bad "weaken lazy: precondition" "$("$DMR" imports "$T/lazygone")"
rc=0; DYLD_BIND_AT_LAUNCH=1 "$T/lazygone" 2>"$T/lg.err" || rc=$?
[ "$rc" -ne 0 ] && grep -q "Symbol not found" "$T/lg.err" \
    && ok "weaken lazy: precondition -- bound at launch, the missing lazy symbol stops it" \
    || bad "weaken lazy: precondition" "exit $rc: $(cat "$T/lg.err")"
run "$T/lazygone" "$T/lazygone.weak" "import weaken _a_gone_fn $LIBA"
[ "$run_rc" -eq 0 ] && [ "$(view "$T/lazygone" _a_gone_fn "$LIBA" weak=1)" = "$("$DMR" imports "$T/lazygone.weak")" ] \
    && ok "weaken lazy: imports changes in exactly one cell" \
    || bad "weaken lazy: imports" "exit $run_rc: $(cat "$T/run.err")"
[ "$(field "$T/lazygone" lazy 2)" = "$(field "$T/lazygone.weak" lazy 2)" ] &&
    [ "$(field "$T/lazygone" lazy 3)" = "$(field "$T/lazygone.weak" lazy 3)" ] \
    && ok "weaken lazy: ... and the lazy stream did not move or change size" \
    || bad "weaken lazy: in place" "$("$MKB" info "$T/lazygone.weak")"
rc=0; DYLD_BIND_AT_LAUNCH=1 "$T/lazygone.weak" || rc=$?
[ "$rc" -eq 8 ] && ok "weaken lazy: ... bound at launch, it starts and calls a_fn (exit 8)" \
    || bad "weaken lazy: runs" "exit $rc"

# ============================================================================
# weaken: matching nothing
# ============================================================================
run "$T/gone" "$T/none.out" "import weaken _nosuch $LIBA"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/none.out" ] &&
    grep -qF "import weaken _nosuch $LIBA matched nothing" "$T/run.err" \
    && ok "weaken: matched nothing refuses by default, nothing written" \
    || bad "weaken: matched nothing" "exit $run_rc: $(cat "$T/run.err")"
run "$T/gone" "$T/none.out" allow-unmatched "import weaken _nosuch $LIBA"
[ "$run_rc" -eq 0 ] && grep -qF "import weaken _nosuch $LIBA matched nothing" "$T/run.err" \
    && ok "weaken: ... and allow-unmatched reports it instead" \
    || bad "weaken: allow-unmatched" "exit $run_rc: $(cat "$T/run.err")"
run "$T/gone" "$T/nolib.out" "import weaken _a_gone /no/such/lib.dylib"
[ "$run_rc" -eq 1 ] && grep -qF "matched nothing" "$T/run.err" \
    && ok "weaken: a library the image does not load matches nothing" \
    || bad "weaken: no such library" "exit $run_rc: $(cat "$T/run.err")"

reached_end=1
echo "bind_edit_test: $fails failure(s)"
[ "$fails" -eq 0 ]
```

Register the suite in `CMakeLists.txt`, directly after the `import_redirect_test` `add_test`:

```cmake
# `import weaken` and `import flatten`, against host-linked fixtures, a
# library rebuilt without the symbols they import, and hand-built bind streams.
add_test(NAME bind_edit_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/bind_edit_test.sh" "$<TARGET_FILE_DIR:drydock-macho-rewrite>")
```

- [ ] **Step 5: Run it to make sure it fails**

Run the build, then `ctest ... -R '^bind_edit_test$' --output-on-failure`.
Expected: the five preconditions PASS. Every `weaken` assertion FAILs with exit 2 and `drydock-macho-rewrite edit: cannot apply 'import weaken'`, because the row has no lowering yet.

- [ ] **Step 6: Write the core**

`src/weaken.h`:

```c
#ifndef DRYDOCK_WEAKEN_H
#define DRYDOCK_WEAKEN_H
/*
 * mwk_ -- `import weaken SYMBOL LIB`: every bind of SYMBOL that names LIB, in
 * the bind and lazy-bind streams, gets BIND_SYMBOL_FLAGS_WEAK_IMPORT, and
 * the symbol table's undefined SYMBOL from LIB gets N_WEAK_REF. The flag is
 * the symbol opcode's immediate, so nothing moves. One 64-bit slice at a time,
 * in memory.
 *
 * Returns 0 with *rep filled -- bind + lazy + nlist == 0 when nothing in this
 * slice matched, which is not a refusal -- or MR_REFUSED / MR_FAIL
 * (src/rewrite.h) with the reason on stderr, and *pbuf the image as it was.
 */
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int  from;
    long bind, lazy, nlist;
} mwk_report;

int mwk_weaken(uint8_t **pbuf, size_t *psize, const char *symbol, const char *from,
               mwk_report *rep);

#endif
```

`src/weaken.c`:

```c
/* weaken.c -- `import weaken`. See weaken.h. */
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#include "weaken.h"
#include "bindsel.h"
#include "image.h"
#include "ordinals.h"
#include "rewrite.h"
#include "mach_compat.h"

#define WHO "drydock-macho-rewrite: import weaken"

typedef struct { size_t *off; size_t n; } mwk_flips;

static void mwk_add(mwk_flips *f, size_t off) {
    size_t i;
    for (i = 0; i < f->n; i++)
        if (f->off[i] == off) return;
    f->off[f->n++] = off;
}

static int mwk_plan(const uint8_t *buf, const mbs_events *e, const mbs_sel *sel,
                    long *hits, mwk_flips *f) {
    size_t i;
    for (i = 0; i < e->n; i++) {
        const mo_bind_state *b = &e->v[i];
        if (!mbs_selected(sel, b)) continue;
        *hits += (long)b->count;
        mwk_add(f, (size_t)(b->sym_at - buf));
    }
    return 0;
}

static ptrdiff_t mwk_pos(const uint8_t *p, const uint8_t *base) {
    return p ? p - base : -1;
}

static int mwk_same(const char *stream, const mbs_events *before, const uint8_t *b0,
                    const mbs_events *after, const uint8_t *a0, const mbs_sel *sel) {
    size_t i;
    if (before->n != after->n) {
        mbs_say(WHO, "verification failed: the %s stream had %zu binds and now has "
                     "%zu; refusing\n", stream, before->n, after->n);
        return MR_REFUSED;
    }
    for (i = 0; i < before->n; i++) {
        const mo_bind_state *x = &before->v[i], *y = &after->v[i];
        int want = mbs_selected(sel, x) ? 1 : x->weak;
        int same_sym = (!x->symbol && !y->symbol) ||
                       (x->symbol && y->symbol && strcmp(x->symbol, y->symbol) == 0);
        if (!same_sym || y->weak != want || x->ordinal != y->ordinal ||
            x->seg != y->seg || x->type != y->type || x->offset != y->offset ||
            x->addend != y->addend || x->count != y->count || x->skip != y->skip ||
            x->len != y->len || memcmp(x->at, y->at, x->len) != 0 ||
            mwk_pos(x->at, b0) != mwk_pos(y->at, a0) ||
            mwk_pos(x->sym_at, b0) != mwk_pos(y->sym_at, a0)) {
            mbs_say(WHO, "verification failed: %s bind %zu (%s) is not what the "
                         "weaken meant it to be; refusing\n",
                    stream, i, x->symbol ? x->symbol : "-");
            return MR_REFUSED;
        }
    }
    return 0;
}

int mwk_weaken(uint8_t **pbuf, size_t *psize, const char *symbol, const char *from,
               mwk_report *rep) {
    uint8_t *buf = *pbuf, *nb = NULL;
    size_t size = *psize, k;
    mi_image im;
    mbs_slice s;
    mbs_sel sel;
    mbs_events bind, lazy, weak, nbind, nlazy;
    mwk_flips flips = { NULL, 0 };
    int rc;

    memset(rep, 0, sizeof *rep);
    memset(&bind, 0, sizeof bind); memset(&lazy, 0, sizeof lazy);
    memset(&weak, 0, sizeof weak); memset(&nbind, 0, sizeof nbind);
    memset(&nlazy, 0, sizeof nlazy);
    if ((rc = mbs_open(buf, size, WHO, &im, &s)) != 0) return rc;
    if (!(im.hdr->flags & MH_TWOLEVEL)) {
        mbs_say(WHO, "flat namespace: no import names a library, so there is none "
                     "to weaken\n");
        return MR_REFUSED;
    }
    mbs_select(&s, symbol, from, &sel);
    rep->from = sel.first;
    if (sel.nfrom == 0) return 0;
    if (!s.di) {
        mbs_say(WHO, "no LC_DYLD_INFO: this image binds through relocation entries, "
                     "which import weaken does not rewrite\n");
        return MR_REFUSED;
    }
    if ((rc = mbs_bounds(&s, size, WHO)) != 0) return rc;

    const struct dyld_info_command *di = s.di;
    if ((rc = mbs_walk(buf, di->bind_off, di->bind_size, "bind", WHO, &bind)) != 0 ||
        (rc = mbs_walk(buf, di->lazy_bind_off, di->lazy_bind_size, "lazy bind", WHO, &lazy)) != 0 ||
        (rc = mbs_walk(buf, di->weak_bind_off, di->weak_bind_size, "weak bind", WHO, &weak)) != 0)
        goto out;

    flips.off = malloc((bind.n + lazy.n + 1) * sizeof *flips.off);
    nb = malloc(size ? size : 1);
    if (!flips.off || !nb) { mbs_say(WHO, "out of memory\n"); rc = MR_FAIL; goto out; }
    if ((rc = mwk_plan(buf, &bind, &sel, &rep->bind, &flips)) != 0 ||
        (rc = mwk_plan(buf, &lazy, &sel, &rep->lazy, &flips)) != 0)
        goto out;

    memcpy(nb, buf, size);
    for (k = 0; k < flips.n; k++) nb[flips.off[k]] |= BIND_SYMBOL_FLAGS_WEAK_IMPORT;
    if (s.st) {
        struct nlist_64 *syms = (struct nlist_64 *)(nb + s.st->symoff);
        for (uint32_t q = 0; q < s.st->nsyms; q++) {
            if (!mbs_nlist_selected(nb, s.st, &syms[q], &sel)) continue;
            syms[q].n_desc |= N_WEAK_REF;
            rep->nlist++;
        }
    }

    if (memcmp(nb + di->weak_bind_off, buf + di->weak_bind_off, di->weak_bind_size) != 0) {
        mbs_say(WHO, "verification failed: the weak-bind stream changed; refusing\n");
        rc = MR_REFUSED;
        goto out;
    }
    if ((rc = mbs_walk(nb, di->bind_off, di->bind_size, "bind", WHO, &nbind)) != 0 ||
        (rc = mbs_walk(nb, di->lazy_bind_off, di->lazy_bind_size, "lazy bind", WHO, &nlazy)) != 0 ||
        (rc = mwk_same("bind", &bind, buf, &nbind, nb, &sel)) != 0 ||
        (rc = mwk_same("lazy bind", &lazy, buf, &nlazy, nb, &sel)) != 0)
        goto out;
    if (s.st) {
        const struct nlist_64 *was = (const struct nlist_64 *)(buf + s.st->symoff);
        const struct nlist_64 *now = (const struct nlist_64 *)(nb + s.st->symoff);
        for (uint32_t q = 0; q < s.st->nsyms; q++) {
            struct nlist_64 expect = was[q];
            if (mbs_nlist_selected(buf, s.st, &was[q], &sel)) expect.n_desc |= N_WEAK_REF;
            if (memcmp(&expect, &now[q], sizeof expect) != 0) {
                mbs_say(WHO, "verification failed: symbol-table entry %u is not what "
                             "the weaken meant it to be; refusing\n", q);
                rc = MR_REFUSED;
                goto out;
            }
        }
    }
    free(buf);
    *pbuf = nb;
    nb = NULL;
out:
    free(nb);
    free(flips.off);
    mbs_free(&bind); mbs_free(&lazy); mbs_free(&weak);
    mbs_free(&nbind); mbs_free(&nlazy);
    return rc;
}
```

Add `src/weaken.c` to `CMakeLists.txt:66` after `src/bindsel.c`.

- [ ] **Step 7: Lower it**

In `src/edit.c`, add `#include "weaken.h"` after `#include "redirect.h"`. Directly after `me_log_redirect`, add:

```c
static void me_log_weaken(FILE *log, const mwk_report *r, const char *symbol) {
    char c1[32], c2[32], c3[32], c4[32];
    long n = r->bind + r->lazy;
    if (n == 0 && r->nlist == 0) {
        me_say(log, "      no bind of %s names that library here\n", symbol);
    } else {
        me_say(log, "      weakened %s bind%s (bind %s, lazy %s) and %s nlist entr%s "
                    "from ordinal %d\n",
               me_count(c1, n), n == 1 ? "" : "s", me_count(c2, r->bind),
               me_count(c3, r->lazy), me_count(c4, r->nlist), r->nlist == 1 ? "y" : "ies",
               r->from);
    }
}
```

Directly after `me_rewrite`, add:

```c
static int me_import_verdict(const ms_script *s, const ms_stmt *st, me_verdict *v, long n) {
    *v->renamed += (int)n;
    if (!v->decide || *v->renamed > 0) return 0;
    me_say(stderr, "drydock-macho-rewrite: %s %s %s %s%s%s matched nothing\n",
           ms_kind_name(st->kind), ms_op_name(st->op), st->a, st->b,
           st->c ? " " : "", st->c ? st->c : "");
    if (!s->allow_unmatched) { v->missed = 1; return MR_REFUSED; }
    return 0;
}
```

Replace `case MS_IMPORT: { ... }` (`:410-422` at HEAD c8d5c21) with:

```c
    case MS_IMPORT: {
        if (st->op == MS_WEAKEN) {
            mwk_report w;
            int rc = mwk_weaken(pbuf, psize, st->a, st->b, &w);
            if (rc != 0) return rc;
            me_log_weaken(log, &w, st->a);
            return me_import_verdict(s, st, v, w.bind + w.lazy + w.nlist);
        }
        if (st->op != MS_REDIRECT) goto unknown;
        mrd_report r;
        int rc = mrd_redirect(pbuf, psize, st->a, st->b, st->c, &r);
        if (rc != 0) return rc;
        me_log_redirect(log, &r, st->a);
        return me_import_verdict(s, st, v, r.bind + r.lazy + r.nlist);
    }
```

The redirect verdict line is unchanged: `drydock-macho-rewrite: import redirect A B C matched nothing`.

- [ ] **Step 8: Run the tests and make sure they pass**

Run the build (confirm `weaken.c.o` and `edit.c.o` compiled), then the full `ctest`.
Expected: all PASS, including `bind_edit_test: 0 failure(s)` and `import_redirect_test: 0 failure(s)`.

- [ ] **Step 9: Mutation-prove**

- `nb[flips.off[k]] |= BIND_SYMBOL_FLAGS_WEAK_IMPORT;` → `|= 0;`: `mwk_same` refuses ("verification failed"), and every `weaken` success assertion FAILs. Then also change `int want = mbs_selected(sel, x) ? 1 : x->weak;` → `int want = x->weak;` (both at once): the run succeeds, but "imports changes in exactly one cell", "the program starts, and a_gone is NULL" and the lazy launch FAIL.
- `syms[q].n_desc |= N_WEAK_REF;` → `(void)0;`, with the matching `expect.n_desc |= N_WEAK_REF;` removed too: "gains N_WEAK_REF" FAILs.
- In `me_import_verdict`, `if (!s->allow_unmatched)` → `if (0)`: "matched nothing refuses by default" FAILs.
- `R("import", ... "weaken", ... MREL_NONE)` → `MREL_FILE_OFF`: the new `script_test` disturbs check FAILs.

Revert each one, and confirm the rebuild both times.

- [ ] **Step 10: Commit**

```bash
git add src/weaken.h src/weaken.c src/script.h src/script.c src/edit.c CMakeLists.txt \
        tests/mkbindstream.c tests/bind_edit_test.sh tests/script_test.c tests/cli_test.sh
git commit -m "feat(import): weaken a bind that already exists

import weaken SYMBOL LIB ORs BIND_SYMBOL_FLAGS_WEAK_IMPORT into the symbol
opcode of every bind and lazy bind of SYMBOL from LIB, and N_WEAK_REF into
its undefined symbol-table entry. Nothing moves. The result is walked again
and refused on any difference from what was meant.

A program whose library lacks a regular or lazily bound symbol stops at
launch before, and starts with the symbol NULL after.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 4: `import weaken`'s edges: shared symbol opcodes, already weak, weak binds, refusals, fat

**Files:**
- Modify: `src/weaken.h` (`mwk_report`), `src/weaken.c` (`mwk_plan`, `mwk_count`, `mwk_weaken`)
- Modify: `src/edit.c` (`me_log_weaken`)
- Test: `tests/bind_edit_test.sh` (insert before `reached_end=1`)

**Interfaces:**
- Consumes: `mwk_weaken`, `me_log_weaken` and the suite's helpers (Task 3).
- Produces: `mwk_report` becomes `{ int from; long bind, lazy, nlist, already, weak; }`. Adds `static long mwk_count(const mbs_events *e, const char *symbol, int ordinal);`, which counts binds of `symbol`, restricted to `ordinal` unless it is 0. Task 7 uses it.

- [ ] **Step 1: Write the failing tests**

Insert before `reached_end=1`:

```sh
# ============================================================================
# weaken: one symbol opcode serving two libraries
# ============================================================================
A=$(ordinal_of "$T/two" "$LIBA") B=$(ordinal_of "$T/two" "$LIBB")
"$MKB" set "$T/two" "$T/shared" bind "ord:$A" sym:_dup type:1 seg:2:0 do "ord:$B" do done
run "$T/shared" "$T/shared.out" "import weaken _dup $LIBA"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/shared.out" ] && grep -qF "they share one symbol opcode" "$T/run.err" \
    && ok "weaken shared: a symbol opcode serving liba's and libb's _dup is refused, nothing written" \
    || bad "weaken shared" "exit $run_rc: $(cat "$T/run.err")"
"$MKB" set "$T/two" "$T/sep" bind "ord:$A" sym:_dup type:1 seg:2:0 do "ord:$B" sym:_dup do done
run "$T/sep" "$T/sep.out" "import weaken _dup $LIBA"
[ "$run_rc" -eq 0 ] && [ "$(cell "$T/sep.out" _dup "$LIBA" bind weak)" = 1 ] &&
    [ "$(cell "$T/sep.out" _dup "$LIBB" bind weak)" = 0 ] \
    && ok "weaken shared: ... with a symbol opcode each, liba's _dup is weak and libb's is not" \
    || bad "weaken separate" "exit $run_rc: $("$DMR" imports "$T/sep.out" 2>&1)"

# ============================================================================
# weaken: already weak
# ============================================================================
cat >"$T/weakimp.c" <<'EOF'
extern int a_gone(void) __attribute__((weak_import));
int (*volatile p)(void) = a_gone;
int main(void) { return p ? p() : 3; }
EOF
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/weakimp" "$T/weakimp.c" "$V1"
[ "$(cell "$T/weakimp" _a_gone "$LIBA" bind weak)" = 1 ] \
    && ok "weaken already: precondition -- a weak_import declaration links a weak bind" \
    || bad "weaken already: precondition" "$("$DMR" imports "$T/weakimp")"
run "$T/weakimp" "$T/weakimp.out" "import weaken _a_gone $LIBA"
[ "$run_rc" -eq 0 ] && cmp -s "$T/weakimp" "$T/weakimp.out" \
    && ok "weaken already: matched, not refused, and the output is byte-identical to the input" \
    || bad "weaken already" "exit $run_rc: $(cat "$T/run.err")"
grep -qF "1 already weak, left as it was" "$T/run.err" \
    && ok "weaken already: ... and the report says so" \
    || bad "weaken already: report" "$(cat "$T/run.err")"

# ============================================================================
# weaken: the weak-bind table, and verification
# ============================================================================
"$MKB" set "$T/gone" "$T/wb" weak sym:_a_gone type:1 seg:2:0 do done
run "$T/wb" "$T/wb.out" "import weaken _a_gone $LIBA"
[ "$run_rc" -eq 0 ] &&
    grep -qF "WARNING: _a_gone appears in the weak-bind table 1 time; weak binds name no library, so it was not weakened" "$T/run.err" \
    && ok "weaken weak-bind: a weak bind of the symbol is warned about" \
    || bad "weaken weak-bind: warning" "exit $run_rc: $(cat "$T/run.err")"
[ "$(view "$T/wb" _a_gone "$LIBA" weak=1)" = "$("$DMR" imports "$T/wb.out")" ] \
    && ok "weaken weak-bind: ... and left alone, while the regular bind was weakened" \
    || bad "weaken weak-bind: untouched" "$("$DMR" imports "$T/wb.out")"
"$MKB" alias "$T/gone" "$T/alias"
run "$T/alias" "$T/alias.out" "import weaken _a_gone $LIBA"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/alias.out" ] && grep -qF "verification failed" "$T/run.err" \
    && ok "weaken verification: a weak-bind table overlapping the bind stream is caught, nothing written" \
    || bad "weaken verification: overlap" "exit $run_rc: $(cat "$T/run.err")"

# ============================================================================
# weaken: refusals
# ============================================================================
"$CC" -O2 -I "$HERE/../src" -o "$T/mkchained" "$HERE/mkchained.c"
"$T/mkchained" make "$T/chained"
run "$T/chained" "$T/chained.out" "import weaken _mkchained_sym /a"
[ "$run_rc" -eq 1 ] && grep -qF "put \`fixups set classic\` before this statement" "$T/run.err" \
    && ok "weaken chained: refused, naming fixups set classic as the remedy" \
    || bad "weaken chained" "exit $run_rc: $(cat "$T/run.err")"
"$CC" $FF -Wl,-flat_namespace -o "$T/flatns" "$T/gone.c" "$V1"
run "$T/flatns" "$T/flatns.out" "import weaken _a_gone $LIBA"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/flatns.out" ] &&
    grep -qF "flat namespace: no import names a library, so there is none to weaken" "$T/run.err" \
    && ok "weaken flat namespace: refused, nothing written" \
    || bad "weaken flat namespace" "exit $run_rc: $(cat "$T/run.err")"

# ============================================================================
# weaken: fat -- matched in one slice is matched
# ============================================================================
printf 'int main(void) { return 0; }\n' >"$T/nolib.c"
"$CC" $FF -o "$T/nolib" "$T/nolib.c"
"$BIN/makefat" "$T/fat" "$T/gone" 0x1000007 3 12 "$T/nolib" 0x1000007 8 12
run "$T/fat" "$T/fat.out" "import weaken _a_gone $LIBA"
n=$("$DMR" imports "$T/fat.out" | awk -F'\t' 'NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["symbol"] == "_a_gone" && $c["weak"] == 1 { n++ } END { print n + 0 }')
[ "$run_rc" -eq 0 ] && [ "$n" -eq 1 ] \
    && ok "weaken fat: the slice loading liba is weakened; the last slice, which does not, does not make it a miss" \
    || bad "weaken fat" "exit $run_rc, $n weak rows: $(cat "$T/run.err")"
```

- [ ] **Step 2: Run them to make sure they fail**

Run `ctest ... -R '^bind_edit_test$' --output-on-failure`.
Expected FAILs, each for its stated reason:
- "weaken shared ... refused" FAILs. The run refuses with `verification failed`, because the flip reached libb's bind, and not with `share one symbol opcode`.
- "weaken already: ... the report says so" FAILs, because no such line exists yet.
- "weaken weak-bind: a weak bind of the symbol is warned about" FAILs, because no warning exists yet.

Expected to pass on arrival, because Task 3's code already does these: the separate-opcode case, already-weak `cmp`, alias, chained, flat namespace, and fat. Step 5 proves each of them by mutation.

- [ ] **Step 3: Implement**

`src/weaken.h`: make the struct `long bind, lazy, nlist, already, weak;`.

`src/weaken.c`: replace `mwk_plan` with:

```c
static int mwk_plan(const uint8_t *buf, const mbs_events *e, const mbs_sel *sel,
                    const char *stream, long *hits, long *already, mwk_flips *f) {
    size_t i, j;
    for (i = 0; i < e->n; i++) {
        const mo_bind_state *b = &e->v[i];
        if (!mbs_selected(sel, b)) continue;
        *hits += (long)b->count;
        for (j = 0; j < e->n; j++) {
            if (e->v[j].sym_at == b->sym_at && !mbs_selected(sel, &e->v[j])) {
                mbs_say(WHO, "cannot weaken %s in the %s stream from this library "
                             "without also weakening its bind from ordinal %d: they "
                             "share one symbol opcode; refusing\n",
                        sel->symbol, stream, e->v[j].ordinal);
                return MR_REFUSED;
            }
        }
        if (b->weak) *already += (long)b->count;
        else         mwk_add(f, (size_t)(b->sym_at - buf));
    }
    return 0;
}

static long mwk_count(const mbs_events *e, const char *symbol, int ordinal) {
    long n = 0;
    size_t k;
    for (k = 0; k < e->n; k++)
        if (e->v[k].symbol && strcmp(e->v[k].symbol, symbol) == 0 &&
            (ordinal == 0 || e->v[k].ordinal == ordinal))
            n += (long)e->v[k].count;
    return n;
}
```

In `mwk_weaken`, replace the two `mwk_plan` calls with:

```c
    rep->weak = mwk_count(&weak, symbol, 0);
    if ((rc = mwk_plan(buf, &bind, &sel, "bind", &rep->bind, &rep->already, &flips)) != 0 ||
        (rc = mwk_plan(buf, &lazy, &sel, "lazy bind", &rep->lazy, &rep->already, &flips)) != 0)
        goto out;
```

`src/edit.c`, in `me_log_weaken`: inside the `else` branch, after the "weakened" line, add

```c
        if (r->already)
            me_say(log, "      %s already weak, left as %s\n", me_count(c1, r->already),
                   r->already == 1 ? "it was" : "they were");
```

and after the `if/else`, before the closing `}`:

```c
    if (r->weak)
        me_say(stderr, "WARNING: %s appears in the weak-bind table %s time%s; weak binds "
                       "name no library, so %s not weakened\n", symbol,
               me_count(c1, r->weak), r->weak == 1 ? "" : "s",
               r->weak == 1 ? "it was" : "they were");
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run the build (confirm `weaken.c.o` and `edit.c.o`), then the full `ctest`.
Expected: all PASS.

- [ ] **Step 5: Mutation-prove**

Each of these must turn its assertion red. Revert each one, and confirm the rebuild both times.
- Delete the inner `for (j ...)` sharing loop in `mwk_plan`: "weaken shared ... refused" FAILs (the run gets `verification failed`).
- `if (b->weak) *already += ...; else mwk_add(...)` → `mwk_add(...)` alone: "already: the report says so" FAILs.
- `rep->weak = mwk_count(&weak, symbol, 0);` → `rep->weak = 0;`: the weak-bind warning FAILs.
- In `mwk_weaken`, delete the weak-bind `memcmp` block: "weaken verification: overlap" FAILs. The edit to the bind stream is exactly what was meant, so `mwk_same` accepts it, and only the `memcmp` sees that the aliased weak-bind table changed with it.
- In `mbs_open`, delete the `if (s->chained) {...}` block: "weaken chained" FAILs.
- In `mwk_weaken`, delete the `MH_TWOLEVEL` check: "weaken flat namespace" FAILs (the run says `matched nothing` instead).
- In `me_import_verdict`, `*v->renamed += (int)n;` → `*v->renamed = (int)n;`: "weaken fat" FAILs, because the last slice, which lacks liba, overwrites the count with 0.
- In the separate-opcode fixture, make `mbs_selected` ignore `sel->from`: "liba's _dup is weak and libb's is not" FAILs.

- [ ] **Step 6: Commit**

```bash
git add src/weaken.h src/weaken.c src/edit.c tests/bind_edit_test.sh
git commit -m "feat(import): weaken refuses a shared symbol opcode, reports what it left

A symbol opcode serving a selected and an unselected bind is refused by
name rather than caught later by verification. An already-weak bind
counts as matched and is left alone, so weaken is idempotent. A weak-bind
entry of the symbol names no library, so it is warned about and left as
it was.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 5: `import flatten SYMBOL LIB`

**Files:**
- Modify: `src/redirect.h` (declare `mrd_flatten`), `src/redirect.c` (`mrd_redirect` → `mrd_retarget`, `mrd_encode_width`, `mrd_nlist_ord`)
- Modify: `src/script.h`, `src/script.c` (`MS_FLATTEN`, a row)
- Modify: `src/edit.c` (`me_log_redirect`, `case MS_IMPORT`)
- Test: `tests/script_test.c`, `tests/cli_test.sh`, `tests/bind_edit_test.sh`

**Interfaces:**
- Consumes: `mbs_*` (Task 2), `me_import_verdict` (Task 3).
- Produces:
  - `int mrd_flatten(uint8_t **pbuf, size_t *psize, const char *symbol, const char *from, mrd_report *rep);`, with `rep->to == MO_ORD_FLAT`.
  - `MS_FLATTEN`, appended after `MS_WEAKEN`.
  - Row `R("import", MS_IMPORT, "flatten", MS_FLATTEN, 2, NULL, 0, 0, MREL_FILE_OFF)`.
  - `static int mrd_retarget(uint8_t **pbuf, size_t *psize, const char *who, const char *verb, const char *symbol, const char *from, const char *to, mrd_report *rep);` where `to == NULL` means a flat lookup. Task 6 edits `mrd_encode_width`.

- [ ] **Step 1: Write the failing tests**

`tests/script_test.c`, after `test_import_weaken`, registered after it in `main`:

```c
static void test_import_flatten(void) {
    ms_script s; char err[256] = {0};
    const char *ok = "import flatten _getpid /usr/lib/libSystem.B.dylib\n";
    CHECK(ms_parse(ok, strlen(ok), &s, err, sizeof err) == 0, "flatten rejected: %s", err);
    CHECK(s.n == 1 && s.stmts[0].kind == MS_IMPORT && s.stmts[0].op == MS_FLATTEN,
          "wrong kind/op");
    CHECK(s.n == 1 && strcmp(s.stmts[0].a, "_getpid") == 0 &&
          strcmp(s.stmts[0].b, "/usr/lib/libSystem.B.dylib") == 0 && s.stmts[0].c == NULL,
          "operands are SYMBOL, LIB in that order");
    ms_free(&s);

    const char *three = "import flatten _getpid /a /b\n";
    err[0] = 0;
    CHECK(ms_parse(three, strlen(three), &s, err, sizeof err) == -1 &&
          strstr(err, "takes 2 arguments (got 3)") != NULL,
          "three operands refused for arity: %s", err);
}
```

In `test_capabilities_table_round_trips`, bump the row count Task 3 set by one more (both the `CHECK(n_rows == N` and its message) — Task 3 makes it 19 at HEAD c8d5c21, so Task 5 makes it 20. At the end of `test_disturbs_matches_the_spec_table`, add:

```c
    CHECK(ms_disturbs(MS_IMPORT, MS_FLATTEN) == MREL_FILE_OFF,
          "import flatten can move the bind stream within __LINKEDIT, as redirect can");
```

In `tests/cli_test.sh`, bump the count Task 3 set by one more, in the same three places (the two `-eq N` checks and the `"exactly N unique statement lines"` message) — Task 3 makes it 19 at HEAD, so Task 5 makes it 20 — and add after the weaken line:

```sh
echo "$caps" | grep -qxF "statement import flatten 2" \
    && ok "capabilities: import flatten is advertised" \
    || bad "capabilities: import flatten" "no 'statement import flatten 2' line: $(echo "$caps" | grep '^statement import')"
```

In `tests/bind_edit_test.sh`, insert before `reached_end=1`:

```sh
# ============================================================================
# flatten: a regular bind
# ============================================================================
run "$T/gone" "$T/gone.flat" "dylib append $SHIM" "import flatten _a_gone $LIBA"
[ "$run_rc" -eq 0 ] && ok "flatten: import flatten succeeds" \
    || bad "flatten: run" "exit $run_rc: $(cat "$T/run.err")"
[ "$(view "$T/gone" _a_gone "$LIBA" ordinal=flat kind=- install_name=-)" = "$("$DMR" imports "$T/gone.flat")" ] \
    && ok "flatten: ... imports changes in exactly _a_gone's ordinal, kind and install_name" \
    || bad "flatten: imports" "$("$DMR" imports "$T/gone.flat")"
[ "$(field "$T/gone" bind 2)" = "$(field "$T/gone.flat" bind 2)" ] &&
    [ "$(field "$T/gone" bind 3)" = "$(field "$T/gone.flat" bind 3)" ] \
    && ok "flatten: ... in place: the bind stream's offset and size are unchanged" \
    || bad "flatten: in place" "$("$MKB" info "$T/gone.flat")"
[ "$("$MKB" nlist "$T/gone.flat" _a_gone)" = 254 ] \
    && ok "flatten: ... and the symbol table's undefined _a_gone records DYNAMIC_LOOKUP_ORDINAL" \
    || bad "flatten: nlist" "ordinal $("$MKB" nlist "$T/gone.flat" _a_gone)"
grep -qF "flattened 1 bind (bind 1, lazy 0) and 1 nlist entry from ordinal $(ordinal_of "$T/gone" "$LIBA") to flat lookup" "$T/run.err" &&
    grep -qF "bind stream rewritten in place" "$T/run.err" \
    && ok "flatten: ... and the report says what it flattened, in place" \
    || bad "flatten: report" "$(cat "$T/run.err")"
rc=0; "$T/gone.flat" || rc=$?
[ "$rc" -eq 42 ] && ok "flatten: ... liba lacks a_gone, so the shim's is found (exit 42)" \
    || bad "flatten: runs" "exit $rc"
rc=0; DYLD_LIBRARY_PATH="$T/v1" "$T/gone.flat" || rc=$?
[ "$rc" -eq 9 ] && ok "flatten: ... and where liba has a_gone, liba's is found first (exit 9)" \
    || bad "flatten: runs against v1" "exit $rc"
run "$T/gone" "$T/gone.flatonly" "import flatten _a_gone $LIBA"
rc=0; "$T/gone.flatonly" 2>"$T/fo.err" || rc=$?
[ "$run_rc" -eq 0 ] && [ "$rc" -ne 0 ] && grep -q "Symbol not found" "$T/fo.err" \
    && ok "flatten: ... with nothing defining a_gone, a strong flat lookup still stops it" \
    || bad "flatten: alone" "edit exit $run_rc, run exit $rc: $(cat "$T/fo.err")"

# ============================================================================
# flatten: a lazy bind
# ============================================================================
run "$T/lazygone" "$T/lazygone.flat" "dylib append $SHIM" "import flatten _a_gone_fn $LIBA"
[ "$run_rc" -eq 0 ] &&
    [ "$(view "$T/lazygone" _a_gone_fn "$LIBA" ordinal=flat kind=- install_name=-)" = "$("$DMR" imports "$T/lazygone.flat")" ] \
    && ok "flatten lazy: imports changes in exactly _a_gone_fn's three cells" \
    || bad "flatten lazy: imports" "exit $run_rc: $(cat "$T/run.err")"
[ "$(field "$T/lazygone" lazy 2)" = "$(field "$T/lazygone.flat" lazy 2)" ] &&
    [ "$(field "$T/lazygone" lazy 3)" = "$(field "$T/lazygone.flat" lazy 3)" ] \
    && ok "flatten lazy: ... and the lazy stream did not move or change size" \
    || bad "flatten lazy: in place" "$("$MKB" info "$T/lazygone.flat")"
rc=0; DYLD_BIND_AT_LAUNCH=1 "$T/lazygone.flat" x || rc=$?
[ "$rc" -eq 43 ] && ok "flatten lazy: ... bound at launch, it calls the shim's a_gone_fn (exit 43)" \
    || bad "flatten lazy: runs" "exit $rc"

run "$T/gone" "$T/none.out" "import flatten _nosuch $LIBA"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/none.out" ] &&
    grep -qF "import flatten _nosuch $LIBA matched nothing" "$T/run.err" \
    && ok "flatten: matched nothing refuses by default, nothing written" \
    || bad "flatten: matched nothing" "exit $run_rc: $(cat "$T/run.err")"
```

- [ ] **Step 2: Run them to make sure they fail**

Run the build.
Expected: `script_test.c` fails to compile, with `'MS_FLATTEN' undeclared`.

- [ ] **Step 3: Implement**

`src/script.h`: append `MS_FLATTEN` after `MS_WEAKEN`. `src/script.c`: add a row after weaken's:

```c
  R("import",       MS_IMPORT,       "flatten",  MS_FLATTEN,      2, NULL,        0,             0, MREL_FILE_OFF)
```

(add the ` \` continuation to the weaken row above it).

`src/redirect.h`, after `mrd_redirect`'s declaration:

```c
/* `import flatten SYMBOL FROM-LIB`: mrd_redirect with the target a flat lookup
 * instead of a library, and each selected symbol-table entry's library ordinal
 * DYNAMIC_LOOKUP_ORDINAL. rep->to is MO_ORD_FLAT. */
int mrd_flatten(uint8_t **pbuf, size_t *psize, const char *symbol,
                const char *from, mrd_report *rep);
```

`src/redirect.c`:

(a) `mrd_encode_width` gets a flat branch at its top:

```c
static int mrd_encode_width(uint8_t *p, int ord, uint32_t width) {
    if (ord == MO_ORD_FLAT) {
        if (width != 1) return 0;
        p[0] = (uint8_t)(BIND_OPCODE_SET_DYLIB_SPECIAL_IMM |
                         (BIND_SPECIAL_DYLIB_FLAT_LOOKUP & BIND_IMMEDIATE_MASK));
        return 1;
    }
```

`mrd_encode_min` needs no change: its `ord <= BIND_IMMEDIATE_MASK` already gives `MO_ORD_FLAT` width 1.

(b) After `mrd_encode_min`, add:

```c
static uint8_t mrd_nlist_ord(int to) {
    return to == MO_ORD_FLAT ? DYNAMIC_LOOKUP_ORDINAL : (uint8_t)to;
}
```

and replace both `SET_LIBRARY_ORDINAL(d, (uint8_t)rep->to);` with `SET_LIBRARY_ORDINAL(d, mrd_nlist_ord(rep->to));`. Confirm with `git grep -n 'mrd_nlist_ord(rep->to)' src/redirect.c`, which must print 2 lines, and `git grep -n '(uint8_t)rep->to' src/redirect.c`, which must print nothing.

(c) Rename `int mrd_redirect(...)` to:

```c
static int mrd_retarget(uint8_t **pbuf, size_t *psize, const char *who, const char *verb,
                        const char *symbol, const char *from, const char *to,
                        mrd_report *rep) {
```

and delete its first line, `const char *who = WHAT;`. Replace the TO-LIB lookup and its refusal with:

```c
    if (to) {
        for (i = 1; i <= s.n && !rep->to; i++)
            if (strcmp(s.names[i], to) == 0) rep->to = i;
        if (!rep->to) {
            mbs_say(who, "%s is not a library this image loads; a statement "
                         "before this one must add it (dylib append %s)\n", to, to);
            return MR_REFUSED;
        }
    } else {
        rep->to = MO_ORD_FLAT;
    }
```

In the flat-namespace message, change `"is none to redirect\n"` to `"is none to %s\n", verb`. In the no-`LC_DYLD_INFO` message, change `"entries, which import redirect does not rewrite\n"` to `"entries, which import %s does not rewrite\n", verb`. At the end of the file, add:

```c
int mrd_redirect(uint8_t **pbuf, size_t *psize, const char *symbol,
                 const char *from, const char *to, mrd_report *rep) {
    return mrd_retarget(pbuf, psize, WHAT, "redirect", symbol, from, to, rep);
}

int mrd_flatten(uint8_t **pbuf, size_t *psize, const char *symbol,
                const char *from, mrd_report *rep) {
    return mrd_retarget(pbuf, psize, "drydock-macho-rewrite: import flatten", "flatten",
                        symbol, from, NULL, rep);
}
```

`src/edit.c`: replace `me_log_redirect` with:

```c
static void me_log_redirect(FILE *log, const mrd_report *r, const char *symbol) {
    char c1[32], c2[32], c3[32], c4[32], to[32];
    int flat = r->to == MO_ORD_FLAT;
    long n = r->bind + r->lazy;
    if (flat) snprintf(to, sizeof to, "flat lookup");
    else      snprintf(to, sizeof to, "ordinal %d", r->to);
    if (n == 0 && r->nlist == 0) {
        me_say(log, "      no bind of %s names that library here\n", symbol);
    } else {
        me_say(log, "      %s %s bind%s (bind %s, lazy %s) and %s nlist entr%s "
                    "from ordinal %d to %s\n", flat ? "flattened" : "redirected",
               me_count(c1, n), n == 1 ? "" : "s", me_count(c2, r->bind),
               me_count(c3, r->lazy), me_count(c4, r->nlist), r->nlist == 1 ? "y" : "ies",
               r->from, to);
    }
    if (r->bind_off_after != r->bind_off_before)
        me_say(log, "      bind stream grew from %s to %s bytes; it now lives at file "
                    "offset 0x%x, and __LINKEDIT grew from %s to %s bytes to cover it\n",
               me_count(c1, (long)r->bind_before), me_count(c2, (long)r->bind_after),
               r->bind_off_after, me_count(c3, (long)r->linkedit_before),
               me_count(c4, (long)r->linkedit_after));
    else if (r->bind)
        me_say(log, "      bind stream rewritten in place (%s bytes)\n",
               me_count(c1, (long)r->bind_after));
    if (r->weak)
        me_say(stderr, "WARNING: %s appears in the weak-bind table %s time%s; weak binds "
                       "name no library, so %s not %s\n", symbol,
               me_count(c1, r->weak), r->weak == 1 ? "" : "s",
               r->weak == 1 ? "it was" : "they were", flat ? "flattened" : "redirected");
}
```

In `case MS_IMPORT`, before `if (st->op != MS_REDIRECT) goto unknown;`, add:

```c
        if (st->op == MS_FLATTEN) {
            mrd_report f;
            int rc = mrd_flatten(pbuf, psize, st->a, st->b, &f);
            if (rc != 0) return rc;
            me_log_redirect(log, &f, st->a);
            return me_import_verdict(s, st, v, f.bind + f.lazy + f.nlist);
        }
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run the build (confirm `redirect.c.o`, `edit.c.o` and `script.c.o`), then the full `ctest`.
Expected: all PASS. `import_redirect_test` must pass unchanged. Its "redirected ... to ordinal", "not redirected" and "is not a library this image loads" greps are how that is known.

- [ ] **Step 5: Mutation-prove**

Revert each one, and confirm the rebuild both times.
- `mrd_nlist_ord`: `DYNAMIC_LOOKUP_ORDINAL` → `(uint8_t)to`: the verify refuses, or "records DYNAMIC_LOOKUP_ORDINAL" FAILs.
- In `mrd_encode_width`'s flat branch, `BIND_SPECIAL_DYLIB_FLAT_LOOKUP` → `BIND_SPECIAL_DYLIB_MAIN_EXECUTABLE`: `mrd_same` refuses ("verification failed"), and every flatten success FAILs. This proves the verify reads the ordinal back.
- `rep->to = MO_ORD_FLAT;` → `rep->to = -2;` (raw, not walker space): "flatten: import flatten succeeds" FAILs. The walker reads `MO_ORD_FLAT` back, which is not `-2`.
- `me_log_redirect`: `flat ? "flattened" : "redirected"` → `"redirected"`: "flatten: ... report" FAILs, and `import_redirect_test` still PASSes.
- The flatten row's `MREL_FILE_OFF` → `MREL_NONE`: the new disturbs check FAILs.

- [ ] **Step 6: Commit**

```bash
git add src/redirect.h src/redirect.c src/script.h src/script.c src/edit.c \
        tests/script_test.c tests/cli_test.sh tests/bind_edit_test.sh
git commit -m "feat(import): flatten a bind to a flat lookup

import flatten SYMBOL LIB is import redirect with the target spelled
BIND_SPECIAL_DYLIB_FLAT_LOOKUP, and n_desc's library ordinal
DYNAMIC_LOOKUP_ORDINAL. The target stays MO_ORD_FLAT, the walker's own
value, until the encoder writes it: raw -2 is MO_ORD_EXE there.

With a shim appended, a program whose library lacks the symbol calls the
shim's, and against a library that has it, the library's.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 6: `import flatten`'s edges: wide lazy ordinals, growth, sharing, fat, refusals

**Files:**
- Modify: `src/redirect.c` (`mrd_encode_width`'s flat branch)
- Modify: `tests/mkbindstream.c` (`hex`)
- Test: `tests/bind_edit_test.sh` (insert before `reached_end=1`)

**Interfaces:**
- Consumes: `mrd_flatten` (Task 5), the fat and chained fixtures (Task 4: `$T/nolib`, `$T/chained`, `$T/flatns`).
- Produces: `mkbindstream hex FILE bind|weak|lazy` prints that stream's bytes as space-separated lowercase hex pairs.

- [ ] **Step 1: Write the failing tests**

`tests/mkbindstream.c`: add `mkbindstream hex FILE bind|weak|lazy` to the usage list and `` `hex` prints that stream's bytes, as space-separated hex pairs. `` to the description. Add it to `main` before the final usage check:

```c
    if (argc == 4 && strcmp(argv[1], "hex") == 0) {
        uint8_t *b = slurp(argv[2], &n);
        uint32_t off, sz;
        find(b, &di, &le);
        if (strcmp(argv[3], "bind") == 0)      { off = di->bind_off;      sz = di->bind_size; }
        else if (strcmp(argv[3], "weak") == 0) { off = di->weak_bind_off; sz = di->weak_bind_size; }
        else if (strcmp(argv[3], "lazy") == 0) { off = di->lazy_bind_off; sz = di->lazy_bind_size; }
        else { fprintf(stderr, "unknown stream '%s'\n", argv[3]); return 2; }
        for (uint32_t i = 0; i < sz; i++) printf("%s%02x", i ? " " : "", b[off + i]);
        printf("\n");
        return 0;
    }
```

Add `| hex FILE bind|weak|lazy` to the usage `fprintf`.

`tests/bind_edit_test.sh`, before `reached_end=1`:

```sh
# ============================================================================
# flatten: a lazy ordinal above 15, in a two-byte opcode
# ============================================================================
i=1; libs=""; decls=""
while [ "$i" -le 16 ]; do
    printf 'int f%d(void) { return %d; }\n' "$i" "$i" >"$T/f$i.c"
    "$CC" -dynamiclib $FF -install_name "$T/lib/libf$i.dylib" -o "$T/lib/libf$i.dylib" "$T/f$i.c"
    libs="$libs $T/lib/libf$i.dylib"; decls="$decls int f$i(void);"
    i=$((i + 1))
done
printf '#include <stdio.h>\n%s\nint (*p)(void) = f1;\nint main(void) { printf("%%d %%d\\n", p(), f16()); return 0; }\n' \
    "$decls" >"$T/many.c"
# shellcheck disable=SC2086
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/many" "$T/many.c" $libs
F16=$(ordinal_of "$T/many" "$T/lib/libf16.dylib")
wide=$(printf '20 %02x' "${F16:-0}")
[ "${F16:-0}" -gt 15 ] && has_import "$T/many" _f16 "$T/lib/libf16.dylib" lazy &&
    case " $("$MKB" hex "$T/many" lazy) " in *" $wide "*) true ;; *) false ;; esac \
    && ok "flatten wide: precondition -- _f16 binds lazily from ordinal $F16, a two-byte opcode ($wide)" \
    || bad "flatten wide: precondition" "ordinal ${F16:-none}: $("$MKB" hex "$T/many" lazy)"
run "$T/many" "$T/many.flat" "import flatten _f16 $T/lib/libf16.dylib"
[ "$run_rc" -eq 0 ] && [ "$(cell "$T/many.flat" _f16 - lazy ordinal)" = flat ] \
    && ok "flatten wide: _f16's lazy bind is a flat lookup" \
    || bad "flatten wide: run" "exit $run_rc: $(cat "$T/run.err")"
[ "$(field "$T/many" lazy 2)" = "$(field "$T/many.flat" lazy 2)" ] &&
    [ "$(field "$T/many" lazy 3)" = "$(field "$T/many.flat" lazy 3)" ] \
    && ok "flatten wide: ... the lazy stream did not move or change size" \
    || bad "flatten wide: in place" "$("$MKB" info "$T/many.flat")"
case " $("$MKB" hex "$T/many.flat" lazy) " in *" 3e 3e "*) f=1 ;; *) f=0 ;; esac
case " $("$MKB" hex "$T/many" lazy) " in *" 3e 3e "*) g=1 ;; *) g=0 ;; esac
[ "$f" -eq 1 ] && [ "$g" -eq 0 ] \
    && ok "flatten wide: ... the two-byte opcode became two flat-lookup opcodes (3e 3e), absent before" \
    || bad "flatten wide: filler" "after: $("$MKB" hex "$T/many.flat" lazy)"
[ "$(DYLD_BIND_AT_LAUNCH=1 "$T/many.flat")" = "1 16" ] \
    && ok "flatten wide: ... and bound at launch, libf16's f16 is found by flat lookup" \
    || bad "flatten wide: runs" "printed '$(DYLD_BIND_AT_LAUNCH=1 "$T/many.flat" 2>&1)'"

# ============================================================================
# flatten: a regular stream that has to grow
# ============================================================================
A=$(ordinal_of "$T/gone" "$LIBA")
"$MKB" set "$T/gone" "$T/grow" bind "ord:$A" sym:_x type:1 seg:2:0 do sym:_y do done
run "$T/grow" "$T/grow.out" "import flatten _x $LIBA"
[ "$run_rc" -eq 0 ] && [ "$(cell "$T/grow.out" _x - bind ordinal)" = flat ] &&
    has_import "$T/grow.out" _y "$LIBA" bind \
    && ok "flatten grow: _x is a flat lookup and _y still names liba" \
    || bad "flatten grow" "exit $run_rc: $(cat "$T/run.err")"
grep -q "bind stream grew from [0-9,]* to [0-9,]* bytes; it now lives at file offset 0x" "$T/run.err" &&
    [ "$(field "$T/grow.out" bind 2)" != "$(field "$T/grow" bind 2)" ] &&
    [ "$(field "$T/grow.out" linkedit 2)" -gt "$(field "$T/grow" linkedit 2)" ] \
    && ok "flatten grow: ... it moved, __LINKEDIT grew to cover it, and stderr says so" \
    || bad "flatten grow: moved" "$("$MKB" info "$T/grow.out"): $(cat "$T/run.err")"

# ============================================================================
# flatten: sharing, the weak-bind table, refusals, fat
# ============================================================================
A=$(ordinal_of "$T/two" "$LIBA")
"$MKB" set "$T/two" "$T/lshared" lazy seg:2:0 "ord:$A" sym:_a_fn do sym:_dup do done
run "$T/lshared" "$T/lshared.out" "import flatten _a_fn $LIBA"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/lshared.out" ] && grep -qF "share one library-ordinal opcode" "$T/run.err" \
    && ok "flatten shared lazy: refused, nothing written" \
    || bad "flatten shared lazy" "exit $run_rc: $(cat "$T/run.err")"
run "$T/wb" "$T/wbf.out" "import flatten _a_gone $LIBA"
[ "$run_rc" -eq 0 ] &&
    grep -qF "WARNING: _a_gone appears in the weak-bind table 1 time; weak binds name no library, so it was not flattened" "$T/run.err" \
    && ok "flatten weak-bind: warned about, in flatten's own words" \
    || bad "flatten weak-bind" "exit $run_rc: $(cat "$T/run.err")"
run "$T/chained" "$T/chainedf.out" "import flatten _mkchained_sym /a"
[ "$run_rc" -eq 1 ] && grep -qF "import flatten: the image uses LC_DYLD_CHAINED_FIXUPS" "$T/run.err" \
    && ok "flatten chained: refused, under its own name" \
    || bad "flatten chained" "exit $run_rc: $(cat "$T/run.err")"
run "$T/flatns" "$T/flatnsf.out" "import flatten _a_gone $LIBA"
[ "$run_rc" -eq 1 ] && grep -qF "so there is none to flatten" "$T/run.err" \
    && ok "flatten flat namespace: refused" \
    || bad "flatten flat namespace" "exit $run_rc: $(cat "$T/run.err")"
run "$T/fat" "$T/fatf.out" "dylib append $SHIM" "import flatten _a_gone $LIBA"
n=$("$DMR" imports "$T/fatf.out" | awk -F'\t' 'NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["symbol"] == "_a_gone" && $c["ordinal"] == "flat" { n++ } END { print n + 0 }')
[ "$run_rc" -eq 0 ] && [ "$n" -eq 1 ] \
    && ok "flatten fat: the slice loading liba is flattened, and the run is not a miss" \
    || bad "flatten fat" "exit $run_rc, $n flat rows: $(cat "$T/run.err")"
```

- [ ] **Step 2: Run them to make sure they fail**

Run the build and `ctest ... -R '^bind_edit_test$' --output-on-failure`.
Expected: the four "flatten wide" assertions after the precondition FAIL. The run exits 1 with `cannot encode ordinal -3 in the 2-byte ordinal opcode of _f16's lazy bind`, because Task 5's flat branch accepts only width 1. The remaining new assertions pass on arrival: growth, sharing and the refusals are `import redirect`'s machinery, and the warning's wording is Task 5's. Step 5 proves them by mutation.

- [ ] **Step 3: Implement**

In `src/redirect.c`, replace the flat branch of `mrd_encode_width` with:

```c
    if (ord == MO_ORD_FLAT) {
        for (uint32_t i = 0; i < width; i++)
            p[i] = (uint8_t)(BIND_OPCODE_SET_DYLIB_SPECIAL_IMM |
                             (BIND_SPECIAL_DYLIB_FLAT_LOOKUP & BIND_IMMEDIATE_MASK));
        return 1;
    }
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run the build (confirm `redirect.c.o`), then the full `ctest`.
Expected: all PASS.

- [ ] **Step 5: Mutation-prove**

Revert each one, and confirm the rebuild both times.
- The fill loop writes `0x51` (`BIND_OPCODE_SET_TYPE_IMM | BIND_TYPE_POINTER`) for `i >= 1`: "flatten wide: _f16's lazy bind is a flat lookup" FAILs. `mrd_same` refuses because the lazy program's `type` reads back 1, not 0. This is the spec's reason for not using the queue's filler, shown on a real binary.
- `for (uint32_t i = 0; i < width; i++)` → `i < 1`: the trailing ULEB byte survives as a stray opcode. Verification refuses, or "3e 3e" FAILs.
- In `mrd_retarget`, `if (nbind.n <= di->bind_size)` → `if (1)`: "flatten grow" FAILs.
- Delete the lazy shared-ordinal loop in `mrd_retarget` (`for (j = 0; j < lazy.n; j++) { if (lazy.v[j].ord_at == b->ord_at ...`): "flatten shared lazy" FAILs. Check that `import_redirect_test`'s "shared lazy" FAILs under the same mutation too.

- [ ] **Step 6: Commit**

```bash
git add src/redirect.c tests/mkbindstream.c tests/bind_edit_test.sh
git commit -m "feat(import): flatten a lazy bind whose ordinal opcode is wider than one byte

A lazy program cannot move, and SET_DYLIB_SPECIAL_IMM is one byte, so a
SET_DYLIB_ORDINAL_ULEB is replaced by as many flat-lookup opcodes as it
had bytes. Each re-sets the same ordinal. SET_TYPE_IMM(POINTER) filler
would change the type in effect in a program that never set one, and the
verification after the rewrite rightly refuses it.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 7: Weaken, then flatten

**Files:**
- Modify: `src/weaken.h` (`mwk_report.flat`), `src/weaken.c` (count it), `src/edit.c` (`me_log_weaken`'s hint)
- Test: `tests/bind_edit_test.sh` (insert before `reached_end=1`)

**Interfaces:**
- Consumes: `mwk_count` (Task 4), `mrd_flatten` (Task 5).
- Produces: `mwk_report` becomes `{ int from; long bind, lazy, nlist, already, weak, flat; }`, where `flat` is the number of binds of SYMBOL in the bind and lazy streams whose ordinal is a flat lookup.

- [ ] **Step 1: Write the failing tests**

```sh
# ============================================================================
# weaken, then flatten: what a stub dylib covers, and what it does not
# ============================================================================
cat >"$T/both.c" <<'EOF'
int a_gone(void); int a_gone2(void);
int (*volatile p)(void) = a_gone;
int (*volatile q)(void) = a_gone2;
int main(void) { return (p ? p() : 0) + (q ? 100 : 0); }
EOF
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/both" "$T/both.c" "$V1"
run "$T/both" "$T/both.out" "dylib append $SHIM" \
    "import weaken _a_gone $LIBA" "import weaken _a_gone2 $LIBA" \
    "import flatten _a_gone $LIBA" "import flatten _a_gone2 $LIBA"
[ "$run_rc" -eq 0 ] &&
    [ "$(cell "$T/both.out" _a_gone - bind weak)" = 1 ] && [ "$(cell "$T/both.out" _a_gone - bind ordinal)" = flat ] &&
    [ "$(cell "$T/both.out" _a_gone2 - bind weak)" = 1 ] && [ "$(cell "$T/both.out" _a_gone2 - bind ordinal)" = flat ] \
    && ok "both: each bind is weak and a flat lookup; flatten kept the weak flag" \
    || bad "both: imports" "exit $run_rc: $("$DMR" imports "$T/both.out" 2>&1)"
rc=0; "$T/both.out" || rc=$?
[ "$rc" -eq 42 ] && ok "both: ... the shim covers a_gone (42) and a_gone2 is NULL (+0)" \
    || bad "both: runs" "exit $rc"
rc=0; DYLD_LIBRARY_PATH="$T/v1" "$T/both.out" || rc=$?
[ "$rc" -eq 109 ] && ok "both: ... and against v1 liba both are liba's (9 + 100)" \
    || bad "both: runs against v1" "exit $rc"

run "$T/both" "$T/wrong.out" "import flatten _a_gone $LIBA" "import weaken _a_gone $LIBA"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/wrong.out" ] &&
    grep -qF "import weaken _a_gone $LIBA matched nothing" "$T/run.err" &&
    grep -qF "1 bind of _a_gone is a flat lookup, which names no library: weaken before flatten" "$T/run.err" \
    && ok "both: flatten before weaken refuses, and says which order works" \
    || bad "both: wrong order" "exit $run_rc: $(cat "$T/run.err")"
# libb is loaded and names no bind of _a_fn, which binds (lazily, not flat)
# from liba: a miss, but not one a flat lookup explains.
grep -qF "is a flat lookup, which names no library" "$T/run.err" &&
    run "$T/two" "$T/none2.out" "import weaken _a_fn $LIBB" && [ "$run_rc" -eq 1 ] &&
    ! grep -qF "is a flat lookup, which names no library" "$T/run.err" \
    && ok "both: ... and a miss whose binds are not flat lookups carries no such hint" \
    || bad "both: hint only when earned" "$(cat "$T/run.err")"
```

The last assertion's first `grep` is the positive control for its negated `grep`.

- [ ] **Step 2: Run them to make sure they fail**

Expected: the `both:` assertions for imports and the two runs PASS on arrival. Task 5's `mrd_same` already keeps `weak`, and they are proven in Step 5. "flatten before weaken refuses, and says which order works" FAILs, because there is no hint line. "a miss whose binds are not flat lookups carries no such hint" FAILs on its positive control, because the first `grep` finds nothing.

- [ ] **Step 3: Implement**

`src/weaken.h`: `long bind, lazy, nlist, already, weak, flat;`.

`src/weaken.c`, in `mwk_weaken`, directly after `rep->weak = mwk_count(&weak, symbol, 0);`, add:

```c
    rep->flat = mwk_count(&bind, symbol, MO_ORD_FLAT) + mwk_count(&lazy, symbol, MO_ORD_FLAT);
```

The misordered case always reaches this line, past the `sel.nfrom == 0` early return: flatten does not remove LIB's load command, so `sel.nfrom` is still at least 1.

`src/edit.c`, in `me_log_weaken`'s `n == 0 && r->nlist == 0` branch, after the "no bind" line:

```c
        if (r->flat)
            me_say(log, "      %s bind%s of %s %s a flat lookup, which names no library: "
                        "weaken before flatten\n", me_count(c1, r->flat),
                   r->flat == 1 ? "" : "s", symbol, r->flat == 1 ? "is" : "are");
```

The misordered flatten also rewrites the symbol table's ordinal to `DYNAMIC_LOOKUP_ORDINAL`, so `rep->nlist` is 0 there, and this branch is the one taken.

- [ ] **Step 4: Run the tests and make sure they pass**

Run the build (confirm `weaken.c.o` and `edit.c.o`), then the full `ctest`.
Expected: all PASS.

- [ ] **Step 5: Mutation-prove**

Revert each one, and confirm the rebuild both times.
- `rep->flat = ...` → `rep->flat = 0;`: "says which order works" FAILs.
- `MO_ORD_FLAT` → `0` in both `mwk_count` calls, so any bind of the symbol counts: "a miss whose binds are not flat lookups carries no such hint" FAILs, because `_a_fn`'s liba bind is now counted.
- On the test side, delete the two `import weaken` lines from the `both` run: "each bind is weak and a flat lookup" FAILs, and so does "the shim covers a_gone ... a_gone2 is NULL", because a strong flat lookup of `a_gone2` stops the program. So both assertions depend on the weak flag surviving flatten.
- Deleting `x->weak != y->weak ||` from `mrd_same` is a **surviving** mutation: nothing in `mrd_retarget` writes a symbol opcode, so no current code can clear the flag. The check guards future code. Say so in the commit message rather than claiming the test pins it.

- [ ] **Step 6: Commit**

```bash
git add src/weaken.h src/weaken.c src/edit.c tests/bind_edit_test.sh
git commit -m "feat(import): say to weaken before flatten when the order is wrong

A flattened bind names no library, so import weaken of it matches nothing
and refuses. The refusal's report now counts the flat-lookup binds of the
symbol and says which order works. Weakened and then flattened, a symbol
the shim defines calls the shim's, and one it does not is NULL.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 8: README

**Touch only the lines this feature adds.** Do not reflow, reword or "fix" any neighbouring line.

**Files:**
- Modify: `README.md` (Statements block, `:56-77` at HEAD c8d5c21, the `import        redirect  SYMBOL FROM-LIB TO-LIB` line is at `:74`; the "can match nothing" list, header `:119`, the `` - `import redirect` `` item at `:124`; a new subsection directly before `### Queries`, at `:259` at HEAD)

**Interfaces:**
- Consumes: the statements as built.
- Produces: documentation only.

- [ ] **Step 1: Write the check first**

Run `git grep -n 'import weaken\|import flatten' README.md`. It must print nothing. The positive control is `git grep -nE 'import +redirect' README.md` (not a plain `-n 'import redirect'`, which finds only 1 line — the Statements block spells it `import        redirect` with multi-space alignment, which a single-space pattern misses). At HEAD c8d5c21, `git grep -nE 'import +redirect' README.md` prints exactly 2 lines: `README.md:74:import        redirect  SYMBOL FROM-LIB TO-LIB` and `` README.md:124:- `import redirect` (no bind of that symbol names that library) ``.

- [ ] **Step 2: Edit**

In the Statements code block, directly after `import        redirect  SYMBOL FROM-LIB TO-LIB`:

```
import        weaken    SYMBOL LIB
import        flatten   SYMBOL LIB
```

In the "can match nothing" list, directly after `` - `import redirect` (no bind of that symbol names that library) ``:

```
- `import weaken` and `import flatten` (no bind of that symbol names that library)
```

Directly before `### Queries`:

```
### `import weaken` and `import flatten`

Each selects the binds of SYMBOL whose library is LIB, as
`drydock-macho-rewrite imports` prints them in its `symbol` and `install_name`
columns.

`import weaken` makes each one a weak import: if the symbol is missing at
launch, it is bound to NULL instead of stopping the program. Nothing moves.

`import flatten` makes each one a flat lookup: dyld takes the symbol from the
first loaded image that defines it. A shim added with `dylib append` loads
last, so it is used only where the library lacks the symbol. The bind stream
may grow, and if it does, the report says so.

Weaken before flatten. A flattened bind names no library, so a later
`import weaken` of it matches nothing. A weak-bind table entry names no
library either, so neither statement edits one, and each warns about it.
```

- [ ] **Step 3: Check it**

Run `git diff --stat README.md`: expect one file, with only insertions. Run `git diff README.md | grep '^-' | grep -v '^---'`: it must print nothing. The positive control is `git diff README.md | grep -c '^+'`, which must be greater than 0.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add import weaken and import flatten to the README

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

## Before starting: the owner's open questions

The spec's "Questions for the owner" section has five questions. This plan
implements every recommendation: two new `import` ops, exact pairs with no
wildcards, `0x3E` filler, order enforced by matched-nothing plus a hint, and
no new query. If the owner decides any of them differently, fix these tasks
before starting:

| decision | tasks it changes |
|---|---|
| spelling | 3, 5, 8 (grammar, tests, README) |
| wildcards | a new task after 7, confined to `mbs_select` and `mbs_selected`, plus parse checks |
| filler | 6 (and its mutation, which becomes the implementation) |
| ordering | 7 |
| a symbol-table query | a new task, `cli/drydock-macho-rewrite.c` |
