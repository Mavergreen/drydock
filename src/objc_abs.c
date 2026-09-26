/* mma_ -- see objc_abs.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "objc_abs.h"
#include "linkedit.h"
#include "rewrite.h"
#include "mach_compat.h"

#define WHAT "drydock-macho-rewrite: objc-methods set absolute"

static int mma_fail(char *why, size_t whysz, int code, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
static int mma_fail(char *why, size_t whysz, int code, const char *fmt, ...) {
    va_list ap;
    if (why && whysz) {
        va_start(ap, fmt);
        vsnprintf(why, whysz, fmt, ap);
        va_end(ap);
    }
    return code;
}

/* ---- layout ------------------------------------------------------------- */

typedef struct { mma_seg *segs; int n, max; } mma_seg_ctx;

static int mma_seg_lc(const struct load_command *lc, void *ctx_) {
    mma_seg_ctx *c = ctx_;
    const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    if (c->n == c->max) { c->n = -1; return 1; }
    memcpy(c->segs[c->n].name, sc->segname, 16);
    c->segs[c->n].vmaddr = sc->vmaddr;
    c->segs[c->n].vmsize = sc->vmsize;
    c->segs[c->n].fileoff = sc->fileoff;
    c->segs[c->n].filesize = sc->filesize;
    c->segs[c->n].initprot = (uint32_t)sc->initprot;
    c->n++;
    return 0;
}

int mma_segments(const mi_image *im, mma_seg *segs, int max) {
    mma_seg_ctx c = { segs, 0, max };
    mi_each_lc(im, mma_seg_lc, &c);
    return c.n;
}

static int mma_is_linkedit(const mma_seg *s) { return strncmp(s->name, "__LINKEDIT", 16) == 0; }

int mma_layout_check(const mma_seg *segs, int n, uint64_t file_size, mma_layout *lay,
                     char *why, size_t whysz) {
    int i;
    memset(lay, 0, sizeof *lay);
    if (n < 0)
        return mma_fail(why, whysz, MMA_REFUSED, "the image has more than %d segments", MML_MAX_SEGS);
    if (n == 1 && mma_is_linkedit(&segs[0]))
        return mma_fail(why, whysz, MMA_REFUSED, "there is no segment before __LINKEDIT to hold the lists");
    if (n < 2 || !mma_is_linkedit(&segs[n - 1])) {
        for (i = 0; i < n; i++)
            if (mma_is_linkedit(&segs[i]))
                return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT is not the last segment");
        return mma_fail(why, whysz, MMA_REFUSED, "the image has no __LINKEDIT to follow the lists");
    }
    const mma_seg *d = &segs[n - 2], *l = &segs[n - 1];
    if (n - 2 > 15)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s, the segment before __LINKEDIT, is segment "
                        "%d, and a rebase opcode names only segments 0 to 15", d->name, n - 2);
    if (!(d->initprot & VM_PROT_WRITE))
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s, the segment before __LINKEDIT, is not "
                        "writable, and the runtime writes into method lists", d->name);
    if (d->filesize > d->vmsize)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s has more file bytes than vm bytes", d->name);
    if (d->vmaddr > l->vmaddr || d->vmsize != l->vmaddr - d->vmaddr)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s, 0x%llx bytes at 0x%llx in memory, does not "
                        "end where __LINKEDIT begins, at 0x%llx", d->name,
                        (unsigned long long)d->vmsize, (unsigned long long)d->vmaddr,
                        (unsigned long long)l->vmaddr);
    for (i = 0; i < n - 2; i++)
        if (segs[i].vmaddr > l->vmaddr || segs[i].vmsize > l->vmaddr - segs[i].vmaddr)
            return mma_fail(why, whysz, MMA_REFUSED, "%.16s, 0x%llx bytes at 0x%llx in memory, lies "
                            "above __LINKEDIT's start at 0x%llx, where __LINKEDIT would move",
                            segs[i].name, (unsigned long long)segs[i].vmsize,
                            (unsigned long long)segs[i].vmaddr, (unsigned long long)l->vmaddr);
    if (d->fileoff > l->fileoff || d->filesize != l->fileoff - d->fileoff)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s, 0x%llx bytes at file offset 0x%llx, does "
                        "not end where __LINKEDIT begins, at 0x%llx", d->name,
                        (unsigned long long)d->filesize, (unsigned long long)d->fileoff,
                        (unsigned long long)l->fileoff);
    if (l->fileoff > file_size || l->filesize != file_size - l->fileoff)
        return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT, 0x%llx bytes at file offset 0x%llx, "
                        "does not end the image: the image is 0x%llx bytes",
                        (unsigned long long)l->filesize, (unsigned long long)l->fileoff,
                        (unsigned long long)file_size);
    if (d->vmsize - d->filesize > UINT32_MAX)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s has 0x%llx bytes of zero fill, too many to "
                        "make file bytes", d->name, (unsigned long long)(d->vmsize - d->filesize));
    if ((d->vmaddr + d->vmsize) % MMA_PAGE || (l->fileoff + d->vmsize - d->filesize) % MMA_PAGE)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s does not end on a page boundary", d->name);
    lay->d = n - 2;
    lay->l = n - 1;
    memcpy(lay->dname, d->name, 16);
    lay->list_va = d->vmaddr + d->vmsize;
    lay->insert = l->fileoff;
    lay->z = d->vmsize - d->filesize;
    return MMA_OK;
}

