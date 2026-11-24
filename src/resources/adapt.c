#include "adapt.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { TRANSLATE, WRAPPING, N_RULES };
static const char *const rule_name[N_RULES] = { "translate-autoresizing", "wrapping-width" };
static const char *const DNT = "NSDoNotTranslateAutoresizingMask", *const PMLW = "NSPreferredMaxLayoutWidth";

struct RAdaptSet { int applies[N_RULES], on[N_RULES]; };

static int version_ok(const char *v) {
    const char *p = v;
    if (!*p) return 0;
    for (; *p; p++)
        if (!((*p >= '0' && *p <= '9') || (*p == '.' && p != v && p[-1] != '.' && p[1]))) return 0;
    return 1;
}

static int version_cmp(const char *a, const char *b) {
    while (*a || *b) {
        char *ea, *eb;
        unsigned long x = strtoul(a, &ea, 10), y = strtoul(b, &eb, 10);
        if (x != y) return x < y ? -1 : 1;
        a = *ea == '.' ? ea + 1 : ea;
        b = *eb == '.' ? eb + 1 : eb;
    }
    return 0;
}

static int rule_index(const char *rule) {
    int r;
    for (r = 0; r < N_RULES; r++)
        if (!strcmp(rule, rule_name[r])) return r;
    return -1;
}

int ra_known(const char *rule) { return rule && rule_index(rule) >= 0; }

/* adapt.tsv: "#" lines, then RULE<TAB>APPLIES_BELOW<TAB>NOTE, each rule exactly once. */
RAdaptSet *ra_default(const char *refdir_resources, const char *target) {
    char path[4096], line[4096], *f[3], *p;
    int seen[N_RULES] = { 0 }, r, n, ok = 1;
    FILE *in;
    RAdaptSet *s;
    if (!refdir_resources || !target || !version_ok(target)
        || snprintf(path, sizeof path, "%s/adapt.tsv", refdir_resources) >= (int)sizeof path
        || !(in = fopen(path, "r")))
        return NULL;
    if (!(s = calloc(1, sizeof *s))) { fclose(in); return NULL; }
    while (ok && fgets(line, sizeof line, in)) {
        size_t len = strlen(line);
        if (!len || line[len - 1] != '\n') { ok = 0; break; }
        line[len - 1] = 0;
        if (line[0] == '#') continue;
        for (n = 0, p = line; n < 3 && p; n++) {
            f[n] = p;
            if ((p = strchr(p, '\t'))) *p++ = 0;
        }
        if (n != 3 || p || (r = rule_index(f[0])) < 0 || seen[r] || !version_ok(f[1]) || !*f[2]) { ok = 0; break; }
        seen[r] = 1;
        s->applies[r] = s->on[r] = version_cmp(target, f[1]) < 0;
    }
    if (ferror(in)) ok = 0;
    fclose(in);
    for (r = 0; r < N_RULES; r++)
        if (!seen[r]) ok = 0;
    if (!ok) { free(s); return NULL; }
    return s;
}

void ra_free(RAdaptSet *s) { free(s); }

int ra_disable(RAdaptSet *s, const char *rule) {
    int r;
    if (!rule) {
        for (r = 0; r < N_RULES; r++) s->on[r] = 0;
        return 0;
    }
    if ((r = rule_index(rule)) < 0) return 2;
    s->on[r] = 0;
    return 0;
}

static int is_a(const RGraph *g, const char *cls, const char *want) {
    const RChain *c;
    size_t i;
    if (!strcmp(cls, want)) return 1;
    if (!(c = rg_chain(g, cls)) || !c->resolved) return 0;
    for (i = 0; i < c->n_chain; i++)
        if (!strcmp(c->chain[i], want)) return 1;
    return 0;
}

static RValue *value(RGraph *g, uint32_t obj, const char *key) {
    size_t i;
    for (i = 0; i < g->objs[obj].n_vals; i++)
        if (!strcmp(g->objs[obj].vals[i].key, key)) return &g->objs[obj].vals[i];
    return NULL;
}

