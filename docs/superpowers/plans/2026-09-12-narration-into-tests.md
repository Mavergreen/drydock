# Narration Into Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the narration in this repo's worst-offending files into tests that fail when someone breaks what they described, and delete the prose that is left.

**Architecture:** Five buckets per passage (testable → write the test; already tested → delete; load-bearing → one sentence; history → delete, git has it; interface contract → compress). One file per commit, worst-first by measured comment density. Task 1 proves the method on the single hardest claim in the tree before any bulk deletion happens.

**Tech Stack:** C99, stock 10.9 AppleClang 6.0, CMake + ctest, POSIX `/bin/sh`. Tests go in `tests/cli_test.sh` (CLI behaviour) and the `tests/*_test.c` hermetic idiom (module behaviour).

**Spec:** `docs/superpowers/specs/2026-09-12-narration-into-tests-design.md`

## Global Constraints

- **The safety rule: any passage stating a constraint must either become a test or keep a one-line form. Never both deleted and untested.**
- **Every new test must be mutation-checked**: break the thing it describes, watch that test fail, revert, and record it. A test that cannot fail is worse than no test.
- **Take the mutation record after the last assertion exists.** A record taken earlier goes stale silently; that has already happened once in this repo.
- `tests/EXPECTED` is never edited. `sh tests/characterize.sh $B check` must keep printing `characterize: OK (ad12bdd780da4131f81a808e6d08b688e2034f37e434772f81df023332b39792)`. No emitted byte changes in this plan, so a moved digest is a real defect.
- `tests/known-callers.sh`'s converted-bytes sha256s are never edited. If one moves, **stop and report** — that is a finding, not an expectation to update.
- **The six wrappers' stdout stays byte-identical.** `tests/wrapper_test.sh` is the gate that actually protects it (the digests hash file bytes, not output).
- POSIX `/bin/sh` only in `compat/*.sh` and tests: no `[[`, `local`, `+=`, arrays, `<<<`, `$'...'`, `function`, `source`. 10.9 ships Python 2 only; no `sort -V`.
- C99, warning-free under stock 10.9 AppleClang 6.0.
- **Run the family gates from a main-based shipyard**, never `../mavericks-shipyard` (a feature branch, spurious failures): `sh /Users/schmonz/Documents/code/trees/mavericks-shipyard-readme-gate/scripts/check-family-conventions.sh .` and the same path's `check-shell-portability.sh .`.
- **Do not touch `README.md`.** Its rewrite, and removing its unreviewed-human marker, belong to the repo owner.
- **Do not touch** `tests/compat-matrix.tsv`, `tests/compat-sweep.sh`'s `refuser=` value, completed plans and specs, or the two dated research records.
- **Do not fix code defects here.** `src/rewrite.c`'s three unchecked `calloc`s stay as they are, disclosure comment included: a sweep that also changes behaviour is a sweep nobody can review.
- Committed text never names plan artifacts. Build dir: `B=/private/tmp/mm-build/schmonz/macho-tools/native`.

## File structure

| file | lines | comment | % | disposition |
|---|---|---|---|---|
| `src/edit.h` | 304 | 290 | 95% | Tasks 1–2. Target ≤ 60 comment lines. |
| `compat/fix_macho.sh` | 284 | 259 | 91% | Task 3. Target ≤ 35. Divergences consolidate into `compat/README.md`, which already carries such a list. |
| `compat/change_dylib.sh` | 221 | 196 | 88% | Task 4. Target ≤ 35. |
| `src/rewrite.h` | 425 | 359 | 84% | Task 5. Target ≤ 90. |
| `tests/cli_test.sh` | — | — | — | gains the new tests in Tasks 1, 3, 4, 5 |
| `compat/README.md` | — | — | — | receives the wrappers' divergence tables and the moved MEASURED transcript |
| `src/rewrite.c`, `cli/machotool.c`, `src/grow.h` | 1424 / 1382 / 321 | 758 / 728 / 206 | 53% / 52% / 64% | Task 6 measures and decides; a follow-up plan if warranted |

---

### Task 1: The refusal inventory becomes a test

