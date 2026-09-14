# The script is the only interface

**Status:** design, agreed 2026-09-14. Supersedes the verb half of
`2026-09-10-relations-and-verb-lowering-design.md`'s Decision 4, which prescribed
a mechanism that turned out not to be implementable — see "What item 5 learned".

## The proposal in one line

`machotool` stops having a CLI of verbs. Its only way to modify a binary is a
script on stdin.

```
machotool FILE OUT      # statements on stdin; the only way to change anything
machotool verify FILE   # read-only
machotool info FILE     # read-only
```

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
    printf 'dylib replace /a /b\n' | machotool f f.new
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

  **Measured, because the pipeline does drive a multi-operation invocation.**
  `tests/characterize.sh:24` runs `change_dylib "$T/out" -strip-lc uuid
  -strip-lc codesig` — two operations in one `mr_ops`. They name different
  kinds, so they do not conflict, and the two models agree:
  `machotool lc IN OUT -delete uuid -delete codesig` and the two statements
  `load-command delete uuid` / `load-command delete codesig` produce
  **byte-identical** output. The digest does not move.

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
- `tests/leaf-tool-crashes.sh`'s `grow` cases move to script form and must still
  catch what they catch today.
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

## Open questions for the repo owner

1. **`machotool FILE OUT` with no subcommand at all, or keep a word?** A bare
   `machotool f f.new < script` is the smallest surface. A retained word (`edit`,
   `apply`) costs one token and makes the read/write split visible in the
   invocation itself. This spec assumes the bare form; say if you want the word.
2. **Should `grow N` be a statement, or should `grow` simply go?** The spec
   chooses statement, because a mutation outside the mutating interface defeats
   the single claim — but the measurements lean the other way and you should
   know that. `compat/` emits the `grow` verb **zero** times (positive control:
   `segment` appears 31 times in `translate.sh`), and the old grammar's `-grow`
   flag maps to the **`allow-grow` directive**, not to the verb
   (`translate.sh:130`). So `grow` the verb has exactly one user in the world:
   `tests/leaf-tool-crashes.sh`. If those two crash-safety cases can reach the
   same code through a script with `allow-grow` — not yet measured — then
   deleting `grow` outright is the smaller and better answer, and the spec
   should be amended to say so.
3. **`--capabilities`** currently advertises verbs and statements separately.
   With one interface the verb list collapses into the statement list. Anything
   parsing that output sees a changed shape — and nothing outside this repo is
   known to parse it, which is worth confirming before relying on it.
