/* linkedit_order.c -- see linkedit_order.h. */
#include "linkedit_order.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "arch_names.h"
#include "fat.h"
#include "mach_compat.h"

/* The load commands the checks read, found in one walk. */
typedef struct {
    const mi_image *im;
    const struct segment_command_64 *le;
    int nle;
    const struct dyld_info_command *di;
    int ndi;
    const struct symtab_command *st;
    const struct dysymtab_command *dy;
    const struct twolevel_hints_command *hints;
    const struct linkedit_data_command *split, *fstarts, *dic, *drs, *loh, *sig;
    const struct dylib_command *id;
    int nid;
} mlo_cmds;

static void mlo_vadd(mlo_verdict *v, int kind, int newer, int order, const char *fmt,
                     va_list ap) {
    if (v->n == MLO_MAX) { v->dropped++; return; }
    mlo_finding *f = &v->f[v->n++];
    vsnprintf(f->text, sizeof f->text, fmt, ap);
    f->kind = kind;
    f->newer = newer;
    f->order = order;
    if (kind == MLO_REFUSES && v->refusal < 0) v->refusal = v->n - 1;
}

static void mlo_add(mlo_verdict *v, int kind, int newer, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));
static void mlo_add(mlo_verdict *v, int kind, int newer, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    mlo_vadd(v, kind, newer, 0, fmt, ap);
    va_end(ap);
}

