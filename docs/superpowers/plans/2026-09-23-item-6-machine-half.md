# Item 6, the Machine Half: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `src/grow.c`'s 50 diagnostics program-neutral, with tests first. Fix the present-tense citations of eight retired filenames. Move the compat wrappers', support files' and CLI's narration to tests, commit messages and `compat/README.md`. Record the result in the queue.

**Architecture:** Eleven tasks, each reviewable alone. Tasks 1–2 write the tests for the diagnostic prefix and then change it. Task 3 fixes the citations. Tasks 4–9 do the comment pass one file at a time. A test comes first wherever a passage states behaviour that nothing asserts. Task 10 handles the CLI's history markers and Task 11 the queue. Comment edits use a line-range tool, `rr`, that checks the first and last line of each range before it replaces anything. A wrong range therefore refuses instead of damaging code.

**Tech Stack:** C99, POSIX `/bin/sh`, CMake/ctest via shipyard, `git grep`.

**Spec:** `docs/superpowers/specs/2026-09-23-item-6-machine-half-design.md`

## Global Constraints

- **Home order, binding on every comment passage, and to be copied into every implementer brief and every fix-round message:** a test first, then the commit message, then `compat/README.md`, and only then ONE inline sentence where a reader must see it at that line to avoid breaking it. A finding about a comment is resolved by moving the passage to its home, never by rewording it in place at the same length. Narration is the expensive class: accounts of retired tools, measured transcripts, quotations of earlier comment text, and "used to" or "now". Every "can't happen" claim in touched text is deleted, or names the test that holds it.
- **TDD** wherever behaviour or a user-visible string changes. Mutation-prove every new assertion: apply the named mutation, see it fail, then revert.
- **Clock skew:** this host's clock is skewed, so an mtime proves nothing. For C, confirm the rebuild with `strings BINARY | grep -c 'EXPECTED TEXT'`. For a staged shell file, confirm with `cmp compat/X.sh /private/tmp/build/schmonz/drydock-native/X`.
- **No history narration and no plan/task/spec references in source.** `docs/superpowers/` is ephemeral: never cite it from source, tests, `compat/README.md` or a commit message.
- **Never touch `README.md`.** Also never touch `src/declassify.c`, `src/version_min.*`, or the `target`/`me_target` code in `src/edit.c` and `src/script.c`.
- **Build:** `/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j`
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native`. Expected: 22 tests, and `chained_fixups` skips on this host. For one suite, add `-R NAME --output-on-failure`. The names are `grow_test`, `wrapper_test`, `translate_test`, `cli_test`, `image_test`, `trie_test`, `linkedit_test`, `change_dylib_test` and `leaf_tool_crashes`.
- **Greps:** every negative needs a positive control (a hit on something known to exist), and every count states its scope (files and pattern). `git grep -E` has no `\b`. Use `git grep`, not `grep -r`, which skips gitignored paths.
- **Shell suites:** never let a bare nonzero command sit under `set -e`. Capture with `rc=0; cmd || rc=$?`.
- **Other agents are working in this checkout.** Stage explicit paths only. Never `git add -A` or `git add .`. Before editing a file, run `git diff --quiet -- FILE`. If it has changes you did not make, stop and report; do not edit it. Before each commit, `git diff --cached --stat` must list only the task's files.
- **Commit trailer, exactly:**
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
  ```
- **Line numbers** are at `d1cab99`, except in Task 10, which is at `26d6f8c`. `rr` checks each range's first and last line, compared after stripping leading whitespace. If it refuses because a file moved, find the range with `grep -n -F 'ANCHOR TEXT' FILE` and re-run with the new numbers. Apply a file's `rr` edits in the order given, which is always bottom to top.
- **Tools.** Every Bash call starts a fresh shell, so source `rr` in each call that uses it. Create both tools once, before Task 1:

```sh
mkdir -p /private/tmp/drydock-item6
cat > /private/tmp/drydock-item6/rr.sh <<'EOF'
# rr FILE START END 'first line' 'last line' <<'X' ... X
# Replace lines START..END of FILE with stdin (use </dev/null to delete).
# Both anchor lines are compared after stripping leading whitespace. FILE's
# mode is kept.
rr() {
    rr_f=$1 rr_s=$2 rr_e=$3
    rr_a=$(sed -n "${rr_s}p" "$rr_f" | sed 's/^[[:space:]]*//')
    rr_b=$(sed -n "${rr_e}p" "$rr_f" | sed 's/^[[:space:]]*//')
    [ "$rr_a" = "$4" ] || { printf 'rr: %s:%s is [%s], not [%s]\n' "$rr_f" "$rr_s" "$rr_a" "$4" >&2; return 1; }
    [ "$rr_b" = "$5" ] || { printf 'rr: %s:%s is [%s], not [%s]\n' "$rr_f" "$rr_e" "$rr_b" "$5" >&2; return 1; }
    { awk -v s="$rr_s" 'NR < s' "$rr_f"; cat; awk -v e="$rr_e" 'NR > e' "$rr_f"; } > "$rr_f.rr" \
        && cat "$rr_f.rr" > "$rr_f" && rm -f "$rr_f.rr"
}
EOF
cat > /private/tmp/drydock-item6/density.sh <<'EOF'
#!/bin/sh
# density.sh FILE... -- total / comment / code lines and the first code line.
# Shell: a comment line's first non-blank is '#', the shebang excluded.
# C: a comment line is inside /* */ or starts with //; preprocessor is code.
for f in "$@"; do
  case $f in
    *.sh) awk -v f="$f" '
      NR==1 && /^#!/ { next }
      /^[[:space:]]*$/ { next }
      /^[[:space:]]*#/ { c++; next }
      { k++; if (!first) first = NR }
      END { printf "%s total=%d comment=%d code=%d first_code=%d\n", f, NR, c, k, first }' "$f" ;;
    *.c|*.h) awk -v f="$f" '
      { line = $0; iscom = 0; iscode = 0
        if (inc) { iscom = 1; if (index(line, "*/")) { inc = 0; rest = substr(line, index(line, "*/") + 2); if (rest ~ /[^[:space:]]/) iscode = 1 } }
        else if (line ~ /^[[:space:]]*\/\//) iscom = 1
        else if (line ~ /^[[:space:]]*\/\*/) { iscom = 1; if (!index(substr(line, index(line, "/*") + 2), "*/")) inc = 1 }
        else if (line ~ /[^[:space:]]/) { iscode = 1; if (index(line, "/*") && !index(substr(line, index(line, "/*") + 2), "*/")) inc = 1 }
        if (iscode) { k++; if (!first) first = NR } else if (iscom) c++ }
      END { printf "%s total=%d comment=%d code=%d first_code=%d\n", f, NR, c, k, first }' "$f" ;;
  esac
done
EOF
chmod +x /private/tmp/drydock-item6/density.sh
```

  The density tool's positive control, run once: `printf '/* a\n * b */\nint x; /* c */\n#include <x>\n' > /private/tmp/drydock-item6/ctl.c && /private/tmp/drydock-item6/density.sh /private/tmp/drydock-item6/ctl.c` must print `total=4 comment=2 code=2 first_code=3`.

- **The no-code-changed check** for a comment-only shell edit must print nothing:
  `git diff -U0 -- FILE | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'`.
  Its positive control is `printf '%s\n' '+    exit 1' | grep -vE '^[-+][[:space:]]*(#|$)'`, which prints `+    exit 1`. For C, filter with `grep -vE '^[-+][[:space:]]*(/?\*|//|$)'` instead, with the same control.

---

### Task 1: Assertions on the new diagnostic prefix, failing

**Files:**
- Modify: `tests/grow_test.c`. The match in `stderr_contains_during` is at `:1267-1268`. A new test goes directly above `int main(void) {` (`:1836`). One call is added at the end of `main`'s list (`:1882`).
- Modify: `tests/wrapper_test.sh`. The insertion goes directly above `# ADOPTED CHANGE 6: THE SAME -change ON A PIE COPY GROWS THE HEADER.` (`:1923`).

**Interfaces:**
- Produces: `stderr_contains_during(call, pbuf, pfsize, grow, needle, &ret)`, where a needle that begins with `^` must start a stderr line, and any other needle is a substring as before. Also produces `test_grow_diagnostics_name_no_program(void)` and `plausible_thunk(uint8_t **, size_t *, uint32_t)`.
- Consumes: the existing helpers `check_ensure_refuses_unchanged(what, opts, filetype, flags, needle)`, `check_grow_precondition_refused(what, with_pagezero, pagezero_vmsize, text_fileoff, needle)`, `build_growable_image`, `build_image`, `first_sect_thunk` / `g_first`, and `MG_T_UNKNOWN_LC`, `MG_T_CHAINED`, `MG_T_FUNCSTARTS`.

**This task does not commit.** Its tests fail until Task 2, and the two tasks ship as one commit so `main` is never red.

- [ ] **Step 1: Record the count and its controls (scope: `src/grow.c`; `tests/ cli/ compat/`)**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git grep -c 'fprintf(stderr, "macho_grow: ' -- src/grow.c        # expect src/grow.c:50
git grep -n 'macho_grow: ' -- tests cli compat                   # expect exactly compat/README.md:661
git grep -n 'drydock-macho-rewrite: ' -- tests cli compat | wc -l  # positive control: 12
```

- [ ] **Step 2: Anchor the stderr needle.** In `tests/grow_test.c`, replace

```c
        while (fgets(line, sizeof line, rf))
            if (strstr(line, needle)) { found = 1; break; }
```

with

```c
        while (fgets(line, sizeof line, rf))
            if (needle[0] == '^' ? strncmp(line, needle + 1, strlen(needle + 1)) == 0
                                 : strstr(line, needle) != NULL) { found = 1; break; }
```

- [ ] **Step 3: Write the library test.** Insert directly above `int main(void) {`:

```c
static int plausible_thunk(uint8_t **pbuf, size_t *pfsize, uint32_t unused) {
    (void)unused;
    return mg_plausible(*pbuf, *pfsize);
}

/* grow.c is a library, so its diagnostics name no program: each begins
 * "ERROR: ", as src/rewrite.c's do. A needle starting '^' must start the
 * line. One message of each kind. */
static void test_grow_diagnostics_name_no_program(void) {
    check_ensure_refuses_unchanged("a dylib, by its prefix", 0, MH_DYLIB, MH_PIE,
                                   "^ERROR: only MH_EXECUTE can be grown (filetype=6)");
    check_ensure_refuses_unchanged("a non-PIE executable, by its prefix", 0, MH_EXECUTE, 0,
                                   "^ERROR: executable is not PIE (flags=0x");
    check_ensure_refuses_unchanged("an unclassified load command, by its prefix",
                                   MG_T_UNKNOWN_LC, MH_EXECUTE, MH_PIE,
                                   "^ERROR: load command 0x");
    check_ensure_refuses_unchanged("chained fixups, by its prefix", MG_T_CHAINED,
                                   MH_EXECUTE, MH_PIE,
                                   "^ERROR: LC_DYLD_CHAINED_FIXUPS: chained pointers");
    check_grow_precondition_refused("no __PAGEZERO, by its prefix", 0, 0, 0,
                                    "^ERROR: need a __PAGEZERO >= 4096 bytes");

    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_growable_image(&fsize, &sect_off);
    ((struct mach_header *)buf)->magic = MH_MAGIC;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
                                      "^ERROR: not a 64-bit Mach-O (magic=0xfeedface)", &r);
    CHECK(said && r == -1, "a 32-bit header's refusal begins 'ERROR: ' (got %d)", r);
    free(buf);

    size_t jsize = 64;
    uint8_t *junk = (uint8_t *)calloc(1, jsize);
    said = stderr_contains_during(first_sect_thunk, &junk, &jsize, 0,
                                  "^ERROR: image fails validation (bad magic", &r);
    CHECK(said && g_first == UINT32_MAX,
          "mg_first_sect_off's validation failure begins 'ERROR: ' (got %u)", g_first);
    free(junk);

    buf = build_image(&fsize, &sect_off, MG_T_FUNCSTARTS);
    ((uint32_t *)(buf + sect_off))[0] += 0x10;
    said = stderr_contains_during(plausible_thunk, &buf, &fsize, 0,
                                  "^ERROR: implausible -- ", &r);
    CHECK(said && r == -1, "mg_plausible's refusal begins 'ERROR: ' (got %d)", r);
    free(buf);
}

