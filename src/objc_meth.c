/* mml_ -- see objc_meth.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "objc_meth.h"
#include "mach_compat.h"

#define MML_MAX_SEGS   64
#define MML_DATA_MASK  0x00007ffffffffff8ULL
#define MML_CLASS_ISA   0
#define MML_CLASS_DATA 32
#define MML_RO_METHODS 32
#define MML_CAT_INSTANCE 16
#define MML_CAT_CLASS    24
#define MML_CAT_SIZE     32
#define MML_PROTO_FIRST  24   /* instance, class, optional instance, optional class */
#define MML_PROTO_SIZE   56

typedef struct { uint64_t vmaddr, filesize, fileoff; } mml_seg;

/* Open addressing; 0 marks an empty bucket, so the key 0 is kept apart. */
typedef struct { uint64_t *keys; uint32_t cap, n; int has_zero; } mml_set;

typedef struct {
    const mi_image *im;
    mml_walk *w;
    mml_seg segs[MML_MAX_SEGS];
    int nsegs, chained, err;
    mml_set records, slots, lists;
} mml_ctx;

static const struct { const char *name; int owner; } MML_LISTS[] = {
    { "__objc_classlist", MML_CLASS },
    { "__objc_nlclslist", MML_CLASS },
    { "__objc_catlist",   MML_CATEGORY },
    { "__objc_nlcatlist", MML_CATEGORY },
    { "__objc_protolist", MML_PROTOCOL },
};

