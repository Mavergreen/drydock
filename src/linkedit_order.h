#ifndef DRYDOCK_LINKEDIT_ORDER_H
#define DRYDOCK_LINKEDIT_ORDER_H
/*
 * mlo_ -- whether 10.9's codesign_allocate (cctools-862) can re-sign an
 * image, and whether it would re-sign it correctly; and the pass that puts
 * __LINKEDIT in the order it wants.
 *
 * mlo_check mirrors codesign_allocate's own checks (libstuff/ofile.c's load
 * command loop, libstuff/checkout.c's check_object, dyld_order and
 * symbol_string_at_end, misc/codesign_allocate.c's header room) and
 * simulates its writer (setup_code_signature, libstuff/writeout.c's
 * copy_new_symbol_info), which never updates an offset in a load command and
 * so must put every piece back exactly where it was. It evaluates every rule
 * and records every finding. It reads the image and allocates nothing.
 */
#include <stddef.h>
#include <stdint.h>

#include "image.h"

/* A finding's kind. */
enum {
    MLO_REFUSES = 1,   /* codesign_allocate refuses the image with `text` */
    MLO_CORRUPTS,      /* its writer would put a piece somewhere else */
    MLO_NOTE           /* neither, but worth saying (see mlo_check) */
};

#define MLO_MAX 32

typedef struct {
    int  kind;
    int  newer;        /* MLO_REFUSES only: a newer codesign_allocate may not
                        * refuse it (an unknown load command, header room) */
    int  order;        /* MLO_REFUSES only: a rule about where the pieces
                        * lie (dyld_order, symbol_string_at_end) */
    char text[200];    /* codesign_allocate's own words, where it has any; a
                        * "…" stands for words that name offsets or files */
} mlo_finding;

typedef struct {
    int         n;          /* findings kept, in the tool's order */
    int         dropped;    /* findings past MLO_MAX, counted only */
    mlo_finding f[MLO_MAX];
    int         refusal;    /* index of the first MLO_REFUSES finding, or -1 */
    int         corrupting; /* every MLO_REFUSES finding is `newer`, and the
                             * writer would move a piece */
} mlo_verdict;

/* Checks `im`, a 64-bit slice, into *v. */
void mlo_check(const mi_image *im, mlo_verdict *v);

#endif /* DRYDOCK_LINKEDIT_ORDER_H */
