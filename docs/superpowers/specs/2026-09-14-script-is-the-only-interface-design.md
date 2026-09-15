# The script is the only interface

**Status:** design, agreed 2026-09-14. Supersedes the verb half of
`2026-09-10-relations-and-verb-lowering-design.md`'s Decision 4, which prescribed
a mechanism that turned out not to be implementable — see "What item 5 learned".

## The proposal in one line

`machotool` stops having a CLI of verbs, and is renamed `machorewrite` to say
what it now is. Its only way to modify a binary is a script on stdin.

```
machorewrite FILE OUT      # statements on stdin; the only way to change anything
machorewrite verify FILE   # read-only
machorewrite info FILE     # read-only
```

Eleven verbs become one mutating form and two read-only queries.

## Why: there are two application models, and one of them is the expensive one

This is not a tidiness argument. The two models have different semantics, and
keeping both is what made queue item 5 hard.

**The script path is sequential, one operation per pass.** `me_statements`
(`src/edit.c`) loops over statements; each calls `me_apply` → `me_rewrite` →
`mr_apply_image` with an `mr_ops` holding **exactly one** operation
(`edit.c:250-257`, `ops.n_strip_cmds = 1`; the disturbs mask passed down is
`ms_disturbs(st->kind, st->op)`, singular). Statements run in the order written.
Callers sequence their own work. Nothing resolves conflicts, because two
operations are never in flight at once.

**The verb path is a set, many operations in one pass.** `cmd_dylib_or_rpath`
accumulates every flag on the command line into one `mr_ops` and applies it in a
single walk of the load commands. That is a different computation, and it needs
machinery the script path does not:

| what | where | why it exists |
|---|---|---|
| `mr_is_deleted` | `src/rewrite.c:56` | scans **every** change so a `-delete` beats a conflicting `-change` for the same path, *regardless of argument order* |
| `No break` loop | `src/rewrite.c:141` | one load command can be named by more than one operation |
| `No break` loop | `src/rewrite.c:248` | the first entry naming a command must stay the "matched" one |
| `mr_report_unmatched` | `src/rewrite.c:1119` | the matched-versus-acted distinction, needed only because one operation can shadow another |
| `int dylib[MR_MAX_OPS]`, `rpath[MR_MAX_OPS]`, `strip[MR_MAX_STRIP]` | `src/rewrite.h:143-145` | 32/32/16-entry hit arrays, sized for a set |

**18 sites** in `rewrite.c` exist only because an `mr_ops` may hold several
operations. `tests/change_dylib_test.sh`'s historical-bug regression case lives
in exactly that machinery. That is where the bugs were.

So the sequential model is not merely simpler to describe — it is the one with
less code and fewer places to be wrong, and the repo owner's recollection that
this was the point is correct.

## What item 5 learned, and why this supersedes part of it

Item 5's Decision 4 said each `cmd_*` should build an `ms_script` and call
`me_run`. It was refused during implementation, on two measured grounds:

1. `me_run` reports `OUT: written (N,NNN bytes)` on **stderr** where
   `mr_apply_file` writes `Wrote OUT (N bytes)` on **stdout**, and
   `tests/known-callers.sh:149` pins the absence of that line in both
   directions.
2. A set cannot be expressed as a sequence. Measured on a fixture with an
   appended dylib nothing binds to:
   - `machotool dylib IN OUT -replace P /also/absent.dylib -delete P` →
     **neither path present.** The delete won.
   - the same two as script statements → **`/also/absent.dylib` present.** The
     replace won and the delete matched nothing.

   Same request, different file. `-delete` winning regardless of order is
   `mr_is_deleted`'s deliberate rule, not an accident.

Ground 1 is void: the repo owner ruled on 2026-09-13 that wrapper text may
change — *"the wrappers won't live long. our machotool code will."* Ground 2 is
real, and this design resolves it by removing the set model rather than by
teaching the script grammar to imitate it. An earlier sketch proposed exactly
that imitation ("one-pass statement groups") and it was **the wrong direction**:
it would import the conflict machinery into the model that is free of it.

## What it costs: measured, and almost nothing outside this repo

