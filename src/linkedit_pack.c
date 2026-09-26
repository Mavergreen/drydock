/* linkedit_pack.c -- mlo_pack and mlo_changed; see linkedit_order.h. */
#include "linkedit_order.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mach_compat.h"

/* The pieces, in the order the pass writes them: ld64's, with the two
 * modern blobs where cctools-1035 wants them. */
enum { MLO_P_REBASE, MLO_P_BIND, MLO_P_WEAK, MLO_P_LAZY, MLO_P_EXPORT, MLO_P_CHAINED,
       MLO_P_TRIE, MLO_P_LOCREL, MLO_P_SPLIT, MLO_P_FSTARTS, MLO_P_DIC, MLO_P_DRS,
       MLO_P_LOH, MLO_P_SYMTAB, MLO_P_HINTS, MLO_P_EXTREL, MLO_P_INDIRECT, MLO_P_TOC,
       MLO_P_MODTAB, MLO_P_REFS, MLO_P_STRTAB, MLO_P_SIG, MLO_P_N };

static const char *const mlo_pname[MLO_P_N] = {
    "the rebase opcodes", "the bind opcodes", "the weak-bind opcodes", "the lazy-bind opcodes",
    "the export trie", "the chained fixups", "the exports trie", "the local relocations",
    "the split info", "the function starts", "the data in code", "the code-signing DRs",
    "the linker hints", "the symbol table", "the two-level hints", "the external relocations",
    "the indirect symbol table", "the table of contents", "the module table",
    "the reference table", "the string table", "the code signature" };

typedef struct {
    uint32_t *off;     /* its offset field, in the load command */
    uint64_t  size;    /* bytes */
    int       present; /* the command that names it exists */
} mlo_piece;

typedef struct {
    mlo_piece p[MLO_P_N];
    struct segment_command_64 *le;
    uint32_t nind;     /* the indirect table's count, for the 8-rounding */
    int      modern;   /* a chained-fixups or exports-trie blob is present */
} mlo_pieces;

