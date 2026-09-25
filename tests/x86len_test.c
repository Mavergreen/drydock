/*
 * tests/x86len_test.c -- hermetic tests for src/x86len.h's mx_decode.
 *
 * Each case is an instruction's bytes, hand-assembled, and where its ModRM,
 * displacement and immediate lie. LLVM 22's llvm-objdump decodes each as it
 * is here, and so does 10.9's otool, except where a case says otherwise;
 * tests/x86len_oracle_test.sh checks the decoder against otool over real
 * images.
 */
#include "x86len.h"
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

struct xcase {
    const char *what;
    int n;                 /* bytes available */
    uint8_t b[16];
    int len, modrm, disp, displen, immlen;   /* len 0: not decoded */
};

#define D32 0x11, 0x22, 0x33, 0x44
static const struct xcase cases[] = {
    { "push %rbp", 1, { 0x55 }, 1, -1, -1, 0, 0 },
    { "mov %rsp, %rbp", 3, { 0x48, 0x89, 0xe5 }, 3, 2, -1, 0, 0 },
    { "mov %rax, %rsp (mod 3, r/m 4: no SIB)", 3, { 0x48, 0x89, 0xc4 }, 3, 2, -1, 0, 0 },
    { "mov -8(%rbp), %eax (mod 1, r/m 5: not RIP)", 3, { 0x8b, 0x45, 0xf8 }, 3, 1, 2, 1, 0 },
    { "lea hdr(%rip), %rdx", 7, { 0x48, 0x8d, 0x15, D32 }, 7, 2, 3, 4, 0 },
    { "cmpl $1, x(%rip)", 7, { 0x83, 0x3d, D32, 0x01 }, 7, 1, 2, 4, 1 },
    { "movl $imm32, x(%rip)", 10, { 0xc7, 0x05, D32, D32 }, 10, 1, 2, 4, 4 },
    { "movw $imm16, x(%rip)", 9, { 0x66, 0xc7, 0x05, D32, 0x01, 0x02 }, 9, 2, 3, 4, 2 },
    { "testb $1, 0x250(%rdi)", 7, { 0xf6, 0x87, 0x50, 0x02, 0x00, 0x00, 0x01 }, 7, 1, 2, 4, 1 },
    { "testl $imm32, %eax (F7 /0)", 6, { 0xf7, 0xc0, D32 }, 6, 1, -1, 0, 4 },
    { "notl (%rax) (F7 /2)", 2, { 0xf7, 0x10 }, 2, 1, -1, 0, 0 },
    { "notb (%rax) (F6 /2)", 2, { 0xf6, 0x10 }, 2, 1, -1, 0, 0 },
    { "mov 8(%rsp), %eax (SIB, disp8)", 4, { 0x8b, 0x44, 0x24, 0x08 }, 4, 1, 3, 1, 0 },
    { "mov abs32, %eax (SIB, no base)", 7, { 0x8b, 0x04, 0x25, D32 }, 7, 1, 3, 4, 0 },
    { "mov (%rbp,%rax), %eax (SIB base rbp, mod 1)", 4, { 0x8b, 0x44, 0x05, 0x00 }, 4, 1, 3, 1, 0 },
    { "mov disp32(%rax), %eax", 6, { 0x8b, 0x80, D32 }, 6, 1, 2, 4, 0 },
    { "movabs $imm64, %rax", 10, { 0x48, 0xb8, D32, D32 }, 10, -1, -1, 0, 8 },
    { "mov $imm32, %eax", 5, { 0xb8, D32 }, 5, -1, -1, 0, 4 },
    { "mov $imm32, %r8d (REX without W)", 6, { 0x41, 0xb8, D32 }, 6, -1, -1, 0, 4 },
    { "mov $imm16, %ax", 4, { 0x66, 0xb8, 0x01, 0x02 }, 4, -1, -1, 0, 2 },
    { "cmp $imm32, %eax (3D)", 5, { 0x3d, D32 }, 5, -1, -1, 0, 4 },
    { "push $imm32 (68)", 5, { 0x68, D32 }, 5, -1, -1, 0, 4 },
    { "cmp $imm16, %ax (66 3D)", 4, { 0x66, 0x3d, 0x01, 0x02 }, 4, -1, -1, 0, 2 },
    { "cmp $imm32, %rax (66 48 3D: REX.W outranks 66)", 7, { 0x66, 0x48, 0x3d, D32 }, 7, -1, -1, 0, 4 },
    { "add $imm32, %rax (66 48 81: REX.W outranks 66)", 8, { 0x66, 0x48, 0x81, 0xc0, D32 }, 8, 3, -1, 0, 4 },
    { "mov $imm32, %rax (66 48 C7: REX.W outranks 66)", 8, { 0x66, 0x48, 0xc7, 0xc0, D32 }, 8, 3, -1, 0, 4 },
    { "mov x(%eip), %eax (67 and a ModRM)", 7, { 0x67, 0x8b, 0x05, D32 }, 7, 2, 3, 4, 0 },
    /* otool reads this as data16 and a 32-bit immediate; the CPU and LLVM do not. */
    { "a REX before a prefix counts for nothing", 5, { 0x48, 0x66, 0xb8, 0x01, 0x02 }, 5, -1, -1, 0, 2 },
    { "mov moffs64, %eax", 9, { 0xa1, D32, D32 }, 9, -1, 1, 8, 0 },
    { "mov moffs32, %eax (67)", 6, { 0x67, 0xa1, D32 }, 6, -1, 2, 4, 0 },
    { "call rel32", 5, { 0xe8, D32 }, 5, -1, -1, 0, 4 },
    { "jmp rel8", 2, { 0xeb, 0x06 }, 2, -1, -1, 0, 1 },
    { "je rel32", 6, { 0x0f, 0x84, D32 }, 6, -1, -1, 0, 4 },
    { "enter $16, $0", 4, { 0xc8, 0x10, 0x00, 0x00 }, 4, -1, -1, 0, 3 },
    { "ret $8", 3, { 0xc2, 0x08, 0x00 }, 3, -1, -1, 0, 2 },
    { "bt $10, %eax (0F BA)", 4, { 0x0f, 0xba, 0xe0, 0x0a }, 4, 2, -1, 0, 1 },
    { "shufps $0x1b (0F C6)", 4, { 0x0f, 0xc6, 0xc1, 0x1b }, 4, 2, -1, 0, 1 },
    { "pshufb (0F 38)", 5, { 0x66, 0x0f, 0x38, 0x00, 0xc1 }, 5, 4, -1, 0, 0 },
    { "palignr $8 (0F 3A)", 6, { 0x66, 0x0f, 0x3a, 0x0f, 0xc1, 0x08 }, 6, 4, -1, 0, 1 },
    { "xorps %xmm0, %xmm0", 3, { 0x0f, 0x57, 0xc0 }, 3, 2, -1, 0, 0 },
    { "paddd %mm1, %mm2 (0F FE, reg 2)", 3, { 0x0f, 0xfe, 0xd1 }, 3, 2, -1, 0, 0 },
    { "cmpxchg8b (%rax) (0F C7, reg 1)", 3, { 0x0f, 0xc7, 0x08 }, 3, 2, -1, 0, 0 },
    { "movups %xmm0, x(%rip)", 7, { 0x0f, 0x11, 0x05, D32 }, 7, 2, 3, 4, 0 },
    { "syscall (0F, nothing more)", 2, { 0x0f, 0x05 }, 2, -1, -1, 0, 0 },
    { "vzeroupper (VEX, no ModRM)", 3, { 0xc5, 0xf8, 0x77 }, 3, -1, -1, 0, 0 },
    { "vmovdqa x(%rip), %xmm0 (VEX2)", 8, { 0xc5, 0xf9, 0x6f, 0x05, D32 }, 8, 3, 4, 4, 0 },
    { "vpshufd $0x1b (VEX2, imm8)", 5, { 0xc5, 0xf9, 0x70, 0xc1, 0x1b }, 5, 3, -1, 0, 1 },
    { "vpshufb (VEX3, 0F 38)", 5, { 0xc4, 0xe2, 0x7d, 0x00, 0xc1 }, 5, 4, -1, 0, 0 },
    { "vinsertf128 $1 (VEX3, 0F 3A)", 6, { 0xc4, 0xe3, 0x7d, 0x18, 0xc1, 0x01 }, 6, 4, -1, 0, 1 },
    { "vmovups x(%rip), %ymm0 (VEX3, 0F)", 9, { 0xc4, 0xe1, 0x7c, 0x10, 0x05, D32 }, 9, 4, 5, 4, 0 },
    { "lock cmpxchg %rdx, (%rcx)", 5, { 0xf0, 0x48, 0x0f, 0xb1, 0x11 }, 5, 4, -1, 0, 0 },
    { "rep movsb", 2, { 0xf3, 0xa4 }, 2, -1, -1, 0, 0 },
    { "nopw %cs:0(%rax,%rax)", 10, { 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0, 0, 0, 0 }, 10, 4, 6, 4, 0 },
    { "fifteen bytes", 15, { 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0, 0, 0, 0 },
      15, 9, 11, 4, 0 },
    { "xbegin rel32 (C7 F8)", 6, { 0xc7, 0xf8, D32 }, 6, 1, -1, 0, 4 },
    { "xabort $1 (C6 F8)", 3, { 0xc6, 0xf8, 0x01 }, 3, 1, -1, 0, 1 },
    { "pop (%rax) (8F /0)", 2, { 0x8f, 0x00 }, 2, 1, -1, 0, 0 },
    { "fldl (%rax) (x87)", 2, { 0xdd, 0x00 }, 2, 1, -1, 0, 0 },

    { "sixteen bytes", 16, { 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x2e, 0x0f, 0x1f, 0x84, 0x00, 0, 0, 0, 0 },
      0, 0, 0, 0, 0 },
    { "EVEX (62)", 11, { 0x62, 0xf1, 0xfd, 0x48, 0x6f, 0x05, D32, 0x00 }, 0, 0, 0, 0, 0 },
    { "XOP (8F, map 8)", 6, { 0x8f, 0xe8, 0x78, 0xc2, 0xc1, 0x01 }, 0, 0, 0, 0, 0 },
    { "3DNow! (0F 0F)", 4, { 0x0f, 0x0f, 0xc1, 0xb4 }, 0, 0, 0, 0, 0 },
    { "VEX map 4", 6, { 0xc4, 0xe4, 0x7d, 0x00, 0xc1, 0x00 }, 0, 0, 0, 0, 0 },
    { "VEX with no ModRM form (0F 05)", 3, { 0xc5, 0xf8, 0x05 }, 0, 0, 0, 0, 0 },
    { "VEX with a rel32 (0F 84)", 7, { 0xc5, 0xf8, 0x84, D32 }, 0, 0, 0, 0, 0 },
    { "push %es (06, not in 64-bit mode)", 1, { 0x06 }, 0, 0, 0, 0, 0 },
    { "into (CE)", 1, { 0xce }, 0, 0, 0, 0, 0 },
    { "int1 (F1)", 1, { 0xf1 }, 0, 0, 0, 0, 0 },
    { "ljmp ptr16:32 (EA)", 7, { 0xea, D32, 0x00, 0x00 }, 0, 0, 0, 0, 0 },
    { "lcall ptr16:32 (9A)", 7, { 0x9a, D32, 0x00, 0x00 }, 0, 0, 0, 0, 0 },
    { "mov %cr0 (0F 20: mod is ignored, not a RIP disp32)", 7, { 0x0f, 0x20, 0x05, D32 }, 0, 0, 0, 0, 0 },
    { "extrq $2, $1 (66 0F 78: two imm8)", 6, { 0x66, 0x0f, 0x78, 0xc0, 0x01, 0x02 }, 0, 0, 0, 0, 0 },
    { "xbegin rel16 (66 C7 F8)", 5, { 0x66, 0xc7, 0xf8, 0x01, 0x02 }, 0, 0, 0, 0, 0 },
    { "sixteen prefixes", 16, { 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
                                0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66 }, 0, 0, 0, 0, 0 },
    { "0F 04", 2, { 0x0f, 0x04 }, 0, 0, 0, 0, 0 },
    { "FF /7", 2, { 0xff, 0xff }, 0, 0, 0, 0, 0 },
    { "FE /2", 2, { 0xfe, 0x10 }, 0, 0, 0, 0, 0 },
    { "8F /1", 2, { 0x8f, 0x08 }, 0, 0, 0, 0, 0 },
    { "C7 /1", 6, { 0xc7, 0x08, D32 }, 0, 0, 0, 0, 0 },
    { "C6 /7 with memory", 3, { 0xc6, 0x38, 0x01 }, 0, 0, 0, 0, 0 },
    { "F6 /1, an alias of TEST", 3, { 0xf6, 0xc8, 0x01 }, 0, 0, 0, 0, 0 },
    { "F7 /1, an alias of TEST", 6, { 0xf7, 0xc8, D32 }, 0, 0, 0, 0, 0 },
    { "66 E8: Intel and AMD disagree on its length", 7, { 0x66, 0xe8, D32, 0x00 }, 0, 0, 0, 0, 0 },
    { "66 0F 84: likewise", 8, { 0x66, 0x0f, 0x84, D32, 0x00 }, 0, 0, 0, 0, 0 },
    { "a disp32 cut short", 6, { 0x48, 0x8d, 0x05, 0x11, 0x22, 0x33 }, 0, 0, 0, 0, 0 },
    { "an immediate cut short", 6, { 0x83, 0x3d, D32 }, 0, 0, 0, 0, 0 },
    { "a SIB cut short", 2, { 0x8b, 0x04 }, 0, 0, 0, 0, 0 },
    { "a ModRM cut short", 1, { 0x8b }, 0, 0, 0, 0, 0 },
    { "a prefix and nothing else", 1, { 0x66 }, 0, 0, 0, 0, 0 },
    { "0F and nothing else", 1, { 0x0f }, 0, 0, 0, 0, 0 },
    { "0F 38 and nothing else", 2, { 0x0f, 0x38 }, 0, 0, 0, 0, 0 },
    { "a VEX3 prefix cut short", 3, { 0xc4, 0xe1, 0x7c }, 0, 0, 0, 0, 0 },
    { "a VEX2 prefix cut short", 2, { 0xc5, 0xf8 }, 0, 0, 0, 0, 0 },
    { "8F cut short", 1, { 0x8f }, 0, 0, 0, 0, 0 },
};

