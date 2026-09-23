# `minos at-most` and `minos if-absent`: one vocabulary for the declared minimum

**Status:** design, approved in conversation 2026-09-23; this document for review.
**Replaces:** `version-min set 10.9` and `minos set VERSION` (neither has shipped).
**Facts it rests on:** `docs/minimum-os-version.md`.

## Why

A slice can be in one of four states:

- it declares no minimum;
- it declares one in `LC_VERSION_MIN_MACOSX`;
- it declares one in a macOS `LC_BUILD_VERSION`;
- rarely, it carries both.

Every statement about the minimum answers two questions for each of those states:

1. What happens when the slice declares no minimum?
2. What happens when it declares a different one?

Today's statements answer them in three different ways, and nothing in their names says which:

- `version-min set` adds a minimum and leaves an existing one alone.
- `minos set` rewrites an existing minimum and misses when there is none.
- `target` adds a minimum and lowers one only if it is above 10.9.

The new words name the rule they apply. Each one also leaves the slice in a single known shape: exactly one `LC_VERSION_MIN_MACOSX`, the only version command 10.9 reads. That removes the "two version commands" hazard that 10.14's dyld and the 10.15+ kernel refuse.

On 10.9 the minimum is a label: nothing gates loading, execution or launching on it (`docs/minimum-os-version.md`). The value of getting it right is that the file tells the truth, and the tool's report says what it did.

## The grammar

```
minos at-most   VERSION     lower a minimum above VERSION to VERSION; leave one
                            at or below it; declare VERSION where there is none
minos if-absent VERSION     declare VERSION where there is none; leave any
                            declared minimum as it is
```

- **VERSION** is `MAJOR[.MINOR[.PATCH]]`, decimal, at most 65535.255.255. The existing `ms_parse_version` validates it at parse time, so a bad version is a parse error (exit 2) before any I/O.
- **Comparison happens at VERSION's own precision.** `at-most 10.9` treats every 10.9.x as 10.9, so a declared 10.9.5 is left as declared. `at-most 10.9.3` compares all three parts. A declared version counts as above VERSION only when it is greater once truncated to the parts VERSION names.
- **Removed:**
  - The `version-min set` and `minos set` rows leave `MS_TABLE`.
  - Their kinds and ops go too: `MS_VERSION_MIN` goes, and `MS_MINOS` gains the ops `MS_AT_MOST` and `MS_IF_ABSENT`.
  - Neither word gets a migration message. Each falls through to the parser's generic unknown-statement refusal, as `fatal-warnings` does. A pinning test lists both beside a typo.
- **The table size stays at 18 rows:** two removed, two added.

## What each statement does, per slice

Only 64-bit slices selected by the script are edited, which is the existing rule for every statement. For each slice:

1. **Read the declaration.**
   - A slice whose only version commands are non-macOS `LC_BUILD_VERSION`s (an iOS simulator slice, for instance) is refused (exit 1): "declares platform N, not macOS; refusing to add a macOS minimum to it". It is not a macOS image, and adding a command would create two.
   - More than one `LC_VERSION_MIN_MACOSX`, or more than one macOS `LC_BUILD_VERSION`, is refused as malformed. Refuse, don't guess.
   - Otherwise the declared minimum **D** and sdk **S** come from:
     - the `LC_VERSION_MIN_MACOSX` if there is one;
     - else the macOS `LC_BUILD_VERSION`;
     - else D is absent.
2. **Decide the minimum N.**

   | statement | D absent | D at or below VERSION | D above VERSION |
   |---|---|---|---|
   | `at-most VERSION` | VERSION | D | VERSION |
   | `if-absent VERSION` | VERSION | D | D |

3. **Decide the sdk.**
   - If an `LC_VERSION_MIN_MACOSX` exists, its sdk is kept.
   - If the declaration came from `LC_BUILD_VERSION`, its sdk is carried over: the binary was built against it.
   - If there was nothing, the sdk is 10.9.
   - The sdk is never raised, lowered or invented beyond that.