/* A refusal about where the pieces lie. */
static void mlo_place(mlo_verdict *v, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void mlo_place(mlo_verdict *v, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    mlo_vadd(v, MLO_REFUSES, 0, 1, fmt, ap);
    va_end(ap);
}

/* The commands whose fields the checks read: each one's name, the size of
 * its struct, whether check_Mach_O wants exactly that size, and whether it
 * refuses a second of the kind before it checks the size
 * (ofile.c:3757-4528). A shorter one is refused and never read. */
static const struct {
    uint32_t cmd; const char *name; uint32_t size; int exact, second_first;
} mlo_sized[] = {
    { LC_SYMTAB, "LC_SYMTAB", sizeof(struct symtab_command), 1, 0 },
    { LC_DYSYMTAB, "LC_DYSYMTAB", sizeof(struct dysymtab_command), 1, 0 },
    { LC_TWOLEVEL_HINTS, "LC_TWOLEVEL_HINTS", sizeof(struct twolevel_hints_command), 1, 0 },
    { LC_SEGMENT_SPLIT_INFO, "LC_SEGMENT_SPLIT_INFO", sizeof(struct linkedit_data_command), 1, 1 },
    { LC_CODE_SIGNATURE, "LC_CODE_SIGNATURE", sizeof(struct linkedit_data_command), 1, 1 },
    { LC_FUNCTION_STARTS, "LC_FUNCTION_STARTS", sizeof(struct linkedit_data_command), 1, 1 },
    { LC_DATA_IN_CODE, "LC_DATA_IN_CODE", sizeof(struct linkedit_data_command), 1, 1 },
    { LC_DYLIB_CODE_SIGN_DRS, "LC_DYLIB_CODE_SIGN_DRS", sizeof(struct linkedit_data_command), 1, 1 },
    { LC_LINKER_OPTIMIZATION_HINT, "LC_LINKER_OPTIMIZATION_HINT",
      sizeof(struct linkedit_data_command), 1, 1 },
    { LC_DYLD_INFO, "LC_DYLD_INFO", sizeof(struct dyld_info_command), 1, 0 },
    { LC_DYLD_INFO_ONLY, "LC_DYLD_INFO_ONLY", sizeof(struct dyld_info_command), 1, 0 },
    { LC_ID_DYLIB, "LC_ID_DYLIB", sizeof(struct dylib_command), 0, 0 },
};
#define MLO_NSIZED (sizeof mlo_sized / sizeof mlo_sized[0])

static int mlo_sized_at(uint32_t cmd) {
    for (size_t k = 0; k < MLO_NSIZED; k++)
        if (mlo_sized[k].cmd == cmd) return (int)k;
    return -1;
}

static int mlo_collect(const struct load_command *lc, void *ctx_) {
    mlo_cmds *c = (mlo_cmds *)ctx_;
    int z = mlo_sized_at(lc->cmd);
    if (z >= 0 && lc->cmdsize < mlo_sized[z].size) return 0;
    switch (lc->cmd) {
    case LC_SEGMENT_64: {
        const struct segment_command_64 *s = (const struct segment_command_64 *)lc;
        if (strncmp(s->segname, "__LINKEDIT", 16) == 0) {
            if (!c->le) c->le = s;
            c->nle++;
        }
        break;
    }
    case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY:
        if (!c->di) c->di = (const struct dyld_info_command *)lc;
        c->ndi++;
        break;
    case LC_SYMTAB:
        if (!c->st) c->st = (const struct symtab_command *)lc;
        break;
    case LC_DYSYMTAB:
        if (!c->dy) c->dy = (const struct dysymtab_command *)lc;
        break;
    case LC_TWOLEVEL_HINTS:
        if (!c->hints) c->hints = (const struct twolevel_hints_command *)lc;
        break;
    case LC_SEGMENT_SPLIT_INFO:
        if (!c->split) c->split = (const struct linkedit_data_command *)lc;
        break;
    case LC_FUNCTION_STARTS:
        if (!c->fstarts) c->fstarts = (const struct linkedit_data_command *)lc;
        break;
    case LC_DATA_IN_CODE:
        if (!c->dic) c->dic = (const struct linkedit_data_command *)lc;
        break;
    case LC_DYLIB_CODE_SIGN_DRS:
        if (!c->drs) c->drs = (const struct linkedit_data_command *)lc;
        break;
    case LC_LINKER_OPTIMIZATION_HINT:
        if (!c->loh) c->loh = (const struct linkedit_data_command *)lc;
        break;
    case LC_CODE_SIGNATURE:
        if (!c->sig) c->sig = (const struct linkedit_data_command *)lc;
        break;
    case LC_ID_DYLIB:
        if (!c->id) c->id = (const struct dylib_command *)lc;
        c->nid++;
        break;
    }
    return 0;
}

/* check_object (checkout.c:75-216), less the duplicates the ofile loop
 * refuses first. */
static void mlo_check_object(const mlo_cmds *c, mlo_verdict *v) {
    const struct mach_header_64 *h = c->im->hdr;
    if (c->ndi > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one LC_DYLD_INFO load command)");
    if (c->nle > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one __LINKEDITsegment)");
    if (c->nid > 1)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (more than one LC_ID_DYLIB load command)");
    if ((h->filetype == MH_DYLIB || (h->filetype == MH_DYLIB_STUB && h->ncmds > 0)) && !c->id)
        mlo_add(v, MLO_REFUSES, 0, "malformed file (no LC_ID_DYLIB load command in %s file)",
                h->filetype == MH_DYLIB ? "MH_DYLIB" : "MH_DYLIB_STUB");
    if (c->hints) {
        if (!c->dy && c->hints->nhints != 0)
            mlo_add(v, MLO_REFUSES, 0, "malformed file (LC_TWOLEVEL_HINTS load command present "
                    "without an LC_DYSYMTAB load command)");
        if (c->dy && c->hints->nhints != 0 && c->hints->nhints != c->dy->nundefsym)
            mlo_add(v, MLO_REFUSES, 0, "malformed file (LC_TWOLEVEL_HINTS load command's nhints "
                    "does not match LC_DYSYMTAB load command's nundefsym)");
    }
}

static uint32_t mlo_rnd(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }


/* One piece of dyld_order's walk: `off` must be the running offset. On a
 * mismatch the walk goes on from where the piece really is, so each later
 * piece is judged on its own. */
static uint32_t mlo_at(mlo_verdict *v, uint32_t offset, uint32_t off, uint32_t size,
                       const char *what) {
    if (off != offset) {
        mlo_place(v, "file not in an order that can be processed (%s)", what);
        return off + size;
    }
    return offset + size;
}

#define MLO_ORDER(what) mlo_place(v, "file not in an order that can be processed (%s)", what)
#define MLO_INDEX(what) mlo_add(v, MLO_REFUSES, 0, "file not in an order that can be processed (%s)", what)

/* dyld_order (checkout.c:313-560), rule for rule. */
static uint32_t mlo_dyld_order(const mlo_cmds *c, mlo_verdict *v) {
    const struct dysymtab_command *dy = c->dy;
    const struct symtab_command *st = c->st;
    uint32_t size = (uint32_t)c->im->size, offset, rounded, isym, pad = 0;
    if (!c->le) {
        mlo_place(v, "malformed file (no __LINKEDIT segment)");
        return 0;
    }
    if (c->le->filesize != 0 && c->le->fileoff + c->le->filesize != size)
        mlo_place(v, "the __LINKEDIT segment does not cover the end of the file (can't be processed)");
    offset = (uint32_t)c->le->fileoff;
    if (c->di) {
        const struct dyld_info_command *di = c->di;
        if (di->rebase_off != 0) {
            if (di->rebase_off != offset) MLO_ORDER("dyld_info out of place");
        } else if (di->bind_off != 0) {
            if (di->bind_off != offset) MLO_ORDER("dyld_info out of place");
        } else if (di->export_off != 0) {
            if (di->export_off != offset && di->weak_bind_size != 0 && di->lazy_bind_size != 0)
                MLO_ORDER("dyld_info out of place");
        }
        if (di->export_size != 0)         offset = di->export_off + di->export_size;
        else if (di->lazy_bind_size != 0) offset = di->lazy_bind_off + di->lazy_bind_size;
        else if (di->weak_bind_size != 0) offset = di->weak_bind_off + di->weak_bind_size;
        else if (di->bind_size != 0)      offset = di->bind_off + di->bind_size;
        else if (di->rebase_size != 0)    offset = di->rebase_off + di->rebase_size;
    }
    if (dy->nlocrel != 0)
        offset = mlo_at(v, offset, dy->locreloff, dy->nlocrel * 8, "local relocation entries out of place");
    /* A zero dataoff skips the check for these three, but not the advance. */
    static const char *const skip_what[3] = { "split info data out of place",
        "function starts data out of place", "data in code info out of place" };
    const struct linkedit_data_command *skip[3] = { c->split, c->fstarts, c->dic };
    for (int k = 0; k < 3; k++) {
        if (!skip[k]) continue;
        if (skip[k]->dataoff != 0 && skip[k]->dataoff != offset) {
            MLO_ORDER(skip_what[k]);
            offset = skip[k]->dataoff + skip[k]->datasize;
        } else {
            offset += skip[k]->datasize;
        }
    }
    if (c->drs) offset = mlo_at(v, offset, c->drs->dataoff, c->drs->datasize,
                                "code signing DRs info out of place");
    if (c->loh) offset = mlo_at(v, offset, c->loh->dataoff, c->loh->datasize,
                                "linker optimization hint info out of place");
    if (st && st->nsyms != 0)
        offset = mlo_at(v, offset, st->symoff, st->nsyms * 16, "symbol table out of place");
    isym = 0;
    if (dy->nlocalsym != 0) {
        if (dy->ilocalsym != isym) MLO_INDEX("local symbols out of place");
        isym += dy->nlocalsym;
    }
    if (dy->nextdefsym != 0) {
        if (dy->iextdefsym != isym) MLO_INDEX("externally defined symbols out of place");
        isym += dy->nextdefsym;
    }
    if (dy->nundefsym != 0) {
        if (dy->iundefsym != isym) MLO_INDEX("undefined symbols out of place");
        isym += dy->nundefsym;
    }
    if (c->hints && c->hints->nhints != 0)
        offset = mlo_at(v, offset, c->hints->offset, c->hints->nhints * 4, "hints table out of place");
    if (dy->nextrel != 0)
        offset = mlo_at(v, offset, dy->extreloff, dy->nextrel * 8,
                        "external relocation entries out of place");
    if (dy->nindirectsyms != 0)
        offset = mlo_at(v, offset, dy->indirectsymoff, dy->nindirectsyms * 4,
                        "indirect symbol table out of place");
    rounded = (dy->nindirectsyms % 2) ? mlo_rnd(offset, 8) : offset;
    /* Only the first of these that is present may take the rounding. */
    struct { uint32_t n, off, size; const char *what; } tail[4] = {
        { dy->ntoc, dy->tocoff, dy->ntoc * 8, "table of contents out of place" },
        { dy->nmodtab, dy->modtaboff, dy->nmodtab * 56, "module table out of place" },
        { dy->nextrefsyms, dy->extrefsymoff, dy->nextrefsyms * 4, "reference table out of place" },
        { st ? st->strsize : 0, st ? st->stroff : 0, st ? st->strsize : 0, "string table out of place" },
    };
    for (int k = 0; k < 4; k++) {
        if (tail[k].n == 0) continue;
        if (tail[k].off == offset) {
            offset += tail[k].size;
            rounded = offset;
        } else if (tail[k].off == rounded) {
            pad = rounded - offset;
            rounded += tail[k].size;
            offset = rounded;
        } else {
            MLO_ORDER(tail[k].what);
            offset = rounded = tail[k].off + tail[k].size;
        }
    }
    if (c->sig) {
        rounded = mlo_rnd(rounded, 16);
        if (c->sig->dataoff != rounded) {
            MLO_ORDER("code signature data out of place");
            rounded = c->sig->dataoff;
        }
        rounded += c->sig->datasize;
        offset = rounded;
    }
    if (offset != size && rounded != size)
        MLO_ORDER("link edit information does not fill the __LINKEDIT segment");
    return pad;
}

/* The load commands cctools-862's check_Mach_O has a case for
 * (ofile.c:3530-5965). LC_FVMFILE and LC_PREPAGE have none. */
static const uint32_t mlo_known[] = {
    LC_SEGMENT, LC_SYMTAB, LC_SYMSEG, LC_THREAD, LC_UNIXTHREAD, LC_LOADFVMLIB,
    LC_IDFVMLIB, LC_IDENT, LC_DYSYMTAB, LC_LOAD_DYLIB, LC_ID_DYLIB, LC_LOAD_DYLINKER,
    LC_ID_DYLINKER, LC_PREBOUND_DYLIB, LC_ROUTINES, LC_SUB_FRAMEWORK, LC_SUB_UMBRELLA,
    LC_SUB_CLIENT, LC_SUB_LIBRARY, LC_TWOLEVEL_HINTS, LC_PREBIND_CKSUM, LC_LOAD_WEAK_DYLIB,
    LC_SEGMENT_64, LC_ROUTINES_64, LC_UUID, LC_RPATH, LC_CODE_SIGNATURE,
    LC_SEGMENT_SPLIT_INFO, LC_REEXPORT_DYLIB, LC_LAZY_LOAD_DYLIB, LC_ENCRYPTION_INFO,
    LC_DYLD_INFO, LC_DYLD_INFO_ONLY, LC_LOAD_UPWARD_DYLIB, LC_VERSION_MIN_MACOSX,
    LC_VERSION_MIN_IPHONEOS, LC_FUNCTION_STARTS, LC_DYLD_ENVIRONMENT, LC_MAIN,
    LC_DATA_IN_CODE, LC_SOURCE_VERSION, LC_DYLIB_CODE_SIGN_DRS, LC_ENCRYPTION_INFO_64,
    LC_LINKER_OPTION, LC_LINKER_OPTIMIZATION_HINT,
};

static int mlo_known_cmd(uint32_t cmd) {
    for (size_t k = 0; k < sizeof mlo_known / sizeof mlo_known[0]; k++)
        if (mlo_known[k] == cmd) return 1;
    return 0;
}

/* The commands the loop refuses a second of, and the name it says. The two
 * version-min commands count as one kind. */
static const struct { uint32_t cmd; const char *name; } mlo_once[] = {
    { LC_SYMTAB, "LC_SYMTAB" }, { LC_DYSYMTAB, "LC_DYSYMTAB" },
    { LC_ROUTINES, "LC_ROUTINES" }, { LC_ROUTINES_64, "LC_ROUTINES_64" },
    { LC_TWOLEVEL_HINTS, "LC_TWOLEVEL_HINTS" }, { LC_SEGMENT_SPLIT_INFO, "LC_SEGMENT_SPLIT_INFO" },
    { LC_CODE_SIGNATURE, "LC_CODE_SIGNATURE" }, { LC_FUNCTION_STARTS, "LC_FUNCTION_STARTS" },
    { LC_DATA_IN_CODE, "LC_DATA_IN_CODE" }, { LC_DYLIB_CODE_SIGN_DRS, "LC_DYLIB_CODE_SIGN_DRS" },
    { LC_LINKER_OPTIMIZATION_HINT, "LC_LINKER_OPTIMIZATION_HINT" },
    { LC_VERSION_MIN_MACOSX, "LC_VERSION_MIN_IPHONEOS or LC_VERSION_MIN_MACOSX" },
    { LC_VERSION_MIN_IPHONEOS, "LC_VERSION_MIN_IPHONEOS or LC_VERSION_MIN_MACOSX" },
    { LC_PREBIND_CKSUM, "LC_PREBIND_CKSUM" }, { LC_UUID, "LC_UUID" },
};
#define MLO_NONCE (sizeof mlo_once / sizeof mlo_once[0])

/* The ofile loop, in index order: every unknown command and every second
 * of a kind, each where the loop meets it. */
static void mlo_ofile_loop(const mi_image *im, mlo_verdict *v) {
    const struct mach_header_64 *h = im->hdr;
    const uint8_t *p = (const uint8_t *)(h + 1);
    int seen[MLO_NONCE];
    memset(seen, 0, sizeof seen);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        p += lc->cmdsize;
        if (!mlo_known_cmd(lc->cmd)) {
            mlo_add(v, MLO_REFUSES, 1, "malformed object (unknown load command %u)", i);
            continue;
        }
        const char *second = NULL;
        for (size_t k = 0; k < MLO_NONCE; k++) {
            if (mlo_once[k].cmd != lc->cmd) continue;
            /* the version-min pair share one count */
            size_t slot = (lc->cmd == LC_VERSION_MIN_IPHONEOS) ? k - 1 : k;
            if (seen[slot]++) second = mlo_once[k].name;
        }
        int z = mlo_sized_at(lc->cmd);
        if (second && z >= 0 && mlo_sized[z].second_first) {
            mlo_add(v, MLO_REFUSES, 0, "malformed object (more than one %s command)", second);
        } else if (z >= 0 && lc->cmdsize < mlo_sized[z].size) {
            mlo_add(v, MLO_REFUSES, 0, "malformed object (%s cmdsize too small) in command %u",
                    mlo_sized[z].name, i);
        } else if (second) {
            mlo_add(v, MLO_REFUSES, 0, "malformed object (more than one %s command)", second);
        } else if (z >= 0 && mlo_sized[z].exact && lc->cmdsize != mlo_sized[z].size) {
            if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY)
                mlo_add(v, MLO_REFUSES, 0, "malformed object (LC_DYLD_INFOcommand %u has "
                        "incorrect cmdsize)", i);
            else
                mlo_add(v, MLO_REFUSES, 0, "malformed object (%s command %u has incorrect cmdsize)",
                        mlo_sized[z].name, i);
        } else if (lc->cmd == LC_ID_DYLIB &&
                   ((const struct dylib_command *)lc)->dylib.name.offset >= lc->cmdsize) {
            mlo_add(v, MLO_REFUSES, 0, "truncated or malformed object (name.offset field of "
                    "LC_ID_DYLIB command %u extends past the end of the file)", i);
        }
    }
}

