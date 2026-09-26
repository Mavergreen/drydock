# Output that 10.9's `codesign` can re-sign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every file Drydock writes can be re-signed by 10.9's own `codesign`, and none is one that any `codesign` would re-sign corrupt: a run that changes `__LINKEDIT` packs it into the order 10.9's `codesign_allocate` requires, `info` says whether the file will re-sign, and an output the tool would silently corrupt is refused.

**Architecture:** A new module, `src/linkedit_order.[ch]` (`mlo_`), holds a pure verifier, `mlo_check`. It mirrors cctools-862's load-command loop, `check_object`, `dyld_order`, `symbol_string_at_end` and header-room check rule for rule, keeps every finding, and simulates `codesign_allocate`'s writer to find a file it would accept and then corrupt. `mlo_file_verdict` turns that into one line for a whole (thin or fat) file, which `info` prints. `src/linkedit_pack.c` adds `mlo_pack`, which rewrites a slice's `__LINKEDIT` into ld64's order, and `mlo_changed`, which tells whether a run changed a piece. `src/edit.c` calls the pack once per slice after the last statement when the run changed a piece or the output would re-sign corrupt, and refuses a write that would still re-sign corrupt. A hand-built fixture, `tests/linkedit_fixture.h`, lays out one dylib in 48 ways; each variant's verdict is what 10.9's tool says of it, and `tests/codesign_order_test.sh` checks that against the real tool on 10.9.

**Tech Stack:** C as the 10.9 clang (Apple LLVM 6.0) accepts it; CMake through shipyard; POSIX `sh`; hand-built Mach-O fixtures, the same bytes on every host; 10.9's `codesign_allocate` (cctools-862) as the oracle, run locally.

