/* reference.c -- load the SDK reference facts receiver closure consumes.
 *
 * Two inputs, both produced by tools/objc-sdk-inventory.c from one pinned SDK:
 *   - signatures_path: the --signature-output companion, schema 1 (its header line, then eight
 *     TAB-separated columns: record, owner, kind, selector, result kind, result class, source,
 *     container). Only declared results are loaded; nothing is inferred from an ABI encoding.
 *   - facts_path: the eleven-column facts; only `class` rows are read, for each interface's
 *     declared superclass (column 5, "-" for a root).
 * Either may be absent; closure then leaves open whatever needed it. A present but unreadable,
 * malformed or truncated file is cannot-measure, never a partial load. The analyzer points both at
 * the versioned set (reference/objc), whose manifest main.m verifies first; the rest of that set
 * loads below (objc_load_reference_set). */
#include "report.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE_MAX_BYTES 65536

/* Splits `line` in place on TABs into at most `max` fields; returns the count. */
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

static int load_file(ObjcAnalysis *a, const char *path, int signatures) {
    FILE *f;
    char *line;
    size_t lineno = 0;
    int status = OBJC_OK;
    if (!(f = fopen(path, "r")))
        return objc_fail(a, "unreadable-reference", NULL, 0, "%s: %s", path, strerror(errno));
    if (!(line = malloc(LINE_MAX_BYTES))) { fclose(f); return objc_fail(a, "out-of-memory", NULL, 0, "reference"); }
    while (status == OBJC_OK && fgets(line, LINE_MAX_BYTES, f)) {
        char *col[12];
        size_t len = strlen(line);
        int n;
        lineno++;
        if (!len || line[len - 1] != '\n') {
            status = objc_fail(a, "malformed-reference", NULL, 0, "%s:%zu unterminated or too long", path, lineno);
            break;
        }
        line[len - 1] = 0;
        if (signatures && lineno == 1) {
            if (strcmp(line, "# objc-signatures 1"))
                status = objc_fail(a, "malformed-reference", NULL, 0, "%s: missing schema-1 header", path);
            continue;
        }
        n = split(line, col, 11);
        if (signatures) {
            ObjcSignature s;
            if (n != 8 || (strcmp(col[2], "+") && strcmp(col[2], "-")) ||
                (strcmp(col[4], "class") && strcmp(col[4], "instancetype") && strcmp(col[4], "id") &&
                 strcmp(col[4], "other") && strcmp(col[4], "unknown")) ||
                (!strcmp(col[4], "class") == !strcmp(col[5], "-"))) {
                status = objc_fail(a, "malformed-reference", NULL, 0, "%s:%zu not a schema-1 signature", path, lineno);
                break;
            }
            s.record = col[0]; s.owner = col[1]; s.method_kind = col[2]; s.selector = col[3];
            s.result_kind = col[4]; s.result_class = !strcmp(col[5], "-") ? NULL : col[5]; s.source = col[6];
            if (objc_add_signature(a, &s)) status = OBJC_CANNOT_MEASURE;
        } else {
            ObjcClassFact c;
            if (n != 11) {
                status = objc_fail(a, "malformed-reference", NULL, 0, "%s:%zu not an eleven-column fact", path, lineno);
                break;
            }
            if (strcmp(col[0], "class")) continue;
            c.name = col[2]; c.super = !strcmp(col[4], "-") ? NULL : col[4];
            if (objc_add_class_fact(a, &c)) status = OBJC_CANNOT_MEASURE;
        }
    }
    if (status == OBJC_OK && ferror(f)) status = objc_fail(a, "unreadable-reference", NULL, 0, "%s: read error", path);
    if (status == OBJC_OK && signatures && lineno == 0)
        status = objc_fail(a, "malformed-reference", NULL, 0, "%s: empty, not even a header", path);
    free(line);
    fclose(f);
    return status;
}

int objc_load_references(ObjcAnalysis *a) {
    int rc = OBJC_OK;
    if (a->signatures_path && load_file(a, a->signatures_path, 1)) rc = OBJC_CANNOT_MEASURE;
    if (a->facts_path && load_file(a, a->facts_path, 0)) rc = OBJC_CANNOT_MEASURE;
    a->references_loaded = rc == OBJC_OK;
    return rc;
}

