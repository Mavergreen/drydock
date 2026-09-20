# Design: `dylib retype`, `imports`, and an `insert_dylib` wrapper

Queue items 12 (an `insert_dylib` wrapper) and 13 gaps 3 and 7, taken together
because gap 3 is what makes item 12's `--weak` implementable and the wrapper is
the first caller of both.

## What is being built

1. **`dylib retype PATH KIND`** — one statement that rewrites a dylib load
   command's `cmd` field, in either direction, across the four ordinal-bearing
   dylib kinds. Subsumes the existing one-way `dylib reexport`.
2. **`machorewrite imports FILE`** — a new read-only verb emitting every
   `(install_name, symbol)` pair the image imports, as TSV with a header row.
3. **`compat/insert_dylib.sh`** — a seventh wrapper, presenting
   `Wowfunhappy/insert_dylib`'s command line over these statements.

## Decisions

### KIND is four values, and `lazy` is refused

`mo_is_ordinal_lc` (`src/ordinals.c`) counts `LC_LOAD_DYLIB`,
`LC_LOAD_WEAK_DYLIB`, `LC_REEXPORT_DYLIB` and `LC_LOAD_UPWARD_DYLIB`. KIND is
those four, spelled `load`, `weak`, `reexport`, `upward`.

`LC_LAZY_LOAD_DYLIB` is **not** a KIND. `mo_map_build` already refuses an image
carrying one, because whether it takes a slot in the ordinal sequence has never
been exercised here. Accepting it as a retype target would let this tool emit
images its own verbs refuse. The refusal names that reason.

Every one of the four is ordinal-bearing, so a retype moves no ordinal and
changes no byte count: it is a single `uint32_t` write, the same one
`src/rewrite.c`'s reexport path already performs. The row therefore declares
`MREL_NONE`, as the `reexport` row does.

### `dylib reexport PATH` survives as a row

It becomes a spelling of `retype PATH reexport`. Removing it would break every
existing script and the `change_dylib` wrapper's `-reexport` path for no
capability gain. This is not the "two spellings of one act" the
script-is-the-only-interface work removed: there both spellings had their own
code path, and here there is one implementation with a fixed second argument.

`--capabilities` gains the KIND list, so a wrapper discovers the accepted set
rather than hard-coding it and drifting.

### The table's `flag`, `modes` and `ops_ord` columns

Vestigial. `src/script.h` records that they are read only by `ms_table_row`
since the mutating verbs were deleted. The new row carries `NULL`/`0`/`0` rather
than inventing values that describe a grammar which no longer exists. Existing
rows are left alone; tidying them is not this work.

### `imports` is a verb, not a flag on `info`

`info FILE` takes exactly three argv and refuses anything else. Adding
`-imports` would reopen flag parsing on a read-only verb months after the
mutating side's flag grammar was deliberately deleted, and every later report
would be another flag. A verb keeps each output single-purpose, separately
hashable, and free of argument parsing.

### The `imports` output contract

```
arch	ordinal	kind	install_name	symbol	weak
x86_64	1	load	/usr/lib/libSystem.B.dylib	_memcpy	0
x86_64	2	weak	/System/.../AppKit	_NSBeep	1
x86_64	flat	-	-	_CFRelease	0
```

One header row, then one tab-separated row per pair. **Columns may be appended;
they are never reordered, renamed or removed.** Consumers select by column name.
That contract is what lets the live missing-symbol half — item 13's other half,
not built here — add a `status` column later without breaking anything reading
this today.

Fat containers are handled from the start, one row set per slice, which is why
`arch` is the first column rather than an afterthought. `ordinal` carries
`flat`, `self`, `exe` for the
`BIND_OPCODE_SET_DYLIB_SPECIAL_IMM` values, which have no install name; those
rows carry `-` for `kind` and `install_name`. `weak` is `1` when the pair's
`BIND_SYMBOL_FLAGS_WEAK_IMPORT` is set.

Only structural facts appear here — everything is a function of the file's
bytes, so the output is deterministic and testable against committed fixtures on
any host. Nothing asks the running system whether a symbol exists.

### A chained-fixups image is refused

`LC_DYLD_CHAINED_FIXUPS` stores imports in a different structure. `imports`
refuses such an image by name and points at `fixups set`, which converts. This
follows the codebase's standing rule: refuse rather than guess.

`imports` exits 0 on success and `EX_REFUSED` for anything it declines — not a
readable 64-bit Mach-O, or chained fixups — matching `info` and `verify`. An
image with no bind stream at all is not a refusal: it is a successful report of
zero rows, header line included.

### One walker, two consumers

