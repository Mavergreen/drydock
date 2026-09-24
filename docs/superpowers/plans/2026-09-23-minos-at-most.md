# `minos at-most` and `minos if-absent` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `version-min set 10.9` and `minos set VERSION` with `minos at-most VERSION` and `minos if-absent VERSION`, each leaving every slice with exactly one `LC_VERSION_MIN_MACOSX`; make `fixups set classic` keep a macOS `LC_BUILD_VERSION` as that command; make `swift-abi set legacy` refuse a chained image; publish `target 10.9` as the edit script it expands to, detected step by step; and commit `edit-scripts/claude-code.edits`, one edit script that turns the binary Anthropic ships into the Claude Code install.sh's wrappers produce today.

**Architecture:** One new in-memory core, `mv_declare_minos` (src/version_min.c), reads a slice's declaration, decides the minimum by rule, and writes one `LC_VERSION_MIN_MACOSX`, removing every `LC_BUILD_VERSION`. `md_declassify_buf` writes the kept command directly before the `LC_DYLD_INFO_ONLY` it appends, so either order of `fixups` and `minos` gives the same bytes. `target 10.9` becomes four steps, each detected on the image the previous steps left. The hidden sdk channel, `minos set`, `version-min set`, and `mv_add_version_min[_image]` are deleted. Two committed edit scripts in `edit-scripts/` do install.sh's whole Claude Code patch in one run.

**Tech Stack:** C99, CMake + CTest via shipyard, POSIX `/bin/sh` suites (`tests/cli_test.sh`, `tests/wrapper_test.sh`, `tests/translate_test.sh`, `tests/known-callers.sh`), C test binaries (`tests/script_test.c`, `tests/edit_test.c`), fixture builders compiled by the suites (`tests/mkminos.c`, `tests/mkchained.c`).

**Spec:** `docs/superpowers/specs/2026-09-23-minos-at-most-design.md` (binding). Facts behind it: `docs/minimum-os-version.md`.

## Global Constraints

- **Tests before code, mutation-proven.** Write each test first and watch it fail. After it passes, apply each mutation the task names, one at a time: rebuild, confirm the rebuild happened (next bullet), watch the named test fail, restore, rebuild, confirm again, watch it pass. Commit only restored code.
- **This host's clock is skewed, so a build can silently not rebuild.** Confirm every rebuild by hash, using the sequence below. If a binary whose source you touched is on the `OK` list, or a wrapper prints `STALE`, `touch` its source and build again. Never read a result off a stale binary, least of all during a mutation.
- **Build:** `/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j`
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native` (22 tests; `chained_fixups` skips on this host). One suite: add `-R '^cli_test$' --output-on-failure` (or `edit_test`, `script_test`, `wrapper_test`, `translate_test`, `known_callers`).
- **Exit codes:** `EX_REFUSED` / `MR_REFUSED` = 1, `EX_FAIL` / `MR_FAIL` = 2.
- **Comments are a last resort.** Explanation goes, in this order of preference, into a test, the commit message, a doc, and only then ONE inline sentence a reader needs at that line. No history narration. No plan, task or spec references in source. No "keep in sync with" lists.
- **Shell assertions:** capture a status with `rc=0; cmd || rc=$?`, never a bare command that can exit nonzero (`cli_test.sh` runs under `set -eu`). Every grep-based negative is paired with a positive control, so a missing report cannot make it pass.
- **Staging:** name every path in `git add`. Never `git add -A` or `git add .`.
- **Before Task 1:** run `git status --short`. It should show only `?? .superpowers/` and `?? READMES-OWED.md`. If any file this plan touches shows as modified, that is someone else's work: stop and ask the owner.
- **README.md is being edited by hand by the owner.** Task 6 touches only its named passages and stops if `git diff HEAD -- README.md` prints anything.
- **Never push.**
- **Commit trailer**, exactly:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
  ```
- **Report arrows are ASCII `->`.** Versions print as `mv_format_version` does: `MAJOR.MINOR`, plus `.PATCH` when nonzero.
- **Segment and section names are `char[16]`:** print with `%.16s`, compare with `strncmp(..., 16)`.

The build-and-check sequence every "run" step means, written out once:

```sh
cd /Users/schmonz/Documents/code/trees/mavergreen-drydock
B=/private/tmp/build/schmonz/drydock-native
H="${TMPDIR:-/tmp}/drydock.sha"
shasum -a 256 "$B/drydock-macho-rewrite" "$B/edit_test" "$B/script_test" >"$H"
/usr/local/bin/shipyard-cmake --build "$B" -j
shasum -a 256 -c "$H" 2>/dev/null | grep ': OK$' || true
# Every binary whose source you touched must be ABSENT from that OK list.
for w in add_version_min retag_swift_classes patch_macho; do
    cmp -s "compat/$w.sh" "$B/$w" || echo "STALE $w"
done
cmp -s compat/translate.sh "$B/drydock-macho-rewrite-translate.sh" || echo "STALE translate"
# Nothing may print STALE.
```

The test suites compile `tests/mkminos.c`, `tests/mkchained.c` and `tests/mkswift.c` themselves on every run, so those need no hash check.

---

## Decisions this plan makes that the spec left open

1. **Task order is swift-abi, core, fixups+target, wrapper, Claude Code edit scripts, README.** `fixups set classic` keeping a `LC_VERSION_MIN_MACOSX` 12.0 breaks today's `target` (its derived `version-min set` sees one present and leaves 12.0), and `target`'s new expansion without the kept command loses the sdk. So those two land together (Task 3). `version-min set` is what the wrapper emits, so it goes with the wrapper's new translation (Task 4). The statement count is therefore 20 after Task 2, 19 after Task 3 and 18 after Task 4, each pinned by that task's tests.
2. **VERSION's precision comes from `ms_parse_version`**, which gains a `uint32_t *mask` out-parameter (NULL allowed): `0xFFFF0000`, `0xFFFFFF00` or `0xFFFFFFFF` for one, two or three parts. "Above" is `(D & mask) > VERSION`.
3. **The new core is `mv_declare_minos`, with its own report type `mv_decl_report`.** It does its own append, through `mg_ensure_pad`, with the same "no room for LC_VERSION_MIN_MACOSX" refusal that `tests/leaf-tool-crashes.sh` greps. `mv_add_version_min_image` loses its sdk parameter in Task 3, as the spec says, and is deleted in Task 4 together with `mv_add_version_min`, which already has no caller.
4. **Report lines are indented six spaces**, like every other statement's follow-up (`me_log_*`). The spec's example indentation is schematic.
5. **"at or below VERSION" echoes VERSION as written**, so `minos at-most 10` reports "at or below 10", not "10.0".
6. **Under `if-absent`, an `LC_BUILD_VERSION` above VERSION reads `build-version D -> version-min D; sdk S carried over`.** The spec's "kept (declared)" shape names a version-min; a build-version is still converted.
7. **A slice with a non-macOS, non-Mac-Catalyst `LC_BUILD_VERSION` beside a macOS declaration is refused**, "declares platform N beside macOS; refusing rather than guess which it is". The spec refuses a slice with only non-macOS commands and is silent on this mix. Refuse, don't guess.
8. **A macOS `LC_BUILD_VERSION` removed beside a `LC_VERSION_MIN_MACOSX` is reported** with `; build-version D removed`. The spec names only the Mac Catalyst suffix, but the report must not hide a removal.
9. **`fixups set classic` refuses two macOS `LC_BUILD_VERSION`s**, as `minos` does, rather than choose whose values to keep. It adds no stdout line; the kept command is reported on the statement's report line only, so `patch_macho`'s stdout is unchanged. The kept command needs 16 more bytes of header pad, so a chained image with under 8 bytes of pad (with an exports trie) now refuses where it converted. The smallest pad measured in the spike was 8.
10. **`mswift_*` signals a chained image with a new code, `MSWIFT_CHAINED` (-3)**, returned by the shared walk before it reads anything, so every caller gets it. `mswift_retag_file` returns it without writing `out`.
11. **`target`'s derived `minos` line reads `minos at-most 10.9  (always)`.** "Nothing to do" is printed after the last step, when no step changed the image. `me_verdict` gains `int changed`, which the `minos` lowering writes.
12. **The `add_version_min` wrapper prints "LC_VERSION_MIN_MACOSX already present; nothing to do." itself**, when the run changed no byte (`MW_CHANGED` is 0). After `minos if-absent 10.9`, that happens exactly when the input held one `LC_VERSION_MIN_MACOSX` and no `LC_BUILD_VERSION`. The core stays silent on stdout, so `target` runs print nothing new there.
13. **`compat/retag_swift_classes.sh` is not changed.** Its exit-1 arm is a silent skip, so a chained Swift binary now gives exit 0, `total: 0` and an untouched file, which is exactly what the C tool gave (it read the chain links as addresses and found nothing). Task 1 pins that.
14. **`patch_macho` inherits the kept declaration**, because it is `fixups set classic`, and the real sdk is carried everywhere, the install.sh pipeline included; nothing special-cases the wrapper path. The owner ruled this, and `docs/minimum-os-version.md` ("Every sdk check in 10.9.5's own code") measured it: on 10.9 every sdk ≥ 10.9 behaves identically. The new row in `compat/README.md`'s `patch_macho` table records the byte difference and cites that section. Nothing in this plan exists to keep sdk 10.9: the hand-written `version-min set` sdk-10.9 assertion is dropped in Task 3.
15. **The published-edit-script test keeps the edit script as a literal in `tests/cli_test.sh`** and does not parse README.md, which the owner edits by hand. Task 6 checks the README lines against that literal with `git grep`. The thin fixture is a chained Swift image in `__DATA_CONST`, so all four lines apply; the fat one adds a plain chained slice, where `segment rename` and `swift-abi` are no-ops.
16. **Fixtures come from committed sources.** `tests/mkchained.c` gains `make-swift` (Task 1), `make-swiftdc` and `make-tight` (Task 3), and a `tags` reader (Task 1). `tests/mkminos.c` gains `add-bv` (Task 2). Nothing reads the scratchpad.
17. **The Claude Code edit script is two files**, because an edit script has no conditionals: `edit-scripts/claude-code.edits` (a CPU with AVX2) and `edit-scripts/claude-code-no-avx2.edits` (the variant that links the AVX emulator). Each is the spec's list, in its order, with the nine `dylib replace` pairs `/usr/local/bin/claude` passes to `change_dylib`, in that wrapper's order. Old == new pairs are kept: they are harmless, as the wrapper says, and a probe confirmed a same-path `dylib replace` exits 0.
18. **The no-AVX2 variant spells the wrapper's `$MF`/`$MFL` paths relative to the binary:** `@loader_path/../../claude-mavericks/…` and `@loader_path/../../claude-mavericks-local/libavxemu.dylib`. A committed script cannot expand `$HOME`. The binary lives at `~/.local/share/claude/versions/<ver>`, so these name the same files dyld would find. The AVX2 variant's three migration pairs (old = `$MF/…`) use the same spelling, so a binary built by either edit script converges on the other. Matching the wrapper's literal absolute spellings is install.sh's concern, which the spec leaves to the owner. The owner should know this spelling differs from today's absolute one.
19. **The edit scripts' ctest check runs each file for real, not a parse-only mode:** the CLI has no `--dry-run`. `build_main`'s fixture links `/usr/lib/libSystem.B.dylib`, so one `dylib replace` really matches; `allow-unmatched` covers the rest, and `fixups set classic` passes an already-classic image through.
20. **The check against the real Claude Code binary is done once, by hand, before Drydock's first release** ("One-time check before Drydock's first release", after Task 6). It is not a ctest, a merge gate or a recurring release step. It runs the new binary from a sibling directory of `versions/`, so the `@loader_path/../` names resolve exactly as in `versions/`, and Claude Code's version housekeeping cannot reap it.

## For the item-6 comment sweep's held Tasks 7 and 8

Both held tasks start with `git diff --quiet d1cab99 -- FILE || echo CHANGED-STOP` and density counts. After this plan:

- **Task 7 (`compat/add_version_min.sh`) will hit CHANGED-STOP.** Task 4 here edits that file's header (the statement name on line 3, and the WHAT THIS REPLACED/GRAMMAR, EXIT CODES, STDOUT and STDERR paragraphs, and the THIN ONLY comment, none of which may keep naming the deleted `mv_add_version_min`) and adds one code line after `mw_finish || exit 1`. Its `rr` line ranges and density expectations must be re-measured, and its replacement header must name `minos if-absent 10.9`, not `version-min set 10.9`.
- **Task 7's new README section already exists.** Task 4 here creates `## \`add_version_min\`: the differences, and what holds each one` directly above `## \`rename_segment\`: exit codes`, where Task 7 planned to put it. Task 7 must merge its rows into that section, not add a second one. Three of its planned rows are now wrong: the statement no longer calls `mv_add_version_min` (deleted); the stderr announcement is `none -> version-min 10.9; sdk 10.9 written`, not `appended LC_VERSION_MIN_MACOSX 10.9`; and the "already present" line is printed by the wrapper (the new code line), not by the core.
- **Task 7's comment edits cite `mv_add_version_min`**, which Task 4 deletes. The wrapper-test label "add_version_min: a fat container is refused, untouched, as mv_add_version_min's own mi_open did" keeps the old name so that `compat/README.md`'s "Thin only" table still matches it.
- **Task 8 (`compat/retag_swift_classes.sh`)** is not edited here, so its CHANGED-STOP check passes. But its `1)` arm, commented `MSWIFT_NOT_MACHO: the benign skip`, now also receives `swift-abi set legacy`'s refusal of a chained image. The observable result still matches the C tool, and Task 1 pins it as "retag_swift_classes: a chained Swift binary is the C tool's silent zero, untouched". Task 8's README row "exits 1 (`EX_REFUSED`: not a Mach-O) … skips it silently" must name that case and cite that test.
- **If item-6 Task 9 (`compat/translate.sh`) is still pending:** Task 4 here changes `mt_tr_add_version_min`'s comment and emitted statement.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `src/swift_retag.h`, `src/swift_retag.c` | `MSWIFT_CHAINED`: the walk refuses a chained image | 1 |
| `cli/drydock-macho-rewrite.c` | `info`'s `swift-abi: unknown (…)` line | 1 |
| `src/script.h`, `src/script.c` | the `minos at-most`/`if-absent` rows and ops; `ms_parse_version`'s mask; removing `minos set`, `version-min set` and `ms_stmt.sdk` | 2, 3, 4 |
| `src/version_min.h`, `src/version_min.c` | `mv_declare_minos` and `mv_decl_report`; deleting `mv_set_minos`, then `mv_add_version_min[_image]` | 2, 3, 4 |
| `src/declassify.h`, `src/declassify.c` | keeping a macOS `LC_BUILD_VERSION` as `LC_VERSION_MIN_MACOSX` before `LC_DYLD_INFO_ONLY` | 3 |
| `src/edit.h`, `src/edit.c` | lowering; `me_log_declared`; the fixups report; `target` as four detected steps | 1, 2, 3, 4 |
| `src/rewrite.c` | one comment naming a deleted function | 4 |
| `compat/translate.sh`, `compat/add_version_min.sh`, `compat/README.md` | the wrapper's translation, its "already present" line, the divergence rows | 3, 4 |
| `tests/mkchained.c` | `make-swift`, `make-swiftdc`, `make-tight`, `tags` | 1, 3 |
| `tests/mkminos.c` | `add-bv` | 2 |
| `tests/script_test.c`, `tests/edit_test.c`, `tests/cli_test.sh`, `tests/wrapper_test.sh`, `tests/translate_test.sh`, `tests/known-callers.sh`, `tests/README.md`, `tests/strip_version_min.c` | tests and their prose | 1-5 |
| `edit-scripts/claude-code.edits`, `edit-scripts/claude-code-no-avx2.edits` | the Claude Code edit scripts | 5 |
| `README.md` | the user-facing grammar, decision table, target's edit script | 6 |

---

### Task 1: `swift-abi set legacy` refuses a chained image, and `info` says unknown

**Files:**
- Modify: `src/swift_retag.h` (the `MSWIFT_*` block, lines 55-63; the return sentences of `mswift_retag_file`, `mswift_retag_image`, `mswift_stable_tagged_image`)
- Modify: `src/swift_retag.c` (`mswift_walk`, lines 144-179; `mswift_retag_file`, lines 228-235)
- Modify: `src/edit.c` (`case MS_SWIFT_ABI`, lines 398-411)
- Modify: `cli/drydock-macho-rewrite.c` (`info_image`, lines 373-376)
- Modify: `tests/mkchained.c` (header comment, the mode enum, `make`, a new `tags`, `main`)
- Test: `tests/cli_test.sh` (directly after the line `    || bad "info swift-abi after retag" "still reports tagged records"`)
- Test: `tests/wrapper_test.sh` (directly after the `|| bad "retag_swift_classes fat" …` line that closes the fat-container retag assertion)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `#define MSWIFT_CHAINED (-3)` in `src/swift_retag.h`. `mswift_retag_image`, `mswift_stable_tagged_image` and `mswift_retag_file` return it for any image carrying `LC_DYLD_CHAINED_FIXUPS`, having changed and written nothing.
  - The refusal line `drydock-macho-rewrite edit: PATH: the class records' pointers are chained; write \`fixups set classic\` before \`swift-abi set legacy\``, exit 1.
  - The `info` line `swift-abi: unknown (pointers are chained; fixups set classic first)`.
  - `mkchained make-swift OUT`: `mkchained make`'s image with a `__DATA` holding `__objc_classlist` (one class) and `__objc_data` (the class and its metaclass), both data words tagged stable-ABI (low bits 2), all five pointers chained rebases.
  - `mkchained tags FILE`: prints `class N` and `meta N`, the low two bits of those two data words.

- [ ] **Step 1: Give `mkchained` a chained Swift image and a tag reader**

In `tests/mkchained.c`:

Append to the header comment, directly after the `make-lcfirst` paragraph (before ` */`):

```c
 *
 * make-swift differs in __DATA: an __objc_classlist naming one class whose isa
 * is its metaclass, both data words carrying the stable-ABI Swift tag (low
 * bits 2), and all five of those pointers chained rebases.
 *
 * mkchained tags FILE -- print "class N" and "meta N": the low two bits of the
 * two data words make-swift lays out, raw, so it reads a chained or a
 * converted image alike.
```

Change the usage summary line near the top to:

```c
 * mkchained make|make-weak|make-big|make-nosect|make-sectpast|make-badord|make-high8|make-lcfirst|make-swift OUT
```

After `#define SYMNAME          "_mkchained_sym"`, add:

```c
#define SW_CLASS 0x100   /* DATA_OFF-relative: the class record (+0 isa, +32 data) */
#define SW_META  0x140   /* ... its metaclass */
#define SW_RO    0x200   /* ... the class's read-only data; the metaclass's is +0x40 */
```

Change the enum to:

```c
enum { MK_PLAIN, MK_WEAK, MK_BIG, MK_NOSECT, MK_SECTPAST, MK_BADORD, MK_HIGH8, MK_LCFIRST,
       MK_SWIFT };
```

Before `static int make(`, add:

```c
/* One DYLD_CHAINED_PTR_64_OFFSET rebase at DATA_OFF + off: `target` is
 * base-relative, `next` the byte distance to the next link, 0 at the end. */
static void sw_link(uint8_t *buf, uint32_t off, uint64_t target, uint32_t next) {
    *(uint64_t *)(buf + DATA_OFF + off) = target | ((uint64_t)(next / 4) << 51);
}
```

In `make`, replace

```c
    struct segment_command_64 *data = put_seg(p, "__DATA", TEXT_VMADDR + DATA_OFF, data_size,
                                              DATA_OFF, data_size, 1);
    put_sect(data, 0, "__data", "__DATA", TEXT_VMADDR + DATA_OFF, data_size,
             (mode == MK_NOSECT || mode == MK_SECTPAST) ? 0 : DATA_OFF);
    p += data->cmdsize;
```

with

```c
    struct segment_command_64 *data;
    if (mode == MK_SWIFT) {
        data = put_seg(p, "__DATA", TEXT_VMADDR + DATA_OFF, data_size, DATA_OFF, data_size, 2);
        put_sect(data, 0, "__objc_classlist", "__DATA", TEXT_VMADDR + DATA_OFF, 8, DATA_OFF);
        put_sect(data, 1, "__objc_data", "__DATA", TEXT_VMADDR + DATA_OFF + SW_CLASS, 0x80,
                 DATA_OFF + SW_CLASS);
    } else {
        data = put_seg(p, "__DATA", TEXT_VMADDR + DATA_OFF, data_size, DATA_OFF, data_size, 1);
        put_sect(data, 0, "__data", "__DATA", TEXT_VMADDR + DATA_OFF, data_size,
                 (mode == MK_NOSECT || mode == MK_SECTPAST) ? 0 : DATA_OFF);
    }
    p += data->cmdsize;
```

and replace `    if (mode == MK_BIG) {` (the chain-writing branch) with

```c
    if (mode == MK_SWIFT) {
        sw_link(buf, 0,             DATA_OFF + SW_CLASS,             SW_CLASS);
        sw_link(buf, SW_CLASS,      DATA_OFF + SW_META,              0x20);
        sw_link(buf, SW_CLASS + 32, (DATA_OFF + SW_RO) | 2,          0x20);
        sw_link(buf, SW_META,       DATA_OFF + SW_META,              0x20);
        sw_link(buf, SW_META + 32,  (DATA_OFF + SW_RO + 0x40) | 2,   0);
    } else if (mode == MK_BIG) {
```

Before `int main(`, add:

```c
static int tags(const char *path) {
    FILE *f = fopen(path, "rb");
    uint64_t c = 0, m = 0;
    if (!f) { perror(path); return 2; }
    if (fseek(f, DATA_OFF + SW_CLASS + 32, SEEK_SET) != 0 || fread(&c, 8, 1, f) != 1 ||
        fseek(f, DATA_OFF + SW_META + 32, SEEK_SET) != 0 || fread(&m, 8, 1, f) != 1) {
        fprintf(stderr, "%s: too short for make-swift's layout\n", path);
        fclose(f);
        return 2;
    }
    fclose(f);
    printf("class %llu\nmeta %llu\n", (unsigned long long)(c & 3), (unsigned long long)(m & 3));
    return 0;
}
```

