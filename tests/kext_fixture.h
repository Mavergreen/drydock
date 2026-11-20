/*
 * tests/kext_fixture.h -- a minimal x86_64 MH_KEXT_BUNDLE with vnode-op tables.
 *
 * Header-only, so tests/mkkext.c builds it standalone. Layout: __TEXT,__text
 * (0x40 bytes of ret) at file 0x200, __DATA,__data right after it, then
 * __LINKEDIT in ld64's order: local relocations, symbols, external
 * relocations, strings.
 * Section addresses are base + file offset, and r_address is relative to base.
 *
 * Each table entry is {desc, impl}: an external UNSIGNED quad relocation to
 * its descriptor and a local one to __text + impl. An undefined symbol no
 * entry names, and whose name does not end in "_desc", gets one external
 * pointer in __data after the tables. Knobs aim at KF_OLD's first entry.
 */
#ifndef DRYDOCK_KEXT_FIXTURE_H
#define DRYDOCK_KEXT_FIXTURE_H

#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KF_OLD "_vnop_renamex_desc"
#define KF_TEXT_OFF 0x200u
#define KF_TEXT_SIZE 0x40u

typedef struct { const char *desc; int impl; } kf_entry;
typedef struct {
    uint64_t base;
    const kf_entry *tables[2]; int ntables;
    const char *const *undefs; int nundefs;
    int ndefs;
    int extra_reloc_at_old, ntoc, undef_not_last, extern_local_reloc, stray_old_reloc, impl_reloc_kind_differs;
    uint32_t filetype, cputype;   /* 0: MH_KEXT_BUNDLE, CPU_TYPE_X86_64 */
} kf_spec;

static int kf_undef(const kf_spec *s, const char *name) {
    for (int i = 0; i < s->nundefs; i++)
        if (strcmp(s->undefs[i], name) == 0) return i;
    fprintf(stderr, "kf_build: %s is not among the undefined symbols\n", name);
    abort();
}

static int kf_named_by_table(const kf_spec *s, const char *name) {
    for (int t = 0; t < s->ntables; t++)
        for (const kf_entry *e = s->tables[t]; e->desc || e->impl; e++)
            if (e->desc && strcmp(e->desc, name) == 0) return 1;
    return 0;
}

static int kf_ends_desc(const char *name) {
    size_t n = strlen(name);
    return n >= 5 && strcmp(name + n - 5, "_desc") == 0;
}

static void kf_reloc(uint8_t *at, uint64_t addr, uint64_t base, uint32_t sym, int ext) {
    struct relocation_info r;
    memset(&r, 0, sizeof r);
    r.r_address = (int32_t)(addr - base);
    r.r_symbolnum = sym; r.r_pcrel = 0; r.r_length = 3; r.r_extern = (unsigned)ext; r.r_type = 0;
    memcpy(at, &r, sizeof r);
}

