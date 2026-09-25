/* tests/relmeth_fixture.h -- a hand-built x86_64 executable whose class,
 * metaclass, category and protocol name RELATIVE method lists, for
 * tests/objc_meth_test.c (in memory) and tests/mkrelmeth.c (to a file). No
 * linker on a 10.9 host emits relative method lists. File offsets equal vm
 * offsets from RMF_VMBASE throughout, so RMF_VA(off) is off's address. */
#ifndef RELMETH_FIXTURE_H
#define RELMETH_FIXTURE_H

#include <stdint.h>
#include <string.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>

#ifndef LC_DYLD_CHAINED_FIXUPS
#define LC_DYLD_CHAINED_FIXUPS 0x80000034
#endif

#define RMF_SIZE         0x2100u
#define RMF_VMBASE       0x100000000ULL
#define RMF_VA(off)      (RMF_VMBASE + (uint64_t)(off))

#define RMF_REL_HEADER   0x8000000cu
#define RMF_ABS_HEADER   0x00000018u

#define RMF_TEXT         0x800u
#define RMF_METHNAME     0x900u
#define RMF_METHTYPE     0x940u
#define RMF_METHLIST     0x980u
#define RMF_LIST_A       0x980u
#define RMF_LIST_B       0x9a0u
#define RMF_LIST_C       0x9b4u
#define RMF_LIST_D       0x9c8u
#define RMF_METHLIST_END 0x9dcu

#define RMF_DATA         0x1000u
#define RMF_CLASSLIST    0x1000u
#define RMF_NLCLSLIST    0x1008u
#define RMF_CATLIST      0x1010u
#define RMF_PROTOLIST    0x1020u
#define RMF_NLCATLIST    0x1028u
#define RMF_SELREFS      0x1040u
#define RMF_CONST        0x1100u
#define RMF_CLASS_RO     0x1100u
#define RMF_META_RO      0x1180u
#define RMF_ABS_C        0x1200u
#define RMF_CATEGORY     0x1240u
#define RMF_CATEGORY2    0x1260u
#define RMF_PROTOCOL     0x1280u
#define RMF_OBJC_DATA    0x1300u
#define RMF_CLASS        0x1300u
#define RMF_META         0x1340u

#define RMF_LINKEDIT     0x2000u
#define RMF_LINKEDIT_SIZE 0x100u
#define RMF_REBASE       0x2000u
#define RMF_SYMS         0x2080u
#define RMF_STRS         0x20a0u
#define RMF_CHAINED_BLOB 0x20c0u

enum {
    RMF_PLAIN    = 0,
    RMF_CHAINED  = 1u << 0,  /* carries an LC_DYLD_CHAINED_FIXUPS */
    RMF_DIRECT   = 1u << 1,  /* list A's header also sets 0x40000000 */
    RMF_LISTLIST = 1u << 2,  /* the class ro names list A with its low bit set */
    RMF_OOB      = 1u << 3,  /* list B claims 0x10000000 entries */
    RMF_SHARED   = 1u << 4,  /* the category names list A, as the class does */
    RMF_ABSCAT   = 1u << 5,  /* the category names an absolute list at RMF_ABS_C */
    RMF_NLCLS    = 1u << 6,  /* __objc_nlclslist names the class a second time */
    RMF_SWIFT    = 1u << 7,  /* both class data words carry the stable-ABI tag */
    RMF_BADENT   = 1u << 8,  /* list A is relative with a 16-byte entsize */
    RMF_ALLSLOTS = 1u << 9   /* the category's classMethods and the protocol's other three
                              * slots name lists; __objc_nlcatlist names the category and a
                              * second category that names list D */
};

static inline void rmf_name16(char *f, const char *s) {
    size_t n = strlen(s);
    if (n > 16) n = 16;
    memset(f, 0, 16);
    memcpy(f, s, n);
}

static inline void rmf_put32(uint8_t *b, uint32_t off, uint32_t v) { memcpy(b + off, &v, 4); }
static inline void rmf_put64(uint8_t *b, uint32_t off, uint64_t v) { memcpy(b + off, &v, 8); }

static inline void *rmf_lc(uint8_t *b, uint32_t *at, uint32_t cmd, uint32_t size) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    struct load_command *lc = (struct load_command *)(b + *at);
    lc->cmd = cmd;
    lc->cmdsize = size;
    *at += size;
    h->ncmds++;
    h->sizeofcmds += size;
    return lc;
}

