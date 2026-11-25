#include "keyed.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KEYED_VERSION 100000
#define NEXT_OID 1000000

/* ---- shared ---- */

#define SHOWBUF 161

/* At most 40 bytes of a name for a message, every byte outside printable ASCII as \xHH. */
static const char *show(char *buf, const char *s) {
    size_t i, o = 0;
    for (i = 0; s[i] && i < 40; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c >= 0x20 && c < 0x7f) buf[o++] = (char)c;
        else o += (size_t)snprintf(buf + o, SHOWBUF - o, "\\x%02x", c);
    }
    buf[o] = 0;
    return buf;
}

static int utf8_valid(const uint8_t *p, size_t n) {
    size_t i = 0, k, j;
    uint32_t c;
    while (i < n) {
        if (p[i] < 0x80) { i++; continue; }
        if (p[i] >= 0xc2 && p[i] <= 0xdf) k = 2, c = p[i] & 0x1f;
        else if (p[i] >= 0xe0 && p[i] <= 0xef) k = 3, c = p[i] & 0x0f;
        else if (p[i] >= 0xf0 && p[i] <= 0xf4) k = 4, c = p[i] & 0x07;
        else return 0;
        if (k > n - i) return 0;
        for (j = 1; j < k; j++) {
            if ((p[i + j] & 0xc0) != 0x80) return 0;
            c = c << 6 | (p[i + j] & 0x3f);
        }
        if ((k == 3 && c < 0x800) || (k == 4 && (c < 0x10000 || c > 0x10ffff)) || (c >= 0xd800 && c <= 0xdfff)) return 0;
        i += k;
    }
    return 1;
}

/* Sorts v[0..n) by strcmp (a merge sort, so no input is quadratic) and returns a name that occurs twice, or NULL;
 * *oom is set when the scratch array cannot be had. */
static const char *repeated(const char **v, size_t n, int *oom) {
    const char **a = v, **b, **t;
    size_t w, i, lo, mid, hi, x, y;
    *oom = 0;
    if (n < 2) return NULL;
    if (!(b = malloc(n * sizeof *b))) { *oom = 1; return NULL; }
    for (w = 1; w < n; w *= 2) {
        for (lo = 0; lo < n; lo += 2 * w) {
            mid = lo + w < n ? lo + w : n;
            hi = lo + 2 * w < n ? lo + 2 * w : n;
            for (i = lo, x = lo, y = mid; i < hi; i++)
                b[i] = (x < mid && (y >= hi || strcmp(a[x], a[y]) <= 0)) ? a[x++] : a[y++];
        }
        t = a; a = b; b = t;
    }
    if (a != v) { memcpy(v, a, n * sizeof *v); b = a; }
    free(b);
    for (i = 1; i < n; i++)
        if (!strcmp(v[i - 1], v[i])) return v[i];
    return NULL;
}

static int is_named(const char *cls, const char *const *names) {
    for (; *names; names++)
        if (!strcmp(cls, *names)) return 1;
    return 0;
}
static const char *const LISTS[] = { "NSArray", "NSMutableArray", "NSSet", "NSMutableSet", NULL };
static const char *const DICTS[] = { "NSDictionary", "NSMutableDictionary", NULL };
static const char *const ARRAYS[] = { "NSArray", "NSMutableArray", NULL };
static const char *const SCALARS[] = { "NSNumber", "NSString", "NSData", NULL };
static const char *const SYNTH_KEYS[] = { "NSFramework", "NSFontManager", "NSNextOid", "NSClassesKeys", "NSClassesValues",
                                          "NSNamesKeys", "NSNamesValues", NULL };

/* ---- graph to archive ---- */

typedef struct {
    const RGraph *g;
    char *why;
    size_t whysz;
    int rc;                   /* 0, 1 unencodable, 4 out of memory */
    int nib;                  /* the graph came from a NIBArchive, so the mapping rules apply */
    size_t *entry_of;         /* per chain (one more for a built-in NSArray): its class entry, or SIZE_MAX */
    size_t *order;            /* class entries: chain indexes, in first-use order */
    size_t n_classes;
    size_t nsarray;           /* the chain index NSArray's entry uses */
    BpNode *synth;            /* objects made for NSIBObjectData, numbered from synth_base */
    size_t synth_base, n_synth;
    char sb[SHOWBUF];
} W;

static BpNode *unencodable(W *w, const char *fmt, ...) {
    va_list ap;
    int k;
    if (w->rc) return NULL;
    w->rc = 1;
    k = snprintf(w->why, w->whysz, "unencodable: ");
    if (k >= 0 && (size_t)k < w->whysz) {
        va_start(ap, fmt);
        vsnprintf(w->why + k, w->whysz - (size_t)k, fmt, ap);
        va_end(ap);
    }
    return NULL;
}

static BpNode *oom(W *w) {
    if (!w->rc) {
        w->rc = 4;
        snprintf(w->why, w->whysz, "out of memory");
    }
    return NULL;
}

static BpNode *made(W *w, BpNode *v) { return v ? v : oom(w); }

static int set(W *w, BpNode *d, const char *key, BpNode *v) {
    if (!v) return -1;
    if (bp_set(d, key, v)) { oom(w); return -1; }
    return 0;
}

static int push(W *w, BpNode *a, BpNode *v) {
    if (!v) return -1;
    if (bp_push(a, v)) { oom(w); return -1; }
    return 0;
}

static BpNode *string(W *w, const uint8_t *p, size_t n, uint32_t obj, const char *what) {
    if (!utf8_valid(p, n)) return unencodable(w, "@%lu %s is not UTF-8", (unsigned long)obj, what);
    return made(w, bp_string((const char *)p, n));
}

