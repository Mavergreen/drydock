/* Test-only harness for bplist.c:
 *   resources-bplist-driver build [--xml-safe|--small|--wide N] OUT   writes a built tree with bp_write
 *   resources-bplist-driver build --xml-safe --only KEY OUT          writes a dict of just the xml-safe tree's KEY
 *   resources-bplist-driver rewrite IN OUT                           bp_read, then bp_write
 *   resources-bplist-driver dump [--as-xml] IN                       bp_read, then one line per node; --as-xml
 *                                                                    drops what an XML plist loses: dict entry
 *                                                                    order (sorted by key) and a real's width
 *   resources-bplist-driver graft IN                                 bp_read, move its "$archiver" and "$top"
 *                                                                    into a new array with bp_retain, free the
 *                                                                    read tree, then write, read and dump the array
 *   resources-bplist-driver summary IN                               bp_read and bp_write in memory, then
 *                                                                    "written N maxrss_kb N"
 * The full tree holds every type, nested; building it first checks that the constructors refuse invalid UTF-8 and
 * a 33-bit UID. --xml-safe leaves out what XML plists can't carry: null, a 4-byte real, NaN, -0.0, and a string
 * holding U+0000, which 10.9's plutil writes as XML but a modern one refuses. Exit 0, 4 malformed (why on stderr),
 * 2 usage, unreadable or out of memory. */
#include "bplist.h"
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    uint8_t *buf, *more;
    size_t cap = 1 << 16;
    *n = 0;
    if (!f) { perror(path); return NULL; }
    if (!(buf = malloc(cap))) { fclose(f); return NULL; }
    for (;;) {
        *n += fread(buf + *n, 1, cap - *n, f);
        if (*n < cap) break;
        if (cap >= (size_t)1 << 28 || !(more = realloc(buf, cap * 2))) { free(buf); fclose(f); return NULL; }
        buf = more;
        cap *= 2;
    }
    fclose(f);
    if (!(more = malloc(*n ? *n : 1))) { free(buf); return NULL; }
    memcpy(more, buf, *n);
    free(buf);
    return more;
}

static int spit(const char *path, const uint8_t *p, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(p, 1, n, f) != n || fclose(f)) { perror(path); return 2; }
    return 0;
}

static int read_file(const char *path, BpNode **root) {
    size_t n;
    char why[256];
    uint8_t *buf = slurp(path, &n);
    int rc;
    if (!buf) return 2;
    rc = bp_read(buf, n, root, why, sizeof why);
    free(buf);
    if (rc) fprintf(stderr, "%s\n", why);
    return rc;
}

static int ok;
static BpNode *chk(BpNode *v) { if (!v) ok = 0; return v; }
static void push(BpNode *a, BpNode *v) { if (bp_push(a, v)) ok = 0; }
static void set(BpNode *d, const char *k, BpNode *v) { if (bp_set(d, k, v)) ok = 0; }
static BpNode *str(const char *s) { return chk(bp_string(s, strlen(s))); }

static BpNode *build(int xml_safe) {
    static const int64_t ints[] = { 0, 1, 14, 15, 255, 256, 65535, 65536, 4294967295LL, 4294967296LL, -1,
                                    INT64_MIN, INT64_MAX };
    static const uint64_t uids[] = { 0, 255, 256, 65535, 65536, 4294967295ULL };
    BpNode *root = chk(bp_dict()), *a = chk(bp_array()), *nest = chk(bp_array()), *inner = chk(bp_dict()),
           *wide = chk(bp_array()), *wided = chk(bp_dict());
    uint8_t bytes[300];
    size_t i;
    char key[8];
    ok = 1;
    for (i = 0; i < sizeof bytes; i++) bytes[i] = (uint8_t)(i * 7);
    for (i = 0; i < sizeof ints / sizeof *ints; i++) push(a, chk(bp_int(ints[i])));
    for (i = 0; i < sizeof uids / sizeof *uids; i++) push(a, chk(bp_uid(uids[i])));
    set(root, "ints and uids", a);
    set(root, "true", chk(bp_bool(1)));
    set(root, "false", chk(bp_bool(0)));
    set(root, "real", chk(bp_real(0.1)));
    set(root, "big real", chk(bp_real(-1e300)));
    set(root, "", str(""));
    set(root, "ascii", str("repeated string"));
    set(root, "repeated string", str("repeated string"));
    set(root, "latin", str("caf\xc3\xa9"));
    set(root, "astral", str("smile \xf0\x9f\x98\x80 \xe2\x82\xac"));
    set(root, "long ascii string over fifteen", str("long ascii value over fifteen bytes"));
    set(root, "empty data", chk(bp_data(NULL, 0)));
    set(root, "data", chk(bp_data(bytes, 3)));
    set(root, "long data", chk(bp_data(bytes, sizeof bytes)));
    set(root, "empty array", chk(bp_array()));
    set(root, "empty dict", chk(bp_dict()));
    push(nest, str("repeated string"));
    push(nest, chk(bp_uid(3)));
    set(inner, "deeper", chk(bp_array()));
    push(bp_get(inner, "deeper"), chk(bp_int(-42)));
    push(bp_get(inner, "deeper"), str("repeated string"));
    push(nest, inner);
    set(root, "nested", nest);
    for (i = 0; i < 20; i++) push(wide, chk(bp_int((int64_t)i)));
    set(root, "wide array", wide);
    for (i = 0; i < 17; i++) { snprintf(key, sizeof key, "k%02u", (unsigned)i); set(wided, key, chk(bp_bool((int)(i & 1)))); }
    set(root, "wide dict", wided);
    if (!xml_safe) {
        double nan_payload, neg_zero = -0.0;
        uint64_t bits = 0x7ff4000000000123ULL;
        memcpy(&nan_payload, &bits, 8);
        set(root, "null", chk(bp_null()));
        set(root, "nul", chk(bp_string("a\0b", 3)));
        set(root, "f32", chk(bp_real32(0x3fc00000u)));
        set(root, "f32 signalling nan", chk(bp_real32(0x7f800001u)));
        set(root, "nan", chk(bp_real(nan_payload)));
        set(root, "-0", chk(bp_real(neg_zero)));
    }
    if (!ok) { bp_free(root); return NULL; }
    return root;
}

