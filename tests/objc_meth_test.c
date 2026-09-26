/* tests/objc_meth_test.c -- hermetic tests for src/objc_meth.c, against the
 * hand-built image in tests/relmeth_fixture.h. */
#include "objc_meth.h"
#include "objc_abs.h"
#include "image.h"
#include "mach_compat.h"
#include "rewrite.h"
#include "relmeth_fixture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

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

static struct dyld_info_command *poke_find_dyld_info(uint8_t *b) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = b + sizeof *h;
    for (uint32_t k = 0; k < h->ncmds; k++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_DYLD_INFO_ONLY || lc->cmd == LC_DYLD_INFO)
            return (struct dyld_info_command *)lc;
        p += lc->cmdsize;
    }
    return NULL;
}

/* Retypes every rebase in the stream (one SET_TYPE_IMM covers them all) as
 * REBASE_TYPE_TEXT_ABSOLUTE32. */
static void poke_rebase_abs32(uint8_t *b) {
    b[RMF_REBASE] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_TEXT_ABSOLUTE32;
}

/* Replaces the whole rebase stream with two rebases of the same slot (list
 * A entry 0's selref, RMF_SELREFS + 8): TEXT_ABSOLUTE32 first, POINTER
 * second. */
static void poke_rebase_dup_pointer(uint8_t *b) {
    struct dyld_info_command *di = poke_find_dyld_info(b);
    uint32_t at = RMF_REBASE, off = RMF_SELREFS + 8 - RMF_DATA;
    b[at++] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_TEXT_ABSOLUTE32;
    b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
    at += rmf_uleb(b + at, off);
    b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
    b[at++] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER;
    b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
    at += rmf_uleb(b + at, off);
    b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
    b[at++] = REBASE_OPCODE_DONE;
    di->rebase_off = RMF_REBASE;
    di->rebase_size = at - RMF_REBASE;
}

/* Replaces the whole rebase stream with a single POINTER rebase of
 * RMF_SELREFS + 8 -- the slot RMF_SELBIND's bind stream also binds. */
static void poke_rebase_add_selref1(uint8_t *b) {
    struct dyld_info_command *di = poke_find_dyld_info(b);
    uint32_t at = RMF_REBASE, off = RMF_SELREFS + 8 - RMF_DATA;
    b[at++] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER;
    b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
    at += rmf_uleb(b + at, off);
    b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
    b[at++] = REBASE_OPCODE_DONE;
    di->rebase_off = RMF_REBASE;
    di->rebase_size = at - RMF_REBASE;
}

/* list A entry 0's IMP delta, poked so that -- interpreted against a
 * synthetic ref whose list_va is 0 -- it resolves to address 0 exactly. */
static void poke_imp_zero(uint8_t *b) { rmf_put32(b, RMF_LIST_A + 16, (uint32_t)(int32_t)(-16)); }

static void poke_text_fileoff(uint8_t *b) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = b + sizeof *h;
    for (uint32_t k = 0; k < h->ncmds; k++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *sc = (struct segment_command_64 *)lc;
            if (strncmp(sc->segname, "__TEXT", 16) == 0) { sc->fileoff = 1; return; }
        }
        p += lc->cmdsize;
    }
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
    refused_entry(RMF_PLAIN, poke_rebase_abs32, RMF_LIST_A, 0,
                  "carries a TEXT_ABSOLUTE32 rebase, not a pointer rebase",
                  "a selector reference rebased as TEXT_ABSOLUTE32");
    refused_entry(RMF_SELBIND, poke_rebase_add_selref1, RMF_LIST_A, 0, "is bound to another image",
                  "a selector reference both bound and pointer-rebased");
    refused_entry(RMF_PLAIN, NULL, RMF_LIST_A, 2, "only 2 entries", "an index past the list's count");
}

static void test_a_selref_rebased_both_ways_still_resolves_as_pointer(void) {
    opened o;
    int rc = open_poked(RMF_PLAIN, poke_rebase_dup_pointer, &o);
    CHECK(rc == MML_OK, "dup rebase: resolver rc %d (%s)", rc, o.why);
    if (rc == MML_OK)
        check_entry(&o, RMF_LIST_A, 0, 0x10, RMF_VA(RMF_TEXT + 0),
                    "list A entry 0, rebased as TEXT_ABSOLUTE32 then as a pointer");
    close_opened(&o);
}

static void test_an_imp_resolving_to_address_0_is_refused(void) {
    opened o;
    mml_ref ref;
    mml_entry e;
    char why[256] = "";
    int rc = open_poked(RMF_PLAIN, poke_imp_zero, &o);
    CHECK(rc == MML_OK, "imp zero: resolver rc %d (%s)", rc, o.why);
    if (rc == MML_OK) {
        memset(&ref, 0, sizeof ref);
        ref.list_off = RMF_LIST_A;
        ref.header = RMF_REL_HEADER;
        ref.count = 2;
        rc = mml_entry_at(&o.r, &ref, 0, &e, why, sizeof why);
        CHECK(rc == MML_MALFORMED, "imp zero: rc %d, want MML_MALFORMED", rc);
        CHECK(strstr(why, "resolves to address 0") != NULL,
              "imp zero: why '%s' lacks 'resolves to address 0'", why);
    }
    close_opened(&o);
}

/* Bypasses open_poked/mml_walk_image: __TEXT maps __objc_methlist and
 * friends, so a poke that leaves it unable to map file offset 0 would
 * break the walk too, not just mi_image_base. mml_resolver_open needs no
 * successful walk first. */