**No external caller invokes a verb.** `mavericksforever.com/claude/install.sh`
fetches `patch_macho`, `change_dylib` and `add_version_min` — *wrapper names*.
The verb surface's only consumer is our own `compat/translate.sh`, which builds
`machotool <verb> ...` command lines at runtime (`translate.sh:768`) and also
**prints them** as each wrapper's deprecation notice:

```
change_dylib: deprecated -- machotool does this now. The equivalent commands, in this order, are:
    machotool dylib f f.new -replace /a /b
    mv -f f.new f
```

Under this design that notice becomes a pipeline, which is if anything a
clearer statement of what the tool now is:

```
    printf 'dylib replace /a /b\n' | machorewrite f f.new
    mv -f f.new f
```

## The verbs, one by one

Seven map onto statements that **already exist** — this half is pure
subtraction, not translation:

| verb | statement |
|---|---|
| `declassify` | `fixups set classic` |
| `segment OLD NEW` | `segment rename OLD NEW` |
| `retag-swift` | `swift-abi set legacy` |
| `minos 10.9` | `version-min set 10.9` |
| `lc -delete KIND` | `load-command delete KIND` |
| `dylib -replace/-delete/-append/-insert/-reexport` | `dylib replace/delete/append/insert/reexport` |
| `rpath -replace/-delete/-append/-insert` | `rpath replace/delete/append/insert` |

`edit` stops being a verb name and becomes the tool itself.

### The three that do not map

**`grow FILE OUT N` has no statement form.** Zero rows in `MS_TABLE` against a
positive control. `allow-grow` exists only as a script *directive*
(`src/script.h:61`), so a script can **permit** growth but cannot **request** a
specific number of bytes. It has no production caller — `compat/` never emits
it — but it is exercised by `tests/leaf-tool-crashes.sh` (the sectionless case
at `:362` and the past-the-end-section case at `:374`), so it is a live
crash-safety surface, not dead weight.

**Decision: `grow` becomes a statement, `grow N`.** It is a mutation with an
operand, which is exactly what a statement is; leaving one mutation outside the
only mutating interface would defeat the design's single claim. The crash-safety
cases move to script form with it.

**`verify FILE` and `info FILE` stay as verbs.** They are read-only, take no
`OUT`, and a grammar whose every statement describes a *change* has nothing to
say about them. Forcing them through `FILE OUT` + stdin would mean inventing a
null output for a query, which is worse than an exception. Two read-only verbs
beside one mutating form is an honest shape: the tool reads, or it writes a new
file from a script.

## What gets deleted

Once no `mr_ops` holds more than one operation:

- `mr_is_deleted` and the delete-wins precedence rule
- both `No break` loops and the shadowing they exist to handle
- `mr_report_unmatched`'s matched-versus-acted distinction
- `MR_MAX_OPS` (32) and `MR_MAX_STRIP` (16), and the three hit arrays sized by
  them (`src/rewrite.h:143-145`), which collapse to single values
- the "too many operations" refusals that those caps generate

**This deletion is the point of the design**, not a side effect. Any version of
this work that keeps the multi-operation machinery has not done the thing.

## The one behaviour change, stated plainly

`change_dylib -change X Y -delete X` deletes `X` today. Afterwards it renames
`X` to `Y` and the delete matches nothing.

That is a compat-wrapper behaviour change, authorised in advance. It is also
the more honest reading: a caller who wrote a rename and then a delete of the
old name has described a rename. The order-independence being given up —
"`-delete` anywhere beats `-change` anywhere" — is a rule that has to be
*documented to be predicted*, which is the signature of a rule worth removing
when its only consumer is a compatibility layer with a limited life.

## What must not change

- **Emitted bytes.** `tests/characterize.sh` must keep reproducing
  `ad12bdd780da4131f81a808e6d08b688e2034f37e434772f81df023332b39792`.

  **Measured — and corrected 2026-09-14, because the first measurement passed
  for a weaker reason than it claimed.** `tests/characterize.sh:24` runs
  `change_dylib "$T/out" -strip-lc uuid -strip-lc codesig`, which *looks* like
  two operations in one `mr_ops`. It is effectively one: **no fixture in this
  repo carries an `LC_CODE_SIGNATURE`.** `tests/fixture.macho` has
  `LC_DATA_IN_CODE` and `LC_DYLIB_CODE_SIGN_DRS`, and `lc -delete codesig` on it
  is a **no-op** (byte-identical output, measured). So the agreement that
  invocation demonstrates is a one-effective-operation agreement, which is not
  the property that matters.

  The genuine two-operation case is `uuid` + `source-version`, both of which
  `fixture.macho` really carries and each of which really removes something
  (measured). One pass and two statements agree there too. Task 2's suite
  asserts **both** shapes — the literal `characterize.sh` one and the
  genuinely-two one — because the first alone would pass vacuously forever.
  The digest does not move.

  That is the general rule, also measured: the set and sequence models agree on
  every input **except two operations naming the same path**. Non-overlapping
  operations — different paths, different kinds — are identical either way.
