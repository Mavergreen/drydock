# `minos set`, and a `target 10.9` that stops hiding a declared minimum

## Why

`target 10.9` reports a binary that declares 10.12 as already done. To reproduce
on this 10.9.5 host:

```sh
printf 'int main(void){return 0;}\n' >m.c
cc -arch x86_64 -mmacosx-version-min=10.12 m.c -o m1012
drydock-macho-rewrite info m1012 | grep -A1 VERSION_MIN
#   LC[8] LC_VERSION_MIN_MACOSX cmdsize=16
#     version=10.12.0 sdk=10.9.0
printf 'target 10.9\n' | drydock-macho-rewrite m1012 m1012.out
#     target 10.9
#       nothing to do: this binary already targets 10.9
```

The claim is false. `me_expand_10_9` (`src/edit.c:590`) asks only whether an
`LC_VERSION_MIN_MACOSX` exists, not what it says, and `version-min set 10.9`
appends only when none exists (`src/version_min.c:129-131`: "already present;
nothing to do"). No statement can change a minimum an image already declares.
QUEUE.md item 13, capability 4, lists the same gap from the other direction:
"our `minos` is a no-op when one is present, and `lc delete build-version`
throws the information away instead of correcting it."

**This fixes correctness and honesty, not loading.** Measured on this 10.9.5
host:

- an executable declaring a 10.12 minimum runs;
- a dylib declaring a 10.12 minimum loads, both as a link-time dependency and
  through `dlopen`.

10.9's dyld does not enforce the field. So lowering it makes no binary load that
did not load before. It makes the file tell the truth about what it now targets,
and it makes the tool's report tell the truth about what it did. The declared
minimum is also the only hint left in a binary that it may call APIs newer than
10.9, so it must never be dropped without a trace.

Why Keynote 9's bundled frameworks needed `patch_min_version.py` (item 13's
source) is **unknown**. The measurements above do not explain it, and this
design does not claim to.

## Decisions

### 1. A new statement, `minos set VERSION`, and `version-min set` stays as it is

```
minos         set       VERSION
```

It rewrites, in place, the `version` field of every `LC_VERSION_MIN_MACOSX` and
the `minos` field of every `LC_BUILD_VERSION` whose `platform` is macOS (1). It
never writes an `sdk` field: frameworks decide linked-on-or-after behaviour from
the SDK, and that is not what this statement is about. No command changes size,
so nothing moves, and the row's disturbs mask is `MREL_NONE`.

**The spelling.** The grammar is `<kind> <op> operands`. Every other kind names
a load command or a thing inside the image (`version-min`, `segment`, `dylib`).
`minos` names the *field* that both version-bearing commands carry, which is the
difference from `version-min`: `version-min set` places a command, while
`minos set` rewrites a field wherever it already is. The op is `set`, as for
the other value statements (`swift-abi set`, `fixups set`).

**Why `version-min set` does not gain replace semantics.** It is what the
`add_version_min` wrapper emits (`compat/translate.sh:633`). Upstream
`add_version_min.c` appends when absent and leaves the file alone when a command
is present, printing "already present; nothing to do." Wrapper output may change
wording, but not bytes or exit codes. Giving the statement replace semantics
would make `add_version_min` rewrite a 10.12 declaration its upstream left
alone. So the two statements divide the work: `version-min set 10.9` appends
when no command is present, and `minos set` rewrites one that is. A test pins
`version-min set 10.9` leaving a 10.12 declaration unchanged, so the two cannot
drift into doing the same thing.

**VERSION** is `MAJOR[.MINOR[.PATCH]]`: decimal digits only, at most
65535.255.255, which is the packed `xxxx.yy.zz` form both commands use.
`ms_parse` validates it, so a malformed version is a parse error (exit 2)
before the tool reads anything, the same as `version-min set 10.10`. Any valid
version is accepted, including one higher than the current value. An explicit
statement says what it wants. Only `target` has a never-raise rule.

**When neither command exists, the statement is a miss.** It does not append:
appending is `version-min set`'s job, and a statement that sometimes rewrites
and sometimes appends would do two different things under one name. It is not
a silent no-op either: the refuse-by-default rule exists to stop an operation
that did nothing from passing as a success. So:

- matched = at least one command rewritten, counted across every selected slice
  (the same any-slice rule `segment rename` and `import redirect` use, through
  the same `me_verdict.renamed` counter);
- unmatched = a report on stderr, `drydock-macho-rewrite: minos set 10.9 matched
  nothing`, and exit 1 with nothing written, unless the script says
  `allow-unmatched`;
- a command whose value already equals VERSION **has matched**. The field exists
  and holds what was asked for, so running a script again on its own output
  succeeds.

An `LC_BUILD_VERSION` for another platform (iOS, Mac Catalyst) is not a macOS
minimum. Writing a macOS version into it would be wrong, so it does not match.

