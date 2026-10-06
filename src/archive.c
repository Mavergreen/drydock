/* archive.c -- see archive.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

#include "archive.h"
#include "rewrite.h"
#include "symrename.h"

#define AR_MAGIC "!<arch>\n"
#define AR_HDR 60
#define AR_SIZE_MAX 9999999999ull

static int refuse(char *why, size_t whylen, const char *fmt, ...) {
    if (why && whylen) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(why, whylen, fmt, ap);
        va_end(ap);
    }
    return MR_REFUSED;
}

/* Digits then spaces, at least one digit, filling the field. */
static int field_decimal(const uint8_t *p, size_t len, uint64_t *out) {
    size_t i = 0;
    uint64_t v = 0;
    while (i < len && p[i] >= '0' && p[i] <= '9') v = v * 10 + (uint64_t)(p[i++] - '0');
    if (i == 0) return -1;
    for (size_t j = i; j < len; j++) if (p[j] != ' ') return -1;
    *out = v;
    return 0;
}

static int index_kind_of(const char *name) {
    if (strcmp(name, "__.SYMDEF") == 0) return MAR_IDX_32;
    if (strcmp(name, "__.SYMDEF SORTED") == 0) return MAR_IDX_32_SORTED;
    if (strcmp(name, "__.SYMDEF_64") == 0) return MAR_IDX_64;
    if (strcmp(name, "__.SYMDEF_64 SORTED") == 0) return MAR_IDX_64_SORTED;
    return -1;
}

static int index_width(int kind) { return kind == MAR_IDX_64 || kind == MAR_IDX_64_SORTED ? 8 : 4; }
static int index_sorted(int kind) { return kind == MAR_IDX_32_SORTED || kind == MAR_IDX_64_SORTED; }

static uint64_t get_le(const uint8_t *p, int w) {
    uint64_t v = 0;
    for (int i = w - 1; i >= 0; i--) v = v << 8 | p[i];
    return v;
}

