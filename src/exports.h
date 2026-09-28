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

/* One terminal of an export trie: the name that reaches it (name_len bytes,
 * not NUL-terminated; NULL when empty), its flags, and the rest of its
 * terminal, [info, info_end), undecoded. Valid for the duration of one call. */
typedef struct {
    const char *name;
    size_t name_len;
    uint64_t flags;
    const uint8_t *info, *info_end;
} mexp_terminal;

typedef int (*mexp_terminal_fn)(const mexp_terminal *t, void *ctx);

/* Walks the export trie t[0, size) depth first, in edge order, calling `fn`
 * at each terminal. The reader mexp_report uses. MEXP_WALK_DONE once every
 * node is read; MEXP_WALK_STOPPED as soon as `fn` returns nonzero;
 * MEXP_WALK_MALFORMED with *why saying how; MEXP_WALK_OOM. */
#define MEXP_WALK_DONE        0
#define MEXP_WALK_STOPPED     1
#define MEXP_WALK_MALFORMED (-1)
#define MEXP_WALK_OOM       (-2)
int mexp_trie_walk(const uint8_t *t, uint32_t size, mexp_terminal_fn fn, void *ctx,
                   const char **why);

#endif