static BpNode *uid(W *w, uint64_t u) { return made(w, bp_uid(u)); }

static BpNode *value(W *w, uint32_t obj, const RValue *v) {
    const RGraph *g = w->g;
    BpNode *a;
    size_t i;
    switch (v->type) {
    case RV_I8: case RV_I16: case RV_I32: case RV_I64: return made(w, bp_int(v->u.i));
    case RV_FALSE: case RV_TRUE: return made(w, bp_bool(v->type == RV_TRUE));
    case RV_F32: return made(w, bp_real32(v->u.f32));
    case RV_F64: return made(w, bp_real(v->u.f));
    case RV_DATA: return made(w, bp_data(v->u.d.p, v->u.d.n));
    case RV_STRING: return string(w, v->u.d.p, v->u.d.n, obj, show(w->sb, v->key));
    case RV_NIL: return uid(w, 0);
    case RV_REF:
        if (!v->u.ref)
            return unencodable(w, "@%lu %s refers to @0, the archive's top, which nothing in a keyed archive can refer to",
                               (unsigned long)obj, show(w->sb, v->key));
        if (v->u.ref >= g->n_objs)
            return unencodable(w, "@%lu %s refers to @%lu, past the last object", (unsigned long)obj, show(w->sb, v->key),
                               (unsigned long)v->u.ref);
        return uid(w, v->u.ref);
    case RV_UID_ARRAY:
        if (!(a = made(w, bp_array()))) return NULL;
        for (i = 0; i < v->u.refs.n; i++) {
            if (v->u.refs.v[i] >= g->n_objs) {
                bp_free(a);
                return unencodable(w, "@%lu %s refers to @%lu, past the last object", (unsigned long)obj,
                                   show(w->sb, v->key), (unsigned long)v->u.refs.v[i]);
            }
            if (push(w, a, uid(w, v->u.refs.v[i]))) { bp_free(a); return NULL; }
        }
        return a;
    }
    return unencodable(w, "@%lu %s has an unknown type", (unsigned long)obj, show(w->sb, v->key));
}

/* An object a keyed archive holds as a plain plist value, not a dict: every NIBArchive NSNumber, NSString and NSData,
 * and every bare object of a keyed graph. */
static int is_scalar(const W *w, const RObject *o);

/* A NIBArchive NSString whose text is "$null", which a keyed archive cannot hold bare: a ref to it decodes as nil. */
static int null_text(const RObject *o) {
    return !strcmp(o->cls, "NSString") && o->n_vals == 1 && !strcmp(o->vals[0].key, "NS.bytes") &&
           o->vals[0].type == RV_DATA && o->vals[0].u.d.n == 5 &&
           !memcmp(o->vals[0].u.d.p, "$null", 5);
}

static int is_scalar(const W *w, const RObject *o) {
    return w->nib ? is_named(o->cls, SCALARS) && !null_text(o) : o->bare;
}

static BpNode *scalar(W *w, uint32_t i) {
    const RObject *o = &w->g->objs[i];
    const RValue *v = o->n_vals == 1 ? &o->vals[0] : NULL;
    if (!strcmp(o->cls, "NSNumber")) {
        if (v && !strcmp(v->key, "NS.intval") && v->type <= RV_I64) return made(w, bp_int(v->u.i));
        if (v && !strcmp(v->key, "NS.boolval") && (v->type == RV_TRUE || v->type == RV_FALSE))
            return made(w, bp_bool(v->type == RV_TRUE));
        if (v && (!strcmp(v->key, "NS.dblval") || !strcmp(v->key, "NS.floatval"))) {
            if (v->type == RV_F64) return made(w, bp_real(v->u.f));
            if (v->type == RV_F32) return made(w, bp_real32(v->u.f32));
        }
        return unencodable(w, "@%lu NSNumber holds no single NS.intval, NS.boolval, NS.dblval or NS.floatval",
                           (unsigned long)i);
    }
    if (!strcmp(o->cls, "NSString")) {
        if (v && !strcmp(v->key, "NS.bytes") && (v->type == RV_DATA || v->type == RV_STRING))
            return string(w, v->u.d.p, v->u.d.n, i, "NS.bytes");
        return unencodable(w, "@%lu NSString holds no single NS.bytes", (unsigned long)i);
    }
    if (!strcmp(o->cls, "NSData")) {
        if (v && !strcmp(v->key, "NS.bytes") && v->type == RV_DATA) return made(w, bp_data(v->u.d.p, v->u.d.n));
        return unencodable(w, "@%lu NSData holds no single NS.bytes", (unsigned long)i);
    }
    return unencodable(w, "@%lu is bare, but a %s is never a plain plist value", (unsigned long)i, show(w->sb, o->cls));
}

static size_t class_uid(const W *w, size_t chain) { return w->g->n_objs + w->entry_of[chain]; }

/* An NSArray dict whose members are refs[0..n). */
static BpNode *array_dict(W *w, const uint32_t *refs, size_t n) {
    BpNode *d = made(w, bp_dict()), *a;
    size_t i;
    if (!d) return NULL;
    if (set(w, d, "$class", uid(w, class_uid(w, w->nsarray))) || !(a = made(w, bp_array()))) { bp_free(d); return NULL; }
    for (i = 0; i < n; i++)
        if (push(w, a, uid(w, refs[i]))) { bp_free(a); bp_free(d); return NULL; }
    if (set(w, d, "NS.objects", a)) { bp_free(d); return NULL; }
    return d;
}

