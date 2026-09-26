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

/* ---- the pass ---- */

static int pack(uint8_t **buf, size_t *n, mlo_pack_report *r, char *why) {
    return mlo_pack(buf, n, r, why, 256);
}

/* Every variant whose only faults are where its pieces lie comes out in
 * order, re-signing correctly, every piece's bytes intact. */
static void test_the_pass_puts_each_variant_in_order(void) {
    static const char *const fixable[] = {
        "bind-first", "gap-before-rebase", "export-inside", "gap-after-export",
        "symtab-before-fstarts", "dic-stale", "gap-before-symtab", "strtab-first",
        "strtab-past-rounding", "sig-off-16", "sig-late", "tail-after-sig", "tail-after-strtab",
        "hole-16", "hole-16-unsigned", "stale-empty-rebase", "hole-absorbed", "export-last",
        "drs-empty-stale", "weak-lazy-empty-export", "bind-first-static", "no-dysymtab-hole",
        "no-dysymtab-unsigned-misaligned", "no-dysymtab-unsigned-drs8", "no-dysymtab-drs8",
        "bind-first-dep" };
    /* These have no canonical twin: a piece is empty or missing, or there is
     * no LC_DYSYMTAB. */
    static const char *const unlike[] = { "stale-empty-rebase", "strtab-past-rounding",
        "drs-empty-stale", "weak-lazy-empty-export" };
    for (size_t k = 0; k < sizeof fixable / sizeof fixable[0]; k++) {
        const lkf_variant *w = variant(fixable[k]);
        uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
        size_t n = lkf_make(buf, w);
        uint8_t *before = (uint8_t *)malloc(n);
        memcpy(before, buf, n);
        mlo_pack_report r;
        char why[256] = "";
        int rc = pack(&buf, &n, &r, why);
        CHECK(rc == MLO_PACKED, "%s: packed (got %d: %s)", w->name, rc, why);
        mlo_verdict v;
        check(buf, n, &v);
        CHECK(v.refusal < 0 && !v.corrupting, "%s: in order after the pass (%s)", w->name,
              v.refusal >= 0 ? v.f[v.refusal].text : "corrupting");
        /* and in the canonical layout, byte for byte */
        static uint8_t canon[LKF_CAP];
        size_t cn = lkf_build(canon, (w->opts & LKF_NOSIG) ?
                              "rebase bind weak lazy export fstarts dic drs symtab indirect strtab" :
                              LKF_CANON, w->opts);
        int twin = !(w->opts & LKF_NODYSYMTAB);
        for (size_t j = 0; j < sizeof unlike / sizeof unlike[0]; j++)
            if (strcmp(w->name, unlike[j]) == 0) twin = 0;
        if (twin)
            CHECK(n == cn && memcmp(buf, canon, n) == 0, "%s: the canonical bytes", w->name);
        /* and every piece's bytes, wherever the pass put them, are the
         * bytes it started with */
        for (int p = 0; p < LKF_NPIECES; p++) {
            uint32_t *offB, *sizeB, scaleB, *offA, *sizeA, scaleA;
            lkf_fields(before, p, &offB, &sizeB, &scaleB);
            lkf_fields(buf, p, &offA, &sizeA, &scaleA);
            if (!offB || !offA || *sizeB == 0) continue;
            uint32_t bytes = *sizeB * scaleB;
            CHECK(*sizeA * scaleA == bytes && memcmp(before + *offB, buf + *offA, bytes) == 0,
                  "%s: %s's bytes intact", w->name, lkf_names[p]);
        }
        free(before);
        free(buf);
    }
}

static void test_the_pass_leaves_an_ordered_image_alone(void) {
    static const char *const ordered[] = { "canonical", "canonical-unsigned", "strtab-at-rounding" };
    for (size_t k = 0; k < sizeof ordered / sizeof ordered[0]; k++) {
        uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
        size_t n = lkf_make(buf, variant(ordered[k]));
        uint8_t *was = buf;
        mlo_pack_report r;
        char why[256] = "";
        int rc = pack(&buf, &n, &r, why);
        CHECK(rc == MLO_UNCHANGED && buf == was, "%s: unchanged (got %d: %s)", ordered[k], rc, why);
        free(buf);
    }
    /* the repo's own fixture, which tests/EXPECTED's digest depends on */
    mi_image im;
    if (mi_open("tests/fixture.macho", &im) != 0) {
        printf("FAIL: tests/fixture.macho does not open (run from the source directory)\n");
        fails++;
        return;
    }
    size_t n = im.size;
    uint8_t *buf = mi_release(&im);
    mlo_pack_report r;
    char why[256] = "";
    int rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_UNCHANGED, "tests/fixture.macho: unchanged (got %d: %s)", rc, why);
    free(buf);
}