```

  Then in `main`, replace

```c
    test_grow_refuses_a_section_past_the_image();
    if (fails) {
```

  with

```c
    test_grow_refuses_a_section_past_the_image();
    test_grow_diagnostics_name_no_program();
    if (fails) {
```

- [ ] **Step 4: Write the CLI-level assertion.** In `tests/wrapper_test.sh`, insert directly above the line `# ADOPTED CHANGE 6: THE SAME -change ON A PIE COPY GROWS THE HEADER.`. At that point `$T/err` still holds the `fix_macho` run that the grow refused as non-PIE:

```sh
# The grow is library code, so the refusal a user sees names no program.
grep -q '^ERROR: executable is not PIE (flags=0x' "$T/err" \
    && ! grep -q '^macho_grow: ' "$T/err" \
    && ok "fix_macho: ... and the grow's own refusal begins 'ERROR: ', naming no program" \
    || bad "fix_macho mid-script refusal" "the grow's refusal is not program-neutral: $(grep 'not PIE' "$T/err")"

```

- [ ] **Step 5: Prove each needle matches today's text apart from the prefix.** Temporarily swap the prefix in the test, build, and confirm everything passes:

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
sed -i '' 's/"\^ERROR: /"^macho_grow: /' tests/grow_test.c
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
strings /private/tmp/build/schmonz/drydock-native/grow_test | grep -c '^\^macho_grow: '   # expect 8
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native -R grow_test --output-on-failure
sed -i '' 's/"\^macho_grow: /"^ERROR: /' tests/grow_test.c
```

  Expected: `grow_test` PASSES. If one CHECK fails, its needle is wrong about the text after the prefix. Correct that needle to the real line, which `stderr_contains_during`'s capture shows when you print it, and repeat. The needle must still begin `^ERROR: `.

- [ ] **Step 6: Build and see the new assertions fail**

```sh
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
strings /private/tmp/build/schmonz/drydock-native/grow_test | grep -c '^\^ERROR: '   # expect 8
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native -R 'grow_test|wrapper_test' --output-on-failure
```

  Expected: both FAIL. `grow_test` prints eight `FAIL:` lines, each naming one needle, for example `FAIL: ensure_pad on a dylib, by its prefix: the refusal says '^ERROR: only MH_EXECUTE can be grown (filetype=6)'`. `wrapper_test` prints `FAIL fix_macho mid-script refusal: the grow's refusal is not program-neutral: macho_grow: executable is not PIE (flags=0x85); ...`. No other assertion fails.

---

### Task 2: `src/grow.c`'s diagnostics become `ERROR: `

**Files:**
- Modify: `src/grow.c` (the 50 `fprintf(stderr, "macho_grow: ` lines)
- Modify: `compat/README.md:661` (the one quotation of the old prefix)
- Commit also: Task 1's `tests/grow_test.c`, `tests/wrapper_test.sh`

**Interfaces:**
- Consumes: Task 1's failing assertions.
- Produces: every diagnostic in `src/grow.c` begins `ERROR: ` and the text after it is unchanged. Later tasks rely on no `macho_grow: ` in `src/`.

**The replacement, per class.** It is the same for every class: refusals after examining the image, validation failures, internal errors and `verify FAILED`, and allocation failures (`realloc failed`, `out of memory`). All become `ERROR: `. This matches `src/rewrite.c`'s siblings (`:585`, `:595`, `:602`, `:714`, `:738`, `:996`, `:1000`), and `src/grow.c`'s own `mg_ensure_pad`, whose six refusals (`:63`–`:102`) already begin `ERROR: %s: `. No message's wording after the prefix changes.

- [ ] **Step 1: Change the prefixes**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
sed -i '' 's/fprintf(stderr, "macho_grow: /fprintf(stderr, "ERROR: /' src/grow.c
git grep -c 'fprintf(stderr, "ERROR: ' -- src/grow.c    # expect src/grow.c:56 (50 changed, plus mg_ensure_pad's 6)
git grep -n 'macho_grow: ' -- src                       # expect nothing
git grep -n 'fprintf(stderr, "ERROR: ' -- src/rewrite.c | head -1   # positive control: a hit
```

- [ ] **Step 2: Update the README's quotation.** In `compat/README.md`, replace `` `macho_grow: only MH_EXECUTE can be grown ...` `` with `` `ERROR: only MH_EXECUTE can be grown ...` ``. Then `git grep -n 'macho_grow: ' -- tests cli compat src` must print nothing. Its positive control is Task 1 Step 1's count of 12.

- [ ] **Step 3: Build, confirm the rebuild, run everything**

```sh
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
strings /private/tmp/build/schmonz/drydock-native/drydock-macho-rewrite | grep -c 'macho_grow: '   # expect 0
strings /private/tmp/build/schmonz/drydock-native/drydock-macho-rewrite | grep -c '^ERROR: executable is not PIE'   # expect 1
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

  Expected: 22 tests. All pass except `chained_fixups`, which skips.

- [ ] **Step 4: Mutation 1, one site reverted.** Both suites must catch it.

```sh
sed -i '' 's/"ERROR: executable is not PIE/"macho_grow: executable is not PIE/' src/grow.c
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
strings /private/tmp/build/schmonz/drydock-native/drydock-macho-rewrite | grep -c 'macho_grow: executable is not PIE'   # expect 1
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native -R 'grow_test|wrapper_test' --output-on-failure
sed -i '' 's/"macho_grow: executable is not PIE/"ERROR: executable is not PIE/' src/grow.c
```

  Expected: `grow_test` fails on "a non-PIE executable, by its prefix", and `wrapper_test` fails on "the grow's own refusal begins 'ERROR: '". The last `sed` reverts the mutation.

- [ ] **Step 5: Mutation 2, a doubled prefix.** Only the line-start anchor catches it.

```sh
sed -i '' 's/"ERROR: only MH_EXECUTE/"macho_grow: ERROR: only MH_EXECUTE/' src/grow.c
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
strings /private/tmp/build/schmonz/drydock-native/grow_test | grep -c 'macho_grow: ERROR: only'   # expect 1
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native -R grow_test --output-on-failure
sed -i '' 's/"macho_grow: ERROR: only MH_EXECUTE/"ERROR: only MH_EXECUTE/' src/grow.c
```

  Expected: FAIL on "a dylib, by its prefix". After the revert, `git diff --stat -- src/grow.c` shows 50 lines changed. Rebuild, and the full ctest run is green again.

- [ ] **Step 6: Commit**

```sh
git add src/grow.c compat/README.md tests/grow_test.c tests/wrapper_test.sh
git diff --cached --stat   # exactly those four files
git commit -F - <<'EOF'
fix(grow): diagnostics name no program

src/grow.c is library code, but 50 of its stderr lines began
"macho_grow: ", the name of the header-only library it used to be.
src/rewrite.c's convention is that library diagnostics are
program-neutral ("ERROR: ...") and only a front end's own prefix names a
program; grow.c now follows it. The wording after the prefix is
unchanged, for every class: refusals, validation failures, internal
errors and allocation failures alike.

Nothing pinned the old prefix. tests/grow_test.c's stderr capture gains
a line-start anchor ('^') and asserts "ERROR: " on one message of each
kind; tests/wrapper_test.sh asserts it on the fix_macho non-PIE refusal
a user sees. Both were run against the old text and failed.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h   # record this SHA for Task 11
```

---

### Task 3: Retired-filename citations

**Files:**
- Modify: `CMakeLists.txt:181-193`, `src/grow.c:1-10` and `:1064`, `src/grow.h:2`, `src/image.c:49-50`, `src/image.h:3-6, 75, 96-98, 115, 155`, `src/linkedit.h:3, 29, 36-38`, `src/trie.h:3, 29`, `src/uleb.c:5`, `src/uleb.h:11`, `src/ordinals.c:49`, `src/ordinals.h:28-29`, `cli/drydock-macho-rewrite.c:382-384`
- Modify: `tests/image_test.c:4-8, 140, 436`, `tests/trie_test.c:48, 71, 266`, `tests/change_dylib_test.sh:1424, 1508-1510, 1579`, `tests/leaf-tool-crashes.sh:478-479`
- Not here: the `compat/*.sh` citations go in Tasks 5–9, with their headers.

**Interfaces:** Consumes nothing. Produces nothing later tasks call. Task 10 relies on `cli/drydock-macho-rewrite.c:382-384` staying three lines.

**The rule.** Keep past-tense provenance, such as "This is compat/rename_segment.c's former …", "Extracted from change_dylib.c", or "compat/fix_macho.c's `-change` used to …". Fix any present-tense directive that sends a reader to a file that does not exist. Nothing moves to `PROVENANCE.md`: it is about the upstream extraction and already names all eight originals.

- [ ] **Step 1: Recount, with scope and control**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
P='macho_grow\.h|macho_grow_test\.c|(change_dylib|fix_macho|patch_macho|rename_segment|add_version_min|retag_swift_classes)\.c'
git grep -n -E "$P" -- src cli tests compat CMakeLists.txt | wc -l    # expect 97
git grep -c 'grow\.h' -- src | head -1                                # positive control: a hit
```

- [ ] **Step 2: Multi-line edits with `rr`**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
. /private/tmp/drydock-item6/rr.sh

rr CMakeLists.txt 181 193 "# -Wall deploys lesson nine's detection net (tests/README.md): a" '# translation unit does not all use.' <<'EOF'
# -Wall: a -Wfortify-source "will always overflow" strcpy into a char[16]
# segname/sectname fires here at compile time, on any host, before a
# modern-clang runner would abort at run time building the same fixture
# (tests/README.md, lesson nine).
EOF

rr src/grow.c 1 10 "/* grow.c -- see grow.h for the design and every function's contract." '* grow_test are the proof. */' <<'EOF'
/* grow.c -- see grow.h for the design and every function's contract. */
EOF

rr src/image.c 49 50 '* validation (mg_first_sect_off and friends in macho_grow.h,' "* change_dylib.c's build_lcs, ordinals.c's mo_map_build) inherits" <<'EOF'
         * validation (mg_first_sect_off and friends in src/grow.c,
         * rewrite.c's mr_build_lcs_lc, ordinals.c's mo_map_build) inherits
EOF

rr src/image.h 3 6 '* The layer under every rewriter in this repo. Today each of the seven opens a' '* eleven times. They agree by coincidence. This is the one they converge on.' <<'EOF'
 * The layer under every rewriter in this repo: one validated open and one
 * load-command walk for all of them.
EOF

rr src/linkedit.h 36 38 '* macho_grow.h -- they are about repositioning the header pad and the' '* task that created this module scoped it to the latter only.' <<'EOF'
 * src/grow.c -- they are about repositioning the header pad and the
 * entry point, not about __LINKEDIT's own resident structures.
EOF

rr src/ordinals.h 28 29 "* survive?\" (change_dylib.c's ord_is_deleted is called from both its own" '* load-command rewrite and from mo_map_build; see change_dylib.c). As a' <<'EOF'
 * survive?" (src/rewrite.c's mr_is_deleted, called from both
 * mr_build_lcs_lc and mo_map_build). As a
EOF

rr cli/drydock-macho-rewrite.c 382 384 "* mo_lc_str_at (ordinals.h), which change_dylib.c's build_lcs and" "* what the rewriters consider in-bounds, the way it briefly did. */" <<'EOF'
 * mo_lc_str_at (ordinals.h), which rewrite.c's mr_build_lcs_lc and
 * mo_map_build also call -- so this dump can't drift out of agreement with
 * what the rewriters consider in-bounds. */
EOF

rr tests/image_test.c 4 8 '* What this pins: every one of the seven rewriters currently opens a Mach-O by' '* not by construction. This tests the one implementation they are converging on.' <<'EOF'
 * What this pins: the one open/validate/iterate implementation every
 * rewriter here goes through.
EOF

rr tests/change_dylib_test.sh 1508 1510 '# which walks the REAL load commands instead of the -change arguments -- see' '# approximation it still makes.' <<'EOF'
# which walks the REAL load commands instead of the -change arguments; see
# mr_change_growth_bytes in src/rewrite.c.
EOF

rr tests/leaf-tool-crashes.sh 478 479 "# The array was then enlarged from [4] to [16] (see patch_macho.c's own" '# comment on struct pm_collect_ctx): review found that [4] left ZERO margin' <<'EOF'
# The array was then enlarged from [4] to [16] (see the comment above struct
# md_collect_ctx in src/declassify.c): review found that [4] left ZERO margin
EOF
```

  The `change_dylib_test.sh` edit fixes a claim as well as a name. `mr_change_growth_bytes`'s own comment says the over-budget case is gone, so "the one approximation it still makes" was false.

- [ ] **Step 3: Single-substring edits** (Edit tool, exact substring, unique in its file)

| file | replace | with |
|---|---|---|
| `src/grow.c` | `macho_grow_test.c's test_grow_refuses_32bit_mach_header` | `tests/grow_test.c's test_grow_refuses_32bit_mach_header` |
| `src/grow.h` | ` * macho_grow.h — make room` | ` * grow.h — make room` |
| `src/image.h` | `(macho_grow_test.c builds several)` | `(tests/grow_test.c builds several)` |
| `src/image.h` | `(rename_segment.c's rs_rename_lc)` | `(segname.c's mseg_rename_lc)` |
| `src/image.h` | `(retag_swift_classes.c's retag())` | `(swift_retag.c's mswift_retag())` |
| `src/image.h` | `bits (patch_macho.c's pm_collect_lc leaves` | `bits (declassify.c's md_collect_lc leaves` |
| `src/image.h` | `e.g. change_dylib.c's build_lcs on a malformed` | `e.g. rewrite.c's mr_build_lcs_lc on a malformed` |
| `src/image.h` | `macho_grow.h means by "base"` | `src/grow.c means by "base"` |
| `src/linkedit.h` | `* macho_grow.h's image-base trick (see its own header comment) lowers the` | `* src/grow.h's image-base trick (see its header comment) lowers the` |
| `src/linkedit.h` | `refused outright by macho_grow.h's` | `refused outright by src/grow.c's` |
| `src/trie.h` | ` * macho_grow.h's image-base trick adds` | ` * src/grow.c's image-base trick adds` |
| `src/trie.h` | `rather than walked. macho_grow.h's own hand-rolled` | `rather than walked. src/grow.c's own hand-rolled` |
| `src/uleb.c` | `untouched -- macho_grow_test already tests all three directly` | `untouched -- tests/grow_test.c tests all three directly` |
| `src/uleb.h` | `here. patch_macho.c` | `here. src/declassify.c` |
| `src/ordinals.c` | `buffer change_dylib.c owns and passes straight through` | `buffer mr_process_thin (src/rewrite.c) owns and passes straight through` |
| `tests/image_test.c` | `/* macho_grow_test.c builds Mach-O images` | `/* tests/grow_test.c builds Mach-O images` |
| `tests/image_test.c` | `fixup in macho_grow.h means` | `fixup in src/grow.c means` |
| `tests/trie_test.c` | `as macho_grow_test.c's MG_T_TRIE fixture` | `as tests/grow_test.c's MG_T_TRIE fixture` |
| `tests/trie_test.c` | `case macho_grow.h must now handle by growing` | `case mg_grow_header handles by growing` |
| `tests/trie_test.c` | `128 is macho_grow.h's own existing depth guard` | `128 is src/grow.c's own depth guard` |
| `tests/change_dylib_test.sh` | `# see the comment on that calculation in change_dylib.c.` | `# see mr_change_growth_bytes in src/rewrite.c.` |
| `tests/change_dylib_test.sh` | `# build_lcs_lc (change_dylib.c) calls mo_lc_str_at` | `# mr_build_lcs_lc (src/rewrite.c) calls mo_lc_str_at` |

  Every new name was checked at `d1cab99`:
  - `mr_build_lcs_lc` is at `rewrite.c:132`, and calls `mo_lc_str_at` at `:209` and `:261`;
  - `mr_is_deleted` is at `:60`, and is passed to `mo_map_build` at `:658` in `mr_process_thin`;
  - `mr_change_growth_bytes` is at `:516`;
  - `mseg_rename_lc` is at `segname.c:16`;
  - `mswift_retag` is at `swift_retag.c:123`;
  - `md_collect_lc` and `md_collect_ctx` are in `declassify.c`;
  - `ob_uleb` is at `declassify.c:110`.

- [ ] **Step 4: Recount against the kept list**

```sh
git grep -c -E "$P" -- src cli tests compat CMakeLists.txt
```

  Expected, exactly, 63 lines in total:

  ```
  compat/README.md:3
  compat/add_version_min.sh:1
  compat/patch_macho.sh:1
  compat/rename_segment.sh:4
  compat/retag_swift_classes.sh:3
  compat/translate.sh:5
  src/atomic_write.c:1
  src/atomic_write.h:1
  src/declassify.c:1
  src/declassify.h:2
  src/image.h:1
  src/lc_kinds.h:1
  src/mach_compat.h:4
  src/ordinals.h:2
  src/rewrite.c:1
  src/segname.c:1
  src/segname.h:3
  src/swift_retag.c:1
  src/swift_retag.h:3
  src/uleb.c:1
  src/version_min.c:1
  src/version_min.h:1
  tests/README.md:2
  tests/change_dylib_test.sh:8
  tests/cli_test.sh:2
  tests/compat-sweep.sh:2
  tests/leaf-tool-crashes.sh:1
  tests/linkedit_test.c:1
  tests/translate_test.sh:2
  tests/wrapper_test.sh:3
  ```

  Read every surviving `src/`, `tests/` and `compat/README.md` hit (`git grep -n -E "$P" -- src tests compat/README.md`). Each must be past tense, or must be one of the deferred lines: `src/declassify.c:2`, `src/version_min.c:2`, `src/version_min.h:10`, and `tests/cli_test.sh:1397`, which waits for the minos-set plan's `tests/cli_test.sh` work.

- [ ] **Step 5: Check that no code changed, build, run**

```sh
git diff -U0 -- src cli tests/image_test.c tests/trie_test.c | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(/?\*|//|$)'   # expect nothing
git diff -U0 -- CMakeLists.txt tests/change_dylib_test.sh tests/leaf-tool-crashes.sh | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'   # expect nothing
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

  Expected: both checks print nothing; ctest is green, with `chained_fixups` skipped.

- [ ] **Step 6: Commit**

```sh
git add CMakeLists.txt src/grow.c src/grow.h src/image.c src/image.h src/linkedit.h src/trie.h src/uleb.c src/uleb.h src/ordinals.c src/ordinals.h cli/drydock-macho-rewrite.c tests/image_test.c tests/trie_test.c tests/change_dylib_test.sh tests/leaf-tool-crashes.sh
git diff --cached --stat
git commit -F - <<'EOF'
docs: point at files that exist

Comments in src/, cli/ and tests/ told readers to go and read
macho_grow.h, macho_grow_test.c, change_dylib.c or patch_macho.c,
none of which exists any more. Each is repointed at the function's
current home (mr_build_lcs_lc and mr_is_deleted in src/rewrite.c,
md_collect_ctx in src/declassify.c, tests/grow_test.c) or deleted.
Past-tense provenance ("This is compat/rename_segment.c's former ...")
stays.

Also gone: src/grow.c's account of its own move out of macho_grow.h,
and two references to the task that did a piece of work, in
CMakeLists.txt and src/linkedit.h. tests/change_dylib_test.sh no longer
cites "the one approximation it still makes": mr_change_growth_bytes'
own comment says that over-budget case is gone.

Scope: src/ cli/ tests/ compat/ CMakeLists.txt, eight retired names:
97 lines before, 63 after, and the compat/ wrappers' own go with their
headers.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h
```

---

### Task 4: The shared machinery and the bootstrap prelude

**Files:**
- Test: `tests/wrapper_test.sh`. The insertion goes directly above `# ---- a wrapper finds drydock-macho-rewrite next to itself, not on PATH` (`:211`).
- Modify: `compat/drydock-macho-rewrite-compat.sh`
- Modify: `compat/README.md`. The insertion goes directly above `## Why the six wrapper names are unchanged`.

**Interfaces:**
- Produces: the assertion `"$w: a symlink to it elsewhere says to set DRYDOCK_MACHO_REWRITE_COMPAT_DIR (1)"` for all eight wrappers, which Tasks 5–8 cite when they delete their prelude comments. Also produces a `compat/README.md` section `## Thin only`, which Tasks 5, 7 and 8 point to, and `mw_thin_only`'s comment, which points there.

- [ ] **Step 1: Measure**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git diff --quiet d1cab99 -- compat/drydock-macho-rewrite-compat.sh || echo CHANGED-STOP
/private/tmp/drydock-item6/density.sh compat/drydock-macho-rewrite-compat.sh
```

  Expected: `total=448 comment=266 code=164 first_code=68`.

- [ ] **Step 2: Write the prelude test.** Insert above `# ---- a wrapper finds drydock-macho-rewrite next to itself, not on PATH`:

```sh
# ---- a symlinked wrapper, away from its support files -------------------
for w in patch_macho change_dylib add_version_min fix_macho rename_segment \
         retag_swift_classes insert_dylib bake-mavericks-shim; do
    rm -rf "$T/lnk"; mkdir "$T/lnk"; ln -s "$BIN/$w" "$T/lnk/$w"
    rc=0
    ( unset DRYDOCK_MACHO_REWRITE_COMPAT_DIR; "$T/lnk/$w" ) >"$T/out" 2>"$T/err" || rc=$?
    [ "$rc" -eq 1 ] \
        && firstline_is "$T/err" "$T/lnk/$w: cannot find drydock-macho-rewrite-compat.sh in $T/lnk -- drydock-macho-rewrite and its two support" \
        && grep -qF 'set DRYDOCK_MACHO_REWRITE_COMPAT_DIR to where they really are' "$T/err" \
        && ok "$w: a symlink to it elsewhere says to set DRYDOCK_MACHO_REWRITE_COMPAT_DIR (1)" \
        || bad "$w symlinked" "exit $rc: $(cat "$T/err")"
done
rm -rf "$T/lnk"

```

- [ ] **Step 3: Run it. It passes, because it characterizes existing behaviour.**

```sh
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native -R wrapper_test --output-on-failure
```

  Expected: PASS, including 8 new `PASS ...: a symlink to it elsewhere ...` lines.

- [ ] **Step 4: Mutate.** Delete the `[ -r "$MW_DIR/drydock-macho-rewrite-compat.sh" ] || { ... }` block (6 lines) from `compat/fix_macho.sh`. Rebuild, confirm `cmp compat/fix_macho.sh /private/tmp/build/schmonz/drydock-native/fix_macho` reports no difference, and run `wrapper_test`. Expected: `FAIL fix_macho symlinked`, because the shell's own `.` error replaces the message. Then run `git checkout -- compat/fix_macho.sh` and rebuild.

- [ ] **Step 5: Comment pass on `compat/drydock-macho-rewrite-compat.sh`** (bottom to top)

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
. /private/tmp/drydock-item6/rr.sh
F=compat/drydock-macho-rewrite-compat.sh

rr $F 401 422 '# mw_run_to_tmp -- run the translation (which writes MW_TMPFILE) with its' "# mw_teach's needles are fixed words -- so the hazard is gone with it." <<'EOF'
# mw_run_to_tmp -- run the translation (which writes MW_TMPFILE) with its
# stdout captured in $MW_T/out, forward that stdout, and return
# drydock-macho-rewrite's status. patch_macho.sh reads the capture back.
EOF

rr $F 384 388 '# mw_retranslate TOOL ARG... -- translate again, this time writing MW_TMPFILE.' '# it inspects the exit status, not the text.' <<'EOF'
# mw_retranslate TOOL ARG... -- translate again with MW_TMPFILE as the output.
# Re-translating, rather than editing the emitted line, keeps mt_qargs'
# quoting the only thing that parses a file name.
EOF

rr $F 354 363 "# REGULAR FILES ONLY. A directory's link count is always greater than" '# did.' <<'EOF'
        # Regular files only: a directory's link count is always above one,
        # and a directory falls through to drydock-macho-rewrite's own refusal.
EOF

rr $F 309 316 '# ---- the install path ----------------------------------------------------' '# sequence, shared rather than copied into each wrapper as they arrive:' <<'EOF'
# ---- the install path ----------------------------------------------------
#
# drydock-macho-rewrite never writes the file it is given, and the tools these
# wrappers replace edited FILE in place, so every wrapper writes a temp beside
# the real target and mv's it over:
EOF

rr $F 273 301 '# mw_thin_only FILE' '# (add_version_min <dir> exits 2 on both sides).' <<'EOF'
# mw_thin_only FILE -- return 1 when `info --thin` refuses FILE (EX_REFUSED):
# a fat container, or not a Mach-O. compat/README.md's "Thin only" has what
# each thin-only tool would do without this gate. EX_FAIL (2) falls through,
# so `add_version_min DIR` exits 2 on both sides.
EOF

rr $F 240 260 '# mw_require_writable FILE' '# tests/known-callers.sh pin them.' <<'EOF'
# mw_require_writable FILE -- the C tools opened FILE O_RDWR first, so an
# absent or unwritable FILE failed with perror("open"). drydock-macho-rewrite
# opens FILE read-only, so only this reproduces that. The two strings are
# pinned by tests/wrapper_test.sh and tests/known-callers.sh.
EOF

rr $F 221 235 '# ---- run -----------------------------------------------------------------' '# drydock-macho-rewrite, and it overrides that default for the one process that wants input.' <<'EOF'
# ---- run -----------------------------------------------------------------
#
# mw_run -- eval the translation: at most one command (retag_swift_classes.sh
# runs its per-file lines itself). </dev/null keeps it off the caller's stdin.
EOF

rr $F 213 216 '# Every line is a whole command now -- the statements ride inside the' '# shown stays pasteable verbatim.' <<'EOF'
    # One whole command per line, so indenting keeps it pasteable.
EOF

rr $F 183 191 '# COMMANDS, and every one of them is now exactly one line: a drydock-macho-rewrite' '# compared at all.' <<'EOF'
    # Count commands by their fixed first words. Caller text never reaches
    # awk here; any that must goes through ENVIRON, not -v, which runs it
    # through escape processing.
EOF

rr $F 159 175 '# ---- translate, and teach ------------------------------------------------' '# binary did.' <<'EOF'
# ---- translate, and teach ------------------------------------------------
#
# mw_translate TOOL ARG... -- fill MW_CMDS and MW_NCMDS, teach, and return
# compat/translate.sh's own code (0, or 1 or 2 with its message printed) for
# the caller to forward. MT_PROG0=$0, so a usage line names argv[0] as the C
# tools' did.
EOF

rr $F 109 114 '# NOT the same hard failure as a missing drydock-macho-rewrite-translate.sh above,' '# refuse: refusing would break that legitimate case outright.' <<'EOF'
    # Installed elsewhere on PATH is legitimate, so warn rather than refuse.
EOF

rr $F 92 104 '# PATH, not an absolute program word: the command lines translate.sh emits are' '# and that `env -i` check is what lets it stop answering to them.' <<'EOF'
# PATH, not an absolute program word: the taught commands say
# drydock-macho-rewrite and must mean the one beside this wrapper.
# tests/wrapper_test.sh re-runs a taught block under `env -i` to hold that.
EOF

rr $F 70 81 '# ---- locate everything ---------------------------------------------------' '# itself came out of.' <<'EOF'
# ---- locate everything ---------------------------------------------------
#
# MW_DIR comes from the wrapper. It is made absolute because it goes on PATH:
# a relative "." would resolve every helper against the working directory.
EOF

rr $F 2 66 "# compat/drydock-macho-rewrite-compat.sh -- the machinery the historical tools' /bin/sh" '# tests/compat-sweep.sh and tests/translate_test.sh made.' <<'EOF'
# compat/drydock-macho-rewrite-compat.sh -- what the historical tools' /bin/sh
# wrappers share. Sourced, never run:
#
#   MW_DIR=... ; . "$MW_DIR/drydock-macho-rewrite-compat.sh"
#
# A wrapper translates its argv (compat/translate.sh), teaches the equivalent
# on stderr, runs it into a temp beside the target, and installs the temp.
# Installed flat, beside drydock-macho-rewrite and
# drydock-macho-rewrite-translate.sh; $DRYDOCK_MACHO_REWRITE_COMPAT_DIR
# overrides where they are looked for.
#
# POSIX sh (10.9's /bin/sh is bash 3.2). set -u, not set -e: every failure is
# checked where it happens.
EOF
```

  These passages go to the commit message rather than to a new home:
  - "WHY THE WRAPPERS ARE NOT SIX COPIES";
  - the "what lives WHERE" table, which also falsely says each wrapper header carries a "DELIBERATE DIVERGENCES" list;
  - the flat-layout rationale, which `compat/README.md`'s "What a packager has to change" already states;
  - "the tool answered to three earlier names";
  - the `macho9 minos` measurement;
  - "This used to drop a Wrote line";
  - `mw_retranslate`'s claim that it "cannot fail on its own", which is a can't-happen claim that no test backs.

- [ ] **Step 6: Add the "Thin only" section to `compat/README.md`.** Insert directly above `## Why the six wrapper names are unchanged`:

```markdown
## Thin only

`patch_macho`, `add_version_min`, `retag_swift_classes` and `rename_segment`
read one thin 64-bit image and refused a fat container. A script rewrites
every slice. So each wrapper asks `drydock-macho-rewrite info --thin` first
(`mw_thin_only`, or `rename_segment.sh`'s own call). Measured against the
pre-migration binaries on a two-slice x86_64 fat file:

| invocation | the C tool | a script, with no gate | held by (`tests/wrapper_test.sh`) |
|---|---|---|---|
| `add_version_min FAT` | exit 1, nothing written | exit 0, every slice rewritten | "add_version_min: a fat container is refused, untouched, as mv_add_version_min's own mi_open did" |
| `patch_macho FAT OUT` | exit 1, no `OUT` | exit 0, `OUT` written | "patch_macho: a fat container is refused and no output is created" |
| `retag_swift_classes FAT` | exit 0, file untouched | exit 0 and `total: 0`, with the file retagged | "retag_swift_classes: a fat container is the benign skip it always was, and the file is untouched" |
| `rename_segment FAT OLD NEW` | exit 1 | a rename in every slice | "rename_segment: a fat container is refused, as it always was" |

Only `EX_REFUSED` (1) from `info --thin` is intercepted. `EX_FAIL` (2) falls
through ("mw_thin_only: EX_FAIL (2) still falls through").

```

- [ ] **Step 7: Verify.** Check that no code changed, measure, build, confirm staging, and run.

```sh
git diff -U0 -- compat/drydock-macho-rewrite-compat.sh | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'   # expect nothing
/private/tmp/drydock-item6/density.sh compat/drydock-macho-rewrite-compat.sh   # record it
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
cmp compat/drydock-macho-rewrite-compat.sh /private/tmp/build/schmonz/drydock-native/drydock-macho-rewrite-compat.sh && echo staged
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

  Expected: comment ≤ 100 and first_code ≤ 20 (simulated: `total=268 comment=86 code=164 first_code=16`); `staged`; ctest green.

- [ ] **Step 8: Commit**

```sh
git add tests/wrapper_test.sh compat/drydock-macho-rewrite-compat.sh compat/README.md
git diff --cached --stat
git commit -F - <<'EOF'
refactor(compat): the shared wrapper machinery says what, not how it got here

drydock-macho-rewrite-compat.sh's comments shrink to each function's
contract. Moved out: the fat-container measurement (what add_version_min,
patch_macho, retag_swift_classes and rename_segment would do without the
thin-only gate) is now compat/README.md's "Thin only" table, with the
assertion holding each row. Dropped as history: why the wrappers are
not six copies, the tool's three earlier names, the `macho9 minos`
measurement of a directory, and the "Wrote <temp>" line this once
filtered, whose lesson (caller text reaches awk through ENVIRON, never
-v) stays as one sentence where awk is used. Its "what lives where" list
also said each wrapper header carries a DELIBERATE DIVERGENCES list,
which is no longer true of any of them.

mw_retranslate claimed it "cannot fail on its own", which nothing
tests, so the claim is gone and the check stays.

New: a wrapper symlinked away from its support files exits 1 and says to
set DRYDOCK_MACHO_REWRITE_COMPAT_DIR, for all eight. That is what the
comment above each wrapper's bootstrap check described, so those
comments can go as each wrapper is swept.

Before: 448 lines, 266 comment, first code at 68.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h
```

  Add the after-measurement from Step 7 to the commit message's "Before:" line before committing, as "Before: …; after: …".

---

### Task 5: `compat/patch_macho.sh`

**Files:**
- Test: `tests/wrapper_test.sh`. The insertion goes directly below line `:792`. That line is the bare `rm -rf "$T/adir"` that follows `|| bad "patch_macho directory OUT" "exit $rc, stderr: $(cat "$T/err")"`; the Edit anchor is those two lines together, because `rm -rf "$T/adir"` alone occurs twice.
- Modify: `compat/patch_macho.sh`
- Modify: `compat/README.md`. There is a new section directly above `## \`rename_segment\`: exit codes`, and one sentence in the "drop-in" bullet.
- Modify, only if `git diff --quiet -- tests/cli_test.sh` succeeds: `tests/cli_test.sh:873-874`.

**Interfaces:**
- Consumes: Task 4's symlink assertion, and README "Thin only".
- Produces: the README section `## \`patch_macho\`: the differences, and what holds each one`, and the assertions "patch_macho: with IN and OUT both bad, OUT's refusal is the one named" and "patch_macho: a dangling symlink as OUT is refused (1), and its target is not created".

- [ ] **Step 1: Measure**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git diff --quiet d1cab99 -- compat/patch_macho.sh || echo CHANGED-STOP
/private/tmp/drydock-item6/density.sh compat/patch_macho.sh   # expect total=224 comment=169 code=45 first_code=137
```

- [ ] **Step 2: Write the two tests** the header's prose asserted and nothing held. Insert below the two-line anchor named above:

```sh
# With IN and OUT both bad, OUT is named: the OUT checks decide where the
# rewrite writes, so they run first. The C tool converted first and opened
# OUT last. Exit 1 either way.
printf 'not a mach-o at all\n' > "$T/nm"
rm -rf "$T/adir"; mkdir "$T/adir"
run patch_macho nm adir
[ "$rc" -eq 1 ] && grep -qxF 'create output: Is a directory' "$T/err" \
    && ! grep -q 'not a readable 64-bit Mach-O' "$T/err" \
    && ok "patch_macho: with IN and OUT both bad, OUT's refusal is the one named" \
    || bad "patch_macho both bad" "exit $rc, stderr: $(cat "$T/err")"
rm -rf "$T/adir" "$T/nm"

# A dangling symlink at OUT is refused; the C tool created the link's target.
fresh
rm -f "$T/pmdangle" "$T/pmnowhere"; ln -s pmnowhere "$T/pmdangle"
run patch_macho f pmdangle
[ "$rc" -eq 1 ] && [ -L "$T/pmdangle" ] && [ ! -e "$T/pmnowhere" ] \
    && ok "patch_macho: a dangling symlink as OUT is refused (1), and its target is not created" \
    || bad "patch_macho dangling OUT" "exit $rc, stderr: $(cat "$T/err")"
rm -f "$T/pmdangle" "$T/pmnowhere"
```

- [ ] **Step 3: Run them. They pass, because they characterize.** Build, then run `ctest -R wrapper_test --output-on-failure`. Expected: PASS, with both new labels printed.

- [ ] **Step 4: Mutate each**
  - In `compat/patch_macho.sh`, move the two-line `if ! mw_thin_only "$1"; then … fi` block above the `if [ -d "$mw_out" ]` block. Rebuild; `cmp compat/patch_macho.sh /private/tmp/build/schmonz/drydock-native/patch_macho` shows a difference is staged. Run `wrapper_test`. Expected: FAIL "patch_macho both bad". Then `git checkout -- compat/patch_macho.sh`.
  - In `compat/drydock-macho-rewrite-compat.sh`, change `[ ! -e "$1" ] && [ ! -L "$1" ]` to `[ ! -e "$1" ]`. Rebuild and run. Expected: FAIL "patch_macho dangling OUT". Then `git checkout -- compat/drydock-macho-rewrite-compat.sh`. Rebuild, and ctest is green.

- [ ] **Step 5: Comment pass** (bottom to top; the prelude comment's claim is held by Task 4's test)

```sh
. /private/tmp/drydock-item6/rr.sh
F=compat/patch_macho.sh

rr $F 205 208 '# A fresh OUT gets what open(..., 0755) produced: 0755 narrowed by the' '# prepended to make the arithmetic octal either way.' <<'EOF'
    # A fresh OUT: 0755 & ~umask. The leading 0 makes umask's digits octal.
EOF

rr $F 200 202 "# An existing OUT keeps its own mode: open() does not change one on a file" '# about its target -- the file the install lands on.' <<'EOF'
    # An existing OUT keeps its mode; MW_TARGET is a symlinked OUT's target.
EOF

rr $F 196 198 '# THE MODE THE C TOOL WOULD HAVE LEFT, applied to the temp before it is' '# open(argv[2], O_WRONLY|O_CREAT|O_TRUNC, 0755) gave.' <<'EOF'
# The mode patch_macho's open(OUT, O_CREAT, 0755) would have left.
EOF

rr $F 192 193 '# A refusal leaves OUT untouched -- md_declassify runs to completion before the' '# C tool ever opened OUT, so this matches, and it is why the temp exists.' </dev/null

rr $F 174 181 "# \`new-ok\`: this tool's OUT is the file it is asked to CREATE, so an OUT that" '# covers everything else that goes wrong here.' <<'EOF'
# new-ok: OUT need not exist yet. Thin only, and asked of IN, not OUT.
EOF

rr $F 156 164 '# AN OUT THAT EXISTS BUT IS NOT A REGULAR FILE, refused here because neither of' '# wrapper can install over with a rename either, and says so in its own words.' <<'EOF'
# An existing OUT that is not a regular file is refused here: given a
# directory, mv would move the temp into it and exit 0.
EOF

rr $F 139 143 '# Checked here, before sourcing, so a missing support file gets this message' '# one holding drydock-macho-rewrite -- which is why DRYDOCK_MACHO_REWRITE_COMPAT_DIR exists.' </dev/null

rr $F 2 135 '# patch_macho -- a /bin/sh wrapper around `drydock-macho-rewrite IN OUT` with one' '# and which therefore SKIPs on 10.9 -- can run it.' <<'EOF'
# patch_macho -- a /bin/sh wrapper around `drydock-macho-rewrite IN OUT` with one
# `fixups set classic` statement on its stdin.
#
#   patch_macho input output
#
# compat/translate.sh holds the grammar; compat/README.md's "patch_macho"
# section holds every difference from the C tool and the test for each.
EOF
```

- [ ] **Step 6: Add the README section.** Insert directly above `## \`rename_segment\`: exit codes`:

```markdown
## `patch_macho`: the differences, and what holds each one

`patch_macho IN OUT` becomes `fixups set classic` into a temp beside `OUT`,
installed over `OUT`. The conversion is `md_declassify` on both sides, so what
differs is everything around it. "Held by" names assertions in
`tests/wrapper_test.sh` unless it says otherwise.

| the difference | held by |
|---|---|
| **every nonzero exit is 1**, the only failure code `patch_macho` had: `EX_FAIL` (2) is folded, and `EX_REFUSED` already is 1 | "patch_macho: an absent IN maps drydock-macho-rewrite's EX_FAIL back to a flat 1", "patch_macho: a non-Mach-O input exits 1, not 2" |
| **thin only**: a fat `IN` is refused and no `OUT` is created (see "Thin only", above) | "patch_macho: a fat container is refused and no output is created" |
| **`OUT`'s mode is the C tool's**: `0755 & ~umask` for a fresh `OUT`, and its own mode for an existing one. It is not the input's mode, which is what `drydock-macho-rewrite` gives | "patch_macho: a fresh OUT gets 0755 masked by the umask (0700 under 077)", "patch_macho: and 0755 under umask 022, not the input's own mode", "patch_macho: an existing OUT keeps its mode"; on the converting path, "patch_macho: a converting run's fresh OUT is 0755 & ~umask too", "patch_macho: a converting run's existing OUT keeps its mode, with a new inode" |
| **`OUT` is installed by rename**, so it gets a new inode when its bytes change, where the C tool's `open(O_TRUNC)` kept it. An unchanged pass-through installs nothing, so `patch_macho IN IN` on a converted input keeps its inode | "patch_macho: ... and is installed atomically, so its inode is new", "patch_macho: ... and an unchanged pass-through installs nothing, so the inode stands", "patch_macho: IN == OUT converts IN in place, to drydock-macho-rewrite's own bytes", "patch_macho: ... installed by rename, so the inode is new when the bytes change" |
| **an `OUT` with other hard links is refused** (1), where the C tool wrote through every link | "patch_macho: a hard-linked OUT is refused (1), both names untouched", "patch_macho: a hard-linked OUT is refused (1) even when IN converts" |
| **an unwritable existing `OUT` fails**, as `open(O_WRONLY)` did | "patch_macho: an unwritable existing OUT fails, as open(O_WRONLY) did", "patch_macho: an unwritable OUT is refused (1), untouched, even when IN converts" |
| **an `OUT` that is a directory** is refused in the C tool's own words, `create output: Is a directory`. `mv` alone would move the temp into it and exit 0 | "patch_macho: an OUT that is a directory is refused (1), as open() did" |
| **a dangling symlink at `OUT` is refused** (1), where the C tool created the link's target | "patch_macho: a dangling symlink as OUT is refused (1), and its target is not created" |
| **with `IN` and `OUT` both bad, `OUT` is named**. The `OUT` checks run before the rewrite because they decide where it writes; the C tool converted first and opened `OUT` last. Exit 1 either way | "patch_macho: with IN and OUT both bad, OUT's refusal is the one named" |
| **stdout**: `md_declassify`'s own lines pass through, and `Wrote OUT (N bytes)` is printed only on the converting path, as `patch_macho` printed it. A pass-through, recognised by `md_declassify`'s `Already patched` line, names no file | "patch_macho: the pass-through prints no 'Wrote ...' line", "patch_macho: ... and its last stdout line names OUT and OUT's size", "patch_macho: ... and exactly one 'Wrote ' line, so drydock-macho-rewrite's cannot leak", "patch_macho: ... and md_declassify's own lines still come through"; `tests/known-callers.sh`, "install.sh: patch_macho passes an already-converted binary through unchanged" |

```

  Then, in the "drop-in" bullet that ends `` `compat/patch_macho.sh`'s header has all of it. ``, replace that sentence with `` The "`patch_macho`" section below names the test for each. ``

- [ ] **Step 7: Repoint `tests/cli_test.sh`, only if it is clean.** If `git diff --quiet -- tests/cli_test.sh` succeeds, replace

```
    # where the numbers diverge; compat/patch_macho.sh's own header covers
    # both.
```

  with

```
    # where the numbers diverge; compat/README.md's "patch_macho" section
    # covers both.
```

  Otherwise leave it, and add "`tests/cli_test.sh:873` still cites `compat/patch_macho.sh`'s header" to Task 11's deferred list.

- [ ] **Step 8: Verify**

```sh
git diff -U0 -- compat/patch_macho.sh | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'   # expect nothing
git grep -n "patch_macho.sh's" -- . ':!docs/superpowers'   # expect nothing (or only cli_test.sh, if Step 7 deferred)
git grep -n 'patch_macho' -- compat/README.md | head -1     # positive control: a hit
/private/tmp/drydock-item6/density.sh compat/patch_macho.sh   # expect total=69 comment=14 code=45 first_code=10
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
cmp compat/patch_macho.sh /private/tmp/build/schmonz/drydock-native/patch_macho && echo staged
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

- [ ] **Step 9: Commit** (add `tests/cli_test.sh` only if Step 7 edited it)

```sh
git add compat/patch_macho.sh compat/README.md tests/wrapper_test.sh
git diff --cached --stat
git commit -F - <<'EOF'
refactor(compat): patch_macho's differences live in compat/README.md

patch_macho.sh's 134-line header is now its usage line and a pointer.
Each difference from the C tool is a row in compat/README.md's new
"patch_macho" table, naming the assertion that holds it.

Two claims the header made had no test, and now do: with IN and OUT
both bad, OUT's refusal is the one named (the OUT checks must run
before the rewrite because they decide where it writes); and a dangling
symlink at OUT is refused, where the C tool created the link's target.
Each was mutated to fail.

Dropped as history: what compat/patch_macho.c was, which verb's
divergence list this used to be, the three mutations of the converting
path that went unnoticed before tests/mkchained.c existed, and why the
"Already patched" grep did not move when the verbs went. The header
also said mw_run_to_tmp drops drydock-macho-rewrite's "Wrote <temp>"
line; mw_run_to_tmp filters nothing.

Before: 224 lines, 169 comment, 45 code, first code at 137.
After: 69 / 14 / 45, first code at 10.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h
```

  If Step 8's density line differs from the expected one, use the measured numbers in the "After:" line.

---

### Task 6: `compat/rename_segment.sh`

**Files:**
- Modify: `compat/rename_segment.sh`
- Modify: `compat/README.md`: the drop-in bullet about `LC_LAZY_LOAD_DYLIB`, the writability bullet, and the `fix_macho` "two more differences" table's `LC_LAZY_LOAD_DYLIB` row.

**Interfaces:** Consumes Task 4's symlink assertion. The existing README section "## `rename_segment`: exit codes" is the pointer's target, and is unchanged.

- [ ] **Step 1: Measure**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git diff --quiet d1cab99 -- compat/rename_segment.sh || echo CHANGED-STOP
/private/tmp/drydock-item6/density.sh compat/rename_segment.sh   # expect total=224 comment=167 code=44 first_code=159
```

  Every claim in the header already has a test: the count's two fixed bugs ("an OLD longer than 16 bytes still matches on its first 16", "a segname containing whitespace still matches"), thin only, `LC_LAZY_LOAD_DYLIB`, the `mg_plausible` pair, and the exit codes (README "rename_segment: exit codes"). So this task writes no test. The measured `libxcselect` transcript moves into the README.

- [ ] **Step 2: Comment pass**

```sh
. /private/tmp/drydock-item6/rr.sh
F=compat/rename_segment.sh

rr $F 161 165 '# Checked here, before sourcing, so a missing support file gets this message' '# one holding drydock-macho-rewrite -- which is why DRYDOCK_MACHO_REWRITE_COMPAT_DIR exists.' </dev/null

rr $F 2 157 '# rename_segment -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one' '# writable binary in a read-only directory now fails with FILE untouched.' <<'EOF'
# rename_segment -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one
# `segment rename OLD NEW` statement on its stdin.
#
#   rename_segment binary OLDNAME NEWNAME
#
# compat/translate.sh holds the grammar; compat/README.md's "rename_segment:
# exit codes" maps each drydock-macho-rewrite exit to this tool's 0, 1 or 2.
EOF
```

- [ ] **Step 3: Move the measurement and repoint the README.** In `compat/README.md`, replace

```
    renumber. `compat/rename_segment.sh`'s header has the measurement. It is
    one file out of 300
```

  with

```
    renumber. Measured on `/usr/lib/libxcselect.dylib`: the C tool renamed it
    (exit 0), and a `segment rename` statement, a `load-command delete`
    statement and the pre-wrapper `change_dylib` all refuse it (exit 1) with
    the same message, so the refusal is the shared rewriter's, not the
    rename's. It is one file out of 300
```

  Replace

```
    caller (absent, and mode-denied); `compat/rename_segment.sh`'s header has
    the detail.
```

  with

```
    caller (absent, and mode-denied).
```

  In the `fix_macho` "two more differences" table, replace `` `compat/rename_segment.sh`'s header has the measurement (on `/usr/lib/libxcselect.dylib`) and the note that the smallest fix is a change to `drydock-macho-rewrite`, not to a wrapper. `` with `` The "drop-in" section above has the measurement (on `/usr/lib/libxcselect.dylib`); the smallest fix is to skip building the ordinal map when no operation can renumber, a change to `drydock-macho-rewrite`, not to a wrapper. ``

- [ ] **Step 4: Verify**

```sh
git diff -U0 -- compat/rename_segment.sh | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'   # expect nothing
git grep -n "rename_segment.sh's header" -- . ':!docs/superpowers'   # expect nothing
git grep -n 'rename_segment.sh' -- compat/README.md | head -1          # positive control: a hit
/private/tmp/drydock-item6/density.sh compat/rename_segment.sh   # expect total=70 comment=13 code=44 first_code=10
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
cmp compat/rename_segment.sh /private/tmp/build/schmonz/drydock-native/rename_segment && echo staged
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

- [ ] **Step 5: Commit**

```sh
git add compat/rename_segment.sh compat/README.md
git diff --cached --stat
git commit -F - <<'EOF'
refactor(compat): rename_segment's header is its usage line

Every claim the 156-line header made is held by a test in
tests/wrapper_test.sh or mapped in compat/README.md's "rename_segment:
exit codes" table, so the header goes. The one measurement it carried
(on /usr/lib/libxcselect.dylib: the C tool renamed it, and a segment
rename, a load-command delete and the pre-wrapper change_dylib all
refuse it with the same message) moves into compat/README.md, which
pointed at the header for it.

Dropped as history: what compat/rename_segment.c was; the earlier
version that counted matches out of `info` text, which missed an OLD
longer than 16 bytes and a name containing whitespace (both now
tested); the verb-era list of five divergences; and mg_plausible,
which stopped being a divergence when src/rewrite.c began running it
only on runs that disturb what it checks.

Before: 224 lines, 167 comment, 44 code, first code at 159.
After: 70 / 13 / 44, first code at 10.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h
```

---

### Task 7: `compat/add_version_min.sh`

**Files:**
- Test: `tests/wrapper_test.sh`. `hl_case`'s comment is at `:419-424`, and one call is added after `hl_case rename_segment __DATA __DATA_HL` (`:444`). A new read-only-directory case goes directly below the `ok "add_version_min: ... and stderr is where the announcement went"` assertion's `|| bad` line (`:997`).
- Modify: `compat/add_version_min.sh`
- Modify: `compat/README.md`: a new section directly above `## \`rename_segment\`: exit codes` (so after `patch_macho`'s), the drop-in bullet's "fourth case" sentence, and the `change_dylib` in-place table's read-only-directory row.

**Interfaces:**
- Consumes: Task 4's symlink assertion and README "Thin only".
- Produces: the assertions "add_version_min: a hard-linked FILE is refused (1), both names untouched" (from `hl_case`) and "add_version_min: a writable file in a read-only directory exits 2, untouched". Task 8 edits the README phrases this task writes. They are marked **(Task 8 edits this)** below.

- [ ] **Step 1: Measure**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git diff --quiet d1cab99 -- compat/add_version_min.sh || echo CHANGED-STOP
/private/tmp/drydock-item6/density.sh compat/add_version_min.sh   # expect total=106 comment=82 code=21 first_code=77
```

- [ ] **Step 2: Write the tests.** Nothing held the header's read-only-directory transcript. `hl_case`'s comment says "add_version_min's own case is asserted above", and no such assertion exists (`grep -n 'add_version_min: a hard-linked' tests/wrapper_test.sh` returns nothing; control: `grep -n 'hl_case rename_segment' tests/wrapper_test.sh` returns a hit).

  Replace `hl_case`'s comment

```
# A HARD-LINKED FILE IS REFUSED (1) BY EVERY WRAPPER ON THE INSTALL PATH, which
# for these three is new: their C tools wrote through their own descriptor, so
# every name for the inode saw the change, while installing by mv would leave
# the siblings on the old content. add_version_min's own case is asserted
# above; these are the three whose verbs converted together. Each must refuse
# before running anything, leave BOTH names byte-identical, and leave no temp.
```

  with

```
# A HARD-LINKED FILE IS REFUSED (1) BY EVERY WRAPPER ON THE INSTALL PATH: the
# C tools wrote through their own descriptor, so every name for the inode saw
# the change, while installing by mv would leave the siblings on the old
# content. Each must refuse before running anything, leave BOTH names
# byte-identical, and leave no temp.
```

  and after `hl_case rename_segment __DATA __DATA_HL` add the line `hl_case add_version_min`.

  Below the `|| bad "add_version_min stderr" ...` line, insert:

```sh

# A writable FILE in a read-only directory: the install needs the directory,
# which the C tool never did. drydock-macho-rewrite's own write of the temp
# fails, and its 2 is forwarded.
rm -rf "$T/avm_ro"; mkdir "$T/avm_ro"
cp "$FIXTURE" "$T/avm_ro/b"; strip_vm "$T/avm_ro/b"
avm_ro_before=$(sha "$T/avm_ro/b")
chmod 555 "$T/avm_ro"
run add_version_min avm_ro/b
chmod 755 "$T/avm_ro"
[ "$rc" -eq 2 ] && grep -q 'mkstemp: Permission denied' "$T/err" \
    && [ "$(sha "$T/avm_ro/b")" = "$avm_ro_before" ] \
    && ok "add_version_min: a writable file in a read-only directory exits 2, untouched" \
    || bad "add_version_min read-only dir" "exit $rc: $(tail -2 "$T/err")"
rm -rf "$T/avm_ro"
```

- [ ] **Step 3: Run them. They pass, because they characterize.** Build and run `wrapper_test`. Expected: PASS, with both new labels printed.

- [ ] **Step 4: Mutate each**
  - In `compat/drydock-macho-rewrite-compat.sh`, change `if [ "$mw_links" -gt 1 ]; then` to `if [ "$mw_links" -gt 99 ]; then`. Rebuild, confirm with `cmp` that it is staged, and run. Expected: FAIL "add_version_min hard link", along with the other `hl_case` rows. Revert with `git checkout -- compat/drydock-macho-rewrite-compat.sh`.
  - In `compat/add_version_min.sh`, change `[ "$mw_rc" -eq 0 ] || exit "$mw_rc"` to `[ "$mw_rc" -eq 0 ] || exit 1`. Rebuild and run. Expected: FAIL "add_version_min read-only dir", and also "mw_thin_only EX_FAIL". Revert with `git checkout -- compat/add_version_min.sh`, rebuild, and ctest is green.

- [ ] **Step 5: Comment pass**

```sh
. /private/tmp/drydock-item6/rr.sh
F=compat/add_version_min.sh

rr $F 94 96 "# THIN ONLY, like mv_add_version_min's own mi_open. drydock-macho-rewrite-compat.sh's" '# named the FILE and not the tool.' <<'EOF'
# Thin only; the message is mv_add_version_min's, which named FILE, not the tool.
EOF

rr $F 79 83 '# Checked here, before sourcing, so a missing support file gets this message' '# one holding drydock-macho-rewrite -- which is why DRYDOCK_MACHO_REWRITE_COMPAT_DIR exists.' </dev/null

rr $F 2 75 '# add_version_min -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one' '# and the teaching message this wrapper prints ahead of both.' <<'EOF'
# add_version_min -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one
# `version-min set 10.9` statement on its stdin.
#
#   add_version_min binary
#
# drydock-macho-rewrite's exit code is forwarded unchanged; the wrapper's own
# refusals exit 1. compat/README.md's "add_version_min" section holds every
# difference from the C tool and the test for each.
EOF
```

  The header claimed "the two exit codes the COMMAND has of its own are unreachable from here". That is a can't-happen claim with no test, and it is deleted, not moved.

- [ ] **Step 6: The README.** Insert directly above `## \`rename_segment\`: exit codes`:

```markdown
## `add_version_min`: the differences, and what holds each one

`add_version_min FILE` becomes `version-min set 10.9` into a temp beside
`FILE`, installed over it. The statement calls `mv_add_version_min`, the
function the C tool called, so only what surrounds it differs.

| the difference | held by (`tests/wrapper_test.sh` unless named) |
|---|---|
| **`drydock-macho-rewrite`'s exit code is forwarded unchanged**: a considered refusal exits 1, as the C tool's did, and an operational failure exits 2, where the C tool exited 1 | "add_version_min: a fat container is refused, untouched, as mv_add_version_min's own mi_open did" (1); "mw_thin_only: EX_FAIL (2) still falls through" (a directory as `FILE`, 2) |
| **a short header pad is grown**, where the C tool refused | `tests/cli_test.sh`, "add_version_min: a short pad is grown, announced, where the original refused (0)" |
| **the append is announced on stderr** as `appended LC_VERSION_MIN_MACOSX 10.9`, not on stdout. The C tool's "Added LC_VERSION_MIN_MACOSX ..." line belonged to the `minos` verb. The repo owner ruled on 2026-09-13 that wrapper text may change where bytes and exit codes may not | "add_version_min: stdout is empty -- the append is announced on stderr now", "add_version_min: ... and stderr is where the announcement went" |
| **a hard-linked `FILE` is refused** (1), where the C tool wrote through every link | "add_version_min: a hard-linked FILE is refused (1), both names untouched" |
| **a writable `FILE` in a read-only directory fails** with `mkstemp: Permission denied`, exit 2, `FILE` untouched: installing needs the directory writable, where the C tool needed only `FILE` | "add_version_min: a writable file in a read-only directory exits 2, untouched" |
| **thin only** (see "Thin only", above) | "add_version_min: a fat container is refused, untouched, as mv_add_version_min's own mi_open did" |

```

  In the drop-in bullet, replace

```
    tools needed only `FILE` itself to be; `compat/add_version_min.sh` and
    `compat/retag_swift_classes.sh`'s own headers both name it, and for
```

  with (**Task 8 edits this**)

```
    tools needed only `FILE` itself to be; `tests/wrapper_test.sh` holds it
    for `add_version_min`, `compat/retag_swift_classes.sh`'s header names it, and for
```

  In the `change_dylib` in-place table, replace `` `compat/add_version_min.sh` and `compat/retag_swift_classes.sh`'s headers record the same shape `` with (**Task 8 edits this**) `` `tests/wrapper_test.sh` asserts it for `add_version_min`, and `compat/retag_swift_classes.sh`'s header records the same shape ``

- [ ] **Step 7: Verify**

```sh
git diff -U0 -- compat/add_version_min.sh | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'   # expect nothing
git grep -n "add_version_min.sh's\|add_version_min.sh\` and" -- . ':!docs/superpowers'   # expect nothing
git grep -n 'add_version_min.sh' -- compat/README.md | head -1   # positive control: a hit
/private/tmp/drydock-item6/density.sh compat/add_version_min.sh   # expect total=33 comment=9 code=21 first_code=11
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
cmp compat/add_version_min.sh /private/tmp/build/schmonz/drydock-native/add_version_min && echo staged
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

- [ ] **Step 8: Commit**

```sh
git add compat/add_version_min.sh compat/README.md tests/wrapper_test.sh
git diff --cached --stat
git commit -F - <<'EOF'
refactor(compat): add_version_min's differences live in compat/README.md

add_version_min.sh's 74-line header becomes its usage line and a
pointer to compat/README.md's new "add_version_min" table, which names
the assertion holding each difference.

Two claims had no test, and now do: a writable FILE in a read-only
directory exits 2 with mkstemp's error and FILE untouched, the
measurement the header recorded; and a hard-linked FILE is refused.
tests/wrapper_test.sh's hl_case comment said add_version_min's
hard-link case was "asserted above", and no such assertion existed.
Each was mutated to fail.

Dropped as history: what compat/add_version_min.c was, and that the
"Added LC_VERSION_MIN_MACOSX" line belonged to the minos verb. Dropped
as an untested can't-happen claim: that the command's own two exit
codes are unreachable from this wrapper.

Before: 106 lines, 82 comment, 21 code, first code at 77.
After: 33 / 9 / 21, first code at 11.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h
```

---

### Task 8: `compat/retag_swift_classes.sh`

**Files:**
- Test: `tests/wrapper_test.sh`. The insertion goes directly below the `|| bad "retag_swift_classes unwritable mix" "rsc_u changed"` line (`:1526`).
- Modify: `compat/retag_swift_classes.sh`
- Modify: `compat/README.md`: a new section directly above `## \`insert_dylib\`: not one of the six`, the "1-vs-2 mapping" parenthesis, and the two phrases Task 7 wrote.

**Interfaces:**
- Consumes: Task 4's symlink assertion, README "Thin only", and Task 7's README phrases.
- Produces: the assertion "retag_swift_classes: a writable file in a read-only directory is an error, untouched, and the loop goes on".

- [ ] **Step 1: Measure**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git diff --quiet d1cab99 -- compat/retag_swift_classes.sh || echo CHANGED-STOP
/private/tmp/drydock-item6/density.sh compat/retag_swift_classes.sh   # expect total=196 comment=139 code=52 first_code=111
```

- [ ] **Step 2: Write the test.** It holds the header's measured `chmod 555 ro` transcript. Insert below `|| bad "retag_swift_classes unwritable mix" "rsc_u changed"`:

```sh

# A writable argument in a read-only directory: mw_prepare's checks pass,
# drydock-macho-rewrite cannot write the temp beside it (EX_FAIL), and the
# loop counts it as an error and goes on.
rm -rf "$T/rsc_ro"; mkdir "$T/rsc_ro"
mkswift_fixture "$T/rsc_g5"
mkswift_fixture "$T/rsc_ro/b"
rsc_ro_before=$(sha "$T/rsc_ro/b")
chmod 555 "$T/rsc_ro"
run retag_swift_classes rsc_g5 rsc_ro/b
chmod 755 "$T/rsc_ro"
[ "$rc" -eq 1 ] && grep -qxF 'rsc_g5: retagged 2 class record(s)' "$T/out" \
    && grep -qxF 'total: 2 class record(s) retagged' "$T/out" \
    && ! grep -q 'rsc_ro/b' "$T/out" \
    && grep -q 'mkstemp: Permission denied' "$T/err" \
    && [ "$(sha "$T/rsc_ro/b")" = "$rsc_ro_before" ] \
    && ok "retag_swift_classes: a writable file in a read-only directory is an error, untouched, and the loop goes on" \
    || bad "retag_swift_classes read-only dir" "exit $rc, stdout: $(cat "$T/out"), stderr: $(tail -2 "$T/err")"
rm -rf "$T/rsc_ro"
```

- [ ] **Step 3: Run it. It passes, because it characterizes.** Build and run `wrapper_test`. Expected: PASS.

- [ ] **Step 4: Mutate.** In `compat/retag_swift_classes.sh`'s `*)` arm, delete `mw_had_error=1`. Rebuild, confirm with `cmp`, and run. Expected: FAIL "retag_swift_classes read-only dir" (exit 0, not 1). Revert with `git checkout -- compat/retag_swift_classes.sh`, rebuild, and ctest is green.

- [ ] **Step 5: Comment pass**

```sh
. /private/tmp/drydock-item6/rr.sh
F=compat/retag_swift_classes.sh

