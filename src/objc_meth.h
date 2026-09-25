#ifndef DRYDOCK_OBJC_METH_H
#define DRYDOCK_OBJC_METH_H
/*
 * mml_ -- the Objective-C method lists an image's own classes, metaclasses,
 * categories and protocols name, found by the walk the 10.9 runtime makes,
 * on an image whose pointers are classic rather than chained.
 */
#include <stdint.h>

#include "image.h"

#define MML_RELATIVE    0x80000000u
#define MML_FLAG_MASK   0xFFFF0003u
#define MML_REL_ENTSIZE 12u
#define MML_ABS_ENTSIZE 24u

#define MML_OK          0
#define MML_CHAINED   (-1)
#define MML_MALFORMED (-2)
#define MML_NOMEM     (-3)

enum { MML_CLASS, MML_METACLASS, MML_CATEGORY, MML_PROTOCOL, MML_NOWNERS };

typedef struct {
    uint64_t slot_off;   /* file offset of the pointer that names the list */
    uint64_t list_va, list_off;
    uint32_t header, count;
    int      owner;
} mml_ref;

typedef struct {
    mml_ref *refs;
    uint32_t n, cap;
    uint32_t relative, absolute;     /* distinct lists, by address */
    uint32_t owners[MML_NOWNERS];    /* distinct records walked */
    char     why[160];
} mml_walk;

/* MML_OK, or MML_CHAINED / MML_MALFORMED / MML_NOMEM with w->why set,
 * w->refs NULL and every count zero. */
int  mml_walk_image(const mi_image *im, mml_walk *w);
void mml_walk_free(mml_walk *w);

#endif
