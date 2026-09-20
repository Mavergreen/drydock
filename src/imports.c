/* imports.c -- the read-only bind-stream reporter. See imports.h. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

#include "imports.h"
#include "image.h"
#include "fat.h"
#include "ordinals.h"
#include "arch_names.h"
#include "mach_compat.h"

/* Per-slice state, filled by one mi_each_lc walk (collect_lc) and consumed
 * by two later passes (validate the bounds, then emit the rows): the
 * ordinal->(install_name, kind) table exactly mo_map_build builds it --
 * every mo_is_ordinal_lc command counts, in load-command order, 1-based --
 * plus the one LC_DYLD_INFO(_ONLY) command (if any) and whether
 * LC_DYLD_CHAINED_FIXUPS was seen. */
struct slice_ctx {
    const char *arch;
    const char *names[MO_MAX_DYLIBS + 1];
    uint32_t    cmds[MO_MAX_DYLIBS + 1];
    int         n;
    const struct dyld_info_command *di;
    int         chained;
};

static int collect_lc(const struct load_command *lc, void *vctx) {
    struct slice_ctx *s = vctx;
    if (mo_is_ordinal_lc(lc->cmd)) {
        if (s->n < MO_MAX_DYLIBS) {
            const struct dylib_command *dc = (const struct dylib_command *)lc;
            s->n++;
            s->names[s->n] = mo_lc_str_at(lc, dc->dylib.name.offset);
            s->cmds[s->n]  = lc->cmd;
        }
        /* Past MO_MAX_DYLIBS (the format's own ceiling, MAX_LIBRARY_ORDINAL):
         * silently stop growing the table, same as mo_map_build's own bound.
         * A bind stream can never name an ordinal beyond what this image
         * itself declared, so nothing downstream needs the overflow. */
    } else if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        s->di = (const struct dyld_info_command *)lc;
    } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) {
        s->chained = 1;
    }
    return 0;   /* visit every command; nothing here ever needs to stop early */
}

/* One bind/weak-bind/lazy-bind stream's offset, size and the name this
 * module reports it under -- shared between the bounds pass and the
 * emission pass so the two can never disagree about which three streams a
 * slice carries. */
struct mimp_stream { uint32_t off, size; const char *what; };

static void mimp_streams(const struct dyld_info_command *di, struct mimp_stream out[3]) {
    out[0].off = di->bind_off;      out[0].size = di->bind_size;      out[0].what = "bind";
    out[1].off = di->weak_bind_off; out[1].size = di->weak_bind_size; out[1].what = "weak bind";
    out[2].off = di->lazy_bind_off; out[2].size = di->lazy_bind_size; out[2].what = "lazy bind";
}

/* Pass 1 for one slice: build the ordinal table, and refuse (MIMP_REFUSED,
 * with a message on stderr) rather than proceed if this slice cannot be
 * reported on at all -- LC_DYLD_CHAINED_FIXUPS present, or a bind/weak-bind/
 * lazy-bind offset+size pair that does not fit inside the slice. Nothing is
 * emitted to `fn` here; see imports.h's own comment on mimp_report for why
 * every bound is checked before any row is. */
static int mimp_validate_slice(const mi_image *im, const char *arch, struct slice_ctx *s) {
    memset(s, 0, sizeof *s);
    s->arch = arch;
    mi_each_lc(im, collect_lc, s);

    if (s->chained) {
        fprintf(stderr, "machorewrite imports: %s: uses LC_DYLD_CHAINED_FIXUPS; its "
                        "import table is not a bind-opcode stream this walk reads. "
                        "Convert first with `fixups set classic`, then report imports "
                        "against the converted output.\n", arch);
        return MIMP_REFUSED;
    }
    if (s->di) {
        struct mimp_stream streams[3];
        mimp_streams(s->di, streams);
        for (int i = 0; i < 3; i++) {
            if (streams[i].size == 0) continue;
            if (!mo_fits(streams[i].off, streams[i].size, im->size)) {
                fprintf(stderr, "machorewrite imports: %s: %s stream (offset %u, %u "
                                "bytes) does not fit within the %zu-byte slice; "
                                "refusing\n",
                        arch, streams[i].what, streams[i].off, streams[i].size, im->size);
                return MIMP_REFUSED;
            }
        }
    }
    return MIMP_OK;
}

struct emit_ctx {
    const struct slice_ctx *s;
    mimp_row_fn             fn;
    void                   *ctx;
};

static void emit(const mo_bind_state *st, void *vctx) {
    struct emit_ctx *e = vctx;
    const struct slice_ctx *s = e->s;
    mimp_row row;
    row.arch    = s->arch;
    row.ordinal = st->ordinal;
    row.symbol  = st->symbol ? st->symbol : "-";
    row.weak    = st->weak;
    if (st->ordinal >= 1 && st->ordinal <= s->n) {
        row.kind         = mo_kind_name(s->cmds[st->ordinal]);
        row.install_name = s->names[st->ordinal] ? s->names[st->ordinal] : "-";
    } else {
        /* A special ordinal (self/exe/flat/unknown) names no library, and
         * an ordinal past what this slice's own load commands declared is a
         * malformed stream reported as-is rather than resolved -- the same
         * "refuse to guess" stance ordinals.h documents for mo_bind_walk,
         * applied here to a report instead of a rewrite: the row still
         * goes out, naming what it can. */
        row.kind = "-";
        row.install_name = "-";
    }
    e->fn(&row, e->ctx);
}

