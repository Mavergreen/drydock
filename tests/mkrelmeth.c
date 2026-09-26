/* tests/mkrelmeth.c -- writes one variant of tests/relmeth_fixture.h's image,
 * or prints the oracle's reading of an image's method lists:
 *   mkrelmeth make VARIANT[+VARIANT...] OUT
 *   mkrelmeth entries FILE */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "relmeth_fixture.h"

static const struct { const char *name; unsigned bits; } VARIANTS[] = {
    { "plain", RMF_PLAIN },     { "chained", RMF_CHAINED }, { "direct", RMF_DIRECT },
    { "listlist", RMF_LISTLIST }, { "oob", RMF_OOB },       { "shared", RMF_SHARED },
    { "abscat", RMF_ABSCAT },   { "nlcls", RMF_NLCLS },     { "swift", RMF_SWIFT },
    { "badent", RMF_BADENT },   { "allslots", RMF_ALLSLOTS },
    { "sharedro", RMF_SHAREDRO }, { "catpast", RMF_CATPAST }, { "protopast", RMF_PROTOPAST },
    { "metaout", RMF_METAOUT }, { "selbind", RMF_SELBIND }, { "fstarts", RMF_FSTARTS },
    { "fsbad", RMF_FSBAD },     { "noslotrb", RMF_NOSLOTRB }, { "dylib", RMF_DYLIB },
    { "zerotail", RMF_ZEROTAIL }, { "dataro", RMF_DATARO },  { "gap", RMF_GAP },
    { "segafter", RMF_SEGAFTER }, { "codesig", RMF_CODESIG }, { "split", RMF_SPLIT },
    { "pad16", RMF_PAD16 },     { "compact", RMF_COMPACT },
};

static int bits_of(const char *spec, unsigned *out) {
    char buf[256], *tok, *save = NULL;
    size_t i, nv = sizeof VARIANTS / sizeof VARIANTS[0];
    if (strlen(spec) >= sizeof buf) return -1;
    strcpy(buf, spec);
    *out = 0;
    for (tok = strtok_r(buf, "+", &save); tok; tok = strtok_r(NULL, "+", &save)) {
        for (i = 0; i < nv; i++)
            if (strcmp(tok, VARIANTS[i].name) == 0) break;
        if (i == nv) {
            fprintf(stderr, "mkrelmeth: unknown variant '%s'\n", tok);
            return -1;
        }
        *out |= VARIANTS[i].bits;
    }
    return 0;
}

static int entries(const char *path) {
    FILE *f = fopen(path, "rb");
    uint8_t *b;
    char *out;
    long n;
    int w;
    if (!f) { perror(path); return 1; }
    if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0) {
        perror(path); fclose(f); return 1;
    }
    b = malloc((size_t)n + 1);
    out = malloc(1 << 16);
    if (!b || !out || fread(b, 1, (size_t)n, f) != (size_t)n) {
        perror(path); fclose(f); free(b); free(out); return 1;
    }
    fclose(f);
    w = rmf_describe(b, (size_t)n, out, 1 << 16);
    if (w < 0) {
        fprintf(stderr, "mkrelmeth: %s: a method list the oracle cannot read\n", path);
        free(b); free(out); return 1;
    }
    fputs(out, stdout);
    free(b); free(out);
    return 0;
}

int main(int argc, char **argv) {
    static uint8_t b[RMF_SIZE];
    unsigned bits;
    size_t n;
    FILE *f;

    if (argc == 3 && strcmp(argv[1], "entries") == 0) return entries(argv[2]);
    if (argc != 4 || strcmp(argv[1], "make") != 0) {
        fprintf(stderr, "usage: mkrelmeth make VARIANT[+VARIANT...] OUT\n"
                        "       mkrelmeth entries FILE\n");
        return 2;
    }
    if (bits_of(argv[2], &bits) != 0) return 2;
    n = rmf_build(b, bits);
    f = fopen(argv[3], "wb");
    if (!f) { perror(argv[3]); return 1; }
    if (fwrite(b, 1, n, f) != n) { perror(argv[3]); fclose(f); return 1; }
    return fclose(f) == 0 ? 0 : 1;
}
