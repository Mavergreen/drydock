/* Test-only harness: resources-graph-driver [--summary] NIB reads a NIBArchive nib with na_read, from a buffer
 * of exactly its size, and prints its graph, one "#N Class" line per object and one "  key (type) = value" line
 * per value; --summary prints "objects N values N maxrss_kb N" instead. Exit 0, 4 malformed (why on stderr),
 * 2 usage or unreadable. */
#include "nibarchive.h"
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *const type_names[] = { "i8", "i16", "i32", "i64", "false", "true", "f32", "f64",
                                          "data", "nil", "ref", "string", "uids" };

static void print_bytes(const uint8_t *p, size_t n) {
    size_t i;
    for (i = 0; i < n; i++)
        if (p[i] < 0x20 || p[i] > 0x7e || p[i] == '"' || p[i] == '\\') break;
    if (i == n) { printf("\"%.*s\"", (int)n, (const char *)p); return; }
    printf("bytes%lu:", (unsigned long)n);
    for (i = 0; i < n; i++) printf("%02x", p[i]);
}

int main(int argc, char **argv) {
    FILE *f;
    uint8_t *buf, *more;
    size_t n = 0, cap = 1 << 16, i, j, k;
    RGraph g;
    char why[256];
    int rc, summary = argc == 3 && !strcmp(argv[1], "--summary");
    const char *path = argv[argc - 1];
    if (argc != 2 && !summary) { fprintf(stderr, "usage: resources-graph-driver [--summary] NIB\n"); return 2; }
    if (!(f = fopen(path, "rb"))) { perror(path); return 2; }
    if (!(buf = malloc(cap))) return 2;
    for (;;) {
        n += fread(buf + n, 1, cap - n, f);
        if (n < cap) break;
        if (cap >= (size_t)1 << 28 || !(more = realloc(buf, cap * 2))) {
            fprintf(stderr, "%s: too big\n", path);
            free(buf);
            fclose(f);
            return 2;
        }
        buf = more;
        cap *= 2;
    }
    fclose(f);
    if (!(more = malloc(n ? n : 1))) { free(buf); return 2; }
    memcpy(more, buf, n);
    free(buf);
    rc = na_read(more, n, &g, why, sizeof why);
    free(more);
    if (rc) { fprintf(stderr, "%s\n", why); return rc; }
    if (summary) {
        struct rusage ru;
        size_t vals = 0;
        long kb;
        for (i = 0; i < g.n_objs; i++) vals += g.objs[i].n_vals;
        getrusage(RUSAGE_SELF, &ru);
#ifdef __APPLE__
        kb = ru.ru_maxrss / 1024;
#else
        kb = ru.ru_maxrss;
#endif
        printf("objects %lu values %lu maxrss_kb %ld\n", (unsigned long)g.n_objs, (unsigned long)vals, kb);
        rg_free(&g);
        return 0;
    }
    for (i = 0; i < g.n_objs; i++) {
        printf("#%lu %s\n", (unsigned long)i, g.objs[i].cls);
        for (j = 0; j < g.objs[i].n_vals; j++) {
            const RValue *v = &g.objs[i].vals[j];
            printf("  %s (%s) = ", v->key, type_names[v->type]);
            switch (v->type) {
            case RV_I8: case RV_I16: case RV_I32: case RV_I64: printf("%lld", (long long)v->u.i); break;
            case RV_TRUE: printf("true"); break;
            case RV_FALSE: printf("false"); break;
            case RV_F32: { float f; memcpy(&f, &v->u.f32, 4); printf("%.17g", (double)f); break; }
            case RV_F64: printf("%.17g", v->u.f); break;
            case RV_DATA: case RV_STRING: print_bytes(v->u.d.p, v->u.d.n); break;
            case RV_NIL: printf("nil"); break;
            case RV_REF: printf("@%lu<%s>", (unsigned long)v->u.ref, g.objs[v->u.ref].cls); break;
            case RV_UID_ARRAY:
                for (k = 0; k < v->u.refs.n; k++) printf("%s@%lu", k ? " " : "", (unsigned long)v->u.refs.v[k]);
                break;
            }
            printf("\n");
        }
    }
    rg_free(&g);
    return 0;
}