/* ---- string map ---------------------------------------------------------------------------- */

struct ObjcMap { char **keys, **vals; size_t cap, n; };

ObjcMap *objc_map_create(void) {
    ObjcMap *m = calloc(1, sizeof *m);
    if (m && !(m->keys = calloc(m->cap = 1024, sizeof *m->keys))) { free(m); return NULL; }
    if (m && !(m->vals = calloc(m->cap, sizeof *m->vals))) { free(m->keys); free(m); return NULL; }
    return m;
}

void objc_map_destroy(ObjcMap *m) {
    size_t i;
    if (!m) return;
    for (i = 0; i < m->cap; i++) { free(m->keys[i]); free(m->vals[i]); }
    free(m->keys); free(m->vals); free(m);
}

static size_t map_hash(const char *k) {
    size_t h = 1469598103934665603ULL;
    while (*k) { h ^= (unsigned char)*k++; h *= 1099511628211ULL; }
    return h;
}

static size_t map_slot(const ObjcMap *m, const char *k) {
    size_t i = map_hash(k) & (m->cap - 1);
    while (m->keys[i] && strcmp(m->keys[i], k)) i = (i + 1) & (m->cap - 1);
    return i;
}

int objc_map_put(ObjcMap *m, const char *key, const char *value) {
    size_t i;
    if ((m->n + 1) * 2 > m->cap) {
        ObjcMap g;
        g.cap = m->cap * 2; g.n = m->n;
        if (g.cap < m->cap || !(g.keys = calloc(g.cap, sizeof *g.keys))) return -1;
        if (!(g.vals = calloc(g.cap, sizeof *g.vals))) { free(g.keys); return -1; }
        for (i = 0; i < m->cap; i++)
            if (m->keys[i]) { size_t j = map_slot(&g, m->keys[i]); g.keys[j] = m->keys[i]; g.vals[j] = m->vals[i]; }
        free(m->keys); free(m->vals);
        *m = g;
    }
    i = map_slot(m, key);
    if (m->keys[i]) return 1;
    if (!(m->keys[i] = strdup(key))) return -1;
    if (!(m->vals[i] = strdup(value ? value : ""))) { free(m->keys[i]); m->keys[i] = NULL; return -1; }
    m->n++;
    return 0;
}

const char *objc_map_get(const ObjcMap *m, const char *key) {
    size_t i;
    if (!m) return NULL;
    i = map_slot(m, key);
    return m->keys[i] ? m->vals[i] : NULL;
}

/* ---- the versioned reference set ------------------------------------------------------------
 *
 * floor-runtime.tsv (tools/objc-runtime-inventory.m header, schema 1) gives what the floor host
 * measured: class rows (superclass, root, image), active method rows for the required images,
 * the R1 root-method witness and NSProxy behavior rows, image roles and overrides. Its identity
 * rows must be the manifest's runtime identity; a capture that is not production, carries a
 * refusal, or whose witness does not cover every class for both kinds of every reviewed root
 * selector -- the manifest's root_selectors, exactly -- is cannot-measure, never a partial R1.
 * The witness's non-implementing classes must be the manifest's root_exceptions, exactly
 * (witness_exceptions below; the R1 amendment in the plan), and so must each root selector's own,
 * but for a selector the manifest's root_subset_exceptions records (the plan's R1 selector set:
 * retain, release, autorelease, +class): each of its reviewed kinds must measure exactly the
 * recorded set, which must be a strict subset of root_exceptions; a kind it does not list (-class)
 * is held to root_exceptions like every other root selector. Any other set, recorded or measured,
 * is cannot-measure.
 * NSProxy behavior rows are kept as
 * measured facts but no longer decide R1, which rests on existence alone.
 * newer-sdk.tsv is the later-API catalog (declared introductions), floor-sdk.tsv the floor's
 * declarations. Lookups are keyed "CLASS<TAB>KIND<TAB>SELECTOR". */

static int map_put3(ObjcAnalysis *a, ObjcMap *m, const char *x, const char *y, const char *z, const char *v) {
    char key[1024];
    int r;
    if (snprintf(key, sizeof key, "%s\t%s\t%s", x, y, z) >= (int)sizeof key)
        return objc_fail(a, "malformed-reference", NULL, 0, "key too long: %s %s", x, z);
    r = objc_map_put(m, key, v);
    return r < 0 ? objc_fail(a, "out-of-memory", NULL, 0, "reference map") : OBJC_OK;
}

