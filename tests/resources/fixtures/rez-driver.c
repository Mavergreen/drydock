/* Test-only harness: resources-rez-driver TEXT reads a dump with rez_parse and writes it again with rez_write;
 * resources-rez-driver --nib NIB reads a NIBArchive nib with na_read and writes it with rez_write, with no chain
 * lines since nothing resolves them. Each input is handed over in a buffer of exactly its size, so guard malloc and
 * ASan see a read past its last byte. Exit 0, 4 malformed (why on stderr, nothing on stdout), 2 usage or
 * unreadable. */
#include "nibarchive.h"
#include "rez.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *slurp(const char *path, size_t *outn) {
    FILE *f;
    uint8_t *buf, *more;
    size_t n = 0, cap = 1 << 16;
    if (!(f = fopen(path, "rb"))) { perror(path); return NULL; }
    if (!(buf = malloc(cap))) { fclose(f); return NULL; }
    for (;;) {
        n += fread(buf + n, 1, cap - n, f);
        if (n < cap) break;
        if (cap >= (size_t)1 << 28 || !(more = realloc(buf, cap * 2))) { free(buf); fclose(f); return NULL; }
        buf = more;
        cap *= 2;
    }
    fclose(f);
    if (!(more = malloc(n ? n : 1))) { free(buf); return NULL; }
    memcpy(more, buf, n);
    free(buf);
    *outn = n;
    return more;
}

int main(int argc, char **argv) {
    uint8_t *in;
    char *out, why[512];
    size_t n, outn;
    RGraph g;
    int rc, nib = argc == 3 && !strcmp(argv[1], "--nib");
    if (argc != 2 && !nib) { fprintf(stderr, "usage: resources-rez-driver [--nib NIB | TEXT]\n"); return 2; }
    if (!(in = slurp(argv[argc - 1], &n))) return 2;
    rc = nib ? na_read(in, n, &g, why, sizeof why) : rez_parse((const char *)in, n, &g, why, sizeof why);
    free(in);
    if (rc) { fprintf(stderr, "%s\n", why); return rc; }
    rc = rez_write(&g, &out, &outn, why, sizeof why);
    rg_free(&g);
    if (rc) { fprintf(stderr, "%s\n", why); return rc; }
    rc = fwrite(out, 1, outn, stdout) != outn || fflush(stdout) ? 2 : 0;
    free(out);
    return rc;
}
