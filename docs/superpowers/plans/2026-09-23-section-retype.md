# `section retype` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `info` name every section's type, then add a `section retype SEG,SECT FROM TO` statement that turns `S_NON_LAZY_SYMBOL_POINTERS` or `S_SYMBOL_STUBS` into `S_REGULAR`, one byte per section, and refuses where doing so would leave pointers unbound.

**Architecture:** A new module `src/section.[ch]` (`msec_`) holds the section-type name table, the `SEG,SECT` splitter and the retype core. `cli/drydock-macho-rewrite.c`'s `info_cb` prints each type through the table. `src/script.c` gains one `MS_TABLE_ROWS` row and its operand checks. `src/edit.c` gains one `me_apply` case that counts matches the way `segment rename` does. `src/grow.c` is not changed. The spec proves the `grow` tension does not exist, and Task 5 pins that with a byte-identity test.

**Tech Stack:** C99, CMake + CTest via shipyard, POSIX `/bin/sh` test suites, hermetic C test binaries.

**Spec:** `docs/superpowers/specs/2026-09-23-section-retype-design.md`

**Before starting:** the spec's "Questions for the owner" #1 asks whether to build Tasks 2–6 at all. Task 1 stands alone. Do not start Task 2 without the owner's answer.

## Global Constraints

- **TDD, mutation-proven.** Write every test first and watch it fail. After it passes, apply the task's named mutations one at a time. Rebuild, **confirm the rebuild happened**, watch the named test go red, then restore the code exactly. This host has clock skew, so a rebuild can silently not happen. Confirm each one: the build output must name the object for the file you changed (for example `Building C object CMakeFiles/drydockcore.dir/src/section.c.o`). If it does not, `touch` the file and build again.
- **Comments are a last resort.** Say it in a test first, then the commit message, then a doc, and only then one inline sentence. No history narration ("used to", "was", "now"). No reference to this plan, the spec or a task number in any source file.
- **Build:** `/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j`
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native`. Add `-R <name> --output-on-failure` for one suite. Every task ends with the full, unfiltered run green.
- **Exit codes:** `EX_REFUSED` = `MR_REFUSED` = 1, `EX_FAIL` = `MR_FAIL` = 2 (`cli/drydock-macho-rewrite.c:151-152`, `src/rewrite.h`).
- **Names are `char[16]`, not always NUL-terminated.** Print with `%.16s`. Compare with `strncmp(field, name, 16)` (`MSEG_NAME_MAX`, `src/segname.h`).
- **Every grep negative needs a positive control.** Before asserting that a pattern is absent, show that the same pattern finds something it should. The harness's `grep` is ugrep and skips gitignored files, so use `git grep` for sweeps of the repository.
- **Shell suites capture a status with `rc=0; cmd || rc=$?`**, never `cmd; rc=$?`.
- **`README.md` is touched only by Task 6**, and only on the lines this feature adds.
- **Stage explicit paths only.** Never `git add -A` or `git add .`: other agents may be working in this tree.
- **No test in this plan may match `src/grow.c`'s stderr text.** Item 6's comment sweep is rewriting its `macho_grow:` prefixes. Read growth from `info` instead.
- Every commit message ends with exactly:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
  ```

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `src/section.h`, `src/section.c` (new) | type names, `SEG,SECT` split, the retype core | 1, 2 |
| `tests/section_test.c` (new) | hermetic tests of `src/section.c` | 1, 2 |
| `tests/secttypes.c` (new) | independent reader/patcher of section types, for the shell suite | 1 |
| `tests/section_retype_test.sh` (new) | `info` types and the statement against a host-linked binary | 1, 5 |
| `cli/drydock-macho-rewrite.c` | `info_cb` prints `      type=` | 1 |
| `CMakeLists.txt` | `src/section.c` in `drydockcore`; two `add_test`s | 1 |
| `tests/README.md` | a row per new suite | 1 |
| `src/script.h`, `src/script.c` | `MS_SECTION`, the row, operand checks | 3 |
| `src/edit.c` | the `MS_SECTION` lowering | 3 |
| `tests/script_test.c`, `tests/cli_test.sh` | grammar; row count 17 → 18 | 3 |
| `tests/edit_test.c` | statement semantics, thin and fat | 3, 4 |
| `README.md` | the user-facing grammar and query | 6 |

**Shared with plans drafting in parallel:** `src/script.[ch]`, `src/edit.c`, `tests/script_test.c`, `tests/cli_test.sh` (all rebase the 17-row count: whoever lands second bumps it), `cli/drydock-macho-rewrite.c` (`info_cb`), `CMakeLists.txt`, `README.md`. `src/grow.c` is shared **only** as Task 5's temporary mutation, which is never committed.

---

### Task 1: `info` names each section's type