/* A zero-size piece keeps a zero offset, and a stale one is set where
 * ld64 puts it. */
static void test_the_pass_places_empty_pieces(void) {
    uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
    size_t n = lkf_make(buf, variant("dic-stale"));
    mlo_pack_report r;
    char why[256];
    int rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_PACKED, "dic-stale: packed (got %d: %s)", rc, why);
    struct linkedit_data_command *dic = lkf_led(buf, LKF_LC_DIC);
    struct linkedit_data_command *drs = lkf_led(buf, LKF_LC_DRS);
    CHECK(dic->dataoff == drs->dataoff, "an empty data in code at the running offset (0x%x, 0x%x)",
          dic->dataoff, drs->dataoff);
    free(buf);
    buf = (uint8_t *)malloc(LKF_CAP);
    n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs symtab indirect strtab @16 sig", 0);
    lkf_led(buf, LKF_LC_DIC)->dataoff = 0;
    rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_PACKED, "dic-at-0: packed (got %d: %s)", rc, why);
    CHECK(lkf_led(buf, LKF_LC_DIC)->dataoff == 0, "an empty data in code at 0 stays at 0");
    free(buf);
    buf = (uint8_t *)malloc(LKF_CAP);
    n = lkf_make(buf, variant("stale-empty-rebase"));
    rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_PACKED, "stale-empty-rebase: packed (got %d: %s)", rc, why);
    CHECK(lkf_di(buf)->rebase_off == 0 && lkf_di(buf)->bind_off == LKF_LE,
          "a stale empty rebase stream gets offset 0 (rebase 0x%x, bind 0x%x)",
          lkf_di(buf)->rebase_off, lkf_di(buf)->bind_off);
    free(buf);
}

/* An emptied signature keeps the rounded running offset, like DRS and the
 * linker hints -- not offset 0: codesign_allocate's dyld_order checks a
 * signature's position whether or not it has bytes. */
static void test_the_pass_places_an_empty_signature(void) {
    uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
    size_t n = lkf_make(buf, variant("canonical"));
    struct linkedit_data_command *sig = lkf_led(buf, LKF_LC_SIG);
    uint32_t before_off = sig->dataoff;
    sig->datasize = 0;
    mlo_pack_report r;
    char why[256] = "";
    int rc = pack(&buf, &n, &r, why);
    sig = lkf_led(buf, LKF_LC_SIG);
    CHECK(rc == MLO_PACKED && sig->dataoff == before_off,
          "an emptied signature: packed at 0x%x (got %d: %s, dataoff 0x%x)",
          before_off, rc, why, sig->dataoff);
    free(buf);
}

/* The 8-rounding after an odd indirect table stays where the input had it,
 * and the report counts what was dropped. */
static void test_the_pass_keeps_the_rounding(void) {
    uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
    size_t n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs symtab indirect @8 "
                         "strtab @16 sig", 0);
    mlo_pack_report r;
    char why[256];
    int rc = pack(&buf, &n, &r, why);
    struct symtab_command *st = lkf_st(buf);
    struct dysymtab_command *dy = lkf_dy(buf);
    uint32_t ind_end = dy->indirectsymoff + dy->nindirectsyms * 4;
    CHECK(rc == MLO_PACKED && st->stroff == ((ind_end + 7) & ~7u) && st->stroff != ind_end,
          "the string table stays at the 8-rounding (0x%x after 0x%x)", st->stroff, ind_end);
    free(buf);
    buf = (uint8_t *)malloc(LKF_CAP);
    n = lkf_make(buf, variant("hole-16"));
    rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_PACKED && r.before == 0x110 && r.after == 0x100 && r.dropped == 0x14,
          "the report: 0x%llx -> 0x%llx, 0x%llx dropped", (unsigned long long)r.before,
          (unsigned long long)r.after, (unsigned long long)r.dropped);
    free(buf);
}

