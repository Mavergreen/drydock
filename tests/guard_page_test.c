/* tests/guard_page_test.c -- a load command shorter than its struct, last in
 * an image that ends where the command does, against a PROT_NONE page: a
 * reader that takes a field past the command's 8 bytes faults here, on any
 * host, where tests/grow_test.c's cut images fault only under libgmalloc.
 *
 * Each reader runs in a child, so a fault is reported, not fatal.
 *
 * Short LC_DYLD_EXPORTS_TRIE, LC_FUNCTION_STARTS and LC_DATA_IN_CODE commands
 * belong here too, once a grow floors them: docs/superpowers/QUEUE.md item 32
 * records each as faulting today. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <mach-o/loader.h>

#include "grow.h"

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

enum { R_GROW, R_REBASES, R_TRIE, R_PEEK };

/* Runs reader `r` on the guarded image in a child. Returns its exit status,
 * or 128 + the signal that stopped it. The child's stderr goes to `err`. */
static int run(int r, uint8_t *img, size_t n, char *err, size_t errsz) {
    const char *tmp = getenv("TMPDIR");
    char path[1024];
    snprintf(path, sizeof path, "%s/guard_page_test.XXXXXX", tmp && *tmp ? tmp : "/tmp");
    int fd = mkstemp(path);
    if (fd < 0) { perror("mkstemp"); exit(2); }
    fflush(stdout);
    fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) { perror("fork"); exit(2); }
    if (pid == 0) {
        dup2(fd, 2);
        uint8_t *b = img;
        size_t sz = n;
        char why[256] = "";
        mg_rebases rb;
        uint32_t off, size;
        switch (r) {
        case R_GROW:
            _exit(mg_grow_header(&b, &sz, 0x1000) == -1 && b == img && sz == n ? 0 : 1);
        case R_REBASES: {
            int got = mg_rebases_read(img, n, &rb, why, sizeof why);
            fprintf(stderr, "%s\n", why);
            _exit(got == -1 ? 0 : 1);
        }
        case R_TRIE:
            _exit(mg_find_trie(img, n, &off, &size) == 0 ? 0 : 1);
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
    return WIFSIGNALED(st) ? 128 + WTERMSIG(st) : WEXITSTATUS(st);
}

/* Each command, and what refuses it: on the raise route, mg_raise_ok's floor
 * or mg_rebases_read's; on the lowering, mg_rebases_read's. A lowering reads
 * no LC_UUID, so an 8-byte one does not stop it. */
static const struct {
    uint32_t filetype, cmd;
    const char *what, *grow_says, *rebases_say;
} cases[] = {
    { MH_DYLIB, LC_DYSYMTAB, "raise: an 8-byte LC_DYSYMTAB",
      "ERROR: LC_DYSYMTAB is 8 bytes, too short to hold its tables' counts; refusing to grow",
      "the image's LC_DYSYMTAB command is 8 bytes, too short to hold nlocrel" },
    { MH_DYLIB, LC_DYLD_INFO_ONLY, "raise: an 8-byte LC_DYLD_INFO_ONLY",
      "ERROR: the image's LC_DYLD_INFO command is 8 bytes, too short to hold rebase_off/rebase_size",
      "the image's LC_DYLD_INFO command is 8 bytes, too short to hold rebase_off/rebase_size" },
    { MH_DYLIB, LC_UUID, "raise: an 8-byte LC_UUID",
      "ERROR: LC_UUID is 8 bytes, too short to hold its UUID; refusing to grow", NULL },
    { MH_DYLIB, LC_SYMTAB, "raise: an 8-byte LC_SYMTAB", "too short", NULL },
    { MH_EXECUTE, LC_DYSYMTAB, "lowering: an 8-byte LC_DYSYMTAB",
      "ERROR: the image's LC_DYSYMTAB command is 8 bytes, too short to hold nlocrel",
      "the image's LC_DYSYMTAB command is 8 bytes, too short to hold nlocrel" },
    { MH_EXECUTE, LC_DYLD_INFO_ONLY, "lowering: an 8-byte LC_DYLD_INFO_ONLY",
      "ERROR: the image's LC_DYLD_INFO command is 8 bytes, too short to hold rebase_off/rebase_size",
      "the image's LC_DYLD_INFO command is 8 bytes, too short to hold rebase_off/rebase_size" },
    { MH_EXECUTE, LC_SYMTAB, "lowering: an 8-byte LC_SYMTAB", "too short", NULL },
};

int main(void) {
    uint8_t src[4096];
    char err[4096];

    /* The positive control: the guard page is there, and faults. */
    size_t n = cut_image(src, MH_DYLIB, LC_UUID);
    uint8_t *img = guarded(src, n);
    int st = run(R_PEEK, img, n, err, sizeof err);
    CHECK(st == 128 + SIGSEGV || st == 128 + SIGBUS,
          "the positive control: a read of the byte past the image faults (got %d)", st);

    for (size_t k = 0; k < sizeof cases / sizeof cases[0]; k++) {
        n = cut_image(src, cases[k].filetype, cases[k].cmd);
        img = guarded(src, n);
        st = run(R_GROW, img, n, err, sizeof err);
        CHECK(st == 0 && strstr(err, cases[k].grow_says) != NULL && memcmp(img, src, n) == 0,
              "%s, last, refuses the grow before reading past it (got %d): %s", cases[k].what, st, err);
        st = run(R_REBASES, img, n, err, sizeof err);
        if (cases[k].rebases_say)
            CHECK(st == 0 && strstr(err, cases[k].rebases_say) != NULL,
                  "%s, last: mg_rebases_read refuses it (got %d): %s", cases[k].what, st, err);
        else
            CHECK(st < 128, "%s, last: mg_rebases_read reads nothing past it (got %d)", cases[k].what, st);
        st = run(R_TRIE, img, n, err, sizeof err);
        CHECK(cases[k].cmd == LC_DYLD_INFO_ONLY ? st == 0 : st < 128,
              "%s, last: mg_find_trie %s (got %d)", cases[k].what,
              cases[k].cmd == LC_DYLD_INFO_ONLY ? "takes it for no trie" : "reads nothing past it", st);
    }
    printf("guard_page_test: %d failure(s)\n", failures);
    return failures != 0;
}