/* The UINibEncoderEmptyKey values of object i as refs; NULL with *n 0 when it has none (or on failure, w->rc set). */
static uint32_t *members(W *w, uint32_t i, size_t *n) {
    const RObject *o = &w->g->objs[i];
    uint32_t *r;
    size_t j, k = 0;
    *n = 0;
    for (j = 0; j < o->n_vals; j++) k += !strcmp(o->vals[j].key, "UINibEncoderEmptyKey");
    if (!k) return NULL;
    if (!(r = malloc(k * sizeof *r))) { oom(w); return NULL; }
    for (j = 0; j < o->n_vals; j++) {
        const RValue *v = &o->vals[j];
        if (strcmp(v->key, "UINibEncoderEmptyKey")) continue;
        if (v->type != RV_REF || !v->u.ref || v->u.ref >= w->g->n_objs) {
            free(r);
            unencodable(w, "@%lu %s has a UINibEncoderEmptyKey value that is not a ref to an object", (unsigned long)i,
                        show(w->sb, o->cls));
            return NULL;
        }
        r[(*n)++] = v->u.ref;
    }
    return r;
}

/* NS.objects, and for a dictionary NS.keys before it, from object i's UINibEncoderEmptyKey values. */
static int collection(W *w, uint32_t i, BpNode *d, const char ***keys, size_t *n_keys) {
    const RObject *o = &w->g->objs[i];
    size_t n, j;
    uint32_t *r = members(w, i, &n);
    int dict = is_named(o->cls, DICTS);
    BpNode *ka = NULL, *oa = NULL;
    if (w->rc) return -1;
    if (dict && n % 2) {
        free(r);
        unencodable(w, "@%lu %s has an odd number (%lu) of UINibEncoderEmptyKey values", (unsigned long)i,
                    show(w->sb, o->cls), (unsigned long)n);
        return -1;
    }
    if ((dict && !(ka = made(w, bp_array()))) || !(oa = made(w, bp_array()))) goto fail;
    for (j = 0; j < n; j++)
        if (push(w, dict && !(j % 2) ? ka : oa, uid(w, r[j]))) goto fail;
    free(r);
    if (dict) {
        (*keys)[(*n_keys)++] = "NS.keys";
        if (set(w, d, "NS.keys", ka)) { bp_free(oa); return -1; }
    }
    (*keys)[(*n_keys)++] = "NS.objects";
    return set(w, d, "NS.objects", oa);
fail:
    free(r);
    bp_free(ka);
    bp_free(oa);
    return -1;
}

/* NSIBObjectData's fields 10.9's nib loader wants and a modern nib leaves out, each only when absent. */
static int synthesize(W *w, uint32_t i, BpNode *d, const char ***keys, size_t *n_keys) {
    const RGraph *g = w->g;
    const RValue *ok = rg_get(g, i, "NSObjectsKeys");
    uint32_t *r = NULL, *names;
    size_t n = 0, j, k;
    char buf[32];
    if (ok && ok->type == RV_REF && ok->u.ref && ok->u.ref < g->n_objs && is_named(g->objs[ok->u.ref].cls, ARRAYS)) {
        r = members(w, ok->u.ref, &n);
        if (w->rc) return -1;
    } else if (ok && ok->type != RV_NIL) {
        unencodable(w, "@%lu NSIBObjectData's NSObjectsKeys is not a ref to an array", (unsigned long)i);
        return -1;
    }
    for (k = 0; SYNTH_KEYS[k]; k++) {
        const char *key = SYNTH_KEYS[k];
        BpNode *v;
        if (rg_get(g, i, key)) continue;
        (*keys)[(*n_keys)++] = key;
        if (!strcmp(key, "NSFontManager")) v = uid(w, 0);
        else if (!strcmp(key, "NSNextOid")) v = made(w, bp_int(NEXT_OID));
        else {
            BpNode *obj;
            v = uid(w, w->synth_base + w->n_synth);
            if (!strcmp(key, "NSFramework")) obj = made(w, bp_string("IBCocoaFramework", 16));
            else if (!strcmp(key, "NSNamesKeys")) obj = array_dict(w, r, n);
            else if (!strcmp(key, "NSNamesValues")) {
                if (!(names = malloc((n ? n : 1) * sizeof *names))) { bp_free(v); free(r); oom(w); return -1; }
                for (j = 0; j < n; j++) names[j] = (uint32_t)(w->synth_base + w->n_synth + 1 + j);
                obj = array_dict(w, names, n);
                free(names);
            } else
                obj = array_dict(w, NULL, 0);
            if (push(w, w->synth, obj)) { bp_free(v); free(r); return -1; }
            w->n_synth++;
            if (!strcmp(key, "NSNamesValues"))
                for (j = 0; j < n; j++) {
                    snprintf(buf, sizeof buf, "obj%lu", (unsigned long)j);
                    if (push(w, w->synth, made(w, bp_string(buf, strlen(buf))))) { bp_free(v); free(r); return -1; }
                    w->n_synth++;
                }
        }
        if (set(w, d, key, v)) { free(r); return -1; }
    }
    free(r);
    return 0;
}

static int check_keys(W *w, const char **keys, size_t n, const char *where) {
    int no_memory;
    const char *dup = repeated(keys, n, &no_memory);
    if (no_memory) { oom(w); return -1; }
    if (dup) { unencodable(w, "%s would hold the key %s twice", where, show(w->sb, dup)); return -1; }
    return 0;
}