static void test_an_unbased_image_names_its_own_refusal(void) {
    mi_image im;
    mml_resolver r;
    char why[256] = "";
    int rc;
    rmf_build(fx, RMF_FSTARTS);
    poke_text_fileoff(fx);
    if (mi_wrap(fx, RMF_SIZE, &im) != 0) {
        printf("FAIL: fixture variant fstarts (unbased) does not wrap\n");
        fails++;
        return;
    }
    rc = mml_resolver_open(&im, &r, why, sizeof why);
    CHECK(rc == MML_MALFORMED, "unbased: rc %d, want MML_MALFORMED (%s)", rc, why);
    CHECK(strstr(why, "no segment maps the image's header") != NULL,
          "unbased: why '%s' lacks its own reason", why);
    if (rc == MML_OK) mml_resolver_close(&r);
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

/* ---- layout ------------------------------------------------------------------ */

static int layout_of(unsigned variant, void (*poke)(uint8_t *), size_t size, mma_layout *lay,
                     char *why, size_t whysz) {
    mi_image im;
    mma_seg segs[MML_MAX_SEGS];
    rmf_build(fx, variant);
    if (poke) poke(fx);
    if (mi_wrap(fx, RMF_SIZE, &im) != 0) return -99;
    return mma_layout_check(segs, mma_segments(&im, segs, MML_MAX_SEGS), size, lay, why, whysz);
}

static void test_layout_puts_the_lists_at_the_end_of_data(void) {
    mma_layout lay;
    char why[256] = "";
    int rc = layout_of(RMF_PLAIN, NULL, RMF_SIZE, &lay, why, sizeof why);
    CHECK(rc == MMA_OK, "layout plain: rc %d (%s)", rc, why);
    CHECK(lay.d == 2 && lay.l == 3 && strncmp(lay.dname, "__DATA", 16) == 0,
          "layout plain: D %d (%.16s), L %d", lay.d, lay.dname, lay.l);
    CHECK(lay.list_va == RMF_VA(RMF_LINKEDIT) && lay.insert == RMF_LINKEDIT && lay.z == 0,
          "layout plain: lists at %#llx, insert %#llx, z %#llx", (unsigned long long)lay.list_va,
          (unsigned long long)lay.insert, (unsigned long long)lay.z);
    rc = layout_of(RMF_DYLIB, NULL, RMF_SIZE, &lay, why, sizeof why);
    CHECK(rc == MMA_OK && lay.d == 1 && lay.l == 2, "layout dylib: rc %d, D %d, L %d (%s)",
          rc, lay.d, lay.l, why);
    rc = layout_of(RMF_ZEROTAIL, NULL, RMF_SIZE, &lay, why, sizeof why);
    CHECK(rc == MMA_OK && lay.z == 0x1000 && lay.list_va == RMF_VA(RMF_DATA + 0x2000) &&
          lay.insert == RMF_LINKEDIT, "layout zerotail: rc %d, z %#llx, lists at %#llx (%s)", rc,
          (unsigned long long)lay.z, (unsigned long long)lay.list_va, why);
}

static void poke_linkedit_fileoff(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *l;
    if (mi_wrap(b, RMF_SIZE, &im) == 0 && (l = mi_find_segment(&im, "__LINKEDIT"))) l->fileoff += 8;
}
static void poke_data_unaligned(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *d, *l;
    if (mi_wrap(b, RMF_SIZE, &im) != 0) return;
    if ((d = mi_find_segment(&im, "__DATA"))) { d->vmsize -= 8; d->filesize -= 8; }
    if ((l = mi_find_segment(&im, "__LINKEDIT"))) { l->vmaddr -= 8; l->fileoff -= 8; l->filesize += 8; }
}

static void refused_layout(unsigned variant, void (*poke)(uint8_t *), size_t size,
                           const char *want, const char *label) {
    mma_layout lay;
    char why[256] = "";
    int rc = layout_of(variant, poke, size, &lay, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: rc %d, want MMA_REFUSED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
}

static void test_layout_refusals(void) {
    mma_seg segs[18];
    mma_layout lay;
    char why[256] = "";
    int rc;
    refused_layout(RMF_DATARO, NULL, RMF_SIZE, "is not writable", "D read-only");
    refused_layout(RMF_GAP, NULL, RMF_SIZE, "in memory", "a gap in vm before __LINKEDIT");
    refused_layout(RMF_SEGAFTER, NULL, RMF_SIZE, "not the last segment", "a segment after __LINKEDIT");
    refused_layout(RMF_PLAIN, poke_linkedit_fileoff, RMF_SIZE + 8, "file offset", "a gap in the file");
    refused_layout(RMF_PLAIN, NULL, RMF_SIZE + 8, "the image is 0x2208 bytes", "bytes past __LINKEDIT");
    refused_layout(RMF_PLAIN, poke_data_unaligned, RMF_SIZE, "page boundary", "D ends mid-page");
    memset(segs, 0, sizeof segs);
    for (int i = 0; i < 18; i++) {
        snprintf(segs[i].name, sizeof segs[i].name, "__S%d", i);
        segs[i].vmaddr = segs[i].fileoff = 0x1000 * (uint64_t)i;
        segs[i].vmsize = segs[i].filesize = 0x1000;
        segs[i].initprot = VM_PROT_READ | VM_PROT_WRITE;
    }
    memcpy(segs[17].name, "__LINKEDIT", 11);
    rc = mma_layout_check(segs, 18, 0x12000, &lay, why, sizeof why);
    CHECK(rc == MMA_REFUSED && strstr(why, "is segment 16") != NULL,
          "D at segment 16: rc %d, why '%s'", rc, why);
    rc = mma_layout_check(segs + 1, 17, 0x12000, &lay, why, sizeof why);
    CHECK(rc == MMA_OK && lay.d == 15, "D at segment 15: rc %d, D %d (%s)", rc, lay.d, why);
}

/* ---- insertion ----------------------------------------------------------------- */

typedef struct { uint8_t *b; size_t n; mma_layout lay; uint32_t r; } inserted;

static const uint8_t LISTS[40] = "the lists, forty bytes of them, padded.";
static const uint8_t STREAM[16] = { 0x11, 0x22, 0x08, 0x51, 0 };

static int insert_into(unsigned variant, void (*poke)(uint8_t *), inserted *o, char *why, size_t whysz) {
    mi_image im;
    int rc;
    memset(o, 0, sizeof *o);
    if ((rc = layout_of(variant, poke, RMF_SIZE, &o->lay, why, whysz)) != MMA_OK) return rc;
    if (mi_wrap(fx, RMF_SIZE, &im) != 0) return -99;
    o->r = sizeof STREAM;
    return mma_insert(&im, &o->lay, LISTS, sizeof LISTS, MMA_PAGE, STREAM, o->r, &o->b, &o->n,
                      why, whysz);
}

typedef struct { const struct segment_command_64 *d, *l, *pz, *tx; const struct dyld_info_command *di;
                 const struct symtab_command *st; const struct linkedit_data_command *cs, *sp;
                 int nsegs; } lcs_of;

static int note_lc(const struct load_command *lc, void *ctx_) {
    lcs_of *c = ctx_;
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
        if (strncmp(sc->segname, "__DATA", 16) == 0) c->d = sc;
        if (strncmp(sc->segname, "__LINKEDIT", 16) == 0) c->l = sc;
        if (strncmp(sc->segname, "__PAGEZERO", 16) == 0) c->pz = sc;
        if (strncmp(sc->segname, "__TEXT", 16) == 0) c->tx = sc;
        c->nsegs++;
    }
    if (lc->cmd == LC_DYLD_INFO_ONLY) c->di = (const struct dyld_info_command *)lc;
    if (lc->cmd == LC_SYMTAB) c->st = (const struct symtab_command *)lc;
    if (lc->cmd == LC_CODE_SIGNATURE) c->cs = (const struct linkedit_data_command *)lc;
    if (lc->cmd == LC_SEGMENT_SPLIT_INFO) c->sp = (const struct linkedit_data_command *)lc;
    return 0;
}

static lcs_of lcs(uint8_t *b, size_t n) {
    lcs_of c;
    mi_image im;
    memset(&c, 0, sizeof c);
    if (mi_wrap(b, n, &im) == 0) mi_each_lc(&im, note_lc, &c);
    return c;
}

static void test_insert_moves_linkedit_up_behind_the_lists(void) {
    inserted o;
    uint8_t in[RMF_SIZE];
    char why[256] = "";
    int rc = insert_into(RMF_CODESIG | RMF_SPLIT, NULL, &o, why, sizeof why);
    uint64_t grow = MMA_PAGE + sizeof STREAM;
    memcpy(in, fx, RMF_SIZE);
    CHECK(rc == MMA_OK && o.n == RMF_SIZE + grow, "insert: rc %d, %zu bytes (%s)", rc, o.n, why);
    if (rc != MMA_OK) return;
    lcs_of was = lcs(in, RMF_SIZE), now = lcs(o.b, o.n);
    CHECK(now.d->vmsize == 0x2000 && now.d->filesize == 0x2000, "insert: D is %#llx/%#llx",
          (unsigned long long)now.d->vmsize, (unsigned long long)now.d->filesize);
    CHECK(now.l->vmaddr == was.l->vmaddr + MMA_PAGE && now.l->fileoff == RMF_LINKEDIT + MMA_PAGE &&
          now.l->filesize == RMF_LINKEDIT_SIZE + sizeof STREAM && now.l->vmsize == was.l->vmsize,
          "insert: __LINKEDIT at %#llx/%#llx, %#llx/%#llx bytes", (unsigned long long)now.l->vmaddr,
          (unsigned long long)now.l->fileoff, (unsigned long long)now.l->vmsize,
          (unsigned long long)now.l->filesize);
    CHECK(now.pz && now.tx && memcmp(now.pz, was.pz, was.pz->cmdsize) == 0 &&
          memcmp(now.tx, was.tx, was.tx->cmdsize) == 0,
          "insert: __PAGEZERO's or __TEXT's load command changed");
    CHECK(memcmp(o.b + sizeof(struct mach_header_64) + ((struct mach_header_64 *)in)->sizeofcmds,
                 in + sizeof(struct mach_header_64) + ((struct mach_header_64 *)in)->sizeofcmds,
                 RMF_LINKEDIT - sizeof(struct mach_header_64) - ((struct mach_header_64 *)in)->sizeofcmds) == 0,
          "insert: a byte between the load commands and __LINKEDIT changed");
    CHECK(memcmp(o.b + RMF_LINKEDIT, LISTS, sizeof LISTS) == 0, "insert: the lists are not at D's old end");
    for (size_t i = RMF_LINKEDIT + sizeof LISTS; i < RMF_LINKEDIT + MMA_PAGE; i++)
        if (o.b[i]) { CHECK(0, "insert: byte %#zx past the lists is %#x", i, o.b[i]); break; }
    CHECK(memcmp(o.b + RMF_LINKEDIT + MMA_PAGE, STREAM, sizeof STREAM) == 0,
          "insert: the stream does not start __LINKEDIT");
    CHECK(now.di->rebase_off == RMF_LINKEDIT + MMA_PAGE && now.di->rebase_size == sizeof STREAM,
          "insert: rebase_off %#x size %u", now.di->rebase_off, now.di->rebase_size);
    for (uint32_t i = 0; i < was.di->rebase_size; i++)
        if (o.b[RMF_REBASE + grow + i]) { CHECK(0, "insert: the old rebase stream is not zeroed"); break; }
    CHECK(memcmp(o.b + RMF_REBASE + grow + was.di->rebase_size, in + RMF_REBASE + was.di->rebase_size,
                 RMF_SIZE - RMF_REBASE - was.di->rebase_size) == 0,
          "insert: the rest of the old __LINKEDIT did not move up intact");
    CHECK(now.st->symoff == was.st->symoff + grow && now.st->stroff == was.st->stroff + grow &&
          now.cs->dataoff == was.cs->dataoff + grow && now.sp->dataoff == was.sp->dataoff + grow,
          "insert: an offset in __LINKEDIT did not move by %#llx", (unsigned long long)grow);
    CHECK(memcmp(o.b + now.cs->dataoff, in + RMF_CODESIG_BLOB, RMF_CODESIG_SIZE) == 0 &&
          memcmp(o.b + now.sp->dataoff, "split!!", 8) == 0,
          "insert: the code signature or split info bytes are not where their offsets say");
    free(o.b);
}

static void test_insert_makes_the_zero_fill_file_bytes(void) {
    inserted o;
    char why[256] = "";
    int rc = insert_into(RMF_ZEROTAIL, NULL, &o, why, sizeof why);
    uint64_t z = 0x1000, grow = z + MMA_PAGE + sizeof STREAM;
    CHECK(rc == MMA_OK && o.n == RMF_SIZE + grow, "zerotail insert: rc %d, %zu bytes (%s)", rc, o.n, why);
    if (rc != MMA_OK) return;
    lcs_of now = lcs(o.b, o.n);
    CHECK(now.d->vmsize == 0x3000 && now.d->filesize == 0x3000, "zerotail: D is %#llx/%#llx",
          (unsigned long long)now.d->vmsize, (unsigned long long)now.d->filesize);
    CHECK(now.l->fileoff == RMF_LINKEDIT + z + MMA_PAGE && now.l->vmaddr == RMF_VA(RMF_DATA + 0x3000),
          "zerotail: __LINKEDIT at %#llx/%#llx", (unsigned long long)now.l->vmaddr,
          (unsigned long long)now.l->fileoff);
    for (size_t i = RMF_LINKEDIT; i < RMF_LINKEDIT + z; i++)
        if (o.b[i]) { CHECK(0, "zerotail: zero-fill byte %#zx is %#x", i, o.b[i]); break; }
    CHECK(memcmp(o.b + RMF_LINKEDIT + z, LISTS, sizeof LISTS) == 0, "zerotail: the lists are not past the zero fill");
    CHECK(now.st->symoff == RMF_SYMS + grow, "zerotail: symoff %#x", now.st->symoff);
    CHECK(now.di->rebase_off == RMF_LINKEDIT + z + MMA_PAGE, "zerotail: rebase_off %#x", now.di->rebase_off);
    free(o.b);
}

static void poke_linkedit_snug(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *l;
    if (mi_wrap(b, RMF_SIZE, &im) == 0 && (l = mi_find_segment(&im, "__LINKEDIT"))) l->vmsize = l->filesize;
}

static void test_insert_grows_linkedit_vm_to_cover_its_file_bytes(void) {
    inserted o;
    char why[256] = "";
    int rc = insert_into(RMF_PLAIN, poke_linkedit_snug, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "snug insert: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    lcs_of now = lcs(o.b, o.n);
    CHECK(now.l->vmsize == MMA_PAGE, "snug: __LINKEDIT vmsize %#llx for %#llx file bytes, want 0x1000",
          (unsigned long long)now.l->vmsize, (unsigned long long)now.l->filesize);
    free(o.b);
}

static void test_insert_never_grows_the_header(void) {
    inserted o;
    char why[256] = "";
    int rc = insert_into(RMF_DYLIB, NULL, &o, why, sizeof why);
    const struct mach_header_64 *was = (const struct mach_header_64 *)fx;
    CHECK(rc == MMA_OK, "dylib insert: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    const struct mach_header_64 *now = (const struct mach_header_64 *)o.b;
    CHECK(now->ncmds == was->ncmds && now->sizeofcmds == was->sizeofcmds &&
          sizeof *now + now->sizeofcmds + RMF_PAD == RMF_TEXT,
          "dylib insert: %u commands in %u bytes, was %u in %u", now->ncmds, now->sizeofcmds,
          was->ncmds, was->sizeofcmds);
    CHECK(memcmp(o.b + RMF_TEXT, fx + RMF_TEXT, RMF_LINKEDIT - RMF_TEXT) == 0,
          "dylib insert: a byte below __LINKEDIT changed");
    free(o.b);
}

/* ---- layout and insertion, hostile inputs ----------------------------------------- */

static mma_seg seg_of(const char *name, uint64_t vm, uint64_t vmsize, uint64_t foff, uint64_t fsize) {
    mma_seg s;
    memset(&s, 0, sizeof s);
    snprintf(s.name, sizeof s.name, "%s", name);
    s.vmaddr = vm; s.vmsize = vmsize; s.fileoff = foff; s.filesize = fsize;
    s.initprot = VM_PROT_READ | VM_PROT_WRITE;
    return s;
}

static void refused_segs(const mma_seg *segs, int n, uint64_t file_size, const char *want,
                         const char *label) {
    mma_layout lay;
    char why[256] = "";
    int rc = mma_layout_check(segs, n, file_size, &lay, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: rc %d, want MMA_REFUSED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
}

/* D's end wraps past 2^64 onto __LINKEDIT's start. */
static void poke_vm_wrap(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *d, *l;
    if (mi_wrap(b, RMF_SIZE, &im) != 0) return;
    if (!(d = mi_find_segment(&im, "__DATA")) || !(l = mi_find_segment(&im, "__LINKEDIT"))) return;
    d->vmsize = (uint64_t)0 - 0x2000;
    l->vmaddr = d->vmaddr + d->vmsize;
}

static void test_layout_refuses_ends_that_wrap(void) {
    const uint64_t top = (uint64_t)0 - 0x1000;
    mma_seg s[3];
    refused_layout(RMF_PLAIN, poke_vm_wrap, RMF_SIZE, "in memory, does not end where", "D's vm end wraps");
    s[0] = seg_of("__TEXT", 0, 0x1000, 0, 0x1000);
    s[1] = seg_of("__DATA", 0, top, 0x3000, top);
    s[2] = seg_of("__LINKEDIT", top, 0x1000, 0x2000, 0x200);
    refused_segs(s, 3, 0x2200, "file offset", "D's file end wraps");
    s[1] = seg_of("__DATA", 0x1000, 0x1000, 0x2000, 0x1000);
    s[2] = seg_of("__LINKEDIT", 0x2000, 0x1000, 0x3000, top);
    refused_segs(s, 3, 0x2000, "the image is 0x2000 bytes", "__LINKEDIT's file end wraps");
    s[1] = seg_of("__DATA", 0x1000, 0x100001000ULL, 0x1000, 0x1000);
    s[2] = seg_of("__LINKEDIT", 0x100002000ULL, 0x1000, 0x2000, 0x200);
    refused_segs(s, 3, 0x2200, "zero fill", "4GB of zero fill");
}

static void test_layout_takes_zero_fill_up_to_4gb(void) {
    mma_layout lay;
    char why[256] = "";
    mma_seg s[3];
    int rc;
    s[0] = seg_of("__TEXT", 0, 0x1000, 0, 0x1000);
    s[1] = seg_of("__DATA", 0x1000, 0x1001 + (uint64_t)UINT32_MAX, 0x1000, 0x1001);
    s[2] = seg_of("__LINKEDIT", 0x100002000ULL, 0x1000, 0x2001, 0x1ff);
    rc = mma_layout_check(s, 3, 0x2200, &lay, why, sizeof why);
    CHECK(rc == MMA_OK && lay.z == UINT32_MAX, "0xffffffff bytes of zero fill: rc %d, z %#llx (%s)",
          rc, (unsigned long long)lay.z, why);
}

static void test_layout_refuses_a_segment_above_linkedit(void) {
    mma_layout lay;
    char why[256] = "";
    mma_seg s[4];
    int rc;
    s[0] = seg_of("__TEXT", 0, 0x1000, 0, 0x1000);
    s[1] = seg_of("__HIGH", 0x10000, 0x1000, 0, 0);
    s[2] = seg_of("__DATA", 0x1000, 0x1000, 0x1000, 0x1000);
    s[3] = seg_of("__LINKEDIT", 0x2000, 0x1000, 0x2000, 0x200);
    refused_segs(s, 4, 0x2200, "above __LINKEDIT", "a segment above __LINKEDIT in vm");
    s[1] = seg_of("__LOW", 0x800, 0x800, 0, 0);
    rc = mma_layout_check(s, 4, 0x2200, &lay, why, sizeof why);
    CHECK(rc == MMA_OK, "a segment ending where D begins: rc %d (%s)", rc, why);
    s[1] = seg_of("__END", 0x1800, 0x800, 0, 0);
    rc = mma_layout_check(s, 4, 0x2200, &lay, why, sizeof why);
    CHECK(rc == MMA_OK, "a segment ending where __LINKEDIT begins: rc %d (%s)", rc, why);
    s[1] = seg_of("__EMPTY", 0x2000, 0, 0, 0);
    rc = mma_layout_check(s, 4, 0x2200, &lay, why, sizeof why);
    CHECK(rc == MMA_OK, "an empty segment where __LINKEDIT begins: rc %d (%s)", rc, why);
}

static void test_layout_names_why_there_is_no_room(void) {
    mma_seg s[1];
    s[0] = seg_of("__LINKEDIT", 0x2000, 0x1000, 0x2000, 0x200);
    refused_segs(s, -1, 0x2200, "more than 64 segments", "too many segments");
    refused_segs(s, 1, 0x2200, "no segment before __LINKEDIT", "__LINKEDIT alone");
    refused_segs(s, 0, 0x2200, "has no __LINKEDIT", "no segments");
}

static void append_lc(uint8_t *b, const void *lc, uint32_t size) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    memcpy(b + sizeof *h + h->sizeofcmds, lc, size);
    h->ncmds++;
    h->sizeofcmds += size;
}

static struct dyld_info_command *info_of(uint8_t *b) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = b + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++, p += ((struct load_command *)p)->cmdsize)
        if (((struct load_command *)p)->cmd == LC_DYLD_INFO_ONLY) return (struct dyld_info_command *)p;
    return NULL;
}

static void poke_note(uint8_t *b) {
    struct { uint32_t cmd, cmdsize; char owner[16]; uint64_t offset, size; } n =
        { LC_NOTE, 40, "rmf", RMF_SYMS, 8 };
    append_lc(b, &n, sizeof n);
}
static void poke_atom(uint8_t *b) {
    struct linkedit_data_command a = { LC_ATOM_INFO, sizeof a, RMF_SYMS, 8 };
    append_lc(b, &a, sizeof a);
}
static void poke_info2(uint8_t *b) {
    struct dyld_info_command d = *info_of(b);
    append_lc(b, &d, sizeof d);
}
static void poke_no_info(uint8_t *b) { info_of(b)->cmd = 0x7e; }
static void poke_rebase_low(uint8_t *b) { info_of(b)->rebase_off = RMF_TEXT; }
static void poke_rebase_past(uint8_t *b) { info_of(b)->rebase_size = RMF_SIZE; }
static void poke_rebase_to_eof(uint8_t *b) { info_of(b)->rebase_size = RMF_SIZE - RMF_REBASE; }
static void poke_rebase_past_eof(uint8_t *b) { info_of(b)->rebase_size = RMF_SIZE - RMF_REBASE + 1; }

static void refused_insert(void (*poke)(uint8_t *), const char *want, const char *label) {
    inserted o;
    char why[256] = "";
    int rc = insert_into(RMF_PLAIN, poke, &o, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: rc %d, want MMA_REFUSED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    free(o.b);
}

static void test_insert_refusals(void) {
    refused_insert(poke_note, "LC_NOTE carries a file offset", "an LC_NOTE");
    refused_insert(poke_atom, "LC_ATOM_INFO carries a file offset", "an LC_ATOM_INFO");
    refused_insert(poke_info2, "2 LC_DYLD_INFO", "two LC_DYLD_INFO_ONLY");
    refused_insert(poke_no_info, "no LC_DYLD_INFO", "no LC_DYLD_INFO");
    refused_insert(poke_rebase_low, "not in __LINKEDIT", "a rebase stream below __LINKEDIT");
}

typedef void (*spoiler)(mma_layout *, uint64_t *, uint64_t *, uint32_t *);

/* mma_insert against the plain fixture's layout with one input made hostile. */
static int direct(spoiler spoil, char *why, size_t whysz) {
    mi_image im;
    mma_layout lay;
    uint64_t s = MMA_PAGE, lists_len = sizeof LISTS;
    uint32_t r = sizeof STREAM;
    uint8_t *out = NULL;
    size_t outsz = 0;
    int rc = layout_of(RMF_PLAIN, NULL, RMF_SIZE, &lay, why, whysz);
    if (rc != MMA_OK) return -98;
    if (mi_wrap(fx, RMF_SIZE, &im) != 0) return -99;
    spoil(&lay, &s, &lists_len, &r);
    rc = mma_insert(&im, &lay, LISTS, lists_len, s, STREAM, r, &out, &outsz, why, whysz);
    if (rc != MMA_OK && out) rc = -97;
    free(out);
    return rc;
}

static void refused_direct(spoiler spoil, const char *want, const char *label) {
    char why[256] = "";
    int rc = direct(spoil, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: rc %d, want MMA_REFUSED (%s)", label, rc, why);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
}
static void spoil_z(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->z = (uint64_t)0 - 0x3000;
}
static void spoil_s(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)l; (void)n; (void)r; *s = (uint64_t)0 - 0x1000;
}
static void spoil_insert(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->insert = RMF_SIZE + 0x1000;
}
static void spoil_4gb(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)l; (void)n; (void)r; *s = 0xfffff000u;
}
static void spoil_page(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)l; (void)n; (void)r; *s = 0x800;
}
static void spoil_lists(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)l; (void)r; *n = *s + 1;
}
static void spoil_r(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)l; (void)s; (void)n; *r = 12;
}
static void spoil_z_max(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->z = UINT32_MAX;
}
static void spoil_z_over(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->z = (uint64_t)UINT32_MAX + 1;
}
static void spoil_s_over(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)l; (void)n; (void)r; *s = (uint64_t)UINT32_MAX + 1;
}
static void spoil_insert_eof(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->insert = RMF_SIZE;
}
static void spoil_insert_past_eof(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->insert = RMF_SIZE + 1;
}
static uint64_t cmds_end(void) {
    return sizeof(struct mach_header_64) + ((const struct mach_header_64 *)fx)->sizeofcmds;
}
static void spoil_insert_in_cmds(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->insert = 0x40;
}
static void spoil_insert_cmds_end_less_1(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->insert = cmds_end() - 1;
}
static void spoil_insert_cmds_end(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; l->insert = cmds_end();
}
static void spoil_zeroed(mma_layout *l, uint64_t *s, uint64_t *n, uint32_t *r) {
    (void)s; (void)n; (void)r; memset(l, 0, sizeof *l);
}

