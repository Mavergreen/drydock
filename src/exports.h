/* exports.h -- report every symbol a 64-bit Mach-O image exports, as data.
 *
 * The read-only twin of src/imports.h, for the other side of a bind: what a
 * library DEFINES. Read from the export trie -- LC_DYLD_INFO(_ONLY)'s, or
 * LC_DYLD_EXPORTS_TRIE's -- which is what dyld itself resolves a two-level
 * import against. An image with no export trie at all (one linked before
 * LC_DYLD_INFO existed) is read from its symbol table instead: every external
 * symbol that is not undefined. Each row says which source it came from.
 *
 * Scope and refusals follow imports.h: 64-bit only, a fat container slice by
 * slice (a slice mi_wrap cannot read is skipped), every row committed only
 * after every slice has been read, and a symbol carrying a TAB or NEWLINE
 * refuses the whole report rather than corrupt a TSV row.
 */
#ifndef DRYDOCK_EXPORTS_H
#define DRYDOCK_EXPORTS_H

#include <stddef.h>
#include <stdint.h>

#define MEXP_OK        0
#define MEXP_REFUSED (-1)

/* `arch` as in imports.h. `kind` is regular, thread-local, absolute, reexport
 * or stub-resolver; `weak` is 1 for a weak definition; `source` is "trie" or
 * "symtab". Every pointer is valid only for the duration of one call. */
typedef struct {
    const char *arch;
    const char *symbol;
    const char *kind;
    int         weak;
    const char *source;
} mexp_row;

typedef void (*mexp_row_fn)(const mexp_row *row, void *ctx);

int mexp_report(const uint8_t *buf, size_t size, mexp_row_fn fn, void *ctx);

#endif
