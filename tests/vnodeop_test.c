/*
 * tests/vnodeop_test.c -- hermetic tests for src/vnodeop.c, on kexts from
 * tests/kext_fixture.h.
 */
#include "vnodeop.h"
#include "kext_fixture.h"

#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

#define RENAME "_vnop_rename_desc"
#define RENAMEX KF_OLD

static const kf_entry both[] = { { RENAME, 0x10 }, { RENAMEX, 0x20 }, { NULL, 0 } };
static const char *const undefs[] = { "_a", RENAME, RENAMEX, "_z" };

static kf_spec spec2(const kf_entry *t1, const kf_entry *t2) {
    kf_spec s;
    memset(&s, 0, sizeof s);
    s.tables[0] = t1; s.tables[1] = t2; s.ntables = t2 ? 2 : 1;
    s.undefs = undefs; s.nundefs = 4; s.ndefs = 3;
    return s;
}

static void *find_lc(uint8_t *b, uint32_t cmd) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    uint8_t *p = b + sizeof *h;
    for (uint32_t i = 0; i < h->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmd == cmd) return lc;
        p += lc->cmdsize;
    }
    return NULL;
}
static struct symtab_command *symtab(uint8_t *b) { return find_lc(b, LC_SYMTAB); }
static struct dysymtab_command *dysymtab(uint8_t *b) { return find_lc(b, LC_DYSYMTAB); }

static struct nlist_64 *nlist_at(uint8_t *b, uint32_t i) {
    return (struct nlist_64 *)(b + symtab(b)->symoff + (size_t)i * sizeof(struct nlist_64));
}
static const char *sym_name(uint8_t *b, uint32_t i) {
    return (const char *)b + symtab(b)->stroff + nlist_at(b, i)->n_un.n_strx;
}
static uint32_t sym_index(uint8_t *b, const char *name) {
    for (uint32_t i = 0; i < symtab(b)->nsyms; i++)
        if (strcmp(sym_name(b, i), name) == 0) return i;
    return UINT32_MAX;
}
static struct relocation_info *ext_reloc(uint8_t *b, uint32_t i) {
    return (struct relocation_info *)(b + dysymtab(b)->extreloff + (size_t)i * 8);
}
static struct relocation_info *loc_reloc(uint8_t *b, uint32_t i) {
    return (struct relocation_info *)(b + dysymtab(b)->locreloff + (size_t)i * 8);
}
static struct relocation_info *ext_reloc_to(uint8_t *b, const char *name, unsigned nth) {
    for (uint32_t i = 0; i < dysymtab(b)->nextrel; i++) {
        struct relocation_info *r = ext_reloc(b, i);
        if (r->r_extern && strcmp(sym_name(b, r->r_symbolnum), name) == 0 && nth-- == 0) return r;
    }
    return NULL;
}
static unsigned ext_relocs_to(uint8_t *b, const char *name) {
    unsigned n = 0;
    while (ext_reloc_to(b, name, n)) n++;
    return n;
}

static uint8_t *dup(const uint8_t *b, size_t size) {
    uint8_t *c = malloc(size);
    memcpy(c, b, size);
    return c;
}

static void refuses(const char *what, uint8_t *b, size_t size, int want) {
    uint8_t *copy = dup(b, size);
    mvn_report r = { 9, 9, 9 };
    int rc = mvn_replace(b, size, RENAMEX, RENAME, &r);
    CHECK(rc == want, "%s: rc %d (%s), want %d (%s)", what, rc, mvn_reason(rc), want, mvn_reason(want));
    CHECK(memcmp(b, copy, size) == 0, "%s: buffer changed", what);
    free(copy);
}

static void refuses_spec(const char *what, const kf_spec *s, int want) {
    size_t size;
    uint8_t *b = kf_build(s, &size);
    refuses(what, b, size, want);
    free(b);
}

static void mark(uint8_t *changeable, size_t from, size_t len) { memset(changeable + from, 1, len); }