static int open_rows(ObjcAnalysis *a, const char *name, FILE **f, char **line) {
    char path[4096];
    if (snprintf(path, sizeof path, "%s/%s", a->references_dir, name) >= (int)sizeof path)
        return objc_fail(a, "unreadable-reference", NULL, 0, "path too long");
    if (!(*f = fopen(path, "r"))) return objc_fail(a, "unreadable-reference", NULL, 0, "%s: %s", path, strerror(errno));
    if (!(*line = malloc(LINE_MAX_BYTES))) { fclose(*f); return objc_fail(a, "out-of-memory", NULL, 0, "reference"); }
    return OBJC_OK;
}

static int by_bytes(const void *x, const void *y) { return strcmp(*(char *const *)x, *(char *const *)y); }
static void drop_strv(char **v, size_t n) { size_t i; for (i = 0; i < n; i++) free(v[i]); free(v); }

/* The manifest's root_subset_exceptions entry for SEL ("SEL\tKINDS\tCLASS ..."), or NULL. */
static const char *subset_of(const ObjcAnalysis *a, const char *sel) {
    size_t i, n = strlen(sel);
    for (i = 0; i < a->n_manifest_subsets; i++)
        if (!strncmp(a->manifest_subsets[i], sel, n) && a->manifest_subsets[i][n] == '\t') return a->manifest_subsets[i];
    return NULL;
}
static const char *subset_classes(const char *e) { return strchr(strchr(e, '\t') + 1, '\t') + 1; }
static int in_words(const char *words, const char *w) {
    size_t n = strlen(w);
    const char *p = words;
    while ((p = strstr(p, w))) {
        if ((p == words || p[-1] == ' ') && (p[n] == ' ' || !p[n])) return 1;
        p += n;
    }
    return 0;
}

/* Whether a recorded subset covers KIND ("+" or "-"), or both kinds when KIND is NULL. */
static int subset_covers(const char *e, const char *kind) {
    const char *k = strchr(e, '\t') + 1;
    if (!strncmp(k, "+-\t", 3)) return 1;
    return kind && k[0] == kind[0];
}

const char *objc_r1_subset_kinds(const ObjcAnalysis *a, const char *sel) {
    const char *e = subset_of(a, sel), *k;
    if (!e) return NULL;
    k = strchr(e, '\t') + 1;
    return !strncmp(k, "+-\t", 3) ? "+-" : k[0] == '+' ? "+" : "-";
}

int objc_r1_reviewed(const ObjcAnalysis *a, const char *kind, const char *sel) {
    size_t i;
    for (i = 0; i < a->n_root_selectors && strcmp(a->root_selectors[i], sel); i++) ;
    return i < a->n_root_selectors && kind && (kind[0] == '+' || kind[0] == '-') && !kind[1];
}

void objc_r1_selector_exceptions(const ObjcAnalysis *a, const char *kind, const char *sel, char *out, size_t outsz) {
    const char *e = subset_of(a, sel);
    size_t i, at = 0;
    if (e && subset_covers(e, kind)) { snprintf(out, outsz, "%s", subset_classes(e)); return; }
    out[0] = 0;
    for (i = 0; i < a->n_r1_exceptions && at + 2 < outsz; i++)
        at += (size_t)snprintf(out + at, outsz - at, "%s%s", i ? " " : "", a->r1_exceptions[i]);
}

/* The R1 amendment. The witness measures existence: a class is an exception when some witness row
 * (either kind, any reviewed root selector) does not resolve -- NSProxy-rooted classes resolve
 * them and are not exceptions. The measured set must be exactly the manifest's root_exceptions,
 * the reviewed residual risk; anything else (a new exception, one gone, no reviewed list) is
 * cannot-measure, never auto-accepted. It must also be that set for every root selector and kind
 * on its own: an exception that resolves one of them makes that selector's exception set another
 * one, which is a different residual risk, not the reviewed one. A selector with a recorded subset
 * is held, for each reviewed kind, to that subset instead, and the subset must be a strict one.
 * On success a->r1_exceptions holds the set, sorted. */