static int mml_fail(mml_ctx *c, int code, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static int mml_fail(mml_ctx *c, int code, const char *fmt, ...) {
    va_list ap;
    if (c->err) return c->err;
    va_start(ap, fmt);
    vsnprintf(c->w->why, sizeof c->w->why, fmt, ap);
    va_end(ap);
    c->err = code;
    return code;
}

/* The file offset of [va, va + len) when one segment's file bytes hold all
 * of it, else -1. */
static int64_t mml_off(const mml_ctx *c, uint64_t va, uint64_t len) {
    for (int i = 0; i < c->nsegs; i++) {
        const mml_seg *s = &c->segs[i];
        if (va < s->vmaddr || va - s->vmaddr >= s->filesize) continue;
        uint64_t rel = va - s->vmaddr;
        if (len > s->filesize - rel) return -1;
        uint64_t off = s->fileoff + rel;
        if (off > c->im->size || len > c->im->size - off) return -1;
        return (int64_t)off;
    }
    return -1;
}

static int mml_read64(const mml_ctx *c, uint64_t va, uint64_t *out) {
    int64_t off = mml_off(c, va, 8);
    if (off < 0) return -1;
    memcpy(out, c->im->buf + off, 8);
    return 0;
}

static uint32_t mml_bucket(uint64_t k, uint32_t cap) {
    return (uint32_t)((k * 0x9e3779b97f4a7c15ULL) >> 32) & (cap - 1);
}

static int mml_set_grow(mml_set *s) {
    uint32_t cap = s->cap ? s->cap * 2 : 64, j;
    uint64_t *keys;
    if (s->cap >= 0x80000000u || !(keys = calloc(cap, sizeof *keys))) return -1;
    for (uint32_t i = 0; i < s->cap; i++) {
        if (!s->keys[i]) continue;
        for (j = mml_bucket(s->keys[i], cap); keys[j]; j = (j + 1) & (cap - 1)) {}
        keys[j] = s->keys[i];
    }
    free(s->keys);
    s->keys = keys;
    s->cap = cap;
    return 0;
}

/* 1 when `k` was in the set already; else adds it and returns 0, or -1 when
 * out of memory. */
static int mml_set_add(mml_set *s, uint64_t k) {
    uint32_t i;
    if (!k) { int had = s->has_zero; s->has_zero = 1; return had; }
    if ((uint64_t)(s->n + 1) * 4 > (uint64_t)s->cap * 3 && mml_set_grow(s) != 0) return -1;
    for (i = mml_bucket(k, s->cap); s->keys[i]; i = (i + 1) & (s->cap - 1))
        if (s->keys[i] == k) return 1;
    s->keys[i] = k;
    s->n++;
    return 0;
}

/* mml_set_add, failing the walk when out of memory. */
static int mml_seen(mml_ctx *c, mml_set *s, uint64_t k) {
    int r = mml_set_add(s, k);
    if (r < 0) mml_fail(c, MML_NOMEM, "out of memory");
    return r;
}

static int mml_list(mml_ctx *c, uint64_t slot_va, int owner) {
    mml_walk *w = c->w;
    uint64_t list_va;
    uint32_t hdr, count;
    int known;
    int64_t slot_off = mml_off(c, slot_va, 8), loff;

    if (slot_off < 0)
        return mml_fail(c, MML_MALFORMED, "the method-list pointer at 0x%llx lies outside the file",
                        (unsigned long long)slot_va);
    memcpy(&list_va, c->im->buf + slot_off, 8);
    if (!list_va) return 0;
    if (list_va & 3)
        return mml_fail(c, MML_MALFORMED, "the method-list pointer at 0x%llx has its low bits set "
                        "(0x%llx): a list of lists, which this walk does not read",
                        (unsigned long long)slot_va, (unsigned long long)list_va);
    loff = mml_off(c, list_va, 8);
    if (loff < 0)
        return mml_fail(c, MML_MALFORMED, "the method list at 0x%llx lies outside the file",
                        (unsigned long long)list_va);
    memcpy(&hdr, c->im->buf + loff, 4);
    memcpy(&count, c->im->buf + loff + 4, 4);

    int rel = (hdr & MML_RELATIVE) != 0;
    uint32_t entsize = hdr & ~MML_FLAG_MASK;
    uint32_t allowed = rel ? MML_RELATIVE : 3u;
    if (entsize != (rel ? MML_REL_ENTSIZE : MML_ABS_ENTSIZE) || (hdr & MML_FLAG_MASK & ~allowed))
        return mml_fail(c, MML_MALFORMED, "the method list at 0x%llx has entsizeAndFlags 0x%08x, "
                        "which this walk does not read", (unsigned long long)list_va, hdr);
    if (mml_off(c, list_va, 8 + (uint64_t)entsize * count) < 0)
        return mml_fail(c, MML_MALFORMED, "the method list at 0x%llx claims %u entries, which runs "
                        "past its segment", (unsigned long long)list_va, count);

    if (mml_seen(c, &c->slots, (uint64_t)slot_off) != 0) return c->err;
    if ((known = mml_seen(c, &c->lists, list_va)) < 0) return c->err;
    if (w->n == w->cap) {
        uint32_t cap = w->cap ? w->cap * 2 : 32;
        mml_ref *p = realloc(w->refs, cap * sizeof *p);
        if (!p) return mml_fail(c, MML_NOMEM, "out of memory");
        w->refs = p;
        w->cap = cap;
    }
    w->refs[w->n].slot_off = (uint64_t)slot_off;
    w->refs[w->n].list_va = list_va;
    w->refs[w->n].list_off = (uint64_t)loff;
    w->refs[w->n].header = hdr;
    w->refs[w->n].count = count;
    w->refs[w->n].owner = owner;
    w->n++;
    if (!known) { if (rel) w->relative++; else w->absolute++; }
    return 0;
}

static int mml_class(mml_ctx *c, uint64_t cls_va, int owner) {
    uint64_t data, isa;
    if (!cls_va || mml_seen(c, &c->records, cls_va) != 0) return c->err;
    if (mml_read64(c, cls_va + MML_CLASS_ISA, &isa) != 0 ||
        mml_read64(c, cls_va + MML_CLASS_DATA, &data) != 0)
        return mml_fail(c, MML_MALFORMED, "the %s record at 0x%llx lies outside the file",
                        owner == MML_METACLASS ? "metaclass" : "class", (unsigned long long)cls_va);
    c->w->owners[owner]++;
    uint64_t ro = data & MML_DATA_MASK;
    if (ro && mml_list(c, ro + MML_RO_METHODS, owner) != 0) return c->err;
    if (owner == MML_CLASS && isa) return mml_class(c, isa, MML_METACLASS);
    return 0;
}

static int mml_category(mml_ctx *c, uint64_t va) {
    if (!va || mml_seen(c, &c->records, va) != 0) return c->err;
    if (mml_off(c, va, MML_CAT_SIZE) < 0)
        return mml_fail(c, MML_MALFORMED, "the category record at 0x%llx lies outside the file",
                        (unsigned long long)va);
    c->w->owners[MML_CATEGORY]++;
    if (mml_list(c, va + MML_CAT_INSTANCE, MML_CATEGORY) != 0) return c->err;
    return mml_list(c, va + MML_CAT_CLASS, MML_CATEGORY);
}

static int mml_protocol(mml_ctx *c, uint64_t va) {
    if (!va || mml_seen(c, &c->records, va) != 0) return c->err;
    if (mml_off(c, va, MML_PROTO_SIZE) < 0)
        return mml_fail(c, MML_MALFORMED, "the protocol record at 0x%llx lies outside the file",
                        (unsigned long long)va);
    c->w->owners[MML_PROTOCOL]++;
    for (int k = 0; k < 4; k++)
        if (mml_list(c, va + MML_PROTO_FIRST + 8 * k, MML_PROTOCOL) != 0) return c->err;
    return 0;
}

static int mml_record(mml_ctx *c, uint64_t va, int owner) {
    if (owner == MML_CATEGORY) return mml_category(c, va);
    if (owner == MML_PROTOCOL) return mml_protocol(c, va);
    return mml_class(c, va, owner);
}

static int mml_section(mml_ctx *c, const struct section_64 *s, int owner) {
    if (s->offset > c->im->size || s->size > c->im->size - s->offset)
        return mml_fail(c, MML_MALFORMED, "section %.16s lies outside the file", s->sectname);
    for (uint64_t i = 0; i + 8 <= s->size; i += 8) {
        uint64_t va;
        memcpy(&va, c->im->buf + s->offset + i, 8);
        if (mml_record(c, va, owner) != 0) return c->err;
    }
    return 0;
}

static int mml_seg_lc(const struct load_command *lc, void *ctx_) {
    mml_ctx *c = ctx_;
    if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) c->chained = 1;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
    if (c->nsegs == MML_MAX_SEGS) {
        mml_fail(c, MML_MALFORMED, "more than %d segments", MML_MAX_SEGS);
        return 1;
    }
    c->segs[c->nsegs].vmaddr = sc->vmaddr;
    c->segs[c->nsegs].filesize = sc->filesize;
    c->segs[c->nsegs].fileoff = sc->fileoff;
    c->nsegs++;
    return 0;
}

