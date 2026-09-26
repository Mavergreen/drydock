/* tests/linkedit_order_test.c -- src/linkedit_order.h's mlo_check,
 * mlo_file_verdict, mlo_pack and mlo_changed, on tests/linkedit_fixture.h's
 * hand-built variants. Each variant's expected verdict is what 10.9's
 * codesign_allocate says of it (tests/codesign_order_test.sh checks that on
 * 10.9), so these run the same on every host. */
#include "image.h"
#include "linkedit_order.h"
#include "mach_compat.h"
#include "linkedit_fixture.h"

#include <mach-o/fat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

static const lkf_variant *variant(const char *name) {
    for (size_t k = 0; k < LKF_NVARIANTS; k++)
        if (strcmp(lkf_variants[k].name, name) == 0) return &lkf_variants[k];
    printf("FAIL: no variant %s\n", name);
    exit(1);
}

static void check(uint8_t *buf, size_t n, mlo_verdict *v) {
    mi_image im;
    if (mi_wrap(buf, n, &im) != 0) { printf("FAIL: the image does not wrap\n"); exit(1); }
    mlo_check(&im, v);
}

static int has(const mlo_verdict *v, int kind, const char *text) {
    for (int k = 0; k < v->n; k++)
        if (v->f[k].kind == kind && strstr(v->f[k].text, text)) return 1;
    return 0;
}

/* Every variant: the refusal 10.9's tool prints, and whether it re-signs
 * corrupt. */
static void test_every_variant(void) {
    static uint8_t buf[LKF_CAP];
    for (size_t k = 0; k < LKF_NVARIANTS; k++) {
        const lkf_variant *w = &lkf_variants[k];
        size_t n = lkf_make(buf, w);
        CHECK(n != 0, "%s: builds", w->name);
        mlo_verdict v;
        check(buf, n, &v);
        const char *got = v.refusal >= 0 ? v.f[v.refusal].text : NULL;
        CHECK((got == NULL) == (w->tool == NULL) && (!got || strcmp(got, w->tool) == 0),
              "%s: refusal is '%s', want '%s'", w->name, got ? got : "(none)",
              w->tool ? w->tool : "(none)");
        CHECK(v.corrupting == w->corrupting, "%s: corrupting is %d, want %d", w->name,
              v.corrupting, w->corrupting);
    }
}

/* Each rule is judged on its own: two faults, two findings. */
static void test_every_finding_is_kept(void) {
    static uint8_t buf[LKF_CAP];
    size_t n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs +8 symtab indirect "
                         "strtab +8 sig", 0);
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(has(&v, MLO_REFUSES, "(dyld_info out of place)") &&
          has(&v, MLO_REFUSES, "(symbol table out of place)") &&
          has(&v, MLO_REFUSES, "(code signature data out of place)"),
          "two faults: all three findings are kept (got %d)", v.n);
    CHECK(v.n == 3, "two faults: each piece after one out of place is judged from where that one "
          "is, so there are exactly three findings (got %d)", v.n);
    CHECK(v.refusal == 0 && strstr(v.f[0].text, "dyld_info"),
          "two faults: the refusal is the first, in the tool's order");
}

/* A __LINKEDIT whose file offset is not a multiple of 16 is noted. */
static void test_the_fileoff_note(void) {
    static uint8_t buf[LKF_CAP];
    size_t n = lkf_make(buf, variant("canonical-unsigned"));
    struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(!has(&v, MLO_NOTE, "multiple of 16"), "fileoff 0x2000: no note");
    le->fileoff = LKF_LE - 8;   /* a lie, but the note reads only this */
    le->filesize += 8;
    check(buf, n, &v);
    CHECK(has(&v, MLO_NOTE, "multiple of 16"), "fileoff 0x1ff8: noted");
}

/* An unknown command does not hide a hole a newer tool would re-sign
 * corrupt. */
static void test_corrupting_behind_an_unknown_command(void) {
    static uint8_t buf[LKF_CAP];
    size_t n = lkf_build(buf, "rebase +16 bind weak lazy export " LKF_TAIL, LKF_EXECUTE);
    lkf_uuid_to_bv(buf, &n);
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(v.refusal >= 0 && strstr(v.f[v.refusal].text, "unknown load command 3") && v.corrupting,
          "an unknown command and a hole: refused on 10.9, and corrupting");
}