/* A copy of `b` whose last byte ends a page, and the next page unmapped: a
 * decoder that reads past `n` bytes crashes the test instead of reading
 * whatever follows. */
static const uint8_t *at_page_end(const uint8_t *b, int n) {
    static uint8_t *pages;
    long pg = sysconf(_SC_PAGESIZE);
    if (!pages) {
        pages = (uint8_t *)mmap(NULL, 2 * (size_t)pg, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANON, -1, 0);
        if (pages == MAP_FAILED || mprotect(pages + pg, (size_t)pg, PROT_NONE) != 0) return NULL;
    }
    memcpy(pages + pg - n, b, (size_t)n);
    return pages + pg - n;
}

static sigjmp_buf guard_hit;
static void on_guard(int sig) { siglongjmp(guard_hit, sig); }

static void test_each_case(void) {
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        const struct xcase *c = &cases[i];
        const uint8_t *b = at_page_end(c->b, c->n);
        CHECK(b != NULL, "setup: a guard page");
        if (!b) return;
        if (sigsetjmp(guard_hit, 1)) {
            CHECK(0, "%s: read past avail", c->what);
            continue;
        }
        mx_insn in = { 99, 99, 99, 99, 99 };
        int ok = mx_decode(b, (size_t)c->n, &in);
        if (c->len == 0) {
            CHECK(!ok, "%s: decoded as %d bytes, want not decoded", c->what, in.len);
            continue;
        }
        CHECK(ok, "%s: not decoded", c->what);
        if (!ok) continue;
        CHECK(in.len == c->len && in.modrm == c->modrm && in.disp == c->disp &&
              in.displen == c->displen && in.immlen == c->immlen,
              "%s: len %d modrm %d disp %d/%d imm %d, want %d %d %d/%d %d", c->what,
              in.len, in.modrm, in.disp, in.displen, in.immlen,
              c->len, c->modrm, c->disp, c->displen, c->immlen);
    }
}

