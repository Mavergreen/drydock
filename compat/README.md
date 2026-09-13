# compat/

The six original entry points, kept for compatibility. All six are now
`/bin/sh` wrappers around `machotool`. There is no C left in this directory.

> **The goal is met.** The retirement plan's headline was "`macho9` becomes
> the only Mach-O rewriting binary this repo ships." It is: `compat/` holds
> six shell wrappers and two shell support files, and `machotool` is the only
> binary `CMakeLists.txt` builds or installs. `fix_macho` was the holdout —
> see "Why `fix_macho` could not be wrapped, and what changed" below, which is
> the record of what adopting its five divergences cost and why that was the
> right call rather than a shortcut.

| installed name | what it is now |
|---|---|
| `patch_macho` | `patch_macho.sh` → `machotool declassify IN OUT`, installed over `OUT` |
| `change_dylib` | `change_dylib.sh` → `machotool lc` / `dylib` / `rpath`, or `machotool edit FILE OUT -` when more than one of those |
| `add_version_min` | `add_version_min.sh` → `machotool minos FILE OUT 10.9`, installed over `FILE` |
| `rename_segment` | `rename_segment.sh` → `machotool segment FILE OUT OLD NEW` |
| `retag_swift_classes` | `retag_swift_classes.sh` → `machotool retag-swift FILE OUT`, once per file, installed over each `FILE` |
| `fix_macho` | `fix_macho.sh` → `machotool lc` / `dylib` / `segment`, or `machotool edit FILE OUT -` when more than one command's worth (two renames already are) |

plus the two files every wrapper sources:

| file | installed as | what it does |
|---|---|---|
| `translate.sh` | `machotool-translate.sh` | old argv → the `machotool` command line(s) it means. Pure text; runs nothing. |
| `machotool-compat.sh` | `machotool-compat.sh` | finds `machotool`, prints the teaching message, and runs the translation. |

## Why the names are unchanged

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

**A wrapper cannot work without `machotool`, `machotool-compat.sh` and
`machotool-translate.sh` sitting in the same directory.** `install.sh` fetches
`patch_macho`, `change_dylib` and `add_version_min` **by name**, three files;
those three now need three more beside them. Fetch the three alone and you get
three names that cannot run.

That is inherent to replacing the binaries with wrappers at all, not to how
these particular ones are written, and it is why everything installs **flat**
into one `bin` rather than into a `libexec/` subdirectory — a flat layout
needs only extra file names from that script, where a subdirectory would need
it restructured.

**Nobody has told whoever owns that script.** `install.sh` lives at
`mavericksforever.com` and is not this repo's to change; the retirement plan's
Task 3 is already blocked on it moving, and this is a second, earlier reason
the same conversation has to happen. Until it does, a CDN built from this repo
would ship three names that cannot run. `.github/workflows/release.yml` puts
all six files in the release artifact, which is the most this repo can do on
its own.

## What "drop-in" means here, precisely

