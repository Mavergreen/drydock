/* vnodeop.c -- see vnodeop.h. */
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/machine.h>

#include "vnodeop.h"
#include "image.h"

#define MVN_RELOC_UNSIGNED 0   /* X86_64_RELOC_UNSIGNED */
#define MVN_MAX_SECTS 255

typedef struct { uint64_t addr, size; uint32_t offset; int contents; } mvn_sect;

typedef struct {
    size_t at;          /* file offset of the relocation_info */
    int ext_table;      /* 1: in the external relocation table; 0: the local one */
    uint64_t addr;      /* base + r_address */
    uint32_t sym;
    unsigned pcrel, length, ext, type;
} mvn_rel;

typedef struct {
    size_t size;
    int have_base;
    uint64_t base;
    mvn_sect sect[MVN_MAX_SECTS];
    unsigned nsect;
    int too_many_sects;
    int indexes_symtab;   /* a section relocation or LC_TWOLEVEL_HINTS */
    const struct symtab_command *st;
    const struct dysymtab_command *dy;
} mvn_lcs;

typedef struct { uint32_t symoff, nsyms, stroff, strsize; } mvn_tab;

typedef struct { uint64_t a, b, a_off, b_off; const mvn_rel *target; } mvn_plan;

int mvn_is_x86_64_kext(const uint8_t *buf, size_t size) {
    struct mach_header_64 h;
    if (size < sizeof h) return 0;
    memcpy(&h, buf, sizeof h);
    return h.magic == MH_MAGIC_64 && h.cputype == CPU_TYPE_X86_64 && h.filetype == MH_KEXT_BUNDLE;
}

const char *mvn_reason(int rc) {
    switch (rc) {
    case MVN_UNMATCHED:          return "no symbol is named OLD";
    case MVN_NOT_X86_64_KEXT:    return "the input is not an x86_64 kext (MH_KEXT_BUNDLE)";
    case MVN_NOT_ONE_SYMBOL:     return "OLD or NEW does not name exactly one symbol";
    case MVN_NOT_UNDEFINED:      return "OLD or NEW is not an undefined symbol";
    case MVN_UNREFERENCED:       return "no relocation names OLD";
    case MVN_BAD_RELOC:          return "a relocation naming OLD or NEW is not the only relocation at its entry's descriptor slot, "
                                        "or is not an external UNSIGNED quad";
    case MVN_NOT_IN_TABLE:       return "a relocation naming OLD is not at a 16-byte entry in a section with file contents";
    case MVN_NO_TERMINATOR:      return "a vnode-op table holding OLD reaches its section's end without a {NULL, NULL} entry";
    case MVN_NEW_COUNT:          return "a vnode-op table holding OLD does not hold exactly one NEW entry";
    case MVN_IMPL_MISMATCH:      return "the implementation slots of an OLD entry and its NEW entry carry different relocations";
    case MVN_STRAY_REFERENCE:    return "a local relocation names OLD";
    case MVN_DYSYMTAB_SHAPE:     return "there is no LC_DYSYMTAB, ntoc, nmodtab, nextrefsyms or nindirectsyms is nonzero, "
                                        "or a section relocation or LC_TWOLEVEL_HINTS indexes the symbol table";
    case MVN_UNDEF_NOT_LAST:     return "the undefined symbols are not last in the symbol table";
    case MVN_EXTERN_LOCAL_RELOC: return "a local relocation is external";
    case MVN_VERIFY:             return "the rewrite did not verify: a relocation names OLD, NEW's count is off, "
                                        "or another relocation's symbol changed";
    case MVN_MALFORMED:          return "the symbol or relocation tables are malformed";
    case MVN_NOMEM:              return "out of memory";
    default:                     return "";
    }
}

