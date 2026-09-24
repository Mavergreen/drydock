/*
 * mv_ -- see version_min.h. This started as compat/add_version_min.c's
 * main(); only the argument check stayed behind in that tool. A short header
 * pad is grown, via mg_ensure_pad (src/grow.h), whose own refusal precedes
 * this file's "no room for LC_VERSION_MIN_MACOSX" when the image cannot be
 * grown. Its in-memory middle is mv_add_version_min_image, so an edit script
 * can apply it to a buffer.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <mach-o/loader.h>

#include "version_min.h"
#include "mach_compat.h"
#include "image.h"
#include "grow.h"
#include "atomic_write.h"   /* wa_write_new: `path` is read, `out` is written */
#include "rewrite.h"    /* MR_REFUSED/MR_FAIL: this function's own exit-code
                         * vocabulary, shared with mr_apply_file -- see the
                         * comment on the MR_REFUSED/MR_FAIL #defines there
                         * for the dividing line this follows. */

struct mv_scan {
    uint32_t first_sect_off;   /* lowest nonzero section file offset;
                                 * UINT32_MAX if no section has one. Only
                                 * that sentinel is consulted: mg_ensure_pad
                                 * finds the pad's bound for itself. */
    int      has_version_min;
};

static int mv_scan_lc(const struct load_command *lc, void *ctx_) {
    struct mv_scan *ctx = ctx_;
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *sect = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++)
            if (sect[j].offset && sect[j].offset < ctx->first_sect_off)
                ctx->first_sect_off = sect[j].offset;
    } else if (lc->cmd == LC_VERSION_MIN_MACOSX) {
        ctx->has_version_min = 1;
    }
    return 0;   /* nothing here ever needs to stop the walk early */
}

/* This function's return value is forwarded verbatim by whatever calls it,
 * the same arrangement mr_apply_file
 * has with its own callers -- so every return below is MR_REFUSED or MR_FAIL,
 * the same two codes and the same dividing line rewrite.h's comment on the
 * MR_REFUSED/MR_FAIL #defines draws: MR_FAIL for this function's own
 * open/fstat, for mi_open's own I/O (MI_IO_ERROR, below) and for
 * wa_write_new's failure to produce `out`; MR_REFUSED for every site that
 * examined the file and declined, including mi_open's MI_NOT_MACHO and
 * "no room for LC_VERSION_MIN_MACOSX". */
int mv_add_version_min(const char *path, const char *out) {
    /* Opened only to report an unreadable `path` immediately, before any
     * analysis, in the words the historical tool's own open() produced;
     * mi_open (O_RDONLY too) does the actual read and validation. Nothing is
     * ever written through this descriptor -- `path` is an input now -- so it
     * is closed again at once and the result goes to `out`. */
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open"); return MR_FAIL; }
    struct stat st0;
    if (fstat(fd, &st0) != 0) { perror("fstat"); close(fd); return MR_FAIL; }
    close(fd);

    mi_image im;
    int mo_rc = mi_open(path, &im);
    if (mo_rc == MI_IO_ERROR) {
        /* The open()/fstat() above only proved this path opens, not that
         * mi_open's own independent open, read of the whole file, or the
         * malloc it reads into will succeed too -- any of those, or an
         * actual TOCTOU race, land here. Not a considered refusal either
         * way. */
        fprintf(stderr, "%s: cannot open or read\n", path);
        return MR_FAIL;
    }
    if (mo_rc != 0) {
        fprintf(stderr, "%s: not a readable 64-bit Mach-O\n", path);
        return MR_REFUSED;
    }

    /* The edit itself, in memory; what is left here is the file around it.
     * mi_release first: growing may reallocate the buffer, and the image
     * wrapper must not be left owning a pointer that realloc moved. */
    size_t fsize = im.size;
    uint8_t *buf = mi_release(&im);
    int added = 0;
    int rc = mv_add_version_min_image(&buf, &fsize, path, MV_10_9, &added);
    if (rc != 0) {
        free(buf);
        return rc;
    }

    /* Written even when nothing was added: a 0 exit means `out` is the
     * answer, so it has to exist either way. wa_write_new creates it afresh
     * from `path`'s mode, owner and xattrs and never touches `path`. */
    struct mach_header_64 *hdr = (struct mach_header_64 *)buf;
    int wr = wa_write_new(path, out, buf, fsize);
    if (wr == WA_IS_INPUT) { free(buf); return MR_FAIL; }   /* checked earlier; a path changed */
    if (wr != 0) { free(buf); return MR_FAIL; }
    if (added)
        printf("Added LC_VERSION_MIN_MACOSX 10.9 (ncmds=%u, sizeofcmds=%u)\n",
               hdr->ncmds, hdr->sizeofcmds);
    printf("Wrote %s (%zu bytes)\n", out, fsize);
    free(buf);
    return 0;
}

