# Dylib header growth M2a: the one rule on both routes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A grow refuses, before it changes anything, an image whose code (confirmed by decoding), `N_SECT` symbol or export names a byte strictly between its header and its first content, or whose bind, weak bind or lazy bind lies in the segment that maps the header. These are the two items M1's final review handed to M2, done on the one route that exists, in the form the raise route (plan M2b) reuses unchanged.

**Architecture:** `src/hdrref.[ch]` gains a range scan (`mhr_scan_range`) that reports each candidate's target, and `mhr_confirm_each`, which decodes every candidate in a range and gives each a verdict: confirmed, refuted, or not reached. `mhr_confirm` keeps its contract, built on it. `mg_grow_header` gains three pre-mutation checks in `src/grow.c`: code that names the inside of the header, as the owner ruled (Task 2), symbols and exports that do (Task 3), and binds in the header's segment (Task 4).

**Tech Stack:** C as the 10.9 clang (Apple LLVM 6.0) accepts it; CMake through shipyard; POSIX `sh`; hand-built in-memory Mach-O fixtures in `tests/grow_test.c`.

**Spec:** `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`. This plan implements the first two bullets of its M2 section ("Enforce the one rule's strictly-inside refusal on both routes", "Refuse a bind in `__TEXT` on both routes") and the `mhr_confirm` item of "Interfaces to generalise". Read QUEUE item 29's **I1** paragraph too. Plan M2b (`plans/2026-09-26-dylib-growth-m2b.md`) is the raise route, and starts where this plan ends.

## Why M2 is two plans

M2 is fourteen tasks, and they fall in two groups that a reviewer can accept or reject apart:

- **M2a (this plan, 5 tasks)** finishes the executable route's share of the one rule. Every change is observable today on executables, the host sweep proves it changes nothing measured, and the owner's I1 ruling is one small task. It ships on its own.
- **M2b (9 tasks)** adds the raise route for `MH_DYLIB` and `MH_BUNDLE`, and reuses M2a's range scan and bind check on it. It is large (fixture, geometry, stabs, split info, UUID, two new verification checks, the CLI, and the real-dylib proof), and it can be reviewed without re-reading M2a's decisions.

## The measurements that decide this plan

Measured 2026-09-26 on this host (10.9, ld64-241.9) at `5ca0612`, with a probe linked against Task 1's `libdrydockcore.a`. The executable corpus is the M1 and data-pointer sweeps': every regular file with an x86_64 slice under `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin` and `/usr/libexec`, 1,128 files, 1,059 of them `MH_EXECUTE`. Claude Code is the pristine 2.1.282 snapshot (`~/.local/share/claude-binary-snapshots/2.1.282.49763317.bin`, sha256 `5c34b00b…`).

**RIP-relative targets strictly inside (base, base + F)**, each candidate given Task 1's verdict:

| corpus | images with one | candidates | confirmed | refuted | not reached |
|---|---|---|---|---|---|
| the 1,059 `MH_EXECUTE` | 120 | 1,060 | **0** | 1,057 | 3, all in `thnucups` (no `LC_FUNCTION_STARTS`) |
| Claude Code 2.1.282 (and 2.1.283) | 1 | 29 | **0** | 29 | 0 |
| M2b's 1,180 10.9 system dylibs and bundles | 87 | 1,331 | **0** | 1,310 | 21, all in `MediaToolbox` |
| 651 x86_64 images in this machine's applications (`/Applications`, `~/Applications`, `~/Downloads`: executables, frameworks, dylibs) | 162 | 34,398 | **0** | 32,938 | 1,460, in 33 images, all with no `LC_FUNCTION_STARTS` (Chromium's, VMware Fusion's bundled libraries, an old Sparkle) |

The same probe over exactly the base finds 152 candidates in the executables and confirms 151, as M1 did: the zeros above are answers, not a broken probe. Every image with a candidate decoding cannot reach (`thnucups`, `MediaToolbox`, and the 33 application images) also has an exact-base candidate it cannot reach, and M1 refuses it already.

**Why "refuted" matters.** Every exact-base reference, `lea __mh_execute_header(%rip)`, is also three candidates in the range: the same four bytes read with a 1-, 2- or 4-byte immediate name base + 1, + 2 and + 4. Decoding reaches the `lea`, sees it has no immediate, and refutes all three. Of Claude Code's 29, 21 are its 7 references read with other immediates, and all 29 are refuted. So "a candidate decoding cannot confirm" is two different sets: *refuted* (decoding reaches it and it is not that operand) and *not reached* (decoding cannot get there). Task 1 tells them apart, and the owner's ruling (below) refuses the second and passes the first.

**Nothing else this plan refuses occurs here.** No executable's `N_SECT` symbol or non-absolute export names a byte inside the header, and no bind, weak bind or lazy bind lies in the header's segment. Task 5's sweep: all 1,128 files give byte-identical output and identical messages before and after, and so does Claude Code (2.14 s before, 2.30 s after).

## Rulings

Decided 2026-09-26, while this plan was under review. No implementer needs to stop and ask.

1. **The code half of I1 (the owner's ruling): refuse a candidate that decoding confirms or cannot reach; pass one that decoding refutes.** A RIP-relative candidate whose target lies strictly inside (base, base + F) refuses the grow if decoding confirms it is that operand, or if decoding cannot reach it (no function starts, an instruction the decoder does not know before it, or an instruction that is partly data). One that decoding refutes (another instruction's bytes, data in code, where an instruction begins, or this operand with another immediate) passes. Measured over the 2,891 images above, this refuses nothing that M1 does not refuse already, Claude Code included, and it closes the hole of code that decoding cannot reach.
   - *Considered and lost:* passing every candidate decoding does not confirm. It changes nothing measured either, but lets code that decoding cannot reach, and that does name the header's inside, grow silently wrong. And refusing every candidate decoding does not confirm, refuted ones included, as the spec first put it, would refuse every image M1 repairs (each exact-base reference's other immediate lengths are refuted in-range candidates): the item 29 reproduction, Claude Code and 119 host executables.
2. **The executable route's encrypted and protected images** (found while planning M2b, whose raise refuses them): recorded as QUEUE item 33 by Task 5, stating only what was found, and not fixed here.
3. **CI is a post-push check.** This plan changes only `grow_test`'s hand-built fixtures, which are the same bytes on every host; after the owner pushes, CI on `macos-26-arm64` is a separate gate (Task 5's last step).

Plan M2b records the rulings on the raise route (`LC_LOAD_UPWARD_DYLIB`, which checks run on which route, the points the spec left open, and the docs that change with M2).

## Global Constraints

