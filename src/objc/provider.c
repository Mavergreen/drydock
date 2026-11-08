/* provider.c -- whether a declared Objective-C provider is linked and activated in the final
 * artifact, proved from bytes; and the link mapping the build-evidence command records.
 *
 * A provider (Recaulk's NSWorkspace openURLs backfill is the first) is declared in
 * PREFIX/share/recaulk/objc-providers.json (main.m validates it: class, kind, selector, type
 * encoding, implementation symbol, activation root, required frameworks, archive digest) and
 * shipped as an archive of ordinary x86_64 objects. A send counts as `provided` only when ALL of:
 *
 *   1. Identity: the declaration and archive hash to what the build evidence recorded, and the
 *      archive to the declared digest -- recomputed every run; a cached report is not consulted.
 *   2. Linkage: the archive member defining the activation root is in the final x86_64 slice. The
 *      evidence (scripts/objc-build-evidence.sh) says where each placed atom of the archive's
 *      members landed; that is only where to look. Each atom reached is compared with its member
 *      byte for byte. Relocated fields are the only bytes that may differ, and each is resolved
 *      to what the object meant: a call to an import must reach a stub for that very symbol; a
 *      GOT load an indirect pointer for it (or, for a symbol the provider defines, the one
 *      supported linker relaxation, movq->leaq of the same target); a reference into a provider
 *      atom must land at that atom's evidenced address plus the same offset (and that atom is
 *      then verified too); a reference to a C string, literal, selector or class reference or
 *      constant CFString must reach the same content. Any other relocation type, a scattered
 *      relocation, an addend on an import or a different section name is cannot-measure.
 *   3. Activation: the root member's own constructor (its __mod_init_func entry) is verified the
 *      same way and its final address is a pointer in the final image's initializer table. The
 *      constructor's closure -- not the root's alone -- must call class_addMethod,
 *      sel_registerName and objc_getClass, carry the declared class, selector and type encoding
 *      as strings and reference the implementation symbol: the registration path of the declared
 *      method. The declared encoding must be the newer SDK's for that method. Only instance
 *      methods (kind "-") registered on objc_getClass's class are a supported shape.
 *   4. What it needs loaded: every import the verified provider code reaches (a call through a stub,
 *      a GOT load, a bound pointer) binds, by its two-level ordinal, to an LC_LOAD_DYLIB of the
 *      final image, and the declared class's home in the floor capture (AppKit for NSWorkspace) is
 *      one too -- strong, so loaded and initialized before the image's constructors run. Weak,
 *      lazy, upward, absent, or a flat or other special lookup is inactive. The declaration's
 *      required frameworks are what the link is given (scripts/objc-provider-link-args.sh), not
 *      what activation checks: a framework the provider binds nothing to (Carbon, whose functions
 *      it reaches through CoreServices and ApplicationServices) may be left out, as lld does.
 * A provider whose identity, mapping or registration does not check is cannot-measure (4). One
 * that checks but is not linked, constructed or strongly loaded is inactive: its sends stay
 * unsupported (1). An active provider turns exactly the unsupported findings of its selector and
 * kind, on a receiver whose floor class chain includes its class, into `provided`. Its own body's
 * sends are classified like any others; nothing in the archive is exempt.
 *
 * Every class_addMethod call the reader saw (OBJC_EV_METHOD_REGISTRATION) must lie in provider
 * code verified here, or the artifact is cannot-measure (unattested-method-registration): a
 * root symbol, a provider name or a link-argument list alone attests nothing.
 *
 * objc_map_provider_link is the build side: the final and prestrip slices must carry identical
 * sections (strip touches only __LINKEDIT), the link map's Arch and Sections must be this link's,
 * and each atom it places from an archive member must be a symbol the member defines and the
 * prestrip image has at that address. Archives are read by a bounded BSD ar(5) reader here
 * (the pinned Drydock's archive module needs its rewrite modules); objects by the bounded
 * MH_OBJECT reader below. Nothing is executed or loaded. */
#include "report.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>
#include <mach-o/x86_64/reloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define ARCHIVE_MAX (256u << 20)
#define LINKMAP_MAX (256u << 20)  /* Codex 0.165's map is 174 MB; the same bound as ARCHIVE_MAX */
#define DEPTH_MAX 8

/* ---- objects and archives ----------------------------------------------------------------------- */

typedef struct { char seg[17], sect[17], name[36]; uint64_t addr, size; uint32_t off, flags, reloff, nreloc; } OSect;
typedef struct {
    char name[256], sha[65];
    const uint8_t *buf; size_t size;
    OSect *sects; uint32_t nsects;
    struct nlist_64 *nl; uint32_t nsyms;
    const char *strtab; uint32_t strsize;
} OMember;
typedef struct { uint8_t *buf; size_t size; OMember *m; size_t n; } OArchive;

static void hex_digest(const uint8_t *p, size_t n, char out[65]) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX c;
    int i;
    CC_SHA256_Init(&c);
    while (n) { CC_LONG k = n > (1u << 30) ? (1u << 30) : (CC_LONG)n; CC_SHA256_Update(&c, p, k); p += k; n -= k; }
    CC_SHA256_Final(d, &c);
    for (i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(out + 2 * i, 3, "%02x", d[i]);
}

static int read_file(ObjcAnalysis *a, const char *path, size_t max, uint8_t **buf, size_t *size, const char *what) {
    FILE *f;
    struct stat st;
    *buf = NULL;
    if (!(f = fopen(path, "rb")) || fstat(fileno(f), &st) != 0 || !S_ISREG(st.st_mode)) {
        int e = errno;
        if (f) fclose(f);
        return objc_fail(a, "unreadable-input", NULL, 0, "%s %s: %s", what, path, strerror(e ? e : EINVAL));
    }
    if ((uint64_t)st.st_size > max) { fclose(f); return objc_fail(a, "oversized-input", NULL, 0, "%s %s: over %zu bytes", what, path, max); }
    *size = (size_t)st.st_size;
    if (!(*buf = malloc(*size + 1))) { fclose(f); return objc_fail(a, "out-of-memory", NULL, 0, "%s", what); }
    if (fread(*buf, 1, *size, f) != *size) { fclose(f); free(*buf); *buf = NULL; return objc_fail(a, "unreadable-input", NULL, 0, "%s %s: short read", what, path); }
    fclose(f);
    (*buf)[*size] = 0;
    return OBJC_OK;
}

static const char *sym_name(const OMember *m, uint32_t i) {
    uint32_t x = m->nl[i].n_un.n_strx;
    return x < m->strsize ? m->strtab + x : "";
}
static int defined(const struct nlist_64 *n) { return !(n->n_type & N_STAB) && (n->n_type & N_TYPE) == N_SECT; }