static int is_int(const RValue *v) { return v->type <= RV_I64; }

static int ref_of(const RGraph *g, uint32_t obj, const char *key, uint32_t *out) {
    const RValue *v = rg_get(g, obj, key);
    if (!v || v->type != RV_REF || v->u.ref >= g->n_objs) return 0;
    *out = v->u.ref;
    return 1;
}

/* The string a value holds directly, or through an NSString object's NS.bytes or NS.string, NUL-terminated in buf. */
static int string_of(const RGraph *g, const RValue *v, char *buf, size_t bufsz) {
    if (v && v->type == RV_REF && v->u.ref < g->n_objs) {
        const RValue *b = rg_get(g, v->u.ref, "NS.bytes");
        v = b ? b : rg_get(g, v->u.ref, "NS.string");
    }
    if (!v || (v->type != RV_DATA && v->type != RV_STRING) || v->u.d.n >= bufsz || memchr(v->u.d.p, 0, v->u.d.n)) return 0;
    memcpy(buf, v->u.d.p, v->u.d.n);
    buf[v->u.d.n] = 0;
    return 1;
}

/* A plain decimal number, as NSStringFromRect writes one, at *p; advances past it. */
static int number(const char **p, double *out) {
    const char *s = *p, *q = s;
    char tmp[64];
    if (*q == '-') q++;
    if (*q < '0' || *q > '9') return 0;
    while (*q >= '0' && *q <= '9') q++;
    if (*q == '.') for (q++; *q >= '0' && *q <= '9'; q++) {}
    if (*q == 'e' || *q == 'E') {
        q++;
        if (*q == '-' || *q == '+') q++;
        if (*q < '0' || *q > '9') return 0;
        while (*q >= '0' && *q <= '9') q++;
    }
    if ((size_t)(q - s) >= sizeof tmp) return 0;
    memcpy(tmp, s, (size_t)(q - s));
    tmp[q - s] = 0;
    *out = strtod(tmp, NULL);
    *p = q;
    return isfinite(*out);
}

static int lit(const char **p, const char *want) {
    while (**p == ' ') (*p)++;
    if (strncmp(*p, want, strlen(want))) return 0;
    *p += strlen(want);
    while (**p == ' ') (*p)++;
    return 1;
}

/* "{w, h}" into *w. */
static int size_of(const char **p, double *w) {
    double h;
    return lit(p, "{") && number(p, w) && lit(p, ",") && number(p, &h) && lit(p, "}");
}

/* The width of an NSFrame "{{x, y}, {w, h}}" or NSFrameSize "{w, h}"; 0 with why set when it cannot be read. */
static int frame_width(const RGraph *g, uint32_t obj, double *w, char *why, size_t whysz) {
    char buf[256];
    const char *p, *key = "NSFrame";
    const RValue *v = rg_get(g, obj, key);
    double x;
    int ok;
    if (!v) v = rg_get(g, obj, key = "NSFrameSize");
    if (!v) { snprintf(why, whysz, "no NSFrame or NSFrameSize"); return 0; }
    if (!string_of(g, v, buf, sizeof buf)) { snprintf(why, whysz, "%s is not a string", key); return 0; }
    p = buf;
    ok = strcmp(key, "NSFrame") ? size_of(&p, w)
                                : lit(&p, "{") && size_of(&p, &x) && lit(&p, ",") && size_of(&p, w) && lit(&p, "}");
    if (!ok || *p) { snprintf(why, whysz, "%s \"%s\" is not a rectangle", key, buf); return 0; }
    if (!(*w > 4)) { snprintf(why, whysz, "%s width %g leaves no preferred width", key, *w); return 0; }
    return 1;
}

/* Whether 10.9 wraps the cell: NSCellFlags2's line break mode (bits 9-11) when set, word or character wrapping,
 * else NSCellFlags' clipping bit 0x40 clear. Absent flags are 0, as 10.9 decodes them. */
