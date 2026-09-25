#ifndef DRYDOCK_OBJC_METH_H
#define DRYDOCK_OBJC_METH_H
/*
 * mml_ -- the Objective-C method lists an image's own classes, metaclasses,
 * categories and protocols name, found by the walk the 10.9 runtime makes,
 * on an image whose pointers are classic rather than chained.
 */
#include <stdint.h>

#include "image.h"
#include "rebase.h"

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

/* One method, as the 10.9 runtime reads an absolute entry: the selector's
 * name string, the type string and the implementation (0 for none), each an
 * unslid address in the image. */
typedef struct { uint64_t name, types, imp; } mml_entry;

#define MML_MAX_SEGS 64

typedef struct { uint64_t addr, size; uint32_t offset, flags; } mml_sect;

/* What resolving an entry consults, gathered once per image: the segments
 * in load-command order, every section, the rebase stream's slots and the
 * bind stream's (both sorted), and LC_FUNCTION_STARTS' addresses when the
 * image lists any. */
typedef struct {
    const mi_image *im;
    struct { uint64_t vmaddr, vmsize, fileoff, filesize; } segs[MML_MAX_SEGS];
    int       nsegs;
    mml_sect *sects;
    uint32_t  nsects;
    mrb_set   rebases, binds;
    uint64_t *starts;
    int       nstarts;       /* -1 when there is nothing to check an IMP against */
} mml_resolver;

/* MML_OK, or MML_MALFORMED / MML_NOMEM with why set and nothing to close.
 * An image with no LC_DYLD_INFO[_ONLY] opens with empty rebase and bind sets. */
int  mml_resolver_open(const mi_image *im, mml_resolver *r, char *why, size_t whysz);
void mml_resolver_close(mml_resolver *r);

/* Entry `i` of the list `ref` names; refused as MML_MALFORMED when `i` is
 * not less than `ref->count`. An absolute entry is read. A relative one is
 * resolved and checked: its selector reference is 8-byte aligned,
 * file-backed and rebased as a pointer (bound is checked before rebased, so
 * a selref both bound and rebased still refuses as bound), and holds the
 * address of a string NUL-terminated within an S_CSTRING_LITERALS section;
 * its types are such a string; its IMP is 0, or a nonzero address (never
 * one that resolves to exactly 0) lying in a section of instructions and,
 * when the image lists function starts, is one. MML_OK, or MML_MALFORMED
 * with why set. */
int  mml_entry_at(const mml_resolver *r, const mml_ref *ref, uint32_t i, mml_entry *e,
                  char *why, size_t whysz);

/* The segment whose file bytes hold [va, va + len), or -1. */
int  mml_seg_of(const mml_resolver *r, uint64_t va, uint64_t len);

/* 1 when the 8 bytes at file offset `off` carry a rebase, of any type. */
int  mml_off_rebased(const mml_resolver *r, uint64_t off);

#endif
