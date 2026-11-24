#include "chains.h"
#include "report.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHAIN_MAX 64
#define NAME_MAX_BYTES 1024

enum { SRC_BINARY, SRC_FLOOR, SRC_NEWER };

/* super: "-" a root, NULL a superclass the reader could not measure. version: newer-sdk.tsv's, or NULL. */
typedef struct { const char *name, *super, *version; int src; size_t seq; } Entry;

struct RChainSrc {
    char *target;
    char *floor_buf, *newer_buf;
    Entry *e; size_t n;
    char **owned; size_t n_owned;
    int sorted;
};

typedef struct { const char *p; size_t n; int from_swapper; } Name;

static void *grown(void *p, size_t n, size_t size) {
    if (n & (n - 1)) return p;
    if (n > SIZE_MAX / 2 / size) return NULL;
    return realloc(p, (n ? 2 * n : 1) * size);
}

static int add_entry(RChainSrc *s, const char *name, const char *super, const char *version, int src) {
    Entry *e = grown(s->e, s->n, sizeof *e);
    if (!e) return -1;
    s->e = e;
    e[s->n].name = name; e[s->n].super = super; e[s->n].version = version; e[s->n].src = src; e[s->n].seq = s->n;
    s->n++;
    s->sorted = 0;
    return 0;
}

static char *own(RChainSrc *s, const char *str) {
    char **o, *c;
    size_t n = strlen(str);
    if (!(o = grown(s->owned, s->n_owned, sizeof *o))) return NULL;
    s->owned = o;
    if (!(c = malloc(n + 1))) return NULL;
    memcpy(c, str, n + 1);
    return o[s->n_owned++] = c;
}

static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb");
    char *buf = NULL, *more;
    size_t n = 0, cap = 1 << 20;
    if (!f) return NULL;
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

static int version_ok(const char *v) {
    const char *p = v;
    if (!*p) return 0;
    for (; *p; p++)
        if (!((*p >= '0' && *p <= '9') || (*p == '.' && p != v && p[-1] != '.' && p[1])))
            return 0;
    return 1;
}

/* floor-runtime.tsv: class NAME - SUPER ROOT FRAMEWORK -; newer-sdk.tsv: class FRAMEWORK NAME - SUPER - VERSION ... */
static int load(RChainSrc *s, char *buf, int src) {
    char *line = buf, *next, *f[12];
    int want = src == SRC_FLOOR ? 7 : 11, name = src == SRC_FLOOR ? 1 : 2;
    for (; *line; line = next) {
        if ((next = strchr(line, '\n'))) *next++ = 0;
        else next = line + strlen(line);
        if (strncmp(line, "class\t", 6)) continue;
        if (split(line, f, 11) != want || !*f[name] || !*f[name + 2]) return -1;
        if (src == SRC_NEWER && strcmp(f[6], "-") && !version_ok(f[6])) return -1;
        if (add_entry(s, f[name], f[name + 2], src == SRC_NEWER ? f[6] : NULL, src)) return -1;
    }
    return 0;
}

/* <0, 0, >0 as dotted version a is older, the same, newer than b, both version_ok or "?" (unknown), newest of all. */
static int version_cmp(const char *a, const char *b) {
    if (!strcmp(a, "?") || !strcmp(b, "?")) return !strcmp(a, "?") - !strcmp(b, "?");
    while (*a || *b) {
        char *ea, *eb;
        unsigned long x = strtoul(a, &ea, 10), y = strtoul(b, &eb, 10);
        if (x != y) return x < y ? -1 : 1;
        a = *ea == '.' ? ea + 1 : ea;
        b = *eb == '.' ? eb + 1 : eb;
    }
    return 0;
}

