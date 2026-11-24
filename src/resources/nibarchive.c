#include "nibarchive.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const uint8_t *b;
    size_t n, pos;
    char *why;
    size_t whysz;
} Cur;

static int bad(Cur *c, const char *what, size_t at) {
    snprintf(c->why, c->whysz, "malformed-nibarchive: %s at %lu", what, (unsigned long)at);
    return -1;
}

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t le64(const uint8_t *p) {
    return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}

/* 7 bits per byte, low group first; the high bit marks the last byte. */
static int varint(Cur *c, uint64_t *out) {
    size_t at = c->pos;
    unsigned shift = 0;
    uint64_t r = 0;
    for (;;) {
        uint8_t x;
        if (c->pos >= c->n || shift > 63) return bad(c, "varint", at);
        x = c->b[c->pos++];
        if (shift == 63 && (x & 0x7e)) return bad(c, "varint", at);
        r |= (uint64_t)(x & 0x7f) << shift;
        shift += 7;
        if (x & 0x80) { *out = r; return 0; }
    }
}

static int need(Cur *c, size_t k, const char *what, size_t at) {
    return k > c->n - c->pos ? bad(c, what, at) : 0;
}

/* A section's count and offset, checked against the file before anything is allocated from them. */
static int section(Cur *c, uint32_t count, uint32_t off, size_t min_record, const char *what) {
    if (off > c->n || (uint64_t)count * min_record > c->n - off) return bad(c, what, off);
    c->pos = off;
    return 0;
}

typedef struct { uint32_t key; RvType type; int64_t i; double f; const uint8_t *p; size_t len; uint32_t ref; } RawValue;

static int read_value(Cur *c, uint32_t n_keys, uint32_t n_objs, RawValue *v) {
    size_t at = c->pos;
    uint64_t k, len;
    uint8_t t;
    float f32;
    double f64;
    uint32_t u32;
    uint64_t u64;
    static const size_t width[] = { 1, 2, 4, 8, 0, 0, 4, 8 };
    if (varint(c, &k)) return -1;
    if (k >= n_keys) return bad(c, "key index", at);
    v->key = (uint32_t)k;
    if (need(c, 1, "value", at)) return -1;
    at = c->pos;
    t = c->b[c->pos++];
    if (t > RV_REF) {
        char what[32];
        snprintf(what, sizeof what, "value type %u", (unsigned)t);
        return bad(c, what, at);
    }
    v->type = (RvType)t;
    if (t <= RV_F64 && need(c, width[t], "value", at)) return -1;
    switch (v->type) {
    case RV_I8: v->i = (int8_t)c->b[c->pos]; break;
    case RV_I16: v->i = (int16_t)(uint16_t)(c->b[c->pos] | c->b[c->pos + 1] << 8); break;
    case RV_I32: v->i = (int32_t)le32(c->b + c->pos); break;
    case RV_I64: v->i = (int64_t)le64(c->b + c->pos); break;
    case RV_F32: u32 = le32(c->b + c->pos); memcpy(&f32, &u32, 4); v->f = f32; break;
    case RV_F64: u64 = le64(c->b + c->pos); memcpy(&f64, &u64, 8); v->f = f64; break;
    case RV_DATA:
        if (varint(c, &len)) return -1;
        if (len > c->n - c->pos) return bad(c, "data", at);
        v->p = c->b + c->pos;
        v->len = (size_t)len;
        c->pos += (size_t)len;
        return 0;
    case RV_REF:
        if (need(c, 4, "value", at)) return -1;
        v->ref = le32(c->b + c->pos);
        if (v->ref >= n_objs) return bad(c, "ref", at);
        c->pos += 4;
        return 0;
    default: break;
    }
    if (t <= RV_F64) c->pos += width[t];
    return 0;
}