/* Each thing the pass cannot account for, and the image left alone. */
static void test_the_pass_declines(void) {
    static const struct { const char *variant, *why; } no[] = {
        { "note", "may name a range of the file the pass does not know" },
        { "fvmfile", "may name a range of the file the pass does not know" },
        { "two-fstarts", "more than one of the function starts" },
        { "fstarts-dataoff-0", "the function starts lies outside __LINKEDIT" },
        { "no-rebase-no-bind", "which codesign_allocate cannot lay out" },
        { "nsyms-0", "a string table but no symbols" },
        { "no-dysymtab-linkedit-short-hole", "__LINKEDIT does not end the file" },
    };
    for (size_t k = 0; k < sizeof no / sizeof no[0]; k++) {
        uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
        size_t n = lkf_make(buf, variant(no[k].variant));
        uint8_t *copy = (uint8_t *)malloc(n);
        memcpy(copy, buf, n);
        uint8_t *was = buf;
        size_t n0 = n;
        mlo_pack_report r;
        char why[256] = "";
        int rc = pack(&buf, &n, &r, why);
        CHECK(rc == MLO_DECLINED && strstr(why, no[k].why) && buf == was && n == n0 &&
              memcmp(buf, copy, n) == 0, "%s: declined (got %d: %s)", no[k].variant, rc, why);
        free(copy);
        free(buf);
    }
    /* and the layout checks, on an image made to fail each */
    struct { const char *what, *why; } lay[] = {
        { "a piece outside __LINKEDIT", "lies outside __LINKEDIT" },
        { "overlapping pieces", "overlaps" },
        { "__LINKEDIT not ending the file", "__LINKEDIT does not end the file" },
        { "a section in __LINKEDIT", "lies in __LINKEDIT" },
        { "a section with relocations", "has relocation entries" },
        { "__LINKEDIT's vmsize would overlap", "would overlap __DATA" },
        { "a signed __LINKEDIT not 16-aligned", "is not a multiple of 16" },
        { "load commands past their size", "not a readable 64-bit Mach-O" },
        { "an unsigned __LINKEDIT not 16-aligned", "even in codesign_allocate's order" },
    };
    for (size_t k = 0; k < sizeof lay / sizeof lay[0]; k++) {
        uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
        size_t n = lkf_make(buf, variant("bind-first"));
        struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
        struct segment_command_64 *da = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_DATA);
        struct section_64 *data = (struct section_64 *)(da + 1);
        switch (k) {
        case 0: lkf_led(buf, LKF_LC_DRS)->dataoff = 0x1100; break;
        case 1: lkf_led(buf, LKF_LC_DRS)->dataoff = lkf_st(buf)->symoff; break;
        case 2: le->filesize -= 16; break;
        case 3: data->offset = LKF_LE + 0x40; break;
        case 4: data->reloff = LKF_LE; data->nreloc = 1; break;
        case 5: {
            /* a bigger pack than the page, and __DATA right after it in vm */
            uint8_t *big = (uint8_t *)realloc(buf, LKF_CAP + 0x2000);
            buf = big;
            n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs symtab indirect "
                          "strtab:5000 @16 sig", 0);
            le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
            da = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_DATA);
            le->vmsize = 0x1000;
            da->vmaddr = le->vmaddr + 0x1000;
            break;
        }
        case 6:   /* a lie, but the pass reads only this */
            le->fileoff -= 8;
            le->filesize += 8;
            break;
        case 7: ((struct mach_header_64 *)buf)->sizeofcmds = 0x7fffffff; break;
        case 8:   /* the same lie, where a signature the tool adds would land wrong */
            n = lkf_make(buf, variant("canonical-unsigned"));
            le->fileoff -= 8;
            le->filesize += 8;
            da->filesize -= 8;
            break;
        }
        uint8_t *copy = (uint8_t *)malloc(n);
        memcpy(copy, buf, n);
        uint8_t *was = buf;
        size_t n0 = n;
        mlo_pack_report r;
        char why[256] = "";
        int rc = pack(&buf, &n, &r, why);
        CHECK(rc == MLO_DECLINED && strstr(why, lay[k].why) && buf == was && n == n0 &&
              memcmp(buf, copy, n) == 0, "%s: declined (got %d: %s)", lay[k].what, rc, why);
        free(copy);
        free(buf);
    }
}

