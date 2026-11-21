/* linkmap.c -- reads a link map's Arch, Object files, Sections and Symbols, and checks it is this link's. */
#include "linkmap.h"
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINKMAP_MAX (256u << 20)  /* Codex 0.165's map is 174 MB; the same bound as provider.c's ARCHIVE_MAX */

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

static char *dup_n(const char *s, size_t n) {
    char *d = malloc(n + 1);
    if (d) { memcpy(d, s, n); d[n] = 0; }
    return d;
}

typedef struct { long num; size_t pos; } FileNum;
typedef struct { ObjcMapAtom atom; size_t seq; } SeqAtom;

static int by_num(const void *x, const void *y) {
    const FileNum *p = x, *q = y;
    if (p->num != q->num) return p->num < q->num ? -1 : 1;
    return p->pos < q->pos ? -1 : p->pos > q->pos;
}
static int by_addr(const void *x, const void *y) {
    const SeqAtom *p = x, *q = y;
    if (p->atom.addr != q->atom.addr) return p->atom.addr < q->atom.addr ? -1 : 1;
    return p->seq < q->seq ? -1 : p->seq > q->seq;
}

/* Each atom's map file number becomes the position of the first Object files line with it, or -1. */
static int resolve_files(ObjcLinkMap *m, const long *num) {
    FileNum *idx = malloc((m->nfiles ? m->nfiles : 1) * sizeof *idx);
    size_t i;
    if (!idx) return -1;
    for (i = 0; i < m->nfiles; i++) { idx[i].num = num[i]; idx[i].pos = i; }
    qsort(idx, m->nfiles, sizeof *idx, by_num);
    for (i = 0; i < m->natoms; i++) {
        size_t lo = 0, hi = m->nfiles;
        long want = m->atoms[i].file;
        while (lo < hi) { size_t mid = lo + (hi - lo) / 2; if (idx[mid].num < want) lo = mid + 1; else hi = mid; }
        m->atoms[i].file = lo < m->nfiles && idx[lo].num == want ? (long)idx[lo].pos : -1;
    }
    free(idx);
    return 0;
}

static int sort_atoms(ObjcLinkMap *m) {
    SeqAtom *s;
    size_t i;
    for (i = 1; i < m->natoms && m->atoms[i - 1].addr <= m->atoms[i].addr; i++) ;
    if (i >= m->natoms) return 0;
    if (!(s = malloc(m->natoms * sizeof *s))) return -1;
    for (i = 0; i < m->natoms; i++) { s[i].atom = m->atoms[i]; s[i].seq = i; }
    qsort(s, m->natoms, sizeof *s, by_addr);
    for (i = 0; i < m->natoms; i++) m->atoms[i] = s[i].atom;
    free(s);
    return 0;
}

static int furthest_ends(ObjcLinkMap *m) {
    size_t i;
    if (!(m->ends = malloc((m->natoms ? m->natoms : 1) * sizeof *m->ends))) return -1;
    for (i = 0; i < m->natoms; i++) {
        const ObjcMapAtom *t = &m->atoms[i];
        uint64_t e = t->size > UINT64_MAX - t->addr ? UINT64_MAX : t->addr + t->size;
        m->ends[i] = i && m->ends[i - 1] > e ? m->ends[i - 1] : e;
    }
    return 0;
}