- **Line numbers** are at `5ca0612`, `main` when this plan was written. Each edit also quotes the text it anchors on, and that text is what to match: a `(`:N`)` is the line where the quoted text begins once the edits before it in the same task are made. `src/grow.c`'s and `tests/grow_test.c`'s numbers drift from task to task.
- **Build:** `B=/private/tmp/build/schmonz/drydock-native`; `/usr/local/mavergreen/bin/shipyard-cmake --build "$B" -j`. That directory is already configured. Do not configure with `--preset`. If it ever needs configuring again: `/usr/local/mavergreen/bin/shipyard-cmake -S . -B "$B" -G Ninja -DCMAKE_TOOLCHAIN_FILE=/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/MavericksToolchain.cmake -DMAVERICKS_EXPECTED_MODE=native -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64`.
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavergreen/bin/shipyard-ctest --test-dir "$B"`. At `5ca0612` the suite has 29 tests, and `chained_fixups` SKIPs. A single C test runs as `"$B/grow_test"`. **Green at every task's end** means both: the whole suite (29 tests, `chained_fixups` skipped), and `DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib "$B/grow_test"` ending `macho_grow_test: all cases pass`.
- **Rebuild check (clock skew here; `touch` can fail to relink).** Before every build, delete every object and the binaries you are about to run:
  ```sh
  find "$B/CMakeFiles" -name '*.o' -exec rm {} +
  rm -f "$B/libdrydockcore.a" "$B/grow_test" "$B/drydock-macho-rewrite"
  pre=$(cat "$B/.last-sha" 2>/dev/null)
  /usr/local/mavergreen/bin/shipyard-cmake --build "$B" -j
  shasum -a 256 "$B/grow_test" "$B/drydock-macho-rewrite" | tee "$B/.last-sha"
  ```
  Then confirm that the sums changed from `$pre`. A test result against an unchanged binary is not a result. Below, "build (rebuild check)" means exactly this.
- **TDD and mutation proof** for every code task. Write the test first and see it fail as the step says; then write the code. Then apply every row of the task's mutation table, each alone, rebuild (rebuild check), and see it fail with the row's text. Mutate only a saved copy's original: `M=$(mktemp -d -t m2a); cp src/grow.c src/hdrref.c "$M/"` (10.9's `mktemp -d` needs a template). Edit, rebuild, run, then `cp "$M/grow.c" src/grow.c && cmp src/grow.c "$M/grow.c"` (and the same for `hdrref.c`), and rebuild. **Never `git stash` and never `git checkout --`**: restore only from the saved copy. A mutation that no test kills is a finding: add the test that kills it, in the same task.
- **Comments are a last resort:** prefer a test, then the commit message, then a doc, then one inline sentence. No history narration, and no reference to a plan or spec from source (both are deleted once implemented).
- **Exit codes:** `EX_REFUSED` = 1 (`MR_REFUSED`), `EX_FAIL` = 2 (`MR_FAIL`). A statement never writes its input, and nothing is written on a refusal.
- **Every refusal this plan adds happens before anything is mutated**, with its reason on stderr: `ERROR: <reason>; refusing to grow`.
- **Every grep negative needs a positive control.** In shell, `rc=0; cmd || rc=$?`.
- **char[16] names:** print with `%.16s`, compare with `strncmp(..., 16)`.
- **Staging and pushing:** stage explicit paths only (never `git add -A` or `.`); commit on `main`; do not push. Every commit message ends with:
  ```
  Co-Authored-By: <authoring model> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
  ```
- **CI runs on `macos-26-arm64`** from a cross build. Everything this plan tests is in `grow_test`, whose fixtures are hand-built bytes, the same on every host. After the owner pushes, CI is a separate gate.

## Review Focus

1. **A candidate with several immediate lengths.** One disp32 can name several in-range targets, one per immediate length; an instruction confirms at most one of them. Decoding must refute the others, not leave them unreached, or Task 2 refuses every repaired image. Pinned by Task 1's `test_confirm_each_gives_each_candidate_its_verdict` ("a lea") and Task 2's `test_grow_repairs_header_references` staying green.
2. **The rule's edges.** base + 1 and base + F − 1 refuse; base + F (the first content) does not; base itself is M1's. For code (Task 2), symbols and exports (Task 3). Pinned by `test_grow_refuses_code_that_names_the_inside_of_the_header`, `test_grow_leaves_code_that_names_the_first_content`, `test_grow_refuses_a_symbol_inside_the_header`, `test_grow_refuses_an_export_inside_the_header`.
3. **What is not an address.** A stab, an `N_ABS` symbol and an absolute export may hold a value inside the header's range and are not refused. Pinned by `test_grow_leaves_other_symbols_that_name_the_inside_of_the_header` and `test_grow_leaves_an_absolute_export_inside_the_header`.
4. **`__PAGEZERO` is not the header's segment.** It starts at file offset 0 but maps none of the file, so a bind there is not refused for lying in the header's segment. Pinned by `test_grow_accepts_binds_outside_the_header_segment`.
5. **A symbol name the file does not hold.** A refusal names the symbol, and must not read past the string table or the image to do it. Pinned by `test_grow_refuses_a_symbol_inside_the_header`'s last three rows.

## Plan decisions at a glance

Each is repeated, with its reason, in the task that makes it.

- Task 1: the scan takes an inclusive range, `[first, last]`, so an exact target is `[t, t]` and nothing overflows. `mhr_confirm_each` never stops on its own; its callback does. Its verdicts are `MHR_CONFIRMED`, `MHR_REFUTED` (new), `MHR_UNCONFIRMED` (here: decoding cannot reach it) and `MHR_NO_STARTS`. `mhr_confirm`'s contract is unchanged: refuted and not reached are both `MHR_UNCONFIRMED` to it.
- Task 2: the owner's ruling: a confirmed or not-reached candidate refuses, a refuted one passes. The check runs after M1's exact-base check, so M1's messages keep their priority.
- Task 3: symbols are `N_SECT` and not stabs, as M1's symbol repair has them; stabs are M2b's. An export's kind comes from the trie walk (`MG_K_ABS`, new), so an absolute export's value is not read as an offset.
- Task 4: every DO_BIND of the bind, weak-bind and lazy-bind streams, read with `mo_bind_observe` (`src/ordinals.h`), the decoder the renumberer and `imports` already share. Stream bounds and decode failures refuse too.
- Task 5: the sweep and the docs. The shas go into QUEUE item 29 and the spec's M2 section.

## File structure

| file | responsibility | task |
|---|---|---|
| `src/hdrref.h`, `src/hdrref.c` | `mhr_cand.target`; `mhr_scan_range`; `MHR_REFUTED`, `mhr_verdict_fn`, `mhr_confirm_each`; `mhr_confirm` on top of it | 1 |
| `src/grow.h` | `MG_K_ABS` (3); `mg_grow_header`'s contract (2, 3, 4) | 2–4 |
| `src/grow.c` | `mg_inside_refs_ok` (2); `mg_exports_ok`, the symbol half in `mg_hsym_cb`, `mg_sym_name` (3); `mg_binds_ok` (4) | 2–4 |
| `tests/grow_test.c` | the range scan and verdicts (1); code (2); symbols and exports (3); binds (4) | 1–4 |
| `docs/superpowers/QUEUE.md` | item 29's I1 paragraph: the code half (2); the rest, the table row, and item 33 (5) | 2, 5 |
| `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md` | M2's first two bullets marked done | 5 |

`CMakeLists.txt` does not change.

## How this plan was checked

Every code block below was cut from a checkpoint: a `git archive` of `5ca0612` in a scratch directory, with each task applied and committed in turn, built in its own directory configured by the command above. A script then parsed this document's own edit instructions (every "In `file`, replace / immediately before / immediately after" block), applied them to a fresh archive of `5ca0612` task by task, and compared the tree after each task with that task's checkpoint: identical, file for file. At each checkpoint:

- the whole suite passed (29 tests, `chained_fixups` skipped), with no compiler warning, and `grow_test` passed under libgmalloc;
- each "see it fail" step was run as written, by applying only that task's test edits to the checkpoint before it: the outputs quoted are what it printed;
- every row of every mutation table (57 rows) was applied alone to that task's finished files, rebuilt after deleting every object and the binaries (with the sums compared), and failed with the row's text. Task 2's row 1 is the lost alternative's line: it fails the ruling's test.

Task 5's sweep numbers are from those builds against a build of `5ca0612`.

---

### Task 1: Scan a range, and give every candidate a verdict

**Files** (each edit block below gives its line):
- Modify: `src/hdrref.h` (`mhr_cand`; after `mhr_scan`'s declaration; `MHR_UNCONFIRMED`)
- Modify: `src/hdrref.c` (`mhr_code`; `mhr_scan_code`; `struct mhr_ctx`, `mhr_seg_cb`, `mhr_walk`, `mhr_scan`; `mhr_sweep`; `mhr_confirm_cb` and `mhr_confirm`)
- Test: `tests/grow_test.c` (`hr_confirm`; new tests before `int main(void) {`; calls before `if (fails)`)

**Interfaces:**
- Consumes: `mx_decode` (`src/x86len.h`), `mi_wrap`, `mi_each_lc`, `mi_image_base` (`src/image.h`); in the tests, `build_code_image`, `hr_plant`, `hr_record`, `struct hr_seen`, `struct hr_code`, `hr_push_lea`, `HR_ONE_FUNCTION`, `hr_add_lc` (all in `tests/grow_test.c`).
- Produces (Tasks 2–4 and M2b use them):
  - `mhr_cand` gains `uint64_t target`, the address the operand names with its `immlen`.
  - `int64_t mhr_scan_range(const uint8_t *buf, size_t fsize, uint64_t first, uint64_t last, mhr_fn fn, void *ctx);` — `mhr_scan` over `[first, last]`, one candidate per immediate length that lands there.
  - `#define MHR_REFUTED 4`; `typedef int (*mhr_verdict_fn)(const mhr_cand *c, int verdict, void *ctx);`
  - `int mhr_confirm_each(const uint8_t *buf, size_t fsize, uint64_t first, uint64_t last, mhr_verdict_fn fn, void *ctx);` — returns `MHR_CONFIRMED` (every candidate passed to `fn`, or `fn` stopped), `MHR_UNSCANNABLE`, or -1.
  - In `tests/grow_test.c`: `hr_code_image`, `HR_FIRST`, `HR_LAST`, `struct hr_verdicts`, `hr_verdict`, `hr_confirm_each`, `hr_push_lea_inside`.

**Plan decisions.**

- **An inclusive range.** `[first, last]`: the exact scan is `[t, t]`, and a range ending at `UINT64_MAX` cannot overflow a half-open bound. The strictly-inside range is `[base + 1, base + F − 1]`.
- **Three verdicts, not two.** `mhr_sweep` now returns 1 (this operand, this immediate), 0 (decoding reached the bytes and they are something else: another instruction's bytes, data in code, where an instruction begins, or this operand with another immediate), or -1 (an instruction it cannot decode, or one that is partly data, lies before them). `mhr_confirm_cb` maps these to `MHR_CONFIRMED`, `MHR_REFUTED` and `MHR_UNCONFIRMED`; a candidate with no function start of its own is `MHR_UNCONFIRMED`, or `MHR_NO_STARTS` with no starts at all. The owner's question needs refuted and not reached apart (see "The owner's question").
- **`mhr_confirm` keeps its contract.** It is `mhr_confirm_each` over `[base, base]`, stopping at the first candidate not confirmed; a refuted one reports `MHR_UNCONFIRMED`, as before. Every M1 test stays as it is.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, replace (`:2550`):

```c
static int hr_confirm(const struct hr_code *k, mhr_cand *bad) {
    uint8_t *buf = build_code_image();
    memcpy(buf + HR_FOFF, k->b, k->n);
    if (k->fs) hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, k->fs, k->nfs);
    if (k->dic) hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, k->dic, k->ndic);
```

with:

```c
static uint8_t *hr_code_image(const struct hr_code *k) {
    uint8_t *buf = build_code_image();
    memcpy(buf + HR_FOFF, k->b, k->n);
    if (k->fs) hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, k->fs, k->nfs);
    if (k->dic) hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, k->dic, k->ndic);
    return buf;
}

static int hr_confirm(const struct hr_code *k, mhr_cand *bad) {
    uint8_t *buf = hr_code_image(k);
```

In `tests/grow_test.c`, immediately before (`:3913`):

```c
int main(void) {
```

insert:

```c
/* ---- a range of targets ----
 * The one rule refuses what names a byte strictly between the header and
 * its first content, so the scan also takes a range, [first, last], and
 * says what each candidate names. */
#define HR_FIRST (HR_BASE + 1)
#define HR_LAST  (HR_BASE + 0xfff)

static void test_scan_reports_each_candidates_target(void) {
    uint8_t code[16];
    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 2, 0x3d, 2, HR_BASE);
    struct hr_seen s = { { { 0 } }, 0, 0 };
    mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, hr_record, &s);
    CHECK(s.n == 1 && s.c[0].target == HR_BASE && s.c[0].immlen == 2,
          "scan: the candidate names %#llx with a 2-byte immediate (%d found, %#llx, %d)",
          (unsigned long long)HR_BASE, s.n, (unsigned long long)s.c[0].target, s.c[0].immlen);
}

/* One operand whose target is first - 2 without an immediate reaches the
 * range only with a 2- or 4-byte one; one at last - 1 leaves it with a
 * 2-byte one. */
static void test_scan_range_takes_its_bounds_inclusively(void) {
    uint8_t *buf = build_code_image();
    hr_plant(buf + HR_FOFF, HR_CODE, 0x20, 0x05, 0, HR_FIRST - 2);
    hr_plant(buf + HR_FOFF, HR_CODE, 0x40, 0x05, 0, HR_LAST - 1);
    struct hr_seen s = { { { 0 } }, 0, 0 };
    int64_t n = mhr_scan_range(buf, HR_IMG_SIZE, HR_FIRST, HR_LAST, hr_record, &s);
    static const struct { uint64_t addr; int immlen; uint64_t target; } want[4] = {
        { HR_CODE + 0x21, 2, HR_FIRST },
        { HR_CODE + 0x21, 4, HR_FIRST + 2 },
        { HR_CODE + 0x41, 0, HR_LAST - 1 },
        { HR_CODE + 0x41, 1, HR_LAST },
    };
    CHECK(n == 4 && s.n == 4, "range: %lld candidates, want 4", (long long)n);
    for (int k = 0; k < 4 && k < s.n; k++)
        CHECK(s.c[k].addr == want[k].addr && s.c[k].immlen == want[k].immlen &&
              s.c[k].target == want[k].target,
              "range: candidate %d is at %#llx, immediate %d, naming %#llx; want %#llx, %d, %#llx",
              k, (unsigned long long)s.c[k].addr, s.c[k].immlen, (unsigned long long)s.c[k].target,
              (unsigned long long)want[k].addr, want[k].immlen, (unsigned long long)want[k].target);
    free(buf);
}

struct hr_verdicts { mhr_cand c[8]; int v[8]; int n; int stop_after; };
static int hr_verdict(const mhr_cand *c, int verdict, void *ctx) {
    struct hr_verdicts *s = (struct hr_verdicts *)ctx;
    if (s->n < 8) { s->c[s->n] = *c; s->v[s->n] = verdict; }
    s->n++;
    return s->stop_after && s->n >= s->stop_after;
}

static int hr_confirm_each(const struct hr_code *k, struct hr_verdicts *s) {
    uint8_t *buf = hr_code_image(k);
    int r = mhr_confirm_each(buf, HR_IMG_SIZE, HR_FIRST, HR_LAST, hr_verdict, s);
    free(buf);
    return r;
}

/* push; lea base+16(%rip), %rax. Its disp32 names base + 16 with no
 * immediate, which decoding confirms, and base + 17, + 18 and + 20 with one,
 * which decoding refutes: the lea has none. */
static struct hr_code hr_push_lea_inside(void) {
    struct hr_code k = hr_push_lea();
    hr_plant(k.b, HR_CODE, 3, 0x05, 0, HR_BASE + 16);
    return k;
}

/* Each case's four candidates share a disp32, at `at`, and name base + 16,
 * + 17, + 18 and + 20; `v` is each one's verdict. */
static void check_verdicts(const char *what, const struct hr_code *k, uint64_t at, const int v[4]) {
    static const int immlen[4] = { 0, 1, 2, 4 };
    struct hr_verdicts s = { { { 0 } }, { 0 }, 0, 0 };
    int r = hr_confirm_each(k, &s);
    CHECK(r == MHR_CONFIRMED && s.n == 4, "verdicts: %s: 4 candidates (got %d, %d)", what, r, s.n);
    for (int i = 0; i < 4 && i < s.n; i++)
        CHECK(s.c[i].addr == at && s.c[i].immlen == immlen[i] && s.v[i] == v[i],
              "verdicts: %s: with a %d-byte immediate, verdict %d, want %d (at %#llx)", what,
              immlen[i], s.v[i], v[i], (unsigned long long)s.c[i].addr);
}

static void test_confirm_each_gives_each_candidate_its_verdict(void) {
    static const int lea[4] = { MHR_CONFIRMED, MHR_REFUTED, MHR_REFUTED, MHR_REFUTED };
    static const int refuted[4] = { MHR_REFUTED, MHR_REFUTED, MHR_REFUTED, MHR_REFUTED };
    static const int unreached[4] = { MHR_UNCONFIRMED, MHR_UNCONFIRMED, MHR_UNCONFIRMED,
                                      MHR_UNCONFIRMED };
    static const int nostarts[4] = { MHR_NO_STARTS, MHR_NO_STARTS, MHR_NO_STARTS, MHR_NO_STARTS };
    static const uint8_t late[] = { 0x90, 0x20, 0x00 };                            /* base + 0x1010 */
    static const uint8_t data[] = { 0x01, 0x10, 0, 0, 0x07, 0x00, 0x01, 0x00 };   /* +1, 7 bytes */
    static const uint8_t disp[] = { 0x04, 0x10, 0, 0, 0x04, 0x00, 0x01, 0x00 };   /* +4, 4 bytes */
    struct hr_code k = hr_push_lea_inside();
    check_verdicts("a lea", &k, HR_CODE + 4, lea);

    struct hr_code mov = { { 0x55, 0xb8 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(mov.b, HR_CODE, 2, 0x05, 0, HR_BASE + 16);                /* mov $imm32, %eax */
    check_verdicts("inside mov's immediate", &mov, HR_CODE + 3, refuted);

    struct hr_code next = { { 0x55, 0xb8, 0x00, 0x00, 0x00 }, 11, HR_ONE_FUNCTION,
                            sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(next.b, HR_CODE, 5, 0x05, 0, HR_BASE + 16);               /* the imm32's last byte */
    check_verdicts("where the next instruction begins", &next, HR_CODE + 6, refuted);

    k = hr_push_lea_inside();
    k.dic = data; k.ndic = sizeof data;
    check_verdicts("in data in code", &k, HR_CODE + 4, refuted);

    k = hr_push_lea_inside();
    k.dic = disp; k.ndic = sizeof disp;
    check_verdicts("in an instruction that is partly data", &k, HR_CODE + 4, unreached);

    struct hr_code evex = { { 0x55, 0x62, 0x90, 0x90, 0x90, 0x48, 0x8d }, 12, HR_ONE_FUNCTION,
                            sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(evex.b, HR_CODE, 7, 0x05, 0, HR_BASE + 16);
    check_verdicts("past what the decoder cannot decode", &evex, HR_CODE + 8, unreached);

    k = hr_push_lea_inside();
    k.fs = late; k.nfs = sizeof late;
    check_verdicts("with no function start at or before it", &k, HR_CODE + 4, unreached);

    k = hr_push_lea_inside();
    k.fs = NULL;
    check_verdicts("with no LC_FUNCTION_STARTS", &k, HR_CODE + 4, nostarts);
}

static void test_confirm_each_stops_when_asked(void) {
    struct hr_code k = hr_push_lea_inside();
    struct hr_verdicts s = { { { 0 } }, { 0 }, 0, 2 };
    int r = hr_confirm_each(&k, &s);
    CHECK(r == MHR_CONFIRMED && s.n == 2, "confirm each: stopped after 2 (got %d, %d)", r, s.n);
}

static void test_confirm_each_reports_an_image_it_cannot_scan(void) {
    struct hr_code k = hr_push_lea_inside();
    struct hr_verdicts s = { { { 0 } }, { 0 }, 0, 0 };
    uint8_t *buf = hr_code_image(&k);
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    sc[1].size = HR_IMG_SIZE;                          /* __stubs runs past the image */
    int r = mhr_confirm_each(buf, HR_IMG_SIZE, HR_FIRST, HR_LAST, hr_verdict, &s);
    CHECK(r == MHR_UNSCANNABLE, "confirm each: an instruction section past the image (got %d)", r);
    free(buf);
}

```

In `tests/grow_test.c`, immediately after (`:4184`):

```c
    test_find_trie_refuses_a_short_dyld_info();
```

insert:

```c
    test_scan_reports_each_candidates_target();
    test_scan_range_takes_its_bounds_inclusively();
    test_confirm_each_gives_each_candidate_its_verdict();
    test_confirm_each_stops_when_asked();
    test_confirm_each_reports_an_image_it_cannot_scan();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check).
Expected: the build fails compiling `grow_test.c`, with 11 errors, four `no member named 'target' in 'mhr_cand'` and seven `use of undeclared identifier 'MHR_REFUTED'`, the first of each being:

```
tests/grow_test.c:3926:30: error: no member named 'target' in 'mhr_cand'
tests/grow_test.c:3994:48: error: use of undeclared identifier 'MHR_REFUTED'
```

and two warnings, `implicit declaration of function 'mhr_scan_range'` and `… 'mhr_confirm_each'`.

- [ ] **Step 3: Declare the range scan and the verdicts**

In `src/hdrref.h`, replace (`:22`):

```c
    int      immlen;  /* 0, 1, 2 or 4: the immediate length that makes the target exact */
```

with:

```c
    int      immlen;  /* 0, 1, 2 or 4: the immediate length that gives `target` */
    uint64_t target;  /* the address the operand names, with that immediate */
```

In `src/hdrref.h`, replace (`:44`):

```c
/* mhr_confirm's answers. */
#define MHR_CONFIRMED   0  /* every candidate is an instruction, or there is none */
#define MHR_UNSCANNABLE 1  /* an instruction section lies past the end of the image, or so
                             * does LC_DATA_IN_CODE's payload, or its size is not a multiple
                             * of its 8-byte entry */
#define MHR_NO_STARTS   2  /* a candidate, and no LC_FUNCTION_STARTS to decode it from */
#define MHR_UNCONFIRMED 3  /* a candidate that decoding its function does not confirm */
```

with:

```c
/* mhr_scan for every candidate whose target lies in [first, last]: one per
 * immediate length that puts it there. */
int64_t mhr_scan_range(const uint8_t *buf, size_t fsize, uint64_t first, uint64_t last,
                       mhr_fn fn, void *ctx);

/* mhr_confirm's answers. */
#define MHR_CONFIRMED   0  /* every candidate is an instruction, or there is none */
#define MHR_UNSCANNABLE 1  /* an instruction section lies past the end of the image, or so
                             * does LC_DATA_IN_CODE's payload, or its size is not a multiple
                             * of its 8-byte entry */
#define MHR_NO_STARTS   2  /* a candidate, and no LC_FUNCTION_STARTS to decode it from */
#define MHR_UNCONFIRMED 3  /* a candidate that decoding its function does not confirm */
#define MHR_REFUTED     4  /* mhr_confirm_each only: decoding reaches the candidate and
                            * finds another instruction's bytes, data in code, or this
                            * operand with another immediate */

/* Called once per candidate with MHR_CONFIRMED, MHR_REFUTED, MHR_NO_STARTS
 * or MHR_UNCONFIRMED, which here means that decoding cannot reach it.
 * Returning nonzero stops the walk. */
typedef int (*mhr_verdict_fn)(const mhr_cand *c, int verdict, void *ctx);

/* Decodes, as mhr_confirm does, every candidate mhr_scan_range finds for
 * [first, last], and passes each to `fn` with its verdict. Returns
 * MHR_CONFIRMED when every candidate was passed to `fn`, or `fn` stopped the
 * walk; MHR_UNSCANNABLE as mhr_confirm does; or -1 as mhr_confirm does. */
int mhr_confirm_each(const uint8_t *buf, size_t fsize, uint64_t first, uint64_t last,
                     mhr_verdict_fn fn, void *ctx);
```

- [ ] **Step 4: Scan the range, and give each candidate its verdict**

In `src/hdrref.c`, replace (`:14`):

```c
                         uint64_t target, mhr_fn fn, void *ctx, int *stopped) {
    uint64_t n = 0;
    for (uint64_t i = 0; i + 5 <= size; i++) {
        if ((code[i] & 0xC7) != 0x05) continue;
        int32_t disp;
        memcpy(&disp, code + i + 1, sizeof disp);
        uint64_t at = addr + i + 1;
        for (int k = 0; k < 4; k++) {
            if (at + 4 + (uint64_t)mhr_immlens[k] + (uint64_t)(int64_t)disp != target) continue;
            mhr_cand c = { at, off + i + 1, mhr_immlens[k] };
```

with:

```c
                         uint64_t first, uint64_t last, mhr_fn fn, void *ctx, int *stopped) {
    uint64_t n = 0;
    for (uint64_t i = 0; i + 5 <= size; i++) {
        if ((code[i] & 0xC7) != 0x05) continue;
        int32_t disp;
        memcpy(&disp, code + i + 1, sizeof disp);
        uint64_t at = addr + i + 1;
        for (int k = 0; k < 4; k++) {
            uint64_t t = at + 4 + (uint64_t)mhr_immlens[k] + (uint64_t)(int64_t)disp;
            if (t < first || t > last) continue;
            mhr_cand c = { at, off + i + 1, mhr_immlens[k], t };
```

In `src/hdrref.c`, replace (`:35`):

```c
    return mhr_code(code, size, addr, off, target, fn, ctx, &stopped);
}

struct mhr_ctx {
    const uint8_t *buf;
    size_t fsize;
    uint64_t target;
```

with:

```c
    return mhr_code(code, size, addr, off, target, target, fn, ctx, &stopped);
}

struct mhr_ctx {
    const uint8_t *buf;
    size_t fsize;
    uint64_t first, last;
```

In `src/hdrref.c`, replace (`:60`):

```c
                         w->target, w->fn, w->ctx, &w->stopped);
        if (w->stopped) return 1;
    }
    return 0;
}

static int64_t mhr_walk(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx,
                        const struct section_64 **sect) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0) return -1;
    struct mhr_ctx w = { buf, fsize, target, fn, ctx, 0, 0, 0, sect };
    mi_each_lc(&im, mhr_seg_cb, &w);
    return w.bad ? -1 : (int64_t)w.n;
}

int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx) {
    return mhr_walk(buf, fsize, target, fn, ctx, NULL);
```

with:

```c
                         w->first, w->last, w->fn, w->ctx, &w->stopped);
        if (w->stopped) return 1;
    }
    return 0;
}