/* The writer counts the string table only with symbols; the review's
 * no-dysymtab image writes only the symbol and string tables. */
static void test_the_simulation_follows_the_branches(void) {
    static uint8_t buf[LKF_CAP];
    size_t n = lkf_make(buf, variant("nsyms-0"));
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(has(&v, MLO_CORRUPTS, "would not survive"), "nsyms 0: the pieces would move");
    n = lkf_make(buf, variant("no-dysymtab-hole"));
    check(buf, n, &v);
    CHECK(v.n == 0, "no dysymtab, a hole: nothing found (got %d: %s)", v.n, v.n ? v.f[0].text : "");
}

/* The whole file: thin, and fat with a bad slice. */
static void test_the_file_verdict(void) {
    static uint8_t a[LKF_CAP], b[LKF_CAP];
    char refusal[256], corrupt[512];
    size_t na = lkf_make(a, variant("canonical"));
    int rc = mlo_file_verdict(a, na, refusal, sizeof refusal, corrupt, sizeof corrupt);
    CHECK(rc == 0 && strcmp(refusal, "ok") == 0 && !corrupt[0], "thin canonical: ok (got %d, %s)",
          rc, refusal);
    size_t nb = lkf_make(b, variant("note"));
    size_t off2 = 0x4000, total = off2 + nb;
    uint8_t *fat = (uint8_t *)calloc(1, total);
    struct fat_header *fh = (struct fat_header *)fat;
    struct fat_arch *fa = (struct fat_arch *)(fh + 1);
    fh->magic = OSSwapHostToBigInt32(FAT_MAGIC);
    fh->nfat_arch = OSSwapHostToBigInt32(2);
    fa[0].cputype = OSSwapHostToBigInt32(CPU_TYPE_X86_64);
    fa[0].cpusubtype = OSSwapHostToBigInt32(CPU_SUBTYPE_X86_64_ALL);
    fa[0].offset = OSSwapHostToBigInt32(0x1000);
    fa[0].size = OSSwapHostToBigInt32((uint32_t)na);
    fa[0].align = OSSwapHostToBigInt32(12);
    fa[1].cputype = OSSwapHostToBigInt32(CPU_TYPE_X86_64);
    fa[1].cpusubtype = OSSwapHostToBigInt32(CPU_SUBTYPE_X86_64_H);
    fa[1].offset = OSSwapHostToBigInt32((uint32_t)off2);
    fa[1].size = OSSwapHostToBigInt32((uint32_t)nb);
    fa[1].align = OSSwapHostToBigInt32(12);
    memcpy(fat + 0x1000, a, na);
    memcpy(fat + off2, b, nb);
    ((struct mach_header_64 *)(fat + off2))->cpusubtype = CPU_SUBTYPE_X86_64_H;
    rc = mlo_file_verdict(fat, total, refusal, sizeof refusal, corrupt, sizeof corrupt);
    CHECK(rc == 1 && strcmp(refusal, "slice x86_64h: malformed object (unknown load command 8)") == 0,
          "fat: the other slice's refusal (got %d, %s)", rc, refusal);
    /* and a corrupting slice */
    size_t nc = lkf_make(b, variant("hole-16"));
    memcpy(fat + off2, b, nc);
    fa[1].size = OSSwapHostToBigInt32((uint32_t)nc);
    ((struct mach_header_64 *)(fat + off2))->cpusubtype = CPU_SUBTYPE_X86_64_H;
    rc = mlo_file_verdict(fat, off2 + nc, refusal, sizeof refusal, corrupt, sizeof corrupt);
    CHECK(rc == 2 && strncmp(corrupt, "slice x86_64h: ", 15) == 0 && strstr(corrupt, "would not survive"),
          "fat: a corrupting slice (got %d, %s)", rc, corrupt);
    free(fat);
}

int main(void) {
    test_every_variant();
    test_every_finding_is_kept();
    test_the_fileoff_note();
    test_corrupting_behind_an_unknown_command();
    test_the_simulation_follows_the_branches();
    test_the_file_verdict();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
    return fails ? 1 : 0;
}
