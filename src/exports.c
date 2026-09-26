/* exports.c -- the export reporter. See exports.h. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/fat.h>

#include "exports.h"
#include "image.h"
#include "fat.h"
#include "arch_names.h"
#include "trie.h"
#include "uleb.h"
#include "mach_compat.h"

#define WHAT "drydock-macho-rewrite exports"

/* spec: src/exports.h -- rows are held until every slice has been read. */
typedef struct { size_t name; const char *kind; int weak; } mexp_item;
typedef struct {
    char arch[32];
    const char *source;
    mexp_item *items; size_t n, cap;
    char *pool; size_t used, room;
    int oom;
} mexp_slice;

static size_t mexp_intern(mexp_slice *s, const char *name, size_t len) {
    if (s->oom) return 0;
    if (s->used + len + 1 > s->room) {
        size_t room = s->room ? s->room : 4096;
        while (room < s->used + len + 1) room *= 2;
        char *p = realloc(s->pool, room);
        if (!p) { s->oom = 1; return 0; }
        s->pool = p; s->room = room;
    }
    size_t at = s->used;
    memcpy(s->pool + at, name, len);
    s->pool[at + len] = '\0';
    s->used += len + 1;
    return at;
}

static void mexp_add(mexp_slice *s, const char *name, size_t len, const char *kind, int weak) {
    if (s->oom) return;
    if (s->n == s->cap) {
        size_t cap = s->cap ? s->cap * 2 : 256;
        mexp_item *v = realloc(s->items, cap * sizeof *v);
        if (!v) { s->oom = 1; return; }
        s->items = v; s->cap = cap;
    }
    size_t at = mexp_intern(s, name, len);
    if (s->oom) return;
    s->items[s->n].name = at;
    s->items[s->n].kind = kind;
    s->items[s->n].weak = weak;
    s->n++;
}

static int mexp_bad(const mexp_slice *s, const char *name, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (name[i] == '\t' || name[i] == '\n' || name[i] == '\0') {
            fprintf(stderr, WHAT ": %s: an exported symbol contains byte 0x%02x, which "
                            "would corrupt the TSV row; refusing\n", s->arch,
                    (unsigned char)name[i]);
            return 1;
        }
    }
    return 0;
}

typedef struct { uint32_t off; uint32_t child, nchildren; const uint8_t *next; size_t name_len; } mexp_frame;