`src/edit.h:139-153` claims exactly which of `edit`'s refusals name both files and which cannot. That paragraph has been **wrong twice in one day** — first as an absolute ("true of every one of them"), then as a narrower claim that still missed two allocation-failure sites. It is the perfect bucket-1 passage: a precise, checkable claim that prose kept getting wrong. Pin it, then delete it.

**Files:**
- Modify: `tests/cli_test.sh` — add the refusal-inventory block
- Modify: `src/edit.h:139-153` — delete the inventory paragraph, leaving one sentence

**Interfaces:**
- Produces: a `cli_test.sh` block named `edit refusal inventory` that later tasks must keep passing. No C interface changes.

- [ ] **Step 1: Write the failing test**

Add to `tests/cli_test.sh`, after the existing `edit` refusal assertions. Every refusal that happens **after** the image has been read must name both files; the pre-read and unresolved-bytes refusals must not claim anything about PATH.

```sh
# ---- edit refusal inventory ------------------------------------------------
#
# Which refusals name both files is a property worth pinning rather than
# describing: the prose version of this was wrong twice, first as an absolute
# and then as a narrower claim that still missed two sites. A refusal that has
# read the image says what became of OUT and of PATH; one that never got that
# far says only what it can.
ri_both() {   # $1 = label, $2 = stderr file -- must name both files
    if grep -q 'not written;' "$2" && grep -q 'left unmodified' "$2"; then
        ok "refusal inventory: $1 names both files"
    else
        bad "refusal inventory: $1" "expected both halves: $(cat "$2")"
    fi
}
ri_neither() {  # $1 = label, $2 = stderr file -- must NOT claim anything of PATH
    if grep -q 'left unmodified' "$2"; then
        bad "refusal inventory: $1" "claimed PATH's fate before reading it: $(cat "$2")"
    else
        ok "refusal inventory: $1 says only what it can"
    fi
}

build_main "$T/ri_in"
printf 'load-command delete uuid\n' >"$T/ri.edits"

# The two that fire before anything is read.
"$MACHOTOOL" edit "$T/ri_in" "$T/ri.edits" >/dev/null 2>"$T/ri1.err" || :
ri_neither "no output file was named" "$T/ri1.err"
"$MACHOTOOL" edit "$T/ri_in" "$T/ri_in" "$T/ri.edits" >/dev/null 2>"$T/ri2.err" || :
ri_neither "OUT is PATH" "$T/ri2.err"

# The ones where PATH's bytes never resolved into an image this tool parses.
"$MACHOTOOL" edit "$T/nosuchfile" "$T/ri.out" "$T/ri.edits" >/dev/null 2>"$T/ri3.err" || :
ri_neither "cannot open or read" "$T/ri3.err"
printf 'not a mach-o at all, not even close\n' >"$T/ri_text"
"$MACHOTOOL" edit "$T/ri_text" "$T/ri.out" "$T/ri.edits" >/dev/null 2>"$T/ri4.err" || :
ri_neither "not a readable 64-bit Mach-O" "$T/ri4.err"

# Everything that got as far as an image names both. A fat64 container is
# refused by its magic before mi_open, and still names both -- four bytes of
# FAT_MAGIC_64 is the whole fixture, as cli_test.sh:1397 already does it.
printf '%b' '\0277\0272\0376\0312' > "$T/ri_fat64"
rm -f "$T/ri.out"
"$MACHOTOOL" edit "$T/ri_fat64" "$T/ri.out" "$T/ri.edits" >/dev/null 2>"$T/ri5.err" || :
ri_both "fat_arch_64 container" "$T/ri5.err"

# A statement's own refusal.
printf 'fatal-warnings\nload-command delete uuid\n' >"$T/ri_fw.edits"
"$MACHOTOOL" lc "$T/ri_in" "$T/ri_nouuid" -delete uuid >/dev/null 2>&1
rm -f "$T/ri.out"
"$MACHOTOOL" edit "$T/ri_nouuid" "$T/ri.out" "$T/ri_fw.edits" >/dev/null 2>"$T/ri6.err" || :
ri_both "a statement that matched nothing under fatal-warnings" "$T/ri6.err"
[ ! -e "$T/ri.out" ] \
    && ok "refusal inventory: and every one of them wrote no OUT" \
    || bad "refusal inventory" "OUT exists after a refusal"

# An arch directive naming a slice a thin file does not have.
printf 'arch arm64\nload-command delete uuid\n' >"$T/ri_arch.edits"
rm -f "$T/ri.out"
"$MACHOTOOL" edit "$T/ri_in" "$T/ri.out" "$T/ri_arch.edits" >/dev/null 2>"$T/ri7.err" || :
ri_both "an arch directive the file cannot satisfy" "$T/ri7.err"
```

