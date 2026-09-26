/* tests/linkedit_fixture.h -- a hand-built x86_64 dylib with every
 * __LINKEDIT piece ld64 writes for one, laid out in any order, for
 * tests/linkedit_order_test.c (in memory) and tests/mklinkedit.c (to a file).
 *
 * lkf_build(buf, layout, opts) writes the image into buf (LKF_CAP bytes) and
 * returns its size, or 0 for a layout it cannot read. `layout` names the
 * pieces in file order from __LINKEDIT's start: rebase bind weak lazy export
 * fstarts dic drs symtab indirect strtab sig. "+N" inserts N zero bytes, and
 * "@N" pads with zeros to a multiple of N. A piece the layout leaves out keeps
 * its canonical offset (a stale one, unless the layout happens to agree). A
 * size can follow a name: "strtab:36" gives the string table 36 bytes.
 *
 * LKF_CANON is the order ld64 writes and codesign_allocate wants. */
#ifndef LINKEDIT_FIXTURE_H
#define LINKEDIT_FIXTURE_H

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#define LKF_CAP   0x4000u
#define LKF_LE    0x2000u   /* __LINKEDIT's file offset */
#define LKF_TEXT  0x800u    /* __text's file offset */
#define LKF_CANON "rebase bind weak lazy export fstarts dic drs symtab indirect strtab @16 sig"

/* opts */
#define LKF_NOSIG      1u   /* no LC_CODE_SIGNATURE (leave "sig" out of the layout) */
#define LKF_NODYSYMTAB 2u   /* no LC_DYSYMTAB (leave "indirect" out) */
#define LKF_EXECUTE    4u   /* MH_EXECUTE, no LC_ID_DYLIB */
#define LKF_STATIC    16u   /* no MH_DYLDLINK: checkout uses symbol_string_at_end */
#define LKF_DEP        8u   /* an LC_LOAD_DYLIB, last, and the bind opcodes name it */

/* The load commands, in this order; LKF_LC_* are their indexes. */
enum { LKF_LC_TEXT, LKF_LC_DATA, LKF_LC_LINKEDIT, LKF_LC_ID, LKF_LC_DYLD_INFO,
       LKF_LC_SYMTAB, LKF_LC_DYSYMTAB, LKF_LC_FSTARTS, LKF_LC_DIC, LKF_LC_DRS,
       LKF_LC_SIG };

enum { LKF_REBASE, LKF_BIND, LKF_WEAK, LKF_LAZY, LKF_EXPORT, LKF_FSTARTS, LKF_DIC,
       LKF_DRS, LKF_SYMTAB, LKF_INDIRECT, LKF_STRTAB, LKF_SIG, LKF_NPIECES };

static const char *const lkf_names[LKF_NPIECES] = {
    "rebase", "bind", "weak", "lazy", "export", "fstarts", "dic", "drs",
    "symtab", "indirect", "strtab", "sig" };

/* Each piece's bytes. The streams are real opcodes: rebase __DATA+0; bind
 * _x (self) at __DATA+8; weak-bind _w at __DATA+0x10; lazy-bind _l (self)
 * at __DATA+0x18; an export trie with no exports. */
static const uint8_t lkf_rebase[8] = { 0x11, 0x21, 0x00, 0x51, 0x00 };
static const uint8_t lkf_bind[16] = { 0x30, 0x40, '_', 'x', 0, 0x51, 0x71, 0x08, 0x90, 0x00 };
static const uint8_t lkf_weak[16] = { 0x40, '_', 'w', 0, 0x51, 0x71, 0x10, 0x90, 0x00 };
static const uint8_t lkf_lazy[16] = { 0x71, 0x18, 0x30, 0x40, '_', 'l', 0, 0x90, 0x00 };
static const uint8_t lkf_export[16] = { 0x00, 0x00 };
static const uint8_t lkf_fstarts[8] = { 0x80, 0x10, 0x00 };
static const uint8_t lkf_drs[16] = { 0xfa, 0xde, 0x0c, 0x05, 0, 0, 0, 16 };
static const char lkf_strings[] = "\0_l\0_e\0_u";   /* 10 bytes, padded */

/* sizes in the canonical layout */
static const uint32_t lkf_sizes[LKF_NPIECES] = { 8, 16, 16, 16, 16, 8, 0, 16, 48, 12, 32, 64 };

static uint32_t lkf_rnd(uint32_t x, uint32_t a) { return (x + a - 1) / a * a; }
static struct dyld_info_command *lkf_di(uint8_t *b);

