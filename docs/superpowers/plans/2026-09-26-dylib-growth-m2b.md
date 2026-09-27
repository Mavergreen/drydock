# Dylib header growth M2b: the raise route — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dylib's or bundle's header pad grows: `mg_grow_header` raises everything after the load commands by the grow G, and every absolute address that names it, so that `dylib append`, `dylib insert`, `rpath replace` and every other statement that needs pad work on frameworks. Each raise verifies itself six ways, and the executable route is unchanged.

**Architecture:** `mg_grow_header` picks its route by file type (spec Decision 1). The raise shares the lowering's pre-mutation audits, snapshot, insert and base-relative walkers, and differs where the spec's Decision 2 says: segment and section geometry and `LC_ROUTINES_64` (`mg_raise_cb`), rebased pointers (`mg_raise_pointers` vouches for each before anything moves, and `mg_raise_rebased` moves them), symbols and stabs (`mg_move_symbols`), `LC_UUID` (`mg_raised_uuid`) and `LC_SEGMENT_SPLIT_INFO` (`mg_drop_split_info`). `mg_verify` gains the raise's delta, and on the raise two more checks: the image byte for byte against the original (`mg_verify_bytes`) and four oracles read by code of their own (`mg_oracles`). All in `src/grow.[ch]`; a hand-built dylib fixture in `tests/grow_test.c` carries every structure.

**Tech Stack:** C as the 10.9 clang (Apple LLVM 6.0) accepts it, with CommonCrypto's `CC_SHA256` (libSystem); CMake through shipyard; POSIX `sh`; hand-built in-memory Mach-O fixtures in `tests/grow_test.c`; a dylib and a program compiled at test time in `tests/cli_test.sh`.

**Spec:** `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`. This plan implements its M2: Decisions 1, 2, 4, 5, 6, 7 and 8, `mg_classify`'s route argument, and "Interfaces to generalise" (the snapshot's delta, `mg_verify_refs` as new base + G, the repair loop). Decision 9's rebase oracle already exists (`tests/rebase_oracle_test.sh`, from objc-methods M2), and passes. Plan M2a (`plans/2026-09-26-dylib-growth-m2a.md`) comes first: this plan starts at its last commit and uses its `mhr_confirm_each`, `mg_inside_refs_ok`, `mg_exports_ok`, `mg_binds_ok` and `MG_K_ABS`. **M3 begins where this plan ends** (Task 9 says where).

## Why M2 is two plans

M2 is fourteen tasks. M2a (5) finishes the one rule and the bind refusal on the executable route, where each is observable today, with the owner's I1 ruling in its Task 2. This plan (9) is the raise route. It can be reviewed without M2a's decisions, and M2a can ship without it.

## Rulings

Decided 2026-09-26, while this plan was under review (the controller's, on the planner's questions). No implementer needs to stop and ask. M2a records the owner's I1 ruling and the executable route's follow-up (QUEUE item 33).