static int mvn_lc(const struct load_command *lc, void *ctx) {
    mvn_lcs *l = ctx;
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
        const struct section_64 *sec = (const struct section_64 *)(sg + 1);
        if (!l->have_base) { l->base = sg->vmaddr; l->have_base = 1; }
        for (uint32_t i = 0; i < sg->nsects; i++) {
            if (sec[i].nreloc) l->indexes_symtab = 1;
            if (l->nsect == MVN_MAX_SECTS) { l->too_many_sects = 1; continue; }
            uint32_t type = sec[i].flags & SECTION_TYPE;
            mvn_sect *s = &l->sect[l->nsect++];
            s->addr = sec[i].addr; s->size = sec[i].size; s->offset = sec[i].offset;
            s->contents = s->offset != 0 && type != S_ZEROFILL && type != S_GB_ZEROFILL && type != S_THREAD_LOCAL_ZEROFILL;
        }
    } else if (lc->cmd == LC_SYMTAB && !l->st) {
        l->st = (const struct symtab_command *)lc;
    } else if (lc->cmd == LC_TWOLEVEL_HINTS) {
        l->indexes_symtab = 1;
    } else if (lc->cmd == LC_DYSYMTAB && !l->dy) {
        l->dy = (const struct dysymtab_command *)lc;
    }
    return 0;
}

static int mvn_fits(size_t size, uint64_t off, uint64_t n, uint64_t each) {
    return off <= size && (each == 0 || n <= (size - off) / each);
}

/* The NUL-terminated name of symbol i, or NULL if it runs off the string table. */
static const char *mvn_name(const uint8_t *buf, const mvn_tab *t, uint32_t i) {
    uint32_t strx;
    memcpy(&strx, buf + t->symoff + (size_t)i * sizeof(struct nlist_64), sizeof strx);
    if (strx >= t->strsize) return NULL;
    const uint8_t *s = buf + t->stroff + strx;
    if (!memchr(s, 0, t->strsize - strx)) return NULL;
    return (const char *)s;
}

/* -1 if a name is malformed; otherwise how many symbols are named `name`, the first at *index. */
static int mvn_count(const uint8_t *buf, const mvn_tab *t, const char *name, uint32_t *index) {
    int n = 0;
    for (uint32_t i = 0; i < t->nsyms; i++) {
        const char *s = mvn_name(buf, t, i);
        if (!s) return -1;
        if (strcmp(s, name) == 0 && n++ == 0) *index = i;
    }
    return n;
}

static int mvn_undefined(const uint8_t *buf, const mvn_tab *t, uint32_t i) {
    uint8_t type = buf[t->symoff + (size_t)i * sizeof(struct nlist_64) + offsetof(struct nlist_64, n_type)];
    return !(type & N_STAB) && (type & N_TYPE) == N_UNDF;
}

static void mvn_decode(const uint8_t *buf, size_t at, int ext_table, uint64_t base, mvn_rel *r) {
    int32_t address;
    uint32_t w;
    memcpy(&address, buf + at, 4);
    memcpy(&w, buf + at + 4, 4);
    r->at = at; r->ext_table = ext_table;
    r->addr = base + (uint64_t)(int64_t)address;
    r->sym = w & 0xffffff; r->pcrel = (w >> 24) & 1; r->length = (w >> 25) & 3;
    r->ext = (w >> 27) & 1; r->type = w >> 28;
}

static void mvn_store(uint8_t *buf, const mvn_rel *r) {
    uint32_t w = r->sym | r->pcrel << 24 | r->length << 25 | r->ext << 27 | r->type << 28;
    memcpy(buf + r->at + 4, &w, 4);
}

static int mvn_quad_to(const mvn_rel *r, uint32_t sym) {
    return r->ext_table && r->ext && !r->pcrel && r->length == 3 && r->type == MVN_RELOC_UNSIGNED && r->sym == sym;
}

typedef struct { const mvn_rel *rel; size_t n; } mvn_rels;

static size_t mvn_at(const mvn_rels *rs, uint64_t addr, const mvn_rel **out, size_t max) {
    size_t n = 0;
    for (size_t i = 0; i < rs->n; i++)
        if (rs->rel[i].addr == addr) { if (n < max) out[n] = &rs->rel[i]; n++; }
    return n;
}