/* Pass 2 for one slice, already validated by mimp_validate_slice: walk each
 * non-empty stream with mo_bind_observe and hand every DO_BIND-family
 * opcode to `fn` via emit(). Bounds were already proven in pass 1, so the
 * only way this can still fail is a stream whose OPCODES are malformed --
 * see imports.h's own comment on mimp_report for that distinction. */
static int mimp_emit_slice(const mi_image *im, const struct slice_ctx *s,
                           mimp_row_fn fn, void *ctx) {
    if (!s->di) return MIMP_OK;   /* no dyld info at all: zero rows */
    struct emit_ctx e = { s, fn, ctx };
    struct mimp_stream streams[3];
    mimp_streams(s->di, streams);
    for (int i = 0; i < 3; i++) {
        if (streams[i].size == 0) continue;
        if (mo_bind_observe(im->buf + streams[i].off, streams[i].size,
                            streams[i].what, emit, &e) != 0)
            return MIMP_REFUSED;
    }
    return MIMP_OK;
}

int mimp_report(const uint8_t *buf, size_t size, mimp_row_fn fn, void *ctx) {
    if (size < sizeof(uint32_t)) return MIMP_REFUSED;
    uint32_t magic;
    memcpy(&magic, buf, sizeof magic);

    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        uint32_t narch;
        int swapped;
        if (mfat_parse(buf, size, &narch, &swapped) != 0) return MIMP_REFUSED;
        if (narch == 0) return MIMP_OK;   /* no slices at all: zero rows, not a refusal */

        /* Per-slice state, kept alive across both passes: `ims`/`scs` for
         * every slice mi_wrap could read, `readable` marking which (an
         * unreadable slice is skipped, not fatal -- see imports.h), and
         * `names` holding each readable slice's arch-name bytes, since
         * slice_ctx.arch is a pointer into it that pass 2 still reads. */
        mi_image *ims = calloc(narch, sizeof *ims);
        struct slice_ctx *scs = calloc(narch, sizeof *scs);
        int *readable = calloc(narch, sizeof *readable);
        char (*names)[32] = calloc(narch, sizeof *names);
        int rc = MIMP_OK;

        if (!ims || !scs || !readable || !names) {
            fprintf(stderr, "machorewrite imports: out of memory\n");
            rc = MIMP_REFUSED;
        } else {
            /* Pass 1, over every slice: wrap what mi_wrap can read, and
             * validate it. The first validation failure stops this pass --
             * matching mr_process_fat's MR_ERROR handling of a slice its
             * rewrite path cannot honour -- so pass 2 below never starts,
             * and nothing has been emitted to `fn` yet for any slice. */
            for (uint32_t i = 0; i < narch && rc == MIMP_OK; i++) {
                mfat_arch a;
                mfat_get(buf, swapped, i, &a);
                /* mi_wrap takes a non-const buffer even though nothing here
                 * ever writes through it -- image.h has no observe-only wrap
                 * the way mo_bind_observe is ordinals.h's one-cast entry
                 * point for the bind walk itself. This is the same
                 * discipline (cast once, here, documented, never used to
                 * write) applied to the one place this module still needs
                 * it. */
                if (mi_wrap((uint8_t *)buf + a.offset, a.size, &ims[i]) != 0) {
                    readable[i] = 0;
                    continue;
                }
                readable[i] = 1;
                ma_describe(a.cputype, a.cpusubtype, names[i]);
                rc = mimp_validate_slice(&ims[i], names[i], &scs[i]);
            }

            /* Pass 2, only once every slice pass 1 looked at has cleared:
             * emit every row, slice by slice, in fat-arch-table order. */
            for (uint32_t i = 0; i < narch && rc == MIMP_OK; i++) {
                if (!readable[i]) continue;
                rc = mimp_emit_slice(&ims[i], &scs[i], fn, ctx);
            }

            for (uint32_t i = 0; i < narch; i++)
                if (readable[i]) mi_close(&ims[i]);
        }

        free(ims); free(scs); free(readable); free(names);
        return rc;
    }

    /* Thin: one slice, arch "-". Same one-cast discipline as the fat path's
     * mi_wrap call above. */
    mi_image im;
    if (mi_wrap((uint8_t *)buf, size, &im) != 0) return MIMP_REFUSED;

    struct slice_ctx s;
    int rc = mimp_validate_slice(&im, "-", &s);
    if (rc == MIMP_OK) rc = mimp_emit_slice(&im, &s, fn, ctx);
    mi_close(&im);
    return rc;
}
