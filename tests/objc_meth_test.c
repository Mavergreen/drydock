/* tests/objc_meth_test.c -- hermetic tests for src/objc_meth.c, against the
 * hand-built image in tests/relmeth_fixture.h. */
#include "objc_meth.h"
#include "objc_abs.h"
#include "image.h"
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

typedef struct { const struct segment_command_64 *d, *l; const struct dyld_info_command *di;
                 const struct symtab_command *st; const struct linkedit_data_command *cs, *sp;
                 int nsegs; } lcs_of;

static int note_lc(const struct load_command *lc, void *ctx_) {
    lcs_of *c = ctx_;
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
        if (strncmp(sc->segname, "__DATA", 16) == 0) c->d = sc;
        if (strncmp(sc->segname, "__LINKEDIT", 16) == 0) c->l = sc;
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
    test_a_selref_rebased_both_ways_still_resolves_as_pointer();
    test_an_imp_resolving_to_address_0_is_refused();
    test_an_unbased_image_names_its_own_refusal();

    if (fails) {
        printf("%d failure(s)\n", fails);
        return 1;
    }
    printf("objc_meth_test: 0 failure(s)\n");
    return 0;
}
