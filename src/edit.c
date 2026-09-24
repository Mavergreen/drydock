/*
 * me_ -- see edit.h. Read once, apply each statement in order, verify what
 * the run disturbed, write once.
 *
 * Every operation is performed by the one implementation of that operation --
 * the same in-memory cores the deleted CLI verbs used to reach; what lives
 * here is the lowering from a statement to that call (the switch in
 * me_apply), the sequencing, the final verify and the single write. The
 * operations print what they have always printed, to stdout and
 * stderr; this module's own report goes to me_opts.log. That report includes
 * the follow-up work an operation does beyond what its statement names, from
 * figures the operation hands back through an out-parameter -- mr_ops'
 * `renumbering`, md_declassify_buf's md_report, mswift_retag_image's return,
 * mv_add_version_min_image's `added` -- and never from a second look at the
 * image.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/fat.h>

#include "edit.h"
#include "image.h"
#include "grow.h"
#include "relations.h"
#include "rewrite.h"
#include "segname.h"
#include "lc_kinds.h"
#include "version_min.h"
#include "swift_retag.h"
#include "declassify.h"
#include "redirect.h"
#include "atomic_write.h"
#include "mach_compat.h"
#include "fat.h"
#include "arch_names.h"

/* Every line this module writes, to the log or to stderr, goes through here.
 * The operations print their progress to stdout, which is fully buffered
 * when it is not a terminal, so without the flush a `2>&1` capture would
 * show this module's lines ahead of stdout lines printed before them.
 * me_rewrite flushes the same way before the "matched nothing" report. What
 * this cannot order is a message an operation writes to stderr while it
 * runs (a refusal from inside mr_apply_image, say): stderr is unbuffered,
 * so that can still land ahead of the same operation's earlier stdout
 * lines. */
