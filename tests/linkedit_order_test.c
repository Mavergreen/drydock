/* tests/linkedit_order_test.c -- src/linkedit_order.h's mlo_check,
 * mlo_file_verdict, mlo_pack and mlo_changed, on tests/linkedit_fixture.h's
 * hand-built variants. Each variant's expected verdict is what 10.9's
 * codesign_allocate says of it (tests/codesign_order_test.sh checks that on
 * 10.9), so these run the same on every host. */
#include "image.h"
#include "linkedit_order.h"
#include "mach_compat.h"
#include "linkedit_fixture.h"

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

int main(void) {
    test_every_variant();
    test_every_finding_is_kept();
    if (fails == 0) printf("linkedit_order_test: all cases pass\n");
    return fails ? 1 : 0;
}