/* A dict of object i's values (object 0's are $top's), after the NIBArchive rules when they apply. */
static BpNode *dict(W *w, uint32_t i) {
    const RObject *o = &w->g->objs[i];
    const char **keys;
    char where[64];
    size_t n_keys = 0, j;
    int list = 0, done = 0;
    BpNode *d;
    if (!(keys = malloc((o->n_vals + 16) * sizeof *keys))) return oom(w);
    if (!(d = made(w, bp_dict()))) { free(keys); return NULL; }
    if (i) {
        keys[n_keys++] = "$class";
        if (set(w, d, "$class", uid(w, class_uid(w, (size_t)(rg_chain(w->g, o->cls) - w->g->chains))))) goto fail;
    }
    if (w->nib && i) list = is_named(o->cls, LISTS) || is_named(o->cls, DICTS);
    /* NSKeyedArchiver's own forms: the text or bytes inline under NS.string or NS.data */
    if (w->nib && i && (!strcmp(o->cls, "NSMutableString") || !strcmp(o->cls, "NSMutableData") || null_text(o))) {
        int text = strcmp(o->cls, "NSMutableData") != 0;
        const RValue *v = o->n_vals == 1 && !strcmp(o->vals[0].key, "NS.bytes") && o->vals[0].type == RV_DATA ? o->vals
                        : NULL;
        if (!v) { unencodable(w, "@%lu %s holds no single NS.bytes", (unsigned long)i, o->cls); goto fail; }
        keys[n_keys++] = text ? "NS.string" : "NS.data";
        if (set(w, d, keys[n_keys - 1], text ? string(w, v->u.d.p, v->u.d.n, i, "NS.bytes")
                                                  : made(w, bp_data(v->u.d.p, v->u.d.n)))) goto fail;
        free(keys);
        return d;
    }
    for (j = 0; j < o->n_vals; j++) {
        const RValue *v = &o->vals[j];
        if (w->nib && !strcmp(v->key, "NSInlinedValue")) continue;
        if (w->nib && !strcmp(v->key, "UINibEncoderEmptyKey")) {
            if (!list) {
                unencodable(w, "@%lu %s has UINibEncoderEmptyKey values, which only arrays, sets and dictionaries hold",
                            (unsigned long)i, show(w->sb, o->cls));
                goto fail;
            }
            if (!done && collection(w, i, d, &keys, &n_keys)) goto fail;
            done = 1;
            continue;
        }
        if (!utf8_valid((const uint8_t *)v->key, strlen(v->key))) {
            unencodable(w, "@%lu has a key that is not UTF-8: %s", (unsigned long)i, show(w->sb, v->key));
            goto fail;
        }
        keys[n_keys++] = v->key;
        if (set(w, d, v->key, value(w, i, v))) goto fail;
    }
    if (list && !done && collection(w, i, d, &keys, &n_keys)) goto fail;
    if (w->nib && i && !strcmp(o->cls, "NSIBObjectData") && synthesize(w, i, d, &keys, &n_keys)) goto fail;
    if (i) snprintf(where, sizeof where, "@%lu", (unsigned long)i);
    else snprintf(where, sizeof where, "$top");
    if (check_keys(w, keys, n_keys, where)) goto fail;
    free(keys);
    return d;
fail:
    free(keys);
    bp_free(d);
    return NULL;
}

/* Gives each class one entry, in first use order; refuses a class with no resolved chain. */
static int classes(W *w) {
    const RGraph *g = w->g;
    size_t i, c, k;
    int synth = 0;
    if (!(w->entry_of = malloc((g->n_chains + 1) * sizeof *w->entry_of)) ||
        !(w->order = malloc((g->n_chains + 1) * sizeof *w->order))) { oom(w); return -1; }
    for (c = 0; c <= g->n_chains; c++) w->entry_of[c] = SIZE_MAX;
    for (i = 1; i < g->n_objs; i++) {
        const RObject *o = &g->objs[i];
        const RChain *ch;
        if (is_scalar(w, o)) continue;
        if (!(ch = rg_chain(g, o->cls)) || !ch->resolved) {
            unencodable(w, "unresolved chain for %s", show(w->sb, o->cls));
            return -1;
        }
        c = (size_t)(ch - g->chains);
        if (w->entry_of[c] == SIZE_MAX) { w->entry_of[c] = w->n_classes; w->order[w->n_classes++] = c; }
        if (w->nib && !strcmp(o->cls, "NSIBObjectData"))
            for (k = 3; SYNTH_KEYS[k]; k++) synth |= !rg_get(g, (uint32_t)i, SYNTH_KEYS[k]);
    }
    w->nsarray = g->n_chains;
    if (synth) {
        const RChain *ch = rg_chain(g, "NSArray");
        if (ch && !ch->resolved) { unencodable(w, "unresolved chain for NSArray"); return -1; }
        if (ch) w->nsarray = (size_t)(ch - g->chains);
        if (w->entry_of[w->nsarray] == SIZE_MAX) { w->entry_of[w->nsarray] = w->n_classes; w->order[w->n_classes++] = w->nsarray; }
    }
    return 0;
}

