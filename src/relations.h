/* relations.h -- what points at what, and when a check has anything to check.
 *
 * Several places in this toolkit answer some version of "is this offset (or
 * ordinal, or base) still correct". Each has, until now, hand-rolled its own
 * applicability condition for when that question is even worth asking on a
 * given image -- the base-of-zero bug that made mg_plausible refuse every
 * dylib was exactly one of those hand-rolled conditions getting it wrong.
 * This module names the handful of things a rewrite can point stale
 * references at, so "is X live in this image" and "did this run disturb X"
 * have ONE place to be asked, not a new one per caller.
 *
 * A relation declares its REFERENT and its LIVENESS only. Nothing here
 * declares a check or a repair -- that would mean rewriting working repair
 * code to buy a uniformity nothing needs -- and no repair code moves here:
 * mo_map_apply still repairs ordinals, src/grow.c still re-bases and bumps
 * offsets, mr_build_lcs/mg_grow_header still repack the header pad. This
 * module only says what each of those already-working repairs is FOR, and
 * whether this image has one to be for.
 *
 * | relation                        | referent                     | repaired today by                      |
 * |----------------------------------|-------------------------------|-----------------------------------------|
 * | library ordinal                  | the ordinal-carrying LC       | mo_map_build/mo_map_apply               |
 * |                                   | subsequence                   | (src/ordinals.c)                        |
 * | base-relative values             | the image base                 | src/grow.c's re-base pass               |
 * | file-offset fields                | __LINKEDIT's blobs             | src/linkedit.h's list, src/grow.c's bump|
 * | initializer and unwind targets    | LC_FUNCTION_STARTS             | mg_plausible -- checked, never repaired |
 * | sizeofcmds                        | the header pad                 | mr_build_lcs, mg_grow_header            |
 */

#ifndef DRYDOCK_RELATIONS_H
#define DRYDOCK_RELATIONS_H

#include "image.h"

/* What is pointed AT. A bitmask so an operation can disturb several. */
enum {
    MREL_NONE       = 0,        /* spelled, never defaulted: see ms_disturbs */
    MREL_ORDINAL    = 1u << 0,  /* the ordinal-carrying LC subsequence */
    MREL_BASE_REL   = 1u << 1,  /* the image base */
    MREL_FILE_OFF   = 1u << 2,  /* __LINKEDIT's blobs */
    MREL_FUNC_START = 1u << 3,  /* LC_FUNCTION_STARTS */
    MREL_HEADER_PAD = 1u << 4   /* sizeofcmds, i.e. the first section's offset */
};

/* Which relations are LIVE in this image -- present and therefore checkable.
 * `im` is a SLICE: a fat container has no single answer, so a fat run derives
 * this once per slice, the same granularity me_statements and mg_plausible
 * already run at (src/edit.c:671, :676). */
unsigned mrel_live(const mi_image *im);

/* Human name for one bit, for diagnostics. NULL if `bit` names no relation. */
const char *mrel_name(unsigned bit);

/* Does mg_plausible have anything to check on THIS image after a run that
 * disturbed `disturbed`? The one expression both front-ends' gate sites use,
 * so there is no second copy to drift: the initializer-and-unwind relation
 * must be LIVE here (MREL_FUNC_START), and the run must have disturbed the
 * base-relative values those offsets are (MREL_BASE_REL). Nonzero means run
 * the gate.
 *
 * These are two DIFFERENT masks, not one. No
 * operation ever disturbs MREL_FUNC_START (mg_plausible only ever checks
 * LC_FUNCTION_STARTS, never rewrites it), so `disturbed & MREL_FUNC_START`
 * is permanently zero and a derivation built on it would switch this gate
 * off for every run while every suite stayed green. What must have been
 * disturbed is MREL_BASE_REL: base-relative movement is what invalidates the
 * function-start offsets the gate checks. */
int mrel_verify_applies(const mi_image *im, unsigned disturbed);

#endif /* DRYDOCK_RELATIONS_H */
