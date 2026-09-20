/* imports.h -- report every (install_name, symbol) pair a 64-bit Mach-O
 * image imports, as data rather than text a caller has to scrape.
 *
 * This is the read-only twin of ordinals.c's renumbering walk: same decode
 * (mo_bind_observe, over the same LC_DYLD_INFO bind/weak-bind/lazy-bind
 * streams mo_map_apply renumbers), pointed at reporting instead of
 * rewriting. Two later consumers need exactly this list -- a flat-namespace
 * shim, which needs to know which symbols to stub, and a bind-stream editor,
 * whose selector list this output IS -- so the shape is a machine-readable
 * row per bind, not another --verbose printf.
 *
 * Scope: 64-bit Mach-O only, same as image.h; a fat container is walked one
 * 64-bit slice at a time. LC_DYLD_CHAINED_FIXUPS is refused outright (its
 * import table is not a bind-opcode stream this walk reads) rather than
 * guessed at, the same stance mo_map_apply takes.
 */

#ifndef MACHOREWRITE_IMPORTS_H
#define MACHOREWRITE_IMPORTS_H

#include <stdint.h>
#include <stddef.h>

/* MIMP_OK: a successful report, whether it holds any rows or not -- an
 * image with no bind stream at all is NOT a refusal, it is a report of
 * ZERO rows. MIMP_REFUSED: `buf` is not a readable 64-bit Mach-O (thin or
 * fat), or some slice it examined uses LC_DYLD_CHAINED_FIXUPS. One negative
 * code covers both, same as MI_NOT_MACHO/MFAT_MALFORMED's callers already
 * collapse "examined and declined" to a single value; the two reasons are
 * told apart only by the message this module prints to stderr, exactly as
 * mo_map_apply's own refusals are. */
#define MIMP_OK        0
#define MIMP_REFUSED (-1)

/* One (dylib, symbol) row. `arch` is "-" for a thin image, else the slice's
 * lipo-style name (src/arch_names.h) or "cputype 0x..." for one that table
 * does not know. `ordinal` is >= 1 for a real library ordinal, or one of
 * ordinals.h's MO_ORD_* values for a special bind (self/exe/flat/unknown).
 * `kind`/`install_name` are "-" for a special ordinal, or when a real
 * ordinal names no load command this slice actually declared (a malformed
 * stream, reported rather than resolved). `symbol` is "-" if no
 * SET_SYMBOL_TRAILING_FLAGS_IMM has been seen yet in this bind (malformed,
 * but reported, not refused). Every pointer here is owned by the walk that
 * produced it and is valid only for the duration of one mimp_row_fn call --
 * a callback that needs a row past its own call must copy it. */
typedef struct {
    const char *arch;
    int         ordinal;
    const char *kind;
    const char *install_name;
    const char *symbol;
    int         weak;
} mimp_row;

typedef void (*mimp_row_fn)(const mimp_row *row, void *ctx);

/* Report every bind opcode's (dylib, symbol) pair in `buf`/`size` -- a whole
 * file's bytes, thin or fat -- calling `fn` once per row, in the order each
 * stream (bind, then weak-bind, then lazy-bind) and slice (fat-arch-table
 * order) is walked. `buf` is const: this module never writes a byte of it,
 * the same property Task 5's mo_bind_observe establishes for the walk
 * underneath it.
 *
 * Every row `fn` sees is committed only after this call has already proven
 * the WHOLE input safe to report on -- no row is ever emitted for one slice
 * only to discover a later slice (or a later stream in the same slice)
 * forces a refusal, which would otherwise leak a partial report to a
 * caller expecting all-or-nothing the way MIMP_REFUSED's own contract
 * promises. Bounds (mo_fits, ordinals.h) are checked for every bind/
 * weak-bind/lazy-bind offset+size pair, and every slice is scanned for
 * LC_DYLD_CHAINED_FIXUPS, before any `fn` call for ANY slice -- so a
 * refusal always arrives with zero rows reported. The one exception a
 * streaming report cannot rule out is a bind OPCODE STREAM that is
 * well-formed by offset/size but corrupt in its own content (an unknown
 * opcode, an out-of-range ULEB ordinal, an unterminated symbol name) --
 * mo_bind_observe only discovers that while walking, so rows from an
 * earlier stream or slice in the same call may already have reached `fn`
 * when that happens. This is the same content-vs-bounds distinction
 * mo_map_apply's own comment draws; it has never been reachable through a
 * linker-built fixture, only a hand-corrupted one.
 *
 * A fat slice mi_wrap cannot read at all (not 64-bit, or malformed) is
 * SKIPPED, not fatal, matching fix_macho's/mr_process_fat's own "skip this
 * arch" convention -- one unreadable slice must not suppress the readable
 * ones. A slice that uses LC_DYLD_CHAINED_FIXUPS is a different case: it IS
 * a readable 64-bit Mach-O, this module simply does not speak its import
 * format, so -- again matching mr_process_fat's MR_ERROR handling -- it
 * refuses the WHOLE report rather than silently omitting that slice's
 * imports from an otherwise-successful one.
 *
 * Returns MIMP_OK or MIMP_REFUSED (see above); a refusal's reason is
 * printed to stderr, in this module's own words, before returning. */
int mimp_report(const uint8_t *buf, size_t size, mimp_row_fn fn, void *ctx);

#endif /* MACHOREWRITE_IMPORTS_H */
