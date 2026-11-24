#include "bplist.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct BpNode {
    BpType type;
    size_t refs;      /* parents holding it: more than one only for a leaf bp_read shared */
    int64_t index;
    union {
        int64_t i;
        uint64_t u;
        struct { uint64_t bits; int width; } r;
        struct { uint8_t *p; size_t n; } s;           /* BP_STRING (NUL past n), BP_DATA */
        struct { BpNode **v; size_t n, cap; } c;      /* BP_ARRAY; BP_DICT as key, value, key, value ... */
    } u;
};

static BpNode *node(BpType t) {
    BpNode *v = calloc(1, sizeof *v);
    if (v) { v->type = t; v->refs = 1; v->index = -1; }
    return v;
}

BpNode *bp_null(void) { return node(BP_NULL); }
BpNode *bp_bool(int b) { BpNode *v = node(BP_BOOL); if (v) v->u.i = b != 0; return v; }
BpNode *bp_int(int64_t i) { BpNode *v = node(BP_INT); if (v) v->u.i = i; return v; }
BpNode *bp_uid(uint64_t u) { BpNode *v = u > UINT32_MAX ? NULL : node(BP_UID); if (v) v->u.u = u; return v; }
BpNode *bp_array(void) { return node(BP_ARRAY); }
BpNode *bp_dict(void) { return node(BP_DICT); }

BpNode *bp_real(double d) {
    BpNode *v = node(BP_REAL);
    if (v) { memcpy(&v->u.r.bits, &d, 8); v->u.r.width = 8; }
    return v;
}

BpNode *bp_real32(uint32_t bits) {
    BpNode *v = node(BP_REAL);
    if (v) { v->u.r.bits = bits; v->u.r.width = 4; }
    return v;
}

static BpNode *bytes_node(BpType t, const uint8_t *p, size_t n) {
    BpNode *v;
    if (n == SIZE_MAX || !(v = node(t))) return NULL;
    if (!(v->u.s.p = malloc(n + 1))) { free(v); return NULL; }
    if (n) memcpy(v->u.s.p, p, n);
    v->u.s.p[n] = 0;
    v->u.s.n = n;
    return v;
}

BpNode *bp_data(const uint8_t *p, size_t n) { return bytes_node(BP_DATA, p, n); }

/* The length of the UTF-8 sequence at p (at most n bytes), or 0 if it is not a valid scalar value's shortest form. */
static size_t utf8_seq(const uint8_t *p, size_t n, uint32_t *cp) {
    uint32_t c = p[0], min;
    size_t len, i;
    if (c < 0x80) { *cp = c; return 1; }
    if (c >= 0xc2 && c <= 0xdf) { len = 2; c &= 0x1f; min = 0x80; }
    else if (c >= 0xe0 && c <= 0xef) { len = 3; c &= 0x0f; min = 0x800; }
    else if (c >= 0xf0 && c <= 0xf4) { len = 4; c &= 0x07; min = 0x10000; }
    else return 0;
    if (len > n) return 0;
    for (i = 1; i < len; i++) {
        if ((p[i] & 0xc0) != 0x80) return 0;
        c = c << 6 | (p[i] & 0x3f);
    }
    if (c < min || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) return 0;
    *cp = c;
    return len;
}

BpNode *bp_string(const char *s, size_t n) {
    const uint8_t *p = (const uint8_t *)s;
    size_t i = 0, k;
    uint32_t cp;
    while (i < n) {
        if (!(k = utf8_seq(p + i, n - i, &cp))) return NULL;
        i += k;
    }
    return bytes_node(BP_STRING, p, n);
}

static int append(BpNode *c, BpNode *v) {
    if (c->u.c.n == c->u.c.cap) {
        size_t cap = c->u.c.cap ? c->u.c.cap * 2 : 4;
        BpNode **m;
        if (cap > SIZE_MAX / sizeof *m || !(m = realloc(c->u.c.v, cap * sizeof *m))) return -1;
        c->u.c.v = m;
        c->u.c.cap = cap;
    }
    c->u.c.v[c->u.c.n++] = v;
    return 0;
}

BpNode *bp_retain(BpNode *v) {
    if (v) v->refs++;
    return v;
}

int bp_push(BpNode *array, BpNode *v) {
    if (!v || !array || array->type != BP_ARRAY || append(array, v)) { bp_free(v); return -1; }
    return 0;
}