static void test_insert_boundaries(void) {
    inserted o;
    char why[256] = "";
    int rc = insert_into(RMF_PLAIN, poke_rebase_to_eof, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "a rebase stream ending at the end of the file: rc %d (%s)", rc, why);
    free(o.b);
    refused_direct(spoil_insert_eof, "not in __LINKEDIT", "an insertion at the end of the file");
    refused_direct(spoil_z_max, "the image would pass 4GB", "0xffffffff bytes of zero fill");
    refused_direct(spoil_z_over, "0x100000000 zero-fill and", "0x100000000 bytes of zero fill");
    refused_direct(spoil_s_over, "0x100000000 list bytes at", "a 0x100000000-byte list area");
    rc = direct(spoil_insert_cmds_end, why, sizeof why);
    CHECK(rc == MMA_OK, "an insertion where the load commands end: rc %d (%s)", rc, why);
}

/* Last in main: before the guards they test, each of these wrote past a buffer. */
static void test_insert_refuses_what_would_overrun(void) {
    refused_insert(poke_vm_wrap, "in memory, does not end where", "an insert after D's vm end wraps");
    refused_insert(poke_rebase_past, "past the end of the file", "a rebase stream past the file");
    refused_insert(poke_rebase_past_eof, "past the end of the file", "a rebase stream a byte past the file");
    refused_direct(spoil_z, "0xffffffffffffd000 zero-fill and", "4GB of zero fill");
    refused_direct(spoil_s, "zero-fill and 0xfffffffffffff000 list bytes", "a 4GB list area");
    refused_direct(spoil_insert, "list bytes at 0x3200 in a 0x2200-byte image", "an insertion past the file");
    refused_direct(spoil_insert_past_eof, "list bytes at 0x2201 in a 0x2200-byte image",
                   "an insertion a byte past the file");
    refused_direct(spoil_4gb, "the image would pass 4GB", "an image that would pass 4GB");
    refused_direct(spoil_page, "40 list bytes in 2048, 16 stream bytes", "a list area not whole pages");
    refused_direct(spoil_lists, "4097 list bytes in 4096, 16 stream bytes", "lists longer than their area");
    refused_direct(spoil_r, "40 list bytes in 4096, 12 stream bytes", "a stream not a multiple of 8");
    refused_direct(spoil_insert_in_cmds, "inside the header or load commands",
                   "an insertion inside the load commands");
    refused_direct(spoil_insert_cmds_end_less_1, "inside the header or load commands",
                   "an insertion a byte before the load commands end");
    refused_direct(spoil_zeroed, "inside the header or load commands", "a zeroed layout");
}