RChainSrc *rc_open(const char *refdir, const char *target) {
    RChainSrc *s;
    char path[4096];
    if (!target || !version_ok(target) || !(s = calloc(1, sizeof *s))) return NULL;
    if (!(s->target = malloc(strlen(target) + 1))) { free(s); return NULL; }
    strcpy(s->target, target);
    if (refdir && (snprintf(path, sizeof path, "%s/floor-runtime.tsv", refdir) >= (int)sizeof path
                   || !(s->floor_buf = slurp(path))
                   || snprintf(path, sizeof path, "%s/newer-sdk.tsv", refdir) >= (int)sizeof path
                   || !(s->newer_buf = slurp(path))
                   || load(s, s->floor_buf, SRC_FLOOR) || load(s, s->newer_buf, SRC_NEWER))) {
        rc_close(s);
        return NULL;
    }
    return s;
}

void rc_close(RChainSrc *s) {
    size_t i;
    if (!s) return;
    for (i = 0; i < s->n_owned; i++) free(s->owned[i]);
    free(s->owned);
    free(s->e);
    free(s->floor_buf);
    free(s->newer_buf);
    free(s->target);
    free(s);
}

int rc_add_binary(RChainSrc *s, const char *macho_path, char *why, size_t whysz) {
    ObjcAnalysis *a;
    size_t i, first = s->n;
    int rc;
    if (!(a = objc_analysis_create()) || objc_set_string(&a->artifact_path, macho_path)) {
        objc_analysis_destroy(a);
        snprintf(why, whysz, "out of memory");
        return -1;
    }
    a->metadata_only = 1;
    rc = objc_collect_artifacts(a);
    for (i = 0; i < a->n_errors; i++)
        if (!strcmp(a->errors[i].code, "out-of-memory")) {
            snprintf(why, whysz, "out of memory");
            objc_analysis_destroy(a);
            return -1;
        }
    if (rc || a->n_errors) {
        snprintf(why, whysz, "%s: %s", a->n_errors ? a->errors[0].code : "cannot-measure",
                 a->n_errors && a->errors[0].detail ? a->errors[0].detail : "");
        objc_analysis_destroy(a);
        return 1;
    }
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        const char *name, *super = NULL;
        if (e->kind != OBJC_EV_CLASS_DEF || !e->name || !*e->name) continue;
        if (e->owner && *e->owner) super = own(s, e->owner);
        else if (e->symbol && !strcmp(e->symbol, "root")) super = "-";
        if (!(name = own(s, e->name)) || ((e->owner && *e->owner) && !super) || add_entry(s, name, super, NULL, SRC_BINARY)) {
            s->n = first;
            objc_analysis_destroy(a);
            snprintf(why, whysz, "out of memory");
            return -1;
        }
    }
    objc_analysis_destroy(a);
    return 0;
}

static int entry_cmp(const void *x, const void *y) {
    const Entry *a = x, *b = y;
    int c = strcmp(a->name, b->name);
    if (c) return c;
    if (a->src != b->src) return a->src - b->src;
    return a->seq < b->seq ? -1 : a->seq > b->seq;
}

/* The entry that defines name, binaries first, or NULL: the first of its rows in the sorted table. */
static const Entry *lookup(const RChainSrc *s, const char *name) {
    size_t lo = 0, hi = s->n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (strcmp(s->e[mid].name, name) < 0) lo = mid + 1;
        else hi = mid;
    }
    return lo < s->n && !strcmp(s->e[lo].name, name) ? &s->e[lo] : NULL;
}

static int name_cmp(const void *x, const void *y) {
    const Name *a = x, *b = y;
    int c = memcmp(a->p, b->p, a->n < b->n ? a->n : b->n);
    return c ? c : (a->n > b->n) - (a->n < b->n);
}

static int name_origin_cmp(const void *x, const void *y) {
    const Name *a = x, *b = y;
    int c = name_cmp(a, b);
    return c ? c : a->from_swapper - b->from_swapper;
}

/* The bytes an NSClassSwapper value names: data or a string, or an object holding them in NS.bytes. */
static int swapper_name(const RGraph *g, const RValue *v, Name *out) {
    if (v && v->type == RV_REF) v = v->u.ref < g->n_objs ? rg_get(g, v->u.ref, "NS.bytes") : NULL;
    if (!v || (v->type != RV_DATA && v->type != RV_STRING)) return 0;
    if (!v->u.d.n || v->u.d.n > NAME_MAX_BYTES || memchr(v->u.d.p, 0, v->u.d.n)) return 0;
    out->p = (const char *)v->u.d.p;
    out->n = v->u.d.n;
    out->from_swapper = 1;
    return 1;
}