- **`tests/known-callers.sh`'s 18 sha256s** are converted-file digests, not
  stdout. A moved digest means a real behaviour change beyond the one above.
- **The six wrapper names and their exit codes.** The wrappers' *text* may
  change; which invocations succeed and fail may not, apart from the documented
  case.

## Testing

- **Every statement equivalence proved before its verb is deleted**, one verb at
  a time: same input, verb form and script form, **byte-identical output**. A
  verb whose script form is not yet proven equivalent does not get deleted.
- **The one divergent case gets an explicit test** asserting the new meaning,
  replacing `change_dylib_test.sh`'s historical-bug regression case — which
  tested machinery that will no longer exist. Delete it only with its subject.
- **Mutation-check the deletions**: after removing `mr_is_deleted`, a script
  that renames and then deletes must produce the rename, and a test must fail if
  it produces the deletion.
- `tests/leaf-tool-crashes.sh`'s `grow` cases must still catch what they catch
  today. **Corrected 2026-09-14:** this line said "move to script form", which
  contradicts Decision 2 below and is impossible for the past-the-end case —
  no script can reach that grow, which is Decision 2's own argument. Decision 2
  is authoritative. In the event both cases turned out to be hermetic C tests in
  `grow_test.c` **already**, added by the commits that fixed the bugs
  (`7ea664a`, `66ca5ce`), so the work was verify-then-delete rather than
  author-then-delete.
- The family gates from a shipyard checkout **on `main`** — not a feature branch
  (item 6 reported "ok" for six tasks from a branch missing a check entirely).
- **Check CI after each push.** Item 6 shipped a test that was red on `main` for
  a day because it could not fail on the architecture it was written on.

## Out of scope

- **The compat wrappers' own grammar.** They keep accepting exactly what the
  retired C tools accepted; only what they emit changes.
- **`verify` and `info`'s output.** Untouched.
- **Item 7's history rewrite**, which invalidates every commit SHA this document
  cites.
- **A migration period with both interfaces.** There is no external caller to
  migrate, so a deprecation window would carry the two-model cost for no reader.

## Decisions, settled 2026-09-14

**1. The bare form.** `machorewrite FILE OUT` with statements on stdin. No verb
word, no `-`. The smallest surface.

**2. `grow` is deleted, not made a statement** — and the earlier sketch that
made it a statement was wrong. Measured: `compat/` emits it **zero** times
(control: `segment` appears 31 times in `translate.sh`) and the old `-grow` flag
maps to the `allow-grow` **directive**, not the verb (`translate.sh:130`).

**Deleting it costs a SIGSEGV regression test, and that cost must be paid, not
skipped.** The two paths differ: `mg_ensure_pad` runs only when
`need_end > first_sect_off` (`rewrite.c:732`) — growth *on demand* — while
`grow FILE OUT N` **forces** a grow. On `tests/leaf-tool-crashes.sh`'s `oobgrow`
fixture the first section's offset lies past the end of the image, so nothing
ever needs room and **no script can reach the wrap**. That wrap is a real
historical crash: `fsize - insert` underflows a `size_t` and `macho9 grow` died
of SIGSEGV (exit 139).

So the regression moves rather than dies, and it moves somewhere better:
`mg_grow_header` is exported (`src/grow.h:319`) and `tests/grow_test.c:509`
already calls it directly. **Both crash cases become hermetic C tests in
`grow_test.c`** — which is where they belong, since the bug is in the library,
not in a CLI verb. The `sectionless` case moves the same way.

**3. `--capabilities`** collapses its verb list into the statement list.

**4. The tool is renamed `machotool` → `machorewrite`, and it happens here.**