static int wraps(const RGraph *g, uint32_t cell, int *out, char *why, size_t whysz) {
    const RValue *f = rg_get(g, cell, "NSCellFlags"), *f2 = rg_get(g, cell, "NSCellFlags2");
    int64_t a = 0, b = 0, mode;
    if ((f && !is_int(f)) || (f2 && !is_int(f2))) {
        snprintf(why, whysz, "@%lu %s is not an integer", (unsigned long)cell, f && !is_int(f) ? "NSCellFlags" : "NSCellFlags2");
        return 0;
    }
    if (f) a = f->u.i;
    if (f2) b = f2->u.i;
    mode = (b >> 9) & 7;
    *out = mode ? mode == 1 : !(a & 0x40);
    return 1;
}

static int is_zero(const RValue *v) {
    if (!v) return 1;
    if (is_int(v)) return v->u.i == 0;
    if (v->type == RV_F64) return v->u.f == 0;
    if (v->type == RV_F32) return !(v->u.f32 & 0x7fffffffu);
    return 0;
}

/* One rewrite a rule wants: obj's key, and for wrapping-width the width; or a finding it cannot fix. */
typedef struct { int rule; uint32_t obj; int fixable; double width; char why[300]; } Want;
typedef struct { Want *v; size_t n, cap; } Wants;

static int want(Wants *w, int rule, uint32_t obj, int fixable, double width, const char *why) {
    if (w->n == w->cap) {
        size_t cap = w->cap ? 2 * w->cap : 16;
        Want *v = cap > SIZE_MAX / sizeof *v ? NULL : realloc(w->v, cap * sizeof *v);
        if (!v) return -1;
        w->v = v;
        w->cap = cap;
    }
    w->v[w->n].rule = rule;
    w->v[w->n].obj = obj;
    w->v[w->n].fixable = fixable;
    w->v[w->n].width = width;
    snprintf(w->v[w->n].why, sizeof w->v[w->n].why, "%s", why);
    w->n++;
    return 0;
}

/* What each rule in rules[] wants of g, in object order: 0, or -1 out of memory. */
static int scan(const RGraph *g, const int rules[N_RULES], Wants *out) {
    unsigned char *mark;
    size_t i;
    uint32_t r;
    enum { ITEM = 1, CONTENT = 2 };
    if (!g->n_objs) return 0;
    if (!(mark = calloc(g->n_objs, 1))) return -1;
    for (i = 0; i < g->n_objs; i++) {
        char buf[RF_CLASS_MAX];
        const char *cls = rf_class_of(g, (uint32_t)i, buf);
        if (g->objs[i].bare) continue;
        if (is_a(g, cls, "NSLayoutConstraint")) {
            if (ref_of(g, (uint32_t)i, "NSFirstItem", &r)) mark[r] |= ITEM;
            if (ref_of(g, (uint32_t)i, "NSSecondItem", &r)) mark[r] |= ITEM;
        } else if (is_a(g, cls, "NSWindowTemplate")) {
            if (ref_of(g, (uint32_t)i, "NSWindowView", &r)) mark[r] |= CONTENT;
        } else if (is_a(g, cls, "NSBox")) {
            if (ref_of(g, (uint32_t)i, "NSContentView", &r)) mark[r] |= CONTENT;
        }
    }
    for (i = 0; i < g->n_objs; i++) {
        char buf[RF_CLASS_MAX];
        const char *cls = rf_class_of(g, (uint32_t)i, buf);
        const RValue *v;
        uint32_t o = (uint32_t)i, cell;
        char why[300];
        if (!(mark[i] & ITEM) || g->objs[i].bare || !is_a(g, cls, "NSView")) continue;
        if (rules[TRANSLATE] && !(mark[i] & CONTENT)) {
            v = rg_get(g, o, DNT);
            if (v && (v->type == RV_FALSE || (is_int(v) && !v->u.i))) {
                snprintf(why, sizeof why, "false");
                if (want(out, TRANSLATE, o, 1, 0, why)) goto oom;
            } else if (v && v->type != RV_TRUE && !is_int(v)) {
                snprintf(why, sizeof why, "is not a boolean");
                if (want(out, TRANSLATE, o, 0, 0, why)) goto oom;
            }
        }
        if (rules[WRAPPING] && is_a(g, cls, "NSTextField") && is_zero(v = rg_get(g, o, PMLW))) {
            int w;
            double width;
            char what[300];
            if (!ref_of(g, o, "NSCell", &cell)) continue;
            if (!wraps(g, cell, &w, what, sizeof what)) {
                if (want(out, WRAPPING, o, 0, 0, what)) goto oom;
                continue;
            }
            if (!w) continue;
            if (!frame_width(g, o, &width, what, sizeof what)) {
                if (want(out, WRAPPING, o, 0, 0, what)) goto oom;
                continue;
            }
            snprintf(why, sizeof why, "%s, %s width %g", v ? "0" : "absent",
                     rg_get(g, o, "NSFrame") ? "NSFrame" : "NSFrameSize", width);
            if (want(out, WRAPPING, o, 1, width - 4, why)) goto oom;
        }
    }
    free(mark);
    return 0;
oom:
    free(mark);
    return -1;
}

