/* mml_ -- see objc_meth.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "objc_meth.h"
#include "grow.h"
#include "ordinals.h"
#include "mach_compat.h"

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

/* ---- resolving entries ---------------------------------------------------- */

static int mml_rfail(char *why, size_t whysz, int code, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
static int mml_rfail(char *why, size_t whysz, int code, const char *fmt, ...) {
    va_list ap;
    if (why && whysz) {
        va_start(ap, fmt);
        vsnprintf(why, whysz, fmt, ap);
        va_end(ap);
    }
    return code;
}

typedef struct {
    mml_resolver *r;
    const struct dyld_info_command *di;
    const struct linkedit_data_command *fs;
    int err;
} mml_open_ctx;

static int mml_open_lc(const struct load_command *lc, void *ctx_) {
    mml_open_ctx *c = ctx_;
    mml_resolver *r = c->r;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        c->di = (const struct dyld_info_command *)lc;
    } else if (lc->cmd == LC_FUNCTION_STARTS) {
        c->fs = (const struct linkedit_data_command *)lc;
    } else if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
        const struct section_64 *s = (const struct section_64 *)(sc + 1);
        if (r->nsegs == MML_MAX_SEGS) { c->err = MML_MALFORMED; return 1; }
        r->segs[r->nsegs].vmaddr = sc->vmaddr;
        r->segs[r->nsegs].vmsize = sc->vmsize;
        r->segs[r->nsegs].fileoff = sc->fileoff;
        r->segs[r->nsegs].filesize = sc->filesize;
        r->nsegs++;
        if (sc->nsects) {
            mml_sect *p = realloc(r->sects, (r->nsects + sc->nsects) * sizeof *p);
            if (!p) { c->err = MML_NOMEM; return 1; }
            r->sects = p;
            for (uint32_t k = 0; k < sc->nsects; k++, r->nsects++) {
                p[r->nsects].addr = s[k].addr;
                p[r->nsects].size = s[k].size;
                p[r->nsects].offset = s[k].offset;
                p[r->nsects].flags = s[k].flags;
            }
        }
    }
    return 0;
}

static void mml_note_bind(const mo_bind_state *st, void *ctx_) {
    mml_open_ctx *c = ctx_;
    uint64_t off = st->offset;
    if (c->err || st->seg < 0 || st->seg > 255) return;
    for (uint64_t k = 0; k < st->count && !c->err; k++, off += 8 + st->skip)
        if (mrb_add(&c->r->binds, (uint8_t)st->seg, 0, off) != 0) c->err = MML_NOMEM;
}

static int mml_fits(uint64_t off, uint64_t len, size_t size) {
    return off <= size && len <= size - off;
}

int mml_resolver_open(const mi_image *im, mml_resolver *r, char *why, size_t whysz) {
    mml_open_ctx c;
    int rc;
    memset(r, 0, sizeof *r);
    memset(&c, 0, sizeof c);
    r->im = im;
    r->nstarts = -1;
    c.r = r;
    mi_each_lc(im, mml_open_lc, &c);
    if (c.err == MML_NOMEM) {
        mml_resolver_close(r);
        return mml_rfail(why, whysz, MML_NOMEM, "out of memory");
    }
    if (c.err) {
        mml_resolver_close(r);
        return mml_rfail(why, whysz, MML_MALFORMED, "more than %d segments", MML_MAX_SEGS);
    }
    if (c.di && c.di->rebase_size) {
        if (!mml_fits(c.di->rebase_off, c.di->rebase_size, im->size)) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_MALFORMED, "the rebase stream lies outside the file");
        }
        rc = mrb_decode(im->buf + c.di->rebase_off, c.di->rebase_size, r->nsegs, &r->rebases,
                        why, whysz);
        if (rc != MRB_OK) {
            mml_resolver_close(r);
            return rc == MRB_NOMEM ? MML_NOMEM : MML_MALFORMED;
        }
    }
    if (c.di && c.di->bind_size) {
        if (!mml_fits(c.di->bind_off, c.di->bind_size, im->size) ||
            mo_bind_observe(im->buf + c.di->bind_off, c.di->bind_size, "bind",
                            mml_note_bind, &c) != 0) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_MALFORMED, "the bind stream does not decode");
        }
        if (c.err) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_NOMEM, "out of memory");
        }
    }
    mrb_sort(&r->rebases);
    mrb_sort(&r->binds);
    if (c.fs && c.fs->datasize) {
        uint64_t base;
        int n;
        if (!mml_fits(c.fs->dataoff, c.fs->datasize, im->size) || mi_image_base(im, &base) != 0) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_MALFORMED, "LC_FUNCTION_STARTS lies outside the file");
        }
        if (!(r->starts = malloc((size_t)c.fs->datasize * sizeof *r->starts))) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_NOMEM, "out of memory");
        }
        n = mg_funcstarts_decode(im->buf + c.fs->dataoff, c.fs->datasize, base, r->starts,
                                 (int)c.fs->datasize);
        if (n < 0) {
            mml_resolver_close(r);
            return mml_rfail(why, whysz, MML_MALFORMED, "LC_FUNCTION_STARTS does not decode");
        }
        r->nstarts = n ? n : -1;
    }
    return MML_OK;
}

void mml_resolver_close(mml_resolver *r) {
    free(r->sects);
    free(r->starts);
    mrb_free(&r->rebases);
    mrb_free(&r->binds);
    r->sects = NULL;
    r->starts = NULL;
    r->nsects = 0;
}

