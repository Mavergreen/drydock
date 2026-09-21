# Relations as data, and verbs that lower to scripts

**Status:** design, agreed 2026-09-10.

**Sequenced after** `docs/superpowers/specs/2026-09-10-edit-scripts-design.md` and
its plan. `MS_TABLE`, `ms_script` and `me_run` all come from that work; this
design has nothing to attach to until they exist.

## Why these two things are one design

The edit-scripts design listed them separately — "Relations — one place to record
what points at what" and "What this does to the CLI". They are the same move made
against two different kinds of knowledge:

> **One declaration, several consumers, and no way for the consumers to drift
> apart.** Applied to *what points at what*, it is the relation table. Applied to
> *the operation vocabulary*, it is verb lowering.

Doing them together is not bundling. The vocabulary table is where an operation
declares which relations it disturbs, so the relation half needs the merged table
the verb half produces. Split, the first half would have to invent a temporary
home for that column and the second would move it.

## This mechanism already exists here, twice

Worth stating before designing anything, because it changes the work from
"introduce a pattern" to "finish applying one".

**`src/linkedit.h`** holds one list of load commands whose entire `__LINKEDIT`
footprint is plain file-offset fields. `src/grow.c`'s `mg_classify_cb` and
`src/linkedit.c`'s `ml_bump_lc` both build their `case` labels from it, so a load
command cannot be added to grow's accept side without being added here, and
adding it here is what teaches `ml_bump_lc` to bump it. The coupling is enforced
as a **link error**, not merely a test — commit `247d09d`.

**`cli/machotool.c`'s `DYLIB_OPS`** (`:159-166`) carries, per operation, the flag
spelling, the arity, a capability name, and separate `dylib`/`rpath` columns
(`-reexport` is `DOP_REEXPORT` for dylib and `DOP_NONE` for rpath). The argument
parser and the `--capabilities` output are both generated from it.

So the question this design answers is not "should we do this" but "why is it
done in two places and not the other three".

## A correction to the edit-scripts spec

That document says `mg_verify`, `mg_snapshot_take` and `mg_plausible` "each
hand-roll their own version of 'is this still consistent', each with its own
hand-rolled applicability condition." **The first half is false.** All three call
`mg_collect` (`src/grow.c:197`), which is already the single walk over the
base-relative structures; `mg_snapshot_take` stores what it returns, `mg_verify`
compares two of them, and `mg_plausible` checks them against
`LC_FUNCTION_STARTS`. Those are three different invariants over one shared
collection, which is the right shape.

The second half is true and is what this design addresses: the **applicability
conditions** are hand-written and scattered, and one of them was the base-of-zero
bug that made `mg_plausible` refuse every dylib.

## Decision 1: derivation only

Relations declare **what is pointed at** and **when they are live**. Nothing
else. Repair code does not move, and no relation declares a check or a repair
function.

| relation | referent | repaired today by |
|---|---|---|
| library ordinal | the ordinal-carrying load-command subsequence | `mo_map_build`/`mo_map_apply` (`src/ordinals.c`) |
| base-relative values | the image base | `src/grow.c`'s re-base pass |
| file-offset fields | `__LINKEDIT`'s blobs | `src/linkedit.h`'s list, `src/grow.c`'s bump |
| initializer and unwind targets | `LC_FUNCTION_STARTS` | `mg_plausible` — checked, never repaired |
| `sizeofcmds` | the header pad | `mr_build_lcs`, `mg_grow_header` |

The two heavier options were considered and declined. Declaring a `check` and a
`repair` per relation would rewrite working, load-bearing code in `src/grow.c` to
buy uniformity this design does not need. A general engine that executes
consequences from a declared graph is the larger of the edit-script spec's "two
generalizations", and nothing yet demands it.

## Decision 2: what each operation disturbs

"Disturbs" means **changes the referent such that references to it go stale** —
not merely "writes bytes near it". The distinction is the whole content of the
column, so it is stated before the table rather than left to be inferred.

Every row below was checked against `src/rewrite.h`'s documented semantics rather
than reasoned from the operation's name. Two rows came out the opposite of the
first draft, which is why the check is recorded here.