rr $F 155 168 '# Read BEFORE the forward, because the report is on stderr now: the' '# it is what would break next if that gate ever moved.' <<'EOF'
        # The statement reports on stderr, once per slice: sum the lines.
EOF

rr $F 142 145 "# mw_retranslate's signature is TOOL ARG..., so retranslating THIS ONE" '# original argv.' </dev/null

rr $F 132 137 "# THIN ONLY, like mswift_retag_file's own mi_open -- and a refusal here is" '# rather than retagging every slice and still reporting a total of 0.' <<'EOF'
    # Thin only: a fat container is the same silent skip as a non-Mach-O.
EOF

rr $F 113 117 '# Checked here, before sourcing, so a missing support file gets this message' '# one holding drydock-macho-rewrite -- which is why DRYDOCK_MACHO_REWRITE_COMPAT_DIR exists.' </dev/null

rr $F 2 109 '# retag_swift_classes -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT` with one' '# load-bearing, not decoration.' <<'EOF'
# retag_swift_classes -- a /bin/sh wrapper around `drydock-macho-rewrite FILE OUT`
# with one `swift-abi set legacy` statement on its stdin, once per argument.
#
#   retag_swift_classes binary [binary ...]
#
# Each file's command runs here rather than through mw_run, because each file
# needs its own exit code and stdout. compat/README.md's "retag_swift_classes"
# section maps both, with the test for each.
EOF
```

  The sum comment claimed "mw_thin_only above means a fat argument no longer gets this far … it is what would break next if that gate ever moved". That is a can't-happen claim about the fat path, and it is deleted. The summing stays.

- [ ] **Step 6: The README.** Insert directly above `## \`insert_dylib\`: not one of the six, and the differences it has from the fork`:

```markdown
## `retag_swift_classes`: exit codes and stdout

One `swift-abi set legacy` command per argument, in argv order, run by the
wrapper itself so that each file keeps its own exit code and stdout. The exit
is `had_error ? 1 : 0`, as the C tool's was, and the last line is always
`total: N class record(s) retagged`. `tests/leaf-tool-crashes.sh` greps for
`^total: 0 class record(s) retagged$` on a malformed fixture, so that line is
load-bearing. "Held by" names assertions in `tests/wrapper_test.sh`.

| per argument | what the wrapper does | held by |
|---|---|---|
| `drydock-macho-rewrite` exits 0 | sums the statement's `retagged N class record(s)` lines (stderr, one per slice), installs, and prints `FILE: retagged N class record(s)` when N > 0 | "retag_swift_classes: a nonzero-count binary prints its own line and the right total", "retag_swift_classes: ... and its bytes really changed (this was not a discarded no-op)", "retag_swift_classes: a 0-count binary among nonzero ones prints no line of its own, and the total excludes it", "retag_swift_classes: ... and its INODE is unchanged (discarded, not reinstalled)" |
| exits 1 (`EX_REFUSED`: not a Mach-O), or is a fat container | skips it silently and goes on, as the C tool did | "retag_swift_classes: a non-Mach-O argument is skipped, and the loop continues", "retag_swift_classes: the skip is silent, as it always was", "retag_swift_classes: a fat container is the benign skip it always was, and the file is untouched" |
| exits 2 (`EX_FAIL`), including a writable file in a read-only directory (`mkstemp: Permission denied`) | shows the error, sets `had_error`, goes on | "retag_swift_classes: a writable file in a read-only directory is an error, untouched, and the loop goes on" |
| the wrapper's own refusal: absent, unwritable, or hard-linked | says so, sets `had_error`, goes on. An absent or unwritable argument is reported as `open: ...` where the C tool said `<path>: ...`, so only the exit code still matches | "retag_swift_classes: an absent path exits 1 and still prints the total", "retag_swift_classes: good/hardlinked/good -- exit 1, the two good lines, and the reduced total", "retag_swift_classes: ... and says why the hard-linked one was skipped", "retag_swift_classes: good/unwritable/good -- exit 1, the two good lines, and the reduced total", "retag_swift_classes: no temp file left behind after a mid-loop refusal" |

```

  Replace

