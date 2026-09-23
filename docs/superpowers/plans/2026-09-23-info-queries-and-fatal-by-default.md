# Queryable Detections and Unmatched-Is-Fatal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every detection `target 10.9` performs askable through `info` on thin files and fat containers, then make an unmatched operation refuse by default, with `allow-unmatched` as the opt-in three compat wrappers need.

**Architecture:** `cmd_info` gains section names, a Swift-tag line, and a fat-container path; a new `info --thin` flag preserves the exit-status gate four wrappers depend on. Separately, `fatal-warnings` is deleted from the parser and `allow-unmatched` takes its slot with the field's default inverted.

**Tech Stack:** C99, CMake + CTest, POSIX `/bin/sh` wrappers, shell test suites (`tests/cli_test.sh`, `tests/wrapper_test.sh`) and C test binaries (`tests/script_test.c`).

**Spec:** `docs/superpowers/specs/2026-09-23-info-queries-and-fatal-by-default-design.md`

## Global Constraints

- **A thin file's `info` output must stay byte-identical** through Tasks 1–2 and change only by *added* lines in Tasks 3–5. `compat/insert_dylib.sh:91,101`, `tests/differential.sh:260` and `tests/bake_mavericks_shim_test.sh` all read it.
- **New `info` lines nest at four spaces** (`    sectname=`), one level deeper than today's two-space `  segname=`, so no existing grep can match them. `swift-abi:` is flush left, beside `header pad:`.
- **Ordering is load-bearing:** `info --thin` and the wrapper migration (Tasks 1–2) MUST land before `info` learns fat containers (Task 5), or four wrappers silently start accepting fat files between commits.
- **Exit codes:** `EX_REFUSED` is 1, `EX_FAIL` is 2 (`cli/drydock-macho-rewrite.c:148-149`). `mw_thin_only` intercepts only 1 and lets 2 fall through.
- **Segment and section names are `char[16]` and need not be NUL-terminated.** Always `%.16s` to print and `strncmp(..., 16)` to compare.
- **Build:** `cmake --build build-native -j` then `ctest --test-dir build-native --output-on-failure`. The shell suites also run standalone with `DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite`.
- Every commit message ends with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `cli/drydock-macho-rewrite.c` | `cmd_info`, `info_cb`, the `info` verb arm, `print_capabilities` | 1, 3, 4, 5 |
| `compat/drydock-macho-rewrite-compat.sh` | `mw_thin_only`, the shared gate | 2 |
| `compat/rename_segment.sh` | its own inline thin gate; its zero-rename verdict | 2, 9 |
| `compat/translate.sh` | emits `allow-unmatched` for three wrappers | 8 |
| `compat/bake-mavericks-shim.sh` | the match probe | 10 |
| `compat/README.md` | the adopted-divergences table | 6 |
| `src/script.c`, `src/script.h` | the directive table and the script struct | 7 |
| `src/edit.c` | the three consumers of the flag | 7 |
| `README.md` | the user-facing grammar and query docs | 11 |

---

### Task 1: `info --thin`

A flag that refuses a fat container. It is a no-op today, because `cmd_info` is
already a bare `mi_open` — which is the point: it must exist and be tested
*before* `info` learns fat containers, so the wrappers have somewhere to move.

**Files:**
- Modify: `cli/drydock-macho-rewrite.c:418` (`cmd_info` signature), `:758-761` (the verb arm), `:285` (`print_capabilities`), `:269` (the directive comment)
- Test: `tests/cli_test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `static int cmd_info(const char *path, int thin_only)`. Capability line `verb info flags=--thin`. CLI form `drydock-macho-rewrite info [--thin] FILE`.

- [ ] **Step 1: Write the failing test**

Add to `tests/cli_test.sh`, in the `--capabilities` region near line 414 for the
capability assertion and immediately after it for the behaviour ones:

```sh
# ---- info --thin ---------------------------------------------------------
# The flag exists before `info` learns fat containers, so the four wrappers
# that reproduce their upstreams' thin-only refusal by gating on info's EXIT
# STATUS have somewhere to move first. On a thin file it changes nothing.
echo "$caps" | grep -qxF "verb info flags=--thin" \
    && ok "capabilities: info advertises --thin" \
    || bad "capabilities: info flags" "no 'verb info flags=--thin' line: $(echo "$caps" | grep '^verb info')"

"$DRYDOCK_MACHO_REWRITE" info --thin "$FIXTURE" >"$T/thin.out" 2>"$T/thin.err"
[ $? -eq 0 ] && ok "info --thin: accepted on a thin Mach-O" \
    || bad "info --thin" "exited nonzero on a thin file: $(cat "$T/thin.err")"

"$DRYDOCK_MACHO_REWRITE" info "$FIXTURE" >"$T/nothin.out" 2>/dev/null
cmp -s "$T/thin.out" "$T/nothin.out" \
    && ok "info --thin: identical output to plain info on a thin file" \
    || bad "info --thin output" "differs from plain info: $(diff "$T/nothin.out" "$T/thin.out" | head -5)"

# A FILE literally named --thin is still reachable as ./--thin, the same
# remedy bad_out names for an OUT beginning with '-'.
"$DRYDOCK_MACHO_REWRITE" info --thin >/dev/null 2>&1
[ $? -eq 2 ] && ok "info --thin: --thin with no FILE is a usage error (2)" \
    || bad "info --thin usage" "--thin with no FILE did not exit 2"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cmake --build build-native -j && DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/cli_test.sh 2>&1 | grep -E 'info --thin|info advertises'`

Expected: FAIL on all four — `--capabilities` has no `flags=` on its info line, and `info --thin FIXTURE` is `argc == 4`, which today hits `usage: … info FILE` and exits 2.

- [ ] **Step 3: Write the minimal implementation**

In `cli/drydock-macho-rewrite.c`, change the signature and add the early refusal:

```c
static int cmd_info(const char *path, int thin_only) {
    mi_image im;
    int mo_rc = mi_open(path, &im);
    if (mo_rc == MI_IO_ERROR) {
        fprintf(stderr, "drydock-macho-rewrite info: %s: cannot open or read\n", path);
        return EX_FAIL;
    }
    if (mo_rc != 0) {
        fprintf(stderr, "drydock-macho-rewrite info: %s: not a readable 64-bit Mach-O\n", path);
        return EX_REFUSED;
    }
    (void)thin_only;   /* Task 5 gives this its only effect. */
```

Replace the verb arm at `:758-761`:

```c
    if (strcmp(verb, "info") == 0) {
        /* `--thin` is the ONE flag any query verb takes. It is recognised
         * only in argv[2], so a FILE named `--thin` stays reachable as
         * `./--thin`, the same remedy bad_out names for an OUT beginning
         * with '-'. */
        int thin_only = 0, ai = 2;
        if (argc > 2 && strcmp(argv[2], "--thin") == 0) { thin_only = 1; ai = 3; }
        if (argc != ai + 1) {
            fprintf(stderr, "usage: %s info [--thin] FILE\n", argv[0]);
            return EX_FAIL;
        }
        return cmd_info(argv[ai], thin_only);
    }
```

In `print_capabilities`, replace `printf("verb info\n");` with:

```c
    /* The one query flag any verb takes. A wrapper reproducing an old tool's
     * thin-only refusal checks for this line rather than assume the flag,
     * because gating on plain `info` failing stopped working when `info`
     * learned fat containers. */
    printf("verb info flags=--thin\n");
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: PASS, with no other suite regressing.

- [ ] **Step 5: Commit**

```bash
git add cli/drydock-macho-rewrite.c tests/cli_test.sh
git commit -m "feat(info): add --thin, the gate four wrappers will need

info is a bare mi_open today, so --thin changes nothing yet. It lands first
so the wrappers that reproduce their upstreams' thin-only refusal by gating
on info's exit status have somewhere to move before info learns fat
containers.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The four wrappers move to `info --thin`

**Files:**
- Modify: `compat/drydock-macho-rewrite-compat.sh:307-312` (`mw_thin_only`), `compat/rename_segment.sh:204-208` (its inline copy)
- Test: `tests/wrapper_test.sh:2071`

**Interfaces:**
- Consumes: `drydock-macho-rewrite info --thin FILE` from Task 1.
- Produces: no new names. `mw_thin_only FILE` keeps its exact contract — return 1 only when `info` returned `EX_REFUSED`.

- [ ] **Step 1: Write the failing test**

Extend the block at `tests/wrapper_test.sh:2071`. `fm_mkfat` is already defined
at line 1602 in this file.

```sh
# The gate is `info --thin`, not plain `info`: once `info` reports a fat
# container the plain form stops failing, and a wrapper gating on it would
# start rewriting files its upstream refused outright. Asserted on the
# WRAPPERS, not on mw_thin_only directly, because the contract is what a
# caller sees.
fm_mkfat "$T/gatefat" "$FIXTURE" 16777223 "$FIXTURE" 16777223
for gate_tool in patch_macho add_version_min rename_segment retag_swift_classes; do
    case $gate_tool in
        rename_segment) set -- "$T/gatefat" __DATA __DATB ;;
        *)              set -- "$T/gatefat" ;;
    esac
    cp "$T/gatefat" "$T/gatefat.keep"
    "$BUILD/$gate_tool" "$@" >/dev/null 2>"$T/gate.err"; gate_rc=$?
    [ "$gate_rc" -eq 1 ] \
        && ok "$gate_tool: a fat container is still refused (1)" \
        || bad "$gate_tool fat gate" "exited $gate_rc, not 1: $(cat "$T/gate.err")"
    cmp -s "$T/gatefat" "$T/gatefat.keep" \
        && ok "$gate_tool: the refused fat container is untouched" \
        || bad "$gate_tool fat gate" "the input changed"
