# Header references, M1: repair code that addresses its own header — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a grow lowers an executable's base, it repairs every instruction that reaches the image's own header by RIP-relative distance (M0 only warned), after confirming by decoding that each is an instruction; it refuses the grow when it cannot confirm one; it moves the `__mh_execute_header` symbol with the header; and it proves the repair in its own verification. QUEUE item 29's reproduction then grows and runs.

**Architecture:** A new, self-contained module, `src/x86len.[ch]` (`mx_`), gives the length of one x86-64 instruction and where its ModRM, displacement and immediate lie; a local test holds it to 10.9's `otool` over every function of twelve of 10.9's own images. `src/hdrref.[ch]` gains `mhr_confirm`: for each candidate M0's scan finds, it decodes from the candidate's `LC_FUNCTION_STARTS` function start, stepping over `LC_DATA_IN_CODE`, and requires an instruction whose RIP-relative disp32 is the candidate's and whose target is exactly the base. `mg_grow_header` (`src/grow.c`) refuses before it mutates anything unless every candidate is confirmed, records the candidates in its snapshot, takes the grow off each disp32 after the file moves, moves each non-stab `N_SECT` symbol whose value is the old base, and `mg_verify` re-scans the result (the spec's verification check 5). `mg_ensure_pad`'s M0 warning becomes a clause of its announcement.

**Tech Stack:** C as the 10.9 clang (Apple LLVM 6.0) accepts it; CMake through shipyard; POSIX `sh` suites; hand-built in-memory Mach-O fixtures in `tests/grow_test.c`; a hermetic table of hand-assembled instructions in the new `tests/x86len_test.c`; `otool -tv` over 10.9's own images in the new `tests/x86len_oracle_test.sh`; two tiny x86_64 programs compiled at test time in `tests/grown_binary_runs_test.sh`.

**Spec:** `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`. M1 is its "M1" milestone and the M1 rows of its Testing table: the instruction-length decoder with its `otool` oracle; confirmation and patching on the executable route (Decision 3), with Decision 6's refusal of a candidate the decoder cannot confirm or an image with no `LC_FUNCTION_STARTS`; the announcement's repair clause (Decision 8); verification check 5 (Decision 7); and item 29's reproduction growing and running. M2 (the raise route) and M3 are out of scope.

## Claude Code: the measurement that decides M1

M1 is worth landing only if the decoder confirms all seven of a fresh Claude Code's candidates. Measured 2026-09-25 on a scratch copy of the ungrown snapshot `~/.local/share/claude-binary-snapshots/2.1.282.49763317.bin` (manifest: `pristine`, sha256 `5c34b00b…`; the snapshots themselves were never modified):

- **All 7 are confirmed**, and a grow of that copy (`fixups set classic`, then a 6000-byte `rpath append`) exits 0 announcing `image base 0x100000000 -> 0xffffe000; repaired 7 references to the header`; each of the seven disp32s then targets `0xffffe000`, and `verify` says `OK`.
- The seven sit 31, 31, 55, 42, 49, 42 and 405 bytes into their functions (`0x100041550`, `0x100044fb0`, `0x100098420`, `0x1000ab180`, `0x1000b97f0`, `0x1000baaa0`, `0x1001dd300`), so confirming them decodes **168 instructions**.
- **Those 168 need no AVX, no VEX (C4/C5), no EVEX (62), no 3DNow! and no legacy prefix** (no 66, F2, F3, F0 or segment override). They are one-byte opcodes, most with a REX prefix (`push`, `mov`, `lea`, `call`, `jcc rel8`, `cmp`, `test`, `xor`, `sub`, `movabs`), and three two-byte ones: `xorps` (0F 57), `movups` (0F 11) and `jcc rel32` (0F 8x). No `LC_DATA_IN_CODE` range falls inside them.
- The whole binary is another matter (LLVM 22's `llvm-objdump`, 15.85 million lines over its code sections): 43,446 VEX instructions, 16,181 EVEX (AVX-512), 366 byte sequences that would read as XOP (`8F` with a map of 8 or more), no 3DNow!, and every legacy prefix; and 4,848 `LC_DATA_IN_CODE` jump tables.
- An installed copy is already grown (base `0xfffff000`): its seven references name `0x100000000`, which is no longer the base, so M1 finds nothing to repair and grows it with no clause, exactly as M0 printed no warning.

**Cost of a grow.** The same 230 MB grow takes 0.78 s wall with M0's build and 2.0–2.2 s with M1's. The sweeps are not the cost: decoding all 15.4 million instructions of `__text` takes 0.38 s, the largest function is 208,832 bytes, and the seven sweeps decode 168 instructions. The cost is five scans of the 64 MB `__text` at about 0.15 s each: `mg_ensure_pad`'s count, `mhr_confirm`'s, the snapshot's, and two in `mg_verify`.

## The oracle: what 10.9's `otool` can vouch for

`otool` here is cctools-862 with LLVM 3.5svn's disassembler.

- **Legacy, SSE, AES-NI, AVX, AVX2 and FMA: yes.** Over the committed corpus (twelve images, 1,511,420 instructions in 12,387 functions, 3 s) and over every x86_64 image in `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, `/usr/libexec`, `/usr/lib` and the top level of `/System/Library/{,Private}Frameworks` (1,467 images, 49,641,008 instructions in 774,149 of 785,974 functions), the decoder's boundaries equal `otool`'s with **0 mismatches**. So do they over Claude Code's `__text` (13,934,503 instructions, stepping over its `LC_DATA_IN_CODE`).
- **AVX-512: no.** Against LLVM 22 at every VEX and EVEX instruction of Claude Code, `otool` disagrees at 6,008 of 16,179 EVEX instructions (AVX-512BW, DQ and VBMI: `vpcmpeqb`, `vmovdqu8/16`, `vpermb`, `vpternlogd`, …; it does read AVX-512F's `vmovdqa64`) and at 4,140 of 42,951 VEX ones (the opmask instructions `kmov*`, `kor*`, `kortest*`, and 256-bit `vaesenc` / `vpclmulqdq`).
- **So the decoder does not decode EVEX, XOP or 3DNow!** (Plan decision, Task 1). An EVEX instruction before a candidate makes the candidate unconfirmable, and the grow refuses: safe, and none of Claude Code's seven meets one.
- **Fallback:** LLVM 22.1.1's `/usr/local/mavericks-clang-22/bin/llvm-objdump` exists on this host. Measured once, not committed: at every instruction start it reports in Claude Code's `__text` (prefixes it prints on lines of their own and bytes it cannot decode aside), the decoder's length equals LLVM's at 15,357,544 and is refused at 15,825 (15,820 EVEX, 5 others), and never differs. All 41,448 VEX instructions agree, opmask ones among them. The one difference found while writing this plan, `66 E9` (a jump whose length Intel and AMD disagree on), is now among the refused. Of the decoder's own test cases, LLVM decodes every one as the decoder does, and `otool` all but one (a REX before a `66`, noted in the test). If a later milestone decodes EVEX, `llvm-objdump` is its oracle; it disassembles Claude Code in 3 minutes, too slow for the suite.
- **What `otool -tv` needs from the comparison** (Task 2): it prints `lock`, `rep`, `repne`, segment and `data16` prefixes as instructions of their own, at the prefix's address; it disassembles `LC_DATA_IN_CODE` jump tables as code; and a linear sweep of `__text` can be out of step at a function's start, after padding. `-tV` also breaks instruction lines with symbolizer diagnostics (`part of section contents of: (__DATA,__bss) is past end of file`) on 6 of the 1,477 x86_64 images surveyed, `spindump` among them; `-tv` does not.
- **The 10.9 toolchain writes no `LC_DATA_IN_CODE` entries** (every corpus image has an empty one): its jump tables sit inline in `__text`, after the code of their function. A candidate after an inline jump table in its own function would be unconfirmable; M1 then refuses.

## A finding for the spec: data pointers to the header

Decision 2 says the executable route "leaves [absolute vm addresses] alone". That is right for addresses that name content and wrong for one that names the header, which moves. `const void *hp = &_mh_execute_header;` is a rebase target whose value is the base; grown by M0, the program reports `data pointer MISSES the header (off by 4096)`. 46 of the 838 x86_64 executables on this host have one (the Java launcher stubs among them); Claude Code has none among its 94,730 rebase targets. Repairing it needs the rebase decoder of Decision 9, which M2 builds, so **M1 does not repair it** (Plan decision, Task 6); QUEUE item 29 records it. The `__mh_execute_header` symbol (the addendum to item 29) is the same class, and M1 does repair that (Task 5).

## Global Constraints

- **Line numbers** are at `cd05fea`, `main` when this plan was written, before any task. Every edit also quotes the text it anchors on, and that text is what to match; `src/grow.c` line numbers drift within Tasks 4 and 5, and `tests/grow_test.c`'s within Tasks 3 to 5.
- **Build:** `B=/private/tmp/build/schmonz/drydock-native` (the existing Ninja build directory); build with `shipyard-cmake --build "$B" -j`; a single C test runs as `"$B/<name>"`. Writing this plan (2026-09-25, after 14:21), `/usr/local/bin/shipyard-cmake` and `/usr/local/bin/shipyard-ctest` did not exist on this host; shipyard's commands were `/usr/local/mavergreen/bin/shipyard-cmake` and `-ctest`. Use whichever exists. `$B`'s `build.ninja` names the removed `/usr/local/mavergreen-shipyard/bin/cmake`, and `ninja -n` there wants to re-run CMake; if the build fails for that reason, configure `$B` afresh first: `/usr/local/mavergreen/bin/shipyard-cmake -S . -B "$B" -G Ninja -DCMAKE_TOOLCHAIN_FILE=/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/MavericksToolchain.cmake -DMAVERICKS_EXPECTED_MODE=native -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64` (the same command, without `-G Ninja`, configured every scratch build this plan was checked in; `--preset native` did not, with the committed `CMakePresets.json`).
- **Test:** `unset DRYDOCK_MACHO_REWRITE; shipyard-ctest --test-dir "$B"` (the `shipyard-ctest` beside the `shipyard-cmake` above). A shell test runs alone as `unset DRYDOCK_MACHO_REWRITE; sh tests/<name>.sh "$B"`, from the repo root.
- **Rebuild check (clock skew on this host).** Before every build, `pre=$(shasum -a 256 "$B/<target>")`; after it, compare. A `touch` does not force a relink here: delete the edited source's object file, `$B/libdrydockcore.a` and the test binary before the build. **When a header changes, delete every object** (`find "$B/CMakeFiles" -name '*.o' -delete`): writing this plan, swapping `src/grow.h` back and forth left an object built against the other `mg_snapshot` layout, and `grow_test` died of SIGSEGV. A result against an unchanged binary is not a result.
- **TDD and mutation proof** for every task: the test first, seen failing for the stated reason; then the code; then every row of the task's mutation table, each applied alone to a saved copy (`M=$(mktemp -d "${TMPDIR:-/tmp}/m1-mut.XXXXXX") && cp FILE "$M/"`; 10.9's `mktemp` needs a template; edit, rebuild with the rebuild check, run, then `cp "$M/$(basename FILE)" FILE && cmp FILE "$M/$(basename FILE)"`, rebuild), and seen to fail the named test. A mutation no test kills is a finding: add the test that kills it, in the same task. Never use `git stash` or `git checkout --` to undo an edit; restore from the `cp`.
- **M1 adds refusals**, each before anything is mutated, each `EX_REFUSED` with its reason on stderr: a candidate `mhr_confirm` cannot confirm; a candidate in an image with no `LC_FUNCTION_STARTS`; an instruction section that runs past the file (M0 warned and grew); and an `LC_SYMTAB` symbol table that runs past the file.
- **Comments are a last resort:** prefer a test, then the commit message, then a doc, then one inline sentence. No history narration, and no reference to a plan or spec from source (both are deleted once implemented).
- **Exit codes:** `EX_REFUSED` = 1, `EX_FAIL` = 2. Drydock never writes its input, and writes nothing on a refusal.
- **Every grep negative needs a positive control.** In shell, `rc=0; cmd || rc=$?`.
- **Staging:** stage explicit paths only (never `git add -A` or `.`); commit on `main`; do not push. Every commit message ends with:
  ```
  Co-Authored-By: <authoring model> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
  ```
- **CI runs on `macos-26` (arm64).** It runs the whole ctest suite from a cross build; x86_64 test programs run there under Rosetta. `x86len_test` and `grow_test` are hermetic and run there. `tests/grown_binary_runs_test.sh`'s `hdr` fixture is linked there by CI's clang for 10.9 and x86_64, and its grown copy must now run under Rosetta. `x86len_oracle_test` SKIPs there (exit 77): the runner keeps its libraries in the shared cache, so the corpus is absent. After the owner pushes, CI is a separate gate.
- **The corpus tests are local-only.** `tests/x86len_oracle_test.sh` and Task 6's Claude Code check SKIP, saying why, where their tools or images are absent.
- **Docs:** `compat/README.md`'s warning wording becomes the repair wording; QUEUE item 29 is marked done in the last task. `README.md` has no paragraph on a grow's output and is not touched.

## Review Focus

1. **Bytes that only look like a reference** (a `05` inside another instruction's immediate, or a SIB byte `25` before a disp32) → the grow refuses rather than patch them. Pinned by Task 3's `test_confirm_rejects_a_lookalike_inside_an_immediate`, `test_confirm_rejects_an_absolute_address_that_looks_rip_relative`, `test_confirm_rejects_a_lookalike_inside_a_rip_relative_instruction`, and Task 4's `test_grow_refuses_a_header_reference_it_cannot_confirm`.
2. **A reference followed by an immediate** (`cmpl $1, __mh_execute_header(%rip)`) → confirmed and repaired, and one whose immediate moves its target off the header is not. Pinned by Task 3's `test_confirm_an_operand_with_an_immediate` and `test_confirm_rejects_an_operand_whose_immediate_moves_its_target`.
3. **A function holding AVX-512, or a jump table, before the reference** → refused, never misdecoded; a jump table `LC_DATA_IN_CODE` names is stepped over. Pinned by Task 3's `test_confirm_rejects_what_the_decoder_cannot_decode`, `test_confirm_steps_over_data_in_code`, `test_confirm_orders_data_in_code` and `test_confirm_rejects_a_candidate_inside_data_in_code`.
4. **A reference in a section its function does not start in** (`__stubs`, or code before the first function start) → refused. Pinned by Task 3's `test_confirm_needs_a_function_in_the_candidates_section`.
5. **A refused grow** → nothing written, and no byte of the buffer changed, symbols included. Pinned by Task 4's `check_grow_refuses_header_refs` ("nothing changed") and Task 5's `test_grow_moves_no_symbol_when_it_refuses`.

## Plan decisions at a glance

Each is repeated, with its reason, in the task that makes it.

- Task 1: the decoder is its own module, `src/x86len.[ch]` (`mx_`): the spec asks for a self-contained one, and M2 needs it unchanged. It is table-driven, and it decodes legacy and REX prefixes, the one-byte map, 0F, 0F 38, 0F 3A and VEX. It **refuses** EVEX, XOP, 3DNow!, every opcode invalid in 64-bit mode (and `F1`, `CE`, `EA`, `9A`), the undefined encodings of groups `8F`, `C6`/`C7`, `FE` and `FF`, the `F6 /1` and `F7 /1` aliases of `test` (which neither `otool` nor LLVM decodes), a `66`-prefixed `rel32` branch, and anything over 15 bytes or past the bytes it is given. What it refuses leaves a candidate unconfirmed, and so refuses the grow.
- Task 1: `tests/x86len_test.c` decodes every case from the end of a page whose next page is unmapped, so a read past `avail` crashes the test instead of passing unseen.
- Task 2: the oracle reads `otool -tv`, not the spec's `-tV`: the same instructions, without the symbolizer's diagnostics that break lines on some images. It joins `otool`'s prefix-only lines to the next, compares a function only when `otool` has a line at its start, and stops a function at bytes either side cannot decode (the inline jump tables). The corpus is twelve fixed images covering C, C++, Objective-C, SSE through AVX2, FMA and AES-NI (3 s); the 1,467-image run and the `llvm-objdump` fallback were measurements, recorded above, not tests.
- Task 3: confirmation lives in `src/hdrref.[ch]` (`mhr_confirm`), beside the scan it confirms; its interface only grows. It confirms against the image's own base, reads the first `LC_FUNCTION_STARTS` and `LC_DATA_IN_CODE` as `src/grow.c` does, ignores either when its payload runs past the file, answers `MHR_UNSCANNABLE` whenever the scan does (any instruction section past the file, wherever it lies), requires the function to start in the candidate's own section, and requires the instruction's RIP-relative ModRM, its disp32 at the candidate, and its end (so its immediate) to make the target exactly the base.
- Task 4: `mg_grow_header` refuses before mutating (Decision 6), after its existing audits; the repair is `disp32 -= G` at the candidate's file offset plus G. Check 5 lives in `mg_verify`, driven by the snapshot (now base and candidates), so a test can undo a repair after a grow and see verification refuse it. `mg_ensure_pad` counts the candidates itself (one more scan) rather than change `mg_grow_header`'s signature, and says "1 reference" or "N references".
- Task 4: an instruction section past the end of the file now refuses the grow (M0 warned): M1 adds refusals, and code no one can read cannot be shown not to address the header. The scan still reads on past such a section and answers -1 (`15939c7`); `mhr_confirm` turns that -1 into `MHR_UNSCANNABLE` even when every candidate it could read was confirmed (Task 3), so the refusal does not depend on where the bad section lies.
- Task 4: M0's `test_ensure_pad_warns_across_a_two_page_grow` becomes `test_ensure_pad_repairs_across_a_two_page_grow`: the same two-page grow, now repaired and announced, with the lea checked against the base two pages down. It is the one test that tells `disp -= grow` from `disp -= MG_PAGE`, as M0's told `base_before - base_after` from `MG_PAGE`.
- Task 4: `hdr` no longer prints its lea's disp32; the test now runs the grown `hdr` and compares it with the original, as the spec's M1 row asks.
- Task 5: M1 fixes item 29's addendum. A grow moves each symbol that names the header: `N_SECT`, not a stab, with value exactly the old base. A stab or an `N_ABS` symbol with that value is left alone. A symbol table that runs past the file refuses the grow before anything moves. Every grown executable's `__mh_execute_header` therefore changes value: after Task 4, a grow of an image with no header reference is byte-identical to M0's; after Task 5 it differs in exactly those 4 bytes.
- Task 6: a data pointer to the header (a rebase value equal to the base) is **not** repaired by M1: that needs the rebase decoder M2 builds (spec Decision 9). QUEUE item 29 records it, with its measured reach.

## File structure

| file | status | responsibility | task |
|---|---|---|---|
| `src/x86len.h`, `src/x86len.c` | new | `mx_decode`: one instruction's length, ModRM, displacement and immediate | 1 |
| `tests/x86len_test.c` | new | the decoder, case by case, from a page end | 1 |
| `tests/x86len_oracle.c`, `tests/x86len_oracle_test.sh` | new | the decoder against `otool -tv` over 10.9's images (local) | 2 |
| `CMakeLists.txt` | modify | `src/x86len.c` in `drydockcore`; `x86len_test`; `x86len_oracle` and its test | 1, 2 |
| `src/hdrref.h`, `src/hdrref.c` | modify | `mhr_confirm`, and the scan's walk knowing its section | 3 |
| `tests/grow_test.c` | modify | confirmation (3); repair, refusals, check 5, the announcement (4); symbols (5) | 3–5 |
| `src/grow.c`, `src/grow.h` | modify | refusal, repair, snapshot, check 5, announcement (4); symbols (5) | 4, 5 |
| `tests/grown_binary_runs_test.sh` | modify | `hdr` grows, says so, and runs as the original (4); its symbol (5) | 4, 5 |
| `compat/README.md`, `docs/superpowers/QUEUE.md` | modify | the repair's wording; item 29 done | 6 |

## How this plan was checked

Every code block below was applied, task by task, to a fresh `git archive` of `cd05fea` in a scratch directory with its own build, configured with the toolchain file as above (`cd05fea`'s `CMakePresets.json` includes the removed shipyard's presets). The blocks and that check come from one source, so the plan's text is what was built. At each task, the named tests failed exactly as each "Run it to see it fail" step says, then passed, and each task was committed. The whole ctest suite passed at the end: 25 tests, `chained_fixups` skipped as on `main`. All 95 mutation rows (98 runs, counting the rows also run against `tests/grown_binary_runs_test.sh`) were then applied one at a time to the finished tree, each rebuilt after deleting every object, and each failed the test its row names. A 6000-byte `rpath append` on `ctl`, `tests/fixture.macho` and `/usr/bin/printf` (none has a header reference) gave outputs byte-identical to M0's after Task 4, and differing from M0's only in `__mh_execute_header`'s 4-byte value after Task 5.

---
### Task 1: An x86-64 instruction-length decoder (`src/x86len.[ch]`)

**Files:**
- Create: `src/x86len.h`, `src/x86len.c`, `tests/x86len_test.c`
- Modify: `CMakeLists.txt:66` (the `add_library(drydockcore STATIC ... src/hdrref.c)` line) and after `:206` (`add_test(NAME trie_test COMMAND trie_test)`)

**Interfaces:**
- Consumes: nothing.
- Produces (Task 3 calls it; Task 2 checks it):
  - `typedef struct { int len; int modrm; int disp; int displen; int immlen; } mx_insn;`: the length (1 to 15); the offset of the ModRM byte, or -1; the offset of the displacement, or -1, and its length (0, 1, 4, or 8 for a `moffs`); the bytes of immediate, a relative branch's offset included.
  - `int mx_decode(const uint8_t *code, size_t avail, mx_insn *out);` → 1 with `*out` filled, or 0 if the bytes are not an instruction it decodes or run past `avail`. It reads no byte at or past `avail`.

**Plan decisions.** A module of its own because the spec asks for a self-contained decoder and M2 reuses it. Table-driven: one letter per opcode in each map says what follows it. What it decodes is what 10.9's `otool` can check (see "The oracle", above) and what Claude Code's seven candidates need; everything else is refused, which costs at most a refused grow. It refuses a `66`-prefixed `rel32` branch because Intel reads it as 4 bytes of offset and AMD as 2, and `llvm-objdump` and the decoder disagreed on exactly that, once, in Claude Code; and `F6 /1` and `F7 /1`, because neither disassembler here decodes them, so no oracle vouches for a length. XOP needs no case of its own: an `8F` whose next byte has a map of 8 or more has a nonzero ModRM.reg, which group `8F` refuses. The tests decode from a page's end, with the next page unmapped, so a read past `avail` crashes rather than passes.

- [ ] **Step 1: Write the failing test**

Create `tests/x86len_test.c`:

```c
/*
 * tests/x86len_test.c -- hermetic tests for src/x86len.h's mx_decode.
 *
 * Each case is an instruction's bytes, hand-assembled, and where its ModRM,
 * displacement and immediate lie. LLVM 22's llvm-objdump decodes each as it
 * is here, and so does 10.9's otool, except where a case says otherwise;
 * tests/x86len_oracle_test.sh checks the decoder against otool over real
 * images.
 */
#include "x86len.h"
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

struct xcase {
    const char *what;
    int n;                 /* bytes available */
    uint8_t b[16];
    int len, modrm, disp, displen, immlen;   /* len 0: not decoded */
};

#define D32 0x11, 0x22, 0x33, 0x44
static const struct xcase cases[] = {
    { "push %rbp", 1, { 0x55 }, 1, -1, -1, 0, 0 },
    { "mov %rsp, %rbp", 3, { 0x48, 0x89, 0xe5 }, 3, 2, -1, 0, 0 },
    { "mov %rax, %rsp (mod 3, r/m 4: no SIB)", 3, { 0x48, 0x89, 0xc4 }, 3, 2, -1, 0, 0 },
    { "mov -8(%rbp), %eax (mod 1, r/m 5: not RIP)", 3, { 0x8b, 0x45, 0xf8 }, 3, 1, 2, 1, 0 },
    { "lea hdr(%rip), %rdx", 7, { 0x48, 0x8d, 0x15, D32 }, 7, 2, 3, 4, 0 },
    { "cmpl $1, x(%rip)", 7, { 0x83, 0x3d, D32, 0x01 }, 7, 1, 2, 4, 1 },
    { "movl $imm32, x(%rip)", 10, { 0xc7, 0x05, D32, D32 }, 10, 1, 2, 4, 4 },
    { "movw $imm16, x(%rip)", 9, { 0x66, 0xc7, 0x05, D32, 0x01, 0x02 }, 9, 2, 3, 4, 2 },
    { "testb $1, 0x250(%rdi)", 7, { 0xf6, 0x87, 0x50, 0x02, 0x00, 0x00, 0x01 }, 7, 1, 2, 4, 1 },
    { "testl $imm32, %eax (F7 /0)", 6, { 0xf7, 0xc0, D32 }, 6, 1, -1, 0, 4 },
    { "notl (%rax) (F7 /2)", 2, { 0xf7, 0x10 }, 2, 1, -1, 0, 0 },
    { "notb (%rax) (F6 /2)", 2, { 0xf6, 0x10 }, 2, 1, -1, 0, 0 },
    { "mov 8(%rsp), %eax (SIB, disp8)", 4, { 0x8b, 0x44, 0x24, 0x08 }, 4, 1, 3, 1, 0 },
    { "mov abs32, %eax (SIB, no base)", 7, { 0x8b, 0x04, 0x25, D32 }, 7, 1, 3, 4, 0 },
    { "mov (%rbp,%rax), %eax (SIB base rbp, mod 1)", 4, { 0x8b, 0x44, 0x05, 0x00 }, 4, 1, 3, 1, 0 },
    { "mov disp32(%rax), %eax", 6, { 0x8b, 0x80, D32 }, 6, 1, 2, 4, 0 },
    { "movabs $imm64, %rax", 10, { 0x48, 0xb8, D32, D32 }, 10, -1, -1, 0, 8 },
    { "mov $imm32, %eax", 5, { 0xb8, D32 }, 5, -1, -1, 0, 4 },
    { "mov $imm32, %r8d (REX without W)", 6, { 0x41, 0xb8, D32 }, 6, -1, -1, 0, 4 },
    { "mov $imm16, %ax", 4, { 0x66, 0xb8, 0x01, 0x02 }, 4, -1, -1, 0, 2 },
    /* otool reads this as data16 and a 32-bit immediate; the CPU and LLVM do not. */
    { "a REX before a prefix counts for nothing", 5, { 0x48, 0x66, 0xb8, 0x01, 0x02 }, 5, -1, -1, 0, 2 },
    { "mov moffs64, %eax", 9, { 0xa1, D32, D32 }, 9, -1, 1, 8, 0 },
    { "mov moffs32, %eax (67)", 6, { 0x67, 0xa1, D32 }, 6, -1, 2, 4, 0 },
    { "call rel32", 5, { 0xe8, D32 }, 5, -1, -1, 0, 4 },
    { "jmp rel8", 2, { 0xeb, 0x06 }, 2, -1, -1, 0, 1 },
    { "je rel32", 6, { 0x0f, 0x84, D32 }, 6, -1, -1, 0, 4 },
    { "enter $16, $0", 4, { 0xc8, 0x10, 0x00, 0x00 }, 4, -1, -1, 0, 3 },
    { "ret $8", 3, { 0xc2, 0x08, 0x00 }, 3, -1, -1, 0, 2 },
    { "bt $10, %eax (0F BA)", 4, { 0x0f, 0xba, 0xe0, 0x0a }, 4, 2, -1, 0, 1 },
    { "shufps $0x1b (0F C6)", 4, { 0x0f, 0xc6, 0xc1, 0x1b }, 4, 2, -1, 0, 1 },
    { "pshufb (0F 38)", 5, { 0x66, 0x0f, 0x38, 0x00, 0xc1 }, 5, 4, -1, 0, 0 },
    { "palignr $8 (0F 3A)", 6, { 0x66, 0x0f, 0x3a, 0x0f, 0xc1, 0x08 }, 6, 4, -1, 0, 1 },
    { "xorps %xmm0, %xmm0", 3, { 0x0f, 0x57, 0xc0 }, 3, 2, -1, 0, 0 },
    { "paddd %mm1, %mm2 (0F FE, reg 2)", 3, { 0x0f, 0xfe, 0xd1 }, 3, 2, -1, 0, 0 },
    { "cmpxchg8b (%rax) (0F C7, reg 1)", 3, { 0x0f, 0xc7, 0x08 }, 3, 2, -1, 0, 0 },
    { "movups %xmm0, x(%rip)", 7, { 0x0f, 0x11, 0x05, D32 }, 7, 2, 3, 4, 0 },
    { "syscall (0F, nothing more)", 2, { 0x0f, 0x05 }, 2, -1, -1, 0, 0 },
    { "vzeroupper (VEX, no ModRM)", 3, { 0xc5, 0xf8, 0x77 }, 3, -1, -1, 0, 0 },
    { "vmovdqa x(%rip), %xmm0 (VEX2)", 8, { 0xc5, 0xf9, 0x6f, 0x05, D32 }, 8, 3, 4, 4, 0 },
    { "vpshufd $0x1b (VEX2, imm8)", 5, { 0xc5, 0xf9, 0x70, 0xc1, 0x1b }, 5, 3, -1, 0, 1 },
    { "vpshufb (VEX3, 0F 38)", 5, { 0xc4, 0xe2, 0x7d, 0x00, 0xc1 }, 5, 4, -1, 0, 0 },
    { "vinsertf128 $1 (VEX3, 0F 3A)", 6, { 0xc4, 0xe3, 0x7d, 0x18, 0xc1, 0x01 }, 6, 4, -1, 0, 1 },
    { "vmovups x(%rip), %ymm0 (VEX3, 0F)", 9, { 0xc4, 0xe1, 0x7c, 0x10, 0x05, D32 }, 9, 4, 5, 4, 0 },
    { "lock cmpxchg %rdx, (%rcx)", 5, { 0xf0, 0x48, 0x0f, 0xb1, 0x11 }, 5, 4, -1, 0, 0 },
    { "rep movsb", 2, { 0xf3, 0xa4 }, 2, -1, -1, 0, 0 },
    { "nopw %cs:0(%rax,%rax)", 10, { 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0, 0, 0, 0 }, 10, 4, 6, 4, 0 },
    { "fifteen bytes", 15, { 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0, 0, 0, 0 },
      15, 9, 11, 4, 0 },
    { "xbegin rel32 (C7 F8)", 6, { 0xc7, 0xf8, D32 }, 6, 1, -1, 0, 4 },
    { "xabort $1 (C6 F8)", 3, { 0xc6, 0xf8, 0x01 }, 3, 1, -1, 0, 1 },
    { "pop (%rax) (8F /0)", 2, { 0x8f, 0x00 }, 2, 1, -1, 0, 0 },
    { "fldl (%rax) (x87)", 2, { 0xdd, 0x00 }, 2, 1, -1, 0, 0 },

    { "sixteen bytes", 16, { 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0, 0, 0, 0 },
      0, 0, 0, 0, 0 },
    { "EVEX (62)", 11, { 0x62, 0xf1, 0xfd, 0x48, 0x6f, 0x05, D32, 0x00 }, 0, 0, 0, 0, 0 },
    { "XOP (8F, map 8)", 6, { 0x8f, 0xe8, 0x78, 0xc2, 0xc1, 0x01 }, 0, 0, 0, 0, 0 },
    { "3DNow! (0F 0F)", 4, { 0x0f, 0x0f, 0xc1, 0xb4 }, 0, 0, 0, 0, 0 },
    { "VEX map 4", 6, { 0xc4, 0xe4, 0x7d, 0x00, 0xc1, 0x00 }, 0, 0, 0, 0, 0 },
    { "VEX with no ModRM form (0F 05)", 3, { 0xc5, 0xf8, 0x05 }, 0, 0, 0, 0, 0 },
    { "VEX with a rel32 (0F 84)", 7, { 0xc5, 0xf8, 0x84, D32 }, 0, 0, 0, 0, 0 },
    { "push %es (06, not in 64-bit mode)", 1, { 0x06 }, 0, 0, 0, 0, 0 },
    { "into (CE)", 1, { 0xce }, 0, 0, 0, 0, 0 },
    { "int1 (F1)", 1, { 0xf1 }, 0, 0, 0, 0, 0 },
    { "ljmp ptr16:32 (EA)", 7, { 0xea, D32, 0x00, 0x00 }, 0, 0, 0, 0, 0 },
    { "0F 04", 2, { 0x0f, 0x04 }, 0, 0, 0, 0, 0 },
    { "FF /7", 2, { 0xff, 0xff }, 0, 0, 0, 0, 0 },
    { "FE /2", 2, { 0xfe, 0x10 }, 0, 0, 0, 0, 0 },
    { "8F /1", 2, { 0x8f, 0x08 }, 0, 0, 0, 0, 0 },
    { "C7 /1", 6, { 0xc7, 0x08, D32 }, 0, 0, 0, 0, 0 },
    { "C6 /7 with memory", 3, { 0xc6, 0x38, 0x01 }, 0, 0, 0, 0, 0 },
    { "F6 /1, an alias of TEST", 3, { 0xf6, 0xc8, 0x01 }, 0, 0, 0, 0, 0 },
    { "F7 /1, an alias of TEST", 6, { 0xf7, 0xc8, D32 }, 0, 0, 0, 0, 0 },
    { "66 E8: Intel and AMD disagree on its length", 7, { 0x66, 0xe8, D32, 0x00 }, 0, 0, 0, 0, 0 },
    { "66 0F 84: likewise", 8, { 0x66, 0x0f, 0x84, D32, 0x00 }, 0, 0, 0, 0, 0 },
    { "a disp32 cut short", 6, { 0x48, 0x8d, 0x05, 0x11, 0x22, 0x33 }, 0, 0, 0, 0, 0 },
    { "an immediate cut short", 6, { 0x83, 0x3d, D32 }, 0, 0, 0, 0, 0 },
    { "a SIB cut short", 2, { 0x8b, 0x04 }, 0, 0, 0, 0, 0 },
    { "a ModRM cut short", 1, { 0x8b }, 0, 0, 0, 0, 0 },
    { "a prefix and nothing else", 1, { 0x66 }, 0, 0, 0, 0, 0 },
    { "0F and nothing else", 1, { 0x0f }, 0, 0, 0, 0, 0 },
    { "0F 38 and nothing else", 2, { 0x0f, 0x38 }, 0, 0, 0, 0, 0 },
    { "a VEX3 prefix cut short", 3, { 0xc4, 0xe1, 0x7c }, 0, 0, 0, 0, 0 },
    { "a VEX2 prefix cut short", 2, { 0xc5, 0xf8 }, 0, 0, 0, 0, 0 },
    { "8F cut short", 1, { 0x8f }, 0, 0, 0, 0, 0 },
};

/* A copy of `b` whose last byte ends a page, and the next page unmapped: a
 * decoder that reads past `n` bytes crashes the test instead of reading
 * whatever follows. */
static const uint8_t *at_page_end(const uint8_t *b, int n) {
    static uint8_t *pages;
    long pg = sysconf(_SC_PAGESIZE);
    if (!pages) {
        pages = (uint8_t *)mmap(NULL, 2 * (size_t)pg, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANON, -1, 0);
        if (pages == MAP_FAILED || mprotect(pages + pg, (size_t)pg, PROT_NONE) != 0) return NULL;
    }
    memcpy(pages + pg - n, b, (size_t)n);
    return pages + pg - n;
}

static void test_each_case(void) {
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        const struct xcase *c = &cases[i];
        const uint8_t *b = at_page_end(c->b, c->n);
        CHECK(b != NULL, "setup: a guard page");
        if (!b) return;
        mx_insn in = { 99, 99, 99, 99, 99 };
        int ok = mx_decode(b, (size_t)c->n, &in);
        if (c->len == 0) {
            CHECK(!ok, "%s: decoded as %d bytes, want not decoded", c->what, in.len);
            continue;
        }
        CHECK(ok, "%s: not decoded", c->what);
        if (!ok) continue;
        CHECK(in.len == c->len && in.modrm == c->modrm && in.disp == c->disp &&
              in.displen == c->displen && in.immlen == c->immlen,
              "%s: len %d modrm %d disp %d/%d imm %d, want %d %d %d/%d %d", c->what,
              in.len, in.modrm, in.disp, in.displen, in.immlen,
              c->len, c->modrm, c->disp, c->displen, c->immlen);
    }
}