int na_read(const uint8_t *buf, size_t n, RGraph *out, char *why, size_t whysz) {
    Cur c;
    uint32_t h[10], i, j;
    const char **keys = NULL, **classes = NULL;
    RawValue *raw = NULL;
    uint8_t *used = NULL;
    int rc = 4;
    memset(out, 0, sizeof *out);
    c.b = buf; c.n = n; c.pos = 0; c.why = why; c.whysz = whysz;
    if (n < 50 || memcmp(buf, "NIBArchive", 10)) { bad(&c, "header", 0); return 4; }
    for (i = 0; i < 10; i++) h[i] = le32(buf + 10 + 4 * i);
    out->format = RF_NIBARCHIVE;
    out->na_header[0] = h[0];
    out->na_header[1] = h[1];
    if (section(&c, h[2], h[3], 3, "objects") || section(&c, h[4], h[5], 1, "keys")
        || section(&c, h[6], h[7], 2, "values") || section(&c, h[8], h[9], 2, "classes"))
        goto done;

    c.pos = h[5];
    if (!(keys = calloc(h[4] ? h[4] : 1, sizeof *keys))) goto oom;
    for (i = 0; i < h[4]; i++) {
        uint64_t len;
        size_t at = c.pos;
        if (varint(&c, &len)) goto done;
        if (len > c.n - c.pos) { bad(&c, "key", at); goto done; }
        if (memchr(c.b + c.pos, 0, (size_t)len)) { bad(&c, "key NUL", at); goto done; }
        if (!(keys[i] = rg_intern(out, (const char *)c.b + c.pos, (size_t)len))) goto oom;
        c.pos += (size_t)len;
    }

    c.pos = h[9];
    if (!(classes = calloc(h[8] ? h[8] : 1, sizeof *classes))) goto oom;
    for (i = 0; i < h[8]; i++) {
        uint64_t len, extras;
        size_t at = c.pos, len_n;
        if (varint(&c, &len)) goto done;
        if (varint(&c, &extras)) goto done;
        if (extras > (c.n - c.pos) / 4) { bad(&c, "class extras", at); goto done; }
        c.pos += 4 * (size_t)extras;
        if (len > c.n - c.pos) { bad(&c, "class name", at); goto done; }
        len_n = len && !c.b[c.pos + len - 1] ? (size_t)len - 1 : (size_t)len;
        if (memchr(c.b + c.pos, 0, len_n)) { bad(&c, "class NUL", at); goto done; }
        if (!(classes[i] = rg_intern(out, (const char *)c.b + c.pos, len_n))) goto oom;
        c.pos += (size_t)len;
    }

    c.pos = h[7];
    if (!(raw = calloc(h[6] ? h[6] : 1, sizeof *raw))) goto oom;
    for (i = 0; i < h[6]; i++)
        if (read_value(&c, h[4], h[2], &raw[i])) goto done;

    c.pos = h[3];
    if (!(used = calloc(h[6] / 8 + 1, 1))) goto oom;
    for (i = 0; i < h[2]; i++) {
        uint64_t cls, first, count;
        size_t at = c.pos;
        if (varint(&c, &cls) || varint(&c, &first) || varint(&c, &count)) goto done;
        if (cls >= h[8]) { bad(&c, "class index", at); goto done; }
        if (first > h[6] || count > h[6] - first) { bad(&c, "object values", at); goto done; }
        if (rg_add_object(out, classes[cls]) < 0) goto oom;
        for (j = 0; j < count; j++) {
            uint32_t k = (uint32_t)first + j;
            const RawValue *r = &raw[k];
            RValue v;
            if (used[k / 8] & 1u << k % 8) { bad(&c, "object values", at); goto done; }
            used[k / 8] |= (uint8_t)(1u << k % 8);
            memset(&v, 0, sizeof v);
            v.key = keys[r->key];
            v.type = r->type;
            if (r->type == RV_F32 || r->type == RV_F64) v.u.f = r->f;
            else if (r->type == RV_DATA) { v.u.d.p = (uint8_t *)r->p; v.u.d.n = r->len; }
            else if (r->type == RV_REF) v.u.ref = r->ref;
            else v.u.i = r->i;
            if (rg_add_value(out, i, &v)) goto oom;
        }
    }
    rc = 0;
    goto done;
oom:
    snprintf(why, whysz, "out of memory reading a NIBArchive");
done:
    free(keys);
    free(classes);
    free(raw);
    free(used);
    if (rc) rg_free(out);
    return rc;
}