static void me_say(FILE *f, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void me_say(FILE *f, const char *fmt, ...) {
    va_list ap;
    fflush(stdout);
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
}

/* The tail of a refusal or failure line: what the run left behind, which is
 * always both halves -- FILE as it was, and OUT not written. "OUT not written"
 * rather than "OUT left unmodified" because OUT may never have existed, and
 * because a pre-existing OUT is equally untouched: every refusal, on the thin
 * path and the fat one alike, happens before me_write_once is reached, and that
 * is the only place anything is written. */
static void me_say_left(FILE *log, const char *path, const char *out) {
    me_say(log, "%s not written; %s left unmodified\n", out, path);
}

/* "208526708" -> "208,526,708", the way the report prints a byte count. */
static void me_commas(char out[32], size_t n) {
    char digits[24];
    int len = snprintf(digits, sizeof digits, "%zu", n);
    int o = 0;
    for (int i = 0; i < len; i++) {
        if (i > 0 && (len - i) % 3 == 0) out[o++] = ',';
        out[o++] = digits[i];
    }
    out[o] = '\0';
}

static void me_log_stmt(FILE *log, const ms_stmt *st) {
    me_say(log, "  %s %s", ms_kind_name(st->kind), ms_op_name(st->op));
    if (st->a) me_say(log, " %s", st->a);
    if (st->b) me_say(log, " %s", st->b);
    if (st->c) me_say(log, " %s", st->c);
    me_say(log, "\n");
}

/* A count the way the report prints one: with commas. */
static const char *me_count(char out[32], long n) {
    me_commas(out, n < 0 ? 0 : (size_t)n);
    return out;
}

/* A load command kind by its LC_* name, or in hex for one lc_cmd_name does
 * not list. */
static const char *me_lc(char out[16], uint32_t cmd) {
    const char *name = lc_cmd_name(cmd);
    if (name) return name;
    snprintf(out, 16, "0x%08x", cmd);
    return out;
}

/* The follow-up a dylib insert or delete carries: the library-ordinal
 * renumbering, as the rewrite's own map and mo_map_apply's own counts
 * describe it (rewrite.h's mr_renumbering). Indented under the statement
 * line, in this shape:
 *
 *       removed LC_LOAD_DYLIB (was ordinal 4)
 *       renumbered 3 surviving ordinals: 5->4, 6->5, 7->6
 *           12 nlist entries updated
 *           847 SET_DYLIB_ORDINAL opcodes updated (bind 811, weak 0, lazy 36)
 *
 * "existing" in place of "surviving" when nothing was removed. An inserted
 * command is named LC_LOAD_DYLIB because that is the one kind the rewrite
 * emits for an insert (rewrite.h, mr_ops' dylib_insert). */
static void me_log_renumbering(FILE *log, const mr_renumbering *r) {
    char k[16], c1[32], c2[32], c3[32], c4[32];
    int removed = 0, moved = 0;
    for (int i = 1; i <= r->inserted; i++)
        me_say(log, "      inserted LC_LOAD_DYLIB as ordinal %d\n", i);
    for (int o = 1; o <= r->n; o++) {
        int to = r->old_to_new[o];
        if (to == 0) {
            me_say(log, "      removed %s (was ordinal %d)\n", me_lc(k, r->old_cmd[o]), o);
            removed++;
        } else if (to != o) {
            moved++;
        }
    }
    const char *which = removed ? "surviving" : "existing";
    if (r->counts.flat) {
        /* mo_map_apply walked nothing: a flat-namespace image names no
         * library by ordinal, so a moved load command moves no reference. */
        me_say(log, "      flat namespace: no symbol records a library ordinal, "
                    "so none was renumbered\n");
        return;
    }
    if (moved == 0) {
        me_say(log, "      no %s ordinal changed\n", which);
        return;
    }
    me_say(log, "      renumbered %d %s ordinal%s:", moved, which, moved == 1 ? "" : "s");
    const char *sep = " ";
    for (int o = 1; o <= r->n; o++) {
        int to = r->old_to_new[o];
        if (to == 0 || to == o) continue;
        me_say(log, "%s%d->%d", sep, o, to);
        sep = ", ";
    }
    me_say(log, "\n");
    long ops = r->counts.bind + r->counts.weak + r->counts.lazy;
    me_say(log, "          %s nlist entr%s updated\n",
           me_count(c1, r->counts.nlist), r->counts.nlist == 1 ? "y" : "ies");
    me_say(log, "          %s SET_DYLIB_ORDINAL opcode%s updated (bind %s, weak %s, lazy %s)\n",
           me_count(c1, ops), ops == 1 ? "" : "s", me_count(c2, r->counts.bind),
           me_count(c3, r->counts.weak), me_count(c4, r->counts.lazy));
}

/* The follow-up `fixups set classic` carries when it converts: __LINKEDIT's
 * opcode streams rebuilt wholesale, in md_declassify_buf's own figures
 * (declassify.h's md_report). */
static void me_log_declassify(FILE *log, const md_report *r) {
    char k[16], c1[32], c2[32], c3[32], c4[32], v1[16], v2[16];
    me_say(log, "      chained fixups -> LC_DYLD_INFO_ONLY");
    if (r->kept_version_min) {
        mv_format_version(r->kept_minos, v1);
        mv_format_version(r->kept_sdk, v2);
        me_say(log, "; LC_BUILD_VERSION %s (sdk %s) kept as LC_VERSION_MIN_MACOSX", v1, v2);
    }
    me_say(log, "\n");
    me_say(log, "      %s rebase%s and %s bind%s emitted (%s bytes of opcodes, %s bytes appended)\n",
           me_count(c1, r->rebases), r->rebases == 1 ? "" : "s",
           me_count(c2, r->binds), r->binds == 1 ? "" : "s",
           me_count(c3, (long)(r->rebase_bytes + r->bind_bytes)),
           me_count(c4, (long)r->appended));
    if (r->n_stripped > 0) {
        me_say(log, "      stripped");
        for (int i = 0; i < r->n_stripped; i++)
            me_say(log, "%s%s", i ? ", " : " ", me_lc(k, r->stripped[i]));
        me_say(log, "\n");
    }
    if (r->linkedit_after > r->linkedit_before)
        me_say(log, "      __LINKEDIT extended by %s bytes\n",
               me_count(c1, (long)(r->linkedit_after - r->linkedit_before)));
}

/* spec: tests/import_redirect_test.sh "grow" -- growth is announced, always. */
static void me_log_redirect(FILE *log, const mrd_report *r, const char *symbol) {
    char c1[32], c2[32], c3[32], c4[32];
    long n = r->bind + r->lazy;
    if (n == 0 && r->nlist == 0) {
        me_say(log, "      no bind of %s names that library here\n", symbol);
    } else {
        me_say(log, "      redirected %s bind%s (bind %s, lazy %s) and %s nlist entr%s "
                    "from ordinal %d to ordinal %d\n",
               me_count(c1, n), n == 1 ? "" : "s", me_count(c2, r->bind),
               me_count(c3, r->lazy), me_count(c4, r->nlist), r->nlist == 1 ? "y" : "ies",
               r->from, r->to);
    }
    if (r->bind_off_after != r->bind_off_before)
        me_say(log, "      bind stream grew from %s to %s bytes; it now lives at file "
                    "offset 0x%x, and __LINKEDIT grew from %s to %s bytes to cover it\n",
               me_count(c1, (long)r->bind_before), me_count(c2, (long)r->bind_after),
               r->bind_off_after, me_count(c3, (long)r->linkedit_before),
               me_count(c4, (long)r->linkedit_after));
    else if (r->bind)
        me_say(log, "      bind stream rewritten in place (%s bytes)\n",
               me_count(c1, (long)r->bind_after));
    if (r->weak)
        me_say(stderr, "WARNING: %s appears in the weak-bind table %s time%s; weak binds "
                       "name no library, so %s not redirected\n", symbol,
               me_count(c1, r->weak), r->weak == 1 ? "" : "s",
               r->weak == 1 ? "it was" : "they were");
}

static void me_log_declared(FILE *log, const mv_decl_report *r, const char *version) {
    char d[16], n[16], s[16], x[16];
    mv_format_version(r->declared, d);
    mv_format_version(r->minos, n);
    mv_format_version(r->sdk, s);
    if (r->from == MV_FROM_NONE)
        me_say(log, "      none -> version-min %s; sdk %s written", n, s);
    else if (r->from == MV_FROM_BUILD_VERSION)
        me_say(log, "      build-version %s -> version-min %s; sdk %s carried over", d, n, s);
    else if (r->minos != r->declared)
        me_say(log, "      version-min %s -> %s; sdk %s kept", d, n, s);
    else if (r->above)
        me_say(log, "      version-min %s kept (declared); sdk %s kept", d, s);
    else
        me_say(log, "      version-min %s, at or below %s: kept; sdk %s kept", d, version, s);
    if (r->dropped_macos) {
        mv_format_version(r->dropped_minos, x);
        me_say(log, "; build-version %s removed", x);
    }
    if (r->catalyst) me_say(log, "; Mac Catalyst build-version removed");
    me_say(log, "\n");
}

/* The version-min and swift-abi cores take an mi_image; the buffer is the
 * image as the previous statement left it, so it gets the same validation
 * mi_open would give a file. */
static int me_view(uint8_t *buf, size_t size, mi_image *im, const char *path, FILE *log) {
    if (mi_wrap(buf, size, im) == 0) return 0;
    me_say(log, "drydock-macho-rewrite edit: %s: the image is no longer a readable 64-bit Mach-O\n", path);
    return MR_REFUSED;
}

/* What one statement's "matched nothing" verdict needs across the slices of
 * a run: counts that every slice running the statement ADDS to (mr_hits'
 * own contract, rewrite.h), and whether this is the last selected slice --
 * the one that decides. On a thin file the one image is the last, so the
 * verdict comes right after the statement, as it always has. */
typedef struct {
    mr_hits *hits;      /* this statement's counts, summed across slices */
    int     *renamed;   /* this statement's segment-rename or import-redirect count, likewise */
    int      decide;    /* nonzero in the last selected slice */
    int      missed;    /* set when the verdict refused: it matched nothing */
    int      changed;   /* written by minos: whether it changed the slice */
} me_verdict;

/* One mr_ops through the rewrite, then -- in the last selected slice -- the
 * verdict on anything it asked for that matched nothing: a report on stderr,
 * and a refusal unless the script says allow-unmatched (ops->fatal_unmatched).
 * The hit counts are per statement, because each statement is its own rewrite
 * of the image as it now stands, and are summed across the slices that run
 * it, because a statement that matched in any selected slice has matched.
 *
 * `declared` is the STATEMENT's own disturbs mask, not the script's union:
 * the rewrite's internal gate is about this one rewrite, and this module's
 * own accumulator (me_note_disturbed) is what carries the run's total to the
 * final verify. */
static int me_rewrite(uint8_t **pbuf, size_t *psize, const char *path,
                      const mr_ops *ops, unsigned declared, me_verdict *v) {
    int modified = 0;
    int rc = mr_apply_image(pbuf, psize, path, ops, declared, &modified, v->hits);
    if (rc != 0 || !v->decide) return rc;
    /* The verdict's "matched nothing" report goes to stderr; flushed first
     * for the reason me_say flushes. */
    fflush(stdout);
    rc = mr_unmatched_verdict(ops, v->hits);
    if (rc != 0) v->missed = 1;
    return rc;
}

/* The lowering: one statement, one call to the code that performs it. Returns
 * 0, MR_REFUSED or MR_FAIL. *pbuf and *psize always name the current image
 * afterwards, whether or not the statement succeeded, because three of these
 * reallocate it: a header grow, inside the rewrite and inside
 * `version-min set`, and the room `fixups set classic` appends its opcode
 * streams into.
 *
 * A statement that succeeded logs, indented beneath its statement line, the
 * work it did beyond what it names: the ordinal renumbering of a dylib insert
 * or delete, what `fixups set classic` converted or that it passed the image
 * through, what `swift-abi set legacy` retagged, and the command
 * `version-min set` appended. */
static int me_apply(uint8_t **pbuf, size_t *psize, const char *path,
                    const ms_script *s, const ms_stmt *st, FILE *log,
                    me_verdict *v) {
    mr_ops ops;
    mr_change change;
    mr_renumbering renum;
    memset(&ops, 0, sizeof ops);
    memset(&change, 0, sizeof change);
    memset(&renum, 0, sizeof renum);
    ops.fatal_unmatched = !s->allow_unmatched;

    switch (st->kind) {
    case MS_LOAD_COMMAND: {
        /* ms_parse has already refused a KIND outside LC_STRIP_KINDS; this
         * is the same lookup the deleted `lc` verb made. */
        uint32_t cmd = 0;
        if (lc_kind_by_name(st->a, &cmd) != 0) break;
        ops.strip_cmd = &cmd;
        return me_rewrite(pbuf, psize, path, &ops, ms_disturbs(st->kind, st->op), v);
    }

    case MS_SEGMENT: {
        /* The same pre-check the deleted `segment` verb made: a segname
         * field is 16 bytes,
         * and mseg_rename_lc would truncate a longer name silently. */
        if (!mseg_name_fits(st->b)) {
            me_say(log, "drydock-macho-rewrite edit: new segment name '%s' is longer than the %d bytes "
                        "a segname field holds\n", st->b, MSEG_NAME_MAX);
            return MR_REFUSED;
        }
        /* A rename has no hit count for mr_unmatched_verdict to read; its
         * match count comes back through segment_renamed, as it did for
         * that verb, and is summed across the slices that run this
         * statement, the way mr_hits is. Zero in every one of them is this
         * statement's miss, judged in the last selected slice: reported on
         * stderr in the shape of the other "matched nothing" lines, and a
         * refusal unless allow-unmatched -- before anything is written,
         * because nothing is written until after the last statement. */
        int renamed = 0;
        ops.segment_rename_old = st->a;
        ops.segment_rename_new = st->b;
        ops.segment_renamed = &renamed;
        int rc = me_rewrite(pbuf, psize, path, &ops, ms_disturbs(st->kind, st->op), v);
        if (rc != 0) return rc;
        *v->renamed += renamed;
        if (!v->decide || *v->renamed > 0) return 0;
        me_say(stderr, "drydock-macho-rewrite: segment %s matched nothing\n", st->a);
        if (!s->allow_unmatched) { v->missed = 1; return MR_REFUSED; }
        return 0;
    }

    case MS_DYLIB:
    case MS_RPATH: {
        /* mr_change's own encoding (rewrite.h), the one the deleted
         * dylib/rpath verbs also produced: new_path NULL deletes, "" with
         * retype_to promotes/retypes. */
        int rpath = (st->kind == MS_RPATH);
        switch (st->op) {
        case MS_REPLACE:  change.old_path = st->a; change.new_path = st->b; break;
        case MS_DELETE:   change.old_path = st->a; change.new_path = NULL;  break;
        case MS_REEXPORT: if (rpath) goto unknown;
                          change.old_path = st->a; change.new_path = "";
                          change.retype_to = LC_REEXPORT_DYLIB; break;
        case MS_RETYPE:   if (rpath) goto unknown;
                          change.old_path = st->a; change.new_path = "";
                          change.retype_to = mo_kind_from_name(st->b);
                          break;
        case MS_APPEND:
            if (rpath) ops.rpath_append = st->a;
            else       ops.dylib_append = st->a;
            break;
        case MS_INSERT:
            if (rpath) ops.rpath_insert = st->a;
            else       ops.dylib_insert = st->a;
            break;
        default: goto unknown;
        }
        if (change.old_path) {
            if (rpath) ops.rpath_change = &change;
            else       ops.dylib_change = &change;
        }
        /* Only a dylib statement can renumber: an LC_RPATH bears no
         * ordinal. The rewrite fills renum only when it did renumber --
         * an insert, or a delete that matched -- so a replace, an append, a
         * reexport or a delete that matched nothing logs no follow-up. */
        if (!rpath) ops.renumbering = &renum;
        int rc = me_rewrite(pbuf, psize, path, &ops, ms_disturbs(st->kind, st->op), v);
        if (rc == 0 && renum.done) me_log_renumbering(log, &renum);
        return rc;
    }

    case MS_VERSION_MIN: {
        /* ms_parse accepts only 10.9, and 10.9 is the only floor this core
         * writes; the parser's value check is the one place that says so.
         * When the pad is short, growing it is mg_ensure_pad's decision, the
         * same as for dylib and rpath. */
        mi_image im;
        int added = 0;
        if (me_view(*pbuf, *psize, &im, path, log) != 0) return MR_REFUSED;
        int rc = mv_add_version_min_image(pbuf, psize, path, &added);
        if (rc == 0 && added)
            me_say(log, "      appended LC_VERSION_MIN_MACOSX 10.9\n");
        return rc;
    }

    case MS_SWIFT_ABI: {
        /* `legacy` is the only value ms_parse accepts. A count of zero is
         * not a refusal: an image with no Swift classes has nothing to
         * retag, as the `retag-swift` verb reported with exit 0. */
        mi_image im;
        if (me_view(*pbuf, *psize, &im, path, log) != 0) return MR_REFUSED;
        int retagged = mswift_retag_image(&im);
        if (retagged == MSWIFT_CHAINED) {
            me_say(log, "drydock-macho-rewrite edit: %s: the class records' pointers are chained; "
                        "write `fixups set classic` before `swift-abi set legacy`\n", path);
            return MR_REFUSED;
        }
        if (retagged > 0)
            me_say(log, "      retagged %d class record%s\n", retagged,
                   retagged == 1 ? "" : "s");
        else
            me_say(log, "      nothing to retag\n");
        return 0;
    }

    case MS_IMPORT: {
        if (st->op != MS_REDIRECT) goto unknown;
        mrd_report r;
        int rc = mrd_redirect(pbuf, psize, st->a, st->b, st->c, &r);
        if (rc != 0) return rc;
        me_log_redirect(log, &r, st->a);
        *v->renamed += (int)(r.bind + r.lazy + r.nlist);
        if (!v->decide || *v->renamed > 0) return 0;
        me_say(stderr, "drydock-macho-rewrite: import redirect %s %s %s matched nothing\n",
               st->a, st->b, st->c);
        if (!s->allow_unmatched) { v->missed = 1; return MR_REFUSED; }
        return 0;
    }

    case MS_MINOS: {
        uint32_t want = 0, mask = 0;
        mi_image im;
        mv_decl_report d;
        if (st->op != MS_AT_MOST && st->op != MS_IF_ABSENT) goto unknown;
        if (ms_parse_version(st->a, &want, &mask) != 0) goto unknown;
        if (me_view(*pbuf, *psize, &im, path, log) != 0) return MR_REFUSED;
        int rc = mv_declare_minos(pbuf, psize, path,
                                  st->op == MS_AT_MOST ? MV_AT_MOST : MV_IF_ABSENT,
                                  want, mask, &d);
        if (rc != 0) return rc;
        me_log_declared(log, &d, st->a);
        v->changed = d.changed;
        return 0;
    }

    case MS_FIXUPS: {
        /* The conversion appends into room past the image rather than
         * reallocating (declassify.h), and md_declassify gets that room by
         * reading the file with MDCL_SLACK to spare. The image is already in
         * memory here, so the room comes from a realloc instead -- zeroed,
         * because the streams are aligned within it and the alignment gap
         * becomes part of the output. */
        size_t len = *psize, newlen = 0;
        if (len > SIZE_MAX - MDCL_SLACK) {
            me_say(log, "drydock-macho-rewrite edit: %s: too large to make room for fixups set classic\n", path);
            return MR_FAIL;
        }
        uint8_t *nb = (uint8_t *)realloc(*pbuf, len + MDCL_SLACK);
        if (!nb) {
            me_say(log, "drydock-macho-rewrite edit: out of memory making room for fixups set classic\n");
            return MR_FAIL;
        }
        *pbuf = nb;
        memset(nb + len, 0, MDCL_SLACK);
        md_report rep;
        int rc = md_declassify_buf(nb, len, len + MDCL_SLACK, &newlen, &rep);
        /* Tested by name, as declassify.h requires: PASSTHROUGH is a nonzero
         * success. rep is filled only on CONVERTED. */
        if (rc == MDCL_CONVERTED) {
            *psize = newlen;
            me_log_declassify(log, &rep);
            return 0;
        }
        if (rc == MDCL_PASSTHROUGH) {
            *psize = newlen;
            me_say(log, "      already classic (LC_DYLD_INFO_ONLY, no chained fixups): "
                        "passed through unchanged\n");
            return 0;
        }
        if (rc == MDCL_REFUSED) return MR_REFUSED;   /* the reason is on stderr */
        if (rc == MDCL_ERROR) return MR_FAIL;        /* likewise */
        if (rc == MDCL_NOT_MACHO) {
            me_say(log, "drydock-macho-rewrite edit: %s: the image is no longer a readable 64-bit Mach-O\n", path);
            return MR_REFUSED;
        }
        me_say(log, "drydock-macho-rewrite edit: md_declassify_buf returned an unrecognized code %d\n", rc);
        return MR_FAIL;
    }
    }

unknown:
    /* Unreachable through ms_parse, which refuses a statement outside
     * MS_TABLE; a statement this switch does not lower is a build that
     * disagrees with itself, not something the image did. MS_TARGET reaches
     * this too, and would be that same disagreement: me_statements expands it
     * instead of lowering it, because it is not one operation. */
    me_say(log, "drydock-macho-rewrite edit: cannot apply '%s %s'\n", ms_kind_name(st->kind), ms_op_name(st->op));
    return MR_FAIL;
}

/* What one statement actually disturbed: what its row DECLARES, plus what the
 * run is observed to have done. The observation is the first section's file
 * offset -- the header pad's own definition -- because that moving is exactly
 * a grow, and a grow re-bases every base-relative value and moves every
 * __LINKEDIT blob. A declaration alone would miss it; the pad's own bit is
 * not enough, since disturbing the pad and OVERFLOWING it are different
 * events.
 *
 * This is why the accumulator runs here and not over s->stmts: the statements
 * as PARSED are the declared half only, and `target 10.9` declares MREL_NONE
 * of its own while its expansion can lower a fixups conversion. A gate reading
 * the parsed script's declarations would therefore skip the verify on exactly
 * that run -- the one that most needs it. */
static void me_note_disturbed(unsigned *disturbed, const ms_stmt *st,
                              uint32_t first_before, uint32_t first_after) {
    *disturbed |= ms_disturbs(st->kind, st->op);
    if (first_before != first_after)
        *disturbed |= MREL_BASE_REL | MREL_FILE_OFF;
}

/* The gate did not apply, so the report says what the run DID disturb: with
 * the verify now conditional, "why was my file not verified?" is a question
 * the line itself has to answer. Names come from mrel_name, so a relation
 * cannot be renamed in one place and reported under the old name here. */
static void me_say_not_rechecked(FILE *log, const char *what, unsigned disturbed) {
    char names[160];   /* every name src/relations.h has, joined, with slack */
    size_t used = 0;
    unsigned bit;

    if (disturbed == MREL_NONE) {
        me_say(log, "%s: this run disturbed nothing, so there is nothing to re-check\n", what);
        return;
    }
    names[0] = '\0';
    for (bit = 1; bit; bit <<= 1) {
        const char *name = (disturbed & bit) ? mrel_name(bit) : NULL;
        int w;
        if (!name) continue;
        w = snprintf(names + used, sizeof names - used, "%s%s", used ? ", " : "", name);
        if (w < 0 || (size_t)w >= sizeof names - used) break;
        used += (size_t)w;
    }
    me_say(log, "%s: this run disturbed %s; none of that is re-checked\n", what, names);
}

/* ---- target 10.9 --------------------------------------------------------
 *
 * The one statement whose meaning depends on the binary. It is not an
 * operation: it expands, where it is written, into statements the language
 * already has -- the ones THIS image needs -- and those run in its place.
 * See src/script.h's MS_TARGET for its place in the statement vocabulary.
 *
 * Every detection here is exact: a load command is present or it is not, a
 * section name begins with __objc_ or it does not, a tag bit is set or it is
 * not. None of them guesses, so the expansion is reproducible from the image
 * alone.
 */
#define ME_TARGET_MAX 4   /* the steps of target 10.9's edit script, in README.md's order */

/* One derived statement, and the finding that produced it -- the report
 * carries both, because "why is this script doing that?" is exactly the
 * question a profile line raises. */
typedef struct { ms_stmt stmt; const char *why; } me_derived;

/* What the load commands say about this image. */
typedef struct { int chained, dataconst_objc; } me_seen;

static int me_target_lc(const struct load_command *lc, void *ctx_) {
    me_seen *f = (me_seen *)ctx_;
    if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) { f->chained = 1; return 0; }
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
        /* segname/sectname are 16 bytes and need not be NUL-terminated, which
         * is why these are strncmp and not strcmp. mi_wrap has already proved
         * cmdsize covers the section array nsects claims, so this walk stays
         * inside the command. A __DATA_CONST with no __objc_ section is left
         * alone: what breaks on 10.9 is the Objective-C runtime not finding
         * its metadata (src/segname.h), and a segment carrying none has none
         * to hide. */
        if (strncmp(sc->segname, "__DATA_CONST", MSEG_NAME_MAX) != 0) return 0;
        const struct section_64 *sect = (const struct section_64 *)(sc + 1);
        for (uint32_t k = 0; k < sc->nsects; k++)
            if (strncmp(sect[k].sectname, "__objc_", 7) == 0) f->dataconst_objc = 1;
    }
    return 0;
}