static int mlo_fail(char *why, size_t whysz, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
static int mlo_fail(char *why, size_t whysz, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(why, whysz, fmt, ap);
    va_end(ap);
    return -1;
}

static void mlo_set(mlo_pieces *ps, int k, uint32_t *off, uint64_t size) {
    ps->p[k].off = off;
    ps->p[k].size = size;
    ps->p[k].present = 1;
}

/* Every piece of the image in buf, or -1 with `why`. A command that
 * carries a file offset the pass does not know is refused, and so is a
 * second of a kind: the pass could not account for every byte it moves. */
static int mlo_find(uint8_t *buf, size_t size, mlo_pieces *ps, char *why, size_t whysz) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = (uint8_t *)(h + 1);
    memset(ps, 0, sizeof *ps);
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
        struct load_command *lc = (struct load_command *)p;
        int k0 = -1;
        switch (lc->cmd) {
        case LC_SEGMENT_64: {
            struct segment_command_64 *sg = (struct segment_command_64 *)lc;
            struct section_64 *s = (struct section_64 *)(sg + 1);
            if (strncmp(sg->segname, "__LINKEDIT", 16) == 0) {
                if (ps->le) return mlo_fail(why, whysz, "the image has more than one __LINKEDIT");
                ps->le = sg;
            }
            for (uint32_t j = 0; j < sg->nsects; j++, s++)
                if (s->reloff != 0)
                    return mlo_fail(why, whysz, "section %.16s,%.16s has relocation entries",
                                    s->segname, s->sectname);
            continue;
        }
        case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY: {
            struct dyld_info_command *di = (struct dyld_info_command *)lc;
            if (ps->p[MLO_P_REBASE].present)
                return mlo_fail(why, whysz, "the image has more than one LC_DYLD_INFO");
            mlo_set(ps, MLO_P_REBASE, &di->rebase_off, di->rebase_size);
            mlo_set(ps, MLO_P_BIND, &di->bind_off, di->bind_size);
            mlo_set(ps, MLO_P_WEAK, &di->weak_bind_off, di->weak_bind_size);
            mlo_set(ps, MLO_P_LAZY, &di->lazy_bind_off, di->lazy_bind_size);
            mlo_set(ps, MLO_P_EXPORT, &di->export_off, di->export_size);
            continue;
        }
        case LC_SYMTAB: {
            struct symtab_command *st = (struct symtab_command *)lc;
            if (ps->p[MLO_P_SYMTAB].present)
                return mlo_fail(why, whysz, "the image has more than one LC_SYMTAB");
            mlo_set(ps, MLO_P_SYMTAB, &st->symoff, (uint64_t)st->nsyms * 16);
            mlo_set(ps, MLO_P_STRTAB, &st->stroff, st->strsize);
            continue;
        }
        case LC_DYSYMTAB: {
            struct dysymtab_command *dy = (struct dysymtab_command *)lc;
            if (ps->p[MLO_P_INDIRECT].present)
                return mlo_fail(why, whysz, "the image has more than one LC_DYSYMTAB");
            mlo_set(ps, MLO_P_LOCREL, &dy->locreloff, (uint64_t)dy->nlocrel * 8);
            mlo_set(ps, MLO_P_EXTREL, &dy->extreloff, (uint64_t)dy->nextrel * 8);
            mlo_set(ps, MLO_P_INDIRECT, &dy->indirectsymoff, (uint64_t)dy->nindirectsyms * 4);
            mlo_set(ps, MLO_P_TOC, &dy->tocoff, (uint64_t)dy->ntoc * 8);
            mlo_set(ps, MLO_P_MODTAB, &dy->modtaboff, (uint64_t)dy->nmodtab * 56);
            mlo_set(ps, MLO_P_REFS, &dy->extrefsymoff, (uint64_t)dy->nextrefsyms * 4);
            ps->nind = dy->nindirectsyms;
            continue;
        }
        case LC_TWOLEVEL_HINTS: {
            struct twolevel_hints_command *th = (struct twolevel_hints_command *)lc;
            if (ps->p[MLO_P_HINTS].present)
                return mlo_fail(why, whysz, "the image has more than one LC_TWOLEVEL_HINTS");
            mlo_set(ps, MLO_P_HINTS, &th->offset, (uint64_t)th->nhints * 4);
            continue;
        }
        case LC_SEGMENT_SPLIT_INFO:       k0 = MLO_P_SPLIT; break;
        case LC_FUNCTION_STARTS:          k0 = MLO_P_FSTARTS; break;
        case LC_DATA_IN_CODE:             k0 = MLO_P_DIC; break;
        case LC_DYLIB_CODE_SIGN_DRS:      k0 = MLO_P_DRS; break;
        case LC_LINKER_OPTIMIZATION_HINT: k0 = MLO_P_LOH; break;
        case LC_CODE_SIGNATURE:           k0 = MLO_P_SIG; break;
        case LC_DYLD_CHAINED_FIXUPS:      k0 = MLO_P_CHAINED; break;
        case LC_DYLD_EXPORTS_TRIE:        k0 = MLO_P_TRIE; break;
        /* Commands that name no range of the file, or (LC_ENCRYPTION_INFO*)
         * name one in __TEXT, which the pass never moves. */
        case LC_THREAD: case LC_UNIXTHREAD: case LC_LOADFVMLIB: case LC_IDFVMLIB:
        case LC_IDENT: case LC_LOAD_DYLIB: case LC_ID_DYLIB: case LC_LOAD_DYLINKER:
        case LC_ID_DYLINKER: case LC_PREBOUND_DYLIB: case LC_ROUTINES: case LC_SUB_FRAMEWORK:
        case LC_SUB_UMBRELLA: case LC_SUB_CLIENT: case LC_SUB_LIBRARY: case LC_PREBIND_CKSUM:
        case LC_LOAD_WEAK_DYLIB: case LC_ROUTINES_64: case LC_UUID: case LC_RPATH:
        case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB: case LC_ENCRYPTION_INFO:
        case LC_LOAD_UPWARD_DYLIB: case LC_VERSION_MIN_MACOSX: case LC_VERSION_MIN_IPHONEOS:
        case LC_DYLD_ENVIRONMENT: case LC_MAIN: case LC_SOURCE_VERSION:
        case LC_ENCRYPTION_INFO_64: case LC_LINKER_OPTION: case LC_BUILD_VERSION:
        case 0x2f /* LC_VERSION_MIN_TVOS */: case 0x30 /* LC_VERSION_MIN_WATCHOS */:
            continue;
        default:
            return mlo_fail(why, whysz, "load command %u (cmd 0x%x) may name a range of the "
                            "file the pass does not know", i, lc->cmd);
        }
        struct linkedit_data_command *ld = (struct linkedit_data_command *)lc;
        if (ps->p[k0].present)
            return mlo_fail(why, whysz, "the image has more than one of %s", mlo_pname[k0]);
        mlo_set(ps, k0, &ld->dataoff, ld->datasize);
        if (k0 == MLO_P_CHAINED || k0 == MLO_P_TRIE) ps->modern = 1;
    }
    (void)size;
    return 0;
}

