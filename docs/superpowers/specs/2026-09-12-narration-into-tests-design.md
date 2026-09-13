# Narration into tests

**Status:** design, agreed 2026-09-12. The first half of queue item 6 ("human
code review + excellent documentation"). The human review is the second half and
follows this, deliberately.

## The problem

Nearly half this codebase is prose, and the density is worst exactly where a
reader starts.

| | lines | comment | % |
|---|---|---|---|
| all of `src/` + `cli/` | 11,004 | 5,032 | **45%** |
| `src/edit.h` | 304 | 290 | **95%** |
| `compat/fix_macho.sh` | 284 | 259 | **91%** |
| `compat/change_dylib.sh` | 221 | 196 | **88%** |
| `src/rewrite.h` | 425 | 359 | 84% |
| `src/grow.h` | 321 | 206 | 64% |
| `src/rewrite.c` | 1,424 | 758 | 53% |
| `cli/machotool.c` | 1,382 | 728 | 52% |

Measured 2026-09-12. `compat/fix_macho.sh` is 284 lines of which **20** do
anything, with the first line of code at 251. The repo owner's report is the
plain statement of the cost: *"my eyes glaze over attempting to skim the compat
wrappers, several screens of comments away from finding where they actually
happen."*

Two things this is **not**. It is not a style preference — a reader cannot skim a
95% header, so the prose has stopped serving the purpose prose is for. And it is
not free: the `machotool` rename paid a fix round for stale narration at nearly
every task, and one whole task was mostly classifying comments as "describes the
tool now" versus "reports what happened then". Getting that wrong is invisible
to a grep, because a substitution erases the tell.

## Why tests rather than better comments

The rename made the asymmetry measurable. Comments went stale repeatedly and
nothing caught them; every mutation thrown at the tests failed loudly. A test
named for a quirk fails when someone "fixes" the quirk. A comment describing the
quirk merely becomes wrong, and this repo's own rule — a comment that claims
more than the code does is a defect — then makes it a defect nobody can find.

Four false claims surfaced in a single later item, each one machinery that looked
like it was working: a conformance deviation that could never match, a version
wrapper that could only print the wrong shape, a `fetch-depth` comment half of
which was inert, and a notes README declaring an optional file mandatory. Every
one was caught by *running* the thing. That is the argument for this design in
one sentence: prose is unexecutable, so nothing checks it.

## Decisions, as agreed

- **Convert where possible, delete otherwise.** For each narration passage, ask
  first whether it can be a test that fails when someone breaks what it
  describes. Then delete the prose.
- **The sweep runs before the human review**, not after. The queue previously
  sequenced documentation *with* the review, reasoning that a pass afterward
  means the reviewer read a version not worth reading and a pass before means
  polishing prose the review will invalidate. That reasoning assumed polish.
  This is deletion, and removing the narration is a **precondition** for the
  review being possible: nobody can review `src/edit.h` at 95% or
  `fix_macho.sh` at 91%.
- **Worst-first, one file per commit**, so each diff is reviewable alone.
- **Scoped to the worst offenders**, not all 7,000 comment lines. The remainder
  is decided after the approach has proven itself on the hard cases.

## The five buckets

Every passage lands in exactly one. The boundaries are the whole design.

**1. Testable claim → write the test, delete the prose.** A claim about
behaviour that a test can pin. `src/grow.h`'s account of why 32-bit is refused;
`src/edit.h`'s inventory of which refusals name both files; the rule that a
refused run leaves no OUT.

**2. Already tested → delete the prose outright.** A surprising share of
narration restates something `cli_test.sh`, `wrapper_test.sh` or a C test
already pins. The test is the record; the prose is a second, rottable copy.

**3. Load-bearing at the point of danger → keep one sentence, and it must
carry a tag.** Amended 2026-09-12 to match the family convention being built in
shipyard: a surviving comment cites a reason from a **closed set of two**.

- **`platform:`** — a platform fact that bit us. *"platform: 10.9's BSD
  `mktemp` rejects a bare `-d`"*, *"platform: no `sort -V` here"*, *"platform:
  `awk -v` escape-processes its value; use `ENVIRON`"*. Most of what this
  bucket protects in this family is exactly this shape: same sentence, same
  place, one word of prefix.
- **`spec:`** — a pointer to where the decision lives.

The tag is the leading word after the comment opener, whatever the comment
syntax: `# platform: …` in shell, `/* platform: … */` in C.

**Anything else load-bearing becomes a test, and its FAIL message carries the
why** (see Testing). There is deliberately no third tag. The hardest shape —
the sentence explaining why a refusal is *deliberate* rather than
unimplemented, which is exactly what a later reader deletes while adding the
feature — converts cleanly: `machotool` refuses 32-bit input, and the test's
failure reads *"32-bit is refused on purpose; supporting it means a parallel
`LC_SEGMENT` growth path through seven places"*, firing when someone tries,
which is the only moment the reasoning matters.

**4. History → delete. Git has it.** "This comment used to say…", repro
narratives, accounts of what a retired C tool did on a particular day, and the
rename-era sentences that exist only because a rename happened.

**5. Interface contract in a header → keep, compressed, and untagged.** What
the function does, how to call it, what it depends on. Rationale becomes a test
or goes away.

A header's interface documentation is not a *reason*, so the closed set does not
apply to it: `platform:` and `spec:` answer "why is this line here", and an API
contract's answer is "it is the API". **Open point with the family check:** if
that check requires a tag on every comment rather than on every surviving
*rationale*, then compressed headers need a category of their own — which is the
third member shipyard's rule declines to add. Not blocking: the check is opt-in
per repo and macho-tools has no `comment-reasons` file, so this can be settled
when someone adds one.

## The safety rule

**Any passage stating a constraint must either become a test or keep a one-line
form. Never both deleted and untested.**

That is the line that separates this from vandalism. A constraint with neither a
test nor a note is an invitation for the next person to violate it, and this
codebase is full of deliberate-looking-wrong decisions — refusals that exist for
a reason, an `O_RDONLY` that is load-bearing, a filter that must not move.

## What is not touched

- **`tests/compat-matrix.tsv`** and `tests/compat-sweep.sh`'s `refuser=` value —
  a frozen measurement of retired binaries.
- **`compat/fix_macho.sh`'s MEASURED transcript** and its dated note. This is a
  record of a measurement, not narration about code; it **moves to a doc**
  rather than being deleted.
- **Completed plans and specs**, and the two dated research records.
- **Anything under `docs/`** except where a passage moves there.

**Expect this to undo some very recent work.** Two fix rounds on 2026-09-12
carefully restored rename-era narration — the "macho9 → machotool" history
sentences. Under bucket 4 most of that is now deletable: its job was to be true
during a rename that has finished. The measured transcript is the exception, and
moves rather than dies. This is not inconsistent; it is the difference between
"true" and "worth a reader's screen".

## Testing

- **Every suite green after each file.** `ctest`, `characterize.sh` reproducing
  `ad12bdd780da4131f81a808e6d08b688e2034f37e434772f81df023332b39792`,
  `cli_test.sh`, `wrapper_test.sh`, `translate_test.sh`, `known-callers.sh`,
  `change_dylib_test.sh`, `leaf-tool-crashes.sh`, plus the family's
  `check-family-conventions.sh` and `check-shell-portability.sh` from a
  **main-based** shipyard checkout.
- **Every new test mutation-checked.** Break the thing it describes, watch that
  test fail, revert. A test that cannot fail is worse than no test — this item's
  entire premise is that tests catch what prose cannot, and an unfalsifiable
  test is prose with extra steps.
- **Every new test's FAIL message carries the knowledge the deleted comment
  held.** A test whose failure says only "assertion failed" has thrown away the
  thing the comment was protecting. Say what a user loses: not *"expected both
  halves"* but *"a refusal that read the image must say what became of BOTH
  files — a user who sees only 'OUT not written' cannot tell whether their input
  survived"*. This is what makes a test the better home for the knowledge:
  **the comment rots silently; the failure message is read at exactly the moment
  it is needed.**
- **Take the mutation record after the last assertion exists.** A record taken
  earlier goes stale silently; that happened once already.
- The wrappers' stdout stays byte-identical, and no emitted byte changes, so a
  moved digest is a real defect.

## Out of scope

- **The human code review itself** — the second half of item 6, after this.
- **The README.** Its length and its unparseable opening sentence are the repo
  owner's to fix, and removing the unreviewed marker is theirs by definition:
  the family gate exists to force exactly that reading. This spec does not touch
  `README.md`.
- **Module prefixes** (`mi_`, `mr_`, `mg_`, …). A readability decision no single
  design should make unilaterally; it belongs to the human review.
- **Code defects carried into item 6**, notably `src/rewrite.c`'s three
  unchecked `calloc`s. Those are code, not comments. They should be fixed, but
  not here — a sweep that also changes behaviour is a sweep nobody can review.
- The remaining files below the worst-offender threshold, pending the first
  pass's result.

## Relation to other queued work

- **Item 5 (relations + verb lowering)** creates `src/relations.c`. It waits for
  this, so the new module is written to the standard rather than in the old
  style and then rewritten.
- **Item 7 (history rewrite)** invalidates every commit SHA this repo's prose
  cites. This sweep deletes a great many of those citations as a side effect,
  which makes item 7 cheaper.
- The plan-artifact names in roughly 87 older comments are bucket 4, so they go
  as part of this rather than needing their own sweep.
- **The family convention this now matches** is being built in shipyard as an
  enforced conventions check, across 2,700 comment lines in 98 files. It is
  **opt-in per repo, by a repo-local `comment-reasons` file**, so nothing here
  goes red until someone adds one — but sweeping to the family vocabulary now
  means macho-tools needs no second pass when it does.