| operation | disturbs | why |
|---|---|---|
| `segment rename` | nothing | name characters; no offsets, no commands |
| `swift-abi set legacy` | nothing | one tag bit per class record |
| `dylib reexport` | nothing | an **in-place promotion** of `LC_LOAD_DYLIB` to `LC_REEXPORT_DYLIB` (`rewrite.h:62`). Both are ordinal-carrying, so the subsequence's membership, order and length are all unchanged |
| `dylib append` | header pad | a new `LC_LOAD_DYLIB` "placed last" (`rewrite.h:85`); it takes the highest ordinal, so **no existing ordinal moves** |
| `dylib replace` | header pad, only if the new path is longer | keeps the command's position and its ordinal |
| `rpath` — all four | header pad | `LC_RPATH` carries no ordinal; only the command count changes |
| `load-command delete` | header pad | frees pad |
| `version-min set` | header pad | appends a command |
| `dylib insert` | ordinal subsequence, header pad | "placed first"; inserted dylibs "become ordinals 1..n" (`rewrite.h:76-87`), shifting every existing one |
| `dylib delete` | ordinal subsequence, header pad | removes a member, renumbering every survivor after it |
| `fixups set classic` | `__LINKEDIT`'s blobs, the image base | rebuilds the bind and rebase streams wholesale |

The header-pad column is not noise: "disturbs the header pad" is exactly the
condition under which an edit may not fit and `allow-grow` becomes relevant. It
is the cheapest relation to satisfy and the most commonly disturbed, which is why
it earns a column rather than a special case.

Two facts are then computed rather than maintained:

- **which operations carry follow-up work** — exactly those disturbing some
  relation's referent;
- **which checks apply to a run** — exactly those relations live in this image
  whose referent this run disturbs.

## Decision 3: `mr_is_rename_only` is deleted, and the deletion must be proved

`mr_is_rename_only` (`src/rewrite.c:641`) scopes `mg_plausible` out of rename-only
operations. It exists because the gate refuses real images for ordinary edits, and
it is written as "everything else is empty" — a conjunction over `mr_ops`' fields
with a **documented blind spot**: a new member of four bytes or fewer placed in
one of the struct's seven interior padding holes moves neither `sizeof` nor the
guarded offset, compiles clean, and is invisible to it. The layout tripwire at
`:638` catches the layout change, not the meaning change.

What that predicate actually asks is *"does this operation disturb anything
anyone points at?"* — which is what §2 computes. So it becomes derived, and the
hand-written version goes.

### The derivation narrows applicability, deliberately, and the narrowing is enumerated

`mr_is_rename_only` skips the gate for one shape. The derived rule skips it
whenever the run did not disturb the initializer-and-unwind relation — which, per
§2, only `fixups set classic` and a header grow do. So the new rule **skips checks
the old rule ran**, and a differential test demanding the two "agree everywhere"
would be incoherent.

The justification is `mg_plausible`'s own, generalized. Its comment
(`src/rewrite.c:872-880`) explains the rename exception as *"the gate cannot catch
anything a rename did; it can only re-decide a property the INPUT already had,
and refuse."* That is an argument about offsets, and it holds identically for
every operation below: none moves a section offset or rewrites
`LC_FUNCTION_STARTS`.

**Expected differences — the complete list. Any difference not on it is a stop.**

| op-set shape | old | new | why the skip is right |
|---|---|---|---|
| `swift-abi set legacy` alone | runs | skips | one tag bit per class record; no offset moves |
| `dylib reexport` alone | runs | skips | in-place promotion; count, order and ordinals all unchanged |
| `load-command delete` alone | runs | skips | frees header pad; no section offset moves |
| `version-min set` alone | runs | skips | appends a command; no section offset moves |
| any `dylib` or `rpath` op alone, without growth | runs | skips | changes the command region and possibly ordinals; no section offset moves |
| any combination of the above, without growth | runs | skips | the union disturbs no referent the gate checks |
| `fixups set classic` | runs | **runs** | rewrites `__LINKEDIT` and the image base |
| anything that grew the header | runs | **runs** | see below |
| rename-only | skips | skips | unchanged |

**Applicability is evaluated against what the run did, not only what it
declared.** A `dylib append` that overflows the pad and triggers a grow has
disturbed the base-relative relation, whichever statement asked for it. Declaring
this up front matters: computing applicability from the statement list alone would
skip the gate on exactly the runs that most need it.