**Spec:** `docs/superpowers/specs/2026-09-26-classic-fixups-re-signable-design.md` (at `6250617`). Read its "Why" (the rules, the writer's assumption, fat files), its Decisions 1–9 and its "Tests and compat output this changes" table. Where this plan and the spec differ, the spec's "(plan)" notes are the reconciliation.

## Global Constraints

- **Line numbers** are at `6250617`, `main` when this plan was written. Every edit quotes the text it anchors on, and that text is what to match; `src/edit.c`'s and `tests/cli_test.sh`'s line numbers drift from task to task.
- **Build:** `B=/private/tmp/build/schmonz/drydock-native`; `/usr/local/mavergreen/bin/shipyard-cmake --build "$B" -j`. Do not configure with `--preset`. **After editing `CMakeLists.txt`, re-run the configure step** before building (on this host a clock skew can let ninja miss the change): `/usr/local/mavergreen/bin/shipyard-cmake -S . -B "$B" -G Ninja -DCMAKE_TOOLCHAIN_FILE=/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/MavericksToolchain.cmake -DMAVERICKS_EXPECTED_MODE=native -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64`.
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavergreen/bin/shipyard-ctest --test-dir "$B"`, from the repo root. At `6250617` the suite has 27 tests (`chained_fixups` SKIPs). Task 1 makes it 28 (`linkedit_order_test`) and Task 5 makes it 29 (`codesign_order_test`, which SKIPs everywhere but 10.9). Single tests: `"$B/linkedit_order_test"` (run it from the repo root: it reads `tests/fixture.macho`), and `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B"`.
- **Rebuild check (clock skew here; `touch` can fail to relink).** "Build (rebuild check)" below means exactly:
  ```sh
  find "$B/CMakeFiles" -name '*.o' -exec rm {} +
  rm -f "$B/libdrydockcore.a" "$B/drydock-macho-rewrite" "$B/linkedit_order_test" "$B/mklinkedit"
  pre=$(cat "$B/.last-sha" 2>/dev/null)
  /usr/local/mavergreen/bin/shipyard-cmake --build "$B" -j
  shasum -a 256 "$B/drydock-macho-rewrite" "$B/linkedit_order_test" 2>/dev/null | tee "$B/.last-sha"
  ```
  Then confirm the sums changed from `$pre`. A test result against an unchanged binary is not a result. For a mutation, deleting the mutated file's own object, `libdrydockcore.a` and the binaries is enough (no header is mutated); confirm that object's `shasum` changed.
- **TDD and mutation proof** for every task: write the test first and see it fail as the step says; then the code; then apply every row of the task's mutation list, each alone, rebuild (rebuild check), and see it fail the named test with the quoted text. Mutate only a saved copy's original: `M=$(mktemp -d -t lkorder); cp FILE "$M/"` (10.9's `mktemp -d` needs a template), edit, rebuild, run, then `cp "$M/$(basename FILE)" FILE && cmp FILE "$M/$(basename FILE)"`, and rebuild. **Never `git stash` and never `git checkout --`**: restore only from the saved copy. A mutation that no test kills is a finding: add the test that kills it, in the same task.
- **Comments are a last resort:** prefer a test, then the commit message, then a doc, then one inline sentence. No history narration, and no reference to a plan or spec from source (both are deleted once implemented).
- **Exit codes:** `EX_REFUSED` = 1 (`MR_REFUSED`), `EX_FAIL` = 2 (`MR_FAIL`). A parse error is 2. A statement never writes its input, and nothing is written on a refusal.
- **Every grep negative needs a positive control.** In shell suites, `rc=0; cmd || rc=$?`.
- **char[16] names:** print with `%.16s`, compare with `strncmp(..., 16)`.
- **Staging and pushing:** stage explicit paths only (never `git add -A` or `.`); commit on `main`; do not push. Every commit message ends with:
  ```
  Co-Authored-By: <authoring model> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
  ```
- **CI runs on `macos-26-arm64`.** Every fixture here is hand-built bytes (`tests/linkedit_fixture.h`, `tests/mkchained.c`, `tests/mkrelmeth.c`), the same on every host, so `linkedit_order_test` and the `cli_test` blocks mean the same there. `codesign_order_test` SKIPs there (it needs cctools-862). **A milestone does not close until `codesign_order_test` has run, not skipped, on the 10.9 host**: Tasks 5, 8, 9 and 11 each end by running it.

## Review Focus

1. **A file the tool would accept and then corrupt.** The worst outcome: `codesign -v` passes and the fixup opcodes are wrong. Pinned by Task 3's `hole-16`, `hole-16-unsigned`, `nsyms-0` and `nsyms-0-short-strtab` variants (`corrupting`), Task 7's "one it cannot repair is refused", Task 8's "an unselected slice that would re-sign corrupt refuses the run", and the oracle's byte comparison after the real tool (Task 5).
2. **An image already in order must come out byte-identical.** Every clang- or ld64-built input is in order; moving its bytes would break every byte-identity test and the compat wrappers' outputs. Pinned by Task 6's "unchanged" test (the canonical variants and `tests/fixture.macho`, which `tests/EXPECTED` depends on) and Task 7's "on an image already in order, nothing is said".
3. **A run that touches only the header of a still-chained image must say nothing new** (N5 of the spec's review): pinned by Task 7's "an edit of a chained image says nothing new".
4. **A slice nobody selected.** `codesign_allocate` checks every slice; Task 4's fat `info` tests and Task 8's refusal and report tests pin it.
5. **Zero-size pieces.** A stale offset on an empty stream fails rule 1; an empty `LC_DATA_IN_CODE` at 0 must stay at 0. Pinned by Task 1's `stale-empty-rebase`, `dic-at-0` and `no-rebase-bind-late`, and Task 6's "places empty pieces".

## Plan decisions at a glance

Each is repeated, with its reason, in the task that makes it.

- The findings are texts in `codesign_allocate`'s own words, with "…" for words that name offsets or files, so the oracle can compare them with the tool's stderr (Task 1).
- A refusal about where the pieces lie is marked `order`, so the pass's postcondition can require every such rule to pass while leaving refusals it cannot cure (Task 1).
- The simulation compares bytes, not positions: a piece survives when the output the writer would build holds its bytes where its load command says. That is exactly what the oracle compares (Task 3).
- `mlo_file_verdict` is the one whole-file verdict; `info` and the edit run both use it (Tasks 3, 4, 7).
- The pass is its own file, `src/linkedit_pack.c`, beside `src/linkedit_order.c`, sharing `linkedit_order.h` (Task 6).
- The pass runs on observed change, not on the script table's declared mask, so no `MS_TABLE_ROWS` row changes (Task 7; spec Decision 4).
- The report lines use the input path, as every other report line of a run does (Task 7).
- The lowering's 8-padding lands in Task 9, beside the tests that pin the lowering end to end (spec Decision 8, folded into M2 as the review asked).

## File structure

| file | responsibility | tasks |
|---|---|---|
| `src/linkedit_order.h` | the verdict types; `mlo_check`, `mlo_file_verdict` (3); `mlo_pack`, `mlo_changed` (6) | 1, 3, 6 |
| `src/linkedit_order.c` | findings; `check_object`, `dyld_order` (1); the load-command loop, `symbol_string_at_end`, header room (2); the writer simulation, the whole-file verdict (3) | 1–3 |
| `src/linkedit_pack.c` | the piece model, `mlo_pack`, `mlo_changed` | 6 |
| `src/edit.c` | `me_pack`, `me_resign`, the thin run (7); the fat run (8) | 7, 8 |
| `src/declassify.c` | the lowering pads its two streams to 8 | 9 |
| `cli/drydock-macho-rewrite.c` | `info`'s `resign 10.9:` and `resign corrupt:` lines | 4 |
| `tests/linkedit_fixture.h` | the hand-built dylib and its 48 variants | 1, 2, 3, 7 |
| `tests/linkedit_order_test.c` | `mlo_check`, `mlo_file_verdict`, `mlo_pack`, `mlo_changed` on the variants | 1, 2, 3, 6, 7 |
| `tests/mklinkedit.c` | writes a variant to a file; lists the variants; lists a file's pieces apart from `src/` | 4 |
| `tests/codesign_order_test.sh` | the oracle: `info` against 10.9's `codesign_allocate`, byte for byte | 5 |
| `tests/cli_test.sh` | `info` (4); the thin run (7); the fat run (8); the lowering and objc-methods (9) | 4, 7–9 |
| `tests/import_redirect_test.sh` | the grown bind stream is packed back | 7 |
| `tests/mkchained.c`, `tests/relmeth_fixture.h`, `tests/mkrelmeth.c` | `make-signable`; the `dysymtab` variant | 9 |
| `CMakeLists.txt` | the two sources, `linkedit_order_test`, `mklinkedit`, `codesign_order_test` | 1, 5, 6 |
| `README.md`, `compat/README.md`, `compat/bake-mavericks-shim.sh`, `docs/codesign-order.md`, the objc-methods spec | the words | 10 |
| `docs/superpowers/QUEUE.md` | item 30 closed | 11 |

`src/grow.c`, `src/grow.h`, `src/trie.c`, `tests/grow_test.c` and `tests/grown_binary_runs_test.sh` are **not edited**. See "The other plan", below.

## The other plan: `2026-09-26-header-data-pointers.md` runs after this one

That plan (`462fc5a`) edits `src/grow.[ch]`, `tests/grow_test.c`, `tests/grown_binary_runs_test.sh`, `compat/README.md:151-158`, `docs/superpowers/QUEUE.md:35` and `:1473-1488`, and the dylib-growth spec. This plan edits none of `src/grow.[ch]`, `src/trie.c` or the grow tests, so no line that plan cites in them moves. Its `compat/README.md` lines are above this plan's insertion (Task 10 inserts before `## \`insert_dylib\``, near line 702), and this plan's `QUEUE.md` edits (Task 11) are row 36 and item 30's section after line 1490, so `:35` and `:1473-1488` do not move either.

**What does change for it:** after this plan, a CLI run that changes `__LINKEDIT` also packs it. Its Task 5 sweep deletes a signature on each signed input, so every such output is now packed, and its baseline figures (the 1,046/82 exit counts, "every other output is byte-identical", Claude Code "byte-identical to `88e846f`'s") were measured at `88e846f`. Re-measure its "before" at this plan's last commit rather than at `88e846f`.

## How this plan was checked

- Every task's code was built first as a checkpoint in a scratch `git archive` of `43e3aec` (source identical to `6250617`): ten commits, one per code task, each built after deleting every object and reconfiguring, and each passing the whole ctest suite: 28 tests at Tasks 1–4, 29 from Task 5 on, `chained_fixups` skipped, `codesign_order_test` run (not skipped) from Task 5 on.
- **Every edit block below was cut from those checkpoints by a script**, and a second script applied this plan's own `Create`/`replace … with` blocks, in order, to a fresh archive and compared the result with each checkpoint: identical at every task.
- Every "Run it to see it fail" step was run as written, on the previous checkpoint plus that task's test edits; the expected output quoted is what it printed.
- Every row of every mutation list (80 rows: 15, 13, 11, 4, 3, 19, 9, 4 and 2 in Tasks 1–9) was applied alone to that task's checkpoint, rebuilt with the rebuild check, confirmed to change the mutated object, run, and seen to fail the named test with the quoted text; then restored and confirmed byte-identical.
- The real binaries in Task 11 were run through the finished build on this host; the figures quoted there are that run's.

---

### Task 1: The verifier: `check_object` and `dyld_order` (M1)

**Files:**
- Create: `src/linkedit_order.h`, `src/linkedit_order.c`, `tests/linkedit_fixture.h`, `tests/linkedit_order_test.c`
- Modify: `CMakeLists.txt` (`add_library(drydockcore …)` at `:66`; a new test block before `add_executable(relations_test tests/relations_test.c)`)

**Interfaces:**
- Consumes: `mi_image`, `mi_wrap`, `mi_each_lc` (`src/image.h`).
- Produces (later tasks use them):
  - `enum { MLO_REFUSES = 1, MLO_CORRUPTS, MLO_NOTE };`
  - `typedef struct { int kind; int newer; int order; char text[200]; } mlo_finding;` — `newer`: a newer `codesign_allocate` may accept it; `order`: a rule about where the pieces lie.
  - `typedef struct { int n; int dropped; mlo_finding f[MLO_MAX]; int refusal; int corrupting; } mlo_verdict;` — `refusal` indexes the first `MLO_REFUSES` finding, or is -1.
  - `void mlo_check(const mi_image *im, mlo_verdict *v);`
  - In `tests/linkedit_fixture.h`: `lkf_build(buf, layout, opts)`, `lkf_make(buf, const lkf_variant *)`, `lkf_variants[]`/`LKF_NVARIANTS`, `lkf_lc`, `lkf_di`, `lkf_st`, `lkf_dy`, `lkf_led`, `lkf_patch`, `LKF_CANON`, `LKF_TAIL`, `LKF_CAP`, `LKF_LE`, the `LKF_LC_*` indexes and the options `LKF_NOSIG`, `LKF_NODYSYMTAB`, `LKF_EXECUTE`.

**Plan decisions.**

- **One fixture, many layouts** (25 in this task, 38 after Task 2, 46 after Task 3, 48 after Task 7). `lkf_build` writes a dylib with every piece ld64 writes for one, then places them in the order a layout string names, with `+N` gaps and `@N` roundings. A variant is a layout, options, a poke, and **what 10.9's tool says of it**, measured with `codesign_allocate -i F -a x86_64 16384 -o OUT` while this plan was written. The unit test holds `mlo_check` to that; Task 5's oracle holds it to the tool again on 10.9.
- **Findings are the tool's own words**, so a refusal can be compared with the tool's stderr.
- **Every rule is judged on its own.** The walk resyncs to where an out-of-place piece really is, so the pieces after it are judged against it, not against where it should have been. That is why "two faults" yields exactly three findings.
- **This task mirrors `check_object` less the duplicates the load-command loop refuses first** (Task 2 adds that loop) and `dyld_order` rule for rule, including the start clause exactly as `checkout.c:350-366` writes it and the zero-`dataoff` exemption that still advances the offset.

- [ ] **Step 1: Write the failing test, the fixture, and the test target**

Create `tests/linkedit_fixture.h` with:

```c
/* tests/linkedit_fixture.h -- a hand-built x86_64 dylib with every
 * __LINKEDIT piece ld64 writes for one, laid out in any order, for
 * tests/linkedit_order_test.c (in memory) and tests/mklinkedit.c (to a file).
 *
 * lkf_build(buf, layout, opts) writes the image into buf (LKF_CAP bytes) and
 * returns its size, or 0 for a layout it cannot read. `layout` names the
 * pieces in file order from __LINKEDIT's start: rebase bind weak lazy export
 * fstarts dic drs symtab indirect strtab sig. "+N" inserts N zero bytes, and
 * "@N" pads with zeros to a multiple of N. A piece the layout leaves out keeps
 * its canonical offset (a stale one, unless the layout happens to agree). A
 * size can follow a name: "strtab:36" gives the string table 36 bytes.
 *
 * LKF_CANON is the order ld64 writes and codesign_allocate wants. */
#ifndef LINKEDIT_FIXTURE_H
#define LINKEDIT_FIXTURE_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#define LKF_CAP   0x4000u
#define LKF_LE    0x2000u   /* __LINKEDIT's file offset */
#define LKF_TEXT  0x800u    /* __text's file offset */
#define LKF_CANON "rebase bind weak lazy export fstarts dic drs symtab indirect strtab @16 sig"

/* opts */
#define LKF_NOSIG      1u   /* no LC_CODE_SIGNATURE (leave "sig" out of the layout) */
#define LKF_NODYSYMTAB 2u   /* no LC_DYSYMTAB (leave "indirect" out) */
#define LKF_EXECUTE    4u   /* MH_EXECUTE, no LC_ID_DYLIB */

/* The load commands, in this order; LKF_LC_* are their indexes. */
enum { LKF_LC_TEXT, LKF_LC_DATA, LKF_LC_LINKEDIT, LKF_LC_ID, LKF_LC_DYLD_INFO,
       LKF_LC_SYMTAB, LKF_LC_DYSYMTAB, LKF_LC_FSTARTS, LKF_LC_DIC, LKF_LC_DRS,
       LKF_LC_SIG };

enum { LKF_REBASE, LKF_BIND, LKF_WEAK, LKF_LAZY, LKF_EXPORT, LKF_FSTARTS, LKF_DIC,
       LKF_DRS, LKF_SYMTAB, LKF_INDIRECT, LKF_STRTAB, LKF_SIG, LKF_NPIECES };

static const char *const lkf_names[LKF_NPIECES] = {
    "rebase", "bind", "weak", "lazy", "export", "fstarts", "dic", "drs",
    "symtab", "indirect", "strtab", "sig" };

/* Each piece's bytes. The streams are real opcodes: rebase __DATA+0; bind
 * _x (self) at __DATA+8; weak-bind _w at __DATA+0x10; lazy-bind _l (self)
 * at __DATA+0x18; an export trie with no exports. */
static const uint8_t lkf_rebase[8] = { 0x11, 0x21, 0x00, 0x51, 0x00 };
static const uint8_t lkf_bind[16] = { 0x30, 0x40, '_', 'x', 0, 0x51, 0x71, 0x08, 0x90, 0x00 };
static const uint8_t lkf_weak[16] = { 0x40, '_', 'w', 0, 0x51, 0x71, 0x10, 0x90, 0x00 };
static const uint8_t lkf_lazy[16] = { 0x71, 0x18, 0x30, 0x40, '_', 'l', 0, 0x90, 0x00 };
static const uint8_t lkf_export[16] = { 0x00, 0x00 };
static const uint8_t lkf_fstarts[8] = { 0x80, 0x10, 0x00 };
static const uint8_t lkf_drs[16] = { 0xfa, 0xde, 0x0c, 0x05, 0, 0, 0, 16 };
static const char lkf_strings[] = "\0_l\0_e\0_u";   /* 10 bytes, padded */

/* sizes in the canonical layout */
static const uint32_t lkf_sizes[LKF_NPIECES] = { 8, 16, 16, 16, 16, 8, 0, 16, 48, 12, 32, 64 };

static uint32_t lkf_rnd(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }

static uint8_t *lkf_lc(uint8_t *buf, int index) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = (uint8_t *)(h + 1);
    for (int i = 0; i < index && i < (int)h->ncmds; i++)
        p += ((struct load_command *)p)->cmdsize;
    return p;
}

/* The image's canonical load commands and the non-__LINKEDIT content. */
static uint8_t *lkf_header(uint8_t *buf, unsigned opts) {
    memset(buf, 0, LKF_CAP);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = (opts & LKF_EXECUTE) ? MH_EXECUTE : MH_DYLIB;
    h->flags = MH_DYLDLINK | MH_TWOLEVEL;
    uint8_t *lc = (uint8_t *)(h + 1);

    struct segment_command_64 *tx = (struct segment_command_64 *)lc;
    struct section_64 *text = (struct section_64 *)(tx + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof *text;
    strcpy(tx->segname, "__TEXT");
    tx->vmsize = tx->filesize = 0x1000;
    tx->maxprot = tx->initprot = VM_PROT_READ | VM_PROT_EXECUTE;
    tx->nsects = 1;
    strncpy(text->sectname, "__text", sizeof text->sectname);
    strncpy(text->segname, "__TEXT", sizeof text->segname);
    text->addr = LKF_TEXT;
    text->size = 16;
    text->offset = LKF_TEXT;
    text->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    lc += tx->cmdsize;

    struct segment_command_64 *da = (struct segment_command_64 *)lc;
    struct section_64 *data = (struct section_64 *)(da + 1);
    da->cmd = LC_SEGMENT_64;
    da->cmdsize = sizeof *da + sizeof *data;
    strcpy(da->segname, "__DATA");
    da->vmaddr = 0x1000;
    da->vmsize = da->filesize = 0x1000;
    da->fileoff = 0x1000;
    da->maxprot = da->initprot = VM_PROT_READ | VM_PROT_WRITE;
    da->nsects = 1;
    strncpy(data->sectname, "__data", sizeof data->sectname);
    strncpy(data->segname, "__DATA", sizeof data->segname);
    data->addr = 0x1000;
    data->size = 0x20;
    data->offset = 0x1000;
    lc += da->cmdsize;

    struct segment_command_64 *le = (struct segment_command_64 *)lc;
    le->cmd = LC_SEGMENT_64;
    le->cmdsize = sizeof *le;
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = 0x2000;
    le->vmsize = 0x1000;
    le->fileoff = LKF_LE;
    le->maxprot = le->initprot = VM_PROT_READ;
    lc += le->cmdsize;
    h->ncmds = 3;

    if (!(opts & LKF_EXECUTE)) {
        struct dylib_command *id = (struct dylib_command *)lc;
        id->cmd = LC_ID_DYLIB;
        id->cmdsize = sizeof *id + 16;
        id->dylib.name.offset = sizeof *id;
        strcpy((char *)(id + 1), "/lkf.dylib");
        lc += id->cmdsize;
    } else {
        /* keep the indexes: an LC_UUID where the id would be */
        struct uuid_command *u = (struct uuid_command *)lc;
        u->cmd = LC_UUID;
        u->cmdsize = sizeof *u;
        lc += u->cmdsize;
    }
    h->ncmds++;

    struct dyld_info_command *di = (struct dyld_info_command *)lc;
    di->cmd = LC_DYLD_INFO_ONLY;
    di->cmdsize = sizeof *di;
    lc += di->cmdsize;
    struct symtab_command *st = (struct symtab_command *)lc;
    st->cmd = LC_SYMTAB;
    st->cmdsize = sizeof *st;
    st->nsyms = 3;
    lc += st->cmdsize;
    h->ncmds += 2;
    if (!(opts & LKF_NODYSYMTAB)) {
        struct dysymtab_command *dy = (struct dysymtab_command *)lc;
        dy->cmd = LC_DYSYMTAB;
        dy->cmdsize = sizeof *dy;
        dy->ilocalsym = 0; dy->nlocalsym = 1;
        dy->iextdefsym = 1; dy->nextdefsym = 1;
        dy->iundefsym = 2; dy->nundefsym = 1;
        dy->nindirectsyms = 3;
        lc += dy->cmdsize;
    } else {
        struct source_version_command *sv = (struct source_version_command *)lc;   /* keeps the indexes */
        sv->cmd = LC_SOURCE_VERSION;
        sv->cmdsize = sizeof *sv;
        lc += sv->cmdsize;
    }
    h->ncmds++;
    static const uint32_t led[3] = { LC_FUNCTION_STARTS, LC_DATA_IN_CODE, LC_DYLIB_CODE_SIGN_DRS };
    for (int k = 0; k < 3; k++) {
        struct linkedit_data_command *l = (struct linkedit_data_command *)lc;
        l->cmd = led[k];
        l->cmdsize = sizeof *l;
        lc += l->cmdsize;
        h->ncmds++;
    }
    if (!(opts & LKF_NOSIG)) {
        struct linkedit_data_command *l = (struct linkedit_data_command *)lc;
        l->cmd = LC_CODE_SIGNATURE;
        l->cmdsize = sizeof *l;
        lc += l->cmdsize;
        h->ncmds++;
    }
    h->sizeofcmds = (uint32_t)(lc - (uint8_t *)(h + 1));
    buf[LKF_TEXT] = 0xc3;   /* ret */
    return lc;
}

/* Where a piece's offset and size live, and its bytes. */
static void lkf_fields(uint8_t *buf, int piece, uint32_t **off, uint32_t **size,
                       uint32_t *count_scale) {
    *count_scale = 1;
    *size = NULL;
    *off = NULL;
    struct dyld_info_command *di = (struct dyld_info_command *)lkf_lc(buf, LKF_LC_DYLD_INFO);
    struct symtab_command *st = (struct symtab_command *)lkf_lc(buf, LKF_LC_SYMTAB);
    struct dysymtab_command *dy = (struct dysymtab_command *)lkf_lc(buf, LKF_LC_DYSYMTAB);
    switch (piece) {
    case LKF_REBASE: *off = &di->rebase_off; *size = &di->rebase_size; break;
    case LKF_BIND:   *off = &di->bind_off; *size = &di->bind_size; break;
    case LKF_WEAK:   *off = &di->weak_bind_off; *size = &di->weak_bind_size; break;
    case LKF_LAZY:   *off = &di->lazy_bind_off; *size = &di->lazy_bind_size; break;
    case LKF_EXPORT: *off = &di->export_off; *size = &di->export_size; break;
    case LKF_FSTARTS: case LKF_DIC: case LKF_DRS: {
        struct linkedit_data_command *l = (struct linkedit_data_command *)
            lkf_lc(buf, LKF_LC_FSTARTS + (piece - LKF_FSTARTS));
        *off = &l->dataoff; *size = &l->datasize;
        break;
    }
    case LKF_SYMTAB: *off = &st->symoff; *size = &st->nsyms; *count_scale = 16; break;
    case LKF_INDIRECT:
        if (dy->cmd != LC_DYSYMTAB) break;
        *off = &dy->indirectsymoff; *size = &dy->nindirectsyms; *count_scale = 4;
        break;
    case LKF_STRTAB: *off = &st->stroff; *size = &st->strsize; break;
    case LKF_SIG: {
        struct linkedit_data_command *l = (struct linkedit_data_command *)lkf_lc(buf, LKF_LC_SIG);
        if (l->cmd != LC_CODE_SIGNATURE) break;
        *off = &l->dataoff; *size = &l->datasize;
        break;
    }
    }
}

static void lkf_content(int piece, uint8_t *to, uint32_t size) {
    const uint8_t *src = NULL;
    uint32_t n = 0;
    uint8_t syms[48];
    uint8_t sig[64];
    uint8_t ind[12];
    switch (piece) {
    case LKF_REBASE:  src = lkf_rebase;  n = sizeof lkf_rebase; break;
    case LKF_BIND:    src = lkf_bind;    n = sizeof lkf_bind; break;
    case LKF_WEAK:    src = lkf_weak;    n = sizeof lkf_weak; break;
    case LKF_LAZY:    src = lkf_lazy;    n = sizeof lkf_lazy; break;
    case LKF_EXPORT:  src = lkf_export;  n = sizeof lkf_export; break;
    case LKF_FSTARTS: src = lkf_fstarts; n = sizeof lkf_fstarts; break;
    case LKF_DRS:     src = lkf_drs;     n = sizeof lkf_drs; break;
    case LKF_STRTAB:  src = (const uint8_t *)lkf_strings; n = sizeof lkf_strings; break;
    case LKF_SYMTAB: {
        struct nlist_64 *s = (struct nlist_64 *)syms;
        memset(syms, 0, sizeof syms);
        s[0].n_un.n_strx = 1; s[0].n_type = N_SECT;         s[0].n_sect = 1; s[0].n_value = LKF_TEXT;
        s[1].n_un.n_strx = 4; s[1].n_type = N_SECT | N_EXT; s[1].n_sect = 1; s[1].n_value = LKF_TEXT;
        s[2].n_un.n_strx = 7; s[2].n_type = N_UNDF | N_EXT;
        src = syms; n = sizeof syms;
        break;
    }
    case LKF_INDIRECT: {
        uint32_t v[3] = { 2, INDIRECT_SYMBOL_LOCAL, INDIRECT_SYMBOL_ABS };
        memcpy(ind, v, sizeof v);
        src = ind; n = sizeof ind;
        break;
    }
    case LKF_SIG:
        memset(sig, 0, sizeof sig);
        sig[0] = 0xfa; sig[1] = 0xde; sig[2] = 0x0c; sig[3] = 0xc0; sig[7] = 64;
        src = sig; n = sizeof sig;
        break;
    }
    memset(to, 0, size);
    if (src) memcpy(to, src, n < size ? n : size);
}

static size_t lkf_build(uint8_t *buf, const char *layout, unsigned opts) {
    lkf_header(buf, opts);
    /* Every piece at its canonical offset first, so one the layout leaves
     * out still has an offset (and size) to be stale with. */
    uint32_t at = LKF_LE;
    for (int p = 0; p < LKF_NPIECES; p++) {
        uint32_t *off, *size, scale;
        lkf_fields(buf, p, &off, &size, &scale);
        if (p == LKF_SIG) at = lkf_rnd(at, 16);
        if (off) { *off = at; *size = lkf_sizes[p] / scale; }
        at += lkf_sizes[p];
    }
    uint32_t canon_end = at;
    char words[512];
    strncpy(words, layout, sizeof words - 1);
    words[sizeof words - 1] = 0;
    at = LKF_LE;
    for (char *w = strtok(words, " "); w; w = strtok(NULL, " ")) {
        if (w[0] == '+') { at += (uint32_t)strtoul(w + 1, NULL, 0); continue; }
        if (w[0] == '@') { at = lkf_rnd(at, (uint32_t)strtoul(w + 1, NULL, 0)); continue; }
        char *colon = strchr(w, ':');
        uint32_t want = 0;
        int sized = 0;
        if (colon) { *colon = 0; want = (uint32_t)strtoul(colon + 1, NULL, 0); sized = 1; }
        int p;
        for (p = 0; p < LKF_NPIECES; p++) if (strcmp(w, lkf_names[p]) == 0) break;
        if (p == LKF_NPIECES) return 0;
        uint32_t *off, *size, scale;
        lkf_fields(buf, p, &off, &size, &scale);
        if (!off) return 0;
        uint32_t bytes = sized ? want : lkf_sizes[p];
        if (at + bytes > LKF_CAP) return 0;
        *off = at;
        *size = bytes / scale;
        lkf_content(p, buf + at, bytes);
        at += bytes;
    }
    if (at < LKF_LE) return 0;
    (void)canon_end;
    struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    le->filesize = at - LKF_LE;
    if (le->filesize > le->vmsize) le->vmsize = lkf_rnd((uint32_t)le->filesize, 0x1000);
    return at;
}

/* ---- the variants ----
 * Each is a layout, options, and a poke applied after lkf_build; `tool` is
 * what 10.9's codesign_allocate (cctools-862) says, measured with
 * `codesign_allocate -i F -a x86_64 16384 -o OUT`, as mlo_check words it
 * ("…" for offsets and names), or NULL where it accepts; `corrupting` is
 * whether it then writes a piece's bytes somewhere else. */
typedef void (*lkf_poke)(uint8_t *buf, size_t *size);

static struct dyld_info_command *lkf_di(uint8_t *b) {
    return (struct dyld_info_command *)lkf_lc(b, LKF_LC_DYLD_INFO);
}
static struct symtab_command *lkf_st(uint8_t *b) {
    return (struct symtab_command *)lkf_lc(b, LKF_LC_SYMTAB);
}
static struct dysymtab_command *lkf_dy(uint8_t *b) {
    return (struct dysymtab_command *)lkf_lc(b, LKF_LC_DYSYMTAB);
}
static struct linkedit_data_command *lkf_led(uint8_t *b, int index) {
    return (struct linkedit_data_command *)lkf_lc(b, index);
}

static void lkf_patch(uint8_t *b, int index, uint32_t cmd) {
    ((struct load_command *)lkf_lc(b, index))->cmd = cmd;
}
static void lkf_stale_empty_rebase(uint8_t *b, size_t *n) {
    (void)n;
    lkf_di(b)->rebase_size = 0;
    lkf_di(b)->rebase_off = LKF_LE + 0x40;
}
static void lkf_no_rebase_no_bind(uint8_t *b, size_t *n) {
    (void)n;
    lkf_di(b)->rebase_off = lkf_di(b)->rebase_size = 0;
    lkf_di(b)->bind_off = lkf_di(b)->bind_size = 0;
}
static void lkf_no_rebase(uint8_t *b, size_t *n) {
    (void)n;
    lkf_di(b)->rebase_off = lkf_di(b)->rebase_size = 0;
}
static void lkf_dic_at_0(uint8_t *b, size_t *n) {
    (void)n;
    lkf_led(b, LKF_LC_DIC)->dataoff = 0;
}
static void lkf_syms_misordered(uint8_t *b, size_t *n) {
    (void)n;
    lkf_dy(b)->iextdefsym = 2;
    lkf_dy(b)->iundefsym = 1;
}
static void lkf_linkedit_short(uint8_t *b, size_t *n) {
    (void)n;
    ((struct segment_command_64 *)lkf_lc(b, LKF_LC_LINKEDIT))->filesize -= 16;
}
static void lkf_no_id(uint8_t *b, size_t *n) {
    (void)n;
    lkf_patch(b, LKF_LC_ID, LC_RPATH);   /* same shape: an lc_str at 24 */
}

typedef struct {
    const char *name, *layout;
    unsigned opts;
    lkf_poke poke;
    const char *tool;
    int corrupting;
} lkf_variant;

#define LKF_TAIL "fstarts dic drs symtab indirect strtab @16 sig"
static const lkf_variant lkf_variants[] = {
    { "canonical", LKF_CANON, 0, NULL, NULL, 0 },
    { "canonical-unsigned", "rebase bind weak lazy export fstarts dic drs symtab indirect strtab",
      LKF_NOSIG, NULL, NULL, 0 },
    { "bind-first", "bind rebase weak lazy export " LKF_TAIL, 0, NULL,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "gap-before-rebase", "+8 rebase bind weak lazy export " LKF_TAIL, 0, NULL,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "export-inside", "rebase bind export weak lazy " LKF_TAIL, 0, NULL,
      "file not in an order that can be processed (function starts data out of place)", 0 },
    { "gap-after-export", "rebase bind weak lazy export +8 " LKF_TAIL, 0, NULL,
      "file not in an order that can be processed (function starts data out of place)", 0 },
    { "symtab-before-fstarts",
      "rebase bind weak lazy export symtab fstarts dic drs indirect strtab @16 sig", 0, NULL,
      "file not in an order that can be processed (function starts data out of place)", 0 },
    { "dic-stale", "rebase bind weak lazy export fstarts drs dic symtab indirect strtab @16 sig",
      0, NULL, "file not in an order that can be processed (data in code info out of place)", 0 },
    { "gap-before-symtab",
      "rebase bind weak lazy export fstarts dic drs +8 symtab indirect strtab @16 sig", 0, NULL,
      "file not in an order that can be processed (symbol table out of place)", 0 },
    { "strtab-first", "rebase bind weak lazy export fstarts dic drs strtab symtab indirect @16 sig",
      0, NULL, "file not in an order that can be processed (symbol table out of place)", 0 },
    { "strtab-past-rounding",
      "rebase bind weak lazy export fstarts dic drs symtab indirect @8 +8 strtab @16 sig", 0, NULL,
      "file not in an order that can be processed (string table out of place)", 0 },
    { "strtab-at-rounding",
      "rebase bind weak lazy export fstarts dic drs symtab indirect @8 strtab @16 sig", 0, NULL,
      NULL, 0 },
    { "sig-off-16", "rebase bind weak lazy export fstarts dic drs symtab indirect strtab +8 sig",
      0, NULL, "file not in an order that can be processed (code signature data out of place)", 0 },
    { "sig-late", "rebase bind weak lazy export fstarts dic drs symtab indirect strtab @16 +16 sig",
      0, NULL, "file not in an order that can be processed (code signature data out of place)", 0 },
    { "tail-after-sig", LKF_CANON " +16", 0, NULL,
      "file not in an order that can be processed (link edit information does not fill the "
      "__LINKEDIT segment)", 0 },
    { "tail-after-strtab",
      "rebase bind weak lazy export fstarts dic drs symtab indirect strtab +16", LKF_NOSIG, NULL,
      "file not in an order that can be processed (link edit information does not fill the "
      "__LINKEDIT segment)", 0 },
    { "stale-empty-rebase", "bind weak lazy export " LKF_TAIL, 0, lkf_stale_empty_rebase,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "no-rebase-no-bind", "weak lazy export " LKF_TAIL, 0, lkf_no_rebase_no_bind,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "export-last", "rebase bind weak lazy fstarts dic drs symtab indirect strtab @16 sig export",
      0, NULL, "file not in an order that can be processed (function starts data out of place)", 0 },
    { "bind-first-exec", "bind rebase weak lazy export " LKF_TAIL, LKF_EXECUTE, NULL,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "no-rebase-bind-late", "weak bind lazy export " LKF_TAIL, 0, lkf_no_rebase,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "dic-at-0", LKF_CANON, 0, lkf_dic_at_0, NULL, 0 },
    { "syms-misordered", LKF_CANON, 0, lkf_syms_misordered,
      "file not in an order that can be processed (externally defined symbols out of place)", 0 },
    { "linkedit-short", LKF_CANON, 0, lkf_linkedit_short,
      "the __LINKEDIT segment does not cover the end of the file (can't be processed)", 0 },
    { "no-id-dylib", LKF_CANON, 0, lkf_no_id,
      "malformed file (no LC_ID_DYLIB load command in MH_DYLIB file)", 0 },
};
#define LKF_NVARIANTS (sizeof lkf_variants / sizeof lkf_variants[0])

static size_t lkf_make(uint8_t *buf, const lkf_variant *v) {
    size_t n = lkf_build(buf, v->layout, v->opts);
    if (n && v->poke) v->poke(buf, &n);
    return n;
}

#endif /* LINKEDIT_FIXTURE_H */
```

Create `tests/linkedit_order_test.c` with:

```c
/* tests/linkedit_order_test.c -- src/linkedit_order.h's mlo_check,
 * mlo_file_verdict, mlo_pack and mlo_changed, on tests/linkedit_fixture.h's
 * hand-built variants. Each variant's expected verdict is what 10.9's
 * codesign_allocate says of it (tests/codesign_order_test.sh checks that on
 * 10.9), so these run the same on every host. */
#include "image.h"
#include "linkedit_order.h"
#include "mach_compat.h"
#include "linkedit_fixture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

static const lkf_variant *variant(const char *name) {
    for (size_t k = 0; k < LKF_NVARIANTS; k++)
        if (strcmp(lkf_variants[k].name, name) == 0) return &lkf_variants[k];
    printf("FAIL: no variant %s\n", name);
    exit(1);
}

static void check(uint8_t *buf, size_t n, mlo_verdict *v) {
    mi_image im;
    if (mi_wrap(buf, n, &im) != 0) { printf("FAIL: the image does not wrap\n"); exit(1); }
    mlo_check(&im, v);
}

static int has(const mlo_verdict *v, int kind, const char *text) {
    for (int k = 0; k < v->n; k++)
        if (v->f[k].kind == kind && strstr(v->f[k].text, text)) return 1;
    return 0;
}

/* Every variant: the refusal 10.9's tool prints, and whether it re-signs
 * corrupt. */
static void test_every_variant(void) {
    static uint8_t buf[LKF_CAP];
    for (size_t k = 0; k < LKF_NVARIANTS; k++) {
        const lkf_variant *w = &lkf_variants[k];
        size_t n = lkf_make(buf, w);
        CHECK(n != 0, "%s: builds", w->name);
        mlo_verdict v;
        check(buf, n, &v);
        const char *got = v.refusal >= 0 ? v.f[v.refusal].text : NULL;
        CHECK((got == NULL) == (w->tool == NULL) && (!got || strcmp(got, w->tool) == 0),
              "%s: refusal is '%s', want '%s'", w->name, got ? got : "(none)",
              w->tool ? w->tool : "(none)");
        CHECK(v.corrupting == w->corrupting, "%s: corrupting is %d, want %d", w->name,
              v.corrupting, w->corrupting);
    }
}

/* Each rule is judged on its own: two faults, two findings. */
static void test_every_finding_is_kept(void) {
    static uint8_t buf[LKF_CAP];
    size_t n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs +8 symtab indirect "
                         "strtab +8 sig", 0);
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(has(&v, MLO_REFUSES, "(dyld_info out of place)") &&
          has(&v, MLO_REFUSES, "(symbol table out of place)") &&
          has(&v, MLO_REFUSES, "(code signature data out of place)"),
          "two faults: all three findings are kept (got %d)", v.n);
    CHECK(v.n == 3, "two faults: each piece after one out of place is judged from where that one "
          "is, so there are exactly three findings (got %d)", v.n);
    CHECK(v.refusal == 0 && strstr(v.f[0].text, "dyld_info"),
          "two faults: the refusal is the first, in the tool's order");
}

int main(void) {
    test_every_variant();
    test_every_finding_is_kept();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
    return fails ? 1 : 0;
}
```

In `CMakeLists.txt`, replace:

```cmake
# made cli_test's build-version fixtures pass here and fail on the cross runner.
add_executable(relations_test tests/relations_test.c)
```

with:

```cmake
# made cli_test's build-version fixtures pass here and fail on the cross runner.
add_executable(linkedit_order_test tests/linkedit_order_test.c)
target_compile_options(linkedit_order_test PRIVATE -O2 -Wall -Wextra -Wno-unused-function)
target_link_libraries(linkedit_order_test PRIVATE drydockcore)
add_test(NAME linkedit_order_test COMMAND linkedit_order_test
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
set_tests_properties(linkedit_order_test PROPERTIES ENVIRONMENT MallocScribble=1)

add_executable(relations_test tests/relations_test.c)
```

- [ ] **Step 2: Run it to see it fail**

Run: re-run the configure step (the Global Constraints' command), then build (rebuild check).
Expected: the build fails compiling the test:

```
tests/linkedit_order_test.c:7:10: fatal error: 'linkedit_order.h' file not found
```

- [ ] **Step 3: Write the verifier**

Create `src/linkedit_order.h` with:

```c
#ifndef DRYDOCK_LINKEDIT_ORDER_H
#define DRYDOCK_LINKEDIT_ORDER_H
/*
 * mlo_ -- whether 10.9's codesign_allocate (cctools-862) can re-sign an
 * image, and whether it would re-sign it correctly; and the pass that puts
 * __LINKEDIT in the order it wants.
 *
 * mlo_check mirrors codesign_allocate's own checks (libstuff/ofile.c's load
 * command loop, libstuff/checkout.c's check_object, dyld_order and
 * symbol_string_at_end, misc/codesign_allocate.c's header room) and
 * simulates its writer (setup_code_signature, libstuff/writeout.c's
 * copy_new_symbol_info), which never updates an offset in a load command and
 * so must put every piece back exactly where it was. It evaluates every rule
 * and records every finding. It reads the image and allocates nothing.
 */
#include <stddef.h>
#include <stdint.h>

#include "image.h"

/* A finding's kind. */
enum {
    MLO_REFUSES = 1,   /* codesign_allocate refuses the image with `text` */
    MLO_CORRUPTS,      /* its writer would put a piece somewhere else */
    MLO_NOTE           /* neither, but worth saying (see mlo_check) */
};

#define MLO_MAX 32

typedef struct {
    int  kind;
    int  newer;        /* MLO_REFUSES only: a newer codesign_allocate may not
                        * refuse it (an unknown load command, header room) */
    int  order;        /* MLO_REFUSES only: a rule about where the pieces
                        * lie (dyld_order, symbol_string_at_end) */
    char text[200];    /* codesign_allocate's own words, where it has any; a
                        * "…" stands for words that name offsets or files */
} mlo_finding;

typedef struct {
    int         n;          /* findings kept, in the tool's order */
    int         dropped;    /* findings past MLO_MAX, counted only */
    mlo_finding f[MLO_MAX];
    int         refusal;    /* index of the first MLO_REFUSES finding, or -1 */
    int         corrupting; /* every MLO_REFUSES finding is `newer`, and the
                             * writer would move a piece */
} mlo_verdict;

/* Checks `im`, a 64-bit slice, into *v. */
void mlo_check(const mi_image *im, mlo_verdict *v);

#endif /* DRYDOCK_LINKEDIT_ORDER_H */
```

Create `src/linkedit_order.c` with:

```c
/* linkedit_order.c -- see linkedit_order.h. */
#include "linkedit_order.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "mach_compat.h"

/* The load commands the checks read, found in one walk. */
typedef struct {
    const mi_image *im;
    const struct segment_command_64 *le;
    int nle;
    const struct dyld_info_command *di;
    int ndi;
    const struct symtab_command *st;
    const struct dysymtab_command *dy;
    const struct twolevel_hints_command *hints;
    const struct linkedit_data_command *split, *fstarts, *dic, *drs, *loh, *sig;
    const struct dylib_command *id;
    int nid;
} mlo_cmds;

static void mlo_vadd(mlo_verdict *v, int kind, int newer, int order, const char *fmt,
                     va_list ap) {
    if (v->n == MLO_MAX) { v->dropped++; return; }
    mlo_finding *f = &v->f[v->n++];
    vsnprintf(f->text, sizeof f->text, fmt, ap);
    f->kind = kind;
    f->newer = newer;
    f->order = order;
    if (kind == MLO_REFUSES && v->refusal < 0) v->refusal = v->n - 1;
}

static void mlo_add(mlo_verdict *v, int kind, int newer, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
static void mlo_add(mlo_verdict *v, int kind, int newer, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    mlo_vadd(v, kind, newer, 0, fmt, ap);
    va_end(ap);
}

/* A refusal about where the pieces lie. */
static void mlo_place(mlo_verdict *v, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void mlo_place(mlo_verdict *v, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    mlo_vadd(v, MLO_REFUSES, 0, 1, fmt, ap);
    va_end(ap);
}

static int mlo_collect(const struct load_command *lc, void *ctx_) {
    mlo_cmds *c = (mlo_cmds *)ctx_;
    switch (lc->cmd) {
    case LC_SEGMENT_64: {
        const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
        if (strncmp(s->segname, "__LINKEDIT", 16) == 0) {
            if (!c->le) c->le = s;
            c->nle++;
        }
        break;
    }
    case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY:
        if (!c->di) c->di = (const struct dyld_info_command *)lc;
        c->ndi++;
        break;
    case LC_SYMTAB:
        if (!c->st) c->st = (const struct symtab_command *)lc;
        break;
    case LC_DYSYMTAB:
        if (!c->dy) c->dy = (const struct dysymtab_command *)lc;
        break;
    case LC_TWOLEVEL_HINTS:
        if (!c->hints) c->hints = (const struct twolevel_hints_command *)lc;
        break;
    case LC_SEGMENT_SPLIT_INFO:
        if (!c->split) c->split = (const struct linkedit_data_command *)lc;
        break;
    case LC_FUNCTION_STARTS:
        if (!c->fstarts) c->fstarts = (const struct linkedit_data_command *)lc;
        break;
    case LC_DATA_IN_CODE:
        if (!c->dic) c->dic = (const struct linkedit_data_command *)lc;
        break;
    case LC_DYLIB_CODE_SIGN_DRS:
        if (!c->drs) c->drs = (const struct linkedit_data_command *)lc;
        break;
    case LC_LINKER_OPTIMIZATION_HINT:
        if (!c->loh) c->loh = (const struct linkedit_data_command *)lc;
        break;
    case LC_CODE_SIGNATURE:
        if (!c->sig) c->sig = (const struct linkedit_data_command *)lc;
        break;
    case LC_ID_DYLIB:
        if (!c->id) c->id = (const struct dylib_command *)lc;
        c->nid++;
        break;
    }
    return 0;
}

/* check_object (checkout.c:75-216), less the duplicates the ofile loop
 * refuses first. */
static void mlo_check_object(const mlo_cmds *c, mlo_verdict *v) {
    const struct mach_header_64 *h = c->im->hdr;
    if (c->ndi > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one LC_DYLD_INFO load command)");
    if (c->nle > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one __LINKEDITsegment)");
    if (c->nid > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one LC_ID_DYLIB load command)");
    if ((h->filetype == MH_DYLIB || (h->filetype == MH_DYLIB_STUB && h->ncmds > 0)) && !c->id)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (no LC_ID_DYLIB load command in %s file)",
                h->filetype == MH_DYLIB ? "MH_DYLIB" : "MH_DYLIB_STUB");
    if (c->hints) {
        if (!c->dy && c->hints->nhints != 0)
            mlo_add(v, MLO_REFUSES, 0, "malformed file (LC_TWOLEVEL_HINTS load command present "
                    "without an LC_DYSYMTAB load command)");
        if (c->dy && c->hints->nhints != 0 && c->hints->nhints != c->dy->nundefsym)
            mlo_add(v, MLO_REFUSES, 0, "malformed file (LC_TWOLEVEL_HINTS load command's nhints "
                    "does not match LC_DYSYMTAB load command's nundefsym)");
    }
}

static uint32_t mlo_rnd(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }


/* One piece of dyld_order's walk: `off` must be the running offset. On a
 * mismatch the walk goes on from where the piece really is, so each later
 * piece is judged on its own. */
static uint32_t mlo_at(mlo_verdict *v, uint32_t offset, uint32_t off, uint32_t size,
                       const char *what) {
    if (off != offset) {
        mlo_place(v, "file not in an order that can be processed (%s)", what);
        return off + size;
    }
    return offset + size;
}

#define MLO_ORDER(what) mlo_place(v, "file not in an order that can be processed (%s)", what)

/* dyld_order (checkout.c:313-560), rule for rule. */
static uint32_t mlo_dyld_order(const mlo_cmds *c, mlo_verdict *v) {
    const struct dysymtab_command *dy = c->dy;
    const struct symtab_command *st = c->st;
    uint32_t size = (uint32_t)c->im->size, offset, rounded, isym, pad = 0;
    if (!c->le) {
        mlo_place(v, "malformed file (no __LINKEDIT segment)");
        return 0;
    }
    if (c->le->filesize != 0 && c->le->fileoff + c->le->filesize != size)
        mlo_place(v, "the __LINKEDIT segment does not cover the end of the file (can't be processed)");
    offset = (uint32_t)c->le->fileoff;
    if (c->di) {
        const struct dyld_info_command *di = c->di;
        if (di->rebase_off != 0) {
            if (di->rebase_off != offset) MLO_ORDER("dyld_info out of place");
        } else if (di->bind_off != 0) {
            if (di->bind_off != offset) MLO_ORDER("dyld_info out of place");
        } else if (di->export_off != 0) {
            if (di->export_off != offset && di->weak_bind_size != 0 && di->lazy_bind_size != 0)
                MLO_ORDER("dyld_info out of place");
        }
        if (di->export_size != 0)         offset = di->export_off + di->export_size;
        else if (di->lazy_bind_size != 0) offset = di->lazy_bind_off + di->lazy_bind_size;
        else if (di->weak_bind_size != 0) offset = di->weak_bind_off + di->weak_bind_size;
        else if (di->bind_size != 0)      offset = di->bind_off + di->bind_size;
        else if (di->rebase_size != 0)    offset = di->rebase_off + di->rebase_size;
    }
    if (dy->nlocrel != 0)
        offset = mlo_at(v, offset, dy->locreloff, dy->nlocrel * 8, "local relocation entries out of place");
    /* A zero dataoff skips the check for these three, but not the advance. */
    static const char *const skip_what[3] = { "split info data out of place",
        "function starts data out of place", "data in code info out of place" };
    const struct linkedit_data_command *skip[3] = { c->split, c->fstarts, c->dic };
    for (int k = 0; k < 3; k++) {
        if (!skip[k]) continue;
        if (skip[k]->dataoff != 0 && skip[k]->dataoff != offset) {
            MLO_ORDER(skip_what[k]);
            offset = skip[k]->dataoff + skip[k]->datasize;
        } else {
            offset += skip[k]->datasize;
        }
    }
    if (c->drs) offset = mlo_at(v, offset, c->drs->dataoff, c->drs->datasize,
                                "code signing DRs info out of place");
    if (c->loh) offset = mlo_at(v, offset, c->loh->dataoff, c->loh->datasize,
                                "linker optimization hint info out of place");
    if (st && st->nsyms != 0)
        offset = mlo_at(v, offset, st->symoff, st->nsyms * 16, "symbol table out of place");
    isym = 0;
    if (dy->nlocalsym != 0) {
        if (dy->ilocalsym != isym) MLO_ORDER("local symbols out of place");
        isym += dy->nlocalsym;
    }
    if (dy->nextdefsym != 0) {
        if (dy->iextdefsym != isym) MLO_ORDER("externally defined symbols out of place");
        isym += dy->nextdefsym;
    }
    if (dy->nundefsym != 0) {
        if (dy->iundefsym != isym) MLO_ORDER("undefined symbols out of place");
        isym += dy->nundefsym;
    }
    if (c->hints && c->hints->nhints != 0)
        offset = mlo_at(v, offset, c->hints->offset, c->hints->nhints * 4, "hints table out of place");
    if (dy->nextrel != 0)
        offset = mlo_at(v, offset, dy->extreloff, dy->nextrel * 8,
                        "external relocation entries out of place");
    if (dy->nindirectsyms != 0)
        offset = mlo_at(v, offset, dy->indirectsymoff, dy->nindirectsyms * 4,
                        "indirect symbol table out of place");
    rounded = (dy->nindirectsyms % 2) ? mlo_rnd(offset, 8) : offset;
    /* Only the first of these that is present may take the rounding. */
    struct { uint32_t n, off, size; const char *what; } tail[4] = {
        { dy->ntoc, dy->tocoff, dy->ntoc * 8, "table of contents out of place" },
        { dy->nmodtab, dy->modtaboff, dy->nmodtab * 56, "module table out of place" },
        { dy->nextrefsyms, dy->extrefsymoff, dy->nextrefsyms * 4, "reference table out of place" },
        { st ? st->strsize : 0, st ? st->stroff : 0, st ? st->strsize : 0, "string table out of place" },
    };
    for (int k = 0; k < 4; k++) {
        if (tail[k].n == 0) continue;
        if (tail[k].off == offset) {
            offset += tail[k].size;
            rounded = offset;
        } else if (tail[k].off == rounded) {
            pad = rounded - offset;
            rounded += tail[k].size;
            offset = rounded;
        } else {
            MLO_ORDER(tail[k].what);
            offset = rounded = tail[k].off + tail[k].size;
        }
    }
    if (c->sig) {
        rounded = mlo_rnd(rounded, 16);
        if (c->sig->dataoff != rounded) {
            MLO_ORDER("code signature data out of place");
            rounded = c->sig->dataoff;
        }
        rounded += c->sig->datasize;
        offset = rounded;
    }
    if (offset != size && rounded != size)
        MLO_ORDER("link edit information does not fill the __LINKEDIT segment");
    return pad;
}

void mlo_check(const mi_image *im, mlo_verdict *v) {
    mlo_cmds c;
    memset(v, 0, sizeof *v);
    v->refusal = -1;
    memset(&c, 0, sizeof c);
    c.im = im;
    mi_each_lc(im, mlo_collect, &c);
    mlo_check_object(&c, v);
    if (c.dy && (im->hdr->filetype == MH_DYLIB || (im->hdr->flags & MH_DYLDLINK)))
        mlo_dyld_order(&c, v);
}
```

In `CMakeLists.txt`, replace:

```cmake
# a tool that gains a dependency does so visibly, in this file.
add_library(drydockcore STATIC src/uleb.c src/image.c src/ordinals.c src/fat.c src/trie.c src/lc_kinds.c src/atomic_write.c src/linkedit.c src/grow.c src/rewrite.c src/version_min.c src/segname.c src/swift_retag.c src/declassify.c src/script.c src/edit.c src/arch_names.c src/relations.c src/imports.c src/redirect.c src/exports.c src/objc_meth.c src/hdrref.c src/x86len.c src/rebase.c src/objc_abs.c)
target_include_directories(drydockcore PUBLIC src)
```

with:

```cmake
# a tool that gains a dependency does so visibly, in this file.
add_library(drydockcore STATIC src/uleb.c src/image.c src/ordinals.c src/fat.c src/trie.c src/lc_kinds.c src/atomic_write.c src/linkedit.c src/grow.c src/rewrite.c src/version_min.c src/segname.c src/swift_retag.c src/declassify.c src/script.c src/edit.c src/arch_names.c src/relations.c src/imports.c src/redirect.c src/exports.c src/objc_meth.c src/hdrref.c src/x86len.c src/rebase.c src/objc_abs.c src/linkedit_order.c)
target_include_directories(drydockcore PUBLIC src)
```

- [ ] **Step 4: Run it to see it pass**

Run: re-run the configure step, then build (rebuild check), then `"$B/linkedit_order_test"` from the repo root.
Expected: `linkedit_order_test: all cases pass`. Then the whole suite: 28 tests, all pass (`chained_fixups` skipped).

- [ ] **Step 5: Mutation proof** (file `src/linkedit_order.c`)

1. In `src/linkedit_order.c`, replace `            if (di->rebase_off != offset) MLO_ORDER("dyld_info out of place");` with `            if (0) MLO_ORDER("dyld_info out of place");`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `bind-first: refusal is`.
2. In `src/linkedit_order.c`, replace `            if (di->bind_off != offset) MLO_ORDER("dyld_info out of place");` with `            if (0) MLO_ORDER("dyld_info out of place");`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-rebase-bind-late: refusal is`.
3. In `src/linkedit_order.c`, replace `            if (di->export_off != offset && di->weak_bind_size != 0 && di->lazy_bind_size != 0)` with `            if (di->export_off != offset && di->weak_bind_size != 0 && di->lazy_bind_size != 0 && 0)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-rebase-no-bind: refusal is`.
4. In `src/linkedit_order.c`, replace `        if (di->export_size != 0)         offset = di->export_off + di->export_size;` with `        if (0)                            offset = di->export_off + di->export_size;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `export-inside: refusal is`.
5. In `src/linkedit_order.c`, replace `        if (skip[k]->dataoff != 0 && skip[k]->dataoff != offset) {` with `        if (skip[k]->dataoff != offset) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `dic-at-0: refusal is`.
6. In `src/linkedit_order.c`, replace `            offset += skip[k]->datasize;` with `            offset += 0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `canonical: refusal is`.
7. In `src/linkedit_order.c`, replace `    if (c->drs) offset = mlo_at(v, offset, c->drs->dataoff, c->drs->datasize,` with `    if (0) offset = mlo_at(v, offset, c->drs->dataoff, c->drs->datasize,`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `canonical: refusal is`.
8. In `src/linkedit_order.c`, replace `        if (dy->iextdefsym != isym) MLO_ORDER("externally defined symbols out of place");` with `        if (0) MLO_ORDER("externally defined symbols out of place");`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `syms-misordered: refusal is`.
9. In `src/linkedit_order.c`, replace `    rounded = (dy->nindirectsyms % 2) ? mlo_rnd(offset, 8) : offset;` with `    rounded = offset;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `strtab-at-rounding: refusal is`.
10. In `src/linkedit_order.c`, replace `        rounded = mlo_rnd(rounded, 16);` with `        rounded = rounded;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `canonical: refusal is`.
11. In `src/linkedit_order.c`, replace `    if (offset != size && rounded != size)` with `    if (0)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `tail-after-sig: refusal is`.
12. In `src/linkedit_order.c`, replace `    if (c->le->filesize != 0 && c->le->fileoff + c->le->filesize != size)` with `    if (0)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `linkedit-short: refusal is`.
13. In `src/linkedit_order.c`, replace `    if ((h->filetype == MH_DYLIB || (h->filetype == MH_DYLIB_STUB && h->ncmds > 0)) && !c->id)` with `    if (0)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-id-dylib: refusal is`.
14. In `src/linkedit_order.c`, replace `        return off + size;` with `        return offset + size;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `so there are exactly three findings`.
15. In `src/linkedit_order.c`, replace `    if (kind == MLO_REFUSES && v->refusal < 0) v->refusal = v->n - 1;` with `    if (kind == MLO_REFUSES) v->refusal = v->n - 1;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `the refusal is the first`.

- [ ] **Step 6: Commit**

```bash
git add src/linkedit_order.h src/linkedit_order.c tests/linkedit_fixture.h tests/linkedit_order_test.c CMakeLists.txt
git commit -m "feat(linkedit_order): check_object and dyld_order, as 10.9's codesign_allocate has them

mlo_check reads a 64-bit slice and records, in codesign_allocate's own
words, every rule of cctools-862's check_object and dyld_order it breaks:
where the dyld info starts, the order and contiguity of every __LINKEDIT
piece, the one 8-rounding and the 16-rounding before the signature,
__LINKEDIT ending the file, the symbol-index order, LC_ID_DYLIB. Each piece
after one out of place is judged from where that one really is. The
fixture is a hand-built dylib, here laid out 25 ways; each variant's
verdict is what the real tool says of it.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 2: The load-command loop, `symbol_string_at_end` and header room (M1)

**Files:**
- Modify: `src/linkedit_order.c` (before `void mlo_check(const mi_image *im, mlo_verdict *v) {`; `mlo_check`'s body)
- Modify: `tests/linkedit_fixture.h` (the pokes before `typedef struct {` … `} lkf_variant;`; the end of `lkf_variants[]`), `tests/linkedit_order_test.c`

**Interfaces:**
- Consumes: Task 1's `mlo_cmds`, `mlo_add`, `mlo_place`, `mlo_rnd`.
- Produces: `mlo_check` now evaluates, in the tool's order, the load-command loop (unknown commands by index, a second of a kind, the ranges and overlaps of every piece it reads, hints against `nundefsym`), `check_object`, `dyld_order` or `symbol_string_at_end`, and header room, and notes a `__LINKEDIT` whose `fileoff` is not a multiple of 16. An unknown command and header room are `newer` findings.

**Plan decisions.**

- **The load-command loop's list of known commands is cctools-862's** (`check_Mach_O`'s 45 `case` labels; `LC_FVMFILE` and `LC_PREPAGE` have none), and "unknown load command N" is the loop index, as the tool prints it.
- **Duplicates are refused where the loop meets the second**, with the loop's list (`LC_SYMTAB` … `LC_UUID`; the two version-min commands count as one kind). `check_object`'s own duplicates (`LC_DYLD_INFO`, `LC_ID_DYLIB`, `__LINKEDIT`) stay in Task 1's function.
- **Range and overlap checks are coarse on purpose**: one finding each, worded `truncated or malformed object (…extends past the end of the file)` and `malformed object (…overlaps…)`. The tool's exact pair of names depends on its element list's insertion order; the oracle matches the parts around "…".
- **`symbol_string_at_end` applies to an image without `LC_DYSYMTAB`, or one that is neither an `MH_DYLIB` nor `MH_DYLDLINK`**, exactly as `check_object` dispatches.
- **Header room** is checked only without an `LC_CODE_SIGNATURE`, as `add_code_sig_load_command` is only called then; it is `newer` (spec Decision 5), and so is an unknown command.

- [ ] **Step 1: Write the failing tests**

In `tests/linkedit_fixture.h`, replace:

```c
    lkf_patch(b, LKF_LC_ID, LC_RPATH);   /* same shape: an lc_str at 24 */
}

typedef struct {
```

with:

```c
    lkf_patch(b, LKF_LC_ID, LC_RPATH);   /* same shape: an lc_str at 24 */
}
static void lkf_uuid_to_bv(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_ID, 0x32); }
static void lkf_dic_to_note(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_DIC, 0x31); }
static void lkf_dic_to_trie(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_DIC, 0x80000033); }
static void lkf_dic_to_fvmfile(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_DIC, 0x9); }
static void lkf_dic_to_prepage(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_DIC, 0xa); }
static void lkf_dic_to_fstarts(uint8_t *b, size_t *n) {
    (void)n;
    lkf_patch(b, LKF_LC_DIC, LC_FUNCTION_STARTS);
}
static void lkf_id_offset(uint8_t *b, size_t *n) {
    (void)n;
    struct dylib_command *id = (struct dylib_command *)lkf_lc(b, LKF_LC_ID);
    id->dylib.name.offset = id->cmdsize;
}
static void lkf_hints0(uint8_t *b, size_t *n) {
    (void)n;
    /* the empty data-in-code command becomes an empty LC_TWOLEVEL_HINTS */
    struct twolevel_hints_command *h = (struct twolevel_hints_command *)lkf_lc(b, LKF_LC_DIC);
    h->cmd = LC_TWOLEVEL_HINTS;
    h->offset = 0;
    h->nhints = 0;
}
static void lkf_no_room(uint8_t *b, size_t *n) {
    (void)n;
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    struct section_64 *text = (struct section_64 *)(lkf_lc(b, LKF_LC_TEXT) + sizeof(struct segment_command_64));
    text->offset = (uint32_t)sizeof *h + h->sizeofcmds + 8;
    text->addr = text->offset;
}
static void lkf_strtab_past_end(uint8_t *b, size_t *n) {
    (void)n;
    lkf_st(b)->strsize += 0x1000;
}
static void lkf_fstarts0(uint8_t *b, size_t *n) {
    (void)n;
    lkf_led(b, LKF_LC_FSTARTS)->dataoff = 0;
}