static uint8_t *lkf_lc(uint8_t *buf, int index) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *p = (uint8_t *)(h + 1);
    for (int i = 0; i < index && i < (int)h->ncmds; i++)
        p += ((struct load_command *)p)->cmdsize;
    return p;
}

/* The image's canonical load commands and the non-__LINKEDIT content. */
static uint8_t *lkf_header(uint8_t *buf, unsigned opts) {
    memset(buf, 0, LKF_CAP);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = (opts & LKF_EXECUTE) ? MH_EXECUTE : MH_DYLIB;
    h->flags = (opts & LKF_STATIC) ? MH_TWOLEVEL : MH_DYLDLINK | MH_TWOLEVEL;
    uint8_t *lc = (uint8_t *)(h + 1);

    struct segment_command_64 *tx = (struct segment_command_64 *)lc;
    struct section_64 *text = (struct section_64 *)(tx + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof *text;
    strcpy(tx->segname, "__TEXT");
    tx->vmsize = tx->filesize = 0x1000;
    tx->maxprot = tx->initprot = VM_PROT_READ | VM_PROT_EXECUTE;
    tx->nsects = 1;
    strncpy(text->sectname, "__text", sizeof text->sectname);
    strncpy(text->segname, "__TEXT", sizeof text->segname);
    text->addr = LKF_TEXT;
    text->size = 16;
    text->offset = LKF_TEXT;
    text->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    lc += tx->cmdsize;

    struct segment_command_64 *da = (struct segment_command_64 *)lc;
    struct section_64 *data = (struct section_64 *)(da + 1);
    da->cmd = LC_SEGMENT_64;
    da->cmdsize = sizeof *da + sizeof *data;
    strcpy(da->segname, "__DATA");
    da->vmaddr = 0x1000;
    da->vmsize = da->filesize = 0x1000;
    da->fileoff = 0x1000;
    da->maxprot = da->initprot = VM_PROT_READ | VM_PROT_WRITE;
    da->nsects = 1;
    strncpy(data->sectname, "__data", sizeof data->sectname);
    strncpy(data->segname, "__DATA", sizeof data->segname);
    data->addr = 0x1000;
    data->size = 0x20;
    data->offset = 0x1000;
    lc += da->cmdsize;

    struct segment_command_64 *le = (struct segment_command_64 *)lc;
    le->cmd = LC_SEGMENT_64;
    le->cmdsize = sizeof *le;
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = 0x2000;
    le->vmsize = 0x1000;
    le->fileoff = LKF_LE;
    le->maxprot = le->initprot = VM_PROT_READ;
    lc += le->cmdsize;
    h->ncmds = 3;

    if (!(opts & LKF_EXECUTE)) {
        struct dylib_command *id = (struct dylib_command *)lc;
        id->cmd = LC_ID_DYLIB;
        id->cmdsize = sizeof *id + 16;
        id->dylib.name.offset = sizeof *id;
        strcpy((char *)(id + 1), "/lkf.dylib");
        lc += id->cmdsize;
    } else {
        /* keep the indexes: an LC_UUID where the id would be */
        struct uuid_command *u = (struct uuid_command *)lc;
        u->cmd = LC_UUID;
        u->cmdsize = sizeof *u;
        lc += u->cmdsize;
    }
    h->ncmds++;

    struct dyld_info_command *di = (struct dyld_info_command *)lc;
    di->cmd = LC_DYLD_INFO_ONLY;
    di->cmdsize = sizeof *di;
    lc += di->cmdsize;
    struct symtab_command *st = (struct symtab_command *)lc;
    st->cmd = LC_SYMTAB;
    st->cmdsize = sizeof *st;
    st->nsyms = 3;
    lc += st->cmdsize;
    h->ncmds += 2;
    if (!(opts & LKF_NODYSYMTAB)) {
        struct dysymtab_command *dy = (struct dysymtab_command *)lc;
        dy->cmd = LC_DYSYMTAB;
        dy->cmdsize = sizeof *dy;
        dy->ilocalsym = 0; dy->nlocalsym = 1;
        dy->iextdefsym = 1; dy->nextdefsym = 1;
        dy->iundefsym = 2; dy->nundefsym = 1;
        dy->nindirectsyms = 3;
        lc += dy->cmdsize;
    } else {
        struct source_version_command *sv = (struct source_version_command *)lc;   /* keeps the indexes */
        sv->cmd = LC_SOURCE_VERSION;
        sv->cmdsize = sizeof *sv;
        lc += sv->cmdsize;
    }
    h->ncmds++;
    static const uint32_t led[3] = { LC_FUNCTION_STARTS, LC_DATA_IN_CODE, LC_DYLIB_CODE_SIGN_DRS };
    for (int k = 0; k < 3; k++) {
        struct linkedit_data_command *l = (struct linkedit_data_command *)lc;
        l->cmd = led[k];
        l->cmdsize = sizeof *l;
        lc += l->cmdsize;
        h->ncmds++;
    }
    if (!(opts & LKF_NOSIG)) {
        struct linkedit_data_command *l = (struct linkedit_data_command *)lc;
        l->cmd = LC_CODE_SIGNATURE;
        l->cmdsize = sizeof *l;
        lc += l->cmdsize;
        h->ncmds++;
    }
    if (opts & LKF_DEP) {
        struct dylib_command *d = (struct dylib_command *)lc;
        d->cmd = LC_LOAD_DYLIB;
        d->cmdsize = sizeof *d + 32;
        d->dylib.name.offset = sizeof *d;
        strcpy((char *)(d + 1), "/usr/lib/libSystem.B.dylib");
        lc += d->cmdsize;
        h->ncmds++;
    }
    h->sizeofcmds = (uint32_t)(lc - (uint8_t *)(h + 1));
    buf[LKF_TEXT] = 0xc3;   /* ret */
    return lc;
}

/* Where a piece's offset and size live, and its bytes. */
static void lkf_fields(uint8_t *buf, int piece, uint32_t **off, uint32_t **size,
                       uint32_t *count_scale) {
    *count_scale = 1;
    *size = NULL;
    *off = NULL;
    struct dyld_info_command *di = (struct dyld_info_command *)lkf_lc(buf, LKF_LC_DYLD_INFO);
    struct symtab_command *st = (struct symtab_command *)lkf_lc(buf, LKF_LC_SYMTAB);
    struct dysymtab_command *dy = (struct dysymtab_command *)lkf_lc(buf, LKF_LC_DYSYMTAB);
    switch (piece) {
    case LKF_REBASE: *off = &di->rebase_off; *size = &di->rebase_size; break;
    case LKF_BIND:   *off = &di->bind_off; *size = &di->bind_size; break;
    case LKF_WEAK:   *off = &di->weak_bind_off; *size = &di->weak_bind_size; break;
    case LKF_LAZY:   *off = &di->lazy_bind_off; *size = &di->lazy_bind_size; break;
    case LKF_EXPORT: *off = &di->export_off; *size = &di->export_size; break;
    case LKF_FSTARTS: case LKF_DIC: case LKF_DRS: {
        struct linkedit_data_command *l = (struct linkedit_data_command *)
            lkf_lc(buf, LKF_LC_FSTARTS + (piece - LKF_FSTARTS));
        *off = &l->dataoff; *size = &l->datasize;
        break;
    }
    case LKF_SYMTAB: *off = &st->symoff; *size = &st->nsyms; *count_scale = 16; break;
    case LKF_INDIRECT:
        if (dy->cmd != LC_DYSYMTAB) break;
        *off = &dy->indirectsymoff; *size = &dy->nindirectsyms; *count_scale = 4;
        break;
    case LKF_STRTAB: *off = &st->stroff; *size = &st->strsize; break;
    case LKF_SIG: {
        struct linkedit_data_command *l = (struct linkedit_data_command *)lkf_lc(buf, LKF_LC_SIG);
        if (l->cmd != LC_CODE_SIGNATURE) break;
        *off = &l->dataoff; *size = &l->datasize;
        break;
    }
    }
}

static void lkf_content(int piece, uint8_t *to, uint32_t size) {
    const uint8_t *src = NULL;
    uint32_t n = 0;
    uint8_t syms[48];
    uint8_t sig[64];
    uint8_t ind[12];
    switch (piece) {
    case LKF_REBASE:  src = lkf_rebase;  n = sizeof lkf_rebase; break;
    case LKF_BIND:    src = lkf_bind;    n = sizeof lkf_bind; break;
    case LKF_WEAK:    src = lkf_weak;    n = sizeof lkf_weak; break;
    case LKF_LAZY:    src = lkf_lazy;    n = sizeof lkf_lazy; break;
    case LKF_EXPORT:  src = lkf_export;  n = sizeof lkf_export; break;
    case LKF_FSTARTS: src = lkf_fstarts; n = sizeof lkf_fstarts; break;
    case LKF_DRS:     src = lkf_drs;     n = sizeof lkf_drs; break;
    case LKF_STRTAB:  src = (const uint8_t *)lkf_strings; n = sizeof lkf_strings; break;
    case LKF_SYMTAB: {
        struct nlist_64 *s = (struct nlist_64 *)syms;
        memset(syms, 0, sizeof syms);
        s[0].n_un.n_strx = 1; s[0].n_type = N_SECT;         s[0].n_sect = 1; s[0].n_value = LKF_TEXT;
        s[1].n_un.n_strx = 4; s[1].n_type = N_SECT | N_EXT; s[1].n_sect = 1; s[1].n_value = LKF_TEXT;
        s[2].n_un.n_strx = 7; s[2].n_type = N_UNDF | N_EXT;
        src = syms; n = sizeof syms;
        break;
    }
    case LKF_INDIRECT: {
        uint32_t v[3] = { 2, INDIRECT_SYMBOL_LOCAL, INDIRECT_SYMBOL_ABS };
        memcpy(ind, v, sizeof v);
        src = ind; n = sizeof ind;
        break;
    }
    case LKF_SIG:
        memset(sig, 0, sizeof sig);
        sig[0] = 0xfa; sig[1] = 0xde; sig[2] = 0x0c; sig[3] = 0xc0; sig[7] = 64;
        src = sig; n = sizeof sig;
        break;
    }
    memset(to, 0, size);
    if (src) memcpy(to, src, n < size ? n : size);
}

static size_t lkf_build(uint8_t *buf, const char *layout, unsigned opts) {
    lkf_header(buf, opts);
    /* Every piece at its canonical offset first, so one the layout leaves
     * out still has an offset (and size) to be stale with. */
    uint32_t at = LKF_LE;
    for (int p = 0; p < LKF_NPIECES; p++) {
        uint32_t *off, *size, scale;
        lkf_fields(buf, p, &off, &size, &scale);
        if (p == LKF_SIG) at = lkf_rnd(at, 16);
        if (off) { *off = at; *size = lkf_sizes[p] / scale; }
        at += lkf_sizes[p];
    }
    uint32_t canon_end = at;
    char words[512];
    strncpy(words, layout, sizeof words - 1);
    words[sizeof words - 1] = 0;
    at = LKF_LE;
    for (char *w = strtok(words, " "); w; w = strtok(NULL, " ")) {
        if (w[0] == '+') { at += (uint32_t)strtoul(w + 1, NULL, 0); continue; }
        if (w[0] == '@') { at = lkf_rnd(at, (uint32_t)strtoul(w + 1, NULL, 0)); continue; }
        char *colon = strchr(w, ':');
        uint32_t want = 0;
        int sized = 0;
        if (colon) { *colon = 0; want = (uint32_t)strtoul(colon + 1, NULL, 0); sized = 1; }
        int p;
        for (p = 0; p < LKF_NPIECES; p++) if (strcmp(w, lkf_names[p]) == 0) break;
        if (p == LKF_NPIECES) return 0;
        uint32_t *off, *size, scale;
        lkf_fields(buf, p, &off, &size, &scale);
        if (!off) return 0;
        uint32_t bytes = sized ? want : lkf_sizes[p];
        if (at + bytes > LKF_CAP) return 0;
        *off = at;
        *size = bytes / scale;
        lkf_content(p, buf + at, bytes);
        at += bytes;
    }
    if (at < LKF_LE) return 0;
    (void)canon_end;
    if (opts & LKF_DEP) buf[lkf_di(buf)->bind_off] = 0x11;   /* SET_DYLIB_ORDINAL_IMM 1 */
    struct segment_command_64 *le = (struct segment_command_64 *)lkf_lc(buf, LKF_LC_LINKEDIT);
    le->filesize = at - LKF_LE;
    if (le->filesize > le->vmsize) le->vmsize = lkf_rnd((uint32_t)le->filesize, 0x1000);
    return at;
}

/* ---- the variants ----
 * Each is a layout, options, and a poke applied after lkf_build; `tool` is
 * what 10.9's codesign_allocate (cctools-862) says, measured with
 * `codesign_allocate -i F -a x86_64 16384 -o OUT`, as mlo_check words it
 * ("…" for offsets and names), or NULL where it accepts; `corrupting` is
 * whether it then writes a piece's bytes somewhere else. */
typedef void (*lkf_poke)(uint8_t *buf, size_t *size);

static struct dyld_info_command *lkf_di(uint8_t *b) {
    return (struct dyld_info_command *)lkf_lc(b, LKF_LC_DYLD_INFO);
}
static struct symtab_command *lkf_st(uint8_t *b) {
    return (struct symtab_command *)lkf_lc(b, LKF_LC_SYMTAB);
}
static struct dysymtab_command *lkf_dy(uint8_t *b) {
    return (struct dysymtab_command *)lkf_lc(b, LKF_LC_DYSYMTAB);
}
static struct linkedit_data_command *lkf_led(uint8_t *b, int index) {
    return (struct linkedit_data_command *)lkf_lc(b, index);
}

static void lkf_patch(uint8_t *b, int index, uint32_t cmd) {
    ((struct load_command *)lkf_lc(b, index))->cmd = cmd;
}
static void lkf_stale_empty_rebase(uint8_t *b, size_t *n) {
    (void)n;
    lkf_di(b)->rebase_size = 0;
    lkf_di(b)->rebase_off = LKF_LE + 0x40;
}
static void lkf_no_rebase_no_bind(uint8_t *b, size_t *n) {
    (void)n;
    lkf_di(b)->rebase_off = lkf_di(b)->rebase_size = 0;
    lkf_di(b)->bind_off = lkf_di(b)->bind_size = 0;
}
static void lkf_no_rebase(uint8_t *b, size_t *n) {
    (void)n;
    lkf_di(b)->rebase_off = lkf_di(b)->rebase_size = 0;
}
static void lkf_dic_at_0(uint8_t *b, size_t *n) {
    (void)n;
    lkf_led(b, LKF_LC_DIC)->dataoff = 0;
}
static void lkf_syms_misordered(uint8_t *b, size_t *n) {
    (void)n;
    lkf_dy(b)->iextdefsym = 2;
    lkf_dy(b)->iundefsym = 1;
}
static void lkf_linkedit_short(uint8_t *b, size_t *n) {
    (void)n;
    ((struct segment_command_64 *)lkf_lc(b, LKF_LC_LINKEDIT))->filesize -= 16;
}
static void lkf_drs_empty_stale(uint8_t *b, size_t *n) {
    (void)n;
    lkf_led(b, LKF_LC_DRS)->datasize = 0;
    lkf_led(b, LKF_LC_DRS)->dataoff = LKF_LE + 0x40;
}
static void lkf_no_id(uint8_t *b, size_t *n) {
    (void)n;
    lkf_patch(b, LKF_LC_ID, LC_RPATH);   /* same shape: an lc_str at 24 */
}
static void lkf_uuid_to_bv(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_ID, 0x32); }
static void lkf_dic_to_note(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_DIC, 0x31); }
static void lkf_dic_to_trie(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_DIC, 0x80000033); }
static void lkf_dic_to_fvmfile(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_DIC, 0x9); }
static void lkf_dic_to_prepage(uint8_t *b, size_t *n) { (void)n; lkf_patch(b, LKF_LC_DIC, 0xa); }
static void lkf_dic_to_fstarts(uint8_t *b, size_t *n) {
    (void)n;
    lkf_patch(b, LKF_LC_DIC, LC_FUNCTION_STARTS);
}
static void lkf_id_offset(uint8_t *b, size_t *n) {
    (void)n;
    struct dylib_command *id = (struct dylib_command *)lkf_lc(b, LKF_LC_ID);
    id->dylib.name.offset = id->cmdsize;
}
static void lkf_hints0(uint8_t *b, size_t *n) {
    (void)n;
    /* the empty data-in-code command becomes an empty LC_TWOLEVEL_HINTS */
    struct twolevel_hints_command *h = (struct twolevel_hints_command *)lkf_lc(b, LKF_LC_DIC);
    h->cmd = LC_TWOLEVEL_HINTS;
    h->offset = 0;
    h->nhints = 0;
}
static void lkf_no_room(uint8_t *b, size_t *n) {
    (void)n;
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    struct section_64 *text = (struct section_64 *)(lkf_lc(b, LKF_LC_TEXT) + sizeof(struct segment_command_64));
    text->offset = (uint32_t)sizeof *h + h->sizeofcmds + 8;
    text->addr = text->offset;
}
static void lkf_strtab_past_end(uint8_t *b, size_t *n) {
    (void)n;
    lkf_st(b)->strsize += 0x1000;
}
static void lkf_fstarts0(uint8_t *b, size_t *n) {
    (void)n;
    lkf_led(b, LKF_LC_FSTARTS)->dataoff = 0;
}
static void lkf_nsyms0(uint8_t *b, size_t *n) {
    (void)n;
    struct dysymtab_command *dy = lkf_dy(b);
    lkf_st(b)->nsyms = 0;
    dy->nlocalsym = dy->nextdefsym = dy->nundefsym = 0;
    dy->ilocalsym = dy->iextdefsym = dy->iundefsym = 0;
    uint32_t *ind = (uint32_t *)(b + dy->indirectsymoff);
    ind[0] = INDIRECT_SYMBOL_LOCAL;
}

