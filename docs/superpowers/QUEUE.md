# Work queue

The agreed order. Each item names its spec and, once written, its plan.

| # | item | spec | plan | state |
|---|---|---|---|---|
| 1 | Report what macho9 did | — | `plans/2026-09-10-report-what-macho9-did.md` | **done**, pushed, CI green at `77f076a` |
| 2 | Edit scripts | `specs/2026-09-10-edit-scripts-design.md` | `plans/2026-09-10-edit-scripts.md` | **done**, pushed, CI green at `36703e0` |
| 3 | Rename + target | `specs/2026-09-10-machotool-rename-and-target-design.md` | `plans/2026-09-10-machotool-rename-and-target.md` | **done**, pushed, `9e39a57..770433f` |
| 4 | Release conformance | `specs/2026-09-10-release-conformance-design.md` | `plans/2026-09-10-release-conformance.md` | **done**, pushed, `ed7f4e4..452175a`; the first release is refused until item 6 removes the README marker |
| 5 | Relations + verb lowering | `specs/2026-09-10-relations-and-verb-lowering-design.md` | `plans/2026-09-10-relations-and-verb-lowering.md` | **done**, `e0eee27..5595a0f`, not yet pushed. One open decision for the repo owner: narrowing the gate removed the compat chain's only check on the chained-fixups conversion (`change_dylib` after `patch_macho` went from refusing to writing). Measured, with three options, in the spec's Amendment 3 |
| 6 | **Human code review + excellent documentation** | `specs/2026-09-12-narration-into-tests-design.md` (first half) | `plans/2026-09-12-narration-into-tests.md` (first half) | **first half done**, pushed, `3ce226a..fb241d3`, CI green. Second half — the human review and the README rewrite that removes the marker — is the repo owner's and is what still blocks the first release |
| 7 | History rewrite + the three rename steps | — | — | last of the in-tree work |
| 8 | `.pkg` + Sparkle updater | — | — | after 7; not yet designed |
| 9 | `machotool` never writes its input (replaces "skip the write when nothing changed") | `specs/2026-09-11-never-write-the-input-design.md` | `plans/2026-09-11-never-write-the-input.md` | **done**, pushed, `bccd008..1c0c38c` |
| 10 | `allow-grow` everywhere it is expected | `specs/2026-09-11-allow-grow-everywhere-design.md` | `plans/2026-09-11-allow-grow-everywhere.md` | **done**, pushed, `b76ddf1..9ae6835` |
| 11 | `edit` on fat (universal) files | `specs/2026-09-11-edit-on-fat-files-design.md` | `plans/2026-09-11-edit-on-fat-files.md` | **done**, pushed, `8f17001..956b4f6` |
| 12 | An `insert_dylib` wrapper | `specs/2026-09-20-insert-dylib-retype-imports-design.md` | — | **designed** 2026-09-20, with item 13 gaps 3 and 7; plan not yet written |
| 13 | What real app backports need and we lack | `specs/2026-09-20-insert-dylib-retype-imports-design.md` (gaps 3 and 7 only) | — | researched 2026-09-11, see below. **Gaps 3 and 7 designed** 2026-09-20 with item 12; gaps 1, 2, 4, 5, 6 and the live half of 7 remain |
| 14 | Spike: weaken binds in memory at load time | — | — | **spike done** 2026-09-12: answered NO; see below |
| 15 | Flat-namespace shim: satisfy missing symbols at runtime | — | — | not started; came out of item 14's spike |
| 16 | 32-bit (`LC_SEGMENT`) input | — | — | **to brainstorm**, raised 2026-09-20. Refused everywhere today, deliberately; `docs/prior-art.md` holds the reasoning and the two regression tests that pin it. Reopening it is what a Snow Leopard target would need, and what a fully drop-in `insert_dylib` would need |
| 17 | Convert a newer NIB to one 10.9 can load, without Xcode | — | — | **to brainstorm**, raised 2026-09-21; a working 148-line prototype exists in mavericks-1password history, see below |
| 18 | "Will this run on Mavericks?" for an arbitrary binary or `.app` | — | — | **to brainstorm**, raised 2026-09-21; see below |
| 19 | Rename this repo to **drydock** | — | — | **name decided** 2026-09-21; the rename itself waits for item 7, see below |
| 20 | Other tools that belong here | — | — | **idea list**, raised 2026-09-21; see below |
| 21 | Rehome Mavericks-Porting-Resources | — | — | **surveyed** 2026-09-21; Wowfunhappy is open to it being reorganized into the owner's repos, see below |
| 22 | Runtime trace for a ported binary, from M-P-R's `syscall_trace.c` | — | — | **to brainstorm**; the runtime half of item 18; see item 21 |
| 23 | Wrapper-dylib verb, from M-P-R's `build_wrappers.sh` and recipes | — | — | **to brainstorm**; see item 21 |
| 24 | Stub/wrapper shim generator, designed from M-P-R's `framework-stubs/` | — | — | **to brainstorm**; this is item 20.4, see item 21 |

Items 9–11 follow from item 2 and run **before item 3**, in the order 10, 11, 9: item 9's wrappers emit edit scripts for multi-command invocations, which needs item 11's fat support. Their plans are
written against today's names (`macho9`, `cli/macho9.c`) and today's
`--verbose` flag. Item 3 renames the product by sweeping the tree, which
picks up whatever 9–11 added, and its Task 6 ("always verbose, on stderr")
deletes the flag -- turning every verbose-only line 9–11 add, such as the
per-slice lines, into always-on output in the same pass. Running item 3
first would mean rebasing all three plans onto the new names.

## Why this order

**2 before 5.** Relations and verb lowering have nothing to attach to until
`MS_TABLE`, `ms_script` and `me_run` exist.

**3 before 4.** `release.yml`'s artifact list names `macho9`, `macho9-compat.sh`
and `macho9-translate.sh`; the rename changes all three. Landing release
conformance first would edit the same lines twice.

**8 is split out of 4, and goes after 7.** The `.pkg` and the Sparkle updater.
Its own spec section calls it "the largest single piece and the one most
reasonably split into its own increment", and everything else in item 4 can land
first and produce a GitHub Release of the binaries. The repo owner placed it
after the history rewrite; it needs a spec and a plan before it starts, and
neither is wanted yet. The constraint to carry into them is that the updater
must not link the product it updates.

**6 before 7, and 6 after everything else.** A human review wants the code in its
final shape — renamed, versioned, with the language in place — so it is not
reviewing something about to be restructured. And it must come *before* the
history rewrite for two reasons: a review that produces changes puts those
changes in the history being rewritten, and a rewrite done first would mean the
reviewer is reading commits that no longer exist by the time their comments land.

**Documentation belongs with the review, not after it.** Item 6 is one item on
purpose. The docs are part of what gets reviewed — a human reading this codebase
reads the comments and the READMEs as much as the code, and this repo already
treats a comment that claims more than the code does as a defect. Sequencing a
documentation pass *after* the review would mean the reviewer read the version
that was not yet worth reading; sequencing it before would mean polishing prose
about code the review is about to change.

**The README is a named input to item 6**, raised by the repo owner
2026-09-11: it is far too long, and its opening sentence does not parse.

- **Length.** 360 lines, of which the `machotool edit` manual (its file format,
  statements, directives, worked example and limits) is about 200 — 55% of the
  front door spent on one verb. That material is reference, not introduction;
  it wants its own file, with the README keeping a short pointer.
- **The opening sentence.** "Mach-O surgery for hosts too old to have any"
  reads as *hosts too old to have any surgery*, which is not the claim. The
  claim is that the tools that would normally do this work do not exist for,
  or do not run on, 10.9. Say that plainly.
- Also: the Layout section explains `compat/` at a length that belongs in
  `compat/README.md`, which already exists and says it.

**Deleting the README's unreviewed marker is part of item 6.** `README.md` now
carries, under its heading, the family's generated-README marker — visible
prose, so it renders on the repo's front page. Shipyard's `publish-release.yml`
refuses a repo's *first* release while that line is present, so item 4 cannot
ship until a human has read this README and removed it. That is the intended
loop: item 6 is already the pass where a human rewrites the front door, and the
two complaints recorded below — the length, and the opening sentence that does
not parse — are exactly what the marker is asking someone to fix.

**Comment density is the other named input to item 6**, raised by the repo
owner 2026-09-12 after the rename: *"my eyes glaze over attempting to skim the
compat wrappers, several screens of comments away from finding where they
actually happen."* Measured that day:

| file | total | comments | code | first code at |
|---|---|---|---|---|
| `fix_macho.sh` | 284 | 259 (91%) | **20** | line 251 |
| `change_dylib.sh` | 221 | 196 (88%) | **20** | line 184 |
| `rename_segment.sh` | 232 | 190 (81%) | 31 | line 168 |
| `patch_macho.sh` | 205 | 156 (76%) | 40 | line 128 |
| `translate.sh` | 808 | 469 (58%) | 311 | line 240 |

A 284-line wrapper where 20 lines do anything, reached after 250 lines of
prose. That is a defect in placement, not a matter of taste.

**The first two rows are history as of `3dc64aa`.** The narration sweep (the
first half of this item) cut `fix_macho.sh` to **48 lines / 23 comment (47%)**
and `change_dylib.sh` to **51 / 26 (50%)**, first code at line 17 and 18. The
other three rows are unchanged and still measure as written. Full before/after
is in "Carried out of the narration sweep", below.