```
    which has its own real 1-vs-2 mapping (`compat/retag_swift_classes.sh`'s
    header has it) and is likewise unaffected by this. (EVERY wrapper whose
```

  with

```
    which has its own real 1-vs-2 mapping (its section below has it) and is
    likewise unaffected by this. (EVERY wrapper whose
```

  Replace Task 7's

```
    tools needed only `FILE` itself to be; `tests/wrapper_test.sh` holds it
    for `add_version_min`, `compat/retag_swift_classes.sh`'s header names it, and for
```

  with

```
    tools needed only `FILE` itself to be; `tests/wrapper_test.sh` holds it
    for both, and for
```

  Replace Task 7's `` `tests/wrapper_test.sh` asserts it for `add_version_min`, and `compat/retag_swift_classes.sh`'s header records the same shape `` with `` `tests/wrapper_test.sh` asserts the same shape for `add_version_min` and `retag_swift_classes` ``

- [ ] **Step 7: Verify**

```sh
git diff -U0 -- compat/retag_swift_classes.sh | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'   # expect nothing
git grep -n "retag_swift_classes.sh's" -- . ':!docs/superpowers'   # expect nothing
git grep -n 'retag_swift_classes.sh' -- compat/README.md | head -1   # positive control: a hit
/private/tmp/drydock-item6/density.sh compat/retag_swift_classes.sh   # expect total=69 comment=12 code=52 first_code=11
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
cmp compat/retag_swift_classes.sh /private/tmp/build/schmonz/drydock-native/retag_swift_classes && echo staged
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

- [ ] **Step 8: Commit**

```sh
git add compat/retag_swift_classes.sh compat/README.md tests/wrapper_test.sh
git diff --cached --stat
git commit -F - <<'EOF'
refactor(compat): retag_swift_classes' mapping lives in compat/README.md