static int mexp_trie(mexp_slice *s, const uint8_t *t, uint32_t size) {
    mexp_frame stack[MT_TRIE_MAX_DEPTH];
    uint8_t *seen = calloc(size ? size : 1, 1);
    char *name = NULL;
    size_t name_room = 0;
    int depth = 0, rc = -1;
    if (!seen) { s->oom = 1; return -1; }
    const uint8_t *end = t + size;

#define MEXP_FAIL(why) do { fprintf(stderr, WHAT ": %s: malformed export trie: %s; refusing\n", \
                                    s->arch, why); goto out; } while (0)

    uint32_t off = 0;
    size_t name_len = 0;
    for (;;) {
        if (off >= size) MEXP_FAIL("a node offset lies outside it");
        if (seen[off]) MEXP_FAIL("a node is reachable more than one way");
        seen[off] = 1;
        if (depth >= MT_TRIE_MAX_DEPTH) MEXP_FAIL("deeper than this reader walks");
        const uint8_t *p = t + off;
        uint64_t tsize;
        int n = mu_decode(p, end, &tsize);
        if (n == 0) MEXP_FAIL("a terminal size is truncated or past 64 bits");
        p += n;
        if (tsize > (uint64_t)(end - p)) MEXP_FAIL("a terminal runs past its end");
        const uint8_t *children = p + tsize;
        if (tsize) {
            uint64_t flags;
            if (mu_decode(p, children, &flags) == 0)
                MEXP_FAIL("a symbol's flags are truncated or past 64 bits");
            const char *kind;
            if (flags & EXPORT_SYMBOL_FLAGS_REEXPORT) kind = "reexport";
            else if (flags & EXPORT_SYMBOL_FLAGS_STUB_AND_RESOLVER) kind = "stub-resolver";
            else switch (flags & EXPORT_SYMBOL_FLAGS_KIND_MASK) {
                case EXPORT_SYMBOL_FLAGS_KIND_REGULAR:      kind = "regular"; break;
                case EXPORT_SYMBOL_FLAGS_KIND_THREAD_LOCAL: kind = "thread-local"; break;
                case 2:                                     kind = "absolute"; break;
                default: MEXP_FAIL("a symbol has an unknown kind");
            }
            if (name_len == 0) MEXP_FAIL("a symbol has an empty name");
            if (mexp_bad(s, name, name_len)) goto out;
            mexp_add(s, name, name_len, kind, (flags & EXPORT_SYMBOL_FLAGS_WEAK_DEFINITION) != 0);
            if (s->oom) goto out;
        }
        if (children >= end) MEXP_FAIL("a node has no child count");
        stack[depth].off = off;
        stack[depth].child = 0;
        stack[depth].nchildren = *children;
        stack[depth].next = children + 1;
        stack[depth].name_len = name_len;
        depth++;

        for (;;) {
            if (depth == 0) { rc = 0; goto out; }
            mexp_frame *f = &stack[depth - 1];
            if (f->child == f->nchildren) { depth--; continue; }
            const uint8_t *q = f->next;
            const uint8_t *lbl = q;
            while (q < end && *q) q++;
            if (q >= end) MEXP_FAIL("an edge label is unterminated");
            size_t lbl_len = (size_t)(q - lbl);
            q++;
            uint64_t child;
            int m = mu_decode(q, end, &child);
            if (m == 0) MEXP_FAIL("a child offset is truncated or past 64 bits");
            q += m;
            f->next = q;
            f->child++;
            if (f->name_len + lbl_len + 1 > name_room) {
                size_t room = name_room ? name_room : 256;
                while (room < f->name_len + lbl_len + 1) room *= 2;
                char *nn = realloc(name, room);
                if (!nn) { s->oom = 1; goto out; }
                name = nn; name_room = room;
            }
            memcpy(name + f->name_len, lbl, lbl_len);
            name_len = f->name_len + lbl_len;
            if (child >= size) MEXP_FAIL("a child offset lies outside it");
            off = (uint32_t)child;
            break;
        }
    }
#undef MEXP_FAIL
out:
    free(seen);
    free(name);
    return rc;
}

static int mexp_symtab(mexp_slice *s, const mi_image *im, const struct symtab_command *st) {
    if ((uint64_t)st->symoff + (uint64_t)st->nsyms * sizeof(struct nlist_64) > im->size ||
        (uint64_t)st->stroff + st->strsize > im->size) {
        fprintf(stderr, WHAT ": %s: LC_SYMTAB does not fit within the slice; refusing\n", s->arch);
        return -1;
    }
    const struct nlist_64 *syms = (const struct nlist_64 *)(im->buf + st->symoff);
    const char *strs = (const char *)im->buf + st->stroff;
    for (uint32_t i = 0; i < st->nsyms; i++) {
        uint8_t type = syms[i].n_type & N_TYPE;
        if ((syms[i].n_type & N_STAB) || !(syms[i].n_type & N_EXT)) continue;
        if (type == N_UNDF || type == N_PBUD) continue;
        uint32_t x = syms[i].n_un.n_strx;
        if (x >= st->strsize) {
            fprintf(stderr, WHAT ": %s: symbol %u's name lies outside the string table; "
                            "refusing\n", s->arch, i);
            return -1;
        }
        const char *nm = strs + x;
        size_t len = strnlen(nm, st->strsize - x);
        if (len == st->strsize - x) {
            fprintf(stderr, WHAT ": %s: symbol %u's name is unterminated; refusing\n", s->arch, i);
            return -1;
        }
        if (mexp_bad(s, nm, len)) return -1;
        const char *kind = type == N_INDR ? "reexport" : type == N_ABS ? "absolute" : "regular";
        mexp_add(s, nm, len, kind, (syms[i].n_desc & N_WEAK_DEF) != 0);
        if (s->oom) return -1;
    }
    return 0;
}