**The expensive class is narration**, not comments as such: measured
transcripts, repro steps, quotations of earlier comment text, accounts of what
a retired tool did on a particular day. It goes stale silently, and the rename
(item 3) paid a fix round for it at nearly every task — most of one whole task
was spent classifying comments as "describes the tool now" versus "reports what
happened then", and getting it wrong is invisible to a grep, because a
substitution erases the tell.

**Prefer a test to a comment.** Item 3 demonstrated the asymmetry: the comments
went stale repeatedly and nothing caught them, while every mutation thrown at
the tests failed loudly. A test named for a quirk fails when someone "fixes"
the quirk; a comment describing the quirk merely becomes wrong. This repo's
tests are strong enough that much of the narration describes something already
pinned.

**The order to apply, per passage:** can it be a test? Then can it be a commit
message — history belongs in history? Then can it be `compat/README.md`, which
already exists and is where divergence tables and measured transcripts belong?
Only what survives all three stays inline, and only what a reader must see *at
that line* to avoid breaking it: a sentence, not a screen.

What is worth keeping inline, on the evidence: the short load-bearing kind. The
comment explaining why the tool's own diagnostics carry its name is what made
the rename mandatory rather than optional. The one-liner saying to pass a value
through `ENVIRON` rather than `awk -v` prevents a bug that had already shipped
once. Both are a sentence at the point of danger.

**A note on how it got this way, so the pass does not just blame the past.**
Dense comments are cheap to write and their cost lands later, on whoever reads
or renames. The assistant added prose at nearly every review cycle of items 9
and 3; the trend was worsening, not historical. Whatever rule item 6 lands on
should bind new work, not only clean up old.

One known input to that pass, raised by the repo owner while approving item 5's
design: **the module prefixes** (`mi_`, `mr_`, `mg_`, `mo_`, `mseg_`, `mswift_`,
`wa_`, `ms_`, `me_`) mean nothing to a reader who has not learned them. That is a
readability decision no single design should make unilaterally, and item 6 is
where it belongs.

**7 after everything but 8** because rewriting history invalidates every commit
SHA this repo's docs, ledgers and plans cite.

## Carried out of item 2

Item 2 shipped `cbcacd3..36703e0`. What it deliberately left for later, so the
record does not live only in a git-ignored ledger:

**For item 5.** Its plan predates what item 2 built, and should be re-read
against `src/edit.c`, the buffer-level seams item 2 exposed (`mr_apply_image`,
`mv_add_version_min_image`, `mswift_retag_image`, `md_declassify_buf`),
`lc_kind_by_name`, and the `mr_ops` result pointers (`segment_renamed`,
`renumbering`). Open items that belong to it:

- During an `edit` run the operations still print their own stdout progress
  lines, so a run later refused can show "updated" on stdout. Those lines are
  the compat wrappers' byte-identical contract; silencing them per front-end is
  the output restructuring verb lowering exists to do. The README says stderr's
  refusal line and the exit code are authoritative meanwhile.
- The segment-name validity check lives in the front-ends (`cmd_segment`,
  `src/edit.c`), not in the operation.
- An allocation failure inside `mg_grow_header` or `mg_plausible` is reported
  as refused (1), not error (2): splitting their per-slice status widens into
  `src/grow.c`'s contracts. Disclosed in `src/rewrite.c`.
- The core's no-room message says "pass -grow to enlarge it", naming neither
  `edit`'s `allow-grow` directive nor the CLI's `--allow-grow`.

**Limits of `edit` as shipped**, each refused rather than wrong:
- thin 64-bit input only; a fat file is refused — *closed by item 11*;
- `allow-grow` reaches `dylib` and `rpath` only; `version-min set` refuses
  "no room" even under it — *closed by item 10*;
- statement order is execution order, so two `dylib insert` lines give the
  reverse of `-insert A -insert B`. A generator that emits scripts from verb
  lines (`compat/translate.sh`, per the spec's "Consumers") must reverse them.

**For item 6** (pre-existing, found along the way): `src/rewrite.c`'s **two**
unchecked `calloc`s (`:718` and `:793` as of item 5, both `mr_process_thin`'s
`new_lcs` tables) crash rather than refuse on allocation failure. Corrected
2026-09-12: this said three, one of them in `mr_process_fat`. `mr_process_fat`
allocates nothing, and `mr_apply_file`'s `malloc` (`:1307`) is checked. The
code's own comments had it right all along (`rewrite.c:1265`, and
`rewrite.h:158` — `:404` until the narration sweep shortened that header, which
is 171 lines today).