done

# EX_FAIL still falls through, which is what makes `add_version_min <dir>`
# exit 2 on both sides. A directory is the measurement mw_thin_only's own
# comment names.
"$BUILD/add_version_min" "$T" >/dev/null 2>&1
[ $? -eq 2 ] && ok "mw_thin_only: EX_FAIL (2) still falls through" \
    || bad "mw_thin_only EX_FAIL" "a directory did not exit 2"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cmake --build build-native -j && DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/wrapper_test.sh 2>&1 | grep 'fat gate'`

Expected: These PASS already — plain `info` still fails on fat. That is correct and expected: this test is a **regression guard written before the change that could break it**, not a red-to-green cycle. Record the passing output; Step 4 proves it still passes after the switch, and Task 5 is where it would have failed without this task.

- [ ] **Step 3: Make the change**

`compat/drydock-macho-rewrite-compat.sh`, in `mw_thin_only`:

```sh
mw_thin_only() {
    drydock-macho-rewrite info --thin "$1" >/dev/null 2>&1
    mw_to_rc=$?
    [ "$mw_to_rc" -eq 1 ] && return 1
    return 0
}
```

Update the comment above it: `drydock-macho-rewrite info` is no longer a bare
`mi_open` — `info --thin` is. Replace the sentence "`drydock-macho-rewrite info`
is a bare mi_open, so its verdict IS the old verb's" with "`drydock-macho-rewrite
info --thin` refuses a fat container, so its verdict IS the old verb's — plain
`info` reports one, which is why the flag exists."

`compat/rename_segment.sh:204-208`:

```sh
if ! drydock-macho-rewrite info --thin "$mw_file" >/dev/null 2>&1; then
    printf '%s: not a readable 64-bit Mach-O\n' "$mw_file" >&2
    exit 1
fi
```

Update its header note at `:86-96` the same way: the gate is `info --thin`, and
the reason is now explicit rather than incidental.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: PASS, identical to Step 2's output.

- [ ] **Step 5: Commit**

```bash
git add compat/drydock-macho-rewrite-compat.sh compat/rename_segment.sh tests/wrapper_test.sh
git commit -m "refactor(compat): gate on info --thin, not on info failing

Four wrappers reproduce their upstreams' thin-only refusal by gating on
info's exit status. That worked because info was a bare mi_open; it stops
working the moment info reports a fat container. Move the gate to the flag
that asks the question directly, and pin the refusal on the wrappers so the
next commit cannot quietly open it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `info` prints section names

**Files:**
- Modify: `cli/drydock-macho-rewrite.c:393-398` (`info_cb`'s `LC_SEGMENT_64` arm)
- Test: `tests/cli_test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `    sectname=%.16s` lines, four spaces, one per `section_64`, in section order, under each `  segname=` line.

- [ ] **Step 1: Write the failing test**

Place after `segread` is compiled (`tests/cli_test.sh:2407`), so the
cross-check has a reader.

```sh
# ---- info: section names --------------------------------------------------
# The detection `target 10.9` makes for __DATA_CONST is "does it carry any
# __objc_ section", and until now nothing could ask: info printed segname and
# nsects but never a section name. Four spaces, one level deeper than
# "  segname=", so no existing consumer's grep can reach these.
"$DRYDOCK_MACHO_REWRITE" info "$T/segment_fixture" >"$T/sect.out" 2>/dev/null

# Cross-checked against segread, never against otool, and never against a
# hand-written list: the two readers must agree on names AND on count.
"$T/segread" segs "$T/segment_fixture" | sed -n 's|^SECT [^/]*/||p' | sort >"$T/sect.want"
sed -n 's/^    sectname=//p' "$T/sect.out" | sort >"$T/sect.got"
cmp -s "$T/sect.want" "$T/sect.got" \
    && ok "info: sectname lines match segread, name for name" \
    || bad "info sectname" "differs: $(diff "$T/sect.want" "$T/sect.got" | head -5)"

[ -s "$T/sect.want" ] \
    && ok "info: the fixture really has sections to print" \
    || bad "info sectname" "the fixture has no sections; this assertion proves nothing"

# A 16-byte name uses the whole field and is NOT NUL-terminated. %.16s is
# what prints it whole; %s would run into the next struct member.
"$T/segread" segs "$T/segment_16_fixture" >/dev/null 2>&1 && {
    "$DRYDOCK_MACHO_REWRITE" info "$T/segment_16_fixture" 2>/dev/null \
        | grep -q '^    sectname=[!-~]\{1,16\}$' \
        && ok "info: a 16-byte sectname prints whole, with nothing after it" \
        || bad "info sectname 16" "a 16-byte name ran past its field: $("$DRYDOCK_MACHO_REWRITE" info "$T/segment_16_fixture" 2>/dev/null | grep '^    sectname=' | head -2)"
}

# The added lines must not reach any existing consumer's pattern.
grep -c '^  ordinal=[0-9]* path=' "$T/sect.out" >"$T/sect.ord.new"
grep -q '^    sectname=' "$T/sect.out" \
    && ok "info: sectname lines are present" \
    || bad "info sectname" "none printed at all"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cmake --build build-native -j && DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/cli_test.sh 2>&1 | grep 'info sectname\|info: sectname'`

Expected: FAIL — `$T/sect.got` is empty, so `cmp` reports a difference against a non-empty `sect.want`.

- [ ] **Step 3: Write the minimal implementation**

In `info_cb`, extend the `LC_SEGMENT_64` arm:

```c
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        printf("  segname=%.16s vmaddr=0x%llx vmsize=0x%llx fileoff=%llu filesize=%llu nsects=%u\n",
               seg->segname, (unsigned long long)seg->vmaddr, (unsigned long long)seg->vmsize,
               (unsigned long long)seg->fileoff, (unsigned long long)seg->filesize, seg->nsects);
        /* mi_wrap has already proved cmdsize covers the section array nsects
         * claims, which is what makes this walk in-bounds -- the same
         * guarantee me_target_lc (src/edit.c) relies on for the same walk.
         * sectname is 16 bytes and need not be NUL-terminated, so %.16s, not
         * %s. Printed for EVERY segment, not just __DATA_CONST: a query
         * answers what is there and the caller decides what it means. */
        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t k = 0; k < seg->nsects; k++)
            printf("    sectname=%.16s\n", sect[k].sectname);
    }
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: PASS. Watch `tests/bake_mavericks_shim_test.sh` and `tests/differential.sh` in particular — they read `info`'s output and must be unaffected.

