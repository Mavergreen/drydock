# Header references, M0: warn when a grow moves the header out from under code — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a grow lowers an executable's base, it names on stderr each instruction that reaches the image's own header by RIP-relative distance, which the grow leaves pointing G bytes past it (QUEUE item 29's silent crash becomes a visible warning; M1 repairs it). And the executable grow stops re-basing two things that are not offsets from the base: an absolute export and an empty function-starts list.

**Architecture:** A new module, `src/hdrref.[ch]` (`mhr_`), scans every instruction section at every byte for a RIP-relative operand (ModRM `(b & 0xC7) == 0x05`, disp32, immediate of 0, 1, 2 or 4 bytes) whose target is exactly a given address, and hands each candidate to a callback. `mg_ensure_pad` (`src/grow.c`), the one caller of `mg_grow_header`, runs it against the pre-grow base just before it grows, keeps each candidate's disp32 address, and after its own "grew the header pad" line prints one warning per candidate; the grow itself is unchanged. `mg_trie_node` and `mt_trie_rebuild` leave `EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE` entries alone and `mg_collect` records them as their value; `mg_reencode_funcstarts_base`, the width pre-check and `mg_collect` treat a leading 0 as an empty list.

**Tech Stack:** C as the 10.9 clang (Apple LLVM 6.0) accepts it; CMake through shipyard; POSIX `sh` suites; hand-built in-memory Mach-O fixtures in `tests/grow_test.c` and `tests/trie_test.c`; two tiny x86_64 programs compiled at test time in `tests/grown_binary_runs_test.sh`.

**Spec:** `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`. M0 is only its "M0" milestone bullet and the M0 rows of its Testing table: Decision 3's scan and M0 warning (as revised in `8059a1f`), the export-trie `KIND_ABSOLUTE` fix (Decision 2's table), the leading-zero function-starts fix (Decision 6), and the item 29 regression test. M1 (confirmation, patching, the instruction decoder), M2 (the raise route) and M3 are out of scope: nothing here patches code.

## Claude Code

The Claude Code executable as downloaded has 7 candidates, all `lea __mh_execute_header(%rip)` whose value reaches `___cxa_atexit`'s `dso` argument (an identity key, which is why grown copies run). Measured 2026-09-25 on every installed version (2.1.278 to 2.1.282) by scanning for their original base, `0x100000000`: the installed copies are already grown, so a scan for their current base finds none. So a fresh download **grows, with 7 warnings** (the first names disp32 `0x10004156f` in 2.1.282), and an installed copy grows with none (Task 5 checks that). The owner chose this over refusing (spec, Decision 3, `8059a1f`).

## Global Constraints

- **Line numbers** are at `8059a1f`, before any task. Task 2 adds lines near the top of `src/grow.c`, so later `src/grow.c` line numbers drift; every edit also quotes the text it anchors on, and that text is what to match.
- **Build:** `/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j`. Below, `B=/private/tmp/build/schmonz/drydock-native`; a single C test runs as `"$B/<name>"`.
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/bin/shipyard-ctest --test-dir /private/tmp/build/schmonz/drydock-native`. The shell test in this plan runs alone as `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`, from the repo root.
- **Rebuild check (clock skew on this host).** Before every build, `pre=$(shasum -a 256 "$B/<target>")`; after it, compare. If the binary you changed did not change, `touch` the edited source and build again; if it still did not change, build with `--clean-first`. A result against an unchanged binary is not a result. (Writing this plan, `touch` was not enough: relinks were silently skipped until the edited source's object file, `libdrydockcore.a` and the test binary were deleted before the build. Do that when the sha256 does not change.)
- **TDD and mutation proof** for every task: the test first, seen failing for the stated reason; then the code; then every row of the task's mutation table, each applied alone to a saved copy (`M=$(mktemp -d); cp FILE "$M/"`, edit, rebuild with the rebuild check, run, then `cp "$M/$(basename FILE)" FILE && cmp FILE "$M/$(basename FILE)"`, rebuild), and seen to fail the named test. A mutation no test kills is a finding: add the test that kills it, in the same task.
- **M0 adds no refusal.** A grow that finds header references proceeds exactly as before, plus its warning lines. The one new failure is an allocation failure while listing them, before anything moves.
- **Comments are a last resort:** prefer a test, then the commit message, then a doc, then one inline sentence. No history narration, and no reference to a plan or spec from source (both are deleted once implemented).
- **Exit codes:** `EX_REFUSED` = 1, `EX_FAIL` = 2. Drydock never writes its input, and writes nothing on a refusal. A grow with warnings exits 0.
- **Every grep negative needs a positive control.** In shell, `rc=0; cmd || rc=$?`.
- **Staging:** stage explicit paths only (never `git add -A` or `.`); commit on `main`; do not push. Every commit message ends with:
  ```
  Co-Authored-By: <authoring model> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
  ```
- **CI runs on `macos-26` (arm64).** It runs the whole ctest suite from a cross build; the x86_64 tool and every x86_64 program `tests/grown_binary_runs_test.sh` compiles run there under Rosetta, as `prog` does today (CI run 36157842808 passed it). Every other test here is in-memory and host-independent. After the owner pushes, CI is a separate gate. A grown fixture that CI's toolchain happened to give a header reference now carries a warning line; only a suite that asserts on the exact stderr of that grow would notice.
- **Docs:** `compat/README.md` gets the warning's wording where it quotes a grow's output; `README.md` has no paragraph on grow behavior and is not touched. QUEUE item 29 is marked in the last task.

## Review Focus

1. **An edit that fits the existing pad, on an image that has a header reference** → no grow, so no scan and nothing printed: the image is edited as before. Pinned by Task 2's `test_ensure_pad_fits_despite_a_header_reference`.
2. **A thread-local export (kind 1)** → still an offset from the base, so it still gains `grow`; only kind 2 is left alone. Pinned by Task 3's thread-local halves of `test_grow_leaves_an_absolute_export_alone` and `test_rebuild_absolute_export_untouched`.
3. **Bytes that only look like a RIP-relative operand** (inside another instruction's immediate) → reported, so the grow warns about it: the scan over-reports, never under-reports. Pinned by Task 1's `test_scan_reports_a_lookalike_inside_another_instruction`.
4. **A header address stored in a data section** (no instruction attribute) → not scanned and not warned about; the spec names this residual risk. Pinned by Task 1's `test_scan_reads_every_instruction_section_and_no_other` (`__const` is skipped).
5. **Several references** → one warning each, in address order within a section and load-command order across sections, all after the grow's announcement. Pinned by Task 2's `test_ensure_pad_warns_of_each_header_reference`.

## Plan decisions at a glance

Each is repeated, with its reason, in the task that makes it.

- Task 1: the scan is a new module, `src/hdrref.[ch]` (`mhr_`), not more of `src/grow.c`: M1's patcher, M2's raise and Decision 7's verification all call it, and `grow.c` is already 1491 lines. Its interface hands every candidate (vm address and file offset of the disp32, immediate length) to a callback and takes the target as an argument, because verification scans for base + G, not base.
- Task 1: a disp32 must lie wholly inside its section; its immediate may run past the end (an over-report is safe, an under-report is not). A section with file offset 0 has no file data and is skipped; an instruction section whose bytes run past the file makes the scan fail (-1).
- Task 1: the scan's unit tests go in `tests/grow_test.c`, as the spec's Testing table says.
- Task 2: the warning names **the disp32's vm address**, not the instruction's. M0 has no decoder, so the instruction's first byte is unknown; the disp32 is exactly the four bytes M1 patches, and `otool -tV` shows the instruction that contains it. The amount is the base's move, `base_before - base_after`: exactly how far past the header the operand now points.
- Task 2: **`mg_ensure_pad` scans and prints; `mg_grow_header` is untouched.** `mg_ensure_pad` has the label and is `mg_grow_header`'s only caller. It scans for its `base_before` just before calling `mg_grow_header`, since the grow moves that base; it keeps the disp32 addresses (the grow reallocates the buffer), and prints one warning per candidate after its "grew the header pad" line, so a failed grow prints none. An edit that fits never scans.
- Task 2: an instruction section whose bytes run past the file is not scanned, and the grow says so in a warning of its own, rather than refusing: M0 adds no refusal.
- Task 2: `hdr.c` takes its header's address with an inline `leaq __mh_execute_header(%rip)`, then prints that lea's disp32 address, unslid, so the test knows which address the warning must name with no disassembler. Written in C, whether the reference is a `lea` depends on whether the linker relaxes a GOT load, and CI's linker is not this host's. Whether the grown `hdr` runs is not asserted: that is M1's. The shell test grows with the file's existing `grow` helper (enough pad-derived `LC_RPATH`s, so G is 0x1000), not the reproduction's fixed 3000-byte path.
- Task 3: `mg_collect` records an absolute export as its value, not `base + value`, and does not skip it, so verify still watches it. The absolute kind applies to every address field of an entry, in both walkers.
- Task 3: the `mt_trie_rebuild` test goes in `tests/trie_test.c`, that function's hermetic suite, not `tests/grow_test.c` as the spec's table says.
- Task 4: `mg_collect` skips an empty list's leading 0 too. The spec names only the re-encode and the width check, but without this every grow of such an image fails its own verify (base + 0 moves with the base).

## File structure

| file | status | responsibility | task |
|---|---|---|---|
| `src/hdrref.h`, `src/hdrref.c` | new | `mhr_`: the header-reference scan over a code buffer and over an image | 1 |
| `CMakeLists.txt` | modify | `src/hdrref.c` in `drydockcore` | 1 |
| `tests/grow_test.c` | modify | scan tests (1); warning tests (2); absolute export (3); empty function starts (4) | 1–4 |
| `src/grow.c` | modify | the scan and warnings in `mg_ensure_pad` (2); `mg_trie_node`, `mg_collect` for absolute exports (3); the empty list (4) | 2–4 |
| `src/grow.h` | modify | `mg_ensure_pad`'s contract (2), `mg_trie_node` and `MG_EXPORT_KIND_ABSOLUTE` (3), `mg_reencode_funcstarts_base` (4) | 2–4 |
| `tests/grown_binary_runs_test.sh` | modify | item 29's reproduction (grows, one warning) and control (grows silently, runs) | 2 |
| `src/trie.c`, `src/trie.h` | modify | `mt_trie_rebuild` leaves absolute exports alone | 3 |
| `tests/trie_test.c` | modify | the rebuild's absolute, thread-local and stub-and-resolver cases | 3 |
| `compat/README.md`, `docs/superpowers/QUEUE.md` | modify | the warning's wording; item 29's stop-gap | 5 |

## How this plan was checked

Every code block below was applied, task by task, to a fresh `git archive` of `8059a1f` in a scratch directory with its own build (`shipyard-cmake --preset native`). At each task the build and the named tests failed exactly as each "Run it to see it fail" step says, then passed; the whole ctest suite passed at the end (23 tests, `chained_fixups` skipped as on `main`). All 35 mutation rows were applied one at a time to the finished tree, each rebuild confirmed by a changed sha256, and each failed the test its row names. No existing test or fixture meets the new warning: the suite passed unchanged, and `tests/fixture.macho`, the only committed Mach-O fixture, has 0 candidates. Growing `ctl`, `tests/fixture.macho` and `/usr/bin/printf` with and without these changes gave byte-identical outputs.

---
### Task 1: The header-reference scan (`src/hdrref.[ch]`)

**Files:**
- Create: `src/hdrref.h`, `src/hdrref.c`
- Modify: `CMakeLists.txt:66` (the `add_library(drydockcore STATIC ... src/objc_meth.c)` line)
- Test: `tests/grow_test.c` (`#include "grow.h"` at `:17`; new tests before `int main(void) {` at `:1883`; calls after `test_grow_diagnostics_name_no_program();` at `:1930`)