static BpNode *class_entry(W *w, size_t c) {
    static const char *const nsarray[] = { "NSArray", "NSObject" };
    const RGraph *g = w->g;
    const char *const *chain = c < g->n_chains ? (const char *const *)g->chains[c].chain : nsarray;
    size_t n = c < g->n_chains ? g->chains[c].n_chain : 2, j;
    BpNode *d = made(w, bp_dict()), *a;
    if (!d) return NULL;
    for (j = 0; j < n; j++)
        if (!utf8_valid((const uint8_t *)chain[j], strlen(chain[j]))) {
            bp_free(d);
            return unencodable(w, "the chain of %s names a class that is not UTF-8", show(w->sb, chain[0]));
        }
    if (set(w, d, "$classname", made(w, bp_string(chain[0], strlen(chain[0])))) || !(a = made(w, bp_array()))) {
        bp_free(d);
        return NULL;
    }
    for (j = 0; j < n; j++)
        if (push(w, a, made(w, bp_string(chain[j], strlen(chain[j]))))) { bp_free(a); bp_free(d); return NULL; }
    if (set(w, d, "$classes", a)) { bp_free(d); return NULL; }
    if (c < g->n_chains && g->chains[c].n_hints) {
        const RChain *ch = &g->chains[c];
        if (!(a = made(w, bp_array()))) { bp_free(d); return NULL; }
        for (j = 0; j < ch->n_hints; j++) {
            if (!utf8_valid((const uint8_t *)ch->hints[j], strlen(ch->hints[j]))) {
                bp_free(a);
                bp_free(d);
                return unencodable(w, "the class hints of %s name a class that is not UTF-8", show(w->sb, chain[0]));
            }
            if (push(w, a, made(w, bp_string(ch->hints[j], strlen(ch->hints[j]))))) { bp_free(a); bp_free(d); return NULL; }
        }
        if (set(w, d, "$classhints", a)) { bp_free(d); return NULL; }
    }
    return d;
}

int ka_stores(const RGraph *g, uint32_t obj) {
    W w;
    memset(&w, 0, sizeof w);
    w.g = g;
    w.nib = g->format == RF_NIBARCHIVE;
    return obj > 0 && obj < g->n_objs && !is_scalar(&w, &g->objs[obj]);
}

int ka_from_graph(const RGraph *g, BpNode **archive, char *why, size_t whysz) {
    W w;
    BpNode *root = NULL, *objs;
    size_t i;
    memset(&w, 0, sizeof w);
    w.g = g; w.why = why; w.whysz = whysz;
    w.nib = g->format == RF_NIBARCHIVE;
    *archive = NULL;
    if (!g->n_objs) { unencodable(&w, "the graph has no objects"); goto done; }
    if (strcmp(g->objs[0].cls, "NSObject") || g->objs[0].bare) {
        unencodable(&w, "@0 is %s%s, but a keyed archive's top is a plain NSObject", g->objs[0].bare ? "a bare " : "",
                    show(w.sb, g->objs[0].cls));
        goto done;
    }
    if (classes(&w)) goto done;
    w.synth_base = g->n_objs + w.n_classes;
    if (!(w.synth = made(&w, bp_array())) || !(root = made(&w, bp_dict()))) goto done;
    if (set(&w, root, "$version", made(&w, bp_int(KEYED_VERSION))) ||
        set(&w, root, "$archiver", made(&w, bp_string("NSKeyedArchiver", 15))) || set(&w, root, "$top", dict(&w, 0)) ||
        !(objs = made(&w, bp_array())))
        goto done;
    if (set(&w, root, "$objects", objs) || push(&w, objs, made(&w, bp_string("$null", 5)))) goto done;
    for (i = 1; i < g->n_objs; i++)
        if (push(&w, objs, is_scalar(&w, &g->objs[i]) ? scalar(&w, (uint32_t)i) : dict(&w, (uint32_t)i))) goto done;
    for (i = 0; i < w.n_classes; i++)
        if (push(&w, objs, class_entry(&w, w.order[i]))) goto done;
    for (i = 0; i < w.n_synth; i++)
        if (push(&w, objs, bp_retain(bp_at(w.synth, i)))) goto done;
done:
    free(w.entry_of);
    free(w.order);
    bp_free(w.synth);
    if (w.rc) { bp_free(root); return w.rc; }
    *archive = root;
    return 0;
}

/* ---- archive to graph ---- */

typedef struct { const char *name; int copied; } Slot;

typedef struct {
    RGraph *g;
    char *why;
    size_t whysz;
    int oom;
    Slot *slots;              /* per plist object index */
    size_t n_slots;
    size_t budget, limit;     /* bytes left, and the bytes allowed, for copying a value the plist shares */
    const BpNode *objs;       /* $objects */
    size_t n;
    uint32_t *gidx;           /* per $objects index: its graph object, or CLASS_ENTRY */
    const char **entry_cls;   /* per $objects index: a class entry's interned name */
    const char *names[10];    /* NSObject, NSString, NSNumber, NSData, NS.bytes, ... once each */
    char sb[SHOWBUF];
} R;
#define CLASS_ENTRY UINT32_MAX

enum { N_NSOBJECT, N_NSSTRING, N_NSNUMBER, N_NSDATA, N_BYTES, N_INTVAL, N_BOOLVAL, N_DBLVAL, N_FLOATVAL };
static const char *const FIXED[] = { "NSObject", "NSString", "NSNumber", "NSData", "NS.bytes", "NS.intval", "NS.boolval",
                                     "NS.dblval", "NS.floatval" };

static int rfail(R *r, const char *fmt, ...) {
    va_list ap;
    int k = snprintf(r->why, r->whysz, "malformed-keyed: ");
    if (k >= 0 && (size_t)k < r->whysz) {
        va_start(ap, fmt);
        vsnprintf(r->why + k, r->whysz - (size_t)k, fmt, ap);
        va_end(ap);
    }
    return -1;
}

static int room(R *r) {
    r->oom = 1;
    snprintf(r->why, r->whysz, "out of memory");
    return -1;
}