/* Step `step` of the 10.9 profile, asked of the image as the steps before it
 * left it: 1, with `d` filled, when this image needs that step, else 0.
 *
 * `fixups set classic` comes first because nothing can grow the header while
 * the image still has chained fixups (src/grow.h), and every step after it
 * sees the __LINKEDIT, the header pad and the class-record pointers it left.
 *
 * NEVER dylib or rpath work: no tool can guess which stub dylib you meant,
 * and that is the dominant real workload. A profile that guessed would be
 * wrong silently, which is the failure class this toolkit exists to remove.
 *
 * Each derived statement carries the `target` line's own source line, which
 * is where it came from and the only line anyone wrote.
 *
 * `im` is a view, and is not written. */
static int me_expand_10_9(const mi_image *im, int step, me_derived *d, int line) {
    me_seen f;
    memset(&f, 0, sizeof f);
    memset(d, 0, sizeof *d);
    mi_each_lc(im, me_target_lc, &f);
    d->stmt.line = line;
    switch (step) {
    case 0:
        if (!f.chained) return 0;
        d->stmt.kind = MS_FIXUPS; d->stmt.op = MS_SET; d->stmt.a = "classic";
        d->why = "LC_DYLD_CHAINED_FIXUPS present";
        return 1;
    case 1:
        d->stmt.kind = MS_MINOS; d->stmt.op = MS_AT_MOST; d->stmt.a = "10.9";
        d->why = "always";
        return 1;
    case 2:
        if (!f.dataconst_objc) return 0;
        d->stmt.kind = MS_SEGMENT; d->stmt.op = MS_RENAME;
        d->stmt.a = "__DATA_CONST"; d->stmt.b = "__DATA";
        d->why = "__DATA_CONST carries __objc_ sections";
        return 1;
    case 3:
        if (mswift_stable_tagged_image(im) <= 0) return 0;
        d->stmt.kind = MS_SWIFT_ABI; d->stmt.op = MS_SET; d->stmt.a = "legacy";
        d->why = "class records carry the stable-ABI Swift tag";
        return 1;
    }
    return 0;
}

