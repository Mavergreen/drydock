# The Script Is The Only Interface — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `machotool` becomes `machorewrite`, loses its CLI of verbs, and modifies a binary only through a script on stdin — which lets the multi-operation machinery in `src/rewrite.c` be deleted outright.

**Architecture:** Seven mutating verbs already have exact statement equivalents, so they are subtraction. The bare form `machorewrite FILE OUT` reads statements from stdin. `verify` and `info` survive as read-only verbs. `grow` is deleted and its crash coverage moves into `tests/grow_test.c`. With no `mr_ops` holding more than one operation, `mr_is_deleted`, both `No break` loops, `mr_report_unmatched`'s shadowing logic and the `MR_MAX_OPS`/`MR_MAX_STRIP` hit arrays all go.

**Tech Stack:** C99, stock 10.9 AppleClang 6.0, CMake + ctest, POSIX `/bin/sh`.

**Spec:** `docs/superpowers/specs/2026-09-14-script-is-the-only-interface-design.md`

## Global Constraints

- **Emitted bytes never change.** `sh tests/characterize.sh $B` must keep printing `ad12bdd780da4131f81a808e6d08b688e2034f37e434772f81df023332b39792`. Measured, with a correction worth carrying: `characterize.sh:24`'s `-strip-lc uuid -strip-lc codesig` is **effectively one operation**, because no fixture here has an `LC_CODE_SIGNATURE` and `lc -delete codesig` is a no-op on `tests/fixture.macho`. The genuine two-operation agreement is `uuid` + `source-version`, both really present and each really removed. A moved digest is a real defect.
- **`tests/known-callers.sh`'s 18 sha256s are converted-file digests, never edited.** If one moves, **stop and report** — that is a behaviour change beyond the one this plan authorises.
- **Zero behaviour changes, corrected 2026-09-14 — the one this plan authorised turns out to be avoidable, and `translate.sh` already knew how.** Its multi-family path (`:524-545`) documents that a verb applies a family's operations as a batch against the ORIGINAL image while a script applies them in SEQUENCE, and that **they agree when the statements are emitted in a specific order**: every `load-command delete` first, then per family every delete and reexport, then replaces, then appends, then inserts **in reverse flag order**. Measured: `dylib delete P` followed by `dylib replace P Q` produces output **byte-identical** to the verb's `-replace P Q -delete P`, because the delete runs first and the replace then finds nothing — reproducing `mr_is_deleted`'s precedence by ordering rather than by a precedence rule.

  So Task 3 applies that existing bucketing to the single-family case too, and **nothing about which invocations succeed or fail may move, including the same-path case.** If any invocation's outcome does move, that is a finding — stop and report.

  One shape genuinely has no reproducing order: a `-change` whose NEW is another `-change`'s OLD. `mt_chain_check` already refuses it, and must keep refusing it.
- **Wrapper *text* may change; wrapper *outcomes* may not.** The repo owner ruled 2026-09-13: *"the wrappers won't live long. our machotool code will."*
- **A verb is deleted only after its script form is proven byte-identical** on a real fixture. No verb goes on the strength of the table in the spec.
- **`verify` and `info` keep their current output exactly.**
- POSIX `/bin/sh` only in `compat/*.sh` and tests: no `[[`, `local`, `+=`, arrays, `<<<`, `$'...'`, `function`, `source`.
- C99, `-Wall -Wextra`, warning-free. **Count compiler warnings with `^[^ ]+\.[ch]:[0-9]+:[0-9]+: warning:`** — a bare `grep -c 'warning:'` catches gmake clock-skew noise.
- **Pass every suite an ABSOLUTE build dir.** `tests/cli_test.sh` accepts a relative one and then silently fails 11 assertions.
- **A grep is evidence only once you have seen it return a hit on a case you know exists.** State a negative only after a positive control. Five false claims in the previous two items came from empty greps — a backtick, backticks around an identifier, `exit [0-9]` missing `exit "$mw_rc"`, `grep -c` counting the comment that stated the count, and a phrase spanning a line break.
- **A mutation that does not compile is not a caught mutation, it is an invalid experiment.** Confirm the mutant builds, then watch the named test fail.
- **A "dead branch" is a claim about reachability and can be false.** Exercise it at the parent commit rather than reading it.
- **Check CI after each push**: `gh run list --repo Mavergreen/macho-tools --limit 3`. The `conventions` job is expected red on a pre-existing `release-notes.sh` rule belonging to item 4; the `release` job's `build` must be green. Item 6 shipped a test that was red on `main` for a day because it could not fail on the architecture it was written on.
- **Line-number citations into files this plan edits go stale as the plan proceeds.** Regenerate them from the tree at dispatch time; do not copy them forward. This bit the previous item twice.