/* Bytes past the instruction do not change it. */
static void test_ignores_what_follows(void) {
    uint8_t b[8] = { 0x48, 0x8d, 0x05, 0x11, 0x22, 0x33, 0x44, 0xff };
    mx_insn in;
    CHECK(mx_decode(b, sizeof b, &in) == 1 && in.len == 7, "a lea followed by more bytes is 7 bytes");
}

int main(void) {
    test_each_case();
    test_ignores_what_follows();
    if (fails) { printf("x86len_test: %d FAILURE(S)\n", fails); return 1; }
    printf("x86len_test: all cases pass\n");
    return 0;
}
```

In `CMakeLists.txt`, after `add_test(NAME trie_test COMMAND trie_test)` (`:206`), the result reading:

```cmake
add_test(NAME trie_test COMMAND trie_test)

# Hermetic tests for src/x86len.c's instruction-length decoder: hand-assembled
# instructions and where their operands lie. tests/x86len_oracle_test.sh
# checks the same decoder against otool over real images.
add_executable(x86len_test tests/x86len_test.c)
target_compile_options(x86len_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(x86len_test PRIVATE drydockcore)
add_test(NAME x86len_test COMMAND x86len_test)
```

- [ ] **Step 2: Run it to see it fail**

Run: build (Build command).
Expected: the build fails: `tests/x86len_test.c:10:10: fatal error: 'x86len.h' file not found`.

- [ ] **Step 3: Write `src/x86len.h`**

```c
#ifndef DRYDOCK_X86LEN_H
#define DRYDOCK_X86LEN_H
/*
 * mx_ -- the length of one x86-64 instruction, and where its operands lie.
 *
 * Legacy and REX prefixes, the one-byte map, 0F, 0F 38, 0F 3A, and VEX
 * (C4, C5): everything the 10.9 toolchain emits and 10.9's otool
 * disassembles. EVEX (62), XOP (8F with map 8 or above), 3DNow! (0F 0F),
 * and every opcode that is invalid in 64-bit mode are not decoded, so a
 * caller never trusts a length for them.
 */
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int len;      /* 1 to 15 */
    int modrm;    /* offset of the ModRM byte, or -1 if there is none */
    int disp;     /* offset of the displacement, or -1 */
    int displen;  /* 0, 1, 4 or 8 (a moffs) */
    int immlen;   /* bytes of immediate, relative branch offset included */
} mx_insn;

/* Decodes the instruction at code[0, avail). Returns 1 with *out filled, or
 * 0 if it is not one this decoder knows or it runs past `avail`. */
int mx_decode(const uint8_t *code, size_t avail, mx_insn *out);

#endif /* DRYDOCK_X86LEN_H */
```

- [ ] **Step 4: Write `src/x86len.c`**

```c
/* mx_ -- see x86len.h. */
#include "x86len.h"

