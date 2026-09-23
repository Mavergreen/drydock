# Relative ObjC Method Lists, Milestone 1 (See the Lists) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find every Objective-C method list an image's classes, metaclasses, categories and protocols name, tell relative lists from absolute ones, and report the count as an `info` line.

**Architecture:** A new read-only module, `src/objc_meth.[ch]` (prefix `mml_`), walks the same structures the 10.9 runtime walks on a classic-fixups image. It records each method-list slot it finds, and refuses shapes it cannot read, giving a reason. `info_image` prints one `method-lists:` line from that walk. The fixture is hand-built, in `tests/relmeth_fixture.h`, and shared by a hermetic C test and a small file-writing tool for the shell suite.

**Tech Stack:** C99, CMake + CTest, `/bin/sh` test suites, the 10.9 SDK's `<mach-o/loader.h>`.

**Spec:** `docs/superpowers/specs/2026-09-23-objc-method-lists-design.md`. This plan is its milestone M1. M2–M4 are outlined there and get their own plans.

## Global Constraints

- **TDD, mutation-proven.** Every task writes its failing test first, watches it fail, implements, and watches it pass. Then it applies each listed mutation, rebuilds, sees the named test FAIL, and reverts.
- **This host has clock skew, so confirm every rebuild.** Before and after each mutation build, record `shasum -a 256` of the binary under test. If the hash did not change, `touch` the mutated source and build again. A mutation measured against a stale binary proves nothing.
- **Comments are a last resort.** Prefer a test, then the commit message, then a doc, then one inline sentence. No history narration in source, and no references to this plan or the spec from source.
- **Build:** `/usr/local/bin/shipyard-cmake --build /private/tmp/build/schmonz/drydock-native -j`
- **Test:** `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir /private/tmp/build/schmonz/drydock-native`
- **Exit codes:** `EX_REFUSED`=1, `EX_FAIL`=2.
- **Every grep negative needs a positive control.** A test asserting that a grep finds nothing must also show that the same grep finds something where it should.
- **In shell suites, capture rc with `rc=0; cmd || rc=$?`.**
- **README.md is not touched by this milestone.** It is touched only by M4's final task, which changes only the lines this feature adds.
- **Stage explicit paths, never `git add -A`.** Other agents may have work in the tree.
- **Segment and section names are `char[16]` and need not be NUL-terminated.** Print them with `%.16s` and compare them with `strncmp(..., 16)`.
- **Commit trailer, exactly:**
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
  ```

Shorthand used below: `B=/private/tmp/build/schmonz/drydock-native`.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `src/objc_meth.h` | `mml_walk_image`, `mml_ref`, `mml_walk`, the `MML_*` constants | 1, 2 |
| `src/objc_meth.c` | the walk: segments, list sections, records, list headers | 1, 2 |
| `tests/relmeth_fixture.h` | `rmf_build`: the hand-built image, its fixed offsets, and its variants | 1 |
| `tests/objc_meth_test.c` | hermetic tests of the walk | 1, 2 |
| `tests/mkrelmeth.c` | writes a fixture variant to a file for the shell suites | 3 |
| `cli/drydock-macho-rewrite.c` | `info_image`'s `method-lists:` line | 3 |
| `tests/cli_test.sh` | the `info` assertions | 3 |
| `CMakeLists.txt` | library source, the `objc_meth_test` target | 1 |

**Shared with plans drafting in parallel:** `cli/drydock-macho-rewrite.c` (a minos-set plan may add `info` lines, which is an adjacent-line conflict at worst), `CMakeLists.txt` (everyone appends) and `tests/cli_test.sh` (everyone appends). Append; do not reorder.

---

### Task 1: Walk classes and metaclasses, refusing what cannot be read

**Files:**
- Create: `src/objc_meth.h`, `src/objc_meth.c`, `tests/relmeth_fixture.h`, `tests/objc_meth_test.c`
- Modify: `CMakeLists.txt:66` (library sources), and add the test target after the `relations_test` block (`CMakeLists.txt:272-275`)

**Interfaces:**
- Consumes: `mi_wrap`, `mi_each_lc`, `mi_image` (`src/image.h`); `LC_DYLD_CHAINED_FIXUPS` (`src/mach_compat.h`).
- Produces:
  - `int mml_walk_image(const mi_image *im, mml_walk *w)` returns `MML_OK` (0), `MML_CHAINED` (-1), `MML_MALFORMED` (-2) or `MML_NOMEM` (-3). On any non-zero return `w->refs` is NULL, `w->n` is 0, and `w->why` holds the reason.
  - `void mml_walk_free(mml_walk *w)`.
  - `mml_ref { uint64_t slot_off, list_va, list_off; uint32_t header, count; int owner; }`.
  - `mml_walk { mml_ref *refs; uint32_t n, cap; uint32_t relative, absolute; uint32_t owners[MML_NOWNERS]; char why[160]; }`.
  - Owners: `MML_CLASS`=0, `MML_METACLASS`, `MML_CATEGORY`, `MML_PROTOCOL`, `MML_NOWNERS`.
  - Fixture: `size_t rmf_build(uint8_t *b, unsigned variant)` into an `RMF_SIZE` buffer, with the `RMF_*` offsets and variant bits below.

- [ ] **Step 1: Write the fixture header**

Create `tests/relmeth_fixture.h`:

```c
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
#define RMF_SELREFS      0x1040u
#define RMF_CONST        0x1100u
#define RMF_CLASS_RO     0x1100u
#define RMF_META_RO      0x1180u
#define RMF_ABS_C        0x1200u
#define RMF_CATEGORY     0x1240u
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
    RMF_BADENT   = 1u << 8   /* list A is relative with a 16-byte entsize */
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
    for (uint32_t i = 0; i < 4; i++) out[n++] = RMF_SELREFS - RMF_DATA + 8 * i;
    out[n++] = RMF_CLASS_RO + 32 - RMF_DATA;
    out[n++] = RMF_META_RO + 32 - RMF_DATA;
    if (v & RMF_ABSCAT)
        for (uint32_t i = 0; i < 3; i++) out[n++] = RMF_ABS_C + 8 + 8 * i - RMF_DATA;
    out[n++] = RMF_CATEGORY + 8 - RMF_DATA;
    out[n++] = RMF_CATEGORY + 16 - RMF_DATA;
    out[n++] = RMF_PROTOCOL + 24 - RMF_DATA;
    out[n++] = RMF_CLASS - RMF_DATA;
    out[n++] = RMF_CLASS + 32 - RMF_DATA;
    out[n++] = RMF_META + 32 - RMF_DATA;
    return n;
}

