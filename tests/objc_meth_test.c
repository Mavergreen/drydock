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

static void test_a_slot_two_classes_share_is_recorded_once(void) {
    mml_walk w;
    int rc = walk(RMF_SHAREDRO, &w);
    CHECK(rc == MML_OK, "sharedro: rc %d (%s)", rc, w.why);
    CHECK(count_of(&w, MML_CLASS) == 1, "sharedro: %u class refs, want 1", count_of(&w, MML_CLASS));
    CHECK(w.owners[MML_CLASS] == 2 && w.owners[MML_METACLASS] == 1,
          "sharedro: %u classes, %u metaclasses walked; want 2, 1",
          w.owners[MML_CLASS], w.owners[MML_METACLASS]);
    CHECK(w.n == 4, "sharedro: %u slots, want 4", w.n);
    mml_walk_free(&w);
}

static void test_refusal(unsigned variant, int want_rc, const char *want_why, const char *label) {
    mml_walk w;
    int rc = walk(variant, &w);
    CHECK(rc == want_rc, "%s: rc %d, want %d (%s)", label, rc, want_rc, w.why);
    CHECK(strstr(w.why, want_why) != NULL, "%s: why '%s' lacks '%s'", label, w.why, want_why);
    CHECK(w.refs == NULL && w.n == 0, "%s: a refusal left refs behind", label);
    CHECK(w.relative == 0 && w.absolute == 0, "%s: a refusal left %u relative, %u absolute",
          label, w.relative, w.absolute);
    for (int k = 0; k < MML_NOWNERS; k++)
        CHECK(w.owners[k] == 0, "%s: a refusal left owners[%d] = %u", label, k, w.owners[k]);
    mml_walk_free(&w);
}

static void test_refusals(void) {
    test_refusal(RMF_CHAINED,  MML_CHAINED,   "fixups set classic", "chained");
    test_refusal(RMF_DIRECT,   MML_MALFORMED, "0xc000000c",         "direct selectors");
    test_refusal(RMF_BADENT,   MML_MALFORMED, "0x80000010",         "relative entsize 16");
    test_refusal(RMF_LISTLIST, MML_MALFORMED, "low bits",           "list of lists");
    test_refusal(RMF_OOB,      MML_MALFORMED, "runs past",          "list past its segment");
    test_refusal(RMF_CATPAST,  MML_MALFORMED, "category record",    "category past its segment");
    test_refusal(RMF_PROTOPAST, MML_MALFORMED, "protocol record",   "protocol past its segment");
    test_refusal(RMF_METAOUT,  MML_MALFORMED, "the metaclass record", "metaclass outside the file");
}

static void test_category_and_protocol_lists(void) {
    mml_walk w;
    int rc = walk(RMF_PLAIN, &w);
    const mml_ref *c = nth_of(&w, MML_CATEGORY, 0), *p = nth_of(&w, MML_PROTOCOL, 0);
    CHECK(rc == MML_OK, "plain: rc %d (%s)", rc, w.why);
    CHECK(c && c->slot_off == RMF_CATEGORY + 16 && c->list_va == RMF_VA(RMF_LIST_C),
          "plain: category instanceMethods not found");
    CHECK(p && p->slot_off == RMF_PROTOCOL + 24 && p->list_va == RMF_VA(RMF_LIST_D),
          "plain: protocol instanceMethods not found");
    CHECK(w.owners[MML_CATEGORY] == 1, "categories walked: %u", w.owners[MML_CATEGORY]);
    CHECK(w.owners[MML_PROTOCOL] == 1, "protocols walked: %u", w.owners[MML_PROTOCOL]);
    CHECK(w.n == 4, "plain: %u slots, want 4", w.n);
    CHECK(w.relative == 4 && w.absolute == 0, "plain: %u relative, %u absolute; want 4, 0",
          w.relative, w.absolute);
    mml_walk_free(&w);
}