No fat64 builder is needed: `tests/cli_test.sh:1391-1397` already makes one from four bytes of `FAT_MAGIC_64`, and the refusal fires on the magic alone, before `mi_open`. Use that idiom rather than inventing a fixture.

- [ ] **Step 2: Run it and watch which assertions fail**

```bash
sh tests/cli_test.sh $B 2>&1 | grep 'refusal inventory'
```

Expected: the `ri_both`/`ri_neither` helpers are new, so every line reports. Any `FAIL` here is a real finding about the code, **not** about the test — `src/edit.h`'s own inventory has been wrong twice, so a failure means the third version of the claim is also wrong. Report what you find before changing either side.

- [ ] **Step 3: Make every assertion pass, changing tests only**

If an assertion fails, the truth is whatever the code does; adjust the assertion to pin reality and **say so in the report**, naming the refusal and what it actually prints. Do not change `src/edit.c` — behaviour changes are out of scope for this plan.

- [ ] **Step 4: Mutation-check**

Make `me_say_left` (`src/edit.c:64-66`) print only `"%s not written\n"`, dropping the `left unmodified` half. Rebuild. Every `ri_both` assertion must fail and every `ri_neither` must still pass. Revert, rebuild, confirm all pass again. Record both counts.

- [ ] **Step 5: Delete the paragraph**

Replace `src/edit.h:139-153` — the whole inventory, from "REPORT, to o->log." through "an allocation failure once PATH has resolved into an image." — with:

```c
 * REPORT, to o->log. A refusal that has read the image names both files and
 * what became of each; one that never got that far says only what it can.
 * tests/cli_test.sh's "refusal inventory" block is the enumeration.
```

- [ ] **Step 6: Run everything and commit**

```bash
cmake --build $B && ctest --test-dir $B
sh tests/characterize.sh $B check
sh tests/cli_test.sh $B; sh tests/wrapper_test.sh $B; sh tests/translate_test.sh $B
sh tests/known-callers.sh $B; sh tests/change_dylib_test.sh $B; sh tests/leaf-tool-crashes.sh $B
git add tests/cli_test.sh src/edit.h
git commit -m "test: pin which refusals name both files, and stop describing it"
```

---

### Task 2: The rest of `src/edit.h`

290 comment lines for one function declaration. Task 1 removed the paragraph that kept going wrong; this removes the rest of what tests already hold.

**Files:**
- Modify: `src/edit.h` — target **≤ 60** comment lines

**Interfaces:**
- Consumes: Task 1's `refusal inventory` block, cited by the surviving REPORT sentence.
- Produces: nothing new. `me_run`'s declaration is unchanged.

- [ ] **Step 1: Record the starting measurement**

```bash
awk 'END{print NR" lines"} /^[ \t]*(\/\*|\*|\/\/)/{c++} END{print c" comment"}' src/edit.h
```

Save it for the report; Step 5 compares against it.

- [ ] **Step 2: Delete what tests already hold (bucket 2)**

Each of these passages restates something a suite pins. Delete the prose; do **not** add a citation for each (a comment pointing at a test is still a comment that can rot — the test is the record):

- `:8-12` "if any statement is refused … NOTHING is written" — pinned across nine verbs by `cli_test.sh`'s never-writes-input assertions.
- `:41-43` OUT required, may not be PATH, symlink/hard link caught — `tests/atomic_write_test.c` plus `cli_test.sh`'s five-shape refusals.
- `:52-70` FAT FILES, every claim — `cli_test.sh`'s fat `edit` block and `tests/fat_test.c`.
- `:75-80` VERIFY, including `MACHO_NO_VERIFY` not being consulted — `cli_test.sh` pins it.
- `:82-87` WRITE, `wa_write_new`'s behaviour — `tests/atomic_write_test.c`.
- `:89-94` ORDER, the insert reversal — `cli_test.sh`'s insert-order assertions and `translate_test.sh`.
- `:96-134` TARGET, all five detections, position-dependence, the derived-miss rule — `cli_test.sh`'s 33 `target` assertions.
- `:188-219` WHAT THE OPERATIONS PRINT THEMSELVES — 31 lines enumerating every core's stdout. This is the wrappers' contract, and `wrapper_test.sh` plus `known-callers.sh` are what hold it.
- `:255-299` DIRECTIVES, all three — `cli_test.sh` and `script_test.c`.

