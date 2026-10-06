/*
 * tests/symrename_test.c -- hermetic tests for src/symrename.c.
 *
 * Each object is built in memory: header, one empty LC_SEGMENT_64, LC_SYMTAB,
 * the nlist_64 entries, then the string table, last.
 */
#include "symrename.h"

#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/stab.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

typedef struct { const char *name; uint8_t type; uint32_t strx; int use_strx; uint64_t value; } sym;

typedef struct { uint8_t *buf; size_t size; size_t symoff, stroff, strsize; } obj;

#define NO_SYMTAB 1
#define TRAIL_JUNK 2
#define TRAIL_PAD 4

/* `pool` is the string table body after the leading NUL; entries with
 * use_strx point wherever they say, others are appended. */
static obj build(const sym *syms, int n, int flags, const char *extra_pool) {
    obj o;
    size_t lcs = sizeof(struct segment_command_64) + sizeof(struct symtab_command);
    if (flags & NO_SYMTAB) lcs = sizeof(struct segment_command_64);
    size_t symoff = sizeof(struct mach_header_64) + lcs;
    size_t stroff = symoff + (size_t)n * sizeof(struct nlist_64);
    char *pool = calloc(1, 8192 + (extra_pool ? strlen(extra_pool) : 0));
    size_t used = 1;
    if (extra_pool) { memcpy(pool + 1, extra_pool, strlen(extra_pool)); used += strlen(extra_pool) + 1; }
    uint32_t *strx = calloc(n ? n : 1, sizeof *strx);
    for (int i = 0; i < n; i++) {
        if (syms[i].use_strx) { strx[i] = syms[i].strx; continue; }
        strx[i] = (uint32_t)used;
        strcpy(pool + used, syms[i].name);
        used += strlen(syms[i].name) + 1;
    }
    size_t total = stroff + used;
    if (flags & TRAIL_PAD) total = (total + 7) & ~(size_t)7;
    if (flags & TRAIL_JUNK) total += 4;
    o.buf = calloc(1, total);
    o.size = total; o.symoff = symoff; o.stroff = stroff; o.strsize = used;
    struct mach_header_64 *h = (struct mach_header_64 *)o.buf;
    h->magic = MH_MAGIC_64; h->cputype = 0x01000007; h->cpusubtype = 3;
    h->filetype = MH_OBJECT; h->ncmds = (flags & NO_SYMTAB) ? 1 : 2; h->sizeofcmds = (uint32_t)lcs;
    struct segment_command_64 *sg = (struct segment_command_64 *)(o.buf + sizeof *h);
    sg->cmd = LC_SEGMENT_64; sg->cmdsize = sizeof *sg;
    if (!(flags & NO_SYMTAB)) {
        struct symtab_command *st = (struct symtab_command *)(o.buf + sizeof *h + sizeof *sg);
        st->cmd = LC_SYMTAB; st->cmdsize = sizeof *st;
        st->symoff = (uint32_t)symoff; st->nsyms = (uint32_t)n;
        st->stroff = (uint32_t)stroff; st->strsize = (uint32_t)used;
    }
    for (int i = 0; i < n; i++) {
        struct nlist_64 nl; memset(&nl, 0, sizeof nl);
        nl.n_un.n_strx = strx[i]; nl.n_type = syms[i].type; nl.n_value = syms[i].value;
        memcpy(o.buf + symoff + (size_t)i * sizeof nl, &nl, sizeof nl);
    }
    memcpy(o.buf + stroff, pool, used);
    if (flags & TRAIL_JUNK) memset(o.buf + total - 4, 0xAB, 4);
    free(pool); free(strx);
    return o;
}