/* What the constructors must refuse: overlong, surrogate, past U+10FFFF, cut short, a stray continuation; a UID
 * past 32 bits. */
static int refusals(void) {
    static const char *const bad[] = { "\xc0\x80", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82",
                                       "\x80", "\xff", "\xc3\x28" };
    size_t i;
    BpNode *v;
    for (i = 0; i < sizeof bad / sizeof *bad; i++)
        if ((v = bp_string(bad[i], strlen(bad[i])))) {
            bp_free(v);
            fprintf(stderr, "bp_string accepted bad[%u]\n", (unsigned)i);
            return 2;
        }
    if ((v = bp_uid(4294967296ULL))) { bp_free(v); fprintf(stderr, "bp_uid accepted 2^32\n"); return 2; }
    return 0;
}

static void print_bytes(const uint8_t *p, size_t n) {
    size_t i;
    for (i = 0; i < n; i++)
        if (p[i] < 0x20 || p[i] > 0x7e || p[i] == '"' || p[i] == '\\') break;
    if (i == n) { printf("\"%.*s\"", (int)n, (const char *)p); return; }
    printf("bytes%lu:", (unsigned long)n);
    for (i = 0; i < n; i++) printf("%02x", p[i]);
}

static int as_xml;

static void dump(const BpNode *v, int depth, const BpNode *key);

static void dump_dict(const BpNode *v, int depth) {
    size_t i, n = bp_count(v);
    size_t *order = malloc((n ? n : 1) * sizeof *order);
    if (!order) { fprintf(stderr, "out of memory\n"); exit(2); }
    for (i = 0; i < n; i++) order[i] = i;
    if (as_xml) {
        size_t j, k;
        for (i = 1; i < n; i++)
            for (j = i; j > 0; j--) {
                size_t na, nb;
                const uint8_t *pa = bp_bytes(bp_key_at(v, order[j - 1]), &na), *pb = bp_bytes(bp_key_at(v, order[j]), &nb);
                int c = memcmp(pa, pb, na < nb ? na : nb);
                if (c < 0 || (!c && na <= nb)) break;
                k = order[j]; order[j] = order[j - 1]; order[j - 1] = k;
            }
    }
    for (i = 0; i < n; i++) dump(bp_value_at(v, order[i]), depth + 1, bp_key_at(v, order[i]));
    free(order);
}

static void dump(const BpNode *v, int depth, const BpNode *key) {
    size_t i, n;
    const uint8_t *p;
    printf("%*s", depth * 2, "");
    if (key) { p = bp_bytes(key, &n); print_bytes(p, n); printf(" = "); }
    switch (bp_type(v)) {
    case BP_NULL: printf("null\n"); break;
    case BP_BOOL: printf("bool %d\n", bp_bool_value(v)); break;
    case BP_INT: printf("int %lld\n", (long long)bp_int_value(v)); break;
    case BP_UID: printf("uid %llu\n", (unsigned long long)bp_uid_value(v)); break;
    case BP_REAL:
        if (bp_real_width(v) == 4 && !as_xml) printf("real32 %08llx\n", (unsigned long long)bp_real_bits(v));
        else printf("real %.17g\n", bp_real_value(v));
        break;
    case BP_STRING: p = bp_bytes(v, &n); printf("string "); print_bytes(p, n); printf("\n"); break;
    case BP_DATA: p = bp_bytes(v, &n); printf("data "); print_bytes(p, n); printf("\n"); break;
    case BP_ARRAY:
        printf("array %lu\n", (unsigned long)bp_count(v));
        for (i = 0; i < bp_count(v); i++) dump(bp_at(v, i), depth + 1, NULL);
        break;
    case BP_DICT:
        printf("dict %lu\n", (unsigned long)bp_count(v));
        dump_dict(v, depth);
        break;
    }
}