The exit codes are identical to the C tools', and the rewritten file's bytes
are identical everywhere `tests/differential.sh` and `tests/compat-sweep.sh`
check them, with four known exceptions, truthfully not all the same KIND of
known: one reproduced on a real file (one out of 300 in the differential
corpus, below), one argued unreachable in practice rather than observed, and
two true by construction rather than by measurement -- they follow
directly from reading what the wrappers' code does, not from a corpus
row that exhibits them, so no file "reproduces" them and no argument is needed
for why they would be rare:

  * `rename_segment` on a binary carrying `LC_LAZY_LOAD_DYLIB` refuses where
    the C tool renamed, because the shared rewriter builds its
    library-ordinal map before it looks at whether any operation could
    renumber. `compat/rename_segment.sh`'s header has the measurement. It is
    one file out of 300 in `tests/differential.sh`'s corpus, and closing it
    means changing `machotool`.
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
    the shared rewrite drivers' (`mr_apply_file`, `mv_add_version_min`) own
    exit code verbatim, with no mapping at all -- unlike `fix_macho`,
    `patch_macho` and `rename_segment`, which translate every nonzero
    machotool exit to one flat historical code, and `retag_swift_classes`,
    which has its own real 1-vs-2 mapping (`compat/retag_swift_classes.sh`'s
    header has it) and is likewise unaffected by this. (EVERY wrapper whose
    verb now writes an output the wrapper installs -- all six, `patch_macho`
    included: its verb's output goes to a temp beside the `OUT` it was asked
    for, and is installed onto it --
    has refusals of its OWN on top of that,
    exiting 1, made before machotool runs for the argument in question: an
    absent or unwritable `FILE`, a `FILE` carrying other hard links, and a
    failed install. Those are the wrapper's, not a forwarded code -- and for
    `retag_swift_classes` an absent or unwritable argument is a WORDING
    divergence too: `tests/compat-matrix.tsv`'s rows for that case (measured
    before the wrapper's own pre-check began answering first) have both
    sides agreeing on `perror(path)`'s
    "`<path>: No such file or directory`", which is still what
    `mswift_retag_file` itself prints when machotool actually reaches the
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
    every other reason either one refuses -- and it needs no `-grow`.
    `change_dylib` reaches `mg_grow_header` only through `--allow-grow`,
    but `src/rewrite.c` runs `mg_plausible` on every rewrite that is not a
    pure segment rename -- every rewrite `change_dylib` can ask for --
    unless `MACHO_NO_VERIFY` is set. `src/rewrite.c`'s own comment on that
    fold has the reasoning. An invocation touching more than one family is
    no longer a sequence of `machotool` lines with shell steps between them:
    it is one `machotool edit FILE OUT -`, whose exit code is `me_run`'s own, from
    the same `MR_REFUSED`/`MR_FAIL` vocabulary. `compat/change_dylib.sh`
    and `compat/add_version_min.sh`'s own headers have the rest of the
    detail.

There is a fifth gap this list used to omit entirely: no argument
combination in `tests/compat-sweep.sh`'s 1227-row matrix ever exercises
`mg_grow_header` (`grep -c "grew header pad" tests/compat-matrix.tsv` is 0)
-- `tests/fixture.macho`'s header pad is large enough, and the sweep's
argument vocabulary short enough, that nothing in it ever needs to grow. 72
of those rows DO give one old mixed-family `-grow` two chances to grow
(compat/change_dylib.c issued one grow call for the whole operation set; the
emitted `machotool edit` script runs a dylib statement and an rpath statement as
separate passes under one `allow-grow`, each capable of growing on its own),
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

Stdout is identical everywhere a caller or an in-repo test can see it, and
each wrapper's own header **enumerates** the places where it is not, with the
measurement behind each one (`tests/compat-matrix.tsv` records what all 1227
enumerated argument combinations did on both sides, stdout included). The one
exception is `fix_macho`, whose stdout is deliberately not reproduced at all —
see below.

Stderr is where the wrappers deliberately differ: each one prints the
`machotool` equivalent of the invocation it just received, so the caller's
script keeps working while the message teaches the new grammar. That is the
retirement plan's "phase one", and stdout stays clean precisely so this can
go on stderr.

`tests/known-callers.sh` replays every caller Task 0 of that plan found — the
production `install.sh` wrapper pipeline first — and `tests/wrapper_test.sh`
covers the wrappers' own grammar, exit-code and stdout mapping.

## Why `fix_macho` could not be wrapped, and what changed

It was attempted as a wrapper once before and measured, on real 10.9, against
the binaries that shipped before the wrappers — and it could not be wrapped,
because a wrapper had to **preserve** behaviour and `fix_macho`'s differs from
the shared rewriter's. It stayed C for a whole plan on that basis.

What changed is not the code but the standard: the repo owner ruled those
differences **improvements to adopt deliberately**. There are five, and this
section is where they are stated — the wrapper itself no longer carries them,
and points here instead.

### `fix_macho`: the adopted divergences

Each row is a case where `fix_macho` and the shared rewriter give different
answers and the shared rewriter's is better, so the wrapper does **not** close
it. "Held by" is the assertion that fails if someone reverses the decision.

| # | the difference, and why adopting it is right | held by |
|---|---|---|
| 1 | **A replacement path longer than the existing command now SUCCEEDS.** `fix_macho` wrote the new path into the existing `LC_LOAD_DYLIB` and refused if it did not fit (`new path '...' too long (320 > 32)`, exit 1, file untouched); `machotool dylib -replace` rebuilds the load-command table and fits the longer path into header pad the image already has, exit 0. The limit was an artifact of a rewriter that never learned to resize a command, not a safety property: nothing in `docs/PROPOSAL.md` records a reason for it, and `machotool` does not have to inherit the old tools' artificial limits. The translation still emits no `--allow-grow` — this uses existing pad and never enlarges the header. | `tests/wrapper_test.sh`, "a longer replacement path is now rewritten into header pad, not refused"; `tests/translate_test.sh`'s `fm-*` cases, none of which emits `allow-grow` |
| 2 | **A chained `-rename_seg` now CHAINS.** `-rename_seg __DATA __X -rename_seg __X __Y` produced `__X` under `fix_macho`, which applied every pair in ONE pass and gave each segment its FIRST match, so the second pair never fired. Each pair is its own pass here — its own `segment rename` statement in the emitted edit script — and the second reads the first's result, so it produces `__Y`. Adopting it is doing what was asked. `compat/translate.sh` refused this shape outright until the ruling, correctly, while a wrapper still had to preserve `fix_macho`'s answer; its `-rename_seg` arm records the reversal. | `tests/wrapper_test.sh`, "a chained `-rename_seg` now produces the SECOND name, not the first" (asserts `__Y` present **and** `__X` absent); `tests/translate_test.sh`'s `fm-chain`, `fm-chain-3` |
| 3 | **The write-back is ATOMIC.** `fix_macho` `lseek`'d to 0 and wrote the whole file back over itself, so a crash, a full disk or a kill mid-write left a corrupt binary. `machotool` never writes `FILE` at all: it writes a temp beside it (`wa_write_new`, `src/atomic_write.h` — `mkstemp` + `rename`, carrying `FILE`'s mode, owner and xattrs) and the wrapper installs that temp with one `mv` in the same directory, so the caller's file is either wholly old or wholly new. These tools exist to make binaries loadable; a half-written one is the failure they are supposed to prevent. There is no multi-write caveat: an invocation worth more than one command is one `machotool edit FILE OUT -`, and `me_run` (`src/edit.c`) reads the image once, applies every statement in memory, verifies, and writes once — so a refusal at any statement leaves the temp unwritten and `FILE` exactly as it was. | `tests/wrapper_test.sh`: "a changed run installs by rename, so `FILE` gets a new inode"; "a refusal part way through a multi-statement run leaves `FILE` byte-identical and no temp beside it"; `hl_case fix_macho` ("a hard-linked `FILE` is refused (1), both names untouched", "and no temp was left beside it"). Mode, owner and xattrs: `tests/atomic_write_test.c` under `ctest` |
| 4 | **A fat slice whose edit fails now REFUSES THE WHOLE FILE.** `fix_macho`'s fat loop treated every per-slice failure alike: `process_macho` returned -1 whether the slice was not a Mach-O at all or was one whose edit it refused, and the loop printed `  Skipping arch %u` and carried on, exiting 0 having rewritten the slices it did understand — a partially converted universal binary reported as a success. `mr_process_fat` (`src/rewrite.c`) splits the two: `MR_SKIP` for a slice that is not a 64-bit Mach-O, `MR_ERROR` for one that IS and whose edit failed, and only `MR_ERROR` refuses. Refuse rather than guess. **Narrower than the retirement plan's table says:** that table reads as covering both cases; a slice that is simply not a 64-bit Mach-O is still left unchanged exactly as `fix_macho` left it, with a different message (`not a 64-bit Mach-O; leaving this slice unchanged`) and exit 0. | the `MR_SKIP` half, through `fix_macho` on a hand-built two-slice container: `tests/wrapper_test.sh`, "a non-64-bit slice is left unchanged and the other slice is still rewritten" — so the distinction cannot be quietly widened. The `MR_ERROR` half, at the verb: `tests/cli_test.sh`'s "MR_ERROR: one bad slice refuses the WHOLE fat file" block (message, slice label, per-slice reason, and the file unmodified) |
| 5 | **A `-change` aimed at this dylib's own install name now matches NOTHING**, instead of rewriting it. `compat/fix_macho.c`'s match block opened on `mo_is_ordinal_lc(lc->cmd) \|\| lc->cmd == LC_ID_DYLIB` and then ran the `changes[]` loop with no `LC_ID_DYLIB` exclusion, so `-change <this dylib's own install name> NEW` rewrote the dylib's identity — even though the file's own comment said "nothing in `changes` is ever meant to match it". `src/rewrite.c` guards it now. Adopting it is right because (a) `install_name_tool` spells identity `-id` and its `-change` never touches `LC_ID_DYLIB`, so `machotool` matches the tool everyone already knows; (b) `fix_macho.c`'s own comment stated the contract `machotool` now enforces, so this is the C being fixed, not contradicted; (c) silently rewriting a dylib's own install name from an operation aimed at a DEPENDENCY is exactly the invisible edit this work exists to make visible. Measured: both sides exit 0 and the bytes differ, with nothing on stderr naming the reason (transcript below). | `tests/wrapper_test.sh`, "-change at a dylib's own install name leaves `LC_ID_DYLIB` unchanged, reported unmatched, while a real dependency's `-change` in the same run still lands" — one run, both halves, on a dylib fixture built for it |

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
itself in everything it prints, so today that line reads `machotool: ...
matched nothing`; only the name moved. Updating the transcript in place would
falsify a record rather than refresh a description — the same reason
`tests/compat-matrix.tsv` still names the tools it measured.