typedef struct { uint32_t off, size; const struct symtab_command *st; } mexp_where;

static int mexp_lc(const struct load_command *lc, void *ctx) {
    mexp_where *w = ctx;
    if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        const struct dyld_info_command *di = (const struct dyld_info_command *)lc;
        if (di->export_size) { w->off = di->export_off; w->size = di->export_size; }
    } else if (lc->cmd == LC_DYLD_EXPORTS_TRIE) {
        const struct linkedit_data_command *ld = (const struct linkedit_data_command *)lc;
        if (ld->datasize) { w->off = ld->dataoff; w->size = ld->datasize; }
    } else if (lc->cmd == LC_SYMTAB) {
        w->st = (const struct symtab_command *)lc;
    }
    return 0;
}

static int mexp_read_slice(const mi_image *im, mexp_slice *s) {
    mexp_where w;
    memset(&w, 0, sizeof w);
    mi_each_lc(im, mexp_lc, &w);
    int rc = 0;
    if (w.size) {
        s->source = "trie";
        if ((uint64_t)w.off + w.size > im->size) {
            fprintf(stderr, WHAT ": %s: the export trie does not fit within the slice; "
                            "refusing\n", s->arch);
            return -1;
        }
        rc = mexp_trie(s, im->buf + w.off, w.size);
    } else if (w.st) {
        s->source = "symtab";
        rc = mexp_symtab(s, im, w.st);
    }
    if (s->oom) { fprintf(stderr, WHAT ": out of memory\n"); return -1; }
    return rc;
}

static void mexp_emit(const mexp_slice *s, mexp_row_fn fn, void *ctx) {
    for (size_t i = 0; i < s->n; i++) {
        mexp_row r;
        r.arch = s->arch;
        r.symbol = s->pool + s->items[i].name;
        r.kind = s->items[i].kind;
        r.weak = s->items[i].weak;
        r.source = s->source;
        fn(&r, ctx);
    }
}

static void mexp_free(mexp_slice *s) { free(s->items); free(s->pool); }

int mexp_report(const uint8_t *buf, size_t size, mexp_row_fn fn, void *ctx) {
    if (size < sizeof(uint32_t)) return MEXP_REFUSED;
    uint32_t magic;
    memcpy(&magic, buf, sizeof magic);
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        uint32_t narch;
        int swapped, rc = MEXP_OK;
        if (mfat_parse(buf, size, &narch, &swapped) != 0) return MEXP_REFUSED;
        mexp_slice *sl = calloc(narch ? narch : 1, sizeof *sl);
        int *readable = calloc(narch ? narch : 1, sizeof *readable);
        if (!sl || !readable) {
            fprintf(stderr, WHAT ": out of memory\n");
            free(sl); free(readable);
            return MEXP_REFUSED;
        }
        for (uint32_t i = 0; i < narch && rc == MEXP_OK; i++) {
            mfat_arch a;
            mi_image im;
            mfat_get(buf, swapped, i, &a);
            if (mi_wrap((uint8_t *)buf + a.offset, a.size, &im) != 0) continue;
            readable[i] = 1;
            ma_describe(a.cputype, a.cpusubtype, sl[i].arch);
            if (mexp_read_slice(&im, &sl[i]) != 0) rc = MEXP_REFUSED;
        }
        for (uint32_t i = 0; i < narch && rc == MEXP_OK; i++)
            if (readable[i]) mexp_emit(&sl[i], fn, ctx);
        for (uint32_t i = 0; i < narch; i++) mexp_free(&sl[i]);
        free(sl); free(readable);
        return rc;
    }
    mi_image im;
    if (mi_wrap((uint8_t *)buf, size, &im) != 0) return MEXP_REFUSED;
    mexp_slice s;
    memset(&s, 0, sizeof s);
    snprintf(s.arch, sizeof s.arch, "-");
    int rc = mexp_read_slice(&im, &s) == 0 ? MEXP_OK : MEXP_REFUSED;
    if (rc == MEXP_OK) mexp_emit(&s, fn, ctx);
    mexp_free(&s);
    return rc;
}
