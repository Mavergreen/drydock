#ifndef MACHOTOOL_REWRITE_H
#define MACHOTOOL_REWRITE_H
/* mr_ -- rewriting a Mach-O's dylib load commands and LC_RPATHs. Both
 * front-ends share this code: cli/machotool.c's dylib/rpath/lc/segment verbs
 * through mr_apply_file, src/edit.c's edit scripts through mr_apply_image.
 * Parsing stays in each front-end; what crosses this boundary is an mr_ops.
 * Every diagnostic lives here once, not re-emitted per caller: contract.
 * spec: tests/change_dylib_test.sh -- it captures stderr and compares it.
 * spec: tests/cli_test.sh's "machotool stands alone" -- the CLI links this in
 * rather than forking change_dylib, so change_dylib can wrap machotool.
 * spec: src/ordinals.h -- a dylib insert or delete shifts every later library
 * ordinal and this module renumbers; an rpath insert shifts none. */
#include <stdint.h>
#include <stddef.h>

#include "ordinals.h"

/* One dylib-path (or rpath) operation. new_path == NULL deletes the command
 * naming old_path; "" leaves the path alone; anything else rewrites it,
 * growing the command if the longer string needs it. `reexport` promotes
 * LC_LOAD_DYLIB to LC_REEXPORT_DYLIB (what "" is for), never an rpath. */
typedef struct {
    const char *old_path;
    const char *new_path;
    int reexport;                /* always 0 in mr_ops' rpath arrays */
} mr_change;

/* What a rewrite's ordinal renumbering did, handed back so a front-end can
 * report it. Every field is copied from the one map and the one renumbering
 * the rewrite already made; nothing here is recomputed. */
typedef struct {
    int       done;                          /* 1 once the rest is filled in */
    int       n;                             /* ordinals the image had: 1..n */
    int       inserted;                      /* new LC_LOAD_DYLIBs took 1..it */
    int       old_to_new[MO_MAX_DYLIBS + 1]; /* mo_map's: 0 = deleted */
    uint32_t  old_cmd[MO_MAX_DYLIBS + 1];    /* the kind at each old ordinal */
    mo_counts counts;                        /* what mo_map_apply changed */
} mr_renumbering;

/* Everything one run of the rewriter is being asked to do. Each array is
 * caller-owned and read-only for the call; a count of 0 means the operation
 * was not requested and its pointer is never dereferenced. Array order is
 * the order the operations were given, and observable: inserted dylibs
 * become ordinals 1..n in it, and for LC_RPATHs it is dyld's SEARCH order. */
typedef struct {
    const mr_change *dylib_changes;    /* rewrite/delete/reexport a dependency */
    int              n_dylib_changes;
    const char *const *dylib_appends;  /* brand-new LC_LOAD_DYLIB, placed last */
    int              n_dylib_appends;
    const char *const *dylib_inserts;  /* brand-new LC_LOAD_DYLIB, placed first */
    int              n_dylib_inserts;
    const uint32_t  *strip_cmds;       /* whole load commands to drop, by LC_* */
    int              n_strip_cmds;
    const mr_change *rpath_changes;    /* rewrite/delete an LC_RPATH */
    int              n_rpath_changes;
    const char *const *rpath_appends;  /* brand-new LC_RPATH, searched LAST */
    int              n_rpath_appends;
    const char *const *rpath_inserts;  /* brand-new LC_RPATH, searched FIRST */
    int              n_rpath_inserts;
    /* Rename every LC_SEGMENT_64 named segment_rename_old -- and each of its
     * sections' own copy of that name -- to segment_rename_new, through
     * mseg_rename_lc. Both NULL means no rename was requested. */
    const char      *segment_rename_old;
    const char      *segment_rename_new;
    /* OUT: if non-NULL, the rewriter ADDS the LC_SEGMENT_64s it renamed,
     * summed over a fat container's slices, and leaves it alone when refused.
     * spec: src/segname.h -- matching is strncmp over the 16-byte segname,
     * so only the code that matched can count the matches. */
    int             *segment_renamed;
    /* OUT, on the same terms: if the rewrite renumbered library ordinals,
     * *renumbering is OVERWRITTEN and its `done` set to 1, else left alone --
     * so zero it first and read `done`. Overwritten, not added to, since a map
     * does not sum: a fat file's later renumbering replaces the earlier. */
    mr_renumbering  *renumbering;
    /* If non-zero, mr_apply_file refuses (MR_REFUSED) when any
     * dylib_changes/rpath_changes/strip_cmds entry matched nothing, and
     * NOTHING IS WRITTEN: the verdict is decided before the one
     * wa_write_new. It asks whether anything MATCHED an operation, never
     * whether it ACTED, so a shadowed operation stays silent.
     * spec: src/rewrite.c's mr_build_lcs_lc "No break" -- counting only what
     * acted reports `-replace X N -delete X`'s -delete as a miss.
     * spec: the layout tripwire by mr_is_rename_only in src/rewrite.c --
     * declared BEFORE allow_grow so allow_grow stays the LAST field. */
    int              fatal_unmatched;
    int              allow_grow;       /* may enlarge the pad (mg_grow_header) */
} mr_ops;

