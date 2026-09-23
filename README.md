# Drydock

Source code can often be adjusted to build and run on Mavericks.
When all you have is a binary executable, there's Drydock.

## Example usage

To adapt Claude Code to load and run, [Mavericks Forever's installer](https://mavericksforever.com/claude/install.sh) performs a `patch_macho` + `add_version_min` + `change_dylib` sequence.
Here's the Drydock equivalent:

```sh
cat >drydock-claude <<EOF
fixups        set      classic
version-min   set      10.9
load-command  delete   uuid
load-command  delete   codesig
dylib         replace  /usr/lib/libSystem.B.dylib   @loader_path/../S.dylib
dylib         replace  /usr/lib/libicucore.A.dylib  @loader_path/../I.dylib
dylib         replace  /usr/lib/libc++.1.dylib      @loader_path/../c++.1.dylib
EOF
drydock-macho-rewrite claude claude-mavericks < drydock-claude
./claude-mavericks
```

## drydock-macho-rewrite

Writes a minimally modified copy of a Mach-O executable, given instructions on stdin.

Convenience wrappers are provided for:

* `add_version_min`       ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/add_version_min.c))
* `bake-mavericks-shim`   ([original](https://forums.macrumors.com/threads/tailscale-for-mavericks.2489200/?post=34788880#post-34788880))
* `change_dylib`          ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/change_dylib.c))
* `fix_macho`             ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/fix_macho.c))
* `insert_dylib`          ([original](https://github.com/Wowfunhappy/insert_dylib))
* `patch_macho`           ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/patch_macho.c))
* `rename_segment`        ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/rename_segment.c))
* `retag_swift_classes`   ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/retag_swift_classes.c))

### Script format

One statement per line.
Blank lines are ignored.
Begin a comment with `#` at the start of an unquoted field.
Fields are split like shell words:
- Whitespace-separated
- Single- and double-quote grouping
- Backslash escapes

### Statements

```
load-command  delete    KIND        uuid | codesig | source-version
                                    | build-version | code-sign-drs
segment       rename    OLD NEW
version-min   set       10.9
swift-abi     set       legacy
fixups        set       classic
dylib         replace   OLD NEW
dylib         append    PATH
dylib         insert    PATH
dylib         delete    PATH
dylib         reexport  PATH
dylib         retype    PATH KIND   load | weak | reexport | upward
rpath         replace   OLD NEW
rpath         delete    PATH
rpath         append    PATH
rpath         insert    PATH
import        redirect  SYMBOL FROM-LIB TO-LIB
target        10.9                  the one statement whose meaning depends on
                                    the binary; see "The `target` statement"
```

Statements run one at a time, in the order written, so each `insert` goes to
the front of the image as the statement before it left it: the lines
`dylib insert A` then `dylib insert B` leave B at ordinal 1 and A at ordinal 2.
`rpath insert` works the same way, so dyld searches B before A.

### Directives

```
arch NAME           apply the script only to the slice named NAME (lipo's
                    names: x86_64, x86_64h, arm64, arm64e, i386); repeatable.
                    Without it, every 64-bit slice of a fat file is edited
allow-unmatched     an operation that matched nothing is reported and the run
                    continues, instead of refusing the whole run
```

If used, these must appear before any other operations.

An operation that matches nothing refuses the whole run (exit 1, nothing
written). These are the statements that can match nothing:

- `load-command delete` (no command of that kind)
- `dylib replace/delete/reexport/retype` and `rpath replace/delete` (no command naming that path)
- `segment rename` (no segment of that name)
- `import redirect` (no bind of that symbol names that library)

On a fat file, a statement has matched if it matched in any selected slice.

`version-min set` and `swift-abi set` cannot miss: with nothing to do, they
are no-ops. `fixups set classic` is a no-op on an image that already uses
`LC_DYLD_INFO_ONLY`, but it refuses an image with neither that nor chained
fixups, and `allow-unmatched` does not cover that refusal.

`allow-unmatched` is for the wrappers that reproduce tools which exited 0
when an operation matched nothing: `change_dylib`, `fix_macho` and
`insert_dylib` head their scripts with it. [compat/README.md](compat/README.md)
records why for each.

### The `target` statement

```
target        10.9
```

Every other statement means the same thing for every input — `dylib replace
A B` may match nothing, but *what it asks for* is fixed. `target 10.9` asks a
different question of every binary and answers it differently.

**It expands, where it is written, into statements the language already
has** — the ones this binary actually needs — and those run in its place:

| detected | expands to |
|---|---|
| `LC_DYLD_CHAINED_FIXUPS` present | `fixups set classic` |
| `LC_BUILD_VERSION` present | `load-command delete build-version` |
| no `LC_VERSION_MIN_MACOSX` | `version-min set 10.9` |
| `__DATA_CONST` carrying `__objc_*` sections | `segment rename __DATA_CONST __DATA` |
| class records carrying the stable-ABI Swift tag | `swift-abi set legacy` |

Each detection is exact rather than a guess: a load command is present or it
is not, a section name begins with `__objc_` or it does not, a tag bit is set
or it is not. **Never `dylib` or `rpath` work** — no tool can guess which stub
dylib you meant, and that is the dominant real workload, so a profile stops
where the guessing would start.