static int parse_object(ObjcAnalysis *a, OMember *m) {
    struct mach_header_64 h;
    size_t off;
    uint32_t i;
    int segs = 0;
    if (m->size < sizeof h) return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s is too short", m->name);
    memcpy(&h, m->buf, sizeof h);
    if (h.magic != MH_MAGIC_64 || h.cputype != CPU_TYPE_X86_64 || h.filetype != MH_OBJECT)
        return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s is not an x86_64 relocatable object", m->name);
    if (h.sizeofcmds > m->size - sizeof h) return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: load commands past its end", m->name);
    for (i = 0, off = sizeof h; i < h.ncmds; i++) {
        struct load_command lc;
        if (off + sizeof lc > sizeof h + h.sizeofcmds) return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: truncated load command", m->name);
        memcpy(&lc, m->buf + off, sizeof lc);
        if (lc.cmdsize < sizeof lc || lc.cmdsize > sizeof h + h.sizeofcmds - off)
            return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: bad load command size", m->name);
        if (lc.cmd == LC_SEGMENT_64) {
            struct segment_command_64 sg;
            uint32_t k;
            if (segs++ || lc.cmdsize < sizeof sg) return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: unexpected segments", m->name);
            memcpy(&sg, m->buf + off, sizeof sg);
            if ((uint64_t)sg.nsects * sizeof(struct section_64) > lc.cmdsize - sizeof sg)
                return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: sections past the command", m->name);
            if (!(m->sects = calloc(sg.nsects + 1, sizeof *m->sects))) return objc_fail(a, "out-of-memory", NULL, 0, "sections");
            for (k = 0; k < sg.nsects; k++) {
                struct section_64 x;
                OSect *o = &m->sects[k];
                uint8_t type;
                memcpy(&x, m->buf + off + sizeof sg + k * sizeof x, sizeof x);
                memcpy(o->seg, x.segname, 16); memcpy(o->sect, x.sectname, 16);
                snprintf(o->name, sizeof o->name, "%s,%s", o->seg, o->sect);
                o->addr = x.addr; o->size = x.size; o->off = x.offset; o->flags = x.flags;
                o->reloff = x.reloff; o->nreloc = x.nreloc;
                type = x.flags & SECTION_TYPE;
                if (type != S_ZEROFILL && type != S_GB_ZEROFILL && type != S_THREAD_LOCAL_ZEROFILL &&
                    (x.offset > m->size || x.size > m->size - x.offset))
                    return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: section %s past its end", m->name, o->name);
                if (x.reloff > m->size || (uint64_t)x.nreloc * 8 > m->size - x.reloff)
                    return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: relocations past its end", m->name);
            }
            m->nsects = sg.nsects;
        } else if (lc.cmd == LC_SYMTAB) {
            struct symtab_command st;
            if (lc.cmdsize < sizeof st) return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: short LC_SYMTAB", m->name);
            memcpy(&st, m->buf + off, sizeof st);
            if (st.symoff > m->size || (uint64_t)st.nsyms * sizeof(struct nlist_64) > m->size - st.symoff ||
                st.stroff > m->size || st.strsize > m->size - st.stroff || !st.strsize || m->buf[st.stroff + st.strsize - 1])
                return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: symbol table past its end", m->name);
            if (!(m->nl = malloc(((size_t)st.nsyms + 1) * sizeof *m->nl))) return objc_fail(a, "out-of-memory", NULL, 0, "symbols");
            memcpy(m->nl, m->buf + st.symoff, (size_t)st.nsyms * sizeof *m->nl);
            m->nsyms = st.nsyms; m->strtab = (const char *)m->buf + st.stroff; m->strsize = st.strsize;
        }
        off += lc.cmdsize;
    }
    for (i = 0; i < m->nsyms; i++)
        if (defined(&m->nl[i]) && (m->nl[i].n_sect < 1 || m->nl[i].n_sect > m->nsects))
            return objc_fail(a, "malformed-provider-archive", NULL, 0, "member %s: symbol %s in no section", m->name, sym_name(m, i));
    return OBJC_OK;
}

static void archive_free(OArchive *ar) {
    size_t i;
    for (i = 0; i < ar->n; i++) { free(ar->m[i].sects); free(ar->m[i].nl); }
    free(ar->m); free(ar->buf);
    memset(ar, 0, sizeof *ar);
}

/* BSD ar(5): "!<arch>\n", 60-byte headers, "#1/N" long names, even padding; index members skipped. */
static int archive_open(ObjcAnalysis *a, const char *path, OArchive *ar) {
    size_t off = 8;
    int rc;
    memset(ar, 0, sizeof *ar);
    if ((rc = read_file(a, path, ARCHIVE_MAX, &ar->buf, &ar->size, "provider archive"))) return rc;
    if (ar->size < 8 || memcmp(ar->buf, "!<arch>\n", 8)) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s is not an ar archive", path);
    while (off < ar->size) {
        const uint8_t *h = ar->buf + off;
        char field[17], name[256];
        unsigned long long sz;
        size_t data, len, nl = 0;
        char *end;
        OMember *g;
        size_t i;
        if (ar->size - off < 60 || h[58] != '`' || h[59] != '\n') return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: bad member header at %zu", path, off);
        memcpy(field, h + 48, 10); field[10] = 0;
        sz = strtoull(field, &end, 10);
        if (end == field || (*end && *end != ' ') || sz > ar->size - off - 60) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: bad member size at %zu", path, off);
        data = off + 60; len = (size_t)sz;
        memcpy(field, h, 16); field[16] = 0;
        if (!strncmp(field, "#1/", 3)) {
            nl = (size_t)strtoul(field + 3, &end, 10);
            if (!nl || nl >= sizeof name || nl > len) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: bad long name at %zu", path, off);
            memcpy(name, ar->buf + data, nl); name[nl] = 0;
            data += nl; len -= nl;
        } else {
            size_t k = 16;
            while (k && field[k - 1] == ' ') k--;
            if (k && field[k - 1] == '/') return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: GNU-style archive names are not supported", path);
            memcpy(name, field, k); name[k] = 0;
        }
        name[strcspn(name, "\0")] = 0;
        off = data + len + ((data + len) & 1);
        if (!strncmp(name, "__.SYMDEF", 9)) continue;
        if (!*name) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: unnamed member", path);
        for (i = 0; i < ar->n; i++)
            if (!strcmp(ar->m[i].name, name)) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: two members named %s", path, name);
        if (!(g = realloc(ar->m, (ar->n + 1) * sizeof *g))) return objc_fail(a, "out-of-memory", NULL, 0, "members");
        ar->m = g; g = &ar->m[ar->n++]; memset(g, 0, sizeof *g);
        snprintf(g->name, sizeof g->name, "%s", name);
        g->buf = ar->buf + data; g->size = len;
        hex_digest(g->buf, g->size, g->sha);
        if ((rc = parse_object(a, g))) return rc;
    }
    return OBJC_OK;
}

static OMember *member_named(OArchive *ar, const char *name) {
    size_t i;
    for (i = 0; i < ar->n; i++) if (!strcmp(ar->m[i].name, name)) return &ar->m[i];
    return NULL;
}

/* The member and symbol index defining external `name`, or -1. */
static int archive_defines(const OArchive *ar, const char *name, size_t *mi, uint32_t *si) {
    size_t i;
    uint32_t k;
    for (i = 0; i < ar->n; i++)
        for (k = 0; k < ar->m[i].nsyms; k++)
            if (defined(&ar->m[i].nl[k]) && (ar->m[i].nl[k].n_type & N_EXT) && !strcmp(sym_name(&ar->m[i], k), name)) {
                *mi = i; *si = k; return 0;
            }
    return -1;
}

/* [lo, hi) of the atom symbol si starts: up to the next symbol in its section, or the section end. */
static void atom_extent(const OMember *m, uint32_t si, uint64_t *lo, uint64_t *hi) {
    const struct nlist_64 *n = &m->nl[si];
    const OSect *x = &m->sects[n->n_sect - 1];
    uint32_t k;
    *lo = n->n_value; *hi = x->addr + x->size;
    for (k = 0; k < m->nsyms; k++)
        if (defined(&m->nl[k]) && m->nl[k].n_sect == n->n_sect && m->nl[k].n_value > *lo && m->nl[k].n_value < *hi)
            *hi = m->nl[k].n_value;
}

/* The symbol whose atom covers t in section sect (1-based), or -1. */
static long covering(const OMember *m, uint8_t sect, uint64_t t) {
    long best = -1;
    uint32_t k;
    for (k = 0; k < m->nsyms; k++)
        if (defined(&m->nl[k]) && m->nl[k].n_sect == sect && m->nl[k].n_value <= t &&
            (best < 0 || m->nl[k].n_value > m->nl[best].n_value))
            best = (long)k;
    return best;
}

typedef enum { C_ATOM, C_CSTRING, C_LITERAL, C_SLOT, C_CFSTRING, C_IGNORED } Content;