/* __LINKEDIT's fileoff inside the load commands: the pass must not read or
 * write past the packed image it allocates for its layout. */
static void test_the_pass_declines_load_commands_in_linkedit(void) {
    uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
    size_t n = lkf_build(buf, "rebase symtab strtab", LKF_NOSIG | LKF_NODYSYMTAB);
    struct segment_command_64 *tx = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_TEXT);
    struct segment_command_64 *da = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_DATA);
    struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    struct section_64 *s = (struct section_64 *)(tx + 1);
    for (uint32_t j = 0; j < tx->nsects; j++) s[j].offset = 0;
    s = (struct section_64 *)(da + 1);
    for (uint32_t j = 0; j < da->nsects; j++) s[j].offset = 0;
    for (int i = LKF_LC_FSTARTS; i <= LKF_LC_DRS; i++) {
        lkf_led(buf, i)->dataoff = 0;
        lkf_led(buf, i)->datasize = 0;
    }
    struct dyld_info_command *di = lkf_di(buf);
    di->bind_off = di->bind_size = di->weak_bind_off = di->weak_bind_size = 0;
    di->lazy_bind_off = di->lazy_bind_size = di->export_off = di->export_size = 0;
    tx->filesize = 0;
    da->filesize = 0;
    le->filesize = n - 0x28;
    le->fileoff = 0x28;
    uint8_t *copy = (uint8_t *)malloc(n);
    memcpy(copy, buf, n);
    uint8_t *was = buf;
    size_t n0 = n;
    mlo_pack_report r;
    char why[256] = "";
    int rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_DECLINED && strstr(why, "the load commands lie in __LINKEDIT") &&
          buf == was && n == n0 && memcmp(buf, copy, n) == 0,
          "load commands in __LINKEDIT: declined (got %d: %s)", rc, why);
    free(copy);
    free(buf);
}

/* Fuzz-found: no layout survives a signed, static LC_DYSYMTAB image with an
 * empty string table, so the pass must decline it, not fail a postcondition. */
static void test_the_pass_declines_empty_strtab_outside_dyldlink(void) {
    uint8_t *buf = (uint8_t *)malloc(LKF_CAP);
    size_t n = lkf_build(buf, "rebase bind weak lazy export +4 fstarts dic drs symtab +16 "
                         "indirect:8 strtab:0 sig", LKF_EXECUTE | LKF_STATIC);
    uint8_t *copy = (uint8_t *)malloc(n);
    memcpy(copy, buf, n);
    mlo_verdict v;
    check(buf, n, &v);
    CHECK(!v.corrupting, "empty-strtab static signed, not stale: not corrupting as given");
    mlo_pack_report r;
    char why[256] = "";
    int rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_DECLINED && strstr(why, "string table") && memcmp(buf, copy, n) == 0,
          "empty-strtab static signed, not stale: declined (got %d: %s)", rc, why);
    free(copy);
    free(buf);

    /* Corrupting as given (a stale DRS size): still a decline, not a failure. */
    buf = (uint8_t *)malloc(LKF_CAP);
    n = lkf_build(buf, "rebase bind weak lazy export +4 fstarts dic drs:12 symtab indirect "
                  "strtab:0 sig", LKF_EXECUTE | LKF_STATIC);
    check(buf, n, &v);
    CHECK(v.corrupting, "empty-strtab static signed, stale drs: corrupting as given");
    why[0] = 0;
    rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_DECLINED && strstr(why, "string table"),
          "empty-strtab static signed, stale drs: declined, not failed (got %d: %s)", rc, why);
    free(buf);

    /* A zero-count indirect table hits a different symbol_string_at_end
     * message for the same defect; it must decline too. */
    buf = (uint8_t *)malloc(LKF_CAP);
    n = lkf_build(buf, "rebase bind +4 weak lazy export:12 fstarts:4 dic drs symtab @16 "
                  "indirect:0 strtab:0 sig", LKF_EXECUTE | LKF_STATIC);
    why[0] = 0;
    rc = pack(&buf, &n, &r, why);
    CHECK(rc == MLO_DECLINED && strstr(why, "string table"),
          "empty-strtab static signed, zero indirect: declined (got %d: %s)", rc, why);
    free(buf);
}

/* __LINKEDIT's vmsize grows to cover a longer pack, rounded to the page;
 * and an empty piece's offset, even one past the new end, becomes 0. */
