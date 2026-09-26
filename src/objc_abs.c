/* mma_ -- see objc_abs.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "objc_abs.h"
#include "linkedit.h"
#include "mach_compat.h"

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
    if (d->vmaddr + d->vmsize != l->vmaddr)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s ends at 0x%llx in memory, and __LINKEDIT "
                        "begins at 0x%llx", d->name, (unsigned long long)(d->vmaddr + d->vmsize),
                        (unsigned long long)l->vmaddr);
    if (d->fileoff + d->filesize != l->fileoff)
        return mma_fail(why, whysz, MMA_REFUSED, "%.16s ends at file offset 0x%llx, and __LINKEDIT "
                        "begins at 0x%llx", d->name, (unsigned long long)(d->fileoff + d->filesize),
                        (unsigned long long)l->fileoff);
    if (l->fileoff + l->filesize != file_size)
        return mma_fail(why, whysz, MMA_REFUSED, "__LINKEDIT ends at file offset 0x%llx, and the "
                        "image is 0x%llx bytes", (unsigned long long)(l->fileoff + l->filesize),
                        (unsigned long long)file_size);
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

int mma_insert(const mi_image *im, const mma_layout *lay, const uint8_t *lists,
               uint64_t lists_len, uint64_t s, const uint8_t *stream, uint32_t r,
               uint8_t **out, size_t *outsz, char *why, size_t whysz) {
    const struct dyld_info_command *odi = NULL;
    uint64_t grow = lay->z + s + r, at;
    uint8_t *nb;
    mi_image nim;
    mma_edit_ctx c;

    *out = NULL;
    *outsz = 0;
    if (s % MMA_PAGE || lists_len > s || r % 8)
        return mma_fail(why, whysz, MMA_REFUSED, "internal error: %llu list bytes in %llu, "
                        "%u stream bytes", (unsigned long long)lists_len, (unsigned long long)s, r);
    mi_each_lc(im, mma_find_info, &odi);
    if (!odi)
        return mma_fail(why, whysz, MMA_REFUSED, "no LC_DYLD_INFO: there is no rebase stream to extend");
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
    if (c.di->rebase_size) memset(nb + c.di->rebase_off, 0, c.di->rebase_size);
    c.di->rebase_off = (uint32_t)(at + lay->z + s);
    c.di->rebase_size = r;
    *out = nb;
    *outsz = im->size + grow;
    return MMA_OK;
}