static void test_a_shared_list_counts_once(void) {
    mml_walk w;
    int rc = walk(RMF_SHARED, &w);
    const mml_ref *c = nth_of(&w, MML_CATEGORY, 0);
    CHECK(rc == MML_OK, "shared: rc %d (%s)", rc, w.why);
    CHECK(w.n == 4, "shared: %u slots, want 4 -- every slot is kept", w.n);
    CHECK(c && c->list_va == RMF_VA(RMF_LIST_A), "shared: the category's slot does not name list A");
    CHECK(w.relative == 3, "shared: %u relative lists, want 3", w.relative);
    mml_walk_free(&w);
}

static void test_absolute_lists_are_counted_apart(void) {
    mml_walk w;
    int rc = walk(RMF_ABSCAT, &w);
    const mml_ref *c = nth_of(&w, MML_CATEGORY, 0);
    CHECK(rc == MML_OK, "abscat: rc %d (%s)", rc, w.why);
    CHECK(c && c->header == RMF_ABS_HEADER && c->count == 1, "abscat: the absolute list was misread");
    CHECK(w.relative == 3 && w.absolute == 1, "abscat: %u relative, %u absolute; want 3, 1",
          w.relative, w.absolute);
    mml_walk_free(&w);
}

static void check_slot(const mml_walk *w, int owner, uint32_t nth, uint64_t slot_off,
                       uint32_t list, const char *label) {
    const mml_ref *r = nth_of(w, owner, nth);
    CHECK(r != NULL, "allslots: no %s", label);
    if (r)
        CHECK(r->slot_off == slot_off && r->list_va == RMF_VA(list),
              "allslots: %s at %#llx names %#llx; want %#llx naming %#llx", label,
              (unsigned long long)r->slot_off, (unsigned long long)r->list_va,
              (unsigned long long)slot_off, (unsigned long long)RMF_VA(list));
}

static void test_every_category_and_protocol_slot_is_read(void) {
    mml_walk w;
    int rc = walk(RMF_ALLSLOTS, &w);
    CHECK(rc == MML_OK, "allslots: rc %d (%s)", rc, w.why);
    check_slot(&w, MML_CATEGORY, 0, RMF_CATEGORY + 16,  RMF_LIST_C, "category instanceMethods");
    check_slot(&w, MML_CATEGORY, 1, RMF_CATEGORY + 24,  RMF_LIST_B, "category classMethods");
    check_slot(&w, MML_CATEGORY, 2, RMF_CATEGORY2 + 16, RMF_LIST_D, "nlcatlist-only category");
    check_slot(&w, MML_PROTOCOL, 0, RMF_PROTOCOL + 24,  RMF_LIST_D, "protocol instanceMethods");
    check_slot(&w, MML_PROTOCOL, 1, RMF_PROTOCOL + 32,  RMF_LIST_A, "protocol classMethods");
    check_slot(&w, MML_PROTOCOL, 2, RMF_PROTOCOL + 40,  RMF_LIST_B, "protocol optionalInstanceMethods");
    check_slot(&w, MML_PROTOCOL, 3, RMF_PROTOCOL + 48,  RMF_LIST_C, "protocol optionalClassMethods");
    CHECK(w.owners[MML_CATEGORY] == 2, "allslots: categories walked %u, want 2 -- the one listed "
          "twice once, and the one only __objc_nlcatlist names", w.owners[MML_CATEGORY]);
    CHECK(w.n == 9, "allslots: %u slots, want 9", w.n);
    CHECK(w.relative == 4 && w.absolute == 0, "allslots: %u relative, %u absolute; want 4, 0",
          w.relative, w.absolute);
    mml_walk_free(&w);
}

int main(void) {
    test_class_names_its_relative_list();
    test_metaclass_is_reached_through_isa();
    test_swift_tag_bits_do_not_hide_the_ro();
    test_a_class_listed_twice_is_walked_once();
    test_a_slot_two_classes_share_is_recorded_once();
    test_refusals();
    test_category_and_protocol_lists();
    test_a_shared_list_counts_once();
    test_absolute_lists_are_counted_apart();
    test_every_category_and_protocol_slot_is_read();

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("objc_meth_test: 0 failure(s)\n");
    return 0;
}