/* One letter per opcode, sixteen to a row:
 *   m  ModRM                      b  ModRM, imm8
 *   z  ModRM, imm16/32 (66: 16)   g  ModRM, imm8 if ModRM.reg is 0 (F6)
 *   G  ModRM, imm16/32 if ModRM.reg is 0 (F7)
 *   -  nothing more               1  imm8 or rel8
 *   2  imm16                      3  imm16, imm8 (enter)
 *   4  rel32                      Z  imm16/32 (66: 16)
 *   V  imm16/32/64 (REX.W: 64, 66: 16)
 *   A  moffs: an 8-byte address (67: 4)
 *   p  a prefix                   x  not decoded
 *   T  0F                         S  0F 38            U  0F 3A
 *   X  VEX (C4, C5) */
static const char mx_map0[] =
    "mmmm1Zxxmmmm1ZxT" "mmmm1Zxxmmmm1Zxx" "mmmm1Zpxmmmm1Zpx" "mmmm1Zpxmmmm1Zpx"
    "pppppppppppppppp" "----------------" "xxxmppppZz1b----" "1111111111111111"
    "bzxbmmmmmmmmmmmm" "----------x-----" "AAAA----1Z------" "11111111VVVVVVVV"
    "bb2-XXbz3-2--1x-" "mmmmxxx-mmmmmmmm" "1111111144x1----" "pxpp--gG------mm";

static const char mx_map1[] =
    "mmmmx-----x-xm-x" "mmmmmmmmmmmmmmmm" "mmmmxxxxmmmmmmmm" "------x-SxUxxxxx"
    "mmmmmmmmmmmmmmmm" "mmmmmmmmmmmmmmmm" "mmmmmmmmmmmmmmmm" "bbbbmmm-mmxxmmmm"
    "4444444444444444" "mmmmmmmmmmmmmmmm" "---mbmxx---mbmmm" "mmmmmmmmmmbmmmmm"
    "mmbmbbbm--------" "mmmmmmmmmmmmmmmm" "mmmmmmmmmmmmmmmm" "mmmmmmmmmmmmmmmm";
_Static_assert(sizeof mx_map0 == 257 && sizeof mx_map1 == 257, "sixteen rows of sixteen");

/* Decodes the ModRM at code[at] and whatever SIB and displacement follow it
 * into *o; returns the offset just past them, or -1 past `avail`. */
static int mx_modrm(const uint8_t *code, size_t avail, int at, mx_insn *o) {
    if ((size_t)at >= avail) return -1;
    int mod = code[at] >> 6, rm = code[at] & 7, n = at + 1;
    o->modrm = at;
    if (mod == 3) return n;
    if (rm == 4) {
        if ((size_t)n >= avail) return -1;
        if (mod == 0 && (code[n] & 7) == 5) o->displen = 4;
        n++;
    } else if (mod == 0 && rm == 5) {
        o->displen = 4;
    }
    if (mod == 1) o->displen = 1;
    if (mod == 2) o->displen = 4;
    if (o->displen) o->disp = n;
    return n + o->displen;
}

/* The one-byte groups whose ModRM.reg leaves some encodings undefined, or,
 * for F6 /1 and F7 /1, an alias of TEST that neither otool nor LLVM decodes.
 * XOP (8F with a map of 8 or more) always has a nonzero reg field here. */
static int mx_group_ok(uint8_t op, uint8_t modrm) {
    int reg = (modrm >> 3) & 7;
    switch (op) {
    case 0x8F: return reg == 0;
    case 0xF6: case 0xF7: return reg != 1;
    case 0xC6: case 0xC7: return reg == 0 || modrm == 0xF8;
    case 0xFE: return reg < 2;
    case 0xFF: return reg < 7;
    }
    return 1;
}

int mx_decode(const uint8_t *code, size_t avail, mx_insn *out) {
    mx_insn o = { 0, -1, -1, 0, 0 };
    int n = 0, opsize = 0, adsize = 0, rexw = 0;
    for (;; n++) {
        if ((size_t)n >= avail) return 0;
        uint8_t b = code[n];
        if (b == 0x66) opsize = 1;
        else if (b == 0x67) adsize = 1;
        else if (b == 0xF0 || b == 0xF2 || b == 0xF3 || b == 0x2E || b == 0x36 ||
                 b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65) ;
        else if ((b & 0xF0) == 0x40) { rexw = (b & 8) != 0; continue; }
        else break;
        rexw = 0;                    /* a REX counts only just before the opcode */
    }
    uint8_t op = code[n++];
    char c = mx_map0[op];
    int map = 0;
    if (c == 'X') {
        if ((size_t)n + (op == 0xC4 ? 2 : 1) >= avail) return 0;
        map = op == 0xC4 ? code[n] & 0x1F : 1;
        n += op == 0xC4 ? 2 : 1;
        uint8_t vop = code[n++];
        if (map == 1 && vop == 0x77) c = '-';
        else if (map == 1) c = mx_map1[vop] == 'm' || mx_map1[vop] == 'b' ? mx_map1[vop] : 'x';
        else if (map == 2) c = 'm';
        else if (map == 3) c = 'b';
    } else if (c == 'T') {
        if ((size_t)n >= avail) return 0;
        op = code[n++];
        c = mx_map1[op];
        map = 1;
        if (c == 'S' || c == 'U') { n++; c = c == 'S' ? 'm' : 'b'; }
    }
    int immz = opsize ? 2 : 4;
    switch (c) {
    case 'm': case 'b': case 'z': case 'g': case 'G':
        n = mx_modrm(code, avail, n, &o);
        if (n < 0) return 0;
        if (map == 0 && !mx_group_ok(op, code[o.modrm])) return 0;
        if (c == 'b') o.immlen = 1;
        if (c == 'z') o.immlen = immz;
        if (c == 'g' && ((code[o.modrm] >> 3) & 7) == 0) o.immlen = 1;
        if (c == 'G' && ((code[o.modrm] >> 3) & 7) == 0) o.immlen = immz;
        break;
    case '-': break;
    case '1': o.immlen = 1; break;
    case '2': o.immlen = 2; break;
    case '3': o.immlen = 3; break;
    case '4': if (opsize) return 0; o.immlen = 4; break;
    case 'Z': o.immlen = immz; break;
    case 'V': o.immlen = rexw ? 8 : immz; break;
    case 'A': o.disp = n; o.displen = adsize ? 4 : 8; n += o.displen; break;
    default: return 0;
    }
    n += o.immlen;
    if (n > 15 || (size_t)n > avail) return 0;
    o.len = n;
    *out = o;
    return 1;
}
```

- [ ] **Step 5: Register it**

In `CMakeLists.txt:66`, add `src/x86len.c` as the last source of the `add_library(drydockcore STATIC ...)` line, which today ends `src/objc_meth.c src/hdrref.c)`:

```cmake
... src/exports.c src/objc_meth.c src/hdrref.c src/x86len.c)
```

- [ ] **Step 6: Build and run**

Run: build (rebuild check on `$B/x86len_test`), then `"$B/x86len_test"`.
Expected: `x86len_test: all cases pass`, and no line starting `FAIL:`. Then the whole suite (Test command): all pass.

- [ ] **Step 7: Mutation proof** (file `src/x86len.c`; test binary `$B/x86len_test`; each row's case is named by the `what` string the test prints; "crashes" means a read of the unmapped page after the case's bytes, which ends the run with SIGBUS, exit 138)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (mod == 3) return n;` | (delete it) | `mov %rax, %rsp (mod 3, r/m 4: no SIB)` |
| 2 | `        if (mod == 0 && (code[n] & 7) == 5) o->displen = 4;` | (delete it) | `mov abs32, %eax (SIB, no base)` |
| 3 | `    } else if (mod == 0 && rm == 5) {` ⏎ `        o->displen = 4;` ⏎ `    }` | `    }` | `lea hdr(%rip), %rdx` |
| 4 | `    if (mod == 1) o->displen = 1;` | `    if (mod == 1) o->displen = 4;` | `mov 8(%rsp), %eax (SIB, disp8)` |
| 5 | `    if (mod == 2) o->displen = 4;` | (delete it) | `mov disp32(%rax), %eax` |
| 6 | `    if (o->displen) o->disp = n;` | `    o->disp = n;` | `notl (%rax) (F7 /2)` |
| 7 | in `mx_modrm`, `    if ((size_t)at >= avail) return -1;` | (delete it) | `a ModRM cut short` (crashes) |
| 8 | in `mx_modrm`, `        if ((size_t)n >= avail) return -1;` | (delete it) | `a SIB cut short` (crashes) |
| 9 | `    case 0x8F: return reg == 0;` | `    case 0x8F: return 1;` | `8F /1` |
| 10 | `return reg == 0 \|\| modrm == 0xF8;` | `return reg == 0 \|\| reg == 7;` | `C6 /7 with memory` |
| 11 | `return reg == 0 \|\| modrm == 0xF8;` | `return reg < 2 \|\| modrm == 0xF8;` | `C7 /1` |
| 12 | `    case 0xFE: return reg < 2;` | `    case 0xFE: return reg < 3;` | `FE /2` |
| 13 | `    case 0xFF: return reg < 7;` | `    case 0xFF: return 1;` | `FF /7` |
| 14 | in the prefix loop, `        if ((size_t)n >= avail) return 0;` | (delete it) | `a prefix and nothing else` (crashes) |
| 15 | `        rexw = 0;                    /* a REX counts only just before the opcode */` | (delete it) | `a REX before a prefix counts for nothing` |
| 16 | `rexw = (b & 8) != 0;` | `rexw = 1;` | `mov $imm32, %r8d (REX without W)` |
| 17 | `        else if (b == 0x67) adsize = 1;` | `        else if (b == 0x67) adsize = 0;` | `mov moffs32, %eax (67)` |
| 18 | `        if ((size_t)n + (op == 0xC4 ? 2 : 1) >= avail) return 0;` | the same with `> avail` | `a VEX3 prefix cut short`, `a VEX2 prefix cut short` (crashes) |
| 19 | `        n += op == 0xC4 ? 2 : 1;` | `        n += 1;` | `vpshufb (VEX3, 0F 38)` |
| 20 | `        if (map == 1 && vop == 0x77) c = '-';` ⏎ `        else if (map == 1)` | `        if (map == 1)` | `vzeroupper (VEX, no ModRM)` |
| 21 | `c = mx_map1[vop] == 'm' \|\| mx_map1[vop] == 'b' ? mx_map1[vop] : 'x';` | `c = mx_map1[vop];` | `VEX with no ModRM form (0F 05)` |
| 22 | `        else if (map == 2) c = 'm';` | `        else if (map == 2) c = 'b';` | `vpshufb (VEX3, 0F 38)` |
| 23 | `        else if (map == 3) c = 'b';` | `        else if (map == 3) c = 'm';` | `vinsertf128 $1 (VEX3, 0F 3A)` |
| 24 | `        else if (map == 3) c = 'b';` | `        else c = 'b';` | `VEX map 4` |
| 25 | in the 0F branch, `        if ((size_t)n >= avail) return 0;` | (delete it) | `0F and nothing else` (crashes) |
| 26 | `{ n++; c = c == 'S' ? 'm' : 'b'; }` | `{ c = c == 'S' ? 'm' : 'b'; }` | `pshufb (0F 38)` |
| 27 | `c = c == 'S' ? 'm' : 'b';` | `c = c == 'S' ? 'b' : 'm';` | `palignr $8 (0F 3A)` |
| 28 | `        if (map == 0 && !mx_group_ok(op, code[o.modrm])) return 0;` | `        if (!mx_group_ok(op, code[o.modrm])) return 0;` | `paddd %mm1, %mm2 (0F FE, reg 2)` |
| 29 | `    int immz = opsize ? 2 : 4;` | `    int immz = 4;` | `movw $imm16, x(%rip)` |
| 30 | `    case 0xF6: case 0xF7: return reg != 1;` | (delete it) | `F6 /1, an alias of TEST` |
| 31 | `        if (c == 'g' && ((code[o.modrm] >> 3) & 7) == 0) o.immlen = 1;` | the same with `< 3` | `notb (%rax) (F6 /2)` |
| 32 | `        if (c == 'G' && ((code[o.modrm] >> 3) & 7) == 0) o.immlen = immz;` | the same with `< 3` | `notl (%rax) (F7 /2)` |
| 33 | the same line | the same with `!= 0` | `testl $imm32, %eax (F7 /0)` |
| 34 | `    case '4': if (opsize) return 0; o.immlen = 4; break;` | `    case '4': o.immlen = 4; break;` | `66 E8: Intel and AMD disagree on its length` |
| 35 | `    case 'V': o.immlen = rexw ? 8 : immz; break;` | `    case 'V': o.immlen = immz; break;` | `movabs $imm64, %rax` |
| 36 | `o.displen = adsize ? 4 : 8;` | `o.displen = adsize ? 8 : 4;` | `mov moffs64, %eax` |
| 37 | `    if (n > 15 \|\| (size_t)n > avail) return 0;` | `    if ((size_t)n > avail) return 0;` | `sixteen bytes` |
| 38 | the same line | `    if (n > 15) return 0;` | `a disp32 cut short` |
| 39 | `"bzxbmmmmmmmmmmmm"` (row 8x: `83` takes an imm8) | `"bzxmmmmmmmmmmmmm"` | `cmpl $1, x(%rip)` |
| 40 | `"mmmmmmmmmmbmmmmm"` (row Bx of 0F: `0F BA` takes an imm8) | `"mmmmmmmmmmmmmmmm"` | `bt $10, %eax (0F BA)` |
| 41 | `"mmmm1Zxxmmmm1ZxT"` (`06` is not decoded) | `"mmmm1Z-xmmmm1ZxT"` | `push %es (06, not in 64-bit mode)` |
| 42 | `"mmmmx-----x-xm-x"` (`0F 0F` is not decoded) | `"mmmmx-----x-xm-b"` | `3DNow! (0F 0F)` |
| 43 | `"xxxmppppZz1b----"` (`62` is not decoded) | `"xxmmppppZz1b----"` | `EVEX (62)` |
| 44 | `"bb2-XXbz3-2--1x-"` (`C8` takes 3 bytes) | `"bb2-XXbz2-2--1x-"` | `enter $16, $0` |

- [ ] **Step 8: Commit**

```bash
git add src/x86len.h src/x86len.c tests/x86len_test.c CMakeLists.txt
git commit -m "feat(x86len): the length of an x86-64 instruction

A table of one letter per opcode, for the one-byte map, 0F, 0F 38, 0F 3A
and VEX, says whether a ModRM follows and how much immediate; the ModRM
says whether a SIB and a displacement follow. That gives an instruction's
length and where its displacement lies, which is what confirming a
reference to the image's own header needs. EVEX, XOP, 3DNow!, opcodes
invalid in 64-bit mode and a 66-prefixed rel32 branch are not decoded, so
nothing trusts a length for them. Nothing calls it yet.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 2: The decoder against `otool`, over 10.9's own images

**Files:**
- Create: `tests/x86len_oracle.c`, `tests/x86len_oracle_test.sh`
- Modify: `CMakeLists.txt`, after Task 1's `add_test(NAME x86len_test COMMAND x86len_test)`

**Interfaces:**
- Consumes: `mx_decode` (Task 1); `mi_open`, `mi_each_lc`, `mi_image_base` (`src/image.h`); `mu_decode` (`src/uleb.h`).
- Produces: the ctest `x86len_oracle_test` (SKIP code 77) and the helper `x86len_oracle` (`otool -tv FILE | x86len_oracle FILE`). Nothing in `src/` depends on them.

**Plan decisions.** `otool -tv` rather than the spec's `-tV`: the instructions are the same, and `-tV`'s symbolizer breaks lines with diagnostics on some images. The comparison joins `otool`'s prefix-only lines (`lock`, `rep`, `repne`, `data16`, segment overrides) to the instruction after them; compares a function only when `otool` has a line at its start (else its sweep is out of step, after padding); and stops a function at bytes either side cannot decode, which is how the inline jump tables of 10.9 code end each comparison. The 10.9 toolchain writes no `LC_DATA_IN_CODE` entries, so the oracle has none to skip. The corpus is twelve fixed images, so the test is quick (3 s) and repeatable; it SKIPs, saying which, if any is absent, which is how it stays out of CI. Two positive controls show the comparison can fail: with one `otool` line gone it must report a mismatch, and with none it must refuse to pass.

- [ ] **Step 1: Write the oracle**

Create `tests/x86len_oracle.c`:

```c
/*
 * x86len_oracle.c -- src/x86len.h's instruction boundaries against otool's,
 * over every function of a real image.
 *
 *   otool -tv FILE | x86len_oracle FILE
 *
 * FILE is a thin x86_64 image. otool disassembles __TEXT,__text in one sweep
 * from its start; for each function LC_FUNCTION_STARTS names there, the
 * decoder sweeps from the function's start to the next function's, and each
 * instruction must end where otool's next one starts. otool is out of step at
 * a function whose start it has no line for (padding before it ended
 * mid-instruction): that function is not compared. A function's comparison
 * stops at bytes either side cannot decode, such as a jump table. The 10.9
 * toolchain writes no LC_DATA_IN_CODE entries, so there are none to skip.
 *
 * Prints one summary line, and one line per mismatch (the first ten); exits 1
 * on a mismatch or when no instruction was compared, 2 on bad input.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "image.h"
#include "uleb.h"
#include "x86len.h"

struct line { uint64_t addr; int bad; };
static struct line *lines;
static size_t nlines, caplines;

/* otool prints these prefixes as instructions of their own, at the prefix's
 * address; the instruction they prefix follows, on the next line. */
static int is_prefix(const char *m) {
    static const char *const p[] = { "lock", "rep", "repne", "data16", "cs", "ds", "es",
                                     "fs", "gs", "ss", "xacquire", "xrelease", NULL };
    for (int i = 0; p[i]; i++) if (strcmp(m, p[i]) == 0) return 1;
    return 0;
}

/* Every "ADDRESS<tab>MNEMONIC ..." line, a prefix's line joined to the next. */
static void read_otool(FILE *f) {
    char buf[4096];
    int joining = 0;
    while (fgets(buf, sizeof buf, f)) {
        char *end, m[32];
        uint64_t a = strtoull(buf, &end, 16);
        if (end == buf || *end != '\t' || sscanf(end, "%31s", m) != 1) continue;
        int bad = strcmp(m, ".byte") == 0;
        if (joining) { lines[nlines - 1].bad = bad; joining = is_prefix(m); continue; }
        joining = is_prefix(m);
        if (nlines == caplines) {
            caplines = caplines ? 2 * caplines : 1 << 16;
            lines = (struct line *)realloc(lines, caplines * sizeof *lines);
            if (!lines) { fprintf(stderr, "x86len_oracle: out of memory\n"); exit(2); }
        }
        lines[nlines].addr = a;
        lines[nlines++].bad = bad;
    }
}

static size_t line_at(uint64_t a) {           /* the first line at or after a */
    size_t lo = 0, hi = nlines;
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (lines[mid].addr < a) lo = mid + 1; else hi = mid; }
    return lo;
}