int bp_set(BpNode *dict, const char *key, BpNode *v) {
    BpNode *k = NULL;
    if (!v || !dict || dict->type != BP_DICT || !key || !(k = bp_string(key, strlen(key))) || append(dict, k)) {
        bp_free(k);
        bp_free(v);
        return -1;
    }
    if (append(dict, v)) { dict->u.c.n--; bp_free(k); bp_free(v); return -1; }
    return 0;
}

void bp_free(BpNode *v) {
    size_t i;
    if (!v || --v->refs) return;
    if (v->type == BP_ARRAY || v->type == BP_DICT) {
        for (i = 0; i < v->u.c.n; i++) bp_free(v->u.c.v[i]);
        free(v->u.c.v);
    } else if (v->type == BP_STRING || v->type == BP_DATA) {
        free(v->u.s.p);
    }
    free(v);
}

BpType bp_type(const BpNode *v) { return v->type; }
int64_t bp_int_value(const BpNode *v) { return v->u.i; }
int bp_bool_value(const BpNode *v) { return (int)v->u.i; }
uint64_t bp_uid_value(const BpNode *v) { return v->u.u; }
int bp_real_width(const BpNode *v) { return v->u.r.width; }
uint64_t bp_real_bits(const BpNode *v) { return v->u.r.bits; }
int64_t bp_object_index(const BpNode *v) { return v->index; }

double bp_real_value(const BpNode *v) {
    double d;
    float f;
    uint32_t b32 = (uint32_t)v->u.r.bits;
    if (v->u.r.width == 4) { memcpy(&f, &b32, 4); return f; }
    memcpy(&d, &v->u.r.bits, 8);
    return d;
}

const uint8_t *bp_bytes(const BpNode *v, size_t *n) { *n = v->u.s.n; return v->u.s.p; }
size_t bp_count(const BpNode *v) { return v->type == BP_DICT ? v->u.c.n / 2 : v->u.c.n; }
BpNode *bp_at(const BpNode *a, size_t i) { return i < a->u.c.n ? a->u.c.v[i] : NULL; }
const BpNode *bp_key_at(const BpNode *d, size_t i) { return i < d->u.c.n / 2 ? d->u.c.v[2 * i] : NULL; }
BpNode *bp_value_at(const BpNode *d, size_t i) { return i < d->u.c.n / 2 ? d->u.c.v[2 * i + 1] : NULL; }

BpNode *bp_get(const BpNode *d, const char *key) {
    size_t i, n = strlen(key);
    for (i = 0; i + 1 < d->u.c.n; i += 2)
        if (d->u.c.v[i]->u.s.n == n && !memcmp(d->u.c.v[i]->u.s.p, key, n)) return d->u.c.v[i + 1];
    return NULL;
}

/* ---- reading ---- */

typedef struct {
    const uint8_t *b;
    size_t n, end;            /* end: where the offset table starts; no object reaches past it */
    uint64_t n_objs;
    unsigned osz, rsz;
    size_t table;
    uint8_t *state;           /* 0 unread, 1 a container being read, 2 read */
    BpNode **objs;
    char *why;
    size_t whysz;
    size_t budget;            /* object bytes not yet read: each object is charged once, so aliases can't multiply */
    int oom;
} Rd;

static int bad(Rd *r, const char *what, size_t at) {
    if (r->oom) snprintf(r->why, r->whysz, "out of memory");
    else snprintf(r->why, r->whysz, "malformed-bplist: %s at %lu", what, (unsigned long)at);
    return -1;
}

static int oom(Rd *r) { r->oom = 1; return bad(r, "", 0); }

static uint64_t be(const uint8_t *p, unsigned k) {
    uint64_t v = 0;
    unsigned i;
    for (i = 0; i < k; i++) v = v << 8 | p[i];
    return v;
}

/* The int object at pos, which must end by r->end: 1/2/4 bytes unsigned, 8 signed, 16 when it fits int64_t. */
static int read_int(Rd *r, size_t pos, int64_t *out, size_t *len, const char *what) {
    unsigned k;
    if (pos >= r->end || (r->b[pos] >> 4) != 1) return bad(r, what, pos);
    if ((r->b[pos] & 0xf) > 4) return bad(r, what, pos);
    k = 1u << (r->b[pos] & 0xf);
    if (k > r->end - pos - 1) return bad(r, what, pos);
    if (k == 16) {
        uint64_t hi = be(r->b + pos + 1, 8), lo = be(r->b + pos + 9, 8);
        if (hi != (lo >> 63 ? UINT64_MAX : 0)) return bad(r, what, pos);
        *out = (int64_t)lo;
    } else {
        *out = (int64_t)be(r->b + pos + 1, k);
    }
    *len = 1 + k;
    return 0;
}

