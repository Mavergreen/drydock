# Case study: what Drydock would have saved MACL's iWork ports

[nfzerox/MavericksAppCompatibilityLayer](https://github.com/nfzerox/MavericksAppCompatibilityLayer)
(MACL) ran two generations of iWork on older macOS and kept a detailed log in
`JOURNEY.md`:

- **iWork 2015** (Keynote 6.6.2, Pages 5.6.2 and Numbers 3.6.2) on 10.9.5. This
  took about 11 hours over 32 checkpoints and was finished.
- **Keynote 9.1** (built on the 10.14 SDK for 10.13) on 10.12, 10.11, 10.10 and
  10.9. This took about 5.5 hours more. It mostly works on 10.12 and 10.11. The
  10.10 and 10.9 tiers were left broken.

This document sorts every intervention MACL made by whether Drydock performs it,
to measure how much of a real GUI-app port is binary editing. Citations are
`file:line` in MACL at commit `1ca33fb`.

Classes:

- **(a)** Drydock does it today.
- **(b)** Planned bind-stream editing (`import weaken`, `import flatten`); see
  [bind-stream-editing.md](bind-stream-editing.md).
- **(c)** Planned conversion of relative Objective-C method lists to absolute
  ones.
- **(d)** None of these.

## Summary

- **iWork 2015: 11 hours would become about 9.5 to 10.** Drydock and bind-stream
  editing replace MACL's binary-patching tools: `weaken_dylibs.py`,
  `macho_binds.py`, `patch_surgical.py` and its `--inject-dylib`. That is about
  630 of the ~1,990 lines in `tools/`, all from checkpoints 1, 3 and 18.
  Checkpoints 5 to 32, about 7.5 hours, are untouched. They built a 2,150-line
  Objective-C shim with 103 methods and 24 runtime method patches, which
  recreates Yosemite AppKit behaviour.
- **Keynote 9.1: minutes to perhaps an hour saved, and the same outcome.**
  Drydock replaces the minimum-version tool, the flat and weak rewriting of 18
  binaries, and injecting the stub library into every framework. The attempt
  was stopped by other things, none of them binary edits:
  - 302 missing symbols to discover and classify;
  - 300 to 1,150 lines of shims per OS tier;
  - a static-initialiser heap corruption that nobody solved.
- **Method-list conversion applied to neither.** The linker writes relative
  method lists only for macOS 11+ deployment targets. iWork 2015 targeted 10.10
  and Keynote 9.1 targeted 10.13 (`JOURNEY.md:59-61, 1059-1061`). Each ran as
  shipped on a runtime that cannot read relative lists, and Keynote 9.1 ran on
  10.11 and 10.12 with no method-list handling (`JOURNEY.md:1537-1545`). No iWork
  binary was inspected directly; this rests on the deployment targets and the
  runtimes that ran them.
- **The Mach-O minimum was never enforced.** MACL never changed iWork 2015's
  `LC_VERSION_MIN_MACOSX`, and it ran on 10.9 anyway. That contradicts MACL's own
  `patch_min_version.py:9-10` and agrees with
  [minimum-os-version.md](minimum-os-version.md).

The hard part of porting a GUI app is making missing APIs and changed runtime
behaviour work, and that stays human work. Drydock turns the mechanical part
into a few lines of edit script. It does the edits without parser mistakes
around header slack or ULEB padding, and it loads a shim through a real load
command instead of `DYLD_INSERT_LIBRARIES`. Method-list conversion, chained
fixups and `__DATA_CONST` are what an app built for macOS 11 or later needs
before any shim work can start. MACL never faced them because it chose older
app versions.

## iWork 2015 → 10.9.5

| # | Intervention | Evidence | Size | Class |
|---|---|---|---|---|
| 1 | Blanket weakening: `WEAK_IMPORT` on every bind to `/System/Library/Frameworks/*` and `/usr/lib/*`. A debugging step, later abandoned | `JOURNEY.md:69-79`; `tools/weaken_dylibs.py` | 2,989 binds in Keynote; 200-line tool | (b), one `import weaken` per symbol, generated from `imports` output |
| 2 | `LC_LOAD_DYLIB` → `LC_LOAD_WEAK_DYLIB` for libraries 10.9 lacks (CloudKit etc.) | `JOURNEY.md:75-76, 161`; `patch_surgical.py:154-158` | 6 libraries for Keynote | (a) `dylib retype PATH weak` |
| 3 | Per-symbol rewrite of missing symbols to flat lookup plus weak import, in the bind, lazy-bind and weak-bind streams; ULEB ordinals padded with `0x51` | `JOURNEY.md:159-171`; `patch_surgical.py`; `macho_binds.py` | 63 symbols in Keynote, 66 in Pages, 60 in Numbers; 245 + 188 lines | (b) `import flatten` + `import weaken`. Drydock re-encodes the stream instead of padding it |
| 4 | Missing-symbol discovery: `dlcheck` asks the live 10.9 loader about each import | `JOURNEY.md:143-151`; `tools/dlcheck.c`, `tools/diff_imports.py` | 78 + 225 lines | (d). Drydock's `imports` supplies the input list |
| 5 | Type classification from 10.10 SDK headers; typed stub generation | `JOURNEY.md:152-177`; `tools/classify_symbols.py`, `gen_stubs.py` | 360 + 130 lines | (d) |
| 6 | The stub library: constants, classes, 10.10 category methods, C functions | `JOURNEY.md:101-118, 221-290` | 2,150 lines, 103 methods, 14 categories | (d). (b) only makes it reachable |
| 7 | `OSAtomic*` functions compiled separately, because the 10.9 SDK makes them `static inline` | `JOURNEY.md:259-264` | 7 functions | (d) |
| 8 | Loading the stub library through `LSEnvironment` `DYLD_INSERT_LIBRARIES` | `JOURNEY.md:101-105, 569-590`; `install_iwork2015.sh:231-236` | 1 plist key | (a) `dylib append`, with no environment variable |
| 9 | Bundling Yosemite's CoreUI so asset catalogs decode, loaded through an injected `LC_LOAD_DYLIB` | `JOURNEY.md:627-693`; `patch_surgical.py:99-147` | 1 framework | Injection: (a) `dylib insert`/`append`, which grows the header where MACL's tool refused (`patch_surgical.py:116-118`). The copy: (d) |
| 10 | `LSMinimumSystemVersion` → 10.9.0 | `JOURNEY.md:66-67` | 1 key | (d), trivial; Drydock does not edit Info.plist |
| 11 | Ad-hoc re-signing, `lsregister` | `JOURNEY.md:77-79, 815-826` | 1 command | (d) |
| 12 | Splicing view controllers into the responder chain | `JOURNEY.md:317-365, 978-1017` | 2 checkpoints, about 70 minutes; the last blocker | (d) |
| 13 | Forwarding `scrollWheel:` past view controllers | `JOURNEY.md:497-530` | 28 minutes | (d) |
| 14 | Fixing full-size-content window chrome | `JOURNEY.md:402-428, 699-733, 799-809` | 3 checkpoints | (d) |
| 15 | Behavioural fixes: save-panel file type, `contentViewController`, `viewDidLoad`, popover appearance and more | `JOURNEY.md:292-311, 475-495, 546-564, 597-621, 769-780, 903-918` | about 8 checkpoints | (d) |
| 16 | Visual fixes: colours, visual-effect-view fills, HUD panels | `JOURNEY.md:735-797, 924-972` | 4 checkpoints | (d) |
| 17 | Feature crashes, including one fixed through `__DATA,__interpose` | `JOURNEY.md:828-901` | 4 checkpoints | (d). The interpose could be `import redirect` (a), but the replacement is still code |
| 18 | Diagnostic tracers and view dumps | `JOURNEY.md:367-469` | 16 environment-variable gates | (d) |
| 19 | SSH wrappers and installer scripts | `JOURNEY.md:194-207` | about an hour lost to `sockaddr_un` length | (d) |

MACL did no NIB or resource editing, no method-list or fixup-format changes, no
segment renames and no Swift work for this port.

## Keynote 9.1 → 10.12, 10.11, 10.10 and 10.9

| # | Intervention | Evidence | Size | Class |
|---|---|---|---|---|
| 20 | Lowering the minimum OS in every binary to the tier | `JOURNEY.md:1072-1076`; `tools/patch_min_version.py` | 18 binaries | (a) `minos at-most` |
| 21 | Per-symbol flat and weak rewriting, extended to the main binary, 13 frameworks, 4 XPC services and the bundled Swift libraries | `JOURNEY.md:1101-1104, 1146-1156, 1409-1413` | 302 missing symbols at 10.9, 26 at 10.12 | (b), one edit script per binary |
| 22 | Weak-loading frameworks that are linked but never bound (Vision, ClassKit, Contacts, AuthKit) | `JOURNEY.md:1114-1121, 1308-1315` | a handful of load commands | (a) `dylib retype … weak`; finding them is (d) |
| 23 | Injecting the stub library into the main binary and every framework, so it loads before their initialisers | `JOURNEY.md:1141-1144` | per binary | (a) `dylib insert`/`append` |
| 24 | Copying the stub library into each XPC service | `JOURNEY.md:1150-1156` | 4 copies | (d), trivial |
| 25 | Discovery fixes: `@rpath`, `RTLD_DEFAULT` fallback, forced-missing lists | `JOURNEY.md:1106-1121, 1218-1223, 1303-1315` | 19 false positives dropped | (d) |
| 26 | A classifier rewritten over the 10.13 SDK, with a 195-entry typedef map | `JOURNEY.md:1190-1230` | 302 symbols | (d) |
| 27 | libSystem shims: `os_log`, `os_unfair_lock`, dispatch asserts, empty-collection singletons | `JOURNEY.md:1130-1136, 1173-1188, 1232-1282, 1415-1427` | 6 checkpoints | (d) |
| 28 | Framework shims: a CloudKit entitlement bypass, NSProgress, secure coding, named colours, window tabbing, Touch Bar, spell checking | `JOURNEY.md:1322-1454` | 299 lines at 10.12; 921 at 10.11; 1,147 at 10.10 | (d) |
| 29 | Inert Touch Bar classes; a working NSGridView built on stack views | `JOURNEY.md:1474-1535` | 2 checkpoints | (d) |
| 30 | Suppressing Auto Layout assertions | `JOURNEY.md:1456-1467, 1506-1511` | | (d) |
| 31 | Side-loading Sierra's CoreUI for 10.11 asset catalogs; parked | MACL's `memory/project_kpf9_sierra_coreui_sideload.md` | about 60 shims, not done | The framework is dropped in; wiring it is (b); the shims are (d) |
| 32 | 10.10 and 10.9: heap corruption in Keynote's static initialisers | `JOURNEY.md:1244-1282, 1541-1545` | unsolved | (d) |

MACL patched the bundled Swift libraries' binds (#21) but never touched
class-record ABI tags, and 10.11 worked without that. Whether Keynote 9.1's
classes carry the stable-ABI tag that `swift-abi set legacy` clears is not
recorded. Neither app needed chained fixups lowered or `__DATA_CONST` renamed:
chained fixups need a macOS 12 deployment target.