static int witness_exceptions(ObjcAnalysis *a) {
    char **got = NULL, msg[2048];
    size_t ngot = 0, i, j, at = 0;
    int same;
    for (i = 0; i < a->n_rt_classes; i++) {
        const char *cls = a->rt_classes[i].name;
        int exc = 0;
        for (j = 0; j < a->n_root_selectors * 2 && !exc; j++) {
            char key[1024];
            const char *w;
            snprintf(key, sizeof key, "%s\t%s\t%s", cls, j & 1 ? "+" : "-", a->root_selectors[j / 2]);
            exc = !(w = objc_map_get(a->rt_witness, key)) || (w[0] == '-' && w[1] == '\t');
        }
        if (exc && objc_strv_push(&got, &ngot, cls)) { drop_strv(got, ngot); return objc_fail(a, "out-of-memory", NULL, 0, "witness"); }
    }
    if (ngot) qsort(got, ngot, sizeof *got, by_bytes);
    same = a->have_manifest_exceptions && ngot == a->n_manifest_exceptions;
    for (i = 0; same && i < ngot; i++) {
        for (j = 0; j < a->n_manifest_exceptions && strcmp(a->manifest_exceptions[j], got[i]); j++) ;
        same = j < a->n_manifest_exceptions;
    }
    if (!same) {
        msg[0] = 0;
        for (i = 0; i < ngot && at + 2 < sizeof msg; i++) at += (size_t)snprintf(msg + at, sizeof msg - at, "%s%s", i ? " " : "", got[i]);
        drop_strv(got, ngot);
        if (!a->have_manifest_exceptions)
            return objc_fail(a, "witness-exceptions-mismatch", NULL, 0, "the witness's non-implementing classes (%s) have no reviewed root_exceptions in the manifest", msg);
        return objc_fail(a, "witness-exceptions-mismatch", NULL, 0, "the witness's non-implementing classes (%s) are not the reviewed root_exceptions (%zu classes)",
                         msg, a->n_manifest_exceptions);
    }
    /* Each recorded subset: one per root selector, of reviewed exceptions only, fewer than all of them. */
    for (i = 0; i < a->n_manifest_subsets; i++) {
        const char *e = a->manifest_subsets[i], *cls = subset_classes(e), *p;
        char sel[256];
        size_t n = 0, k;
        snprintf(sel, sizeof sel, "%.*s", (int)strcspn(e, "\t"), e);
        for (k = 0; k < a->n_root_selectors && strcmp(a->root_selectors[k], sel); k++) ;
        same = k < a->n_root_selectors && subset_of(a, sel) == e;
        for (p = cls; same && *p; n++) {
            char c[256];
            size_t len = strcspn(p, " ");
            snprintf(c, sizeof c, "%.*s", (int)len, p);
            for (k = 0; k < ngot && strcmp(got[k], c); k++) ;
            same = k < ngot && !in_words(p + len, c);
            p += len + (p[len] == ' ');
        }
        if (!same || !n || n >= ngot) {
            snprintf(msg, sizeof msg, "the recorded %s exceptions are not a strict subset of root_exceptions, for a root selector, once (%s)", sel, cls);
            drop_strv(got, ngot);
            return objc_fail(a, "witness-exceptions-mismatch", NULL, 0, "%s", msg);
        }
    }
    /* Each root selector and kind on its own: the reviewed six, or a reviewed kind's recorded subset. */
    for (j = 0; j < a->n_root_selectors * 2; j++) {
        const char *sel = a->root_selectors[j / 2], *kind = j & 1 ? "+" : "-", *e = subset_of(a, sel);
        if (e && !subset_covers(e, kind)) e = NULL;   /* a kind its record does not list (-class): held to the six */
        for (i = 0; i < ngot; i++) {
            char key[1024], measured[1024];
            const char *w;
            int resolves;
            size_t k, mat = 0;
            snprintf(key, sizeof key, "%s\t%s\t%s", got[i], kind, sel);
            resolves = (w = objc_map_get(a->rt_witness, key)) && !(w[0] == '-' && w[1] == '\t');
            if (resolves == (!e || in_words(subset_classes(e), got[i]))) {
                if (!e) {
                    snprintf(msg, sizeof msg, "the witness resolves %s%s %s on reviewed exception %s: that selector's exception set is not the reviewed root_exceptions",
                             kind, got[i], sel, got[i]);
                } else {
                    measured[0] = 0;
                    for (k = 0; k < ngot && mat + 2 < sizeof measured; k++) {
                        snprintf(key, sizeof key, "%s\t%s\t%s", got[k], kind, sel);
                        if (!(w = objc_map_get(a->rt_witness, key)) || (w[0] == '-' && w[1] == '\t'))
                            mat += (size_t)snprintf(measured + mat, sizeof measured - mat, "%s%s", mat ? " " : "", got[k]);
                    }
                    snprintf(msg, sizeof msg, "the witness measures %s%s exceptions (%s), not the recorded (%s)", kind, sel, measured, subset_classes(e));
                }
                drop_strv(got, ngot);
                return objc_fail(a, "witness-exceptions-mismatch", NULL, 0, "%s", msg);
            }
        }
    }
    a->r1_exceptions = got; a->n_r1_exceptions = ngot;
    return OBJC_OK;
}

