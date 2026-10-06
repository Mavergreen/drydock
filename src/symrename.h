/* symrename.h -- rename symbols in one relocatable object's bytes. */

#ifndef DRYDOCK_SYMRENAME_H
#define DRYDOCK_SYMRENAME_H

#include <stdint.h>
#include <stddef.h>

enum { MSR_OK = 0, MSR_UNMATCHED, MSR_SAME, MSR_EXISTS, MSR_STRTAB_NOT_LAST, MSR_MALFORMED };

/* msr_rename returns -1 if it cannot allocate; the buffer is then unchanged. */
#define MSR_NOMEM (-1)

typedef struct { unsigned entries; } msr_report;

/* buf holds one thin 64-bit Mach-O of filetype MH_OBJECT; may be realloc'd.
 * Every nlist_64 entry named `old` is pointed at a copy of `new_` appended to
 * the string table. On any nonzero return the buffer is unchanged.
 * MSR_STRTAB_NOT_LAST: a load command records file bytes past the string
 * table, or more than 7 bytes, or any nonzero byte, follow it. */
int msr_rename(uint8_t **pbuf, size_t *psize, const char *old, const char *new_, msr_report *r);

const char *msr_reason(int rc);

/* 1 if any nlist_64 entry is named `name`; 0 otherwise (also with no LC_SYMTAB). */
int msr_has(const uint8_t *buf, size_t size, const char *name);

/* Calls fn for each defined external symbol (N_EXT set, N_TYPE != N_UNDF, not
 * common, not a stab). Returns 0 when every symbol was visited, fn's nonzero
 * result if it stopped the walk, or -1 if the symbol table is malformed. */
int msr_each_defined_external(const uint8_t *buf, size_t size,
                              int (*fn)(const char *name, void *ctx), void *ctx);

#endif