- [ ] **Step 5: Commit**

```bash
git add cli/drydock-macho-rewrite.c tests/cli_test.sh
git commit -m "feat(info): print each segment's section names

target 10.9 detects __objc_ sections inside __DATA_CONST, and until now
nothing could ask the same question: info printed nsects but never a name.
Four-space indent, one level deeper than segname, so no existing consumer's
grep reaches the new lines.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `info` prints the Swift stable-ABI tag

**Files:**
- Modify: `cli/drydock-macho-rewrite.c` (includes, and `cmd_info` after the LC loop)
- Test: `tests/cli_test.sh`

**Interfaces:**
- Consumes: `int mswift_stable_tagged_image(const mi_image *im)` (`src/swift_retag.h:116`) — returns a **count** of tagged class records, so `> 0` means tagged; a negative value is an error.
- Produces: one flush-left `swift-abi: …` line per image, in all three states.

- [ ] **Step 1: Write the failing test**

`tests/wrapper_test.sh:2090` builds a Swift fixture (`$T/sw1`); this suite
needs its own. Add near the section-name block:

```sh
# ---- info: the Swift stable-ABI tag ---------------------------------------
# The last of target 10.9's five detections to become askable.
# mswift_stable_tagged_image was reachable only from me_expand_10_9, so this
# fact had no query at all. Printed in EVERY state, so absence is never
# ambiguous with "info forgot to look".
"$DRYDOCK_MACHO_REWRITE" info "$FIXTURE" 2>/dev/null | grep -q '^swift-abi: ' \
    && ok "info: a swift-abi line is always printed" \
    || bad "info swift-abi" "no swift-abi line on the plain fixture"

"$DRYDOCK_MACHO_REWRITE" info "$FIXTURE" 2>/dev/null \
    | grep -qxF 'swift-abi: no class records carry the stable-ABI tag' \
    && ok "info: an untagged image says so" \
    || bad "info swift-abi" "wrong wording: $("$DRYDOCK_MACHO_REWRITE" info "$FIXTURE" 2>/dev/null | grep '^swift-abi:')"

# The tagged half, on the retag's own fixture if this build has one. Skipped
# loudly rather than silently, the rule tests/change_dylib_test.sh's
# LC_LAZY_LOAD_DYLIB case sets.
if [ -f "$T/swift_fixture" ]; then
    "$DRYDOCK_MACHO_REWRITE" info "$T/swift_fixture" 2>/dev/null \
        | grep -qxF 'swift-abi: class records carry the stable-ABI tag' \
        && ok "info: a tagged image says so" \
        || bad "info swift-abi tagged" "wrong wording: $("$DRYDOCK_MACHO_REWRITE" info "$T/swift_fixture" 2>/dev/null | grep '^swift-abi:')"
    # And the line follows the statement: retag, then ask again.
    cp "$T/swift_fixture" "$T/swift_retagged"
    mts "$T/swift_retagged" "swift-abi set legacy" >/dev/null 2>&1
    "$DRYDOCK_MACHO_REWRITE" info "$T/swift_retagged" 2>/dev/null \
        | grep -qxF 'swift-abi: no class records carry the stable-ABI tag' \
        && ok "info: the tag is gone after swift-abi set legacy" \
        || bad "info swift-abi after retag" "still reports tagged records"
else
    echo "SKIP info swift-abi tagged: no stable-ABI Swift fixture in this build"
fi
```

If `$T/swift_fixture` does not exist in this suite, build it the same way
`tests/wrapper_test.sh:2090` builds `$T/sw1` — copy that construction verbatim
rather than inventing a second one.

- [ ] **Step 2: Run it to make sure it fails**

Run: `cmake --build build-native -j && DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/cli_test.sh 2>&1 | grep 'swift-abi'`

Expected: FAIL — no `swift-abi:` line exists in `info`'s output.

- [ ] **Step 3: Write the minimal implementation**

Add the include beside the others in `cli/drydock-macho-rewrite.c`:

```c
#include "swift_retag.h"
```

In `cmd_info`, after `mi_each_lc(&im, info_cb, &ctx);` and before the header-pad
block:

```c
    /* The fifth of target 10.9's detections, and the only one with no other
     * way to ask: mswift_stable_tagged_image (src/swift_retag.h) had exactly
     * one caller, me_expand_10_9. It returns a COUNT of tagged class records,
     * so >0 is "tagged"; a negative is the walk refusing the image, which is
     * said rather than rounded to "no". Flush left, beside `header pad:`,
     * because it describes the image and not a load command. */
    {
        int tagged = mswift_stable_tagged_image(&im);
        if (tagged < 0)
            printf("swift-abi: unknown (class records could not be walked)\n");
        else if (tagged > 0)
            printf("swift-abi: class records carry the stable-ABI tag\n");
        else
            printf("swift-abi: no class records carry the stable-ABI tag\n");
    }
```

Link `swift_retag` into the CLI target if CMake does not already — check
`CMakeLists.txt` for the library the CLI links; `drydock-macho-rewrite` already
reaches `mswift_retag_image` through `src/edit.c`, so no change is expected.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cli/drydock-macho-rewrite.c tests/cli_test.sh
git commit -m "feat(info): report the Swift stable-ABI tag

mswift_stable_tagged_image had one caller, me_expand_10_9, so the fact it
decides could not be asked. Printed in every state so that absence is never
ambiguous with info not having looked.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: `info` reads fat containers

**Files:**
- Modify: `cli/drydock-macho-rewrite.c:418-453` (`cmd_info` split into a per-image body and a dispatcher)
- Test: `tests/cli_test.sh`

**Interfaces:**
- Consumes: `int mfat_parse(const uint8_t *buf, size_t size, uint32_t *narch_out, int *swapped_out)`, `void mfat_get(const uint8_t *buf, int swapped, uint32_t idx, mfat_arch *out)` (`src/fat.h`); `int mi_wrap(uint8_t *buf, size_t size, mi_image *out)` (`src/image.h:78`); `void ma_describe(uint32_t cputype, uint32_t cpusubtype, char out[32])` (`src/arch_names.h:28`); `static int read_file(const char *verb, const char *path, uint8_t **out, size_t *outlen)` (`cli/drydock-macho-rewrite.c:587`).
- Produces: `static void info_image(mi_image *im, const char *label)`; flush-left `slice NAME: …` headers; `--thin`'s refusal becomes real.

- [ ] **Step 1: Write the failing test**

```sh
# ---- info: fat containers -------------------------------------------------
# info was a bare mi_open and failed outright on a fat container, which is
# why bake-mavericks-shim needs a trial rewrite to learn anything about one
# (compat/bake-mavericks-shim.sh's probe). One block per 64-bit slice now.
"$T/segread" wrap "$T/info_fat" "$T/segment_fixture" "$T/segment_fixture" 16777223

