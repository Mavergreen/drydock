#include "graph.h"

#include <stdlib.h>
#include <string.h>

/* Arrays grow by doubling: an n that is 0 or a power of two is full. */
static void *grown(void *p, size_t n, size_t size) {
    if (n & (n - 1)) return p;
    if (n > SIZE_MAX / 2 / size) return NULL;
    return realloc(p, (n ? 2 * n : 1) * size);
}

static void free_value(RValue *v) {
    if (v->type == RV_DATA || v->type == RV_STRING) free(v->u.d.p);
    else if (v->type == RV_UID_ARRAY) free(v->u.refs.v);
}

void rg_free(RGraph *g) {
    size_t i, j;
    for (i = 0; i < g->n_objs; i++) {
        for (j = 0; j < g->objs[i].n_vals; j++) free_value(&g->objs[i].vals[j]);
        free(g->objs[i].vals);
    }
    free(g->objs);
    for (i = 0; i < g->n_chains; i++) {
        for (j = 0; j < g->chains[i].n_chain; j++) free(g->chains[i].chain[j]);
        free(g->chains[i].chain);
        free(g->chains[i].cls);
        free(g->chains[i].newer);
    }
    free(g->chains);
    for (i = 0; i < g->n_strs; i++) free(g->strs[i]);
    free(g->strs);
    memset(g, 0, sizeof *g);
}

const char *rg_intern(RGraph *g, const char *s, size_t n) {
    char **t, *c;
    if (n == SIZE_MAX || memchr(s, 0, n) || !(t = grown(g->strs, g->n_strs, sizeof *t))) return NULL;
    g->strs = t;
    if (!(c = malloc(n + 1))) return NULL;
    memcpy(c, s, n);
    c[n] = 0;
    return t[g->n_strs++] = c;
}

int rg_add_object(RGraph *g, const char *cls) {
    RObject *o;
    if (g->n_objs >= (size_t)INT32_MAX) return -1;
    if (!(o = grown(g->objs, g->n_objs, sizeof *o))) return -1;
    g->objs = o;
    o[g->n_objs].cls = cls;
    o[g->n_objs].vals = NULL;
    o[g->n_objs].n_vals = 0;
    return (int)g->n_objs++;
}

int rg_add_value(RGraph *g, uint32_t obj, const RValue *v) {
    RObject *o;
    RValue c, *vs;
    if (obj >= g->n_objs) return -1;
    o = &g->objs[obj];
    if (!(vs = grown(o->vals, o->n_vals, sizeof *vs))) return -1;
    o->vals = vs;
    c = *v;
    if (v->type == RV_DATA || v->type == RV_STRING) {
        if (!(c.u.d.p = malloc(v->u.d.n ? v->u.d.n : 1))) return -1;
        if (v->u.d.n) memcpy(c.u.d.p, v->u.d.p, v->u.d.n);
    } else if (v->type == RV_UID_ARRAY) {
        if (v->u.refs.n > SIZE_MAX / sizeof *c.u.refs.v
            || !(c.u.refs.v = malloc(v->u.refs.n ? v->u.refs.n * sizeof *c.u.refs.v : 1))) return -1;
        if (v->u.refs.n) memcpy(c.u.refs.v, v->u.refs.v, v->u.refs.n * sizeof *c.u.refs.v);
    }
    o->vals[o->n_vals++] = c;
    return 0;
}

const RValue *rg_get(const RGraph *g, uint32_t obj, const char *key) {
    size_t i;
    if (obj >= g->n_objs) return NULL;
    for (i = 0; i < g->objs[obj].n_vals; i++)
        if (!strcmp(g->objs[obj].vals[i].key, key)) return &g->objs[obj].vals[i];
    return NULL;
}

static int chain_key(const void *k, const void *c) { return strcmp(k, ((const RChain *)c)->cls); }

const RChain *rg_chain(const RGraph *g, const char *cls) {
    return g->n_chains ? bsearch(cls, g->chains, g->n_chains, sizeof *g->chains, chain_key) : NULL;
}