static inline struct segment_command_64 *rmf_seg(uint8_t *b, uint32_t *at, const char *name,
                                                 uint64_t vm, uint64_t vmsize, uint64_t foff,
                                                 uint64_t fsize, uint32_t nsects, int prot) {
    struct segment_command_64 *s = rmf_lc(b, at, LC_SEGMENT_64,
        (uint32_t)(sizeof *s + nsects * sizeof(struct section_64)));
    rmf_name16(s->segname, name);
    s->vmaddr = vm; s->vmsize = vmsize; s->fileoff = foff; s->filesize = fsize;
    s->maxprot = s->initprot = prot;
    return s;
}

static inline void rmf_sect(struct segment_command_64 *s, const char *name, uint32_t off,
                            uint64_t size, uint32_t flags) {
    struct section_64 *x = (struct section_64 *)(s + 1) + s->nsects++;
    rmf_name16(x->sectname, name);
    memcpy(x->segname, s->segname, 16);
    x->addr = RMF_VA(off); x->size = size; x->offset = off; x->align = 3; x->flags = flags;
}

/* One relative entry at `e`: name -> the selref slot, types -> RMF_METHTYPE,
 * imp -> `imp`, or 0 for none. */
static inline void rmf_rel_entry(uint8_t *b, uint32_t e, uint32_t selref, uint32_t imp) {
    rmf_put32(b, e,     (uint32_t)(int32_t)((int64_t)selref - (int64_t)e));
    rmf_put32(b, e + 4, (uint32_t)(int32_t)((int64_t)RMF_METHTYPE - (int64_t)(e + 4)));
    rmf_put32(b, e + 8, imp ? (uint32_t)(int32_t)((int64_t)imp - (int64_t)(e + 8)) : 0);
}

static inline uint32_t rmf_uleb(uint8_t *p, uint64_t v) {
    uint32_t n = 0;
    do {
        uint8_t byte = v & 0x7f;
        v >>= 7;
        if (v) byte |= 0x80;
        p[n++] = byte;
    } while (v);
    return n;
}

/* Every pointer slot in __DATA (segment index 2), as offsets from its start. */
static inline uint32_t rmf_rebase_slots(unsigned v, uint32_t *out) {
    uint32_t n = 0;
    out[n++] = RMF_CLASSLIST - RMF_DATA;
    if (v & RMF_NLCLS) out[n++] = RMF_NLCLSLIST - RMF_DATA;
    out[n++] = RMF_CATLIST - RMF_DATA;
    out[n++] = RMF_PROTOLIST - RMF_DATA;
    if (v & RMF_ALLSLOTS)
        for (uint32_t i = 0; i < 2; i++) out[n++] = RMF_NLCATLIST + 8 * i - RMF_DATA;
    for (uint32_t i = 0; i < 4; i++) out[n++] = RMF_SELREFS - RMF_DATA + 8 * i;
    out[n++] = RMF_CLASS_RO + 32 - RMF_DATA;
    out[n++] = RMF_META_RO + 32 - RMF_DATA;
    if (v & RMF_ABSCAT)
        for (uint32_t i = 0; i < 3; i++) out[n++] = RMF_ABS_C + 8 + 8 * i - RMF_DATA;
    out[n++] = RMF_CATEGORY + 8 - RMF_DATA;
    out[n++] = RMF_CATEGORY + 16 - RMF_DATA;
    if (v & RMF_ALLSLOTS) {
        out[n++] = RMF_CATEGORY + 24 - RMF_DATA;
        out[n++] = RMF_CATEGORY2 + 8 - RMF_DATA;
        out[n++] = RMF_CATEGORY2 + 16 - RMF_DATA;
    }
    for (uint32_t i = 0; i < ((v & RMF_ALLSLOTS) ? 4u : 1u); i++)
        out[n++] = RMF_PROTOCOL + 24 + 8 * i - RMF_DATA;
    out[n++] = RMF_CLASS - RMF_DATA;
    out[n++] = RMF_CLASS + 32 - RMF_DATA;
    out[n++] = RMF_META + 32 - RMF_DATA;
    return n;
}

static inline uint32_t rmf_rebases(uint8_t *b, unsigned v) {
    uint32_t slots[32], n = rmf_rebase_slots(v, slots), at = RMF_REBASE;
    b[at++] = REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER;
    for (uint32_t i = 0; i < n; i++) {
        b[at++] = REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | 2;
        at += rmf_uleb(b + at, slots[i]);
        b[at++] = REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1;
    }
    b[at++] = REBASE_OPCODE_DONE;
    return at - RMF_REBASE;
}