static inline uint32_t rmf_rebases(uint8_t *b, unsigned v) {
    uint32_t slots[24], n = rmf_rebase_slots(v, slots), at = RMF_REBASE;
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
                (v & RMF_NLCLS) ? 7 : 6, VM_PROT_READ | VM_PROT_WRITE);
    rmf_sect(s, "__objc_classlist", RMF_CLASSLIST, 8, S_REGULAR | S_ATTR_NO_DEAD_STRIP);
    if (v & RMF_NLCLS)
        rmf_sect(s, "__objc_nlclslist", RMF_NLCLSLIST, 8, S_REGULAR | S_ATTR_NO_DEAD_STRIP);
    rmf_sect(s, "__objc_catlist", RMF_CATLIST, 8, S_REGULAR | S_ATTR_NO_DEAD_STRIP);
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
    rmf_put32(b, RMF_PROTOCOL + 64, 80);
    rmf_put64(b, RMF_CLASS, RMF_VA(RMF_META));
    rmf_put64(b, RMF_CLASS + 32, RMF_VA(RMF_CLASS_RO) | ((v & RMF_SWIFT) ? 2 : 0));
    rmf_put64(b, RMF_META + 32, RMF_VA(RMF_META_RO) | ((v & RMF_SWIFT) ? 2 : 0));
    rmf_put64(b, RMF_CLASSLIST, RMF_VA(RMF_CLASS));
    if (v & RMF_NLCLS) rmf_put64(b, RMF_NLCLSLIST, RMF_VA(RMF_CLASS));
    rmf_put64(b, RMF_CATLIST, RMF_VA(RMF_CATEGORY));
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
```

- [ ] **Step 2: Write the failing test**

Create `tests/objc_meth_test.c`:

```c
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
```

Register it in `CMakeLists.txt`. Append ` src/objc_meth.c` to the end of the `add_library(drydockcore STATIC ...)` source list at line 66. After the `relations_test` block (`add_test(NAME relations_test ...)`, line 275), add:

```cmake
# Hermetic tests for src/objc_meth.c, against tests/relmeth_fixture.h's
# hand-built image, since no 10.9 linker emits relative method lists.
add_executable(objc_meth_test tests/objc_meth_test.c)
target_compile_options(objc_meth_test PRIVATE -O2 -Wall -Wextra)
target_link_libraries(objc_meth_test PRIVATE drydockcore)
add_test(NAME objc_meth_test COMMAND objc_meth_test)
set_tests_properties(objc_meth_test PROPERTIES ENVIRONMENT MallocScribble=1)
```

Create `src/objc_meth.h` with the interface only, so the test compiles and fails to link:

```c
#ifndef DRYDOCK_OBJC_METH_H
#define DRYDOCK_OBJC_METH_H
/*
 * mml_ -- the Objective-C method lists an image's own classes, metaclasses,
 * categories and protocols name, found by the walk the 10.9 runtime makes,
 * on an image whose pointers are classic rather than chained.
 */
#include <stdint.h>

#include "image.h"

#define MML_RELATIVE    0x80000000u
#define MML_FLAG_MASK   0xFFFF0003u
#define MML_REL_ENTSIZE 12u
#define MML_ABS_ENTSIZE 24u

#define MML_OK          0
#define MML_CHAINED   (-1)
#define MML_MALFORMED (-2)
#define MML_NOMEM     (-3)

