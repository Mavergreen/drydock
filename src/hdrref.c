/* mhr_ -- see hdrref.h. */
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "hdrref.h"
#include "image.h"
#include "uleb.h"
#include "x86len.h"

static const int mhr_immlens[4] = { 0, 1, 2, 4 };

static uint64_t mhr_code(const uint8_t *code, uint64_t size, uint64_t addr, uint64_t off,
                         uint64_t target, mhr_fn fn, void *ctx, int *stopped) {
    uint64_t n = 0;
    for (uint64_t i = 0; i + 5 <= size; i++) {
        if ((code[i] & 0xC7) != 0x05) continue;
        int32_t disp;
        memcpy(&disp, code + i + 1, sizeof disp);
        uint64_t at = addr + i + 1;
        for (int k = 0; k < 4; k++) {
            if (at + 4 + (uint64_t)mhr_immlens[k] + (uint64_t)(int64_t)disp != target) continue;
            mhr_cand c = { at, off + i + 1, mhr_immlens[k] };
            n++;
            if (fn && fn(&c, ctx)) { *stopped = 1; return n; }
        }
    }
    return n;
}

uint64_t mhr_scan_code(const uint8_t *code, uint64_t size, uint64_t addr, uint64_t off,
                       uint64_t target, mhr_fn fn, void *ctx) {
    int stopped = 0;
    return mhr_code(code, size, addr, off, target, fn, ctx, &stopped);
}

struct mhr_ctx {
    const uint8_t *buf;
    size_t fsize;
    uint64_t target;
    mhr_fn fn;
    void *ctx;
    uint64_t n;
    int stopped, bad;
    const struct section_64 **sect;   /* if not NULL, the section being scanned */
};

static int mhr_seg_cb(const struct load_command *lc, void *ctx_) {
    struct mhr_ctx *w = (struct mhr_ctx *)ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(seg + 1);
    for (uint32_t j = 0; j < seg->nsects; j++) {
        if (!(s[j].flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) continue;
        if (s[j].offset == 0) continue;
        if (s[j].size > w->fsize || s[j].offset > w->fsize - s[j].size) { w->bad = 1; continue; }
        if (w->sect) *w->sect = &s[j];
        w->n += mhr_code(w->buf + s[j].offset, s[j].size, s[j].addr, s[j].offset,
                         w->target, w->fn, w->ctx, &w->stopped);
        if (w->stopped) return 1;
    }
    return 0;
}

static int64_t mhr_walk(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx,
                        const struct section_64 **sect) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0) return -1;
    struct mhr_ctx w = { buf, fsize, target, fn, ctx, 0, 0, 0, sect };
    mi_each_lc(&im, mhr_seg_cb, &w);
    return w.bad ? -1 : (int64_t)w.n;
}

int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx) {
    return mhr_walk(buf, fsize, target, fn, ctx, NULL);
}

struct mhr_range { uint64_t from, to; };

/* What a sweep needs, read once: LC_FUNCTION_STARTS as addresses, and
 * LC_DATA_IN_CODE as ranges in address order. */
struct mhr_map {
    const uint8_t *buf;
    uint64_t base;
    uint64_t *starts;
    size_t nstarts;
    struct mhr_range *dic;
    size_t ndic;
};

/* The first of each command counts, as in src/grow.c. */
struct mhr_lcs { const struct linkedit_data_command *fs, *dic; };
static int mhr_lcs_cb(const struct load_command *lc, void *ctx_) {
    struct mhr_lcs *l = (struct mhr_lcs *)ctx_;
    if (lc->cmd == LC_FUNCTION_STARTS && !l->fs) l->fs = (const struct linkedit_data_command *)lc;
    if (lc->cmd == LC_DATA_IN_CODE && !l->dic) l->dic = (const struct linkedit_data_command *)lc;
    return 0;
}

/* How many bytes of `d`'s payload to read: none if it runs past the file. */
static uint32_t mhr_payload(const struct linkedit_data_command *d, size_t fsize) {
    if (!d || d->datasize > fsize || d->dataoff > fsize - d->datasize) return 0;
    return d->datasize;
}

static int mhr_by_from(const void *a, const void *b) {
    uint64_t x = ((const struct mhr_range *)a)->from, y = ((const struct mhr_range *)b)->from;
    return x < y ? -1 : x > y;
}

/* mhr_map_read's failures, beyond 0 (ok): a malloc failure (mhr_confirm
 * answers -1 for this, same as its other "memory runs out" cases), or an
 * LC_DATA_IN_CODE payload too broken to trust the code around it -- past the
 * image, or not a multiple of the 8-byte entry it must decode as. Silently
 * treating either as "no data-in-code to step over" would sweep literal data
 * as code, so mhr_confirm answers MHR_UNSCANNABLE instead. */
#define MHR_MAP_ALLOC   (-1)
#define MHR_MAP_BAD_DIC (-2)