**Interfaces:**
- Consumes: `mi_wrap`, `mi_each_lc` (`src/image.h`).
- Produces (Task 2 calls `mhr_scan`; M1 and M2 will call both):
  - `typedef struct { uint64_t addr; uint64_t off; int immlen; } mhr_cand;` — the disp32's vm address and file offset, and the immediate length (0, 1, 2 or 4) that makes the target exact.
  - `typedef int (*mhr_fn)(const mhr_cand *c, void *ctx);` — nonzero stops the scan.
  - `uint64_t mhr_scan_code(const uint8_t *code, uint64_t size, uint64_t addr, uint64_t off, uint64_t target, mhr_fn fn, void *ctx);` → the number of candidates passed to `fn`.
  - `int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx);` → the number of candidates, or -1 when `buf` does not wrap or an instruction section runs past `fsize`.

**Plan decisions.** The scan is its own module because three later callers need it (M1's confirm-and-patch, M2's raise, Decision 7's re-scan of the output), and `src/grow.c` is already 1491 lines; it takes `target` as an argument because verification scans for base + G. A disp32 must lie wholly inside its section, but an immediate may run past the end: an over-report is a needless warning, an under-report a silent crash. A section with file offset 0 has no file data (a zerofill section's `size` is its vm size), as `mg_first_sect_off` already treats it. The tests go in `tests/grow_test.c`, as the spec's Testing table says.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, after `#include "grow.h"` (`:17`) add:

```c
#include "hdrref.h"
```

Insert before `int main(void) {` (`:1883`):

```c
/* ---- the header-reference scan (src/hdrref.h) ----
 * Code bytes are hand-assembled here; each planted operand's disp32 is
 * computed from where it sits, so the test states only the target. Filler is
 * 0x90, which no scan can mistake for a RIP-relative ModRM (0x90 & 0xC7 is
 * 0x80). */
#define HR_BASE 0x100000000ull
#define HR_CODE 0x100001000ull   /* the vm address each test's code loads at */
#define HR_FOFF 0x1000u          /* ... and its file offset */

struct hr_seen { mhr_cand c[8]; int n; int stop_after; };
static int hr_record(const mhr_cand *c, void *ctx) {
    struct hr_seen *s = (struct hr_seen *)ctx;
    if (s->n < 8) s->c[s->n] = *c;
    s->n++;
    return s->stop_after && s->n >= s->stop_after;
}

/* `modrm`, then a disp32 that makes the target `target` for an operand
 * followed by `immlen` bytes of immediate, at code[at]; code loads at `va`. */
static void hr_plant(uint8_t *code, uint64_t va, uint32_t at, uint8_t modrm, int immlen,
                     uint64_t target) {
    uint64_t next = va + at + 1 + 4 + (uint64_t)immlen;
    int32_t disp = (int32_t)(int64_t)(target - next);
    code[at] = modrm;
    memcpy(code + at + 1, &disp, sizeof disp);
}

static void test_scan_finds_every_immediate_length(void) {
    uint8_t code[64];
    static const uint8_t modrm[4] = { 0x05, 0x0d, 0x3d, 0x25 };  /* reg field 0, 1, 7, 4 */
    static const int immlen[4] = { 0, 1, 2, 4 };
    memset(code, 0x90, sizeof code);
    for (int k = 0; k < 4; k++) hr_plant(code, HR_CODE, 2 + 12 * k, modrm[k], immlen[k], HR_BASE);
    struct hr_seen s = { { { 0 } }, 0, 0 };
    uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, hr_record, &s);
    CHECK(n == 4 && s.n == 4, "scan: four planted forms, %llu reported (%d visited)",
          (unsigned long long)n, s.n);
    for (int k = 0; k < 4 && k < s.n; k++) {
        CHECK(s.c[k].addr == HR_CODE + 3 + 12 * k && s.c[k].off == HR_FOFF + 3 + 12 * k,
              "scan: immediate length %d: disp32 at %#llx (file %#llx), want %#llx (file %#llx)",
              immlen[k], (unsigned long long)s.c[k].addr, (unsigned long long)s.c[k].off,
              (unsigned long long)(HR_CODE + 3 + 12 * k), (unsigned long long)(HR_FOFF + 3 + 12 * k));
        CHECK(s.c[k].immlen == immlen[k], "scan: candidate %d has immediate length %d, want %d",
              k, s.c[k].immlen, immlen[k]);
    }
}

/* The target must be the base exactly: the review found that everything that
 * names the header names exactly the base, and nothing names a byte past it. */
static void test_scan_ignores_a_target_one_byte_past_the_base(void) {
    uint8_t code[16];
    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 2, 0x05, 0, HR_BASE + 1);
    uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, NULL, NULL);
    CHECK(n == 0, "scan: a target one byte past the base is a candidate (%llu)",
          (unsigned long long)n);
}

/* Only mod 00 with r/m 101 is RIP-relative. r/m 100 means a SIB byte follows,
 * and mod 01, 10 or 11 with r/m 101 means [rbp + disp] or a register. Each of
 * these is followed by four bytes that, read as a RIP-relative disp32, would
 * name the base. */
static void test_scan_ignores_forms_that_are_not_rip_relative(void) {
    static const uint8_t modrm[] = { 0x04, 0x0c, 0x45, 0x85, 0xc5 };
    for (size_t k = 0; k < sizeof modrm; k++) {
        uint8_t code[16];
        memset(code, 0x90, sizeof code);
        hr_plant(code, HR_CODE, 2, modrm[k], 0, HR_BASE);
        uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, NULL, NULL);
        CHECK(n == 0, "scan: ModRM %#04x is not RIP-relative, yet %llu reported", modrm[k],
              (unsigned long long)n);
    }
}

/* A disp32 must lie wholly inside the section; an immediate need not. The
 * byte past the section completes, if it is read, a disp32 naming the base. */
static void test_scan_stops_at_the_section_end(void) {
    uint8_t code[24];
    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 15, 0x05, 4, HR_BASE);   /* disp32 is bytes 16-19 of 20 */
    struct hr_seen s = { { { 0 } }, 0, 0 };
    uint64_t n = mhr_scan_code(code, 20, HR_CODE, HR_FOFF, HR_BASE, hr_record, &s);
    CHECK(n == 1 && s.n == 1 && s.c[0].addr == HR_CODE + 16,
          "scan: a disp32 ending exactly at the section's end: %llu reported",
          (unsigned long long)n);

    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 16, 0x05, 0, HR_BASE);   /* disp32 is bytes 17-20 of 20 */
    n = mhr_scan_code(code, 20, HR_CODE, HR_FOFF, HR_BASE, NULL, NULL);
    CHECK(n == 0, "scan: a disp32 that runs one byte past the section: %llu reported",
          (unsigned long long)n);
}

/* A byte inside another instruction can look like a ModRM. The scan reports
 * it: it may over-report, never under-report. Here 0x05 is the first byte of
 * `mov $imm32, %eax`'s immediate. */
static void test_scan_reports_a_lookalike_inside_another_instruction(void) {
    uint8_t code[16];
    memset(code, 0x90, sizeof code);
    code[2] = 0xb8;                                   /* mov $imm32, %eax */
    hr_plant(code, HR_CODE, 3, 0x05, 0, HR_BASE);
    uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, NULL, NULL);
    CHECK(n == 1, "scan: a lookalike inside an immediate: %llu reported, want 1",
          (unsigned long long)n);
}

static void test_scan_stops_when_asked(void) {
    uint8_t code[32];
    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 2, 0x05, 0, HR_BASE);
    hr_plant(code, HR_CODE, 12, 0x05, 0, HR_BASE);
    struct hr_seen s = { { { 0 } }, 0, 1 };
    uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, hr_record, &s);
    CHECK(n == 1 && s.n == 1 && s.c[0].addr == HR_CODE + 3,
          "scan: a callback that stops at the first: %llu reported, %d visited",
          (unsigned long long)n, s.n);
}

/* A PIE image, `HR_IMG_SIZE` bytes, whose __TEXT holds three sections of
 * 0x90: __text (both instruction attributes, as ld64 writes it), __stubs
 * (S_ATTR_SOME_INSTRUCTIONS only) and __const (neither). */
#define HR_IMG_SIZE 0x2000u
static uint8_t *build_code_image(void) {
    static const struct { const char *name; uint32_t flags; uint32_t off; } s[3] = {
        { "__text",  S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, 0x1000 },
        { "__stubs", S_SYMBOL_STUBS | S_ATTR_SOME_INSTRUCTIONS,           0x1400 },
        { "__const", S_REGULAR,                                           0x1800 },
    };
    uint8_t *buf = (uint8_t *)calloc(1, HR_IMG_SIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    h->ncmds = 1;
    struct segment_command_64 *tx = (struct segment_command_64 *)(h + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + 3 * sizeof(struct section_64);
    memcpy(tx->segname, "__TEXT", 6);
    tx->vmaddr = HR_BASE;
    tx->vmsize = tx->filesize = HR_IMG_SIZE;
    tx->nsects = 3;
    h->sizeofcmds = tx->cmdsize;
    struct section_64 *sc = (struct section_64 *)(tx + 1);
    for (int k = 0; k < 3; k++) {
        strncpy(sc[k].sectname, s[k].name, sizeof sc[k].sectname);
        memcpy(sc[k].segname, "__TEXT", 6);
        sc[k].addr = HR_BASE + s[k].off;
        sc[k].size = 0x100;
        sc[k].offset = s[k].off;
        sc[k].flags = s[k].flags;
        memset(buf + s[k].off, 0x90, 0x100);
    }
    return buf;
}

static void test_scan_reads_every_instruction_section_and_no_other(void) {
    uint8_t *buf = build_code_image();
    hr_plant(buf + 0x1000, HR_BASE + 0x1000, 0x20, 0x05, 0, HR_BASE);
    hr_plant(buf + 0x1400, HR_BASE + 0x1400, 0x30, 0x05, 0, HR_BASE);
    hr_plant(buf + 0x1800, HR_BASE + 0x1800, 0x40, 0x05, 0, HR_BASE);   /* data: not scanned */
    struct hr_seen s = { { { 0 } }, 0, 0 };
    int64_t n = mhr_scan(buf, HR_IMG_SIZE, HR_BASE, hr_record, &s);
    CHECK(n == 2 && s.n == 2, "image scan: %lld candidates, want __text's and __stubs'", (long long)n);
    if (s.n == 2) {
        CHECK(s.c[0].addr == HR_BASE + 0x1021 && s.c[0].off == 0x1021,
              "image scan: __text's at %#llx (file %#llx)",
              (unsigned long long)s.c[0].addr, (unsigned long long)s.c[0].off);
        CHECK(s.c[1].addr == HR_BASE + 0x1431 && s.c[1].off == 0x1431,
              "image scan: __stubs' at %#llx (file %#llx)",
              (unsigned long long)s.c[1].addr, (unsigned long long)s.c[1].off);
    }
    struct hr_seen first = { { { 0 } }, 0, 1 };
    n = mhr_scan(buf, HR_IMG_SIZE, HR_BASE, hr_record, &first);
    CHECK(n == 1 && first.n == 1, "image scan: a callback that stops at __text's went on "
          "to %d", first.n);
    free(buf);
}

/* An instruction section whose bytes the file does not hold cannot be
 * scanned, so nothing can be said about it. */
static void test_scan_refuses_an_instruction_section_past_the_image(void) {
    uint8_t *buf = build_code_image();
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    sc[1].size = HR_IMG_SIZE;                         /* __stubs: 0x1400 + 0x2000 > 0x2000 */
    CHECK(mhr_scan(buf, HR_IMG_SIZE, HR_BASE, NULL, NULL) == -1,
          "image scan: an instruction section past the end of the image was scanned");
    sc[1].offset = 0;                                 /* no file data, whatever its size */
    sc[1].size = 2 * HR_IMG_SIZE;
    CHECK(mhr_scan(buf, HR_IMG_SIZE, HR_BASE, NULL, NULL) == 0,
          "image scan: an instruction section with no file data was not skipped");
    free(buf);
}
```