/* Lays the image out in b[0, RMF_SIZE) and returns RMF_SIZE. */
static inline size_t rmf_build(uint8_t *b, unsigned v) {
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    struct segment_command_64 *s;
    uint32_t at = sizeof *h, cat_methods;

    memset(b, 0, RMF_SIZE);
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_EXECUTE;
    h->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE;

    rmf_seg(b, &at, "__PAGEZERO", 0, RMF_VMBASE, 0, 0, 0, VM_PROT_NONE);
    s = rmf_seg(b, &at, "__TEXT", RMF_VMBASE, 0x1000, 0, 0x1000, 4, VM_PROT_READ | VM_PROT_EXECUTE);
    rmf_sect(s, "__text", RMF_TEXT, 0x10, S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
    rmf_sect(s, "__objc_methname", RMF_METHNAME, 0x40, S_CSTRING_LITERALS);
    rmf_sect(s, "__objc_methtype", RMF_METHTYPE, 0x10, S_CSTRING_LITERALS);
    rmf_sect(s, "__objc_methlist", RMF_METHLIST, RMF_METHLIST_END - RMF_METHLIST, S_REGULAR);
    s = rmf_seg(b, &at, "__DATA", RMF_VA(RMF_DATA), 0x1000, RMF_DATA, 0x1000,
                6 + !!(v & RMF_NLCLS) + !!(v & RMF_ALLSLOTS), VM_PROT_READ | VM_PROT_WRITE);
    rmf_sect(s, "__objc_classlist", RMF_CLASSLIST, 8, S_REGULAR | S_ATTR_NO_DEAD_STRIP);
    if (v & RMF_NLCLS)
        rmf_sect(s, "__objc_nlclslist", RMF_NLCLSLIST, 8, S_REGULAR | S_ATTR_NO_DEAD_STRIP);
    rmf_sect(s, "__objc_catlist", RMF_CATLIST, 8, S_REGULAR | S_ATTR_NO_DEAD_STRIP);
    if (v & RMF_ALLSLOTS)
        rmf_sect(s, "__objc_nlcatlist", RMF_NLCATLIST, 16, S_REGULAR | S_ATTR_NO_DEAD_STRIP);
    rmf_sect(s, "__objc_protolist", RMF_PROTOLIST, 8, S_REGULAR | S_ATTR_NO_DEAD_STRIP);
    rmf_sect(s, "__objc_selrefs", RMF_SELREFS, 0x20, S_LITERAL_POINTERS | S_ATTR_NO_DEAD_STRIP);
    rmf_sect(s, "__objc_const", RMF_CONST, 0x200, S_REGULAR);
    rmf_sect(s, "__objc_data", RMF_OBJC_DATA, 0x80, S_REGULAR);
    rmf_seg(b, &at, "__LINKEDIT", RMF_VA(RMF_LINKEDIT), 0x1000, RMF_LINKEDIT,
            RMF_LINKEDIT_SIZE, 0, VM_PROT_READ);

    memset(b + RMF_TEXT, 0xc3, 0x10);
    memcpy(b + RMF_METHNAME + 0x00, "alpha", 6);
    memcpy(b + RMF_METHNAME + 0x10, "beta", 5);
    memcpy(b + RMF_METHNAME + 0x20, "gamma", 6);
    memcpy(b + RMF_METHNAME + 0x30, "delta", 6);
    memcpy(b + RMF_METHTYPE, "v16@0:8", 8);
    for (uint32_t i = 0; i < 4; i++)
        rmf_put64(b, RMF_SELREFS + 8 * i, RMF_VA(RMF_METHNAME + 0x10 * i));

    rmf_put32(b, RMF_LIST_A, (v & RMF_BADENT) ? 0x80000010u
                           : (v & RMF_DIRECT) ? (RMF_REL_HEADER | 0x40000000u) : RMF_REL_HEADER);
    rmf_put32(b, RMF_LIST_A + 4, 2);
    rmf_rel_entry(b, RMF_LIST_A + 8,  RMF_SELREFS + 0, RMF_TEXT + 0);
    rmf_rel_entry(b, RMF_LIST_A + 20, RMF_SELREFS + 8, RMF_TEXT + 4);
    rmf_put32(b, RMF_LIST_B, RMF_REL_HEADER);
    rmf_put32(b, RMF_LIST_B + 4, (v & RMF_OOB) ? 0x10000000u : 1);
    rmf_rel_entry(b, RMF_LIST_B + 8, RMF_SELREFS + 16, RMF_TEXT + 8);
    rmf_put32(b, RMF_LIST_C, RMF_REL_HEADER);
    rmf_put32(b, RMF_LIST_C + 4, 1);
    rmf_rel_entry(b, RMF_LIST_C + 8, RMF_SELREFS + 24, RMF_TEXT + 12);
    rmf_put32(b, RMF_LIST_D, RMF_REL_HEADER);
    rmf_put32(b, RMF_LIST_D + 4, 1);
    rmf_rel_entry(b, RMF_LIST_D + 8, RMF_SELREFS + 0, 0);

    if (v & RMF_ABSCAT) {
        rmf_put32(b, RMF_ABS_C, RMF_ABS_HEADER);
        rmf_put32(b, RMF_ABS_C + 4, 1);
        rmf_put64(b, RMF_ABS_C + 8,  RMF_VA(RMF_METHNAME + 0x30));
        rmf_put64(b, RMF_ABS_C + 16, RMF_VA(RMF_METHTYPE));
        rmf_put64(b, RMF_ABS_C + 24, RMF_VA(RMF_TEXT + 12));
    }

    rmf_put64(b, RMF_CLASS_RO + 32, RMF_VA(RMF_LIST_A) | ((v & RMF_LISTLIST) ? 1 : 0));
    rmf_put32(b, RMF_META_RO, 1);
    rmf_put64(b, RMF_META_RO + 32, RMF_VA(RMF_LIST_B));
    cat_methods = (v & RMF_SHARED) ? RMF_LIST_A : (v & RMF_ABSCAT) ? RMF_ABS_C : RMF_LIST_C;
    rmf_put64(b, RMF_CATEGORY + 8, RMF_VA(RMF_CLASS));
    rmf_put64(b, RMF_CATEGORY + 16, RMF_VA(cat_methods));
    rmf_put64(b, RMF_PROTOCOL + 24, RMF_VA(RMF_LIST_D));
    if (v & RMF_ALLSLOTS) {
        rmf_put64(b, RMF_CATEGORY + 24, RMF_VA(RMF_LIST_B));
        rmf_put64(b, RMF_CATEGORY2 + 8, RMF_VA(RMF_CLASS));
        rmf_put64(b, RMF_CATEGORY2 + 16, RMF_VA(RMF_LIST_D));
        rmf_put64(b, RMF_PROTOCOL + 32, RMF_VA(RMF_LIST_A));
        rmf_put64(b, RMF_PROTOCOL + 40, RMF_VA(RMF_LIST_B));
        rmf_put64(b, RMF_PROTOCOL + 48, RMF_VA(RMF_LIST_C));
    }
    rmf_put32(b, RMF_PROTOCOL + 64, 80);
    rmf_put64(b, RMF_CLASS, RMF_VA(RMF_META));
    rmf_put64(b, RMF_CLASS + 32, RMF_VA(RMF_CLASS_RO) | ((v & RMF_SWIFT) ? 2 : 0));
    rmf_put64(b, RMF_META + 32, RMF_VA(RMF_META_RO) | ((v & RMF_SWIFT) ? 2 : 0));
    rmf_put64(b, RMF_CLASSLIST, RMF_VA(RMF_CLASS));
    if (v & RMF_NLCLS) rmf_put64(b, RMF_NLCLSLIST, RMF_VA(RMF_CLASS));
    rmf_put64(b, RMF_CATLIST, RMF_VA(RMF_CATEGORY));
    if (v & RMF_ALLSLOTS) {
        rmf_put64(b, RMF_NLCATLIST, RMF_VA(RMF_CATEGORY));
        rmf_put64(b, RMF_NLCATLIST + 8, RMF_VA(RMF_CATEGORY2));
    }
    rmf_put64(b, RMF_PROTOLIST, RMF_VA(RMF_PROTOCOL));

    {
        struct dyld_info_command *di = rmf_lc(b, &at, LC_DYLD_INFO_ONLY, sizeof *di);
        di->rebase_off = RMF_REBASE;
        di->rebase_size = (rmf_rebases(b, v) + 7) & ~7u;
    }
    {
        struct symtab_command *st = rmf_lc(b, &at, LC_SYMTAB, sizeof *st);
        struct nlist_64 *sym = (struct nlist_64 *)(b + RMF_SYMS);
        st->symoff = RMF_SYMS; st->nsyms = 1;
        st->stroff = RMF_STRS; st->strsize = 0x10;
        memcpy(b + RMF_STRS + 1, "_rmf_main", 10);
        sym->n_un.n_strx = 1;
        sym->n_type = N_SECT | N_EXT;
        sym->n_sect = 1;
        sym->n_value = RMF_VA(RMF_TEXT);
    }
    if (v & RMF_CHAINED) {
        struct linkedit_data_command *cf = rmf_lc(b, &at, LC_DYLD_CHAINED_FIXUPS, sizeof *cf);
        cf->dataoff = RMF_CHAINED_BLOB;
        cf->datasize = 0x20;
    }
    return RMF_SIZE;
}

#endif