static const char *fixed(R *r, int which) {
    if (!r->names[which] && !(r->names[which] = rg_intern(r->g, FIXED[which], strlen(FIXED[which])))) room(r);
    return r->names[which];
}

static Slot *slot(R *r, const BpNode *v) {
    int64_t idx = bp_object_index(v);
    if (idx < 0) return NULL;
    if ((uint64_t)idx >= r->n_slots) {
        size_t cap = r->n_slots ? r->n_slots : 64;
        Slot *s;
        while (cap <= (uint64_t)idx) cap *= 2;
        if (!(s = realloc(r->slots, cap * sizeof *s))) return NULL;
        memset(s + r->n_slots, 0, (cap - r->n_slots) * sizeof *s);
        r->slots = s;
        r->n_slots = cap;
    }
    return &r->slots[idx];
}

/* A string node as an interned name, once per plist object. */
static const char *name_of(R *r, const BpNode *v, const char *what) {
    size_t n;
    const char *p = (const char *)bp_bytes(v, &n);
    Slot *s = slot(r, v);
    if (bp_object_index(v) >= 0 && !s) { room(r); return NULL; }
    if (s && s->name) return s->name;
    if (memchr(p, 0, n)) { rfail(r, "%s holds a NUL", what); return NULL; }
    if (!(p = rg_intern(r->g, p, n))) { room(r); return NULL; }
    if (s) s->name = p;
    return p;
}

/* Charges a copy of n bytes from v: the first copy of each plist object is free, later ones come from the budget. */
static int charge(R *r, const BpNode *v, size_t n) {
    Slot *s = slot(r, v);
    if (bp_object_index(v) >= 0 && !s) return room(r);
    if (s && !s->copied) { s->copied = 1; return 0; }
    if (n > r->budget) return rfail(r, "values shared so often that copying them would pass %lu bytes", (unsigned long)r->limit);
    r->budget -= n;
    return 0;
}

static const char *const TYPE_NAMES[] = { "null", "bool", "int", "real", "string", "data", "uid", "array", "dict" };

/* A UID's graph object; 0 for UID 0, the null. */
static int ref_of(R *r, const BpNode *u, uint32_t *out, const char *where) {
    uint64_t v = bp_uid_value(u);
    if (v >= r->n) return rfail(r, "%s: uid %llu is past the last object, %lu", where, (unsigned long long)v,
                                (unsigned long)(r->n - 1));
    if (r->gidx[v] == CLASS_ENTRY) return rfail(r, "%s: uid %llu names a class entry", where, (unsigned long long)v);
    *out = r->gidx[v];
    return 0;
}

static int add_value(R *r, uint32_t obj, const char *key, const BpNode *v, const char *where) {
    RValue rv;
    size_t i, n;
    uint64_t bits;
    int rc;
    memset(&rv, 0, sizeof rv);
    rv.key = key;
    switch (bp_type(v)) {
    case BP_UID:
        if (ref_of(r, v, &rv.u.ref, where)) return -1;
        rv.type = rv.u.ref ? RV_REF : RV_NIL;
        break;
    case BP_INT: rv.type = RV_I64; rv.u.i = bp_int_value(v); break;
    case BP_BOOL: rv.type = bp_bool_value(v) ? RV_TRUE : RV_FALSE; break;
    case BP_REAL:
        bits = bp_real_bits(v);
        if (bp_real_width(v) == 4) { rv.type = RV_F32; rv.u.f32 = (uint32_t)bits; }
        else { rv.type = RV_F64; memcpy(&rv.u.f, &bits, 8); }
        break;
    case BP_STRING: case BP_DATA:
        rv.type = bp_type(v) == BP_STRING ? RV_STRING : RV_DATA;
        rv.u.d.p = (uint8_t *)bp_bytes(v, &rv.u.d.n);
        if (charge(r, v, rv.u.d.n)) return -1;
        break;
    case BP_ARRAY:
        rv.type = RV_UID_ARRAY;
        n = bp_count(v);
        if (!(rv.u.refs.v = malloc((n ? n : 1) * sizeof *rv.u.refs.v))) return room(r);
        rv.u.refs.n = n;
        for (i = 0; i < n; i++) {
            const BpNode *u = bp_at(v, i);
            if (bp_type(u) != BP_UID) {
                free(rv.u.refs.v);
                return rfail(r, "%s: an array holding a plist %s, not only uids", where, TYPE_NAMES[bp_type(u)]);
            }
            if (ref_of(r, u, &rv.u.refs.v[i], where)) { free(rv.u.refs.v); return -1; }
        }
        rc = rg_add_value(r->g, obj, &rv);
        free(rv.u.refs.v);
        return rc ? room(r) : 0;
    default:
        return rfail(r, "%s: a plist %s as a value", where, TYPE_NAMES[bp_type(v)]);
    }
    return rg_add_value(r->g, obj, &rv) ? room(r) : 0;
}

/* Object obj's values from dict d, all but $class; refuses a key d holds twice. */
static int add_values(R *r, uint32_t obj, const BpNode *d, const char *where) {
    size_t i, n = bp_count(d), k = 0;
    const char **keys, *dup;
    char at[SHOWBUF + 96];
    int no_memory;
    if (!(keys = malloc((n ? n : 1) * sizeof *keys))) return room(r);
    for (i = 0; i < n; i++) {
        const char *key = name_of(r, bp_key_at(d, i), "a key");
        if (!key) { free(keys); return -1; }
        keys[k++] = key;
        if (obj && !strcmp(key, "$class")) continue;
        snprintf(at, sizeof at, "%s %s", where, show(r->sb, key));
        if (add_value(r, obj, key, bp_value_at(d, i), at)) { free(keys); return -1; }
    }
    dup = repeated(keys, k, &no_memory);
    free(keys);
    if (no_memory) return room(r);
    if (dup) return rfail(r, "%s holds the key %s twice", where, show(r->sb, dup));
    return 0;
}