struct find { const struct linkedit_data_command *fs; const struct section_64 *text; };
static int find_cb(const struct load_command *lc, void *ctx_) {
    struct find *c = (struct find *)ctx_;
    if (lc->cmd == LC_FUNCTION_STARTS) c->fs = (const struct linkedit_data_command *)lc;
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *s = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++)
            if (strncmp(s[j].segname, "__TEXT", 16) == 0 && strncmp(s[j].sectname, "__text", 16) == 0)
                c->text = &s[j];
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: otool -tv FILE | x86len_oracle FILE\n"); return 2; }
    mi_image im;
    uint64_t base;
    struct find f = { NULL, NULL };
    if (mi_open(argv[1], &im) != 0 || mi_image_base(&im, &base) != 0) {
        fprintf(stderr, "x86len_oracle: %s: not an image this can read\n", argv[1]);
        return 2;
    }
    mi_each_lc(&im, find_cb, &f);
    if (!f.text || !f.fs || (uint64_t)f.text->offset + f.text->size > im.size ||
        (uint64_t)f.fs->dataoff + f.fs->datasize > im.size) {
        fprintf(stderr, "x86len_oracle: %s: no __text and LC_FUNCTION_STARTS to compare\n", argv[1]);
        return 2;
    }
    read_otool(stdin);

    uint64_t lo = f.text->addr, hi = f.text->addr + f.text->size;
    const uint8_t *code = im.buf + f.text->offset;
    uint64_t *starts = (uint64_t *)malloc((f.fs->datasize + 1) * sizeof *starts);
    if (!starts) { fprintf(stderr, "x86len_oracle: out of memory\n"); return 2; }
    size_t nstarts = 0;
    const uint8_t *p = im.buf + f.fs->dataoff, *pe = p + f.fs->datasize;
    for (uint64_t a = base, d; p < pe; ) {
        int c = mu_decode(p, pe, &d);
        if (c == 0 || d == 0) break;
        p += c; a += d;
        if (a >= lo && a < hi) starts[nstarts++] = a;
    }

    unsigned long compared = 0, insns = 0, out_of_step = 0, stopped = 0, bad = 0;
    for (size_t i = 0; i < nstarts; i++) {
        uint64_t s = starts[i], e = i + 1 < nstarts ? starts[i + 1] : hi;
        size_t j = line_at(s);
        if (j == nlines || lines[j].addr != s) { out_of_step++; continue; }
        compared++;
        for (uint64_t pc = s; pc < e; ) {
            mx_insn in;
            j = line_at(pc);
            if (lines[j].bad || !mx_decode(code + (pc - lo), (size_t)(hi - pc), &in)) { stopped++; break; }
            insns++;
            uint64_t next = pc + (uint64_t)in.len;
            if (next < e && (j + 1 == nlines || lines[j + 1].addr != next)) {
                if (bad++ < 10) {
                    printf("MISMATCH at %#llx: the decoder says %d bytes, otool %lld:",
                           (unsigned long long)pc, in.len,
                           j + 1 < nlines ? (long long)(lines[j + 1].addr - pc) : -1LL);
                    for (uint64_t b = pc; b < pc + 15 && b < hi; b++) printf(" %02x", code[b - lo]);
                    printf("\n");
                }
                break;
            }
            pc = next;
        }
    }
    printf("x86len_oracle: %s: %lu of %zu functions compared, %lu instructions, %lu mismatches "
           "(%lu out of step with otool at their start; %lu stopped at bytes either cannot "
           "decode)\n", argv[1], compared, nstarts, insns, bad, out_of_step, stopped);
    return bad || insns == 0;
}
```

Create `tests/x86len_oracle_test.sh`:

```sh
#!/bin/sh
# tests/x86len_oracle_test.sh -- src/x86len.h's instruction boundaries must
# be otool's, over every function of a corpus of real 10.9 images.
#
#   sh tests/x86len_oracle_test.sh <bindir>
#
# The corpus covers C, C++ and Objective-C, SSE through AVX2, FMA and AES-NI.
# Local only: it SKIPs, saying why, where otool or a corpus image is absent;
# CI's macos-26 runner keeps its libraries in the shared cache.
set -u

BIN="${1:?usage: x86len_oracle_test.sh <bindir>}"
ORACLE="$BIN/x86len_oracle"
[ -x "$ORACLE" ] || { echo "x86len_oracle_test: $ORACLE not found or not executable" >&2; exit 1; }

command -v otool >/dev/null 2>&1 || { echo "SKIP: no otool here"; exit 77; }
command -v lipo >/dev/null 2>&1 || { echo "SKIP: no lipo here"; exit 77; }
AF=/System/Library/Frameworks/Accelerate.framework/Versions/A/Frameworks
CORPUS="/usr/lib/system/libsystem_c.dylib /usr/lib/system/libsystem_m.dylib
/usr/lib/system/libsystem_platform.dylib /usr/lib/system/libcorecrypto.dylib
/usr/lib/libobjc.A.dylib /usr/lib/libc++.1.dylib
$AF/vImage.framework/Versions/A/vImage $AF/vecLib.framework/Versions/A/libBLAS.dylib
$AF/vecLib.framework/Versions/A/libvDSP.dylib $AF/vecLib.framework/Versions/A/libvMisc.dylib
/usr/bin/groff /bin/ls"
for f in $CORPUS; do
    [ -f "$f" ] || { echo "SKIP: $f is absent; the corpus is 10.9's own images"; exit 77; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/x86len-oracle.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
for f in $CORPUS; do
    thin="$T/$(basename "$f")"
    lipo "$f" -thin x86_64 -output "$thin" 2>/dev/null || cp "$f" "$thin"
    rc=0; otool -tv "$thin" | "$ORACLE" "$thin" >"$T/out" || rc=$?
    sed "s|$thin|$f|" "$T/out"
    [ "$rc" -eq 0 ] || fail=$((fail + 1))
done

# The positive controls: with one of otool's lines gone, or all of them, the
# comparison fails.
thin="$T/libsystem_m.dylib"
rc=0; otool -tv "$thin" | awk 'NR != 10' | "$ORACLE" "$thin" >"$T/out" || rc=$?
if [ "$rc" -eq 1 ] && grep -q '^MISMATCH' "$T/out"; then
    echo "PASS the positive control: a boundary otool does not have is a mismatch"
else
    echo "FAIL the positive control: with otool's tenth line gone, the oracle said (exit $rc):"
    cat "$T/out"
    fail=$((fail + 1))
fi

rc=0; : | "$ORACLE" "$thin" >"$T/out" || rc=$?
if [ "$rc" -eq 1 ] && grep -q ' 0 instructions' "$T/out"; then
    echo "PASS the positive control: comparing nothing is a failure"
else
    echo "FAIL the positive control: with no otool output, the oracle said (exit $rc): $(cat "$T/out")"
    fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] || { echo "x86len_oracle_test: $fail failure(s)"; exit 1; }
echo "x86len_oracle_test: all passed"
```

In `CMakeLists.txt`, after Task 1's `add_test(NAME x86len_test COMMAND x86len_test)`, the result reading:

```cmake
add_test(NAME x86len_test COMMAND x86len_test)

