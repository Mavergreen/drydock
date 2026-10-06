/* archive.h -- read, rewrite and re-index BSD static archives (ar(5) as
 * Apple's libtool, ranlib and ar write them). */

#ifndef DRYDOCK_ARCHIVE_H
#define DRYDOCK_ARCHIVE_H

#include <stdint.h>
#include <stddef.h>

enum { MAR_IDX_NONE, MAR_IDX_32, MAR_IDX_32_SORTED, MAR_IDX_64, MAR_IDX_64_SORTED };

typedef struct {
    size_t hdr_off;              /* the 60-byte header */
    char name[256];              /* NUL-terminated; #1/N names resolved */
    size_t name_len_inline;      /* N for #1/N, else 0 */
    size_t data_off, data_size;  /* the member's own bytes, after any #1/N name */
    int is_index;                /* the __.SYMDEF* member */
} mar_member;

typedef struct { mar_member *m; size_t n; int index_kind; } mar_archive;

/* 0, MR_REFUSED (the reason, naming the offset, in `why`), or MR_FAIL if
 * it cannot allocate. On success free `a` with mar_free. */
int  mar_parse(const uint8_t *buf, size_t size, mar_archive *a, char *why, size_t whylen);
void mar_free(mar_archive *a);

/* Calls fn on a private copy of each non-index member's bytes (fn may
 * realloc and resize it), then lays out the new archive: members in order,
 * original headers but updated size fields, the input's padding convention,
 * and a rebuilt index of the input's kind. Returns 0, fn's nonzero code
 * unchanged, or MR_REFUSED/MR_FAIL with the reason in `why`; on any nonzero
 * return *pbuf and *psize are untouched. */
typedef int (*mar_member_fn)(uint8_t **pbuf, size_t *psize, const mar_member *m, void *ctx);
int mar_rewrite(uint8_t **pbuf, size_t *psize, mar_member_fn fn, void *ctx, char *why, size_t whylen);

#endif
