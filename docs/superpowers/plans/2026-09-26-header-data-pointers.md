# Header data pointers: move them when an executable grows — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a grow lowers an executable's image base, every rebased data pointer whose value is the base (`const void *p = &_mh_execute_header;`) loses the grow with the header, a pointer to any byte strictly between the header and its first content refuses the grow, and `mg_verify` checks both. The Java launcher stubs, which die of SIGSEGV after a grow today, then grow and run.

**Architecture:** `src/grow.[ch]` gains `mg_rebases_read`, which decodes the rebase opcodes with `src/rebase.h`'s `mrb_decode`, maps each target through its segment to a file offset and a vm address, reads its 8-byte value, and refuses what it cannot vouch for (Decision 6's rebase refusals). `mg_header_pointers` counts, moves or refuses the pointers that name the header. `mg_grow_header` calls it once before it mutates anything (to refuse) and once after (to move them). `mg_ensure_pad` counts the pointers into its "repaired N references" clause. The snapshot records every target and its value, and `mg_verify` decodes the grown image afresh and compares slot by slot, in the style of the spec's Decision 7 check 2.

**Tech Stack:** C as the 10.9 clang (Apple LLVM 6.0) accepts it; CMake through shipyard; POSIX `sh`; hand-built in-memory Mach-O fixtures in `tests/grow_test.c`; three tiny x86_64 programs compiled at test time in `tests/grown_binary_runs_test.sh`.

**Spec:** `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`. This plan implements its Decision 1 rule ("anything that names the header moves with the header … anything strictly between is refused") for **rebase values on the executable route**, which the spec calls QUEUE item 29's remaining half. It follows Decision 6's rebase refusals, adds Decision 7's check 2 with a delta of 0, and supplies the geometry-aware layer Decision 9 says the raise needs. It is not a spec milestone. It sits between M1 (landed) and M2, and M2 reuses `mg_rebases_read` and `mg_header_pointers`. Read QUEUE item 29's "Not repaired" and "I1" paragraphs too.

## The measurements that decide this plan

Measured 2026-09-26 at `88e846f` on this host (10.9, ld64-241.9). The corpus is every regular file with an x86_64 slice under `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin` and `/usr/libexec`: 1,128 files, 1,059 of them `MH_EXECUTE`. That is the list the M1 sweeps used, and Task 5 Step 2 rebuilds it. A probe linked against `libdrydockcore.a` decoded every rebase and bind stream in them, plus the 1,376 paths of the earlier survey (symlinks included), which brings in `/usr/bin/java` and its siblings.

- **Pointers that name the header: 46 executables.** They are the 42 Java launcher stubs in `JavaVM.framework/Versions/A/Commands` (`/usr/bin/java`, `jar`, `javac`, …, reached through symlinks, so not in the 1,128), `restoreui`, `MRT`, `cgpdftoraster` and `thnucups`. Each has exactly one, and every one comes from crt1: the `mh` field of `__DATA,__program_vars` (offset 0), or of the older `__DATA,__dyld` (offset 0x10, `thnucups`). libSystem hands that field to `_NSGetMachExecuteHeader`. Grown at `88e846f`, `/usr/bin/java -version` exits 139 (SIGSEGV). Grown with this plan it prints `java version "1.6.0_65"`.
- **Nothing else this plan refuses occurs on this host:**
  - a rebase value strictly inside (base, base + F): 0;
  - a rebase type other than `REBASE_TYPE_POINTER`: 0;
  - a rebase target in the segment that maps the header: 0;
  - a target past its segment's `filesize` (zero-fill) or past the file: 0;
  - a slot rebased twice: 0 among 661,125 targets in 1,300 executables;
  - a second `LC_DYLD_INFO`: 0;
  - a bind in `__TEXT`: 0 of 129,363 binds.
- **`&_mh_execute_header + 16` is one line of C away.** `const char *q = (const char *)&_mh_execute_header + 16;` links to a rebase whose value is base + 16. That is what the strictly-inside refusal exists for.
- **Binds to the image's own header: none on this host, and they need nothing.** ld64-241.9 emits them only under `-Wl,-interposable`: `dyldinfo -bind` shows `this-image __mh_execute_header`, three for a program with two data pointers and one code reference. Default linking, `-flat_namespace`, `-export_dynamic` and a `weak_import` declaration all give rebases. dyld resolves such a bind through the export trie, whose `__mh_execute_header` entry is offset 0 and so names the moved header. A program printing whether its bound pointer equals `_dyld_get_image_header(0)` grows at `88e846f` and still says "names". Task 2 pins that.
- **Classic relocations: 3 executables.** `dnsextd`, `mDNSResponder` and `mDNSResponderHelper` are PIE with no `LC_DYLD_INFO`. dyld slides their pointers from `LC_DYSYMTAB`'s local relocation entries (114, 547 and 190 of them, all `X86_64_RELOC_UNSIGNED`, 8 bytes, relative to the first writable segment). Each has one pointer whose value is the base, at `__DATA,__dyld+0x10`. At `88e846f` each grows, announces "repaired 1 reference to the header" (its code reference), and leaves that pointer a page past the header. One more (`thnucups`) has local relocations beside `LC_DYLD_INFO`. dyld reads only the rebase opcodes there, and so does this plan.
- **Claude Code** (the pristine 2.1.282 snapshot, `fixups set classic` and then a 6000-byte `rpath append`): 0 pointers name the header, and the output is byte-identical to `88e846f`'s: "repaired 7 references to the header", `verify` OK, 1.41 s at `88e846f` against 1.38 s.

### The code half of I1, measured

QUEUE item 29's I1 asks for "any address strictly inside (base, base + F)" to refuse, "once for both routes via a range scan". The probe copied `src/hdrref.c`, changed its candidate test from `target == base` to `base < target < base + F`, and let `mhr_confirm`'s sweep run on past an unconfirmed candidate, counting each.

| corpus | range candidates | in executables | confirmed as instructions |
|---|---|---|---|
| the 1,128 (1,059 `MH_EXECUTE`) | 1,060 | 120 | **0** |
| the earlier survey's 966 x86_64 executables | 928 | 108 | **0** |
| Claude Code 2.1.282 | 29 | 1 | **0** |

**Positive control:** the same modified probe with the range narrowed to {base} finds the 152 exact-base candidates in 43 executables, and confirms 151 of them, all of them in 42 executables. That matches M1's "42 of 43 repair". So the zero is the answer, not a broken probe. Of the 120 executables with range candidates, 119 grow at `88e846f`.

## The I1 decision: (a), data pointers only

This plan does **(a)**: the data half of I1 (a rebase value exactly the base loses G; one strictly inside refuses). The code half stays with dylib-growth M2. The reason is the measurement above. Rebase values are exact: a value is inside or it is not. It costs nothing to refuse the inside ones, since there are none here, and a program gets one with a single line of C. The code half has no answer until the spec says what an in-range candidate that cannot be confirmed means, and that choice decides the grow yield:

- **refuse it** (as M1 does for an exact-base candidate): 119 executables that grow today, and **Claude Code**, stop growing, for 0 confirmed references;
- **ignore it, and refuse only a confirmed one**: nothing measured changes. The grow pays another full scan of `__text`, and a sweep per candidate, for a refusal that has never fired.

That is a product choice, so it is Question 1 below. No task here depends on its answer.

## Questions for the owner