static int load_runtime(ObjcAnalysis *a) {
    FILE *f; char *line; size_t lineno = 0, i;
    int status, production = 0, os = 0, build = 0, arch = 0;
    if ((status = open_rows(a, "floor-runtime.tsv", &f, &line))) return status;
    while (status == OBJC_OK && fgets(line, LINE_MAX_BYTES, f)) {
        char *c[8], v[1024];
        size_t len = strlen(line);
        lineno++;
        if (!len || line[len - 1] != '\n') { status = objc_fail(a, "malformed-reference", NULL, 0, "floor-runtime.tsv:%zu unterminated", lineno); break; }
        line[len - 1] = 0;
        if (lineno == 1) {
            if (strcmp(line, "# objc-runtime 1")) status = objc_fail(a, "malformed-reference", NULL, 0, "floor-runtime.tsv: not schema 1");
            continue;
        }
        if (split(line, c, 7) != 7) { status = objc_fail(a, "malformed-reference", NULL, 0, "floor-runtime.tsv:%zu not seven columns", lineno); break; }
        if (!strcmp(c[0], "class")) {
            ObjcRtClass k;
            char idx[32];
            if (a->n_rt_classes == a->cap_rt_classes) {
                ObjcRtClass *g = realloc(a->rt_classes, (a->cap_rt_classes = a->cap_rt_classes ? a->cap_rt_classes * 2 : 4096) * sizeof *g);
                if (!g) { status = objc_fail(a, "out-of-memory", NULL, 0, "runtime classes"); break; }
                a->rt_classes = g;
            }
            memset(&k, 0, sizeof k);
            if (objc_set_string(&k.name, c[1]) || objc_set_string(&k.super, strcmp(c[3], "-") ? c[3] : NULL) ||
                objc_set_string(&k.root, c[4]) || objc_set_string(&k.image, c[5])) {
                free(k.name); free(k.super); free(k.root); free(k.image);
                status = objc_fail(a, "out-of-memory", NULL, 0, "runtime class"); break;
            }
            snprintf(idx, sizeof idx, "%zu", a->n_rt_classes);
            a->rt_classes[a->n_rt_classes++] = k;
            if (objc_map_put(a->rt_class, c[1], idx)) { status = objc_fail(a, "malformed-reference", NULL, 0, "class %s twice or out of memory", c[1]); break; }
        } else if (!strcmp(c[0], "method")) {
            if (!strcmp(c[6], "active")) status = map_put3(a, a->rt_method, c[1], c[2], c[3], c[5]);
        } else if (!strcmp(c[0], "witness")) {
            snprintf(v, sizeof v, "%s\t%s\t%s", c[4], c[5], c[6]);
            status = map_put3(a, a->rt_witness, c[1], c[2], c[3], v);
            a->n_witness++;
        } else if (!strcmp(c[0], "behavior")) {
            status = map_put3(a, a->rt_behavior, c[1], c[2], c[3], c[4]);
        } else if (!strcmp(c[0], "image")) {
            if (objc_map_put(a->rt_image_role, c[1], c[5]) < 0) status = objc_fail(a, "out-of-memory", NULL, 0, "image");
            snprintf(v, sizeof v, "@%s", c[3]);
            if (strcmp(c[3], "-") && objc_map_put(a->rt_image_role, v, c[5]) < 0) status = objc_fail(a, "out-of-memory", NULL, 0, "image");
        } else if (!strcmp(c[0], "override")) {
            if (objc_map_put(a->rt_override, c[1], c[3]) < 0) status = objc_fail(a, "out-of-memory", NULL, 0, "override");
        } else if (!strcmp(c[0], "identity")) {
            const char *want = !strcmp(c[1], "os") ? a->runtime_os : !strcmp(c[1], "build") ? a->runtime_build :
                               !strcmp(c[1], "arch") ? a->runtime_arch : NULL;
            if (want && strcmp(want, c[4]))
                status = objc_fail(a, "reference-identity-mismatch", NULL, 0, "floor runtime %s %s, manifest says %s", c[1], c[4], want);
            os |= !strcmp(c[1], "os"); build |= !strcmp(c[1], "build"); arch |= !strcmp(c[1], "arch");
        } else if (!strcmp(c[0], "check")) {
            if (!strcmp(c[1], "mode")) production = !strcmp(c[4], "production");
            else if (!strcmp(c[1], "refusal")) status = objc_fail(a, "unclean-floor-runtime", NULL, 0, "capture refusal: %s", c[4]);
            else if (!strcmp(c[1], "root-selector") && !strcmp(c[4], "reviewed") &&
                     objc_strv_push(&a->root_selectors, &a->n_root_selectors, c[3]))
                status = objc_fail(a, "out-of-memory", NULL, 0, "root selector");
        } else if (strcmp(c[0], "class") && strcmp(c[0], "image")) {
            status = objc_fail(a, "malformed-reference", NULL, 0, "floor-runtime.tsv:%zu unknown record %s", lineno, c[0]);
        }
    }
    if (status == OBJC_OK && ferror(f)) status = objc_fail(a, "unreadable-reference", NULL, 0, "floor-runtime.tsv: read error");
    free(line); fclose(f);
    if (status) return status;
    if (!production) return objc_fail(a, "unclean-floor-runtime", NULL, 0, "floor runtime is not a production capture");
    if (!os || !build || !arch || !a->runtime_os)
        return objc_fail(a, "reference-identity-mismatch", NULL, 0, "floor runtime or manifest lacks an os/build/arch identity");
    /* R1's witness: every class, both kinds, every reviewed root selector -- the manifest's list. */
    if (a->n_root_selectors != a->n_manifest_roots)
        return objc_fail(a, "witness-mismatch", NULL, 0, "%zu reviewed root selectors, manifest lists %zu", a->n_root_selectors, a->n_manifest_roots);
    for (i = 0; i < a->n_root_selectors; i++) {
        size_t j;
        for (j = 0; j < a->n_manifest_roots && strcmp(a->manifest_roots[j], a->root_selectors[i]); j++) ;
        if (j == a->n_manifest_roots) return objc_fail(a, "witness-mismatch", NULL, 0, "root selector %s is not the manifest's", a->root_selectors[i]);
    }
    if (a->n_witness && a->n_witness != a->n_rt_classes * a->n_root_selectors * 2)
        return objc_fail(a, "witness-mismatch", NULL, 0, "%zu witness rows for %zu classes and %zu root selectors",
                         a->n_witness, a->n_rt_classes, a->n_root_selectors);
    return a->n_witness ? witness_exceptions(a) : OBJC_OK;
}