typedef struct {
    const mma_layout *lay;
    uint64_t s, r;
    int idx;
    struct dyld_info_command *di;
} mma_edit_ctx;

static int mma_edit_lc(const struct load_command *lc, void *ctx_) {
    mma_edit_ctx *c = ctx_;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        c->di = (struct dyld_info_command *)lc;
        return 0;
    }
    if (lc->cmd != LC_SEGMENT_64) return 0;
    struct segment_command_64 *sc = (struct segment_command_64 *)lc;
    if (c->idx == c->lay->d) {
        sc->vmsize += c->s;
        sc->filesize = sc->vmsize;
    } else if (c->idx == c->lay->l) {
        uint64_t need;
        sc->vmaddr += c->s;
        sc->fileoff += c->lay->z + c->s;
        sc->filesize += c->r;
        need = (sc->filesize + MMA_PAGE - 1) & ~(uint64_t)(MMA_PAGE - 1);
        if (sc->vmsize < need) sc->vmsize = need;
    }
    c->idx++;
    return 0;
}

static int mma_find_info(const struct load_command *lc, void *ctx_) {
    if (lc->cmd != LC_DYLD_INFO && lc->cmd != LC_DYLD_INFO_ONLY) return 0;
    *(const struct dyld_info_command **)ctx_ = (const struct dyld_info_command *)lc;
    return 1;
}

typedef struct { int ninfo; uint32_t unmoved; } mma_scan_ctx;

/* Counts LC_DYLD_INFO[_ONLY]s and notes the first command whose file offset
 * ml_bump_all leaves alone. */
static int mma_scan_lc(const struct load_command *lc, void *ctx_) {
    mma_scan_ctx *c = ctx_;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) c->ninfo++;
    if ((lc->cmd == LC_NOTE || lc->cmd == LC_ATOM_INFO) && !c->unmoved) c->unmoved = lc->cmd;
    return 0;
}

int mma_insert(const mi_image *im, const mma_layout *lay, const uint8_t *lists,
               uint64_t lists_len, uint64_t s, const uint8_t *stream, uint32_t r,
               uint8_t **out, size_t *outsz, char *why, size_t whysz) {
    const struct dyld_info_command *odi = NULL;
    mma_scan_ctx sc = { 0, 0 };
    uint64_t grow, at;
    uint8_t *nb;
    mi_image nim;
    mma_edit_ctx c;

    *out = NULL;
    *outsz = 0;
    if (s % MMA_PAGE || lists_len > s || r % 16)
        return mma_fail(why, whysz, MMA_REFUSED, "internal error: %llu list bytes in %llu, "
                        "%u stream bytes", (unsigned long long)lists_len, (unsigned long long)s, r);
    if (lay->z > UINT32_MAX || s > UINT32_MAX || lay->insert > im->size)
        return mma_fail(why, whysz, MMA_REFUSED, "internal error: 0x%llx zero-fill and 0x%llx list "
                        "bytes at 0x%llx in a 0x%llx-byte image", (unsigned long long)lay->z,
                        (unsigned long long)s, (unsigned long long)lay->insert,
                        (unsigned long long)im->size);
    if (lay->insert < sizeof(struct mach_header_64) + im->hdr->sizeofcmds)
        return mma_fail(why, whysz, MMA_REFUSED, "internal error: the insertion point 0x%llx lies "
                        "inside the header or load commands, which end at 0x%llx",
                        (unsigned long long)lay->insert,
                        (unsigned long long)(sizeof(struct mach_header_64) + im->hdr->sizeofcmds));
    grow = lay->z + s + r;
    mi_each_lc(im, mma_find_info, &odi);
    mi_each_lc(im, mma_scan_lc, &sc);
    if (!odi)
        return mma_fail(why, whysz, MMA_REFUSED, "no LC_DYLD_INFO: there is no rebase stream to extend");
    if (sc.ninfo > 1)
        return mma_fail(why, whysz, MMA_REFUSED, "the image has %d LC_DYLD_INFO commands, and only "
                        "one rebase stream can be replaced", sc.ninfo);
    if (sc.unmoved)
        return mma_fail(why, whysz, MMA_REFUSED, "%s carries a file offset (%s) this tool does not "
                        "verify or re-base", sc.unmoved == LC_NOTE ? "LC_NOTE" : "LC_ATOM_INFO",
                        sc.unmoved == LC_NOTE ? "note_command.offset" : "dataoff");
    if (odi->rebase_size && (odi->rebase_off > im->size || odi->rebase_size > im->size - odi->rebase_off))
        return mma_fail(why, whysz, MMA_REFUSED, "the rebase stream, 0x%x bytes at 0x%x, runs past "
                        "the end of the file", odi->rebase_size, odi->rebase_off);
    if (odi->rebase_size && odi->rebase_off < lay->insert)
        return mma_fail(why, whysz, MMA_REFUSED, "the rebase stream is not in __LINKEDIT");
    if (im->size + grow > UINT32_MAX)
        return mma_fail(why, whysz, MMA_REFUSED, "the image would pass 4GB");
    if (!(nb = calloc(1, im->size + grow)))
        return mma_fail(why, whysz, MMA_NOMEM, "out of memory");
    at = lay->insert;
    memcpy(nb, im->buf, at);
    memcpy(nb + at + lay->z, lists, lists_len);
    memcpy(nb + at + lay->z + s, stream, r);
    memcpy(nb + at + grow, im->buf + at, im->size - at);
    if (mi_wrap(nb, im->size + grow, &nim) != 0) {
        free(nb);
        return mma_fail(why, whysz, MMA_REFUSED, "internal error: the new image does not wrap");
    }
    memset(&c, 0, sizeof c);
    c.lay = lay;
    c.s = s;
    c.r = r;
    mi_each_lc(&nim, mma_edit_lc, &c);
    if (ml_bump_all(&nim, (uint32_t)at, (uint32_t)grow) != 0) {
        free(nb);
        return mma_fail(why, whysz, MMA_REFUSED, "a __LINKEDIT file offset would pass 4GB");
    }
    if (!c.di || (c.di->rebase_size && (c.di->rebase_off > nim.size ||
                                         c.di->rebase_size > nim.size - c.di->rebase_off))) {
        free(nb);
        return mma_fail(why, whysz, MMA_REFUSED, "internal error: the moved rebase stream is not "
                        "in the new image");
    }
    if (c.di->rebase_size) memset(nb + c.di->rebase_off, 0, c.di->rebase_size);
    c.di->rebase_off = (uint32_t)(at + lay->z + s);
    c.di->rebase_size = r;
    *out = nb;
    *outsz = im->size + grow;
    return MMA_OK;
}