1. **The code half of I1: what does an in-range candidate that cannot be confirmed mean?** *Recommended:* in M2, refuse only a confirmed instruction whose RIP-relative target lies strictly inside (base, base + F), and let an unconfirmable in-range candidate pass. Refusing those would stop Claude Code and 119 host executables growing, and 0 of their 1,089 candidates is real. An exact-base candidate keeps M1's stricter rule, because there every confirmed one is patched and a miss corrupts. The symbol half of I1 (a non-stab `N_SECT` symbol strictly inside) is exact like this plan's. There are 0 on this host. *Recommended:* it goes into M2 with the code half, since the raise route must classify every symbol anyway.
2. **Refuse an executable whose pointers are in classic local relocations (Task 4)?** *Recommended: yes.* The cost is three executables that grow today (`dnsextd`, `mDNSResponder`, `mDNSResponderHelper`). Each of them has a pointer that the grow leaves a page past the header today, while its announcement says the header references were repaired. The alternative is to read `X86_64_RELOC_UNSIGNED` local relocations as a second source of pointers. That is a decoder, a base address (the first writable segment) and a verification of its own, for three daemons. Task 4 is self-contained. Dropping it leaves those three growing as they do today, wrongly, and changes nothing else in this plan.
3. **One clause or two in the announcement?** This plan counts moved pointers into the existing "; repaired N references to the header" (spec Decision 8's wording, whose tests match only the stable prefix). *Recommended: one clause.* A pointer to the header is a reference to it. The Java stub's line then reads "…; repaired 1 reference to the header". The alternative is a separate "; moved N pointers to the header". That changes `mg_ensure_pad`'s last `fprintf` and Task 2's three announcement expectations.

## Global Constraints

- **Line numbers** are at `88e846f`, `main` when this plan was written. Every edit also quotes the text it anchors on, and that text is what to match. `src/grow.c`'s and `tests/grow_test.c`'s line numbers drift from task to task.
- **Build:** `B=/private/tmp/build/schmonz/drydock-native`; `/usr/local/mavergreen/bin/shipyard-cmake --build "$B" -j`. That directory is already configured. Do not configure with `--preset`. If it ever needs configuring again: `/usr/local/mavergreen/bin/shipyard-cmake -S . -B "$B" -G Ninja -DCMAKE_TOOLCHAIN_FILE=/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/MavericksToolchain.cmake -DMAVERICKS_EXPECTED_MODE=native -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64`.
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavergreen/bin/shipyard-ctest --test-dir "$B"`. At `88e846f` the suite has 27 tests (`chained_fixups` SKIPs). A single C test runs as `"$B/grow_test"`, and the shell test as `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`, from the repo root.
- **Rebuild check (clock skew here; `touch` can fail to relink).** Every build in this plan edits `src/grow.h` or `tests/grow_test.c`, so before every build delete every object and the binaries you are about to run:
  ```sh
  find "$B/CMakeFiles" -name '*.o' -exec rm {} +
  rm -f "$B/libdrydockcore.a" "$B/grow_test" "$B/drydock-macho-rewrite"
  pre=$(cat "$B/.last-sha" 2>/dev/null)
  /usr/local/mavergreen/bin/shipyard-cmake --build "$B" -j
  shasum -a 256 "$B/grow_test" "$B/drydock-macho-rewrite" | tee "$B/.last-sha"
  ```
  Then confirm that the sums changed from `$pre`. A test result against an unchanged binary is not a result. Below, "build (rebuild check)" means exactly this.
- **TDD and mutation proof** for every task. Write the test first and see it fail for the stated reason; then write the code. Then apply every row of the task's mutation table, each alone, rebuild (rebuild check), and see it fail the named test. Mutate only a saved copy's original: `M=$(mktemp -d -t datapointers); cp src/grow.c "$M/"` (10.9's `mktemp -d` needs a template). Edit, rebuild, run, then `cp "$M/grow.c" src/grow.c && cmp src/grow.c "$M/grow.c"`, and rebuild. **Never `git stash` and never `git checkout --`**: restore only from the saved copy. A mutation that no test kills is a finding: add the test that kills it, in the same task.
- **Comments are a last resort:** prefer a test, then the commit message, then a doc, then one inline sentence. No history narration, and no reference to a plan or spec from source (both are deleted once implemented).
- **Exit codes:** `EX_REFUSED` = 1 (`MR_REFUSED`), `EX_FAIL` = 2 (`MR_FAIL`). A parse error is 2. A statement never writes its input, and nothing is written on a refusal.
- **Every refusal this plan adds happens before anything is mutated**, with its reason on stderr: `ERROR: <reason>; refusing to grow`.
- **Every grep negative needs a positive control.** In shell suites, `rc=0; cmd || rc=$?`.
- **char[16] names:** print with `%.16s`, compare with `strncmp(..., 16)`.
- **Staging and pushing:** stage explicit paths only (never `git add -A` or `.`); commit on `main`; do not push. Every commit message ends with:
  ```
  Co-Authored-By: <authoring model> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
  ```
- **CI runs on `macos-26-arm64`** from a cross build, and x86_64 test programs run there under Rosetta. `grow_test`'s fixtures are hand-built bytes, the same on every host. `tests/grown_binary_runs_test.sh`'s `ptr`, `inside` and `self` are linked by CI's clang for 10.9 x86_64. Their checks are behavioural (what the program prints, the grow's exit status and message). The one check that reads link output, "self binds its own `__mh_execute_header`", SKIPs where `/Library/Developer/CommandLineTools/usr/bin/dyldinfo` is absent. After the owner pushes, CI is a separate gate.

## Review Focus

1. **A pointer whose value cannot be read from the file, or that dyld would slide differently.** This covers a target in zero-fill, straddling or past the file, of type `TEXT_ABSOLUTE32`, or in the segment that maps the header. The grow must refuse before changing a byte. Pinned by Task 1's `test_grow_refuses_rebases_it_cannot_read`, one row per case, with "nothing changed".
2. **The rule's edges.** Base + 1 and base + F − 1 refuse. Base + F (the first byte of content) and base − 0x1000 (below the image) are left alone. Pinned by Task 2's `test_grow_refuses_a_pointer_inside_the_header` and `test_grow_moves_the_pointers_that_name_the_header`, whose fixture carries both of the latter.
3. **A slot rebased twice.** dyld would slide it twice, and a per-slot patch would subtract G twice, so it is refused up front. Pinned by Task 1's "a slot rebased twice" row.
4. **A bind to the image's own header.** It needs no repair, and must still run after the grow. Pinned by Task 2's `self` fixture in `tests/grown_binary_runs_test.sh`.
5. **Classic local relocations, with and without rebase opcodes beside them.** Refused without them; read from the opcodes with them (as dyld does). Pinned by Task 4's `test_rebases_read_refuses_local_relocations` and `test_grow_refuses_local_relocations`.

## Plan decisions at a glance

Each is repeated, with its reason, in the task that makes it.

- Task 1: the reader lives in `src/grow.[ch]` (`mg_rebases_read`), not `src/rebase.[ch]`. `rebase.h` is deliberately free of segment geometry (spec Decision 9), and what to refuse is the grow's policy. It keeps stream order, which verification compares index by index, and it checks for a slot named twice on a sorted copy.
- Task 1: it refuses exactly Decision 6's rebase list (type, segment that maps the header, past `filesize`), plus a stream past the file, one that does not decode, two `LC_DYLD_INFO`s and a slot named twice. None occurs on this host.
- Task 2: `mg_header_pointers` does count, move and the strictly-inside refusal in one walker, like `mg_header_symbols` and `mg_init_offsets_pass`. `mg_grow_header` calls it before mutating, with a grow of 0, and after, with the grow. The inside refusal uses (base, base + F), F being `mg_first_sect_off`, exactly the spec's one rule.
- Task 2: moved pointers join code references in the one "repaired N references" clause (Question 3).
- Task 2: a bind to the header needs nothing. A test pins that, and no code is added.
- Task 3: check 2 of Decision 7, with a delta of 0. The snapshot keeps every target (its vm address and value), and `mg_verify` re-reads the grown image and compares index by index: same count, same vm address, same value, except that a value that was the old base must now be the new base. It neither calls nor shares `mg_header_pointers`.
- Task 4: an executable with local relocations and no rebase opcodes is refused (Question 2).
- Task 5: the corpus sweep, the Java stub, QUEUE item 29 and the spec. The code half of I1 goes to M2 (Question 1).

## File structure

| file | responsibility | task |
|---|---|---|
| `src/grow.h` | `mg_rbval`, `mg_rebases`, `mg_rebases_read`, `mg_rebases_free` (1); `mg_header_pointers` (2); the snapshot's `rb` (3); contracts | 1–4 |
| `src/grow.c` | the reader (1, 4); `mg_header_pointers`, the refusal, the move and the announcement (2); snapshot and `mg_verify_pointers` (3) | 1–4 |
| `tests/grow_test.c` | `build_pointer_image` and the reader's tests (1); moving, refusing, announcing (2); verification (3); local relocations (4) | 1–4 |
| `tests/grown_binary_runs_test.sh` | `ptr` grows and runs, `inside` refuses, `self` grows and runs | 2 |
| `compat/README.md`, `docs/superpowers/QUEUE.md`, `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md` | the announcement's meaning; item 29; the spec's "not handled" text | 5 |

`CMakeLists.txt` does not change: `src/rebase.c` is already in `drydockcore`.

## How this plan was checked

Every code block below was applied, task by task, to a `git archive` of `88e846f` in a scratch directory, with its own build configured by the command above. At each task:

- the named tests failed exactly as each "Run it to see it fail" step says, and then passed;
- the whole ctest suite passed at the end (27 tests, `chained_fixups` skipped, as on `main`);
- every row of every mutation table (38 rows, 4 of which also name `tests/grown_binary_runs_test.sh`) was applied alone to that task's finished files, rebuilt after deleting every object, and failed the test its row names.

The sweep numbers in Task 5 are from that build against a build of `88e846f`.

---
### Task 1: Read every rebase target, and refuse a grow that cannot

**Files:**
- Modify: `src/grow.h` (after `#include "hdrref.h"` at `:60`; before `/* What mg_verify compares a grown image against` at `:180`; `mg_grow_header`'s contract at `:364`)
- Modify: `src/grow.c` (`#include <mach-o/nlist.h>` at `:3`; before `/* mg_snapshot_take's mhr_scan callback` at `:371`; after `if (mg_header_symbols(buf, fsize, 0, grow, 0) != 0) return -1;` at `:1418`)
- Test: `tests/grow_test.c` (new tests before `int main(void) {` at `:3293`; calls after `test_confirm_needs_function_starts_when_the_list_is_empty();` at `:3404`)

**Interfaces:**
- Consumes: `mrb_decode`, `mrb_sort`, `mrb_free`, `mrb_set`, `mrb_slot` (`src/rebase.h`); `mi_wrap`, `mi_each_lc` (`src/image.h`); in the tests, `build_image`, `find_lc`, `seg_named`, `stderr_contains_during` (all already in `tests/grow_test.c`).
- Produces (Tasks 2–4 use them):
  - `typedef struct { uint64_t at, vm, value; } mg_rbval;` and `typedef struct { mrb_set s; mg_rbval *v; } mg_rebases;`: the targets in stream order, `v[i]` beside `s.v[i]`.
  - `int mg_rebases_read(const uint8_t *buf, size_t fsize, mg_rebases *r, char *why, size_t whysz);` returns 0, or -1 with `*r` empty and `why` set.
  - `void mg_rebases_free(mg_rebases *r);`, which is safe on an empty `*r`.
  - In `tests/grow_test.c`: `build_pointer_image(size_t *fsize, int opts)` with `PT_CODE`, the constants `PT_BASE`, `PT_F`, `PT_DATA`, `PT_DATAVM`, `PT_LE`, `PT_FSIZE`, `PT_OPS`, `PT_FS`, `PT_N`, `pt_ptrs[4]`, `pt_seg`, `pt_type` (a poke), and the `pt_unreadable` table.

**Plan decisions.**

- **Where the reader lives.** `src/rebase.h` stays geometry-free, as spec Decision 9 has it. Mapping a slot through its segment, and deciding what a grow can vouch for, is the grow's job, so the reader goes in `src/grow.[ch]` beside the other readers the grow and its verification share.
- **What it refuses.** Spec Decision 6's rebase refusals:
  - a type other than `REBASE_TYPE_POINTER` (a 32-bit value; ld64 never emits one for x86_64);
  - a target in the segment that maps the header (a text relocation, which a grow would also misplace, since that segment's contents move relative to its start);
  - a target not wholly within its segment's `filesize` (a zero-fill slot's value is not in the file).
  It also refuses what makes the list untrustworthy: opcodes past the file, opcodes `mrb_decode` refuses, a second `LC_DYLD_INFO[_ONLY]`, and a slot named twice (dyld slides it twice).
- **Order and duplicates.** Stream order is kept, because Task 3 compares index by index. A slot named twice is found on a sorted copy.
- **When the grow calls it.** After the existing audits, before anything is mutated, so every refusal leaves the buffer as it was.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately before `int main(void) {` (`:3293`), insert:

```c
/* ---- pointers that name the header ----
 * A PIE executable whose __DATA holds pointers, with the rebase opcodes that
 * name them:
 *   __TEXT      file [0, 8192), vm 0x100000000; __text at file 4096 (F)
 *   __DATA      file [8192, 12288), vm [0x100002000, 0x100004000), the
 *               second half zero-fill; pt_ptrs at its start
 *   __LINKEDIT  file [12288, 12544), vm 0x100004000; the rebase opcodes at
 *               its start (PT_OPS), and with PT_CODE a function-starts list
 * Segment indexes: __PAGEZERO 0, __TEXT 1, __DATA 2, __LINKEDIT 3. With
 * PT_CODE, __text starts with `lea base(%rip), %rax` and is a function. */
#define PT_BASE   0x100000000ull
#define PT_F      4096u
#define PT_DATA   8192u
#define PT_DATAVM 0x100002000ull
#define PT_LE     12288u
#define PT_FSIZE  12544u
#define PT_OPS    PT_LE
#define PT_FS     (PT_LE + 64)
#define PT_CODE   1
static const uint64_t pt_ptrs[4] = {
    PT_BASE,             /* the header */
    PT_DATAVM + 0x40,    /* content */
    PT_BASE + PT_F,      /* the first byte of content */
    PT_BASE - 0x1000,    /* below the image */
};
#define PT_N 4

static uint8_t *build_pointer_image(size_t *fsize, int opts) {
    uint8_t *buf = (uint8_t *)calloc(1, PT_FSIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    uint8_t *lc = (uint8_t *)(h + 1);

    struct segment_command_64 *pz = (struct segment_command_64 *)lc;
    pz->cmd = LC_SEGMENT_64;
    pz->cmdsize = sizeof *pz;
    strcpy(pz->segname, "__PAGEZERO");
    pz->vmsize = PT_BASE;
    lc += pz->cmdsize;

    struct segment_command_64 *tx = (struct segment_command_64 *)lc;
    struct section_64 *text = (struct section_64 *)(tx + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof *text;
    strcpy(tx->segname, "__TEXT");
    tx->vmaddr = PT_BASE;
    tx->vmsize = tx->filesize = PT_DATA;
    tx->nsects = 1;
    strncpy(text->sectname, "__text", sizeof text->sectname);
    strncpy(text->segname, "__TEXT", sizeof text->segname);
    text->addr = PT_BASE + PT_F;
    text->size = 16;
    text->offset = PT_F;
    text->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    lc += tx->cmdsize;

    struct segment_command_64 *da = (struct segment_command_64 *)lc;
    struct section_64 *data = (struct section_64 *)(da + 1);
    da->cmd = LC_SEGMENT_64;
    da->cmdsize = sizeof *da + sizeof *data;
    strcpy(da->segname, "__DATA");
    da->vmaddr = PT_DATAVM;
    da->vmsize = 0x2000;
    da->fileoff = PT_DATA;
    da->filesize = PT_LE - PT_DATA;
    da->nsects = 1;
    strncpy(data->sectname, "__data", sizeof data->sectname);
    strncpy(data->segname, "__DATA", sizeof data->segname);
    data->addr = PT_DATAVM;
    data->size = sizeof pt_ptrs;
    data->offset = PT_DATA;
    lc += da->cmdsize;

    struct segment_command_64 *le = (struct segment_command_64 *)lc;
    le->cmd = LC_SEGMENT_64;
    le->cmdsize = sizeof *le;
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = PT_DATAVM + 0x2000;
    le->vmsize = 0x1000;
    le->fileoff = PT_LE;
    le->filesize = PT_FSIZE - PT_LE;
    lc += le->cmdsize;

    struct dyld_info_command *di = (struct dyld_info_command *)lc;
    di->cmd = LC_DYLD_INFO_ONLY;
    di->cmdsize = sizeof *di;
    di->rebase_off = PT_OPS;
    di->rebase_size = 8;
    lc += di->cmdsize;
    h->ncmds = 5;

    /* SET_TYPE_IMM pointer; SET_SEGMENT_AND_OFFSET_ULEB 2, 0;
     * DO_REBASE_IMM_TIMES 4; DONE */
    static const uint8_t ops[8] = { 0x11, 0x22, 0x00, 0x54, 0x00, 0, 0, 0 };
    memcpy(buf + PT_OPS, ops, sizeof ops);
    memcpy(buf + PT_DATA, pt_ptrs, sizeof pt_ptrs);

    if (opts & PT_CODE) {
        struct linkedit_data_command *fs = (struct linkedit_data_command *)lc;
        static const uint8_t starts[8] = { 0x80, 0x20, 0x00 };   /* base + 4096: __text */
        fs->cmd = LC_FUNCTION_STARTS;
        fs->cmdsize = sizeof *fs;
        fs->dataoff = PT_FS;
        fs->datasize = sizeof starts;
        memcpy(buf + PT_FS, starts, sizeof starts);
        lc += fs->cmdsize;
        h->ncmds++;
        int32_t disp = (int32_t)(PT_BASE - (PT_BASE + PT_F + 7));
        buf[PT_F] = 0x48;
        buf[PT_F + 1] = 0x8d;
        buf[PT_F + 2] = 0x05;
        memcpy(buf + PT_F + 3, &disp, sizeof disp);
    }
    h->sizeofcmds = (uint32_t)(lc - (uint8_t *)(h + 1));
    *fsize = PT_FSIZE;
    return buf;
}

static struct segment_command_64 *pt_seg(uint8_t *buf, const char *name) {
    return seg_named(buf, PT_FSIZE, name);
}

static void test_rebases_read_every_target(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == PT_N, "rebases: all %d read (got %d, %zu: %s)", PT_N, r, rb.s.n, why);
    for (size_t i = 0; r == 0 && i < rb.s.n && i < PT_N; i++)
        CHECK(rb.v[i].at == PT_DATA + 8 * i && rb.v[i].vm == PT_DATAVM + 8 * i &&
              rb.v[i].value == pt_ptrs[i],
              "rebases: target %zu is at file %#llx, vm %#llx, holding %#llx; want %#llx, %#llx, "
              "%#llx", i, (unsigned long long)rb.v[i].at, (unsigned long long)rb.v[i].vm,
              (unsigned long long)rb.v[i].value, (unsigned long long)(PT_DATA + 8 * i),
              (unsigned long long)(PT_DATAVM + 8 * i), (unsigned long long)pt_ptrs[i]);
    mg_rebases_free(&rb);
    free(buf);
}

/* A slot ending exactly at its segment's file data is still in the file. */
static void test_rebases_read_a_target_ending_at_the_segments_file_data(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    pt_seg(buf, "__DATA")->filesize = 8 * PT_N;
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == PT_N, "rebases: the last slot ends at the file data (got %d: %s)",
          r, why);
    mg_rebases_free(&rb);
    free(buf);
}

static void test_rebases_read_none_without_rebase_opcodes(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, 0);   /* no LC_DYLD_INFO at all */
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == 0, "rebases: none without LC_DYLD_INFO (got %d, %zu)", r, rb.s.n);
    mg_rebases_free(&rb);
    free(buf);
    buf = build_pointer_image(&fsize, 0);
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->rebase_size = 0;
    r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == 0, "rebases: none with empty rebase opcodes (got %d, %zu)", r, rb.s.n);
    mg_rebases_free(&rb);
    free(buf);
}

/* Each way the rebase targets cannot be read. `poke` breaks the fixture. */
typedef void (*pt_poke)(uint8_t *buf);
static void pt_type(uint8_t *buf) { buf[PT_OPS] = 0x12; }             /* TEXT_ABSOLUTE32 */
static void pt_in_text(uint8_t *buf) { buf[PT_OPS + 1] = 0x21; }      /* __TEXT */
static void pt_no_segment(uint8_t *buf) { buf[PT_OPS + 1] = 0x2f; }   /* segment 15 */
static void pt_unknown_op(uint8_t *buf) { buf[PT_OPS + 3] = 0x90; }
static void pt_zerofill(uint8_t *buf) { pt_seg(buf, "__DATA")->filesize = 16; }
static void pt_straddle(uint8_t *buf) { pt_seg(buf, "__DATA")->filesize = 20; }
static void pt_all_zerofill(uint8_t *buf) { pt_seg(buf, "__DATA")->filesize = 0; }
static void pt_past_image(uint8_t *buf) { pt_seg(buf, "__DATA")->fileoff = PT_FSIZE - 16; }
static void pt_ops_past_image(uint8_t *buf) {
    ((struct dyld_info_command *)find_lc(buf, PT_FSIZE, LC_DYLD_INFO_ONLY))->rebase_size = 1000;
}
static void pt_twice(uint8_t *buf) {        /* then SET_SEGMENT_AND_OFFSET_ULEB 2, 16; DO 1 */
    static const uint8_t again[4] = { 0x22, 0x10, 0x51, 0x00 };
    memcpy(buf + PT_OPS + 4, again, sizeof again);
}
static void pt_two_dyld_info(uint8_t *buf) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *di = (uint8_t *)find_lc(buf, PT_FSIZE, LC_DYLD_INFO_ONLY);
    memcpy((uint8_t *)(h + 1) + h->sizeofcmds, di, sizeof(struct dyld_info_command));
    h->ncmds++;
    h->sizeofcmds += sizeof(struct dyld_info_command);
}
static const struct { const char *what; pt_poke poke; const char *why; } pt_unreadable[] = {
    { "a rebase that is not a pointer", pt_type,
      "the rebase at __DATA+0 is of type 2, not a pointer" },
    { "a rebase in the segment that maps the header", pt_in_text,
      "the rebase at __TEXT+0 lies in the segment that maps the header" },
    { "a rebase naming a segment the image lacks", pt_no_segment,
      "names segment 15, and there are 4" },
    { "an unknown rebase opcode", pt_unknown_op, "unknown rebase opcode 0x90 at byte 3" },
    { "a rebase in zero-fill", pt_zerofill,
      "the rebase at __DATA+0x10 lies past the 16 bytes of that segment the file holds, so its "
      "value is not in the file" },
    { "a rebase straddling the end of its file data", pt_straddle,
      "the rebase at __DATA+0x10 lies past the 20 bytes of that segment the file holds, so its "
      "value is not in the file" },
    { "a rebase in a segment with no file data", pt_all_zerofill,
      "the rebase at __DATA+0 lies past the 0 bytes of that segment the file holds, so its "
      "value is not in the file" },
    { "a rebase past the end of the image", pt_past_image,
      "the rebase at __DATA+0x10 lies past the end of the 12544-byte image" },
    { "rebase opcodes past the end of the image", pt_ops_past_image,
      "the rebase opcodes (1000 bytes at offset 12288) run past the end of the 12544-byte image" },
    { "two LC_DYLD_INFO commands", pt_two_dyld_info, "the image has 2 LC_DYLD_INFO commands" },
    { "a slot rebased twice", pt_twice, "the rebase opcodes name __DATA+0x10 more than once" },
};

static void test_rebases_read_refuses_what_it_cannot_read(void) {
    for (size_t k = 0; k < sizeof pt_unreadable / sizeof pt_unreadable[0]; k++) {
        size_t fsize;
        uint8_t *buf = build_pointer_image(&fsize, 0);
        pt_unreadable[k].poke(buf);
        mg_rebases rb;
        char why[256] = "";
        int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
        CHECK(r == -1 && strstr(why, pt_unreadable[k].why) != NULL,
              "rebases: %s is refused (got %d, '%s')", pt_unreadable[k].what, r, why);
        CHECK(rb.s.n == 0 && rb.s.v == NULL && rb.v == NULL,
              "rebases: %s leaves nothing behind", pt_unreadable[k].what);
        mg_rebases_free(&rb);
        free(buf);
    }
}

/* And a grow refuses each, before it changes anything. */
static void test_grow_refuses_rebases_it_cannot_read(void) {
    for (size_t k = 0; k < sizeof pt_unreadable / sizeof pt_unreadable[0]; k++) {
        size_t fsize;
        uint8_t *buf = build_pointer_image(&fsize, 0);
        pt_unreadable[k].poke(buf);
        size_t fsize0 = fsize;
        uint8_t *before = (uint8_t *)malloc(fsize0);
        memcpy(before, buf, fsize0);
        char want[320];
        int r;
        snprintf(want, sizeof want, "%s; refusing to grow", pt_unreadable[k].why);
        int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000, want, &r);
        CHECK(r == -1 && said, "grow: %s is refused, saying so (got %d)", pt_unreadable[k].what, r);
        CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
              "grow: %s: nothing changed", pt_unreadable[k].what);
        free(before);
        free(buf);
    }
}

/* The control: the fixture as built grows. */
static void test_grow_accepts_readable_rebases(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "grow: the pointer fixture grows (got %d)", r);
    free(buf);
}
```

After `    test_confirm_needs_function_starts_when_the_list_is_empty();` (`:3404`), insert:

```c
    test_rebases_read_every_target();
    test_rebases_read_a_target_ending_at_the_segments_file_data();
    test_rebases_read_none_without_rebase_opcodes();
    test_rebases_read_refuses_what_it_cannot_read();
    test_grow_refuses_rebases_it_cannot_read();
    test_grow_accepts_readable_rebases();
```

- [ ] **Step 2: Run it to see it fail**

Run: build (rebuild check).
Expected: the build fails compiling `grow_test.c`: `error: use of undeclared identifier 'mg_rebases'` and `warning: implicit declaration of function 'mg_rebases_read'`.

- [ ] **Step 3: Declare the reader**

In `src/grow.h`, replace (`:59-60`):

```c
/* Code that addresses its own image's header: found, confirmed, repaired. */
#include "hdrref.h"
```

with:

```c
/* Code that addresses its own image's header: found, confirmed, repaired. */
#include "hdrref.h"

/* The rebase opcodes, decoded. */
#include "rebase.h"
```

Immediately before `/* What mg_verify compares a grown image against: the resolved addresses` (`:180`), insert:

```c
/* Every rebase target of an image, in the order its rebase opcodes name
 * them (src/rebase.h): each slot, where its 8 bytes lie in the file (`at`)
 * and in memory (`vm`), and the value the file holds there. */
typedef struct { uint64_t at, vm, value; } mg_rbval;
typedef struct { mrb_set s; mg_rbval *v; } mg_rebases;

/* Reads every rebase target into *r: none when the image has no
 * LC_DYLD_INFO[_ONLY] or its rebase opcodes are empty. Returns 0; or -1, with
 * *r empty and `why` saying what, when the image has more than one
 * LC_DYLD_INFO[_ONLY], when its rebase opcodes lie past the end of the image
 * or do not decode, or when a target is not a plain pointer
 * (REBASE_TYPE_POINTER), lies in the segment that maps the header, does not
 * lie wholly within its segment's file data, or is named more than once.
 * Free *r with mg_rebases_free, which is safe on an empty one. */
int  mg_rebases_read(const uint8_t *buf, size_t fsize, mg_rebases *r, char *why, size_t whysz);
void mg_rebases_free(mg_rebases *r);

```

In `mg_grow_header`'s contract, replace (`:364-368`):

```c
 * for; and one whose LC_SYMTAB symbol table does not fit in the image. Every
 * confirmed reference is repaired: its disp32 loses the grow, so it still
 * reaches the header. So does the value of each symbol that names the header
 * (__mh_execute_header). A failure partway through growing can leave the
 * buffer modified (see mg_ensure_pad).
```

with:

```c
 * for; one whose LC_SYMTAB symbol table does not fit in the image; and one
 * whose rebase targets mg_rebases_read cannot read. Every confirmed
 * reference is repaired: its disp32 loses the grow, so it still reaches the
 * header. So does the value of each symbol that names the header
 * (__mh_execute_header). A failure partway through growing can leave the
 * buffer modified (see mg_ensure_pad).
```

- [ ] **Step 4: Write the reader, and call it before the grow mutates anything**

In `src/grow.c`, replace `#include <mach-o/nlist.h>` (`:3`) with:

```c
#include <mach-o/nlist.h>
#include <stdarg.h>
```

Immediately before `/* mg_snapshot_take's mhr_scan callback: keep each reference to the header. */` (`:371`), insert:

```c
/* The segments a rebase can name (its segment index is four bits) and the
 * image's LC_DYLD_INFO[_ONLY]s. */
struct mg_rb_lcs {
    const struct segment_command_64 *seg[16];
    int nsegs, ndi;
    const struct dyld_info_command *di;
};

static int mg_rb_lcs_cb(const struct load_command *lc, void *ctx_) {
    struct mg_rb_lcs *c = (struct mg_rb_lcs *)ctx_;
    if (lc->cmd == LC_SEGMENT_64 && c->nsegs < 16)
        c->seg[c->nsegs++] = (const struct segment_command_64 *)lc;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        c->ndi++;
        if (!c->di) c->di = (const struct dyld_info_command *)lc;
    }
    return 0;
}

static int mg_rb_fail(mg_rebases *r, char *why, size_t whysz, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
static int mg_rb_fail(mg_rebases *r, char *why, size_t whysz, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(why, whysz, fmt, ap);
    va_end(ap);
    mg_rebases_free(r);
    return -1;
}

int mg_rebases_read(const uint8_t *buf, size_t fsize, mg_rebases *r, char *why, size_t whysz) {
    mi_image im;
    struct mg_rb_lcs c;
    char dwhy[160];
    memset(r, 0, sizeof *r);
    memset(&c, 0, sizeof c);
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0)
        return mg_rb_fail(r, why, whysz, "the image does not validate");
    mi_each_lc(&im, mg_rb_lcs_cb, &c);
    if (c.ndi > 1)
        return mg_rb_fail(r, why, whysz, "the image has %d LC_DYLD_INFO commands", c.ndi);
    if (!c.di || !c.di->rebase_size) return 0;
    if (c.di->rebase_size > fsize || c.di->rebase_off > fsize - c.di->rebase_size)
        return mg_rb_fail(r, why, whysz, "the rebase opcodes (%u bytes at offset %u) run past "
                          "the end of the %zu-byte image", c.di->rebase_size, c.di->rebase_off,
                          fsize);
    int rc = mrb_decode(buf + c.di->rebase_off, c.di->rebase_size, c.nsegs, &r->s, dwhy,
                        sizeof dwhy);
    if (rc != MRB_OK)
        return mg_rb_fail(r, why, whysz, "%s", rc == MRB_NOMEM ? "out of memory" : dwhy);
    r->v = (mg_rbval *)malloc(r->s.n * sizeof *r->v + 1);
    if (!r->v) return mg_rb_fail(r, why, whysz, "out of memory");
    for (size_t i = 0; i < r->s.n; i++) {
        const mrb_slot *t = &r->s.v[i];
        const struct segment_command_64 *seg = c.seg[t->seg];
        if (t->type != REBASE_TYPE_POINTER)
            return mg_rb_fail(r, why, whysz, "the rebase at %.16s+%#llx is of type %u, not a "
                              "pointer", seg->segname, (unsigned long long)t->off, t->type);
        if (seg->fileoff == 0 && seg->filesize > 0)
            return mg_rb_fail(r, why, whysz, "the rebase at %.16s+%#llx lies in the segment that "
                              "maps the header", seg->segname, (unsigned long long)t->off);
        if (seg->filesize < 8 || t->off > seg->filesize - 8)
            return mg_rb_fail(r, why, whysz, "the rebase at %.16s+%#llx lies past the %llu bytes "
                              "of that segment the file holds, so its value is not in the file",
                              seg->segname, (unsigned long long)t->off,
                              (unsigned long long)seg->filesize);
        if (seg->fileoff > fsize || fsize - seg->fileoff < 8 || t->off > fsize - seg->fileoff - 8)
            return mg_rb_fail(r, why, whysz, "the rebase at %.16s+%#llx lies past the end of the "
                              "%zu-byte image", seg->segname, (unsigned long long)t->off, fsize);
        r->v[i].at = seg->fileoff + t->off;
        r->v[i].vm = seg->vmaddr + t->off;
        memcpy(&r->v[i].value, buf + r->v[i].at, sizeof r->v[i].value);
    }
    mrb_set o = { (mrb_slot *)malloc(r->s.n * sizeof *r->s.v + 1), r->s.n, r->s.n, 0 };
    if (!o.v) return mg_rb_fail(r, why, whysz, "out of memory");
    memcpy(o.v, r->s.v, r->s.n * sizeof *o.v);
    mrb_sort(&o);
    for (size_t i = 1; i < o.n; i++) {
        if (o.v[i].seg != o.v[i - 1].seg || o.v[i].off != o.v[i - 1].off) continue;
        snprintf(dwhy, sizeof dwhy, "%.16s+%#llx", c.seg[o.v[i].seg]->segname,
                 (unsigned long long)o.v[i].off);
        mrb_free(&o);
        return mg_rb_fail(r, why, whysz, "the rebase opcodes name %s more than once", dwhy);
    }
    mrb_free(&o);
    return 0;
}

void mg_rebases_free(mg_rebases *r) {
    mrb_free(&r->s);
    free(r->v);
    r->v = NULL;
}

```

Replace `    if (mg_header_symbols(buf, fsize, 0, grow, 0) != 0) return -1;` (`:1418`) with:

```c
    if (mg_header_symbols(buf, fsize, 0, grow, 0) != 0) return -1;
    {
        mg_rebases rb;
        char why[256];
        if (mg_rebases_read(buf, fsize, &rb, why, sizeof why) != 0) {
            fprintf(stderr, "ERROR: %s; refusing to grow\n", why);
            return -1;
        }
        mg_rebases_free(&rb);
    }
```

- [ ] **Step 5: Run it to see it pass**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: `macho_grow_test: all cases pass`. Then the whole suite: 27 tests, all pass (`chained_fixups` skipped).

- [ ] **Step 6: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`; each row fails with the quoted `FAIL:` text)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (c.ndi > 1)` | `    if (c.ndi > 2)` | `test_rebases_read_refuses_what_it_cannot_read` ("two LC_DYLD_INFO commands is refused") |
| 2 | `    if (c.di->rebase_size > fsize \|\| c.di->rebase_off > fsize - c.di->rebase_size)` | `    if (0)` | the same test ("rebase opcodes past the end of the image is refused") |
| 3 | `        if (t->type != REBASE_TYPE_POINTER)` | `        if (0)` | the same test ("a rebase that is not a pointer is refused") |
| 4 | `        if (seg->fileoff == 0 && seg->filesize > 0)` | `        if (0)` | the same test ("a rebase in the segment that maps the header is refused") |
| 5 | `        if (seg->filesize < 8 \|\| t->off > seg->filesize - 8)` | `        if (t->off > seg->filesize - 8)` | the same test ("a rebase in a segment with no file data is refused") |
| 6 | the same line | `        if (seg->filesize < 8 \|\| t->off >= seg->filesize - 8)` | `test_rebases_read_a_target_ending_at_the_segments_file_data` |
| 7 | `        if (seg->fileoff > fsize \|\| fsize - seg->fileoff < 8 \|\| t->off > fsize - seg->fileoff - 8)` | `        if (0)` | `test_rebases_read_refuses_what_it_cannot_read` ("a rebase past the end of the image is refused") |
| 8 | `        r->v[i].at = seg->fileoff + t->off;` | `        r->v[i].at = t->off;` | `test_rebases_read_every_target` ("target 0 is at file") |
| 9 | `        r->v[i].vm = seg->vmaddr + t->off;` | `        r->v[i].vm = seg->fileoff + t->off;` | `test_rebases_read_every_target` |
| 10 | `        if (o.v[i].seg != o.v[i - 1].seg \|\| o.v[i].off != o.v[i - 1].off) continue;` | `        continue;` | `test_rebases_read_refuses_what_it_cannot_read` ("a slot rebased twice is refused") |
| 11 | the same line | `        if (o.v[i].seg != o.v[i - 1].seg) continue;` | `test_rebases_read_every_target` ("all 4 read") |
| 12 | `        if (mg_rebases_read(buf, fsize, &rb, why, sizeof why) != 0) {` (in `mg_grow_header`) | `        if (mg_rebases_read(buf, fsize, &rb, why, sizeof why) != 0 && 0) {` | `test_grow_refuses_rebases_it_cannot_read` ("a rebase that is not a pointer is refused, saying so") |

(Row 12 keeps the call: removing it would free an uninitialized `rb`, which aborts rather than fails.)

- [ ] **Step 7: Commit**

```bash
git add src/grow.h src/grow.c tests/grow_test.c
git commit -m "feat(grow): read every rebase target, and refuse what cannot be read

A grow is about to move the rebased pointers that name the header, so it
must first read every rebase target's value from the file. mg_rebases_read
decodes the opcodes, maps each slot through its segment and reads its 8
bytes. A grow now refuses, before it changes anything, an image whose
rebases it cannot vouch for: a type other than pointer, a slot in the
segment that maps the header, in zero-fill or past the file, a slot named
twice, opcodes past the file or that do not decode, and a second
LC_DYLD_INFO. None occurs among this host's executables.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 2: Move the pointers that name the header, and refuse one inside it

**Files:**
- Modify: `src/grow.h` (the top comment's last sentence at `:28-29`; `mg_ensure_pad`'s contract at `:113-115`; after Task 1's `void mg_rebases_free(mg_rebases *r);`; `mg_grow_header`'s contract as Task 1 left it)
- Modify: `src/grow.c` (`mg_ensure_pad` at `:82` and `:106-108`; after Task 1's `mg_rebases_free` definition; Task 1's audit block in `mg_grow_header`; after the block beginning `    if (mg_header_symbols(buf, final_size, snap.base, grow, 1) != 0) {`)
- Test: `tests/grow_test.c` (new tests before `int main(void) {`; calls after Task 1's `test_grow_accepts_readable_rebases();`), `tests/grown_binary_runs_test.sh` (before its last line, `[ "$fail" -eq 0 ] || …`, at `:223`)

**Interfaces:**
- Consumes: Task 1's `mg_rebases_read`, `mg_rebases_free`, `mg_rbval`, `build_pointer_image`, `PT_*`, `pt_ptrs`; in the tests `ensure_pad_stderr`, `stderr_contains_during`, `seg_named`; in the shell test `grow`, `lowered`, `same`, `ok`, `bad`, `skip`, `$CC`, `$FF`.
- Produces: `int64_t mg_header_pointers(uint8_t *buf, size_t fsize, uint64_t base, uint64_t first, uint32_t grow, char *why, size_t whysz);`. It returns how many rebase targets hold `base`, having taken `grow` off each (0 to count only). It returns -1 with `why` set when the targets cannot be read or one holds a value strictly inside (base, base + first). Task 3's verification must agree with it without calling it.

**Plan decisions.**

- **One walker.** `mg_header_pointers` counts, moves and refuses, as `mg_header_symbols` and `mg_init_offsets_pass` do. With `grow` 0 it only counts, since taking 0 off changes nothing; the count test pins that.
- **Where the grow calls it.** `mg_grow_header` calls it twice. The first call is Task 1's audit, now with the image base and `insert` (F), and refuses before anything moves. The second comes after the symbols move, on the grown buffer, with the snapshot's (old) base and the grow.
- **Strictly inside.** The refusal is the spec's one rule: base < value < base + F. Base itself moves; base + F and above are content and stay; below base is not the image and stays.
- **The announcement.** `mg_ensure_pad` counts the pointers into its clause, as M1 counts code references (Question 3).
- **Binds.** A bind to the image's own `__mh_execute_header` needs no code: dyld resolves it through the export trie, which already names the moved header. The shell test's `self` pins that on this host's linker.
- **The end-to-end fixtures.** `ptr` stands for a Java stub's `__program_vars` pointer; `inside` is the one-line way to get a strictly-inside value.

- [ ] **Step 1: Write the failing in-memory tests**

In `tests/grow_test.c`, immediately before `int main(void) {`, insert:

```c
/* The pointer values in __DATA after a grow, wherever the file now holds them. */
static const uint64_t *pt_values(uint8_t *buf, size_t fsize) {
    struct segment_command_64 *da = seg_named(buf, fsize, "__DATA");
    return da ? (const uint64_t *)(buf + da->fileoff) : NULL;
}

static void check_pointers_after(const char *what, uint32_t grow_req, uint32_t grow, int also) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    uint64_t want[PT_N];
    memcpy(want, pt_ptrs, sizeof want);
    if (also) {                                  /* slot 3 names the header too */
        ((uint64_t *)(buf + PT_DATA))[3] = PT_BASE;
        want[3] = PT_BASE;
    }
    want[0] -= grow;
    if (also) want[3] -= grow;
    int r = mg_grow_header(&buf, &fsize, grow_req);
    CHECK(r == 0, "%s: the grow succeeds (got %d)", what, r);
    const uint64_t *v = r == 0 ? pt_values(buf, fsize) : NULL;
    for (int i = 0; v && i < PT_N; i++)
        CHECK(v[i] == want[i], "%s: pointer %d holds %#llx after the grow, want %#llx", what, i,
              (unsigned long long)v[i], (unsigned long long)want[i]);
    free(buf);
}

/* The header moves down by the grow; what names it follows, and what names
 * content, the first byte of content, or nothing in the image stays. */
static void test_grow_moves_the_pointers_that_name_the_header(void) {
    check_pointers_after("pointers", 0x1000, 0x1000, 0);
    check_pointers_after("two pointers to the header", 0x1000, 0x1000, 1);
    check_pointers_after("pointers, two-page grow", 0x1001, 0x2000, 0);
}

/* A value strictly inside (base, base + F) names a byte of the header or its
 * load commands, which the grow moves apart: refused, nothing changed. */
static void check_grow_refuses_a_pointer_inside(uint64_t value, const char *needle) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    ((uint64_t *)(buf + PT_DATA))[1] = value;
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000, needle, &r);
    CHECK(r == -1 && said, "inside: %#llx is refused, saying '%s' (got %d)",
          (unsigned long long)value, needle, r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "inside: %#llx: nothing changed", (unsigned long long)value);
    free(before);
    free(buf);
}

static void test_grow_refuses_a_pointer_inside_the_header(void) {
    check_grow_refuses_a_pointer_inside(PT_BASE + 1,
        "ERROR: the pointer at 0x100002008 names 0x100000001, between the header at 0x100000000 "
        "and its first content at 0x100001000, which a grow moves apart; refusing to grow");
    check_grow_refuses_a_pointer_inside(PT_BASE + PT_F - 1,
        "ERROR: the pointer at 0x100002008 names 0x100000fff, between the header");
}

static void test_header_pointers_counts_without_moving(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    ((uint64_t *)(buf + PT_DATA))[3] = PT_BASE;
    uint8_t *before = (uint8_t *)malloc(fsize);
    memcpy(before, buf, fsize);
    char why[256] = "";
    int64_t n = mg_header_pointers(buf, fsize, PT_BASE, PT_F, 0, why, sizeof why);
    CHECK(n == 2, "count: two pointers name the header (got %lld: %s)", (long long)n, why);
    CHECK(memcmp(before, buf, fsize) == 0, "count: counting moves nothing");
    free(before);
    free(buf);
}

/* mg_ensure_pad announces the pointers it moved, with the code it repaired. */
static void check_ensure_pad_announces(const char *what, int opts, int also, const char *tail) {
    size_t fsize;
    int r;
    uint8_t *buf = build_pointer_image(&fsize, opts);
    if (also) ((uint64_t *)(buf + PT_DATA))[3] = PT_BASE;
    char *err = ensure_pad_stderr(&buf, &fsize, PT_F + 1, &r);
    CHECK(r == 0 && strstr(err, tail) != NULL, "%s: announced as '...%s' (got %d):\n%s", what,
          tail, r, err);
    free(err);
    free(buf);
}

static void test_ensure_pad_announces_the_pointers_it_moves(void) {
    check_ensure_pad_announces("one pointer", 0, 0,
        "image base 0x100000000 -> 0xfffff000; repaired 1 reference to the header\n");
    check_ensure_pad_announces("two pointers", 0, 1,
        "image base 0x100000000 -> 0xfffff000; repaired 2 references to the header\n");
    check_ensure_pad_announces("a pointer and an instruction", PT_CODE, 0,
        "image base 0x100000000 -> 0xfffff000; repaired 2 references to the header\n");
}
```

After Task 1's `    test_grow_accepts_readable_rebases();`, insert:

```c
    test_grow_moves_the_pointers_that_name_the_header();
    test_grow_refuses_a_pointer_inside_the_header();
    test_header_pointers_counts_without_moving();
    test_ensure_pad_announces_the_pointers_it_moves();
```

- [ ] **Step 2: Write the failing end-to-end test**

In `tests/grown_binary_runs_test.sh`, immediately before its last line, `[ "$fail" -eq 0 ] || { echo "grown_binary_runs_test: $fail failure(s)"; exit 1; }` (`:223`), insert:

```sh
# ---- 4. data that points at its own header ----------------------------------
# ptr keeps its own header's address in data, as crt1's __program_vars does in
# every Java launcher stub on 10.9: a rebased pointer whose value is the base.
# The grow must move it with the header, say so, and leave a binary that runs
# as the original does. inside points 16 bytes into its header, which a grow
# moves away from what follows it, so its grow refuses and writes nothing.
# self takes the same address through -interposable, which this host's ld64
# makes a bind to its own __mh_execute_header; dyld resolves that through the
# export trie, which a grow keeps naming the header, so it runs too.
cat >"$T/ptr.c" <<'EOF'
#include <stdio.h>
#include <mach-o/dyld.h>
#include <mach-o/ldsyms.h>
const void *hp = &_mh_execute_header;
int main(void) {
    const void *h = _dyld_get_image_header(0);
    printf("data pointer %s the header\n", hp == h ? "names" : "MISSES");
    return hp == h ? 0 : 1;
}
EOF
cat >"$T/inside.c" <<'EOF'
#include <stdio.h>
#include <mach-o/ldsyms.h>
const char *in = (const char *)&_mh_execute_header + 16;
int main(void) { printf("%p\n", (const void *)in); return 0; }
EOF
{ "$CC" $FF -Wl,-headerpad,0 -o "$T/ptr" "$T/ptr.c" &&
  "$CC" $FF -Wl,-headerpad,0 -o "$T/inside" "$T/inside.c" &&
  "$CC" $FF -Wl,-headerpad,0 -Wl,-interposable -o "$T/self" "$T/ptr.c"; } \
    || { echo "grown_binary_runs_test: could not link ptr, inside or self" >&2; exit 1; }

"$T/ptr" >"$T/ptr.run" 2>&1
grep -q 'data pointer names the header' "$T/ptr.run" \
    && ok "ptr: the fixture's data pointer names its header" || bad "ptr: fixture" "$(cat "$T/ptr.run")"
grow ptr "$T/ptr" "$T/ptr.grown"
[ "$grc" -eq 0 ] && [ -e "$T/ptr.grown" ] && ok "ptr: the grow succeeds and writes its output" \
    || bad "ptr: grow" "exit $grc: $(cat "$T/ptr.grow.err")"
lowered ptr "$T/ptr" "$T/ptr.grown"
grep -q "^$T/ptr: grew the header pad by .*; repaired 1 reference to the header\$" "$T/ptr.grow.err" \
    && ok "ptr: ... moving its one pointer to the header, and saying so" \
    || bad "ptr: repaired" "$(cat "$T/ptr.grow.err")"
same ptr "$T/ptr" "$T/ptr.grown"
grep -q 'data pointer names the header' "$T/ptr.out.out" \
    && ok "ptr: ... and the grown binary's data pointer names its header" \
    || bad "ptr: grown output" "$(cat "$T/ptr.out.out")"

grow inside "$T/inside" "$T/inside.grown"
[ "$grc" -eq 1 ] && [ ! -e "$T/inside.grown" ] \
    && ok "inside: a pointer into the header refuses the grow, and nothing is written" \
    || bad "inside: grow" "exit $grc: $(cat "$T/inside.grow.err")"
grep -q 'between the header at .* and its first content at .*, which a grow moves apart; refusing to grow$' \
    "$T/inside.grow.err" \
    && ok "inside: ... saying why" || bad "inside: why" "$(cat "$T/inside.grow.err")"

DYLDINFO=/Library/Developer/CommandLineTools/usr/bin/dyldinfo
if [ -x "$DYLDINFO" ]; then
    "$DYLDINFO" -bind "$T/self" | grep -q 'this-image *__mh_execute_header$' \
        && ok "self: the fixture binds its own __mh_execute_header" \
        || bad "self: fixture" "$("$DYLDINFO" -bind "$T/self")"
else
    skip "self: the fixture's bind" "no $DYLDINFO to read it with"
fi
grow self "$T/self" "$T/self.grown"
[ "$grc" -eq 0 ] && [ -e "$T/self.grown" ] && ok "self: the grow succeeds and writes its output" \
    || bad "self: grow" "exit $grc: $(cat "$T/self.grow.err")"
lowered self "$T/self" "$T/self.grown"
same self "$T/self" "$T/self.grown"
grep -q 'data pointer names the header' "$T/self.out.out" \
    && ok "self: ... and the grown binary's bound pointer names its header" \
    || bad "self: grown output" "$(cat "$T/self.out.out")"
```

- [ ] **Step 3: Run them to see them fail**

Run: build (rebuild check).
Expected: `grow_test` does not link: `Undefined symbols for architecture x86_64: "_mg_header_pointers"`, after `warning: implicit declaration of function 'mg_header_pointers'`. `drydock-macho-rewrite` still builds.

Run: `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`
Expected: exit 1, `grown_binary_runs_test: 6 failure(s)`:

```
FAIL ptr: repaired: …
FAIL ptr: stdout: input 'data pointer names the header', grown 'data pointer MISSES the header'
FAIL ptr: exit status: input 0, grown 1
FAIL ptr: grown output: data pointer MISSES the header
FAIL inside: grow: exit 0: …
FAIL inside: why: …
```

(`self` passes already. It pins what this task must keep.)

- [ ] **Step 4: Declare `mg_header_pointers`, and say what now moves**

In `src/grow.h`, after Task 1's `void mg_rebases_free(mg_rebases *r);`, insert (after a blank line):

```c
/* The pointers that name the header: each rebase target whose value is
 * `base`. Each loses `grow` (0 to count them), following the header down.
 * One whose value lies strictly inside (base, base + first), in the header
 * and its load commands, is refused: a grow moves those apart, so no value
 * names that byte both before and after. Returns how many name the header,
 * or -1 with `why` set (mg_rebases_read's reasons, or that one). */
int64_t mg_header_pointers(uint8_t *buf, size_t fsize, uint64_t base, uint64_t first,
                           uint32_t grow, char *why, size_t whysz);
```

In the top comment, replace (`:29`):

```c
 * RIP-relatively (src/hdrref.h), and the value of a symbol that names it.
```

with:

```c
 * RIP-relatively (src/hdrref.h), the value of a symbol that names it, and a
 * rebased pointer to it.
```

In `mg_ensure_pad`'s contract, replace (`:114-115`):

```c
 * the header" (or "1 reference") when the grow repaired code that addresses
 * the image's own header (src/hdrref.h).
```

with:

```c
 * the header" (or "1 reference") when the grow repaired code that addresses
 * the image's own header (src/hdrref.h) or moved pointers to it
 * (mg_header_pointers), counting both.
```

In `mg_grow_header`'s contract, replace Task 1's:

```c
 * for; one whose LC_SYMTAB symbol table does not fit in the image; and one
 * whose rebase targets mg_rebases_read cannot read. Every confirmed
 * reference is repaired: its disp32 loses the grow, so it still reaches the
 * header. So does the value of each symbol that names the header
 * (__mh_execute_header). A failure partway through growing can leave the
 * buffer modified (see mg_ensure_pad).
```

with:

```c
 * for; one whose LC_SYMTAB symbol table does not fit in the image; and one
 * whose rebase targets mg_rebases_read cannot read, or one of which
 * mg_header_pointers refuses. Every confirmed reference is repaired: its
 * disp32 loses the grow, so it still reaches the header. So does the value
 * of each symbol that names the header (__mh_execute_header), and of each
 * rebased pointer that does. A failure partway through growing can leave the
 * buffer modified (see mg_ensure_pad).
```

- [ ] **Step 5: Write `mg_header_pointers`, and call it**

In `src/grow.c`, immediately after Task 1's `mg_rebases_free` definition (ending `    r->v = NULL;` and `}`), insert (after a blank line):

```c
int64_t mg_header_pointers(uint8_t *buf, size_t fsize, uint64_t base, uint64_t first,
                           uint32_t grow, char *why, size_t whysz) {
    mg_rebases rb;
    int64_t n = 0;
    if (mg_rebases_read(buf, fsize, &rb, why, whysz) != 0) return -1;
    for (size_t i = 0; i < rb.s.n; i++) {
        uint64_t v = rb.v[i].value;
        if (v > base && v - base < first) {
            snprintf(why, whysz, "the pointer at %#llx names %#llx, between the header at %#llx "
                     "and its first content at %#llx, which a grow moves apart",
                     (unsigned long long)rb.v[i].vm, (unsigned long long)v,
                     (unsigned long long)base, (unsigned long long)(base + first));
            mg_rebases_free(&rb);
            return -1;
        }
        if (v != base) continue;
        n++;
        v -= grow;
        memcpy(buf + rb.v[i].at, &v, sizeof v);
    }
    mg_rebases_free(&rb);
    return n;
}