/* A marker's count: its low nibble, or the int object after a 0xf nibble; then the count's first byte. */
static int read_count(Rd *r, size_t pos, uint64_t *count, size_t *body) {
    int64_t c;
    size_t len;
    if ((r->b[pos] & 0xf) != 0xf) { *count = r->b[pos] & 0xf; *body = pos + 1; return 0; }
    if (pos + 1 >= r->end || r->b[pos + 1] == 0x14 || read_int(r, pos + 1, &c, &len, "length") || c < 0)
        return bad(r, "length", pos);
    *count = (uint64_t)c;
    *body = pos + 1 + len;
    return 0;
}

static BpNode *read_obj(Rd *r, uint64_t ref, size_t at, unsigned depth);

static int charge(Rd *r, size_t pos, size_t extent) {
    if (extent > r->budget) return bad(r, "overlapping objects", pos);
    r->budget -= extent;
    return 0;
}

static int fits(Rd *r, size_t body, uint64_t count, unsigned unit) {
    return body <= r->end && count <= (r->end - body) / unit;
}

static BpNode *read_utf16(Rd *r, size_t pos, size_t body, uint64_t units) {
    const uint8_t *p = r->b + body;
    uint8_t *out, *o;
    size_t i;
    BpNode *v;
    if (!fits(r, body, units, 2)) { bad(r, "utf-16 string", pos); return NULL; }
    if (charge(r, pos, body + (size_t)units * 2 - pos)) return NULL;
    if (!(out = malloc(units * 3 + 1))) { oom(r); return NULL; }
    for (o = out, i = 0; i < units; i++) {
        uint32_t c = (uint32_t)p[2 * i] << 8 | p[2 * i + 1];
        if (c >= 0xdc00 && c <= 0xdfff) { free(out); bad(r, "utf-16 string", pos); return NULL; }
        if (c >= 0xd800 && c <= 0xdbff) {
            uint32_t lo = i + 1 < units ? (uint32_t)p[2 * i + 2] << 8 | p[2 * i + 3] : 0;
            if (lo < 0xdc00 || lo > 0xdfff) { free(out); bad(r, "utf-16 string", pos); return NULL; }
            c = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
            i++;
        }
        if (c < 0x80) *o++ = (uint8_t)c;
        else if (c < 0x800) { *o++ = (uint8_t)(0xc0 | c >> 6); *o++ = (uint8_t)(0x80 | (c & 0x3f)); }
        else if (c < 0x10000) {
            *o++ = (uint8_t)(0xe0 | c >> 12); *o++ = (uint8_t)(0x80 | (c >> 6 & 0x3f)); *o++ = (uint8_t)(0x80 | (c & 0x3f));
        } else {
            *o++ = (uint8_t)(0xf0 | c >> 18); *o++ = (uint8_t)(0x80 | (c >> 12 & 0x3f));
            *o++ = (uint8_t)(0x80 | (c >> 6 & 0x3f)); *o++ = (uint8_t)(0x80 | (c & 0x3f));
        }
    }
    v = bytes_node(BP_STRING, out, (size_t)(o - out));
    free(out);
    if (!v) oom(r);
    return v;
}

static void bad_marker(Rd *r, uint8_t m, size_t pos) {
    char what[16];
    snprintf(what, sizeof what, "marker %02x", m);
    bad(r, what, pos);
}