**What this costs, stated plainly.** `mg_plausible` is defence against bugs in the
*rewriter*, not only against the operation's declared intent, so narrowing its
reach narrows that defence. The case the comment names as the reason it exists —
`patch_macho`'s chained-fixups conversion, ~94,900 rebases with no self-check of
its own — is preserved, because that conversion disturbs the relation. What is
given up is the chance of the gate incidentally catching a bug in an operation
that moves no offsets. That trade is the point of the design, not a side effect,
and it is written here so a reviewer weighs it rather than discovers it.

### One existing assertion this invalidates, and what replaces it

`tests/cli_test.sh:2109-2122` runs `lc -delete uuid` against `mkimplausible`'s
fixture and asserts it **is refused**, under the comment *"An ordinary operation
on it still meets the gate and is refused … so the skip below is narrow, not a
hole"* and the label *"an operation that CAN move an offset still meets the
gate"*. Its failure message is `"lc -delete uuid was NOT refused, so the gate is
gone"`.

The derived rule skips the gate for that operation, so this test fails — and
fails saying the gate is gone, which would read as a genuine regression.

Two things follow, and the plan must carry both:

**Its premise is already slightly false, and that is worth recording.** `lc
-delete` does not move a section offset: it frees header pad and `mr_build_lcs`
repacks the command region, leaving section file offsets where they were. The
label "an operation that CAN move an offset" overstates what the operation does —
the same class of claim this repo treats as a defect. The test has been passing
because the gate ran, not because the premise held.

**Do not delete it to make the suite green.** Its purpose — proving the skip is
narrow rather than a hole — is exactly the property this design most needs
asserted, since the skip is now much wider. Rewrite it against an operation that
genuinely disturbs the relation: `fixups set classic`, or any run that grows the
header. Same fixture, same "was NOT refused, so the gate is gone" failure message,
an operation for which the claim is true.

**The test that gates the deletion.** Both predicates run side by side across
every operation-set shape the suite exercises. A difference on the table above is
expected and asserted; a difference anywhere else fails. Only once that holds does
the old predicate come out. A comment claiming the two are equivalent is exactly
the kind of claim this repo treats as a defect when nothing would fail if it were
false.

## Decision 4: verbs build scripts

`DYLIB_OPS` and `MS_TABLE` merge into one table carrying, per operation: script
kind and operation, verb flag spelling, arity, which modes accept it, capability
name, and the referents it disturbs. One declaration feeds the verb parser, the
script parser, `--capabilities`, and §2's derivation.

Each `cmd_*` parses its `argv` into an `ms_script` **in memory** and calls
`me_run`. Not by generating script text: round-tripping `argv` through quoting
would put a quoting bug on the compat wrappers' path, where today it could only
reach `edit`.

**The verbs' own `printf` calls do not move.** The six wrappers' stdout must stay
byte-identical to the C tools they replaced; `tests/known-callers.sh` is the gate,
and it stays green because the output statements stay exactly where they are. What
changes is the path by which the edit gets applied, not the path by which it is
described.

## The objection this will draw

Putting an applicability predicate in front of `me_run`'s verification reads like
reintroducing the `MACHO_NO_VERIFY` escape that was deliberately removed from a
shipped wrapper during the compat retirement.

It is not the same thing, and the difference is the whole reason the removal
happened. **An escape hatch is caller-controlled**: a flag or an environment
variable, settable by whoever is invoking the tool, and therefore settable by
someone who wants a refusal to go away. **This is determined by the image and the
operations**, computed from declarations, with no input that a caller can supply
to switch it off. The check that does not run is the check that has nothing to
check — which is already why `mg_plausible` returns 0 when an image carries no
`LC_FUNCTION_STARTS`.

## Testing

- **The differential test of Decision 3**, above. It is the one that gates the
  deletion.
- **A tripwire on the merged table**, in the spirit of `linkedit.h`'s link error:
  adding an operation without declaring what it disturbs must fail to build, not
  silently declare "nothing". "Nothing" is a real and common answer, so it has to
  be spelled, not defaulted.
- `tests/known-callers.sh` and `tests/wrapper_test.sh` unchanged and green —
  the evidence that wrapper stdout did not move.
- `tests/characterize.sh` reproducing
  `ad12bdd780da4131f81a808e6d08b688e2034f37e434772f81df023332b39792` — the
  evidence that no emitted byte changed.

