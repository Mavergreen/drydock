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
fatal-warnings      an operation that matched nothing refuses the whole run
                    (exit 1, nothing written) instead of only being reported
```

If used, these must appear before any other operations.

`fatal-warnings` covers the statements that can match nothing:

- `load-command delete` (no command of that kind)
- `dylib replace/delete/reexport` and `rpath replace/delete` (no command naming that path)
- `segment rename` (no segment of that name)
- `import redirect` (no bind of that symbol names that library). 

On a fat file, a statement has matched if it matched in any selected slice.

XXX why do we have `fatal-warnings`? still used for anything? does it need to exist, or can we just always error out in such cases?

### The `target` statement

XXX why isn't this documented under Statements?

XXX this seems really weird and non-orthogonal -- what motivated adding it, and is that motivation still valid?

```
target        10.9
```

Every other statement means the same thing for every input — `dylib replace
A B` may match nothing, but *what it asks for* is fixed. `target 10.9` asks a
different question of every binary and answers it differently: it is the
intent level, arriving as a named line rather than as hidden behaviour.

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
- **`target` never counts as unmatched under `fatal-warnings`,** and neither
  does anything it derived: "this binary already targets 10.9 correctly" is a
  correct answer for a profile, unlike for an explicit operation. (It happens
  for real: `fixups set classic` strips `LC_BUILD_VERSION` itself, so the
  `load-command delete build-version` the same expansion derived finds nothing
  left to do.)
- **Writing `target 10.9` *and* an explicit statement it would have derived
  makes the explicit one redundant, and `fatal-warnings` will flag it.** That
  is right, and is documented rather than special-cased.

## Limitations

- 32-bit input is currently refused.
- 64-bit fat containers (`fat_arch_64`) are currently refused.

## Other related tools

- `install_name_tool` from the Mavericks Command Line Tools
- `llvm-install-name-tool` from [clang](https://github.com/Mavergreen/clang)