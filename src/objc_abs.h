#ifndef DRYDOCK_OBJC_ABS_H
#define DRYDOCK_OBJC_ABS_H
/*
 * mma_ -- `objc-methods set absolute`: every relative Objective-C method list
 * objc_meth.h's walk reaches becomes an absolute list, appended past the end
 * of D, the segment just before __LINKEDIT, and every slot that named it is
 * repointed. D grows, __LINKEDIT moves up behind it, and no load command is
 * added, so the header pad is never touched.
 */
#include <stddef.h>
#include <stdint.h>

#include "image.h"
#include "objc_meth.h"

#define MMA_OK        0
#define MMA_NOTHING   1
#define MMA_REFUSED (-1)
#define MMA_NOMEM   (-2)

#define MMA_PAGE 0x1000u

typedef struct {
    char     name[16];
    uint64_t vmaddr, vmsize, fileoff, filesize;
    uint32_t initprot;
} mma_seg;

typedef struct {
    int      d, l;         /* segment indices of D and __LINKEDIT */
    char     dname[16];    /* D's segname, not NUL-terminated at 16 */
    uint64_t list_va;      /* D's vm end: the converted lists start here */
    uint64_t insert;       /* __LINKEDIT's file offset: new bytes go in here */
    uint64_t z;            /* D's zero fill, which becomes file bytes */
} mma_layout;

/* The image's LC_SEGMENT_64s in load-command order: their count, or -1 when
 * there are more than `max`, which is MML_MAX_SEGS for mma_layout_check. */
int mma_segments(const mi_image *im, mma_seg *segs, int max);

/* Where the lists can go in an image of `file_size` bytes with these
 * segments, or MMA_REFUSED with why set: __LINKEDIT must be the last segment
 * and end the file; D must be segment 15 or lower, writable, end where
 * __LINKEDIT begins in vm and in file, have under 4GB of zero fill, and end
 * on a page boundary once that zero fill is in the file; no other segment
 * may reach above __LINKEDIT's start in vm. */
int mma_layout_check(const mma_seg *segs, int n, uint64_t file_size, mma_layout *lay,
                     char *why, size_t whysz);

/* A new image, in *out (malloc'd) of *outsz bytes: `im` with its zero fill
 * made file bytes, `lists_len` bytes of `lists` then zeros to `s` (a whole
 * number of pages) past D's end, and `r` bytes of `stream` (a multiple of
 * 16, so every moved offset keeps its alignment) at the start of __LINKEDIT,
 * which moves up by s in vm and by z + s in file.
 * D's vmsize grows by s and its filesize becomes its vmsize; __LINKEDIT's
 * filesize grows by r and its vmsize grows to cover it; every other file
 * offset at or past the insertion moves by z + s + r; rebase_off and
 * rebase_size name the new stream and the old one is zeroed. Refused: more
 * than one LC_DYLD_INFO[_ONLY], an LC_NOTE or LC_ATOM_INFO (offsets this does
 * not move), a rebase stream outside __LINKEDIT or the file, and a result
 * past 4GB. `im` is only read. MMA_OK, MMA_REFUSED or MMA_NOMEM, with why
 * set. */
int mma_insert(const mi_image *im, const mma_layout *lay, const uint8_t *lists,
               uint64_t lists_len, uint64_t s, const uint8_t *stream, uint32_t r,
               uint8_t **out, size_t *outsz, char *why, size_t whysz);

/* What a conversion did, in the figures it had in hand while doing it. */
typedef struct {
    uint32_t lists, methods;            /* relative lists converted, and their entries */
    uint32_t owners[MML_NOWNERS];       /* those lists, by the record of the first slot naming each */
    uint32_t rebases;                   /* rebases added */
    char     dname[16];                 /* D's segname, not NUL-terminated at 16 */
    uint64_t grew, zerofill;            /* D grew by `grew` in vm, and `zerofill` more in file */
    uint64_t linkedit_before, linkedit_after;   /* __LINKEDIT's filesize */
} mma_report;

typedef struct {
    uint8_t   *buf;     /* the converted image, malloc'd; NULL unless MMA_OK */
    size_t     size;
    mma_layout lay;
    uint64_t   s;       /* the converted lists' room, a whole number of pages */
    uint32_t   r;       /* the new rebase stream's size, a multiple of 16 */
    mma_report rep;
} mma_out;

/* The room the converted lists take: for each ref i that is the first to
 * name a relative list (first[i] == i), new_va[i] = list_va plus that list's
 * offset among them; in *total their bytes, in *nslots the most rebases they
 * need. MMA_REFUSED with why set when the lists would pass 4GB. */
int  mma_room(const mml_walk *w, const uint32_t *first, uint64_t list_va, uint64_t *new_va,
              uint64_t *total, size_t *nslots, char *why, size_t whysz);

/* Converts `im`, which is only read, into o->buf: MMA_OK; MMA_NOTHING when
 * the walk finds no relative list; MMA_REFUSED or MMA_NOMEM with why set.
 * Refuses an image that is not x86_64, has chained fixups, has no
 * LC_DYLD_INFO or more than one, has a rebase stream outside the file, fails
 * the walk or the layout, has a method-list slot or an absolute list in
 * __LINKEDIT, has a slot without a pointer rebase, needs lists past 4GB, or
 * has an entry mml_entry_at will not resolve. The new
 * lists keep their entries' order; each carries one rebase per pointer that
 * is not 0. */
int  mma_build(const mi_image *im, mma_out *o, char *why, size_t whysz);
void mma_out_free(mma_out *o);

/* Checks o->buf against `in`, the image it was built from, and against
 * nothing mma_build computed but o->lay, o->s and o->r: the output is
 * z + s + r bytes longer and the layout names its segments; the output's walk
 * finds no relative list, the same slots grouped the same way, and in each
 * converted list the same entries in the same order; its rebases are the
 * input's, each of its type, plus exactly one POINTER rebase per new pointer
 * that is not 0, and no input rebase names D past its end or __LINKEDIT; its
 * load commands differ only in D's and __LINKEDIT's geometry and the
 * __LINKEDIT offsets, each by exactly what the layout says; every byte
 * outside the new lists and stream is the input's, moved or not, but for the
 * repointed slots, the zero fill and the zeroed old rebase stream; no
 * segments overlap.
 * MMA_OK, or MMA_REFUSED / MMA_NOMEM with why set. */
int  mma_verify(const mi_image *in, const mma_out *o, char *why, size_t whysz);

/* The statement: mma_build, then mma_verify, then the image is replaced.
 * 0 with *rep filled (rep->lists == 0 when there was nothing to convert), or
 * MR_REFUSED / MR_FAIL (src/rewrite.h) with the reason on stderr. *pbuf and
 * *psize name the image afterwards either way; on a non-zero return it is
 * the image as it was. */
int  mma_convert(uint8_t **pbuf, size_t *psize, mma_report *rep);

#endif