/* ---- conversion ------------------------------------------------------------ */

static char oracle_before[4096], oracle_after[4096];

/* The oracle's reading of `b`, with every "rel" read as "abs". */
static int oracle(const uint8_t *b, size_t n, char *out, int as_abs) {
    int w = rmf_describe(b, n, out, 4096);
    char *p;
    if (w < 0) return -1;
    while (as_abs && (p = strstr(out, " rel "))) memcpy(p, " abs ", 5);
    return w;
}

static int build(unsigned variant, void (*poke)(uint8_t *), mma_out *o, char *why, size_t whysz) {
    mi_image im;
    rmf_build(fx, variant);
    if (poke) poke(fx);
    if (mi_wrap(fx, RMF_SIZE, &im) != 0) return -99;
    return mma_build(&im, o, why, whysz);
}

/* Flags 3 on an absolute list tell the 10.9 runtime it is already fixed up,
 * so it would skip uniquing the selectors: every list must read 0x18. */
static void check_headers_are_plain_absolute(const mma_out *o, const char *label) {
    mi_image im;
    mml_walk w;
    CHECK(mi_wrap(o->buf, o->size, &im) == 0 && mml_walk_image(&im, &w) == MML_OK,
          "%s: the converted image does not walk", label);
    for (uint32_t i = 0; i < w.n; i++)
        CHECK(w.refs[i].header == MML_ABS_ENTSIZE, "%s: the list at %#llx has header %#x, want 0x18",
              label, (unsigned long long)w.refs[i].list_va, w.refs[i].header);
    mml_walk_free(&w);
}