/* What a reference into section x means: an atom to verify, or content to compare. */
static Content content_of(const OSect *x, uint64_t *width) {
    uint8_t type = x->flags & SECTION_TYPE;
    *width = 0;
    if (type == S_CSTRING_LITERALS) return C_CSTRING;
    if (type == S_4BYTE_LITERALS) { *width = 4; return C_LITERAL; }
    if (type == S_8BYTE_LITERALS) { *width = 8; return C_LITERAL; }
    if (type == S_16BYTE_LITERALS) { *width = 16; return C_LITERAL; }
    if (type == S_LITERAL_POINTERS || !strcmp(x->sect, "__objc_selrefs") || !strcmp(x->sect, "__objc_classrefs") ||
        !strcmp(x->sect, "__objc_superrefs")) { *width = 8; return C_SLOT; }
    if (!strcmp(x->sect, "__cfstring")) { *width = 32; return C_CFSTRING; }
    if (!strcmp(x->sect, "__eh_frame") || !strcmp(x->seg, "__LD")) return C_IGNORED;
    return C_ATOM;
}

/* ---- verification ------------------------------------------------------------------------------- */

typedef struct { size_t m; uint32_t s; } Ref;
typedef struct {
    ObjcAnalysis *a;
    ObjcProvider *p;
    OArchive *ar;
    ObjcImage *im;
    Ref *work; size_t nwork, capwork, next;
    int collecting;                 /* the constructor's closure: registration facts count */
    char **facts; size_t nfacts;    /* "import:_sym", "string:text", "atom:_sym" */
    char **binds; size_t nbinds;    /* "_sym\tlibrary": what every verified import binds to (all code, not only the constructor's) */
    int status;
} V;

