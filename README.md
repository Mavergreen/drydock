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

Given an Objective-C binary built for Mavericks, report which of its message sends the Mavericks runtime and SDK can answer. It is shipyard's Objective-C analyzer, moved here so the tool that rewrites a Mach-O file and the tool that checks what it will do on 10.9 ship together. It has four subcommands:

* `drydock-objc analyze`: analyze an artifact against the reference set and write a report.
* `drydock-objc evidence`: write the source-side evidence an artifact's analysis is checked against.
* `drydock-objc link-args`: print the link arguments for a provider prefix and link map.
* `drydock-objc receipt`: write an Objective-C provider's source receipt: every Objective-C send in its verified prepared sources, with the identities of the clang (its libclang version), the SDK and the tool that took it.

Their arguments and exit statuses are those of the shipyard scripts they replace; run `drydock-objc` with no arguments for the usage. It reads its reference set from `share/drydock/objc/reference`, found from where the real `drydock-objc` binary is, so a symlink to it works; `--references DIR` names another.

`analyze`, `evidence` and `link-args` run on macOS only. On Linux, for now, the tarball's `drydock-objc` does `receipt` alone and those three exit 2: their front end is Foundation, which Linux lacks, until it is ported to C. `receipt` runs everywhere. It takes `--clang-prefix` and `--sdk`, and fetches nothing: you name the clang and the SDK, and it loads that clang's libclang at run time. On Linux, using `receipt` needs a host with glibc 2.35 or newer (Ubuntu 22.04+), because the pinned libclang.so needs it; `drydock-objc` itself stays within the archive's floor.

Building Drydock now fetches the pinned clang22 at configure time, for its `clang-c` headers only (nothing of it ships), so a build needs network access or a warm cache.

## Other related tools

- `install_name_tool` from the Mavericks Command Line Tools
- `llvm-install-name-tool` from [clang](https://github.com/Mavergreen/clang)