### `fix_macho`: two more differences, NOT on the adopted list

Both are consequences of travelling through `mr_apply_file` at all rather than
choices the conversion made, both are shared with every other verb that
rewrites, and both are reported rather than worked around.

| the difference | held by |
|---|---|
| **`mg_plausible`.** `mr_apply_file` runs that gate before writing (except for a rename-only operation set, which `src/rewrite.c` skips because the gate asks an OFFSET question and a rename moves no offset). `fix_macho` had no such gate, so an image the gate rejects is one this refuses and `fix_macho` rewrote. It is a check on the INPUT, not on what the rewrite did. | `tests/wrapper_test.sh`'s `mg_plausible` pair on `tests/mkimplausible.c`'s fixture — the fixture is refused for an ordinary operation and renamed successfully — and `tests/cli_test.sh`'s "segment does NOT meet the `mg_plausible` gate" block at the verb |
| **`LC_LAZY_LOAD_DYLIB`.** `mo_map_build` (`src/ordinals.c`) refuses any image carrying one, up front, before it looks at what the operations are. `fix_macho` never built an ordinal map and rewrote such an image happily. `compat/rename_segment.sh`'s header has the measurement (on `/usr/lib/libxcselect.dylib`) and the note that the smallest fix is a change to `machotool`, not to a wrapper. | `tests/change_dylib_test.sh`'s `LC_LAZY_LOAD_DYLIB` case (refusal, the refusal naming the load command, and the input untouched) — through `change_dylib`, on the same shared driver, and it SKIPs loudly where the host's linker will not emit one |