1. **`LC_LOAD_UPWARD_DYLIB` is accepted on both routes** (Task 4): it names a dylib and nothing a grow moves, as `LC_LOAD_DYLIB` does. 13 of the 1,180 system dylibs and bundles carry one, and no host executable.
2. **Which checks run on which route.** Checks 2 (its load-command half), 3 and 4 run on the raise only (Tasks 6 and 7). The lowering keeps checks 1, 2's pointer and symbol halves, 5 and 6, as they were. Check 4 asks of the raised image only the oracles that held of the original.
3. **What the spec left open, settled:**
   - a symbol or stab whose value is below the base, like one naming the header, stays (ld64's closing `N_SO` holds 0);
   - the UUID is SHA-256 over the old UUID and then G as 8 bytes, little-endian, as an RFC 4122 version 4 UUID;
   - Decision 9's rebase oracle already exists (`tests/rebase_oracle_test.sh`), so M2 adds none;
   - beyond Decision 6, a raise refuses a segment whose file data starts before F, an `LC_UUID`, `LC_ROUTINES_64`, `LC_DYSYMTAB` or encryption command too short to read, and a dylib or bundle that is not x86_64;
   - and, from the review of this plan (2026-09-27), what a raise cannot move and no system image has: beside `LC_DYLD_INFO`, a table of contents, module table, or external or local relocations in `LC_DYSYMTAB` (their addresses are not rebase opcodes); and a section aligned to more than a page (G is one page, so the raise would break its alignment). Task 9's sweeps show neither fires on this host's 1,180 dylibs and bundles or its 1,128 executables;
   - code that names an address outside the image (below the base, or past its last segment) is **not** refused, though the raise moves the code G further from it. The review proposed it, on condition that it fire on no system image. Tried, it refused 19 of the 1,180 and one bundle of the executable corpus, each for a disp32 that decoding "confirms" 143 MiB or more outside the image (vImage's, for one, is a jump table after a `ret` that no data-in-code entry declares, decoded as `pushq 0x74ffffff(%rip)`), and a position-independent image names nothing outside itself RIP-relatively. So it would only ever refuse falsely;
   - which segment maps a rebased pointer is decided once, before anything moves, and the raise then moves the values the snapshot read (the review found a second pass, against the moved layout, that refused a pointer into a segment past a gap).
4. **No window of false docs.** `compat/README.md`'s rows that say a dylib is refused, and `tests/README.md`'s note that says so, change in Task 9, so they are true when this plan lands; M3 keeps the rest of the documentation.
5. **CI is a post-push check** (Task 9's last step): Task 8's `cli_test` block builds with CI's clang and runs under Rosetta, which this host cannot.

## The measurements that decide this plan

Measured 2026-09-26 on this host (10.9, ld64-241.9), with this plan's finished build (and again 2026-09-27, after the review's changes: every exit status, output checksum and message the same), over every regular file under `/usr/lib` and `/System/Library/Frameworks` with an x86_64 slice whose file type is `MH_DYLIB` or `MH_BUNDLE`: 1,180 files, 399 dylibs and 781 bundles. Each was thinned, its signature deleted, and given `rpath append`s past its pad (Task 9's sweep).

| | before (M2a) | after |
|---|---|---|
| grow, raised, and verify | 0 | **1,177** |
| refused | 1,180 (`only MH_EXECUTE can be grown`) | 3 |

- The 1,177: every one is announced "contents raised by 0x1000; new UUID", 364 also "dropped `LC_SEGMENT_SPLIT_INFO`", 37 "repaired N references to the header" (312 in all), and 1,173 have `__LINKEDIT` re-packed afterward. 1,164 of them grow with Tasks 1–3 and 5–8 alone; the other 13 (AppKit, HIToolbox, Metadata, `libdispatch`, `libdyld`, `libsystem_c` and seven more of libSystem's parts) carry `LC_LOAD_UPWARD_DYLIB`, which no grow had ever classified. Task 4 accepts it.
- The 3: CFNetwork and `libxcselect.dylib` carry `LC_LAZY_LOAD_DYLIB`, which the rewriter's ordinal renumbering refuses before any grow; MediaToolbox has code at 0x2380d0 that may address its header and that decoding does not confirm (M1's rule).
- **Raised copies run.** libz, libxml2, libsqlite3, libcurl, libc++ (18 references to its header repaired), CoreFoundation (2) and Foundation, each raised, load under `/usr/bin/gzip`, `xmllint`, `sqlite3`, `curl`, a C++ program that throws across libc++, and `plutil`; `DYLD_PRINT_LIBRARIES` names the raised copy, and the output is the original's. `info` says `resign 10.9: ok` of each; a copy signed ad hoc with 10.9's `codesign` verifies and runs.
- **The executable route is unchanged.** Over the M1 and M2a sweeps' 1,128 files, all 1,059 `MH_EXECUTE` give byte-identical output and messages; the corpus's other 69 (1 dylib and 68 bundles under `/usr/libexec`) now grow, raised and verified, where they were refused. Claude Code 2.1.282's grow is byte-identical.
- **Sparkle.** An old Sparkle.framework (ppc, i386 and x86_64; ShiftIt's and Downie's) has no `LC_DYLD_INFO` and is refused for it (Decision 6); iTerm's, OBS's and XQuartz's grow.
- **I1 on dylibs:** 1,331 RIP-relative candidates strictly inside a header in 87 of the 1,180; decoding confirms none, refutes 1,310, and cannot reach 21, all in MediaToolbox, which M1 refuses already. So M2a Task 2's ruling refuses nothing here that M1 does not.

## Global Constraints

- **Line numbers** are at M2a's last commit (`5ca0612` plus M2a). Each edit also quotes the text it anchors on, and that text is what to match: a (`:N`) is the line where the quoted text begins once the edits before it in the same task are made. `src/grow.c`'s and `tests/grow_test.c`'s numbers drift from task to task.
- **M2a comes first.** This plan applies on M2a's last commit, with M2a Task 2 as the owner ruled.
- **Build:** `B=/private/tmp/build/schmonz/drydock-native`; `/usr/local/mavergreen/bin/shipyard-cmake --build "$B" -j`. That directory is already configured. Do not configure with `--preset`. If it ever needs configuring again: `/usr/local/mavergreen/bin/shipyard-cmake -S . -B "$B" -G Ninja -DCMAKE_TOOLCHAIN_FILE=/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/MavericksToolchain.cmake -DMAVERICKS_EXPECTED_MODE=native -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64`.
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavergreen/bin/shipyard-ctest --test-dir "$B"`: 29 tests, `chained_fixups` SKIPs. A single C test runs as `"$B/grow_test"` or `"$B/script_test"`, and `cli_test` as `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B"` from the repo root. **Green at every task's end** means both the whole suite and `DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib "$B/grow_test"` ending `macho_grow_test: all cases pass`.
- **Rebuild check (clock skew here; `touch` can fail to relink).** Before every build, delete every object and the binaries you are about to run:
  ```sh
  find "$B/CMakeFiles" -name '*.o' -exec rm {} +
  rm -f "$B/libdrydockcore.a" "$B/grow_test" "$B/script_test" "$B/drydock-macho-rewrite"
  pre=$(cat "$B/.last-sha" 2>/dev/null)
  /usr/local/mavergreen/bin/shipyard-cmake --build "$B" -j
  shasum -a 256 "$B/grow_test" "$B/script_test" "$B/drydock-macho-rewrite" | tee "$B/.last-sha"
  ```
  Then confirm that the sums changed from `$pre` (a change to a test file changes only its own test's sum). A test result against an unchanged binary is not a result. Below, "build (rebuild check)" means exactly this.
- **TDD and mutation proof** for every code task. Write the test first and see it fail as the step says; then write the code. Then apply every row of the task's mutation table, each alone, and see it fail with the row's text. For each row:
  1. **Save every file the task's rows touch**, once per task: `M=$(mktemp -d -t m2b); cp src/grow.c tests/script_test.c "$M/"` (10.9's `mktemp -d` needs a template). This plan's rows touch only those two: `src/grow.c`, and Task 4's row 14 `tests/script_test.c`.
  2. **Apply the row, and confirm it applied**: `! cmp -s src/grow.c "$M/grow.c"` (or `script_test.c`), and `grep -c -F` of a distinctive line of the row's new text giving 1 (a row that only deletes: of its old text, giving 0). The rebuild check's changed sums are no such confirmation: the binaries' debug map (`N_OSO`) holds each object's modification time, so every rebuild changes the sums, whether or not the edit landed.
  3. **Rebuild (rebuild check), run, and see the row's text.**
  4. **Restore every saved file**: `cp "$M/grow.c" src/grow.c && cmp src/grow.c "$M/grow.c"`, and the same for `tests/script_test.c`; then rebuild.

  **Never `git stash` and never `git checkout --`**: restore only from the saved copies. A mutation that no test kills is a finding: add the test that kills it, in the same task. Many rows are killed first by the raise refusing itself at verification ("raise: the grow succeeds (got -1)"): that is the raise's own verification refusing its result, and each such row's own assertion stands behind it.
- **Comments are a last resort:** prefer a test, then the commit message, then a doc, then one inline sentence. No history narration, and no reference to a plan or spec from source (both are deleted once implemented).
- **Exit codes:** `EX_REFUSED` = 1 (`MR_REFUSED`), `EX_FAIL` = 2 (`MR_FAIL`). A statement never writes its input, and nothing is written on a refusal.
- **Every refusal this plan adds happens before anything is mutated**, with its reason on stderr, ending `; refusing to grow`. The split-info drop (Task 4) mutates after every refusal and before the snapshot, as the spec's Decision 4 has it.
- **Every grep negative needs a positive control.** In shell, `rc=0; cmd || rc=$?`.
- **char[16] names:** print with `%.16s`, compare with `strncmp(..., 16)`.
- **Real system files are read, never written:** every real dylib this plan grows is a copy in a scratch directory.
- **Staging and pushing:** stage explicit paths only (never `git add -A` or `.`); commit on `main`; do not push. Every commit message ends with:
  ```
  Co-Authored-By: <authoring model> <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
  ```
- **CI runs on `macos-26-arm64`** from a cross build. `grow_test`'s fixtures are hand-built bytes, the same on every host. Task 8's `cli_test` block compiles a dylib and a program with CI's clang for 10.9 x86_64 and runs the program under Rosetta; its checks are behavioural, and the announcement it matches ends at "new UUID", so a modern linker's split info would not break it. After the owner pushes, CI is a separate gate.

## Review Focus

1. **A dylib linked above base 0.** Every 10.9 system dylib is linked at 0, but a `__TEXT` at a nonzero `vmaddr` exists (the spec's appendix), and base-relative and absolute arithmetic differ only there. The fixture is built at base 0x10000000 as well as 0 (`build_dylib_at`), and every Decision 2 row is checked at 0x10000000.
2. **The edges of "content".** A pointer to base stays; to base + F, to a segment's start or a byte into it past a gap of one page or two, and to a segment's end, is raised; one strictly inside the header, or outside every segment, refuses. Which segment maps a pointer is decided before anything moves: a one-page raise opens a gap where `__ZERO + 8` was, and a gap of exactly G hid a second pass that tested the moved layout. A symbol below the base stays, and so does an export at offset 0. Pinned by `test_raise_moves_pointers_to_the_edges_of_content`, `test_raise_refuses_what_it_cannot_move`, `test_raise_leaves_a_symbol_below_the_base`, `test_raise_leaves_an_export_at_offset_0`.
3. **An export trie that widens.** A raise adds G to offsets near 0, so a 2-byte ULEB can need 3 and the trie is rebuilt and appended past `__LINKEDIT`; the byte check must allow exactly that. Pinned by `test_raise_rebuilds_a_widening_export_trie` (two pages).
4. **A segment at file offset 0 that maps no file** (a zero-fill `__ZERO`, like `__PAGEZERO` in shape) is content, not the header's segment. Pinned by `DY_ZEROSEG` in `test_grow_raises_past_what_it_can_vouch_for` and `test_raise_moves_the_segments_and_sections`.
5. **Two split infos, adjacent.** Deleting one must not skip the command that slides into its place. Pinned by `test_raise_drops_every_split_info`.
6. **What verification trusts.** Checks 1–3 and 5 read the image through the decoders the raise reads it through (`mg_rebases_read`, `mg_collect`'s walkers, `mg_symtab`, `mhr_scan`): an entry one of them misses is neither moved nor compared, and the grow passes. Their unit tests guard them, and `rebase_oracle_test` guards `mrb_decode` against `dyldinfo`. Check 4's oracles read with code of their own, and catch some such misses (Task 7's rows 20 and 21: an LSDA or personality the walker skips).

## Plan decisions at a glance

Each is repeated, with its reason, in the task that makes it.

- Task 1: the route is the file type; a dylib or bundle must be x86_64. The raise's refusals (Decision 6's, Decision 1's section rules, four short commands, `LC_DYSYMTAB`'s tables and relocations, and a section aligned past a page) come first, in `mg_raise_ok`, and until Task 2 a dylib that passes them meets the old refusal, word for word, so every existing test of it stands.
- Task 2: one `mg_grow_header`, with the raise in its own callback and walkers where Decision 2 differs from the lowering. "Names content" is "at base + F or past it"; a value exactly base is the header. Which segment maps each pointer is decided once, before anything moves. `mg_verify` derives G from how far the first section moved, and the delta from the file type the snapshot kept, so its callers do not change.
- Task 3: the stab table exactly as Decision 2 has it, with an unknown stab refused, in one predicate (`mg_stab_address`) shared by the move and the snapshot.
- Task 4: the drop is its own step, after every refusal and before the snapshot; `mg_classify` takes `raise`. `LC_LOAD_UPWARD_DYLIB` is accepted on both routes.
- Task 5: the UUID is SHA-256 (CommonCrypto) over the old UUID and G as 8 little-endian bytes.
- Task 6: check 3 compares the raised image with a copy of the original: the load commands against an expectation written independently of the patcher, and every byte from F on, less exactly what checks 1, 2 and 5 watch.
- Task 7: check 4's four oracles (initializers, lazy pointers, exports, compact unwind), read by code of their own; each is asked of the raised image only if it held of the original.
- Task 8: `dylib append`, `dylib insert` and `rpath replace` end to end, and a program running the raised dylib. `src/relations.h` gains the row, and no bit: a grow already sets `MREL_BASE_REL`.
- Task 9: the real dylibs, the sweeps, and QUEUE item 31.

## File structure

| file | responsibility | task |
|---|---|---|
| `src/grow.h` | the raise's contracts: `mg_raise_pointers` (2), what verification trusts (7), `mg_snapshot`'s `kinds`, `first`, `raise` (2), `symaddr` (3), `old`, `oldsize` (6), `oracles` (7); `mg_classify`'s `raise` (4); `mg_raised_uuid` (5); `mg_oracles`, `MG_OR_*` (7); `mg_grow_header`, `mg_ensure_pad` and `mg_verify` contracts | 1–7 |
| `src/grow.c` | `mg_raise_ok` (1); `mg_raise_cb`, `mg_raise_pointers`, `mg_raise_rebased`, `mg_move_symbols`, `mg_repair_refs`, the delta in `mg_verify` (2); `mg_stab_address`, `mg_sym_address` (3); `mg_drop_split_info`, `mg_has_cmd` (4); `mg_raised_uuid` (5); `mg_verify_bytes` (6); `mg_oracles` (7) | 1–7 |
| `src/mach_compat.h` | `N_AST` | 3 |
| `src/rewrite.c` | two comments that said a grow never changes the load commands | 4 |
| `src/relations.h` | the raise's row | 8 |
| `tests/grow_test.c` | `build_dylib_at` and the refusals (1); every Decision 2 row, the verification (2); stabs (3); split info, upward dylibs (4); the UUID (5); check 3 (6); check 4 (7) | 1–7 |
| `tests/script_test.c` | no statement can name split info | 4 |
| `tests/insert_dylib_test.sh` | its "no room" dylib now grows | 2 |
| `tests/cli_test.sh` | the raise end to end, and a comment that said a dylib cannot grow | 8 |
| `docs/superpowers/QUEUE.md`, the spec | item 31; M2 done | 9 |

`CMakeLists.txt` does not change: CommonCrypto is part of libSystem.

## How this plan was checked

Every code block below was cut from a checkpoint: M2a's checkpoints, then each task of this plan applied and committed in turn, each built in its own directory configured by the command above. A script then parsed both plans' edit instructions (every "In `file`, replace / immediately before / immediately after" block), applied them to a fresh archive of `5ca0612` task by task, and compared the tree after each task with that task's checkpoint: identical, file for file. At each checkpoint:

- the whole suite passed (29 tests, `chained_fixups` skipped), with no compiler warning, and `grow_test` passed under libgmalloc;
- each "see it fail" step was run as written, by applying only that task's test edits to the checkpoint before it: the outputs quoted are what it printed;
- every row of every mutation table (188 rows) was applied alone to that task's finished files, by a script that first required the row's old text to occur exactly once and so confirmed the edit landed, rebuilt after deleting every object and the binaries (with the sums compared), and failed with the row's text; after each row the files were restored and compared.

Task 9's numbers are from the finished build.

---

### Task 1: Choose the route, and refuse what a raise cannot vouch for

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (the file-type check in `mg_grow_header`; the `__PAGEZERO` and `__TEXT` checks; new `mg_raise_ok_cb` and `mg_raise_ok` before `int mg_grow_header(`)
- Test: `tests/grow_test.c` (`test_ensure_pad_refuses_what_cannot_grow`; `test_grow_diagnostics_name_no_program`; the fixture and tests before `int main(void) {`; calls before `if (fails)`)

**Interfaces:**
- Consumes: `mi_image_base`, `mi_each_lc`, `mi_find_segment`; in the tests, `find_lc`, `seg_named`, `find_section_struct`, `check_ensure_refuses_unchanged`, `check_grow_refuses_header_refs`.
- Produces:
  - `static int mg_raise_ok(const mi_image *im, uint64_t base, uint32_t first);` 0, or -1 having said why. Task 5 adds `LC_UUID` to it.
  - `mg_grow_header`'s local `int raise` (a dylib or bundle), which Tasks 2–7 read, and `uint64_t base` (from `mi_image_base`, which a base of 0 does not confuse, where `mi_text_base` did).
  - In `tests/grow_test.c`, the fixture every later task uses: `build_dylib_at(uint64_t base, size_t *fsize, int opts)`, `build_dylib(size_t *fsize, int opts)` (base 0), `DY_F` (0x1000), `DY_FSIZE` (0x3300), `dy_ptrs`, the options `DY_UNWIND` (compact unwind, and the `__gcc_except_tab` its LSDA names), `DY_DIC`, `DY_ROUTINES`, `DY_SPLIT`, `DY_ZEROSEG`, `DY_ZEROFAR`, and `dy_find`, `dy_section`, `dy_lc`, `dy_sect`.

**Plan decisions.**

- **The route.** `MH_EXECUTE` lowers (and must be PIE, as today); `MH_DYLIB` and `MH_BUNDLE` raise; anything else is refused, naming the three. A dylib or bundle that is not x86_64 is refused before anything else looks at it: the raise decodes its code (M1's decoder is x86-64), and the lowering's arm64 refusal speaks of lowering.
- **The refusals, before anything moves** (`mg_raise_ok`): no `LC_DYLD_INFO[_ONLY]` (only rebase opcodes list every pointer a raise moves: spec Decision 6); a thread command; an encrypted image (`cryptid` ≠ 0) or a protected segment (a raise would move encrypted pages); any section below the first content (Decision 1); a `__TEXT` section whose address and file offset differ from the base by different amounts (Decision 1); a segment other than the header's whose file data starts before the first content (the insert would split it). And, because `mi_validate` vouches for only a command's first 8 bytes: an encryption command, `LC_ROUTINES_64` or `LC_DYSYMTAB` too short to read (item 32's class).
- **What a raise cannot move, and no system image has.** `LC_DYSYMTAB`'s table of contents, module table, and external and local relocations name addresses that no rebase opcode lists, so a raise would leave them stale: beside `LC_DYLD_INFO`, any nonzero count refuses. Without `LC_DYLD_INFO`, Decision 6's refusal says so first (the old Sparkle carries both, and is refused for that), so `mg_raise_ok` judges the two together, after the walk. A section aligned to more than 2^12 bytes refuses: G is one page, and would break its alignment. Neither fires on this host's system images (Task 9); each costs one comparison.
- **Until Task 2.** A dylib or bundle that passes every check meets the refusal every dylib meets today, word for word (`ERROR: only MH_EXECUTE can be grown (filetype=6)…`), so `tests/insert_dylib_test.sh` and the other tests that pin it stand, and `test_grow_raises_past_what_it_can_vouch_for` is this task's positive control: it proves such a dylib passes every new check. Task 2 removes the refusal.
- **The fixture.** `build_dylib_at` is a small, well-formed x86_64 dylib, linkable in shape and ordinary in every way the raise does not care about, carrying one of each structure Decision 2 names; the layout is in its comment. `DY_ZEROSEG` adds a zero-fill segment at file offset 0 past a one-page gap, and `DY_ZEROFAR` moves it past a two-page gap.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, replace (`:1609`):

```c
    check_ensure_refuses_unchanged("a dylib", 0, MH_DYLIB, MH_PIE,
                                   "cannot grow a dylib or bundle");
```

with:

```c
    check_ensure_refuses_unchanged("an object file", 0, MH_OBJECT, 0,
                                   "only MH_EXECUTE, MH_DYLIB and MH_BUNDLE can be grown");
    check_ensure_refuses_unchanged("a dylib that is not x86_64", 0, MH_DYLIB, 0,
                                   "only an x86_64 dylib or bundle can be grown");
```

In `tests/grow_test.c`, replace (`:1857`):

```c
    check_ensure_refuses_unchanged("a dylib, by its prefix", 0, MH_DYLIB, MH_PIE,
                                   "^ERROR: only MH_EXECUTE can be grown (filetype=6)");
```

with:

```c
    check_ensure_refuses_unchanged("an object file, by its prefix", 0, MH_OBJECT, 0,
                                   "^ERROR: only MH_EXECUTE, MH_DYLIB and MH_BUNDLE can be grown "
                                   "(filetype=1)");
    check_ensure_refuses_unchanged("a dylib that is not x86_64, by its prefix", 0, MH_DYLIB, 0,
                                   "^ERROR: only an x86_64 dylib or bundle can be grown "
                                   "(cputype=0)");
```

In `tests/grow_test.c`, immediately before (`:4268`):

```c
int main(void) {
```

insert:

```c
/* ---- a dylib to raise ----
 * build_dylib's MH_DYLIB, x86_64, linked at DY_BASE (0, as every 10.9 system
 * dylib is; `base` moves it). F, its first content, is file and vm offset
 * 0x1000. Segment indexes: __TEXT 0, __DATA 1, __LINKEDIT 2.
 *   __TEXT      file [0, 0x2000)
 *     __text          0x1000: f1: lea base(%rip), %rax; ret.  f2 (0x1010): push; ret
 *     __stub_helper   0x1100: nops
 *     __gcc_except_tab 0x1180 (DY_UNWIND): f2's LSDA
 *     __unwind_info   0x1800 (DY_UNWIND): f1 and f2, f2 with an LSDA
 *   __DATA      file [0x2000, 0x3000), vm to 0x4000
 *     __data          0x2000: dy_ptrs, three rebased pointers
 *     __mod_init_func 0x2030: f2
 *     __la_symbol_ptr 0x2038: __stub_helper
 *     __got           0x2040: bound to _x
 *     __bss           0x3000, zero-fill
 *   __LINKEDIT  file [0x3000, DY_FSIZE), vm 0x4000
 *     rebase 0x3000, bind 0x3010, export trie 0x3040 (_f1, _f2, _d),
 *     function starts 0x3080 (f1, f2), data in code 0x3090 (DY_DIC),
 *     symbols 0x30a0, strings 0x3200
 *   __ZERO      (DY_ZEROSEG) vm [0x6000, 0x7000), no file data; with
 *               DY_ZEROFAR, [0x7000, 0x8000), two pages past __LINKEDIT */
#define DY_F      0x1000u
#define DY_FSIZE  0x3300u
#define DY_UNWIND 1
#define DY_DIC    2
#define DY_ROUTINES 4
#define DY_SPLIT  8
#define DY_ZEROSEG 16    /* a zero-fill segment, __ZERO, at vm 0x6000: file offset 0, no file data */
#define DY_ZEROFAR 128   /* __ZERO at 0x7000 */
static const uint64_t dy_ptrs[3] = { 0, 0x1010, 0x2020 };   /* the header, f2, _d */

static struct section_64 *dy_sect(struct section_64 *s, const char *seg, const char *name,
                                  uint64_t addr, uint64_t size, uint32_t off, uint32_t flags) {
    strncpy(s->segname, seg, sizeof s->segname);
    strncpy(s->sectname, name, sizeof s->sectname);
    s->addr = addr;
    s->size = size;
    s->offset = off;
    s->flags = flags;
    return s + 1;
}

static uint8_t *dy_lc(uint8_t **lc, struct mach_header_64 *h, uint32_t cmd, uint32_t size) {
    struct load_command *l = (struct load_command *)*lc;
    uint8_t *at = *lc;
    l->cmd = cmd;
    l->cmdsize = size;
    *lc += size;
    h->ncmds++;
    h->sizeofcmds += size;
    return at;
}

static uint8_t *build_dylib_at(uint64_t base, size_t *fsize, int opts) {
    static const uint8_t rebase[16] = { 0x11, 0x21, 0x00, 0x53, 0x21, 0x30, 0x52, 0x00 };
    static const uint8_t bind[16] = { 0x11, 0x40, '_', 'x', 0, 0x51, 0x71, 0x40, 0x90, 0x00 };
    static const uint8_t trie[31] = {
        0x00, 0x03, '_', 'f', '1', 0, 16, '_', 'f', '2', 0, 21, '_', 'd', 0, 26,
        0x03, 0x00, 0x80, 0x20, 0x00,      /* _f1: 0x1000 */
        0x03, 0x00, 0x90, 0x20, 0x00,      /* _f2: 0x1010 */
        0x03, 0x00, 0xa0, 0x40, 0x00 };    /* _d:  0x2020 */
    static const uint8_t starts[8] = { 0x80, 0x20, 0x10, 0x00 };
    static const uint8_t dic[8] = { 0x20, 0x10, 0, 0, 0x08, 0x00, 0x01, 0x00 };  /* 0x1020, 8 */
    static const char strs[] = "\0__mh_dylib_header\0_f1\0_f2\0_d\0_x";
    uint8_t *buf = (uint8_t *)calloc(1, DY_FSIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *lc = (uint8_t *)(h + 1);
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_DYLIB;
    h->flags = MH_DYLDLINK | MH_TWOLEVEL | MH_NOUNDEFS;

    int ntext = (opts & DY_UNWIND) ? 4 : 2;
    struct segment_command_64 *tx = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
        sizeof *tx + ntext * sizeof(struct section_64));
    strcpy(tx->segname, "__TEXT");
    tx->vmaddr = base;
    tx->vmsize = tx->filesize = 0x2000;
    tx->maxprot = tx->initprot = VM_PROT_READ | VM_PROT_EXECUTE;
    tx->nsects = ntext;
    struct section_64 *s = (struct section_64 *)(tx + 1);
    s = dy_sect(s, "__TEXT", "__text", base + 0x1000, 0x100, 0x1000,
                S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
    s = dy_sect(s, "__TEXT", "__stub_helper", base + 0x1100, 0x10, 0x1100,
                S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
    if (opts & DY_UNWIND) {
        s = dy_sect(s, "__TEXT", "__gcc_except_tab", base + 0x1180, 0x10, 0x1180, 0);
        s = dy_sect(s, "__TEXT", "__unwind_info", base + 0x1800, 0x60, 0x1800, 0);
    }

    struct segment_command_64 *da = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
        sizeof *da + 5 * sizeof(struct section_64));
    strcpy(da->segname, "__DATA");
    da->vmaddr = base + 0x2000;
    da->vmsize = 0x2000;
    da->fileoff = 0x2000;
    da->filesize = 0x1000;
    da->maxprot = da->initprot = VM_PROT_READ | VM_PROT_WRITE;
    da->nsects = 5;
    s = (struct section_64 *)(da + 1);
    s = dy_sect(s, "__DATA", "__data", base + 0x2000, 0x30, 0x2000, 0);
    s = dy_sect(s, "__DATA", "__mod_init_func", base + 0x2030, 8, 0x2030, S_MOD_INIT_FUNC_POINTERS);
    s = dy_sect(s, "__DATA", "__la_symbol_ptr", base + 0x2038, 8, 0x2038, S_LAZY_SYMBOL_POINTERS);
    s = dy_sect(s, "__DATA", "__got", base + 0x2040, 8, 0x2040, S_NON_LAZY_SYMBOL_POINTERS);
    s = dy_sect(s, "__DATA", "__bss", base + 0x3000, 0x100, 0, S_ZEROFILL);

    struct segment_command_64 *le = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
        sizeof *le);
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = base + 0x4000;
    le->vmsize = 0x1000;
    le->fileoff = 0x3000;
    le->filesize = DY_FSIZE - 0x3000;
    le->maxprot = le->initprot = VM_PROT_READ;

    if (opts & DY_ZEROSEG) {
        struct segment_command_64 *z = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
            sizeof *z + sizeof(struct section_64));
        strcpy(z->segname, "__ZERO");
        z->vmaddr = base + ((opts & DY_ZEROFAR) ? 0x7000 : 0x6000);
        z->vmsize = 0x1000;
        z->maxprot = z->initprot = VM_PROT_READ | VM_PROT_WRITE;
        z->nsects = 1;
        dy_sect((struct section_64 *)(z + 1), "__ZERO", "__zero", z->vmaddr, 0x1000, 0,
                S_ZEROFILL);
    }
    struct dylib_command *id = (struct dylib_command *)dy_lc(&lc, h, LC_ID_DYLIB, 48);
    id->dylib.name.offset = sizeof *id;
    strcpy((char *)(id + 1), "@rpath/libdy.dylib");
    struct dylib_command *sys = (struct dylib_command *)dy_lc(&lc, h, LC_LOAD_DYLIB, 56);
    sys->dylib.name.offset = sizeof *sys;
    strcpy((char *)(sys + 1), "/usr/lib/libSystem.B.dylib");

    struct dyld_info_command *di = (struct dyld_info_command *)dy_lc(&lc, h, LC_DYLD_INFO_ONLY,
                                                                    sizeof *di);
    di->rebase_off = 0x3000;
    di->rebase_size = 8;
    di->bind_off = 0x3010;
    di->bind_size = 16;
    di->export_off = 0x3040;
    di->export_size = sizeof trie;

    struct symtab_command *st = (struct symtab_command *)dy_lc(&lc, h, LC_SYMTAB, sizeof *st);
    st->symoff = 0x30a0;
    st->nsyms = 5;
    st->stroff = 0x3200;
    st->strsize = sizeof strs;
    struct dysymtab_command *ds = (struct dysymtab_command *)dy_lc(&lc, h, LC_DYSYMTAB, sizeof *ds);
    ds->nlocalsym = 1;
    ds->iextdefsym = 1;
    ds->nextdefsym = 3;
    ds->iundefsym = 4;
    ds->nundefsym = 1;

    struct uuid_command *u = (struct uuid_command *)dy_lc(&lc, h, LC_UUID, sizeof *u);
    for (int i = 0; i < 16; i++) u->uuid[i] = (uint8_t)(0x10 + i);

    struct linkedit_data_command *fs = (struct linkedit_data_command *)dy_lc(&lc, h,
        LC_FUNCTION_STARTS, sizeof *fs);
    fs->dataoff = 0x3080;
    fs->datasize = sizeof starts;
    if (opts & DY_DIC) {
        struct linkedit_data_command *dc = (struct linkedit_data_command *)dy_lc(&lc, h,
            LC_DATA_IN_CODE, sizeof *dc);
        dc->dataoff = 0x3090;
        dc->datasize = sizeof dic;
        memcpy(buf + 0x3090, dic, sizeof dic);
    }
    if (opts & DY_SPLIT) {
        struct linkedit_data_command *sp = (struct linkedit_data_command *)dy_lc(&lc, h,
            LC_SEGMENT_SPLIT_INFO, sizeof *sp);
        sp->dataoff = 0x3098;
        sp->datasize = 8;
        memset(buf + 0x3098, 0x5a, 8);
    }
    if (opts & DY_ROUTINES) {
        struct routines_command_64 *rt = (struct routines_command_64 *)dy_lc(&lc, h,
            LC_ROUTINES_64, sizeof *rt);
        rt->init_address = base + 0x1010;
    }

    /* f1: lea base(%rip), %rax; ret.  f2: push %rbp; ret. */
    memset(buf + 0x1000, 0x90, 0x110);
    buf[0x1000] = 0x48; buf[0x1001] = 0x8d; buf[0x1002] = 0x05;
    int32_t disp = (int32_t)(int64_t)(base - (base + 0x1007));
    memcpy(buf + 0x1003, &disp, sizeof disp);
    buf[0x1007] = 0xc3;
    buf[0x1010] = 0x55; buf[0x1011] = 0xc3;
    if (opts & DY_UNWIND) {
        uint32_t *uw = (uint32_t *)(buf + 0x1800);
        uw[0] = 1; uw[3] = 28; uw[4] = 1; uw[5] = 32; uw[6] = 2;
        uw[7] = 0x2040;                             /* personality: the __got slot */
        uw[8] = 0x1000; uw[9] = 0x48; uw[10] = 56;  /* f1; its page; LSDA from 56 */
        uw[11] = 0x1100; uw[12] = 0; uw[13] = 64;   /* the sentinel: the end of f2 */
        uw[14] = 0x1010; uw[15] = 0x1180;           /* f2's LSDA, in __gcc_except_tab */
        uw[18] = 3; ((uint16_t *)(buf + 0x1800 + 0x48))[2] = 8;
        ((uint16_t *)(buf + 0x1800 + 0x48))[3] = 2;
        uw[20] = 0x00000000u | (1u << 24); uw[21] = 0x00000010u | (1u << 24);
    }

    uint64_t ptrs[3];
    for (int i = 0; i < 3; i++) ptrs[i] = base + dy_ptrs[i];
    memcpy(buf + 0x2000, ptrs, sizeof ptrs);
    uint64_t init = base + 0x1010, lazy = base + 0x1100;
    memcpy(buf + 0x2030, &init, 8);
    memcpy(buf + 0x2038, &lazy, 8);

    memcpy(buf + 0x3000, rebase, sizeof rebase);
    memcpy(buf + 0x3010, bind, sizeof bind);
    memcpy(buf + 0x3040, trie, sizeof trie);
    memcpy(buf + 0x3080, starts, sizeof starts);
    struct nlist_64 *nl = (struct nlist_64 *)(buf + 0x30a0);
    static const struct { uint32_t strx; uint8_t type, sect; uint64_t value; } syms[5] = {
        { 1, N_SECT | N_PEXT, 1, 0 }, { 19, N_SECT | N_EXT, 1, 0x1000 },
        { 23, N_SECT | N_EXT, 1, 0x1010 }, { 27, N_SECT | N_EXT, 0, 0x2020 },
        { 30, N_UNDF | N_EXT, 0, 0 } };
    for (int i = 0; i < 5; i++) {
        nl[i].n_un.n_strx = syms[i].strx;
        nl[i].n_type = syms[i].type;
        nl[i].n_sect = i == 3 ? (uint8_t)(ntext + 1) : syms[i].sect;
        nl[i].n_value = syms[i].type == (N_UNDF | N_EXT) ? 0 : base + syms[i].value;
    }
    memcpy(buf + 0x3200, strs, sizeof strs);
    *fsize = DY_FSIZE;
    return buf;
}

static uint8_t *build_dylib(size_t *fsize, int opts) { return build_dylib_at(0, fsize, opts); }

/* The dylib's `cmd` command, or NULL. */
static uint8_t *dy_find(uint8_t *buf, uint32_t cmd) { return (uint8_t *)find_lc(buf, DY_FSIZE, cmd); }
static struct section_64 *dy_section(uint8_t *buf, const char *seg, const char *name) {
    mi_image im;
    return mi_wrap(buf, DY_FSIZE, &im) == 0 ? mi_find_section(&im, seg, name) : NULL;
}

/* Each way a raise refuses before it changes anything: `poke` breaks
 * build_dylib's image, and the refusal must say `why`. */
typedef void (*dy_poke)(uint8_t *buf);
static void dy_no_info(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_DYLD_INFO_ONLY))->cmd = LC_SOURCE_VERSION; }
static void dy_unixthread(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_UUID))->cmd = LC_UNIXTHREAD; }
static void dy_thread(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_UUID))->cmd = LC_THREAD; }
static void dy_encrypted(uint8_t *buf) {
    struct encryption_info_command_64 *e = (struct encryption_info_command_64 *)dy_find(buf, LC_UUID);
    e->cmd = LC_ENCRYPTION_INFO_64;
    e->cryptid = 1;
}
static void dy_short_crypt(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_ENCRYPTION_INFO; }
static void dy_short_routines(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_ROUTINES_64; }
static void dy_protected(uint8_t *buf) { seg_named(buf, DY_FSIZE, "__DATA")->flags |= SG_PROTECTED_VERSION_1; }
static void dy_misplaced(uint8_t *buf) { dy_section(buf, "__TEXT", "__stub_helper")->addr += 0x10; }
static void dy_below(uint8_t *buf) {
    dy_section(buf, "__DATA", "__bss")->addr = seg_named(buf, DY_FSIZE, "__TEXT")->vmaddr + 0xfff;
}
static void dy_early(uint8_t *buf) { seg_named(buf, DY_FSIZE, "__DATA")->fileoff = 0xfff; }
static void dy_short_dysymtab(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_DYSYMTAB; }
static struct dysymtab_command *dy_dysymtab(uint8_t *buf) { return (struct dysymtab_command *)dy_find(buf, LC_DYSYMTAB); }
static void dy_toc(uint8_t *buf) { dy_dysymtab(buf)->ntoc = 1; }
static void dy_modtab(uint8_t *buf) { dy_dysymtab(buf)->nmodtab = 1; }
static void dy_extrel(uint8_t *buf) { dy_dysymtab(buf)->nextrel = 1; }
static void dy_locrel(uint8_t *buf) { dy_dysymtab(buf)->nlocrel = 1; }
static void dy_no_info_locrel(uint8_t *buf) { dy_no_info(buf); dy_locrel(buf); }
static void dy_overaligned(uint8_t *buf) { dy_section(buf, "__DATA", "__data")->align = 13; }
static void dy_not_x86_64(uint8_t *buf) { ((struct mach_header_64 *)buf)->cputype = CPU_TYPE_POWERPC64; }
static const struct { const char *what; dy_poke poke; const char *why; } dy_unraisable[] = {
    { "no LC_DYLD_INFO", dy_no_info,
      "ERROR: a dylib or bundle with no LC_DYLD_INFO[_ONLY]: only its rebase opcodes list every "
      "pointer a raise moves; refusing to grow" },
    { "LC_UNIXTHREAD", dy_unixthread,
      "ERROR: a dylib or bundle with a thread command (0x5), whose register state a raise does "
      "not move; refusing to grow" },
    { "LC_THREAD", dy_thread, "ERROR: a dylib or bundle with a thread command (0x4)" },
    { "an encrypted image", dy_encrypted,
      "ERROR: the image is encrypted (cryptid 1), and a raise would move its encrypted pages; "
      "refusing to grow" },
    { "a short encryption command", dy_short_crypt,
      "ERROR: an encryption command is 16 bytes, too short to hold cryptid; refusing to grow" },
    { "a short LC_ROUTINES_64", dy_short_routines,
      "ERROR: LC_ROUTINES_64 is 16 bytes, too short to hold init_address; refusing to grow" },
    { "a protected segment", dy_protected,
      "ERROR: segment __DATA is protected (SG_PROTECTED_VERSION_1), and a raise would move its "
      "encrypted pages; refusing to grow" },
    { "a __TEXT section whose address and offset disagree", dy_misplaced,
      "ERROR: section __TEXT,__stub_helper lies 0x1110 past the image base in memory and 0x1100 "
      "in the file; refusing to grow" },
    { "a section below the first content", dy_below,
      "ERROR: section __DATA,__bss lies at 0xfff, below the first content at 0x1000; refusing "
      "to grow" },
    { "a segment whose file data starts before the first content", dy_early,
      "ERROR: segment __DATA's file data starts at 4095, before the first content at 4096; "
      "refusing to grow" },
    { "a short LC_DYSYMTAB", dy_short_dysymtab,
      "ERROR: LC_DYSYMTAB is 16 bytes, too short to hold its tables' counts; refusing to grow" },
    { "a table of contents", dy_toc,
      "ERROR: LC_DYSYMTAB lists 1 table-of-contents entries, 0 modules, 0 external and 0 local "
      "relocations beside LC_DYLD_INFO, whose addresses a raise does not move; refusing to grow" },
    { "a module table", dy_modtab, "ERROR: LC_DYSYMTAB lists 0 table-of-contents entries, 1 modules" },
    { "external relocations", dy_extrel, "0 modules, 1 external and 0 local relocations" },
    { "local relocations", dy_locrel, "0 external and 1 local relocations" },
    { "local relocations and no LC_DYLD_INFO", dy_no_info_locrel,
      "ERROR: a dylib or bundle with no LC_DYLD_INFO[_ONLY]: only its rebase opcodes" },
    { "a section aligned past a page", dy_overaligned,
      "ERROR: section __DATA,__data is aligned to 2^13 bytes, more than the page a raise moves it "
      "by; refusing to grow" },
    { "a dylib that is not x86_64", dy_not_x86_64,
      "ERROR: only an x86_64 dylib or bundle can be grown (cputype=0x1000012): its code is "
      "decoded to find what addresses its header" },
};

static void test_grow_refuses_what_it_cannot_raise(void) {
    for (size_t i = 0; i < sizeof dy_unraisable / sizeof dy_unraisable[0]; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib(&fsize, 0);
        dy_unraisable[i].poke(buf);
        check_grow_refuses_header_refs(dy_unraisable[i].what, buf, fsize, dy_unraisable[i].why);
    }
    size_t fsize;
    uint8_t *buf = build_dylib_at(0x10000000, &fsize, 0);
    dy_below(buf);
    check_grow_refuses_header_refs("a section below the first content, above base 0", buf, fsize,
        "ERROR: section __DATA,__bss lies at 0x10000fff, below the first content at 0x10001000; "
        "refusing to grow");
}

/* An unencrypted image's encryption command, an LC_ROUTINES_64 long enough
 * to read, and a zero-fill segment at file offset 0 are no reason to refuse,
 * at base 0 or above it: such a dylib or bundle reaches the refusal every
 * dylib and bundle meets until the raise is written. */
static void test_grow_raises_past_what_it_can_vouch_for(void) {
    static const uint32_t filetype[3] = { MH_DYLIB, MH_BUNDLE, MH_DYLIB };
    static const uint64_t base[3] = { 0, 0, 0x10000000 };
    for (int i = 0; i < 3; i++) {
        size_t fsize;
        char needle[64];
        uint8_t *buf = build_dylib_at(base[i], &fsize, DY_ROUTINES | DY_ZEROSEG);
        struct encryption_info_command_64 *e =
            (struct encryption_info_command_64 *)dy_find(buf, LC_UUID);
        ((struct mach_header_64 *)buf)->filetype = filetype[i];
        e->cmd = LC_ENCRYPTION_INFO_64;
        e->cryptoff = e->cryptsize = e->cryptid = 0;
        dy_section(buf, "__DATA", "__data")->align = 12;
        snprintf(needle, sizeof needle, "ERROR: only MH_EXECUTE can be grown (filetype=%u)",
                 filetype[i]);
        check_grow_refuses_header_refs("a dylib or bundle a raise can vouch for", buf, fsize,
                                       needle);
    }
}

```

In `tests/grow_test.c`, immediately after (`:4761`):

```c
    test_grow_accepts_binds_outside_the_header_segment();
```

insert:

```c
    test_grow_refuses_what_it_cannot_raise();
    test_grow_raises_past_what_it_can_vouch_for();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: exit 1, and 23 `FAIL:` lines, every one a refusal that says today's words (`only MH_EXECUTE can be grown`) instead of the new: the four `ensure_pad on an object file …` and `… a dylib that is not x86_64 …` lines, then one "the refusal says" line for each of the eighteen rows of `dy_unraisable` and the base-0x10000000 row. The last is:

```
FAIL: a section below the first content, above base 0: the refusal says 'ERROR: section __DATA,__bss lies at 0x10000fff, below the first content at 0x10001000; refusing to grow'
```

`test_grow_raises_past_what_it_can_vouch_for` passes already: it expects today's refusal.

- [ ] **Step 3: Choose the route, and write the raise's refusals**

In `src/grow.c`, immediately before (`:1609`):

```c
int mg_grow_header(uint8_t **pbuf, size_t *pfsize, uint32_t grow_req) {
```

insert:

```c
/* mg_raise_ok's mi_each_lc callback: says why, and stops, at the first load
 * command a raise cannot vouch for; notes LC_DYLD_INFO and LC_DYSYMTAB's
 * counts, which mg_raise_ok judges together. */
struct mg_raise_ctx { uint64_t base; uint32_t first; int di; uint32_t toc, mod, ext, loc; };
static int mg_raise_ok_cb(const struct load_command *lc, void *ctx_) {
    struct mg_raise_ctx *c = (struct mg_raise_ctx *)ctx_;
    switch (lc->cmd) {
    case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY:
        c->di = 1;
        return 0;
    case LC_UNIXTHREAD: case LC_THREAD:
        fprintf(stderr, "ERROR: a dylib or bundle with a thread command (%#x), whose register "
                        "state a raise does not move; refusing to grow\n", lc->cmd);
        return 1;
    case LC_ENCRYPTION_INFO: case LC_ENCRYPTION_INFO_64: {
        const struct encryption_info_command *e = (const struct encryption_info_command *)lc;
        if (lc->cmdsize < sizeof *e) {
            fprintf(stderr, "ERROR: an encryption command is %u bytes, too short to hold "
                            "cryptid; refusing to grow\n", lc->cmdsize);
            return 1;
        }
        if (!e->cryptid) return 0;
        fprintf(stderr, "ERROR: the image is encrypted (cryptid %u), and a raise would move "
                        "its encrypted pages; refusing to grow\n", e->cryptid);
        return 1;
    }
    case LC_DYSYMTAB: {
        const struct dysymtab_command *d = (const struct dysymtab_command *)lc;
        if (lc->cmdsize < sizeof *d) {
            fprintf(stderr, "ERROR: LC_DYSYMTAB is %u bytes, too short to hold its tables' "
                            "counts; refusing to grow\n", lc->cmdsize);
            return 1;
        }
        c->toc = d->ntoc;
        c->mod = d->nmodtab;
        c->ext = d->nextrel;
        c->loc = d->nlocrel;
        return 0;
    }
    case LC_ROUTINES_64:
        if (lc->cmdsize >= sizeof(struct routines_command_64)) return 0;
        fprintf(stderr, "ERROR: LC_ROUTINES_64 is %u bytes, too short to hold init_address; "
                        "refusing to grow\n", lc->cmdsize);
        return 1;
    case LC_SEGMENT_64: {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *s = (const struct section_64 *)(seg + 1);
        int header = seg->fileoff == 0 && seg->filesize > 0;
        if (seg->flags & SG_PROTECTED_VERSION_1) {
            fprintf(stderr, "ERROR: segment %.16s is protected (SG_PROTECTED_VERSION_1), and a "
                            "raise would move its encrypted pages; refusing to grow\n",
                    seg->segname);
            return 1;
        }
        if (!header && seg->filesize > 0 && seg->fileoff < c->first) {
            fprintf(stderr, "ERROR: segment %.16s's file data starts at %llu, before the first "
                            "content at %u; refusing to grow\n", seg->segname,
                    (unsigned long long)seg->fileoff, c->first);
            return 1;
        }
        for (uint32_t j = 0; j < seg->nsects; j++) {
            if (s[j].align > 12) {
                fprintf(stderr, "ERROR: section %.16s,%.16s is aligned to 2^%u bytes, more than "
                                "the page a raise moves it by; refusing to grow\n", s[j].segname,
                        s[j].sectname, s[j].align);
                return 1;
            }
            if (s[j].addr < c->base + c->first) {
                fprintf(stderr, "ERROR: section %.16s,%.16s lies at %#llx, below the first "
                                "content at %#llx; refusing to grow\n", s[j].segname,
                        s[j].sectname, (unsigned long long)s[j].addr,
                        (unsigned long long)(c->base + c->first));
                return 1;
            }
            if (header && s[j].addr - c->base != s[j].offset) {
                fprintf(stderr, "ERROR: section %.16s,%.16s lies %#llx past the image base in "
                                "memory and %#x in the file; refusing to grow\n", s[j].segname,
                        s[j].sectname, (unsigned long long)(s[j].addr - c->base), s[j].offset);
                return 1;
            }
        }
        return 0;
    }
    }
    return 0;
}

/* 0 when a raise can vouch for every load command of the dylib or bundle
 * `im`, whose image base is `base` and first content base + `first`; else
 * -1, having said why. */
static int mg_raise_ok(const mi_image *im, uint64_t base, uint32_t first) {
    struct mg_raise_ctx c = { base, first, 0, 0, 0, 0, 0 };
    if (!mi_each_lc(im, mg_raise_ok_cb, &c)) return -1;
    if (!c.di) {
        fprintf(stderr, "ERROR: a dylib or bundle with no LC_DYLD_INFO[_ONLY]: only its rebase "
                        "opcodes list every pointer a raise moves; refusing to grow\n");
        return -1;
    }
    if (!(c.toc | c.mod | c.ext | c.loc)) return 0;
    fprintf(stderr, "ERROR: LC_DYSYMTAB lists %u table-of-contents entries, %u modules, %u "
                    "external and %u local relocations beside LC_DYLD_INFO, whose addresses a "
                    "raise does not move; refusing to grow\n", c.toc, c.mod, c.ext, c.loc);
    return -1;
}

```

In `src/grow.c`, replace (`:1751`):

```c
    if (hdr->filetype != MH_EXECUTE) {
        fprintf(stderr, "ERROR: only MH_EXECUTE can be grown (filetype=%u): growing "
                        "lowers the image base into __PAGEZERO, and a dylib or bundle has "
                        "none. This tool cannot grow a dylib or bundle.\n", hdr->filetype);
        return -1;
    }
    if (!(hdr->flags & MH_PIE)) {
```

with:

```c
    int raise = hdr->filetype == MH_DYLIB || hdr->filetype == MH_BUNDLE;
    if (hdr->filetype != MH_EXECUTE && !raise) {
        fprintf(stderr, "ERROR: only MH_EXECUTE, MH_DYLIB and MH_BUNDLE can be grown "
                        "(filetype=%u)\n", hdr->filetype);
        return -1;
    }
    if (raise && hdr->cputype != CPU_TYPE_X86_64) {
        fprintf(stderr, "ERROR: only an x86_64 dylib or bundle can be grown (cputype=%#x): "
                        "its code is decoded to find what addresses its header\n",
                hdr->cputype);
        return -1;
    }
    if (!raise && !(hdr->flags & MH_PIE)) {
```

In `src/grow.c`, replace (`:1826`):

```c
    if (!mi_text_base(&find_im)) {
        fprintf(stderr, "ERROR: no __TEXT-like segment holds the header\n");
        return -1;
    }
    if (!pagezero || pagezero->vmsize < grow) {
```

with:

```c
    uint64_t base;
    if (mi_image_base(&find_im, &base) != 0) {
        fprintf(stderr, "ERROR: no __TEXT-like segment holds the header\n");
        return -1;
    }
    if (raise) {
        if (mg_raise_ok(&find_im, base, insert) != 0) return -1;
        fprintf(stderr, "ERROR: only MH_EXECUTE can be grown (filetype=%u): growing "
                        "lowers the image base into __PAGEZERO, and a dylib or bundle has "
                        "none. This tool cannot grow a dylib or bundle.\n", hdr->filetype);
        return -1;
    } else if (!pagezero || pagezero->vmsize < grow) {
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    int raise = hdr->filetype == MH_DYLIB \|\| hdr->filetype == MH_BUNDLE;` | `    int raise = hdr->filetype == MH_DYLIB;` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says 'ERROR: only MH_EXECUTE can be grown (filetype=8)'` |
| 2 | `    if (hdr->filetype != MH_EXECUTE && !raise) {` | `    if (0) {` | `FAIL: ensure_pad on an object file: the refusal says` |
| 3 | `    if (raise && hdr->cputype != CPU_TYPE_X86_64) {` | `    if (0) {` | `FAIL: a dylib that is not x86_64: the refusal says` |
| 4 | `    if (!raise && !(hdr->flags & MH_PIE)) {` | `    if (!(hdr->flags & MH_PIE)) {` | `FAIL: no LC_DYLD_INFO: the refusal says` |
| 5 | `        c->di = 1;`<br>`        return 0;` | `        return 0;` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |
| 6 | `    case LC_UNIXTHREAD: case LC_THREAD:` | `    case LC_THREAD:` | `FAIL: LC_UNIXTHREAD: the refusal says` |
| 7 | `    case LC_UNIXTHREAD: case LC_THREAD:` | `    case LC_UNIXTHREAD:` | `FAIL: LC_THREAD: the refusal says` |
| 8 | `    case LC_ENCRYPTION_INFO: case LC_ENCRYPTION_INFO_64: {` | `    case LC_ENCRYPTION_INFO: {` | `FAIL: an encrypted image: the refusal says` |
| 9 | `    case LC_ENCRYPTION_INFO: case LC_ENCRYPTION_INFO_64: {` | `    case LC_ENCRYPTION_INFO_64: {` | `FAIL: a short encryption command: the refusal says` |
| 10 | `        if (lc->cmdsize < sizeof *e) {` | `        if (0) {` | `FAIL: a short encryption command: the refusal says` |
| 11 | `        if (!e->cryptid) return 0;` | `        if (1) return 0;` | `FAIL: an encrypted image: the refusal says` |
| 12 | `        if (!e->cryptid) return 0;` | `        if (0) return 0;` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |
| 13 | `        if (lc->cmdsize >= sizeof(struct routines_command_64)) return 0;` | `        return 0;` | `FAIL: a short LC_ROUTINES_64: the refusal says` |
| 14 | `        if (lc->cmdsize >= sizeof(struct routines_command_64)) return 0;` | `        if (lc->cmdsize > sizeof(struct routines_command_64)) return 0;` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |
| 15 | `        if (seg->flags & SG_PROTECTED_VERSION_1) {` | `        if (0) {` | `FAIL: a protected segment: the refusal says` |
| 16 | `        int header = seg->fileoff == 0 && seg->filesize > 0;` | `        int header = seg->fileoff == 0;` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |
| 17 | `        if (!header && seg->filesize > 0 && seg->fileoff < c->first) {` | `        if (!header && seg->fileoff < c->first) {` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |
| 18 | `        if (!header && seg->filesize > 0 && seg->fileoff < c->first) {` | `        if (0) {` | `FAIL: a segment whose file data starts before the first content: the refusal says` |
| 19 | `            if (s[j].addr < c->base + c->first) {` | `            if (s[j].addr <= c->base + c->first) {` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |
| 20 | `            if (s[j].addr < c->base + c->first) {` | `            if (s[j].addr < c->first) {` | `FAIL: a section below the first content, above base 0: the refusal says` |
| 21 | `            if (header && s[j].addr - c->base != s[j].offset) {` | `            if (s[j].addr - c->base != s[j].offset) {` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |
| 22 | `            if (header && s[j].addr - c->base != s[j].offset) {` | `            if (header && s[j].addr != s[j].offset) {` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |
| 23 | `    if (!c.di) {` | `    if (0) {` | `FAIL: no LC_DYLD_INFO: the refusal says` |
| 24 | `    case LC_DYSYMTAB: {` | `    case 0x7fffffff: {` | `FAIL: a table of contents: the refusal says` |
| 25 | `        if (lc->cmdsize < sizeof *d) {`<br>`            fprintf(stderr, "ERROR: LC_DYSYMTAB is` | `        if (0) {`<br>`            fprintf(stderr, "ERROR: LC_DYSYMTAB is` | `FAIL: a short LC_DYSYMTAB: the refusal says` |
| 26 | `    if (!(c.toc \| c.mod \| c.ext \| c.loc)) return 0;` | `    if (!(c.mod \| c.ext \| c.loc)) return 0;` | `FAIL: a table of contents: the refusal says` |
| 27 | `    if (!(c.toc \| c.mod \| c.ext \| c.loc)) return 0;` | `    if (!(c.toc \| c.ext \| c.loc)) return 0;` | `FAIL: a module table: the refusal says` |
| 28 | `    if (!(c.toc \| c.mod \| c.ext \| c.loc)) return 0;` | `    if (!(c.toc \| c.mod \| c.loc)) return 0;` | `FAIL: external relocations: the refusal says` |
| 29 | `    if (!(c.toc \| c.mod \| c.ext \| c.loc)) return 0;` | `    if (!(c.toc \| c.mod \| c.ext)) return 0;` | `FAIL: local relocations: the refusal says` |
| 30 | `    if (!(c.toc \| c.mod \| c.ext \| c.loc)) return 0;` | `    return 0;` | `FAIL: a table of contents: the refusal says` |
| 31 | `        c->toc = d->ntoc;` | *(delete it)* | `FAIL: a table of contents: the refusal says` |
| 32 | `        c->mod = d->nmodtab;` | *(delete it)* | `FAIL: a module table: the refusal says` |
| 33 | `        c->ext = d->nextrel;` | *(delete it)* | `FAIL: external relocations: the refusal says` |
| 34 | `        c->loc = d->nlocrel;` | *(delete it)* | `FAIL: local relocations: the refusal says` |
| 35 | `    if (!c.di) {` | `    if (!c.di && !(c.toc \| c.mod \| c.ext \| c.loc)) {` | `FAIL: local relocations and no LC_DYLD_INFO: the refusal says` |
| 36 | `            if (s[j].align > 12) {` | `            if (s[j].align > 13) {` | `FAIL: a section aligned past a page: the refusal says` |
| 37 | `            if (s[j].align > 12) {` | `            if (s[j].align >= 12) {` | `FAIL: a dylib or bundle a raise can vouch for: the refusal says` |

A row removing the `return -1` after `mg_raise_ok` survives here, because the old refusal follows it; it is Task 2's row 22.

- [ ] **Step 6: Commit**

```bash
git add src/grow.c tests/grow_test.c
git commit -m "feat(grow): choose the route by file type, and refuse what a raise cannot vouch for

A dylib or bundle will be raised, not lowered. Before anything moves, the
raise refuses what it could not vouch for: no LC_DYLD_INFO, a thread
command, encryption, a protected segment, a section below the first
content, a __TEXT section whose address and offset disagree, a segment
whose file data starts before the first content, commands too short to
read, LC_DYSYMTAB's tables and relocations (whose addresses no rebase
opcode lists), and a section aligned to more than the page it would
move by. One that passes still meets today's refusal, until the raise
itself lands. Any other file type is refused naming the three that grow.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 2: Raise the contents, and verify the raise

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (`mg_ensure_pad`'s announcement; new `mg_segs_cb` and `mg_raise_pointers` before `/* mg_binds_ok's observer`; `mg_snapshot_take`; `mg_found_ref`, `mg_verify_refs`, `mg_verify_symbols`, `mg_verify_pointers`, `mg_verify`; new `mg_raise_cb` before `/* mg_each_fileoff's visitor for the grow`; `mg_hsym_cb` and `mg_header_symbols` (renamed `mg_move_symbols`); new `mg_raise_rebased` and `mg_repair_refs`; `mg_grow_header`)
- Modify: `src/grow.h` (the top comment's last paragraph; `mg_ensure_pad`'s contract; new `mg_raise_pointers`; `mg_snapshot`; `mg_verify`'s and `mg_grow_header`'s contracts)
- Test: `tests/grow_test.c` (`test_verify_watches_the_pointers`'s "moved to a slot" row; Task 1's positive control, now a grow; new tests before `int main(void) {`; calls)
- Test: `tests/insert_dylib_test.sh` (block 14's comment and its dylib case)

**Interfaces:**
- Consumes: Task 1's `raise`, `base`, `build_dylib_at`; M2a's `mg_inside_refs_ok`, `mg_exports_ok`, `mg_binds_ok`, `MG_K_ABS`; `mg_rebases_read`, `mg_collect`, `mg_trie_walk`, the unwind, dice and init-offsets walkers.
- Produces:
  - `int mg_raise_pointers(const uint8_t *buf, size_t fsize, uint64_t base, uint64_t first, char *why, size_t whysz);` 0, or -1 with `why`: whether a raise can move every rebased pointer, decided before anything moves. It changes nothing.
  - `mg_snapshot` gains `uint8_t *kinds`, `uint32_t first`, `int raise`; `mg_verify(buf, fsize, before)` keeps its signature and derives G and the delta.
  - `static int mg_move_symbols(uint8_t *buf, size_t fsize, uint64_t base, uint64_t first, uint32_t grow, int raise, int patch);` (was `mg_header_symbols`); `static void mg_raise_rebased(uint8_t *buf, const mg_snapshot *snap, uint32_t grow);` (the move, from the snapshot's values); `static void mg_repair_refs(uint8_t *buf, const mg_snapshot *snap, uint32_t grow);`; `static int mg_raise_cb(...)`.
  - In the tests: `DY_RAISED_AT` (0x10000000), `DY_ALL`, `raised_dylib`, `dy_syms`, `check_verify_rejects_raise_with` (Task 3 uses it) and `check_verify_rejects_raise`.

**Plan decisions.**

- **Decision 2's table, row by row.** Every segment but the header's: `vmaddr` + G, and `fileoff` + G when its data lies at F or past it (a zero-fill segment keeps 0). The header's segment: `vmsize` and `filesize` + G. Every section's `addr` + G. `LC_ROUTINES_64.init_address` + G. File offsets, and the base-relative structures (unwind, trie, function starts, data in code, `__init_offsets`), by the lowering's own code: both routes add G to every distance from the base. A rebased pointer: + G if it names content; left if it names the header; refused if strictly inside or outside every segment. A symbol (`N_SECT`, not a stab): the same, and one below the base is left. Code that addresses the header: `disp32 −= G`, as on the lowering (factored into `mg_repair_refs`).
- **"Names content"** is at base + F or past it. A segment's end counts as within it, so a pointer to `__LINKEDIT`'s end or `__DATA`'s moves.
- **Decided once, before anything moves.** `mg_raise_pointers` checks each rebased pointer against the original's segments, and changes nothing; after the insert, `mg_raise_rebased` adds G to each value the snapshot read, in its slot G further on. A check after the segments moved would test old values against new ranges: a one-page raise opens a gap where `__ZERO + 8` was, and a segment two pages past the last would seem to map nothing. The edges test covers both, with `DY_ZEROFAR`.
- **Code that names what lies outside the image is not refused** (Ruling 3): tried, it refused 20 real images, every one falsely.
- **An export at offset 0** names the header, and stays: the trie walker adds G only to a nonzero offset, as on the lowering.
- **Verification.** `mg_verify` reads G as how far the first section moved and takes the delta (G on a raise, 0 on a lowering) from the file type the snapshot kept. Check 1: each collected entry moves by the delta, except an absolute export (M2a's `MG_K_ABS`) and an unmapped offset. Check 2's pointer and symbol halves: header-namers name the new base, content-namers move by the delta, and each rebase slot moves by it. Check 5: no code names new base + G (on the lowering that is the old base, so its message changes and its behaviour does not), and each recorded reference, now `delta` further on, names the base. So the executable route's verification is what it was. Checks 2's load-command half, 3 and 4 are Tasks 6 and 7.
- **Stabs** are refused on the raise until Task 3.
- **The announcement** (Decision 8): "…; contents raised by 0x1000", and the pad after the grow is measured after it, so Task 4's dropped command counts. On the raise only code is "repaired": a pointer to the header is left where it is.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, replace (`:3838`):

```c
        "ERROR: verify FAILED -- rebase 0 is at 0x100002008 after the grow, and was at 0x100002000 "
        "before; refusing.");
```

with:

```c
        "ERROR: verify FAILED -- rebase 0 is at 0x100002008 after the grow, and must be at "
        "0x100002000; refusing.");
```

In `tests/grow_test.c`, replace (`:4595`):

```c
 * at base 0 or above it: such a dylib or bundle reaches the refusal every
 * dylib and bundle meets until the raise is written. */
static void test_grow_raises_past_what_it_can_vouch_for(void) {
    static const uint32_t filetype[3] = { MH_DYLIB, MH_BUNDLE, MH_DYLIB };
    static const uint64_t base[3] = { 0, 0, 0x10000000 };
    for (int i = 0; i < 3; i++) {
        size_t fsize;
        char needle[64];
        uint8_t *buf = build_dylib_at(base[i], &fsize, DY_ROUTINES | DY_ZEROSEG);
        struct encryption_info_command_64 *e =
            (struct encryption_info_command_64 *)dy_find(buf, LC_UUID);
        ((struct mach_header_64 *)buf)->filetype = filetype[i];
        e->cmd = LC_ENCRYPTION_INFO_64;
        e->cryptoff = e->cryptsize = e->cryptid = 0;
        dy_section(buf, "__DATA", "__data")->align = 12;
        snprintf(needle, sizeof needle, "ERROR: only MH_EXECUTE can be grown (filetype=%u)",
                 filetype[i]);
        check_grow_refuses_header_refs("a dylib or bundle a raise can vouch for", buf, fsize,
                                       needle);
    }
```

with:

```c
 * at base 0 or above it. */
static void test_grow_raises_past_what_it_can_vouch_for(void) {
    static const uint32_t filetype[3] = { MH_DYLIB, MH_BUNDLE, MH_DYLIB };
    static const uint64_t base[3] = { 0, 0, 0x10000000 };
    for (int i = 0; i < 3; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib_at(base[i], &fsize, DY_ROUTINES | DY_ZEROSEG);
        struct encryption_info_command_64 *e =
            (struct encryption_info_command_64 *)dy_find(buf, LC_UUID);
        ((struct mach_header_64 *)buf)->filetype = filetype[i];
        e->cmd = LC_ENCRYPTION_INFO_64;
        e->cryptoff = e->cryptsize = e->cryptid = 0;
        dy_section(buf, "__DATA", "__data")->align = 12;
        int r = mg_grow_header(&buf, &fsize, 0x1000);
        CHECK(r == 0 && fsize == DY_FSIZE + 0x1000, "raise: filetype %u at base %#llx grows "
              "(got %d, %zu bytes)", filetype[i], (unsigned long long)base[i], r, fsize);
        free(buf);
    }
}

/* ---- what a raise moves (spec Decision 2) ----
 * Each test raises build_dylib_at(DY_RAISED_AT, ...) by one page and reads
 * the result back. */
#define DY_RAISED_AT 0x10000000ull
#define DY_ALL (DY_UNWIND | DY_DIC | DY_ROUTINES | DY_ZEROSEG)
static uint8_t *raised_dylib(size_t *fsize, int opts, uint32_t grow_req) {
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, fsize, opts);
    int r = mg_grow_header(&buf, fsize, grow_req);
    CHECK(r == 0, "raise: the grow succeeds (got %d)", r);
    if (r == 0) return buf;
    free(buf);
    return NULL;
}
static struct nlist_64 *dy_syms(uint8_t *buf, size_t fsize) {
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB);
    return (struct nlist_64 *)(buf + st->symoff);
}

static void test_raise_moves_the_segments_and_sections(void) {
    static const struct { const char *seg; uint64_t vmaddr, vmsize, fileoff, filesize; } segs[4] = {
        { "__TEXT", 0, 0x3000, 0, 0x3000 },
        { "__DATA", 0x3000, 0x2000, 0x3000, 0x1000 },
        { "__LINKEDIT", 0x5000, 0x1000, 0x4000, DY_FSIZE - 0x3000 },
        { "__ZERO", 0x7000, 0x1000, 0, 0 },
    };
    static const struct { const char *seg, *sect; uint64_t addr; uint32_t offset; } sects[4] = {
        { "__TEXT", "__text", 0x2000, 0x2000 }, { "__TEXT", "__unwind_info", 0x2800, 0x2800 },
        { "__DATA", "__la_symbol_ptr", 0x3038, 0x3038 }, { "__DATA", "__bss", 0x4000, 0 },
    };
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    for (int i = 0; i < 4; i++) {
        struct segment_command_64 *s = seg_named(buf, fsize, segs[i].seg);
        CHECK(s && s->vmaddr == DY_RAISED_AT + segs[i].vmaddr && s->vmsize == segs[i].vmsize &&
              s->fileoff == segs[i].fileoff && s->filesize == segs[i].filesize,
              "raise: %s is vm %#llx+%#llx, file %#llx+%#llx after it", segs[i].seg,
              s ? (unsigned long long)s->vmaddr : 0, s ? (unsigned long long)s->vmsize : 0,
              s ? (unsigned long long)s->fileoff : 0, s ? (unsigned long long)s->filesize : 0);
    }
    for (int i = 0; i < 4; i++) {
        mi_image im;
        struct section_64 *s = mi_wrap(buf, fsize, &im) == 0 ?
            mi_find_section(&im, sects[i].seg, sects[i].sect) : NULL;
        CHECK(s && s->addr == DY_RAISED_AT + sects[i].addr && s->offset == sects[i].offset,
              "raise: %s,%s is at %#llx, file %u after it", sects[i].seg, sects[i].sect,
              s ? (unsigned long long)s->addr : 0, s ? s->offset : 0);
    }
    struct routines_command_64 *rt = (struct routines_command_64 *)find_lc(buf, fsize, LC_ROUTINES_64);
    CHECK(rt && rt->init_address == DY_RAISED_AT + 0x2010,
          "raise: LC_ROUTINES_64's initializer is f2, raised (%#llx)",
          rt ? (unsigned long long)rt->init_address : 0);
    CHECK(buf[0x2010] == 0x55 && buf[0x2000] == 0x48, "raise: the code is in the file a page on");
    free(buf);
}

/* A pointer to the header stays; every other one follows the content. */
static void test_raise_moves_the_pointers_that_name_content(void) {
    static const uint64_t want[5] = { 0, 0x2010, 0x3020, 0x2010, 0x2100 };
    static const uint32_t at[5] = { 0x3000, 0x3008, 0x3010, 0x3030, 0x3038 };
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    for (int i = 0; i < 5; i++) {
        uint64_t v;
        memcpy(&v, buf + at[i], sizeof v);
        CHECK(v == DY_RAISED_AT + want[i], "raise: the pointer at file %#x holds %#llx, want %#llx",
              at[i], (unsigned long long)v, (unsigned long long)(DY_RAISED_AT + want[i]));
    }
    free(buf);
}

/* __mh_dylib_header names the header, and stays; the defined symbols
 * follow the content; the undefined one is not an address. */
static void test_raise_moves_the_symbols_that_name_content(void) {
    static const uint64_t want[5] = { DY_RAISED_AT, DY_RAISED_AT + 0x2000, DY_RAISED_AT + 0x2010,
                                      DY_RAISED_AT + 0x3020, 0 };
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    struct nlist_64 *nl = dy_syms(buf, fsize);
    for (int i = 0; i < 5; i++)
        CHECK(nl[i].n_value == want[i], "raise: symbol %d is %#llx, want %#llx", i,
              (unsigned long long)nl[i].n_value, (unsigned long long)want[i]);
    free(buf);
}

/* What is measured from the base gains the grow, as on the executable
 * route: the export trie, the leading function start, data in code and
 * compact unwind. */
static void test_raise_moves_what_is_measured_from_the_base(void) {
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    uint32_t toff = 0, tsize = 0;
    uint64_t a[3] = { 0, 0, 0 }, d0 = 0;
    static const uint32_t leaf[3] = { 16, 21, 26 };
    static const uint64_t want[3] = { 0x2000, 0x2010, 0x3020 };
    mg_find_trie(buf, fsize, &toff, &tsize);
    for (int i = 0; i < 3; i++) {
        mu_decode(buf + toff + leaf[i] + 2, buf + toff + tsize, &a[i]);
        CHECK(a[i] == want[i], "raise: export %d is %#llx, want %#llx", i,
              (unsigned long long)a[i], (unsigned long long)want[i]);
    }
    struct linkedit_data_command *fs =
        (struct linkedit_data_command *)find_lc(buf, fsize, LC_FUNCTION_STARTS);
    mu_decode(buf + fs->dataoff, buf + fs->dataoff + fs->datasize, &d0);
    CHECK(d0 == 0x2000, "raise: the first function start is %#llx, want 0x2000", (unsigned long long)d0);
    struct linkedit_data_command *dc = (struct linkedit_data_command *)find_lc(buf, fsize, LC_DATA_IN_CODE);
    CHECK(UW32(buf, dc->dataoff, 0) == 0x2020 && UW32(buf, dc->dataoff, 4) == 0x10008,
          "raise: data in code starts at %#x, length and kind unchanged", UW32(buf, dc->dataoff, 0));
    CHECK(UW32(buf, 0x2800, 28) == 0x3040 && UW32(buf, 0x2800, 32) == 0x2000 &&
          UW32(buf, 0x2800, 44) == 0x2100 && UW32(buf, 0x2800, 56) == 0x2010 &&
          UW32(buf, 0x2800, 60) == 0x2180 && UW32(buf, 0x2800, 80) == (1u << 24),
          "raise: compact unwind's personality, functions, sentinel and LSDA are raised, its "
          "compressed entries are not");
    free(buf);
}

/* f1's lea names the header, which stays, from code a page further on. */
static void test_raise_repairs_code_that_addresses_the_header(void) {
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    struct hr_seen s = { { { 0 } }, 0, 0 };
    int64_t n = mhr_scan(buf, fsize, DY_RAISED_AT, hr_record, &s);
    CHECK(n == 1 && s.c[0].addr == DY_RAISED_AT + 0x2003 && s.c[0].immlen == 0,
          "raise: f1's lea still addresses the header (%lld)", (long long)n);
    free(buf);
}

/* Two pages: _d, 0x2020 + 0x2000, needs a wider ULEB, so the export trie is
 * rebuilt at the end of __LINKEDIT. */
static void test_raise_rebuilds_a_widening_export_trie(void) {
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1001);
    if (!buf) return;
    uint32_t toff = 0, tsize = 0;
    mg_find_trie(buf, fsize, &toff, &tsize);
    CHECK(toff == DY_FSIZE + 0x2000 && fsize == DY_FSIZE + 0x2000 + tsize,
          "raise: the rebuilt trie is at the end (%#x, %u bytes, file %zu)", toff, tsize, fsize);
    free(buf);
}

/* A value strictly inside (base, base + F), or that no segment maps, cannot
 * be raised; nor can a debugging stab yet. */
static void test_raise_refuses_what_it_cannot_move(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    uint64_t v = DY_RAISED_AT + 16;
    memcpy(buf + 0x2008, &v, sizeof v);
    check_grow_refuses_header_refs("a pointer inside the header", buf, fsize,
        "ERROR: the pointer at 0x10002008 names 0x10000010, between the header at 0x10000000 and "
        "its first content at 0x10001000, which a grow moves apart; refusing to grow");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    v = DY_RAISED_AT + 0x5001;
    memcpy(buf + 0x2008, &v, sizeof v);
    check_grow_refuses_header_refs("a pointer past every segment", buf, fsize,
        "ERROR: the pointer at 0x10002008 names 0x10005001, which no segment maps; refusing to grow");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    v = DY_RAISED_AT - 1;
    memcpy(buf + 0x2008, &v, sizeof v);
    check_grow_refuses_header_refs("a pointer below every segment", buf, fsize,
        "ERROR: the pointer at 0x10002008 names 0xfffffff, which no segment maps");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    dy_syms(buf, fsize)[3].n_value = DY_RAISED_AT + 16;
    check_grow_refuses_header_refs("a symbol inside the header", buf, fsize,
        "ERROR: symbol 3, \"_d\", names 0x10000010, between the header at 0x10000000");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    dy_syms(buf, fsize)[4].n_type = N_FUN;
    check_grow_refuses_header_refs("a stab", buf, fsize,
        "ERROR: symbol 4, \"_x\", is a stab of type 0x24, which a raise does not know how to "
        "move; refusing to grow");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    hr_plant(buf + 0x1000, DY_RAISED_AT + 0x1000, 2, 0x05, 0, DY_RAISED_AT + 16);
    check_grow_refuses_header_refs("code inside the header", buf, fsize,
        "ERROR: the code at 0x10001003 names 0x10000010, between the header");
}

/* An N_SECT symbol below the base names nothing a raise moves. */
static void test_raise_leaves_a_symbol_below_the_base(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    dy_syms(buf, fsize)[3].n_value = 0x10;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && dy_syms(buf, fsize)[3].n_value == 0x10,
          "raise: a symbol below the base stays (got %d, %#llx)", r,
          (unsigned long long)dy_syms(buf, fsize)[3].n_value);
    free(buf);
}

/* _d, made absolute, is a value, 0x2020: the raise leaves it, and verify
 * expects it left. */
static void test_raise_leaves_an_absolute_export_alone(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    uint32_t toff = 0, tsize = 0;
    uint64_t a = 0;
    buf[0x3040 + 27] = 0x02;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    mg_find_trie(buf, fsize, &toff, &tsize);
    mu_decode(buf + toff + 28, buf + toff + tsize, &a);
    CHECK(r == 0 && a == 0x2020, "raise: an absolute export stays 0x2020 (got %d, %#llx)", r,
          (unsigned long long)a);
    free(buf);
}

/* A pointer to the first content, into a segment past a gap in memory
 * (__ZERO, a page past __LINKEDIT, or two with DY_ZEROFAR), or to the end of
 * a segment names content. Which segment maps it is decided before the raise
 * moves any: afterward, __ZERO + 8 lies in the gap a one-page raise opens. */
static void test_raise_moves_pointers_to_the_edges_of_content(void) {
    static const struct { const char *what; uint64_t v; int opts; } p[6] = {
        { "the first content", 0x1000, 0 },
        { "__ZERO's start", 0x6000, 0 },
        { "__ZERO + 8", 0x6008, 0 },
        { "__LINKEDIT's end", 0x5000, 0 },
        { "__ZERO's start, past a two-page gap", 0x7000, DY_ZEROFAR },
        { "__ZERO + 8, past a two-page gap", 0x7008, DY_ZEROFAR },
    };
    for (int i = 0; i < 6; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ZEROSEG | p[i].opts);
        uint64_t v = DY_RAISED_AT + p[i].v;
        memcpy(buf + 0x2008, &v, sizeof v);
        int r = mg_grow_header(&buf, &fsize, 0x1000);
        memcpy(&v, buf + 0x3008, sizeof v);
        CHECK(r == 0 && v == DY_RAISED_AT + p[i].v + 0x1000, "raise: a pointer to %s is raised "
              "(got %d, %#llx)", p[i].what, r, (unsigned long long)v);
        free(buf);
    }
}

/* An export at offset 0 names the header, and stays. */
static void test_raise_leaves_an_export_at_offset_0(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    uint32_t toff = 0, tsize = 0;
    uint64_t a = 1;
    buf[0x3040 + 28] = 0x80;                           /* _d: 0, in its two bytes */
    buf[0x3040 + 29] = 0x00;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    mg_find_trie(buf, fsize, &toff, &tsize);
    mu_decode(buf + toff + 28, buf + toff + tsize, &a);
    CHECK(r == 0 && a == 0, "raise: an export at offset 0 stays 0 (got %d, %#llx)", r,
          (unsigned long long)a);
    free(buf);
}

/* __LINKEDIT cut short of the string table: its offset maps nowhere, before
 * the raise and after it. */
static void test_raise_keeps_an_offset_no_segment_maps(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    seg_named(buf, fsize, "__LINKEDIT")->filesize = 0xf0;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "raise: an offset no segment maps stays unmapped (got %d)", r);
    free(buf);
}

/* Verification, on the raise: each check_verify_rejects_raise undoes one
 * thing a correct raise did. */
typedef void (*dy_undo)(uint8_t *buf, size_t fsize);
static void check_verify_rejects_raise(const char *what, dy_undo undo, const char *needle) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) { CHECK(0, "%s: snapshot", what); free(buf); return; }
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "%s: grow", what); mg_snapshot_free(&snap); free(buf); return;
    }
    CHECK(mg_verify(buf, fsize, &snap) == 0, "%s: verify accepts the raise as made", what);
    undo(buf, fsize);
    int r;
    verify_snap = &snap;
    char *err = stderr_during(verify_thunk, &buf, &fsize, 0, &r);
    CHECK(r == -1 && strstr(err, needle) != NULL, "verify REJECTS %s, saying '%s' (got %d):\n%s",
          what, needle, r, err);
    free(err);
    mg_snapshot_free(&snap);
    free(buf);
}
static void dy_unraise_pointer(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x3009] -= 0x10; }
static void dy_raise_header_pointer(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x3001] += 0x10; }
static void dy_unraise_symbol(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[3].n_value -= 0x1000; }
static void dy_raise_header_symbol(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[0].n_value += 0x1000; }
static void dy_unraise_unwind(uint8_t *buf, size_t fsize) { (void)fsize; UW32(buf, 0x2800, 32) -= 0x1000; }
static void dy_unrepair(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x2004] += 0x10; }
static void dy_unraise_linkedit(uint8_t *buf, size_t fsize) { seg_named(buf, fsize, "__LINKEDIT")->vmaddr -= 0x1000; }