/* The section holding [addr, addr + len), or NULL. */
static const mvn_sect *mvn_section(const mvn_lcs *l, uint64_t addr, uint64_t len) {
    for (unsigned i = 0; i < l->nsect; i++) {
        const mvn_sect *s = &l->sect[i];
        if (s->addr <= addr && addr - s->addr <= s->size && len <= s->size - (addr - s->addr)) return s;
    }
    return NULL;
}

static int mvn_terminator(const uint8_t *buf, const mvn_rels *rs, const mvn_sect *s, uint64_t e) {
    static const uint8_t zero[16];
    const mvn_rel *dummy[1];
    return memcmp(buf + s->offset + (e - s->addr), zero, 16) == 0
        && mvn_at(rs, e, dummy, 1) == 0 && mvn_at(rs, e + 8, dummy, 1) == 0;
}

static int mvn_kind_cmp(const void *x, const void *y) {
    const mvn_rel *a = *(const mvn_rel *const *)x, *b = *(const mvn_rel *const *)y;
    unsigned ka[6] = { (unsigned)!a->ext_table, a->sym, a->pcrel, a->length, a->ext, a->type };
    unsigned kb[6] = { (unsigned)!b->ext_table, b->sym, b->pcrel, b->length, b->ext, b->type };
    for (int i = 0; i < 6; i++)
        if (ka[i] != kb[i]) return ka[i] < kb[i] ? -1 : 1;
    return 0;
}

#define MVN_MAX_IMPL 8

static int mvn_impl_slots(const mvn_rels *rs, uint64_t a, uint64_t b,
                          const mvn_rel **src, const mvn_rel **dst, size_t *n) {
    size_t ns = mvn_at(rs, b + 8, src, MVN_MAX_IMPL), nd = mvn_at(rs, a + 8, dst, MVN_MAX_IMPL);
    if (ns != nd || ns > MVN_MAX_IMPL) return MVN_IMPL_MISMATCH;
    qsort(src, ns, sizeof *src, mvn_kind_cmp);
    qsort(dst, nd, sizeof *dst, mvn_kind_cmp);
    for (size_t i = 0; i < ns; i++)
        if (src[i]->ext_table != dst[i]->ext_table || src[i]->pcrel != dst[i]->pcrel || src[i]->length != dst[i]->length
            || src[i]->ext != dst[i]->ext || src[i]->type != dst[i]->type)
            return MVN_IMPL_MISMATCH;
    *n = ns;
    return MVN_OK;
}

/* Finds the NEW entry B in the table holding OLD's entry at A. */
static int mvn_plan_one(const uint8_t *buf, const mvn_lcs *l, const mvn_rels *rs, const mvn_rel *t,
                        uint32_t new_i, mvn_plan *p) {
    const mvn_rel *at[2];
    if (!mvn_quad_to(t, t->sym)) return MVN_BAD_RELOC;
    uint64_t a = t->addr;
    const mvn_sect *s = mvn_section(l, a, 16);
    if (!s || !s->contents) return MVN_NOT_IN_TABLE;
    if (!mvn_fits(l->size, s->offset, s->size, 1) || s->size > UINT64_MAX - s->addr) return MVN_MALFORMED;
    if (mvn_at(rs, a, at, 2) != 1) return MVN_BAD_RELOC;

    uint64_t end = s->addr + s->size, hi = 0, lo = a;
    for (uint64_t e = a + 16; e < end && end - e >= 16; e += 16)
        if (mvn_terminator(buf, rs, s, e)) { hi = e; break; }
    if (!hi) return MVN_NO_TERMINATOR;
    while (lo - s->addr >= 16 && !mvn_terminator(buf, rs, s, lo - 16)) lo -= 16;

    unsigned found = 0;
    uint64_t b = 0;
    for (uint64_t e = lo; e < hi; e += 16) {
        int names_new = 0;
        for (size_t i = 0; i < rs->n; i++)
            if (rs->rel[i].addr == e && rs->rel[i].ext && rs->rel[i].sym == new_i) names_new = 1;
        if (names_new) { found++; b = e; }
    }
    if (found != 1) return MVN_NEW_COUNT;
    if (mvn_at(rs, b, at, 2) != 1 || !mvn_quad_to(at[0], new_i)) return MVN_BAD_RELOC;

    const mvn_rel *src[MVN_MAX_IMPL], *dst[MVN_MAX_IMPL];
    size_t n;
    int rc = mvn_impl_slots(rs, a, b, src, dst, &n);
    if (rc != MVN_OK) return rc;
    p->a = a; p->b = b; p->target = t;
    p->a_off = s->offset + (a - s->addr); p->b_off = s->offset + (b - s->addr);
    return MVN_OK;
}