static uint64_t mlo_rnd64(uint64_t x, uint64_t a) { return (x + a - 1) / a * a; }

/* Is the first present table after the indirect table at the 8-rounding? */
static int mlo_had_pad(const mlo_pieces *ps) {
    if (ps->nind % 2 == 0) return 0;
    uint64_t end = (uint64_t)*ps->p[MLO_P_INDIRECT].off + ps->p[MLO_P_INDIRECT].size;
    static const int tail[4] = { MLO_P_TOC, MLO_P_MODTAB, MLO_P_REFS, MLO_P_STRTAB };
    for (int t = 0; t < 4; t++) {
        const mlo_piece *q = &ps->p[tail[t]];
        if (!q->present || q->size == 0) continue;
        return *q->off != end && *q->off == mlo_rnd64(end, 8);
    }
    return 0;
}

/* Without an LC_DYSYMTAB, codesign_allocate's writer writes only the symbol
 * table, the string table and the signature, from where the sum of their
 * sizes, rounded up to 16, says they start; and a signature it adds goes at
 * __LINKEDIT's end rounded up to 16, in a file whose size that same sum
 * decides. Both agree with the layout only if the symbol table is
 * 16-aligned. */
static int mlo_sym_rnd(const mlo_pieces *ps) {
    return !ps->p[MLO_P_INDIRECT].present && ps->p[MLO_P_SYMTAB].present &&
           ps->p[MLO_P_SYMTAB].size != 0;
}

/* Where each piece goes: new offsets for every present piece, and the new
 * __LINKEDIT length. Pieces keep their sizes. */
static uint64_t mlo_layout(const mlo_pieces *ps, uint64_t start, uint32_t *to) {
    uint64_t at = start;
    int pad = mlo_had_pad(ps), padded = 0;
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *q = &ps->p[k];
        if (!q->present) continue;
        uint32_t off = *q->off;
        if (q->size == 0) {
            /* An empty piece goes where ld64 puts one: a linkedit-data
             * piece at the running offset (or 0, where it was 0), anything
             * else at 0. */
            if (k == MLO_P_SPLIT || k == MLO_P_FSTARTS || k == MLO_P_DIC ||
                k == MLO_P_CHAINED || k == MLO_P_TRIE)
                to[k] = (off == 0) ? 0 : (uint32_t)at;
            else if (k == MLO_P_DRS || k == MLO_P_LOH)
                to[k] = (uint32_t)at;
            else
                to[k] = 0;
            continue;
        }
        if (pad && !padded && (k == MLO_P_TOC || k == MLO_P_MODTAB || k == MLO_P_REFS ||
                               k == MLO_P_STRTAB)) {
            at = mlo_rnd64(at, 8);
            padded = 1;
        }
        if (k == MLO_P_SIG || (k == MLO_P_SYMTAB && mlo_sym_rnd(ps))) at = mlo_rnd64(at, 16);
        to[k] = (uint32_t)at;
        at += q->size;
    }
    return at - start;
}

/* The pieces tile __LINKEDIT, in the pass's order, from its start to the
 * end of the file, with no gap but the two roundings. */
