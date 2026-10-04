/* tests/guard_page_test.c -- a load command shorter than its struct, last in
 * an image that ends where the command does, against a PROT_NONE page: a
 * reader that takes a field past the command's 8 bytes faults here, on any
 * host, where tests/grow_test.c's cut images fault only under libgmalloc.
 *
 * mi_validate refuses such an image, so every reader that wraps it first
 * refuses too. Each kind below is one some reader takes fields from; each
 * reader runs in a child, so a fault is reported, not fatal. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach-o/loader.h>

#include "grow.h"
#include "hdrref.h"
#include "imports.h"
#include "linkedit_order.h"
#include "mach_compat.h"
#include "ordinals.h"

static int failures;

#define CHECK(cond, ...) do { \
        if (cond) { printf("PASS "); } else { printf("FAIL "); failures++; } \
        printf(__VA_ARGS__); printf("\n"); \
    } while (0)

/* An x86_64 image of `filetype`: __PAGEZERO for an executable, __TEXT with
 * one section whose file data would start where the load commands end, a
 * full LC_DYLD_INFO_ONLY unless `cmd` is one, and last an 8-byte `cmd`. The
 * image ends with that command. */
static size_t cut_image(uint8_t *buf, uint32_t filetype, uint32_t cmd) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = buf + sizeof *h;
    memset(buf, 0, 4096);
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = filetype;
    h->flags = MH_DYLDLINK | MH_TWOLEVEL | (filetype == MH_EXECUTE ? MH_PIE : 0);
    uint64_t base = filetype == MH_EXECUTE ? 0x100000000ull : 0;
    if (filetype == MH_EXECUTE) {
        struct segment_command_64 *z = (struct segment_command_64 *)p;
        z->cmd = LC_SEGMENT_64;
        z->cmdsize = sizeof *z;
        memcpy(z->segname, "__PAGEZERO", 10);
        z->vmsize = base;
        p += sizeof *z;
        h->ncmds++;
    }
    struct segment_command_64 *t = (struct segment_command_64 *)p;
    struct section_64 *s = (struct section_64 *)(t + 1);
    t->cmd = LC_SEGMENT_64;
    t->cmdsize = sizeof *t + sizeof *s;
    memcpy(t->segname, "__TEXT", 6);
    t->vmaddr = base;
    t->vmsize = t->filesize = 0x1000;
    t->maxprot = t->initprot = VM_PROT_READ | VM_PROT_EXECUTE;
    t->nsects = 1;
    memcpy(s->sectname, "__const", 7);
    memcpy(s->segname, "__TEXT", 6);
    p += t->cmdsize;
    h->ncmds++;
    if (cmd != LC_DYLD_INFO_ONLY) {
        struct dyld_info_command *d = (struct dyld_info_command *)p;
        d->cmd = LC_DYLD_INFO_ONLY;
        d->cmdsize = sizeof *d;
        p += sizeof *d;
        h->ncmds++;
    }
    struct load_command *l = (struct load_command *)p;
    l->cmd = cmd;
    l->cmdsize = 8;
    p += 8;
    h->ncmds++;
    h->sizeofcmds = (uint32_t)(p - buf - sizeof *h);
    s->offset = (uint32_t)(p - buf);
    s->addr = base + s->offset;
    return (size_t)(p - buf);
}

/* `n` bytes of `src` placed so that the byte after the last is the first of a
 * PROT_NONE page. */
static uint8_t *guarded(const uint8_t *src, size_t n) {
    size_t pg = (size_t)getpagesize();
    size_t span = (n + pg - 1) / pg * pg;
    uint8_t *m = (uint8_t *)mmap(NULL, span + pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); exit(2); }
    if (mprotect(m + span, pg, PROT_NONE) != 0) { perror("mprotect"); exit(2); }
    memcpy(m + span - n, src, n);
    return m + span - n;
}

/* cut_image, but last a `size`-byte `cmd` whose name, at `off`, runs to the
 * command's end: `size - off` bytes of 'A', the last a NUL only if `nul`;
 * none if `off` is past it. */
static size_t named_image(uint8_t *buf, uint32_t cmd, uint32_t size, uint32_t off, int nul) {
    size_t n = cut_image(buf, MH_DYLIB, cmd);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct load_command *l = (struct load_command *)(buf + n - 8);
    struct section_64 *s = (struct section_64 *)(buf + sizeof *h + sizeof(struct segment_command_64));
    l->cmdsize = size;
    memcpy((uint8_t *)l + 8, &off, sizeof off);
    if (off < size) memset((uint8_t *)l + off, 'A', size - off);
    if (nul && off < size) ((uint8_t *)l)[size - 1] = 0;
    h->sizeofcmds += size - 8;
    s->offset += size - 8;
    s->addr += size - 8;
    return n + size - 8;
}

static int never(const char *name, void *ctx) { (void)ctx; return strlen(name) == 0; }
static void row(const mimp_row *r, void *ctx) { (void)ctx; (void)strlen(r->install_name); }