- [ ] **Step 3: Keep, compressed (buckets 3 and 5)**

What survives is the interface: what `me_run` does, what it returns, what it requires, and the handful of constraints a caller would otherwise violate.

Keep in one or two sentences each: the module's purpose (`:4-6`); that it lowers and sequences and performs no operation itself (`:14-18`); the return codes and that `out` is required and may not be `path` (`:35-40`); that `MR_ERROR` is not an exit code (`:45-46`); Task 1's REPORT sentence; and the FOLLOW-UPS list (`:221-253`) reduced to one sentence saying a statement logs the work it did beyond what it names, with the `target` expansion example kept — that example is the only part of it a reader cannot reconstruct.

Delete the "THERE IS NO QUIET MODE" rationale at `:24-29`, keeping only what the field means: `log` is where the report goes, stderr when NULL.

- [ ] **Step 4: Check the safety rule held**

```bash
git diff src/edit.h | grep '^-' | grep -iE 'refus|never|must|only|deliberat|not consulted'
```

Read every hit. For each, confirm a test holds it or a surviving sentence states it. Any line with neither is a safety-rule violation: restore a one-line form. **List what you checked in the report** — this step is the plan's whole safeguard, and "I checked" without the list is not evidence.

- [ ] **Step 5: Measure, run everything, commit**

```bash
awk 'END{print NR" lines"} /^[ \t]*(\/\*|\*|\/\/)/{c++} END{print c" comment"}' src/edit.h
cmake --build $B && ctest --test-dir $B && sh tests/characterize.sh $B check
sh tests/cli_test.sh $B; sh tests/wrapper_test.sh $B; sh tests/translate_test.sh $B
sh tests/known-callers.sh $B; sh tests/change_dylib_test.sh $B; sh tests/leaf-tool-crashes.sh $B
git add src/edit.h
git commit -m "docs(edit): the header documents the interface; the tests hold the behaviour"
```

Report both measurements. If the result is above 60 comment lines, say which passages you judged un-deletable and why.

---

### Task 3: `compat/fix_macho.sh`

284 lines, of which **20** do anything, with the first line of code at 251. The prose is five deliberate divergences, an exit-code account, an in-place-edit account, and a history section.

**Files:**
- Modify: `compat/fix_macho.sh` — target **≤ 35** comment lines
- Modify: `compat/README.md` — receives the divergence table and the MEASURED transcript
- Modify: `tests/cli_test.sh` or `tests/wrapper_test.sh` — a test for any divergence not already held

**Interfaces:**
- Consumes: nothing.
- Produces: a divergence table in `compat/README.md` that Task 4 extends.

- [ ] **Step 1: Enumerate the divergences and find their tests**

```bash
sed -n '44,197p' compat/fix_macho.sh
grep -n 'fix_macho' tests/wrapper_test.sh tests/known-callers.sh tests/translate_test.sh
```

For each of the five adopted divergences and the two "not on the adopted list", write down which assertion holds it. `compat/fix_macho.sh:178` already says `tests/wrapper_test.sh` is what reads the two quoted stdout lines, so at least that one is held.

- [ ] **Step 2: Write tests for any divergence nothing holds**

A divergence is a behaviour claim. If Step 1 found no assertion for one, write it now, in the idiom of the `fix_macho` assertions already in `tests/wrapper_test.sh`. Name it for the divergence so a future reader finds it from the behaviour:

```sh
# fix_macho divergence: every nonzero exit becomes 1, unlike the C tool's
# spread of codes. The wrapper folds mw_run_to_tmp's status deliberately.
cp "$FIXTURE" "$T/fmx"; chmod 0444 "$T/fmx"
rc=0; "$BIN/fix_macho" "$T/fmx" -change /nope /also-nope >/dev/null 2>"$T/fmx.err" || rc=$?
[ "$rc" -eq 1 ] \
    && ok "fix_macho: a refusal exits 1, not machotool's own code" \
    || bad "fix_macho exit fold" "rc $rc: $(cat "$T/fmx.err")"
chmod 0644 "$T/fmx"
```

- [ ] **Step 3: Mutation-check every test you added**

For the example above: change `compat/fix_macho.sh:276` from `exit 1` to `exit "$mw_frc"`, run `wrapper_test.sh`, watch that assertion fail, revert. Do this for each new assertion and record the counts. **Take the record after the last assertion exists**, not as you go.

- [ ] **Step 4: Move the divergence table to `compat/README.md`**

`compat/README.md` already carries a divergence list and an exception list — extend those rather than starting a new section. Move the five adopted divergences and the two unadopted ones there as table rows, each naming the test that holds it. Move the MEASURED transcript (`:154-179`, the `macho9:`-prefixed sample and its dated note) there verbatim — it is a record of a measurement, so it moves rather than dies, and **its `macho9:` text stays exactly as measured**.

- [ ] **Step 5: Reduce the wrapper to what a reader needs at the point of danger**