In `main`, change both usage strings to end `…|make-lcfirst|make-swift|check|tags FILE\n`, and add, before the `check` line:

```c
    if (strcmp(argv[1], "make-swift") == 0) return make(argv[2], MK_SWIFT);
    if (strcmp(argv[1], "tags") == 0) return tags(argv[2]);
```

- [ ] **Step 2: Write the failing tests**

In `tests/cli_test.sh`, directly after `    || bad "info swift-abi after retag" "still reports tagged records"`:

```sh

# ON A CHAINED IMAGE THE CLASS-RECORD POINTERS ARE CHAIN LINKS, which the
# walk cannot follow: info says so, and swift-abi set legacy refuses rather
# than answer "nothing to retag" about records it never read.
"$T/mkchained" make-swift "$T/swift_chained"
[ "$("$T/mkchained" tags "$T/swift_chained")" = "class 2
meta 2" ] || bad "swift-abi chained: fixture setup" \
    "not both on the stable-ABI tag: $("$T/mkchained" tags "$T/swift_chained")"
"$DRYDOCK_MACHO_REWRITE" info "$T/swift_chained" 2>/dev/null \
    | grep -qxF 'swift-abi: unknown (pointers are chained; fixups set classic first)' \
    && ok "info: on a chained image the swift-abi line says unknown, and why" \
    || bad "info swift-abi chained" "got: $("$DRYDOCK_MACHO_REWRITE" info "$T/swift_chained" 2>/dev/null | grep '^swift-abi:')"
"$T/mkchained" make "$T/c_chained"
"$DRYDOCK_MACHO_REWRITE" info "$T/c_chained" 2>/dev/null \
    | grep -qxF 'swift-abi: unknown (pointers are chained; fixups set classic first)' \
    && ok "info: ... on any chained image, Swift or not" \
    || bad "info swift-abi chained" "got: $("$DRYDOCK_MACHO_REWRITE" info "$T/c_chained" 2>/dev/null | grep '^swift-abi:')"
swc_before=$(sha "$T/swift_chained")
rm -f "$T/swift_chained.out"
rc=0; printf 'swift-abi set legacy\n' | "$DRYDOCK_MACHO_REWRITE" "$T/swift_chained" "$T/swift_chained.out" \
    >/dev/null 2>"$T/swc.err" || rc=$?
[ "$rc" -eq 1 ] && [ ! -e "$T/swift_chained.out" ] && [ "$(sha "$T/swift_chained")" = "$swc_before" ] \
    && ok "swift-abi set legacy: a chained image is refused (1), nothing written" \
    || bad "swift-abi chained" "expected 1 and no OUT, got $rc: $(cat "$T/swc.err")"
grep -q 'pointers are chained; write .fixups set classic. before .swift-abi set legacy.' "$T/swc.err" \
    && ok "swift-abi set legacy: ... and the refusal names the fix" \
    || bad "swift-abi chained" "no fix named: $(cat "$T/swc.err")"
rc=0; printf 'fixups set classic\nswift-abi set legacy\n' \
    | "$DRYDOCK_MACHO_REWRITE" "$T/swift_chained" "$T/swift_chained.out" >/dev/null 2>"$T/swc.err" || rc=$?
[ "$rc" -eq 0 ] && grep -qxF "      retagged 2 class records" "$T/swc.err" \
    && [ "$("$T/mkchained" tags "$T/swift_chained.out")" = "class 1
meta 1" ] \
    && ok "swift-abi set legacy: after fixups set classic the same records are retagged" \
    || bad "swift-abi chained, fixups first" "rc $rc: $(cat "$T/swc.err")"
```

In `tests/wrapper_test.sh`, directly after the `    || bad "retag_swift_classes fat" …` line:

```sh

# A chained Swift binary: drydock-macho-rewrite refuses swift-abi set legacy on
# it (1), and this wrapper's exit-1 arm is its silent skip, so the caller gets
# what the C tool gave -- exit 0, total 0, the file untouched.
[ -x "$T/mkchained" ] || "$CC" -O2 -I "$ROOT/src" -o "$T/mkchained" "$HERE/mkchained.c" \
    || bad "retag_swift_classes chained: fixture setup" "cannot build $HERE/mkchained.c"
"$T/mkchained" make-swift "$T/f" || bad "retag_swift_classes chained: fixture setup" "make-swift failed"
ch_before=$(sha "$T/f")
run retag_swift_classes f
[ "$rc" -eq 0 ] && [ "$(sha "$T/f")" = "$ch_before" ] \
    && has_line "$T/out" 'total: 0 class record(s) retagged' \
    && ok "retag_swift_classes: a chained Swift binary is the C tool's silent zero, untouched" \
    || bad "retag_swift_classes chained" "exit $rc: $(cat "$T/out") $(cat "$T/err")"
```

- [ ] **Step 3: Run them to make sure they fail**

Run the build-and-check sequence, then:
`unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh /private/tmp/build/schmonz/drydock-native 2>&1 | grep -E 'swift-abi (chained|set legacy)|swift-abi line says unknown|Swift or not'`

Expected: FAIL "info swift-abi chained" twice (it says "no class records carry the stable-ABI tag"), FAIL "swift-abi chained" twice (exit 0, "nothing to retag"). PASS "after fixups set classic the same records are retagged", which proves the fixture holds two retaggable records. The wrapper assertion already PASSES: it pins behaviour this task must keep.

- [ ] **Step 4: Write the implementation**

`src/swift_retag.h`: directly after the `MSWIFT_NOT_MACHO` define, add

```c
#define MSWIFT_CHAINED    (-3)  /* the image has LC_DYLD_CHAINED_FIXUPS, so its class
                                 * records' pointers are chain links this walk cannot
                                 * follow; nothing printed, nothing changed */
```

and change the comment line `/* Negative returns from mswift_retag_file.` to `/* Negative returns from mswift_retag_file (and MSWIFT_CHAINED from all three).`. In `mswift_retag_file`'s comment, change "or one of the MSWIFT_* codes above" to "or one of the MSWIFT_* codes above; MSWIFT_CHAINED writes no `out`". In `mswift_retag_image`'s comment, replace "Returns the number of class records retagged, 0 or more; it has no failure of its own and prints nothing." with "Returns the number of class records retagged, 0 or more, or MSWIFT_CHAINED having changed nothing; it prints nothing." In `mswift_stable_tagged_image`'s comment, after its first sentence, add "MSWIFT_CHAINED on a chained image."

`src/swift_retag.c`: add `#include "mach_compat.h"   /* LC_DYLD_CHAINED_FIXUPS */` after `#include "image.h"`. Before `static int mswift_walk(`, add

```c
static int mswift_chained_lc(const struct load_command *lc, void *ctx_) {
    if (lc->cmd != LC_DYLD_CHAINED_FIXUPS) return 0;
    *(int *)ctx_ = 1;
    return 1;
}
```

and at the top of `mswift_walk`'s body, before `size_t fsize = im->size;`:

```c
    int chained = 0;
    mi_each_lc(im, mswift_chained_lc, &chained);
    if (chained) return MSWIFT_CHAINED;
```

In `mswift_retag_file`, directly after `int changed = mswift_retag_image(&im);`:

```c
    if (changed < 0) { mi_close(&im); return changed; }
```

`src/edit.c`, `case MS_SWIFT_ABI`: directly after `int retagged = mswift_retag_image(&im);`, add

```c
        if (retagged == MSWIFT_CHAINED) {
            me_say(log, "drydock-macho-rewrite edit: %s: the class records' pointers are chained; "
                        "write `fixups set classic` before `swift-abi set legacy`\n", path);
            return MR_REFUSED;
        }
```

`cli/drydock-macho-rewrite.c`, `info_image`: replace

```c
    if (mswift_stable_tagged_image(im) > 0)
        printf("swift-abi: class records carry the stable-ABI tag\n");
    else
        printf("swift-abi: no class records carry the stable-ABI tag\n");
```

with

```c
    int tagged = mswift_stable_tagged_image(im);
    if (tagged == MSWIFT_CHAINED)
        printf("swift-abi: unknown (pointers are chained; fixups set classic first)\n");
    else if (tagged > 0)
        printf("swift-abi: class records carry the stable-ABI tag\n");
    else
        printf("swift-abi: no class records carry the stable-ABI tag\n");
```

`target`'s own call (`if (mswift_stable_tagged_image(im) > 0)` in `me_expand_10_9`) is unchanged here: a negative answer derives nothing, as today. Task 3 moves that detection after `fixups set classic`.

- [ ] **Step 5: Run the tests and make sure they pass**

Run the build-and-check sequence (`drydock-macho-rewrite` and `edit_test` must be absent from the OK list), then the full test command. Expected: 22 tests, all pass, `chained_fixups` skips.

- [ ] **Step 6: Mutation-prove it**

1. In `mswift_walk`, delete `if (chained) return MSWIFT_CHAINED;`. Expected failures: cli_test "info swift-abi chained" (both), "swift-abi chained" (both).
2. In `case MS_SWIFT_ABI`, change the new `return MR_REFUSED;` to `return 0;`. Expected failure: "a chained image is refused (1), nothing written".
3. In `info_image`, swap the first two `printf` strings. Expected failures: "on a chained image the swift-abi line says unknown" and cli_test's "info: a tagged image says so".

- [ ] **Step 7: Commit**

```bash
git add src/swift_retag.h src/swift_retag.c src/edit.c cli/drydock-macho-rewrite.c \
        tests/mkchained.c tests/cli_test.sh tests/wrapper_test.sh
git commit -F - <<'EOF'
fix(swift-abi): refuse a chained image instead of answering "nothing to retag"

On an image with LC_DYLD_CHAINED_FIXUPS the class-record pointers are
chain links, not addresses, so the retag walk found no records, reported
"nothing to retag", exited 0, and left the stable-ABI tag set. A script
that ordered swift-abi before fixups got that silently.

The walk now answers MSWIFT_CHAINED before reading anything, the
statement refuses (1) and names the fix, and info's swift-abi line says
"unknown (pointers are chained; fixups set classic first)".

retag_swift_classes' wrapper maps exit 1 to its silent skip, so a caller
still gets what the C tool gave: exit 0, total 0, file untouched. A test
pins that.

mkchained gains make-swift, a chained image with one Swift class and its
metaclass on the stable-ABI tag, and a tags reader.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
```

---

### Task 2: `minos at-most` and `minos if-absent`, the core and the grammar

