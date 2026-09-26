/* tests/mklinkedit.c -- writes one of tests/linkedit_fixture.h's variants,
 * for tests/codesign_order_test.sh.
 *   mklinkedit list              every variant: NAME TAB corrupting TAB tool
 *   mklinkedit make NAME OUT
 *   mklinkedit raw LAYOUT OPTS OUT   an unnamed lkf_build layout, for a CLI
 *                                    regression pin not worth an oracle-swept variant
 *   mklinkedit pieces FILE       NAME OFFSET SIZE per non-empty piece of a thin
 *                                64-bit file, the signature included (as "sig"),
 *                                read apart from src/
 *   mklinkedit lone CMD SIZE OUT a dylib whose one load command, CMD, is SIZE
 *                                bytes of zeros after its cmd and cmdsize
 *   mklinkedit short-last OUT    lkf_short_last's image */
#include <stdio.h>
#include "linkedit_fixture.h"

static int write_out(const char *path, const uint8_t *b, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(b, 1, n, f) != n) return 2;
    return fclose(f) == 0 ? 0 : 2;
}

static int lone(uint32_t cmd, uint32_t size, const char *path) {
    static uint8_t b[sizeof(struct mach_header_64) + 4096];
    if (size < 8 || size > 4096) return 2;
    memset(b, 0, sizeof b);
    struct load_command *lc = (struct load_command *)(lkf_short_header(b, 1, size) + 1);
    lc->cmd = cmd;
    lc->cmdsize = size;
    return write_out(path, b, sizeof(struct mach_header_64) + size);
}

static int short_last(const char *path) {
    uint8_t b[LKF_SHORT_LAST];
    return write_out(path, b, lkf_short_last(b));
}

static int pieces(const char *path) {
    static uint8_t b[1 << 24];
    FILE *f = fopen(path, "rb");
    if (!f) return 2;
    size_t n = fread(b, 1, sizeof b, f);
    fclose(f);
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    if (n < sizeof *h || h->magic != MH_MAGIC_64) return 2;
    uint8_t *p = (uint8_t *)(h + 1);
#define P(name, o, s) do { if (s) printf("%s %u %u\n", name, (unsigned)(o), (unsigned)(s)); } while (0)
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
        struct load_command *lc = (struct load_command *)p;
        switch (lc->cmd) {
        case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY: {
            struct dyld_info_command *d = (struct dyld_info_command *)lc;
            P("rebase", d->rebase_off, d->rebase_size);
            P("bind", d->bind_off, d->bind_size);
            P("weak", d->weak_bind_off, d->weak_bind_size);
            P("lazy", d->lazy_bind_off, d->lazy_bind_size);
            P("export", d->export_off, d->export_size);
            break;
        }
        case LC_SYMTAB: {
            struct symtab_command *s = (struct symtab_command *)lc;
            P("symtab", s->symoff, s->nsyms * 16);
            P("strtab", s->stroff, s->strsize);
            break;
        }
        case LC_DYSYMTAB: {
            struct dysymtab_command *d = (struct dysymtab_command *)lc;
            P("toc", d->tocoff, d->ntoc * 8);
            P("modtab", d->modtaboff, d->nmodtab * 56);
            P("refs", d->extrefsymoff, d->nextrefsyms * 4);
            P("indirect", d->indirectsymoff, d->nindirectsyms * 4);
            P("extrel", d->extreloff, d->nextrel * 8);
            P("locrel", d->locreloff, d->nlocrel * 8);
            break;
        }
        case LC_TWOLEVEL_HINTS: {
            struct twolevel_hints_command *t = (struct twolevel_hints_command *)lc;
            P("hints", t->offset, t->nhints * 4);
            break;
        }
        case LC_SEGMENT_SPLIT_INFO: case LC_FUNCTION_STARTS: case LC_DATA_IN_CODE:
        case LC_DYLIB_CODE_SIGN_DRS: case 0x2e /* LC_LINKER_OPTIMIZATION_HINT */:
        case LC_CODE_SIGNATURE: {
            struct linkedit_data_command *l = (struct linkedit_data_command *)lc;
            const char *nm = lc->cmd == LC_SEGMENT_SPLIT_INFO ? "split"
                           : lc->cmd == LC_FUNCTION_STARTS ? "fstarts"
                           : lc->cmd == LC_DATA_IN_CODE ? "dic"
                           : lc->cmd == LC_DYLIB_CODE_SIGN_DRS ? "drs"
                           : lc->cmd == LC_CODE_SIGNATURE ? "sig" : "loh";
            P(nm, l->dataoff, l->datasize);
            break;
        }
        }
    }
#undef P
    return 0;
}

int main(int argc, char **argv) {
    static uint8_t buf[LKF_CAP];
    if (argc == 2 && strcmp(argv[1], "list") == 0) {
        for (size_t k = 0; k < LKF_NVARIANTS; k++)
            printf("%s\t%d\t%s\n", lkf_variants[k].name, lkf_variants[k].corrupting,
                   lkf_variants[k].tool ? lkf_variants[k].tool : "");
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "pieces") == 0) return pieces(argv[2]);
    if (argc == 5 && strcmp(argv[1], "lone") == 0)
        return lone((uint32_t)strtoul(argv[2], NULL, 0), (uint32_t)strtoul(argv[3], NULL, 0), argv[4]);
    if (argc == 3 && strcmp(argv[1], "short-last") == 0) return short_last(argv[2]);
    if (argc == 4 && strcmp(argv[1], "make") == 0) {
        for (size_t k = 0; k < LKF_NVARIANTS; k++) {
            if (strcmp(lkf_variants[k].name, argv[2]) != 0) continue;
            size_t n = lkf_make(buf, &lkf_variants[k]);
            FILE *f = fopen(argv[3], "wb");
            if (!n || !f || fwrite(buf, 1, n, f) != n) return 2;
            return fclose(f) == 0 ? 0 : 2;
        }
        fprintf(stderr, "mklinkedit: no variant '%s'\n", argv[2]);
        return 2;
    }
    if (argc == 5 && strcmp(argv[1], "raw") == 0) {
        size_t n = lkf_build(buf, argv[2], (unsigned)strtoul(argv[3], NULL, 0));
        FILE *f = fopen(argv[4], "wb");
        if (!n || !f || fwrite(buf, 1, n, f) != n) return 2;
        return fclose(f) == 0 ? 0 : 2;
    }
    fprintf(stderr, "usage: mklinkedit list | make NAME OUT | raw LAYOUT OPTS OUT | pieces FILE"
                    " | lone CMD SIZE OUT | short-last OUT\n");
    return 2;
}