static void check_converts_like_the_oracle(unsigned variant, uint32_t lists, uint32_t methods,
                                           const char *label) {
    mma_out o;
    char why[256] = "";
    int rc = build(variant, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "%s: rc %d (%s)", label, rc, why);
    if (rc != MMA_OK) return;
    CHECK(oracle(fx, RMF_SIZE, oracle_before, 1) > 0 && oracle(o.buf, o.size, oracle_after, 0) > 0,
          "%s: the oracle cannot read an image", label);
    CHECK(strcmp(oracle_before, oracle_after) == 0, "%s: the oracle reads\n%s\nwhere it read\n%s",
          label, oracle_after, oracle_before);
    CHECK(o.rep.lists == lists && o.rep.methods == methods, "%s: converted %u lists (%u methods), "
          "want %u (%u)", label, o.rep.lists, o.rep.methods, lists, methods);
    check_headers_are_plain_absolute(&o, label);
    mma_out_free(&o);
}

static void test_conversion_matches_the_oracle_in_order(void) {
    check_converts_like_the_oracle(RMF_PLAIN, 4, 5, "plain");
    check_converts_like_the_oracle(RMF_ALLSLOTS, 4, 5, "every slot filled");
    check_converts_like_the_oracle(RMF_SWIFT, 4, 5, "Swift-tagged class data");
    check_converts_like_the_oracle(RMF_ZEROTAIL, 4, 5, "a zero-fill tail");
    check_converts_like_the_oracle(RMF_DYLIB, 4, 5, "a dylib with 16 bytes of header pad");
    check_converts_like_the_oracle(RMF_CODESIG | RMF_SPLIT, 4, 5, "a code signature and split info");
    check_converts_like_the_oracle(RMF_FSTARTS, 4, 5, "function starts naming every IMP");
    check_converts_like_the_oracle(RMF_SHARED, 3, 4, "a list two slots share");
    check_converts_like_the_oracle(RMF_ABSCAT, 3, 4, "an absolute list beside relative ones");
    check_converts_like_the_oracle(RMF_COMPACT | RMF_ALLSLOTS, 4, 5, "ld64's compact rebase opcodes");
}