Comments still naming plan artifacts ("Task N", briefs, rounds, "item N"):
**50** across `src/`, `cli/`, `compat/` and `tests/`, measured 2026-09-13 at
`3dc64aa` (54 at the sweep's base `3ce226a`; it removed four). This entry said
"about 87", which is not reproducible — and the mass is not where the entry
implies: **37 of the 50 are in `tests/`**, led by `compat-sweep.sh` (10) and
`change_dylib_test.sh` (6), against **13** in all of `src/` + `cli/` +
`compat/` together (`cli/machotool.c` 5, `compat/translate.sh` 3, and one each
in six other files). Plan-artifact *paths* (`docs/superpowers/...`) number
**three** in shipped files, not dozens. So the spec's expectation that this
class would be swept away as a side effect was sound only because the class was
already almost empty; it was never the 87-comment liability recorded here.

Also for item 6, and still open: in `md_declassify_buf` (`src/declassify.c`),
the first-section walk and the
`__LINKEDIT` extension go through `segs[]` pointers taken before the loop that
`memmove`s the removed load commands out, and never refreshed: in a crafted
file where a removed command precedes a segment command, both would read and
write shifted content.

## Carried out of item 10

**A confirmed silent-corruption bug, pre-existing: fixed in `66ca5ce`.**
`mg_first_sect_off` answered 4096 for an image with no section data, and
`src/grow.h` called that "a real, if unusual, answer". It was not: on a
sectionless image of 4096 bytes or more, `mr_process_thin` took it as the
header-pad boundary, and its commit zeroed everything up to it. Reproduced on
an 8192-byte image: `macho9 dylib F -append /x` exited 0 having zeroed bytes
200..4095, with or without `MACHO_NO_VERIFY`, because `mg_plausible` accepts
that image. (An earlier version of this note said `mg_plausible` happened to
refuse the fixture without the variable; it does not, so it was never a
guard.) `src/declassify.c` had its own copy of the same 4096 fallback, checked
against `buf + 4096` and never against the file size. The smaller case -- a
sectionless image shorter than 4096 bytes, which wrote past the buffer -- was
fixed in item 10 (`34a3187`). `66ca5ce` stops treating "no sections" as
"4096": `mg_first_sect_off` answers `MG_NO_SECTION_DATA`, every caller that
writes into the pad refuses it (declassify also refuses a first section past
the end of the image), and `macho9 info` reports the pad as unknown.
`7ea664a` makes `mg_grow_header` refuse a first section whose file offset lies
past the end of the image, the bound every other caller already had; before
it, `macho9 grow` on such an image died of SIGSEGV.

**Four wording overclaims for item 6's documentation pass**, two of them
resolved by `66ca5ce`, which rewrote both passages: `src/grow.h:99-101` (an
image with no section data was refused only when shorter than 4096 bytes) and
`tests/leaf-tool-crashes.sh:19-23` (past tense about a clearing that still
happened on large images). Still open: `README.md:300` and `src/edit.h:153`
("Nor does the conversion need it" needs the same "on a modern chained binary"
qualifier as the sentence after it); `src/edit.h:108-114` (omits the grow line
printed before a refusal on a non-PIE image).

## Carried out of item 11

Item 11 shipped `8f17001..956b4f6`. Its final review found nothing critical or
important; what it left deliberately:

**For item 9** (`machotool` never writes its input). `me_fat_slice` sets
`*changed` for every selected slice, so a fat `edit` always reassembles and
rewrites the container even when no statement changed a byte — and reassembly
sizes the output from the furthest slice end, so bytes trailing the last slice
are dropped (a 16613-byte input with a no-op script gives a 16600-byte output).
The verb path drops them too, but only when something actually changed, so this
is not a regression in `mr_process_fat` — it is new only in that `edit` reaches
the reassembly unconditionally. Item 9's "skip the write when nothing changed"
closes both halves.

**For item 6** (documentation and review): `--capabilities` advertises
`statement` rows but no directives at all, so the `translate.sh` emitter the
edit-scripts spec names cannot discover `arch` — nor `allow-grow` nor
`fatal-warnings`. Consistent with the existing protocol rather than a gap item
11 opened, but worth deciding once.

**Pre-existing, not touched:** `src/fat.c:189` truncates a slice's offset and
size to `uint32_t`, so a container larger than 4 GiB is silently mis-laid-out.
The line moved verbatim out of `mr_process_fat` into `mfat_rewrite`, which is
now the one place a bound on `max_end` would go. `edit`'s post-reassembly
`mfat_parse` would likely catch the result; the verb path has no such re-parse.
`src/edit.c`'s `char have[256]` slice list, printed by the "no such slice"
refusals, truncates silently — unreachable with five arch names.

## Item 12: an `insert_dylib` wrapper

Unlike the six in `compat/`, this one would emulate a tool this repo never
shipped. `Wowfunhappy/insert_dylib` (a fork of `Tyilo/insert_dylib`) is prior
art we measured ourselves against and took the export-trie rebuild from —
`docs/prior-art.md`, `src/trie.c`. Nothing in `tests/known-callers.sh`'s
caller set invokes it, so this is convenience for people who already know that
grammar, not compatibility debt.

The capability is already here under our own grammar: `machotool dylib FILE
-append PATH` is insert_dylib's core act, `-insert` puts it at ordinal 1, and
`lc -delete codesig` covers `--strip-codesig`. What a wrapper adds is its CLI
shape — `insert_dylib dylib_path binary [new_binary]`, with `--inplace`,
`--all-yes`, `--weak`, `--strip-codesig` — which is the part worth designing
rather than guessing. Two things to settle first: which of its flags have an
equivalent at all (`--weak` means `LC_LOAD_WEAK_DYLIB`, which the `dylib` verb
does not emit today), and what the repo owner's actual use of the fork is —
the answer decides whether this is a full wrapper or one worked example in the
README. Runs after item 9, since it inherits the `FILE OUT` grammar.

## Item 13: what real app backports need and we lack

Researched 2026-09-11 after the repo owner recalled a project running newer
iLife/iWork on Mavericks. Full report, with sources and line references, in
`.superpowers/research-ilife-iwork-backports.md`. **That path is untracked, not
ignored** — `.gitignore` covers only the build directories, `/VERSION` and
`CMakeUserPresets.json` — so the file is one `git clean -fdx` from gone. Both it
and item 14's spike report want moving into `docs/` when either item gets a
spec, after a read-through: this repo is public, so committing them is
publishing, and they are subagent prose that has not had a documentation pass.

**What exists.** One direct hit:
`nfzerox/MavericksAppCompatibilityLayer`, which patches Keynote 6.6.2 / Pages
5.6.2 / Numbers 3.6.2 to run on 10.9.5 — published once in May 2016 and
abandoned (one squashed commit, no issues, no forks). Its relatives run the same
direction without being Apple apps: `Wowfunhappy/Celeste-64-Patched-For-Mavericks`,
whose `COMPAT_WRITEUP.md` is the best operation-by-operation source found and
whose `patch_macho.c` is this repo's own ancestor, and `landonf/XcodePostFacto`,
which does the equivalent work **in memory** at image-state-change time and so
never writes or re-signs anything. No iMovie, GarageBand or Photos backport
appears to exist. `Wowfunhappy/Pages-Mavericks-Workaround` looks like a hit and
is not — it patches iWork '09 on Mavericks, an old app on a newer OS.

**The gaps, ranked.** The first two are one subsystem and are what their whole
approach rests on:

1. **Edit an existing `LC_DYLD_INFO[_ONLY]` bind stream** — OR
   `BIND_SYMBOL_FLAGS_WEAK_IMPORT` into a named symbol's trailing-flags byte, so
   a missing symbol becomes a weak import instead of a load failure. Size
   preserving, so no `grow` or `__LINKEDIT` interaction. We already write that
   exact byte in `src/declassify.c` when synthesising a stream; what is missing
   is any way to reach into one that already exists.
2. **Rewrite a bind entry's dylib ordinal to `BIND_SPECIAL_DYLIB_FLAT_LOOKUP`**,
   padding the shortened ULEB with `SET_TYPE_IMM(BIND_TYPE_POINTER)` (`0x51`)
   no-ops to keep the stream's byte length identical. Same walker and selectors
   as gap 1; the filler trick is worth lifting verbatim. Together, 1 and 2 are
   the difference between making a modern image *loadable* and making it
   *satisfiable by a stub dylib*.
3. **`LC_LOAD_WEAK_DYLIB`** — emit it on `dylib append`/`insert`, and flip an
   existing `LC_LOAD_DYLIB` to weak and back. The flip is one `uint32_t` write
   with no size change and no ordinal movement, since `mo_is_dylib_lc` already
   counts both kinds. This is also the last flag-axis gap against
   `insert_dylib --weak`, so it belongs with item 12.
4. **`minos set`** — rewrite an existing `LC_VERSION_MIN_MACOSX.version` or
   `LC_BUILD_VERSION.minos` rather than only appending or deleting. Their
   `patch_min_version.py` exists because Keynote 9's bundled frameworks each
   declare 10.13 in a load command that is otherwise 10.9-parseable; our
   `minos` is a no-op when one is present, and `lc delete build-version` throws
   the information away instead of correcting it.
5. **`section retype`** — normalize `S_NON_LAZY_SYMBOL_POINTERS` /
   `S_SYMBOL_STUBS` to `S_REGULAR`. One `flags` write per section, but resolve a
   tension first: `grow` refuses an unrecognized section type, so the two
   features must agree on ordering.
6. **Relative → absolute ObjC method lists.** Not a statement, a subsystem: new
   segment and section, 12 → 24-byte entries, `entsize` change, fresh rebase
   entries in a writable segment. Per Celeste's writeup this is what stands
   between `declassify` succeeding and a modern Obj-C binary actually running.
   Wants its own spec.
7. **Machine-readable import reporting.** Both projects' hardest work is the
   *diff*, not the patch — enumerate every `(install_name, symbol)` a binary
   imports and ask the live 10.9 loader which are missing. Our `info` is
   structural. Emitting the import list as parseable output is also the natural
   on-ramp to gaps 1 and 2, since that manifest is exactly their selector list.

**Where their practice bears on our refusals:**

- **`FAT_MAGIC_64`: they parse it, and for their operation class they are right
  — because every edit they make preserves byte length inside a slice.** That
  argues for accepting `fat_arch_64` for the size-preserving statements while
  keeping it refused for `grow`, `declassify`, and any append that overflows
  slack, which genuinely need `fat_arch_64.offset`/`.size` rewritten. Caveat
  worth carrying: nothing in their corpus actually is `fat_arch_64`, so their
  support is untested.
- **32-bit: no challenge.** Their code path exists but every target is
  x86_64-only and nothing exercises it. Dead code on their side; our refusal
  stands. (The condition that *would* reopen it is recorded in
  `docs/prior-art.md`.)
- **One place we are already right where they are wrong:** their
  `--prepend-dylib` path shifts load commands down without renumbering
  `SET_DYLIB_ORDINAL` opcodes — a latent bug no shipped script of theirs
  invokes. Our `dylib insert` renumbers.

**A documentation gap this turned up, for item 6.** Ad-hoc re-signing
(`codesign --force --deep --sign -`) is **mandatory** in their flow, not
optional: their installer aborts when `codesign --verify` fails, because a
modified bundle carrying Apple's original signature is rejected at exec. Since
`machotool lc delete codesig` makes re-signing unavoidable, our README's
capability list has an undocumented dependency — a user could follow it
exactly and end up with a bundle the kernel kills. The README should say that
re-signing is a required external step, and what it costs: ad-hoc signing drops
private entitlements (their iCloud sync does not work, and CloudKit had to be
neutered at runtime because amfid rejects an ad-hoc binary that keeps iCloud
entitlements). Note SIP and Gatekeeper never obstructed them, by design —
everything is written inside the `.app`, and the one system-framework
substitution is bundled and reached through an injected `@executable_path`
`LC_LOAD_DYLIB` rather than replacing the system copy.

## Item 14: spike — weaken binds in memory at load time

Raised by the repo owner 2026-09-12, reading item 13's note that
`landonf/XcodePostFacto` does equivalent work in memory and so never writes or
re-signs anything. A **spike**: the output is an answer, not code we keep.

**Why it is worth asking.** It dissolves the one item 13 finding that no amount
of load-command coverage fixes. Nothing on disk changes, so the code signature
stays valid: no ad-hoc re-sign, no dropped private entitlements, no CloudKit
workaround, no SIP question, and undoing it means not injecting. XcodePostFacto
never touched the app bundle at all, because it is a *launcher* — it sets
`DYLD_INSERT_LIBRARIES` and execs the target, so even `Info.plist` stays
untouched, and editing `Info.plist` is precisely what forced their re-sign.

**Confirmed available here 2026-09-12:** `_dyld_register_image_state_change_handler`
is exported from 10.9.5's `/usr/lib/system/libdyld.dylib` (build 13F1911). The
declaration is not in the SDK — `dyld_priv.h` ships with dyld's source, not
Xcode — so a caller declares it itself.

**What it does not avoid.** The operations are item 13's gaps 1 and 2 —
weakening an import, and rewriting its ordinal to flat lookup. In-memory
relocates that work rather than removing it. The opcode walker is reusable; the
*locating* arithmetic is not, because this repo's buffer-level operations assume
file layout, and `LC_DYLD_INFO.bind_off` is a file offset: in a mapped image you
need `__LINKEDIT`'s vmaddr plus the slide. `__LINKEDIT` is also mapped
read-only, so patching means `vm_protect` out and back.

**The question that decides feasibility, and is genuinely open:** which images
can a handler still reach in time? Registered from an inserted library, it fires
for images mapped *after* it — whether it can still catch the **main
executable**, which dyld may already have bound by the time our constructor
runs, is unknown. XcodePostFacto's targets were frameworks Xcode loads later,
which does not settle the general case. If only later-loaded images are
reachable, this is a technique for framework-shaped problems, not a general
porting tool.

**The probe.** Declare the SPI, register at `dyld_image_state_dependents_mapped`,
and try to weaken one bind against a test binary that links a deliberately
missing symbol — once where the symbol is in a `dlopen`ed dylib, once where it
is in the main executable. Report which worked. Also worth noting the blunt
alternative and why it is not this: `DYLD_FORCE_FLAT_NAMESPACE` abandons
two-level namespace wholesale, which is presumably why XcodePostFacto rewrote
individual binds instead.

**If it works,** the shape is two front ends over one walker: one writes a file,
one patches mapped memory. That is the same split this repo already has between
file-level and buffer-level operations, so it is not a new architecture — but a
runtime injector is a new *kind* of artifact, with a test strategy that cannot
be "hash the output file", so it wants its own spec rather than being folded
into item 13.

### Spike result, 2026-09-12: **no.** Do not build this.

Run natively on 10.9.5 (`dyld-239.5`). Full evidence in
`.superpowers/spike-inmemory-bind-weakening.md`.

| case | reachable in time? | weakening effective? |
|---|---|---|
| `dlopen`ed dylib | **yes** — handler fires for just that image | **yes** — refs resolve to 0; guarded code survives, unguarded SIGSEGVs |
| main exe, non-lazy (data) | **no** — dyld aborts inside `link()`; the injected constructor never runs | n/a |
| main exe, lazy (function) | **yes** — stream patched `0x40`→`0x41` and read back as weak | **no** — dyld's stub-time binder ignores the flag |
| load-time dependency dylib | **no** — dependencies bind before the main executable | n/a |

**Two complementary walls: everything reachable is ineffective, everything
effective is unreachable.** The decisive one is that dyld's lazy-binding path
ignores `BIND_SYMBOL_FLAGS_WEAK_IMPORT` altogether — proven not to be a
patching artifact, since a genuine `__attribute__((weak_import))` function
called unguarded dies the same way (`dyld: lazy symbol binding failed`). And
guarding a function reference forces it *non-lazy*, because you take its
address — so "reachable in time" and "guarded" are mutually exclusive. What
timing left open, dyld's binder closes.

**A finding that bears on item 13's gaps 1 and 2, which are the ON-DISK version
of the same edit.** Those gaps survive this result — patching the file puts the
flag in place before dyld ever looks, so the timing problem is specific to
memory. But the spike sharpens *why* weakening alone is not the win:
`if (&sym)` against a strong import is **compiled away** (`movb $0x1,%cl;
testb $0x1,%cl` even at `-O0`), so a binary whose source never used
`weak_import` has no guard to satisfy. Weakening such a bind converts a clean
launch-time abort into a SIGSEGV at the use site — worse, not better. Gap 1 is
only useful *with* gap 2: the symbol must end up resolving to a real stub, not
to 0. Any spec for gaps 1–2 should state that as a precondition.

## Item 15: flat-namespace shim — satisfy missing symbols at runtime

Came out of item 14's spike, which found it while proving the other approach
dead. `DYLD_FORCE_FLAT_NAMESPACE=1` plus an inserted shim dylib that *defines*
the missing symbols rescued **all six** probe variants, main executable
included, with no memory patching and nothing written to disk at all.

Why this is worth a design rather than a shrug:

- **Nothing on disk changes, so the signature survives.** Verified: `md5`
  identical and `codesign -v` still passes, even with `CS_KILL` set. This is the
  property that motivated item 14 in the first place, and this route delivers it
  without the patching.
- **No bundle edit is needed.** `open` forwards `DYLD_INSERT_LIBRARIES` through
  LaunchServices on 10.9 — verified with two distinct values plus an unset
  control — so `Info.plist` stays untouched, and XcodePostFacto's launcher app
  may have been unnecessary.
- **It inverts the work.** Instead of rewriting a binary so its imports become
  satisfiable, supply the imports. The hard part stops being Mach-O surgery and
  becomes *knowing which symbols to stub and what they should do* — which is
  what item 13's gap 7 (machine-readable import reporting) exists to answer, and
  where this repo's `info` verb is the natural on-ramp.

Costs and blockers to settle in the design, not discover later:

- **Process-wide flat lookup** is the price. Two libraries exporting the same
  name now collide where two-level namespacing kept them apart — a real hazard
  in a large app with bundled frameworks, and the reason XcodePostFacto
  presumably rewrote individual binds instead. Whether that is tolerable is the
  central design question.
- **A `__RESTRICT` segment is a hard blocker**: it strips every `DYLD_*`
  variable, so nothing is injected at all. Determine how common that is in the
  target population before promising anything.
- A stub that returns the wrong thing is worse than a missing symbol, because it
  fails later and less legibly. The design needs a story for what a stub does
  when it cannot do the real work.

This is a different product from `machotool` — a runtime library plus a launch
wrapper, not a file transformer — so it gets its own spec, and its verification
cannot be "hash the output file".

## Carried out of item 3

**The multi-family wrappers leak the compat temp's name on stderr.** Since the
report became unconditional, a multi-family `change_dylib` or `fix_macho` run —
the invocations that translate to one `machotool edit` — ends its stderr with a
line naming the hidden temp:

    ./.mf.machotool-compat.37920: written (8,504 bytes)

That is the same path `mw_run_to_tmp` already filters out of *stdout*, and
hiding it is the entire reason the wrapper's install mechanism exists. Measured
cosmetic: nothing gates wrapper stderr byte-for-byte and all 182 wrapper
assertions pass with the line present. Single-family runs are unaffected —
they reach `machotool dylib`, which produces no report at all.

**Where the fix belongs, and why not the obvious one.** In the wrapper, not in
`edit`: `edit` naming its `OUT` is correct behaviour, since `OUT` is what the
caller of `machotool edit` asked for — the wrapper is the party that chose a
hidden temp as `OUT`. Extend `mw_run_to_tmp` so the one predicate that already
knows `$MW_TMPFILE` filters both streams, rather than teaching a second place
the temp's name. Do **not** suppress the edit run's stderr wholesale: real
diagnostics share that stream, and one was caught in the same capture
(`machotool: no load command of kind build-version to delete`, from
`fix_macho`), which a caller should see.

It needs a stream swap (`3>&1 1>&2 2>&3`) around the `awk` in the most
depended-on wrapper, plus a new `wrapper_test` assertion pinning the temp's
absence from stderr — a new construct and a new gate, which is why it was not
bought with the last of item 3's verification budget. `tests/characterize.sh`'s
own console output shows the same line, and is a convenient reproduction.

**A latent collision worth knowing before anything else emits `target`.**
`me_log_derived` and the empty-expansion line emit **four-space-indented**
report lines, and since the report became unconditional those go to stderr
always. `tests/wrapper_test.sh`'s taught-block extractor pulls commands out of
wrapper stderr with `awk '/^    /{sub(/^    /,""); print}'` — also four spaces.
No collision exists today, because no wrapper translates to a `target`
statement and the report's statement echoes are two-space indented (confirmed
by running that awk over a real multi-family stderr: only the two taught lines
come back). But if a wrapper ever emits `target`, its expansion listing would
be captured as taught commands. Either indentation is the thing to change then.