/* A derived statement's own line in the report, one indent deeper than the
 * `target` line it came from, with the finding that produced it. This is the
 * whole reason `target` is a visible line rather than hidden behaviour: the
 * same line does different things to different binaries, so the report has to
 * say which it did here. */
static void me_log_derived(FILE *log, const me_derived *d) {
    me_say(log, "    %s %s", ms_kind_name(d->stmt.kind), ms_op_name(d->stmt.op));
    if (d->stmt.a) me_say(log, " %s", d->stmt.a);
    if (d->stmt.b) me_say(log, " %s", d->stmt.b);
    me_say(log, "  (%s)\n", d->why);
}

/* Run the profile's steps in order, at this position, each derived from the
 * image the step before it left. Returns 0, or the first derived statement's
 * own MR_REFUSED/MR_FAIL -- which me_statements then reports against the
 * `target` line, since that is the line the operator wrote.
 *
 * A derived statement NEVER counts as unmatched: "this binary already
 * targets 10.9 correctly" is a correct answer for a profile, unlike for an
 * explicit operation. Two things enforce that together -- allow_unmatched is
 * SET in the script this runs under, and the verdict is not taken at all
 * (decide is 0), so no "matched nothing" line is printed either. Writing
 * `target 10.9` AND an explicit statement it would have derived is the other
 * side of this, and is not special-cased: the explicit one is redundant, and
 * the default refusal flags it. */
