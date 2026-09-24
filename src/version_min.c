/* mv_ -- see version_min.h. */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>

#include "version_min.h"
#include "mach_compat.h"
#include "image.h"
#include "grow.h"
#include "rewrite.h"

void mv_format_version(uint32_t v, char out[16]) {
    if (v & 0xff) snprintf(out, 16, "%u.%u.%u", v >> 16, (v >> 8) & 0xff, v & 0xff);
    else          snprintf(out, 16, "%u.%u", v >> 16, (v >> 8) & 0xff);
}

struct mv_decl_scan {
    int      n_vm, n_macos, n_bv, n_foreign, n_catalyst, n_other, short_cmd;
    uint32_t vm_version, vm_sdk, bv_minos, bv_sdk, foreign, other;
};

static int mv_decl_lc(const struct load_command *lc, void *ctx_) {
    struct mv_decl_scan *c = ctx_;
    if (lc->cmd == LC_VERSION_MIN_MACOSX) {
        const struct version_min_command *vm = (const struct version_min_command *)lc;
        if (lc->cmdsize < sizeof *vm) { c->short_cmd = 1; return 1; }
        if (c->n_vm++ == 0) { c->vm_version = vm->version; c->vm_sdk = vm->sdk; }
    } else if (lc->cmd == LC_BUILD_VERSION) {
        const struct mc_build_version *bv = (const struct mc_build_version *)lc;
        if (lc->cmdsize < sizeof *bv) { c->short_cmd = 1; return 1; }
        c->n_bv++;
        if (bv->platform == MV_PLATFORM_MACOS) {
            if (c->n_macos++ == 0) { c->bv_minos = bv->minos; c->bv_sdk = bv->sdk; }
            return 0;
        }
        if (c->n_foreign++ == 0) c->foreign = bv->platform;
        if (bv->platform == MV_PLATFORM_MACCATALYST) c->n_catalyst++;
        else if (c->n_other++ == 0) c->other = bv->platform;
    }
    return 0;
}

static int mv_refuse_platform(const struct mv_decl_scan *c, const char *label) {
    if (c->n_foreign && !c->n_vm && !c->n_macos) {
        fprintf(stderr, "%s: declares platform %u, not macOS; refusing to add a macOS minimum to it\n",
                label, c->foreign);
        return 1;
    }
    if (c->n_other) {
        fprintf(stderr, "%s: declares platform %u beside macOS; refusing rather than guess which it is\n",
                label, c->other);
        return 1;
    }
    return 0;
}

int mv_foreign_platform(const mi_image *im, const char *label) {
    struct mv_decl_scan c;
    memset(&c, 0, sizeof c);
    mi_each_lc(im, mv_decl_lc, &c);
    return mv_refuse_platform(&c, label);
}

static void mv_remove_build_versions(uint8_t *buf) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = buf + sizeof *h;
    uint32_t end = (uint32_t)sizeof *h + h->sizeofcmds, i = 0;
    while (i < h->ncmds) {
        struct load_command *lc = (struct load_command *)p;
        uint32_t sz = lc->cmdsize;
        if (lc->cmd == LC_BUILD_VERSION) {
            memmove(p, p + sz, end - (uint32_t)(p - buf) - sz);
            memset(buf + end - sz, 0, sz);
            end -= sz; h->ncmds--; h->sizeofcmds -= sz;
            continue;
        }
        p += sz; i++;
    }
}

static void mv_rewrite_version(uint8_t *buf, uint32_t version) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = buf + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_VERSION_MIN_MACOSX) {
            ((struct version_min_command *)lc)->version = version;
            return;
        }
        p += lc->cmdsize;
    }
}

static void mv_append_version_min(uint8_t *buf, uint32_t version, uint32_t sdk) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct version_min_command *vm =
        (struct version_min_command *)(buf + sizeof *h + h->sizeofcmds);
    vm->cmd = LC_VERSION_MIN_MACOSX;
    vm->cmdsize = sizeof *vm;
    vm->version = version;
    vm->sdk = sdk;
    h->ncmds++;
    h->sizeofcmds += sizeof *vm;
}

int mv_declare_minos(uint8_t **pbuf, size_t *psize, const char *label, int rule,
                     uint32_t version, uint32_t mask, mv_decl_report *r) {
    struct mv_decl_scan c;
    mi_image im;
    memset(r, 0, sizeof *r);
    memset(&c, 0, sizeof c);
    if (mi_wrap(*pbuf, *psize, &im) != 0) {
        fprintf(stderr, "%s: not a readable 64-bit Mach-O\n", label);
        return MR_REFUSED;
    }
    mi_each_lc(&im, mv_decl_lc, &c);
    if (c.short_cmd) {
        fprintf(stderr, "%s: a version load command is shorter than its structure; refusing\n", label);
        return MR_REFUSED;
    }
    if (c.n_vm > 1) {
        fprintf(stderr, "%s: %d LC_VERSION_MIN_MACOSX commands; refusing rather than choose one\n",
                label, c.n_vm);
        return MR_REFUSED;
    }
    if (c.n_macos > 1) {
        fprintf(stderr, "%s: %d macOS LC_BUILD_VERSION commands; refusing rather than choose one\n",
                label, c.n_macos);
        return MR_REFUSED;
    }
    if (mv_refuse_platform(&c, label)) return MR_REFUSED;

    r->from = c.n_vm ? MV_FROM_VERSION_MIN : c.n_macos ? MV_FROM_BUILD_VERSION : MV_FROM_NONE;
    r->declared = r->from == MV_FROM_VERSION_MIN ? c.vm_version : c.bv_minos;
    r->above = r->from != MV_FROM_NONE && (r->declared & mask) > version;
    r->minos = r->from == MV_FROM_NONE || (rule == MV_AT_MOST && r->above) ? version : r->declared;
    r->sdk = r->from == MV_FROM_VERSION_MIN ? c.vm_sdk
           : r->from == MV_FROM_BUILD_VERSION ? c.bv_sdk : MV_10_9;
    r->dropped_macos = r->from == MV_FROM_VERSION_MIN && c.n_macos;
    r->dropped_minos = c.bv_minos;
    r->catalyst = c.n_catalyst;

    if (r->from == MV_FROM_VERSION_MIN && !c.n_bv && r->minos == r->declared) return 0;
    if (r->from == MV_FROM_NONE) {
        uint32_t need_end = (uint32_t)sizeof(struct mach_header_64) + im.hdr->sizeofcmds +
                            (uint32_t)sizeof(struct version_min_command);
        if (mg_ensure_pad(pbuf, psize, need_end, label) != 0 || need_end > *psize) {
            fprintf(stderr, "%s: no room for LC_VERSION_MIN_MACOSX\n", label);
            return MR_REFUSED;
        }
        mv_append_version_min(*pbuf, r->minos, r->sdk);
    } else {
        mv_remove_build_versions(*pbuf);
        if (r->from == MV_FROM_VERSION_MIN) mv_rewrite_version(*pbuf, r->minos);
        else                                mv_append_version_min(*pbuf, r->minos, r->sdk);
    }
    r->changed = 1;
    return 0;
}
