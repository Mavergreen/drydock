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

/* ---- resolving entries ------------------------------------------------------ */

/* Builds `variant`, lets `poke` edit it, and opens a walk and a resolver on it. */
typedef struct { mi_image im; mml_walk w; mml_resolver r; int rc; char why[256]; } opened;

static int open_poked(unsigned variant, void (*poke)(uint8_t *), opened *o) {
    memset(o, 0, sizeof *o);
    rmf_build(fx, variant);
    if (poke) poke(fx);
    if (mi_wrap(fx, RMF_SIZE, &o->im) != 0) {
        printf("FAIL: fixture variant %#x does not wrap\n", variant);
        fails++;
        return -1;
    }
    if ((o->rc = mml_walk_image(&o->im, &o->w)) != MML_OK) return -1;
    return o->rc = mml_resolver_open(&o->im, &o->r, o->why, sizeof o->why);
}

static void close_opened(opened *o) {
    mml_walk_free(&o->w);
    mml_resolver_close(&o->r);
}

static const mml_ref *ref_naming(const mml_walk *w, uint32_t list) {
    for (uint32_t i = 0; i < w->n; i++)
        if (w->refs[i].list_va == RMF_VA(list)) return &w->refs[i];
    return NULL;
}

static void check_entry(const opened *o, uint32_t list, uint32_t i, uint32_t name_off,
                        uint64_t imp, const char *label) {
    const mml_ref *ref = ref_naming(&o->w, list);
    mml_entry e;
    char why[256] = "";
    int rc = ref ? mml_entry_at(&o->r, ref, i, &e, why, sizeof why) : -99;
    CHECK(rc == MML_OK, "%s: rc %d (%s)", label, rc, why);
    if (rc == MML_OK)
        CHECK(e.name == RMF_VA(RMF_METHNAME + name_off) && e.types == RMF_VA(RMF_METHTYPE) &&
              e.imp == imp, "%s: (%#llx, %#llx, %#llx); want (%#llx, %#llx, %#llx)", label,
              (unsigned long long)e.name, (unsigned long long)e.types, (unsigned long long)e.imp,
              (unsigned long long)RMF_VA(RMF_METHNAME + name_off),
              (unsigned long long)RMF_VA(RMF_METHTYPE), (unsigned long long)imp);
}

static void test_relative_entries_resolve_through_their_selector_references(void) {
    opened o;
    int rc = open_poked(RMF_PLAIN, NULL, &o);
    CHECK(rc == MML_OK, "resolve plain: rc %d (%s)", rc, o.why);
    if (rc == MML_OK) {
        check_entry(&o, RMF_LIST_A, 0, 0x10, RMF_VA(RMF_TEXT + 0), "list A entry 0 (beta)");
        check_entry(&o, RMF_LIST_A, 1, 0x00, RMF_VA(RMF_TEXT + 4), "list A entry 1 (alpha)");
        check_entry(&o, RMF_LIST_B, 0, 0x20, RMF_VA(RMF_TEXT + 8), "list B entry 0 (gamma)");
        check_entry(&o, RMF_LIST_D, 0, 0x00, 0, "list D entry 0, which has no IMP");
    }
    close_opened(&o);
}

static void test_absolute_entries_are_read_as_they_are(void) {
    opened o;
    int rc = open_poked(RMF_ABSCAT, NULL, &o);
    CHECK(rc == MML_OK, "resolve abscat: rc %d (%s)", rc, o.why);
    if (rc == MML_OK) check_entry(&o, RMF_ABS_C, 0, 0x30, RMF_VA(RMF_TEXT + 12), "absolute list C");
    close_opened(&o);
}

static void test_function_starts_admit_every_imp_they_name(void) {
    opened o;
    int rc = open_poked(RMF_FSTARTS, NULL, &o);
    CHECK(rc == MML_OK && o.r.nstarts == 4, "fstarts: rc %d, %d starts (%s)", rc, o.r.nstarts, o.why);
    if (rc == MML_OK) check_entry(&o, RMF_LIST_C, 0, 0x30, RMF_VA(RMF_TEXT + 12), "fstarts list C");
    close_opened(&o);
}