typedef struct {
```

In `tests/linkedit_fixture.h`, replace:

```c
      "malformed file (no LC_ID_DYLIB load command in MH_DYLIB file)", 0 },
};
```

with:

```c
      "malformed file (no LC_ID_DYLIB load command in MH_DYLIB file)", 0 },
    /* the load-command loop, symbol_string_at_end and header room */
    { "build-version", LKF_CANON, 0, lkf_uuid_to_bv, "malformed object (unknown load command 3)", 0 },
    { "note", LKF_CANON, 0, lkf_dic_to_note, "malformed object (unknown load command 8)", 0 },
    { "exports-trie", LKF_CANON, 0, lkf_dic_to_trie, "malformed object (unknown load command 8)", 0 },
    { "fvmfile", LKF_CANON, 0, lkf_dic_to_fvmfile, "malformed object (unknown load command 8)", 0 },
    { "prepage", LKF_CANON, 0, lkf_dic_to_prepage, "malformed object (unknown load command 8)", 0 },
    { "two-fstarts", LKF_CANON, 0, lkf_dic_to_fstarts,
      "malformed object (more than one LC_FUNCTION_STARTS command)", 0 },
    { "id-name-offset", LKF_CANON, 0, lkf_id_offset,
      "truncated or malformed object (name.offset field of LC_ID_DYLIB command 3 extends past the "
      "end of the file)", 0 },
    { "hints-0", LKF_CANON, 0, lkf_hints0,
      "malformed object (nhints in LC_TWOLEVEL_HINTS load command not the same as nundefsym in "
      "LC_DYSYMTAB load command)", 0 },
    { "no-room", "rebase bind weak lazy export fstarts dic drs symtab indirect strtab", LKF_NOSIG,
      lkf_no_room, "because larger updated load commands do not fit", 0 },
    { "fstarts-dataoff-0", "rebase bind weak lazy export +8 dic drs symtab indirect strtab @16 sig",
      0, lkf_fstarts0, "malformed object (…overlaps…)", 0 },
    { "strtab-past-end", LKF_CANON, 0, lkf_strtab_past_end,
      "truncated or malformed object (…extends past the end of the file)", 0 },
    { "no-dysymtab-strtab-first", "rebase bind weak lazy export fstarts dic drs strtab symtab @16 sig",
      LKF_NODYSYMTAB | LKF_EXECUTE, NULL,
      "string table not at the end of the file (can't be processed)", 0 },
    { "no-dysymtab-tail", "rebase bind weak lazy export fstarts dic drs symtab strtab @16 sig +16",
      LKF_NODYSYMTAB | LKF_EXECUTE, NULL,
      "code signature not at the end of the file (can't be processed)", 0 },
};
```

In `tests/linkedit_order_test.c`, replace:

```c

int main(void) {
```

with:

```c

/* A __LINKEDIT whose file offset is not a multiple of 16 is noted. */
static void test_the_fileoff_note(void) {
    static uint8_t buf[LKF_CAP];
    size_t n = lkf_make(buf, variant("canonical-unsigned"));
    struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(!has(&v, MLO_NOTE, "multiple of 16"), "fileoff 0x2000: no note");
    le->fileoff = LKF_LE - 8;   /* a lie, but the note reads only this */
    le->filesize += 8;
    check(buf, n, &v);
    CHECK(has(&v, MLO_NOTE, "multiple of 16"), "fileoff 0x1ff8: noted");
}

int main(void) {
```

In `tests/linkedit_order_test.c`, replace:

```c
    test_every_finding_is_kept();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
```

with:

```c
    test_every_finding_is_kept();
    test_the_fileoff_note();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
```

- [ ] **Step 2: Run it to see it fail**

Run: build (rebuild check), then `"$B/linkedit_order_test"`.
Expected: exit 1, fourteen `FAIL:` lines, among them:

```
FAIL: build-version: refusal is 'malformed file (no LC_ID_DYLIB load command in MH_DYLIB file)', want 'malformed object (unknown load command 3)'
FAIL: note: refusal is '(none)', want 'malformed object (unknown load command 8)'
FAIL: two-fstarts: refusal is '(none)', want 'malformed object (more than one LC_FUNCTION_STARTS command)'
FAIL: no-room: refusal is '(none)', want 'because larger updated load commands do not fit'
FAIL: no-dysymtab-strtab-first: refusal is '(none)', want 'string table not at the end of the file (can't be processed)'
FAIL: fileoff 0x1ff8: noted
```

- [ ] **Step 3: Write the checks**

In `src/linkedit_order.c`, replace:

```c

void mlo_check(const mi_image *im, mlo_verdict *v) {
```

with:

```c

/* The load commands cctools-862's check_Mach_O has a case for
 * (ofile.c:3530-5965). LC_FVMFILE and LC_PREPAGE have none. */
static const uint32_t mlo_known[] = {
    LC_SEGMENT, LC_SYMTAB, LC_SYMSEG, LC_THREAD, LC_UNIXTHREAD, LC_LOADFVMLIB,
    LC_IDFVMLIB, LC_IDENT, LC_DYSYMTAB, LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_DYLINKER,
    LC_ID_DYLINKER, LC_PREBOUND_DYLIB, LC_ROUTINES, LC_SUB_FRAMEWORK, LC_SUB_UMBRELLA,
    LC_SUB_CLIENT, LC_SUB_LIBRARY, LC_TWOLEVEL_HINTS, LC_PREBIND_CKSUM, LC_LOAD_WEAK_DYLIB,
    LC_SEGMENT_64, LC_ROUTINES_64, LC_UUID, LC_RPATH, LC_CODE_SIGNATURE,
    LC_SEGMENT_SPLIT_INFO, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_ENCRYPTION_INFO,
    LC_DYLD_INFO, LC_DYLD_INFO_ONLY, LC_LOAD_UPWARD_DYLIB, LC_VERSION_MIN_MACOSX,
    LC_VERSION_MIN_IPHONEOS, LC_FUNCTION_STARTS, LC_DYLD_ENVIRONMENT, LC_MAIN,
    LC_DATA_IN_CODE, LC_SOURCE_VERSION, LC_DYLIB_CODE_SIGN_DRS, LC_ENCRYPTION_INFO_64,
    LC_LINKER_OPTION, LC_LINKER_OPTIMIZATION_HINT,
};

static int mlo_known_cmd(uint32_t cmd) {
    for (size_t k = 0; k < sizeof mlo_known / sizeof mlo_known[0]; k++)
        if (mlo_known[k] == cmd) return 1;
    return 0;
}

/* The commands the loop refuses a second of, and the name it says. The two
 * version-min commands count as one kind. */
static const struct { uint32_t cmd; const char *name; } mlo_once[] = {
    { LC_SYMTAB, "LC_SYMTAB" }, { LC_DYSYMTAB, "LC_DYSYMTAB" },
    { LC_ROUTINES, "LC_ROUTINES" }, { LC_ROUTINES_64, "LC_ROUTINES_64" },
    { LC_TWOLEVEL_HINTS, "LC_TWOLEVEL_HINTS" }, { LC_SEGMENT_SPLIT_INFO, "LC_SEGMENT_SPLIT_INFO" },
    { LC_CODE_SIGNATURE, "LC_CODE_SIGNATURE" }, { LC_FUNCTION_STARTS, "LC_FUNCTION_STARTS" },
    { LC_DATA_IN_CODE, "LC_DATA_IN_CODE" }, { LC_DYLIB_CODE_SIGN_DRS, "LC_DYLIB_CODE_SIGN_DRS" },
    { LC_LINKER_OPTIMIZATION_HINT, "LC_LINKER_OPTIMIZATION_HINT" },
    { LC_VERSION_MIN_MACOSX, "LC_VERSION_MIN_IPHONEOS or LC_VERSION_MIN_MACOSX" },
    { LC_VERSION_MIN_IPHONEOS, "LC_VERSION_MIN_IPHONEOS or LC_VERSION_MIN_MACOSX" },
    { LC_PREBIND_CKSUM, "LC_PREBIND_CKSUM" }, { LC_UUID, "LC_UUID" },
};
#define MLO_NONCE (sizeof mlo_once / sizeof mlo_once[0])

/* The ofile loop, in index order: every unknown command and every second
 * of a kind, each where the loop meets it. */
static void mlo_ofile_loop(const mi_image *im, mlo_verdict *v) {
    const struct mach_header_64 *h = im->hdr;
    const uint8_t *p = (const uint8_t *)(h + 1);
    int seen[MLO_NONCE];
    memset(seen, 0, sizeof seen);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (!mlo_known_cmd(lc->cmd)) {
            mlo_add(v, MLO_REFUSES, 1, "malformed object (unknown load command %u)", i);
        } else if (lc->cmd == LC_ID_DYLIB &&
                   ((const struct dylib_command *)lc)->dylib.name.offset >= lc->cmdsize) {
            mlo_add(v, MLO_REFUSES, 0, "truncated or malformed object (name.offset field of "
                    "LC_ID_DYLIB command %u extends past the end of the file)", i);
        } else {
            for (size_t k = 0; k < MLO_NONCE; k++) {
                if (mlo_once[k].cmd != lc->cmd) continue;
                /* the version-min pair share one count */
                size_t slot = (lc->cmd == LC_VERSION_MIN_IPHONEOS) ? k - 1 : k;
                if (seen[slot]++)
                    mlo_add(v, MLO_REFUSES, 0, "malformed object (more than one %s command)",
                            mlo_once[k].name);
            }
        }
        p += lc->cmdsize;
    }
}

/* A range of the file one command names, as the loop checks and overlaps
 * them. */
typedef struct { uint64_t off, size; } mlo_range;

static int mlo_ranges(const mlo_cmds *c, mlo_range *r, int max) {
    int n = 0;
#define MLO_R(o, s) do { if (((s) != 0 || (o) != 0) && n < max) { r[n].off = (o); r[n].size = (s); n++; } } while (0)
    const struct dyld_info_command *di = c->di;
    if (di) {
        MLO_R(di->rebase_off, di->rebase_size);
        MLO_R(di->bind_off, di->bind_size);
        MLO_R(di->weak_bind_off, di->weak_bind_size);
        MLO_R(di->lazy_bind_off, di->lazy_bind_size);
        MLO_R(di->export_off, di->export_size);
    }
    const struct linkedit_data_command *led[6] = { c->split, c->fstarts, c->dic, c->drs, c->loh, c->sig };
    for (int k = 0; k < 6; k++) if (led[k]) MLO_R(led[k]->dataoff, led[k]->datasize);
    if (c->st) {
        MLO_R(c->st->symoff, (uint64_t)c->st->nsyms * 16);
        MLO_R(c->st->stroff, c->st->strsize);
    }
    if (c->dy) {
        const struct dysymtab_command *dy = c->dy;
        MLO_R(dy->tocoff, (uint64_t)dy->ntoc * 8);
        MLO_R(dy->modtaboff, (uint64_t)dy->nmodtab * 56);
        MLO_R(dy->extrefsymoff, (uint64_t)dy->nextrefsyms * 4);
        MLO_R(dy->indirectsymoff, (uint64_t)dy->nindirectsyms * 4);
        MLO_R(dy->extreloff, (uint64_t)dy->nextrel * 8);
        MLO_R(dy->locreloff, (uint64_t)dy->nlocrel * 8);
    }
    if (c->hints) MLO_R(c->hints->offset, (uint64_t)c->hints->nhints * 4);
#undef MLO_R
    return n;
}

/* The loop's checks on the ranges it reads: each within the file, and none
 * overlapping another or the headers. */
static void mlo_ofile_ranges(const mlo_cmds *c, mlo_verdict *v) {
    mlo_range r[32];
    int n = mlo_ranges(c, r, 31);
    r[n].off = 0;
    r[n].size = sizeof(struct mach_header_64) + c->im->hdr->sizeofcmds;
    n++;
    for (int i = 0; i < n; i++) {
        if (r[i].off > c->im->size || r[i].size > c->im->size - r[i].off) {
            mlo_add(v, MLO_REFUSES, 0, "truncated or malformed object (…extends past the end of the file)");
            return;
        }
    }
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++)
            if (r[i].size && r[j].size &&
                r[i].off < r[j].off + r[j].size && r[j].off < r[i].off + r[i].size) {
                mlo_add(v, MLO_REFUSES, 0, "malformed object (…overlaps…)");
                return;
            }
}

/* The loop's last check (ofile.c:6046). */
static void mlo_ofile_hints(const mlo_cmds *c, mlo_verdict *v) {
    if (c->hints && c->dy && c->hints->nhints != c->dy->nundefsym)
        mlo_add(v, MLO_REFUSES, 0, "malformed object (nhints in LC_TWOLEVEL_HINTS load command "
                "not the same as nundefsym in LC_DYSYMTAB load command)");
}

/* symbol_string_at_end (checkout.c:573-699), rule for rule. Returns the
 * indirect table's pad, which the writer counts. */
static uint32_t mlo_string_at_end(const mlo_cmds *c, mlo_verdict *v, uint32_t *object_size) {
    const struct symtab_command *st = c->st;
    uint32_t pad = 0;
    if (!st || st->nsyms == 0) return 0;
    uint32_t end = *object_size;
    if (c->sig) {
        if (c->sig->dataoff + c->sig->datasize != end)
            mlo_place(v, "code signature not at the end of the file (can't be processed)");
        end = c->sig->dataoff;
        if (st->strsize != 0 && c->sig->dataoff == mlo_rnd(st->stroff + st->strsize, 16))
            end = st->stroff + st->strsize;
    }
    if (st->strsize != 0) {
        uint32_t strend = st->stroff + st->strsize;
        uint32_t rounded = mlo_rnd(strend, 8);
        if (strend != end && rounded != end)
            mlo_place(v, "string table not at the end of the file (can't be processed)");
        if (rounded != strend && !c->sig) *object_size = strend;
        end = st->stroff;
    }
    const struct dysymtab_command *dy = c->dy;
    if (dy && dy->nindirectsyms != 0 && dy->indirectsymoff > st->symoff) {
        uint32_t indirectend = dy->indirectsymoff + dy->nindirectsyms * 4;
        uint32_t rounded = (dy->nindirectsyms % 2) ? mlo_rnd(indirectend, 8) : indirectend;
        if (indirectend != end && rounded != end)
            mlo_place(v, "indirect symbol table does not directly preceed the string "
                    "table (can't be processed)");
        pad = end - indirectend;
        end = dy->indirectsymoff;
        if (st->symoff + st->nsyms * 16 != end)
            mlo_place(v, "symbol table does not directly preceed the indirect symbol "
                    "table (can't be processed)");
    } else if (st->symoff + st->nsyms * 16 != end) {
        mlo_place(v, "symbol table and string table not at the end of the file "
                "(can't be processed)");
    }
    if (c->le && c->le->filesize != 0 && c->le->fileoff + c->le->filesize != *object_size)
        mlo_place(v, "the __LINKEDIT segment does not cover the symbol and string "
                "table (can't be processed)");
    return pad;
}

/* add_code_sig_load_command's room check (codesign_allocate.c:655-736),
 * for an image with no LC_CODE_SIGNATURE. */
static int mlo_room_seg(const struct load_command *lc, void *ctx_) {
    uint32_t *low = (uint32_t *)ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(sg + 1);
    if (sg->nsects != 0) {
        for (uint32_t j = 0; j < sg->nsects; j++, s++) {
            uint32_t type = s->flags & SECTION_TYPE;
            if (s->size != 0 && type != S_ZEROFILL && type != S_THREAD_LOCAL_ZEROFILL &&
                s->offset < *low)
                *low = s->offset;
        }
    } else if (sg->filesize != 0 && sg->fileoff < *low) {
        *low = (uint32_t)sg->fileoff;
    }
    return 0;
}

static void mlo_room(const mlo_cmds *c, mlo_verdict *v) {
    uint32_t low = UINT32_MAX;
    if (c->sig) return;
    mi_each_lc(c->im, mlo_room_seg, &low);
    if (c->im->hdr->sizeofcmds + sizeof(struct linkedit_data_command) +
        sizeof(struct mach_header_64) > low)
        mlo_add(v, MLO_REFUSES, 1, "because larger updated load commands do not fit");
    if (c->le && c->le->fileoff % 16 != 0)
        mlo_add(v, MLO_NOTE, 0, "__LINKEDIT's file offset is not a multiple of 16, and "
                "codesign_allocate would round its filesize, not its end");
}