"$DRYDOCK_MACHO_REWRITE" info "$T/info_fat" >"$T/fat.out" 2>"$T/fat.err"
[ $? -eq 0 ] && ok "info: a fat container is read, not refused" \
    || bad "info fat" "exited nonzero: $(cat "$T/fat.err")"

[ "$(grep -c '^slice ' "$T/fat.out")" -eq 2 ] \
    && ok "info fat: one slice header per 64-bit slice" \
    || bad "info fat" "wanted 2 slice headers, got $(grep -c '^slice ' "$T/fat.out"): $(grep '^slice ' "$T/fat.out")"

# Each slice's body is the thin body. Compare slice 0's load commands with
# what info prints for that same slice standing alone.
"$T/segread" dump "$T/info_fat" 0 "$T/info_fat_s0"
"$DRYDOCK_MACHO_REWRITE" info "$T/info_fat_s0" 2>/dev/null | grep '^LC\[' >"$T/fat.thin.lc"
awk '/^slice /{n++} n==1' "$T/fat.out" | grep '^LC\[' >"$T/fat.s0.lc"
cmp -s "$T/fat.thin.lc" "$T/fat.s0.lc" \
    && ok "info fat: a slice's load commands match the same slice read alone" \
    || bad "info fat slice body" "$(diff "$T/fat.thin.lc" "$T/fat.s0.lc" | head -5)"

# Every detection, on a fat file. This is the whole point of the task.
grep -q '^    sectname=' "$T/fat.out" \
    && ok "info fat: section names are printed per slice" \
    || bad "info fat" "no sectname lines"
[ "$(grep -c '^swift-abi: ' "$T/fat.out")" -eq 2 ] \
    && ok "info fat: a swift-abi line per slice" \
    || bad "info fat" "wanted 2 swift-abi lines, got $(grep -c '^swift-abi: ' "$T/fat.out")"

# --thin's refusal is now real, not vacuous.
"$DRYDOCK_MACHO_REWRITE" info --thin "$T/info_fat" >/dev/null 2>"$T/fatthin.err"
[ $? -eq 1 ] && ok "info --thin: a fat container is refused (1)" \
    || bad "info --thin fat" "did not exit 1"
grep -qF 'not a readable 64-bit Mach-O' "$T/fatthin.err" \
    && ok "info --thin: the refusal keeps mi_open's wording" \
    || bad "info --thin fat" "wrong message: $(cat "$T/fatthin.err")"

# A non-Mach-O slice is named and passed over, in me_run_fat's words -- not a
# second vocabulary for the same fact.
"$T/segread" wrap "$T/info_fat32" "$T/segment_fixture" "$T/notmacho" 7
"$DRYDOCK_MACHO_REWRITE" info "$T/info_fat32" 2>/dev/null | grep -q '^slice .*: 32-bit; passed through unchanged$' \
    && ok "info fat: a 32-bit slice reuses me_run_fat's wording" \
    || bad "info fat 32-bit" "got: $("$DRYDOCK_MACHO_REWRITE" info "$T/info_fat32" 2>/dev/null | grep '^slice ')"

# A thin file's output is unchanged by all of this.
"$DRYDOCK_MACHO_REWRITE" info "$FIXTURE" 2>/dev/null | grep -qc '^slice ' \
    && bad "info thin" "a thin file grew a slice header" \
    || ok "info: a thin file still prints no slice header"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `cmake --build build-native -j && DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/cli_test.sh 2>&1 | grep 'info fat\|info --thin'`

Expected: FAIL — `info` on a fat container exits 1 with "not a readable 64-bit Mach-O".

- [ ] **Step 3: Write the implementation**

Split `cmd_info`. First the per-image body, which is today's function with the
open and close removed:

```c
/* One image's report: the same lines for a thin file and for each slice of a
 * fat container, so there is one description of what info says and not two.
 * `label` heads it -- the path for a thin file, `slice NAME` for a slice. */
static void info_image(mi_image *im, const char *label) {
    printf("%s: %zu bytes, %u load commands, filetype=%u\n",
           label, im->size, im->hdr->ncmds, im->hdr->filetype);
    struct info_ctx ctx = { 0, 0 };
    mi_each_lc(im, info_cb, &ctx);

    {
        int tagged = mswift_stable_tagged_image(im);
        if (tagged < 0)
            printf("swift-abi: unknown (class records could not be walked)\n");
        else if (tagged > 0)
            printf("swift-abi: class records carry the stable-ABI tag\n");
        else
            printf("swift-abi: no class records carry the stable-ABI tag\n");
    }

    uint32_t first_sect_off = mg_first_sect_off(im->buf, im->size);
    if (first_sect_off == MG_NO_SECTION_DATA) {
        printf("header pad: unknown (no section data bounds it)\n");
    } else if (first_sect_off != UINT32_MAX && first_sect_off > im->size) {
        printf("header pad: unknown (the first section lies past the end of the image)\n");
    } else if (first_sect_off != UINT32_MAX) {
        uint32_t lc_end = (uint32_t)sizeof(struct mach_header_64) + im->hdr->sizeofcmds;
        uint32_t pad = first_sect_off > lc_end ? first_sect_off - lc_end : 0;
        printf("header pad: %u bytes available (LC end=%u, first sect=%u)\n",
               pad, lc_end, first_sect_off);
    }
}
```

Then the dispatcher:

```c
static int cmd_info(const char *path, int thin_only) {
    mi_image im;
    int mo_rc = mi_open(path, &im);
    if (mo_rc == MI_IO_ERROR) {
        fprintf(stderr, "drydock-macho-rewrite info: %s: cannot open or read\n", path);
        return EX_FAIL;
    }
    if (mo_rc == 0) {
        info_image(&im, path);
        mi_close(&im);
        return 0;
    }

    /* Not a thin 64-bit Mach-O. With --thin that is the whole answer, and it
     * is mi_open's verdict verbatim -- the four wrappers that gate on this
     * reproduce their upstreams' refusal by its exit status alone
     * (compat/drydock-macho-rewrite-compat.sh's mw_thin_only). */
    if (thin_only) {
        fprintf(stderr, "drydock-macho-rewrite info: %s: not a readable 64-bit Mach-O\n", path);
        return EX_REFUSED;
    }

    {
        uint8_t *buf = NULL;
        size_t size = 0;
        uint32_t narch = 0, i;
        int swapped = 0, rrc;

        rrc = read_file("info", path, &buf, &size);
        if (rrc != 0) return rrc;

        if (mfat_parse(buf, size, &narch, &swapped) != 0) {
            free(buf);
            fprintf(stderr, "drydock-macho-rewrite info: %s: not a readable 64-bit Mach-O\n", path);
            return EX_REFUSED;
        }

        printf("%s: %zu bytes, %u slices\n", path, size, narch);
        for (i = 0; i < narch; i++) {
            mfat_arch a;
            mi_image sl;
            char name[32], label[64];
            mfat_get(buf, swapped, i, &a);
            ma_describe(a.cputype, a.cpusubtype, name);
            /* mfat_parse proved offset+size is in bounds, so this slicing
             * needs no further check of its own. */
            if (mi_wrap(buf + a.offset, a.size, &sl) != 0) {
                /* me_run_fat's two wordings, reused rather than reinvented --
                 * the fact is the same one, and a caller should not have to
                 * learn a second vocabulary for it (src/edit.c:797). */
                printf("slice %s: %s; passed through unchanged\n", name,
                       (a.cputype & 0x01000000u) ? "not a 64-bit Mach-O" : "32-bit");
                continue;
            }
            snprintf(label, sizeof label, "slice %s", name);
            info_image(&sl, label);
            mi_close(&sl);
        }
        free(buf);
        return 0;
    }
}
```

