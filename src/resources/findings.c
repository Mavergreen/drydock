#include "findings.h"
#include "adapt.h"
#include "keyed.h"

#include <fnmatch.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *a, *b; } Pair;   /* class and key; or colour name and version */

struct RfRefs {
    char *keys_buf, *floor_buf, *newer_buf;
    Pair *keys; size_t n_keys;
    Pair *floor_colors; size_t n_floor;      /* b unused */
    Pair *newer_colors; size_t n_newer;
    int floor_storyboard;
    const char *storyboard_version;
};

static char *dup_s(const char *s) {
    char *c = malloc(strlen(s) + 1);
    if (c) strcpy(c, s);
    return c;
}

int rf_add(RFindings *f, const char *kind, const char *nib, const char *item, RfSeverity sev, const char *fmt, ...) {
    va_list ap;
    int n;
    RFinding *v, x;
    memset(&x, 0, sizeof x);
    va_start(ap, fmt);
    n = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (n < 0 || !(x.detail = malloc((size_t)n + 1))) return -1;
    va_start(ap, fmt);
    vsnprintf(x.detail, (size_t)n + 1, fmt, ap);
    va_end(ap);
    x.sev = sev;
    if (!(x.kind = dup_s(kind)) || (nib && !(x.nib = dup_s(nib))) || !(x.item = dup_s(item))
        || (!(f->n & (f->n - 1)) && f->n > SIZE_MAX / 2 / sizeof *v)
        || !(v = (f->n & (f->n - 1)) ? f->v : realloc(f->v, (f->n ? 2 * f->n : 1) * sizeof *v))) {
        free(x.kind); free(x.nib); free(x.item); free(x.detail);
        return -1;
    }
    f->v = v;
    f->v[f->n++] = x;
    return 0;
}

void rf_free(RFindings *f) {
    size_t i;
    for (i = 0; i < f->n; i++) {
        free(f->v[i].kind); free(f->v[i].nib); free(f->v[i].item); free(f->v[i].detail); free(f->v[i].deviation);
    }
    free(f->v);
    f->v = NULL;
    f->n = 0;
}

const char *rf_severity_name(RfSeverity s) {
    switch (s) {
    case RF_BLOCK_WRITE: return "blocks-write";
    case RF_FINDING: return "finding";
    case RF_WILL_ADAPT: return "will-adapt";
    default: return "adapted";
    }
}

const char *rf_class_of(const RGraph *g, uint32_t obj, char buf[RF_CLASS_MAX]) {
    const RValue *v;
    if (strcmp(g->objs[obj].cls, "NSClassSwapper")) return g->objs[obj].cls;
    v = rg_get(g, obj, "NSOriginalClassName");
    if (v && v->type == RV_REF && v->u.ref < g->n_objs) v = rg_get(g, v->u.ref, "NS.bytes");
    if (!v || (v->type != RV_DATA && v->type != RV_STRING) || !v->u.d.n || v->u.d.n >= RF_CLASS_MAX
        || memchr(v->u.d.p, 0, v->u.d.n))
        return g->objs[obj].cls;
    memcpy(buf, v->u.d.p, v->u.d.n);
    buf[v->u.d.n] = 0;
    return buf;
}

static char *slurp_path(const char *path) {
    FILE *f;
    char *buf = NULL, *more;
    size_t n = 0, cap = 1 << 20;
    if (!(f = fopen(path, "rb"))) return NULL;
    for (;;) {
        if (!(more = realloc(buf, cap + 1))) { free(buf); fclose(f); return NULL; }
        buf = more;
        n += fread(buf + n, 1, cap - n, f);
        if (n < cap) break;
        if (cap > SIZE_MAX / 4) { free(buf); fclose(f); return NULL; }
        cap *= 2;
    }
    if (ferror(f)) { free(buf); fclose(f); return NULL; }
    fclose(f);
    buf[n] = 0;
    return buf;
}

static char *slurp(const char *dir, const char *name) {
    char path[4096];
    if (snprintf(path, sizeof path, "%s/%s", dir, name) >= (int)sizeof path) return NULL;
    return slurp_path(path);
}

/* Splits line at tabs into at most max fields; returns the count, or max + 1 when more remain. */
static int split(char *line, char **f, int max) {
    int n = 0;
    char *p = line;
    while (n < max) {
        f[n++] = p;
        if (!(p = strchr(p, '\t'))) break;
        *p++ = 0;
    }
    return p ? max + 1 : n;
}