static void test_verify_watches_the_raise(void) {
    check_verify_rejects_raise("a pointer to content left where it was", dy_unraise_pointer,
        "ERROR: verify FAILED -- the pointer at 0x10003008 holds 0x10001010 after the grow, and "
        "must hold 0x10002010; refusing.");
    check_verify_rejects_raise("a pointer to the header raised", dy_raise_header_pointer,
        "the pointer at 0x10003000 holds 0x10001000 after the grow, and must hold 0x10000000");
    check_verify_rejects_raise("a symbol left where it was", dy_unraise_symbol,
        "ERROR: verify FAILED -- symbol 3 is type 0xf, value 0x10002020 after the grow, and must "
        "be type 0xf, value 0x10003020; refusing.");
    check_verify_rejects_raise("the header's symbol raised", dy_raise_header_symbol,
        "symbol 0 is type 0x1e, value 0x10001000 after the grow, and must be type 0x1e, value "
        "0x10000000");
    check_verify_rejects_raise("an unwind entry left where it was", dy_unraise_unwind,
        "resolved to 0x10001000 before the grow and 0x10001000 after (moved +0 bytes), and must "
        "resolve to 0x10002000");
    check_verify_rejects_raise("code that addresses the header, unrepaired", dy_unrepair,
        "ERROR: verify FAILED -- code at 0x10002003 addresses 0x10001000, as a reference to the "
        "header the grow did not repair would; refusing.");
    check_verify_rejects_raise("__LINKEDIT left where it was", dy_unraise_linkedit,
        "and must resolve to 0x");
}

/* mg_ensure_pad says the contents were raised, and counts the code it
 * repaired; a pointer to the header, left where it is, is not repaired. */
static void test_ensure_pad_announces_a_raise(void) {
    size_t fsize;
    int r;
    uint8_t *buf = build_dylib(&fsize, 0);
    uint32_t lc_end = (uint32_t)sizeof(struct mach_header_64) +
                      ((struct mach_header_64 *)buf)->sizeofcmds;
    char want[160];
    snprintf(want, sizeof want, "t: grew the header pad by 4096 bytes (%u -> %u available); "
             "contents raised by 0x1000; repaired 1 reference to the header\n",
             DY_F - lc_end, DY_F + 0x1000 - lc_end);
    char *err = ensure_pad_stderr(&buf, &fsize, DY_F + 1, &r);
    CHECK(r == 0 && strcmp(err, want) == 0, "ensure_pad on a dylib: announced as '%s' (got %d):\n%s",
          want, r, err);
    free(err);
    free(buf);
```

In `tests/grow_test.c`, immediately after (`:5092`):

```c
    test_grow_raises_past_what_it_can_vouch_for();
```

insert:

```c
    test_raise_moves_the_segments_and_sections();
    test_raise_moves_the_pointers_that_name_content();
    test_raise_moves_the_symbols_that_name_content();
    test_raise_moves_what_is_measured_from_the_base();
    test_raise_repairs_code_that_addresses_the_header();
    test_raise_rebuilds_a_widening_export_trie();
    test_raise_refuses_what_it_cannot_move();
    test_raise_moves_pointers_to_the_edges_of_content();
    test_raise_keeps_an_offset_no_segment_maps();
    test_raise_leaves_an_export_at_offset_0();
    test_raise_leaves_an_absolute_export_alone();
    test_raise_leaves_a_symbol_below_the_base();
    test_verify_watches_the_raise();
    test_ensure_pad_announces_a_raise();
```

In `tests/insert_dylib_test.sh`, replace (`:521`):

```sh
# dylib -- which has no __PAGEZERO to lower the base into -- it is refused.
```

with:

```sh
# dylib, which has no __PAGEZERO to lower the base into, the contents are
# raised, announced.
```

In `tests/insert_dylib_test.sh`, replace (`:541`):

```sh
    [ "$rc" -eq 1 ] && [ ! -e "$T/nr_dy_out" ] && grep -q 'only MH_EXECUTE can be grown' "$T/14d.err" \
        && ok "no room: a dylib cannot grow, and is refused (exit 1, nothing written)" \
        || bad "no room (dylib)" "exit $rc (want 1): $(cut -c1-300 "$T/14d.err")"
```

with:

```sh
    [ "$rc" -eq 0 ] && grep -q ': grew the header pad by .*; contents raised by 0x' "$T/14d.err" \
        && ok "no room: a dylib's contents are raised, announced (exit 0)" \
        || bad "no room (dylib)" "exit $rc (want 0, announced): $(cut -c1-300 "$T/14d.err")"
    "$BIN/drydock-macho-rewrite" info "$T/nr_dy_out" 2>/dev/null | grep -qF "path=$nr_path" \
        && "$BIN/drydock-macho-rewrite" verify "$T/nr_dy_out" >/dev/null 2>&1 \
        && ok "no room: ... the dylib's output names the dylib and verifies" \
        || bad "no room (dylib)" "the output lacks the dylib or does not verify"
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: exit 1, and 34 `FAIL:` lines. The first is the reworded verify message:

```
FAIL: verify REJECTS a rebase moved to a slot holding the same value, saying 'ERROR: verify FAILED -- rebase 0 is at 0x100002008 after the grow, and must be at 0x100002000; refusing.' (got -1):
```

then `FAIL: raise: filetype 6 at base 0 grows (got -1, 13056 bytes)` and every raise test's "the grow succeeds (got -1)" or refusal line: a dylib is still refused with today's words. And `unset DRYDOCK_MACHO_REWRITE; sh tests/insert_dylib_test.sh "$B"` ends `insert_dylib_test: 39 passed, 2 failed`, its edited block 14 failing:

```
FAIL no room (dylib): exit 1 (want 0, announced): insert_dylib: deprecated -- drydock-macho-rewrite does this now. The equivalent command is:
FAIL no room (dylib): the output lacks the dylib or does not verify
```

- [ ] **Step 3: The raise's geometry, pointers and symbols**

In `src/grow.c`, replace (`:84`):

```c
    int64_t refs = mhr_scan(*pbuf, *pfsize, base_before, NULL, NULL);
    char why[256];
    int64_t ptrs = mg_header_pointers(*pbuf, *pfsize, base_before, first, 0, 0, why, sizeof why);
```

with:

```c
    int raise = hdr->filetype == MH_DYLIB || hdr->filetype == MH_BUNDLE;
    int64_t refs = mhr_scan(*pbuf, *pfsize, base_before, NULL, NULL);
    char why[256];
    int64_t ptrs = raise ? 0 : mg_header_pointers(*pbuf, *pfsize, base_before, first, 0, 0, why,
                                                  sizeof why);
```

In `src/grow.c`, replace (`:108`):

```c
    fprintf(stderr, "%s: grew the header pad by %u bytes (%u -> %u available); "
                    "image base %#llx -> %#llx",
            label, first - first_before, pad_avail, first - cur_lc_end,
            (unsigned long long)base_before, (unsigned long long)mg_base_of(*pbuf, *pfsize));
```

with:

```c
    hdr = (const struct mach_header_64 *)*pbuf;
    fprintf(stderr, "%s: grew the header pad by %u bytes (%u -> %u available); ", label,
            first - first_before, pad_avail, first - (uint32_t)sizeof *hdr - hdr->sizeofcmds);
    if (raise)
        fprintf(stderr, "contents raised by %#x", first - first_before);
    else
        fprintf(stderr, "image base %#llx -> %#llx", (unsigned long long)base_before,
                (unsigned long long)mg_base_of(*pbuf, *pfsize));
```

In `src/grow.c`, immediately before (`:534`):

```c
/* mg_binds_ok's observer: the first bind that names no segment of the image,
```

insert:

```c
/* Each segment's vm range, [lo, hi], for the first 64 segments with any. */
struct mg_segs { uint64_t lo[64], hi[64]; int n; };
static int mg_segs_cb(const struct load_command *lc, void *ctx_) {
    struct mg_segs *s = (struct mg_segs *)ctx_;
    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    if (lc->cmd != LC_SEGMENT_64 || seg->vmsize == 0 || s->n == 64) return 0;
    s->lo[s->n] = seg->vmaddr;
    s->hi[s->n++] = seg->vmaddr + seg->vmsize;
    return 0;
}

int mg_raise_pointers(const uint8_t *buf, size_t fsize, uint64_t base, uint64_t first,
                      char *why, size_t whysz) {
    mg_rebases rb;
    mi_image im;
    struct mg_segs segs;
    if (mg_rebases_read(buf, fsize, &rb, why, whysz) != 0) return -1;
    memset(&segs, 0, sizeof segs);
    if (mi_wrap((uint8_t *)buf, fsize, &im) == 0) mi_each_lc(&im, mg_segs_cb, &segs);
    for (size_t i = 0; i < rb.s.n; i++) {
        uint64_t v = rb.v[i].value;
        int mapped = 0;
        if (v > base && v - base < first) {
            snprintf(why, whysz, "the pointer at %#llx names %#llx, between the header at %#llx "
                     "and its first content at %#llx, which a grow moves apart",
                     (unsigned long long)rb.v[i].vm, (unsigned long long)v,
                     (unsigned long long)base, (unsigned long long)(base + first));
            mg_rebases_free(&rb);
            return -1;
        }
        for (int k = 0; k < segs.n && !mapped; k++) mapped = v >= segs.lo[k] && v <= segs.hi[k];
        if (!mapped) {
            snprintf(why, whysz, "the pointer at %#llx names %#llx, which no segment maps",
                     (unsigned long long)rb.v[i].vm, (unsigned long long)v);
            mg_rebases_free(&rb);
            return -1;
        }
    }
    mg_rebases_free(&rb);
    return 0;
}

```

In `src/grow.c`, replace (`:671`):

```c
    s->refs = NULL;
    s->nrefs = 0;
    s->symval = NULL;
    s->symtype = NULL;
    s->nsyms = 0;
    memset(&s->rb, 0, sizeof s->rb);
    s->addr = (uint64_t *)malloc(MG_SNAP_MAX * sizeof(uint64_t));
    if (!s->addr) return -1;
    if (mg_collect(buf, fsize, s->addr, NULL, MG_SNAP_MAX, &s->n) != 0 ||
```

with:

```c
    const struct mach_header_64 *h = (const struct mach_header_64 *)buf;
    s->refs = NULL;
    s->nrefs = 0;
    s->symval = NULL;
    s->symtype = NULL;
    s->nsyms = 0;
    memset(&s->rb, 0, sizeof s->rb);
    s->kinds = NULL;
    s->first = mg_first_sect_off(buf, fsize);
    s->raise = h->filetype == MH_DYLIB || h->filetype == MH_BUNDLE;
    s->addr = (uint64_t *)malloc(MG_SNAP_MAX * sizeof(uint64_t));
    if (!s->addr || !(s->kinds = (uint8_t *)malloc(MG_SNAP_MAX)) ||
        mg_collect(buf, fsize, s->addr, s->kinds, MG_SNAP_MAX, &s->n) != 0 ||
```

In `src/grow.c`, immediately after (`:701`):

```c
    free(s->addr); s->addr = NULL; s->n = 0;
```

insert:

```c
    free(s->kinds); s->kinds = NULL;
```

In `src/grow.c`, replace (`:732`):

```c
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
    int64_t n = mhr_scan(buf, fsize, before->base, mg_first_ref, &stale);
    if (n < 0) {
        fprintf(stderr, "ERROR: verify FAILED -- an instruction section lies past the end of "
                        "the %zu-byte image, so it cannot be searched for code that addresses "
                        "the header; refusing.\n", fsize);
        return -1;
    }
    if (n != 0) {
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

/* Every symbol keeps its type, and its value unless it is an N_SECT symbol,
 * not a stab, that named the header: that one names it where it is now. */
static int mg_verify_symbols(const mi_image *im, size_t fsize, const mg_snapshot *before,
                             uint64_t base) {
```

with:

```c
struct mg_found { const mg_snapshot *s; uint64_t delta; uint8_t *seen; };
static int mg_found_ref(const mhr_cand *c, void *ctx_) {
    struct mg_found *f = (struct mg_found *)ctx_;
    for (uint32_t i = 0; i < f->s->nrefs; i++)
        if (f->s->refs[i].addr + f->delta == c->addr && f->s->refs[i].immlen == c->immlen)
            f->seen[i] = 1;
    return 0;
}

/* No code addresses `grow` past the header, where an unrepaired reference
 * to it would, and every reference the snapshot recorded, now `delta`
 * further on, addresses it. */
static int mg_verify_refs(const uint8_t *buf, size_t fsize, const mg_snapshot *before,
                          uint64_t base, uint64_t grow, uint64_t delta) {
    mhr_cand stale = { 0, 0, 0, 0 };
    int64_t n = mhr_scan(buf, fsize, base + grow, mg_first_ref, &stale);
    if (n < 0) {
        fprintf(stderr, "ERROR: verify FAILED -- an instruction section lies past the end of "
                        "the %zu-byte image, so it cannot be searched for code that addresses "
                        "the header; refusing.\n", fsize);
        return -1;
    }
    if (n != 0) {
        fprintf(stderr, "ERROR: verify FAILED -- code at %#llx addresses %#llx, as a reference "
                        "to the header the grow did not repair would; refusing.\n",
                (unsigned long long)stale.addr, (unsigned long long)(base + grow));
        return -1;
    }
    struct mg_found f = { before, delta, (uint8_t *)calloc(before->nrefs + 1, 1) };
    if (!f.seen) return -1;
    mhr_scan(buf, fsize, base, mg_found_ref, &f);
    for (uint32_t i = 0; i < before->nrefs; i++) {
        if (f.seen[i]) continue;
        fprintf(stderr, "ERROR: verify FAILED -- the reference to the header at %#llx does "
                        "not address it after the grow; refusing.\n",
                (unsigned long long)(before->refs[i].addr + delta));
        free(f.seen);
        return -1;
    }
    free(f.seen);
    return 0;
}

/* Every symbol keeps its type, and its value unless it is an N_SECT symbol,
 * not a stab: one that named the header names it where it is now, and one
 * that named content, at the first section or past it, has moved `delta`. */
static int mg_verify_symbols(const mi_image *im, size_t fsize, const mg_snapshot *before,
                             uint64_t base, uint64_t delta) {
```

In `src/grow.c`, replace (`:794`):

```c
        uint64_t want = !(t & N_STAB) && (t & N_TYPE) == N_SECT && before->symval[i] == before->base
                        ? base : before->symval[i];
```

with:

```c
        uint64_t want = before->symval[i];
        if (!(t & N_STAB) && (t & N_TYPE) == N_SECT)
            want = want > before->base && want - before->base >= before->first ? want + delta
                 : want == before->base ? base : want;
```

In `src/grow.c`, replace (`:812`):

```c
                              const mg_snapshot *before, uint64_t base) {
```

with:

```c
                              const mg_snapshot *before, uint64_t base, uint64_t delta) {
```

In `src/grow.c`, replace (`:828`):

```c
        uint64_t want = was->value == before->base ? base : was->value;
        uint64_t loads = mg_fileoff_vm(im, is->at);
        if (loads != is->vm) {
            fprintf(stderr, "ERROR: verify FAILED -- rebase %zu is read from file offset %#llx, "
                            "which loads at %#llx, not %#llx; refusing.\n", i,
                    (unsigned long long)is->at, (unsigned long long)loads,
                    (unsigned long long)is->vm);
            rc = -1;
        } else if (is->vm != was->vm) {
            fprintf(stderr, "ERROR: verify FAILED -- rebase %zu is at %#llx after the grow, and "
                            "was at %#llx before; refusing.\n", i, (unsigned long long)is->vm,
                    (unsigned long long)was->vm);
```

with:

```c
        uint64_t want = was->value == before->base ? base : was->value + delta;
        uint64_t loads = mg_fileoff_vm(im, is->at);
        if (loads != is->vm) {
            fprintf(stderr, "ERROR: verify FAILED -- rebase %zu is read from file offset %#llx, "
                            "which loads at %#llx, not %#llx; refusing.\n", i,
                    (unsigned long long)is->at, (unsigned long long)loads,
                    (unsigned long long)is->vm);
            rc = -1;
        } else if (is->vm != was->vm + delta) {
            fprintf(stderr, "ERROR: verify FAILED -- rebase %zu is at %#llx after the grow, and "
                            "must be at %#llx; refusing.\n", i, (unsigned long long)is->vm,
                    (unsigned long long)(was->vm + delta));
```

In `src/grow.c`, immediately after (`:852`):

```c
int mg_verify(const uint8_t *buf, size_t fsize, const mg_snapshot *before) {
```

insert:

```c
    uint64_t grow = (uint64_t)mg_first_sect_off(buf, fsize) - before->first;
    uint64_t delta = before->raise ? grow : 0;
```

In `src/grow.c`, replace (`:868`):

```c
        if (now[i] == before->addr[i]) continue;
```

with:

```c
        uint64_t want = before->addr[i] == MG_UNMAPPED || before->kinds[i] == MG_K_ABS
                        ? before->addr[i] : before->addr[i] + delta;
        if (now[i] == want) continue;
```

In `src/grow.c`, replace (`:880`):

```c
                        "%#llx before the grow and %#llx after (moved %+lld bytes). The grow "
                        "must leave every resolved address unchanged; refusing.\n",
                i, (unsigned long long)before->addr[i], (unsigned long long)now[i],
                (long long)moved);
```

with:

```c
                        "%#llx before the grow and %#llx after (moved %+lld bytes), and must "
                        "resolve to %#llx; refusing.\n",
                i, (unsigned long long)before->addr[i], (unsigned long long)now[i],
                (long long)moved, (unsigned long long)want);
```

In `src/grow.c`, replace (`:898`):

```c
    if (mg_verify_symbols(&im, fsize, before, base) != 0) return -1;
    if (mg_verify_pointers(&im, buf, fsize, before, base) != 0) return -1;
    return mg_verify_refs(buf, fsize, before, base);
```

with:

```c
    if (mg_verify_symbols(&im, fsize, before, base, delta) != 0) return -1;
    if (mg_verify_pointers(&im, buf, fsize, before, base, delta) != 0) return -1;
    return mg_verify_refs(buf, fsize, before, base, grow, delta);
```

In `src/grow.c`, immediately before (`:1476`):

```c
/* mg_each_fileoff's visitor for the grow: move each file offset at or past
```

insert:

```c
/* mg_grow_header's mi_each_lc callback for a raise's geometry: every segment
 * but the one that maps the header moves up `grow` in memory, and in the
 * file when its data lies past the insert; the header's segment grows by
 * `grow`; every section's address, and LC_ROUTINES_64's initializer, moves
 * up `grow`. */
static int mg_raise_cb(const struct load_command *lc_in, void *ctx_) {
    struct mg_patch_ctx *ctx = (struct mg_patch_ctx *)ctx_;
    if (lc_in->cmd == LC_ROUTINES_64) {
        ((struct routines_command_64 *)lc_in)->init_address += ctx->grow;
        return 0;
    }
    if (lc_in->cmd != LC_SEGMENT_64) return 0;
    struct segment_command_64 *seg = (struct segment_command_64 *)lc_in;
    struct section_64 *s = (struct section_64 *)(seg + 1);
    if (seg->fileoff == 0 && seg->filesize > 0) {
        seg->vmsize += ctx->grow;
        seg->filesize += ctx->grow;
    } else {
        seg->vmaddr += ctx->grow;
        if (seg->fileoff >= ctx->insert) seg->fileoff += ctx->grow;
    }
    for (uint32_t j = 0; j < seg->nsects; j++) s[j].addr += ctx->grow;
    return 0;
}

```

In `src/grow.c`, replace (`:1638`):

```c
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
```

with:

```c
/* The symbols a grow moves: each N_SECT symbol, not a stab. With `patch`,
 * on a lowering, one whose value is `base` loses `grow`, following the
 * header down; on a raise, one that names content, at base + `first` or
 * past it, gains `grow`, following the content up. Without `patch`, this
 * checks that the symbol table lies within the image, and says so on stderr
 * when it does not; on a raise, it refuses a stab. Either way, one that names
 * a byte strictly between the header and its first content, at base +
 * `first`, is refused, saying so. Returns 0, or -1. */
struct mg_hsym_ctx {
    uint8_t *buf;
    size_t fsize;
    uint64_t base, first;
    uint32_t grow;
    int raise, patch, bad, n;
```

In `src/grow.c`, replace (`:1672`):

```c
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

with:

```c
        const char *name;
        if (c->raise && (nl[i].n_type & N_STAB)) {
            int len = mg_sym_name(c->buf, c->fsize, st, &nl[i], &name);
            fprintf(stderr, "ERROR: symbol %u, \"%.*s\", is a stab of type %#x, which a raise "
                            "does not know how to move; refusing to grow\n", i, len, name,
                    nl[i].n_type);
            c->bad = 1;
            return 1;
        }
        if ((nl[i].n_type & N_STAB) || (nl[i].n_type & N_TYPE) != N_SECT) continue;
        uint64_t v = nl[i].n_value;
        if (v > c->base && v - c->base < c->first) {
            int len = mg_sym_name(c->buf, c->fsize, st, &nl[i], &name);
            fprintf(stderr, "ERROR: symbol %u, \"%.*s\", names %#llx, between the header at %#llx "
                            "and its first content at %#llx, which a grow moves apart; refusing "
                            "to grow\n", i, len, name, (unsigned long long)v,
                    (unsigned long long)c->base, (unsigned long long)(c->base + c->first));
            c->bad = 1;
            return 1;
        }
        if (c->patch && !c->raise && v == c->base) nl[i].n_value -= c->grow;
        if (c->patch && c->raise && v > c->base && v - c->base >= c->first)
            nl[i].n_value += c->grow;
    }
    return 0;
}

static int mg_move_symbols(uint8_t *buf, size_t fsize, uint64_t base, uint64_t first,
                           uint32_t grow, int raise, int patch) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) != 0) return -1;
    struct mg_hsym_ctx c = { buf, fsize, base, first, grow, raise, patch, 0, 0 };