/* A range of the file one command names, as the loop checks and overlaps
 * them. */
typedef struct { uint64_t off, size; } mlo_range;

static int mlo_ranges(const mlo_cmds *c, mlo_range *r, int max) {
    int n = 0;
#define MLO_R(o, s) do { if (((s) != 0 || (o) != 0) && n < max) { r[n].off = (o); r[n].size = (s); n++; } } while (0)
    const struct dyld_info_command *di = c->di;
    if (di) {
        MLO_R(di->rebase_off, di->rebase_size);
        MLO_R(di->bind_off, di->bind_size);
        MLO_R(di->weak_bind_off, di->weak_bind_size);
        MLO_R(di->lazy_bind_off, di->lazy_bind_size);
        MLO_R(di->export_off, di->export_size);
    }
    const struct linkedit_data_command *led[6] = { c->split, c->fstarts, c->dic, c->drs, c->loh, c->sig };
    for (int k = 0; k < 6; k++) if (led[k]) MLO_R(led[k]->dataoff, led[k]->datasize);
    if (c->st) {
        MLO_R(c->st->symoff, (uint64_t)c->st->nsyms * 16);
        MLO_R(c->st->stroff, c->st->strsize);
    }
    if (c->dy) {
        const struct dysymtab_command *dy = c->dy;
        MLO_R(dy->tocoff, (uint64_t)dy->ntoc * 8);
        MLO_R(dy->modtaboff, (uint64_t)dy->nmodtab * 56);
        MLO_R(dy->extrefsymoff, (uint64_t)dy->nextrefsyms * 4);
        MLO_R(dy->indirectsymoff, (uint64_t)dy->nindirectsyms * 4);
        MLO_R(dy->extreloff, (uint64_t)dy->nextrel * 8);
        MLO_R(dy->locreloff, (uint64_t)dy->nlocrel * 8);
    }
    if (c->hints) MLO_R(c->hints->offset, (uint64_t)c->hints->nhints * 4);
#undef MLO_R
    return n;
}