int mml_seg_of(const mml_resolver *r, uint64_t va, uint64_t len) {
    for (int i = 0; i < r->nsegs; i++) {
        uint64_t rel = va - r->segs[i].vmaddr;
        if (va < r->segs[i].vmaddr || rel >= r->segs[i].filesize) continue;
        if (len > r->segs[i].filesize - rel ||
            !mml_fits(r->segs[i].fileoff + rel, len, r->im->size)) return -1;
        return i;
    }
    return -1;
}

int mml_off_rebased(const mml_resolver *r, uint64_t off) {
    for (int i = 0; i < r->nsegs; i++)
        if (off >= r->segs[i].fileoff && off - r->segs[i].fileoff < r->segs[i].filesize)
            return mrb_has(&r->rebases, (uint8_t)i, off - r->segs[i].fileoff);
    return 0;
}

/* Like mrb_has, but only for a slot rebased as REBASE_TYPE_POINTER: a
 * selector reference is loaded and dereferenced whole, so a rebase that
 * dyld would write as a narrower fixup (REBASE_TYPE_TEXT_ABSOLUTE32, which
 * mrb_decode now also accepts) at the same (seg, off) is not good enough --
 * mrb_has alone can't tell the two apart. */
static int mml_pointer_rebased(const mml_resolver *r, uint8_t seg, uint64_t off) {
    const mrb_slot *v = r->rebases.v;
    size_t n = r->rebases.n, lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (v[mid].seg < seg || (v[mid].seg == seg && v[mid].off < off)) lo = mid + 1;
        else hi = mid;
    }
    for (; lo < n && v[lo].seg == seg && v[lo].off == off; lo++)
        if (v[lo].type == REBASE_TYPE_POINTER) return 1;
    return 0;
}

static const mml_sect *mml_sect_at(const mml_resolver *r, uint64_t va) {
    for (uint32_t k = 0; k < r->nsects; k++)
        if (va >= r->sects[k].addr && va - r->sects[k].addr < r->sects[k].size) return &r->sects[k];
    return NULL;
}

static int mml_cstring(const mml_resolver *r, uint64_t va) {
    const mml_sect *s = mml_sect_at(r, va);
    if (!s || (s->flags & SECTION_TYPE) != S_CSTRING_LITERALS || !s->offset ||
        !mml_fits(s->offset, s->size, r->im->size)) return 0;
    return memchr(r->im->buf + s->offset + (va - s->addr), 0, s->size - (va - s->addr)) != NULL;
}

int mml_entry_at(const mml_resolver *r, const mml_ref *ref, uint32_t i, mml_entry *e,
                 char *why, size_t whysz) {
    const uint8_t *buf = r->im->buf;
    if (!(ref->header & MML_RELATIVE)) {
        const uint8_t *p = buf + ref->list_off + 8 + (uint64_t)MML_ABS_ENTSIZE * i;
        memcpy(&e->name, p, 8);
        memcpy(&e->types, p + 8, 8);
        memcpy(&e->imp, p + 16, 8);
        return MML_OK;
    }
    uint64_t va = ref->list_va + 8 + (uint64_t)MML_REL_ENTSIZE * i;
    int32_t d[3];
    memcpy(d, buf + ref->list_off + 8 + (uint64_t)MML_REL_ENTSIZE * i, sizeof d);
    uint64_t slot = va + (uint64_t)(int64_t)d[0];
    uint64_t types = va + 4 + (uint64_t)(int64_t)d[1];
    uint64_t imp = d[2] ? va + 8 + (uint64_t)(int64_t)d[2] : 0;
    const unsigned long long lva = (unsigned long long)ref->list_va;
    int si;

    if (slot & 7)
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx names "
                         "a selector reference at 0x%llx, which is not 8-byte aligned",
                         i, lva, (unsigned long long)slot);
    if ((si = mml_seg_of(r, slot, 8)) < 0)
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx names "
                         "a selector reference at 0x%llx, which lies outside the file",
                         i, lva, (unsigned long long)slot);
    uint64_t rel = slot - r->segs[si].vmaddr;
    if (!mml_pointer_rebased(r, (uint8_t)si, rel))
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx names "
                         "the selector reference at 0x%llx, which %s", i, lva, (unsigned long long)slot,
                         mrb_has(&r->binds, (uint8_t)si, rel)
                             ? "is bound to another image, so its name is not in this one"
                             : "carries no rebase");
    memcpy(&e->name, buf + r->segs[si].fileoff + rel, 8);
    if (!mml_cstring(r, e->name))
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx: the "
                         "selector reference at 0x%llx holds 0x%llx, which is not a C string",
                         i, lva, (unsigned long long)slot, (unsigned long long)e->name);
    if (!mml_cstring(r, types))
        return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx: its "
                         "types at 0x%llx are not a C string", i, lva, (unsigned long long)types);
    if (imp) {
        const mml_sect *s = mml_sect_at(r, imp);
        if (!s || !(s->flags & (S_ATTR_SOME_INSTRUCTIONS | S_ATTR_PURE_INSTRUCTIONS)))
            return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx: "
                             "its implementation at 0x%llx is not in a section of instructions",
                             i, lva, (unsigned long long)imp);
        if (r->nstarts > 0 && !mg_addr_known(r->starts, r->nstarts, imp))
            return mml_rfail(why, whysz, MML_MALFORMED, "entry %u of the method list at 0x%llx: "
                             "its implementation at 0x%llx is not one of the %d function starts "
                             "in LC_FUNCTION_STARTS", i, lva, (unsigned long long)imp, r->nstarts);
    }
    e->types = types;
    e->imp = imp;
    return MML_OK;
}