/* Whether a declared introduction ("10.10", "11.0") is later than the 10.9 floor. */
static int later_than_floor(const char *v) {
    long major, minor = 0;
    char *end;
    if (!strcmp(v, "-")) return 0;
    major = strtol(v, &end, 10);
    if (*end == '.') minor = strtol(end + 1, NULL, 10);
    return major > 10 || (major == 10 && minor > 9);
}

static int load_sdk(ObjcAnalysis *a, const char *name, ObjcMap *methods, ObjcMap *classes) {
    FILE *f; char *line; size_t lineno = 0;
    int status;
    if ((status = open_rows(a, name, &f, &line))) return status;
    while (status == OBJC_OK && fgets(line, LINE_MAX_BYTES, f)) {
        char *c[12], v[1024];
        size_t len = strlen(line);
        lineno++;
        if (!len || line[len - 1] != '\n') { status = objc_fail(a, "malformed-reference", NULL, 0, "%s:%zu unterminated", name, lineno); break; }
        line[len - 1] = 0;
        if (split(line, c, 11) != 11) { status = objc_fail(a, "malformed-reference", NULL, 0, "%s:%zu not eleven columns", name, lineno); break; }
        /* value: introduced, framework, deprecated, unavailable */
        snprintf(v, sizeof v, "%s\t%s\t%s\t%s", c[6], c[1], c[7], c[8]);
        if (!strcmp(c[0], "method") || !strcmp(c[0], "property-get") || !strcmp(c[0], "property-set")) {
            status = map_put3(a, methods, c[2], c[3], c[4], v);
            if (status == OBJC_OK && methods == a->nw_method) status = map_put3(a, a->nw_encoding, c[2], c[3], c[4], c[5]);
            if (status == OBJC_OK && methods == a->nw_method && later_than_floor(c[6]) && objc_map_put(a->nw_later_sel, c[4], c[6]) < 0)
                status = objc_fail(a, "out-of-memory", NULL, 0, "later selector");
        } else if (!strcmp(c[0], "class")) {
            snprintf(v, sizeof v, "%s\t%s\t%s", c[4], c[6], c[1]);
            if (objc_map_put(classes, c[2], v) < 0) status = objc_fail(a, "out-of-memory", NULL, 0, "sdk class");
        }
    }
    if (status == OBJC_OK && ferror(f)) status = objc_fail(a, "unreadable-reference", NULL, 0, "%s: read error", name);
    free(line); fclose(f);
    return status;
}