static struct symtab_command *symtab_of(obj *o) {
    return (struct symtab_command *)(o->buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
}
static const char *name_of(obj *o, int i) {
    struct nlist_64 nl;
    memcpy(&nl, o->buf + o->symoff + (size_t)i * sizeof nl, sizeof nl);
    return (const char *)o->buf + o->stroff + nl.n_un.n_strx;
}

static int rename_obj(obj *o, const char *old, const char *new_, msr_report *r) {
    return msr_rename(&o->buf, &o->size, old, new_, r);
}

static void test_renames_defined_and_undefined(void) {
    sym s[] = { { "_foo", N_SECT | N_EXT, 0, 0, 0 }, { "_bar", N_SECT | N_EXT, 0, 0, 0 }, { "_foo", N_UNDF | N_EXT, 0, 0, 0 } };
    obj o = build(s, 3, 0, NULL);
    uint8_t *before = malloc(o.stroff + o.strsize);
    memcpy(before, o.buf + o.stroff, o.strsize);
    size_t old_size = o.size, old_strsize = o.strsize;
    msr_report r = {0};
    int rc = rename_obj(&o, "_foo", "_impl_foo", &r);
    CHECK(rc == MSR_OK, "rc %d", rc);
    CHECK(r.entries == 2, "entries %u", r.entries);
    CHECK(strcmp(name_of(&o, 0), "_impl_foo") == 0, "entry 0 is %s", name_of(&o, 0));
    CHECK(strcmp(name_of(&o, 1), "_bar") == 0, "entry 1 is %s", name_of(&o, 1));
    CHECK(strcmp(name_of(&o, 2), "_impl_foo") == 0, "entry 2 is %s", name_of(&o, 2));
    CHECK(symtab_of(&o)->strsize == old_strsize + strlen("_impl_foo") + 1, "strsize %u", symtab_of(&o)->strsize);
    CHECK(o.size == old_size + strlen("_impl_foo") + 1, "size %zu", o.size);
    CHECK(memcmp(before, o.buf + o.stroff, old_strsize) == 0, "old string bytes changed");
    free(before); free(o.buf);
}

static void test_renames_local(void) {
    sym s[] = { { "_loc", N_SECT, 0, 0, 0 } };
    obj o = build(s, 1, 0, NULL);
    msr_report r = {0};
    CHECK(rename_obj(&o, "_loc", "_other", &r) == MSR_OK && r.entries == 1, "local not renamed");
    CHECK(strcmp(name_of(&o, 0), "_other") == 0, "got %s", name_of(&o, 0));
    free(o.buf);
}

static void test_tail_shared_string_untouched(void) {
    sym s[] = { { "_bar_foo", N_SECT | N_EXT, 0, 0, 0 }, { NULL, N_SECT | N_EXT, 5, 1, 0 } };
    obj o = build(s, 2, 0, NULL);
    CHECK(strcmp(name_of(&o, 1), "_foo") == 0, "setup: tail-shared name is %s", name_of(&o, 1));
    msr_report r = {0};
    CHECK(rename_obj(&o, "_foo", "_impl_foo", &r) == MSR_OK && r.entries == 1, "rename failed");
    CHECK(strcmp(name_of(&o, 0), "_bar_foo") == 0, "_bar_foo became %s", name_of(&o, 0));
    CHECK(strcmp(name_of(&o, 1), "_impl_foo") == 0, "got %s", name_of(&o, 1));
    free(o.buf);
}

static void unchanged(const char *what, int rc, int want, obj *o, const uint8_t *copy, size_t size) {
    CHECK(rc == want, "%s: rc %d, want %d", what, rc, want);
    CHECK(o->size == size && memcmp(o->buf, copy, size) == 0, "%s: buffer changed", what);
}

static void test_unmatched(void) {
    sym s[] = { { "_bar", N_SECT | N_EXT, 0, 0, 0 } };
    obj o = build(s, 1, 0, NULL);
    uint8_t *copy = malloc(o.size); memcpy(copy, o.buf, o.size); size_t size = o.size;
    msr_report r = { 9 };
    unchanged("unmatched", rename_obj(&o, "_foo", "_x", &r), MSR_UNMATCHED, &o, copy, size);
    CHECK(r.entries == 0, "entries %u", r.entries);
    free(copy); free(o.buf);
}

static void test_no_symtab(void) {
    obj o = build(NULL, 0, NO_SYMTAB, NULL);
    uint8_t *copy = malloc(o.size); memcpy(copy, o.buf, o.size); size_t size = o.size;
    unchanged("no symtab", rename_obj(&o, "_foo", "_x", NULL), MSR_UNMATCHED, &o, copy, size);
    CHECK(msr_has(o.buf, o.size, "_foo") == 0, "msr_has on no symtab");
    free(copy); free(o.buf);
    obj z = build(NULL, 0, 0, NULL);
    copy = malloc(z.size); memcpy(copy, z.buf, z.size); size = z.size;
    unchanged("zero symbols", rename_obj(&z, "_foo", "_x", NULL), MSR_UNMATCHED, &z, copy, size);
    free(copy); free(z.buf);
}

static void test_same_name(void) {
    sym s[] = { { "_foo", N_SECT | N_EXT, 0, 0, 0 } };
    obj o = build(s, 1, 0, NULL);
    uint8_t *copy = malloc(o.size); memcpy(copy, o.buf, o.size); size_t size = o.size;
    unchanged("same", rename_obj(&o, "_foo", "_foo", NULL), MSR_SAME, &o, copy, size);
    free(copy); free(o.buf);
}

static void test_new_exists(void) {
    sym s[] = { { "_foo", N_SECT | N_EXT, 0, 0, 0 }, { "_new", N_UNDF | N_EXT, 0, 0, 0 } };
    obj o = build(s, 2, 0, NULL);
    uint8_t *copy = malloc(o.size); memcpy(copy, o.buf, o.size); size_t size = o.size;
    unchanged("exists", rename_obj(&o, "_foo", "_new", NULL), MSR_EXISTS, &o, copy, size);
    free(copy); free(o.buf);
}

static void test_strtab_not_last(void) {
    sym s[] = { { "_foo", N_SECT | N_EXT, 0, 0, 0 } };
    obj o = build(s, 1, TRAIL_JUNK, NULL);
    uint8_t *copy = malloc(o.size); memcpy(copy, o.buf, o.size); size_t size = o.size;
    unchanged("not last", rename_obj(&o, "_foo", "_new", NULL), MSR_STRTAB_NOT_LAST, &o, copy, size);
    free(copy); free(o.buf);
}

/* The bytes after the string table are claimed by one load command field, or
 * by none. A claim past the string table's end must refuse whatever the tail
 * holds, even with the file cut back to the string table. */
enum { CLAIM_NONE, CLAIM_SEGMENT, CLAIM_SECTION, CLAIM_RELOC, CLAIM_INDIRECT,
       CLAIM_EXTREL, CLAIM_DATA_IN_CODE, CLAIM_N };
static const char *claim_names[] = { "none", "segment", "section", "relocations",
                                     "indirect symbols", "external relocations", "data in code" };

typedef struct {
    struct mach_header_64 h; struct segment_command_64 sg; struct section_64 sec;
    struct symtab_command st; struct dysymtab_command dy; struct linkedit_data_command dic;
    uint8_t data[16]; struct nlist_64 nl[1]; char str[6]; uint8_t tail[2];
} claimed;

static void claimed_obj(claimed *o, int claim, uint8_t pad) {
    memset(o, 0, sizeof *o);
    uint32_t past = (uint32_t)offsetof(claimed, tail);
    o->h.magic = MH_MAGIC_64; o->h.cputype = 0x01000007; o->h.cpusubtype = 3; o->h.filetype = MH_OBJECT;
    o->h.ncmds = 4; o->h.sizeofcmds = sizeof o->sg + sizeof o->sec + sizeof o->st + sizeof o->dy + sizeof o->dic;
    o->sg.cmd = LC_SEGMENT_64; o->sg.cmdsize = sizeof o->sg + sizeof o->sec; o->sg.nsects = 1;
    o->sg.fileoff = offsetof(claimed, data); o->sg.filesize = sizeof o->data;
    memcpy(o->sec.sectname, "__data", 6); memcpy(o->sec.segname, "__DATA", 6);
    o->sec.offset = (uint32_t)offsetof(claimed, data); o->sec.size = sizeof o->data;
    o->st.cmd = LC_SYMTAB; o->st.cmdsize = sizeof o->st; o->st.nsyms = 1;
    o->st.symoff = (uint32_t)offsetof(claimed, nl);
    o->st.stroff = (uint32_t)offsetof(claimed, str); o->st.strsize = sizeof o->str;
    o->dy.cmd = LC_DYSYMTAB; o->dy.cmdsize = sizeof o->dy;
    o->dic.cmd = LC_DATA_IN_CODE; o->dic.cmdsize = sizeof o->dic;
    memcpy(o->str, "\0_foo\0", 6);
    o->nl[0].n_un.n_strx = 1; o->nl[0].n_type = N_SECT | N_EXT; o->nl[0].n_sect = 1;
    memset(o->tail, pad, sizeof o->tail);
    switch (claim) {
    case CLAIM_SEGMENT:      o->sg.filesize = past + 2 - o->sg.fileoff; break;
    case CLAIM_SECTION:      o->sec.offset = past; o->sec.size = 2; break;
    case CLAIM_RELOC:        o->sec.reloff = past; o->sec.nreloc = 1; break;
    case CLAIM_INDIRECT:     o->dy.indirectsymoff = past; o->dy.nindirectsyms = 1; break;
    case CLAIM_EXTREL:       o->dy.extreloff = past; o->dy.nextrel = 1; break;
    case CLAIM_DATA_IN_CODE: o->dic.dataoff = past; o->dic.datasize = 8; break;
    }
}

static void test_claimed_tail(void) {
    size_t end = offsetof(claimed, tail);
    CHECK(sizeof(claimed) == end + 2 && sizeof(claimed) % 8 == 0, "setup: a 2-byte tail to an 8-byte end");
    for (int claim = CLAIM_NONE; claim < CLAIM_N; claim++) {
        for (int trim = 0; trim < 2; trim++) {
            claimed c;
            claimed_obj(&c, claim, 0);
            size_t size = trim ? end : sizeof c;
            obj o = { malloc(size), size, offsetof(claimed, nl), end - sizeof c.str, sizeof c.str };
            memcpy(o.buf, &c, size);
            uint8_t *copy = malloc(size); memcpy(copy, o.buf, size);
            char what[96];
            snprintf(what, sizeof what, "claim %s, %s", claim_names[claim], trim ? "cut to its string table" : "with its tail");
            if (claim == CLAIM_NONE) {
                CHECK(rename_obj(&o, "_foo", "_impl_foo", NULL) == MSR_OK, "%s: rename refused", what);
            } else {
                unchanged(what, rename_obj(&o, "_foo", "_impl_foo", NULL), MSR_STRTAB_NOT_LAST, &o, copy, size);
            }
            free(copy); free(o.buf);
        }
    }
}

static void test_trailing_pad_kept(void) {
    sym s[] = { { "_foo", N_SECT | N_EXT, 0, 0, 0 } };
    obj o = build(s, 1, TRAIL_PAD, NULL);
    size_t old = o.size;
    CHECK(rename_obj(&o, "_foo", "_impl_foo", NULL) == MSR_OK, "rename failed");
    CHECK(o.size % 8 == 0 && o.size >= old, "size %zu not padded", o.size);
    CHECK(o.stroff + symtab_of(&o)->strsize <= o.size && o.size - (o.stroff + symtab_of(&o)->strsize) < 8, "pad too long");
    CHECK(strcmp(name_of(&o, 0), "_impl_foo") == 0, "got %s", name_of(&o, 0));
    free(o.buf);
}

static void test_long_new_name(void) {
    sym s[] = { { "_foo", N_SECT | N_EXT, 0, 0, 0 } };
    obj o = build(s, 1, 0, NULL);
    char *big = malloc(4097);
    memset(big, 'a', 4096); big[0] = '_'; big[4096] = '\0';
    size_t old_size = o.size, old_strsize = o.strsize;
    CHECK(rename_obj(&o, "_foo", big, NULL) == MSR_OK, "rename failed");
    CHECK(symtab_of(&o)->strsize == old_strsize + 4097, "strsize %u", symtab_of(&o)->strsize);
    CHECK(o.size == old_size + 4097, "size %zu", o.size);
    CHECK(strcmp(name_of(&o, 0), big) == 0, "name differs");
    CHECK(msr_has(o.buf, o.size, big) == 1, "msr_has misses the long name");
    free(big); free(o.buf);
}

static void test_malformed(void) {
    sym s[] = { { "_foo", N_SECT | N_EXT, 0, 0, 0 } };
    obj o = build(s, 1, 0, NULL);
    symtab_of(&o)->strsize += 100;
    uint8_t *copy = malloc(o.size); memcpy(copy, o.buf, o.size); size_t size = o.size;
    unchanged("strtab past end", rename_obj(&o, "_foo", "_x", NULL), MSR_MALFORMED, &o, copy, size);
    free(copy); free(o.buf);

    sym t[] = { { NULL, N_SECT | N_EXT, 9999, 1, 0 } };
    o = build(t, 1, 0, NULL);
    copy = malloc(o.size); memcpy(copy, o.buf, o.size); size = o.size;
    unchanged("n_strx past strtab", rename_obj(&o, "_foo", "_x", NULL), MSR_MALFORMED, &o, copy, size);
    free(copy); free(o.buf);

    obj p = build(s, 1, 0, NULL);
    symtab_of(&p)->nsyms = 1000000;
    copy = malloc(p.size); memcpy(copy, p.buf, p.size); size = p.size;
    unchanged("nsyms past end", rename_obj(&p, "_foo", "_x", NULL), MSR_MALFORMED, &p, copy, size);
    free(copy); free(p.buf);

    obj q = build(s, 1, 0, NULL);
    q.buf[q.size - 1] = 'x';
    copy = malloc(q.size); memcpy(copy, q.buf, q.size); size = q.size;
    unchanged("unterminated name", rename_obj(&q, "_foo", "_x", NULL), MSR_MALFORMED, &q, copy, size);
    free(copy); free(q.buf);
}

static int collect(const char *name, void *ctx) {
    char *out = ctx;
    strcat(out, name); strcat(out, ",");
    return 0;
}

static int stop_at_first(const char *name, void *ctx) { (void)name; (void)ctx; return 7; }

static void test_each_defined_external(void) {
    sym s[] = {
        { "_def", N_SECT | N_EXT, 0, 0, 0 },
        { "_local", N_SECT, 0, 0, 0 },
        { "_undef", N_UNDF | N_EXT, 0, 0, 0 },
        { "_common", N_UNDF | N_EXT, 0, 0, 16 },
        { "_abs", N_ABS | N_EXT, 0, 0, 0 },
        { "_pext", N_SECT | N_EXT | N_PEXT, 0, 0, 0 },
        { "_stab", N_FUN | N_EXT, 0, 0, 0 },
    };
    obj o = build(s, 7, 0, NULL);
    char out[256] = "";
    CHECK(msr_each_defined_external(o.buf, o.size, collect, out) == 0, "walk failed");
    CHECK(strcmp(out, "_def,_abs,_pext,") == 0, "got %s", out);
    CHECK(msr_each_defined_external(o.buf, o.size, stop_at_first, NULL) == 7, "stop not propagated");
    CHECK(msr_has(o.buf, o.size, "_common") == 1, "msr_has misses common");
    CHECK(msr_has(o.buf, o.size, "_nope") == 0, "msr_has false positive");
    free(o.buf);
}

static void test_reasons(void) {
    for (int rc = MSR_UNMATCHED; rc <= MSR_MALFORMED; rc++)
        CHECK(*msr_reason(rc) != '\0', "no reason for %d", rc);
}

int main(void) {
    test_renames_defined_and_undefined();
    test_renames_local();
    test_tail_shared_string_untouched();
    test_unmatched();
    test_no_symtab();
    test_same_name();
    test_new_exists();
    test_strtab_not_last();
    test_claimed_tail();
    test_trailing_pad_kept();
    test_long_new_name();
    test_malformed();
    test_each_defined_external();
    test_reasons();
    if (fails) { printf("%d failure(s)\n", fails); return 1; }
    printf("symrename_test: ok\n");
    return 0;
}
