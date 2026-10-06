/* symrename.c -- see symrename.h. */
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>

#include "symrename.h"
#include "image.h"
#include "mach_compat.h"

typedef struct {
    const struct symtab_command *st;
    int found;
    uint64_t claim;     /* the end of the last file byte a load command records, the string table aside */
} msr_find;

static void msr_claim(msr_find *f, uint64_t off, uint64_t len) {
    if (len == 0) return;
    uint64_t end = off > UINT64_MAX - len ? UINT64_MAX : off + len;
    if (end > f->claim) f->claim = end;
}

static void msr_claim_lc(msr_find *f, const struct load_command *lc, int own_symtab) {
    switch (lc->cmd) {
    case LC_SEGMENT_64: {
        const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
        const struct section_64 *sec = (const struct section_64 *)(sg + 1);
        msr_claim(f, sg->fileoff, sg->filesize);
        for (uint32_t i = 0; i < sg->nsects; i++) {
            uint32_t type = sec[i].flags & SECTION_TYPE;
            if (type != S_ZEROFILL && type != S_GB_ZEROFILL && type != S_THREAD_LOCAL_ZEROFILL)
                msr_claim(f, sec[i].offset, sec[i].size);
            msr_claim(f, sec[i].reloff, (uint64_t)sec[i].nreloc * sizeof(struct relocation_info));
        }
        break;
    }
    case LC_SYMTAB: {
        const struct symtab_command *st = (const struct symtab_command *)lc;
        msr_claim(f, st->symoff, (uint64_t)st->nsyms * sizeof(struct nlist_64));
        if (!own_symtab) msr_claim(f, st->stroff, st->strsize);
        break;
    }
    case LC_DYSYMTAB: {
        const struct dysymtab_command *d = (const struct dysymtab_command *)lc;
        msr_claim(f, d->tocoff, (uint64_t)d->ntoc * sizeof(struct dylib_table_of_contents));
        msr_claim(f, d->modtaboff, (uint64_t)d->nmodtab * sizeof(struct dylib_module_64));
        msr_claim(f, d->extrefsymoff, (uint64_t)d->nextrefsyms * sizeof(struct dylib_reference));
        msr_claim(f, d->indirectsymoff, (uint64_t)d->nindirectsyms * sizeof(uint32_t));
        msr_claim(f, d->extreloff, (uint64_t)d->nextrel * sizeof(struct relocation_info));
        msr_claim(f, d->locreloff, (uint64_t)d->nlocrel * sizeof(struct relocation_info));
        break;
    }
    case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY: {
        const struct dyld_info_command *d = (const struct dyld_info_command *)lc;
        msr_claim(f, d->rebase_off, d->rebase_size);
        msr_claim(f, d->bind_off, d->bind_size);
        msr_claim(f, d->weak_bind_off, d->weak_bind_size);
        msr_claim(f, d->lazy_bind_off, d->lazy_bind_size);
        msr_claim(f, d->export_off, d->export_size);
        break;
    }
    case LC_TWOLEVEL_HINTS: {
        const struct twolevel_hints_command *h = (const struct twolevel_hints_command *)lc;
        msr_claim(f, h->offset, (uint64_t)h->nhints * sizeof(struct twolevel_hint));
        break;
    }
    case LC_ENCRYPTION_INFO: case LC_ENCRYPTION_INFO_64: {
        const struct encryption_info_command *e = (const struct encryption_info_command *)lc;
        msr_claim(f, e->cryptoff, e->cryptsize);
        break;
    }
    case LC_ATOM_INFO:
        if (lc->cmdsize < sizeof(struct linkedit_data_command)) break;
        /* fall through */
    case LC_CODE_SIGNATURE: case LC_SEGMENT_SPLIT_INFO: case LC_FUNCTION_STARTS:
    case LC_DATA_IN_CODE: case LC_DYLIB_CODE_SIGN_DRS: case LC_LINKER_OPTIMIZATION_HINT:
    case LC_DYLD_EXPORTS_TRIE: case LC_DYLD_CHAINED_FIXUPS: {
        const struct linkedit_data_command *d = (const struct linkedit_data_command *)lc;
        msr_claim(f, d->dataoff, d->datasize);
        break;
    }
    case LC_NOTE: {   /* cmd, cmdsize, data_owner[16], uint64_t offset, uint64_t size */
        uint64_t off, len;
        if (lc->cmdsize < 40) break;
        memcpy(&off, (const uint8_t *)lc + 24, sizeof off);
        memcpy(&len, (const uint8_t *)lc + 32, sizeof len);
        msr_claim(f, off, len);
        break;
    }
    }
}

static int msr_find_lc(const struct load_command *lc, void *ctx) {
    msr_find *f = ctx;
    int own = 0;
    if (lc->cmd == LC_SYMTAB && !f->found) {
        f->st = (const struct symtab_command *)lc;
        f->found = 1;
        own = 1;
    }
    msr_claim_lc(f, lc, own);
    return 0;
}

typedef struct {
    size_t symoff, stroff, strsize;
    uint32_t nsyms;
} msr_tab;

/* 1 if a symbol table was found and fits; 0 if there is none or no symbols;
 * -1 if it is malformed. Every n_strx is checked by msr_name. */
static int msr_locate(const uint8_t *buf, size_t size, msr_tab *t, msr_find *f) {
    mi_image im;
    if (mi_wrap((uint8_t *)buf, size, &im) != 0) return -1;
    memset(f, 0, sizeof *f);
    mi_each_lc(&im, msr_find_lc, f);
    if (!f->found || f->st->nsyms == 0) return 0;
    t->symoff = f->st->symoff;
    t->stroff = f->st->stroff;
    t->strsize = f->st->strsize;
    t->nsyms = f->st->nsyms;
    if (t->symoff > size || (size - t->symoff) / sizeof(struct nlist_64) < t->nsyms) return -1;
    if (t->stroff > size || size - t->stroff < t->strsize) return -1;
    if (t->strsize == 0) return -1;
    return 1;
}