static int vfail(V *v, const char *code, uint64_t at, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
static int vfail(V *v, const char *code, uint64_t at, const char *fmt, ...) {
    char msg[768];
    va_list ap;
    va_start(ap, fmt); vsnprintf(msg, sizeof msg, fmt, ap); va_end(ap);
    v->status = objc_fail(v->a, code, "x86_64", at, "%s: %s", v->p->provider_id, msg);
    return -1;
}

static void fact(V *v, const char *kind, const char *text) {
    char buf[1024];
    if (!v->collecting) return;
    snprintf(buf, sizeof buf, "%s:%s", kind, text);
    if (objc_strv_push(&v->facts, &v->nfacts, buf)) v->status = objc_fail(v->a, "out-of-memory", NULL, 0, "facts");
}
/* An import the verified code reaches, and the library the final image binds it to. */
static void bind_of(V *v, const char *sym, const char *lib) {
    char buf[1200];
    size_t i;
    snprintf(buf, sizeof buf, "%s\t%s", sym, lib ? lib : "(no library)");
    for (i = 0; i < v->nbinds; i++) if (!strcmp(v->binds[i], buf)) return;
    if (objc_strv_push(&v->binds, &v->nbinds, buf)) v->status = objc_fail(v->a, "out-of-memory", NULL, 0, "binds");
}
static int has_fact(const V *v, const char *kind, const char *text) {
    char buf[1024];
    size_t i;
    snprintf(buf, sizeof buf, "%s:%s", kind, text);
    for (i = 0; i < v->nfacts; i++) if (!strcmp(v->facts[i], buf)) return 1;
    return 0;
}

static const ObjcProviderAtom *evidence_atom(const ObjcProvider *p, const char *member, const char *symbol) {
    size_t i;
    for (i = 0; i < p->n_atoms; i++)
        if (!strcmp(p->atoms[i].member, member) && !strcmp(p->atoms[i].symbol, symbol)) return &p->atoms[i];
    return NULL;
}

static int enqueue(V *v, size_t m, uint32_t s) {
    size_t i;
    for (i = 0; i < v->nwork; i++) if (v->work[i].m == m && v->work[i].s == s) return 0;
    if (v->nwork == v->capwork) {
        Ref *g = realloc(v->work, (v->capwork = v->capwork ? v->capwork * 2 : 64) * sizeof *g);
        if (!g) return vfail(v, "out-of-memory", 0, "work list");
        v->work = g;
    }
    v->work[v->nwork].m = m; v->work[v->nwork].s = s; v->nwork++;
    return 0;
}

static uint32_t rd32(const uint8_t *p) { uint32_t x; memcpy(&x, p, 4); return x; }
static uint64_t rd64(const uint8_t *p) { uint64_t x; memcpy(&x, p, 8); return x; }

static int final_section_is(const V *v, uint64_t va, uint8_t type, const char *name) {
    uint32_t flags;
    const char *n = objc_image_section_of(v->im, va, NULL, NULL, &flags);
    if (!n) return 0;
    if (name && strcmp(n, name)) return 0;
    return type == 0xff || (flags & SECTION_TYPE) == type;
}

static int compare_region(V *v, size_t mi, const OSect *x, uint64_t lo, uint64_t hi, uint64_t fin, int depth);

/* A provider atom referenced at final address T (offset into it `off`): its evidenced address must
 * match, and it joins the work list. */
static int internal_target(V *v, size_t mi, uint32_t si, uint64_t off, uint64_t T, uint64_t at) {
    const OMember *m = &v->ar->m[mi];
    const char *name = sym_name(m, si);
    const ObjcProviderAtom *e = evidence_atom(v->p, m->name, name);
    if (!e) return vfail(v, "provider-mapping-mismatch", at, "the evidence places no atom %s(%s)", m->name, name);
    if (T != e->address + off)
        return vfail(v, "provider-mapping-mismatch", at, "reference to %s(%s)+%llu reaches 0x%llx, not 0x%llx", m->name, name,
                     (unsigned long long)off, (unsigned long long)T, (unsigned long long)(e->address + off));
    if (!strcmp(name + (*name == '_'), v->p->impl_symbol)) fact(v, "atom", name);
    return enqueue(v, mi, si);
}

/* An object address t in section index sect (1-based) of member mi, reached at final T. */
static int obj_target(V *v, size_t mi, uint8_t sect, uint64_t t, uint64_t T, uint64_t at, int depth) {
    const OMember *m = &v->ar->m[mi];
    const OSect *xs;
    uint64_t w;
    Content c;
    long s;
    if (sect < 1 || sect > m->nsects) return vfail(v, "unsupported-provider-relocation", at, "%s: relocation to no section", m->name);
    xs = &m->sects[sect - 1];
    if (t < xs->addr || t >= xs->addr + xs->size) return vfail(v, "unsupported-provider-relocation", at, "%s: target outside %s", m->name, xs->name);
    c = content_of(xs, &w);
    if (depth > DEPTH_MAX) return vfail(v, "unsupported-provider-relocation", at, "references nest too deep");
    switch (c) {
    case C_CSTRING: {
        const char *s0 = (const char *)m->buf + xs->off + (t - xs->addr);
        size_t room = (size_t)(xs->addr + xs->size - t), len = strnlen(s0, room);
        const uint8_t *f;
        if (len == room) return vfail(v, "unsupported-provider-relocation", at, "%s: unterminated string", m->name);
        if (!final_section_is(v, T, S_CSTRING_LITERALS, NULL) || !(f = objc_image_bytes(v->im, T, len + 1)) || memcmp(f, s0, len + 1))
            return vfail(v, "provider-mapping-mismatch", at, "string \"%.80s\" is not at 0x%llx", s0, (unsigned long long)T);
        fact(v, "string", s0);
        return 0;
    }
    case C_LITERAL: {
        const uint8_t *f = objc_image_bytes(v->im, T, w);
        /* ld64 merges 4-, 8- and 16-byte literals into __TEXT,__const, lld into __TEXT,__literals. */
        if (t + w > xs->addr + xs->size || !f ||
            (!final_section_is(v, T, xs->flags & SECTION_TYPE, NULL) && !final_section_is(v, T, S_REGULAR, "__TEXT,__const") &&
             !final_section_is(v, T, S_REGULAR, "__TEXT,__literals")) ||
            memcmp(f, m->buf + xs->off + (t - xs->addr), w))
            return vfail(v, "provider-mapping-mismatch", at, "%llu-byte literal differs at 0x%llx", (unsigned long long)w, (unsigned long long)T);
        return 0;
    }
    case C_SLOT: case C_CFSTRING:
        if (t + w > xs->addr + xs->size || !final_section_is(v, T, 0xff, xs->name))
            return vfail(v, "provider-mapping-mismatch", at, "%s entry is not at 0x%llx", xs->name, (unsigned long long)T);
        return compare_region(v, mi, xs, t, t + w, T, depth + 1);
    case C_IGNORED:
        return vfail(v, "unsupported-provider-relocation", at, "code refers into %s", xs->name);
    case C_ATOM:
        if ((s = covering(m, sect, t)) < 0) return vfail(v, "unsupported-provider-relocation", at, "%s: no atom covers 0x%llx", m->name, (unsigned long long)t);
        return internal_target(v, mi, (uint32_t)s, t - m->nl[s].n_value, T, at);
    }
    return 0;
}

/* Compare [lo, hi) of section x of member mi with the final image at `fin`, resolving relocations. */
static int compare_region(V *v, size_t mi, const OSect *x, uint64_t lo, uint64_t hi, uint64_t fin, int depth) {
    const OMember *m = &v->ar->m[mi];
    const uint8_t *ob = m->buf + x->off + (lo - x->addr), *fb;
    uint64_t size = hi - lo, i;
    uint8_t *mask;
    long relax = -1;
    uint32_t k;
    if (!(fb = objc_image_bytes(v->im, fin, size))) return vfail(v, "provider-mapping-mismatch", fin, "%s: no bytes at 0x%llx for %llu", m->name, (unsigned long long)fin, (unsigned long long)size);
    if (!(mask = calloc(size + 1, 1))) return vfail(v, "out-of-memory", fin, "mask");
    for (k = 0; k < x->nreloc && !v->status; k++) {
        struct relocation_info r;
        uint64_t field, at, T;
        int N = 0;
        memcpy(&r, m->buf + x->reloff + (size_t)k * 8, 8);
        if ((uint32_t)r.r_address & R_SCATTERED) { vfail(v, "unsupported-provider-relocation", fin, "%s: scattered relocation", m->name); break; }
        if ((uint64_t)(uint32_t)r.r_address < lo - x->addr || (uint64_t)(uint32_t)r.r_address >= hi - x->addr) continue;
        field = (uint64_t)(uint32_t)r.r_address - (lo - x->addr);
        at = fin + field;
        switch (r.r_type) {
        case X86_64_RELOC_SIGNED_1: N = 1; goto pcrel;
        case X86_64_RELOC_SIGNED_2: N = 2; goto pcrel;
        case X86_64_RELOC_SIGNED_4: N = 4; goto pcrel;
        case X86_64_RELOC_BRANCH: case X86_64_RELOC_SIGNED: case X86_64_RELOC_GOT_LOAD: case X86_64_RELOC_GOT:
        pcrel: {
            int32_t c, d;
            if (!r.r_pcrel || r.r_length != 2 || field + 4 > size) { vfail(v, "unsupported-provider-relocation", at, "%s: pc-relative relocation shape", m->name); break; }
            memset(mask + field, 1, 4);
            c = (int32_t)rd32(ob + field); d = (int32_t)rd32(fb + field);
            T = at + 4 + (uint64_t)N + (uint64_t)(int64_t)d;
            if (r.r_type == X86_64_RELOC_GOT_LOAD || r.r_type == X86_64_RELOC_GOT) {
                const char *name;
                size_t mi2; uint32_t si2;
                if (!r.r_extern || r.r_symbolnum >= m->nsyms || c) { vfail(v, "unsupported-provider-relocation", at, "%s: GOT relocation shape", m->name); break; }
                name = sym_name(m, r.r_symbolnum);
                if (defined(&m->nl[r.r_symbolnum]) || !archive_defines(v->ar, name, &mi2, &si2)) {
                    const ObjcProviderAtom *e;
                    if (defined(&m->nl[r.r_symbolnum])) { mi2 = mi; si2 = r.r_symbolnum; }
                    if (!(e = evidence_atom(v->p, v->ar->m[mi2].name, sym_name(&v->ar->m[mi2], si2)))) {
                        vfail(v, "provider-mapping-mismatch", at, "the evidence places no atom %s(%s)", v->ar->m[mi2].name, name); break;
                    }
                    if (T == e->address && r.r_type == X86_64_RELOC_GOT_LOAD && field >= 2 && ob[field - 2] == 0x8b && fb[field - 2] == 0x8d)
                        relax = (long)(field - 2);   /* movq sym@GOTPCREL -> leaq sym: the target itself */
                    else if (!final_section_is(v, T, S_NON_LAZY_SYMBOL_POINTERS, NULL) || !objc_image_bytes(v->im, T, 8) ||
                             rd64(objc_image_bytes(v->im, T, 8)) != e->address) {
                        vfail(v, "provider-mapping-mismatch", at, "GOT load of %s does not reach it", name); break;
                    }
                    if (internal_target(v, mi2, si2, 0, e->address, at)) break;
                } else {
                    const char *imp = objc_image_import_at(v->im, T);
                    if (!final_section_is(v, T, S_NON_LAZY_SYMBOL_POINTERS, NULL) || !imp || strcmp(imp, name)) {
                        vfail(v, "provider-mapping-mismatch", at, "GOT load of %s reaches %s", name, imp ? imp : "no import"); break;
                    }
                    bind_of(v, name, objc_image_import_lib_at(v->im, T));
                }
                break;
            }
            if (r.r_extern) {
                const char *name;
                size_t mi2; uint32_t si2;
                if (r.r_symbolnum >= m->nsyms) { vfail(v, "unsupported-provider-relocation", at, "%s: symbol index", m->name); break; }
                name = sym_name(m, r.r_symbolnum);
                if (defined(&m->nl[r.r_symbolnum])) {
                    obj_target(v, mi, m->nl[r.r_symbolnum].n_sect, m->nl[r.r_symbolnum].n_value + (uint64_t)(int64_t)c + (uint64_t)N, T, at, depth);
                } else if (!archive_defines(v->ar, name, &mi2, &si2)) {
                    internal_target(v, mi2, si2, (uint64_t)(int64_t)c + (uint64_t)N, T, at);
                } else {
                    const char *imp = objc_image_import_at(v->im, T);
                    if (r.r_type != X86_64_RELOC_BRANCH || c || !final_section_is(v, T, S_SYMBOL_STUBS, NULL) || !imp || strcmp(imp, name)) {
                        vfail(v, "provider-mapping-mismatch", at, "call to %s reaches %s", name, imp ? imp : "no stub"); break;
                    }
                    fact(v, "import", name);
                    bind_of(v, name, objc_image_import_lib_at(v->im, T));
                }
            } else {
                uint64_t t = x->addr + (uint64_t)(uint32_t)r.r_address + 4 + (uint64_t)N + (uint64_t)(int64_t)c;
                obj_target(v, mi, (uint8_t)r.r_symbolnum, t, T, at, depth);
            }
            break;
        }
        case X86_64_RELOC_UNSIGNED: {
            uint64_t c, val;
            if (r.r_pcrel || r.r_length != 3 || field + 8 > size) { vfail(v, "unsupported-provider-relocation", at, "%s: pointer relocation shape", m->name); break; }
            memset(mask + field, 1, 8);
            c = rd64(ob + field); val = rd64(fb + field);
            if (r.r_extern) {
                const char *name;
                size_t mi2; uint32_t si2;
                if (r.r_symbolnum >= m->nsyms) { vfail(v, "unsupported-provider-relocation", at, "%s: symbol index", m->name); break; }
                name = sym_name(m, r.r_symbolnum);
                if (defined(&m->nl[r.r_symbolnum])) obj_target(v, mi, m->nl[r.r_symbolnum].n_sect, m->nl[r.r_symbolnum].n_value + c, val, at, depth);
                else if (!archive_defines(v->ar, name, &mi2, &si2)) internal_target(v, mi2, si2, c, val, at);
                else {
                    const char *b = objc_image_bound_at(v->im, at);
                    if (c || !b || strcmp(b, name)) { vfail(v, "provider-mapping-mismatch", at, "pointer to %s is bound to %s", name, b ? b : "nothing"); break; }
                    bind_of(v, name, objc_image_bound_lib_at(v->im, at));
                }
            } else obj_target(v, mi, (uint8_t)r.r_symbolnum, c, val, at, depth);
            break;
        }
        default:
            vfail(v, "unsupported-provider-relocation", at, "%s: relocation type %u", m->name, (unsigned)r.r_type);
        }
    }
    for (i = 0; i < size && !v->status; i++)
        if (!mask[i] && ob[i] != fb[i] && (long)i != relax)
            vfail(v, "provider-mapping-mismatch", fin + i, "%s differs from the final image at 0x%llx", m->name, (unsigned long long)(fin + i));
    free(mask);
    return v->status ? -1 : 0;
}

static int add_range(V *v, uint64_t lo, uint64_t hi) {
    uint64_t *g = realloc(v->p->ranges, (v->p->n_ranges + 1) * 2 * sizeof *g);
    if (!g) return vfail(v, "out-of-memory", lo, "ranges");
    v->p->ranges = g; g[v->p->n_ranges * 2] = lo; g[v->p->n_ranges * 2 + 1] = hi; v->p->n_ranges++;
    return 0;
}

static int drain(V *v) {
    while (v->next < v->nwork && !v->status) {
        Ref r = v->work[v->next++];
        const OMember *m = &v->ar->m[r.m];
        const char *name = sym_name(m, r.s);
        const OSect *x = &m->sects[m->nl[r.s].n_sect - 1];
        const ObjcProviderAtom *e = evidence_atom(v->p, m->name, name);
        uint64_t lo, hi, w;
        const char *fs;
        if (content_of(x, &w) != C_ATOM) return vfail(v, "unsupported-provider-relocation", 0, "%s(%s) is not code or data", m->name, name);
        if (!e) return vfail(v, "provider-mapping-mismatch", 0, "the evidence places no atom %s(%s)", m->name, name);
        atom_extent(m, r.s, &lo, &hi);
        if (hi - lo != e->size)
            return vfail(v, "provider-mapping-mismatch", e->address, "%s(%s) is %llu bytes, the evidence says %llu", m->name, name,
                         (unsigned long long)(hi - lo), (unsigned long long)e->size);
        if (!(fs = objc_image_section_of(v->im, e->address, NULL, NULL, NULL)) || strcmp(fs, x->name))
            return vfail(v, "provider-mapping-mismatch", e->address, "%s(%s) is in %s, the final address in %s", m->name, name, x->name, fs ? fs : "no section");
        if (compare_region(v, r.m, x, lo, hi, e->address, 0) || add_range(v, e->address, e->address + e->size)) return -1;
        v->p->verified++;
    }
    return v->status ? -1 : 0;
}

/* Whether the final image strongly loads (LC_LOAD_DYLIB) the library `lib`: an install name, or a
 * short name as the floor capture records a class's image (a framework's or a dylib's last path
 * component, "AppKit"). *how is the load kind found, or NULL when nothing loads it. */
static int library_load(const ObjcAnalysis *a, const char *lib, const char **how) {
    size_t i;
    *how = NULL;
    for (i = 0; i < a->n_dylibs; i++) {
        const char *p = a->dylibs[i].path, *tail = strrchr(p, '/');
        if (strcmp(p, lib) && !(strchr(lib, '/') == NULL && tail && !strcmp(tail + 1, lib))) continue;
        *how = a->dylibs[i].how;
        if (!strcmp(*how, "load")) return 1;
    }
    return 0;
}
static const char *load_kind(const char *how) {
    return !how ? "not linked" : !strcmp(how, "weak") ? "weakly linked" : !strcmp(how, "lazy") ? "lazily linked" :
           !strcmp(how, "upward") ? "linked upward (initialized late)" : "not strongly linked";
}

static int set_reason(ObjcAnalysis *a, ObjcProvider *p, int active, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
static int set_reason(ObjcAnalysis *a, ObjcProvider *p, int active, const char *fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt); vsnprintf(msg, sizeof msg, fmt, ap); va_end(ap);
    p->active = active;
    return objc_set_string(&p->reason, msg) ? objc_fail(a, "out-of-memory", NULL, 0, "provider") : OBJC_OK;
}

/* ---- line tables (only with a source receipt) ---------------------------------------------------- */

/* A DW_LNE_set_address operand's relocation: unsigned, 8 bytes, absolute, to a section of the member
 * (its in-place value is the object address) or to a symbol it defines (plus the in-place addend). */
typedef struct { const OMember *m; const OSect *x; } LineCtx;
static int line_reloc(void *ctx, uint64_t off, uint64_t *addr) {
    const LineCtx *c = ctx;
    uint32_t k;
    for (k = 0; k < c->x->nreloc; k++) {
        struct relocation_info r;
        uint64_t v;
        memcpy(&r, c->m->buf + c->x->reloff + (size_t)k * 8, 8);
        if ((uint32_t)r.r_address & R_SCATTERED) return -1;
        if ((uint64_t)(uint32_t)r.r_address != off) continue;
        if (r.r_type != X86_64_RELOC_UNSIGNED || r.r_length != 3 || r.r_pcrel || off + 8 > c->x->size) return -1;
        memcpy(&v, c->m->buf + c->x->off + off, 8);
        if (r.r_extern) {
            if (r.r_symbolnum >= c->m->nsyms || !defined(&c->m->nl[r.r_symbolnum])) return -1;
            v += c->m->nl[r.r_symbolnum].n_value;
        } else if (!r.r_symbolnum || r.r_symbolnum > c->m->nsects ||
                   !(c->m->sects[r.r_symbolnum - 1].flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)))
            return -1;
        *addr = v;
        return 0;
    }
    return -1;
}