static char *dup_n(const char *p, size_t n) {
    char *c = malloc(n + 1);
    if (c) { memcpy(c, p, n); c[n] = 0; }
    return c;
}

static void free_chain(RChain *c) {
    size_t j;
    for (j = 0; j < c->n_chain; j++) free(c->chain[j]);
    free(c->chain);
    free(c->cls);
    free(c->newer);
}

/* ib_ok: the name is an object's own class, never a swapper's, so an unlisted IB* name is nib-internal. */
static int walk(const RChainSrc *s, RChain *c, int ib_ok) {
    const char *cur = c->cls, *newer = NULL, *walked[CHAIN_MAX + 1];
    size_t n = 0, j;
    int resolved = 0;
    for (;;) {
        const Entry *e;
        if (n == CHAIN_MAX) break;
        walked[n++] = cur;
        if (!(e = lookup(s, cur))) {
            if (n == 1 && ib_ok && !strncmp(cur, "IB", 2)) { walked[n++] = "NSObject"; resolved = 1; }
            break;
        }
        if (!e->super) break;
        if (e->src == SRC_NEWER) {
            const char *v = strcmp(e->version, "-") ? e->version : "?";
            if (version_cmp(v, s->target) > 0 && (!newer || version_cmp(v, newer) > 0)) newer = v;
        }
        if (!strcmp(e->super, "-") || !strcmp(e->super, "root")) { resolved = 1; break; }
        cur = e->super;
    }
    if (!resolved) n = 1, newer = NULL;
    if (!(c->chain = calloc(n, sizeof *c->chain))) return -1;
    for (j = 0; j < n; j++) {
        if (!(c->chain[j] = dup_n(walked[j], strlen(walked[j])))) return -1;
        c->n_chain = j + 1;
    }
    if (newer && !(c->newer = dup_n(newer, strlen(newer)))) return -1;
    c->resolved = resolved;
    return 0;
}

int rc_resolve(RChainSrc *s, RGraph *g) {
    Name *names = NULL, *nn;
    size_t n = 0, i, k, u;
    static const char *const keys[] = { "NSClassName", "NSOriginalClassName" };
    RChain *chains = NULL;
    if (!s->sorted) { qsort(s->e, s->n, sizeof *s->e, entry_cmp); s->sorted = 1; }
    for (i = 0; i < g->n_chains; i++) free_chain(&g->chains[i]);
    free(g->chains);
    g->chains = NULL;
    g->n_chains = 0;
    for (i = 0; i < g->n_objs; i++) {
        Name m;
        if (!(nn = grown(names, n, sizeof *names))) goto oom;
        names = nn;
        names[n].p = g->objs[i].cls;
        names[n].n = strlen(g->objs[i].cls);
        names[n++].from_swapper = 0;
        if (strcmp(g->objs[i].cls, "NSClassSwapper")) continue;
        for (k = 0; k < sizeof keys / sizeof *keys; k++) {
            if (!swapper_name(g, rg_get(g, (uint32_t)i, keys[k]), &m)) continue;
            if (!(nn = grown(names, n, sizeof *names))) goto oom;
            names = nn;
            names[n++] = m;
        }
    }
    if (n) qsort(names, n, sizeof *names, name_origin_cmp);
    for (i = u = 0; i < n; i++)
        if (!u || name_cmp(&names[u - 1], &names[i])) names[u++] = names[i];
    if (u && !(chains = calloc(u, sizeof *chains))) goto oom;
    for (i = 0; i < u; i++) {
        if (!(chains[i].cls = dup_n(names[i].p, names[i].n)) || walk(s, &chains[i], !names[i].from_swapper)) {
            for (k = 0; k <= i; k++) free_chain(&chains[k]);
            free(chains);
            goto oom;
        }
    }
    free(names);
    g->chains = chains;
    g->n_chains = u;
    return 0;
oom:
    free(names);
    return -1;
}