```

In `mg_ensure_pad`, replace (`:82`):

```c
    int64_t refs = mhr_scan(*pbuf, *pfsize, base_before, NULL, NULL);
```

with:

```c
    int64_t refs = mhr_scan(*pbuf, *pfsize, base_before, NULL, NULL);
    char why[256];
    int64_t ptrs = mg_header_pointers(*pbuf, *pfsize, base_before, first, 0, why, sizeof why);
```

and replace (`:106-108`):

```c
    if (refs > 0)
        fprintf(stderr, "; repaired %lld reference%s to the header", (long long)refs,
                refs == 1 ? "" : "s");
```

with:

```c
    int64_t repaired = (refs > 0 ? refs : 0) + (ptrs > 0 ? ptrs : 0);
    if (repaired > 0)
        fprintf(stderr, "; repaired %lld reference%s to the header", (long long)repaired,
                repaired == 1 ? "" : "s");
```

In `mg_grow_header`, replace Task 1's audit block:

```c
    {
        mg_rebases rb;
        char why[256];
        if (mg_rebases_read(buf, fsize, &rb, why, sizeof why) != 0) {
            fprintf(stderr, "ERROR: %s; refusing to grow\n", why);
            return -1;
        }
        mg_rebases_free(&rb);
    }
```

with:

```c
    {
        char why[256];
        int64_t n = mg_header_pointers(buf, fsize, mg_base_of(buf, fsize), insert, 0, why,
                                       sizeof why);
        if (n < 0) {
            fprintf(stderr, "ERROR: %s; refusing to grow\n", why);
            return -1;
        }
    }
