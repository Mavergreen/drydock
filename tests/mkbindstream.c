/* mkbindstream -- hand-built bind streams for tests/import_redirect_test.sh.
 *
 *   mkbindstream set IN OUT bind|weak|lazy TOKEN...
 *   mkbindstream info FILE
 *   mkbindstream noexports IN OUT
 *   mkbindstream nlist FILE SYMBOL
 *   mkbindstream alias IN OUT
 *
 * `set` writes the stream the tokens spell at the end of IN (8-aligned),
 * points LC_DYLD_INFO's offset and size at exactly it -- no padding after, so
 * a stream that must grow has no slack to grow into -- and extends __LINKEDIT
 * over it. Every other byte of IN is kept. Tokens:
 *
 *   ord:N        SET_DYLIB_ORDINAL, the shortest form (IMM up to 15)
 *   flat         SET_DYLIB_SPECIAL_IMM, flat lookup
 *   sym:NAME     SET_SYMBOL_TRAILING_FLAGS_IMM, no flags
 *   type:N       SET_TYPE_IMM
 *   seg:S:OFF    SET_SEGMENT_AND_OFFSET_ULEB
 *   do           DO_BIND
 *   done         DONE
 *
 * `info` prints `bind OFF SIZE`, `weak ...`, `lazy ...` and `linkedit FILESIZE`,
 * one per line. `noexports` zeroes LC_DYLD_INFO's export offset and size, so
 * the image has no export trie left to read. `nlist` prints the library
 * ordinal the symbol table's undefined SYMBOL records. `alias` points the
 * weak-bind table at the bind stream's own bytes, which no linker does and a
 * hostile file can. Self-contained on purpose: a fixture builder that shared the
 * code under test could not catch its mistakes. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

static uint8_t *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = malloc((size_t)len + 4096 + 65536);
    if (!b || fread(b, 1, (size_t)len, f) != (size_t)len) { perror(path); exit(2); }
    fclose(f);
    *n = (size_t)len;
    return b;
}

static void find(uint8_t *b, struct dyld_info_command **di, struct segment_command_64 **le) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = b + sizeof *h;
    *di = NULL; *le = NULL;
    if (h->magic != MH_MAGIC_64) { fprintf(stderr, "not a thin 64-bit Mach-O\n"); exit(2); }
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY)
            *di = (struct dyld_info_command *)p;
        if (lc->cmd == LC_SEGMENT_64 &&
            strncmp(((struct segment_command_64 *)p)->segname, "__LINKEDIT", 16) == 0)
            *le = (struct segment_command_64 *)p;
        p += lc->cmdsize;
    }
    if (!*di || !*le) { fprintf(stderr, "no LC_DYLD_INFO or no __LINKEDIT\n"); exit(2); }
}

static size_t uleb(uint8_t *p, uint64_t v) {
    size_t n = 0;
    do {
        uint8_t byte = v & 0x7f;
        v >>= 7;
        if (v) byte |= 0x80;
        p[n++] = byte;
    } while (v);
    return n;
}

int main(int argc, char **argv) {
    size_t n;
    struct dyld_info_command *di;
    struct segment_command_64 *le;
    if (argc == 3 && strcmp(argv[1], "info") == 0) {
        uint8_t *b = slurp(argv[2], &n);
        find(b, &di, &le);
        printf("bind %u %u\nweak %u %u\nlazy %u %u\nlinkedit %llu\n",
               di->bind_off, di->bind_size, di->weak_bind_off, di->weak_bind_size,
               di->lazy_bind_off, di->lazy_bind_size, (unsigned long long)le->filesize);
        return 0;
    }
    if (argc == 4 && strcmp(argv[1], "nlist") == 0) {
        uint8_t *b = slurp(argv[2], &n);
        struct mach_header_64 *h = (struct mach_header_64 *)b;
        uint8_t *p = b + sizeof *h;
        for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize) {
            struct symtab_command *st = (struct symtab_command *)p;
            if (st->cmd != LC_SYMTAB) continue;
            struct nlist_64 *nl = (struct nlist_64 *)(b + st->symoff);
            for (uint32_t k = 0; k < st->nsyms; k++) {
                if ((nl[k].n_type & N_TYPE) != N_UNDF || !(nl[k].n_type & N_EXT)) continue;
                if (strcmp((char *)b + st->stroff + nl[k].n_un.n_strx, argv[3]) != 0) continue;
                printf("%d\n", GET_LIBRARY_ORDINAL(nl[k].n_desc));
                return 0;
            }
        }
        fprintf(stderr, "no undefined %s\n", argv[3]);
        return 1;
    }
    if (argc == 4 && (strcmp(argv[1], "noexports") == 0 || strcmp(argv[1], "alias") == 0)) {
        uint8_t *b = slurp(argv[2], &n);
        find(b, &di, &le);
        if (argv[1][0] == 'n') {
            di->export_off = 0;
            di->export_size = 0;
        } else {
            di->weak_bind_off = di->bind_off;
            di->weak_bind_size = di->bind_size;
        }
        FILE *f = fopen(argv[3], "wb");
        if (!f || fwrite(b, 1, n, f) != n || fclose(f) != 0) { perror(argv[3]); return 2; }
        return 0;
    }
    if (argc < 5 || strcmp(argv[1], "set") != 0) {
        fprintf(stderr, "usage: mkbindstream set IN OUT bind|weak|lazy TOKEN... | info FILE | noexports IN OUT | nlist FILE SYMBOL | alias IN OUT\n");
        return 2;
    }
    uint8_t *b = slurp(argv[2], &n);
    find(b, &di, &le);
    if (le->fileoff + le->filesize != n) { fprintf(stderr, "__LINKEDIT does not end the file\n"); return 2; }
    size_t at = (n + 7) & ~(size_t)7, o = at;
    memset(b + n, 0, at - n);
    for (int i = 5; i < argc; i++) {
        const char *t = argv[i];
        unsigned a;
        unsigned long long off;
        if (strncmp(t, "ord:", 4) == 0 && sscanf(t + 4, "%u", &a) == 1) {
            if (a <= 15) b[o++] = (uint8_t)(BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | a);
            else { b[o++] = BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB; o += uleb(b + o, a); }
        } else if (strncmp(t, "sym:", 4) == 0) {
            b[o++] = BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM;
            size_t l = strlen(t + 4) + 1;
            memcpy(b + o, t + 4, l);
            o += l;
        } else if (strncmp(t, "type:", 5) == 0 && sscanf(t + 5, "%u", &a) == 1) {
            b[o++] = (uint8_t)(BIND_OPCODE_SET_TYPE_IMM | a);
        } else if (strncmp(t, "seg:", 4) == 0 && sscanf(t + 4, "%u:%llx", &a, &off) == 2) {
            b[o++] = (uint8_t)(BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | a);
            o += uleb(b + o, off);
        } else if (strcmp(t, "flat") == 0) {
            b[o++] = (uint8_t)(BIND_OPCODE_SET_DYLIB_SPECIAL_IMM |
                               (BIND_SPECIAL_DYLIB_FLAT_LOOKUP & BIND_IMMEDIATE_MASK));
        } else if (strcmp(t, "do") == 0) {
            b[o++] = BIND_OPCODE_DO_BIND;
        } else if (strcmp(t, "done") == 0) {
            b[o++] = BIND_OPCODE_DONE;
        } else {
            fprintf(stderr, "unknown token '%s'\n", t);
            return 2;
        }
        if (o - at > 60000) { fprintf(stderr, "stream too long\n"); return 2; }
    }
    uint32_t *off_f, *size_f;
    if (strcmp(argv[4], "bind") == 0)      { off_f = &di->bind_off;      size_f = &di->bind_size; }
    else if (strcmp(argv[4], "weak") == 0) { off_f = &di->weak_bind_off; size_f = &di->weak_bind_size; }
    else if (strcmp(argv[4], "lazy") == 0) { off_f = &di->lazy_bind_off; size_f = &di->lazy_bind_size; }
    else { fprintf(stderr, "unknown stream '%s'\n", argv[4]); return 2; }
    *off_f = (uint32_t)at;
    *size_f = (uint32_t)(o - at);
    le->filesize = o - le->fileoff;
    if (le->vmsize < ((le->filesize + 0xfff) & ~0xfffULL)) le->vmsize = (le->filesize + 0xfff) & ~0xfffULL;
    FILE *f = fopen(argv[3], "wb");
    if (!f || fwrite(b, 1, o, f) != o || fclose(f) != 0) { perror(argv[3]); return 2; }
    return 0;
}