/* See version_min.h. mv_add_version_min's former middle, moved rather than
 * copied: the scan, the "already present" and "no room" answers, and the
 * append, all against the caller's buffer and none of the file around it. */
int mv_add_version_min_image(uint8_t **pbuf, size_t *psize,
                             const char *label, uint32_t sdk, int *out_added) {
    *out_added = 0;
    mi_image im;
    if (mi_wrap(*pbuf, *psize, &im) != 0) {
        fprintf(stderr, "not a readable 64-bit Mach-O\n");
        return MR_REFUSED;
    }
    struct mach_header_64 *hdr = im.hdr;

    struct mv_scan scan = { UINT32_MAX, 0 };
    mi_each_lc(&im, mv_scan_lc, &scan);

    if (scan.has_version_min) {
        printf("LC_VERSION_MIN_MACOSX already present; nothing to do.\n");
        return 0;
    }

    uint32_t lc_end   = sizeof(*hdr) + hdr->sizeofcmds;
    uint32_t need_end = lc_end + (uint32_t)sizeof(struct version_min_command);
    /* Two ways "no room" is true that growing cannot cure, both refused
     * before anything is written: no section anywhere has a nonzero file
     * offset (scan.first_sect_off is still its UINT32_MAX sentinel, and a
     * write would go off whatever end the buffer has), or the command would
     * run past the buffer itself -- mi_wrap validates load commands, not
     * section file ranges, so first_sect_off is an untrusted value read
     * straight from the file. Fixed after a real heap overflow: a 104-byte
     * file (header + one LC_SEGMENT_64, nsects=0) hit exactly the first case
     * and wrote 16 bytes past a buffer whose allocation was exactly
     * file-sized; see tests/leaf-tool-crashes.sh. */
    if (scan.first_sect_off == UINT32_MAX || need_end > *psize) {
        fprintf(stderr, "no room for LC_VERSION_MIN_MACOSX\n");
        return MR_REFUSED;
    }
    /* Whether the command fits in the pad before the first section, and if
     * not whether to grow it, is mg_ensure_pad's to decide, the same as for
     * every other load-command edit. It returns 0 at once, untouched, when
     * the command fits, and it refuses an image whose first section lies
     * past the buffer's end. */
    if (mg_ensure_pad(pbuf, psize, need_end, label) != 0) {
        fprintf(stderr, "no room for LC_VERSION_MIN_MACOSX\n");
        return MR_REFUSED;
    }
    hdr = (struct mach_header_64 *)*pbuf;   /* growth may have reallocated it */

    struct version_min_command *vm = (struct version_min_command *)(*pbuf + lc_end);
    memset(vm, 0, sizeof(*vm));
    vm->cmd = LC_VERSION_MIN_MACOSX;
    vm->cmdsize = sizeof(*vm);
    vm->version = MV_10_9;
    vm->sdk     = sdk;
    hdr->ncmds++;
    hdr->sizeofcmds += sizeof(*vm);
    *out_added = 1;
    return 0;
}

struct mv_set_ctx { uint32_t version; mv_minos_report *r; };

static int mv_set_lc(const struct load_command *lc, void *ctx_) {
    struct mv_set_ctx *c = ctx_;
    if (lc->cmd == LC_VERSION_MIN_MACOSX && lc->cmdsize >= sizeof(struct version_min_command)) {
        struct version_min_command *vm = (struct version_min_command *)lc;
        if (c->r->version_min++ == 0) c->r->version_min_was = vm->version;
        vm->version = c->version;
    } else if (lc->cmd == LC_BUILD_VERSION && lc->cmdsize >= sizeof(struct mc_build_version)) {
        struct mc_build_version *bv = (struct mc_build_version *)lc;
        if (bv->platform != MV_PLATFORM_MACOS) return 0;
        if (c->r->build_version++ == 0) c->r->build_version_was = bv->minos;
        bv->minos = c->version;
    }
    return 0;
}

void mv_set_minos(mi_image *im, uint32_t version, mv_minos_report *r) {
    struct mv_set_ctx c = { version, r };
    memset(r, 0, sizeof *r);
    mi_each_lc(im, mv_set_lc, &c);
}

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
    if (c.n_foreign && !c.n_vm && !c.n_macos) {
        fprintf(stderr, "%s: declares platform %u, not macOS; refusing to add a macOS minimum to it\n",
                label, c.foreign);
        return MR_REFUSED;
    }
    if (c.n_other) {
        fprintf(stderr, "%s: declares platform %u beside macOS; refusing rather than guess which it is\n",
                label, c.other);
        return MR_REFUSED;
    }

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
        uint32_t first = mg_first_sect_off(*pbuf, *psize);
        if (first == MG_NO_SECTION_DATA || first == UINT32_MAX || need_end > *psize ||
            mg_ensure_pad(pbuf, psize, need_end, label) != 0) {
            fprintf(stderr, "no room for LC_VERSION_MIN_MACOSX\n");
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