static BpNode *read_leaf(Rd *r, size_t pos) {
    uint8_t m = r->b[pos], hi = m >> 4;
    uint64_t count;
    size_t body, i, len;
    int64_t iv;
    BpNode *v = NULL;
    switch (hi) {
    case 0x0:
        if ((m == 0x00 || m == 0x08 || m == 0x09) && charge(r, pos, 1)) return NULL;
        if (m == 0x00) v = bp_null();
        else if (m == 0x08 || m == 0x09) v = bp_bool(m == 0x09);
        else { bad_marker(r, m, pos); return NULL; }
        break;
    case 0x1:
        if ((m & 0xf) > 4) { bad_marker(r, m, pos); return NULL; }
        if (read_int(r, pos, &iv, &len, "int") || charge(r, pos, len)) return NULL;
        v = bp_int(iv);
        break;
    case 0x2:
        if (m != 0x22 && m != 0x23) { bad_marker(r, m, pos); return NULL; }
        len = m == 0x22 ? 4 : 8;
        if (len > r->end - pos - 1) { bad(r, "real", pos); return NULL; }
        if (charge(r, pos, 1 + len)) return NULL;
        if ((v = node(BP_REAL))) { v->u.r.bits = be(r->b + pos + 1, (unsigned)len); v->u.r.width = (int)len; }
        break;
    case 0x4: case 0x5:
        if (read_count(r, pos, &count, &body)) return NULL;
        if (!fits(r, body, count, 1)) { bad(r, hi == 4 ? "data" : "ascii string", pos); return NULL; }
        if (charge(r, pos, body + (size_t)count - pos)) return NULL;
        if (hi == 5)
            for (i = 0; i < count; i++)
                if (r->b[body + i] >= 0x80) { bad(r, "ascii string", pos); return NULL; }
        v = bytes_node(hi == 4 ? BP_DATA : BP_STRING, r->b + body, (size_t)count);
        break;
    case 0x6:
        if (read_count(r, pos, &count, &body)) return NULL;
        return read_utf16(r, pos, body, count);
    case 0x8:
        len = (m & 0xf) + 1u;
        if (len > r->end - pos - 1) { bad(r, "uid", pos); return NULL; }
        if (charge(r, pos, 1 + len)) return NULL;
        for (i = 0; i + 4 < len; i++)
            if (r->b[pos + 1 + i]) { bad(r, "uid", pos); return NULL; }
        v = bp_uid(be(r->b + pos + 1 + (len > 4 ? len - 4 : 0), len > 4 ? 4u : (unsigned)len));
        break;
    default: bad_marker(r, m, pos); return NULL;
    }
    if (!v) oom(r);
    return v;
}

static BpNode *read_container(Rd *r, size_t pos, unsigned depth) {
    int dict = r->b[pos] >> 4 == 0xd;
    uint64_t count, i, k;
    size_t body;
    BpNode *v;
    if (read_count(r, pos, &count, &body)) return NULL;
    if (!fits(r, body, count, r->rsz * (dict ? 2u : 1u))) { bad(r, dict ? "dict" : "array", pos); return NULL; }
    k = dict ? count * 2 : count;
    if (charge(r, pos, body + (size_t)k * r->rsz - pos)) return NULL;
    if (!(v = node(dict ? BP_DICT : BP_ARRAY)) || (k && !(v->u.c.v = calloc((size_t)k, sizeof *v->u.c.v)))) {
        free(v);
        oom(r);
        return NULL;
    }
    v->u.c.n = v->u.c.cap = (size_t)k;
    for (i = 0; i < k; i++) {
        /* a dict's refs are all its keys, then all its values; it is held as key, value pairs */
        size_t slot = dict ? (i < count ? 2 * (size_t)i : 2 * (size_t)(i - count) + 1) : (size_t)i;
        size_t at = body + (size_t)i * r->rsz;
        BpNode *c = read_obj(r, be(r->b + at, r->rsz), at, depth + 1);
        if (!c) { bp_free(v); return NULL; }
        v->u.c.v[slot] = c;
        if (dict && i < count && c->type != BP_STRING) { bp_free(v); bad(r, "dict key", at); return NULL; }
    }
    return v;
}

static BpNode *read_obj(Rd *r, uint64_t ref, size_t at, unsigned depth) {
    size_t pos;
    uint8_t hi;
    BpNode *v;
    if (ref >= r->n_objs) { bad(r, "ref", at); return NULL; }
    if (r->state[ref] == 2 && r->objs[ref]) { r->objs[ref]->refs++; return r->objs[ref]; }
    if (r->state[ref] == 1) { bad(r, "cyclic container", at); return NULL; }
    if (r->state[ref] == 2) { bad(r, "shared container", at); return NULL; }
    pos = (size_t)be(r->b + r->table + (size_t)ref * r->osz, r->osz);
    if (pos < 8 || pos >= r->end) { bad(r, "offset", r->table + (size_t)ref * r->osz); return NULL; }
    hi = r->b[pos] >> 4;
    if (hi == 0xa || hi == 0xd) {
        if (depth > BP_MAX_DEPTH) { bad(r, "depth", pos); return NULL; }
        r->state[ref] = 1;
        v = read_container(r, pos, depth);
        r->state[ref] = 2;   /* even on failure: the read is over */
        if (v && !v->u.c.n) r->objs[ref] = v;
    } else {
        v = read_leaf(r, pos);
        if (v) { r->state[ref] = 2; r->objs[ref] = v; }
    }
    if (v) v->index = (int64_t)ref;
    return v;
}