```

and after the block that moves the symbols (it begins `    if (mg_header_symbols(buf, final_size, snap.base, grow, 1) != 0) {` and ends `        return -1;` and `    }`), insert:

```c
    {
        char why[256];
        if (mg_header_pointers(buf, final_size, snap.base, insert, grow, why, sizeof why) < 0) {
            fprintf(stderr, "ERROR: internal error moving the pointers that name the header "
                            "after passing the pre-check: %s\n", why);
            mg_snapshot_free(&snap);
            return -1;
        }
    }
```

- [ ] **Step 6: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"` and `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`.
Expected: `macho_grow_test: all cases pass`. `grown_binary_runs_test: all passed`, including `PASS ptr: ... moving its one pointer to the header, and saying so`, `PASS inside: ... saying why`, and (on this host) `PASS self: the fixture binds its own __mh_execute_header`. Then the whole suite: all pass.

- [ ] **Step 7: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`, and `tests/grown_binary_runs_test.sh` where named)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `        if (v > base && v - base < first) {` | `        if (v > base && v - base <= first) {` | `test_grow_moves_the_pointers_that_name_the_header` ("pointers: the grow succeeds") |
| 2 | the same line | `        if (v > base + 1 && v - base < first) {` | `test_grow_refuses_a_pointer_inside_the_header` ("inside: 0x100000001 is refused") |
| 3 | the same line | `        if (v >= base && v - base < first) {` | `test_grow_moves_the_pointers_that_name_the_header` ("pointers: the grow succeeds") |
| 4 | `        if (v != base) continue;` | `        if (v < base) continue;` | `test_grow_moves_the_pointers_that_name_the_header` ("pointers: pointer 1 holds") |
| 5 | `        v -= grow;` | `        v -= MG_PAGE;` | the same test ("pointers, two-page grow: pointer 0 holds") |
| 6 | the same line | `        v += grow;` | the same test ("pointers: pointer 0 holds") |
| 7 | `        n++;` (in `mg_header_pointers`) | (delete it) | `test_ensure_pad_announces_the_pointers_it_moves` ("one pointer: announced") |
| 8 | `        if (n < 0) {` (the audit in `mg_grow_header`) | `        if (0) {` | `test_grow_refuses_a_pointer_inside_the_header`; and `tests/grown_binary_runs_test.sh` (`FAIL inside: why`) |
| 9 | `        if (mg_header_pointers(buf, final_size, snap.base, insert, grow, why, sizeof why) < 0) {` | the same with `insert, 0, why` | `test_grow_moves_the_pointers_that_name_the_header` ("pointers: pointer 0 holds"); and `tests/grown_binary_runs_test.sh` (`FAIL ptr: grown output`) |
| 10 | the same line | the same with `mg_base_of(buf, final_size)` for `snap.base` | the same C test |
| 11 | `    int64_t repaired = (refs > 0 ? refs : 0) + (ptrs > 0 ? ptrs : 0);` | `    int64_t repaired = (refs > 0 ? refs : 0);` | `test_ensure_pad_announces_the_pointers_it_moves` ("one pointer: announced"); and `tests/grown_binary_runs_test.sh` (`FAIL ptr: repaired`) |
| 12 | the same line | `    int64_t repaired = (ptrs > 0 ? ptrs : 0);` | the same C test ("a pointer and an instruction: announced") |
| 13 | `                repaired == 1 ? "" : "s");` | `                refs == 1 ? "" : "s");` | the same C test ("one pointer: announced") |
| 14 | `    int64_t ptrs = mg_header_pointers(*pbuf, *pfsize, base_before, first, 0, why, sizeof why);` | the same with `0` for `base_before` | the same C test ("one pointer: announced") |

- [ ] **Step 8: Commit**

```bash
git add src/grow.h src/grow.c tests/grow_test.c tests/grown_binary_runs_test.sh
git commit -m "fix(grow): move the pointers that name the header with it

Lowering the image base moves the header down by the grow, and a rebased
pointer whose value was the base went on naming the old place: every Java
launcher stub on 10.9 keeps one in crt1's __program_vars, and a grown
/usr/bin/java died of SIGSEGV. Each such pointer now loses the grow, and
the announcement counts it among the references it repaired. A pointer
to a byte strictly between the header and its first content refuses the
grow: the grow moves those apart, so nothing it could hold names the same
byte afterward. A bind to the image's own __mh_execute_header needs
nothing, since dyld resolves it through the export trie; a test pins it.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 3: Verify the pointers

**Files:**
- Modify: `src/grow.h` (the `mg_snapshot` typedef and its comment at `:180-193`, now further down; `mg_verify`'s comment at `:222-226`, likewise)
- Modify: `src/grow.c` (`mg_snapshot_take`, `mg_snapshot_free`, before `int mg_verify(`, and in `mg_verify` after `    if (mg_verify_symbols(&im, fsize, before, base) != 0) return -1;`)
- Test: `tests/grow_test.c` (new tests before `int main(void) {`; calls after Task 2's `test_ensure_pad_announces_the_pointers_it_moves();`)

**Interfaces:**
- Consumes: Task 1's `mg_rebases_read`, `mg_rebases_free`, `mg_rebases`, `build_pointer_image`, `pt_type`, `PT_*`; `verify_thunk` and `verify_snap` (`tests/grow_test.c:2310`); `find_lc`, `seg_named`.
- Produces: `mg_snapshot` gains `mg_rebases rb;`, which `mg_snapshot_take` fills and `mg_snapshot_free` frees; `mg_verify` refuses a grown image whose rebase targets differ from the snapshot's.

**Plan decisions.** This is spec Decision 7's check 2 for the executable route, where the delta is 0. It is independent of the repair: it re-reads the grown image with `mg_rebases_read` and compares index by index against the snapshot, never calling `mg_header_pointers`. Every target must be at the same vm address and hold the same value, except that one which held the old base must hold the new base. A slot that moves but holds the same value is caught by its vm address (a test pins that). The count catches a slot dropped or added. Type needs no comparison, since the reader refuses every type but one.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately before `int main(void) {`, insert:

```c
/* Verification's own check on the pointers: a snapshot of the fixture, a
 * grow, then `undo` breaks what the grow made, and verify must say `needle`.
 * `setup`, if any, changes the fixture before the snapshot. */
typedef void (*pt_tweak)(uint8_t *buf, size_t fsize);
static uint8_t *pt_ops_now(uint8_t *buf, size_t fsize) {
    return buf + ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->rebase_off;
}
static uint64_t *pt_slots_now(uint8_t *buf, size_t fsize) {
    return (uint64_t *)(buf + seg_named(buf, fsize, "__DATA")->fileoff);
}
static void pt_unmove(uint8_t *buf, size_t fsize) { pt_slots_now(buf, fsize)[0] += 0x1000; }
static void pt_move_again(uint8_t *buf, size_t fsize) { pt_slots_now(buf, fsize)[0] -= 0x1000; }
static void pt_move_content(uint8_t *buf, size_t fsize) { pt_slots_now(buf, fsize)[1] -= 0x1000; }
static void pt_drop_one(uint8_t *buf, size_t fsize) { pt_ops_now(buf, fsize)[3] = 0x53; }
static void pt_retype(uint8_t *buf, size_t fsize) { pt_ops_now(buf, fsize)[0] = 0x12; }
static void pt_all_alike(uint8_t *buf, size_t fsize) {
    for (int i = 0; i < PT_N + 1; i++) pt_slots_now(buf, fsize)[i] = PT_DATAVM + 0x40;
}
static void pt_shift_one(uint8_t *buf, size_t fsize) { pt_ops_now(buf, fsize)[2] = 0x08; }

static void check_verify_rejects_pointer(const char *what, pt_tweak setup, pt_tweak undo,
                                         const char *needle) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    if (setup) setup(buf, fsize);
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) {
        CHECK(0, "%s: snapshot", what); free(buf); return;
    }
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "%s: grow", what); mg_snapshot_free(&snap); free(buf); return;
    }
    CHECK(mg_verify(buf, fsize, &snap) == 0, "%s: verify accepts the grow as made", what);
    undo(buf, fsize);
    int r;
    verify_snap = &snap;
    int said = stderr_contains_during(verify_thunk, &buf, &fsize, 0, needle, &r);
    CHECK(r == -1 && said, "verify REJECTS %s, saying '%s' (got %d)", what, needle, r);
    mg_snapshot_free(&snap);
    free(buf);
}

static void test_verify_watches_the_pointers(void) {
    check_verify_rejects_pointer("a pointer left naming where the header was", NULL, pt_unmove,
        "ERROR: verify FAILED -- the pointer at 0x100002000 holds 0x100000000 after the grow, and "
        "must hold 0xfffff000; refusing.");
    check_verify_rejects_pointer("a pointer to the header moved twice", NULL, pt_move_again,
        "the pointer at 0x100002000 holds 0xffffe000 after the grow, and must hold 0xfffff000");
    check_verify_rejects_pointer("a pointer to content moved with the header", NULL,
        pt_move_content,
        "the pointer at 0x100002008 holds 0x100001040 after the grow, and must hold 0x100002040");
    check_verify_rejects_pointer("a rebase dropped", NULL, pt_drop_one,
        "ERROR: verify FAILED -- the grown image rebases 3 pointers, 4 before the grow; refusing.");
    check_verify_rejects_pointer("a rebase moved to a slot holding the same value", pt_all_alike,
        pt_shift_one,
        "ERROR: verify FAILED -- rebase 0 is at 0x100002008 after the grow, and was at 0x100002000 "
        "before; refusing.");
    check_verify_rejects_pointer("rebases it cannot read", NULL, pt_retype,
        "ERROR: verify FAILED -- the grown image's rebases cannot be read (the rebase at __DATA+0 "
        "is of type 2, not a pointer); refusing.");
}

static void test_snapshot_refuses_rebases_it_cannot_read(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    pt_type(buf);
    mg_snapshot snap;
    CHECK(mg_snapshot_take(buf, fsize, &snap) == -1, "snapshot: rebases it cannot read");
    free(buf);
}
```

After Task 2's `    test_ensure_pad_announces_the_pointers_it_moves();`, insert:

```c
    test_verify_watches_the_pointers();
    test_snapshot_refuses_rebases_it_cannot_read();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: exit 1, `macho_grow_test: 7 FAILURE(S)`: the six `FAIL: verify REJECTS …` lines of `test_verify_watches_the_pointers` (each `(got 0)`) and `FAIL: snapshot: rebases it cannot read`.

- [ ] **Step 3: The snapshot keeps the targets**

In `src/grow.h`, replace the snapshot typedef and its comment:

```c
/* What mg_verify compares a grown image against: the resolved addresses
 * mg_collect finds, the image base with every reference to it the
 * header-reference scan (src/hdrref.h) finds, and each symbol's type and
 * value. */
typedef struct {
    uint64_t *addr;
    uint32_t n;
    uint64_t base;
    mhr_cand *refs;
    uint32_t nrefs;
    uint64_t *symval;
    uint8_t *symtype;
    uint32_t nsyms;
} mg_snapshot;
```

with:

```c
/* What mg_verify compares a grown image against: the resolved addresses
 * mg_collect finds, the image base with every reference to it the
 * header-reference scan (src/hdrref.h) finds, each symbol's type and value,
 * and every rebase target with its value. */
typedef struct {
    uint64_t *addr;
    uint32_t n;
    uint64_t base;
    mhr_cand *refs;
    uint32_t nrefs;
    uint64_t *symval;
    uint8_t *symtype;
    uint32_t nsyms;
    mg_rebases rb;
} mg_snapshot;
```

and `mg_verify`'s comment:

```c
/* 0 if every base-relative structure and every mg_each_fileoff offset
 * resolves exactly where it did before the grow, no two segments overlap in
 * memory, no code addresses the base as it was, and every reference to the
 * header the snapshot recorded addresses the base as it is; -1 (with a message
 * naming the first failure) otherwise. */
```

with:

```c
/* 0 if every base-relative structure and every mg_each_fileoff offset
 * resolves exactly where it did before the grow, no two segments overlap in
 * memory, no code addresses the base as it was, every reference to the
 * header the snapshot recorded addresses the base as it is, and the rebase
 * targets are the same slots, each holding what it held unless that named the
 * header, which now names the base as it is; -1 (with a message naming the
 * first failure) otherwise. */
```

In `src/grow.c`'s `mg_snapshot_take`, replace:

```c
int mg_snapshot_take(const uint8_t *buf, size_t fsize, mg_snapshot *s) {
    mi_image im;
    const struct nlist_64 *nl;
```

with:

```c
int mg_snapshot_take(const uint8_t *buf, size_t fsize, mg_snapshot *s) {
    mi_image im;
    const struct nlist_64 *nl;
    char why[256];
```

then replace:

```c
    s->nsyms = 0;
    s->addr = (uint64_t *)malloc(MG_SNAP_MAX * sizeof(uint64_t));
```

with:

```c
    s->nsyms = 0;
    memset(&s->rb, 0, sizeof s->rb);
    s->addr = (uint64_t *)malloc(MG_SNAP_MAX * sizeof(uint64_t));
```

and replace:

```c
        !(s->symtype = (uint8_t *)malloc(s->nsyms + 1))) {
```

with:

```c
        !(s->symtype = (uint8_t *)malloc(s->nsyms + 1)) ||
        mg_rebases_read(buf, fsize, &s->rb, why, sizeof why) != 0) {
```

In `mg_snapshot_free`, replace:

```c
    free(s->symtype); s->symtype = NULL; s->nsyms = 0;
}
```

with:

```c
    free(s->symtype); s->symtype = NULL; s->nsyms = 0;
    mg_rebases_free(&s->rb);
}
```

- [ ] **Step 4: `mg_verify` compares them**

Immediately before `int mg_verify(const uint8_t *buf, size_t fsize, const mg_snapshot *before) {`, insert:

```c
/* The rebase targets are the same slots, in the same order, and each holds
 * what it held, unless that named the header: that one names it where it is
 * now. */
static int mg_verify_pointers(const uint8_t *buf, size_t fsize, const mg_snapshot *before,
                              uint64_t base) {
    mg_rebases now;
    char why[256];
    int rc = 0;
    if (mg_rebases_read(buf, fsize, &now, why, sizeof why) != 0) {
        fprintf(stderr, "ERROR: verify FAILED -- the grown image's rebases cannot be read (%s); "
                        "refusing.\n", why);
        return -1;
    }
    if (now.s.n != before->rb.s.n) {
        fprintf(stderr, "ERROR: verify FAILED -- the grown image rebases %zu pointers, %zu before "
                        "the grow; refusing.\n", now.s.n, before->rb.s.n);
        rc = -1;
    }
    for (size_t i = 0; rc == 0 && i < now.s.n; i++) {
        const mg_rbval *was = &before->rb.v[i], *is = &now.v[i];
        uint64_t want = was->value == before->base ? base : was->value;
        if (is->vm != was->vm) {
            fprintf(stderr, "ERROR: verify FAILED -- rebase %zu is at %#llx after the grow, and "
                            "was at %#llx before; refusing.\n", i, (unsigned long long)is->vm,
                    (unsigned long long)was->vm);
            rc = -1;
        } else if (is->value != want) {
            fprintf(stderr, "ERROR: verify FAILED -- the pointer at %#llx holds %#llx after the "
                            "grow, and must hold %#llx; refusing.\n", (unsigned long long)is->vm,
                    (unsigned long long)is->value, (unsigned long long)want);
            rc = -1;
        }
    }
    mg_rebases_free(&now);
    return rc;
}

```

In `mg_verify`, replace:

```c
    if (mg_verify_symbols(&im, fsize, before, base) != 0) return -1;
    return mg_verify_refs(buf, fsize, before, base);
```

with:

```c
    if (mg_verify_symbols(&im, fsize, before, base) != 0) return -1;
    if (mg_verify_pointers(buf, fsize, before, base) != 0) return -1;
    return mg_verify_refs(buf, fsize, before, base);
```

- [ ] **Step 5: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"` and `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`.
Expected: `macho_grow_test: all cases pass`; `grown_binary_runs_test: all passed`. Then the whole suite: all pass.

- [ ] **Step 6: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (mg_verify_pointers(buf, fsize, before, base) != 0) return -1;` | (delete it) | `test_verify_watches_the_pointers` ("verify REJECTS a pointer left naming where the header was") |
| 2 | `        uint64_t want = was->value == before->base ? base : was->value;` | `        uint64_t want = was->value;` | `test_grow_moves_the_pointers_that_name_the_header` ("pointers: the grow succeeds": verification now refuses the correct grow) |
| 3 | `    if (now.s.n != before->rb.s.n) {` | `    if (0) {` | `test_verify_watches_the_pointers` ("verify REJECTS a rebase dropped") |
| 4 | `        if (is->vm != was->vm) {` | `        if (0) {` | the same test ("verify REJECTS a rebase moved to a slot holding the same value") |
| 5 | `        } else if (is->value != want) {` | `        } else if (0) {` | the same test ("verify REJECTS a pointer left naming where the header was") |
| 6 | `        mg_rebases_read(buf, fsize, &s->rb, why, sizeof why) != 0) {` | `        0) {` | `test_snapshot_refuses_rebases_it_cannot_read`; and `test_grow_moves_the_pointers_that_name_the_header` ("pointers: the grow succeeds") |
| 7 | `    if (mg_rebases_read(buf, fsize, &now, why, sizeof why) != 0) {` | `    if ((mg_rebases_read(buf, fsize, &now, why, sizeof why), 0)) {` | `test_verify_watches_the_pointers` ("verify REJECTS rebases it cannot read") |
| 8 | `        if (mg_header_pointers(buf, final_size, snap.base, insert, grow, why, sizeof why) < 0) {` | the same with `insert, 0, why` | `test_grow_moves_the_pointers_that_name_the_header` ("pointers: the grow succeeds": verification catches the repair that did not happen) |

- [ ] **Step 7: Commit**

```bash
git add src/grow.h src/grow.c tests/grow_test.c
git commit -m "fix(grow): verify the pointers a grow moved, and the ones it did not

The snapshot now keeps every rebase target and its value, and mg_verify
re-reads the grown image and compares them slot by slot: the same slots
at the same addresses, each holding what it held, except that one which
held the old base must hold the new one. It does not share the code that
moved them, so it catches a pointer left behind, moved twice or moved
when it named content, and a rebase dropped or shifted.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 4: Refuse an executable whose pointers are in local relocations

*(Question 2. If the owner declines it, skip this task. Nothing else depends on it.)*

**Files:**
- Modify: `src/grow.c` (Task 1's `struct mg_rb_lcs`, `mg_rb_lcs_cb`, and `mg_rebases_read`)
- Modify: `src/grow.h` (Task 1's comment on `mg_rebases_read`)
- Test: `tests/grow_test.c` (Task 1's `PT_CODE` define and `build_pointer_image`; new tests before `int main(void) {`; calls after Task 3's `test_snapshot_refuses_rebases_it_cannot_read();`)

**Interfaces:**
- Consumes: Task 1's reader and fixture.
- Produces: `mg_rebases_read` also refuses an image with no `LC_DYLD_INFO[_ONLY]` whose `LC_DYSYMTAB` lists local relocation entries. `build_pointer_image` gains `PT_LOCREL` and `PT_NOINFO`.

**Plan decisions.** Without rebase opcodes, dyld slides an executable's pointers from `LC_DYSYMTAB`'s local relocation entries (`ImageLoaderMachOClassic`). The grow does not read those, so it cannot find a pointer that names the header among them. Three executables here are such images, and each has such a pointer. With rebase opcodes present, dyld reads only the opcodes (`ImageLoaderMachOCompressed`), and so does the reader: `thnucups` has both. External relocations bind through the symbol table, whose `__mh_execute_header` M1 already moves, so they need nothing.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, replace Task 1's:

```c
#define PT_CODE   1
```

with:

```c
#define PT_CODE   1
#define PT_LOCREL 2   /* an LC_DYSYMTAB listing one local relocation entry */
#define PT_NOINFO 4   /* no LC_DYLD_INFO_ONLY: dyld reads LC_DYSYMTAB's entries instead */
```

In `build_pointer_image`, replace:

```c
    struct dyld_info_command *di = (struct dyld_info_command *)lc;
    di->cmd = LC_DYLD_INFO_ONLY;
    di->cmdsize = sizeof *di;
    di->rebase_off = PT_OPS;
    di->rebase_size = 8;
    lc += di->cmdsize;
    h->ncmds = 5;
```

with:

```c
    h->ncmds = 4;
    if (!(opts & PT_NOINFO)) {
        struct dyld_info_command *di = (struct dyld_info_command *)lc;
        di->cmd = LC_DYLD_INFO_ONLY;
        di->cmdsize = sizeof *di;
        di->rebase_off = PT_OPS;
        di->rebase_size = 8;
        lc += di->cmdsize;
        h->ncmds++;
    }
    if (opts & PT_LOCREL) {
        struct dysymtab_command *ds = (struct dysymtab_command *)lc;
        ds->cmd = LC_DYSYMTAB;
        ds->cmdsize = sizeof *ds;
        ds->locreloff = PT_LE + 128;   /* X86_64_RELOC_UNSIGNED, 8 bytes, at __DATA+0, section 2 */
        ds->nlocrel = 1;
        lc += ds->cmdsize;
        h->ncmds++;
        static const uint8_t reloc[8] = { 0, 0, 0, 0, 0x02, 0, 0, 0x06 };
        memcpy(buf + PT_LE + 128, reloc, sizeof reloc);
    }
```

Immediately before `int main(void) {`, insert:

```c
/* An image with no rebase opcodes lists its pointers, if any, in LC_DYSYMTAB's
 * local relocation entries, and dyld then slides the pointers they name. A
 * grow does not read those, so it cannot move one that names the header:
 * refused. With rebase opcodes, dyld reads only those, and so does the grow. */
static void test_rebases_read_refuses_local_relocations(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, PT_NOINFO | PT_LOCREL);
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == -1 && strcmp(why, "the image lists its pointers in LC_DYSYMTAB's local "
                                 "relocation entries (1), not in rebase opcodes, and a grow does "
                                 "not read those") == 0,
          "local relocations: refused (got %d, '%s')", r, why);
    mg_rebases_free(&rb);
    free(buf);

    buf = build_pointer_image(&fsize, PT_LOCREL);
    r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == PT_N, "local relocations beside rebase opcodes: the opcodes are "
          "read (got %d, %zu: %s)", r, rb.s.n, why);
    mg_rebases_free(&rb);
    free(buf);

    buf = build_pointer_image(&fsize, PT_NOINFO);
    r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == 0, "neither: nothing to read (got %d, %zu: %s)", r, rb.s.n, why);
    mg_rebases_free(&rb);
    free(buf);
}

static void test_grow_refuses_local_relocations(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, PT_NOINFO | PT_LOCREL);
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
        "ERROR: the image lists its pointers in LC_DYSYMTAB's local relocation entries (1), not "
        "in rebase opcodes, and a grow does not read those; refusing to grow", &r);
    CHECK(r == -1 && said, "local relocations: the grow refuses, saying why (got %d)", r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "local relocations: nothing changed");
    free(before);
    free(buf);
    buf = build_pointer_image(&fsize, PT_LOCREL);
    r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "local relocations beside rebase opcodes: the grow succeeds (got %d)", r);
    free(buf);
}
```

After Task 3's `    test_snapshot_refuses_rebases_it_cannot_read();`, insert:

```c
    test_rebases_read_refuses_local_relocations();
    test_grow_refuses_local_relocations();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: exit 1, `macho_grow_test: 3 FAILURE(S)`:

```
FAIL: local relocations: refused (got 0, '')
FAIL: local relocations: the grow refuses, saying why (got 0)
FAIL: local relocations: nothing changed
```

- [ ] **Step 3: Implement**

In `src/grow.c`, replace Task 1's:

```c
    const struct dyld_info_command *di;
};
```

with:

```c
    const struct dyld_info_command *di;
    uint32_t nlocrel;
};
```

In `mg_rb_lcs_cb`, replace:

```c
        if (!c->di) c->di = (const struct dyld_info_command *)lc;
    }
    return 0;
```

with:

```c
        if (!c->di) c->di = (const struct dyld_info_command *)lc;
    }
    if (lc->cmd == LC_DYSYMTAB) c->nlocrel += ((const struct dysymtab_command *)lc)->nlocrel;
    return 0;
```

In `mg_rebases_read`, replace:

```c
    if (!c.di || !c.di->rebase_size) return 0;
```

with:

```c
    if (!c.di && c.nlocrel)
        return mg_rb_fail(r, why, whysz, "the image lists its pointers in LC_DYSYMTAB's local "
                          "relocation entries (%u), not in rebase opcodes, and a grow does not "
                          "read those", c.nlocrel);
    if (!c.di || !c.di->rebase_size) return 0;
```

In `src/grow.h`, replace Task 1's comment on `mg_rebases_read`:

```c
/* Reads every rebase target into *r: none when the image has no
 * LC_DYLD_INFO[_ONLY] or its rebase opcodes are empty. Returns 0; or -1, with
 * *r empty and `why` saying what, when the image has more than one
 * LC_DYLD_INFO[_ONLY], when its rebase opcodes lie past the end of the image
 * or do not decode, or when a target is not a plain pointer
 * (REBASE_TYPE_POINTER), lies in the segment that maps the header, does not
 * lie wholly within its segment's file data, or is named more than once.
 * Free *r with mg_rebases_free, which is safe on an empty one. */
```

with:

```c
/* Reads every rebase target into *r: none when the image has no
 * LC_DYLD_INFO[_ONLY] or its rebase opcodes are empty. Returns 0; or -1, with
 * *r empty and `why` saying what, when the image has more than one
 * LC_DYLD_INFO[_ONLY]; when it has none and LC_DYSYMTAB lists local
 * relocation entries, which dyld then reads in their place; when its rebase
 * opcodes lie past the end of the image or do not decode; or when a target
 * is not a plain pointer (REBASE_TYPE_POINTER), lies in the segment that maps
 * the header, does not lie wholly within its segment's file data, or is named
 * more than once. Free *r with mg_rebases_free, which is safe on an empty
 * one. */
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: `macho_grow_test: all cases pass`. Then the whole suite: all pass.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (!c.di && c.nlocrel)` | `    if (c.nlocrel)` | `test_rebases_read_refuses_local_relocations` ("local relocations beside rebase opcodes: the opcodes are read") |
| 2 | the same line | `    if (!c.di)` | the same test ("neither: nothing to read") |
| 3 | `    if (lc->cmd == LC_DYSYMTAB) c->nlocrel += ((const struct dysymtab_command *)lc)->nlocrel;` | (delete it) | the same test ("local relocations: refused"); and `test_grow_refuses_local_relocations` |
| 4 | the same line | the same with `->nextrel` for `->nlocrel` | `test_rebases_read_refuses_local_relocations` ("local relocations: refused") |

- [ ] **Step 6: Commit**

```bash
git add src/grow.h src/grow.c tests/grow_test.c
git commit -m "fix(grow): refuse an executable whose pointers are local relocations

With no rebase opcodes, dyld slides an executable's pointers from
LC_DYSYMTAB's local relocation entries, which a grow does not read, so it
cannot move one that names the header. dnsextd, mDNSResponder and
mDNSResponderHelper each have such a pointer, in crt1's __dyld section;
they grew before with it left a page past the header, and now refuse.
Beside rebase opcodes, the entries are ignored, as dyld ignores them.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 5: The corpus, a Java stub, QUEUE item 29 and the spec

**Files:**
- Modify: `compat/README.md:151-158` (the "A header pad too short … is grown" bullet's sentences on header references)
- Modify: `docs/superpowers/QUEUE.md:35` (item 29's row), `:1473-1488` (item 29's "Not repaired" and "I1" paragraphs)
- Modify: `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md:111-117` (Decision 1, "The executable route"), `:353-356` (Decision 7, check 2), `:397-399` (Decision 9), `:438-443` (M2's first bullet)

**Interfaces:**
- Consumes: Tasks 1–4's commits, and a build of their finished tree in `$B`.
- Produces: nothing code depends on.

**Plan decisions.** The sweep compares a build of the commit before Task 1 with `$B`, over the same 1,128 files the M1 sweeps used, rebuilt from the filesystem so the step does not depend on another session's scratch directory. The Java stub is the end-to-end proof, since `/usr/bin/java` is a symlink and so outside the 1,128. The spec is edited in place, where it says data pointers are not handled; it is deleted once M3 lands, like every spec.

- [ ] **Step 1: Find the commits**

Run:

```sh
P=$(git log -1 --format=%h --grep='^feat(grow): read every rebase target' )^
C=$(git log -1 --format=%h --grep='^fix(grow): move the pointers that name the header')
L=$(git log -1 --format=%h)
echo "before=$(git rev-parse --short "$P") move=$C last=$L"
```

Expected: three short hashes. `$C` replaces `$C` in the docs below.

- [ ] **Step 2: The corpus sweep**

Build the commit before Task 1 in a scratch directory, and grow every file of the corpus with each build. Each grow uses `rpath append`s long enough to outgrow the pad, after deleting any code signature. Record the exit status, the output's hash and stderr:

```sh
W=$(mktemp -d -t datapointers-sweep)
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
paste "$W/before/results.tsv" "$W/after/results.tsv" | awk -F'\t' '$2 != $6 || $3 != $7 { print $1 "\t" $2 " -> " $6 "\t" $8 }' | cut -c1-240
```

Expected, as measured writing this plan (fat files are thinned to x86_64 first):

- `1128`, then `before: 1046 0   82 1` and `after: 1043 0   85 1` (`uniq -c` of the exit statuses: 1,046 grew and 82 were refused, then 1,043 and 85);
- exactly six files differ:

  | file | exit | why |
  |---|---|---|
  | `/usr/bin/restoreui` | 0 -> 0 | its `__program_vars` pointer now names the header; the line ends `; repaired 1 reference to the header`; 4 bytes of the output differ |
  | `/usr/libexec/MRT` | 0 -> 0 | the same |
  | `/usr/libexec/cups/filter/cgpdftoraster` | 0 -> 0 | the same |
  | `/usr/sbin/dnsextd` | 0 -> 1 | Task 4: `ERROR: the image lists its pointers in LC_DYSYMTAB's local relocation entries (114), …` |
  | `/usr/sbin/mDNSResponder` | 0 -> 1 | Task 4 (547 entries) |
  | `/usr/sbin/mDNSResponderHelper` | 0 -> 1 | Task 4 (190 entries) |

  (Without Task 4, only the first three differ, and `after` is `1046 0   82 1`.)
- **The header-reference executables still repair.** The 43 with code that addresses the header are the 42 whose `before` line has `repaired`, plus `thnucups`, which is refused in both for having no `LC_FUNCTION_STARTS`. Of the 42, 39 still grow and repair, and the three Task 4 refuses are the rest (all 42 without Task 4). Check:

  ```sh
  grep -c 'repaired' "$W/before/results.tsv" "$W/after/results.tsv"
  # before: 42 (their code); after: 42 = 39 of them + restoreui, MRT, cgpdftoraster
  ```

Nothing else changes: every other output is byte-identical. Keep `$W` for Step 3.

- [ ] **Step 3: A Java launcher stub, before and after**

`/usr/bin/java` is a symlink, so the sweep skipped it. Grow it with each build exactly as the sweep grows a file (its code signature deleted, then enough `rpath append`s to outgrow the pad), and run both:

```sh
"/usr/bin/java" -version 2>&1 | head -1          # the control
printf '/usr/bin/java\n' > "$W/java.list"
for s in before after; do
  d=$([ $s = before ] && echo "$W/build" || echo "$B")
  sh "$W/sweep.sh" "$d/drydock-macho-rewrite" "$W/java.$s.d" "$W/java.list"
  cp "$W/java.$s.d/out" "$W/java.$s"
  echo "$s: grow: exit $(cut -f2,4 "$W/java.$s.d/results.tsv")"
  rc=0; "$W/java.$s" -version > "$W/java.$s.run" 2>&1 || rc=$?
  echo "$s: runs, exit $rc: $(head -1 "$W/java.$s.run")"
done
"$B/drydock-macho-rewrite" verify "$W/java.after"
```

Expected:

```
java version "1.6.0_65"
before: grow: exit 0	IN: grew the header pad by 4096 bytes (64 -> 4160 available); image base 0x100000000 -> 0xfffff000|IN: verified|OUT: written (30,048 bytes)|
… Segmentation fault: 11  "$W/java.$s" -version > "$W/java.$s.run" 2>&1
before: runs, exit 139: 
after: grow: exit 0	IN: grew the header pad by 4096 bytes (64 -> 4160 available); image base 0x100000000 -> 0xfffff000; repaired 1 reference to the header|IN: verified|OUT: written (30,048 bytes)|
after: runs, exit 0: java version "1.6.0_65"
$W/java.after: OK
```

The `before` grow's line says nothing about the pointer, and its binary dies of SIGSEGV; the `after` grow's line counts the pointer, and its binary runs as `/usr/bin/java` does. (The JDK 6 runtime is installed on this host, and the stub finds it through `JavaVM.framework`.) Then `rm -rf "$W"`.

- [ ] **Step 4: `compat/README.md`**

Replace (`:151-158`):

```markdown
    ..."), and exits 0; anything else is still refused. When the
    executable's code takes its own header's address RIP-relatively, which
    lowering the base would break, the grow repairs each such instruction
    and ends the line "; repaired N references to the header"
    (`tests/grown_binary_runs_test.sh`, "hdr"). The scan that finds these can,
    rarely, report bytes that only look like such an instruction; the grow
    confirms each by decoding its function, and refuses rather than patch
    bytes it cannot confirm. The repo owner's
```

with:

```markdown
    ..."), and exits 0; anything else is still refused. When the
    executable takes its own header's address, in code RIP-relatively or
    in a data pointer (every Java launcher stub on 10.9 has one), which
    lowering the base would break, the grow repairs each such instruction
    or pointer and ends the line "; repaired N references to the header"
    (`tests/grown_binary_runs_test.sh`, "hdr" and "ptr"). The scan that
    finds the instructions can, rarely, report bytes that only look like
    one; the grow confirms each by decoding its function, and refuses
    rather than patch bytes it cannot confirm. The repo owner's
```

- [ ] **Step 5: `docs/superpowers/QUEUE.md`**

In item 29's row (`:35`), replace:

```markdown
| **done**: repaired since `5d93921`; a data pointer to the header is not, see below |
```

with (`$C` from Step 1):

```markdown
| **done**: code repaired since `5d93921`, data pointers since `$C`; the code half of I1 is M2's, see below |
```

Replace item 29's "Not repaired" and "I1" paragraphs (`:1473-1488`, from `**Not repaired** (found while planning M1)` to `M2 implements the refusal once, for both routes, via a range scan.`) with:

```markdown
**Data pointers: done** since `$C`. A data pointer to the header,
`const void *p = &_mh_execute_header;`, is a rebase target whose value is
the base. On 10.9 they come from crt1: the `mh` field of
`__DATA,__program_vars`, or of the older `__DATA,__dyld`, which libSystem
hands to `_NSGetMachExecuteHeader`. 46 executables here have one: the 42
Java launcher stubs, `restoreui`, `MRT`, `cgpdftoraster` and `thnucups`.
Grown before, `/usr/bin/java -version` died of SIGSEGV; now it runs. A grow
reads every rebase target (`mg_rebases_read`, `src/grow.h`), moves each
that names the header down with it, counts them among the "references to
the header" it repaired, and verifies them slot by slot. It refuses what it
cannot vouch for: a rebase that is not a pointer, lies in the segment that
maps the header, in zero-fill or past the file, or is named twice (none
here); and, having no rebase opcodes to read, an executable whose
`LC_DYSYMTAB` lists local relocations. `dnsextd`, `mDNSResponder` and
`mDNSResponderHelper` are such, each with a `__dyld` pointer the grow used
to leave a page past the header, and now refuse. A bind to the image's own
`__mh_execute_header` (ld64's `-interposable`) needs nothing: dyld resolves
it through the export trie.

**I1**, the one rule's strictly-inside refusal: its **data half is done**
since `$C`. A rebase value strictly inside (base, base + F), such as
`(const char *)&_mh_execute_header + 16`, refuses the grow (none among
this host's executables). Its **code half is not**: a
`movl __mh_execute_header+16(%rip)` still grows silently wrong. Measured
2026-09-26, a scan for RIP-relative targets strictly inside (base, base + F)
finds 1,060 candidates in 120 of this host's 1,059 x86_64 executables, and
29 in Claude Code, and decoding confirms none as an instruction. The same
decoding confirms 151 of the 152 exact-base candidates. Refusing every
candidate it cannot confirm would stop 119 of those executables growing, and
Claude Code; refusing only confirmed ones changes nothing measured. Which is
the owner's call; it moves to dylib-growth M2, with the symbol half (a
symbol strictly inside: none here).
```

If either passage has changed since this plan was written, make the equivalent edit and say so in the commit message.

- [ ] **Step 6: the dylib-growth spec**

In `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`, Decision 1, replace (`:113-117`):

```markdown
  `__mh_execute_header` symbol, and any rebased data pointer to the header.
  Before M1 the executable route adjusted none of these. M1 moves the symbol;
  data pointers to the header need the complete rebase decoder and are QUEUE
  item 29's remaining half. 46 of 838 executables on this host have one; the
  Claude Code executable has none.
```

with:

```markdown
  `__mh_execute_header` symbol, and any rebased data pointer to the header.
  Before M1 the executable route adjusted none of these. M1 moves the symbol;
  QUEUE item 29's data-pointer work moves the pointers (`mg_header_pointers`,
  `src/grow.h`) and refuses one strictly inside (base, base + F). 46
  executables on this host have one, all from crt1's `__program_vars` or
  `__dyld`; the Claude Code executable has none.
```

Decision 7, check 2, replace (`:353-356`):

```markdown
2. **Absolute addresses** (raise). Decode old and new rebase targets,
   symbols, segment and section addresses, and `LC_ROUTINES_64`. Each must
   equal its old value plus G, or its old value if it named the header. The
   rebase targets must be the same set, at the same segment offsets.
```

with:

```markdown
2. **Absolute addresses** (raise). Decode old and new rebase targets,
   symbols, segment and section addresses, and `LC_ROUTINES_64`. Each must
   equal its old value plus G, or its old value if it named the header. The
   rebase targets must be the same set, at the same segment offsets. On the
   executable route the rebase half already runs, with a delta of 0 and the
   header's move of −G (`mg_verify_pointers`).
```

Decision 9, replace (`:397-399`):

```markdown
That interface sees no segment geometry. So the raise itself refuses a type
other than `REBASE_TYPE_POINTER`, and checks that offset + 8 ≤ the segment's
`filesize` (Decision 6).
```

with:

```markdown
That interface sees no segment geometry. `mg_rebases_read` (`src/grow.h`),
built for the executable route's data pointers, adds it: it refuses a type
other than `REBASE_TYPE_POINTER`, a target in the segment that maps the
header, and one not wholly within its segment's `filesize` (Decision 6), and
reads each target's value. The raise reuses it.
```

M2's first bullet, replace (`:438-443`):

```markdown
- **Enforce the one rule's strictly-inside refusal on both routes.** A RIP
  target, rebase value or symbol strictly inside (base, base + F) must
  refuse. M0 and M1 enforce only the exact-base case; `mhr_code` takes an
  exact target. Give the scan a range (lo, hi) and report each candidate's
  target. None of the 1,059 x86_64 executables on this host has such a
  target, but a `movl __mh_execute_header+16(%rip)` grows silently wrong.
```

with:

```markdown
- **Enforce the one rule's strictly-inside refusal on both routes.** A RIP
  target or symbol strictly inside (base, base + F) must refuse; a rebase
  value strictly inside already does, on the executable route
  (`mg_header_pointers`), and the raise reuses that. `mhr_code` takes an
  exact target: give the scan a range (lo, hi) and report each candidate's
  target. What an in-range candidate that cannot be confirmed means is the
  owner's decision (QUEUE item 29, I1): measured, 1,060 in 120 of 1,059 host
  executables and 29 in Claude Code, none confirmed, so refusing them would
  stop 119 of those and Claude Code growing. A
  `movl __mh_execute_header+16(%rip)` still grows silently wrong.
```

If a passage has changed since this plan was written, make the equivalent edit and say so in the commit message.

- [ ] **Step 7: Check the docs and the tree**

Run each. Every negative has its positive control first:

```sh
git grep -n 'repaired N references to the header' -- compat/README.md                 # expect 1 line
git grep -n 'data pointers since' -- docs/superpowers/QUEUE.md                          # expect 1 line naming $C
git grep -c 'remaining half' "$P" -- docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md   # positive control: expect 1
rc=0; git grep -n 'remaining half' -- docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md || rc=$?; echo "rc=$rc"   # expect rc=1
git grep -c 'Not repaired' "$P" -- docs/superpowers/QUEUE.md                            # positive control: expect 1
rc=0; git grep -n 'Not repaired' -- docs/superpowers/QUEUE.md || rc=$?; echo "rc=$rc"   # expect rc=1
git grep -c -E 'superpowers|specs/|plans/' -- docs/superpowers/QUEUE.md                 # positive control: expect > 0
rc=0; git grep -n -E 'superpowers|specs/|plans/' -- src tests CMakeLists.txt || rc=$?; echo "rc=$rc"   # expect rc=1
```

- [ ] **Step 8: Commit**

```bash
git add compat/README.md docs/superpowers/QUEUE.md docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md
git commit -F- <<EOF
docs: a grow moves the data pointers that name the header

QUEUE item 29's data half is done since $C: a grown Java launcher stub
runs, where it died of SIGSEGV. The corpus sweep over this host's 1,128
x86_64 files changes six: restoreui, MRT and cgpdftoraster now move their
pointer, and dnsextd, mDNSResponder and mDNSResponderHelper refuse for
their local relocations. The code half of I1 is measured and handed to
dylib-growth M2 as the owner's decision; the spec now says what the
executable route already does with data pointers.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
EOF
```

(The heredoc is unquoted so `$C` expands; check `git log -1` shows the hash, not `$C`. If Task 4 was skipped, drop its clause from the message and from QUEUE's paragraph.)

---

## Self-review

**1. Spec coverage.**

| requirement | task |
|---|---|
| Decision 1: a rebased data pointer to the header loses G on the executable route | 2 |
| Decision 1's one rule, rebase-value half: strictly inside (base, base + F) refuses | 2 |
| Decision 6: refuse a rebase type other than pointer, a target past `filesize`, a rebase in `__TEXT` | 1 |
| Decision 6: refusals leave the buffer untouched | 1, 2, 4 |
| Decision 7 check 2, executable route (delta 0): same targets, same offsets, each value unchanged or, if it named the header, the new base | 3 |
| Decision 8: the announcement | 2 |
| Decision 9: geometry for the shared decoder | 1 |
| Item 29: the Java stub grows and runs; the sweep; the queue and spec updated | 5 |
| Task-brief questions: zero-fill and past-`filesize` slots (refused, 0 here); `TEXT_ABSOLUTE32` (refused, 0 here); self-binds (none here, need nothing, pinned) | 1, 2 |

The code and symbol halves of I1 are not here, by decision (a).

**2. Placeholder scan.** No "TBD" or "similar to Task N". Every step has its code. `$C`, `$P` and `$W` are computed by Task 5's own commands. `<authoring model>` is the trailer's own wording.

**3. Type and name consistency.** `mg_rbval {at, vm, value}` and `mg_rebases {s, v}` (Task 1) are what Tasks 2–4 read. `mg_rebases_read(buf, fsize, &r, why, whysz)` and `mg_rebases_free(&r)` are called with those arguments in Tasks 2 and 3. `mg_header_pointers(buf, fsize, base, first, grow, why, whysz)` (Task 2) is called with them by `mg_ensure_pad` and `mg_grow_header`. `mg_snapshot.rb` (Task 3) is what `mg_verify_pointers` reads. The test helpers `build_pointer_image`, `pt_seg`, `pt_type`, `pt_unreadable`, `pt_values`, `check_pointers_after`, `check_grow_refuses_a_pointer_inside`, `check_ensure_pad_announces`, `check_verify_rejects_pointer`, `pt_ops_now` and `pt_slots_now` are each defined before their first use.

**4. Review Focus.** Five inputs the spec implies and no requirement names: unreadable or oddly slid pointers, the rule's edges, a slot rebased twice, a self-bind, and local relocations. Each has its test in the owning task.

**What the spec leaves open, decided here:** where the reader lives (Task 1); what a zero-fill or twice-named slot means (Task 1); one clause or two (Task 2, Question 3); binds (Task 2); classic relocations (Task 4, Question 2); the code half of I1 (Question 1, to M2).