/* The loop's checks on the ranges it reads: each within the file, and none
 * overlapping another or the headers. */
static void mlo_ofile_ranges(const mlo_cmds *c, mlo_verdict *v) {
    mlo_range r[32];
    int n = mlo_ranges(c, r, 31);
    r[n].off = 0;
    r[n].size = sizeof(struct mach_header_64) + c->im->hdr->sizeofcmds;
    n++;
    for (int i = 0; i < n; i++) {
        if (r[i].off > c->im->size || r[i].size > c->im->size - r[i].off) {
            mlo_add(v, MLO_REFUSES, 0, "truncated or malformed object (…extends past the end of the file)");
            return;
        }
    }
    for (int i = 0; i < n; i++)
        for (int j = i + 1; j < n; j++)
            if (r[i].size && r[j].size &&
                r[i].off < r[j].off + r[j].size && r[j].off < r[i].off + r[i].size) {
                mlo_add(v, MLO_REFUSES, 0, "malformed object (…overlaps…)");
                return;
            }
}

/* The loop's last check (ofile.c:6046). */
static void mlo_ofile_hints(const mlo_cmds *c, mlo_verdict *v) {
    if (c->hints && c->dy && c->hints->nhints != c->dy->nundefsym)
        mlo_add(v, MLO_REFUSES, 0, "malformed object (nhints in LC_TWOLEVEL_HINTS load command "
                "not the same as nundefsym in LC_DYSYMTAB load command)");
}