/* Each external relocation's name in `after` is its name in `before`, but OLD's are NEW's. */
static int mvn_verify(const uint8_t *before, const mvn_tab *tb, const uint8_t *after, const mvn_tab *ta,
                      const struct dysymtab_command *dy, const char *old, const char *new_, unsigned entries) {
    unsigned new_before = 0, new_after = 0;
    uint32_t dummy;
    if (mvn_count(after, ta, old, &dummy) != 0) return MVN_VERIFY;
    for (uint32_t i = 0; i < dy->nextrel; i++) {
        mvn_rel rb, ra;
        mvn_decode(before, dy->extreloff + (size_t)i * 8, 1, 0, &rb);
        mvn_decode(after, dy->extreloff + (size_t)i * 8, 1, 0, &ra);
        if (rb.ext != ra.ext) return MVN_VERIFY;
        if (!rb.ext) continue;
        if (rb.sym >= tb->nsyms || ra.sym >= ta->nsyms) return MVN_VERIFY;
        const char *nb = mvn_name(before, tb, rb.sym), *na = mvn_name(after, ta, ra.sym);
        if (!nb || !na) return MVN_VERIFY;
        if (strcmp(nb, new_) == 0) new_before++;
        if (strcmp(na, new_) == 0) new_after++;
        if (strcmp(na, strcmp(nb, old) == 0 ? new_ : nb) != 0) return MVN_VERIFY;
    }
    return new_after == new_before + entries ? MVN_OK : MVN_VERIFY;
}