## Carried out of the narration sweep

The first half of item 6 shipped `3ce226a..3dc64aa`, five tasks, one file per
commit. Everything below was measured 2026-09-13 at `3dc64aa`, with the base
checked out in a worktree rather than reasoned about.

### Two verification gaps this item exposed, before anything else

Both are about *how we check*, and both silently under-reported for a whole
item. Read these before trusting a green run.

**Local suites are not CI, and this item's tests were red on `main` for a day
without anyone noticing.** `tests/cli_test.sh`'s refusal inventory named
`arch arm64` as a directive its fixture could not satisfy, but `build_main`
compiles for the *host* — `FIXTURE_FLAGS` pins only the deployment target — so
on GitHub's `macos-26-arm64` runner the fixture **is** arm64, the directive
becomes satisfiable, and the assertion fails. It passed on every x86_64
machine. Six implementers and five reviewers ran nine local gates each and not
one looked at the remote result across 21 commits, because the plan's own
constraints listed only local gates. Fixed at `725104e` (`uname -m`, with a
`platform:` tag). **The general point outlives the bug: a mutation proof is
only valid in the environment the mutation ran in, and this item
mutation-proved 27 assertions on one architecture.** Run `gh run list` after a
push; a suite that cannot fail where it was written is not pinned.

**`check-family-conventions.sh` must come from shipyard `main`, and the
checkout this item used did not.** Every task reported
`check-family-conventions: ok` from
`trees/mavericks-shipyard-readme-gate/scripts/`, which sits on the
`readme-reviewed-before-first-release` branch and **does not contain** the
`release-notes.sh` check at all (`grep -c` returns 0). CI, which uses
`.shipyard/scripts/`, has failed on that rule since before the sweep — see the
release-conformance item, whose first job it is. The error direction was the
lucky one (missing checks under-report, so false passes rather than false
failures), but "the family gate passed" means only as much as the checkout it
ran from.

### What it measured

Four files. Each lost between three-quarters and nine-tenths of its comment
lines; together, 82% of them:

| file | before | after |
|---|---|---|
| `src/edit.h` | 304 / 290 (95%) | 74 / 60 (81%) |
| `compat/fix_macho.sh` | 284 / 259 (91%) | 48 / 23 (47%) |
| `compat/change_dylib.sh` | 221 / 196 (88%) | 51 / 26 (50%) |
| `src/rewrite.h` | 425 / 359 (84%) | 156 / 91 (58%) |
| **the four together** | **1,234 / 1,104 (89%)** | **329 / 200 (61%)** |