**Report**, one line beneath the statement per command kind rewritten, old
value before new, using ASCII `->` like the report's other arrows (`5->4`,
`chained fixups -> LC_DYLD_INFO_ONLY`):

```
  minos set 10.9
      version-min 10.12 -> 10.9
      build-version minos 12.0 -> 10.9
```

A version prints as `MAJOR.MINOR`, plus `.PATCH` when the patch is nonzero.
When nothing matches, the report says
`no LC_VERSION_MIN_MACOSX or macOS LC_BUILD_VERSION to set`.

### 2. `target 10.9` and the declared minimum

The rule compares **major.minor only**. The profile is 10.9 and this host is
10.9.5, so every 10.9.x counts as 10.9. "Above 10.9" means major.minor > 10.9.

| the image declares | `target 10.9` derives | the minimum afterwards |
|---|---|---|
| nothing | `version-min set 10.9` (as today) | 10.9 |
| `LC_VERSION_MIN_MACOSX` above 10.9 | `minos set 10.9` | 10.9 |
| `LC_VERSION_MIN_MACOSX` at or below 10.9 | nothing | as declared |
| a macOS `LC_BUILD_VERSION`, no `LC_VERSION_MIN_MACOSX`, minos above 10.9 | `load-command delete build-version`, `version-min set 10.9` (as today) | 10.9 |
| the same, minos at or below 10.9 but not exactly 10.9.0 | the same two, then `minos set <that minos>` | as declared |

A declared minimum at or below 10.9 is never raised: raising it throws away a
true fact and gains nothing.

**Every run logs the minimum**, on one line directly under `target 10.9` and
before the derived lines, so the declared value is never dropped silently:

```
    minimum: version-min 10.12 -> 10.9; sdk 10.13 untouched
    minimum: version-min 10.8, at or below 10.9; left as declared; sdk 10.9 untouched
    minimum: build-version 12.0 -> version-min 10.9; sdk 12.3 carried over
    minimum: build-version 10.7 -> version-min 10.7; sdk 10.10 carried over
    minimum: none declared -> version-min 10.9; sdk 10.9 written
```

The line also names the `sdk` the image carries afterwards, and whether it
was left alone, carried over from `LC_BUILD_VERSION`, or written (decision 3).

When both commands are present, `LC_VERSION_MIN_MACOSX` decides, because it is
the one 10.9 reads. The `LC_BUILD_VERSION` is deleted as it is today.

**The false report cannot happen any more.** "nothing to do: this binary already
targets 10.9" is printed only when nothing was derived. After this change,
nothing is derived only when the minimum line says "left as declared", which
means the image does declare 10.9 or lower. The reproduction above becomes a
test.

### 3. `LC_BUILD_VERSION` without chained fixups: convert, don't lower in place

Today `target` already converts an image that has `LC_BUILD_VERSION` but no
chained fixups: it derives `load-command delete build-version` whenever the
command is present, and `version-min set 10.9` whenever `LC_VERSION_MIN_MACOSX`
is absent. That stays. `target` does **not** lower the minos in place and keep
the command, for two reasons:

- 10.9 predates `LC_BUILD_VERSION`. Its dyld and its `otool` read the minimum
  from `LC_VERSION_MIN_MACOSX`, so a lowered minos inside `LC_BUILD_VERSION`
  would be a correction that nothing on the target system reads.
- A chained image already comes out with `LC_VERSION_MIN_MACOSX` in place of
  `LC_BUILD_VERSION`, because `fixups set classic` strips the latter. Converting
  in the unchained case too means `target` gives the same result whether or not
  fixups were chained.

What is new is that the conversion no longer throws the declared value away. A
minos above 10.9 becomes 10.9, and the minimum line reports it as old -> new. A
minos at or below 10.9 carries over, by a derived `minos set` that runs after
the append and rewrites the command just appended.

**The conversion carries the original `sdk` over.** The binary really was built
against that SDK, and this is the same rule `minos set` follows: never change
the `sdk`. Today the conversion writes `sdk=10.9`. That value comes from
`mv_add_version_min_image` (`src/version_min.c:166`, `vm->sdk = (10 << 16) |
(9 << 8)`), which runs for the `version-min set 10.9` that `target` derives.
`declassify`'s conversion strips `LC_BUILD_VERSION` but never writes a
version-min, so it is not involved. So:

- `mv_add_version_min_image` takes the `sdk` to write as a parameter;
- `ms_stmt` gains `uint32_t sdk`, which `ms_parse` sets to 0. A written
  `version-min set 10.9` therefore keeps today's `sdk=10.9`. So do the
  `add_version_min` wrapper and `mv_add_version_min`, which pass 10.9;
- when `target` derives `version-min set 10.9` in place of a macOS
  `LC_BUILD_VERSION`, it sets that statement's `sdk` to the `LC_BUILD_VERSION`'s
  sdk, which it read before any derived statement ran. When there was no macOS
  `LC_BUILD_VERSION`, `sdk` stays 0 and 10.9 is written, as today;