static void test_every_new_pointer_is_rebased(void) {
    mma_out o;
    mrb_set was, now;
    char why[256] = "";
    int rc = build(RMF_PLAIN, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "rebases: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    lcs_of in = lcs(fx, RMF_SIZE), out = lcs(o.buf, o.size);
    CHECK(mrb_decode(fx + in.di->rebase_off, in.di->rebase_size, 4, &was, NULL, 0) == MRB_OK &&
          mrb_decode(o.buf + out.di->rebase_off, out.di->rebase_size, 4, &now, NULL, 0) == MRB_OK,
          "rebases: a stream does not decode");
    CHECK(mrb_sort(&now) == 0, "rebases: the new stream repeats a slot");
    CHECK(now.n == was.n + 14 && o.rep.rebases == 14, "rebases: %zu, was %zu; reported %u added, want 14",
          now.n, was.n, o.rep.rebases);
    for (size_t k = 0; k < was.n; k++)
        CHECK(mrb_has(&now, was.v[k].seg, was.v[k].off), "rebases: lost (%u, %#llx)",
              was.v[k].seg, (unsigned long long)was.v[k].off);
    /* List A at 0x2000 (D offset 0x1000): two entries, six pointers. List D,
     * last, at 0x2078: one entry whose IMP is 0, so two. */
    for (uint64_t off = 0x1008; off < 0x1038; off += 8)
        CHECK(mrb_has(&now, 2, off), "rebases: list A's pointer at D+%#llx has none", (unsigned long long)off);
    CHECK(mrb_has(&now, 2, 0x1080) && mrb_has(&now, 2, 0x1088) && !mrb_has(&now, 2, 0x1090),
          "rebases: list D's name and types need one each, and its IMP of 0 none");
    CHECK(o.rep.grew == MMA_PAGE && o.rep.zerofill == 0 && o.rep.linkedit_before == RMF_LINKEDIT_SIZE &&
          o.rep.linkedit_after == RMF_LINKEDIT_SIZE + o.r && strncmp(o.rep.dname, "__DATA", 16) == 0,
          "report: grew %#llx, zero fill %#llx, __LINKEDIT %llu -> %llu, D %.16s",
          (unsigned long long)o.rep.grew, (unsigned long long)o.rep.zerofill,
          (unsigned long long)o.rep.linkedit_before, (unsigned long long)o.rep.linkedit_after, o.rep.dname);
    CHECK(o.rep.owners[MML_CLASS] == 1 && o.rep.owners[MML_METACLASS] == 1 &&
          o.rep.owners[MML_CATEGORY] == 1 && o.rep.owners[MML_PROTOCOL] == 1,
          "report: owners %u %u %u %u", o.rep.owners[0], o.rep.owners[1], o.rep.owners[2], o.rep.owners[3]);
    mrb_free(&was);
    mrb_free(&now);
    mma_out_free(&o);
}

static uint64_t slot_value(const uint8_t *b, uint32_t off) { uint64_t v; memcpy(&v, b + off, 8); return v; }

static void test_every_slot_is_repointed_and_absolute_ones_kept(void) {
    mma_out o;
    char why[256] = "";
    int rc = build(RMF_SHARED, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "shared: rc %d (%s)", rc, why);
    if (rc == MMA_OK) {
        CHECK(slot_value(o.buf, RMF_CLASS_RO + 32) == RMF_VA(RMF_LINKEDIT) &&
              slot_value(o.buf, RMF_CATEGORY + 16) == RMF_VA(RMF_LINKEDIT),
              "shared: the class and category do not both name the one new list");
        mma_out_free(&o);
    }
    rc = build(RMF_ABSCAT, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK && slot_value(o.buf, RMF_CATEGORY + 16) == RMF_VA(RMF_ABS_C),
          "abscat: the absolute list's slot moved (rc %d, %s)", rc, why);
    mma_out_free(&o);
}

static void test_a_converted_image_has_nothing_to_convert(void) {
    mma_out o, again;
    mi_image im;
    char why[256] = "";
    int rc = build(RMF_PLAIN, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "again: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    CHECK(mi_wrap(o.buf, o.size, &im) == 0 && mma_build(&im, &again, why, sizeof why) == MMA_NOTHING &&
          again.buf == NULL, "again: a converted image converts a second time");
    mma_out_free(&o);
}

static void poke_arm64(uint8_t *b)   { ((struct mach_header_64 *)b)->cputype = CPU_TYPE_ARM64; }

static void refused_build(unsigned variant, void (*poke)(uint8_t *), const char *want, const char *label) {
    mma_out o;
    uint8_t before[RMF_SIZE];
    char why[256] = "";
    int rc;
    rmf_build(before, variant);
    if (poke) poke(before);
    rc = build(variant, poke, &o, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: rc %d, want MMA_REFUSED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    CHECK(o.buf == NULL, "%s: a refusal handed back an image", label);
    CHECK(memcmp(before, fx, RMF_SIZE) == 0, "%s: the refusal wrote into its input", label);
}

static void test_conversion_refusals_write_nothing(void) {
    refused_build(RMF_CHAINED, NULL, "fixups set classic first", "chained fixups");
    refused_build(RMF_PLAIN, poke_arm64, "not x86_64", "an arm64 image");
    refused_build(RMF_PLAIN, poke_no_info, "no LC_DYLD_INFO", "no rebase stream");
    refused_build(RMF_DATARO, NULL, "is not writable", "D read-only");
    refused_build(RMF_NOSLOTRB, NULL, "file offset 0x1120 carries no rebase", "a method-list slot with no rebase");
    refused_build(RMF_SELBIND, NULL, "is bound to another image", "a bound selector reference");
    refused_build(RMF_FSBAD, NULL, "not one of the 3 function starts", "an IMP that is not a function start");
    refused_build(RMF_OOB, NULL, "runs past its segment", "a list the walk cannot read");
}

static void test_lists_past_4gb_are_refused_before_any_allocation(void) {
    mml_ref refs[3];
    mml_walk w;
    uint32_t first[3] = { 0, 1, 0 };
    uint64_t new_va[3] = { 0 }, total = 0;
    size_t nslots = 0;
    char why[256] = "";
    int rc;
    memset(&w, 0, sizeof w);
    memset(refs, 0, sizeof refs);
    w.refs = refs;
    w.n = 3;
    /* 8 + 24 * 178956970 is 2^32 - 8, the most 32 bits hold; ref 1 is an
     * absolute list and ref 2 names ref 0's list again, so neither counts. */
    refs[0].header = RMF_REL_HEADER; refs[0].list_va = 0x1000; refs[0].count = 178956970;
    refs[1].header = RMF_ABS_HEADER; refs[1].list_va = 0x2000; refs[1].count = 0xffffffffu;
    refs[2] = refs[0];
    rc = mma_room(&w, first, RMF_VA(RMF_LINKEDIT), new_va, &total, &nslots, why, sizeof why);
    CHECK(rc == MMA_OK && total == 0xfffffff8u && nslots == 3u * 178956970u &&
          new_va[0] == RMF_VA(RMF_LINKEDIT), "room at 2^32 - 8: rc %d, total %#llx, %zu slots (%s)",
          rc, (unsigned long long)total, nslots, why);
    refs[0].count++;
    rc = mma_room(&w, first, RMF_VA(RMF_LINKEDIT), new_va, &total, &nslots, why, sizeof why);
    CHECK(rc == MMA_REFUSED && strstr(why, "pass 4GB") != NULL, "room at 2^32 + 16: rc %d, why '%s'",
          rc, why);
    /* two lists whose 3 * entries is 0x240000000, 0x40000000 in 32 bits */
    refs[0].count = 0x60000000u;
    refs[1] = refs[0];
    refs[1].list_va = 0x2000;
    first[2] = 2;
    refs[2].header = RMF_ABS_HEADER;
    why[0] = 0;
    rc = mma_room(&w, first, RMF_VA(RMF_LINKEDIT), new_va, &total, &nslots, why, sizeof why);
    CHECK(rc == MMA_REFUSED && strstr(why, "pass 4GB") != NULL, "room whose slots wrap: rc %d, why '%s'",
          rc, why);
}

static void test_new_rebases_name_ds_own_segment(void) {
    mma_out o;
    mrb_set now;
    char why[256] = "";
    int rc = build(RMF_DYLIB, NULL, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "dylib rebases: rc %d (%s)", rc, why);
    if (rc != MMA_OK) return;
    lcs_of out = lcs(o.buf, o.size);
    CHECK(mrb_decode(o.buf + out.di->rebase_off, out.di->rebase_size, out.nsegs, &now, NULL, 0) == MRB_OK,
          "dylib rebases: the stream does not decode");
    mrb_sort(&now);
    for (uint64_t off = 0x1008; off < 0x1038; off += 8)
        CHECK(mrb_has(&now, 1, off) && !mrb_has(&now, 2, off),
              "dylib rebases: list A's pointer at D+%#llx is not rebased in segment 1, __DATA",
              (unsigned long long)off);
    mrb_free(&now);
    mma_out_free(&o);
}

/* Rewrites the plain fixture's rebase stream to rebase each of its slots in
 * turn, the one at __DATA offset `abs32` (when nonzero) as TEXT_ABSOLUTE32,
 * then __LINKEDIT offset `linkedit` (when nonzero) as a pointer. */
static void restream(uint8_t *b, uint32_t abs32, uint32_t linkedit) {
    struct dyld_info_command *di = info_of(b);
    uint32_t slots[32], n = rmf_rebase_slots(RMF_PLAIN, slots), at = RMF_REBASE;
    for (uint32_t i = 0; i < n; i++) {
        b[at++] = REBASE_OPCODE_SET_TYPE_IMM |
                  ((abs32 && slots[i] == abs32) ? REBASE_TYPE_TEXT_ABSOLUTE32 : REBASE_TYPE_POINTER);
        b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
        at += rmf_uleb(b + at, slots[i]);
        b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
    }
    if (linkedit) {
        b[at++] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER;
        b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 3;
        at += rmf_uleb(b + at, linkedit);
        b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
    }
    b[at++] = REBASE_OPCODE_DONE;
    memset(b + at, 0, RMF_SYMS - at);
    di->rebase_size = (at - RMF_REBASE + 7) & ~7u;
}

#define RMF_LINKEDIT_RO 0x21a0u

static void poke_slot_abs32(uint8_t *b) { restream(b, RMF_CLASS_RO + 32 - RMF_DATA, 0); }
static void poke_restream(uint8_t *b)   { restream(b, 0, 0); }

/* The class's data word names a copy of its ro in __LINKEDIT, whose
 * baseMethods slot is rebased as a pointer. */
static void poke_ro_in_linkedit(uint8_t *b) {
    memcpy(b + RMF_LINKEDIT_RO, b + RMF_CLASS_RO, 0x48);
    rmf_put64(b, RMF_CLASS + 32, RMF_VA(RMF_LINKEDIT_RO));
    restream(b, 0, RMF_LINKEDIT_RO + 32 - RMF_LINKEDIT);
}

/* The category names a copy of its absolute list, in __LINKEDIT. */
static void poke_abs_in_linkedit(uint8_t *b) {
    memcpy(b + RMF_LINKEDIT_RO, b + RMF_ABS_C, 8 + 24);
    rmf_put64(b, RMF_CATEGORY + 16, RMF_VA(RMF_LINKEDIT_RO));
}

static void test_slots_the_conversion_cannot_rewrite_are_refused(void) {
    mma_out o;
    char why[256] = "";
    int rc = build(RMF_PLAIN, poke_restream, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "restreamed: rc %d (%s)", rc, why);
    mma_out_free(&o);
    refused_build(RMF_PLAIN, poke_slot_abs32, "file offset 0x1120 is rebased as TEXT_ABSOLUTE32",
                  "a method-list slot rebased as 32 bits");
    refused_build(RMF_PLAIN, poke_ro_in_linkedit, "file offset 0x21c0 lies in __LINKEDIT",
                  "a method-list slot in __LINKEDIT");
    refused_build(RMF_ABSCAT, poke_abs_in_linkedit, "absolute method list at file offset 0x21a0 "
                  "lies in __LINKEDIT", "an absolute list in __LINKEDIT");
}

/* ---- verification ------------------------------------------------------------ */

static void test_every_conversion_verifies(void) {
    static const unsigned variants[] = {
        RMF_PLAIN, RMF_ALLSLOTS, RMF_SHARED, RMF_ABSCAT, RMF_SWIFT, RMF_NLCLS, RMF_SHAREDRO,
        RMF_ZEROTAIL, RMF_DYLIB, RMF_CODESIG | RMF_SPLIT, RMF_FSTARTS, RMF_PAD16,
        RMF_COMPACT | RMF_ALLSLOTS,
    };
    for (size_t k = 0; k < sizeof variants / sizeof variants[0]; k++) {
        mma_out o;
        mi_image in;
        char why[512] = "";
        int rc = build(variants[k], NULL, &o, why, sizeof why);
        CHECK(rc == MMA_OK, "variant %#x: build rc %d (%s)", variants[k], rc, why);
        if (rc != MMA_OK) continue;
        mi_wrap(fx, RMF_SIZE, &in);
        rc = mma_verify(&in, &o, why, sizeof why);
        CHECK(rc == MMA_OK, "variant %#x: verify rc %d (%s)", variants[k], rc, why);
        mma_out_free(&o);
    }
}

typedef void (*corrupt_fn)(mma_out *o);

static uint64_t stream_at(const mma_out *o) { return o->lay.insert + o->lay.z + o->s; }

static void c_name(mma_out *o)    { o->buf[o->lay.insert + o->lay.z + 8] ^= 0x10; }
static void c_types(mma_out *o)   { o->buf[o->lay.insert + o->lay.z + 16] ^= 1; }
static void c_imp(mma_out *o)     { o->buf[o->lay.insert + o->lay.z + 24] ^= 4; }
static void c_relative(mma_out *o) { rmf_put64(o->buf, RMF_CLASS_RO + 32, RMF_VA(RMF_LIST_A)); }
static void c_absolute(mma_out *o) { rmf_put64(o->buf, RMF_CATEGORY + 16, RMF_VA(RMF_LINKEDIT)); }
static void c_split(mma_out *o)   {
    /* the protocol's third slot, one of three naming list B, names the new
     * list C: converted, of B's one entry, but not B */
    rmf_put64(o->buf, RMF_PROTOCOL + 40, slot_value(o->buf, RMF_CATEGORY + 16));
}
static void c_drop_rebase(mma_out *o) {
    mrb_set set;
    mrb_decode(o->buf + stream_at(o), o->r, 4, &set, NULL, 0);
    o->buf[stream_at(o) + set.end - 1]--;
    mrb_free(&set);
}
static void c_add_rebase(mma_out *o) {
    mrb_set set;
    mrb_decode(o->buf + stream_at(o), o->r, 4, &set, NULL, 0);
    o->buf[stream_at(o) + set.end - 1]++;
    mrb_free(&set);
}
static void c_move_rebase(mma_out *o) {
    /* list D's run, SET_SEGMENT_AND_OFFSET_ULEB 2 0x1080 then two, starts at 0x1078 instead */
    mrb_set set;
    mrb_decode(o->buf + stream_at(o), o->r, 4, &set, NULL, 0);
    o->buf[stream_at(o) + set.end - 3] = 0xf8;
    o->buf[stream_at(o) + set.end - 2] = 0x20;
    mrb_free(&set);
}
/* The input's stream opens with SET_TYPE_IMM POINTER, and the new pointers'
 * run with another where the input's DONE was: each poke makes one of them
 * TEXT_ABSOLUTE32, which would slide only a pointer's low half. */
static void c_retype_old(mma_out *o) {
    o->buf[stream_at(o)] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_TEXT_ABSOLUTE32;
}
static void c_retype_new(mma_out *o) {
    mrb_set was;
    lcs_of in = lcs(fx, RMF_SIZE);
    mrb_decode(fx + in.di->rebase_off, in.di->rebase_size, 4, &was, NULL, 0);
    o->buf[stream_at(o) + was.end] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_TEXT_ABSOLUTE32;
    mrb_free(&was);
}
static void c_dvmsize(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.d)->vmsize += MMA_PAGE; }
static void c_lfilesize(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.l)->filesize -= 8; }
static void c_lvmaddr(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.l)->vmaddr += MMA_PAGE; }
static void c_dfilesize(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.d)->filesize -= 8; }
static void c_lfileoff(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.l)->fileoff += 8; }
static void c_lvmsize(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct segment_command_64 *)(uintptr_t)c.l)->vmsize += MMA_PAGE; }
static void c_truncate(mma_out *o) { o->size -= 8; }
static void c_lay_d(mma_out *o) { o->lay.d = lcs(o->buf, o->size).nsegs; }
static void c_lay_l(mma_out *o) { o->lay.l = 1; }
/* rebase_off names a copy of the stream, in the zeros past the lists */
static void c_rebase_off(mma_out *o) {
    lcs_of c = lcs(o->buf, o->size);
    uint64_t copy = o->lay.insert + o->lay.z + 0x800;
    memcpy(o->buf + copy, o->buf + stream_at(o), o->r);
    ((struct dyld_info_command *)(uintptr_t)c.di)->rebase_off = (uint32_t)copy;
}
static void c_rebase_size(mma_out *o) { lcs_of c = lcs(o->buf, o->size); ((struct dyld_info_command *)(uintptr_t)c.di)->rebase_size += 8; }
static void c_symoff(mma_out *o)  { lcs_of c = lcs(o->buf, o->size); ((struct symtab_command *)(uintptr_t)c.st)->symoff += 8; }
static void c_nsyms(mma_out *o)   { lcs_of c = lcs(o->buf, o->size); ((struct symtab_command *)(uintptr_t)c.st)->nsyms += 1; }
static void c_below(mma_out *o)   { o->buf[RMF_DATA_TAIL] ^= 0xff; }
static void c_zerofill(mma_out *o) { o->buf[o->lay.insert] = 1; }
static void c_past_lists(mma_out *o) { o->buf[o->lay.insert + o->lay.z + o->s - 1] = 1; }
static void c_linkedit(mma_out *o) { o->buf[o->size - 1] ^= 0xff; }
static void c_old_stream(mma_out *o) { o->buf[RMF_REBASE + o->lay.z + o->s + o->r] = 0x11; }