int main(int argc, char **argv) {
    BpNode *root = NULL;
    uint8_t *out;
    size_t n;
    int rc;
    if (argc >= 3 && !strcmp(argv[1], "build")) {
        const char *mode = argc >= 4 ? argv[2] : "";
        if (argc == 4 && !strcmp(mode, "--small")) {
            ok = 1;
            root = chk(bp_dict());
            set(root, "a", chk(bp_int(1)));
            set(root, "b", str("x"));
            if (!ok) { bp_free(root); root = NULL; }
        } else if (!strcmp(mode, "--wide") && argc == 5) {
            long i, w = atol(argv[3]);
            ok = 1;
            root = chk(bp_array());
            for (i = 0; i < w; i++) push(root, chk(bp_int(i)));
            if (!ok) { bp_free(root); root = NULL; }
        } else if (argc == 3 || (argc == 4 && !strcmp(mode, "--xml-safe"))) {
            if ((rc = refusals())) return rc;
            root = build(argc == 4);
        } else if (argc == 6 && !strcmp(mode, "--xml-safe") && !strcmp(argv[3], "--only")) {
            BpNode *all = build(1), *v = all ? bp_get(all, argv[4]) : NULL;
            if (all && !v) { bp_free(all); fprintf(stderr, "no entry \"%s\"\n", argv[4]); return 2; }
            ok = 1;
            if (v) { root = chk(bp_dict()); set(root, argv[4], bp_retain(v)); }
            bp_free(all);
            if (!ok) { bp_free(root); root = NULL; }
        } else goto usage;
        if (!root || bp_write(root, &out, &n)) { bp_free(root); fprintf(stderr, "out of memory\n"); return 2; }
        bp_free(root);
        rc = spit(argv[argc - 1], out, n);
        free(out);
        return rc;
    }
    if (argc == 4 && !strcmp(argv[1], "rewrite")) {
        if ((rc = read_file(argv[2], &root))) return rc;
        if (bp_write(root, &out, &n)) { bp_free(root); fprintf(stderr, "out of memory\n"); return 2; }
        bp_free(root);
        rc = spit(argv[3], out, n);
        free(out);
        return rc;
    }
    if ((argc == 3 || (argc == 4 && !strcmp(argv[2], "--as-xml"))) && !strcmp(argv[1], "dump")) {
        as_xml = argc == 4;
        if ((rc = read_file(argv[argc - 1], &root))) return rc;
        dump(root, 0, NULL);
        bp_free(root);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "graft")) {
        BpNode *a, *back;
        char why[256];
        if ((rc = read_file(argv[2], &root))) return rc;
        if (bp_type(root) != BP_DICT || !bp_get(root, "$archiver") || !bp_get(root, "$top")) {
            bp_free(root);
            fprintf(stderr, "%s: no $archiver and $top\n", argv[2]);
            return 2;
        }
        if (!(a = bp_array()) || bp_push(a, bp_retain(bp_get(root, "$archiver"))) ||
            bp_push(a, bp_retain(bp_get(root, "$top")))) {
            bp_free(a);
            bp_free(root);
            return 2;
        }
        bp_free(root);
        rc = bp_write(a, &out, &n);
        bp_free(a);
        if (rc) { fprintf(stderr, "out of memory\n"); return 2; }
        rc = bp_read(out, n, &back, why, sizeof why);
        free(out);
        if (rc) { fprintf(stderr, "%s\n", why); return rc; }
        dump(back, 0, NULL);
        bp_free(back);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "summary")) {
        struct rusage ru;
        long kb;
        if ((rc = read_file(argv[2], &root))) return rc;
        if (bp_write(root, &out, &n)) { bp_free(root); fprintf(stderr, "out of memory\n"); return 2; }
        bp_free(root);
        free(out);
        getrusage(RUSAGE_SELF, &ru);
#ifdef __APPLE__
        kb = ru.ru_maxrss / 1024;
#else
        kb = ru.ru_maxrss;
#endif
        printf("written %lu maxrss_kb %ld\n", (unsigned long)n, kb);
        return 0;
    }
usage:
    fprintf(stderr, "usage: resources-bplist-driver build [--xml-safe [--only KEY]|--small|--wide N] OUT | "
                    "rewrite IN OUT | dump [--as-xml] IN | graft IN | summary IN\n");
    return 2;
}