/* symbol_string_at_end (checkout.c:573-699), rule for rule. Returns the
 * indirect table's pad, which the writer counts. Its last check, that
 * __LINKEDIT covers the tables, reads only a 32-bit image's segment. */
static uint32_t mlo_string_at_end(const mlo_cmds *c, mlo_verdict *v, uint32_t *object_size) {
    const struct symtab_command *st = c->st;
    uint32_t pad = 0;
    if (!st || st->nsyms == 0) return 0;
    uint32_t end = *object_size;
    if (c->sig) {
        if (c->sig->dataoff + c->sig->datasize != end)
            mlo_place(v, "code signature not at the end of the file (can't be processed)");
        end = c->sig->dataoff;
        if (st->strsize != 0 && c->sig->dataoff == mlo_rnd(st->stroff + st->strsize, 16))
            end = st->stroff + st->strsize;
    }
    if (st->strsize != 0) {
        uint32_t strend = st->stroff + st->strsize;
        uint32_t rounded = mlo_rnd(strend, 8);
        if (strend != end && rounded != end)
            mlo_place(v, "string table not at the end of the file (can't be processed)");
        if (rounded != strend && !c->sig) *object_size = strend;
        end = st->stroff;
    }
    const struct dysymtab_command *dy = c->dy;
    if (dy && dy->nindirectsyms != 0 && dy->indirectsymoff > st->symoff) {
        uint32_t indirectend = dy->indirectsymoff + dy->nindirectsyms * 4;
        uint32_t rounded = (dy->nindirectsyms % 2) ? mlo_rnd(indirectend, 8) : indirectend;
        if (indirectend != end && rounded != end)
            mlo_place(v, "indirect symbol table does not directly preceed the string "
                    "table (can't be processed)");
        pad = end - indirectend;
        end = dy->indirectsymoff;
        if (st->symoff + st->nsyms * 16 != end)
            mlo_place(v, "symbol table does not directly preceed the indirect symbol "
                    "table (can't be processed)");
    } else if (st->symoff + st->nsyms * 16 != end) {
        mlo_place(v, "symbol table and string table not at the end of the file "
                "(can't be processed)");
    }
    return pad;
}