/* How many times one operation may repeat in a run. compat/translate.sh's
 * mt_room repeats both numbers as literals -- a /bin/sh script cannot include
 * this header -- and refuses at the identical count. NOT a cap on an edit
 * script: src/edit.c lowers each statement to a one-operation mr_ops. */
#define MR_MAX_OPS   32
#define MR_MAX_STRIP 16

/* The two failure codes. MR_REFUSED is a CONSIDERED refusal: something
 * examined the bytes and declined. MR_FAIL is operational -- open, fstat,
 * read or write failing, or a checked allocation: mr_apply_file's fat-path
 * read buffer, mi_open's and mfat_parse's for the file and arch table, and
 * mfat_rewrite's for a fat split's arrays, copies and reassembly buffer. An
 * allocation failure inside mg_grow_header or mg_plausible is deliberately
 * MR_REFUSED instead, grow.c folding it in with its other refusals.
 * spec: cli/machotool.c's EX_REFUSED -- why a refusal is the LOWER code, and
 * where equality with these two is enforced at compile time. */
#define MR_REFUSED 1
#define MR_FAIL    2

/* Apply `ops` to the Mach-O at `path` and write the result as the NEW file
 * `out`. `path` is opened O_RDONLY and never written. Returns 0, else
 * MR_REFUSED or MR_FAIL -- this function's own, or a primitive's: mi_open,
 * mfat_parse, mg_first_sect_off, mo_map_build, mr_build_lcs, mg_grow_header,
 * mo_map_validate, mo_map_apply, mg_plausible.
 * spec: tests/cli_test.sh's "pinning the MR_REFUSED/MR_FAIL split" -- both
 * sides of that line, and both of the two size refusals.
 * PRECONDITION, unenforced here: `out` must not name `path`. cli/machotool.c
 * refuses it before any read, and wa_write_new checks again, so an unchecked
 * caller gets MR_FAIL and an unwritten input, not a rewritten one.
 * spec: cli/machotool.c's dylib/rpath and lc parsers -- PRECONDITION,
 * unenforced here AND undiagnosed: n_dylib_changes and n_rpath_changes each
 * <= MR_MAX_OPS, n_strip_cmds <= MR_MAX_STRIP. The hit-count arrays are on
 * this function's stack, sized from those macros; a caller that skips the
 * bound overflows that stack instead of getting a diagnostic. */
int mr_apply_file(const char *path, const char *out, const mr_ops *ops);

/* How many load commands each entry of an mr_ops' dylib_changes,
 * rpath_changes and strip_cmds matched, index for index. ADDED to, never
 * assigned: a fat file's slices each add to one total, an operation that
 * matched in one slice and not another having matched. So zero an mr_hits
 * once per image, not between slices. */
typedef struct {
    int dylib[MR_MAX_OPS];
    int rpath[MR_MAX_OPS];
    int strip[MR_MAX_STRIP];
} mr_hits;

/* mr_apply_file's thin-image step, without the file: apply `ops` to the thin
 * 64-bit Mach-O already in memory at *pbuf (*pfsize bytes), and write
 * nothing. *pbuf may be realloc'd (allow_grow reaches mg_grow_header), so on
 * return, success or not, *pbuf and *pfsize name the buffer the caller owns
 * and must free() -- its contents after a failure unspecified, so a caller
 * that sees a refusal must discard it, never write it. Prints what
 * mr_apply_file's thin path does bar its "Wrote OUT" line, with `label` for
 * the path, but neither reports what matched nothing nor acts on
 * ops->fatal_unmatched: counts are ADDED to `hits`, and mr_unmatched_verdict
 * does both, later. Returns 0 (with *out_modified) or MR_REFUSED, never
 * MR_FAIL, there being no I/O here. Its two new_lcs callocs are not checked at
 * all. Same array bound as mr_apply_file's. */
int mr_apply_image(uint8_t **pbuf, size_t *pfsize, const char *label,
                   const mr_ops *ops, int *out_modified, mr_hits *hits);

/* After a SUCCESSFUL rewrite -- only then, a refused one having possibly
 * stopped before a single comparison ran -- report on stderr every
 * dylib_changes/rpath_changes/strip_cmds entry `hits` says matched nothing,
 * and return MR_REFUSED if any did and ops->fatal_unmatched is set, else 0. */
int mr_unmatched_verdict(const mr_ops *ops, const mr_hits *hits);

#endif /* MACHOTOOL_REWRITE_H */