int objc_add_probe(ObjcAnalysis *a, const ObjcClusterProbe *src) {
    ObjcClusterProbe p, *g;
    size_t i;
    memset(&p, 0, sizeof p);
    if (!(g = realloc(a->probes, (a->n_probes + 1) * sizeof *g))) return objc_fail(a, "out-of-memory", NULL, 0, "probe");
    a->probes = g;
    if (objc_set_string(&p.id, src->id) || objc_set_string(&p.cls, src->cls) ||
        objc_set_string(&p.construction, src->construction) || objc_set_string(&p.concrete, src->concrete))
        goto oom;
    for (i = 0; i < src->nchain; i++) if (objc_strv_push(&p.chain, &p.nchain, src->chain[i])) goto oom;
    for (i = 0; i < src->nbelow; i++) if (objc_strv_push(&p.below, &p.nbelow, src->below[i])) goto oom;
    a->probes[a->n_probes++] = p;
    return OBJC_OK;
oom:
    free(p.id); free(p.cls); free(p.construction); free(p.concrete);
    for (i = 0; i < p.nchain; i++) free(p.chain[i]);
    for (i = 0; i < p.nbelow; i++) free(p.below[i]);
    free(p.chain); free(p.below);
    return objc_fail(a, "out-of-memory", NULL, 0, "probe");
}

int objc_load_reference_set(ObjcAnalysis *a) {
    int rc;
    if (!a->references_dir) return objc_fail(a, "no-references", NULL, 0, "no reference set");
    if (!(a->rt_class = objc_map_create()) || !(a->rt_method = objc_map_create()) ||
        !(a->rt_witness = objc_map_create()) || !(a->rt_behavior = objc_map_create()) ||
        !(a->rt_image_role = objc_map_create()) || !(a->rt_override = objc_map_create()) ||
        !(a->nw_method = objc_map_create()) || !(a->nw_class = objc_map_create()) ||
        !(a->fl_method = objc_map_create()) || !(a->fl_class = objc_map_create()) ||
        !(a->nw_later_sel = objc_map_create()) || !(a->nw_encoding = objc_map_create()))
        return objc_fail(a, "out-of-memory", NULL, 0, "reference maps");
    if ((rc = load_runtime(a))) return rc;
    if ((rc = load_sdk(a, "newer-sdk.tsv", a->nw_method, a->nw_class))) return rc;
    return load_sdk(a, "floor-sdk.tsv", a->fl_method, a->fl_class);
}