static int push(Pair **v, size_t *n, const char *a, const char *b) {
    Pair *p;
    if (!(*n & (*n - 1))) {
        if (*n > SIZE_MAX / 2 / sizeof *p || !(p = realloc(*v, (*n ? 2 * *n : 1) * sizeof *p))) return -1;
        *v = p;
    }
    (*v)[*n].a = a;
    (*v)[(*n)++].b = b;
    return 0;
}

static int pair_cmp(const void *x, const void *y) {
    const Pair *p = x, *q = y;
    int c = strcmp(p->a, q->a);
    return c ? c : strcmp(p->b, q->b);
}

static int name_cmp(const void *x, const void *y) { return strcmp(((const Pair *)x)->a, ((const Pair *)y)->a); }

/* Each line of buf, NUL-terminated in place, to fn; stops at fn's nonzero result. */
static int lines(char *buf, int (*fn)(RfRefs *, char *), RfRefs *r) {
    char *line = buf, *next;
    int rc;
    for (; *line; line = next) {
        if ((next = strchr(line, '\n'))) *next++ = 0;
        else next = line + strlen(line);
        if ((rc = fn(r, line))) return rc;
    }
    return 0;
}

static int key_row(RfRefs *r, char *line) {
    char *f[5];
    if (line[0] == '#') return 0;
    if (split(line, f, 4) != 4 || !*f[0] || !*f[1] || (strcmp(f[2], "read") && strcmp(f[2], "ignored")) || !*f[3]) return -1;
    return push(&r->keys, &r->n_keys, f[0], f[1]);
}

/* floor-runtime.tsv: method NSColor + NAME ...; class NSStoryboard ... */
static int floor_row(RfRefs *r, char *line) {
    char *f[5];
    if (!strncmp(line, "class\tNSStoryboard\t", 19)) r->floor_storyboard = 1;
    if (strncmp(line, "method\tNSColor\t+\t", 17)) return 0;
    if (split(line, f, 4) < 4 || !*f[3]) return -1;
    return push(&r->floor_colors, &r->n_floor, f[3], "");
}

/* newer-sdk.tsv: method|property-get AppKit NSColor + NAME TYPE VERSION ...; class AppKit NSStoryboard - SUPER - VERSION */
static int newer_row(RfRefs *r, char *line) {
    char *f[8];
    int color = !strncmp(line, "method\tAppKit\tNSColor\t+\t", 24) || !strncmp(line, "property-get\tAppKit\tNSColor\t+\t", 30);
    int board = !strncmp(line, "class\tAppKit\tNSStoryboard\t", 25);
    if (!color && !board) return 0;
    if (split(line, f, 7) < 7 || !*f[color ? 4 : 2]) return -1;
    if (board) { r->storyboard_version = strcmp(f[6], "-") ? f[6] : "?"; return 0; }
    return push(&r->newer_colors, &r->n_newer, f[4], strcmp(f[6], "-") ? f[6] : "?");
}

RfRefs *rf_open(const char *refdir_resources, const char *refdir_objc) {
    RfRefs *r;
    if (!refdir_resources || !refdir_objc || !(r = calloc(1, sizeof *r))) return NULL;
    if (!(r->keys_buf = slurp(refdir_resources, "keys-10.9.tsv")) || !(r->floor_buf = slurp(refdir_objc, "floor-runtime.tsv"))
        || !(r->newer_buf = slurp(refdir_objc, "newer-sdk.tsv")) || lines(r->keys_buf, key_row, r)
        || lines(r->floor_buf, floor_row, r) || lines(r->newer_buf, newer_row, r)) {
        rf_close(r);
        return NULL;
    }
    if (r->n_keys) qsort(r->keys, r->n_keys, sizeof *r->keys, pair_cmp);
    if (r->n_floor) qsort(r->floor_colors, r->n_floor, sizeof *r->floor_colors, name_cmp);
    if (r->n_newer) qsort(r->newer_colors, r->n_newer, sizeof *r->newer_colors, pair_cmp);
    return r;
}

void rf_close(RfRefs *r) {
    if (!r) return;
    free(r->keys); free(r->floor_colors); free(r->newer_colors);
    free(r->keys_buf); free(r->floor_buf); free(r->newer_buf);
    free(r);
}

static int known_key(const RfRefs *r, const char *cls, const char *key) {
    Pair p;
    p.a = cls;
    p.b = key;
    return r->n_keys && bsearch(&p, r->keys, r->n_keys, sizeof *r->keys, pair_cmp);
}