It decides per slice: each slice of a fat file gets only the lines that slice
needs. It derives `fixups set classic` only where there are chained fixups to
convert, so never on an image where that line refuses. It puts that line
first, and it reports why it derived each line. A second profile is what would show the
design earns its place; this build has one, and refuses any other.

**Use `target 10.9`** to make a whole binary built for a newer macOS run on
10.9, especially one with chained fixups or more than one slice. It combines
with the `dylib` and `rpath` lines it never derives, as below.

**Write the statements by hand** when you want some of those changes and not
the rest, such as only `version-min set 10.9`. Then:

- put `fixups set classic` first, and leave it out for an image with neither
  chained fixups nor `LC_DYLD_INFO_ONLY` (it refuses);
- leave out `load-command delete build-version` after `fixups set classic`,
  which already removes `LC_BUILD_VERSION`, so the delete would match nothing;
- rename `__DATA_CONST` only where `info` shows `__objc_` sections in it;
- when slices need different lines, run one script per slice with `arch`,
  since a directive applies to the whole script.

`info` shows what `target` would act on: each of its detections is an `info`
line (see [Queries](#queries)).

**Position is not cosmetic, which is why this is a statement and not a
flag.** `fixups set classic` rewrites `__LINKEDIT` and strips load commands,
which changes the header pad available to every `dylib replace` after it, and
nothing reorders your statements — the script is the plan. Where you write
the line is where the expansion lands:

```
target 10.9

dylib replace /System/Library/Frameworks/Metal.framework/Versions/A/Metal  @loader_path/libMetalStub.dylib
rpath  insert  @loader_path/../Frameworks
```

The report lists the expansion line by line, with the finding that produced
each, since the same line does different things to different binaries:

```
  target 10.9
    fixups set classic  (LC_DYLD_CHAINED_FIXUPS present)
    version-min set 10.9  (no LC_VERSION_MIN_MACOSX)
```

and says `nothing to do: this binary already targets 10.9` when the
expansion is empty.

The rest of the rules:

- **One `target` per script.** A second is a parse error.
- **An unknown target is a refusal.** `target 10.10` errors, naming what this
  build does know, rather than silently doing 10.9's work.
- **A derived statement behaves as the one you would have written** — a
  derived `version-min set 10.9` grows a short header pad exactly as one you
  wrote does — and if a derived statement is refused, the refusal names the
  `target` line, which is the line you wrote.
- **`target` never counts as unmatched,** and neither does anything it
  derived: "this binary already targets 10.9 correctly" is a correct answer
  for a profile, unlike for an explicit operation. (It happens for real:
  `fixups set classic` strips `LC_BUILD_VERSION` itself, so the `load-command
  delete build-version` the same expansion derived finds nothing left to do.)
- **Writing `target 10.9` *and*, after it, an explicit statement it derived
  makes the explicit one redundant, and if that statement can miss, it
  refuses as unmatched.** That is right, and is documented rather than
  special-cased.

### Queries

Four verbs read a file and change nothing:

```
drydock-macho-rewrite verify FILE          is the file structurally plausible?
drydock-macho-rewrite info [--thin] FILE   load commands, ordinals, sections, header pad
drydock-macho-rewrite imports FILE         TSV, one row per bind
drydock-macho-rewrite exports FILE         TSV, one row per export
```

`info` reads a fat container as one block per 64-bit slice, and names the
slices it passes over; `--thin` refuses a fat container instead (exit 1).
`verify` reads only a thin file. `imports` and `exports` read either; each
row names its slice in an `arch` column, and the header row names the columns.

`info` answers each of `target 10.9`'s five detections: an `LC[n]` line for
`LC_DYLD_CHAINED_FIXUPS`, `LC_BUILD_VERSION` or `LC_VERSION_MIN_MACOSX`, a
`sectname=` line under `segname=__DATA_CONST`, and the `swift-abi:` line.
From `drydock-macho-rewrite info hello`, on a two-slice x86_64 + i386 build:

```
hello: 16576 bytes, 2 slices
slice x86_64: 4312 bytes, 15 load commands, filetype=2
LC[0] LC_SEGMENT_64 cmdsize=72
  segname=__PAGEZERO vmaddr=0x0 vmsize=0x100000000 fileoff=0 filesize=0 nsects=0
LC[1] LC_SEGMENT_64 cmdsize=312
  segname=__TEXT vmaddr=0x100000000 vmsize=0x1000 fileoff=0 filesize=4096 nsects=3
    sectname=__text
    sectname=__unwind_info
    sectname=__eh_frame
...
LC[8] LC_VERSION_MIN_MACOSX cmdsize=16
  version=10.9.0 sdk=10.9.0
...
LC[11] LC_LOAD_DYLIB cmdsize=56
  ordinal=1 path=/usr/lib/libSystem.B.dylib
...
swift-abi: no class records carry the stable-ABI tag
header pad: 3112 bytes available (LC end=856, first sect=3968)
slice i386: 32-bit; passed through unchanged
```

On a thin file there is no slice header: the first line names the path.

## Limitations

- 32-bit input is currently refused.
- 64-bit fat containers (`fat_arch_64`) are currently refused.

## Other related tools

- `install_name_tool` from the Mavericks Command Line Tools
- `llvm-install-name-tool` from [clang](https://github.com/Mavergreen/clang)