static void test_the_pass_resizes_and_zeroes(void) {
    uint8_t *buf = (uint8_t *)malloc(LKF_CAP + 0x2000);
    size_t n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs symtab indirect "
                         "strtab:5000 @16 sig", 0);
    struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    le->vmsize = 0x1000;
    lkf_dy(buf)->locreloff = 0x9000;   /* no entries, and past the end of the file */
    mlo_pack_report r;
    char why[256] = "";
    int rc = pack(&buf, &n, &r, why);
    le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    CHECK(rc == MLO_PACKED && le->vmsize == 0x2000 && le->filesize > 0x1000,
          "a longer pack: vmsize 0x%llx for filesize 0x%llx (got %d: %s)",
          (unsigned long long)le->vmsize, (unsigned long long)le->filesize, rc, why);
    CHECK(lkf_dy(buf)->locreloff == 0, "an empty table's stale offset becomes 0 (got 0x%x)",
          lkf_dy(buf)->locreloff);
    free(buf);
    /* arm64's page is 0x4000, not x86_64's 0x1000. */
    buf = (uint8_t *)malloc(LKF_CAP + 0x2000);
    n = lkf_build(buf, "bind rebase weak lazy export fstarts dic drs symtab indirect "
                  "strtab:5000 @16 sig", 0);
    ((struct mach_header_64 *)buf)->cputype = CPU_TYPE_ARM64;
    le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    le->vmsize = 0x1000;
    rc = pack(&buf, &n, &r, why);
    le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    CHECK(rc == MLO_PACKED && le->vmsize == 0x4000 && le->filesize > 0x1000,
          "arm64's page: vmsize 0x%llx for filesize 0x%llx (got %d: %s)",
          (unsigned long long)le->vmsize, (unsigned long long)le->filesize, rc, why);
    free(buf);
}

/* ---- the observed change ---- */

static void test_what_counts_as_a_change(void) {
    static uint8_t a[LKF_CAP], b[LKF_CAP];
    size_t na = lkf_make(a, variant("canonical"));
    memcpy(b, a, na);
    CHECK(!mlo_changed(a, na, b, na), "the same image: no change");
    ((struct dylib_command *)lkf_lc(b, LKF_LC_ID))->dylib.current_version = 0x10000;
    CHECK(!mlo_changed(a, na, b, na), "a header-only edit: no change");
    memcpy(b, a, na);
    b[lkf_di(b)->bind_off] ^= 1;
    CHECK(mlo_changed(a, na, b, na), "a byte of the bind opcodes: a change");
    memcpy(b, a, na);
    lkf_st(b)->stroff += 1;
    CHECK(mlo_changed(a, na, b, na), "an offset: a change");
    memcpy(b, a, na);
    lkf_patch(b, LKF_LC_SIG, LC_UUID);
    CHECK(mlo_changed(a, na, b, na), "a piece gone: a change");
    memcpy(b, a, na);
    ((struct segment_command_64 *)lkf_lc(b, LKF_LC_LINKEDIT))->filesize += 16;
    CHECK(mlo_changed(a, na, b, na + 16), "__LINKEDIT's filesize: a change");
    /* A side that is not a readable image: the pass must be asked, and it
     * declines; two such sides say nothing. */
    memcpy(b, a, na);
    ((struct mach_header_64 *)b)->sizeofcmds = 0x7fffffff;
    CHECK(mlo_changed(a, na, b, na) && mlo_changed(b, na, a, na), "one side not an image: a change");
    CHECK(!mlo_changed(b, na, b, na), "neither side an image: no change");
}

int main(void) {
    test_every_variant();
    test_every_finding_is_kept();
    test_the_fileoff_note();
    test_corrupting_behind_an_unknown_command();
    test_the_simulation_follows_the_branches();
    test_the_file_verdict();
    test_the_pass_puts_each_variant_in_order();
    test_the_pass_leaves_an_ordered_image_alone();
    test_the_pass_places_empty_pieces();
    test_the_pass_places_an_empty_signature();
    test_the_pass_keeps_the_rounding();
    test_the_pass_declines();
    test_the_pass_declines_load_commands_in_linkedit();
    test_the_pass_declines_empty_strtab_outside_dyldlink();
    test_the_pass_resizes_and_zeroes();
    test_what_counts_as_a_change();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
    return fails ? 1 : 0;
}