/* ---- conversion ---------------------------------------------------------- */

typedef struct { uint64_t va; uint32_t i; } mma_pair;

static int mma_pair_cmp(const void *a_, const void *b_) {
    const mma_pair *a = a_, *b = b_;
    if (a->va != b->va) return a->va < b->va ? -1 : 1;
    return a->i < b->i ? -1 : a->i > b->i;
}

/* first[i]: the first ref naming the list ref i names. */
static int mma_firsts(const mml_walk *w, uint32_t *first) {
    mma_pair *p = malloc((w->n ? w->n : 1) * sizeof *p);
    uint32_t i, g;
    if (!p) return -1;
    for (i = 0; i < w->n; i++) { p[i].va = w->refs[i].list_va; p[i].i = i; }
    qsort(p, w->n, sizeof *p, mma_pair_cmp);
    for (i = 0, g = 0; i < w->n; i++) {
        if (i && p[i].va != p[i - 1].va) g = i;
        first[p[i].i] = p[g].i;
    }
    free(p);
    return 0;
}

static void mma_put64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }

int mma_room(const mml_walk *w, const uint32_t *first, uint64_t list_va, uint64_t *new_va,
             uint64_t *total, size_t *nslots, char *why, size_t whysz) {
    *total = 0;
    *nslots = 0;
    for (uint32_t i = 0; i < w->n; i++) {
        if (first[i] != i || !(w->refs[i].header & MML_RELATIVE)) continue;
        new_va[i] = list_va + *total;
        *total += 8 + (uint64_t)MML_ABS_ENTSIZE * w->refs[i].count;
        if (*total > UINT32_MAX)
            return mma_fail(why, whysz, MMA_REFUSED, "the absolute method lists would pass 4GB");
        *nslots += 3 * (size_t)w->refs[i].count;
    }
    return MMA_OK;
}

void mma_out_free(mma_out *o) {
    free(o->buf);
    o->buf = NULL;
    o->size = 0;
}