int ra_check(const RAdaptSet *s, const RGraph *g, const char *nib, RFindings *out) {
    Wants w = { NULL, 0, 0 };
    size_t i;
    int rc = 0;
    if (scan(g, s->applies, &w)) return 4;
    for (i = 0; i < w.n && !rc; i++) {
        const Want *x = &w.v[i];
        char buf[RF_CLASS_MAX];
        RfSeverity sev = x->fixable && s->on[x->rule] ? RF_WILL_ADAPT : RF_FINDING;
        if (rf_add(out, rule_name[x->rule], nib, rf_class_of(g, x->obj, buf), sev, "@%lu %s %s", (unsigned long)x->obj,
                   x->rule == TRANSLATE ? DNT : PMLW, x->why))
            rc = 4;
    }
    free(w.v);
    return rc;
}

int ra_apply(const RAdaptSet *s, RGraph *g, RFindings *log) {
    Wants w = { NULL, 0, 0 };
    int on[N_RULES], r, rc = 0;
    const char *key[N_RULES] = { NULL, NULL };
    size_t i;
    for (r = 0; r < N_RULES; r++) on[r] = s->applies[r] && s->on[r];
    if (scan(g, on, &w)) return 4;
    for (i = 0; i < w.n && !rc; i++) {
        const Want *x = &w.v[i];
        RValue nv, *v;
        char buf[RF_CLASS_MAX];
        if (!x->fixable) {
            if (rf_add(log, rule_name[x->rule], NULL, rf_class_of(g, x->obj, buf), RF_FINDING, "@%lu %s %s",
                       (unsigned long)x->obj, x->rule == TRANSLATE ? DNT : PMLW, x->why))
                rc = 4;
            continue;
        }
        memset(&nv, 0, sizeof nv);
        if (x->rule == TRANSLATE) nv.type = RV_TRUE;
        else { nv.type = RV_F64; nv.u.f = x->width; }
        if ((v = value(g, x->obj, x->rule == TRANSLATE ? DNT : PMLW))) {
            nv.key = v->key;
            *v = nv;   /* the old value was a boolean or a number, which own no memory */
        } else {
            const char *name = x->rule == TRANSLATE ? DNT : PMLW;
            if (!key[x->rule] && !(key[x->rule] = rg_intern(g, name, strlen(name)))) { rc = 4; break; }
            nv.key = key[x->rule];
            if (rg_add_value(g, x->obj, &nv)) { rc = 4; break; }
        }
        if (rf_add(log, "adapted", NULL, rule_name[x->rule], RF_ADAPTED, "@%lu %s", (unsigned long)x->obj,
                   x->rule == TRANSLATE ? DNT : PMLW))
            rc = 4;
    }
    free(w.v);
    return rc;
}