static void poke_misaligned(uint8_t *b)   { uint32_t d; memcpy(&d, b + RMF_LIST_A + 8, 4); d += 4; memcpy(b + RMF_LIST_A + 8, &d, 4); }
static void poke_selref_const(uint8_t *b) { rmf_put64(b, RMF_SELREFS + 8, RMF_VA(RMF_CLASS_RO)); }
static void poke_types_open(uint8_t *b)   { memset(b + RMF_METHTYPE, 'v', 0x10); }
static void poke_imp_data(uint8_t *b)     {
    rmf_put32(b, RMF_LIST_A + 16, (uint32_t)(int32_t)((int64_t)RMF_METHNAME - (int64_t)(RMF_LIST_A + 16)));
}
static void poke_selref_outside(uint8_t *b) {
    rmf_put32(b, RMF_LIST_A + 8, (uint32_t)(int32_t)((int64_t)RMF_SIZE + 0x1000 - (int64_t)(RMF_LIST_A + 8)));
}

static void refused_entry(unsigned variant, void (*poke)(uint8_t *), uint32_t list, uint32_t i,
                          const char *want, const char *label) {
    opened o;
    mml_entry e;
    char why[256] = "";
    int rc = open_poked(variant, poke, &o);
    const mml_ref *ref = rc == MML_OK ? ref_naming(&o.w, list) : NULL;
    CHECK(ref != NULL, "%s: no list to resolve (rc %d, %s)", label, rc, o.why);
    if (ref) {
        rc = mml_entry_at(&o.r, ref, i, &e, why, sizeof why);
        CHECK(rc == MML_MALFORMED, "%s: rc %d, want MML_MALFORMED", label, rc);
        CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    }
    close_opened(&o);
}

static void test_entries_that_cannot_be_made_absolute_are_refused(void) {
    refused_entry(RMF_SELBIND, NULL, RMF_LIST_A, 0, "is bound to another image", "a bound selector reference");
    refused_entry(RMF_PLAIN, poke_misaligned, RMF_LIST_A, 0, "not 8-byte aligned", "a misaligned selector reference");
    refused_entry(RMF_PLAIN, poke_selref_outside, RMF_LIST_A, 0, "outside the file", "a selector reference past the file");
    refused_entry(RMF_PLAIN, poke_selref_const, RMF_LIST_A, 0, "is not a C string", "a selector reference into __objc_const");
    refused_entry(RMF_PLAIN, poke_types_open, RMF_LIST_A, 0, "types at", "types with no NUL in their section");
    refused_entry(RMF_PLAIN, poke_imp_data, RMF_LIST_A, 0, "not in a section of instructions", "an IMP into __objc_methname");
    refused_entry(RMF_FSBAD, NULL, RMF_LIST_C, 0, "not one of the 3 function starts", "an IMP that is not a function start");
}

static void poke_unbind(uint8_t *b) { memset(b + RMF_BIND_BLOB, 0, 0x20); }

static void test_selector_references_without_a_rebase_or_bind_are_named_so(void) {
    opened o;
    int rc = open_poked(RMF_NOSLOTRB, NULL, &o);
    CHECK(rc == MML_OK, "noslotrb: rc %d (%s)", rc, o.why);
    CHECK(!mml_off_rebased(&o.r, RMF_CLASS_RO + 32), "noslotrb: the class ro's slot reads as rebased");
    CHECK(mml_off_rebased(&o.r, RMF_META_RO + 32), "noslotrb: the metaclass ro's slot reads as not rebased");
    close_opened(&o);
    refused_entry(RMF_SELBIND, poke_unbind, RMF_LIST_A, 0, "carries no rebase",
                  "a selector reference neither rebased nor bound");
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
    test_relative_entries_resolve_through_their_selector_references();
    test_absolute_entries_are_read_as_they_are();
    test_function_starts_admit_every_imp_they_name();
    test_entries_that_cannot_be_made_absolute_are_refused();
    test_selector_references_without_a_rebase_or_bind_are_named_so();

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("objc_meth_test: 0 failure(s)\n");
    return 0;
}