**Files:**
- Create: `src/section.h`, `src/section.c`, `tests/section_test.c`, `tests/secttypes.c`, `tests/section_retype_test.sh`
- Modify: `cli/drydock-macho-rewrite.c:81-94` (includes), `:401-404` (`info_cb`'s section loop)
- Modify: `CMakeLists.txt:66` (`drydockcore` sources), and add two tests after `:216` (`trie_test`) and `:390` (`import_redirect_test`)
- Modify: `tests/README.md` (two rows, after `trie_test`'s)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `const char *msec_type_name(uint32_t type);`, which returns NULL for a value outside `0x00`–`0x16`. It also produces the `info` line `      type=NAME` or `      type=0x%02x` under every `    sectname=` line, the `tests/secttypes` helper (`list FILE` prints `SEG SECT 0xTT FLAGS-OFFSET` per section; `set FILE SEG SECT T OUT`), and the `tests/section_retype_test.sh` skeleton that Task 5 extends.

- [ ] **Step 1: Sweep `info`'s consumers, with a positive control**

Run:

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git grep -n -e 'rewrite" info' -e 'rewrite info' -e 'DMR" info' -e 'REWRITE" info' -- compat tests
```

Positive control: the output must include `compat/insert_dylib.sh:91` and `tests/grown_binary_runs_test.sh:54`. If either is missing, the pattern is wrong: fix the pattern, not the conclusion. For each hit, read the pattern applied to `info`'s output and confirm it cannot match a line that is six spaces, `type=`, then a lower-case hyphenated word or `0x` and two hex digits. Anchored patterns (`^  ordinal=`, `^LC\[`, `^header pad: `, `^    sectname=`) cannot. The unanchored ones look for `LC_`, `path=`, `__DATA_F1` or `segname=__TEXT `, and no type name contains any of those. Record the hit count and the verdict in the commit message.

- [ ] **Step 2: Write the failing C test**

Create `tests/section_test.c`:

```c
/*
 * tests/section_test.c -- hermetic tests for src/section.c, against images
 * built here by hand.
 */
#include "section.h"
#include "image.h"
#include "mach_compat.h"

#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

static void test_every_defined_type_has_a_distinct_name(void) {
    for (uint32_t t = 0; t <= S_INIT_FUNC_OFFSETS; t++) {
        const char *n = msec_type_name(t);
        CHECK(n != NULL, "type 0x%02x has a name", t);
        for (uint32_t u = 0; n && u < t; u++) {
            const char *m = msec_type_name(u);
            CHECK(!m || strcmp(m, n) != 0, "types 0x%02x and 0x%02x share the name %s", u, t, n);
        }
    }
    CHECK(msec_type_name(S_REGULAR) && strcmp(msec_type_name(S_REGULAR), "regular") == 0,
          "0x00 is regular");
    CHECK(msec_type_name(S_NON_LAZY_SYMBOL_POINTERS) &&
          strcmp(msec_type_name(S_NON_LAZY_SYMBOL_POINTERS), "non-lazy-symbol-pointers") == 0,
          "0x06 is non-lazy-symbol-pointers");
    CHECK(msec_type_name(S_SYMBOL_STUBS) &&
          strcmp(msec_type_name(S_SYMBOL_STUBS), "symbol-stubs") == 0, "0x08 is symbol-stubs");
    CHECK(msec_type_name(S_INIT_FUNC_OFFSETS) &&
          strcmp(msec_type_name(S_INIT_FUNC_OFFSETS), "init-func-offsets") == 0,
          "0x16 is init-func-offsets");
    CHECK(msec_type_name(S_INIT_FUNC_OFFSETS + 1) == NULL, "0x17 has no name");
    CHECK(msec_type_name(0xff) == NULL, "0xff has no name");
}

int main(void) {
    test_every_defined_type_has_a_distinct_name();
    printf("section_test: %d failure(s)\n", fails);
    return fails ? 1 : 0;
}
```

Register it in `CMakeLists.txt`, after the `trie_test` block (`:213-216`):

```cmake
# Hermetic tests for src/section.c against images built by hand.
add_executable(section_test tests/section_test.c)
target_compile_options(section_test PRIVATE -O2 -Wall)
target_link_libraries(section_test PRIVATE drydockcore)
add_test(NAME section_test COMMAND section_test)
```

- [ ] **Step 3: Write the failing shell test**

Create `tests/secttypes.c`:

```c
/* secttypes list FILE                 SEG SECT 0xTYPE FLAGS-OFFSET, one line per section
 * secttypes set FILE SEG SECT T OUT   FILE with that section's type byte set to T, as OUT
 *
 * A thin 64-bit Mach-O only. Independent of src/, so it can check what info says. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <mach-o/loader.h>

static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)sz);
    if (!b || fread(b, 1, (size_t)sz, f) != (size_t)sz) { fprintf(stderr, "read %s\n", path); exit(2); }
    fclose(f);
    *n = (size_t)sz;
    return b;
}

int main(int argc, char **argv) {
    int set = argc == 7 && strcmp(argv[1], "set") == 0;
    if (!set && !(argc == 3 && strcmp(argv[1], "list") == 0)) {
        fprintf(stderr, "usage: secttypes list FILE | set FILE SEG SECT TYPE OUT\n");
        return 2;
    }
    size_t n; uint8_t *b = slurp(argv[2], &n);
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    if (n < sizeof *h || h->magic != MH_MAGIC_64) { fprintf(stderr, "not a thin 64-bit Mach-O\n"); return 2; }
    uint32_t t = set ? (uint32_t)strtoul(argv[5], NULL, 0) : 0;
    int hits = 0;
    uint8_t *p = b + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *sg = (struct segment_command_64 *)lc;
            struct section_64 *sc = (struct section_64 *)(sg + 1);
            for (uint32_t k = 0; k < sg->nsects; k++) {
                size_t off = (size_t)((uint8_t *)&sc[k].flags - b);
                if (!set)
                    printf("%.16s %.16s 0x%02x %zu\n", sc[k].segname, sc[k].sectname,
                           sc[k].flags & SECTION_TYPE, off);
                else if (strncmp(sc[k].segname, argv[3], 16) == 0 &&
                         strncmp(sc[k].sectname, argv[4], 16) == 0) {
                    sc[k].flags = (sc[k].flags & ~(uint32_t)SECTION_TYPE) | t;
                    hits++;
                }
            }
        }
        p += lc->cmdsize;
    }
    if (!set) return 0;
    if (hits == 0) { fprintf(stderr, "no section %s,%s\n", argv[3], argv[4]); return 2; }
    FILE *f = fopen(argv[6], "wb");
    if (!f || fwrite(b, 1, n, f) != n) { perror(argv[6]); return 2; }
    fclose(f);
    chmod(argv[6], 0755);
    return 0;
}
```

Create `tests/section_retype_test.sh`:

```sh
#!/bin/sh
# tests/section_retype_test.sh -- info's section types, and the section retype
# statement, against a binary linked on this host.
#
#   sh tests/section_retype_test.sh <bindir>
#
# Facts about a result come from `drydock-macho-rewrite info` and from
# tests/secttypes.c, never from otool, and never from a section name or count
# this host's linker chose.
set -u
BIN="${1:?usage: section_retype_test.sh <bindir>}"
BIN=$(cd "$BIN" && pwd)
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "section_retype_test: $DMR not found or not executable" >&2; exit 1; }
CC="${CC:-clang}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FF="-arch x86_64 -mmacosx-version-min=10.9"

fails=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
T=$(mktemp -d "${TMPDIR:-/tmp}/section_retype_test.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
reached_end=0
trap 'rc=$?; rm -rf "$T"; if [ "$reached_end" -eq 0 ]; then
    echo "section_retype_test: FATAL -- aborted early (exit $rc); everything after the last PASS/FAIL line never ran" >&2
fi' EXIT

"$CC" -O2 -o "$T/secttypes" "$HERE/secttypes.c" \
    || { echo "section_retype_test: could not build secttypes" >&2; exit 1; }
ST="$T/secttypes"

cat >"$T/prog.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    const char *e = getenv("RETYPE_PROBE");
    for (int i = 1; i < argc; i++) printf("%s\n", argv[i]);
    fprintf(stderr, "env=%s\n", e ? e : "(unset)");
    return argc + 3;
}
EOF
"$CC" $FF -o "$T/prog" "$T/prog.c" \
    || { echo "section_retype_test: could not link the fixture" >&2; exit 1; }

# SEG SECT TYPE-NAME per section, from info's own lines.
info_types() {
    "$DMR" info "$1" | awk '
        /^  segname=/     { split($1, a, "="); seg = a[2] }
        /^    sectname=/  { sect = substr($0, 14) }
        /^      type=/    { print seg, sect, substr($0, 12) }'
}

# ---- info: section types ----------------------------------------------------
rc=0; "$DMR" info "$T/prog" >"$T/info.out" 2>"$T/info.err" || rc=$?
[ "$rc" -eq 0 ] && ok "info: reads the fixture" \
    || bad "info" "exited $rc: $(cat "$T/info.err")"

awk '/^    sectname=/ { if (want) err = 1; want = 1; next }
     /^      type=/    { if (!want) err = 1; want = 0; n++; next }
                       { if (want) err = 1 }
     END { exit !(n > 0 && !want && !err) }' "$T/info.out" \
    && ok "info: exactly one type line directly under every sectname line" \
    || bad "info type lines" "$(grep -E '^    sectname=|^      type=' "$T/info.out" | head -20)"

"$ST" list "$T/prog" >"$T/st.list"
grep -q ' 0x06 ' "$T/st.list" && grep -q ' 0x08 ' "$T/st.list" \
    && ok "fixture: carries a non-lazy pointer section and a stub section (positive control)" \
    || bad "fixture" "secttypes found no 0x06 or no 0x08, so the checks below prove nothing: $(cat "$T/st.list")"

awk '$3 == "0x00" { print $1, $2, "regular" }
     $3 == "0x06" { print $1, $2, "non-lazy-symbol-pointers" }
     $3 == "0x08" { print $1, $2, "symbol-stubs" }' "$T/st.list" | sort >"$T/want.types"
info_types "$T/prog" | sort >"$T/got.types"
comm -23 "$T/want.types" "$T/got.types" >"$T/missing.types"
[ -s "$T/want.types" ] && [ ! -s "$T/missing.types" ] \
    && ok "info: regular, non-lazy-symbol-pointers and symbol-stubs agree with secttypes, section for section" \
    || bad "info types" "info lacks: $(cat "$T/missing.types")"

under_text() { "$DMR" info "$1" | awk '/^    sectname=__text$/ { getline; print; exit }'; }
[ "$(under_text "$T/prog")" = "      type=regular" ] \
    && ok "info: __text is regular (positive control for the hex case)" \
    || bad "info __text" "got '$(under_text "$T/prog")'"
"$ST" set "$T/prog" __TEXT __text 0x7e "$T/prog.7e"
[ "$(under_text "$T/prog.7e")" = "      type=0x7e" ] \
    && ok "info: a type with no name prints as two hex digits" \
    || bad "info hex type" "got '$(under_text "$T/prog.7e")'"

reached_end=1
echo "section_retype_test: $fails failure(s)"
[ "$fails" -eq 0 ]
```

Register it in `CMakeLists.txt`, after the `import_redirect_test` block (`:387-389`):

```cmake
# info's section types and the section retype statement, against host-linked fixtures.
add_test(NAME section_retype_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/section_retype_test.sh" "$<TARGET_FILE_DIR:drydock-macho-rewrite>")
```

- [ ] **Step 4: Run both and make sure they fail**

Run the build, then `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native -R 'section_test|section_retype_test' --output-on-failure`.

Expected: `section_test` fails to **compile** (`section.h` not found). `section_retype_test` FAILs "one type line…", "agree with secttypes" and both `__text` checks, and PASSes the fixture positive control.

- [ ] **Step 5: Write the minimal implementation**

Create `src/section.h`:

```c
#ifndef DRYDOCK_SECTION_H
#define DRYDOCK_SECTION_H
/*
 * msec_ -- a section's type, the SECTION_TYPE byte of section_64.flags.
 */
#include <stdint.h>

/* "regular", "symbol-stubs", ...: the S_ constant, lower case, '_' as '-';
 * NULL for a value no header defines. */
const char *msec_type_name(uint32_t type);

#endif /* DRYDOCK_SECTION_H */
```

Create `src/section.c`:

```c
#include "section.h"
#include "mach_compat.h"
#include <mach-o/loader.h>
#include <stddef.h>

static const char *const MSEC_NAMES[] = {
    [S_REGULAR]                             = "regular",
    [S_ZEROFILL]                            = "zerofill",
    [S_CSTRING_LITERALS]                    = "cstring-literals",
    [S_4BYTE_LITERALS]                      = "4byte-literals",
    [S_8BYTE_LITERALS]                      = "8byte-literals",
    [S_LITERAL_POINTERS]                    = "literal-pointers",
    [S_NON_LAZY_SYMBOL_POINTERS]            = "non-lazy-symbol-pointers",
    [S_LAZY_SYMBOL_POINTERS]                = "lazy-symbol-pointers",
    [S_SYMBOL_STUBS]                        = "symbol-stubs",
    [S_MOD_INIT_FUNC_POINTERS]              = "mod-init-func-pointers",
    [S_MOD_TERM_FUNC_POINTERS]              = "mod-term-func-pointers",
    [S_COALESCED]                           = "coalesced",
    [S_GB_ZEROFILL]                         = "gb-zerofill",
    [S_INTERPOSING]                         = "interposing",
    [S_16BYTE_LITERALS]                     = "16byte-literals",
    [S_DTRACE_DOF]                          = "dtrace-dof",
    [S_LAZY_DYLIB_SYMBOL_POINTERS]          = "lazy-dylib-symbol-pointers",
    [S_THREAD_LOCAL_REGULAR]                = "thread-local-regular",
    [S_THREAD_LOCAL_ZEROFILL]               = "thread-local-zerofill",
    [S_THREAD_LOCAL_VARIABLES]              = "thread-local-variables",
    [S_THREAD_LOCAL_VARIABLE_POINTERS]      = "thread-local-variable-pointers",
    [S_THREAD_LOCAL_INIT_FUNCTION_POINTERS] = "thread-local-init-function-pointers",
    [S_INIT_FUNC_OFFSETS]                   = "init-func-offsets",
};

const char *msec_type_name(uint32_t type) {
    return type < sizeof MSEC_NAMES / sizeof MSEC_NAMES[0] ? MSEC_NAMES[type] : NULL;
}
```

In `CMakeLists.txt:66`, add `src/section.c` to the `drydockcore` source list, after `src/segname.c`.

In `cli/drydock-macho-rewrite.c`, add `#include "section.h"` after `#include "script.h"` (`:90`), and replace the loop at `:403-404`:

```c
        for (uint32_t k = 0; k < seg->nsects; k++) {
            uint32_t type = sect[k].flags & SECTION_TYPE;
            const char *name = msec_type_name(type);
            printf("    sectname=%.16s\n", sect[k].sectname);
            if (name) printf("      type=%s\n", name);
            else      printf("      type=0x%02x\n", type);
        }
```

Add two rows to `tests/README.md`'s table, after `trie_test`'s:

```markdown
| `section_test` | hermetic: `src/section.c`'s type names, `SEG,SECT` split and retype core, against images built by hand |
| `section_retype_test` | `info`'s `type=` lines and the `section retype` statement, against a binary linked here: types cross-checked with `tests/secttypes.c`, the bytes a retype changes, retype and grow in either order, and the retyped binary run beside its input |
```

- [ ] **Step 6: Run the tests and make sure they pass**

Run the full test command. Expected: `section_test` and `section_retype_test` PASS, and so does every other suite. That is Step 1's sweep, confirmed by running the consumers.

- [ ] **Step 7: Mutation-prove**

For each of these, apply it, build, confirm the build names the object, run `-R 'section_test|section_retype_test'`, see the named failure, then restore:

1. Delete the `[S_SYMBOL_STUBS]` row of `MSEC_NAMES`. Expect `section_test` "type 0x08 has a name", and `section_retype_test` "agree with secttypes".
2. In `info_cb`, change the fallback to `printf("      type=%u\n", type)`. Expect "a type with no name prints as two hex digits".
3. Swap the two `printf`s so `type=` comes before `sectname=`. Expect "exactly one type line directly under every sectname line".

- [ ] **Step 8: Commit**

```bash
git add src/section.h src/section.c tests/section_test.c tests/secttypes.c \
        tests/section_retype_test.sh cli/drydock-macho-rewrite.c CMakeLists.txt tests/README.md
git commit -m "feat(info): name each section's type

A line six spaces deep under every sectname= line, so no existing
consumer's pattern can match it: type=regular, type=symbol-stubs, ...,
or type=0xNN for a value no header defines. Swept N info consumers in
compat/ and tests/; none matches the new line.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF"
```

Before committing, replace `N` with Step 1's hit count.

---

### Task 2: The retype core

**Files:**
- Modify: `src/section.h`, `src/section.c`
- Test: `tests/section_test.c`

**Interfaces:**
- Consumes: `msec_type_name` (Task 1).
- Produces:
  - `int msec_type_by_name(const char *name, uint32_t *type);` returns 0, or -1 for a name not in the table.
  - `int msec_retypable(uint32_t from);` returns nonzero only for `S_NON_LAZY_SYMBOL_POINTERS` and `S_SYMBOL_STUBS`.
  - `int msec_split(const char *operand, char seg[MSEG_NAME_MAX + 1], char sect[MSEG_NAME_MAX + 1]);` splits at the first comma. It returns 0, or -1 when there is no comma or either side is empty or longer than 16 bytes.
  - `#define MSEC_NO_DYLD_INFO 1`
  - `int msec_retype(const mi_image *im, const char *seg, const char *sect, uint32_t from, uint32_t to, int *retyped);` sets each matching section's `SECTION_TYPE` to `to` and returns 0 with `*retyped` set. A section matches when its own `segname` and `sectname` equal `seg` and `sect` under `strncmp(…, 16)` and its type is `from`. It returns `MSEC_NO_DYLD_INFO` with nothing written and `*retyped` 0 when something matched but the image has no `LC_DYLD_INFO` or `LC_DYLD_INFO_ONLY`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/section_test.c`, above `main`:

```c
#define IMG 0x1000
#define WITH_DYLD_INFO 1

static void name16(char *f, const char *n) {
    size_t l = strlen(n);
    memset(f, 0, 16);
    memcpy(f, n, l > 16 ? 16 : l);
}

static void put(struct section_64 *s, const char *seg, const char *sect, uint32_t flags,
                uint32_t r1, uint32_t r2) {
    memset(s, 0, sizeof *s);
    name16(s->segname, seg); name16(s->sectname, sect);
    s->flags = flags; s->reserved1 = r1; s->reserved2 = r2;
}

/* __TEXT: __text (regular), __stubs (symbol-stubs, reserved 2/6).
 * __DATA: __got (non-lazy), ABCDEFGHIJKLMNOP (non-lazy, a 16-byte name with no NUL).
 * WITH_DYLD_INFO adds an empty LC_DYLD_INFO_ONLY. */
static uint8_t *build(int opts) {
    uint8_t *b = calloc(1, IMG);
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    h->magic = MH_MAGIC_64; h->cputype = CPU_TYPE_X86_64; h->filetype = MH_EXECUTE;
    uint8_t *p = b + sizeof *h;
    const uint32_t code = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;

    struct segment_command_64 *text = (struct segment_command_64 *)p;
    text->cmd = LC_SEGMENT_64; text->nsects = 2;
    text->cmdsize = (uint32_t)(sizeof *text + 2 * sizeof(struct section_64));
    name16(text->segname, "__TEXT");
    put((struct section_64 *)(text + 1) + 0, "__TEXT", "__text", S_REGULAR | code, 0, 0);
    put((struct section_64 *)(text + 1) + 1, "__TEXT", "__stubs", S_SYMBOL_STUBS | code, 2, 6);
    p += text->cmdsize;

    struct segment_command_64 *data = (struct segment_command_64 *)p;
    data->cmd = LC_SEGMENT_64; data->nsects = 2;
    data->cmdsize = (uint32_t)(sizeof *data + 2 * sizeof(struct section_64));
    name16(data->segname, "__DATA");
    put((struct section_64 *)(data + 1) + 0, "__DATA", "__got", S_NON_LAZY_SYMBOL_POINTERS, 0, 0);
    put((struct section_64 *)(data + 1) + 1, "__DATA", "ABCDEFGHIJKLMNOP",
        S_NON_LAZY_SYMBOL_POINTERS, 1, 0);
    p += data->cmdsize;
    h->ncmds = 2;

    if (opts & WITH_DYLD_INFO) {
        struct dyld_info_command *di = (struct dyld_info_command *)p;
        di->cmd = LC_DYLD_INFO_ONLY; di->cmdsize = sizeof *di;
        p += di->cmdsize; h->ncmds++;
    }
    h->sizeofcmds = (uint32_t)(p - (b + sizeof *h));
    return b;
}

static struct section_64 *find(uint8_t *b, const char *seg, const char *sect) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = b + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *sg = (struct segment_command_64 *)lc;
            struct section_64 *s = (struct section_64 *)(sg + 1);
            for (uint32_t k = 0; k < sg->nsects; k++)
                if (strncmp(s[k].segname, seg, 16) == 0 && strncmp(s[k].sectname, sect, 16) == 0)
                    return &s[k];
        }
        p += lc->cmdsize;
    }
    return NULL;
}

static int retype(uint8_t *b, const char *seg, const char *sect, uint32_t from, int *n) {
    mi_image im;
    if (mi_wrap(b, IMG, &im) != 0) { printf("FAIL: the built image does not wrap\n"); fails++; return -99; }
    return msec_retype(&im, seg, sect, from, S_REGULAR, n);
}

static int bytes_differing(const uint8_t *a, const uint8_t *b, size_t *where) {
    int d = 0;
    for (size_t i = 0; i < IMG; i++) if (a[i] != b[i]) { d++; *where = i; }
    return d;
}

static void test_names_round_trip_and_only_two_are_retypable(void) {
    for (uint32_t t = 0; t <= S_INIT_FUNC_OFFSETS; t++) {
        uint32_t back = 0xffffffffu;
        CHECK(msec_type_by_name(msec_type_name(t), &back) == 0 && back == t,
              "0x%02x round-trips through its name", t);
    }
    uint32_t x;
    CHECK(msec_type_by_name("bogus", &x) == -1, "an unknown name is refused");
    for (uint32_t t = 0; t <= 0xff; t++)
        CHECK(!!msec_retypable(t) == (t == S_NON_LAZY_SYMBOL_POINTERS || t == S_SYMBOL_STUBS),
              "0x%02x retypable is %d", t, msec_retypable(t));
}

static void test_split(void) {
    char seg[17], sect[17];
    CHECK(msec_split("__DATA,__got", seg, sect) == 0 && strcmp(seg, "__DATA") == 0 &&
          strcmp(sect, "__got") == 0, "__DATA,__got splits");
    CHECK(msec_split("__DATA,__a,b", seg, sect) == 0 && strcmp(seg, "__DATA") == 0 &&
          strcmp(sect, "__a,b") == 0, "the first comma splits");
    CHECK(msec_split("ABCDEFGHIJKLMNOP,ABCDEFGHIJKLMNOP", seg, sect) == 0 &&
          strlen(seg) == 16 && strlen(sect) == 16, "16 bytes each side fit");
    CHECK(msec_split("ABCDEFGHIJKLMNOPQ,__got", seg, sect) == -1, "a 17-byte segment is refused");
    CHECK(msec_split("__DATA,ABCDEFGHIJKLMNOPQ", seg, sect) == -1, "a 17-byte section is refused");
    CHECK(msec_split("__DATA__got", seg, sect) == -1, "no comma is refused");
    CHECK(msec_split(",__got", seg, sect) == -1, "an empty segment is refused");
    CHECK(msec_split("__DATA,", seg, sect) == -1, "an empty section is refused");
}

static void test_retype_writes_only_the_type_byte(void) {
    uint8_t *b = build(WITH_DYLD_INFO), *orig = build(WITH_DYLD_INFO);
    int n = -1; size_t at = 0;
    CHECK(retype(b, "__TEXT", "__stubs", S_SYMBOL_STUBS, &n) == 0 && n == 1,
          "__stubs retyped (n=%d)", n);
    struct section_64 *s = find(b, "__TEXT", "__stubs");
    CHECK(s->flags == (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS),
          "__stubs keeps its attributes and loses its type (flags 0x%08x)", s->flags);
    CHECK(s->reserved1 == 2 && s->reserved2 == 6, "__stubs keeps reserved1/2");
    CHECK(bytes_differing(orig, b, &at) == 1 && at == (size_t)((uint8_t *)&s->flags - b),
          "exactly one byte changed, and it is __stubs' type byte");

    free(b); b = build(WITH_DYLD_INFO);
    CHECK(retype(b, "__DATA", "__got", S_NON_LAZY_SYMBOL_POINTERS, &n) == 0 && n == 1,
          "__got retyped (n=%d)", n);
    CHECK(find(b, "__DATA", "__got")->flags == S_REGULAR, "__got is regular");
    free(b); free(orig);
}

static void test_names_match_exactly(void) {
    uint8_t *b = build(WITH_DYLD_INFO), *orig = build(WITH_DYLD_INFO);
    int n = -1; size_t at = 0;
    CHECK(retype(b, "__DATA", "__go", S_NON_LAZY_SYMBOL_POINTERS, &n) == 0 && n == 0,
          "__go does not select __got (n=%d)", n);
    CHECK(retype(b, "__DAT", "__got", S_NON_LAZY_SYMBOL_POINTERS, &n) == 0 && n == 0,
          "__DAT does not select __DATA (n=%d)", n);
    CHECK(retype(b, "__DATA", "ABCDEFGHIJKLMNO", S_NON_LAZY_SYMBOL_POINTERS, &n) == 0 && n == 0,
          "a 15-byte name does not select the 16-byte one (n=%d)", n);
    CHECK(bytes_differing(orig, b, &at) == 0, "three misses changed nothing");
    CHECK(retype(b, "__DATA", "ABCDEFGHIJKLMNOP", S_NON_LAZY_SYMBOL_POINTERS, &n) == 0 && n == 1,
          "the whole 16-byte name selects it (n=%d)", n);
    free(b); free(orig);
}

static void test_a_wrong_from_misses(void) {
    uint8_t *b = build(WITH_DYLD_INFO);
    int n = -1;
    CHECK(retype(b, "__TEXT", "__stubs", S_NON_LAZY_SYMBOL_POINTERS, &n) == 0 && n == 0,
          "__stubs is not non-lazy (n=%d)", n);
    CHECK(retype(b, "__DATA", "__got", S_SYMBOL_STUBS, &n) == 0 && n == 0,
          "__got is not stubs (n=%d)", n);
    CHECK(retype(b, "__TEXT", "__text", S_SYMBOL_STUBS, &n) == 0 && n == 0,
          "__text is not stubs (n=%d)", n);
    free(b);
}

static void test_no_dyld_info_refuses_only_a_match(void) {
    uint8_t *b = build(0), *orig = build(0);
    int n = -1; size_t at = 0;
    CHECK(retype(b, "__DATA", "__got", S_NON_LAZY_SYMBOL_POINTERS, &n) == MSEC_NO_DYLD_INFO && n == 0,
          "a match on an image without LC_DYLD_INFO[_ONLY] is refused (n=%d)", n);
    CHECK(retype(b, "__TEXT", "__stubs", S_SYMBOL_STUBS, &n) == MSEC_NO_DYLD_INFO,
          "stubs too: one rule for both types");
    CHECK(bytes_differing(orig, b, &at) == 0, "a refusal writes nothing");
    CHECK(retype(b, "__DATA", "__nope", S_NON_LAZY_SYMBOL_POINTERS, &n) == 0 && n == 0,
          "no match on such an image is a plain miss, not a refusal");
    free(b); free(orig);
}
```

Replace `main` with:

```c
int main(void) {
    test_every_defined_type_has_a_distinct_name();
    test_names_round_trip_and_only_two_are_retypable();
    test_split();
    test_retype_writes_only_the_type_byte();
    test_names_match_exactly();
    test_a_wrong_from_misses();
    test_no_dyld_info_refuses_only_a_match();
    printf("section_test: %d failure(s)\n", fails);
    return fails ? 1 : 0;
}
```

- [ ] **Step 2: Run it to make sure it fails**

Build. Expected: `section_test` fails to compile, with the new `msec_*` declarations missing.

- [ ] **Step 3: Write the minimal implementation**

Replace `src/section.h`'s body (between the include guard lines) with:

```c
/*
 * msec_ -- a section's type, the SECTION_TYPE byte of section_64.flags.
 */
#include <stdint.h>
#include "image.h"
#include "segname.h"

/* "regular", "symbol-stubs", ...: the S_ constant, lower case, '_' as '-';
 * NULL for a value no header defines. */
const char *msec_type_name(uint32_t type);
int msec_type_by_name(const char *name, uint32_t *type);

/* The types `section retype` accepts as FROM. */
int msec_retypable(uint32_t from);

int msec_split(const char *operand, char seg[MSEG_NAME_MAX + 1], char sect[MSEG_NAME_MAX + 1]);

#define MSEC_NO_DYLD_INFO 1

/* Without LC_DYLD_INFO[_ONLY], dyld binds non-lazy pointers by section type. */
int msec_retype(const mi_image *im, const char *seg, const char *sect,
                uint32_t from, uint32_t to, int *retyped);
```

Append to `src/section.c`, and add `#include <string.h>` to its includes:

```c
int msec_type_by_name(const char *name, uint32_t *type) {
    for (uint32_t t = 0; t < sizeof MSEC_NAMES / sizeof MSEC_NAMES[0]; t++)
        if (MSEC_NAMES[t] && strcmp(MSEC_NAMES[t], name) == 0) { *type = t; return 0; }
    return -1;
}

int msec_retypable(uint32_t from) {
    return from == S_NON_LAZY_SYMBOL_POINTERS || from == S_SYMBOL_STUBS;
}

int msec_split(const char *operand, char seg[MSEG_NAME_MAX + 1], char sect[MSEG_NAME_MAX + 1]) {
    const char *comma = strchr(operand, ',');
    if (!comma) return -1;
    size_t sl = (size_t)(comma - operand), tl = strlen(comma + 1);
    if (sl == 0 || sl > MSEG_NAME_MAX || tl == 0 || tl > MSEG_NAME_MAX) return -1;
    memcpy(seg, operand, sl); seg[sl] = '\0';
    memcpy(sect, comma + 1, tl); sect[tl] = '\0';
    return 0;
}

struct msec_ctx {
    const char *seg, *sect;
    uint32_t from, to;
    int write, n, dyld_info;
};

static int msec_cb(const struct load_command *lc_in, void *ctx_) {
    struct msec_ctx *c = (struct msec_ctx *)ctx_;
    struct load_command *lc = (struct load_command *)lc_in;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) c->dyld_info = 1;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    struct segment_command_64 *sg = (struct segment_command_64 *)lc;
    struct section_64 *s = (struct section_64 *)(sg + 1);
    for (uint32_t j = 0; j < sg->nsects; j++) {
        if (strncmp(s[j].segname, c->seg, MSEG_NAME_MAX) != 0) continue;
        if (strncmp(s[j].sectname, c->sect, MSEG_NAME_MAX) != 0) continue;
        if ((s[j].flags & SECTION_TYPE) != c->from) continue;
        if (c->write) s[j].flags = (s[j].flags & ~(uint32_t)SECTION_TYPE) | c->to;
        c->n++;
    }
    return 0;
}

int msec_retype(const mi_image *im, const char *seg, const char *sect,
                uint32_t from, uint32_t to, int *retyped) {
    struct msec_ctx c = { seg, sect, from, to, 0, 0, 0 };
    *retyped = 0;
    mi_each_lc(im, msec_cb, &c);
    if (c.n == 0) return 0;
    if (!c.dyld_info) return MSEC_NO_DYLD_INFO;
    c.write = 1; c.n = 0;
    mi_each_lc(im, msec_cb, &c);
    *retyped = c.n;
    return 0;
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run `-R section_test --output-on-failure`, then the full test command. Expected: all PASS.

- [ ] **Step 5: Mutation-prove**

Each mutation is applied, built (confirm `section.c.o` rebuilt), run with `-R section_test`, seen to fail as named, and restored:

1. `strncmp(s[j].sectname, c->sect, MSEG_NAME_MAX)` → `strncmp(s[j].sectname, c->sect, strlen(c->sect))`. Expect "__go does not select __got" and "a 15-byte name…".
2. Delete the `from` line (`if ((s[j].flags & SECTION_TYPE) != c->from) continue;`). Expect "__stubs is not non-lazy".
3. `s[j].flags = (… ) | c->to` → `s[j].flags = c->to`. Expect "__stubs keeps its attributes".
4. `if (!c.dyld_info) return MSEC_NO_DYLD_INFO;` → delete it. Expect "a match on an image without LC_DYLD_INFO[_ONLY] is refused".
5. Move the `dyld_info` check above `if (c.n == 0) return 0;`. Expect "no match on such an image is a plain miss".
6. In `msec_retypable`, add `|| from == S_LAZY_SYMBOL_POINTERS`. Expect "0x07 retypable is 1".

- [ ] **Step 6: Commit**

```bash
git add src/section.h src/section.c tests/section_test.c
git commit -m "feat(section): retype a named section's type byte, refusing classic images

msec_retype sets SECTION_TYPE on every section whose own segname and
sectname match under strncmp(..., 16) and whose type is FROM, leaving
attributes and reserved1/2 alone. When something matches in an image
with no LC_DYLD_INFO[_ONLY], it refuses and writes nothing: dyld's
classic loader binds non-lazy pointers by section type, and a 10.5-linked
x86_64 binary with __got retyped dies of SIGSEGV on 10.9.5.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF"
```

---

### Task 3: The `section retype` statement

**Files:**
- Modify: `src/script.h:40-43` (kind enum)
- Modify: `src/script.c:1-9` (includes), `:81` ("17 rows"), `:128-129` (the last row), `:417-420` (operand checks, before the `import redirect` check)
- Modify: `src/edit.c:26-41` (includes), `me_apply`'s switch (a new case before `case MS_FIXUPS:`, `:411`)
- Test: `tests/script_test.c` (`:367-422` row count and dummy operands, `:425` and `:521-530` disturbs, a new test, `main`)
- Test: `tests/cli_test.sh:497-510`
- Test: `tests/edit_test.c` (`:62-64` flags, `build_image`, a new reader, new tests, `main`)

**Interfaces:**
- Consumes: `msec_split`, `msec_type_by_name`, `msec_retypable`, `msec_retype`, `MSEC_NO_DYLD_INFO` (Task 2).
- Produces:
  - Enum value `MS_SECTION`, appended last in the kind enum.
  - Row `section retype`, 3 operands, `MREL_NONE`. `ms_stmt.a` is `SEG,SECT` whole, `.b` is FROM, `.c` is TO.
  - Log line `      retyped N section(s)`.
  - On a miss, stderr `drydock-macho-rewrite: section retype A B C matched nothing`.
  - `edit_test`'s build flag `POINTER_SECTS` (8), which names `__TEXT`'s section `__stubs` (symbol-stubs, `reserved2` 6) and `__DATA`'s first section `__got` (non-lazy).

- [ ] **Step 1: Write the failing parser tests**

In `tests/script_test.c`:

In `test_capabilities_table_round_trips`, add a dummy-operand case after the `dylib retype` one:

```c
        else if (strcmp(kind, "section") == 0) { a = "__DATA,__got"; b = "symbol-stubs"; c = "regular"; }
```

Change `CHECK(n_rows == 17, "the statement table has 17 rows (got %d)", n_rows);` to use 18 in both places, and in the comment above it change "17 rows (16 kind/op pairs" to "18 rows (17 kind/op pairs" and "(exactly 17" to "(exactly 18". Change `:425`'s "seventeen" to "eighteen". Add to the end of `test_disturbs_matches_the_spec_table`:

```c
    CHECK(ms_disturbs(MS_SECTION, MS_RETYPE) == MREL_NONE,
          "section retype rewrites one byte of a section header in place and moves nothing");
```

Add before `test_every_row_declares_its_disturbs`:

```c
static void test_section_retype(void) {
    ms_script s; char err[256] = {0};
    const char *ok = "section retype __DATA,__got non-lazy-symbol-pointers regular\n";
    CHECK(ms_parse(ok, strlen(ok), &s, err, sizeof err) == 0, "section retype rejected: %s", err);
    CHECK(s.n == 1 && s.stmts[0].kind == MS_SECTION && s.stmts[0].op == MS_RETYPE, "wrong kind/op");
    CHECK(s.n == 1 && strcmp(s.stmts[0].a, "__DATA,__got") == 0 &&
          strcmp(s.stmts[0].b, "non-lazy-symbol-pointers") == 0 &&
          strcmp(s.stmts[0].c, "regular") == 0, "operands are SEG,SECT, FROM, TO in that order");
    ms_free(&s);

    const char *full = "section retype ABCDEFGHIJKLMNOP,ABCDEFGHIJKLMNOP symbol-stubs regular\n";
    err[0] = 0;
    CHECK(ms_parse(full, strlen(full), &s, err, sizeof err) == 0, "16-byte names rejected: %s", err);
    ms_free(&s);

    static const struct { const char *line, *want; } BAD[] = {
        { "section retype __DATA__got non-lazy-symbol-pointers regular\n", "is not SEG,SECT" },
        { "section retype ,__got non-lazy-symbol-pointers regular\n", "is not SEG,SECT" },
        { "section retype __DATA, non-lazy-symbol-pointers regular\n", "is not SEG,SECT" },
        { "section retype ABCDEFGHIJKLMNOPQ,__got non-lazy-symbol-pointers regular\n", "is not SEG,SECT" },
        { "section retype __DATA,ABCDEFGHIJKLMNOPQ non-lazy-symbol-pointers regular\n", "is not SEG,SECT" },
        { "section retype __DATA,__got regular regular\n",
          "FROM 'regular' is not one of: non-lazy-symbol-pointers, symbol-stubs" },
        { "section retype __DATA,__got lazy-symbol-pointers regular\n", "FROM 'lazy-symbol-pointers'" },
        { "section retype __DATA,__got bogus regular\n", "FROM 'bogus'" },
        { "section retype __DATA,__got symbol-stubs symbol-stubs\n",
          "TO accepts only 'regular' (got 'symbol-stubs')" },
        { "section retype __DATA,__got symbol-stubs\n", "takes 3 arguments (got 2)" },
    };
    for (size_t i = 0; i < sizeof BAD / sizeof BAD[0]; i++) {
        err[0] = 0;
        CHECK(ms_parse(BAD[i].line, strlen(BAD[i].line), &s, err, sizeof err) == -1 &&
              strstr(err, BAD[i].want) != NULL,
              "'%.*s' is refused with '%s' (got: %s)", (int)strlen(BAD[i].line) - 1,
              BAD[i].line, BAD[i].want, err);
    }
}
```

Call `test_section_retype();` from `main`, after `test_import_redirect();`.

In `tests/cli_test.sh:497-510`, change every `17` to `18` and "16 <kind,op> pairs" to "17 <kind,op> pairs", then add after the `statement dylib retype 2` assertion:

```sh
echo "$caps" | grep -qxF "statement section retype 3" \
    && ok "capabilities: section retype statement is advertised" \
    || bad "capabilities: section retype" "no 'statement section retype 3' line: $(echo "$caps" | grep '^statement section')"
```

- [ ] **Step 2: Write the failing execution tests**

In `tests/edit_test.c`, add after `#define NO_UUID 4`:

```c
#define POINTER_SECTS 8 /* __TEXT,__stubs (symbol-stubs) and __DATA,__got (non-lazy) */
```

In `build_image`, replace the two `put_sect` calls for `__text` and `__data`:

```c
    int ptrs = (flags & POINTER_SECTS) != 0;
    put_sect(text, 0, ptrs ? "__stubs" : "__text", "__TEXT", TEXT_VMADDR + SECT_OFF, 4, SECT_OFF,
             ptrs ? (S_SYMBOL_STUBS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS) : 0);
    if (ptrs) ((struct section_64 *)(text + 1))[0].reserved2 = 6;
```

```c
    put_sect(data, 0, ptrs ? "__got" : "__data", "__DATA", TEXT_VMADDR + DATA_OFF, 8, DATA_OFF,
             ptrs ? S_NON_LAZY_SYMBOL_POINTERS : 0);
```

Add after `has_segment`:

```c
/* flags of SEG,SECT in the thin image at `path`, or 0xffffffff if it has none. */
static uint32_t sect_flags(const char *path, const char *seg, const char *sect) {
    size_t len = 0;
    uint8_t *buf = read_file(path, &len);
    mi_image im;
    uint32_t flags = 0xffffffffu;
    if (buf && mi_wrap(buf, len, &im) == 0) {
        uint8_t *p = buf + sizeof(struct mach_header_64);
        for (uint32_t i = 0; i < im.hdr->ncmds; i++) {
            struct load_command *lc = (struct load_command *)p;
            if (lc->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *sg = (struct segment_command_64 *)lc;
                struct section_64 *s = (struct section_64 *)(sg + 1);
                for (uint32_t k = 0; k < sg->nsects; k++)
                    if (strncmp(s[k].segname, seg, 16) == 0 && strncmp(s[k].sectname, sect, 16) == 0)
                        flags = s[k].flags;
            }
            p += lc->cmdsize;
        }
    }
    free(buf);
    return flags;
}
```

Add after `test_an_unmatched_segment_rename_refuses_by_default`:

```c
static void test_section_retype_rewrites_the_type(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(DYLD_INFO | POINTER_SECTS);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    int rc = run(path, out,
                 "section retype __TEXT,__stubs symbol-stubs regular\n"
                 "section retype __DATA,__got non-lazy-symbol-pointers regular\n");
    CHECK(rc == 0, "section retype: run succeeds (got %d; log: %s)", rc, g_log);
    CHECK(sect_flags(out, "__TEXT", "__stubs") == (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS),
          "section retype: __stubs is regular with its attributes (0x%08x)",
          sect_flags(out, "__TEXT", "__stubs"));
    CHECK(sect_flags(out, "__DATA", "__got") == S_REGULAR, "section retype: __got is regular");
    CHECK(strstr(g_log, "      retyped 1 section\n") != NULL,
          "section retype: the log says what it did (log: %s)", g_log);

    /* Run again on the result: the sections are regular now, so it misses. */
    char again[512];
    in_dir(again, sizeof again, "img.again");
    rc = run(out, again, "section retype __DATA,__got non-lazy-symbol-pointers regular\n");
    CHECK(rc == MR_REFUSED, "section retype: a second run misses and refuses (got %d)", rc);
    rm_dir();
}

static void test_an_unmatched_section_retype_refuses_by_default(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(DYLD_INFO | POINTER_SECTS);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    snap before = take(path);
    int rc = run(path, out,
                 "load-command delete uuid\n"
                 "section retype __DATA,__nope non-lazy-symbol-pointers regular\n");
    CHECK(rc == MR_REFUSED, "by default: a retype that matched nothing refuses (got %d)", rc);
    check_untouched("by default, retype", path, &before);
    CHECK(access(out, F_OK) != 0, "by default, retype: %s was not created", out);
    CHECK(strstr(g_log, "refused at statement 2 of 2 (line 2)") != NULL,
          "by default: the refusal names the retype (log: %s)", g_log);

    rc = run(path, out,
             "allow-unmatched\n"
             "load-command delete uuid\n"
             "section retype __DATA,__nope non-lazy-symbol-pointers regular\n");
    CHECK(rc == 0, "allow-unmatched: an unmatched retype is reported and the run succeeds (got %d)", rc);
    CHECK(count_lc(out, LC_UUID, NULL) == 0, "allow-unmatched: the statement before it was applied");
    CHECK(sect_flags(out, "__DATA", "__got") == S_NON_LAZY_SYMBOL_POINTERS,
          "allow-unmatched: __got was not touched");
    rm_dir();
}

static void test_section_retype_refuses_an_image_without_dyld_info(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    uint8_t *img = build_image(POINTER_SECTS);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);

    snap before = take(path);
    int rc = run(path, out,
                 "allow-unmatched\n"
                 "section retype __DATA,__got non-lazy-symbol-pointers regular\n");
    CHECK(rc == MR_REFUSED, "no LC_DYLD_INFO: refused, and allow-unmatched does not cover it (got %d)", rc);
    check_untouched("no LC_DYLD_INFO", path, &before);
    CHECK(access(out, F_OK) != 0, "no LC_DYLD_INFO: %s was not created", out);
    CHECK(strstr(g_log, "has no LC_DYLD_INFO or LC_DYLD_INFO_ONLY") != NULL,
          "no LC_DYLD_INFO: the refusal says why (log: %s)", g_log);
    rm_dir();
}
```

Call all three from `main`, after `test_an_unmatched_segment_rename_refuses_by_default();`.

- [ ] **Step 3: Run them to make sure they fail**

Build. Expected: `script_test` and `edit_test` fail to compile (`MS_SECTION` undeclared).

- [ ] **Step 4: Write the minimal implementation**

`src/script.h:40-41`: append `MS_SECTION` to the kind enum:

```c
enum { MS_LOAD_COMMAND, MS_SEGMENT, MS_VERSION_MIN, MS_SWIFT_ABI,
       MS_FIXUPS, MS_DYLIB, MS_RPATH, MS_TARGET, MS_IMPORT, MS_SECTION };
```

`src/script.c`: add `#include "section.h"` to the includes. At `:81` change "17 rows" to "18 rows". Make the `import redirect` row end with ` \` and append:

```c
  R("section",      MS_SECTION,      "retype",   MS_RETYPE,       3, NULL,        0,             0, MREL_NONE)
```

In the operand-check chain, add before `} else if (kind == MS_IMPORT && op == MS_REDIRECT &&`:

```c
            } else if (kind == MS_SECTION && op == MS_RETYPE) {
                char seg[MSEG_NAME_MAX + 1], sect[MSEG_NAME_MAX + 1];
                uint32_t from;
                if (msec_split(fields[2], seg, sect) != 0)
                    return ms_failf(stmts, text, out, err, errsz, lineno,
                        "section retype: '%s' is not SEG,SECT with each name 1 to 16 bytes",
                        fields[2]);
                if (msec_type_by_name(fields[3], &from) != 0 || !msec_retypable(from))
                    return ms_failf(stmts, text, out, err, errsz, lineno,
                        "section retype: FROM '%s' is not one of: non-lazy-symbol-pointers, "
                        "symbol-stubs", fields[3]);
                if (strcmp(fields[4], "regular") != 0)
                    return ms_failf(stmts, text, out, err, errsz, lineno,
                        "section retype: TO accepts only 'regular' (got '%s')", fields[4]);
```

`src/edit.c`: add `#include "section.h"` after `#include "segname.h"`. Add this case before `case MS_FIXUPS: {`:

```c
    case MS_SECTION: {
        char seg[MSEG_NAME_MAX + 1], sect[MSEG_NAME_MAX + 1];
        uint32_t from = 0, to = 0;
        mi_image im;
        int retyped = 0;
        if (st->op != MS_RETYPE || msec_split(st->a, seg, sect) != 0 ||
            msec_type_by_name(st->b, &from) != 0 || msec_type_by_name(st->c, &to) != 0)
            goto unknown;
        if (me_view(*pbuf, *psize, &im, path, log) != 0) return MR_REFUSED;
        if (msec_retype(&im, seg, sect, from, to, &retyped) == MSEC_NO_DYLD_INFO) {
            me_say(log, "drydock-macho-rewrite edit: %s has no LC_DYLD_INFO or LC_DYLD_INFO_ONLY, "
                        "so dyld finds its symbol pointers by section type and retyping %s would "
                        "leave them unbound; an image with chained fixups gets one from "
                        "`fixups set classic`\n", path, st->a);
            return MR_REFUSED;
        }
        if (retyped > 0)
            me_say(log, "      retyped %d section%s\n", retyped, retyped == 1 ? "" : "s");
        *v->renamed += retyped;
        if (!v->decide || *v->renamed > 0) return 0;
        me_say(stderr, "drydock-macho-rewrite: section retype %s %s %s matched nothing\n",
               st->a, st->b, st->c);
        if (!s->allow_unmatched) { v->missed = 1; return MR_REFUSED; }
        return 0;
    }
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run `-R 'script_test|edit_test|cli_test' --output-on-failure`, then the full test command. Expected: all PASS.

- [ ] **Step 6: Mutation-prove**

Each mutation is applied, built (confirm the named object rebuilt), run with the named suite, seen to fail, and restored:

1. `src/script.c`: delete the `TO` check. Expect `script_test` "…TO accepts only 'regular'…".
2. `src/script.c`: `!msec_retypable(from)` → `0`. Expect `script_test` "FROM 'regular' is not one of…".
3. `src/script.c`: the row's `MREL_NONE` → `MREL_HEADER_PAD`. Expect `script_test` "section retype rewrites one byte…".
4. `src/edit.c`: delete `*v->renamed += retyped;`. Expect `edit_test` "section retype: run succeeds".
5. `src/edit.c`: `if (!s->allow_unmatched)` → `if (s->allow_unmatched)`. Expect `edit_test` "by default: a retype that matched nothing refuses".
6. `src/edit.c`: replace the `MSEC_NO_DYLD_INFO` branch's `return MR_REFUSED;` with `return 0;`. Expect `edit_test` "no LC_DYLD_INFO: refused…".

- [ ] **Step 7: Commit**

```bash
git add src/script.h src/script.c src/edit.c tests/script_test.c tests/cli_test.sh tests/edit_test.c
git commit -m "feat(edit): section retype SEG,SECT FROM TO

FROM is non-lazy-symbol-pointers or symbol-stubs, TO is regular. The
section is selected by its own segname,sectname, split at the first
comma, each 1 to 16 bytes. A retype that matches nothing refuses by
default, like segment rename. An image without LC_DYLD_INFO[_ONLY]
refuses whatever allow-unmatched says. MREL_NONE: one byte of a
section header, in place.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF"
```

---

### Task 4: `section retype` on fat files

The shared verdict (`me_verdict`, summed across slices and judged in the last
one) already gives the semantics the spec asks for. So these tests are
expected to **pass on first run**: they pin behaviour rather than drive new
code. They are proved by mutation, not by a red first run. If one fails on
first run, stop: that is a defect in Task 3, and it must be fixed there with
its own failing test.

**Files:**
- Test: `tests/edit_test.c`

**Interfaces:**
- Consumes: `POINTER_SECTS`, `sect_flags` and the statement (Task 3); `write_fat(path, flags0, flags1, with_i386)` and `slice_to_file` (existing; slice 0 is x86_64 and slice 1 is arm64).
- Produces: nothing new.

- [ ] **Step 1: Write the tests**

Add after `test_fat_unmatched_counts_a_match_in_any_slice`:

```c
static void test_fat_section_retype_counts_a_match_in_any_slice(void) {
    fresh_dir();
    char path[512], out[512], s0[512], s1[512], orig1[512];
    const char *st = "section retype __DATA,__got non-lazy-symbol-pointers regular\n";
    in_dir(path, sizeof path, "fat"); in_dir(out, sizeof out, "fat.out");
    in_dir(s0, sizeof s0, "s0"); in_dir(s1, sizeof s1, "s1"); in_dir(orig1, sizeof orig1, "orig1");

    write_fat(path, DYLD_INFO | POINTER_SECTS, DYLD_INFO, 0);
    slice_to_file(path, 1, orig1);
    int rc = run(path, out, st);
    CHECK(rc == 0, "fat retype: a match in the first slice only is a match (got %d; log: %s)", rc, g_log);
    slice_to_file(out, 0, s0); slice_to_file(out, 1, s1);
    CHECK(sect_flags(s0, "__DATA", "__got") == S_REGULAR, "fat retype: slice 0's __got is regular");
    size_t la, lb; uint8_t *a = read_file(orig1, &la), *b = read_file(s1, &lb);
    CHECK(la == lb && memcmp(a, b, la) == 0, "fat retype: slice 1, which had no __got, is byte-identical");
    free(a); free(b);

    write_fat(path, DYLD_INFO, DYLD_INFO | POINTER_SECTS, 0);
    rc = run(path, out, st);
    CHECK(rc == 0, "fat retype: a match in a LATER slice is not a miss (got %d; log: %s)", rc, g_log);

    write_fat(path, DYLD_INFO, DYLD_INFO, 0);
    snap before = take(path);
    rc = run(path, out, st);
    CHECK(rc == MR_REFUSED, "fat retype: matching in no slice refuses (got %d)", rc);
    check_untouched("fat retype, miss everywhere", path, &before);
    CHECK(strstr(g_log, "matched nothing in any selected slice") != NULL,
          "fat retype: the refusal says no slice matched (log: %s)", g_log);
    rm_dir();
}

static void test_fat_section_retype_arch_limits_the_match(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat"); in_dir(out, sizeof out, "fat.out");
    write_fat(path, DYLD_INFO | POINTER_SECTS, DYLD_INFO, 0);
    snap before = take(path);
    int rc = run(path, out, "arch arm64\nsection retype __DATA,__got non-lazy-symbol-pointers regular\n");
    CHECK(rc == MR_REFUSED, "fat retype, arch arm64: x86_64's match does not count (got %d)", rc);
    check_untouched("fat retype, arch", path, &before);
    rm_dir();
}

static void test_fat_section_retype_refuses_a_slice_without_dyld_info(void) {
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "fat"); in_dir(out, sizeof out, "fat.out");
    write_fat(path, DYLD_INFO | POINTER_SECTS, POINTER_SECTS, 0);
    snap before = take(path);
    int rc = run(path, out, "section retype __DATA,__got non-lazy-symbol-pointers regular\n");
    CHECK(rc == MR_REFUSED, "fat retype: a matching slice with no LC_DYLD_INFO refuses the run (got %d)", rc);
    check_untouched("fat retype, classic slice", path, &before);
    CHECK(strstr(g_log, "in slice arm64") != NULL, "fat retype: the refusal names the slice (log: %s)", g_log);
    rm_dir();
}
```

Call all three from `main`, after `test_fat_unmatched_counts_a_match_in_any_slice();`.

- [ ] **Step 2: Run them**

Run `-R edit_test --output-on-failure`. Expected: PASS on first run (see above).

- [ ] **Step 3: Mutation-prove**

Apply each to `src/edit.c`'s `MS_SECTION` case, build (confirm `edit.c.o` rebuilt), run `-R edit_test`, see the named failure, and restore:

1. `if (!v->decide || *v->renamed > 0) return 0;` → `if (*v->renamed > 0) return 0;`. This takes the verdict per slice. Expect "a match in a LATER slice is not a miss".
2. `*v->renamed += retyped;` → `*v->renamed = retyped;`. This lets a later slice's miss erase an earlier match. Expect "a match in the first slice only is a match".

- [ ] **Step 4: Commit**

```bash
git add tests/edit_test.c
git commit -m "test(edit): pin section retype's per-slice semantics on fat files

A match in any selected slice counts, judged in the last one; arch
limits which slices count; a matching slice without LC_DYLD_INFO[_ONLY]
refuses the whole run and is named. Passes first time on the shared
verdict; proved by making the verdict per-slice and by overwriting the
sum, each of which fails a named case.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF"
```

---

### Task 5: End to end on a linked binary: bytes, `grow`, and running it

This task measures what the spec left open. Does a retyped 10.9 binary run the
same as its input on this host's `dyld-239.5` and on CI? Does retype with grow
give the same bytes in either order?

**Files:**
- Test: `tests/section_retype_test.sh` (insert before `reached_end=1`)

**Interfaces:**
- Consumes: `info_types`, `$ST` and `$T/prog` (Task 1); the statement (Task 3).
- Produces: nothing new.

- [ ] **Step 1: Write the tests**

Insert before `reached_end=1`:

```sh
# ---- section retype, end to end ----------------------------------------------
# The base image carries no code signature, so every byte a retype changes is
# one this suite can account for.
cp "$T/prog" "$T/base"
if "$DMR" info "$T/prog" | grep -q ' LC_CODE_SIGNATURE '; then
    rc=0; printf 'load-command delete codesig\n' | "$DMR" "$T/prog" "$T/base" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || bad "base" "could not strip the linker's signature (exit $rc)"
fi

info_types "$T/base" | awk '
    $3 == "non-lazy-symbol-pointers" || $3 == "symbol-stubs" {
        print "section retype " $1 "," $2 " " $3 " regular" }' >"$T/retype.edits"
grep -q ' non-lazy-symbol-pointers ' "$T/retype.edits" && grep -q ' symbol-stubs ' "$T/retype.edits" \
    && ok "retype: the fixture yields a statement of each kind (positive control)" \
    || bad "retype edits" "$(cat "$T/retype.edits")"

rc=0; "$DMR" "$T/base" "$T/retyped" <"$T/retype.edits" >"$T/retype.out" 2>"$T/retype.err" || rc=$?
[ "$rc" -eq 0 ] && ok "retype: every such section retyped" \
    || bad "retype" "exited $rc: $(cat "$T/retype.err")"
info_types "$T/retyped" | grep -qE ' (non-lazy-symbol-pointers|symbol-stubs)$' \
    && bad "retype" "info still reports: $(info_types "$T/retyped" | grep -E ' (non-lazy-symbol-pointers|symbol-stubs)$')" \
    || ok "retype: info reports no non-lazy or stub section afterwards"

# Exactly one byte per retyped section differs: its flags' low byte (little-endian).
"$ST" list "$T/base" | awk '$3 == "0x06" || $3 == "0x08" { print $4 + 1 }' | sort -n >"$T/want.bytes"
cmp -l "$T/base" "$T/retyped" | awk '{ print $1 }' | sort -n >"$T/got.bytes"
[ -s "$T/want.bytes" ] && cmp -s "$T/want.bytes" "$T/got.bytes" \
    && ok "retype: the only bytes changed are the retyped sections' type bytes" \
    || bad "retype bytes" "want offsets $(tr '\n' ' ' <"$T/want.bytes"), got $(tr '\n' ' ' <"$T/got.bytes")"

# Runs the same: stdout, stderr and exit status.
run_one() {
    rrc=0
    RETYPE_PROBE=probe "$1" b a >"$2.stdout" 2>"$2.stderr" || rrc=$?
    echo "$rrc" >"$2.rc"
}
run_one "$T/base" "$T/run.base"
run_one "$T/retyped" "$T/run.retyped"
[ "$(cat "$T/run.base.rc")" = 6 ] \
    && ok "run: the input runs as built (positive control)" \
    || bad "run base" "exit $(cat "$T/run.base.rc"): $(cat "$T/run.base.stderr")"
cmp -s "$T/run.base.stdout" "$T/run.retyped.stdout" && cmp -s "$T/run.base.stderr" "$T/run.retyped.stderr" \
    && cmp -s "$T/run.base.rc" "$T/run.retyped.rc" \
    && ok "run: the retyped binary behaves exactly as its input" \
    || bad "run retyped" "exit $(cat "$T/run.retyped.rc"); stderr: $(cat "$T/run.retyped.stderr")"

# ---- retype and grow, in either order ------------------------------------------
pad_of() { "$DMR" info "$1" | awk '/^header pad: / { print $3; exit }'; }
text_vmaddr() {
    "$DMR" info "$1" | awk '/^  segname=__TEXT / {
        for (i = 1; i <= NF; i++) if ($i ~ /^vmaddr=/) { sub("vmaddr=", "", $i); print $i; exit } }'
}
pad=$(pad_of "$T/base")
n=$(( ${pad:-0} / 200 + 2 )); fill=$(printf '%0180d' 0); i=0
: >"$T/grow.edits"
while [ "$i" -lt "$n" ]; do
    printf 'rpath append /nonexistent/retype-probe-%d/%s\n' "$i" "$fill" >>"$T/grow.edits"
    i=$((i + 1))
done
cat "$T/retype.edits" "$T/grow.edits" >"$T/retype-first.edits"
cat "$T/grow.edits" "$T/retype.edits" >"$T/grow-first.edits"
rc1=0; "$DMR" "$T/base" "$T/retype-first" <"$T/retype-first.edits" >/dev/null 2>"$T/rf.err" || rc1=$?
rc2=0; "$DMR" "$T/base" "$T/grow-first" <"$T/grow-first.edits" >/dev/null 2>"$T/gf.err" || rc2=$?
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] \
    && ok "retype + grow: both orders succeed" \
    || bad "retype + grow" "retype first exited $rc1: $(cat "$T/rf.err"); grow first exited $rc2: $(cat "$T/gf.err")"