## Out of scope

- **Declaring checks or repairs per relation**, and the general consequence
  engine. Decision 1 names both and declines them.
- **Removing any verb.** The verbs stay as sugar; the repo owner settled that
  redundancy is a feature when it keeps a transformation in one pass.
- **The module prefixes.** `mi_`, `mr_`, `mg_`, `mo_`, `mseg_`, `mswift_`, `wa_`
  and the new `ms_`/`me_` are opaque to a reader who has not learned them — the
  repo owner said so while approving this design. It is a real readability cost
  and it is not this design's to fix; the rename design
  (`2026-09-10-machotool-rename-and-target-design.md`) currently says prefixes
  stay, and reversing that is a decision for that document.
- **`tests/compat-matrix.tsv`.** A dated artifact whose other side no longer
  exists at HEAD; nothing here regenerates it.

---

## Amendment, 2026-09-13: the derivation governs every gate site

Written after a drift scan against `HEAD`, five items having shipped since this
design was agreed. The scan's measurements are in
`.superpowers/item5-drift-scan.md`. One design decision did not survive; the
repo owner ruled on it, and four smaller decisions fall out of that ruling.

### What broke

This design modelled the `mg_plausible` gate as **one** site — `mr_process_thin`'s
— scoped by `mr_is_rename_only`. At `HEAD` there are **four**, and two of them
run it *unconditionally*:

| site | scoped by |
|---|---|
| `src/rewrite.c:944` (`mr_process_thin`) | `mr_is_rename_only`, plus `MACHO_NO_VERIFY` |
| `src/grow.c:1432` (inside `mg_grow_header`) | nothing |
| `src/edit.c:899` — `me_run`'s final verify, thin | **nothing** |
| `src/edit.c:676` — `me_fat_slice`'s per-slice verify | **nothing** |

So the two front-ends already disagree, and this was measured rather than
reasoned. On `tests/mkimplausible.c`'s fixture, with the identical operation:

```
machotool segment f o __DATA __DATA_R9           -> exit 0
machotool edit f o <<< 'segment rename __DATA __DATA_R9'  -> exit 1, refused at verification
```

Decision 4's *"each `cmd_*` parses its `argv` into an `ms_script` in memory and
calls `me_run`"* therefore imports `edit`'s gate into the verbs, flipping
`machotool segment` and `machotool minos` from 0 to 1 — breaking two
`cli_test.sh` assertions and contradicting Decision 3's own "rename-only:
skips → skips, **unchanged**" row.

### Decision 5: the derived applicability governs both front-ends

**The repo owner's ruling.** The derivation decides whether `mg_plausible` runs,
at `mr_process_thin`'s site *and* at `me_run`'s two. The verbs keep the exit
codes they have today; `edit` stops running a check that has nothing to check.

The consequence to state honestly, because this design's own rule is that a
claim nothing would fail on is a defect: **`edit`'s final verify stops being
unconditional.** `src/edit.c:895-896` says *"Verify the finished image: always,
and never subject to `MACHO_NO_VERIFY`"*, and
`tests/edit_test.c:615`'s `test_the_final_verify_ignores_MACHO_NO_VERIFY` pins
it. That test is **rewritten, not deleted** — the same rule this design already
applied to `cli_test.sh`'s scope assertion.

What it must pin after the change is the property that actually matters, which
survives intact:

- **No caller can switch the gate off.** `MACHO_NO_VERIFY` still cannot suppress
  a verify that applies. That is the whole content of the original contract and
  it is unchanged.
- **The skip is image- and operation-determined.** What narrows is only
  *"always"* → *"whenever anything it checks was disturbed"*.

This is the distinction §"The objection this will draw" already draws, now load
-bearing rather than rhetorical: an escape hatch is caller-controlled, and this
is not. A test asserting "always" would, after this change, be asserting
something false; a test asserting "never caller-suppressible" asserts the thing
the contract was protecting.

`mg_grow_header`'s own internal call (`src/grow.c:1432`) is **not** in scope and
does not move. A grow disturbs the base-relative relation by definition, so the
derivation would run it there anyway; leaving it alone keeps the change to the
two sites whose behaviour the ruling is about.

### Decision 6: relations are evaluated per slice

