# Growing a dylib's header

Every statement that adds or lengthens a load command needs header pad, and
`mg_ensure_pad` (`src/grow.h`) grows the pad when it is short. Today it can
only grow a PIE executable: it lowers the image base into `__PAGEZERO`, and a
dylib or bundle has none (`ERROR: only MH_EXECUTE can be grown`). This spec
adds a second route for `MH_DYLIB` and `MH_BUNDLE`, so that `dylib insert`,
`dylib append`, `dylib replace`, `rpath add`, `rpath replace`,
`minos if-absent` and every later statement that needs pad work on
frameworks with no change of their own.

## Why

**Real dylibs have almost no pad.** Measured 2026-09-25: the three x86_64
frameworks in `~/Downloads/OpenCode.app` (Mantle, ReactiveObjC, Squirrel;
macOS 12 target) have 16, 24 and 16 bytes. An `LC_LOAD_DYLIB` or `LC_RPATH`
for a realistic path needs 50 to 100.

**The work that needs it:**

- `docs/macl-case-study.md` row 23: MACL injects its stub library "into the
  main binary and every framework". The case study credits `dylib insert`
  with this. On a framework with 16 bytes of pad Drydock refuses today, so
  that row overstates what Drydock does; row 9 (injecting a bundled CoreUI)
  has the same shape.
- Mavergreen swift-runtime's README tells users to run
  `rpath replace /usr/lib/swift /usr/local/mavergreen/swift-runtime/lib/swift`.
  The new path is 32 bytes longer, so on a framework carrying that rpath it
  needs pad that is not there.
- objc-methods (`specs/2026-09-23-objc-method-lists-design.md`, Decision 1)
  had to abandon its first layout for the same reason. It does **not**
  change back once this lands; that spec says why.

**What the existing grow refuses.** `mg_classify` run over 321 real dylibs,
each thinned to x86_64 (`lipo -thin`), 2026-09-25:

| where | accepted | refused: `LC_SEGMENT_SPLIT_INFO` | refused: chained fixups |
|---|---|---|---|
| 10.9 system (`/usr/lib`, `/System/Library/Frameworks`) | 2 | 283 | 0 |
| app frameworks (`/Applications`, `~/Downloads`) | 24 | 3 (Sparkle ×2, RegexKit) | 4 |

Also measured on the same set: old-style relocation entries
(`LC_DYSYMTAB` `nlocrel`/`nextrel` > 0) in 5 images, all built for 10.5 or
earlier (Sparkle ×2, RegexKit, `libnetsnmp` ×2); no x86_64 image rebases or
binds into `__TEXT` (two hits were 32-bit-only frameworks that thinning
passed through).

## Decisions

### 1. Two routes, one rule

`mg_grow_header` chooses its route by file type:

- `MH_EXECUTE` with `MH_PIE`: **lower** the image base, as today. Unchanged.
- `MH_DYLIB` or `MH_BUNDLE`: **raise** the contents, below.
- Anything else: refused, as today.

**The raise.** Let F be the first section's file offset (the end of the
pad, `mg_first_sect_off`) and G the shortfall rounded up to a 4 KB page
(`MG_PAGE`), so every section keeps its alignment. G zero bytes are inserted
at file offset F. Every byte from F to the end of the file moves up by G in
the file, and everything it holds moves up by G in vm. The header and the
load commands stay at file offset 0 and at `__TEXT`'s `vmaddr`.

**Why most of the existing machinery is already right.** Measured from the
image base, both routes move every section up by G: the executable route by
moving the base down, the dylib route by moving the contents up. So every
structure that stores a distance from the base gains G in both routes, and
the walkers `grow` already has for them apply unchanged: `__unwind_info`
(`mg_unwind_walk`), the export trie (`mg_trie_walk`), the leading
`LC_FUNCTION_STARTS` delta (`mg_reencode_funcstarts_base`),
`LC_DATA_IN_CODE` (`mg_dice_walk`) and `S_INIT_FUNC_OFFSETS`
(`mg_init_offsets_pass`). What differs is absolute vm addresses: the
executable route leaves them alone, and the dylib route must add G to each.

**The one rule.** An address, absolute or base-relative, that names the
header or load commands, meaning it is below the first section's old
address, is unchanged. An address that names content at or above it gains
G. The existing code already follows the first half for executables: export
offset 0 is `__mh_execute_header` and stays 0 (`src/grow.h`, the export-trie
note). For a dylib the header-namers are the `__mh_dylib_header` or
`__mh_bundle_header` symbol and every `__dso_handle` pointer, which C++
`atexit` and thread-local variables use.

### 2. What changes