/* Bytes past the instruction do not change it. */
static void test_ignores_what_follows(void) {
    uint8_t b[8] = { 0x48, 0x8d, 0x05, 0x11, 0x22, 0x33, 0x44, 0xff };
    mx_insn in;
    CHECK(mx_decode(b, sizeof b, &in) == 1 && in.len == 7 && in.immlen == 0,
          "a lea followed by more bytes is 7 bytes, with no immediate");
}

/* An instruction is at most 15 bytes, so a run of prefixes is refused at the
 * fifteenth without a look at the sixteenth, however much `avail` allows. */
static void test_prefix_run_stops_at_fifteen(void) {
    static const uint8_t fifteen[15] = { 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66,
                                         0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x66 };
    const uint8_t *b = at_page_end(fifteen, 15);
    CHECK(b != NULL, "setup: a guard page");
    if (!b) return;
    if (sigsetjmp(guard_hit, 1)) {
        CHECK(0, "fifteen prefixes: read a sixteenth byte");
        return;
    }
    mx_insn in;
    CHECK(mx_decode(b, 64, &in) == 0, "fifteen prefixes: decoded as %d bytes", in.len);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    signal(SIGBUS, on_guard);
    signal(SIGSEGV, on_guard);
    test_each_case();
    test_ignores_what_follows();
    test_prefix_run_stops_at_fifteen();
    if (fails) { printf("x86len_test: %d FAILURE(S)\n", fails); return 1; }
    printf("x86len_test: all cases pass\n");
    return 0;
}