static int me_target(uint8_t **pbuf, size_t *psize, const char *path,
                     const ms_script *s, const ms_stmt *st, FILE *log,
                     unsigned *disturbed) {
    ms_script sub = *s;
    int step, changed = 0;
    sub.allow_unmatched = 1;
    for (step = 0; step < ME_TARGET_MAX; step++) {
        me_derived d;
        mi_image im;
        mr_hits hits;
        int renamed = 0, rc;
        me_verdict v;
        if (me_view(*pbuf, *psize, &im, path, log) != 0) return MR_REFUSED;
        if (!me_expand_10_9(&im, step, &d, st->line)) continue;
        memset(&hits, 0, sizeof hits);
        v.hits = &hits; v.renamed = &renamed; v.decide = 0; v.missed = 0; v.changed = 1;
        me_log_derived(log, &d);
        /* Each DERIVED statement declares for itself, which is what makes
         * the `target` row's own MREL_NONE correct rather than a hole. */
        uint32_t first_before = mg_first_sect_off(*pbuf, *psize);
        rc = me_apply(pbuf, psize, path, &sub, &d.stmt, log, &v);
        if (rc != 0) return rc;
        me_note_disturbed(disturbed, &d.stmt, first_before, mg_first_sect_off(*pbuf, *psize));
        changed |= v.changed;
    }
    if (!changed)
        me_say(log, "    nothing to do: this binary already targets 10.9\n");
    return 0;
}

/* Every statement, in order, against one image -- a thin file's, or one fat
 * slice's. `slice` is NULL for a thin file, else the slice's arch name, for
 * the refusal line. hits/renamed hold one entry per statement, shared by
 * every slice of the run; `decide` says whether this is the last selected
 * slice. Returns 0, or the first failing statement's code after printing the
 * refusal line.
 *
 * WHY NOT BATCH THE STATEMENTS into one operation set, the way `drydock-macho-rewrite
 * dylib` batches its flags into one mr_ops: because `fixups set classic`
 * cannot batch with anything -- every later statement has to see the lowered
 * image, with its new LC_DYLD_INFO_ONLY and extended __LINKEDIT -- and
 * because running in sequence is what a reader of the script assumes.
 * `dylib append X` followed by `dylib replace X Y` means something only in
 * sequence. The cost is rebuilding the load-command table once per
 * statement: a few KB, against I/O that happens once either way. */
