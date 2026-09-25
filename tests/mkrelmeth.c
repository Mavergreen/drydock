/* tests/mkrelmeth.c -- writes one variant of tests/relmeth_fixture.h's image:
 *   mkrelmeth make VARIANT OUT */
#include <stdio.h>
#include <string.h>

#include "relmeth_fixture.h"

static const struct { const char *name; unsigned bits; } VARIANTS[] = {
    { "plain", RMF_PLAIN },     { "chained", RMF_CHAINED }, { "direct", RMF_DIRECT },
    { "listlist", RMF_LISTLIST }, { "oob", RMF_OOB },       { "shared", RMF_SHARED },
    { "abscat", RMF_ABSCAT },   { "nlcls", RMF_NLCLS },     { "swift", RMF_SWIFT },
    { "badent", RMF_BADENT },   { "allslots", RMF_ALLSLOTS },
    { "sharedro", RMF_SHAREDRO }, { "catpast", RMF_CATPAST }, { "protopast", RMF_PROTOPAST },
    { "metaout", RMF_METAOUT },
};

int main(int argc, char **argv) {
    static uint8_t b[RMF_SIZE];
    size_t i, n, nv = sizeof VARIANTS / sizeof VARIANTS[0];
    FILE *f;

    if (argc != 4 || strcmp(argv[1], "make") != 0) {
        fprintf(stderr, "usage: mkrelmeth make VARIANT OUT\n");
        return 2;
    }
    for (i = 0; i < nv; i++)
        if (strcmp(argv[2], VARIANTS[i].name) == 0) break;
    if (i == nv) {
        fprintf(stderr, "mkrelmeth: unknown variant '%s'\n", argv[2]);
        return 2;
    }
    n = rmf_build(b, VARIANTS[i].bits);
    f = fopen(argv[3], "wb");
    if (!f) { perror(argv[3]); return 1; }
    if (fwrite(b, 1, n, f) != n) { perror(argv[3]); fclose(f); return 1; }
    return fclose(f) == 0 ? 0 : 1;
}