4. **Write the result.** The slice ends with exactly one `LC_VERSION_MIN_MACOSX` holding (N, sdk).
   - Every `LC_BUILD_VERSION` in the slice is removed: the macOS one whose values were carried, and any Mac Catalyst one in a zippered binary.
   - An existing `LC_VERSION_MIN_MACOSX` is rewritten in place.
   - Otherwise one is appended, and the removed `LC_BUILD_VERSION`s free more room than the append needs.
   - When nothing changes (an existing `LC_VERSION_MIN_MACOSX` already at N, with no `LC_BUILD_VERSION`), the slice's bytes are unchanged.

**Neither statement can match nothing.** Every macOS slice ends in the stated shape, and that shape is what the statement is for. So these are not operations that "matched nothing", and `allow-unmatched` does not apply to them. The refusals above are refusals, not misses.

**Relations.** `ms_disturbs` returns what `version-min set` returns today, `MREL_HEADER_PAD`. Appending, or converting an `LC_BUILD_VERSION` to a shorter `LC_VERSION_MIN_MACOSX`, changes the load-command area. A rewrite in place disturbs nothing, but the relation is per statement, not per outcome, so the conservative mask stands.

## The report

One line per slice under the statement. `at-most` uses exactly one of the first five shapes below. `if-absent` uses the same five, except that a declared minimum above VERSION reads as the last shape:

```
  minos at-most 10.9
    version-min 10.12 -> 10.9; sdk 10.13 kept
    version-min 10.7, at or below 10.9: kept; sdk 10.9 kept
    build-version 12.0 -> version-min 10.9; sdk 12.3 carried over
    build-version 10.7 -> version-min 10.7; sdk 10.10 carried over
    none -> version-min 10.9; sdk 10.9 written
  minos if-absent 10.9
    version-min 10.12 kept (declared); sdk 10.13 kept
```

- When the slice has a Mac Catalyst `LC_BUILD_VERSION`, the line gains `; Mac Catalyst build-version removed`.
- Versions print as `mv_format_version` does.
- Arrows are ASCII `->`.

## `fixups set classic` keeps the declaration

Today `md_declassify` strips `LC_BUILD_VERSION` along with the chained-fixups commands, which loses the declared minimum and sdk. `target` works around that with a hidden channel: `ms_stmt.sdk` / `has_sdk`, filled in at detection time. A hand-written script cannot use that channel.

**Change:** when `md_declassify` strips a macOS `LC_BUILD_VERSION`, it writes an `LC_VERSION_MIN_MACOSX` carrying that command's minos and sdk. The new command goes directly before the `LC_DYLD_INFO_ONLY` that declassify appends, not in the build-version's old slot. That placement makes "`fixups set classic`, then `minos`" and "`minos`, then `fixups set classic`" produce byte-identical output, and a test pins that. It does not lower the minimum; that is `minos`'s job. The new command is 16 bytes, where the old one was 24 or more, so the net header change still shrinks.

- A Mac Catalyst `LC_BUILD_VERSION` is stripped as today.
- An image that already has an `LC_VERSION_MIN_MACOSX` gets no second one; its `LC_BUILD_VERSION` is stripped as today.

After `fixups set classic`, then, no information is lost, and a following `minos at-most 10.9` sees an ordinary `LC_VERSION_MIN_MACOSX`. The hidden channel is deleted: `ms_stmt.sdk`, `has_sdk`, and the sdk parameter of `mv_add_version_min_image`.

This is a behaviour change to `fixups set classic`. Its report line gains `; LC_BUILD_VERSION A.B (sdk C.D) kept as LC_VERSION_MIN_MACOSX`.

## `swift-abi set legacy` refuses what it cannot read

Measured 2026-09-23: on a chained-fixups image, `swift-abi set legacy` cannot follow the class-record pointers. It reports "nothing to retag", exits 0, and leaves the stable-ABI tag set. That answer is false, and a hand-written script that orders `swift-abi` before `fixups` gets it silently. `target 10.9` hits the same bug: it tests for the tag on the image before its own `fixups set classic` has run, so on a chained Swift binary it never derives the retag.