static void test_replaces_both_tables(void) {
    kf_spec s = spec2(both, both);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    uint8_t *before = dup(b, size);
    struct symtab_command st0 = *symtab(b);
    struct dysymtab_command dy0 = *dysymtab(b);
    uint32_t old_index = sym_index(b, RENAMEX);
    unsigned to_z = ext_relocs_to(b, "_z"), to_rename = ext_relocs_to(b, RENAME);
    CHECK(to_z > 0 && to_rename == 2 && ext_relocs_to(b, RENAMEX) == 2, "setup: relocations %u %u", to_z, to_rename);

    uint8_t *changeable = calloc(1, size);
    mark(changeable, st0.symoff, (size_t)st0.nsyms * sizeof(struct nlist_64));
    mark(changeable, dy0.extreloff, (size_t)dy0.nextrel * 8);
    mark(changeable, dy0.locreloff, (size_t)dy0.nlocrel * 8);
    mark(changeable, (size_t)((uint8_t *)symtab(b) - b), sizeof st0);
    mark(changeable, (size_t)((uint8_t *)dysymtab(b) - b), sizeof dy0);
    uint32_t old_at[2], new_at[2];
    for (unsigned k = 0; k < 2; k++) {
        old_at[k] = (uint32_t)ext_reloc_to(b, RENAMEX, k)->r_address;
        new_at[k] = (uint32_t)ext_reloc_to(b, RENAME, k)->r_address;
        mark(changeable, old_at[k], 16);
    }

    mvn_report r = { 0, 0, 0 };
    int rc = mvn_replace(b, size, RENAMEX, RENAME, &r);
    CHECK(rc == MVN_OK, "rc %d (%s)", rc, mvn_reason(rc));
    CHECK(r.entries == 2, "entries %u", r.entries);
    CHECK(r.removed_index == old_index, "removed_index %u, want %u", r.removed_index, old_index);
    CHECK(r.renumbered == to_z, "renumbered %u, want %u", r.renumbered, to_z);
    for (unsigned k = 0; k < 2; k++)
        CHECK(memcmp(b + old_at[k], b + new_at[k], 16) == 0, "entry %u not copied", k);
    CHECK(memcmp(b + old_at[0], before + old_at[0], 16) != 0, "setup: the entries were already equal");

    for (uint32_t i = 0; i < dy0.nextrel; i++) {
        struct relocation_info *was = ext_reloc(before, i), *is = ext_reloc(b, i);
        const char *want = sym_name(before, was->r_symbolnum);
        if (strcmp(want, RENAMEX) == 0) want = RENAME;
        CHECK(strcmp(sym_name(b, is->r_symbolnum), want) == 0, "extrel %u names %s, want %s",
              i, sym_name(b, is->r_symbolnum), want);
    }
    CHECK(ext_relocs_to(b, RENAME) == 4, "%u relocations to NEW", ext_relocs_to(b, RENAME));
    CHECK(symtab(b)->nsyms == st0.nsyms - 1, "nsyms %u", symtab(b)->nsyms);
    CHECK(dysymtab(b)->nundefsym == dy0.nundefsym - 1, "nundefsym %u", dysymtab(b)->nundefsym);
    CHECK(sym_index(b, RENAMEX) == UINT32_MAX, "OLD still in the symbol table");
    static const uint8_t zero[16];
    CHECK(memcmp(b + st0.symoff + (size_t)(st0.nsyms - 1) * 16, zero, 16) == 0, "symtab tail not zeroed");
    CHECK(memcmp(b + st0.stroff, before + st0.stroff, st0.strsize) == 0, "strtab changed");
    size_t stray = 0;
    for (size_t i = 0; i < size; i++)
        if (!changeable[i] && b[i] != before[i]) { if (!stray) printf("first stray change at 0x%zx\n", i); stray++; }
    CHECK(stray == 0, "%zu bytes changed outside symtab, relocations, entries and their commands", stray);

    refuses("second run", b, size, MVN_UNMATCHED);
    free(changeable); free(before); free(b);
}

static void test_new_after_old(void) {
    static const kf_entry t[] = { { RENAMEX, 0x20 }, { RENAME, 0x10 }, { NULL, 0 } };
    kf_spec s = spec2(t, NULL);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    uint32_t a = (uint32_t)ext_reloc_to(b, RENAMEX, 0)->r_address;
    int rc = mvn_replace(b, size, RENAMEX, RENAME, NULL);
    CHECK(rc == MVN_OK, "new after old: rc %d (%s)", rc, mvn_reason(rc));
    CHECK(memcmp(b + a, b + a + 16, 16) == 0, "new after old: entry not copied");
    free(b);
}