int mvn_replace(uint8_t *buf, size_t size, const char *old, const char *new_, mvn_report *r) {
    if (r) memset(r, 0, sizeof *r);
    if (!mvn_is_x86_64_kext(buf, size)) return MVN_NOT_X86_64_KEXT;
    mi_image im;
    if (mi_wrap(buf, size, &im) != 0) return MVN_MALFORMED;
    mvn_lcs l;
    memset(&l, 0, sizeof l);
    l.size = size;
    mi_each_lc(&im, mvn_lc, &l);
    if (!l.st || l.st->nsyms == 0) return MVN_UNMATCHED;
    if (!l.have_base || l.too_many_sects) return MVN_MALFORMED;
    mvn_tab t = { l.st->symoff, l.st->nsyms, l.st->stroff, l.st->strsize };
    if (!mvn_fits(size, t.symoff, t.nsyms, sizeof(struct nlist_64)) || !mvn_fits(size, t.stroff, t.strsize, 1))
        return MVN_MALFORMED;

    uint32_t old_i = 0, new_i = 0;
    int n_old = mvn_count(buf, &t, old, &old_i);
    if (n_old < 0) return MVN_MALFORMED;
    if (n_old == 0) return MVN_UNMATCHED;
    if (n_old != 1 || mvn_count(buf, &t, new_, &new_i) != 1) return MVN_NOT_ONE_SYMBOL;
    if (!mvn_undefined(buf, &t, old_i) || !mvn_undefined(buf, &t, new_i)) return MVN_NOT_UNDEFINED;

    const struct dysymtab_command *dy = l.dy;
    if (!dy || dy->ntoc || dy->nmodtab || dy->nextrefsyms || dy->nindirectsyms || l.indexes_symtab)
        return MVN_DYSYMTAB_SHAPE;
    if ((uint64_t)dy->iundefsym + dy->nundefsym != t.nsyms || old_i < dy->iundefsym) return MVN_UNDEF_NOT_LAST;
    if (!mvn_fits(size, dy->extreloff, dy->nextrel, 8) || !mvn_fits(size, dy->locreloff, dy->nlocrel, 8))
        return MVN_MALFORMED;

    mvn_rels rs = { NULL, (size_t)dy->nextrel + dy->nlocrel };
    mvn_rel *rel = calloc(rs.n ? rs.n : 1, sizeof *rel);
    mvn_plan *plan = calloc(dy->nextrel ? dy->nextrel : 1, sizeof *plan);
    uint8_t *work = malloc(size);
    int rc = MVN_NOMEM;
    if (!rel || !plan || !work) goto out;
    rs.rel = rel;
    for (uint32_t i = 0; i < dy->nextrel; i++) mvn_decode(buf, dy->extreloff + (size_t)i * 8, 1, l.base, &rel[i]);
    for (uint32_t i = 0; i < dy->nlocrel; i++)
        mvn_decode(buf, dy->locreloff + (size_t)i * 8, 0, l.base, &rel[dy->nextrel + i]);

    rc = MVN_MALFORMED;
    for (size_t i = 0; i < rs.n; i++)
        if (rel[i].ext && rel[i].sym >= t.nsyms) goto out;
    rc = MVN_STRAY_REFERENCE;
    for (size_t i = dy->nextrel; i < rs.n; i++)
        if (rel[i].ext && rel[i].sym == old_i) goto out;
    rc = MVN_EXTERN_LOCAL_RELOC;
    for (size_t i = dy->nextrel; i < rs.n; i++)
        if (rel[i].ext) goto out;

    unsigned entries = 0;
    for (uint32_t i = 0; i < dy->nextrel; i++) {
        if (!rel[i].ext || rel[i].sym != old_i) continue;
        rc = mvn_plan_one(buf, &l, &rs, &rel[i], new_i, &plan[entries]);
        if (rc != MVN_OK) goto out;
        entries++;
    }
    rc = MVN_UNREFERENCED;
    if (entries == 0) goto out;

    memcpy(work, buf, size);
    for (unsigned i = 0; i < entries; i++) {
        const mvn_plan *p = &plan[i];
        memcpy(work + p->a_off, buf + p->b_off, 16);
        mvn_rel t2 = *p->target;
        t2.sym = new_i;
        mvn_store(work, &t2);
        const mvn_rel *src[MVN_MAX_IMPL], *dst[MVN_MAX_IMPL];
        size_t n = 0;
        mvn_impl_slots(&rs, p->a, p->b, src, dst, &n);
        for (size_t k = 0; k < n; k++) {
            mvn_rel d = *dst[k];
            d.sym = src[k]->sym; d.pcrel = src[k]->pcrel; d.length = src[k]->length;
            d.ext = src[k]->ext; d.type = src[k]->type;
            mvn_store(work, &d);
        }
    }

    size_t from = t.symoff + (size_t)old_i * sizeof(struct nlist_64), end = t.symoff + (size_t)t.nsyms * sizeof(struct nlist_64);
    memmove(work + from, work + from + sizeof(struct nlist_64), end - from - sizeof(struct nlist_64));
    memset(work + end - sizeof(struct nlist_64), 0, sizeof(struct nlist_64));
    uint32_t nsyms = t.nsyms - 1, nundefsym = dy->nundefsym - 1;
    memcpy(work + ((const uint8_t *)l.st - buf) + offsetof(struct symtab_command, nsyms), &nsyms, 4);
    memcpy(work + ((const uint8_t *)dy - buf) + offsetof(struct dysymtab_command, nundefsym), &nundefsym, 4);
    unsigned renumbered = 0;
    for (uint32_t i = 0; i < dy->nextrel; i++) {
        mvn_rel x;
        mvn_decode(work, dy->extreloff + (size_t)i * 8, 1, l.base, &x);
        if (x.ext && x.sym > old_i) { x.sym--; mvn_store(work, &x); renumbered++; }
    }

    mvn_tab ta = t;
    ta.nsyms = nsyms;
    rc = mvn_verify(buf, &t, work, &ta, dy, old, new_, entries);
    if (rc != MVN_OK) goto out;
    memcpy(buf, work, size);
    if (r) { r->entries = entries; r->removed_index = old_i; r->renumbered = renumbered; }
out:
    free(rel); free(plan); free(work);
    return rc;
}