int mma_build(const mi_image *im, mma_out *o, char *why, size_t whysz) {
    const struct dyld_info_command *di = NULL;
    mma_scan_ctx scan = { 0, 0 };
    mma_seg segs[MML_MAX_SEGS];
    mml_walk w;
    mml_resolver res;
    mrb_set old;
    mrb_buf stream;
    mrb_slot *slots = NULL;
    uint32_t *first = NULL, i, e;
    size_t nslots = 0;
    uint64_t *new_va = NULL, total = 0, at;
    uint8_t *lists = NULL, zero[16] = { 0 };
    int nsegs, rc;

    memset(o, 0, sizeof *o);
    memset(&stream, 0, sizeof stream);
    memset(&old, 0, sizeof old);
    if (im->hdr->cputype != CPU_TYPE_X86_64)
        return mma_fail(why, whysz, MMA_REFUSED, "the image is not x86_64, the only architecture 10.9 runs");
    rc = mml_walk_image(im, &w);
    if (rc != MML_OK)
        return mma_fail(why, whysz, rc == MML_NOMEM ? MMA_NOMEM : MMA_REFUSED, "%s", w.why);
    if (w.relative == 0) {
        mml_walk_free(&w);
        return MMA_NOTHING;
    }
    mi_each_lc(im, mma_find_info, &di);
    mi_each_lc(im, mma_scan_lc, &scan);
    if (!di) {
        mml_walk_free(&w);
        return mma_fail(why, whysz, MMA_REFUSED, "no LC_DYLD_INFO: there is no rebase stream to extend");
    }
    if (scan.ninfo > 1) {
        mml_walk_free(&w);
        return mma_fail(why, whysz, MMA_REFUSED, "the image has %d LC_DYLD_INFO commands, and only "
                        "one rebase stream can be replaced", scan.ninfo);
    }
    if (di->rebase_size && (di->rebase_off > im->size || di->rebase_size > im->size - di->rebase_off)) {
        mml_walk_free(&w);
        return mma_fail(why, whysz, MMA_REFUSED, "the rebase stream, 0x%x bytes at 0x%x, runs past "
                        "the end of the file", di->rebase_size, di->rebase_off);
    }
    nsegs = mma_segments(im, segs, MML_MAX_SEGS);
    if ((rc = mma_layout_check(segs, nsegs, im->size, &o->lay, why, whysz)) != MMA_OK) {
        mml_walk_free(&w);
        return rc;
    }
    if ((rc = mml_resolver_open(im, &res, why, whysz)) != MML_OK) {
        mml_walk_free(&w);
        return rc == MML_NOMEM ? MMA_NOMEM : MMA_REFUSED;
    }
    rc = MMA_NOMEM;
    if (!(first = malloc(w.n * sizeof *first)) || !(new_va = calloc(w.n, sizeof *new_va)) ||
        mma_firsts(&w, first) != 0) {
        mma_fail(why, whysz, MMA_NOMEM, "out of memory");
        goto done;
    }
    rc = MMA_REFUSED;
    for (i = 0; i < w.n; i++) {
        if (w.refs[i].slot_off >= o->lay.insert) {
            mma_fail(why, whysz, MMA_REFUSED, "the method-list pointer at file offset 0x%llx lies "
                     "in __LINKEDIT, which the conversion moves", (unsigned long long)w.refs[i].slot_off);
            goto done;
        }
        if (!(w.refs[i].header & MML_RELATIVE) && w.refs[i].list_off >= o->lay.insert) {
            mma_fail(why, whysz, MMA_REFUSED, "the absolute method list at file offset 0x%llx lies "
                     "in __LINKEDIT, which the conversion moves", (unsigned long long)w.refs[i].list_off);
            goto done;
        }
        if (!mml_off_rebased(&res, w.refs[i].slot_off)) {
            mma_fail(why, whysz, MMA_REFUSED, "the method-list pointer at file offset 0x%llx "
                     "carries no rebase", (unsigned long long)w.refs[i].slot_off);
            goto done;
        }
        if (!mml_off_pointer_rebased(&res, w.refs[i].slot_off)) {
            mma_fail(why, whysz, MMA_REFUSED, "the method-list pointer at file offset 0x%llx is "
                     "rebased as TEXT_ABSOLUTE32, which would slide only its low half",
                     (unsigned long long)w.refs[i].slot_off);
            goto done;
        }
    }
    if ((rc = mma_room(&w, first, o->lay.list_va, new_va, &total, &nslots, why, whysz)) != MMA_OK)
        goto done;
    o->s = (total + MMA_PAGE - 1) & ~(uint64_t)(MMA_PAGE - 1);
    rc = MMA_NOMEM;
    if (!(lists = calloc(1, total)) || !(slots = malloc((nslots ? nslots : 1) * sizeof *slots))) {
        mma_fail(why, whysz, MMA_NOMEM, "out of memory");
        goto done;
    }
    rc = MMA_REFUSED;
    nslots = 0;
    for (i = 0; i < w.n; i++) {
        const mml_ref *ref = &w.refs[i];
        if (first[i] != i || !(ref->header & MML_RELATIVE)) continue;
        at = new_va[i] - o->lay.list_va;
        memcpy(lists + at, &(uint32_t){ MML_ABS_ENTSIZE }, 4);
        memcpy(lists + at + 4, &ref->count, 4);
        for (e = 0; e < ref->count; e++) {
            mml_entry ent;
            uint64_t ea = at + 8 + (uint64_t)MML_ABS_ENTSIZE * e;
            uint64_t eoff = new_va[i] + 8 + (uint64_t)MML_ABS_ENTSIZE * e - segs[o->lay.d].vmaddr;
            if (mml_entry_at(&res, ref, e, &ent, why, whysz) != MML_OK) goto done;
            mma_put64(lists + ea, ent.name);
            mma_put64(lists + ea + 8, ent.types);
            mma_put64(lists + ea + 16, ent.imp);
            for (int k = 0; k < 3; k++) {
                if (k == 2 && !ent.imp) continue;
                slots[nslots].seg = (uint8_t)o->lay.d;
                slots[nslots].type = REBASE_TYPE_POINTER;
                slots[nslots].off = eoff + 8 * (uint64_t)k;
                nslots++;
            }
        }
        o->rep.lists++;
        o->rep.methods += ref->count;
        o->rep.owners[ref->owner]++;
    }
    if (di->rebase_size) {
        rc = mrb_decode(im->buf + di->rebase_off, di->rebase_size, nsegs, &old, why, whysz);
        if (rc != MRB_OK) { rc = rc == MRB_NOMEM ? MMA_NOMEM : MMA_REFUSED; goto done; }
        mrb_put(&stream, im->buf + di->rebase_off, old.end);
    }
    rc = mrb_encode(slots, nslots, &stream);
    if (rc != MRB_OK) {
        rc = rc == MRB_NOMEM ? MMA_NOMEM : MMA_REFUSED;
        mma_fail(why, whysz, rc, rc == MMA_NOMEM ? "out of memory" : "internal error: new rebases out of order");
        goto done;
    }
    mrb_put(&stream, zero, 1 + (16 - (stream.n + 1) % 16) % 16);
    if (stream.oom) { rc = mma_fail(why, whysz, MMA_NOMEM, "out of memory"); goto done; }
    o->r = (uint32_t)stream.n;
    rc = mma_insert(im, &o->lay, lists, total, o->s, stream.p, o->r, &o->buf, &o->size, why, whysz);
    if (rc != MMA_OK) goto done;
    for (i = 0; i < w.n; i++)
        if (w.refs[i].header & MML_RELATIVE) mma_put64(o->buf + w.refs[i].slot_off, new_va[first[i]]);
    o->rep.rebases = (uint32_t)nslots;
    memcpy(o->rep.dname, o->lay.dname, 16);
    o->rep.grew = o->s;
    o->rep.zerofill = o->lay.z;
    o->rep.linkedit_before = segs[o->lay.l].filesize;
    o->rep.linkedit_after = segs[o->lay.l].filesize + o->r;
done:
    free(first);
    free(new_va);
    free(lists);
    free(slots);
    free(stream.p);
    mrb_free(&old);
    mml_resolver_close(&res);
    mml_walk_free(&w);
    return rc;
}