Tree-wide, over `src/*.c src/*.h cli/*.c compat/*.sh`: **13,445 lines / 6,744
comment (50%) → 12,545 / 5,845 (46%)**. Over `src/` + `cli/` alone, which is
what the design spec's headline measured: **11,004 / 5,032 (45%) → 10,508 /
4,537 (43%)**. Files both over 200 lines and at least half comment fell from 12
to 8 — the four that left are exactly the four swept.

So the sweep removed **904 comment lines** and moved the tree four points. It
did not move it *below* dense, and it could not have: the four worst files held
16% of the comment mass.

**A measurement trap, because the next person will hit it.** The plan's own
`awk` one-liner puts `#` in its comment-opener alternation — necessary for
shell, but it makes every C `#include`, `#define` and `#ifndef` count as a
comment. That inflates `src/grow.h` from 64% to 70%, `src/rewrite.h` from 84%
to 86%, and the tree total from 46% to 49%. Every figure in this section
excludes preprocessor lines for C files and counts `#` for shell. The spec's
table is reproducible to the line under that rule, and off under the
one-liner's — which is the same units error as counting matrix rows as file
lines.

### What it bought in tests, honestly

`tests/` gained 312 lines against 8 removed. `cli_test.sh` 392 → **405**,
`wrapper_test.sh` 182 → **196**: **27 new assertions**, every one
mutation-proven, several failing two ways. `translate_test.sh` (128),
`change_dylib_test.sh` (71), `known-callers.sh` (18), `leaf-tool-crashes.sh`
and `ctest` (17/17, `chained_fixups` skipped) are all unchanged, the
`characterize.sh` digest `ad12bdd7…` never moved, no `known-callers` sha256
moved, and a clean build has 0 compiler warnings.

**27 assertions for 904 deleted comment lines is 3 per 100.** Say it plainly:
this was mostly deletion, not conversion. That was the designed outcome for
buckets 2 and 4 and it is where most of the volume fell — `fix_macho.sh` and
`change_dylib.sh` between them lost 406 comment lines and produced 14
assertions, because the bulk of both headers was a divergence table that
belonged in `compat/README.md` and a measured transcript that belonged in a
doc. Neither is a testable claim; both are records, and moving a record is not
a conversion.

The conversion that did happen is worth more than the ratio suggests, because
of *which* claims it caught: 6 of the 27 assertions pin behaviour that **no
test in the tree had ever held** — `change_dylib`'s exit-code forwarding, its
mid-script atomicity, its no-command guard, two `fix_macho` install properties,
and `rewrite.c:1291`'s size refusal, which nothing had ever reached. Those are
not redundant prose made executable. They are claims the repo had been
asserting in comments and nowhere else, for as long as the comments existed.

### The claims that were false, not merely verbose

This is the sweep's real yield, and the pattern in it is the finding.

- **`src/edit.h`'s refusal inventory was wrong twice** before a test pinned it.
  The third version was right, and now something checks it instead of a reader.
- **A third passage in the same header** attributed `"Updated PATH (N bytes)"`
  to verbs that print `Wrote OUT`. Measured: `"Updated` does not occur anywhere
  in `src/` or `cli/`. The string is the compat wrapper's own
  (`compat/fix_macho.sh:47`), which `tests/wrapper_test.sh:259` derives with
  `sed 's|^Wrote f\.mtout (|Updated f (|'`. A test asserting it absent from a
  core tool's stdout would have passed vacuously forever.
- **`src/rewrite.h`'s file header claimed `tests/characterize.sh` pins the
  module's diagnostics.** It cannot: `characterize.sh` sends stdout to
  `/dev/null` and contains no `2>` at all. The pre-sweep text cited both
  `change_dylib_test.sh` and `characterize.sh`; a compression kept the half
  that cannot capture stderr and dropped the half that redirects it 44 times.
- **The planning documents said `src/rewrite.c` has three unchecked `calloc`s,
  one in `mr_process_fat`.** There are two, both `mr_process_thin`'s `new_lcs`
  (`:718`, `:793` as of item 5); `mr_process_fat` allocates nothing at all and
  `mr_apply_file`'s `malloc` (`:1307`) is checked. The miscount came from
  reading `grep -c calloc` (3) rather than the hits — the third hit is the
  comment (`:1265`) that states the count correctly.
- **`compat/change_dylib.sh` said "all four callers"**;
  `tests/known-callers.sh` names three (`install.sh`,
  `mf-wrapper-rebase.sh`, `magic-trackpad2`) plus this repo's own suites.
- **Three claims that wrapper's prose made were held by no test at all** —
  exit-code forwarding, mid-script atomicity, the no-command guard. The
  forwarding one was live: `change_dylib` **forwards** `machotool`'s exit code
  (a directory as `FILE` gives 2) while its sibling `fix_macho` **folds** every
  nonzero to 1. Two wrappers, opposite policies, and the task brief asserted
  the fold for the forwarder.
- **Deleting one header orphaned citations in seven other files**
  (`fix_macho.sh`: `CMakeLists.txt`, `compat/README.md`,
  `compat/translate.sh` ×3, `src/rewrite.c`, `tests/change_dylib_test.sh`,
  `tests/cli_test.sh`, `README.md`) and another in four
  (`change_dylib.sh`: `compat/README.md`, `compat/add_version_min.sh`,
  `compat/retag_swift_classes.sh`, `src/rewrite.h`). A dense header is not a
  local cost; it is a hub, and deleting it is a link-integrity problem.
- **Two fixes made things worse before better.** A pointer in
  `cli/machotool.c` was repointed at `mr_is_rename_only` when the argument it
  cites lives in `mr_build_lcs_lc`'s comment in `src/rewrite.c` — a vague
  pointer replaced by a wrong one, which is strictly worse, since vague costs a
  search and wrong sends the reader somewhere confidently. (`mr_is_rename_only`
  itself no longer exists: item 5 derived its answer and deleted it. The line
  numbers this bullet originally carried were as of the sweep and had already
  drifted.) And a fourth stale pointer
  at `cli/machotool.c:291` was missed because the first three shared a
  phrasing and it did not: when a reorganization invalidates a claim, the stale
  references share the *claim*, not the wording.

**And the pattern the spec predicted holds, measured.** The prose closest to
the code was the most accurate, and the planning documents were the least.
`rewrite.c:1265` and pre-sweep `rewrite.h:404` (now `:158`) both stated the
`calloc` count correctly while the spec, the plan and this file all said three.
`change_dylib.sh:56` said the codes it produces *itself* are all 1 — exactly
right, and it was a *paraphrase* of that line, dropping "itself", that produced
the false fold claim. Twice the original comment beat the summary of it. The
mechanism is not "prose rots and code does not"; it is that **prose rots at a
rate set by how often a reader is forced past it** — a test is read on every
run, a comment when nearby code changes, a planning doc once. Which also means
the danger in a sweep is not deletion but *paraphrase*: deletion loses
information visibly, paraphrase loses it invisibly and leaves something that
still looks authoritative.

### The three deferred files: no second sweep plan

`src/rewrite.c` (1,425 / 759, 53%), `cli/machotool.c` (1,384 / 730, 52%) and
`src/grow.h` (321 / 206, 64%) were left out of the plan pending this decision.
**Recommendation: do not plan a second sweep for any of them.** The percentage
is what put them on the list, and the percentage turns out to be the wrong
metric.

Comment-to-code ratio, which is what a reader actually experiences:

| file | comment : code |
|---|---|
| `src/edit.h` (before) | 29.0 : 1 |
| `compat/fix_macho.sh` (before) | 13.0 : 1 |
| `compat/change_dylib.sh` (before) | 9.8 : 1 |
| `src/rewrite.h` (before) | 6.7 : 1 |
| `src/grow.h` | **3.8 : 1** |
| `src/rewrite.c` | **1.25 : 1** |
| `cli/machotool.c` | **1.21 : 1** |

The swept files ran 6.7× to 29× more prose than code. The two `.c` files run
about one comment line per code line. They read as 53% and 52% only because
they are long files that are *mostly code*; nothing in either is screens from
where the work happens, which was the complaint that started this item.

- **`src/rewrite.c` — no.** 1.25:1, and its comment mass sits beside live
  logic at the point of danger rather than in a header block (32 of 759 lines
  are the file header, 4%). Bucket-4 content is negligible: 14 lines carry a
  past-tense marker, 2 mention `macho9`, none cites a plan artifact. It is also
  where Task 5's mutation proofs were applied — two refusal sites, each mutated
  two ways — while being the one file the sweep was required to leave
  byte-identical afterwards. A sweep here is high risk against almost no
  bucket-2/4 yield.
- **`cli/machotool.c` — no**, for the same reasons and one more. 1.21:1; 136 of
  730 comment lines are the leading header (18%), the largest header block of
  the three, and that block is the `--capabilities` and exit-code contract that
  `tests/README.md` and `compat/README.md` both defer to. It holds the most
  history of any file in the tree (22 markers, 7 of them `macho9`), which is a
  real but small bucket-4 job — a handful of lines, not a plan.
