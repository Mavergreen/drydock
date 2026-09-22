#ifndef DRYDOCK_REDIRECT_H
#define DRYDOCK_REDIRECT_H
/*
 * mrd_ -- `import redirect SYMBOL FROM-LIB TO-LIB`: every bind of SYMBOL that
 * names FROM-LIB, in the bind and lazy-bind streams and the symbol table, is
 * made to name TO-LIB instead. Nothing else changes. The design is
 * Wowfunhappy's bake-mavericks-shim.py; spec: compat/README.md
 * "bake-mavericks-shim".
 *
 * One 64-bit slice at a time, in memory, like the other cores src/edit.c
 * lowers statements to.
 *
 *   - The LAZY stream is patched in place: each lazy program is addressed by
 *     its offset from __stub_helper, so none may move. The ordinal opcode is
 *     re-encoded in its own width, and a redirect it cannot hold is refused,
 *     as is one whose opcode also serves a bind that stays.
 *   - The BIND stream is rewritten opcode for opcode: an ordinal opcode that
 *     serves only redirected binds is replaced, and a redirected bind that
 *     shares one gets its own ordinal before it and the old one restored after.
 *     It stays in place when that fits; when it does not, it moves to the end
 *     of __LINKEDIT, which grows to cover it -- the same room
 *     `fixups set classic` appends into.
 *   - The WEAK-bind stream is left alone: it names no library. A weak bind of
 *     SYMBOL is counted and reported.
 *
 * Before it hands the image back it walks both streams again and requires
 * every redirected bind to name TO-LIB and every other bind to be what it was;
 * any difference refuses.
 */
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int      from, to;
    long     bind, lazy, nlist, weak;
    uint32_t bind_before, bind_after, bind_off_before, bind_off_after;
    uint64_t linkedit_before, linkedit_after;
} mrd_report;

/* Returns 0 with *rep filled -- rep->bind + rep->lazy == 0 when nothing in
 * this slice matched, which is not a refusal -- or MR_REFUSED / MR_FAIL
 * (src/rewrite.h) with the reason on stderr. *pbuf and *psize name the image
 * afterwards either way; on a refusal it is the image as it was. */
int mrd_redirect(uint8_t **pbuf, size_t *psize, const char *symbol,
                 const char *from, const char *to, mrd_report *rep);

#endif