static uint8_t *kf_build(const kf_spec *s, size_t *size) {
    size_t nentries = 0, nmisc = 0;
    for (int t = 0; t < s->ntables; t++) {
        const kf_entry *e = s->tables[t];
        while (e->desc || e->impl) { e++; nentries++; }
        nentries++;
    }
    for (int i = 0; i < s->nundefs; i++)
        if (!kf_named_by_table(s, s->undefs[i]) && !kf_ends_desc(s->undefs[i])) nmisc++;
    size_t nstray = (s->stray_old_reloc ? 1 : 0) + (s->extern_local_reloc ? 1 : 0);

    size_t lcs = 2 * (sizeof(struct segment_command_64) + sizeof(struct section_64))
               + sizeof(struct segment_command_64) + sizeof(struct symtab_command) + sizeof(struct dysymtab_command);
    uint64_t text_off = KF_TEXT_OFF, data_off = text_off + KF_TEXT_SIZE;
    uint64_t data_size = (nentries * 16 + (nmisc + nstray) * 8 + 15) & ~(uint64_t)15;
    uint64_t le_off = data_off + data_size;

    size_t nextrel = 0, nlocrel = 0;
    for (int t = 0; t < s->ntables; t++)
        for (const kf_entry *e = s->tables[t]; e->desc || e->impl; e++) {
            if (e->desc) nextrel++;
            if (e->impl) nlocrel++;
        }
    nextrel += nmisc;
    if (s->extra_reloc_at_old) nlocrel++;
    nlocrel += nstray;
    if (s->impl_reloc_kind_differs) { nextrel++; nlocrel--; }
    int nsyms = s->ndefs + s->nundefs + (s->undef_not_last ? 1 : 0);

    size_t locreloff = le_off, symoff = locreloff + nlocrel * 8;
    size_t extreloff = symoff + (size_t)nsyms * sizeof(struct nlist_64), stroff = extreloff + nextrel * 8;
    size_t strsize = 2 + 16 * (size_t)(s->ndefs + 1);
    for (int i = 0; i < s->nundefs; i++) strsize += strlen(s->undefs[i]) + 1;
    strsize = (strsize + 7) & ~(size_t)7;
    size_t total = stroff + strsize;

    uint8_t *b = calloc(1, total);
    if (!b) abort();
    struct mach_header_64 *h = (struct mach_header_64 *)b;
    h->magic = MH_MAGIC_64;
    h->cputype = s->cputype ? (cpu_type_t)s->cputype : CPU_TYPE_X86_64;
    h->cpusubtype = 3;
    h->filetype = s->filetype ? s->filetype : MH_KEXT_BUNDLE;
    h->flags = MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL;   /* as ld64 writes a kext's */
    h->ncmds = 5; h->sizeofcmds = (uint32_t)lcs;

    uint8_t *p = b + sizeof *h;
    const char *segs[2] = { SEG_TEXT, SEG_DATA }, *sects[2] = { SECT_TEXT, SECT_DATA };
    uint64_t offs[2] = { text_off, data_off }, sizes[2] = { KF_TEXT_SIZE, data_size };
    for (int i = 0; i < 2; i++) {
        struct segment_command_64 *sg = (struct segment_command_64 *)p;
        struct section_64 *sc = (struct section_64 *)(sg + 1);
        sg->cmd = LC_SEGMENT_64; sg->cmdsize = sizeof *sg + sizeof *sc;
        strncpy(sg->segname, segs[i], 16);
        sg->vmaddr = s->base + (i ? offs[i] : 0);
        sg->vmsize = sg->filesize = i ? sizes[i] : offs[0] + sizes[0];
        sg->fileoff = i ? offs[i] : 0;
        sg->maxprot = sg->initprot = i ? (VM_PROT_READ | VM_PROT_WRITE) : (VM_PROT_READ | VM_PROT_EXECUTE);
        sg->nsects = 1;
        strncpy(sc->sectname, sects[i], 16); strncpy(sc->segname, segs[i], 16);
        sc->addr = s->base + offs[i]; sc->size = sizes[i]; sc->offset = (uint32_t)offs[i]; sc->align = 4;
        if (!i) sc->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
        p += sg->cmdsize;
    }
    struct segment_command_64 *le = (struct segment_command_64 *)p;
    le->cmd = LC_SEGMENT_64; le->cmdsize = sizeof *le;
    strncpy(le->segname, SEG_LINKEDIT, 16);
    le->vmaddr = s->base + le_off; le->vmsize = le->filesize = total - le_off; le->fileoff = le_off;
    le->maxprot = le->initprot = VM_PROT_READ;
    p += le->cmdsize;
    struct symtab_command *st = (struct symtab_command *)p;
    st->cmd = LC_SYMTAB; st->cmdsize = sizeof *st;
    st->symoff = (uint32_t)symoff; st->nsyms = (uint32_t)nsyms;
    st->stroff = (uint32_t)stroff; st->strsize = (uint32_t)strsize;
    p += st->cmdsize;
    struct dysymtab_command *dy = (struct dysymtab_command *)p;
    dy->cmd = LC_DYSYMTAB; dy->cmdsize = sizeof *dy;
    dy->ilocalsym = 0; dy->nlocalsym = (uint32_t)s->ndefs;
    dy->iextdefsym = (uint32_t)s->ndefs; dy->nextdefsym = 0;
    dy->iundefsym = (uint32_t)s->ndefs; dy->nundefsym = (uint32_t)s->nundefs;
    if (s->ntoc) { dy->tocoff = (uint32_t)symoff; dy->ntoc = (uint32_t)s->ntoc; }
    dy->extreloff = (uint32_t)extreloff; dy->nextrel = (uint32_t)nextrel;
    dy->locreloff = (uint32_t)locreloff; dy->nlocrel = (uint32_t)nlocrel;

    memset(b + text_off, 0xc3, KF_TEXT_SIZE);
    uint64_t text_addr = s->base + text_off, at = s->base + data_off;
    uint8_t *ext = b + extreloff, *loc = b + locreloff;
    int old_seen = 0;
    for (int t = 0; t < s->ntables; t++) {
        const kf_entry *e = s->tables[t];
        for (;; e++, at += 16) {
            if (!e->desc && !e->impl) { at += 16; break; }
            int is_old = e->desc && strcmp(e->desc, KF_OLD) == 0 && !old_seen++;
            if (e->desc) {
                kf_reloc(ext, at, s->base, (uint32_t)(s->ndefs + kf_undef(s, e->desc)), 1); ext += 8;
            }
            if (is_old && s->extra_reloc_at_old) { kf_reloc(loc, at, s->base, 1, 0); loc += 8; }
            if (e->impl) {
                uint64_t v = text_addr + (uint64_t)e->impl;
                if (is_old && s->impl_reloc_kind_differs) {
                    kf_reloc(ext, at + 8, s->base, (uint32_t)s->ndefs, 1); ext += 8;
                } else {
                    memcpy(b + (at - s->base) + 8, &v, 8);
                    kf_reloc(loc, at + 8, s->base, 1, 0); loc += 8;
                }
            }
        }
    }
    for (int i = 0; i < s->nundefs; i++)
        if (!kf_named_by_table(s, s->undefs[i]) && !kf_ends_desc(s->undefs[i])) {
            kf_reloc(ext, at, s->base, (uint32_t)(s->ndefs + i), 1); ext += 8; at += 8;
        }
    if (s->stray_old_reloc) {
        kf_reloc(loc, at, s->base, (uint32_t)(s->ndefs + kf_undef(s, KF_OLD)), 1); loc += 8; at += 8;
    }
    if (s->extern_local_reloc) {
        kf_reloc(loc, at, s->base, (uint32_t)(s->ndefs + s->nundefs - 1), 1); loc += 8; at += 8;
    }

    char *str = (char *)b + stroff;
    size_t used = 2;   /* " \0", as ld writes it */
    str[0] = ' ';
    uint8_t *nl = b + symoff;
    for (int i = 0; i < nsyms; i++) {
        struct nlist_64 n;
        memset(&n, 0, sizeof n);
        n.n_un.n_strx = (uint32_t)used;
        if (i >= s->ndefs && i < s->ndefs + s->nundefs) {
            const char *name = s->undefs[i - s->ndefs];
            strcpy(str + used, name); used += strlen(name) + 1;
            n.n_type = N_UNDF | N_EXT;
        } else {
            used += (size_t)snprintf(str + used, 16, "_def%d", i) + 1;
            n.n_type = N_SECT | (i < s->ndefs ? 0 : N_EXT); n.n_sect = 1; n.n_value = text_addr;
        }
        memcpy(nl + (size_t)i * sizeof n, &n, sizeof n);
    }
    *size = total;
    return b;
}

#endif