static int line_cmp(const void *x, const void *y) {
    const ObjcLine *a = x, *b = y;
    return a->addr < b->addr ? -1 : a->addr > b->addr;
}

/* Each linked member's __DWARF,__debug_line rows, carried to final addresses through the evidence's
 * atom mapping: a row lands at its atom's final address plus its offset in the atom, and is kept only
 * inside atoms the evidence places. A member without a line table contributes nothing; a line
 * table this reader does not accept is cannot-measure. */
static int member_lines(ObjcAnalysis *a, ObjcProvider *p, OArchive *ar) {
    size_t i, r;
    for (i = 0; i < p->n_members; i++) {
        OMember *m = member_named(ar, p->members[i].name);
        const OSect *dl = NULL, *ls = NULL;
        ObjcDwarfRow *rows = NULL;
        size_t nrows = 0;
        uint32_t k;
        char why[256];
        LineCtx ctx;
        if (!m) continue;
        for (k = 0; k < m->nsects; k++) {
            if (!strcmp(m->sects[k].seg, "__DWARF") && !strcmp(m->sects[k].sect, "__debug_line")) dl = &m->sects[k];
            if (!strcmp(m->sects[k].seg, "__DWARF") && !strcmp(m->sects[k].sect, "__debug_line_str")) ls = &m->sects[k];
        }
        if (!dl) continue;
        ctx.m = m; ctx.x = dl;
        if (objc_dwarf_lines(m->buf + dl->off, dl->size, ls ? m->buf + ls->off : NULL, ls ? ls->size : 0, line_reloc, &ctx,
                             &rows, &nrows, why, sizeof why))
            return objc_fail(a, "unsupported-line-table", NULL, 0, "%s: member %s: %s", p->provider_id, m->name, why);
        for (r = 0; r < nrows; r++) {
            const ObjcDwarfRow *w = &rows[r];
            const ObjcProviderAtom *at;
            ObjcLine *g;
            long s = -1;
            for (k = 0; k < m->nsects && s < 0; k++)
                if (w->addr >= m->sects[k].addr && w->addr < m->sects[k].addr + m->sects[k].size) s = covering(m, (uint8_t)(k + 1), w->addr);
            if (w->end || s < 0 || !(at = evidence_atom(p, m->name, sym_name(m, (uint32_t)s)))) continue;
            if (w->addr - m->nl[s].n_value >= at->size) continue;
            if (!(g = realloc(p->lines, (p->n_lines + 1) * sizeof *g))) { r = nrows; break; }
            p->lines = g; g = &g[p->n_lines];
            g->addr = at->address + (w->addr - m->nl[s].n_value); g->lo = at->address; g->hi = at->address + at->size;
            g->line = w->line; g->col = w->col;
            if (!(g->file = strdup(w->file))) break;
            p->n_lines++;
        }
        for (r = 0; r < nrows; r++) free(rows[r].file);
        free(rows);
    }
    if (p->n_lines > 1) qsort(p->lines, p->n_lines, sizeof *p->lines, line_cmp);
    return OBJC_OK;
}

