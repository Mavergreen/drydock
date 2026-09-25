/* mhr_ -- see hdrref.h. */
#include <string.h>
#include <mach-o/loader.h>

#include "hdrref.h"
#include "image.h"

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
};

static int mhr_seg_cb(const struct load_command *lc, void *ctx_) {
    struct mhr_ctx *c = (struct mhr_ctx *)ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(seg + 1);
    for (uint32_t j = 0; j < seg->nsects; j++) {
        if (!(s[j].flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) continue;
        if (s[j].offset == 0) continue;
        if (s[j].size > c->fsize || s[j].offset > c->fsize - s[j].size) { c->bad = 1; continue; }
        c->n += mhr_code(c->buf + s[j].offset, s[j].size, s[j].addr, s[j].offset,
                         c->target, c->fn, c->ctx, &c->stopped);
        if (c->stopped) return 1;
    }
    return 0;
}

int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, fsize, &im) != 0) return -1;
    struct mhr_ctx c = { buf, fsize, target, fn, ctx, 0, 0, 0 };
    mi_each_lc(&im, mhr_seg_cb, &c);
    return c.bad ? -1 : (int64_t)c.n;
}