static int mlo_tiles(const mlo_pieces *ps, uint64_t start, uint64_t end, char *why, size_t whysz) {
    uint64_t at = start;
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *q = &ps->p[k];
        if (!q->present || q->size == 0) continue;
        uint64_t off = *q->off;
        if (off != at && !(off == mlo_rnd64(at, 8) && (k == MLO_P_TOC || k == MLO_P_MODTAB ||
                                                       k == MLO_P_REFS || k == MLO_P_STRTAB)) &&
            !(off == mlo_rnd64(at, 16) && (k == MLO_P_SIG || (k == MLO_P_SYMTAB && mlo_sym_rnd(ps)))))
            return mlo_fail(why, whysz, "%s is at 0x%llx, not 0x%llx", mlo_pname[k],
                            (unsigned long long)off, (unsigned long long)at);
        at = off + q->size;
    }
    if (at != end)
        return mlo_fail(why, whysz, "the pieces end at 0x%llx, not at the end of the file, 0x%llx",
                        (unsigned long long)at, (unsigned long long)end);
    return 0;
}

int mlo_pack(uint8_t **pbuf, size_t *psize, mlo_pack_report *rep, char *why, size_t whysz) {
    uint8_t *buf = *pbuf;
    size_t size = *psize;
    mlo_pieces ps;
    mi_image in;
    memset(rep, 0, sizeof *rep);
    if (mi_wrap(buf, size, &in) != 0) {
        mlo_fail(why, whysz, "the image is not a readable 64-bit Mach-O");
        return MLO_DECLINED;
    }
    if (mlo_find(buf, size, &ps, why, whysz) != 0) return MLO_DECLINED;
    struct segment_command_64 *le = ps.le;
    if (!le) { mlo_fail(why, whysz, "the image has no __LINKEDIT"); return MLO_DECLINED; }
    uint64_t start = le->fileoff, end = le->fileoff + le->filesize;
    if (end != size) {
        mlo_fail(why, whysz, "__LINKEDIT does not end the file");
        return MLO_DECLINED;
    }
    /* codesign_allocate rounds the sum of the sizes where the order rounds
     * the offset; they agree only from a 16-aligned start. */
    if (start % 16 != 0 && ps.p[MLO_P_SIG].present && ps.p[MLO_P_INDIRECT].present) {
        mlo_fail(why, whysz, "__LINKEDIT's file offset, 0x%llx, is not a multiple of 16",
                 (unsigned long long)start);
        return MLO_DECLINED;
    }
    /* Nothing else lies in __LINKEDIT or after it. */
    {
        struct mach_header_64 *h = (struct mach_header_64 *)buf;
        uint8_t *p = (uint8_t *)(h + 1);
        for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
            struct segment_command_64 *sg = (struct segment_command_64 *)p;
            if (sg->cmd != LC_SEGMENT_64 || sg == le) continue;
            if (sg->filesize != 0 && sg->fileoff + sg->filesize > start) {
                mlo_fail(why, whysz, "%.16s lies in or after __LINKEDIT", sg->segname);
                return MLO_DECLINED;
            }
            struct section_64 *s = (struct section_64 *)(sg + 1);
            for (uint32_t j = 0; j < sg->nsects; j++, s++)
                if (s->size != 0 && s->offset != 0 && s->offset + s->size > start) {
                    mlo_fail(why, whysz, "section %.16s,%.16s lies in __LINKEDIT", s->segname,
                             s->sectname);
                    return MLO_DECLINED;
                }
        }
    }
    /* With no rebase or bind opcodes, codesign_allocate wants the export
     * trie at __LINKEDIT's start (checkout.c:360-366) but copies the dyld
     * info from the first stream's offset, so no layout both passes and
     * survives. */
    if (ps.p[MLO_P_REBASE].present && !ps.p[MLO_P_REBASE].size && !ps.p[MLO_P_BIND].size &&
        ps.p[MLO_P_WEAK].size && ps.p[MLO_P_LAZY].size && ps.p[MLO_P_EXPORT].size) {
        mlo_fail(why, whysz, "the image has weak-bind, lazy-bind and export opcodes but no rebase "
                 "or bind opcodes, which codesign_allocate cannot lay out");
        return MLO_DECLINED;
    }
    /* The order rules put a string table last whenever it has bytes, but the
     * writer counts and writes it only with symbols: no layout survives. */
    if (ps.p[MLO_P_SYMTAB].present && !ps.p[MLO_P_SYMTAB].size && ps.p[MLO_P_STRTAB].size) {
        mlo_fail(why, whysz, "the image has a string table but no symbols, which "
                 "codesign_allocate's writer neither counts nor writes");
        return MLO_DECLINED;
    }
    uint64_t covered = 0;
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *q = &ps.p[k];
        if (!q->present || q->size == 0) continue;
        if (*q->off < start || *q->off + q->size > end) {
            mlo_fail(why, whysz, "%s lies outside __LINKEDIT", mlo_pname[k]);
            return MLO_DECLINED;
        }
        for (int j = 0; j < k; j++) {
            const mlo_piece *r = &ps.p[j];
            if (!r->present || r->size == 0) continue;
            if (*q->off < *r->off + r->size && *r->off < *q->off + q->size) {
                mlo_fail(why, whysz, "%s overlaps %s", mlo_pname[k], mlo_pname[j]);
                return MLO_DECLINED;
            }
        }
        covered += q->size;
    }

    uint32_t to[MLO_P_N];
    memset(to, 0, sizeof to);
    uint64_t len = mlo_layout(&ps, start, to);
    if (start + len > UINT32_MAX) {
        mlo_fail(why, whysz, "the packed image would pass 4GB");
        return MLO_DECLINED;
    }
    uint64_t vmsize = le->vmsize;
    if (len > vmsize) {
        uint64_t page = (((struct mach_header_64 *)buf)->cputype == CPU_TYPE_ARM64) ? 0x4000 : 0x1000;
        vmsize = mlo_rnd64(len, page);
        struct mach_header_64 *h = (struct mach_header_64 *)buf;
        uint8_t *p = (uint8_t *)(h + 1);
        for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
            struct segment_command_64 *sg = (struct segment_command_64 *)p;
            if (sg->cmd != LC_SEGMENT_64 || sg == le || sg->vmsize == 0) continue;
            if (sg->vmaddr < le->vmaddr + vmsize && le->vmaddr < sg->vmaddr + sg->vmsize) {
                mlo_fail(why, whysz, "__LINKEDIT's vmsize would overlap %.16s", sg->segname);
                return MLO_DECLINED;
            }
        }
    }

    uint8_t *nb = (uint8_t *)calloc(1, (size_t)(start + len) ? (size_t)(start + len) : 1);
    if (!nb) { mlo_fail(why, whysz, "out of memory"); return MLO_NOMEM; }
    memcpy(nb, buf, (size_t)start);
    mlo_pieces ns;
    if (mlo_find(nb, (size_t)(start + len), &ns, why, whysz) != 0) {
        free(nb);
        return MLO_FAILED;
    }
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *q = &ps.p[k];
        if (!q->present) continue;
        if (q->size) memcpy(nb + to[k], buf + *q->off, (size_t)q->size);
        *ns.p[k].off = to[k];
    }
    ns.le->filesize = len;
    ns.le->vmsize = vmsize;

    int rc = MLO_PACKED;
    if (start + len == size && memcmp(nb, buf, size) == 0) rc = MLO_UNCHANGED;

    /* Postconditions: each piece's bytes where its offset now says; nothing
     * else in the header changed; the pieces tile __LINKEDIT; and, but for
     * commands it cannot remove, codesign_allocate would accept the image
     * and re-sign it correctly. */
    for (int k = 0; rc == MLO_PACKED && k < MLO_P_N; k++) {
        const mlo_piece *q = &ps.p[k];
        if (!q->present || q->size == 0) continue;
        if (memcmp(nb + *ns.p[k].off, buf + *q->off, (size_t)q->size) != 0) {
            mlo_fail(why, whysz, "internal error: %s did not move intact", mlo_pname[k]);
            rc = MLO_FAILED;
        }
    }
    if (rc == MLO_PACKED) {
        uint8_t *mask = (uint8_t *)calloc(1, (size_t)start ? (size_t)start : 1);
        if (!mask) { free(nb); mlo_fail(why, whysz, "out of memory"); return MLO_NOMEM; }
        for (int k = 0; k < MLO_P_N; k++)
            if (ns.p[k].present) memset(mask + ((uint8_t *)ns.p[k].off - nb), 1, 4);
        memset(mask + ((uint8_t *)&ns.le->vmsize - nb), 1, 8);
        memset(mask + ((uint8_t *)&ns.le->filesize - nb), 1, 8);
        for (uint64_t i = 0; i < start; i++)
            if (!mask[i] && nb[i] != buf[i]) {
                mlo_fail(why, whysz, "internal error: header byte 0x%llx changed",
                         (unsigned long long)i);
                rc = MLO_FAILED;
                break;
            }
        free(mask);
    }
    if (rc == MLO_PACKED && mlo_tiles(&ns, start, start + len, why, whysz) != 0) rc = MLO_FAILED;
    if (rc == MLO_PACKED) {
        mi_image im;
        mlo_verdict v;
        if (mi_wrap(nb, (size_t)(start + len), &im) != 0) {
            mlo_fail(why, whysz, "internal error: the packed image does not wrap");
            rc = MLO_FAILED;
        } else {
            mlo_verdict was;
            mlo_check(&in, &was);
            mlo_check(&im, &v);
            for (int k = 0; k < v.n && rc == MLO_PACKED; k++) {
                if (v.f[k].kind != MLO_REFUSES) continue;
                if (!v.f[k].order) {
                    /* What the pass does not cure, the input already had. */
                    int had = 0;
                    for (int j = 0; j < was.n; j++)
                        if (was.f[j].kind == MLO_REFUSES && strcmp(was.f[j].text, v.f[k].text) == 0)
                            had = 1;
                    if (had) continue;
                    mlo_fail(why, whysz, "internal error: the packed image is refused, and the input "
                             "was not: %s", v.f[k].text);
                    rc = MLO_FAILED;
                    break;
                }
                /* 862's walk has no slot for a modern blob, so an image that
                 * keeps one is held to the tiling above instead. */
                if (ns.modern && strstr(v.f[k].text, "file not in an order")) continue;
                mlo_fail(why, whysz, "internal error: the packed image is refused: %s", v.f[k].text);
                rc = MLO_FAILED;
            }
            /* What no layout can make survive (a __LINKEDIT that starts off
             * 16, say) is the input's, so it is a decline, not a failure. */
            for (int k = 0; rc == MLO_PACKED && v.corrupting && k < v.n; k++) {
                if (v.f[k].kind != MLO_CORRUPTS) continue;
                mlo_fail(why, whysz, "even in codesign_allocate's order, %s", v.f[k].text);
                rc = MLO_DECLINED;
            }
        }
    }
    if (rc != MLO_PACKED) {
        free(nb);
        return rc;
    }
    rep->before = le->filesize;
    rep->after = len;
    rep->dropped = le->filesize > covered ? le->filesize - covered : 0;
    free(buf);
    *pbuf = nb;
    *psize = (size_t)(start + len);
    return MLO_PACKED;
}