int bp_read(const uint8_t *buf, size_t n, BpNode **root, char *why, size_t whysz) {
    Rd r;
    const uint8_t *t;
    uint64_t top, table;
    memset(&r, 0, sizeof r);
    r.b = buf;
    r.n = n;
    r.why = why;
    r.whysz = whysz;
    *root = NULL;
    if (n < 8 || memcmp(buf, "bplist00", 8)) { bad(&r, "header", 0); return 4; }
    if (n < 8 + 32) { bad(&r, "short file", 8); return 4; }
    t = buf + n - 32;
    r.osz = t[6];
    r.rsz = t[7];
    r.n_objs = be(t + 8, 8);
    top = be(t + 16, 8);
    table = be(t + 24, 8);
    if (r.osz < 1 || r.osz > 8 || r.rsz < 1 || r.rsz > 8 || r.n_objs < 1 || top >= r.n_objs) {
        bad(&r, "trailer", n - 32);
        return 4;
    }
    if (table < 9 || table > n - 32 || r.n_objs > (n - 32 - table) / r.osz) {
        bad(&r, "offset table", n - 32);
        return 4;
    }
    r.table = r.end = (size_t)table;
    r.budget = r.end - 8;
    if (!(r.state = calloc((size_t)r.n_objs, 1)) || !(r.objs = calloc((size_t)r.n_objs, sizeof *r.objs))) {
        free(r.state);
        oom(&r);
        return 4;
    }
    *root = read_obj(&r, top, n - 16, 0);
    free(r.state);
    free(r.objs);
    return *root ? 0 : 4;
}

/* ---- writing ---- */

typedef struct { uint8_t *p; size_t n, cap; int oom; } Buf;

static void put(Buf *b, const void *p, size_t k) {
    if (b->oom) return;
    if (k > b->cap - b->n) {
        size_t cap = b->cap ? b->cap : 256;
        uint8_t *m;
        while (k > cap - b->n) {
            if (cap > SIZE_MAX / 2) { b->oom = 1; return; }
            cap *= 2;
        }
        if (!(m = realloc(b->p, cap))) { b->oom = 1; return; }
        b->p = m;
        b->cap = cap;
    }
    memcpy(b->p + b->n, p, k);
    b->n += k;
}

static void put_be(Buf *b, uint64_t v, unsigned k) {
    uint8_t x[8];
    unsigned i;
    for (i = 0; i < k; i++) x[k - 1 - i] = (uint8_t)(v >> 8 * i);
    put(b, x, k);
}

static unsigned width(uint64_t v) { return v <= 0xff ? 1 : v <= 0xffff ? 2 : v <= 0xffffffffu ? 4 : 8; }

static void put_int(Buf *b, int64_t i) {
    unsigned k = i < 0 ? 8 : width((uint64_t)i);
    uint8_t m = (uint8_t)(0x10 | (k == 1 ? 0 : k == 2 ? 1 : k == 4 ? 2 : 3));
    put(b, &m, 1);
    put_be(b, (uint64_t)i, k);
}

static void put_marker(Buf *b, uint8_t hi, uint64_t count) {
    uint8_t m = (uint8_t)(hi << 4 | (count < 15 ? count : 15));
    put(b, &m, 1);
    if (count >= 15) put_int(b, (int64_t)count);
}

/* Every place a node appears, in depth-first order: occ[s] is the node at occurrence s; a container's children are
 * kids[kid0[s] ...]. */
typedef struct {
    const BpNode **occ;
    size_t *kid0, *kids, n, nk, cap, capk;
    int oom;
} Walk;

