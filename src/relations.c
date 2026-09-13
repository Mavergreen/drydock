#include "relations.h"

#include "linkedit.h"
#include "ordinals.h"

#include <mach-o/loader.h>
#include <stddef.h>

/* mrel_live's mi_each_lc callback. Accumulates every bit this walk can find;
 * MREL_HEADER_PAD and MREL_BASE_REL are not walk-dependent and are set by the
 * caller instead (see mrel_live below). */
static int mrel_live_cb(const struct load_command *lc, void *ctx) {
    unsigned *mask = (unsigned *)ctx;

    /* spec: src/ordinals.h's mo_is_ordinal_lc -- the one place "does this
     * load command carry a library ordinal" is decided, so this walk and
     * mo_map_build's cannot independently drift on which commands count. */
    if (mo_is_ordinal_lc(lc->cmd)) *mask |= MREL_ORDINAL;

    if (lc->cmd == LC_FUNCTION_STARTS) {
        const struct linkedit_data_command *d = (const struct linkedit_data_command *)lc;
        if (d->datasize != 0) *mask |= MREL_FUNC_START;
    }

    switch (lc->cmd) {
    /* Case labels generated from linkedit.h's ML_PLAIN_OFFSET_LCS -- the
     * same list src/grow.c's accept bucket and src/linkedit.c's bump switch
     * already build their labels from, so this can't independently name a
     * different set of "lives in __LINKEDIT" commands than either of those. */
#define MREL_FILE_OFF_CASE(cmd) case cmd:
    ML_PLAIN_OFFSET_LCS(MREL_FILE_OFF_CASE)
#undef MREL_FILE_OFF_CASE
        *mask |= MREL_FILE_OFF;
        break;
    default:
        break;
    }

    return 0;
}

unsigned mrel_live(const mi_image *im) {
    unsigned mask = MREL_HEADER_PAD;   /* every image has a sizeofcmds */

    mi_each_lc(im, mrel_live_cb, &mask);

    /* spec: src/image.h's mi_image_base -- NOT mi_text_base, whose 0 return
     * is ambiguous between "no segment maps the header" and "the base
     * legitimately IS 0" (every dylib). mi_image_base tells the two apart;
     * reading the ambiguous one is the bug that made mg_plausible refuse
     * every dylib on the machine. */
    uint64_t base;
    if (mi_image_base(im, &base) == 0) mask |= MREL_BASE_REL;

    return mask;
}

const char *mrel_name(unsigned bit) {
    switch (bit) {
    case MREL_ORDINAL:    return "library ordinal";
    case MREL_BASE_REL:   return "base-relative values";
    case MREL_FILE_OFF:   return "file-offset fields";
    case MREL_FUNC_START: return "initializer and unwind targets";
    case MREL_HEADER_PAD: return "sizeofcmds";
    default:              return NULL;
    }
}

int mrel_verify_applies(const mi_image *im, unsigned disturbed) {
    return (mrel_live(im) & MREL_FUNC_START) != 0 &&
           (disturbed & MREL_BASE_REL) != 0;
}