- **`src/grow.h` — no, though it is the only close call.** 3.8:1 puts it just
  below the swept band, and 63 of its 206 comment lines are a file header. But
  read, that header is the *algorithm*: why this tool lowers the image base
  from `__PAGEZERO` instead of raising every later segment the way LIEF and
  llvm-objcopy do. That is bucket 5 and bucket 3 — an interface contract and a
  design decision a reader must have before touching the highest-risk file in
  the toolkit — and it is not convertible to a test. The per-declaration
  comments are return-value contracts every caller must check. The one passage
  the design spec named as this file's bucket-1 candidate, "`src/grow.h`'s
  account of why 32-bit is refused", **is not in `src/grow.h`**: it is at
  `src/grow.c:958-972`, in a file measuring 26%, and it already cites its own
  pinned regression test. The spec's headline example for the bucket was
  pointing at the wrong file, and the passage had already done what the bucket
  asks.

**What to do instead — and it splits in two.** Density did not predict falsity:
the defects sat in files that never met the worst-offender threshold. But the
`macho_grow` surface is *not* one uniform, zero-risk prose sweep, and the first
version of this recommendation said it was. **Corrected 2026-09-13**: half of
it is user-visible behaviour that no test pins, and sweeping it as prose would
have shipped a regression with every suite green.

**Part one: the filename citations — prose, and safe.** Eight retired filenames
are still cited: `macho_grow.h` (now `src/grow.h`), `macho_grow_test.c` (now
`tests/grow_test.c`), and the six retired tool sources `change_dylib.c`,
`fix_macho.c`, `patch_macho.c`, `rename_segment.c`, `add_version_min.c`,
`retag_swift_classes.c`. Counted 2026-09-13 after this correction: **108
occurrences in the code tree** (`src/`, `cli/`, `tests/`, `compat/`,
`CMakeLists.txt`) and **199 across the whole tracked tree excluding this file**,
the difference being `docs/`, `LICENSE` and `PROVENANCE.md`. The figure of **28**
given earlier was not wrong but narrow — it greped two of the eight names, in
the code tree, and at `3dc64aa` that scope held 21 + 7 (now 21 + 5, this round
having corrected two self-references in `tests/grow_test.c`). Some citations are
legitimate past-tense history (`src/grow.c:3`,
`src/mach_compat.h:22`), but about a dozen are present-tense directives telling
a reader to go read a file that is not there — `src/image.h:5`, `:75`, `:155`,
`src/image.c:49`, `src/linkedit.h:3`, `:29`, `:36`, `src/linkedit.c:130`,
`src/trie.h:3`, `:29`, `src/grow.c:971`, `CMakeLists.txt:187` — and
`src/grow.h:2` still names *itself* `macho_grow.h`. Every one of those files
measures under the worst-offender threshold and was therefore out of scope.
This part is cheap, mechanical, fully verifiable and carries no behaviour risk.
It belongs to item 7 (the history rewrite already touches the rename) or to the
human review that is item 6's second half.

**Part two: `src/grow.c`'s 48 stderr prefixes — not prose, and not zero-risk.**
`src/grow.c` has 50 lines mentioning `macho_grow`, and **48 of them are
`fprintf(stderr, "macho_grow: …")`** — user-visible diagnostic strings, not
comments. **No test pins that prefix**: a grep for `macho_grow: ` across
`tests/`, `cli/` and `compat/` returns nothing, while the same grep for
`machotool: ` hits three suites, so the negative has its positive control.
`tests/grow_test.c`'s own `macho_grow` mentions are prose plus its binary's
summary line (`macho_grow_test: all cases pass`), which asserts nothing about
`grow.c`'s stderr. Renaming those 48 as part of a prose sweep would therefore
change what users see with every suite passing.

It is also a genuine defect rather than untidiness. `src/rewrite.c:1142` states
the convention outright: the `"machotool: "` prefix there is "DELIBERATE and is
the one program-specific string in this file -- every other diagnostic here is
program-neutral ("ERROR: ..."), because this library does not otherwise know
which front end is running it." `grow.c`'s 48 prefixes name a program that no
longer exists, from a library that has no business naming one. Fixing them is
worth doing, but it needs **tests written first** — assertions on the new
prefix, mutation-proven — so it is **a plan of its own, and explicitly not part
of the zero-risk sweep**.

**A scope note, because these counts will not match across documents.** Bare
`macho_grow` occurrences: **84 in the code tree**, **122 across the whole
tracked tree excluding this file** — the extra 38 being `docs/`
(`docs/PROPOSAL.md` plus the plan and spec files), `LICENSE` and
`PROVENANCE.md`. Every number in this section
states its scope for that reason; a count given without one is not comparable
to another count given without one.

The generalization for that review: **the worst-offender threshold selected for
volume and the defects were distributed by hub-ness.** Rank by how many other
files cite a passage, not by what fraction of its own lines are prose.

### Two rules this plan earned, worth binding future work

- **A grep is evidence only once it has returned a hit on a case you know
  exists.** Four wrong claims on this plan came from greps that answered
  confidently about a question they had not asked: a pattern missing a backtick
  (the real text was ``No `break` ``, the grep said `No break`), `grep -c`
  counting a comment as an occurrence, a character class `[0-9]` excluding
  `exit "$mw_rc"`, and BRE `\|` passed to `grep -E`. State a negative from a
  grep only after a positive control.
- **A comment citing a test must not imply the test is exhaustive unless it
  is.** Where a claim has parts nothing can reach, the test's own comment names
  them and says why. A constraint may go untested when nothing can trigger it,
  but then somebody has to be told.

## For shipyard: build OUT of tree is documented but not operative

**DONE 2026-09-21, and done differently from the resolution below.** A survey of
all 15 org repos (not just the ones with presets) killed the preset-inspecting
check: it would have exempted clang and golang, which build from shell scripts.
What shipped instead asks what the source tree looks like AFTER a build, which
holds for any build system: shipyard's `scripts/assert-tree-clean.sh`, with a
committed `.mavericks-intree` allowlist, called before and after the build by
all 15 repos, each with a red run before its build moved and a green run after.
Conventions check 19 requires the pair of calls; check 20 requires
`CMakeUserPresets.json` to be gitignored wherever `CMakePresets.json` is
committed. shipyard's own ci.yml was the last in-tree build. A whole-branch
review then found four ways the assertion could pass when it should fail; all
four are fixed and mutation-tested (`81f5232`, `2b29718`, `8341e8d`).

Still open, both shipyard's:

- **Eleven workflows hard-code the path `${sourceDirName}` resolves to**, e.g.
  `"$MAVERICKS_BUILD_ROOT/tailscale-cross"`. `${sourceDirName}` exists because a
  checkout's directory name varies, so those eleven are right only for a default
  `actions/checkout`. This repo paid for exactly this once on 2026-09-20: the
  preset built into one directory, the workflow read another, and the tree-clean
  assertion was GREEN throughout, because a build that goes somewhere unexpected
  still leaves the source tree clean. Fix: a `shipyard-build-dir <mode>` helper,
  plus a test that its output equals the `binaryDir` CMake actually reports.
- **shipyard's own ci.yml prints two false "prune it" warnings** for `VERSION`
  and `dist/`, which only its release job writes. Exit 0, and ci.yml runs only on
  branches and pull requests, never on main, so it is rare noise; left rather
  than fixed with a new knob. The cost is that it teaches people to ignore the
  warning, which is how a stale allowlist rots.

What follows is the record as written on 2026-09-20.


Found 2026-09-20. `modernmavericks-conventions` SKILL.md already carries the
rule, with its own measurement on THIS repo — local disk 2.96s wall / 88% CPU
against in-tree-on-NFS 11.16s / 25%, user time identical at 1.78s vs 1.81s, so
the whole 3.8x is I/O wait. Nothing enforces it, and shipyard itself violates it.

- **SKILL.md contradicts itself.** One bullet forbids `${sourceDir}/build-*` in a
  committed `CMakePresets.json`; the closing bullet says CI is unaffected because
  "the shared presets keep working unchanged", which only holds if they use it.
- **Shipyard's own `mavericks-presets.json` uses `${sourceDir}/build-native`.**
- **No repo inherits it.** All five products with a `CMakePresets.json` are
  standalone; four use `${sourceDir}/build-*` (container-tools, macho-tools,
  magic-trackpad2, tailscale; openssh uses `build/updater`).
- **`check-family-conventions.sh` does not check this.** Its build-dir check (7)
  is about `.gitignore` COVERAGE, and it explicitly strips `${sourceDir}/` and
  accepts what remains.

**Resolution chosen by the repo owner 2026-09-20: enforce it with a conventions
check.** The shape that satisfies both SKILL bullets without declaring either
wrong is a committed `binaryDir` built from a VARIABLE —
`$env{MAVERICKS_BUILD_ROOT}/<repo>-native` — which is portable (no developer path
committed) and out of tree. Check 7's own comment already treats "a path built
from a variable like $RUNNER_TEMP" as having left the tree, so the checker's
model already contemplates this. Shipyard's install action exports the variable:
`RUNNER_TEMP` in CI, `/private/tmp/build/$USER` locally.

**Sequencing.** The check cannot land alone — it reddens four repos the moment it
ships, and macho-tools is one of them. It lands together with the five repos'
preset changes and the workflows that hardcode a build dir (this repo's
`release.yml` names `build-cross` three times: the `characterize.sh` and
`chained-fixups.sh` invocations and the `cp "build-cross/$f" dist/` staging loop).
Deliberately NOT started while the 2026-09-20 retype/imports plan is in flight,
because reddening this repo's CI would mask that plan's own signal.