The 108-line header becomes its usage line, one sentence on why this
wrapper runs each file itself, and a pointer to compat/README.md's new
"retag_swift_classes" table: what each per-file outcome becomes, with
the assertion holding it.

The header's one measured transcript (`chmod 555 ro`, arguments
`a ro/b`: a is retagged, ro/b fails with mkstemp's error and counts as
had_error) is now a test, mutated to fail.

Dropped as history: what compat/retag_swift_classes.c was, which verb's
divergence named this mapping, the compat-matrix rows it unblocked, and
the perror(path) wording the C tool used. Dropped as an untested
can't-happen claim: that a fat argument cannot reach the summing code.

Before: 196 lines, 139 comment, 52 code, first code at 111.
After: 69 / 12 / 52, first code at 11.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h
```

---

### Task 9: `compat/translate.sh`

**Files:**
- Test: `tests/translate_test.sh`. The insertion goes directly above `# ---- DRYDOCK_MACHO_REWRITE names the program word` (`:570`).
- Test: `tests/wrapper_test.sh`. There is an insertion directly above `# THE CAPACITY CAPS, in fix_macho's own words.` (`:1799`), and the header's pointer at `:23-26` is repointed.
- Modify: `compat/translate.sh`
- Modify: `compat/README.md`: a new section directly above `## Thin only`.
- Modify: `tests/compat-sweep.sh:466-468`.

**Interfaces:**
- Consumes: README "Thin only" (Task 4). `mt_new_name`, `mt_translate` and `MT_PROG0` are unchanged.
- Produces: the translate_test cases `cd-dash-file` and `mt-prog-per-call`, the wrapper_test assertion "fix_macho: a 16-character NEW of 32 bytes is refused (1), file untouched, under LC_ALL=…", and the README section `## Which statement each old flag becomes`.

- [ ] **Step 1: Measure**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git diff --quiet d1cab99 -- compat/translate.sh || echo CHANGED-STOP
/private/tmp/drydock-item6/density.sh compat/translate.sh   # expect total=868 comment=509 code=326 first_code=230
```

- [ ] **Step 2: Write the three tests** for claims only the comments held. In `tests/translate_test.sh`, above `# ---- DRYDOCK_MACHO_REWRITE names the program word`:

```sh
# ---- a FILE beginning with '-' ------------------------------------------
# drydock-macho-rewrite refuses an OUT beginning with '-', so the teaching
# form names ./-FILE.new, and both printed lines stay runnable.
ok cd-dash-file "printf 'allow-unmatched\ndylib delete P\n' | drydock-macho-rewrite -f ./-f.new
mv -f ./-f.new -f" -- change_dylib -f -delete P

# ---- MT_PROG is recomputed on every call --------------------------------
# One sourced shell translating two tools names each in its usage line.
got=$( MT_SOURCED=1 /bin/sh -c '. "$1"; mt_translate change_dylib x 2>/dev/null; mt_translate patch_macho 2>&1' sh "$TR" )
if [ "$got" = "Usage: patch_macho input output" ]; then
    pass=$((pass + 1))
else
    printf 'FAIL mt-prog-per-call: got %s\n' "$got" >&2; fail=$((fail + 1))
fi

```

  In `tests/wrapper_test.sh`, above `# THE CAPACITY CAPS, in fix_macho's own words.`:

```sh
# A 16-character NEW of 32 bytes. In a UTF-8 locale ${#3} counts characters,
# so translate.sh lets it through and mseg_name_fits refuses it; in the C
# locale translate.sh refuses it itself. Exit 1 and FILE untouched either way.
fresh
fm_mb=$(printf '\303\251%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)
fm_mb_before=$(sha "$T/f")
for fm_loc in en_US.UTF-8 C; do
    case $fm_loc in
        C) fm_mb_want='new segment name longer than 16 bytes: ' ;;
        *) fm_mb_want='longer than the 16 bytes a segname field holds' ;;
    esac
    rc=0
    ( cd "$T" && LC_ALL=$fm_loc "$BIN/fix_macho" f -rename_seg __DATA "$fm_mb" ) \
        >"$T/out" 2>"$T/err" || rc=$?
    [ "$rc" -eq 1 ] && [ "$(sha "$T/f")" = "$fm_mb_before" ] \
        && grep -qF -- "$fm_mb_want" "$T/err" \
        && ok "fix_macho: a 16-character NEW of 32 bytes is refused (1), file untouched, under LC_ALL=$fm_loc" \
        || bad "fix_macho multibyte NEW ($fm_loc)" "exit $rc: $(tail -1 "$T/err")"
done

```

- [ ] **Step 3: Run them. They pass, because they characterize.** Build, then run `ctest -R 'translate_test|wrapper_test' --output-on-failure`. Expected: both PASS. `translate_test`'s count rises by 2, and `wrapper_test` prints the two `LC_ALL=` labels.

- [ ] **Step 4: Mutate each.** Revert each mutation with `git checkout -- FILE`, rebuild, and confirm with `cmp` or `strings` before running.
  - In `compat/translate.sh`'s `mt_new_name`, change `-*) printf './%s.new' "$1" ;;` to `-*) printf '%s.new' "$1" ;;`. Expected: FAIL `cd-dash-file`.
  - In `mt_translate`, change `MT_PROG=${MT_PROG0:-$mt_tool}` to `MT_PROG=${MT_PROG0:-${MT_PROG:-$mt_tool}}`. Expected: FAIL `mt-prog-per-call`, which gets `Usage: translate.sh input output`.
  - In `mt_tr_fix_macho`'s `-rename_seg` arm, change `[ "${#3}" -le 16 ]` to `[ "${#3}" -le 64 ]`. Expected: FAIL "fix_macho multibyte NEW (C)", because drydock-macho-rewrite's message replaces translate.sh's.
  - In `src/segname.c`, make `mseg_name_fits` return 1 unconditionally. Rebuild; `strings` cannot show this, so confirm that `drydock-macho-rewrite`'s size or `shasum` changed. Expected: FAIL "fix_macho multibyte NEW (en_US.UTF-8)".

