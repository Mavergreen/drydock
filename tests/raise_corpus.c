/* tests/raise_corpus.c -- the corpus side of tests/raise_corpus_test.sh and
 * tests/raise_oracle_counts_test.sh.
 *
 *   raise_corpus list      paths on stdin; prints those with an x86_64
 *                          MH_DYLIB or MH_BUNDLE, thin or in a fat file
 *   raise_corpus shas      paths on stdin; prints each with a tab and the
 *                          sha256 of its x86_64 slice
 *   raise_corpus thin IN OUT
 *                          writes IN's x86_64 slice (IN itself, if thin)
 *   raise_corpus oracles   paths on stdin; prints, for each file's x86_64
 *                          slice, its path, a tab, its sha256, a tab, and
 *                          what each of mg_oracles' five says of it: "held",
 *                          "skipped" (it does not hold, so a grow's check 4
 *                          does not ask it) or "nothing" (it holds, with
 *                          nothing to check)
 *
 * The sha256 keys tests/data's tables on contents: a row is compared only
 * while the file it was measured on is unchanged.
 */
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>

#include "grow.h"
#include "image.h"

static uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

/* The x86_64 slice of the file whose first `n` bytes are `h` and whose size
 * is `fsize`: its offset and size. 0 if there is none. */
static int slice_of(const uint8_t *h, size_t n, size_t fsize, uint64_t *off, uint64_t *size) {
    uint32_t m;
    if (n < 8) return 0;
    memcpy(&m, h, 4);
    if (m == MH_MAGIC_64) {
        const struct mach_header_64 *mh = (const struct mach_header_64 *)h;
        if (mh->cputype != CPU_TYPE_X86_64) return 0;
        *off = 0;
        *size = fsize;
        return 1;
    }
    if (be32(h) != FAT_MAGIC) return 0;
    uint32_t na = be32(h + 4);
    if (na == 0 || na > 16 || 8 + 20ull * na > n) return 0;   /* a Java class shares the magic */
    for (uint32_t i = 0; i < na; i++) {
        const uint8_t *a = h + 8 + 20 * i;
        if (be32(a) != CPU_TYPE_X86_64) continue;
        if ((uint64_t)be32(a + 8) + be32(a + 12) > fsize) return 0;
        *off = be32(a + 8);
        *size = be32(a + 12);
        return 1;
    }
    return 0;
}

/* Reads `path`'s x86_64 slice whole into *buf. 0 on success. */
static int read_slice(const char *path, uint8_t **buf, size_t *size) {
    uint8_t h[4096];
    struct stat st;
    uint64_t off, sz;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = fstat(fd, &st) == 0 ? pread(fd, h, sizeof h, 0) : -1;
    if (n < 0 || !slice_of(h, (size_t)n, (size_t)st.st_size, &off, &sz) || sz < 32) { close(fd); return -1; }
    *buf = (uint8_t *)malloc(sz);
    if (!*buf || pread(fd, *buf, sz, (off_t)off) != (ssize_t)sz) { free(*buf); close(fd); return -1; }
    close(fd);
    *size = sz;
    return 0;
}

static int list(void) {
    char path[4096];
    while (fgets(path, sizeof path, stdin)) {
        uint8_t h[4096], s[32];
        struct stat st;
        uint64_t off, sz;
        path[strcspn(path, "\n")] = 0;
        int fd = open(path, O_RDONLY);
        if (fd < 0) continue;
        ssize_t n = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) ? pread(fd, h, sizeof h, 0) : -1;
        if (n > 0 && slice_of(h, (size_t)n, (size_t)st.st_size, &off, &sz) && sz >= sizeof s &&
            pread(fd, s, sizeof s, (off_t)off) == (ssize_t)sizeof s) {
            uint32_t m, ft;
            memcpy(&m, s, 4);
            memcpy(&ft, s + 12, 4);
            if (m == MH_MAGIC_64 && (ft == MH_DYLIB || ft == MH_BUNDLE)) printf("%s\n", path);
        }
        close(fd);
    }
    return 0;
}

/* The sha256 of `n` bytes at `buf`, as 64 hex digits in `hex`. */
static void sha_of(const uint8_t *buf, size_t n, char hex[65]) {
    uint8_t d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX c;
    CC_SHA256_Init(&c);
    for (size_t at = 0; at < n; at += 1u << 30) {
        size_t k = n - at < (1u << 30) ? n - at : (1u << 30);
        CC_SHA256_Update(&c, buf + at, (CC_LONG)k);
    }
    CC_SHA256_Final(d, &c);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2 * i, 3, "%02x", d[i]);
}