**Change:** on an image with `LC_DYLD_CHAINED_FIXUPS`, `swift-abi set legacy` refuses (exit 1) with "the class records' pointers are chained; write `fixups set classic` before `swift-abi set legacy`". It no longer answers a question it could not read. After this, statement order in a 10.9 script matters only by being refused, never by silently producing a different result.

`mswift_stable_tagged_image`'s callers treat a chained image the same way. `info`'s `swift-abi:` line says `swift-abi: unknown (pointers are chained; fixups set classic first)` rather than "no class records carry the stable-ABI tag".

## `target 10.9`

`target 10.9` is a published recipe, not a hidden policy. The README prints its expansion as the script it is equivalent to, and a test pins that running the recipe by hand gives the same bytes as `target 10.9`, on a thin chained Swift image and on a fat one.

It detects each condition **on the image as the preceding derived statements leave it**, not on the input. In particular, the Swift tag is tested after `fixups set classic` has run, which fixes the bug described above.

The expansion becomes, in order, whichever of these apply:

1. `fixups set classic`, when the image has chained fixups;
2. `minos at-most 10.9`, always;
3. `segment rename __DATA_CONST __DATA`, when `__DATA_CONST` holds `__objc_` sections;
4. `swift-abi set legacy`, when class records carry the stable-ABI tag.

`load-command delete build-version` is no longer derived, because `minos` removes every `LC_BUILD_VERSION`. `target`'s own `minimum:` line goes, because the `minos` statement's report line says it. `ME_TARGET_MAX` becomes 4. `target` stays a profile: it derives statements and nothing else.

"Nothing to do: this binary already targets 10.9" is printed only when nothing in the expansion changes the image. `minos at-most 10.9` counts as changing nothing only when the slice already holds one `LC_VERSION_MIN_MACOSX` at or below 10.9 and no `LC_BUILD_VERSION`.

## The `add_version_min` wrapper

Its translation becomes `minos if-absent 10.9`. Upstream `add_version_min` appended an `LC_VERSION_MIN_MACOSX` when none existed and otherwise left the file alone. On a binary carrying only an `LC_BUILD_VERSION`, the upstream tool therefore produced two version commands. The wrapper now produces one, keeping the build-version's minimum and sdk. This is a new divergence, adopted because the upstream output is the pair that 10.14+ refuses. It is recorded in `compat/README.md`'s `add_version_min` differences table with a held-by test.

The wrapper's "already present" output for an image that already has an `LC_VERSION_MIN_MACOSX` must be unchanged, because a test pins it.

## README

The statements section gets a short decision table. It is the "when to use which" the owner asked for:

| you want | write |
|---|---|
| a binary built for a newer macOS to say it targets 10.9 | `minos at-most 10.9`, or let `target 10.9` derive it |
| a minimum declared where there is none, and nothing else changed | `minos if-absent 10.9` |
| to keep an honest lower minimum such as 10.7 | either; neither raises one |

Beside it, three sentences:

- **What gates launch:** Finder and LaunchServices refuse on `LSMinimumSystemVersion` in `Info.plist`, not on the Mach-O minimum, and Drydock does not edit `Info.plist`.
- **What the sdk field does on 10.9:** it decides linked-on-or-after behaviour and code-signature registration. See `docs/minimum-os-version.md`.
- **What each statement leaves:** exactly one `LC_VERSION_MIN_MACOSX` per slice.

The owner is editing README.md by hand. The plan's README task changes only the lines this feature touches, and stops if the file has uncommitted edits.

What `target` adds over a hand-written recipe, and the README says so in these terms:
- it renames `__DATA_CONST` only where `__objc_` sections need it, per slice. Renaming a C-only `__DATA_CONST` breaks nothing measured on 10.9, but it leaves two segments named `__DATA`, which `getsegbyname` and tools cannot tell apart;
- it chooses per slice of a fat file;
- it derives `fixups set classic` only where there are chained fixups, so it never hits that statement's refusal on an image with no fixup information;
- it reports why each line was derived.