static void refused_verify(unsigned variant, void (*poke)(uint8_t *), corrupt_fn corrupt,
                           const char *want, const char *label) {
    mma_out o;
    mi_image in;
    char why[512] = "";
    int rc = build(variant, poke, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "%s: build rc %d (%s)", label, rc, why);
    if (rc != MMA_OK) return;
    if (corrupt) corrupt(&o);
    mi_wrap(fx, RMF_SIZE, &in);
    rc = mma_verify(&in, &o, why, sizeof why);
    CHECK(rc == MMA_REFUSED, "%s: verify rc %d, want MMA_REFUSED", label, rc);
    CHECK(strstr(why, want) != NULL, "%s: why '%s' lacks '%s'", label, why, want);
    mma_out_free(&o);
}

static void poke_text_over_data(uint8_t *b) {
    mi_image im;
    struct segment_command_64 *t;
    if (mi_wrap(b, RMF_SIZE, &im) == 0 && (t = mi_find_segment(&im, "__TEXT"))) t->vmsize = 0x2000;
}

/* The plain fixture's rebases, then one more of `type` at __DATA+`off`. */
static void restream_plus(uint8_t *b, uint8_t type, uint32_t off) {
    struct dyld_info_command *di = info_of(b);
    uint32_t slots[32], n = rmf_rebase_slots(RMF_PLAIN, slots), at = RMF_REBASE;
    for (uint32_t i = 0; i < n; i++) {
        b[at++] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER;
        b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
        at += rmf_uleb(b + at, slots[i]);
        b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
    }
    b[at++] = REBASE_OPCODE_SET_TYPE_IMM | type;
    b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
    at += rmf_uleb(b + at, off);
    b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
    b[at++] = REBASE_OPCODE_DONE;
    memset(b + at, 0, RMF_SYMS - at);
    di->rebase_size = (at - RMF_REBASE + 7) & ~7u;
}

/* The input rebases __DATA+0x1008, past __DATA's end, where the first new
 * list's first name pointer goes. */
static void poke_rebase_past_d(uint8_t *b) { restream_plus(b, REBASE_TYPE_POINTER, 0x1008); }

/* List A entry 0's selector reference, rebased as TEXT_ABSOLUTE32 as well. */
static void poke_rebase_both_ways(uint8_t *b) {
    restream_plus(b, REBASE_TYPE_TEXT_ABSOLUTE32, RMF_SELREFS + 8 - RMF_DATA);
}

/* __DATA+0, rebased twice as a pointer. */
static void poke_rebase_twice(uint8_t *b) { restream_plus(b, REBASE_TYPE_POINTER, 0); }

/* The copied old stream's last run, poke_rebase_twice's second rebase of
 * __DATA+0, rebases __DATA+0x70 instead: the same number of rebases, and
 * every one the input had still present at least once. */
static void c_twice_moved(mma_out *o) {
    mrb_set was;
    lcs_of in = lcs(fx, RMF_SIZE);
    uint8_t *run;
    mrb_decode(fx + in.di->rebase_off, in.di->rebase_size, 4, &was, NULL, 0);
    run = o->buf + stream_at(o) + was.end - 4;
    CHECK(run[0] == 0x11 && run[1] == 0x22 && run[2] == 0 && run[3] == 0x51,
          "twice moved: the old stream's last run is %02x %02x %02x %02x", run[0], run[1], run[2], run[3]);
    run[2] = 0x70;
    mrb_free(&was);
}

static void verifies(void (*poke)(uint8_t *), const char *label) {
    mma_out o;
    mi_image in;
    char why[512] = "";
    int rc = build(RMF_PLAIN, poke, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "%s: build rc %d (%s)", label, rc, why);
    if (rc != MMA_OK) return;
    mi_wrap(fx, RMF_SIZE, &in);
    rc = mma_verify(&in, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "%s: verify rc %d (%s)", label, rc, why);
    mma_out_free(&o);
}

static void test_a_slot_rebased_twice_verifies(void) {
    verifies(poke_rebase_both_ways, "both ways");
    verifies(poke_rebase_twice, "twice as a pointer");
}

/* The input rebases __LINKEDIT+0x100, whose bytes the new stream moves up. */
static void poke_rebase_linkedit(uint8_t *b) { restream(b, 0, 0x100); }