## File structure

| file | change |
|---|---|
| `cli/machotool.c` → `cli/machorewrite.c` | verb dispatch (`:1327-1381`) collapses to: `--capabilities`, `verify`, `info`, and the bare `FILE OUT` form. `cmd_grow`, `cmd_minos`, `cmd_segment`, `cmd_retag_swift`, `cmd_lc`, `cmd_dylib_or_rpath`, `cmd_declassify` all go. |
| `src/rewrite.h` | `MR_MAX_OPS` (`:90`), `MR_MAX_STRIP` (`:91`), the three hit arrays (`:143-145`) and the array-bound precondition go; `mr_ops` collapses to one operation. |
| `src/rewrite.c` | `mr_is_deleted` (`:56`), both `No break` loops (`:141`, `:248`), `mr_report_unmatched` (`:1119`) simplify or go. |
| `compat/translate.sh` | seven emitters rewritten to the bare form: `mt_tr_change_dylib` (`:383`), `mt_tr_fix_macho` (`:563`), `mt_tr_add_version_min` (`:710`), `mt_tr_patch_macho` (`:719`), `mt_tr_rename_segment` (`:741`), `mt_tr_retag_swift_classes` (`:749`), and `mt_pre_word` (`:767`). |
| `tests/grow_test.c` | receives the two crash cases from `leaf-tool-crashes.sh`; already calls `mg_grow_header` directly at `:509`. |
| `tests/leaf-tool-crashes.sh` | loses its `grow` cases (`:362`, `:374`). |
| `CMakeLists.txt`, all tests, `README.md`, `compat/README.md` | the rename. |

---

### Task 1: The bare form, alongside the verbs

Add `machotool FILE OUT` reading statements from stdin. **Change no verb and delete nothing** — this task only adds the form everything else will migrate onto, so that migration and deletion are separately reviewable.

**Files:**
- Modify: `cli/machotool.c` — `main`'s dispatch
- Modify: `tests/cli_test.sh`

**Interfaces:**
- Produces: `machotool FILE OUT` with a script on stdin, exit codes identical to `machotool edit FILE OUT -`.

- [ ] **Step 1: Find the dispatch and the existing stdin path**

```bash
grep -n 'strcmp(verb,' cli/machotool.c
grep -n 'cmd_edit' cli/machotool.c
```

`machotool edit FILE OUT -` already reads stdin and works — verify that before building on it:

```bash
B=/Users/schmonz/Documents/code/trees/mavericks-macho-tools/build-native
printf 'load-command delete uuid\n' | "$B/machotool" edit "$B/machotool" /tmp/o1 -
```

- [ ] **Step 2: Add the bare form**

In `main`, after the `--capabilities`, `verify` and `info` checks and before the verb chain: if `argc == 3` and `argv[1]` is not a known verb, treat it as `FILE OUT` and run the `edit` path with the script read from stdin. Keep `edit` working unchanged.

- [ ] **Step 3: Prove it is the same thing**

```sh
# The bare form is `edit FILE OUT -` with the verb word dropped. Same script,
# same bytes, same exit -- if these ever diverge, one of two spellings of one
# operation has grown a second behaviour, which is the whole defect this item
# exists to remove.
printf 'load-command delete uuid\n' >"$T/bare.edits"
"$MACHOTOOL" edit "$T/in" "$T/via_edit" "$T/bare.edits" >/dev/null 2>&1; ve=$?
"$MACHOTOOL" "$T/in" "$T/via_bare" <"$T/bare.edits" >/dev/null 2>&1; vb=$?
[ "$ve" -eq "$vb" ] && cmp -s "$T/via_edit" "$T/via_bare" \
    && ok "bare form: FILE OUT with stdin is edit FILE OUT - with the word dropped" \
    || bad "bare form" "edit exit $ve vs bare exit $vb; bytes $(cmp -s "$T/via_edit" "$T/via_bare" && echo same || echo DIFFER)"
```

- [ ] **Step 4: Mutation-check**

Make the bare form ignore stdin (read an empty script). Confirm the mutant **builds**, watch the assertion fail, revert, confirm `git diff cli/machotool.c` is empty.

- [ ] **Step 5: Commit**