typedef struct {
    const char *name, *layout;
    unsigned opts;
    lkf_poke poke;
    const char *tool;
    int corrupting;
} lkf_variant;

#define LKF_TAIL "fstarts dic drs symtab indirect strtab @16 sig"
static const lkf_variant lkf_variants[] = {
    { "canonical", LKF_CANON, 0, NULL, NULL, 0 },
    { "canonical-unsigned", "rebase bind weak lazy export fstarts dic drs symtab indirect strtab",
      LKF_NOSIG, NULL, NULL, 0 },
    { "bind-first", "bind rebase weak lazy export " LKF_TAIL, 0, NULL,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "gap-before-rebase", "+8 rebase bind weak lazy export " LKF_TAIL, 0, NULL,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "export-inside", "rebase bind export weak lazy " LKF_TAIL, 0, NULL,
      "file not in an order that can be processed (function starts data out of place)", 0 },
    { "gap-after-export", "rebase bind weak lazy export +8 " LKF_TAIL, 0, NULL,
      "file not in an order that can be processed (function starts data out of place)", 0 },
    { "symtab-before-fstarts",
      "rebase bind weak lazy export symtab fstarts dic drs indirect strtab @16 sig", 0, NULL,
      "file not in an order that can be processed (function starts data out of place)", 0 },
    { "dic-stale", "rebase bind weak lazy export fstarts drs dic symtab indirect strtab @16 sig",
      0, NULL, "file not in an order that can be processed (data in code info out of place)", 0 },
    { "gap-before-symtab",
      "rebase bind weak lazy export fstarts dic drs +8 symtab indirect strtab @16 sig", 0, NULL,
      "file not in an order that can be processed (symbol table out of place)", 0 },
    { "strtab-first", "rebase bind weak lazy export fstarts dic drs strtab symtab indirect @16 sig",
      0, NULL, "file not in an order that can be processed (symbol table out of place)", 0 },
    { "strtab-past-rounding",
      "rebase bind weak lazy export fstarts dic drs symtab indirect @8 +8 strtab @16 sig", 0, NULL,
      "file not in an order that can be processed (string table out of place)", 0 },
    { "strtab-at-rounding",
      "rebase bind weak lazy export fstarts dic drs symtab indirect @8 strtab @16 sig", 0, NULL,
      NULL, 0 },
    { "sig-off-16", "rebase bind weak lazy export fstarts dic drs symtab indirect strtab +8 sig",
      0, NULL, "file not in an order that can be processed (code signature data out of place)", 0 },
    { "sig-late", "rebase bind weak lazy export fstarts dic drs symtab indirect strtab @16 +16 sig",
      0, NULL, "file not in an order that can be processed (code signature data out of place)", 0 },
    { "tail-after-sig", LKF_CANON " +16", 0, NULL,
      "file not in an order that can be processed (link edit information does not fill the "
      "__LINKEDIT segment)", 0 },
    { "tail-after-strtab",
      "rebase bind weak lazy export fstarts dic drs symtab indirect strtab +16", LKF_NOSIG, NULL,
      "file not in an order that can be processed (link edit information does not fill the "
      "__LINKEDIT segment)", 0 },
    { "stale-empty-rebase", "bind weak lazy export " LKF_TAIL, 0, lkf_stale_empty_rebase,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "no-rebase-no-bind", "weak lazy export " LKF_TAIL, 0, lkf_no_rebase_no_bind,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "export-last", "rebase bind weak lazy fstarts dic drs symtab indirect strtab @16 sig export",
      0, NULL, "file not in an order that can be processed (function starts data out of place)", 0 },
    { "bind-first-exec", "bind rebase weak lazy export " LKF_TAIL, LKF_EXECUTE, NULL,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "no-rebase-bind-late", "weak bind lazy export " LKF_TAIL, 0, lkf_no_rebase,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "dic-at-0", LKF_CANON, 0, lkf_dic_at_0, NULL, 0 },
    { "syms-misordered", LKF_CANON, 0, lkf_syms_misordered,
      "file not in an order that can be processed (externally defined symbols out of place)", 0 },
    { "linkedit-short", LKF_CANON, 0, lkf_linkedit_short,
      "the __LINKEDIT segment does not cover the end of the file (can't be processed)", 0 },
    { "drs-empty-stale", LKF_CANON, 0, lkf_drs_empty_stale,
      "file not in an order that can be processed (code signing DRs info out of place)", 0 },
    { "weak-lazy-empty-export", "weak lazy export:0 " LKF_TAIL, 0, lkf_no_rebase_no_bind,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
    { "strtab-at-rounding-unsigned",
      "rebase bind weak lazy export fstarts dic drs symtab indirect @8 strtab", LKF_NOSIG, NULL, NULL, 0 },
    { "no-id-dylib", LKF_CANON, 0, lkf_no_id,
      "malformed file (no LC_ID_DYLIB load command in MH_DYLIB file)", 0 },
    /* the load-command loop, symbol_string_at_end and header room */
    { "build-version", LKF_CANON, 0, lkf_uuid_to_bv, "malformed object (unknown load command 3)", 0 },
    { "note", LKF_CANON, 0, lkf_dic_to_note, "malformed object (unknown load command 8)", 0 },
    { "exports-trie", LKF_CANON, 0, lkf_dic_to_trie, "malformed object (unknown load command 8)", 0 },
    { "fvmfile", LKF_CANON, 0, lkf_dic_to_fvmfile, "malformed object (unknown load command 8)", 0 },
    { "prepage", LKF_CANON, 0, lkf_dic_to_prepage, "malformed object (unknown load command 8)", 0 },
    { "two-fstarts", LKF_CANON, 0, lkf_dic_to_fstarts,
      "malformed object (more than one LC_FUNCTION_STARTS command)", 0 },
    { "id-name-offset", LKF_CANON, 0, lkf_id_offset,
      "truncated or malformed object (name.offset field of LC_ID_DYLIB command 3 extends past the "
      "end of the file)", 0 },
    { "hints-0", LKF_CANON, 0, lkf_hints0,
      "malformed object (nhints in LC_TWOLEVEL_HINTS load command not the same as nundefsym in "
      "LC_DYSYMTAB load command)", 0 },
    { "no-room", "rebase bind weak lazy export fstarts dic drs symtab indirect strtab", LKF_NOSIG,
      lkf_no_room, "because larger updated load commands do not fit", 0 },
    { "fstarts-dataoff-0", "rebase bind weak lazy export +8 dic drs symtab indirect strtab @16 sig",
      0, lkf_fstarts0, "malformed object (…overlaps…)", 0 },
    { "strtab-past-end", LKF_CANON, 0, lkf_strtab_past_end,
      "truncated or malformed object (…extends past the end of the file)", 0 },
    { "no-dysymtab-strtab-first", "rebase bind weak lazy export fstarts dic drs strtab symtab @16 sig",
      LKF_NODYSYMTAB | LKF_EXECUTE, NULL,
      "string table not at the end of the file (can't be processed)", 0 },
    { "no-dysymtab-tail", "rebase bind weak lazy export fstarts dic drs symtab strtab @16 sig +16",
      LKF_NODYSYMTAB | LKF_EXECUTE, NULL,
      "code signature not at the end of the file (can't be processed)", 0 },
    { "no-dysymtab-linkedit-short",
      "rebase bind weak lazy export fstarts dic drs symtab strtab @16 sig",
      LKF_NODYSYMTAB | LKF_EXECUTE, lkf_linkedit_short, NULL, 0 },
    { "no-dysymtab-odd-strtab-unsigned",
      "rebase bind weak lazy export fstarts dic drs symtab strtab:35 @8",
      LKF_NOSIG | LKF_NODYSYMTAB | LKF_EXECUTE, NULL, NULL, 0 },
    /* the writer */
    { "hole-16", "rebase +16 bind weak lazy export " LKF_TAIL, 0, NULL, NULL, 1 },
    { "hole-absorbed", "rebase +4 bind weak lazy export " LKF_TAIL, 0, NULL, NULL, 0 },
    { "hole-16-unsigned",
      "rebase +16 bind weak lazy export fstarts dic drs symtab indirect strtab", LKF_NOSIG, NULL,
      NULL, 1 },
    { "nsyms-0", "rebase bind weak lazy export fstarts dic drs indirect strtab @16 sig", 0,
      lkf_nsyms0, NULL, 1 },
    { "nsyms-0-short-strtab", "rebase bind weak lazy export fstarts dic drs indirect strtab:4 @16 sig",
      0, lkf_nsyms0, NULL, 1 },
    { "no-dysymtab-drs8", "rebase bind weak lazy export +16 fstarts dic drs:8 symtab strtab @16 sig",
      LKF_NODYSYMTAB | LKF_EXECUTE, NULL, NULL, 1 },
    { "no-dysymtab-hole", "rebase bind weak lazy export +16 fstarts dic drs symtab strtab @16 sig",
      LKF_NODYSYMTAB | LKF_EXECUTE, NULL, NULL, 0 },
    { "hole-16-note", "rebase +16 bind weak lazy export " LKF_TAIL, 0, lkf_dic_to_note,
      "malformed object (unknown load command 8)", 1 },
    { "no-dysymtab-linkedit-short-hole",
      "rebase bind weak lazy export fstarts dic drs +8 symtab strtab @16 sig",
      LKF_NODYSYMTAB | LKF_EXECUTE, lkf_linkedit_short, NULL, 1 },
    { "no-dysymtab-unsigned-linkedit-short",
      "rebase bind weak lazy export fstarts dic drs symtab strtab",
      LKF_NOSIG | LKF_NODYSYMTAB | LKF_EXECUTE, lkf_linkedit_short, NULL, 1 },
    { "bind-first-static", "bind rebase weak lazy export " LKF_TAIL, LKF_EXECUTE | LKF_STATIC, NULL,
      NULL, 1 },
    { "no-dysymtab-unsigned-misaligned", "rebase bind weak lazy export fstarts dic drs +8 symtab strtab",
      LKF_NOSIG | LKF_NODYSYMTAB | LKF_EXECUTE, NULL, NULL, 1 },
    { "no-dysymtab-unsigned-drs8", "rebase bind weak lazy export fstarts dic drs:8 strtab symtab",
      LKF_NOSIG | LKF_NODYSYMTAB | LKF_EXECUTE, NULL,
      "string table not at the end of the file (can't be processed)", 0 },
    /* an LC_LOAD_DYLIB the bind names */
    { "canonical-dep", LKF_CANON, LKF_DEP, NULL, NULL, 0 },
    { "bind-first-dep", "bind rebase weak lazy export " LKF_TAIL, LKF_DEP, NULL,
      "file not in an order that can be processed (dyld_info out of place)", 0 },
};
#define LKF_NVARIANTS (sizeof lkf_variants / sizeof lkf_variants[0])

static size_t lkf_make(uint8_t *buf, const lkf_variant *v) {
    size_t n = lkf_build(buf, v->layout, v->opts);
    if (n && v->poke) v->poke(buf, &n);
    return n;
}

/* ---- short load commands ---- */

static struct mach_header_64 *lkf_short_header(uint8_t *b, uint32_t ncmds, uint32_t sizeofcmds) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_DYLIB;
    h->ncmds = ncmds;
    h->sizeofcmds = sizeofcmds;
    h->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL;
    return h;
}

