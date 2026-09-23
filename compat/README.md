# compat/

The six original entry points, kept for compatibility. All six are now
`/bin/sh` wrappers around `drydock-macho-rewrite`. There is no C left in this directory.
A seventh wrapper, `insert_dylib`, joined later — it is convenience for a
grammar this repo never shipped, not compatibility debt; see "`insert_dylib`:
not one of the six" below. An eighth, `bake-mavericks-shim`, is the same kind
of convenience; see "`bake-mavericks-shim`" at the end.

> **The goal is met.** The goal was "`macho9` becomes the only Mach-O
> rewriting binary this repo ships." It is: `compat/` holds
> six shell wrappers and two shell support files, and `drydock-macho-rewrite` is the only
> binary `CMakeLists.txt` builds or installs. `fix_macho` was the holdout —
> see "Why `fix_macho` could not be wrapped, and what changed" below, which is
> the record of what adopting its five divergences cost and why that was the
> right call rather than a shortcut.

THERE ARE NO VERBS LEFT TO EMIT. Every wrapper emits the one mutating form,
`printf '<statements>' | drydock-macho-rewrite FILE OUT`, and `compat/translate.sh` is
where the old flag grammar becomes those statements.
`drydock-macho-rewrite declassify`, `lc`, `dylib`, `rpath`, `minos`, `segment`,
`retag-swift`, `grow` and `edit` were verbs, and are read below as history.

| installed name | what it is now |
|---|---|
| `patch_macho` | `patch_macho.sh` → `fixups set classic`, installed over `OUT` |
| `change_dylib` | `change_dylib.sh` → `load-command delete` / `dylib` / `rpath` statements, however many the flags name |
| `add_version_min` | `add_version_min.sh` → `version-min set 10.9`, installed over `FILE` |
| `rename_segment` | `rename_segment.sh` → `segment rename OLD NEW` |
| `retag_swift_classes` | `retag_swift_classes.sh` → `swift-abi set legacy`, once per file, installed over each `FILE` |
| `fix_macho` | `fix_macho.sh` → `load-command delete` / `dylib` / `segment rename` statements, however many the flags name (two renames are two statements) |
| `insert_dylib` | `insert_dylib.sh` → `dylib append` / `dylib retype` / `load-command delete codesig` statements — not one of the six; see below |
| `bake-mavericks-shim` | `bake-mavericks-shim.sh` → `load-command delete codesig` / `dylib append` / one `import redirect` per import the shim provides — not one of the six; see below |

plus the two files every wrapper sources:

| file | installed as | what it does |
|---|---|---|
| `translate.sh` | `drydock-macho-rewrite-translate.sh` | old argv → the `drydock-macho-rewrite` command line(s) it means. Pure text; runs nothing. |
| `drydock-macho-rewrite-compat.sh` | `drydock-macho-rewrite-compat.sh` | finds `drydock-macho-rewrite`, prints the teaching message, and runs the translation. |

## Why the six wrapper names are unchanged

The *support* files were renamed with the binary — `drydock-macho-rewrite-compat.sh` and
`drydock-macho-rewrite-translate.sh` — because nothing outside this repo names them. The
six wrapper names are the opposite case, and that is what this section is about.

`mavericksforever.com/claude/install.sh` fetches `patch_macho`,
`change_dylib` and `add_version_min` **by those names** and its generated
`/usr/local/bin/claude` wrapper invokes them by those names.