/* An array of names ($classes or $classhints) as malloc'd strings into *out, counted in *n as each is copied. */
static int names_of(R *r, const BpNode *a, const char *key, char ***out, size_t *n, const char *where) {
    size_t j, len, count = bp_count(a);
    for (j = 0; j < count; j++)
        if (bp_type(bp_at(a, j)) != BP_STRING)
            return rfail(r, "%s: %s holds a plist %s", where, key, TYPE_NAMES[bp_type(bp_at(a, j))]);
    if (!(*out = calloc(count ? count : 1, sizeof **out))) return room(r);
    for (j = 0; j < count; j++) {
        const BpNode *s = bp_at(a, j);
        const char *p = (const char *)bp_bytes(s, &len);
        if (memchr(p, 0, len)) return rfail(r, "%s: %s holds a name with a NUL", where, key);
        if (charge(r, s, len)) return -1;
        if (!((*out)[j] = malloc(len + 1))) return room(r);
        memcpy((*out)[j], p, len);
        (*out)[j][len] = 0;
        (*n)++;
    }
    return 0;
}

static int class_entry_read(R *r, size_t i, const BpNode *d) {
    const BpNode *name = NULL, *chain = NULL, *hints = NULL;
    const char *cls;
    size_t j, len0;
    RChain *cs;
    char where[48];
    snprintf(where, sizeof where, "$objects[%lu]", (unsigned long)i);
    for (j = 0; j < bp_count(d); j++) {
        size_t kn;
        const char *k = (const char *)bp_bytes(bp_key_at(d, j), &kn);
        const BpNode *v = bp_value_at(d, j);
        if (kn == 10 && !memcmp(k, "$classname", 10) && !name && bp_type(v) == BP_STRING) name = v;
        else if (kn == 8 && !memcmp(k, "$classes", 8) && !chain && bp_type(v) == BP_ARRAY) chain = v;
        else if (kn == 11 && !memcmp(k, "$classhints", 11) && !hints && bp_type(v) == BP_ARRAY) hints = v;
        else return rfail(r, "%s: a class entry holds %s", where, show(r->sb, memchr(k, 0, kn) ? "a key with a NUL" : k));
    }
    if (!name || !chain || !bp_count(chain)) return rfail(r, "%s: a class entry needs $classname and $classes", where);
    if (hints && !bp_count(hints)) return rfail(r, "%s: $classhints is empty", where);
    if (!(cls = name_of(r, name, "a class name"))) return -1;
    r->entry_cls[i] = cls;
    bp_bytes(name, &len0);
    if (!(cs = realloc(r->g->chains, (r->g->n_chains + 1) * sizeof *cs))) return room(r);
    r->g->chains = cs;
    cs = &r->g->chains[r->g->n_chains++];
    memset(cs, 0, sizeof *cs);
    cs->resolved = 1;
    if (!(cs->cls = malloc(len0 + 1))) return room(r);
    memcpy(cs->cls, cls, len0 + 1);
    if (names_of(r, chain, "$classes", &cs->chain, &cs->n_chain, where)) return -1;
    if (strcmp(cs->chain[0], cls)) return rfail(r, "%s: $classes does not start with %s", where, show(r->sb, cls));
    return hints ? names_of(r, hints, "$classhints", &cs->hints, &cs->n_hints, where) : 0;
}

/* g->chains sorted by class (a merge sort), refusing a class with two entries. */
static int sort_chains(R *r) {
    RChain *a = r->g->chains, *b, *t;
    size_t n = r->g->n_chains, w, i, lo, mid, hi, x, y;
    if (n < 2) return 0;
    if (!(b = malloc(n * sizeof *b))) return room(r);
    for (w = 1; w < n; w *= 2) {
        for (lo = 0; lo < n; lo += 2 * w) {
            mid = lo + w < n ? lo + w : n;
            hi = lo + 2 * w < n ? lo + 2 * w : n;
            for (i = lo, x = lo, y = mid; i < hi; i++)
                b[i] = (x < mid && (y >= hi || strcmp(a[x].cls, a[y].cls) <= 0)) ? a[x++] : a[y++];
        }
        t = a; a = b; b = t;
    }
    if (a != r->g->chains) { memcpy(r->g->chains, a, n * sizeof *a); b = a; }
    free(b);
    for (i = 1; i < n; i++)
        if (!strcmp(r->g->chains[i - 1].cls, r->g->chains[i].cls))
            return rfail(r, "the class %s has two entries", show(r->sb, r->g->chains[i].cls));
    return 0;
}

static int bare_object(R *r, size_t i, const BpNode *v) {
    int cls, key, obj;
    char where[48];
    switch (bp_type(v)) {
    case BP_STRING: cls = N_NSSTRING; key = N_BYTES; break;
    case BP_DATA: cls = N_NSDATA; key = N_BYTES; break;
    case BP_INT: cls = N_NSNUMBER; key = N_INTVAL; break;
    case BP_BOOL: cls = N_NSNUMBER; key = N_BOOLVAL; break;
    case BP_REAL: cls = N_NSNUMBER; key = bp_real_width(v) == 4 ? N_FLOATVAL : N_DBLVAL; break;
    default: return rfail(r, "$objects[%lu] is a plist %s", (unsigned long)i, TYPE_NAMES[bp_type(v)]);
    }
    if (!fixed(r, cls) || !fixed(r, key)) return -1;
    if ((obj = rg_add_object(r->g, r->names[cls])) < 0) return room(r);
    r->g->objs[obj].bare = 1;
    snprintf(where, sizeof where, "$objects[%lu]", (unsigned long)i);
    return add_value(r, (uint32_t)obj, r->names[key], v, where);
}