Keep: one sentence on what this wrapper is and that `compat/translate.sh` holds the grammar; one sentence pointing at `compat/README.md` for the divergences; and the support-file check's explanation (`:252-254`) — a symlink on `PATH` resolving to the symlink's directory is exactly the non-obvious hazard bucket 3 exists for. Delete: WHAT THIS REPLACED, the capacity-caps account (the caps live in `translate.sh` and `translate_test.sh` holds them), the exit-code essay, and the in-place-edit account (every claim in it is held by `wrapper_test.sh`'s hard-link, unwritable and symlink assertions).

- [ ] **Step 6: Verify the wrapper still behaves identically, then commit**

```bash
sh /Users/schmonz/Documents/code/trees/mavericks-shipyard-readme-gate/scripts/check-shell-portability.sh .
sh -n compat/fix_macho.sh && /bin/ksh -n compat/fix_macho.sh
sh tests/wrapper_test.sh $B; sh tests/known-callers.sh $B; sh tests/translate_test.sh $B
sh tests/characterize.sh $B check; sh tests/change_dylib_test.sh $B
awk 'END{print NR" lines"} /^[ \t]*#/{c++} END{print c" comment"}' compat/fix_macho.sh
git add compat/fix_macho.sh compat/README.md tests/wrapper_test.sh
git commit -m "docs(fix_macho): the divergences live in compat/README.md, held by tests"
```

A comment-only change to a wrapper must move no byte of its stdout. If `known-callers.sh`'s sha256s move, stop.

---

### Task 4: `compat/change_dylib.sh`

221 lines, 196 comment, 20 lines of code. Same treatment as Task 3, against the table Task 3 created.

**Files:**
- Modify: `compat/change_dylib.sh` — target **≤ 35** comment lines
- Modify: `compat/README.md` — extend the divergence table
- Modify: `tests/wrapper_test.sh` — tests for any unheld claim

**Interfaces:**
- Consumes: the divergence table in `compat/README.md` from Task 3.

- [ ] **Step 1: Enumerate and find the tests**

```bash
grep -nE '^# [A-Z]' compat/change_dylib.sh
grep -n 'change_dylib' tests/wrapper_test.sh tests/known-callers.sh tests/change_dylib_test.sh
```

`change_dylib` is the most heavily tested wrapper in the repo — `tests/change_dylib_test.sh` exists for it alone — so expect most claims to be bucket 2.

- [ ] **Step 2: Write tests for anything unheld, and mutation-check them**

Same idiom and same discipline as Task 3 Steps 2–3: name each test for the behaviour, break the behaviour, watch the named test fail, revert, record after the last assertion exists.

- [ ] **Step 3: Move divergences to `compat/README.md`, reduce the wrapper**

Keep one sentence on what it is, one pointing at the grammar in `translate.sh`, one pointing at `compat/README.md`, and the support-file check's hazard note. Everything else goes.

Note the unwritable-FILE guard: if any comment still explains why it exits 2 rather than 1, that is a constraint — `wrapper_test.sh` holds it, so the prose goes, but **confirm the assertion exists before deleting the explanation.**

- [ ] **Step 4: Run everything and commit**

```bash
sh /Users/schmonz/Documents/code/trees/mavericks-shipyard-readme-gate/scripts/check-shell-portability.sh .
sh -n compat/change_dylib.sh && /bin/ksh -n compat/change_dylib.sh
sh tests/change_dylib_test.sh $B; sh tests/wrapper_test.sh $B; sh tests/known-callers.sh $B
sh tests/translate_test.sh $B; sh tests/characterize.sh $B check
git add compat/change_dylib.sh compat/README.md tests/wrapper_test.sh
git commit -m "docs(change_dylib): the divergences live in compat/README.md, held by tests"
```

---

### Task 5: `src/rewrite.h`

425 lines, 359 comment. Mostly rationale, and some of it is load-bearing in a way `edit.h`'s was not — the `MR_FAIL`/`MR_REFUSED` dividing line is the contract every caller reasons about.

**Files:**
- Modify: `src/rewrite.h` — target **≤ 90** comment lines
- Modify: `tests/cli_test.sh` — a test for the dividing line, if none holds it

**Interfaces:**
- Produces: nothing new.

- [ ] **Step 1: Find whether the exit-code dividing line is tested**

```bash
grep -nE 'MR_FAIL|MR_REFUSED|rc.*-eq 2|rc.*-eq 1' tests/cli_test.sh | head -20
```

The rule is: `MR_FAIL` (2) for an operational failure — a syscall, a malloc — and `MR_REFUSED` (1) for anything that examined the bytes and declined. If no test pins both sides, write one:

```sh
# The dividing line rewrite.h draws: 2 means the tool could not do its job,
# 1 means it looked and declined. A reader can only trust that if something
# checks both sides of it.
rc=0; "$MACHOTOOL" dylib "$T/nosuchfile" "$T/dl.out" -append /x >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "exit codes: an unopenable input is operational failure (2)" \
                || bad "exit codes" "unopenable input gave $rc, want 2"
printf 'this is not a mach-o\n' >"$T/dl_text"
rc=0; "$MACHOTOOL" dylib "$T/dl_text" "$T/dl.out" -append /x >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok "exit codes: bytes examined and declined is refusal (1)" \
                || bad "exit codes" "non-Mach-O gave $rc, want 1"
```

- [ ] **Step 2: Mutation-check it**

In `src/rewrite.c`'s `mr_apply_file`, change the `too small to be a Mach-O` return from `MR_REFUSED` to `MR_FAIL`. The second assertion must fail and the first must still pass. Revert. Record.

- [ ] **Step 3: Keep the constraints, delete the essays**

Keep, compressed: the `MR_FAIL`/`MR_REFUSED` dividing line as a two-line rule citing the test; `mr_apply_file`'s signature contract (`path` is read, `out` is written, `out` may not be `path`); the **unenforced precondition** that `ops`'s arrays respect `MR_MAX_OPS`/`MR_MAX_STRIP` — that is a constraint a caller can violate with no diagnostic, so it is bucket 3 and stays; and the disclosure that three `calloc`s go unchecked, which stays until the defect is fixed elsewhere.

Delete: the historical account of what `change_dylib.c` did, the rationale for why the fd is opened up front (the code says `O_RDONLY` and a one-line comment suffices), and the long explanations of `mr_process_fat`'s slice loop now that `mfat_rewrite` owns the layout.

- [ ] **Step 4: Check the safety rule held**

```bash
git diff src/rewrite.h | grep '^-' | grep -iE 'must|never|only|precondition|unchecked|refus|deliberat'
```

Read every hit; confirm a test or a surviving sentence holds it. List what you checked in the report.

- [ ] **Step 5: Run everything and commit**

```bash
cmake --build $B && ctest --test-dir $B && sh tests/characterize.sh $B check
sh tests/cli_test.sh $B; sh tests/wrapper_test.sh $B; sh tests/change_dylib_test.sh $B
sh tests/known-callers.sh $B; sh tests/translate_test.sh $B; sh tests/leaf-tool-crashes.sh $B
awk 'END{print NR" lines"} /^[ \t]*(\/\*|\*|\/\/)/{c++} END{print c" comment"}' src/rewrite.h
git add src/rewrite.h tests/cli_test.sh
git commit -m "docs(rewrite): keep the contract and the constraints, drop the history"
```

---

### Task 6: Measure, and decide about the rest

The spec scopes this plan to the worst offenders and says the remainder is decided after the approach has proven itself. This task produces that decision with numbers rather than a feeling.

**Files:**
- Modify: `docs/superpowers/QUEUE.md` — record the result and the recommendation

- [ ] **Step 1: Measure the whole tree, before and after**

```bash
awk 'FNR==1{f=FILENAME} {t[f]++} /^[ \t]*(\/\*|\*|\/\/|#)/{c[f]++} \
  END{for(x in t){TL+=t[x];TC+=c[x]; if(t[x]>200) printf "%-28s %6d %7d %4d%%\n",x,t[x],c[x],c[x]*100/t[x]}; \
  printf "%-28s %6d %7d %4d%%\n","TOTAL",TL,TC,TC*100/TL}' \
  src/*.c src/*.h cli/*.c compat/*.sh | sort -k4 -rn
```

Compare against the spec's table. Report the four swept files' before/after and the new tree total.

- [ ] **Step 2: Count what the sweep bought in tests**

```bash
git diff --stat 2026-09-12-narration-start..HEAD -- tests/
sh tests/cli_test.sh $B | tail -1; sh tests/wrapper_test.sh $B | tail -1
```

Report how many assertions were added, and how many of them were mutation-proven. The ratio of new tests to deleted comment lines is the number that says whether "convert to tests" was real or whether this was mostly deletion.

- [ ] **Step 3: Write the recommendation into the queue**

Add a "Carried out of the narration sweep" section to `docs/superpowers/QUEUE.md` stating: the measured before/after, which passages resisted conversion and why, whether `src/rewrite.c` (53%), `cli/machotool.c` (52%) and `src/grow.h` (64%) warrant a second plan, and any claim the sweep found to be **false** rather than merely verbose — that last category has appeared in every item this week and is the most valuable thing a pass like this produces.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/QUEUE.md
git commit -m "docs: what the narration sweep measured, and what is left"
```

---

## Self-review

**Spec coverage.** Five buckets → Tasks 1–5 apply them per file, with the bucket named for each passage group. The safety rule → an explicit check step in Tasks 2, 4 and 5, each requiring the list of what was checked rather than an assertion that it was. Mutation-checking every new test → Task 1 Step 4, Task 3 Step 3, Task 4 Step 2, Task 5 Step 2, with the "record after the last assertion" rule stated in the Global Constraints and repeated in Task 3. Worst-first, one file per commit → the file-structure table, and one commit per task. Scoped to the worst offenders with the remainder decided later → Task 6. The MEASURED transcript moving rather than dying → Task 3 Step 4, including that its `macho9:` text stays as measured. Not touching `README.md`, the frozen matrix, completed plans, or the unchecked `calloc`s → Global Constraints.

**One gap I am leaving deliberately.** `src/grow.h` (64%) is in the spec's table but gets no task of its own; Task 6 decides it with the other two `.c` files. Adding a fifth sweep task before the method has been tried on four files would be planning past the evidence.

**Placeholder scan.** Every code step carries the actual test or the actual replacement text. Task 1 Step 1 names a `$MKFAT64` that may not exist and says what to do if it does not, rather than assuming. Tasks 3 and 4 cannot list every passage's test in advance — which assertion holds which divergence is a fact about the tree that Step 1 of each task establishes by grepping — so those steps specify the enumeration and the idiom, with a worked example each, instead of pretending to know the answer.

**Type consistency.** No new C interfaces. The shell helpers `ri_both`/`ri_neither` are defined in Task 1 and used only there. `$MACHOTOOL`, `$BIN`, `$FIXTURE`, `$T`, `ok`, `bad` and `build_main` are the existing idioms in `tests/cli_test.sh` and `tests/wrapper_test.sh`; each new block uses the ones native to the file it goes in.