/* add_code_sig_load_command's room check (codesign_allocate.c:655-736),
 * for an image with no LC_CODE_SIGNATURE. */
static int mlo_room_seg(const struct load_command *lc, void *ctx_) {
    uint32_t *low = (uint32_t *)ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(sg + 1);
    if (sg->nsects != 0) {
        for (uint32_t j = 0; j < sg->nsects; j++, s++) {
            uint32_t type = s->flags & SECTION_TYPE;
            if (s->size != 0 && type != S_ZEROFILL && type != S_THREAD_LOCAL_ZEROFILL &&
                s->offset < *low)
                *low = s->offset;
        }
    } else if (sg->filesize != 0 && sg->fileoff < *low) {
        *low = (uint32_t)sg->fileoff;
    }
    return 0;
}

static void mlo_room(const mlo_cmds *c, mlo_verdict *v) {
    uint32_t low = UINT32_MAX;
    if (c->sig) return;
    mi_each_lc(c->im, mlo_room_seg, &low);
    if (c->im->hdr->sizeofcmds + sizeof(struct linkedit_data_command) +
        sizeof(struct mach_header_64) > low)
        mlo_add(v, MLO_REFUSES, 1, "because larger updated load commands do not fit");
    if (c->le && c->le->fileoff % 16 != 0)
        mlo_add(v, MLO_NOTE, 0, "__LINKEDIT's file offset is not a multiple of 16, and "
                "codesign_allocate would round its filesize, not its end");
}

/* The writer (setup_code_signature, codesign_allocate.c:302-503;
 * copy_new_symbol_info, writeout.c:735-840). It copies the file verbatim up
 * to P = object_size - input_sym_info_size, writes the pieces it knows one
 * after another from P, each from where its load command says it is, and
 * then the signature at the next multiple of 16. It updates no offset, so
 * the re-sign is correct only if every piece's bytes are still where its load
 * command says. This is that comparison, done on the input's own bytes. */
typedef struct { uint32_t dest, src, size; } mlo_write;

/* Would the output hold input[off, off+size)'s bytes at the same place? */
static int mlo_survives(const uint8_t *in, uint32_t P, const mlo_write *w, int nw,
                        uint32_t off, uint32_t size) {
    uint32_t x = off, end = off + size;
    while (x < end) {
        if (x < P) { x = end < P ? end : P; continue; }
        int k;
        for (k = 0; k < nw; k++)
            if (w[k].size && x >= w[k].dest && x < w[k].dest + w[k].size) break;
        if (k == nw) return 0;   /* nothing the writer puts there */
        uint32_t stop = w[k].dest + w[k].size < end ? w[k].dest + w[k].size : end;
        if (memcmp(in + w[k].src + (x - w[k].dest), in + x, stop - x) != 0) return 0;
        x = stop;
    }
    return 1;
}