enum { MML_CLASS, MML_METACLASS, MML_CATEGORY, MML_PROTOCOL, MML_NOWNERS };

typedef struct {
    uint64_t slot_off;   /* file offset of the pointer that names the list */
    uint64_t list_va, list_off;
    uint32_t header, count;
    int      owner;
} mml_ref;

typedef struct {
    mml_ref *refs;
    uint32_t n, cap;
    uint32_t relative, absolute;     /* distinct lists, by address */
    uint32_t owners[MML_NOWNERS];    /* distinct records walked */
    char     why[160];
} mml_walk;

/* MML_OK, or MML_CHAINED / MML_MALFORMED / MML_NOMEM with w->why set and
 * w->refs NULL. */
int  mml_walk_image(const mi_image *im, mml_walk *w);
void mml_walk_free(mml_walk *w);

#endif
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `/usr/local/bin/shipyard-cmake --build $B -j 2>&1 | tail -5`
Expected: a link error, `Undefined symbols ... _mml_walk_image`, and no `$B/objc_meth_test`. The CMake source list names `src/objc_meth.c`, which does not exist yet, so configure may fail first with `Cannot find source file: src/objc_meth.c`. Either failure is the expected red.

- [ ] **Step 4: Write the minimal implementation**

Create `src/objc_meth.c`:

```c
/* mml_ -- see objc_meth.h. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "objc_meth.h"
#include "mach_compat.h"

#define MML_MAX_SEGS   64
#define MML_DATA_MASK  0x00007ffffffffff8ULL
#define MML_CLASS_ISA   0
#define MML_CLASS_DATA 32
#define MML_RO_METHODS 32

typedef struct { uint64_t vmaddr, filesize, fileoff; } mml_seg;

typedef struct {
    const mi_image *im;
    mml_walk *w;
    mml_seg segs[MML_MAX_SEGS];
    int nsegs, chained, err;
    uint64_t *seen;
    uint32_t nseen, capseen;
} mml_ctx;

static const struct { const char *name; int owner; } MML_LISTS[] = {
    { "__objc_classlist", MML_CLASS },
    { "__objc_nlclslist", MML_CLASS },
};

static int mml_fail(mml_ctx *c, int code, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static int mml_fail(mml_ctx *c, int code, const char *fmt, ...) {
    va_list ap;
    if (c->err) return c->err;
    va_start(ap, fmt);
    vsnprintf(c->w->why, sizeof c->w->why, fmt, ap);
    va_end(ap);
    c->err = code;
    return code;
}

/* The file offset of [va, va + len) when one segment's file bytes hold all
 * of it, else -1. */
static int64_t mml_off(const mml_ctx *c, uint64_t va, uint64_t len) {
    for (int i = 0; i < c->nsegs; i++) {
        const mml_seg *s = &c->segs[i];
        if (va < s->vmaddr || va - s->vmaddr >= s->filesize) continue;
        uint64_t rel = va - s->vmaddr;
        if (len > s->filesize - rel) return -1;
        uint64_t off = s->fileoff + rel;
        if (off > c->im->size || len > c->im->size - off) return -1;
        return (int64_t)off;
    }
    return -1;
}

static int mml_read64(const mml_ctx *c, uint64_t va, uint64_t *out) {
    int64_t off = mml_off(c, va, 8);
    if (off < 0) return -1;
    memcpy(out, c->im->buf + off, 8);
    return 0;
}

/* 1 the first time `va` is seen, 0 after that, -1 when out of memory. */
static int mml_first_visit(mml_ctx *c, uint64_t va) {
    for (uint32_t i = 0; i < c->nseen; i++)
        if (c->seen[i] == va) return 0;
    if (c->nseen == c->capseen) {
        uint32_t cap = c->capseen ? c->capseen * 2 : 64;
        uint64_t *p = realloc(c->seen, cap * sizeof *p);
        if (!p) { mml_fail(c, MML_NOMEM, "out of memory"); return -1; }
        c->seen = p;
        c->capseen = cap;
    }
    c->seen[c->nseen++] = va;
    return 1;
}

static int mml_list(mml_ctx *c, uint64_t slot_va, int owner) {
    mml_walk *w = c->w;
    uint64_t list_va;
    uint32_t hdr, count, i;
    int64_t slot_off = mml_off(c, slot_va, 8), loff;

    if (slot_off < 0)
        return mml_fail(c, MML_MALFORMED, "the method-list pointer at 0x%llx lies outside the file",
                        (unsigned long long)slot_va);
    memcpy(&list_va, c->im->buf + slot_off, 8);
    if (!list_va) return 0;
    if (list_va & 3)
        return mml_fail(c, MML_MALFORMED, "the method-list pointer at 0x%llx has its low bits set "
                        "(0x%llx): a list of lists, which this walk does not read",
                        (unsigned long long)slot_va, (unsigned long long)list_va);
    loff = mml_off(c, list_va, 8);
    if (loff < 0)
        return mml_fail(c, MML_MALFORMED, "the method list at 0x%llx lies outside the file",
                        (unsigned long long)list_va);
    memcpy(&hdr, c->im->buf + loff, 4);
    memcpy(&count, c->im->buf + loff + 4, 4);

    int rel = (hdr & MML_RELATIVE) != 0;
    uint32_t entsize = hdr & ~MML_FLAG_MASK;
    uint32_t allowed = rel ? MML_RELATIVE : 3u;
    if (entsize != (rel ? MML_REL_ENTSIZE : MML_ABS_ENTSIZE) || (hdr & MML_FLAG_MASK & ~allowed))
        return mml_fail(c, MML_MALFORMED, "the method list at 0x%llx has entsizeAndFlags 0x%08x, "
                        "which this walk does not read", (unsigned long long)list_va, hdr);
    if (mml_off(c, list_va, 8 + (uint64_t)entsize * count) < 0)
        return mml_fail(c, MML_MALFORMED, "the method list at 0x%llx claims %u entries, which runs "
                        "past its segment", (unsigned long long)list_va, count);

    int fresh = 1;
    for (i = 0; i < w->n; i++) {
        if (w->refs[i].slot_off == (uint64_t)slot_off) return 0;
        if (w->refs[i].list_va == list_va) fresh = 0;
    }
    if (w->n == w->cap) {
        uint32_t cap = w->cap ? w->cap * 2 : 32;
        mml_ref *p = realloc(w->refs, cap * sizeof *p);
        if (!p) return mml_fail(c, MML_NOMEM, "out of memory");
        w->refs = p;
        w->cap = cap;
    }
    w->refs[w->n].slot_off = (uint64_t)slot_off;
    w->refs[w->n].list_va = list_va;
    w->refs[w->n].list_off = (uint64_t)loff;
    w->refs[w->n].header = hdr;
    w->refs[w->n].count = count;
    w->refs[w->n].owner = owner;
    w->n++;
    if (fresh) { if (rel) w->relative++; else w->absolute++; }
    return 0;
}

static int mml_class(mml_ctx *c, uint64_t cls_va, int owner) {
    uint64_t data, isa;
    int v;
    if (!cls_va) return 0;
    v = mml_first_visit(c, cls_va);
    if (v <= 0) return c->err;
    if (mml_read64(c, cls_va + MML_CLASS_ISA, &isa) != 0 ||
        mml_read64(c, cls_va + MML_CLASS_DATA, &data) != 0)
        return mml_fail(c, MML_MALFORMED, "the class record at 0x%llx lies outside the file",
                        (unsigned long long)cls_va);
    c->w->owners[owner]++;
    uint64_t ro = data & MML_DATA_MASK;
    if (ro && mml_list(c, ro + MML_RO_METHODS, owner) != 0) return c->err;
    if (owner == MML_CLASS && isa) return mml_class(c, isa, MML_METACLASS);
    return 0;
}

static int mml_record(mml_ctx *c, uint64_t va, int owner) {
    return mml_class(c, va, owner);
}

static int mml_section(mml_ctx *c, const struct section_64 *s, int owner) {
    if (s->offset > c->im->size || s->size > c->im->size - s->offset)
        return mml_fail(c, MML_MALFORMED, "section %.16s lies outside the file", s->sectname);
    for (uint64_t i = 0; i + 8 <= s->size; i += 8) {
        uint64_t va;
        memcpy(&va, c->im->buf + s->offset + i, 8);
        if (mml_record(c, va, owner) != 0) return c->err;
    }
    return 0;
}

static int mml_seg_lc(const struct load_command *lc, void *ctx_) {
    mml_ctx *c = ctx_;
    if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) c->chained = 1;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
    if (c->nsegs == MML_MAX_SEGS) {
        mml_fail(c, MML_MALFORMED, "more than %d segments", MML_MAX_SEGS);
        return 1;
    }
    c->segs[c->nsegs].vmaddr = sc->vmaddr;
    c->segs[c->nsegs].filesize = sc->filesize;
    c->segs[c->nsegs].fileoff = sc->fileoff;
    c->nsegs++;
    return 0;
}

static int mml_sect_lc(const struct load_command *lc, void *ctx_) {
    mml_ctx *c = ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
    const struct section_64 *s = (const struct section_64 *)(sc + 1);
    for (uint32_t k = 0; k < sc->nsects; k++)
        for (size_t j = 0; j < sizeof MML_LISTS / sizeof MML_LISTS[0]; j++)
            if (strncmp(s[k].sectname, MML_LISTS[j].name, 16) == 0 &&
                mml_section(c, &s[k], MML_LISTS[j].owner) != 0)
                return 1;
    return 0;
}

int mml_walk_image(const mi_image *im, mml_walk *w) {
    mml_ctx c;
    memset(w, 0, sizeof *w);
    memset(&c, 0, sizeof c);
    c.im = im;
    c.w = w;
    mi_each_lc(im, mml_seg_lc, &c);
    if (!c.err && c.chained)
        mml_fail(&c, MML_CHAINED, "the image has chained fixups; fixups set classic first");
    if (!c.err) mi_each_lc(im, mml_sect_lc, &c);
    free(c.seen);
    if (c.err) {
        free(w->refs);
        w->refs = NULL;
        w->n = w->cap = 0;
    }
    return c.err;
}

void mml_walk_free(mml_walk *w) {
    free(w->refs);
    w->refs = NULL;
    w->n = w->cap = 0;
}
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `/usr/local/bin/shipyard-cmake --build $B -j && $B/objc_meth_test`
Expected: `objc_meth_test: 0 failure(s)`. If `$B/objc_meth_test` does not exist, the build did not see the `CMakeLists.txt` change (clock skew). Run `touch CMakeLists.txt` and build again.

- [ ] **Step 6: Prove the tests bite (mutations)**

For each mutation:

1. Record `shasum -a 256 $B/objc_meth_test`.
2. Apply the mutation and build.
3. Confirm the hash changed. If it did not, `touch src/objc_meth.c` and build again.
4. Run `$B/objc_meth_test` and see the named FAIL.
5. Revert.

| mutation in `src/objc_meth.c` | must fail |
|---|---|
| `if (owner == MML_CLASS && isa)` → `if (0 && isa)` | `plain: no metaclass ref` |
| `uint64_t ro = data & MML_DATA_MASK;` → `uint64_t ro = data;` | `swift: class list not found` |
| `if (v <= 0) return c->err;` → `if (v < 0) return c->err;` | `nlcls: classes walked 2, want 1` |
| `uint32_t allowed = rel ? MML_RELATIVE : 3u;` → `uint32_t allowed = 0xFFFFFFFFu;` | `direct selectors: rc 0` |
| delete the `if (list_va & 3)` refusal | `list of lists: rc` |
| `8 + (uint64_t)entsize * count` → `8` | `list past its segment: rc 0` |
| `if (!c.err && c.chained)` → `if (0)` | `chained: rc 0` |

After the last revert, rebuild, confirm the hash matches the Step 5 binary's, and run the full suite:

Run: `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir $B`
Expected: every test passes, `objc_meth_test` included.

- [ ] **Step 7: Commit**

```bash
git add src/objc_meth.h src/objc_meth.c tests/relmeth_fixture.h tests/objc_meth_test.c CMakeLists.txt
git commit -m "$(cat <<'EOF'
feat(objc): find the method lists classes and metaclasses name