Interim, already done: `CMakeUserPresets.json` (gitignored, per SKILL's prescribed
mechanism) now exists in this checkout with `native-local` and `cross-local`
pointing at `/private/tmp/build/$USER/macho-tools-*`. Verified: configures in
0.29s.

## For shipyard: two gaps a self-upstream repo falls through

Found 2026-09-12 while making this repo releasable. Both are shipyard's, not
this repo's, and both are the same shape: machinery written for the **port**
case that silently does nothing for a repo that is its own upstream.

- **`previous-release-tag.sh` globs `*-mavericks.*`.** An `X.Y.Z` tag can never
  match, so `PREV` is permanently empty here and **no release body will ever
  carry its `[All changes since X](…/compare/…)` footer** — not just the first
  one. Verified against a scratch repo tagged `0.1.0`, `0.2.0`, `backup/foo`:
  every lookup returns empty. Teaching it the self-upstream shape would give
  releases 2+ their compare link.

  **Bigger than first recorded** (confirmed 2026-09-12 by the shipyard
  session): this is not only the hypothetical self-upstream repo. **Shipyard's
  own tags are `v1.0.N`**, which never match `*-mavericks.*` either — so
  shipyard's own release bodies have never carried a compare footer, live,
  today, in the repo the whole family consumes.
- **`release-notes-file.sh` hardcodes "Requires Mac OS X 10.9.5 or later"** —
  the `.pkg` floor — while these binaries target 10.9. Harmless for a repo that
  ships a `.pkg`; wrong for one that ships bare binaries.

  **Currently unreachable, so do not spend a morning on it** (confirmed
  2026-09-12 by the shipyard session): on shipyard's main its only references
  are `check-shell-portability.sh` and its own test. Zero production callers —
  it is a back-compat wrapper whose six callers were deleted. The bug is real
  and nothing reaches it.

Neither blocks a release. Both want a shipyard change rather than a local
workaround, since a workaround here would be the fourth copy of a thing that
should live in one place.

## Outstanding owner actions

- Review the four specs above (items 2–5).
- **The three rename steps are deferred to item 7**, immediately before the
  history rewrite — not to item 3. See below.

## The rename steps sit with the history rewrite, not with item 3

Item 3 renames the *product*: the binary, the CMake targets, the shared wrapper
scripts, the prose. That is all in-tree and lands on its own. The three steps the
repo owner takes — moving the agent's project directory, moving the clone,
renaming the GitHub repo — are about **where things live**, and were checked
against the tree rather than assumed:

- **Nothing in the repo keys on the clone's directory name.** The only
  `macho-tools` strings outside `docs/` are `CMakeLists.txt`'s status messages
  and `release.yml`'s artifact name, and item 3 renames both as product names
  wherever the clone happens to sit.
- **The build directories are a convention, not a derivation.** No shipyard
  script generates `/private/tmp/mm-build/schmonz/macho-tools/…` from the repo
  path. Moving the clone does invalidate the configured build dirs, because
  `CMakeCache.txt` holds absolute source paths — one reconfigure, not a redesign.
- **Both checkout roots are one filesystem object** (same inode), so moving
  either moves both views at once.

So the product rename and the location rename are independent, and the location
rename belongs here because **the history rewrite is the other change that
invalidates infrastructure** — every commit SHA cited across these docs and the
SDD ledgers. Doing both at one break costs one disruption instead of two.

**The order within the pair is still invariant.** The project directory must move
immediately before the clone, in the same sitting, with no session live in that
directory:

```sh
mv ~/.claude/projects/-Users-schmonz-Documents-code-trees-mavericks-macho-tools \
   ~/.claude/projects/-Users-schmonz-Documents-code-trees-mavericks-machotool
mv ~/Documents/code/trees/mavericks-macho-tools \
   ~/Documents/code/trees/mavericks-machotool
```

Renaming the clone first orphans the memories and every transcript of this work.

**The GitHub rename is independent of both** and can happen whenever — GitHub
redirects the old URL, so the local remote keeps working either way. Grouping it
here only keeps the mental model to one "rename day".

## Item 7 also purges `docs/superpowers/` from history

**Standing rule, stated by the owner 2026-09-15:** superpowers docs are
**ephemeral**. A spec or plan lives long enough to get implemented and is then
deleted. The code survives; the plan for getting from previous-code to this-code
does not. This repo has been violating that since `868e2a6`, the first plan.

It belongs to item 7 for the reason item 7 already groups its other work: a
history rewrite is what makes the deletion real. Removing these files at the tip
leaves ~14k lines in the objects forever, and the rewrite is already
invalidating every commit SHA cited across these docs and the SDD ledgers. One
disruption instead of two.

**What is tracked today:** 26 files, 13,920 lines, 755K.

| path | count | disposition |
|---|---|---|
| `docs/superpowers/plans/` | 14 | purge — these are the route, not the destination |
| `docs/superpowers/specs/` | 11 | purge |
| `docs/superpowers/QUEUE.md` | 1 | **owner's call** — see below |

### The purge is blocked on removing a comment tag first

This is the part a naive `filter-repo` gets wrong. The comment standard
established by item 6 blessed exactly **two** tags, `platform:` and `spec:`, and
`spec:` is *a path into `docs/superpowers/specs/`*. So the violation became
load-bearing: **15 files carry 25 citations, and production `.c`/`.h` are among
them** — `cli/machorewrite.c` (3), `src/rewrite.c` (3), `src/script.h` (2),
`src/relations.h` (2), `src/edit.c` (2), `src/rewrite.h`, `src/edit.h`,
`compat/translate.sh` (4), `compat/README.md`, `CMakeLists.txt`, and five test
files. Every citation resolves today; all 25 dangle the moment the files go.

Only **5** distinct documents are cited. The other 21 are referenced by nothing.

Order of operations, and none of it is optional:

1. **Drop `spec:` from the comment standard**, leaving `platform:` as the only
   tag. A blessed tag that points at a deliberately ephemeral file is the
   mechanism that turned scratch into a dependency, and it will re-create the
   problem on the next plan if it survives.
2. **Rewrite the 25 citations.** Sampled, most are attribution attached to prose
   that already carries the substance (`spec: … -- Decision 5, the derived
   applicability governs both front-ends`) — there, strip the path and keep the
   sentence. Where a comment leans on the spec to carry the meaning (`spec: …
   says why keeping both spellings was expensive`), **inline the why**, because
   after the rewrite there is nowhere for a reader to go. Losing a reason is a
   worse outcome than keeping a file.
3. **Then** purge, so the rewrite does not have to rewrite the citing files too.

### `QUEUE.md` is the one genuine question

The rule names specs and plans — the route from previous-code to this-code.
`QUEUE.md` is neither: it is the living backlog, and items 8 and 12–15 have not
been implemented, so it has not finished being true. Purging it discards
unimplemented work; keeping it under `docs/superpowers/` keeps a directory the
rule says should not exist. Most likely answer is that it survives the purge
under a different path, but that is the owner's call, not a ruling to take.

## Items 17–20, queued 2026-09-21

### 17. Convert a newer NIB to one 10.9 can load, without Xcode