**Today** it fetches them from
[`Wowfunhappy/Mavericks-Porting-Resources`](https://github.com/Wowfunhappy/Mavericks-Porting-Resources),
not from this repo — so renaming them right now would break nothing live (see
`PROVENANCE.md`, "Extracted from a branch, not from master"). Keeping the
names matching is about the adoption path: PRs #11/#12 upstream this repo's
fixes to that repo, and if/when Wowfunhappy merges them, or
`mavericksforever.com` points `install.sh` at this repo instead (see
`docs/PROPOSAL.md`, "one repo, first-party"), `install.sh`'s existing
invocations have to already resolve to the same names here.

### What a packager has to change, and who has not been told

**A wrapper cannot work without `drydock-macho-rewrite`, `drydock-macho-rewrite-compat.sh` and
`drydock-macho-rewrite-translate.sh` sitting in the same directory.** `install.sh` fetches
`patch_macho`, `change_dylib` and `add_version_min` **by name**, three files;
those three now need three more beside them. Fetch the three alone and you get
three names that cannot run.

That is inherent to replacing the binaries with wrappers at all, not to how
these particular ones are written, and it is why everything installs **flat**
into one `bin` rather than into a `libexec/` subdirectory — a flat layout
needs only extra file names from that script, where a subdirectory would need
it restructured.

**Nobody has told whoever owns that script.** `install.sh` lives at
`mavericksforever.com` and is not this repo's to change; turning the wrappers
into refusals is already blocked on it moving, and this is a second, earlier reason
the same conversation has to happen. Until it does, a CDN built from this repo
would ship three names that cannot run. `.github/workflows/release.yml` puts
all six files in the release artifact, which is the most this repo can do on
its own.

## What "drop-in" means here, precisely

The exit codes are identical to the C tools', and the rewritten file's bytes
are identical everywhere `tests/differential.sh` and `tests/compat-sweep.sh`
check them, with five known exceptions, truthfully not all the same KIND of
known: one reproduced on a real file (one out of 300 in the differential
corpus, below), one argued unreachable in practice rather than observed,
two true by construction rather than by measurement -- they follow
directly from reading what the wrappers' code does, not from a corpus
row that exhibits them, so no file "reproduces" them and no argument is needed
for why they would be rare -- and one decided on purpose:

  * **A header pad too short for the new load commands is grown**, where the
    C tools refused: `change_dylib` without `-grow`, `fix_macho` and
    `add_version_min` all said there was no room, exit 1, file untouched. On
    an x86_64 PIE executable the wrapper now lowers the image base to make
    room, announces it on stderr ("FILE: grew the header pad by N bytes
    ..."), and exits 0; anything else is still refused. The repo owner's
    ruling: the engine never writes its input, and the grow verifies itself,
    so an opt-in bought nothing. `tests/cli_test.sh`'s `add_version_min`
    case ("a short pad is grown, announced, where the original refused")
    holds it for that tool; the `change_dylib` and `fix_macho` tables below
    hold it for theirs. Two rows of `tests/compat-matrix.tsv` record the
    refusal as it was measured.

  * `rename_segment` on a binary carrying `LC_LAZY_LOAD_DYLIB` refuses where
    the C tool renamed, because the shared rewriter builds its
    library-ordinal map before it looks at whether any operation could
    renumber. `compat/rename_segment.sh`'s header has the measurement. It is
    one file out of 300 in `tests/differential.sh`'s corpus, and closing it
    means changing `drydock-macho-rewrite`.
  * `patch_macho`'s `OUT` gets a NEW INODE where the C tool's
    `open(O_WRONLY|O_CREAT|O_TRUNC)` wrote through the path and kept it. The
    install is `mv`, like every other wrapper's, which is what makes `OUT`
    wholly old or wholly new rather than possibly half-written (neither the C
    tool's write nor the `cat TEMP > OUT` that first replaced it was atomic).
    Its MODE is still exactly what the C tool left -- `0755 & ~umask` for an
    `OUT` that did not exist, `OUT`'s own mode for one that did -- and an
    unchanged run (the pass-through, including `patch_macho IN IN`) installs
    nothing, so that case keeps its inode too. What a rename cannot keep is
    `OUT`'s other HARD LINKS, so an `OUT` carrying any is refused (exit 1)
    instead of being silently split, exactly as `FILE` is for the other five;
    a dangling symlink at `OUT` is refused as well, where the C tool created
    the link's target, and an `OUT` that exists but is not a regular file (a
    directory, a fifo, a device) is refused where the C tool's `open()` either
    wrote to it or failed with `EISDIR`. Those `OUT` pre-checks also answer
    BEFORE the input is diagnosed, so when IN **and** OUT are both bad it is now
    OUT that is named — the same shape as `retag_swift_classes`' pre-check
    below, and exit 1 on both sides either way.
    `compat/patch_macho.sh`'s header has all of it.
  * The writability pre-check `rename_segment.sh` runs (`test -w`, to fail
    before any analysis exactly as the C tool's `open(O_RDWR)` did) can
    disagree with the real open at the edges -- it consults the real uid and
    does not see ACLs. It agrees on the two cases that actually reach a
    caller (absent, and mode-denied); `compat/rename_segment.sh`'s header has
    the detail.
  * `change_dylib` and `add_version_min` are the two wrappers that forward
    script run's own exit code (`me_run`, `src/edit.h`) verbatim, with no
    mapping at all -- unlike `fix_macho` and
    `patch_macho`, which translate every nonzero
    drydock-macho-rewrite exit to one flat historical code, `rename_segment`,
    which classifies a refusal (its exit-code section below has the map), and
    `retag_swift_classes`,
    which has its own real 1-vs-2 mapping (`compat/retag_swift_classes.sh`'s
    header has it) and is likewise unaffected by this. (EVERY wrapper whose
    verb now writes an output the wrapper installs -- all six, `patch_macho`
    included: its verb's output goes to a temp beside the `OUT` it was asked
    for, and is installed onto it --
    has refusals of its OWN on top of that,
    exiting 1, made before drydock-macho-rewrite runs for the argument in question: an
    absent or unwritable `FILE`, a `FILE` carrying other hard links, and a
    failed install. Those are the wrapper's, not a forwarded code -- and for
    `retag_swift_classes` an absent or unwritable argument is a WORDING
    divergence too: `tests/compat-matrix.tsv`'s rows for that case (measured
    before the wrapper's own pre-check began answering first) have both
    sides agreeing on `perror(path)`'s
    "`<path>: No such file or directory`", which is still what
    `mswift_retag_file` itself prints when drydock-macho-rewrite actually reaches the
    open() -- but the wrapper's own pre-check now answers first, in its own
    words (`open: No such file or directory`), so only the exit code still
    matches. `add_version_min.sh` has no such gap: its own C tool's
    `perror("open")` already said literally "open: ...", so the wrapper's
    identical wording was never a divergence to begin with. A WRITABLE
    `FILE` inside a NON-writable directory is a fourth case neither wrapper's
    own pre-checks catch -- the write itself fails, `mkstemp: Permission
    denied`, because installing needs the directory writable where the old
    tools needed only `FILE` itself to be; `compat/add_version_min.sh` and
    `compat/retag_swift_classes.sh`'s own headers both name it, and for
    `retag_swift_classes` it surfaces as `had_error` (exit 1) rather than
    `add_version_min`'s raw, forwarded 2, since this wrapper never forwards
    one argument's exit code as the whole run's.
    `change_dylib` briefly had an unwritable-`FILE` guard of its own that
    exited 2, chosen to match what `mr_apply_file`'s `open(O_RDWR)` then gave
    on the single-family path; that path opens `FILE` read-only now, so there
    is no such code to match and the guard is gone -- `mw_prepare` answers
    for `change_dylib` as it does for every other wrapper here, with the C
    tool's own flat 1.) A CONSIDERED
    refusal
    (the input examined and declined) still exits 1, matching the C tool by
    coincidence, not by construction; but a genuine operational failure
    (open, fstat, read or write failing,
    or a checked allocation that `src/rewrite.c`'s drivers or
    `mi_open`/`mfat_parse` make -- `src/rewrite.h`'s `MR_FAIL` comment
    names them) now exits 2, where the C tool always exited a flat 1. One
    exception, `change_dylib`'s only: an allocation failure INSIDE
    `mg_grow_header` or `mg_plausible` (`src/grow.c`) exits 1, the same as
    every other reason either one refuses. This wrapper reaches both only
    when the header must grow: `mg_grow_header` by definition, and `mg_plausible`
    because `mr_process_thin` runs it only when the rewrite disturbed the
    base-relative values it checks (`src/relations.h`'s
    `mrel_verify_applies`), which for the operations `change_dylib` can ask
    for means only a rewrite that grew the header. (Before that derivation
    shipped, `mg_plausible` ran on every rewrite that was not a pure segment
    rename, unless `MACHO_NO_VERIFY` was set.) `src/rewrite.c`'s own comment
    on that fold has the reasoning. An invocation touching more than one family is
    no longer a sequence of `drydock-macho-rewrite` lines with shell steps between them:
    it is one `printf … | drydock-macho-rewrite FILE OUT`, whose exit code is `me_run`'s own, from
    the same `MR_REFUSED`/`MR_FAIL` vocabulary. The "`change_dylib`: the
    differences" tables below and `compat/add_version_min.sh`'s own header
    have the rest of the detail.

There is a fifth gap this list used to omit entirely: no argument
combination in `tests/compat-sweep.sh`'s 1227-row matrix ever exercises
`mg_grow_header` (`grep -c "grew header pad" tests/compat-matrix.tsv` is 0)
-- `tests/fixture.macho`'s header pad is large enough, and the sweep's
argument vocabulary short enough, that nothing in it ever needs to grow. 72
of those rows DO give one old mixed-family `-grow` two chances to grow
(compat/change_dylib.c issued one grow call for the whole operation set; the
emitted script runs a dylib statement and an rpath statement as
separate passes, each capable of growing on its own),
and no row forces either of those to actually grow. `tests/change_dylib_test.sh`'s "mixed-family
double grow" case closes that gap directly (not through the sweep) with
inputs sized to force a real double grow, and compares the result byte-for-
byte against a single combined `mr_apply_file` call built the way
`compat/change_dylib.c` used to build one. On that case the two routes are
byte-identical: `mg_grow_header` grows by the excess over whatever pad it
sees at the moment, rounded up to a whole page, so growing twice in sequence
composes losslessly with growing once for the summed delta (a page-aligned
grow does not change what the next `ceil` rounds to). That is a property of
the growth algorithm, not a coincidence of one fixture, but it is verified
here only for two sequential grows on one image, not for three or more mixed
families, a fat container, or every possible order.

Stdout is identical everywhere a caller or an in-repo test can see it, and the
places where it is not are **enumerated** with the measurement behind each one
(`tests/compat-matrix.tsv` records what all 1227 enumerated argument
combinations did on both sides, stdout included) — for `change_dylib` and
`fix_macho` in the sections below, and for the other four in their own headers.
`fix_macho` is the one whose stdout is deliberately not reproduced at all.

Stderr is where the wrappers deliberately differ: each one prints the
`drydock-macho-rewrite` equivalent of the invocation it just received, so the caller's
script keeps working while the message teaches the new grammar. That is
the kind form of deprecation, and stdout stays clean precisely so this can
go on stderr.

`tests/known-callers.sh` replays every caller found by reading `install.sh` in full and grepping every `mavericks-*` checkout — the
production `install.sh` wrapper pipeline first — and `tests/wrapper_test.sh`
covers the wrappers' own grammar, exit-code and stdout mapping.

## `change_dylib`: the differences, and what holds each one

`change_dylib` is the tool with the most callers, so nothing here is an
adopted improvement the way `fix_macho`'s five are: every difference is either
a consequence of `drydock-macho-rewrite` not writing the file it is given, or a place where
reproducing the C tool's transcript would have been worse than differing. The
wrapper itself no longer carries them and points here instead. "Held by" is the
assertion that fails if someone reverses the decision.

### `change_dylib`: exit codes

`drydock-macho-rewrite`'s own, **forwarded unchanged**. This is one of only two wrappers
here that maps nothing (`add_version_min` is the other); `fix_macho` and
`patch_macho` collapse every nonzero to one historical code, and
`rename_segment` classifies a refusal ("`rename_segment`: exit codes", below). The C tool returned `mr_apply_file`'s flat 0/1, and 1 is still what a
considered refusal exits — so the coincidence holds for every case a caller had
seen — but the shared vocabulary is no longer flat (`src/rewrite.h`): 0
ok, `MR_REFUSED` (1) for a refusal that read the image and declined,
`MR_FAIL` (2) for a genuine open/fstat/read/write/malloc failure. So an
operational failure now exits 2 where the C tool exited 1, which the "drop-in"
section above lists as a named exception. A multi-statement run speaks that
same vocabulary from `me_run`, so a mixed-family invocation is not a separate
regime.

The codes this wrapper produces **itself** are all 1: `mw_prepare`'s absent,
unwritable and hard-linked refusals, and a failed install. The wrapper never
*invents* a 2; the 2 above is `drydock-macho-rewrite`'s, forwarded. Every `change_dylib`
failure row in `tests/compat-matrix.tsv` is a flat 1, and those rows are the
authority for the codes this wrapper produces itself — not for the ones it
passes through.

One exception to the 1-vs-2 split, `change_dylib`'s only: an allocation failure
INSIDE `mg_grow_header` or `mg_plausible` (`src/grow.c`) is folded into
`MR_REFUSED`, the same as every other reason either one refuses —
`src/rewrite.c`'s comment on that fold has the reasoning. This wrapper reaches
both only when the header must grow: `mg_grow_header` by definition, and
`mg_plausible` because `mr_process_thin` runs it only when the rewrite
disturbed the base-relative values it checks (`src/relations.h`'s
`mrel_verify_applies`) — which, for the operations this wrapper can ask for,
means only a rewrite that grew the header.

Refusing an unmatched operation is a separate fact, not what makes any of the
above conditional: it is `drydock-macho-rewrite`'s default now, not a flag a caller has
to ask for, so this translation opts back OUT of it — `change_dylib`'s
grammar has no spelling for the choice, and never will, since `-change`
matching nothing has always exited 0 and that is compat surface — by heading
its emitted script with the `allow-unmatched` directive, ahead of every
operation.

| the difference | held by |
|---|---|
| an operational failure exits **2**, where the C tool exited a flat 1 | `tests/wrapper_test.sh`: "`drydock-macho-rewrite`'s own code for this input is 2, an operational failure" (the setup, so the two below cannot rot into proving nothing), then "a single-family run forwards `drydock-macho-rewrite`'s own 2 rather than mapping it" and "… and so does a multi-family run, whose code is the bare `drydock-macho-rewrite` form's own" — a DIRECTORY as `FILE`, which `mw_prepare` passes through and `drydock-macho-rewrite`'s read fails on |
| a considered refusal still exits **1**, so the two numbers really differ | `tests/wrapper_test.sh`, "a considered refusal is still the flat 1 the C tool always gave" |
| every refusal the wrapper makes itself exits 1 | `tests/wrapper_test.sh`'s unwritable-`FILE` pair ("exits 1 (the C tool's only failure code), saying so, having changed neither its bytes nor its inode", on both paths), its absent-`FILE` assertion, and `hl_case change_dylib` on both paths. A **failed install** is the one of the four with no assertion anywhere — `mw_finish`'s `mv` has to fail for it, which nothing here can arrange — so it stays stated rather than tested |
| `-change` matching nothing still exits 0, because the translation heads its script with `allow-unmatched` | `tests/wrapper_test.sh`, "a run that changed nothing prints no `Updated` line" (exit 0 on a `-change` aimed at a path the image does not carry) |

### `change_dylib`: stdout

Measured over all 1110 generated `change_dylib` combinations plus the
hand-picked ones (`tests/compat-matrix.tsv`). The row counts are that
measurement, **taken while a multi-family invocation was still a SEQUENCE of
verbs**; what those rows run today is one script, so the counts still
say how many invocations are of each shape and the second bullet describes a
different difference than it did then.

  * **ONE emitted command — 459 rows — stdout is byte-identical.** Both sides
    one pass over the same file with the same ops — the C tool's
    `mr_apply_file` then, one `mr_apply_image` call under `me_run` now. Two lines
    of `drydock-macho-rewrite`'s are reshaped to get there, both consequences of the verb
    writing a temp instead of `FILE`: `mw_run_to_tmp` drops its `Wrote <temp>
    (N bytes)` line, which names a file no caller has heard of, and the wrapper
    prints `Updated FILE (N bytes)` itself after the install, only when the
    bytes changed — the same line `mr_apply_file` used to print, under the same
    condition, naming the same path.
  * **MORE THAN ONE FAMILY — 669 rows — stdout DIFFERS, unavoidably.** Each
    statement of the one script is its own pass over the image, so a
    `header pad …` / `updated …` pair is printed PER STATEMENT where one
    invocation printed one pair. The closing `Updated FILE (N bytes)` line IS
    there, printed by the wrapper on the same terms as above. Every line that is
    there names `FILE`, because that is the path `drydock-macho-rewrite` was handed.
    Reproducing the C tool's exact transcript would mean suppressing
    `drydock-macho-rewrite`'s output and inventing a plausible one, which is worse than a
    difference.
  * **NO command at all — 2 rows** (`change_dylib FILE -grow -grow`). The C tool
    still ran an empty `mr_apply_file` pass and printed its `header pad …` and
    `nothing to change.` lines; the translation is empty by design (no
    `drydock-macho-rewrite` command means "do nothing"), so nothing is printed. No caller
    does this.

No caller parses this tool's stdout as data; the ones that look at it at all
redirect it to `/dev/null`.

| the difference | held by |
|---|---|
| a single-family run's stdout is byte-identical to a one-statement `drydock-macho-rewrite FILE OUT`'s, `Wrote <temp>` reshaped to `Updated FILE` | `tests/wrapper_test.sh`, "a single-family run is byte-identical to `drydock-macho-rewrite`'s, stdout included" — it runs both and compares, with exactly that one line reshaped, so any other wording fails |
| the `Wrote <temp>` line is suppressed even when the caller's path contains a backslash | `tests/wrapper_test.sh`, "a path containing a backslash still suppresses the temp-naming line" (and the companion assertion that the teaching block is still counted and indented) |
| a multi-family run's lines name `FILE`, never the temp | `tests/wrapper_test.sh`, "a multi-family run's stdout names FILE, not a copy", plus "a multi-family run leaves no stray file beside FILE" |
| `Updated FILE (N bytes)` closes a run that changed the bytes, on both paths, and is absent when nothing changed | `tests/wrapper_test.sh`'s `Updated` pair (single- and multi-family) and "a run that changed nothing prints no `Updated` line" |
| an invocation that asks for nothing prints nothing, where the C tool printed two lines | `tests/wrapper_test.sh`, "an invocation that asks for nothing exits 0, prints nothing, and leaves FILE alone"; `tests/translate_test.sh`'s `cd-grow-only` pins the empty emission as text |

### `change_dylib`: the in-place edit

`change_dylib` rewrote `FILE`; `drydock-macho-rewrite` does not write the
file it is given. So the wrapper takes the shared install path —
`mw_prepare` names a temp beside the file `FILE` really is, `mw_retranslate`
re-emits the command with that temp as its output, `mw_run_to_tmp` runs it, and
`mw_finish` `mv`s the temp over the target or discards it when the bytes did not
change, since the C tool wrote nothing in that case.
`drydock-macho-rewrite-compat.sh`'s "the install path" section has the reasoning for each
step. `drydock-macho-rewrite` takes that temp as its `OUT` positional whether the
script is one statement or several, so both shapes install identically.

| the difference | held by |
|---|---|
| **an absent or unwritable `FILE` is refused**, in the C tool's own `perror("open")` words, before `drydock-macho-rewrite` runs. `change_dylib` opened `FILE` `O_RDWR` first, so either failed immediately having changed nothing. No `drydock-macho-rewrite` invocation reproduces that: a form that writes an output opens `FILE` `O_RDONLY` and has no opinion about `FILE`'s mode, and the wrapper installs by rename, which needs the DIRECTORY writable (measured before this check existed: a mode-444 binary replaced, fresh inode, exit 0 — a silent rewrite of a file its owner marked read-only). `test -e`/`test -w` are not `open(O_RDWR)` — they consult the real uid and do not see ACLs, so they can disagree at the edges; they agree on the two cases that reach a caller, and both follow a symlink, which is what is wanted, since the install lands on the symlink's target and it is that file's mode that decides | `tests/wrapper_test.sh`'s unwritable pair, on BOTH paths, asserting exit 1, `open: Permission denied`, and neither the bytes nor the inode moved; and "an absent `FILE` exits 1 with the C tool's own `open()` message" |
| **a hard-linked `FILE` is refused (1)** — new, and the one behaviour a caller can see that no version of `change_dylib` had: the C tool wrote through its own descriptor so every link saw the change, while an install by `mv` would leave the others on the old content. Refused rather than silently split, which is the trade every wrapper on this path makes; `mw_prepare` has the message and the remedy | `hl_case change_dylib` in `tests/wrapper_test.sh`, on both the single- and the multi-family path (exit 1, "hard link" named, both names byte-identical, no temp left); `tests/change_dylib_test.sh` case 14b also asserts the group is still one inode, unsplit |
| **the install is a rename**, so a changed run gives `FILE` a fresh inode and an interrupted one can never leave a half-written binary — and a symlinked `FILE` stays a symlink, with the real target rewritten and its xattrs intact | `tests/change_dylib_test.sh` case 14: 14a (symlink still a symlink to the same name, the real target changed, fresh inode, xattr survived), 14c (the ordinary case still goes through `mkstemp`+rename). Mode and quarantine on the multi-family path: `tests/wrapper_test.sh`, "mode and quarantine survive a MULTI-FAMILY run too" |
| **a writable binary inside a read-only directory now fails**, because creating a temp beside `FILE` and renaming it needs the DIRECTORY writable where the C tool needed only `FILE` itself to be: `mkstemp: Permission denied`, from `drydock-macho-rewrite`'s own write of the temp, with `FILE` untouched | stated, not tested for `change_dylib`: the behaviour is `drydock-macho-rewrite`'s own write, not this wrapper's, and the equivalent case is asserted for `patch_macho` in `tests/wrapper_test.sh`. `compat/add_version_min.sh` and `compat/retag_swift_classes.sh`'s headers record the same shape |

### `change_dylib`: header growth

`-grow` asked the C tool to enlarge the header pad when new load commands did
not fit; without it the tool refused. The wrapper grows whenever they do not
fit, so `-grow` is accepted — it is in the tool's documented usage line,
`change_dylib input [-grow] [-change old new] …` — and asks for nothing.

| the difference | held by |
|---|---|
| **without `-grow`, a short header pad is grown** on an x86_64 PIE executable, announced on stderr, exit 0, where the C tool refused (`don't fit in header pad (... avail); pass -grow to enlarge it`, exit 1, file untouched) | `tests/change_dylib_test.sh`, "long -change (no -grow): grows the header where the original refused" and "... and the grow is announced on stderr"; `tests/compat-matrix.tsv`'s two 3000-character `-change` rows without `-grow` record the refusal as measured |
| **`-grow` is a no-op**: the command emitted with it is the command emitted without it, and the file written is byte-identical | `tests/change_dylib_test.sh`, "-grow is a no-op -- the result is byte-identical to the run without it"; `tests/translate_test.sh`'s `cd-grow-mixed` and `cd-nogrow-mixed` |

### `change_dylib`: atomicity of a mixed-family invocation

`install.sh`'s production line strips two load commands AND rewrites three dylib
paths. `tests/compat-sweep.sh` measured what splitting that one atomic rewrite
into a SEQUENCE of verbs cost: two rows where the C tool refused having written
nothing, while the sequence refused having already written. One script run
closes that at the source rather than around it — `me_run` reads the image once,
applies every statement to it in memory, verifies, and writes once, so a refusal
at any statement leaves `FILE` exactly as it was. That is the C tool's shape,
not an approximation of it. (It writes the temp this wrapper installs, not
`FILE`, so a refusal leaves no temp to install either.)

| the difference | held by |
|---|---|
| a refusal at a later statement leaves `FILE` byte-identical, leaves no temp beside it, and is reported as a refusal rather than as a failed install | `tests/wrapper_test.sh`'s three mid-script assertions: "a refusal at a later statement leaves `FILE` byte-identical, not half-edited", "… and leaves no temp beside it", "… and says the run was refused, not that installing it failed" |
| a run `drydock-macho-rewrite` refuses at the first read leaves nothing beside `FILE` either | `tests/wrapper_test.sh`, "a run `drydock-macho-rewrite` refuses leaves no temp beside FILE" |

### `change_dylib`'s capacity caps

**Enforced in the translation, and now nowhere else.** `drydock-macho-rewrite` used to cap
at the same numbers (`MR_MAX_OPS` 32, `MR_MAX_STRIP` 16, shared via
`src/rewrite.h`) while naming ITS grammar's flags, so passing its message
through would have printed "too many `-append`" where `change_dylib` printed
"too many `-add`" — which is why the counting was put here to begin with. Those
caps sized the verb parsers' arrays; the verbs are gone and an `mr_ops` now
holds at most one operation of each kind, so there is no second count anywhere
to fall back on. `mt_room` in `compat/translate.sh` prints the origin text and
refuses before anything runs. This is also what keeps the fixed-size arrays'
historical stack smash — "Repeated options wrote past their fixed-size arrays;
33 `-change` flags smashed the stack — fixed, PR #9", `docs/PROPOSAL.md` —
fixed rather than reintroduced in shell.

Held by `tests/wrapper_test.sh`'s two cap assertions (`too many -add (max 32)`
and `too many -strip-lc (max 16)`, in `change_dylib`'s own words, plus the file
untouched) and `tests/translate_test.sh`'s `cap-strip-17`, `cap-add-33`,
`cap-ins-33`, `cap-chg-33`, `cap-radd-33` and `cap-shared`.

## Why `fix_macho` could not be wrapped, and what changed

It was attempted as a wrapper once before and measured, on real 10.9, against
the binaries that shipped before the wrappers — and it could not be wrapped,
because a wrapper had to **preserve** behaviour and `fix_macho`'s differs from
the shared rewriter's. It stayed C for a while on that basis.

What changed is not the code but the standard: the repo owner ruled those
differences **improvements to adopt deliberately**. There are six — the sixth
came later, when header growth stopped needing a directive — and this
section is where they are stated — the wrapper itself no longer carries them,
and points here instead.

### `fix_macho`: the adopted divergences

Each row is a case where `fix_macho` and the shared rewriter give different
answers and the shared rewriter's is better, so the wrapper does **not** close
it. "Held by" is the assertion that fails if someone reverses the decision.

| # | the difference, and why adopting it is right | held by |
|---|---|---|
| 1 | **A replacement path longer than the existing command now SUCCEEDS.** `fix_macho` wrote the new path into the existing `LC_LOAD_DYLIB` and refused if it did not fit (`new path '...' too long (320 > 32)`, exit 1, file untouched); `drydock-macho-rewrite dylib -replace` rebuilds the load-command table and fits the longer path into header pad the image already has, exit 0. The limit was an artifact of a rewriter that never learned to resize a command, not a safety property: nothing in `docs/PROPOSAL.md` records a reason for it, and `drydock-macho-rewrite` does not have to inherit the old tools' artificial limits. When the pad itself is too short, that is row 6. | `tests/wrapper_test.sh`, "a longer replacement path is now rewritten into header pad, not refused" |
| 2 | **A chained `-rename_seg` now CHAINS.** `-rename_seg __DATA __X -rename_seg __X __Y` produced `__X` under `fix_macho`, which applied every pair in ONE pass and gave each segment its FIRST match, so the second pair never fired. Each pair is its own pass here — its own `segment rename` statement in the emitted edit script — and the second reads the first's result, so it produces `__Y`. Adopting it is doing what was asked. `compat/translate.sh` refused this shape outright until the ruling, correctly, while a wrapper still had to preserve `fix_macho`'s answer; its `-rename_seg` arm records the reversal. | `tests/wrapper_test.sh`, "a chained `-rename_seg` now produces the SECOND name, not the first" (asserts `__Y` present **and** `__X` absent); `tests/translate_test.sh`'s `fm-chain`, `fm-chain-3` |
| 3 | **The write-back is ATOMIC.** `fix_macho` `lseek`'d to 0 and wrote the whole file back over itself, so a crash, a full disk or a kill mid-write left a corrupt binary. `drydock-macho-rewrite` never writes `FILE` at all: it writes a temp beside it (`wa_write_new`, `src/atomic_write.h` — `mkstemp` + `rename`, carrying `FILE`'s mode, owner and xattrs) and the wrapper installs that temp with one `mv` in the same directory, so the caller's file is either wholly old or wholly new. These tools exist to make binaries loadable; a half-written one is the failure they are supposed to prevent. There is no multi-write caveat: an invocation worth more than one command is one `printf … | drydock-macho-rewrite FILE OUT`, and `me_run` (`src/edit.c`) reads the image once, applies every statement in memory, verifies, and writes once — so a refusal at any statement leaves the temp unwritten and `FILE` exactly as it was. | `tests/wrapper_test.sh`: "a changed run installs by rename, so `FILE` gets a new inode"; "a refusal part way through a multi-statement run leaves `FILE` byte-identical and no temp beside it"; `hl_case fix_macho` ("a hard-linked `FILE` is refused (1), both names untouched", "and no temp was left beside it"). Mode, owner and xattrs: `tests/atomic_write_test.c` under `ctest` |
| 4 | **A fat slice whose edit fails now REFUSES THE WHOLE FILE.** `fix_macho`'s fat loop treated every per-slice failure alike: `process_macho` returned -1 whether the slice was not a Mach-O at all or was one whose edit it refused, and the loop printed `  Skipping arch %u` and carried on, exiting 0 having rewritten the slices it did understand — a partially converted universal binary reported as a success. `mr_process_fat` (`src/rewrite.c`) splits the two: `MR_SKIP` for a slice that is not a 64-bit Mach-O, `MR_ERROR` for one that IS and whose edit failed, and only `MR_ERROR` refuses. Refuse rather than guess. **Narrower than it was first described:** that description read as covering both cases; a slice that is simply not a 64-bit Mach-O is still left unchanged, as `fix_macho` left it, with a different message and exit 0 — but *which* message, and *whether* exit 0, need saying precisely, because neither is what this row used to claim. **No wrapper reaches `mr_process_fat` at all**: `fix_macho` runs `me_run_fat` (`src/edit.c`), so the line a caller sees is that loop's, and there are two of them, chosen by what the `fat_arch` declared — `slice NAME: 32-bit; passed through unchanged` when it declares a 32-bit cputype, `slice NAME: not a 64-bit Mach-O; passed through unchanged` when it declares a 64-bit one over bytes that are not. `mr_fat_slice`'s `not a 64-bit Mach-O; leaving this slice unchanged`, which this row named, is emitted on a path nothing ships. And **exit 0 holds only while some slice is a 64-bit Mach-O**: a container in which none is exits **1** — `drydock-macho-rewrite edit: FILE has no 64-bit slice to edit (it has: arm64, i386); … left unmodified`, nothing written — which is `me_run_fat`'s no-editable-slice refusal, the one thing `mr_process_fat` does not do. (Measured through `build-native/fix_macho`, all three.) | the `MR_SKIP` half, through `fix_macho` on a hand-built two-slice container: `tests/wrapper_test.sh`, "a non-64-bit slice is left unchanged and the other slice is still rewritten", which asserts the line above as `slice i386: 32-bit; passed through unchanged` — so the distinction cannot be quietly widened. The other declared shape and the byte-shapes under it: `tests/cli_test.sh`'s "A SLICE IS WHAT ITS BYTES ARE" block. The two loops' agreement, and this row's one exception to it: `tests/change_dylib_test.sh`'s "two fat loops" block, which drives both over one corpus. The `MR_ERROR` half, at the verb: `tests/cli_test.sh`'s "MR_ERROR: one bad slice refuses the WHOLE fat file" block (message, slice label, per-slice reason, and the file unmodified) |
| 5 | **A `-change` aimed at this dylib's own install name now matches NOTHING**, instead of rewriting it. `compat/fix_macho.c`'s match block opened on `mo_is_ordinal_lc(lc->cmd) \|\| lc->cmd == LC_ID_DYLIB` and then ran the `changes[]` loop with no `LC_ID_DYLIB` exclusion, so `-change <this dylib's own install name> NEW` rewrote the dylib's identity — even though the file's own comment said "nothing in `changes` is ever meant to match it". `src/rewrite.c` guards it now. Adopting it is right because (a) `install_name_tool` spells identity `-id` and its `-change` never touches `LC_ID_DYLIB`, so `drydock-macho-rewrite` matches the tool everyone already knows; (b) `fix_macho.c`'s own comment stated the contract `drydock-macho-rewrite` now enforces, so this is the C being fixed, not contradicted; (c) silently rewriting a dylib's own install name from an operation aimed at a DEPENDENCY is exactly the invisible edit this work exists to make visible. Measured: both sides exit 0 and the bytes differ, with nothing on stderr naming the reason (transcript below). | `tests/wrapper_test.sh`, "-change at a dylib's own install name leaves `LC_ID_DYLIB` unchanged, reported unmatched, while a real dependency's `-change` in the same run still lands" — one run, both halves, on a dylib fixture built for it |
| 6 | **A header pad too short for the replacement is now GROWN**, on an x86_64 PIE executable: the image base is lowered to make room, announced on stderr, exit 0. `fix_macho` had no `-grow` and never enlarged a header. Adopted by the repo owner's ruling for every wrapper: the engine never writes its input and the grow verifies itself, so refusing bought nothing. A non-PIE executable or a dylib is still refused, exit 1, file untouched | `tests/wrapper_test.sh`, "a replacement the pad cannot hold grows the header, announced"; its `fix_macho` mid-script refusal clears `MH_PIE` on its copy so that it still refuses |

#### The measurement behind row 5

Taken on copies of the same `-install_name /tmp/aaa/libfoo.dylib` dylib, and
left exactly as it was read off the two runs:

```
old:  Changed: /tmp/aaa/libfoo.dylib -> /tmp/bbb/libfoo.dylib
      File updated: a.dylib          rc=0   otool -D -> /tmp/bbb/libfoo.dylib
new:  macho9: /tmp/aaa/libfoo.dylib matched nothing
      b.dylib: nothing to change.    rc=0   otool -D -> /tmp/aaa/libfoo.dylib
cmp a.dylib b.dylib -> differ
```

That transcript is the measurement AS TAKEN. Since 2026-09-12 the tool names
itself in everything it prints, so today that line reads `drydock-macho-rewrite: ...
matched nothing`; only the name moved. Updating the transcript in place would
falsify a record rather than refresh a description — the same reason
`tests/compat-matrix.tsv` still names the tools it measured.

### `fix_macho`: two more differences, NOT on the adopted list

Both are consequences of travelling through the shared rewriter
(`mr_apply_image`, `src/rewrite.h`) at all rather than choices the conversion
made, both are shared with every statement that rewrites load commands, and
both are reported rather than worked around.

| the difference | held by |
|---|---|
| **`mg_plausible`.** The rewriter runs that gate before writing only when the run disturbed what it checks — the gate asks an OFFSET question about base-relative values, and `src/relations.h`'s `mrel_verify_applies` decides. Of the operations this driver offers, only a header grow disturbs them, so in practice `fix_macho`'s replacement reaches this gate where `fix_macho` itself had none, and skips it where the rewrite moved no offset. It is a check on the INPUT, not on what the rewrite did. | `tests/wrapper_test.sh`'s `mg_plausible` pair on `tests/mkimplausible.c`'s fixture — the fixture is refused for `fixups set classic`, which disturbs the relation, and renamed successfully — and `tests/cli_test.sh`'s "segment does NOT meet the `mg_plausible` gate" block at the verb |
| **`LC_LAZY_LOAD_DYLIB`.** `mo_map_build` (`src/ordinals.c`) refuses any image carrying one, up front, before it looks at what the operations are. `fix_macho` never built an ordinal map and rewrote such an image happily. `compat/rename_segment.sh`'s header has the measurement (on `/usr/lib/libxcselect.dylib`) and the note that the smallest fix is a change to `drydock-macho-rewrite`, not to a wrapper. | `tests/change_dylib_test.sh`'s `LC_LAZY_LOAD_DYLIB` case (refusal, the refusal naming the load command, and the input untouched) — through `change_dylib`, on the same shared driver, and it SKIPs loudly where the host's linker will not emit one |

### `fix_macho`: exit codes

0 and 1, the only two `fix_macho` had — so **every nonzero from `drydock-macho-rewrite` is
mapped to 1**. It is the same mapping `compat/patch_macho.sh` makes, and for
the same reason: `drydock-macho-rewrite`'s own
`EX_FAIL` is 2, a value no `fix_macho` caller has ever seen, and forwarding it
would invent a third outcome for a grammar that has two. `EX_REFUSED`, 1, is
not the problem — it already coincides with `fix_macho`'s own flat failure code
for any of the ordinary considered refusals this translation's
`dylib`/`load-command`/`segment` statements can reach (bad magic, no room to
grow, and the rest of `src/rewrite.h`'s list). The one refusal this
translation deliberately avoids reaching is the one an unmatched operation
gets by default now, "an operation matched nothing" promoted to
`MR_REFUSED`: the emitted script heads with `allow-unmatched`, precisely so
that refusal never fires. It would not have needed mapping either way, being
1 like everything else the mapping collapses.

Held by `tests/wrapper_test.sh`'s exit-fold pair — `drydock-macho-rewrite`'s own code for
an unreadable `FILE` is 2, and `fix_macho` on the same input exits 1 — and by
"`-strip_build_version` with nothing to strip exits 0, having written nothing",
which is the assertion that fails if the translation ever stops asking for
`allow-unmatched`.

### `fix_macho`: stdout is not reproduced

That is deliberate too. `fix_macho` printed `Processing thin Mach-O:` /
`Processing arch N at offset M:` / `  Changed: X -> Y` / `  Removed
LC_BUILD_VERSION (N bytes)` / `  Renamed segment 'A' -> 'B'` / `File updated:
F` / `No changes needed: F`. None of it survives. What a caller sees now is
`drydock-macho-rewrite`'s own reporting, plus — for the one line that carried information a
caller could act on — the per-operation unmatched report on **stderr**:

```
drydock-macho-rewrite: /usr/lib/libFoo.dylib matched nothing        (a -change)
drydock-macho-rewrite: no load command of kind build-version to delete
```

That is strictly more than `No changes needed: F` said, which could not
distinguish which of several operations missed. Those two lines are quoted with
the `drydock-macho-rewrite:` prefix and all, because that is what a caller really sees: the
report names the operation in `drydock-macho-rewrite`'s grammar, which is the grammar this
wrapper teaches (`src/rewrite.c`'s `mr_report_unmatched` says why the prefix is
the tool's name and not `argv[0]`).

Refusing on an unmatched operation is `drydock-macho-rewrite`'s own default now, and **this
translation must opt back out of it** — which is why its script heads with
`allow-unmatched`: `fix_macho` exited 0 when an operation matched nothing,
and that is compat surface.

Neither `tests/EXPECTED` nor `tests/known-callers.sh`'s sha256s have an opinion
about any of these strings — both hash converted file bytes with the tools'
output sent to `/dev/null`. What reads these two lines is
`tests/wrapper_test.sh`, and the closing `Updated FILE (N bytes)` line (the one
`mr_apply_file` printed while the verbs still wrote `FILE`, not `fix_macho`'s
own `File updated: F`) is pinned there too, by a byte comparison of the
wrapper's whole stdout against a one-statement `drydock-macho-rewrite FILE OUT`'s.

### `fix_macho`: the in-place edit

`fix_macho` rewrote the file it was given; `drydock-macho-rewrite` does not. So the wrapper takes the shared install path — `mw_prepare` names a temp
beside the file `FILE` really is, `mw_retranslate` re-emits the command with
that temp as its output, `mw_run_to_tmp` runs it and drops the `Wrote <temp>`
line no C tool ever printed, and `mw_finish` `mv`s the temp over the target or
discards it when the bytes did not change. `drydock-macho-rewrite-compat.sh`'s "the install
path" section has the reasoning for each step. `drydock-macho-rewrite` takes that temp
as its `OUT` positional whether the script is one statement or several, so both
shapes install identically.

Three consequences, all of them `fix_macho`'s alone to explain:

* **The writability check** comes with it, inside `mw_prepare`. `fix_macho`
  opened the file `O_RDWR` before it looked at it, so an absent or unwritable
  file failed immediately, with no analysis and no write. No `drydock-macho-rewrite`
  invocation reproduces that any more — a form that writes an output opens
  `FILE` `O_RDONLY`, and the run finds out it cannot write only when it
  writes, at the END of the run, with a different message — so
  `mw_require_writable` is the only thing that does. `test -w` is not
  `open(O_RDWR)`: it consults the real uid and does not see ACLs, so it can
  disagree at the edges. It agrees on the two cases that actually reach a
  caller (absent, and mode-denied), and both sides exit 1 either way. Held by
  `tests/wrapper_test.sh`'s absent-file and unwritable-file assertions, both on
  the MULTI-command path, which is the path where `drydock-macho-rewrite` would otherwise
  succeed and silently replace a mode-444 binary.
* **A hard-linked `FILE` is refused (exit 1)**, the one behaviour here no
  version of `fix_macho` had: it wrote through its own descriptor, so every link
  saw the change, while an install by `mv` would leave the others on the old
  content. Every wrapper on this install path makes the same trade;
  `mw_prepare` has the message and the remedy. Held by `hl_case fix_macho` in
  `tests/wrapper_test.sh`.
* **A writable binary in a read-only directory now fails**, because creating a
  temp beside `FILE` needs the DIRECTORY writable where the C tool needed only
  `FILE` itself to be: `mkstemp: Permission denied`, from `drydock-macho-rewrite`'s own
  write of the temp, with `FILE` untouched.

### `fix_macho`'s capacity caps

Its two repeated options are still capped, in `compat/translate.sh`'s
`mt_room`, with the same wording — `fix_macho` held `-change` in a
`changes[32]` and `-rename_seg` in a `renames[16]`, and for most of its life
neither had a bounds check, the same stack smash `docs/PROPOSAL.md` records
being fixed in `change_dylib` alone ("Repeated options wrote past their
fixed-size arrays; 33 `-change` flags smashed the stack — fixed, PR #9"). The
C file grew an `FM_ROOM` check before it retired; `mt_room` is where that check
lives now, printing the same `too many -change (max 32)` / `too many
-rename_seg (max 16)` and refusing before anything runs. The `-rename_seg` cap
exists nowhere else, and never did: `drydock-macho-rewrite` sees one rename at a time
either way — its `segment rename` statement sees one pair, and always did — so
nothing downstream would ever count them. That is now true of every cap here,
one statement per operation being the only shape `drydock-macho-rewrite` has. Held by
`tests/wrapper_test.sh`'s two cap assertions (the wording, and the file
untouched) and `tests/translate_test.sh`'s `fm-cap-*` cases.

`fix_macho`'s only caller in this repo was `tests/change_dylib_test.sh`.

## `rename_segment`: exit codes

`rename_segment` had three answers: 0 renamed, 2 nothing matched, 1
everything else. A `segment rename` that matches nothing is `EX_REFUSED`, and
so is one on an `LC_LAZY_LOAD_DYLIB` binary, so the wrapper classifies an
`EX_REFUSED` by asking `drydock-macho-rewrite info --thin FILE` whether a
segment named OLD exists. The match rule is the C's own: OLD cut to 16 bytes,
compared with `strncmp` over the 16-byte field (`src/segname.c`).

| `rename_segment` answer | when | held by |
|---|---|---|
| 0 | renamed | `tests/wrapper_test.sh`, "rename_segment: prints its own one-line message, not mr_apply_file's chatter" |
| 2, silent, file untouched | `EX_REFUSED` and OLD absent | "rename_segment: nothing matched exits 2, silently, without writing", "...and stderr is exactly the teaching block, never drydock-macho-rewrite's own refusal", and the stub case "a fake tool's exit 1 is 'nothing matched' when OLD does not exist, no matter what it says" |
| 2, silent | `EX_REFUSED` on an `LC_LAZY_LOAD_DYLIB` binary and OLD absent: the C tool's own answer | "rename_segment: LC_LAZY_LOAD_DYLIB with an absent OLD exits 2, silently, as the C tool did" |
| 1, refusal shown | `EX_REFUSED` and OLD present (`LC_LAZY_LOAD_DYLIB` is the real case) | "rename_segment: LC_LAZY_LOAD_DYLIB is a real refusal (exit 1), shown, once classified 'present'", and the stub case "a fake tool's exit 1 is shown, not swallowed, when OLD DOES exist" |
| 1, shown | `EX_FAIL` or any other nonzero | the stub case "rename_segment: EX_FAIL stays 'everything else' -- shown, and exit 1, not 2" |
| 1, shown | the classification query itself fails | no assertion: the thin-only gate runs the same query first, so only a file that changes between the two calls reaches it |
| 1, loud, file untouched | exit 0 with no `  Rename segment:` line (a mismatched install) | the stub case "rename_segment: a tool that exits 0 without naming a rename is a mismatched install: exit 1, loud, file untouched" |

A known limit: `info` prints a segment name with `%.16s`, so a name that
itself contains ` vmaddr=` makes its line ambiguous. After `segment rename
__PAGEZERO 'A vmaddr=0x1'`, `rename_segment FILE A ZZ` finds `A` "present",
and exits 1 with the refusal shown where the C tool exited 2 silently. No grep
over `info`'s text can be exact for such a name.

## `insert_dylib`: not one of the six, and the differences it has from the fork

`insert_dylib.sh` wraps a grammar this repo never shipped:
[`Wowfunhappy/insert_dylib`](https://github.com/Wowfunhappy/insert_dylib)
(commit `bd221b8`), a well-known tool for adding a dylib load command to an
existing binary. It has **no known caller** — `install.sh` never fetched it,
and no checkout on this machine invokes it — so it is convenience for someone
who already knows this fork's grammar, not compatibility debt, and
`tests/known-callers.sh` is silent for it on purpose. `tests/compat-sweep.sh`
is silent for it too: that matrix is frozen for the six historical tools
(`tests/compat-sweep.sh:23,169`), and regenerating it to admit a seventh would
destroy what it exists to preserve. `tests/insert_dylib_test.sh` is this
tool's whole test surface instead.

`insert_dylib [flags] dylib_path binary_path [new_binary_path]` becomes:

| flag | statement(s) |
|---|---|
| *(none)* | `dylib append DYLIB` |
| `--weak` | `dylib append DYLIB`, `dylib retype DYLIB weak` |
| `--strip-codesig` | also: `load-command delete codesig` |
| `--no-strip-codesig` | nothing extra, and the wrapper never asks about it |

`--strip-codesig`'s `load-command delete codesig` statement can match
nothing — on a binary carrying no code signature to begin with, the way
`tests/fixture.macho` itself does — and that is **not** a divergence from
the fork: the fork exited 0 there too, doing nothing rather than refusing.
Refusing an unmatched operation is `drydock-macho-rewrite`'s default now, so
`mt_tr_insert_dylib` (`compat/translate.sh`) heads its emitted script with
the `allow-unmatched` directive to preserve that upstream fidelity, exactly
as `change_dylib`'s and `fix_macho`'s translations do for the same reason
(their own "exit codes" sections above). Held by
`tests/insert_dylib_test.sh`, "--strip-codesig on an unsigned binary: exits
0" and "... OUT still has the dylib appended".

`--inplace`, `--overwrite` and `--all-yes` never become a statement: they
choose `OUT` and, in the wrapper, whether each of the fork's five prompts is
asked and how it answers. Every prompt reads `/dev/tty`, never stdin — stdin
is the statement channel to `drydock-macho-rewrite`, same as every other wrapper here
— so with `--all-yes` none of the five is asked, and with no `/dev/tty` to
ask on and no `--all-yes`, the wrapper refuses naming `--all-yes` rather than
blocking a build script forever on a read nothing will ever answer.

| the difference from the fork | held by |
|---|---|
| 32-bit input is **refused**, where the fork handles it | `tests/insert_dylib_test.sh`, "32-bit refused" — this toolkit refuses 32-bit input everywhere, deliberately, not a gap specific to this tool (`docs/prior-art.md`) |
| an image carrying `LC_LAZY_LOAD_DYLIB` is **refused**, where the fork proceeds | `tests/insert_dylib_test.sh`, "unknown load command (LC_LAZY_LOAD_DYLIB): refuses" — `dylib append` runs through `src/ordinals.c`'s `mo_map_build`, the same refusal `tests/change_dylib_test.sh` case 15 pins, inherited here with no code of this wrapper's own; SKIPs on a host whose linker cannot produce one |
| exit codes are `drydock-macho-rewrite`'s own 0/1/2, **forwarded unchanged**; the fork exits 1 for everything | matches `change_dylib` and `add_version_min`'s own choice, for the same reason: it costs nothing to keep the distinction `drydock-macho-rewrite` already makes between a considered refusal and an operational failure. Not separately tested here beyond "exits 1"/"exits 0" on each case — there is no C binary left to compare a 2 against |
| output **bytes** are not claimed equal to the fork's | never measured; there is no C `insert_dylib` binary in this repo's build to compare against |
| the fork's prompt 3 ("it doesn't seem like there is enough empty space") is **not asked**: on an x86_64 PIE executable a short header pad is grown, announced on stderr, exit 0, where the fork asked before its own expansion. Anything that cannot grow — a dylib, a non-PIE executable — is refused in `dylib append`'s words, forwarded through the exit code above | `tests/insert_dylib_test.sh`, "no room: the header grows, announced" |
| `--inplace` together with an explicit `new_binary_path` is **refused**, where the fork silently picks one and never reads the other (`--inplace` wins; `main.c`'s `if(!inplace_flag) { ... }` block that would consume `argv[3]` is skipped entirely when `--inplace` is set, so the named file is never even opened). Matching the fork here would mean silently ignoring an output path the caller wrote out by hand and overwriting their input instead — the data-loss shape this toolkit refuses rather than guesses through everywhere else, and there are no known callers of this tool to break by refusing. `compat/translate.sh`'s `mt_id_parse` refuses it unconditionally, before any prompt, so `--all-yes` does not make it succeed either | `tests/insert_dylib_test.sh`, "--inplace + new_binary_path" (three assertions: refuses exit 1 even with `--all-yes`, names both `--inplace` and the path, and leaves both the input and the named path untouched) |
| on a real dylib whose header pad is too small for the new load command and which carries no `__PAGEZERO` to shrink (true of every dylib — only executables have one), **the fork reports success and exits 0** while its own stderr admits `__PAGEZERO segment not found, cannot expand header.` The file it writes **fails this toolkit's own `drydock-macho-rewrite verify`** (`mg_plausible` refuses it): the fork's own header-expansion path did not actually expand anything, and nothing downstream of that checks. This wrapper refuses cleanly instead — `macho_grow: only MH_EXECUTE can be grown ...`, then `ERROR: ... don't fit in header pad (... avail), and the header could not be grown (see above)`, exit 1, input untouched. This is not a case where this toolkit needs to catch up: the fork is wrong here, and the four checks named just above this table (plus `mg_verify`/`mg_plausible`) are exactly why this side catches it and the fork does not | `tests/insert-dylib-diff.sh`'s 2026-09-20 run (`tests/README.md`), reproduced on `/usr/lib/swift/libswiftDarwin.dylib`, a real thin (non-fat) system dylib, so the differential's Mach-O-validity check ran on the fork's own output rather than being skipped for being unreadable fat |
| on an unwritable `--inplace` target, the fork's own diagnostic (`main.c`'s `printf("Couldn't open file %s\n", binary_path)`) lands on **its stdout**, not stderr; this wrapper's (`mw_require_writable`'s `open: Permission denied`) lands on **stderr only**. Both sides still exit 1 having touched nothing — this is a stream difference in the fork's own C, not a behaviour difference, and not chased | `tests/insert-dylib-diff.sh`'s 2026-09-20 run (`tests/README.md`), reproduced on several root-owned binaries under `/usr/bin` (`atq`, `calendar`, `cupstestppd`, `newgrp`) |

### `insert_dylib`: the adopted divergence

Not a difference from the fork — the fork does read fat containers
(`docs/prior-art.md`'s prior-art table). This wrapper's own answer changed
underneath it instead, found by auditing what reads `info`'s output rather
than designed for, and the repo owner ruled it adopted rather than
suppressed. Same shape as `fix_macho`'s adopted divergences above — an
earlier answer and the current one disagree, and the current one is
better — just measured against this wrapper's own prior commit rather than
a predecessor tool.

| # | the difference, and why adopting it is right | held by |
|---|---|---|
| 1 | **Both interactive prompts now fire on a FAT binary.** Prompt 1 ("LC_CODE_SIGNATURE load command found. Remove it?") and prompt 2 ("Binary already contains a load command for that dylib. Continue anyway?") each read `drydock-macho-rewrite info $MT_ID_BIN` and grep its output. While plain `info` was a bare `mi_open` it failed outright on a fat container — `not a readable 64-bit Mach-O`, stderr discarded by this wrapper's own `2>/dev/null` — so both greps ran over empty input and neither prompt was ever asked: a fat binary silently skipped both questions, and the fork's own behaviour was not reproduced so much as accidentally bypassed. `info` reads fat containers now, printing "the same lines for a thin file and for each slice of a fat container" (`info_image`'s own header comment, `cli/drydock-macho-rewrite.c`) — the identical `  ordinal=N path=` and `LC[N] LC_CODE_SIGNATURE` lines, each at its usual indentation, once per slice. Neither prompt's grep is scoped to one slice, so each fires the instant *either* slice matches — over the union of the slices, not one arbitrarily chosen one. Adopting it is right because the prompts exist to stop a caller doing something they did not mean, and a fat binary is where that matters most. | `tests/wrapper_test.sh`, "insert_dylib: the duplicate-dylib prompt fires on a fat binary whose second slice alone names the dylib" |

## `bake-mavericks-shim`

`bake-mavericks-shim.sh` presents the command line of **Wowfunhappy's
`bake-mavericks-shim.py`**, whose design this is: take a binary that only runs
as

```sh
DYLD_FORCE_FLAT_NAMESPACE=1 DYLD_INSERT_LIBRARIES=/usr/local/lib/libMavericksLegacySystem.B.dylib ./binary
```

and make it load the shim itself, binding to the shim exactly the imports the
shim exports and nothing else — the self-adjusting intersection his script
introduced. The Python is not part of this repo; this is his behaviour
implemented through `drydock-macho-rewrite`, not his code. It has no known caller, so
`tests/known-callers.sh` and `tests/compat-sweep.sh` are silent for it, and
`tests/bake_mavericks_shim_test.sh` is its test surface.

```
bake-mavericks-shim INPUT [OUTPUT] [--shim PATH]
```

`OUTPUT` defaults to `INPUT.selfcontained` and the shim to
`/usr/local/lib/libMavericksLegacySystem.B.dylib`. The wrapper reads
`drydock-macho-rewrite exports SHIM` and `drydock-macho-rewrite imports INPUT`
and runs one edit script:

| statement | when |
|---|---|
| `fixups set classic` | `INPUT` has chained fixups |
| `load-command delete codesig` | `INPUT` is signed |
| `dylib append SHIM` | `INPUT` does not already load `SHIM` |
| `import redirect SYMBOL LIBRARY SHIM` | once per bind whose symbol `SHIM` exports, for every library it is imported from |

Its stdout is the Python's summary — how many symbols the shim exports, whether
a signature was stripped, the shim's ordinal and whether it was newly added,
how many imports moved and which — and the weak-bind warning is the Python's
too. `OUTPUT` is left mode 755, as the Python leaves it, and may name `INPUT`.

| the difference from the Python | held by |
|---|---|
| an import is identified by **symbol and library**: each library a symbol is imported from gets its own `import redirect`, and the wrapper selects all of them, which is the Python's selection stated exactly. A bind with a special ordinal (flat lookup, self, main executable) names no library and is **not** redirected; the Python re-points every regular bind of a shim symbol, whatever ordinal it had | `tests/import_redirect_test.sh`, "same name, other library"; `tests/bake_mavericks_shim_test.sh`, "flat" |
| a **fat** input is baked slice by slice; the Python refuses it | `tests/bake_mavericks_shim_test.sh`, "fat" |
| a **chained-fixups** input is converted with `fixups set classic` first; the Python refuses it | `tests/bake_mavericks_shim_test.sh`, "chained" — it SKIPs on a host whose linker cannot emit chained fixups, 10.9 among them |
| **ordinals above 15** work: a bind-stream opcode is re-encoded as `SET_DYLIB_ORDINAL_ULEB`, and a lazy one wherever its opcode is wide enough. The Python dies whenever the shim's ordinal is above 15 and a regular bind moves. A lazy bind whose opcode is one byte still cannot name an ordinal above 15 on either side, because no lazy program may grow | `tests/import_redirect_test.sh`, the "ordinal>15" block, whose last assertion is that refusal |
| the **symbol table**'s undefined entries are redirected with the binds, so `nm -m` and a later `dylib delete` agree with dyld; the Python leaves them naming the old library | `tests/import_redirect_test.sh`, "regular: ... the symbol table's undefined _a_data" |
| the result is **verified before it is written**: both streams are read back and every bind compared with what it was. The Python writes what it computed | `tests/import_redirect_test.sh`, "verification" |
| the bind stream is rewritten **opcode for opcode**, in place when that fits; the Python re-emits the whole stream in its own encoding. When the stream has to grow, both put it at the end of `__LINKEDIT` | compared bind by bind with `dyldinfo` in the differential below |
| the shim's exports come from its **export trie** (`drydock-macho-rewrite exports`), not from `nm -gU`'s text | `tests/import_redirect_test.sh`, "exports" |
| `load-command delete codesig` removes the load command and **leaves the signature's bytes** in `__LINKEDIT`; the Python truncates them and shrinks `__LINKEDIT` | `tests/bake_mavericks_shim_test.sh`, "signed" (the command is gone; the bytes are not asserted either way) |
| the appended `LC_LOAD_DYLIB` records **version 0.0.0**, as every `dylib append` does, so any build of the shim satisfies it; the Python records 1.0.0, and dyld refuses a shim built without `-compatibility_version 1.0` | the differential below, which had to build its shim with that flag for the Python's output to load |
| the summary's `bind data:` names **where** each table went (`regular table in place`, `regular table relocated to the end of __LINKEDIT`, `lazy table rewritten in place`) without the Python's byte counts; `drydock-macho-rewrite`'s own report on stderr has the sizes | `tests/bake_mavericks_shim_test.sh`, "the Python's summary lines" |
| stderr also carries `drydock-macho-rewrite`'s report of the edit, and a weak bind of a redirected symbol is warned about twice: the Python's list, then the engine's line for that symbol | `tests/bake_mavericks_shim_test.sh`, "weak" |
| with **no room in the header** for the shim's load command, the Python dies with `no room in the Mach-O header to add a load command`, exit 1; this grows the header on an x86_64 PIE executable, announced on stderr, and the baked result runs. What cannot grow is refused in `dylib append`'s words, exit 1, nothing written | `tests/bake_mavericks_shim_test.sh`, "grow: no header room for the shim" and "... the grown, baked binary calls the shim's functions" |
| exit codes are `drydock-macho-rewrite`'s 0/1/2, **forwarded**; the Python exits 1 for everything but a usage error, which is 2 on both sides | as for `insert_dylib`, above |
| an image carrying `LC_LAZY_LOAD_DYLIB` is **refused**, as everywhere in this toolkit; the Python counts it as an ordinal | `dylib append` refuses it first, through `src/ordinals.c`'s `mo_map_build`, which `tests/change_dylib_test.sh` case 15 pins; `import redirect` refuses it again on its own |

### `bake-mavericks-shim`: the differential

Before the Python was deleted from the working tree, both were run over the
same inputs on 10.9.5 and compared by what they mean rather than their bytes:
every bind (`dyldinfo -bind -lazy_bind -weak_bind`), the `imports` report, the
load-command list, the summary lines, and the output of running both results
and the input. The inputs, and the Python's sha256, are in the message of the
commit that added this wrapper.