`src/ordinals.c` already walks every bind opcode — both `SET_DYLIB_ORDINAL`
forms, `SET_SYMBOL_TRAILING_FLAGS_IMM`, and the rest — in order to renumber. The
reporter needs the same walk to observe rather than rewrite.

That loop becomes callback-driven, with the renumberer and the reporter as its
two callers. `ordinals.h` already argues this shape for `mo_map_build`: a second
independent walk is a second place to disagree with the first, and this module
exists because two places that had to agree about ordinals did not.

### The wrapper's prompts read `/dev/tty`

`insert_dylib` prompts on five conditions. The wrapper pipes its statements to
`machorewrite`'s stdin, so stdin is not available to ask on; prompts read
`/dev/tty`. With `--all-yes` nothing is asked. With no tty and no `--all-yes`,
the wrapper refuses rather than blocking — a wrapper that hangs in a build
script is worse than one that fails.

### Flag mapping

| flag | statements |
|---|---|
| (none) | `dylib append PATH` |
| `--weak` | `dylib append PATH`, `dylib retype PATH weak` |
| `--strip-codesig` | adds `load-command delete codesig` |
| `--no-strip-codesig` | suppresses it; no prompt |
| `--inplace` | output is the input path |
| `--overwrite` | suppresses the "already exists" prompt |
| `--all-yes` | answers every prompt yes |

Default output is `<binary_path>_patched` — appended, confirmed from
`main.c`'s `asprintf`. The fork's README says "prepended" and is wrong.

The load command lands at the end of the load commands, which is `dylib append`,
not `dylib insert`. Queue item 12 said `-insert`; that was incorrect.

## What is claimed, and what is tested

**Claimed: the interface.** Flags accepted, statements emitted, default output
path, prompt conditions, exit codes, and refusals. All of it is determinable
from the fork's source and is differential-tested against it at a pinned commit.

**Not claimed: output bytes.** The two tools reach a valid result by different
routes. `docs/prior-art.md` records four checks on this side the fork does not
make (`LC_FUNCTION_STARTS` leading delta, `LC_DATA_IN_CODE` contents,
`__TEXT,__unwind_info`, post-transform `mg_verify`/`mg_plausible`) and one place
the fork proceeds where this refuses (unknown load command). The fork's own
README states its header-expansion path "has not been verified beyond (1) it
passes Claude's own tests and (2) it works with Momiji". Pinning our bytes to
that would adopt an unverified reference and discard checks we have.

### Declared divergences, for `compat/README.md`

- **32-bit input is refused.** `insert_dylib` handles it. This toolkit refuses
  it everywhere, deliberately and with regression tests. Queued separately as
  item 16; not reopened here.
- **An unknown load command is refused**, where the fork proceeds.
- **Exit codes are `machorewrite`'s 0/1/2, forwarded verbatim**, where the fork
  exits 1 for everything. This matches the six existing wrappers, whose
  divergence tables already say so.
- **Output bytes are not claimed equal.**

## Testing

- `dylib retype`: unit tests per KIND pair, both directions, asserting the
  `cmd` field changed and that nothing else did — byte length, ordinals, and
  the rest of the image identical. A `lazy` target and an unknown KIND each
  assert their named refusal.
- `imports`: fixture-driven, hashable. Cases for a `flat`/`self`/`exe` ordinal,
  a weak import, a fat container, and the chained-fixups refusal. The header
  contract gets a test that reads a column by name, so reordering columns fails
  loudly rather than silently moving a consumer's data.
- `insert_dylib`: differential-tested against the fork pinned at `bd221b8`
  ("Fixes for some executables"), which is where every behaviour in this
  document was read. The pin lives beside the test that uses it, and moving it
  is a deliberate act with a diff to review, not a `git pull`.

  `tests/compat-sweep.sh` is **not** extended: it holds a frozen matrix it
  refuses to overwrite, covering the six historical tools, and adding a seventh
  would mean regenerating a reference that exists to be stable. `insert_dylib`
  gets its own sweep.

  `tests/known-callers.sh` gains nothing — there are no known callers. That
  absence belongs in the wrapper's header, so a reader is not left wondering why
  the decisive gate is silent for this one tool.

Nothing above moves `tests/EXPECTED`: `characterize.sh` hashes the bytes its
fixed pipeline produces, and that pipeline is unchanged.

## A note on citations

Source added by this work **does not carry a `spec:` tag pointing at this file.**
Superpowers docs are ephemeral; queue item 7 is already committed to dropping
`spec:` from the comment standard and rewriting the 25 citations that exist,
precisely because a blessed tag pointing at a deliberately temporary file is what
turned scratch into a dependency. Adding the twenty-sixth while planning to
remove the first twenty-five would be absurd. Where a comment here needs a
reason, it states the reason.