static size_t walk(Walk *w, const BpNode *v) {
    size_t s, i, base;
    if (w->oom) return 0;
    if (w->n == w->cap) {
        size_t cap = w->cap ? w->cap * 2 : 64;
        const BpNode **o;
        size_t *k;
        if (cap > SIZE_MAX / sizeof *k) { w->oom = 1; return 0; }
        if (!(o = realloc(w->occ, cap * sizeof *o))) { w->oom = 1; return 0; }
        w->occ = o;
        if (!(k = realloc(w->kid0, cap * sizeof *k))) { w->oom = 1; return 0; }
        w->kid0 = k;
        w->cap = cap;
    }
    s = w->n++;
    w->occ[s] = v;
    w->kid0[s] = 0;
    if (v->type != BP_ARRAY && v->type != BP_DICT) return s;
    if (v->u.c.n > w->capk - w->nk) {
        size_t cap = w->capk ? w->capk : 64, *k;
        while (v->u.c.n > cap - w->nk) {
            if (cap > SIZE_MAX / 2 / sizeof *k) { w->oom = 1; return 0; }
            cap *= 2;
        }
        if (!(k = realloc(w->kids, cap * sizeof *k))) { w->oom = 1; return 0; }
        w->kids = k;
        w->capk = cap;
    }
    base = w->kid0[s] = w->nk;
    w->nk += v->u.c.n;
    for (i = 0; i < v->u.c.n; i++) {
        size_t k = walk(w, v->u.c.v[i]);   /* walk may move w->kids */
        w->kids[base + i] = k;
    }
    return s;
}

/* A bottom-up merge sort of idx[0..n) by cmp: O(n log n) comparisons on any input, ties kept in order. */
static int msort(size_t *idx, size_t n, int (*cmp)(const Walk *, size_t, size_t), const Walk *w) {
    size_t *tmp, *a = idx, *b, width_, i;
    if (n < 2) return 0;
    if (n > SIZE_MAX / sizeof *tmp || !(tmp = malloc(n * sizeof *tmp))) return -1;
    b = tmp;
    for (width_ = 1; width_ < n; width_ *= 2) {
        for (i = 0; i < n; i += 2 * width_) {
            size_t lo = i, mid = i + width_ < n ? i + width_ : n, hi = i + 2 * width_ < n ? i + 2 * width_ : n;
            size_t x = lo, y = mid, o = lo;
            while (x < mid && y < hi) b[o++] = cmp(w, a[y], a[x]) < 0 ? a[y++] : a[x++];
            while (x < mid) b[o++] = a[x++];
            while (y < hi) b[o++] = a[y++];
        }
        { size_t *t = a; a = b; b = t; }
        if (width_ > SIZE_MAX / 2) break;
    }
    if (a != idx) memcpy(idx, a, n * sizeof *idx);
    free(tmp);
    return 0;
}

static int by_node(const Walk *w, size_t x, size_t y) {
    uintptr_t a = (uintptr_t)w->occ[x], b = (uintptr_t)w->occ[y];
    return a < b ? -1 : a > b;
}

static int by_content(const Walk *w, size_t x, size_t y) {
    const BpNode *a = w->occ[x], *b = w->occ[y];
    size_t n = a->u.s.n < b->u.s.n ? a->u.s.n : b->u.s.n;
    int c = n ? memcmp(a->u.s.p, b->u.s.p, n) : 0;
    return c ? c : a->u.s.n < b->u.s.n ? -1 : a->u.s.n > b->u.s.n;
}

static void put_string(Buf *b, const BpNode *v) {
    const uint8_t *p = v->u.s.p;
    size_t n = v->u.s.n, i, units = 0, k;
    uint32_t c;
    for (i = 0; i < n && p[i] < 0x80; i++) {}
    if (i == n) { put_marker(b, 0x5, n); put(b, p, n); return; }
    for (i = 0; i < n; i += k) { k = utf8_seq(p + i, n - i, &c); units += c >= 0x10000 ? 2 : 1; }
    put_marker(b, 0x6, units);
    for (i = 0; i < n; i += k) {
        k = utf8_seq(p + i, n - i, &c);
        if (c >= 0x10000) {
            put_be(b, 0xd800 + ((c - 0x10000) >> 10), 2);
            put_be(b, 0xdc00 + ((c - 0x10000) & 0x3ff), 2);
        } else {
            put_be(b, c, 2);
        }
    }
}

