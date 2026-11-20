/* mkkext CASE OUT: writes a tests/kext_fixture.h kext for vnodeop_replace_test.sh.
 *   ok      a thin x86_64 MH_KEXT_BUNDLE with two vnode-op tables
 *   ok-fat  that kext, then an arm64e copy of it, in a fat container
 *   bundle  the same bytes as an MH_BUNDLE
 *   bundle-fat  that bundle, then an arm64e copy of it, in a fat container */
#include "kext_fixture.h"
#include "../src/mach_compat.h"

#include <mach-o/fat.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const kf_entry table[] = { { "_vnop_rename_desc", 0x10 }, { KF_OLD, 0x20 }, { NULL, 0 } };
static const char *const undefs[] = { "_a", "_vnop_rename_desc", KF_OLD, "_y", "_z" };

static uint32_t be32(uint32_t v) {
    return ((v & 0xff) << 24) | ((v & 0xff00) << 8) | ((v & 0xff0000) >> 8) | (v >> 24);
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: mkkext ok|ok-fat|bundle|bundle-fat OUT\n"); return 2; }
    const char *c = argv[1];
    if (strcmp(c, "ok") != 0 && strcmp(c, "ok-fat") != 0 && strcmp(c, "bundle") != 0
        && strcmp(c, "bundle-fat") != 0) {
        fprintf(stderr, "mkkext: unknown case '%s'\n", c);
        return 2;
    }
    kf_spec s;
    memset(&s, 0, sizeof s);
    s.base = 0x7000;
    s.tables[0] = table; s.tables[1] = table; s.ntables = 2;
    s.undefs = undefs; s.nundefs = 5; s.ndefs = 3;
    if (strncmp(c, "bundle", 6) == 0) s.filetype = MH_BUNDLE;
    size_t size;
    uint8_t *b = kf_build(&s, &size), *out = b;
    size_t total = size;

    int fat = strcmp(c, "ok-fat") == 0 || strcmp(c, "bundle-fat") == 0;
    if (fat) {
        const uint32_t align = 14, off0 = 1u << align;
        uint32_t off1 = (uint32_t)((off0 + size + off0 - 1) & ~(size_t)(off0 - 1));
        total = off1 + size;
        out = calloc(1, total);
        if (!out) return 2;
        struct fat_header *fh = (struct fat_header *)out;
        fh->magic = be32(FAT_MAGIC); fh->nfat_arch = be32(2);
        struct fat_arch *ar = (struct fat_arch *)(fh + 1);
        uint32_t ct[2] = { CPU_TYPE_X86_64, CPU_TYPE_ARM64 }, cs[2] = { 3, CPU_SUBTYPE_ARM64E };
        uint32_t off[2] = { off0, off1 };
        for (int i = 0; i < 2; i++) {
            ar[i].cputype = (cpu_type_t)be32(ct[i]); ar[i].cpusubtype = (cpu_subtype_t)be32(cs[i]);
            ar[i].offset = be32(off[i]); ar[i].size = be32((uint32_t)size); ar[i].align = be32(align);
            memcpy(out + off[i], b, size);
        }
        struct mach_header_64 *h = (struct mach_header_64 *)(out + off1);
        h->cputype = CPU_TYPE_ARM64; h->cpusubtype = CPU_SUBTYPE_ARM64E;
    }

    FILE *f = fopen(argv[2], "wb");
    if (!f || fwrite(out, 1, total, f) != total || fclose(f) != 0) { perror(argv[2]); return 2; }
    return 0;
}