static int mml_sect_lc(const struct load_command *lc, void *ctx_) {
    mml_ctx *c = ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(sc + 1);
    for (uint32_t k = 0; k < sc->nsects; k++)
        for (size_t j = 0; j < sizeof MML_LISTS / sizeof MML_LISTS[0]; j++)
            if (strncmp(s[k].sectname, MML_LISTS[j].name, 16) == 0 &&
                mml_section(c, &s[k], MML_LISTS[j].owner) != 0)
                return 1;
    return 0;
}

int mml_walk_image(const mi_image *im, mml_walk *w) {
    mml_ctx c;
    memset(w, 0, sizeof *w);
    memset(&c, 0, sizeof c);
    c.im = im;
    c.w = w;
    mi_each_lc(im, mml_seg_lc, &c);
    if (!c.err && c.chained)
        mml_fail(&c, MML_CHAINED, "the image has chained fixups; fixups set classic first");
    if (!c.err) mi_each_lc(im, mml_sect_lc, &c);
    free(c.records.keys);
    free(c.slots.keys);
    free(c.lists.keys);
    if (c.err) {
        free(w->refs);
        w->refs = NULL;
        w->n = w->cap = 0;
        w->relative = w->absolute = 0;
        memset(w->owners, 0, sizeof w->owners);
    }
    return c.err;
}

void mml_walk_free(mml_walk *w) {
    free(w->refs);
    w->refs = NULL;
    w->n = w->cap = 0;
}
