# Design: drydock, slice 1 — missing symbols, end to end

Brainstormed with the repo owner 2026-09-21. The first sub-project of turning
this repo into **drydock** (queue item 19): a system that takes real
too-new-for-Mavericks binaries, recognises their gaps, applies durable repairs
automatically, and reports the short list it cannot yet fix, improving with
every binary it is given.

## Decisions that shape everything

| question | decision |
|---|---|
| Who operates drydock? | **An agent in a porting session, for now.** The goal is the repo owner operating it by hand, with an agent called in only when drydock meets a gap it does not know yet. So the knowledge must live in drydock (code, data, tests), not in agent sessions. |
| How does an agent's fix become part of drydock? | **A catalog entry plus a test that fails without it**, landed like any other change. Nothing enters unverified; the next binary with that gap gets the repair automatically. |
| What does "ready" promise? | **Graded: loads, launches, works.** Drydock claims only the level it measured. *Loads*: analysis says dyld binds everything. *Launches*: it ran on 10.9 and survived a first-run check. *Works*: a person confirmed it. A stub repair caps a binary at *loads* until it is run. |
| Where does drydock run? | **Analysis and repair anywhere** (a modern Mac, CI, or 10.9), as `machotool` already does. Only *launches* needs a 10.9 machine. |
| First slice | **One gap class end to end — missing symbols** — so every stage boundary meets real data before any of them hardens. Later gap classes (formats, nibs, signatures) are further slices, not redesigns. |

## Gap vocabulary

Every gap has a stable ID. This slice defines three kinds:

| kind | ID | meaning | blocks *loads*? |
|---|---|---|---|
| missing library | `library:<install_name>` | the binary loads a library 10.9 does not have at all (e.g. `/usr/lib/swift/libswiftCore.dylib`). One gap, not one per symbol. | yes |
| missing symbol | `symbol:<install_name>:<symbol>` | a non-weak import that 10.9's copy of that library does not export, directly or through its re-exports | yes |
| missing weak symbol | `weak-symbol:<install_name>:<symbol>` | the same, imported weak: it resolves to NULL and calling it crashes | no, but reported |

IDs are the join key for everything else: `inspect` emits them, catalog
entries declare which ones they close, the scoreboard counts them.

## Ground truth: what 10.9 actually exports

`drydock harvest`, run on a real 10.9.5 system (the repo owner's machine is one:
build `13F1911`), records every library a 10.9 binary can load — `/usr/lib`,
`/System/Library/Frameworks`, `/System/Library/PrivateFrameworks` — with each
one's install name, exported symbols, and re-exports. The result is committed as
data, stamped with the OS build it came from.

The running system is the authority, not the 10.9 SDK, whose stubs can disagree
with it. The size of the full harvest is **not yet measured**; if it is too large
to commit comfortably, the fallback is public frameworks plus `/usr/lib`, and the
choice is recorded with the measurement.

## `drydock inspect <binary or .app>`

1. Walk every Mach-O in the input (for a bundle: `Contents/MacOS`, `Frameworks`,
   `PlugIns`, `XPCServices`, `Library/LoginItems`).
2. Take each one's imports from the existing `imports` verb.
3. Resolve each (install name, symbol) against the harvested exports, following
   re-exports (`libSystem` re-exports `libsystem_*`; umbrella frameworks
   re-export sub-frameworks). Libraries shipped inside the bundle (`@rpath`,
   `@executable_path`, `@loader_path`) resolve against their own exports, and are
   inspected in turn.
4. Emit TSV with a header, one row per gap, columns only ever appended (the rule
   `imports` already follows), then a summary line.

Anything `inspect` cannot classify is reported as a gap, never skipped.

**Outside this slice, deliberately:** ObjC selectors sent at runtime (not binds,
so invisible to `imports`); `dlsym` and `NSClassFromString` (the runtime trace,
queue item 22, catches those); resource and file formats.

## The catalog

Under two-level namespace an import names its library, and dyld looks only in
that library and what it re-exports. Adding a shim library therefore does
nothing on its own. The two repair shapes Mavericks-Porting-Resources proved:

* **wrapper** — the library exists on 10.9 but lacks the symbol. A small dylib
  re-exports the real library and defines the symbol; the binary's load command
  is repointed at the wrapper (`dylib replace`, which `machotool` already has).
* **stub** — the library does not exist on 10.9. A dylib defining exactly the
  symbols the binary binds; the load command is repointed at it.

A catalog entry is plain text beside its source, parseable from `sh` and C:

| field | content |
|---|---|
| `provides:` | the gap IDs it closes |
| `grade:` | `real` (a genuine implementation) or `stub` (returns failure or does nothing) |
| `source:` | the implementation — in this repo, or an external provider. libSystem gaps point at `mavericks-legacy-support` once it is its own org repo (queue item 21), rather than copying it |
| `test:` | one that **fails without the entry**: a behaviour test run on 10.9 for `real`, a load test for `stub` |
| `provenance:`, `license:` | where it came from; item 21 already makes both a precondition for moving code between repos |

## Building repairs

Drydock's CI builds **one wrapper per library carrying every catalog entry for
it**, and one stub per missing library, cross-built for x86_64 with a 10.9 floor
like every family artifact, and publishes them as release artifacts. Nothing is
compiled per binary: a repair is a copy and an edit. The wrappers fall under the
reproducible-builds convention proposed in shipyard's `BACKLOG.md` entry 20.

## `drydock repair <in> <out>`

1. `inspect`; look each gap up in the catalog.
2. Copy the needed wrappers and stubs **into the output**
   (`Contents/Frameworks/drydock/` in a bundle; beside a bare binary, reached via
   `@loader_path`). The system is never touched.
3. Repoint each affected load command with a `machotool edit` script. The input
   is never written; `machotool` already guarantees that.
4. Re-sign ad hoc, since editing invalidates the signature. Known soft spot: 10.9's
   `codesign` may not read newer signature formats, so stripping may have to come
   first. Queue item 20.1 generalises this.
5. `inspect` the output. What remains is the short list. *Loads* is claimed only
   when no blocking gap remains; stub repairs are listed by name.

## The corpus and the scoreboard

Third-party binaries cannot be committed, so the corpus is a list — name,
download URL, version, sha256 — fetched on demand and cached by checksum.
**Results are committed**: a scoreboard TSV with one row per binary giving gaps
before repair, gaps after, the grade reached, and how many repairs were stubs.
CI regenerates it on every change, so progress is a diff to one file over time,
and it is the measured answer to "what percentage just works?". Grade columns
exist for *launches* and *works* from the start; this slice fills only *loads*.

First entries: **TaskExplorer** (Objective-See) — a 2026-09-21 session already
produced a hand-made version of this report for it (about 10 missing symbols,
queue item 18) — plus two or three more chosen with the repo owner.

## The loop an agent follows

When `repair` leaves gaps:

1. `drydock inspect` names the short list.
2. For each gap, add a catalog entry and its test — from `mavericks-legacy-support`
   or Mavericks-Porting-Resources first, new code only when neither has it.
3. `drydock score`: that binary's row improves, and **no other row may regress**.

Written down as a drydock skill in shipyard's `claude-plugins/modernmavericks`,
beside the family's other skills, so every agent session runs the same loop.

## Safety

* **Every catalog entry's test must fail without that entry**, enforced by CI:
  rebuild with each entry removed in turn and require its test to fail. An entry
  that proves nothing cannot land. The wrappers are small, so this is expected to
  be affordable; the cost is measured before it is relied on.
* Unclassifiable input is a gap, never a skip.
* The input is never written; `repair` re-inspects its own output before claiming
  a grade.

## Plans

One spec, two plans:

1. **Recognising:** `harvest` and the committed 10.9 exports, `inspect`, the
   corpus list, and a scoreboard of gaps. Useful to agents on its own.
2. **Repairing:** the catalog format, the first entries (TaskExplorer's
   symbols), wrapper and stub builds, `repair`, the automatic
   entry-must-matter check, and the skill.

## Not in this slice

* the *launches* level — next slice; the repo owner's 10.9 machine is the rig,
  with the runtime trace (queue item 22);
* nibs and other formats (items 17, 20);
* ObjC selectors, `dlsym`;
* the repo rename (item 19), which stays with item 7.
