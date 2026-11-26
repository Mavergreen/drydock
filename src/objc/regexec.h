#ifndef DRYDOCK_OBJC_REGEXEC_H
#define DRYDOCK_OBJC_REGEXEC_H
/* regexec.h -- the registration executor: a provider's class_addMethod calls, derived from its code
 * (regexec.c states the contract). */
#include "report.h"
#include <stddef.h>
#include <stdint.h>

/* A lookup that returned found. A NULL cls or sel is one the executor could not name: it may be any. */
typedef struct { char *cls; int meta; char *sel; } ObjcRegLookup;
/* One class_addMethod call. NULL fields are values the executor could not name. imp_va: the IMP's address, 0 when
 * not a known address (imp is the image's symbol there, NULL in a stripped image). ok: the fork this path took
 * (1 the add succeeded, 0 it failed): a failure fork exists only where the path read the result; an add whose result
 * no instruction read has no failed twin (it would be identical, and provider.c exempts it). site: the call
 * instruction. */
typedef struct { char *cls; int meta; char *sel, *imp, *types; uint64_t imp_va, site; int ok; } ObjcRegAdd;
/* class_null: objc_getClass returned NULL on it; null_classes: for which literals (a NULL entry: one not named). trapped: it ended at int3 or ud2. unknown_forks: the branches,
 * setcc and cmov along it whose flags the executor did not know, each decided by forking (the path may be
 * infeasible when nonzero). table_forks: those, apart, whose flags derive from an own-stores run's class table (regexec.c's
 * "Start"), which a later call of the root may hold otherwise. */
typedef struct { ObjcRegLookup *found; size_t n_found; ObjcRegAdd *adds; size_t n_adds;
                 int class_null, trapped; size_t unknown_forks, table_forks; char **null_classes; size_t n_null_classes; } ObjcRegPath;
typedef struct { size_t max_paths, max_depth, max_insns; } ObjcRegBudget;
#define OBJC_REG_MAX_PATHS ((size_t)1 << 14)
#define OBJC_REG_MAX_DEPTH ((size_t)16)
#define OBJC_REG_MAX_INSNS ((size_t)1 << 22)
typedef struct {
    ObjcRegPath *paths; size_t n_paths;          /* every completed path, in exploration order */
    uint64_t *mutator_sites; size_t n_sites;      /* call sites of the spec's mutator list on explored paths, ascending */
    /* Each sel_registerName call site on explored paths: all_literal 1 when every arrival's argument was a C string
     * read from the image's initial bytes, 0 when any was not. Ascending, distinct. */
    struct { uint64_t site; int all_literal; } *selreg; size_t n_selreg;
    uint64_t *called; size_t n_called;            /* targets in the ranges of calls and tail jumps on explored paths,
                                                   * followed or summarised; ascending, distinct */
    /* [lo, hi) pairs, ascending, distinct: each a function (bounded by LC_FUNCTION_STARTS and by the given range
     * holding it) where some explored path executed an instruction. A summarised callee is in none. */
    uint64_t *explored; size_t n_explored;
    uint64_t *executed; size_t n_executed;        /* every instruction an explored path executed; ascending, distinct */
    /* Escapes of a value derived from writable image data or a tracked address (regexec.c's provenance): va, the
     * address it was derived from; site, the instruction; how: OBJC_ESC_CALL (at a call not followed), OBJC_ESC_STORE (stored outside the
     * frame), OBJC_ESC_RETURN (returned from the entry or a function it called). Sorted, distinct. */
    struct { uint64_t va, site; int how; } *escaped; size_t n_escaped;
    /* Image data read as initial values: [va, va+len) by the instruction at site (a load), or by the call at site
     * (a runtime model reading the C string at va, e.g. sel_registerName's literal: how 1). Sorted, distinct. */
    struct { uint64_t va, len, site; int how; } *const_reads; size_t n_reads;
    /* Stores into writable image data on explored paths, by the instruction at site. Sorted, distinct. */
    struct { uint64_t va, len, site; } *image_stores; size_t n_stores;
    int refused; char code[64], why[512];         /* set: nothing above may be trusted */
} ObjcRegResult;

/* Refusal codes: unsupported-instruction, indirect-call, foreign-call, unknown-store, image-store, path-budget,
 * depth-budget, insn-budget, unverified-pointer. b NULL: the defaults above. ranges: n_ranges [lo, hi) pairs
 * of provider code. 0 explored, 1 refused (out->refused, code, why); out is always filled for objc_reg_free. */
int objc_derive_registration(const ObjcImage *im, uint64_t entry, const uint64_t *ranges, size_t n_ranges,
                             const ObjcRegBudget *b, ObjcRegResult *out);
/* Where and how a run starts (regexec.c's "Start"): entry; arg0_class, when not NULL, the class rdi holds; tracked,
 * n_tracked addresses followed as writable data is; own_stores, image stores held to the class into
 * [table_lo, table_hi). objc_derive_registration is this with only entry set. */
typedef struct { uint64_t entry; const char *arg0_class; const uint64_t *tracked; size_t n_tracked;
                 int own_stores; uint64_t table_lo, table_hi; } ObjcRegStart;
int objc_derive_registration_from(const ObjcImage *im, const ObjcRegStart *start, const uint64_t *ranges,
                                  size_t n_ranges, const ObjcRegBudget *b, ObjcRegResult *out);
void objc_reg_free(ObjcRegResult *r);
/* 1 when import (with or without its leading underscore) is one of the spec's mutators, which mutator_sites lists. */
enum { OBJC_ESC_CALL, OBJC_ESC_STORE, OBJC_ESC_RETURN };
int objc_reg_mutator(const char *import);

#endif