/* Every reader of a load command's name, each of which must refuse one that
 * runs to the end of its command with no NUL, without reading past it: 0
 * when all did, else 1, naming the first that did not. */
static int names_refused(uint8_t *img, size_t n) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)img;
    const uint8_t *p = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i + 1 < h->ncmds; i++) p += ((const struct load_command *)p)->cmdsize;
    const struct load_command *l = (const struct load_command *)p;
    mo_map map;
    int nnew;
    uint32_t off;
    memcpy(&off, p + 8, sizeof off);
    const char *who =
        mo_lc_str_at(l, off) != NULL ? "mo_lc_str_at" :
        mo_is_ordinal_lc(l->cmd) && mo_map_build(img, h->ncmds, 0, never, NULL, &map, &nnew) != -1 ?
            "mo_map_build" :
        (mimp_report(img, n, row, NULL), NULL);
    if (who) fprintf(stderr, "%s did not refuse it\n", who);
    return who != NULL;
}

enum { R_GROW, R_READERS, R_NAMES, R_PEEK };

/* Every reader of a whole image, each of which must refuse this one before
 * it reads a field: 0 when all did, else 1, naming the first that did not. */
static int readers_refuse(uint8_t *img, size_t n) {
    static uint64_t addr[16];
    static uint8_t kinds[16];
    uint32_t off, size, cnt = 0;
    mg_rebases rb;
    mg_snapshot snap;
    mhr_cand bad;
    char why[256], corrupt[256];
    const char *who =
        mg_first_sect_off(img, n) != UINT32_MAX ? "mg_first_sect_off" :
        mg_classify(img, n, 1) != -1 ? "mg_classify" :
        mg_rebases_read(img, n, &rb, why, sizeof why) != -1 ? "mg_rebases_read" :
        mg_find_trie(img, n, &off, &size) != 0 ? "mg_find_trie" :
        mg_trie_walk(img, n, 0, 0, 0, addr, kinds, &cnt, 16) != 0 ? "mg_trie_walk" :
        mg_dice_walk(img, n, 0, 0, 0, addr, kinds, &cnt, 16) != -1 ? "mg_dice_walk" :
        mg_unwind_walk(img, n, 0, 0, 0, addr, kinds, &cnt, 16) != -1 ? "mg_unwind_walk" :
        mg_init_offsets_pass(img, n, 0x1000, 0) != -1 ? "mg_init_offsets_pass" :
        mg_collect(img, n, addr, kinds, 16, &cnt) != -1 ? "mg_collect" :
        mg_plausible(img, n) != -1 ? "mg_plausible" :
        mg_oracles(img, n, MG_OR_ALL, why, sizeof why) != 0 ? "mg_oracles" :
        mg_raise_pointers(img, n, 0, 0x1000, why, sizeof why) != -1 ? "mg_raise_pointers" :
        mg_header_pointers(img, n, 0, 0x1000, 0, 0, why, sizeof why) != -1 ? "mg_header_pointers" :
        mhr_scan(img, n, 0, NULL, NULL) != -1 ? "mhr_scan" :
        mhr_confirm(img, n, &bad) != -1 ? "mhr_confirm" :
        mlo_file_verdict(img, n, why, sizeof why, corrupt, sizeof corrupt) != -1 ? "mlo_file_verdict" :
        mg_snapshot_take(img, n, &snap) != -1 ? "mg_snapshot_take" : NULL;
    if (who) fprintf(stderr, "%s did not refuse it\n", who);
    return who != NULL;
}

/* Runs reader `r` on the guarded image in a child. Returns its exit status,
 * or 128 + the signal that stopped it. The child's stderr goes to `err`. */
static int run(int r, uint8_t *img, size_t n, char *err, size_t errsz) {
    const char *tmp = getenv("TMPDIR");
    char path[1024];
    snprintf(path, sizeof path, "%s/guard_page_test.XXXXXX", tmp && *tmp ? tmp : "/tmp");
    int fd = mkstemp(path);
    if (fd < 0) { perror("mkstemp"); exit(2); }
    uint8_t *before = (uint8_t *)malloc(n);
    if (!before) { perror("malloc"); exit(2); }
    memcpy(before, img, n);
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); exit(2); }
    if (pid == 0) {
        dup2(fd, 2);
        uint8_t *b = img;
        size_t sz = n;
        switch (r) {
        case R_GROW:
            _exit(mg_grow_header(&b, &sz, 0x1000) == -1 && b == img && sz == n &&
                  memcmp(img, before, n) == 0 ? 0 : 1);
        case R_READERS:
            _exit(readers_refuse(img, n));
        case R_NAMES:
            _exit(names_refused(img, n));
        case R_PEEK:
            _exit(img[n] == 0x55 ? 3 : 4);
        }
        _exit(5);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    ssize_t got = pread(fd, err, errsz - 1, 0);
    err[got > 0 ? got : 0] = 0;
    close(fd);
    unlink(path);
    free(before);
    return WIFSIGNALED(st) ? 128 + WTERMSIG(st) : WEXITSTATUS(st);
}