static int parse_line(ObjcAnalysis *a, ObjcLinkMap *m, char *line, int *part, long **num, size_t *capf, size_t *caps, size_t *capa) {
    const char *rest;
    if (!strncmp(line, "# Arch: ", 8)) { snprintf(m->arch, sizeof m->arch, "%s", line + 8); return 0; }
    if (!strcmp(line, "# Object files:")) { *part = 1; return 0; }
    if (!strcmp(line, "# Sections:")) { *part = 2; return 0; }
    if (!strcmp(line, "# Symbols:")) { *part = 3; return 0; }
    if (!strncmp(line, "# Dead Stripped Symbols:", 24)) { *part = 4; return 0; }
    if (*line == '#' || !*line) return 0;
    if (*part == 1) {
        long n = file_index(line, &rest);
        ObjcMapFile *f;
        const char *open;
        size_t len;
        if (n < 0) return objc_fail(a, "malformed-link-map", NULL, 0, "object file line: %.120s", line);
        if (m->nfiles == *capf) {
            size_t c = *capf ? 2 * *capf : 64;
            ObjcMapFile *g = realloc(m->files, c * sizeof *g);
            long *k;
            if (g) m->files = g;
            if (!g || !(k = realloc(*num, c * sizeof *k))) return objc_fail(a, "out-of-memory", NULL, 0, "map");
            *num = k; *capf = c;
        }
        f = &m->files[m->nfiles]; memset(f, 0, sizeof *f);
        len = strlen(rest);
        if (len && rest[len - 1] == ')' && (open = strrchr(rest, '(')) && open != rest) {
            if (!(f->archive = dup_n(rest, (size_t)(open - rest))) || !(f->member = dup_n(open + 1, len - (size_t)(open - rest) - 2)))
                { free(f->archive); return objc_fail(a, "out-of-memory", NULL, 0, "map"); }
        } else if (!(f->path = dup_n(rest, len))) return objc_fail(a, "out-of-memory", NULL, 0, "map");
        (*num)[m->nfiles++] = n;
    } else if (*part == 2) {
        char seg[64], sect[64];
        unsigned long long addr, sz;
        ObjcMapSect *s;
        if (sscanf(line, "%llx %llx %63s %63s", &addr, &sz, seg, sect) != 4 || strlen(seg) > 16 || strlen(sect) > 16)
            return objc_fail(a, "malformed-link-map", NULL, 0, "section line: %.120s", line);
        if (m->nsects == *caps) {
            size_t c = *caps ? 2 * *caps : 32;
            if (!(s = realloc(m->sects, c * sizeof *s))) return objc_fail(a, "out-of-memory", NULL, 0, "map");
            m->sects = s; *caps = c;
        }
        s = &m->sects[m->nsects++];
        s->addr = addr; s->size = sz;
        snprintf(s->seg, sizeof s->seg, "%s", seg); snprintf(s->sect, sizeof s->sect, "%s", sect);
    } else if (*part == 3) {
        unsigned long long addr, sz;
        char *end;
        long n;
        ObjcMapAtom *t;
        addr = strtoull(line, &end, 16);
        if (end == line) return objc_fail(a, "malformed-link-map", NULL, 0, "symbol line: %.120s", line);
        sz = strtoull(end, &end, 16);
        while (*end == ' ' || *end == '\t') end++;
        if ((n = file_index(end, &rest)) < 0) return objc_fail(a, "malformed-link-map", NULL, 0, "symbol line: %.120s", line);
        if (m->natoms == *capa) {
            size_t c = *capa ? 2 * *capa : 256;
            if (!(t = realloc(m->atoms, c * sizeof *t))) return objc_fail(a, "out-of-memory", NULL, 0, "map");
            m->atoms = t; *capa = c;
        }
        t = &m->atoms[m->natoms];
        t->addr = addr; t->size = sz; t->file = n;
        if (!(t->name = dup_n(rest, strlen(rest)))) return objc_fail(a, "out-of-memory", NULL, 0, "map");
        m->natoms++;
    }
    return 0;
}

int objc_linkmap_read(ObjcAnalysis *a, const char *path, ObjcLinkMap *out) {
    uint8_t *buf;
    size_t size, capf = 0, caps = 0, capa = 0;
    long *num = NULL;
    char *line, *next;
    int rc, part = 0;
    memset(out, 0, sizeof *out);
    if ((rc = objc_read_file(a, path, LINKMAP_MAX, &buf, &size, "link map"))) return rc;
    if (memchr(buf, 0, size)) { free(buf); return objc_fail(a, "malformed-link-map", NULL, 0, "%s holds a NUL byte", path); }
    if (!(out->path = dup_n(path, strlen(path)))) { free(buf); return objc_fail(a, "out-of-memory", NULL, 0, "map"); }
    for (line = (char *)buf; line && !rc; line = next) {
        if ((next = strchr(line, '\n'))) *next++ = 0;
        line[strcspn(line, "\r")] = 0;
        rc = parse_line(a, out, line, &part, &num, &capf, &caps, &capa);
    }
    if (!rc && resolve_files(out, num)) rc = objc_fail(a, "out-of-memory", NULL, 0, "map");
    if (!rc && sort_atoms(out)) rc = objc_fail(a, "out-of-memory", NULL, 0, "map");
    if (!rc && furthest_ends(out)) rc = objc_fail(a, "out-of-memory", NULL, 0, "map");
    free(num); free(buf);
    if (rc) { objc_linkmap_free(out); return OBJC_CANNOT_MEASURE; }
    return OBJC_OK;
}