static void test_adjacent_tables_do_not_share(void) {
    static const kf_entry t1[] = { { RENAMEX, 0x20 }, { NULL, 0 } };
    static const kf_entry t2[] = { { RENAME, 0x10 }, { NULL, 0 } };
    kf_spec s = spec2(t1, t2);
    refuses_spec("NEW in the next table", &s, MVN_NEW_COUNT);
    s = spec2(t2, t1);
    refuses_spec("NEW in the previous table", &s, MVN_NEW_COUNT);
}

static void test_nonzero_base(void) {
    kf_spec s = spec2(both, both);
    s.base = 0x1000;
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    mvn_report r = { 0, 0, 0 };
    int rc = mvn_replace(b, size, RENAMEX, RENAME, &r);
    CHECK(rc == MVN_OK && r.entries == 2, "nonzero base: rc %d (%s), entries %u", rc, mvn_reason(rc), r.entries);
    free(b);
}

static void test_unmatched(void) {
    static const kf_entry t[] = { { RENAME, 0x10 }, { NULL, 0 } };
    static const char *const u[] = { "_a", RENAME, "_z" };
    kf_spec s = spec2(t, NULL);
    s.undefs = u; s.nundefs = 3;
    refuses_spec("unmatched", &s, MVN_UNMATCHED);
}

static void test_not_one_symbol(void) {
    static const char *const u[] = { "_a", RENAME, RENAMEX, RENAMEX, "_z" };
    kf_spec s = spec2(both, NULL);
    s.undefs = u; s.nundefs = 5;
    refuses_spec("duplicate OLD", &s, MVN_NOT_ONE_SYMBOL);
    static const char *const v[] = { "_a", RENAME, RENAME, RENAMEX, "_z" };
    s.undefs = v;
    refuses_spec("duplicate NEW", &s, MVN_NOT_ONE_SYMBOL);
    static const kf_entry t[] = { { RENAMEX, 0x20 }, { NULL, 0 } };
    static const char *const w[] = { "_a", RENAMEX, "_z" };
    s = spec2(t, NULL);
    s.undefs = w; s.nundefs = 3;
    refuses_spec("no NEW", &s, MVN_NOT_ONE_SYMBOL);
}

static void test_not_undefined(void) {
    kf_spec s = spec2(both, NULL);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    struct nlist_64 *n = nlist_at(b, sym_index(b, RENAMEX));
    n->n_type = N_SECT | N_EXT; n->n_sect = 1;
    refuses("defined OLD", b, size, MVN_NOT_UNDEFINED);
    free(b);
    b = kf_build(&s, &size);
    n = nlist_at(b, sym_index(b, RENAME));
    n->n_type = N_SECT | N_EXT; n->n_sect = 1;
    refuses("defined NEW", b, size, MVN_NOT_UNDEFINED);
    free(b);
}

static void test_unreferenced(void) {
    static const kf_entry t[] = { { RENAME, 0x10 }, { NULL, 0 } };
    kf_spec s = spec2(t, NULL);
    refuses_spec("unreferenced", &s, MVN_UNREFERENCED);
}

static void test_bad_reloc(void) {
    kf_spec s = spec2(both, NULL);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    ext_reloc_to(b, RENAMEX, 0)->r_pcrel = 1;
    refuses("pcrel OLD", b, size, MVN_BAD_RELOC);
    free(b);
    b = kf_build(&s, &size);
    ext_reloc_to(b, RENAMEX, 0)->r_length = 2;
    refuses("long OLD", b, size, MVN_BAD_RELOC);
    free(b);
    b = kf_build(&s, &size);
    ext_reloc_to(b, RENAME, 0)->r_pcrel = 1;
    refuses("pcrel NEW", b, size, MVN_BAD_RELOC);
    free(b);
    s.extra_reloc_at_old = 1;
    refuses_spec("extra relocation at OLD", &s, MVN_BAD_RELOC);
}