**Files:**
- Modify: `src/script.h` (op enum, line 43; `ms_parse_version`'s declaration and comment, lines 101-103)
- Modify: `src/script.c` (`MS_TABLE_ROWS`, line 132; `ms_parse_version`, lines 197-215; the `MS_MINOS` value check, lines 429-433)
- Modify: `src/version_min.h`, `src/version_min.c` (new declarations and definitions at the end of each)
- Modify: `src/edit.c` (`case MS_MINOS`, lines 427-440; a new `me_log_declared` after `me_log_minos`)
- Modify: `tests/mkminos.c` (header comment, usage, a new `add-bv` mode)
- Test: `tests/script_test.c`, `tests/edit_test.c`, `tests/cli_test.sh`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - Ops `MS_AT_MOST` and `MS_IF_ABSENT`, appended to the op enum. Rows `minos at-most` and `minos if-absent`, arity 1, disturbs `MREL_HEADER_PAD`, as the last two rows of `MS_TABLE_ROWS`. `--capabilities` gains `statement minos at-most 1` and `statement minos if-absent 1`; 20 statement lines until Task 3.
  - `int ms_parse_version(const char *s, uint32_t *out, uint32_t *mask);` — `*mask` (if not NULL) is `0xFFFF0000`, `0xFFFFFF00` or `0xFFFFFFFF` for one, two or three parts.
  - In `src/version_min.h`:
    ```c
    #define MV_PLATFORM_MACCATALYST 6
    enum { MV_AT_MOST, MV_IF_ABSENT };
    enum { MV_FROM_NONE, MV_FROM_VERSION_MIN, MV_FROM_BUILD_VERSION };
    typedef struct {
        int from; uint32_t declared; int above; uint32_t minos, sdk;
        int dropped_macos; uint32_t dropped_minos; int catalyst; int changed;
    } mv_decl_report;
    int mv_declare_minos(uint8_t **pbuf, size_t *psize, const char *label, int rule,
                         uint32_t version, uint32_t mask, mv_decl_report *r);
    ```
    It returns 0 or `MR_REFUSED` (reason on stderr, prefixed by `label`).
  - Report lines, six spaces in, one per slice:
    - `version-min D -> N; sdk S kept`
    - `version-min D, at or below V: kept; sdk S kept` (V as written in the statement)
    - `version-min D kept (declared); sdk S kept` (`if-absent`, D above V)
    - `build-version D -> version-min N; sdk S carried over`
    - `none -> version-min N; sdk 10.9 written`
    - each optionally followed by `; build-version D removed` and then `; Mac Catalyst build-version removed`
  - Refusals on stderr: `LABEL: declares platform N, not macOS; refusing to add a macOS minimum to it`; `LABEL: N LC_VERSION_MIN_MACOSX commands; refusing rather than choose one`; `LABEL: N macOS LC_BUILD_VERSION commands; refusing rather than choose one`; `LABEL: declares platform N beside macOS; refusing rather than guess which it is`; `no room for LC_VERSION_MIN_MACOSX`.
  - `mkminos add-bv FILE PLATFORM MINOS SDK`: append one `LC_BUILD_VERSION`, removing nothing.

- [ ] **Step 1: Give `mkminos` an append that strips nothing**

In `tests/mkminos.c`, add this line to the header's mode list, after the `bv` line:

```c
 *   mkminos add-bv FILE PLATFORM MINOS SDK  append LC_BUILD_VERSION, removing nothing
```

In `main`, directly before `usage:`:

```c
    if (strcmp(argv[1], "add-bv") == 0 && argc == 6) {
        uint32_t plat = (uint32_t)strtoul(argv[3], NULL, 10);
        if (version(argv[4], &v) || version(argv[5], &s)) return 2;
        uint32_t w[6] = { LC_BUILD_VERSION, 24, plat, v, s, 0 };
        return append(w, 6) || save(argv[2]) ? 2 : 0;
    }
```

and change the usage string to `"usage: mkminos none|show FILE | vmin FILE VERSION SDK | bv|add-bv FILE PLATFORM MINOS SDK\n"`.

- [ ] **Step 2: Write the failing parse tests**

In `tests/script_test.c`, in `test_minos_set_takes_a_version`, change `ms_parse_version(good[i], &v) == 0` to `ms_parse_version(good[i], &v, NULL) == 0`. Add before `main`:

```c
static void test_minos_at_most_and_if_absent_take_a_version(void) {
    static const char *ops[] = { "at-most", "if-absent" };
    const int op_enum[] = { MS_AT_MOST, MS_IF_ABSENT };
    static const char *good[] = { "10.9", "10.12", "10.9.5", "11", "65535.255.255", "0.0" };
    static const uint32_t packed[] = { 0x000A0900, 0x000A0C00, 0x000A0905, 0x000B0000,
                                       0xFFFFFFFF, 0 };
    static const uint32_t mask[] = { 0xFFFFFF00, 0xFFFFFF00, 0xFFFFFFFF, 0xFFFF0000,
                                     0xFFFFFFFF, 0xFFFFFF00 };
    static const char *bad[] = { "", "10.", ".9", "10..9", "10.9.5.1", "10.256",
                                 "65536", "-10.9", "+10", "10.9a", "ten", "10.9.256" };
    size_t o, i;
    for (o = 0; o < 2; o++) {
        for (i = 0; i < sizeof good / sizeof *good; i++) {
            char line[64], err[256] = {0};
            ms_script s;
            snprintf(line, sizeof line, "minos %s %s\n", ops[o], good[i]);
            CHECK(ms_parse(line, strlen(line), &s, err, sizeof err) == 0,
                  "minos %s %s parses (%s)", ops[o], good[i], err);
            if (s.n == 1)
                CHECK(s.stmts[0].kind == MS_MINOS && s.stmts[0].op == op_enum[o] &&
                      strcmp(s.stmts[0].a, good[i]) == 0,
                      "minos %s %s is one MS_MINOS statement carrying its operand", ops[o], good[i]);
            ms_free(&s);
        }
        for (i = 0; i < sizeof bad / sizeof *bad; i++) {
            char line[64], err[256] = {0};
            ms_script s;
            snprintf(line, sizeof line, "minos %s '%s'\n", ops[o], bad[i]);
            CHECK(ms_parse(line, strlen(line), &s, err, sizeof err) == -1 &&
                  strstr(err, "line 1") && strstr(err, "not a version") && strstr(err, ops[o]),
                  "minos %s '%s' is refused as not a version (got: %s)", ops[o], bad[i], err);
        }
    }
    for (i = 0; i < sizeof good / sizeof *good; i++) {
        uint32_t v = 1, m = 1;
        CHECK(ms_parse_version(good[i], &v, &m) == 0 && v == packed[i] && m == mask[i],
              "%s packs to 0x%08x with mask 0x%08x (got 0x%08x, 0x%08x)",
              good[i], packed[i], mask[i], v, m);
    }
    {
        uint32_t v = 0;
        CHECK(ms_parse_version("10.9", &v, NULL) == 0 && v == 0x000A0900,
              "a NULL mask is allowed");
    }
}
```

Register it in `main` after `test_minos_set_takes_a_version();`. In `test_capabilities_table_round_trips`, change `CHECK(n_rows == 18, "the statement table has 18 rows (got %d)", n_rows);` to use 20. At the end of `test_disturbs_matches_the_spec_table`, add:

```c
    CHECK(ms_disturbs(MS_MINOS, MS_AT_MOST) == MREL_HEADER_PAD,
          "minos at-most removes build-versions and may append a version-min: the pad");
    CHECK(ms_disturbs(MS_MINOS, MS_IF_ABSENT) == MREL_HEADER_PAD,
          "minos if-absent does the same, so it costs the same");
```

- [ ] **Step 3: Write the failing in-memory tests**

In `tests/edit_test.c`, after `#define BUILDVER_IOS 32 …`:

```c
#define CATALYST     64   /* a Mac Catalyst LC_BUILD_VERSION (platform 6), minos 13.0, sdk 13.0 */
#define SECOND_VMIN 128   /* a second LC_VERSION_MIN_MACOSX, 10.12, sdk 10.13 */
```

In `build_image`, directly before `h->ncmds = ncmds;`:

```c
    if (flags & CATALYST) {
        struct mc_build_version *bv = (struct mc_build_version *)p;
        bv->cmd = LC_BUILD_VERSION; bv->cmdsize = sizeof *bv;
        bv->platform = MV_PLATFORM_MACCATALYST;
        bv->minos = 0x000D0000; bv->sdk = 0x000D0000; bv->ntools = 0;
        p += bv->cmdsize; ncmds++;
    }
    if (flags & SECOND_VMIN) {
        struct version_min_command *vm = (struct version_min_command *)p;
        vm->cmd = LC_VERSION_MIN_MACOSX; vm->cmdsize = sizeof *vm;
        vm->version = 0x000A0C00; vm->sdk = 0x000A0D00;
        p += vm->cmdsize; ncmds++;
    }
```

After `lc_word`, add:

```c
/* Set word `field` (cmd is word 0) of the nth (0-based) `cmd` load command of
 * a build_image buffer. */
static void poke_lc(uint8_t *img, uint32_t cmd, int nth, uint32_t field, uint32_t value) {
    struct mach_header_64 *h = (struct mach_header_64 *)img;
    uint8_t *p = img + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == cmd && nth-- == 0) { ((uint32_t *)p)[field] = value; return; }
        p += lc->cmdsize;
    }
    assert(!"poke_lc: no such command");
}

static int same_file(const char *a, const char *b) {
    size_t la = 0, lb = 0;
    uint8_t *x = read_file(a, &la), *y = read_file(b, &lb);
    int same = x && y && la == lb && memcmp(x, y, la) == 0;
    free(x);
    free(y);
    return same;
}
```

Before `main`:

```c
static void test_minos_decides_the_minimum_per_rule(void) {
    static const struct {
        const char *script; int flags; uint32_t poke_cmd, poke_field, poke_value;
        uint32_t want_version, want_sdk; const char *line;
    } rows[] = {
        { "minos at-most 10.9\n", VMIN_1012, 0, 0, 0, 0x000A0900, 0x000A0D00,
          "  minos at-most 10.9\n      version-min 10.12 -> 10.9; sdk 10.13 kept\n" },
        { "minos at-most 10.9\n", VMIN_1012, LC_VERSION_MIN_MACOSX, 2, 0x000A0700,
          0x000A0700, 0x000A0D00, "      version-min 10.7, at or below 10.9: kept; sdk 10.13 kept\n" },
        { "minos at-most 10.9\n", VMIN_1012, LC_VERSION_MIN_MACOSX, 2, 0x000A0905,
          0x000A0905, 0x000A0D00, "      version-min 10.9.5, at or below 10.9: kept; sdk 10.13 kept\n" },
        { "minos at-most 10.9.3\n", VMIN_1012, LC_VERSION_MIN_MACOSX, 2, 0x000A0905,
          0x000A0903, 0x000A0D00, "      version-min 10.9.5 -> 10.9.3; sdk 10.13 kept\n" },
        { "minos at-most 10.9\n", BUILDVER_12, 0, 0, 0, 0x000A0900, 0x000C0300,
          "      build-version 12.0 -> version-min 10.9; sdk 12.3 carried over\n" },
        { "minos at-most 10.9\n", BUILDVER_12, LC_BUILD_VERSION, 3, 0x000A0700,
          0x000A0700, 0x000C0300, "      build-version 10.7 -> version-min 10.7; sdk 12.3 carried over\n" },
        { "minos at-most 10.9\n", 0, 0, 0, 0, 0x000A0900, 0x000A0900,
          "      none -> version-min 10.9; sdk 10.9 written\n" },
        { "minos at-most 10.7\n", 0, 0, 0, 0, 0x000A0700, 0x000A0900,
          "      none -> version-min 10.7; sdk 10.9 written\n" },
        { "minos if-absent 10.9\n", VMIN_1012, 0, 0, 0, 0x000A0C00, 0x000A0D00,
          "      version-min 10.12 kept (declared); sdk 10.13 kept\n" },
        { "minos if-absent 10.9\n", VMIN_1012, LC_VERSION_MIN_MACOSX, 2, 0x000A0700,
          0x000A0700, 0x000A0D00, "      version-min 10.7, at or below 10.9: kept; sdk 10.13 kept\n" },
        { "minos if-absent 10.9\n", BUILDVER_12, 0, 0, 0, 0x000C0000, 0x000C0300,
          "      build-version 12.0 -> version-min 12.0; sdk 12.3 carried over\n" },
        { "minos if-absent 10.9\n", BUILDVER_12, LC_BUILD_VERSION, 3, 0x000A0700,
          0x000A0700, 0x000C0300, "      build-version 10.7 -> version-min 10.7; sdk 12.3 carried over\n" },
        { "minos if-absent 10.9\n", 0, 0, 0, 0, 0x000A0900, 0x000A0900,
          "      none -> version-min 10.9; sdk 10.9 written\n" },
        { "minos at-most 10.9\n", VMIN_1012 | BUILDVER_12, 0, 0, 0, 0x000A0900, 0x000A0D00,
          "      version-min 10.12 -> 10.9; sdk 10.13 kept; build-version 12.0 removed\n" },
        { "minos at-most 10.9\n", BUILDVER_12 | CATALYST, 0, 0, 0, 0x000A0900, 0x000C0300,
          "      build-version 12.0 -> version-min 10.9; sdk 12.3 carried over; "
          "Mac Catalyst build-version removed\n" },
    };
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    for (size_t i = 0; i < sizeof rows / sizeof *rows; i++) {
        uint8_t *img = build_image(rows[i].flags);
        if (rows[i].poke_cmd) poke_lc(img, rows[i].poke_cmd, 0, rows[i].poke_field, rows[i].poke_value);
        write_file(path, img, IMG_SIZE, 0755);
        free(img);
        int rc = run(path, out, rows[i].script);
        CHECK(rc == 0, "row %zu, %s: runs (got %d; log: %s)", i, rows[i].script, rc, g_log);
        CHECK(count_lc(out, LC_VERSION_MIN_MACOSX, NULL) == 1 &&
              count_lc(out, LC_BUILD_VERSION, NULL) == 0,
              "row %zu: one LC_VERSION_MIN_MACOSX and no LC_BUILD_VERSION after it", i);
        CHECK(lc_word(out, LC_VERSION_MIN_MACOSX, 2) == rows[i].want_version &&
              lc_word(out, LC_VERSION_MIN_MACOSX, 3) == rows[i].want_sdk,
              "row %zu: version-min 0x%08x sdk 0x%08x (got 0x%08x sdk 0x%08x)", i,
              rows[i].want_version, rows[i].want_sdk, lc_word(out, LC_VERSION_MIN_MACOSX, 2),
              lc_word(out, LC_VERSION_MIN_MACOSX, 3));
        CHECK(strstr(g_log, rows[i].line) != NULL,
              "row %zu: the report says %s(log: %s)", i, rows[i].line, g_log);
    }
    rm_dir();
}

static void test_minos_leaves_a_declared_10_9_byte_for_byte(void) {
    fresh_dir();
    char path[512], out[512], out2[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    in_dir(out2, sizeof out2, "img.out2");
    uint8_t *img = build_image(VMIN_1012);
    poke_lc(img, LC_VERSION_MIN_MACOSX, 0, 2, 0x000A0900);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    int rc = run(path, out, "minos at-most 10.9\n");
    CHECK(rc == 0 && same_file(path, out), "at-most leaves a version-min 10.9 byte for byte (got %d)", rc);
    rc = run(path, out, "minos if-absent 10.9\n");
    CHECK(rc == 0 && same_file(path, out), "if-absent does too (got %d)", rc);
    img = build_image(VMIN_1012 | BUILDVER_12);
    write_file(path, img, IMG_SIZE, 0755);
    free(img);
    rc = run(path, out, "minos at-most 10.9\n");
    CHECK(rc == 0 && !same_file(path, out), "at-most lowers and converts that image (got %d)", rc);
    rc = run(out, out2, "minos at-most 10.9\n");
    CHECK(rc == 0 && same_file(out, out2), "run again on its own output it changes nothing (got %d)", rc);
    rm_dir();
}

static void test_minos_refuses_what_is_not_one_macos_declaration(void) {
    static const struct { int flags; uint32_t second_bv_platform; const char *what; } rows[] = {
        { BUILDVER_IOS, 0, "an iOS-only slice" },
        { VMIN_1012 | SECOND_VMIN, 0, "two LC_VERSION_MIN_MACOSX" },
        { BUILDVER_12 | CATALYST, MV_PLATFORM_MACOS, "two macOS LC_BUILD_VERSION" },
        { VMIN_1012 | BUILDVER_IOS, 0, "an iOS LC_BUILD_VERSION beside a macOS version-min" },
    };
    static const char *scripts[] = { "minos at-most 10.9\n", "minos if-absent 10.9\n" };
    fresh_dir();
    char path[512], out[512];
    in_dir(path, sizeof path, "img");
    in_dir(out, sizeof out, "img.out");
    for (size_t i = 0; i < sizeof rows / sizeof *rows; i++) {
        for (size_t j = 0; j < 2; j++) {
            uint8_t *img = build_image(rows[i].flags);
            if (rows[i].second_bv_platform)
                poke_lc(img, LC_BUILD_VERSION, 1, 2, rows[i].second_bv_platform);
            write_file(path, img, IMG_SIZE, 0755);
            free(img);
            snap before = take(path);
            int rc = run(path, out, scripts[j]);
            CHECK(rc == MR_REFUSED, "%s, %s: refused (got %d; log: %s)",
                  rows[i].what, scripts[j], rc, g_log);
            check_untouched(rows[i].what, path, &before);
        }
    }
    rm_dir();
}

static void test_fat_minos_decides_per_slice(void) {
    fresh_dir();
    char path[512], out[512], s0[512], s1[512], in1[512];
    in_dir(path, sizeof path, "fat");
    in_dir(out, sizeof out, "fat.out");
    in_dir(s0, sizeof s0, "s0");
    in_dir(s1, sizeof s1, "s1");
    in_dir(in1, sizeof in1, "in1");
    write_fat(path, VMIN_1012, BUILDVER_12, 0);
    int rc = run(path, out, "minos at-most 10.9\n");
    CHECK(rc == 0, "fat, minos at-most: runs (got %d; log: %s)", rc, g_log);
    slice_to_file(out, 0, s0);
    slice_to_file(out, 1, s1);
    CHECK(lc_word(s0, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900 &&
          lc_word(s0, LC_VERSION_MIN_MACOSX, 3) == 0x000A0D00,
          "fat: slice 0's version-min 10.12 is lowered to 10.9, sdk 10.13 kept");
    CHECK(count_lc(s1, LC_BUILD_VERSION, NULL) == 0 &&
          lc_word(s1, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900 &&
          lc_word(s1, LC_VERSION_MIN_MACOSX, 3) == 0x000C0300,
          "fat: slice 1's build-version 12.0 becomes version-min 10.9, sdk 12.3 carried over");
    rc = run(path, out, "arch x86_64\nminos at-most 10.9\n");
    slice_to_file(path, 1, in1);
    slice_to_file(out, 0, s0);
    slice_to_file(out, 1, s1);
    CHECK(rc == 0 && same_file(in1, s1),
          "fat, arch x86_64: the arm64 slice passes through byte for byte (got %d)", rc);
    CHECK(lc_word(s0, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900,
          "fat, arch x86_64: ... and the x86_64 slice is lowered");
    rm_dir();
}
```

Register all four in `main` after `test_mv_format_version_drops_a_zero_patch();`.

- [ ] **Step 4: Write the failing end-to-end tests**

In `tests/cli_test.sh`, change the capabilities count block (`[ "$n_statements" -eq 18 ] && [ "$n_unique" -eq 18 ]` and its `ok` label) to 20, and directly after the `"capabilities: minos set is advertised"` assertion add:

```sh
for caps_minos in 'at-most' 'if-absent'; do
    echo "$caps" | grep -qxF "statement minos $caps_minos 1" \
        && ok "capabilities: minos $caps_minos is advertised" \
        || bad "capabilities statements" "no 'statement minos $caps_minos 1': $(echo "$caps" | grep '^statement minos')"
done
```

Directly before the section header whose second line is `# lc -delete`, add:

```sh
# ============================================================================
# minos at-most, minos if-absent
# ============================================================================
# mn_setup FILE MODE ARG... -- one mkminos surgery on FILE.
mn_setup() { mn_f=$1; shift; mn_m=$1; shift; "$T/mkminos" "$mn_m" "$mn_f" "$@"; }
# statement | mkminos setup | mkminos show afterwards | the report line
while IFS='|' read -r mn_st mn_how mn_want mn_line; do
    build_main "$T/mn"
    mn_setup "$T/mn" $mn_how || bad "minos $mn_st: fixture setup" "mkminos $mn_how failed"
    rc=0; printf 'minos %s\n' "$mn_st" | "$DRYDOCK_MACHO_REWRITE" "$T/mn" "$T/mn.out" \
        >/dev/null 2>"$T/mn.err" || rc=$?
    [ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/mn.out")" = "$mn_want" ] \
        && ok "minos $mn_st on '$mn_how': the image ends as $mn_want" \
        || bad "minos $mn_st ($mn_how)" "rc $rc: $("$T/mkminos" show "$T/mn.out" 2>&1); $(cat "$T/mn.err")"
    grep -qxF "      $mn_line" "$T/mn.err" \
        && ok "minos $mn_st on '$mn_how': ... and the report says '$mn_line'" \
        || bad "minos $mn_st ($mn_how)" "no report line: $(cat "$T/mn.err")"
done <<'EOF'
at-most 10.9|vmin 10.12 10.13|version-min version=10.9.0 sdk=10.13.0|version-min 10.12 -> 10.9; sdk 10.13 kept
at-most 10.9|vmin 10.7 10.9|version-min version=10.7.0 sdk=10.9.0|version-min 10.7, at or below 10.9: kept; sdk 10.9 kept
at-most 10.9|bv 1 12.0 12.3|version-min version=10.9.0 sdk=12.3.0|build-version 12.0 -> version-min 10.9; sdk 12.3 carried over
at-most 10.9|bv 1 10.7 10.10|version-min version=10.7.0 sdk=10.10.0|build-version 10.7 -> version-min 10.7; sdk 10.10 carried over
at-most 10.9|none|version-min version=10.9.0 sdk=10.9.0|none -> version-min 10.9; sdk 10.9 written
if-absent 10.9|vmin 10.12 10.13|version-min version=10.12.0 sdk=10.13.0|version-min 10.12 kept (declared); sdk 10.13 kept
if-absent 10.9|vmin 10.7 10.9|version-min version=10.7.0 sdk=10.9.0|version-min 10.7, at or below 10.9: kept; sdk 10.9 kept
if-absent 10.9|bv 1 12.0 12.3|version-min version=12.0.0 sdk=12.3.0|build-version 12.0 -> version-min 12.0; sdk 12.3 carried over
if-absent 10.9|bv 1 10.7 10.10|version-min version=10.7.0 sdk=10.10.0|build-version 10.7 -> version-min 10.7; sdk 10.10 carried over
if-absent 10.9|none|version-min version=10.9.0 sdk=10.9.0|none -> version-min 10.9; sdk 10.9 written
EOF

# A zippered slice carries two LC_BUILD_VERSIONs; either statement leaves one
# LC_VERSION_MIN_MACOSX and neither of them.
build_main "$T/mn_zip"
"$T/mkminos" bv "$T/mn_zip" 1 12.0 12.3 && "$T/mkminos" add-bv "$T/mn_zip" 6 13.0 13.0 \
    || bad "minos zippered: fixture setup" "mkminos failed"
[ "$("$T/mkminos" show "$T/mn_zip")" = "build-version platform=1 minos=12.0.0 sdk=12.3.0
build-version platform=6 minos=13.0.0 sdk=13.0.0" ] \
    || bad "minos zippered: fixture setup" "not macOS + Mac Catalyst: $("$T/mkminos" show "$T/mn_zip")"
for mn_st in 'at-most 10.9' 'if-absent 10.9'; do
    case $mn_st in
        at-*) mn_want='version-min version=10.9.0 sdk=12.3.0' ;;
        *)    mn_want='version-min version=12.0.0 sdk=12.3.0' ;;
    esac
    rc=0; printf 'minos %s\n' "$mn_st" | "$DRYDOCK_MACHO_REWRITE" "$T/mn_zip" "$T/mn_zip.out" \
        >/dev/null 2>"$T/mn.err" || rc=$?
    [ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/mn_zip.out")" = "$mn_want" ] \
        && ok "minos $mn_st: a zippered slice ends with one LC_VERSION_MIN_MACOSX and no LC_BUILD_VERSION" \
        || bad "minos $mn_st (zippered)" "rc $rc: $("$T/mkminos" show "$T/mn_zip.out" 2>&1)"
    grep -q '^      build-version 12\.0 -> .*; Mac Catalyst build-version removed$' "$T/mn.err" \
        && ok "minos $mn_st: ... and the report names the Mac Catalyst command it removed" \
        || bad "minos $mn_st (zippered)" "no removal named: $(cat "$T/mn.err")"
done

# A slice that already holds one version-min at or below VERSION, and nothing
# else, is written byte for byte.
build_main "$T/mn_same"
"$T/mkminos" vmin "$T/mn_same" 10.9 10.9 || bad "minos unchanged: fixture setup" "mkminos vmin failed"
for mn_st in 'at-most 10.9' 'if-absent 10.9'; do
    rc=0; printf 'minos %s\n' "$mn_st" | "$DRYDOCK_MACHO_REWRITE" "$T/mn_same" "$T/mn_same.out" \
        >/dev/null 2>"$T/mn.err" || rc=$?
    [ "$rc" -eq 0 ] && cmp -s "$T/mn_same" "$T/mn_same.out" \
        && ok "minos $mn_st: a slice already at version-min 10.9 is written byte for byte" \
        || bad "minos $mn_st (unchanged)" "rc $rc, or the bytes changed: $(cat "$T/mn.err")"
done

# A slice that declares only a non-macOS platform is refused, not a miss:
# allow-unmatched does not cover it.
build_main "$T/mn_ios"
"$T/mkminos" bv "$T/mn_ios" 2 12.0 12.3 || bad "minos iOS: fixture setup" "mkminos bv failed"
mn_before=$(sha "$T/mn_ios")
for mn_script in 'minos at-most 10.9' 'allow-unmatched
minos if-absent 10.9'; do
    rm -f "$T/mn_ios.out"
    rc=0; printf '%s\n' "$mn_script" | "$DRYDOCK_MACHO_REWRITE" "$T/mn_ios" "$T/mn_ios.out" \
        >/dev/null 2>"$T/mn.err" || rc=$?
    [ "$rc" -eq 1 ] && [ ! -e "$T/mn_ios.out" ] && [ "$(sha "$T/mn_ios")" = "$mn_before" ] \
        && grep -qF "declares platform 2, not macOS; refusing to add a macOS minimum to it" "$T/mn.err" \
        && ok "minos: an iOS-only slice is refused (1), nothing written ($(echo "$mn_script" | tr '\n' ' '))" \
        || bad "minos (iOS)" "rc $rc: $(cat "$T/mn.err")"
done

rm -f "$T/mn_bad.out"
rc=0; printf 'minos at-most 10.x\n' | "$DRYDOCK_MACHO_REWRITE" "$T/mn_same" "$T/mn_bad.out" \
    >/dev/null 2>"$T/mn.err" || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$T/mn_bad.out" ] && grep -q "minos at-most: '10.x' is not a version" "$T/mn.err" \
    && ok "minos at-most: a malformed version is a parse error (2), nothing written" \
    || bad "minos at-most (bad version)" "rc $rc: $(cat "$T/mn.err")"
```

- [ ] **Step 5: Run them to make sure they fail**

Run the build-and-check sequence. Expected: the build fails in `script_test.c` and `edit_test.c` (`MS_AT_MOST`, `MV_PLATFORM_MACCATALYST` undeclared; `ms_parse_version` called with too many arguments). That is this step's failure. `drydock-macho-rewrite` still builds, so run `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh /private/tmp/build/schmonz/drydock-native 2>&1 | grep -E '^FAIL' | head -40`. Expected: FAIL on "exactly 20", both new capability lines, every `minos at-most` / `minos if-absent` row (the parser says "unknown statement"), the zippered and unchanged cases, the iOS case (exit 2, not 1), and the malformed-version case (exit 2, but "unknown statement 'minos at-most'", not "is not a version").

- [ ] **Step 6: Write the parser half**

`src/script.h`: change the op enum to

```c
enum { MS_DELETE, MS_RENAME, MS_SET, MS_REPLACE, MS_APPEND,
       MS_INSERT, MS_REEXPORT, MS_PROFILE_10_9, MS_RETYPE, MS_REDIRECT,
       MS_AT_MOST, MS_IF_ABSENT };
```

and replace the `ms_parse_version` comment and declaration with

```c
/* Packs MAJOR[.MINOR[.PATCH]], at most 65535.255.255, as xxxx.yy.zz, and sets
 * *mask (unless NULL) to the parts it names: 0xFFFF0000, 0xFFFFFF00 or
 * 0xFFFFFFFF. 0, or -1 if malformed. */
int ms_parse_version(const char *s, uint32_t *out, uint32_t *mask);
```

`src/script.c`: put a ` \` after the `minos set` row and add two rows after it, so the table ends:

```c
  R("minos",        MS_MINOS,        "set",      MS_SET,          1, NULL,        0,             0, MREL_NONE) \
  R("minos",        MS_MINOS,        "at-most",  MS_AT_MOST,      1, NULL,        0,             0, MREL_HEADER_PAD) \
  R("minos",        MS_MINOS,        "if-absent", MS_IF_ABSENT,   1, NULL,        0,             0, MREL_HEADER_PAD)
```

Replace `ms_parse_version` with

```c
int ms_parse_version(const char *s, uint32_t *out, uint32_t *mask) {
    static const unsigned long max[3] = { 65535, 255, 255 };
    static const uint32_t masks[3] = { 0xFFFF0000u, 0xFFFFFF00u, 0xFFFFFFFFu };
    unsigned long part[3] = { 0, 0, 0 };
    int n = 0;
    for (;;) {
        unsigned long v = 0;
        if (*s < '0' || *s > '9') return -1;
        while (*s >= '0' && *s <= '9') {
            v = v * 10 + (unsigned long)(*s++ - '0');
            if (v > max[n]) return -1;
        }
        part[n++] = v;
        if (*s == '\0') break;
        if (*s != '.' || n == 3) return -1;
        s++;
    }
    *out = (uint32_t)(part[0] << 16 | part[1] << 8 | part[2]);
    if (mask) *mask = masks[n - 1];
    return 0;
}
```

and replace the `MS_MINOS` value check with one covering every `minos` op:

```c
            } else if (kind == MS_MINOS && ms_parse_version(fields[2], &ver, NULL) != 0) {
                return ms_failf(stmts, text, out, err, errsz, lineno,
                    "minos %s: '%s' is not a version (MAJOR[.MINOR[.PATCH]], "
                    "at most 65535.255.255)", fields[1], fields[2]);
```

- [ ] **Step 7: Write the core**

`src/version_min.h`, before `#endif`:

```c
#define MV_PLATFORM_MACCATALYST 6   /* LC_BUILD_VERSION.platform */

enum { MV_AT_MOST, MV_IF_ABSENT };                                /* the rule */
enum { MV_FROM_NONE, MV_FROM_VERSION_MIN, MV_FROM_BUILD_VERSION };  /* where D was read */

/* What mv_declare_minos read and wrote, for the report. */
typedef struct {
    int      from;           /* MV_FROM_* */
    uint32_t declared;       /* D, when from is not MV_FROM_NONE */
    int      above;          /* D is above VERSION, at VERSION's precision */
    uint32_t minos, sdk;     /* the LC_VERSION_MIN_MACOSX the slice ends with */
    int      dropped_macos;  /* a macOS LC_BUILD_VERSION removed beside a version-min */
    uint32_t dropped_minos;  /* ... and its minos */
    int      catalyst;       /* Mac Catalyst LC_BUILD_VERSIONs removed */
    int      changed;        /* any byte of the slice changed */
} mv_decl_report;

/* Leave the image in *pbuf with exactly one LC_VERSION_MIN_MACOSX and no
 * LC_BUILD_VERSION. `rule` and `version` (with the mask ms_parse_version gave)
 * decide the minimum; the sdk is the declaring command's, or 10.9 when
 * nothing was declared. Returns 0, or MR_REFUSED with the reason on stderr
 * prefixed by `label`. A grow may reallocate *pbuf. */
int mv_declare_minos(uint8_t **pbuf, size_t *psize, const char *label, int rule,
                     uint32_t version, uint32_t mask, mv_decl_report *r);
```

`src/version_min.c`, at the end:

```c
struct mv_decl_scan {
    int      n_vm, n_macos, n_bv, n_foreign, n_catalyst, n_other, short_cmd;
    uint32_t vm_version, vm_sdk, bv_minos, bv_sdk, foreign, other;
};

static int mv_decl_lc(const struct load_command *lc, void *ctx_) {
    struct mv_decl_scan *c = ctx_;
    if (lc->cmd == LC_VERSION_MIN_MACOSX) {
        const struct version_min_command *vm = (const struct version_min_command *)lc;
        if (lc->cmdsize < sizeof *vm) { c->short_cmd = 1; return 1; }
        if (c->n_vm++ == 0) { c->vm_version = vm->version; c->vm_sdk = vm->sdk; }
    } else if (lc->cmd == LC_BUILD_VERSION) {
        const struct mc_build_version *bv = (const struct mc_build_version *)lc;
        if (lc->cmdsize < sizeof *bv) { c->short_cmd = 1; return 1; }
        c->n_bv++;
        if (bv->platform == MV_PLATFORM_MACOS) {
            if (c->n_macos++ == 0) { c->bv_minos = bv->minos; c->bv_sdk = bv->sdk; }
            return 0;
        }
        if (c->n_foreign++ == 0) c->foreign = bv->platform;
        if (bv->platform == MV_PLATFORM_MACCATALYST) c->n_catalyst++;
        else if (c->n_other++ == 0) c->other = bv->platform;
    }
    return 0;
}

static void mv_remove_build_versions(uint8_t *buf) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = buf + sizeof *h;
    uint32_t end = (uint32_t)sizeof *h + h->sizeofcmds, i = 0;
    while (i < h->ncmds) {
        struct load_command *lc = (struct load_command *)p;
        uint32_t sz = lc->cmdsize;
        if (lc->cmd == LC_BUILD_VERSION) {
            memmove(p, p + sz, end - (uint32_t)(p - buf) - sz);
            memset(buf + end - sz, 0, sz);
            end -= sz; h->ncmds--; h->sizeofcmds -= sz;
            continue;
        }
        p += sz; i++;
    }
}

static void mv_rewrite_version(uint8_t *buf, uint32_t version) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = buf + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_VERSION_MIN_MACOSX) {
            ((struct version_min_command *)lc)->version = version;
            return;
        }
        p += lc->cmdsize;
    }
}

static void mv_append_version_min(uint8_t *buf, uint32_t version, uint32_t sdk) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct version_min_command *vm =
        (struct version_min_command *)(buf + sizeof *h + h->sizeofcmds);
    vm->cmd = LC_VERSION_MIN_MACOSX;
    vm->cmdsize = sizeof *vm;
    vm->version = version;
    vm->sdk = sdk;
    h->ncmds++;
    h->sizeofcmds += sizeof *vm;
}

int mv_declare_minos(uint8_t **pbuf, size_t *psize, const char *label, int rule,
                     uint32_t version, uint32_t mask, mv_decl_report *r) {
    struct mv_decl_scan c;
    mi_image im;
    memset(r, 0, sizeof *r);
    memset(&c, 0, sizeof c);
    if (mi_wrap(*pbuf, *psize, &im) != 0) {
        fprintf(stderr, "%s: not a readable 64-bit Mach-O\n", label);
        return MR_REFUSED;
    }
    mi_each_lc(&im, mv_decl_lc, &c);
    if (c.short_cmd) {
        fprintf(stderr, "%s: a version load command is shorter than its structure; refusing\n", label);
        return MR_REFUSED;
    }
    if (c.n_vm > 1) {
        fprintf(stderr, "%s: %d LC_VERSION_MIN_MACOSX commands; refusing rather than choose one\n",
                label, c.n_vm);
        return MR_REFUSED;
    }
    if (c.n_macos > 1) {
        fprintf(stderr, "%s: %d macOS LC_BUILD_VERSION commands; refusing rather than choose one\n",
                label, c.n_macos);
        return MR_REFUSED;
    }
    if (c.n_foreign && !c.n_vm && !c.n_macos) {
        fprintf(stderr, "%s: declares platform %u, not macOS; refusing to add a macOS minimum to it\n",
                label, c.foreign);
        return MR_REFUSED;
    }
    if (c.n_other) {
        fprintf(stderr, "%s: declares platform %u beside macOS; refusing rather than guess which it is\n",
                label, c.other);
        return MR_REFUSED;
    }

    r->from = c.n_vm ? MV_FROM_VERSION_MIN : c.n_macos ? MV_FROM_BUILD_VERSION : MV_FROM_NONE;
    r->declared = r->from == MV_FROM_VERSION_MIN ? c.vm_version : c.bv_minos;
    r->above = r->from != MV_FROM_NONE && (r->declared & mask) > version;
    r->minos = r->from == MV_FROM_NONE || (rule == MV_AT_MOST && r->above) ? version : r->declared;
    r->sdk = r->from == MV_FROM_VERSION_MIN ? c.vm_sdk
           : r->from == MV_FROM_BUILD_VERSION ? c.bv_sdk : MV_10_9;
    r->dropped_macos = r->from == MV_FROM_VERSION_MIN && c.n_macos;
    r->dropped_minos = c.bv_minos;
    r->catalyst = c.n_catalyst;

    if (r->from == MV_FROM_VERSION_MIN && !c.n_bv && r->minos == r->declared) return 0;
    if (r->from == MV_FROM_NONE) {
        uint32_t need_end = (uint32_t)sizeof(struct mach_header_64) + im.hdr->sizeofcmds +
                            (uint32_t)sizeof(struct version_min_command);
        uint32_t first = mg_first_sect_off(*pbuf, *psize);
        if (first == MG_NO_SECTION_DATA || first == UINT32_MAX || need_end > *psize ||
            mg_ensure_pad(pbuf, psize, need_end, label) != 0) {
            fprintf(stderr, "no room for LC_VERSION_MIN_MACOSX\n");
            return MR_REFUSED;
        }
        mv_append_version_min(*pbuf, r->minos, r->sdk);
    } else {
        mv_remove_build_versions(*pbuf);
        if (r->from == MV_FROM_VERSION_MIN) mv_rewrite_version(*pbuf, r->minos);
        else                                mv_append_version_min(*pbuf, r->minos, r->sdk);
    }
    r->changed = 1;
    return 0;
}
```

- [ ] **Step 8: Write the lowering**

`src/edit.c`: after `me_log_minos`, add

```c
static void me_log_declared(FILE *log, const mv_decl_report *r, const char *version) {
    char d[16], n[16], s[16], x[16];
    mv_format_version(r->declared, d);
    mv_format_version(r->minos, n);
    mv_format_version(r->sdk, s);
    if (r->from == MV_FROM_NONE)
        me_say(log, "      none -> version-min %s; sdk %s written", n, s);
    else if (r->from == MV_FROM_BUILD_VERSION)
        me_say(log, "      build-version %s -> version-min %s; sdk %s carried over", d, n, s);
    else if (r->minos != r->declared)
        me_say(log, "      version-min %s -> %s; sdk %s kept", d, n, s);
    else if (r->above)
        me_say(log, "      version-min %s kept (declared); sdk %s kept", d, s);
    else
        me_say(log, "      version-min %s, at or below %s: kept; sdk %s kept", d, version, s);
    if (r->dropped_macos) {
        mv_format_version(r->dropped_minos, x);
        me_say(log, "; build-version %s removed", x);
    }
    if (r->catalyst) me_say(log, "; Mac Catalyst build-version removed");
    me_say(log, "\n");
}
```

Replace `case MS_MINOS` with

```c
    case MS_MINOS: {
        uint32_t want = 0, mask = 0;
        mi_image im;
        if (ms_parse_version(st->a, &want, &mask) != 0) goto unknown;
        if (me_view(*pbuf, *psize, &im, path, log) != 0) return MR_REFUSED;
        if (st->op == MS_AT_MOST || st->op == MS_IF_ABSENT) {
            mv_decl_report d;
            int rc = mv_declare_minos(pbuf, psize, path,
                                      st->op == MS_AT_MOST ? MV_AT_MOST : MV_IF_ABSENT,
                                      want, mask, &d);
            if (rc != 0) return rc;
            me_log_declared(log, &d, st->a);
            return 0;
        }
        if (st->op != MS_SET) goto unknown;
        mv_minos_report r;
        mv_set_minos(&im, want, &r);
        me_log_minos(log, &r, want);
        *v->renamed += r.version_min + r.build_version;
        if (!v->decide || *v->renamed > 0) return 0;
        me_say(stderr, "drydock-macho-rewrite: minos set %s matched nothing\n", st->a);
        if (!s->allow_unmatched) { v->missed = 1; return MR_REFUSED; }
        return 0;
    }
```

- [ ] **Step 9: Run the tests and make sure they pass**

Run the build-and-check sequence (all three binaries absent from the OK list), then the full test command. Expected: 22 tests, all pass, `chained_fixups` skips.

- [ ] **Step 10: Mutation-prove it**

Each on its own; rebuild, confirm by hash, see it fail, restore.

1. In `mv_declare_minos`, change `(r->declared & mask) > version` to `r->declared > version`. Expected: edit_test row 2 ("version-min 10.9.5, at or below 10.9") fails.
2. Change `rule == MV_AT_MOST && r->above` to `rule == MV_IF_ABSENT && r->above`. Expected: edit_test rows 0, 3 and 8, and cli_test's `at-most 10.9|vmin 10.12` and `if-absent 10.9|vmin 10.12` rows, fail.
3. Change `: r->from == MV_FROM_BUILD_VERSION ? c.bv_sdk : MV_10_9;` to `: MV_10_9;`. Expected: every "carried over" row fails in both suites.
4. In the `else` branch, delete `mv_remove_build_versions(*pbuf);`. Expected: edit_test row 13 ("build-version 12.0 removed") fails on "no LC_BUILD_VERSION after it"; the zippered cli cases fail.
5. Delete the `if (c.n_foreign && !c.n_vm && !c.n_macos) { … }` block. Expected: edit_test "an iOS-only slice … refused" and cli_test "an iOS-only slice is refused (1)" fail.
6. In `ms_parse_version`, change `masks[n - 1]` to `masks[2]`. Expected: script_test "packs to … with mask" fails for 10.9, 10.12, 11 and 0.0.

- [ ] **Step 11: Commit**

```bash
git add src/script.h src/script.c src/version_min.h src/version_min.c src/edit.c \
        tests/mkminos.c tests/script_test.c tests/edit_test.c tests/cli_test.sh
git commit -F - <<'EOF'
feat(script): minos at-most and minos if-absent

Two statements that name the rule they apply to the declared minimum.
at-most lowers a minimum above VERSION to VERSION; if-absent leaves any
declared minimum as it is; both declare VERSION where nothing is
declared. Comparison is at VERSION's own precision, so at-most 10.9
keeps a declared 10.9.5 and at-most 10.9.3 lowers it.

Every macOS slice ends with exactly one LC_VERSION_MIN_MACOSX, the only
version command 10.9 reads, and no LC_BUILD_VERSION: the pair that
10.14's dyld and the 10.15+ kernel refuse cannot be left behind. The
sdk is the declaring command's, carried over from an LC_BUILD_VERSION,
or 10.9 when nothing was declared. A slice already in that shape is
written byte for byte.

A slice declaring only a non-macOS platform, two of either version
command, or a foreign platform beside a macOS declaration is refused.
Neither statement can match nothing, so allow-unmatched does not apply.

ms_parse_version reports the precision VERSION was written at.
mkminos gains add-bv, which appends without stripping, for zippered
fixtures.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
```

---

### Task 3: `fixups set classic` keeps the declaration, and `target 10.9` is published as the edit script it expands to

**Files:**
- Modify: `src/declassify.h` (the WHAT IT DOES list, lines 33-34; LIMITS, line 113; `md_report`, lines 155-168)
- Modify: `src/declassify.c` (`md_collect_ctx` and `md_collect_lc`, lines 137-224; after the `if (!fixups_off)` refusal, line 491; the LC_DYLD_INFO_ONLY room check and write, lines 746-752; the `rep` fill, lines 794-803)
- Modify: `src/script.h` (`ms_stmt`, lines 46-53), `src/script.c` (the two `has_sdk`/`sdk` assignments; the `minos set` row)
- Modify: `src/version_min.h`, `src/version_min.c` (drop `mv_add_version_min_image`'s `sdk` parameter; delete `mv_set_minos`, `mv_set_ctx`, `mv_set_lc`, `mv_minos_report`)
- Modify: `src/edit.c` (`me_log_declassify`; `me_log_minos` deleted; `me_verdict`; `case MS_VERSION_MIN`; `case MS_MINOS`; the whole `target 10.9` section, lines 542-765)
- Modify: `src/edit.h` (the report example, lines 62-77)
- Modify: `tests/mkchained.c` (`make-swiftdc`, `make-tight`)
- Modify: `compat/README.md` (the `patch_macho` table)
- Test: `tests/script_test.c`, `tests/edit_test.c`, `tests/cli_test.sh`, `tests/wrapper_test.sh`

**Interfaces:**
- Consumes: from Task 2, `minos at-most`, `mv_declare_minos`, `mv_decl_report` (`.changed`), `me_log_declared`, `MV_PLATFORM_MACCATALYST`, `mkminos add-bv`. From Task 1, `mkchained make-swift`, `mkchained tags`, `MSWIFT_CHAINED`.
- Produces:
  - `md_report` gains `int kept_version_min; uint32_t kept_minos, kept_sdk;`. The report's first line becomes `      chained fixups -> LC_DYLD_INFO_ONLY; LC_BUILD_VERSION A.B (sdk C.D) kept as LC_VERSION_MIN_MACOSX` when one was kept.
  - `fixups set classic` refusal: `ERROR: N macOS LC_BUILD_VERSION commands; refusing rather than choose whose minimum to keep`.
  - `me_verdict` gains `int changed`.
  - `target 10.9`'s derived lines, in order, whichever apply: `    fixups set classic  (LC_DYLD_CHAINED_FIXUPS present)`, `    minos at-most 10.9  (always)`, `    segment rename __DATA_CONST __DATA  (__DATA_CONST carries __objc_ sections)`, `    swift-abi set legacy  (class records carry the stable-ABI Swift tag)`. No `minimum:` line. `    nothing to do: this binary already targets 10.9` last, when nothing changed.
  - `ms_stmt` without `has_sdk`/`sdk`; `int mv_add_version_min_image(uint8_t **pbuf, size_t *psize, const char *label, int *out_added);`.
  - `mkchained make-swiftdc OUT` (make-swift's image with the segment named `__DATA_CONST`) and `mkchained make-tight OUT` (make's image with 8 bytes of header pad).
  - 19 statement lines; `minos set` is an unknown statement.

- [ ] **Step 1: Give `mkchained` the two remaining shapes**

In `tests/mkchained.c`: add `MK_SWIFTDC, MK_TIGHT` to the enum after `MK_SWIFT`. After `#define SECT_OFF …`, add

```c
#define TIGHT_SECT_OFF 0x1d8        /* make's 464 bytes of load commands, then 8 of pad */
```

Append to the header comment:

```c
 *
 * make-swiftdc is make-swift with the segment named __DATA_CONST, as an
 * Xcode 10+ link names it. make-tight is make with its first section at
 * 0x1d8, leaving 8 bytes of header pad.
```

Add `|make-swiftdc|make-tight` after `make-swift` in the header usage line and in both usage strings. In `make`, replace

```c
    uint32_t text_off = (mode == MK_NOSECT) ? 0
                      : (mode == MK_SECTPAST) ? (uint32_t)fsize + 0x1000 : SECT_OFF;
    put_sect(text, 0, "__text", "__TEXT", TEXT_VMADDR + SECT_OFF, 4, text_off);
```

with

```c
    uint32_t sect_off = (mode == MK_TIGHT) ? TIGHT_SECT_OFF : SECT_OFF;
    uint32_t text_off = (mode == MK_NOSECT) ? 0
                      : (mode == MK_SECTPAST) ? (uint32_t)fsize + 0x1000 : sect_off;
    put_sect(text, 0, "__text", "__TEXT", TEXT_VMADDR + sect_off, 4, text_off);
```

Replace the `if (mode == MK_SWIFT) {` that builds the data segment with

```c
    if (mode == MK_SWIFT || mode == MK_SWIFTDC) {
        const char *sn = (mode == MK_SWIFTDC) ? "__DATA_CONST" : "__DATA";
        data = put_seg(p, sn, TEXT_VMADDR + DATA_OFF, data_size, DATA_OFF, data_size, 2);
        put_sect(data, 0, "__objc_classlist", sn, TEXT_VMADDR + DATA_OFF, 8, DATA_OFF);
        put_sect(data, 1, "__objc_data", sn, TEXT_VMADDR + DATA_OFF + SW_CLASS, 0x80,
                 DATA_OFF + SW_CLASS);
```

(the `} else {` branch is unchanged), and change the chain branch's `if (mode == MK_SWIFT) {` to `if (mode == MK_SWIFT || mode == MK_SWIFTDC) {`. In `main`, add

```c
    if (strcmp(argv[1], "make-swiftdc") == 0) return make(argv[2], MK_SWIFTDC);
    if (strcmp(argv[1], "make-tight") == 0) return make(argv[2], MK_TIGHT);
```

- [ ] **Step 2: Write the failing `fixups set classic` tests**

In `tests/cli_test.sh`, directly after Task 2's block (after its `"minos at-most (bad version)"` assertion):

```sh

# ============================================================================
# fixups set classic keeps the declaration
# ============================================================================
# mkchained's LC_BUILD_VERSION is macOS, minos 12.0, sdk 12.0. The conversion
# keeps it as one LC_VERSION_MIN_MACOSX, just before the LC_DYLD_INFO_ONLY it
# adds: mkminos reads the values, info the order.
fk_order() { "$DRYDOCK_MACHO_REWRITE" info "$1" | sed -n 's/^LC\[[0-9]*\] //p' | tail -2; }
fk_run() { rm -f "$2"; rc=0; printf 'fixups set classic\n' | "$DRYDOCK_MACHO_REWRITE" "$1" "$2" \
    >/dev/null 2>"$T/fk.err" || rc=$?; }
"$T/mkchained" make "$T/fk_in"
fk_run "$T/fk_in" "$T/fk_out"
[ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/fk_out")" = "version-min version=12.0.0 sdk=12.0.0" ] \
    && ok "fixups set classic: a macOS LC_BUILD_VERSION is kept as LC_VERSION_MIN_MACOSX, minimum and sdk" \
    || bad "fixups keeps (values)" "rc $rc: $("$T/mkminos" show "$T/fk_out" 2>&1); $(cat "$T/fk.err")"
[ "$(fk_order "$T/fk_out")" = "LC_VERSION_MIN_MACOSX cmdsize=16
LC_DYLD_INFO_ONLY cmdsize=48" ] \
    && ok "fixups set classic: ... placed directly before the LC_DYLD_INFO_ONLY it adds" \
    || bad "fixups keeps (order)" "last two commands: $(fk_order "$T/fk_out")"
grep -qxF "      chained fixups -> LC_DYLD_INFO_ONLY; LC_BUILD_VERSION 12.0 (sdk 12.0) kept as LC_VERSION_MIN_MACOSX" \
    "$T/fk.err" \
    && ok "fixups set classic: ... and its report line says what it kept" \
    || bad "fixups keeps (report)" "$(cat "$T/fk.err")"

"$T/mkchained" make "$T/fk_vm"
"$T/mkminos" vmin "$T/fk_vm" 10.9 10.9 && "$T/mkminos" add-bv "$T/fk_vm" 1 12.0 12.0 \
    || bad "fixups keeps: fixture setup" "mkminos failed"
fk_run "$T/fk_vm" "$T/fk_vm.out"
[ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/fk_vm.out")" = "version-min version=10.9.0 sdk=10.9.0" ] \
    && ok "fixups set classic: an image that already has LC_VERSION_MIN_MACOSX gets no second one" \
    || bad "fixups keeps (has version-min)" "rc $rc: $("$T/mkminos" show "$T/fk_vm.out" 2>&1)"
grep -qxF "      chained fixups -> LC_DYLD_INFO_ONLY" "$T/fk.err" \
    && ok "fixups set classic: ... and its report line keeps nothing" \
    || bad "fixups keeps (has version-min)" "$(cat "$T/fk.err")"

"$T/mkchained" make "$T/fk_cat"
"$T/mkminos" add-bv "$T/fk_cat" 6 13.0 13.0 || bad "fixups keeps: fixture setup" "mkminos add-bv failed"
fk_run "$T/fk_cat" "$T/fk_cat.out"
[ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/fk_cat.out")" = "version-min version=12.0.0 sdk=12.0.0" ] \
    && ok "fixups set classic: a Mac Catalyst LC_BUILD_VERSION is stripped; only the macOS one is kept" \
    || bad "fixups keeps (Mac Catalyst)" "rc $rc: $("$T/mkminos" show "$T/fk_cat.out" 2>&1)"

"$T/mkchained" make "$T/fk_two"
"$T/mkminos" add-bv "$T/fk_two" 1 13.0 13.0 || bad "fixups keeps: fixture setup" "mkminos add-bv failed"
fk_run "$T/fk_two" "$T/fk_two.out"
[ "$rc" -eq 1 ] && [ ! -e "$T/fk_two.out" ] && grep -qF "2 macOS LC_BUILD_VERSION commands" "$T/fk.err" \
    && ok "fixups set classic: two macOS LC_BUILD_VERSIONs are refused (1), nothing written" \
    || bad "fixups keeps (two)" "rc $rc: $(cat "$T/fk.err")"

# FIXUPS THEN MINOS, OR MINOS THEN FIXUPS: THE SAME BYTES, with the stripped
# commands first, and with only 8 bytes of header pad.
for fo_mode in make make-lcfirst make-tight; do
    "$T/mkchained" "$fo_mode" "$T/fo_in"
    [ "$fo_mode" != make-tight ] \
        || "$DRYDOCK_MACHO_REWRITE" info "$T/fo_in" | grep -q '^header pad: 8 bytes available' \
        || bad "fixups/minos order: fixture setup" "make-tight's pad is not 8 bytes"
    rm -f "$T/fo_fm" "$T/fo_mf"
    rc=0
    printf 'fixups set classic\nminos at-most 10.9\n' | "$DRYDOCK_MACHO_REWRITE" "$T/fo_in" "$T/fo_fm" \
        >/dev/null 2>"$T/fo.err" || rc=$?
    printf 'minos at-most 10.9\nfixups set classic\n' | "$DRYDOCK_MACHO_REWRITE" "$T/fo_in" "$T/fo_mf" \
        >/dev/null 2>>"$T/fo.err" || rc=$?
    [ "$rc" -eq 0 ] && [ "$("$T/mkminos" show "$T/fo_fm")" = "version-min version=10.9.0 sdk=12.0.0" ] \
        && cmp -s "$T/fo_fm" "$T/fo_mf" \
        && ok "fixups and minos at-most, in either order, write the same bytes ($fo_mode)" \
        || bad "fixups/minos order ($fo_mode)" "rc $rc: $("$T/mkminos" show "$T/fo_fm" 2>&1) vs $("$T/mkminos" show "$T/fo_mf" 2>&1): $(cat "$T/fo.err")"
done
```

In `tests/wrapper_test.sh`, directly after the `|| bad "patch_macho converting stdout" "not the converting transcript: …"` line:

```sh

# THE DECLARATION SURVIVES. The C tool dropped mkchained's LC_BUILD_VERSION
# (macOS, 12.0, sdk 12.0) and left no version command. As install.sh runs the
# two, add_version_min then appended 10.9, sdk 10.9; now it finds 12.0 present.
[ "$("$BIN/drydock-macho-rewrite" info "$T/cfout" | grep -c '^LC\[[0-9]*\] LC_VERSION_MIN_MACOSX ')" = 1 ] \
    && "$BIN/drydock-macho-rewrite" info "$T/cfout" | grep -qxF '  version=12.0.0 sdk=12.0.0' \
    && ok "patch_macho: ... and OUT keeps the build-version's minimum and sdk as one LC_VERSION_MIN_MACOSX" \
    || bad "patch_macho keeps the declaration" "$("$BIN/drydock-macho-rewrite" info "$T/cfout" | grep -A1 VERSION)"
cp "$T/cfout" "$T/cfpipe"
run add_version_min cfpipe
[ "$rc" -eq 0 ] && "$BIN/drydock-macho-rewrite" info "$T/cfpipe" | grep -qxF '  version=12.0.0 sdk=12.0.0' \
    && ok "patch_macho then add_version_min: the binary declares the build-version's minimum and sdk, not 10.9" \
    || bad "patch_macho then add_version_min" "exit $rc: $("$BIN/drydock-macho-rewrite" info "$T/cfpipe" | grep -A1 VERSION)"
```

- [ ] **Step 3: Rewrite the `target` tests**

All edits are in `tests/cli_test.sh`'s `target 10.9` section, found by content.

(a) `tgt_empty`'s setup: replace `mts "$T/tgt_empty" "version-min set 10.9"` with `mts "$T/tgt_empty" "minos if-absent 10.9"`, and in the same `bad` line `"version-min set failed: …"` with `"minos if-absent failed: …"`.

(b) Replace the two comment lines `# ROW 1: LC_DYLD_CHAINED_FIXUPS present -> fixups set classic.` and `# ROW 2: LC_BUILD_VERSION present -> load-command delete build-version.` with

```sh
# ROW 1: LC_DYLD_CHAINED_FIXUPS present -> fixups set classic, first.
# ROW 2: always -> minos at-most 10.9, which leaves no LC_BUILD_VERSION, so
# load-command delete build-version is never derived.
```

and replace the assertion

```sh
grep -qF "    load-command delete build-version  (LC_BUILD_VERSION present)" "$T/tgt.err" \
    && ok "target: LC_BUILD_VERSION expands to load-command delete build-version" \
    || bad "target (chained)" "no build-version line: $(cat "$T/tgt.err")"
```

with

```sh
if grep -qxF "    minos at-most 10.9  (always)" "$T/tgt.err"; then
    if grep -q "^    load-command delete build-version" "$T/tgt.err"; then
        bad "target (chained)" "derived load-command delete build-version: $(cat "$T/tgt.err")"
    else
        ok "target: minos at-most 10.9 is derived, and load-command delete build-version never is"
    fi
else
    bad "target (chained)" "no minos at-most line: $(cat "$T/tgt.err")"
fi
```

(c) Delete from the comment `# The inverse, so the detection is not "always emit it": a fixture with no` through the `fi` that closes the `tgt_nobv` assertion. Its claim is now universal and (b) asserts it.

(d) Replace from `# ROW 3: no LC_VERSION_MIN_MACOSX -> version-min set 10.9. strip_version_min` through the `fi` that closes the `tgt_hasvm` assertion with

```sh
# An image that declares nothing gets version-min 10.9, sdk 10.9.
build_main "$T/tgt_novm"
"$T/mkminos" none "$T/tgt_novm" || bad "target: fixture setup" "mkminos none failed"
tgt_run "$T/tgt_novm" "$T/tgt_novm.out" || bad "target (none declared)" "$(cat "$T/tgt.err")"
grep -A1 -xF '    minos at-most 10.9  (always)' "$T/tgt.err" \
    | grep -qxF '      none -> version-min 10.9; sdk 10.9 written' \
    && ok "target: an image declaring nothing gets version-min 10.9, sdk 10.9, and says so" \
    || bad "target (none declared)" "$(cat "$T/tgt.err")"
[ "$("$T/mkminos" show "$T/tgt_novm.out")" = "version-min version=10.9.0 sdk=10.9.0" ] \
    && ok "target: ... and the written image declares it" \
    || bad "target (none declared)" "$("$T/mkminos" show "$T/tgt_novm.out" 2>&1)"
```

(e) Replace from `# The declared minimum; mkminos writes and reads each premise.` up to (not including) `# TARGET NEVER COUNTS AS UNMATCHED.` with

```sh
# THE DECLARED MINIMUM, through the derived minos at-most 10.9; mkminos writes
# and reads each premise.
tgt_minos() { grep -A1 -xF '    minos at-most 10.9  (always)' "$T/tgt.err" | sed -n 2p; }

# The reproduction: this host's own toolchain, asked for 10.12.
printf 'int main(void){return 0;}\n' >"$T/min1012.c"
"$CC" -arch x86_64 -mmacosx-version-min=10.12 "$T/min1012.c" -o "$T/tgt_1012" \
    || bad "target: fixture setup" "could not build for 10.12"
case $("$T/mkminos" show "$T/tgt_1012" || true) in
    *version=10.12.0*|*minos=10.12.0*) ;;
    *) bad "target: fixture setup" "tgt_1012 does not declare 10.12: $("$T/mkminos" show "$T/tgt_1012" || true)" ;;
esac
tgt_run "$T/tgt_1012" "$T/tgt_1012.out" || bad "target (10.12 build)" "$(cat "$T/tgt.err")"
if grep -qF "  target 10.9" "$T/tgt.err"; then
    if grep -q "nothing to do" "$T/tgt.err"; then
        bad "target (10.12 build)" "said nothing to do for a binary declaring 10.12: $(cat "$T/tgt.err")"
    else
        ok "target: a binary declaring 10.12 is never 'nothing to do'"
    fi
else
    bad "target (10.12 build)" "no report, so the absent 'nothing to do' proves nothing: $(cat "$T/tgt.err")"
fi
"$T/mkminos" show "$T/tgt_1012.out" | grep -q '^version-min version=10\.9\.0 ' \
    && ok "target: ... and the written binary declares 10.9" \
    || bad "target (10.12 build)" "$("$T/mkminos" show "$T/tgt_1012.out" 2>&1)"

build_main "$T/tgt_vm12"
"$T/mkminos" vmin "$T/tgt_vm12" 10.12 10.13 || bad "target: fixture setup" "mkminos vmin failed"
tgt_run "$T/tgt_vm12" "$T/tgt_vm12.out" || bad "target (version-min 10.12)" "$(cat "$T/tgt.err")"
[ "$(tgt_minos)" = "      version-min 10.12 -> 10.9; sdk 10.13 kept" ] \
    && [ "$("$T/mkminos" show "$T/tgt_vm12.out")" = "version-min version=10.9.0 sdk=10.13.0" ] \
    && ok "target: a version-min above 10.9 is lowered, its sdk kept, and the report says so" \
    || bad "target (version-min 10.12)" "report '$(tgt_minos)': $("$T/mkminos" show "$T/tgt_vm12.out" 2>&1)"

for tgt_low in 10.8 10.9 10.9.5; do
    build_main "$T/tgt_low"
    "$T/mkminos" vmin "$T/tgt_low" "$tgt_low" 10.9 || bad "target: fixture setup" "mkminos vmin $tgt_low failed"
    tgt_run "$T/tgt_low" "$T/tgt_low.out" || bad "target (version-min $tgt_low)" "$(cat "$T/tgt.err")"
    [ "$(tgt_minos)" = "      version-min $tgt_low, at or below 10.9: kept; sdk 10.9 kept" ] \
        && ok "target: version-min $tgt_low is at or below 10.9, and the report says so" \
        || bad "target (version-min $tgt_low)" "report '$(tgt_minos)'"
    grep -qxF "    nothing to do: this binary already targets 10.9" "$T/tgt.err" \
        && cmp -s "$T/tgt_low" "$T/tgt_low.out" \
        && ok "target: ... nothing to do, and the image is written byte for byte" \
        || bad "target (version-min $tgt_low)" "$(cat "$T/tgt.err")"
done

build_main "$T/tgt_bv12"
"$T/mkminos" bv "$T/tgt_bv12" 1 12.0 12.3 || bad "target: fixture setup" "mkminos bv failed"
tgt_run "$T/tgt_bv12" "$T/tgt_bv12.out" || bad "target (build-version 12.0)" "$(cat "$T/tgt.err")"
[ "$(tgt_minos)" = "      build-version 12.0 -> version-min 10.9; sdk 12.3 carried over" ] \
    && [ "$("$T/mkminos" show "$T/tgt_bv12.out")" = "version-min version=10.9.0 sdk=12.3.0" ] \
    && ok "target: build-version 12.0 becomes version-min 10.9, sdk 12.3 carried over, and says so" \
    || bad "target (build-version 12.0)" "report '$(tgt_minos)': $("$T/mkminos" show "$T/tgt_bv12.out" 2>&1)"
if [ -n "$(tgt_minos)" ]; then
    if grep -q "^    load-command delete build-version" "$T/tgt.err"; then
        bad "target (build-version 12.0)" "derived load-command delete build-version: $(cat "$T/tgt.err")"
    else
        ok "target: ... with no load-command delete build-version derived"
    fi
else
    bad "target (build-version 12.0)" "no minos report, so the absent delete proves nothing"
fi

build_main "$T/tgt_bv0"
"$T/mkminos" bv "$T/tgt_bv0" 1 12.0 0.0 || bad "target: fixture setup" "mkminos bv failed"
tgt_run "$T/tgt_bv0" "$T/tgt_bv0.out" || bad "target (build-version sdk 0)" "$(cat "$T/tgt.err")"
[ "$(tgt_minos)" = "      build-version 12.0 -> version-min 10.9; sdk 0.0 carried over" ] \
    && [ "$("$T/mkminos" show "$T/tgt_bv0.out")" = "version-min version=10.9.0 sdk=0.0.0" ] \
    && ok "target: a build-version sdk of 0.0 is carried over too" \
    || bad "target (build-version sdk 0)" "report '$(tgt_minos)': $("$T/mkminos" show "$T/tgt_bv0.out" 2>&1)"

for tgt_bvlow in 10.7 10.9 10.9.5; do
    case $tgt_bvlow in 10.9.5) tgt_want=10.9.5 ;; *) tgt_want=$tgt_bvlow.0 ;; esac
    build_main "$T/tgt_bvlow"
    "$T/mkminos" bv "$T/tgt_bvlow" 1 "$tgt_bvlow" 10.10 || bad "target: fixture setup" "mkminos bv $tgt_bvlow failed"
    tgt_run "$T/tgt_bvlow" "$T/tgt_bvlow.out" || bad "target (build-version $tgt_bvlow)" "$(cat "$T/tgt.err")"
    [ "$(tgt_minos)" = "      build-version $tgt_bvlow -> version-min $tgt_bvlow; sdk 10.10 carried over" ] \
        && [ "$("$T/mkminos" show "$T/tgt_bvlow.out")" = "version-min version=$tgt_want sdk=10.10.0" ] \
        && ok "target: build-version $tgt_bvlow is carried over as version-min $tgt_bvlow" \
        || bad "target (build-version $tgt_bvlow)" "report '$(tgt_minos)': $("$T/mkminos" show "$T/tgt_bvlow.out" 2>&1)"
done

"$T/mkchained" make "$T/tgt_chmin"
tgt_run "$T/tgt_chmin" "$T/tgt_chmin.out" || bad "target (chained minimum)" "$(cat "$T/tgt.err")"
grep -qxF "      chained fixups -> LC_DYLD_INFO_ONLY; LC_BUILD_VERSION 12.0 (sdk 12.0) kept as LC_VERSION_MIN_MACOSX" \
    "$T/tgt.err" \
    && [ "$(tgt_minos)" = "      version-min 12.0 -> 10.9; sdk 12.0 kept" ] \
    && ok "target: a chained image's build-version is kept by fixups, then lowered by minos" \
    || bad "target (chained minimum)" "$(cat "$T/tgt.err")"
"$T/mkminos" show "$T/tgt_chmin.out" | grep -qxF "version-min version=10.9.0 sdk=12.0.0" \
    && ok "target: ... and the chained image's sdk 12.0 survives the conversion" \
    || bad "target (chained minimum)" "$("$T/mkminos" show "$T/tgt_chmin.out" 2>&1)"
tgt_first=$(grep '^    [a-z]' "$T/tgt.err" | head -1)
[ "$tgt_first" = "    fixups set classic  (LC_DYLD_CHAINED_FIXUPS present)" ] \
    && ok "target: ... and fixups set classic is the first derived line" \
    || bad "target (chained minimum)" "first derived line: '$tgt_first'"

# THE SWIFT TAG IS READ AFTER fixups set classic. On a chained image the class
# records' pointers are chain links until the conversion lowers them.
"$T/mkchained" make-swift "$T/tgt_chsw"
tgt_run "$T/tgt_chsw" "$T/tgt_chsw.out" || bad "target (chained Swift)" "$(cat "$T/tgt.err")"
grep -qxF "    swift-abi set legacy  (class records carry the stable-ABI Swift tag)" "$T/tgt.err" \
    && [ "$("$T/mkchained" tags "$T/tgt_chsw.out")" = "class 1
meta 1" ] \
    && ok "target: a chained Swift image is retagged, detected after fixups set classic" \
    || bad "target (chained Swift)" "tags $("$T/mkchained" tags "$T/tgt_chsw.out" | tr '\n' ' '): $(cat "$T/tgt.err")"

"$T/mkchained" make-swiftdc "$T/tgt_all"
tgt_run "$T/tgt_all" "$T/tgt_all.out" || bad "target (all four)" "$(cat "$T/tgt.err")"
tgt_o1=$(tgt_at "$T/tgt.err" "^    fixups set classic  ")
tgt_o2=$(tgt_at "$T/tgt.err" "^    minos at-most 10.9  ")
tgt_o3=$(tgt_at "$T/tgt.err" "^    segment rename __DATA_CONST __DATA  ")
tgt_o4=$(tgt_at "$T/tgt.err" "^    swift-abi set legacy  ")
[ -n "$tgt_o1" ] && [ -n "$tgt_o2" ] && [ -n "$tgt_o3" ] && [ -n "$tgt_o4" ] \
    && [ "$tgt_o1" -lt "$tgt_o2" ] && [ "$tgt_o2" -lt "$tgt_o3" ] && [ "$tgt_o3" -lt "$tgt_o4" ] \
    && ok "target: the four lines are derived in the edit script's order, minos at-most second" \
    || bad "target (all four)" "order '$tgt_o1' '$tgt_o2' '$tgt_o3' '$tgt_o4': $(cat "$T/tgt.err")"

# THE PUBLISHED EDIT SCRIPT. README.md prints target 10.9's expansion as a script;
# run by hand it must write target's own bytes, thin and fat. The thin image
# needs all four lines; the fat one adds a plain chained slice, where the
# rename and the retag are no-ops.
printf 'fixups set classic\nminos at-most 10.9\nsegment rename __DATA_CONST __DATA\nswift-abi set legacy\n' \
    >"$T/tgt_script.edits"
rc=0; "$DRYDOCK_MACHO_REWRITE" "$T/tgt_all" "$T/tgt_all.hand" <"$T/tgt_script.edits" \
    >/dev/null 2>"$T/tgt_script.err" || rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/tgt_all.hand" "$T/tgt_all.out" && ! cmp -s "$T/tgt_all" "$T/tgt_all.out" \
    && ok "target: the published edit script, run by hand, writes target's own bytes (thin)" \
    || bad "target (edit script, thin)" "rc $rc, or the bytes differ: $(cat "$T/tgt_script.err")"
"$T/mkchained" make "$T/script_s1"
"$BIN/makefat" "$T/script_fat" "$T/tgt_all" 0x1000007 3 12 "$T/script_s1" 0x100000c 0 12
tgt_run "$T/script_fat" "$T/script_fat.out" || bad "target (edit script, fat)" "$(cat "$T/tgt.err")"
rc=0; "$DRYDOCK_MACHO_REWRITE" "$T/script_fat" "$T/script_fat.hand" <"$T/tgt_script.edits" \
    >/dev/null 2>"$T/tgt_script.err" || rc=$?
[ "$rc" -eq 0 ] && cmp -s "$T/script_fat.hand" "$T/script_fat.out" \
    && ! cmp -s "$T/script_fat" "$T/script_fat.out" \
    && ok "target: ... and on a fat file" \
    || bad "target (edit script, fat)" "rc $rc, or the bytes differ: $(cat "$T/tgt_script.err")"

```

(f) Replace the comment

```sh
# TARGET NEVER COUNTS AS UNMATCHED. On a chained image the expansion derives
# both `fixups set classic` and `load-command delete build-version` -- and
# the first strips LC_BUILD_VERSION itself, so the second finds nothing left
# to do. "This binary already targets 10.9 correctly" is a correct answer
# for a profile, so that is not a miss, and it must not refuse by default.
```

with

```sh
# TARGET NEVER COUNTS AS UNMATCHED. Each line it derives has work on the image
# in front of it, and minos cannot miss, so nothing is reported as unmatched
# and nothing refuses by default.
```

and in the `# THE OTHER SIDE OF THAT` comment replace the line

```sh
# added -- the expansion's `fixups set classic` strips LC_BUILD_VERSION, so by
```

with

```sh
# added -- the expansion leaves no LC_BUILD_VERSION, so by
```

(g) In the `# A DERIVED STATEMENT GETS THE ANSWER THE EXPLICIT ONE GETS` comment, replace

```sh
# `version-min set 10.9` grows the header, as the explicit statement does;
```

with

```sh
# `minos at-most 10.9` grows the header, as the explicit statement does;
```

and replace

```sh
# ABSENT too. On a host whose linker emits one, the expansion would derive a
# `load-command delete build-version` that runs first and frees at least 24
# bytes -- more than the 16 LC_VERSION_MIN_MACOSX needs -- so the run would
```

with

```sh
# ABSENT too. On a host whose linker emits one, minos at-most would convert
# it, freeing at least 24 bytes -- more than the 16 LC_VERSION_MIN_MACOSX
# needs -- so the run would
```

(h) In the fat block, replace

```sh
fat_tgt_min=$(grep -c "^    minimum: " "$T/fat_tgt.err" || true)
[ "$fat_tgt_min" -eq 2 ] && ok "target: ... and each slice names its own minimum" \
    || bad "target fat" "expected 2 minimum lines, got $fat_tgt_min: $(cat "$T/fat_tgt.err")"
```

with

```sh
fat_tgt_min=$(grep -c "^    minos at-most 10.9  (always)$" "$T/fat_tgt.err" || true)
[ "$fat_tgt_min" -eq 2 ] && ok "target: ... and each slice derives its own minos at-most 10.9" \
    || bad "target fat" "expected 2 minos lines, got $fat_tgt_min: $(cat "$T/fat_tgt.err")"
```

(i) Delete the whole `minos set` section, from its header block (`# minos set` between two `# ====` lines) through the assertion ending `"version-min set (present)" "rc $rc: $("$T/mkminos" show "$T/ms_vmset.out" 2>&1)"`.

(j) In the capabilities block, change 20 to 19 in the count assertion, and replace the `"capabilities: minos set is advertised"` assertion with

```sh
if echo "$caps" | grep -qxF "statement minos at-most 1"; then
    if echo "$caps" | grep -qxF "statement minos set 1"; then
        bad "capabilities statements" "minos set is still advertised"
    else
        ok "capabilities: minos set is no longer advertised"
    fi
else
    bad "capabilities statements" "no minos at-most line, so the absent minos set proves nothing"
fi
```

In `tests/script_test.c`: delete `test_minos_set_takes_a_version` and its registration; delete the `CHECK(ms_disturbs(MS_MINOS, MS_SET) == MREL_NONE, …)` assertion; change 20 to 19 in `test_capabilities_table_round_trips`; add before `main`

```c
static void test_retired_minimum_statements_are_unknown(void) {
    static const char *lines[] = { "minos set 10.9\n", "minos at-mots 10.9\n" };
    static const char *said[] = { "unknown statement 'minos set'",
                                  "unknown statement 'minos at-mots'" };
    for (size_t i = 0; i < sizeof lines / sizeof *lines; i++) {
        ms_script s; char err[256] = {0};
        CHECK(ms_parse(lines[i], strlen(lines[i]), &s, err, sizeof err) == -1 &&
              strstr(err, said[i]) != NULL,
              "%s is refused as %s, with no message of its own (got: %s)", lines[i], said[i], err);
    }
}
```

and register it after `test_minos_at_most_and_if_absent_take_a_version();`.

In `tests/edit_test.c`: delete `test_minos_set_rewrites_the_declared_minimum_in_place`, `test_minos_set_with_nothing_declared_is_a_miss` and `test_fat_minos_set_matches_in_any_slice`, and their registrations. Replace the body of `test_target_with_both_commands_lets_version_min_decide` from `CHECK(strstr(g_log, "    minimum: …` onward (keep the setup and the `rc == 0` check) with

```c
    CHECK(strstr(g_log, "    minos at-most 10.9  (always)\n"
                        "      version-min 10.12 -> 10.9; sdk 10.13 kept; build-version 12.0 removed\n")
          != NULL,
          "target, both commands: the version-min decides, and the build-version's removal is named "
          "(log: %s)", g_log);
    CHECK(count_lc(out, LC_BUILD_VERSION, NULL) == 0 &&
          lc_word(out, LC_VERSION_MIN_MACOSX, 2) == 0x000A0900 &&
          lc_word(out, LC_VERSION_MIN_MACOSX, 3) == 0x000A0D00,
          "target, both commands: build-version gone, version-min 10.9 with sdk 10.13 kept");
    rm_dir();
}
```

- [ ] **Step 4: Run them to make sure they fail**

Run the build-and-check sequence (only the tests changed). Expected: `script_test` fails "the statement table has 19 rows" and "minos set 10.9 is refused"; `edit_test` fails "target, both commands". Then `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh /private/tmp/build/schmonz/drydock-native 2>&1 | grep -E '^(PASS|FAIL)' | grep -E 'fixups|target|capabilities'`. Expected:
- FAIL: "fixups keeps (values)", "(order)" and "(report)" (the conversion leaves no version command); "fixups keeps (Mac Catalyst)" (`none`); "fixups keeps (two)" (exit 0).
- FAIL: "fixups/minos order" for all three modes: fixups-first ends with a version-min 10.9 whose sdk is 10.9, appended after `LC_DYLD_INFO_ONLY`.
- FAIL: every rewritten `target` assertion that names `minos at-most` or the kept line, "a chained Swift image is retagged", "derived in the edit script's order", both edit-script assertions, the fat minos count, "minos set is no longer advertised", "exactly 19".
- PASS already, guarding behaviour this task keeps: "an image that already has LC_VERSION_MIN_MACOSX gets no second one" and its report line, and the 10.12 reproduction.
- wrapper_test: both new assertions FAIL (no `LC_VERSION_MIN_MACOSX` in OUT; 10.9 after `add_version_min`).

- [ ] **Step 5: Write `fixups set classic`'s half**

`src/declassify.c`: add `#include "version_min.h"   /* MV_PLATFORM_MACOS */` after `#include "uleb.h"`. In `struct md_collect_ctx`, after `int has_dyld_info_only;`, add

```c
    int has_version_min;
    int n_macos_bv;
    uint32_t bv_minos, bv_sdk;   /* the macOS LC_BUILD_VERSION's */
```

In `md_collect_lc`, replace

```c
    } else if (lc->cmd == LC_BUILD_VERSION) {
        if (md_remove_push(ctx, (uint8_t *)lc, lc->cmdsize, lc->cmd)) return 1;
    }
```

with

```c
    } else if (lc->cmd == LC_BUILD_VERSION) {
        const struct mc_build_version *bv = (const struct mc_build_version *)lc;
        if (lc->cmdsize >= sizeof *bv && bv->platform == MV_PLATFORM_MACOS &&
            ctx->n_macos_bv++ == 0) {
            ctx->bv_minos = bv->minos;
            ctx->bv_sdk = bv->sdk;
        }
        if (md_remove_push(ctx, (uint8_t *)lc, lc->cmdsize, lc->cmd)) return 1;
    } else if (lc->cmd == LC_VERSION_MIN_MACOSX) {
        ctx->has_version_min = 1;
    }
```

Directly after `    if (!fixups_off) { fprintf(stderr, "No chained fixups found\n"); return MDCL_REFUSED; }`:

```c
    if (cctx.n_macos_bv > 1) {
        fprintf(stderr, "ERROR: %d macOS LC_BUILD_VERSION commands; refusing rather than "
                        "choose whose minimum to keep\n", cctx.n_macos_bv);
        return MDCL_REFUSED;
    }
    int keep = cctx.n_macos_bv == 1 && !cctx.has_version_min;
    uint32_t keep_len = keep ? (uint32_t)sizeof(struct version_min_command) : 0;
```

Replace

```c
    if (lcmds_end + 48 > first_data) {
        fprintf(stderr, "ERROR: No room for LC_DYLD_INFO_ONLY (need 48 bytes, have %ld)\n",
                first_data - lcmds_end);
        goto refuse;
    }
```

with

```c
    if (lcmds_end + keep_len + 48 > first_data) {
        fprintf(stderr, "ERROR: No room for LC_DYLD_INFO_ONLY (need %u bytes, have %ld)\n",
                48 + keep_len, first_data - lcmds_end);
        goto refuse;
    }
    if (keep) {
        struct version_min_command *vm = (struct version_min_command *)lcmds_end;
        vm->cmd = LC_VERSION_MIN_MACOSX;
        vm->cmdsize = keep_len;
        vm->version = cctx.bv_minos;
        vm->sdk = cctx.bv_sdk;
        lcmds_end += keep_len;
        hdr->ncmds++;
        hdr->sizeofcmds += keep_len;
    }
```

In the `if (rep) {` block, after `rep->n_stripped = cctx.n_remove;`:

```c
        rep->kept_version_min = keep;
        rep->kept_minos = cctx.bv_minos;
        rep->kept_sdk = cctx.bv_sdk;
```

`src/declassify.h`: after the bullet ending `LC_BUILD_VERSION (10.9's dyld understands none of them);`, add

```c
 *   - keeps a macOS LC_BUILD_VERSION's minos and sdk as an LC_VERSION_MIN_MACOSX,
 *     written just before the new LC_DYLD_INFO_ONLY, unless the image already
 *     has one; two macOS LC_BUILD_VERSIONs are refused;
```

In LIMITS, change `48 bytes of header pad for the new LC_DYLD_INFO_ONLY` to `48 bytes of header pad for the new LC_DYLD_INFO_ONLY (64 with a kept LC_VERSION_MIN_MACOSX)`. In `md_report`, after `int n_stripped;`:

```c
    int      kept_version_min; /* a macOS LC_BUILD_VERSION was kept as ... */
    uint32_t kept_minos, kept_sdk; /* ... an LC_VERSION_MIN_MACOSX with these */
```

`src/edit.c`, `me_log_declassify`: change the first two lines of its body to

```c
    char k[16], c1[32], c2[32], c3[32], c4[32], v1[16], v2[16];
    me_say(log, "      chained fixups -> LC_DYLD_INFO_ONLY");
    if (r->kept_version_min) {
        mv_format_version(r->kept_minos, v1);
        mv_format_version(r->kept_sdk, v2);
        me_say(log, "; LC_BUILD_VERSION %s (sdk %s) kept as LC_VERSION_MIN_MACOSX", v1, v2);
    }
    me_say(log, "\n");
```

- [ ] **Step 6: Delete `minos set` and the hidden sdk channel**

`src/script.c`: delete the `minos set` row (and the ` \` that now ends the `import` row stays; the `at-most` row keeps its ` \`). Delete `stmts[n_stmts].has_sdk = 0;` and `stmts[n_stmts].sdk = 0;`. `src/script.h`: change `ms_stmt` to

```c
typedef struct { int kind, op; const char *a, *b, *c; int line; } ms_stmt;
```

and delete the comment's last sentence (`` `target` sets `has_sdk` and `sdk` on a derived `version-min set` to carry an `LC_BUILD_VERSION`'s sdk over. ``).

`src/version_min.h`: change `mv_add_version_min_image`'s declaration to `int mv_add_version_min_image(uint8_t **pbuf, size_t *psize, const char *label, int *out_added);` and in its comment change "10.9, with `sdk`, to the image" to "10.9, sdk 10.9, to the image". Delete `mv_minos_report`, its comment, and `mv_set_minos`'s declaration and comment. Keep `MV_PLATFORM_MACOS`, `MV_10_9` and `mv_format_version`.

`src/version_min.c`: drop the `uint32_t sdk` parameter from `mv_add_version_min_image`'s definition and write `vm->sdk = MV_10_9;`; in `mv_add_version_min` the call becomes `mv_add_version_min_image(&buf, &fsize, path, &added)`. Delete `struct mv_set_ctx`, `mv_set_lc` and `mv_set_minos`.

`src/edit.c`: delete `me_log_minos`. In `me_verdict`, change the `renamed` comment to `/* this statement's segment-rename or import-redirect count, likewise */` and add after `int missed;`:

```c
    int      changed;   /* written by minos: whether it changed the slice */
```

In `case MS_VERSION_MIN`, replace from `uint32_t sdk = st->has_sdk ? st->sdk : MV_10_9;` through `return rc;` with

```c
        int rc = mv_add_version_min_image(pbuf, psize, path, &added);
        if (rc == 0 && added)
            me_say(log, "      appended LC_VERSION_MIN_MACOSX 10.9\n");
        return rc;
```

Replace `case MS_MINOS` with

```c
    case MS_MINOS: {
        uint32_t want = 0, mask = 0;
        mi_image im;
        mv_decl_report d;
        if (st->op != MS_AT_MOST && st->op != MS_IF_ABSENT) goto unknown;
        if (ms_parse_version(st->a, &want, &mask) != 0) goto unknown;
        if (me_view(*pbuf, *psize, &im, path, log) != 0) return MR_REFUSED;
        int rc = mv_declare_minos(pbuf, psize, path,
                                  st->op == MS_AT_MOST ? MV_AT_MOST : MV_IF_ABSENT,
                                  want, mask, &d);
        if (rc != 0) return rc;
        me_log_declared(log, &d, st->a);
        v->changed = d.changed;
        return 0;
    }
```

- [ ] **Step 7: Rewrite `target 10.9` as four detected steps**

`src/edit.c`: replace from `#define ME_TARGET_MAX 6` through the closing `}` of `me_expand_10_9` with

```c
#define ME_TARGET_MAX 4   /* the steps of target 10.9's edit script, in README.md's order */

/* One derived statement, and the finding that produced it -- the report
 * carries both, because "why is this script doing that?" is exactly the
 * question a profile line raises. */
typedef struct { ms_stmt stmt; const char *why; } me_derived;

/* What the load commands say about this image. */
typedef struct { int chained, dataconst_objc; } me_seen;

static int me_target_lc(const struct load_command *lc, void *ctx_) {
    me_seen *f = (me_seen *)ctx_;
    if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) { f->chained = 1; return 0; }
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
        /* segname/sectname are 16 bytes and need not be NUL-terminated, which
         * is why these are strncmp and not strcmp. mi_wrap has already proved
         * cmdsize covers the section array nsects claims, so this walk stays
         * inside the command. A __DATA_CONST with no __objc_ section is left
         * alone: what breaks on 10.9 is the Objective-C runtime not finding
         * its metadata (src/segname.h), and a segment carrying none has none
         * to hide. */
        if (strncmp(sc->segname, "__DATA_CONST", MSEG_NAME_MAX) != 0) return 0;
        const struct section_64 *sect = (const struct section_64 *)(sc + 1);
        for (uint32_t k = 0; k < sc->nsects; k++)
            if (strncmp(sect[k].sectname, "__objc_", 7) == 0) f->dataconst_objc = 1;
    }
    return 0;
}

/* Step `step` of the 10.9 profile, asked of the image as the steps before it
 * left it: 1, with `d` filled, when this image needs that step, else 0.
 *
 * `fixups set classic` comes first because nothing can grow the header while
 * the image still has chained fixups (src/grow.h), and every step after it
 * sees the __LINKEDIT, the header pad and the class-record pointers it left.
 *
 * NEVER dylib or rpath work: no tool can guess which stub dylib you meant,
 * and that is the dominant real workload. A profile that guessed would be
 * wrong silently, which is the failure class this toolkit exists to remove.
 *
 * Each derived statement carries the `target` line's own source line, which
 * is where it came from and the only line anyone wrote.
 *
 * `im` is a view, and is not written. */
static int me_expand_10_9(const mi_image *im, int step, me_derived *d, int line) {
    me_seen f;
    memset(&f, 0, sizeof f);
    memset(d, 0, sizeof *d);
    mi_each_lc(im, me_target_lc, &f);
    d->stmt.line = line;
    switch (step) {
    case 0:
        if (!f.chained) return 0;
        d->stmt.kind = MS_FIXUPS; d->stmt.op = MS_SET; d->stmt.a = "classic";
        d->why = "LC_DYLD_CHAINED_FIXUPS present";
        return 1;
    case 1:
        d->stmt.kind = MS_MINOS; d->stmt.op = MS_AT_MOST; d->stmt.a = "10.9";
        d->why = "always";
        return 1;
    case 2:
        if (!f.dataconst_objc) return 0;
        d->stmt.kind = MS_SEGMENT; d->stmt.op = MS_RENAME;
        d->stmt.a = "__DATA_CONST"; d->stmt.b = "__DATA";
        d->why = "__DATA_CONST carries __objc_ sections";
        return 1;
    case 3:
        if (mswift_stable_tagged_image(im) <= 0) return 0;
        d->stmt.kind = MS_SWIFT_ABI; d->stmt.op = MS_SET; d->stmt.a = "legacy";
        d->why = "class records carry the stable-ABI Swift tag";
        return 1;
    }
    return 0;
}
```

Keep `me_log_derived` as it is. Replace `me_target`, and the comment above it, with

```c
/* Run the profile's steps in order, at this position, each derived from the
 * image the step before it left. Returns 0, or the first derived statement's
 * own MR_REFUSED/MR_FAIL -- which me_statements then reports against the
 * `target` line, since that is the line the operator wrote.
 *
 * A derived statement NEVER counts as unmatched: "this binary already
 * targets 10.9 correctly" is a correct answer for a profile, unlike for an
 * explicit operation. Two things enforce that together -- allow_unmatched is
 * SET in the script this runs under, and the verdict is not taken at all
 * (decide is 0), so no "matched nothing" line is printed either. Writing
 * `target 10.9` AND an explicit statement it would have derived is the other
 * side of this, and is not special-cased: the explicit one is redundant, and
 * the default refusal flags it. */
static int me_target(uint8_t **pbuf, size_t *psize, const char *path,
                     const ms_script *s, const ms_stmt *st, FILE *log,
                     unsigned *disturbed) {
    ms_script sub = *s;
    int step, changed = 0;
    sub.allow_unmatched = 1;
    for (step = 0; step < ME_TARGET_MAX; step++) {
        me_derived d;
        mi_image im;
        mr_hits hits;
        int renamed = 0, rc;
        me_verdict v;
        if (me_view(*pbuf, *psize, &im, path, log) != 0) return MR_REFUSED;
        if (!me_expand_10_9(&im, step, &d, st->line)) continue;
        memset(&hits, 0, sizeof hits);
        v.hits = &hits; v.renamed = &renamed; v.decide = 0; v.missed = 0; v.changed = 1;
        me_log_derived(log, &d);
        /* Each DERIVED statement declares for itself, which is what makes
         * the `target` row's own MREL_NONE correct rather than a hole. */
        uint32_t first_before = mg_first_sect_off(*pbuf, *psize);
        rc = me_apply(pbuf, psize, path, &sub, &d.stmt, log, &v);
        if (rc != 0) return rc;
        me_note_disturbed(disturbed, &d.stmt, first_before, mg_first_sect_off(*pbuf, *psize));
        changed |= v.changed;
    }
    if (!changed)
        me_say(log, "    nothing to do: this binary already targets 10.9\n");
    return 0;
}
```

`src/edit.h`: replace the example block and the three lines after it (through `derives \`dylib\` or \`rpath\` work, and \`fixups set classic\` comes first within it.`) with

```c
 *       target 10.9
 *         fixups set classic  (LC_DYLD_CHAINED_FIXUPS present)
 *           chained fixups -> LC_DYLD_INFO_ONLY; LC_BUILD_VERSION 12.0 (sdk 12.3) kept as LC_VERSION_MIN_MACOSX
 *         minos at-most 10.9  (always)
 *           version-min 12.0 -> 10.9; sdk 12.3 kept
 *
 * -- each line derived from the image as the lines before it left it, and
 * "nothing to do: this binary already targets 10.9" when none of them changed
 * it. The expansion never derives `dylib` or `rpath` work, and `fixups set
 * classic` comes first within it.
```

(keep the following `spec: src/grow.h …` line).

- [ ] **Step 8: Record `patch_macho`'s new difference**

`compat/README.md`, in the `## \`patch_macho\`: the differences, and what holds each one` table, add as its last row:

```markdown
| **a macOS `LC_BUILD_VERSION` is kept as an `LC_VERSION_MIN_MACOSX`** carrying its minimum and sdk, just before the new `LC_DYLD_INFO_ONLY`; the C tool dropped it and left no version command. Run before `add_version_min`, as install.sh runs them, the binary ends declaring the build-version's minimum and sdk, where the C tools left 10.9 and sdk 10.9. On 10.9 any sdk at or above 10.9 behaves identically (`docs/minimum-os-version.md`, "Every sdk check in 10.9.5's own code"). The kept command needs 16 more bytes of header pad, and two macOS `LC_BUILD_VERSION`s are refused | "patch_macho: ... and OUT keeps the build-version's minimum and sdk as one LC_VERSION_MIN_MACOSX", "patch_macho then add_version_min: the binary declares the build-version's minimum and sdk, not 10.9"; `tests/cli_test.sh`'s "fixups set classic: …" block |
```

- [ ] **Step 9: Run the tests and make sure they pass**

Run the build-and-check sequence (all three binaries absent from the OK list), then the full test command. Expected: 22 tests, all pass, `chained_fixups` skips. Then check nothing still names the deleted pieces, with positive controls:

```sh
git grep -n 'has_sdk\|mv_set_minos\|mv_minos_report\|me_log_minos\|    minimum: ' -- src cli tests   # prints nothing
git grep -c 'mv_declare_minos' -- src/edit.c                                                     # nonzero
git grep -n '"minos set\|minos set 10' -- tests                                                   # only script_test's retired-statement pin
```

- [ ] **Step 10: Mutation-prove it**

1. In `md_declassify_buf`, change `int keep = cctx.n_macos_bv == 1 && !cctx.has_version_min;` to `int keep = 0;`. Expected: "fixups keeps (values)", "(order)", "(report)", all three "fixups/minos order" rows, "the chained image's sdk 12.0 survives", and the two new wrapper assertions fail.
2. Move the `if (keep) { … }` block to after `hdr->sizeofcmds += 48;` (and write it at `lcmds_end + 48`). Expected: "fixups keeps (order)" and all three "fixups/minos order" rows fail.
3. Delete `&& !cctx.has_version_min`. Expected: "gets no second one" fails.
4. Delete the `if (cctx.n_macos_bv > 1) { … }` block. Expected: "two macOS LC_BUILD_VERSIONs are refused" fails.
5. In `me_target`, move `if (me_view(…)) return MR_REFUSED;` and a single `me_view` above the loop so every step is asked of the input image (declare `mi_image im;` outside the loop and delete the in-loop `me_view`). Expected: "a chained Swift image is retagged, detected after fixups set classic" and "the four lines are derived in the edit script's order" fail.
6. Change `changed |= v.changed;` to `changed |= 0;`. Expected: "a binary declaring 10.12 is never 'nothing to do'" fails.
7. In `case MS_MINOS`, delete `v->changed = d.changed;`. Expected: the `tgt_low` loop's "nothing to do, and the image is written byte for byte" and `tgt_empty`'s "nothing to do" assertion fail.

- [ ] **Step 11: Commit**

```bash
git add src/declassify.h src/declassify.c src/script.h src/script.c \
        src/version_min.h src/version_min.c src/edit.h src/edit.c \
        tests/mkchained.c tests/script_test.c tests/edit_test.c tests/cli_test.sh \
        tests/wrapper_test.sh compat/README.md
git commit -F - <<'EOF'
feat(target): published as its edit script, detected step by step

fixups set classic stripped LC_BUILD_VERSION with the chained-fixups
commands and lost the declared minimum and sdk; target worked around that
with a hidden channel a hand-written script could not use. The conversion
now keeps a macOS LC_BUILD_VERSION as an LC_VERSION_MIN_MACOSX with its
minos and sdk, written just before the LC_DYLD_INFO_ONLY it appends, so
"fixups, then minos" and "minos, then fixups" give identical bytes, with
8 bytes of header pad too. An image with a version-min gets no second
one; two macOS build-versions are refused. The kept command costs 16
bytes of pad the conversion did not need before.

target 10.9 is now four steps, each asked of the image the previous ones
left: fixups set classic where there are chained fixups, minos at-most
10.9 always, the __DATA_CONST rename where __objc_ sections need it, and
swift-abi set legacy where class records carry the stable-ABI tag. The
Swift tag is read after the conversion, so a chained Swift binary is
retagged; before, it never was. load-command delete build-version is no
longer derived, and the minimum: line is gone: minos's own report line
says it. "Nothing to do" means no step changed the image. Running the
edit script by hand writes target's bytes, thin and fat.

minos set, ms_stmt's sdk channel and mv_set_minos are deleted.

patch_macho inherits the kept declaration; compat/README.md records it,
and that install.sh's patch_macho + add_version_min now leaves the
build-version's minimum and sdk where the C tools left 10.9.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
```

---

### Task 4: `add_version_min` becomes `minos if-absent 10.9`, and `version-min set` goes

**Files:**
- Modify: `compat/translate.sh` (`mt_tr_add_version_min`, lines 293-302)
- Modify: `compat/add_version_min.sh` (header lines 3, 7-16, 38-57, 59-75, 94-96; one line after `mw_finish || exit 1`)
- Modify: `compat/README.md` (the two translation tables, lines 28 and 66; a new section directly above `## \`rename_segment\`: exit codes`)
- Modify: `src/script.h`, `src/script.c` (`MS_VERSION_MIN`, its row, its value check)
- Modify: `src/version_min.h`, `src/version_min.c` (delete `mv_add_version_min`, `mv_add_version_min_image`, `struct mv_scan`, `mv_scan_lc`; the header comments)
- Modify: `src/edit.c` (delete `case MS_VERSION_MIN`; the header comment and `me_apply`'s comment), `src/rewrite.c` (one comment, line 1120)
- Test: `tests/translate_test.sh`, `tests/wrapper_test.sh`, `tests/known-callers.sh`, `tests/cli_test.sh`, `tests/edit_test.c`, `tests/script_test.c`
- Modify: `tests/README.md` (lines 140-144, 223), `tests/strip_version_min.c` (line 6)

**Interfaces:**
- Consumes: `minos if-absent` and its report lines (Task 2); `MW_CHANGED` from `compat/drydock-macho-rewrite-compat.sh`'s `mw_finish`.
- Produces: `add_version_min FILE` → `printf 'minos if-absent 10.9\n' | drydock-macho-rewrite FILE FILE.new` then `mv -f FILE.new FILE`; the wrapper prints `LC_VERSION_MIN_MACOSX already present; nothing to do.` when the run changed nothing. 18 statement lines; `version-min set` is an unknown statement.

- [ ] **Step 1: Write the failing wrapper and translation tests**

`tests/translate_test.sh`: in the three expectations for `add_version_min` (`ok avm …`, the `MT_OUT` comparison, the `DRYDOCK_MACHO_REWRITE=/opt/bin/…` comparison) replace `version-min set 10.9` with `minos if-absent 10.9`. Replace `stmtcheck version-min set 1` with `stmtcheck minos if-absent 1`.

`tests/known-callers.sh`: replace `grep -q 'version-min set 10.9' "$T/e2"` with `grep -q 'minos if-absent 10.9' "$T/e2"`.

`tests/wrapper_test.sh`:
- In the teaching-message block, replace `"    printf 'version-min set 10.9\n' | drydock-macho-rewrite f f.new"` with `"    printf 'minos if-absent 10.9\n' | drydock-macho-rewrite f f.new"`, and `grep -q 'version-min set' "$T/out"` with `grep -q 'minos if-absent' "$T/out"`.
- In the `# ---- add_version_min ----` block: replace the comment paragraph that begins `# STDOUT MOVED, and this pins where it went.` with

```sh
# STDOUT MOVED, and this pins where it went. add_version_min printed "Added
# LC_VERSION_MIN_MACOSX 10.9 (ncmds=..., sizeofcmds=...)" on stdout; the
# statement reports the append on STDERR, as "      none -> version-min 10.9;
# sdk 10.9 written". The repo owner's ruling of 2026-09-13 is that wrapper TEXT
# may change where bytes and exit codes may not, so both halves are asserted.
```

  replace `grep -q 'appended LC_VERSION_MIN_MACOSX 10.9' "$T/err"` with `grep -qxF '      none -> version-min 10.9; sdk 10.9 written' "$T/err"`, and the oracle `printf 'version-min set 10.9\n'` with `printf 'minos if-absent 10.9\n'`.
- Directly after the `|| bad "add_version_min usage" …` line:

```sh

# A build-version-only binary ends with ONE version command, keeping the
# build-version's minimum and sdk. The C tool appended LC_VERSION_MIN_MACOSX
# 10.9 beside it: the pair 10.14's dyld and the 10.15+ kernel refuse.
mkminos_run() {
    [ -x "$T/mkminos" ] || "$CC" -O2 -o "$T/mkminos" "$HERE/mkminos.c" 2>"$T/mkminos.out" \
        || { bad "mkminos_run" "cannot build $HERE/mkminos.c: $(cat "$T/mkminos.out")"; return 1; }
    "$T/mkminos" "$@"
}
fresh
mkminos_run bv "$T/f" 1 12.0 12.3 || bad "add_version_min build-version: fixture setup" "mkminos bv failed"
run add_version_min f
[ "$rc" -eq 0 ] && [ "$(mkminos_run show "$T/f")" = "version-min version=12.0.0 sdk=12.3.0" ] \
    && ok "add_version_min: a build-version-only binary ends with one LC_VERSION_MIN_MACOSX, its minimum and sdk kept" \
    || bad "add_version_min build-version" "exit $rc: $(mkminos_run show "$T/f" 2>&1)"
fresh
mkminos_run vmin "$T/f" 10.9 10.9 && mkminos_run add-bv "$T/f" 1 12.0 12.3 \
    || bad "add_version_min both: fixture setup" "mkminos failed"
run add_version_min f
[ "$rc" -eq 0 ] && [ "$(mkminos_run show "$T/f")" = "version-min version=10.9.0 sdk=10.9.0" ] \
    && ok "add_version_min: ... and one carrying both loses the LC_BUILD_VERSION, its version-min unchanged" \
    || bad "add_version_min both" "exit $rc: $(mkminos_run show "$T/f" 2>&1)"
```

- In the capabilities loop, replace `'version-min set 1'` with `'minos if-absent 1'`.

- [ ] **Step 2: Run them to make sure they fail**

Run the build-and-check sequence, then `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native -R '^(translate_test|wrapper_test|known_callers)$' --output-on-failure`. Expected: translate_test fails `avm`, `avm-mt-out` and `drydock-macho-rewrite-env`; known_callers fails "add_version_min taught its drydock-macho-rewrite equivalent"; wrapper_test fails the teaching message, "stderr is where the announcement went", and both new build-version assertions (each ends with two commands). Still passing, and guarding what must not change: "the bytes it installs are drydock-macho-rewrite's own" (on a fixture with no version command both statements append the same 16 bytes) and "prints the C tool's 'already present' line".

- [ ] **Step 3: Change the translation and the wrapper**

`compat/translate.sh`, `mt_tr_add_version_min`: replace its three comment lines with

```sh
    # `argc != 2`; the C tool took no version, and 10.9 was its floor.
```

and the emitted line `version-min set 10.9` with `minos if-absent 10.9`.

`compat/add_version_min.sh`:
- line 3: `` # `version-min set 10.9` statement on its stdin. `` → `` # `minos if-absent 10.9` statement on its stdin. ``
- replace lines 7-16 (from `# WHAT THIS REPLACED.` through `# something through.`) with

```sh
# GRAMMAR. `add_version_min FILE` -> `printf 'minos if-absent 10.9\n' |
# drydock-macho-rewrite FILE OUT`: declare 10.9 where nothing is declared, and
# leave a declared minimum as it is, as the C tool did. compat/README.md's
# "add_version_min" section has where the two differ.
```

- replace the EXIT CODES paragraph (from `# EXIT CODES. drydock-macho-rewrite's, forwarded unchanged, with the wrapper's own refusals` through `# exit 1, the only failure code this tool ever had.`) with

```sh
# EXIT CODES. drydock-macho-rewrite's, forwarded unchanged: 0, 1 for a
# considered refusal, 2 for an operational failure, where the C tool exited a
# flat 1 for both (compat/README.md's "drop-in" section names it). The
# wrapper's own refusals -- an absent or unwritable FILE (`open: ...`, the C
# tool's own words), a hard-linked FILE, and a failed install -- exit 1.
```

- replace the STDOUT paragraph (from `# STDOUT -- ONE OF THE C TOOL'S TWO LINES` through `# is pinned rather than merely tolerated.`) with

```sh
# STDOUT. The C tool printed "LC_VERSION_MIN_MACOSX already present; nothing
# to do." or "Added LC_VERSION_MIN_MACOSX 10.9 (...)". This wrapper prints the
# first when the run changed nothing; the second became the statement's report
# on stderr.
```

- replace the two-line STDERR paragraph (`# STDERR. mv_add_version_min's own diagnostics, the statement report above,` / `# and the teaching message this wrapper prints ahead of both.`) with `# STDERR. The statement's diagnostics and report, after the teaching message.`
- replace the three-line `# THIN ONLY, like mv_add_version_min's own mi_open. …` comment with `# THIN ONLY, as the C tool was; the message is the one it printed, naming FILE.`
- after `mw_finish || exit 1`, add

```sh
[ "$MW_CHANGED" -eq 1 ] || printf 'LC_VERSION_MIN_MACOSX already present; nothing to do.\n'
```

- [ ] **Step 4: Remove `version-min set` and the old append**

`src/script.h`: remove `MS_VERSION_MIN` from the kind enum:

```c
enum { MS_LOAD_COMMAND, MS_SEGMENT, MS_SWIFT_ABI,
       MS_FIXUPS, MS_DYLIB, MS_RPATH, MS_TARGET, MS_IMPORT, MS_MINOS };
```

`src/script.c`: delete the `version-min set` row and the `} else if (kind == MS_VERSION_MIN && op == MS_SET && … "version-min set accepts only '10.9' …");` branch.

`src/edit.c`: delete `case MS_VERSION_MIN` and its comment. In the file's header comment, replace `mv_add_version_min_image's \`added\`` with `mv_declare_minos's report`. In `me_apply`'s comment, replace `` inside `version-min set` `` with `` inside `minos` `` and `` and the command `version-min set` appended `` with `` and what `minos` declared ``.

`src/rewrite.c`: in the comment at line 1120, replace `mv_add_version_min_image` with `mv_declare_minos`.

`src/version_min.c`: delete `struct mv_scan`, `mv_scan_lc`, `mv_add_version_min`, `mv_add_version_min_image`, and the includes only they used (`<fcntl.h>`, `<unistd.h>`, `<sys/stat.h>`, `"atomic_write.h"`). Replace the file's header comment with

```c
/*
 * mv_ -- see version_min.h. A short header pad is grown through
 * mg_ensure_pad (src/grow.h), whose own refusal precedes "no room for
 * LC_VERSION_MIN_MACOSX" when the image cannot be grown.
 */
```

`src/version_min.h`: delete the two functions' declarations and comments. Replace the header comment with

```c
/*
 * mv_ -- the minimum OS a Mach-O declares. mv_declare_minos is `minos
 * at-most` and `minos if-absent` against an image in memory;
 * mv_format_version prints a packed version the way every report does.
 */
```

- [ ] **Step 5: Move the remaining tests off `version-min set`**

`tests/script_test.c`: delete `test_version_min_value_refusal` and its registration; delete the `ms_disturbs(MS_VERSION_MIN, MS_SET)` assertion and the two-line comment above it; in the fixups comment, change `the same two reasons load-command delete and` / `version-min set earn MREL_HEADER_PAD` to `the same two reasons load-command delete and` / `minos at-most earn MREL_HEADER_PAD`; in `test_capabilities_table_round_trips` change `strcmp(kind, "version-min") == 0 || strcmp(kind, "minos") == 0` to `strcmp(kind, "minos") == 0` and 19 to 18; in `test_retired_minimum_statements_are_unknown` extend both arrays:

```c
    static const char *lines[] = { "version-min set 10.9\n", "minos set 10.9\n",
                                   "minos at-mots 10.9\n" };
    static const char *said[] = { "unknown statement 'version-min set'",
                                  "unknown statement 'minos set'",
                                  "unknown statement 'minos at-mots'" };
```

`tests/edit_test.c`:
- In `test_the_file_level_operations_run_in_memory`: change its comment's first word `version-min,` to `minos,`. Replace the script `"version-min set 10.9\n"` (first run) with `"minos if-absent 10.9\n"`; `strstr(g_log, "  version-min set 10.9\n")` with `strstr(g_log, "  minos if-absent 10.9\n")`; `"\n      appended LC_VERSION_MIN_MACOSX 10.9\n"` with `"\n      none -> version-min 10.9; sdk 10.9 written\n"`; the label text "logs the version-min append" with "logs the declaration". Replace the second run's `"version-min set 10.9\n"` with `"minos if-absent 10.9\n"`, its label "version-min set on an image that has one" with "minos if-absent on an image that has one", "a second version-min set appends" with "a second minos if-absent appends", and `CHECK(strstr(g_log, "appended") == NULL,` with `CHECK(strstr(g_log, "      version-min 10.9, at or below 10.9: kept; sdk 10.9 kept\n") != NULL,`, relabelled "in memory: the report says the declared one was kept (log: %s)". Replace the last run's `"version-min set 10.9\nfixups set classic\n"` with `"minos if-absent 10.9\nfixups set classic\n"`.
- In `test_fat_a_slice_skips_its_verify_on_its_own_terms`: the script and both comment mentions of `` `version-min set 10.9` `` become `` `minos if-absent 10.9` ``.

`tests/cli_test.sh`:
- The `alone` capabilities loop: `'version-min set 1'` → `'minos if-absent 1'`.
- Replace the `alone` block from `# \`version-min set\` is the one statement that was gated on add_version_min` through `|| bad "alone: version-min set result" …` with

```sh
# minos if-absent was the one statement gated on add_version_min rather than
# change_dylib, so it needs its own standalone run.
if printf 'minos if-absent 10.9\n' \
        | "$T/alone/drydock-macho-rewrite" "$T/alone/fixture" "$T/alone/fixture.minos" \
        >"$T/alone_minos.out" 2>&1; then
    ok "alone: minos if-absent works with no add_version_min anywhere near drydock-macho-rewrite"
else
    bad "alone: minos if-absent" "$(cat "$T/alone_minos.out")"
fi
if grep -q "^      .*version-min " "$T/alone_minos.out"; then
    ok "alone: minos if-absent reached its core in-process (said what it did)"
else
    bad "alone: minos if-absent output" "exited 0 but reported no version-min: $(cat "$T/alone_minos.out")"
fi
"$T/alone/drydock-macho-rewrite" info "$T/alone/fixture.minos" | grep -q "LC_VERSION_MIN_MACOSX" \
    && ok "alone: the output carries LC_VERSION_MIN_MACOSX afterward" \
    || bad "alone: minos if-absent result" "no LC_VERSION_MIN_MACOSX in info output after minos if-absent"
```

- The block under the `# version-min set` header: rename the header line to `# minos if-absent`, then run

```sh
sed -i '' -e '/^# Any other version is refused up front/,/a refused version writes no OUT"$/d' tests/cli_test.sh
sed -i '' -e '/^build_main "\$T\/minos_fixture"$/,/"version-min set no OUT"/s/version-min set/minos if-absent/g' \
    tests/cli_test.sh
```

- The `vonly` block: `printf 'version-min set 10.9\n' >"$T/vonly_vm.edits"` → `printf 'minos if-absent 10.9\n' >"$T/vonly_vm.edits"`; `"version-min run: …"` → `"minos run: …"`; in its comment `mv_add_version_min_image` → `mv_declare_minos`.
- The short-pad block: run

```sh
sed -i '' -e '/^# version-min set on a short pad\./,/"version-min set" "an extra token after OUT/s/version-min set/minos if-absent/g' \
    tests/cli_test.sh
```

Each `sed` rewrites every `version-min set` in its range, labels and comments alike; Step 7's `git grep` proves none is left.

- Delete the six lines from `` # `verb minos versions=10.9 flags=...` used to be here `` through `|| bad "capabilities version-min" …`.
- In the capabilities block, change 19 to 18, and after Task 3's `minos set` negative add

```sh
echo "$caps" | grep -qxF "statement version-min set 1" \
    && bad "capabilities statements" "version-min set is still advertised" \
    || ok "capabilities: version-min set is no longer advertised"
```

(Task 3's `minos at-most` presence check above it is this negative's positive control.)

`tests/README.md`: replace `` and `version-min set` (past its own version check) hand their `` / `` statement's code back through `me_run` from the shared rewrite drivers, `` / `` `mr_apply_image` and `mv_add_version_min` (`src/rewrite.h`, `` with `` and `minos` hand their `` / `` statement's code back through `me_run` from the shared cores, `` / `` `mr_apply_image` and `mv_declare_minos` (`src/rewrite.h`, ``. Replace `` `cli_test.sh`'s `version-min set` fixture construction `` with `` `cli_test.sh`'s `minos if-absent` fixture construction ``.

`tests/strip_version_min.c`: line 6, `` `version-min set 10.9` `` → `` `minos if-absent 10.9` ``.

- [ ] **Step 6: Record the divergence**

`compat/README.md`: line 28's cell `` `add_version_min.sh` → `version-min set 10.9`, installed over `FILE` `` becomes `` `add_version_min.sh` → `minos if-absent 10.9`, installed over `FILE` ``; line 66's `` | `add_version_min FILE` | `version-min set 10.9` | `` becomes `` | `add_version_min FILE` | `minos if-absent 10.9` | ``. Directly above `## \`rename_segment\`: exit codes`, add

```markdown
## `add_version_min`: the differences, and what holds each one

`add_version_min FILE` becomes `minos if-absent 10.9` into a temp beside
`FILE`, installed over it. "Held by" names assertions in
`tests/wrapper_test.sh`.

| the difference | held by |
|---|---|
| **a binary whose only version command is a macOS `LC_BUILD_VERSION` ends with one `LC_VERSION_MIN_MACOSX`** carrying that command's minimum and sdk. The C tool appended `LC_VERSION_MIN_MACOSX` 10.9 beside it, leaving the pair that 10.14's dyld and the 10.15+ kernel refuse | "add_version_min: a build-version-only binary ends with one LC_VERSION_MIN_MACOSX, its minimum and sdk kept" |
| **a binary carrying both loses the `LC_BUILD_VERSION`**; its `LC_VERSION_MIN_MACOSX` is unchanged. The C tool left both | "add_version_min: ... and one carrying both loses the LC_BUILD_VERSION, its version-min unchanged" |
| **the append is announced on stderr** as `none -> version-min 10.9; sdk 10.9 written`, not as the C tool's "Added LC_VERSION_MIN_MACOSX 10.9 (...)" on stdout | "add_version_min: stdout is empty -- the append is announced on stderr now", "add_version_min: ... and stderr is where the announcement went" |
| **"LC_VERSION_MIN_MACOSX already present; nothing to do." is printed by the wrapper**, when the run changed no byte | "wrapper: ... and prints the C tool's 'already present' line" |
```

- [ ] **Step 7: Run the tests and make sure they pass**

Run the build-and-check sequence (all three binaries absent from the OK list; no `STALE`), then the full test command. Expected: 22 tests, all pass, `chained_fixups` skips. Then, with positive controls:

```sh
git grep -n 'version-min set\|MS_VERSION_MIN\|mv_add_version_min' -- src cli compat tests ':!tests/compat-matrix.tsv'
# prints only: the label "as mv_add_version_min's own mi_open did" (tests/wrapper_test.sh,
# compat/README.md), script_test's retired-statement pin, and cli_test's
# "version-min set is no longer advertised" negative
git grep -c 'minos if-absent 10.9' -- compat/translate.sh tests/cli_test.sh   # both nonzero
```

- [ ] **Step 8: Mutation-prove it**

1. In `compat/translate.sh`, emit `minos at-most 10.9`. Rebuild, confirm the staged copy changed (no `STALE`). Expected: translate_test `avm` and its two siblings, and wrapper_test "a build-version-only binary ends with one LC_VERSION_MIN_MACOSX, its minimum and sdk kept" (it gets 10.9), fail.
2. In `compat/add_version_min.sh`, delete the new `printf` line. Expected: "wrapper: ... and prints the C tool's 'already present' line" fails.
3. Change `[ "$MW_CHANGED" -eq 1 ] ||` to `[ "$MW_CHANGED" -eq 0 ] ||`. Expected: "stdout is empty -- the append is announced on stderr now" and the "already present" assertion fail.

- [ ] **Step 9: Commit**

```bash
git add compat/translate.sh compat/add_version_min.sh compat/README.md \
        src/script.h src/script.c src/version_min.h src/version_min.c src/edit.c src/rewrite.c \
        tests/translate_test.sh tests/wrapper_test.sh tests/known-callers.sh tests/cli_test.sh \
        tests/edit_test.c tests/script_test.c tests/README.md tests/strip_version_min.c
git commit -F - <<'EOF'
feat(compat): add_version_min is minos if-absent 10.9; version-min set goes

add_version_min appended LC_VERSION_MIN_MACOSX 10.9 where there was
none and otherwise left the file alone. On a binary carrying only an
LC_BUILD_VERSION that left two version commands, the pair 10.14's dyld
and the 10.15+ kernel refuse. The wrapper now emits minos if-absent
10.9: one LC_VERSION_MIN_MACOSX, keeping the build-version's minimum and
sdk. compat/README.md's new add_version_min section records it.

The wrapper prints "LC_VERSION_MIN_MACOSX already present; nothing to
do." itself when the run changed nothing, which is exactly the C tool's
case, so that pinned output is unchanged.

version-min set, MS_VERSION_MIN, mv_add_version_min and
mv_add_version_min_image are deleted; minos if-absent is the statement
the remaining tests use.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
```

---

### Task 5: the Claude Code edit scripts

**Files:**
- Create: `edit-scripts/claude-code.edits`, `edit-scripts/claude-code-no-avx2.edits`
- Test: `tests/cli_test.sh` (directly after Task 3's "fixups set classic keeps the declaration" block)

**Interfaces:**
- Consumes: `minos at-most` (Task 2) and `fixups set classic` keeping the declaration (Task 3). The paths are `/usr/local/bin/claude`'s, read there (read-only): its `mf_change_dylib` pairs, its `SW`/`IW`/`CW` for each scheme, and its `AW` and `-change @loader_path/../A.dylib` for the linked-emulator scheme.
- Produces: two committed edit scripts, run as `drydock-macho-rewrite CLAUDE CLAUDE.new < edit-scripts/claude-code.edits`, where CLAUDE is the unpatched binary Anthropic ships.

- [ ] **Step 1: Write the failing test**

In `tests/cli_test.sh`, directly after the `"fixups/minos order ($fo_mode)"` loop's `done`:

```sh

# ============================================================================
# edit-scripts/: the Claude Code edit scripts
# ============================================================================
# Each runs to the end on a plain executable: build_main links
# /usr/lib/libSystem.B.dylib, so one dylib replace really matches, and
# allow-unmatched covers the rest.
ES_DIR=$(CDPATH= cd -- "$HERE/../edit-scripts" && pwd)
for es in claude-code claude-code-no-avx2; do
    [ "$(grep -c '^dylib replace ' "$ES_DIR/$es.edits" || true)" = 9 ] \
        && ok "edit-scripts/$es.edits: the nine dylib replace pairs the wrapper's change_dylib makes" \
        || bad "edit-scripts/$es.edits" "$(grep -c '^dylib replace ' "$ES_DIR/$es.edits" || true) dylib replace lines"
    build_main "$T/es_$es"
    rc=0; "$DRYDOCK_MACHO_REWRITE" "$T/es_$es" "$T/es_$es.out" <"$ES_DIR/$es.edits" \
        >/dev/null 2>"$T/es.err" || rc=$?
    [ "$rc" -eq 0 ] \
        && ok "edit-scripts/$es.edits: parses, and runs to the end on a plain executable" \
        || bad "edit-scripts/$es.edits" "rc $rc: $(cat "$T/es.err")"
done
"$DRYDOCK_MACHO_REWRITE" info "$T/es_claude-code.out" | grep -qF ' path=@loader_path/../S.dylib' \
    && ok "edit-scripts/claude-code.edits: ... libSystem becomes the wrapper's S.dylib alias" \
    || bad "edit-scripts/claude-code.edits" "$("$DRYDOCK_MACHO_REWRITE" info "$T/es_claude-code.out" | grep 'path=')"
"$DRYDOCK_MACHO_REWRITE" info "$T/es_claude-code-no-avx2.out" \
    | grep -qxF '  ordinal=1 path=@loader_path/../../claude-mavericks-local/libavxemu.dylib' \
    && "$DRYDOCK_MACHO_REWRITE" info "$T/es_claude-code-no-avx2.out" \
        | grep -qF ' path=@loader_path/../../claude-mavericks/libSystemWrapper.dylib' \
    && ok "edit-scripts/claude-code-no-avx2.edits: ... the AVX emulator is ordinal 1, and libSystem is the wrapper" \
    || bad "edit-scripts/claude-code-no-avx2.edits" "$("$DRYDOCK_MACHO_REWRITE" info "$T/es_claude-code-no-avx2.out" | grep 'path=')"
```

- [ ] **Step 2: Run it to make sure it fails**

Run the build-and-check sequence, then `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh /private/tmp/build/schmonz/drydock-native 2>&1 | tail -5`. Expected: the suite stops at `ES_DIR=$(…)` under `set -e` (no `edit-scripts/` directory), and `ctest` reports cli_test failed. That is this step's failure.

- [ ] **Step 3: Write the edit scripts**

`edit-scripts/claude-code.edits`:

```
# Claude Code for OS X 10.9, on a CPU with AVX2:
#   drydock-macho-rewrite CLAUDE CLAUDE.new < edit-scripts/claude-code.edits
# CLAUDE is the unpatched binary. The @loader_path/../ names are the aliases
# /usr/local/bin/claude makes beside versions/.
allow-unmatched
fixups set classic
minos at-most 10.9
load-command delete uuid
load-command delete codesig
dylib replace /usr/lib/libSystem.B.dylib @loader_path/../S.dylib
dylib replace /usr/lib/libicucore.A.dylib @loader_path/../I.dylib
dylib replace /usr/lib/libc++.1.dylib @loader_path/../c++.1.dylib
dylib replace @loader_path/../S.dylib @loader_path/../S.dylib
dylib replace @loader_path/../I.dylib @loader_path/../I.dylib
dylib replace @loader_path/../c++.1.dylib @loader_path/../c++.1.dylib
dylib replace @loader_path/../../claude-mavericks/libSystemWrapper.dylib @loader_path/../S.dylib
dylib replace @loader_path/../../claude-mavericks/libicucoreWrapper.dylib @loader_path/../I.dylib
dylib replace @loader_path/../../claude-mavericks/libc++.1.dylib @loader_path/../c++.1.dylib
```

`edit-scripts/claude-code-no-avx2.edits`:

```
# Claude Code for OS X 10.9, on a CPU without AVX2, with the AVX emulator
# linked in:
#   drydock-macho-rewrite CLAUDE CLAUDE.new < edit-scripts/claude-code-no-avx2.edits
# CLAUDE is the unpatched binary, in ~/.local/share/claude/versions/.
allow-unmatched
fixups set classic
minos at-most 10.9
load-command delete uuid
load-command delete codesig
dylib replace /usr/lib/libSystem.B.dylib @loader_path/../../claude-mavericks/libSystemWrapper.dylib
dylib replace /usr/lib/libicucore.A.dylib @loader_path/../../claude-mavericks/libicucoreWrapper.dylib
dylib replace /usr/lib/libc++.1.dylib @loader_path/../../claude-mavericks/libc++.1.dylib
dylib replace @loader_path/../S.dylib @loader_path/../../claude-mavericks/libSystemWrapper.dylib
dylib replace @loader_path/../I.dylib @loader_path/../../claude-mavericks/libicucoreWrapper.dylib
dylib replace @loader_path/../c++.1.dylib @loader_path/../../claude-mavericks/libc++.1.dylib
dylib replace @loader_path/../../claude-mavericks/libSystemWrapper.dylib @loader_path/../../claude-mavericks/libSystemWrapper.dylib
dylib replace @loader_path/../../claude-mavericks/libicucoreWrapper.dylib @loader_path/../../claude-mavericks/libicucoreWrapper.dylib
dylib replace @loader_path/../../claude-mavericks/libc++.1.dylib @loader_path/../../claude-mavericks/libc++.1.dylib
dylib replace @loader_path/../A.dylib @loader_path/../../claude-mavericks-local/libavxemu.dylib
dylib insert @loader_path/../../claude-mavericks-local/libavxemu.dylib
```

Check the pairs against the wrapper before committing: `grep -n -- '-change ' /usr/local/bin/claude` must list the nine `mf_change_dylib` pairs plus `@loader_path/../A.dylib`, in the order above, with `$SW`/`$IW`/`$CW`/`$AW` standing for the targets used here.

- [ ] **Step 4: Run the tests and make sure they pass**

Run the build-and-check sequence, then the full test command. Expected: 22 tests, all pass, `chained_fixups` skips.

- [ ] **Step 5: Mutation-prove it**

1. Delete the `libicucore` line from `edit-scripts/claude-code.edits`. Expected: "the nine dylib replace pairs" fails for it.
2. Change `dylib insert` to `dylib insrt` in the no-AVX2 file. Expected: "parses, and runs to the end" fails (exit 2).
3. Delete the no-AVX2 file's `dylib insert` line. Expected: "the AVX emulator is ordinal 1" fails.

- [ ] **Step 6: Commit**

```bash
git add edit-scripts/claude-code.edits edit-scripts/claude-code-no-avx2.edits tests/cli_test.sh
git commit -F - <<'EOF'
feat(edit-scripts): Claude Code in one drydock-macho-rewrite run

edit-scripts/ holds edit scripts that users run. claude-code.edits does
in one run what install.sh's patch_macho, add_version_min and
change_dylib do today: fixups set classic, minos at-most 10.9, delete
LC_UUID and LC_CODE_SIGNATURE, and the nine dylib replace pairs
/usr/local/bin/claude passes to change_dylib. claude-code-no-avx2.edits
is the variant for CPUs without AVX2, linking the AVX emulator first.

A script cannot expand $HOME, so the no-AVX2 variant names
~/.local/share/claude-mavericks{,-local} relative to the binary in
~/.local/share/claude/versions/. The output differs from today's in bytes:
it keeps the binary's real sdk, which on 10.9 behaves identically to 10.9
(docs/minimum-os-version.md), and its load commands come in another order.

cli_test runs both edit scripts to the end on a plain executable.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
```

---

### Task 6: README

**The owner is editing README.md by hand.** Before you edit, run `git log --oneline -5 -- README.md` and `git diff HEAD -- README.md`. If the second prints anything, stop and ask. Find each passage below by its content, not its line number, and leave the words around it exactly as they are.

**Files:**
- Modify: `README.md`: Statements, the list of statements that can match nothing and the paragraph after it, "The `target` statement", and Queries.
- Test: none; this is prose. Step 2 checks it against the tests.

**Interfaces:**
- Consumes: the behaviour of Tasks 1-4 as their tests pin it.
- Produces: nothing code reads.

- [ ] **Step 1: Make the edits**

1. **Statements block.** Replace the two lines `version-min   set       10.9` and `minos         set       VERSION     e.g. 10.9, 10.12, 10.9.5` with
   ```
   minos         at-most   VERSION     e.g. 10.9, 10.12, 10.9.5
   minos         if-absent VERSION
   ```
2. **The blockquote after the Statements block** (it begins `> \`version-min set 10.9\` appends`): replace it with

   ````markdown
   `minos at-most VERSION` lowers a declared minimum above VERSION to VERSION;
   `minos if-absent VERSION` leaves any declared minimum as it is. Both declare
   VERSION where nothing is declared, and both compare at VERSION's own
   precision, so `minos at-most 10.9` keeps a declared 10.9.5. A minimum read
   from an `LC_BUILD_VERSION` keeps that command's sdk; with nothing declared,
   the sdk written is 10.9.

   | you want | write |
   |---|---|
   | a binary built for a newer macOS to say it targets 10.9 | `minos at-most 10.9`, or let `target 10.9` derive it |
   | a minimum declared where there is none, and nothing else changed | `minos if-absent 10.9` |
   | to keep an honest lower minimum such as 10.7 | either; neither raises one |

   Finder and LaunchServices refuse to launch on `LSMinimumSystemVersion` in
   `Info.plist`, not on the Mach-O minimum, and Drydock does not edit
   `Info.plist`. On 10.9 the sdk field decides linked-on-or-after behaviour and
   whether dyld registers a dylib's code signature; see
   [docs/minimum-os-version.md](docs/minimum-os-version.md). Each `minos`
   statement leaves exactly one `LC_VERSION_MIN_MACOSX` per slice, and no
   `LC_BUILD_VERSION`.
   ````

3. **The list of statements that can match nothing:** delete the item `` - `minos set` (no `LC_VERSION_MIN_MACOSX` and no macOS `LC_BUILD_VERSION`) ``. In the paragraph after it, replace `` `version-min set` and `swift-abi set` cannot miss: with nothing to do, they `` / `are no-ops.` with `` `minos` and `swift-abi set` cannot miss: with nothing to do, they are `` / `` no-ops. `swift-abi set legacy` refuses an image that still has chained fixups, whose class-record pointers it cannot read: write `fixups set classic` before it. ``
4. **"The `target` statement".** Replace from `**It expands, where it is written, into statements the language already` through the table's last row (`| class records carrying the stable-ABI Swift tag | \`swift-abi set legacy\` |`) with

   ````markdown
   **It expands, where it is written, into statements the language already
   has** — the ones this binary actually needs — and those run in its place.
   It is this script, with each conditional line kept only where its
   condition holds:

   ```
   fixups set classic                   # where LC_DYLD_CHAINED_FIXUPS is present
   minos at-most 10.9
   segment rename __DATA_CONST __DATA   # where __DATA_CONST holds __objc_ sections
   swift-abi set legacy                 # where class records carry the stable-ABI Swift tag
   ```

   Each condition is tested on the image as the lines before it left it, so
   the Swift tag is read after `fixups set classic` has made the class-record
   pointers readable.
   ````

   Then replace the paragraph beginning `It decides per slice: each slice of a fat file gets only the lines that slice` through `design earns its place; this build has one, and refuses any other.` with

   ````markdown
   What `target` adds over writing that script by hand:

   - it renames `__DATA_CONST` only where `__objc_` sections need it, per
     slice. Renaming a C-only `__DATA_CONST` breaks nothing measured on 10.9,
     but it leaves two segments named `__DATA`, which `getsegbyname` and tools
     cannot tell apart;
   - it chooses per slice of a fat file;
   - it derives `fixups set classic` only where there are chained fixups, so it
     never hits that statement's refusal on an image with no fixup information;
   - it reports why each line was derived.

   A second profile is what would show the design earns its place; this build
   has one, and refuses any other.
   ````

5. **"Write the statements by hand".** Replace `the rest, such as only \`version-min set 10.9\`. Then:` with `the rest. Then:`. Delete the bullet `` - to lower a declared minimum and nothing else, write `minos set 10.9`; `` / `` `version-min set 10.9` only appends one where none is declared; `` and the bullet beginning `` - leave out `load-command delete build-version` after `fixups set classic` `` (three lines). After the bullet ending `chained fixups nor \`LC_DYLD_INFO_ONLY\` (it refuses);`, add `` - put `swift-abi set legacy` after it (it refuses an image that still has chained fixups); ``.
6. **The report example.** Replace the five-line block beginning `  target 10.9` with
   ```
     target 10.9
       fixups set classic  (LC_DYLD_CHAINED_FIXUPS present)
         chained fixups -> LC_DYLD_INFO_ONLY; LC_BUILD_VERSION 12.0 (sdk 12.3) kept as LC_VERSION_MIN_MACOSX
       minos at-most 10.9  (always)
         version-min 12.0 -> 10.9; sdk 12.3 kept
   ```
   and replace the blockquote after it (beginning `> The \`minimum:\` line is always there`) with

   > Each statement's own lines follow it; the conversion's other figures are
   > left out here. The report says `nothing to do: this binary already
   > targets 10.9` only when no line changed the image: the slice already held
   > one `LC_VERSION_MIN_MACOSX` at or below 10.9, no `LC_BUILD_VERSION`, and
   > nothing else to convert.

7. **The rest of the rules.** Replace `` derived `version-min set 10.9` grows a short header pad exactly as one you `` with `` derived `minos at-most 10.9` grows a short header pad exactly as one you ``. In the `**\`target\` never counts as unmatched,**` bullet, delete the parenthetical `` (It happens for real: `` … `` delete build-version` the same expansion derived finds nothing left to do.) ``.
8. **Queries.** Replace the three-line paragraph beginning `` `info` answers each of `target 10.9`'s five detections `` with this plain paragraph:

   ````markdown
   `info` answers each of `target 10.9`'s three detections: an `LC[n]` line
   for `LC_DYLD_CHAINED_FIXUPS`, a `sectname=` line under
   `segname=__DATA_CONST`, and the `swift-abi:` line, which says `unknown`
   on an image whose fixups are still chained.
   ````

   After the paragraph that ends `and the header row names the columns.`, add this paragraph:

   ````markdown
   `verify` checks structure, not what 10.9's runtime requires: it passes an
   Objective-C image whose `__objc_` sections sit in `__DATA_CONST`, and that
   image dies at launch on 10.9.
   ````

- [ ] **Step 2: Check the prose against the tests**

Run `git diff -- README.md`. Expected: only the eight passages above changed. Then each quoted report line must be one a test asserts, and target's edit script must match the test's literal:

```sh
for s in 'minos at-most 10.9  (always)' 'kept as LC_VERSION_MIN_MACOSX' \
         'nothing to do: this binary already targets 10.9' \
         'swift-abi: unknown (pointers are chained; fixups set classic first)' \
         'fixups set classic\nminos at-most 10.9\nsegment rename __DATA_CONST __DATA\nswift-abi set legacy'; do
    git grep -qF "$s" tests/cli_test.sh && echo "ok: $s" || echo "MISSING: $s"
done
git grep -n 'version-min set\|minos set\|minimum: ' -- README.md   # prints nothing
git grep -c 'minos at-most' -- README.md                          # nonzero
```

Every line prints `ok:`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -F - <<'EOF'
docs(readme): minos at-most, minos if-absent, and target as an edit script

The statements list the two minos words; a short table says when to use
which, and three sentences say what gates launch, what the sdk field
does on 10.9, and what each statement leaves. target's section prints
the script it is equivalent to and what it adds over writing it by hand;
the report example and the write-by-hand advice follow the new
expansion. Queries says info's swift-abi line is unknown on a chained
image, and that verify checks structure, not 10.9's runtime.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
```

---

## One-time check before Drydock's first release

Done once, by hand, by the owner, before Drydock's first release. It is not a ctest, not a merge gate, and not repeated at later releases. The owner records the result; if Claude Code misbehaves later, the sdk question is revisited with this as its baseline.

`ORIG` is an unpatched copy of the current Claude Code version: the file install.sh downloads before it patches it. The copy in `~/.local/share/claude/versions/` has already been patched in place by `/usr/local/bin/claude` and is today's pipeline output. The new binary goes in a sibling of `versions/`, so the `@loader_path/../` names resolve as they do there, and Claude Code's version housekeeping cannot reap it.

```sh
B=/private/tmp/build/schmonz/drydock-native
V=$(basename "$(readlink ~/.local/bin/claude)")
TODAY=~/.local/share/claude/versions/$V
ORIG=/path/to/unpatched/claude-$V          # the owner supplies this copy
S=~/.local/share/claude/drydock-check
mkdir -p "$S"
"$B/drydock-macho-rewrite" "$ORIG" "$S/claude" < edit-scripts/claude-code.edits
export USE_BUILTIN_RIPGREP=0 DISABLE_INSTALLATION_CHECKS=1 JSC_numberOfGCMarkers=1
for bin in "$TODAY" "$S/claude"; do
    "$bin" --version            >"$S/$(basename "$bin").version" 2>&1
    "$bin" --help               >"$S/$(basename "$bin").help"    2>&1
    "$bin" -p 'Reply with exactly the word ok.' >"$S/$(basename "$bin").p" 2>&1
done
diff "$S/$V.version" "$S/claude.version"
diff "$S/$V.help"    "$S/claude.help"
cat "$S/$V.p" "$S/claude.p"
rm -rf "$S"
```

Expected: both `diff`s print nothing, and both `-p` runs answer `ok`. On a Mac without AVX2, repeat with `edit-scripts/claude-code-no-avx2.edits`.

---

## Self-Review

**Spec coverage.**

| spec requirement | task |
|---|---|
| grammar: both words; VERSION validated at parse time (exit 2); precision | 2 (script_test, cli bad version, edit_test rows 2-3) |
| `version-min set`, `minos set` removed, unknown statements pinned beside a typo; 18 rows | 3 (`minos set`), 4 (`version-min set`, 18) |
| `--capabilities` lists both new lines | 2 |
| per-slice decision table, every cell, for version-min, build-version and none | 2 (edit_test rows, cli rows) |
| sdk kept / carried over / 10.9 written | 2 |
| one `LC_VERSION_MIN_MACOSX`, no `LC_BUILD_VERSION`, including zippered | 2 (edit_test row 14, cli zippered) |
| iOS-only refused; duplicates refused | 2 |
| unchanged slice keeps its bytes | 2 (edit_test, cli cmp) |
| fat, per slice, with `arch` | 2 (edit_test `write_fat`) |
| `ms_disturbs` is `MREL_HEADER_PAD` | 2 |
| report shapes, Mac Catalyst suffix, ASCII arrows | 2 |
| `fixups set classic` keeps macOS `LC_BUILD_VERSION` as `LC_VERSION_MIN_MACOSX`, before `LC_DYLD_INFO_ONLY`; Mac Catalyst stripped; no second one; report line | 3 |
| either order byte-identical, including the 8-byte-pad chained image | 3 (`make`, `make-lcfirst`, `make-tight`) |
| hidden channel deleted | 3 |
| `swift-abi set legacy` refuses a chained image and names the fix; `info` says unknown | 1 |
| `target` detects after each derived statement; the Swift bug | 3 |
| `target` expansion, order, `minos at-most` in position 2, never `load-command delete build-version`, no `minimum:` line, `ME_TARGET_MAX` 4 | 3 |
| "nothing to do" only when nothing changes; the 10.12 reproduction | 3 |
| the published edit script equals `target`, thin and fat | 3 (test), 6 (README) |
| `add_version_min` → `minos if-absent 10.9`; build-version-only gives one command; "already present" unchanged; `compat/README.md` row | 4 |
| `edit-scripts/claude-code.edits`: the spec's lines, nine `dylib replace` pairs, the no-AVX2 variant; a ctest that runs it | 5 |
| the one-time manual check against the real Claude Code binary | "One-time check before Drydock's first release" |
| README decision table, three sentences, target's edit script, what `target` adds, verify's limit | 6 |
| every mutation named fails its test | each task's mutation step |

**Placeholder scan.** Every code step shows its code; every test step shows its assertions. Task 4's two `sed` blocks are the edits, not descriptions of them, and Step 7's `git grep` names exactly which hits may remain. Task 6 gives the replacement text and finds passages by content. The one-time check's `ORIG` is an input only the owner has (an unpatched Claude Code binary), named as such.

**Type consistency.** These names are the same everywhere they appear:
- `ms_parse_version(const char *, uint32_t *, uint32_t *)`, called with `NULL` in `script.c` and `&mask` in `edit.c`
- `mv_declare_minos(uint8_t **, size_t *, const char *, int, uint32_t, uint32_t, mv_decl_report *)`
- `mv_decl_report` fields `from`, `declared`, `above`, `minos`, `sdk`, `dropped_macos`, `dropped_minos`, `catalyst`, `changed`
- `MV_AT_MOST`, `MV_IF_ABSENT`, `MV_FROM_NONE`, `MV_FROM_VERSION_MIN`, `MV_FROM_BUILD_VERSION`, `MV_PLATFORM_MACOS`, `MV_PLATFORM_MACCATALYST`, `MV_10_9`
- `MS_AT_MOST`, `MS_IF_ABSENT`, `MS_MINOS`; `MS_VERSION_MIN` exists through Task 3 only
- `me_log_declared(FILE *, const mv_decl_report *, const char *)`; `me_verdict.changed`
- `md_report.kept_version_min`, `kept_minos`, `kept_sdk`
- `MSWIFT_CHAINED` (-3)
- `me_expand_10_9(const mi_image *, int step, me_derived *, int line)`; `ME_TARGET_MAX` 4
- `mkchained` modes `make-swift`, `make-swiftdc`, `make-tight`, `tags`; `mkminos add-bv`
- statement counts: 20 after Task 2, 19 after Task 3, 18 after Task 4, in both `script_test.c` and `cli_test.sh`

The report strings asserted in `edit_test.c` and `cli_test.sh` are the ones `me_log_declared` and `me_log_declassify` produce: six spaces, then the shapes in Task 2's Interfaces, with the version as written (`10.9`) in "at or below".
