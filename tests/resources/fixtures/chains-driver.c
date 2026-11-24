/* Test-only harness: resources-chains-driver REFDIR TARGET [ARG...] builds a graph, resolves its superclass chains
 * with rc_resolve and prints one "CLASS<TAB>resolved|unresolved<TAB>NEWER-or--<TAB>CHAIN" line per chain. ARGs,
 * in order: --nib PATH reads a NIBArchive nib as the graph; --class NAME adds an object of class NAME;
 * --swapper-hex HEX adds an NSClassSwapper whose NSClassName refers to an NSString holding those bytes;
 * --binary PATH calls rc_add_binary, printing "binary PATH: unreadable: WHY" when it returns 1.
 * Exit 0, 4 when a nib is malformed, rc_add_binary or rc_resolve runs out of memory or rg_chain misses a chain, 2 on usage or when rc_open fails. */
#include "chains.h"
#include "nibarchive.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int read_nib(const char *path, RGraph *g) {
    FILE *f;
    uint8_t *buf, *more;
    size_t n = 0, cap = 1 << 16;
    char why[256];
    int rc;
    if (!(f = fopen(path, "rb"))) { perror(path); return 2; }
    if (!(buf = malloc(cap))) { fclose(f); return 2; }
    for (;;) {
        n += fread(buf + n, 1, cap - n, f);
        if (n < cap) break;
        if (cap >= (size_t)1 << 28 || !(more = realloc(buf, cap * 2))) { free(buf); fclose(f); return 2; }
        buf = more;
        cap *= 2;
    }
    fclose(f);
    rc = na_read(buf, n, g, why, sizeof why);
    free(buf);
    if (rc) fprintf(stderr, "%s: %s\n", path, why);
    return rc;
}

static int add_swapper(RGraph *g, const char *hex) {
    size_t n = strlen(hex) / 2, i;
    uint8_t *b = malloc(n ? n : 1);
    RValue v;
    int s, sw;
    const char *nsstring = rg_intern(g, "NSString", 8), *swapper = rg_intern(g, "NSClassSwapper", 14);
    const char *bytes_key = rg_intern(g, "NS.bytes", 8), *name_key = rg_intern(g, "NSClassName", 11);
    if (!b || !nsstring || !swapper || !bytes_key || !name_key) { free(b); return -1; }
    for (i = 0; i < n; i++) {
        unsigned x;
        if (sscanf(hex + 2 * i, "%2x", &x) != 1) { free(b); return -1; }
        b[i] = (uint8_t)x;
    }
    memset(&v, 0, sizeof v);
    if ((s = rg_add_object(g, nsstring)) < 0 || (sw = rg_add_object(g, swapper)) < 0) { free(b); return -1; }
    v.key = bytes_key; v.type = RV_DATA; v.u.d.p = b; v.u.d.n = n;
    if (rg_add_value(g, (uint32_t)s, &v)) { free(b); return -1; }
    free(b);
    memset(&v, 0, sizeof v);
    v.key = name_key; v.type = RV_REF; v.u.ref = (uint32_t)s;
    return rg_add_value(g, (uint32_t)sw, &v);
}

int main(int argc, char **argv) {
    RGraph g;
    RChainSrc *s;
    char why[512];
    size_t i, j;
    int a, rc = 0;
    if (argc < 3) { fprintf(stderr, "usage: resources-chains-driver REFDIR TARGET [ARG...]\n"); return 2; }
    memset(&g, 0, sizeof g);
    if (!(s = rc_open(argv[1], argv[2]))) { fprintf(stderr, "rc_open %s failed\n", argv[1]); return 2; }
    for (a = 3; a + 1 < argc && !rc; a += 2) {
        if (!strcmp(argv[a], "--nib")) {
            rg_free(&g);
            rc = read_nib(argv[a + 1], &g);
        } else if (!strcmp(argv[a], "--class")) {
            const char *c = rg_intern(&g, argv[a + 1], strlen(argv[a + 1]));
            if (!c || rg_add_object(&g, c) < 0) rc = 2;
        } else if (!strcmp(argv[a], "--swapper-hex")) {
            if (add_swapper(&g, argv[a + 1])) rc = 2;
        } else if (!strcmp(argv[a], "--binary")) {
            int b = rc_add_binary(s, argv[a + 1], why, sizeof why);
            if (b > 0) printf("binary %s: unreadable: %s\n", argv[a + 1], why);
            else if (b < 0) { fprintf(stderr, "rc_add_binary %s: %s\n", argv[a + 1], why); rc = 4; }
        } else
            rc = 2;
    }
    if (!rc && a != argc) rc = 2;
    if (!rc && rc_resolve(s, &g)) { fprintf(stderr, "rc_resolve failed\n"); rc = 4; }
    for (i = 0; !rc && i < g.n_chains; i++) {
        const RChain *c = &g.chains[i];
        if (rg_chain(&g, c->cls) != c) { fprintf(stderr, "rg_chain does not find %s\n", c->cls); rc = 4; break; }
        printf("%s\t%s\t%s\t", c->cls, c->resolved ? "resolved" : "unresolved", c->newer ? c->newer : "-");
        for (j = 0; j < c->n_chain; j++) printf("%s%s", j ? " " : "", c->chain[j]);
        printf("\n");
    }
    rc_close(s);
    rg_free(&g);
    return rc;
}