static int verify_one(ObjcAnalysis *a, ObjcProvider *p, ObjcImage *im) {
    OArchive ar;
    V v;
    size_t rm, i;
    uint32_t rs, k;
    const OMember *m;
    const OSect *init = NULL;
    char root[300], impl[300], key[1024], fws[2048] = "", rootm[256], needwhy[1400] = "";
    const char *enc;
    int rc;
    if (!p->have_evidence) return set_reason(a, p, 0, "no build evidence names this provider");
    if (strcmp(p->ev_declaration_sha256, p->declaration_sha256))
        return objc_fail(a, "stale-provider-evidence", NULL, 0, "%s: the declaration is %s, the build evidence recorded %s", p->provider_id, p->declaration_sha256, p->ev_declaration_sha256);
    if (strcmp(p->ev_archive_sha256, p->archive_sha256))
        return objc_fail(a, "stale-provider-evidence", NULL, 0, "%s: the archive is %s, the build evidence recorded %s", p->provider_id, p->archive_sha256, p->ev_archive_sha256);
    if (strcmp(p->method_kind, "-"))
        return objc_fail(a, "unsupported-provider", NULL, 0, "%s: only instance-method providers registered on objc_getClass's class are supported", p->provider_id);
    snprintf(key, sizeof key, "%s\t%s\t%s", p->cls, p->method_kind, p->selector);
    if (!(enc = a->nw_encoding ? objc_map_get(a->nw_encoding, key) : NULL) || strcmp(enc, p->encoding))
        return objc_fail(a, "provider-abi-mismatch", NULL, 0, "%s: declared %s%s %s as %s; the newer SDK %s%s", p->provider_id, p->method_kind,
                         p->cls, p->selector, p->encoding, enc ? "declares " : "does not declare it", enc ? enc : "");
    if ((rc = archive_open(a, p->archive, &ar))) { archive_free(&ar); return rc; }
    for (i = 0; i < p->n_members; i++) {
        const OMember *g = member_named(&ar, p->members[i].name);
        if (!g || strcmp(g->sha, p->members[i].sha256)) {
            archive_free(&ar);
            return objc_fail(a, "stale-provider-evidence", NULL, 0, "%s: archive member %s is not the one the evidence recorded", p->provider_id, p->members[i].name);
        }
    }
    snprintf(root, sizeof root, "_%s", p->root_symbol);
    snprintf(impl, sizeof impl, "_%s", p->impl_symbol);
    if (archive_defines(&ar, root, &rm, &rs) || archive_defines(&ar, impl, &i, &k)) {
        archive_free(&ar);
        return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: the archive does not define both %s and %s", p->provider_id, root, impl);
    }
    m = &ar.m[rm];
    snprintf(rootm, sizeof rootm, "%s", m->name);
    for (i = 0; i < p->n_members && strcmp(p->members[i].name, m->name); i++) ;
    if (i == p->n_members) { archive_free(&ar); return set_reason(a, p, 0, "the activation root's member %s is not in the link", rootm); }
    for (k = 0; k < m->nsects; k++) if ((m->sects[k].flags & SECTION_TYPE) == S_MOD_INIT_FUNC_POINTERS) init = &m->sects[k];
    if (!init || !init->nreloc) { archive_free(&ar); return objc_fail(a, "unsupported-provider", NULL, 0, "%s: member %s has no constructor", p->provider_id, rootm); }

    memset(&v, 0, sizeof v);
    v.a = a; v.p = p; v.ar = &ar; v.im = im; v.collecting = 1;
    /* The constructor's closure first: only what it reaches counts as the registration path. */
    for (k = 0; k < init->nreloc && !v.status; k++) {
        struct relocation_info r;
        long s;
        memcpy(&r, m->buf + init->reloff + (size_t)k * 8, 8);
        if (r.r_type != X86_64_RELOC_UNSIGNED || r.r_length != 3 || r.r_pcrel) { vfail(&v, "unsupported-provider", 0, "constructor entry shape"); break; }
        if (r.r_extern) s = r.r_symbolnum < m->nsyms && defined(&m->nl[r.r_symbolnum]) ? (long)r.r_symbolnum : -1;
        else {
            uint64_t t = rd64(m->buf + init->off + (uint32_t)r.r_address);
            s = covering(m, (uint8_t)r.r_symbolnum, t);
            if (s >= 0 && m->nl[s].n_value != t) s = -1;
        }
        if (s < 0) { vfail(&v, "unsupported-provider", 0, "constructor entry names no function of %s", m->name); break; }
        if (!p->constructor) {
            const ObjcProviderAtom *e = evidence_atom(p, m->name, sym_name(m, (uint32_t)s));
            if (!e) { vfail(&v, "provider-mapping-mismatch", 0, "the evidence places no constructor %s(%s)", m->name, sym_name(m, (uint32_t)s)); break; }
            p->constructor = e->address;
        }
        enqueue(&v, rm, (uint32_t)s);
    }
    if (!v.status) drain(&v);
    v.collecting = 0;
    if (!v.status && !enqueue(&v, rm, rs)) drain(&v);
    rc = v.status;
    if (!rc) {
        static const char *NEED[] = { "_class_addMethod", "_sel_registerName", "_objc_getClass" };
        const char *strs[3];
        strs[0] = p->cls; strs[1] = p->selector; strs[2] = p->encoding;
        for (i = 0; i < 3 && !rc; i++)
            if (!has_fact(&v, "import", NEED[i]))
                rc = objc_fail(a, "provider-registration-mismatch", NULL, 0, "%s: the constructor's code never calls %s", p->provider_id, NEED[i]);
        for (i = 0; i < 3 && !rc; i++)
            if (!has_fact(&v, "string", strs[i]))
                rc = objc_fail(a, "provider-registration-mismatch", NULL, 0, "%s: the constructor's code does not carry the declared \"%s\"", p->provider_id, strs[i]);
        if (!rc && !has_fact(&v, "atom", impl))
            rc = objc_fail(a, "provider-registration-mismatch", NULL, 0, "%s: the constructor's code does not reference %s", p->provider_id, impl);
    }
    if (!rc && a->src_sha256) rc = member_lines(a, p, &ar);
    /* 4. What it needs loaded: every library its verified imports bind to, and its class's home. */
    if (!rc) {
        const char *idx = objc_map_get(a->rt_class, p->cls), *how, *home;
        if (!idx) snprintf(needwhy, sizeof needwhy, "%s is not a class of the floor capture", p->cls);
        else if (!library_load(a, (home = a->rt_classes[strtoul(idx, NULL, 10)].image), &how))
            snprintf(needwhy, sizeof needwhy, "%s (home of %s) is %s", home, p->cls, load_kind(how));
        else snprintf(fws, sizeof fws, "%s (home of %s)", home, p->cls);
        for (i = 0; i < v.nbinds && !needwhy[0]; i++) {
            char *tab = strchr(v.binds[i], '\t');
            const char *lib = tab + 1;
            *tab = 0;
            if (!library_load(a, lib, &how))
                snprintf(needwhy, sizeof needwhy, "%s binds to %s, which is %s", v.binds[i], lib,
                         lib[0] == '(' ? "not a library the image loads" : load_kind(how));
            else if (!strstr(fws, lib))
                snprintf(fws + strlen(fws), sizeof fws - strlen(fws), ", %s", lib);
            *tab = '\t';
        }
    }
    for (i = 0; i < v.nfacts; i++) free(v.facts[i]);
    for (i = 0; i < v.nbinds; i++) free(v.binds[i]);
    free(v.facts); free(v.binds); free(v.work); archive_free(&ar);
    if (rc) return OBJC_CANNOT_MEASURE;

    /* The constructor's final address must be an initializer. */
    {
        size_t n = objc_image_nsections(im), j;
        int found = 0;
        for (j = 0; j < n && !found; j++) {
            uint64_t addr, size, o;
            uint32_t flags;
            objc_image_section(im, j, &addr, &size, &flags);
            if ((flags & SECTION_TYPE) != S_MOD_INIT_FUNC_POINTERS) continue;
            for (o = 0; o + 8 <= size; o += 8) {
                const uint8_t *b = objc_image_bytes(im, addr + o, 8);
                if (b && rd64(b) == p->constructor) { found = 1; break; }
            }
        }
        if (!found) return set_reason(a, p, 0, "linked, but its constructor at 0x%llx is not in the final initializer table", (unsigned long long)p->constructor);
    }
    if (needwhy[0]) return set_reason(a, p, 0, "linked and constructed, but %s", needwhy);
    return set_reason(a, p, 1, "archive sha256 %.12s..., member %s: constructor at 0x%llx in the initializer table, %zu atoms "
                      "byte-verified, registers %s[%s %s] %s; %s strongly loaded", p->archive_sha256, rootm,
                      (unsigned long long)p->constructor, p->verified, p->method_kind, p->cls, p->selector, p->encoding, fws);
}