/* The kinds a reader here takes fields from past the first 8 bytes. */
static const struct { uint32_t cmd; const char *name; } kinds[] = {
    { LC_SEGMENT_64, "LC_SEGMENT_64" }, { LC_SYMTAB, "LC_SYMTAB" }, { LC_DYSYMTAB, "LC_DYSYMTAB" },
    { LC_DYLD_INFO_ONLY, "LC_DYLD_INFO_ONLY" }, { LC_DYLD_INFO, "LC_DYLD_INFO" },
    { LC_DYLD_EXPORTS_TRIE, "LC_DYLD_EXPORTS_TRIE" }, { LC_FUNCTION_STARTS, "LC_FUNCTION_STARTS" },
    { LC_DATA_IN_CODE, "LC_DATA_IN_CODE" }, { LC_DYLD_CHAINED_FIXUPS, "LC_DYLD_CHAINED_FIXUPS" },
    { LC_SEGMENT_SPLIT_INFO, "LC_SEGMENT_SPLIT_INFO" }, { LC_CODE_SIGNATURE, "LC_CODE_SIGNATURE" },
    { LC_UUID, "LC_UUID" }, { LC_ROUTINES_64, "LC_ROUTINES_64" },
    { LC_ENCRYPTION_INFO, "LC_ENCRYPTION_INFO" }, { LC_ENCRYPTION_INFO_64, "LC_ENCRYPTION_INFO_64" },
    { LC_MAIN, "LC_MAIN" }, { LC_LOAD_DYLIB, "LC_LOAD_DYLIB" }, { LC_ID_DYLIB, "LC_ID_DYLIB" },
    { LC_RPATH, "LC_RPATH" }, { LC_VERSION_MIN_MACOSX, "LC_VERSION_MIN_MACOSX" },
    { LC_BUILD_VERSION, "LC_BUILD_VERSION" }, { LC_TWOLEVEL_HINTS, "LC_TWOLEVEL_HINTS" },
};

int main(void) {
    uint8_t src[4096];
    char err[4096];

    /* The positive control: the guard page is there, and faults. */
    size_t n = cut_image(src, MH_DYLIB, LC_UUID);
    uint8_t *img = guarded(src, n);
    int st = run(R_PEEK, img, n, err, sizeof err);
    if (st != 128 + SIGSEGV && st != 128 + SIGBUS) {
        printf("SKIP guard_page_test: the host does not fault on a PROT_NONE page (got %d), "
               "so the readers' bounds cannot be judged here\n", st);
        return 77;
    }

    static const uint32_t filetype[2] = { MH_DYLIB, MH_EXECUTE };
    static const char *const route[2] = { "raise", "lowering" };
    for (size_t k = 0; k < sizeof kinds / sizeof kinds[0]; k++) {
        for (int f = 0; f < 2; f++) {
            n = cut_image(src, filetype[f], kinds[k].cmd);
            img = guarded(src, n);
            st = run(R_GROW, img, n, err, sizeof err);
            CHECK(st == 0 && strstr(err, "ERROR: image fails validation") != NULL,
                  "%s: an 8-byte %s, last, refuses the grow before reading past it (got %d) %s",
                  route[f], kinds[k].name, st, st == 0 ? "" : err);
            st = run(R_READERS, img, n, err, sizeof err);
            CHECK(st == 0, "%s: an 8-byte %s, last: every reader refuses it (got %d) %s",
                  route[f], kinds[k].name, st, st == 0 ? "" : err);
        }
    }
    /* A name with no NUL inside its command, last: each reader refuses it.
     * And the same name ending in its command's last byte is read. */
    static const struct { uint32_t cmd; const char *name; uint32_t size, off; } named[] = {
        { LC_RPATH, "LC_RPATH", 16, 12 }, { LC_LOAD_DYLIB, "LC_LOAD_DYLIB", 32, 24 },
        { LC_ID_DYLIB, "LC_ID_DYLIB", 32, 24 }, { LC_RPATH, "LC_RPATH, its offset 64,", 16, 64 },
    };
    for (size_t k = 0; k < sizeof named / sizeof named[0]; k++) {
        n = named_image(src, named[k].cmd, named[k].size, named[k].off, 0);
        img = guarded(src, n);
        st = run(R_NAMES, img, n, err, sizeof err);
        CHECK(st == 0, "an %s whose name has no NUL inside it, last: every reader of names refuses it "
              "(got %d) %s", named[k].name, st, st == 0 ? "" : err);
        if (named[k].off >= named[k].size) continue;
        n = named_image(src, named[k].cmd, named[k].size, named[k].off, 1);
        img = guarded(src, n);
        const struct load_command *l = (const struct load_command *)(img + n - named[k].size);
        const char *s = mo_lc_str_at(l, named[k].off);
        CHECK(s && strlen(s) == named[k].size - named[k].off - 1, "an %s whose name's NUL is its "
              "command's last byte: mo_lc_str_at reads it", named[k].name);
    }
    printf("guard_page_test: %d failure(s)\n", failures);
    return failures != 0;
}