[ "$(text_vmaddr "$T/retype-first")" != "$(text_vmaddr "$T/base")" ] \
    && [ "$(text_vmaddr "$T/grow-first")" != "$(text_vmaddr "$T/base")" ] \
    && ok "retype + grow: both really grew the header (the image base moved)" \
    || bad "retype + grow" "__TEXT vmaddr base=$(text_vmaddr "$T/base") rf=$(text_vmaddr "$T/retype-first") gf=$(text_vmaddr "$T/grow-first")"
cmp -s "$T/retype-first" "$T/grow-first" \
    && ok "retype + grow: the two orders give byte-identical output" \
    || bad "retype + grow" "outputs differ: $(cmp "$T/retype-first" "$T/grow-first")"
```

- [ ] **Step 2: Run them**

Run `-R section_retype_test --output-on-failure`. Expected: PASS on first run. This is the measurement the spec leaves open. If "the retyped binary behaves exactly as its input" fails, stop and report to the owner: it contradicts the spec's reading of dyld, and the answer to the spec's question 1 changes.

- [ ] **Step 3: Mutation-prove**

Each one is applied, built (confirm the named object rebuilt), run with `-R section_retype_test`, seen to fail as named, and restored:

1. `src/section.c`: `s[j].flags = (…) | c->to` → `s[j].flags = c->to`. Expect "the only bytes changed are…". `__stubs`' attribute byte changes too.
2. `src/edit.c`'s `MS_SECTION` case: pass `S_MOD_INIT_FUNC_POINTERS` in place of `to` to `msec_retype`. dyld then calls each `__got` entry as an initialiser. Expect "the retyped binary behaves exactly as its input". This mutation is what makes that test falsifiable.
3. **`src/grow.c:809`, temporary, never committed:** `if (type > S_INIT_FUNC_OFFSETS) {` → `if (type > S_INIT_FUNC_OFFSETS || type == S_SYMBOL_STUBS) {`. Expect "both orders succeed" to fail on the grow-first order. Restore it **by reversing that exact edit**, not with `git checkout`, because another agent may have uncommitted work in `src/grow.c`. Then confirm `git diff -- src/grow.c` shows only what was there before this step.

- [ ] **Step 4: Commit**

```bash
git add tests/section_retype_test.sh
git commit -m "test(section): a retyped binary runs as its input, and grow does not care

Against a binary linked here: exactly one byte per retyped section
changes; the result runs with the same stdout, stderr and exit status on
this host's dyld; and retype-then-grow and grow-then-retype give the same
bytes, because grow accepts regular, non-lazy and stub sections alike.
Falsified by retyping to mod-init-func-pointers (dyld calls __got), and
by a grow that refuses stubs.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF"
```

---

### Task 6: README

Only the lines this feature adds. Nothing else in `README.md` changes.

**Files:**
- Modify: `README.md:52-71` (the Statements block), `:92-97` (the can-miss list), `:208-248` (Queries)

**Interfaces:**
- Consumes: the finished statement and `info` line.
- Produces: nothing.

- [ ] **Step 1: Edit**

In the Statements block, add after the `import redirect` line:

```
section       retype    SEG,SECT FROM TO
                                    FROM: non-lazy-symbol-pointers | symbol-stubs
                                    TO: regular
```

After the paragraph that follows the block, add:

```markdown
`section retype` changes only the section's type. It refuses an image with
no `LC_DYLD_INFO` or `LC_DYLD_INFO_ONLY` (write `fixups set classic` first on
one with chained fixups), because there dyld finds non-lazy pointers by
section type.
```

In the can-miss list, add after the `import redirect` item:

```markdown
- `section retype` (no section of that name has type FROM)
```

In Queries, change `info`'s summary from `load commands, ordinals, sections, header pad` to `load commands, ordinals, sections and their types, header pad`. In the example, add `      type=regular` under each of the three `    sectname=` lines.

- [ ] **Step 2: Check the diff touches only those lines**

Run `git diff -- README.md`. Every `+` line is one of the above, and there are no `-` lines except the one `info` summary line. The positive control is that the diff is not empty.

- [ ] **Step 3: Run the full suite**

Run the full test command. Expected: all PASS. `README.md` is read by no test, so this is only a final check that the tree is green.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: section retype, and info's section types

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF"
```

---

## Self-Review

**Spec coverage.**

| Spec section | Task |
|---|---|
| §1 `info` types, six spaces, hex fallback, consumer sweep | 1 |
| §2 grammar: first-comma split, 1–16 bytes, section's own names, FROM required, TO `regular` | 2 (core), 3 (parser) |
| §3 type byte only, `MREL_NONE`, classic refusal only on a match | 2, 3 |
| §4 matched and unmatched, refuse-by-default, log line | 3 |
| §5 fat and `arch` | 4 |
| §6 grow tension, order-independence, falsified through `grow.c` | 5 |
| §7 `target` does not derive it | no code. `me_expand_10_9` is untouched, and `cli_test`'s existing target blocks stay green |
| Testing table | Tasks 1–5 |
| Owner question 1 (build at all?) | gates Task 2 onward. See "Before starting" |

**Placeholder scan.** No TBD, no "similar to Task N". Every code step has its code. The one value filled in at execution time is the sweep's hit count in Task 1's commit message, which Step 1 produces.

**Type consistency.** These names are the same in every task: `msec_type_name`, `msec_type_by_name`, `msec_retypable`, `msec_split(…, char seg[MSEG_NAME_MAX + 1], char sect[MSEG_NAME_MAX + 1])`, `msec_retype(const mi_image *, …, int *retyped)`, `MSEC_NO_DYLD_INFO`, `MS_SECTION` + `MS_RETYPE`, `POINTER_SECTS`, `sect_flags`, `info_types`, `$ST`. The log line `      retyped 1 section\n` in Task 3's test matches the `me_say` format. The stderr miss line matches the spec's §4 text.
