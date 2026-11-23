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
 * Groups (schema 2; legacy entries are checked as above). 1, 2 and 4 hold as for an entry, and 3's
 * constructor is verified the same way, with every member's implementation verified too (a
 * zerofill atom, which has no bytes, only inside a final section that is zerofill as well).
 * Instead of 3's strings, each member must be declared with the newer SDK's encoding and be
 * absent from the 10.9 floor on its class's chain, a superclass the capture lacks counting as
 * present (provider-abi-mismatch, provider-present-on-floor), and
 * the registration is derived from the code: regexec.c runs from the constructor's final
 * address over the verified ranges (its refusal is provider-unmeasurable). Over every path it
 * completes, guessed or trapped ones included: the root is called on some path; no path where a
 * lookup found a member -- or one whose class or selector is unnamed -- calls class_addMethod
 * (provider-guard-violation); every path adds exactly the members (class, kind by metaclass,
 * selector, implementation by final address, types), nothing being a mismatch too, except one
 * where objc_getClass of the group's own class returned NULL, a member's or an unnamed lookup
 * was found, or an add failed -- a found lookup of anything else exempts nothing; no succeeding
 * add anywhere is outside them; and at least one exact path has no guessed branch and no trap
 * (else provider-registration-mismatch). Coverage: no mutator but class_addMethod is called on an
 * explored path (provider-registration-mismatch), and every call of one in the verified code is on an
 * explored path, as is any other use of a mutator's stub, pointer or bound data slot there but a load a
 * path executed, and every class_addMethod call the reader saw there, through a register included
 * (provider-unexplored-mutation). Over the whole image (objc_image_refs: code as the reader walks it,
 * rebased pointers), nothing refers into a function an explored path ran in -- the explored functions --
 * but a branch from one of them, or the constructor's one initializer entry (provider-foreign-entry);
 * nothing refers to image data outside __TEXT the executor read as its initial value but a load, an
 * instruction a path executed, or a pointer in __TEXT; and no value derived from an address of writable
 * image data inside data read as initial values -- a range read, or any atom overlapping one -- reaches code
 * the executor does not follow, is stored outside the frame, or is returned from the constructor or the root
 * (regexec's escaped, by the address each was derived from), and nothing read as an initial value lies in
 * class metadata the runtime writes (__objc_data, __objc_const, __objc_ivar; selector, class and super
 * references it rewrites only to equal values) (provider-mutable-constant). An explored function
 * with an LSDA is provider-unmeasurable (exceptional control flow). A summarised callee is not explored.
 * A group is credited
 * whole or not at all: an active group turns the unsupported findings of each member's selector
 * and kind ("+" being a send to the class object) on a receiver whose floor chain includes its
 * class into `provided`.
 *
 * Every class_addMethod call the reader saw (OBJC_EV_METHOD_REGISTRATION) must lie in provider
 * code verified here, or the artifact is cannot-measure (unattested-method-registration): a
 * root symbol, a provider name or a link-argument list alone attests nothing. With a group
 * declared, the reader records a sel_registerName of a non-literal (OBJC_EV_SEL_COMPUTED)
 * instead of refusing it; it is refused here (computed-selector-producer) unless it lies in a
 * group whose registration verified and the executor reached it with a literal from the image
 * on every arrival -- and by no group once any provider refuses; one in a group's code the
 * executor never reached says so.
 *
 * objc_map_provider_link is the build side: the final and prestrip slices must carry identical
 * sections (strip touches only __LINKEDIT), the link map's Arch and Sections must be this link's,
 * and each atom it places from an archive member must be a symbol the member defines and the
 * prestrip image has at that address. An assembler-local atom (l_, L or ltmp: the linker drops
 * such symbols, so no image has them by name) the prestrip image lacks is instead verified by
 * bytes, by the same walk as the attestation above run on the prestrip image: its bytes at the
 * link-map address equal the member's, every relocated field resolved to what the object meant: a byte or mapping
 * difference refuses prestrip-mismatch, and a relocation that walk cannot resolve keeps its own code
 * (unsupported-provider-relocation). Archives are read by a bounded BSD ar(5) reader
 * (the pinned Drydock's archive module needs its rewrite modules) and objects by a bounded
 * MH_OBJECT reader, both in attest.c. Nothing is executed or loaded. */
#include "report.h"
#include "linkmap.h"
#include "attest.h"
#include "regexec.h"
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

#define DEPTH_MAX 8

/* ---- archives ---------------------------------------------------------------------------------- */

int objc_read_file(ObjcAnalysis *a, const char *path, size_t max, uint8_t **buf, size_t *size, const char *what) {
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

/* The member and symbol index defining external `name`, or -1. */
static int archive_defines(const OArchive *ar, const char *name, size_t *mi, uint32_t *si) {
    size_t i;
    uint32_t k;
    for (i = 0; i < ar->n; i++)
        for (k = 0; k < ar->m[i].nsyms; k++)
            if (objc_obj_defined(&ar->m[i].nl[k]) && (ar->m[i].nl[k].n_type & N_EXT) && !strcmp(objc_obj_sym_name(&ar->m[i], k), name)) {
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
        if (objc_obj_defined(&m->nl[k]) && m->nl[k].n_sect == n->n_sect && m->nl[k].n_value > *lo && m->nl[k].n_value < *hi)
            *hi = m->nl[k].n_value;
}

/* The symbol whose atom covers t in section sect (1-based), or -1. */
static long covering(const OMember *m, uint8_t sect, uint64_t t) {
    long best = -1;
    uint32_t k;
    for (k = 0; k < m->nsyms; k++)
        if (objc_obj_defined(&m->nl[k]) && m->nl[k].n_sect == sect && m->nl[k].n_value <= t &&
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
    const char *mismatch;           /* the code a byte or mapping mismatch is reported as (default provider-mapping-mismatch) */
    const char *atom;               /* the atom being verified at build time, named in what is reported */
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
    if (v->mismatch && !strcmp(code, "provider-mapping-mismatch")) code = v->mismatch;
    if (v->atom) v->status = objc_fail(v->a, code, "x86_64", at, "%s: atom %s: %s", v->p->provider_id, v->atom, msg);
    else v->status = objc_fail(v->a, code, "x86_64", at, "%s: %s", v->p->provider_id, msg);
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
    const char *name = objc_obj_sym_name(m, si);
    const ObjcProviderAtom *e = evidence_atom(v->p, m->name, name);
    if (!e) return vfail(v, "provider-mapping-mismatch", at, "the evidence places no atom %s(%s)", m->name, name);
    if (T != e->address + off)
        return vfail(v, "provider-mapping-mismatch", at, "reference to %s(%s)+%llu reaches 0x%llx, not 0x%llx", m->name, name,
                     (unsigned long long)off, (unsigned long long)T, (unsigned long long)(e->address + off));
    if (v->p->legacy && !strcmp(name + (*name == '_'), v->p->impl_symbol)) fact(v, "atom", name);
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
                name = objc_obj_sym_name(m, r.r_symbolnum);
                if (objc_obj_defined(&m->nl[r.r_symbolnum]) || !archive_defines(v->ar, name, &mi2, &si2)) {
                    const ObjcProviderAtom *e;
                    if (objc_obj_defined(&m->nl[r.r_symbolnum])) { mi2 = mi; si2 = r.r_symbolnum; }
                    if (!(e = evidence_atom(v->p, v->ar->m[mi2].name, objc_obj_sym_name(&v->ar->m[mi2], si2)))) {
                        vfail(v, "provider-mapping-mismatch", at, "the evidence places no atom %s(%s)", v->ar->m[mi2].name, name); break;
                    }
                    if (T == e->address && r.r_type == X86_64_RELOC_GOT_LOAD && field >= 2 && ob[field - 2] == 0x8b && fb[field - 2] == 0x8d)
                        mask[field - 2] = 1;   /* movq sym@GOTPCREL -> leaq sym: the target itself */
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
                name = objc_obj_sym_name(m, r.r_symbolnum);
                if (objc_obj_defined(&m->nl[r.r_symbolnum])) {
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
                name = objc_obj_sym_name(m, r.r_symbolnum);
                if (objc_obj_defined(&m->nl[r.r_symbolnum])) obj_target(v, mi, m->nl[r.r_symbolnum].n_sect, m->nl[r.r_symbolnum].n_value + c, val, at, depth);
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
        if (!mask[i] && ob[i] != fb[i])
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

static int zerofill(uint32_t flags) {
    uint32_t t = flags & SECTION_TYPE;
    return t == S_ZEROFILL || t == S_GB_ZEROFILL || t == S_THREAD_LOCAL_ZEROFILL;
}
static int drain(V *v) {
    while (v->next < v->nwork && !v->status) {
        Ref r = v->work[v->next++];
        const OMember *m = &v->ar->m[r.m];
        const char *name = objc_obj_sym_name(m, r.s);
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
        if (!v->p->legacy && zerofill(x->flags)) {   /* no bytes on either side: the final section must be zerofill too */
            uint64_t fa = 0, fz = 0;
            uint32_t ff = 0;
            objc_image_section_of(v->im, e->address, &fa, &fz, &ff);
            if (!zerofill(ff) || e->address + e->size > fa + fz) return vfail(v, "provider-mapping-mismatch", e->address, "%s(%s) is zerofill, its final section is not", m->name, name);
            if (add_range(v, e->address, e->address + e->size)) return -1;
        } else if (compare_region(v, r.m, x, lo, hi, e->address, 0) || add_range(v, e->address, e->address + e->size)) return -1;
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
            if (r.r_symbolnum >= c->m->nsyms || !objc_obj_defined(&c->m->nl[r.r_symbolnum])) return -1;
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
        OMember *m = objc_archive_member(ar, p->members[i].name);
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
            if (w->end || s < 0 || !(at = evidence_atom(p, m->name, objc_obj_sym_name(m, (uint32_t)s)))) continue;
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

/* ---- schema-2 groups ------------------------------------------------------------------------------ */

/* The class on floor class cls's runtime chain that answers kind/sel (a root's instance methods answer class
 * messages), or the first chain class the floor capture did not measure (*unmeasured 1), or NULL. */
static const char *floor_answers(const ObjcAnalysis *a, const char *cls, const char *kind, const char *sel, int *unmeasured) {
    int depth;
    *unmeasured = 0;
    for (depth = 0; cls && depth < 64; depth++) {
        const char *i = objc_map_get(a->rt_class, cls), *role;
        const ObjcRtClass *c;
        char key[1024];
        if (!i && depth) { *unmeasured = 1; return cls; }   /* a superclass the capture lacks: it may answer */
        if (!i) return NULL;                                /* the class itself: 4 finds it no floor class */
        c = &a->rt_classes[strtoul(i, NULL, 10)];
        role = objc_map_get(a->rt_image_role, c->image);
        if (!role || (strcmp(role, "required") && strcmp(role, "fixture"))) { *unmeasured = 1; return c->name; }
        snprintf(key, sizeof key, "%s\t%s\t%s", c->name, kind, sel);
        if (objc_map_get(a->rt_method, key)) return c->name;
        snprintf(key, sizeof key, "%s\t-\t%s", c->name, sel);
        if (!c->super && !strcmp(kind, "+") && objc_map_get(a->rt_method, key)) return c->name;
        cls = c->super;
    }
    return NULL;
}

/* Every member declared with the newer SDK's encoding and absent from the 10.9 floor. */
static int group_declared(ObjcAnalysis *a, const ObjcProvider *p) {
    size_t i;
    for (i = 0; i < p->n_methods; i++) {
        const ObjcProviderMethod *m = &p->methods[i];
        char key[1024];
        const char *enc, *owner;
        int unmeasured;
        snprintf(key, sizeof key, "%s\t%s\t%s", p->cls, m->kind, m->selector);
        if (!(enc = a->nw_encoding ? objc_map_get(a->nw_encoding, key) : NULL) || strcmp(enc, m->encoding))
            return objc_fail(a, "provider-abi-mismatch", NULL, 0, "%s: declared %s%s %s as %s; the newer SDK %s%s", p->provider_id, m->kind,
                             p->cls, m->selector, m->encoding, enc ? "declares " : "does not declare it", enc ? enc : "");
        if ((owner = floor_answers(a, p->cls, m->kind, m->selector, &unmeasured)))
            return objc_fail(a, "provider-present-on-floor", NULL, 0, "%s: %s[%s %s] %s %s", p->provider_id, m->kind, p->cls, m->selector,
                             unmeasured ? "may be present on 10.9: the floor capture does not measure" : "is present on 10.9, answered by", owner);
    }
    return OBJC_OK;
}

static void say(char *buf, size_t n, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void say(char *buf, size_t n, const char *fmt, ...) {
    size_t l = strlen(buf);
    va_list ap;
    if (l + 3 >= n) return;
    if (l) { strcpy(buf + l, "; "); l += 2; }
    va_start(ap, fmt); vsnprintf(buf + l, n - l, fmt, ap); va_end(ap);
}
static const char *nz(const char *s) { return s ? s : "?"; }
static int add_names(const ObjcRegAdd *d, const ObjcProvider *p, const ObjcProviderMethod *m) {
    return d->cls && d->sel && !strcmp(d->cls, p->cls) && d->meta == (m->kind[0] == '+') && !strcmp(d->sel, m->selector);
}
/* Whether add d registers member m exactly (impva: the final address of m's implementation). */
static int add_is(const ObjcRegAdd *d, const ObjcProvider *p, const ObjcProviderMethod *m, uint64_t impva) {
    return add_names(d, p, m) && d->imp_va == impva && d->types && !strcmp(d->types, m->encoding);
}
/* A found lookup that may be a member's: one of p's class, kind and a member's selector, or one whose class or
 * selector the executor could not name. */
static int lookup_declared(const ObjcRegLookup *l, const ObjcProvider *p) {
    size_t i;
    if (!l->cls || !l->sel) return 1;
    for (i = 0; i < p->n_methods; i++)
        if (!strcmp(l->cls, p->cls) && l->meta == (p->methods[i].kind[0] == '+') && !strcmp(l->sel, p->methods[i].selector)) return 1;
    return 0;
}
static const char *imp_text(const ObjcRegAdd *d, char *buf, size_t n) {
    if (d->imp) return d->imp;
    snprintf(buf, n, d->imp_va ? "0x%llx" : "?", (unsigned long long)d->imp_va);
    return buf;
}

/* The verdict on a group's derived registration (the header's "Groups"): the root reached; (a) no add on a path
 * where a member's lookup was found; (b) every path adds exactly the members, except one where objc_getClass of the
 * group's class returned NULL, a member's (or an unnamed) lookup was found, or an add failed; (c) no succeeding add
 * anywhere outside them; (d) some path of (b) has no guess. impva[i]: member i's implementation's final address.
 * *clean: the paths of (d). */
static int group_verdict(ObjcAnalysis *a, const ObjcProvider *p, const ObjcRegResult *r, uint64_t root, const uint64_t *impva,
                         size_t *clean) {
    size_t i, j, k, l;
    char buf[2048], ib[32];
    *clean = 0;
    for (i = 0; i < r->n_called && r->called[i] != root; i++) ;
    if (i == r->n_called)
        return objc_fail(a, "provider-registration-mismatch", NULL, 0, "%s: the constructor never reaches %s", p->provider_id, p->root_symbol);
    for (i = 0; i < r->n_paths; i++) {
        const ObjcRegPath *q = &r->paths[i];
        int guarded = 0;
        for (j = 0; j < q->n_found; j++) guarded |= lookup_declared(&q->found[j], p);
        if (!guarded || !q->n_adds) continue;
        buf[0] = 0;
        for (j = 0; j < q->n_found; j++) say(buf, sizeof buf, "%s[%s %s]", q->found[j].meta ? "+" : "-", nz(q->found[j].cls), nz(q->found[j].sel));
        return objc_fail(a, "provider-guard-violation", NULL, 0, "%s: path %zu calls class_addMethod %zu times after these lookups were found: %s",
                         p->provider_id, i, q->n_adds, buf);
    }
    for (i = 0; i < r->n_paths; i++) {
        const ObjcRegPath *q = &r->paths[i];
        int exempt = 0;
        for (j = 0; j < q->n_null_classes && !exempt; j++) exempt = q->null_classes[j] && !strcmp(q->null_classes[j], p->cls);
        for (j = 0; j < q->n_found && !exempt; j++) exempt = lookup_declared(&q->found[j], p);
        for (j = 0; j < q->n_adds && !exempt; j++) exempt = !q->adds[j].ok;
        if (exempt) continue;
        buf[0] = 0;
        for (k = 0; k < p->n_methods; k++) {
            const ObjcProviderMethod *m = &p->methods[k];
            const ObjcRegAdd *h = NULL;
            for (j = 0; j < q->n_adds && !h; j++) if (add_names(&q->adds[j], p, m)) h = &q->adds[j];
            if (!h) { say(buf, sizeof buf, "missing %s[%s %s]", m->kind, p->cls, m->selector); continue; }
            if (h->imp_va != impva[k])
                say(buf, sizeof buf, "%s[%s %s] implemented by %s, declared _%s", m->kind, p->cls, m->selector, imp_text(h, ib, sizeof ib), m->impl_symbol);
            if (!h->types || strcmp(h->types, m->encoding))
                say(buf, sizeof buf, "%s[%s %s] typed %s, declared %s", m->kind, p->cls, m->selector, nz(h->types), m->encoding);
        }
        for (j = 0; j < q->n_adds; j++) {
            const ObjcRegAdd *d = &q->adds[j];
            for (k = 0; k < p->n_methods && !add_names(d, p, &p->methods[k]); k++) ;
            for (l = 0; l < j && k < p->n_methods && !add_names(&q->adds[l], p, &p->methods[k]); l++) ;
            if (k == p->n_methods || l < j) say(buf, sizeof buf, "extra %s[%s %s]", d->meta ? "+" : "-", nz(d->cls), nz(d->sel));
        }
        if (buf[0])
            return objc_fail(a, "provider-registration-mismatch", NULL, 0, "%s: path %zu registers other than the declaration: %s", p->provider_id, i, buf);
        if (!q->unknown_forks && !q->trapped) (*clean)++;
    }
    for (i = 0; i < r->n_paths; i++)
        for (j = 0; j < r->paths[i].n_adds; j++) {
            const ObjcRegAdd *d = &r->paths[i].adds[j];
            if (!d->ok) continue;   /* nothing added; its succeeding fork is a path of its own */
            for (k = 0; k < p->n_methods && !add_is(d, p, &p->methods[k], impva[k]); k++) ;
            if (k == p->n_methods)
                return objc_fail(a, "provider-registration-mismatch", NULL, 0, "%s: path %zu adds %s[%s %s] (%s, %s), which the group does not declare",
                                 p->provider_id, i, d->meta ? "+" : "-", nz(d->cls), nz(d->sel), imp_text(d, ib, sizeof ib), nz(d->types));
        }
    if (!*clean) return objc_fail(a, "provider-registration-mismatch", NULL, 0, "%s: no path registers the group without a guess", p->provider_id);
    return OBJC_OK;
}

/* ---- a group's coverage: what the executor did not explore must not change what it derived ---------------------- */

typedef struct {
    ObjcAnalysis *a;
    const ObjcProvider *p;
    const ObjcImage *im;
    const ObjcRegResult *r;
    uint64_t *c; size_t nc;    /* [lo, hi): image data outside __TEXT the executor read as initial values, merged */
    uint64_t *m; size_t nm;    /* [lo, lo+1): each stub, pointer slot or bound data slot of a mutator import */
    int inits;                 /* initializer slots holding the constructor */
    int status;
} Sweep;

static int in_pairs(const uint64_t *r, size_t n, uint64_t a) {
    size_t i;
    for (i = 0; i < n; i++) if (a >= r[2 * i] && a < r[2 * i + 1]) return 1;
    return 0;
}
static int pair_cmp(const void *x, const void *y) {
    uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y;
    return a < b ? -1 : a > b;
}
static int push_pair(uint64_t **v, size_t *n, uint64_t lo, uint64_t hi) {
    uint64_t *g = realloc(*v, (*n + 1) * 2 * sizeof *g);
    if (!g) return -1;
    *v = g; g[2 * *n] = lo; g[2 * *n + 1] = hi; (*n)++;
    return 0;
}
/* Where va is, for a message: the function holding it (LC_FUNCTION_STARTS) by its symbol, else its section. */
static const char *where(const ObjcImage *im, uint64_t va, char *buf, size_t n) {
    size_t lo = 0, hi = objc_image_nfunctions(im);
    uint32_t fl = 0;
    const char *s = objc_image_section_of(im, va, NULL, NULL, &fl), *name = NULL;
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (objc_image_function(im, mid) <= va) lo = mid + 1; else hi = mid; }
    if (lo && s && (fl & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))) name = objc_image_symbol_at(im, objc_image_function(im, lo - 1));
    snprintf(buf, n, "%s", name ? name : s ? s : "no section");
    return buf;
}
static int executed(const ObjcRegResult *r, uint64_t ip) {
    size_t lo = 0, hi = r->n_executed;
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (r->executed[mid] < ip) lo = mid + 1; else hi = mid; }
    return lo < r->n_executed && r->executed[lo] == ip;
}
static const char *const REF_KIND[] = { "branches to", "reads", "takes the address of", "writes or uses", "points to", "may encode" };

static int sweep_ref(void *ctx, uint64_t site, uint64_t target, int kind) {
    Sweep *w = ctx;
    const ObjcRegResult *r = w->r;
    int in_e = in_pairs(r->explored, r->n_explored, site), ran = executed(r, site);
    uint32_t fl = 0;
    const char *sn = objc_image_section_of(w->im, site, NULL, NULL, &fl);
    char wb[300], tb[300];
    size_t i;
    if (in_pairs(w->m, w->nm, target) && in_pairs(w->p->ranges, w->p->n_ranges, site)) {
        const char *imp = objc_image_import_at(w->im, target);
        if (!imp) imp = objc_image_bound_at(w->im, target);
        for (i = 0; kind == OBJC_REF_BRANCH && i < r->n_sites && r->mutator_sites[i] != site; i++) ;
        if (kind == OBJC_REF_BRANCH ? i == r->n_sites : !(kind == OBJC_REF_LOAD && ran))
            return w->status = objc_fail(w->a, "provider-unexplored-mutation", NULL, site,
                                         "%s: %s at 0x%llx (in %s), in the group's verified code, is on no path the executor explored",
                                         w->p->provider_id, imp ? imp + (imp[0] == '_') : "a mutator", (unsigned long long)site,
                                         where(w->im, site, wb, sizeof wb));
    }
    if (in_pairs(r->explored, r->n_explored, target) && !(in_e && kind == OBJC_REF_BRANCH) &&
        !(kind == OBJC_REF_POINTER && (fl & SECTION_TYPE) == S_MOD_INIT_FUNC_POINTERS && target == w->p->constructor && w->inits == 1))
        return w->status = objc_fail(w->a, "provider-foreign-entry", NULL, site,
                                     "%s: 0x%llx (in %s) %s 0x%llx (in %s), code the executor explored, from code or data it did not",
                                     w->p->provider_id, (unsigned long long)site, where(w->im, site, wb, sizeof wb), REF_KIND[kind],
                                     (unsigned long long)target, where(w->im, target, tb, sizeof tb));
    if (in_pairs(w->c, w->nc, target) && kind != OBJC_REF_LOAD && !ran &&
        !(kind == OBJC_REF_POINTER && sn && !strncmp(sn, "__TEXT,", 7) && !(fl & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))))
        return w->status = objc_fail(w->a, "provider-mutable-constant", NULL, site,
                                     "%s: 0x%llx (in %s) %s 0x%llx (in %s), which the executor read as its initial value",
                                     w->p->provider_id, (unsigned long long)site, where(w->im, site, wb, sizeof wb), REF_KIND[kind],
                                     (unsigned long long)target, where(w->im, target, tb, sizeof tb));
    return 0;
}

/* The header's "Coverage": no mutator but class_addMethod on an explored path; every mutator call in the verified code
 * on one; and, over the whole image, no reference into an explored function from outside the explored functions but
 * the constructor's initializer entry, and none to data read as a constant but a load, one from an explored function,
 * or a pointer in such data or in __TEXT. */
static int group_covered(ObjcAnalysis *a, const ObjcProvider *p, const ObjcImage *im, const ObjcRegResult *r) {
    Sweep w;
    uint64_t *all = NULL;
    size_t i, j, k, nall = 0, ns = objc_image_nsections(im);
    int rc = 0;
    char wb[300];
    for (i = 0; i < r->n_sites; i++) {
        int add = 0;
        for (j = 0; j < r->n_paths && !add; j++)
            for (k = 0; k < r->paths[j].n_adds && !add; k++) add = r->paths[j].adds[k].site == r->mutator_sites[i];
        if (!add)
            return objc_fail(a, "provider-registration-mismatch", NULL, r->mutator_sites[i], "%s: a run-time mutator other than class_addMethod is called at 0x%llx (in %s), on an explored path",
                             p->provider_id, (unsigned long long)r->mutator_sites[i], where(im, r->mutator_sites[i], wb, sizeof wb));
    }
    memset(&w, 0, sizeof w);
    w.a = a; w.p = p; w.im = im; w.r = r;
    for (i = 0; i < r->n_reads; i++) {
        const char *sn = objc_image_section_of(im, r->const_reads[i].va, NULL, NULL, NULL);
        if (sn && strncmp(sn, "__TEXT,", 7) && push_pair(&w.c, &w.nc, r->const_reads[i].va, r->const_reads[i].va + r->const_reads[i].len)) goto oom;
    }
    if (w.nc) qsort(w.c, w.nc, 2 * sizeof *w.c, pair_cmp);
    for (i = 1, j = 0; i < w.nc; i++)
        if (w.c[2 * i] <= w.c[2 * j + 1]) { if (w.c[2 * i + 1] > w.c[2 * j + 1]) w.c[2 * j + 1] = w.c[2 * i + 1]; }
        else { j++; w.c[2 * j] = w.c[2 * i]; w.c[2 * j + 1] = w.c[2 * i + 1]; }
    if (w.nc) w.nc = j + 1;
    {
        uint64_t f = 0;
        int l = objc_image_lsda(im, r->explored, r->n_explored, &f);
        if (l)
            rc = l < 0 ? objc_fail(a, "provider-unmeasurable", NULL, 0, "%s: exceptional control flow: the unwind tables do not read", p->provider_id)
                       : objc_fail(a, "provider-unmeasurable", NULL, f, "%s: exceptional control flow: %s at 0x%llx, a function the executor explored, has an LSDA",
                                   p->provider_id, where(im, f, wb, sizeof wb), (unsigned long long)f);
        if (l) goto out;
    }
    for (i = 0; i < r->n_reads; i++) {
        static const char *const META[] = { "__objc_data", "__objc_const", "__objc_ivar" };
        const char *sn = objc_image_section_of(im, r->const_reads[i].va, NULL, NULL, NULL), *c = sn ? strchr(sn, ',') : NULL;
        for (j = 0; c && j < sizeof META / sizeof *META; j++)
            if (!strcmp(c + 1, META[j])) {
                rc = objc_fail(a, "provider-mutable-constant", NULL, r->const_reads[i].site,
                               "%s: 0x%llx (in %s), read at 0x%llx as its initial value, is Objective-C runtime metadata, never a constant",
                               p->provider_id, (unsigned long long)r->const_reads[i].va, where(im, r->const_reads[i].va, wb, sizeof wb),
                               (unsigned long long)r->const_reads[i].site);
                goto out;
            }
    }
    for (i = 0; i < r->n_escaped; i++) {
        static const char *const HOW[] = { "is passed to code it does not follow", "is stored outside the frame", "is returned from the root" };
        uint64_t b = r->escaped[i].va;
        int hit = b == ~0ULL && w.nc;   /* derived from more addresses than regexec tracks */
        for (j = 0; j < w.nc && !hit; j++) {
            hit = b >= w.c[2 * j] && b < w.c[2 * j + 1];
            for (k = 0; k < p->n_atoms && !hit; k++) {
                uint64_t lo = p->atoms[k].address, hi = lo + p->atoms[k].size;
                hit = lo < w.c[2 * j + 1] && w.c[2 * j] < hi && b >= lo && b < hi;
            }
        }
        if (hit) {
            char tb[300];
            rc = objc_fail(a, "provider-mutable-constant", NULL, r->escaped[i].site,
                           "%s: a value derived from 0x%llx (in %s), data the executor read as initial values, %s at 0x%llx (in %s)",
                           p->provider_id, (unsigned long long)b, where(im, b, tb, sizeof tb),
                           r->escaped[i].how >= 0 && r->escaped[i].how < 3 ? HOW[r->escaped[i].how] : "escapes",
                           (unsigned long long)r->escaped[i].site, where(im, r->escaped[i].site, wb, sizeof wb));
            goto out;
        }
    }
    for (i = 0; i < objc_image_nbinds(im); i++) {
        uint64_t va = 0;
        if (objc_reg_mutator(objc_image_bind(im, i, &va)) && push_pair(&w.m, &w.nm, va, va + 1)) goto oom;
    }
    for (i = 0; i < ns; i++) {
        uint64_t addr, size, va;
        uint32_t fl, t;
        objc_image_section(im, i, &addr, &size, &fl);
        t = fl & SECTION_TYPE;
        if (t == S_MOD_INIT_FUNC_POINTERS)
            for (va = addr; va + 8 <= addr + size; va += 8) {
                const uint8_t *b = objc_image_bytes(im, va, 8);
                w.inits += b && rd64(b) == p->constructor;
            }
        if (t != S_SYMBOL_STUBS && t != S_NON_LAZY_SYMBOL_POINTERS && t != S_LAZY_SYMBOL_POINTERS) continue;
        for (va = addr; va < addr + size; va++)
            if (objc_reg_mutator(objc_image_import_at(im, va)) && push_pair(&w.m, &w.nm, va, va + 1)) goto oom;
    }
    for (i = 0; i < r->n_explored; i++) if (push_pair(&all, &nall, r->explored[2 * i], r->explored[2 * i + 1])) goto oom;
    for (i = 0; i < w.nc; i++) if (push_pair(&all, &nall, w.c[2 * i], w.c[2 * i + 1])) goto oom;
    for (i = 0; i < w.nm; i++) if (push_pair(&all, &nall, w.m[2 * i], w.m[2 * i + 1])) goto oom;
    rc = objc_image_refs(im, all, nall, sweep_ref, &w);
    if (rc < 0) rc = objc_fail(a, "unsupported-provider", NULL, 0, "%s: the image is not position-independent: references by absolute address are not swept", p->provider_id);
out:
    free(all); free(w.c); free(w.m);
    return rc ? OBJC_CANNOT_MEASURE : OBJC_OK;
oom:
    free(all); free(w.c); free(w.m);
    return objc_fail(a, "out-of-memory", NULL, 0, "provider sweep");
}

/* A group's registration, derived from its constructor over its verified code; what it found, for the reason. */
static int group_derived(ObjcAnalysis *a, ObjcProvider *p, ObjcImage *im, const OArchive *ar, const char *rootm, char *what, size_t n) {
    ObjcRegResult r;
    uint64_t *impva, root;
    const ObjcProviderAtom *e;
    size_t i, mi, clean = 0, nulls = 0;
    uint32_t si;
    char sym[300];
    int rc = OBJC_OK;
    snprintf(sym, sizeof sym, "_%s", p->root_symbol);
    if (!(e = evidence_atom(p, rootm, sym))) return objc_fail(a, "provider-mapping-mismatch", NULL, 0, "%s: the evidence places no %s", p->provider_id, sym);
    root = e->address;
    if (!(impva = calloc(p->n_methods, sizeof *impva))) return objc_fail(a, "out-of-memory", NULL, 0, "provider");
    for (i = 0; i < p->n_methods; i++) {
        snprintf(sym, sizeof sym, "_%s", p->methods[i].impl_symbol);
        if (archive_defines(ar, sym, &mi, &si) || !(e = evidence_atom(p, ar->m[mi].name, sym))) {
            free(impva);
            return objc_fail(a, "provider-mapping-mismatch", NULL, 0, "%s: the evidence places no %s", p->provider_id, sym);
        }
        impva[i] = e->address;
    }
    if (objc_derive_registration(im, p->constructor, p->ranges, p->n_ranges, NULL, &r))
        rc = objc_fail(a, "provider-unmeasurable", NULL, 0, "%s: %s: %s", p->provider_id, r.code, r.why);
    else rc = group_verdict(a, p, &r, root, impva, &clean);
    if (!rc) rc = group_covered(a, p, im, &r);
    if (!rc && r.n_selreg && (!(p->literal_sel_sites = calloc(r.n_selreg, sizeof *p->literal_sel_sites)) ||
                              !(p->sel_sites = calloc(r.n_selreg, sizeof *p->sel_sites))))
        rc = objc_fail(a, "out-of-memory", NULL, 0, "provider");
    if (!rc && r.n_sites) {
        if (!(p->mutator_sites = malloc(r.n_sites * sizeof *p->mutator_sites))) rc = objc_fail(a, "out-of-memory", NULL, 0, "provider");
        else { memcpy(p->mutator_sites, r.mutator_sites, r.n_sites * sizeof *p->mutator_sites); p->n_mutator_sites = r.n_sites; }
    }
    for (i = 0; !rc && i < r.n_selreg; i++) {
        p->sel_sites[p->n_sel_sites++] = r.selreg[i].site;
        if (r.selreg[i].all_literal) p->literal_sel_sites[p->n_literal_sel_sites++] = r.selreg[i].site;
    }
    for (i = 0; i < r.n_paths; i++) nulls += r.paths[i].class_null != 0;
    snprintf(what, n, "%zu paths from the constructor, %zu registering without a guess, %zu with objc_getClass NULL", r.n_paths, clean, nulls);
    objc_reg_free(&r);
    free(impva);
    return rc;
}

static int verify_one(ObjcAnalysis *a, ObjcProvider *p, ObjcImage *im) {
    OArchive ar;
    V v;
    size_t rm, i;
    uint32_t rs, k;
    const OMember *m;
    const OSect *init = NULL;
    char root[300], impl[300], key[1024], fws[2048] = "", rootm[256], needwhy[1400] = "", derived[256] = "";
    const char *enc;
    int rc;
    if (!p->have_evidence) return set_reason(a, p, 0, "no build evidence names this provider");
    if (strcmp(p->ev_declaration_sha256, p->declaration_sha256))
        return objc_fail(a, "stale-provider-evidence", NULL, 0, "%s: the declaration is %s, the build evidence recorded %s", p->provider_id, p->declaration_sha256, p->ev_declaration_sha256);
    if (strcmp(p->ev_archive_sha256, p->archive_sha256))
        return objc_fail(a, "stale-provider-evidence", NULL, 0, "%s: the archive is %s, the build evidence recorded %s", p->provider_id, p->archive_sha256, p->ev_archive_sha256);
    if (!p->legacy) { if ((rc = group_declared(a, p))) return rc; }
    else {
        if (strcmp(p->method_kind, "-"))
            return objc_fail(a, "unsupported-provider", NULL, 0, "%s: only instance-method providers registered on objc_getClass's class are supported", p->provider_id);
        snprintf(key, sizeof key, "%s\t%s\t%s", p->cls, p->method_kind, p->selector);
        if (!(enc = a->nw_encoding ? objc_map_get(a->nw_encoding, key) : NULL) || strcmp(enc, p->encoding))
            return objc_fail(a, "provider-abi-mismatch", NULL, 0, "%s: declared %s%s %s as %s; the newer SDK %s%s", p->provider_id, p->method_kind,
                             p->cls, p->selector, p->encoding, enc ? "declares " : "does not declare it", enc ? enc : "");
    }
    if ((rc = objc_archive_open(a, p->archive, &ar))) { objc_archive_free(&ar); return rc; }
    for (i = 0; i < p->n_members; i++) {
        const OMember *g = objc_archive_member(&ar, p->members[i].name);
        if (!g || strcmp(g->sha, p->members[i].sha256)) {
            objc_archive_free(&ar);
            return objc_fail(a, "stale-provider-evidence", NULL, 0, "%s: archive member %s is not the one the evidence recorded", p->provider_id, p->members[i].name);
        }
    }
    snprintf(root, sizeof root, "_%s", p->root_symbol);
    for (i = 0; i < (p->legacy ? 1 : p->n_methods); i++) {
        size_t mi;
        snprintf(impl, sizeof impl, "_%s", p->legacy ? p->impl_symbol : p->methods[i].impl_symbol);
        if (archive_defines(&ar, root, &rm, &rs) || archive_defines(&ar, impl, &mi, &k)) {
            objc_archive_free(&ar);
            return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: the archive does not define both %s and %s", p->provider_id, root, impl);
        }
    }
    m = &ar.m[rm];
    snprintf(rootm, sizeof rootm, "%s", m->name);
    for (i = 0; i < p->n_members && strcmp(p->members[i].name, m->name); i++) ;
    if (i == p->n_members) { objc_archive_free(&ar); return set_reason(a, p, 0, "the activation root's member %s is not in the link", rootm); }
    for (k = 0; k < m->nsects; k++) if ((m->sects[k].flags & SECTION_TYPE) == S_MOD_INIT_FUNC_POINTERS) init = &m->sects[k];
    if (!init || !init->nreloc) { objc_archive_free(&ar); return objc_fail(a, "unsupported-provider", NULL, 0, "%s: member %s has no constructor", p->provider_id, rootm); }

    memset(&v, 0, sizeof v);
    v.a = a; v.p = p; v.ar = &ar; v.im = im; v.collecting = 1;
    /* The constructor's closure first: only what it reaches counts as the registration path. */
    for (k = 0; k < init->nreloc && !v.status; k++) {
        struct relocation_info r;
        long s;
        memcpy(&r, m->buf + init->reloff + (size_t)k * 8, 8);
        if (r.r_type != X86_64_RELOC_UNSIGNED || r.r_length != 3 || r.r_pcrel) { vfail(&v, "unsupported-provider", 0, "constructor entry shape"); break; }
        if (r.r_extern) s = r.r_symbolnum < m->nsyms && objc_obj_defined(&m->nl[r.r_symbolnum]) ? (long)r.r_symbolnum : -1;
        else {
            uint64_t t = rd64(m->buf + init->off + (uint32_t)r.r_address);
            s = covering(m, (uint8_t)r.r_symbolnum, t);
            if (s >= 0 && m->nl[s].n_value != t) s = -1;
        }
        if (s < 0) { vfail(&v, "unsupported-provider", 0, "constructor entry names no function of %s", m->name); break; }
        if (!p->constructor) {
            const ObjcProviderAtom *e = evidence_atom(p, m->name, objc_obj_sym_name(m, (uint32_t)s));
            if (!e) { vfail(&v, "provider-mapping-mismatch", 0, "the evidence places no constructor %s(%s)", m->name, objc_obj_sym_name(m, (uint32_t)s)); break; }
            p->constructor = e->address;
        }
        enqueue(&v, rm, (uint32_t)s);
    }
    if (!v.status) drain(&v);
    v.collecting = 0;
    if (!v.status && !enqueue(&v, rm, rs)) drain(&v);
    for (i = 0; i < p->n_methods && !v.status; i++) {   /* a group's implementations, verified wherever they are */
        size_t mi;
        snprintf(impl, sizeof impl, "_%s", p->methods[i].impl_symbol);
        if (!archive_defines(&ar, impl, &mi, &k) && !enqueue(&v, mi, k)) drain(&v);
    }
    rc = v.status;
    if (!rc && !p->legacy) rc = group_derived(a, p, im, &ar, rootm, derived, sizeof derived);
    else if (!rc) {
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
    free(v.facts); free(v.binds); free(v.work); objc_archive_free(&ar);
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
    if (!p->legacy)
        return set_reason(a, p, 1, "archive sha256 %.12s..., member %s: constructor at 0x%llx in the initializer table, %zu atoms "
                          "byte-verified, registers its %zu methods on %s (%s); %s strongly loaded", p->archive_sha256, rootm,
                          (unsigned long long)p->constructor, p->verified, p->n_methods, p->cls, derived, fws);
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
    int rc = OBJC_OK;
    if (a->n_providers && (rc = objc_image_open(a, a->artifact_path, &im))) return rc;
    for (i = 0; i < a->n_providers && !rc; i++) rc = verify_one(a, &a->providers[i], im);
    objc_image_close(im);
    for (i = 0; i < a->n_evidence; i++) {   /* after a refusal, only the deferred selector producers: the reader's own */
        const ObjcEvidence *e = &a->evidence[i];
        int ok = 0;
        if (rc && e->kind != OBJC_EV_SEL_COMPUTED) continue;
        if (e->kind == OBJC_EV_SEL_COMPUTED) {
            const ObjcProvider *in = NULL;
            int reached = 0;
            for (j = 0; !rc && j < a->n_providers && !ok; j++) {   /* after a refusal, nothing is explained */
                const ObjcProvider *p = &a->providers[j];
                int inside = 0;
                for (k = 0; k < p->n_ranges && !inside; k++) inside = e->address >= p->ranges[2 * k] && e->address < p->ranges[2 * k + 1];
                for (k = 0; inside && k < p->n_literal_sel_sites && !ok; k++) ok = p->literal_sel_sites[k] == e->address;
                if (inside && !p->legacy && p->active) in = p;
                for (k = 0; inside && k < p->n_sel_sites; k++) reached |= p->sel_sites[k] == e->address;
            }
            if (ok) continue;
            if (in && !reached)
                objc_fail(a, "computed-selector-producer", e->slice, e->address, "%s argument is not a recognised literal: in %s's code, on no path the executor explored",
                          e->name, in->provider_id);
            else objc_fail(a, "computed-selector-producer", e->slice, e->address, "%s argument is not a recognised literal", e->name);
            continue;
        }
        if (e->kind != OBJC_EV_METHOD_REGISTRATION) continue;
        {
            const ObjcProvider *g = NULL;
            for (j = 0; j < a->n_providers && !ok; j++) {
                const ObjcProvider *p = &a->providers[j];
                int inside = 0;
                for (k = 0; k < p->n_ranges && !inside; k++) inside = e->address >= p->ranges[2 * k] && e->address < p->ranges[2 * k + 1];
                if (!inside) continue;
                if (p->legacy) { ok = 1; continue; }
                for (k = 0; k < p->n_mutator_sites && !ok; k++) ok = p->mutator_sites[k] == e->address;
                if (!ok) g = p;
            }
            if (!ok && g) {
                objc_fail(a, "provider-unexplored-mutation", e->slice, e->address, "%s: %s at 0x%llx (in %s), in the group's verified code, is on no path the executor explored",
                          g->provider_id, e->name, (unsigned long long)e->address, e->function ? e->function : "an unnamed function");
                continue;
            }
        }
        if (!ok) objc_fail(a, "unattested-method-registration", e->slice, e->address,
                           "%s in %s lies outside every provider this analysis verified; a run-time method registration is not modelled",
                           e->name, e->function ? e->function : "an unnamed function");
    }
    return rc ? rc : a->n_errors ? OBJC_CANNOT_MEASURE : OBJC_OK;
}

int objc_provide_findings(ObjcAnalysis *a) {
    size_t i, j;
    for (i = 0; i < a->n_findings; i++) {
        ObjcFinding *f = &a->findings[i];
        const ObjcSend *s = &a->sends[f->send];
        for (j = 0; j < a->n_providers; j++) {
            const ObjcProvider *p = &a->providers[j];
            char proof[2048];
            size_t k;
            int named = 0;
            if (!p->active || f->verdict != OBJC_UNSUPPORTED || !s->selector || !s->method_kind || !s->receiver) continue;
            if (p->legacy) named = !strcmp(s->selector, p->selector) && !strcmp(s->method_kind, p->method_kind);
            for (k = 0; k < p->n_methods && !named; k++)
                named = !strcmp(s->selector, p->methods[k].selector) && !strcmp(s->method_kind, p->methods[k].kind);
            if (!named || !chain_includes(a, s->receiver, p->cls)) continue;
            snprintf(proof, sizeof proof, "provided by %s: %s (was: %s)", p->provider_id, p->reason, f->proof ? f->proof : "-");
            if (objc_set_string(&f->proof, proof)) return objc_fail(a, "out-of-memory", NULL, 0, "proof");
            f->verdict = OBJC_PROVIDED;
            break;
        }
    }
    return OBJC_OK;
}

/* ---- the build side ------------------------------------------------------------------------------ */

static int assembler_local(const char *name) {
    return !strncmp(name, "l_", 2) || !strncmp(name, "ltmp", 4) || (name[0] == 'L' && name[1] != 0);
}

typedef struct { size_t provider, atom; const OMember *m; uint32_t k; } Local;

/* Atom k of member m, placed at a.address in the prestrip image pi, equals the member's bytes there. */
static int verify_local(ObjcAnalysis *a, ObjcProvider *p, OArchive *ar, ObjcImage *pi, const Local *l) {
    const ObjcProviderAtom *g = &p->atoms[l->atom];
    const OMember *m = l->m;
    const OSect *x = &m->sects[m->nl[l->k].n_sect - 1];
    uint64_t lo, hi;
    const char *fs;
    V v;
    int rc;
    memset(&v, 0, sizeof v);
    v.a = a; v.p = p; v.ar = ar; v.im = pi; v.mismatch = "prestrip-mismatch"; v.atom = g->symbol;
    atom_extent(m, l->k, &lo, &hi);
    if (hi - lo != g->size)
        rc = vfail(&v, "provider-mapping-mismatch", g->address, "%s(%s) is %llu bytes, the link map says %llu", m->name, g->symbol,
                   (unsigned long long)(hi - lo), (unsigned long long)g->size);
    else if (!(fs = objc_image_section_of(pi, g->address, NULL, NULL, NULL)) || strcmp(fs, x->name))
        rc = vfail(&v, "provider-mapping-mismatch", g->address, "%s(%s) is in %s, the prestrip address in %s", m->name, g->symbol, x->name, fs ? fs : "no section");
    else
        rc = compare_region(&v, (size_t)(m - ar->m), x, lo, hi, g->address, 0);
    free(v.work);
    return rc;
}

int objc_map_provider_link(ObjcAnalysis *a, const char *final, const char *prestrip, const char *link_map) {
    ObjcImage *pi = NULL;
    ObjcLinkMap map;
    size_t i, j;
    OArchive *ars = NULL;
    Local *locals = NULL;
    size_t nlocals = 0;
    int rc;
    memset(&map, 0, sizeof map);
    if ((rc = objc_linkmap_read(a, link_map, &map))) goto out;
    if ((rc = objc_linkmap_check_image(a, &map, final, prestrip))) goto out;
    if ((rc = objc_image_open(a, prestrip, &pi))) goto out;
    if (!(ars = calloc(a->n_providers + 1, sizeof *ars))) { rc = objc_fail(a, "out-of-memory", NULL, 0, "archives"); goto out; }
    for (i = 0; i < a->n_providers; i++) if ((rc = objc_archive_open(a, a->providers[i].archive, &ars[i]))) goto out;
    for (i = 0; i < a->n_providers; i++) {
        ObjcProvider *p = &a->providers[i];
        p->have_evidence = 1;
        if (objc_set_string(&p->ev_declaration_sha256, p->declaration_sha256) || objc_set_string(&p->ev_archive_sha256, p->archive_sha256))
            { rc = objc_fail(a, "out-of-memory", NULL, 0, "provider"); goto out; }
    }
    for (j = 0; j < map.natoms; j++) {
        const ObjcMapAtom *t = &map.atoms[j];
        const ObjcMapFile *f = t->file < 0 ? NULL : &map.files[t->file];
        const char *name = t->name;
        uint64_t addr = t->addr;
        if (!f || !f->archive || strlen(f->archive) >= PATH_MAX || strlen(f->member) >= sizeof ars->m->name) continue;
        for (i = 0; i < a->n_providers; i++) {
            ObjcProvider *p = &a->providers[i];
            char rp[PATH_MAX];
            OArchive *ar = &ars[i];
            OMember *m;
            uint32_t k;
            if (!realpath(f->archive, rp) || strcmp(rp, p->archive)) continue;
            if (!(m = objc_archive_member(ar, f->member))) {
                rc = objc_fail(a, "link-map-mismatch", NULL, 0, "%s names member %s, which %s lacks", link_map, f->member, p->archive);
                goto out;
            }
            for (k = 0; k < m->nsyms; k++) {
                uint64_t w;
                ObjcProviderAtom *g;
                size_t q;
                if (!objc_obj_defined(&m->nl[k]) || strcmp(objc_obj_sym_name(m, k), name) || content_of(&m->sects[m->nl[k].n_sect - 1], &w) != C_ATOM) continue;
                int local = !objc_image_has_symbol(pi, name, addr) && assembler_local(name);
                if (!local && !objc_image_has_symbol(pi, name, addr)) {
                    rc = objc_fail(a, "prestrip-mismatch", NULL, addr, "the prestrip image has no %s at 0x%llx, where the link map places %s(%s)", name, (unsigned long long)addr, f->member, name);
                    goto out;
                }
                for (q = 0; q < p->n_atoms; q++)
                    if (!strcmp(p->atoms[q].member, m->name) && !strcmp(p->atoms[q].symbol, name)) break;
                if (q < p->n_atoms) { rc = objc_fail(a, "malformed-link-map", NULL, addr, "%s(%s) placed twice", m->name, name); goto out; }
                if (!(g = realloc(p->atoms, (p->n_atoms + 1) * sizeof *g))) { rc = objc_fail(a, "out-of-memory", NULL, 0, "atoms"); goto out; }
                p->atoms = g; g = &p->atoms[p->n_atoms++]; memset(g, 0, sizeof *g);
                g->address = addr; g->size = t->size;
                if (local) {
                    Local *lg = realloc(locals, (nlocals + 1) * sizeof *lg);
                    if (!lg) { rc = objc_fail(a, "out-of-memory", NULL, 0, "assembler-local atoms"); goto out; }
                    locals = lg; locals[nlocals].provider = i; locals[nlocals].atom = p->n_atoms - 1; locals[nlocals].m = m; locals[nlocals].k = k; nlocals++;
                }
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
    for (j = 0; j < nlocals; j++)
        if (verify_local(a, &a->providers[locals[j].provider], &ars[locals[j].provider], pi, &locals[j])) { rc = OBJC_CANNOT_MEASURE; goto out; }
    rc = OBJC_OK;
out:
    free(locals);
    if (ars) for (i = 0; i < a->n_providers; i++) objc_archive_free(&ars[i]);
    free(ars);
    objc_linkmap_free(&map);
    objc_image_close(pi);
    return rc ? OBJC_CANNOT_MEASURE : OBJC_OK;
}
