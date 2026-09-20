#ifndef MACHOREWRITE_REWRITE_H
#define MACHOREWRITE_REWRITE_H
/* mr_ -- rewriting a Mach-O's dylib load commands and LC_RPATHs. Both
 * front-ends shared this code: cli/machorewrite.c's dylib/rpath/lc/segment verbs
 * through mr_apply_file until they were deleted, and src/edit.c's scripts
 * through mr_apply_image, which is the only way in now.
 * Parsing stays in each front-end; what crosses this boundary is an mr_ops.
 * Every diagnostic lives here once, not re-emitted per caller: contract.
 * spec: tests/change_dylib_test.sh -- it captures stderr and compares it.
 * spec: tests/cli_test.sh's "machorewrite stands alone" -- the CLI links this in
 * rather than forking change_dylib, so change_dylib can wrap machorewrite.
 * spec: src/ordinals.h -- a dylib insert or delete shifts every later library
 * ordinal and this module renumbers; an rpath insert shifts none. */
#include <stdint.h>
#include <stddef.h>

#include "ordinals.h"

/* One dylib-path (or rpath) operation. new_path == NULL deletes the command
 * naming old_path; "" leaves the path alone; anything else rewrites it,
 * growing the command if the longer string needs it. `retype_to` is an LC_*
 * constant to rewrite the command's kind to (what "" is for), or 0 to leave
 * the kind alone; never set for an rpath. */
typedef struct {
    const char *old_path;
    const char *new_path;
    uint32_t    retype_to;       /* always 0 for an rpath change */
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

/* Everything one run of the rewriter is being asked to do: AT MOST ONE
 * operation of each kind. Every pointer is caller-owned and read-only for the
 * call; NULL means that operation was not requested and the pointer is never
 * dereferenced.
 *
 * ONE OF EACH, not a set, and that is the whole shape of this module. The
 * only caller is src/edit.c, which lowers one statement at a time
 * (`me_apply`), so statements run in the order written and each sees what the
 * one before it left. Two operations are never in flight at once, so nothing
 * here resolves a conflict between them: `dylib replace P X` followed by
 * `dylib delete P` renames P and then finds no P to delete.
 * spec: docs/superpowers/specs/2026-09-14-script-is-the-only-interface-design.md
 * -- "What gets deleted": the set model, and the precedence rule, both go.
 * spec: tests/cli_test.sh's "dylib: replace+delete same path" -- that
 * sequence, asserted to produce the rename. */
typedef struct {
    const mr_change *dylib_change;     /* rewrite/delete/reexport a dependency */
    const char      *dylib_append;     /* brand-new LC_LOAD_DYLIB, placed last */
    const char      *dylib_insert;     /* brand-new LC_LOAD_DYLIB, placed first */
    const uint32_t  *strip_cmd;        /* a whole load-command kind to drop, LC_* */
    const mr_change *rpath_change;     /* rewrite/delete an LC_RPATH */
    const char      *rpath_append;     /* brand-new LC_RPATH, searched LAST */
    const char      *rpath_insert;     /* brand-new LC_RPATH, searched FIRST */
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
    /* If non-zero, mr_apply_file refuses (MR_REFUSED) when the run's
     * dylib_change/rpath_change/strip_cmd matched nothing, and NOTHING IS
     * WRITTEN: the verdict is decided before the one wa_write_new. Matching
     * and acting are the same question now that a run carries one operation:
     * the command this operation names is the command it rewrites. */
    int              fatal_unmatched;
    int              allow_grow;       /* may enlarge the pad (mg_grow_header) */
} mr_ops;

/* The two failure codes. MR_REFUSED is a CONSIDERED refusal: something
 * examined the bytes and declined. MR_FAIL is operational -- open, fstat,
 * read or write failing, or a checked allocation: mr_apply_file's fat-path
 * read buffer, mi_open's and mfat_parse's for the file and arch table, and
 * mfat_rewrite's for a fat split's arrays, copies and reassembly buffer. An
 * allocation failure inside mg_grow_header or mg_plausible is deliberately
 * MR_REFUSED instead, grow.c folding it in with its other refusals.
 * spec: cli/machorewrite.c's EX_REFUSED -- why a refusal is the LOWER code, and
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
 * PRECONDITION, unenforced here: `out` must not name `path`. cli/machorewrite.c
 * refuses it before any read, and wa_write_new checks again, so an unchecked
 * caller gets MR_FAIL and an unwritten input, not a rewritten one.
 *
 * `declared_disturbs` is what the OPERATIONS in `ops` declare they
 * invalidate, as an MREL_* mask (src/relations.h), which every caller reads
 * off the one operation table (src/script.h's ms_disturbs) rather than
 * inventing. It decides whether the rewrite's mg_plausible gate has anything
 * to check. A PARAMETER and not an mr_ops field on purpose: an mr_ops
 * DECLARES what to do, and a derived value living in a declaration struct is
 * the shape that goes stale in silence -- while a parameter makes the
 * compiler require an answer from every caller, the same enforcement
 * src/linkedit.h's link error and src/script.c's table macro rely on. The
 * declaration is only the starting point: a run that grows the header ORs in
 * MREL_BASE_REL, because a grow re-bases everything whichever operation
 * asked for it.
 */
int mr_apply_file(const char *path, const char *out, const mr_ops *ops,
                  uint32_t declared_disturbs);

/* How many load commands an mr_ops' dylib_change, rpath_change and strip_cmd
 * matched -- one count each, because a run carries one of each. ADDED to,
 * never assigned: a fat file's slices each add to one total, an operation
 * that matched in one slice and not another having matched. So zero an
 * mr_hits once per image, not between slices. */
typedef struct {
    int dylib;
    int rpath;
    int strip;
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
 * all. Same `declared_disturbs` as mr_apply_file's -- see there for what it is
 * and why it is a parameter. */
int mr_apply_image(uint8_t **pbuf, size_t *pfsize, const char *label,
                   const mr_ops *ops, uint32_t declared_disturbs,
                   int *out_modified, mr_hits *hits);

/* After a SUCCESSFUL rewrite -- only then, a refused one having possibly
 * stopped before a single comparison ran -- report on stderr each of
 * dylib_change/rpath_change/strip_cmd that `hits` says matched nothing, and
 * return MR_REFUSED if any did and ops->fatal_unmatched is set, else 0. */
int mr_unmatched_verdict(const mr_ops *ops, const mr_hits *hits);

#endif /* MACHOREWRITE_REWRITE_H */
