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
    if (s % MMA_PAGE || lists_len > s || r % 8)
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