/* The __LINKEDIT segment of a slice, or NULL. */
static const struct segment_command_64 *mlo_le(const uint8_t *buf, size_t size) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, size, &im) != 0) return NULL;
    const struct segment_command_64 *le = mi_find_segment(&im, "__LINKEDIT");
    return le && le->fileoff <= size && le->filesize <= size - le->fileoff ? le : NULL;
}

int mlo_changed(const uint8_t *a, size_t asize, const uint8_t *b, size_t bsize) {
    const struct segment_command_64 *la = mlo_le(a, asize), *lb = mlo_le(b, bsize);
    if (!la || !lb) return la != lb;
    if (la->fileoff != lb->fileoff || la->filesize != lb->filesize) return 1;
    mlo_pieces pa, pb;
    char why[160];
    /* mlo_find does not write through its buffer. */
    if (mlo_find((uint8_t *)a, asize, &pa, why, sizeof why) != 0 ||
        mlo_find((uint8_t *)b, bsize, &pb, why, sizeof why) != 0)
        return memcmp(a + la->fileoff, b + lb->fileoff, (size_t)la->filesize) != 0;
    for (int k = 0; k < MLO_P_N; k++) {
        const mlo_piece *x = &pa.p[k], *y = &pb.p[k];
        if (x->present != y->present) return 1;
        if (!x->present) continue;
        if (*x->off != *y->off || x->size != y->size) return 1;
        if (x->size && (*x->off + x->size > asize || *y->off + y->size > bsize)) return 1;
        if (x->size && memcmp(a + *x->off, b + *y->off, (size_t)x->size) != 0) return 1;
    }
    return 0;
}