A new read-only walk, mml_walk_image, follows __objc_classlist and
__objc_nlclslist to each class record, masks the Swift tag bits off its
data word, reads class_ro_t.baseMethods, and does the same for the
metaclass through isa. It records every slot that names a list, and
tells relative lists (entsizeAndFlags 0x8000000c) from absolute ones.

It refuses what it cannot read, with the reason: chained fixups,
unknown list flags such as the shared cache's direct selectors, a wrong
entry size, a list-of-lists pointer, and a list that runs past its
segment.

The fixture is hand-built, because no linker on a 10.9 host emits
relative method lists.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
)"
```

---

### Task 2: Categories and protocols, and counting distinct lists

**Files:**
- Modify: `src/objc_meth.c` (the `MML_LISTS` table, `mml_record`, and two new walkers above `mml_record`)
- Test: `tests/objc_meth_test.c`

**Interfaces:**
- Consumes: Task 1's `mml_walk_image`, `mml_ref`, `mml_walk`, `nth_of`, `count_of` and `walk` (test helpers), and `RMF_SHARED` / `RMF_ABSCAT`.
- Produces: the same interface, now reaching `MML_CATEGORY` and `MML_PROTOCOL` refs. `w->relative` / `w->absolute` count distinct lists across all four owners.

- [ ] **Step 1: Write the failing tests**

Add to `tests/objc_meth_test.c` above `main`:

```c
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
```

and call them from `main` after `test_a_class_listed_twice_is_walked_once();`:

```c
    test_category_and_protocol_lists();
    test_a_shared_list_counts_once();
    test_absolute_lists_are_counted_apart();
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `/usr/local/bin/shipyard-cmake --build $B -j && $B/objc_meth_test`
Expected: FAIL `plain: category instanceMethods not found`, `plain: protocol instanceMethods not found`, `plain: 2 slots, want 4`, and the matching lines for `shared` and `abscat`.

- [ ] **Step 3: Write the minimal implementation**

In `src/objc_meth.c`, add the offsets next to the existing `MML_RO_METHODS`:

```c
#define MML_CAT_INSTANCE 16
#define MML_CAT_CLASS    24
#define MML_CAT_SIZE     32
#define MML_PROTO_FIRST  24   /* instance, class, optional instance, optional class */
#define MML_PROTO_SIZE   56
```

Replace the `MML_LISTS` table with:

```c
static const struct { const char *name; int owner; } MML_LISTS[] = {
    { "__objc_classlist", MML_CLASS },
    { "__objc_nlclslist", MML_CLASS },
    { "__objc_catlist",   MML_CATEGORY },
    { "__objc_nlcatlist", MML_CATEGORY },
    { "__objc_protolist", MML_PROTOCOL },
};
```

