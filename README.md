# Drydock

Source code can often be adjusted to build and run on Mavericks.
When all you have is a binary executable, there's Drydock.

## Installing

Each [release](https://github.com/Mavergreen/drydock/releases) has three downloads:

- `drydock-<version>-macos-universal.tar.gz`: no installer. Unpack it anywhere and run what's in `bin/`. It needs nothing installed outside that directory beyond what Mac OS X ships, and writes only the files you name and its own temporary files. The wrappers find `drydock-macho-rewrite` beside themselves, unless `DRYDOCK_MACHO_REWRITE_COMPAT_DIR` is set: then they use the one there. So a wrapper symlinked from elsewhere needs it set to the real `bin/`, and an inherited setting overrides the copy you unpacked.
- `drydock-<version>.pkg`: installs into `/usr/local/mavergreen`, puts it on your `PATH`, and keeps itself up to date.
- `drydock-<version>-linux-x86_64.tar.gz`: the same tools, built for Linux, to rewrite Mach-O files from a Linux machine, such as a CI runner building for Mavericks. Unpack it anywhere, as with the macOS archive. It runs on any x86_64 CPU (it needs nothing above the x86-64 baseline) with glibc 2.34 or later.

`SHA256SUMS` covers all three.

## Example usage

To adapt Claude Code to load and run,
[Mavericks Forever's installer](https://mavericksforever.com/claude/install.sh)
needs a sequence of `patch_macho`, `add_version_min`, and `change_dylib` commands.
Here's the equivalent script in Drydock's little language:

```sh
cat >drydock-claude <<EOF
fixups        set      classic
minos         at-most  10.9
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

Given instructions on stdin, write a modified copy of a Mach-O executable.

See [drydock-macho-rewrite(1)](man/drydock-macho-rewrite.1) for script syntax, operations, queries, and limitations.

`drydock-macho-rewrite` incorporates functionality (and sometimes code) from a variety of tools. To aid migration, compatibility wrappers are available:

* `add_version_min`       ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/add_version_min.c))
* `bake-mavericks-shim`   ([original](https://forums.macrumors.com/threads/tailscale-for-mavericks.2489200/?post=34788880#post-34788880))
* `change_dylib`          ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/change_dylib.c))
* `fix_macho`             ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/fix_macho.c))
* `insert_dylib`          ([original](https://github.com/Wowfunhappy/insert_dylib))
* `patch_macho`           ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/patch_macho.c))
* `rename_segment`        ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/rename_segment.c))
* `retag_swift_classes`   ([original](https://github.com/Wowfunhappy/Mavericks-Porting-Resources/blob/master/retag_swift_classes.c))

(The wrappers will probably go away at some point, so take their guidance and change your call sites.)

## drydock-objc

Given an Objective-C binary built for Mavericks, report which of its message sends the Mavericks runtime and SDK can answer. It is shipyard's Objective-C analyzer, moved here so the tool that rewrites a Mach-O file and the tool that checks what it will do on 10.9 ship together. It has five subcommands:

* `drydock-objc analyze`: analyze an artifact against the reference set and write a report. Non-system images the artifact loads are found inside `--root`. With `--root-kind volume`, `--root` is a staged volume as installed at `/`: an absolute install name such as `/usr/local/lib/libfuse.2.dylib` and every symlink resolve inside it, never on the host.
* `drydock-objc evidence`: write the source-side evidence an artifact's analysis is checked against, or with `--tree-digest-only` or `--sdk-digest-only` just print a digest of a source tree or an SDK.
* `drydock-objc link-args`: print the link arguments for a provider prefix and link map; `--provider ID`, repeatable, limits them to the providers named, so a consumer roots and links only what it uses.
* `drydock-objc receipt`: write an Objective-C provider's source receipt: every Objective-C send in its verified prepared sources, with the identities of the clang (its libclang version), the SDK and the tool that took it.
* `drydock-objc resolve`: fill reviewed schema-2 build evidence's symbols and crate disambiguators from an artifact, so a product's CI regenerates them on every build. A reviewed path names one function or the copies of one generic instance; anything else is refused as `resolve-ambiguous`.

`analyze`, `evidence`, `link-args` and `receipt` take the arguments and exit statuses of the shipyard scripts they replace; `resolve` is new, and described below. Run `drydock-objc` with no arguments for the usage. It reads its reference set from `share/drydock/objc/reference`, found from where the real `drydock-objc` binary is, so a symlink to it works; `--references DIR` names another.

All five subcommands run on macOS and on Linux, with the same arguments and exit statuses. `receipt` takes `--clang-prefix` and `--sdk`, and fetches nothing: you name the clang and the SDK, and it loads that clang's libclang at run time. On Linux, using `receipt` needs a host with glibc 2.35 or newer (Ubuntu 22.04+), because the pinned libclang.so needs it; `drydock-objc` itself stays within the archive's floor.

### Input strictness

Every JSON input (the reference manifest and cluster witnesses, build evidence, a provider declaration, objc-api exception evidence, reviewed evidence for `resolve`) must be one UTF-8 JSON object. From 0.7.0 these are refused as cannot-measure (exit 4), where 0.6 took them:

* a duplicate key in an object;
* an integer outside a 64-bit signed integer;
* `\u0000` in a string;
* a UTF-16 or UTF-32 document, or a UTF-8 byte-order mark;
* a `schema` other than the integer `1` (or `2` where schema 2 exists): `1.0` and `true` are no longer schema 1;
* a schema-1 guard's `source.line`, or a provider atom's `size`, that is a real number or a boolean, which 0.6 read as an integer (`12.5` as 12, `true` as 1; an absent or non-numeric `source.line` still records 0).

One input is laxer than 0.6's Foundation reading: a real too small for a double, such as `1e-400`, which 10.9 refused, now parses as 0.0. It cannot reach a verdict, because every number `drydock-objc` reads must be an integer.

Nesting deeper than 513 levels is refused, as 10.9's Foundation refused it. A parse failure is `malformed-input`, its detail naming the line and column. An unknown key is named in document order: the first one the document holds.

### Build evidence, schema 2

Reviewed build evidence is a JSON file a product keeps beside its source. Schema 2 keys each review to the code it was about, not to the revision it was made at. It names a prepared source tree by `source.tree_sha256`, which `drydock-objc evidence --tree-digest-only --source-root DIR` prints. Each guard record, R2 type evidence row and R3 position row lists the files it rests on, as `sources` (`{cite, sha256}`, a cite being `tree:PATH`, `crate:NAME-VERSION/PATH` or `sdk:PATH`), R2 and R3 rows add a free-text `note`, and a guard record also lists `covers`, the guarded sends it reviewed, per selector with a count; in a fat artifact each slice must show that count. `crates[]` pins each crate as `{name, version, checksum?, disambiguator}`, and lists only the crates the artifact's symbols name; the checksum is provenance (a workspace or path crate has none) and is never compared. Its `revision`, `patches_sha256` and `features` are provenance only: they are carried into the report and never compared. A review holds while its files are unchanged.

`analyze` takes the evidence with `--build-evidence FILE` and checks it itself: `--source-root DIR` is the prepared tree (needed for any row a send uses), `--crate-sources DIR` holds the crates as `NAME-VERSION/`, and `--sdk-root DIR` is the SDK, which an `sdk:` cite holds against only if its header digest (`drydock-objc evidence --sdk-digest-only --sdk-root DIR`) is the reference set's pinned floor SDK. The analyzer hashes every cited file, and refuses a path that leaves its root. A `crate:` cite holds only when its `NAME-VERSION` is a `crates[]` entry's name and version (a `-` in the directory matching a `_` in the name), a `tree:` cite may not reach into `.git` (the tree digest leaves it out), and an `sdk:` cite must be one of the headers the SDK digest covers. Records no send uses fail nothing. These options need `--build-evidence`. The refusals, each exit 4:

* `source-tree-mismatch`: the tree at `--source-root` is not the one `source.tree_sha256` names, or a row is in use with no `--source-root` to verify it.
* `guard-source-changed`, `position-source-changed` (an R2 or R3 row): a cited file's hash is not the recorded one.
* `guard-coverage-changed`: the guarded sends in the function copies a guard record names are no longer exactly its `covers`.
* `citation-unverifiable`: a cite cannot be checked (no root, no such file, a path out of its root or into `.git`, a crate the evidence does not pin, an `sdk:` file outside the digest or against an SDK that is not the pinned one).
* `link-map-mismatch`: `--link-map` names a map that does not hash to the evidence's `link_map.sha256`, or the evidence records no link map.
* `resolve-ambiguous`: from `resolve`, not `analyze`: a reviewed path names several functions that are not copies of one instance, or a crate's disambiguator cannot be told from the artifact.

A row names its code by `path`; `symbol` or `symbols` (the copies of one generic instance) are what `analyze` matches, and `drydock-objc resolve` writes them. A row used while it has neither, or whose symbols are not its path's, is `malformed-build-evidence`. Schema 1 evidence is accepted and judged as before, revision and all.

`drydock-objc resolve --artifact FILE --reviewed FILE --output NEW_FILE` reads schema-2 reviewed evidence and writes it again with every guard's, R2 row's and R3 row's `symbol` or `symbols`, and every crate's `disambiguator`, read from the artifact. Everything else, `artifact` and `source` included, is copied unchanged: the product's build stamps those. The output is the whole document with its keys sorted by Unicode code point (byte order of their UTF-8, so a non-ASCII key sorts after every ASCII one) and a 2-space indent. It exits 0 when it wrote the output; 2 for a usage error, or when `NEW_FILE` already exists (it never overwrites); 4 having written nothing, with each error on stderr: `stale-build-evidence` for a path no function of the artifact has or a crate no symbol names, `resolve-ambiguous` as above, `malformed-build-evidence` for evidence that is not schema 2.

### Undecoded bytes in code

Bytes in code that no instruction covers can hold a value that happens to land on a selector reference or lazy pointer, and `analyze` refuses such a window as `undecodable-objc-reference`. Constant tables in assembly (aws-lc's, for one) do this by chance. `drydock-objc evidence --link-map FILE` binds the link's map as `link_map.sha256`, with or without `--provider-prefix`. `analyze --link-map FILE`, which needs `--build-evidence` naming that map, clears a window only when the map places it in an object file whose bytes there match the image and carry no relocation, so the assembler fixed them and they can reach only that object's own section, and the address they would name lies outside it. The object comes from the map's path, or by its basename from exactly one `--object-dir DIR` (repeatable), for a build whose objects have moved. Both options are optional; a window that cannot be cleared still refuses, and its detail ends `(not attested: REASON)`. Given `--link-map`, the report adds `undecoded_code_bytes_attested`: of `undecoded_code_bytes`, the whole undecoded runs that passed the sweep only because some window in them was cleared this way. A run with one cleared window counts in full, its other bytes included.

Building Drydock now fetches the pinned clang22 at configure time, for its `clang-c` headers only (nothing of it ships), so a build needs network access or a warm cache.

## drydock-resources

`drydock-resources` makes the nibs of an app built for a newer macOS load on Mavericks. Modern Xcode compiles nibs as NIBArchive files, which 10.9's AppKit cannot read; `drydock-resources` rewrites them as the keyed archives 10.9 reads, adapts what 10.9 would lay out differently, and reports what it cannot fix. It runs on macOS and Linux. It has four subcommands:

* `drydock-resources dump NIB` prints a nib (a NIBArchive file, or a nib directory's `keyedobjects.nib`) as text a person can read, diff and edit.
* `drydock-resources build TEXT -o NIB` builds a keyed-archive nib from that text, replacing `NIB` whole or leaving it as it was.
* `drydock-resources check BUNDLE|NIB|TEXT` prints every finding for every nib of a bundle, or for one nib, nib directory, `.storyboardc` or dump, one per line, sorted: `NIB: SEVERITY: KIND ITEM (DETAIL)`.
* `drydock-resources convert BUNDLE|NIB` checks as `check` does, then rewrites each NIBArchive nib in place as a keyed archive, adapted. A keyed nib is left byte for byte unless a rule adapts it.

Every subcommand takes `--target 10.9`, the only target. `check` and `convert` take `--report NEW_FILE` for a JSON report, which never replaces a file. The tool finds Drydock's reference data beside its real binary, under `share/drydock/objc/reference` and `share/drydock/resources/reference`; `--references DIR` and `--resource-references DIR` name others.

### Strict by default

`convert` is strict: any finding no exception accepts means it writes nothing at all. `--no-strict` writes every nib but those it cannot encode or whose objects' classes it cannot resolve, and still exits 1. A NIBArchive nib held back this way, by a `blocks-write` finding, stays NIBArchive, and its `nibarchive-format` line becomes a `finding` that says so, even when the `blocks-write` finding is accepted. Every nib is staged beside itself before any is renamed into place, so a nib that cannot be staged leaves every nib as it was.

### Adaptation rules

Two rules rewrite what 10.9 takes literally in a modern nib. They are on by default, `--no-adapt` turns both off, and `--no-adapt=RULE` turns off one:

* `translate-autoresizing` sets `NSDoNotTranslateAutoresizingMask` to true where the nib stores it false on a view a constraint names, other than a window's or a box's content view. Without it, 10.9 turns the view's autoresizing mask into constraints that conflict with the nib's own.
* `wrapping-width` gives a wrapping text field with no `NSPreferredMaxLayoutWidth` its frame width less 4. Before 10.11, a label with no preferred width is measured as one line.

`check` reports what a rule will fix as `will-adapt`, which strict mode allows; with `--no-adapt` the same problem is an ordinary `finding`. `convert` and `build` print each rewrite as `NIB: adapted: RULE (@N KEY)`.

### Accepting gaps

`--exceptions FILE` accepts findings you have judged harmless, one per line, four fields separated by tabs:

```
NIB_GLOB<TAB>KIND<TAB>ITEM<TAB>REASON
*MFPreferencePane.nib	named-color-missing	labelColor	10.9 draws it opaque black, where 10.10 draws it black at 85%
```

A finding of `KIND` and `ITEM` in a nib whose bundle-relative path matches `NIB_GLOB` (fnmatch, where `*` also matches `/`) is printed with `accepted as KIND:ITEM` and no longer counts. An accepted `storyboard` finding covers every finding in that storyboard's nibs. A line that accepts nothing is named on stderr. A malformed line is exit 4, before any work.

### Exit codes

* 0: no finding, or only `will-adapt` and accepted ones.
* 1: findings, or a directory with no nibs, which is said on stderr (`build`: a dump it cannot encode or adapt).
* 2: a usage error, an unknown rule, or a report file that already exists.
* 4: a nib, dump, exceptions file or reference set that cannot be read or written, or out of memory.

### The dump

A dump starts with its version, the archive's format, and the superclass chain of every class it names. Then come the objects, `@N CLASS`, each with one `KEY = TYPE VALUE` line per value. Some lines from macFUSE's pane:

```
drydock-resources dump 1
format nibarchive 1 10
chain NSTextField : NSControl : NSView : NSResponder : NSObject

@37 NSTextField
  NSNibTouchBar = nil
  NSvFlags = i16 268
  NSFrame = ref @38
  NSDoNotTranslateAutoresizingMask = true

@38 NSString
  NS.bytes = data "{{18, 20}, {549, 16}}"
```

and from the keyed archive `convert` writes of it, where the label has gained its preferred width:

```
@37 NSTextField
  NSPreferredMaxLayoutWidth = f64 0x1.108p+9  # 545
```

The types are `i8`, `i16`, `i32` and `i64`; `true` and `false`; `f32` and `f64`, written exactly in hexadecimal with the decimal after `#`; `data`, quoted with escapes, or as hexadecimal `x"..."` pieces for bytes that are not text; `nil`; and `ref @N`. A chain of `?` is a class neither the reference set nor the bundle's own binaries define. A nib with an object of that class cannot be built; a class only an `NSClassSwapper` names is a `finding`, since the keyed archive never stores its chain.

A NIBArchive dump and a keyed-archive dump differ as their formats do:

* The format line: `format nibarchive A B` carries the NIBArchive header's two numbers; `format keyed` has none.
* The chains: a NIBArchive nib names only its classes, so `dump` finds their superclasses in the reference set and in the bundle's binaries. A keyed archive stores each class's chain, which `dump` prints as stored, adding `hints` for its `$classhints` and, from the reference set, `newer` for a class newer than the target.
* The values: a NIBArchive stores each integer at its own width, every string as `data`, and each collection as `NSInlinedValue = true` followed by one `UINibEncoderEmptyKey = ref @N` line per element. A keyed archive stores integers as `i64`, strings as `string`, a collection as one `NS.objects = uids @N @M ...` line, and a plain string, number or data in its object table as a `bare` object.
* The order: a NIBArchive's values are dumped in the archive's order, and a keyed archive's in its dictionaries' order.

`build` writes a keyed archive from either. `convert --no-adapt` of a nib gives the same bytes as `build --no-adapt` of its dump.

## Other related tools

- `install_name_tool` from the Mavericks Command Line Tools
- `llvm-install-name-tool` from [clang](https://github.com/Mavergreen/clang)