- [ ] **Step 5: Comment pass** (bottom to top; `mt_tr_add_version_min`'s three lines at `:628-630` stay)

```sh
. /private/tmp/drydock-item6/rr.sh
F=compat/translate.sh

rr $F 854 857 '# Not one of the seven. There is deliberately no fallback and no' '# to rule out.' <<'EOF'
            # No fallback: a guessed command line for a tool this file does
            # not know is the failure it exists to rule out.
EOF
rr $F 840 843 '# MT_PROG is recomputed on EVERY call, so a long-lived shell that sources' '# presets MT_PROG0 instead.' </dev/null
rr $F 803 810 '# THE ONE OTHER TOOL BESIDES patch_macho WHOSE GRAMMAR NAMES ITS OWN' '# mt_tr_patch_macho, same reason.' <<'EOF'
    # Same fork as mt_tr_patch_macho: OUT is named unless it is BIN itself.
EOF
rr $F 773 779 "# mt_id_out -- OUT per the fork's own asprintf default: new_binary_path if" '# ever called, so the two are mutually exclusive by the time OUT is named.' <<'EOF'
# mt_id_out -- OUT as the fork's source at bd221b8 names it: new_binary_path,
# else BIN under --inplace, else "<BIN>_patched" (appended; the fork's README
# says "prepended", which is wrong).
EOF
rr $F 758 765 '# --inplace names BIN as the write target; an explicit new_binary_path' '# insert_dylib table -- not something mt_id_out gets to arbitrate.' <<'EOF'
    # The fork silently ignores new_binary_path under --inplace and overwrites
    # BIN; refused instead (compat/README.md's insert_dylib table).
EOF
rr $F 720 727 '# mt_id_parse ARG... -- sets MT_ID_DYLIB, MT_ID_BIN, MT_ID_NEWOUT (may be' '# pure translation cannot, rather than walking argv a second time itself.' <<'EOF'
# mt_id_parse ARG... -- sets MT_ID_DYLIB, MT_ID_BIN, MT_ID_NEWOUT (may be
# empty) and MT_ID_INPLACE/MT_ID_WEAK/MT_ID_OVERWRITE/MT_ID_ALLYES/
# MT_ID_STRIP/MT_ID_NOSTRIP (each '' or 1). compat/insert_dylib.sh calls it
# too, to learn DYLIB, BIN and OUT.
EOF
rr $F 705 714 '# --inplace, --overwrite and --all-yes never become a statement: they choose' '# file -- so mt_tr_insert_dylib below never sees the ambiguous case at all.' <<'EOF'
# --inplace, --overwrite and --all-yes choose OUT (mt_id_out) and, in the
# wrapper, how a prompt is answered; none becomes a statement.
EOF
rr $F 694 697 '# NOT one of the six historical tools -- this repo never shipped' '# and why tests/known-callers.sh has nothing to say about it.' <<'EOF'
# Not one of the six: the grammar of Wowfunhappy/insert_dylib at bd221b8.
EOF
rr $F 675 682 '# `argc < 2`. This is the one tool whose grammar is variadic over FILES' '# do for every other tool here.' <<'EOF'
    # `argc < 2`. Variadic over FILES: one command per file, in argv order.
    # MT_OUT names one output, so a wrapper sets it only per file.
EOF
rr $F 641 651 '# THE ONE TOOL WHOSE GRAMMAR ALREADY NAMED ITS OUTPUT, so the teaching form' '# all, since it always names a temp of its own.' <<'EOF'
    # patch_macho's grammar names its output, so the teaching form is the
    # command as typed -- unless IN and OUT are the same string, which
    # drydock-macho-rewrite refuses; that form gets a temp and an install.
EOF
rr $F 603 617 '# fix_macho had no -grow and never enlarged a header. A `dylib replace`' '# allow-unmatched: fix_macho exited 0 on a miss (compat/README.md).' <<'EOF'
    # lc, then dylib, then segment: a rename changes no sizes, so it goes last.
    # allow-unmatched: fix_macho exited 0 on a miss (compat/README.md).
EOF
rr $F 573 594 '# A CHAINED RENAME (`-rename_seg A B -rename_seg B C`) USED TO' '# row 2 of the five adopted ones.' </dev/null
rr $F 566 570 "# fix_macho's renames[] held 16, and its FM_ROOM refused the 17th" '# Enforcing it here is the only thing keeping that refusal alive.' </dev/null
rr $F 552 564 '# Same 16-byte segname limit fix_macho checks here, before any' '# the wording differs earlier.' <<'EOF'
            # fix_macho's 16-byte segname limit, in its words. ${#3} counts
            # characters, not bytes: a longer multibyte name is refused
            # downstream by mseg_name_fits instead.
EOF
rr $F 543 546 "# Only ever one LC kind, and fix_macho's flag is a boolean, so a" '# forms below ASSIGN rather than append.' <<'EOF'
            # A boolean flag: a repeat assigns rather than appends.
EOF
rr $F 533 536 "# fix_macho's FM_MAX_CHANGES was change_dylib's own MR_MAX_OPS, and" '# flag spelling in it.' </dev/null
rr $F 529 531 "# fix_macho's own condition is \`i + 2 < argc\`, so a trailing" '# -change" -- naming the flag, not the missing operand.' </dev/null
rr $F 496 499 '# `change_dylib FILE -grow -grow` asks for nothing, so nothing is emitted.' '# name an output nothing wrote, so it goes too.' <<'EOF'
    # `change_dylib FILE -grow -grow` asks for nothing: no command, no install.
EOF
rr $F 469 476 '# It is a RULING, not a reproduction. The pre-migration wrappers did not' '#' </dev/null
rr $F 409 411 '# PREPENDED, not appended: see the emission comment below. Every' '# them backwards to leave them in the order the batch would.' <<'EOF'
            # Prepended: inserts run in reverse (see the emission order below).
EOF
rr $F 372 375 '# One bucket per family for the operations the load-command walk itself' '# them: see the emission comment below.' <<'EOF'
    # -change/-delete/-reexport and their rpath spellings, in flag order.
EOF
rr $F 368 369 '# The operations as statements, bucketed by kind so the emission can order' '# them (see the emission comment below).' <<'EOF'
    # The operations as statements, bucketed by kind for the emission order.
EOF
rr $F 362 364 '# `argc < 4` in change_dylib.c -- program name plus fewer than three' '# usage text presents -grow as an optional standalone flag.' <<'EOF'
    # change_dylib's `argc < 4`: `change_dylib FILE -grow` is a usage error.
EOF
rr $F 345 349 '# What a reproduced usage line prints where the C tool printed argv[0].' '# usage line.' <<'EOF'
# The C tool's argv[0] in a usage line; mt_translate sets it on every call.
EOF
rr $F 338 342 "# change_dylib's -strip-lc vocabulary, from src/lc_kinds.c. This is the OLD" '# tests/translate_test.sh asserts the two agree rather than assuming it.' <<'EOF'
# change_dylib's -strip-lc vocabulary, frozen. tests/translate_test.sh checks
# it against what `drydock-macho-rewrite --capabilities` advertises.
EOF
rr $F 333 335 "# fix_macho's own second array, from compat/fix_macho.c's FM_MAX_RENAMES. No" "# than one at a time -- so this 16 is fix_macho's alone and lives here." </dev/null
rr $F 328 330 '# Caps, from src/rewrite.h. -change/-delete/-reexport SHARE one array of 32,' '# their own 32; -strip-lc gets 16.' <<'EOF'
# The old tools' caps: -change/-delete/-reexport share 32, as do
# -change-rpath/-delete-rpath; -add, -insert and -add-rpath get 32 each;
# -strip-lc 16; fix_macho's -rename_seg 16. Nothing downstream counts
# operations, so these are the only enforcement.
EOF
rr $F 319 321 "# change_dylib's CD_ROOM: refuse BEFORE the write that would overflow, naming" '#   mt_room <current count> <max> <flag spelling>' <<'EOF'
# mt_room COUNT MAX FLAG -- refuse the one past MAX, in change_dylib's words.
EOF
rr $F 283 302 '# ---- the one command shape ----------------------------------------------' "# tests/translate_test.sh's quoting section." <<'EOF'
# ---- the one command shape ----------------------------------------------
#
# mt_emit FILE OUT, statements on stdin -- print one
# `printf FORMAT | drydock-macho-rewrite FILE OUT`. The statements are the
# FORMAT, so `%` and `\` are doubled; mt_quote's single quotes are what the
# shell needs.
EOF
rr $F 248 269 '# The output a translated command writes. A wrapper sets MT_OUT to its temp' '# MT_OUT is always its own dot-prefixed temp (mw_prepare, drydock-macho-rewrite-compat.sh).' <<'EOF'
# The output a translated command writes: MT_OUT (a wrapper's temp), or for
# the teaching form FILE.new, followed by mt_install_line's `mv -f`. A bare
# FILE beginning with `-` gets `./-FILE.new`, since drydock-macho-rewrite
# refuses an OUT beginning with `-`.
EOF
rr $F 214 229 '# ---- quoting -------------------------------------------------------------' '# ever been handed one.' <<'EOF'
# ---- quoting -------------------------------------------------------------
#
# One argument, quoted only if it needs it. ms_split (src/script.c) reads a
# statement's words by shell rules, so the same quoting serves the script.
EOF
rr $F 2 212 '# compat/translate.sh -- turn an OLD-grammar invocation into the drydock-macho-rewrite' '# keep.' <<'EOF'
# compat/translate.sh -- print the drydock-macho-rewrite command line(s) an
# old-grammar invocation is equivalent to. Pure text: it opens, reads and
# runs nothing.
#
#   sh compat/translate.sh TOOL ARG...        print the equivalent, exit 0
#   MT_SOURCED=1 . compat/translate.sh        load mt_translate() and helpers
#
# Exit 0: the commands, one per line, none for a no-op. Exit 1: the old tool
# would have refused this argv, and its own message is on stderr. Exit 2: no
# equivalent (an unknown TOOL). tests/translate_test.sh pins every line; the
# table of which statement each old flag becomes is in compat/README.md.
EOF
```

  Where each deleted passage went:
  - The output contract is held by `tests/translate_test.sh`'s `ok` and `refuses` helpers, which check the exit code and the whole of stdout. The `unknown-tool` case holds exit 2, and `cd-grow-only` holds exit 0 with no lines.
  - The grammar table moves to `compat/README.md`, in Step 6.
  - The ordering list's copy in the header goes. `mt_tr_change_dylib`'s emission comment keeps the numbered order, and `cd-mixed-order` and `cd-insert-reverse` hold it.
  - The header's divergence list goes. It copied `compat/README.md`'s, and it falsely said each entry is documented "at its site in cli/drydock-macho-rewrite.c".
  - The capacity-cap history goes. The `cap-*` and `fm-cap-*` cases hold the caps.
  - The two "refused a shape" narratives (chained `-change` and `-rename_seg`) go to the commit message. `fm-chain`, `cd-chain` and README row 2 hold today's behaviour.
  - The can't-happen claims deleted are "this function never actually has to choose" (held by `id-mutex`), "the body is never empty" (held by `fm-usage`), and "a single `-grow` never gets this far" (held by `cd-usage-grow`).

- [ ] **Step 6: README mapping section.** Insert directly above `## Thin only`:

```markdown
## Which statement each old flag becomes

`compat/translate.sh` holds this mapping, in shell rather than inside
`drydock-macho-rewrite`, so the binary never learns the spellings
`docs/PROPOSAL.md` refused as synonyms. The wrappers source the same file
`tests/translate_test.sh` tests. Whatever an invocation asks for, its
statements go into one `printf ... | drydock-macho-rewrite FILE OUT`.

| old flag | statement |
|---|---|
| `change_dylib FILE -change O N` | `dylib replace O N` |
| `change_dylib FILE -delete P` | `dylib delete P` |
| `change_dylib FILE -reexport P` | `dylib reexport P` |
| `change_dylib FILE -add P` | `dylib append P` |
| `change_dylib FILE -insert P` | `dylib insert P` |
| `change_dylib FILE -change-rpath O N` | `rpath replace O N` |
| `change_dylib FILE -delete-rpath P` | `rpath delete P` |
| `change_dylib FILE -add-rpath P` | `rpath append P` |
| `change_dylib FILE -strip-lc KIND` | `load-command delete KIND` |
| `change_dylib FILE -grow` | nothing: a short header pad grows anyway |
| `fix_macho FILE -change O N` | `dylib replace O N` |
| `fix_macho FILE -strip_build_version` | `load-command delete build-version` |
| `fix_macho FILE -rename_seg O N` | `segment rename O N` |
| `add_version_min FILE` | `version-min set 10.9` |
| `patch_macho IN OUT` | `fixups set classic`, into `OUT` (into `OUT.new` and then `mv` when `IN` and `OUT` are the same) |
| `rename_segment FILE O N` | `segment rename O N` |
| `retag_swift_classes F1 F2 ...` | `swift-abi set legacy`, once per file |

`tests/translate_test.sh`'s `cd-*`, `fm-*`, `avm`, `pm`, `pm-same`, `rs` and
`rsc-*` cases hold each row.

```

- [ ] **Step 7: Repoint the two pointers into the old header.** In `tests/compat-sweep.sh`, replace

```
# Runs the emitted command lines in order, stopping at the first nonzero exit
# and returning that exit code -- the contract compat/translate.sh's header
# states, in the one place the sweep needs it executed.
```

  with

```
# Runs the emitted command lines in order, stopping at the first nonzero exit
# and returning that exit code.
```

  In `tests/wrapper_test.sh`, replace

```
# The divergences themselves are documented at their sites: the
# list at the top of compat/translate.sh, and the "DELIBERATE DIVERGENCES
# FROM <tool>" blocks in cli/drydock-macho-rewrite.c's cmd_segment, cmd_retag_swift and
# cmd_declassify.
```

  with

```
# compat/README.md records each divergence and the assertion here that holds it.
```

- [ ] **Step 8: Verify**

```sh
git diff -U0 -- compat/translate.sh | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(#|$)'   # expect nothing
git grep -n -E "translate\.sh's header|at the top of compat/translate\.sh" -- . ':!docs/superpowers'   # expect nothing
git grep -n 'compat/translate.sh' -- tests/wrapper_test.sh | head -1   # positive control: a hit
git grep -c -E 'macho_grow\.h|macho_grow_test\.c|(change_dylib|fix_macho|patch_macho|rename_segment|add_version_min|retag_swift_classes)\.c' -- src cli tests compat CMakeLists.txt | awk -F: '{ n += $2 } END { print n }'   # expect 49
/private/tmp/drydock-item6/density.sh compat/translate.sh   # expect comment <= 170 and first_code <= 20 (simulated: total=482 comment=123 code=326 first_code=18)
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j
cmp compat/translate.sh /private/tmp/build/schmonz/drydock-native/drydock-macho-rewrite-translate.sh && echo staged
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

- [ ] **Step 9: Commit**

```sh
git add compat/translate.sh compat/README.md tests/translate_test.sh tests/wrapper_test.sh tests/compat-sweep.sh
git diff --cached --stat
git commit -F - <<'EOF'
refactor(compat): translate.sh's header is eleven lines

The 211-line header held an output contract tests/translate_test.sh
already enforces, a flag-to-statement table (now compat/README.md's
"Which statement each old flag becomes"), an ordering list the
emission comment keeps where it is used, and a copy of
compat/README.md's divergence list that said each entry was documented
at its site in cli/drydock-macho-rewrite.c, which none is. In-function
comments shrink to a sentence each.

Three claims only the comments held are now tests, each mutated to
fail: the teaching form names ./-FILE.new for a FILE beginning with
'-'; MT_PROG is recomputed on every call; and fix_macho's -rename_seg
refuses a 16-character, 32-byte NEW with exit 1 and FILE untouched in
both a UTF-8 and the C locale, since ${#3} counts characters.

Dropped as history: the chained -change and -rename_seg shapes this
file once refused, with exit 2, until the repo owner ruled that doing
what was asked in the order asked is the behaviour to keep; the caps'
life as MR_MAX_OPS and FM_MAX_RENAMES; the pre-migration wrappers'
two conflict rules. Dropped as can't-happen claims already held by
id-mutex, fm-usage and cd-usage-grow.

Before: 868 lines, 509 comment, 326 code, first code at 230.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h
```

  Add Step 8's measured line as "After: …" to the message before committing.

---

### Task 10: `cli/drydock-macho-rewrite.c`'s history markers

**Files:**
- Modify: `cli/drydock-macho-rewrite.c`, in comments only. The ranges are listed below.

**Interfaces:** Consumes Task 3's three-line edit at `:382-384`, which leaves the line count unchanged. **These line numbers are at `26d6f8c`, not `d1cab99`.** That minos-set commit added six lines to `info_cb`, so every range below `:415` sits six lines lower than it did at `d1cab99`. If `cli/drydock-macho-rewrite.c` has changed again since, `rr` refuses. Find the moved ranges with `grep -n -F` on the anchor text.

The markers, measured: 16 passages here, plus `:382-384` in Task 3. The scope is `cli/drydock-macho-rewrite.c`. A marker is a passage about removed verbs, the old exit numbering, a commit SHA, "used to" / "now" / "left" / "while … stood here", or `macho9`, which appears at `:98` and `:101`. The queue's "22 markers, 7 `macho9`" was counted when the file was 1,384 lines.

- [ ] **Step 1: Measure and confirm there is no foreign change**

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
git diff --quiet -- cli/drydock-macho-rewrite.c || echo DIRTY-STOP
git log --oneline 26d6f8c..HEAD -- cli/drydock-macho-rewrite.c   # expect only Task 3's commit
/private/tmp/drydock-item6/density.sh cli/drydock-macho-rewrite.c   # record: at 26d6f8c it was total=874 comment=389 code=441 first_code=65
```

  Every behavioural claim these passages make is already held, by these `tests/cli_test.sh` assertions:
  - `--dry-run`, `--output` and `--verbose` refused by name (the block from `:3565`);
  - verb shadowing and `./info` ("bare form: ... and './info' edits the file that is named like a verb", from `:3731`);
  - both `bad_out` wordings;
  - the grow crash cases, by `tests/grow_test.c`'s `test_grow_refuses_a_section_past_the_image` and `test_grow_refuses_an_image_with_no_section_data`.

  So this task writes no test.

- [ ] **Step 2: The edits** (bottom to top)

```sh
. /private/tmp/drydock-item6/rr.sh
F=cli/drydock-macho-rewrite.c

rr $F 859 868 '* there is nothing left for it to be but a file name.' "* with '-'. */" <<'EOF'
     * there is nothing left for it to be but a file name. */
EOF
rr $F 745 747 "* forwarded verbatim past that point -- the whole of this binary's mutating" "* and mv_add_version_min's are gone." <<'EOF'
 * forwarded verbatim past that point.
EOF
rr $F 721 728 '* `--output` and `--dry-run` were flags while this form still wrote FILE and' '* deserves.' <<'EOF'
 * A `--`-prefixed token in either position is refused by name rather than
 * opened as a file: this form has no flags. tests/cli_test.sh pins
 * `--dry-run`, `--output` and `--verbose`.
EOF
rr $F 717 719 "* \`drydock-macho-rewrite FILE OUT < script\` -- the redirection is the shell's job, and" "* interface for no capability at all (it went; see this file's header)." <<'EOF'
 * `drydock-macho-rewrite FILE OUT < script` -- the redirection is the shell's job.
EOF
rr $F 266 267 '*       matches statements against, so this can never advertise a statement' '*       the parser would refuse, or omit one it accepts. `nargs` is the operand' <<'EOF'
 *       matches statements against. `nargs` is the operand
EOF
rr $F 255 261 '*       the three read-only queries are left (verify, info, imports). The' '*       attribute in use.' <<'EOF'
 *       the four read-only queries are listed (verify, info, imports,
 *       exports). `info`'s `flags=--thin` is the one attribute in use.
EOF
rr $F 250 251 '*       still have no advertised way to send one, which is what' '*       --capabilities looked like while `verb edit` stood here instead.' <<'EOF'
 *       still have no advertised way to send one.
EOF
rr $F 229 233 '*       exact allocation breakdown). The two numbers are 1 and 2, not the' "*       numbers run. A script run returns me_run's own code verbatim, and" <<'EOF'
 *       exact allocation breakdown). A script run returns me_run's own
 *       code verbatim, and
EOF
rr $F 187 192 '* ONE function rather than the same lines in each form. There is one form' "* for \"which begins with '-'\")." <<'EOF'
 * `verb` is always "edit", the prefix src/edit.c's report carries, so a
 * refusal before the script is read reads like the ones after it.
 * tests/cli_test.sh greps for "never writes its input" and for "which
 * begins with '-'".
EOF
rr $F 179 180 '* a caller reaching for the old flag-first habit -- from before these forms' '* took an output -- would otherwise CREATE a file named after the flag and' <<'EOF'
 * a caller reaching for a flag-first habit would otherwise CREATE a file
 * named after the flag and
EOF
rr $F 157 158 '* here is a build failure, not a hope -- the same device commit 247d09d used' "* for mg_classify/ml_bump_lc's coupling. */" <<'EOF'
 * here is a build failure, not a hope. */
EOF
rr $F 138 140 '* other reason either one refuses, not split out to MR_FAIL. The same fold' '* (mg_plausible) returns EX_REFUSED for any failure of its own. So a failed' <<'EOF'
 * other reason either one refuses, not split out to MR_FAIL. So a failed
EOF
rr $F 96 121 '/* Exit codes. 0 is success, as always. Everything else used to be a flat 1,' '* form ships, it no longer is.' <<'EOF'
/* Exit codes: 0 ok; EX_REFUSED (1) when drydock-macho-rewrite examined FILE
 * and declined on purpose; EX_FAIL (2) when something went wrong running it.
 * The highest code means "could not do its job", as with diff, grep and cmp,
 * so a caller can tell "this file just isn't one it will touch" from "retry,
 * or investigate" without scraping stderr. A caller checking only nonzero
 * needs nothing more.
EOF
rr $F 77 80 "* pin them equal to this file's own exit codes, and me_run hands them back." '* through the statements. */' <<'EOF'
 * pin them equal to this file's own exit codes, and me_run hands them back. */
EOF
rr $F 26 49 '* EIGHT MUTATING VERBS USED TO LIVE HERE -- declassify, segment, retag-swift,' '*' </dev/null
rr $F 14 20 '* THERE WAS AN `edit FILE OUT SCRIPT` VERB, and it went with the other eight:' '*' </dev/null
```

  The `:138-140` sentence ("The same fold holds on the one verb left … cmd_verify") is deleted, not repointed. The capabilities contract at `:225-226` already says the fold holds "on verify as well as a script run". The `:266` "can never advertise" claim is structural and no test holds it, so it is deleted. The `:848` "can never shadow one" stays, held by `tests/cli_test.sh`'s `./info` assertions.

- [ ] **Step 3: Verify**

```sh
git diff -U0 -- cli/drydock-macho-rewrite.c | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ' | grep -vE '^[-+][[:space:]]*(/?\*|//|$)'   # expect nothing
grep -n -E 'macho9|used to|no longer|while .verb|247d09d|the three read-only' cli/drydock-macho-rewrite.c   # expect nothing
grep -c 'EX_REFUSED' cli/drydock-macho-rewrite.c   # positive control: nonzero
/private/tmp/drydock-item6/density.sh cli/drydock-macho-rewrite.c   # record; simulated: total=787 comment=302 code=441 first_code=34
/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j 2>&1 | grep -c 'warning:'   # expect 0
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native
```

- [ ] **Step 4: Commit**

```sh
git add cli/drydock-macho-rewrite.c
git diff --cached --stat
git commit -F - <<'EOF'
docs(cli): say what the front end does, not what it used to

Sixteen passages narrated the front end's past: the edit verb and the
eight mutating verbs it went with, and the grow verb's crash coverage
moving into tests/grow_test.c; the flat exit code macho9 once had and
the 0/1/2 numbering that first shipped reversed; the --output,
--dry-run and --verbose flags; "while `verb edit` stood here"; the
shadowing verb words that are now file names; and a citation of commit
247d09d. The behaviour each described is held by tests/cli_test.sh or
tests/grow_test.c, so the history goes to this message.

Corrected: the capabilities contract said "the three read-only queries
(verify, info, imports)"; --capabilities advertises four, with exports.
Deleted as an untested structural claim: print_capabilities "can never
advertise a statement the parser would refuse".

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
git log -1 --format=%h
```

  Add Step 1's and Step 3's density lines to the message as "Before: …; after: …" before committing.

---

### Task 11: The queue, then push

**Files:**
- Modify: `docs/superpowers/QUEUE.md`: the item-6 table row, the "Part one" and "Part two" paragraphs, and a new subsection directly above `## For shipyard: build OUT of tree is documented but not operative`.

**Interfaces:** Consumes the SHAs and density lines recorded in Tasks 2–10.

- [ ] **Step 1: The table row.** Replace

```
**first half done**, pushed, `3ce226a..fb241d3`, CI green. Second half — the human review and the README rewrite that removes the marker — is the repo owner's and is what still blocks the first release |
```

  with

```
**first half done**, pushed, `3ce226a..fb241d3`, CI green. **Machine half of the second half done**, see "The machine half" below. What remains is the repo owner's: the human review and the README rewrite that removes the marker, which still blocks the first release |
```

- [ ] **Step 2: Mark Part one and Part two done.** After `human review that is item 6's second half.`, add ` **Done** by item 6's machine half ("The machine half", below).` After `**a plan of its own, and explicitly not part\nof the zero-risk sweep**.`, add ` **Done** by item 6's machine half, tests first: all 50 now begin \`ERROR: \`.`

- [ ] **Step 3: The subsection.** Insert above `## For shipyard: build OUT of tree is documented but not operative`. Fill each after cell and each SHA from what Tasks 2–10 recorded. These are measured values, not decisions left open:

```markdown
### The machine half

Nine commits: the SHAs recorded by Tasks 2 to 10, in order. Measured
before at `d1cab99`, with the rule above: `#` counts in shell, and
preprocessor lines are code in C.

| file | before: total / comment / code, first code | after |
|---|---|---|
| `compat/patch_macho.sh` | 224 / 169 / 45, line 137 | (Task 5) |
| `compat/rename_segment.sh` | 224 / 167 / 44, line 159 | (Task 6) |
| `compat/add_version_min.sh` | 106 / 82 / 21, line 77 | (Task 7) |
| `compat/retag_swift_classes.sh` | 196 / 139 / 52, line 111 | (Task 8) |
| `compat/translate.sh` | 868 / 509 / 326, line 230 | (Task 9) |
| `compat/drydock-macho-rewrite-compat.sh` | 448 / 266 / 164, line 68 | (Task 4) |
| `cli/drydock-macho-rewrite.c` | 874 / 389 / 441, line 65 (at `26d6f8c`) | (Task 10) |

- `src/grow.c`'s 50 `macho_grow: ` diagnostics begin `ERROR: `. They are held by
  `tests/grow_test.c`'s `test_grow_diagnostics_name_no_program`, whose needle
  is anchored to the line start, and by one `tests/wrapper_test.sh` assertion.
- Retired-filename citations (scope `src/ cli/ tests/ compat/ CMakeLists.txt`,
  the eight names): 97 lines before and 49 after, every survivor past-tense
  provenance.
- Eleven new assertions hold what only comments had claimed. One comment in
  `tests/wrapper_test.sh` claimed an `add_version_min` hard-link assertion that
  did not exist. It exists now.
- **Deferred:** `tests/cli_test.sh:1397` (`add_version_min.c` in the present
  tense) waits for the minos-set plan's `tests/cli_test.sh` work.
- **Not done, and not the machine's:** the owner's review and `README.md`; the
  module prefixes; the `tests/*.sh` headers' own narration (for example
  `tests/change_dylib_test.sh:44-72`), which item 6 did not name.
```

  Replace each `(Task N)` with that task's recorded density line, formatted `total / comment / code, line N`. Replace the first sentence with the nine SHAs. If Task 5 deferred `tests/cli_test.sh:873`, add it to **Deferred**.

- [ ] **Step 4: Check the queue edit.** Run `git grep -n '(Task [0-9]*)' -- docs/superpowers/QUEUE.md`, which must print nothing. Its positive control is `git grep -n 'The machine half' -- docs/superpowers/QUEUE.md`, which prints three hits.

- [ ] **Step 5: Commit**

```sh
git add docs/superpowers/QUEUE.md
git diff --cached --stat
git commit -F - <<'EOF'
docs(queue): item 6's machine half is done; the human half remains

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
```

- [ ] **Step 6: Push and check CI.** Stay on `main`, and do not add or rewrite a remote.

```sh
git push origin main || git push https://github.com/Mavergreen/drydock.git main
gh run list --limit 3
```

  Watch the run for the pushed SHA until it finishes (`gh run watch`). A local green run is not CI: the `wrapper_test` locale case and the `grow_test` anchors must also pass on the `macos-26-arm64` runner.

---

## Self-Review

**Spec coverage.**
- C's tests: Task 1. C's change: Task 2, with the per-class replacement stated there, and `compat/README.md:661` handled.
- B: Task 3 for `src/`, `cli/`, `tests/` and `CMakeLists.txt`, and Tasks 5–9 for the `compat/` citations inside the headers they delete. Task 9's Step 8 checks the final 49.
- A: Tasks 4–9, one file each, each with before/after density, the no-code-changed check, a first-code threshold, and its can't-happen claims named. Task 10 covers the CLI markers.
- D: Task 11.
- The deferrals the spec lists appear in Task 3 Step 4, Task 5 Step 7 and Task 11 Step 3.
- `README.md` appears only in "never touch" constraints.

**Placeholder scan.** Task 11's `(Task N)` cells and SHAs are values measured during execution. Step 4 checks that none survive. Every code and test step shows its full text. No "similar to Task N" is used: each wrapper task repeats its own `rr` calls in full.

**Consistency.**
- `stderr_contains_during`'s signature is unchanged; only the `^` semantics are added.
- Every assertion label that a README row cites is either copied from `tests/wrapper_test.sh` at `d1cab99` or created by this plan with that exact text:
  - "patch_macho: with IN and OUT both bad, OUT's refusal is the one named";
  - "patch_macho: a dangling symlink as OUT is refused (1), and its target is not created";
  - "add_version_min: a hard-linked FILE is refused (1), both names untouched" (from `hl_case`'s `"$hl_tool: a hard-linked FILE is refused (1), both names untouched"`);
  - "add_version_min: a writable file in a read-only directory exits 2, untouched";
  - "retag_swift_classes: a writable file in a read-only directory is an error, untouched, and the loop goes on".
- The README phrases Task 7 writes are exactly the ones Task 8 replaces.

**Dry run.** Before this plan was handed off, its edits were applied to a scratch copy of `26d6f8c`:
- Every `rr` range matched its anchors.
- Every Edit anchor occurs exactly once, except `rm -rf "$T/adir"`, which is why Task 5 names a two-line anchor.
- The no-code-changed check printed nothing for any file.
- Every wrapper passes `sh -n`, and the touched C files compile.
- The density results are the "simulated" figures quoted in Tasks 4, 9 and 10, and Tasks 5–8's expected values.
- Task 1's `grow_test.c` additions compile against today's library and fail exactly 8 ways. With `^macho_grow: ` needles they pass. After Task 2's `sed` they pass, and Mutation 2 fails them exactly once.
- The new wrapper and translate tests' commands were each run against the current build, and gave the expected exits and messages.