static void put_obj(Buf *b, const Walk *w, size_t s, const size_t *num, unsigned rsz) {
    const BpNode *v = w->occ[s];
    uint8_t m;
    size_t i, half;
    switch (v->type) {
    case BP_NULL: m = 0x00; put(b, &m, 1); break;
    case BP_BOOL: m = v->u.i ? 0x09 : 0x08; put(b, &m, 1); break;
    case BP_INT: put_int(b, v->u.i); break;
    case BP_REAL:
        m = v->u.r.width == 4 ? 0x22 : 0x23;
        put(b, &m, 1);
        put_be(b, v->u.r.bits, (unsigned)v->u.r.width);
        break;
    case BP_STRING: put_string(b, v); break;
    case BP_DATA: put_marker(b, 0x4, v->u.s.n); put(b, v->u.s.p, v->u.s.n); break;
    case BP_UID: {
        unsigned k = width(v->u.u);
        m = (uint8_t)(0x80 | (k - 1));
        put(b, &m, 1);
        put_be(b, v->u.u, k);
        break;
    }
    case BP_ARRAY:
        put_marker(b, 0xa, v->u.c.n);
        for (i = 0; i < v->u.c.n; i++) put_be(b, num[w->kids[w->kid0[s] + i]], rsz);
        break;
    case BP_DICT:
        half = v->u.c.n / 2;
        put_marker(b, 0xd, half);
        for (i = 0; i < half; i++) put_be(b, num[w->kids[w->kid0[s] + 2 * i]], rsz);
        for (i = 0; i < half; i++) put_be(b, num[w->kids[w->kid0[s] + 2 * i + 1]], rsz);
        break;
    }
}

int bp_write(const BpNode *root, uint8_t **out, size_t *nout) {
    Walk w;
    Buf b;
    size_t *canon = NULL, *idx = NULL, *num = NULL, *rep = NULL, *offs = NULL, i, j, nu = 0, nobj = 0, table;
    unsigned rsz, osz;
    uint64_t maxoff = 0;
    int rc = -1;
    memset(&w, 0, sizeof w);
    memset(&b, 0, sizeof b);
    *out = NULL;
    *nout = 0;
    walk(&w, root);
    if (w.oom) goto done;
    if (!(canon = malloc(w.n * sizeof *canon)) || !(idx = malloc(w.n * sizeof *idx)) ||
        !(num = malloc(w.n * sizeof *num)) || !(rep = malloc(w.n * sizeof *rep)))
        goto done;
    /* a node met again (a leaf the reader shared) is the object of its first occurrence */
    for (i = 0; i < w.n; i++) idx[i] = i;
    if (msort(idx, w.n, by_node, &w)) goto done;
    for (i = 0; i < w.n; i = j)
        for (j = i; j < w.n && w.occ[idx[j]] == w.occ[idx[i]]; j++) canon[idx[j]] = idx[i];
    /* and a string, among first occurrences, is the object of the first string with its bytes */
    for (i = 0; i < w.n; i++)
        if (canon[i] == i && w.occ[i]->type == BP_STRING) idx[nu++] = i;
    if (msort(idx, nu, by_content, &w)) goto done;
    for (i = 0; i < nu; i = j)
        for (j = i; j < nu && !by_content(&w, idx[j], idx[i]); j++) canon[idx[j]] = idx[i];
    for (i = 0; i < w.n; i++) {
        size_t c = canon[canon[i]];
        if (c == i) { rep[nobj] = i; num[i] = nobj++; }
        else num[i] = num[c];
    }
    rsz = width(nobj - 1);
    if (!(offs = malloc(nobj * sizeof *offs))) goto done;
    put(&b, "bplist00", 8);
    for (i = 0; i < nobj; i++) {
        offs[i] = b.n;
        put_obj(&b, &w, rep[i], num, rsz);
    }
    maxoff = offs[nobj - 1];
    osz = width(maxoff);
    table = b.n;
    for (i = 0; i < nobj; i++) put_be(&b, offs[i], osz);
    put(&b, "\0\0\0\0\0\0", 6);
    put_be(&b, osz, 1);
    put_be(&b, rsz, 1);
    put_be(&b, nobj, 8);
    put_be(&b, 0, 8);
    put_be(&b, table, 8);
    if (b.oom) goto done;
    *out = b.p;
    *nout = b.n;
    b.p = NULL;
    rc = 0;
done:
    free(b.p);
    free(canon);
    free(idx);
    free(num);
    free(rep);
    free(offs);
    free(w.occ);
    free(w.kid0);
    free(w.kids);
    return rc;
}