```bash
git add cli/machotool.c tests/cli_test.sh
git commit -F <(printf 'feat: a bare FILE OUT form, reading statements from stdin\n\n...\n')
```

---

### Task 2: Prove every verb's script equivalence

**This task deletes nothing.** It is the gate: a verb may be removed in Task 4 only if this task proved its script form produces byte-identical output. Seven verbs, on real fixtures.

**Files:**
- Create: `tests/verb_script_equivalence.sh`
- Modify: `CMakeLists.txt`

**Interfaces:**
- Produces: a suite that fails if any verb and its statement disagree. Task 4 deletes the verbs; Task 5 deletes this suite with them, the way Task 4 of the previous item deleted the differential harness with its subject.

- [ ] **Step 1: One case per verb**

For each pair below, run both forms on the same input and compare **bytes and exit code**:

| verb form | script form |
|---|---|
| `declassify IN OUT` | `fixups set classic` |
| `segment IN OUT __DATA __DATA_R9` | `segment rename __DATA __DATA_R9` |
| `retag-swift IN OUT` | `swift-abi set legacy` |
| `minos IN OUT 10.9` | `version-min set 10.9` |
| `lc IN OUT -delete uuid` | `load-command delete uuid` |
| `dylib IN OUT -append /tmp/x.dylib` | `dylib append /tmp/x.dylib` |
| `rpath IN OUT -append /tmp/r` | `rpath append /tmp/r` |

Use a fixture each verb actually changes — a verb that no-ops proves nothing. `tests/cli_test.sh`'s `build_main` and `tests/mkimplausible.c` are the existing fixture idioms.

- [ ] **Step 2: The multi-operation cases, which are the interesting ones**

Non-overlapping operations agree (measured); same-path ones do not. Assert **both**, so the one authorised divergence is pinned rather than discovered:

```sh
# Non-overlapping: one pass and two statements must agree. If they ever stop
# agreeing, migrating the wrappers silently changes what users' binaries become.
"$MACHOTOOL" lc "$T/in" "$T/multi_verb" -delete uuid -delete codesig >/dev/null 2>&1
printf 'load-command delete uuid\nload-command delete codesig\n' >"$T/multi.edits"
"$MACHOTOOL" "$T/in" "$T/multi_script" <"$T/multi.edits" >/dev/null 2>&1
cmp -s "$T/multi_verb" "$T/multi_script" \
    && ok "equivalence: two non-overlapping ops agree as a set and as a sequence" \
    || bad "equivalence: multi-op" "one pass and two statements produced different files"
```

- [ ] **Step 3: Pin the one divergence, before it changes**

```sh
# THE authorised behaviour change, asserted here in its BEFORE state so Task 5
# has to update it deliberately. Set semantics: -delete beats a conflicting
# -replace for the same path, whatever the order (mr_is_deleted). Sequence
# semantics: the replace happens, then the delete matches nothing.
"$MACHOTOOL" dylib "$T/conf_in" "$T/conf_verb" -replace "$P" /also/absent.dylib -delete "$P" >/dev/null 2>&1
printf 'dylib replace %s /also/absent.dylib\ndylib delete %s\n' "$P" "$P" >"$T/conf.edits"
"$MACHOTOOL" "$T/conf_in" "$T/conf_script" <"$T/conf.edits" >/dev/null 2>&1
"$MACHOTOOL" info "$T/conf_verb"   | grep -q 'also/absent' && vk=kept || vk=deleted
"$MACHOTOOL" info "$T/conf_script" | grep -q 'also/absent' && sk=kept || sk=deleted
[ "$vk" = deleted ] && [ "$sk" = kept ] \
    && ok "equivalence: same-path replace+delete -- the verb deletes, the script renames" \
    || bad "equivalence: same-path" "expected verb=deleted script=kept, got verb=$vk script=$sk"
```

- [ ] **Step 4: Run, register in CMake, commit**

Every pair must pass except the pinned divergence. **A pair that fails is a finding, not a row to adjust until it goes green** — report it and stop.

---

### Task 3: The wrappers emit the bare form

**Files:**
- Modify: `compat/translate.sh` — `mt_tr_change_dylib`, `mt_tr_fix_macho`, `mt_tr_add_version_min`, `mt_tr_patch_macho`, `mt_tr_rename_segment`, `mt_tr_retag_swift_classes`, `mt_pre_word`
- Modify: `tests/translate_test.sh`, `tests/wrapper_test.sh`

- [ ] **Step 1: Change what the emitters build**

Each emitter prints the equivalent command as a deprecation notice **and** the wrapper runs it. Both change shape. From:

```
    machotool dylib f f.new -replace /a /b
    mv -f f.new f
```

to:

```
    printf 'dylib replace /a /b\n' | machorewrite f f.new
    mv -f f.new f
```

Regenerate the line numbers before editing — `translate.sh` is 809 lines and this plan's citations will have drifted.

- [ ] **Step 2: Multi-operation invocations become multi-statement scripts**

`mt_tr_change_dylib` accumulates several old-grammar flags into one invocation. Each becomes one statement, **in the order the flags appeared**. That is the one authorised behaviour change; Task 5 updates the assertion Task 2 pinned.

- [ ] **Step 3: Outcomes must not move**

```bash
B=/Users/schmonz/Documents/code/trees/mavericks-macho-tools/build-native
sh tests/known-callers.sh "$B"     # 18, NO sha256 may move -- stop if one does
sh tests/characterize.sh "$B"      # the digest
sh tests/wrapper_test.sh "$B" | grep -c '^PASS '
```

Wrapper *text* changes, so `wrapper_test.sh` and `translate_test.sh` expectations move. Say which and why. `known-callers.sh`'s digests are file bytes and must not.

---

### Task 4: Delete the seven verbs, collapse `--capabilities`

Gated on Task 2 passing.

**Files:**
- Modify: `cli/machotool.c` — the dispatch and `cmd_minos`, `cmd_segment`, `cmd_retag_swift`, `cmd_lc`, `cmd_dylib_or_rpath`, `cmd_declassify`
- Modify: `tests/cli_test.sh`, `tests/change_dylib_test.sh`
- Delete: `tests/verb_script_equivalence.sh` and its CMake block — **moved here from Task 5 by the pre-flight scan.** That suite invokes the verbs; deleting them without it leaves a suite calling functions that no longer exist. It goes with its subject, in the same commit, the way the previous item's differential harness went with the predicate it licensed.

- [ ] **Step 1: Delete the dispatch arms and the `cmd_*` bodies**

Keep `verify`, `info`, `--capabilities`, and the bare form. Delete the rest. Then confirm with a positive control that each is really gone:

```bash
git grep -c 'cmd_dylib_or_rpath\|cmd_declassify\|cmd_minos' -- src/ cli/   # expect 0
git grep -c 'cmd_verify' -- cli/                                            # control: nonzero
```

- [ ] **Step 2: `--capabilities` loses its verb list**

The `verb dylib ops=...` lines go; the `statement ...` lines stay. `verify`, `info` and the bare form are what remains to advertise. Diff the output before and after and put both in the report — this is a deliberate, visible change.

- [ ] **Step 3: Migrate every test that invokes a deleted verb**

`tests/cli_test.sh` is the bulk. **Do not delete an assertion to get green**: each one tests a property, and the property survives the verb. Move it to the script form, keeping its FAIL message.

---

### Task 5: Delete the multi-operation machinery

**This is the payoff.** With no `mr_ops` holding more than one operation, the conflict code has nothing to resolve.

**Files:**
- Modify: `src/rewrite.h` — `MR_MAX_OPS`, `MR_MAX_STRIP`, `mr_hits`, `mr_ops`
- Modify: `src/rewrite.c` — `mr_is_deleted`, both `No break` loops, `mr_report_unmatched`
- Modify: `tests/change_dylib_test.sh` — its historical-bug regression case

- [ ] **Step 1: Collapse `mr_ops` to one operation**

`int dylib[MR_MAX_OPS]`, `rpath[MR_MAX_OPS]`, `strip[MR_MAX_STRIP]` become single values. The `n_*` counts become 0-or-1. The "too many operations" refusals those caps generate go with them.

- [ ] **Step 2: Delete the conflict resolvers**

`mr_is_deleted` and the delete-wins rule; both `No break` loops; `mr_report_unmatched`'s matched-versus-acted distinction. Each exists only because two operations could name one load command.

- [ ] **Step 3: Update the pinned divergence, deliberately**

Task 2 asserted the verb deletes and the script renames. The verb is gone; the script's behaviour is now the only behaviour. Rewrite that assertion to state it, and rewrite `change_dylib_test.sh`'s historical-bug regression case — which tested machinery that no longer exists.

**Delete it only with its subject.** Its purpose was proving one operation could not silently shadow another's match report; if any part of that property survives the collapse, it keeps a test.

- [ ] **Step 4: Mutation-check the collapse**

A script that renames and then deletes the old name must produce the **rename**. Break that — make the delete win — and confirm the named test fails. Confirm the mutant builds first.