static int64_t mhr_walk(const uint8_t *buf, size_t fsize, uint64_t first, uint64_t last,
                        mhr_fn fn, void *ctx, const struct section_64 **sect) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0) return -1;
    struct mhr_ctx w = { buf, fsize, first, last, fn, ctx, 0, 0, 0, sect };
    mi_each_lc(&im, mhr_seg_cb, &w);
    return w.bad ? -1 : (int64_t)w.n;
}

int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx) {
    return mhr_walk(buf, fsize, target, target, fn, ctx, NULL);
}

int64_t mhr_scan_range(const uint8_t *buf, size_t fsize, uint64_t first, uint64_t last,
                       mhr_fn fn, void *ctx) {
    return mhr_walk(buf, fsize, first, last, fn, ctx, NULL);
```

In `src/hdrref.c`, replace (`:173`):

```c
 * immediate that makes its target c's. */
```

with:

```c
 * immediate that makes its target c's; 0 if it is not, or c's bytes are data
 * in code or begin an instruction; -1 if decoding cannot reach c. */
```

In `src/hdrref.c`, replace (`:190`):

```c
        if (!mx_decode(code + (pc - s->addr), (size_t)(end - pc), &in)) return 0;
        /* A range starting inside [pc, pc+len) -- not at or before pc -- means
         * this "instruction" is partly data: its bytes are not all code, so it
         * cannot be the one that addresses c. */
        if (k < m->ndic && m->dic[k].from < pc + (uint64_t)in.len) return 0;
```

with:

```c
        if (!mx_decode(code + (pc - s->addr), (size_t)(end - pc), &in)) return -1;
        /* A range starting inside [pc, pc+len) -- not at or before pc -- means
         * this "instruction" is partly data: its bytes are not all code, so it
         * cannot be the one that addresses c. */
        if (k < m->ndic && m->dic[k].from < pc + (uint64_t)in.len) return -1;
```

In `src/hdrref.c`, replace (`:213`):

```c
    int status;
    mhr_cand *bad;
    struct mhr_resume r;
};

static int mhr_confirm_cb(const mhr_cand *c, void *ctx_) {
    struct mhr_confirm_ctx *x = (struct mhr_confirm_ctx *)ctx_;
    const struct mhr_map *m = x->m;
    size_t lo = 0, hi = m->nstarts;               /* past the last start at or below c */
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (m->starts[mid] <= c->addr) lo = mid + 1; else hi = mid; }
    if (lo > 0 && m->starts[lo - 1] >= x->sect->addr && mhr_sweep(m, x->sect, m->starts[lo - 1], c, &x->r))
        return 0;
    x->status = m->nstarts ? MHR_UNCONFIRMED : MHR_NO_STARTS;
    *x->bad = *c;
    return 1;
}

int mhr_confirm(const uint8_t *buf, size_t fsize, mhr_cand *bad) {
    mi_image im;
    struct mhr_map m = { buf, 0, NULL, 0, NULL, 0 };
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0 || mi_image_base(&im, &m.base) != 0) return -1;
    int rc = -1, mr = mhr_map_read(&m, &im, fsize);
    if (mr == MHR_MAP_BAD_DIC) {
        rc = MHR_UNSCANNABLE;
    } else if (mr == 0) {
        struct mhr_confirm_ctx x = { &m, NULL, MHR_CONFIRMED, bad, { NULL, 0, 0, 0 } };
        rc = mhr_walk(buf, fsize, m.base, mhr_confirm_cb, &x, &x.sect) < 0 ? MHR_UNSCANNABLE : x.status;
    }
    free(m.starts);
    free(m.dic);
    return rc;
}
```

with:

```c
    mhr_verdict_fn fn;
    void *ctx;
    struct mhr_resume r;
};

static int mhr_confirm_cb(const mhr_cand *c, void *ctx_) {
    struct mhr_confirm_ctx *x = (struct mhr_confirm_ctx *)ctx_;
    const struct mhr_map *m = x->m;
    size_t lo = 0, hi = m->nstarts;               /* past the last start at or below c */
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (m->starts[mid] <= c->addr) lo = mid + 1; else hi = mid; }
    if (lo == 0 || m->starts[lo - 1] < x->sect->addr)
        return x->fn(c, m->nstarts ? MHR_UNCONFIRMED : MHR_NO_STARTS, x->ctx);
    int s = mhr_sweep(m, x->sect, m->starts[lo - 1], c, &x->r);
    return x->fn(c, s > 0 ? MHR_CONFIRMED : s == 0 ? MHR_REFUTED : MHR_UNCONFIRMED, x->ctx);
}

int mhr_confirm_each(const uint8_t *buf, size_t fsize, uint64_t first, uint64_t last,
                     mhr_verdict_fn fn, void *ctx) {
    mi_image im;
    struct mhr_map m = { buf, 0, NULL, 0, NULL, 0 };
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0 || mi_image_base(&im, &m.base) != 0) return -1;
    int rc = -1, mr = mhr_map_read(&m, &im, fsize);
    if (mr == MHR_MAP_BAD_DIC) {
        rc = MHR_UNSCANNABLE;
    } else if (mr == 0) {
        struct mhr_confirm_ctx x = { &m, NULL, fn, ctx, { NULL, 0, 0, 0 } };
        rc = mhr_walk(buf, fsize, first, last, mhr_confirm_cb, &x, &x.sect) < 0 ? MHR_UNSCANNABLE
                                                                                : MHR_CONFIRMED;
    }
    free(m.starts);
    free(m.dic);
    return rc;
}

/* mhr_confirm's verdict callback: stop at the first candidate not confirmed. */
struct mhr_first { int status; mhr_cand *bad; };
static int mhr_first_cb(const mhr_cand *c, int verdict, void *ctx_) {
    struct mhr_first *f = (struct mhr_first *)ctx_;
    if (verdict == MHR_CONFIRMED) return 0;
    f->status = verdict == MHR_REFUTED ? MHR_UNCONFIRMED : verdict;
    *f->bad = *c;
    return 1;
}