static int top_level(R *r, const BpNode *root, const BpNode **top) {
    static const char *const want[] = { "$version", "$archiver", "$top", "$objects" };
    const BpNode *got[4] = { NULL, NULL, NULL, NULL };
    size_t i, k, n;
    const uint8_t *p;
    if (bp_type(root) != BP_DICT) return rfail(r, "the top object is a plist %s, not a dict", TYPE_NAMES[bp_type(root)]);
    for (i = 0; i < bp_count(root); i++) {
        p = bp_bytes(bp_key_at(root, i), &n);
        for (k = 0; k < 4 && !(n == strlen(want[k]) && !memcmp(p, want[k], n)); k++) {}
        if (k == 4) {
            char key[41];
            size_t m = n < 40 ? n : 40, j;
            for (j = 0; j < m; j++) key[j] = p[j] && p[j] < 0x80 ? (char)p[j] : '?';
            key[m] = 0;
            return rfail(r, "the archive holds the key %s", show(r->sb, key));
        }
        if (got[k]) return rfail(r, "the archive holds %s twice", want[k]);
        got[k] = bp_value_at(root, i);
    }
    for (k = 0; k < 4; k++)
        if (!got[k]) return rfail(r, "the archive has no %s", want[k]);
    if (bp_type(got[0]) != BP_INT || bp_int_value(got[0]) != KEYED_VERSION) return rfail(r, "$version is not %d", KEYED_VERSION);
    if (bp_type(got[1]) != BP_STRING || (p = bp_bytes(got[1], &n), n != 15 || memcmp(p, "NSKeyedArchiver", 15)))
        return rfail(r, "$archiver is not NSKeyedArchiver");
    if (bp_type(got[2]) != BP_DICT) return rfail(r, "$top is not a dict");
    if (bp_type(got[3]) != BP_ARRAY || !bp_count(got[3]) || bp_type(bp_at(got[3], 0)) != BP_STRING ||
        (p = bp_bytes(bp_at(got[3], 0), &n), n != 5 || memcmp(p, "$null", 5)))
        return rfail(r, "$objects is not an array with $null first");
    *top = got[2];
    r->objs = got[3];
    return 0;
}

int ka_read(const uint8_t *buf, size_t n, RGraph *out, char *why, size_t whysz) {
    R r;
    BpNode *root = NULL;
    const BpNode *top = NULL;
    size_t i;
    uint32_t next = 1;
    int rc;
    memset(out, 0, sizeof *out);
    out->format = RF_KEYED;
    if ((rc = bp_read(buf, n, &root, why, whysz))) return rc;
    memset(&r, 0, sizeof r);
    r.g = out; r.why = why; r.whysz = whysz;
    r.budget = r.limit = n > SIZE_MAX / 32 ? SIZE_MAX : 16 * n + ((size_t)1 << 20);
    rc = 4;
    if (top_level(&r, root, &top)) goto done;
    r.n = bp_count(r.objs);
    if (!(r.gidx = malloc(r.n * sizeof *r.gidx)) || !(r.entry_cls = calloc(r.n, sizeof *r.entry_cls))) { room(&r); goto done; }
    r.gidx[0] = 0;
    for (i = 1; i < r.n; i++) {
        const BpNode *v = bp_at(r.objs, i);
        if (bp_type(v) == BP_DICT && !bp_get(v, "$class")) {
            if (!bp_get(v, "$classname")) { rfail(&r, "$objects[%lu] is a dict with neither $class nor $classname", (unsigned long)i); goto done; }
            r.gidx[i] = CLASS_ENTRY;
        } else
            r.gidx[i] = next++;
    }
    for (i = 1; i < r.n; i++)
        if (r.gidx[i] == CLASS_ENTRY && class_entry_read(&r, i, bp_at(r.objs, i))) goto done;
    if (sort_chains(&r)) goto done;
    if (!fixed(&r, N_NSOBJECT) || rg_add_object(out, r.names[N_NSOBJECT]) < 0) { room(&r); goto done; }
    if (add_values(&r, 0, top, "$top")) goto done;
    for (i = 1; i < r.n; i++) {
        const BpNode *v = bp_at(r.objs, i), *c;
        char where[48];
        int obj;
        if (r.gidx[i] == CLASS_ENTRY) continue;
        if (bp_type(v) != BP_DICT) {
            if (bare_object(&r, i, v)) goto done;
            continue;
        }
        snprintf(where, sizeof where, "$objects[%lu]", (unsigned long)i);
        c = bp_get(v, "$class");
        if (bp_type(c) != BP_UID || bp_uid_value(c) >= r.n || r.gidx[bp_uid_value(c)] != CLASS_ENTRY) {
            rfail(&r, "%s: $class is not the uid of a class entry", where);
            goto done;
        }
        if ((obj = rg_add_object(out, r.entry_cls[bp_uid_value(c)])) < 0) { room(&r); goto done; }
        if (add_values(&r, (uint32_t)obj, v, where)) goto done;
    }
    rc = 0;
done:
    free(r.gidx);
    free(r.entry_cls);
    free(r.slots);
    bp_free(root);
    if (rc) rg_free(out);
    return rc;
}
