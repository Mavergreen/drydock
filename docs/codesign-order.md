# What 10.9's `codesign` needs of `__LINKEDIT`

Why `src/linkedit_order.[ch]` checks what it checks, and why a run that changes
`__LINKEDIT` also packs it. Researched 2026-09-26 on 10.9.5 (13F1911).
Claims are tagged as in `docs/minimum-os-version.md`:

- **MEASURED** means run on this host;
- **SOURCED** means read in [apple-oss-distributions/cctools](https://github.com/apple-oss-distributions/cctools),
  tag `cctools-862`, which is what 10.9's Command Line Tools 6.2 ship (the
  binary carries that string).

## The tool

`codesign` runs `codesign_allocate`, which does two things:

- it **checks** the image: `libstuff/ofile.c`'s load-command loop and
  `libstuff/checkout.c`;
- it **rewrites** it with room for the signature: `misc/codesign_allocate.c`
  and `libstuff/writeout.c`.

`codesign_allocate -i IN -a x86_64 16384 -o OUT` runs it alone, without
signing. `tests/codesign_order_test.sh` does that, on 10.9, against every
fixture in `tests/linkedit_fixture.h`.

## "unknown load command N" is an index

`ofile.c` prints the loop index of the first command it has no case for. So
4 is the fifth command, not `cmd` 4. MEASURED: Mantle, whose fifth command is
`LC_DYLD_CHAINED_FIXUPS`, says 4.

Commands cctools-862 does not know:
- `LC_FVMFILE`, `LC_PREPAGE`;
- `LC_VERSION_MIN_TVOS`, `LC_VERSION_MIN_WATCHOS`;
- `LC_NOTE`, `LC_BUILD_VERSION`;
- `LC_DYLD_EXPORTS_TRIE`, `LC_DYLD_CHAINED_FIXUPS`;
- `LC_FILESET_ENTRY`, `LC_ATOM_INFO`, and everything later.

`fixups set classic` removes the three a modern image carries, and `minos`
replaces `LC_BUILD_VERSION`.

## The order

For a dylib, or any image with `MH_DYLDLINK`, that has an `LC_DYSYMTAB`,
`checkout.c`'s `dyld_order()` requires each piece to start exactly where the
previous one ended. The first piece starts at `__LINKEDIT`'s file offset. The
order is:

1. the dyld info: rebase, bind, weak-bind, lazy-bind and export, as one block;
2. local relocations;
3. split info;
4. function starts;
5. data in code;
6. code-signing DRs;
7. linker optimization hints;
8. the symbol table: locals, then defined externals, then undefined;
9. two-level hints;
10. external relocations;
11. the indirect symbol table;
12. the table of contents, module table and reference table;
13. the string table;
14. the code signature, at the next multiple of 16.

`__LINKEDIT` must end the file. The only gaps allowed are:
- that 16-rounding;
- an 8-rounding after an odd-sized indirect table, taken by the first table
  after it.

A split-info, function-starts or data-in-code piece whose offset is 0 is not
checked, but still counts toward the running offset. An image without an
`LC_DYSYMTAB` is held only to `symbol_string_at_end()`: the string table
ends the file, before the signature, and the symbol table directly precedes it.

MEASURED: every layout in `tests/linkedit_fixture.h` gives the refusal its row
names.

## What the writer silently assumes

`codesign_allocate` never changes an offset in a load command. Its writer
works like this:
- it copies the file verbatim up to `object_size − input_sym_info_size`;
- it writes the pieces back one after another, each from where its load
  command says it is;
- it puts the signature at the next multiple of 16.

`input_sym_info_size` is a **sum** of the pieces' sizes. It counts:
- with an `LC_DYSYMTAB`, every other piece: the five dyld-info streams, the
  relocations, split info, function starts, data in code, code-signing DRs,
  linker hints, two-level hints, the indirect table and the pad that rounds
  an odd-sized one to 8, and the table of contents, module and reference
  tables;
- without an `LC_DYSYMTAB`, none of those;
- the symbol and string tables, with or without it, but only when there are
  symbols.

The dyld info is copied as one span, from its first byte to its last. So a
hole inside it, or a string table without symbols, shifts every later piece
off its offset. Nothing reports it.

MEASURED, all with the order rules passing:
- an 8-byte hole between two streams made a signed file whose `__LINKEDIT`
  runs past its end;
- a 2,936-byte hole (the old rebase stream `objc-methods set absolute` used
  to leave zeroed) made a file that **`codesign -v` accepts** while its rebase
  and bind opcodes are wrong;
- a hole the 16-rounding happens to absorb is harmless.

So `codesign -v` passing is not evidence of a correct re-sign. `mlo_check`
simulates the writer and compares, piece by piece, the bytes it would leave at
each piece's offset. Any other host's `codesign_allocate` makes the same sum
(`cctools-1035.1.102`, SOURCED), which is why a corrupting output is refused
rather than reported.

## Fat files

`checkout()` runs over every slice, whichever one is signed. MEASURED: an
x86_64 + x86_64h file whose x86_64h slice still has chained fixups is refused
when `-a x86_64` is signed. `info`'s `resign 10.9:` line is therefore a
verdict on the whole file.

## Does 10.9 need a valid signature?

No. MEASURED with a clang-built dylib and executable:

| image | from an ordinary process | from one signed `-o kill` |
|---|---|---|
| dylib, stale signature | loads | killed (`denying page sending SIGKILL`) |
| dylib, signature removed | loads | loads |
| executable, stale signature | runs | — |
| executable signed `-o kill`, then edited | killed (exit 137) | — |
| executable, signature removed | runs | — |

A well-formed stale signature is the only one that can hurt, and only under
the kill flag. `docs/minimum-os-version.md` has the sdk rule that decides
whether dyld registers a dylib's signature at all. Drydock keeps a stale
signature, moved to the end where `codesign --force` replaces it.
`load-command delete codesig` removes it, bytes and all.

## Snow Leopard

`cctools-782` (SOURCED; that it is 10.6's is inferred) has the same core
order, but its `ofile.c` knows none of these:
- `LC_VERSION_MIN_MACOSX`, `LC_FUNCTION_STARTS`, `LC_DATA_IN_CODE`;
- `LC_MAIN`, `LC_SOURCE_VERSION`, `LC_DYLIB_CODE_SIGN_DRS`.

10.6's own `codesign` therefore cannot re-sign a typical 10.9 image, whatever
its order.
