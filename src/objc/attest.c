/* attest.c -- the bounded MH_OBJECT and BSD ar(5) readers (provider.c's, shared), and the objects the link map
 * names, found for the undecoded-bytes sweep (attest.h). */
#include "attest.h"
#include "linkmap.h"
#include <CommonCrypto/CommonDigest.h>
#include <limits.h>
#include <mach-o/loader.h>
#include <mach-o/reloc.h>
#include <mach-o/x86_64/reloc.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

/* ---- objects and archives ----------------------------------------------------------------------- */

static void hex_digest(const uint8_t *p, size_t n, char out[65]) {
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX c;
    int i;
    CC_SHA256_Init(&c);
    while (n) { CC_LONG k = n > (1u << 30) ? (1u << 30) : (CC_LONG)n; CC_SHA256_Update(&c, p, k); p += k; n -= k; }
    CC_SHA256_Final(d, &c);
    for (i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(out + 2 * i, 3, "%02x", d[i]);
}

const char *objc_obj_sym_name(const OMember *m, uint32_t i) {
    uint32_t x = m->nl[i].n_un.n_strx;
    return x < m->strsize ? m->strtab + x : "";
}
int objc_obj_defined(const struct nlist_64 *n) { return !(n->n_type & N_STAB) && (n->n_type & N_TYPE) == N_SECT; }

static int why_is(int rc, char *why, size_t n, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
static int why_is(int rc, char *why, size_t n, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(why, n, fmt, ap);
    va_end(ap);
    return rc;
}

int objc_obj_parse(OMember *m, char *why, size_t n) {
    struct mach_header_64 h;
    size_t off;
    uint32_t i;
    int segs = 0;
    const int BAD = OBJC_OBJ_MALFORMED;
    if (m->size < sizeof h) return why_is(BAD, why, n, "member %s is too short", m->name);
    memcpy(&h, m->buf, sizeof h);
    if (h.magic != MH_MAGIC_64 || h.cputype != CPU_TYPE_X86_64 || h.filetype != MH_OBJECT)
        return why_is(OBJC_OBJ_NOT_X86_64, why, n, "member %s is not an x86_64 relocatable object", m->name);
    if (h.sizeofcmds > m->size - sizeof h) return why_is(BAD, why, n, "member %s: load commands past its end", m->name);
    for (i = 0, off = sizeof h; i < h.ncmds; i++) {
        struct load_command lc;
        if (off + sizeof lc > sizeof h + h.sizeofcmds) return why_is(BAD, why, n, "member %s: truncated load command", m->name);
        memcpy(&lc, m->buf + off, sizeof lc);
        if (lc.cmdsize < sizeof lc || lc.cmdsize > sizeof h + h.sizeofcmds - off)
            return why_is(BAD, why, n, "member %s: bad load command size", m->name);
        if (lc.cmd == LC_SEGMENT_64) {
            struct segment_command_64 sg;
            uint32_t k;
            if (segs++ || lc.cmdsize < sizeof sg) return why_is(BAD, why, n, "member %s: unexpected segments", m->name);
            memcpy(&sg, m->buf + off, sizeof sg);
            if ((uint64_t)sg.nsects * sizeof(struct section_64) > lc.cmdsize - sizeof sg)
                return why_is(BAD, why, n, "member %s: sections past the command", m->name);
            if (!(m->sects = calloc(sg.nsects + 1, sizeof *m->sects))) return why_is(-1, why, n, "sections");
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
                    return why_is(BAD, why, n, "member %s: section %s past its end", m->name, o->name);
                if (x.reloff > m->size || (uint64_t)x.nreloc * 8 > m->size - x.reloff)
                    return why_is(BAD, why, n, "member %s: relocations past its end", m->name);
            }
            m->nsects = sg.nsects;
        } else if (lc.cmd == LC_SYMTAB) {
            struct symtab_command st;
            if (m->nl) return why_is(BAD, why, n, "member %s: two symbol tables", m->name);
            if (lc.cmdsize < sizeof st) return why_is(BAD, why, n, "member %s: short LC_SYMTAB", m->name);
            memcpy(&st, m->buf + off, sizeof st);
            if (st.symoff > m->size || (uint64_t)st.nsyms * sizeof(struct nlist_64) > m->size - st.symoff ||
                st.stroff > m->size || st.strsize > m->size - st.stroff || !st.strsize || m->buf[st.stroff + st.strsize - 1])
                return why_is(BAD, why, n, "member %s: symbol table past its end", m->name);
            if (!(m->nl = malloc(((size_t)st.nsyms + 1) * sizeof *m->nl))) return why_is(-1, why, n, "symbols");
            memcpy(m->nl, m->buf + st.symoff, (size_t)st.nsyms * sizeof *m->nl);
            m->nsyms = st.nsyms; m->strtab = (const char *)m->buf + st.stroff; m->strsize = st.strsize;
        }
        off += lc.cmdsize;
    }
    for (i = 0; i < m->nsyms; i++)
        if (objc_obj_defined(&m->nl[i]) && (m->nl[i].n_sect < 1 || m->nl[i].n_sect > m->nsects))
            return why_is(BAD, why, n, "member %s: symbol %s in no section", m->name, objc_obj_sym_name(m, i));
    return 0;
}

/* BSD ar(5): "!<arch>\n", 60-byte headers, "#1/N" long names, even padding; index members skipped. The member
 * after *off: 1 with its name and bytes, 0 at the end, -1 with WHY (LABEL names the archive). */
static int ar_next(const uint8_t *buf, size_t size, size_t *off, const char *label, char name[256],
                   size_t *data, size_t *len, char *why, size_t n) {
    while (*off < size) {
        const uint8_t *h = buf + *off;
        char field[17];
        unsigned long long sz;
        size_t nl = 0;
        char *end;
        if (size - *off < 60 || h[58] != '`' || h[59] != '\n') return why_is(-1, why, n, "%s: bad member header at %zu", label, *off);
        memcpy(field, h + 48, 10); field[10] = 0;
        sz = strtoull(field, &end, 10);
        if (end == field || (*end && *end != ' ') || sz > size - *off - 60) return why_is(-1, why, n, "%s: bad member size at %zu", label, *off);
        *data = *off + 60; *len = (size_t)sz;
        memcpy(field, h, 16); field[16] = 0;
        if (!strncmp(field, "#1/", 3)) {
            nl = (size_t)strtoul(field + 3, &end, 10);
            if (!nl || nl >= 256 || nl > *len) return why_is(-1, why, n, "%s: bad long name at %zu", label, *off);
            memcpy(name, buf + *data, nl); name[nl] = 0;
            *data += nl; *len -= nl;
        } else {
            size_t k = 16;
            while (k && field[k - 1] == ' ') k--;
            if (k && field[k - 1] == '/') return why_is(-1, why, n, "%s: GNU-style archive names are not supported", label);
            memcpy(name, field, k); name[k] = 0;
        }
        name[strcspn(name, "\0")] = 0;
        *off = *data + *len + ((*data + *len) & 1);
        if (!strncmp(name, "__.SYMDEF", 9)) continue;
        if (!*name) return why_is(-1, why, n, "%s: unnamed member", label);
        return 1;
    }
    return 0;
}

void objc_archive_free(OArchive *ar) {
    size_t i;
    for (i = 0; i < ar->n; i++) { free(ar->m[i].sects); free(ar->m[i].nl); }
    free(ar->m); free(ar->buf);
    memset(ar, 0, sizeof *ar);
}

int objc_archive_open(ObjcAnalysis *a, const char *path, OArchive *ar) {
    size_t off = 8, data, len;
    char name[256], why[PATH_MAX + 512];
    int rc;
    memset(ar, 0, sizeof *ar);
    if ((rc = objc_read_file(a, path, OBJC_ARCHIVE_MAX, &ar->buf, &ar->size, "provider archive"))) return rc;
    if (ar->size < 8 || memcmp(ar->buf, "!<arch>\n", 8)) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s is not an ar archive", path);
    while ((rc = ar_next(ar->buf, ar->size, &off, path, name, &data, &len, why, sizeof why))) {
        OMember *g;
        size_t i;
        if (rc < 0) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s", why);
        for (i = 0; i < ar->n; i++)
            if (!strcmp(ar->m[i].name, name)) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s: two members named %s", path, name);
        if (!(g = realloc(ar->m, (ar->n + 1) * sizeof *g))) return objc_fail(a, "out-of-memory", NULL, 0, "members");
        ar->m = g; g = &ar->m[ar->n++]; memset(g, 0, sizeof *g);
        snprintf(g->name, sizeof g->name, "%s", name);
        g->buf = ar->buf + data; g->size = len;
        hex_digest(g->buf, g->size, g->sha);
        if ((rc = objc_obj_parse(g, why, sizeof why)) < 0) return objc_fail(a, "out-of-memory", NULL, 0, "%s", why);
        if (rc) return objc_fail(a, "malformed-provider-archive", NULL, 0, "%s", why);
    }
    return OBJC_OK;
}

OMember *objc_archive_member(OArchive *ar, const char *name) {
    size_t i;
    for (i = 0; i < ar->n; i++) if (!strcmp(ar->m[i].name, name)) return &ar->m[i];
    return NULL;
}

/* ---- the objects a link map names -------------------------------------------------------------- */

struct ObjcObject { uint8_t *buf; OMember m; };
struct ObjcObjectSlot { int done; ObjcObject *obj; char *why, *msg; };

static int slot_why(ObjcAnalysis *a, struct ObjcObjectSlot *s, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static int slot_why(ObjcAnalysis *a, struct ObjcObjectSlot *s, const char *fmt, ...) {
    char why[PATH_MAX + 512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(why, sizeof why, fmt, ap);
    va_end(ap);
    if (!(s->why = strdup(why))) return objc_fail(a, "out-of-memory", NULL, 0, "%s", "attestation");
    return OBJC_OK;
}

static int is_file(const char *path) {
    struct stat st;
    return stat(path, &st) == 0 && S_ISREG(st.st_mode);
}

/* PATH itself when it exists, else its basename in exactly one --object-dir: 0 with FOUND set, or 0 with
 * FOUND empty and the slot's reason set. */
static int locate(ObjcAnalysis *a, struct ObjcObjectSlot *s, const char *path, char found[PATH_MAX]) {
    const char *base = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
    size_t i, hits = 0;
    *found = 0;
    if (is_file(path)) { snprintf(found, PATH_MAX, "%s", path); return OBJC_OK; }
    for (i = 0; i < a->n_object_dirs; i++) {
        char p[PATH_MAX];
        if ((size_t)snprintf(p, sizeof p, "%s/%s", a->object_dirs[i], base) >= sizeof p || !is_file(p)) continue;
        if (!hits++) snprintf(found, PATH_MAX, "%s", p);
    }
    if (hits == 1) return OBJC_OK;
    *found = 0;
    if (!hits) return slot_why(a, s, "%s not found in --object-dir", base);
    return slot_why(a, s, "%s found in %zu --object-dirs", base, hits);
}

/* PATH's bytes, read as objc_read_file does, except that a file it cannot open or read, or one over
 * OBJC_ARCHIVE_MAX, is the slot's reason and not an error. */
static int read_object(ObjcAnalysis *a, struct ObjcObjectSlot *s, const char *path, const char *base, uint8_t **buf, size_t *size) {
    FILE *f;
    struct stat st;
    *buf = NULL;
    if (!(f = fopen(path, "rb")) || fstat(fileno(f), &st) != 0 || !S_ISREG(st.st_mode)) {
        if (f) fclose(f);
        return slot_why(a, s, "%s unreadable", base);
    }
    if ((uint64_t)st.st_size > OBJC_ARCHIVE_MAX) { fclose(f); return slot_why(a, s, "%s too large to read", base); }
    *size = (size_t)st.st_size;
    if (!(*buf = malloc(*size + 1))) { fclose(f); return objc_fail(a, "out-of-memory", NULL, 0, "%s", "attestation"); }
    if (fread(*buf, 1, *size, f) != *size) { fclose(f); free(*buf); *buf = NULL; return slot_why(a, s, "%s unreadable", base); }
    fclose(f);
    return OBJC_OK;
}

static int resolve(ObjcAnalysis *a, const ObjcMapFile *f, struct ObjcObjectSlot *s) {
    const char *path = f->archive ? f->archive : f->path;
    const char *base = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
    char found[PATH_MAX], why[PATH_MAX + 512];
    uint8_t *buf = NULL, *shrunk;
    size_t size = 0;
    ObjcObject *o;
    int rc;
    if (!f->archive && !strcmp(f->path, "linker synthesized")) return slot_why(a, s, "linker synthesized");
    if ((rc = locate(a, s, path, found)) || !*found) return rc;
    if ((rc = read_object(a, s, found, base, &buf, &size)) || !buf) return rc;
    if (f->archive) {
        size_t off = 8, data = 0, len = 0, d, l, hits = 0;
        char name[256];
        if (size < 8 || memcmp(buf, "!<arch>\n", 8)) { free(buf); return slot_why(a, s, "%s is not an ar archive", base); }
        while ((rc = ar_next(buf, size, &off, base, name, &d, &l, why, sizeof why)) > 0)
            if (!strcmp(name, f->member) && !hits++) { data = d; len = l; }
        if (rc < 0) { free(buf); return slot_why(a, s, "%s", why); }
        if (hits != 1) { free(buf); return slot_why(a, s, hits ? "%s appears twice in %s" : "%s is not a member of %s", f->member, base); }
        memmove(buf, buf + data, len);
        size = len;
        if ((shrunk = realloc(buf, len ? len : 1))) buf = shrunk;
    }
    if (!(o = calloc(1, sizeof *o))) { free(buf); return objc_fail(a, "out-of-memory", NULL, 0, "%s", "attestation"); }
    o->buf = buf;
    o->m.buf = buf; o->m.size = size;
    snprintf(o->m.name, sizeof o->m.name, "%s", f->archive ? f->member : base);
    rc = objc_obj_parse(&o->m, why, sizeof why);
    if (!rc) { s->obj = o; return OBJC_OK; }
    free(o->m.sects); free(o->m.nl); free(o); free(buf);
    if (rc < 0) return objc_fail(a, "out-of-memory", NULL, 0, "%s", why);
    return rc == OBJC_OBJ_NOT_X86_64 ? slot_why(a, s, "not an x86_64 object") : slot_why(a, s, "%s", why);
}

int objc_attest_object(ObjcAnalysis *a, long file, const ObjcObject **out, const char **why) {
    struct ObjcObjectSlot *s;
    int rc;
    *out = NULL;
    *why = NULL;
    if (!a->map || file < 0 || (size_t)file >= a->map->nfiles) { *why = "no object file line"; return OBJC_OK; }
    if (!a->objects && !(a->objects = calloc(a->map->nfiles, sizeof *a->objects)))
        return objc_fail(a, "out-of-memory", NULL, 0, "%s", "attestation");
    s = &a->objects[file];
    if (!s->done) {
        if ((rc = resolve(a, &a->map->files[file], s))) return rc;
        s->done = 1;
    }
    *out = s->obj;
    *why = s->why;
    return OBJC_OK;
}

/* The one defined symbol NAME in M: its section index (0-based) and value, or 0 when none or several. */
static int defined_once(const OMember *m, const char *name, uint32_t *sect, uint64_t *value) {
    uint32_t i, n = 0;
    for (i = 0; i < m->nsyms; i++)
        if (objc_obj_defined(&m->nl[i]) && !strcmp(objc_obj_sym_name(m, i), name)) {
            *sect = m->nl[i].n_sect - 1u; *value = m->nl[i].n_value; n++;
        }
    return n == 1;
}

/* The window's bytes (at offset W of S) that some relocation of S writes: bit k for byte k. A scattered
 * relocation, or one this reader does not know the shape of, writes them all. */
static unsigned reloc_mask(const OMember *m, const OSect *x, uint64_t w) {
    unsigned mask = 0;
    uint32_t i;
    for (i = 0; i < x->nreloc; i++) {
        struct relocation_info r;
        uint64_t lo, len;
        unsigned k;
        memcpy(&r, m->buf + x->reloff + 8u * i, sizeof r);
        if ((uint32_t)r.r_address & R_SCATTERED) return 0xF;
        if (r.r_type > X86_64_RELOC_TLV || (r.r_length != 2 && r.r_length != 3)) return 0xF;
        lo = (uint32_t)r.r_address; len = 1u << r.r_length;
        for (k = 0; k < 4; k++) if (w + k >= lo && w + k - lo < len) mask |= 1u << k;
    }
    return mask;
}

static const ObjcMapSect *sect_at(const ObjcLinkMap *m, uint64_t va) {
    size_t i;
    for (i = 0; i < m->nsects; i++) if (va >= m->sects[i].addr && va - m->sects[i].addr < m->sects[i].size) return &m->sects[i];
    return NULL;
}

static int within(uint64_t t, uint64_t lo, uint64_t size) { return t >= lo && t - lo <= size; }

int objc_attest_window(ObjcAnalysis *a, uint64_t va, const uint8_t *bytes, uint64_t target, const char **why) {
    const ObjcMapAtom *t = NULL;
    const ObjcMapSect *ts;
    const ObjcObject *o;
    const OSect *x;
    struct ObjcObjectSlot *s;
    uint64_t value, off, w, base;
    uint32_t sect;
    unsigned mask, k;
    size_t i, n;
    *why = NULL;
    if (!a->map || objc_linkmap_cover(a->map, va, va + 4, &t) != 1 || va < t->addr || t->size < 4 || va - t->addr > t->size - 4) {
        *why = "no single atom covers the window"; return 0;
    }
    if (objc_attest_object(a, t->file, &o, why)) return -1;
    if (!o) return 0;
    s = &a->objects[t->file];
    if (!defined_once(&o->m, t->name, &sect, &value)) {
        char buf[1024];
        snprintf(buf, sizeof buf, "symbol %s not defined in its object", t->name);
        free(s->msg);
        if (!(s->msg = strdup(buf))) { objc_fail(a, "out-of-memory", NULL, 0, "%s", "attestation"); return -1; }
        *why = s->msg; return 0;
    }
    x = &o->m.sects[sect];
    k = x->flags & SECTION_TYPE;
    off = value - x->addr;
    w = off + (va - t->addr);
    if (k == S_ZEROFILL || k == S_GB_ZEROFILL || k == S_THREAD_LOCAL_ZEROFILL || value < x->addr || off > x->size ||
        w > x->size || x->size - w < 4) {
        *why = "bytes differ from the object"; return 0;
    }
    mask = reloc_mask(&o->m, x, w);
    for (k = 0; k < 4; k++)
        if (!(mask & (1u << k)) && o->m.buf[x->off + w + k] != bytes[k]) { *why = "bytes differ from the object"; return 0; }
    if (mask) { *why = "a relocation covers the window"; return 0; }
    /* The target: outside where S itself would lie were it placed whole, and outside every atom this object
     * places in the target's section, ends included. */
    if (!(ts = sect_at(a->map, target))) { *why = "target outside the map's sections"; return 0; }
    base = t->addr - off;
    if (t->addr < off || within(target, base, x->size)) { *why = "target inside the same object's section"; return 0; }
    for (i = 0, n = a->map->natoms; i < n; ) { size_t mid = i + (n - i) / 2; if (a->map->atoms[mid].addr < ts->addr) i = mid + 1; else n = mid; }
    for (; i < a->map->natoms && a->map->atoms[i].addr - ts->addr <= ts->size; i++) {
        const ObjcMapAtom *u = &a->map->atoms[i];
        if (u->file == t->file && within(target, u->addr, u->size)) {
            *why = "target inside the same object's section"; return 0;
        }
    }
    return 1;
}

void objc_attest_free(ObjcAnalysis *a) {
    size_t i;
    if (a->objects)
        for (i = 0; i < a->map->nfiles; i++) {
            ObjcObject *o = a->objects[i].obj;
            if (o) { free(o->m.sects); free(o->m.nl); free(o->buf); free(o); }
            free(a->objects[i].why); free(a->objects[i].msg);
        }
    free(a->objects); a->objects = NULL;
    if (a->map) { objc_linkmap_free(a->map); free(a->map); a->map = NULL; }
    for (i = 0; i < a->n_object_dirs; i++) free(a->object_dirs[i]);
    free(a->object_dirs); a->object_dirs = NULL; a->n_object_dirs = 0;
    free(a->be_link_map_sha256); a->be_link_map_sha256 = NULL;
}