Replace `mml_record` with these three functions:

```c
static int mml_category(mml_ctx *c, uint64_t va) {
    int v;
    if (!va) return 0;
    v = mml_first_visit(c, va);
    if (v <= 0) return c->err;
    if (mml_off(c, va, MML_CAT_SIZE) < 0)
        return mml_fail(c, MML_MALFORMED, "the category record at 0x%llx lies outside the file",
                        (unsigned long long)va);
    c->w->owners[MML_CATEGORY]++;
    if (mml_list(c, va + MML_CAT_INSTANCE, MML_CATEGORY) != 0) return c->err;
    return mml_list(c, va + MML_CAT_CLASS, MML_CATEGORY);
}

static int mml_protocol(mml_ctx *c, uint64_t va) {
    int v;
    if (!va) return 0;
    v = mml_first_visit(c, va);
    if (v <= 0) return c->err;
    if (mml_off(c, va, MML_PROTO_SIZE) < 0)
        return mml_fail(c, MML_MALFORMED, "the protocol record at 0x%llx lies outside the file",
                        (unsigned long long)va);
    c->w->owners[MML_PROTOCOL]++;
    for (int k = 0; k < 4; k++)
        if (mml_list(c, va + MML_PROTO_FIRST + 8 * k, MML_PROTOCOL) != 0) return c->err;
    return 0;
}

static int mml_record(mml_ctx *c, uint64_t va, int owner) {
    if (owner == MML_CATEGORY) return mml_category(c, va);
    if (owner == MML_PROTOCOL) return mml_protocol(c, va);
    return mml_class(c, va, owner);
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `/usr/local/bin/shipyard-cmake --build $B -j && $B/objc_meth_test`
Expected: `objc_meth_test: 0 failure(s)`.

- [ ] **Step 5: Prove the tests bite (mutations)**

Use the same hash-confirmed loop as in Task 1 Step 6.

| mutation in `src/objc_meth.c` | must fail |
|---|---|
| `va + MML_PROTO_FIRST + 8 * k` → `va + MML_PROTO_FIRST + 8 + 8 * k` | `plain: protocol instanceMethods not found` |
| `va + MML_CAT_INSTANCE` → `va + MML_CAT_CLASS` | `plain: category instanceMethods not found` |
| `if (w->refs[i].list_va == list_va) fresh = 0;` → deleted | `shared: 4 relative lists, want 3` |
| `if (fresh) { if (rel) w->relative++; else w->absolute++; }` → `if (fresh) w->relative++;` | `abscat: 4 relative, 0 absolute` |
| remove the `{ "__objc_catlist", MML_CATEGORY },` row | `plain: category instanceMethods not found` |

After the last revert, rebuild, confirm the hash matches Step 4's, and run the full suite.

Run: `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir $B`
Expected: every test passes.

- [ ] **Step 6: Commit**

```bash
git add src/objc_meth.c tests/objc_meth_test.c
git commit -m "$(cat <<'EOF'
feat(objc): find the method lists categories and protocols name

The walk now follows __objc_catlist and __objc_nlcatlist to each
category's instance and class method lists, and __objc_protolist to all
four of each protocol's lists.

Protocols are walked even though no linker is known to emit relative
lists for them. The walk costs nothing when there are none, and a
relative list it missed would crash 10.9's runtime.

relative and absolute now count distinct lists, so a list that two
records share is counted once. Every slot that names it is still
recorded, because each one will need repointing.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
)"
```

---

### Task 3: `info` prints the `method-lists:` line

**Files:**
- Create: `tests/mkrelmeth.c`
- Modify: `cli/drydock-macho-rewrite.c:92` (includes), and `info_image` (`cli/drydock-macho-rewrite.c:436-439`, just after the `swift-abi:` lines)
- Test: `tests/cli_test.sh`. There are two insertions. One goes after the fat `swift-abi` check (the line reading `|| bad "info fat" "wanted 2 swift-abi lines, ...`, near line 2482). The other goes after the `info swift-abi after retag` assertion (near line 3345).

**Interfaces:**
- Consumes: Task 2's `mml_walk_image` / `mml_walk_free`, and `rmf_build` with its variant bits.
- Produces: the `info` line in exactly these four shapes:
  - `method-lists: none`
  - `method-lists: R relative, A absolute`
  - `method-lists: not walked: <why>`
  - The CLI tool `mkrelmeth make VARIANT OUT`, with VARIANT one of `plain chained direct listlist oob shared abscat nlcls swift badent`, exit 0 on success and 2 on usage.

- [ ] **Step 1: Write the fixture tool**

Create `tests/mkrelmeth.c`:

```c
/* tests/mkrelmeth.c -- writes one variant of tests/relmeth_fixture.h's image:
 *   mkrelmeth make VARIANT OUT */
#include <stdio.h>
#include <string.h>

#include "relmeth_fixture.h"

static const struct { const char *name; unsigned bits; } VARIANTS[] = {
    { "plain", RMF_PLAIN },     { "chained", RMF_CHAINED }, { "direct", RMF_DIRECT },
    { "listlist", RMF_LISTLIST }, { "oob", RMF_OOB },       { "shared", RMF_SHARED },
    { "abscat", RMF_ABSCAT },   { "nlcls", RMF_NLCLS },     { "swift", RMF_SWIFT },
    { "badent", RMF_BADENT },
};

int main(int argc, char **argv) {
    static uint8_t b[RMF_SIZE];
    size_t i, n, nv = sizeof VARIANTS / sizeof VARIANTS[0];
    FILE *f;

    if (argc != 4 || strcmp(argv[1], "make") != 0) {
        fprintf(stderr, "usage: mkrelmeth make VARIANT OUT\n");
        return 2;
    }
    for (i = 0; i < nv; i++)
        if (strcmp(argv[2], VARIANTS[i].name) == 0) break;
    if (i == nv) {
        fprintf(stderr, "mkrelmeth: unknown variant '%s'\n", argv[2]);
        return 2;
    }
    n = rmf_build(b, VARIANTS[i].bits);
    f = fopen(argv[3], "wb");
    if (!f) { perror(argv[3]); return 1; }
    if (fwrite(b, 1, n, f) != n) { perror(argv[3]); fclose(f); return 1; }
    return fclose(f) == 0 ? 0 : 1;
}
```

- [ ] **Step 2: Write the failing tests**

In `tests/cli_test.sh`, immediately after the fat `swift-abi` check (`|| bad "info fat" "wanted 2 swift-abi lines, got ..."`), add:

```sh
[ "$(grep -c '^method-lists: ' "$T/fat.out")" -eq 2 ] \
    && ok "info fat: a method-lists line per slice" \
    || bad "info fat" "wanted 2 method-lists lines, got $(grep -c '^method-lists: ' "$T/fat.out")"
```

After the `info swift-abi after retag` assertion (`|| bad "info swift-abi after retag" "still reports tagged records"`), add:

```sh
# ---- info: the method-lists line ------------------------------------------
# tests/mkrelmeth.c writes tests/relmeth_fixture.h's hand-built image; no
# linker on a 10.9 host emits relative method lists.
"$CC" -O2 -o "$T/mkrelmeth" "$HERE/mkrelmeth.c"
for v in plain chained abscat oob; do "$T/mkrelmeth" make "$v" "$T/relmeth_$v"; done
info_ml() { "$DRYDOCK_MACHO_REWRITE" info "$1" 2>/dev/null | grep '^method-lists: ' || true; }

[ "$(info_ml "$T/signing_probe")" = "method-lists: none" ] \
    && ok "info: an image with no Objective-C says method-lists: none" \
    || bad "info method-lists none" "got: '$(info_ml "$T/signing_probe")'"
[ "$(info_ml "$T/swift_fixture")" = "method-lists: none" ] \
    && ok "info: class records naming no method list say none" \
    || bad "info method-lists swift" "got: '$(info_ml "$T/swift_fixture")'"
[ "$(info_ml "$T/relmeth_plain")" = "method-lists: 4 relative, 0 absolute" ] \
    && ok "info: counts the relative lists of a class, metaclass, category and protocol" \
    || bad "info method-lists plain" "got: '$(info_ml "$T/relmeth_plain")'"
[ "$(info_ml "$T/relmeth_abscat")" = "method-lists: 3 relative, 1 absolute" ] \
    && ok "info: counts absolute lists apart" \
    || bad "info method-lists abscat" "got: '$(info_ml "$T/relmeth_abscat")'"
[ "$(info_ml "$T/relmeth_chained")" = "method-lists: not walked: the image has chained fixups; fixups set classic first" ] \
    && ok "info: a chained image says why it was not walked" \
    || bad "info method-lists chained" "got: '$(info_ml "$T/relmeth_chained")'"
case "$(info_ml "$T/relmeth_oob")" in
    "method-lists: not walked: "*"runs past its segment") ok "info: an unreadable list is named" ;;
    *) bad "info method-lists oob" "got: '$(info_ml "$T/relmeth_oob")'" ;;
esac
rc=0; "$DRYDOCK_MACHO_REWRITE" info "$T/relmeth_oob" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] \
    && ok "info: an unreadable method list is an answer, not a failure of info (0)" \
    || bad "info method-lists oob exit" "exited $rc"
```

The `none` assertions are positive matches on a present line, not grep negatives. The `fat.out` count has the `swift-abi` count just above it as its control.

- [ ] **Step 3: Run it to make sure it fails**

Run: `/usr/local/bin/shipyard-cmake --build $B -j && sh tests/cli_test.sh $B 2>&1 | grep -E 'method-lists'`
Expected: every new assertion prints `FAIL`, the `got:` fields are empty (`info` prints no such line yet), and `wanted 2 method-lists lines, got 0`.

- [ ] **Step 4: Write the minimal implementation**