static void test_not_in_table(void) {
    kf_spec s = spec2(both, NULL);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    ext_reloc_to(b, RENAMEX, 0)->r_address = (int32_t)(KF_TEXT_OFF - 8);
    refuses("OLD outside every section", b, size, MVN_NOT_IN_TABLE);
    free(b);
    b = kf_build(&s, &size);
    struct segment_command_64 *data = (struct segment_command_64 *)((uint8_t *)find_lc(b, LC_SEGMENT_64)
                                                                    + ((struct load_command *)find_lc(b, LC_SEGMENT_64))->cmdsize);
    ((struct section_64 *)(data + 1))->flags = S_ZEROFILL;
    refuses("OLD in a zerofill section", b, size, MVN_NOT_IN_TABLE);
    free(b);
}

static void test_no_terminator(void) {
    kf_spec s = spec2(both, both);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    uint32_t a = (uint32_t)ext_reloc_to(b, RENAMEX, 1)->r_address;
    b[a + 16] = 1;
    refuses("no terminator", b, size, MVN_NO_TERMINATOR);
    free(b);
}

static void test_new_count(void) {
    static const kf_entry none[] = { { "_vnop_open_desc", 0x10 }, { RENAMEX, 0x20 }, { NULL, 0 } };
    static const char *const u[] = { "_a", "_vnop_open_desc", RENAME, RENAMEX, "_z" };
    kf_spec s = spec2(both, none);
    s.undefs = u; s.nundefs = 5;
    refuses_spec("no NEW entry", &s, MVN_NEW_COUNT);
    static const kf_entry two[] = { { RENAME, 0x10 }, { RENAMEX, 0x20 }, { RENAME, 0x30 }, { NULL, 0 } };
    s = spec2(two, NULL);
    refuses_spec("two NEW entries", &s, MVN_NEW_COUNT);
}

static void test_impl_mismatch(void) {
    kf_spec s = spec2(both, NULL);
    s.impl_reloc_kind_differs = 1;
    refuses_spec("implementation relocations differ", &s, MVN_IMPL_MISMATCH);
    size_t size;
    s.impl_reloc_kind_differs = 0;
    uint8_t *b = kf_build(&s, &size);
    for (uint32_t i = 0; i < dysymtab(b)->nlocrel; i++)
        if ((uint32_t)loc_reloc(b, i)->r_address == (uint32_t)ext_reloc_to(b, RENAMEX, 0)->r_address + 8)
            loc_reloc(b, i)->r_length = 2;
    refuses("implementation relocation lengths differ", b, size, MVN_IMPL_MISMATCH);
    free(b);
    b = kf_build(&s, &size);
    for (uint32_t i = 0; i < dysymtab(b)->nlocrel; i++)
        if ((uint32_t)loc_reloc(b, i)->r_address == (uint32_t)ext_reloc_to(b, RENAME, 0)->r_address + 8)
            loc_reloc(b, i)->r_address = (int32_t)(KF_TEXT_OFF - 8);
    refuses("implementation relocation counts differ", b, size, MVN_IMPL_MISMATCH);
    free(b);
}

static void test_stray_reference(void) {
    kf_spec s = spec2(both, NULL);
    s.stray_old_reloc = 1;
    refuses_spec("stray reference", &s, MVN_STRAY_REFERENCE);
}

static void test_dysymtab_shape(void) {
    kf_spec s = spec2(both, NULL);
    s.ntoc = 1;
    refuses_spec("ntoc", &s, MVN_DYSYMTAB_SHAPE);
    size_t size;
    s.ntoc = 0;
    const uint32_t off[] = { offsetof(struct dysymtab_command, nmodtab), offsetof(struct dysymtab_command, nextrefsyms),
                             offsetof(struct dysymtab_command, nindirectsyms) };
    for (unsigned i = 0; i < 3; i++) {
        uint8_t *b = kf_build(&s, &size);
        uint32_t one = 1;
        memcpy((uint8_t *)dysymtab(b) + off[i], &one, 4);
        refuses("nmodtab/nextrefsyms/nindirectsyms", b, size, MVN_DYSYMTAB_SHAPE);
        free(b);
    }
}