/* ---- verification --------------------------------------------------------- */

/* Every ml_each_off field's value, in order; which one is rebase_off; and,
 * with a mask, which load-command bytes they occupy. */
typedef struct {
    uint32_t *v;
    uint32_t n, cap, rb_at;
    const uint32_t *rb;
    uint8_t *mask;
    const uint8_t *base;
    int oom;
} mma_offs;

static int mma_collect_off(uint32_t *off, uint32_t cmd, int flags, void *ctx_) {
    mma_offs *c = ctx_;
    (void)cmd; (void)flags;
    if (c->mask) memset(c->mask + ((const uint8_t *)off - c->base), 1, 4);
    if (off == c->rb) c->rb_at = c->n;
    if (c->n == c->cap) {
        uint32_t cap = c->cap ? c->cap * 2 : 32;
        uint32_t *v = realloc(c->v, cap * sizeof *v);
        if (!v) { c->oom = 1; return 1; }
        c->v = v;
        c->cap = cap;
    }
    c->v[c->n++] = *off;
    return 0;
}

typedef struct {
    const struct segment_command_64 *seg[MML_MAX_SEGS];
    int n;
    const struct dyld_info_command *di;
} mma_lcs;

static int mma_lcs_lc(const struct load_command *lc, void *ctx_) {
    mma_lcs *c = ctx_;
    if (lc->cmd == LC_SEGMENT_64 && c->n < MML_MAX_SEGS)
        c->seg[c->n++] = (const struct segment_command_64 *)lc;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY)
        c->di = (const struct dyld_info_command *)lc;
    return 0;
}

/* The output's walk against the input's, and every new pointer's slot into `added`. */
static int mma_verify_walk(const mml_walk *wi, const mml_walk *wo, const mml_resolver *ri,
                           const mml_resolver *ro, const mma_out *o, uint64_t d_vmaddr,
                           const uint32_t *first, mrb_set *added, uint64_t *used,
                           char *why, size_t whysz) {
    uint32_t i, e;
    if (wo->relative)
        return mma_fail(why, whysz, MMA_REFUSED, "the output still has %u relative method lists",
                        wo->relative);
    if (wo->n != wi->n)
        return mma_fail(why, whysz, MMA_REFUSED, "the output has %u method-list slots, the input %u",
                        wo->n, wi->n);
    for (i = 0; i < wi->n; i++) {
        const mml_ref *a = &wi->refs[i], *b = &wo->refs[i];
        if (a->slot_off != b->slot_off)
            return mma_fail(why, whysz, MMA_REFUSED, "method-list slot %u moved from 0x%llx to 0x%llx",
                            i, (unsigned long long)a->slot_off, (unsigned long long)b->slot_off);
        if (!(a->header & MML_RELATIVE)) {
            if (b->list_va != a->list_va)
                return mma_fail(why, whysz, MMA_REFUSED, "the slot at 0x%llx named an absolute list "
                                "at 0x%llx and now names 0x%llx", (unsigned long long)a->slot_off,
                                (unsigned long long)a->list_va, (unsigned long long)b->list_va);
            continue;
        }
        if (a->list_va != wi->refs[first[i]].list_va)
            return mma_fail(why, whysz, MMA_REFUSED, "the slots at 0x%llx and 0x%llx named two lists "
                            "and were given one", (unsigned long long)wi->refs[first[i]].slot_off,
                            (unsigned long long)a->slot_off);
        if (b->list_va != wo->refs[first[i]].list_va)
            return mma_fail(why, whysz, MMA_REFUSED, "the slots at 0x%llx and 0x%llx named one list "
                            "and now name two", (unsigned long long)wi->refs[first[i]].slot_off,
                            (unsigned long long)a->slot_off);
        if (b->list_va < o->lay.list_va || b->list_va - o->lay.list_va >= o->s ||
            b->header != MML_ABS_ENTSIZE || b->count != a->count)
            return mma_fail(why, whysz, MMA_REFUSED, "the slot at 0x%llx names 0x%llx, which is not "
                            "a converted list of %u entries", (unsigned long long)a->slot_off,
                            (unsigned long long)b->list_va, a->count);
        if (first[i] != i) continue;
        for (e = 0; e < a->count; e++) {
            mml_entry x, y;
            uint64_t slot = b->list_va + 8 + (uint64_t)MML_ABS_ENTSIZE * e - d_vmaddr;
            if (mml_entry_at(ri, a, e, &x, why, whysz) != MML_OK ||
                mml_entry_at(ro, b, e, &y, why, whysz) != MML_OK)
                return MMA_REFUSED;
            if (x.name != y.name || x.types != y.types || x.imp != y.imp)
                return mma_fail(why, whysz, MMA_REFUSED, "entry %u of the list the slot at 0x%llx "
                                "names is not the entry it was", e, (unsigned long long)a->slot_off);
            for (int k = 0; k < 3; k++)
                if ((k < 2 || y.imp) &&
                    mrb_add(added, (uint8_t)o->lay.d, REBASE_TYPE_POINTER, slot + 8 * (uint64_t)k) != 0)
                    return mma_fail(why, whysz, MMA_NOMEM, "out of memory");
        }
        if (b->list_va + 8 + (uint64_t)MML_ABS_ENTSIZE * a->count - o->lay.list_va > *used)
            *used = b->list_va + 8 + (uint64_t)MML_ABS_ENTSIZE * a->count - o->lay.list_va;
    }
    return MMA_OK;
}