static void test_verification_refuses_every_difference(void) {
    refused_verify(RMF_PLAIN, NULL, c_name, "is not the entry it was", "an entry's name");
    refused_verify(RMF_PLAIN, NULL, c_types, "is not the entry it was", "an entry's types");
    refused_verify(RMF_PLAIN, NULL, c_imp, "is not the entry it was", "an entry's IMP");
    refused_verify(RMF_PLAIN, NULL, c_relative, "relative method lists", "a slot back on its relative list");
    refused_verify(RMF_ABSCAT, NULL, c_absolute, "named an absolute list", "an absolute list's slot moved");
    refused_verify(RMF_ALLSLOTS, NULL, c_split, "now name two", "a shared list split in two");
    refused_verify(RMF_PLAIN, NULL, c_drop_rebase, "rebases; the old one had", "a new pointer's rebase dropped");
    refused_verify(RMF_PLAIN, NULL, c_move_rebase, "offset 0x1088 has no rebase", "a rebase on the wrong slot");
    refused_verify(RMF_PLAIN, NULL, c_add_rebase, "rebases; the old one had", "a rebase for an IMP of 0");
    refused_verify(RMF_PLAIN, NULL, c_retype_old, "old rebase of segment 2 offset 0x0, type 1, is gone", "an old rebase retyped");
    refused_verify(RMF_PLAIN, poke_rebase_twice, c_twice_moved, "the old rebase of segment 2 offset 0x0, "
                   "type 1, is gone", "one of two rebases of a slot moved");
    refused_verify(RMF_PLAIN, NULL, c_retype_new, "offset 0x1008 has no rebase", "a new pointer rebased as 32 bits");
    refused_verify(RMF_PLAIN, NULL, c_dvmsize, "vmsize/filesize", "D grown too far");
    refused_verify(RMF_PLAIN, NULL, c_lfilesize, "__LINKEDIT's geometry", "__LINKEDIT's size");
    refused_verify(RMF_PLAIN, NULL, c_lvmaddr, "__LINKEDIT's geometry", "__LINKEDIT's address");
    refused_verify(RMF_PLAIN, NULL, c_truncate, "the layout makes it", "a truncated output");
    refused_verify(RMF_PLAIN, NULL, c_lay_d, "the layout names D as segment 4", "a layout whose D is no segment");
    refused_verify(RMF_PLAIN, NULL, c_lay_l, "and __LINKEDIT as segment 1", "a layout whose __LINKEDIT is not last");
    refused_verify(RMF_PLAIN, NULL, c_dfilesize, "vmsize/filesize", "D's file bytes short");
    refused_verify(RMF_PLAIN, NULL, c_lvmsize, "__LINKEDIT's geometry", "__LINKEDIT's vm size");
    refused_verify(RMF_PLAIN, NULL, c_lfileoff, "__LINKEDIT's geometry", "__LINKEDIT's file offset");
    refused_verify(RMF_PLAIN, NULL, c_rebase_off, "rebase_off/size", "rebase_off naming a copy of the stream");
    refused_verify(RMF_PLAIN, poke_rebase_past_d, NULL, "offset 0x1008, past its end", "an input rebase where a new pointer goes");
    refused_verify(RMF_PLAIN, poke_rebase_linkedit, NULL, "rebases __LINKEDIT at offset 0x100", "an input rebase in __LINKEDIT");
    refused_verify(RMF_PLAIN, NULL, c_rebase_size, "rebase_off/size", "rebase_size past the stream");
    refused_verify(RMF_PLAIN, NULL, c_symoff, "__LINKEDIT offset", "symoff moved by the wrong amount");
    refused_verify(RMF_PLAIN, NULL, c_nsyms, "load-command byte", "a load-command field nothing edits");
    refused_verify(RMF_PLAIN, NULL, c_below, "below the insertion", "a byte below the insertion");
    refused_verify(RMF_ZEROTAIL, NULL, c_zerofill, "zero-fill byte", "a zero-fill byte");
    refused_verify(RMF_PLAIN, NULL, c_past_lists, "past the lists", "a byte past the lists");
    refused_verify(RMF_CODESIG, NULL, c_linkedit, "is not what it was", "a code-signature byte");
    refused_verify(RMF_PLAIN, NULL, c_old_stream, "the old rebase stream, zeroed", "the old stream left in place");
    refused_verify(RMF_PLAIN, poke_text_over_data, NULL, "overlap in memory", "segments that overlap");
}

static void test_convert_swaps_only_what_verifies(void) {
    static uint8_t pristine[RMF_SIZE];
    uint8_t *buf = malloc(RMF_SIZE), *was;
    size_t size = RMF_SIZE;
    mma_report rep;
    rmf_build(buf, RMF_PLAIN);
    was = buf;
    CHECK(mma_convert(&buf, &size, &rep) == 0 && buf != was && size > RMF_SIZE && rep.lists == 4,
          "convert plain: not replaced (%zu bytes, %u lists)", size, rep.lists);
    was = buf;
    CHECK(mma_convert(&buf, &size, &rep) == 0 && buf == was && rep.lists == 0,
          "convert again: replaced, or %u lists", rep.lists);
    free(buf);
    buf = malloc(RMF_SIZE);
    size = RMF_SIZE;
    rmf_build(buf, RMF_DATARO);
    memcpy(pristine, buf, RMF_SIZE);
    was = buf;
    CHECK(mma_convert(&buf, &size, &rep) == MR_REFUSED && buf == was && size == RMF_SIZE &&
          memcmp(buf, pristine, RMF_SIZE) == 0, "convert dataro: not refused, or the image touched");
    free(buf);
    /* mma_build takes this image; only verification refuses it */
    buf = malloc(RMF_SIZE);
    size = RMF_SIZE;
    rmf_build(buf, RMF_PLAIN);
    poke_text_over_data(buf);
    memcpy(pristine, buf, RMF_SIZE);
    was = buf;
    CHECK(mma_convert(&buf, &size, &rep) == MR_REFUSED && buf == was && size == RMF_SIZE &&
          memcmp(buf, pristine, RMF_SIZE) == 0, "convert overlapping: not refused, or the image touched");
    free(buf);
}

/* A bogus LC_DYLD_INFO_ONLY, its rebase stream far outside the file, ahead
 * of the real one. */
static void poke_info_bogus_first(uint8_t *b) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = (uint8_t *)info_of(b), *end = b + sizeof *h + h->sizeofcmds;
    struct dyld_info_command d;
    memmove(p + sizeof d, p, (size_t)(end - p));
    memset(&d, 0, sizeof d);
    d.cmd = LC_DYLD_INFO_ONLY;
    d.cmdsize = sizeof d;
    d.rebase_off = 0x7ffff000u;
    d.rebase_size = 0x10000u;
    memcpy(p, &d, sizeof d);
    h->ncmds++;
    h->sizeofcmds += sizeof d;
}

/* Last in main: before the guards they test, each of these read or wrote
 * past a buffer. */
static void test_build_refuses_what_would_overrun(void) {
    mma_out o;
    char why[256] = "";
    int rc = build(RMF_PLAIN, poke_rebase_to_eof, &o, why, sizeof why);
    CHECK(rc == MMA_OK, "a rebase stream ending at the end of the file: build rc %d (%s)", rc, why);
    if (rc == MMA_OK) mma_out_free(&o);
    refused_build(RMF_PLAIN, poke_info_bogus_first, "the image has 2 LC_DYLD_INFO commands",
                  "a bogus LC_DYLD_INFO_ONLY before the real one");
    refused_build(RMF_PLAIN, poke_rebase_past, "the rebase stream, 0x2200 bytes at 0x2000, runs past "
                  "the end of the file", "a rebase stream past the file");
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
    test_layout_puts_the_lists_at_the_end_of_data();
    test_layout_refusals();
    test_insert_moves_linkedit_up_behind_the_lists();
    test_insert_makes_the_zero_fill_file_bytes();
    test_insert_grows_linkedit_vm_to_cover_its_file_bytes();
    test_insert_never_grows_the_header();
    test_lists_past_4gb_are_refused_before_any_allocation();
    test_conversion_matches_the_oracle_in_order();
    test_every_new_pointer_is_rebased();
    test_every_slot_is_repointed_and_absolute_ones_kept();
    test_a_converted_image_has_nothing_to_convert();
    test_conversion_refusals_write_nothing();
    test_every_conversion_verifies();
    test_verification_refuses_every_difference();
    test_a_slot_rebased_twice_verifies();
    test_convert_swaps_only_what_verifies();
    test_new_rebases_name_ds_own_segment();
    test_slots_the_conversion_cannot_rewrite_are_refused();
    test_layout_refuses_ends_that_wrap();
    test_layout_refuses_a_segment_above_linkedit();
    test_layout_names_why_there_is_no_room();
    test_layout_takes_zero_fill_up_to_4gb();
    test_insert_refusals();
    test_insert_boundaries();
    test_a_selref_rebased_both_ways_still_resolves_as_pointer();
    test_an_imp_resolving_to_address_0_is_refused();
    test_an_unbased_image_names_its_own_refusal();
    test_insert_refuses_what_would_overrun();
    test_build_refuses_what_would_overrun();

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("objc_meth_test: 0 failure(s)\n");
    return 0;
}