/* A dylib with a UUID, __TEXT and __LINKEDIT whose last command is an 8-byte
 * LC_DYSYMTAB. Read as a whole one, it would name 8 bytes of indirect symbols
 * in __LINKEDIT. */
#define LKF_SHORT_LAST 0x168u
static size_t lkf_short_last(uint8_t *b) {
    memset(b, 0, LKF_SHORT_LAST);
    uint8_t *p = (uint8_t *)(lkf_short_header(b, 4, 0x100) + 1);
    struct uuid_command *u = (struct uuid_command *)p;
    u->cmd = LC_UUID;
    u->cmdsize = sizeof *u;
    memset(u->uuid, 0x11, sizeof u->uuid);
    p += u->cmdsize;
    struct segment_command_64 *tx = (struct segment_command_64 *)p;
    struct section_64 *s = (struct section_64 *)(tx + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof *s;
    strcpy(tx->segname, "__TEXT");
    tx->vmsize = 0x1000;
    tx->maxprot = tx->initprot = VM_PROT_READ | VM_PROT_EXECUTE;
    tx->nsects = 1;
    strncpy(s->sectname, "__text", sizeof s->sectname);
    strncpy(s->segname, "__TEXT", sizeof s->segname);
    s->addr = 0x100;
    s->offset = 0x120;
    s->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    p += tx->cmdsize;
    struct segment_command_64 *le = (struct segment_command_64 *)p;
    le->cmd = LC_SEGMENT_64;
    le->cmdsize = sizeof *le;
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = 0x1000;
    le->vmsize = 0x1000;
    le->fileoff = 0x120;
    le->filesize = 0x48;
    le->maxprot = le->initprot = VM_PROT_READ;
    p += le->cmdsize;
    struct load_command *dy = (struct load_command *)p;
    dy->cmd = LC_DYSYMTAB;
    dy->cmdsize = 8;
    struct dysymtab_command *whole = (struct dysymtab_command *)p;
    whole->indirectsymoff = 0x158;
    whole->nindirectsyms = 2;
    return LKF_SHORT_LAST;
}

#endif /* LINKEDIT_FIXTURE_H */
