/* linkedit_order.c -- see linkedit_order.h. */
#include "linkedit_order.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "mach_compat.h"

/* The load commands the checks read, found in one walk. */
typedef struct {
    const mi_image *im;
    const struct segment_command_64 *le;
    int nle;
    const struct dyld_info_command *di;
    int ndi;
    const struct symtab_command *st;
    const struct dysymtab_command *dy;
    const struct twolevel_hints_command *hints;
    const struct linkedit_data_command *split, *fstarts, *dic, *drs, *loh, *sig;
    const struct dylib_command *id;
    int nid;
} mlo_cmds;

static void mlo_vadd(mlo_verdict *v, int kind, int newer, int order, const char *fmt,
                     va_list ap) {
    if (v->n == MLO_MAX) { v->dropped++; return; }
    mlo_finding *f = &v->f[v->n++];
    vsnprintf(f->text, sizeof f->text, fmt, ap);
    f->kind = kind;
    f->newer = newer;
    f->order = order;
    if (kind == MLO_REFUSES && v->refusal < 0) v->refusal = v->n - 1;
}

static void mlo_add(mlo_verdict *v, int kind, int newer, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
static void mlo_add(mlo_verdict *v, int kind, int newer, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    mlo_vadd(v, kind, newer, 0, fmt, ap);
    va_end(ap);
}

/* A refusal about where the pieces lie. */
static void mlo_place(mlo_verdict *v, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void mlo_place(mlo_verdict *v, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    mlo_vadd(v, MLO_REFUSES, 0, 1, fmt, ap);
    va_end(ap);
}

static int mlo_collect(const struct load_command *lc, void *ctx_) {
    mlo_cmds *c = (mlo_cmds *)ctx_;
    switch (lc->cmd) {
    case LC_SEGMENT_64: {
        const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
        if (strncmp(s->segname, "__LINKEDIT", 16) == 0) {
            if (!c->le) c->le = s;
            c->nle++;
        }
        break;
    }
    case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY:
        if (!c->di) c->di = (const struct dyld_info_command *)lc;
        c->ndi++;
        break;
    case LC_SYMTAB:
        if (!c->st) c->st = (const struct symtab_command *)lc;
        break;
    case LC_DYSYMTAB:
        if (!c->dy) c->dy = (const struct dysymtab_command *)lc;
        break;
    case LC_TWOLEVEL_HINTS:
        if (!c->hints) c->hints = (const struct twolevel_hints_command *)lc;
        break;
    case LC_SEGMENT_SPLIT_INFO:
        if (!c->split) c->split = (const struct linkedit_data_command *)lc;
        break;
    case LC_FUNCTION_STARTS:
        if (!c->fstarts) c->fstarts = (const struct linkedit_data_command *)lc;
        break;
    case LC_DATA_IN_CODE:
        if (!c->dic) c->dic = (const struct linkedit_data_command *)lc;
        break;
    case LC_DYLIB_CODE_SIGN_DRS:
        if (!c->drs) c->drs = (const struct linkedit_data_command *)lc;
        break;
    case LC_LINKER_OPTIMIZATION_HINT:
        if (!c->loh) c->loh = (const struct linkedit_data_command *)lc;
        break;
    case LC_CODE_SIGNATURE:
        if (!c->sig) c->sig = (const struct linkedit_data_command *)lc;
        break;
    case LC_ID_DYLIB:
        if (!c->id) c->id = (const struct dylib_command *)lc;
        c->nid++;
        break;
    }
    return 0;
}

/* check_object (checkout.c:75-216), less the duplicates the ofile loop
 * refuses first. */
static void mlo_check_object(const mlo_cmds *c, mlo_verdict *v) {
    const struct mach_header_64 *h = c->im->hdr;
    if (c->ndi > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one LC_DYLD_INFO load command)");
    if (c->nle > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one __LINKEDITsegment)");
    if (c->nid > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one LC_ID_DYLIB load command)");
    if ((h->filetype == MH_DYLIB || (h->filetype == MH_DYLIB_STUB && h->ncmds > 0)) && !c->id)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (no LC_ID_DYLIB load command in %s file)",
                h->filetype == MH_DYLIB ? "MH_DYLIB" : "MH_DYLIB_STUB");
    if (c->hints) {
        if (!c->dy && c->hints->nhints != 0)
            mlo_add(v, MLO_REFUSES, 0, "malformed file (LC_TWOLEVEL_HINTS load command present "
                    "without an LC_DYSYMTAB load command)");
        if (c->dy && c->hints->nhints != 0 && c->hints->nhints != c->dy->nundefsym)
            mlo_add(v, MLO_REFUSES, 0, "malformed file (LC_TWOLEVEL_HINTS load command's nhints "
                    "does not match LC_DYSYMTAB load command's nundefsym)");
    }
}

static uint32_t mlo_rnd(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }


/* One piece of dyld_order's walk: `off` must be the running offset. On a
 * mismatch the walk goes on from where the piece really is, so each later
 * piece is judged on its own. */
static uint32_t mlo_at(mlo_verdict *v, uint32_t offset, uint32_t off, uint32_t size,
                       const char *what) {
    if (off != offset) {
        mlo_place(v, "file not in an order that can be processed (%s)", what);
        return off + size;
    }
    return offset + size;
}

#define MLO_ORDER(what) mlo_place(v, "file not in an order that can be processed (%s)", what)

/* dyld_order (checkout.c:313-560), rule for rule. */
static uint32_t mlo_dyld_order(const mlo_cmds *c, mlo_verdict *v) {
    const struct dysymtab_command *dy = c->dy;
    const struct symtab_command *st = c->st;
    uint32_t size = (uint32_t)c->im->size, offset, rounded, isym, pad = 0;
    if (!c->le) {
        mlo_place(v, "malformed file (no __LINKEDIT segment)");
        return 0;
    }
    if (c->le->filesize != 0 && c->le->fileoff + c->le->filesize != size)
        mlo_place(v, "the __LINKEDIT segment does not cover the end of the file (can't be processed)");
    offset = (uint32_t)c->le->fileoff;
    if (c->di) {
        const struct dyld_info_command *di = c->di;
        if (di->rebase_off != 0) {
            if (di->rebase_off != offset) MLO_ORDER("dyld_info out of place");
        } else if (di->bind_off != 0) {
            if (di->bind_off != offset) MLO_ORDER("dyld_info out of place");
        } else if (di->export_off != 0) {
            if (di->export_off != offset && di->weak_bind_size != 0 && di->lazy_bind_size != 0)
                MLO_ORDER("dyld_info out of place");
        }
        if (di->export_size != 0)         offset = di->export_off + di->export_size;
        else if (di->lazy_bind_size != 0) offset = di->lazy_bind_off + di->lazy_bind_size;
        else if (di->weak_bind_size != 0) offset = di->weak_bind_off + di->weak_bind_size;
        else if (di->bind_size != 0)      offset = di->bind_off + di->bind_size;
        else if (di->rebase_size != 0)    offset = di->rebase_off + di->rebase_size;
    }
    if (dy->nlocrel != 0)
        offset = mlo_at(v, offset, dy->locreloff, dy->nlocrel * 8, "local relocation entries out of place");
    /* A zero dataoff skips the check for these three, but not the advance. */
    static const char *const skip_what[3] = { "split info data out of place",
        "function starts data out of place", "data in code info out of place" };
    const struct linkedit_data_command *skip[3] = { c->split, c->fstarts, c->dic };
    for (int k = 0; k < 3; k++) {
        if (!skip[k]) continue;
        if (skip[k]->dataoff != 0 && skip[k]->dataoff != offset) {
            MLO_ORDER(skip_what[k]);
            offset = skip[k]->dataoff + skip[k]->datasize;
        } else {
            offset += skip[k]->datasize;
        }
    }
    if (c->drs) offset = mlo_at(v, offset, c->drs->dataoff, c->drs->datasize,
                                "code signing DRs info out of place");
    if (c->loh) offset = mlo_at(v, offset, c->loh->dataoff, c->loh->datasize,
                                "linker optimization hint info out of place");
    if (st && st->nsyms != 0)
        offset = mlo_at(v, offset, st->symoff, st->nsyms * 16, "symbol table out of place");
    isym = 0;
    if (dy->nlocalsym != 0) {
        if (dy->ilocalsym != isym) MLO_ORDER("local symbols out of place");
        isym += dy->nlocalsym;
    }
    if (dy->nextdefsym != 0) {
        if (dy->iextdefsym != isym) MLO_ORDER("externally defined symbols out of place");
        isym += dy->nextdefsym;
    }
    if (dy->nundefsym != 0) {
        if (dy->iundefsym != isym) MLO_ORDER("undefined symbols out of place");
        isym += dy->nundefsym;
    }
    if (c->hints && c->hints->nhints != 0)
        offset = mlo_at(v, offset, c->hints->offset, c->hints->nhints * 4, "hints table out of place");
    if (dy->nextrel != 0)
        offset = mlo_at(v, offset, dy->extreloff, dy->nextrel * 8,
                        "external relocation entries out of place");
    if (dy->nindirectsyms != 0)
        offset = mlo_at(v, offset, dy->indirectsymoff, dy->nindirectsyms * 4,
                        "indirect symbol table out of place");
    rounded = (dy->nindirectsyms % 2) ? mlo_rnd(offset, 8) : offset;
    /* Only the first of these that is present may take the rounding. */
    struct { uint32_t n, off, size; const char *what; } tail[4] = {
        { dy->ntoc, dy->tocoff, dy->ntoc * 8, "table of contents out of place" },
        { dy->nmodtab, dy->modtaboff, dy->nmodtab * 56, "module table out of place" },
        { dy->nextrefsyms, dy->extrefsymoff, dy->nextrefsyms * 4, "reference table out of place" },
        { st ? st->strsize : 0, st ? st->stroff : 0, st ? st->strsize : 0, "string table out of place" },
    };
    for (int k = 0; k < 4; k++) {
        if (tail[k].n == 0) continue;
        if (tail[k].off == offset) {
            offset += tail[k].size;
            rounded = offset;
        } else if (tail[k].off == rounded) {
            pad = rounded - offset;
            rounded += tail[k].size;
            offset = rounded;
        } else {
            MLO_ORDER(tail[k].what);
            offset = rounded = tail[k].off + tail[k].size;
        }
    }
    if (c->sig) {
        rounded = mlo_rnd(rounded, 16);
        if (c->sig->dataoff != rounded) {
            MLO_ORDER("code signature data out of place");
            rounded = c->sig->dataoff;
        }
        rounded += c->sig->datasize;
        offset = rounded;
    }
    if (offset != size && rounded != size)
        MLO_ORDER("link edit information does not fill the __LINKEDIT segment");
    return pad;
}

void mlo_check(const mi_image *im, mlo_verdict *v) {
    mlo_cmds c;
    memset(v, 0, sizeof *v);
    v->refusal = -1;
    memset(&c, 0, sizeof c);
    c.im = im;
    mi_each_lc(im, mlo_collect, &c);
    mlo_check_object(&c, v);
    if (c.dy && (im->hdr->filetype == MH_DYLIB || (im->hdr->flags & MH_DYLDLINK)))
        mlo_dyld_order(&c, v);
}