static struct nlist_64 msr_nlist(const uint8_t *buf, const msr_tab *t, uint32_t i) {
    struct nlist_64 n;
    memcpy(&n, buf + t->symoff + (size_t)i * sizeof n, sizeof n);
    return n;
}

/* The NUL-terminated name at n_strx, or NULL if it runs off the table. */
static const char *msr_name(const uint8_t *buf, const msr_tab *t, uint32_t strx) {
    if (strx >= t->strsize) return NULL;
    const uint8_t *s = buf + t->stroff + strx;
    if (!memchr(s, 0, t->strsize - strx)) return NULL;
    return (const char *)s;
}

int msr_has(const uint8_t *buf, size_t size, const char *name) {
    msr_tab t;
    msr_find f;
    if (msr_locate(buf, size, &t, &f) != 1) return 0;
    for (uint32_t i = 0; i < t.nsyms; i++) {
        struct nlist_64 n = msr_nlist(buf, &t, i);
        const char *s = msr_name(buf, &t, n.n_un.n_strx);
        if (s && strcmp(s, name) == 0) return 1;
    }
    return 0;
}

int msr_each_defined_external(const uint8_t *buf, size_t size,
                              int (*fn)(const char *name, void *ctx), void *ctx) {
    msr_tab t;
    msr_find f;
    int rc = msr_locate(buf, size, &t, &f);
    if (rc < 0) return -1;
    if (rc == 0) return 0;
    for (uint32_t i = 0; i < t.nsyms; i++) {
        struct nlist_64 n = msr_nlist(buf, &t, i);
        const char *s = msr_name(buf, &t, n.n_un.n_strx);
        if (!s) return -1;
        if (n.n_type & N_STAB) continue;
        if (!(n.n_type & N_EXT) || (n.n_type & N_TYPE) == N_UNDF) continue;
        int stop = fn(s, ctx);
        if (stop) return stop;
    }
    return 0;
}

const char *msr_reason(int rc) {
    switch (rc) {
    case MSR_UNMATCHED:        return "no symbol is named OLD";
    case MSR_SAME:             return "OLD and NEW are the same name";
    case MSR_EXISTS:           return "a symbol is already named NEW";
    case MSR_STRTAB_NOT_LAST:  return "the string table is not the last thing in the file";
    case MSR_MALFORMED:        return "the symbol table is malformed";
    case MSR_NOMEM:            return "out of memory";
    default:                   return "";
    }
}

int msr_rename(uint8_t **pbuf, size_t *psize, const char *old, const char *new_, msr_report *r) {
    uint8_t *buf = *pbuf;
    size_t size = *psize;
    if (r) r->entries = 0;

    msr_tab t;
    msr_find loc;
    int rc = msr_locate(buf, size, &t, &loc);
    if (rc < 0) return MSR_MALFORMED;

    unsigned matched = 0;
    int exists = 0;
    for (uint32_t i = 0; rc == 1 && i < t.nsyms; i++) {
        struct nlist_64 n = msr_nlist(buf, &t, i);
        const char *s = msr_name(buf, &t, n.n_un.n_strx);
        if (!s) return MSR_MALFORMED;
        if (strcmp(s, old) == 0) matched++;
        if (strcmp(s, new_) == 0) exists = 1;
    }
    if (matched == 0) return MSR_UNMATCHED;
    if (strcmp(old, new_) == 0) return MSR_SAME;
    if (exists) return MSR_EXISTS;

    size_t end = t.stroff + t.strsize;
    size_t tail = size - end;
    if (loc.claim > end) return MSR_STRTAB_NOT_LAST;
    if (tail != 0) {
        if (tail >= 8 || size % 8 != 0) return MSR_STRTAB_NOT_LAST;
        for (size_t i = end; i < size; i++)
            if (buf[i]) return MSR_STRTAB_NOT_LAST;
    }

    size_t add = strlen(new_) + 1;
    if (add > (size_t)UINT32_MAX - t.strsize) return MSR_MALFORMED;
    size_t new_strsize = t.strsize + add;
    size_t new_size = t.stroff + new_strsize;
    if (tail != 0) new_size = (new_size + 7) & ~(size_t)7;
    size_t st_at = (size_t)((const uint8_t *)loc.st - buf);

    if (new_size > size) {
        uint8_t *nb = realloc(buf, new_size);
        if (!nb) return MSR_NOMEM;
        buf = nb;
        *pbuf = nb;
    }
    memcpy(buf + end, new_, add);
    if (new_size > end + add) memset(buf + end + add, 0, new_size - end - add);

    for (uint32_t i = 0; i < t.nsyms; i++) {
        struct nlist_64 n = msr_nlist(buf, &t, i);
        const char *s = msr_name(buf, &t, n.n_un.n_strx);
        if (s && strcmp(s, old) == 0) {
            n.n_un.n_strx = (uint32_t)t.strsize;
            memcpy(buf + t.symoff + (size_t)i * sizeof n, &n, sizeof n);
        }
    }
    uint32_t strsize32 = (uint32_t)new_strsize;
    memcpy(buf + st_at + offsetof(struct symtab_command, strsize), &strsize32, sizeof strsize32);
    *psize = new_size;
    if (r) r->entries = matched;
    return MSR_OK;
}