```

In `src/grow.c`, immediately before (`:1813`):

```c
int mg_grow_header(uint8_t **pbuf, size_t *pfsize, uint32_t grow_req) {
```

insert:

```c
/* The pointers a raise moves, as the snapshot read them before anything
 * moved (mg_raise_pointers vouched for each): every rebase target's value,
 * unless it names the header, gains `grow`, in its slot, which the insert
 * moved `grow` further into the file. */
static void mg_raise_rebased(uint8_t *buf, const mg_snapshot *snap, uint32_t grow) {
    for (size_t i = 0; i < snap->rb.s.n; i++) {
        uint64_t v = snap->rb.v[i].value;
        if (v == snap->base) continue;
        v += grow;
        memcpy(buf + snap->rb.v[i].at + grow, &v, sizeof v);
    }
}

/* A grow puts the header and its code `grow` bytes closer together on
 * either route, so each reference the snapshot recorded, which the insert
 * moved `grow` further into the file, loses `grow`. */
static void mg_repair_refs(uint8_t *buf, const mg_snapshot *snap, uint32_t grow) {
    for (uint32_t i = 0; i < snap->nrefs; i++) {
        uint8_t *d = buf + snap->refs[i].off + grow;
        int32_t disp;
        memcpy(&disp, d, sizeof disp);
        disp = (int32_t)((int64_t)disp - (int64_t)grow);
        memcpy(d, &disp, sizeof disp);
    }
}

```

In `src/grow.c`, replace (`:1851`):

```c
     * load time. A non-PIE image, or a dylib/bundle (no __PAGEZERO), would
     * require fixing up absolute pointers — which this tool deliberately does
     * not do. Refuse loudly rather than silently corrupt.
```

with:

```c
     * load time. A dylib or bundle has no __PAGEZERO, so it is raised, and
     * every absolute address that names its contents moves with them. Refuse
     * loudly rather than silently corrupt.
```

In `src/grow.c`, replace (`:1958`):

```c
        fprintf(stderr, "ERROR: only MH_EXECUTE can be grown (filetype=%u): growing "
                        "lowers the image base into __PAGEZERO, and a dylib or bundle has "
                        "none. This tool cannot grow a dylib or bundle.\n", hdr->filetype);
        return -1;
```

with:

```c
```

In `src/grow.c`, replace (`:2016`):

```c
    if (mg_header_symbols(buf, fsize, mg_base_of(buf, fsize), insert, grow, 0) != 0) return -1;
    {
        char why[256];
        int64_t n = mg_header_pointers(buf, fsize, mg_base_of(buf, fsize), insert, grow, 0,
                                       why, sizeof why);
```

with:

```c
    if (mg_move_symbols(buf, fsize, base, insert, grow, raise, 0) != 0) return -1;
    {
        char why[256];
        int64_t n = raise ? mg_raise_pointers(buf, fsize, base, insert, why, sizeof why)
                          : mg_header_pointers(buf, fsize, base, insert, grow, 0, why, sizeof why);
```

In `src/grow.c`, replace (`:2120`):

```c
        mi_each_lc(&patch_im, mg_patch_cb, &pctx);
```

with:

```c
        mi_each_lc(&patch_im, raise ? mg_raise_cb : mg_patch_cb, &pctx);
```

In `src/grow.c`, replace (`:2287`):

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

    if (mg_header_symbols(buf, final_size, snap.base, insert, grow, 1) != 0) {
        fprintf(stderr, "ERROR: internal error re-basing the symbols that name the header "
                        "after passing the pre-check\n");
        mg_snapshot_free(&snap);
        return -1;
    }

    {
        char why[256];
        if (mg_header_pointers(buf, final_size, snap.base, insert, 0, grow, why, sizeof why) < 0) {
            fprintf(stderr, "ERROR: internal error moving the pointers that name the header "
                            "after passing the pre-check: %s\n", why);
```

with:

```c
    mg_repair_refs(buf, &snap, grow);

    if (mg_move_symbols(buf, final_size, snap.base, insert, grow, raise, 1) != 0) {
        fprintf(stderr, "ERROR: internal error moving the symbols after passing the "
                        "pre-check\n");
        mg_snapshot_free(&snap);
        return -1;
    }

    if (raise) {
        mg_raise_rebased(buf, &snap, grow);
    } else {
        char why[256];
        if (mg_header_pointers(buf, final_size, snap.base, insert, 0, grow, why, sizeof why) < 0) {
            fprintf(stderr, "ERROR: internal error moving the pointers after passing the "
                            "pre-check: %s\n", why);
```

- [ ] **Step 4: The contracts**

In `src/grow.h`, replace (`:34`):

```c
 * Dylibs without a __PAGEZERO can't lower the base; mg_grow_header reports that
 * and leaves the buffer untouched so the caller can fall back / error cleanly.
```

with:

```c
 * A dylib or bundle, which has no __PAGEZERO, is raised instead: everything
 * past the header moves up by the grow, and so does every absolute address
 * that names it: each rebased pointer, symbol, section and segment.
```

In `src/grow.h`, replace (`:118`):

```c
 * available); image base 0xOLD -> 0xNEW", ending "; repaired N references to
 * the header" (or "1 reference") when the grow repaired code that addresses
 * the image's own header (src/hdrref.h) or moved pointers to it
 * (mg_header_pointers), counting both.
```

with:

```c
 * available); image base 0xOLD -> 0xNEW" for an executable, or "...;
 * contents raised by 0xN" for a dylib or bundle, ending "; repaired N
 * references to the header" (or "1 reference") when the grow repaired code
 * that addresses the image's own header (src/hdrref.h) or, lowering, moved
 * pointers to it (mg_header_pointers), counting both.
```

In `src/grow.h`, replace (`:220`):

```c
/* What mg_verify compares a grown image against: the resolved addresses
 * mg_collect finds, the image base with every reference to it the
 * header-reference scan (src/hdrref.h) finds, each symbol's type and value,
 * and every rebase target with its value. */
typedef struct {
    uint64_t *addr;
    uint32_t n;
    uint64_t base;
```

with:

```c
/* Whether a raise can move every pointer, before anything moves: each
 * rebase target's value names the header (it is `base`, and stays) or
 * content, which a raise moves up. One strictly inside (base, base + first)
 * is refused, and so is one that no segment maps (its range's end
 * included). Returns 0, or -1 with `why` set (mg_rebases_read's reasons, or
 * those two). The raise then moves them from its snapshot, as read here. */
int mg_raise_pointers(const uint8_t *buf, size_t fsize, uint64_t base, uint64_t first,
                      char *why, size_t whysz);

/* What mg_verify compares a grown image against: the resolved addresses
 * mg_collect finds and their kinds, the image base and first section offset
 * with every reference to the header the header-reference scan (src/hdrref.h)
 * finds, whether the image is raised (a dylib or bundle) or lowered, each
 * symbol's type and value, and every rebase target with its value. */
typedef struct {
    uint64_t *addr;
    uint8_t *kinds;
    uint32_t n;
    uint64_t base;
    uint32_t first;
    int raise;
```

In `src/grow.h`, replace (`:276`):

```c
/* 0 if every base-relative structure and every mg_each_fileoff offset
 * resolves exactly where it did before the grow, no two segments overlap in
 * memory, no code addresses the base as it was, every reference to the
 * header the snapshot recorded addresses the base as it is, and the rebase
 * targets are the same slots, each holding what it held unless that named the
 * header, which now names the base as it is; -1 (with a message naming the
 * first failure) otherwise. */
```

with:

```c
/* The grow G is how far the first section moved; a raise moves every
 * content address by it, a lowering none. 0 if every base-relative structure
 * and every mg_each_fileoff offset resolves where it did before the grow,
 * moved by that (an absolute export not at all); no two segments overlap in
 * memory; no code addresses the base as it is plus G, where an unrepaired
 * reference to the header would; every reference to the header the snapshot
 * recorded addresses the base as it is; each N_SECT symbol, not a stab, and
 * each rebase target's value, names the base as it is if it named the
 * header, and else what it named, moved; and the rebase targets are the same
 * slots, moved. -1 (with a message naming the first failure) otherwise. */
```

In `src/grow.h`, replace (`:421`):

```c
 * and size unchanged. Among those: an image that is not a PIE executable with
 * a large enough __PAGEZERO; one with no section data to insert the new space
```

with:

```c
 * and size unchanged. Among those: an executable that is not PIE, or lacks a
 * large enough __PAGEZERO; a dylib or bundle that is not x86_64, or that a
 * raise cannot vouch for (mg_raise_ok); any other file type; one with no
 * section data to insert the new space
```

- [ ] **Step 5: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green (`insert_dylib_test` among it: 41 passed).

- [ ] **Step 6: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    int raise = hdr->filetype == MH_DYLIB \|\| hdr->filetype == MH_BUNDLE;`<br>`    int64_t refs` | `    int raise = 0;`<br>`    int64_t refs` | `FAIL: ensure_pad on a dylib: announced as` |
| 2 | `    int64_t ptrs = raise ? 0 : mg_header_pointers(` | `    int64_t ptrs = mg_header_pointers(` | `FAIL: ensure_pad on a dylib: announced as` |
| 3 | `    if (raise)`<br>`        fprintf(stderr, "contents raised by %#x", first - first_before);` | `    if (!raise)`<br>`        fprintf(stderr, "contents raised by %#x", first - first_before);` | `FAIL: ensure_pad on a dylib: announced as` |
| 4 | `        if (v == snap->base) continue;`<br>`        v += grow;` | `        v += grow;` | `FAIL: raise: the grow succeeds (got -1)` |
| 5 | `        if (v > base && v - base < first) {`<br>`            snprintf(why, whysz, "the pointer at %#llx names %#llx, between the header at %#llx "`<br>`                     "and its first content at %#llx, which a grow moves apart",`<br>`                     (unsigned long long)rb.v[i].vm, (unsigned long long)v,`<br>`                     (unsigned long long)base, (unsigned long long)(base + first));`<br>`            mg_rebases_free(&rb);`<br>`            return -1;`<br>`        }`<br>`        for` | `        if (v > base && v - base <= first) {`<br>`            snprintf(why, whysz, "the pointer at %#llx names %#llx, between the header at %#llx "`<br>`                     "and its first content at %#llx, which a grow moves apart",`<br>`                     (unsigned long long)rb.v[i].vm, (unsigned long long)v,`<br>`                     (unsigned long long)base, (unsigned long long)(base + first));`<br>`            mg_rebases_free(&rb);`<br>`            return -1;`<br>`        }`<br>`        for` | `FAIL: raise: a pointer to the first content is raised` |
| 6 | `        for (int k = 0; k < segs.n && !mapped; k++) mapped = v >= segs.lo[k] && v <= segs.hi[k];` | `        for (int k = 0; k < segs.n && !mapped; k++) mapped = v >= segs.lo[k] && v < segs.hi[k];` | `FAIL: raise: a pointer to __LINKEDIT's end is raised` |
| 7 | `        for (int k = 0; k < segs.n && !mapped; k++) mapped = v >= segs.lo[k] && v <= segs.hi[k];` | `        for (int k = 0; k < segs.n && !mapped; k++) mapped = v > segs.lo[k] && v <= segs.hi[k];` | `FAIL: raise: a pointer to __ZERO's start is raised` |
| 8 | `        for (int k = 0; k < segs.n && !mapped; k++) mapped = v >= segs.lo[k] && v <= segs.hi[k];` | `        for (int k = 0; k < segs.n && !mapped; k++) mapped = v <= segs.hi[k];` | `FAIL: a pointer below every segment: mg_grow_header refuses` |
| 9 | `        if (!mapped) {` | `        if (0) {` | `FAIL: a pointer past every segment: mg_grow_header refuses` |
| 10 | `        v += grow;`<br>`        memcpy(buf + snap->rb.v[i].at + grow, &v, sizeof v);` | `        v += grow;`<br>`        (void)v;` | `FAIL: raise: the grow succeeds (got -1)` |
| 11 | `        ((struct routines_command_64 *)lc_in)->init_address += ctx->grow;` | `        (void)0;` | `FAIL: raise: LC_ROUTINES_64's initializer is f2, raised` |
| 12 | `    if (seg->fileoff == 0 && seg->filesize > 0) {`<br>`        seg->vmsize += ctx->grow;` | `    if (seg->fileoff == 0) {`<br>`        seg->vmsize += ctx->grow;` | `FAIL: raise: __ZERO is vm` |
| 13 | `        seg->vmsize += ctx->grow;`<br>`        seg->filesize += ctx->grow;`<br>`    } else {` | `        seg->filesize += ctx->grow;`<br>`    } else {` | `FAIL: raise: the grow succeeds (got -1)` |
| 14 | `        seg->vmsize += ctx->grow;`<br>`        seg->filesize += ctx->grow;`<br>`    } else {` | `        seg->vmsize += ctx->grow;`<br>`    } else {` | `FAIL: raise: the grow succeeds (got -1)` |
| 15 | `        seg->vmaddr += ctx->grow;`<br>`        if (seg->fileoff >= ctx->insert) seg->fileoff += ctx->grow;` | `        if (seg->fileoff >= ctx->insert) seg->fileoff += ctx->grow;` | `FAIL: raise: the grow succeeds (got -1)` |
| 16 | `        seg->vmaddr += ctx->grow;`<br>`        if (seg->fileoff >= ctx->insert) seg->fileoff += ctx->grow;` | `        seg->vmaddr += ctx->grow;`<br>`        seg->fileoff += ctx->grow;` | `FAIL: raise: __ZERO is vm` |
| 17 | `    for (uint32_t j = 0; j < seg->nsects; j++) s[j].addr += ctx->grow;` | `    (void)s;` | `FAIL: raise: the grow succeeds (got -1)` |
| 18 | `        if (c->raise && (nl[i].n_type & N_STAB)) {` | `        if (0) {` | `FAIL: a stab: mg_grow_header refuses` |
| 19 | `        if (c->patch && !c->raise && v == c->base) nl[i].n_value -= c->grow;` | `        if (c->patch && v == c->base) nl[i].n_value -= c->grow;` | `FAIL: raise: the grow succeeds (got -1)` |
| 20 | `        if (c->patch && c->raise && v > c->base && v - c->base >= c->first)`<br>`            nl[i].n_value += c->grow;` | `        if (c->patch && c->raise && v != c->base)`<br>`            nl[i].n_value += c->grow;` | `FAIL: raise: a symbol below the base stays` |
| 21 | `        if (c->patch && c->raise && v > c->base && v - c->base >= c->first)`<br>`            nl[i].n_value += c->grow;` | `        (void)0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 22 | `        if (mg_raise_ok(&find_im, base, insert) != 0) return -1;` | `        mg_raise_ok(&find_im, base, insert);` | `FAIL: no LC_DYLD_INFO: mg_grow_header refuses` |
| 23 | `        int64_t n = raise ? mg_raise_pointers(buf, fsize, base, insert, why, sizeof why)` | `        int64_t n = 0 ? mg_raise_pointers(buf, fsize, base, insert, why, sizeof why)` | `FAIL: a pointer past every segment: mg_grow_header refuses` |
| 24 | `        mi_each_lc(&patch_im, raise ? mg_raise_cb : mg_patch_cb, &pctx);` | `        mi_each_lc(&patch_im, mg_patch_cb, &pctx);` | `FAIL: raise: the grow succeeds` |
| 25 | `    mg_repair_refs(buf, &snap, grow);` | `    (void)mg_repair_refs;` | `FAIL: raise: the grow succeeds` |
| 26 | `    if (mg_move_symbols(buf, final_size, snap.base, insert, grow, raise, 1) != 0) {` | `    if (mg_move_symbols(buf, final_size, snap.base, insert, grow, 0, 1) != 0) {` | `FAIL: raise: the grow succeeds` |
| 27 | `    if (raise) {`<br>`        mg_raise_rebased(buf, &snap, grow);` | `    if (0) {`<br>`        mg_raise_rebased(buf, &snap, grow);` | `FAIL: raise: the grow succeeds` |
| 28 | `    s->raise = h->filetype == MH_DYLIB \|\| h->filetype == MH_BUNDLE;` | `    s->raise = h->filetype == MH_DYLIB;` | `FAIL: raise: filetype 8 at base 0 grows` |
| 29 | `    s->first = mg_first_sect_off(buf, fsize);` | `    s->first = 0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 30 | `    uint64_t delta = before->raise ? grow : 0;` | `    uint64_t delta = grow;` | `FAIL: repair: a grow with two confirmed references succeeds` |
| 31 | `        uint64_t want = before->addr[i] == MG_UNMAPPED \|\| before->kinds[i] == MG_K_ABS` | `        uint64_t want = before->kinds[i] == MG_K_ABS` | `FAIL: raise: an offset no segment maps stays unmapped` |
| 32 | `        uint64_t want = before->addr[i] == MG_UNMAPPED \|\| before->kinds[i] == MG_K_ABS` | `        uint64_t want = before->addr[i] == MG_UNMAPPED` | `FAIL: raise: an absolute export stays 0x2020` |
| 33 | `            want = want > before->base && want - before->base >= before->first ? want + delta` | `            want = want > before->base && want - before->base >= before->first ? want` | `FAIL: raise: the grow succeeds (got -1)` |
| 34 | `        uint64_t want = was->value == before->base ? base : was->value + delta;` | `        uint64_t want = was->value == before->base ? base : was->value;` | `FAIL: raise: the grow succeeds` |
| 35 | `        } else if (is->vm != was->vm + delta) {` | `        } else if (is->vm != was->vm) {` | `FAIL: raise: the grow succeeds` |
| 36 | `    int64_t n = mhr_scan(buf, fsize, base + grow, mg_first_ref, &stale);` | `    int64_t n = mhr_scan(buf, fsize, before->base, mg_first_ref, &stale);` | `FAIL: raise: the grow succeeds` |
| 37 | `        if (f->s->refs[i].addr + f->delta == c->addr && f->s->refs[i].immlen == c->immlen)` | `        if (f->s->refs[i].addr == c->addr && f->s->refs[i].immlen == c->immlen)` | `FAIL: raise: the grow succeeds` |
| 38 | `    uint64_t grow = (uint64_t)mg_first_sect_off(buf, fsize) - before->first;` | `    uint64_t grow = 0x1000;` | `FAIL: raise: the grow succeeds` |
| 39 | `            want = want > before->base && want - before->base >= before->first ? want + delta` | `            want = want != before->base ? want + delta` | `FAIL: raise: a symbol below the base stays` |
| 40 | `        if (c->patch && c->raise && v > c->base && v - c->base >= c->first)` | `        if (c->patch && c->raise && v - c->base >= c->first)` | `FAIL: raise: a symbol below the base stays` |
| 41 | `        memcpy(buf + snap->rb.v[i].at + grow, &v, sizeof v);` | `        memcpy(buf + snap->rb.v[i].at, &v, sizeof v);` | `FAIL: raise: the grow succeeds (got -1)` |
| 42 | `    if (raise) {`<br>`        mg_raise_rebased(buf, &snap, grow);` | `    if (raise) {`<br>`        char why2[256];`<br>`        if (mg_raise_pointers(buf, final_size, snap.base, insert, why2, sizeof why2) != 0) {`<br>`            mg_snapshot_free(&snap);`<br>`            return -1;`<br>`        }`<br>`        mg_raise_rebased(buf, &snap, grow);` | `FAIL: raise: a pointer to __ZERO + 8 is raised` |
| 43 | `        for (int k = 0; k < segs.n && !mapped; k++) mapped = v >= segs.lo[k] && v <= segs.hi[k];` | `        for (int k = 0; k < segs.n && !mapped; k++) mapped = v >= segs.lo[k] && v <= segs.hi[k] + 0x1000;` | `FAIL: a pointer past every segment: mg_grow_header refuses` |
| 44 | `                if (a != 0) {`<br>`                    if (out) {` | `                if (1) {`<br>`                    if (out) {` | `FAIL: raise: an export at offset 0 stays 0` |

Rows that end "the grow succeeds (got -1)" are caught first by the raise's own verification, which then refuses; the row's own test stands behind it. Row 42 puts back the second pass the review found (the pointers checked again after the segments moved): exactly the edges test's three cases past a gap fail, `__ZERO + 8` and both past a two-page gap.

- [ ] **Step 7: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c tests/insert_dylib_test.sh
git commit -m "feat(grow): raise a dylib's or bundle's contents to grow its header pad

A dylib has no __PAGEZERO to lower its base into, so its header pad grows
the other way: everything after the load commands moves up by the grow,
and so does every absolute address that names it, in segments, sections,
LC_ROUTINES_64, rebased pointers and symbols. What names the header stays;
what names a byte strictly inside it, or no segment, refuses, and which
segment maps a pointer is decided before anything moves. Code that
addresses the header is repaired as on the executable route. mg_verify
takes the raise's delta from the file type and how far the first section
moved, so the executable route's checks are what they were. A dylib whose
pad is too short is announced as \"contents raised by 0x1000\".

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 3: Move the stabs that hold addresses

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (`#include <mach-o/nlist.h>`; `mg_symtab` and the moved `mg_sym_name`, and new `mg_stab_address` and `mg_sym_address`; `mg_snapshot_take`, `mg_snapshot_free`, `mg_verify_symbols`; `mg_hsym_cb`)
- Modify: `src/grow.h` (`mg_snapshot`'s `symaddr`)
- Modify: `src/mach_compat.h` (`N_AST`, after `CPU_SUBTYPE_MASK`)
- Test: `tests/grow_test.c` (the fixture's `DY_STABS`; Task 2's stab refusal row goes; new tests before `int main(void) {`; calls)

**Interfaces:**
- Consumes: Task 2's `mg_move_symbols`, `mg_verify_symbols`, `check_verify_rejects_raise_with`, `DY_RAISED_AT`; M2a's `mg_sym_name`.
- Produces: `static int mg_stab_address(const struct nlist_64 *nl, int named);` and `static int mg_sym_address(const uint8_t *buf, size_t fsize, const struct symtab_command *st, const struct nlist_64 *nl, int raise);` (1 an address, 0 not, -1 an unknown stab on a raise); `mg_snapshot.symaddr`; `mg_symtab(im, fsize, &st, &nl, &nsyms)` gains `st`; `DY_STABS` and `dy_stabs` in the tests.

**Plan decisions.**

- **The table** is Decision 2's, verbatim: `N_BNSYM`, named `N_FUN`, `N_STSYM`, `N_LCSYM`, `N_SLINE`, and `N_SO` or `N_SOL` with a section, hold addresses and move as `N_SECT` symbols do; `N_ENSYM`, `N_OSO`, unnamed `N_FUN`, `N_GSYM`, `N_OPT`, `N_OLEVEL` and `N_AST` do not; any other stab refuses the raise. "Named" is a non-empty name.
- **One predicate.** `mg_sym_address` decides for the move and for the snapshot, which records each symbol's answer for verification; the tests pin the table row by row. On the lowering, stabs are never addresses, as before.
- **ld64's closing `N_SO`** holds 0 with a section: on a dylib linked at 0 that is the base, and stays; above base 0 it is below the base, and stays. The fixture carries it at both bases.
- **`N_AST`** (0x32) is newer than the 10.9 SDK's `<mach-o/stab.h>`, so `src/mach_compat.h` defines it.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately after (`:4296`):

```c
#define DY_ZEROFAR 128   /* __ZERO at 0x7000 */
```

insert:

```c
#define DY_STABS  32     /* dy_stabs, as symbols 5 to 19 */
```

In `tests/grow_test.c`, replace (`:4320`):

```c
}

static uint8_t *build_dylib_at(uint64_t base, size_t *fsize, int opts) {
```

with:

```c
}

/* A debugging image's stabs, as ld64 writes them for a -g build: `at` is an
 * offset from the base when `moves` (the value is an address), else the
 * value itself. build_dylib_at's string table holds "x.h" at 33 and "a.o"
 * at 37 with them. */
static const struct { uint32_t strx; uint8_t type, sect; uint64_t at; int moves; } dy_stabs[15] = {
    { 33, N_SO, NO_SECT, 0x5000, 0 },     { 37, N_OSO, 3, 0x6ab898db, 0 },
    { 0, N_BNSYM, 1, 0x1010, 1 },         { 23, N_FUN, 1, 0x1010, 1 },
    { 0, N_FUN, NO_SECT, 2, 0 },          { 0, N_ENSYM, 1, 2, 0 },
    { 27, N_GSYM, NO_SECT, 0, 0 },        { 27, N_STSYM, 3, 0x2020, 1 },
    { 0, N_LCSYM, 7, 0x3000, 1 },         { 0, N_SLINE, 1, 0x1011, 1 },
    { 33, N_SOL, 1, 0x1010, 1 },          { 0, N_SO, 1, 0, 0 },
    { 0, N_OPT, NO_SECT, 0, 0 },          { 0, N_OLEVEL, NO_SECT, 2, 0 },
    { 37, N_AST, NO_SECT, 0, 0 },
};

static uint8_t *build_dylib_at(uint64_t base, size_t *fsize, int opts) {
```

In `tests/grow_test.c`, immediately after (`:4507`):

```c
    memcpy(buf + 0x3200, strs, sizeof strs);
```

insert:

```c
    if (opts & DY_STABS) {
        memcpy(buf + 0x3200 + sizeof strs, "x.h\0a.o", 8);
        st->strsize += 8;
        st->nsyms = 20;
        for (int i = 0; i < 15; i++) {
            nl[5 + i].n_un.n_strx = dy_stabs[i].strx;
            nl[5 + i].n_type = dy_stabs[i].type;
            nl[5 + i].n_sect = dy_stabs[i].sect;
            nl[5 + i].n_value = dy_stabs[i].moves ? base + dy_stabs[i].at : dy_stabs[i].at;
        }
    }
```

In `tests/grow_test.c`, replace (`:4787`):

```c
 * be raised; nor can a debugging stab yet. */
```

with:

```c
 * be raised. */
```

In `tests/grow_test.c`, replace (`:4810`):

```c
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    dy_syms(buf, fsize)[4].n_type = N_FUN;
    check_grow_refuses_header_refs("a stab", buf, fsize,
        "ERROR: symbol 4, \"_x\", is a stab of type 0x24, which a raise does not know how to "
        "move; refusing to grow");
```

with:

```c
```

In `tests/grow_test.c`, replace (`:4900`):

```c
static void check_verify_rejects_raise(const char *what, dy_undo undo, const char *needle) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
```

with:

```c
static void check_verify_rejects_raise_with(const char *what, int opts, dy_undo undo,
                                            const char *needle) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL | opts);
```

In `tests/grow_test.c`, replace (`:4918`):

```c
    free(buf);
}
static void dy_unraise_pointer(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x3009] -= 0x10; }
```

with:

```c
    free(buf);
}
static void check_verify_rejects_raise(const char *what, dy_undo undo, const char *needle) {
    check_verify_rejects_raise_with(what, 0, undo, needle);
}
static void dy_unraise_pointer(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x3009] -= 0x10; }
```

In `tests/grow_test.c`, replace (`:4968`):

```c
    free(err);
    free(buf);
}

int main(void) {
```

with:

```c
    free(err);
    free(buf);
}

/* ---- stabs on a raise ----
 * A stab that holds an address names content, which moves, or the header,
 * which does not; one that holds a size, a timestamp or nothing stays. The
 * closing N_SO holds 0, the base of a dylib linked at 0. */
static void check_raise_moves_the_stabs(uint64_t base) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(base, &fsize, DY_STABS);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "stabs: a raise at base %#llx succeeds (got %d)", (unsigned long long)base, r);
    struct nlist_64 *nl = r == 0 ? dy_syms(buf, fsize) : NULL;
    for (int i = 0; nl && i < 15; i++) {
        uint64_t want = dy_stabs[i].moves ? base + dy_stabs[i].at + 0x1000 : dy_stabs[i].at;
        CHECK(nl[5 + i].n_value == want, "stabs: at base %#llx, stab %d (type %#x) is %#llx, "
              "want %#llx", (unsigned long long)base, i, dy_stabs[i].type,
              (unsigned long long)nl[5 + i].n_value, (unsigned long long)want);
    }
    free(buf);
}

static void test_raise_moves_the_stabs_that_hold_addresses(void) {
    check_raise_moves_the_stabs(0);
    check_raise_moves_the_stabs(DY_RAISED_AT);
}

/* N_LSYM is a stab this does not know; an N_STSYM naming the header's
 * inside names what a raise moves apart. */
static void test_raise_refuses_stabs_it_cannot_move(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_STABS);
    dy_syms(buf, fsize)[17].n_type = N_LSYM;
    check_grow_refuses_header_refs("an N_LSYM", buf, fsize,
        "ERROR: symbol 17, \"\", is a stab of type 0x80, which a raise does not know how to "
        "move; refusing to grow");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_STABS);
    dy_syms(buf, fsize)[12].n_value = DY_RAISED_AT + 16;
    check_grow_refuses_header_refs("an N_STSYM inside the header", buf, fsize,
        "ERROR: symbol 12, \"_d\", names 0x10000010, between the header at 0x10000000");
}

/* A lowered executable's stabs stay, whatever they hold. */
static void test_lowering_leaves_the_stabs(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    hsym(buf, fsize, 1)->n_type = N_FUN;
    hsym(buf, fsize, 1)->n_un.n_strx = 1;
    memcpy(buf + 6720, "\0_f", 4);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && hsym(buf, fsize, 1)->n_value == 0x100001000ull,
          "stabs: a lowering leaves a named N_FUN (got %d, %#llx)", r,
          (unsigned long long)hsym(buf, fsize, 1)->n_value);
    free(buf);
}

static void dy_unraise_stab(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[8].n_value -= 0x1000; }
static void dy_raise_ensym(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[10].n_value += 0x1000; }

static void test_verify_watches_the_stabs(void) {
    check_verify_rejects_raise_with("a named N_FUN left where it was", DY_STABS, dy_unraise_stab,
        "ERROR: verify FAILED -- symbol 8 is type 0x24, value 0x10001010 after the grow, and must "
        "be type 0x24, value 0x10002010; refusing.");
    check_verify_rejects_raise_with("an N_ENSYM's size raised", DY_STABS, dy_raise_ensym,
        "symbol 10 is type 0x4e, value 0x1002 after the grow, and must be type 0x4e, value 0x2");
}

int main(void) {
```

In `tests/grow_test.c`, immediately after (`:5194`):

```c
    test_raise_leaves_a_symbol_below_the_base();
```

insert:

```c
    test_raise_moves_the_stabs_that_hold_addresses();
    test_raise_refuses_stabs_it_cannot_move();
    test_lowering_leaves_the_stabs();
    test_verify_watches_the_stabs();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check).
Expected: the build fails compiling `grow_test.c`: `tests/grow_test.c:4334:11: error: use of undeclared identifier 'N_AST'`.

- [ ] **Step 3: The stab table**

In `src/mach_compat.h`, immediately before (`:139`):

```c
#endif /* DRYDOCK_MACH_COMPAT_H */
```

insert:

```c
/* <mach-o/stab.h>'s Swift AST stab, named for its module's AST file. */
#ifndef N_AST
#define N_AST 0x32
#endif

```

In `src/grow.h`, immediately after (`:244`):

```c
    uint8_t *symtype;
```

insert:

```c
    uint8_t *symaddr;
```

In `src/grow.c`, immediately after (`:3`):

```c
#include <mach-o/nlist.h>
```

insert:

```c
#include <mach-o/stab.h>
```

In `src/grow.c`, replace (`:648`):

```c
/* The first LC_SYMTAB's table, or NULL with *nsyms 0 when there is none;
 * -1 when it does not fit within the image. */
struct mg_symtab_ctx { const struct symtab_command *st; };
static int mg_symtab_cb(const struct load_command *lc, void *ctx_) {
    if (lc->cmd != LC_SYMTAB) return 0;
    ((struct mg_symtab_ctx *)ctx_)->st = (const struct symtab_command *)lc;
    return 1;
}
static int mg_symtab(const mi_image *im, size_t fsize, const struct nlist_64 **nl, uint32_t *nsyms) {
    struct mg_symtab_ctx c = { NULL };
    mi_each_lc(im, mg_symtab_cb, &c);
```

with:

```c
/* The first LC_SYMTAB (*st) and its table, or NULL with *nsyms 0 when
 * there is none; -1 when it does not fit within the image. */
struct mg_symtab_ctx { const struct symtab_command *st; };
static int mg_symtab_cb(const struct load_command *lc, void *ctx_) {
    if (lc->cmd != LC_SYMTAB) return 0;
    ((struct mg_symtab_ctx *)ctx_)->st = (const struct symtab_command *)lc;
    return 1;
}
static int mg_symtab(const mi_image *im, size_t fsize, const struct symtab_command **st,
                     const struct nlist_64 **nl, uint32_t *nsyms) {
    struct mg_symtab_ctx c = { NULL };
    mi_each_lc(im, mg_symtab_cb, &c);
    *st = c.st;
```

In `src/grow.c`, replace (`:670`):

```c
int mg_snapshot_take(const uint8_t *buf, size_t fsize, mg_snapshot *s) {
    mi_image im;
    const struct nlist_64 *nl;
    char why[256];
    const struct mach_header_64 *h = (const struct mach_header_64 *)buf;
    s->refs = NULL;
    s->nrefs = 0;
    s->symval = NULL;
    s->symtype = NULL;
```

with:

```c
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

/* Whether stab `nl` holds an address: 1 if it does; 0 if its value is a
 * size, a timestamp or nothing; -1 for a type this does not know. `named`:
 * its name is not empty. */
static int mg_stab_address(const struct nlist_64 *nl, int named) {
    switch (nl->n_type) {
    case N_BNSYM: case N_STSYM: case N_LCSYM: case N_SLINE:
        return 1;
    case N_FUN:
        return named;
    case N_SO: case N_SOL:
        return nl->n_sect != NO_SECT;
    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:
        return 0;
    }
    return -1;
}

/* Whether symbol `nl` of LC_SYMTAB `st` holds an address a grow moves: an
 * N_SECT symbol, not a stab; and, on a raise, a stab mg_stab_address says
 * does. -1 for a stab of a type it does not know, on a raise. */
static int mg_sym_address(const uint8_t *buf, size_t fsize, const struct symtab_command *st,
                          const struct nlist_64 *nl, int raise) {
    const char *name;
    if (!(nl->n_type & N_STAB)) return (nl->n_type & N_TYPE) == N_SECT;
    return raise ? mg_stab_address(nl, mg_sym_name(buf, fsize, st, nl, &name) > 0) : 0;
}

int mg_snapshot_take(const uint8_t *buf, size_t fsize, mg_snapshot *s) {
    mi_image im;
    const struct symtab_command *st;
    const struct nlist_64 *nl;
    char why[256];
    const struct mach_header_64 *h = (const struct mach_header_64 *)buf;
    s->refs = NULL;
    s->nrefs = 0;
    s->symval = NULL;
    s->symtype = NULL;
    s->symaddr = NULL;
```

In `src/grow.c`, replace (`:730`):

```c
        mg_symtab(&im, fsize, &nl, &s->nsyms) != 0 ||
        !(s->symval = (uint64_t *)malloc((s->nsyms + 1) * sizeof *s->symval)) ||
        !(s->symtype = (uint8_t *)malloc(s->nsyms + 1)) ||
        mg_rebases_read(buf, fsize, &s->rb, why, sizeof why) != 0) {
        mg_snapshot_free(s);
        return -1;
    }
    for (uint32_t i = 0; i < s->nsyms; i++) {
        s->symval[i] = nl[i].n_value;
        s->symtype[i] = nl[i].n_type;
```

with:

```c
        mg_symtab(&im, fsize, &st, &nl, &s->nsyms) != 0 ||
        !(s->symval = (uint64_t *)malloc((s->nsyms + 1) * sizeof *s->symval)) ||
        !(s->symtype = (uint8_t *)malloc(s->nsyms + 1)) ||
        !(s->symaddr = (uint8_t *)malloc(s->nsyms + 1)) ||
        mg_rebases_read(buf, fsize, &s->rb, why, sizeof why) != 0) {
        mg_snapshot_free(s);
        return -1;
    }
    for (uint32_t i = 0; i < s->nsyms; i++) {
        s->symval[i] = nl[i].n_value;
        s->symtype[i] = nl[i].n_type;
        s->symaddr[i] = mg_sym_address(buf, fsize, st, &nl[i], s->raise) == 1;
```

In `src/grow.c`, immediately after (`:751`):

```c
    free(s->symtype); s->symtype = NULL; s->nsyms = 0;
```

insert:

```c
    free(s->symaddr); s->symaddr = NULL;
```

In `src/grow.c`, replace (`:822`):

```c
/* Every symbol keeps its type, and its value unless it is an N_SECT symbol,
 * not a stab: one that named the header names it where it is now, and one
 * that named content, at the first section or past it, has moved `delta`. */
static int mg_verify_symbols(const mi_image *im, size_t fsize, const mg_snapshot *before,
                             uint64_t base, uint64_t delta) {
    const struct nlist_64 *nl;
    uint32_t nsyms;
    if (mg_symtab(im, fsize, &nl, &nsyms) != 0) {
```

with:

```c
/* Every symbol keeps its type, and its value unless it held an address a
 * grow moves (mg_sym_address): one that named the header names it where it
 * is now, and one that named content, at the first section or past it, has
 * moved `delta`. */
static int mg_verify_symbols(const mi_image *im, size_t fsize, const mg_snapshot *before,
                             uint64_t base, uint64_t delta) {
    const struct symtab_command *st;
    const struct nlist_64 *nl;
    uint32_t nsyms;
    if (mg_symtab(im, fsize, &st, &nl, &nsyms) != 0) {
```

In `src/grow.c`, replace (`:844`):

```c
        if (!(t & N_STAB) && (t & N_TYPE) == N_SECT)
```

with:

```c
        if (before->symaddr[i])
```

In `src/grow.c`, replace (`:1675`):

```c
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

/* The symbols a grow moves: each N_SECT symbol, not a stab. With `patch`,
 * on a lowering, one whose value is `base` loses `grow`, following the
 * header down; on a raise, one that names content, at base + `first` or
 * past it, gains `grow`, following the content up. Without `patch`, this
 * checks that the symbol table lies within the image, and says so on stderr
 * when it does not; on a raise, it refuses a stab. Either way, one that names
 * a byte strictly between the header and its first content, at base +
 * `first`, is refused, saying so. Returns 0, or -1. */
```

with:

```c
/* The symbols a grow moves (mg_sym_address). With `patch`, on a lowering,
 * one whose value is `base` loses `grow`, following the header down; on a
 * raise, one that names content, at base + `first` or past it, gains
 * `grow`, following the content up. Without `patch`, this checks that the
 * symbol table lies within the image, and says so on stderr when it does
 * not; on a raise, it refuses a stab of a type it does not know. Either way,
 * one that names a byte strictly between the header and its first content,
 * at base + `first`, is refused, saying so. Returns 0, or -1. */
```

In `src/grow.c`, replace (`:1710`):

```c
        if (c->raise && (nl[i].n_type & N_STAB)) {
            int len = mg_sym_name(c->buf, c->fsize, st, &nl[i], &name);
            fprintf(stderr, "ERROR: symbol %u, \"%.*s\", is a stab of type %#x, which a raise "
                            "does not know how to move; refusing to grow\n", i, len, name,
                    nl[i].n_type);
            c->bad = 1;
            return 1;
        }
        if ((nl[i].n_type & N_STAB) || (nl[i].n_type & N_TYPE) != N_SECT) continue;
```

with:

```c
        int addr = mg_sym_address(c->buf, c->fsize, st, &nl[i], c->raise);
        if (addr < 0) {
            int len = mg_sym_name(c->buf, c->fsize, st, &nl[i], &name);
            fprintf(stderr, "ERROR: symbol %u, \"%.*s\", is a stab of type %#x, which a raise "
                            "does not know how to move; refusing to grow\n", i, len, name,
                    nl[i].n_type);
            c->bad = 1;
            return 1;
        }
        if (!addr) continue;
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    case N_BNSYM: case N_STSYM: case N_LCSYM: case N_SLINE:` | `    case N_STSYM: case N_LCSYM: case N_SLINE:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 2 | `    case N_BNSYM: case N_STSYM: case N_LCSYM: case N_SLINE:` | `    case N_BNSYM: case N_LCSYM: case N_SLINE:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 3 | `    case N_BNSYM: case N_STSYM: case N_LCSYM: case N_SLINE:` | `    case N_BNSYM: case N_STSYM: case N_SLINE:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 4 | `    case N_BNSYM: case N_STSYM: case N_LCSYM: case N_SLINE:` | `    case N_BNSYM: case N_STSYM: case N_LCSYM:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 5 | `        return named;` | `        return 1;` | `FAIL: stabs: a raise at base 0 succeeds (got -1)` |
| 6 | `        return named;` | `        return 0;` | `FAIL: stabs: at base 0, stab 3 (type 0x24) is 0x1010` |
| 7 | `        return nl->n_sect != NO_SECT;` | `        return 1;` | `FAIL: stabs: at base 0, stab 0 (type 0x64) is 0x6000` |
| 8 | `        return nl->n_sect != NO_SECT;` | `        return 0;` | `FAIL: stabs: at base 0, stab 10 (type 0x84) is 0x1010` |
| 9 | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:` | `    case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 10 | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:` | `    case N_ENSYM: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 11 | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:` | `    case N_ENSYM: case N_OSO: case N_OPT: case N_OLEVEL: case N_AST:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 12 | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:` | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OLEVEL: case N_AST:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 13 | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:` | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_AST:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 14 | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL: case N_AST:` | `    case N_ENSYM: case N_OSO: case N_GSYM: case N_OPT: case N_OLEVEL:` | `FAIL: stabs: a raise at base 0 succeeds` |
| 15 | `    if (!(nl->n_type & N_STAB)) return (nl->n_type & N_TYPE) == N_SECT;` | `    if (!(nl->n_type & N_STAB)) return 1;` | `FAIL: symbols: type 0x3, value 0x100000000, is 0xfffff000` |
| 16 | `    return raise ? mg_stab_address(nl, mg_sym_name(buf, fsize, st, nl, &name) > 0) : 0;` | `    return mg_stab_address(nl, mg_sym_name(buf, fsize, st, nl, &name) > 0);` | `FAIL: symbols: type 0x2e, value 0x100000000, is 0xfffff000` |
| 17 | `    return raise ? mg_stab_address(nl, mg_sym_name(buf, fsize, st, nl, &name) > 0) : 0;` | `    return raise ? mg_stab_address(nl, mg_sym_name(buf, fsize, st, nl, &name) >= 0) : 0;` | `FAIL: stabs: a raise at base 0 succeeds (got -1)` |
| 18 | `        if (addr < 0) {` | `        if (0) {` | `FAIL: an N_LSYM: the refusal says` |
| 19 | `        if (!addr) continue;` | `        (void)0;` | `FAIL: stabs: a raise at base 0 succeeds` |
| 20 | `        s->symaddr[i] = mg_sym_address(buf, fsize, st, &nl[i], s->raise) == 1;` | `        s->symaddr[i] = 0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 21 | `        if (before->symaddr[i])` | `        if (1)` | `FAIL: stabs: a raise at base 0 succeeds` |

- [ ] **Step 6: Commit**

```bash
git add src/grow.c src/grow.h src/mach_compat.h tests/grow_test.c
git commit -m "feat(grow): move the stabs that hold addresses when a dylib is raised

A debugging image's stabs name functions and data by address, and a raise
moves those: N_BNSYM, named N_FUN, N_STSYM, N_LCSYM, N_SLINE, and N_SO or
N_SOL with a section move as N_SECT symbols do. N_ENSYM, N_OSO, unnamed
N_FUN, N_GSYM, N_OPT, N_OLEVEL and N_AST hold sizes, timestamps or nothing,
and stay. A stab of any other type refuses the raise.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 4: Drop split info, give `mg_classify` its route, and accept an upward dylib

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (new `mg_find_cb` and `mg_has_cmd`; `mg_ensure_pad`'s announcement; `mg_classify_cb`, `mg_classify`; new `mg_drop_split_info` before `mg_repair_refs`; `mg_grow_header`'s classify call and the drop before the snapshot)
- Modify: `src/grow.h` (`mg_ensure_pad`'s contract; `mg_classify`; `mg_grow_header`'s contract)
- Modify: `src/rewrite.c` (the two comments that said a grow never changes the load commands)
- Test: `tests/grow_test.c` (new tests before `int main(void) {`; calls)
- Test: `tests/script_test.c` (includes; a new test; its call)

**Interfaces:**
- Consumes: Task 2's `raise`, the snapshot; `LC_STRIP_KINDS` and `lc_kind_by_name` (`src/lc_kinds.h`); in the tests, `hr_add_lc`, `DY_SPLIT`.
- Produces: `int mg_classify(const uint8_t *buf, size_t fsize, int raise);`; `static void mg_drop_split_info(uint8_t *buf);`; `static int mg_has_cmd(uint8_t *buf, size_t fsize, uint32_t cmd);` (Task 5 uses it).

**Plan decisions.**

- **Why drop it** is Decision 4: after a raise its offsets are stale, and dropping it is the one choice this suite can fully check. The payload stays in `__LINKEDIT`, unreferenced; the edit pass's re-pack then drops it (Task 9 shows it).
- **When:** its own step, after every refusal (so a refused image is untouched) and before the snapshot (so `mg_verify` does not watch its `dataoff`), as Decision 4's mechanics say. Every split info is deleted, and the command after each moves down whole; the freed bytes are zeroed.
- **`mg_classify(buf, fsize, raise)`** accepts `LC_SEGMENT_SPLIT_INFO` on the raise only; the lowering refuses it, as before.
- **`LC_LOAD_UPWARD_DYLIB`** names a dylib and nothing a grow moves, like `LC_LOAD_DYLIB`, and was never classified, so any image carrying one was refused ("Unknown means unsafe"). Measured, 13 of the 1,180 system dylibs and bundles carry one (AppKit, HIToolbox, Metadata and ten of libSystem's parts), and no host executable does. It is accepted on both routes.
- **No statement can name split info**, so `src/rewrite.c`'s rebuild after a grow still matches the operations its counting pass matched; `script_test` pins it, and the two comments that said a grow never changes the load commands say what it does.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately before (`:5036`):

```c
int main(void) {
```

insert:

```c
/* ---- split info ----
 * A raise leaves LC_SEGMENT_SPLIT_INFO's offsets stale, so it deletes the
 * command, and its payload (DY_SPLIT: 8 bytes of 0x5a) stays, unreferenced.
 * A lowering refuses it, as before. */
static void test_raise_drops_split_info(void) {
    size_t fsize;
    uint8_t *buf = build_dylib(&fsize, DY_SPLIT | DY_ROUTINES);
    struct mach_header_64 h0 = *(struct mach_header_64 *)buf;
    uint8_t *after = dy_find(buf, LC_SEGMENT_SPLIT_INFO) + sizeof(struct linkedit_data_command);
    ((struct routines_command_64 *)after)->reserved6 = 0x5a5a5a5a5a5a5a5aull;   /* the last 8 bytes */
    struct routines_command_64 rt0 = *(struct routines_command_64 *)after;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct routines_command_64 *rt = (struct routines_command_64 *)find_lc(buf, fsize, LC_ROUTINES_64);
    static const uint8_t payload[8] = { 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a };
    CHECK(r == 0 && !find_lc(buf, fsize, LC_SEGMENT_SPLIT_INFO) && h->ncmds == h0.ncmds - 1 &&
          h->sizeofcmds == h0.sizeofcmds - sizeof(struct linkedit_data_command),
          "split info: the raise deletes the command (got %d, %u commands, %u bytes)", r,
          h->ncmds, h->sizeofcmds);
    CHECK(rt && rt->cmdsize == rt0.cmdsize && rt->init_address == rt0.init_address + 0x1000 &&
          rt->reserved6 == rt0.reserved6, "split info: the command after it moved down whole");
    CHECK(memcmp(buf + 0x3098 + 0x1000, payload, sizeof payload) == 0,
          "split info: its payload stays where it was");
    CHECK(buf[sizeof *h + h->sizeofcmds] == 0 &&
          memcmp(buf + sizeof *h + h->sizeofcmds, buf + sizeof *h + h->sizeofcmds + 1,
                 sizeof(struct linkedit_data_command) - 1) == 0,
          "split info: the bytes it held are zero");
    free(buf);
}

static void test_raise_drops_every_split_info(void) {
    size_t fsize;
    uint8_t *buf = build_dylib(&fsize, DY_SPLIT);
    hr_add_lc(buf, LC_SEGMENT_SPLIT_INFO, 0x3098, "\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a", 8);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && !find_lc(buf, fsize, LC_SEGMENT_SPLIT_INFO),
          "split info: a raise deletes both of two (got %d)", r);
    free(buf);
}

static void test_lowering_refuses_split_info(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, 0);
    hr_add_lc(buf, LC_SEGMENT_SPLIT_INFO, 6656, "\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a", 8);
    check_grow_refuses_header_refs("split info on an executable", buf, fsize,
        "ERROR: LC_SEGMENT_SPLIT_INFO carries base-relative offsets that are not re-based");
}

/* LC_LOAD_UPWARD_DYLIB names a dylib, as LC_LOAD_DYLIB does, and nothing a
 * grow moves; AppKit, HIToolbox, Metadata and ten of libSystem's parts carry
 * one. */
static void test_grow_takes_an_upward_dylib(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_dylib(&fsize, 0);
    ((struct load_command *)dy_find(buf, LC_LOAD_DYLIB))->cmd = LC_LOAD_UPWARD_DYLIB;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "upward: a dylib with an upward dylib is raised (got %d)", r);
    free(buf);
    buf = build_image(&fsize, &sect_off, 0);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct dylib_command *d = (struct dylib_command *)((uint8_t *)(h + 1) + h->sizeofcmds);
    d->cmd = LC_LOAD_UPWARD_DYLIB;
    d->cmdsize = 32;
    d->dylib.name.offset = sizeof *d;
    memcpy(d + 1, "/x", 3);
    h->ncmds++;
    h->sizeofcmds += 32;
    r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "upward: an executable with an upward dylib is lowered (got %d)", r);
    free(buf);
}

static void test_ensure_pad_announces_dropped_split_info(void) {
    size_t fsize;
    int r;
    uint8_t *buf = build_dylib(&fsize, DY_SPLIT);
    uint32_t lc_end = (uint32_t)sizeof(struct mach_header_64) +
                      ((struct mach_header_64 *)buf)->sizeofcmds;
    char want[192];
    snprintf(want, sizeof want, "t: grew the header pad by 4096 bytes (%u -> %u available); "
             "contents raised by 0x1000; dropped LC_SEGMENT_SPLIT_INFO; repaired 1 reference to "
             "the header\n", DY_F - lc_end, DY_F + 0x1000 - lc_end + 16);
    char *err = ensure_pad_stderr(&buf, &fsize, DY_F + 1, &r);
    CHECK(r == 0 && strcmp(err, want) == 0, "ensure_pad on a dylib with split info: announced "
          "as '%s' (got %d):\n%s", want, r, err);
    free(err);
    free(buf);
}

```

In `tests/grow_test.c`, immediately after (`:5287`):

```c
    test_verify_watches_the_stabs();
```

insert:

```c
    test_raise_drops_split_info();
    test_raise_drops_every_split_info();
    test_lowering_refuses_split_info();
    test_ensure_pad_announces_dropped_split_info();
    test_grow_takes_an_upward_dylib();
```

In `tests/script_test.c`, immediately after (`:11`):

```c
#include "relations.h"
```

insert:

```c
#include "lc_kinds.h"
#include <mach-o/loader.h>
```

In `tests/script_test.c`, immediately before (`:831`):

```c
int main(void) {
```

insert:

```c
/* A header grow that raises a dylib deletes its LC_SEGMENT_SPLIT_INFO, and
 * src/rewrite.c rebuilds the load commands after a grow expecting the same
 * statements to match them: so no statement may name that command. */
static void test_no_statement_names_split_info(void) {
    uint32_t cmd = 0;
    CHECK(lc_kind_by_name("uuid", &cmd) == 0 && cmd == LC_UUID,
          "load-command kinds: uuid names LC_UUID (got %#x)", cmd);
    for (size_t i = 0; i < LC_STRIP_KINDS_COUNT; i++)
        CHECK(LC_STRIP_KINDS[i].cmd != LC_SEGMENT_SPLIT_INFO,
              "load-command delete %s names LC_SEGMENT_SPLIT_INFO, which a grow may drop",
              LC_STRIP_KINDS[i].name);
}

```

In `tests/script_test.c`, immediately after (`:887`):

```c
    test_objc_methods_set_takes_only_absolute();
```

insert:

```c
    test_no_statement_names_split_info();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"` and `"$B/script_test"`.
Expected: `grow_test` exits 1 with 7 `FAIL:` lines:

```
FAIL: split info: the raise deletes the command (got -1, 12 commands, 1160 bytes)
FAIL: split info: the command after it moved down whole
FAIL: split info: its payload stays where it was
FAIL: split info: a raise deletes both of two (got -1)
FAIL: ensure_pad on a dylib with split info: announced as 't: grew the header pad by 4096 bytes (2976 -> 7088 available); contents raised by 0x1000; dropped LC_SEGMENT_SPLIT_INFO; repaired 1 reference to the header
FAIL: upward: a dylib with an upward dylib is raised (got -1)
FAIL: upward: an executable with an upward dylib is lowered (got -1)
```

(the last `ensure_pad` line goes on to show the refusal it got). `script_test` passes: it is a guard, and nothing names split info today; row 14 below is its positive control.

- [ ] **Step 3: Drop split info, and give `mg_classify` its route**

In `src/grow.h`, replace (`:119`):

```c
 * contents raised by 0xN" for a dylib or bundle, ending "; repaired N
```

with:

```c
 * contents raised by 0xN" for a dylib or bundle, then "; dropped
 * LC_SEGMENT_SPLIT_INFO" if the raise dropped it, ending "; repaired N
```

In `src/grow.h`, replace (`:396`):

```c

int mg_classify(const uint8_t *buf, size_t fsize);
```

with:

```c
/* 0 if a grow can vouch for every load command and section type of the
 * image, on the route `raise` says: LC_SEGMENT_SPLIT_INFO only on a raise,
 * which drops it. Otherwise -1, having said why on stderr. */
int mg_classify(const uint8_t *buf, size_t fsize, int raise);
```

In `src/grow.h`, replace (`:447`):

```c
 * rebased pointer that does. A failure partway through growing can leave the
 * buffer modified (see mg_ensure_pad).
```

with:

```c
 * rebased pointer that does. A raise deletes LC_SEGMENT_SPLIT_INFO, whose
 * offsets it would leave stale, leaving its payload unreferenced. A failure
 * partway through growing can leave the buffer modified (see mg_ensure_pad).
```

In `src/grow.c`, immediately before (`:48`):

```c
/* The image base, for mg_ensure_pad's announcement; 0 if unreadable. */
```

insert:

```c
/* Whether the image in `buf` has a `cmd` load command; 0 if unreadable. */
static int mg_find_cb(const struct load_command *lc, void *ctx_) {
    return lc->cmd == *(const uint32_t *)ctx_;
}
static int mg_has_cmd(uint8_t *buf, size_t fsize, uint32_t cmd) {
    mi_image im;
    return mi_wrap(buf, fsize, &im) == 0 && !mi_each_lc(&im, mg_find_cb, &cmd);
}

```

In `src/grow.c`, immediately before (`:95`):

```c
    int64_t refs = mhr_scan(*pbuf, *pfsize, base_before, NULL, NULL);
```

insert:

```c
    int split = raise && mg_has_cmd(*pbuf, *pfsize, LC_SEGMENT_SPLIT_INFO);
```

In `src/grow.c`, immediately after (`:126`):

```c
                (unsigned long long)mg_base_of(*pbuf, *pfsize));
```

insert:

```c
    if (split) fprintf(stderr, "; dropped LC_SEGMENT_SPLIT_INFO");
```

In `src/grow.c`, replace (`:1244`):

```c
    (void)ctx_;
    const char *why = NULL;
```

with:

```c
    const char *why = NULL;
```

In `src/grow.c`, immediately after (`:1269`):

```c
        case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB: case LC_PREBOUND_DYLIB:
```

insert:

```c
        case LC_LOAD_UPWARD_DYLIB:
```

In `src/grow.c`, immediately after (`:1281`):

```c
        case LC_SEGMENT_SPLIT_INFO:
```

insert:

```c
            if (*(const int *)ctx_) break;       /* a raise drops it */
```

In `src/grow.c`, replace (`:1341`):

```c
int mg_classify(const uint8_t *buf, size_t fsize) {
```

with:

```c
int mg_classify(const uint8_t *buf, size_t fsize, int raise) {
```

In `src/grow.c`, replace (`:1353`):

```c
    return mi_each_lc(&im, mg_classify_cb, NULL) ? 0 : -1;
```

with:

```c
    return mi_each_lc(&im, mg_classify_cb, &raise) ? 0 : -1;
```

In `src/grow.c`, immediately before (`:1876`):

```c
/* A grow puts the header and its code `grow` bytes closer together on
```

insert:

```c
/* Deletes each LC_SEGMENT_SPLIT_INFO, whose offsets a raise would leave
 * stale, from the load commands of the validated image in `buf`; its
 * payload stays, unreferenced. */
static void mg_drop_split_info(uint8_t *buf) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *lc = (uint8_t *)(h + 1), *end = lc + h->sizeofcmds;
    for (uint32_t i = 0; i < h->ncmds;) {
        uint32_t size = ((struct load_command *)lc)->cmdsize;
        if (((struct load_command *)lc)->cmd != LC_SEGMENT_SPLIT_INFO) {
            lc += size;
            i++;
            continue;
        }
        memmove(lc, lc + size, (size_t)(end - lc - size));
        end -= size;
        memset(end, 0, size);
        h->ncmds--;
        h->sizeofcmds -= size;
    }
}

```

In `src/grow.c`, replace (`:2070`):

```c
    if (mg_classify(buf, fsize) != 0) return -1;
```

with:

```c
    if (mg_classify(buf, fsize, raise) != 0) return -1;
```

In `src/grow.c`, replace (`:2136`):

```c
    }

    /* Phase 4 prep: snapshot every base-relative resolved address BEFORE touching
```

with:

```c
    }

    if (raise) mg_drop_split_info(buf);

    /* Phase 4 prep: snapshot every base-relative resolved address BEFORE touching
```

In `src/rewrite.c`, replace (`:672`):

```c
     * not a header grow later replaces the TABLE this call built (the SET
     * of load commands -- and so which operations match -- does not change
     * when the header grows; only file offsets elsewhere in the image do). */
```

with:

```c
     * not a header grow later replaces the TABLE this call built (which
     * operations match does not change when the header grows: a raise drops
     * LC_SEGMENT_SPLIT_INFO, which no statement can name, and otherwise only
     * file offsets and addresses elsewhere in the image move). */
```

In `src/rewrite.c`, replace (`:745`):

```c
         * deliberately: this walks the SAME load commands the call above
         * already counted (the grow moved offsets elsewhere in the image,
         * not which command matches which operation), so passing the real
```

with:

```c
         * deliberately: this walks the load commands the call above already
         * counted, less any LC_SEGMENT_SPLIT_INFO a raise dropped, which no
         * operation matches, so passing the real
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, `"$B/script_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`, `script_test: 0 failure(s)`; green.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`, but row 14's `tests/script_test.c`; test binary `$B/grow_test`, but row 14's `$B/script_test`)

| # | in | replace | with | must fail |
|---|---|---|---|---|
| 1 | `src/grow.c` | `            if (*(const int *)ctx_) break;       /* a raise drops it */` | *(delete it)* | `FAIL: split info: the raise deletes the command` |
| 2 | `src/grow.c` | `            if (*(const int *)ctx_) break;       /* a raise drops it */` | `            if (1) break;` | `FAIL: split info on an executable: mg_grow_header refuses` |
| 3 | `src/grow.c` | `    if (mg_classify(buf, fsize, raise) != 0) return -1;` | `    if (mg_classify(buf, fsize, 0) != 0) return -1;` | `FAIL: split info: the raise deletes the command` |
| 4 | `src/grow.c` | `    if (mg_classify(buf, fsize, raise) != 0) return -1;` | `    if (mg_classify(buf, fsize, 1) != 0) return -1;` | `FAIL: split info on an executable: mg_grow_header refuses` |
| 5 | `src/grow.c` | `    if (raise) mg_drop_split_info(buf);` | `    if (0) mg_drop_split_info(buf);` | `FAIL: split info: the raise deletes the command` |
| 6 | `src/grow.c` | `        memmove(lc, lc + size, (size_t)(end - lc - size));` | `        (void)0;` | `FAIL: split info: the` |
| 7 | `src/grow.c` | `        memset(end, 0, size);` | `        (void)0;` | `FAIL: split info: the bytes it held are zero` |
| 8 | `src/grow.c` | `        h->ncmds--;`<br>`        h->sizeofcmds -= size;` | `        h->sizeofcmds -= size;` | `FAIL: split info` |
| 9 | `src/grow.c` | `        h->ncmds--;`<br>`        h->sizeofcmds -= size;` | `        h->ncmds--;` | `FAIL: split info` |
| 10 | `src/grow.c` | `        h->ncmds--;`<br>`        h->sizeofcmds -= size;`<br>`    }` | `        h->ncmds--;`<br>`        h->sizeofcmds -= size;`<br>`        lc += ((struct load_command *)lc)->cmdsize;`<br>`        i++;`<br>`    }` | `FAIL: split info: a raise deletes both of two` |
| 11 | `src/grow.c` | `    int split = raise && mg_has_cmd(*pbuf, *pfsize, LC_SEGMENT_SPLIT_INFO);` | `    int split = 0;` | `FAIL: ensure_pad on a dylib with split info: announced` |
| 12 | `src/grow.c` | `    return lc->cmd == *(const uint32_t *)ctx_;` | `    return 1;` | `FAIL: ensure_pad on a dylib: announced as` |
| 13 | `src/grow.c` | `            first - first_before, pad_avail, first - (uint32_t)sizeof *hdr - hdr->sizeofcmds);` | `            first - first_before, pad_avail, first - cur_lc_end);` | `FAIL: ensure_pad on a dylib with split info: announced` |
| 14 | `tests/script_test.c` | `        CHECK(LC_STRIP_KINDS[i].cmd != LC_SEGMENT_SPLIT_INFO,` | `        CHECK(LC_STRIP_KINDS[i].cmd != LC_UUID,` | `FAIL: load-command delete uuid names LC_SEGMENT_SPLIT_INFO` (`$B/script_test`) |
| 15 | `src/grow.c` | `        case LC_LOAD_UPWARD_DYLIB:` | *(delete it)* | `FAIL: upward: a dylib with an upward dylib is raised` |

- [ ] **Step 6: Commit**

```bash
git add src/grow.c src/grow.h src/rewrite.c tests/grow_test.c tests/script_test.c
git commit -m "feat(grow): drop LC_SEGMENT_SPLIT_INFO when a dylib is raised

A raise leaves split info's recorded positions stale, and only a shared
cache build reads them, so the raise deletes the command: a cache build
then skips the dylib, and loading it from its file is as before. The
payload stays, unreferenced. mg_classify takes the route, and a lowering
still refuses split info. LC_LOAD_UPWARD_DYLIB, which no grow had
classified, is accepted: AppKit, HIToolbox, Metadata and ten of
libSystem's parts carry one. No statement can name split info, so a
rewrite's rebuild after a grow still matches what it counted.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 5: Replace the UUID

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (`#include <CommonCrypto/CommonDigest.h>`; `mg_ensure_pad`'s announcement; `LC_UUID` in `mg_raise_ok_cb`; new `mg_raised_uuid`, and `LC_UUID` in `mg_raise_cb`)
- Modify: `src/grow.h` (`mg_ensure_pad`'s contract; new `mg_raised_uuid`; `mg_grow_header`'s contract)
- Test: `tests/grow_test.c` (the two announcements Task 2 and Task 4 pinned; new tests before `int main(void) {`; calls)

**Interfaces:**
- Consumes: Task 1's `mg_raise_ok_cb`; Task 2's `mg_raise_cb`; Task 4's `mg_has_cmd`.
- Produces: `void mg_raised_uuid(const uint8_t old[16], uint64_t grow, uint8_t out[16]);` (Task 6's expectation calls it).

**Plan decisions.**

- **Decision 5**, with the one thing it left open settled: SHA-256 over the old UUID's 16 bytes and then G as 8 bytes, little-endian; the first 16 bytes of the digest, with the version nibble 4 and the RFC 4122 variant. CommonCrypto's `CC_SHA256` is in libSystem on 10.9 and on the CI runner's SDK. The test's expected UUIDs were computed with `shasum -a 256`, not with this code.
- **The announcement:** "…; contents raised by 0x1000; new UUID", only when the image has an `LC_UUID`.
- **A short `LC_UUID`** (fewer than 24 bytes) is refused before anything moves, like Task 1's short commands.
- **The lowering keeps its UUID** (no vm address moves); a test pins it.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, replace (`:4963`):

```c
             "contents raised by 0x1000; repaired 1 reference to the header\n",
```

with:

```c
             "contents raised by 0x1000; new UUID; repaired 1 reference to the header\n",
```

In `tests/grow_test.c`, replace (`:5116`):

```c
             "contents raised by 0x1000; dropped LC_SEGMENT_SPLIT_INFO; repaired 1 reference to "
             "the header\n", DY_F - lc_end, DY_F + 0x1000 - lc_end + 16);
    char *err = ensure_pad_stderr(&buf, &fsize, DY_F + 1, &r);
    CHECK(r == 0 && strcmp(err, want) == 0, "ensure_pad on a dylib with split info: announced "
          "as '%s' (got %d):\n%s", want, r, err);
```

with:

```c
             "contents raised by 0x1000; new UUID; dropped LC_SEGMENT_SPLIT_INFO; repaired 1 "
             "reference to the header\n", DY_F - lc_end, DY_F + 0x1000 - lc_end + 16);
    char *err = ensure_pad_stderr(&buf, &fsize, DY_F + 1, &r);
    CHECK(r == 0 && strcmp(err, want) == 0, "ensure_pad on a dylib with split info: announced "
          "as '%s' (got %d):\n%s", want, r, err);
    free(err);
    free(buf);
}

/* ---- the UUID ----
 * build_dylib's UUID is 10 11 ... 1f. The digests, taken with shasum -a 256
 * over those 16 bytes and then 00 10 00 00 00 00 00 00 (or 00 20 ...), begin
 * 02990cf9 272abb54 62af123c 32f75b2f and e5407efb 8d35fadb 31323fb6
 * 50fa04b5; the version nibble and variant bits make them these. */
static const uint8_t dy_uuid_raised[2][16] = {
    { 0x02, 0x99, 0x0c, 0xf9, 0x27, 0x2a, 0x4b, 0x54, 0xa2, 0xaf, 0x12, 0x3c, 0x32, 0xf7, 0x5b, 0x2f },
    { 0xe5, 0x40, 0x7e, 0xfb, 0x8d, 0x35, 0x4a, 0xdb, 0xb1, 0x32, 0x3f, 0xb6, 0x50, 0xfa, 0x04, 0xb5 },
};

static void test_raised_uuid_is_derived(void) {
    uint8_t old[16], out[16];
    for (int i = 0; i < 16; i++) old[i] = (uint8_t)(0x10 + i);
    mg_raised_uuid(old, 0x1000, out);
    CHECK(memcmp(out, dy_uuid_raised[0], 16) == 0, "uuid: raised by 0x1000");
    mg_raised_uuid(old, 0x2000, out);
    CHECK(memcmp(out, dy_uuid_raised[1], 16) == 0, "uuid: raised by 0x2000");
    memcpy(out, old, 16);
    mg_raised_uuid(out, 0x1000, out);
    CHECK(memcmp(out, dy_uuid_raised[0], 16) == 0, "uuid: derived in place");
}

static void test_raise_replaces_the_uuid(void) {
    static const uint32_t req[2] = { 0x1000, 0x1001 };
    for (int i = 0; i < 2; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib(&fsize, 0);
        int r = mg_grow_header(&buf, &fsize, req[i]);
        struct uuid_command *u = (struct uuid_command *)find_lc(buf, fsize, LC_UUID);
        CHECK(r == 0 && u && memcmp(u->uuid, dy_uuid_raised[i], 16) == 0,
              "uuid: a raise by %#x replaces it (got %d)", i ? 0x2000 : 0x1000, r);
        free(buf);
    }
}

/* A lowering moves no address a dSYM holds, so it keeps its UUID. */
static void test_lowering_keeps_the_uuid(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, 0);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct uuid_command *u = (struct uuid_command *)((uint8_t *)(h + 1) + h->sizeofcmds);
    u->cmd = LC_UUID;
    u->cmdsize = sizeof *u;
    for (int i = 0; i < 16; i++) u->uuid[i] = (uint8_t)(0x10 + i);
    h->ncmds++;
    h->sizeofcmds += sizeof *u;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    u = (struct uuid_command *)find_lc(buf, fsize, LC_UUID);
    CHECK(r == 0 && u && u->uuid[0] == 0x10 && u->uuid[15] == 0x1f,
          "uuid: a lowering keeps it (got %d)", r);
    free(buf);
}

static void test_raise_refuses_a_short_uuid(void) {
    size_t fsize;
    uint8_t *buf = build_dylib(&fsize, 0);
    ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_UUID;
    check_grow_refuses_header_refs("a short LC_UUID", buf, fsize,
        "ERROR: LC_UUID is 16 bytes, too short to hold its UUID; refusing to grow");
}

/* Without an LC_UUID, a raise has none to replace, and says nothing of one. */
static void test_ensure_pad_announces_no_uuid_it_has_not(void) {
    size_t fsize;
    int r;
    uint8_t *buf = build_dylib(&fsize, 0);
    ((struct load_command *)dy_find(buf, LC_UUID))->cmd = LC_SOURCE_VERSION;
    char *err = ensure_pad_stderr(&buf, &fsize, DY_F + 1, &r);
    CHECK(r == 0 && strstr(err, "contents raised by 0x1000; repaired 1 reference") != NULL,
          "ensure_pad on a dylib with no UUID: says no new one (got %d):\n%s", r, err);
```

In `tests/grow_test.c`, immediately after (`:5366`):

```c
    test_grow_takes_an_upward_dylib();
```

insert:

```c
    test_raised_uuid_is_derived();
    test_raise_replaces_the_uuid();
    test_lowering_keeps_the_uuid();
    test_raise_refuses_a_short_uuid();
    test_ensure_pad_announces_no_uuid_it_has_not();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check).
Expected: the build fails linking `grow_test`:

```
tests/grow_test.c:5138:5: warning: implicit declaration of function 'mg_raised_uuid' is invalid in C99 [-Wimplicit-function-declaration]
Undefined symbols for architecture x86_64:
  "_mg_raised_uuid", referenced from:
```

- [ ] **Step 3: Derive the UUID, and replace it**

In `src/grow.h`, replace (`:119`):

```c
 * contents raised by 0xN" for a dylib or bundle, then "; dropped
```

with:

```c
 * contents raised by 0xN" for a dylib or bundle, then "; new UUID" if it
 * has an LC_UUID (mg_raised_uuid), then "; dropped
```

In `src/grow.h`, immediately before (`:397`):

```c
/* 0 if a grow can vouch for every load command and section type of the
```

insert:

```c
/* The UUID a raise of `grow` bytes gives an image whose LC_UUID held `old`:
 * the first 16 bytes of SHA-256 over `old` and then `grow` as 8 bytes,
 * little-endian, made an RFC 4122 version 4 UUID. A raised image's addresses
 * all moved, so its old dSYM would describe it wrongly; the same input and
 * grow always give the same UUID. `out` may be `old`. */
void mg_raised_uuid(const uint8_t old[16], uint64_t grow, uint8_t out[16]);

```

In `src/grow.h`, replace (`:455`):

```c
 * rebased pointer that does. A raise deletes LC_SEGMENT_SPLIT_INFO, whose
```

with:

```c
 * rebased pointer that does. A raise replaces LC_UUID (mg_raised_uuid), and
 * deletes LC_SEGMENT_SPLIT_INFO, whose
```

In `src/grow.c`, immediately before (`:3`):

```c
#include <mach-o/nlist.h>
```

insert:

```c
#include <CommonCrypto/CommonDigest.h>
```

In `src/grow.c`, immediately after (`:96`):

```c
    int split = raise && mg_has_cmd(*pbuf, *pfsize, LC_SEGMENT_SPLIT_INFO);
```

insert:

```c
    int uuid = raise && mg_has_cmd(*pbuf, *pfsize, LC_UUID);
```

In `src/grow.c`, replace (`:125`):

```c
        fprintf(stderr, "contents raised by %#x", first - first_before);
```

with:

```c
        fprintf(stderr, "contents raised by %#x%s", first - first_before, uuid ? "; new UUID" : "");
```

In `src/grow.c`, replace (`:1539`):

```c
/* mg_grow_header's mi_each_lc callback for a raise's geometry: every segment
 * but the one that maps the header moves up `grow` in memory, and in the
 * file when its data lies past the insert; the header's segment grows by
 * `grow`; every section's address, and LC_ROUTINES_64's initializer, moves
 * up `grow`. */
static int mg_raise_cb(const struct load_command *lc_in, void *ctx_) {
    struct mg_patch_ctx *ctx = (struct mg_patch_ctx *)ctx_;
```

with:

```c
void mg_raised_uuid(const uint8_t old[16], uint64_t grow, uint8_t out[16]) {
    uint8_t in[24], digest[CC_SHA256_DIGEST_LENGTH];
    memcpy(in, old, 16);
    for (int i = 0; i < 8; i++) in[16 + i] = (uint8_t)(grow >> (8 * i));
    CC_SHA256(in, (CC_LONG)sizeof in, digest);
    memcpy(out, digest, 16);
    out[6] = (uint8_t)((out[6] & 0x0f) | 0x40);
    out[8] = (uint8_t)((out[8] & 0x3f) | 0x80);
}

/* mg_grow_header's mi_each_lc callback for a raise's geometry: every segment
 * but the one that maps the header moves up `grow` in memory, and in the
 * file when its data lies past the insert; the header's segment grows by
 * `grow`; every section's address, and LC_ROUTINES_64's initializer, moves
 * up `grow`; LC_UUID is replaced (mg_raised_uuid). */
static int mg_raise_cb(const struct load_command *lc_in, void *ctx_) {
    struct mg_patch_ctx *ctx = (struct mg_patch_ctx *)ctx_;
    if (lc_in->cmd == LC_UUID) {
        struct uuid_command *u = (struct uuid_command *)lc_in;
        mg_raised_uuid(u->uuid, ctx->grow, u->uuid);
        return 0;
    }
```

In `src/grow.c`, immediately before (`:1814`):

```c
    case LC_ROUTINES_64:
```

insert:

```c
    case LC_UUID:
        if (lc->cmdsize >= sizeof(struct uuid_command)) return 0;
        fprintf(stderr, "ERROR: LC_UUID is %u bytes, too short to hold its UUID; refusing to "
                        "grow\n", lc->cmdsize);
        return 1;
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    memcpy(in, old, 16);` | `    memcpy(in, old, 15);` | `FAIL: uuid: raised by 0x1000` |
| 2 | `    for (int i = 0; i < 8; i++) in[16 + i] = (uint8_t)(grow >> (8 * i));` | `    for (int i = 0; i < 8; i++) in[23 - i] = (uint8_t)(grow >> (8 * i));` | `FAIL: uuid: raised by 0x1000` |
| 3 | `    CC_SHA256(in, (CC_LONG)sizeof in, digest);` | `    CC_SHA256(in, 16, digest);` | `FAIL: uuid: raised by 0x1000` |
| 4 | `    out[6] = (uint8_t)((out[6] & 0x0f) \| 0x40);` | `    (void)0;` | `FAIL: uuid: raised by 0x1000` |
| 5 | `    out[8] = (uint8_t)((out[8] & 0x3f) \| 0x80);` | `    (void)0;` | `FAIL: uuid: raised by 0x1000` |
| 6 | `        mg_raised_uuid(u->uuid, ctx->grow, u->uuid);` | `        (void)u;` | `FAIL: uuid: a raise by 0x1000 replaces it` |
| 7 | `        if (lc->cmdsize >= sizeof(struct uuid_command)) return 0;` | `        return 0;` | `FAIL: a short LC_UUID: the refusal says` |
| 8 | `        if (lc->cmdsize >= sizeof(struct uuid_command)) return 0;` | `        if (lc->cmdsize > sizeof(struct uuid_command)) return 0;` | `FAIL: uuid: a raise by 0x1000 replaces it` |
| 9 | `    int uuid = raise && mg_has_cmd(*pbuf, *pfsize, LC_UUID);` | `    int uuid = raise;` | `FAIL: ensure_pad on a dylib with no UUID: says no new one` |
| 10 | `first - first_before, uuid ? "; new UUID" : "");` | `first - first_before, "");` | `FAIL: ensure_pad on a dylib: announced as` |

- [ ] **Step 6: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c
git commit -m "feat(grow): give a raised dylib a new UUID

A raise moves every address, so the image's old dSYM would describe it
wrongly, and lldb and atos would trust it for the matching UUID. The
raise replaces LC_UUID with one derived from the old one and the grow
(SHA-256, as an RFC 4122 version 4 UUID), the same for the same input,
and says so. A lowering moves no address, and keeps its UUID.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 6: Verify the raise byte for byte (checks 2 and 3)

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (`mg_snapshot_take` and `mg_snapshot_free`; `mg_verify`'s last lines; new `mg_expect_cb`, `mg_expect_off`, `mg_expect_appended_trie`, `mg_exempt`, `mg_exempt_cb` and `mg_verify_bytes` before `int mg_verify(`)
- Modify: `src/grow.h` (`mg_snapshot`'s `old` and `oldsize`; `mg_verify`'s contract)
- Test: `tests/grow_test.c` (the fixture's `DY_INITOFF`; new tests before `int main(void) {`; calls)

**Interfaces:**
- Consumes: Task 5's `mg_raised_uuid`; `ml_each_off` (`src/linkedit.h`); `mg_find_trie`, `mg_find_trie_lc`; the snapshot's `rb` and `refs`.
- Produces: `mg_snapshot.old`, `mg_snapshot.oldsize`; `static int mg_verify_bytes(const uint8_t *buf, size_t fsize, const mg_snapshot *before, uint64_t grow);`; `DY_INITOFF` in the tests.

**Plan decisions.**

- **A copy of the original.** A raise's snapshot keeps the whole image (the lowering's does not: it runs none of this). Check 3 compares the raised image with it in three parts: the header is identical; each load command is byte for byte what the raise makes of the old one; and from F on, the file is the old one G bytes further on.
- **The load commands' expectation is written apart from the patcher** (`mg_expect_cb`): Decision 2's segment, section, `LC_ROUTINES_64` and UUID rows, restated, and each `ml_each_off` offset at F or past it + G. This is check 2's load-command half (segment and section addresses, the initializer) and check 3's below F. A trie rebuilt too wide for its place is appended past `__LINKEDIT` (Task 2's path), and then the command that locates the trie, and `__LINKEDIT`'s sizes, are taken as found: check 1 resolves that command's other offsets.
- **The pad:** the bytes between the load commands and F are as they were, and the inserted G bytes are zero.
- **From F on, less exactly what the other checks watch:** the rebased slots and the pointers' values (check 2), the repaired disp32s (check 5), each symbol's `n_value` (check 2; its type, section and description are compared here), the export trie, the leading function-start ULEB, each data-in-code offset, `__unwind_info` and `S_INIT_FUNC_OFFSETS` (check 1). Everything else, code and data and the trailing function starts, must be the old bytes.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately after (`:4297`):

```c
#define DY_STABS  32     /* dy_stabs, as symbols 5 to 19 */
```

insert:

```c
#define DY_INITOFF 64    /* __TEXT,__init_offsets at 0x1120: f2 */
```

In `tests/grow_test.c`, replace (`:4358`):

```c
    int ntext = (opts & DY_UNWIND) ? 4 : 2;
```

with:

```c
    int ntext = 2 + 2 * !!(opts & DY_UNWIND) + !!(opts & DY_INITOFF);
```

In `tests/grow_test.c`, replace (`:4374`):

```c
    }

    struct segment_command_64 *da = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
```

with:

```c
    }
    if (opts & DY_INITOFF)
        s = dy_sect(s, "__TEXT", "__init_offsets", base + 0x1120, 4, 0x1120, S_INIT_FUNC_OFFSETS);

    struct segment_command_64 *da = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
```

In `tests/grow_test.c`, immediately after (`:4475`):

```c
    buf[0x1010] = 0x55; buf[0x1011] = 0xc3;
```

insert:

```c
    if (opts & DY_INITOFF) { uint32_t f2 = 0x1010; memcpy(buf + 0x1120, &f2, sizeof f2); }
```

In `tests/grow_test.c`, immediately before (`:5203`):

```c
int main(void) {
```

insert:

```c
/* ---- verification: the raise's bytes ----
 * A correct raise, then one planted change that only the byte check sees. */
static void dy_flip_code(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x2011] ^= 1; }
static void dy_realign(uint8_t *buf, size_t fsize) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) == 0) mi_find_section(&im, "__TEXT", "__stub_helper")->align = 4;
}
static void dy_move_stub_helper(uint8_t *buf, size_t fsize) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) == 0) mi_find_section(&im, "__TEXT", "__stub_helper")->addr++;
}
static void dy_reprotect(uint8_t *buf, size_t fsize) { seg_named(buf, fsize, "__DATA")->maxprot = 7; }
static void dy_misroute(uint8_t *buf, size_t fsize) {
    ((struct routines_command_64 *)find_lc(buf, fsize, LC_ROUTINES_64))->init_address++;
}
static void dy_keep_uuid(uint8_t *buf, size_t fsize) {
    struct uuid_command *u = (struct uuid_command *)find_lc(buf, fsize, LC_UUID);
    for (int i = 0; i < 16; i++) u->uuid[i] = (uint8_t)(0x10 + i);
}
static void dy_dirty_pad(uint8_t *buf, size_t fsize) { (void)fsize; buf[DY_F + 0x10] = 1; }
static void dy_dirty_old_pad(uint8_t *buf, size_t fsize) { (void)fsize; buf[DY_F - 1] = 1; }
static void dy_redesc(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[1].n_desc = 0x10; }
static void dy_relength_dic(uint8_t *buf, size_t fsize) {
    struct linkedit_data_command *dc = (struct linkedit_data_command *)find_lc(buf, fsize, LC_DATA_IN_CODE);
    buf[dc->dataoff + 4]++;
}
static void dy_restart(uint8_t *buf, size_t fsize) {
    struct linkedit_data_command *fs = (struct linkedit_data_command *)find_lc(buf, fsize, LC_FUNCTION_STARTS);
    buf[fs->dataoff + 2]++;                            /* the second start */
}
static void dy_reflag(uint8_t *buf, size_t fsize) { (void)fsize; ((struct mach_header_64 *)buf)->flags |= MH_PIE; }

static void test_verify_watches_the_raised_bytes(void) {
    check_verify_rejects_raise("a byte of code changed", dy_flip_code,
        "ERROR: verify FAILED -- file offset 0x2011 holds 0xc2 after the grow, and must hold 0xc3, "
        "as file offset 0x1011 did before it; refusing.");
    check_verify_rejects_raise("a section's alignment changed", dy_realign,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("a section's address off by one", dy_move_stub_helper,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("a segment's protection changed", dy_reprotect,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("LC_ROUTINES_64 off by one", dy_misroute,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("the UUID kept", dy_keep_uuid,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("a byte of the inserted pad set", dy_dirty_pad,
        "ERROR: verify FAILED -- header pad byte 0x1010 holds 0x1 after the grow, and must hold "
        "0; refusing.");
    check_verify_rejects_raise("a byte of the original pad set", dy_dirty_old_pad,
        "ERROR: verify FAILED -- header pad byte 0xfff holds 0x1 after the grow, and must hold 0");
    check_verify_rejects_raise("a symbol's n_desc changed", dy_redesc, "as file offset 0x30b6 did");
    check_verify_rejects_raise("data in code's length changed", dy_relength_dic,
        "as file offset 0x3094 did");
    check_verify_rejects_raise("a later function start changed", dy_restart,
        "as file offset 0x3082 did");
    check_verify_rejects_raise("the header's flags changed", dy_reflag,
        "ERROR: verify FAILED -- the grown image's header, or its size (17152 bytes), is not the "
        "original's with 4096 more; refusing.");
}

/* The raise moves a section's relocation offset with the file, and keeps
 * the pad it found, whatever it held. */
static void test_raise_moves_a_relocation_offset_and_keeps_the_pad(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    mi_image im;
    mi_wrap(buf, fsize, &im);
    mi_find_section(&im, "__DATA", "__data")->reloff = 0x3000;
    buf[DY_F - 1] = 0xaa;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    mi_wrap(buf, fsize, &im);
    CHECK(r == 0 && mi_find_section(&im, "__DATA", "__data")->reloff == 0x4000 &&
          buf[DY_F - 1] == 0xaa, "raise: a relocation offset moves, and the pad stays (got %d)", r);
    free(buf);
}

/* What the byte check leaves to the others it does not see as a change:
 * S_INIT_FUNC_OFFSETS raised, as mg_collect watches. */
static void test_raise_moves_the_initializer_offsets(void) {
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL | DY_INITOFF, 0x1000);
    if (!buf) return;
    uint32_t v;
    memcpy(&v, buf + 0x2120, sizeof v);
    CHECK(v == 0x2010, "raise: the initializer offset is %#x, want 0x2010", v);
    free(buf);
}

```

In `tests/grow_test.c`, immediately after (`:5464`):

```c
    test_ensure_pad_announces_no_uuid_it_has_not();
```

insert:

```c
    test_verify_watches_the_raised_bytes();
    test_raise_moves_the_initializer_offsets();
    test_raise_moves_a_relocation_offset_and_keeps_the_pad();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check), then `"$B/grow_test"`.
Expected: exit 1, and 12 `FAIL:` lines, one for each planted change, `verify` accepting it (`(got 0)`); the first:

```
FAIL: verify REJECTS a byte of code changed, saying 'ERROR: verify FAILED -- file offset 0x2011 holds 0xc2 after the grow, and must hold 0xc3, as file offset 0x1011 did before it; refusing.' (got 0):
```

`test_raise_moves_the_initializer_offsets` and `test_raise_moves_a_relocation_offset_and_keeps_the_pad` pass already.

- [ ] **Step 3: Keep the original, and compare**

In `src/grow.h`, immediately before (`:243`):

```c
    mhr_cand *refs;
```

insert:

```c
    uint8_t *old;        /* a raise's image as it was, for its byte check */
    size_t oldsize;
```

In `src/grow.h`, replace (`:290`):

```c
 * slots, moved. -1 (with a message naming the first failure) otherwise. */
```

with:

```c
 * slots, moved. On a raise, also: the header is the same; each load command
 * is byte for byte what the raise makes of the old one (its segment, section
 * and initializer addresses, file offsets, and UUID); the pad the old one had
 * is as it was and the inserted G bytes are zero; and from the first section
 * on, the file is the old one G bytes further on, except where a check above
 * watches: the rebased pointers, the repaired code, the symbols' values, the
 * export trie, the leading function start, data in code's offsets, compact
 * unwind and S_INIT_FUNC_OFFSETS. -1 (with a message naming the first
 * failure) otherwise. */
```

In `src/grow.c`, immediately after (`:735`):

```c
    s->kinds = NULL;
```

insert:

```c
    s->old = NULL;
    s->oldsize = 0;
```

In `src/grow.c`, replace (`:756`):

```c
        s->symaddr[i] = mg_sym_address(buf, fsize, st, &nl[i], s->raise) == 1;
    }
    return 0;
}
```

with:

```c
        s->symaddr[i] = mg_sym_address(buf, fsize, st, &nl[i], s->raise) == 1;
    }
    if (!s->raise) return 0;
    if (!(s->old = (uint8_t *)malloc(fsize + 1))) {
        mg_snapshot_free(s);
        return -1;
    }
    memcpy(s->old, buf, fsize);
    s->oldsize = fsize;
    return 0;
}
```

In `src/grow.c`, immediately after (`:774`):

```c
    free(s->symaddr); s->symaddr = NULL;
```

insert:

```c
    free(s->old); s->old = NULL; s->oldsize = 0;
```

In `src/grow.c`, immediately before (`:924`):

```c
int mg_verify(const uint8_t *buf, size_t fsize, const mg_snapshot *before) {
```

insert:

```c
/* What a raise of `grow` makes of a load command, derived from the old one
 * alone: mg_verify_bytes compares it with what the raise made. */
struct mg_expect_ctx { uint32_t first; uint32_t grow; };
static int mg_expect_cb(const struct load_command *lc_in, void *ctx_) {
    struct mg_expect_ctx *x = (struct mg_expect_ctx *)ctx_;
    if (lc_in->cmd == LC_UUID) {
        struct uuid_command *u = (struct uuid_command *)lc_in;
        mg_raised_uuid(u->uuid, x->grow, u->uuid);
    } else if (lc_in->cmd == LC_ROUTINES_64) {
        ((struct routines_command_64 *)lc_in)->init_address += x->grow;
    } else if (lc_in->cmd == LC_SEGMENT_64) {
        struct segment_command_64 *seg = (struct segment_command_64 *)lc_in;
        struct section_64 *s = (struct section_64 *)(seg + 1);
        int header = seg->fileoff == 0 && seg->filesize > 0;
        seg->vmaddr += header ? 0 : x->grow;
        seg->vmsize += header ? x->grow : 0;
        seg->filesize += header ? x->grow : 0;
        seg->fileoff += seg->fileoff >= x->first ? x->grow : 0;
        for (uint32_t j = 0; j < seg->nsects; j++) {
            s[j].addr += x->grow;
            s[j].offset += s[j].offset >= x->first ? x->grow : 0;
            s[j].reloff += s[j].reloff >= x->first ? x->grow : 0;
        }
    }
    return 0;
}
static int mg_expect_off(uint32_t *off, uint32_t cmd, int flags, void *ctx_) {
    struct mg_expect_ctx *x = (struct mg_expect_ctx *)ctx_;
    (void)cmd; (void)flags;
    *off += *off >= x->first ? x->grow : 0;
    return 0;
}

/* The command that locates the export trie, and __LINKEDIT's sizes, in `to`
 * become those of `from`: a rebuilt trie that does not fit is appended past
 * __LINKEDIT's end, and check 1 resolves the command's other offsets. Both
 * hold the same load commands. */
static void mg_expect_appended_trie(uint8_t *to, size_t tosize, const uint8_t *from,
                                    size_t fromsize) {
    mi_image ti, fi;
    long toff, foff;
    uint32_t tcmd, fcmd;
    if (mi_wrap(to, tosize, &ti) != 0 || mi_wrap((uint8_t *)from, fromsize, &fi) != 0) return;
    struct segment_command_64 *tl = mi_find_segment(&ti, "__LINKEDIT");
    struct segment_command_64 *fl = mi_find_segment(&fi, "__LINKEDIT");
    if (tl && fl) {
        tl->filesize = fl->filesize;
        tl->vmsize = fl->vmsize;
    }
    if (mg_find_trie_lc(to, tosize, &toff, &tcmd) && mg_find_trie_lc(from, fromsize, &foff, &fcmd))
        memcpy(to + toff, from + foff, ((const struct load_command *)(to + toff))->cmdsize);
}

/* Marks old[lo, lo + len) as bytes check 3 does not compare, within n. */
static void mg_exempt(uint8_t *mask, size_t n, uint64_t lo, uint64_t len) {
    for (uint64_t i = lo; i < lo + len && i < n; i++) mask[i] = 1;
}

struct mg_exempt_ctx { const uint8_t *old; size_t n; uint8_t *mask; };
static int mg_exempt_cb(const struct load_command *lc, void *ctx_) {
    struct mg_exempt_ctx *x = (struct mg_exempt_ctx *)ctx_;
    const struct linkedit_data_command *d = (const struct linkedit_data_command *)lc;
    if (lc->cmd == LC_SYMTAB) {
        const struct symtab_command *st = (const struct symtab_command *)lc;
        for (uint32_t i = 0; i < st->nsyms; i++)
            mg_exempt(x->mask, x->n, st->symoff + 16ull * i + 8, 8);        /* n_value */
    } else if (lc->cmd == LC_FUNCTION_STARTS && d->datasize && d->dataoff < x->n) {
        uint64_t v;
        uint64_t end = (uint64_t)d->dataoff + d->datasize > x->n ? x->n : d->dataoff + d->datasize;
        mg_exempt(x->mask, x->n, d->dataoff,
                  (uint64_t)mu_decode(x->old + d->dataoff, x->old + end, &v));
    } else if (lc->cmd == LC_DATA_IN_CODE) {
        for (uint32_t k = 0; k + 8 <= d->datasize; k += 8)
            mg_exempt(x->mask, x->n, (uint64_t)d->dataoff + k, 4);            /* offset */
    } else if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *s = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++)
            if ((s[j].flags & SECTION_TYPE) == S_INIT_FUNC_OFFSETS ||
                strncmp(s[j].sectname, "__unwind_info", sizeof s[j].sectname) == 0)
                mg_exempt(x->mask, x->n, s[j].offset, s[j].size);
    }
    return 0;
}

/* Check 3 of a raise (see mg_verify). */
static int mg_verify_bytes(const uint8_t *buf, size_t fsize, const mg_snapshot *before,
                           uint64_t grow) {
    const uint8_t *old = before->old;
    size_t n = before->oldsize, lcend = sizeof(struct mach_header_64) +
                                        ((const struct mach_header_64 *)old)->sizeofcmds;
    uint32_t first = before->first, toff, tsize;
    int rc = -1;
    if (fsize < n + grow || memcmp(old, buf, sizeof(struct mach_header_64)) != 0) {
        fprintf(stderr, "ERROR: verify FAILED -- the grown image's header, or its size (%zu bytes), "
                        "is not the original's with %llu more; refusing.\n", fsize,
                (unsigned long long)grow);
        return -1;
    }
    uint8_t *want = (uint8_t *)malloc(lcend), *mask = (uint8_t *)calloc(n + 1, 1);
    mi_image wim, oim;
    struct mg_expect_ctx x = { first, (uint32_t)grow };
    struct mg_exempt_ctx e = { old, n, mask };
    if (!want || !mask || mi_wrap(memcpy(want, old, lcend), lcend, &wim) != 0 ||
        mi_wrap((uint8_t *)old, n, &oim) != 0) {
        fprintf(stderr, "ERROR: verify FAILED -- could not read the image as it was; refusing.\n");
        goto out;
    }
    mi_each_lc(&wim, mg_expect_cb, &x);
    ml_each_off(&wim, mg_expect_off, &x);
    if (fsize > n + grow) mg_expect_appended_trie(want, lcend, buf, fsize);
    for (size_t i = sizeof(struct mach_header_64); i < lcend; i++) {
        if (want[i] == buf[i]) continue;
        fprintf(stderr, "ERROR: verify FAILED -- load-command byte %#zx holds %#x after the grow, "
                        "and must hold %#x; refusing.\n", i, buf[i], want[i]);
        goto out;
    }
    for (size_t i = lcend; i < first + grow; i++) {
        uint8_t w = i < first ? old[i] : 0;
        if (buf[i] == w) continue;
        fprintf(stderr, "ERROR: verify FAILED -- header pad byte %#zx holds %#x after the grow, "
                        "and must hold %#x; refusing.\n", i, buf[i], w);
        goto out;
    }
    mi_each_lc(&oim, mg_exempt_cb, &e);
    if (mg_find_trie(old, n, &toff, &tsize)) mg_exempt(mask, n, toff, tsize);
    for (size_t i = 0; i < before->rb.s.n; i++) mg_exempt(mask, n, before->rb.v[i].at, 8);
    for (uint32_t i = 0; i < before->nrefs; i++) mg_exempt(mask, n, before->refs[i].off, 4);
    for (size_t i = first; i < n; i++) {
        if (mask[i] || buf[i + grow] == old[i]) continue;
        fprintf(stderr, "ERROR: verify FAILED -- file offset %#llx holds %#x after the grow, and "
                        "must hold %#x, as file offset %#zx did before it; refusing.\n",
                (unsigned long long)(i + grow), buf[i + grow], old[i], i);
        goto out;
    }
    rc = 0;
out:
    free(want);
    free(mask);
    return rc;
}

```

In `src/grow.c`, replace (`:1114`):

```c
    return mg_verify_refs(buf, fsize, before, base, grow, delta);
```

with:

```c
    if (mg_verify_refs(buf, fsize, before, base, grow, delta) != 0) return -1;
    return before->raise ? mg_verify_bytes(buf, fsize, before, grow) : 0;
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `        mg_raised_uuid(u->uuid, x->grow, u->uuid);`<br>`    } else if (lc_in->cmd == LC_ROUTINES_64) {`<br>`        ((struct routines_command_64 *)lc_in)->init_address += x->grow;`<br>`    } else if (lc_in->cmd == LC_SEGMENT_64) {` | `        (void)u;`<br>`    } else if (lc_in->cmd == LC_ROUTINES_64) {`<br>`        ((struct routines_command_64 *)lc_in)->init_address += x->grow;`<br>`    } else if (lc_in->cmd == LC_SEGMENT_64) {` | `FAIL: raise: the grow succeeds (got -1)` |
| 2 | `        ((struct routines_command_64 *)lc_in)->init_address += x->grow;`<br>`    } else if (lc_in->cmd == LC_SEGMENT_64) {`<br>`        struct segment_command_64 *seg = (struct segment_command_64 *)lc_in;`<br>`        struct section_64 *s = (struct section_64 *)(seg + 1);`<br>`        int header` | `        (void)0;`<br>`    } else if (lc_in->cmd == LC_SEGMENT_64) {`<br>`        struct segment_command_64 *seg = (struct segment_command_64 *)lc_in;`<br>`        struct section_64 *s = (struct section_64 *)(seg + 1);`<br>`        int header` | `FAIL: raise: the grow succeeds (got -1)` |
| 3 | `        seg->vmaddr += header ? 0 : x->grow;` | `        seg->vmaddr += 0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 4 | `        seg->vmsize += header ? x->grow : 0;` | `        seg->vmsize += 0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 5 | `        seg->filesize += header ? x->grow : 0;` | `        seg->filesize += 0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 6 | `        seg->fileoff += seg->fileoff >= x->first ? x->grow : 0;` | `        seg->fileoff += x->grow;` | `FAIL: raise: the grow succeeds (got -1)` |
| 7 | `            s[j].addr += x->grow;`<br>`            s[j].offset` | `            s[j].offset` | `FAIL: raise: the grow succeeds (got -1)` |
| 8 | `            s[j].offset += s[j].offset >= x->first ? x->grow : 0;` | `            s[j].offset += x->grow;` | `FAIL: raise: the grow succeeds (got -1)` |
| 9 | `            s[j].reloff += s[j].reloff >= x->first ? x->grow : 0;` | `            (void)0;` | `FAIL: raise: a relocation offset moves, and the pad stays` |
| 10 | `    *off += *off >= x->first ? x->grow : 0;` | `    *off += x->grow;` | `FAIL: raise: the grow succeeds (got -1)` |
| 11 | `    if (fsize > n + grow) mg_expect_appended_trie(want, lcend, buf, fsize);` | `    (void)mg_expect_appended_trie;` | `FAIL: raise: the grow succeeds (got -1)` |
| 12 | `        tl->filesize = fl->filesize;` | `        (void)0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 13 | `        memcpy(to + toff, from + foff, ((const struct load_command *)(to + toff))->cmdsize);` | `        (void)0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 14 | `    if (fsize < n + grow \|\| memcmp(old, buf, sizeof(struct mach_header_64)) != 0) {` | `    if (fsize < n + grow) {` | `FAIL: verify REJECTS the header's flags changed` |
| 15 | `        if (want[i] == buf[i]) continue;` | `        continue;` | `FAIL: verify REJECTS a section's alignment changed` |
| 16 | `        uint8_t w = i < first ? old[i] : 0;` | `        uint8_t w = 0;` | `FAIL: raise: a relocation offset moves, and the pad stays` |
| 17 | `        uint8_t w = i < first ? old[i] : 0;` | `        uint8_t w = old[i];` | `FAIL: raise: the grow succeeds (got -1)` |
| 18 | `            mg_exempt(x->mask, x->n, st->symoff + 16ull * i + 8, 8);        /* n_value */` | `            (void)0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 19 | `                  (uint64_t)mu_decode(x->old + d->dataoff, x->old + end, &v));` | `                  (uint64_t)mu_decode(x->old + d->dataoff, x->old + end, &v) + 1);` | `FAIL: verify REJECTS a later function start changed` |
| 20 | `                  (uint64_t)mu_decode(x->old + d->dataoff, x->old + end, &v));` | `                  (uint64_t)0 * mu_decode(x->old + d->dataoff, x->old + end, &v));` | `FAIL: raise: the grow succeeds (got -1)` |
| 21 | `            mg_exempt(x->mask, x->n, (uint64_t)d->dataoff + k, 4);            /* offset */` | `            mg_exempt(x->mask, x->n, (uint64_t)d->dataoff + k, 6);` | `FAIL: verify REJECTS data in code's length changed` |
| 22 | `            mg_exempt(x->mask, x->n, (uint64_t)d->dataoff + k, 4);            /* offset */` | `            (void)0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 23 | `            if ((s[j].flags & SECTION_TYPE) == S_INIT_FUNC_OFFSETS \|\|`<br>`                strncmp(s[j].sectname, "__unwind_info", sizeof s[j].sectname) == 0)` | `            if (strncmp(s[j].sectname, "__unwind_info", sizeof s[j].sectname) == 0)` | `FAIL: raise: the grow succeeds (got -1)` |
| 24 | `            if ((s[j].flags & SECTION_TYPE) == S_INIT_FUNC_OFFSETS \|\|`<br>`                strncmp(s[j].sectname, "__unwind_info", sizeof s[j].sectname) == 0)` | `            if ((s[j].flags & SECTION_TYPE) == S_INIT_FUNC_OFFSETS)` | `FAIL: raise: the grow succeeds (got -1)` |
| 25 | `    if (mg_find_trie(old, n, &toff, &tsize)) mg_exempt(mask, n, toff, tsize);` | `    (void)toff; (void)tsize;` | `FAIL: raise: the grow succeeds (got -1)` |
| 26 | `    for (size_t i = 0; i < before->rb.s.n; i++) mg_exempt(mask, n, before->rb.v[i].at, 8);` | `    (void)0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 27 | `    for (uint32_t i = 0; i < before->nrefs; i++) mg_exempt(mask, n, before->refs[i].off, 4);` | `    (void)0;` | `FAIL: raise: the grow succeeds (got -1)` |
| 28 | `        if (mask[i] \|\| buf[i + grow] == old[i]) continue;` | `        if (1) continue;` | `FAIL: verify REJECTS a byte of code changed` |
| 29 | `    return before->raise ? mg_verify_bytes(buf, fsize, before, grow) : 0;` | `    return 0;` | `FAIL: verify REJECTS a byte of code changed` |
| 30 | `    memcpy(s->old, buf, fsize);` | `    memset(s->old, 0, fsize);` | `FAIL: raise: the grow succeeds (got -1)` |

- [ ] **Step 6: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c
git commit -m "feat(grow): verify a raise byte for byte against the image it came from

A raise's snapshot keeps the original, and verification compares: the
header is the same, each load command is exactly what the raise makes of
the old one (derived apart from the code that made it: segment, section
and initializer addresses, file offsets, the UUID), the pad is as it was
and the inserted bytes zero, and every byte from the first section on is
the old one a grow further on, except the fields the other checks watch.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 7: Check the raise against four oracles (check 4), and say what verification trusts

**Files** (each edit block below gives its line):
- Modify: `src/grow.c` (`mg_snapshot_take`; `mg_verify`'s last lines; new `mg_or_*`, `mg_oracles` before `/* Check 3 of a raise`)
- Modify: `src/grow.h` (the top comment: what a grow's verification trusts; `mg_snapshot`'s `oracles`; new `mg_oracles` and `MG_OR_*`; `mg_verify`'s contract)
- Test: `tests/grow_test.c` (new tests before `int main(void) {`; calls)

**Interfaces:**
- Consumes: `mg_funcstarts_decode`, `mg_find_trie`, `MT_TRIE_MAX_DEPTH`, `mu_decode`; Task 6's `mg_verify` tail.
- Produces: `unsigned mg_oracles(const uint8_t *buf, size_t fsize, unsigned want, char *why, size_t whysz);`, `MG_OR_INITS`, `MG_OR_LAZY`, `MG_OR_EXPORTS`, `MG_OR_UNWIND`, `MG_OR_ALL`; `mg_snapshot.oracles`.

**Plan decisions.**

- **The oracles are Decision 7's check 4:** every `S_MOD_INIT_FUNC_POINTERS` and `S_MOD_TERM_FUNC_POINTERS` value, and `LC_ROUTINES_64`'s initializer, is an `LC_FUNCTION_STARTS` start; every `__la_symbol_ptr` value lies in `__TEXT,__stub_helper`; every regular export, at the base plus its trie offset, is the address of the `N_SECT | N_EXT` symbol of its name; every compact-unwind personality names a slot of `__got` or `__nl_symbol_ptr`, and every LSDA lies in `__TEXT,__gcc_except_tab`. Each is read by code of its own: its own trie walk (collecting names), its own section reads and name lookup (sorted, then `bsearch`), its own parse of `__unwind_info`'s header, personalities and LSDA table. It shares with the grow only `mi_wrap`'s view of the load commands, `mg_funcstarts_decode` and `mg_find_trie`.
- **What verification trusts** (Review Focus 6), in `src/grow.h`'s top comment. Checks 1–3 and 5 derive what each field must hold from the route's rules, not from the code that moved it, but read the image through the decoders the grow reads it through: `mg_rebases_read`, `mg_collect`'s walkers, `mg_symtab` and `mhr_scan`. An entry one of those misses is neither moved nor compared, and the grow passes. What guards them is their unit tests in `tests/grow_test.c`, and for the rebase opcodes alone (`mrb_decode`), `rebase_oracle_test`'s comparison with `dyldinfo`. The oracles catch some such misses: row 20 below removes the unwind walker's visit to each LSDA, so the raise leaves every LSDA where it was: of the grow's own checks only the unwind oracle sees it (`verify FAILED -- the LSDA 0x10001180 lies outside __gcc_except_tab`), and of the tests the unwind tests; row 21 does the same to the personalities. Without this oracle, the unit tests alone would stand between such a slip and a shipped image.
- **Asked only of what held.** The snapshot records which oracles hold of the original; verification asks only those of the raised image, so an image that breaks one already is not refused for a break the raise did not make. Measured over the 1,180 system images' originals: all four hold of 1,134. The lazy-pointer oracle does not hold of 45 (libc++, libc++abi, MapKit, OpenCL's compilers and matplotlib's and scipy's extensions among them: a lazy pointer that already names a function of the image's own), and the unwind oracle not of VideoToolbox, whose LSDAs lie in a second `__gcc_except_tab`, in `__DATA`. Each is asked the others. An oracle with nothing to check (no function starts, no lazy pointers, no trie, no compact unwind) holds.
- **Why check 4 is tested through a tampered snapshot:** a change planted in the raised file, where the shared decoders read, is seen first by checks 1–3 and 5 (rows 20 and 21 show the other way in: a walker that skips an entry, which of the checks only check 4 then sees). The test moves a lazy pointer outside `__stub_helper` in the raised image and tells the snapshot it held that value before, so only check 4 sees it.

- [ ] **Step 1: Write the failing tests**

In `tests/grow_test.c`, immediately before (`:5292`):

```c
int main(void) {
```

insert:

```c
/* ---- check 4: the oracles ---- */
static void dy_poke64(uint8_t *buf, uint32_t at, uint64_t v) { memcpy(buf + at, &v, sizeof v); }

static void check_oracle(const char *what, uint8_t *buf, unsigned want, const char *why) {
    char got[256] = "";
    unsigned holds = mg_oracles(buf, DY_FSIZE, MG_OR_ALL, got, sizeof got);
    CHECK(holds == want && (!why || strcmp(got, why) == 0),
          "oracles: %s: %#x hold, want %#x; said '%s', want '%s'", what, holds, want, got,
          why ? why : "");
    free(buf);
}

static void test_oracles_judge_the_fixture(void) {
    size_t fsize;
    uint8_t *buf;
    check_oracle("the fixture", build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL | DY_INITOFF),
                 MG_OR_ALL, NULL);
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2030, 0x1011);
    check_oracle("an initializer mid-function", buf, MG_OR_ALL & ~MG_OR_INITS,
                 "the initializer 0x1011 is not a function start");
    buf = build_dylib(&fsize, DY_ROUTINES);
    ((struct routines_command_64 *)dy_find(buf, LC_ROUTINES_64))->init_address = 0x1012;
    check_oracle("LC_ROUTINES_64 mid-function", buf, MG_OR_ALL & ~MG_OR_INITS,
                 "the initializer 0x1012 is not a function start");
    buf = build_dylib(&fsize, 0);
    dy_section(buf, "__DATA", "__mod_init_func")->flags = S_MOD_TERM_FUNC_POINTERS;
    dy_poke64(buf, 0x2030, 0x1013);
    check_oracle("a terminator mid-function", buf, MG_OR_ALL & ~MG_OR_INITS,
                 "the initializer 0x1013 is not a function start");
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2030, 0x1011);
    ((struct linkedit_data_command *)dy_find(buf, LC_FUNCTION_STARTS))->datasize = 0;
    check_oracle("an initializer, and no function starts", buf, MG_OR_ALL, NULL);
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2038, 0x1110);
    check_oracle("a lazy pointer at __stub_helper's end", buf, MG_OR_ALL & ~MG_OR_LAZY,
                 "the lazy pointer 0x1110 lies outside __stub_helper");
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2038, 0x10ff);
    check_oracle("a lazy pointer before __stub_helper", buf, MG_OR_ALL & ~MG_OR_LAZY,
                 "the lazy pointer 0x10ff lies outside __stub_helper");
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2038, 0x110f);
    check_oracle("a lazy pointer at __stub_helper's last byte", buf, MG_OR_ALL, NULL);
    buf = build_dylib(&fsize, 0);
    buf[0x3040 + 18] = 0x81;                           /* _f1: 0x1001 */
    check_oracle("an export off by one", buf, MG_OR_ALL & ~MG_OR_EXPORTS,
                 "the export _f1 names 0x1001, and its symbol 0x1000");
    buf = build_dylib(&fsize, 0);
    buf[0x3040 + 18] = 0x81;
    dy_syms(buf, DY_FSIZE)[1].n_type = N_SECT;         /* _f1 is not external */
    check_oracle("an export with no external symbol", buf, MG_OR_ALL, NULL);

    /* Compact unwind (DY_UNWIND): its personality at word 7, f2's LSDA at 15. */
    static const struct { const char *what; int word; uint32_t v; const char *why; } uw[6] = {
        { "an LSDA outside __gcc_except_tab", 15, 0x1010,
          "the LSDA 0x1010 lies outside __gcc_except_tab" },
        { "an LSDA at __gcc_except_tab's end", 15, 0x1190,
          "the LSDA 0x1190 lies outside __gcc_except_tab" },
        { "an LSDA at __gcc_except_tab's last byte", 15, 0x118f, NULL },
        { "a personality in __data", 7, 0x2000,
          "the personality 0x2000 names no __got or __nl_symbol_ptr slot" },
        { "a personality mid-slot", 7, 0x2044,
          "the personality 0x2044 names no __got or __nl_symbol_ptr slot" },
        { "compact unwind of a version it does not read", 0, 2, "__unwind_info could not be read" },
    };
    for (int i = 0; i < 6; i++) {
        buf = build_dylib(&fsize, DY_UNWIND);
        ((uint32_t *)(buf + 0x1800))[uw[i].word] = uw[i].v;
        check_oracle(uw[i].what, buf, uw[i].why ? MG_OR_ALL & ~MG_OR_UNWIND : MG_OR_ALL,
                     uw[i].why);
    }

    /* Two fail; `why` is the first of those asked about. */
    char why[256] = "";
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2030, 0x1011);
    dy_poke64(buf, 0x2038, 0x1110);
    unsigned holds = mg_oracles(buf, fsize, MG_OR_LAZY | MG_OR_EXPORTS, why, sizeof why);
    CHECK(holds == (MG_OR_EXPORTS | MG_OR_UNWIND) &&
          strcmp(why, "the lazy pointer 0x1110 lies outside __stub_helper") == 0,
          "oracles: asked about the lazy pointers alone, says why they fail (%#x, '%s')", holds, why);
    free(buf);
}

/* A lazy pointer moved outside __stub_helper, and the snapshot told it
 * moved there too: only check 4 sees it. And what did not hold before is
 * not asked after. */
static void test_verify_watches_the_oracles(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) { CHECK(0, "oracles: snapshot"); free(buf); return; }
    CHECK(snap.oracles == MG_OR_ALL, "oracles: the snapshot says all hold (%#x)", snap.oracles);
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "oracles: grow"); mg_snapshot_free(&snap); free(buf); return;
    }
    dy_poke64(buf, 0x3038, DY_RAISED_AT + 0x3000);
    snap.rb.v[4].value = DY_RAISED_AT + 0x2000;
    int r;
    verify_snap = &snap;
    char *err = stderr_during(verify_thunk, &buf, &fsize, 0, &r);
    CHECK(r == -1 && strstr(err, "ERROR: verify FAILED -- the lazy pointer 0x10003000 lies outside "
                                 "__stub_helper after the grow, which held before it; refusing.\n"),
          "oracles: verify REJECTS a lazy pointer outside __stub_helper (got %d):\n%s", r, err);
    free(err);
    mg_snapshot_free(&snap);
    free(buf);

    buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    dy_poke64(buf, 0x2038, DY_RAISED_AT + 0x2000);
    r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "oracles: a raise of an image one did not hold of succeeds (got %d)", r);
    free(buf);
}

```

In `tests/grow_test.c`, immediately after (`:5584`):

```c
    test_raise_moves_a_relocation_offset_and_keeps_the_pad();
```

insert:

```c
    test_oracles_judge_the_fixture();
    test_verify_watches_the_oracles();
```

- [ ] **Step 2: Run them to see them fail**

Run: build (rebuild check).
Expected: the build fails compiling `grow_test.c`: 19 `use of undeclared identifier` errors, for `MG_OR_ALL` (12), `MG_OR_INITS` (3), `MG_OR_LAZY` (2), `MG_OR_EXPORTS` (1) and `MG_OR_UNWIND` (1), then `fatal error: too many errors emitted, stopping now [-ferror-limit=]`.

- [ ] **Step 3: The oracles**

In `src/grow.h`, immediately after (`:36`):

```c
 * that names it: each rebased pointer, symbol, section and segment.
```

insert:

```c
 *
 * What a grow's verification trusts. mg_verify derives what each field must
 * hold from the route's rules, not from the code that moved it, but it reads
 * the image through the decoders the grow itself reads it through:
 * mg_rebases_read for the rebased pointers (checks 2 and 3), mg_collect's
 * walkers of the export trie, compact unwind, data in code, function starts
 * and initializer offsets (check 1), mg_symtab (check 2) and mhr_scan (check
 * 5). An entry one of those misses is missed by the grow and its check
 * alike, and the grow passes: a rebase the reader drops is neither moved nor
 * compared. What guards those decoders is their tests in tests/grow_test.c
 * and, for the rebase opcodes alone (mrb_decode, under mg_rebases_read),
 * tests/rebase_oracle_test.sh's comparison with dyldinfo over 10.9's
 * /usr/lib. mg_oracles (check 4) and mg_plausible read what they check with
 * code of their own, and catch some such misses: an initializer, a lazy
 * pointer, an export or an LSDA left where it was.
```

In `src/grow.h`, immediately after (`:259`):

```c
    size_t oldsize;
```

insert:

```c
    unsigned oracles;    /* the mg_oracles that held of it */
```

In `src/grow.h`, immediately before (`:297`):

```c
/* The grow G is how far the first section moved; a raise moves every
```

insert:

```c
/* Four things true of an image ld64 linked, whatever a grow moved (spec:
 * check 4): every S_MOD_INIT_FUNC_POINTERS and S_MOD_TERM_FUNC_POINTERS
 * value, and LC_ROUTINES_64's initializer, is an LC_FUNCTION_STARTS start
 * (vacuous with no starts); every __la_symbol_ptr value lies in
 * __TEXT,__stub_helper; every regular export, at the base plus its trie
 * offset, is the address of the N_SECT | N_EXT symbol of its name, where
 * there is one; and every personality compact unwind names is a slot of a
 * non-lazy pointer section (__got, __nl_symbol_ptr), and every LSDA lies in
 * __TEXT,__gcc_except_tab. Each reads what it checks itself: the sections'
 * values, the export trie's names, __unwind_info. It shares with the grow
 * only mi_wrap's view of the load commands, mg_funcstarts_decode and
 * mg_find_trie, and none of the walkers that move what it reads. Returns the
 * MG_OR_ bits of those that hold, and sets `why` for the first that does not
 * among `want`. */
#define MG_OR_INITS   1u
#define MG_OR_LAZY    2u
#define MG_OR_EXPORTS 4u
#define MG_OR_UNWIND  8u
#define MG_OR_ALL     15u
unsigned mg_oracles(const uint8_t *buf, size_t fsize, unsigned want, char *why, size_t whysz);

```

In `src/grow.h`, replace (`:334`):

```c
 * unwind and S_INIT_FUNC_OFFSETS. -1 (with a message naming the first
 * failure) otherwise. */
```

with:

```c
 * unwind and S_INIT_FUNC_OFFSETS; and each mg_oracles that held of the image
 * before holds after. -1 (with a message naming the first failure)
 * otherwise. */
```

In `src/grow.c`, immediately after (`:737`):

```c
    s->oldsize = 0;
```

insert:

```c
    s->oracles = 0;
```

In `src/grow.c`, immediately after (`:765`):

```c
    s->oldsize = fsize;
```

insert:

```c
    s->oracles = mg_oracles(buf, fsize, 0, why, sizeof why);
```

In `src/grow.c`, immediately before (`:1011`):

```c
/* Check 3 of a raise (see mg_verify). */
```

insert:

```c
/* ---- mg_oracles ---- */
struct mg_or_lcs {
    const struct linkedit_data_command *fs;
    const struct symtab_command *st;
    const struct routines_command_64 *rt;
    const struct section_64 *helper, *unwind, *except, *nl[8];
    int nlazy, nnl;
};
static int mg_or_lcs_cb(const struct load_command *lc, void *ctx_) {
    struct mg_or_lcs *c = (struct mg_or_lcs *)ctx_;
    if (lc->cmd == LC_FUNCTION_STARTS && !c->fs) c->fs = (const struct linkedit_data_command *)lc;
    if (lc->cmd == LC_SYMTAB && !c->st) c->st = (const struct symtab_command *)lc;
    if (lc->cmd == LC_ROUTINES_64 && !c->rt) c->rt = (const struct routines_command_64 *)lc;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(seg + 1);
    for (uint32_t j = 0; j < seg->nsects; j++) {
        if (!strncmp(s[j].segname, "__TEXT", 16) && !strncmp(s[j].sectname, "__stub_helper", 16))
            c->helper = &s[j];
        if (!strncmp(s[j].segname, "__TEXT", 16) && !strncmp(s[j].sectname, "__gcc_except_tab", 16))
            c->except = &s[j];
        if (!c->unwind && !strncmp(s[j].sectname, "__unwind_info", 16)) c->unwind = &s[j];
        if ((s[j].flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS) c->nlazy++;
        if ((s[j].flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS && c->nnl < 8)
            c->nl[c->nnl++] = &s[j];
    }
    return 0;
}

static int mg_by_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

/* Each 8-byte value of every section of `type`, in turn, to `fn`; stops at the
 * first it returns nonzero for, and returns that. */
struct mg_or_vals { const uint8_t *buf; size_t fsize; uint32_t type; int (*fn)(uint64_t, void *);
                    void *ctx; int r; };
static int mg_or_vals_cb(const struct load_command *lc, void *ctx_) {
    struct mg_or_vals *v = (struct mg_or_vals *)ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(seg + 1);
    for (uint32_t j = 0; j < seg->nsects && !v->r; j++) {
        if ((s[j].flags & SECTION_TYPE) != v->type || !s[j].offset) continue;
        for (uint64_t k = 0; k + 8 <= s[j].size && s[j].offset + k + 8 <= v->fsize && !v->r; k += 8) {
            uint64_t x;
            memcpy(&x, v->buf + s[j].offset + k, sizeof x);
            v->r = v->fn(x, v->ctx);
        }
    }
    return v->r;
}

struct mg_or_starts { const uint64_t *a; size_t n; uint64_t bad; };
static int mg_or_not_start(uint64_t x, void *ctx_) {
    struct mg_or_starts *s = (struct mg_or_starts *)ctx_;
    if (bsearch(&x, s->a, s->n, sizeof *s->a, mg_by_u64)) return 0;
    s->bad = x;
    return 1;
}
struct mg_or_range { uint64_t lo, hi, bad; };
static int mg_or_outside(uint64_t x, void *ctx_) {
    struct mg_or_range *r = (struct mg_or_range *)ctx_;
    if (x >= r->lo && x < r->hi) return 0;
    r->bad = x;
    return 1;
}

/* A regular export: its name, and its offset from the base. */
typedef struct { char *name; uint64_t off; } mg_or_exp;
struct mg_or_trie { const uint8_t *t; uint32_t size; uint8_t *seen; char name[1024];
                    mg_or_exp *e; size_t n, cap; int bad; };
static void mg_or_trie_walk(struct mg_or_trie *w, uint32_t off, size_t len, int depth) {
    const uint8_t *p, *end = w->t + w->size;
    uint64_t term, flags, a, coff;
    int k;
    if (w->bad || depth > MT_TRIE_MAX_DEPTH || off >= w->size || w->seen[off]) { w->bad = 1; return; }
    w->seen[off] = 1;
    p = w->t + off;
    if (!(k = mu_decode(p, end, &term))) { w->bad = 1; return; }
    p += k;
    if (term) {
        const uint8_t *q = p;
        if (!(k = mu_decode(q, end, &flags))) { w->bad = 1; return; }
        q += k;
        if (!(flags & (MG_EXPORT_REEXPORT | MG_EXPORT_STUB_AND_RESOLVER | MG_EXPORT_KIND_MASK))) {
            if (!(k = mu_decode(q, end, &a))) { w->bad = 1; return; }
            if (w->n == w->cap) {
                mg_or_exp *e = (mg_or_exp *)realloc(w->e, (w->cap * 2 + 16) * sizeof *e);
                if (!e) { w->bad = 1; return; }
                w->e = e;
                w->cap = w->cap * 2 + 16;
            }
            if (!(w->e[w->n].name = (char *)malloc(len + 1))) { w->bad = 1; return; }
            memcpy(w->e[w->n].name, w->name, len);
            w->e[w->n].name[len] = 0;
            w->e[w->n++].off = a;
        }
        if (term > (uint64_t)(end - p)) { w->bad = 1; return; }
        p += term;
    }
    if (p >= end) { w->bad = 1; return; }
    for (uint8_t i = 0, nch = *p++; i < nch && !w->bad; i++) {
        size_t l = 0;
        while (p + l < end && p[l]) l++;
        if (p + l >= end || len + l >= sizeof w->name) { w->bad = 1; return; }
        memcpy(w->name + len, p, l);
        p += l + 1;
        if (!(k = mu_decode(p, end, &coff))) { w->bad = 1; return; }
        p += k;
        mg_or_trie_walk(w, (uint32_t)(coff > UINT32_MAX ? UINT32_MAX : coff), len + l, depth + 1);
    }
}
static int mg_or_by_name(const void *a, const void *b) {
    return strcmp(((const mg_or_exp *)a)->name, ((const mg_or_exp *)b)->name);
}

/* 0 when every regular export whose name an N_SECT | N_EXT symbol has names
 * that symbol's address; else 1, with `why` set; -1 when it cannot tell. */
static int mg_or_exports(const uint8_t *buf, size_t fsize, uint64_t base,
                         const struct symtab_command *st, char *why, size_t whysz) {
    uint32_t off, size;
    struct mg_or_trie w;
    int r = 0;
    if (!mg_find_trie(buf, fsize, &off, &size) || !off || !size || !st) return 0;
    if ((uint64_t)off + size > fsize || (uint64_t)st->symoff + 16ull * st->nsyms > fsize ||
        (uint64_t)st->stroff + st->strsize > fsize)
        return -1;
    memset(&w, 0, sizeof w);
    w.t = buf + off;
    w.size = size;
    if (!(w.seen = (uint8_t *)calloc(size, 1))) return -1;
    mg_or_trie_walk(&w, 0, 0, 0);
    if (w.bad) r = -1;
    else qsort(w.e, w.n, sizeof *w.e, mg_or_by_name);
    const struct nlist_64 *nl = (const struct nlist_64 *)(buf + st->symoff);
    for (uint32_t i = 0; r == 0 && i < st->nsyms; i++) {
        if ((nl[i].n_type & (N_STAB | N_TYPE | N_EXT)) != (N_SECT | N_EXT) ||
            nl[i].n_un.n_strx >= st->strsize)
            continue;
        const char *nm = (const char *)buf + st->stroff + nl[i].n_un.n_strx;
        if (!memchr(nm, 0, st->strsize - nl[i].n_un.n_strx)) continue;
        mg_or_exp key = { (char *)nm, 0 };
        const mg_or_exp *e = (const mg_or_exp *)bsearch(&key, w.e, w.n, sizeof *w.e, mg_or_by_name);
        if (!e || base + e->off == nl[i].n_value) continue;
        snprintf(why, whysz, "the export %s names %#llx, and its symbol %#llx", nm,
                 (unsigned long long)(base + e->off), (unsigned long long)nl[i].n_value);
        r = 1;
    }
    for (size_t i = 0; i < w.n; i++) free(w.e[i].name);
    free(w.e);
    free(w.seen);
    return r;
}

/* Whether `a` is an 8-byte slot of a non-lazy pointer section. */
static int mg_or_in_nl(const struct mg_or_lcs *c, uint64_t a) {
    for (int k = 0; k < c->nnl; k++)
        if (a >= c->nl[k]->addr && a - c->nl[k]->addr < c->nl[k]->size &&
            (a - c->nl[k]->addr) % 8 == 0)
            return 1;
    return 0;
}

/* 0 when every personality compact unwind names is a slot of __got or
 * __nl_symbol_ptr, and every LSDA it names lies in __TEXT,__gcc_except_tab;
 * else 1, with `why` set; -1 when __unwind_info cannot be read. Read here,
 * not through mg_unwind_walk. */
static int mg_or_unwind(const uint8_t *buf, size_t fsize, uint64_t base,
                        const struct mg_or_lcs *c, char *why, size_t whysz) {
    const struct section_64 *u = c->unwind;
    uint32_t h[7], lo, hi;
    if (!u || !u->size) return 0;
    if (u->offset > fsize || u->size > fsize - u->offset || u->size < sizeof h) return -1;
    const uint8_t *p = buf + u->offset;
    memcpy(h, p, sizeof h);
    if (h[0] != 1 || (uint64_t)h[3] + 4ull * h[4] > u->size || h[6] < 1 ||
        (uint64_t)h[5] + 12ull * h[6] > u->size)
        return -1;
    for (uint32_t k = 0; k < h[4]; k++) {
        uint32_t pe;
        memcpy(&pe, p + h[3] + 4 * k, sizeof pe);
        if (mg_or_in_nl(c, base + pe)) continue;
        snprintf(why, whysz, "the personality %#llx names no __got or __nl_symbol_ptr slot",
                 (unsigned long long)(base + pe));
        return 1;
    }
    memcpy(&lo, p + h[5] + 8, sizeof lo);
    memcpy(&hi, p + h[5] + 12ull * (h[6] - 1) + 8, sizeof hi);
    if (hi < lo || hi > u->size) return -1;
    for (uint32_t e = lo; e + 8 <= hi; e += 8) {
        uint32_t lsda;
        memcpy(&lsda, p + e + 4, sizeof lsda);
        uint64_t a = base + lsda;
        if (c->except && a >= c->except->addr && a - c->except->addr < c->except->size) continue;
        snprintf(why, whysz, "the LSDA %#llx lies outside __gcc_except_tab", (unsigned long long)a);
        return 1;
    }
    return 0;
}

unsigned mg_oracles(const uint8_t *buf, size_t fsize, unsigned want, char *why, size_t whysz) {
    mi_image im;
    struct mg_or_lcs c;
    uint64_t base;
    unsigned holds = 0;
    char w[4][256] = { "LC_FUNCTION_STARTS could not be read", "",
                       "the export trie or the symbols could not be read",
                       "__unwind_info could not be read" };
    memset(&c, 0, sizeof c);
    snprintf(why, whysz, "the image could not be read");
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0 || mi_image_base(&im, &base) != 0) return 0;
    mi_each_lc(&im, mg_or_lcs_cb, &c);

    uint32_t nfs = c.fs && c.fs->datasize <= fsize && c.fs->dataoff <= fsize - c.fs->datasize
                   ? c.fs->datasize : 0;
    struct mg_or_starts s = { NULL, 0, 0 };
    uint64_t *a = (uint64_t *)malloc(nfs * sizeof *a + 1);
    int ns = a ? mg_funcstarts_decode(buf + (nfs ? c.fs->dataoff : 0), nfs, base, a, (int)nfs) : -1;
    s.a = a;
    s.n = ns > 0 ? (size_t)ns : 0;
    qsort(a, s.n, sizeof *a, mg_by_u64);
    struct mg_or_vals v = { buf, fsize, S_MOD_INIT_FUNC_POINTERS, mg_or_not_start, &s, 0 };
    if (ns == 0) {
        holds |= MG_OR_INITS;
    } else if (ns > 0) {
        mi_each_lc(&im, mg_or_vals_cb, &v);
        v.type = S_MOD_TERM_FUNC_POINTERS;
        if (!v.r) mi_each_lc(&im, mg_or_vals_cb, &v);
        if (!v.r && c.rt) v.r = mg_or_not_start(c.rt->init_address, &s);
        if (!v.r) holds |= MG_OR_INITS;
        else snprintf(w[0], sizeof w[0], "the initializer %#llx is not a function start",
                      (unsigned long long)s.bad);
    }
    free(a);

    struct mg_or_range r = { c.helper ? c.helper->addr : 0,
                             c.helper ? c.helper->addr + c.helper->size : 0, 0 };
    struct mg_or_vals l = { buf, fsize, S_LAZY_SYMBOL_POINTERS, mg_or_outside, &r, 0 };
    if (c.nlazy) mi_each_lc(&im, mg_or_vals_cb, &l);
    if (!l.r) holds |= MG_OR_LAZY;
    else snprintf(w[1], sizeof w[1], "the lazy pointer %#llx lies outside __stub_helper",
                  (unsigned long long)r.bad);

    if (mg_or_exports(buf, fsize, base, c.st, w[2], sizeof w[2]) == 0) holds |= MG_OR_EXPORTS;
    if (mg_or_unwind(buf, fsize, base, &c, w[3], sizeof w[3]) == 0) holds |= MG_OR_UNWIND;
    for (int i = 0; i < 4; i++)
        if (want & ~holds & (1u << i)) {
            snprintf(why, whysz, "%s", w[i]);
            break;
        }
    return holds;
}

```

In `src/grow.c`, replace (`:1372`):

```c
    return before->raise ? mg_verify_bytes(buf, fsize, before, grow) : 0;
```

with:

```c
    if (!before->raise) return 0;
    if (mg_verify_bytes(buf, fsize, before, grow) != 0) return -1;
    char why[256];
    if ((mg_oracles(buf, fsize, before->oracles, why, sizeof why) & before->oracles) ==
        before->oracles)
        return 0;
    fprintf(stderr, "ERROR: verify FAILED -- %s after the grow, which held before it; "
                    "refusing.\n", why);
    return -1;
```

- [ ] **Step 4: Run them to see them pass**

Run: build (rebuild check), then `"$B/grow_test"`, then the suite.
Expected: `macho_grow_test: all cases pass`; green.

- [ ] **Step 5: Mutation proof** (file `src/grow.c`; test binary `$B/grow_test`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    if (ns == 0) {`<br>`        holds \|= MG_OR_INITS;` | `    if (ns == 0) {`<br>`        (void)0;` | `FAIL: oracles: an initializer, and no function starts` |
| 2 | `        mi_each_lc(&im, mg_or_vals_cb, &v);`<br>`        v.type = S_MOD_TERM_FUNC_POINTERS;` | `        v.type = S_MOD_TERM_FUNC_POINTERS;` | `FAIL: oracles: an initializer mid-function` |
| 3 | `        if (!v.r) mi_each_lc(&im, mg_or_vals_cb, &v);`<br>`        if (!v.r && c.rt)` | `        if (!v.r && c.rt)` | `FAIL: oracles: a terminator mid-function` |
| 4 | `        if (!v.r && c.rt) v.r = mg_or_not_start(c.rt->init_address, &s);` | `        (void)0;` | `FAIL: oracles: LC_ROUTINES_64 mid-function` |
| 5 | `    if (bsearch(&x, s->a, s->n, sizeof *s->a, mg_by_u64)) return 0;` | `    if (1) return 0;` | `FAIL: oracles: an initializer mid-function` |
| 6 | `    if (c.nlazy) mi_each_lc(&im, mg_or_vals_cb, &l);` | `    (void)l;` | `FAIL: oracles: a lazy pointer at __stub_helper's end` |
| 7 | `    if (x >= r->lo && x < r->hi) return 0;` | `    if (x >= r->lo && x <= r->hi) return 0;` | `FAIL: oracles: a lazy pointer at __stub_helper's end` |
| 8 | `    if (x >= r->lo && x < r->hi) return 0;` | `    if (x > r->lo && x < r->hi) return 0;` | `FAIL: oracles: the fixture` |
| 9 | `        if (!strncmp(s[j].segname, "__TEXT", 16) && !strncmp(s[j].sectname, "__stub_helper", 16))` | `        if (0)` | `FAIL: oracles: the fixture` |
| 10 | `        if ((nl[i].n_type & (N_STAB \| N_TYPE \| N_EXT)) != (N_SECT \| N_EXT) \|\|` | `        if ((nl[i].n_type & (N_STAB \| N_TYPE)) != N_SECT \|\|` | `FAIL: oracles: an export with no external symbol` |
| 11 | `        if (!e \|\| base + e->off == nl[i].n_value) continue;` | `        if (!e) continue;` | `FAIL: oracles: the fixture` |
| 12 | `        if (!e \|\| base + e->off == nl[i].n_value) continue;` | `        if (!e \|\| e->off == nl[i].n_value) continue;` | `FAIL: oracles: the fixture` |
| 13 | `        if (!(flags & (MG_EXPORT_REEXPORT \| MG_EXPORT_STUB_AND_RESOLVER \| MG_EXPORT_KIND_MASK))) {` | `        if (!(flags & (MG_EXPORT_REEXPORT \| MG_EXPORT_STUB_AND_RESOLVER))) {` | `FAIL: raise: an absolute export stays 0x2020` |
| 14 | `            memcpy(w->e[w->n].name, w->name, len);` | `            memcpy(w->e[w->n].name, w->name, len ? len - 1 : 0);` | `FAIL: oracles: an export off by one` |
| 15 | `    if ((mg_oracles(buf, fsize, before->oracles, why, sizeof why) & before->oracles) ==`<br>`        before->oracles)`<br>`        return 0;` | `    return 0;` | `FAIL: oracles: verify REJECTS a lazy pointer outside __stub_helper` |
| 16 | `    s->oracles = mg_oracles(buf, fsize, 0, why, sizeof why);` | `    s->oracles = MG_OR_ALL;` | `FAIL: oracles: a raise of an image one did not hold of succeeds` |
| 17 | `    s->oracles = mg_oracles(buf, fsize, 0, why, sizeof why);` | `    s->oracles = 0;` | `FAIL: oracles: the snapshot says all hold` |
| 18 | `        if (want & ~holds & (1u << i)) {` | `        if (~holds & (1u << i)) {` | `FAIL: oracles: asked about the lazy pointers alone, says why they fail` |
| 19 | `        if (want & ~holds & (1u << i)) {` | `        if (want & (1u << i)) {` | `FAIL: oracles: a lazy pointer at __stub_helper's end: 0xd hold, want 0xd; said 'LC_FUNCTION_STARTS could not be read'` |
| 20 | `            UW_VISIT(e + 4, MG_K_ANY);     /* lsdaOffset -> __gcc_except_tab */` | *(delete it)* | `verify FAILED -- the LSDA 0x10001180 lies outside __gcc_except_tab` |
| 21 | `        for (uint32_t k = 0; k < peCnt; k++) UW_VISIT(peOff + 4 * k, MG_K_ANY); /* GOT slot */` | *(delete it)* | `verify FAILED -- the personality` |
| 22 | `    if (mg_or_unwind(buf, fsize, base, &c, w[3], sizeof w[3]) == 0) holds \|= MG_OR_UNWIND;` | `    (void)mg_or_unwind;` | `FAIL: oracles: the fixture` |
| 23 | `        if (mg_or_in_nl(c, base + pe)) continue;` | `        if (1) continue;` | `FAIL: oracles: a personality in __data` |
| 24 | `            (a - c->nl[k]->addr) % 8 == 0)` | `            1)` | `FAIL: oracles: a personality mid-slot` |
| 25 | `        if ((s[j].flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS && c->nnl < 8)` | `        if (0)` | `FAIL: oracles: the fixture` |
| 26 | `        if (!strncmp(s[j].segname, "__TEXT", 16) && !strncmp(s[j].sectname, "__gcc_except_tab", 16))` | `        if (0)` | `FAIL: oracles: the fixture` |
| 27 | `        if (c->except && a >= c->except->addr && a - c->except->addr < c->except->size) continue;` | `        if (1) continue;` | `FAIL: oracles: an LSDA outside __gcc_except_tab` |
| 28 | `        if (c->except && a >= c->except->addr && a - c->except->addr < c->except->size) continue;` | `        if (c->except && a >= c->except->addr && a - c->except->addr <= c->except->size) continue;` | `FAIL: oracles: an LSDA at __gcc_except_tab's end` |
| 29 | `    if (h[0] != 1 \|\| (uint64_t)h[3]` | `    if ((uint64_t)h[3]` | `FAIL: oracles: compact unwind of a version it does not read` |

- [ ] **Step 6: Commit**

```bash
git add src/grow.c src/grow.h tests/grow_test.c
git commit -m "feat(grow): check a raise against four oracles read by code of their own

Initializers name function starts, lazy pointers lie in __stub_helper,
each regular export names its symbol's address, and compact unwind's
personalities name __got slots and its LSDAs lie in __gcc_except_tab:
true of what ld64 links, whatever a grow moved, and read here by code of
their own. A raise must keep each that held of the image it came from.
The other checks read the image through the grow's own decoders, and
src/grow.h now says so, and what guards them.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 8: The raise end to end, and `src/relations.h`

**Files** (each edit block below gives its line):
- Modify: `src/relations.h` (the table)
- Test: `tests/cli_test.sh` (the MR_ERROR block's two comments that said a dylib cannot grow; a new block before `reached_end=1`)

**Interfaces:**
- Consumes: everything above, through `drydock-macho-rewrite`; in `cli_test.sh`, `$CC`, `$FIXTURE_FLAGS`, `$T`, `ok`, `bad`.
- Produces: nothing code depends on.

**Plan decisions.**

- **Spec Testing table's row:** `dylib append`, `dylib insert` and `rpath replace` on a dylib whose pad is too short: success, announced, `verify` passes. The fixture is compiled here, as `cli_test`'s others are, with `$FIXTURE_FLAGS` (x86_64, 10.9); the path is 100 bytes longer than its measured pad. A program linked against it runs the dylib the `rpath replace` raised, and `DYLD_PRINT_LIBRARIES` shows that copy loaded (the positive control). Its rpath is `@loader_path/.`: 10.9's dyld expands `@loader_path` only with a slash after it.
- **Signing** (the review's). A dylib its linker signed carries a signature the raise invalidates, so each script deletes `LC_CODE_SIGNATURE` first when `info` lists one, as Task 9's sweeps do; 10.9's ld64 does not sign, so here nothing is deleted. On a host that kills whatever was modified since it was signed (`$signing_enforced`, which `cli_test` establishes apart from this tool), the program's run and its `DYLD_PRINT_LIBRARIES` check are skipped, with one SKIP saying why: the raised dylib would be killed there for being unsigned, not for the raise.
- **No relation bit** (spec Decision 8): a raise always moves the first section, so `src/edit.c`'s `me_note_disturbed` already sets `MREL_BASE_REL` and `MREL_FILE_OFF`, and every later statement reads the raised image afresh. A later `rpath append` into the grown pad is the test; `src/relations.h` gets the row and says why there is no bit.
- **`cli_test`'s MR_ERROR block** said a dylib cannot grow; its refused dylib (`mkimplausible`'s) is refused for its chained fixups, and the comment now says so. Its assertions do not change.
- **No "see it fail":** Tasks 2–7 made this behaviour; these are its end-to-end tests, and pass on arrival. Rows 1 and 2 are their proof that they can fail.

- [ ] **Step 1: The end-to-end tests**

In `tests/cli_test.sh`, replace (`:3020`):

```sh
# mkimplausible builds an MH_DYLIB, which mg_grow_header refuses to grow at
# all (it has no __PAGEZERO to lower the base into).
```

with:

```sh
# mkimplausible builds an MH_DYLIB with LC_DYLD_CHAINED_FIXUPS, which
# mg_grow_header refuses to raise until they are converted.
```

In `tests/cli_test.sh`, replace (`:3065`):

```sh
# it with MH_PIE cleared cannot grow, and its pad is the same.
```

with:

```sh
# it with MH_PIE cleared cannot grow if it is the executable, and the dylib's
# chained fixups refuse its raise; its pad is the same.
```

In `tests/cli_test.sh`, immediately before (`:5364`):

```sh
reached_end=1
```

insert:

```sh
# ============================================================================
# a dylib's header pad grows by raising its contents
# ============================================================================
# A dylib has no __PAGEZERO to lower its base into, so what follows its load
# commands moves up instead (src/grow.h). Each statement asks for more pad
# than the fixture has; each grows it, says so, and verifies. The driver
# finds the raised dylib through its own rpath, and runs. (That rpath is
# @loader_path/., not @loader_path: 10.9's dyld expands only the form with a
# slash.) A linker that signs the dylib leaves a signature the raise
# invalidates, so each script deletes it first, as the sweeps do; and a host
# that kills whatever was modified since it was signed skips the run.
cat > "$T/raise.c" <<'EOF'
int raise_fn(void) { return 7; }
EOF
cat > "$T/raise_main.c" <<'EOF'
int raise_fn(void);
int main(void) { return raise_fn() == 7 ? 0 : 1; }
EOF
mkdir -p "$T/raise"
"$CC" -dynamiclib -O2 $FIXTURE_FLAGS -install_name "@rpath/libraise.dylib" \
    -Wl,-rpath,/usr/lib/swift "$T/raise.c" -o "$T/raise/libraise.dylib"
"$CC" -O2 $FIXTURE_FLAGS -Wl,-rpath,@loader_path/. "$T/raise_main.c" \
    "$T/raise/libraise.dylib" -o "$T/raise/driver"
raise_pad=$("$DRYDOCK_MACHO_REWRITE" info "$T/raise/libraise.dylib" \
    | sed -n 's/^header pad: \([0-9][0-9]*\) bytes available.*/\1/p')
raise_path="/nonexistent/$(printf 'r%.0s' $(seq 1 $((${raise_pad:-0} + 100))))"
raise_sig=
"$DRYDOCK_MACHO_REWRITE" info "$T/raise/libraise.dylib" | grep -q ' LC_CODE_SIGNATURE ' \
    && raise_sig='load-command delete codesig'
raise_script() { [ -z "$raise_sig" ] || echo "$raise_sig"; printf '%s\n' "$1"; }
for raise_stmt in "dylib append $raise_path" "dylib insert $raise_path" \
                  "rpath replace /usr/lib/swift $raise_path"; do
    raise_what=${raise_stmt%% /*}
    rm -f "$T/raise_out"
    rc=0
    raise_script "$raise_stmt" | "$DRYDOCK_MACHO_REWRITE" "$T/raise/libraise.dylib" \
        "$T/raise_out" >"$T/raise.out" 2>"$T/raise.err" || rc=$?
    [ "$rc" -eq 0 ] && grep -q "^$T/raise/libraise.dylib: grew the header pad by [0-9]* bytes ([0-9]* -> [0-9]* available); contents raised by 0x[0-9a-f]*; new UUID" "$T/raise.err" \
        && ok "raise: $raise_what, past a dylib's pad, grows it by raising its contents, announced" \
        || bad "raise: $raise_what" "exit $rc: $(cut -c1-300 "$T/raise.err")"
    "$DRYDOCK_MACHO_REWRITE" verify "$T/raise_out" >/dev/null 2>&1 \
        && "$DRYDOCK_MACHO_REWRITE" info "$T/raise_out" | grep -qF "$raise_path" \
        && ok "raise: $raise_what: the raised dylib names the path and verifies" \
        || bad "raise: $raise_what" "the output lacks the path or does not verify"
done
cp "$T/raise_out" "$T/raise/libraise.dylib"
if [ "$signing_enforced" -eq 1 ]; then
    skip "raise: a program loads the raised dylib and runs" \
        "this host SIGKILLs any binary modified since it was signed (established independently of drydock-macho-rewrite by the host probe above); exercised for real on 10.9"
else
    "$T/raise/driver" && ok "raise: a program loads the raised dylib and runs" \
        || bad "raise: run" "the driver failed"
    DYLD_PRINT_LIBRARIES=1 "$T/raise/driver" 2>&1 | grep -q "raise/.*libraise\.dylib" \
        && ok "raise: ... and the dylib it loaded is the raised copy" \
        || bad "raise: run" "dyld did not say it loaded $T/raise's libraise.dylib"
fi
# A statement after the raise edits the raised image, re-read: the raise needs
# no relation of its own (src/relations.h).
rc=0
printf '%s\n' "rpath append /opt/after-the-raise" | "$DRYDOCK_MACHO_REWRITE" \
    "$T/raise/libraise.dylib" "$T/raise_after" >"$T/raise.out" 2>"$T/raise.err" || rc=$?
[ "$rc" -eq 0 ] && "$DRYDOCK_MACHO_REWRITE" info "$T/raise_after" | grep -qF "/opt/after-the-raise" \
    && "$DRYDOCK_MACHO_REWRITE" verify "$T/raise_after" >/dev/null 2>&1 \
    && ok "raise: a later edit of the raised dylib fits the grown pad and verifies" \
    || bad "raise: a later edit" "exit $rc: $(cut -c1-300 "$T/raise.err")"

```

- [ ] **Step 2: The relation's row**

In `src/relations.h`, immediately after (`:27`):

```c
 * | sizeofcmds                        | the header pad                 | mr_build_lcs, mg_grow_header            |
```

insert:

```c
 * | absolute addresses of the contents | the contents' place in memory | src/grow.c's raise of a dylib or bundle |
 *
 * The last row has no bit below: only a grow raises the contents, a grow
 * always moves the first section and so already sets MREL_BASE_REL and
 * MREL_FILE_OFF (src/edit.c's me_note_disturbed), and every statement after
 * it reads the raised image afresh. The raise also deletes
 * LC_SEGMENT_SPLIT_INFO, which no statement can name.
```

- [ ] **Step 3: Run them**

Run: build (rebuild check), then `unset DRYDOCK_MACHO_REWRITE; sh tests/cli_test.sh "$B" | grep -E 'raise|cli_test:'`, then the suite.
Expected: nine `PASS raise: …` lines (three statements, two lines each; the run; the loaded copy; the later edit), `cli_test: 0 failure(s)`; green. (Where signing is enforced, seven, and a `SKIP raise: a program loads the raised dylib and runs`.)

- [ ] **Step 4: Mutation proof** (file `src/grow.c`; test `sh tests/cli_test.sh "$B"`)

| # | replace | with | must fail |
|---|---|---|---|
| 1 | `    int raise = hdr->filetype == MH_DYLIB \|\| hdr->filetype == MH_BUNDLE;`<br>`    if (hdr->filetype != MH_EXECUTE && !raise) {` | `    int raise = 0;`<br>`    if (hdr->filetype != MH_EXECUTE && !raise) {` | `FAIL raise: dylib append` |
| 2 | `        fprintf(stderr, "contents raised by %#x%s", first - first_before, uuid ? "; new UUID" : "");` | `        fprintf(stderr, "contents raised by %#x", first - first_before);` | `FAIL raise: dylib append` |

- [ ] **Step 5: Commit**

```bash
git add src/relations.h tests/cli_test.sh
git commit -m "test(cli): grow a dylib's pad through dylib and rpath statements

dylib append, dylib insert and rpath replace, each past a dylib's pad,
raise it, say so, and verify; a program loads the raised dylib and runs
(skipped where signing is enforced, and a signature the linker left is
deleted first); and a later statement edits the raised image.
src/relations.h records the raise, which needs no relation bit of its own.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU"
```

---

### Task 9: Real dylibs, the sweeps, the docs that say a dylib is refused, QUEUE item 31 and the spec

Everything real here is a copy in a scratch directory. None of it is committed: M3 makes the run test (`tests/grown_dylib_runs_test.sh`) and writes the rest of the documentation. What this task does commit, by Ruling 4, is every sentence that would otherwise go on saying a dylib is refused once this plan lands.

**Files** (each edit block below gives its line):
- Modify: `compat/README.md` (the "header pad too short … is grown" bullet; `fix_macho`'s divergence 6; `insert_dylib`'s prompt-3 row and its real-dylib row)
- Modify: `tests/README.md` (the `insert-dylib-diff` note's item (2))
- Modify: `docs/superpowers/QUEUE.md` (item 31's row; a new "Item 31" section before `## Item 32`)
- Modify: `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md` (after M2's last line)

**Interfaces:**
- Consumes: Tasks 1–8's commits, M2a's, and a build of the finished tree in `$B`.
- Produces: nothing code depends on.

- [ ] **Step 1: Find the commits, and build the one before this plan**

```sh
A1=$(git log -1 --format=%h --grep='^feat(hdrref): scan a range of targets')
A5=$(git log -1 --format=%h --grep='^docs: the one rule.s code, symbol and export halves')
B1=$(git log -1 --format=%h --grep='^feat(grow): choose the route by file type')
B2=$(git log -1 --format=%h --grep='^feat(grow): raise a dylib.s or bundle.s contents')
B8=$(git log -1 --format=%h --grep='^test(cli): grow a dylib.s pad')
echo "M2a $A1..$A5  M2b $B1 ($B2) .. $B8"
W=$(mktemp -d -t m2b-sweep)
git archive "$B1^" | (mkdir "$W/src" && tar -x -C "$W/src")
/usr/local/mavergreen/bin/shipyard-cmake -S "$W/src" -B "$W/build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/MavericksToolchain.cmake \
  -DMAVERICKS_EXPECTED_MODE=native -DCMAKE_OSX_DEPLOYMENT_TARGET=10.9 -DCMAKE_OSX_ARCHITECTURES=x86_64 >/dev/null
/usr/local/mavergreen/bin/shipyard-cmake --build "$W/build" -j >/dev/null
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
```

Expected: five short hashes (`$B8` is Task 8's; this task's own commit comes last).

- [ ] **Step 2: The executable sweep: unchanged**

```sh
find /bin /sbin /usr/bin /usr/sbin /usr/libexec -type f 2>/dev/null | sort | while read -r f; do
  lipo -info "$f" 2>/dev/null | grep -q x86_64 && printf '%s\n' "$f"; done > "$W/exe"
wc -l < "$W/exe"                                    # expect 1128
sh "$W/sweep.sh" "$W/build/drydock-macho-rewrite" "$W/xb" "$W/exe" &
sh "$W/sweep.sh" "$B/drydock-macho-rewrite" "$W/xa" "$W/exe" & wait
for s in xb xa; do echo "$s: $(cut -f2 "$W/$s/results.tsv" | sort | uniq -c | tr '\n' ' ')"; done
paste "$W/xb/results.tsv" "$W/xa/results.tsv" | awk -F'\t' '$2 != $6 || $3 != $7 || $4 != $8 { print $1 }' > "$W/xdiff"
wc -l < "$W/xdiff"
while read -r f; do
  lipo "$f" -thin x86_64 -output "$W/t" 2>/dev/null || cp "$f" "$W/t"
  head -c 16 "$W/t" | od -An -tu4 | head -1 | awk '{ print $4 }'
done < "$W/xdiff" | sort | uniq -c
grep -F -f "$W/xdiff" "$W/xa/results.tsv" | grep -c 'contents raised by 0x1000; new UUID.*IN: verified'
```

Expected: `1128`; `xb: 1043 0   85 1` and `xa: 1112 0   16 1`; `69` files differ, and they are exactly the corpus's files that are not executables: `1 6` (a dylib) and `68 8` (bundles: Apache's modules and others under `/usr/libexec`); all 69 now raised and verified. Every `MH_EXECUTE` gives byte-identical output and messages.

- [ ] **Step 3: The system dylibs and bundles**

```sh
find /usr/lib /System/Library/Frameworks -type f -size +4k 2>/dev/null | sort | while read -r f; do
  lipo -info "$f" 2>/dev/null | grep -q x86_64 || continue
  t=$(lipo "$f" -thin x86_64 -output /dev/stdout 2>/dev/null | head -c 16 | od -An -tu4 | head -1 | awk '{ print $4 }')
  [ -n "$t" ] || t=$(head -c 16 "$f" | od -An -tu4 | head -1 | awk '{ print $4 }')
  case "$t" in 6|8) printf '%s\n' "$f";; esac
done > "$W/lib"
wc -l < "$W/lib"                                    # expect 1180 (the listing takes about 15 minutes)
sh "$W/sweep.sh" "$W/build/drydock-macho-rewrite" "$W/lb" "$W/lib" &
sh "$W/sweep.sh" "$B/drydock-macho-rewrite" "$W/la" "$W/lib" & wait
for s in lb la; do echo "$s: $(cut -f2 "$W/$s/results.tsv" | sort | uniq -c | tr '\n' ' ')"; done
R=$W/la/results.tsv
for k in 'IN: verified' 'new UUID' 'dropped LC_SEGMENT_SPLIT_INFO' 'repaired' 're-packed'; do
  echo "$k: $(awk -F'\t' '$2 == 0' "$R" | grep -c "$k")"; done
awk -F'\t' '$2 == 0' "$R" | grep -o 'repaired [0-9]*' | awk '{ s += $2 } END { print "references repaired:", s }'
awk -F'\t' '$2 != 0 { print $1 }' "$R"
P='LC_DYSYMTAB lists|aligned to 2\^'
printf '%s\n' 'ERROR: section __DATA,__data is aligned to 2^13 bytes' | grep -c -E "$P"   # positive control: 1
cat "$W/xa/results.tsv" "$R" | grep -c -E "$P"
```

Expected: `1180`; `lb: 1180 1` (every one refused, `only MH_EXECUTE can be grown`); `la: 1177 0    3 1`; `IN: verified: 1177`, `new UUID: 1177`, `dropped LC_SEGMENT_SPLIT_INFO: 364`, `repaired: 37`, `re-packed: 1173`, `references repaired: 312`; and the three refused: `CFNetwork` and `/usr/lib/libxcselect.dylib` (`LC_LAZY_LOAD_DYLIB present …`, the rewriter's), and `MediaToolbox` (`the bytes at 0x2380d0 may be code that addresses the image's own header …`). Then `1`, and `0`: Task 1's refusals of `LC_DYSYMTAB`'s tables and relocations and of a section aligned past a page fire on none of the 1,180, nor on the executable corpus. The raised sweep takes about 2 minutes.

- [ ] **Step 4: Raised copies, run by Apple's programs**

Seven system dylibs, each raised exactly as the sweep raises one, then loaded through `DYLD_LIBRARY_PATH` or `DYLD_FRAMEWORK_PATH` by a program whose output is compared with its run against the original; `DYLD_PRINT_LIBRARIES` must name the raised copy (the positive control: the review confirmed dyld loads it, not the shared cache's). `/usr/bin/…` is named in full: `xmllint` on `PATH` here is pkgsrc's.

```sh
cat > "$W/run.sh" <<'EOF'
#!/bin/sh
# runproof.sh DMR W -- grow copies of 10.9 system dylibs by raising them, and
# run Apple's programs (and one C++ driver) against each copy, beside a run
# against the original.
DMR=$1 W=$2
rm -rf "$W"; mkdir -p "$W/lib" "$W/fw" "$W/in"
printf '<?xml version="1.0"?>\n<r><a x="1">one</a><b>two</b></r>\n' > "$W/in/doc.xml"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>k</key><array><integer>1</integer><string>s</string></array></dict></plist>\n' > "$W/in/p.plist"
seq 1 20000 > "$W/in/nums"
cat > "$W/in/x.cc" <<'CC'
#include <cstdio>
#include <stdexcept>
#include <string>
struct G { ~G() { std::puts("static destructor ran"); } } g;
int main() {
    try { throw std::runtime_error(std::string("thrown across ") + "libc++"); }
    catch (const std::exception &e) { std::printf("caught: %s\n", e.what()); }
    return 0;
}
CC
clang++ -arch x86_64 -mmacosx-version-min=10.9 -stdlib=libc++ -O1 "$W/in/x.cc" -o "$W/in/xx" 2>/dev/null
grow() {   # grow SRC DEST: a raised copy of SRC's x86_64 slice at DEST
    in=$W/grow.in; rm -f "$in" "$2"
    lipo "$1" -thin x86_64 -output "$in" 2>/dev/null || cp "$1" "$in"
    info=$("$DMR" info "$in" 2>/dev/null)
    pad=$(printf '%s\n' "$info" | awk '/^header pad: / { print $3; exit }')
    n=$(( ${pad:-0} / 200 + 2 )); fill=$(printf '%0180d' 0)
    { printf '%s\n' "$info" | grep -q ' LC_CODE_SIGNATURE ' && echo 'load-command delete codesig'
      i=0; while [ $i -lt $n ]; do echo "rpath append /nonexistent/grow-probe-$i/$fill"; i=$((i+1)); done; } > "$W/edits"
    mkdir -p "$(dirname "$2")"
    "$DMR" "$in" "$2" < "$W/edits" > /dev/null 2> "$W/grow.err"; rc=$?
    grep -v '^  ' "$W/grow.err" | grep 'grew the header pad\|re-packed\|resign' | sed "s|$in|IN|; s|$2|OUT|" | cut -c1-200
    [ $rc -eq 0 ] && "$DMR" verify "$2" >/dev/null 2>&1 && echo "  verify: OK" || echo "  grow or verify FAILED ($rc)"
    return $rc
}
proof() {  # proof NAME ENVVAR DIR EXPECT -- CMD...: run CMD against the copy and the original
    name=$1 var=$2 dir=$3 expect=$4; shift 5
    "$@" > "$W/$name.orig" 2>&1; orc=$?
    : > "$W/$name.dyld"; env "$var=$dir" DYLD_PRINT_LIBRARIES=1 "$@" > "$W/$name.grown" 2>> "$W/$name.dyld"; grc=$?
    grep -q "$expect" "$W/$name.dyld" && loaded=yes || loaded=NO
    grep -v '^dyld: loaded:' "$W/$name.dyld" >> "$W/$name.grown"
    if cmp -s "$W/$name.orig" "$W/$name.grown" && [ $orc -eq $grc ] && [ $loaded = yes ]; then
        echo "  $name: runs as the original does (exit $grc, $(wc -l < "$W/$name.grown" | tr -d ' ') lines of output), and loaded the raised copy"
    else
        echo "  $name: DIFFERS: exit $orc -> $grc, loaded the copy: $loaded"; diff "$W/$name.orig" "$W/$name.grown" | head -5
    fi
}
L=$W/lib F=$W/fw
echo "libz.1.dylib";      grow /usr/lib/libz.1.dylib "$L/libz.1.dylib" && proof gzip DYLD_LIBRARY_PATH "$L" "$L/libz.1.dylib" -- /usr/bin/gzip -9 -n -c "$W/in/nums"
echo "libxml2.2.dylib";   grow /usr/lib/libxml2.2.dylib "$L/libxml2.2.dylib" && proof xmllint DYLD_LIBRARY_PATH "$L" "$L/libxml2.2.dylib" -- /usr/bin/xmllint --format "$W/in/doc.xml"
echo "libsqlite3.dylib";  grow /usr/lib/libsqlite3.dylib "$L/libsqlite3.dylib" && proof sqlite3 DYLD_LIBRARY_PATH "$L" "$L/libsqlite3.dylib" -- /usr/bin/sqlite3 :memory: "create table t(x); insert into t values (6),(7); select sqlite_version(), x, (select sum(x) from t) from t;"
echo "libcurl.4.dylib";   grow /usr/lib/libcurl.4.dylib "$L/libcurl.4.dylib" && proof curl DYLD_LIBRARY_PATH "$L" "$L/libcurl.4.dylib" -- /usr/bin/curl -s "file://$W/in/doc.xml"
echo "libc++.1.dylib";    grow /usr/lib/libc++.1.dylib "$L/libc++.1.dylib" && proof cxx DYLD_LIBRARY_PATH "$L" "$L/libc++.1.dylib" -- "$W/in/xx"
echo "CoreFoundation";    grow /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation "$F/CoreFoundation.framework/Versions/A/CoreFoundation" && proof plutil-cf DYLD_FRAMEWORK_PATH "$F" "$F/CoreFoundation.framework" -- /usr/bin/plutil -convert xml1 -o - "$W/in/p.plist"
echo "Foundation";        grow /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation "$F/Foundation.framework/Versions/C/Foundation" && proof plutil DYLD_FRAMEWORK_PATH "$F" "$F/Foundation.framework" -- /usr/bin/plutil -convert json -o - "$W/in/p.plist"
EOF
sh "$W/run.sh" "$B/drydock-macho-rewrite" "$W/run" 2>&1
```

Expected, for each of `libz.1.dylib`, `libxml2.2.dylib`, `libsqlite3.dylib`, `libcurl.4.dylib`, `libc++.1.dylib`, `CoreFoundation` and `Foundation`: its name; `IN: grew the header pad by 4096 bytes (… available); contents raised by 0x1000; new UUID; dropped LC_SEGMENT_SPLIT_INFO` (libc++ adds `; repaired 18 references to the header`, CoreFoundation `; repaired 2 references to the header`); `IN: __LINKEDIT re-packed in codesign_allocate's order: …`; `  verify: OK`; and `  gzip: runs as the original does (exit 0, …), and loaded the raised copy` (then `xmllint`, `sqlite3`, `curl`, `cxx`, `plutil-cf`, `plutil`). No `DIFFERS`. For instance:

```
libc++.1.dylib
IN: grew the header pad by 4096 bytes (168 -> 4280 available); contents raised by 0x1000; new UUID; dropped LC_SEGMENT_SPLIT_INFO; repaired 18 references to the header
IN: __LINKEDIT re-packed in codesign_allocate's order: 401,707 -> 328,791 bytes, 72,916 unreferenced bytes dropped
  verify: OK
  cxx: runs as the original does (exit 0, 2 lines of output), and loaded the raised copy
```

- [ ] **Step 5: `__LINKEDIT`'s re-pack, and re-signing**

Every raise above re-packed `__LINKEDIT` (Step 3's count, and Step 4's `re-packed` lines, which dropped split info's payload among the unreferenced bytes). Then:

```sh
for f in "$W/run/lib/"*.dylib "$W/run/fw/"*/Versions/*/*; do
  printf '%s: ' "${f#$W/run/}"; "$B/drydock-macho-rewrite" info "$f" | grep 'resign 10.9'; done
cp "$W/run/lib/libxml2.2.dylib" "$W/signed.dylib"
codesign -f -s - "$W/signed.dylib" && codesign -v -v "$W/signed.dylib"
"$B/drydock-macho-rewrite" verify "$W/signed.dylib"
mkdir "$W/slib" && cp "$W/signed.dylib" "$W/slib/libxml2.2.dylib"
printf '<r><a>one</a></r>\n' > "$W/s.xml"
DYLD_LIBRARY_PATH="$W/slib" DYLD_PRINT_LIBRARIES=1 /usr/bin/xmllint --format "$W/s.xml" 2>&1 | grep -a 'slib/libxml2\|<a>'
```

Expected: `resign 10.9: ok` for all seven; `valid on disk` and `satisfies its Designated Requirement`; `…/signed.dylib: OK`; and `dyld: loaded: …/slib/libxml2.2.dylib` with `  <a>one</a>`.

- [ ] **Step 6: Sparkle, and Claude Code**

```sh
for sp in /Applications/ShiftIt.app /Users/schmonz/Downloads/Downie.app /Applications/iTerm.app /Applications/OBS.app /Applications/Utilities/XQuartz.app; do
  b=$sp/Contents/Frameworks/Sparkle.framework/Versions/A/Sparkle; [ -f "$b" ] || continue
  printf '%s\n' "$b" > "$W/sp.list"; rm -rf "$W/sp"
  sh "$W/sweep.sh" "$B/drydock-macho-rewrite" "$W/sp" "$W/sp.list"
  echo "$sp: $(lipo -info "$b" | sed 's/.*: //'): $(cut -f2,4 "$W/sp/results.tsv" | cut -c1-140)"
done
CC=~/.local/share/claude-binary-snapshots/2.1.282.49763317.bin
fill=$(printf '%06000d' 0)
printf 'fixups set classic\nrpath append /nonexistent/%s\n' "$fill" > "$W/cc.edits"
"$W/build/drydock-macho-rewrite" "$CC" "$W/cc.before" < "$W/cc.edits" >/dev/null 2>&1
"$B/drydock-macho-rewrite" "$CC" "$W/cc.after" < "$W/cc.edits" >/dev/null 2>&1
cmp "$W/cc.before" "$W/cc.after" && echo "Claude Code: identical"
```

Expected: ShiftIt's and Downie's (`ppc i386 x86_64`): `1	ERROR: a dylib or bundle with no LC_DYLD_INFO[_ONLY]: only its rebase opcodes list every pointer a raise moves; refusing to grow`, Decision 6's reason; iTerm's, OBS's and XQuartz's: `0	IN: grew the header pad by 4096 bytes …; contents raised by 0x1000; new UUID…` (XQuartz's repairs 3 references). Then `Claude Code: identical`. Skip an application this host lacks, and say so. Then `rm -rf "$W"`.

- [ ] **Step 7: The docs that say a dylib is refused** (Ruling 4)

Each sentence below says a dylib cannot grow, or that this toolkit refuses one. The two about the `insert_dylib` differential of 2026-09-20 keep what that run found and say what the wrapper does now; the new behaviour is `tests/insert_dylib_test.sh`'s "no room: a dylib's contents are raised, announced" (Task 2).

In `compat/README.md`, replace (`:151`):

```markdown
    ..."), and exits 0; anything else is still refused. When the
```

with:

```markdown
    ..."), and exits 0; an x86_64 dylib or bundle has no `__PAGEZERO`, so
    everything after its load commands is raised instead ("...; contents
    raised by 0x1000; new UUID"); anything else is still refused. When the
```

In `compat/README.md`, replace (`:477`):

```markdown
| 6 | **A header pad too short for the replacement is now GROWN**, on an x86_64 PIE executable: the image base is lowered to make room, announced on stderr, exit 0. `fix_macho` had no `-grow` and never enlarged a header. Adopted by the repo owner's ruling for every wrapper: the engine never writes its input and the grow verifies itself, so refusing bought nothing. A non-PIE executable or a dylib is still refused, exit 1, file untouched | `tests/wrapper_test.sh`, "a replacement the pad cannot hold grows the header, announced"; its `fix_macho` mid-script refusal clears `MH_PIE` on its copy so that it still refuses |
```

with:

```markdown
| 6 | **A header pad too short for the replacement is now GROWN**, on an x86_64 PIE executable: the image base is lowered to make room, announced on stderr, exit 0. `fix_macho` had no `-grow` and never enlarged a header. Adopted by the repo owner's ruling for every wrapper: the engine never writes its input and the grow verifies itself, so refusing bought nothing. An x86_64 dylib or bundle grows too, its contents raised rather than its base lowered. A non-PIE executable is still refused, exit 1, file untouched | `tests/wrapper_test.sh`, "a replacement the pad cannot hold grows the header, announced"; its `fix_macho` mid-script refusal clears `MH_PIE` on its copy so that it still refuses |
```

In `compat/README.md`, replace (`:779`):

```markdown
| the fork's prompt 3 ("it doesn't seem like there is enough empty space") is **not asked**: on an x86_64 PIE executable a short header pad is grown, announced on stderr, exit 0, where the fork asked before its own expansion. Anything that cannot grow — a dylib, a non-PIE executable — is refused in `dylib append`'s words, forwarded through the exit code above | `tests/insert_dylib_test.sh`, "no room: the header grows, announced" |
| `--inplace` together with an explicit `new_binary_path` is **refused**, where the fork silently picks one and never reads the other (`--inplace` wins; `main.c`'s `if(!inplace_flag) { ... }` block that would consume `argv[3]` is skipped entirely when `--inplace` is set, so the named file is never even opened). Matching the fork here would mean silently ignoring an output path the caller wrote out by hand and overwriting their input instead — the data-loss shape this toolkit refuses rather than guesses through everywhere else, and there are no known callers of this tool to break by refusing. `compat/translate.sh`'s `mt_id_parse` refuses it unconditionally, before any prompt, so `--all-yes` does not make it succeed either | `tests/insert_dylib_test.sh`, "--inplace + new_binary_path" (three assertions: refuses exit 1 even with `--all-yes`, names both `--inplace` and the path, and leaves both the input and the named path untouched) |
| on a real dylib whose header pad is too small for the new load command and which carries no `__PAGEZERO` to shrink (true of every dylib — only executables have one), **the fork reports success and exits 0** while its own stderr admits `__PAGEZERO segment not found, cannot expand header.` The file it writes **fails this toolkit's own `drydock-macho-rewrite verify`** (`mg_plausible` refuses it): the fork's own header-expansion path did not actually expand anything, and nothing downstream of that checks. This wrapper refuses cleanly instead — `ERROR: only MH_EXECUTE can be grown ...`, then `ERROR: ... don't fit in header pad (... avail), and the header could not be grown (see above)`, exit 1, input untouched. This is not a case where this toolkit needs to catch up: the fork is wrong here, and the four checks named just above this table (plus `mg_verify`/`mg_plausible`) are exactly why this side catches it and the fork does not | `tests/insert-dylib-diff.sh`'s 2026-09-20 run (`tests/README.md`), reproduced on `/usr/lib/swift/libswiftDarwin.dylib`, a real thin (non-fat) system dylib, so the differential's Mach-O-validity check ran on the fork's own output rather than being skipped for being unreadable fat |
```

with:

```markdown
| the fork's prompt 3 ("it doesn't seem like there is enough empty space") is **not asked**: on an x86_64 PIE executable a short header pad is grown, announced on stderr, exit 0, where the fork asked before its own expansion. An x86_64 dylib grows too, its contents raised, announced. Anything that cannot grow — a non-PIE executable, a dylib with no `LC_DYLD_INFO` — is refused in `dylib append`'s words, forwarded through the exit code above | `tests/insert_dylib_test.sh`, "no room: the header grows, announced" and "no room: a dylib's contents are raised, announced" |
| `--inplace` together with an explicit `new_binary_path` is **refused**, where the fork silently picks one and never reads the other (`--inplace` wins; `main.c`'s `if(!inplace_flag) { ... }` block that would consume `argv[3]` is skipped entirely when `--inplace` is set, so the named file is never even opened). Matching the fork here would mean silently ignoring an output path the caller wrote out by hand and overwriting their input instead — the data-loss shape this toolkit refuses rather than guesses through everywhere else, and there are no known callers of this tool to break by refusing. `compat/translate.sh`'s `mt_id_parse` refuses it unconditionally, before any prompt, so `--all-yes` does not make it succeed either | `tests/insert_dylib_test.sh`, "--inplace + new_binary_path" (three assertions: refuses exit 1 even with `--all-yes`, names both `--inplace` and the path, and leaves both the input and the named path untouched) |
| on a real dylib whose header pad is too small for the new load command and which carries no `__PAGEZERO` to shrink (true of every dylib — only executables have one), **the fork reports success and exits 0** while its own stderr admits `__PAGEZERO segment not found, cannot expand header.` The file it writes **fails this toolkit's own `drydock-macho-rewrite verify`** (`mg_plausible` refuses it): the fork's own header-expansion path did not actually expand anything, and nothing downstream of that checks. This wrapper refused cleanly then — `ERROR: only MH_EXECUTE can be grown ...`, exit 1, input untouched — and now grows such a dylib's header pad by raising its contents, announced, and its output verifies (`tests/insert_dylib_test.sh`, "no room: a dylib's contents are raised, announced"). This is not a case where this toolkit needs to catch up: the fork is wrong here, and the four checks named just above this table (plus `mg_verify`/`mg_plausible`) are exactly why this side catches it and the fork does not | `tests/insert-dylib-diff.sh`'s 2026-09-20 run (`tests/README.md`), reproduced on `/usr/lib/swift/libswiftDarwin.dylib`, a real thin (non-fat) system dylib, so the differential's Mach-O-validity check ran on the fork's own output rather than being skipped for being unreadable fat |
```

In `tests/README.md`, replace (`:81`):

```markdown
  `drydock-macho-rewrite verify`'s own plausibility check; this wrapper refuses
  instead (`EX_REFUSED`; a dylib cannot grow, which today's wording says as
  "only MH_EXECUTE can be grown"), leaving the input untouched. (3) On an unwritable `--inplace` target the fork's own
```

with:

```markdown
  `drydock-macho-rewrite verify`'s own plausibility check; this wrapper then
  refused instead (`EX_REFUSED`, "only MH_EXECUTE can be grown"), leaving the
  input untouched, and now grows the dylib's header pad by raising its
  contents, verified. (3) On an unwritable `--inplace` target the fork's own
```

Then check nothing else says so:

```sh
P='dylib is still refused|a dylib cannot grow|a dylib, a non-PIE'
git grep -n -E "$P" "$B1^" -- README.md compat docs/*.md tests/README.md | wc -l   # positive control: 3, before this plan
rc=0; git grep -n -E "$P" -- README.md compat docs/*.md tests/README.md || rc=$?; echo "rc=$rc"   # expect rc=1
```

Expected: `3` (compat divergence 6, the prompt-3 row, and the test note); then `rc=1`. The quotation `ERROR: only MH_EXECUTE can be grown` stays once in each file, as what the wrapper said at the 2026-09-20 run.

- [ ] **Step 8: `docs/superpowers/QUEUE.md` and the spec**

In `docs/superpowers/QUEUE.md`, replace (`:37`):

```markdown
| 31 | Grow a dylib's header | `specs/2026-09-25-dylib-header-growth-design.md` | — | **designed** 2026-09-25; the adversarial review's findings are being folded in |
```

with:

```markdown
| 31 | Grow a dylib's header | `specs/2026-09-25-dylib-header-growth-design.md` | M2a `@A1@..@A5@`, M2b `@B1@..@B9@` (plans deleted once implemented) | **raised** since `@B2@`: a dylib's or bundle's header pad grows; M3, the committed run test and the documentation, remains, see below |
```

In `docs/superpowers/QUEUE.md`, immediately before (`:1550`):

```markdown
## Item 32: a load command shorter than its struct
```

insert:

```markdown
## Item 31: grow a dylib's header

**M2 done** (`@A1@..@B9@`). A dylib's or bundle's header pad grows by raising
everything after its load commands a page at a time, and every absolute
address that names it: rebased pointers, symbols (a debugging image's stabs
among them), sections, segments and `LC_ROUTINES_64`. `LC_UUID` is replaced,
since the old dSYM would describe the raised image wrongly, and
`LC_SEGMENT_SPLIT_INFO`, which a raise leaves stale, is deleted. Each raise
verifies itself six ways (the spec's Decision 7), among them a byte-for-byte
comparison with the image it came from, and four oracles (initializers, lazy
pointers, exports, compact unwind) that read what they check with code of
their own. The other checks read the image through the decoders the raise
reads it through (`mg_rebases_read`, `mg_collect`'s walkers, `mg_symtab`,
`mhr_scan`), so an entry one of those misses is missed by both: those
decoders are guarded by their unit tests, and the rebase opcodes' by
`rebase_oracle_test`'s comparison with `dyldinfo`. `LC_LOAD_UPWARD_DYLIB`, which no grow had
classified, is accepted on both routes: AppKit, HIToolbox, Metadata and ten
of libSystem's parts carry one.

Measured 2026-09-26 over this host's 1,180 x86_64 dylibs and bundles under
`/usr/lib` and `/System/Library/Frameworks` (399 dylibs, 781 bundles), with
`rpath append`s past each pad: 1,177 grow and verify, where none did before.
364 drop split info, and 37 repair 312 references to their own header.
Three are refused: CFNetwork and `libxcselect.dylib` carry
`LC_LAZY_LOAD_DYLIB`, which the rewriter's ordinal renumbering refuses, and
MediaToolbox has code at 0x2380d0 that may address its header and that
decoding does not confirm. Raised copies of libz, libxml2, libsqlite3,
libcurl, libc++, CoreFoundation and Foundation load under `gzip`, `xmllint`,
`sqlite3`, `curl`, a C++ program that throws across libc++, and `plutil`,
and print what the originals print. `info` says `resign 10.9: ok` of each,
and a copy signed ad hoc with 10.9's `codesign` verifies and runs. An old
Sparkle.framework (ppc, i386 and x86_64, no `LC_DYLD_INFO`) is refused for
that; newer ones grow. The executable route is unchanged: the M1 sweep's
1,059 executables give byte-identical output, and so does Claude Code.

**M3 remains**: the committed run test, `tests/grown_dylib_runs_test.sh`
(Apple's dylibs under Apple's programs, and host-built dylibs for what no
system dylib has: a thread-local variable, `dlsym` through the trie,
`&__dso_handle` beside a data pointer to it, and both F < G and F > G), and
the documentation: `docs/macl-case-study.md` rows 9 and 23, `src/grow.h`'s
top comment, the two limits the spec's M3 section names (repeated grows and
the function-starts delta; a real reference after an undeclared jump table),
and items 29 and 31 marked done. (`compat/README.md`'s and
`tests/README.md`'s words that a dylib is refused changed with M2 itself.)

```

In `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`, replace (`:347`):

```markdown
slips in the implementation but not a row missing from the table. Checks 4–6
are independent of the table, and exist to catch exactly that.
```

with:

```markdown
slips in the code that applies it, but not a row missing from the table.
Checks 4–6 are independent of the table, and exist to catch exactly that.
None of them catches a slip in a decoder the grow and its checks share:
checks 1–3 and 5 read the image through the same readers of rebases, the
export trie, compact unwind, data in code, function starts and code
(implemented as `mg_rebases_read`, `mg_collect`'s walkers, `mg_symtab` and
`mhr_scan`), so an entry those miss is neither moved nor compared. Their unit tests
guard them, and for the rebase opcodes the `dyldinfo` oracle (Decision 9).
Check 4 reads what it checks with code of its own, and so catches some such
misses.
```

In `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`, immediately after (`:376`):

```markdown
   - Every `__la_symbol_ptr` value lies in `__stub_helper`.
```

insert:

```markdown
   - Every compact-unwind personality names a `__got` or `__nl_symbol_ptr`
     slot, and every LSDA lies in `__gcc_except_tab` (added by plan M2b).
```

In `docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md`, replace (`:484`):

```markdown
**M3: proof on real dylibs, and documentation.** This covers the real-run
test below, and the documentation updates.
```

with:

```markdown
**Done** (`@A1@..@B9@`, plans M2a and M2b). What the plans settled that
this section left open, for M3's reader:

- Decoding gives each in-range candidate one of three verdicts: confirmed,
  refuted, or not reached. The owner's I1 answer (2026-09-26): a confirmed or
  not-reached candidate refuses the grow, and a refuted one passes.
- Checks 2 (its load-command half), 3 and 4 run on the raise route only;
  the executable route keeps checks 1, 2's pointer and symbol halves, 5 and
  6. Check 4 asks of the raised image only the oracles that held of the
  original.
- A symbol or stab below the base, like one naming the header, stays.
- The UUID is SHA-256 over the old UUID and then G as 8 bytes,
  little-endian.
- `LC_LOAD_UPWARD_DYLIB` is accepted on both routes.
- `compat/README.md`'s rows that said a dylib is refused change with M2, not
  M3, so no document says so while dylibs grow.
- A raise's segment must have its file data at F or past it, and an
  `LC_UUID`, `LC_ROUTINES_64`, `LC_DYSYMTAB` or encryption command too
  short to read is refused. So are what no system image has: beside
  `LC_DYLD_INFO`, `LC_DYSYMTAB`'s table of contents, module table, and
  external or local relocations, whose addresses no rebase opcode lists;
  and a section aligned to more than a page.
- Code that names an address outside the image is not refused. Tried, it
  refused 20 system images, each for a jump table that decoding took for
  code naming an address 143 MiB or more away; a position-independent
  image names nothing outside itself RIP-relatively.

**M3: proof on real dylibs, and documentation.** This covers the real-run
test below, and the documentation updates. The documentation must also say,
as M2's review found:

- Grows add up. The function-starts leading delta gains G at each grow, and
  a grow refuses once it would need a wider ULEB (Decision 6), so an image
  grown more than once, on either route, can reach that refusal.
- Under the owner's I1 ruling, decoding "refutes" a candidate that sits
  after an undeclared jump table in `__text` (no `LC_DATA_IN_CODE` for it),
  if the table's bytes happen to decode as instructions that end inside or
  past the candidate. A real in-range reference there passes, and grows
  silently wrong.
```

Then replace the placeholders with Step 1's hashes, and this task's own commit's range end with `$B8` (the docs commit is not code):

```sh
sed -i '' "s/@A1@/$A1/g; s/@A5@/$A5/g; s/@B1@/$B1/g; s/@B2@/$B2/g; s/@B9@/$B8/g" \
  docs/superpowers/QUEUE.md docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md
rc=0; git grep -n '@[AB][0-9]@' -- docs || rc=$?; echo "rc=$rc"          # expect rc=1
git grep -c "$B8" -- docs/superpowers/QUEUE.md                             # positive control: 2
```

- [ ] **Step 9: Check the tree**

```sh
git grep -n 'M2 done' -- docs/superpowers/QUEUE.md | wc -l                 # expect 1
rc=0; git grep -n -E 'superpowers|specs/|plans/' -- src tests CMakeLists.txt || rc=$?; echo "rc=$rc"   # expect rc=1
git grep -c -E 'superpowers|specs/|plans/' -- docs/superpowers/QUEUE.md    # positive control: > 0
unset DRYDOCK_MACHO_REWRITE; /usr/local/mavergreen/bin/shipyard-ctest --test-dir "$B" | tail -3
```

Expected: `1`; `rc=1`; a count; `100% tests passed out of 29`, `chained_fixups` skipped.

- [ ] **Step 10: Commit**

```bash
git add compat/README.md tests/README.md docs/superpowers/QUEUE.md docs/superpowers/specs/2026-09-25-dylib-header-growth-design.md
git commit -F- <<EOF
docs: a dylib's header pad grows by raising its contents

QUEUE item 31's M2 is done ($A1..$B8): 1,177 of this host's 1,180 x86_64
system dylibs and bundles grow, raised and verified, where none did;
raised copies of libz, libxml2, libsqlite3, libcurl, libc++, CoreFoundation
and Foundation run under Apple's programs as the originals do, and can be
re-signed with 10.9's codesign. The executable route is unchanged. The
compat rows and the test note that said a dylib is refused say what it
does now. M3, the committed run test and the rest of the documentation,
remains.

Co-Authored-By: <authoring model> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012jhWLkqMJWtSif6MwCSCVU
EOF
```

(The heredoc is unquoted so the hashes expand; check `git log -1`.)

- [ ] **Step 11: After the owner pushes: CI** (Ruling 5)

CI runs on `macos-26-arm64` from a cross build, and Task 8's `cli_test` block compiles its dylib and driver with CI's clang and runs them under Rosetta: a gate this host cannot run. After the owner pushes, check the run for the pushed head, and treat a red one as this plan's to fix (memory: "Check CI, not just local suites"):

```sh
gh run list --branch main --limit 3
```

Expected: the newest run, on the pushed head, `completed success`.

**Where M3 begins.** M3 is its own plan, written when this one lands. It is the spec's "Real dylibs, run (M3)" as a committed test, `tests/grown_dylib_runs_test.sh`: Apple's dylibs under Apple's programs, invoked by absolute path, with `DYLD_PRINT_LIBRARIES` as the positive control on every run, and host-built fixture dylibs for what no system dylib has (a thread-local variable, `dlsym` through the export trie, `&__dso_handle` and `getsectiondata(&_mh_dylib_header, …)` beside a data pointer to `__dso_handle`, a C++ exception across grown code, static initializers), with both F < G and F > G; SKIPped off 10.9 x86_64. And the rest of the documentation (Step 7 already made true every sentence that said a dylib is refused): `README.md`'s grow paragraph; `docs/macl-case-study.md` rows 9 and 23; `src/grow.h`'s top comment (the one rule, the completeness argument and its residual risk, the header-reference repair); the two limits Step 8 adds to the spec's M3 section (grows add up to the function-starts leading-delta refusal, on either route; and under M2a's ruling decoding can refute a real reference after an undeclared jump table); QUEUE items 29 and 31 done; and the spec deleted. Step 4 above is this plan's evidence, not M3's test.

---

## Self-review

**1. Spec coverage.**

| requirement | task |
|---|---|
| Decision 1: two routes by file type | 1 |
| Decision 1: a `__TEXT` section whose `addr − base` ≠ `offset`, a section below the first, refused | 1 |
| Decision 2: every row | 2 (geometry, pointers, symbols, `LC_ROUTINES_64`, walkers, code), 3 (stabs), 4 (split info), 5 (UUID) |
| Decision 2: an absolute export unchanged | M0; 2 verifies it (`test_raise_leaves_an_absolute_export_alone`) |
| Decision 4: split info dropped, before the snapshot, `mg_classify`'s route, the `rewrite.c` comment and the test | 4 |
| Decision 5: the UUID | 5 |
| Decision 6: every refusal | 1 (route, `LC_DYLD_INFO`, thread, encryption, protected, geometry, short commands; and the review's: `LC_DYSYMTAB`'s tables and relocations beside `LC_DYLD_INFO`, a section aligned past a page); M2a (rebase type and place, binds, strictly inside); 2 (outside every segment); 3 (unknown stab); 5 (short `LC_UUID`); M1 (unconfirmed candidate); function starts and the trie as before |
| Decision 7: checks 1, 2 (pointers, symbols), 5, 6 with the delta | 2 |
| Decision 7: check 2's load-command half, check 3 | 6 |
| Decision 7: check 4 | 7 |
| Decision 8: the announcement; `src/relations.h` | 2, 4, 5; 8 |
| Decision 9: the rebase oracle | already in the tree (`rebase_oracle_test`) |
| Interfaces to generalise: delta, new base + G, the repair loop | 2 |
| Testing: each Decision 2 row on a fixture, with its mutation | 2, 3, 4, 5 |
| Testing: the rule (`__dso_handle` pointer, `__mh_dylib_header`, export offset 0; content at base + F) | 2 (`test_raise_leaves_an_export_at_offset_0` for offset 0) |
| Testing: stabs on a `-g` fixture (`N_ENSYM`, `N_OSO` unchanged) | 3 (`dy_stabs` is ld64's `-g` output, as measured) |
| Testing: each refusal leaves the buffer untouched | 1–5 (`check_grow_refuses_header_refs`) |
| Testing: each verification check catches a planted error | 2 (1, 2, 5), 6 (2, 3), 7 (4); 6 is M0's |
| Testing: `dylib append`, `dylib insert`, `rpath replace` in `cli_test.sh` | 8 |
| Testing: Sparkle refused with Decision 6's reason | 9 |
| Testing: the executable route unchanged | every task's suite; 9's sweep |
| Documentation (M3's), the part that would be false once dylibs grow | 9 (Ruling 4) |

**2. Placeholder scan.** No "TBD" or "similar to Task N". `@A1@`, `@A5@`, `@B1@`, `@B2@`, `@B9@` are replaced by Task 9's own step. `<authoring model>` is the trailer's own wording.

**3. Type and name consistency.** `mg_raise_ok` (Task 1) gains `LC_UUID` in Task 5. `mg_raise_pointers` returns `int` at its declaration, its definition and its one call, before anything moves; `mg_raise_rebased` is called once, after. `mg_move_symbols(buf, fsize, base, first, grow, raise, patch)` is called with seven arguments at both sites. `mg_symtab(im, fsize, &st, &nl, &nsyms)` (Task 3) has five at both calls. `mg_classify(buf, fsize, raise)` (Task 4) has one call. `mg_raised_uuid` (Task 5) is what Task 6's expectation calls. `mg_snapshot`'s fields are each set in `mg_snapshot_take` and freed in `mg_snapshot_free`. The test helpers are each defined before first use.

**4. Review Focus.** Five inputs no requirement names: a base above 0, the edges of content (past a gap of one page and of two), a widening trie, a zero-fill segment at file offset 0, and adjacent split infos. Each has its test. The sixth item, what verification trusts, is stated in `src/grow.h` (Task 7), the QUEUE and the spec (Task 9), and Task 7's rows 20 and 21 show an oracle catching a walker's miss.