static int shas(void) {
    char path[4096], hex[65];
    while (fgets(path, sizeof path, stdin)) {
        uint8_t *buf;
        size_t size;
        path[strcspn(path, "\n")] = 0;
        if (read_slice(path, &buf, &size) != 0) {
            printf("%s\tunreadable\n", path);
            continue;
        }
        sha_of(buf, size, hex);
        printf("%s\t%s\n", path, hex);
        free(buf);
    }
    return 0;
}

static int thin(const char *in, const char *out) {
    uint8_t *buf;
    size_t size;
    if (read_slice(in, &buf, &size) != 0) { fprintf(stderr, "raise_corpus: %s: no x86_64 slice\n", in); return 1; }
    FILE *f = fopen(out, "wb");
    int r = !f || fwrite(buf, 1, size, f) != size;
    if (f && fclose(f) != 0) r = 1;
    free(buf);
    if (r) fprintf(stderr, "raise_corpus: %s: could not write\n", out);
    return r;
}

/* What each oracle has to check, read here without mg_oracles. */
struct have { int values, routines, lazy, symtab, unwind, rebases; const struct linkedit_data_command *fs; };
static int have_cb(const struct load_command *lc, void *ctx) {
    struct have *h = (struct have *)ctx;
    if (lc->cmd == LC_ROUTINES_64) h->routines = 1;
    if (lc->cmd == LC_SYMTAB) h->symtab = 1;
    if ((lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) &&
        ((const struct dyld_info_command *)lc)->rebase_size)
        h->rebases = 1;
    if (lc->cmd == LC_FUNCTION_STARTS && !h->fs) h->fs = (const struct linkedit_data_command *)lc;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(seg + 1);
    for (uint32_t j = 0; j < seg->nsects; j++) {
        uint32_t t = s[j].flags & SECTION_TYPE;
        if ((t == S_MOD_INIT_FUNC_POINTERS || t == S_MOD_TERM_FUNC_POINTERS) && s[j].size >= 8) h->values = 1;
        if (t == S_LAZY_SYMBOL_POINTERS && s[j].size >= 8) h->lazy = 1;
        if (!strncmp(s[j].sectname, "__unwind_info", 16) && s[j].size) h->unwind = 1;
    }
    return 0;
}

static const char *say(unsigned holds, unsigned bit, int something) {
    return !(holds & bit) ? "skipped" : something ? "held" : "nothing";
}

static int oracles(void) {
    char path[4096], why[256], hex[65];
    while (fgets(path, sizeof path, stdin)) {
        uint8_t *buf;
        size_t size;
        mi_image im;
        struct have h;
        uint32_t toff, tsize;
        uint64_t base, starts[1];
        path[strcspn(path, "\n")] = 0;
        if (read_slice(path, &buf, &size) != 0 || mi_wrap(buf, size, &im) != 0 ||
            mi_image_base(&im, &base) != 0) {
            printf("%s\tunreadable\n", path);
            continue;
        }
        memset(&h, 0, sizeof h);
        mi_each_lc(&im, have_cb, &h);
        int nstarts = h.fs && h.fs->dataoff <= size && h.fs->datasize <= size - h.fs->dataoff &&
                      mg_funcstarts_decode(buf + h.fs->dataoff, h.fs->datasize, base, starts, 1) != 0;
        int trie = mg_find_trie(buf, size, &toff, &tsize) && toff && tsize;
        unsigned holds = mg_oracles(buf, size, MG_OR_ALL, why, sizeof why);
        sha_of(buf, size, hex);
        printf("%s\t%s\tinits=%s lazy=%s exports=%s unwind=%s rebases=%s\n", path, hex,
               say(holds, MG_OR_INITS, nstarts && (h.values || h.routines)),
               say(holds, MG_OR_LAZY, h.lazy),
               say(holds, MG_OR_EXPORTS, trie && h.symtab),
               say(holds, MG_OR_UNWIND, h.unwind),
               say(holds, MG_OR_REBASES, h.rebases));
        free(buf);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "list")) return list();
    if (argc == 2 && !strcmp(argv[1], "shas")) return shas();
    if (argc == 4 && !strcmp(argv[1], "thin")) return thin(argv[2], argv[3]);
    if (argc == 2 && !strcmp(argv[1], "oracles")) return oracles();
    fprintf(stderr, "usage: raise_corpus list | shas | thin IN OUT | oracles\n");
    return 2;
}