`mrel_live(const mi_image *)` has no single answer for a fat container, and item
11 shipped `edit` on fat files after this design was written. It takes a
**slice**, not a container, which is how the surrounding code already works:
`me_statements` runs per slice (`src/edit.c:671`) and `mg_plausible` runs per
slice (`:676`). A fat run derives applicability once per slice, and a slice that
disturbs nothing skips its own verify regardless of what its neighbours did.

### Decision 7: `needs_renumber` is not routed through the derivation

`src/rewrite.c:773` decides whether the ordinal renumbering pass runs:

```c
int needs_renumber = (ops->n_dylib_inserts > 0) || (nnew - ops->n_dylib_inserts < nold);
```

Task 3 tells an implementer to route kind-testing sites through `me_followups`
and to *stop and report* any site whose condition is not expressible as a
disturbs mask. This is that site, it is the only one, and the ruling is
**leave it alone**.

The reason is a distinction worth keeping in view for the whole item: a disturbs
mask is a conservative **declaration** about an operation; `needs_renumber` is an
exact **observation** about this image, since `nnew` and `nold` come from
`mo_map_build` walking it. `dylib delete /nonexistent` declares `MREL_ORDINAL`
and renumbers nothing. Routing the observation through the declaration would run
the pass when nothing matched — a behaviour change bought for uniformity, which
is precisely the trade Decision 1 already declined.

### Decision 8: `target 10.9` declares `MREL_NONE`, and its consequences accumulate

`target` is an `MS_TABLE` row (`src/script.c:91`), not a script field like
`allow-grow`, `fatal-warnings` and `arch` (`src/script.h:61-65`), so the tripwire
will demand a disturbs mask for it. Its expansion is image- and slice-dependent
(`src/edit.c:476-514`, at run time), so no static mask can describe what it does.

It declares **`MREL_NONE`**, because the row itself disturbs nothing: it expands
into other statements, and those statements declare their own. This needs no new
mechanism — §"Applicability is evaluated against what the run did, not only what
it declared" already requires accumulating actual disturbance, which is what a
grow relies on too. `MREL_NONE` here means "nothing *of its own*", and the
comment on the row must say so, since a bare zero would otherwise read as an
unreviewed default — exactly what the tripwire exists to prevent.

### Corrections that needed no ruling

- **Decision 2 row 11 was wrong.** `fixups set classic` also disturbs the header
  pad: `src/declassify.h:32-37` strips three command kinds and adds a 48-byte
  `LC_DYLD_INFO_ONLY`. Its mask is `__LINKEDIT` + image base + header pad.
- **Decision 2 is a 15-row table**, `rpath`'s four operations split out, and
  `target 10.9` added per Decision 8.
- **Decision 3's expected-difference table is restated against the derivation**,
  not against `mr_process_thin`'s gate. Three of its nine rows named operations
  that never build an `mr_ops` at all — only `cmd_lc`, `cmd_dylib_or_rpath` and
  `cmd_segment` call `mr_apply_file` — so for those the "old" column was
  describing a gate that never ran.
- **The blind-spot claim splits in two.** `mr_ops` does still have seven 4-byte
  interior holes (at offsets 12/28/44/60/76/92/108, `sizeof` 152,
  `offsetof(allow_grow)` 148 — measured), and that example *is* documented at
  `src/rewrite.c:620-640`. But the `segment_renamed`/`renumbering` omission is
  documented **nowhere** at `HEAD`: the narration sweep deleted the sentence,
  on the ground that a compile-time tripwire enforces it. That strengthens the
  case for deleting the predicate rather than weakening it — making it consult
  those two OUT fields fails two existing assertions, because `cmd_segment`
  always sets `segment_renamed` (`cli/machotool.c:976`).
- **Ten citations were stale** — three dead, seven moved. `src/rewrite.h` lost
  two-thirds of its lines to the narration sweep, so every line reference into it
  had to be re-resolved. The scan report lists each with its new location.

### Amendment addendum, same day: three corrections to the amendment above

Found while revising the plan against it. Recorded here because two are errors in
this document, not in the plan.