Add `#include "fat.h"` and `#include "arch_names.h"` if not already present.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: PASS — **including** Task 2's wrapper fat-gate assertions, which are the ones this change would have broken without `--thin`.

- [ ] **Step 5: Commit**

```bash
git add cli/drydock-macho-rewrite.c tests/cli_test.sh
git commit -m "feat(info): read fat containers, one block per 64-bit slice

Every detection target 10.9 makes is now askable on a fat container too,
which is the state the target decision has to be made against. A thin file's
output is unchanged; the four wrappers that gated on info failing here moved
to info --thin first, and their refusals are asserted.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: `insert_dylib`'s prompts start working on fat binaries

A consequence of Task 5, adopted rather than suppressed.

**Files:**
- Modify: `compat/README.md` (the adopted-divergences table)
- Test: `tests/wrapper_test.sh`

**Interfaces:**
- Consumes: fat `info` from Task 5.
- Produces: no code. One table row and one held-by test.

- [ ] **Step 1: Write the failing test**

```sh
# insert_dylib's two prompts read `drydock-macho-rewrite info`. While info
# failed on a fat container the output was empty and NEITHER prompt fired --
# a fat binary silently skipped both questions. They fire now, on the union
# across slices. Adopted, not suppressed: compat/README.md's table has the row.
fm_mkfat "$T/idfat" "$FIXTURE" 16777223 "$FIXTURE" 16777223
printf 'n\n' | "$BUILD/insert_dylib" --no-strip-codesig /usr/lib/libfoo.dylib "$T/idfat" "$T/idfat.out" \
    >"$T/id.out" 2>&1 || true
# The duplicate-dylib prompt: ask for a dylib the fixture already names.
id_have=$("$DRYDOCK_MACHO_REWRITE" info "$T/idfat" 2>/dev/null | sed -n 's/^  ordinal=[0-9]* path=//p' | head -1)
[ -n "$id_have" ] || bad "insert_dylib fat" "the fat fixture names no dylib; this proves nothing"
printf 'n\n' | "$BUILD/insert_dylib" --no-strip-codesig "$id_have" "$T/idfat" "$T/idfat.out2" \
    >"$T/id2.out" 2>&1 || true
grep -qF 'already contains a load command for that dylib' "$T/id2.out" \
    && ok "insert_dylib: the duplicate-dylib prompt now fires on a fat binary" \
    || bad "insert_dylib fat prompt" "prompt did not fire: $(cat "$T/id2.out")"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `git stash && cmake --build build-native -j && DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/wrapper_test.sh 2>&1 | grep 'insert_dylib fat'; git stash pop`

Expected: On the pre-Task-5 build the prompt does not fire. On the current build it does. If it already passes, that confirms Task 5 caused the change — record which.

- [ ] **Step 3: Add the divergence row**