static int known_for(const RfRefs *r, const RGraph *g, uint32_t obj, const char *cls, const char *key) {
    const RChain *c = rg_chain(g, cls);
    size_t i;
    if (known_key(r, cls, key) || known_key(r, g->objs[obj].cls, key)) return 1;
    if (c && c->resolved)
        for (i = 1; i < c->n_chain; i++)
            if (known_key(r, c->chain[i], key)) return 1;
    return 0;
}

static const char *string_of(const RGraph *g, const RValue *v, char *buf, size_t bufsz) {
    if (v && v->type == RV_REF && v->u.ref < g->n_objs) {
        const RValue *b = rg_get(g, v->u.ref, "NS.bytes");
        v = b ? b : rg_get(g, v->u.ref, "NS.string");
    }
    if (!v || (v->type != RV_DATA && v->type != RV_STRING) || v->u.d.n >= bufsz || memchr(v->u.d.p, 0, v->u.d.n)) return NULL;
    memcpy(buf, v->u.d.p, v->u.d.n);
    buf[v->u.d.n] = 0;
    return buf;
}

/* A candidate finding, kept until every object is seen so each (item, class) is reported once, at its first object. */
typedef struct { char *item, *cls; const char *detail; uint32_t obj; } Cand;
typedef struct { Cand *v; size_t n; } Cands;

static int cand(Cands *c, const char *item, const char *cls, const char *detail, uint32_t obj) {
    Cand *v;
    char *i, *k;
    if (!(c->n & (c->n - 1))) {
        if (c->n > SIZE_MAX / 2 / sizeof *v || !(v = realloc(c->v, (c->n ? 2 * c->n : 1) * sizeof *v))) return -1;
        c->v = v;
    }
    if (!(i = dup_s(item)) || !(k = dup_s(cls))) { free(i); return -1; }
    c->v[c->n].item = i;
    c->v[c->n].cls = k;
    c->v[c->n].detail = detail;
    c->v[c->n++].obj = obj;
    return 0;
}

static int same(const Cand *a, const Cand *b) { return !strcmp(a->item, b->item) && !strcmp(a->cls, b->cls); }

static int cand_cmp(const void *x, const void *y) {
    const Cand *a = x, *b = y;
    int c = strcmp(a->item, b->item);
    if (c) return c;
    if ((c = strcmp(a->cls, b->cls))) return c;
    return a->obj < b->obj ? -1 : a->obj > b->obj;
}

static void cands_free(Cands *c) {
    size_t i;
    for (i = 0; i < c->n; i++) { free(c->v[i].item); free(c->v[i].cls); }
    free(c->v);
}

static int keys_and_colors(const RfRefs *r, const RGraph *g, const char *nib, RFindings *out) {
    Cands keys = { NULL, 0 }, colors = { NULL, 0 };
    size_t i, j;
    int rc = -1;
    for (i = 0; i < g->n_objs; i++) {
        const RObject *o = &g->objs[i];
        char buf[RF_CLASS_MAX], name[RF_CLASS_MAX], cat[16];
        const char *cls;
        Pair p, *hit;
        if (o->bare) continue;
        cls = rf_class_of(g, (uint32_t)i, buf);
        for (j = 0; j < o->n_vals; j++)
            if (!known_for(r, g, (uint32_t)i, cls, o->vals[j].key) && cand(&keys, o->vals[j].key, cls, "", (uint32_t)i))
                goto done;
        if (strcmp(cls, "NSColor") || !string_of(g, rg_get(g, (uint32_t)i, "NSCatalogName"), cat, sizeof cat)
            || strcmp(cat, "System") || !string_of(g, rg_get(g, (uint32_t)i, "NSColorName"), name, sizeof name))
            continue;
        p.a = name;
        p.b = "";
        if (r->n_floor && bsearch(&p, r->floor_colors, r->n_floor, sizeof *r->floor_colors, name_cmp))
            continue;
        hit = r->n_newer ? bsearch(&p, r->newer_colors, r->n_newer, sizeof *r->newer_colors, name_cmp) : NULL;
        if (cand(&colors, name, "", hit ? hit->b : "?", (uint32_t)i)) goto done;
    }
    if (keys.n) qsort(keys.v, keys.n, sizeof *keys.v, cand_cmp);
    if (colors.n) qsort(colors.v, colors.n, sizeof *colors.v, cand_cmp);
    for (i = 0; i < keys.n; i++)
        if ((!i || !same(&keys.v[i - 1], &keys.v[i]))
            && rf_add(out, "unknown-key", nib, keys.v[i].item, RF_FINDING, "%s @%lu", keys.v[i].cls, (unsigned long)keys.v[i].obj))
            goto done;
    for (i = 0; i < colors.n; i++)
        if ((!i || !same(&colors.v[i - 1], &colors.v[i]))
            && rf_add(out, "named-color-missing", nib, colors.v[i].item, RF_FINDING, "%s", colors.v[i].detail))
            goto done;
    rc = 0;
done:
    cands_free(&keys);
    cands_free(&colors);
    return rc;
}