- when the appended `sdk` is not 10.9, the append's report line names it:
  `appended LC_VERSION_MIN_MACOSX 10.9, sdk 12.3`.

The detection reads the image as `target` finds it, before any derived
statement runs, so the minos is known even though `fixups set classic` strips
the command first. **The ordering rule stands: `fixups set classic` first.**
The full order is fixups, `load-command delete build-version`, `version-min
set`, `minos set`, `segment rename`, `swift-abi set`. `minos set` follows
`version-min set` because the carry-over rewrites the command that
`version-min set` appends.

### 4. Fat files

Per slice, as `target` already works: each slice gets its own detection, its own
minimum line and its own derived lines. An explicit `minos set` has matched if
it matched in any selected slice.

### 5. `info` prints `LC_BUILD_VERSION`'s fields

`info` prints `  version=… sdk=…` under `LC_VERSION_MIN_MACOSX`, but nothing
under `LC_BUILD_VERSION`. Without that line, "what minimum does this image
declare, and in which command?" cannot be answered, and the answer decides
whether to write `minos set` by hand. So `info` gains one two-space line:

```
LC[9] LC_BUILD_VERSION cmdsize=24
  platform=1 minos=12.0.0 sdk=12.3.0
```

This line is only added. No existing consumer's pattern can match it: those
patterns are `^  ordinal=`, `^  segname=`, `' LC_CODE_SIGNATURE '`,
`' LC_DYLD_CHAINED_FIXUPS '` and `^header pad:`.

### 6. Wrappers, `--capabilities`, and the old `minos:` labels

The assertions in `tests/cli_test.sh`'s `version-min set` block are labelled
`minos:`, after the deleted verb, which appended. The task that adds the
`minos set` block renames each of them for the behaviour it asserts, for
example `version-min set: appends when absent`. Otherwise two labels that
look alike would sit side by side meaning opposite things.


No wrapper emits the new statement, and `add_version_min` keeps its
append-only upstream semantics (decision 1). `--capabilities` is generated
from `MS_TABLE`, so the new row prints `statement minos set 1` with no edit
to the CLI. The new row goes **last**, after `import redirect`, because the
order of the statement lines is frozen interface text
(`src/script.c:87-91`). Both tests that count those lines move from 17 to 18.

### 7. README

`README.md` gains `minos set` in the Statements block and in the list of
statements that can match nothing. It also gains a paragraph that separates
`version-min set` from `minos set`. The `target` section's table, report
example and "write by hand" guidance change to match decisions 2 and 3.
Queries gains the new `info` line. **The owner is editing README.md by hand**:
that task rebases onto those edits and touches only the lines this feature
changes.

## Testing

TDD throughout. Every test is written first and seen to fail, and every change
is then mutation-proven: break it, watch the test fail, restore it.

| what | where |
|---|---|
| `info` prints `LC_BUILD_VERSION`'s platform, minos, sdk | `tests/cli_test.sh`, against a fixture written by a new independent helper `tests/mkminos.c` |
| `minos set` parses `MAJOR[.MINOR[.PATCH]]` and refuses everything else | `tests/script_test.c` |
| `ms_disturbs(MS_MINOS, MS_SET) == MREL_NONE`; the table has 18 rows | `tests/script_test.c` |
| rewrites version-min and macOS build-version in place, one byte changed, sdk untouched | `tests/edit_test.c`, `tests/cli_test.sh` |
| an explicit `minos set` may raise | `tests/edit_test.c`, `tests/cli_test.sh` |
| nothing declared is a miss: exit 1, nothing written; `allow-unmatched` reports and appends nothing | `tests/edit_test.c`, `tests/cli_test.sh` |
| a non-macOS `LC_BUILD_VERSION` is not matched | `tests/edit_test.c` |
| fat: a match in any slice is a match; none anywhere refuses | `tests/edit_test.c` |
| `version-min set 10.9` leaves a 10.12 declaration alone | `tests/cli_test.sh` |
| `--capabilities` prints `statement minos set 1`, 18 statement lines | `tests/cli_test.sh` |
| the reproduction: a real 10.12 build is never "nothing to do", and comes out at 10.9 | `tests/cli_test.sh` |
| `target` lowers above 10.9, leaves 10.8 / 10.9 / 10.9.5, converts build-version 12.0 and carries 10.7 | `tests/cli_test.sh` |
| the minimum line is printed in every case, once per slice | `tests/cli_test.sh` |
| fixups still come first; `minos set` comes after `version-min set` | `tests/cli_test.sh` |
| a converted `LC_BUILD_VERSION`'s sdk is carried over (12.3 in, 12.3 out; chained 12.0 in, 12.0 out); none declared still writes 10.9 | `tests/cli_test.sh` |
| the old `minos:` labels in the `version-min set` block are renamed for what each asserts | `tests/cli_test.sh` |

## Out of scope

- Minimums for platforms other than macOS.
- 32-bit input and `fat_arch_64` containers stay refused.