static int mma_slot_cmp(const void *a_, const void *b_) {
    const mrb_slot *a = a_, *b = b_;
    if (a->seg != b->seg) return a->seg < b->seg ? -1 : 1;
    if (a->off != b->off) return a->off < b->off ? -1 : 1;
    return (a->type > b->type) - (a->type < b->type);
}

/* The output's rebases must be, as a multiset of (segment, offset, type),
 * the input's plus `added`; and no input rebase may name bytes the
 * conversion puts somewhere else: D past its old end, where the lists go, or
 * __LINKEDIT, which the new stream moves up. */
static int mma_verify_rebases(const mi_image *in, const mma_out *o, const mma_lcs *li,
                              const mma_lcs *lo, mrb_set *added, char *why, size_t whysz) {
    uint64_t d_end = li->seg[o->lay.d]->vmsize;
    mrb_set was, now;
    int rc;
    size_t k, j;
    memset(&was, 0, sizeof was);
    memset(&now, 0, sizeof now);
    if ((rc = mrb_decode(in->buf + li->di->rebase_off, li->di->rebase_size, li->n, &was, why, whysz)) != MRB_OK ||
        (rc = mrb_decode(o->buf + lo->di->rebase_off, lo->di->rebase_size, lo->n, &now, why, whysz)) != MRB_OK) {
        rc = rc == MRB_NOMEM ? MMA_NOMEM : MMA_REFUSED;
        goto out;
    }
    rc = MMA_REFUSED;
    for (k = 0; k < was.n; k++) {
        if (was.v[k].seg == o->lay.d && was.v[k].off >= d_end) {
            mma_fail(why, whysz, MMA_REFUSED, "the input rebases %.16s at offset 0x%llx, past its end "
                     "at 0x%llx, where the lists go", li->seg[o->lay.d]->segname,
                     (unsigned long long)was.v[k].off, (unsigned long long)d_end);
            goto out;
        }
        if (was.v[k].seg == o->lay.l) {
            mma_fail(why, whysz, MMA_REFUSED, "the input rebases __LINKEDIT at offset 0x%llx, whose "
                     "bytes the new rebase stream moves", (unsigned long long)was.v[k].off);
            goto out;
        }
    }
    if (now.n != was.n + added->n) {
        mma_fail(why, whysz, MMA_REFUSED, "the new rebase stream has %zu rebases; the old one had %zu "
                 "and %zu pointers are new", now.n, was.n, added->n);
        goto out;
    }
    for (k = 0; k < added->n; k++)
        if (mrb_add(&was, added->v[k].seg, added->v[k].type, added->v[k].off) != 0) {
            rc = mma_fail(why, whysz, MMA_NOMEM, "out of memory");
            goto out;
        }
    if (was.n) qsort(was.v, was.n, sizeof *was.v, mma_slot_cmp);
    if (now.n) qsort(now.v, now.n, sizeof *now.v, mma_slot_cmp);
    for (k = 0, j = 0; k < was.n; ) {
        int c = j < now.n ? mma_slot_cmp(&was.v[k], &now.v[j]) : -1;
        if (c > 0) { j++; continue; }
        if (c == 0) { k++; j++; continue; }
        if (was.v[k].seg == o->lay.d && was.v[k].off >= d_end)
            mma_fail(why, whysz, MMA_REFUSED, "the new pointer at segment %u offset 0x%llx has no "
                     "rebase as a pointer", was.v[k].seg, (unsigned long long)was.v[k].off);
        else
            mma_fail(why, whysz, MMA_REFUSED, "the old rebase of segment %u offset 0x%llx, type %u, "
                     "is gone", was.v[k].seg, (unsigned long long)was.v[k].off, was.v[k].type);
        goto out;
    }
    rc = MMA_OK;
out:
    mrb_free(&was);
    mrb_free(&now);
    return rc;
}