In `cli/drydock-macho-rewrite.c`, after `#include "swift_retag.h"` (line 92), add:

```c
#include "objc_meth.h"
```

In `info_image`, immediately after the `swift-abi:` `if`/`else` (lines 436-439), add:

```c
    {
        mml_walk w;
        int rc = mml_walk_image(im, &w);
        if (rc != MML_OK)
            printf("method-lists: not walked: %s\n", w.why);
        else if (w.relative + w.absolute == 0)
            printf("method-lists: none\n");
        else
            printf("method-lists: %u relative, %u absolute\n", w.relative, w.absolute);
        mml_walk_free(&w);
    }
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `/usr/local/bin/shipyard-cmake --build $B -j && sh tests/cli_test.sh $B 2>&1 | grep -E 'method-lists|failure'`
Expected: every `method-lists` assertion prints `PASS`, and the last line reads `cli_test: 0 failure(s)`.

- [ ] **Step 6: Prove the tests bite (mutations)**

Use the same hash-confirmed loop as in Task 1 Step 6, hashing `$B/drydock-macho-rewrite`. Touch `cli/drydock-macho-rewrite.c` if the hash is unchanged.

| mutation in `cli/drydock-macho-rewrite.c` | must fail |
|---|---|
| `w.relative, w.absolute);` → `w.absolute, w.relative);` | `info method-lists plain` |
| `if (rc != MML_OK)` → `if (rc == MML_NOMEM)` | `info method-lists chained` |
| `else if (w.relative + w.absolute == 0)` → `else if (w.absolute == 0)` | `info method-lists plain` (prints `none`) |
| delete the whole new block | `info fat` (`got 0`) and every `info method-lists` check |

After the last revert, rebuild, confirm the hash matches Step 5's, and run the full suite:

Run: `unset DRYDOCK_MACHO_REWRITE; /usr/local/mavericks-shipyard/bin/ctest --test-dir $B`
Expected: every test passes, including `cli_test`, `wrapper_test`, `bake_mavericks_shim_test`, `grown_binary_runs_test` and `import_redirect_test`. Each of those reads `info` output, so a pass there shows the new flush-left line broke none of their patterns.

- [ ] **Step 7: Commit**

```bash
git add tests/mkrelmeth.c cli/drydock-macho-rewrite.c tests/cli_test.sh
git commit -m "$(cat <<'EOF'
feat(info): report an image's relative and absolute method lists

info prints one method-lists line per image, beside swift-abi:
"R relative, A absolute", "none", or "not walked: <reason>". The
counts are the distinct lists that the image's classes, metaclasses,
categories and protocols name.

10.9's runtime reads a relative list's header as a 2 GB entry size, so
this line answers whether a binary built for macOS 11 or later will
crash at its first message send.

A chained image is not walked. Its pointers are not addresses until
fixups set classic has run, and the line says so.

tests/mkrelmeth.c writes the hand-built fixture for the shell suites.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Q1j6Cb64TVevZhv65dEfvF
EOF
)"
```

---

## Self-Review

**Spec coverage (M1 only).**

| M1 requirement | covered by |
|---|---|
| Decision 4's table: classes, metaclasses via `isa`, both class lists, the Swift mask, walking by section name in any segment | Task 1 |
| Categories, protocols, one visit per record, one count per list | Task 2 |
| Decision 3's shape refusals: direct selectors, other flags, wrong entsize, list of lists | Task 1 (`mml_list`) |
| Decision 2's chained refusal | Task 1 |
| Decision 5's `info` line in all four shapes, and once per fat slice | Task 3 |
| Synthetic fixture | Tasks 1 and 3 |
| README untouched | Global Constraints |

Not in M1, by the spec's own split: selector resolution, the rebase module, the segment insertion, the statement, `target` and the live test.

**Placeholder scan.** Every code step shows its code, and every run step names its command and expected output. A mutation row that no assertion could see (`w.relative == 0` for the `none` test: every fixture that reaches that branch has relative lists) was replaced with one that `info method-lists plain` catches.

**Type consistency.**

- The names match across all three tasks and both test files: `mml_walk_image`, `mml_walk_free`, `mml_ref.{slot_off,list_va,list_off,header,count,owner}`, `mml_walk.{refs,n,cap,relative,absolute,owners,why}`, `MML_CLASS`/`MML_METACLASS`/`MML_CATEGORY`/`MML_PROTOCOL`/`MML_NOWNERS`, and `MML_OK`/`MML_CHAINED`/`MML_MALFORMED`/`MML_NOMEM`.
- `rmf_build(uint8_t *, unsigned)` returns `size_t`, and so does its only callers' use of it.
- `RMF_REL_HEADER` (`0x8000000c`) and `RMF_ABS_HEADER` (`0x18`) are the fixture's own constants. They are deliberately not `MML_*`, so the oracle does not share the code under test's definitions.

## Execution Handoff

This plan is not to be executed yet: the owner asks before any plan starts. When it runs, subagent-driven development applies (one implementer per task, run to the end, review at the end), per the owner's standing preference.