void objc_linkmap_free(ObjcLinkMap *m) {
    size_t i;
    for (i = 0; i < m->nfiles; i++) { free(m->files[i].path); free(m->files[i].archive); free(m->files[i].member); }
    for (i = 0; i < m->natoms; i++) free(m->atoms[i].name);
    free(m->files); free(m->sects); free(m->atoms); free(m->ends); free(m->path);
    memset(m, 0, sizeof *m);
}

const ObjcMapAtom *objc_linkmap_atom_at(const ObjcLinkMap *m, uint64_t va) {
    size_t lo = 0, hi = m->natoms, i;
    while (lo < hi) { size_t mid = lo + (hi - lo) / 2; if (m->atoms[mid].addr <= va) lo = mid + 1; else hi = mid; }
    for (i = lo; i-- > 0 && m->atoms[i].addr == m->atoms[lo - 1].addr; )
        if (va - m->atoms[i].addr < m->atoms[i].size) return &m->atoms[i];
    return NULL;
}

size_t objc_linkmap_cover(const ObjcLinkMap *m, uint64_t lo, uint64_t hi, const ObjcMapAtom **last) {
    size_t l = 0, h = m->natoms, i, n = 0;
    *last = NULL;
    while (l < h) { size_t mid = l + (h - l) / 2; if (m->atoms[mid].addr < hi) l = mid + 1; else h = mid; }
    for (i = l; i-- > 0 && m->ends[i] > lo; )
        if (m->atoms[i].size && (m->atoms[i].addr >= lo || lo - m->atoms[i].addr < m->atoms[i].size)) { n++; *last = &m->atoms[i]; }
    return n;
}

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

int objc_linkmap_check_image(ObjcAnalysis *a, const ObjcLinkMap *m, const char *final, const char *prestrip) {
    ObjcImage *fi = NULL, *pi = NULL;
    size_t i, j, n;
    int rc;
    if ((rc = objc_image_open(a, final, &fi)) || (rc = objc_image_open(a, prestrip, &pi))) goto out;
    if ((rc = same_sections(a, fi, pi))) goto out;
    n = objc_image_nsections(pi);
    for (i = 0; i < m->nsects; i++) {
        char name[40];
        uint64_t fa, fs;
        uint32_t ff;
        snprintf(name, sizeof name, "%s,%s", m->sects[i].seg, m->sects[i].sect);
        for (j = 0; j < n; j++) {
            const char *s = objc_image_section(pi, j, &fa, &fs, &ff);
            if (!strcmp(s, name) && fa == m->sects[i].addr && fs == m->sects[i].size) break;
        }
        if (j == n) {
            rc = objc_fail(a, "link-map-mismatch", NULL, m->sects[i].addr, "%s: section %s at 0x%llx is not the prestrip image's",
                           m->path, name, (unsigned long long)m->sects[i].addr);
            goto out;
        }
    }
    if (strcmp(m->arch, "x86_64")) { rc = objc_fail(a, "link-map-mismatch", NULL, 0, "%s is not an x86_64 link map", m->path); goto out; }
    if (m->nsects != n) {
        rc = objc_fail(a, "link-map-mismatch", NULL, 0, "%s lists %llu sections, the prestrip image has %zu", m->path, (unsigned long long)m->nsects, n);
        goto out;
    }
out:
    objc_image_close(fi); objc_image_close(pi);
    return rc ? OBJC_CANNOT_MEASURE : OBJC_OK;
}