static int mma_verify_lcs(const mi_image *in, const mma_out *o, const mma_lcs *li, const mma_lcs *lo,
                          char *why, size_t whysz) {
    const struct mach_header_64 *hi = in->hdr, *ho = (const struct mach_header_64 *)o->buf;
    const struct segment_command_64 *di = li->seg[o->lay.d], *dn = lo->seg[o->lay.d];
    const struct segment_command_64 *l0 = li->seg[o->lay.l], *ln = lo->seg[o->lay.l];
    uint64_t z = o->lay.z, grow = z + o->s + o->r, need;
    mi_image a, b;
    mma_offs oi, on;
    uint8_t *mask;
    uint32_t k;
    int rc = MMA_REFUSED;

    if (memcmp(hi, ho, sizeof *hi) != 0 || lo->n != li->n || !lo->di)
        return mma_fail(why, whysz, MMA_REFUSED, "the mach header or the segment count changed");
    if (dn->vmsize != di->vmsize + o->s || dn->filesize != di->filesize + z + o->s)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s's vmsize/filesize are 0x%llx/0x%llx; want "
                        "0x%llx/0x%llx", dn->segname, (unsigned long long)dn->vmsize,
                        (unsigned long long)dn->filesize, (unsigned long long)(di->vmsize + o->s),
                        (unsigned long long)(di->filesize + z + o->s));
    need = (l0->filesize + o->r + MMA_PAGE - 1) & ~(uint64_t)(MMA_PAGE - 1);
    if (ln->vmaddr != l0->vmaddr + o->s || ln->fileoff != l0->fileoff + z + o->s ||
        ln->filesize != l0->filesize + o->r || ln->vmsize != (l0->vmsize > need ? l0->vmsize : need))
        return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT's geometry is not what the layout says");
    for (int x = 0; x < lo->n; x++)
        for (int y = x + 1; y < lo->n; y++) {
            const struct segment_command_64 *p = lo->seg[x], *q = lo->seg[y];
            if (p->vmsize && q->vmsize && p->vmaddr < q->vmaddr + q->vmsize && q->vmaddr < p->vmaddr + p->vmsize)
                return mma_fail(why, whysz, MMA_REFUSED, "segments %.16s and %.16s overlap in memory",
                                p->segname, q->segname);
        }

    if (!(mask = calloc(1, ho->sizeofcmds)))
        return mma_fail(why, whysz, MMA_NOMEM, "out of memory");
    memset(&oi, 0, sizeof oi);
    memset(&on, 0, sizeof on);
    on.rb = &lo->di->rebase_off;
    on.rb_at = UINT32_MAX;
    on.mask = mask;
    on.base = o->buf + sizeof *ho;
    if (mi_wrap(in->buf, in->size, &a) != 0 || mi_wrap(o->buf, o->size, &b) != 0 ||
        ml_each_off(&a, mma_collect_off, &oi) != 0 || ml_each_off(&b, mma_collect_off, &on) != 0) {
        rc = mma_fail(why, whysz, oi.oom || on.oom ? MMA_NOMEM : MMA_REFUSED, "the __LINKEDIT offsets "
                      "could not be read");
        goto out;
    }
    if (oi.n != on.n) {
        mma_fail(why, whysz, MMA_REFUSED, "the output has %u __LINKEDIT offsets, the input %u", on.n, oi.n);
        goto out;
    }
    for (k = 0; k < oi.n; k++) {
        uint64_t want = oi.v[k] >= o->lay.insert && oi.v[k] ? oi.v[k] + grow : oi.v[k];
        if (k == on.rb_at) continue;
        if (on.v[k] != want) {
            mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT offset %u is 0x%x; want 0x%llx", k, on.v[k],
                     (unsigned long long)want);
            goto out;
        }
    }
    if (lo->di->rebase_off != o->lay.insert + z + o->s || lo->di->rebase_size != o->r) {
        mma_fail(why, whysz, MMA_REFUSED, "rebase_off/size are 0x%x/0x%x; want 0x%llx/0x%x",
                 lo->di->rebase_off, lo->di->rebase_size,
                 (unsigned long long)(o->lay.insert + z + o->s), o->r);
        goto out;
    }
    memset(mask + ((const uint8_t *)&lo->di->rebase_size - on.base), 1, 4);
    memset(mask + ((const uint8_t *)&dn->vmsize - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&dn->filesize - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&ln->vmaddr - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&ln->vmsize - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&ln->fileoff - on.base), 1, 8);
    memset(mask + ((const uint8_t *)&ln->filesize - on.base), 1, 8);
    for (k = 0; k < ho->sizeofcmds; k++)
        if (!mask[k] && in->buf[sizeof *hi + k] != o->buf[sizeof *ho + k]) {
            mma_fail(why, whysz, MMA_REFUSED, "load-command byte %u changed, and nothing the "
                     "conversion edits lives there", k);
            goto out;
        }
    rc = MMA_OK;
out:
    free(mask);
    free(oi.v);
    free(on.v);
    return rc;
}

static int mma_verify_bytes(const mi_image *in, const mma_out *o, const mml_walk *wi,
                            const mma_lcs *li, uint64_t used, char *why, size_t whysz) {
    uint64_t at = o->lay.insert, z = o->lay.z, grow = z + o->s + o->r, k;
    uint64_t lc_end = sizeof(struct mach_header_64) + in->hdr->sizeofcmds;
    uint64_t old_rb = li->di->rebase_off, old_rb_end = old_rb + li->di->rebase_size;
    uint8_t *slot = calloc(1, at ? at : 1);
    if (!slot) return mma_fail(why, whysz, MMA_NOMEM, "out of memory");
    for (uint32_t i = 0; i < wi->n; i++)
        if ((wi->refs[i].header & MML_RELATIVE) && wi->refs[i].slot_off + 8 <= at)
            memset(slot + wi->refs[i].slot_off, 1, 8);
    for (k = lc_end; k < at; k++)
        if (!slot[k] && o->buf[k] != in->buf[k]) {
            free(slot);
            return mma_fail(why, whysz, MMA_REFUSED, "byte 0x%llx, below the insertion, changed",
                            (unsigned long long)k);
        }
    free(slot);
    for (k = at; k < at + z; k++)
        if (o->buf[k])
            return mma_fail(why, whysz, MMA_REFUSED, "zero-fill byte 0x%llx is not zero",
                            (unsigned long long)k);
    for (k = at + z + used; k < at + z + o->s; k++)
        if (o->buf[k])
            return mma_fail(why, whysz, MMA_REFUSED, "byte 0x%llx, past the lists, is not zero",
                            (unsigned long long)k);
    for (k = at; k < in->size; k++) {
        int in_old_rb = k >= old_rb && k < old_rb_end;
        if (o->buf[k + grow] != (in_old_rb ? 0 : in->buf[k]))
            return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT byte 0x%llx is not what it was at "
                            "0x%llx%s", (unsigned long long)(k + grow), (unsigned long long)k,
                            in_old_rb ? ", the old rebase stream, zeroed" : "");
    }
    return MMA_OK;
}