And after `    test_grow_diagnostics_name_no_program();` (`:1930`), inside `main`:

```c
    test_scan_finds_every_immediate_length();
    test_scan_ignores_a_target_one_byte_past_the_base();
    test_scan_ignores_forms_that_are_not_rip_relative();
    test_scan_stops_at_the_section_end();
    test_scan_reports_a_lookalike_inside_another_instruction();
    test_scan_stops_when_asked();
    test_scan_reads_every_instruction_section_and_no_other();
    test_scan_refuses_an_instruction_section_past_the_image();
```

- [ ] **Step 2: Run it to see it fail**

Run: `/usr/local/bin/shipyard-cmake --build "$B" -j`
Expected: the build fails: `tests/grow_test.c:18:10: fatal error: 'hdrref.h' file not found`.

- [ ] **Step 3: Write `src/hdrref.h`**

```c
#ifndef DRYDOCK_HDRREF_H
#define DRYDOCK_HDRREF_H
/*
 * mhr_ -- code that reaches its own image's header by RIP-relative distance.
 *
 * In 64-bit mode every RIP-relative operand is a ModRM byte with
 * (b & 0xC7) == 0x05, then a disp32, then 0, 1, 2 or 4 bytes of immediate.
 * Its target is the next instruction's address plus the disp32. A grow moves
 * the header relative to the code, and no rebase, bind or load command
 * records such a distance, so these are found in the code itself.
 *
 * The scan tries every byte of every instruction section as a ModRM byte,
 * with every immediate length, so it cannot miss an instruction form. It can
 * over-report: a byte inside another instruction can look like a ModRM.
 */
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t addr;    /* vm address of the disp32 */
    uint64_t off;     /* file offset of the disp32 */
    int      immlen;  /* 0, 1, 2 or 4: the immediate length that makes the target exact */
} mhr_cand;

/* Called once per candidate, in address order within a section and in
 * load-command order across sections. Returning nonzero stops the scan. */
typedef int (*mhr_fn)(const mhr_cand *c, void *ctx);

/* Every candidate in `code[0, size)`, which loads at vm address `addr` from
 * file offset `off`, whose target is exactly `target`. Its disp32 lies wholly
 * inside `code`; its immediate may run past the end. `fn` may be NULL.
 * Returns how many candidates were passed to `fn`, counting one that stopped
 * the scan. */
uint64_t mhr_scan_code(const uint8_t *code, uint64_t size, uint64_t addr, uint64_t off,
                       uint64_t target, mhr_fn fn, void *ctx);

/* mhr_scan_code over every section with S_ATTR_PURE_INSTRUCTIONS or
 * S_ATTR_SOME_INSTRUCTIONS and file data. Returns the number of candidates,
 * or -1 when `buf` does not wrap or an instruction section's bytes lie past
 * `fsize`. */
int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx);

#endif /* DRYDOCK_HDRREF_H */
```

- [ ] **Step 4: Write `src/hdrref.c`**

```c
/* mhr_ -- see hdrref.h. */
#include <string.h>
#include <mach-o/loader.h>

#include "hdrref.h"
#include "image.h"

static const int mhr_immlens[4] = { 0, 1, 2, 4 };

static uint64_t mhr_code(const uint8_t *code, uint64_t size, uint64_t addr, uint64_t off,
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
            n++;
            if (fn && fn(&c, ctx)) { *stopped = 1; return n; }
        }
    }
    return n;
}

uint64_t mhr_scan_code(const uint8_t *code, uint64_t size, uint64_t addr, uint64_t off,
                       uint64_t target, mhr_fn fn, void *ctx) {
    int stopped = 0;
    return mhr_code(code, size, addr, off, target, fn, ctx, &stopped);
}

struct mhr_ctx {
    const uint8_t *buf;
    size_t fsize;
    uint64_t target;
    mhr_fn fn;
    void *ctx;
    uint64_t n;
    int stopped, bad;
};

static int mhr_seg_cb(const struct load_command *lc, void *ctx_) {
    struct mhr_ctx *c = (struct mhr_ctx *)ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(seg + 1);
    for (uint32_t j = 0; j < seg->nsects; j++) {
        if (!(s[j].flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) continue;
        if (s[j].offset == 0) continue;
        if (s[j].size > c->fsize || s[j].offset > c->fsize - s[j].size) { c->bad = 1; return 1; }
        c->n += mhr_code(c->buf + s[j].offset, s[j].size, s[j].addr, s[j].offset,
                         c->target, c->fn, c->ctx, &c->stopped);
        if (c->stopped) return 1;
    }
    return 0;
}

int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0) return -1;
    struct mhr_ctx c = { buf, fsize, target, fn, ctx, 0, 0, 0 };
    mi_each_lc(&im, mhr_seg_cb, &c);
    return c.bad ? -1 : (int64_t)c.n;
}
```

- [ ] **Step 5: Register it**