static int mhr_map_read(struct mhr_map *m, const mi_image *im, size_t fsize) {
    struct mhr_lcs l = { NULL, NULL };
    mi_each_lc(im, mhr_lcs_cb, &l);
    if (l.dic && l.dic->datasize && (l.dic->datasize % 8 || l.dic->datasize > fsize ||
                                     l.dic->dataoff > fsize - l.dic->datasize))
        return MHR_MAP_BAD_DIC;
    uint32_t nfs = mhr_payload(l.fs, fsize), ndic = l.dic ? l.dic->datasize / 8 : 0;
    m->starts = (uint64_t *)malloc(nfs * sizeof *m->starts + 1);
    m->dic = (struct mhr_range *)malloc(ndic * sizeof *m->dic + 1);
    if (!m->starts || !m->dic) return MHR_MAP_ALLOC;
    const uint8_t *p = m->buf + (nfs ? l.fs->dataoff : 0), *end = p + nfs;
    uint64_t a = m->base, delta;
    int malformed = 0;
    for (int n; p < end; p += n) {
        n = mu_decode(p, end, &delta);
        if (n == 0) { malformed = 1; break; }
        if (delta == 0) break;
        uint64_t next = a + delta;
        if (next <= a) { malformed = 1; break; }   /* wrapped: non-monotonic */
        a = next;
        m->starts[m->nstarts++] = a;
    }
    if (malformed) m->nstarts = 0;   /* a partially-read list is not trustworthy */
    for (p = m->buf + (ndic ? l.dic->dataoff : 0); m->ndic < ndic; p += 8) {
        uint32_t off;
        uint16_t len;
        memcpy(&off, p, sizeof off);
        memcpy(&len, p + 4, sizeof len);
        m->dic[m->ndic].from = m->base + off;
        m->dic[m->ndic++].to = m->base + off + len;
    }
    qsort(m->dic, m->ndic, sizeof *m->dic, mhr_by_from);
    return 0;
}

/* Where the last sweep stopped: at `pc`, in the function starting at `start`
 * in section `s`, with dic[0, k) all ending at or before pc. Candidates come
 * in address order within a section, so the next one in the same function
 * takes up the same walk from there, and any later function can keep k. */
struct mhr_resume {
    const struct section_64 *s;
    uint64_t start, pc;
    size_t k;
};

/* Decodes from `start`, a function start in section `s`, to candidate `c`: 1
 * if the instruction holding c's disp32 is RIP-relative through it, with the
 * immediate that makes its target c's. */
static int mhr_sweep(const struct mhr_map *m, const struct section_64 *s, uint64_t start,
                     const mhr_cand *c, struct mhr_resume *r) {
    const uint8_t *code = m->buf + s->offset;
    uint64_t end = s->addr + s->size, pc = start;
    size_t k = 0;
    if (r->s == s && r->start == start) {
        pc = r->pc;
        k = r->k;
    } else if (r->pc <= start) {
        k = r->k;
    }
    while (pc < c->addr) {
        while (k < m->ndic && m->dic[k].to <= pc) k++;
        if (k < m->ndic && m->dic[k].from <= pc) { pc = m->dic[k].to; continue; }
        mx_insn in;
        if (!mx_decode(code + (pc - s->addr), (size_t)(end - pc), &in)) return 0;
        /* A range starting inside [pc, pc+len) -- not at or before pc -- means
         * this "instruction" is partly data: its bytes are not all code, so it
         * cannot be the one that addresses c. */
        if (k < m->ndic && m->dic[k].from < pc + (uint64_t)in.len) return 0;
        if (pc + (uint64_t)in.len > c->addr) {
            r->s = s;
            r->start = start;
            r->pc = pc;
            r->k = k;
            return in.modrm >= 0 && !in.adsize &&
                   (code[pc - s->addr + (uint64_t)in.modrm] & 0xC7) == 0x05 &&
                   pc + (uint64_t)in.disp == c->addr &&
                   pc + (uint64_t)in.len == c->addr + 4 + (uint64_t)c->immlen;
        }
        pc += (uint64_t)in.len;
    }
    return 0;
}

struct mhr_confirm_ctx {
    const struct mhr_map *m;
    const struct section_64 *sect;
    int status;
    mhr_cand *bad;
    struct mhr_resume r;
};

static int mhr_confirm_cb(const mhr_cand *c, void *ctx_) {
    struct mhr_confirm_ctx *x = (struct mhr_confirm_ctx *)ctx_;
    const struct mhr_map *m = x->m;
    size_t lo = 0, hi = m->nstarts;               /* past the last start at or below c */
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (m->starts[mid] <= c->addr) lo = mid + 1; else hi = mid; }
    if (lo > 0 && m->starts[lo - 1] >= x->sect->addr && mhr_sweep(m, x->sect, m->starts[lo - 1], c, &x->r))
        return 0;
    x->status = m->nstarts ? MHR_UNCONFIRMED : MHR_NO_STARTS;
    *x->bad = *c;
    return 1;
}

int mhr_confirm(const uint8_t *buf, size_t fsize, mhr_cand *bad) {
    mi_image im;
    struct mhr_map m = { buf, 0, NULL, 0, NULL, 0 };
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0 || mi_image_base(&im, &m.base) != 0) return -1;
    int rc = -1, mr = mhr_map_read(&m, &im, fsize);
    if (mr == MHR_MAP_BAD_DIC) {
        rc = MHR_UNSCANNABLE;
    } else if (mr == 0) {
        struct mhr_confirm_ctx x = { &m, NULL, MHR_CONFIRMED, bad, { NULL, 0, 0, 0 } };
        rc = mhr_walk(buf, fsize, m.base, mhr_confirm_cb, &x, &x.sect) < 0 ? MHR_UNSCANNABLE : x.status;
    }
    free(m.starts);
    free(m.dic);
    return rc;
}