static int me_statements(uint8_t **pbuf, size_t *psize, const char *path, const char *out,
                         const ms_script *s, FILE *log,
                         mr_hits *hits, int *renamed, int decide, const char *slice,
                         unsigned *disturbed) {
    for (int i = 0; i < s->n; i++) {
        const ms_stmt *stmt = &s->stmts[i];
        me_log_stmt(log, stmt);
        me_verdict v = { &hits[i], &renamed[i], decide, 0 };
        uint32_t first_before = mg_first_sect_off(*pbuf, *psize);
        /* `target` is not an operation, so it is not lowered to one: it
         * expands here, in place, into the statements this image needs, and
         * they run before the next statement in the script does. Its own
         * hits/renamed entries stay zero -- nothing it derived can miss. */
        int rc = stmt->kind == MS_TARGET
            ? me_target(pbuf, psize, path, s, stmt, log, disturbed)
            : me_apply(pbuf, psize, path, s, stmt, log, &v);
        if (rc != 0) {
            if (rc != MR_REFUSED) rc = MR_FAIL;
            me_say(log, "drydock-macho-rewrite edit: %s at statement %d of %d (line %d)",
                   rc == MR_REFUSED ? "refused" : "failed", i + 1, s->n, stmt->line);
            if (slice && v.missed) me_say(log, ": it matched nothing in any selected slice");
            else if (slice)        me_say(log, " in slice %s", slice);
            me_say(log, "; ");
            me_say_left(log, path, out);
            return rc;
        }
        me_note_disturbed(disturbed, stmt, first_before,
                          mg_first_sect_off(*pbuf, *psize));
    }
    return 0;
}

/* Does the finished image still have anything for mg_plausible to check,
 * after a run that disturbed `disturbed`? The one question both of this
 * module's gate sites ask, so they cannot drift apart.
 *
 * An image this can no longer wrap is answered YES rather than skipped: the
 * derivation needs an image to read, and with none the only safe answer is to
 * run the gate -- which is also the one that says what is wrong, since
 * mg_plausible refuses an unwrappable buffer with its own line. */
static int me_verify_applies(uint8_t *buf, size_t size, unsigned disturbed) {
    mi_image im;
    if (mi_wrap(buf, size, &im) != 0) return 1;
    return mrel_verify_applies(&im, disturbed);
}

/* The last step of a run nothing refused: report, and write OUT once. Takes
 * ownership of buf. The write goes through wa_write_new, which gives OUT the
 * INPUT's mode, owner and extended attributes and renames a temp onto it -- so
 * OUT is whole or as it was, and `path` is never a destination. There is no
 * mode parameter for the same reason: the mode comes from the input, which
 * wa_write_new stats itself. */
static int me_write_once(uint8_t *buf, size_t size, const char *path, const char *out,
                         FILE *log) {
    char bytes[32];
    me_commas(bytes, size);
    int wr = wa_write_new(path, out, buf, size);
    free(buf);
    if (wr != 0) {
        /* What OUT holds after a failed write is atomic_write.h's to say (it
         * is as it was); FILE was never a destination. */
        me_say(log, "drydock-macho-rewrite edit: writing %s failed; %s left unmodified\n", out, path);
        return MR_FAIL;
    }
    me_say(log, "%s: written (%s bytes)\n", out, bytes);
    return 0;
}

/* The first four bytes of `path`, or 0 if they cannot be read. */
static uint32_t me_magic(const char *path) {
    uint32_t magic = 0;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    if (read(fd, &magic, sizeof magic) != (ssize_t)sizeof magic) magic = 0;
    close(fd);
    return magic;
}

/* What the pre-pass decided about one slice.
 *
 * ME_SLICE_NOT_64 IS DECIDED BY THE SLICE'S OWN BYTES, never by the
 * fat_arch's declared cputype -- see me_slice_is_64 below. */
enum { ME_SLICE_NOT_64 = 0, ME_SLICE_EDIT = 1, ME_SLICE_OTHER_ARCH = 2 };

/* Everything the fat path's slice callbacks need. */
typedef struct {
    const ms_script *s;
    const char *path, *out;
    FILE *log;
    const unsigned char *selected;   /* per slice: one of the ME_SLICE_* above */
    uint32_t last;                   /* the last selected slice, in arch-table order */
    mr_hits *hits;
    int *renamed;
} me_fat_ctx;

static int me_fat_slice(uint8_t **pbuf, size_t *psize, const mfat_arch *a,
                        uint32_t index, int *changed, void *ctx_) {
    me_fat_ctx *c = (me_fat_ctx *)ctx_;
    char name[32];
    ma_describe(a->cputype, a->cpusubtype, name);
    if (c->selected[index] != ME_SLICE_EDIT) {
        /* Three reasons, and the one a reader needs to tell apart is the
         * third: a slice the arch table calls 64-bit whose bytes are not a
         * 64-bit Mach-O is not "32-bit", and saying so would describe the
         * declaration this code deliberately does not trust. */
        const char *why;
        if (c->selected[index] == ME_SLICE_OTHER_ARCH) why = "not selected by arch";
        else if (a->cputype & CPU_ARCH_ABI64)          why = "not a 64-bit Mach-O";
        else                                           why = "32-bit";
        me_say(c->log, "slice %s: %s; passed through unchanged\n", name, why);
        return 0;
    }
    me_say(c->log, "slice %s:\n", name);
    /* One accumulator per SLICE, never one shared across the container: a
     * slice that disturbed nothing skips its own verify whatever its
     * neighbours did. */
    unsigned disturbed = MREL_NONE;
    int rc = me_statements(pbuf, psize, c->path, c->out, c->s, c->log,
                           c->hits, c->renamed, index == c->last, name, &disturbed);
    if (rc != 0) return rc;
    /* Each slice's own final verification, on the same derived terms as a thin
     * file's: whenever anything it checks was disturbed, and then never
     * subject to MACHO_NO_VERIFY. */
    if (me_verify_applies(*pbuf, *psize, disturbed)) {
        if (mg_plausible(*pbuf, *psize) != 0) {
            me_say(c->log, "drydock-macho-rewrite edit: refused at verification of slice %s; ", name);
            me_say_left(c->log, c->path, c->out);
            return MR_REFUSED;
        }
        me_say(c->log, "slice %s: verified\n", name);
    } else {
        char what[64];
        snprintf(what, sizeof what, "slice %s", name);
        me_say_not_rechecked(c->log, what, disturbed);
    }
    *changed = 1;
    return 0;
}