## `verify`'s limit

Measured: `verify` passes an Objective-C image whose `__objc_` sections sit in `__DATA_CONST`, and that image dies at launch on 10.9 ("no class for metaclass", SIGILL). `verify` checks structure, not what 10.9's runtime requires. README's Queries section says so in one sentence. Making `verify` check this is out of scope.

## Out of scope

- Whether a rewrite should strip, keep or re-sign a signature it has made stale. That is a separate decision, waiting on measurements from a modern arm64 Mac. On 10.9 it matters only when a kill-flagged host loads an edited dylib whose sdk is 10.9 or later (`docs/minimum-os-version.md`).
- An `sdk` statement. Nothing needs one yet.
- `at-least` and `exactly`. There is no use for them on 10.9, and this was decided in conversation.
- arm64 slices, which Drydock does not edit for 10.9. Their 11.0 minimum is left alone.

## Testing

| claim | held by |
|---|---|
| grammar: both words parse; versions validate; `version-min set` and `minos set` are unknown statements, pinned beside a typo | `tests/script_test.c` |
| `--capabilities` lists `statement minos at-most 1` and `statement minos if-absent 1`, 18 statement lines | `tests/cli_test.sh`, `tests/script_test.c` |
| the decision table, every cell, for `LC_VERSION_MIN_MACOSX`, for `LC_BUILD_VERSION`, and for none | `tests/edit_test.c` (in memory), `tests/cli_test.sh` against `tests/mkminos.c` fixtures |
| VERSION's precision: 10.9.5 kept under `at-most 10.9`, lowered under `at-most 10.9.3` | `tests/edit_test.c` |
| sdk kept, carried over, or 10.9 written, per source | both |
| one `LC_VERSION_MIN_MACOSX` and no `LC_BUILD_VERSION` after every statement, including zippered (two `LC_BUILD_VERSION`s) | `tests/cli_test.sh` with a `mkminos` fixture that carries two; `mkminos` gains an `add-bv` mode that appends without stripping |
| iOS-only slice refused; duplicate version commands refused | `tests/edit_test.c` |
| unchanged slice keeps its bytes | `tests/cli_test.sh` (cmp) |
| fat: per slice, with `arch` selection | `tests/edit_test.c` `write_fat` |
| `fixups set classic` keeps a macOS `LC_BUILD_VERSION`'s minos and sdk as `LC_VERSION_MIN_MACOSX` | `tests/cli_test.sh`, `mkchained` fixture |
| `target 10.9` derives `minos at-most 10.9`, in position 2, and never `load-command delete build-version` | `tests/cli_test.sh` |
| the 10.12 reproduction still reports a lowering, never "nothing to do" | `tests/cli_test.sh` |
| `add_version_min` translates to `minos if-absent 10.9`; build-version-only input gives one command; the "already present" output is unchanged | `tests/translate_test.sh`, `tests/wrapper_test.sh`, `tests/add_version_min*` |
| `fixups set classic` places the kept `LC_VERSION_MIN_MACOSX` before `LC_DYLD_INFO_ONLY`; `fixups`-then-`minos` and `minos`-then-`fixups` give identical bytes, including on the 8-byte-pad chained dylib | `tests/cli_test.sh`, `mkchained` |
| `swift-abi set legacy` on a chained image refuses (1) and names the fix; `info` reports `swift-abi: unknown (…)` there | `tests/cli_test.sh`, a chained Swift fixture (`mkswift` + `mkchained`, or the synthetic one the measurement built) |
| `target 10.9` on a chained Swift image derives and applies the retag (the bug) | `tests/cli_test.sh` |
| the README's published recipe, run by hand, equals `target 10.9` byte for byte, thin and fat | `tests/cli_test.sh` |
| every mutation named in the plan fails its test | each task's mutation step |