### `fix_macho`: exit codes

0 and 1, the only two `fix_macho` had — so **every nonzero from `machotool` is
mapped to 1**. It is the same mapping `compat/rename_segment.sh` and
`compat/patch_macho.sh` make and for the same reason: `machotool`'s own
`EX_FAIL` is 2, a value no `fix_macho` caller has ever seen, and forwarding it
would invent a third outcome for a grammar that has two. `EX_REFUSED`, 1, is
not the problem — it already coincides with `fix_macho`'s own flat failure code
for any of the ordinary considered refusals this translation's
`dylib`/`lc`/`segment`/`edit` commands can reach (bad magic, no room to grow,
and the rest of `src/rewrite.h`'s list). The one `mr_apply_file` refusal
genuinely unreachable here is the `--fatal-warnings`-specific one, "an
operation matched nothing" promoted to `MR_REFUSED`: this translation never
emits that flag. It would not have needed mapping either way, being 1 like
everything else the mapping collapses.

Held by `tests/wrapper_test.sh`'s exit-fold pair — `machotool`'s own code for
an unreadable `FILE` is 2, and `fix_macho` on the same input exits 1 — and by
"`-strip_build_version` with nothing to strip exits 0, having written nothing",
which is the assertion that fails if `--fatal-warnings` ever leaks into the
translation.

### `fix_macho`: stdout is not reproduced

That is deliberate too. `fix_macho` printed `Processing thin Mach-O:` /
`Processing arch N at offset M:` / `  Changed: X -> Y` / `  Removed
LC_BUILD_VERSION (N bytes)` / `  Renamed segment 'A' -> 'B'` / `File updated:
F` / `No changes needed: F`. None of it survives. What a caller sees now is
`machotool`'s own reporting, plus — for the one line that carried information a
caller could act on — the per-operation unmatched report on **stderr**:

```
machotool: /usr/lib/libFoo.dylib matched nothing        (a -change)
machotool: no load command of kind build-version to delete
```

That is strictly more than `No changes needed: F` said, which could not
distinguish which of several operations missed. Those two lines are quoted with
the `machotool:` prefix and all, because that is what a caller really sees: the
report names the operation in `machotool`'s grammar, which is the grammar this
wrapper teaches (`src/rewrite.c`'s `mr_report_unmatched` says why the prefix is
the tool's name and not `argv[0]`).

`machotool --fatal-warnings` would turn that report into a refusal, and **this
wrapper must not pass it**: `fix_macho` exited 0 when an operation matched
nothing, and that is compat surface.

Neither `tests/EXPECTED` nor `tests/known-callers.sh`'s sha256s have an opinion
about any of these strings — both hash converted file bytes with the tools'
output sent to `/dev/null`. What reads these two lines is
`tests/wrapper_test.sh`, and the closing `Updated FILE (N bytes)` line (the one
`mr_apply_file` printed while the verbs still wrote `FILE`, not `fix_macho`'s
own `File updated: F`) is pinned there too, by a byte comparison of the
wrapper's whole stdout against `machotool dylib`'s.

### `fix_macho`: the in-place edit

`fix_macho` rewrote the file it was given; `machotool dylib`/`lc`/`segment` do
not. So the wrapper takes the shared install path — `mw_prepare` names a temp
beside the file `FILE` really is, `mw_retranslate` re-emits the command with
that temp as its output, `mw_run_to_tmp` runs it and drops the `Wrote <temp>`
line no C tool ever printed, and `mw_finish` `mv`s the temp over the target or
discards it when the bytes did not change. `machotool-compat.sh`'s "the install
path" section has the reasoning for each step. `machotool edit` takes that temp
as its `OUT` positional like every other verb, so both shapes install
identically.

Three consequences, all of them `fix_macho`'s alone to explain:

* **The writability check** comes with it, inside `mw_prepare`. `fix_macho`
  opened the file `O_RDWR` before it looked at it, so an absent or unwritable
  file failed immediately, with no analysis and no write. No `machotool`
  command reproduces that any more — a verb that writes an output opens `FILE`
  `O_RDONLY`, and `machotool edit` finds out it cannot write only when it
  writes, at the END of the run, with a different message — so
  `mw_require_writable` is the only thing that does. `test -w` is not
  `open(O_RDWR)`: it consults the real uid and does not see ACLs, so it can
  disagree at the edges. It agrees on the two cases that actually reach a
  caller (absent, and mode-denied), and both sides exit 1 either way. Held by
  `tests/wrapper_test.sh`'s absent-file and unwritable-file assertions, both on
  the MULTI-command path, which is the path where `machotool` would otherwise
  succeed and silently replace a mode-444 binary.
* **A hard-linked `FILE` is refused (exit 1)**, the one behaviour here no
  version of `fix_macho` had: it wrote through its own descriptor, so every link
  saw the change, while an install by `mv` would leave the others on the old
  content. Every wrapper on this install path makes the same trade;
  `mw_prepare` has the message and the remedy. Held by `hl_case fix_macho` in
  `tests/wrapper_test.sh`.
* **A writable binary in a read-only directory now fails**, because creating a
  temp beside `FILE` needs the DIRECTORY writable where the C tool needed only
  `FILE` itself to be: `mkstemp: Permission denied`, from `machotool`'s own
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
exists nowhere else: `machotool` sees one rename at a time either way — its
`segment` verb takes one pair, and an edit script's `segment rename` statement
is one pair — so nothing downstream would ever count them. Held by
`tests/wrapper_test.sh`'s two cap assertions (the wording, and the file
untouched) and `tests/translate_test.sh`'s `fm-cap-*` cases.

`fix_macho`'s only caller in this repo was `tests/change_dylib_test.sh`.