static struct load_command *nth_lc(uint8_t *b, unsigned n) {
    uint8_t *p = b + sizeof(struct mach_header_64);
    while (n--) p += ((struct load_command *)p)->cmdsize;
    return (struct load_command *)p;
}

static void test_section_relocations(void) {
    kf_spec s = spec2(both, NULL);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    struct section_64 *data = (struct section_64 *)((struct segment_command_64 *)nth_lc(b, 1) + 1);
    data->reloff = dysymtab(b)->extreloff; data->nreloc = 1;
    refuses("section relocations", b, size, MVN_DYSYMTAB_SHAPE);
    free(b);
}

static void test_twolevel_hints(void) {
    kf_spec s = spec2(both, NULL);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    nth_lc(b, 2)->cmd = LC_TWOLEVEL_HINTS;   /* was __LINKEDIT's LC_SEGMENT_64 */
    refuses("LC_TWOLEVEL_HINTS", b, size, MVN_DYSYMTAB_SHAPE);
    free(b);
}

static void test_undef_not_last(void) {
    kf_spec s = spec2(both, NULL);
    s.undef_not_last = 1;
    refuses_spec("undefined not last", &s, MVN_UNDEF_NOT_LAST);
}

static void test_extern_local_reloc(void) {
    kf_spec s = spec2(both, NULL);
    s.extern_local_reloc = 1;
    refuses_spec("external local relocation", &s, MVN_EXTERN_LOCAL_RELOC);
}

static void test_not_x86_64_kext(void) {
    kf_spec s = spec2(both, NULL);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    CHECK(mvn_is_x86_64_kext(b, size), "a kext is not a kext");
    CHECK(!mvn_is_x86_64_kext(b, 16), "a 16-byte kext");
    free(b);
    s.filetype = MH_BUNDLE;
    b = kf_build(&s, &size);
    CHECK(!mvn_is_x86_64_kext(b, size), "a bundle is a kext");
    refuses("bundle", b, size, MVN_NOT_X86_64_KEXT);
    free(b);
    s.filetype = 0;
    s.cputype = 0x0100000c;   /* CPU_TYPE_ARM64 */
    b = kf_build(&s, &size);
    CHECK(!mvn_is_x86_64_kext(b, size), "an arm64 kext is x86_64");
    refuses("arm64", b, size, MVN_NOT_X86_64_KEXT);
    free(b);
}

static void test_malformed(void) {
    kf_spec s = spec2(both, NULL);
    size_t size;
    uint8_t *b = kf_build(&s, &size);
    dysymtab(b)->extreloff = (uint32_t)size - 8;
    refuses("relocations past the end", b, size, MVN_MALFORMED);
    free(b);
    b = kf_build(&s, &size);
    nlist_at(b, sym_index(b, "_z"))->n_un.n_strx = symtab(b)->strsize;
    refuses("name past the string table", b, size, MVN_MALFORMED);
    free(b);
    b = kf_build(&s, &size);
    ext_reloc_to(b, "_z", 0)->r_symbolnum = symtab(b)->nsyms;
    refuses("relocation past the symbol table", b, size, MVN_MALFORMED);
    free(b);
}

static void test_reasons(void) {
    for (int rc = MVN_UNMATCHED; rc <= MVN_MALFORMED; rc++)
        CHECK(*mvn_reason(rc) != '\0', "no reason for %d", rc);
    CHECK(*mvn_reason(MVN_NOMEM) != '\0', "no reason for MVN_NOMEM");
}

int main(void) {
    test_replaces_both_tables();
    test_new_after_old();
    test_adjacent_tables_do_not_share();
    test_nonzero_base();
    test_unmatched();
    test_not_one_symbol();
    test_not_undefined();
    test_unreferenced();
    test_bad_reloc();
    test_not_in_table();
    test_no_terminator();
    test_new_count();
    test_impl_mismatch();
    test_stray_reference();
    test_dysymtab_shape();
    test_section_relocations();
    test_twolevel_hints();
    test_undef_not_last();
    test_extern_local_reloc();
    test_not_x86_64_kext();
    test_malformed();
    test_reasons();
    if (fails) { printf("%d failure(s)\n", fails); return 1; }
    printf("vnodeop_test: ok\n");
    return 0;
}