int rf_check(const RfRefs *r, const RGraph *g, const char *nib_relpath, const char *target, const RAdaptSet *adapt,
             RFindings *out) {
    size_t i;
    char why[512];
    BpNode *archive = NULL;
    unsigned char *stored;
    int rc;
    if (strcmp(target, "10.9")) return 2;
    if (g->format == RF_NIBARCHIVE
        && rf_add(out, "nibarchive-format", nib_relpath, "NIBArchive", RF_WILL_ADAPT, "converts to a keyed archive"))
        return 4;
    if (!(stored = calloc(g->n_chains ? g->n_chains : 1, 1))) return 4;
    for (i = 1; i < g->n_objs; i++) {
        const RChain *c = ka_stores(g, (uint32_t)i) ? rg_chain(g, g->objs[i].cls) : NULL;
        if (c) stored[c - g->chains] = 1;
    }
    for (i = 0; i < g->n_chains; i++) {
        const RChain *c = &g->chains[i];
        if (!c->resolved) {
            if (rf_add(out, "unresolved-chain", nib_relpath, c->cls, stored[i] ? RF_BLOCK_WRITE : RF_FINDING, "%s",
                       stored[i] ? "no superclass chain to a root" : "no superclass chain to a root; no object stores it"))
                break;
        } else if (c->newer && rf_add(out, "class-missing", nib_relpath, c->cls, RF_FINDING, "%s", c->newer))
            break;
    }
    free(stored);
    if (i < g->n_chains) return 4;
    if (keys_and_colors(r, g, nib_relpath, out)) return 4;
    if (adapt && ra_check(adapt, g, nib_relpath, out)) return 4;
    rc = ka_from_graph(g, &archive, why, sizeof why);
    if (rc == 4) return 4;
    if (!rc) bp_free(archive);
    else if (strncmp(why, "unencodable: unresolved chain", 29)
             && rf_add(out, "unencodable", nib_relpath, "keyed-archive", RF_BLOCK_WRITE, "%s",
                       strncmp(why, "unencodable: ", 13) ? why : why + 13))
        return 4;
    return 0;
}

int rf_storyboard(const RfRefs *r, const char *relpath, const char *target, RFindings *out) {
    if (strcmp(target, "10.9")) return 2;
    if (r->floor_storyboard) return 0;
    return rf_add(out, "storyboard", relpath, "NSStoryboard", RF_FINDING, "%s",
                  r->storyboard_version ? r->storyboard_version : "?") ? 4 : 0;
}

static int finding_cmp(const void *x, const void *y) {
    const RFinding *a = x, *b = y;
    int c = strcmp(a->nib ? a->nib : "", b->nib ? b->nib : "");
    if (!c) c = strcmp(a->kind, b->kind);
    if (!c) c = strcmp(a->item, b->item);
    return c ? c : strcmp(a->detail, b->detail);
}

void rf_sort(RFindings *f) {
    if (f->n) qsort(f->v, f->n, sizeof *f->v, finding_cmp);
}

int rf_blocks(const RFinding *x) { return (x->sev == RF_FINDING || x->sev == RF_BLOCK_WRITE) && !x->deviation; }

static const char *const kinds[] = { "nibarchive-format", "class-missing", "unresolved-chain", "unknown-key",
                                     "named-color-missing", "storyboard", "unencodable", "translate-autoresizing",
                                     "wrapping-width", "no-floor-nib", "no-nib" };

void rf_exceptions_free(RfExceptions *ex) {
    size_t i, j;
    for (i = 0; i < ex->n; i++) {
        free(ex->v[i].line);
        free(ex->v[i].glob);   /* the other fields share its buffer */
        for (j = 0; j < ex->v[i].n_applied; j++) free(ex->v[i].applied[j]);
        free(ex->v[i].applied);
    }
    free(ex->v);
    ex->v = NULL;
    ex->n = 0;
}