void mlo_check(const mi_image *im, mlo_verdict *v) {
```

In `src/linkedit_order.c`, replace:

```c
    mi_each_lc(im, mlo_collect, &c);
    mlo_check_object(&c, v);
    if (c.dy && (im->hdr->filetype == MH_DYLIB || (im->hdr->flags & MH_DYLDLINK)))
        mlo_dyld_order(&c, v);
}
```

with:

```c
    mi_each_lc(im, mlo_collect, &c);
    mlo_ofile_loop(im, v);
    mlo_ofile_ranges(&c, v);
    mlo_ofile_hints(&c, v);
    mlo_check_object(&c, v);
    uint32_t object_size = (uint32_t)im->size;
    if (c.dy && (im->hdr->filetype == MH_DYLIB || (im->hdr->flags & MH_DYLDLINK)))
        mlo_dyld_order(&c, v);
    else
        mlo_string_at_end(&c, v, &object_size);
    mlo_room(&c, v);
}
```

- [ ] **Step 4: Run it to see it pass**

Run: build (rebuild check), then `"$B/linkedit_order_test"`.
Expected: `linkedit_order_test: all cases pass`. The whole suite: 28 tests pass.

- [ ] **Step 5: Mutation proof** (file `src/linkedit_order.c`)

1. In `src/linkedit_order.c`, replace `        if (!mlo_known_cmd(lc->cmd)) {` with `        if (0) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `note: refusal is`.
2. In `src/linkedit_order.c`, replace `    LC_SEGMENT_64, LC_ROUTINES_64, LC_UUID, LC_RPATH, LC_CODE_SIGNATURE,` with `    LC_SEGMENT_64, LC_ROUTINES_64, LC_UUID, LC_RPATH,`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `canonical: refusal is`.
3. In `src/linkedit_order.c`, replace `                if (seen[slot]++)` with `                if (0 && seen[slot]++)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `two-fstarts: refusal is`.
4. In `src/linkedit_order.c`, replace `                   ((const struct dylib_command *)lc)->dylib.name.offset >= lc->cmdsize) {` with `                   ((const struct dylib_command *)lc)->dylib.name.offset > lc->cmdsize) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `id-name-offset: refusal is`.
5. In `src/linkedit_order.c`, replace `        if (r[i].off > c->im->size || r[i].size > c->im->size - r[i].off) {` with `        if (0) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `strtab-past-end: refusal is`.
6. In `src/linkedit_order.c`, replace `                r[i].off < r[j].off + r[j].size && r[j].off < r[i].off + r[i].size) {` with `                0) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `fstarts-dataoff-0: refusal is`.
7. In `src/linkedit_order.c`, replace `    if (c->hints && c->dy && c->hints->nhints != c->dy->nundefsym)` with `    if (0)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `hints-0: refusal is`.
8. In `src/linkedit_order.c`, replace `        if (c->sig->dataoff + c->sig->datasize != end)` with `        if (0)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-dysymtab-tail: refusal is`.
9. In `src/linkedit_order.c`, replace `            mlo_place(v, "string table not at the end of the file (can't be processed)");` with `            (void)0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-dysymtab-strtab-first: refusal is`.
10. In `src/linkedit_order.c`, replace `    if (c->sig) return;` with `    if (!c->sig) return;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-room: refusal is`.
11. In `src/linkedit_order.c`, replace `    if (c->im->hdr->sizeofcmds + sizeof(struct linkedit_data_command) +` with `    if (c->im->hdr->sizeofcmds +`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-room: refusal is`.
12. In `src/linkedit_order.c`, replace `    if (c->le && c->le->fileoff % 16 != 0)` with `    if (0)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `fileoff 0x1ff8: noted`.
13. In `src/linkedit_order.c`, replace `        mlo_string_at_end(&c, v, &object_size);` with `        (void)0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-dysymtab-strtab-first: refusal is`.

- [ ] **Step 6: Commit**

```bash
git add src/linkedit_order.c tests/linkedit_fixture.h tests/linkedit_order_test.c
git commit -m "feat(linkedit_order): the load-command loop, symbol_string_at_end, header room

mlo_check now refuses, as 10.9's codesign_allocate does, a load command
cctools-862 does not know (by its index), a second command of a kind, a
piece past the file or overlapping another, two-level hints that disagree
with nundefsym, an image without LC_DYSYMTAB whose symbol and string
tables do not end the file, and one with no room for an LC_CODE_SIGNATURE.
An unknown command and header room are marked as ones a newer tool may
accept.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 3: The writer simulation, and the whole file's verdict (M1)

**Files:**
- Modify: `src/linkedit_order.h` (after `void mlo_check(const mi_image *im, mlo_verdict *v);`), `src/linkedit_order.c` (its includes; before `void mlo_check(`; `mlo_check`'s tail; the end of the file)
- Modify: `tests/linkedit_fixture.h` (a poke; the end of `lkf_variants[]`), `tests/linkedit_order_test.c`

**Interfaces:**
- Consumes: Tasks 1–2's `mlo_check` and its helpers; `mfat_parse`, `mfat_get` (`src/fat.h`); `ma_describe` (`src/arch_names.h`).
- Produces:
  - `mlo_verdict.corrupting`: no refusal that every tool makes, and the simulated writer would leave some piece's bytes other than where its load command says.
  - `int mlo_file_verdict(const uint8_t *buf, size_t size, char *refusal, size_t rsz, char *corrupt, size_t csz);` — returns 0 (re-signs correctly on 10.9), 1 (10.9 refuses it; `refusal` has the first slice's reason, prefixed `slice NAME: ` in a fat file), 2 (some slice is corrupting; `corrupt` names the pieces), or -1 (not a 64-bit Mach-O or a fat file of them). A slice `mlo_check` does not model gives `not checked: slice NAME is not a 64-bit Mach-O`.

**Plan decisions.**

- **The simulation compares bytes.** It builds no buffer: for each piece it asks what the writer's output would hold at that piece's offset — the verbatim copy below `P`, a write whose source is some piece, or nothing — and compares with the input's own bytes. That is the exact criterion, and exactly what the oracle measures after the real tool. It is why a hole the 16-rounding absorbs passes, and why a piece with data at `dataoff` 0 would pass too (its range is inside the verbatim copy; the loop refuses it anyway, Task 2's `fstarts-dataoff-0`).
- **Both writer branches**: with `LC_DYSYMTAB` every piece is written, the dyld info as one span; without it only the symbol and string tables. Symbols and strings count only when `nsyms != 0`, in one variable (`strsize`) used for both the sum and the write, so a mutation cannot hide in one of two copies.
- **Only 862's writer.** An image still carrying a chained-fixups or exports-trie blob fails 862's order rules, so `corrupting` is never evaluated for it (spec N2).
- **`corrupting` is evaluated only when every refusal is `newer`**: behind an unknown command it still counts, because a newer tool knows the command and makes the same sum.

- [ ] **Step 1: Write the failing tests**

In `tests/linkedit_fixture.h`, replace:

```c
    lkf_led(b, LKF_LC_FSTARTS)->dataoff = 0;
}

typedef struct {
```

with:

```c
    lkf_led(b, LKF_LC_FSTARTS)->dataoff = 0;
}
static void lkf_nsyms0(uint8_t *b, size_t *n) {
    (void)n;
    struct dysymtab_command *dy = lkf_dy(b);
    lkf_st(b)->nsyms = 0;
    dy->nlocalsym = dy->nextdefsym = dy->nundefsym = 0;
    dy->ilocalsym = dy->iextdefsym = dy->iundefsym = 0;
    uint32_t *ind = (uint32_t *)(b + dy->indirectsymoff);
    ind[0] = INDIRECT_SYMBOL_LOCAL;
}

typedef struct {
```

In `tests/linkedit_fixture.h`, replace:

```c
      "code signature not at the end of the file (can't be processed)", 0 },
};
```

with:

```c
      "code signature not at the end of the file (can't be processed)", 0 },
    /* the writer */
    { "hole-16", "rebase +16 bind weak lazy export " LKF_TAIL, 0, NULL, NULL, 1 },
    { "hole-absorbed", "rebase +4 bind weak lazy export " LKF_TAIL, 0, NULL, NULL, 0 },
    { "hole-16-unsigned",
      "rebase +16 bind weak lazy export fstarts dic drs symtab indirect strtab", LKF_NOSIG, NULL,
      NULL, 1 },
    { "nsyms-0", "rebase bind weak lazy export fstarts dic drs indirect strtab @16 sig", 0,
      lkf_nsyms0, NULL, 1 },
    { "nsyms-0-short-strtab", "rebase bind weak lazy export fstarts dic drs indirect strtab:4 @16 sig",
      0, lkf_nsyms0, NULL, 1 },
    { "no-dysymtab-drs8", "rebase bind weak lazy export +16 fstarts dic drs:8 symtab strtab @16 sig",
      LKF_NODYSYMTAB | LKF_EXECUTE, NULL, NULL, 1 },
    { "no-dysymtab-hole", "rebase bind weak lazy export +16 fstarts dic drs symtab strtab @16 sig",
      LKF_NODYSYMTAB | LKF_EXECUTE, NULL, NULL, 0 },
    { "hole-16-note", "rebase +16 bind weak lazy export " LKF_TAIL, 0, lkf_dic_to_note,
      "malformed object (unknown load command 8)", 1 },
};
```

In `tests/linkedit_order_test.c`, replace:

```c

#include <stdio.h>
```

with:

```c

#include <mach-o/fat.h>
#include <stdio.h>
```

In `tests/linkedit_order_test.c`, replace:

```c

int main(void) {
```

with:

```c

/* An unknown command does not hide a hole a newer tool would re-sign
 * corrupt. */
static void test_corrupting_behind_an_unknown_command(void) {
    static uint8_t buf[LKF_CAP];
    size_t n = lkf_build(buf, "rebase +16 bind weak lazy export " LKF_TAIL, LKF_EXECUTE);
    lkf_uuid_to_bv(buf, &n);
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(v.refusal >= 0 && strstr(v.f[v.refusal].text, "unknown load command 3") && v.corrupting,
          "an unknown command and a hole: refused on 10.9, and corrupting");
}

/* The writer counts the string table only with symbols; the review's
 * no-dysymtab image writes only the symbol and string tables. */
static void test_the_simulation_follows_the_branches(void) {
    static uint8_t buf[LKF_CAP];
    size_t n = lkf_make(buf, variant("nsyms-0"));
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(has(&v, MLO_CORRUPTS, "would not survive"), "nsyms 0: the pieces would move");
    n = lkf_make(buf, variant("no-dysymtab-hole"));
    check(buf, n, &v);
    CHECK(v.n == 0, "no dysymtab, a hole: nothing found (got %d: %s)", v.n, v.n ? v.f[0].text : "");
}

/* The whole file: thin, and fat with a bad slice. */
static void test_the_file_verdict(void) {
    static uint8_t a[LKF_CAP], b[LKF_CAP];
    char refusal[256], corrupt[512];
    size_t na = lkf_make(a, variant("canonical"));
    int rc = mlo_file_verdict(a, na, refusal, sizeof refusal, corrupt, sizeof corrupt);
    CHECK(rc == 0 && strcmp(refusal, "ok") == 0 && !corrupt[0], "thin canonical: ok (got %d, %s)",
          rc, refusal);
    size_t nb = lkf_make(b, variant("note"));
    size_t off2 = 0x4000, total = off2 + nb;
    uint8_t *fat = (uint8_t *)calloc(1, total);
    struct fat_header *fh = (struct fat_header *)fat;
    struct fat_arch *fa = (struct fat_arch *)(fh + 1);
    fh->magic = OSSwapHostToBigInt32(FAT_MAGIC);
    fh->nfat_arch = OSSwapHostToBigInt32(2);
    fa[0].cputype = OSSwapHostToBigInt32(CPU_TYPE_X86_64);
    fa[0].cpusubtype = OSSwapHostToBigInt32(CPU_SUBTYPE_X86_64_ALL);
    fa[0].offset = OSSwapHostToBigInt32(0x1000);
    fa[0].size = OSSwapHostToBigInt32((uint32_t)na);
    fa[0].align = OSSwapHostToBigInt32(12);
    fa[1].cputype = OSSwapHostToBigInt32(CPU_TYPE_X86_64);
    fa[1].cpusubtype = OSSwapHostToBigInt32(CPU_SUBTYPE_X86_64_H);
    fa[1].offset = OSSwapHostToBigInt32((uint32_t)off2);
    fa[1].size = OSSwapHostToBigInt32((uint32_t)nb);
    fa[1].align = OSSwapHostToBigInt32(12);
    memcpy(fat + 0x1000, a, na);
    memcpy(fat + off2, b, nb);
    ((struct mach_header_64 *)(fat + off2))->cpusubtype = CPU_SUBTYPE_X86_64_H;
    rc = mlo_file_verdict(fat, total, refusal, sizeof refusal, corrupt, sizeof corrupt);
    CHECK(rc == 1 && strcmp(refusal, "slice x86_64h: malformed object (unknown load command 8)") == 0,
          "fat: the other slice's refusal (got %d, %s)", rc, refusal);
    /* and a corrupting slice */
    size_t nc = lkf_make(b, variant("hole-16"));
    memcpy(fat + off2, b, nc);
    fa[1].size = OSSwapHostToBigInt32((uint32_t)nc);
    ((struct mach_header_64 *)(fat + off2))->cpusubtype = CPU_SUBTYPE_X86_64_H;
    rc = mlo_file_verdict(fat, off2 + nc, refusal, sizeof refusal, corrupt, sizeof corrupt);
    CHECK(rc == 2 && strncmp(corrupt, "slice x86_64h: ", 15) == 0 && strstr(corrupt, "would not survive"),
          "fat: a corrupting slice (got %d, %s)", rc, corrupt);
    free(fat);
}

int main(void) {
```

In `tests/linkedit_order_test.c`, replace:

```c
    test_the_fileoff_note();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
```

with:

```c
    test_the_fileoff_note();
    test_corrupting_behind_an_unknown_command();
    test_the_simulation_follows_the_branches();
    test_the_file_verdict();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
```

- [ ] **Step 2: Run it to see it fail**

Run: build (rebuild check).
Expected: the test does not link. The output includes:

```
Undefined symbols for architecture x86_64:
ld: symbol(s) not found for architecture x86_64
```

and names `_mlo_file_verdict` as the missing symbol.

- [ ] **Step 3: Write the simulation and the verdict**

In `src/linkedit_order.h`, replace:

```c

#endif /* DRYDOCK_LINKEDIT_ORDER_H */
```

with:

```c

/* One line for a whole file, thin or fat: every slice is checked, as
 * codesign_allocate checks every slice whatever it signs. `refusal` gets
 * "ok", the first slice's refusal ("slice x86_64h: " before it in a fat
 * file), or "not checked: …" for a slice mlo_check does not model; `corrupt`
 * gets "" or the pieces a corrupting slice's writer would move. Returns 0 when
 * the file would re-sign correctly on 10.9, 1 when 10.9 refuses it, 2 when
 * some slice is corrupting, -1 when `buf` is neither a 64-bit Mach-O nor a
 * fat container of them. */
int mlo_file_verdict(const uint8_t *buf, size_t size, char *refusal, size_t rsz,
                     char *corrupt, size_t csz);

#endif /* DRYDOCK_LINKEDIT_ORDER_H */
```

In `src/linkedit_order.c`, replace:

```c

#include "mach_compat.h"
```

with:

```c

#include "arch_names.h"
#include "fat.h"
#include "mach_compat.h"
```

In `src/linkedit_order.c`, replace:

```c

void mlo_check(const mi_image *im, mlo_verdict *v) {
```

with:

```c

/* The writer (setup_code_signature, codesign_allocate.c:302-503;
 * copy_new_symbol_info, writeout.c:735-840). It copies the file verbatim up
 * to P = object_size - input_sym_info_size, writes the pieces it knows one
 * after another from P, each from where its load command says it is, and
 * then the signature at the next multiple of 16. It updates no offset, so
 * the re-sign is correct only if every piece's bytes are still where its load
 * command says. This is that comparison, done on the input's own bytes. */
typedef struct { uint32_t dest, src, size; } mlo_write;

/* Would the output hold input[off, off+size)'s bytes at the same place? */
static int mlo_survives(const uint8_t *in, uint32_t P, const mlo_write *w, int nw,
                        uint32_t off, uint32_t size) {
    uint32_t x = off, end = off + size;
    while (x < end) {
        if (x < P) { x = end < P ? end : P; continue; }
        int k;
        for (k = 0; k < nw; k++)
            if (w[k].size && x >= w[k].dest && x < w[k].dest + w[k].size) break;
        if (k == nw) return 0;   /* nothing the writer puts there */
        uint32_t stop = w[k].dest + w[k].size < end ? w[k].dest + w[k].size : end;
        if (memcmp(in + w[k].src + (x - w[k].dest), in + x, stop - x) != 0) return 0;
        x = stop;
    }
    return 1;
}

static void mlo_simulate(const mlo_cmds *c, mlo_verdict *v, uint32_t object_size, uint32_t pad) {
    const struct symtab_command *st = c->st;
    const struct dysymtab_command *dy = c->dy;
    const struct dyld_info_command *di = c->di;
    const uint8_t *in = c->im->buf;
    /* The symbol and string tables count only when there are symbols. */
    uint32_t nsyms = st ? st->nsyms : 0;
    uint32_t strsize = nsyms ? st->strsize : 0;
    uint64_t iss = (uint64_t)nsyms * 16 + strsize;
    mlo_write w[24];
    int nw = 0;
    /* What the writer writes, in its order: (source offset, size); a source
     * of UINT32_MAX is padding. */
    uint32_t src[24], len[24];
    int n = 0;
#define MLO_W(o, s) do { src[n] = (o); len[n] = (s); n++; } while (0)
    if (dy) {
        if (di) {
            uint32_t start = 0, end = 0;
            if (di->rebase_off)         start = di->rebase_off;
            else if (di->bind_off)      start = di->bind_off;
            else if (di->weak_bind_off) start = di->weak_bind_off;
            else if (di->lazy_bind_off) start = di->lazy_bind_off;
            else if (di->export_off)    start = di->export_off;
            if (di->export_size)         end = di->export_off + di->export_size;
            else if (di->lazy_bind_size) end = di->lazy_bind_off + di->lazy_bind_size;
            else if (di->weak_bind_size) end = di->weak_bind_off + di->weak_bind_size;
            else if (di->bind_size)      end = di->bind_off + di->bind_size;
            else if (di->rebase_size)    end = di->rebase_off + di->rebase_size;
            iss += (uint64_t)di->rebase_size + di->bind_size + di->weak_bind_size +
                   di->lazy_bind_size + di->export_size;
            MLO_W(start, end - start);
        }
        iss += (uint64_t)dy->nlocrel * 8 + (uint64_t)dy->nextrel * 8 + (uint64_t)dy->ntoc * 8 +
               (uint64_t)dy->nextrefsyms * 4;
        MLO_W(dy->locreloff, dy->nlocrel * 8);
        const struct linkedit_data_command *led[5] = { c->split, c->fstarts, c->dic, c->drs, c->loh };
        for (int k = 0; k < 5; k++) {
            if (!led[k]) continue;
            iss += led[k]->datasize;
            MLO_W(led[k]->dataoff, led[k]->datasize);
        }
        iss += (uint64_t)dy->nmodtab * 56 + (uint64_t)dy->nindirectsyms * 4 + pad;
        MLO_W(st ? st->symoff : 0, nsyms * 16);
        if (c->hints) {
            iss += (uint64_t)c->hints->nhints * 4;
            MLO_W(c->hints->offset, c->hints->nhints * 4);
        }
        MLO_W(dy->extreloff, dy->nextrel * 8);
        MLO_W(dy->indirectsymoff, dy->nindirectsyms * 4);
        MLO_W(UINT32_MAX, pad);
        MLO_W(dy->tocoff, dy->ntoc * 8);
        MLO_W(dy->modtaboff, dy->nmodtab * 56);
        MLO_W(dy->extrefsymoff, dy->nextrefsyms * 4);
        MLO_W(st ? st->stroff : 0, strsize);
    } else {
        MLO_W(st ? st->symoff : 0, nsyms * 16);
        MLO_W(st ? st->stroff : 0, strsize);
    }
#undef MLO_W
    if (c->sig) iss = mlo_rnd((uint32_t)iss, 16) + (uint64_t)c->sig->datasize;
    if (iss > object_size) {
        mlo_add(v, MLO_CORRUPTS, 0, "the writer would begin %llu bytes before the file",
                (unsigned long long)(iss - object_size));
        return;
    }
    uint32_t P = object_size - (uint32_t)iss, at = P;
    for (int k = 0; k < n; k++) {
        if (src[k] != UINT32_MAX && len[k]) {
            if ((uint64_t)src[k] + len[k] > c->im->size) {
                mlo_add(v, MLO_CORRUPTS, 0, "the writer would copy past the end of the file");
                return;
            }
            w[nw].dest = at; w[nw].src = src[k]; w[nw].size = len[k]; nw++;
        }
        at += len[k];
    }
    uint32_t sig_at = mlo_rnd(at, 16);
    if (c->sig && sig_at != c->sig->dataoff)
        mlo_add(v, MLO_CORRUPTS, 0, "the writer would put the code signature at 0x%x, not 0x%x",
                sig_at, c->sig->dataoff);
    if (!c->sig && c->le && sig_at != mlo_rnd((uint32_t)(c->le->fileoff + c->le->filesize), 16))
        mlo_add(v, MLO_CORRUPTS, 0, "the writer would put the new code signature at 0x%x, not 0x%x",
                sig_at, mlo_rnd((uint32_t)(c->le->fileoff + c->le->filesize), 16));
    /* Every piece but the signature, which the re-sign replaces. */
    struct { const char *name; uint32_t off, size; } p[24];
    int np = 0;
#define MLO_P(nm, o, s) do { if ((s) != 0) { p[np].name = (nm); p[np].off = (o); p[np].size = (s); np++; } } while (0)
    if (di) {
        MLO_P("the rebase opcodes", di->rebase_off, di->rebase_size);
        MLO_P("the bind opcodes", di->bind_off, di->bind_size);
        MLO_P("the weak-bind opcodes", di->weak_bind_off, di->weak_bind_size);
        MLO_P("the lazy-bind opcodes", di->lazy_bind_off, di->lazy_bind_size);
        MLO_P("the export trie", di->export_off, di->export_size);
    }
    if (c->split)   MLO_P("the split info", c->split->dataoff, c->split->datasize);
    if (c->fstarts) MLO_P("the function starts", c->fstarts->dataoff, c->fstarts->datasize);
    if (c->dic)     MLO_P("the data in code", c->dic->dataoff, c->dic->datasize);
    if (c->drs)     MLO_P("the code-signing DRs", c->drs->dataoff, c->drs->datasize);
    if (c->loh)     MLO_P("the linker hints", c->loh->dataoff, c->loh->datasize);
    if (st) {
        MLO_P("the symbol table", st->symoff, st->nsyms * 16);
        MLO_P("the string table", st->stroff, st->strsize);
    }
    if (dy) {
        MLO_P("the local relocations", dy->locreloff, dy->nlocrel * 8);
        MLO_P("the external relocations", dy->extreloff, dy->nextrel * 8);
        MLO_P("the indirect symbol table", dy->indirectsymoff, dy->nindirectsyms * 4);
        MLO_P("the table of contents", dy->tocoff, dy->ntoc * 8);
        MLO_P("the module table", dy->modtaboff, dy->nmodtab * 56);
        MLO_P("the reference table", dy->extrefsymoff, dy->nextrefsyms * 4);
    }
    if (c->hints) MLO_P("the two-level hints", c->hints->offset, c->hints->nhints * 4);
#undef MLO_P
    for (int k = 0; k < np; k++)
        if (!mlo_survives(in, P, w, nw, p[k].off, p[k].size))
            mlo_add(v, MLO_CORRUPTS, 0, "%s (0x%x, %u bytes) would not survive the re-sign",
                    p[k].name, p[k].off, p[k].size);
}

void mlo_check(const mi_image *im, mlo_verdict *v) {
```

In `src/linkedit_order.c`, replace:

```c
    mlo_check_object(&c, v);
    uint32_t object_size = (uint32_t)im->size;
    if (c.dy && (im->hdr->filetype == MH_DYLIB || (im->hdr->flags & MH_DYLDLINK)))
        mlo_dyld_order(&c, v);
    else
        mlo_string_at_end(&c, v, &object_size);
    mlo_room(&c, v);
}
```

with:

```c
    mlo_check_object(&c, v);
    uint32_t object_size = (uint32_t)im->size, pad = 0;
    if (c.dy && (im->hdr->filetype == MH_DYLIB || (im->hdr->flags & MH_DYLDLINK)))
        pad = mlo_dyld_order(&c, v);
    else
        pad = mlo_string_at_end(&c, v, &object_size);
    mlo_room(&c, v);
    int blocking = 0;
    for (int k = 0; k < v->n; k++)
        if (v->f[k].kind == MLO_REFUSES && !v->f[k].newer) blocking = 1;
    if (blocking) return;
    int before = v->n;
    mlo_simulate(&c, v, object_size, pad);
    v->corrupting = v->n > before || v->dropped;
}

/* The verdict on one slice, into the whole file's. `label` is "" for a
 * thin file, else "slice NAME: ". */
static int mlo_slice_verdict(const uint8_t *buf, size_t size, const char *label, char *refusal,
                             size_t rsz, char *corrupt, size_t csz, int *worst) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, size, &im) != 0) return -1;
    mlo_verdict v;
    mlo_check(&im, &v);
    if (v.refusal >= 0 && *worst < 1) {
        snprintf(refusal, rsz, "%s%s", label, v.f[v.refusal].text);
        *worst = 1;
    }
    if (v.corrupting && !corrupt[0]) {
        size_t at = (size_t)snprintf(corrupt, csz, "%s", label);
        for (int k = 0; k < v.n && at < csz; k++)
            if (v.f[k].kind == MLO_CORRUPTS)
                at += (size_t)snprintf(corrupt + at, csz - at, "%s%s", at > strlen(label) ? "; " : "",
                                       v.f[k].text);
    }
    return 0;
}

int mlo_file_verdict(const uint8_t *buf, size_t size, char *refusal, size_t rsz,
                     char *corrupt, size_t csz) {
    int worst = 0;
    snprintf(refusal, rsz, "ok");
    corrupt[0] = 0;
    uint32_t narch;
    int swapped;
    if (size >= 4 && (buf[0] == 0xca || buf[0] == 0xbe) && mfat_parse(buf, size, &narch, &swapped) == 0) {
        char unchecked[64] = "";
        for (uint32_t i = 0; i < narch; i++) {
            mfat_arch a;
            char name[32], label[48];
            mfat_get(buf, swapped, i, &a);
            ma_describe(a.cputype, a.cpusubtype, name);
            snprintf(label, sizeof label, "slice %s: ", name);
            if (mlo_slice_verdict(buf + a.offset, a.size, label, refusal, rsz, corrupt, csz,
                                  &worst) != 0 && !unchecked[0])
                snprintf(unchecked, sizeof unchecked, "not checked: slice %s is not a 64-bit Mach-O",
                         name);
        }
        if (worst == 0 && unchecked[0]) snprintf(refusal, rsz, "%s", unchecked);
    } else if (mlo_slice_verdict(buf, size, "", refusal, rsz, corrupt, csz, &worst) != 0) {
        return -1;
    }
    if (corrupt[0]) return 2;
    return worst;
}
```

- [ ] **Step 4: Run it to see it pass**

Run: build (rebuild check), then `"$B/linkedit_order_test"`.
Expected: `linkedit_order_test: all cases pass`. The whole suite: 28 tests pass.

- [ ] **Step 5: Mutation proof** (file `src/linkedit_order.c`)

1. In `src/linkedit_order.c`, replace `    uint32_t strsize = nsyms ? st->strsize : 0;` with `    uint32_t strsize = st ? st->strsize : 0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `nsyms-0: corrupting is 0`.
2. In `src/linkedit_order.c`, replace `            iss += (uint64_t)di->rebase_size + di->bind_size + di->weak_bind_size +` with `            iss += (uint64_t)di->bind_size + di->weak_bind_size +`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `canonical-unsigned: corrupting is 1`.
3. In `src/linkedit_order.c`, replace `            MLO_W(start, end - start);` with `            MLO_W(start, di->rebase_size);`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `canonical: corrupting is 1`.
4. In `src/linkedit_order.c`, replace `    if (c->sig) iss = mlo_rnd((uint32_t)iss, 16) + (uint64_t)c->sig->datasize;` with `    if (c->sig) iss = iss + (uint64_t)c->sig->datasize;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `canonical: corrupting is 1`.
5. In `src/linkedit_order.c`, replace `        if (x < P) { x = end < P ? end : P; continue; }` with `        if (0) { continue; }`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no dysymtab, a hole: nothing found`.
6. In `src/linkedit_order.c`, replace `        if (memcmp(in + w[k].src + (x - w[k].dest), in + x, stop - x) != 0) return 0;` with `        (void)0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `nsyms-0: corrupting is 0`.
7. In `src/linkedit_order.c`, replace `        if (k == nw) return 0;   /* nothing the writer puts there */` with `        if (k == nw) return 1;   /* nothing the writer puts there */`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `nsyms-0-short-strtab: corrupting is 0`.
8. In `src/linkedit_order.c`, replace `        if (v->f[k].kind == MLO_REFUSES && !v->f[k].newer) blocking = 1;` with `        if (0) blocking = 1;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `corrupting is 1, want 0`.
9. In `src/linkedit_order.c`, replace `            mlo_add(v, MLO_REFUSES, 1, "malformed object (unknown load command %u)", i);` with `            mlo_add(v, MLO_REFUSES, 0, "malformed object (unknown load command %u)", i);`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `an unknown command and a hole`.
10. In `src/linkedit_order.c`, replace `            snprintf(label, sizeof label, "slice %s: ", name);` with `            snprintf(label, sizeof label, "%s: ", name);`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `fat: the other slice`.
11. In `src/linkedit_order.c`, replace `    if (corrupt[0]) return 2;` with `    (void)0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `fat: a corrupting slice`.

- [ ] **Step 6: Commit**

```bash
git add src/linkedit_order.h src/linkedit_order.c tests/linkedit_fixture.h tests/linkedit_order_test.c
git commit -m "feat(linkedit_order): find what codesign_allocate would accept and re-sign corrupt

codesign_allocate never updates a piece's offset: it copies the file up to
object_size minus the sum of the pieces' sizes and writes the pieces back
one after another. mlo_check now simulates that writer, both branches, and
compares each piece's bytes with what the output would hold at its offset.
A hole in the dyld info, or a string table without symbols, is found; a
hole the 16-rounding absorbs is not. mlo_file_verdict gives one verdict for
a whole file, thin or fat, as the tool checks every slice.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 4: `info`'s resign lines (M1)

**Files:**
- Create: `tests/mklinkedit.c`
- Modify: `cli/drydock-macho-rewrite.c` (`#include "arch_names.h"` at `:61`; before `static int cmd_info(const char *path, int thin_only) {`; `cmd_info`'s thin and fat paths)
- Modify: `tests/cli_test.sh` (a block before its last three lines, `reached_end=1` …)

**Interfaces:**
- Consumes: Task 3's `mlo_file_verdict`; in `tests/cli_test.sh`, `ok`, `bad`, `$CC`, `$HERE`, `$T`, `$BIN/makefat`, and `"$T/chained.in"` (the `mkchained make` image, built at `:672`).
- Produces:
  - `info`'s last line for a thin file, or after a fat file's slices: `resign 10.9: ok`, or 10.9's refusal (`resign 10.9: slice x86_64h: malformed object (unknown load command 8)`), or `resign 10.9: not checked: slice i386 is not a 64-bit Mach-O`; and, when some slice is corrupting, `resign corrupt: …`. A fat header with no slices prints neither.
  - `tests/mklinkedit.c`: `mklinkedit list` (NAME TAB corrupting TAB tool, one per variant), `mklinkedit make NAME OUT`, and `mklinkedit pieces FILE` (NAME OFFSET SIZE for each non-empty piece, read without `src/`).
  - In `tests/cli_test.sh`: `resign FILE`, which prints the `resign 10.9:` verdict; the files `$T/lk_canonical`, `$T/lk_bind-first`, `$T/lk_note`, `$T/lk_hole-16`.

- [ ] **Step 1: Write the failing tests and the fixture writer**

Create `tests/mklinkedit.c` with:

```c
/* tests/mklinkedit.c -- writes one of tests/linkedit_fixture.h's variants,
 * for tests/codesign_order_test.sh.
 *   mklinkedit list              every variant: NAME TAB corrupting TAB tool
 *   mklinkedit make NAME OUT
 *   mklinkedit pieces FILE       NAME OFFSET SIZE per non-empty piece, read
 *                                apart from src/ */
#include <stdio.h>
#include "linkedit_fixture.h"

static int pieces(const char *path) {
    static uint8_t b[1 << 24];
    FILE *f = fopen(path, "rb");
    if (!f) return 2;
    size_t n = fread(b, 1, sizeof b, f);
    fclose(f);
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    if (n < sizeof *h || h->magic != MH_MAGIC_64) return 2;
    uint8_t *p = (uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
        struct load_command *lc = (struct load_command *)p;
        switch (lc->cmd) {
        case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY: {
            struct dyld_info_command *d = (struct dyld_info_command *)lc;
            const char *nm[5] = { "rebase", "bind", "weak", "lazy", "export" };
            uint32_t *o = &d->rebase_off;
            for (int k = 0; k < 5; k++) if (o[2 * k + 1]) printf("%s %u %u\n", nm[k], o[2 * k], o[2 * k + 1]);
            break;
        }
        case LC_SYMTAB: {
            struct symtab_command *s = (struct symtab_command *)lc;
            if (s->nsyms) printf("symtab %u %u\n", s->symoff, s->nsyms * 16);
            if (s->strsize) printf("strtab %u %u\n", s->stroff, s->strsize);
            break;
        }
        case LC_DYSYMTAB: {
            struct dysymtab_command *d = (struct dysymtab_command *)lc;
            if (d->nindirectsyms) printf("indirect %u %u\n", d->indirectsymoff, d->nindirectsyms * 4);
            if (d->nlocrel) printf("locrel %u %u\n", d->locreloff, d->nlocrel * 8);
            if (d->nextrel) printf("extrel %u %u\n", d->extreloff, d->nextrel * 8);
            break;
        }
        case LC_FUNCTION_STARTS: case LC_DATA_IN_CODE: case LC_DYLIB_CODE_SIGN_DRS:
        case LC_SEGMENT_SPLIT_INFO: {
            struct linkedit_data_command *l = (struct linkedit_data_command *)lc;
            if (l->datasize) printf("led-0x%x %u %u\n", lc->cmd, l->dataoff, l->datasize);
            break;
        }
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    static uint8_t buf[LKF_CAP];
    if (argc == 2 && strcmp(argv[1], "list") == 0) {
        for (size_t k = 0; k < LKF_NVARIANTS; k++)
            printf("%s\t%d\t%s\n", lkf_variants[k].name, lkf_variants[k].corrupting,
                   lkf_variants[k].tool ? lkf_variants[k].tool : "");
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "pieces") == 0) return pieces(argv[2]);
    if (argc == 4 && strcmp(argv[1], "make") == 0) {
        for (size_t k = 0; k < LKF_NVARIANTS; k++) {
            if (strcmp(lkf_variants[k].name, argv[2]) != 0) continue;
            size_t n = lkf_make(buf, &lkf_variants[k]);
            FILE *f = fopen(argv[3], "wb");
            if (!n || !f || fwrite(buf, 1, n, f) != n) return 2;
            return fclose(f) == 0 ? 0 : 2;
        }
        fprintf(stderr, "mklinkedit: no variant '%s'\n", argv[2]);
        return 2;
    }
    fprintf(stderr, "usage: mklinkedit list | make NAME OUT | pieces FILE\n");
    return 2;
}
```

In `tests/cli_test.sh`, replace:

```sh

reached_end=1
```

with:

```sh

# ---- __LINKEDIT in codesign_allocate's order ---------------------------------
# tests/linkedit_fixture.h's variants, written by mklinkedit. `resign 10.9:`
# is src/linkedit_order.h's verdict, which tests/codesign_order_test.sh holds
# to 10.9's own codesign_allocate.
"$CC" -O2 -o "$T/mklinkedit" "$HERE/mklinkedit.c"
resign() { "$DRYDOCK_MACHO_REWRITE" info "$1" 2>/dev/null | sed -n 's/^resign 10\.9: //p'; }
for v in canonical bind-first note hole-16; do
    "$T/mklinkedit" make "$v" "$T/lk_$v"
done
[ "$(resign "$T/lk_canonical")" = ok ] \
    && [ "$(resign "$T/lk_bind-first")" = "file not in an order that can be processed (dyld_info out of place)" ] \
    && ok "info: resign 10.9 says what 10.9's codesign_allocate would" \
    || bad "info resign" "[$(resign "$T/lk_canonical")] [$(resign "$T/lk_bind-first")]"
[ "$(resign "$T/chained.in")" = "malformed object (unknown load command 3)" ] \
    && ok "info: ... naming an unknown load command by its index, as the tool does" \
    || bad "info resign chained" "[$(resign "$T/chained.in")]"
"$DRYDOCK_MACHO_REWRITE" info "$T/lk_hole-16" | grep -q '^resign corrupt: .*would not survive the re-sign' \
    && [ "$(resign "$T/lk_hole-16")" = ok ] \
    && ! "$DRYDOCK_MACHO_REWRITE" info "$T/lk_canonical" | grep -q '^resign corrupt' \
    && ok "info: a file the tool would accept and re-sign corrupt gets a resign corrupt line" \
    || bad "info resign corrupt" "$("$DRYDOCK_MACHO_REWRITE" info "$T/lk_hole-16" | grep '^resign')"
"$BIN/makefat" "$T/lk_fat_info" "$T/lk_bind-first" 0x1000007 3 12 "$T/lk_note" 0x1000007 8 12
"$BIN/makefat" "$T/lk_fat_info2" "$T/lk_canonical" 0x1000007 3 12 "$T/lk_note" 0x1000007 8 12
[ "$(resign "$T/lk_fat_info")" = "slice x86_64: file not in an order that can be processed (dyld_info out of place)" ] \
    && [ "$(resign "$T/lk_fat_info2")" = "slice x86_64h: malformed object (unknown load command 8)" ] \
    && [ "$("$DRYDOCK_MACHO_REWRITE" info "$T/lk_fat_info2" | grep -c '^resign 10.9: ')" -eq 1 ] \
    && ok "info: a fat file gets one resign line, the whole file's, slice by slice" \
    || bad "info resign fat" "[$(resign "$T/lk_fat_info")] [$(resign "$T/lk_fat_info2")]"

reached_end=1
```

- [ ] **Step 2: Run it to see it fail**

Run: build (rebuild check), then `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B"`.
Expected: exit 1, and exactly these four `FAIL` lines:

```
FAIL info resign: [] []
FAIL info resign chained: []
FAIL info resign corrupt:
FAIL info resign fat: [] []
```

- [ ] **Step 3: Print the verdict**

In `cli/drydock-macho-rewrite.c`, replace:

```c
#include "arch_names.h"

```

with:

```c
#include "arch_names.h"
#include "linkedit_order.h"

```

In `cli/drydock-macho-rewrite.c`, replace:

```c

static int cmd_info(const char *path, int thin_only) {
```

with:

```c

/* Whether 10.9's codesign_allocate can re-sign the whole file, and whether
 * any host's would re-sign it corrupt. */
static void info_resign(const uint8_t *buf, size_t size) {
    char refusal[256], corrupt[512];
    mlo_file_verdict(buf, size, refusal, sizeof refusal, corrupt, sizeof corrupt);
    printf("resign 10.9: %s\n", refusal);
    if (corrupt[0]) printf("resign corrupt: %s\n", corrupt);
}

static int cmd_info(const char *path, int thin_only) {
```

In `cli/drydock-macho-rewrite.c`, replace:

```c
        info_image(&im, path);
        mi_close(&im);
```

with:

```c
        info_image(&im, path);
        info_resign(im.buf, im.size);
        mi_close(&im);
```

In `cli/drydock-macho-rewrite.c`, replace:

```c
        }
        free(buf);
```

with:

```c
        }
        if (narch) info_resign(buf, size);
        free(buf);
```

- [ ] **Step 4: Run it to see it pass**

Run: build (rebuild check), then `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B"`.
Expected: `cli_test: 0 failure(s)`, and the existing `info fat: a fat header with no slices is reported as 0 slices (0)` still passes. The whole suite: 28 tests pass.

- [ ] **Step 5: Mutation proof** (file `cli/drydock-macho-rewrite.c`)

1. In `cli/drydock-macho-rewrite.c`, replace `        if (narch) info_resign(buf, size);` with `        info_resign(buf, size);`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `info fat 0 slices`.
2. In `cli/drydock-macho-rewrite.c`, replace this:

   ```c
           info_image(&im, path);
           info_resign(im.buf, im.size);
   ```

   with this:

   ```c
           info_image(&im, path);
   ```

   It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `info resign`.
3. In `cli/drydock-macho-rewrite.c`, replace `    if (corrupt[0]) printf("resign corrupt: %s\n", corrupt);` with `    (void)0;`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `info resign corrupt`.
4. In `cli/drydock-macho-rewrite.c`, replace `        if (narch) info_resign(buf, size);` with `        (void)0;`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `info resign fat`.

- [ ] **Step 6: Commit**

```bash
git add cli/drydock-macho-rewrite.c tests/mklinkedit.c tests/cli_test.sh
git commit -m "feat(info): say whether 10.9's codesign can re-sign the file

info's last line is now the whole file's verdict from 10.9's
codesign_allocate: ok, its refusal in its own words (for a fat file, the
first slice it would refuse), or not checked for a slice this does not
model; and a resign corrupt line when some slice would be accepted and
re-signed corrupt. mklinkedit writes the fixture's variants for the shell
suites.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 5: The 10.9 oracle, a local ctest entry (M1)

**Files:**
- Create: `tests/codesign_order_test.sh`
- Modify: `CMakeLists.txt` (after the `linkedit_order_test` block)

**Interfaces:**
- Consumes: Task 4's `info` lines and `mklinkedit list|make|pieces`; 10.9's `codesign_allocate` (via `xcrun -f`, else `PATH`).
- Produces: the ctest entry `codesign_order_test`, which exits 77 (SKIP, with its reason) unless the tool carries the string `cctools-862`, and otherwise requires, for every variant and for each variant after `load-command delete codesig` (the pass runs on those once Task 7 lands):
  - the tool refuses ⇔ `resign 10.9:` is not `ok`, and every "…"-separated part of the verdict appears in the tool's stderr;
  - the tool accepts ⇔ `resign 10.9: ok`, and some piece's bytes, at the offsets the input's load commands give, differ in the tool's output ⇔ `info` prints `resign corrupt:`;
  - and at least 40 files, at least one refused and one written corrupt, so a vacuous pass is a failure.

**Plan decisions.**

- **The oracle runs `codesign_allocate` alone** (`-i F -a x86_64 16384 -o OUT`): no signing, no keychain, and the same checks and writer `codesign` uses.
- **Its equality is defined for both outcomes** (the spec's I2): a refused file is compared by message, an accepted one by bytes, which is the only way to see the silent corruption.
- **Local only, and a gate.** The Global Constraints make running it on 10.9 the close of each milestone. It adds about 3 s to the suite.

- [ ] **Step 1: Write the oracle and its ctest entry**

In `CMakeLists.txt`, replace:

```cmake

add_executable(relations_test tests/relations_test.c)
```

with:

```cmake

# 10.9's own codesign_allocate as the oracle for linkedit_order_test's
# expectations. It SKIPs anywhere else, CI included.
add_executable(mklinkedit tests/mklinkedit.c)
target_compile_options(mklinkedit PRIVATE -O2 -Wall -Wextra -Wno-unused-function)
add_test(NAME codesign_order_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/codesign_order_test.sh" "$<TARGET_FILE_DIR:drydock-macho-rewrite>")
set_tests_properties(codesign_order_test PROPERTIES SKIP_RETURN_CODE 77)

add_executable(relations_test tests/relations_test.c)
```

Create `tests/codesign_order_test.sh` with:

```sh
#!/bin/sh
# tests/codesign_order_test.sh -- `info`'s resign lines (src/linkedit_order.h)
# must be 10.9's own codesign_allocate's verdict, on every
# tests/linkedit_fixture.h variant and on each after the pass has packed it.
#
#   sh tests/codesign_order_test.sh <bindir>
#
# For a file the tool refuses, `resign 10.9:` must be its message ("…" stands
# for words that name offsets or files). For one it accepts, `resign 10.9:`
# must say ok, and `resign corrupt:` must appear exactly when some piece's
# bytes, at the offset its load command gives, differ in what the tool wrote.
#
# Local only: it SKIPs, saying why, unless the codesign_allocate here is
# cctools-862's (10.9's Command Line Tools). Any other tool's verdicts
# legitimately differ.
set -u

BIN="${1:?usage: codesign_order_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
MK="$BIN/mklinkedit"
for x in "$DMR" "$MK"; do
    [ -x "$x" ] || { echo "codesign_order_test: $x not found or not executable" >&2; exit 1; }
done
CA=$(xcrun -f codesign_allocate 2>/dev/null) || CA=$(command -v codesign_allocate 2>/dev/null) || CA=
[ -n "$CA" ] && [ -x "$CA" ] || { echo "SKIP: no codesign_allocate here"; exit 77; }
strings "$CA" | grep -qx 'cctools-862' ||
    { echo "SKIP: $CA is not cctools-862's, whose verdicts this test pins"; exit 77; }

T=$(mktemp -d "${TMPDIR:-/tmp}/codesign-order.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0 files=0 refused=0 corrupt=0

# Does every "…"-separated part of $1 appear in file $2?
matches() {
    printf '%s\n' "$1" | sed 's/…/\
/g' | while IFS= read -r part; do
        [ -z "$part" ] || grep -qF -- "$part" "$2" || exit 1
    done
}

check() {
    f=$1
    files=$((files + 1))
    "$DMR" info "$f" >"$T/info" 2>/dev/null
    ours=$(sed -n 's/^resign 10\.9: //p' "$T/info")
    said_corrupt=$(grep -c '^resign corrupt: ' "$T/info")
    rm -f "$T/out"
    rc=0; "$CA" -i "$f" -a x86_64 16384 -o "$T/out" 2>"$T/err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        refused=$((refused + 1))
        if [ "$ours" = ok ] || ! matches "$ours" "$T/err"; then
            echo "FAIL $f: the tool says [$(cat "$T/err")], resign 10.9 says [$ours]"
            fail=$((fail + 1))
        fi
        return
    fi
    if [ "$ours" != ok ]; then
        echo "FAIL $f: the tool accepts it, resign 10.9 says [$ours]"
        fail=$((fail + 1))
        return
    fi
    moved=
    "$MK" pieces "$f" >"$T/pieces"
    while read -r name off size; do
        dd if="$f" of="$T/a" bs=1 skip="$off" count="$size" 2>/dev/null
        dd if="$T/out" of="$T/b" bs=1 skip="$off" count="$size" 2>/dev/null
        cmp -s "$T/a" "$T/b" || moved="$moved $name"
    done <"$T/pieces"
    if [ -n "$moved" ]; then corrupt=$((corrupt + 1)); fi
    if { [ -n "$moved" ] && [ "$said_corrupt" -eq 0 ]; } || { [ -z "$moved" ] && [ "$said_corrupt" -ne 0 ]; }; then
        echo "FAIL $f: the tool moved [$moved]; resign corrupt said $said_corrupt line(s)"
        fail=$((fail + 1))
    fi
}

"$MK" list | while IFS='	' read -r name c tool; do echo "$name"; done >"$T/names"
while read -r name; do
    "$MK" make "$name" "$T/$name" || { echo "FAIL mklinkedit make $name"; fail=$((fail + 1)); continue; }
    check "$T/$name"
    # and packed: deleting the signature changes a piece, so the pass runs
    rc=0; printf 'allow-unmatched\nload-command delete codesig\n' |
        "$DMR" "$T/$name" "$T/$name.packed" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && check "$T/$name.packed"
done <"$T/names"

if [ "$files" -lt 40 ] || [ "$refused" -eq 0 ] || [ "$corrupt" -eq 0 ]; then
    echo "FAIL: the corpus is too thin to mean anything: $files files, $refused refused, $corrupt corrupting"
    fail=$((fail + 1))
fi
echo "codesign_order_test: $files files ($refused refused by the tool, $corrupt written corrupt), $fail failure(s)"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it**

Run: re-run the configure step, build (rebuild check), then `sh tests/codesign_order_test.sh "$B"`.
Expected, on 10.9: `codesign_order_test: 83 files (52 refused by the tool, 5 written corrupt), 0 failure(s)` (the numbers are at Task 9's end; at this task the pass does not yet run, so the `.packed` copies of signed variants are the unpacked file with the signature's command deleted and the tool refuses more of them). The whole suite: 29 tests pass. On any other host it prints `SKIP: … is not cctools-862's, whose verdicts this test pins` and ctest reports it skipped.

This task has no "see it fail" of its own: the test passes the first time because `mlo_check` is already right. The mutation list is the evidence that it can fail: each row makes `mlo_check` disagree with the tool in one way the unit test alone would not name.

- [ ] **Step 3: Mutation proof** (file `src/linkedit_order.c`; the test is the oracle)

1. In `src/linkedit_order.c`, replace `        MLO_ORDER("code signature data out of place");` with `        MLO_ORDER("code signature misplaced");`. It must fail `sh tests/codesign_order_test.sh "$B"`, with a `FAIL` line containing `the tool says`.
2. In `src/linkedit_order.c`, replace `        if (memcmp(in + w[k].src + (x - w[k].dest), in + x, stop - x) != 0) return 0;` with `        (void)0;`. It must fail `sh tests/codesign_order_test.sh "$B"`, with a `FAIL` line containing `resign corrupt said 0 line(s)`.
3. In `src/linkedit_order.c`, replace `            if (di->export_off != offset && di->weak_bind_size != 0 && di->lazy_bind_size != 0)` with `            if (di->export_off != offset && di->weak_bind_size != 0 && di->lazy_bind_size != 0 && 0)`. It must fail `sh tests/codesign_order_test.sh "$B"`, with a `FAIL` line containing `resign 10.9 says [ok]`.

- [ ] **Step 4: Commit**

```bash
git add tests/codesign_order_test.sh CMakeLists.txt
git commit -m "test(linkedit_order): 10.9's codesign_allocate is the oracle, byte for byte

codesign_order_test runs cctools-862's codesign_allocate over every
fixture variant and compares with info's verdict: a refusal by its
message, an acceptance by comparing each piece's bytes before and after,
which is the only way to see a file the tool re-signs corrupt. It SKIPs
anywhere else, CI included.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 6: The pass: `mlo_pack` and `mlo_changed` (M2)

**Files:**
- Create: `src/linkedit_pack.c`
- Modify: `src/linkedit_order.h` (before `#endif /* DRYDOCK_LINKEDIT_ORDER_H */`), `CMakeLists.txt` (`add_library(drydockcore …)`)
- Modify: `tests/linkedit_order_test.c` (before `int main(void) {`; `main`)

**Interfaces:**
- Consumes: Tasks 1–3's `mlo_check` (as a postcondition); `mi_wrap`, `mi_find_segment`.
- Produces:
  - `enum { MLO_PACKED = 0, MLO_UNCHANGED = 1, MLO_DECLINED = 2, MLO_FAILED = -1, MLO_NOMEM = -2 };`
  - `typedef struct { uint64_t before, after, dropped; } mlo_pack_report;`
  - `int mlo_pack(uint8_t **pbuf, size_t *psize, mlo_pack_report *rep, char *why, size_t whysz);` — on `MLO_PACKED` the old buffer is freed and `*pbuf`/`*psize` name the packed image; on every other return the image is left alone and `why` says why (`MLO_DECLINED`, `MLO_FAILED`).
  - `int mlo_changed(const uint8_t *a, size_t asize, const uint8_t *b, size_t bsize);`

**Plan decisions.**

- **The piece model is the spec's Decision 2**, with ld64's order and the two modern blobs in cctools-1035's slots. Each piece keeps its bytes and size; the pass concatenates. Three paddings only: the 8-rounding where the input had it, the 16-rounding before the signature, and (spec "(plan)") 16-alignment of the symbol table in a signed slice without `LC_DYSYMTAB`.
- **A zero-size piece keeps an offset that already passes**, else goes where ld64 puts one: an empty dyld-info stream to 0, an empty split, function-starts, data-in-code or blob piece to the running offset unless it is at 0, DRs and hints to the running offset.
- **The declines** are the spec's list plus the two "(plan)" ones: a 16-misaligned `__LINKEDIT` in a signed slice with `LC_DYSYMTAB`, and weak-bind, lazy-bind and export opcodes without rebase or bind.
- **Postconditions**, any failure being `MLO_FAILED`: every piece's bytes at its new offset; no header byte changed but the piece offsets and `__LINKEDIT`'s `filesize` and `vmsize`; the pieces tile `__LINKEDIT` in order with no gap but the paddings; and `mlo_check` finds no order refusal (for an image with a modern blob, which 862's walk has no slot for, the tiling stands in) and no corruption. Built this way they never fire; they are there for the next change to this file.
- **`mlo_changed` compares pieces**, and, when it cannot list them (an unknown command that may carry an offset), `__LINKEDIT`'s extent and bytes, so a header-only edit of such an image is still "no change".

- [ ] **Step 1: Write the failing tests**

In `tests/linkedit_order_test.c`, replace:

```c

int main(void) {
```

with:

```c

/* ---- the pass ---- */

static int pack(uint8_t **buf, size_t *n, mlo_pack_report *r, char *why) {
    return mlo_pack(buf, n, r, why, 256);
}

/* Every variant whose only faults are where its pieces lie comes out in
 * order, re-signing correctly, every piece's bytes intact. */
static void test_the_pass_puts_each_variant_in_order(void) {
    static const char *const fixable[] = {
        "bind-first", "gap-before-rebase", "export-inside", "gap-after-export",
        "symtab-before-fstarts", "dic-stale", "gap-before-symtab", "strtab-first",
        "strtab-past-rounding", "sig-off-16", "sig-late", "tail-after-sig", "tail-after-strtab",
        "hole-16", "hole-16-unsigned", "stale-empty-rebase", "hole-absorbed", "export-last",
        "no-dysymtab-hole", "no-dysymtab-drs8" };
    for (size_t k = 0; k < sizeof fixable / sizeof fixable[0]; k++) {
        const lkf_variant *w = variant(fixable[k]);
        uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
        size_t n = lkf_make(buf, w);
        uint8_t *before = (uint8_t *)malloc(n);
        memcpy(before, buf, n);
        mlo_pack_report r;
        char why[256] = "";
        int rc = pack(&buf, &n, &r, why);
        CHECK(rc == MLO_PACKED, "%s: packed (got %d: %s)", w->name, rc, why);
        mlo_verdict v;
        check(buf, n, &v);
        CHECK(v.refusal < 0 && !v.corrupting, "%s: in order after the pass (%s)", w->name,
              v.refusal >= 0 ? v.f[v.refusal].text : "corrupting");
        /* and in the canonical layout, byte for byte */
        static uint8_t canon[LKF_CAP];
        size_t cn = lkf_build(canon, (w->opts & LKF_NOSIG) ?
                              "rebase bind weak lazy export fstarts dic drs symtab indirect strtab" :
                              LKF_CANON, w->opts);
        if (strcmp(w->name, "stale-empty-rebase") != 0 && strcmp(w->name, "strtab-past-rounding") != 0 &&
            !(w->opts & LKF_NODYSYMTAB))
            CHECK(n == cn && memcmp(buf, canon, n) == 0, "%s: the canonical bytes", w->name);
        free(before);
        free(buf);
    }
}

static void test_the_pass_leaves_an_ordered_image_alone(void) {
    static const char *const ordered[] = { "canonical", "canonical-unsigned", "strtab-at-rounding" };
    for (size_t k = 0; k < sizeof ordered / sizeof ordered[0]; k++) {
        uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
        size_t n = lkf_make(buf, variant(ordered[k]));
        uint8_t *was = buf;
        mlo_pack_report r;
        char why[256] = "";
        int rc = pack(&buf, &n, &r, why);
        CHECK(rc == MLO_UNCHANGED && buf == was, "%s: unchanged (got %d: %s)", ordered[k], rc, why);
        free(buf);
    }
    /* the repo's own fixture, which tests/EXPECTED's digest depends on */
    mi_image im;
    if (mi_open("tests/fixture.macho", &im) != 0) {
        printf("FAIL: tests/fixture.macho does not open (run from the source directory)\n");
        fails++;
        return;
    }
    size_t n = im.size;
    uint8_t *buf = mi_release(&im);
    mlo_pack_report r;
    char why[256] = "";
    int rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_UNCHANGED, "tests/fixture.macho: unchanged (got %d: %s)", rc, why);
    free(buf);
}

/* A zero-size piece keeps a zero offset, and a stale one is set where
 * ld64 puts it. */
static void test_the_pass_places_empty_pieces(void) {
    uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
    size_t n = lkf_make(buf, variant("dic-stale"));
    mlo_pack_report r;
    char why[256];
    pack(&buf, &n, &r, why);
    struct linkedit_data_command *dic = lkf_led(buf, LKF_LC_DIC);
    struct linkedit_data_command *drs = lkf_led(buf, LKF_LC_DRS);
    CHECK(dic->dataoff == drs->dataoff, "an empty data in code at the running offset (0x%x, 0x%x)",
          dic->dataoff, drs->dataoff);
    free(buf);
    buf = (uint8_t *)malloc(LKF_CAP);
    n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs symtab indirect strtab @16 sig", 0);
    lkf_led(buf, LKF_LC_DIC)->dataoff = 0;
    pack(&buf, &n, &r, why);
    CHECK(lkf_led(buf, LKF_LC_DIC)->dataoff == 0, "an empty data in code at 0 stays at 0");
    free(buf);
    buf = (uint8_t *)malloc(LKF_CAP);
    n = lkf_make(buf, variant("stale-empty-rebase"));
    pack(&buf, &n, &r, why);
    CHECK(lkf_di(buf)->rebase_off == 0 && lkf_di(buf)->bind_off == LKF_LE,
          "a stale empty rebase stream gets offset 0 (rebase 0x%x, bind 0x%x)",
          lkf_di(buf)->rebase_off, lkf_di(buf)->bind_off);
    free(buf);
}

/* The 8-rounding after an odd indirect table stays where the input had it,
 * and the report counts what was dropped. */
static void test_the_pass_keeps_the_rounding(void) {
    uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
    size_t n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs symtab indirect @8 "
                         "strtab @16 sig", 0);
    mlo_pack_report r;
    char why[256];
    int rc = pack(&buf, &n, &r, why);
    struct symtab_command *st = lkf_st(buf);
    struct dysymtab_command *dy = lkf_dy(buf);
    uint32_t ind_end = dy->indirectsymoff + dy->nindirectsyms * 4;
    CHECK(rc == MLO_PACKED && st->stroff == ((ind_end + 7) & ~7u) && st->stroff != ind_end,
          "the string table stays at the 8-rounding (0x%x after 0x%x)", st->stroff, ind_end);
    free(buf);
    buf = (uint8_t *)malloc(LKF_CAP);
    n = lkf_make(buf, variant("hole-16"));
    rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_PACKED && r.before == 0x110 && r.after == 0x100 && r.dropped == 0x14,
          "the report: 0x%llx -> 0x%llx, 0x%llx dropped", (unsigned long long)r.before,
          (unsigned long long)r.after, (unsigned long long)r.dropped);
    free(buf);
}

/* Each thing the pass cannot account for, and the image left alone. */
static void test_the_pass_declines(void) {
    static const struct { const char *variant, *why; } no[] = {
        { "note", "may name a range of the file the pass does not know" },
        { "fvmfile", "may name a range of the file the pass does not know" },
        { "two-fstarts", "more than one of the function starts" },
        { "fstarts-dataoff-0", "the function starts lies outside __LINKEDIT" },
        { "no-rebase-no-bind", "which codesign_allocate cannot lay out" },
    };
    for (size_t k = 0; k < sizeof no / sizeof no[0]; k++) {
        uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
        size_t n = lkf_make(buf, variant(no[k].variant));
        uint8_t *copy = (uint8_t *)malloc(n);
        memcpy(copy, buf, n);
        uint8_t *was = buf;
        size_t n0 = n;
        mlo_pack_report r;
        char why[256] = "";
        int rc = pack(&buf, &n, &r, why);
        CHECK(rc == MLO_DECLINED && strstr(why, no[k].why) && buf == was && n == n0 &&
              memcmp(buf, copy, n) == 0, "%s: declined (got %d: %s)", no[k].variant, rc, why);
        free(copy);
        free(buf);
    }
    /* and the layout checks, on an image made to fail each */
    struct { const char *what, *why; } lay[] = {
        { "a piece outside __LINKEDIT", "lies outside __LINKEDIT" },
        { "overlapping pieces", "overlaps" },
        { "__LINKEDIT not ending the file", "__LINKEDIT does not end the file" },
        { "a section in __LINKEDIT", "lies in __LINKEDIT" },
        { "a section with relocations", "has relocation entries" },
        { "__LINKEDIT's vmsize would overlap", "would overlap __DATA" },
    };
    for (int k = 0; k < 6; k++) {
        uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
        size_t n = lkf_make(buf, variant("bind-first"));
        struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
        struct segment_command_64 *da = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_DATA);
        struct section_64 *data = (struct section_64 *)(da + 1);
        switch (k) {
        case 0: lkf_led(buf, LKF_LC_DRS)->dataoff = 0x1100; break;
        case 1: lkf_led(buf, LKF_LC_DRS)->dataoff = lkf_st(buf)->symoff; break;
        case 2: le->filesize -= 16; break;
        case 3: data->offset = LKF_LE + 0x40; break;
        case 4: data->reloff = LKF_LE; data->nreloc = 1; break;
        case 5: {
            /* a bigger pack than the page, and __DATA right after it in vm */
            uint8_t *big = (uint8_t *)realloc(buf, LKF_CAP + 0x2000);
            buf = big;
            n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs symtab indirect "
                          "strtab:5000 @16 sig", 0);
            le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
            da = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_DATA);
            le->vmsize = 0x1000;
            da->vmaddr = le->vmaddr + 0x1000;
            break;
        }
        }
        mlo_pack_report r;
        char why[256] = "";
        int rc = pack(&buf, &n, &r, why);
        CHECK(rc == MLO_DECLINED && strstr(why, lay[k].why), "%s: declined (got %d: %s)",
              lay[k].what, rc, why);
        free(buf);
    }
}

/* ---- the observed change ---- */

static void test_what_counts_as_a_change(void) {
    static uint8_t a[LKF_CAP], b[LKF_CAP];
    size_t na = lkf_make(a, variant("canonical"));
    memcpy(b, a, na);
    CHECK(!mlo_changed(a, na, b, na), "the same image: no change");
    ((struct dylib_command *)lkf_lc(b, LKF_LC_ID))->dylib.current_version = 0x10000;
    CHECK(!mlo_changed(a, na, b, na), "a header-only edit: no change");
    memcpy(b, a, na);
    b[lkf_di(b)->bind_off] ^= 1;
    CHECK(mlo_changed(a, na, b, na), "a byte of the bind opcodes: a change");
    memcpy(b, a, na);
    lkf_st(b)->stroff += 1;
    CHECK(mlo_changed(a, na, b, na), "an offset: a change");
    memcpy(b, a, na);
    lkf_patch(b, LKF_LC_SIG, LC_UUID);
    CHECK(mlo_changed(a, na, b, na), "a piece gone: a change");
    memcpy(b, a, na);
    ((struct segment_command_64 *)lkf_lc(b, LKF_LC_LINKEDIT))->filesize += 16;
    CHECK(mlo_changed(a, na, b, na + 16), "__LINKEDIT's filesize: a change");
}

int main(void) {
```

In `tests/linkedit_order_test.c`, replace:

```c
    test_the_file_verdict();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
```

with:

```c
    test_the_file_verdict();
    test_the_pass_puts_each_variant_in_order();
    test_the_pass_leaves_an_ordered_image_alone();
    test_the_pass_places_empty_pieces();
    test_the_pass_keeps_the_rounding();
    test_the_pass_declines();
    test_what_counts_as_a_change();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
```

- [ ] **Step 2: Run it to see it fail**

Run: build (rebuild check).
Expected: the test does not compile:

```
tests/linkedit_order_test.c:158:43: error: unknown type name 'mlo_pack_report'
```

(and a run of `use of undeclared identifier` errors after it).

- [ ] **Step 3: Write the pass**

In `src/linkedit_order.h`, replace:

```c

#endif /* DRYDOCK_LINKEDIT_ORDER_H */
```

with:

```c

/* mlo_pack's returns. */
enum { MLO_PACKED = 0, MLO_UNCHANGED = 1, MLO_DECLINED = 2, MLO_FAILED = -1, MLO_NOMEM = -2 };

typedef struct {
    uint64_t before, after;   /* __LINKEDIT's filesize */
    uint64_t dropped;         /* bytes of the old __LINKEDIT no piece covered */
} mlo_pack_report;

/* Rewrites the 64-bit slice buf[0..size) so its __LINKEDIT holds its pieces
 * in ld64's order: the dyld-info streams, a chained-fixups and an
 * exports-trie blob if any, local relocations, split info, function starts,
 * data in code, code-signing DRs, linker hints, the symbol table, two-level
 * hints, external relocations, the indirect table, the table of contents,
 * module and reference tables, the string table, and the code signature at
 * the next multiple of 16. Each piece keeps its bytes and its size; bytes no
 * piece covers are dropped; nothing below __LINKEDIT moves.
 *
 * MLO_PACKED: *pbuf and *psize are the packed image, and the old buffer is
 * freed. MLO_UNCHANGED: the image was already in that order, and is left
 * alone. MLO_DECLINED: `why` says what the pass cannot account for, and the
 * image is left alone. MLO_FAILED: a postcondition failed (`why`); the image
 * is left alone. MLO_NOMEM: likewise, for an allocation. */
int mlo_pack(uint8_t **pbuf, size_t *psize, mlo_pack_report *rep, char *why, size_t whysz);

/* Whether a run changed a piece of a slice: its set of pieces, any piece's
 * offset, size or bytes, or __LINKEDIT's fileoff or filesize. `a` is the
 * slice as read, `b` as the statements left it. */
int mlo_changed(const uint8_t *a, size_t asize, const uint8_t *b, size_t bsize);

#endif /* DRYDOCK_LINKEDIT_ORDER_H */
```

In `CMakeLists.txt`, replace:

```cmake
# a tool that gains a dependency does so visibly, in this file.
add_library(drydockcore STATIC src/uleb.c src/image.c src/ordinals.c src/fat.c src/trie.c src/lc_kinds.c src/atomic_write.c src/linkedit.c src/grow.c src/rewrite.c src/version_min.c src/segname.c src/swift_retag.c src/declassify.c src/script.c src/edit.c src/arch_names.c src/relations.c src/imports.c src/redirect.c src/exports.c src/objc_meth.c src/hdrref.c src/x86len.c src/rebase.c src/objc_abs.c src/linkedit_order.c)
target_include_directories(drydockcore PUBLIC src)
```

with:

```cmake
# a tool that gains a dependency does so visibly, in this file.
add_library(drydockcore STATIC src/uleb.c src/image.c src/ordinals.c src/fat.c src/trie.c src/lc_kinds.c src/atomic_write.c src/linkedit.c src/grow.c src/rewrite.c src/version_min.c src/segname.c src/swift_retag.c src/declassify.c src/script.c src/edit.c src/arch_names.c src/relations.c src/imports.c src/redirect.c src/exports.c src/objc_meth.c src/hdrref.c src/x86len.c src/rebase.c src/objc_abs.c src/linkedit_order.c src/linkedit_pack.c)
target_include_directories(drydockcore PUBLIC src)
```

Create `src/linkedit_pack.c` with:

```c
/* linkedit_pack.c -- mlo_pack and mlo_changed; see linkedit_order.h. */
#include "linkedit_order.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mach_compat.h"

/* The pieces, in the order the pass writes them: ld64's, with the two
 * modern blobs where cctools-1035 wants them. */
enum { MLO_P_REBASE, MLO_P_BIND, MLO_P_WEAK, MLO_P_LAZY, MLO_P_EXPORT, MLO_P_CHAINED,
       MLO_P_TRIE, MLO_P_LOCREL, MLO_P_SPLIT, MLO_P_FSTARTS, MLO_P_DIC, MLO_P_DRS,
       MLO_P_LOH, MLO_P_SYMTAB, MLO_P_HINTS, MLO_P_EXTREL, MLO_P_INDIRECT, MLO_P_TOC,
       MLO_P_MODTAB, MLO_P_REFS, MLO_P_STRTAB, MLO_P_SIG, MLO_P_N };

static const char *const mlo_pname[MLO_P_N] = {
    "the rebase opcodes", "the bind opcodes", "the weak-bind opcodes", "the lazy-bind opcodes",
    "the export trie", "the chained fixups", "the exports trie", "the local relocations",
    "the split info", "the function starts", "the data in code", "the code-signing DRs",
    "the linker hints", "the symbol table", "the two-level hints", "the external relocations",
    "the indirect symbol table", "the table of contents", "the module table",
    "the reference table", "the string table", "the code signature" };

typedef struct {
    uint32_t *off;     /* its offset field, in the load command */
    uint64_t  size;    /* bytes */
    int       present; /* the command that names it exists */
} mlo_piece;

typedef struct {
    mlo_piece p[MLO_P_N];
    struct segment_command_64 *le;
    uint32_t nind;     /* the indirect table's count, for the 8-rounding */
    int      modern;   /* a chained-fixups or exports-trie blob is present */
} mlo_pieces;

static int mlo_fail(char *why, size_t whysz, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
static int mlo_fail(char *why, size_t whysz, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(why, whysz, fmt, ap);
    va_end(ap);
    return -1;
}

static void mlo_set(mlo_pieces *ps, int k, uint32_t *off, uint64_t size) {
    ps->p[k].off = off;
    ps->p[k].size = size;
    ps->p[k].present = 1;
}

/* Every piece of the image in buf, or -1 with `why`. A command that
 * carries a file offset the pass does not know is refused, and so is a
 * second of a kind: the pass could not account for every byte it moves. */
static int mlo_find(uint8_t *buf, size_t size, mlo_pieces *ps, char *why, size_t whysz) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = (uint8_t *)(h + 1);
    memset(ps, 0, sizeof *ps);
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
        struct load_command *lc = (struct load_command *)p;
        int k0 = -1;
        switch (lc->cmd) {
        case LC_SEGMENT_64: {
            struct segment_command_64 *sg = (struct segment_command_64 *)lc;
            struct section_64 *s = (struct section_64 *)(sg + 1);
            if (strncmp(sg->segname, "__LINKEDIT", 16) == 0) {
                if (ps->le) return mlo_fail(why, whysz, "the image has more than one __LINKEDIT");
                ps->le = sg;
            }
            for (uint32_t j = 0; j < sg->nsects; j++, s++)
                if (s->reloff != 0)
                    return mlo_fail(why, whysz, "section %.16s,%.16s has relocation entries",
                                    s->segname, s->sectname);
            continue;
        }
        case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY: {
            struct dyld_info_command *di = (struct dyld_info_command *)lc;
            if (ps->p[MLO_P_REBASE].present)
                return mlo_fail(why, whysz, "the image has more than one LC_DYLD_INFO");
            mlo_set(ps, MLO_P_REBASE, &di->rebase_off, di->rebase_size);
            mlo_set(ps, MLO_P_BIND, &di->bind_off, di->bind_size);
            mlo_set(ps, MLO_P_WEAK, &di->weak_bind_off, di->weak_bind_size);
            mlo_set(ps, MLO_P_LAZY, &di->lazy_bind_off, di->lazy_bind_size);
            mlo_set(ps, MLO_P_EXPORT, &di->export_off, di->export_size);
            continue;
        }
        case LC_SYMTAB: {
            struct symtab_command *st = (struct symtab_command *)lc;
            if (ps->p[MLO_P_SYMTAB].present)
                return mlo_fail(why, whysz, "the image has more than one LC_SYMTAB");
            mlo_set(ps, MLO_P_SYMTAB, &st->symoff, (uint64_t)st->nsyms * 16);
            mlo_set(ps, MLO_P_STRTAB, &st->stroff, st->strsize);
            continue;
        }
        case LC_DYSYMTAB: {
            struct dysymtab_command *dy = (struct dysymtab_command *)lc;
            if (ps->p[MLO_P_INDIRECT].present)
                return mlo_fail(why, whysz, "the image has more than one LC_DYSYMTAB");
            mlo_set(ps, MLO_P_LOCREL, &dy->locreloff, (uint64_t)dy->nlocrel * 8);
            mlo_set(ps, MLO_P_EXTREL, &dy->extreloff, (uint64_t)dy->nextrel * 8);
            mlo_set(ps, MLO_P_INDIRECT, &dy->indirectsymoff, (uint64_t)dy->nindirectsyms * 4);
            mlo_set(ps, MLO_P_TOC, &dy->tocoff, (uint64_t)dy->ntoc * 8);
            mlo_set(ps, MLO_P_MODTAB, &dy->modtaboff, (uint64_t)dy->nmodtab * 56);
            mlo_set(ps, MLO_P_REFS, &dy->extrefsymoff, (uint64_t)dy->nextrefsyms * 4);
            ps->nind = dy->nindirectsyms;
            continue;
        }
        case LC_TWOLEVEL_HINTS: {
            struct twolevel_hints_command *th = (struct twolevel_hints_command *)lc;
            if (ps->p[MLO_P_HINTS].present)
                return mlo_fail(why, whysz, "the image has more than one LC_TWOLEVEL_HINTS");
            mlo_set(ps, MLO_P_HINTS, &th->offset, (uint64_t)th->nhints * 4);
            continue;
        }
        case LC_SEGMENT_SPLIT_INFO:       k0 = MLO_P_SPLIT; break;
        case LC_FUNCTION_STARTS:          k0 = MLO_P_FSTARTS; break;
        case LC_DATA_IN_CODE:             k0 = MLO_P_DIC; break;
        case LC_DYLIB_CODE_SIGN_DRS:      k0 = MLO_P_DRS; break;
        case LC_LINKER_OPTIMIZATION_HINT: k0 = MLO_P_LOH; break;
        case LC_CODE_SIGNATURE:           k0 = MLO_P_SIG; break;
        case LC_DYLD_CHAINED_FIXUPS:      k0 = MLO_P_CHAINED; break;
        case LC_DYLD_EXPORTS_TRIE:        k0 = MLO_P_TRIE; break;
        /* Commands that name no range of the file, or (LC_ENCRYPTION_INFO*)
         * name one in __TEXT, which the pass never moves. */
        case LC_THREAD: case LC_UNIXTHREAD: case LC_LOADFVMLIB: case LC_IDFVMLIB:
        case LC_IDENT: case LC_LOAD_DYLIB: case LC_ID_DYLIB: case LC_LOAD_DYLINKER:
        case LC_ID_DYLINKER: case LC_PREBOUND_DYLIB: case LC_ROUTINES: case LC_SUB_FRAMEWORK:
        case LC_SUB_UMBRELLA: case LC_SUB_CLIENT: case LC_SUB_LIBRARY: case LC_PREBIND_CKSUM:
        case LC_LOAD_WEAK_DYLIB: case LC_ROUTINES_64: case LC_UUID: case LC_RPATH:
        case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB: case LC_ENCRYPTION_INFO:
        case LC_LOAD_UPWARD_DYLIB: case LC_VERSION_MIN_MACOSX: case LC_VERSION_MIN_IPHONEOS:
        case LC_DYLD_ENVIRONMENT: case LC_MAIN: case LC_SOURCE_VERSION:
        case LC_ENCRYPTION_INFO_64: case LC_LINKER_OPTION: case LC_BUILD_VERSION:
        case 0x2f /* LC_VERSION_MIN_TVOS */: case 0x30 /* LC_VERSION_MIN_WATCHOS */:
            continue;
        default:
            return mlo_fail(why, whysz, "load command %u (cmd 0x%x) may name a range of the "
                            "file the pass does not know", i, lc->cmd);
        }
        struct linkedit_data_command *ld = (struct linkedit_data_command *)lc;
        if (ps->p[k0].present)
            return mlo_fail(why, whysz, "the image has more than one of %s", mlo_pname[k0]);
        mlo_set(ps, k0, &ld->dataoff, ld->datasize);
        if (k0 == MLO_P_CHAINED || k0 == MLO_P_TRIE) ps->modern = 1;
    }
    (void)size;
    return 0;
}

static uint64_t mlo_rnd64(uint64_t x, uint64_t a) { return (x + a - 1) / a * a; }

/* Is the first present table after the indirect table at the 8-rounding? */
static int mlo_had_pad(const mlo_pieces *ps) {
    if (ps->nind % 2 == 0) return 0;
    uint64_t end = (uint64_t)*ps->p[MLO_P_INDIRECT].off + ps->p[MLO_P_INDIRECT].size;
    static const int tail[4] = { MLO_P_TOC, MLO_P_MODTAB, MLO_P_REFS, MLO_P_STRTAB };
    for (int t = 0; t < 4; t++) {
        const mlo_piece *q = &ps->p[tail[t]];
        if (!q->present || q->size == 0) continue;
        return *q->off != end && *q->off == mlo_rnd64(end, 8);
    }
    return 0;
}

/* Without an LC_DYSYMTAB, codesign_allocate's writer writes only the symbol
 * table, the string table and the signature, from where the sum of their
 * sizes, the first two rounded up to 16, says they start. With a signature
 * that is where they lie only if the symbol table is 16-aligned. */
static int mlo_sym_rnd(const mlo_pieces *ps) {
    return !ps->p[MLO_P_INDIRECT].present && ps->p[MLO_P_SIG].present &&
           ps->p[MLO_P_SYMTAB].present && ps->p[MLO_P_SYMTAB].size != 0;
}

/* Where each piece goes: new offsets for every present piece, and the new
 * __LINKEDIT length. Pieces keep their sizes. */
static uint64_t mlo_layout(const mlo_pieces *ps, uint64_t start, uint32_t *to) {
    uint64_t at = start;
    int pad = mlo_had_pad(ps), padded = 0;
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *q = &ps->p[k];
        if (!q->present) continue;
        uint32_t off = *q->off;
        if (q->size == 0) {
            /* A zero-size piece keeps an offset that already passes the
             * rules; otherwise it goes where ld64 puts one. */
            if (k <= MLO_P_EXPORT)
                to[k] = (off == 0 || off == at) ? off : 0;
            else if (k == MLO_P_SPLIT || k == MLO_P_FSTARTS || k == MLO_P_DIC ||
                     k == MLO_P_CHAINED || k == MLO_P_TRIE)
                to[k] = (off == 0) ? 0 : (uint32_t)at;
            else if (k == MLO_P_DRS || k == MLO_P_LOH)
                to[k] = (uint32_t)at;
            else
                to[k] = off;
            continue;
        }
        if (pad && !padded && (k == MLO_P_TOC || k == MLO_P_MODTAB || k == MLO_P_REFS ||
                               k == MLO_P_STRTAB)) {
            at = mlo_rnd64(at, 8);
            padded = 1;
        }
        if (k == MLO_P_SIG || (k == MLO_P_SYMTAB && mlo_sym_rnd(ps))) at = mlo_rnd64(at, 16);
        to[k] = (uint32_t)at;
        at += q->size;
    }
    return at - start;
}

/* The pieces tile __LINKEDIT, in the pass's order, from its start to the
 * end of the file, with no gap but the two roundings. */
static int mlo_tiles(const mlo_pieces *ps, uint64_t start, uint64_t end, char *why, size_t whysz) {
    uint64_t at = start;
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *q = &ps->p[k];
        if (!q->present || q->size == 0) continue;
        uint64_t off = *q->off;
        if (off != at && !(off == mlo_rnd64(at, 8) && (k == MLO_P_TOC || k == MLO_P_MODTAB ||
                                                       k == MLO_P_REFS || k == MLO_P_STRTAB)) &&
            !(off == mlo_rnd64(at, 16) && (k == MLO_P_SIG || (k == MLO_P_SYMTAB && mlo_sym_rnd(ps)))))
            return mlo_fail(why, whysz, "%s is at 0x%llx, not 0x%llx", mlo_pname[k],
                            (unsigned long long)off, (unsigned long long)at);
        at = off + q->size;
    }
    if (at != end)
        return mlo_fail(why, whysz, "the pieces end at 0x%llx, not at the end of the file, 0x%llx",
                        (unsigned long long)at, (unsigned long long)end);
    return 0;
}

int mlo_pack(uint8_t **pbuf, size_t *psize, mlo_pack_report *rep, char *why, size_t whysz) {
    uint8_t *buf = *pbuf;
    size_t size = *psize;
    mlo_pieces ps;
    memset(rep, 0, sizeof *rep);
    if (mlo_find(buf, size, &ps, why, whysz) != 0) return MLO_DECLINED;
    struct segment_command_64 *le = ps.le;
    if (!le) { mlo_fail(why, whysz, "the image has no __LINKEDIT"); return MLO_DECLINED; }
    uint64_t start = le->fileoff, end = le->fileoff + le->filesize;
    if (end != size) {
        mlo_fail(why, whysz, "__LINKEDIT does not end the file");
        return MLO_DECLINED;
    }
    /* codesign_allocate rounds the sum of the sizes where the order rounds
     * the offset; they agree only from a 16-aligned start. */
    if (start % 16 != 0 && ps.p[MLO_P_SIG].present && ps.p[MLO_P_INDIRECT].present) {
        mlo_fail(why, whysz, "__LINKEDIT's file offset, 0x%llx, is not a multiple of 16",
                 (unsigned long long)start);
        return MLO_DECLINED;
    }
    /* Nothing else lies in __LINKEDIT or after it. */
    {
        struct mach_header_64 *h = (struct mach_header_64 *)buf;
        uint8_t *p = (uint8_t *)(h + 1);
        for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
            struct segment_command_64 *sg = (struct segment_command_64 *)p;
            if (sg->cmd != LC_SEGMENT_64 || sg == le) continue;
            if (sg->filesize != 0 && sg->fileoff + sg->filesize > start) {
                mlo_fail(why, whysz, "%.16s lies in or after __LINKEDIT", sg->segname);
                return MLO_DECLINED;
            }
            struct section_64 *s = (struct section_64 *)(sg + 1);
            for (uint32_t j = 0; j < sg->nsects; j++, s++)
                if (s->size != 0 && s->offset != 0 && s->offset + s->size > start) {
                    mlo_fail(why, whysz, "section %.16s,%.16s lies in __LINKEDIT", s->segname,
                             s->sectname);
                    return MLO_DECLINED;
                }
        }
    }
    /* With no rebase or bind opcodes, codesign_allocate wants the export
     * trie at __LINKEDIT's start (checkout.c:360-366) but copies the dyld
     * info from the first stream's offset, so no layout both passes and
     * survives. */
    if (ps.p[MLO_P_REBASE].present && !ps.p[MLO_P_REBASE].size && !ps.p[MLO_P_BIND].size &&
        ps.p[MLO_P_WEAK].size && ps.p[MLO_P_LAZY].size && ps.p[MLO_P_EXPORT].size) {
        mlo_fail(why, whysz, "the image has weak-bind, lazy-bind and export opcodes but no rebase "
                 "or bind opcodes, which codesign_allocate cannot lay out");
        return MLO_DECLINED;
    }
    uint64_t covered = 0;
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *q = &ps.p[k];
        if (!q->present || q->size == 0) continue;
        if (*q->off < start || *q->off + q->size > end) {
            mlo_fail(why, whysz, "%s lies outside __LINKEDIT", mlo_pname[k]);
            return MLO_DECLINED;
        }
        for (int j = 0; j < k; j++) {
            const mlo_piece *r = &ps.p[j];
            if (!r->present || r->size == 0) continue;
            if (*q->off < *r->off + r->size && *r->off < *q->off + q->size) {
                mlo_fail(why, whysz, "%s overlaps %s", mlo_pname[k], mlo_pname[j]);
                return MLO_DECLINED;
            }
        }
        covered += q->size;
    }

    uint32_t to[MLO_P_N];
    memset(to, 0, sizeof to);
    uint64_t len = mlo_layout(&ps, start, to);
    if (start + len > UINT32_MAX) {
        mlo_fail(why, whysz, "the packed image would pass 4GB");
        return MLO_DECLINED;
    }
    uint64_t vmsize = le->vmsize;
    if (len > vmsize) {
        uint64_t page = (((struct mach_header_64 *)buf)->cputype == CPU_TYPE_ARM64) ? 0x4000 : 0x1000;
        vmsize = mlo_rnd64(len, page);
        struct mach_header_64 *h = (struct mach_header_64 *)buf;
        uint8_t *p = (uint8_t *)(h + 1);
        for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
            struct segment_command_64 *sg = (struct segment_command_64 *)p;
            if (sg->cmd != LC_SEGMENT_64 || sg == le || sg->vmsize == 0) continue;
            if (sg->vmaddr < le->vmaddr + vmsize && le->vmaddr < sg->vmaddr + sg->vmsize) {
                mlo_fail(why, whysz, "__LINKEDIT's vmsize would overlap %.16s", sg->segname);
                return MLO_DECLINED;
            }
        }
    }

    uint8_t *nb = (uint8_t *)calloc(1, (size_t)(start + len) ? (size_t)(start + len) : 1);
    if (!nb) { mlo_fail(why, whysz, "out of memory"); return MLO_NOMEM; }
    memcpy(nb, buf, (size_t)start);
    mlo_pieces ns;
    if (mlo_find(nb, (size_t)(start + len), &ns, why, whysz) != 0) {
        free(nb);
        return MLO_FAILED;
    }
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *q = &ps.p[k];
        if (!q->present) continue;
        if (q->size) memcpy(nb + to[k], buf + *q->off, (size_t)q->size);
        *ns.p[k].off = to[k];
    }
    ns.le->filesize = len;
    ns.le->vmsize = vmsize;

    int rc = MLO_PACKED;
    if (start + len == size && memcmp(nb, buf, size) == 0) rc = MLO_UNCHANGED;

    /* Postconditions: each piece's bytes where its offset now says; nothing
     * else in the header changed; the pieces tile __LINKEDIT; and, but for
     * commands it cannot remove, codesign_allocate would accept the image
     * and re-sign it correctly. */
    for (int k = 0; rc == MLO_PACKED && k < MLO_P_N; k++) {
        const mlo_piece *q = &ps.p[k];
        if (!q->present || q->size == 0) continue;
        if (memcmp(nb + *ns.p[k].off, buf + *q->off, (size_t)q->size) != 0) {
            mlo_fail(why, whysz, "internal error: %s did not move intact", mlo_pname[k]);
            rc = MLO_FAILED;
        }
    }
    if (rc == MLO_PACKED) {
        uint8_t *mask = (uint8_t *)calloc(1, (size_t)start ? (size_t)start : 1);
        if (!mask) { free(nb); mlo_fail(why, whysz, "out of memory"); return MLO_NOMEM; }
        for (int k = 0; k < MLO_P_N; k++)
            if (ns.p[k].present) memset(mask + ((uint8_t *)ns.p[k].off - nb), 1, 4);
        memset(mask + ((uint8_t *)&ns.le->vmsize - nb), 1, 8);
        memset(mask + ((uint8_t *)&ns.le->filesize - nb), 1, 8);
        for (uint64_t i = 0; i < start; i++)
            if (!mask[i] && nb[i] != buf[i]) {
                mlo_fail(why, whysz, "internal error: header byte 0x%llx changed",
                         (unsigned long long)i);
                rc = MLO_FAILED;
                break;
            }
        free(mask);
    }
    if (rc == MLO_PACKED && mlo_tiles(&ns, start, start + len, why, whysz) != 0) rc = MLO_FAILED;
    if (rc == MLO_PACKED) {
        mi_image im;
        mlo_verdict v;
        if (mi_wrap(nb, (size_t)(start + len), &im) != 0) {
            mlo_fail(why, whysz, "internal error: the packed image does not wrap");
            rc = MLO_FAILED;
        } else {
            mlo_check(&im, &v);
            for (int k = 0; k < v.n; k++) {
                /* The pass cures where the pieces lie, and nothing else. 862's
                 * walk has no slot for a modern blob, so an image that keeps
                 * one is held to the tiling above instead. */
                if (v.f[k].kind != MLO_REFUSES || !v.f[k].order) continue;
                if (ns.modern && strstr(v.f[k].text, "file not in an order")) continue;
                mlo_fail(why, whysz, "internal error: the packed image is refused: %s", v.f[k].text);
                rc = MLO_FAILED;
                break;
            }
            if (rc == MLO_PACKED && v.corrupting) {
                mlo_fail(why, whysz, "internal error: the packed image would re-sign corrupt");
                rc = MLO_FAILED;
            }
        }
    }
    if (rc != MLO_PACKED) {
        free(nb);
        return rc;
    }
    rep->before = le->filesize;
    rep->after = len;
    rep->dropped = le->filesize > covered ? le->filesize - covered : 0;
    free(buf);
    *pbuf = nb;
    *psize = (size_t)(start + len);
    return MLO_PACKED;
}

/* The __LINKEDIT segment of a slice, or NULL. */
static const struct segment_command_64 *mlo_le(const uint8_t *buf, size_t size) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, size, &im) != 0) return NULL;
    const struct segment_command_64 *le = mi_find_segment(&im, "__LINKEDIT");
    return le && le->fileoff <= size && le->filesize <= size - le->fileoff ? le : NULL;
}

int mlo_changed(const uint8_t *a, size_t asize, const uint8_t *b, size_t bsize) {
    const struct segment_command_64 *la = mlo_le(a, asize), *lb = mlo_le(b, bsize);
    if (!la || !lb) return la != lb;
    if (la->fileoff != lb->fileoff || la->filesize != lb->filesize) return 1;
    mlo_pieces pa, pb;
    char why[160];
    /* mlo_find does not write through its buffer. */
    if (mlo_find((uint8_t *)a, asize, &pa, why, sizeof why) != 0 ||
        mlo_find((uint8_t *)b, bsize, &pb, why, sizeof why) != 0)
        return memcmp(a + la->fileoff, b + lb->fileoff, (size_t)la->filesize) != 0;
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *x = &pa.p[k], *y = &pb.p[k];
        if (x->present != y->present) return 1;
        if (!x->present) continue;
        if (*x->off != *y->off || x->size != y->size) return 1;
        if (x->size && (*x->off + x->size > asize || *y->off + y->size > bsize)) return 1;
        if (x->size && memcmp(a + *x->off, b + *y->off, (size_t)x->size) != 0) return 1;
    }
    return 0;
}
```

- [ ] **Step 4: Run it to see it pass**

Run: re-run the configure step, build (rebuild check), then `"$B/linkedit_order_test"`.
Expected: `linkedit_order_test: all cases pass`. The whole suite: 29 tests pass.

- [ ] **Step 5: Mutation proof** (file `src/linkedit_pack.c`)

1. In `src/linkedit_pack.c`, replace `        if (k == MLO_P_SIG || (k == MLO_P_SYMTAB && mlo_sym_rnd(ps))) at = mlo_rnd64(at, 16);` with `        if (k == MLO_P_SYMTAB && mlo_sym_rnd(ps)) at = mlo_rnd64(at, 16);`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `packed (got -1`.
2. In `src/linkedit_pack.c`, replace `        if (k == MLO_P_SIG || (k == MLO_P_SYMTAB && mlo_sym_rnd(ps))) at = mlo_rnd64(at, 16);` with `        if (k == MLO_P_SIG) at = mlo_rnd64(at, 16);`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-dysymtab-drs8: packed (got -1`.
3. In `src/linkedit_pack.c`, replace `                to[k] = (off == 0 || off == at) ? off : 0;` with `                to[k] = off;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `stale-empty-rebase: packed (got 1`.
4. In `src/linkedit_pack.c`, replace `                to[k] = (off == 0) ? 0 : (uint32_t)at;` with `                to[k] = off;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `dic-stale: packed (got 1`.
5. In `src/linkedit_pack.c`, replace `                to[k] = (off == 0) ? 0 : (uint32_t)at;` with `                to[k] = (uint32_t)at;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `an empty data in code at 0 stays at 0`.
6. In `src/linkedit_pack.c`, replace `        return *q->off != end && *q->off == mlo_rnd64(end, 8);` with `        return 0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `the string table stays at the 8-rounding`.
7. In `src/linkedit_pack.c`, replace `            return mlo_fail(why, whysz, "load command %u (cmd 0x%x) may name a range of the "` with `            if (0) return mlo_fail(why, whysz, "load command %u (cmd 0x%x) may name a range of the "`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `note: declined`.
8. In `src/linkedit_pack.c`, replace this:

   ```c
           if (ps->p[k0].present)
               return mlo_fail(why, whysz, "the image has more than one of %s", mlo_pname[k0]);
   ```

   with nothing (delete it)
   It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `two-fstarts: declined`.
9. In `src/linkedit_pack.c`, replace `        if (*q->off < start || *q->off + q->size > end) {` with `        if (0) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `a piece outside __LINKEDIT: declined`.
10. In `src/linkedit_pack.c`, replace `            if (*q->off < *r->off + r->size && *r->off < *q->off + q->size) {` with `            if (0) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `overlapping pieces: declined`.
11. In `src/linkedit_pack.c`, replace this:

   ```c
       if (end != size) {
           mlo_fail(why, whysz, "__LINKEDIT does not end the file");
   ```

   with this:

   ```c
       if (0) {
           mlo_fail(why, whysz, "__LINKEDIT does not end the file");
   ```

   It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `__LINKEDIT not ending the file: declined`.
12. In `src/linkedit_pack.c`, replace `                if (s->size != 0 && s->offset != 0 && s->offset + s->size > start) {` with `                if (0) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `a section in __LINKEDIT: declined`.
13. In `src/linkedit_pack.c`, replace `                if (s->reloff != 0)` with `                if (0)`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `a section with relocations: declined`.
14. In `src/linkedit_pack.c`, replace `            if (sg->vmaddr < le->vmaddr + vmsize && le->vmaddr < sg->vmaddr + sg->vmsize) {` with `            if (0) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `__LINKEDIT's vmsize would overlap: declined`.
15. In `src/linkedit_pack.c`, replace `        ps.p[MLO_P_WEAK].size && ps.p[MLO_P_LAZY].size && ps.p[MLO_P_EXPORT].size) {` with `        ps.p[MLO_P_WEAK].size && ps.p[MLO_P_LAZY].size && ps.p[MLO_P_EXPORT].size && 0) {`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `no-rebase-no-bind: declined`.
16. In `src/linkedit_pack.c`, replace `    if (start + len == size && memcmp(nb, buf, size) == 0) rc = MLO_UNCHANGED;` with `    (void)0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `canonical: unchanged`.
17. In `src/linkedit_pack.c`, replace `    rep->dropped = le->filesize > covered ? le->filesize - covered : 0;` with `    rep->dropped = 0;`. It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `the report:`.
18. In `src/linkedit_pack.c`, replace `        if (x->size && memcmp(a + *x->off, b + *y->off, (size_t)x->size) != 0) return 1;` with nothing (delete it). It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `a byte of the bind opcodes: a change`.
19. In `src/linkedit_pack.c`, replace `    if (la->fileoff != lb->fileoff || la->filesize != lb->filesize) return 1;` with nothing (delete it). It must fail `"$B/linkedit_order_test"` (from the repo root), with a `FAIL` line containing `__LINKEDIT's filesize: a change`.

- [ ] **Step 6: Commit**

```bash
git add src/linkedit_pack.c src/linkedit_order.h CMakeLists.txt tests/linkedit_order_test.c
git commit -m "feat(linkedit_pack): put a slice's __LINKEDIT in codesign_allocate's order

mlo_pack rewrites __LINKEDIT in ld64's order: each piece keeps its bytes
and size, a zero-size piece keeps an offset that already passes, bytes no
piece covers are dropped, and nothing below __LINKEDIT moves. An image
already in order is left alone. It declines, saying why, what it cannot
account for, and checks its own result against mlo_check. mlo_changed
tells whether a run changed a piece of __LINKEDIT.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 7: The pass in a thin run: when it runs, what it says, what it refuses (M2)

**Files:**
- Modify: `src/edit.c` (`#include "arch_names.h"` at `:42`; before `/* Does the finished image still have anything for mg_plausible to check,` at `:759`; `me_run`'s statement call at `:1110-1115`)
- Modify: `tests/linkedit_fixture.h` (`LKF_DEP`: the option, `lkf_header`, `lkf_build`, two variants), `tests/linkedit_order_test.c` (the fixable list), `tests/import_redirect_test.sh:165-168`, `tests/cli_test.sh` (a block before its last three lines)

**Interfaces:**
- Consumes: Tasks 3 and 6's `mlo_check`, `mlo_file_verdict`, `mlo_pack`, `mlo_changed`; `me_say`, `me_say_left`, `me_count`.
- Produces (Task 8 uses them):
  - `static int me_pack(uint8_t **pbuf, size_t *psize, const uint8_t *orig, size_t osize, const char *label, const char *path, const char *out, FILE *log, int *packed);` — runs the pass when the run changed a piece or the slice would re-sign corrupt; prints `LABEL: __LINKEDIT re-packed in codesign_allocate's order: A -> B bytes, M unreferenced bytes dropped` when it changed the bytes (and sets `*packed`), `LABEL: __LINKEDIT not re-packed: WHY` when it declined; returns 0, or `MR_FAIL` on a failed postcondition.
  - `static int me_resign(const uint8_t *buf, size_t size, const char *path, const char *out, const ms_script *s, int packed, FILE *log);` — refuses (`MR_REFUSED`) a file some slice of which is corrupting, adding `; run the script without arch, or on that slice` when the script has `arch`; otherwise prints `PATH: resign 10.9: …` only when `packed` and 10.9 would refuse the file.
  - `LKF_DEP` and the variants `canonical-dep`, `bind-first-dep`.

**Plan decisions.**

- **Observed change, not the declared mask** (spec Decision 4): the slice as read is kept (one `malloc` of its size) and compared piece by piece after the last statement. No `MS_TABLE_ROWS` row changes, so `cli_test.sh:2933` and `edit_test.c`'s three "this run disturbed sizeofcmds" lines stay as they are.
- **Also on a corrupting output**, whatever changed: that is the repair of a hole an earlier Drydock wrote.
- **Before `mg_plausible`'s gate**, and the refusal before the write, so nothing is written on a refusal.
- **Labels are the input path**, like the run's other report lines.
- **`import_redirect_test.sh`'s grow case** now asserts that the stream grew and was packed back, not that it moved to the end: after the pass it is in order again (the review's 303 → 296).

- [ ] **Step 1: Write the failing tests**

In `tests/linkedit_fixture.h`, replace:

```c
#define LKF_EXECUTE    4u   /* MH_EXECUTE, no LC_ID_DYLIB */

```

with:

```c
#define LKF_EXECUTE    4u   /* MH_EXECUTE, no LC_ID_DYLIB */
#define LKF_DEP        8u   /* an LC_LOAD_DYLIB, last, and the bind opcodes name it */

```

In `tests/linkedit_fixture.h`, replace:

```c
static uint32_t lkf_rnd(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }

```

with:

```c
static uint32_t lkf_rnd(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }
static struct dyld_info_command *lkf_di(uint8_t *b);

```

In `tests/linkedit_fixture.h`, replace:

```c
        l->cmd = LC_CODE_SIGNATURE;
        l->cmdsize = sizeof *l;
        lc += l->cmdsize;
        h->ncmds++;
    }
    h->sizeofcmds = (uint32_t)(lc - (uint8_t *)(h + 1));
```

with:

```c
        l->cmd = LC_CODE_SIGNATURE;
        l->cmdsize = sizeof *l;
        lc += l->cmdsize;
        h->ncmds++;
    }
    if (opts & LKF_DEP) {
        struct dylib_command *d = (struct dylib_command *)lc;
        d->cmd = LC_LOAD_DYLIB;
        d->cmdsize = sizeof *d + 32;
        d->dylib.name.offset = sizeof *d;
        strcpy((char *)(d + 1), "/usr/lib/libSystem.B.dylib");
        lc += d->cmdsize;
        h->ncmds++;
    }
    h->sizeofcmds = (uint32_t)(lc - (uint8_t *)(h + 1));
```

In `tests/linkedit_fixture.h`, replace:

```c
    (void)canon_end;
    struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
```

with:

```c
    (void)canon_end;
    if (opts & LKF_DEP) buf[lkf_di(buf)->bind_off] = 0x11;   /* SET_DYLIB_ORDINAL_IMM 1 */
    struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
```

In `tests/linkedit_fixture.h`, replace:

```c
      "malformed object (unknown load command 8)", 1 },
};
```

with:

```c
      "malformed object (unknown load command 8)", 1 },
    /* an LC_LOAD_DYLIB the bind names */
    { "canonical-dep", LKF_CANON, LKF_DEP, NULL, NULL, 0 },
    { "bind-first-dep", "bind rebase weak lazy export " LKF_TAIL, LKF_DEP, NULL,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
};
```

In `tests/linkedit_order_test.c`, replace:

```c
        "hole-16", "hole-16-unsigned", "stale-empty-rebase", "hole-absorbed", "export-last",
        "no-dysymtab-hole", "no-dysymtab-drs8" };
    for (size_t k = 0; k < sizeof fixable / sizeof fixable[0]; k++) {
```

with:

```c
        "hole-16", "hole-16-unsigned", "stale-empty-rebase", "hole-absorbed", "export-last",
        "no-dysymtab-hole", "no-dysymtab-drs8", "bind-first-dep" };
    for (size_t k = 0; k < sizeof fixable / sizeof fixable[0]; k++) {
```

In `tests/import_redirect_test.sh`, replace:

```sh
    || bad "grow: announced" "$(cat "$T/run.err")"
[ "$(field "$T/grow.out" bind 2)" != "$(field "$T/grow" bind 2)" ] &&
    [ "$(field "$T/grow.out" linkedit 2)" -gt "$(field "$T/grow" linkedit 2)" ] \
    && ok "grow: ... it moved, and __LINKEDIT grew to cover it" \
    || bad "grow: moved" "$("$MKB" info "$T/grow.out")"

```

with:

```sh
    || bad "grow: announced" "$(cat "$T/run.err")"
[ "$(field "$T/grow.out" bind 3)" -gt "$(field "$T/grow" bind 3)" ] &&
    grep -q "__LINKEDIT re-packed in codesign_allocate's order" "$T/run.err" &&
    "$DMR" info "$T/grow.out" | grep -qx 'resign 10.9: ok' \
    && ok "grow: ... it grew, and the pass put it back in codesign_allocate's order" \
    || bad "grow: packed" "$("$MKB" info "$T/grow.out"); $("$DMR" info "$T/grow.out" | grep '^resign')"

```

In `tests/cli_test.sh`, replace:

```sh

reached_end=1
```

with:

```sh

# The pass, on a thin file. It runs when the run changed a piece of
# __LINKEDIT, or the output would re-sign corrupt.
lo() {   # lo IN OUT STATEMENT...: one run, its stderr in $T/lo.err
    lo_in=$1 lo_out=$2; shift 2
    rm -f "$lo_out"
    lo_rc=0
    printf '%s\n' "$@" | "$DRYDOCK_MACHO_REWRITE" "$lo_in" "$lo_out" >/dev/null 2>"$T/lo.err" || lo_rc=$?
}
packed() { grep -q "__LINKEDIT re-packed in codesign_allocate's order" "$T/lo.err"; }
for v in canonical-dep bind-first-dep bind-first-exec hole-16-note build-version; do
    "$T/mklinkedit" make "$v" "$T/lk_$v"
done

# Deleting the signature or the DRs drops their bytes; deleting a UUID
# changes no piece, so nothing moves.
lo "$T/lk_canonical" "$T/lk_nosig" 'load-command delete codesig'
[ "$lo_rc" -eq 0 ] && packed && [ "$(resign "$T/lk_nosig")" = ok ] \
    && [ "$(wc -c <"$T/lk_nosig" | tr -d ' ')" -eq 8380 ] \
    && ok "order: load-command delete codesig drops the signature's bytes (8,448 -> 8,380)" \
    || bad "order: delete codesig" "rc $lo_rc, $(wc -c <"$T/lk_nosig") bytes: $(cat "$T/lo.err")"
lo "$T/lk_canonical" "$T/lk_nodrs" 'load-command delete code-sign-drs'
[ "$lo_rc" -eq 0 ] && packed && [ "$(resign "$T/lk_nodrs")" = ok ] \
    && ok "order: load-command delete code-sign-drs drops the DRs' bytes" \
    || bad "order: delete code-sign-drs" "rc $lo_rc, resign [$(resign "$T/lk_nodrs")]: $(cat "$T/lo.err")"
lo "$T/lk_bind-first-exec" "$T/lk_nouuid" 'load-command delete uuid'
[ "$lo_rc" -eq 0 ] && ! grep -q '__LINKEDIT\|resign' "$T/lo.err" \
    && [ "$(resign "$T/lk_nouuid")" = "$(resign "$T/lk_bind-first-exec")" ] \
    && grep -q 'this run disturbed sizeofcmds' "$T/lo.err" \
    && ok "order: load-command delete uuid changes no piece, so nothing is re-packed or said" \
    || bad "order: delete uuid" "rc $lo_rc: $(cat "$T/lo.err")"

# When the pass changed the file, the report also says what still stops
# 10.9's tool.
lo "$T/lk_build-version" "$T/lk_bv.out" 'load-command delete codesig'
[ "$lo_rc" -eq 0 ] && packed \
    && grep -q "resign 10.9: malformed object (unknown load command 3)" "$T/lo.err" \
    && ok "order: after a pack, the report names what still stops 10.9's codesign_allocate" \
    || bad "order: report after pack" "rc $lo_rc: $(cat "$T/lo.err")"

# An in-place byte edit is a change: dylib insert renumbers the bind's
# ordinal. On an image in order the pass is a silent no-op.
lo "$T/lk_bind-first-dep" "$T/lk_insert" 'dylib insert /usr/lib/libz.1.dylib'
[ "$lo_rc" -eq 0 ] && packed && [ "$(resign "$T/lk_insert")" = ok ] \
    && ok "order: dylib insert's renumbering is a change, and the image is packed" \
    || bad "order: dylib insert" "rc $lo_rc, resign [$(resign "$T/lk_insert")]: $(cat "$T/lo.err")"
lo "$T/lk_canonical-dep" "$T/lk_insert2" 'dylib insert /usr/lib/libz.1.dylib'
[ "$lo_rc" -eq 0 ] && ! grep -q '__LINKEDIT\|resign' "$T/lo.err" && [ "$(resign "$T/lk_insert2")" = ok ] \
    && ok "order: ... and on an image already in order, nothing is said" \
    || bad "order: dylib insert, in order" "rc $lo_rc: $(cat "$T/lo.err")"

# A header-only edit of a still-chained image prints nothing new.
lo "$T/chained.in" "$T/lk_chained_rpath" 'rpath append /lk'
[ "$lo_rc" -eq 0 ] && ! grep -q '__LINKEDIT\|resign' "$T/lo.err" \
    && [ "$(resign "$T/lk_chained_rpath")" = "malformed object (unknown load command 3)" ] \
    && ok "order: an edit of a chained image says nothing new; info has the verdict" \
    || bad "order: chained rpath" "rc $lo_rc, resign [$(resign "$T/lk_chained_rpath")]: $(cat "$T/lo.err")"

# A corrupting input is repaired even by a header-only edit, and refused
# when the pass cannot repair it.
lo "$T/lk_hole-16" "$T/lk_hole.out" 'rpath append /lk'
[ "$lo_rc" -eq 0 ] && packed && [ "$(resign "$T/lk_hole.out")" = ok ] \
    && ok "order: a hole codesign_allocate would corrupt is repaired by any edit" \
    || bad "order: hole repaired" "rc $lo_rc: $(cat "$T/lo.err")"
lo "$T/lk_hole-16-note" "$T/lk_note.out" 'rpath append /lk'
[ "$lo_rc" -eq 1 ] && [ ! -e "$T/lk_note.out" ] \
    && grep -q '__LINKEDIT not re-packed: load command 8 (cmd 0x31)' "$T/lo.err" \
    && grep -q 'refused: codesign_allocate would re-sign .* corrupt' "$T/lo.err" \
    && ok "order: one it cannot repair is refused (1), saying why, and OUT is not written" \
    || bad "order: hole refused" "rc $lo_rc: $(cat "$T/lo.err")"

reached_end=1
```

- [ ] **Step 2: Run it to see it fail**

Run: build (rebuild check), then `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B"` and `sh tests/import_redirect_test.sh "$B"`.
Expected: `cli_test` exits 1 with these six `FAIL` lines, and `import_redirect_test` with the last one:

```
FAIL order: delete codesig: rc 0,     8448 bytes:   load-command delete codesig
FAIL order: delete code-sign-drs: rc 0, resign [file not in an order that can be processed (symbol table out of place)]:   load-command delete code-sign-drs
FAIL order: report after pack: rc 0:   load-command delete codesig
FAIL order: dylib insert: rc 0, resign [file not in an order that can be processed (dyld_info out of place)]:   dylib insert /usr/lib/libz.1.dylib
FAIL order: hole repaired: rc 0:   rpath append /lk
FAIL order: hole refused: rc 0:   rpath append /lk
FAIL grow: packed: bind 8496 24
```

(`cli_test` prints each `bad` with the whole stderr after it; only the first line of each is shown.)

- [ ] **Step 3: Run the pass**

In `src/edit.c`, replace:

```c
#include "arch_names.h"

```

with:

```c
#include "arch_names.h"
#include "linkedit_order.h"

```

In `src/edit.c`, replace:

```c

/* Does the finished image still have anything for mg_plausible to check,
```

with:

```c

/* After a slice's last statement: when the run changed a piece of its
 * __LINKEDIT, or the slice as left would re-sign corrupt, put __LINKEDIT in
 * codesign_allocate's order. `orig` is the slice as read. Sets *packed when
 * the bytes changed. Returns 0, or MR_FAIL with the reason said. */
static int me_pack(uint8_t **pbuf, size_t *psize, const uint8_t *orig, size_t osize,
                   const char *label, const char *path, const char *out, FILE *log,
                   int *packed) {
    mi_image im;
    mlo_verdict v;
    int corrupt = 0;
    if (mi_wrap(*pbuf, *psize, &im) == 0) {
        mlo_check(&im, &v);
        corrupt = v.corrupting;
    }
    if (!corrupt && !mlo_changed(orig, osize, *pbuf, *psize)) return 0;
    mlo_pack_report rep;
    char why[256] = "", c1[32], c2[32], c3[32];
    int rc = mlo_pack(pbuf, psize, &rep, why, sizeof why);
    switch (rc) {
    case MLO_PACKED:
        me_say(log, "%s: __LINKEDIT re-packed in codesign_allocate's order: %s -> %s bytes, "
                    "%s unreferenced bytes dropped\n", label, me_count(c1, (long)rep.before),
               me_count(c2, (long)rep.after), me_count(c3, (long)rep.dropped));
        *packed = 1;
        return 0;
    case MLO_UNCHANGED:
        return 0;
    case MLO_DECLINED:
        me_say(log, "%s: __LINKEDIT not re-packed: %s\n", label, why);
        return 0;
    default:
        me_say(log, "drydock-macho-rewrite edit: %s: %s; ", label, why);
        me_say_left(log, path, out);
        return MR_FAIL;
    }
}

/* Before the write: refuse a file some slice of which codesign_allocate
 * would re-sign corrupt, and, when the pass changed a slice, say whether 10.9
 * can re-sign the file. Returns 0 or MR_REFUSED. */
static int me_resign(const uint8_t *buf, size_t size, const char *path, const char *out,
                     const ms_script *s, int packed, FILE *log) {
    char refusal[256], corrupt[512];
    int rc = mlo_file_verdict(buf, size, refusal, sizeof refusal, corrupt, sizeof corrupt);
    if (rc == 2) {
        me_say(log, "drydock-macho-rewrite edit: refused: codesign_allocate would re-sign %s corrupt "
                    "(%s)%s; ", out, corrupt,
               s->arch_mask ? "; run the script without arch, or on that slice" : "");
        me_say_left(log, path, out);
        return MR_REFUSED;
    }
    if (packed && rc == 1) me_say(log, "%s: resign 10.9: %s\n", path, refusal);
    return 0;
}

/* Does the finished image still have anything for mg_plausible to check,
```

In `src/edit.c`, replace:

```c
    unsigned disturbed = MREL_NONE;
    int rc = me_statements(&buf, &size, path, out, s, log, hits, renamed, 1, NULL,
```

with:

```c
    unsigned disturbed = MREL_NONE;
    size_t osize = size;
    uint8_t *orig = (uint8_t *)malloc(osize ? osize : 1);
    if (!orig) {
        me_say(log, "drydock-macho-rewrite edit: out of memory; ");
        me_say_left(log, path, out);
        free(hits); free(renamed); free(buf);
        return MR_FAIL;
    }
    memcpy(orig, buf, osize);
    int packed = 0;
    int rc = me_statements(&buf, &size, path, out, s, log, hits, renamed, 1, NULL,
```

In `src/edit.c`, replace:

```c
    free(hits); free(renamed);
    if (rc != 0) { free(buf); return rc; }
```

with:

```c
    free(hits); free(renamed);
    if (rc == 0) rc = me_pack(&buf, &size, orig, osize, path, path, out, log, &packed);
    free(orig);
    if (rc == 0) rc = me_resign(buf, size, path, out, s, packed, log);
    if (rc != 0) { free(buf); return rc; }
```

- [ ] **Step 4: Run it to see it pass**

Run: build (rebuild check), then both suites.
Expected: `cli_test: 0 failure(s)`, `import_redirect_test: 0 failure(s)`. The whole suite: 29 tests pass; `characterize` and `known_callers` still match their digests (`tests/fixture.macho` is in order and unsigned, so no run of theirs changes a piece).

- [ ] **Step 5: Mutation proof** (file `src/edit.c`)

1. In `src/edit.c`, replace `    if (!corrupt && !mlo_changed(orig, osize, *pbuf, *psize)) return 0;` with `    if (!mlo_changed(orig, osize, *pbuf, *psize)) return 0;`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: hole repaired`.
2. In `src/edit.c`, replace `    if (!corrupt && !mlo_changed(orig, osize, *pbuf, *psize)) return 0;` with `    if (!corrupt) return 0;`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: delete codesig`.
3. In `src/edit.c`, replace `        me_say(log, "%s: __LINKEDIT not re-packed: %s\n", label, why);` with nothing (delete it). It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: hole refused`.
4. In `src/edit.c`, replace `    if (rc == 2) {` with `    if (0) {`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: hole refused`.
5. In `src/edit.c`, replace `    if (packed && rc == 1) me_say(log, "%s: resign 10.9: %s\n", path, refusal);` with `    if (rc == 1) me_say(log, "%s: resign 10.9: %s\n", path, refusal);`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: chained rpath`.
6. In `src/edit.c`, replace `    if (packed && rc == 1) me_say(log, "%s: resign 10.9: %s\n", path, refusal);` with nothing (delete it). It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: report after pack`.
7. In `src/edit.c`, replace `    if (rc == 0) rc = me_pack(&buf, &size, orig, osize, path, path, out, log, &packed);` with nothing (delete it). It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: delete codesig`.
8. In `src/edit.c`, replace this:

   ```c
           *packed = 1;
           return 0;
   ```

   with this:

   ```c
           return 0;
   ```

   It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: report after pack`.
9. In `src/edit.c`, replace `    if (rc == 0) rc = me_resign(buf, size, path, out, s, packed, log);` with nothing (delete it). It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: hole refused`.

- [ ] **Step 6: Commit**

```bash
git add src/edit.c tests/linkedit_fixture.h tests/linkedit_order_test.c tests/import_redirect_test.sh tests/cli_test.sh
git commit -m "feat(edit): a run that changes __LINKEDIT leaves it in codesign_allocate's order

After a thin file's last statement, if the run changed a piece of
__LINKEDIT or the result would re-sign corrupt, the pass packs it and says
so. A run that changed no piece moves nothing and says nothing new, even on
a chained image. An output some codesign_allocate would re-sign corrupt is
refused, naming why the pass could not repair it; after a pack, the report
names anything that still stops 10.9's tool. load-command delete codesig
and code-sign-drs now drop their bytes.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 8: The pass in a fat run (M2)

**Files:**
- Modify: `src/edit.c` (`me_fat_ctx`; `me_fat_slice`'s statement call; `me_run_fat`'s `ctx` and its last lines)
- Modify: `tests/cli_test.sh` (a block before its last three lines)

**Interfaces:**
- Consumes: Task 7's `me_pack`, `me_resign`; Task 4's `resign`; Task 7's `lo`, `packed`, `$T/lk_*`.
- Produces: `me_fat_ctx.packed`; each selected slice packed as a thin file is, labelled `slice NAME`; the whole container checked before it is written, unselected slices included.

**Plan decisions.**

- **Unselected slices are never packed** (`arch` means "leave the others alone"), but a corrupting one refuses the run, with the remedy.
- **The whole-file line** comes after the slices, once, from `mlo_file_verdict`.

- [ ] **Step 1: Write the failing tests**

In `tests/cli_test.sh`, replace:

```sh

reached_end=1
```

with:

```sh

# Fat: every slice counts, selected or not.
"$BIN/makefat" "$T/lk_fat" "$T/lk_canonical" 0x1000007 3 12 "$T/lk_hole-16" 0x1000007 8 12
lo "$T/lk_fat" "$T/lk_fat.out" 'arch x86_64' 'load-command delete codesig'
[ "$lo_rc" -eq 1 ] && [ ! -e "$T/lk_fat.out" ] \
    && grep -q 'slice x86_64h: .*would not survive' "$T/lo.err" \
    && grep -q 'run the script without arch, or on that slice' "$T/lo.err" \
    && ok "order: an unselected slice that would re-sign corrupt refuses the run, naming it" \
    || bad "order: fat corrupt slice" "rc $lo_rc: $(cat "$T/lo.err")"
lo "$T/lk_fat" "$T/lk_fat.all" 'load-command delete codesig'
[ "$lo_rc" -eq 0 ] && grep -q "slice x86_64h: __LINKEDIT re-packed" "$T/lo.err" \
    && [ "$(resign "$T/lk_fat.all")" = ok ] \
    && ok "order: ... and without arch, each slice is packed and the file re-signs" \
    || bad "order: fat packed" "rc $lo_rc, resign [$(resign "$T/lk_fat.all")]: $(cat "$T/lo.err")"
"$BIN/makefat" "$T/lk_fat4" "$T/lk_bind-first-dep" 0x1000007 3 12 "$T/lk_note" 0x1000007 8 12
lo "$T/lk_fat4" "$T/lk_fat4.out" 'arch x86_64' 'dylib insert /usr/lib/libz.1.dylib'
[ "$lo_rc" -eq 0 ] && grep -q "slice x86_64: __LINKEDIT re-packed" "$T/lo.err" \
    && grep -q "resign 10.9: slice x86_64h: malformed object (unknown load command 8)" "$T/lo.err" \
    && ok "order: when a slice is packed, the report says what still stops 10.9, whole-file" \
    || bad "order: fat report" "rc $lo_rc: $(cat "$T/lo.err")"

reached_end=1
```

- [ ] **Step 2: Run it to see it fail**

Run: build (rebuild check), then `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B"`.
Expected: exit 1, these three `FAIL` lines (first line of each):

```
FAIL order: fat corrupt slice: rc 0: slice x86_64:
FAIL order: fat packed: rc 0, resign [slice x86_64: file not in an order that can be processed (link edit information does not fill the __LINKEDIT segment)]: slice x86_64:
FAIL order: fat report: rc 0: slice x86_64:
```

- [ ] **Step 3: Run the pass per slice, and check the container**

In `src/edit.c`, replace:

```c
    int *renamed;
} me_fat_ctx;
```

with:

```c
    int *renamed;
    int packed;                      /* the pass changed some slice */
} me_fat_ctx;
```

In `src/edit.c`, replace:

```c
    unsigned disturbed = MREL_NONE;
    int rc = me_statements(pbuf, psize, c->path, c->out, c->s, c->log,
                           c->hits, c->renamed, index == c->last, name, &disturbed);
    if (rc != 0) return rc;
```

with:

```c
    unsigned disturbed = MREL_NONE;
    size_t osize = *psize;
    uint8_t *orig = (uint8_t *)malloc(osize ? osize : 1);
    if (!orig) {
        me_say(c->log, "drydock-macho-rewrite edit: out of memory; ");
        me_say_left(c->log, c->path, c->out);
        return MR_FAIL;
    }
    memcpy(orig, *pbuf, osize);
    int rc = me_statements(pbuf, psize, c->path, c->out, c->s, c->log,
                           c->hits, c->renamed, index == c->last, name, &disturbed);
    if (rc == 0) {
        char label[48];
        snprintf(label, sizeof label, "slice %s", name);
        rc = me_pack(pbuf, psize, orig, osize, label, c->path, c->out, c->log, &c->packed);
    }
    free(orig);
    if (rc != 0) return rc;
```

In `src/edit.c`, replace:

```c

    me_fat_ctx ctx = { s, path, out, log, selected, last, hits, renamed };
    int modified = 0;
```

with:

```c

    me_fat_ctx ctx = { s, path, out, log, selected, last, hits, renamed, 0 };
    int modified = 0;
```

In `src/edit.c`, replace:

```c
        me_say_left(log, path, out);
        free(buf);
```

with:

```c
        me_say_left(log, path, out);
        free(buf);
        return MR_REFUSED;
    }
    if (me_resign(buf, size, path, out, s, ctx.packed, log) != 0) {
        free(buf);
```

- [ ] **Step 4: Run it to see it pass**

Run: build (rebuild check), then `cli_test`, then the whole suite and `sh tests/codesign_order_test.sh "$B"` (M2's gate on 10.9).
Expected: `cli_test: 0 failure(s)`; 29 tests pass; the oracle `0 failure(s)`.

- [ ] **Step 5: Mutation proof** (file `src/edit.c`)

1. In `src/edit.c`, replace `        rc = me_pack(pbuf, psize, orig, osize, label, c->path, c->out, c->log, &c->packed);` with nothing (delete it). It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: fat packed`.
2. In `src/edit.c`, replace `    if (me_resign(buf, size, path, out, s, ctx.packed, log) != 0) {` with `    if (0) {`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: fat corrupt slice`.
3. In `src/edit.c`, replace `    if (me_resign(buf, size, path, out, s, ctx.packed, log) != 0) {` with `    if (me_resign(buf, size, path, out, s, 0, log) != 0) {`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: fat report`.
4. In `src/edit.c`, replace `               s->arch_mask ? "; run the script without arch, or on that slice" : "");` with `               "");`. It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: fat corrupt slice`.

- [ ] **Step 6: Commit**

```bash
git add src/edit.c tests/cli_test.sh
git commit -m "feat(edit): pack each slice of a fat file, and check every slice before writing

codesign_allocate checks every slice of a fat file, whichever it signs. A
selected slice is packed as a thin file is; the container is refused when
any slice, selected or not, would re-sign corrupt, and the refusal names
the slice and the remedy; after a pack, the report gives the whole file's
10.9 verdict.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 9: The lowering's padding; the lowering and objc-methods, end to end (M2)

**Files:**
- Modify: `src/declassify.c` (after `    ob_byte(&bind, BIND_OPCODE_DONE);` at `:660`)
- Modify: `tests/mkchained.c` (`make-signable`), `tests/relmeth_fixture.h` and `tests/mkrelmeth.c` (the `dysymtab` variant), `tests/cli_test.sh` (a block before its last three lines)

**Interfaces:**
- Consumes: Task 7's `lo`, `packed`, `resign`; `$T/mkchained` (built at `:671`), `$T/mkrelmeth` (built at `:3518`), `$T/mklinkedit`.
- Produces: `mkchained make-signable OUT` (a chained dylib with `LC_ID_DYLIB`, `LC_SYMTAB`, `LC_DYSYMTAB` and a signature, so the tool would sign it); `mkrelmeth make …+dysymtab` (an `LC_DYSYMTAB` naming the one symbol).

**Plan decisions.**

- **The padding is hygiene** (spec Decision 8): the zeros are `*_OPCODE_DONE`, the sizes include them as ld64's do, and the `!overflow` guard keeps a full buffer from looping forever. It changes the lowering's reported byte counts; no existing test pins those numbers.
- **Neither fixture had what codesign_allocate requires** (`mkchained`: no `LC_ID_DYLIB` or symbol table; `mkrelmeth`: no `LC_DYSYMTAB`), so each gains a variant rather than changing what every other test reads.

- [ ] **Step 1: Write the failing tests**

In `tests/cli_test.sh`, replace:

```sh

reached_end=1
```

with:

```sh

# The lowering: its streams padded to 8, and the result in order.
"$T/mkchained" make-signable "$T/lk_chained"
lo "$T/lk_chained" "$T/lk_chained.out" 'fixups set classic'
[ "$lo_rc" -eq 0 ] && packed && [ "$(resign "$T/lk_chained.out")" = ok ] \
    && ! "$DRYDOCK_MACHO_REWRITE" info "$T/lk_chained.out" | grep -q '^resign corrupt' \
    && ok "order: fixups set classic leaves __LINKEDIT as codesign_allocate wants it" \
    || bad "order: lowering" "rc $lo_rc, resign [$(resign "$T/lk_chained.out")]: $(cat "$T/lo.err")"
"$T/mkchained" check "$T/lk_chained.out" | grep -qx 'slot0=0x100001000' \
    && "$T/mkchained" check "$T/lk_chained.out" | grep -qx 'slot1=0x0' \
    && ok "order: ... and the lowered slots are what they were" \
    || bad "order: lowering slots" "$("$T/mkchained" check "$T/lk_chained.out")"
"$T/mklinkedit" pieces "$T/lk_chained.out" | awk '$1 == "rebase" || $1 == "bind" { n++; if ($3 % 8) odd = 1 }
    END { exit !(n == 2 && !odd) }' \
    && ok "order: ... and each emitted stream's size is a multiple of 8" \
    || bad "order: stream padding" "$("$T/mklinkedit" pieces "$T/lk_chained.out")"

# objc-methods, whose old rebase stream it zeroes inside the dyld info.
"$T/mkrelmeth" make codesig+dysymtab "$T/lk_relmeth"
lo "$T/lk_relmeth" "$T/lk_relmeth.out" 'objc-methods set absolute'
"$T/mkrelmeth" entries "$T/lk_relmeth" | sed 's/ rel / abs /' >"$T/lk.want"
"$T/mkrelmeth" entries "$T/lk_relmeth.out" >"$T/lk.got" 2>/dev/null || true
[ "$lo_rc" -eq 0 ] && packed && [ "$(resign "$T/lk_relmeth.out")" = ok ] \
    && [ -s "$T/lk.want" ] && cmp -s "$T/lk.want" "$T/lk.got" \
    && ok "order: objc-methods set absolute is packed, and its lists read as they did" \
    || bad "order: objc-methods" "rc $lo_rc, resign [$(resign "$T/lk_relmeth.out")]: $(cat "$T/lo.err")"

reached_end=1
```

In `tests/mkchained.c`, replace:

```c
#include <mach-o/loader.h>
#include "mach_compat.h"
```

with:

```c
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include "mach_compat.h"
```

In `tests/mkchained.c`, replace:

```c
enum { MK_PLAIN, MK_WEAK, MK_BIG, MK_NOSECT, MK_SECTPAST, MK_BADORD, MK_HIGH8, MK_LCFIRST,
       MK_SWIFT, MK_SWIFTDC, MK_TIGHT, MK_TIGHT7 };

```

with:

```c
enum { MK_PLAIN, MK_WEAK, MK_BIG, MK_NOSECT, MK_SECTPAST, MK_BADORD, MK_HIGH8, MK_LCFIRST,
       MK_SWIFT, MK_SWIFTDC, MK_TIGHT, MK_TIGHT7, MK_SIGNABLE };

/* make-signable's extra __LINKEDIT, after the trie: one local symbol, its
 * string, and a signature blob, which codesign_allocate needs to see an
 * image it would sign (an LC_ID_DYLIB, a symbol table, an LC_DYSYMTAB). */
#define SG_SYMS  (TRIE_SIZE)
#define SG_STRS  (SG_SYMS + 16)
#define SG_SIG   (SG_STRS + 16)
#define SG_END   (SG_SIG + 64)

```

In `tests/mkchained.c`, replace:

```c
    h->ncmds = 6;
    h->sizeofcmds = (uint32_t)(p - (buf + sizeof *h));
```

with:

```c
    h->ncmds = 6;
    if (mode == MK_SIGNABLE) {
        struct dylib_command *id = (struct dylib_command *)p;
        id->cmd = LC_ID_DYLIB;
        id->cmdsize = sizeof *id + 16;
        id->dylib.name.offset = sizeof *id;
        memcpy(p + sizeof *id, "/mkchained", 11);
        p += id->cmdsize;
        struct symtab_command *st = (struct symtab_command *)p;
        st->cmd = LC_SYMTAB;
        st->cmdsize = sizeof *st;
        st->symoff = (uint32_t)(trie_off + SG_SYMS);
        st->nsyms = 1;
        st->stroff = (uint32_t)(trie_off + SG_STRS);
        st->strsize = 16;
        p += st->cmdsize;
        struct dysymtab_command *dy = (struct dysymtab_command *)p;
        memset(dy, 0, sizeof *dy);
        dy->cmd = LC_DYSYMTAB;
        dy->cmdsize = sizeof *dy;
        dy->nlocalsym = 1;
        p += dy->cmdsize;
        struct linkedit_data_command *sig = (struct linkedit_data_command *)p;
        sig->cmd = LC_CODE_SIGNATURE;
        sig->cmdsize = sizeof *sig;
        sig->dataoff = (uint32_t)(trie_off + SG_SIG);
        sig->datasize = 64;
        p += sig->cmdsize;
        h->ncmds += 4;
        le->filesize = trie_off + SG_END - linkedit_off;
        fsize = (size_t)(trie_off + SG_END);
    }
    h->sizeofcmds = (uint32_t)(p - (buf + sizeof *h));
```

In `tests/mkchained.c`, replace:

```c
    memset(buf + trie_off, 0, TRIE_SIZE);

```

with:

```c
    memset(buf + trie_off, 0, TRIE_SIZE);
    if (mode == MK_SIGNABLE) {
        struct nlist_64 *sym = (struct nlist_64 *)(buf + trie_off + SG_SYMS);
        sym->n_un.n_strx = 1;
        sym->n_type = N_SECT;
        sym->n_sect = 1;
        sym->n_value = TEXT_VMADDR + SECT_OFF;
        memcpy(buf + trie_off + SG_STRS, "\0_mkchained_l", 14);
        static const uint8_t magic[8] = { 0xfa, 0xde, 0x0c, 0xc0, 0, 0, 0, 64 };
        memcpy(buf + trie_off + SG_SIG, magic, sizeof magic);
    }

```

In `tests/mkchained.c`, replace:

```c
int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: mkchained make|make-weak|make-big|make-nosect|make-sectpast|make-badord|make-high8|make-lcfirst|make-swift|make-swiftdc|make-tight|make-tight7|check|tags FILE\n"); return 2; }
    if (strcmp(argv[1], "make") == 0) return make(argv[2], MK_PLAIN);
    if (strcmp(argv[1], "make-weak") == 0) return make(argv[2], MK_WEAK);
```

with:

```c
int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: mkchained make|make-weak|make-big|make-nosect|make-sectpast|make-badord|make-high8|make-lcfirst|make-swift|make-swiftdc|make-tight|make-tight7|make-signable|check|tags FILE\n"); return 2; }
    if (strcmp(argv[1], "make") == 0) return make(argv[2], MK_PLAIN);
    if (strcmp(argv[1], "make-signable") == 0) return make(argv[2], MK_SIGNABLE);
    if (strcmp(argv[1], "make-weak") == 0) return make(argv[2], MK_WEAK);
```

In `tests/mkchained.c`, replace:

```c
    if (strcmp(argv[1], "check") == 0) return check(argv[2]);
    fprintf(stderr, "usage: mkchained make|make-weak|make-big|make-nosect|make-sectpast|make-badord|make-high8|make-lcfirst|make-swift|make-swiftdc|make-tight|make-tight7|check|tags FILE\n");
    return 2;
```

with:

```c
    if (strcmp(argv[1], "check") == 0) return check(argv[2]);
    fprintf(stderr, "usage: mkchained make|make-weak|make-big|make-nosect|make-sectpast|make-badord|make-high8|make-lcfirst|make-swift|make-swiftdc|make-tight|make-tight7|make-signable|check|tags FILE\n");
    return 2;
```

In `tests/relmeth_fixture.h`, replace:

```c
                              * ignored with RMF_DYLIB, which already does */
    RMF_COMPACT  = 1u << 26  /* the rebase stream is ld64's compact form, one segment set and
                              * DO_REBASE_ADD_ADDR_ULEB between slots */
};
```

with:

```c
                              * ignored with RMF_DYLIB, which already does */
    RMF_COMPACT  = 1u << 26, /* the rebase stream is ld64's compact form, one segment set and
                              * DO_REBASE_ADD_ADDR_ULEB between slots */
    RMF_DYSYMTAB = 1u << 27  /* an LC_DYSYMTAB naming the one symbol as defined external */
};
```

In `tests/relmeth_fixture.h`, replace:

```c
    }
    if (v & RMF_CHAINED) {
```

with:

```c
    }
    if (v & RMF_DYSYMTAB) {
        struct dysymtab_command *dy = rmf_lc(b, &at, LC_DYSYMTAB, sizeof *dy);
        dy->iextdefsym = 0;
        dy->nextdefsym = 1;
    }
    if (v & RMF_CHAINED) {
```

In `tests/mkrelmeth.c`, replace:

```c
    { "segafter", RMF_SEGAFTER }, { "codesig", RMF_CODESIG }, { "split", RMF_SPLIT },
    { "pad16", RMF_PAD16 },     { "compact", RMF_COMPACT },
};
```

with:

```c
    { "segafter", RMF_SEGAFTER }, { "codesig", RMF_CODESIG }, { "split", RMF_SPLIT },
    { "pad16", RMF_PAD16 },     { "compact", RMF_COMPACT }, { "dysymtab", RMF_DYSYMTAB },
};
```

- [ ] **Step 2: Run it to see it fail**

Run: build (rebuild check), then `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B"`.
Expected: exit 1, one `FAIL` line: `FAIL order: stream padding: symtab 8235 16` (the lowering and objc-methods runs already pack, from Task 7; only the padding is missing).

- [ ] **Step 3: Pad the streams**

In `src/declassify.c`, replace:

```c
    ob_byte(&bind, BIND_OPCODE_DONE);
    printf("Processed %d rebases, %d binds\n", total_rebases, total_binds);
```

with:

```c
    ob_byte(&bind, BIND_OPCODE_DONE);
    /* Each stream's size is a multiple of 8, as ld64 writes it, so the
     * pieces after it stay 8-aligned. The padding is more DONE opcodes. */
    while (rebase.len % 8 && !rebase.overflow) ob_byte(&rebase, REBASE_OPCODE_DONE);
    while (bind.len % 8 && !bind.overflow) ob_byte(&bind, BIND_OPCODE_DONE);
    printf("Processed %d rebases, %d binds\n", total_rebases, total_binds);
```

- [ ] **Step 4: Run it to see it pass**

Run: build (rebuild check), then `cli_test`, the whole suite, and `sh tests/codesign_order_test.sh "$B"`.
Expected: `cli_test: 0 failure(s)`; 29 tests pass; `codesign_order_test: 83 files (52 refused by the tool, 5 written corrupt), 0 failure(s)`.

- [ ] **Step 5: Mutation proof** (file `src/declassify.c`)

1. In `src/declassify.c`, replace `    while (rebase.len % 8 && !rebase.overflow) ob_byte(&rebase, REBASE_OPCODE_DONE);` with nothing (delete it). It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: stream padding`.
2. In `src/declassify.c`, replace `    while (bind.len % 8 && !bind.overflow) ob_byte(&bind, BIND_OPCODE_DONE);` with nothing (delete it). It must fail `sh tests/cli_test.sh "$B"`, with a `FAIL` line containing `order: stream padding`.

- [ ] **Step 6: Commit**

```bash
git add src/declassify.c tests/mkchained.c tests/relmeth_fixture.h tests/mkrelmeth.c tests/cli_test.sh
git commit -m "feat(declassify): pad the lowered streams to 8, and prove the lowering re-signable

The rebase and bind streams fixups set classic emits are now padded with
DONE opcodes to a multiple of 8, as ld64 writes them. mkchained
make-signable and mkrelmeth's dysymtab variant give the lowering and
objc-methods set absolute an input codesign_allocate would sign, and the
suite shows both come out in its order.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 10: The words (M3)

**Files:**
- Create: `docs/codesign-order.md`
- Modify: `README.md` (before `### Directives`; the `info hello` example), `compat/README.md` (before `## \`insert_dylib\`: not one of the six`; the `bake-mavericks-shim` table), `compat/bake-mavericks-shim.sh:184`, `docs/superpowers/specs/2026-09-23-objc-method-lists-design.md:149-156`

**Interfaces:** none. The owner's rulings (the spec's "The owner's answers"): the compat divergences are adopted and recorded, one row per affected wrapper; the `bake-mavericks-shim` "leaves the signature's bytes" row goes, since that difference no longer exists.

- [ ] **Step 1: Write the words**

In `README.md`, replace:

```markdown
`rpath insert` works the same way, so dyld searches B before A.

```

with:

````markdown
`rpath insert` works the same way, so dyld searches B before A.

### Re-signing

Every edit invalidates a code signature, and known port flows re-sign ad hoc
afterwards (`codesign --force --sign -`). Sign last, after the last
`drydock-macho-rewrite` run. 10.9's own `codesign` can re-sign what Drydock
writes, because a run that changes anything in `__LINKEDIT` also puts
`__LINKEDIT` back in the order 10.9's `codesign_allocate` requires. The
report says so:

```
Mantle: __LINKEDIT re-packed in codesign_allocate's order: 40,992 -> 38,176 bytes, 2,828 unreferenced bytes dropped
```

`info`'s last line says whether 10.9's `codesign_allocate` would re-sign the
file as it stands:

```
resign 10.9: ok
resign 10.9: malformed object (unknown load command 4)
resign 10.9: slice x86_64h: malformed object (unknown load command 4)
```

A file that `codesign_allocate` would accept but re-sign **corrupt**, with
its fixup opcodes or symbol table overwritten under a signature that
`codesign -v` still accepts, gets a second line, `resign corrupt: …`. No run
writes such a file: one it cannot repair is refused.

`load-command delete codesig` removes the signature's bytes, not only its
load command. A universal binary is checked slice by slice, and one slice 10.9
cannot re-sign stops the whole file; on 10.9, which runs only the x86_64
slice, `lipo -thin x86_64` first.

````

In `README.md`, replace:

````markdown
slice i386: 32-bit; passed through unchanged
```
````

with:

````markdown
slice i386: 32-bit; passed through unchanged
resign 10.9: not checked: slice i386 is not a 64-bit Mach-O
```
````

In `compat/README.md`, replace:

```markdown

## `insert_dylib`: not one of the six, and the differences it has from the fork
```

with:

```markdown

## Output 10.9 can re-sign: an adopted divergence four wrappers share

The repo owner ruled this adopted (2026-09-26). A run that changes anything in
`__LINKEDIT` now also puts `__LINKEDIT` in the order 10.9's `codesign_allocate`
requires, and drops the bytes nothing points at, so 10.9's own `codesign` can
re-sign the result. The original tools wrote files it refuses. This changes the
bytes each of these wrappers writes, never what dyld loads:

| wrapper | what the original wrote | what it writes now | held by |
|---|---|---|---|
| `patch_macho` | the rebase and bind streams appended past the code signature, the chained-fixups blob left in place | every piece in order, the stale signature last, the blob dropped | `tests/cli_test.sh`, "order: fixups set classic leaves __LINKEDIT as codesign_allocate wants it" |
| `change_dylib -strip-lc codesig` | the load command removed, the signature's bytes left in `__LINKEDIT` | the bytes dropped too | `tests/cli_test.sh`, "order: load-command delete codesig drops the signature's bytes" |
| `change_dylib -strip-lc code-sign-drs` | the load command removed, its bytes left between function starts and the symbol table | the bytes dropped | `tests/cli_test.sh`, "order: load-command delete code-sign-drs drops the DRs' bytes" |
| `insert_dylib --strip-codesig` | as `change_dylib -strip-lc codesig` | as `change_dylib -strip-lc codesig` | the same |
| any wrapper whose run matched nothing (`allow-unmatched`), on an input `codesign_allocate` would re-sign corrupt | the input, unchanged | the input repaired, in order; one that cannot be repaired is refused | `tests/cli_test.sh`, "order: a hole codesign_allocate would corrupt is repaired by any edit" |

Each wrapper's stderr, where `drydock-macho-rewrite`'s report goes, gains the
line `FILE: __LINKEDIT re-packed in codesign_allocate's order: …` whenever the
pass changed the file. Stdout is unchanged.

## `insert_dylib`: not one of the six, and the differences it has from the fork
```

In `compat/README.md`, replace:

```markdown
| the result is **verified before it is written**: both streams are read back and every bind compared with what it was. The Python writes what it computed | `tests/import_redirect_test.sh`, "verification" |
| the bind stream is rewritten **opcode for opcode**, in place when that fits; the Python re-emits the whole stream in its own encoding. When the stream has to grow, both put it at the end of `__LINKEDIT` | compared bind by bind with `dyldinfo` in the differential below |
| the shim's exports come from its **export trie** (`drydock-macho-rewrite exports`), not from `nm -gU`'s text | `tests/import_redirect_test.sh`, "exports" |
| `load-command delete codesig` removes the load command and **leaves the signature's bytes** in `__LINKEDIT`; the Python truncates them and shrinks `__LINKEDIT` | `tests/bake_mavericks_shim_test.sh`, "signed" (the command is gone; the bytes are not asserted either way) |
| the appended `LC_LOAD_DYLIB` records **version 0.0.0**, as every `dylib append` does, so any build of the shim satisfies it; the Python records 1.0.0, and dyld refuses a shim built without `-compatibility_version 1.0` | the differential below, which had to build its shim with that flag for the Python's output to load |
| the summary's `bind data:` names **where** each table went (`regular table in place`, `regular table relocated to the end of __LINKEDIT`, `lazy table rewritten in place`) without the Python's byte counts; `drydock-macho-rewrite`'s own report on stderr has the sizes | `tests/bake_mavericks_shim_test.sh`, "the Python's summary lines" |
| stderr also carries `drydock-macho-rewrite`'s report of the edit, and a weak bind of a redirected symbol is warned about twice: the Python's list, then the engine's line for that symbol | `tests/bake_mavericks_shim_test.sh`, "weak" |
```

with:

```markdown
| the result is **verified before it is written**: both streams are read back and every bind compared with what it was. The Python writes what it computed | `tests/import_redirect_test.sh`, "verification" |
| the bind stream is rewritten **opcode for opcode**, in place when that fits; the Python re-emits the whole stream in its own encoding. When the stream has to grow, the Python puts it at the end of `__LINKEDIT`; this puts it back in `codesign_allocate`'s order | compared bind by bind with `dyldinfo` in the differential below |
| the shim's exports come from its **export trie** (`drydock-macho-rewrite exports`), not from `nm -gU`'s text | `tests/import_redirect_test.sh`, "exports" |
| the appended `LC_LOAD_DYLIB` records **version 0.0.0**, as every `dylib append` does, so any build of the shim satisfies it; the Python records 1.0.0, and dyld refuses a shim built without `-compatibility_version 1.0` | the differential below, which had to build its shim with that flag for the Python's output to load |
| the summary's `bind data:` names **where** each table went (`regular table in place`, `regular table grown`, `lazy table rewritten in place`) without the Python's byte counts; `drydock-macho-rewrite`'s own report on stderr has the sizes | `tests/bake_mavericks_shim_test.sh`, "the Python's summary lines" |
| stderr also carries `drydock-macho-rewrite`'s report of the edit, and a weak bind of a redirected symbol is warned about twice: the Python's list, then the engine's line for that symbol | `tests/bake_mavericks_shim_test.sh`, "weak" |
```

In `compat/bake-mavericks-shim.sh`, replace:

```sh
grep -q '^      bind stream grew from' "$MW_T/err" &&
    bk_place='regular table relocated to the end of __LINKEDIT'
grep -q '^      bind stream rewritten in place' "$MW_T/err" && [ -z "$bk_place" ] &&
```

with:

```sh
grep -q '^      bind stream grew from' "$MW_T/err" &&
    bk_place='regular table grown'
grep -q '^      bind stream rewritten in place' "$MW_T/err" && [ -z "$bk_place" ] &&
```

Create `docs/codesign-order.md` with:

```markdown
# What 10.9's `codesign` needs of `__LINKEDIT`

Why `src/linkedit_order.[ch]` checks what it checks, and why a run that changes
`__LINKEDIT` also packs it. Researched 2026-09-26 on 10.9.5 (13F1911).
Claims are tagged as in `docs/minimum-os-version.md`:

- **MEASURED** means run on this host;
- **SOURCED** means read in [apple-oss-distributions/cctools](https://github.com/apple-oss-distributions/cctools),
  tag `cctools-862`, which is what 10.9's Command Line Tools 6.2 ship (the
  binary carries that string).

## The tool

`codesign` runs `codesign_allocate`, which does two things:

- it **checks** the image: `libstuff/ofile.c`'s load-command loop and
  `libstuff/checkout.c`;
- it **rewrites** it with room for the signature: `misc/codesign_allocate.c`
  and `libstuff/writeout.c`.

`codesign_allocate -i IN -a x86_64 16384 -o OUT` runs it alone, without
signing. `tests/codesign_order_test.sh` does that, on 10.9, against every
fixture in `tests/linkedit_fixture.h`.

## "unknown load command N" is an index

`ofile.c` prints the loop index of the first command it has no case for. So
4 is the fifth command, not `cmd` 4. MEASURED: Mantle, whose fifth command is
`LC_DYLD_CHAINED_FIXUPS`, says 4.

Commands cctools-862 does not know:
- `LC_FVMFILE`, `LC_PREPAGE`;
- `LC_VERSION_MIN_TVOS`, `LC_VERSION_MIN_WATCHOS`;
- `LC_NOTE`, `LC_BUILD_VERSION`;
- `LC_DYLD_EXPORTS_TRIE`, `LC_DYLD_CHAINED_FIXUPS`;
- `LC_FILESET_ENTRY`, `LC_ATOM_INFO`, and everything later.

`fixups set classic` removes the three a modern image carries, and `minos`
replaces `LC_BUILD_VERSION`.

## The order

For a dylib, or any image with `MH_DYLDLINK`, that has an `LC_DYSYMTAB`,
`checkout.c`'s `dyld_order()` requires each piece to start exactly where the
previous one ended. The first piece starts at `__LINKEDIT`'s file offset. The
order is:

1. the dyld info: rebase, bind, weak-bind, lazy-bind and export, as one block;
2. local relocations;
3. split info;
4. function starts;
5. data in code;
6. code-signing DRs;
7. linker optimization hints;
8. the symbol table: locals, then defined externals, then undefined;
9. two-level hints;
10. external relocations;
11. the indirect symbol table;
12. the table of contents, module table and reference table;
13. the string table;
14. the code signature, at the next multiple of 16.

`__LINKEDIT` must end the file. The only gaps allowed are:
- that 16-rounding;
- an 8-rounding after an odd-sized indirect table, taken by the first table
  after it.

A split-info, function-starts or data-in-code piece whose offset is 0 is not
checked, but still counts toward the running offset. An image without an
`LC_DYSYMTAB` is held only to `symbol_string_at_end()`: the string table
ends the file, before the signature, and the symbol table directly precedes it.

MEASURED: every layout in `tests/linkedit_fixture.h` gives the refusal its row
names.

## What the writer silently assumes

`codesign_allocate` never changes an offset in a load command. Its writer
works like this:
- it copies the file verbatim up to `object_size − input_sym_info_size`;
- it writes the pieces back one after another, each from where its load
  command says it is;
- it puts the signature at the next multiple of 16.

`input_sym_info_size` is a **sum** of the pieces' sizes. It counts:
- the five dyld-info streams, only with an `LC_DYSYMTAB`;
- the symbol and string tables, only when there are symbols.

The dyld info is copied as one span, from its first byte to its last. So a
hole inside it, or a string table without symbols, shifts every later piece
off its offset. Nothing reports it.

MEASURED, all with the order rules passing:
- an 8-byte hole between two streams made a signed file whose `__LINKEDIT`
  runs past its end;
- a 2,936-byte hole (the old rebase stream `objc-methods set absolute` used
  to leave zeroed) made a file that **`codesign -v` accepts** while its rebase
  and bind opcodes are wrong;
- a hole the 16-rounding happens to absorb is harmless.

So `codesign -v` passing is not evidence of a correct re-sign. `mlo_check`
simulates the writer and compares, piece by piece, the bytes it would leave at
each piece's offset. Any other host's `codesign_allocate` makes the same sum
(`cctools-1035.1.102`, SOURCED), which is why a corrupting output is refused
rather than reported.

## Fat files

`checkout()` runs over every slice, whichever one is signed. MEASURED: an
x86_64 + x86_64h file whose x86_64h slice still has chained fixups is refused
when `-a x86_64` is signed. `info`'s `resign 10.9:` line is therefore a
verdict on the whole file.

## Does 10.9 need a valid signature?

No. MEASURED with a clang-built dylib and executable:

| image | from an ordinary process | from one signed `-o kill` |
|---|---|---|
| dylib, stale signature | loads | killed (`denying page sending SIGKILL`) |
| dylib, signature removed | loads | loads |
| executable, stale signature | runs | — |
| executable signed `-o kill`, then edited | killed (exit 137) | — |
| executable, signature removed | runs | — |

A well-formed stale signature is the only one that can hurt, and only under
the kill flag. `docs/minimum-os-version.md` has the sdk rule that decides
whether dyld registers a dylib's signature at all. Drydock keeps a stale
signature, moved to the end where `codesign --force` replaces it.
`load-command delete codesig` removes it, bytes and all.

## Snow Leopard

`cctools-782` (SOURCED; that it is 10.6's is inferred) has the same core
order, but its `ofile.c` knows none of these:
- `LC_VERSION_MIN_MACOSX`, `LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`;
- `LC_MAIN`, `LC_SOURCE_VERSION`, `LC_DYLIB_CODE_SIGN_DRS`.

10.6's own `codesign` therefore cannot re-sign a typical 10.9 image, whatever
its order.
```

In `docs/superpowers/specs/2026-09-23-objc-method-lists-design.md`, replace:

```markdown
`rebase_off`/`rebase_size` are pointed at the new stream. The old stream's
bytes are zeroed where they now sit. `__LINKEDIT` still ends the file and the
code signature, if there is one, still ends `__LINKEDIT`, so this statement
leaves the image as re-signable as it found it. On the real frameworks that
is not re-signable with 10.9's `codesign_allocate`: `fixups set classic`,
which must run first, leaves its streams out of the order that tool
requires (QUEUE item 30). This is the same room-making
`import redirect` does, moved to the other end of `__LINKEDIT`.

```

with:

```markdown
`rebase_off`/`rebase_size` are pointed at the new stream. The old stream's
bytes are zeroed where they now sit. That zeroed hole inside the dyld info
is one `codesign_allocate` accepts and then re-signs corrupt
(`docs/codesign-order.md`), so the run's closing pass drops it and puts
`__LINKEDIT` back in that tool's order; the statement itself leaves the
layout as described here. This is the same room-making `import redirect`
does, moved to the other end of `__LINKEDIT`.

```

- [ ] **Step 2: Check them**

Run:

```sh
unset DRYDOCK_MACHO_REWRITE; sh tests/bake_mavericks_shim_test.sh "$B" | tail -1   # expect 0 failure(s): the summary text changed
git grep -n "relocated to the end of __LINKEDIT" -- compat README.md                # expect nothing
git grep -c "regular table in place" -- compat/README.md                           # positive control: expect 1
git grep -n "leaves the signature's bytes" -- compat/README.md                     # expect nothing
git grep -c "## Output 10.9 can re-sign" -- compat/README.md                       # positive control: expect 1
git grep -n "superpowers" -- docs/codesign-order.md README.md                      # expect nothing: no doc cites a spec or plan
```

Then the whole suite: 29 tests pass.

- [ ] **Step 3: Commit**

```bash
git add README.md compat/README.md compat/bake-mavericks-shim.sh docs/codesign-order.md docs/superpowers/specs/2026-09-23-objc-method-lists-design.md
git commit -m "docs: re-signing on 10.9, the compat divergences it adopts, and why

README: sign last; info's resign line; load-command delete codesig drops
the bytes; lipo -thin for a fat file with a slice 10.9 cannot re-sign.
compat/README: the adopted divergence four wrappers share, and the
bake-mavericks-shim rows the pass made untrue. docs/codesign-order.md keeps
what 10.9's codesign_allocate requires and why, once the spec is gone.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 11: The real-world run on 10.9, and QUEUE item 30 (M4)

**Files:**
- Modify: `docs/superpowers/QUEUE.md` (row 36, `| 30 | …`; item 30's section, from `## Item 30:` to the end)
- Delete: `docs/superpowers/specs/2026-09-26-classic-fixups-re-signable-design.md`, `docs/superpowers/plans/2026-09-26-classic-fixups-re-signable.md` (their durable content is in `docs/codesign-order.md`, Task 10)

- [ ] **Step 1: Run the eight real binaries through the finished build**

On fresh copies, never the originals (OpenCode.app's are read-only by rule):

```sh
W=$(mktemp -d -t item30) && cd "$W"
FW="$HOME/Downloads/OpenCode.app/Contents/Frameworks"; G="$HOME/Downloads/ghidra_12.0.3_PUBLIC"
cp "$FW/Mantle.framework/Versions/A/Mantle" "$FW/ReactiveObjC.framework/Versions/A/ReactiveObjC" \
   "$FW/Squirrel.framework/Versions/A/Squirrel" "$FW/Squirrel.framework/Versions/A/Resources/ShipIt" \
   "$FW/Electron Framework.framework/Versions/A/Helpers/chrome_crashpad_handler" \
   "$FW/Electron Framework.framework/Versions/A/Libraries/libGLESv2.dylib" \
   "$G/Ghidra/Features/FileFormats/os/mac_x86_64/lzfse" "$G/GPL/DemanglerGnu/os/mac_x86_64/demangler_gnu_v2_41" .
shasum -a 256 * | cut -c1-8,65-     # 3b59fda2 Mantle, 35e4e688 ReactiveObjC, 03ef80b1 Squirrel, a233da31 ShipIt,
                                    # ff634765 chrome_crashpad_handler, cbcf071c libGLESv2.dylib, b089fca1 lzfse,
                                    # c471fdf3 demangler_gnu_v2_41
printf '    .globl ____chkstk_darwin\n____chkstk_darwin:\n    ret\n' > chk.s
cc -mmacosx-version-min=10.9 -dynamiclib -o "$W/libchk.dylib" chk.s -install_name "$W/libchk.dylib"
for n in Mantle ReactiveObjC Squirrel; do
  printf 'target 10.9\nobjc-methods set absolute\n' | "$B/drydock-macho-rewrite" "$W/$n" "$W/$n.out" >"$W/$n.log" 2>&1; echo "$n rc=$?"; done
for n in ShipIt chrome_crashpad_handler libGLESv2.dylib; do
  printf 'target 10.9\n' | "$B/drydock-macho-rewrite" "$W/$n" "$W/$n.out" >"$W/$n.log" 2>&1; echo "$n rc=$?"; done
for n in lzfse demangler_gnu_v2_41; do
  printf 'target 10.9\ndylib append %s\nimport redirect ____chkstk_darwin /usr/lib/libSystem.B.dylib %s\n' \
    "$W/libchk.dylib" "$W/libchk.dylib" | "$B/drydock-macho-rewrite" "$W/$n" "$W/$n.out" >"$W/$n.log" 2>&1; echo "$n rc=$?"; done
grep -h 're-packed' "$W"/*.log | sed "s|$W/||"
```

Expected: every `rc=0`, and one re-packed line each:

```
Mantle: __LINKEDIT re-packed in codesign_allocate's order: 44,032 -> 38,272 bytes, 5,764 unreferenced bytes dropped
ReactiveObjC: __LINKEDIT re-packed in codesign_allocate's order: 99,704 -> 80,192 bytes, 19,512 unreferenced bytes dropped
Squirrel: __LINKEDIT re-packed in codesign_allocate's order: 54,992 -> 46,656 bytes, 8,348 unreferenced bytes dropped
ShipIt: __LINKEDIT re-packed in codesign_allocate's order: 43,880 -> 40,176 bytes, 3,704 unreferenced bytes dropped
chrome_crashpad_handler: __LINKEDIT re-packed in codesign_allocate's order: 75,632 -> 68,192 bytes, 7,452 unreferenced bytes dropped
libGLESv2.dylib: __LINKEDIT re-packed in codesign_allocate's order: 315,928 -> 310,368 bytes, 5,560 unreferenced bytes dropped
lzfse: __LINKEDIT re-packed in codesign_allocate's order: 8,182 -> 7,310 bytes, 872 unreferenced bytes dropped
demangler_gnu_v2_41: __LINKEDIT re-packed in codesign_allocate's order: 14,704 -> 14,120 bytes, 588 unreferenced bytes dropped
```

- [ ] **Step 2: Sign each with 10.9's `codesign`, and compare the streams before and after**

```sh
for n in Mantle ReactiveObjC Squirrel ShipIt chrome_crashpad_handler libGLESv2.dylib lzfse demangler_gnu_v2_41; do
  o="$W/$n.out"; r=$("$B/drydock-macho-rewrite" info "$o" | sed -n 's/^resign 10.9: //p')
  cp "$o" "$o.s"; rc=0; codesign --force --sign - "$o.s" 2>/dev/null || rc=$?; v=0; codesign -v "$o.s" 2>/dev/null || v=$?
  for x in "$o" "$o.s"; do
    { xcrun dyldinfo -rebase -bind -weak_bind -lazy_bind -export "$x" | tail -n +2; nm -ap "$x"; otool -Iv "$x" | tail -n +2; } > "$x.all"; done
  echo "$n: resign [$r] sign=$rc v=$v dyldinfo=$(xcrun dyldinfo -rebase -bind -weak_bind -lazy_bind -export "$o" | tail -n +2 | wc -l | tr -d ' ') $(cmp -s "$o.all" "$o.s.all" && echo same || echo DIFF)"
done
chmod +x "$W"/*.out.s
echo _ZN3foo3barEv | "$W/demangler_gnu_v2_41.out.s"
printf 'hello hello hello hello\n' > "$W/in.txt"
"$W/lzfse.out.s" -encode -i "$W/in.txt" -o "$W/in.lz" && "$W/lzfse.out.s" -decode -i "$W/in.lz" -o "$W/out.txt" && cmp "$W/in.txt" "$W/out.txt" && echo "lzfse round-trips"
for n in Mantle ReactiveObjC Squirrel; do "$B/drydock-macho-rewrite" info "$W/$n.out.s" | grep objc-methods; done
```

Expected (the `dyldinfo` counts are the five streams' lines, before signing; `same` means those lines, `nm -ap` and `otool -Iv` are identical after):

```
Mantle: resign [ok] sign=0 v=0 dyldinfo=1298 same
ReactiveObjC: resign [ok] sign=0 v=0 dyldinfo=6208 same
Squirrel: resign [ok] sign=0 v=0 dyldinfo=1987 same
ShipIt: resign [ok] sign=0 v=0 dyldinfo=1154 same
chrome_crashpad_handler: resign [ok] sign=0 v=0 dyldinfo=3693 same
libGLESv2.dylib: resign [ok] sign=0 v=0 dyldinfo=25848 same
lzfse: resign [ok] sign=0 v=0 dyldinfo=306 same
demangler_gnu_v2_41: resign [ok] sign=0 v=0 dyldinfo=416 same
foo::bar()
lzfse round-trips
objc-methods: 0 relative, 32 absolute
objc-methods: 0 relative, 143 absolute
objc-methods: 0 relative, 27 absolute
```

Then `sh tests/codesign_order_test.sh "$B"` once more (M4's gate): `0 failure(s)`.

- [ ] **Step 3: Close QUEUE item 30, and delete the spec and this plan**

In `docs/superpowers/QUEUE.md`, replace row 36:

```markdown
| 30 | `fixups set classic` output cannot be re-signed with 10.9's `codesign` | `specs/2026-09-26-classic-fixups-re-signable-design.md` | `plans/2026-09-26-classic-fixups-re-signable.md` | **planned** 2026-09-26; see below |
```

with (keep it one line, so the other plan's `:35` does not move; `$FIRST..$LAST` is this plan's first and last commit):

```markdown
| 30 | `fixups set classic` output cannot be re-signed with 10.9's `codesign` | spec and plan deleted once implemented | `$FIRST..$LAST` | **done**: a run that changes `__LINKEDIT` packs it in `codesign_allocate`'s order; `docs/codesign-order.md` |
```

and replace item 30's section, from `## Item 30: \`fixups set classic\` output cannot be re-signed on 10.9` to the end of the file, with a closing paragraph that records, in this order: the landed range; that 10.9's `codesign_allocate` requires `__LINKEDIT` in ld64's order and silently re-signs corrupt a file whose pieces do not add up (`docs/codesign-order.md`); that `info` says `resign 10.9:`; and Step 2's result on the eight binaries, in one sentence each for the six OpenCode images and the two Ghidra tools. Then:

```sh
git rm docs/superpowers/specs/2026-09-26-classic-fixups-re-signable-design.md docs/superpowers/plans/2026-09-26-classic-fixups-re-signable.md
git grep -n "classic-fixups-re-signable" -- . ':!docs/superpowers/QUEUE.md'   # expect nothing
git grep -c "codesign-order.md" -- docs/superpowers/QUEUE.md                  # positive control: expect 1 or more
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/QUEUE.md
git commit -m "docs: QUEUE item 30 is done; its spec and plan go

Eight real binaries, six from OpenCode.app and two Ghidra tools, lowered,
converted and redirected, re-sign with 10.9's own codesign, verify, and
keep every rebase, bind, export, symbol and indirect entry through the
signing; the two Ghidra tools run.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```


---

## Self-review

- **Spec coverage.** Decision 1 (one pass at the end): Tasks 6–8. Decision 2 (the piece model and the declines): Task 6. Decision 3 (keep the stale signature; delete means delete): Tasks 6–7. Decision 4 (observed change, and repair): Task 7. Decision 5 (the verifier, rule for rule, every finding, the writer simulation): Tasks 1–3, the oracle Task 5. Decision 6 (refuse the corrupting, report the rest, the report lines): Tasks 7–8. Decision 7 (fat files, the whole-file verdict, `lipo -thin`): Tasks 3–4, 8, 10. Decision 8 (padding): Task 9. Decision 9 (later statements by construction): Task 7's `delete`, `dylib insert`, hole tests; `import_redirect_test`'s grow; the `export-last` variant (a trie rebuilt after the signature, as `mg_grow_header` leaves it, packed by Task 6). "Tests and compat output this changes": Task 7 (`import_redirect_test.sh`), Task 10 (compat). Owner's answers: Task 10. M4: Task 11.
- **Not hermetically tested:** a header grow whose rebuilt export trie outgrows its slot. No fixture here can be grown (they have no `__PAGEZERO`), and the grow tests belong to the other plan. The pass's handling of the resulting layout is Task 6's `export-last`; the real case is Task 11's `lzfse` and `demangler_gnu_v2_41`, whose `dylib append` grows the header and rebuilds the trie at the end of the file, after the bind stream.
- **Not verified here:** any current `codesign_allocate` (the modern slots in the piece model are SOURCED only), and Snow Leopard's.
