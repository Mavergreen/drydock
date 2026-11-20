/* vnodeop.h -- retarget a kext's vnode-op entries from one descriptor to another. */

#ifndef DRYDOCK_VNODEOP_H
#define DRYDOCK_VNODEOP_H

#include <stdint.h>
#include <stddef.h>

enum { MVN_OK = 0, MVN_UNMATCHED, MVN_NOT_X86_64_KEXT, MVN_NOT_ONE_SYMBOL, MVN_NOT_UNDEFINED,
       MVN_UNREFERENCED, MVN_BAD_RELOC, MVN_NOT_IN_TABLE, MVN_NO_TERMINATOR, MVN_NEW_COUNT,
       MVN_IMPL_MISMATCH, MVN_STRAY_REFERENCE, MVN_DYSYMTAB_SHAPE, MVN_UNDEF_NOT_LAST,
       MVN_EXTERN_LOCAL_RELOC, MVN_VERIFY, MVN_MALFORMED };

/* mvn_replace returns -1 if it cannot allocate; the buffer is then unchanged. */
#define MVN_NOMEM (-1)

typedef struct { unsigned entries; unsigned removed_index; unsigned renumbered; } mvn_report;

/* buf: one thin 64-bit Mach-O. Every vnode-op entry {&old, old_impl} becomes a
 * copy of its table's {&new_, new_impl} entry, and the undefined symbol `old`
 * is removed. Rewrites in place; size never changes. On any nonzero return
 * the buffer is unchanged. */
int mvn_replace(uint8_t *buf, size_t size, const char *old, const char *new_, mvn_report *r);

/* One line, saying OLD and NEW where names go, as msr_reason does. */
const char *mvn_reason(int rc);

/* 1 if buf is a thin 64-bit MH_KEXT_BUNDLE for x86_64; 0 otherwise. */
int mvn_is_x86_64_kext(const uint8_t *buf, size_t size);

#endif
