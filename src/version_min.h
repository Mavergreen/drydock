#ifndef DRYDOCK_VERSION_MIN_H
#define DRYDOCK_VERSION_MIN_H
/*
 * mv_ -- declaring a 10.9 deployment floor on an image that has none.
 *
 * patch_macho strips LC_BUILD_VERSION and leaves no platform declaration at
 * all; 10.9's dyld uses that signal for some behaviors (including, possibly,
 * TLV handling). This appends the LC_VERSION_MIN_MACOSX that 10.9 expects.
 *
 * It was compat/add_version_min.c's whole main(). It lives here so that
 * a drydock-macho-rewrite run can do the work in-process instead of forking
 * and exec'ing add_version_min -- the same cycle mr_apply_file (src/rewrite.h)
 * breaks for the load-command rewrites. That is also what let add_version_min
 * become compat/add_version_min.sh, a /bin/sh wrapper that pipes
 * `version-min set 10.9` into `drydock-macho-rewrite FILE OUT` and installs OUT over FILE
 * itself: the old name and the statement
 * print exactly the same thing, because there is only one implementation left
 * to print it.
 */
#include "image.h"

/*
 * Append LC_VERSION_MIN_MACOSX 10.9 to the thin 64-bit Mach-O at `path` and
 * write the result as `out`. `path` is READ and never written; `out` is
 * created afresh (wa_write_new, src/atomic_write.h), carrying `path`'s mode,
 * owner and xattrs. `out` must not be `path` -- wa_write_new refuses that and
 * this returns MR_FAIL without writing anything.
 *
 * Returns 0 on success -- including the "already has one, nothing to do"
 * case, where `out` is still written, so a 0 exit always means `out` exists
 * and is the answer -- or MR_REFUSED/MR_FAIL with a message already printed
 * on stderr. A non-zero return writes no `out` at all.
 *
 * The new command goes in the header pad. If the pad cannot hold it, this
 * is grown when the image can be (a 64-bit PIE executable without chained
 * fixups; see mg_ensure_pad in src/grow.h), and `out` grows with it;
 * otherwise this refuses.
 * Fat containers are not handled: add_version_min never did.
 */
int mv_add_version_min(const char *path, const char *out);

/*
 * mv_add_version_min's edit, without the file: append LC_VERSION_MIN_MACOSX
 * 10.9, with `sdk`, to the image in *pbuf, and nothing else -- no open, no
 * race guard, no write. src/edit.c calls it for `version-min set 10.9`
 * against the image it writes once, itself, after the last statement.
 *
 * Returns 0 with *out_added = 1 if it appended the command, 0 with
 * *out_added = 0 if the image already had one (after printing "already
 * present; nothing to do." on stdout, as mv_add_version_min always has), or
 * MR_REFUSED with "no room for LC_VERSION_MIN_MACOSX" on stderr when the
 * command cannot be placed. When the pad is short, growing it is
 * mg_ensure_pad's decision; if it grows, *pbuf is reallocated, *psize is
 * larger, and every pointer the caller held into the buffer is stale.
 * `label` prefixes mg_ensure_pad's own stderr lines -- its refusal, or its
 * announcement of a grow; both callers pass the file's path.
 */
int mv_add_version_min_image(uint8_t **pbuf, size_t *psize,
                             const char *label, uint32_t sdk, int *out_added);

#define MV_PLATFORM_MACOS 1   /* LC_BUILD_VERSION.platform */
#define MV_10_9 0x000A0900u

/* What mv_set_minos rewrote: how many of each command, and the first one's
 * value before. Both counts 0 means the image declares no macOS minimum. */
typedef struct {
    int      version_min;
    uint32_t version_min_was;
    int      build_version;
    uint32_t build_version_was;
} mv_minos_report;

/* Set LC_VERSION_MIN_MACOSX.version and a macOS LC_BUILD_VERSION's minos to
 * `version`, in place; never an sdk field, never a size. */
void mv_set_minos(mi_image *im, uint32_t version, mv_minos_report *r);

void mv_format_version(uint32_t v, char out[16]);

#define MV_PLATFORM_MACCATALYST 6   /* LC_BUILD_VERSION.platform */

enum { MV_AT_MOST, MV_IF_ABSENT };                                /* the rule */
enum { MV_FROM_NONE, MV_FROM_VERSION_MIN, MV_FROM_BUILD_VERSION };  /* where D was read */

/* What mv_declare_minos read and wrote, for the report. */
typedef struct {
    int      from;           /* MV_FROM_* */
    uint32_t declared;       /* D, when from is not MV_FROM_NONE */
    int      above;          /* D is above VERSION, at VERSION's precision */
    uint32_t minos, sdk;     /* the LC_VERSION_MIN_MACOSX the slice ends with */
    int      dropped_macos;  /* a macOS LC_BUILD_VERSION removed beside a version-min */
    uint32_t dropped_minos;  /* ... and its minos */
    int      catalyst;       /* Mac Catalyst LC_BUILD_VERSIONs removed */
    int      changed;        /* any byte of the slice changed */
} mv_decl_report;

/* Leave the image in *pbuf with exactly one LC_VERSION_MIN_MACOSX and no
 * LC_BUILD_VERSION. `rule` and `version` (with the mask ms_parse_version gave)
 * decide the minimum; the sdk is the declaring command's, or 10.9 when
 * nothing was declared. Returns 0, or MR_REFUSED with the reason on stderr
 * prefixed by `label`. A grow may reallocate *pbuf. */
int mv_declare_minos(uint8_t **pbuf, size_t *psize, const char *label, int rule,
                     uint32_t version, uint32_t mask, mv_decl_report *r);

#endif /* DRYDOCK_VERSION_MIN_H */