static void mlo_simulate(const mlo_cmds *c, mlo_verdict *v, uint32_t object_size, uint32_t pad) {
    const struct symtab_command *st = c->st;
    const struct dysymtab_command *dy = c->dy;
    const struct dyld_info_command *di = c->di;
    const uint8_t *in = c->im->buf;
    /* The symbol and string tables count only when there are symbols. */
    uint32_t nsyms = st ? st->nsyms : 0;
    uint32_t strsize = nsyms ? st->strsize : 0;
    uint64_t iss = (uint64_t)nsyms * 16 + strsize;
    mlo_write w[24];
    int nw = 0;
    /* What the writer writes, in its order: (source offset, size); a source
     * of UINT32_MAX is padding. */
    uint32_t src[24], len[24];
    int n = 0;
#define MLO_W(o, s) do { src[n] = (o); len[n] = (s); n++; } while (0)
    if (dy) {
        if (di) {
            uint32_t start = 0, end = 0;
            if (di->rebase_off)         start = di->rebase_off;
            else if (di->bind_off)      start = di->bind_off;
            else if (di->weak_bind_off) start = di->weak_bind_off;
            else if (di->lazy_bind_off) start = di->lazy_bind_off;
            else if (di->export_off)    start = di->export_off;
            if (di->export_size)         end = di->export_off + di->export_size;
            else if (di->lazy_bind_size) end = di->lazy_bind_off + di->lazy_bind_size;
            else if (di->weak_bind_size) end = di->weak_bind_off + di->weak_bind_size;
            else if (di->bind_size)      end = di->bind_off + di->bind_size;
            else if (di->rebase_size)    end = di->rebase_off + di->rebase_size;
            iss += (uint64_t)di->rebase_size + di->bind_size + di->weak_bind_size +
                   di->lazy_bind_size + di->export_size;
            MLO_W(start, end - start);
        }
        iss += (uint64_t)dy->nlocrel * 8 + (uint64_t)dy->nextrel * 8 + (uint64_t)dy->ntoc * 8 +
               (uint64_t)dy->nextrefsyms * 4;
        MLO_W(dy->locreloff, dy->nlocrel * 8);
        const struct linkedit_data_command *led[5] = { c->split, c->fstarts, c->dic, c->drs, c->loh };
        for (int k = 0; k < 5; k++) {
            if (!led[k]) continue;
            iss += led[k]->datasize;
            MLO_W(led[k]->dataoff, led[k]->datasize);
        }
        iss += (uint64_t)dy->nmodtab * 56 + (uint64_t)dy->nindirectsyms * 4 + pad;
        MLO_W(st ? st->symoff : 0, nsyms * 16);
        if (c->hints) {
            iss += (uint64_t)c->hints->nhints * 4;
            MLO_W(c->hints->offset, c->hints->nhints * 4);
        }
        MLO_W(dy->extreloff, dy->nextrel * 8);
        MLO_W(dy->indirectsymoff, dy->nindirectsyms * 4);
        MLO_W(UINT32_MAX, pad);
        MLO_W(dy->tocoff, dy->ntoc * 8);
        MLO_W(dy->modtaboff, dy->nmodtab * 56);
        MLO_W(dy->extrefsymoff, dy->nextrefsyms * 4);
        MLO_W(st ? st->stroff : 0, strsize);
    } else {
        MLO_W(st ? st->symoff : 0, nsyms * 16);
        MLO_W(st ? st->stroff : 0, strsize);
    }
#undef MLO_W
    if (c->sig) iss = mlo_rnd((uint32_t)iss, 16) + (uint64_t)c->sig->datasize;
    if (iss > object_size) {
        mlo_add(v, MLO_CORRUPTS, 0, "the writer would begin %llu bytes before the file",
                (unsigned long long)(iss - object_size));
        return;
    }
    uint32_t P = object_size - (uint32_t)iss, at = P;
    for (int k = 0; k < n; k++) {
        if (src[k] != UINT32_MAX && len[k]) {
            if ((uint64_t)src[k] + len[k] > c->im->size) {
                mlo_add(v, MLO_CORRUPTS, 0, "the writer would copy past the end of the file");
                return;
            }
            w[nw].dest = at; w[nw].src = src[k]; w[nw].size = len[k]; nw++;
        }
        at += len[k];
    }
    /* Every piece but the signature, which the re-sign replaces. */
    struct { const char *name; uint32_t off, size; } p[24];
    int np = 0;
#define MLO_P(nm, o, s) do { if ((s) != 0) { p[np].name = (nm); p[np].off = (o); p[np].size = (s); np++; } } while (0)
    if (di) {
        MLO_P("the rebase opcodes", di->rebase_off, di->rebase_size);
        MLO_P("the bind opcodes", di->bind_off, di->bind_size);
        MLO_P("the weak-bind opcodes", di->weak_bind_off, di->weak_bind_size);
        MLO_P("the lazy-bind opcodes", di->lazy_bind_off, di->lazy_bind_size);
        MLO_P("the export trie", di->export_off, di->export_size);
    }
    if (c->split)   MLO_P("the split info", c->split->dataoff, c->split->datasize);
    if (c->fstarts) MLO_P("the function starts", c->fstarts->dataoff, c->fstarts->datasize);
    if (c->dic)     MLO_P("the data in code", c->dic->dataoff, c->dic->datasize);
    if (c->drs)     MLO_P("the code-signing DRs", c->drs->dataoff, c->drs->datasize);
    if (c->loh)     MLO_P("the linker hints", c->loh->dataoff, c->loh->datasize);
    if (st) {
        MLO_P("the symbol table", st->symoff, st->nsyms * 16);
        MLO_P("the string table", st->stroff, st->strsize);
    }
    if (dy) {
        MLO_P("the local relocations", dy->locreloff, dy->nlocrel * 8);
        MLO_P("the external relocations", dy->extreloff, dy->nextrel * 8);
        MLO_P("the indirect symbol table", dy->indirectsymoff, dy->nindirectsyms * 4);
        MLO_P("the table of contents", dy->tocoff, dy->ntoc * 8);
        MLO_P("the module table", dy->modtaboff, dy->nmodtab * 56);
        MLO_P("the reference table", dy->extrefsymoff, dy->nextrefsyms * 4);
    }
    if (c->hints) MLO_P("the two-level hints", c->hints->offset, c->hints->nhints * 4);
#undef MLO_P
    uint64_t maxend = 0;
    for (int k = 0; k < np; k++) {
        if (!mlo_survives(in, P, w, nw, p[k].off, p[k].size))
            mlo_add(v, MLO_CORRUPTS, 0, "%s (0x%x, %u bytes) would not survive the re-sign",
                    p[k].name, p[k].off, p[k].size);
        if ((uint64_t)p[k].off + p[k].size > maxend) maxend = (uint64_t)p[k].off + p[k].size;
    }
    /* An existing signature keeps its offset, which the order rules put
     * after every piece. A new one goes at __LINKEDIT's end, rounded up to
     * 16, in a file whose size the tool computes from the sum
     * (codesign_allocate.c:588-633); the signature's own size cancels out. */
    if (!c->sig && c->le) {
        uint32_t le_end = (uint32_t)(c->le->fileoff + c->le->filesize), off = mlo_rnd(le_end, 16);
        uint64_t out = (uint64_t)object_size - iss + (iss ? mlo_rnd((uint32_t)iss, 16) : off - le_end);
        if (off > out)
            mlo_add(v, MLO_CORRUPTS, 0, "the new code signature, at 0x%x, would run past the end "
                    "of the file", off);
        else if (off < maxend)
            mlo_add(v, MLO_CORRUPTS, 0, "the new code signature, at 0x%x, would overlap a piece "
                    "that ends at 0x%llx", off, (unsigned long long)maxend);
    }
}