int mhr_confirm(const uint8_t *buf, size_t fsize, mhr_cand *bad) {
    mi_image im;
    uint64_t base;
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0 || mi_image_base(&im, &base) != 0) return -1;
    struct mhr_first f = { MHR_CONFIRMED, bad };
    int rc = mhr_confirm_each(buf, fsize, base, base, mhr_first_cb, &f);
    return rc == MHR_CONFIRMED ? f.status : rc;
}
```

- [ ] **Step 5: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: `macho_grow_test: all cases pass`. Then green (the suite, and `grow_test` under libgmalloc).

- [ ] **Step 6: Mutation proof** (file `src/hdrref.c`; test binary `$B/grow_test`; each row fails with the quoted `FAIL:` text)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `            if (t < first \|\| t > last) continue;` | `            if (t < first \|\| t >= last) continue;` | `FAIL: range: 3 candidates, want 4` |
| 2 | `            if (t < first \|\| t > last) continue;` | `            if (t <= first \|\| t > last) continue;` | `FAIL: range: 3 candidates, want 4` |
| 3 | `            mhr_cand c = { at, off + i + 1, mhr_immlens[k], t };` | `            mhr_cand c = { at, off + i + 1, mhr_immlens[k], 0 };` | `FAIL: scan: the candidate names 0x100000000 with a 2-byte immediate` |
| 4 | `    return mhr_code(code, size, addr, off, target, target, fn, ctx, &stopped);` | `    return mhr_code(code, size, addr, off, target, target + 1, fn, ctx, &stopped);` | `FAIL: scan: a target one byte past the base is a candidate` |
| 5 | `    return mhr_walk(buf, fsize, target, target, fn, ctx, NULL);` | `    return mhr_walk(buf, fsize, target, target + 1, fn, ctx, NULL);` | `FAIL: image scan: 4 candidates, want __text's and __stubs'` |
| 6 | `    return mhr_walk(buf, fsize, first, last, fn, ctx, NULL);` | `    return mhr_walk(buf, fsize, first, first, fn, ctx, NULL);` | `FAIL: range: 1 candidates, want 4` |
| 7 | `        if (!mx_decode(code + (pc - s->addr), (size_t)(end - pc), &in)) return -1;` | `        if (!mx_decode(code + (pc - s->addr), (size_t)(end - pc), &in)) return 0;` | `FAIL: verdicts: past what the decoder cannot decode: with a 0-byte immediate, verdict 4, want 3` |
| 8 | `        if (k < m->ndic && m->dic[k].from < pc + (uint64_t)in.len) return -1;` | `        if (k < m->ndic && m->dic[k].from < pc + (uint64_t)in.len) return 0;` | `FAIL: verdicts: in an instruction that is partly data: with a 0-byte immediate, verdict 4, want 3` |
| 9 | `        pc += (uint64_t)in.len;`<br>`    }`<br>`    return 0;` | `        pc += (uint64_t)in.len;`<br>`    }`<br>`    return -1;` | `FAIL: verdicts: where the next instruction begins: with a 0-byte immediate, verdict 3, want 4` |
| 10 | `    if (lo == 0 \|\| m->starts[lo - 1] < x->sect->addr)` | `    if (lo == 0)` | `FAIL: confirm: __stubs' lea has no function of its own` |
| 11 | `        return x->fn(c, m->nstarts ? MHR_UNCONFIRMED : MHR_NO_STARTS, x->ctx);` | `        return x->fn(c, MHR_UNCONFIRMED, x->ctx);` | `FAIL: verdicts: with no LC_FUNCTION_STARTS: with a 0-byte immediate, verdict 3, want 2` |
| 12 | `    return x->fn(c, s > 0 ? MHR_CONFIRMED : s == 0 ? MHR_REFUTED : MHR_UNCONFIRMED, x->ctx);` | `    return x->fn(c, s > 0 ? MHR_CONFIRMED : MHR_REFUTED, x->ctx);` | `FAIL: verdicts: past what the decoder cannot decode: with a 0-byte immediate, verdict 4, want 3` |
| 13 | `    return x->fn(c, s > 0 ? MHR_CONFIRMED : s == 0 ? MHR_REFUTED : MHR_UNCONFIRMED, x->ctx);` | `    return x->fn(c, s > 0 ? MHR_CONFIRMED : s == 0 ? MHR_UNCONFIRMED : MHR_UNCONFIRMED, x->ctx);` | `FAIL: verdicts: a lea: with a 1-byte immediate, verdict 3, want 4` |
| 14 | `    return x->fn(c, s > 0 ? MHR_CONFIRMED : s == 0 ? MHR_REFUTED : MHR_UNCONFIRMED, x->ctx);` | `    return x->fn(c, s >= 0 ? MHR_CONFIRMED : MHR_UNCONFIRMED, x->ctx);` | `FAIL: verdicts: a lea: with a 1-byte immediate, verdict 0, want 4` |
| 15 | `        rc = mhr_walk(buf, fsize, first, last, mhr_confirm_cb, &x, &x.sect) < 0 ? MHR_UNSCANNABLE` | `        rc = mhr_walk(buf, fsize, first, first, mhr_confirm_cb, &x, &x.sect) < 0 ? MHR_UNSCANNABLE` | `FAIL: verdicts: a lea: 4 candidates (got 0, 0)` |
| 16 | `                                                                                : MHR_CONFIRMED;` | `                                                                                : MHR_UNCONFIRMED;` | `FAIL: verdicts: a lea: 4 candidates (got 3, 4)` |
| 17 | `    if (verdict == MHR_CONFIRMED) return 0;` | `    if (verdict != MHR_NO_STARTS) return 0;` | `FAIL: confirm: a lookalike in an immediate is unconfirmed` |
| 18 | `    f->status = verdict == MHR_REFUTED ? MHR_UNCONFIRMED : verdict;` | `    f->status = verdict;` | `FAIL: confirm: a lookalike in an immediate is unconfirmed` |
| 19 | `    *f->bad = *c;`<br>`    return 1;` | `    *f->bad = *c;`<br>`    return 0;` | `FAIL: confirm: no LC_FUNCTION_STARTS, so nothing to decode from` |
| 20 | `    int rc = mhr_confirm_each(buf, fsize, base, base, mhr_first_cb, &f);` | `    int rc = mhr_confirm_each(buf, fsize, base, base + 1, mhr_first_cb, &f);` | `FAIL: confirm: push; lea base(%rip) is an instruction` |
| 21 | `    return rc == MHR_CONFIRMED ? f.status : rc;` | `    return f.status;` | `FAIL: confirm: ` |

- [ ] **Step 7: Commit**

```bash
git add src/hdrref.h src/hdrref.c tests/grow_test.c
git commit -m "feat(hdrref): scan a range of targets, and give each candidate a verdict

The one rule refuses code that names a byte strictly between the header
and its first content, so the header-reference scan now takes a range,
[first, last], and says what each candidate names. mhr_confirm_each
decodes every candidate in a range without stopping, and says of each
whether decoding confirms it, refutes it (another instruction's bytes,
data, or this operand with another immediate) or cannot reach it: an
exact-base reference is, read with other immediates, three candidates
inside the header that decoding refutes. mhr_confirm is built on it and
keeps its contract.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 2: Refuse code that names the inside of the header (the owner's I1 ruling)

This task carries Ruling 1: a candidate decoding confirms or cannot reach refuses; one it refutes passes.

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (new functions before `/* The symbols that name the header: each N_SECT symbol, not a stab, whose`; one call after `if (mg_header_refs_ok(buf, fsize, grow) != 0) return -1;`)
- Modify: `src/grow.h` (`mg_grow_header`'s contract)
- Modify: `docs/superpowers/QUEUE.md` (item 29's I1 paragraph)
- Test: `tests/grow_test.c` (new tests before `int main(void) {`; calls before `if (fails)`)

**Interfaces:**
- Consumes: Task 1's `mhr_confirm_each`, `MHR_CONFIRMED`, `MHR_REFUTED`, `mhr_cand.target`; in `src/grow.c`, `mg_base_of`; in the tests, `build_image`, `MG_T_PLAINSECT`, `MG_T_FUNCSTARTS`, `plant_header_refs`, `HR_PLAIN_VA`, `find_section_struct`, `hr_plant`, `refs_to`, `check_grow_refuses_header_refs`.
- Produces: `static int mg_inside_refs_ok(const uint8_t *buf, size_t fsize, uint64_t base, uint32_t first);` (M2b's raise route runs it unchanged, from the same call site). In the tests: `build_inside_ref(uint64_t target, uint32_t at, int opts, size_t *fsize)`.

**Plan decisions.**

- **Which candidates refuse** (Ruling 1): `MHR_CONFIRMED`, `MHR_UNCONFIRMED` (not reached) and `MHR_NO_STARTS`; only `MHR_REFUTED` passes. So `mg_inside_cb` has one filter line, `if (verdict == MHR_REFUTED) return 0;`.
- **Where.** Right after M1's `mg_header_refs_ok`, before any other audit: an image whose exact-base references M1 refuses keeps M1's message. Measured, every image with an in-range candidate decoding cannot reach also has an exact-base one M1 refuses, so this check has not yet been the first to refuse a real image.
- **The range.** `[base + 1, base + F − 1]`, F being `insert` (`mg_first_sect_off`), as the one rule says.
- **The message** names the candidate's disp32 address and its target, in the words of the data half's pointer refusal: `ERROR: the code at X names T, between the header at B and its first content at C, which a grow moves apart; refusing to grow`. "The code at X" means the bytes of an instruction section, which is what a not-reached candidate is; the contract in `src/grow.h` says so.
- **A failed search.** `mhr_confirm_each` returns something other than `MHR_CONFIRMED` only when memory runs out: `mg_header_refs_ok`, just before, has already refused every image whose instruction sections or data in code it cannot read. That branch refuses too (`could not search the image …`), and is not in the mutation table: no test can reach it.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately before (`:4055`):

```c
int main(void) {
```

insert:

```c
/* ---- the one rule's code half ----
 * __plain holds one lea (plant_header_refs), at __plain + `at`, whose
 * disp32 names `target`; with MG_T_FUNCSTARTS in `opts`, __plain is a
 * function. */
static uint8_t *build_inside_ref(uint64_t target, uint32_t at, int opts, size_t *fsize) {
    uint32_t sect_off;
    uint8_t *buf = build_image(fsize, &sect_off, MG_T_PLAINSECT | opts);
    plant_header_refs(buf, *fsize, &at, 1);
    struct section_64 *pl = find_section_struct(buf, *fsize, "__plain");
    if (pl) hr_plant(buf + pl->offset, HR_PLAIN_VA, at + 2, 0x05, 0, target);
    return buf;
}

/* A grow moves the header's bytes away from its first content, so code that
 * names one of them names nothing after it. */
static void test_grow_refuses_code_that_names_the_inside_of_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_inside_ref(HR_BASE + 1, 0, MG_T_FUNCSTARTS, &fsize);
    check_grow_refuses_header_refs("code naming base + 1", buf, fsize,
        "ERROR: the code at 0x100001803 names 0x100000001, between the header at 0x100000000 and "
        "its first content at 0x100001000, which a grow moves apart; refusing to grow");
    buf = build_inside_ref(HR_BASE + 0xfff, 0, MG_T_FUNCSTARTS, &fsize);
    check_grow_refuses_header_refs("code naming base + F - 1", buf, fsize,
        "ERROR: the code at 0x100001803 names 0x100000fff, between the header");
}

static void test_grow_leaves_code_that_names_the_first_content(void) {
    size_t fsize;
    uint8_t *buf = build_inside_ref(HR_BASE + 0x1000, 0, MG_T_FUNCSTARTS, &fsize);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && refs_to(buf, fsize, HR_BASE + 0x1000) == 1,
          "inside: code naming the first content grows, and still names it (got %d)", r);
    free(buf);
}

/* Bytes in the header's range that decoding does not confirm as code: a
 * lookalike it refutes grows; a lea it cannot reach past an EVEX prefix,
 * and one with no LC_FUNCTION_STARTS to decode from, refuse. */
static void test_grow_decides_what_decoding_does_not_confirm_inside_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_inside_ref(HR_BASE + 16, 0, MG_T_FUNCSTARTS, &fsize);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) buf[pl->offset + 1] = 0xb8;                     /* mov $imm32, %eax */
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "inside: a lookalike decoding refutes grows (got %d)", r);
    free(buf);

    buf = build_inside_ref(HR_BASE + 16, 4, MG_T_FUNCSTARTS, &fsize);
    pl = find_section_struct(buf, fsize, "__plain");
    if (pl) buf[pl->offset] = 0x62;                         /* EVEX: not decoded */
    check_grow_refuses_header_refs("a lea decoding cannot reach", buf, fsize,
        "ERROR: the code at 0x100001807 names 0x100000010, between the header at 0x100000000 and "
        "its first content at 0x100001000, which a grow moves apart; refusing to grow");

    buf = build_inside_ref(HR_BASE + 16, 0, 0, &fsize);
    check_grow_refuses_header_refs("a lea with no function starts to decode from", buf, fsize,
        "ERROR: the code at 0x100001803 names 0x100000010, between the header");
}

```

In `tests/grow_test.c`, immediately after (`:4248`):

```c
    test_confirm_each_reports_an_image_it_cannot_scan();
```

insert:

```c
    test_grow_refuses_code_that_names_the_inside_of_the_header();
    test_grow_leaves_code_that_names_the_first_content();
    test_grow_decides_what_decoding_does_not_confirm_inside_the_header();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: exit 1, and exactly these 12 `FAIL:` lines (the grow does not refuse yet), three for each of the four images it must refuse:

```
FAIL: code naming base + 1: mg_grow_header refuses (got 0)
FAIL: code naming base + 1: the refusal says 'ERROR: the code at 0x100001803 names 0x100000001, between the header at 0x100000000 and its first content at 0x100001000, which a grow moves apart; refusing to grow'
FAIL: code naming base + 1: nothing changed
FAIL: code naming base + F - 1: mg_grow_header refuses (got 0)
FAIL: code naming base + F - 1: the refusal says 'ERROR: the code at 0x100001803 names 0x100000fff, between the header'
FAIL: code naming base + F - 1: nothing changed
FAIL: a lea decoding cannot reach: mg_grow_header refuses (got 0)
FAIL: a lea decoding cannot reach: the refusal says 'ERROR: the code at 0x100001807 names 0x100000010, between the header at 0x100000000 and its first content at 0x100001000, which a grow moves apart; refusing to grow'
FAIL: a lea decoding cannot reach: nothing changed
FAIL: a lea with no function starts to decode from: mg_grow_header refuses (got 0)
FAIL: a lea with no function starts to decode from: the refusal says 'ERROR: the code at 0x100001803 names 0x100000010, between the header'
FAIL: a lea with no function starts to decode from: nothing changed
```

(`test_grow_leaves_code_that_names_the_first_content`, and the refuted lookalike's check, pass already.)

- [ ] **Step 3: Refuse code inside the header that decoding does not refute**

In `src/grow.c`, immediately before (`:1420`):

```c
/* The symbols that name the header: each N_SECT symbol, not a stab, whose
```

insert:

```c
/* mg_inside_refs_ok's verdict callback: the first candidate decoding
 * confirms. */
struct mg_inside_ctx { int hit; mhr_cand c; };
static int mg_inside_cb(const mhr_cand *c, int verdict, void *ctx_) {
    struct mg_inside_ctx *x = (struct mg_inside_ctx *)ctx_;
    if (verdict == MHR_REFUTED) return 0;
    x->hit = 1;
    x->c = *c;
    return 1;
}

/* 0 unless code names a byte strictly between the header at `base` and its
 * first content at base + `first`, which a grow moves apart; then -1,
 * having said so. */
static int mg_inside_refs_ok(const uint8_t *buf, size_t fsize, uint64_t base, uint32_t first) {
    struct mg_inside_ctx x = { 0, { 0, 0, 0, 0 } };
    int r = mhr_confirm_each(buf, fsize, base + 1, base + first - 1, mg_inside_cb, &x);
    if (r == MHR_CONFIRMED && !x.hit) return 0;
    if (x.hit)
        fprintf(stderr, "ERROR: the code at %#llx names %#llx, between the header at %#llx and "
                        "its first content at %#llx, which a grow moves apart; refusing to grow\n",
                (unsigned long long)x.c.addr, (unsigned long long)x.c.target,
                (unsigned long long)base, (unsigned long long)(base + first));
    else
        fprintf(stderr, "ERROR: could not search the image for code that names the inside of "
                        "its header; refusing to grow\n");
    return -1;
}

```

In `src/grow.c`, immediately after (`:1654`):

```c
    if (mg_header_refs_ok(buf, fsize, grow) != 0) return -1;
```

insert:

```c
    if (mg_inside_refs_ok(buf, fsize, mg_base_of(buf, fsize), insert) != 0) return -1;
```

In `src/grow.h`, replace (`:409`):

```c
 * mg_header_pointers refuses. Every confirmed reference is repaired: its
```

with:

```c
 * mg_header_pointers refuses.
 * So is one with bytes in an instruction section that name a byte strictly
 * between the header and its first content, which a grow moves apart,
 * unless decoding refutes that they are code (mhr_confirm_each).
 * Every confirmed reference is repaired: its
```

- [ ] **Step 4: Record the ruling in QUEUE item 29**

In `docs/superpowers/QUEUE.md`, replace (`:1511`):

```markdown
host's executables). Its **code half is not**: a
`movl __mh_execute_header+16(%rip)` still grows silently wrong. Measured
2026-09-26 while planning the data half, a scan for RIP-relative targets
strictly inside (base, base + F) finds 1,060 candidates in 120 of this
host's 1,059 x86_64 executables, and 29 in Claude Code, and decoding
confirms none as an instruction. The same decoding confirms 151 of the 152
exact-base candidates. Refusing every candidate it cannot confirm would stop
119 of those executables growing, and Claude Code; refusing only confirmed
ones changes nothing measured. It is deferred to dylib-growth M2, which
```

with:

```markdown
host's executables). Its **code half is done**, in dylib-growth M2a: bytes
in an instruction section that name a byte strictly inside (base, base + F),
such as `movl __mh_execute_header+16(%rip)`, refuse the grow unless decoding
refutes that they are code: the owner.s ruling, 2026-09-26. Measured
then, a scan for RIP-relative targets strictly inside (base, base + F) finds
1,060 candidates in 120 of this host's 1,059 x86_64 executables, and 29 in
Claude Code. Decoding confirms none. It refutes 1,057, among them the other
immediate lengths of every exact-base reference, and all 29 of Claude
Code's. It cannot reach 3, all in `thnucups`, which has no
`LC_FUNCTION_STARTS` and is refused already. So nothing measured changes.
It is deferred to dylib-growth M2, which
```

- [ ] **Step 5: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green.

- [ ] **Step 6: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (verdict == MHR_REFUTED) return 0;`<br>`    x->hit = 1;` | `    if (verdict != MHR_CONFIRMED) return 0;`<br>`    x->hit = 1;` | `FAIL: a lea decoding cannot reach: mg_grow_header refuses (got 0)` |
| 2 | `    if (verdict == MHR_REFUTED) return 0;`<br>`    x->hit = 1;` | `    if (verdict == MHR_REFUTED \|\| verdict == MHR_NO_STARTS) return 0;`<br>`    x->hit = 1;` | `FAIL: a lea with no function starts to decode from: mg_grow_header refuses (got 0)` |
| 3 | `    if (verdict == MHR_REFUTED) return 0;`<br>`    x->hit = 1;` | `    x->hit = 1;` | `FAIL: inside: a lookalike decoding refutes grows` |
| 4 | `    if (verdict == MHR_REFUTED) return 0;`<br>`    x->hit = 1;` | `    return 0;`<br>`    x->hit = 1;` | `FAIL: code naming base + 1: mg_grow_header refuses` |
| 5 | `    x->c = *c;`<br>`    return 1;` | `    return 1;` | `FAIL: code naming base + 1: the refusal says` |
| 6 | `    int r = mhr_confirm_each(buf, fsize, base + 1, base + first - 1, mg_inside_cb, &x);` | `    int r = mhr_confirm_each(buf, fsize, base + 2, base + first - 1, mg_inside_cb, &x);` | `FAIL: code naming base + 1: mg_grow_header refuses` |
| 7 | `    int r = mhr_confirm_each(buf, fsize, base + 1, base + first - 1, mg_inside_cb, &x);` | `    int r = mhr_confirm_each(buf, fsize, base, base + first - 1, mg_inside_cb, &x);` | `FAIL: repair: a grow with two confirmed references succeeds` |
| 8 | `    int r = mhr_confirm_each(buf, fsize, base + 1, base + first - 1, mg_inside_cb, &x);` | `    int r = mhr_confirm_each(buf, fsize, base + 1, base + first - 2, mg_inside_cb, &x);` | `FAIL: code naming base + F - 1: mg_grow_header refuses` |
| 9 | `    int r = mhr_confirm_each(buf, fsize, base + 1, base + first - 1, mg_inside_cb, &x);` | `    int r = mhr_confirm_each(buf, fsize, base + 1, base + first, mg_inside_cb, &x);` | `FAIL: inside: code naming the first content grows` |
| 10 | `    if (mg_inside_refs_ok(buf, fsize, mg_base_of(buf, fsize), insert) != 0) return -1;` | `    mg_inside_refs_ok(buf, fsize, mg_base_of(buf, fsize), insert);` | `FAIL: code naming base + 1: mg_grow_header refuses` |

Row 1 is the alternative that lost (Ruling 1): passing everything decoding does not confirm. A mutation of `if (r == MHR_CONFIRMED && !x.hit) return 0;` to `if (!x.hit) return 0;` survives: it differs only when memory runs out (see the plan decisions).

- [ ] **Step 7: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c docs/superpowers/QUEUE.md
git commit -m "fix(grow): refuse code that names the inside of the header

The one rule's code half. A grow moves the header's bytes apart from its
first content, so an instruction that names one of them names nothing
after the grow. Every RIP-relative candidate in (base, base + F) that
decoding confirms, or cannot reach, now refuses the grow; one that
decoding refutes passes: the owner's ruling. Measured, no image among
this host's executables and system dylibs, its applications, or Claude
Code is refused by it that M1 did not refuse already.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 3: Refuse a symbol or an export that names the inside of the header

**Files** (each edit block below gives its line):
- Modify: `src/grow.h` (`#define MG_K_FUNC 1`; `mg_grow_header`'s contract)
- Modify: `src/grow.c` (`mg_trie_node`'s collected kind; new `mg_exports_ok` and `mg_sym_name`, and the symbol half, at `mg_hsym_cb` and `mg_header_symbols`; `mg_grow_header`'s audit and patch calls)
- Test: `tests/grow_test.c` (new tests before `int main(void) {`; calls before `if (fails)`)

**Interfaces:**
- Consumes: `mg_trie_walk`, `MG_SNAP_MAX`, `MG_EXPORT_KIND_*`; M1's `mg_hsym_cb`; in the tests, `build_symbol_image`, `hsym`, `MG_T_TRIE`, `TRIE_OFF`, `MG_TRIE_A_FLAGS`, `MG_TRIE_A_ADDR`, `check_grow_refuses_header_refs`.
- Produces: `#define MG_K_ABS 2` (an absolute export's collected kind; M2b's verification reads it); `static int mg_exports_ok(uint8_t *buf, size_t fsize, uint64_t base, uint32_t first);`; `static int mg_sym_name(const uint8_t *buf, size_t fsize, const struct symtab_command *st, const struct nlist_64 *nl, const char **name);` (M2b moves it and reuses it); `mg_header_symbols(buf, fsize, base, first, grow, patch)` gains `first`.

**Plan decisions.**

- **Symbols:** `N_SECT` and not a stab, the set M1's repair already moves. A stab and an `N_ABS` symbol hold no address a lowering moves, whatever their value; M2b decides stabs for the raise.
- **Exports:** every entry the trie walk collects that is not `EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE`: its collected value is base + offset, and offset < F refuses (offset 0, the header, is never collected). An absolute entry's value is not an offset, so `mg_trie_node` now marks it `MG_K_ABS` (it was `MG_K_ANY`); `mg_plausible` only reads `MG_K_FUNC`, so nothing else sees the change.
- **The audit** runs after the trie audit, so a malformed trie keeps its message; the collection can fail only past `MG_SNAP_MAX` entries or out of memory, which the snapshot refuses too, and that branch is not in the mutation table.
- **Names.** A symbol refusal names the symbol, read only from within its string table and the image (`mg_sym_name`).

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately before (`:4114`):

```c
int main(void) {
```

insert:

```c
/* ---- the one rule's symbol and export halves ---- */
/* MG_T_SYMTAB's string table is the 8 bytes at 6720, or at `stroff`; the
 * byte after it is not part of it. */
static void check_grow_refuses_symbol(uint64_t value, uint32_t strx, uint32_t stroff,
                                      const char *needle) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    memcpy(buf + 6720, "\0_in\0\0xyz", 9);
    buf[fsize - 3] = 'q';
    ((struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB))->stroff = stroff;
    hsym(buf, fsize, 1)->n_value = value;
    hsym(buf, fsize, 1)->n_un.n_strx = strx;
    check_grow_refuses_header_refs("a symbol inside the header", buf, fsize, needle);
}

static void test_grow_refuses_a_symbol_inside_the_header(void) {
    check_grow_refuses_symbol(HR_BASE + 1, 1, 6720,
        "ERROR: symbol 1, \"_in\", names 0x100000001, between the header at 0x100000000 and its "
        "first content at 0x100001000, which a grow moves apart; refusing to grow");
    check_grow_refuses_symbol(HR_BASE + 0xfff, 1, 6720, "ERROR: symbol 1, \"_in\", names 0x100000fff");
    check_grow_refuses_symbol(HR_BASE + 16, 8, 6720, "ERROR: symbol 1, \"\", names 0x100000010");
    check_grow_refuses_symbol(HR_BASE + 16, 6, 6720, "ERROR: symbol 1, \"xy\", names 0x100000010");
    check_grow_refuses_symbol(HR_BASE + 16, 1, 8192 - 4, "ERROR: symbol 1, \"\", names 0x100000010");
}

/* A stab or an absolute symbol there is not an address a grow moves, and
 * one at the first content names content. */
static void test_grow_leaves_other_symbols_that_name_the_inside_of_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    hsym(buf, fsize, 1)->n_value = HR_BASE + 0x1000;
    hsym(buf, fsize, 2)->n_value = HR_BASE + 16;       /* N_BNSYM */
    hsym(buf, fsize, 3)->n_value = HR_BASE + 16;       /* N_ABS */
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && hsym(buf, fsize, 1)->n_value == HR_BASE + 0x1000 &&
          hsym(buf, fsize, 2)->n_value == HR_BASE + 16 && hsym(buf, fsize, 3)->n_value == HR_BASE + 16,
          "symbols: a stab and an absolute symbol inside the header, and one at its first "
          "content, grow unchanged (got %d)", r);
    free(buf);
}

/* MG_T_TRIE's node A, its address `a` in its two bytes, and `flags`. */
static uint8_t *build_export_at(uint64_t a, uint8_t flags, size_t *fsize) {
    uint32_t sect_off;
    uint8_t *buf = build_image(fsize, &sect_off, MG_T_TRIE);
    buf[TRIE_OFF + MG_TRIE_A_FLAGS] = flags;
    mu_encode_fixed(buf + TRIE_OFF + MG_TRIE_A_ADDR, a, 2);
    return buf;
}

static void test_grow_refuses_an_export_inside_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_export_at(1, 0, &fsize);
    check_grow_refuses_header_refs("an export at offset 1", buf, fsize,
        "ERROR: an export names 0x100000001, between the header at 0x100000000 and its first "
        "content at 0x100001000, which a grow moves apart; refusing to grow");
    buf = build_export_at(0xfff, 0, &fsize);
    check_grow_refuses_header_refs("an export at offset F - 1", buf, fsize,
        "ERROR: an export names 0x100000fff, between the header");
}

/* MG_T_TRIE's trie, with node A absolute and valued base + 16: a value, so
 * the grow leaves it alone. */
static void test_grow_leaves_an_absolute_export_inside_the_header(void) {
    static const uint8_t trie[20] = {
        0x00, 0x02, 'A', 0x00, 8, 'B', 0x00, 16,
        0x06, 0x02, 0x90, 0x80, 0x80, 0x80, 0x10, 0x00,     /* A: absolute, 0x100000010 */
        0x02, 0x00, 0x00, 0x00                              /* B: 0 */
    };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_TRIE);
    memcpy(buf + TRIE_OFF, trie, sizeof trie);
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->export_size = sizeof trie;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "an absolute export valued base + 16 grows (got %d)", r);
    free(buf);
}

```

In `tests/grow_test.c`, immediately after (`:4329`):

```c
    test_grow_decides_what_decoding_does_not_confirm_inside_the_header();
```

insert:

```c
    test_grow_refuses_a_symbol_inside_the_header();
    test_grow_leaves_other_symbols_that_name_the_inside_of_the_header();
    test_grow_refuses_an_export_inside_the_header();
    test_grow_leaves_an_absolute_export_inside_the_header();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: exit 1, and 21 `FAIL:` lines: three for each of the five symbols ("mg_grow_header refuses (got 0)", "the refusal says …", "nothing changed") and three for each of the two exports. The first is `FAIL: a symbol inside the header: mg_grow_header refuses (got 0)`. `test_grow_leaves_other_symbols_that_name_the_inside_of_the_header` and `test_grow_leaves_an_absolute_export_inside_the_header` pass already.

- [ ] **Step 3: Mark an absolute export, and refuse what names the inside**

In `src/grow.h`, immediately after (`:183`):

```c
#define MG_K_FUNC 1
```

insert:

```c
#define MG_K_ABS  2   /* an absolute export: its value, not an offset from the base */
```

In `src/grow.h`, immediately after (`:410`):

```c
 * mg_header_pointers refuses.
```

insert:

```c
 * So is one with an N_SECT symbol, not a stab, or an export, not an
 * absolute one, that names a byte strictly between the header and its first
 * content.
```

In `src/grow.c`, replace (`:963`):

```c
                        if (kinds) kinds[*n] = MG_K_ANY;  /* data exports are not functions */
```

with:

```c
                        if (kinds) kinds[*n] = absolute ? MG_K_ABS : MG_K_ANY;
```

In `src/grow.c`, replace (`:1449`):

```c
/* The symbols that name the header: each N_SECT symbol, not a stab, whose
 * value is `base`. With `patch`, each loses `grow`, following the header
 * down; without, this checks that the symbol table lies within the image,
 * and says so on stderr when it does not. Returns 0, or -1. */
struct mg_hsym_ctx { uint8_t *buf; size_t fsize; uint64_t base; uint32_t grow; int patch, bad, n; };
```

with:

```c
/* 0 unless an export, other than an absolute one, names a byte strictly
 * between the header at `base` and its first content at base + `first`;
 * then -1, having said so. */
static int mg_exports_ok(uint8_t *buf, size_t fsize, uint64_t base, uint32_t first) {
    uint64_t *a = (uint64_t *)malloc(MG_SNAP_MAX * sizeof *a);
    uint8_t *k = (uint8_t *)malloc(MG_SNAP_MAX);
    uint32_t n = 0;
    int rc = -1;
    if (!a || !k || mg_trie_walk(buf, fsize, 0, 0, base, a, k, &n, MG_SNAP_MAX) != 0) {
        fprintf(stderr, "ERROR: could not read the export trie's addresses; refusing to grow\n");
        n = 0;
    } else {
        rc = 0;
    }
    for (uint32_t i = 0; i < n; i++) {
        if (k[i] == MG_K_ABS || a[i] - base >= first) continue;
        fprintf(stderr, "ERROR: an export names %#llx, between the header at %#llx and its first "
                        "content at %#llx, which a grow moves apart; refusing to grow\n",
                (unsigned long long)a[i], (unsigned long long)base,
                (unsigned long long)(base + first));
        rc = -1;
        break;
    }
    free(a);
    free(k);
    return rc;
}

/* The name of symbol `nl` in LC_SYMTAB `st`'s string table, as a length and
 * a pointer; empty when it lies outside the table or the image. */
static int mg_sym_name(const uint8_t *buf, size_t fsize, const struct symtab_command *st,
                       const struct nlist_64 *nl, const char **name) {
    *name = "";
    if (st->strsize > fsize || st->stroff > fsize - st->strsize || nl->n_un.n_strx >= st->strsize)
        return 0;
    *name = (const char *)buf + st->stroff + nl->n_un.n_strx;
    const char *nul = (const char *)memchr(*name, 0, st->strsize - nl->n_un.n_strx);
    return nul ? (int)(nul - *name) : (int)(st->strsize - nl->n_un.n_strx);
}

/* The symbols that name the header: each N_SECT symbol, not a stab, whose
 * value is `base`. With `patch`, each loses `grow`, following the header
 * down; without, this checks that the symbol table lies within the image,
 * and says so on stderr when it does not. Either way, one that names a byte
 * strictly between the header and its first content, at base + `first`,
 * is refused, saying so. Returns 0, or -1. */
struct mg_hsym_ctx {
    uint8_t *buf;
    size_t fsize;
    uint64_t base, first;
    uint32_t grow;
    int patch, bad, n;
};
```

In `src/grow.c`, replace (`:1520`):

```c
    for (uint32_t i = 0; c->patch && i < st->nsyms; i++)
        if (!(nl[i].n_type & N_STAB) && (nl[i].n_type & N_TYPE) == N_SECT &&
            nl[i].n_value == c->base)
            nl[i].n_value -= c->grow;
    return 0;
}