- [ ] **Step 5: Report the size of the deletion**

`git diff --stat` for `src/rewrite.{c,h}`. The spec claims 18 sites; report what actually went.

---

### Task 6: Delete `grow`, move its crash coverage

**Files:**
- Modify: `cli/machotool.c` — `cmd_grow` and its dispatch arm
- Modify: `tests/grow_test.c` — receives both cases
- Modify: `tests/leaf-tool-crashes.sh` — loses them

- [ ] **Step 1: Move the SIGSEGV regression FIRST, before deleting anything**

`tests/leaf-tool-crashes.sh:374` guards a real crash: on the `oobgrow` fixture the first section's offset lies past the end of the image, `fsize - insert` underflows a `size_t`, and `macho9 grow` died of SIGSEGV (exit 139). **No script can reach it** — `mg_ensure_pad` runs only when `need_end > first_sect_off` (`src/rewrite.c:732`), which is false there, while `grow N` forces the grow.

So it becomes a hermetic C test calling `mg_grow_header` (`src/grow.h:319`) directly. `tests/grow_test.c:509` already does exactly that. Build the oobgrow-shaped image with `mkfixture`'s layout (`tests/leaf-tool-crashes.sh:181`) and assert the refusal plus every byte unchanged.

- [ ] **Step 2: Move the sectionless case** (`:362`, `"no section data bounds the header pad; refusing to grow it"`) the same way.

- [ ] **Step 3: Prove the moved tests catch what the old ones caught**

Revert the overflow guard in `mg_grow_header`, confirm the mutant **builds**, and watch the new `grow_test` case fail — with a SIGSEGV or a refusal-check failure. Revert. **If the new test does not catch it, the move failed and the verb stays.**

- [ ] **Step 4: Delete `cmd_grow` and its dispatch arm, then commit**

---

### Task 7: Rename `machotool` → `machorewrite`

Last, so every earlier task's diff is about behaviour rather than spelling.

**Files:** `cli/machotool.c` → `cli/machorewrite.c`; `CMakeLists.txt`; every test; `compat/*.sh`; `README.md`; `compat/README.md`; `tests/README.md`

- [ ] **Step 1: Rename the file and the target**

```bash
git mv cli/machotool.c cli/machorewrite.c
```

Then `CMakeLists.txt`'s target, the installed program name, and `compat/machotool-compat.sh` / `machotool-translate.sh` if the support files are renamed with it — **decide that explicitly and say which you chose**; the wrappers locate them by name.

- [ ] **Step 2: Sweep, then check the invisible direction**

A rename has a direction `grep` cannot find: a sentence that is true only because of the **old** name. Item 3 paid a fix round for this at nearly every task. After the mechanical sweep, `git diff` every prose change and ask whether it still says something true.

```bash
git grep -c 'machotool' -- . ':!docs/superpowers'   # expect 0 outside history
git grep -c 'machorewrite' -- cli/ CMakeLists.txt   # control: nonzero
```

Frozen artefacts keep the old name: `tests/compat-matrix.tsv` and `tests/EXPECTED` are dated measurements and are **never edited**.

- [ ] **Step 3: Every gate, then commit**

---

## Self-review

**Spec coverage.** Bare form → Task 1. Seven verbs' equivalence → Task 2, deletion → Task 4. `--capabilities` collapse → Task 4 Step 2. Wrapper migration → Task 3. The multi-op deletion the spec calls "the point of the design" → Task 5. `grow` deleted with its coverage moved → Task 6. The rename → Task 7. The one authorised behaviour change → pinned in Task 2 Step 3, changed in Task 5 Step 3.

**Ordering.** Equivalence precedes deletion (Task 2 before 4). Verb deletion precedes machinery deletion (4 before 5), because the verbs are the only source of a multi-operation `mr_ops`. The crash coverage moves before `grow` dies (Task 6 Step 1 before Step 4). The rename is last so no earlier diff mixes behaviour with spelling.

**Placeholder scan.** Every test step carries the actual assertion. Task 3's emitter rewrite and Task 4's test migration specify the method rather than every line, because which lines need changing is a fact about the tree at that moment — and this plan's own citations will have drifted by then, which Global Constraints says out loud.

**What I am least sure of.** Task 5's collapse of `mr_ops` is the largest single change and the one where "it still compiles and the suites pass" is weakest evidence — the conflict code's whole purpose was handling a case the suites reach rarely. Its mutation check is the real gate, not the green suite.