void mlo_check(const mi_image *im, mlo_verdict *v) {
    mlo_cmds c;
    memset(v, 0, sizeof *v);
    v->refusal = -1;
    memset(&c, 0, sizeof c);
    c.im = im;
    mi_each_lc(im, mlo_collect, &c);
    mlo_ofile_loop(im, v);
    mlo_ofile_ranges(&c, v);
    mlo_ofile_hints(&c, v);
    mlo_check_object(&c, v);
    uint32_t object_size = (uint32_t)im->size, pad = 0;
    if (c.dy && (im->hdr->filetype == MH_DYLIB || (im->hdr->flags & MH_DYLDLINK)))
        pad = mlo_dyld_order(&c, v);
    else
        pad = mlo_string_at_end(&c, v, &object_size);
    mlo_room(&c, v);
    int blocking = 0;
    for (int k = 0; k < v->n; k++)
        if (v->f[k].kind == MLO_REFUSES && !v->f[k].newer) blocking = 1;
    if (blocking) return;
    int before = v->n;
    mlo_simulate(&c, v, object_size, pad);
    v->corrupting = v->n > before || v->dropped;
}

/* The verdict on one slice, into the whole file's. `label` is "" for a
 * thin file, else "slice NAME: ". */
static int mlo_slice_verdict(const uint8_t *buf, size_t size, const char *label, char *refusal,
                             size_t rsz, char *corrupt, size_t csz, int *worst) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, size, &im) != 0) return -1;
    mlo_verdict v;
    mlo_check(&im, &v);
    if (v.refusal >= 0 && *worst < 1) {
        snprintf(refusal, rsz, "%s%s", label, v.f[v.refusal].text);
        *worst = 1;
    }
    if (v.corrupting && !corrupt[0]) {
        size_t at = (size_t)snprintf(corrupt, csz, "%s", label);
        for (int k = 0; k < v.n && at < csz; k++)
            if (v.f[k].kind == MLO_CORRUPTS)
                at += (size_t)snprintf(corrupt + at, csz - at, "%s%s", at > strlen(label) ? "; " : "",
                                       v.f[k].text);
    }
    return 0;
}

int mlo_file_verdict(const uint8_t *buf, size_t size, char *refusal, size_t rsz,
                     char *corrupt, size_t csz) {
    int worst = 0;
    snprintf(refusal, rsz, "ok");
    corrupt[0] = 0;
    uint32_t narch;
    int swapped;
    if (size >= 4 && (buf[0] == 0xca || buf[0] == 0xbe) && mfat_parse(buf, size, &narch, &swapped) == 0) {
        char unchecked[64] = "";
        for (uint32_t i = 0; i < narch; i++) {
            mfat_arch a;
            char name[32], label[48];
            mfat_get(buf, swapped, i, &a);
            ma_describe(a.cputype, a.cpusubtype, name);
            snprintf(label, sizeof label, "slice %s: ", name);
            if (mlo_slice_verdict(buf + a.offset, a.size, label, refusal, rsz, corrupt, csz,
                                  &worst) != 0 && !unchecked[0])
                snprintf(unchecked, sizeof unchecked, "not checked: slice %s is not a 64-bit Mach-O",
                         name);
        }
        if (worst == 0 && unchecked[0]) snprintf(refusal, rsz, "%s", unchecked);
    } else if (mlo_slice_verdict(buf, size, "", refusal, rsz, corrupt, csz, &worst) != 0) {
        return -1;
    }
    if (corrupt[0]) return 2;
    return worst;
}