/* After the new layout is fixed: a slice that moved says so. Its bytes are
 * unchanged if nothing selected it, but where it lives is not. */
static void me_fat_placed(const mfat_arch *a, uint32_t index,
                          uint64_t off, uint64_t size, void *ctx_) {
    me_fat_ctx *c = (me_fat_ctx *)ctx_;
    (void)index; (void)size;
    if (off == a->offset) return;
    char name[32];
    ma_describe(a->cputype, a->cpusubtype, name);
    me_say(c->log, "slice %s: moved from offset 0x%llx to 0x%llx\n", name,
           (unsigned long long)a->offset, (unsigned long long)off);
}

/* Is slice `a` of the container in buf[0..size) a 64-bit Mach-O?
 *
 * THE ARCH TABLE'S DECLARED cputype IS NOT THE ANSWER. A fat_arch may declare
 * one thing over a slice that is another -- lipo never emits that, a truncated
 * or hand-built container can -- and trusting the header over the content is
 * how a rewriter gets a wrong answer about the bytes it is about to edit.
 *
 * mi_wrap, and not a magic comparison of our own, because this is the SAME
 * question src/rewrite.c's fat loop asks (mr_process_thin returns MR_SKIP for
 * exactly `mi_wrap(...) != 0`, and mr_fat_slice passes such a slice through).
 * The two loops have to CLASSIFY alike -- every compat wrapper moved from that
 * one to this one, and a slice one called a 64-bit Mach-O and the other did not
 * would be a rewriter with two answers about the bytes it is editing.
 *
 * CLASSIFY, not decide: the two loops are not the same rewriter. me_run_fat
 * refuses a container in which nothing is left to edit (`nselected == 0`),
 * which mr_process_fat does not, so a container with no 64-bit Mach-O slice at
 * all is refused here and written there. That difference is this function's
 * caller's, not this function's, and tests/change_dylib_test.sh's
 * "two fat loops" block runs both loops over one corpus and pins it as the
 * ONLY one.
 *
 * The declared cputype still decides which ARCH a slice is -- cpusubtype lives
 * nowhere else -- just not whether it is a 64-bit Mach-O. */
static int me_slice_is_64(uint8_t *buf, size_t size, const mfat_arch *a) {
    mi_image im;
    /* mfat_parse already proved this, and this reads raw memory. */
    if ((uint64_t)a->offset + (uint64_t)a->size > (uint64_t)size) return 0;
    return mi_wrap(buf + a->offset, a->size, &im) == 0;
}

static int me_run_fat(const char *path, const char *out, const ms_script *s,
                      FILE *log) {
    /* Read the whole container once. */
    int fd = open(path, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) != 0) {
        if (fd >= 0) close(fd);
        me_say(log, "drydock-macho-rewrite edit: %s: cannot open or read\n", path);
        return MR_FAIL;
    }
    size_t size = (size_t)st.st_size;
    uint8_t *buf = (uint8_t *)malloc(size ? size : 1);
    if (!buf || read(fd, buf, size) != (ssize_t)size) {
        close(fd); free(buf);
        me_say(log, "drydock-macho-rewrite edit: %s: cannot open or read\n", path);
        return MR_FAIL;
    }
    close(fd);

    uint32_t narch; int swap;
    int prc = mfat_parse(buf, size, &narch, &swap);
    if (prc != 0) {
        free(buf);
        if (prc == MFAT_IO_ERROR) {
            me_say(log, "drydock-macho-rewrite edit: out of memory reading %s's arch table\n", path);
            return MR_FAIL;
        }
        me_say(log, "drydock-macho-rewrite edit: %s: malformed fat file; ", path);
        me_say_left(log, path, out);
        return MR_REFUSED;
    }

    /* Which slices the script applies to, and whether it names any the file
     * lacks or cannot edit -- all decided before any slice is touched. */
    unsigned char *selected = (unsigned char *)calloc(narch ? narch : 1, 1);
    size_t nst = s->n ? (size_t)s->n : 1;
    mr_hits *hits = (mr_hits *)calloc(nst, sizeof *hits);
    int *renamed = (int *)calloc(nst, sizeof *renamed);
    if (!selected || !hits || !renamed) {
        me_say(log, "drydock-macho-rewrite edit: out of memory; ");
        me_say_left(log, path, out);
        free(selected); free(hits); free(renamed); free(buf);
        return MR_FAIL;
    }
    char have[256] = "";
    int nselected = 0; uint32_t last = 0;
    for (uint32_t j = 0; j < narch; j++) {
        mfat_arch a; mfat_get(buf, swap, j, &a);
        char name[32]; ma_describe(a.cputype, a.cpusubtype, name);
        size_t hl = strlen(have);
        snprintf(have + hl, sizeof have - hl, "%s%s", j ? ", " : "", name);
        int row = ma_index(a.cputype, a.cpusubtype);
        int is64 = me_slice_is_64(buf, size, &a);
        if (!is64) selected[j] = ME_SLICE_NOT_64;
        else if (!s->arch_mask) selected[j] = ME_SLICE_EDIT;
        else selected[j] = (row >= 0 && (s->arch_mask & (1u << row)))
                               ? ME_SLICE_EDIT : ME_SLICE_OTHER_ARCH;
        if (selected[j] == ME_SLICE_EDIT) { nselected++; last = j; }
    }
    int rc = 0;
    const char *rname; uint32_t rct, rcs;
    for (int r = 0; ma_row(r, &rname, &rct, &rcs); r++) {
        if (!(s->arch_mask & (1u << r))) continue;
        int found = 0, found64 = 0, decl64 = 0;
        for (uint32_t j = 0; j < narch; j++) {
            mfat_arch a; mfat_get(buf, swap, j, &a);
            if (ma_index(a.cputype, a.cpusubtype) == r) {
                found = 1;
                found64 = selected[j] != ME_SLICE_NOT_64;
                decl64 = (a.cputype & CPU_ARCH_ABI64) != 0;
            }
        }
        if (!found) {
            me_say(log, "drydock-macho-rewrite edit: %s has no %s slice (it has: %s); ", path, rname, have);
            rc = MR_REFUSED;
        } else if (!found64) {
            /* Same distinction me_fat_slice's pass-through line draws, and for
             * the same reason: a slice the arch table calls 64-bit whose bytes
             * are not is not a 32-bit slice. */
            me_say(log, "drydock-macho-rewrite edit: %s's %s slice is %s, and statements apply only to "
                        "64-bit slices; ", path, rname,
                        decl64 ? "not a 64-bit Mach-O" : "32-bit");
            rc = MR_REFUSED;
        }
    }
    if (rc == 0 && nselected == 0) {
        me_say(log, "drydock-macho-rewrite edit: %s has no 64-bit slice to edit (it has: %s); ", path, have);
        rc = MR_REFUSED;
    }
    if (rc != 0) {
        me_say_left(log, path, out);
        free(selected); free(hits); free(renamed); free(buf);
        return rc;
    }

    me_fat_ctx ctx = { s, path, out, log, selected, last, hits, renamed };
    int modified = 0;
    rc = mfat_rewrite(&buf, &size, narch, swap, me_fat_slice, me_fat_placed, &ctx, &modified);
    /* me_fat_slice sets *changed for every selected slice, so *modified is
     * always true here -- and it would make no difference if it were not: OUT
     * is the answer, so a successful run writes it whether or not any statement
     * changed anything. */
    (void)modified;
    free(selected); free(hits); free(renamed);
    if (rc != 0) {
        if (rc == MFAT_IO_ERROR || rc == MFAT_MALFORMED) {
            me_say(log, "drydock-macho-rewrite edit: could not lay out %s's slices again; ", path);
            me_say_left(log, path, out);
            rc = (rc == MFAT_IO_ERROR) ? MR_FAIL : MR_REFUSED;
        }
        /* A slice's own failure already printed its refusal line. */
        free(buf);
        return rc;
    }
    /* The container itself, as it will be written. */
    if (mfat_parse(buf, size, &narch, &swap) != 0) {
        me_say(log, "drydock-macho-rewrite edit: the reassembled %s fails validation; ", path);
        me_say_left(log, path, out);
        free(buf);
        return MR_REFUSED;
    }
    me_say(log, "%s: verified\n", path);
    return me_write_once(buf, size, path, out, log);
}