int mma_verify(const mi_image *in, const mma_out *o, char *why, size_t whysz) {
    mi_image out;
    mml_walk wi, wo;
    mml_resolver ri, ro;
    mma_lcs li, lo;
    mrb_set added;
    uint32_t *first = NULL;
    uint64_t used = 0;
    int rc;

    memset(&wi, 0, sizeof wi);
    memset(&wo, 0, sizeof wo);
    memset(&ri, 0, sizeof ri);
    memset(&ro, 0, sizeof ro);
    memset(&li, 0, sizeof li);
    memset(&lo, 0, sizeof lo);
    memset(&added, 0, sizeof added);
    if (mi_wrap(o->buf, o->size, &out) != 0)
        return mma_fail(why, whysz, MMA_REFUSED, "the output is not a readable 64-bit Mach-O");
    mi_each_lc(in, mma_lcs_lc, &li);
    mi_each_lc(&out, mma_lcs_lc, &lo);
    if (o->size != in->size + o->lay.z + o->s + o->r)
        return mma_fail(why, whysz, MMA_REFUSED, "the output is 0x%zx bytes; the layout makes it 0x%llx",
                        o->size, (unsigned long long)(in->size + o->lay.z + o->s + o->r));
    if (o->lay.d < 0 || o->lay.d >= li.n || o->lay.l != li.n - 1)
        return mma_fail(why, whysz, MMA_REFUSED, "the layout names D as segment %d and __LINKEDIT as "
                        "segment %d, of %d", o->lay.d, o->lay.l, li.n);
    if (!li.di || !lo.di)
        return mma_fail(why, whysz, MMA_REFUSED, "LC_DYLD_INFO is missing");
    if ((rc = mml_walk_image(in, &wi)) != MML_OK || (rc = mml_walk_image(&out, &wo)) != MML_OK) {
        rc = mma_fail(why, whysz, rc == MML_NOMEM ? MMA_NOMEM : MMA_REFUSED, "the walk fails: %s",
                      wo.why[0] ? wo.why : wi.why);
        goto out;
    }
    if ((rc = mml_resolver_open(in, &ri, why, whysz)) != MML_OK ||
        (rc = mml_resolver_open(&out, &ro, why, whysz)) != MML_OK) {
        rc = rc == MML_NOMEM ? MMA_NOMEM : MMA_REFUSED;
        goto out;
    }
    if (!(first = malloc((wi.n ? wi.n : 1) * sizeof *first)) || mma_firsts(&wi, first) != 0) {
        rc = mma_fail(why, whysz, MMA_NOMEM, "out of memory");
        goto out;
    }
    if ((rc = mma_verify_walk(&wi, &wo, &ri, &ro, o, li.seg[o->lay.d]->vmaddr, first, &added,
                              &used, why, whysz)) != MMA_OK ||
        (rc = mma_verify_rebases(in, o, &li, &lo, &added, why, whysz)) != MMA_OK ||
        (rc = mma_verify_lcs(in, o, &li, &lo, why, whysz)) != MMA_OK ||
        (rc = mma_verify_bytes(in, o, &wi, &li, used, why, whysz)) != MMA_OK)
        goto out;
    rc = MMA_OK;
out:
    free(first);
    mrb_free(&added);
    mml_resolver_close(&ri);
    mml_resolver_close(&ro);
    mml_walk_free(&wi);
    mml_walk_free(&wo);
    return rc;
}

int mma_convert(uint8_t **pbuf, size_t *psize, mma_report *rep) {
    mi_image im;
    mma_out o;
    char why[512] = "";
    int rc;

    memset(rep, 0, sizeof *rep);
    if (mi_wrap(*pbuf, *psize, &im) != 0) {
        fprintf(stderr, WHAT ": the image is not a readable 64-bit Mach-O\n");
        return MR_REFUSED;
    }
    rc = mma_build(&im, &o, why, sizeof why);
    if (rc == MMA_NOTHING) return 0;
    if (rc == MMA_OK) {
        rc = mma_verify(&im, &o, why, sizeof why);
        if (rc != MMA_OK) {
            mma_out_free(&o);
            if (rc == MMA_REFUSED) {
                fprintf(stderr, WHAT ": verification failed: %s; refusing\n", why);
                return MR_REFUSED;
            }
        }
    }
    if (rc == MMA_NOMEM) {
        fprintf(stderr, WHAT ": out of memory\n");
        return MR_FAIL;
    }
    if (rc != MMA_OK) {
        fprintf(stderr, WHAT ": %s; refusing\n", why);
        return MR_REFUSED;
    }
    *rep = o.rep;
    free(*pbuf);
    *pbuf = o.buf;
    *psize = o.size;
    return 0;
}