The name should say what the thing is, and after this change the thing is a
Mach-O rewriter driven by a script. `verify` and `info` survive as read-only
verbs and do not contradict the name: both exist to serve a rewrite — one checks
whether a rewrite left the image plausible, the other shows what there is to
rewrite.

**Why with this item rather than with item 7's rename day.** The usual objection
to a second rename is cost — item 3's `macho9` → `machotool` sweep was
expensive, and the repo owner said so at the time. That objection does not apply
here, for two measured reasons. The product has **never been released**, so no
external caller depends on the name: `install.sh` fetches `patch_macho`,
`change_dylib` and `add_version_min`, which are wrapper names and do not change.
And **this item already rewrites every invocation site**: `translate.sh`'s
emissions, every test that runs the binary, and the wrappers' printed
deprecation notices all change shape for the bare form regardless. Renaming
while those lines are already being edited is nearly free; renaming later means
touching them twice.

Item 7 keeps the moves that are about *where things live* — the project
directory, the clone, the GitHub repository — which are independent of the
binary's name and stay grouped with the history rewrite.

## Open questions for the repo owner

None outstanding. All four decisions above are settled; the plan may proceed.

## Amendment, 2026-09-14: conflicts resolve in flag order, uniformly

**The repo owner's ruling**, after a re-review measured what "preserve the
wrappers' behaviour" actually meant for conflicting operations. It does not mean
one thing, because **the pre-migration wrappers did not do one thing.**

### What the parent actually did

Measured at `18ad6f0`:

- **one family** — `compat/translate.sh:509-510` emitted `machotool dylib …` /
  `machotool rpath …`: a **verb**, so one `mr_ops`, applied as a **batch**
  against the original image, with `mr_is_deleted`'s delete-wins precedence.
- **more than one family** — `:524` emitted `machotool edit … -`: a **script**,
  applied as a **sequence**, each statement seeing what the one before left.

So the same conflict got two different answers depending on whether an unrelated
flag from another family happened to be present. `-reexport P -change P Q` alone
resolved one way; add a `-strip-lc` and it resolved the other. That is not a
contract anyone designed; it is an artefact of which code path ran.

A fix round that made single-family reproduce the batch therefore *moved*
multi-family, because the two had never agreed. Four outcomes changed that way —
found only by sweeping ~123 shapes, since the earlier 56-shape sweep contained
no multi-family same-path conflict at all.

### The ruling

**Every conflict resolves in the order written, in every wrapper, whether one
family is present or several.**

Consequences, all intended:

- **`mt_group_stmts` goes.** It takes a delete-wins flag and re-implements
  `mr_is_deleted`'s claiming logic in shell. Keeping it would leave the compat
  layer carrying a copy of the precedence that Task 5 deletes from C — the spec
  calling that deletion "the point of the design" while the shell quietly kept
  it. The two documents would contradict each other, for a rule whose only
  purpose was reproducing a behaviour we are no longer reproducing.
- **`mt_chain_check` should go too.** It exists to refuse shapes no emission
  order can reproduce. Once reproduction is not the goal, a chain is simply a
  sequence: `-change a b -change b c` renames `a` to `b`, then that `b` to `c`.
  That restores the capability its newly-universal application had just removed,
  and it removes the over-broadness the earlier review confirmed byte-for-byte
  (only a true cycle is unorderable; `a→b, b→c` and `a→b, c→a` are both
  reproducible). **Verify before removing** — if some shape still needs
  refusing, say which and why.
- **Nine of roughly 123 swept shapes change.** None is driven by any known
  caller, fixture or suite. Each must be **asserted in its new form**, so the
  next reader finds a decision rather than a surprise.

### Why this is the right trade

The wrappers exist to keep retired tools' callers working while the toolkit
moves on; the repo owner's standing ruling is that they will not live long and
`machotool` will. Spending shell complexity to reproduce an inconsistency — one
that no caller can currently rely on, because it depends on an unrelated flag —
buys compatibility with an accident at the cost of the simplicity this whole
item exists to win.

Stating the rule in one line also makes the wrappers explicable: *operations
apply in the order you wrote them.* The batch rule could not be stated in one
line, which is why it needed `mr_is_deleted`, two `No break` loops and a
comment to explain.