/* mi_open said MI_NOT_MACHO, and me_run has already dispatched every fat
 * container to its own path or refusal: what is left is not an image this
 * tool reads at all. */
static int me_refuse_input(const char *path, FILE *log) {
    me_say(log, "drydock-macho-rewrite edit: %s: not a readable 64-bit Mach-O\n", path);
    return MR_REFUSED;
}

int me_run(const char *path, const char *out, const ms_script *s, const me_opts *o) {
    FILE *log = (o && o->log) ? o->log : stderr;

    /* BEFORE ANYTHING IS READ. `out` is required, and it may not be `path` --
     * the same two mistakes cli/drydock-macho-rewrite.c's bad_out refuses for every verb
     * that names an OUT, refused here as well because me_run is reachable
     * without going through that CLI. wa_write_new would refuse the second at
     * the write, but only after the whole rewrite; MR_FAIL, not MR_REFUSED,
     * because naming one file twice is a mistake about the command rather than a
     * verdict about the image. */
    if (!out) {
        me_say(log, "drydock-macho-rewrite edit: no output file was named\n");
        return MR_FAIL;
    }
    if (wa_is_input(path, out)) {
        me_say(log, "drydock-macho-rewrite edit: %s is %s; drydock-macho-rewrite never writes its input\n", out, path);
        return MR_FAIL;
    }

    uint32_t magic = me_magic(path);
    if (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64) {
        me_say(log, "drydock-macho-rewrite edit: %s is a 64-bit fat container (fat_arch_64), which this "
                    "tool does not read; ", path);
        me_say_left(log, path, out);
        return MR_REFUSED;
    }
    if (magic == FAT_MAGIC || magic == FAT_CIGAM)
        return me_run_fat(path, out, s, log);

    /* Read the image once. */
    mi_image im;
    int mo = mi_open(path, &im);
    if (mo == MI_IO_ERROR) {
        me_say(log, "drydock-macho-rewrite edit: %s: cannot open or read\n", path);
        return MR_FAIL;
    }
    if (mo != 0) return me_refuse_input(path, log);
    /* A thin file has one image, so an `arch` directive that does not name
     * its architecture leaves the script nothing to apply to. */
    if (s->arch_mask) {
        int row = ma_index((uint32_t)im.hdr->cputype, (uint32_t)im.hdr->cpusubtype);
        if (row < 0 || !(s->arch_mask & (1u << row))) {
            char name[32];
            ma_describe((uint32_t)im.hdr->cputype, (uint32_t)im.hdr->cpusubtype, name);
            me_say(log, "drydock-macho-rewrite edit: %s is %s, which the script's arch directives do not "
                        "name; ", path, name);
            me_say_left(log, path, out);
            mi_close(&im);
            return MR_REFUSED;
        }
    }
    size_t size = im.size;
    uint8_t *buf = mi_release(&im);

    /* Apply each statement in order, each to the image the one before it
     * left. The one image is the last selected one, so every statement's
     * "matched nothing" verdict is taken right after it, as it always has
     * been. */
    size_t nst = s->n ? (size_t)s->n : 1;
    mr_hits *hits = (mr_hits *)calloc(nst, sizeof *hits);
    int *renamed = (int *)calloc(nst, sizeof *renamed);
    if (!hits || !renamed) {
        me_say(log, "drydock-macho-rewrite edit: out of memory; ");
        me_say_left(log, path, out);
        free(hits); free(renamed); free(buf);
        return MR_FAIL;
    }
    unsigned disturbed = MREL_NONE;
    int rc = me_statements(&buf, &size, path, out, s, log, hits, renamed, 1, NULL,
                           &disturbed);
    free(hits); free(renamed);
    if (rc != 0) { free(buf); return rc; }

    /* Verify the finished image whenever anything it checks was disturbed, and
     * then never subject to MACHO_NO_VERIFY. The applicability is derived from
     * the relations this image has and what this run was observed to do, so
     * there is no input a CALLER can supply to switch it off -- which is the
     * difference between this and the escape hatch removed during the compat
     * retirement, and the reason the env var is not consulted here.
     * A failure is a refusal -- including an allocation failure inside
     * mg_plausible, which it reports the same way as every other reason it
     * declines (see rewrite.c's comment on that fold).
     *
     * A script with no statements needs no branch of its own here: it runs
     * nothing, so it disturbs nothing, so the gate cannot apply and nothing
     * can say "after statement 0 of 0". */
    if (me_verify_applies(buf, size, disturbed)) {
        if (mg_plausible(buf, size) != 0) {
            me_say(log, "drydock-macho-rewrite edit: refused at verification, after statement %d of %d; ",
                   s->n, s->n);
            me_say_left(log, path, out);
            free(buf);
            return MR_REFUSED;
        }
        me_say(log, "%s: verified\n", path);
    } else {
        me_say_not_rechecked(log, path, disturbed);
    }

    return me_write_once(buf, size, path, out, log);
}