/* Whether floor class `cls`'s runtime chain includes `owner`. */
static int chain_includes(const ObjcAnalysis *a, const char *cls, const char *owner) {
    int depth;
    for (depth = 0; cls && depth < 64; depth++) {
        const char *i;
        if (!strcmp(cls, owner)) return 1;
        if (!(i = objc_map_get(a->rt_class, cls))) return 0;
        cls = a->rt_classes[strtoul(i, NULL, 10)].super;
    }
    return 0;
}

int objc_verify_providers(ObjcAnalysis *a) {
    ObjcImage *im = NULL;
    size_t i, j, k;
    int rc;
    if (a->n_providers && (rc = objc_image_open(a, a->artifact_path, &im))) return rc;
    for (i = 0; i < a->n_providers; i++) {
        if ((rc = verify_one(a, &a->providers[i], im))) { objc_image_close(im); return rc; }
    }
    objc_image_close(im);
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        int ok = 0;
        if (e->kind != OBJC_EV_METHOD_REGISTRATION) continue;
        for (j = 0; j < a->n_providers && !ok; j++)
            for (k = 0; k < a->providers[j].n_ranges && !ok; k++)
                ok = e->address >= a->providers[j].ranges[2 * k] && e->address < a->providers[j].ranges[2 * k + 1];
        if (!ok) objc_fail(a, "unattested-method-registration", e->slice, e->address,
                           "%s in %s lies outside every provider this analysis verified; a run-time method registration is not modelled",
                           e->name, e->function ? e->function : "an unnamed function");
    }
    return a->n_errors ? OBJC_CANNOT_MEASURE : OBJC_OK;
}

int objc_provide_findings(ObjcAnalysis *a) {
    size_t i, j;
    for (i = 0; i < a->n_findings; i++) {
        ObjcFinding *f = &a->findings[i];
        const ObjcSend *s = &a->sends[f->send];
        for (j = 0; j < a->n_providers; j++) {
            const ObjcProvider *p = &a->providers[j];
            char proof[2048];
            if (!p->active || f->verdict != OBJC_UNSUPPORTED || !s->selector || !s->method_kind || !s->receiver ||
                strcmp(s->selector, p->selector) || strcmp(s->method_kind, p->method_kind) || !chain_includes(a, s->receiver, p->cls))
                continue;
            snprintf(proof, sizeof proof, "provided by %s: %s (was: %s)", p->provider_id, p->reason, f->proof ? f->proof : "-");
            if (objc_set_string(&f->proof, proof)) return objc_fail(a, "out-of-memory", NULL, 0, "proof");
            f->verdict = OBJC_PROVIDED;
            break;
        }
    }
    return OBJC_OK;
}

/* ---- the build side ------------------------------------------------------------------------------ */

static int same_sections(ObjcAnalysis *a, ObjcImage *f, ObjcImage *p) {
    size_t n = objc_image_nsections(f), i;
    if (n != objc_image_nsections(p)) return objc_fail(a, "prestrip-mismatch", NULL, 0, "the final and prestrip images have different sections");
    for (i = 0; i < n; i++) {
        uint64_t fa, fs, pa, ps;
        uint32_t ff, pf;
        char fname[40];
        const uint8_t *fb, *pb;
        uint8_t type;
        snprintf(fname, sizeof fname, "%s", objc_image_section(f, i, &fa, &fs, &ff));
        if (strcmp(fname, objc_image_section(p, i, &pa, &ps, &pf)) || fa != pa || fs != ps || ff != pf)
            return objc_fail(a, "prestrip-mismatch", NULL, fa, "section %s differs in place or size between the final and prestrip images", fname);
        type = ff & SECTION_TYPE;
        if (!fs || type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) continue;
        fb = objc_image_bytes(f, fa, fs); pb = objc_image_bytes(p, pa, ps);
        if (!fb || !pb || memcmp(fb, pb, fs)) return objc_fail(a, "prestrip-mismatch", NULL, fa, "section %s bytes differ between the final and prestrip images", fname);
    }
    return OBJC_OK;
}

typedef struct { long index; char path[PATH_MAX]; char member[256]; } MapFile;

/* "[  N] text" -> N and text; -1 when the line is not one. */
static long file_index(const char *s, const char **rest) {
    char *end;
    long n;
    if (*s != '[') return -1;
    n = strtol(s + 1, &end, 10);
    if (end == s + 1 || *end != ']' || n < 0) return -1;
    *rest = end + 1 + (end[1] == ' ');
    return n;
}