**What is known.** A 2026-09-21 session outside this repo (transcript
`~/.claude/projects/-Users-schmonz-Downloads/9413ca21-….jsonl`) analyzed a
modern app for 10.9 and found every one of its 15 compiled nibs in the
`NIBArchive` format (magic `4e49 4241 7263 6869 7665`). 10.9's AppKit rejects
all of them:

    -[NSKeyedUnarchiver initForReadingWithData:]: incomprehensible archive (0x4e, 0x49, 0x42, 0x41 ...

That session's reading was that **the objects inside are fine** — it is the
container format, not the contents, that 10.9 cannot read. Which makes the
converter a re-serialisation (`NIBArchive` → `NSKeyedArchiver` plist), with a
second, separate pass for classes 10.9 lacks (the same session parsed the class
tables to find them; pan gesture recognizers were one). It also guessed that
`ibtool` writes the old format when targeting 10.9 and said it had not verified
that. Unverified; the point of this item is to not need `ibtool` at all.

**Prior art: it worked, end to end, in mavericks-1password.** Commits
`22293ab`, `dff06c5` (2026-07-09) added `viewer/nib2bplist.py`, 148 lines, which
converted NIBArchive to classic `bplist00` `NSKeyedArchiver` for the Chicken of the
VNC back-port. It parsed with the PyPI `nibarchive==1.1.0` package, wrote with
`plistlib`, and ran from the Makefile over every
`Base.lproj/*.nib/keyedobjects.nib` whose first bytes are `NIBArchive`. The
result: the app launched on 10.9.5 and completed a real RFB session. It was
retired with the whole viewer in `2c169a1` (2026-07-12) when OPXpra reached
parity, and not because it failed. Recover it with
`git -C ../mavericks-1password show 2c169a1^:viewer/nib2bplist.py`. The
write-up offered upstream is in 1password's `docs/ays7-chicken-10.9-support.md`,
§3, which is gitignored and on disk only.

What a general tool must do that the script did not:

* **Class hierarchies.** NIBArchive stores a class name but not its superclass
  chain, and `NSKeyedArchiver`'s `$classes` needs the chain. The script
  hard-coded 35 AppKit classes (`HIER`) and fell back to `[name, NSObject]` for
  the rest. That was enough for one small app and wrong for anything else: a
  custom `NSView` subclass would claim to descend from `NSObject` alone. A
  general tool needs the real chains. Candidate sources are the ObjC metadata in
  the app's own binary, via this repo's parsers, plus a table for AppKit.
* **Value types.** It exited on any value type it did not handle ("unhandled
  value type"). That is the right failure, but coverage was only as wide as one
  app's nibs.
* **Dependencies.** A Python dependency from PyPI does not suit a repo whose
  tools are C with a 10.9 floor. Either port the parser, or make the Python
  dependency a deliberate choice.

The same 1password write-up says `ibtool` historically honours a low
`--minimum-deployment-target` and emits the older format, and that recent Xcode
may no longer do so. That is unverified, and it is moot: the point of this item
is not to need Xcode.

Also checked: the local `chicken` checkout's `4624382 old nibs converted` is a
third party's conversion in the other direction (old to newer), so it is not
prior art for this item.

**Neighbours.** Storyboards (10.9 has no `NSStoryboard`; it arrived in 10.10) and
asset catalogs (`Assets.car`) are the same shape of problem — see item 20.

### 18. "Will this run on Mavericks?" for an arbitrary binary or `.app`

Output is one of two things: **ready to try**, or **as exhaustive a list as
possible of what stands in the way**. Exhaustive is the requirement: a tool that
stops at the first blocker sends someone round the loop once per blocker.

Most of the parts exist and this is mostly composition:

* shipyard's `scripts/assert_binary_compatible.sh` already checks a *built*
  binary for post-10.9 undefined imports, post-10.9 ObjC selectors, arch and
  `LC_VERSION_MIN_MACOSX` — but it is a fail-fast guard for our own builds, not a
  report on someone else's app;
* this repo's `imports` verb (item 13 gap 7) already emits every import,
  weak or not, as TSV — the raw material for the symbol half.

What the report needs that neither does: walking an `.app` (every Mach-O in
`Contents/MacOS`, `Frameworks`, `PlugIns`, `XPCServices`, `Library/LoginItems`),
`Info.plist`'s `LSMinimumSystemVersion`, `LC_BUILD_VERSION` vs
`LC_VERSION_MIN_MACOSX`, chained fixups, relative ObjC method lists (item 13 gap
6), the Swift runtime, code-signature formats 10.9's `codesign` cannot read,
`NIBArchive` nibs (item 17), storyboards and `Assets.car`. Each finding should
say whether a tool in this repo already closes it — which turns the report into a
plan, and is the reason it belongs here rather than in shipyard.

### 19. A new name for this repo: **drydock**

**Decided by the repo owner 2026-09-21: the repo will be called `drydock`.** A
drydock is where a ship is hauled out to be refitted. The name sits beside
shipyard and porthole, and it covers what the repo is becoming: a nib
converter and an app-readiness report, neither of which is about Mach-O.

**Not yet: the rename waits for the right point in the sequence.** Item 7
already carries "the three rename steps" and rewrites history, and the rename is
cheapest done in that same pass. Do it there, not as a separate step first. The
product binary `machotool` is a separate question. It does edit Mach-O files, so
the repo name does not force a change to it.

### 20. Other tools that belong here

Ranked by how often the gap would bite, not by size:

1. **Re-sign for 10.9 after an edit.** Every rewrite this repo performs
   invalidates the signature, and a modern signature can carry forms 10.9's
   `codesign` does not understand. Strip-and-ad-hoc-sign as a verb, so the last
   step of a backport is not a hand-typed `codesign` line.
2. **Downgrade an asset catalog.** A newer `Assets.car` is item 17's problem in
   a different container. Probably the second-most common blocker item 18 reports.
3. **Storyboard to nibs.** 10.9 has no `NSStoryboard`. Larger than item 17,
   because it is a change of structure rather than of serialisation.
4. **Generate a shim dylib from item 18's gap list.** The report names the
   missing symbols; a generator stubs them and `dylib insert` adds the load
   command. The runtime half of item 15.
5. **`Info.plist` floor edits.** shipyard's `scripts/set_install_floor.sh`
   already does part of this for our own pkgs; an app-level verb would belong
   here.

### 21. Rehome Mavericks-Porting-Resources

Wowfunhappy is open to the repo owner reorganising everything in M-P-R into the
owner's own repos. Surveyed 2026-09-21 at upstream `master` `6ead179`
(2026-09-08), 217 files, identical in file set to the fork's checkout at
`../Mavericks-Porting-Resources`. Its own `Readme.txt` says it is almost entirely
AI-generated code that no human has reviewed, so treat every piece as a lead to
verify, not as working code to copy.

**Already placed. Nothing to do.**

| M-P-R | where it went |
|---|---|
| `patch_macho.c`, `change_dylib.c`, `add_version_min.c`, `fix_macho.c`, `rename_segment.c`, `retag_swift_classes.c`, `macho_grow.h` | this repo: `machotool` plus the `compat/` wrappers under the old names |
| `avxemu/` (AVX2/FMA/BMI on Sandy/Ivy Bridge) | its own repo, `mavericks-avxemu`. A local checkout exists with no remote yet; its last commit records an open licensing question. `docs/PROPOSAL.md` covers it |

**For drydock, as tools.** Each of these is a tool rather than a library, and
none is tied to one app:

1. **`syscall_trace.c`**, 242 lines. A `DYLD_INSERT_LIBRARIES` interposer that
   logs selected libSystem calls (socket, connect, kevent64, read/write and
   others) with timestamps. Built for diagnosing a ported binary on 10.9
   without dtrace. It is the **runtime half of item 18**: item 18 says what
   *should* fail, and this shows what *did*.
2. **The wrapper-dylib technique**: `build_wrappers.sh` plus
   `libsystem_wrapper_build.md` and `icu_wrapper_build.md`. A wrapper dylib
   re-exports the real 10.9 library and adds the symbols it lacks. The script
   is hard-wired to one app and one person's paths (`Ex-Zodiac.app`,
   `/Users/Jonathan/...`). What generalises is a verb: "wrap framework F,
   adding symbols S, and repoint the binary's load command at the wrapper",
   which `machotool`'s `dylib` rows already half-do. This is item 20.4's shim
   generator with a worked method behind it.
3. **`framework-stubs/`**, 34 files, with a README that separates **stubs** (the
   framework does not exist on 10.9, e.g. CoreSpotlight or UserNotifications:
   define the bound symbols, do nothing) from **wrappers** (the framework exists
   but lacks a symbol, e.g. AppKit's `NSHapticFeedbackManager`: add it and
   re-export the real one). That split is the right design for item 20.4. The
   34 files are a library of outputs, so they belong beside the generator, or
   in a repo of their own if they grow. They are not in this repo's core.

**Not for drydock. Each has a better home.**

| M-P-R | better home | why |
|---|---|---|
| `mavericks-legacy-support/` (the libSystem gap-fillers the wrapper recipes link) | **its own org repo, and org `macports-legacy-support` is retired or folded into it**, per the repo owner 2026-09-21 | see below |
| `dotnet_polyfills.c`, `security_seckey_rsa.c`, `security_wrapper_stubs.c`, `cxx_stream_stubs.cpp` | the same library | `dotnet_polyfills.c`'s own header says so ("fold them in there") |
| `swift-backdeploy/patch_swift_custom_rr.py`, `legacy-swift-stubs/` | org `swift-runtime` | the patcher's header names ModernMavericks swift-runtime's patches 0003–0005; it exists only because of that runtime |
| `compat_headers/`, `macos_compat.h`/`.mm` | the legacy-support headers | compile-time shims for source builds, and `macos_compat.h` names Godot |
| `velopack_updatemac_stub.c` | with an osu! port, if one is made | specific to one app |
| `CLAUDE.md`, and the fork's `mavericks-porting-skills` branch (`04de6a0`, "Add Claude agent skills and conventions for Mavericks porting") | shipyard's `claude-plugins/modernmavericks` | a porting playbook is a skill, and that plugin is where the family keeps its skills |

**legacy-support: the direction, and what to check first.** The repo owner
believes M-P-R's `mavericks-legacy-support` is a superset of MacPorts' and
should get its own org repo, with the org's `macports-legacy-support` retired or
folded into it. Its README bears that out in part. The polyfill code is
"copied verbatim from MacPorts", with the plumbing that targets 10.4 through
current removed (SDK and target detection, the `__MPLS_SDK_*`/`__MPLS_LIB_*`
gates). On top of that it adds the custom libSystem shims, such as
`__ulock_wait`, `kevent64` and the `dlopen` handling, that
`libsystem_wrapper_build.md` says used to live in `modern_api_polyfills.c`. So it
is a superset in *functions for 10.9* and a subset in *OS range*, which is the
trade this family wants. Two things to settle before retiring the org repo:

* **Following upstream.** The org repo packages MacPorts `v1.5.2` unmodified,
  fetched by `build/fetch-upstream.sh` and bumped by Renovate from
  `macports/macports-legacy-support` tags. The verbatim copies in the spin have
  nothing tracking them. Folding in the org repo without adding an equivalent
  means MacPorts' fixes stop arriving.
* **Measure the superset claim.** Compare the spin's function list against
  MacPorts `v1.5.2`, and check what the org repo's current users link against,
  before retiring anything.

**Before any of it moves:** agree the plan with Wowfunhappy, and settle
licensing per piece. avxemu's is already an open question, and a file moving
between repos carries its licence with it.