static int mg_header_symbols(uint8_t *buf, size_t fsize, uint64_t base, uint32_t grow,
                             int patch) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) != 0) return -1;
    struct mg_hsym_ctx c = { buf, fsize, base, grow, patch, 0, 0 };
```

with:

```c
    for (uint32_t i = 0; i < st->nsyms; i++) {
        if ((nl[i].n_type & N_STAB) || (nl[i].n_type & N_TYPE) != N_SECT) continue;
        uint64_t v = nl[i].n_value;
        if (v > c->base && v - c->base < c->first) {
            const char *name;
            int len = mg_sym_name(c->buf, c->fsize, st, &nl[i], &name);
            fprintf(stderr, "ERROR: symbol %u, \"%.*s\", names %#llx, between the header at %#llx "
                            "and its first content at %#llx, which a grow moves apart; refusing "
                            "to grow\n", i, len, name, (unsigned long long)v,
                    (unsigned long long)c->base, (unsigned long long)(c->base + c->first));
            c->bad = 1;
            return 1;
        }
        if (c->patch && v == c->base) nl[i].n_value -= c->grow;
    }
    return 0;
}

static int mg_header_symbols(uint8_t *buf, size_t fsize, uint64_t base, uint64_t first,
                             uint32_t grow, int patch) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) != 0) return -1;
    struct mg_hsym_ctx c = { buf, fsize, base, first, grow, patch, 0, 0 };
```

In `src/grow.c`, replace (`:1715`):

```c
    if (mg_header_symbols(buf, fsize, 0, grow, 0) != 0) return -1;
```

with:

```c
    if (mg_header_symbols(buf, fsize, mg_base_of(buf, fsize), insert, grow, 0) != 0) return -1;
```

In `src/grow.c`, replace (`:1758`):

```c
            mg_trie_needs_rebuild = 1;
        }
    }

```

with:

```c
            mg_trie_needs_rebuild = 1;
        }
    }
    if (mg_exports_ok(buf, fsize, mg_base_of(buf, fsize), insert) != 0) {
        free(mg_new_trie);
        return -1;
    }