int objc_map_provider_link(ObjcAnalysis *a, const char *final, const char *prestrip, const char *link_map) {
    ObjcImage *fi = NULL, *pi = NULL;
    uint8_t *map = NULL;
    size_t size, i, j;
    MapFile *files = NULL;
    OArchive *ars = NULL;
    size_t nfiles = 0;
    char *line, *save = NULL;
    int rc, arch = 0, part = 0;
    uint64_t sect_seen = 0;
    if ((rc = objc_image_open(a, final, &fi)) || (rc = objc_image_open(a, prestrip, &pi))) goto out;
    if ((rc = same_sections(a, fi, pi))) goto out;
    if ((rc = read_file(a, link_map, LINKMAP_MAX, &map, &size, "link map"))) goto out;
    if (memchr(map, 0, size)) { rc = objc_fail(a, "malformed-link-map", NULL, 0, "%s holds a NUL byte", link_map); goto out; }
    if (!(ars = calloc(a->n_providers + 1, sizeof *ars))) { rc = objc_fail(a, "out-of-memory", NULL, 0, "archives"); goto out; }
    for (i = 0; i < a->n_providers; i++) if ((rc = archive_open(a, a->providers[i].archive, &ars[i]))) goto out;
    for (i = 0; i < a->n_providers; i++) {
        ObjcProvider *p = &a->providers[i];
        p->have_evidence = 1;
        if (objc_set_string(&p->ev_declaration_sha256, p->declaration_sha256) || objc_set_string(&p->ev_archive_sha256, p->archive_sha256))
            { rc = objc_fail(a, "out-of-memory", NULL, 0, "provider"); goto out; }
    }
    for (line = strtok_r((char *)map, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        const char *rest;
        line[strcspn(line, "\r")] = 0;
        if (!strncmp(line, "# Arch: ", 8)) { arch = !strcmp(line + 8, "x86_64") ? 1 : -1; continue; }
        if (!strcmp(line, "# Object files:")) { part = 1; continue; }
        if (!strcmp(line, "# Sections:")) { part = 2; continue; }
        if (!strcmp(line, "# Symbols:")) { part = 3; continue; }
        if (!strncmp(line, "# Dead Stripped Symbols:", 24)) { part = 4; continue; }
        if (*line == '#' || !*line) continue;
        if (part == 1) {
            long n = file_index(line, &rest);
            MapFile *g;
            const char *open;
            size_t len;
            if (n < 0) { rc = objc_fail(a, "malformed-link-map", NULL, 0, "object file line: %.120s", line); goto out; }
            len = strlen(rest);
            if (!len || rest[len - 1] != ')' || !(open = strrchr(rest, '(')) || open == rest) continue;
            if (!(g = realloc(files, (nfiles + 1) * sizeof *g))) { rc = objc_fail(a, "out-of-memory", NULL, 0, "map"); goto out; }
            files = g; g = &files[nfiles];
            if ((size_t)(open - rest) >= sizeof g->path || len - (size_t)(open - rest) - 2 >= sizeof g->member) continue;
            snprintf(g->path, sizeof g->path, "%.*s", (int)(open - rest), rest);
            snprintf(g->member, sizeof g->member, "%.*s", (int)(len - (size_t)(open - rest) - 2), open + 1);
            g->index = n; nfiles++;
        } else if (part == 2) {
            char seg[64], sect[64], name[130];
            unsigned long long addr, sz;
            uint64_t fa, fs;
            uint32_t ff;
            size_t n = objc_image_nsections(pi);
            if (sscanf(line, "%llx %llx %63s %63s", &addr, &sz, seg, sect) != 4) { rc = objc_fail(a, "malformed-link-map", NULL, 0, "section line: %.120s", line); goto out; }
            snprintf(name, sizeof name, "%s,%s", seg, sect);
            for (j = 0; j < n; j++) {
                const char *s = objc_image_section(pi, j, &fa, &fs, &ff);
                if (!strcmp(s, name) && fa == addr && fs == sz) break;
            }
            if (j == n) { rc = objc_fail(a, "link-map-mismatch", NULL, addr, "%s: section %s at 0x%llx is not the prestrip image's", link_map, name, addr); goto out; }
            sect_seen++;
        } else if (part == 3) {
            unsigned long long addr, sz;
            char *end;
            long n;
            const char *name;
            addr = strtoull(line, &end, 16);
            if (end == line) { rc = objc_fail(a, "malformed-link-map", NULL, 0, "symbol line: %.120s", line); goto out; }
            sz = strtoull(end, &end, 16);
            while (*end == ' ' || *end == '\t') end++;
            if ((n = file_index(end, &name)) < 0) { rc = objc_fail(a, "malformed-link-map", NULL, 0, "symbol line: %.120s", line); goto out; }
            for (j = 0; j < nfiles && files[j].index != n; j++) ;
            if (j == nfiles) continue;
            for (i = 0; i < a->n_providers; i++) {
                ObjcProvider *p = &a->providers[i];
                char rp[PATH_MAX];
                OArchive *ar = &ars[i];
                OMember *m;
                uint32_t k;
                if (!realpath(files[j].path, rp) || strcmp(rp, p->archive)) continue;
                if (!(m = member_named(ar, files[j].member))) {
                   
                    rc = objc_fail(a, "link-map-mismatch", NULL, 0, "%s names member %s, which %s lacks", link_map, files[j].member, p->archive);
                    goto out;
                }
                for (k = 0; k < m->nsyms; k++) {
                    uint64_t w;
                    ObjcProviderAtom *g;
                    size_t q;
                    if (!defined(&m->nl[k]) || strcmp(sym_name(m, k), name) || content_of(&m->sects[m->nl[k].n_sect - 1], &w) != C_ATOM) continue;
                    if (!objc_image_has_symbol(pi, name, addr)) {
                       
                        rc = objc_fail(a, "prestrip-mismatch", NULL, addr, "the prestrip image has no %s at 0x%llx, where the link map places %s(%s)", name, addr, files[j].member, name);
                        goto out;
                    }
                    for (q = 0; q < p->n_atoms; q++)
                        if (!strcmp(p->atoms[q].member, m->name) && !strcmp(p->atoms[q].symbol, name)) break;
                    if (q < p->n_atoms) { rc = objc_fail(a, "malformed-link-map", NULL, addr, "%s(%s) placed twice", m->name, name); goto out; }
                    if (!(g = realloc(p->atoms, (p->n_atoms + 1) * sizeof *g))) { rc = objc_fail(a, "out-of-memory", NULL, 0, "atoms"); goto out; }
                    p->atoms = g; g = &p->atoms[p->n_atoms++]; memset(g, 0, sizeof *g);
                    g->address = addr; g->size = sz;
                    if (objc_set_string(&g->member, m->name) || objc_set_string(&g->symbol, name)) { rc = objc_fail(a, "out-of-memory", NULL, 0, "atoms"); goto out; }
                    for (q = 0; q < p->n_members && strcmp(p->members[q].name, m->name); q++) ;
                    if (q == p->n_members) {
                        ObjcProviderMember *mm = realloc(p->members, (p->n_members + 1) * sizeof *mm);
                        if (!mm) { rc = objc_fail(a, "out-of-memory", NULL, 0, "members"); goto out; }
                        p->members = mm; mm = &p->members[p->n_members++]; memset(mm, 0, sizeof *mm);
                        if (objc_set_string(&mm->name, m->name) || objc_set_string(&mm->sha256, m->sha)) { rc = objc_fail(a, "out-of-memory", NULL, 0, "members"); goto out; }
                    }
                    break;
                }
               
            }
        }
    }
    if (arch != 1) { rc = objc_fail(a, "link-map-mismatch", NULL, 0, "%s is not an x86_64 link map", link_map); goto out; }
    if (sect_seen != objc_image_nsections(pi)) { rc = objc_fail(a, "link-map-mismatch", NULL, 0, "%s lists %llu sections, the prestrip image has %zu", link_map, (unsigned long long)sect_seen, objc_image_nsections(pi)); goto out; }
    rc = OBJC_OK;
out:
    if (ars) for (i = 0; i < a->n_providers; i++) archive_free(&ars[i]);
    free(ars); free(files); free(map);
    objc_image_close(fi); objc_image_close(pi);
    return rc ? OBJC_CANNOT_MEASURE : OBJC_OK;
}
