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
 *   mklinkedit short-last OUT    lkf_short_last's image
 *   mklinkedit grow-trie OUT     a signed PIE executable in codesign_allocate's
 *                                order whose one export, at 16,000, fills its
 *                                16-byte trie: a header grow of 4096 widens
 *                                that address, so the rebuilt trie no longer
 *                                fits and goes at the end of the file */
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

static int grow_trie(const char *path) {
    enum { TEXT = 0x4000, LE = TEXT, EXPORT = LE, SYMS = LE + 0x10, STRS = LE + 0x20,
           SIG = LE + 0x30, END = LE + 0x40, FN = 0x3e80 };
    static uint8_t b[END];
    memset(b, 0, sizeof b);
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_EXECUTE;
    h->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE;
    uint8_t *p = (uint8_t *)(h + 1);
    struct segment_command_64 *pz = (struct segment_command_64 *)p;
    pz->cmd = LC_SEGMENT_64;
    pz->cmdsize = sizeof *pz;
    strcpy(pz->segname, "__PAGEZERO");
    pz->vmsize = 0x100000000ull;
    p += pz->cmdsize;
    struct segment_command_64 *tx = (struct segment_command_64 *)p;
    struct section_64 *s = (struct section_64 *)(tx + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + 2 * sizeof *s;
    strcpy(tx->segname, "__TEXT");
    tx->vmaddr = 0x100000000ull;
    tx->vmsize = tx->filesize = TEXT;
    tx->maxprot = tx->initprot = VM_PROT_READ | VM_PROT_EXECUTE;
    tx->nsects = 2;
    /* a section low in the file, so the header pad is small */
    strncpy(s[0].sectname, "__const", sizeof s[0].sectname);
    strncpy(s[0].segname, "__TEXT", sizeof s[0].segname);
    s[0].addr = tx->vmaddr + 0x400;
    s[0].size = 8;
    s[0].offset = 0x400;
    strncpy(s[1].sectname, "__text", sizeof s[1].sectname);
    strncpy(s[1].segname, "__TEXT", sizeof s[1].segname);
    s[1].addr = tx->vmaddr + FN;
    s[1].size = 16;
    s[1].offset = FN;
    s[1].flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    b[FN] = 0xc3;   /* ret */
    p += tx->cmdsize;
    struct segment_command_64 *le = (struct segment_command_64 *)p;
    le->cmd = LC_SEGMENT_64;
    le->cmdsize = sizeof *le;
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = tx->vmaddr + TEXT;
    le->vmsize = 0x1000;
    le->fileoff = LE;
    le->filesize = END - LE;
    le->maxprot = le->initprot = VM_PROT_READ;
    p += le->cmdsize;
    struct dyld_info_command *di = (struct dyld_info_command *)p;
    di->cmd = LC_DYLD_INFO_ONLY;
    di->cmdsize = sizeof *di;
    di->export_off = EXPORT;
    di->export_size = 16;
    p += di->cmdsize;
    struct symtab_command *st = (struct symtab_command *)p;
    st->cmd = LC_SYMTAB;
    st->cmdsize = sizeof *st;
    st->symoff = SYMS;
    st->nsyms = 1;
    st->stroff = STRS;
    st->strsize = 16;
    p += st->cmdsize;
    struct dysymtab_command *dy = (struct dysymtab_command *)p;
    dy->cmd = LC_DYSYMTAB;
    dy->cmdsize = sizeof *dy;
    dy->nextdefsym = 1;
    p += dy->cmdsize;
    struct linkedit_data_command *cs = (struct linkedit_data_command *)p;
    cs->cmd = LC_CODE_SIGNATURE;
    cs->cmdsize = sizeof *cs;
    cs->dataoff = SIG;
    cs->datasize = 16;
    p += cs->cmdsize;
    h->ncmds = 7;
    h->sizeofcmds = (uint32_t)(p - (uint8_t *)(h + 1));
    /* The trie: a root with one edge, "_ABCDEF", to a node exporting 16,000
     * (a two-byte ULEB, 80 7d) with no children: sixteen bytes. */
    static const uint8_t trie[16] = { 0x00, 0x01, '_', 'A', 'B', 'C', 'D', 'E', 'F', 0x00, 11,
                                      0x03, 0x00, 0x80, 0x7d, 0x00 };
    memcpy(b + EXPORT, trie, sizeof trie);
    struct nlist_64 *n = (struct nlist_64 *)(b + SYMS);
    n->n_un.n_strx = 1;
    n->n_type = N_SECT | N_EXT;
    n->n_sect = 2;
    n->n_value = tx->vmaddr + FN;
    memcpy(b + STRS, "\0_ABCDEF", 9);
    static const uint8_t sig[16] = { 0xfa, 0xde, 0x0c, 0xc0, 0, 0, 0, 16 };
    memcpy(b + SIG, sig, sizeof sig);
    return write_out(path, b, sizeof b);
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
    if (argc == 3 && strcmp(argv[1], "grow-trie") == 0) return grow_trie(argv[2]);
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
                    " | lone CMD SIZE OUT | short-last OUT | grow-trie OUT\n");
    return 2;
}