# The same decoder against 10.9's otool, over every function of a corpus of
# 10.9's own images. Local only: SKIPs (77) where otool or the corpus is absent.
add_executable(x86len_oracle tests/x86len_oracle.c)
target_compile_options(x86len_oracle PRIVATE -O2 -Wall -Wextra)
target_link_libraries(x86len_oracle PRIVATE drydockcore)
add_test(NAME x86len_oracle_test
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/tests/x86len_oracle_test.sh" "$<TARGET_FILE_DIR:x86len_oracle>")
set_tests_properties(x86len_oracle_test PROPERTIES SKIP_RETURN_CODE 77)
```

- [ ] **Step 2: Run it against a broken decoder, to see it fail**

Save `src/x86len.c` (`M=$(mktemp -d "${TMPDIR:-/tmp}/m1-mut.XXXXXX") && cp src/x86len.c "$M/"`), and in its `mx_map1` table replace the row `"mmmmmmmmmmbmmmmm"` with `"mmmmmmmmmmmmmmmm"` (`0F BA`, `bt $imm8`, loses its immediate). Build (rebuild check on `$B/x86len_oracle`).

Run: `sh tests/x86len_oracle_test.sh "$B"`
Expected: exit 1, `x86len_oracle_test: 2 failure(s)`, with mismatches in `libsystem_c` and `libsystem_m` such as:

```
MISMATCH at 0x2c0e6: the decoder says 4 bytes, otool 5: 48 0f ba e0 26 72 7d 48 83 f8 2a 75 18 80 4b
MISMATCH at 0x5828: the decoder says 4 bytes, otool 5: 66 0f ba e0 0a 72 f5 dd d9 d9 5c 24 fc f3 0f
```

Restore: `cp "$M/x86len.c" src/x86len.c && cmp src/x86len.c "$M/x86len.c"`, and rebuild.

- [ ] **Step 3: Run it to see it pass**

Run: `sh tests/x86len_oracle_test.sh "$B"`, then the whole suite (Test command).
Expected: one line per image, each ending `0 mismatches (...)`, 1,511,420 instructions in all; `PASS the positive control: a boundary otool does not have is a mismatch`; `PASS the positive control: comparing nothing is a failure`; `x86len_oracle_test: all passed`. For example:

```
x86len_oracle: /usr/lib/system/libsystem_c.dylib: 1594 of 1656 functions compared, 126463 instructions, 0 mismatches (62 out of step with otool at their start; 50 stopped at bytes either cannot decode)
x86len_oracle: /System/Library/Frameworks/Accelerate.framework/Versions/A/Frameworks/vImage.framework/Versions/A/vImage: 2671 of 2738 functions compared, 509559 instructions, 0 mismatches (67 out of step with otool at their start; 101 stopped at bytes either cannot decode)
```

- [ ] **Step 4: Mutation proof** (run: `sh tests/x86len_oracle_test.sh "$B"`, rebuilding `$B/x86len_oracle`)

| # | file | replace | with | must fail |
|---|---|---|---|---|
| 1 | `src/x86len.c` | `"mmmmmmmmmmbmmmmm"` | `"mmmmmmmmmmmmmmmm"` | `MISMATCH` in `libsystem_c`, `libsystem_m` |
| 2 | `src/x86len.c` | `        else if (map == 3) c = 'b';` | `        else if (map == 3) c = 'm';` | `MISMATCH` in `libsystem_m` and the four Accelerate images |
| 3 | `src/x86len.c` | `    if (mod == 1) o->displen = 1;` | `    if (mod == 1) o->displen = 4;` | `MISMATCH` in every image |
| 4 | `tests/x86len_oracle.c` | `"lock", "rep", "repne"` | `"lock", "repne"` | `MISMATCH` in `libsystem_c`, `libsystem_platform` and `libc++` |
| 5 | `tests/x86len_oracle.c` | `        if (joining) { lines[nlines - 1].bad = bad; joining = is_prefix(m); continue; }` | (delete it) | `MISMATCH` (every prefix `otool` splits off) |
| 6 | `tests/x86len_oracle.c` | `if (j == nlines \|\| lines[j].addr != s) { out_of_step++; continue; }` | `if (j == nlines) { out_of_step++; continue; }` | `MISMATCH` (functions `otool` is out of step at) |
| 7 | `tests/x86len_oracle.c` | `            if (lines[j].bad \|\| !mx_decode` | `            if (!mx_decode` | `MISMATCH` (bytes `otool` cannot decode) |
| 8 | `tests/x86len_oracle.c` | `            if (next < e && (j + 1 == nlines` | `            if (0 && next < e && (j + 1 == nlines` | `FAIL the positive control: with otool's tenth line gone` |
| 9 | `tests/x86len_oracle.c` | `    return bad \|\| insns == 0;` | `    return bad != 0;` | `FAIL the positive control: with no otool output` |

- [ ] **Step 5: Commit**

```bash
git add tests/x86len_oracle.c tests/x86len_oracle_test.sh CMakeLists.txt
git commit -m "test(x86len): the decoder's boundaries are otool's on 10.9's own images

Over every function of twelve 10.9 images (C, C++, Objective-C, SSE
through AVX2, FMA and AES-NI; 1.5 million instructions), each instruction
the decoder finds ends where otool's next one starts. The comparison
joins the prefixes otool prints on lines of their own, skips a function
otool's sweep is out of step at, and stops at bytes either cannot decode,
such as 10.9's inline jump tables. Local only: it skips where otool or the
images are absent, as on CI.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 3: Confirm each candidate by decoding its function (`mhr_confirm`)

**Files:**
- Modify: `src/hdrref.h:41` (after `int64_t mhr_scan(...);`)
- Modify: `src/hdrref.c:2-6` (the includes), `:40-42` (the end of `struct mhr_ctx`), `:52` (`mhr_seg_cb`'s bounds check), `:60-66` (`mhr_scan`)
- Test: `tests/grow_test.c` (new tests before `int main(void) {` at `:2328`; calls after `test_grow_leaves_an_empty_function_starts_list_alone();` at `:2393`)

**Interfaces:**
- Consumes: `mx_decode`, `mx_insn` (Task 1); `mhr_cand`, `mhr_scan` (M0); `mu_decode`; `mi_wrap`, `mi_each_lc`, `mi_image_base`; the test helpers `build_code_image`, `hr_plant`, `HR_BASE`, `HR_CODE`, `HR_FOFF`, `HR_IMG_SIZE` (M0, `tests/grow_test.c:1889-2037`).
- Produces (Task 4 calls it; M2 will):
  - `#define MHR_CONFIRMED 0`, `MHR_UNSCANNABLE 1`, `MHR_NO_STARTS 2`, `MHR_UNCONFIRMED 3`.
  - `int mhr_confirm(const uint8_t *buf, size_t fsize, mhr_cand *bad);` → an `MHR_` answer, with `*bad` set to the first candidate `MHR_NO_STARTS` or `MHR_UNCONFIRMED` is about; -1 if `buf` does not wrap, no segment maps the header, or memory runs out.
  - Test helpers: `hr_add_lc`, `struct hr_code`, `hr_confirm`, `hr_push_lea`, `HR_ONE_FUNCTION`.

**Plan decisions.** Confirmation belongs beside the scan it confirms, in `src/hdrref.[ch]`; M2's raise needs it unchanged, and `mhr_`'s interface only grows. It confirms references to the image's own base, which is what both routes repair. It reads the first `LC_FUNCTION_STARTS` and the first `LC_DATA_IN_CODE`, as `mg_grow_header` and `mg_dice_walk` do, and ignores one whose payload runs past the file, which leaves its candidates unconfirmed. A candidate's function is the last start at or below it, and must lie in the candidate's own section; the scan's walk now tells its callback which section it is in (`mhr_walk`), so nothing looks the section up twice. The walk goes on past an instruction section that runs past the file and answers -1 (`15939c7`); `mhr_confirm` answers `MHR_UNSCANNABLE` for that -1 whatever it confirmed, and also when it stopped at an unconfirmed candidate after such a section: either way the grow refuses. The sweep steps over data-in-code ranges in address order (sorted, since nothing guarantees the order), and stops at the first byte the decoder refuses. It confirms only an instruction whose ModRM is RIP-relative, whose disp32 is the candidate's, and whose length makes the target exactly the base: the scan's immediate length is a guess, and the decoder's is not.

- [ ] **Step 1: Write the failing tests**

Insert in `tests/grow_test.c`, before `int main(void) {` (`:2328`):

```c
/* ---- confirming a candidate (mhr_confirm) ----
 * build_code_image's __text holds `code` from its first byte (vm HR_CODE,
 * file HR_FOFF), with LC_FUNCTION_STARTS and LC_DATA_IN_CODE payloads, when
 * given, at file offsets 0x1c00 and 0x1d00. A lea's disp32 is planted with
 * hr_plant, so each case states only where its operand sits. */
static const uint8_t HR_ONE_FUNCTION[] = { 0x80, 0x20, 0x00 };    /* base + 0x1000: __text */

static void hr_add_lc(uint8_t *buf, uint32_t cmd, uint32_t at, const void *data, uint32_t n) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct linkedit_data_command *l =
        (struct linkedit_data_command *)(buf + sizeof *h + h->sizeofcmds);
    l->cmd = cmd;
    l->cmdsize = sizeof *l;
    l->dataoff = at;
    l->datasize = n;
    memcpy(buf + at, data, n);
    h->ncmds++;
    h->sizeofcmds += l->cmdsize;
}

struct hr_code {
    uint8_t b[32];
    uint32_t n;              /* bytes of code, at __text's start */
    const uint8_t *fs;       /* LC_FUNCTION_STARTS payload, or NULL for none */
    uint32_t nfs;
    const uint8_t *dic;      /* LC_DATA_IN_CODE payload, or NULL for none */
    uint32_t ndic;
};

static int hr_confirm(const struct hr_code *k, mhr_cand *bad) {
    uint8_t *buf = build_code_image();
    memcpy(buf + HR_FOFF, k->b, k->n);
    if (k->fs) hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, k->fs, k->nfs);
    if (k->dic) hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, k->dic, k->ndic);
    int r = mhr_confirm(buf, HR_IMG_SIZE, bad);
    free(buf);
    return r;
}

/* push %rbp; lea base(%rip), %rax: the disp32 is at HR_CODE + 4. */
static struct hr_code hr_push_lea(void) {
    struct hr_code k = { { 0x55, 0x48, 0x8d }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(k.b, HR_CODE, 3, 0x05, 0, HR_BASE);
    return k;
}

static void test_confirm_a_lea_of_the_header(void) {
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: push; lea base(%%rip) is an instruction (got %d)", r);
}

/* cmpl $1, base(%rip): the operand is followed by an imm8. */
static void test_confirm_an_operand_with_an_immediate(void) {
    struct hr_code k = { { 0x55, 0x83 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 2, 0x3d, 1, HR_BASE);
    k.b[7] = 0x01;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: cmpl $1, base(%%rip) is an instruction (got %d)", r);
}

/* The scan counts `05 disp32` inside mov $imm32, %eax's immediate; the sweep
 * finds the mov, which is not RIP-relative. */
static void test_confirm_rejects_a_lookalike_inside_an_immediate(void) {
    struct hr_code k = { { 0x55, 0xb8 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 2, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED && bad.addr == HR_CODE + 3 && bad.off == HR_FOFF + 3,
          "confirm: a lookalike in an immediate is unconfirmed, at its disp32 (got %d, %#llx)",
          r, (unsigned long long)bad.addr);
}

/* mov abs32, %eax is 8b 04 25 disp32: its SIB byte, 0x25, looks like a
 * RIP-relative ModRM to the scan, and the disp32 is where the scan says. */
static void test_confirm_rejects_an_absolute_address_that_looks_rip_relative(void) {
    struct hr_code k = { { 0x55, 0x8b, 0x04 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 3, 0x25, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: a SIB byte is not a RIP-relative ModRM (got %d)", r);
}

/* movl $imm32, x(%rip) is c7 05 disp32 imm32. Its first disp32 ends in 0x05,
 * so the scan sees a second operand whose disp32 is the imm32: inside a
 * RIP-relative instruction, but not its displacement. */
static void test_confirm_rejects_a_lookalike_inside_a_rip_relative_instruction(void) {
    struct hr_code k = { { 0x55, 0xc7, 0x05, 0x10, 0x00, 0x00 }, 11, HR_ONE_FUNCTION,
                         sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 6, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED && bad.addr == HR_CODE + 7,
          "confirm: an immediate after a real disp32 is not the operand (got %d, %#llx)",
          r, (unsigned long long)bad.addr);
}

/* cmpl $1, x(%rip) whose disp32 would name the base with no immediate: with
 * its imm8, it names the byte after the base. */
static void test_confirm_rejects_an_operand_whose_immediate_moves_its_target(void) {
    struct hr_code k = { { 0x55, 0x83 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 2, 0x3d, 0, HR_BASE);
    k.b[7] = 0x01;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: an operand that names base + 1 is unconfirmed (got %d)", r);
}

/* Two leas and no LC_FUNCTION_STARTS: the first is the one reported. */
static void test_confirm_needs_function_starts(void) {
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = NULL;
    k.b[8] = 0x48; k.b[9] = 0x8d;
    hr_plant(k.b, HR_CODE, 10, 0x05, 0, HR_BASE);
    k.n = 15;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_NO_STARTS && bad.addr == HR_CODE + 4,
          "confirm: no LC_FUNCTION_STARTS, so nothing to decode from (got %d, %#llx)",
          r, (unsigned long long)bad.addr);
}

/* A function-starts payload that runs past the file is not read: one that
 * starts inside it and ends past it, and one longer than the file. Either
 * would name __text's start. */
static void test_confirm_ignores_function_starts_past_the_image(void) {
    static const uint32_t at[2] = { HR_IMG_SIZE - 2, 0x1c00 }, size[2] = { 4, 0x10000 };
    for (int i = 0; i < 2; i++) {
        uint8_t *buf = build_code_image();
        struct hr_code k = hr_push_lea();
        mhr_cand bad = { 0, 0, 0 };
        memcpy(buf + HR_FOFF, k.b, k.n);
        hr_add_lc(buf, LC_FUNCTION_STARTS, at[i], HR_ONE_FUNCTION, 2);
        ((struct linkedit_data_command *)(buf + sizeof(struct mach_header_64) +
            sizeof(struct segment_command_64) + 3 * sizeof(struct section_64)))->datasize = size[i];
        int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
        CHECK(r == MHR_NO_STARTS, "confirm: function starts at %#x, %#x bytes, past the image, "
              "are ignored (got %d)", at[i], size[i], r);
        free(buf);
    }
}

/* A 0 delta ends the list; what follows it names no function. Read as one,
 * the 3 here would start a function inside the lea. */
static void test_confirm_stops_at_the_function_starts_terminator(void) {
    static const uint8_t fs[] = { 0x80, 0x20, 0x00, 0x03 };
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = fs; k.nfs = sizeof fs;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: nothing after the terminator is a function (got %d)", r);
}

/* The first LC_FUNCTION_STARTS and the first LC_DATA_IN_CODE count, as in
 * src/grow.c. The second of each would make the lea unconfirmable. */
static void test_confirm_reads_the_first_of_each_command(void) {
    static const uint8_t late[] = { 0x90, 0x20, 0x00 };                          /* base + 0x1010 */
    static const uint8_t elsewhere[] = { 0x20, 0x10, 0, 0, 0x04, 0x00, 0x01, 0x00 };   /* +0x20 */
    static const uint8_t over_lea[] = { 0x01, 0x10, 0, 0, 0x07, 0x00, 0x01, 0x00 };    /* +1 */
    uint8_t *buf = build_code_image();
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    memcpy(buf + HR_FOFF, k.b, k.n);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c10, late, sizeof late);
    hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, elsewhere, sizeof elsewhere);
    hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d10, over_lea, sizeof over_lea);
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: the first of each command counts (got %d)", r);
    free(buf);
}

/* A function starts after the candidate, or in another section. */
static void test_confirm_needs_a_function_in_the_candidates_section(void) {
    static const uint8_t late[] = { 0x90, 0x20, 0x00 };      /* base + 0x1010 */
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = late; k.nfs = sizeof late;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: no function starts at or before it (got %d)", r);

    uint8_t *buf = build_code_image();
    uint8_t *stubs = buf + 0x1400;
    stubs[0] = 0x48; stubs[1] = 0x8d;
    hr_plant(stubs, HR_BASE + 0x1400, 2, 0x05, 0, HR_BASE);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION);
    r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_UNCONFIRMED && bad.addr == HR_BASE + 0x1403,
          "confirm: __stubs' lea has no function of its own (__text's is not it) (got %d, %#llx)",
          r, (unsigned long long)bad.addr);
    free(buf);
}

/* push; six bytes of data (ff ff: FF /7, no instruction); lea. */
static void test_confirm_steps_over_data_in_code(void) {
    static const uint8_t data[] = { 0x01, 0x10, 0, 0, 0x06, 0x00, 0x01, 0x00 };   /* +1, 6 bytes */
    struct hr_code k = { { 0x55, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x48, 0x8d }, 14,
                         HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, data, sizeof data };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 9, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: a lea after a data-in-code range (got %d)", r);
    k.dic = NULL;
    r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: the same bytes, with no range to step over (got %d)", r);
}

/* Two ranges, listed last first: push; data; nop; data; lea. */
static void test_confirm_orders_data_in_code(void) {
    static const uint8_t data[] = { 0x04, 0x10, 0, 0, 0x02, 0x00, 0x01, 0x00,
                                    0x01, 0x10, 0, 0, 0x02, 0x00, 0x01, 0x00 };
    struct hr_code k = { { 0x55, 0xff, 0xff, 0x90, 0xff, 0xff, 0x48, 0x8d }, 13,
                         HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, data, sizeof data };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 8, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: two data-in-code ranges, listed out of order (got %d)", r);
}

static void test_confirm_rejects_a_candidate_inside_data_in_code(void) {
    static const uint8_t data[] = { 0x01, 0x10, 0, 0, 0x07, 0x00, 0x01, 0x00 };   /* +1, 7 bytes */
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.dic = data; k.ndic = sizeof data;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: a lea inside a data-in-code range (got %d)", r);
}

/* 62 opens an EVEX instruction, which the decoder does not decode, so the
 * sweep stops there: it never reads on to the lea, four nops later. */
static void test_confirm_rejects_what_the_decoder_cannot_decode(void) {
    struct hr_code k = { { 0x55, 0x62, 0x90, 0x90, 0x90, 0x48, 0x8d }, 12,
                         HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 7, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: EVEX before the lea (got %d)", r);
}

static void test_confirm_reports_an_image_it_cannot_scan(void) {
    uint8_t *buf = build_code_image();
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    mhr_cand bad = { 0, 0, 0 };
    sc[1].size = HR_IMG_SIZE;                          /* __stubs runs past the image */
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_UNSCANNABLE, "confirm: an instruction section past the image (got %d)", r);
    free(buf);
}

/* Any instruction section past the file makes the image unscannable, even
 * when every candidate the scan can still read is confirmed: the scan goes on
 * past a bad section but answers -1. Here __text runs past the image, and
 * __stubs holds a lea at a function start of its own. */
static void test_confirm_reports_a_bad_section_before_a_good_one(void) {
    static const uint8_t stubs_fn[] = { 0x80, 0x28, 0x00 };   /* base + 0x1400: __stubs */
    uint8_t *buf = build_code_image();
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    mhr_cand bad = { 0, 0, 0 };
    buf[0x1400] = 0x48; buf[0x1401] = 0x8d;
    hr_plant(buf + 0x1400, HR_BASE + 0x1400, 2, 0x05, 0, HR_BASE);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, stubs_fn, sizeof stubs_fn);
    sc[0].size = HR_IMG_SIZE;                          /* __text: 0x1000 + 0x2000 > 0x2000 */
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_UNSCANNABLE, "confirm: a bad __text before a good __stubs (got %d)", r);
    sc[0].size = 0x100;
    r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: with __text readable, __stubs' lea confirms (got %d)", r);
    free(buf);
}
```

And after `    test_grow_leaves_an_empty_function_starts_list_alone();` (`:2393`), inside `main`:

```c
    test_confirm_a_lea_of_the_header();
    test_confirm_an_operand_with_an_immediate();
    test_confirm_rejects_a_lookalike_inside_an_immediate();
    test_confirm_rejects_an_absolute_address_that_looks_rip_relative();
    test_confirm_rejects_a_lookalike_inside_a_rip_relative_instruction();
    test_confirm_rejects_an_operand_whose_immediate_moves_its_target();
    test_confirm_needs_function_starts();
    test_confirm_ignores_function_starts_past_the_image();
    test_confirm_stops_at_the_function_starts_terminator();
    test_confirm_reads_the_first_of_each_command();
    test_confirm_needs_a_function_in_the_candidates_section();
    test_confirm_steps_over_data_in_code();
    test_confirm_orders_data_in_code();
    test_confirm_rejects_a_candidate_inside_data_in_code();
    test_confirm_rejects_what_the_decoder_cannot_decode();
    test_confirm_reports_an_image_it_cannot_scan();
    test_confirm_reports_a_bad_section_before_a_good_one();
```

- [ ] **Step 2: Run it to see it fail**

Run: build.
Expected: the build fails, starting `tests/grow_test.c:2378:16: error: use of undeclared identifier 'MHR_CONFIRMED'`; clang stops after 20 such errors (`too many errors emitted`).

- [ ] **Step 3: Declare `mhr_confirm`**

In `src/hdrref.h`, replace `int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx);` (`:41`) with:

```c
int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx);

/* mhr_confirm's answers. */
#define MHR_CONFIRMED   0  /* every candidate is an instruction, or there is none */
#define MHR_UNSCANNABLE 1  /* an instruction section lies past the end of the image */
#define MHR_NO_STARTS   2  /* a candidate, and no LC_FUNCTION_STARTS to decode it from */
#define MHR_UNCONFIRMED 3  /* a candidate that decoding its function does not confirm */

/* Whether every candidate mhr_scan finds for the image's own base is an
 * instruction that addresses it. A candidate's function is the last
 * LC_FUNCTION_STARTS entry at or below it, in its own section. Decoding from
 * there (src/x86len.h), stepping over LC_DATA_IN_CODE ranges, must reach an
 * instruction whose RIP-relative disp32 is the candidate's and whose target
 * is the base. Returns an MHR_ answer, with *bad set to the candidate
 * MHR_NO_STARTS or MHR_UNCONFIRMED is about; or -1 if `buf` does not wrap,
 * no segment maps the header, or memory runs out. */
int mhr_confirm(const uint8_t *buf, size_t fsize, mhr_cand *bad);
```

- [ ] **Step 4: Let the scan's walk name its section**

In `src/hdrref.c`, replace the includes (`:2-6`):

```c
#include <string.h>
#include <mach-o/loader.h>

#include "hdrref.h"
#include "image.h"
```

with:

```c
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "hdrref.h"
#include "image.h"
#include "uleb.h"
#include "x86len.h"
```

Replace the end of `struct mhr_ctx` (`:40-42`):

```c
    uint64_t n;
    int stopped, bad;
};
```

with:

```c
    uint64_t n;
    int stopped, bad;
    const struct section_64 **sect;   /* if not NULL, the section being scanned */
};
```

In `mhr_seg_cb`, replace the bounds check (`:52`):

```c
        if (s[j].size > c->fsize || s[j].offset > c->fsize - s[j].size) { c->bad = 1; continue; }
```

with:

```c
        if (s[j].size > c->fsize || s[j].offset > c->fsize - s[j].size) { c->bad = 1; continue; }
        if (c->sect) *c->sect = &s[j];
```

Replace `mhr_scan` (`:60-66`):

```c
int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0) return -1;
    struct mhr_ctx c = { buf, fsize, target, fn, ctx, 0, 0, 0 };
    mi_each_lc(&im, mhr_seg_cb, &c);
    return c.bad ? -1 : (int64_t)c.n;
}
```

with:

```c
static int64_t mhr_walk(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx,
                        const struct section_64 **sect) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0) return -1;
    struct mhr_ctx c = { buf, fsize, target, fn, ctx, 0, 0, 0, sect };
    mi_each_lc(&im, mhr_seg_cb, &c);
    return c.bad ? -1 : (int64_t)c.n;
}

int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx) {
    return mhr_walk(buf, fsize, target, fn, ctx, NULL);
}
```

- [ ] **Step 5: Write `mhr_confirm`**

Append to `src/hdrref.c`, after `mhr_scan`:

```c
struct mhr_range { uint64_t from, to; };

/* What a sweep needs, read once: LC_FUNCTION_STARTS as addresses, and
 * LC_DATA_IN_CODE as ranges in address order. */
struct mhr_map {
    const uint8_t *buf;
    uint64_t base;
    uint64_t *starts;
    size_t nstarts;
    struct mhr_range *dic;
    size_t ndic;
};

/* The first of each command counts, as in src/grow.c. */
struct mhr_lcs { const struct linkedit_data_command *fs, *dic; };
static int mhr_lcs_cb(const struct load_command *lc, void *ctx_) {
    struct mhr_lcs *l = (struct mhr_lcs *)ctx_;
    if (lc->cmd == LC_FUNCTION_STARTS && !l->fs) l->fs = (const struct linkedit_data_command *)lc;
    if (lc->cmd == LC_DATA_IN_CODE && !l->dic) l->dic = (const struct linkedit_data_command *)lc;
    return 0;
}

/* How many bytes of `d`'s payload to read: none if it runs past the file. */
static uint32_t mhr_payload(const struct linkedit_data_command *d, size_t fsize) {
    if (!d || d->datasize > fsize || d->dataoff > fsize - d->datasize) return 0;
    return d->datasize;
}

static int mhr_by_from(const void *a, const void *b) {
    uint64_t x = ((const struct mhr_range *)a)->from, y = ((const struct mhr_range *)b)->from;
    return x < y ? -1 : x > y;
}

static int mhr_map_read(struct mhr_map *m, const mi_image *im, size_t fsize) {
    struct mhr_lcs l = { NULL, NULL };
    mi_each_lc(im, mhr_lcs_cb, &l);
    uint32_t nfs = mhr_payload(l.fs, fsize), ndic = mhr_payload(l.dic, fsize) / 8;
    m->starts = (uint64_t *)malloc(nfs * sizeof *m->starts + 1);
    m->dic = (struct mhr_range *)malloc(ndic * sizeof *m->dic + 1);
    if (!m->starts || !m->dic) return -1;
    const uint8_t *p = m->buf + (nfs ? l.fs->dataoff : 0), *end = p + nfs;
    uint64_t a = m->base, delta;
    for (int n; p < end && (n = mu_decode(p, end, &delta)) != 0 && delta != 0; p += n)
        m->starts[m->nstarts++] = a += delta;
    for (p = m->buf + (ndic ? l.dic->dataoff : 0); m->ndic < ndic; p += 8) {
        uint32_t off;
        uint16_t len;
        memcpy(&off, p, sizeof off);
        memcpy(&len, p + 4, sizeof len);
        m->dic[m->ndic].from = m->base + off;
        m->dic[m->ndic++].to = m->base + off + len;
    }
    qsort(m->dic, m->ndic, sizeof *m->dic, mhr_by_from);
    return 0;
}

/* Decodes from `pc`, a function start in section `s`, to candidate `c`: 1 if
 * the instruction holding c's disp32 is RIP-relative through it, with the
 * immediate that makes its target c's. */
static int mhr_sweep(const struct mhr_map *m, const struct section_64 *s, uint64_t pc,
                     const mhr_cand *c) {
    const uint8_t *code = m->buf + s->offset;
    uint64_t end = s->addr + s->size;
    size_t k = 0;
    while (pc < c->addr) {
        while (k < m->ndic && m->dic[k].to <= pc) k++;
        if (k < m->ndic && m->dic[k].from <= pc) { pc = m->dic[k].to; continue; }
        mx_insn in;
        if (!mx_decode(code + (pc - s->addr), (size_t)(end - pc), &in)) return 0;
        if (pc + (uint64_t)in.len > c->addr)
            return in.modrm >= 0 && (code[pc - s->addr + (uint64_t)in.modrm] & 0xC7) == 0x05 &&
                   pc + (uint64_t)in.disp == c->addr &&
                   pc + (uint64_t)in.len == c->addr + 4 + (uint64_t)c->immlen;
        pc += (uint64_t)in.len;
    }
    return 0;
}

struct mhr_confirm_ctx {
    const struct mhr_map *m;
    const struct section_64 *sect;
    int status;
    mhr_cand *bad;
};

static int mhr_confirm_cb(const mhr_cand *c, void *ctx_) {
    struct mhr_confirm_ctx *x = (struct mhr_confirm_ctx *)ctx_;
    const struct mhr_map *m = x->m;
    size_t lo = 0, hi = m->nstarts;               /* past the last start at or below c */
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (m->starts[mid] <= c->addr) lo = mid + 1; else hi = mid; }
    if (lo > 0 && m->starts[lo - 1] >= x->sect->addr && mhr_sweep(m, x->sect, m->starts[lo - 1], c))
        return 0;
    x->status = m->nstarts ? MHR_UNCONFIRMED : MHR_NO_STARTS;
    *x->bad = *c;
    return 1;
}

int mhr_confirm(const uint8_t *buf, size_t fsize, mhr_cand *bad) {
    mi_image im;
    struct mhr_map m = { buf, 0, NULL, 0, NULL, 0 };
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0 || mi_image_base(&im, &m.base) != 0) return -1;
    int rc = -1;
    if (mhr_map_read(&m, &im, fsize) == 0) {
        struct mhr_confirm_ctx x = { &m, NULL, MHR_CONFIRMED, bad };
        rc = mhr_walk(buf, fsize, m.base, mhr_confirm_cb, &x, &x.sect) < 0 ? MHR_UNSCANNABLE : x.status;
    }
    free(m.starts);
    free(m.dic);
    return rc;
}
```

- [ ] **Step 6: Run it to see it pass**

Run: build (rebuild check on `$B/grow_test`; `src/hdrref.h` changed, so delete every object), then `"$B/grow_test"`.
Expected: `macho_grow_test: all cases pass`, and no `FAIL:` line. Then the whole suite: all pass (nothing calls `mhr_confirm` yet).

- [ ] **Step 7: Mutation proof** (file `src/hdrref.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `        if (c->sect) *c->sect = &s[j];` | (delete it) | `test_confirm_a_lea_of_the_header`, the first to sweep (SIGSEGV: no section) |
| 2 | `if (lc->cmd == LC_FUNCTION_STARTS && !l->fs)` | `if (lc->cmd == LC_FUNCTION_STARTS)` | `test_confirm_reads_the_first_of_each_command` |
| 3 | `if (lc->cmd == LC_DATA_IN_CODE && !l->dic)` | `if (lc->cmd == LC_DATA_IN_CODE)` | `test_confirm_reads_the_first_of_each_command` |
| 4 | ` \|\| d->dataoff > fsize - d->datasize) return 0;` | `) return 0;` | `test_confirm_ignores_function_starts_past_the_image` |
| 5 | `if (!d \|\| d->datasize > fsize \|\| ` | `if (!d \|\| ` | `test_confirm_ignores_function_starts_past_the_image` (0x10000 bytes) |
| 6 | ` != 0 && delta != 0; p += n)` | ` != 0; p += n)` | `test_confirm_stops_at_the_function_starts_terminator` |
| 7 | `m->dic[m->ndic].from = m->base + off;` and `m->dic[m->ndic++].to = m->base + off + len;` | the same without `m->base + ` | `test_confirm_steps_over_data_in_code` |
| 8 | `    qsort(m->dic, m->ndic, sizeof *m->dic, mhr_by_from);` | (delete it) | `test_confirm_orders_data_in_code` |
| 9 | `if (k < m->ndic && m->dic[k].from <= pc)` | the same with `from < pc` | `test_confirm_steps_over_data_in_code` |
| 10 | `        if (!mx_decode(code + (pc - s->addr), (size_t)(end - pc), &in)) return 0;` | the same ending `{ pc++; continue; }` | `test_confirm_rejects_what_the_decoder_cannot_decode` |
| 11 | `            return in.modrm >= 0 && (code[pc - s->addr + (uint64_t)in.modrm] & 0xC7) == 0x05 &&` | `            return ` | `test_confirm_rejects_an_absolute_address_that_looks_rip_relative` |
| 12 | `                   pc + (uint64_t)in.disp == c->addr &&` | (delete it) | `test_confirm_rejects_a_lookalike_inside_a_rip_relative_instruction` |
| 13 | `                   pc + (uint64_t)in.disp == c->addr &&` ⏎ `                   pc + (uint64_t)in.len == c->addr + 4 + (uint64_t)c->immlen;` | `                   pc + (uint64_t)in.disp == c->addr;` | `test_confirm_rejects_an_operand_whose_immediate_moves_its_target` |
| 14 | `if (lo > 0 && m->starts[lo - 1] >= x->sect->addr && mhr_sweep` | `if (lo > 0 && mhr_sweep` | `test_confirm_needs_a_function_in_the_candidates_section` (`__stubs`' lea, swept from `__text`'s start, is confirmed) |
| 15 | `    x->status = m->nstarts ? MHR_UNCONFIRMED : MHR_NO_STARTS;` | `    x->status = MHR_UNCONFIRMED;` | `test_confirm_needs_function_starts` |
| 16 | `    *x->bad = *c;` | (delete it) | `test_confirm_rejects_a_lookalike_inside_an_immediate` ("at its disp32") |
| 17 | `    *x->bad = *c;` ⏎ `    return 1;` | the same with `return 0;` | `test_confirm_needs_function_starts` (the second lea is reported) |
| 18 | `< 0 ? MHR_UNSCANNABLE : x.status;` | `< 0 ? x.status : x.status;` | `test_confirm_reports_an_image_it_cannot_scan` |

- [ ] **Step 8: A local check on Claude Code** (no commit; SKIPs where the snapshots are absent)

Every candidate of a fresh Claude Code must confirm. The snapshots are the owner's: copy one to a temporary directory and never modify it.

```sh
SNAP=$(awk -F'\t' '$5 == "pristine" { f = $7 } END { print f }' ~/.local/share/claude-binary-snapshots/manifest.tsv 2>/dev/null)
if [ -n "$SNAP" ] && [ -f "$SNAP" ]; then
    D=$(mktemp -d "${TMPDIR:-/tmp}/m1-claude.XXXXXX") && cp "$SNAP" "$D/claude.bin"
    cat >"$D/confirm.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include "hdrref.h"
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb");
    fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    uint8_t *buf = malloc(n); fread(buf, 1, n, f);
    mhr_cand bad = { 0, 0, 0 };
    printf("candidates %lld, mhr_confirm %d\n", (long long)mhr_scan(buf, n, 0x100000000ull, NULL, NULL),
           mhr_confirm(buf, n, &bad));
    return 0;
}
EOF
    cc -Isrc -o "$D/confirm" "$D/confirm.c" "$B/libdrydockcore.a" && "$D/confirm" "$D/claude.bin"
    rm -rf "$D"
else
    echo "SKIP: no pristine Claude Code snapshot"
fi
```

Expected (2.1.282, measured writing this plan): `candidates 7, mhr_confirm 0`.

- [ ] **Step 9: Commit**

```bash
git add src/hdrref.h src/hdrref.c tests/grow_test.c
git commit -m "feat(hdrref): confirm that a header reference is an instruction

The scan over-reports: a byte inside another instruction can look like a
RIP-relative ModRM. mhr_confirm decodes each candidate's function from its
LC_FUNCTION_STARTS entry, stepping over LC_DATA_IN_CODE, and confirms it
only when an instruction's RIP-relative disp32 is the candidate's and its
target is exactly the image's base. A fresh Claude Code's seven all
confirm. Nothing calls it yet; growing an executable will.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 4: Repair the references when growing, and verify the repair

**Files:**
- Modify: `src/grow.c`: the `mg_refs` block (`:51-66`, `/* The vm address of every disp32 ...` through `mg_keep_ref`); `mg_ensure_pad`'s tail (`:96-144`, from `uint64_t base_before = ...` to its closing `}`); `mg_snapshot_take` and `mg_snapshot_free` (`:404-413`); before `int mg_verify(` (`:436`); `mg_verify`'s tail (`:473-477`); before `int mg_grow_header(` (`:1069`); after the `mg_init_offsets_pass(buf, fsize, grow, 0)` audit (`:1231-1234`); after the `mg_init_offsets_pass(buf, final_size, grow, 1)` apply (`:1485-1490`)
- Modify: `src/grow.h`: the top comment (`:25-27`); before `/* The __LINKEDIT offset-bump table` (`:57`); `mg_ensure_pad`'s contract (`:108-113`); the `mg_snapshot` typedef (`:178`); `mg_verify`'s contract (`:207-209`); `mg_grow_header`'s contract (`:343-346`)
- Test: `tests/grow_test.c` (M0's section `/* ---- a grow warns of code that addresses its own header ----`, `:2099-2227`, which holds `test_ensure_pad_warns_across_a_two_page_grow`; M0's calls at `:2385-2388`), `tests/grown_binary_runs_test.sh` (`:11-13`, `:149-155`, `:164-170`, `:197-215`)

**Interfaces:**
- Consumes: `mhr_confirm`, `MHR_*` (Task 3); `mhr_scan`, `mhr_cand` (M0); `check_verify_rejects_undone`, `stderr_contains_during`, `find_section_struct`, `find_lc`, `build_image`, `hr_plant`, `hr_record`, `struct hr_seen` (`tests/grow_test.c`).
- Produces:
  - `mg_snapshot` gains `uint64_t base; mhr_cand *refs; uint32_t nrefs;` (every candidate for the base, taken before the grow; `mg_snapshot_free` frees them).
  - `mg_verify` also refuses when code addresses `before->base`, or a recorded reference no longer addresses the current base: `ERROR: verify FAILED -- code at 0x... still addresses 0x..., where the header was before the grow; refusing.` and `ERROR: verify FAILED -- the reference to the header at 0x... does not address it after the grow; refusing.`
  - `mg_grow_header` refuses, before mutating, with one of `ERROR: an instruction section lies past the end of the image, so it cannot be searched for code that addresses the image's own header; refusing to grow`, `ERROR: the bytes at 0x... may be code that addresses the image's own header, and with no LC_FUNCTION_STARTS there is no function to decode them from; refusing to grow rather than leave them pointing past it`, or `ERROR: the bytes at 0x... may be code that addresses the image's own header, and decoding their function does not confirm it; refusing to grow rather than patch them or leave them pointing past it`; otherwise it repairs every candidate.
  - `mg_ensure_pad`'s announcement ends `; repaired N references to the header` (`1 reference`) when there were any, and prints no warning.

**Plan decisions.** The refusal is `mg_grow_header`'s, before anything moves (Decision 6), after its existing audits and before the trie rebuild allocates. The snapshot, taken just after, records the candidates, all now confirmed; after the file moves, each disp32, now at its file offset plus G, loses G. Check 5 lives in `mg_verify`, driven by the snapshot, so `check_verify_rejects_undone` can undo a repair after a real grow and watch verification refuse it: re-scanning for the old base must find nothing, and every recorded candidate, with its immediate length, must address the new base. `mg_ensure_pad` counts the candidates with one more scan rather than change `mg_grow_header`'s signature (19 test callers), since after a successful grow every candidate was repaired. An instruction section past the end of the file refuses the grow now, where M0 warned. M0's two-page warning test becomes a two-page repair test, the one that tells `disp -= grow` from `disp -= MG_PAGE`. `hdr` stops printing its disp32, and the shell test runs the grown `hdr` beside the original.

- [ ] **Step 1: Write the failing in-memory tests**

In `tests/grow_test.c`, replace M0's section from `/* ---- a grow warns of code that addresses its own header ----` (`:2099`) up to, not including, `/* The scan runs only when the pad must grow: an edit that fits needs no` (`:2228`), with:

```c
/* ---- a grow repairs code that addresses its own header ----
 * Lowering the base moves the header down by the grow while the code stays
 * put, so `lea __mh_execute_header(%rip)` would then name a byte that far
 * past it. The grow confirms each such instruction and takes the grow off its
 * disp32. __plain becomes code at the vm address its file offset maps to,
 * filled with 0x90, with `lea base(%rip), %rax` (48 8d 05 disp32) at each of
 * `at`; with MG_T_FUNCSTARTS, __plain's start is a function start too. */
#define HR_PLAIN_VA 0x100001800ull
static void plant_header_refs(uint8_t *buf, size_t fsize, const uint32_t *at, int n) {
    static const uint8_t starts[7] = { 0x80, 0x20, 0x80, 0x10, 0x80, 0x10, 0x00 };
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    struct linkedit_data_command *fs =
        (struct linkedit_data_command *)find_lc(buf, fsize, LC_FUNCTION_STARTS);
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
    if (fs) {                                  /* base + 0x1000, 0x1800 (__plain), 0x2000 */
        memcpy(buf + fs->dataoff, starts, sizeof starts);
        fs->datasize = sizeof starts;
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

/* How many candidates in `buf` address `target`. */
static int64_t refs_to(const uint8_t *buf, size_t fsize, uint64_t target) {
    return mhr_scan(buf, fsize, target, NULL, NULL);
}

static void test_grow_repairs_header_references(void) {
    static const uint32_t two[] = { 0, 8 };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    struct hr_seen s = { { { 0 } }, 0, 0 };
    plant_header_refs(buf, fsize, two, 2);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "repair: a grow with two confirmed references succeeds (got %d)", r);
    if (r == 0) {
        int64_t n = mhr_scan(buf, fsize, HR_BASE - 0x1000, hr_record, &s);
        CHECK(n == 2 && s.c[0].addr == HR_PLAIN_VA + 3 && s.c[1].addr == HR_PLAIN_VA + 11,
              "repair: both leas address the new base (%lld)", (long long)n);
        CHECK(refs_to(buf, fsize, HR_BASE) == 0, "repair: none addresses the old base");
    }
    free(buf);
}

/* A grow refuses, and changes nothing, when it cannot account for a
 * candidate; `needle` is the reason it must give. */
static void check_grow_refuses_header_refs(const char *what, uint8_t *buf, size_t fsize,
                                           const char *needle) {
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000, needle, &r);
    CHECK(r == -1, "%s: mg_grow_header refuses (got %d)", what, r);
    CHECK(said, "%s: the refusal says '%s'", what, needle);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0, "%s: nothing changed", what);
    free(before);
    free(buf);
}

/* mov $imm32, %eax whose immediate starts with 0x05: a candidate the sweep
 * finds inside an instruction that is not RIP-relative. */
static void test_grow_refuses_a_header_reference_it_cannot_confirm(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, NULL, 0);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) {
        buf[pl->offset + 1] = 0xb8;
        hr_plant(buf + pl->offset, HR_PLAIN_VA, 2, 0x05, 0, HR_BASE);
    }
    check_grow_refuses_header_refs("a lookalike", buf, fsize,
        "ERROR: the bytes at 0x100001803 may be code that addresses the image's own header, "
        "and decoding their function does not confirm it; refusing to grow");
}

static void test_grow_refuses_a_header_reference_without_function_starts(void) {
    static const uint32_t one[] = { 0 };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    plant_header_refs(buf, fsize, one, 1);
    check_grow_refuses_header_refs("no function starts", buf, fsize,
        "ERROR: the bytes at 0x100001803 may be code that addresses the image's own header, "
        "and with no LC_FUNCTION_STARTS there is no function to decode them from");
}

static void test_grow_refuses_code_it_cannot_scan(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, NULL, 0);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) pl->size = fsize;                  /* 6144 + 8192 runs past the image */
    check_grow_refuses_header_refs("code past the image", buf, fsize,
        "ERROR: an instruction section lies past the end of the image, so it cannot be "
        "searched for code that addresses the image's own header; refusing to grow");
}

/* Verification's own check: undo a repair, or aim it one byte short, where
 * with an imm8 after it the operand would reach the header after all. */
static void give_header_refs(uint8_t *buf, size_t fsize, uint32_t grow) {
    static const uint32_t two[] = { 0, 8 };
    (void)grow;
    plant_header_refs(buf, fsize, two, 2);
}
static void undo_header_ref(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    int32_t disp;
    if (!pl) return;
    memcpy(&disp, buf + pl->offset + 11, sizeof disp);
    disp += (int32_t)grow;
    memcpy(buf + pl->offset + 11, &disp, sizeof disp);
}
static void misaim_header_ref(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    (void)grow;
    if (pl) buf[pl->offset + 3]--;             /* 0xf9: the low byte, far from a borrow */
}

static void test_verify_watches_header_references(void) {
    check_verify_rejects_undone("an unrepaired reference to the header",
                                MG_T_PLAINSECT | MG_T_FUNCSTARTS, give_header_refs, undo_header_ref);
    check_verify_rejects_undone("a repaired reference one byte short of the header",
                                MG_T_PLAINSECT | MG_T_FUNCSTARTS, give_header_refs, misaim_header_ref);
}

static void test_ensure_pad_repairs_each_header_reference(void) {
    static const uint32_t two[] = { 0, 8 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    const struct mach_header_64 *h = (const struct mach_header_64 *)buf;
    uint32_t lc_end = (uint32_t)sizeof *h + h->sizeofcmds;
    char line[256];
    snprintf(line, sizeof line, "t: grew the header pad by 4096 bytes (%u -> %u available); "
             "image base 0x100000000 -> 0xfffff000; repaired 2 references to the header\n",
             sect_off - lc_end, sect_off + 4096 - lc_end);
    plant_header_refs(buf, fsize, two, 2);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == 0, "two header references: the grow repairs them (got %d)", r);
    CHECK(strcmp(err, line) == 0, "two header references: stderr is\n%s want\n%s", err, line);
    CHECK(r != 0 || refs_to(buf, fsize, HR_BASE - 0x1000) == 2,
          "two header references: both address the new base");
    free(err);
    free(buf);
}

static void test_ensure_pad_repairs_one_header_reference(void) {
    static const uint32_t one[] = { 0 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, one, 1);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == 0 && strstr(err, "0xfffff000; repaired 1 reference to the header\n") != NULL,
          "one header reference: the announcement says 1 reference (got %d):\n%s", r, err);
    free(err);
    free(buf);
}

/* The repair takes off the grow, not a page: every other case here moves the
 * base by exactly one page. need_end one byte into the second page forces a
 * two-page grow. */
static void test_ensure_pad_repairs_across_a_two_page_grow(void) {
    static const uint32_t one[] = { 0 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, one, 1);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 0x1001, &r);
    CHECK(r == 0, "two-page grow: the grow repairs its reference (got %d):\n%s", r, err);
    CHECK(strstr(err, "t: grew the header pad by 8192 bytes") != NULL &&
          strstr(err, "image base 0x100000000 -> 0xffffe000; repaired 1 reference to the "
                      "header\n") != NULL,
          "two-page grow: announced as 8192 bytes, with its repair:\n%s", err);
    CHECK(r != 0 || refs_to(buf, fsize, HR_BASE - 0x2000) == 1,
          "two-page grow: the lea addresses the base two pages down");
    free(err);
    free(buf);
}

/* The control: the same section as code, with no reference. */
static void test_ensure_pad_announces_no_repair_without_a_header_reference(void) {
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, NULL, 0);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == 0 && strstr(err, "image base 0x100000000 -> 0xfffff000\n") != NULL,
          "no header reference: the announcement ends at the base (got %d):\n%s", r, err);
    free(err);
    free(buf);
}

/* Code the file does not hold cannot be searched, so the grow refuses. */
static void test_ensure_pad_refuses_code_it_cannot_scan(void) {
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, NULL, 0);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) pl->size = fsize;                  /* 6144 + 8192 runs past the image */
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == -1 && strstr(err, "ERROR: an instruction section lies past the end of the "
                                 "image, so it cannot be searched") != NULL,
          "code past the image: the grow refuses (got %d):\n%s", r, err);
    free(err);
    free(buf);
}
```

In `main`, replace M0's four calls (`:2385-2388`):

```c
    test_ensure_pad_warns_of_each_header_reference();
    test_ensure_pad_warns_across_a_two_page_grow();
    test_ensure_pad_does_not_warn_without_a_header_reference();
    test_ensure_pad_warns_of_code_it_cannot_scan();
```

with:

```c
    test_grow_repairs_header_references();
    test_grow_refuses_a_header_reference_it_cannot_confirm();
    test_grow_refuses_a_header_reference_without_function_starts();
    test_grow_refuses_code_it_cannot_scan();
    test_verify_watches_header_references();
    test_ensure_pad_repairs_each_header_reference();
    test_ensure_pad_repairs_one_header_reference();
    test_ensure_pad_repairs_across_a_two_page_grow();
    test_ensure_pad_announces_no_repair_without_a_header_reference();
    test_ensure_pad_refuses_code_it_cannot_scan();
```

- [ ] **Step 2: Write the failing end-to-end test**

In `tests/grown_binary_runs_test.sh`, replace (`:11-13`):

```sh
# it is; a slice with chained fixups does not, and is reported as a SKIP); and
# two programs that find their own header: one RIP-relatively, whose grow must
# warn about it, and one through dyld, which must grow silently and run.
```

with:

```sh
# it is; a slice with chained fixups does not, and is reported as a SKIP); and
# two programs that find their own header: one RIP-relatively, whose grow must
# repair that reference, and one through dyld, with nothing to repair.
```

Replace section 3's comment (`:149-155`):

```sh
# hdr takes its own header's address RIP-relatively, as getsectiondata(
# &_mh_execute_header, ...) does; the inline lea makes that instruction this
# fixture's on every linker, whether or not it relaxes a GOT load, and hdr
# prints where that lea's disp32 lies. A grow moves the header out from under
# it, so the grow must name it in a warning. Whether the grown hdr runs is
# not asserted: it does not yet. ctl asks dyld for its header instead, so it
# must grow with no warning, and run.
```

with:

```sh
# hdr takes its own header's address RIP-relatively, as getsectiondata(
# &_mh_execute_header, ...) does; the inline lea makes that instruction this
# fixture's on every linker, whether or not it relaxes a GOT load. A grow
# moves the header out from under it, so the grow must repair it, say so, and
# leave a binary that runs as the original does. ctl asks dyld for its header
# instead, so its grow has nothing to repair.
```

In `hdr.c`'s here-document, replace (`:164-170`):

```c
    const struct mach_header_64 *h;
    const char *end;
    unsigned long size = 0;
    __asm__("leaq __mh_execute_header(%%rip), %0\n1:\n\tleaq 1b(%%rip), %1" : "=r"(h), "=r"(end));
    uint8_t *p = getsectiondata(h, "__DATA", "__data", &size);
    printf("disp32 at %#lx\n", (unsigned long)(end - 4 - _dyld_get_image_vmaddr_slide(0)));
    printf(
```

with:

```c
    const struct mach_header_64 *h;
    unsigned long size = 0;
    __asm__("leaq __mh_execute_header(%%rip), %0" : "=r"(h));
    uint8_t *p = getsectiondata(h, "__DATA", "__data", &size);
    printf(
```

Replace (`:197-215`, from `disp=$(awk ...` through the `ctl: warning` check):

```sh
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
```

with:

```sh
grow hdr "$T/hdr" "$T/hdr.grown"
[ "$grc" -eq 0 ] && [ -e "$T/hdr.grown" ] && ok "hdr: the grow succeeds and writes its output" \
    || bad "hdr: grow" "exit $grc: $(cat "$T/hdr.grow.err")"
lowered hdr "$T/hdr" "$T/hdr.grown"
grep -q "^$T/hdr: grew the header pad by .*; repaired 1 reference to the header\$" "$T/hdr.grow.err" \
    && ok "hdr: ... repairing its one reference to the header, and saying so" \
    || bad "hdr: repaired" "$(cat "$T/hdr.grow.err")"
same hdr "$T/hdr" "$T/hdr.grown"
grep -q '__data found' "$T/hdr.out.out" \
    && ok "hdr: ... and the grown binary finds its own __data" \
    || bad "hdr: grown output" "$(cat "$T/hdr.out.out")"

grow ctl "$T/ctl" "$T/ctl.grown"
[ "$grc" -eq 0 ] && [ -e "$T/ctl.grown" ] && ok "ctl: the grow succeeds and writes its output" \
    || bad "ctl: grow" "exit $grc: $(cat "$T/ctl.grow.err")"
lowered ctl "$T/ctl" "$T/ctl.grown"
rc=0; grep -q 'repaired' "$T/ctl.grow.err" || rc=$?
[ "$rc" -eq 1 ] && ok "ctl: ... with nothing to repair (hdr's grep, above, finds its repair)" \
    || bad "ctl: repaired" "$(grep 'repaired' "$T/ctl.grow.err")"
```

- [ ] **Step 3: Run them to see them fail**

Run: build (delete every object: the tests changed nothing in `src/`, but do it anyway), then `"$B/grow_test"`.
Expected: exit 1, `macho_grow_test: 19 FAILURE(S)`:

```
FAIL: repair: both leas address the new base (0)
FAIL: repair: none addresses the old base
FAIL: a lookalike: mg_grow_header refuses (got 0)
FAIL: a lookalike: the refusal says 'ERROR: the bytes at 0x100001803 may be code that addresses the image's own header, and decoding their function does not confirm it; refusing to grow'
FAIL: a lookalike: nothing changed
FAIL: no function starts: mg_grow_header refuses (got 0)
FAIL: no function starts: the refusal says 'ERROR: the bytes at 0x100001803 may be code that addresses the image's own header, and with no LC_FUNCTION_STARTS there is no function to decode them from'
FAIL: no function starts: nothing changed
FAIL: code past the image: mg_grow_header refuses (got 0)
FAIL: code past the image: the refusal says 'ERROR: an instruction section lies past the end of the image, so it cannot be searched for code that addresses the image's own header; refusing to grow'
FAIL: code past the image: nothing changed
FAIL: verify REJECTS an unrepaired reference to the header
FAIL: verify REJECTS a repaired reference one byte short of the header
FAIL: two header references: stderr is
FAIL: two header references: both address the new base
FAIL: one header reference: the announcement says 1 reference (got 0):
FAIL: two-page grow: announced as 8192 bytes, with its repair:
FAIL: two-page grow: the lea addresses the base two pages down
FAIL: code past the image: the grow refuses (got 0):
```

Run: `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`
Expected: exit 1, `grown_binary_runs_test: 4 failure(s)`: `FAIL hdr: repaired`, `FAIL hdr: stdout: input 'header magic 0xfeedfacf, __data found (4 bytes)', grown ''`, `FAIL hdr: exit status: input 0, grown 139` and `FAIL hdr: grown output`; the shell also reports `Segmentation fault: 11`. Item 29's reproduction, reproduced. Every `ctl:` line passes.

- [ ] **Step 4: The snapshot records the references, and verify re-scans**

In `src/grow.h`, before `/* The __LINKEDIT offset-bump table: ml_bump and ml_bump_all, covering` (`:57`), add:

```c
/* Code that addresses its own image's header: found, confirmed, repaired. */
#include "hdrref.h"

```

Replace the typedef (`:178`):

```c
typedef struct { uint64_t *addr; uint32_t n; } mg_snapshot;
```

with:

```c
/* What mg_verify compares a grown image against: the resolved addresses
 * mg_collect finds, and the image base with every reference to it the
 * header-reference scan (src/hdrref.h) finds. */
typedef struct {
    uint64_t *addr;
    uint32_t n;
    uint64_t base;
    mhr_cand *refs;
    uint32_t nrefs;
} mg_snapshot;
```

Replace `mg_verify`'s contract (`:207-209`):

```c
/* 0 if every base-relative structure and every mg_each_fileoff offset
 * resolves exactly where it did before the grow, and no two segments overlap
 * in memory; -1 (with a message naming the first failure) otherwise. */
```

with:

```c
/* 0 if every base-relative structure and every mg_each_fileoff offset
 * resolves exactly where it did before the grow, no two segments overlap in
 * memory, no code addresses the base as it was, and every reference to the
 * header the snapshot recorded addresses the base as it is; -1 (with a message
 * naming the first failure) otherwise. */
```

In `src/grow.c`, replace `mg_snapshot_take` and `mg_snapshot_free` (`:404-413`):

```c
int mg_snapshot_take(const uint8_t *buf, size_t fsize, mg_snapshot *s) {
    s->addr = (uint64_t *)malloc(MG_SNAP_MAX * sizeof(uint64_t));
    if (!s->addr) return -1;
    if (mg_collect(buf, fsize, s->addr, NULL, MG_SNAP_MAX, &s->n) != 0) {
        free(s->addr); s->addr = NULL; s->n = 0; return -1;
    }
    return 0;
}

void mg_snapshot_free(mg_snapshot *s) { free(s->addr); s->addr = NULL; s->n = 0; }
```

with:

```c
/* mg_snapshot_take's mhr_scan callback: keep each reference to the header. */
static int mg_keep_ref(const mhr_cand *c, void *ctx_) {
    mg_snapshot *s = (mg_snapshot *)ctx_;
    mhr_cand *r = (mhr_cand *)realloc(s->refs, (s->nrefs + 1) * sizeof *r);
    if (!r) return 1;
    s->refs = r;
    s->refs[s->nrefs++] = *c;
    return 0;
}

int mg_snapshot_take(const uint8_t *buf, size_t fsize, mg_snapshot *s) {
    mi_image im;
    s->refs = NULL;
    s->nrefs = 0;
    s->addr = (uint64_t *)malloc(MG_SNAP_MAX * sizeof(uint64_t));
    if (!s->addr) return -1;
    if (mg_collect(buf, fsize, s->addr, NULL, MG_SNAP_MAX, &s->n) != 0 ||
        mi_wrap((uint8_t *)buf, fsize, &im) != 0 || mi_image_base(&im, &s->base) != 0 ||
        mhr_scan(buf, fsize, s->base, mg_keep_ref, s) != (int64_t)s->nrefs) {
        mg_snapshot_free(s);
        return -1;
    }
    return 0;
}

void mg_snapshot_free(mg_snapshot *s) {
    free(s->addr); s->addr = NULL; s->n = 0;
    free(s->refs); s->refs = NULL; s->nrefs = 0;
}
```

Immediately before `int mg_verify(const uint8_t *buf, size_t fsize, const mg_snapshot *before) {` (`:436`), add:

```c
static int mg_first_ref(const mhr_cand *c, void *ctx_) { *(mhr_cand *)ctx_ = *c; return 1; }

struct mg_found { const mg_snapshot *s; uint8_t *seen; };
static int mg_found_ref(const mhr_cand *c, void *ctx_) {
    struct mg_found *f = (struct mg_found *)ctx_;
    for (uint32_t i = 0; i < f->s->nrefs; i++)
        if (f->s->refs[i].addr == c->addr && f->s->refs[i].immlen == c->immlen) f->seen[i] = 1;
    return 0;
}

/* No code addresses where the header was, and every reference to it the
 * snapshot recorded addresses where it is. */
static int mg_verify_refs(const uint8_t *buf, size_t fsize, const mg_snapshot *before,
                          uint64_t base) {
    mhr_cand stale = { 0, 0, 0 };
    if (mhr_scan(buf, fsize, before->base, mg_first_ref, &stale) != 0) {
        fprintf(stderr, "ERROR: verify FAILED -- code at %#llx still addresses %#llx, where "
                        "the header was before the grow; refusing.\n",
                (unsigned long long)stale.addr, (unsigned long long)before->base);
        return -1;
    }
    struct mg_found f = { before, (uint8_t *)calloc(before->nrefs + 1, 1) };
    if (!f.seen) return -1;
    mhr_scan(buf, fsize, base, mg_found_ref, &f);
    for (uint32_t i = 0; i < before->nrefs; i++) {
        if (f.seen[i]) continue;
        fprintf(stderr, "ERROR: verify FAILED -- the reference to the header at %#llx does "
                        "not address it after the grow; refusing.\n",
                (unsigned long long)before->refs[i].addr);
        free(f.seen);
        return -1;
    }
    free(f.seen);
    return 0;
}

```

Replace `mg_verify`'s tail (`:473-477`):

```c
                        "memory after the grow; refusing.\n", oc.a->segname, oc.hit->segname);
        return -1;
    }
    return 0;
}
```

with:

```c
                        "memory after the grow; refusing.\n", oc.a->segname, oc.hit->segname);
        return -1;
    }
    uint64_t base;
    if (mi_image_base(&im, &base) != 0) return -1;
    return mg_verify_refs(buf, fsize, before, base);
}
```

- [ ] **Step 5: Refuse what cannot be confirmed, and repair the rest**

In `src/grow.c`, immediately before `int mg_grow_header(uint8_t **pbuf, size_t *pfsize, uint32_t grow_req) {` (`:1069`), add:

```c
/* 0 if every candidate mhr_scan finds for the image's base is an
 * instruction mhr_confirm vouches for, which the grow then repairs; otherwise
 * -1, having said why. */
static int mg_header_refs_ok(const uint8_t *buf, size_t fsize) {
    mhr_cand bad = { 0, 0, 0 };
    int r = mhr_confirm(buf, fsize, &bad);
    if (r == MHR_CONFIRMED) return 0;
    if (r == MHR_UNSCANNABLE)
        fprintf(stderr, "ERROR: an instruction section lies past the end of the image, so "
                        "it cannot be searched for code that addresses the image's own "
                        "header; refusing to grow\n");
    else if (r == MHR_NO_STARTS)
        fprintf(stderr, "ERROR: the bytes at %#llx may be code that addresses the image's "
                        "own header, and with no LC_FUNCTION_STARTS there is no function to "
                        "decode them from; refusing to grow rather than leave them pointing "
                        "past it\n", (unsigned long long)bad.addr);
    else if (r == MHR_UNCONFIRMED)
        fprintf(stderr, "ERROR: the bytes at %#llx may be code that addresses the image's "
                        "own header, and decoding their function does not confirm it; "
                        "refusing to grow rather than patch them or leave them pointing "
                        "past it\n", (unsigned long long)bad.addr);
    else
        fprintf(stderr, "ERROR: could not search the image for code that addresses its own "
                        "header; refusing to grow\n");
    return -1;
}

```

After the `S_INIT_FUNC_OFFSETS` audit (`:1231-1234`, the block ending `fprintf(stderr, "ERROR: malformed S_INIT_FUNC_OFFSETS section; refusing to grow\n"); return -1; }`), add:

```c
    if (mg_header_refs_ok(buf, fsize) != 0) return -1;
```

After the `S_INIT_FUNC_OFFSETS` apply (`:1485-1490`, the block ending `"passing the pre-check\n"); mg_snapshot_free(&snap); return -1; }` after `mg_init_offsets_pass(buf, final_size, grow, 1)`), add:

```c

    /* The header moved down by `grow` and the code did not: every reference
     * to the header is `grow` farther from it. */
    for (uint32_t i = 0; i < snap.nrefs; i++) {
        uint8_t *d = buf + snap.refs[i].off + grow;
        int32_t disp;
        memcpy(&disp, d, sizeof disp);
        disp = (int32_t)((int64_t)disp - (int64_t)grow);
        memcpy(d, &disp, sizeof disp);
    }
```

In `src/grow.h`, replace the top comment's claim (`:25-27`):

```c
 * its ORIGINAL vm address, so no pointer, rebase, bind, n_value, or entry
 * address ever changes. The only fields that move are file offsets — which we
 * shift uniformly. (Borrowed from LIEF: the exhaustive list of offset fields.)
```

with:

```c
 * its ORIGINAL vm address, so no pointer, rebase, bind, n_value, or entry
 * address that names content changes. The fields that move are file offsets —
 * which we shift uniformly (borrowed from LIEF: the exhaustive list of offset
 * fields) — and code that reaches the header RIP-relatively (src/hdrref.h),
 * since the header moved.
```

Replace `mg_grow_header`'s contract (`:343-346`):

```c
 * a large enough __PAGEZERO; one with no section data to insert the new space
 * at (mg_first_sect_off's MG_NO_SECTION_DATA); and one whose first section's
 * file offset lies past the end of the image. A failure partway through
 * growing can leave the buffer modified (see mg_ensure_pad).
```

with:

```c
 * a large enough __PAGEZERO; one with no section data to insert the new space
 * at (mg_first_sect_off's MG_NO_SECTION_DATA); one whose first section's
 * file offset lies past the end of the image; and one with a candidate
 * reference to its own header (src/hdrref.h) that mhr_confirm cannot vouch
 * for. Every confirmed reference is repaired: its disp32 loses the grow, so it
 * still reaches the header. A failure partway through growing can leave the
 * buffer modified (see mg_ensure_pad).
```

- [ ] **Step 6: Announce the repair instead of warning**

In `src/grow.c`, delete M0's `mg_refs` block (`:51-66`), including the blank line after it:

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

Replace `mg_ensure_pad`'s tail (`:96-144`):

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

with:

```c
    uint64_t base_before = mg_base_of(*pbuf, *pfsize);
    int64_t refs = mhr_scan(*pbuf, *pfsize, base_before, NULL, NULL);

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
                    "image base %#llx -> %#llx",
            label, first - first_before, pad_avail, first - cur_lc_end,
            (unsigned long long)base_before, (unsigned long long)mg_base_of(*pbuf, *pfsize));
    if (refs > 0)
        fprintf(stderr, "; repaired %lld reference%s to the header", (long long)refs,
                refs == 1 ? "" : "s");
    fprintf(stderr, "\n");
    return 0;
}
```

In `src/grow.h`, replace in `mg_ensure_pad`'s contract (`:108-113`):

```c
available); image base 0xOLD -> 0xNEW". A line follows for each instruction
 * whose RIP-relative operand named the header before the grow (src/hdrref.h),
 * which the grow leaves pointing G bytes past it: "LABEL: warning: code at
 * 0xDISP32 addresses the image's own header; after this grow it points 0xG
 * bytes past it (QUEUE item 29)"; and one if an instruction section could not
 * be scanned.
```

with:

```c
available); image base 0xOLD -> 0xNEW", ending "; repaired N references to
 * the header" (or "1 reference") when the grow repaired code that addresses
 * the image's own header (src/hdrref.h).
```

- [ ] **Step 7: Run them to see them pass**

Run: build (a header changed: delete every object; rebuild check on `$B/grow_test` and `$B/drydock-macho-rewrite`), then `"$B/grow_test"` and `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`.
Expected: `macho_grow_test: all cases pass`; `grown_binary_runs_test: all passed`, including `PASS hdr: ... repairing its one reference to the header, and saying so`, `PASS hdr: the grown binary's stdout is the input's`, `PASS hdr: ... and so is its exit status (0)` and `PASS ctl: ... with nothing to repair (hdr's grep, above, finds its repair)`. Then the whole suite: all pass. A suite that now fails on `may be code that addresses the image's own header` has a fixture with an unconfirmable candidate: stop and report it (none did writing this plan).

- [ ] **Step 8: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test` unless stated)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (refs > 0)` | `    if (refs > 1)` | `test_ensure_pad_repairs_one_header_reference`; and `tests/grown_binary_runs_test.sh` (`FAIL hdr: repaired`) |
| 2 | `refs == 1 ? "" : "s"` | `"s"` | `test_ensure_pad_repairs_one_header_reference` |
| 3 | `    int64_t refs = mhr_scan(*pbuf, *pfsize, base_before, NULL, NULL);` | the same with `base_before - MG_PAGE` | `test_ensure_pad_repairs_each_header_reference` |
| 4 | `    if (mg_header_refs_ok(buf, fsize) != 0) return -1;` | (delete it) | `test_grow_refuses_a_header_reference_it_cannot_confirm` |
| 5 | `    if (r == MHR_CONFIRMED) return 0;` | `    if (r != -1) return 0;` | `test_grow_refuses_a_header_reference_without_function_starts` |
| 6 | `    if (r == MHR_UNSCANNABLE)` | `    if (r == MHR_UNCONFIRMED)` | `test_grow_refuses_code_it_cannot_scan` |
| 7 | `    else if (r == MHR_NO_STARTS)` | `    else if (r == -2)` | `test_grow_refuses_a_header_reference_without_function_starts` |
| 8 | `        disp = (int32_t)((int64_t)disp - (int64_t)grow);` | the same with `+` | `test_grow_repairs_header_references` (check 5 refuses the grow); and `tests/grown_binary_runs_test.sh` (`FAIL hdr: grow`) |
| 9 | `        uint8_t *d = buf + snap.refs[i].off + grow;` | `        uint8_t *d = buf + snap.refs[i].off;` | `test_grow_repairs_header_references` |
| 10 | `    return mg_verify_refs(buf, fsize, before, base);` | `    return 0;` | `test_verify_watches_header_references` |
| 11 | `    if (mhr_scan(buf, fsize, before->base, mg_first_ref, &stale) != 0) {` | the same with `base` for `before->base` | `test_grow_repairs_header_references` |
| 12 | `        if (f.seen[i]) continue;` | `        continue;` | `test_verify_watches_header_references` ("one byte short") |
| 13 | ` && f->s->refs[i].immlen == c->immlen) f->seen[i] = 1;` | `) f->seen[i] = 1;` | `test_verify_watches_header_references` ("one byte short") |
| 14 | in `mg_keep_ref`, `    s->refs[s->nrefs++] = *c;` | `    (void)c;` | `test_grow_repairs_header_references` |
| 15 | in the repair loop, `        memcpy(d, &disp, sizeof disp);` | (delete it) | `tests/grown_binary_runs_test.sh` (`FAIL hdr: grow`: check 5 refuses, `code at 0x... still addresses 0x100000000`) |
| 16 | `        disp = (int32_t)((int64_t)disp - (int64_t)grow);` | the same with `(int64_t)MG_PAGE` for `(int64_t)grow` | `test_ensure_pad_repairs_across_a_two_page_grow` (check 5 refuses the two-page grow) |

- [ ] **Step 9: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c tests/grown_binary_runs_test.sh
git commit -m "fix(grow): repair code that addresses its own header

Lowering the image base moves the header down while the code stays put,
so leaq __mh_execute_header(%rip) came to name a byte a page past it: the
grown item-29 program segfaulted, and M0 only warned. The grow now
confirms each candidate by decoding its function, takes the grow off each
one's disp32, and says so at the end of its line (\"; repaired 7
references to the header\" on a fresh Claude Code). It refuses, before
changing anything, a candidate it cannot confirm, one in an image with no
LC_FUNCTION_STARTS, and an instruction section past the end of the file.
Verification re-scans the result: no code may still address the old base,
and every repaired reference must address the new one.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 5: Move the symbols that name the header

**Files:**
- Modify: `src/grow.c` (`#include "grow.h"` at `:3`; before `int mg_grow_header(`; after Task 4's `if (mg_header_refs_ok(buf, fsize) != 0) return -1;`; after Task 4's repair loop)
- Modify: `src/grow.h` (`mg_grow_header`'s contract and the top comment, as Task 4 left them)
- Test: `tests/grow_test.c` (`#include "hdrref.h"` at `:18`; new tests before `int main(void) {`; calls after Task 3's `test_confirm_reports_an_image_it_cannot_scan();`), `tests/grown_binary_runs_test.sh` (after Task 4's `hdr: grown output` check)

**Interfaces:**
- Consumes: `snap.base` (Task 4); `build_image`'s `MG_T_SYMTAB` (symbol table at file 6656, room for four `nlist_64`s before its string table at 6720) and `MG_T_TRIE` (node A's child offset at trie byte 4); `TRIE_OFF`; `stderr_contains_during`; `text_vmaddr` (the shell test).
- Produces: after a grow, each `LC_SYMTAB` symbol that is not a stab, has type `N_SECT` and has the old base as its value, has the new base; `mg_grow_header` refuses, before mutating, `ERROR: LC_SYMTAB's symbol table (offset N, M entries) does not fit within the S-byte image; refusing to grow`.

**Plan decisions.** QUEUE item 29's addendum: after a grow, `__mh_execute_header` still records the old base. It is the same stale header address as the code M1 repairs, and spec Decision 2's rule (what names the header follows the header) says to move it, so M1 does. `nm`, `lldb` and `atos` read it; `dladdr` on 10.9 answers `__dso_handle` for the header either way. Only non-stab `N_SECT` symbols whose value is exactly the old base move; a stab (`N_BNSYM`'s type bits read as `N_SECT` under the mask) and an `N_ABS` symbol with that value keep it. One walker audits (bounds) and applies, like `mg_init_offsets_pass`. A symbol table that runs past the file refuses the grow; the audit runs before anything moves, and a test pins that a grow refused after it moves no symbol. After this task, every grown executable's output differs from M0's in exactly these 4 bytes.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, replace `#include "hdrref.h"` (`:18`) with:

```c
#include "hdrref.h"
#include <mach-o/nlist.h>
#include <mach-o/stab.h>
```

Insert before `int main(void) {`:

```c
/* ---- symbols that name the header ----
 * MG_T_SYMTAB's table (file 6656) gets four symbols. __mh_execute_header is
 * an N_SECT symbol whose value is the base, so it follows the header down.
 * The others keep their values: a symbol naming content, and a stab and an
 * absolute symbol whose values happen to equal the base. N_BNSYM's type bits
 * read as N_SECT under the N_TYPE mask; it is a stab all the same. */
static const struct { uint8_t type; uint64_t value, want; } hsyms[4] = {
    { N_SECT | N_EXT, 0x100000000ull, 0xfffff000ull },
    { N_SECT,         0x100001000ull, 0x100001000ull },
    { N_BNSYM,        0x100000000ull, 0x100000000ull },
    { N_ABS | N_EXT,  0x100000000ull, 0x100000000ull },
};

static uint8_t *build_symbol_image(size_t *fsize, uint32_t nsyms, int opts) {
    uint32_t sect_off;
    uint8_t *buf = build_image(fsize, &sect_off, MG_T_SYMTAB | opts);
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, *fsize, LC_SYMTAB);
    struct nlist_64 *nl = (struct nlist_64 *)(buf + st->symoff);
    for (int i = 0; i < 4; i++) {
        nl[i].n_type = hsyms[i].type;
        nl[i].n_sect = hsyms[i].type == N_ABS ? NO_SECT : 1;
        nl[i].n_value = hsyms[i].value;
    }
    st->nsyms = nsyms;
    return buf;
}

static void test_grow_moves_the_symbols_that_name_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "symbols: the grow succeeds (got %d)", r);
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB);
    const struct nlist_64 *nl = (const struct nlist_64 *)(buf + st->symoff);
    for (int i = 0; r == 0 && i < 4; i++)
        CHECK(nl[i].n_value == hsyms[i].want, "symbols: type %#x, value %#llx, is %#llx after "
              "the grow, want %#llx", hsyms[i].type, (unsigned long long)hsyms[i].value,
              (unsigned long long)nl[i].n_value, (unsigned long long)hsyms[i].want);
    free(buf);
}

static void test_grow_refuses_a_symbol_table_past_the_image(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 1000, 0);   /* 6656 + 16000 > 8192 */
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
        "ERROR: LC_SYMTAB's symbol table (offset 6656, 1000 entries) does not fit within the "
        "8192-byte image; refusing to grow", &r);
    CHECK(r == -1 && said, "symbols: a table past the image is refused (got %d)", r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0, "symbols: nothing changed");
    free(before);
    free(buf);
}

/* A grow refused after the symbols are checked (here, for a malformed export
 * trie: node A's child offset points past the trie) leaves them as they were. */
static void test_grow_moves_no_symbol_when_it_refuses(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, MG_T_TRIE);
    buf[TRIE_OFF + 4] = 200;
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
                                      "export trie is malformed", &r);
    CHECK(r == -1 && said, "symbols: a malformed trie is refused (got %d)", r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "symbols: a refused grow moves no symbol");
    free(before);
    free(buf);
}
```

After `    test_confirm_reports_an_image_it_cannot_scan();` in `main`:

```c
    test_grow_moves_the_symbols_that_name_the_header();
    test_grow_refuses_a_symbol_table_past_the_image();
    test_grow_moves_no_symbol_when_it_refuses();
```

In `tests/grown_binary_runs_test.sh`, after the check ending `|| bad "hdr: grown output" "$(cat "$T/hdr.out.out")"`, add:

```sh
sym=$(nm "$T/hdr.grown" | awk '$3 == "__mh_execute_header" { print $1; exit }')
base=$(text_vmaddr "$T/hdr.grown")
[ -n "$sym" ] && [ -n "$base" ] && [ $((0x$sym)) -eq $((base)) ] \
    && ok "hdr: ... and its __mh_execute_header symbol names the header ($base)" \
    || bad "hdr: symbol" "__mh_execute_header is '$sym', the header is at '$base'"
```

- [ ] **Step 2: Run them to see them fail**

Run: build (delete every object), then `"$B/grow_test"`.
Expected: exit 1, `macho_grow_test: 3 FAILURE(S)`:

```
FAIL: symbols: type 0xf, value 0x100000000, is 0x100000000 after the grow, want 0xfffff000
FAIL: symbols: a table past the image is refused (got 0)
FAIL: symbols: nothing changed
```

(`test_grow_moves_no_symbol_when_it_refuses` passes already: it pins what this task must keep.)

Run: `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`
Expected: exit 1, `grown_binary_runs_test: 1 failure(s)`: `FAIL hdr: symbol: __mh_execute_header is '0000000100000000', the header is at '0xfffff000'`.

- [ ] **Step 3: Implement**

In `src/grow.c`, replace `#include "grow.h"` and `#include "hdrref.h"` (`:3-4`) with:

```c
#include <mach-o/nlist.h>

#include "grow.h"
#include "hdrref.h"
```

Immediately before `int mg_grow_header(uint8_t **pbuf, size_t *pfsize, uint32_t grow_req) {` (after Task 4's `mg_header_refs_ok`), add:

```c
/* The symbols that name the header: each N_SECT symbol, not a stab, whose
 * value is `base`. With `patch`, each loses `grow`, following the header
 * down; without, this checks that the symbol table lies within the image,
 * and says so on stderr when it does not. Returns 0, or -1. */
struct mg_hsym_ctx { uint8_t *buf; size_t fsize; uint64_t base; uint32_t grow; int patch, bad; };

static int mg_hsym_cb(const struct load_command *lc, void *ctx_) {
    struct mg_hsym_ctx *c = (struct mg_hsym_ctx *)ctx_;
    if (lc->cmd != LC_SYMTAB) return 0;
    const struct symtab_command *st = (const struct symtab_command *)lc;
    if ((uint64_t)st->symoff + (uint64_t)st->nsyms * sizeof(struct nlist_64) > c->fsize) {
        fprintf(stderr, "ERROR: LC_SYMTAB's symbol table (offset %u, %u entries) does not fit "
                        "within the %zu-byte image; refusing to grow\n",
                st->symoff, st->nsyms, c->fsize);
        c->bad = 1;
        return 1;
    }
    struct nlist_64 *nl = (struct nlist_64 *)(c->buf + st->symoff);
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
    struct mg_hsym_ctx c = { buf, fsize, base, grow, patch, 0 };
    mi_each_lc(&im, mg_hsym_cb, &c);
    return c.bad ? -1 : 0;
}

```

After Task 4's `    if (mg_header_refs_ok(buf, fsize) != 0) return -1;`, add:

```c
    if (mg_header_symbols(buf, fsize, 0, grow, 0) != 0) return -1;
```

After Task 4's repair loop (ending `memcpy(d, &disp, sizeof disp);` and its `}`), add:

```c
    if (mg_header_symbols(buf, final_size, snap.base, grow, 1) != 0) {
        fprintf(stderr, "ERROR: internal error re-basing the symbols that name the header "
                        "after passing the pre-check\n");
        mg_snapshot_free(&snap);
        return -1;
    }
```

In `src/grow.h`, in `mg_grow_header`'s contract, replace:

```c
 * for. Every confirmed reference is repaired: its disp32 loses the grow, so it
 * still reaches the header. A failure partway through growing can leave the
 * buffer modified (see mg_ensure_pad).
```

with:

```c
 * for; and one whose LC_SYMTAB symbol table does not fit in the image. Every
 * confirmed reference is repaired: its disp32 loses the grow, so it still
 * reaches the header. So does the value of each symbol that names the header
 * (__mh_execute_header). A failure partway through growing can leave the
 * buffer modified (see mg_ensure_pad).
```

In the top comment, replace:

```c
 * fields) — and code that reaches the header RIP-relatively (src/hdrref.h),
 * since the header moved.
```

with:

```c
 * fields) — and what names the header, which moved: code that reaches it
 * RIP-relatively (src/hdrref.h), and the value of a symbol that names it.
```

- [ ] **Step 4: Run them to see them pass**

Run: build (delete every object; rebuild check on `$B/grow_test` and `$B/drydock-macho-rewrite`), then `"$B/grow_test"` and `unset DRYDOCK_MACHO_REWRITE; sh tests/grown_binary_runs_test.sh "$B"`.
Expected: `macho_grow_test: all cases pass`; `grown_binary_runs_test: all passed`, including `PASS hdr: ... and its __mh_execute_header symbol names the header (0xfffff000)`. Then the whole suite: all pass.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test` unless stated)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `            nl[i].n_value -= c->grow;` | `            nl[i].n_value -= 0;` | `test_grow_moves_the_symbols_that_name_the_header` ("type 0xf"); and `tests/grown_binary_runs_test.sh` (`FAIL hdr: symbol`) |
| 2 | `        if (!(nl[i].n_type & N_STAB) && (nl[i].n_type & N_TYPE) == N_SECT &&` | `        if ((nl[i].n_type & N_TYPE) == N_SECT &&` | `test_grow_moves_the_symbols_that_name_the_header` ("type 0x2e") |
| 3 | the same line | `        if (!(nl[i].n_type & N_STAB) &&` | `test_grow_moves_the_symbols_that_name_the_header` ("type 0x3") |
| 4 | `            nl[i].n_value == c->base)` | `            nl[i].n_value >= c->base)` | `test_grow_moves_the_symbols_that_name_the_header` ("type 0xe") |
| 5 | `            nl[i].n_value -= c->grow;` | `            nl[i].n_value += c->grow;` | `test_grow_moves_the_symbols_that_name_the_header` ("type 0xf") |
| 6 | `    if ((uint64_t)st->symoff + (uint64_t)st->nsyms * sizeof(struct nlist_64) > c->fsize) {` | `    if (0) {` | `test_grow_refuses_a_symbol_table_past_the_image` |
| 7 | `    if (mg_header_symbols(buf, fsize, 0, grow, 0) != 0) return -1;` | (delete it) | `test_grow_refuses_a_symbol_table_past_the_image` ("nothing changed") |
| 8 | the same line | `    if (mg_header_symbols(buf, fsize, 0x100000000ull, grow, 1) != 0) return -1;` | `test_grow_moves_no_symbol_when_it_refuses` |

- [ ] **Step 6: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c tests/grown_binary_runs_test.sh
git commit -m "fix(grow): move the symbols that name the header with it

A grow lowers the base, so the header moves, and __mh_execute_header's
symbol went on recording where it had been: nm, lldb and atos put the
header a page above it. Each non-stab N_SECT symbol whose value is the old
base now takes the new one; a symbol table that runs past the file refuses
the grow before anything moves.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 6: Documentation, QUEUE item 29, and a local check on Claude Code

**Files:**
- Modify: `compat/README.md:150-158` (the "A header pad too short ... is grown" bullet, which quotes M0's warning and, since `cd05fea`, says the scan can over-report)
- Modify: `docs/superpowers/QUEUE.md:35` (item 29's row), after `:1462-1464` (item 29's "Stop-gap done" paragraph)

**Interfaces:**
- Consumes: Task 4's commit (subject `fix(grow): repair code that addresses its own header`).
- Produces: nothing code depends on.

**Plan decisions.** QUEUE item 29 is marked done: its code references and its symbol are repaired. The data pointer to the header, found while planning M1, is recorded in the same item as not repaired, with its measured reach, because its repair needs the rebase decoder M2 builds (spec Decision 9); the spec's Decision 2 wording is the owner's to amend.

- [ ] **Step 1: Find Task 4's commit**

Run: `C=$(git log -1 --format=%h --grep='^fix(grow): repair code that addresses its own header'); echo "$C"`
Expected: one short hash. It replaces `$C` in the QUEUE edits below.

- [ ] **Step 2: `compat/README.md`**

Replace (`:150-158`):

```markdown
    ..."), and exits 0; anything else is still refused. When the
    executable's code takes its own header's address RIP-relatively, which
    lowering the base breaks, one more line follows for each such
    instruction: "FILE: warning: code at 0x... addresses the image's own
    header; after this grow it points 0x1000 bytes past it (QUEUE item 29)"
    (`tests/grown_binary_runs_test.sh`, "hdr"). The scan that finds these can,
    rarely, report bytes that only look like such an instruction; it
    over-reports, never under-reports. The repo owner's
```

with:

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

- [ ] **Step 3: `docs/superpowers/QUEUE.md`**

In item 29's row (`:35`), replace:

```markdown
| `plans/2026-09-25-header-references-m0.md` (M0) | **stop-gap done**: warned since `ef62652`; repair is M1; see below |
```

with (`$C` from Step 1):

```markdown
| `plans/2026-09-25-header-references-m0.md` (M0), `plans/2026-09-25-header-references-m1.md` (M1) | **done**: repaired since `$C`; a data pointer to the header is not, see below |
```

After item 29's "Stop-gap done" paragraph (`:1462-1464`, ending `fresh Claude Code download grows with seven such warnings.`), add (`$C` from Step 1):

```markdown
**Done** (M1): repaired since `$C`. A grow decodes each candidate's function
from its `LC_FUNCTION_STARTS` entry (`src/x86len.h`, checked against 10.9's
`otool`), takes the grow off each confirmed disp32, moves the
`__mh_execute_header` symbol with the header, and refuses a candidate it
cannot confirm. A fresh Claude Code download grows with "repaired 7
references to the header".

**Not repaired** (found while planning M1): a data pointer to the header,
`const void *p = &_mh_execute_header;`, is a rebase target whose value is
the base, and after a grow it names a byte G past the header. 46 of 838
x86_64 executables on this host have one (the Java launcher stubs among
them); Claude Code has none among its 94,730 rebase targets. The spec's
Decision 2 leaves absolute addresses alone on the executable route; this is
the exception, and its repair needs the rebase decoder (spec Decision 9).
```

If any of these passages has changed since this plan was written, make the equivalent edit and say so in the commit message.

- [ ] **Step 4: Check the docs and the tree**

Run each; every negative has its positive control first:

```sh
git grep -c 'repaired N references to the header' -- compat/README.md                     # expect 1
git grep -n 'repaired since' -- docs/superpowers/QUEUE.md                                 # expect two lines naming $C
git grep -n 'QUEUE item 29' cd05fea -- src tests compat | wc -l                          # positive control: expect 6 (M0's warning)
rc=0; git grep -n 'QUEUE item 29' -- src tests compat || rc=$?; echo "rc=$rc"             # expect rc=1
git grep -c -E 'superpowers|specs/|plans/' -- docs/superpowers/QUEUE.md                   # positive control: expect > 0
rc=0; git grep -n -E 'superpowers|specs/|plans/' -- src tests CMakeLists.txt || rc=$?; echo "rc=$rc"   # expect rc=1
```

- [ ] **Step 5: Local check: a fresh Claude Code grows, repairing seven**

The owner's snapshots are never modified: copy the pristine one to a temporary directory. The step SKIPs where there is none.

```sh
SNAP=$(awk -F'\t' '$5 == "pristine" { f = $7 } END { print f }' ~/.local/share/claude-binary-snapshots/manifest.tsv 2>/dev/null)
if [ -n "$SNAP" ] && [ -f "$SNAP" ]; then
    D=$(mktemp -d "${TMPDIR:-/tmp}/m1-claude.XXXXXX") && cp "$SNAP" "$D/claude.in"
    { echo 'fixups set classic'; printf 'rpath append /nonexistent/%s\n' "$(printf '%06000d' 0)"; } >"$D/edits"
    rc=0; "$B/drydock-macho-rewrite" "$D/claude.in" "$D/claude.out" <"$D/edits" >/dev/null 2>"$D/err" || rc=$?
    echo "rc=$rc"; grep -E 'grew the header pad|: warning: |ERROR' "$D/err"
    "$B/drydock-macho-rewrite" verify "$D/claude.out" 2>&1 | tail -1
    rm -rf "$D"
else
    echo "SKIP: no pristine Claude Code snapshot"
fi
```

Expected (2.1.282, measured writing this plan): `rc=0`; exactly one line, `...claude.in: grew the header pad by 8192 bytes (64 -> 8256 available); image base 0x100000000 -> 0xffffe000; repaired 7 references to the header`; and `...claude.out: OK`. The grow takes about 2 s (M0: 0.8 s).

- [ ] **Step 6: Commit**

```bash
git add compat/README.md docs/superpowers/QUEUE.md
git commit -m "docs: a grow repairs code that addresses its own header; item 29 done

compat/README.md, where it quotes a grow's announcement, now gives the
repair clause in place of the warning. QUEUE item 29 is marked done:
repaired since $C. A data pointer to the header, found while planning M1,
is recorded there as not repaired: it needs the rebase decoder.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

(Expand `$C` before committing: write the message with the hash in it, e.g. through `git commit -F` from a file you filled in.)

---

## Self-review

**1. Spec coverage.**

| M1 requirement (spec) | task |
|---|---|
| An x86-64 instruction-length decoder, a new self-contained module | 1 |
| Its oracle: boundaries equal `otool`'s over every function of a corpus of real 10.9 binaries; local; SKIPs, saying why, without the tools or corpus | 2 |
| Confirmation: containing function through `LC_FUNCTION_STARTS`; linear sweep, skipping `LC_DATA_IN_CODE`; ModRM plus disp32 exactly the candidate's | 3 |
| Patching on the executable route, `disp32 -= G` | 4 |
| Decision 6: refuse a candidate the sweep cannot confirm, or any image with a candidate and no `LC_FUNCTION_STARTS`, before anything is mutated | 4 |
| Decision 8: `; repaired N references to the header`; the patching replaces M0's warning | 4 |
| Decision 7, check 5: no candidate may target new base + G; every patched instruction must target the new base | 4 |
| Testing: item 29's reproduction grows and runs, printing the same as the original | 4 |
| Testing: each refusal in Decision 6 leaves the buffer untouched (M1's share) | 4, 5 |
| QUEUE item 29's addendum: `__mh_execute_header`'s value | 5 |
| Docs: `compat/README.md`'s wording; QUEUE item 29 done | 6 |

Nothing in M1 is left without a task. M2 (the raise route, the rebase decoder) and M3 are not started.

**2. Placeholder scan.** No "TBD", no "similar to Task N", no undescribed step. `$C` in Task 6 is computed by Step 1's command. `<authoring model>` is the trailer's own wording.

**3. Type and name consistency.** `mx_insn {len, modrm, disp, displen, immlen}` and `mx_decode` (Task 1) are used with those names in Tasks 2 and 3. `MHR_CONFIRMED`, `MHR_UNSCANNABLE`, `MHR_NO_STARTS`, `MHR_UNCONFIRMED` and `mhr_confirm(buf, fsize, &bad)` (Task 3) are what Task 4's `mg_header_refs_ok` switches on. `mg_snapshot`'s `base`, `refs`, `nrefs` (Task 4) are what Task 4's repair loop, `mg_verify_refs`, and Task 5's `mg_header_symbols(buf, final_size, snap.base, grow, 1)` read. The test helpers `hr_add_lc`, `hr_code`, `hr_confirm`, `hr_push_lea` (Task 3), `plant_header_refs`, `ensure_pad_stderr`, `refs_to`, `check_grow_refuses_header_refs` (Task 4) and `build_symbol_image` (Task 5) are each defined before their first use.

**4. Review Focus.** Five inputs the spec implies and no requirement names: lookalike bytes, a reference with an immediate, AVX-512 or a jump table before a reference, a reference outside its function's section, and a refused grow's buffer. Each has its test in the owning task.

**What the spec leaves open for M1, decided here:** what the decoder refuses (Task 1); `otool -tv` for `-tV`, and the corpus (Task 2); where confirmation lives and what "exactly the candidate's" requires (Task 3); where check 5 lives, and how `mg_ensure_pad` learns the count (Task 4); an unscannable section now refuses (Task 4); the symbol (Task 5); the data pointer, not repaired (Task 6).
