# Bind-stream editing: per-symbol fixes for missing symbols

Why Drydock plans `import weaken` and `import flatten`, and how they differ
from the shim libraries the Mavericks community already uses. The design is in
`docs/superpowers/specs/2026-09-23-bind-stream-edit-design.md`. It is not
built yet.

## The problem

A Mach-O names the library each imported symbol comes from (two-level
namespace), and 10.9's dyld resolves every non-lazy and non-weak import at
launch. If one of them is missing on 10.9, the app never runs a line:

```
dyld: Symbol not found: _foo
  Referenced from: …
  Expected in: /usr/lib/libSystem.B.dylib
```

Apps built for a newer macOS routinely reference a few newer APIs. Often they
sit behind an availability check or in a feature a 10.9 user never reaches.

## What already exists: library-level redirection

The established remedy replaces a whole library:

- Mavericks Forever's Claude Code installer rewrites every reference to
  `libSystem`, `libicucore` and `libc++` so it names a wrapper library. It
  does this with nine `change_dylib -change` pairs, or `dylib replace`
  statements in an edit script.
- Each wrapper re-exports the real 10.9 library and adds the functions 10.9
  lacks.
- Mavergreen's legacy-support and Mavericks-Porting-Resources' shims work
  the same way.

Every symbol the app expected from `libSystem` then resolves through the
wrapper. When a whole library is the unit that needs filling in, this is the
right tool. For Claude Code it is sufficient.

## What bind-stream editing adds: per-symbol changes

The bind stream is the table that says which library each imported symbol
comes from. Bind-stream editing changes one entry in it and leaves every other
binding as the app shipped it. There are three statements:

- **`import weaken SYMBOL LIB`** marks one import optional. dyld launches the
  app with that symbol set to NULL instead of refusing. It needs no shim at
  all. It is enough when the app checks for the API before calling it, or
  never reaches the call on 10.9. If the app does call it, it crashes there
  instead of at launch.
- **`import redirect SYMBOL FROM TO`** (already built) points one import at
  a named library, such as a small shim.
- **`import flatten SYMBOL LIB`** makes one import resolve from whichever
  loaded library defines it (flat lookup). A shim library can then supply it
  without anyone naming the shim in the binary.

## When per-symbol beats per-library

- **The symbol isn't worth implementing.** Weaken it. There is no wrapper
  library to write, build or ship.
- **The missing symbol lives in a large system framework.** Two functions
  missing from AppKit or Foundation don't justify a wrapper that re-exports
  the whole framework, changes every binding the app makes against it, and
  still misses the bindings of other frameworks the app loads. Redirecting or
  flattening just those two leaves everything else untouched.
- **One shim covers gaps across several frameworks.** A single small library
  can supply a few functions each from Foundation, AppKit and
  CoreFoundation, without wrapping any of them.
- **The app's own bundled frameworks import the missing symbol.** They bind
  by exact library name as well. Per-symbol edits fix those imports without
  repointing whole libraries inside frameworks you don't otherwise want to
  touch.

## Where it is not needed

A binary whose missing symbols all come from a few libraries that are
practical to wrap is already served by library-level redirection. Claude Code
is one: its wrappers cover `libSystem`, `libicucore` and `libc++`.