In `CMakeLists.txt:66`, add `src/hdrref.c` as the last source of the `add_library(drydockcore STATIC ...)` line, after whatever is last there now (today the line ends `src/exports.c src/objc_meth.c)`; objc-methods M2's plan appends `src/rebase.c` to the same line, so if that has landed, it ends `src/objc_meth.c src/rebase.c)`):

```cmake
... src/exports.c src/objc_meth.c src/hdrref.c)
```

- [ ] **Step 6: Build and run**

Run: build (rebuild check on `$B/grow_test`), then `"$B/grow_test"`.
Expected: last line `macho_grow_test: all cases pass`, and no line starting `FAIL:`. Then the whole suite (Test command): all pass.

- [ ] **Step 7: Mutation proof** (file `src/hdrref.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `if ((code[i] & 0xC7) != 0x05) continue;` | `if ((code[i] & 0x07) != 0x05) continue;` | `test_scan_ignores_forms_that_are_not_rip_relative` (ModRM 0x45, 0x85, 0xc5) |
| 2 | `if ((code[i] & 0xC7) != 0x05) continue;` | `if ((code[i] & 0xC0) != 0x00) continue;` | `test_scan_ignores_forms_that_are_not_rip_relative` (0x04, 0x0c: SIB forms) |
| 3 | `for (uint64_t i = 0; i + 5 <= size; i++) {` | `for (uint64_t i = 0; i + 4 <= size; i++) {` | `test_scan_stops_at_the_section_end` ("runs one byte past the section") |
| 4 | `for (uint64_t i = 0; i + 5 <= size; i++) {` | `for (uint64_t i = 0; i + 6 <= size; i++) {` | `test_scan_stops_at_the_section_end` ("ending exactly at the section's end") |
| 5 | `static const int mhr_immlens[4] = { 0, 1, 2, 4 };` | `static const int mhr_immlens[4] = { 0, 1, 2, 3 };` | `test_scan_finds_every_immediate_length` |
| 6 | `(uint64_t)(int64_t)disp != target) continue;` | `(uint64_t)(int64_t)disp < target) continue;` | `test_scan_ignores_a_target_one_byte_past_the_base` |
| 7 | `mhr_cand c = { at, off + i + 1, mhr_immlens[k] };` | `mhr_cand c = { at, off + i, mhr_immlens[k] };` | `test_scan_finds_every_immediate_length` ("disp32 at ... (file ...)") |
| 8 | `if (fn && fn(&c, ctx)) { *stopped = 1; return n; }` | `if (fn) fn(&c, ctx);` | `test_scan_stops_when_asked` |
| 9 | `if (!(s[j].flags & (S_ATTR_PURE_INSTRUCTIONS \| S_ATTR_SOME_INSTRUCTIONS))) continue;` | `if (!(s[j].flags & S_ATTR_PURE_INSTRUCTIONS)) continue;` | `test_scan_reads_every_instruction_section_and_no_other` (`__stubs` missed) |
| 10 | the same line | (delete it) | `test_scan_reads_every_instruction_section_and_no_other` (`__const` scanned) |
| 11 | `{ c->bad = 1; return 1; }` | `continue;` | `test_scan_refuses_an_instruction_section_past_the_image` |
| 12 | `if (s[j].offset == 0) continue;` | (delete it) | `test_scan_refuses_an_instruction_section_past_the_image` ("with no file data was not skipped") |
| 13 | `if (c->stopped) return 1;` | (delete it) | `test_scan_reads_every_instruction_section_and_no_other` ("a callback that stops at __text's went on") |

- [ ] **Step 8: Commit**

```bash
git add src/hdrref.h src/hdrref.c tests/grow_test.c CMakeLists.txt
git commit -m "feat(hdrref): find code that addresses its image's own header

A RIP-relative operand in x86_64 is a ModRM byte with (b & 0xC7) == 0x05,
a disp32 and 0, 1, 2 or 4 bytes of immediate. Trying every byte of every
instruction section, with every immediate length, finds every operand
whose target is a given address, and can over-report but never miss one.
Nothing calls it yet; growing an executable will.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 2: Warn of each instruction a grow leaves pointing past the header

**Files:**
- Modify: `src/grow.c` (`#include "grow.h"` at `:3`; `int mg_ensure_pad(` at `:50`; its tail, `:78-104`, from `uint64_t base_before = ...` to the closing `}`)
- Modify: `src/grow.h:105-107` (`mg_ensure_pad`'s contract, "A grow is always announced ...")
- Test: `tests/grow_test.c` (before `int main(void) {`; calls after Task 1's last call), `tests/grown_binary_runs_test.sh` (the header comment at `:9-11`; a new section before `[ "$fail" -eq 0 ] || ...` at `:146`)

**Interfaces:**
- Consumes: `mhr_cand`, `mhr_scan` (Task 1); `hr_plant`, `HR_BASE` (Task 1's test helpers); `build_image`'s `MG_T_PLAINSECT` section `__plain` (file offset 6144, 16 bytes), `find_section_struct` (`tests/grow_test.c:1666`); `mg_base_of` (`src/grow.c:43`).
- Produces: after a successful grow, `mg_ensure_pad` prints on stderr, after its "grew the header pad" line and in scan order:
  - for each candidate: `LABEL: warning: code at 0x<disp32 vm address> addresses the image's own header; after this grow it points 0x<G> bytes past it (QUEUE item 29)`
  - if an instruction section could not be scanned: `LABEL: warning: an instruction section lies past the end of the image, so it was not scanned for code that addresses the image's own header`

  It still returns 0, and the grown image is the one it produced before this task. `mg_grow_header` does not change.

**Plan decisions.** The warning names the disp32's vm address (the candidate's `addr`), not the instruction's: with no decoder the instruction's first byte is unknown, the disp32 is exactly what M1 will patch, and `otool -tV` shows the instruction containing it. G is the base's move, `base_before - base_after`. `mg_ensure_pad` does the scanning and the printing and `mg_grow_header` stays as it is: `mg_ensure_pad` holds the label, is the only caller of `mg_grow_header`, and already knows `base_before`. It scans just before calling `mg_grow_header`, because the grow moves the base the code was linked against, keeps the addresses (the grow reallocates the buffer), and prints only after its announcement, so a failed grow prints no warning and an edit that fits never scans. An instruction section past the end of the file gets its own warning rather than a refusal, since M0 adds none. `hdr.c` takes its header's address with inline `leaq __mh_execute_header(%rip)` and prints that lea's disp32 address (the label after it, less 4, less the slide), so the shell test knows the address the warning must name without a disassembler; in C (`&_mh_execute_header`) the instruction is a `lea` only if the linker relaxes the GOT load, and CI's linker is not this host's. The test does not run the grown `hdr`: it still crashes, and asserting either way belongs to M1. The shell test grows through the file's existing `grow` helper, whose `LC_RPATH`s outgrow the pad by less than a page, so G is `0x1000`.

- [ ] **Step 1: Write the failing in-memory tests**

Insert in `tests/grow_test.c`, before `int main(void) {`:

```c
/* ---- a grow warns of code that addresses its own header ----
 * Lowering the base moves the header down by the grow while the code stays
 * put, so `lea __mh_execute_header(%rip)` then names a byte that far past
 * it, and nothing a grow re-bases or verifies records that distance. Until
 * such code is repaired, the grow names each one after its announcement.
 * __plain becomes code at the vm address its file offset maps to, filled
 * with 0x90, with `lea base(%rip), %rax` (48 8d 05 disp32) at each of `at`. */
#define HR_PLAIN_VA 0x100001800ull
static void plant_header_refs(uint8_t *buf, size_t fsize, const uint32_t *at, int n) {
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    CHECK(pl != NULL, "setup: __plain present");
    if (!pl) return;
    pl->addr = HR_PLAIN_VA;
    pl->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    memset(buf + pl->offset, 0x90, pl->size);
    for (int k = 0; k < n; k++) {
        buf[pl->offset + at[k]] = 0x48;
        buf[pl->offset + at[k] + 1] = 0x8d;
        hr_plant(buf + pl->offset, HR_PLAIN_VA, at[k] + 2, 0x05, 0, HR_BASE);
    }
}

/* Everything mg_ensure_pad(..., need, "t") prints on stderr, as one string
 * the caller frees. */
static char *ensure_pad_stderr(uint8_t **pbuf, size_t *pfsize, uint32_t need, int *ret) {
    const char *tmpdir = getenv("TMPDIR");
    char path[512];
    char *text = (char *)calloc(1, 65536);
    if (!tmpdir) tmpdir = "/tmp";
    snprintf(path, sizeof path, "%s/macho_grow_test_warn.%d", tmpdir, (int)getpid());
    fflush(stderr);
    int saved_fd = dup(fileno(stderr));
    if (!freopen(path, "w", stderr)) {
        CHECK(0, "could not capture stderr to %s", path);
        *ret = mg_ensure_pad(pbuf, pfsize, need, "t");
        return text;
    }
    *ret = mg_ensure_pad(pbuf, pfsize, need, "t");
    fflush(stderr);
    dup2(saved_fd, fileno(stderr));
    close(saved_fd);
    clearerr(stderr);
    FILE *rf = fopen(path, "r");
    if (rf) {
        size_t got = fread(text, 1, 65535, rf);
        text[got] = '\0';
        fclose(rf);
    }
    unlink(path);
    return text;
}

static int count_of(const char *hay, const char *needle) {
    int n = 0;
    for (const char *p = hay; (p = strstr(p, needle)) != NULL; p++) n++;
    return n;
}

#define HR_WARNING(addr) "t: warning: code at " addr " addresses the image's own header; " \
                         "after this grow it points 0x1000 bytes past it (QUEUE item 29)\n"

static void test_ensure_pad_warns_of_each_header_reference(void) {
    static const uint32_t two[] = { 0, 8 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    plant_header_refs(buf, fsize, two, 2);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    const char *grew = strstr(err, "t: grew the header pad by 4096 bytes");
    const char *w1 = strstr(err, HR_WARNING("0x100001803"));
    const char *w2 = strstr(err, HR_WARNING("0x10000180b"));
    CHECK(r == 0, "two header references: the grow proceeds (got %d)", r);
    CHECK(grew != NULL, "two header references: the grow is announced:\n%s", err);
    CHECK(grew && w1 && w2 && grew < w1 && w1 < w2,
          "two header references: one warning each, in order, after the announcement:\n%s", err);
    CHECK(count_of(err, ": warning: ") == 2, "two header references: %d warnings, want 2",
          count_of(err, ": warning: "));
    free(err);
    free(buf);
}

/* The control: the same section as code, with no reference, grows silently. */
static void test_ensure_pad_does_not_warn_without_a_header_reference(void) {
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    plant_header_refs(buf, fsize, NULL, 0);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == 0 && strstr(err, "t: grew the header pad by ") != NULL,
          "no header reference: the grow happens and is announced (got %d):\n%s", r, err);
    CHECK(count_of(err, ": warning: ") == 0, "no header reference: no warning, yet:\n%s", err);
    free(err);
    free(buf);
}

/* Code the file does not hold cannot be scanned, and the grow says so. */
static void test_ensure_pad_warns_of_code_it_cannot_scan(void) {
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    plant_header_refs(buf, fsize, NULL, 0);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) pl->size = fsize;                  /* 6144 + 8192 runs past the image */
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == 0, "code past the image: the grow proceeds (got %d)", r);
    CHECK(strstr(err, "t: warning: an instruction section lies past the end of the image, so it "
                      "was not scanned for code that addresses the image's own header\n") != NULL,
          "code past the image: the grow says it was not scanned:\n%s", err);
    free(err);
    free(buf);
}

/* The scan runs only when the pad must grow: an edit that fits needs no
 * grow, nothing moves the header, and nothing is printed. */
static void test_ensure_pad_fits_despite_a_header_reference(void) {
    static const uint32_t one[] = { 0 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    plant_header_refs(buf, fsize, one, 1);
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off, &r);
    CHECK(r == 0, "ensure_pad: a fit with a header reference succeeds (got %d)", r);
    CHECK(err[0] == '\0', "ensure_pad: a fit prints nothing, yet:\n%s", err);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "ensure_pad: a fit leaves an image with a header reference alone");
    free(err);
    free(before);
    free(buf);
}
```

And after `    test_scan_refuses_an_instruction_section_past_the_image();` in `main`:

```c
    test_ensure_pad_warns_of_each_header_reference();
    test_ensure_pad_does_not_warn_without_a_header_reference();
    test_ensure_pad_warns_of_code_it_cannot_scan();
    test_ensure_pad_fits_despite_a_header_reference();
```

- [ ] **Step 2: Write the failing end-to-end test**

In `tests/grown_binary_runs_test.sh`, replace the header comment's subjects sentence (`:9-11`):

```sh
# The subjects: a PIE executable linked here with -headerpad 0, and a system
# executable when one qualifies (a 64-bit PIE MH_EXECUTE the grow accepts as
# it is; a slice with chained fixups does not, and is reported as a SKIP).
```

with:

```sh
# The subjects: a PIE executable linked here with -headerpad 0; a system
# executable when one qualifies (a 64-bit PIE MH_EXECUTE the grow accepts as
# it is; a slice with chained fixups does not, and is reported as a SKIP); and
# two programs that find their own header: one RIP-relatively, whose grow must
# warn about it, and one through dyld, which must grow silently and run.
```

and insert, before `[ "$fail" -eq 0 ] || { echo "grown_binary_runs_test: $fail failure(s)"; exit 1; }` (`:146`):

```sh
# ---- 3. code that addresses its own header ----------------------------------
# hdr takes its own header's address RIP-relatively, as getsectiondata(
# &_mh_execute_header, ...) does; the inline lea makes that instruction this
# fixture's on every linker, whether or not it relaxes a GOT load, and hdr
# prints where that lea's disp32 lies. A grow moves the header out from under
# it, so the grow must name it in a warning. Whether the grown hdr runs is
# not asserted: it does not yet. ctl asks dyld for its header instead, so it
# must grow with no warning, and run.
cat >"$T/hdr.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
int payload = 42;
int main(void) {
    const struct mach_header_64 *h;
    const char *end;
    unsigned long size = 0;
    __asm__("leaq __mh_execute_header(%%rip), %0\n1:\n\tleaq 1b(%%rip), %1" : "=r"(h), "=r"(end));
    uint8_t *p = getsectiondata(h, "__DATA", "__data", &size);
    printf("disp32 at %#lx\n", (unsigned long)(end - 4 - _dyld_get_image_vmaddr_slide(0)));
    printf("header magic %#x, __data %s (%lu bytes)\n", h->magic, p ? "found" : "NOT FOUND", size);
    return p ? 0 : 1;
}
EOF
cat >"$T/ctl.c" <<'EOF'
#include <stdio.h>
#include <stdint.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
int payload = 42;
int main(void) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(0);
    unsigned long size = 0;
    uint8_t *p = getsectiondata(h, "__DATA", "__data", &size);
    printf("header magic %#x, __data %s (%lu bytes)\n", h->magic, p ? "found" : "NOT FOUND", size);
    return p ? 0 : 1;
}
EOF
for p in hdr ctl; do
    "$CC" $FF -Wl,-headerpad,0 -o "$T/$p" "$T/$p.c" \
        || { echo "grown_binary_runs_test: could not link $p" >&2; exit 1; }
done

"$T/hdr" >"$T/hdr.run" 2>&1
grep -q '__data found' "$T/hdr.run" \
    && ok "hdr: the fixture finds its own __data" || bad "hdr: fixture" "$(cat "$T/hdr.run")"
disp=$(awk '/^disp32 at 0x/ { print $3; exit }' "$T/hdr.run")
grow hdr "$T/hdr" "$T/hdr.grown"
[ "$grc" -eq 0 ] && [ -e "$T/hdr.grown" ] && ok "hdr: the grow succeeds and writes its output" \
    || bad "hdr: grow" "exit $grc: $(cat "$T/hdr.grow.err")"
lowered hdr "$T/hdr" "$T/hdr.grown"
n=$(grep -c ': warning: ' "$T/hdr.grow.err")
[ "$n" -eq 1 ] && ok "hdr: ... with exactly one warning" || bad "hdr: warnings" "$n: $(cat "$T/hdr.grow.err")"
grep -Fxq "$T/hdr: warning: code at $disp addresses the image's own header; after this grow it points 0x1000 bytes past it (QUEUE item 29)" \
    "$T/hdr.grow.err" \
    && ok "hdr: ... naming its lea's disp32 ($disp) and the grow" \
    || bad "hdr: warning" "want disp32 '$disp': $(grep ': warning: ' "$T/hdr.grow.err")"

grow ctl "$T/ctl" "$T/ctl.grown"
[ "$grc" -eq 0 ] && [ -e "$T/ctl.grown" ] && ok "ctl: the grow succeeds and writes its output" \
    || bad "ctl: grow" "exit $grc: $(cat "$T/ctl.grow.err")"
lowered ctl "$T/ctl" "$T/ctl.grown"
rc=0; grep -q ': warning: ' "$T/ctl.grow.err" || rc=$?
[ "$rc" -eq 1 ] && ok "ctl: ... with no warning (hdr's grep, above, finds one)" \
    || bad "ctl: warning" "$(grep ': warning: ' "$T/ctl.grow.err")"
same ctl "$T/ctl" "$T/ctl.grown"
grep -q '__data found' "$T/ctl.out.out" \
    && ok "ctl: ... and the grown binary finds its own __data" \
    || bad "ctl: grown output" "$(cat "$T/ctl.out.out")"
```

- [ ] **Step 3: Run them to see them fail**

Run: build (rebuild check on `$B/grow_test`), then `"$B/grow_test"`.
Expected: exit 1, and exactly three `FAIL:` lines (two are followed by the captured stderr, which has the grow's announcement and no warning):

```
FAIL: two header references: one warning each, in order, after the announcement:
FAIL: two header references: 0 warnings, want 2
FAIL: code past the image: the grow says it was not scanned:
```

The control and `test_ensure_pad_fits_despite_a_header_reference` already pass: they pin what this task must keep.

Run: `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`
Expected: exit 1, `grown_binary_runs_test: 2 failure(s)`: `FAIL hdr: warnings: 0: ...` and `FAIL hdr: warning: want disp32 '0x...'`. `hdr` grows (exit 0) and every `ctl:` line passes.

- [ ] **Step 4: Implement the warning**

In `src/grow.c`, after `#include "grow.h"` (`:3`) add:

```c
#include "hdrref.h"
```

Immediately before `int mg_ensure_pad(uint8_t **pbuf, size_t *pfsize, uint32_t need_end,` (`:50`) add:

```c
/* The vm address of every disp32 mhr_scan reports, for mg_ensure_pad to warn
 * of after it grows. */
struct mg_refs { uint64_t *addr; size_t n, cap; int oom; };

static int mg_keep_ref(const mhr_cand *c, void *ctx_) {
    struct mg_refs *r = (struct mg_refs *)ctx_;
    if (r->n == r->cap) {
        size_t cap = r->cap ? 2 * r->cap : 8;
        uint64_t *a = (uint64_t *)realloc(r->addr, cap * sizeof *a);
        if (!a) { r->oom = 1; return 1; }
        r->addr = a;
        r->cap = cap;
    }
    r->addr[r->n++] = c->addr;
    return 0;
}
```

Replace the tail of `mg_ensure_pad` (`:78-104`), from:

```c
    uint64_t base_before = mg_base_of(*pbuf, *pfsize);

    uint32_t grow_req = need_end - first;
    if (mg_grow_header(pbuf, pfsize, grow_req) != 0) {
        fprintf(stderr, "ERROR: %s: new LCs (%u bytes) don't fit in header pad (%u avail), "
                        "and the header could not be grown (see above)\n",
                label, new_lcs, pad_avail);
        return -1;
    }
    first = mg_first_sect_off(*pbuf, *pfsize);
    if (first == UINT32_MAX) {
        fprintf(stderr, "ERROR: %s: header grow produced an image that fails validation\n", label);
        return -1;
    }
    if (first == MG_NO_SECTION_DATA) {
        fprintf(stderr, "ERROR: %s: header grow left no section data to bound the pad\n", label);
        return -1;
    }
    /* spec: tests/grow_test.c test_ensure_pad_grows_and_announces */
    fflush(stdout);
    fprintf(stderr, "%s: grew the header pad by %u bytes (%u -> %u available); "
                    "image base %#llx -> %#llx\n",
            label, first - first_before, pad_avail, first - cur_lc_end,
            (unsigned long long)base_before,
            (unsigned long long)mg_base_of(*pbuf, *pfsize));
    return 0;
}
```

with:

```c
    uint64_t base_before = mg_base_of(*pbuf, *pfsize);

    struct mg_refs refs = { NULL, 0, 0, 0 };
    int64_t scanned = mhr_scan(*pbuf, *pfsize, base_before, mg_keep_ref, &refs);
    if (refs.oom) {
        fprintf(stderr, "ERROR: %s: out of memory listing code that addresses the image's "
                        "own header\n", label);
        free(refs.addr);
        return -1;
    }

    uint32_t grow_req = need_end - first;
    if (mg_grow_header(pbuf, pfsize, grow_req) != 0) {
        fprintf(stderr, "ERROR: %s: new LCs (%u bytes) don't fit in header pad (%u avail), "
                        "and the header could not be grown (see above)\n",
                label, new_lcs, pad_avail);
        free(refs.addr);
        return -1;
    }
    first = mg_first_sect_off(*pbuf, *pfsize);
    if (first == UINT32_MAX) {
        fprintf(stderr, "ERROR: %s: header grow produced an image that fails validation\n", label);
        free(refs.addr);
        return -1;
    }
    if (first == MG_NO_SECTION_DATA) {
        fprintf(stderr, "ERROR: %s: header grow left no section data to bound the pad\n", label);
        free(refs.addr);
        return -1;
    }
    uint64_t base_after = mg_base_of(*pbuf, *pfsize);
    /* spec: tests/grow_test.c test_ensure_pad_grows_and_announces */
    fflush(stdout);
    fprintf(stderr, "%s: grew the header pad by %u bytes (%u -> %u available); "
                    "image base %#llx -> %#llx\n",
            label, first - first_before, pad_avail, first - cur_lc_end,
            (unsigned long long)base_before, (unsigned long long)base_after);
    for (size_t i = 0; i < refs.n; i++)
        fprintf(stderr, "%s: warning: code at %#llx addresses the image's own header; after "
                        "this grow it points %#llx bytes past it (QUEUE item 29)\n",
                label, (unsigned long long)refs.addr[i],
                (unsigned long long)(base_before - base_after));
    if (scanned < 0)
        fprintf(stderr, "%s: warning: an instruction section lies past the end of the image, "
                        "so it was not scanned for code that addresses the image's own header\n",
                label);
    free(refs.addr);
    return 0;
}
```

In `src/grow.h`, `mg_ensure_pad`'s contract (`:105-107`), replace:

```c
 * caller held into the buffer is stale. A grow is always announced, on
 * stderr, in one line: "LABEL: grew the header pad by N bytes (A -> B
 * available); image base 0xOLD -> 0xNEW".
```

with:

```c
 * caller held into the buffer is stale. A grow is always announced, on
 * stderr, in one line: "LABEL: grew the header pad by N bytes (A -> B
 * available); image base 0xOLD -> 0xNEW". A line follows for each instruction
 * whose RIP-relative operand named the header before the grow (src/hdrref.h),
 * which the grow leaves pointing G bytes past it: "LABEL: warning: code at
 * 0xDISP32 addresses the image's own header; after this grow it points 0xG
 * bytes past it (QUEUE item 29)"; and one if an instruction section could not
 * be scanned.
```

The out-of-memory branch has no test, like the other allocation failures in `src/grow.c`.

- [ ] **Step 5: Run them to see them pass**

Run: build (rebuild check on `$B/grow_test` and `$B/drydock-macho-rewrite`), then `"$B/grow_test"` and `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`.
Expected: `macho_grow_test: all cases pass`; `grown_binary_runs_test: all passed`, including `PASS hdr: ... with exactly one warning`, `PASS hdr: ... naming its lea's disp32 (0x...) and the grow` and `PASS ctl: ... with no warning (hdr's grep, above, finds one)`. Then the whole suite (Test command): all pass. If any other suite now fails on a line containing `: warning: code at`, stop: a fixture this host builds carries a header reference, and that suite needs deliberate handling in this task (none did when this plan was written).

- [ ] **Step 6: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test` unless stated)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `for (size_t i = 0; i < refs.n; i++)` | `for (size_t i = 0; i < 0; i++)` (no warning) | `test_ensure_pad_warns_of_each_header_reference` ("0 warnings, want 2"); and `tests/grown_binary_runs_test.sh` (`FAIL hdr: warnings: 0`) |
| 2 | `r->addr[r->n++] = c->addr;` | `r->addr[r->n++] = c->off;` | `test_ensure_pad_warns_of_each_header_reference` ("one warning each, in order") |
| 3 | in `mg_keep_ref`, the last `return 0;` | `return 1;` | `test_ensure_pad_warns_of_each_header_reference` ("1 warnings, want 2") |
| 4 | `mhr_scan(*pbuf, *pfsize, base_before, mg_keep_ref, &refs);` | `mhr_scan(*pbuf, *pfsize, base_before - MG_PAGE, mg_keep_ref, &refs);` (the post-grow base) | `test_ensure_pad_warns_of_each_header_reference` ("0 warnings, want 2") |
| 5 | `if (scanned < 0)` | `if (scanned >= 0)` (a warning for the control) | `test_ensure_pad_does_not_warn_without_a_header_reference`; and `tests/grown_binary_runs_test.sh` (`FAIL ctl: warning`) |
| 6 | `(unsigned long long)(base_before - base_after));` | `(unsigned long long)(base_after - base_before));` | `test_ensure_pad_warns_of_each_header_reference` ("one warning each, in order") |
| 7 | the announcement's `fprintf` and the warning loop after it | the same two, warning loop first | `test_ensure_pad_warns_of_each_header_reference` ("... after the announcement") |
| 8 | in `mg_ensure_pad`, before `if (need_end <= first) return 0;` | insert `if (mhr_scan(*pbuf, *pfsize, mg_base_of(*pbuf, *pfsize), NULL, NULL) > 0) fprintf(stderr, "%s: warning: code at ... addresses the image's own header\n", label);` | `test_ensure_pad_fits_despite_a_header_reference` ("a fit prints nothing") |
| 9 | `if (scanned < 0)` | `if (0)` | `test_ensure_pad_warns_of_code_it_cannot_scan` |

- [ ] **Step 7: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c tests/grown_binary_runs_test.sh
git commit -m "fix(grow): warn of code a grow leaves pointing past the header

Growing lowers the image base, so the header moves down while the code
stays put, and an instruction that reaches the header by RIP-relative
distance (leaq __mh_execute_header(%rip), which getsectiondata on the
main image compiles to) then names a byte a page past it. No rebase,
bind or load command records that distance, so the grow, verify and the
plausibility check all passed a binary that segfaulted, silently.

The grow now scans every instruction section for the base it is about to
move and, after announcing itself, names each such displacement and how
far past the header it now points. It does not refuse: a fresh Claude
Code download has seven, all harmless identity keys passed to
__cxa_atexit. Repairing them is the next step.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 3: Leave absolute exports alone when the base moves

**Files:**
- Modify: `src/grow.h:63` (`#define MG_EXPORT_KIND_MASK 0x03`) and `:260` (`mg_trie_node`'s contract, the "`seen` guards" paragraph)
- Modify: `src/grow.c:612-624` (`mg_trie_node`'s terminal-payload loop) and `:1195-1196` (the comment above the trie rebuild in `mg_grow_header`)
- Modify: `src/trie.c:9` (`#define MT_EXPORT_REEXPORT`), `:147` (`b->nodes[idx].flags = flags;`), `:170-171` and `:177` (the three `+ b->shift`), `src/trie.h:36-37` (`mt_trie_rebuild`'s contract)
- Test: `tests/grow_test.c` (before `int main(void) {`; calls after Task 2's last call), `tests/trie_test.c` (before `int main(void) {` at `:390`; call after `test_rebuild_many_edges_none_dropped();` at `:401`)

**Interfaces:**
- Consumes: `build_image`'s `MG_T_TRIE` trie at `TRIE_OFF` (node A: flags at trie byte 9, address `80 20` = 0x1000 at bytes 10-11), `mg_find_trie`, `mg_snapshot_take`, `mg_verify`, `mu_decode`, `mu_encode_fixed`; `mt_trie_rebuild` (`src/trie.h`).
- Produces: `#define MG_EXPORT_KIND_ABSOLUTE 0x02` (`src/grow.h`), `MT_EXPORT_KIND_MASK` / `MT_EXPORT_KIND_ABSOLUTE` (`src/trie.c`, file-local). `mg_trie_node` neither bumps nor widen-checks an entry whose `flags & MG_EXPORT_KIND_MASK` is `MG_EXPORT_KIND_ABSOLUTE`, and collects it as its value; `mt_trie_rebuild` does not shift it.

**Plan decisions.** `mg_collect` (through `mg_trie_node`'s `out` branch) records an absolute export as its value rather than skipping it, so `mg_verify` still notices one that moves. The absolute kind applies to every address field of the entry in both walkers (dyld rejects an absolute stub-and-resolver entry, so this matters only for agreeing with each other). The `mt_trie_rebuild` test goes in `tests/trie_test.c`, that function's hermetic suite, rather than `tests/grow_test.c`.

- [ ] **Step 1: Write the failing tests**

Insert in `tests/grow_test.c`, before `int main(void) {`:

```c
/* ---- an absolute export is a value, not an offset ----
 * EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE (kind 2 under the 0x03 mask) stores the
 * symbol's value itself, so lowering the base leaves it alone; a thread-local
 * export (kind 1) is an offset from the base like a regular one. MG_T_TRIE's
 * node A keeps its flags at trie byte 9 and its address, 0x1000, at bytes
 * 10-11. */
#define MG_TRIE_A_FLAGS 9
#define MG_TRIE_A_ADDR  10
static int grow_with_node_a_flags(uint8_t flags, uint64_t *a_out) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_TRIE);
    uint32_t toff = 0, tsize = 0;
    buf[TRIE_OFF + MG_TRIE_A_FLAGS] = flags;
    *a_out = 0;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    if (r == 0 && mg_find_trie(buf, fsize, &toff, &tsize))
        mu_decode(buf + toff + MG_TRIE_A_ADDR, buf + toff + tsize, a_out);
    free(buf);
    return r;
}

static void test_grow_leaves_an_absolute_export_alone(void) {
    uint64_t a;
    int r = grow_with_node_a_flags(0x02, &a);
    CHECK(r == 0, "absolute export: the grow succeeds and verifies (got %d)", r);
    CHECK(a == 0x1000, "absolute export: its value stays 0x1000 (got %#llx)", (unsigned long long)a);
    r = grow_with_node_a_flags(0x01, &a);
    CHECK(r == 0 && a == 0x2000, "thread-local export: an offset, so it gains grow "
          "(got %d, %#llx)", r, (unsigned long long)a);
}

/* mg_collect records an absolute export as its value, so verify notices one
 * that moved. */
static void test_verify_watches_an_absolute_export(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_TRIE);
    uint32_t toff = 0, tsize = 0;
    mg_snapshot snap;
    buf[TRIE_OFF + MG_TRIE_A_FLAGS] = 0x02;
    CHECK(mg_snapshot_take(buf, fsize, &snap) == 0, "absolute export: snapshot taken");
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "absolute export: grow succeeded");
        mg_snapshot_free(&snap); free(buf); return;
    }
    if (mg_find_trie(buf, fsize, &toff, &tsize))
        mu_encode_fixed(buf + toff + MG_TRIE_A_ADDR, 0x2000, 2);
    CHECK(mg_verify(buf, fsize, &snap) == -1, "verify REJECTS an absolute export that moved");
    mg_snapshot_free(&snap);
    free(buf);
}
```

And after `    test_ensure_pad_fits_despite_a_header_reference();` in `main`:

```c
    test_grow_leaves_an_absolute_export_alone();
    test_verify_watches_an_absolute_export();
```

Insert in `tests/trie_test.c`, before `int main(void) {` (`:390`):

```c
/* ---- an absolute export holds a value, not an offset: never shifted ----
 * root: two children "A"->8, "B"->13. A: flags at byte 9, value 0x1000
 * (80 20) at bytes 10-11. B: flags 0, address 0x1000. After a 0x1000 shift B
 * is 0x2000 (80 40), still two bytes, and A is unshifted when its kind is
 * EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE (2) and shifted when it is
 * THREAD_LOCAL (1). */
static void check_rebuild_node_a_kind(uint8_t flags, uint8_t want_a_hi, const char *what) {
    uint8_t in[] = {
        0x00, 0x02, 'A', 0x00, 8, 'B', 0x00, 13,
        0x03, 0x00, 0x80, 0x20, 0x00,
        0x03, 0x00, 0x80, 0x20, 0x00,
    };
    uint8_t want[sizeof in];
    uint8_t *out = NULL; uint32_t osz = 0;
    in[9] = flags;
    memcpy(want, in, sizeof in);
    want[11] = want_a_hi;
    want[16] = 0x40;
    int r = mt_trie_rebuild(in, sizeof in, 0x1000, &out, &osz);
    CHECK(r == 0, "%s: rebuild succeeds (got %d)", what, r);
    if (r != 0) return;
    CHECK(osz == sizeof want && memcmp(out, want, sizeof want) == 0,
          "%s: node A's second address byte is %#x, want %#x", what,
          osz > 11 ? out[11] : 0, want_a_hi);
    free(out);
}

static void test_rebuild_absolute_export_untouched(void) {
    check_rebuild_node_a_kind(0x02, 0x20, "absolute export");
    check_rebuild_node_a_kind(0x01, 0x40, "thread-local export");
    /* absolute with STUB_AND_RESOLVER (0x12): neither field shifts */
    static const uint8_t sr[] = { 0x03, 0x12, 0x10, 0x20, 0x00 };
    uint8_t *out = NULL; uint32_t osz = 0;
    int r = mt_trie_rebuild(sr, sizeof sr, 0x30, &out, &osz);
    CHECK(r == 0 && osz == sizeof sr && memcmp(out, sr, sizeof sr) == 0,
          "absolute stub-and-resolver: both fields unshifted (got %d, %u bytes)", r, osz);
    free(out);
}
```

And after `    test_rebuild_many_edges_none_dropped();` (`:401`):

```c
    test_rebuild_absolute_export_untouched();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check on `$B/grow_test` and `$B/trie_test`), then `"$B/grow_test"` and `"$B/trie_test"`.
Expected: `grow_test` exits 1 with exactly

```
FAIL: absolute export: its value stays 0x1000 (got 0x2000)
FAIL: verify REJECTS an absolute export that moved
```

and `trie_test` exits 1 with exactly

```
FAIL: absolute export: node A's second address byte is 0x40, want 0x20
FAIL: absolute stub-and-resolver: both fields unshifted (got 0, 5 bytes)
```

(The thread-local halves pass already; they pin that only kind 2 is exempt.)

- [ ] **Step 3: Implement it in `src/grow.h` and `src/grow.c`**

`src/grow.h:63`, replace:

```c
#define MG_EXPORT_KIND_MASK        0x03
```

with:

```c
#define MG_EXPORT_KIND_MASK        0x03
#define MG_EXPORT_KIND_ABSOLUTE    0x02
```

`src/grow.h:260`, `mg_trie_node`'s contract, replace:

```c
 * `seen` guards a shared subtree from being bumped twice
```

with:

```c
 * An EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE entry holds the symbol's value, not an
 * offset from the base, so it is never bumped. It is collected as that value,
 * so verify still sees it move if something moves it.
 *
 * `seen` guards a shared subtree from being bumped twice
```

`src/grow.c:612-613`, replace:

```c
        if (!(flags & MG_EXPORT_REEXPORT)) {          /* re-exports carry no address */
            int rounds = (flags & MG_EXPORT_STUB_AND_RESOLVER) ? 2 : 1;
```

with:

```c
        if (!(flags & MG_EXPORT_REEXPORT)) {          /* re-exports carry no address */
            int absolute = (flags & MG_EXPORT_KIND_MASK) == MG_EXPORT_KIND_ABSOLUTE;
            int rounds = (flags & MG_EXPORT_STUB_AND_RESOLVER) ? 2 : 1;
```

`src/grow.c:621-622`, replace:

```c
                        out[(*n)++] = base + a;
                    } else {
```

with:

```c
                        out[(*n)++] = absolute ? a : base + a;
                    } else if (!absolute) {
```

`src/grow.c:1195-1196`, replace:

```c
     * REBUILD it instead: decode the whole thing, add `grow` to every
     * nonzero address, and
```

with:

```c
     * REBUILD it instead: decode the whole thing, add `grow` to every
     * nonzero offset from the base, and
```

- [ ] **Step 4: Implement it in `src/trie.c` and `src/trie.h`**

`src/trie.c:9`, replace:

```c
#define MT_EXPORT_REEXPORT          0x08
```

with:

```c
#define MT_EXPORT_KIND_MASK         0x03
#define MT_EXPORT_KIND_ABSOLUTE     0x02
#define MT_EXPORT_REEXPORT          0x08
```

`src/trie.c:147`, replace:

```c
        b->nodes[idx].flags = flags;
```

with:

```c
        b->nodes[idx].flags = flags;
        uint64_t shift = (flags & MT_EXPORT_KIND_MASK) == MT_EXPORT_KIND_ABSOLUTE ? 0 : b->shift;
```

`src/trie.c:170-171`, replace:

```c
            b->nodes[idx].a1 = stub ? stub + b->shift : 0;
            b->nodes[idx].a2 = resolver ? resolver + b->shift : 0;
```

with:

```c
            b->nodes[idx].a1 = stub ? stub + shift : 0;
            b->nodes[idx].a2 = resolver ? resolver + shift : 0;
```

`src/trie.c:177`, replace:

```c
            b->nodes[idx].a1 = addr ? addr + b->shift : 0;
```

with:

```c
            b->nodes[idx].a1 = addr ? addr + shift : 0;
```

`src/trie.h:36-37`, replace:

```c
/* Rebuild the export trie at trie[0..size). Every exported address (nonzero)
 * gains `shift`; address 0 is left as 0
```

with:

```c
/* Rebuild the export trie at trie[0..size). Every exported address (nonzero)
 * gains `shift`, except an EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE entry's, which is
 * a value, not an offset; address 0 is left as 0
```

- [ ] **Step 5: Run them to see them pass**

Run: build (rebuild check on `$B/grow_test` and `$B/trie_test`), then `"$B/grow_test"` and `"$B/trie_test"`.
Expected: `macho_grow_test: all cases pass` and `ALL PASS`. Then the whole suite (Test command): all pass.

- [ ] **Step 6: Mutation proof** (test binary `$B/grow_test` for `src/grow.c`, `$B/trie_test` for `src/trie.c`)

| # | file | replace | with | must fail |
|---|---|---|---|---|
| 1 | `src/grow.c` | `int absolute = (flags & MG_EXPORT_KIND_MASK) == MG_EXPORT_KIND_ABSOLUTE;` | `int absolute = 0;` | `test_grow_leaves_an_absolute_export_alone` ("its value stays 0x1000") |
| 2 | `src/grow.c` | `out[(*n)++] = absolute ? a : base + a;` | `out[(*n)++] = base + a;` | `test_grow_leaves_an_absolute_export_alone` ("the grow succeeds and verifies") |
| 3 | `src/grow.c` | `} else if (!absolute) {` | `} else {` | `test_grow_leaves_an_absolute_export_alone` ("the grow succeeds and verifies") |
| 4 | `src/grow.c` | `int absolute = (flags & MG_EXPORT_KIND_MASK) == MG_EXPORT_KIND_ABSOLUTE;` | `int absolute = (flags & MG_EXPORT_KIND_MASK) != 0;` | `test_grow_leaves_an_absolute_export_alone` ("thread-local export: an offset") |
| 5 | `src/grow.c` | `out[(*n)++] = absolute ? a : base + a;` | `if (!absolute) out[(*n)++] = base + a;` | `test_verify_watches_an_absolute_export` |
| 6 | `src/trie.c` | `uint64_t shift = (flags & MT_EXPORT_KIND_MASK) == MT_EXPORT_KIND_ABSOLUTE ? 0 : b->shift;` | `uint64_t shift = b->shift;` | `test_rebuild_absolute_export_untouched` ("absolute export") |
| 7 | `src/trie.c` | the same line | `uint64_t shift = (flags & MT_EXPORT_KIND_MASK) ? 0 : b->shift;` | `test_rebuild_absolute_export_untouched` ("thread-local export") |
| 8 | `src/trie.c` | `b->nodes[idx].a1 = stub ? stub + shift : 0;` | `b->nodes[idx].a1 = stub ? stub + b->shift : 0;` | `test_rebuild_absolute_export_untouched` ("absolute stub-and-resolver") |

- [ ] **Step 7: Commit**

```bash
git add src/grow.c src/grow.h src/trie.c src/trie.h tests/grow_test.c tests/trie_test.c
git commit -m "fix(grow): leave absolute exports alone when the base moves

An export trie entry of kind EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE holds the
symbol's value, not an offset from the image base, but both the in-place
walker and the rebuild added the grow to it, and mg_collect expected it to
move, so verify passed the corruption. Both walkers now leave it alone,
and mg_collect records it as its value, so verify catches one that moves.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 4: Leave an empty function-starts list alone

**Files:**
- Modify: `src/grow.c:109-110` (`mg_reencode_funcstarts_base`), `:230-232` (`mg_collect_cb`'s `LC_FUNCTION_STARTS` branch), `:1164` (the width pre-check in `mg_grow_header`)
- Modify: `src/grow.h:128-133` (`mg_reencode_funcstarts_base`'s contract)
- Test: `tests/grow_test.c` (before `int main(void) {`; calls after Task 3's last call)

**Interfaces:**
- Consumes: `build_image`'s `MG_T_FUNCSTARTS` (a 5-byte blob at `FS_OFF` = 7680), `find_lc`, `mg_reencode_funcstarts_base`.
- Produces: `mg_reencode_funcstarts_base` returns 1 and leaves the blob unchanged when its leading ULEB is 0; `mg_grow_header` neither refuses such a list for width nor collects its leading 0.

**Plan decision.** `mg_collect` skips an empty list's leading 0 as well. The spec names only the re-encode and the width check, but `mg_collect` records the leading delta as `base + d0`, and base + 0 moves with the base, so without this every grow of such an image fails its own verify.

- [ ] **Step 1: Write the failing tests**

Insert in `tests/grow_test.c`, before `int main(void) {`:

```c
/* ---- an empty function-starts list ----
 * A leading ULEB of 0 is the terminator, so the list names no function; a
 * codeless umbrella framework's is eight zero bytes. There is no leading
 * delta to re-base, so the list is left alone, and it cannot widen. */
static void test_reencode_leaves_an_empty_list_alone(void) {
    static const uint8_t zero[8] = { 0 };
    uint8_t blob[8] = { 0 };
    int r = mg_reencode_funcstarts_base(blob, sizeof blob, 0x1000);
    CHECK(r == 1, "an empty list: nothing to re-encode, so done (got %d)", r);
    CHECK(memcmp(blob, zero, sizeof blob) == 0, "an empty list: its terminator stays a terminator");
}

static void test_grow_leaves_an_empty_function_starts_list_alone(void) {
    static const uint8_t zero[5] = { 0 };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_FUNCSTARTS);
    memset(buf + FS_OFF, 0, sizeof zero);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "an empty function-starts list: the grow succeeds (got %d)", r);
    if (r == 0) {
        const struct linkedit_data_command *fs =
            (const struct linkedit_data_command *)find_lc(buf, fsize, LC_FUNCTION_STARTS);
        CHECK(fs && fs->dataoff == FS_OFF + 0x1000 &&
              memcmp(buf + fs->dataoff, zero, sizeof zero) == 0,
              "an empty function-starts list: moved with the file, and still empty");
    }
    free(buf);
}
```

And after `    test_verify_watches_an_absolute_export();` in `main`:

```c
    test_reencode_leaves_an_empty_list_alone();
    test_grow_leaves_an_empty_function_starts_list_alone();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check on `$B/grow_test`), then `"$B/grow_test"`.
Expected: exit 1 with exactly

```
FAIL: an empty list: nothing to re-encode, so done (got 0)
FAIL: an empty function-starts list: the grow succeeds (got -1)
```

and on stderr `ERROR: grow of 4096 would widen the LC_FUNCTION_STARTS leading delta (0 -> 4096 crosses a ULEB byte boundary); ...`: the refusal this task removes.

- [ ] **Step 3: Implement it**

`src/grow.c:109-110` (`mg_reencode_funcstarts_base`), replace:

```c
    if (n0 == 0) return -1;
    uint64_t nd = d0 + grow;
```

with:

```c
    if (n0 == 0) return -1;
    if (d0 == 0) return 1;
    uint64_t nd = d0 + grow;
```

`src/grow.c:230-232` (`mg_collect_cb`), replace:

```c
                return -1;
            if (ctx->n >= ctx->max) return -1;
            if (ctx->kinds) ctx->kinds[ctx->n] = MG_K_FUNC;   /* the first function's address */
```

with:

```c
                return -1;
            if (d0 == 0) return 0;
            if (ctx->n >= ctx->max) return -1;
            if (ctx->kinds) ctx->kinds[ctx->n] = MG_K_FUNC;   /* the first function's address */
```

`src/grow.c:1164`, replace:

```c
        if (mu_minlen(d0 + grow) > n0) {
```

with:

```c
        if (d0 != 0 && mu_minlen(d0 + grow) > n0) {
```

`src/grow.h:130-133`, replace:

```c
 * width so blob size is unchanged and the trailing deltas are untouched.
 * Returns: 1 patched in place; 0 the widened delta needs more bytes than the
 * original leading encoding (caller must refuse — LINKEDIT resize unsupported);
 * -1 malformed blob (empty / bad leading ULEB). */
```

with:

```c
 * width so blob size is unchanged and the trailing deltas are untouched. A
 * leading 0 is the terminator of an empty list, which is left alone.
 * Returns: 1 patched in place, or an empty list; 0 the widened delta needs
 * more bytes than the original leading encoding (caller must refuse —
 * LINKEDIT resize unsupported); -1 malformed blob (empty / bad leading ULEB). */
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check on `$B/grow_test`), then `"$B/grow_test"`.
Expected: `macho_grow_test: all cases pass`. Then the whole suite (Test command): all pass.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `if (d0 == 0) return 1;` | (delete it) | `test_reencode_leaves_an_empty_list_alone` |
| 2 | `if (d0 != 0 && mu_minlen(d0 + grow) > n0) {` | `if (mu_minlen(d0 + grow) > n0) {` | `test_grow_leaves_an_empty_function_starts_list_alone` |
| 3 | `if (d0 == 0) return 0;` | (delete it) | `test_grow_leaves_an_empty_function_starts_list_alone` (verify: entry moved by -4096) |

- [ ] **Step 6: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c
git commit -m "fix(grow): leave an empty function-starts list alone

A function-starts blob whose leading ULEB is 0 lists no function: the 0
is its terminator. The grow read it as a leading delta, so it refused
the list for width (0 + 4096 needs two bytes), and had it not, it would
have turned the terminator into a delta naming a function that is not
there. Codeless umbrella frameworks carry exactly this list.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 5: Documentation, QUEUE item 29, and a local check on Claude Code

**Files:**
- Modify: `compat/README.md:150-151` (the "A header pad too short ... is grown" bullet, which quotes a grow's announcement)
- Modify: `docs/superpowers/QUEUE.md:35` (item 29's table row), after `:1459-1460` (item 29's "Fix")

**Interfaces:**
- Consumes: Task 2's commit (the one whose subject starts `fix(grow): warn of code a grow leaves pointing past the header`).
- Produces: nothing code depends on.

`README.md` has no paragraph on a grow's output, and `compat/README.md`'s other mentions (row 6 of the `fix_macho` table, the `change_dylib` table) say only that a grow is "announced", without quoting it; they stay as they are. QUEUE item 29's "Reach" already records the Claude Code measurement (`bfb5cb6`).

- [ ] **Step 1: Find Task 2's commit**

Run: `C=$(git log -1 --format=%h --grep='^fix(grow): warn of code a grow leaves pointing past the header'); echo "$C"`
Expected: one short hash. It replaces `$C` in the two QUEUE edits below.

- [ ] **Step 2: `compat/README.md`**

Replace (`:150-151`):

```markdown
    room, announces it on stderr ("FILE: grew the header pad by N bytes
    ..."), and exits 0; anything else is still refused. The repo owner's
```

with:

```markdown
    room, announces it on stderr ("FILE: grew the header pad by N bytes
    ..."), and exits 0; anything else is still refused. When the
    executable's code takes its own header's address RIP-relatively, which
    lowering the base breaks, one more line follows for each such
    instruction: "FILE: warning: code at 0x... addresses the image's own
    header; after this grow it points 0x1000 bytes past it (QUEUE item 29)"
    (`tests/grown_binary_runs_test.sh`, "hdr"). The repo owner's
```

- [ ] **Step 3: `docs/superpowers/QUEUE.md`**

Item 29's table row (`:35`), replace:

```markdown
| `specs/2026-09-25-dylib-header-growth-design.md` (the fix is shared with the dylib route) | — | **bug, found 2026-09-25**, reproduced; see below |
```

with (`$C` from Step 1):

```markdown
| `specs/2026-09-25-dylib-header-growth-design.md` (the fix is shared with the dylib route) | `plans/2026-09-25-header-references-m0.md` (M0) | **stop-gap done**: warned since `$C`; repair is M1; see below |
```

At the end of item 29's "Fix" paragraph (`:1459-1460`), replace:

```markdown
the displacement or refuse. The decision and its design live in the
dylib-growth spec.
```

with (`$C` from Step 1):

```markdown
the displacement or refuse. The decision and its design live in the
dylib-growth spec.

**Stop-gap done** (M0): warned since `$C`; repair is M1. A grow now names,
on stderr, each instruction that addresses the image's own header; a
fresh Claude Code download grows with seven such warnings.
```

If any of these passages has changed since this plan was written, make the equivalent edit and say so in the commit message.

- [ ] **Step 4: Check the docs and the tree**

Run each; every negative has its positive control first:

```sh
git grep -c 'QUEUE item 29)' -- compat/README.md                           # expect 1
git grep -n 'warned since' -- docs/superpowers/QUEUE.md                    # expect two lines naming $C
git grep -c 'bug, found 2026-09-25\*\*, reproduced' HEAD -- docs/superpowers/QUEUE.md   # positive control: expect 2 (items 29 and 30, committed)
git grep -c 'bug, found 2026-09-25\*\*, reproduced' -- docs/superpowers/QUEUE.md        # expect 1 (item 30 only)
git grep -c -E 'superpowers|specs/|plans/' -- docs/superpowers/QUEUE.md    # positive control: expect > 0
rc=0; git grep -n -E 'superpowers|specs/|plans/' -- src tests CMakeLists.txt || rc=$?; echo "rc=$rc"   # expect rc=1
```

(The warning's `(QUEUE item 29)` is the spec's wording, and names a queue item, not a plan or spec file; M1 removes the warning.)

- [ ] **Step 5: Local check: an installed Claude Code copy grows with no warning**

The installed copy is already grown (base `0xfffff000`), so its seven header references name the old base, and a scan for the current base finds none: it must grow with no warning. A fresh download, with its base at `0x100000000`, grows with seven; this host has none to check. The step SKIPs where Claude Code is absent.

```sh
C_BIN=$(python3 -c "import os;print(os.path.realpath(os.path.expanduser('~/.local/bin/claude')))" 2>/dev/null)
S=$(mktemp -d)
if [ -f "$C_BIN" ]; then
    printf 'rpath append /nonexistent/%s\n' "$(printf '%06000d' 0)" >"$S/edits"
    cp "$C_BIN" "$S/claude.in"
    rc=0; "$B/drydock-macho-rewrite" "$S/claude.in" "$S/claude.out" <"$S/edits" >/dev/null 2>"$S/err" || rc=$?
    echo "rc=$rc"; grep -E 'grew the header pad|: warning: |ERROR' "$S/err"
else
    echo "SKIP: no Claude Code at ~/.local/bin/claude"
fi
rm -rf "$S"
```

Expected (2.1.282, measured writing this plan): `rc=0` and exactly one line, `...claude.in: grew the header pad by 4096 bytes (3976 -> 8072 available); image base 0xfffff000 -> 0xffffe000`. A `: warning: code at` line here would mean the installed copy has a reference to its current base: report it.

- [ ] **Step 6: Commit**

```bash
git add compat/README.md docs/superpowers/QUEUE.md
git commit -m "docs: a grow warns of code that addresses its own header; item 29's stop-gap

compat/README.md, where it quotes a grow's announcement, now gives the
warning line that follows it for each such instruction. QUEUE item 29 is
marked: warned since $C, repaired in M1.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

(Expand `$C` before committing: write the message with the hash in it, e.g. through `git commit -F` from a file you filled in.)

---

## Self-review

**1. Spec coverage.**

| M0 requirement (spec) | task |
|---|---|
| Decision 3's scan: every `S_ATTR_PURE_INSTRUCTIONS` / `S_ATTR_SOME_INSTRUCTIONS` section, every byte, ModRM `(b & 0xC7) == 0x05`, disp32, immediate 0/1/2/4, target exactly the base (the vmaddr of the segment with `fileoff` 0 and `filesize` > 0: `mi_text_base`, as `mg_patch_cb` identifies it) | 1 |
| The M0 warning on the executable route (spec, `8059a1f`): the grow proceeds, and each candidate gets one stderr line beside the grow's announcement, in the spec's form | 2 |
| Export-trie `KIND_ABSOLUTE` unchanged, in `mg_trie_node` and `mt_trie_rebuild`, and `mg_collect` not expecting it to move | 3 |
| A leading function-starts delta of 0 is an empty list: `mg_reencode_funcstarts_base` and the width pre-check leave it alone | 4 |
| Testing: "the scan finds every form (all four immediate lengths), and never misses a planted reference" | 1 |
| Testing: "item 29's reproduction grows with the warning; its control grows silently and runs" | 2 |
| Testing: "`KIND_ABSOLUTE` exports and a leading-zero function-starts list are left alone" | 3, 4 |
| Testing: "the executable route is byte-for-byte unchanged on every existing grow fixture without header references" | every task's full-suite run; also checked once while writing this plan (a 6000-byte `rpath append` on `ctl`, `tests/fixture.macho` and `/usr/bin/printf`, before and after these changes: byte-identical outputs) |

Nothing in M0 is left without a task. M1–M3 are not started: no patching, no decoder, no raise route, no refusal.

**2. Placeholder scan.** No "TBD", "similar to Task N" or undescribed step. `$C` in Task 5 is computed by Step 1's command. `<authoring model>` is the trailer's own wording, which the executor fills in.

**3. Type and name consistency.** `mhr_cand {addr, off, immlen}`, `mhr_fn`, `mhr_scan_code` (returns `uint64_t`) and `mhr_scan` (returns `int64_t`) are defined in Task 1 and used with those names and types in Task 2 (`mg_keep_ref`, `struct mg_refs`, `scanned`) and the mutation tables. `hr_plant`, `HR_BASE`, `hr_record`, `struct hr_seen` are Task 1's test helpers, reused by Task 2's `plant_header_refs`; Task 2's `ensure_pad_stderr` and `count_of` are its own. `MG_EXPORT_KIND_ABSOLUTE` (`src/grow.h`) and `MT_EXPORT_KIND_ABSOLUTE` (`src/trie.c`) are both 0x02 under a 0x03 mask. Each task's `main` calls go after the previous task's last call, and each anchor line exists by then.

**4. Review Focus.** Five inputs the spec implies and no requirement names: an edit that fits the pad (Task 2), a thread-local export (Task 3), a lookalike operand (Task 1), a header address in data (Task 1), several references (Task 2). Each has its test in the owning task.

**What the spec leaves open for M0, decided here:** where the warning is printed (Task 2: `mg_ensure_pad`, from a scan made before the grow); what happens to code that cannot be scanned (Task 2: its own warning, no refusal); which suite holds the `mt_trie_rebuild` test (Task 3: `tests/trie_test.c`, where the spec's table says `tests/grow_test.c`).