In `compat/README.md`, add to the adopted-divergences table (or a new
`insert_dylib` subsection mirroring `fix_macho`'s):

```markdown
| 7 | **`insert_dylib`'s two prompts now fire on a FAT binary.** Both read `drydock-macho-rewrite info`; while `info` was a bare `mi_open` it failed outright on a fat container, the output was empty, and neither "LC_CODE_SIGNATURE load command found. Remove it?" nor "Binary already contains a load command for that dylib." was ever asked — a fat binary silently skipped both questions and the fork's own behaviour was not reproduced so much as accidentally bypassed. `info` reads fat containers now, so both questions are asked, over the union of the slices. Adopting it is right because the prompts exist to stop a caller doing something they did not mean, and a fat binary is where that matters most. | `tests/wrapper_test.sh`, "insert_dylib: the duplicate-dylib prompt now fires on a fat binary" |
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `ctest --test-dir build-native --output-on-failure`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add compat/README.md tests/wrapper_test.sh
git commit -m "docs(compat): adopt insert_dylib's prompts firing on fat binaries

A consequence of info reading fat containers, found by auditing info's
consumers rather than designed for. While info failed on a fat file both
prompts silently never fired. They fire now, and that is better, so it is
adopted with a held-by test instead of suppressed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: `fatal-warnings` out, `allow-unmatched` in

**Files:**
- Modify: `src/script.c:294` (the local), `:345-356` (the directive branch), `src/script.h:61` (the field and its comment at `:54`), `src/edit.c:280,318,407,630,653`
- Test: `tests/script_test.c`

**Interfaces:**
- Consumes: nothing.
- Produces: `ms_script.allow_unmatched` replacing `ms_script.fatal_warnings`. Directive `allow-unmatched`, no operands, refused after any operation. `fatal-warnings` becomes an unknown statement by ceasing to exist.

- [ ] **Step 1: Write the failing test**

In `tests/script_test.c`, beside `test_allow_grow_is_an_unknown_statement`:

```c
/* `fatal-warnings` was a directive; an unmatched operation refuses by default
 * now, and a script asking for the old behaviour is asking for nothing. It is
 * gone rather than accepted-and-ignored, and it is no more special than a
 * typo -- there is no branch for it to hit, so it falls through to the same
 * unknown-statement refusal `fatal-warnox` gets. */
static void test_fatal_warnings_is_an_unknown_statement(void) {
    ms_script s; char err[256] = {0};
    static const char gone[] = "fatal-warnings\n", never[] = "fatal-warnox\n";
    CHECK(ms_parse(gone, sizeof gone - 1, &s, err, sizeof err) == -1,
          "fatal-warnings is refused");
    CHECK(strstr(err, "unknown statement 'fatal-warnings'") != NULL,
          "and as an unknown statement (got: %s)", err);
    memset(err, 0, sizeof err);
    CHECK(ms_parse(never, sizeof never - 1, &s, err, sizeof err) == -1,
          "a typo is refused too");
    CHECK(strstr(err, "unknown statement 'fatal-warnox'") != NULL,
          "the same way (got: %s)", err);
}

/* The opt-in that replaces it, in the slot allow-grow vacated: a directive,
 * no operands, and refused after any operation. */
static void test_allow_unmatched_is_a_directive(void) {
    ms_script s; char err[256] = {0};
    static const char ok[] = "allow-unmatched\nload-command delete uuid\n";
    static const char late[] = "load-command delete uuid\nallow-unmatched\n";
    static const char operand[] = "allow-unmatched yes\n";

    CHECK(ms_parse(ok, sizeof ok - 1, &s, err, sizeof err) == 0,
          "allow-unmatched rejected: %s", err);
    CHECK(s.allow_unmatched == 1, "allow-unmatched did not set the field");
    CHECK(s.n == 1, "wanted 1 statement, got %d", s.n);
    ms_free(&s);

    memset(err, 0, sizeof err);
    CHECK(ms_parse(late, sizeof late - 1, &s, err, sizeof err) == -1,
          "allow-unmatched after an operation is refused");
    CHECK(strstr(err, "must precede every operation") != NULL,
          "and says why (got: %s)", err);

    memset(err, 0, sizeof err);
    CHECK(ms_parse(operand, sizeof operand - 1, &s, err, sizeof err) == -1,
          "allow-unmatched with an operand is refused");
    CHECK(strstr(err, "takes no operands") != NULL,
          "and says why (got: %s)", err);
}

/* The DEFAULT is the change. A bare script refuses an operation that matched
 * nothing; only allow-unmatched makes it a report. */
static void test_unmatched_refuses_by_default(void) {
    ms_script s; char err[256] = {0};
    static const char bare[] = "load-command delete uuid\n";
    CHECK(ms_parse(bare, sizeof bare - 1, &s, err, sizeof err) == 0,
          "bare script rejected: %s", err);
    CHECK(s.allow_unmatched == 0,
          "a script that said nothing must not allow unmatched operations");
    ms_free(&s);
}
```

Register all three in `main` beside `test_allow_grow_is_an_unknown_statement()`
at `tests/script_test.c:747`. Confirm `ms_free`'s exact name against the
existing tests in that file and use whatever they use.

Also update `tests/script_test.c:602`, which currently reads
`"fatal-warnings\ntarget 10.9\nload-command delete uuid\n"`, and `:645`'s
`"target 10.9\nfatal-warnings\n"` — both become `allow-unmatched`. The second
test asserts a directive after `target` is an error, which stays true.

- [ ] **Step 2: Run it to make sure it fails**

Run: `cmake --build build-native -j && ./build-native/script_test`

Expected: FAIL to **compile** — `s.allow_unmatched` is not a member. That is the correct first failure.

- [ ] **Step 3: Write the implementation**

`src/script.h:61` — rename the field and invert its meaning:

```c
    int      allow_unmatched;   /* set by the `allow-unmatched` directive */
```

Update the comment at `:54` to name `allow-unmatched`, `arch NAME` as the
directives.

`src/script.c:294` — rename the local:

```c
    int allow_unmatched = 0, seen_operation = 0, seen_target = 0;
```

`src/script.c:345-356` — the `fatal-warnings` branch is **deleted** and this
one takes its place. Nothing marks the old word: it falls through to the
`if (n < 2)` refusal at `:368` and is reported as `unknown statement
'fatal-warnings'`, which is what any unrecognised word gets.

```c
        if (strcmp(fields[0], "allow-unmatched") == 0) {
            if (n != 1)
                return ms_failf(stmts, text, out, err, errsz, lineno,
                    "directive '%s' takes no operands", fields[0]);
            if (seen_operation)
                return ms_failf(stmts, text, out, err, errsz, lineno,
                    "directive '%s' must precede every operation", fields[0]);
            allow_unmatched = 1;
            continue;
        }
```

`src/script.c:456`:

```c
    out->allow_unmatched = allow_unmatched;
```

`src/edit.c:280`:

```c
    ops.fatal_unmatched = !s->allow_unmatched;
```

`src/edit.c:318` and `:407`:

```c
        if (!s->allow_unmatched) { v->missed = 1; return MR_REFUSED; }
```

`src/edit.c:653`:

```c
        sub.allow_unmatched = 1;
```

and its comment at `:630` — "fatal_warnings is cleared in the script this runs
under" becomes "allow_unmatched is SET in the script this runs under", same
reasoning, inverted.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: `script_test` PASSES. **`cli_test.sh` and `wrapper_test.sh` will fail here** — every script that relied on the lenient default now refuses. That is the change working. Tasks 8–10 fix the callers; do not weaken this task to make them pass early. Record which assertions fail so Tasks 8–10 can be checked against the list.

- [ ] **Step 5: Commit**

```bash
git add src/script.c src/script.h src/edit.c tests/script_test.c
git commit -m "feat!: an unmatched operation refuses by default

fatal-warnings was opt-in only to preserve three wrappers' upstream exit 0,
which cost the tool's own interface its integrity. The default flips; the
wrappers ask for the old behaviour by name in the next commits.

fatal-warnings does not become a no-op or a migration message -- its branch
is deleted and nothing replaces it, so the word falls through to the same
unknown-statement refusal any typo gets. There are no users to migrate.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Three wrappers ask for `allow-unmatched`

**Files:**
- Modify: `compat/translate.sh:501` (`mt_tr_change_dylib`), `:615` (`mt_tr_fix_macho`), `:786-816` (`mt_tr_insert_dylib`)
- Test: `tests/wrapper_test.sh`, `tests/translate_test.sh`

**Interfaces:**
- Consumes: the `allow-unmatched` directive from Task 7.
- Produces: the directive as the first line of three emitted script bodies.

- [ ] **Step 1: Write the failing test**

The governing assertions already exist — `tests/wrapper_test.sh`'s "a run that
changed nothing prints no `Updated` line" (exit 0 on a `-change` that misses)
and the `fix_macho` equivalents. They fail as of Task 7 and must pass again.
Add the positive assertion that the directive is what does it:

```sh
# The three wrappers whose upstreams exited 0 when an operation matched
# nothing ask for that by name now. The other four emit only statements that
# cannot miss (fixups set / version-min set / swift-abi set), and
# rename_segment WANTS the refusal -- see its exit 2.
for au_tool in change_dylib fix_macho insert_dylib; do
    case $au_tool in
        change_dylib) set -- "$T/f" -change /nope/libx.dylib /also/nope.dylib ;;
        fix_macho)    set -- "$T/f" -change /nope/libx.dylib /also/nope.dylib ;;
        insert_dylib) set -- --strip-codesig /nope/libx.dylib "$T/f" "$T/f.out" ;;
    esac
    MT_OUT= "$BUILD/drydock-macho-rewrite-compat.sh" "$au_tool" "$@" 2>/dev/null \
        | grep -q "^allow-unmatched$" \
        && ok "$au_tool: the translation asks for allow-unmatched" \
        || bad "$au_tool allow-unmatched" "not in the emitted script"
done

# And the four that must NOT ask for it.
for na_tool in patch_macho add_version_min rename_segment retag_swift_classes; do
    case $na_tool in
        rename_segment) set -- "$T/f" __DATA __DATB ;;
        *)              set -- "$T/f" ;;
    esac
    MT_OUT= "$BUILD/drydock-macho-rewrite-compat.sh" "$na_tool" "$@" 2>/dev/null \
        | grep -q "^allow-unmatched$" \
        && bad "$na_tool allow-unmatched" "asked for lenience it does not need" \
        || ok "$na_tool: no allow-unmatched in the translation"
done
```

Check `tests/translate_test.sh` for the exact invocation form of the teaching
translator and match it; the form above is illustrative of the shape, not of
the argument spelling.

- [ ] **Step 2: Run it to make sure it fails**

Run: `DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/wrapper_test.sh 2>&1 | grep 'allow-unmatched'`

Expected: FAIL for the three; PASS for the four.

- [ ] **Step 3: Write the implementation**

`compat/translate.sh`, `mt_tr_change_dylib` at `:501` — the directive must
precede every operation, so it heads the body:

```sh
    mt_emit "$mt_file" "$(mt_out_for "$mt_file")" <<MT_CD_BODY
allow-unmatched
$mt_body
MT_CD_BODY
```

`mt_tr_fix_macho` at `:615`:

```sh
    mt_emit "$mt_file" "$(mt_out_for "$mt_file")" <<MT_FM_BODY
allow-unmatched
$mt_st_lc$mt_st_dychg$mt_st_seg
MT_FM_BODY
```

`mt_tr_insert_dylib` — both `mt_emit` call sites at `:806` and `:811`. Put it
at the head of `mt_body` where it is built at `:789`, so both sites get it
from one place:

```sh
    # --strip-codesig emits `load-command delete codesig`, which misses on a
    # binary carrying no signature; the fork exited 0 there. The other two
    # statements this builds cannot miss.
    mt_body="allow-unmatched
dylib append$(mt_qargs "$MT_ID_DYLIB")
"
```

Add a comment above each of the three explaining that the directive is what
preserves the upstream's exit 0, and naming `compat/README.md`'s section as
the authority — the same way the existing emission comments cite their
reasoning.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: The new assertions PASS, and every pre-existing "exits 0 on a miss" assertion recorded in Task 7's Step 4 passes again.

- [ ] **Step 5: Commit**

```bash
git add compat/translate.sh tests/wrapper_test.sh tests/translate_test.sh
git commit -m "fix(compat): three wrappers ask for allow-unmatched by name

change_dylib, fix_macho and insert_dylib have upstreams that exited 0 when an
operation matched nothing, and that is compat surface. They say so in the
script now instead of relying on a default. The other four emit only
statements that cannot miss, and rename_segment wants the refusal.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: `rename_segment` stops scraping stderr

The integrity win the flip was for.

**Files:**
- Modify: `compat/rename_segment.sh:227-244` and its header note at `:47`, `:80`, `:160`
- Test: `tests/wrapper_test.sh`

**Interfaces:**
- Consumes: the default from Task 7 — `segment rename` matching nothing is now `EX_REFUSED` (1) with nothing written.
- Produces: no new names; the wrapper's exit 2 comes from an exit code, not a message.

- [ ] **Step 1: Write the failing test**

```sh
# rename_segment's "nothing matched" is exit 2 with FILE untouched, which is
# the old tool's. It used to be recovered by grepping stderr for the exact
# words "drydock-macho-rewrite: segment X matched nothing" -- a wrapper
# depending on the WORDING of a human-readable line. The exit code carries it
# now, so the verdict survives a rephrasing.
cp "$FIXTURE" "$T/rs_nomatch"
"$BUILD/rename_segment" "$T/rs_nomatch" __NOSUCHSEG __OTHER >/dev/null 2>"$T/rs.err"
[ $? -eq 2 ] && ok "rename_segment: zero renames is still exit 2" \
    || bad "rename_segment nomatch" "did not exit 2"
cmp -s "$FIXTURE" "$T/rs_nomatch" \
    && ok "rename_segment: and the input is untouched" \
    || bad "rename_segment nomatch" "the input changed"

# The verdict must not come from the message any more.
grep -q 'matched nothing' compat/rename_segment.sh \
    && bad "rename_segment coupling" "still greps for the 'matched nothing' wording" \
    || ok "rename_segment: no longer depends on stderr wording"

# A real rename still works and still exits 0.
cp "$T/segment_fixture" "$T/rs_hit"
rs_seg=$("$T/segread" segs "$T/rs_hit" | sed -n 's/^SEG //p' | head -1)
"$BUILD/rename_segment" "$T/rs_hit" "$rs_seg" __RENAMED >/dev/null 2>&1
[ $? -eq 0 ] && ok "rename_segment: a real rename still exits 0" \
    || bad "rename_segment hit" "a matching rename did not exit 0"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/wrapper_test.sh 2>&1 | grep rename_segment`

Expected: The coupling assertion FAILS (the grep is still in the file).

- [ ] **Step 3: Write the implementation**

Replace `compat/rename_segment.sh:227-244`. The `mw_n`-plus-stderr-grep logic
collapses to reading the run's exit code:

```sh
# NOTHING MATCHED: the old grammar's exit 2, and nothing is installed.
# An unmatched `segment rename` is a refusal now (EX_REFUSED), so the verdict
# arrives as a number. This used to be recovered by grepping stderr for
# drydock-macho-rewrite's exact "segment X matched nothing" wording, which made
# this wrapper depend on how a human-readable line was phrased; the flip to
# unmatched-is-fatal is what let that go.
if [ "$mw_rs_rc" -eq 1 ]; then
    exit 2
fi
```

Bind `mw_rs_rc` from the `mw_retranslate` call that runs the script. Read the
surrounding code and keep `EX_FAIL` (2 from the tool, an operational failure)
distinguishable from `EX_REFUSED` (1) — they must not both become the
wrapper's exit 2 by accident, since the tool's own 2 has a different meaning
here. Preserve whatever the existing code does for the tool's 2.

Delete the "Zero renames AND no 'matched nothing' verdict" fallback at
`:227-232` — it existed because the wrapper could not tell the two apart, and
now it can. Update the header notes at `:47`, `:80` and `:160` to describe the
exit-code verdict.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: PASS, including `tests/differential.sh`'s `rename_segment` rows.

- [ ] **Step 5: Commit**

```bash
git add compat/rename_segment.sh tests/wrapper_test.sh
git commit -m "refactor(compat): rename_segment reads an exit code, not a message

Its zero-renames verdict was recovered by grepping stderr for the exact words
'segment X matched nothing'. An unmatched operation refuses now, so the
number carries it and the verdict survives a rephrasing. This coupling is
what the default flip was for.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: `bake-mavericks-shim`'s probe drops its directive

**Files:**
- Modify: `compat/bake-mavericks-shim.sh:95-103`
- Test: `tests/bake_mavericks_shim_test.sh`

**Interfaces:**
- Consumes: the default from Task 7.
- Produces: `bk_matches FILE STATEMENT` unchanged in contract — exit 0 when the statement matched.

- [ ] **Step 1: Write the failing test**

The suite's existing assertions cover `bk_matches`' behaviour. Add the
coupling guard:

```sh
# The probe runs one statement and reads whether it matched. That is the
# default now, so the directive line is gone -- the probe asks the tool's
# plain question rather than configuring it first.
grep -q 'fatal-warnings' compat/bake-mavericks-shim.sh \
    && bad "bake-mavericks-shim probe" "still prepends the removed fatal-warnings directive" \
    || ok "bake-mavericks-shim: the probe needs no directive"
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `DRYDOCK_MACHO_REWRITE=build-native/drydock-macho-rewrite sh tests/bake_mavericks_shim_test.sh 2>&1 | grep probe`

Expected: FAIL — the word is still in the file. The script would also break at runtime, since `fatal-warnings` is now an unknown statement and every probe would return the parse failure rather than a match verdict.

- [ ] **Step 3: Write the implementation**

```sh
# spec: compat/README.md "bake-mavericks-shim" -- is there a signature, is the
# shim loaded: no query answers either across a fat file's slices, so a trial
# run does, by whether its one statement matched. An unmatched operation
# refuses by default, so the exit code is the answer with nothing to ask for.
bk_matches() {
    printf '%s\n' "$2" | drydock-macho-rewrite "$1" "$MW_T/probe" >/dev/null 2>&1
    bk_m=$?
    rm -f "$MW_T/probe"
    return "$bk_m"
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `cmake --build build-native -j && ctest --test-dir build-native --output-on-failure`

Expected: PASS — the full suite, since this is the last caller change.

- [ ] **Step 5: Commit**

```bash
git add compat/bake-mavericks-shim.sh tests/bake_mavericks_shim_test.sh
git commit -m "refactor(compat): the shim probe asks the plain question

It prepended fatal-warnings to make one statement's miss a nonzero exit.
That is the default, so the directive goes and the probe reads the exit code
of the statement itself.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: README

**Files:**
- Modify: `README.md` — the Statements block (~line 50), the Directives block (~line 83), the `fatal-warnings` paragraphs (~line 88-98), the `target` section (~line 100-175), a new query section, Limitations (~line 178)
- Test: none; prose.

**Interfaces:**
- Consumes: everything above.
- Produces: the file the user edits next.

- [ ] **Step 1: Delete the three XXX markers and answer them in the text**

They are at `README.md:98`, `:102` and `:104`. Each is answered by a change
above, and none survives as a marker.

- [ ] **Step 2: Add `target` to the Statements block**

It is missing today, which makes the grammar block not the grammar. The tool
calls it a statement — row 16 of `MS_TABLE_ROWS` (`src/script.c:130`), and
`--capabilities` prints `statement target 10.9 0`. Add, after `import redirect`:

```
target        10.9                  the one statement whose meaning depends on
                                    the binary; see "The `target` statement"
```

- [ ] **Step 3: Replace the Directives block and the `fatal-warnings` prose**

```
arch NAME           apply the script only to the slice named NAME (lipo's
                    names: x86_64, x86_64h, arm64, arm64e, i386); repeatable.
                    Without it, every 64-bit slice of a fat file is edited
allow-unmatched     an operation that matched nothing is reported and the run
                    continues, instead of refusing the whole run
```

Rewrite the paragraphs that followed. An operation that matched nothing now
refuses the run — exit 1, nothing written — and the list of statements that
*can* match nothing stays as it is, since it is still the useful fact:
`load-command delete`, `dylib replace/delete/reexport`, `rpath
replace/delete`, `segment rename`, `import redirect`. Say which statements
cannot miss, because that is what makes a hand-written 10.9 script safe:
`fixups set`, `version-min set` and `swift-abi set` are no-ops rather than
misses. Keep the fat-file sentence.

Name who asks for `allow-unmatched` and why: `change_dylib`, `fix_macho` and
`insert_dylib` reproduce upstreams that exited 0 on a miss, and
`compat/README.md` holds that record.

- [ ] **Step 4: Document the queries**

`README.md` documents `drydock-macho-rewrite` and its wrappers but never the
query verbs. Add a short section covering `verify`, `info [--thin]`, `imports`
and `exports`, with an `info` sample showing a `sectname=` line, a `swift-abi:`
line and a `slice` header — and say that `info` answers each of `target 10.9`'s
five detections, since that is the section's reason to exist.

- [ ] **Step 5: Retune the `target` section and update Limitations**

Keep the feature and its table. Drop the "it is the intent level" framing one
notch: state plainly that every statement it derives is safe to write by hand,
that what it adds is the report and the ordering, and that a second profile is
what would prove the design — there is one today, and an unknown target is
refused (`src/script.c:378`). Keep the position-matters argument, which is
unchanged and correct.

In Limitations, `info` no longer refuses fat containers; check whether the two
bullets (32-bit input, `fat_arch_64`) still read correctly for the rewriting
form and leave them if so.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: answer the three XXX markers in the text

target joins the Statements block it was missing from; fatal-warnings becomes
allow-unmatched with the default inverted; the query verbs get a section, and
info's sample shows the lines that make each of target's five detections
askable.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: The `target` decision

Deliberately last, and deliberately not pre-decided. Do not start it until
Tasks 1–11 are committed and the suite is green.

**Files:** none yet. The output of Step 1 is a recommendation.

- [ ] **Step 1: Measure**

With `info` answering all five detections on thin files and fat containers,
write the hand-equivalent script and compare:

```sh
printf 'fixups set classic\nload-command delete build-version\nversion-min set 10.9\nsegment rename __DATA_CONST __DATA\nswift-abi set legacy\n' \
    | build-native/drydock-macho-rewrite BIN out.hand
printf 'allow-unmatched\ntarget 10.9\n' \
    | build-native/drydock-macho-rewrite BIN out.target
cmp out.hand out.target
```

Note that the hand form needs `allow-unmatched` — `load-command delete
build-version` and `segment rename __DATA_CONST __DATA` are the two of the
five that can miss. That cost is part of what is being weighed.

Run it over several real binaries, chained and not, Swift and not, thin and
fat.

- [ ] **Step 2: Report and ask**

Report to the user: whether the bytes match in every case, what `target`'s
report says that `info` does not, and a recommendation on keeping, keeping
with narrower documentation, or removing. Do not implement a removal without
their answer.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 `info` sections, Swift tag, fat containers | 3, 4, 5 |
| §1 thin output byte-identical | Global constraint; asserted in 1, 5 |
| §1 slice header flush left, `me_run_fat` wording reused | 5 |
| §2 `info --thin`, four wrappers migrate | 1, 2 |
| §2 `--capabilities` advertises the flag | 1 |
| §2 gate intercepts 1, passes 2 through | 2 |
| §3 `insert_dylib` divergence adopted + held by | 6 |
| §4 `fatal-warnings` deleted, no special case | 7 |
| §4 `allow-unmatched` in the vacated slot | 7 |
| §4 three wrappers emit it; four do not | 8 |
| §4 `rename_segment` drops the stderr grep | 9 |
| §4 `bake-mavericks-shim` probe simplifies | 10 |
| §4 `me_target` sets rather than clears | 7 |
| §4 test mirrors `test_allow_grow_is_an_unknown_statement` | 7 |
| §5 `target` decided against working code | 12 |
| §6 README revision, then the user | 11 |
| Testing table, all 14 rows | 1–10 |

No gaps.

**Placeholder scan:** Task 9 Step 3 says "bind `mw_rs_rc` from the
`mw_retranslate` call" without quoting the surrounding lines, because the
variable that holds the run's status has to be read from the file at
implementation time — the current code path discards it. That is a
read-then-write instruction, not a TODO, and the assertions in Step 1 pin the
outcome. Task 8 Step 1 flags that the translator's invocation spelling must be
matched against `tests/translate_test.sh` rather than guessed. Task 4 Step 1
names `tests/wrapper_test.sh:2090` as the construction to copy for the Swift
fixture. No other step defers work.

**Type consistency:** `cmd_info(const char *path, int thin_only)` is introduced
in Task 1 and used with that signature in Tasks 4 and 5. `info_image(mi_image
*im, const char *label)` is introduced in Task 5 only. `ms_script.allow_unmatched`
is introduced in Task 7 and referenced nowhere earlier. `mr_ops.fatal_unmatched`
keeps its existing name and is set from `!s->allow_unmatched`. The capability
string `verb info flags=--thin` is identical in Task 1's implementation and its
test.
