/* tests/objc_meth_test.c -- hermetic tests for src/objc_meth.c, against the
 * hand-built image in tests/relmeth_fixture.h. */
#include "objc_meth.h"
#include "image.h"
#include "relmeth_fixture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

static uint8_t fx[RMF_SIZE];

static int walk(unsigned variant, mml_walk *w) {
    mi_image im;
    size_t n = rmf_build(fx, variant);
    if (mi_wrap(fx, n, &im) != 0) {
        printf("FAIL: fixture variant %#x does not wrap\n", variant);
        fails++;
        memset(w, 0, sizeof *w);
        return -99;
    }
    return mml_walk_image(&im, w);
}

static const mml_ref *nth_of(const mml_walk *w, int owner, uint32_t nth) {
    for (uint32_t i = 0; i < w->n; i++)
        if (w->refs[i].owner == owner && nth-- == 0) return &w->refs[i];
    return NULL;
}

static uint32_t count_of(const mml_walk *w, int owner) {
    uint32_t k = 0;
    for (uint32_t i = 0; i < w->n; i++) k += w->refs[i].owner == owner;
    return k;
}

static void test_class_names_its_relative_list(void) {
    mml_walk w;
    int rc = walk(RMF_PLAIN, &w);
    const mml_ref *r = nth_of(&w, MML_CLASS, 0);
    CHECK(rc == MML_OK, "plain: rc %d (%s)", rc, w.why);
    CHECK(r != NULL, "plain: no class ref");
    if (r) {
        CHECK(r->slot_off == RMF_CLASS_RO + 32, "class slot_off %#llx", (unsigned long long)r->slot_off);
        CHECK(r->list_va == RMF_VA(RMF_LIST_A), "class list_va %#llx", (unsigned long long)r->list_va);
        CHECK(r->list_off == RMF_LIST_A, "class list_off %#llx", (unsigned long long)r->list_off);
        CHECK(r->header == RMF_REL_HEADER, "class header %#x", r->header);
        CHECK(r->count == 2, "class count %u", r->count);
    }
    CHECK(w.owners[MML_CLASS] == 1, "classes walked: %u", w.owners[MML_CLASS]);
    mml_walk_free(&w);
    CHECK(w.refs == NULL && w.n == 0, "mml_walk_free left refs behind");
}

static void test_metaclass_is_reached_through_isa(void) {
    mml_walk w;
    int rc = walk(RMF_PLAIN, &w);
    const mml_ref *r = nth_of(&w, MML_METACLASS, 0);
    CHECK(rc == MML_OK, "plain: rc %d (%s)", rc, w.why);
    CHECK(r != NULL, "plain: no metaclass ref");
    if (r) {
        CHECK(r->slot_off == RMF_META_RO + 32, "meta slot_off %#llx", (unsigned long long)r->slot_off);
        CHECK(r->list_va == RMF_VA(RMF_LIST_B), "meta list_va %#llx", (unsigned long long)r->list_va);
        CHECK(r->count == 1, "meta count %u", r->count);
    }
    CHECK(w.owners[MML_METACLASS] == 1, "metaclasses walked: %u", w.owners[MML_METACLASS]);
    mml_walk_free(&w);
}

static void test_swift_tag_bits_do_not_hide_the_ro(void) {
    mml_walk w;
    int rc = walk(RMF_SWIFT, &w);
    const mml_ref *c = nth_of(&w, MML_CLASS, 0), *m = nth_of(&w, MML_METACLASS, 0);
    CHECK(rc == MML_OK, "swift: rc %d (%s)", rc, w.why);
    CHECK(c && c->list_va == RMF_VA(RMF_LIST_A), "swift: class list not found through a tagged data word");
    CHECK(m && m->list_va == RMF_VA(RMF_LIST_B), "swift: metaclass list not found through a tagged data word");
    mml_walk_free(&w);
}

static void test_a_class_listed_twice_is_walked_once(void) {
    mml_walk w;
    int rc = walk(RMF_NLCLS, &w);
    CHECK(rc == MML_OK, "nlcls: rc %d (%s)", rc, w.why);
    CHECK(w.owners[MML_CLASS] == 1, "nlcls: classes walked %u, want 1", w.owners[MML_CLASS]);
    CHECK(count_of(&w, MML_CLASS) == 1, "nlcls: %u class refs, want 1", count_of(&w, MML_CLASS));
    mml_walk_free(&w);
}

static void test_refusal(unsigned variant, int want_rc, const char *want_why, const char *label) {
    mml_walk w;
    int rc = walk(variant, &w);
    CHECK(rc == want_rc, "%s: rc %d, want %d (%s)", label, rc, want_rc, w.why);
    CHECK(strstr(w.why, want_why) != NULL, "%s: why '%s' lacks '%s'", label, w.why, want_why);
    CHECK(w.refs == NULL && w.n == 0, "%s: a refusal left refs behind", label);
    mml_walk_free(&w);
}

static void test_refusals(void) {
    test_refusal(RMF_CHAINED,  MML_CHAINED,   "fixups set classic", "chained");
    test_refusal(RMF_DIRECT,   MML_MALFORMED, "0xc000000c",         "direct selectors");
    test_refusal(RMF_BADENT,   MML_MALFORMED, "0x80000010",         "relative entsize 16");
    test_refusal(RMF_LISTLIST, MML_MALFORMED, "low bits",           "list of lists");
    test_refusal(RMF_OOB,      MML_MALFORMED, "runs past",          "list past its segment");
}

int main(void) {
    test_class_names_its_relative_list();
    test_metaclass_is_reached_through_isa();
    test_swift_tag_bits_do_not_hide_the_ro();
    test_a_class_listed_twice_is_walked_once();
    test_refusals();

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("objc_meth_test: 0 failure(s)\n");
    return 0;
}
