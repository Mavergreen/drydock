/* tests/hdrref_ab.c -- the helper of tests/hdrref_table_rule_test.sh.
 *
 *   hdrref_ab dylibs|execs   paths on stdin; for the x86_64 slice of each
 *                            MH_DYLIB or MH_BUNDLE (dylibs), or MH_EXECUTE
 *                            (execs), read in memory and never written:
 *     F <path> <mhr_confirm: answer, bad.addr> <the same without the rule>
 *       <mhr_confirm_each: answer, without the rule> <candidates>
 *     D <path> <addr> <immlen> <target> <verdict> <verdict without the rule>
 *       for each candidate of mhr_confirm_each whose verdict the rule changes
 *     X <path> <index>   the two walks did not pass the same candidates
 *
 * mhr_confirm_each runs over every target, [0, UINT64_MAX].
 *
 * "Without the rule" is src/hdrref.c compiled again with -DMHR_NO_TABLE_RULE
 * and its external names prefixed mhr_nr_ (CMakeLists.txt's hdrref_norule),
 * linked into this one binary so the two walks are compared candidate by
 * candidate in memory. A name left unprefixed would not link: the real
 * hdrref.o defines it too.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "fat.h"
#include "hdrref.h"
#include "image.h"

int mhr_nr_confirm(const uint8_t *buf, size_t fsize, mhr_cand *bad);
int mhr_nr_confirm_each(const uint8_t *buf, size_t fsize, uint64_t first, uint64_t last,
                        mhr_verdict_fn fn, void *ctx);

typedef struct { uint64_t addr; int immlen, verdict; } seen;

struct walk {
    const char *path;
    seen *v;
    size_t n, cap, i;
    int bad;   /* the second walk left the first's candidates */
    uint64_t changed;
};

static int record_cb(const mhr_cand *c, int verdict, void *ctx) {
    struct walk *w = (struct walk *)ctx;
    if (w->n == w->cap) {
        size_t cap = w->cap ? 2 * w->cap : 4096;
        seen *v = (seen *)realloc(w->v, cap * sizeof *v);
        if (!v) { fprintf(stderr, "hdrref_ab: out of memory\n"); exit(2); }
        w->v = v;
        w->cap = cap;
    }
    seen s = { c->addr, c->immlen, verdict };
    w->v[w->n++] = s;
    return 0;
}

static int compare_cb(const mhr_cand *c, int verdict, void *ctx) {
    struct walk *w = (struct walk *)ctx;
    if (w->i >= w->n || w->v[w->i].addr != c->addr || w->v[w->i].immlen != c->immlen) {
        printf("X\t%s\t%zu\n", w->path, w->i);
        w->bad = 1;
        return 1;
    }
    const seen *s = &w->v[w->i++];
    if (s->verdict != verdict) {
        printf("D\t%s\t%llx\t%d\t%llx\t%d\t%d\n", w->path, (unsigned long long)c->addr,
               c->immlen, (unsigned long long)c->target, s->verdict, verdict);
        w->changed++;
    }
    return 0;
}

static uint8_t *slurp(const char *path, size_t *size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    uint8_t *buf = NULL;
    long n = -1;
    if (fseek(f, 0, SEEK_END) == 0 && (n = ftell(f)) > 0 && fseek(f, 0, SEEK_SET) == 0 &&
        (buf = (uint8_t *)malloc((size_t)n)) && fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf);
        buf = NULL;
    }
    fclose(f);
    *size = (size_t)n;
    return buf;
}

/* The x86_64 slice of buf, thin or fat, or NULL. */
static uint8_t *x86_64_slice(uint8_t *buf, size_t size, size_t *ssize) {
    uint32_t magic, narch;
    int swap;
    if (size < sizeof(struct mach_header_64)) return NULL;
    memcpy(&magic, buf, 4);
    if (magic == MH_MAGIC_64) {
        *ssize = size;
        return ((struct mach_header_64 *)buf)->cputype == CPU_TYPE_X86_64 ? buf : NULL;
    }
    if (mfat_parse(buf, size, &narch, &swap) != 0) return NULL;
    for (uint32_t i = 0; i < narch; i++) {
        mfat_arch a;
        mfat_get(buf, swap, i, &a);
        if (a.cputype != CPU_TYPE_X86_64) continue;
        *ssize = a.size;
        return buf + a.offset;
    }
    return NULL;
}

int main(int argc, char **argv) {
    int execs = argc == 2 && !strcmp(argv[1], "execs");
    if (argc != 2 || (!execs && strcmp(argv[1], "dylibs"))) {
        fprintf(stderr, "usage: hdrref_ab dylibs|execs < paths\n");
        return 2;
    }
    char path[4096];
    struct walk w = { NULL, NULL, 0, 0, 0, 0, 0 };
    while (fgets(path, sizeof path, stdin)) {
        path[strcspn(path, "\n")] = '\0';
        size_t size = 0, ssize = 0;
        uint8_t *buf = slurp(path, &size), *s;
        mi_image im;
        if (!buf || !(s = x86_64_slice(buf, size, &ssize)) || mi_wrap(s, ssize, &im) != 0 ||
            (execs ? im.hdr->filetype != MH_EXECUTE
                   : im.hdr->filetype != MH_DYLIB && im.hdr->filetype != MH_BUNDLE)) {
            free(buf);
            continue;
        }
        mhr_cand bad, bad_nr;
        memset(&bad, 0, sizeof bad);
        memset(&bad_nr, 0, sizeof bad_nr);
        int rc = mhr_confirm(s, ssize, &bad), rc_nr = mhr_nr_confirm(s, ssize, &bad_nr);
        w.path = path;
        w.n = w.i = 0;
        w.bad = 0;
        w.changed = 0;
        int erc = mhr_confirm_each(s, ssize, 0, UINT64_MAX, record_cb, &w);
        int erc_nr = mhr_nr_confirm_each(s, ssize, 0, UINT64_MAX, compare_cb, &w);
        if (!w.bad && w.i != w.n) printf("X\t%s\t%zu\n", path, w.i);
        printf("F\t%s\t%d\t%llx\t%d\t%llx\t%d\t%d\t%zu\n", path, rc, (unsigned long long)bad.addr,
               rc_nr, (unsigned long long)bad_nr.addr, erc, erc_nr, w.n);
        free(buf);
    }
    free(w.v);
    return 0;
}