static void put_le(uint8_t *p, uint64_t v, int w) {
    for (int i = 0; i < w; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static int is_member_header(const mar_archive *a, uint64_t off) {
    size_t lo = 1, hi = a->n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (a->m[mid].hdr_off < off) lo = mid + 1; else hi = mid;
    }
    return lo < a->n && a->m[lo].hdr_off == off;
}

static int check_index(const uint8_t *buf, const mar_archive *a, char *why, size_t whylen) {
    const mar_member *ix = &a->m[0];
    const uint8_t *p = buf + ix->data_off;
    uint64_t size = ix->data_size;
    int w = index_width(a->index_kind);
    if (size < (uint64_t)w) return refuse(why, whylen, "at offset %zu: the index is truncated", ix->hdr_off);
    uint64_t rbytes = get_le(p, w);
    if (rbytes % (2 * (uint64_t)w) != 0)
        return refuse(why, whylen, "at offset %zu: the index's byte count is not whole entries", ix->hdr_off);
    if (rbytes > size - w || size - w - rbytes < (uint64_t)w)
        return refuse(why, whylen, "at offset %zu: the index's entries run past the member", ix->hdr_off);
    const uint8_t *strs = p + w + rbytes + w;
    uint64_t strsize = get_le(p + w + rbytes, w);
    if (strsize > size - w - rbytes - w)
        return refuse(why, whylen, "at offset %zu: the index's strings run past the member", ix->hdr_off);
    for (uint64_t e = 0; e < rbytes / (2 * (uint64_t)w); e++) {
        uint64_t strx = get_le(p + w + e * 2 * w, w);
        uint64_t off = get_le(p + w + e * 2 * w + w, w);
        if (strx >= strsize || !memchr(strs + strx, 0, (size_t)(strsize - strx)))
            return refuse(why, whylen, "at offset %zu: index entry %llu names a string past its table",
                          ix->hdr_off, (unsigned long long)e);
        if (!is_member_header(a, off))
            return refuse(why, whylen, "at offset %zu: index entry %llu points at %llu, not a member header",
                          ix->hdr_off, (unsigned long long)e, (unsigned long long)off);
    }
    return 0;
}

int mar_parse(const uint8_t *buf, size_t size, mar_archive *a, char *why, size_t whylen) {
    a->m = NULL; a->n = 0; a->index_kind = MAR_IDX_NONE;
    if (size < 8 || memcmp(buf, AR_MAGIC, 8) != 0)
        return refuse(why, whylen, "not an archive: no !<arch> header");
    size_t cap = 0, off = 8;
    int rc = 0;
    while (off < size) {
        const uint8_t *h = buf + off;
        uint64_t asize, nl = 0;
        if (size - off < AR_HDR) { rc = refuse(why, whylen, "at offset %zu: the member header is truncated", off); break; }
        if (h[58] != '`' || h[59] != '\n') { rc = refuse(why, whylen, "at offset %zu: the member header does not end in `\\n", off); break; }
        if (field_decimal(h + 48, 10, &asize) != 0) { rc = refuse(why, whylen, "at offset %zu: the size field is not decimal", off); break; }
        if (asize > size - off - AR_HDR) { rc = refuse(why, whylen, "at offset %zu: the member runs past the end of the archive", off); break; }
        if (h[0] == '/') { rc = refuse(why, whylen, "at offset %zu: a GNU-style '/' member; this reads BSD archives", off); break; }
        if (a->n == cap) {
            size_t ncap = cap ? cap * 2 : 16;
            mar_member *nm = realloc(a->m, ncap * sizeof *nm);
            if (!nm) { rc = MR_FAIL; refuse(why, whylen, "out of memory"); break; }
            a->m = nm; cap = ncap;
        }
        mar_member *m = &a->m[a->n];
        memset(m, 0, sizeof *m);
        m->hdr_off = off;
        if (memcmp(h, "#1/", 3) == 0) {
            if (field_decimal(h + 3, 13, &nl) != 0) { rc = refuse(why, whylen, "at offset %zu: a #1/ name without a decimal length", off); break; }
            if (nl > asize) { rc = refuse(why, whylen, "at offset %zu: the #1/%llu name is longer than the member", off, (unsigned long long)nl); break; }
            const uint8_t *s = h + AR_HDR;
            size_t len = 0;
            while (len < nl && s[len]) len++;
            if (len >= sizeof m->name) len = sizeof m->name - 1;
            memcpy(m->name, s, len);
        } else {
            size_t len = 16;
            while (len > 0 && h[len - 1] == ' ') len--;
            memcpy(m->name, h, len);
        }
        m->name_len_inline = (size_t)nl;
        m->data_off = off + AR_HDR + (size_t)nl;
        m->data_size = (size_t)(asize - nl);
        if (strncmp(m->name, "__.SYMDEF", 9) == 0) {
            int kind = index_kind_of(m->name);
            if (a->n != 0) { rc = refuse(why, whylen, "at offset %zu: an index member that is not the first member", off); break; }
            if (kind < 0) { rc = refuse(why, whylen, "at offset %zu: an unknown index member '%s'", off, m->name); break; }
            m->is_index = 1;
            a->index_kind = kind;
        }
        a->n++;
        size_t end = off + AR_HDR + (size_t)asize;
        if (end % 2) {
            if (end == size) { rc = refuse(why, whylen, "at offset %zu: the odd-sized member lacks its pad byte", off); break; }
            end++;
        }
        off = end;
    }
    if (rc == 0 && a->n == 0) rc = refuse(why, whylen, "an archive with no members");
    if (rc == 0 && a->index_kind != MAR_IDX_NONE) rc = check_index(buf, a, why, whylen);
    if (rc != 0) mar_free(a);
    return rc;
}

void mar_free(mar_archive *a) {
    free(a->m);
    a->m = NULL;
    a->n = 0;
}

typedef struct {
    const char *name;
    size_t member, seq, strx;
} mar_ent;

typedef struct {
    mar_ent *e;
    size_t n, cap, strbytes, member;
    int nomem;
} mar_collect;

static int collect(const char *name, void *ctx) {
    mar_collect *c = ctx;
    if (!name[0]) return 0;
    if (c->n == c->cap) {
        size_t ncap = c->cap ? c->cap * 2 : 64;
        mar_ent *ne = realloc(c->e, ncap * sizeof *ne);
        if (!ne) { c->nomem = 1; return 1; }
        c->e = ne; c->cap = ncap;
    }
    mar_ent *e = &c->e[c->n];
    e->name = name; e->member = c->member; e->seq = c->n; e->strx = c->strbytes;
    c->strbytes += strlen(name) + 1;
    c->n++;
    return 0;
}

static int ent_cmp(const void *x, const void *y) {
    const mar_ent *a = x, *b = y;
    int c = strcmp(a->name, b->name);
    if (c) return c;
    return a->seq < b->seq ? -1 : a->seq > b->seq;
}

static void put_size(uint8_t *hdr, uint64_t v) {
    char f[16];
    snprintf(f, sizeof f, "%-10llu", (unsigned long long)v);
    memcpy(hdr + 48, f, 10);
}

static int fail(char *why, size_t whylen, int rc, const char *fmt, ...) {
    if (why && whylen) {
        va_list ap;
        va_start(ap, fmt);
        vsnprintf(why, whylen, fmt, ap);
        va_end(ap);
    }
    return rc;
}

static int symbols_of(const uint8_t *b, size_t s, const mar_member *m, mar_collect *c,
                      char *why, size_t whylen) {
    uint32_t magic = 0;
    if (s >= 4) memcpy(&magic, b, 4);
    if (magic == MH_MAGIC || magic == MH_CIGAM || magic == MH_CIGAM_64
        || magic == FAT_MAGIC || magic == FAT_CIGAM)
        return fail(why, whylen, MR_REFUSED, "member '%s' is a Mach-O that is not thin 64-bit; its symbols cannot be indexed", m->name);
    if (magic != MH_MAGIC_64) return 0;
    int rc = msr_each_defined_external(b, s, collect, c);
    if (c->nomem) return fail(why, whylen, MR_FAIL, "out of memory");
    if (rc != 0) return fail(why, whylen, MR_REFUSED, "member '%s': %s", m->name, msr_reason(MSR_MALFORMED));
    return 0;
}

int mar_rewrite(uint8_t **pbuf, size_t *psize, mar_member_fn fn, void *ctx, char *why, size_t whylen) {
    const uint8_t *in = *pbuf;
    size_t insize = *psize;
    mar_archive a;
    int rc = mar_parse(in, insize, &a, why, whylen);
    if (rc != 0) return rc;

    int align8 = insize % 8 == 0;
    for (size_t i = 0; i < a.n; i++) if (a.m[i].hdr_off % 8) align8 = 0;

    uint8_t **bufs = calloc(a.n, sizeof *bufs);
    size_t *sizes = calloc(a.n, sizeof *sizes);
    uint64_t *newoff = calloc(a.n, sizeof *newoff);
    size_t *padded = calloc(a.n, sizeof *padded);
    mar_collect c;
    memset(&c, 0, sizeof c);
    uint8_t *out = NULL;
    if (!bufs || !sizes || !newoff || !padded) { rc = fail(why, whylen, MR_FAIL, "out of memory"); goto done; }

    for (size_t i = 0; i < a.n; i++) {
        if (a.m[i].is_index) continue;
        bufs[i] = malloc(a.m[i].data_size ? a.m[i].data_size : 1);
        if (!bufs[i]) { rc = fail(why, whylen, MR_FAIL, "out of memory"); goto done; }
        memcpy(bufs[i], in + a.m[i].data_off, a.m[i].data_size);
        sizes[i] = a.m[i].data_size;
        rc = fn(&bufs[i], &sizes[i], &a.m[i], ctx);
        if (rc != 0) goto done;
        if (a.index_kind != MAR_IDX_NONE) {
            c.member = i;
            rc = symbols_of(bufs[i], sizes[i], &a.m[i], &c, why, whylen);
            if (rc != 0) goto done;
        }
    }

    int w = index_width(a.index_kind);
    uint64_t ibody = 0, strsize = 0;
    size_t off = 8;
    if (a.index_kind != MAR_IDX_NONE) {
        const mar_member *ix = &a.m[0];
        uint64_t fixed = 8 + AR_HDR + ix->name_len_inline + (uint64_t)w + c.n * 2 * (uint64_t)w + (uint64_t)w;
        strsize = (fixed + c.strbytes + 7) / 8 * 8 - fixed;
        ibody = (uint64_t)w + c.n * 2 * (uint64_t)w + (uint64_t)w + strsize;
        if (ix->name_len_inline + ibody > AR_SIZE_MAX) { rc = fail(why, whylen, MR_REFUSED, "the index is too large for its header"); goto done; }
        off = 8 + AR_HDR + ix->name_len_inline + (size_t)ibody;
    }
    for (size_t i = 0; i < a.n; i++) {
        if (a.m[i].is_index) continue;
        uint64_t nl = a.m[i].name_len_inline, data = sizes[i];
        if (data != a.m[i].data_size && align8) data = (off + AR_HDR + nl + data + 7) / 8 * 8 - (off + AR_HDR + nl);
        if (nl + data > AR_SIZE_MAX) { rc = fail(why, whylen, MR_REFUSED, "member '%s' is too large for its header", a.m[i].name); goto done; }
        newoff[i] = off;
        padded[i] = (size_t)data;
        off += AR_HDR + (size_t)(nl + data);
        off += off % 2;
    }
    if ((a.index_kind == MAR_IDX_32 || a.index_kind == MAR_IDX_32_SORTED)
        && (newoff[a.n - 1] > UINT32_MAX || strsize > UINT32_MAX)) {
        rc = fail(why, whylen, MR_REFUSED, "the archive outgrows its 32-bit index");
        goto done;
    }

    out = malloc(off);
    if (!out) { rc = fail(why, whylen, MR_FAIL, "out of memory"); goto done; }
    memcpy(out, AR_MAGIC, 8);
    if (a.index_kind != MAR_IDX_NONE) {
        const mar_member *ix = &a.m[0];
        uint8_t *p = out + 8;
        memcpy(p, in + ix->hdr_off, AR_HDR + ix->name_len_inline);
        if (ibody != ix->data_size) put_size(p, ix->name_len_inline + ibody);
        uint8_t *q = p + AR_HDR + ix->name_len_inline;
        put_le(q, c.n * 2 * (uint64_t)w, w);
        q += w;
        if (index_sorted(a.index_kind)) qsort(c.e, c.n, sizeof *c.e, ent_cmp);
        for (size_t e = 0; e < c.n; e++) {
            put_le(q, c.e[e].strx, w);
            put_le(q + w, newoff[c.e[e].member], w);
            q += 2 * w;
        }
        put_le(q, strsize, w);
        q += w;
        memset(q, 0, (size_t)strsize);
        for (size_t e = 0; e < c.n; e++) memcpy(q + c.e[e].strx, c.e[e].name, strlen(c.e[e].name) + 1);
    }
    for (size_t i = 0; i < a.n; i++) {
        if (a.m[i].is_index) continue;
        const mar_member *m = &a.m[i];
        size_t nl = m->name_len_inline;
        uint8_t *p = out + newoff[i];
        memcpy(p, in + m->hdr_off, AR_HDR + nl);
        if (padded[i] != m->data_size) put_size(p, nl + padded[i]);
        memcpy(p + AR_HDR + nl, bufs[i], sizes[i]);
        memset(p + AR_HDR + nl + sizes[i], '\n', padded[i] - sizes[i]);
        if ((newoff[i] + AR_HDR + nl + padded[i]) % 2) p[AR_HDR + nl + padded[i]] = '\n';
    }

    free(*pbuf);
    *pbuf = out;
    *psize = off;
    out = NULL;
    rc = 0;
done:
    if (bufs) for (size_t i = 0; i < a.n; i++) free(bufs[i]);
    free(bufs); free(sizes); free(newoff); free(padded); free(c.e); free(out);
    mar_free(&a);
    return rc;
}