int rf_exceptions_read(const char *path, RfExceptions *out, char *why, size_t whysz) {
    char *buf, *line, *next, *f[5], *fields;
    size_t k, no = 0;
    out->v = NULL;
    out->n = 0;
    if (!(buf = slurp_path(path))) { snprintf(why, whysz, "%s: cannot read the exceptions", path); return 4; }
    for (line = buf; *line; line = next) {
        RfException *e;
        int wild = 1;
        const char *p;
        if ((next = strchr(line, '\n'))) *next++ = 0;
        else next = line + strlen(line);
        no++;
        if (!*line) continue;
        if (!(out->n & (out->n - 1))) {
            if (out->n > SIZE_MAX / 2 / sizeof *e || !(e = realloc(out->v, (out->n ? 2 * out->n : 1) * sizeof *e))) goto oom;
            out->v = e;
        }
        e = &out->v[out->n];
        memset(e, 0, sizeof *e);
        out->n++;
        if (!(e->line = dup_s(line)) || !(fields = dup_s(line))) goto oom;
        if (split(fields, f, 4) != 4 || !*f[0] || !*f[1] || !*f[2] || !*f[3]) {
            free(fields);
            snprintf(why, whysz, "%s: line %lu is not NIB_GLOB<TAB>KIND<TAB>ITEM<TAB>REASON", path, (unsigned long)no);
            goto bad;
        }
        e->glob = f[0]; e->kind = f[1]; e->item = f[2]; e->reason = f[3];
        for (p = e->glob; *p; p++)
            if (!strchr("*?/", *p)) wild = 0;
        if (wild) {
            snprintf(why, whysz, "%s: line %lu: the nib glob %s is wildcards alone", path, (unsigned long)no, e->glob);
            goto bad;
        }
        for (k = 0; k < sizeof kinds / sizeof *kinds && strcmp(kinds[k], e->kind); k++) ;
        if (k == sizeof kinds / sizeof *kinds) {
            snprintf(why, whysz, "%s: line %lu: %s is no finding kind", path, (unsigned long)no, e->kind);
            goto bad;
        }
    }
    free(buf);
    return 0;
oom:
    snprintf(why, whysz, "out of memory");
bad:
    free(buf);
    rf_exceptions_free(out);
    return 4;
}

static int applied(RfException *e, const RFinding *x) {
    char **v;
    int n = snprintf(NULL, 0, "%s: %s %s", x->nib ? x->nib : "", x->kind, x->item);
    if (n < 0) return -1;
    if (!(e->n_applied & (e->n_applied - 1))) {
        if (e->n_applied > SIZE_MAX / 2 / sizeof *v || !(v = realloc(e->applied, (e->n_applied ? 2 * e->n_applied : 1) * sizeof *v)))
            return -1;
        e->applied = v;
    }
    if (!(e->applied[e->n_applied] = malloc((size_t)n + 1))) return -1;
    snprintf(e->applied[e->n_applied++], (size_t)n + 1, "%s: %s %s", x->nib ? x->nib : "", x->kind, x->item);
    return 0;
}

static char *deviation(const RfException *e) {
    char *d = malloc(strlen(e->kind) + strlen(e->item) + 2);
    if (d) sprintf(d, "%s:%s", e->kind, e->item);
    return d;
}

int rf_except(RfExceptions *ex, RFindings *f) {
    size_t i, j, k, *by;
    if (!f->n) return 0;
    if (!(by = malloc(f->n * sizeof *by))) return 4;
    for (i = 0; i < f->n; i++) {
        RFinding *x = &f->v[i];
        by[i] = ex->n;
        if (!rf_blocks(x)) continue;
        for (k = 0; k < ex->n; k++) {
            RfException *e = &ex->v[k];
            if (strcmp(e->kind, x->kind) || strcmp(e->item, x->item) || fnmatch(e->glob, x->nib ? x->nib : "", 0)) continue;
            if (!(x->deviation = deviation(e)) || applied(e, x)) goto oom;
            by[i] = k;
            break;
        }
    }
    for (i = 0; i < f->n; i++) {
        const RFinding *s = &f->v[i];
        size_t len;
        if (by[i] == ex->n || strcmp(s->kind, "storyboard") || !s->nib) continue;
        len = strlen(s->nib);
        for (j = 0; j < f->n; j++) {
            RFinding *x = &f->v[j];
            if (!rf_blocks(x) || !x->nib || strncmp(x->nib, s->nib, len) || x->nib[len] != '/') continue;
            if (!(x->deviation = deviation(&ex->v[by[i]])) || applied(&ex->v[by[i]], x)) goto oom;
        }
    }
    free(by);
    return 0;
oom:
    free(by);
    return 4;
}