```

In `src/grow.c`, replace (`:1996`):

```c
    if (mg_header_symbols(buf, final_size, snap.base, grow, 1) != 0) {
```

with:

```c
    if (mg_header_symbols(buf, final_size, snap.base, insert, grow, 1) != 0) {
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `        if (k[i] == MG_K_ABS \|\| a[i] - base >= first) continue;` | `        if (a[i] - base >= first) continue;` | `FAIL: an absolute export valued base + 16 grows` |
| 2 | `        if (k[i] == MG_K_ABS \|\| a[i] - base >= first) continue;` | `        if (k[i] == MG_K_ABS \|\| a[i] - base > first) continue;` | `FAIL: grow succeeds on an image with an export trie (got -1)` |
| 3 | `        if (k[i] == MG_K_ABS \|\| a[i] - base >= first) continue;` | `        if (k[i] == MG_K_ABS \|\| a[i] - base >= first - 1) continue;` | `FAIL: an export at offset F - 1: mg_grow_header refuses` |
| 4 | `                        if (kinds) kinds[*n] = absolute ? MG_K_ABS : MG_K_ANY;` | `                        if (kinds) kinds[*n] = MG_K_ANY;` | `FAIL: an absolute export valued base + 16 grows` |
| 5 | `    if (mg_exports_ok(buf, fsize, mg_base_of(buf, fsize), insert) != 0) {` | `    if (0) {` | `FAIL: an export at offset 1: mg_grow_header refuses` |
| 6 | `        if (v > c->base && v - c->base < c->first) {` | `        if (v - c->base < c->first) {` | `FAIL: symbols: the grow succeeds` |
| 7 | `        if (v > c->base && v - c->base < c->first) {` | `        if (v > c->base + 1 && v - c->base < c->first) {` | `FAIL: a symbol inside the header: mg_grow_header refuses` |
| 8 | `        if (v > c->base && v - c->base < c->first) {` | `        if (v > c->base && v - c->base <= c->first) {` | `FAIL: symbols: a stab and an absolute symbol inside the header, and one at its first content, grow unchanged` |
| 9 | `        if ((nl[i].n_type & N_STAB) \|\| (nl[i].n_type & N_TYPE) != N_SECT) continue;` | `        if ((nl[i].n_type & N_TYPE) != N_SECT) continue;` | `FAIL: symbols: a stab and an absolute symbol inside the header` |
| 10 | `        if ((nl[i].n_type & N_STAB) \|\| (nl[i].n_type & N_TYPE) != N_SECT) continue;` | `        if (nl[i].n_type & N_STAB) continue;` | `FAIL: symbols: a stab and an absolute symbol inside the header` |
| 11 | `        if (c->patch && v == c->base) nl[i].n_value -= c->grow;` | `        if (v == c->base) nl[i].n_value -= c->grow;` | `FAIL: symbols: two tables: nothing changed` |
| 12 | `    if (st->strsize > fsize \|\| st->stroff > fsize - st->strsize \|\| nl->n_un.n_strx >= st->strsize)` | `    if (st->strsize > fsize \|\| nl->n_un.n_strx >= st->strsize)` | `FAIL: a symbol inside the header: the refusal says 'ERROR: symbol 1, "", names 0x100000010'` |
| 13 | `    return nul ? (int)(nul - *name) : (int)(st->strsize - nl->n_un.n_strx);` | `    return nul ? (int)(nul - *name) : (int)strlen(*name);` | `FAIL: a symbol inside the header: the refusal says 'ERROR: symbol 1, "xy"` |
| 14 | `    if (mg_header_symbols(buf, fsize, mg_base_of(buf, fsize), insert, grow, 0) != 0) return -1;` | `    if (mg_header_symbols(buf, fsize, 0, insert, grow, 0) != 0) return -1;` | `FAIL: a symbol inside the header: nothing changed` |

- [ ] **Step 6: Commit**

```bash
git add src/grow.h src/grow.c tests/grow_test.c
git commit -m "fix(grow): refuse a symbol or export that names the inside of the header

The one rule's symbol and export halves. An N_SECT symbol, not a stab, or
an export that is not absolute, naming a byte strictly between the header
and its first content, refuses the grow before it changes anything; the
symbol's refusal names it. None occurs among this host's executables.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 4: Refuse a bind in the segment that maps the header

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (`#include "hdrref.h"`; new `mg_bind_obs` and `mg_binds_ok` before `/* mg_snapshot_take's mhr_scan callback: keep each reference to the header. */`; the pointer audit in `mg_grow_header`)
- Modify: `src/grow.h` (`mg_grow_header`'s contract)
- Test: `tests/grow_test.c` (new tests before `int main(void) {`; calls before `if (fails)`)

**Interfaces:**
- Consumes: `mo_bind_observe`, `mo_bind_state`, `mo_fits` (`src/ordinals.h`); `struct mg_rb_lcs` and `mg_rb_lcs_cb` (the data half's command reader in `src/grow.c`); in the tests, `build_pointer_image`, `PT_LE`, `find_lc`, `check_grow_refuses_header_refs`.
- Produces: `static int mg_binds_ok(const uint8_t *buf, size_t fsize, char *why, size_t whysz);` — M2b's raise route runs it from the same call site. In the tests: `build_bind_image(int which, uint8_t seg, size_t *fsize)`.

**Plan decisions.**

- **Which binds.** Every DO_BIND-family opcode of `LC_DYLD_INFO[_ONLY]`'s bind, weak-bind and lazy-bind streams. The segment that maps the header is the one with file offset 0 and file data, as `mg_rebases_read` has it for a rebase: `__PAGEZERO` is not it.
- **What else refuses.** A stream past the image, a stream `mo_bind_observe` cannot decode, and a segment index past the image's segments: without them the check could not say a bind is not in the header's segment.
- **A short `LC_DYLD_INFO`.** `mg_binds_ok` reads the command through `mg_rb_lcs_cb` and refuses a short one, as `mg_rebases_read` does; `mg_header_pointers` runs first and refuses it already, so that branch is not in the mutation table.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately before (`:4192`):

```c
int main(void) {
```

insert:

```c
/* ---- a bind in the segment that maps the header ----
 * build_pointer_image with one bind (0), weak bind (1) or lazy bind (2) at
 * PT_LE + 16 * (1 + which): ordinal 1, "_s", a pointer, in segment `seg` at
 * offset 0x10. */
static uint8_t *build_bind_image(int which, uint8_t seg, size_t *fsize) {
    uint8_t *buf = build_pointer_image(fsize, 0);
    const uint8_t ops[10] = { 0x11, 0x40, '_', 's', 0, 0x51, (uint8_t)(0x70 | seg), 0x10, 0x90,
                              0x00 };
    struct dyld_info_command *di = (struct dyld_info_command *)find_lc(buf, *fsize, LC_DYLD_INFO_ONLY);
    uint32_t at = PT_LE + 16 * (1 + which);
    memcpy(buf + at, ops, sizeof ops);
    if (which == 0) { di->bind_off = at; di->bind_size = sizeof ops; }
    if (which == 1) { di->weak_bind_off = at; di->weak_bind_size = sizeof ops; }
    if (which == 2) { di->lazy_bind_off = at; di->lazy_bind_size = sizeof ops; }
    return buf;
}

static void test_grow_refuses_a_bind_in_the_segment_that_maps_the_header(void) {
    static const char *const kind[3] = { "bind", "weak bind", "lazy bind" };
    for (int i = 0; i < 3; i++) {
        size_t fsize;
        char what[64], needle[160];
        uint8_t *buf = build_bind_image(i, 1, &fsize);
        snprintf(what, sizeof what, "a %s in __TEXT", kind[i]);
        snprintf(needle, sizeof needle, "ERROR: the %s at __TEXT+0x10 lies in the segment that maps "
                 "the header; refusing to grow", kind[i]);
        check_grow_refuses_header_refs(what, buf, fsize, needle);
    }
}

static void test_grow_refuses_binds_it_cannot_read(void) {
    size_t fsize;
    uint8_t *buf = build_bind_image(2, 4, &fsize);
    check_grow_refuses_header_refs("a lazy bind in segment 4", buf, fsize,
        "ERROR: the lazy bind opcodes name segment 4, and there are 4; refusing to grow");
    buf = build_bind_image(0, 1, &fsize);
    buf[PT_LE + 16 + 9] = 0x7f;                        /* then segment 15, offset 0; DO_BIND */
    buf[PT_LE + 16 + 10] = 0x00;
    buf[PT_LE + 16 + 11] = 0x90;
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->bind_size = 13;
    check_grow_refuses_header_refs("the first of two binds it cannot move", buf, fsize,
        "ERROR: the bind at __TEXT+0x10 lies in the segment that maps the header; refusing to grow");
    buf = build_bind_image(1, 2, &fsize);
    buf[PT_LE + 32 + 8] = 0xe0;                        /* no such opcode */
    check_grow_refuses_header_refs("weak bind opcodes that do not decode", buf, fsize,
        "ERROR: the weak bind opcodes do not decode; refusing to grow");
    buf = build_bind_image(0, 2, &fsize);
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->bind_size = 1000;
    check_grow_refuses_header_refs("bind opcodes past the image", buf, fsize,
        "ERROR: the bind opcodes (1000 bytes at offset 12304) run past the end of the 12544-byte "
        "image; refusing to grow");
}

/* __DATA, and __PAGEZERO, which starts at file offset 0 but maps none of
 * the file, are not the segment that maps the header. */
static void test_grow_accepts_binds_outside_the_header_segment(void) {
    for (int i = 0; i < 3; i++) {
        size_t fsize;
        uint8_t *buf = build_bind_image(i, 2, &fsize);
        int r = mg_grow_header(&buf, &fsize, 0x1000);
        CHECK(r == 0, "binds: stream %d's bind in __DATA grows (got %d)", i, r);
        free(buf);
    }
    size_t fsize;
    uint8_t *buf = build_bind_image(0, 0, &fsize);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "binds: a bind in __PAGEZERO is not in the header's segment (got %d)", r);
    free(buf);
}

```

In `tests/grow_test.c`, immediately after (`:4403`):

```c
    test_grow_leaves_an_absolute_export_inside_the_header();
```

insert:

```c
    test_grow_refuses_a_bind_in_the_segment_that_maps_the_header();
    test_grow_refuses_binds_it_cannot_read();
    test_grow_accepts_binds_outside_the_header_segment();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: exit 1, and 21 `FAIL:` lines, three for each of the seven refusals, beginning:

```
FAIL: a bind in __TEXT: mg_grow_header refuses (got 0)
FAIL: a bind in __TEXT: the refusal says 'ERROR: the bind at __TEXT+0x10 lies in the segment that maps the header; refusing to grow'
FAIL: a bind in __TEXT: nothing changed
```

`test_grow_accepts_binds_outside_the_header_segment` passes already.

- [ ] **Step 3: Read the binds, and refuse one in the header's segment**

In `src/grow.c`, immediately after (`:7`):

```c
#include "hdrref.h"
```

insert:

```c
#include "ordinals.h"
```

In `src/grow.c`, immediately after (`:524`):

```c
    mg_rebases_free(&rb);
    return n;
}

```

insert:

```c
/* mg_binds_ok's observer: the first bind that names no segment of the image,
 * or lies in the segment that maps the header. */
struct mg_bind_ctx { const struct mg_rb_lcs *l; const char *kind; char *why; size_t whysz; int bad; };
static void mg_bind_obs(const mo_bind_state *st, void *ctx_) {
    struct mg_bind_ctx *c = (struct mg_bind_ctx *)ctx_;
    if (c->bad) return;
    if (st->seg >= c->l->nsegs) {
        snprintf(c->why, c->whysz, "the %s opcodes name segment %d, and there are %d", c->kind,
                 st->seg, c->l->nsegs);
        c->bad = 1;
        return;
    }
    const struct segment_command_64 *seg = c->l->seg[st->seg];
    if (seg->fileoff != 0 || seg->filesize == 0) return;
    snprintf(c->why, c->whysz, "the %s at %.16s+%#llx lies in the segment that maps the header",
             c->kind, seg->segname, (unsigned long long)st->offset);
    c->bad = 1;
}

/* 0, or -1 with `why` set when a bind, weak bind or lazy bind lies in the
 * segment that maps the header, whose contents a grow moves out from under
 * it, or when those opcodes cannot be read. */
static int mg_binds_ok(const uint8_t *buf, size_t fsize, char *why, size_t whysz) {
    mi_image im;
    struct mg_rb_lcs c;
    memset(&c, 0, sizeof c);
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0) {
        snprintf(why, whysz, "the image does not validate");
        return -1;
    }
    mi_each_lc(&im, mg_rb_lcs_cb, &c);
    if (c.short_lc) {
        snprintf(why, whysz, "the image's %s command is %u bytes, too short to hold %s", c.short_lc,
                 c.short_size, c.short_of);
        return -1;
    }
    if (!c.di) return 0;
    const struct { const char *kind; uint32_t off, size; } s[3] = {
        { "bind", c.di->bind_off, c.di->bind_size },
        { "weak bind", c.di->weak_bind_off, c.di->weak_bind_size },
        { "lazy bind", c.di->lazy_bind_off, c.di->lazy_bind_size },
    };
    for (int i = 0; i < 3; i++) {
        char what[32];
        struct mg_bind_ctx x = { &c, s[i].kind, why, whysz, 0 };
        if (!s[i].size) continue;
        if (!mo_fits(s[i].off, s[i].size, fsize)) {
            snprintf(why, whysz, "the %s opcodes (%u bytes at offset %u) run past the end of the "
                     "%zu-byte image", s[i].kind, s[i].size, s[i].off, fsize);
            return -1;
        }
        snprintf(what, sizeof what, "the %s opcodes", s[i].kind);
        if (mo_bind_observe(buf + s[i].off, s[i].size, what, mg_bind_obs, &x) != 0) {
            snprintf(why, whysz, "the %s opcodes do not decode", s[i].kind);
            return -1;
        }
        if (x.bad) return -1;
    }
    return 0;
}

```

In `src/grow.c`, replace (`:1782`):

```c
        if (n < 0) {
```

with:

```c
        if (n < 0 || mg_binds_ok(buf, fsize, why, sizeof why) != 0) {
```

In `src/grow.h`, immediately after (`:410`):

```c
 * mg_header_pointers refuses.
```

insert:

```c
 * So is one with a bind, weak bind or lazy bind in the segment that maps the
 * header, whose contents a grow moves out from under it, or bind opcodes it
 * cannot read.
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (st->seg >= c->l->nsegs) {` | `    if (st->seg > c->l->nsegs) {` | dies of SIGSEGV (exit 139) |
| 2 | `    if (seg->fileoff != 0 \|\| seg->filesize == 0) return;` | `    if (seg->fileoff != 0) return;` | `FAIL: binds: a bind in __PAGEZERO is not in the header's segment` |
| 3 | `    if (seg->fileoff != 0 \|\| seg->filesize == 0) return;` | `    if (seg->filesize == 0) return;` | `FAIL: binds: stream 0's bind in __DATA grows` |
| 4 | `    if (seg->fileoff != 0 \|\| seg->filesize == 0) return;` | `    return;` | `FAIL: a bind in __TEXT: mg_grow_header refuses` |
| 5 | `    if (c->bad) return;`<br>`    if (st->seg >= c->l->nsegs) {` | `    if (st->seg >= c->l->nsegs) {` | `FAIL: the first of two binds it cannot move: the refusal says` |
| 6 | `        { "weak bind", c.di->weak_bind_off, c.di->weak_bind_size },` | `        { "weak bind", 0, 0 },` | `FAIL: a weak bind in __TEXT: mg_grow_header refuses` |
| 7 | `        { "lazy bind", c.di->lazy_bind_off, c.di->lazy_bind_size },` | `        { "lazy bind", 0, 0 },` | `FAIL: a lazy bind in __TEXT: mg_grow_header refuses` |
| 8 | `        { "bind", c.di->bind_off, c.di->bind_size },` | `        { "bind", 0, 0 },` | `FAIL: a bind in __TEXT: mg_grow_header refuses` |
| 9 | `        if (!mo_fits(s[i].off, s[i].size, fsize)) {` | `        if (0) {` | `FAIL: bind opcodes past the image: the refusal says` |
| 10 | `        if (mo_bind_observe(buf + s[i].off, s[i].size, what, mg_bind_obs, &x) != 0) {` | `        if (mo_bind_observe(buf + s[i].off, s[i].size, what, mg_bind_obs, &x) != 0 && 0) {` | `FAIL: weak bind opcodes that do not decode: mg_grow_header refuses` |
| 11 | `        if (x.bad) return -1;`<br>`    }` | `    }` | `FAIL: a bind in __TEXT: mg_grow_header refuses` |
| 12 | `        if (n < 0 \|\| mg_binds_ok(buf, fsize, why, sizeof why) != 0) {` | `        if (n < 0) {` | `FAIL: a bind in __TEXT: mg_grow_header refuses` |

Row 1 is killed by `grow_test` dying of SIGSEGV (exit 139): segment 4 of 4 is read past the table. Row 5's test is "the first of two binds it cannot move": without the early return, the second bind's reason overwrites the first's.

- [ ] **Step 6: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c
git commit -m "fix(grow): refuse a bind in the segment that maps the header

A grow moves that segment's contents out from under a bind's slot, so a
bind, weak bind or lazy bind there refuses the grow before it changes
anything, and so do bind opcodes it cannot read. None occurs among this
host's executables.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 5: The sweep, QUEUE items 29 and 33, and the spec

**Files** (each edit block below gives its line):
- Modify: `docs/superpowers/QUEUE.md` (item 29's row; the bind sentences; the I1 paragraph's last sentence; item 33, new, per Ruling 2)
- Modify: `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md` (M2's first bullet)

**Interfaces:**
- Consumes: Tasks 1–4's commits, and a build of their finished tree in `$B`.
- Produces: nothing code depends on.

- [ ] **Step 1: Find the commits**

```sh
P=$(git log -1 --format=%h --grep='^feat(hdrref): scan a range of targets')^
T1=$(git rev-parse --short "$P^{commit}")
T2=$(git log -1 --format=%h --grep='^fix(grow): refuse code that names the inside of the header')
T4=$(git log -1 --format=%h --grep='^fix(grow): refuse a bind in the segment that maps the header')
F=$(git log -1 --format=%h --grep='^feat(hdrref): scan a range of targets')
echo "before=$T1 first=$F code=$T2 last=$T4"
```

Expected: four short hashes; `$F`..`$T4` is this plan's code.

- [ ] **Step 2: The corpus sweep**

Build the commit before Task 1 in a scratch directory, and grow every file of the corpus with each build, exactly as the data-pointer plan's sweep did: thin to x86_64, delete any code signature, and `rpath append` enough 200-byte paths to outgrow the pad. Record each exit status, output hash and stderr:

```sh
W=$(mktemp -d -t m2a-sweep)
git archive "$P" | (mkdir "$W/src" && tar -x -C "$W/src")
/usr/local/mavergreen/bin/shipyard-cmake -S "$W/src" -B "$W/build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/MavericksToolchain.cmake \
  -DMAVERICKS_EXPECTED_MODE=native -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64 >/dev/null
/usr/local/mavergreen/bin/shipyard-cmake --build "$W/build" -j >/dev/null
find /bin /sbin /usr/bin /usr/sbin /usr/libexec -type f 2>/dev/null | sort | while read -r f; do
  lipo -info "$f" 2>/dev/null | grep -q x86_64 && printf '%s\n' "$f"; done > "$W/list"
wc -l < "$W/list"                                   # expect 1128
cat > "$W/sweep.sh" <<'EOF'
DMR=$1 O=$2 L=$3
mkdir -p "$O"; : > "$O/results.tsv"
while read -r f; do
  in=$O/in out=$O/out err=$O/err; rm -f "$in" "$out" "$err"
  lipo "$f" -thin x86_64 -output "$in" 2>/dev/null || cp "$f" "$in"
  info=$("$DMR" info "$in" 2>/dev/null)
  pad=$(printf '%s\n' "$info" | awk '/^header pad: / { print $3; exit }')
  n=$(( ${pad:-0} / 200 + 2 )); fill=$(printf '%0180d' 0)
  { printf '%s\n' "$info" | grep -q ' LC_CODE_SIGNATURE ' && echo 'load-command delete codesig'
    i=0; while [ $i -lt $n ]; do echo "rpath append /nonexistent/grow-probe-$i/$fill"; i=$((i+1)); done; } > "$O/edits"
  rc=0; "$DMR" "$in" "$out" < "$O/edits" > /dev/null 2> "$err" || rc=$?
  sha=-; [ -f "$out" ] && sha=$(shasum -a 256 < "$out" | cut -c1-16)
  printf '%s\t%s\t%s\t%s\n' "$f" "$rc" "$sha" "$(grep -v '^  ' "$err" | sed "s|$in|IN|g; s|$out|OUT|g" | tr '\n' '|')" >> "$O/results.tsv"
done < "$L"
EOF
sh "$W/sweep.sh" "$W/build/drydock-macho-rewrite" "$W/before" "$W/list" &
sh "$W/sweep.sh" "$B/drydock-macho-rewrite" "$W/after" "$W/list" & wait
for s in before after; do echo "$s: $(cut -f2 "$W/$s/results.tsv" | sort | uniq -c | tr '\n' ' ')"; done
paste "$W/before/results.tsv" "$W/after/results.tsv" | awk -F'\t' '$2 != $6 || $3 != $7 || $4 != $8 { print }' | wc -l
```

Expected: `1128`; `before: 1043 0   85 1` and `after: 1043 0   85 1` (1,043 grew, 85 were refused, all 69 files that are not `MH_EXECUTE` among the refused); and `0` lines differ: every output byte-identical, every message identical (measured with Ruling 1's code, and with the alternative that lost). Keep `$W` for Step 3.

- [ ] **Step 3: Claude Code**

```sh
CC=~/.local/share/claude-binary-snapshots/2.1.282.49763317.bin
shasum -a 256 "$CC" | cut -c1-16                    # expect 5c34b00b0f3862b7
fill=$(printf '%06000d' 0)
printf 'fixups set classic\nrpath append /nonexistent/%s\n' "$fill" > "$W/cc.edits"
for s in before after; do
  d=$([ $s = before ] && echo "$W/build" || echo "$B")
  /usr/bin/time -p "$d/drydock-macho-rewrite" "$CC" "$W/cc.$s" < "$W/cc.edits" 2>&1 | grep -E 'grew|verified|real' | cut -c1-120
done
cmp "$W/cc.before" "$W/cc.after" && echo identical
"$B/drydock-macho-rewrite" verify "$W/cc.after"
```

Expected, for each: `… grew the header pad by 8192 bytes (64 -> 8256 available); image base 0x100000000 -> 0xffffe000; repaired 7 references to the header`, `… verified`, a `real` of about 2.1 s before and 2.3 s after (the range scan decodes Claude Code's 29 in-range candidates); then `identical` and `…/cc.after: OK`. Then `rm -rf "$W"`.

- [ ] **Step 4: `docs/superpowers/QUEUE.md` and the spec**

Item 33 (Ruling 2) states only what was found. Its numbers are from probes run while planning: no file in the 1,128, and no executable under `/System/Library/CoreServices` or `/Applications`, has a nonzero `cryptid`; Finder, Dock, SystemUIServer and loginwindow have a protected `__TEXT`, and a grow of each (the sweep's way) refuses with `ERROR: __TEXT,__unwind_info is malformed, …`.

In `docs/superpowers/QUEUE.md`, replace (`:35`):

```markdown
| 29 | **Executable grow breaks code that addresses its own header** | `specs/2026-09-25-dylib-header-growth-design.md` (the fix is shared with the dylib route) | M0 `0ffa6df..cd05fea`, M1 `7a3a439..688ae2b` (plans deleted once implemented) | **done**: code repaired since `5d93921`, data pointers since `f5b186a`; the code half of I1 is M2's, see below |
| 30 | `fixups set classic` output cannot be re-signed with 10.9's `codesign` | spec and plan deleted once implemented | `549c57e..8a79c86` | **done**: a run that changes `__LINKEDIT` packs it in `codesign_allocate`'s order; `docs/codesign-order.md` |
| 31 | Grow a dylib's header | `specs/2026-09-25-dylib-header-growth-design.md` | — | **designed** 2026-09-25; the adversarial review's findings are being folded in |
| 32 | `info` crashes on a lone load command shorter than its struct | — | — | **to do**, found 2026-09-26 by item 30's final review; see below |
```

with:

```markdown
| 29 | **Executable grow breaks code that addresses its own header** | `specs/2026-09-25-dylib-header-growth-design.md` (the fix is shared with the dylib route) | M0 `0ffa6df..cd05fea`, M1 `7a3a439..688ae2b` (plans deleted once implemented) | **done**: code repaired since `5d93921`, data pointers since `f5b186a`; I1's other halves and binds in `__TEXT` since `@T2@..@T4@` (dylib-growth M2a), see below |
| 30 | `fixups set classic` output cannot be re-signed with 10.9's `codesign` | spec and plan deleted once implemented | `549c57e..8a79c86` | **done**: a run that changes `__LINKEDIT` packs it in `codesign_allocate`'s order; `docs/codesign-order.md` |
| 31 | Grow a dylib's header | `specs/2026-09-25-dylib-header-growth-design.md` | — | **designed** 2026-09-25; the adversarial review's findings are being folded in |
| 32 | `info` crashes on a lone load command shorter than its struct | — | — | **to do**, found 2026-09-26 by item 30's final review; see below |
| 33 | The executable grow has no refusal of its own for encrypted or protected images | — | — | **to do**, found 2026-09-26 while planning dylib-growth M2; see below |
```

In `docs/superpowers/QUEUE.md`, replace (`:1505`):

```markdown
refused (I1, below). Still open, and dylib-growth M2's: a bind whose slot
lies in `__TEXT` is not yet refused on the executable route (none here), and
a grow would move that slot's contents out from under it.
```

with:

```markdown
refused (I1, below). A bind, weak bind or lazy bind whose slot lies in the
segment that maps the header is refused too, since dylib-growth M2a (none
here): a grow would move that slot's contents out from under it.
```

In `docs/superpowers/QUEUE.md`, replace (`:1522`):

```markdown
It is deferred to dylib-growth M2, which
decides that, with the symbol half (a symbol strictly inside: none here).
```

with:

```markdown
Its symbol and export halves are done in M2a too: an `N_SECT` symbol, not a
stab, or an export, not an absolute one, strictly inside (base, base + F)
refuses the grow (none here).
```

In `docs/superpowers/QUEUE.md`, immediately after (`:1574`):

```markdown
`getpagesize()`, so a plain `ctest`, CI's included, fails on such a read.
```

insert:

```markdown

## Item 33: encrypted or protected executables

**Found 2026-09-26** while planning dylib-growth M2, whose raise refuses an
image with `LC_ENCRYPTION_INFO[_64]` whose `cryptid` is not 0, or with a
segment flagged `SG_PROTECTED_VERSION_1`: a grow moves bytes the kernel
decrypts by page. The executable route has no such refusal. On this host,
none of the 1,128 x86_64 files of the M1 sweeps' corpus, and none of the
executables under `/System/Library/CoreServices` and `/Applications`, has a
nonzero `cryptid`. Four executables have a protected `__TEXT`: Finder, Dock,
SystemUIServer and loginwindow. A grow refuses each of them, but only because
their `__unwind_info` lies in the protected pages and does not parse
(`ERROR: __TEXT,__unwind_info is malformed, …`), not for being protected.
```

In `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`, immediately before (`:443`):

```markdown
- **Enforce the one rule's strictly-inside refusal on both routes.** A RIP
```

insert:

```markdown
- **Done in M2a** (`@T1@..@T4@`), with the next bullet, on the one route
  that exists; the raise reuses both.
```

Then replace `@T1@`, `@T2@` and `@T4@` in both files with Step 1's `$F`, `$T2` and `$T4` (the placeholders stand for the first commit, the code commit and the last):

```sh
sed -i '' "s/@T1@/$F/; s/@T2@/$T2/; s/@T4@/$T4/" docs/superpowers/QUEUE.md \
  docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md
rc=0; git grep -n '@T[124]@' -- docs || rc=$?; echo "rc=$rc"   # expect rc=1
git grep -c "$T4" -- docs/superpowers/QUEUE.md docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md   # positive control: 1 each
```

- [ ] **Step 5: Check the tree**

```sh
git grep -n 'Still open, and dylib-growth' -- docs/superpowers/QUEUE.md | wc -l          # expect 0
git grep -n 'Its \*\*code half is done\*\*' -- docs/superpowers/QUEUE.md | wc -l         # expect 1 (positive control)
git grep -n '^## Item 33: encrypted or protected executables' -- docs/superpowers/QUEUE.md | wc -l   # expect 1
rc=0; git grep -n -E 'superpowers|specs/|plans/' -- src tests CMakeLists.txt || rc=$?; echo "rc=$rc"   # expect rc=1
git grep -c -E 'superpowers|specs/|plans/' -- docs/superpowers/QUEUE.md                  # positive control: > 0
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/QUEUE.md docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md
git commit -F- <<EOF
docs: the one rule's code, symbol and export halves, and binds in __TEXT

QUEUE item 29's I1 is done on the executable route, and so is refusing a
bind in the segment that maps the header ($F..$T4). The sweep over this
host's 1,128 x86_64 files is byte-identical, and so is Claude Code's grow.
The spec's M2 section says so; its raise route is plan M2b. Item 33 records
that the executable grow has no refusal of its own for an encrypted or
protected image.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
EOF
```

(The heredoc is unquoted so `$F` and `$T4` expand; check `git log -1` shows the hashes.)

- [ ] **Step 7: After the owner pushes: CI** (Ruling 3)

CI runs on `macos-26-arm64`, from a cross build; it is a gate this host cannot run. After the owner pushes, check that the run for the pushed head is green, and treat a red one as this plan's to fix (memory: "Check CI, not just local suites"):

```sh
gh run list --branch main --limit 3
```

Expected: the newest run, on the pushed head, `completed success`.

---

## Self-review

**1. Spec coverage.**

| requirement | task |
|---|---|
| M2: "give the scan a range (lo, hi) and report each candidate's target" | 1 |
| M2: "`mhr_confirm` is hard-wired to the exact base" | 1 (`mhr_confirm_each`) |
| M2: a RIP target strictly inside (base, base + F) refuses: the owner's decision | 2 (Ruling 1) |
| M2 / Decision 6: a symbol strictly inside refuses | 3 |
| Decision 6: an export offset strictly inside refuses | 3 |
| M2 / Decision 6: a bind in `__TEXT` refuses, on both routes | 4 (and M2b runs it on the raise) |
| Decision 6: refusals leave the buffer untouched | 2, 3, 4 |
| "Interfaces to generalise": `mg_verify_refs` as new base + G; the repair loop; the snapshot's delta | **M2b Task 2**: on the executable route new base + G is the old base, so no test here could tell them apart |

**2. Placeholder scan.** No "TBD" or "similar to Task N". `@T1@`, `@T2@`, `@T4@` are replaced by Task 5's own step. `<authoring model>` is the trailer's own wording.

**3. Type and name consistency.** `mhr_cand.target`, `mhr_scan_range`, `MHR_REFUTED`, `mhr_verdict_fn` and `mhr_confirm_each` (Task 1) are what Task 2 calls. `MG_K_ABS` (Task 3) is what M2b's verification reads. `mg_header_symbols(buf, fsize, base, first, grow, patch)` has its new argument at both call sites. `build_inside_ref`, `build_export_at`, `check_grow_refuses_symbol` and `build_bind_image` are each defined before their first use.

**4. Review Focus.** Five inputs no requirement names: a disp32 with several targets, the edges, what is not an address, `__PAGEZERO`, and a name past the string table. Each has its test in the owning task.