**1. The derivation formula in this spec cannot fire as written, and the bug is
mine.** Decision 3 says the derived rule skips the gate "whenever the run did not
disturb the initializer-and-unwind relation". But **no row of Decision 2's table
ever names that relation as disturbed** — `LC_FUNCTION_STARTS` is its *referent*,
and `mg_plausible` only ever *checks* it (the table says so: "checked, never
repaired"). `fixups set classic` disturbs `__LINKEDIT` and the image base; a grow
disturbs the image base. Neither disturbs the relation whose referent is
`LC_FUNCTION_STARTS`.

So `mrel_live(slice) & disturbed & MREL_FUNC_START` is permanently zero, and a
derivation built on it would have switched `mg_plausible` off **everywhere** while
every suite stayed green — the gate would have been deleted by accident rather
than narrowed on purpose. That is the precise failure this item exists to prevent,
sitting in the item's own design.

The rule is two different masks, not one:

> Run `mg_plausible` when the **`MREL_FUNC_START` relation is live in this slice**
> AND the run **disturbed `MREL_BASE_REL`** — because base-relative movement is
> what invalidates the function-start offsets the gate checks.

`fixups set classic` and any header grow both disturb `MREL_BASE_REL`, so
Decision 3's expected-difference table is unchanged in its outcomes. Only the
expression that computes them is.

**2. Five tests pin the unconditional verify, not one.** The amendment named only
`tests/edit_test.c:615`. Also affected: `:590` (an empty script), `:1018-1024`
(the fat per-slice verify), and `:484-490` and `:1138`, which assert on the
`": verified"` report line and so depend on the verify having run. All five are
rewritten to pin the surviving property, not deleted. A sixth, `:632-633`, asserts
the log does *not* claim verification on a refusal — that one is unaffected and
must stay exactly as it is.

**3. How the verdict reaches `mr_process_thin` — a ruling, since the plan had no
answer.** That site holds an `mr_ops`, not an `ms_script`, so there is no mask
lying around for it to read.

**The declared mask is passed as a parameter to `mr_apply_image`, and accumulated
locally.** Not stored in `mr_ops`. Three reasons: a *derived* value inside a
*declaration* struct is exactly the shape that goes stale silently, which is what
this whole item is against; a parameter makes the compiler require every caller to
supply one, which is the same enforcement the `linkedit.h` link error and the
table tripwire already rely on; and it mirrors the accumulator the `edit` side
needs anyway, since applicability is evaluated against what the run *did*. A grow
inside `mr_process_thin` ORs `MREL_BASE_REL` into its local copy, so the one
mechanism covers the "declared" and the "observed" halves without a second path.

### Amendment 3, 2026-09-13: the cost was understated, and here is the measured cost

Written after the plan shipped, because the final whole-branch review measured
the thing §"What this costs, stated plainly" only asserted.

**The claim that was wrong.** That section reassures a reviewer:

> The case the comment names as the reason it exists — `patch_macho`'s
> chained-fixups conversion, ~94,900 rebases with no self-check of its own — is
> preserved, because that conversion disturbs the relation.

**It is not preserved, except inside a single `machotool edit` that itself does
the conversion.** `disturbed` is per **process**. `machotool declassify` — the
`patch_macho` equivalent — runs no plausibility check of its own (`src/declassify.c`
contains no `mg_plausible` reference at all), and the `change_dylib` that follows
it declares only *its* disturbances, which do not include the image base. So
nothing carries the conversion's disturbance across the process boundary.

**What is actually caught now, measured against a build of the parent commit:**

| sequence | before | after |
|---|---|---|
| `patch_macho` (declassify) alone | nothing | nothing — unchanged, it never had a gate |
| `add_version_min` | nothing | nothing — unchanged |
| `change_dylib` after a conversion (`install.sh` step 3) | **refused, exit 1** | **exit 0, file written** |
| the whole `install.sh` chain | **caught at step 3** | **caught nowhere** |
| `machotool edit 'fixups set classic'` | refused | refused |
| `machotool edit 'target 10.9'` | refused | refused (expansion accumulates) |
| any run that grows a header | caught | caught, plus `mg_grow_header`'s own gate |
| `grow`, `verify` | caught | untouched |

So the honest statement of the trade is the opposite of the original one: the
conversion's incidental re-check was **the** protection on the compat chain, and
narrowing the gate removed it there while keeping it in `machotool edit`. What
the design gave up is not "the chance of the gate incidentally catching a bug in
an operation that moves no offsets" — it is the chain's only check on the
heaviest transform the toolkit performs.

**This is not a decision the plan was authorised to make**, because the sentence
that made it look free was false. It is recorded here for the repo owner, who
has three options and should not have them pre-empted:

1. **Accept it.** The re-check was incidental — `change_dylib` never set out to
   validate `patch_macho`'s output, and a conversion that needs checking should
   be checked by the tool that performs it.
2. **Give `declassify` its own gate**, which is where the check belongs on the
   merits: the tool doing ~94,900 rebases with no self-check is the one that
   should verify them. This is a new behaviour, not a restoration.
3. **Make the disturbance cross the process boundary** — the wrappers already
   chain these tools, so a chain could carry what it disturbed. The largest
   change, and it re-couples what this design set out to decouple.

Until then, **no document should state that the chain is protected**, and the
three places that did have been corrected.

### Resolution of Amendment 3, 2026-09-21: option 2, and it was not already done

The repo owner chose **option 2**: the conversion verifies its own output.

**Measured first, because deleting the `declassify` verb could have closed
this by accident.** It did not. The conversion now runs only as the `fixups set
classic` statement (`compat/patch_macho.sh` pipes that statement into
`machorewrite`), so it meets `src/edit.c`'s gate in the same process — but
that gate is `mg_plausible`, which compares initializer, unwind, export and
data-in-code targets against `LC_FUNCTION_STARTS`. It never reads a rebased
pointer or a bind. Two mutations of `src/declassify.c`, each run through
`patch_macho IN OUT`, `machorewrite IN OUT` with `fixups set classic`, and
the `install.sh` chain (`patch_macho`, `add_version_min`, `change_dylib`):

| mutation | fixture | every entry point |
|---|---|---|
| first rebase's slot written as target + 0x10 | `tests/mkchained.c` (no `LC_FUNCTION_STARTS`, so the gate did not apply) | exit 0, file written, `slot0=0x100001010` |
| first rebase's `DO_REBASE` opcode dropped | the same | exit 0, file written, rebase stream 4 bytes instead of 5 |
| first rebase's slot written as target + 0x10 | a real ld64-built x86_64 executable with chained fixups and `LC_FUNCTION_STARTS` (7,880 rebases, 1,281 binds) | exit 0; the gate **ran and printed `verified`**; `change_dylib` afterwards exit 0 |

So the table above understated this too: the row reading
`machotool edit 'fixups set classic'` — **refused** was true only of a
conversion that went wrong in the ways `mg_plausible` checks, and a lowered
rebase or bind is not one of those ways. Nothing, anywhere, checked the
~94,900 rebases.

**What shipped.** `md_declassify_buf` now copies the chained segments' file
bytes before it rewrites them, and, after emitting, reads the output back as
dyld would: it finds the new `LC_DYLD_INFO_ONLY`, interprets its rebase and
bind streams, re-walks every chain from the saved bytes, and requires each
link to be matched by the next emitted rebase or bind at the same segment and
offset, with the slot holding the target the link decodes to (rebase) or 0
and the right symbol, ordinal and weak flag (bind), and nothing emitted
beyond the chains. Any difference is `MDCL_REFUSED`, so every entry point —
the statement, `target 10.9`, `patch_macho`, and therefore the `install.sh`
chain at its first step — refuses and writes nothing. Both mutations above
are now refused through all three entry points.

Two inputs the conversion used to turn into a wrong binary, exit 0, are now
refused by that check and pinned by `tests/cli_test.sh` (`mkchained
make-badord`, `make-high8`); both cases fail when the check's call is
removed: a bind naming an import past `imports_count` (the walk dropped that
link and the rest of its chain), and a rebase with nonzero `high8`, which the
lowering discards. The second is a latent decode defect — the conversion's
`DYLD_CHAINED_PTR_64` branch also reads `target` as 43 bits and `high8` from
bits 43–50, where `<mach-o/fixup-chains.h>` has 36 and 36–43 — that is
harmless while `high8` and the reserved bits are zero, which they are on
x86_64. It is now a refusal rather than a wrong pointer; correcting the
decode is separate work.

The "no document should state that the chain is protected" instruction is
retired: the chain is protected, by the conversion, not by the later
`change_dylib`. `README.md` says so, and the paragraph in `src/rewrite.c`
that described the gap is gone.