| structure | change | by |
|---|---|---|
| each segment after `__TEXT`: `vmaddr`, `fileoff` | +G | new |
| `__TEXT`: `vmsize`, `filesize` | +G | new |
| each section: `addr` | +G (a zerofill section's `offset` stays 0) | new |
| each section: `offset`, `reloff`; every `__LINKEDIT` offset | +G | existing, `mg_each_fileoff` |
| the pointer value at every rebase target | +G if it names content (the rule) | new |
| symbol `n_value`: `N_SECT` symbols, and stabs with `n_sect != NO_SECT` | +G if it names content | new |
| `LC_ROUTINES_64.init_address` | +G | new |
| unwind info, export trie, function starts, data-in-code, `__init_offsets` | +G | existing walkers |
| rebase and bind opcodes (segment index + offset within it) | none: segments move whole, and none may target `__TEXT` (Decision 4) | — |
| RIP-relative code, `__eh_frame`, LSDA tables, Swift metadata, relative Objective-C method lists | none: relative distances within the image do not change | — |
| `LC_SEGMENT_SPLIT_INFO` | the load command is deleted (Decision 3) | new |
| `LC_CODE_SIGNATURE` | offset bumped; the signature is invalid, as after every edit | existing |

**Why the list is complete.** A dylib always slides, so every absolute
address in it must be adjusted at load time, and dyld adjusts only what a
rebase, a bind or a load-command field names. So an absolute address can
live only:

- at a rebase target (handled);
- at a bind target, whose file contents dyld overwrites (nothing to do; a
  lazy pointer's initial stub-helper address is itself a rebase target);
- in a symbol `n_value` or a load-command field (handled).

Any absolute address in `__TEXT` would need a text relocation, which
Decision 4 refuses. Everything else stores a distance from the base (handled
by the existing walkers) or from its own location (invariant). A load
command or section type outside this accounting is refused by
`mg_classify`'s allowlist, which already treats unknown as unsafe.

**The rebase decoder.** Adding G to every rebase target's value needs a
complete classic rebase-opcode decoder. `md_next_rebase` reads only the two
opcodes its own encoder emits. objc-methods M2 creates `src/rebase.[ch]`
(`mrb_`) with a complete one. This subsystem consumes it; whichever plan
executes first builds it, and the other depends on that plan's interface.

### 3. `LC_SEGMENT_SPLIT_INFO` is dropped, and the announcement says so

Split info lists every cross-segment reference in a dylib, so that
`update_dyld_shared_cache` can pack the dylib's `__TEXT` and `__DATA` into
separate regions of the shared cache and patch the references to the new
distance. Nothing reads it when a dylib loads from its own file, and 10.9's
dyld never reads it. After a raise its recorded positions are stale:

| after a raise | loading from disk | a shared-cache build |
|---|---|---|
| stale split info (never an option) | works | corrupts the cache |
| re-based | works | works, if the re-basing is right; no test here could tell |
| **dropped (chosen)** | works | skips this dylib, safely |
| refused (today) | growth never happens | — |

Dropping is the only choice whose result this subsystem's tests can fully
check. It removes the 16-byte load command, which also adds 16 bytes of pad,
and leaves the payload as dead bytes in `__LINKEDIT`. The input file keeps
its split info, since Drydock never writes its input. Only a raise drops it:
an executable grow still refuses split info, as today. Letting it drop too
is a separate, later decision.

**This breaks an invariant `src/rewrite.c` states.** Its comment before the
counting pass says a grow does not change the SET of load commands, only
offsets elsewhere. A raise that drops split info does change it. Both
callers of `mg_ensure_pad` are already safe:

- `mr_process_thin` rebuilds its new table from the grown image, so the
  dropped command does not reappear.
- `mv_` appends to the grown image.

But the comment becomes false, and an operation that names split info
itself (for example an `lc delete` of it, if the grammar accepts one) would
match in the counting pass and not in the rebuild. The plan must:

- correct the comment;
- find every operation that can name split info;
- make the rebuild's result, not the counting pass, decide what is
  reported for it.

### 4. Refusals

`EX_REFUSED` with the reason on stderr and nothing written, before anything
is mutated:

- anything `mg_classify` refuses today, except `LC_SEGMENT_SPLIT_INFO` on
  the raise route;
- chained fixups (`fixups set classic` first), as today;
- a slice that is not x86_64, as today;
- old-style relocation entries (`LC_DYSYMTAB` `nlocrel` or `nextrel`
  non-zero): they hold absolute addresses by another mechanism, and only
  binaries built for 10.5 or earlier carry them, which mostly run on 10.9
  already;
- a rebase or bind whose target lies in `__TEXT` (a text relocation);
- a rebase target whose value names neither the header nor content, i.e.
  lies outside every segment's vm range;
- the existing ULEB-widening refusals (function starts' leading delta),
  and the export trie's existing widen-append path, unchanged;
- an image with no `__TEXT` segment at file offset 0, or whose `__TEXT` does
  not come first in vm.

### 5. Verification

The raise verifies itself and refuses, writing nothing, on any difference:

1. **Relation.** `mg_snapshot_take` / `mg_verify` gain a delta: 0 for the
   executable route and G for the raise. Every base-relative structure and
   every `mg_each_fileoff` offset must resolve at its old vm address plus the
   delta, or unchanged if it named the header.
2. **Absolute addresses.** Decode the old and new images' rebase targets,
   symbols, segment and section addresses and `LC_ROUTINES_64`. Every one
   must equal its old value plus G, or its old value when it named the
   header. Rebase targets must be the same set, each at old segment offset.
3. **Bytes.** From F onward, the new file equals the old one moved up by G,
   except at the fields Decision 2 names. Below F, the load commands are
   compared command by command. Each one is byte-identical to its old
   self, except:
   - the fields Decision 2 names;
   - the deleted split-info command, which is absent.
   The G inserted bytes and the rest of the pad are zero. So nothing outside
   the table can have changed.
4. **`mg_plausible`**, as today: initializers and unwind entries land on
   known function starts.
5. **No two segments overlap in vm**, as today.

### 6. What the user sees

Growth stays automatic and announced, as for executables. The dylib route's
line, from `mg_ensure_pad`:

```
LABEL: grew the header pad by 4096 bytes (16 -> 4112 available); contents raised by 0x1000
LABEL: grew the header pad by 4096 bytes (16 -> 4128 available); contents raised by 0x1000; dropped LC_SEGMENT_SPLIT_INFO
```

The executable route's line is unchanged. Tests match the stable prefix,
`grew the header pad by`.

## Testing

| what | where |
|---|---|
| each row of Decision 2, on a hand-built dylib fixture that carries that structure, with the mutation that skips its fix-up failing a named test | `tests/grow_test.c` |
| the rule: a `__dso_handle` rebase, a `__mh_dylib_header` symbol and export offset 0 unchanged; content one byte past the header raised | `tests/grow_test.c` |
| each refusal in Decision 4 leaves the buffer untouched | `tests/grow_test.c` |
| verification catches a planted error in each of its five checks | `tests/grow_test.c` |
| `dylib append`, `dylib insert`, `rpath replace` on a no-pad dylib fixture: success, announced, `verify` passes | `tests/cli_test.sh` |
| the executable route is byte-for-byte unchanged on every existing grow fixture | existing suites, unchanged |
| **real 10.9 system dylibs, run by Apple's own programs** (below) | new `tests/grown_dylib_runs_test.sh` |

**Real dylibs, run.** The test grows copies of 10.9 system dylibs that force
a grow (`dylib append` of a long path), then runs an Apple program against
each copy through `DYLD_LIBRARY_PATH` or `DYLD_FRAMEWORK_PATH`, and compares
its output with a run against the untouched original. Subjects are chosen so
that between them they exercise:

- C++ exceptions thrown and caught across grown code (unwind info, LSDA);
- Objective-C classes and categories;
- static initializers;
- `dlsym` through the export trie;
- a thread-local variable.

The plan picks the subjects and the programs. Candidates: `libxml2` with
`xmllint`, `libc++` with a small C++ program, `Foundation` with `plutil`.

- **Positive control, every run:** dyld prefers the shared cache for any path
  it contains, so a pass could come from the cached original.
  `DYLD_PRINT_LIBRARIES` must name the grown copy's scratch path, or the run
  fails.
- The test SKIPs, printing the reason, when the host is not 10.9 on x86_64:
  CI's `macos-26-arm64` runner has neither the 10.9 dylibs nor a way to run
  them. This follows memory "Check CI, not just local suites": the
  arm64-runner result is a separate gate from this one.

**End to end, locally:** `dylib append` and `rpath replace` succeed on a copy
of Sparkle (split info) and on a lowered copy of Mantle, and pass
`drydock-macho-rewrite verify`. Both are refused today.

## Documentation

The plan's final task updates:

- `README.md`'s grow paragraph;
- `compat/README.md` rows that say a dylib is refused (for example, the
  `insert_dylib` row about a real dylib with no `__PAGEZERO`);
- `docs/macl-case-study.md` rows 9 and 23, so they are true;
- the swift-runtime note in `docs/superpowers/QUEUE.md`, if any.

Why the raise works — the one rule, and why the list is complete — moves
into `src/grow.h`'s top comment, which already explains the executable
route, since this spec is deleted once implemented.

## Out of scope

- Executables: their route is unchanged, including its split-info refusal.
- 32-bit, arm64, chained fixups, old-style relocations: refused.
- Re-basing split info (Decision 3).
- Reclaiming pad by deleting other load commands (UUID, source version).
  About 50 bytes, not enough for the motivating cases, and deleting the UUID
  costs crash symbolication.

## Approaches that lost

- **Reclaim only**: see Out of scope.
- **Reclaim, then raise**: a policy layer and two paths to test, for no gain,
  because the raise must be correct anyway.
