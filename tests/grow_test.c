/*
 * grow_test.c — hermetic tests for the LC_FUNCTION_STARTS base re-encode
 * that macho_grow performs when it lowers the image base.
 *
 * THE bug this pins: change_dylib -grow lowers __TEXT.vmaddr by N to make header
 * room while keeping every section's VM address fixed. LC_FUNCTION_STARTS encodes
 * its FIRST delta relative to the image base, so after the grow that delta is N
 * too small and every function address avxemu reconstructs is N low — it then
 * can't map faulting instructions to functions and declines to patch them (a
 * SIGILL storm). The fix: add N to the leading delta, preserving its byte width
 * so the blob size is unchanged.
 *
 * Ground truth here is hand-computed (small ULEB values, synthetic function
 * address lists), so the test is host-agnostic. Build:
 *   clang -O2 -Wno-unused-function -o /tmp/mgtest grow_test.c && /tmp/mgtest
 */
#include "grow.h"
#include "hdrref.h"
#include <mach-o/nlist.h>
#include <mach-o/stab.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

static int fails = 0;
#define CHECK(cond, msg, ...) do { if (!(cond)) { \
    printf("FAIL: " msg "\n", ##__VA_ARGS__); fails++; } } while (0)

/* ---- ULEB128 primitives ---- */
static void test_uleb_decode(void) {
    uint64_t v; int n;
    uint8_t a[] = {0x00};                 n = mu_decode(a, a+1, &v); CHECK(n==1 && v==0,      "uleb 0x00 -> 0 (got n=%d v=%llu)", n, (unsigned long long)v);
    uint8_t b[] = {0x7f};                 n = mu_decode(b, b+1, &v); CHECK(n==1 && v==127,    "uleb 0x7f -> 127");
    uint8_t c[] = {0x80,0x01};            n = mu_decode(c, c+2, &v); CHECK(n==2 && v==128,    "uleb 80 01 -> 128");
    uint8_t d[] = {0xc0,0x15};            n = mu_decode(d, d+2, &v); CHECK(n==2 && v==2752,   "uleb c0 15 -> 2752 (the 2.1.227 leading delta)");
    uint8_t e[] = {0xff,0x7f};            n = mu_decode(e, e+2, &v); CHECK(n==2 && v==16383,  "uleb ff 7f -> 16383");
    uint8_t f[] = {0x80,0x80,0x01};       n = mu_decode(f, f+3, &v); CHECK(n==3 && v==16384,  "uleb 80 80 01 -> 16384");
    /* runs off the end (continuation bit set, no more bytes) -> malformed */
    uint8_t g[] = {0x80};                 n = mu_decode(g, g+1, &v); CHECK(n==0,              "uleb truncated -> 0 (got n=%d)", n);
    /* ten bytes carry 70 bits; a tenth byte past 1 names bits past 64 */
    uint8_t h[] = {0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0x01};
    n = mu_decode(h, h+10, &v); CHECK(n==10 && v==UINT64_MAX, "uleb ff x9 01 -> 2^64-1 (got n=%d)", n);
    uint8_t i[] = {0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x80,0x02};
    n = mu_decode(i, i+10, &v); CHECK(n==0, "uleb 80 x9 02 overflows 64 bits -> 0 (got n=%d)", n);
}

static void test_uleb_minlen(void) {
    CHECK(mu_minlen(0)==1,       "minlen(0)=1");
    CHECK(mu_minlen(127)==1,     "minlen(127)=1");
    CHECK(mu_minlen(128)==2,     "minlen(128)=2");
    CHECK(mu_minlen(2752)==2,    "minlen(2752)=2");
    CHECK(mu_minlen(16383)==2,   "minlen(16383)=2");
    CHECK(mu_minlen(16384)==3,   "minlen(16384)=3");
    CHECK(mu_minlen(6848)==2,    "minlen(6848)=2  (2752 + one page)");
}

static void test_uleb_encode_fixed(void) {
    uint8_t buf[8]; uint64_t v; int n;
    /* minimal width */
    CHECK(mu_encode_fixed(buf, 6848, 2)==1, "encode 6848 in 2 bytes ok");
    n = mu_decode(buf, buf+2, &v); CHECK(n==2 && v==6848, "  round-trips to 6848");
    CHECK(buf[0]==0xc0 && buf[1]==0x35, "  bytes are c0 35 (expected 2.1.227 fixed leading delta)");
    /* non-minimal padding: 2752 forced into 3 bytes */
    memset(buf,0xAA,sizeof buf);
    CHECK(mu_encode_fixed(buf, 2752, 3)==1, "encode 2752 padded to 3 bytes ok");
    n = mu_decode(buf, buf+3, &v); CHECK(n==3 && v==2752, "  padded still decodes to 2752 in 3 bytes");
    /* does not fit: 16384 needs 3, width 2 -> refuse */
    CHECK(mu_encode_fixed(buf, 16384, 2)==0, "encode 16384 in 2 bytes refused");
}

/* ---- the leading-delta re-encode ---- */
static void test_reencode_same_width(void) {
    /* leading delta 2752 (c0 15) + a tail that must be preserved verbatim */
    uint8_t blob[] = {0xc0,0x15, /*tail*/ 0x50, 0x81,0x01, 0x00};
    uint8_t saved[sizeof blob]; memcpy(saved, blob, sizeof blob);
    int r = mg_reencode_funcstarts_base(blob, sizeof blob, 0x1000);
    CHECK(r==1, "reencode +0x1000 succeeds in place (got %d)", r);
    CHECK(blob[0]==0xc0 && blob[1]==0x35, "leading delta became c0 35 (2752+4096=6848)");
    CHECK(memcmp(blob+2, saved+2, sizeof blob - 2)==0, "tail bytes untouched");
}

static void test_reencode_widen_refuses(void) {
    /* leading delta 16000 (0x3e80): 16000+4096=20096 needs 3 bytes, was 2 -> refuse */
    uint8_t blob[] = {0x80,0x7d, /*tail*/ 0x40, 0x00};   /* 0x80,0x7d = 16000 */
    uint64_t chk; int n = mu_decode(blob, blob+2, &chk);
    CHECK(n==2 && chk==16000, "precondition: leading delta decodes to 16000");
    uint8_t saved[sizeof blob]; memcpy(saved, blob, sizeof blob);
    int r = mg_reencode_funcstarts_base(blob, sizeof blob, 0x1000);
    CHECK(r==0, "reencode refuses when the delta would widen (got %d)", r);
    CHECK(memcmp(blob, saved, sizeof blob)==0, "blob left untouched on refusal");
}

static void test_reencode_nonminimal_original_preserved(void) {
    /* leading delta 2752 encoded NON-minimally in 3 bytes (c0 95 00); +0x1000 must
     * stay 3 bytes and still decode correctly. */
    uint8_t blob[] = {0xc0,0x95,0x00, /*tail*/ 0x50, 0x00};
    int r = mg_reencode_funcstarts_base(blob, sizeof blob, 0x1000);
    CHECK(r==1, "reencode of a non-minimally-encoded leading delta succeeds");
    uint64_t v; int n = mu_decode(blob, blob+3, &v);
    CHECK(n==3 && v==6848, "leading delta still 3 bytes, decodes to 6848 (got n=%d v=%llu)", n, (unsigned long long)v);
    CHECK(blob[3]==0x50, "tail preserved");
}

static void test_reencode_malformed(void) {
    uint8_t empty[1] = {0};
    CHECK(mg_reencode_funcstarts_base(empty, 0, 0x1000)==-1, "empty blob -> -1");
    uint8_t trunc[] = {0x80};   /* continuation with no successor */
    CHECK(mg_reencode_funcstarts_base(trunc, 1, 0x1000)==-1, "truncated leading ULEB -> -1");
}

/* ---- THE INVARIANT: the grow must move no function ---- */
static void build_funcstarts(uint8_t *out, int *outlen, uint64_t base,
                             const uint64_t *addrs, int n) {
    int len = 0; uint64_t prev = base;
    for (int i = 0; i < n; i++) {
        int w = mu_minlen(addrs[i] - prev);
        mu_encode_fixed(out + len, addrs[i] - prev, w);
        len += w; prev = addrs[i];
    }
    out[len++] = 0x00;   /* terminator */
    *outlen = len;
}

static void test_invariant_addresses_preserved(void) {
    const uint64_t base = 0x100000000ull;
    const uint32_t N = 0x1000;
    /* a realistic ascending function list; first delta 0xac0 stays 2 bytes under +N */
    uint64_t addrs[] = { base+0xac0, base+0xb30, base+0x1200, base+0x1abc, base+0x2f00 };
    int n = (int)(sizeof addrs / sizeof addrs[0]);

    uint8_t blob[64]; int blen; build_funcstarts(blob, &blen, base, addrs, n);
    uint32_t orig_blen = (uint32_t)blen;

    /* grow: lower the base by N and re-encode the leading delta */
    int r = mg_reencode_funcstarts_base(blob, (uint32_t)blen, N);
    CHECK(r==1, "invariant setup: reencode succeeds");
    CHECK((uint32_t)blen == orig_blen, "blob size unchanged by reencode");

    /* decode at the LOWERED base; every absolute address must be identical */
    uint64_t got[16]; int gn = mg_funcstarts_decode(blob, (uint32_t)blen, base - N, got, 16);
    CHECK(gn == n, "same function count after grow (got %d want %d)", gn, n);
    for (int i = 0; i < n && i < gn; i++)
        CHECK(got[i] == addrs[i], "function[%d] address preserved: got %#llx want %#llx",
              i, (unsigned long long)got[i], (unsigned long long)addrs[i]);
}

/* ---- __TEXT,__init_offsets re-base ----
 * Entries are offsets from the mach header, so lowering the base leaves them
 * all `grow` too small. Sections are matched by TYPE (S_INIT_FUNC_OFFSETS)
 * rather than by name: the name is a linker convention, the type is what the
 * format guarantees. Driven against a synthetic image because the 10.9
 * toolchain cannot emit an __init_offsets section to build a fixture from. */
static void test_init_offsets_rebase(void) {
    static uint8_t img[8192];
    memset(img, 0, sizeof img);
    struct mach_header_64 *h = (struct mach_header_64 *)img;
    h->magic = MH_MAGIC_64;
    h->ncmds = 1;
    struct segment_command_64 *seg = (struct segment_command_64 *)(img + sizeof *h);
    seg->cmd = LC_SEGMENT_64;
    seg->cmdsize = sizeof(*seg) + sizeof(struct section_64);
    strcpy(seg->segname, "__TEXT");
    seg->nsects = 1;
    h->sizeofcmds = seg->cmdsize;
    struct section_64 *s = (struct section_64 *)((uint8_t *)seg + sizeof *seg);
    strncpy(s->sectname, "__init_offsets", sizeof s->sectname);
    strncpy(s->segname, "__TEXT", sizeof s->segname);
    s->offset = 4096;
    s->size = 3 * sizeof(uint32_t);
    s->flags = S_INIT_FUNC_OFFSETS;
    uint32_t *e = (uint32_t *)(img + 4096);
    e[0] = 0x1000; e[1] = 0x2000; e[2] = 0x3000;

    CHECK(mg_init_offsets_pass(img, sizeof img, 0x1000, 1) == 0, "init_offsets patch returns 0");
    CHECK(e[0] == 0x2000 && e[1] == 0x3000 && e[2] == 0x4000,
          "every entry gained grow (got %u %u %u)", e[0], e[1], e[2]);

    /* A section of another type must be left alone, even named __init_offsets. */
    s->flags = S_REGULAR;
    e[0] = 0x1000;
    CHECK(mg_init_offsets_pass(img, sizeof img, 0x1000, 1) == 0 && e[0] == 0x1000,
          "sections of other types untouched (got %u)", e[0]);

    /* An entry that would wrap is refused by the audit, before anything moves. */
    s->flags = S_INIT_FUNC_OFFSETS;
    e[0] = 0xffffffffu;
    CHECK(mg_init_offsets_pass(img, sizeof img, 0x1000, 0) == -1, "overflowing entry refused");
}

/* ---- the whole grow, end to end ----
 * Every other case here calls one helper directly. That is how a duplicated
 * re-base survived review: two functions each added `grow` to the same
 * __init_offsets entries, mg_grow_header called both, and no test ran the path
 * that used them. This builds the smallest image mg_grow_header will accept and
 * checks the entries afterwards, so any second application shows up as 2*grow.
 *
 * Deliberately carries no LC_FUNCTION_STARTS and no export trie: both are
 * audited separately, and leaving them out keeps this about the one structure.
 */
/* opts: MG_T_DICE adds an LC_DATA_IN_CODE whose entries are base-relative;
 * MG_T_UNWIND adds a __TEXT,__unwind_info section. macho_grow rebases neither,
 * so a grow of an image carrying either must refuse rather than corrupt it. */
/* offsets within the synthetic __unwind_info section */
#define UW_PERS_OFF  28
#define UW_IDX_OFF   32
#define UW_LSDA_OFF  56
#define UW_LSDA_END  64
#define UW_PAGE_OFF  72
#define UW_ENT_OFF   80
#define UW32(b, secoff, off) (*(uint32_t *)((b) + (secoff) + (off)))

#define MG_T_DICE   1
#define MG_T_UNWIND 2
#define MG_T_TRIE   4
#define MG_T_UNKNOWN_LC 8    /* a load command we have never classified */
#define MG_T_LOH   16    /* LC_LINKER_OPTIMIZATION_HINT: base-relative, unhandled */
#define MG_T_ODDSECT 32  /* a section whose TYPE we do not know */
#define MG_T_FUNCSTARTS 64
#define MG_T_MAIN 128    /* LC_MAIN: entryoff, a uint64_t base-relative-in-effect
                           * file offset -- see test_grow_refuses_overflowing_entryoff */
#define MG_T_PLAINSECT 256   /* an S_REGULAR section with an unremarkable name --
                               * not __unwind_info (bounds-checked by mg_unwind_walk's
                               * own pre-check before the offset bump ever runs),
                               * not S_INIT_FUNC_OFFSETS (bounds-checked by mg_collect
                               * the same way) -- so mg_each_fileoff's section-
                               * offset bump is the ONLY code that bounds its
                               * offset field. See
                               * test_grow_refuses_overflowing_section_offset. Uses
                               * the same section slot as MG_T_UNWIND; never combine
                               * the two in one build_image() call. */
#define MG_T_NOTE 512        /* LC_NOTE: refused outright by mg_classify (its shape
                               * is not verified against any header on hand -- see
                               * src/linkedit.h's top comment). Before this option
                               * existed, mg_classify's LC_NOTE refusal had ZERO test
                               * coverage: a mutation that moved it from the refusal
                               * bucket into the inert (accepted) bucket, without
                               * touching src/linkedit.c's ml_bump_lc to match, made
                               * every test in this suite pass anyway. See
                               * test_grow_refuses_note. */
#define MG_T_ATOM_INFO 1024  /* LC_ATOM_INFO: same story as MG_T_NOTE -- refused,
                               * previously untested. See test_grow_refuses_atom_info. */
#define MG_T_CHAINED 2048    /* LC_DYLD_CHAINED_FIXUPS: refused by mg_classify,
                               * because chained pointers encode offsets from the
                               * image base, which growing moves. See
                               * test_ensure_pad_refuses_what_cannot_grow. */
#define MG_T_LINKEDIT 4096   /* __TEXT ends at 6144; a __LINKEDIT segment maps the
                               * rest, so a later segment's fileoff has to move */
#define MG_T_SYMTAB 8192     /* LC_SYMTAB: file offsets whose content nothing
                               * re-bases, so only resolving them can watch them */

/* note_command isn't in the 10.9 SDK's <mach-o/loader.h> (see
 * src/mach_compat.h's own comment on LC_NOTE); this is dyld/ld64's publicly
 * documented layout, defined locally because this test is the only place in
 * the tree that needs the full struct -- src/grow.c only needs the constant. */
struct mg_test_note_command {
    uint32_t cmd;
    uint32_t cmdsize;
    char data_owner[16];
    uint64_t offset;
    uint64_t size;
};
#define FS_OFF 7680
#define TRIE_OFF    7168
static uint8_t *build_image(size_t *fsize_out, uint32_t *sect_off_out, int opts) {
    const size_t fsize = 8192;
    uint8_t *buf = (uint8_t *)calloc(1, fsize);

    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    h->ncmds = 2;

    struct segment_command_64 *pz = (struct segment_command_64 *)(buf + sizeof *h);
    pz->cmd = LC_SEGMENT_64;
    pz->cmdsize = sizeof *pz;
    strcpy(pz->segname, "__PAGEZERO");
    pz->vmaddr = 0;
    pz->vmsize = 0x100000000ull;   /* room to lower the base into */
    pz->fileoff = 0;
    pz->filesize = 0;              /* filesize 0 keeps it out of the __TEXT probe */

    int tx_nsects = 1 + ((opts & (MG_T_UNWIND | MG_T_PLAINSECT)) ? 1 : 0);
    struct segment_command_64 *tx = (struct segment_command_64 *)((uint8_t *)pz + pz->cmdsize);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + tx_nsects * sizeof(struct section_64);
    strcpy(tx->segname, "__TEXT");
    tx->vmaddr = 0x100000000ull;
    tx->vmsize = fsize;
    tx->fileoff = 0;
    tx->filesize = fsize;
    tx->nsects = tx_nsects;

    struct section_64 *sc = (struct section_64 *)((uint8_t *)tx + sizeof *tx);
    strncpy(sc->sectname, "__init_offsets", sizeof sc->sectname);
    strncpy(sc->segname, "__TEXT", sizeof sc->segname);
    sc->addr = 0x100001000ull;
    sc->size = 2 * sizeof(uint32_t);
    sc->offset = 4096;
    sc->flags = S_INIT_FUNC_OFFSETS;   /* a real one carries both name and type */

    h->sizeofcmds = (uint32_t)(pz->cmdsize + tx->cmdsize);

    if (opts & MG_T_PLAINSECT) {
        struct section_64 *plain = sc + 1;   /* same slot MG_T_UNWIND uses -- never combine */
        strncpy(plain->sectname, "__plain", sizeof plain->sectname);
        strncpy(plain->segname, "__TEXT", sizeof plain->segname);
        plain->addr = 0x100003000ull;
        plain->size = 16;
        plain->offset = 6144;   /* arbitrary in-bounds default; the test pokes it */
        plain->flags = S_REGULAR;
    }

    if (opts & MG_T_UNWIND) {
        struct section_64 *uw = sc + 1;
        strncpy(uw->sectname, "__unwind_info", sizeof uw->sectname);
        strncpy(uw->segname,  "__TEXT",        sizeof uw->segname);
        uw->addr = 0x100002000ull;
        uw->size = 128;
        uw->offset = 5120;
        uw->flags = S_REGULAR;   /* the TYPE says nothing here; the NAME is what matters */

        /* A compact-unwind section with one of every field family, so the test
         * can tell a handler that bumps the right things from one that bumps
         * everything. Layout mirrors the real format. */
        uint32_t *h32 = (uint32_t *)(buf + uw->offset);
        h32[0] = 1;                 /* version */
        h32[1] = 0;                 /* commonEncodingsArraySectionOffset */
        h32[2] = 0;                 /* commonEncodingsArrayCount */
        h32[3] = UW_PERS_OFF;       /* personalityArraySectionOffset */
        h32[4] = 1;                 /* personalityArrayCount */
        h32[5] = UW_IDX_OFF;        /* indexSectionOffset */
        h32[6] = 2;                 /* indexCount (one real entry + the sentinel) */

        UW32(buf, uw->offset, UW_PERS_OFF)      = 0x9000;   /* base-relative -> GOT */

        UW32(buf, uw->offset, UW_IDX_OFF + 0)   = 0x1000;   /* functionOffset  BASE-REL */
        UW32(buf, uw->offset, UW_IDX_OFF + 4)   = UW_PAGE_OFF; /* page   section-rel */
        UW32(buf, uw->offset, UW_IDX_OFF + 8)   = UW_LSDA_OFF; /* lsda   section-rel */
        UW32(buf, uw->offset, UW_IDX_OFF + 12)  = 0x8000;   /* sentinel fnOff  BASE-REL */
        UW32(buf, uw->offset, UW_IDX_OFF + 16)  = 0;        /* sentinel has no page */
        UW32(buf, uw->offset, UW_IDX_OFF + 20)  = UW_LSDA_END;

        UW32(buf, uw->offset, UW_LSDA_OFF + 0)  = 0x1100;   /* lsda functionOffset BASE-REL */
        UW32(buf, uw->offset, UW_LSDA_OFF + 4)  = 0x7000;   /* lsdaOffset          BASE-REL */

        UW32(buf, uw->offset, UW_PAGE_OFF + 0)  = 3;        /* kind = COMPRESSED */
        *(uint16_t *)(buf + uw->offset + UW_PAGE_OFF + 4) = 8;  /* entryPageOffset */
        *(uint16_t *)(buf + uw->offset + UW_PAGE_OFF + 6) = 2;  /* entryCount */
        /* Compressed entries: low 24 bits are a DELTA from this page's own
         * first-level functionOffset. Invariant under a uniform bump -- bumping
         * them is the silent corruption this test exists to catch. */
        UW32(buf, uw->offset, UW_ENT_OFF + 0)   = 0x00000010u | (1u << 24);
        UW32(buf, uw->offset, UW_ENT_OFF + 4)   = 0x00000040u | (2u << 24);
    }

    uint8_t *lcend = (uint8_t *)tx + tx->cmdsize;

    if (opts & MG_T_LINKEDIT) {
        tx->vmsize = tx->filesize = 6144;
        struct segment_command_64 *le = (struct segment_command_64 *)lcend;
        le->cmd = LC_SEGMENT_64;
        le->cmdsize = sizeof *le;
        strcpy(le->segname, "__LINKEDIT");
        le->vmaddr = tx->vmaddr + 6144;
        le->vmsize = le->filesize = fsize - 6144;
        le->fileoff = 6144;
        h->ncmds++; h->sizeofcmds += le->cmdsize; lcend += le->cmdsize;
    }
    if (opts & MG_T_SYMTAB) {
        struct symtab_command *st = (struct symtab_command *)lcend;
        st->cmd = LC_SYMTAB;
        st->cmdsize = sizeof *st;
        st->symoff = 6656; st->nsyms = 1;
        st->stroff = 6720; st->strsize = 8;
        h->ncmds++; h->sizeofcmds += st->cmdsize; lcend += st->cmdsize;
    }

    if (opts & MG_T_DICE) {
        struct linkedit_data_command *dc = (struct linkedit_data_command *)lcend;
        dc->cmd = LC_DATA_IN_CODE;
        dc->cmdsize = sizeof *dc;
        dc->dataoff = 6144;
        dc->datasize = 16;       /* two 8-byte entries */
        h->ncmds++; h->sizeofcmds += dc->cmdsize; lcend += dc->cmdsize;
        /* two data_in_code_entry: { uint32 offset; uint16 length; uint16 kind }.
         * Only `offset` is base-relative; length and kind must survive intact. */
        UW32(buf, dc->dataoff, 0) = 0x1500;
        *(uint16_t *)(buf + dc->dataoff +  4) = 0x20;
        *(uint16_t *)(buf + dc->dataoff +  6) = 4;      /* DICE_KIND_JUMP_TABLE32 */
        UW32(buf, dc->dataoff, 8) = 0x2500;
        *(uint16_t *)(buf + dc->dataoff + 12) = 0x40;
        *(uint16_t *)(buf + dc->dataoff + 14) = 4;
    }

    if (opts & MG_T_TRIE) {
        struct dyld_info_command *di = (struct dyld_info_command *)lcend;
        di->cmd = LC_DYLD_INFO_ONLY;
        di->cmdsize = sizeof *di;
        di->export_off = TRIE_OFF;
        di->export_size = 17;
        h->ncmds++; h->sizeofcmds += di->cmdsize; lcend += di->cmdsize;

        /* A hand-built export trie, 17 bytes:
         *   root: no terminal, two children "A" -> 8, "B" -> 13
         *   node A: terminal, flags 0, address 0x1000 (2-byte ULEB)
         *   node B: terminal, flags 0, address 0 -- the __mh_execute_header
         *           case, which names the header and must STAY 0. */
        static const uint8_t trie[17] = {
            0x00, 0x02,
            'A', 0x00, 8,
            'B', 0x00, 13,
            0x03, 0x00, 0x80, 0x20, 0x00,     /* A: termsz 3, flags 0, addr 0x1000, 0 kids */
            0x02, 0x00, 0x00, 0x00            /* B: termsz 2, flags 0, addr 0,      0 kids */
        };
        memcpy(buf + TRIE_OFF, trie, sizeof trie);
    }

    if (opts & MG_T_UNKNOWN_LC) {
        struct load_command *xc = (struct load_command *)lcend;
        xc->cmd = 0x7fff;                 /* not a real load command */
        xc->cmdsize = sizeof *xc;
        h->ncmds++; h->sizeofcmds += xc->cmdsize; lcend += xc->cmdsize;
    }
    if (opts & MG_T_LOH) {
        struct linkedit_data_command *lc2 = (struct linkedit_data_command *)lcend;
        lc2->cmd = LC_LINKER_OPTIMIZATION_HINT;
        lc2->cmdsize = sizeof *lc2;
        lc2->dataoff = 6656; lc2->datasize = 8;
        h->ncmds++; h->sizeofcmds += lc2->cmdsize; lcend += lc2->cmdsize;
    }
    if (opts & MG_T_FUNCSTARTS) {
        struct linkedit_data_command *fc = (struct linkedit_data_command *)lcend;
        fc->cmd = LC_FUNCTION_STARTS;
        fc->cmdsize = sizeof *fc;
        fc->dataoff = FS_OFF; fc->datasize = 5;
        h->ncmds++; h->sizeofcmds += fc->cmdsize; lcend += fc->cmdsize;
        /* ULEB deltas: first is from the image base. 0x1000 then +0x1000, so the
         * function starts are base+0x1000 and base+0x2000 -- exactly where the
         * two __init_offsets entries point. */
        static const uint8_t fsb[5] = { 0x80, 0x20, 0x80, 0x20, 0x00 };
        memcpy(buf + FS_OFF, fsb, sizeof fsb);
    }
    if (opts & MG_T_MAIN) {
        struct entry_point_command *ep = (struct entry_point_command *)lcend;
        ep->cmd = LC_MAIN;
        ep->cmdsize = sizeof *ep;
        ep->entryoff = 0x1000;   /* a plausible in-bounds default; tests poke it */
        ep->stacksize = 0;
        h->ncmds++; h->sizeofcmds += ep->cmdsize; lcend += ep->cmdsize;
    }
    if (opts & MG_T_NOTE) {
        struct mg_test_note_command *nc = (struct mg_test_note_command *)lcend;
        nc->cmd = LC_NOTE;
        nc->cmdsize = sizeof *nc;
        memcpy(nc->data_owner, "com.example.note", 16);   /* 16 bytes, not NUL-terminated */
        nc->offset = 6656;
        nc->size = 8;
        h->ncmds++; h->sizeofcmds += nc->cmdsize; lcend += nc->cmdsize;
    }
    if (opts & MG_T_ATOM_INFO) {
        struct linkedit_data_command *ac = (struct linkedit_data_command *)lcend;
        ac->cmd = LC_ATOM_INFO;
        ac->cmdsize = sizeof *ac;
        ac->dataoff = 6656; ac->datasize = 8;
        h->ncmds++; h->sizeofcmds += ac->cmdsize; lcend += ac->cmdsize;
    }
    if (opts & MG_T_CHAINED) {
        struct linkedit_data_command *cf = (struct linkedit_data_command *)lcend;
        cf->cmd = LC_DYLD_CHAINED_FIXUPS;
        cf->cmdsize = sizeof *cf;
        cf->dataoff = 6656; cf->datasize = 8;
        h->ncmds++; h->sizeofcmds += cf->cmdsize; lcend += cf->cmdsize;
    }
    if (opts & MG_T_ODDSECT) sc->flags = 0x7e;   /* unknown SECTION_TYPE */

    uint32_t *e = (uint32_t *)(buf + sc->offset);
    e[0] = 0x1000; e[1] = 0x2000;

    *fsize_out = fsize;
    *sect_off_out = sc->offset;
    return buf;
}

static uint8_t *build_growable_image(size_t *fsize_out, uint32_t *sect_off_out) {
    return build_image(fsize_out, sect_off_out, 0);
}

/* Shared by every "find X again after the grow moved it" helper below: visit
 * every load command via mi_each_lc and stop at the first one whose cmd
 * matches. Folds what used to be several near-identical hand-rolled ncmds
 * walks (find_dice's own loop, and the old find_lc near the bottom of this
 * file) into one. */
struct find_lc_ctx { uint32_t cmd; struct load_command *found; };
static int find_lc_cb(const struct load_command *lc, void *ctx_) {
    struct find_lc_ctx *ctx = (struct find_lc_ctx *)ctx_;
    if (lc->cmd != ctx->cmd) return 0;
    ctx->found = (struct load_command *)lc;
    return 1;
}
static struct load_command *find_lc(uint8_t *buf, size_t fsize, uint32_t cmd) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) != 0) return NULL;
    struct find_lc_ctx ctx = { cmd, NULL };
    mi_each_lc(&im, find_lc_cb, &ctx);
    return ctx.found;
}

/* Same shape as find_lc, but matching a SECTION's TYPE rather than a load
 * command's cmd -- __init_offsets is deliberately matched this way (see the
 * comment on test_init_offsets_rebase above): the type is what the format
 * guarantees, the name is only a linker convention, and mi_find_section can
 * only match by name. */
struct find_sect_by_type_ctx { uint32_t type; struct section_64 *found; };
static int find_sect_by_type_cb(const struct load_command *lc, void *ctx_) {
    struct find_sect_by_type_ctx *ctx = (struct find_sect_by_type_ctx *)ctx_;
    if (lc->cmd != LC_SEGMENT_64) return 0;
    const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
    struct section_64 *sect = (struct section_64 *)(seg + 1);
    for (uint32_t j = 0; j < seg->nsects; j++) {
        if ((sect[j].flags & SECTION_TYPE) == ctx->type) { ctx->found = &sect[j]; return 1; }
    }
    return 0;
}

/* After a grow, find __init_offsets again -- its file offset moved with the data. */
static uint32_t *find_init_offsets(uint8_t *buf, size_t fsize) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) != 0) return NULL;
    struct find_sect_by_type_ctx ctx = { S_INIT_FUNC_OFFSETS, NULL };
    mi_each_lc(&im, find_sect_by_type_cb, &ctx);
    return ctx.found ? (uint32_t *)(buf + ctx.found->offset) : NULL;
}

static void test_grow_applies_init_offsets_once(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_growable_image(&fsize, &sect_off);
    const uint32_t grow = 0x1000;

    int r = mg_grow_header(&buf, &fsize, grow);
    CHECK(r == 0, "mg_grow_header succeeds on the synthetic image (got %d)", r);
    if (r != 0) { free(buf); return; }

    uint32_t *e = find_init_offsets(buf, fsize);
    CHECK(e != NULL, "__init_offsets still locatable after the grow");
    if (e) {
        CHECK(e[0] == 0x1000 + grow, "entry 0 gained grow exactly once: got %#x want %#x",
              e[0], 0x1000 + grow);
        CHECK(e[1] == 0x2000 + grow, "entry 1 gained grow exactly once: got %#x want %#x",
              e[1], 0x2000 + grow);
    }
    free(buf);
}

/* ---- refuse what we cannot rebase ----
 * Both structures below store offsets from the image base, exactly like
 * __init_offsets and the function-starts leading delta. macho_grow relocates
 * LC_DATA_IN_CODE's blob but never rewrites the offsets inside it, and does not
 * mention __unwind_info at all. Until handlers exist, growing such an image MUST
 * fail: a silent success ships a binary whose data-in-code ranges and
 * compact-unwind entries are all `grow` bytes low, which nothing notices until
 * something unwinds. A refusal leaves the caller's buffer byte-identical.
 */
static void check_refused_unchanged(const char *what, int opts) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, opts);
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);

    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == -1, "%s: mg_grow_header refuses (got %d)", what, r);
    CHECK(fsize == fsize0, "%s: size unchanged on refusal (got %zu want %zu)",
          what, fsize, fsize0);
    if (fsize == fsize0)
        CHECK(memcmp(before, buf, fsize0) == 0,
              "%s: buffer byte-identical on refusal", what);
    free(before);
    free(buf);
}

static uint8_t *find_dice(uint8_t *buf, size_t fsize) {
    struct load_command *lc = find_lc(buf, fsize, LC_DATA_IN_CODE);
    return lc ? buf + ((struct linkedit_data_command *)lc)->dataoff : NULL;
}

/* Every entry's `offset` is measured from the image base; `length` and `kind`
 * are not offsets at all. A handler that treats the entry as three bumpable
 * words would pass a "did it change" test and corrupt every range. */
static void test_grow_rebases_data_in_code(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_DICE);
    const uint32_t g = 0x1000;

    int r = mg_grow_header(&buf, &fsize, g);
    CHECK(r == 0, "grow succeeds on an image with LC_DATA_IN_CODE (got %d)", r);
    if (r != 0) { free(buf); return; }

    uint8_t *d = find_dice(buf, fsize);
    CHECK(d != NULL, "LC_DATA_IN_CODE still locatable after the grow");
    if (!d) { free(buf); return; }
    CHECK(*(uint32_t *)(d + 0) == 0x1500 + g, "entry 0 offset gains grow: got %#x",
          *(uint32_t *)(d + 0));
    CHECK(*(uint32_t *)(d + 8) == 0x2500 + g, "entry 1 offset gains grow: got %#x",
          *(uint32_t *)(d + 8));
    CHECK(*(uint16_t *)(d +  4) == 0x20 && *(uint16_t *)(d +  6) == 4,
          "entry 0 length/kind UNTOUCHED");
    CHECK(*(uint16_t *)(d + 12) == 0x40 && *(uint16_t *)(d + 14) == 4,
          "entry 1 length/kind UNTOUCHED");
    free(buf);
}

/* After a grow, __unwind_info's file offset moved with the data. */
static uint8_t *find_unwind(uint8_t *buf, size_t fsize) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) != 0) return NULL;
    struct section_64 *sect = mi_find_section(&im, "__TEXT", "__unwind_info");
    return sect ? buf + sect->offset : NULL;
}

/* The handler must bump the four base-relative field families and leave the
 * compressed second-level entries ALONE -- those are deltas from their own
 * page's first-level functionOffset, so a uniform bump leaves them correct and
 * bumping them corrupts the tables silently. */
static void test_grow_rebases_unwind_info(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_UNWIND);
    const uint32_t g = 0x1000;

    int r = mg_grow_header(&buf, &fsize, g);
    CHECK(r == 0, "grow succeeds on an image with __unwind_info (got %d)", r);
    if (r != 0) { free(buf); return; }

    uint8_t *u = find_unwind(buf, fsize);
    CHECK(u != NULL, "__unwind_info still locatable after the grow");
    if (!u) { free(buf); return; }
    uint32_t *at = (uint32_t *)u;
#define UW_IS(off, want, what) \
    CHECK(*(uint32_t *)(u + (off)) == (uint32_t)(want), \
          "%s: got %#x want %#x", what, *(uint32_t *)(u + (off)), (uint32_t)(want))

    UW_IS(UW_PERS_OFF,      0x9000 + g, "personality entry gains grow");
    UW_IS(UW_IDX_OFF + 0,   0x1000 + g, "first-level functionOffset gains grow");
    UW_IS(UW_IDX_OFF + 12,  0x8000 + g, "sentinel functionOffset gains grow");
    UW_IS(UW_LSDA_OFF + 0,  0x1100 + g, "LSDA functionOffset gains grow");
    UW_IS(UW_LSDA_OFF + 4,  0x7000 + g, "LSDA lsdaOffset gains grow");

    /* section-relative fields must NOT move */
    UW_IS(UW_IDX_OFF + 4,  UW_PAGE_OFF, "page section-offset unchanged");
    UW_IS(UW_IDX_OFF + 8,  UW_LSDA_OFF, "LSDA section-offset unchanged");
    UW_IS(3 * 4,           UW_PERS_OFF, "personality section-offset unchanged");

    /* THE trap: compressed entries are deltas and must be untouched */
    UW_IS(UW_ENT_OFF + 0, 0x00000010u | (1u << 24), "compressed entry 0 UNTOUCHED");
    UW_IS(UW_ENT_OFF + 4, 0x00000040u | (2u << 24), "compressed entry 1 UNTOUCHED");
    (void)at;
#undef UW_IS
    free(buf);
}

/* ---- mg_unwind_find_cb's three untested branches (2026-09-09 review) ----
 * A code review round confirmed by mutation, forced rebuild, that all three
 * were unexercised by any suite in this repo -- real-binary and hermetic
 * alike -- and identical since before this code moved to src/grow.c (not a
 * regression the move introduced, but a gap it left standing). These three
 * close it. */

/* A __unwind_info section with size 0 is legal (if unusual): mg_unwind_walk
 * treats it as "nothing to do" and returns 0, not a refusal -- confirmed by
 * mutating that exact `if (!sect[j].size) return 0` away, which no fixture
 * here used to catch. */
static void test_grow_handles_zero_size_unwind_info(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_UNWIND);
    mi_image im;
    CHECK(mi_wrap(buf, fsize, &im) == 0, "setup: fixture wraps");
    struct section_64 *uw = mi_find_section(&im, "__TEXT", "__unwind_info");
    CHECK(uw != NULL, "setup: __unwind_info section present");
    if (!uw) { free(buf); return; }
    uw->size = 0;

    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "grow succeeds on a zero-size __unwind_info section (got %d)", r);
    free(buf);
}

/* A __unwind_info section whose offset+size runs past fsize must refuse --
 * confirmed by mutating that overflow guard away, which no fixture here used
 * to catch (the well-formed MG_T_UNWIND fixture never approaches fsize).
 *
 * Rather than moving the real section near the buffer's physical edge (a
 * genuine OOB-read risk in a test that doesn't run under libgmalloc), this
 * lies about the buffer's SIZE instead: claim fsize=5200, which
 * __init_offsets (ends at 4104) still fits inside but __unwind_info (offset
 * 5120 + size 128 = 5248, both real, well-formed values from MG_T_UNWIND)
 * does not. The physical allocation build_image made is still the full 8192
 * bytes, so nothing is ever actually read out of bounds -- only the overflow
 * ARITHMETIC (offset + size > fsize) sees a boundary, which is exactly what
 * this guard checks. */
static void test_grow_refuses_overflowing_unwind_info(void) {
    size_t fsize_real; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize_real, &sect_off, MG_T_UNWIND);
    (void)fsize_real;
    size_t fsize = 5200;

    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);

    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == -1, "grow refuses an __unwind_info section whose offset+size "
                   "overflows fsize (got %d)", r);
    CHECK(fsize == fsize0, "size unchanged on refusal (got %zu want %zu)", fsize, fsize0);
    if (fsize == fsize0)
        CHECK(memcmp(before, buf, fsize0) == 0, "buffer byte-identical on refusal");
    free(before);
    free(buf);
}

/* Distinguishes "stop at the FIRST section named __unwind_info" from "keep
 * going, LAST one wins" -- a mutation that flips mg_unwind_find_cb's
 * `return 1` to `return 0` passes every other test in this suite, because no
 * other fixture carries two __unwind_info-named sections. __TEXT's is the
 * real, well-formed one from MG_T_UNWIND; a second, deliberately malformed
 * one (13 bytes -- under the 28-byte minimum mg_unwind_walk's body enforces)
 * sits in a later __DATA segment. If the FIRST is used, grow succeeds; if
 * the search kept going past it, grow refuses on the malformed second one. */
static void test_grow_uses_first_unwind_info_not_last(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_UNWIND);

    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct segment_command_64 *tx =
        (struct segment_command_64 *)(buf + sizeof *h + sizeof(struct segment_command_64));
    uint8_t *lcend = (uint8_t *)tx + tx->cmdsize;

    struct segment_command_64 *da = (struct segment_command_64 *)lcend;
    da->cmd = LC_SEGMENT_64;
    da->cmdsize = sizeof *da + sizeof(struct section_64);
    strcpy(da->segname, "__DATA");
    da->vmaddr = 0x100004000ull;
    da->vmsize = 0x1000;
    da->fileoff = 6400;
    da->filesize = 13;
    da->nsects = 1;
    struct section_64 *bad_uw = (struct section_64 *)((uint8_t *)da + sizeof *da);
    strncpy(bad_uw->sectname, "__unwind_info", sizeof bad_uw->sectname);
    strncpy(bad_uw->segname, "__DATA", sizeof bad_uw->segname);
    bad_uw->addr = 0x100004000ull;
    bad_uw->size = 13;      /* < 28: mg_unwind_walk's own `usz < 28` refusal */
    bad_uw->offset = 6400;
    bad_uw->flags = S_REGULAR;
    h->ncmds++;
    h->sizeofcmds += da->cmdsize;

    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "grow succeeds using the FIRST __unwind_info (__TEXT's), not "
                  "the malformed second one in __DATA (got %d)", r);
    free(buf);
}

/* ---- mg_grow_header's own preconditions: __PAGEZERO and __TEXT ----
 * The image-base-lowering trick needs a __PAGEZERO to donate space from and
 * a segment that actually maps the header (fileoff 0, real content) to
 * lower. Every OTHER fixture in this file builds both, correctly sized --
 * so these three refusals had never been exercised by anything, hermetic or
 * real-binary, until a code review round found the gap by mutation. */
static uint8_t *build_minimal_pie(size_t *fsize_out, int with_pagezero,
                                  uint64_t pagezero_vmsize, uint64_t text_fileoff) {
    const size_t fsize = 8192;
    uint8_t *buf = (uint8_t *)calloc(1, fsize);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;

    uint8_t *lcp = buf + sizeof *h;
    uint32_t sizeofcmds = 0;

    if (with_pagezero) {
        struct segment_command_64 *pz = (struct segment_command_64 *)lcp;
        pz->cmd = LC_SEGMENT_64;
        pz->cmdsize = sizeof *pz;
        strcpy(pz->segname, "__PAGEZERO");
        pz->vmaddr = 0;
        pz->vmsize = pagezero_vmsize;
        pz->fileoff = 0;
        pz->filesize = 0;   /* filesize 0 keeps it out of the __TEXT probe */
        lcp += pz->cmdsize; sizeofcmds += pz->cmdsize; h->ncmds++;
    }

    /* One section with file data, at 4096: mg_grow_header refuses an image
     * with none before it reaches the checks these fixtures exist for. */
    struct segment_command_64 *tx = (struct segment_command_64 *)lcp;
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof(struct section_64);
    strcpy(tx->segname, "__TEXT");
    tx->vmaddr = 0x100000000ull;
    tx->vmsize = fsize;
    tx->fileoff = text_fileoff;
    tx->filesize = (text_fileoff == 0) ? fsize : 0;
    tx->nsects = 1;
    struct section_64 *ts = (struct section_64 *)(tx + 1);
    memcpy(ts->sectname, "__text", 6);
    memcpy(ts->segname, "__TEXT", 6);
    ts->addr = tx->vmaddr + 4096;
    ts->size = 16;
    ts->offset = 4096;
    sizeofcmds += tx->cmdsize; h->ncmds++;

    h->sizeofcmds = sizeofcmds;
    *fsize_out = fsize;
    return buf;
}

static int stderr_contains_during(int (*call)(uint8_t **, size_t *, uint32_t),
                                   uint8_t **pbuf, size_t *pfsize, uint32_t grow,
                                   const char *needle, int *ret_out);

/* `needle`, when not NULL, is the reason the refusal must give. Without one
 * these tests went on passing when a refusal earlier in mg_grow_header began
 * catching their fixture first, and so stopped reaching the check each exists
 * for. */
static void check_grow_precondition_refused(const char *what, int with_pagezero,
                                             uint64_t pagezero_vmsize, uint64_t text_fileoff,
                                             const char *needle) {
    size_t fsize;
    uint8_t *buf = build_minimal_pie(&fsize, with_pagezero, pagezero_vmsize, text_fileoff);
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);

    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
                                      needle ? needle : "", &r);
    CHECK(r == -1, "%s: mg_grow_header refuses (got %d)", what, r);
    if (needle)
        CHECK(said, "%s: the refusal says '%s'", what, needle);
    CHECK(fsize == fsize0, "%s: size unchanged on refusal (got %zu want %zu)",
          what, fsize, fsize0);
    if (fsize == fsize0)
        CHECK(memcmp(before, buf, fsize0) == 0, "%s: buffer byte-identical on refusal", what);
    free(before);
    free(buf);
}

static void test_grow_refuses_missing_pagezero(void) {
    check_grow_precondition_refused("no __PAGEZERO at all", 0, 0, 0,
                                     "need a __PAGEZERO >= 4096 bytes");
}

static void test_grow_refuses_undersized_pagezero(void) {
    check_grow_precondition_refused("__PAGEZERO smaller than grow", 1, 0x800, 0,
                                     "need a __PAGEZERO >= 4096 bytes");
}

/* Unlike the two __PAGEZERO cases above, mutating away mg_grow_header's own
 * `!mi_text_base(&find_im)` check does NOT make this test go blind: mg_collect
 * (called from mg_snapshot_take, further down the same function) runs its OWN
 * independent header-mapping-segment search and refuses ("could not snapshot
 * the base-relative structures"), confirmed by mutation. So this refusal is
 * doubly guarded -- genuinely redundant, not a gap -- and
 * this test proves the observable BEHAVIOUR (refuses, unchanged) rather than
 * pinning which of the two guards fired, per this suite's own rule (see
 * tests/README.md: assert the behaviour, not which guard fired).
 *
 * The two searches are no longer the same CALL: mg_collect uses mi_image_base
 * (src/grow.c), mg_grow_header still uses mi_text_base. They agree on THIS
 * fixture, which maps no segment at file offset 0 -- the one input class where
 * mi_text_base's 0 really does mean "not found". They deliberately disagree on
 * an image whose base legitimately IS 0, which is the bug mi_image_base exists
 * to fix; mg_grow_header cannot see one, because it refuses any filetype other
 * than MH_EXECUTE well above this point. */
static void test_grow_refuses_no_text_segment(void) {
    check_grow_precondition_refused("no segment maps the header (fileoff 0)",
                                     1, 0x100000000ull, 0x1000, NULL);
}

/* ---- mg_verify: the grow must move nothing ----
 * The invariant is not "the entries changed by grow", it is "the RESOLVED
 * addresses did not change". Stating it that way is what makes the check catch
 * bugs it was not written for: a handler that never ran, one that ran twice
 * (PR #10 -- two correct __init_offsets re-basers met in a merge and composed
 * into 2*grow), or one that ran with the wrong delta all look the same to it.
 *
 * The two failing cases below are the point. A verify that cannot fail is not a
 * verify, so each one perturbs the grown image by exactly one handler's worth of
 * work and asserts mg_verify rejects it.
 */
static void test_verify_accepts_a_correct_grow(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_growable_image(&fsize, &sect_off);
    mg_snapshot snap;
    CHECK(mg_snapshot_take(buf, fsize, &snap) == 0, "snapshot taken before the grow");
    /* both __init_offsets entries, plus the section's first and last byte */
    CHECK(snap.n == 4, "snapshot found both __init_offsets entries and the section (got %u)",
          snap.n);

    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "grow succeeds (got %d)", r);
    if (r == 0)
        CHECK(mg_verify(buf, fsize, &snap) == 0, "verify ACCEPTS a correct grow");
    mg_snapshot_free(&snap);
    free(buf);
}

/* Perturb every __init_offsets entry by `delta` after a correct grow, then
 * demand mg_verify notices. delta=+grow is the double-apply; -grow is a handler
 * that never ran. */
static void check_verify_rejects(const char *what, int32_t delta) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_growable_image(&fsize, &sect_off);
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) { free(buf); CHECK(0, "%s: snapshot", what); return; }
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        mg_snapshot_free(&snap); free(buf); CHECK(0, "%s: grow", what); return;
    }
    uint32_t *e = find_init_offsets(buf, fsize);
    if (e) { e[0] = (uint32_t)(e[0] + delta); e[1] = (uint32_t)(e[1] + delta); }
    CHECK(mg_verify(buf, fsize, &snap) == -1, "verify REJECTS %s", what);
    mg_snapshot_free(&snap);
    free(buf);
}

static void test_verify_rejects_double_apply(void) {
    check_verify_rejects("a double-applied re-base (the PR #10 defect)", 0x1000);
}

static void test_verify_rejects_handler_that_never_ran(void) {
    check_verify_rejects("a handler that never ran", -0x1000);
}

/* Coverage, not just correctness: a handler is only as safe as verify's
 * willingness to contradict it. If mg_collect ever stops walking compact unwind,
 * the count assertion fails here rather than silently going unwatched. */
static void test_verify_watches_unwind_info(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_UNWIND);
    mg_snapshot snap;
    CHECK(mg_snapshot_take(buf, fsize, &snap) == 0, "snapshot with unwind taken");
    /* 2 __init_offsets + 1 personality + 2 first-level (incl. sentinel)
     * + 2 LSDA fields = 7, plus both sections' first and last bytes = 11.
     * The compressed entries are deltas and must NOT be counted -- if they
     * were, this would be 13. */
    CHECK(snap.n == 11, "verify watches all 7 base-relative unwind+init fields and both "
                        "sections (got %u)", snap.n);

    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "grow succeeded"); mg_snapshot_free(&snap); free(buf); return;
    }
    /* Perturb one unwind field the handler is responsible for. */
    uint8_t *u = find_unwind(buf, fsize);
    if (u) *(uint32_t *)(u + UW_IDX_OFF) += 4;
    CHECK(mg_verify(buf, fsize, &snap) == -1,
          "verify REJECTS a perturbed first-level functionOffset");
    mg_snapshot_free(&snap);
    free(buf);
}

/* The export trie stores each address as a ULEB offset from the image base. The
 * fix that makes this tractable: adding `grow` never widens the encoding on any
 * real binary (measured across all 670 entries of Claude Code 2.1.263 at 4K, 8K
 * and 16K), so the address is re-encoded at its ORIGINAL byte width and the trie
 * -- and every __LINKEDIT offset after it -- keeps its size.
 *
 * __mh_execute_header is exported at 0 and must stay 0: it names the header,
 * which moved down with the base, so 0 is still correct.
 *
 * No hand-rolled find-the-trie walk here: mg_find_trie (src/grow.h) already
 * IS exactly this search (LC_DYLD_INFO[_ONLY] or LC_DYLD_EXPORTS_TRIE,
 * whichever this image carries), exported for callers like mg_grow_header's
 * own widen-append path -- reusing it instead of a second copy is the whole
 * point of that export existing. */
static void test_grow_rebases_export_trie(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_TRIE);
    const uint32_t g = 0x1000;

    int r = mg_grow_header(&buf, &fsize, g);
    CHECK(r == 0, "grow succeeds on an image with an export trie (got %d)", r);
    if (r != 0) { free(buf); return; }

    uint32_t toff = 0, tsize = 0;
    int found = mg_find_trie(buf, fsize, &toff, &tsize);
    CHECK(found && tsize == 17, "trie size UNCHANGED (got %u) -- no __LINKEDIT resize", tsize);
    uint8_t *t = found ? buf + toff : NULL;
    CHECK(t != NULL, "export trie still locatable");
    if (!t) { free(buf); return; }
    /* node A's address, still a 2-byte ULEB at the same place */
    uint64_t a = 0; int n = mu_decode(t + 10, t + 17, &a);
    CHECK(n == 2, "node A address still encoded in 2 bytes (got %d)", n);
    CHECK(a == 0x1000 + g, "node A address gains grow: got %#llx want %#llx",
          (unsigned long long)a, (unsigned long long)(0x1000 + g));
    CHECK(t[15] == 0x00, "__mh_execute_header-style export STAYS 0 (got %#x)", t[15]);
    free(buf);
}

/* ---- A trie that genuinely WIDENS under grow ----
 * Node A's address is 16000 (0x3E80): a 2-byte ULEB (16000 < 16384), but
 * 16000 + 0x1000 = 20096 needs 3 (>= 16384). An in-place patch (the path
 * above) cannot absorb that -- see mg_trie_node's `return 1`. mg_grow_header
 * must REBUILD the trie via src/trie.c's mt_trie_rebuild and, when the
 * rebuild no longer fits the original space (it doesn't here: 18 bytes
 * where there were 17), grow __LINKEDIT to hold it.
 *
 * This fixture is deliberately NOT build_image()'s 8192-byte layout: that
 * fixture has trailing zero padding past its trie, which would make
 * __LINKEDIT's declared end fall short of the file's actual end -- exactly
 * the "unknown trailing data" shape mg_grow_header's append path refuses
 * rather than guess about. This one is sized so __LINKEDIT's export trie is
 * the LAST thing in the file, byte for byte, so the append path's own
 * precondition holds. */
#define WT_LC_END   ((uint32_t)(sizeof(struct mach_header_64) \
                     + sizeof(struct segment_command_64)                         /* __PAGEZERO */ \
                     + sizeof(struct segment_command_64) + sizeof(struct section_64) /* __TEXT */ \
                     + sizeof(struct segment_command_64)                         /* __LINKEDIT */ \
                     + sizeof(struct dyld_info_command)))
#define WT_SECT_OFF 4096u
#define WT_TEXT_FILESIZE 4352u          /* > WT_SECT_OFF+4, page-friendly */
#define WT_TRIE_OFF WT_TEXT_FILESIZE    /* __LINKEDIT starts right after __TEXT */
#define WT_TRIE_SIZE 17u
#define WT_FSIZE (WT_TRIE_OFF + WT_TRIE_SIZE)   /* trie is the LAST file byte */

static uint8_t *build_widening_trie_image(size_t *fsize_out) {
    uint8_t *buf = (uint8_t *)calloc(1, WT_FSIZE);

    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    h->ncmds = 4;

    struct segment_command_64 *pz = (struct segment_command_64 *)(buf + sizeof *h);
    pz->cmd = LC_SEGMENT_64;
    pz->cmdsize = sizeof *pz;
    strcpy(pz->segname, "__PAGEZERO");
    pz->vmaddr = 0; pz->vmsize = 0x100000000ull;
    pz->fileoff = 0; pz->filesize = 0;

    struct segment_command_64 *tx = (struct segment_command_64 *)((uint8_t *)pz + pz->cmdsize);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof(struct section_64);
    strcpy(tx->segname, "__TEXT");
    tx->vmaddr = 0x100000000ull;
    tx->vmsize = WT_TEXT_FILESIZE;
    tx->fileoff = 0;
    tx->filesize = WT_TEXT_FILESIZE;
    tx->nsects = 1;
    struct section_64 *sc = (struct section_64 *)((uint8_t *)tx + sizeof *tx);
    strncpy(sc->sectname, "__data", sizeof sc->sectname);
    strncpy(sc->segname, "__TEXT", sizeof sc->segname);
    sc->addr = 0x100000000ull + WT_SECT_OFF;
    sc->size = 4;
    sc->offset = WT_SECT_OFF;
    sc->flags = S_REGULAR;

    struct segment_command_64 *le =
        (struct segment_command_64 *)((uint8_t *)tx + tx->cmdsize);
    le->cmd = LC_SEGMENT_64;
    le->cmdsize = sizeof *le;
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = tx->vmaddr + tx->vmsize;
    le->vmsize = 0x1000;
    le->fileoff = WT_TRIE_OFF;
    le->filesize = WT_TRIE_SIZE;   /* == exactly the (original) trie: it is
                                     * the only thing in __LINKEDIT here */

    struct dyld_info_command *di =
        (struct dyld_info_command *)((uint8_t *)le + le->cmdsize);
    di->cmd = LC_DYLD_INFO_ONLY;
    di->cmdsize = sizeof *di;
    di->export_off = WT_TRIE_OFF;
    di->export_size = WT_TRIE_SIZE;

    h->sizeofcmds = (uint32_t)(pz->cmdsize + tx->cmdsize + le->cmdsize + di->cmdsize);
    CHECK(sizeof(*h) + h->sizeofcmds == WT_LC_END,
          "fixture invariant: load commands end where WT_LC_END says (got %zu want %u)",
          sizeof(*h) + h->sizeofcmds, WT_LC_END);
    CHECK(WT_LC_END <= WT_SECT_OFF, "fixture invariant: load commands fit before the section");

    /* Same 17-byte hand-built trie as test_grow_rebases_export_trie's
     * MG_T_TRIE fixture, except node A's address is 16000 (0x3E80, ULEB
     * 80 7D) instead of 0x1000 -- see the block comment above this
     * function for why that one value forces the widen. */
    static const uint8_t trie[WT_TRIE_SIZE] = {
        0x00, 0x02,
        'A', 0x00, 8,
        'B', 0x00, 13,
        0x03, 0x00, 0x80, 0x7D, 0x00,     /* A: termsz3 flags0 addr16000(2B) nch0 */
        0x02, 0x00, 0x00, 0x00            /* B: termsz2 flags0 addr0       nch0 */
    };
    memcpy(buf + WT_TRIE_OFF, trie, sizeof trie);

    *fsize_out = WT_FSIZE;
    return buf;
}

static void test_grow_rebuilds_widening_export_trie(void) {
    size_t fsize;
    uint8_t *buf = build_widening_trie_image(&fsize);
    const uint32_t g = 0x1000;
    CHECK(fsize == WT_FSIZE, "fixture is exactly WT_FSIZE bytes (got %zu)", fsize);

    int r = mg_grow_header(&buf, &fsize, g);
    CHECK(r == 0, "grow succeeds on a WIDENING export trie -- no longer refuses (got %d)", r);
    if (r != 0) { free(buf); return; }

    /* Hand-computed rebuilt trie (see the task report / commit message for
     * the by-hand ULEB derivation): 18 bytes, one more than the original 17
     *   root (8B):   00 02 'A' 00 08 'B' 00 0E
     *   node A (6B): 04 00 80 9D 01 00     (addr 20096 = 0x4E80, ULEB 80 9D 01)
     *   node B (4B): 02 00 00 00
     */
    static const uint8_t expect[18] = {
        0x00, 0x02, 'A', 0x00, 0x08, 'B', 0x00, 0x0E,
        0x04, 0x00, 0x80, 0x9D, 0x01, 0x00,
        0x02, 0x00, 0x00, 0x00,
    };

    /* __LINKEDIT via mi_find_segment, the export trie's (off, size) via
     * mg_find_trie -- the same two finders every other converted walk in
     * this toolkit uses, instead of a third hand-rolled copy of this search. */
    uint32_t new_export_off = 0, new_export_size = 0;
    mg_find_trie(buf, fsize, &new_export_off, &new_export_size);
    struct segment_command_64 *le2 = NULL;
    {
        mi_image le_im;
        if (mi_wrap(buf, fsize, &le_im) == 0)
            le2 = mi_find_segment(&le_im, "__LINKEDIT");
    }

    CHECK(new_export_size == sizeof expect,
          "export_size grew to 18 (got %u) -- __LINKEDIT genuinely resized", new_export_size);
    CHECK(fsize == WT_FSIZE + g + sizeof expect,
          "file grew by header-pad(%u) + the trie's 1-byte growth: got %zu want %u",
          g, fsize, (unsigned)(WT_FSIZE + g + sizeof expect));
    CHECK(le2 != NULL, "__LINKEDIT segment still present");
    if (le2) {
        CHECK(le2->fileoff + le2->filesize == fsize,
              "__LINKEDIT still ends exactly at the (new) end of the file "
              "(fileoff=%llu filesize=%llu file=%zu)",
              (unsigned long long)le2->fileoff, (unsigned long long)le2->filesize, fsize);
        CHECK(new_export_off == le2->fileoff + le2->filesize - new_export_size,
              "export_off points at the rebuilt trie's actual location");
    }
    if (new_export_off && new_export_size == sizeof expect &&
        (uint64_t)new_export_off + new_export_size <= fsize) {
        CHECK(memcmp(buf + new_export_off, expect, sizeof expect) == 0,
              "rebuilt trie bytes match the hand-computed result exactly");
        uint64_t a = 0;
        int n = mu_decode(buf + new_export_off + 10, buf + new_export_off + new_export_size, &a);
        CHECK(n == 3 && a == 16000 + g, "node A address is 16000+grow=20096 in 3 bytes "
              "(got n=%d v=%#llx)", n, (unsigned long long)a);
    }
    free(buf);
}

/* ---- unknown means unsafe ----
 * The handlers above cover what we know. This is about what we do not: a load
 * command or section type nobody classified might carry offsets from the image
 * base exactly as __init_offsets and compact unwind do, and there is no way to
 * tell by looking at a number. Growing anyway is how LC_DATA_IN_CODE and
 * __unwind_info were silently corrupted for months. So the default is refusal,
 * and adding support for something means adding it to the table on purpose.
 */
static void test_grow_refuses_unknown_load_command(void) {
    check_refused_unchanged("an unclassified load command", MG_T_UNKNOWN_LC);
}

/* Known to carry base-relative ULEB payloads, and we do not re-base them.
 * Refusing is the honest answer, not silence. */
static void test_grow_refuses_linker_optimization_hint(void) {
    check_refused_unchanged("LC_LINKER_OPTIMIZATION_HINT", MG_T_LOH);
}

static void test_grow_refuses_unknown_section_type(void) {
    check_refused_unchanged("an unclassified section type", MG_T_ODDSECT);
}

/* THE COUPLING GAP a whole-branch review's mutation testing found: mg_classify
 * (src/grow.c) and ml_bump_lc (src/linkedit.c) are two switch statements
 * deciding one question -- "does growing the header need to touch this load
 * command's file offset, and does something actually touch it" -- and nothing
 * couples them. The tables agree today, but before these two tests existed,
 * moving LC_NOTE from mg_classify's refusal bucket into its inert (accepted)
 * bucket -- without teaching ml_bump_lc to bump note_command's `offset` field
 * to match -- left all 10 suites green: mg_classify would accept the grow,
 * ml_bump_lc's default case would silently leave the note's file offset
 * unbumped, and the tool would report success on a binary whose LC_NOTE now
 * points `grow` bytes into the wrong data.
 *
 * These two tests close the coverage gap directly: mg_grow_header MUST refuse
 * an image carrying LC_NOTE or LC_ATOM_INFO. Mutate mg_classify_cb to accept
 * either (move its case out of the refusal switch arm) and check_refused_unchanged's
 * `CHECK(r == -1, ...)` fails immediately -- because ml_bump_lc has no matching
 * case for either cmd, mg_grow_header would otherwise "succeed" while leaving
 * that load command's file offset silently wrong by `grow` bytes. */
static void test_grow_refuses_note(void) {
    check_refused_unchanged("LC_NOTE", MG_T_NOTE);
}

static void test_grow_refuses_atom_info(void) {
    check_refused_unchanged("LC_ATOM_INFO", MG_T_ATOM_INFO);
}

/* ---- 32-bit stays refused, on purpose ----
 * mg_grow_header's image-base trick and every helper it calls (mg_first_sect_off,
 * mg_collect/mg_verify, mg_classify, mg_unwind_walk, mg_init_offsets_pass, and
 * the segment-patching loop inside mg_grow_header itself) walk LC_SEGMENT_64 and
 * struct section_64 -- roughly seven places that would each need a parallel
 * LC_SEGMENT/struct section path, in a file whose correctness already rests on
 * ULEB-precise, snapshot-verified arithmetic (see mg_verify/mg_plausible above).
 * That is a lot of new surface, in the riskiest possible place, for a format
 * this toolkit's own image.h already drew the same line against ("32-bit and
 * fat are known gaps") -- and every one of the seven rewriters
 * in this repo (fix_macho, patch_macho, ...) already refuses non-64-bit input
 * the same way, at the very first header check. So this stays a refusal: the
 * check at the top of mg_grow_header already catches it (magic != MH_MAGIC_64)
 * before anything is touched, this test just makes that refusal a pinned,
 * regression-tested fact rather than an accidental side effect of the 64-bit-
 * only design. See docs/prior-art.md for the write-up.
 *
 * Reviewed and found tautological in its first form: it built a minimal
 * ncmds=0 image with a 32-bit magic and checked mg_grow_header returned -1.
 * Under a mutated magic check (`!= MH_MAGIC_64` -> `!= MH_MAGIC_64 && !=
 * MH_MAGIC`) it still passed -- ncmds=0 means mg_first_sect_off finds no
 * sections and refuses on its OWN account, so the test was really pinning
 * "an image with no sections gets refused somewhere", not "32-bit magic
 * gets refused at the magic check". First fix attempt: build the fixture from
 * build_growable_image()'s output -- a genuinely complete, otherwise-valid
 * image that mg_grow_header actually succeeds on -- and change ONLY its
 * magic. That still doesn't discriminate THIS check on its own: mg_first_sect_off
 * calls mi_wrap (src/image.c), which independently re-validates the magic, so
 * mutating ONLY mg_grow_header's own check leaves mi_wrap's guard catching the
 * same fixture a few lines later, still returning -1 -- true defense in depth,
 * but it means the return code alone can't tell which check fired. So this
 * asserts on the SPECIFIC diagnostic mg_grow_header's own check prints
 * ("deliberately unsupported format"), not just the return code: mutate away
 * mg_grow_header's check and mi_wrap's still refuses (r stays -1) but with ITS
 * message ("fails validation... refusing to guess the header pad boundary"),
 * which does not contain that phrase -- so the message assertion below is what
 * flips to FAIL. Confirmed by hand: mutating src/grow.c's check flips this
 * exact CHECK, though not `r == -1`. */
static int stderr_contains_during(int (*call)(uint8_t **, size_t *, uint32_t),
                                   uint8_t **pbuf, size_t *pfsize, uint32_t grow,
                                   const char *needle, int *ret_out) {
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir) tmpdir = "/tmp";
    char path[512];
    snprintf(path, sizeof path, "%s/macho_grow_test_stderr.%d", tmpdir, (int)getpid());

    fflush(stderr);
    int saved_fd = dup(fileno(stderr));
    if (!freopen(path, "w", stderr)) {
        /* Nothing captured means nothing can be said about what was printed:
         * fail, so that neither a test expecting a message nor one expecting
         * silence passes without having looked. */
        CHECK(0, "could not capture stderr to %s", path);
        *ret_out = call(pbuf, pfsize, grow);
        return 0;
    }

    *ret_out = call(pbuf, pfsize, grow);

    fflush(stderr);
    dup2(saved_fd, fileno(stderr));   /* restore the real stderr */
    close(saved_fd);
    clearerr(stderr);

    int found = 0;
    FILE *rf = fopen(path, "r");
    if (rf) {
        char line[1024];
        while (fgets(line, sizeof line, rf))
            if (needle[0] == '^' ? strncmp(line, needle + 1, strlen(needle + 1)) == 0
                                 : strstr(line, needle) != NULL) { found = 1; break; }
        fclose(rf);
    }
    unlink(path);
    return found;
}

static void test_grow_refuses_32bit_mach_header(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_growable_image(&fsize, &sect_off);
    struct mach_header *h = (struct mach_header *)buf;   /* same offset as ->magic in _64 */
    h->magic = MH_MAGIC;

    uint8_t *before = (uint8_t *)malloc(fsize);
    memcpy(before, buf, fsize);

    size_t got_fsize = fsize;
    int r;
    int mentioned = stderr_contains_during(mg_grow_header, &buf, &got_fsize, 0x1000,
                                            "deliberately unsupported format", &r);
    CHECK(r == -1, "mg_grow_header refuses a 32-bit Mach-O (got %d)", r);
    CHECK(mentioned, "refusal is mg_grow_header's OWN 32-bit check, not a downstream "
                     "guard incidentally catching the same fixture");
    CHECK(got_fsize == fsize, "size unchanged on refusal (got %zu want %zu)", got_fsize, fsize);
    if (got_fsize == fsize)
        CHECK(memcmp(before, buf, fsize) == 0, "buffer byte-identical on refusal");
    free(before);
    free(buf);
}

/* ---- mg_ensure_pad: the one place that decides whether there is room ---- */

static uint32_t g_ensure_need;
static int ensure_thunk(uint8_t **pbuf, size_t *pfsize, uint32_t unused) {
    (void)unused;
    return mg_ensure_pad(pbuf, pfsize, g_ensure_need, "t");
}

static void test_ensure_pad_fits_is_a_noop(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_growable_image(&fsize, &sect_off);
    uint8_t *orig = buf;
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);

    const struct mach_header_64 *h = (const struct mach_header_64 *)buf;
    uint32_t lc_end = (uint32_t)sizeof *h + h->sizeofcmds;
    int r = mg_ensure_pad(&buf, &fsize, lc_end, "t");
    CHECK(r == 0, "ensure_pad: the current load commands fit (got %d)", r);
    r = mg_ensure_pad(&buf, &fsize, sect_off, "t");
    CHECK(r == 0, "ensure_pad: reaching exactly the first section still fits (got %d)", r);
    CHECK(buf == orig && fsize == fsize0, "ensure_pad: a fit neither reallocates nor resizes");
    CHECK(memcmp(before, buf, fsize0) == 0, "ensure_pad: a fit leaves every byte alone");
    free(before);
    free(buf);
}

/* No caller opts in to a grow: a short pad on a growable image grows, and
 * says so on stderr -- by how much, the pad before and after, and the image
 * base before and after -- in one line. */
static void test_ensure_pad_grows_and_announces(void) {
    size_t fsize; uint32_t sect_off;
    /* MG_T_FUNCSTARTS so the plausibility check below has function starts
     * and initializers to check against each other after the base moved. */
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_FUNCSTARTS);
    size_t fsize0 = fsize;
    const struct mach_header_64 *h = (const struct mach_header_64 *)buf;
    uint32_t lc_end = (uint32_t)sizeof *h + h->sizeofcmds;
    char line[256];
    snprintf(line, sizeof line, "t: grew the header pad by %u bytes (%u -> %u available); "
             "image base 0x100000000 -> 0xfffff000\n",
             (unsigned)MG_PAGE, sect_off - lc_end, sect_off + (unsigned)MG_PAGE - lc_end);

    g_ensure_need = sect_off + 1;
    int r;
    int said = stderr_contains_during(ensure_thunk, &buf, &fsize, 0, line, &r);
    CHECK(r == 0, "ensure_pad: a short pad grows, with no permission asked (got %d)", r);
    CHECK(said, "ensure_pad: stderr announces the grow as '%.*s'", (int)strlen(line) - 1, line);
    CHECK(fsize >= fsize0 + MG_PAGE, "ensure_pad: the image grew by at least a page "
          "(got %zu, was %zu)", fsize, fsize0);
    CHECK(mg_first_sect_off(buf, fsize) == sect_off + MG_PAGE,
          "ensure_pad: the first section moved out by one page (got %u, was %u)",
          mg_first_sect_off(buf, fsize), sect_off);
    CHECK(mg_plausible(buf, fsize) == 0, "ensure_pad: the grown image is plausible");
    free(buf);
}

static void check_ensure_refuses_unchanged(const char *what, int opts,
                                           uint32_t filetype, uint32_t flags,
                                           const char *needle) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, opts);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->filetype = filetype;
    h->flags = flags;
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);

    g_ensure_need = sect_off + 1;
    int r;
    int said = stderr_contains_during(ensure_thunk, &buf, &fsize, 0, needle, &r);
    CHECK(r == -1, "ensure_pad on %s: refused (got %d)", what, r);
    CHECK(said, "ensure_pad on %s: the refusal says '%s'", what, needle);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "ensure_pad on %s: the image is byte-identical", what);
    free(before);
    free(buf);
}

/* A PIE executable of `fsize` bytes whose one LC_SEGMENT_64 has no sections:
 * nothing in it has section data, so nothing bounds the header pad. At 104
 * bytes -- a header and the segment command, nothing else -- it has the load
 * command and size of tests/leaf-tool-crashes.sh's nosect, as a PIE executable;
 * larger, the bytes past the load commands are 0xAB, so a write into them
 * shows. */
static uint8_t *build_sectionless_image(size_t fsize) {
    uint8_t *buf = (uint8_t *)calloc(1, fsize);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    h->ncmds = 1;
    h->sizeofcmds = sizeof(struct segment_command_64);
    struct segment_command_64 *seg = (struct segment_command_64 *)(h + 1);
    seg->cmd = LC_SEGMENT_64;
    seg->cmdsize = sizeof *seg;
    memcpy(seg->segname, "__DATA", 6);
    size_t lc_end = sizeof *h + h->sizeofcmds;
    if (fsize > lc_end) memset(buf + lc_end, 0xAB, fsize - lc_end);
    return buf;
}

static uint32_t g_first;
static int first_sect_thunk(uint8_t **pbuf, size_t *pfsize, uint32_t unused) {
    (void)unused;
    g_first = mg_first_sect_off(*pbuf, *pfsize);
    return 0;
}

/* With no section data there is no first-section offset to report, and
 * mg_first_sect_off says so -- MG_NO_SECTION_DATA, and nothing on stderr,
 * so each caller words its own refusal -- rather than naming an offset
 * nothing in the file supports. It used to answer 4096, which on an image
 * of 4096 bytes or more lies inside the buffer and passed for a real pad
 * boundary. */
static void test_first_sect_off_reports_no_section_data(void) {
    size_t sizes[] = { sizeof(struct mach_header_64) + sizeof(struct segment_command_64), 8192 };
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        size_t fsize = sizes[i];
        uint8_t *buf = build_sectionless_image(fsize);
        int r;
        /* The empty needle matches any line (strstr(line, "") is never NULL),
         * so `said` is "anything at all reached stderr". A capture that fails
         * fails the test inside stderr_contains_during, so silence here is
         * observed, not assumed. */
        int said = stderr_contains_during(first_sect_thunk, &buf, &fsize, 0, "", &r);
        CHECK(g_first == MG_NO_SECTION_DATA,
              "first_sect_off on a %zu-byte image with no section data: "
              "MG_NO_SECTION_DATA (got %u)", fsize, g_first);
        CHECK(!said, "first_sect_off on a %zu-byte image with no section data: "
              "prints nothing to stderr", fsize);
        free(buf);
    }
}

/* mg_ensure_pad on an image with no section data: refused, image untouched,
 * whether or not the new commands would have fitted below the 4096
 * mg_first_sect_off used to answer. The
 * 104-byte image is the one whose 4096 lay past the buffer (and so was
 * refused, before, for that); the 8192-byte one is the image whose 4096 lay
 * inside it, where "fits" was the answer and real data sat in the "pad". */
static void test_ensure_pad_refuses_an_image_with_no_section_data(void) {
    size_t sizes[] = { sizeof(struct mach_header_64) + sizeof(struct segment_command_64), 8192 };
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        size_t fsize = sizes[i];
        uint8_t *buf = build_sectionless_image(fsize);
        const struct mach_header_64 *h = (const struct mach_header_64 *)buf;
        uint8_t *orig = buf;
        size_t fsize0 = fsize;
        uint8_t *before = (uint8_t *)malloc(fsize0);
        memcpy(before, buf, fsize0);
        uint32_t lc_end = (uint32_t)(sizeof *h + h->sizeofcmds);

        g_ensure_need = lc_end + 16;
        int r;
        int said = stderr_contains_during(ensure_thunk, &buf, &fsize, 0,
                                          "no section data bounds the header pad; "
                                          "refusing rather than guess where it ends", &r);
        CHECK(r == -1, "ensure_pad on a %zu-byte image with no section data: "
              "refused (got %d)", fsize0, r);
        CHECK(said, "ensure_pad on a %zu-byte image with no section data: "
              "the refusal says no section data bounds the pad", fsize0);
        CHECK(buf == orig && fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
              "ensure_pad on a %zu-byte image with no section data: "
              "the image is byte-identical and not reallocated", fsize0);
        free(before);
        free(buf);
    }
}

/* A section whose file offset lies past the end of the image: that offset is
 * the pad boundary mg_first_sect_off reports, and past the buffer's end it
 * bounds nothing, so answering "fits" against it would let a caller write
 * past the buffer. Refused, image untouched. */
static void test_ensure_pad_refuses_a_section_past_the_image(void) {
    size_t fsize = sizeof(struct mach_header_64) + sizeof(struct segment_command_64)
                 + sizeof(struct section_64);
    uint8_t *buf = (uint8_t *)calloc(1, fsize);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    h->ncmds = 1;
    h->sizeofcmds = (uint32_t)(sizeof(struct segment_command_64) + sizeof(struct section_64));
    struct segment_command_64 *seg = (struct segment_command_64 *)(h + 1);
    seg->cmd = LC_SEGMENT_64;
    seg->cmdsize = h->sizeofcmds;
    seg->nsects = 1;
    memcpy(seg->segname, "__DATA", 6);
    struct section_64 *sect = (struct section_64 *)(seg + 1);
    memcpy(sect->sectname, "__data", 6);
    memcpy(sect->segname, "__DATA", 6);
    sect->offset = 0x7000;
    sect->size = 0x10;
    CHECK(mg_first_sect_off(buf, fsize) == 0x7000,
          "ensure_pad past-the-image fixture: the first section is at 0x7000 (got %u)",
          mg_first_sect_off(buf, fsize));

    uint8_t *orig = buf;
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    uint32_t lc_end = (uint32_t)(sizeof *h + h->sizeofcmds);

    g_ensure_need = lc_end + 16;
    int r;
    int said = stderr_contains_during(ensure_thunk, &buf, &fsize, 0,
                                      "lies past the end of the image", &r);
    CHECK(r == -1, "ensure_pad on a section past the image: refused, "
          "though 0x7000 would 'fit' (got %d)", r);
    CHECK(said, "ensure_pad on a section past the image: the refusal "
          "says the first section lies past the end of the image");
    CHECK(buf == orig && fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "ensure_pad on a section past the image: the image is "
          "byte-identical and not reallocated");
    free(before);
    free(buf);
}

/* mg_grow_header inserts its new page at the first section's file offset;
 * with no section data there is no such offset, and it refuses before it
 * moves anything, rather than inserting at an offset it made up. */
static void test_grow_refuses_an_image_with_no_section_data(void) {
    size_t fsize = 8192;
    uint8_t *buf = build_sectionless_image(fsize);
    uint8_t *before = (uint8_t *)malloc(fsize);
    memcpy(before, buf, fsize);
    size_t got_fsize = fsize;
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &got_fsize, 0x1000,
                                      "no section data bounds the header pad", &r);
    CHECK(r == -1, "grow refuses an image with no section data (got %d)", r);
    CHECK(said, "grow's refusal says no section data bounds the header pad");
    CHECK(got_fsize == fsize, "size unchanged on refusal (got %zu want %zu)", got_fsize, fsize);
    if (got_fsize == fsize)
        CHECK(memcmp(before, buf, fsize) == 0, "buffer byte-identical on refusal");
    free(before);
    free(buf);
}

/* mg_grow_header moves everything from the first section's file offset to
 * the end of the image up by a page; with that offset past the end, the
 * length of the move (fsize - insert) wraps around, and the grow died of
 * SIGSEGV. build_minimal_pie's image is otherwise one it grows, so only the
 * section's offset is moved past the end. Refused, image untouched. */
static void test_grow_refuses_a_section_past_the_image(void) {
    size_t fsize;
    uint8_t *buf = build_minimal_pie(&fsize, 1, 0x100000000ull, 0);
    struct section_64 *ts = (struct section_64 *)(buf + sizeof(struct mach_header_64)
                                                  + 2 * sizeof(struct segment_command_64));
    ts->offset = (uint32_t)fsize + 0x1000;
    CHECK(mg_first_sect_off(buf, fsize) == (uint32_t)fsize + 0x1000,
          "grow past-the-image fixture: the first section lies past the end (got %u)",
          mg_first_sect_off(buf, fsize));
    uint8_t *before = (uint8_t *)malloc(fsize);
    memcpy(before, buf, fsize);
    size_t got_fsize = fsize;
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &got_fsize, 0x1000,
                                      "lies past the end of the image", &r);
    CHECK(r == -1, "grow refuses a first section past the end of the image (got %d)", r);
    CHECK(said, "grow's refusal says the first section lies past the end of the image");
    CHECK(got_fsize == fsize, "size unchanged on refusal (got %zu want %zu)", got_fsize, fsize);
    if (got_fsize == fsize)
        CHECK(memcmp(before, buf, fsize) == 0, "buffer byte-identical on refusal");
    free(before);
    free(buf);
}

/* The grow moves by 4 KB pages, and arm64 maps 16 KB: an arm64 image is
 * refused, byte-identical. The same image labelled x86_64 grows, so the
 * refusal is the cputype's and nothing else's. */
static void test_ensure_pad_refuses_arm64(void) {
    uint32_t types[2] = { (uint32_t)CPU_TYPE_ARM64, (uint32_t)CPU_TYPE_X86_64 };
    for (int i = 0; i < 2; i++) {
        size_t fsize; uint32_t sect_off;
        uint8_t *buf = build_image(&fsize, &sect_off, 0);
        ((struct mach_header_64 *)buf)->cputype = (cpu_type_t)types[i];
        size_t fsize0 = fsize;
        uint8_t *before = (uint8_t *)malloc(fsize0);
        memcpy(before, buf, fsize0);
        g_ensure_need = sect_off + 1;
        int r;
        int said = stderr_contains_during(ensure_thunk, &buf, &fsize, 0,
                                          "arm64 image maps 16 KB pages", &r);
        if (i == 0) {
            CHECK(r == -1, "ensure_pad on arm64: refused (got %d)", r);
            CHECK(said, "ensure_pad on arm64: the refusal names the page size");
            CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
                  "ensure_pad on arm64: the image is byte-identical");
        } else {
            CHECK(r == 0 && !said, "ensure_pad on the same image as x86_64: grows (got %d)", r);
        }
        free(before);
        free(buf);
    }
}

static void test_ensure_pad_refuses_what_cannot_grow(void) {
    check_ensure_refuses_unchanged("an object file", 0, MH_OBJECT, 0,
                                   "only MH_EXECUTE, MH_DYLIB and MH_BUNDLE can be grown");
    check_ensure_refuses_unchanged("a dylib that is not x86_64", 0, MH_DYLIB, 0,
                                   "only an x86_64 dylib or bundle can be grown");
    check_ensure_refuses_unchanged("a non-PIE executable", 0, MH_EXECUTE, 0,
                                   "not PIE");
    check_ensure_refuses_unchanged("an image with chained fixups", MG_T_CHAINED,
                                   MH_EXECUTE, MH_PIE, "fixups set classic");
    check_ensure_refuses_unchanged("an unclassified load command", MG_T_UNKNOWN_LC,
                                   MH_EXECUTE, MH_PIE, "Unknown means unsafe");
    check_ensure_refuses_unchanged("an unclassified section type", MG_T_ODDSECT,
                                   MH_EXECUTE, MH_PIE, "is not classified");
}

/* ---- plausibility: verification without a "before" ----
 * The invariant check is strictly stronger, but it needs a snapshot taken before
 * the transform -- which the wrapper cannot have, because it verifies the end
 * state of a pipeline whose earlier stages ran in other processes.
 *
 * This is the check that works from the finished file alone: initializers and
 * compact-unwind entries name FUNCTIONS, so their targets must land exactly on
 * an address LC_FUNCTION_STARTS lists. Measured on Claude Code 2.1.263 that
 * holds perfectly -- 13/13 first-level, 198/198 LSDA, 9/9 initializers, against
 * 71,974 known starts -- while a mere range check would be near-useless there,
 * since __text is 63 MB and a one-page error stays inside it.
 */
static void test_plausible_accepts_a_well_formed_image(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_FUNCSTARTS);
    CHECK(mg_plausible(buf, fsize) == 0,
          "plausible ACCEPTS initializers that land on function starts");
    free(buf);
}

static void test_plausible_rejects_an_offset_that_names_no_function(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_FUNCSTARTS);
    uint32_t *e = (uint32_t *)(buf + sect_off);
    e[0] += 0x10;              /* still inside __text, but not a function start */
    CHECK(mg_plausible(buf, fsize) == -1,
          "plausible REJECTS an initializer pointing into the middle of a function");
    free(buf);
}

/* The failure this is really for: a structure left un-re-based by a grow. */
static void test_plausible_rejects_an_unrebased_initializer(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_FUNCSTARTS);
    uint32_t *e = (uint32_t *)(buf + sect_off);
    e[0] -= 0x1000;            /* exactly what forgetting to re-base looks like */
    CHECK(mg_plausible(buf, fsize) == -1,
          "plausible REJECTS an initializer left a page low");
    free(buf);
}

/* ---- overflow refusal at src/grow.c's other two ml_bump call sites ----
 * (a code review round found ml_bump/ml_bump_all's overflow guard, but noted
 * the SAME class of bug still lived at the two ml_bump call sites left
 * inside mg_grow_header itself: a section's offset/reloff, and LC_MAIN's
 * entryoff. Fixing those before this code was relocated meant the move
 * carried already-correct code, not a known bug -- the mistake this project
 * already made once with change_dylib/mi_open.) */

/* Every caller below builds its fixture via build_image, which always puts
 * the section it names into "__TEXT" -- so mi_find_section (segment name
 * required) is a direct fit, not a lateral move. find_lc (used two functions
 * down) is the shared one defined near the top of this file. */
static struct section_64 *find_section_struct(uint8_t *buf, size_t fsize, const char *name) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) != 0) return NULL;
    return mi_find_section(&im, "__TEXT", name);
}

/* __plain (MG_T_PLAINSECT) rather than __unwind_info: __unwind_info's offset
 * is bounds-checked by mg_unwind_walk's own pre-mutation audit (`offset +
 * size > fsize` -> refuse) before the offset bump with the NEW guard ever
 * runs, so poking IT would exercise the pre-existing bounds check, not the
 * guard this test exists to pin. __plain is S_REGULAR with an unremarkable
 * name: nothing walks its content, so mg_each_fileoff's section-offset bump
 * is the only code that bounds its offset field. */
/* Unlike check_refused_unchanged's cases (mg_classify refuses before ANY
 * byte moves, so "byte-identical" is trivially true there), these three
 * guards fire mid-transformation -- after the memmove/realloc that inserts
 * the header pad. Fields on commands walked before the one that overflows
 * are already bumped in place and are NOT rolled back; that is the
 * documented contract every internal failure path in mg_grow_header shares
 * (see src/linkedit.h's ml_bump_all doc comment). What must hold is that the
 * OUTER caller never writes a refused buffer to disk. That used to be
 * verifiable through `drydock-macho-rewrite grow FILE OUT N` -- confirmed by hand on
 * poked copies of tests/fixture.macho for all three guards (section offset,
 * reloff, entryoff): an observation made at or before cbcacd3 (the old
 * numbering, under which EX_REFUSED was 2), which reported exit 2 and left
 * the file byte-for-byte unmodified on disk. That verb is gone, and no script
 * can request a grow of a specific size, so no CLI reaches these three guards
 * at all now: the only caller of mg_grow_header left is mg_ensure_pad, which
 * grows on demand and hands its own refusal up. So these three checks pin
 * what this translation unit can honestly promise, and all that anything can:
 * the refusal itself (r == -1). */
static void test_grow_refuses_overflowing_section_offset(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    struct section_64 *plain = find_section_struct(buf, fsize, "__plain");
    CHECK(plain != NULL, "setup: __plain section present");
    if (!plain) { free(buf); return; }
    plain->offset = 0xfffff000u;   /* + grow (0x1000) would overflow uint32_t */

    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == -1, "grow refuses a section offset that would overflow (got %d)", r);
    free(buf);
}

static void test_grow_refuses_overflowing_reloff(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    struct section_64 *plain = find_section_struct(buf, fsize, "__plain");
    CHECK(plain != NULL, "setup: __plain section present");
    if (!plain) { free(buf); return; }
    plain->reloff = 0xfffff000u;   /* offset itself (4096, from build_image) stays
                                     * fine; only reloff is poked, isolating this
                                     * guard from the offset one above */

    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == -1, "grow refuses a section reloff that would overflow (got %d)", r);
    free(buf);
}

static void test_grow_refuses_overflowing_entryoff(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_MAIN);
    struct load_command *lc = find_lc(buf, fsize, LC_MAIN);
    CHECK(lc != NULL, "setup: LC_MAIN present");
    if (!lc) { free(buf); return; }
    struct entry_point_command *ep = (struct entry_point_command *)lc;
    ep->entryoff = 0xfffffffffffff000ULL;   /* + grow (0x1000) would overflow uint64_t */

    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == -1, "grow refuses an entryoff that would overflow (got %d)", r);
    free(buf);
}

/* ---- mg_verify watches every field a grow adjusts ----
 * Each case undoes ONE adjustment of an otherwise correct grow -- what a patcher
 * that forgot it would leave -- and requires mg_verify to refuse. Dropping
 * LC_MAIN's entryoff bump once produced binaries that died of SIGBUS while
 * verify passed: it watched base-relative CONTENT, and entryoff, the segment
 * geometry and every load command's file offset are not content. */
typedef void (*mg_tweak)(uint8_t *buf, size_t fsize, uint32_t grow);

static struct segment_command_64 *seg_named(uint8_t *buf, size_t fsize, const char *name) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) != 0) return NULL;
    return mi_find_segment(&im, name);
}

static void check_verify_rejects_undone(const char *what, int opts, mg_tweak setup,
                                        mg_tweak undo) {
    const uint32_t grow = 0x1000;
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, opts);
    if (setup) setup(buf, fsize, grow);
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) {
        CHECK(0, "%s: snapshot", what); free(buf); return;
    }
    if (mg_grow_header(&buf, &fsize, grow) != 0) {
        CHECK(0, "%s: grow", what); mg_snapshot_free(&snap); free(buf); return;
    }
    CHECK(mg_verify(buf, fsize, &snap) == 0, "%s: verify accepts the grow as made", what);
    undo(buf, fsize, grow);
    CHECK(mg_verify(buf, fsize, &snap) == -1, "verify REJECTS %s", what);
    mg_snapshot_free(&snap);
    free(buf);
}

static void undo_entryoff(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct entry_point_command *ep = (struct entry_point_command *)find_lc(buf, fsize, LC_MAIN);
    if (ep) ep->entryoff -= grow;
}
static void undo_plain_offset(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct section_64 *s = find_section_struct(buf, fsize, "__plain");
    if (s) s->offset -= grow;
}
static void give_plain_relocs(uint8_t *buf, size_t fsize, uint32_t grow) {
    (void)grow;
    struct section_64 *s = find_section_struct(buf, fsize, "__plain");
    if (s) s->reloff = 6400;
}
static void undo_plain_reloff(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct section_64 *s = find_section_struct(buf, fsize, "__plain");
    if (s) s->reloff -= grow;
}
static void undo_symoff(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB);
    if (st) st->symoff -= grow;
}
static void undo_export_off(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct dyld_info_command *di =
        (struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY);
    if (di) di->export_off -= grow;
}
static void undo_linkedit_fileoff(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct segment_command_64 *s = seg_named(buf, fsize, "__LINKEDIT");
    if (s) s->fileoff -= grow;
}
static void undo_text_vmaddr(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct segment_command_64 *s = seg_named(buf, fsize, "__TEXT");
    if (s) s->vmaddr += grow;
}
static void undo_text_filesize(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct segment_command_64 *s = seg_named(buf, fsize, "__TEXT");
    if (s) s->filesize -= grow;
}
static void undo_text_vmsize(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct segment_command_64 *s = seg_named(buf, fsize, "__TEXT");
    if (s) s->vmsize -= grow;
}
static void undo_pagezero_vmsize(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct segment_command_64 *s = seg_named(buf, fsize, "__PAGEZERO");
    if (s) s->vmsize += grow;
}

static void test_verify_watches_every_adjusted_field(void) {
    check_verify_rejects_undone("an un-bumped LC_MAIN entryoff", MG_T_MAIN, NULL, undo_entryoff);
    check_verify_rejects_undone("an un-bumped section offset", MG_T_PLAINSECT, NULL,
                                undo_plain_offset);
    check_verify_rejects_undone("an un-bumped section reloff", MG_T_PLAINSECT,
                                give_plain_relocs, undo_plain_reloff);
    check_verify_rejects_undone("an un-bumped LC_SYMTAB symoff", MG_T_SYMTAB, NULL, undo_symoff);
    check_verify_rejects_undone("an un-bumped later segment's fileoff",
                                MG_T_LINKEDIT | MG_T_SYMTAB, NULL, undo_linkedit_fileoff);
    check_verify_rejects_undone("an un-grown __TEXT filesize", 0, NULL, undo_text_filesize);
    check_verify_rejects_undone("an un-grown __TEXT vmsize", 0, NULL, undo_text_vmsize);
    check_verify_rejects_undone("an un-shrunk __PAGEZERO, overlapping __TEXT", 0, NULL,
                                undo_pagezero_vmsize);
    /* Watched before this list existed, through the content they locate: */
    check_verify_rejects_undone("an un-lowered __TEXT vmaddr", 0, NULL, undo_text_vmaddr);
    check_verify_rejects_undone("an un-bumped export_off", MG_T_TRIE, NULL, undo_export_off);
}

static int plausible_thunk(uint8_t **pbuf, size_t *pfsize, uint32_t unused) {
    (void)unused;
    return mg_plausible(*pbuf, *pfsize);
}

/* grow.c is a library, so its diagnostics name no program: each begins
 * "ERROR: ", as src/rewrite.c's do. A needle starting '^' must start the
 * line. One message of each kind. */
static void test_grow_diagnostics_name_no_program(void) {
    check_ensure_refuses_unchanged("an object file, by its prefix", 0, MH_OBJECT, 0,
                                   "^ERROR: only MH_EXECUTE, MH_DYLIB and MH_BUNDLE can be grown "
                                   "(filetype=1)");
    check_ensure_refuses_unchanged("a dylib that is not x86_64, by its prefix", 0, MH_DYLIB, 0,
                                   "^ERROR: only an x86_64 dylib or bundle can be grown "
                                   "(cputype=0)");
    check_ensure_refuses_unchanged("a non-PIE executable, by its prefix", 0, MH_EXECUTE, 0,
                                   "^ERROR: executable is not PIE (flags=0x");
    check_ensure_refuses_unchanged("an unclassified load command, by its prefix",
                                   MG_T_UNKNOWN_LC, MH_EXECUTE, MH_PIE,
                                   "^ERROR: load command 0x");
    check_ensure_refuses_unchanged("chained fixups, by its prefix", MG_T_CHAINED,
                                   MH_EXECUTE, MH_PIE,
                                   "^ERROR: LC_DYLD_CHAINED_FIXUPS: chained pointers");
    check_grow_precondition_refused("no __PAGEZERO, by its prefix", 0, 0, 0,
                                    "^ERROR: need a __PAGEZERO >= 4096 bytes");

    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_growable_image(&fsize, &sect_off);
    ((struct mach_header *)buf)->magic = MH_MAGIC;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
                                      "^ERROR: not a 64-bit Mach-O (magic=0xfeedface)", &r);
    CHECK(said && r == -1, "a 32-bit header's refusal begins 'ERROR: ' (got %d)", r);
    free(buf);

    size_t jsize = 64;
    uint8_t *junk = (uint8_t *)calloc(1, jsize);
    said = stderr_contains_during(first_sect_thunk, &junk, &jsize, 0,
                                  "^ERROR: image fails validation (bad magic", &r);
    CHECK(said && g_first == UINT32_MAX,
          "mg_first_sect_off's validation failure begins 'ERROR: ' (got %u)", g_first);
    free(junk);

    buf = build_image(&fsize, &sect_off, MG_T_FUNCSTARTS);
    ((uint32_t *)(buf + sect_off))[0] += 0x10;
    said = stderr_contains_during(plausible_thunk, &buf, &fsize, 0,
                                  "^ERROR: implausible -- ", &r);
    CHECK(said && r == -1, "mg_plausible's refusal begins 'ERROR: ' (got %d)", r);
    free(buf);
}

/* ---- the header-reference scan (src/hdrref.h) ----
 * Code bytes are hand-assembled here; each planted operand's disp32 is
 * computed from where it sits, so the test states only the target. Filler is
 * 0x90, which no scan can mistake for a RIP-relative ModRM (0x90 & 0xC7 is
 * 0x80). */
#define HR_BASE 0x100000000ull
#define HR_CODE 0x100001000ull   /* the vm address each test's code loads at */
#define HR_FOFF 0x1000u          /* ... and its file offset */

struct hr_seen { mhr_cand c[8]; int n; int stop_after; };
static int hr_record(const mhr_cand *c, void *ctx) {
    struct hr_seen *s = (struct hr_seen *)ctx;
    if (s->n < 8) s->c[s->n] = *c;
    s->n++;
    return s->stop_after && s->n >= s->stop_after;
}

/* `modrm`, then a disp32 that makes the target `target` for an operand
 * followed by `immlen` bytes of immediate, at code[at]; code loads at `va`. */
static void hr_plant(uint8_t *code, uint64_t va, uint32_t at, uint8_t modrm, int immlen,
                     uint64_t target) {
    uint64_t next = va + at + 1 + 4 + (uint64_t)immlen;
    int32_t disp = (int32_t)(int64_t)(target - next);
    code[at] = modrm;
    memcpy(code + at + 1, &disp, sizeof disp);
}

static void test_scan_finds_every_immediate_length(void) {
    uint8_t code[64];
    static const uint8_t modrm[4] = { 0x05, 0x0d, 0x3d, 0x25 };  /* reg field 0, 1, 7, 4 */
    static const int immlen[4] = { 0, 1, 2, 4 };
    memset(code, 0x90, sizeof code);
    for (int k = 0; k < 4; k++) hr_plant(code, HR_CODE, 2 + 12 * k, modrm[k], immlen[k], HR_BASE);
    struct hr_seen s = { { { 0 } }, 0, 0 };
    uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, hr_record, &s);
    CHECK(n == 4 && s.n == 4, "scan: four planted forms, %llu reported (%d visited)",
          (unsigned long long)n, s.n);
    for (int k = 0; k < 4 && k < s.n; k++) {
        CHECK(s.c[k].addr == HR_CODE + 3 + 12 * k && s.c[k].off == HR_FOFF + 3 + 12 * k,
              "scan: immediate length %d: disp32 at %#llx (file %#llx), want %#llx (file %#llx)",
              immlen[k], (unsigned long long)s.c[k].addr, (unsigned long long)s.c[k].off,
              (unsigned long long)(HR_CODE + 3 + 12 * k), (unsigned long long)(HR_FOFF + 3 + 12 * k));
        CHECK(s.c[k].immlen == immlen[k], "scan: candidate %d has immediate length %d, want %d",
              k, s.c[k].immlen, immlen[k]);
    }
}

/* The target must be the base exactly: the review found that everything that
 * names the header names exactly the base, and nothing names a byte past it. */
static void test_scan_ignores_a_target_one_byte_past_the_base(void) {
    uint8_t code[16];
    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 2, 0x05, 0, HR_BASE + 1);
    uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, NULL, NULL);
    CHECK(n == 0, "scan: a target one byte past the base is a candidate (%llu)",
          (unsigned long long)n);
}

/* Only mod 00 with r/m 101 is RIP-relative. r/m 100 means a SIB byte follows,
 * and mod 01, 10 or 11 with r/m 101 means [rbp + disp] or a register. Each of
 * these is followed by four bytes that, read as a RIP-relative disp32, would
 * name the base. */
static void test_scan_ignores_forms_that_are_not_rip_relative(void) {
    static const uint8_t modrm[] = { 0x04, 0x0c, 0x45, 0x85, 0xc5 };
    for (size_t k = 0; k < sizeof modrm; k++) {
        uint8_t code[16];
        memset(code, 0x90, sizeof code);
        hr_plant(code, HR_CODE, 2, modrm[k], 0, HR_BASE);
        uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, NULL, NULL);
        CHECK(n == 0, "scan: ModRM %#04x is not RIP-relative, yet %llu reported", modrm[k],
              (unsigned long long)n);
    }
}

/* A disp32 must lie wholly inside the section; an immediate need not. The
 * byte past the section completes, if it is read, a disp32 naming the base. */
static void test_scan_stops_at_the_section_end(void) {
    uint8_t code[24];
    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 15, 0x05, 4, HR_BASE);   /* disp32 is bytes 16-19 of 20 */
    struct hr_seen s = { { { 0 } }, 0, 0 };
    uint64_t n = mhr_scan_code(code, 20, HR_CODE, HR_FOFF, HR_BASE, hr_record, &s);
    CHECK(n == 1 && s.n == 1 && s.c[0].addr == HR_CODE + 16,
          "scan: a disp32 ending exactly at the section's end: %llu reported",
          (unsigned long long)n);

    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 16, 0x05, 0, HR_BASE);   /* disp32 is bytes 17-20 of 20 */
    n = mhr_scan_code(code, 20, HR_CODE, HR_FOFF, HR_BASE, NULL, NULL);
    CHECK(n == 0, "scan: a disp32 that runs one byte past the section: %llu reported",
          (unsigned long long)n);
}

/* A byte inside another instruction can look like a ModRM. The scan reports
 * it: it may over-report, never under-report. Here 0x05 is the first byte of
 * `mov $imm32, %eax`'s immediate. */
static void test_scan_reports_a_lookalike_inside_another_instruction(void) {
    uint8_t code[16];
    memset(code, 0x90, sizeof code);
    code[2] = 0xb8;                                   /* mov $imm32, %eax */
    hr_plant(code, HR_CODE, 3, 0x05, 0, HR_BASE);
    uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, NULL, NULL);
    CHECK(n == 1, "scan: a lookalike inside an immediate: %llu reported, want 1",
          (unsigned long long)n);
}

static void test_scan_stops_when_asked(void) {
    uint8_t code[32];
    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 2, 0x05, 0, HR_BASE);
    hr_plant(code, HR_CODE, 12, 0x05, 0, HR_BASE);
    struct hr_seen s = { { { 0 } }, 0, 1 };
    uint64_t n = mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, hr_record, &s);
    CHECK(n == 1 && s.n == 1 && s.c[0].addr == HR_CODE + 3,
          "scan: a callback that stops at the first: %llu reported, %d visited",
          (unsigned long long)n, s.n);
}

/* A PIE image, `HR_IMG_SIZE` bytes, whose __TEXT holds three sections of
 * 0x90: __text (both instruction attributes, as ld64 writes it), __stubs
 * (S_ATTR_SOME_INSTRUCTIONS only) and __const (neither). */
#define HR_IMG_SIZE 0x2000u
static uint8_t *build_code_image(void) {
    static const struct { const char *name; uint32_t flags; uint32_t off; } s[3] = {
        { "__text",  S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, 0x1000 },
        { "__stubs", S_SYMBOL_STUBS | S_ATTR_SOME_INSTRUCTIONS,           0x1400 },
        { "__const", S_REGULAR,                                           0x1800 },
    };
    uint8_t *buf = (uint8_t *)calloc(1, HR_IMG_SIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    h->ncmds = 1;
    struct segment_command_64 *tx = (struct segment_command_64 *)(h + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + 3 * sizeof(struct section_64);
    memcpy(tx->segname, "__TEXT", 6);
    tx->vmaddr = HR_BASE;
    tx->vmsize = tx->filesize = HR_IMG_SIZE;
    tx->nsects = 3;
    h->sizeofcmds = tx->cmdsize;
    struct section_64 *sc = (struct section_64 *)(tx + 1);
    for (int k = 0; k < 3; k++) {
        strncpy(sc[k].sectname, s[k].name, sizeof sc[k].sectname);
        memcpy(sc[k].segname, "__TEXT", 6);
        sc[k].addr = HR_BASE + s[k].off;
        sc[k].size = 0x100;
        sc[k].offset = s[k].off;
        sc[k].flags = s[k].flags;
        memset(buf + s[k].off, 0x90, 0x100);
    }
    return buf;
}

static void test_scan_reads_every_instruction_section_and_no_other(void) {
    uint8_t *buf = build_code_image();
    hr_plant(buf + 0x1000, HR_BASE + 0x1000, 0x20, 0x05, 0, HR_BASE);
    hr_plant(buf + 0x1400, HR_BASE + 0x1400, 0x30, 0x05, 0, HR_BASE);
    hr_plant(buf + 0x1800, HR_BASE + 0x1800, 0x40, 0x05, 0, HR_BASE);   /* data: not scanned */
    struct hr_seen s = { { { 0 } }, 0, 0 };
    int64_t n = mhr_scan(buf, HR_IMG_SIZE, HR_BASE, hr_record, &s);
    CHECK(n == 2 && s.n == 2, "image scan: %lld candidates, want __text's and __stubs'", (long long)n);
    if (s.n == 2) {
        CHECK(s.c[0].addr == HR_BASE + 0x1021 && s.c[0].off == 0x1021,
              "image scan: __text's at %#llx (file %#llx)",
              (unsigned long long)s.c[0].addr, (unsigned long long)s.c[0].off);
        CHECK(s.c[1].addr == HR_BASE + 0x1431 && s.c[1].off == 0x1431,
              "image scan: __stubs' at %#llx (file %#llx)",
              (unsigned long long)s.c[1].addr, (unsigned long long)s.c[1].off);
    }
    struct hr_seen first = { { { 0 } }, 0, 1 };
    n = mhr_scan(buf, HR_IMG_SIZE, HR_BASE, hr_record, &first);
    CHECK(n == 1 && first.n == 1, "image scan: a callback that stops at __text's went on "
          "to %d", first.n);
    free(buf);
}

/* An instruction section whose bytes the file does not hold cannot be
 * scanned, so nothing can be said about it. */
static void test_scan_refuses_an_instruction_section_past_the_image(void) {
    uint8_t *buf = build_code_image();
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    sc[1].size = HR_IMG_SIZE;                         /* __stubs: 0x1400 + 0x2000 > 0x2000 */
    CHECK(mhr_scan(buf, HR_IMG_SIZE, HR_BASE, NULL, NULL) == -1,
          "image scan: an instruction section past the end of the image was scanned");
    sc[1].offset = 0;                                 /* no file data, whatever its size */
    sc[1].size = 2 * HR_IMG_SIZE;
    CHECK(mhr_scan(buf, HR_IMG_SIZE, HR_BASE, NULL, NULL) == 0,
          "image scan: an instruction section with no file data was not skipped");
    free(buf);
}

/* A bad instruction section must not stop the scan of the ones after it: only
 * __text (the first) is unreadable here, and __stubs (the second, past it)
 * still carries a header reference that must reach the callback even though
 * the overall verdict is -1. */
static void test_scan_continues_after_a_bad_instruction_section(void) {
    uint8_t *buf = build_code_image();
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    sc[0].size = HR_IMG_SIZE;   /* __text: 0x1000 + 0x2000 > 0x2000, runs past the image */
    hr_plant(buf + 0x1400, HR_BASE + 0x1400, 0x30, 0x05, 0, HR_BASE);   /* __stubs: a real reference */
    struct hr_seen s = { { { 0 } }, 0, 0 };
    int64_t n = mhr_scan(buf, HR_IMG_SIZE, HR_BASE, hr_record, &s);
    CHECK(n == -1, "image scan: a bad instruction section still fails overall (got %lld)",
          (long long)n);
    CHECK(s.n == 1 && s.c[0].addr == HR_BASE + 0x1431 && s.c[0].off == 0x1431,
          "image scan: the later, good instruction section is still scanned and its "
          "reference still reaches the callback (got n=%d)", s.n);
    free(buf);
}

/* ---- a grow repairs code that addresses its own header ----
 * Lowering the base moves the header down by the grow while the code stays
 * put, so `lea __mh_execute_header(%rip)` would then name a byte that far
 * past it. The grow confirms each such instruction and takes the grow off its
 * disp32. __plain becomes code at the vm address its file offset maps to,
 * filled with 0x90, with `lea base(%rip), %rax` (48 8d 05 disp32) at each of
 * `at`; with MG_T_FUNCSTARTS, __plain's start is a function start too. */
#define HR_PLAIN_VA 0x100001800ull
static void plant_header_refs(uint8_t *buf, size_t fsize, const uint32_t *at, int n) {
    static const uint8_t starts[7] = { 0x80, 0x20, 0x80, 0x10, 0x80, 0x10, 0x00 };
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    struct linkedit_data_command *fs =
        (struct linkedit_data_command *)find_lc(buf, fsize, LC_FUNCTION_STARTS);
    CHECK(pl != NULL, "setup: __plain present");
    if (!pl) return;
    pl->addr = HR_PLAIN_VA;
    pl->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    memset(buf + pl->offset, 0x90, pl->size);
    for (int k = 0; k < n; k++) {
        buf[pl->offset + at[k]] = 0x48;
        buf[pl->offset + at[k] + 1] = 0x8d;
        hr_plant(buf + pl->offset, HR_PLAIN_VA, at[k] + 2, 0x05, 0, HR_BASE);
    }
    if (fs) {                                  /* base + 0x1000, 0x1800 (__plain), 0x2000 */
        memcpy(buf + fs->dataoff, starts, sizeof starts);
        fs->datasize = sizeof starts;
    }
}

/* Everything `call` prints on stderr, as one string the caller frees. */
static char *stderr_during(int (*call)(uint8_t **, size_t *, uint32_t), uint8_t **pbuf,
                           size_t *pfsize, uint32_t grow, int *ret) {
    const char *tmpdir = getenv("TMPDIR");
    char path[512];
    char *text = (char *)calloc(1, 65536);
    if (!tmpdir) tmpdir = "/tmp";
    snprintf(path, sizeof path, "%s/macho_grow_test_stderr.%d", tmpdir, (int)getpid());
    fflush(stderr);
    int saved_fd = dup(fileno(stderr));
    if (!freopen(path, "w", stderr)) {
        CHECK(0, "could not capture stderr to %s", path);
        *ret = call(pbuf, pfsize, grow);
        return text;
    }
    *ret = call(pbuf, pfsize, grow);
    fflush(stderr);
    dup2(saved_fd, fileno(stderr));
    close(saved_fd);
    clearerr(stderr);
    FILE *rf = fopen(path, "r");
    if (rf) {
        size_t got = fread(text, 1, 65535, rf);
        text[got] = '\0';
        fclose(rf);
    }
    unlink(path);
    return text;
}

/* Everything mg_ensure_pad(..., need, "t") prints on stderr. */
static char *ensure_pad_stderr(uint8_t **pbuf, size_t *pfsize, uint32_t need, int *ret) {
    g_ensure_need = need;
    return stderr_during(ensure_thunk, pbuf, pfsize, 0, ret);
}

/* How many candidates in `buf` address `target`. */
static int64_t refs_to(const uint8_t *buf, size_t fsize, uint64_t target) {
    return mhr_scan(buf, fsize, target, NULL, NULL);
}

static void test_grow_repairs_header_references(void) {
    static const uint32_t two[] = { 0, 8 };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    struct hr_seen s = { { { 0 } }, 0, 0 };
    plant_header_refs(buf, fsize, two, 2);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "repair: a grow with two confirmed references succeeds (got %d)", r);
    if (r == 0) {
        int64_t n = mhr_scan(buf, fsize, HR_BASE - 0x1000, hr_record, &s);
        CHECK(n == 2 && s.c[0].addr == HR_PLAIN_VA + 3 && s.c[1].addr == HR_PLAIN_VA + 11 &&
              s.c[0].immlen == 0 && s.c[1].immlen == 0,
              "repair: both leas address the new base, with no immediate (%lld)", (long long)n);
        CHECK(refs_to(buf, fsize, HR_BASE) == 0, "repair: none addresses the old base");
    }
    free(buf);
}

/* A grow refuses, and changes nothing, when it cannot account for a
 * candidate; `needle` is the reason it must give. */
static void check_grow_refuses_header_refs(const char *what, uint8_t *buf, size_t fsize,
                                           const char *needle) {
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000, needle, &r);
    CHECK(r == -1, "%s: mg_grow_header refuses (got %d)", what, r);
    CHECK(said, "%s: the refusal says '%s'", what, needle);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0, "%s: nothing changed", what);
    free(before);
    free(buf);
}

/* movabs $imm64, %rax whose immediate starts with 0x05: a candidate the sweep
 * finds inside an instruction that is not RIP-relative. */
static void test_grow_refuses_a_header_reference_it_cannot_confirm(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, NULL, 0);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) {
        buf[pl->offset + 1] = 0xb8;
        hr_plant(buf + pl->offset, HR_PLAIN_VA, 2, 0x05, 0, HR_BASE);
    }
    check_grow_refuses_header_refs("a lookalike", buf, fsize,
        "ERROR: the bytes at 0x100001803 may be code that addresses the image's own header, "
        "and decoding their function does not confirm it; refusing to grow");
}

static void test_grow_refuses_a_header_reference_without_function_starts(void) {
    static const uint32_t one[] = { 0 };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    plant_header_refs(buf, fsize, one, 1);
    check_grow_refuses_header_refs("no function starts", buf, fsize,
        "ERROR: the bytes at 0x100001803 may be code that addresses the image's own header, "
        "and with no LC_FUNCTION_STARTS there is no function to decode them from");
}

static void test_grow_refuses_code_it_cannot_scan(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, NULL, 0);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) pl->size = fsize;                  /* 6144 + 8192 runs past the image */
    check_grow_refuses_header_refs("code past the image", buf, fsize,
        "ERROR: an instruction section lies past the end of the image, so it cannot be "
        "searched for code that addresses the image's own header; refusing to grow");
}

/* Verification's own check: undo a repair, or aim it one byte short, where
 * with an imm8 after it the operand would reach the header after all. */
static void give_header_refs(uint8_t *buf, size_t fsize, uint32_t grow) {
    static const uint32_t two[] = { 0, 8 };
    (void)grow;
    plant_header_refs(buf, fsize, two, 2);
}
static void undo_header_ref(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    int32_t disp;
    if (!pl) return;
    memcpy(&disp, buf + pl->offset + 11, sizeof disp);
    disp += (int32_t)grow;
    memcpy(buf + pl->offset + 11, &disp, sizeof disp);
}
static void misaim_header_ref(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    (void)grow;
    if (pl) buf[pl->offset + 3]--;             /* 0xf9: the low byte, far from a borrow */
}

static void test_verify_watches_header_references(void) {
    check_verify_rejects_undone("an unrepaired reference to the header",
                                MG_T_PLAINSECT | MG_T_FUNCSTARTS, give_header_refs, undo_header_ref);
    check_verify_rejects_undone("a repaired reference one byte short of the header",
                                MG_T_PLAINSECT | MG_T_FUNCSTARTS, give_header_refs, misaim_header_ref);
}

/* An image whose one reference to the header is a lea at `far`, where
 * __plain moves, with a fourth function start naming it. */
static uint8_t *build_far_ref(uint64_t far, size_t *fsize) {
    static const uint32_t one[] = { 0 };
    uint32_t sect_off;
    uint8_t *buf = build_image(fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, *fsize, one, 1);
    struct section_64 *pl = find_section_struct(buf, *fsize, "__plain");
    struct linkedit_data_command *fs =
        (struct linkedit_data_command *)find_lc(buf, *fsize, LC_FUNCTION_STARTS);
    if (!pl || !fs) { CHECK(0, "setup: __plain and function starts"); return buf; }
    pl->addr = far;
    hr_plant(buf + pl->offset, far, 2, 0x05, 0, HR_BASE);
    uint8_t *p = buf + fs->dataoff + 6;             /* past 0x1000, 0x1800, 0x2000 */
    uint64_t d = far - (HR_BASE + 0x2000);
    do { uint8_t b = d & 0x7f; d >>= 7; *p++ = (uint8_t)(b | (d ? 0x80 : 0)); } while (d);
    *p++ = 0;
    fs->datasize = (uint32_t)(p - (buf + fs->dataoff));
    return buf;
}

/* A grow of 0x1000 takes a disp32 of INT32_MIN + 0x1000 exactly to INT32_MIN,
 * and one a byte further past it. */
static void test_grow_refuses_a_reference_the_grow_would_put_out_of_reach(void) {
    size_t fsize;
    uint8_t *buf = build_far_ref(HR_BASE + 0x7fffeff9ull, &fsize);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "reach: a disp32 the grow takes exactly to INT32_MIN is repaired (got %d)", r);
    CHECK(r != 0 || refs_to(buf, fsize, HR_BASE - 0x1000) == 1, "reach: it addresses the new base");
    free(buf);
    buf = build_far_ref(HR_BASE + 0x7fffeffaull, &fsize);
    check_grow_refuses_header_refs("a reference a grow would put out of reach", buf, fsize,
        "ERROR: the code at 0x17fffeffd addresses the image's own header with a disp32 of "
        "-2147479553, and a grow of 4096 would take it past INT32_MIN; refusing to grow");
}

/* mg_verify's image must hold every section it names. Given one cut a byte
 * short of __plain's end, the header-reference scan cannot read __plain, and
 * verify says so rather than report code at 0. (No grow is needed: with no
 * function starts, nothing else it reads lies past the cut.) */
static const mg_snapshot *verify_snap;
static int verify_thunk(uint8_t **pbuf, size_t *pfsize, uint32_t unused) {
    (void)unused;
    return mg_verify(*pbuf, *pfsize, verify_snap);
}
static void test_verify_says_when_it_cannot_search_the_image(void) {
    static const uint32_t two[] = { 0, 8 };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    plant_header_refs(buf, fsize, two, 2);
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) { CHECK(0, "unsearchable: snapshot"); free(buf); return; }
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    size_t cut = pl ? pl->offset + pl->size - 1 : fsize;
    char want[256];
    snprintf(want, sizeof want, "ERROR: verify FAILED -- an instruction section lies past the end "
             "of the %zu-byte image, so it cannot be searched for code that addresses the header; "
             "refusing.", cut);
    int r;
    verify_snap = &snap;
    int said = stderr_contains_during(verify_thunk, &buf, &cut, 0, want, &r);
    CHECK(r == -1 && said, "unsearchable: verify refuses, saying '%s' (got %d)", want, r);
    mg_snapshot_free(&snap);
    free(buf);
}

static void test_ensure_pad_repairs_each_header_reference(void) {
    static const uint32_t two[] = { 0, 8 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    const struct mach_header_64 *h = (const struct mach_header_64 *)buf;
    uint32_t lc_end = (uint32_t)sizeof *h + h->sizeofcmds;
    char line[256];
    snprintf(line, sizeof line, "t: grew the header pad by 4096 bytes (%u -> %u available); "
             "image base 0x100000000 -> 0xfffff000; repaired 2 references to the header\n",
             sect_off - lc_end, sect_off + 4096 - lc_end);
    plant_header_refs(buf, fsize, two, 2);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == 0, "two header references: the grow repairs them (got %d)", r);
    CHECK(strcmp(err, line) == 0, "two header references: stderr is\n%s want\n%s", err, line);
    CHECK(r != 0 || refs_to(buf, fsize, HR_BASE - 0x1000) == 2,
          "two header references: both address the new base");
    free(err);
    free(buf);
}

static void test_ensure_pad_repairs_one_header_reference(void) {
    static const uint32_t one[] = { 0 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, one, 1);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == 0 && strstr(err, "0xfffff000; repaired 1 reference to the header\n") != NULL,
          "one header reference: the announcement says 1 reference (got %d):\n%s", r, err);
    free(err);
    free(buf);
}

/* The repair takes off the grow, not a page: every other case here moves the
 * base by exactly one page. need_end one byte into the second page forces a
 * two-page grow. */
static void test_ensure_pad_repairs_across_a_two_page_grow(void) {
    static const uint32_t one[] = { 0 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, one, 1);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 0x1001, &r);
    CHECK(r == 0, "two-page grow: the grow repairs its reference (got %d):\n%s", r, err);
    CHECK(strstr(err, "t: grew the header pad by 8192 bytes") != NULL &&
          strstr(err, "image base 0x100000000 -> 0xffffe000; repaired 1 reference to the "
                      "header\n") != NULL,
          "two-page grow: announced as 8192 bytes, with its repair:\n%s", err);
    CHECK(r != 0 || refs_to(buf, fsize, HR_BASE - 0x2000) == 1,
          "two-page grow: the lea addresses the base two pages down");
    free(err);
    free(buf);
}

/* The control: the same section as code, with no reference. */
static void test_ensure_pad_announces_no_repair_without_a_header_reference(void) {
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, NULL, 0);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == 0 && strstr(err, "image base 0x100000000 -> 0xfffff000\n") != NULL,
          "no header reference: the announcement ends at the base (got %d):\n%s", r, err);
    free(err);
    free(buf);
}

/* Code the file does not hold cannot be searched, so the grow refuses. */
static void test_ensure_pad_refuses_code_it_cannot_scan(void) {
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT | MG_T_FUNCSTARTS);
    plant_header_refs(buf, fsize, NULL, 0);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) pl->size = fsize;                  /* 6144 + 8192 runs past the image */
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off + 1, &r);
    CHECK(r == -1 && strstr(err, "ERROR: an instruction section lies past the end of the "
                                 "image, so it cannot be searched") != NULL,
          "code past the image: the grow refuses (got %d):\n%s", r, err);
    free(err);
    free(buf);
}

/* The scan runs only when the pad must grow: an edit that fits needs no
 * grow, nothing moves the header, and nothing is printed. */
static void test_ensure_pad_fits_despite_a_header_reference(void) {
    static const uint32_t one[] = { 0 };
    size_t fsize; uint32_t sect_off; int r;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_PLAINSECT);
    plant_header_refs(buf, fsize, one, 1);
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    char *err = ensure_pad_stderr(&buf, &fsize, sect_off, &r);
    CHECK(r == 0, "ensure_pad: a fit with a header reference succeeds (got %d)", r);
    CHECK(err[0] == '\0', "ensure_pad: a fit prints nothing, yet:\n%s", err);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "ensure_pad: a fit leaves an image with a header reference alone");
    free(err);
    free(before);
    free(buf);
}

/* ---- an absolute export is a value, not an offset ----
 * EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE (kind 2 under the 0x03 mask) stores the
 * symbol's value itself, so lowering the base leaves it alone; a thread-local
 * export (kind 1) is an offset from the base like a regular one. MG_T_TRIE's
 * node A keeps its flags at trie byte 9 and its address, 0x1000, at bytes
 * 10-11. */
#define MG_TRIE_A_FLAGS 9
#define MG_TRIE_A_ADDR  10
static int grow_with_node_a_flags(uint8_t flags, uint64_t *a_out) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_TRIE);
    uint32_t toff = 0, tsize = 0;
    buf[TRIE_OFF + MG_TRIE_A_FLAGS] = flags;
    *a_out = 0;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    if (r == 0 && mg_find_trie(buf, fsize, &toff, &tsize))
        mu_decode(buf + toff + MG_TRIE_A_ADDR, buf + toff + tsize, a_out);
    free(buf);
    return r;
}

static void test_grow_leaves_an_absolute_export_alone(void) {
    uint64_t a;
    int r = grow_with_node_a_flags(0x02, &a);
    CHECK(r == 0, "absolute export: the grow succeeds and verifies (got %d)", r);
    CHECK(a == 0x1000, "absolute export: its value stays 0x1000 (got %#llx)", (unsigned long long)a);
    r = grow_with_node_a_flags(0x01, &a);
    CHECK(r == 0 && a == 0x2000, "thread-local export: an offset, so it gains grow "
          "(got %d, %#llx)", r, (unsigned long long)a);
}

/* mg_collect records an absolute export as its value, so verify notices one
 * that moved. */
static void test_verify_watches_an_absolute_export(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_TRIE);
    uint32_t toff = 0, tsize = 0;
    mg_snapshot snap;
    buf[TRIE_OFF + MG_TRIE_A_FLAGS] = 0x02;
    CHECK(mg_snapshot_take(buf, fsize, &snap) == 0, "absolute export: snapshot taken");
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "absolute export: grow succeeded");
        mg_snapshot_free(&snap); free(buf); return;
    }
    if (mg_find_trie(buf, fsize, &toff, &tsize))
        mu_encode_fixed(buf + toff + MG_TRIE_A_ADDR, 0x2000, 2);
    CHECK(mg_verify(buf, fsize, &snap) == -1, "verify REJECTS an absolute export that moved");
    mg_snapshot_free(&snap);
    free(buf);
}

/* ---- an empty function-starts list ----
 * A leading ULEB of 0 is the terminator, so the list names no function; a
 * codeless umbrella framework's is eight zero bytes. There is no leading
 * delta to re-base, so the list is left alone, and it cannot widen. */
static void test_reencode_leaves_an_empty_list_alone(void) {
    static const uint8_t zero[8] = { 0 };
    uint8_t blob[8] = { 0 };
    int r = mg_reencode_funcstarts_base(blob, sizeof blob, 0x1000);
    CHECK(r == 1, "an empty list: nothing to re-encode, so done (got %d)", r);
    CHECK(memcmp(blob, zero, sizeof blob) == 0, "an empty list: its terminator stays a terminator");
}

static void test_grow_leaves_an_empty_function_starts_list_alone(void) {
    static const uint8_t zero[5] = { 0 };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_FUNCSTARTS);
    memset(buf + FS_OFF, 0, sizeof zero);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "an empty function-starts list: the grow succeeds (got %d)", r);
    if (r == 0) {
        const struct linkedit_data_command *fs =
            (const struct linkedit_data_command *)find_lc(buf, fsize, LC_FUNCTION_STARTS);
        CHECK(fs && fs->dataoff == FS_OFF + 0x1000 &&
              memcmp(buf + fs->dataoff, zero, sizeof zero) == 0,
              "an empty function-starts list: moved with the file, and still empty");
    }
    free(buf);
}

/* ---- confirming a candidate (mhr_confirm) ----
 * build_code_image's __text holds `code` from its first byte (vm HR_CODE,
 * file HR_FOFF), with LC_FUNCTION_STARTS and LC_DATA_IN_CODE payloads, when
 * given, at file offsets 0x1c00 and 0x1d00. A lea's disp32 is planted with
 * hr_plant, so each case states only where its operand sits. */
static const uint8_t HR_ONE_FUNCTION[] = { 0x80, 0x20, 0x00 };    /* base + 0x1000: __text */

static void hr_add_lc(uint8_t *buf, uint32_t cmd, uint32_t at, const void *data, uint32_t n) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct linkedit_data_command *l =
        (struct linkedit_data_command *)(buf + sizeof *h + h->sizeofcmds);
    l->cmd = cmd;
    l->cmdsize = sizeof *l;
    l->dataoff = at;
    l->datasize = n;
    memcpy(buf + at, data, n);
    h->ncmds++;
    h->sizeofcmds += l->cmdsize;
}

struct hr_code {
    uint8_t b[32];
    uint32_t n;              /* bytes of code, at __text's start */
    const uint8_t *fs;       /* LC_FUNCTION_STARTS payload, or NULL for none */
    uint32_t nfs;
    const uint8_t *dic;      /* LC_DATA_IN_CODE payload, or NULL for none */
    uint32_t ndic;
};

static uint8_t *hr_code_image(const struct hr_code *k) {
    uint8_t *buf = build_code_image();
    memcpy(buf + HR_FOFF, k->b, k->n);
    if (k->fs) hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, k->fs, k->nfs);
    if (k->dic) hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, k->dic, k->ndic);
    return buf;
}

static int hr_confirm(const struct hr_code *k, mhr_cand *bad) {
    uint8_t *buf = hr_code_image(k);
    int r = mhr_confirm(buf, HR_IMG_SIZE, bad);
    free(buf);
    return r;
}

/* push %rbp; lea base(%rip), %rax: the disp32 is at HR_CODE + 4. */
static struct hr_code hr_push_lea(void) {
    struct hr_code k = { { 0x55, 0x48, 0x8d }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(k.b, HR_CODE, 3, 0x05, 0, HR_BASE);
    return k;
}

static void test_confirm_a_lea_of_the_header(void) {
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: push; lea base(%%rip) is an instruction (got %d)", r);
}

/* cmpl $1, base(%rip): the operand is followed by an imm8. */
static void test_confirm_an_operand_with_an_immediate(void) {
    struct hr_code k = { { 0x55, 0x83 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 2, 0x3d, 1, HR_BASE);
    k.b[7] = 0x01;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: cmpl $1, base(%%rip) is an instruction (got %d)", r);
}

/* The scan counts `05 disp32` inside mov $imm32, %eax's immediate; the sweep
 * finds the mov, which is not RIP-relative. */
static void test_confirm_rejects_a_lookalike_inside_an_immediate(void) {
    struct hr_code k = { { 0x55, 0xb8 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 2, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED && bad.addr == HR_CODE + 3 && bad.off == HR_FOFF + 3,
          "confirm: a lookalike in an immediate is unconfirmed, at its disp32 (got %d, %#llx)",
          r, (unsigned long long)bad.addr);
}

/* mov abs32, %eax is 8b 04 25 disp32: its SIB byte, 0x25, looks like a
 * RIP-relative ModRM to the scan, and the disp32 is where the scan says. */
static void test_confirm_rejects_an_absolute_address_that_looks_rip_relative(void) {
    struct hr_code k = { { 0x55, 0x8b, 0x04 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 3, 0x25, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: a SIB byte is not a RIP-relative ModRM (got %d)", r);
}

/* movl $imm32, x(%rip) is c7 05 disp32 imm32. Its first disp32 ends in 0x05,
 * so the scan sees a second operand whose disp32 is the imm32: inside a
 * RIP-relative instruction, but not its displacement. */
static void test_confirm_rejects_a_lookalike_inside_a_rip_relative_instruction(void) {
    struct hr_code k = { { 0x55, 0xc7, 0x05, 0x10, 0x00, 0x00 }, 11, HR_ONE_FUNCTION,
                         sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 6, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED && bad.addr == HR_CODE + 7,
          "confirm: an immediate after a real disp32 is not the operand (got %d, %#llx)",
          r, (unsigned long long)bad.addr);
}

/* cmpl $1, x(%rip) whose disp32 would name the base with no immediate: with
 * its imm8, it names the byte after the base. */
static void test_confirm_rejects_an_operand_whose_immediate_moves_its_target(void) {
    struct hr_code k = { { 0x55, 0x83 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 2, 0x3d, 0, HR_BASE);
    k.b[7] = 0x01;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: an operand that names base + 1 is unconfirmed (got %d)", r);
}

/* Two leas and no LC_FUNCTION_STARTS: the first is the one reported. */
static void test_confirm_needs_function_starts(void) {
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = NULL;
    k.b[8] = 0x48; k.b[9] = 0x8d;
    hr_plant(k.b, HR_CODE, 10, 0x05, 0, HR_BASE);
    k.n = 15;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_NO_STARTS && bad.addr == HR_CODE + 4,
          "confirm: no LC_FUNCTION_STARTS, so nothing to decode from (got %d, %#llx)",
          r, (unsigned long long)bad.addr);
}

/* ---- what confirming costs ----
 * Each case below must confirm within HR_SLOW seconds. A sweep that
 * restarts at its function start for every candidate, or rescans
 * LC_DATA_IN_CODE from its first range, does not. */
#define HR_SLOW 10
static const char *hr_slow_what;
static void hr_too_slow(int sig) {
    (void)sig;
    if (write(STDOUT_FILENO, "FAIL: ", 6) < 0 || write(STDOUT_FILENO, hr_slow_what, strlen(hr_slow_what)) < 0 ||
        write(STDOUT_FILENO, " took more than 10 s\n", 21) < 0) {}
    _exit(1);
}

/* An image whose __text is `n` bytes of `code` at file and vm offset 0x1000,
 * with `fs` and `dic` payloads after it. */
static uint8_t *hr_big_image(const uint8_t *code, size_t n, const uint8_t *fs, size_t nfs,
                             const uint8_t *dic, size_t ndic, size_t *fsize) {
    size_t size = HR_FOFF + n + nfs + ndic;
    uint8_t *buf = (uint8_t *)calloc(1, size);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    h->ncmds = 1;
    struct segment_command_64 *tx = (struct segment_command_64 *)(h + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof(struct section_64);
    memcpy(tx->segname, "__TEXT", 6);
    tx->vmaddr = HR_BASE;
    tx->vmsize = tx->filesize = size;
    tx->nsects = 1;
    h->sizeofcmds = tx->cmdsize;
    struct section_64 *sc = (struct section_64 *)(tx + 1);
    strncpy(sc->sectname, "__text", sizeof sc->sectname);
    memcpy(sc->segname, "__TEXT", 6);
    sc->addr = HR_CODE;
    sc->size = n;
    sc->offset = HR_FOFF;
    sc->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    memcpy(buf + HR_FOFF, code, n);
    hr_add_lc(buf, LC_FUNCTION_STARTS, (uint32_t)(HR_FOFF + n), fs, (uint32_t)nfs);
    if (dic) hr_add_lc(buf, LC_DATA_IN_CODE, (uint32_t)(HR_FOFF + n + nfs), dic, (uint32_t)ndic);
    *fsize = size;
    return buf;
}

/* `lea base(%rip), %rax` at code[at]. */
static void hr_put_lea(uint8_t *code, uint32_t at) {
    code[at] = 0x48;
    code[at + 1] = 0x8d;
    hr_plant(code, HR_CODE, at + 2, 0x05, 0, HR_BASE);
}

static void check_confirms_in_time(const char *what, const uint8_t *buf, size_t fsize) {
    mhr_cand bad = { 0, 0, 0 };
    hr_slow_what = what;
    signal(SIGALRM, hr_too_slow);
    alarm(HR_SLOW);
    int r = mhr_confirm(buf, fsize, &bad);
    alarm(0);
    signal(SIGALRM, SIG_DFL);
    CHECK(r == MHR_CONFIRMED, "%s: got %d, candidate %#llx", what, r, (unsigned long long)bad.addr);
}

/* One function of 149,796 leas, each a candidate. */
static void test_confirm_resumes_within_a_function(void) {
    const size_t n = 1u << 20, k = n / 7;
    static const uint8_t fs[] = { 0x80, 0x20, 0x00 };
    uint8_t *code = (uint8_t *)malloc(n);
    size_t fsize;
    memset(code, 0x90, n);
    for (size_t i = 0; i < k; i++) hr_put_lea(code, (uint32_t)(7 * i));
    uint8_t *buf = hr_big_image(code, n, fs, sizeof fs, NULL, 0, &fsize);
    check_confirms_in_time("confirm: 149,796 candidates in one function", buf, fsize);
    free(buf);
    free(code);
}

/* 300,000 one-byte LC_DATA_IN_CODE ranges, then 300,000 one-lea functions,
 * or with `one`, one function of 300,000 leas. */
static void check_resumes_after_data_in_code(int one, const char *what) {
    const size_t m = 300000, k = 300000, n = m + 7 * k;
    uint8_t *code = (uint8_t *)malloc(n), *fs = (uint8_t *)malloc(k + 4), *dic = (uint8_t *)malloc(8 * m);
    size_t nfs = 0, fsize;
    memset(code, 0x90, n);
    for (size_t i = 0; i < k; i++) hr_put_lea(code, (uint32_t)(m + 7 * i));
    uint64_t first = HR_FOFF + m;                  /* ULEB: the first function's distance from base */
    do { uint8_t b = first & 0x7f; first >>= 7; fs[nfs++] = (uint8_t)(b | (first ? 0x80 : 0)); } while (first);
    for (size_t i = 1; !one && i < k; i++) fs[nfs++] = 7;
    fs[nfs++] = 0;
    for (size_t i = 0; i < m; i++) {
        uint32_t off = (uint32_t)(HR_FOFF + i);
        uint16_t len = 1, kind = 1;
        memcpy(dic + 8 * i, &off, 4);
        memcpy(dic + 8 * i + 4, &len, 2);
        memcpy(dic + 8 * i + 6, &kind, 2);
    }
    uint8_t *buf = hr_big_image(code, n, fs, nfs, dic, 8 * m, &fsize);
    check_confirms_in_time(what, buf, fsize);
    free(buf);
    free(dic);
    free(fs);
    free(code);
}

static void test_confirm_resumes_across_data_in_code(void) {
    check_resumes_after_data_in_code(0, "confirm: 300,000 functions after 300,000 data-in-code ranges");
    check_resumes_after_data_in_code(1, "confirm: 300,000 candidates in one function after 300,000 "
                                        "data-in-code ranges");
}

/* __text's bytes at `t`, __stubs' at `u`, each section at the vm address
 * given, with `fs` and `dic` payloads; mhr_confirm's answer. */
static int hr_confirm_two(uint64_t taddr, const uint8_t *t, size_t nt, uint64_t uaddr,
                          const uint8_t *u, size_t nu, const uint8_t *fs, uint32_t nfs,
                          const uint8_t *dic, uint32_t ndic, mhr_cand *bad) {
    uint8_t *buf = build_code_image();
    struct section_64 *sc = (struct section_64 *)((struct segment_command_64 *)
                                                  ((struct mach_header_64 *)buf + 1) + 1);
    sc[0].addr = taddr;
    sc[1].addr = uaddr;
    memcpy(buf + sc[0].offset, t, nt);
    memcpy(buf + sc[1].offset, u, nu);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, fs, nfs);
    if (dic) hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, dic, ndic);
    int r = mhr_confirm(buf, HR_IMG_SIZE, bad);
    free(buf);
    return r;
}

/* Two functions, each a lea of the header, with a stray 0x68 between them.
 * Swept on from the first, push $imm32 swallows the second's first bytes. */
static void test_confirm_resumes_only_in_its_own_function(void) {
    static const uint8_t fs[] = { 0x80, 0x20, 0x08, 0x00 };   /* base + 0x1000, 0x1008 */
    struct hr_code k = { { 0x48, 0x8d }, 15, fs, sizeof fs, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 2, 0x05, 0, HR_BASE);
    k.b[7] = 0x68;
    k.b[8] = 0x48; k.b[9] = 0x8d;
    hr_plant(k.b, HR_CODE, 10, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: the second function sweeps from its own start "
          "(got %d at %#llx)", r, (unsigned long long)bad.addr);
}

/* Two instruction sections at one vm address. __stubs' add $5, %al; lea
 * confirms from their shared function start, but resumed where __text's
 * sweep stopped, one byte in, it reads as add $imm32, %eax. */
static void test_confirm_resumes_only_in_its_own_section(void) {
    uint8_t t[16], u[16];
    mhr_cand bad = { 0, 0, 0 };
    memset(t, 0x90, sizeof t);
    memset(u, 0x90, sizeof u);
    t[0] = 0x55;
    t[1] = 0x48; t[2] = 0x8d;
    hr_plant(t, HR_CODE, 3, 0x05, 0, HR_BASE);
    u[0] = 0x04; u[1] = 0x05;
    u[2] = 0x48; u[3] = 0x8d;
    hr_plant(u, HR_CODE, 4, 0x05, 0, HR_BASE);
    int r = hr_confirm_two(HR_CODE, t, sizeof t, HR_CODE, u, sizeof u, HR_ONE_FUNCTION,
                           sizeof HR_ONE_FUNCTION, NULL, 0, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: a second section at the same address sweeps afresh "
          "(got %d at %#llx)", r, (unsigned long long)bad.addr);
}

/* __stubs, listed after __text but mapped below it, starts with 3 bytes of
 * data. __text's sweep has passed them; __stubs' must still step over them,
 * or push $imm32 swallows the lea's first two bytes. */
static void test_confirm_carries_data_in_code_only_forward(void) {
    static const uint8_t fs[] = { 0x80, 0x20, 0x80, 0x08, 0x00 };   /* base + 0x1000, 0x1400 */
    static const uint8_t dic[] = { 0x00, 0x10, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00 };
    uint8_t t[16], u[16];
    mhr_cand bad = { 0, 0, 0 };
    memset(t, 0x90, sizeof t);
    memset(u, 0x90, sizeof u);
    t[0] = 0x48; t[1] = 0x8d;
    hr_plant(t, HR_BASE + 0x1400, 2, 0x05, 0, HR_BASE);
    u[0] = 0x68;
    u[3] = 0x48; u[4] = 0x8d;
    hr_plant(u, HR_BASE + 0x1000, 5, 0x05, 0, HR_BASE);
    int r = hr_confirm_two(HR_BASE + 0x1400, t, sizeof t, HR_BASE + 0x1000, u, sizeof u,
                           fs, sizeof fs, dic, sizeof dic, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: a section below the last one swept still steps over "
          "its data in code (got %d at %#llx)", r, (unsigned long long)bad.addr);
}

/* __text and __stubs share one vm address, one function start and one
 * data-in-code range, [X, X+3). __text's sweep passes the range; __stubs'
 * must still step over it, so the lea it hides there is data, not a
 * reference. */
static void test_confirm_carries_data_in_code_only_from_where_it_was_passed(void) {
    static const uint8_t dic[] = { 0x00, 0x10, 0x00, 0x00, 0x03, 0x00, 0x01, 0x00 };
    uint8_t t[16], u[16];
    mhr_cand bad = { 0, 0, 0 };
    memset(t, 0x90, sizeof t);
    memset(u, 0x90, sizeof u);
    t[3] = 0x48; t[4] = 0x8d;
    hr_plant(t, HR_CODE, 5, 0x05, 0, HR_BASE);
    u[0] = 0x48; u[1] = 0x8d;
    hr_plant(u, HR_CODE, 2, 0x05, 0, HR_BASE);
    int r = hr_confirm_two(HR_CODE, t, sizeof t, HR_CODE, u, sizeof u, HR_ONE_FUNCTION,
                           sizeof HR_ONE_FUNCTION, dic, sizeof dic, &bad);
    CHECK(r == MHR_UNCONFIRMED && bad.addr == HR_CODE + 3, "confirm: a lea inside another "
          "section's data in code is not confirmed (got %d at %#llx)", r,
          (unsigned long long)bad.addr);
}

/* A function-starts payload that runs past the file is not read: one that
 * starts inside it and ends past it, and one longer than the file. Either
 * would name __text's start. */
static void test_confirm_ignores_function_starts_past_the_image(void) {
    static const uint32_t at[2] = { HR_IMG_SIZE - 2, 0x1c00 }, size[2] = { 4, 0x10000 };
    for (int i = 0; i < 2; i++) {
        uint8_t *buf = build_code_image();
        struct hr_code k = hr_push_lea();
        mhr_cand bad = { 0, 0, 0 };
        memcpy(buf + HR_FOFF, k.b, k.n);
        hr_add_lc(buf, LC_FUNCTION_STARTS, at[i], HR_ONE_FUNCTION, 2);
        ((struct linkedit_data_command *)find_lc(buf, HR_IMG_SIZE, LC_FUNCTION_STARTS))->datasize = size[i];
        int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
        CHECK(r == MHR_NO_STARTS, "confirm: function starts at %#x, %#x bytes, past the image, "
              "are ignored (got %d)", at[i], size[i], r);
        free(buf);
    }
}

/* A 0 delta ends the list; what follows it names no function. Read as one,
 * the 3 here would start a function inside the lea. */
static void test_confirm_stops_at_the_function_starts_terminator(void) {
    static const uint8_t fs[] = { 0x80, 0x20, 0x00, 0x03 };
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = fs; k.nfs = sizeof fs;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: nothing after the terminator is a function (got %d)", r);
}

/* The first LC_FUNCTION_STARTS and the first LC_DATA_IN_CODE count, as in
 * src/grow.c. The second of each would make the lea unconfirmable. */
static void test_confirm_reads_the_first_of_each_command(void) {
    static const uint8_t late[] = { 0x90, 0x20, 0x00 };                          /* base + 0x1010 */
    static const uint8_t elsewhere[] = { 0x20, 0x10, 0, 0, 0x04, 0x00, 0x01, 0x00 };   /* +0x20 */
    static const uint8_t over_lea[] = { 0x01, 0x10, 0, 0, 0x07, 0x00, 0x01, 0x00 };    /* +1 */
    uint8_t *buf = build_code_image();
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    memcpy(buf + HR_FOFF, k.b, k.n);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c10, late, sizeof late);
    hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, elsewhere, sizeof elsewhere);
    hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d10, over_lea, sizeof over_lea);
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: the first of each command counts (got %d)", r);
    free(buf);
}

/* A function starts after the candidate, or in another section. */
static void test_confirm_needs_a_function_in_the_candidates_section(void) {
    static const uint8_t late[] = { 0x90, 0x20, 0x00 };      /* base + 0x1010 */
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = late; k.nfs = sizeof late;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: no function starts at or before it (got %d)", r);

    uint8_t *buf = build_code_image();
    uint8_t *stubs = buf + 0x1400;
    stubs[0] = 0x48; stubs[1] = 0x8d;
    hr_plant(stubs, HR_BASE + 0x1400, 2, 0x05, 0, HR_BASE);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION);
    r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_UNCONFIRMED && bad.addr == HR_BASE + 0x1403,
          "confirm: __stubs' lea has no function of its own (__text's is not it) (got %d, %#llx)",
          r, (unsigned long long)bad.addr);
    free(buf);
}

/* push; six bytes of data (ff ff: FF /7, no instruction); lea. */
static void test_confirm_steps_over_data_in_code(void) {
    static const uint8_t data[] = { 0x01, 0x10, 0, 0, 0x06, 0x00, 0x01, 0x00 };   /* +1, 6 bytes */
    struct hr_code k = { { 0x55, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x48, 0x8d }, 14,
                         HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, data, sizeof data };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 9, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: a lea after a data-in-code range (got %d)", r);
    k.dic = NULL;
    r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: the same bytes, with no range to step over (got %d)", r);
}

/* Two ranges, listed last first: push; data; nop; data; lea. */
static void test_confirm_orders_data_in_code(void) {
    static const uint8_t data[] = { 0x04, 0x10, 0, 0, 0x02, 0x00, 0x01, 0x00,
                                    0x01, 0x10, 0, 0, 0x02, 0x00, 0x01, 0x00 };
    struct hr_code k = { { 0x55, 0xff, 0xff, 0x90, 0xff, 0xff, 0x48, 0x8d }, 13,
                         HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, data, sizeof data };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 8, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: two data-in-code ranges, listed out of order (got %d)", r);
}

static void test_confirm_rejects_a_candidate_inside_data_in_code(void) {
    static const uint8_t data[] = { 0x01, 0x10, 0, 0, 0x07, 0x00, 0x01, 0x00 };   /* +1, 7 bytes */
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.dic = data; k.ndic = sizeof data;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: a lea inside a data-in-code range (got %d)", r);
}

/* 62 opens an EVEX instruction, which the decoder does not decode, so the
 * sweep stops there: it never reads on to the lea, four nops later. */
static void test_confirm_rejects_what_the_decoder_cannot_decode(void) {
    struct hr_code k = { { 0x55, 0x62, 0x90, 0x90, 0x90, 0x48, 0x8d }, 12,
                         HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 7, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: EVEX before the lea (got %d)", r);
}

static void test_confirm_reports_an_image_it_cannot_scan(void) {
    uint8_t *buf = build_code_image();
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    mhr_cand bad = { 0, 0, 0 };
    sc[1].size = HR_IMG_SIZE;                          /* __stubs runs past the image */
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_UNSCANNABLE, "confirm: an instruction section past the image (got %d)", r);
    free(buf);
}

/* Any instruction section past the file makes the image unscannable, even
 * when every candidate the scan can still read is confirmed: the scan goes on
 * past a bad section but answers -1. Here __text runs past the image, and
 * __stubs holds a lea at a function start of its own. */
static void test_confirm_reports_a_bad_section_before_a_good_one(void) {
    static const uint8_t stubs_fn[] = { 0x80, 0x28, 0x00 };   /* base + 0x1400: __stubs */
    uint8_t *buf = build_code_image();
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    mhr_cand bad = { 0, 0, 0 };
    buf[0x1400] = 0x48; buf[0x1401] = 0x8d;
    hr_plant(buf + 0x1400, HR_BASE + 0x1400, 2, 0x05, 0, HR_BASE);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, stubs_fn, sizeof stubs_fn);
    sc[0].size = HR_IMG_SIZE;                          /* __text: 0x1000 + 0x2000 > 0x2000 */
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_UNSCANNABLE, "confirm: a bad __text before a good __stubs (got %d)", r);
    sc[0].size = 0x100;
    r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: with __text readable, __stubs' lea confirms (got %d)", r);
    free(buf);
}

/* ---- data-in-code ranges that overlap a candidate instruction ----
 *
 * (1) A data-in-code range that starts partway through the instruction
 * holding the candidate's disp32 -- not at or before pc -- must leave the
 * candidate unconfirmed: the range check at loop-top sees only `pc`, not
 * the span the decoded instruction actually covers. Two shapes: a range
 * that is exactly the disp32 (4 bytes), and one starting a byte into the
 * lea (6 bytes, from lea+1). */
static void test_confirm_rejects_data_in_code_starting_mid_instruction(void) {
    static const uint8_t at_disp32[] = { 0x04, 0x10, 0, 0, 0x04, 0x00, 0x01, 0x00 };      /* +4, 4 bytes */
    static const uint8_t at_lea_plus_1[] = { 0x02, 0x10, 0, 0, 0x06, 0x00, 0x01, 0x00 };  /* +2, 6 bytes */
    const uint8_t *dics[2] = { at_disp32, at_lea_plus_1 };
    for (int i = 0; i < 2; i++) {
        struct hr_code k = hr_push_lea();
        mhr_cand bad = { 0, 0, 0 };
        k.dic = dics[i]; k.ndic = 8;
        int r = hr_confirm(&k, &bad);
        CHECK(r == MHR_UNCONFIRMED, "confirm: a data-in-code range starting mid-instruction "
              "(case %d) leaves it unconfirmed (got %d)", i, r);
    }
}

/* (2) 0x67 (address-size override) makes a RIP-relative-looking ModRM
 * actually EIP-relative: its target is (next truncated to 32 bits) + disp32,
 * not next + disp32. A disp32 that names the base under 64-bit RIP-relative
 * arithmetic must not confirm when 0x67 is among the instruction's
 * prefixes. */
static void test_confirm_rejects_an_eip_relative_operand(void) {
    struct hr_code k = { { 0x55, 0x67, 0x48, 0x8d }, 9, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    mhr_cand bad = { 0, 0, 0 };
    hr_plant(k.b, HR_CODE, 4, 0x05, 0, HR_BASE);
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_UNCONFIRMED, "confirm: an addr32 (0x67) lea is not RIP-relative (got %d)", r);
}

/* (3) A malformed ULEB128 after a real start, or a delta that wraps the
 * cumulative address, must discard every start the list produced -- not
 * just stop reading where it broke. mg_funcstarts_decode (src/grow.c)
 * returns -1 on the same malformed bytes, refusing to trust a partially-read
 * list; a wrapping delta is not monotonic, which a real LC_FUNCTION_STARTS
 * list never is. */
static void test_confirm_ignores_a_malformed_function_starts_list(void) {
    static const uint8_t fs[] = { 0x80, 0x20, 0xff };
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = fs; k.nfs = sizeof fs;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_NO_STARTS, "confirm: a malformed ULEB tail discards every start (got %d)", r);
}

/* 80 x9 02 is 2^64 with its only set bit dropped: read as 0, it would end
 * the list after __text's start and confirm the lea. */
static void test_confirm_ignores_an_overlong_function_starts_terminator(void) {
    static const uint8_t fs[] = { 0x80, 0x20,
                                  0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x02 };
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = fs; k.nfs = sizeof fs;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_NO_STARTS, "confirm: an overlong ULEB discards every start (got %d)", r);
}

static void test_confirm_ignores_a_wrapping_function_starts_delta(void) {
    static const uint8_t fs[] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 };
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = fs; k.nfs = sizeof fs;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_NO_STARTS, "confirm: a wrapping delta discards every start (got %d)", r);
}

/* An empty LC_DATA_IN_CODE is nothing to step over, wherever it points, as
 * mg_dice_walk already reads it. */
static void test_confirm_ignores_empty_data_in_code_past_the_image(void) {
    uint8_t *buf = build_code_image();
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    memcpy(buf + HR_FOFF, k.b, k.n);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct linkedit_data_command *l =
        (struct linkedit_data_command *)(buf + sizeof *h + h->sizeofcmds);
    hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, "", 0);
    l->dataoff = HR_IMG_SIZE + 0x100;
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_CONFIRMED, "confirm: empty data-in-code past the image (got %d)", r);
    free(buf);
}

/* An LC_DATA_IN_CODE payload past the image, or whose size is not a
 * multiple of its 8-byte entry, must not be treated as "no data-in-code to
 * step over" -- that lets literal data pass as code. Either makes the
 * image MHR_UNSCANNABLE, mirroring how an instruction section past the
 * image already does. */
static void test_confirm_reports_data_in_code_past_the_image(void) {
    uint8_t *buf = build_code_image();
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    memcpy(buf + HR_FOFF, k.b, k.n);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION);
    static const uint8_t dic[8] = { 0 };
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct linkedit_data_command *l =
        (struct linkedit_data_command *)(buf + sizeof *h + h->sizeofcmds);
    hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, dic, sizeof dic);
    l->datasize = HR_IMG_SIZE - l->dataoff + 8;   /* a multiple of 8, still 8 bytes past the image */
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_UNSCANNABLE, "confirm: data-in-code past the image (got %d)", r);
    free(buf);
}

static void test_confirm_reports_data_in_code_not_a_multiple_of_8(void) {
    uint8_t *buf = build_code_image();
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    memcpy(buf + HR_FOFF, k.b, k.n);
    hr_add_lc(buf, LC_FUNCTION_STARTS, 0x1c00, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION);
    static const uint8_t dic[8] = { 0 };
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct linkedit_data_command *l =
        (struct linkedit_data_command *)(buf + sizeof *h + h->sizeofcmds);
    hr_add_lc(buf, LC_DATA_IN_CODE, 0x1d00, dic, sizeof dic);
    l->datasize = 12;                                   /* not a multiple of 8 */
    int r = mhr_confirm(buf, HR_IMG_SIZE, &bad);
    CHECK(r == MHR_UNSCANNABLE, "confirm: data-in-code size not a multiple of 8 (got %d)", r);
    free(buf);
}

/* An empty but present LC_FUNCTION_STARTS -- just its terminator -- is the
 * same fact as no LC_FUNCTION_STARTS at all: no usable starts. */
static void test_confirm_needs_function_starts_when_the_list_is_empty(void) {
    static const uint8_t fs[] = { 0x00 };
    struct hr_code k = hr_push_lea();
    mhr_cand bad = { 0, 0, 0 };
    k.fs = fs; k.nfs = sizeof fs;
    int r = hr_confirm(&k, &bad);
    CHECK(r == MHR_NO_STARTS, "confirm: an empty function-starts list is no starts (got %d)", r);
}

/* ---- symbols that name the header ----
 * MG_T_SYMTAB's table (file 6656) gets four symbols. __mh_execute_header is
 * an N_SECT symbol whose value is the base, so it follows the header down.
 * The others keep their values: a symbol naming content, and a stab and an
 * absolute symbol whose values happen to equal the base. N_BNSYM's type bits
 * read as N_SECT under the N_TYPE mask; it is a stab all the same. */
static const struct { uint8_t type; uint64_t value, want; } hsyms[4] = {
    { N_SECT | N_EXT, 0x100000000ull, 0xfffff000ull },
    { N_SECT,         0x100001000ull, 0x100001000ull },
    { N_BNSYM,        0x100000000ull, 0x100000000ull },
    { N_ABS | N_EXT,  0x100000000ull, 0x100000000ull },
};

static uint8_t *build_symbol_image(size_t *fsize, uint32_t nsyms, int opts) {
    uint32_t sect_off;
    uint8_t *buf = build_image(fsize, &sect_off, MG_T_SYMTAB | opts);
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, *fsize, LC_SYMTAB);
    struct nlist_64 *nl = (struct nlist_64 *)(buf + st->symoff);
    for (int i = 0; i < 4; i++) {
        nl[i].n_type = hsyms[i].type;
        nl[i].n_sect = hsyms[i].type == N_ABS ? NO_SECT : 1;
        nl[i].n_value = hsyms[i].value;
    }
    st->nsyms = nsyms;
    return buf;
}

static void test_grow_moves_the_symbols_that_name_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "symbols: the grow succeeds (got %d)", r);
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB);
    const struct nlist_64 *nl = (const struct nlist_64 *)(buf + st->symoff);
    for (int i = 0; r == 0 && i < 4; i++)
        CHECK(nl[i].n_value == hsyms[i].want, "symbols: type %#x, value %#llx, is %#llx after "
              "the grow, want %#llx", hsyms[i].type, (unsigned long long)hsyms[i].value,
              (unsigned long long)nl[i].n_value, (unsigned long long)hsyms[i].want);
    free(buf);
}

/* Verification's own check on the symbols: one left naming where the header
 * was, one moved that named content, and one retyped. */
static void give_hsyms(uint8_t *buf, size_t fsize, uint32_t grow) {
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB);
    struct nlist_64 *nl = (struct nlist_64 *)(buf + st->symoff);
    (void)grow;
    for (int i = 0; i < 4; i++) {
        nl[i].n_type = hsyms[i].type;
        nl[i].n_sect = hsyms[i].type == N_ABS ? NO_SECT : 1;
        nl[i].n_value = hsyms[i].value;
    }
    st->nsyms = 4;
}
static struct nlist_64 *hsym(uint8_t *buf, size_t fsize, int i) {
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB);
    return (struct nlist_64 *)(buf + st->symoff) + i;
}
static void unmove_hsym(uint8_t *buf, size_t fsize, uint32_t grow) { hsym(buf, fsize, 0)->n_value += grow; }
static void move_content_sym(uint8_t *buf, size_t fsize, uint32_t grow) { hsym(buf, fsize, 1)->n_value -= grow; }
static void retype_hsym(uint8_t *buf, size_t fsize, uint32_t grow) {
    (void)grow;
    hsym(buf, fsize, 0)->n_type = N_ABS | N_EXT;
}
static void drop_hsym(uint8_t *buf, size_t fsize, uint32_t grow) {
    (void)grow;
    ((struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB))->nsyms = 3;
}

static void test_verify_watches_the_symbols(void) {
    check_verify_rejects_undone("a symbol left naming where the header was", MG_T_SYMTAB,
                                give_hsyms, unmove_hsym);
    check_verify_rejects_undone("a symbol naming content, moved with the header", MG_T_SYMTAB,
                                give_hsyms, move_content_sym);
    check_verify_rejects_undone("a symbol retyped", MG_T_SYMTAB, give_hsyms, retype_hsym);
    check_verify_rejects_undone("a symbol dropped", MG_T_SYMTAB, give_hsyms, drop_hsym);
}

/* A symbol table past the image: no snapshot, and no verify. */
static void test_snapshot_and_verify_refuse_a_symbol_table_past_the_image(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 1000, 0);   /* 6656 + 16000 > 8192 */
    mg_snapshot snap;
    CHECK(mg_snapshot_take(buf, fsize, &snap) == -1, "symbols: a snapshot of a table past the image");
    free(buf);
    buf = build_symbol_image(&fsize, 4, 0);
    if (mg_snapshot_take(buf, fsize, &snap) != 0) { CHECK(0, "symbols: snapshot"); free(buf); return; }
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "symbols: grow"); mg_snapshot_free(&snap); free(buf); return;
    }
    ((struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB))->nsyms = 1000;
    int r;
    verify_snap = &snap;
    int said = stderr_contains_during(verify_thunk, &buf, &fsize, 0,
        "ERROR: verify FAILED -- LC_SYMTAB's symbol table does not fit within the grown image; "
        "refusing.", &r);
    CHECK(r == -1 && said, "symbols: verify refuses a table past the grown image (got %d)", r);
    mg_snapshot_free(&snap);
    free(buf);
}

/* A grow patches every LC_SYMTAB and verifies the first, so it refuses a
 * second before changing anything. */
static void test_grow_refuses_two_symbol_tables(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB);
    memcpy((uint8_t *)(h + 1) + h->sizeofcmds, st, sizeof *st);
    h->ncmds++;
    h->sizeofcmds += sizeof *st;
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
        "ERROR: the image has more than one LC_SYMTAB; refusing to grow", &r);
    CHECK(r == -1 && said, "symbols: two symbol tables are refused (got %d)", r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0, "symbols: two tables: nothing changed");
    free(before);
    free(buf);
}

static void test_grow_refuses_a_symbol_table_past_the_image(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 1000, 0);   /* 6656 + 16000 > 8192 */
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
        "ERROR: LC_SYMTAB's symbol table (offset 6656, 1000 entries) does not fit within the "
        "8192-byte image; refusing to grow", &r);
    CHECK(r == -1 && said, "symbols: a table past the image is refused (got %d)", r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0, "symbols: nothing changed");
    free(before);
    free(buf);
}

/* A grow refused after the symbols are checked (here, for a malformed export
 * trie: node A's child offset points past the trie) leaves them as they were. */
static void test_grow_moves_no_symbol_when_it_refuses(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, MG_T_TRIE);
    buf[TRIE_OFF + 4] = 200;
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
                                      "export trie is malformed", &r);
    CHECK(r == -1 && said, "symbols: a malformed trie is refused (got %d)", r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "symbols: a refused grow moves no symbol");
    free(before);
    free(buf);
}

/* ---- pointers that name the header ----
 * A PIE executable whose __DATA holds pointers, with the rebase opcodes that
 * name them:
 *   __TEXT      file [0, 8192), vm 0x100000000; __text at file 4096 (F)
 *   __DATA      file [8192, 12288), vm [0x100002000, 0x100004000), the
 *               second half zero-fill; pt_ptrs at its start
 *   __LINKEDIT  file [12288, 12544), vm 0x100004000; the rebase opcodes at
 *               its start (PT_OPS), and with PT_CODE a function-starts list
 * Segment indexes: __PAGEZERO 0, __TEXT 1, __DATA 2, __LINKEDIT 3. With
 * PT_CODE, __text starts with `lea base(%rip), %rax` and is a function. */
#define PT_BASE   0x100000000ull
#define PT_F      4096u
#define PT_DATA   8192u
#define PT_DATAVM 0x100002000ull
#define PT_LE     12288u
#define PT_FSIZE  12544u
#define PT_OPS    PT_LE
#define PT_FS     (PT_LE + 64)
#define PT_CODE   1
#define PT_LOCREL 2   /* an LC_DYSYMTAB listing one local relocation entry */
#define PT_NOINFO 4   /* no LC_DYLD_INFO_ONLY: dyld reads LC_DYSYMTAB's entries instead */
static const uint64_t pt_ptrs[4] = {
    PT_BASE,             /* the header */
    PT_DATAVM + 0x40,    /* content */
    PT_BASE + PT_F,      /* the first byte of content */
    PT_BASE - 0x3000,    /* below the image, beyond a two-page grow */
};
#define PT_N 4

static uint8_t *build_pointer_image(size_t *fsize, int opts) {
    uint8_t *buf = (uint8_t *)calloc(1, PT_FSIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->filetype = MH_EXECUTE;
    h->flags = MH_PIE;
    uint8_t *lc = (uint8_t *)(h + 1);

    struct segment_command_64 *pz = (struct segment_command_64 *)lc;
    pz->cmd = LC_SEGMENT_64;
    pz->cmdsize = sizeof *pz;
    strcpy(pz->segname, "__PAGEZERO");
    pz->vmsize = PT_BASE;
    lc += pz->cmdsize;

    struct segment_command_64 *tx = (struct segment_command_64 *)lc;
    struct section_64 *text = (struct section_64 *)(tx + 1);
    tx->cmd = LC_SEGMENT_64;
    tx->cmdsize = sizeof *tx + sizeof *text;
    strcpy(tx->segname, "__TEXT");
    tx->vmaddr = PT_BASE;
    tx->vmsize = tx->filesize = PT_DATA;
    tx->nsects = 1;
    strncpy(text->sectname, "__text", sizeof text->sectname);
    strncpy(text->segname, "__TEXT", sizeof text->segname);
    text->addr = PT_BASE + PT_F;
    text->size = 16;
    text->offset = PT_F;
    text->flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS;
    lc += tx->cmdsize;

    struct segment_command_64 *da = (struct segment_command_64 *)lc;
    struct section_64 *data = (struct section_64 *)(da + 1);
    da->cmd = LC_SEGMENT_64;
    da->cmdsize = sizeof *da + sizeof *data;
    strcpy(da->segname, "__DATA");
    da->vmaddr = PT_DATAVM;
    da->vmsize = 0x2000;
    da->fileoff = PT_DATA;
    da->filesize = PT_LE - PT_DATA;
    da->nsects = 1;
    strncpy(data->sectname, "__data", sizeof data->sectname);
    strncpy(data->segname, "__DATA", sizeof data->segname);
    data->addr = PT_DATAVM;
    data->size = sizeof pt_ptrs;
    data->offset = PT_DATA;
    lc += da->cmdsize;

    struct segment_command_64 *le = (struct segment_command_64 *)lc;
    le->cmd = LC_SEGMENT_64;
    le->cmdsize = sizeof *le;
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = PT_DATAVM + 0x2000;
    le->vmsize = 0x1000;
    le->fileoff = PT_LE;
    le->filesize = PT_FSIZE - PT_LE;
    lc += le->cmdsize;

    h->ncmds = 4;
    if (!(opts & PT_NOINFO)) {
        struct dyld_info_command *di = (struct dyld_info_command *)lc;
        di->cmd = LC_DYLD_INFO_ONLY;
        di->cmdsize = sizeof *di;
        di->rebase_off = PT_OPS;
        di->rebase_size = 8;
        lc += di->cmdsize;
        h->ncmds++;
    }
    if (opts & PT_LOCREL) {
        struct dysymtab_command *ds = (struct dysymtab_command *)lc;
        ds->cmd = LC_DYSYMTAB;
        ds->cmdsize = sizeof *ds;
        ds->locreloff = PT_LE + 128;   /* X86_64_RELOC_UNSIGNED, 8 bytes, at __DATA+0, section 2 */
        ds->nlocrel = 1;
        lc += ds->cmdsize;
        h->ncmds++;
        static const uint8_t reloc[8] = { 0, 0, 0, 0, 0x02, 0, 0, 0x06 };
        memcpy(buf + PT_LE + 128, reloc, sizeof reloc);
    }

    /* SET_TYPE_IMM pointer; SET_SEGMENT_AND_OFFSET_ULEB 2, 0;
     * DO_REBASE_IMM_TIMES 4; DONE */
    static const uint8_t ops[8] = { 0x11, 0x22, 0x00, 0x54, 0x00, 0, 0, 0 };
    memcpy(buf + PT_OPS, ops, sizeof ops);
    memcpy(buf + PT_DATA, pt_ptrs, sizeof pt_ptrs);

    if (opts & PT_CODE) {
        struct linkedit_data_command *fs = (struct linkedit_data_command *)lc;
        static const uint8_t starts[8] = { 0x80, 0x20, 0x00 };   /* base + 4096: __text */
        fs->cmd = LC_FUNCTION_STARTS;
        fs->cmdsize = sizeof *fs;
        fs->dataoff = PT_FS;
        fs->datasize = sizeof starts;
        memcpy(buf + PT_FS, starts, sizeof starts);
        lc += fs->cmdsize;
        h->ncmds++;
        int32_t disp = (int32_t)(PT_BASE - (PT_BASE + PT_F + 7));
        buf[PT_F] = 0x48;
        buf[PT_F + 1] = 0x8d;
        buf[PT_F + 2] = 0x05;
        memcpy(buf + PT_F + 3, &disp, sizeof disp);
    }
    h->sizeofcmds = (uint32_t)(lc - (uint8_t *)(h + 1));
    *fsize = PT_FSIZE;
    return buf;
}

static struct segment_command_64 *pt_seg(uint8_t *buf, const char *name) {
    return seg_named(buf, PT_FSIZE, name);
}

static void test_rebases_read_every_target(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == PT_N, "rebases: all %d read (got %d, %zu: %s)", PT_N, r, rb.s.n, why);
    for (size_t i = 0; r == 0 && i < rb.s.n && i < PT_N; i++)
        CHECK(rb.v[i].at == PT_DATA + 8 * i && rb.v[i].vm == PT_DATAVM + 8 * i &&
              rb.v[i].value == pt_ptrs[i],
              "rebases: target %zu is at file %#llx, vm %#llx, holding %#llx; want %#llx, %#llx, "
              "%#llx", i, (unsigned long long)rb.v[i].at, (unsigned long long)rb.v[i].vm,
              (unsigned long long)rb.v[i].value, (unsigned long long)(PT_DATA + 8 * i),
              (unsigned long long)(PT_DATAVM + 8 * i), (unsigned long long)pt_ptrs[i]);
    mg_rebases_free(&rb);
    free(buf);
}

/* A slot ending exactly at its segment's file data is still in the file. */
static void test_rebases_read_a_target_ending_at_the_segments_file_data(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    pt_seg(buf, "__DATA")->filesize = 8 * PT_N;
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == PT_N, "rebases: the last slot ends at the file data (got %d: %s)",
          r, why);
    mg_rebases_free(&rb);
    free(buf);
}

static void test_rebases_read_none_without_rebase_opcodes(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, 0);   /* no LC_DYLD_INFO at all */
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == 0, "rebases: none without LC_DYLD_INFO (got %d, %zu)", r, rb.s.n);
    mg_rebases_free(&rb);
    free(buf);
    buf = build_pointer_image(&fsize, 0);
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->rebase_size = 0;
    r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == 0, "rebases: none with empty rebase opcodes (got %d, %zu)", r, rb.s.n);
    mg_rebases_free(&rb);
    free(buf);
}

/* Each way the rebase targets cannot be read. `poke` breaks the fixture. */
typedef void (*pt_poke)(uint8_t *buf);
static void pt_type(uint8_t *buf) { buf[PT_OPS] = 0x12; }             /* TEXT_ABSOLUTE32 */
static void pt_in_text(uint8_t *buf) { buf[PT_OPS + 1] = 0x21; }      /* __TEXT */
static void pt_no_segment(uint8_t *buf) { buf[PT_OPS + 1] = 0x2f; }   /* segment 15 */
static void pt_unknown_op(uint8_t *buf) { buf[PT_OPS + 3] = 0x90; }
static void pt_zerofill(uint8_t *buf) { pt_seg(buf, "__DATA")->filesize = 16; }
static void pt_straddle(uint8_t *buf) { pt_seg(buf, "__DATA")->filesize = 20; }
static void pt_all_zerofill(uint8_t *buf) { pt_seg(buf, "__DATA")->filesize = 0; }
static void pt_past_image(uint8_t *buf) { pt_seg(buf, "__DATA")->fileoff = PT_FSIZE - 16; }
static void pt_all_past_image(uint8_t *buf) { pt_seg(buf, "__DATA")->fileoff = PT_FSIZE + 0x1000; }
static void pt_short_of_a_slot(uint8_t *buf) { pt_seg(buf, "__DATA")->fileoff = PT_FSIZE - 4; }
static void pt_ops_past_image(uint8_t *buf) {
    ((struct dyld_info_command *)find_lc(buf, PT_FSIZE, LC_DYLD_INFO_ONLY))->rebase_size = 1000;
}
static void pt_twice(uint8_t *buf) {        /* then SET_SEGMENT_AND_OFFSET_ULEB 2, 16; DO 1 */
    static const uint8_t again[4] = { 0x22, 0x10, 0x51, 0x00 };
    memcpy(buf + PT_OPS + 4, again, sizeof again);
}
static void pt_two_dyld_info(uint8_t *buf) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *di = (uint8_t *)find_lc(buf, PT_FSIZE, LC_DYLD_INFO_ONLY);
    memcpy((uint8_t *)(h + 1) + h->sizeofcmds, di, sizeof(struct dyld_info_command));
    h->ncmds++;
    h->sizeofcmds += sizeof(struct dyld_info_command);
}
/* The fixture's last command, cut to the 8 bytes mi_validate vouches for. */
static void pt_short_di(uint8_t *buf) {
    struct dyld_info_command *di =
        (struct dyld_info_command *)find_lc(buf, PT_FSIZE, LC_DYLD_INFO_ONLY);
    di->cmdsize = sizeof(struct load_command);
}
static void pt_short_dysymtab(uint8_t *buf) {
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct load_command *lc = (struct load_command *)((uint8_t *)(h + 1) + h->sizeofcmds);
    lc->cmd = LC_DYSYMTAB;
    lc->cmdsize = sizeof *lc;
    h->ncmds++;
    h->sizeofcmds += sizeof *lc;
}
static const struct { const char *what; pt_poke poke; const char *why; } pt_unreadable[] = {
    { "a rebase that is not a pointer", pt_type,
      "the rebase at __DATA+0 is of type 2, not a pointer" },
    { "a rebase in the segment that maps the header", pt_in_text,
      "the rebase at __TEXT+0 lies in the segment that maps the header" },
    { "a rebase naming a segment the image lacks", pt_no_segment,
      "names segment 15, and there are 4" },
    { "an unknown rebase opcode", pt_unknown_op, "unknown rebase opcode 0x90 at byte 3" },
    { "a rebase in zero-fill", pt_zerofill,
      "the rebase at __DATA+0x10 lies past the 16 bytes of that segment the file holds, so its "
      "value is not in the file" },
    { "a rebase straddling the end of its file data", pt_straddle,
      "the rebase at __DATA+0x10 lies past the 20 bytes of that segment the file holds, so its "
      "value is not in the file" },
    { "a rebase in a segment with no file data", pt_all_zerofill,
      "the rebase at __DATA+0 lies past the 0 bytes of that segment the file holds, so its "
      "value is not in the file" },
    { "a rebase past the end of the image", pt_past_image,
      "the rebase at __DATA+0x10 lies past the end of the 12544-byte image" },
    { "a segment whose file data starts past the image", pt_all_past_image,
      "the rebase at __DATA+0 lies past the end of the 12544-byte image" },
    { "a segment whose file data starts 4 bytes before the image ends", pt_short_of_a_slot,
      "the rebase at __DATA+0 lies past the end of the 12544-byte image" },
    { "rebase opcodes past the end of the image", pt_ops_past_image,
      "the rebase opcodes (1000 bytes at offset 12288) run past the end of the 12544-byte image" },
    { "two LC_DYLD_INFO commands", pt_two_dyld_info, "the image has 2 LC_DYLD_INFO commands" },
    { "a slot rebased twice", pt_twice, "the rebase opcodes name __DATA+0x10 more than once" },
    { "a short LC_DYLD_INFO command", pt_short_di,
      "the image's LC_DYLD_INFO command is 8 bytes, too short to hold rebase_off/rebase_size" },
    { "a short LC_DYSYMTAB command", pt_short_dysymtab,
      "the image's LC_DYSYMTAB command is 8 bytes, too short to hold nlocrel" },
};

static void test_rebases_read_refuses_what_it_cannot_read(void) {
    for (size_t k = 0; k < sizeof pt_unreadable / sizeof pt_unreadable[0]; k++) {
        size_t fsize;
        uint8_t *buf = build_pointer_image(&fsize, 0);
        pt_unreadable[k].poke(buf);
        mg_rebases rb;
        char why[256] = "";
        int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
        CHECK(r == -1 && strstr(why, pt_unreadable[k].why) != NULL,
              "rebases: %s is refused (got %d, '%s')", pt_unreadable[k].what, r, why);
        CHECK(rb.s.n == 0 && rb.s.v == NULL && rb.v == NULL,
              "rebases: %s leaves nothing behind", pt_unreadable[k].what);
        mg_rebases_free(&rb);
        free(buf);
    }
}

/* Cut where the short command ends, so that under libgmalloc reading any of
 * its missing fields faults. */
static void test_rebases_read_refuses_a_short_command_before_reading_it(void) {
    static const pt_poke pokes[] = { pt_short_di, pt_short_dysymtab };
    for (size_t k = 0; k < sizeof pokes / sizeof pokes[0]; k++) {
        size_t fsize;
        uint8_t *buf = build_pointer_image(&fsize, 0);
        pokes[k](buf);
        size_t end = sizeof(struct mach_header_64) + ((struct mach_header_64 *)buf)->sizeofcmds;
        uint8_t *cut = (uint8_t *)malloc(end);
        memcpy(cut, buf, end);
        mg_rebases rb;
        char why[256] = "";
        int r = mg_rebases_read(cut, end, &rb, why, sizeof why);
        CHECK(r == -1 && strstr(why, "too short to hold") != NULL,
              "rebases: short command %zu, at the end of the image, is refused (got %d, '%s')",
              k, r, why);
        mg_rebases_free(&rb);
        free(cut);
        free(buf);
    }
}

/* And a grow refuses each, before it changes anything. */
static void test_grow_refuses_rebases_it_cannot_read(void) {
    for (size_t k = 0; k < sizeof pt_unreadable / sizeof pt_unreadable[0]; k++) {
        size_t fsize;
        uint8_t *buf = build_pointer_image(&fsize, 0);
        pt_unreadable[k].poke(buf);
        size_t fsize0 = fsize;
        uint8_t *before = (uint8_t *)malloc(fsize0);
        memcpy(before, buf, fsize0);
        char want[320];
        int r;
        snprintf(want, sizeof want, "%s; refusing to grow", pt_unreadable[k].why);
        int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000, want, &r);
        CHECK(r == -1 && said, "grow: %s is refused, saying so (got %d)", pt_unreadable[k].what, r);
        CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
              "grow: %s: nothing changed", pt_unreadable[k].what);
        free(before);
        free(buf);
    }
}

/* The control: the fixture as built grows. */
static void test_grow_accepts_readable_rebases(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "grow: the pointer fixture grows (got %d)", r);
    free(buf);
}

static void test_rebases_read_refuses_a_malformed_image(void) {
    uint8_t buf[16] = { 0 };   /* bad magic, and shorter than a header */
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, sizeof buf, &rb, why, sizeof why);
    CHECK(r == -1 && strstr(why, "the image does not validate") != NULL,
          "rebases: a malformed image is refused (got %d, '%s')", r, why);
    mg_rebases_free(&rb);
}

/* With no `why` to refuse through, mg_find_trie reports no trie. */
static void test_find_trie_refuses_a_short_dyld_info(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    pt_short_di(buf);
    uint32_t off, size;
    int r = mg_find_trie(buf, fsize, &off, &size);
    CHECK(r == 0, "find_trie: a short LC_DYLD_INFO command yields no trie (got %d)", r);
    free(buf);
}

/* The pointer values in __DATA after a grow, wherever the file now holds them. */
static const uint64_t *pt_values(uint8_t *buf, size_t fsize) {
    struct segment_command_64 *da = seg_named(buf, fsize, "__DATA");
    return da ? (const uint64_t *)(buf + da->fileoff) : NULL;
}

static void check_pointers_after(const char *what, uint32_t grow_req, uint32_t grow,
                                 uint64_t slot3) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    uint64_t want[PT_N];
    memcpy(want, pt_ptrs, sizeof want);
    ((uint64_t *)(buf + PT_DATA))[3] = want[3] = slot3;
    want[0] -= grow;
    if (slot3 == PT_BASE) want[3] -= grow;
    int r = mg_grow_header(&buf, &fsize, grow_req);
    CHECK(r == 0, "%s: the grow succeeds (got %d)", what, r);
    const uint64_t *v = r == 0 ? pt_values(buf, fsize) : NULL;
    for (int i = 0; v && i < PT_N; i++)
        CHECK(v[i] == want[i], "%s: pointer %d holds %#llx after the grow, want %#llx", what, i,
              (unsigned long long)v[i], (unsigned long long)want[i]);
    free(buf);
}

/* The header moves down by the grow; what names it follows, and what names
 * content, the first byte of content, or below the grown header stays. */
static void test_grow_moves_the_pointers_that_name_the_header(void) {
    check_pointers_after("pointers", 0x1000, 0x1000, pt_ptrs[3]);
    check_pointers_after("two pointers to the header", 0x1000, 0x1000, PT_BASE);
    check_pointers_after("pointers, two-page grow", 0x1001, 0x2000, pt_ptrs[3]);
    check_pointers_after("a pointer just below the grown header", 0x1000, 0x1000,
                         PT_BASE - 0x1001);
    check_pointers_after("a pointer just below the header grown two pages", 0x1001, 0x2000,
                         PT_BASE - 0x2001);
}

/* Slot 1 holds `value`, and a grow of `grow_req` refuses it: nothing changed. */
static void check_grow_refuses_a_pointer(uint64_t value, uint32_t grow_req, const char *needle) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    ((uint64_t *)(buf + PT_DATA))[1] = value;
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, grow_req, needle, &r);
    CHECK(r == -1 && said, "pointer: %#llx is refused, saying '%s' (got %d)",
          (unsigned long long)value, needle, r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "pointer: %#llx: nothing changed", (unsigned long long)value);
    free(before);
    free(buf);
}

/* A value strictly inside (base, base + F) names a byte of the header or its
 * load commands, which the grow moves apart. */
static void test_grow_refuses_a_pointer_inside_the_header(void) {
    check_grow_refuses_a_pointer(PT_BASE + 1, 0x1000,
        "ERROR: the pointer at 0x100002008 names 0x100000001, between the header at 0x100000000 "
        "and its first content at 0x100001000, which a grow moves apart; refusing to grow");
    check_grow_refuses_a_pointer(PT_BASE + PT_F - 1, 0x1000,
        "ERROR: the pointer at 0x100002008 names 0x100000fff, between the header");
}

/* A value in [base - G, base) names nothing before a grow of G, and the grown
 * header after it. */
static void test_grow_refuses_a_pointer_below_the_header(void) {
    check_grow_refuses_a_pointer(PT_BASE - 1, 0x1000,
        "ERROR: the pointer at 0x100002008 names 0xffffffff, within the 0x1000 bytes below the "
        "header at 0x100000000, where the grown header will lie; refusing to grow");
    check_grow_refuses_a_pointer(PT_BASE - 0x1000, 0x1000,
        "ERROR: the pointer at 0x100002008 names 0xfffff000, within the 0x1000 bytes below");
    check_grow_refuses_a_pointer(PT_BASE - 0x2000, 0x1001,
        "ERROR: the pointer at 0x100002008 names 0xffffe000, within the 0x2000 bytes below");
}

static void test_header_pointers_counts_without_moving(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    ((uint64_t *)(buf + PT_DATA))[3] = PT_BASE;
    uint8_t *before = (uint8_t *)malloc(fsize);
    memcpy(before, buf, fsize);
    char why[256] = "";
    int64_t n = mg_header_pointers(buf, fsize, PT_BASE, PT_F, 0, 0, why, sizeof why);
    CHECK(n == 2, "count: two pointers name the header (got %lld: %s)", (long long)n, why);
    CHECK(memcmp(before, buf, fsize) == 0, "count: counting moves nothing");
    free(before);
    free(buf);
}

/* mg_ensure_pad announces the pointers it moved, with the code it repaired. */
static void check_ensure_pad_announces(const char *what, int opts, int also, const char *tail) {
    size_t fsize;
    int r;
    uint8_t *buf = build_pointer_image(&fsize, opts);
    if (also) ((uint64_t *)(buf + PT_DATA))[3] = PT_BASE;
    char *err = ensure_pad_stderr(&buf, &fsize, PT_F + 1, &r);
    CHECK(r == 0 && strstr(err, tail) != NULL, "%s: announced as '...%s' (got %d):\n%s", what,
          tail, r, err);
    free(err);
    free(buf);
}

static void test_ensure_pad_announces_the_pointers_it_moves(void) {
    check_ensure_pad_announces("one pointer", 0, 0,
        "image base 0x100000000 -> 0xfffff000; repaired 1 reference to the header\n");
    check_ensure_pad_announces("two pointers", 0, 1,
        "image base 0x100000000 -> 0xfffff000; repaired 2 references to the header\n");
    check_ensure_pad_announces("a pointer and an instruction", PT_CODE, 0,
        "image base 0x100000000 -> 0xfffff000; repaired 2 references to the header\n");
}

/* Verification's own check on the pointers: a snapshot of the fixture, a
 * grow, then `undo` breaks what the grow made, and verify must say `needle`.
 * `setup`, if any, changes the fixture before the snapshot. */
typedef void (*pt_tweak)(uint8_t *buf, size_t fsize);
static uint8_t *pt_ops_now(uint8_t *buf, size_t fsize) {
    return buf + ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->rebase_off;
}
static uint64_t *pt_slots_now(uint8_t *buf, size_t fsize) {
    return (uint64_t *)(buf + seg_named(buf, fsize, "__DATA")->fileoff);
}
static void pt_unmove(uint8_t *buf, size_t fsize) { pt_slots_now(buf, fsize)[0] += 0x1000; }
static void pt_move_again(uint8_t *buf, size_t fsize) { pt_slots_now(buf, fsize)[0] -= 0x1000; }
static void pt_move_content(uint8_t *buf, size_t fsize) { pt_slots_now(buf, fsize)[1] -= 0x1000; }
static void pt_drop_one(uint8_t *buf, size_t fsize) { pt_ops_now(buf, fsize)[3] = 0x53; }
static void pt_retype(uint8_t *buf, size_t fsize) { pt_ops_now(buf, fsize)[0] = 0x12; }
static void pt_all_alike(uint8_t *buf, size_t fsize) {
    for (int i = 0; i < PT_N + 1; i++) pt_slots_now(buf, fsize)[i] = PT_DATAVM + 0x40;
}
static void pt_shift_one(uint8_t *buf, size_t fsize) { pt_ops_now(buf, fsize)[2] = 0x08; }
static void pt_add_one(uint8_t *buf, size_t fsize) { pt_ops_now(buf, fsize)[3] = 0x55; }

static void check_verify_rejects_pointer(const char *what, pt_tweak setup, pt_tweak undo,
                                         const char *needle) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    if (setup) setup(buf, fsize);
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) {
        CHECK(0, "%s: snapshot", what); free(buf); return;
    }
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "%s: grow", what); mg_snapshot_free(&snap); free(buf); return;
    }
    CHECK(mg_verify(buf, fsize, &snap) == 0, "%s: verify accepts the grow as made", what);
    undo(buf, fsize);
    int r, errors = 0;
    verify_snap = &snap;
    char *err = stderr_during(verify_thunk, &buf, &fsize, 0, &r);
    for (const char *p = err; (p = strstr(p, "ERROR")) != NULL; p++) errors++;
    CHECK(r == -1 && strstr(err, needle) != NULL, "verify REJECTS %s, saying '%s' (got %d):\n%s",
          what, needle, r, err);
    CHECK(errors == 1, "%s: verify prints one ERROR, not %d:\n%s", what, errors, err);
    free(err);
    mg_snapshot_free(&snap);
    free(buf);
}

static void test_verify_watches_the_pointers(void) {
    check_verify_rejects_pointer("a pointer left naming where the header was", NULL, pt_unmove,
        "ERROR: verify FAILED -- the pointer at 0x100002000 holds 0x100000000 after the grow, and "
        "must hold 0xfffff000; refusing.");
    check_verify_rejects_pointer("a pointer to the header moved twice", NULL, pt_move_again,
        "the pointer at 0x100002000 holds 0xffffe000 after the grow, and must hold 0xfffff000");
    check_verify_rejects_pointer("a pointer to content moved with the header", NULL,
        pt_move_content,
        "the pointer at 0x100002008 holds 0x100001040 after the grow, and must hold 0x100002040");
    check_verify_rejects_pointer("a rebase dropped", NULL, pt_drop_one,
        "ERROR: verify FAILED -- the grown image rebases 3 pointers, 4 before the grow; refusing.");
    check_verify_rejects_pointer("a rebase added", NULL, pt_add_one,
        "ERROR: verify FAILED -- the grown image rebases 5 pointers, 4 before the grow; refusing.");
    check_verify_rejects_pointer("a rebase moved to a slot holding the same value", pt_all_alike,
        pt_shift_one,
        "ERROR: verify FAILED -- rebase 0 is at 0x100002008 after the grow, and must be at "
        "0x100002000; refusing.");
    check_verify_rejects_pointer("rebases it cannot read", NULL, pt_retype,
        "ERROR: verify FAILED -- the grown image's rebases cannot be read (the rebase at __DATA+0 "
        "is of type 2, not a pointer); refusing.");
}

static void test_snapshot_refuses_rebases_it_cannot_read(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, 0);
    pt_type(buf);
    mg_snapshot snap;
    CHECK(mg_snapshot_take(buf, fsize, &snap) == -1, "snapshot: rebases it cannot read");
    free(buf);
}

/* An image with no rebase opcodes lists its pointers, if any, in LC_DYSYMTAB's
 * local relocation entries, and dyld then slides the pointers they name. A
 * grow does not read those, so it cannot move one that names the header:
 * refused. With rebase opcodes, dyld reads only those, and so does the grow. */
static void test_rebases_read_refuses_local_relocations(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, PT_NOINFO | PT_LOCREL);
    mg_rebases rb;
    char why[256] = "";
    int r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == -1 && strcmp(why, "the image lists its pointers in LC_DYSYMTAB's local "
                                 "relocation entries (1), not in rebase opcodes, and a grow does "
                                 "not read those") == 0,
          "local relocations: refused (got %d, '%s')", r, why);
    mg_rebases_free(&rb);
    free(buf);

    buf = build_pointer_image(&fsize, PT_LOCREL);
    r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == PT_N, "local relocations beside rebase opcodes: the opcodes are "
          "read (got %d, %zu: %s)", r, rb.s.n, why);
    mg_rebases_free(&rb);
    free(buf);

    buf = build_pointer_image(&fsize, PT_LOCREL);
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->rebase_size = 0;
    r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == 0, "local relocations beside empty rebase opcodes: nothing to read "
          "(got %d, %zu: %s)", r, rb.s.n, why);
    mg_rebases_free(&rb);
    free(buf);

    buf = build_pointer_image(&fsize, PT_NOINFO);
    r = mg_rebases_read(buf, fsize, &rb, why, sizeof why);
    CHECK(r == 0 && rb.s.n == 0, "neither: nothing to read (got %d, %zu: %s)", r, rb.s.n, why);
    mg_rebases_free(&rb);
    free(buf);
}

static void test_grow_refuses_local_relocations(void) {
    size_t fsize;
    uint8_t *buf = build_pointer_image(&fsize, PT_NOINFO | PT_LOCREL);
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    int said = stderr_contains_during(mg_grow_header, &buf, &fsize, 0x1000,
        "ERROR: the image lists its pointers in LC_DYSYMTAB's local relocation entries (1), not "
        "in rebase opcodes, and a grow does not read those; refusing to grow", &r);
    CHECK(r == -1 && said, "local relocations: the grow refuses, saying why (got %d)", r);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0,
          "local relocations: nothing changed");
    free(before);
    free(buf);
    buf = build_pointer_image(&fsize, PT_LOCREL);
    r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "local relocations beside rebase opcodes: the grow succeeds (got %d)", r);
    free(buf);
    buf = build_pointer_image(&fsize, PT_LOCREL);
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->rebase_size = 0;
    r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "local relocations beside empty rebase opcodes: the grow succeeds (got %d)", r);
    free(buf);
}

/* ---- a range of targets ----
 * The one rule refuses what names a byte strictly between the header and
 * its first content, so the scan also takes a range, [first, last], and
 * says what each candidate names. */
#define HR_FIRST (HR_BASE + 1)
#define HR_LAST  (HR_BASE + 0xfff)

static void test_scan_reports_each_candidates_target(void) {
    uint8_t code[16];
    memset(code, 0x90, sizeof code);
    hr_plant(code, HR_CODE, 2, 0x3d, 2, HR_BASE);
    struct hr_seen s = { { { 0 } }, 0, 0 };
    mhr_scan_code(code, sizeof code, HR_CODE, HR_FOFF, HR_BASE, hr_record, &s);
    CHECK(s.n == 1 && s.c[0].target == HR_BASE && s.c[0].immlen == 2,
          "scan: the candidate names %#llx with a 2-byte immediate (%d found, %#llx, %d)",
          (unsigned long long)HR_BASE, s.n, (unsigned long long)s.c[0].target, s.c[0].immlen);
}

/* One operand whose target is first - 2 without an immediate reaches the
 * range only with a 2- or 4-byte one; one at last - 1 leaves it with a
 * 2-byte one. */
static void test_scan_range_takes_its_bounds_inclusively(void) {
    uint8_t *buf = build_code_image();
    hr_plant(buf + HR_FOFF, HR_CODE, 0x20, 0x05, 0, HR_FIRST - 2);
    hr_plant(buf + HR_FOFF, HR_CODE, 0x40, 0x05, 0, HR_LAST - 1);
    struct hr_seen s = { { { 0 } }, 0, 0 };
    int64_t n = mhr_scan_range(buf, HR_IMG_SIZE, HR_FIRST, HR_LAST, hr_record, &s);
    static const struct { uint64_t addr; int immlen; uint64_t target; } want[4] = {
        { HR_CODE + 0x21, 2, HR_FIRST },
        { HR_CODE + 0x21, 4, HR_FIRST + 2 },
        { HR_CODE + 0x41, 0, HR_LAST - 1 },
        { HR_CODE + 0x41, 1, HR_LAST },
    };
    CHECK(n == 4 && s.n == 4, "range: %lld candidates, want 4", (long long)n);
    for (int k = 0; k < 4 && k < s.n; k++)
        CHECK(s.c[k].addr == want[k].addr && s.c[k].immlen == want[k].immlen &&
              s.c[k].target == want[k].target,
              "range: candidate %d is at %#llx, immediate %d, naming %#llx; want %#llx, %d, %#llx",
              k, (unsigned long long)s.c[k].addr, s.c[k].immlen, (unsigned long long)s.c[k].target,
              (unsigned long long)want[k].addr, want[k].immlen, (unsigned long long)want[k].target);
    free(buf);
}

struct hr_verdicts { mhr_cand c[8]; int v[8]; int n; int stop_after; };
static int hr_verdict(const mhr_cand *c, int verdict, void *ctx) {
    struct hr_verdicts *s = (struct hr_verdicts *)ctx;
    if (s->n < 8) { s->c[s->n] = *c; s->v[s->n] = verdict; }
    s->n++;
    return s->stop_after && s->n >= s->stop_after;
}

static int hr_confirm_each(const struct hr_code *k, struct hr_verdicts *s) {
    uint8_t *buf = hr_code_image(k);
    int r = mhr_confirm_each(buf, HR_IMG_SIZE, HR_FIRST, HR_LAST, hr_verdict, s);
    free(buf);
    return r;
}

/* push; lea base+16(%rip), %rax. Its disp32 names base + 16 with no
 * immediate, which decoding confirms, and base + 17, + 18 and + 20 with one,
 * which decoding refutes: the lea has none. */
static struct hr_code hr_push_lea_inside(void) {
    struct hr_code k = hr_push_lea();
    hr_plant(k.b, HR_CODE, 3, 0x05, 0, HR_BASE + 16);
    return k;
}

/* Each case's four candidates share a disp32, at `at`, and name base + 16,
 * + 17, + 18 and + 20; `v` is each one's verdict. */
static void check_verdicts(const char *what, const struct hr_code *k, uint64_t at, const int v[4]) {
    static const int immlen[4] = { 0, 1, 2, 4 };
    struct hr_verdicts s = { { { 0 } }, { 0 }, 0, 0 };
    int r = hr_confirm_each(k, &s);
    CHECK(r == MHR_CONFIRMED && s.n == 4, "verdicts: %s: 4 candidates (got %d, %d)", what, r, s.n);
    for (int i = 0; i < 4 && i < s.n; i++)
        CHECK(s.c[i].addr == at && s.c[i].immlen == immlen[i] && s.v[i] == v[i],
              "verdicts: %s: with a %d-byte immediate, verdict %d, want %d (at %#llx)", what,
              immlen[i], s.v[i], v[i], (unsigned long long)s.c[i].addr);
}

static void test_confirm_each_gives_each_candidate_its_verdict(void) {
    static const int lea[4] = { MHR_CONFIRMED, MHR_REFUTED, MHR_REFUTED, MHR_REFUTED };
    static const int refuted[4] = { MHR_REFUTED, MHR_REFUTED, MHR_REFUTED, MHR_REFUTED };
    static const int unreached[4] = { MHR_UNCONFIRMED, MHR_UNCONFIRMED, MHR_UNCONFIRMED,
                                      MHR_UNCONFIRMED };
    static const int nostarts[4] = { MHR_NO_STARTS, MHR_NO_STARTS, MHR_NO_STARTS, MHR_NO_STARTS };
    static const int addr32v[4] = { MHR_UNCONFIRMED, MHR_REFUTED, MHR_REFUTED, MHR_REFUTED };
    static const uint8_t late[] = { 0x90, 0x20, 0x00 };                            /* base + 0x1010 */
    static const uint8_t data[] = { 0x01, 0x10, 0, 0, 0x07, 0x00, 0x01, 0x00 };   /* +1, 7 bytes */
    static const uint8_t disp[] = { 0x04, 0x10, 0, 0, 0x04, 0x00, 0x01, 0x00 };   /* +4, 4 bytes */
    struct hr_code k = hr_push_lea_inside();
    check_verdicts("a lea", &k, HR_CODE + 4, lea);

    struct hr_code mov = { { 0x55, 0xb8 }, 8, HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(mov.b, HR_CODE, 2, 0x05, 0, HR_BASE + 16);                /* mov $imm32, %eax */
    check_verdicts("inside mov's immediate", &mov, HR_CODE + 3, refuted);

    struct hr_code next = { { 0x55, 0xb8, 0x00, 0x00, 0x00 }, 11, HR_ONE_FUNCTION,
                            sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(next.b, HR_CODE, 5, 0x05, 0, HR_BASE + 16);               /* the imm32's last byte */
    check_verdicts("where the next instruction begins", &next, HR_CODE + 6, refuted);

    k = hr_push_lea_inside();
    k.dic = data; k.ndic = sizeof data;
    check_verdicts("in data in code", &k, HR_CODE + 4, refuted);

    k = hr_push_lea_inside();
    k.dic = disp; k.ndic = sizeof disp;
    check_verdicts("in an instruction that is partly data", &k, HR_CODE + 4, unreached);

    struct hr_code evex = { { 0x55, 0x62, 0x90, 0x90, 0x90, 0x48, 0x8d }, 12, HR_ONE_FUNCTION,
                            sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(evex.b, HR_CODE, 7, 0x05, 0, HR_BASE + 16);
    check_verdicts("past what the decoder cannot decode", &evex, HR_CODE + 8, unreached);

    /* 0x67 (address-size override) makes a RIP-relative-looking ModRM
     * actually EIP-relative (src/x86len.h's adsize comment): the immediate
     * length that matches the lea (0, as it has none) is untrusted, not
     * refuted; the other three lengths don't match this instruction at all,
     * so decoding refutes them same as any other lea (the "a lea" case,
     * above). Same bytes as test_confirm_rejects_an_eip_relative_operand,
     * retargeted to base + 16. */
    struct hr_code addr32 = { { 0x55, 0x67, 0x48, 0x8d }, 9, HR_ONE_FUNCTION,
                              sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(addr32.b, HR_CODE, 4, 0x05, 0, HR_BASE + 16);
    check_verdicts("an addr32 operand", &addr32, HR_CODE + 5, addr32v);

    k = hr_push_lea_inside();
    k.fs = late; k.nfs = sizeof late;
    check_verdicts("with no function start at or before it", &k, HR_CODE + 4, unreached);

    k = hr_push_lea_inside();
    k.fs = NULL;
    check_verdicts("with no LC_FUNCTION_STARTS", &k, HR_CODE + 4, nostarts);
}

/* Two leas share one function, the second past an EVEX byte (0x62) between
 * them: an unreached candidate after a confirmed one in the same function
 * stays unreached. */
static void test_confirm_each_resumes_the_sweep_across_candidates(void) {
    struct hr_code k = { { 0x55, 0x48, 0x8d, 0, 0, 0, 0, 0, 0x62, 0x90, 0x90, 0x90, 0x48, 0x8d }, 20,
                         HR_ONE_FUNCTION, sizeof HR_ONE_FUNCTION, NULL, 0 };
    hr_plant(k.b, HR_CODE, 3, 0x05, 0, HR_BASE + 16);
    hr_plant(k.b, HR_CODE, 14, 0x05, 0, HR_BASE + 32);
    struct hr_verdicts s = { { { 0 } }, { 0 }, 0, 0 };
    int r = hr_confirm_each(&k, &s);
    static const int want[8] = { MHR_CONFIRMED, MHR_REFUTED, MHR_REFUTED, MHR_REFUTED,
                                 MHR_UNCONFIRMED, MHR_UNCONFIRMED, MHR_UNCONFIRMED, MHR_UNCONFIRMED };
    CHECK(r == MHR_CONFIRMED && s.n == 8, "resume: 8 candidates (got %d, %d)", r, s.n);
    for (int i = 0; i < 8 && i < s.n; i++)
        CHECK(s.v[i] == want[i], "resume: candidate %d has verdict %d, want %d", i, s.v[i], want[i]);
}

static void test_confirm_each_stops_when_asked(void) {
    struct hr_code k = hr_push_lea_inside();
    struct hr_verdicts s = { { { 0 } }, { 0 }, 0, 2 };
    int r = hr_confirm_each(&k, &s);
    CHECK(r == MHR_CONFIRMED && s.n == 2, "confirm each: stopped after 2 (got %d, %d)", r, s.n);
}

static void test_confirm_each_reports_an_image_it_cannot_scan(void) {
    struct hr_code k = hr_push_lea_inside();
    struct hr_verdicts s = { { { 0 } }, { 0 }, 0, 0 };
    uint8_t *buf = hr_code_image(&k);
    struct section_64 *sc =
        (struct section_64 *)(buf + sizeof(struct mach_header_64) + sizeof(struct segment_command_64));
    sc[1].size = HR_IMG_SIZE;                          /* __stubs runs past the image */
    int r = mhr_confirm_each(buf, HR_IMG_SIZE, HR_FIRST, HR_LAST, hr_verdict, &s);
    CHECK(r == MHR_UNSCANNABLE, "confirm each: an instruction section past the image (got %d)", r);
    free(buf);
}

/* ---- the one rule's code half ----
 * __plain holds one lea (plant_header_refs), at __plain + `at`, whose
 * disp32 names `target`; with MG_T_FUNCSTARTS in `opts`, __plain is a
 * function. */
static uint8_t *build_inside_ref(uint64_t target, uint32_t at, int opts, size_t *fsize) {
    uint32_t sect_off;
    uint8_t *buf = build_image(fsize, &sect_off, MG_T_PLAINSECT | opts);
    plant_header_refs(buf, *fsize, &at, 1);
    struct section_64 *pl = find_section_struct(buf, *fsize, "__plain");
    if (pl) hr_plant(buf + pl->offset, HR_PLAIN_VA, at + 2, 0x05, 0, target);
    return buf;
}

/* A grow moves the header's bytes away from its first content, so code that
 * names one of them names nothing after it. */
static void test_grow_refuses_code_that_names_the_inside_of_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_inside_ref(HR_BASE + 1, 0, MG_T_FUNCSTARTS, &fsize);
    check_grow_refuses_header_refs("code naming base + 1", buf, fsize,
        "ERROR: the code at 0x100001803 names 0x100000001, between the header at 0x100000000 and "
        "its first content at 0x100001000, which a grow moves apart; refusing to grow");
    buf = build_inside_ref(HR_BASE + 0xfff, 0, MG_T_FUNCSTARTS, &fsize);
    check_grow_refuses_header_refs("code naming base + F - 1", buf, fsize,
        "ERROR: the code at 0x100001803 names 0x100000fff, between the header");
}

static void test_grow_leaves_code_that_names_the_first_content(void) {
    size_t fsize;
    uint8_t *buf = build_inside_ref(HR_BASE + 0x1000, 0, MG_T_FUNCSTARTS, &fsize);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && refs_to(buf, fsize, HR_BASE + 0x1000) == 1,
          "inside: code naming the first content grows, and still names it (got %d)", r);
    free(buf);
}

/* Bytes in the header's range that decoding does not confirm as code: a
 * lookalike it refutes grows; a lea it cannot reach past an EVEX prefix,
 * and one with no LC_FUNCTION_STARTS to decode from, refuse. */
static void test_grow_decides_what_decoding_does_not_confirm_inside_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_inside_ref(HR_BASE + 16, 0, MG_T_FUNCSTARTS, &fsize);
    struct section_64 *pl = find_section_struct(buf, fsize, "__plain");
    if (pl) buf[pl->offset + 1] = 0xb8;                     /* movabs $imm64, %rax */
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "inside: a lookalike decoding refutes grows (got %d)", r);
    free(buf);

    buf = build_inside_ref(HR_BASE + 16, 4, MG_T_FUNCSTARTS, &fsize);
    pl = find_section_struct(buf, fsize, "__plain");
    if (pl) buf[pl->offset] = 0x62;                         /* EVEX: not decoded */
    check_grow_refuses_header_refs("a lea decoding cannot reach", buf, fsize,
        "ERROR: the code at 0x100001807 names 0x100000010, between the header at 0x100000000 and "
        "its first content at 0x100001000, which a grow moves apart; refusing to grow");

    buf = build_inside_ref(HR_BASE + 16, 0, 0, &fsize);
    check_grow_refuses_header_refs("a lea with no function starts to decode from", buf, fsize,
        "ERROR: the code at 0x100001803 names 0x100000010, between the header");
}

/* ---- the one rule's symbol and export halves ---- */
/* MG_T_SYMTAB's string table is the 8 bytes at 6720, or at `stroff`; the
 * byte after it is not part of it. */
static void check_grow_refuses_symbol(uint64_t value, uint32_t strx, uint32_t stroff,
                                      const char *needle) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    memcpy(buf + 6720, "\0_in\0\0xyz", 9);
    buf[fsize - 3] = 'q';
    ((struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB))->stroff = stroff;
    hsym(buf, fsize, 1)->n_value = value;
    hsym(buf, fsize, 1)->n_un.n_strx = strx;
    check_grow_refuses_header_refs("a symbol inside the header", buf, fsize, needle);
}

static void test_grow_refuses_a_symbol_inside_the_header(void) {
    check_grow_refuses_symbol(HR_BASE + 1, 1, 6720,
        "ERROR: symbol 1, \"_in\", names 0x100000001, between the header at 0x100000000 and its "
        "first content at 0x100001000, which a grow moves apart; refusing to grow");
    check_grow_refuses_symbol(HR_BASE + 0xfff, 1, 6720, "ERROR: symbol 1, \"_in\", names 0x100000fff");
    check_grow_refuses_symbol(HR_BASE + 16, 8, 6720, "ERROR: symbol 1, \"\", names 0x100000010");
    check_grow_refuses_symbol(HR_BASE + 16, 6, 6720, "ERROR: symbol 1, \"xy\", names 0x100000010");
    check_grow_refuses_symbol(HR_BASE + 16, 1, 8192 - 4, "ERROR: symbol 1, \"\", names 0x100000010");
}

/* A stab or an absolute symbol there is not an address a grow moves, and
 * one at the first content names content. */
static void test_grow_leaves_other_symbols_that_name_the_inside_of_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    hsym(buf, fsize, 1)->n_value = HR_BASE + 0x1000;
    hsym(buf, fsize, 2)->n_value = HR_BASE + 16;       /* N_BNSYM */
    hsym(buf, fsize, 3)->n_value = HR_BASE + 16;       /* N_ABS */
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && hsym(buf, fsize, 1)->n_value == HR_BASE + 0x1000 &&
          hsym(buf, fsize, 2)->n_value == HR_BASE + 16 && hsym(buf, fsize, 3)->n_value == HR_BASE + 16,
          "symbols: a stab and an absolute symbol inside the header, and one at its first "
          "content, grow unchanged (got %d)", r);
    free(buf);
}

/* MG_T_TRIE's node A, its address `a` in its two bytes, and `flags`. */
static uint8_t *build_export_at(uint64_t a, uint8_t flags, size_t *fsize) {
    uint32_t sect_off;
    uint8_t *buf = build_image(fsize, &sect_off, MG_T_TRIE);
    buf[TRIE_OFF + MG_TRIE_A_FLAGS] = flags;
    mu_encode_fixed(buf + TRIE_OFF + MG_TRIE_A_ADDR, a, 2);
    return buf;
}

static void test_grow_refuses_an_export_inside_the_header(void) {
    size_t fsize;
    uint8_t *buf = build_export_at(1, 0, &fsize);
    check_grow_refuses_header_refs("an export at offset 1", buf, fsize,
        "ERROR: an export names 0x100000001, between the header at 0x100000000 and its first "
        "content at 0x100001000, which a grow moves apart; refusing to grow");
    buf = build_export_at(0xfff, 0, &fsize);
    check_grow_refuses_header_refs("an export at offset F - 1", buf, fsize,
        "ERROR: an export names 0x100000fff, between the header");
}

/* MG_T_TRIE's trie, with node A absolute and valued base + 16: a value, so
 * the grow leaves it alone. */
static void test_grow_leaves_an_absolute_export_inside_the_header(void) {
    static const uint8_t trie[20] = {
        0x00, 0x02, 'A', 0x00, 8, 'B', 0x00, 16,
        0x06, 0x02, 0x90, 0x80, 0x80, 0x80, 0x10, 0x00,     /* A: absolute, 0x100000010 */
        0x02, 0x00, 0x00, 0x00                              /* B: 0 */
    };
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, MG_T_TRIE);
    memcpy(buf + TRIE_OFF, trie, sizeof trie);
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->export_size = sizeof trie;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "an absolute export valued base + 16 grows (got %d)", r);
    free(buf);
}

/* ---- a bind in the segment that maps the header ----
 * build_pointer_image with one bind (0), weak bind (1) or lazy bind (2) at
 * PT_LE + 16 * (1 + which): ordinal 1, "_s", a pointer, in segment `seg` at
 * offset 0x10. */
static uint8_t *build_bind_image(int which, uint8_t seg, size_t *fsize) {
    uint8_t *buf = build_pointer_image(fsize, 0);
    const uint8_t ops[10] = { 0x11, 0x40, '_', 's', 0, 0x51, (uint8_t)(0x70 | seg), 0x10, 0x90,
                              0x00 };
    struct dyld_info_command *di = (struct dyld_info_command *)find_lc(buf, *fsize, LC_DYLD_INFO_ONLY);
    uint32_t at = PT_LE + 16 * (1 + which);
    memcpy(buf + at, ops, sizeof ops);
    if (which == 0) { di->bind_off = at; di->bind_size = sizeof ops; }
    if (which == 1) { di->weak_bind_off = at; di->weak_bind_size = sizeof ops; }
    if (which == 2) { di->lazy_bind_off = at; di->lazy_bind_size = sizeof ops; }
    return buf;
}

static void test_grow_refuses_a_bind_in_the_segment_that_maps_the_header(void) {
    static const char *const kind[3] = { "bind", "weak bind", "lazy bind" };
    for (int i = 0; i < 3; i++) {
        size_t fsize;
        char what[64], needle[160];
        uint8_t *buf = build_bind_image(i, 1, &fsize);
        snprintf(what, sizeof what, "a %s in __TEXT", kind[i]);
        snprintf(needle, sizeof needle, "ERROR: the %s at __TEXT+0x10 lies in the segment that maps "
                 "the header; refusing to grow", kind[i]);
        check_grow_refuses_header_refs(what, buf, fsize, needle);
    }
}

static void test_grow_refuses_binds_it_cannot_read(void) {
    size_t fsize;
    uint8_t *buf = build_bind_image(2, 4, &fsize);
    check_grow_refuses_header_refs("a lazy bind in segment 4", buf, fsize,
        "ERROR: the lazy bind opcodes name segment 4, and there are 4; refusing to grow");
    buf = build_bind_image(0, 1, &fsize);
    buf[PT_LE + 16 + 9] = 0x7f;                        /* then segment 15, offset 0; DO_BIND */
    buf[PT_LE + 16 + 10] = 0x00;
    buf[PT_LE + 16 + 11] = 0x90;
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->bind_size = 13;
    check_grow_refuses_header_refs("the first of two binds it cannot move", buf, fsize,
        "ERROR: the bind at __TEXT+0x10 lies in the segment that maps the header; refusing to grow");
    buf = build_bind_image(1, 2, &fsize);
    buf[PT_LE + 32 + 8] = 0xe0;                        /* no such opcode */
    check_grow_refuses_header_refs("weak bind opcodes that do not decode", buf, fsize,
        "ERROR: the weak bind opcodes do not decode; refusing to grow");
    buf = build_bind_image(0, 2, &fsize);
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->bind_size = 1000;
    check_grow_refuses_header_refs("bind opcodes past the image", buf, fsize,
        "ERROR: the bind opcodes (1000 bytes at offset 12304) run past the end of the 12544-byte "
        "image; refusing to grow");
}

/* __DATA, and __PAGEZERO, which starts at file offset 0 but maps none of
 * the file, are not the segment that maps the header. */
static void test_grow_accepts_binds_outside_the_header_segment(void) {
    for (int i = 0; i < 3; i++) {
        size_t fsize;
        uint8_t *buf = build_bind_image(i, 2, &fsize);
        int r = mg_grow_header(&buf, &fsize, 0x1000);
        CHECK(r == 0, "binds: stream %d's bind in __DATA grows (got %d)", i, r);
        free(buf);
    }
    size_t fsize;
    uint8_t *buf = build_bind_image(0, 0, &fsize);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "binds: a bind in __PAGEZERO is not in the header's segment (got %d)", r);
    free(buf);
}

/* ---- a dylib to raise ----
 * build_dylib's MH_DYLIB, x86_64, linked at base 0 (as every 10.9 system
 * dylib is; `base` moves it). F, its first content, is file and vm offset
 * 0x1000. Segment indexes: __TEXT 0, __DATA 1, __LINKEDIT 2.
 *   __TEXT      file [0, 0x2000)
 *     __text          0x1000: f1: lea base(%rip), %rax; ret.  f2 (0x1010): push; ret
 *     __stub_helper   0x1100: nops
 *     __gcc_except_tab 0x1180 (DY_UNWIND): f2's LSDA
 *     __unwind_info   0x1800 (DY_UNWIND): f1 and f2, f2 with an LSDA
 *   __DATA      file [0x2000, 0x3000), vm to 0x4000
 *     __data          0x2000: dy_ptrs, three rebased pointers
 *     __mod_init_func 0x2030: f2
 *     __la_symbol_ptr 0x2038: __stub_helper
 *     __got           0x2040: bound to _x
 *     __bss           0x3000, zero-fill
 *   __LINKEDIT  file [0x3000, DY_FSIZE), vm 0x4000
 *     rebase 0x3000, bind 0x3010, export trie 0x3040 (_f1, _f2, _d),
 *     function starts 0x3080 (f1, f2), data in code 0x3090 (DY_DIC),
 *     symbols 0x30a0, strings 0x3200
 *   __ZERO      (DY_ZEROSEG) vm [0x6000, 0x7000), no file data; with
 *               DY_ZEROFAR, [0x7000, 0x8000), two pages past __LINKEDIT */
#define DY_F      0x1000u
#define DY_FSIZE  0x3300u
#define DY_UNWIND 1
#define DY_DIC    2
#define DY_ROUTINES 4
#define DY_SPLIT  8
#define DY_ZEROSEG 16    /* a zero-fill segment, __ZERO, at vm 0x6000: file offset 0, no file data */
#define DY_ZEROFAR 128   /* __ZERO at 0x7000 */
#define DY_STABS  32     /* dy_stabs, as symbols 5 to 19 */
#define DY_INITOFF 64    /* __TEXT,__init_offsets at 0x1120: f2 */
static const uint64_t dy_ptrs[3] = { 0, 0x1010, 0x2020 };   /* the header, f2, _d */

static struct section_64 *dy_sect(struct section_64 *s, const char *seg, const char *name,
                                  uint64_t addr, uint64_t size, uint32_t off, uint32_t flags) {
    strncpy(s->segname, seg, sizeof s->segname);
    strncpy(s->sectname, name, sizeof s->sectname);
    s->addr = addr;
    s->size = size;
    s->offset = off;
    s->flags = flags;
    return s + 1;
}

static uint8_t *dy_lc(uint8_t **lc, struct mach_header_64 *h, uint32_t cmd, uint32_t size) {
    struct load_command *l = (struct load_command *)*lc;
    uint8_t *at = *lc;
    l->cmd = cmd;
    l->cmdsize = size;
    *lc += size;
    h->ncmds++;
    h->sizeofcmds += size;
    return at;
}

/* A debugging image's stabs, as ld64 writes them for a -g build: `at` is an
 * offset from the base when `moves` (the value is an address), else the
 * value itself. build_dylib_at's string table holds "x.h" at 33 and "a.o"
 * at 37 with them. */
static const struct { uint32_t strx; uint8_t type, sect; uint64_t at; int moves; } dy_stabs[15] = {
    { 33, N_SO, NO_SECT, 0x5000, 0 },     { 37, N_OSO, 3, 0x6ab898db, 0 },
    { 0, N_BNSYM, 1, 0x1010, 1 },         { 23, N_FUN, 1, 0x1010, 1 },
    { 0, N_FUN, NO_SECT, 2, 0 },          { 0, N_ENSYM, 1, 2, 0 },
    { 27, N_GSYM, NO_SECT, 0, 0 },        { 27, N_STSYM, 3, 0x2020, 1 },
    { 0, N_LCSYM, 7, 0x3000, 1 },         { 0, N_SLINE, 1, 0x1011, 1 },
    { 33, N_SOL, 1, 0x1010, 1 },          { 0, N_SO, 1, 0, 0 },
    { 0, N_OPT, NO_SECT, 0, 0 },          { 0, N_OLEVEL, NO_SECT, 2, 0 },
    { 37, N_AST, NO_SECT, 0, 0 },
};

static uint8_t *build_dylib_at(uint64_t base, size_t *fsize, int opts) {
    static const uint8_t rebase[16] = { 0x11, 0x21, 0x00, 0x53, 0x21, 0x30, 0x52, 0x00 };
    static const uint8_t bind[16] = { 0x11, 0x40, '_', 'x', 0, 0x51, 0x71, 0x40, 0x90, 0x00 };
    static const uint8_t trie[31] = {
        0x00, 0x03, '_', 'f', '1', 0, 16, '_', 'f', '2', 0, 21, '_', 'd', 0, 26,
        0x03, 0x00, 0x80, 0x20, 0x00,      /* _f1: 0x1000 */
        0x03, 0x00, 0x90, 0x20, 0x00,      /* _f2: 0x1010 */
        0x03, 0x00, 0xa0, 0x40, 0x00 };    /* _d:  0x2020 */
    static const uint8_t starts[8] = { 0x80, 0x20, 0x10, 0x00 };
    static const uint8_t dic[8] = { 0x20, 0x10, 0, 0, 0x08, 0x00, 0x01, 0x00 };  /* 0x1020, 8 */
    static const char strs[] = "\0__mh_dylib_header\0_f1\0_f2\0_d\0_x";
    uint8_t *buf = (uint8_t *)calloc(1, DY_FSIZE);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    uint8_t *lc = (uint8_t *)(h + 1);
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_X86_64;
    h->cpusubtype = CPU_SUBTYPE_X86_64_ALL;
    h->filetype = MH_DYLIB;
    h->flags = MH_DYLDLINK | MH_TWOLEVEL | MH_NOUNDEFS;

    int ntext = 2 + 2 * !!(opts & DY_UNWIND) + !!(opts & DY_INITOFF);
    struct segment_command_64 *tx = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
        sizeof *tx + ntext * sizeof(struct section_64));
    strcpy(tx->segname, "__TEXT");
    tx->vmaddr = base;
    tx->vmsize = tx->filesize = 0x2000;
    tx->maxprot = tx->initprot = VM_PROT_READ | VM_PROT_EXECUTE;
    tx->nsects = ntext;
    struct section_64 *s = (struct section_64 *)(tx + 1);
    s = dy_sect(s, "__TEXT", "__text", base + 0x1000, 0x100, 0x1000,
                S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
    s = dy_sect(s, "__TEXT", "__stub_helper", base + 0x1100, 0x10, 0x1100,
                S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS);
    if (opts & DY_UNWIND) {
        s = dy_sect(s, "__TEXT", "__gcc_except_tab", base + 0x1180, 0x10, 0x1180, 0);
        s = dy_sect(s, "__TEXT", "__unwind_info", base + 0x1800, 0x60, 0x1800, 0);
    }
    if (opts & DY_INITOFF)
        s = dy_sect(s, "__TEXT", "__init_offsets", base + 0x1120, 4, 0x1120, S_INIT_FUNC_OFFSETS);

    struct segment_command_64 *da = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
        sizeof *da + 5 * sizeof(struct section_64));
    strcpy(da->segname, "__DATA");
    da->vmaddr = base + 0x2000;
    da->vmsize = 0x2000;
    da->fileoff = 0x2000;
    da->filesize = 0x1000;
    da->maxprot = da->initprot = VM_PROT_READ | VM_PROT_WRITE;
    da->nsects = 5;
    s = (struct section_64 *)(da + 1);
    s = dy_sect(s, "__DATA", "__data", base + 0x2000, 0x30, 0x2000, 0);
    s = dy_sect(s, "__DATA", "__mod_init_func", base + 0x2030, 8, 0x2030, S_MOD_INIT_FUNC_POINTERS);
    s = dy_sect(s, "__DATA", "__la_symbol_ptr", base + 0x2038, 8, 0x2038, S_LAZY_SYMBOL_POINTERS);
    s = dy_sect(s, "__DATA", "__got", base + 0x2040, 8, 0x2040, S_NON_LAZY_SYMBOL_POINTERS);
    s = dy_sect(s, "__DATA", "__bss", base + 0x3000, 0x100, 0, S_ZEROFILL);

    struct segment_command_64 *le = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
        sizeof *le);
    strcpy(le->segname, "__LINKEDIT");
    le->vmaddr = base + 0x4000;
    le->vmsize = 0x1000;
    le->fileoff = 0x3000;
    le->filesize = DY_FSIZE - 0x3000;
    le->maxprot = le->initprot = VM_PROT_READ;

    if (opts & DY_ZEROSEG) {
        struct segment_command_64 *z = (struct segment_command_64 *)dy_lc(&lc, h, LC_SEGMENT_64,
            sizeof *z + sizeof(struct section_64));
        strcpy(z->segname, "__ZERO");
        z->vmaddr = base + ((opts & DY_ZEROFAR) ? 0x7000 : 0x6000);
        z->vmsize = 0x1000;
        z->maxprot = z->initprot = VM_PROT_READ | VM_PROT_WRITE;
        z->nsects = 1;
        dy_sect((struct section_64 *)(z + 1), "__ZERO", "__zero", z->vmaddr, 0x1000, 0,
                S_ZEROFILL);
    }
    struct dylib_command *id = (struct dylib_command *)dy_lc(&lc, h, LC_ID_DYLIB, 48);
    id->dylib.name.offset = sizeof *id;
    strcpy((char *)(id + 1), "@rpath/libdy.dylib");
    struct dylib_command *sys = (struct dylib_command *)dy_lc(&lc, h, LC_LOAD_DYLIB, 56);
    sys->dylib.name.offset = sizeof *sys;
    strcpy((char *)(sys + 1), "/usr/lib/libSystem.B.dylib");

    struct dyld_info_command *di = (struct dyld_info_command *)dy_lc(&lc, h, LC_DYLD_INFO_ONLY,
                                                                    sizeof *di);
    di->rebase_off = 0x3000;
    di->rebase_size = 8;
    di->bind_off = 0x3010;
    di->bind_size = 16;
    di->export_off = 0x3040;
    di->export_size = sizeof trie;

    struct symtab_command *st = (struct symtab_command *)dy_lc(&lc, h, LC_SYMTAB, sizeof *st);
    st->symoff = 0x30a0;
    st->nsyms = 5;
    st->stroff = 0x3200;
    st->strsize = sizeof strs;
    struct dysymtab_command *ds = (struct dysymtab_command *)dy_lc(&lc, h, LC_DYSYMTAB, sizeof *ds);
    ds->nlocalsym = 1;
    ds->iextdefsym = 1;
    ds->nextdefsym = 3;
    ds->iundefsym = 4;
    ds->nundefsym = 1;

    struct uuid_command *u = (struct uuid_command *)dy_lc(&lc, h, LC_UUID, sizeof *u);
    for (int i = 0; i < 16; i++) u->uuid[i] = (uint8_t)(0x10 + i);

    struct linkedit_data_command *fs = (struct linkedit_data_command *)dy_lc(&lc, h,
        LC_FUNCTION_STARTS, sizeof *fs);
    fs->dataoff = 0x3080;
    fs->datasize = sizeof starts;
    if (opts & DY_DIC) {
        struct linkedit_data_command *dc = (struct linkedit_data_command *)dy_lc(&lc, h,
            LC_DATA_IN_CODE, sizeof *dc);
        dc->dataoff = 0x3090;
        dc->datasize = sizeof dic;
        memcpy(buf + 0x3090, dic, sizeof dic);
    }
    if (opts & DY_SPLIT) {
        struct linkedit_data_command *sp = (struct linkedit_data_command *)dy_lc(&lc, h,
            LC_SEGMENT_SPLIT_INFO, sizeof *sp);
        sp->dataoff = 0x3098;
        sp->datasize = 8;
        memset(buf + 0x3098, 0x5a, 8);
    }
    if (opts & DY_ROUTINES) {
        struct routines_command_64 *rt = (struct routines_command_64 *)dy_lc(&lc, h,
            LC_ROUTINES_64, sizeof *rt);
        rt->init_address = base + 0x1010;
    }

    /* f1: lea base(%rip), %rax; ret.  f2: push %rbp; ret. */
    memset(buf + 0x1000, 0x90, 0x110);
    buf[0x1000] = 0x48; buf[0x1001] = 0x8d; buf[0x1002] = 0x05;
    int32_t disp = (int32_t)(int64_t)(base - (base + 0x1007));
    memcpy(buf + 0x1003, &disp, sizeof disp);
    buf[0x1007] = 0xc3;
    buf[0x1010] = 0x55; buf[0x1011] = 0xc3;
    if (opts & DY_INITOFF) { uint32_t f2 = 0x1010; memcpy(buf + 0x1120, &f2, sizeof f2); }
    if (opts & DY_UNWIND) {
        uint32_t *uw = (uint32_t *)(buf + 0x1800);
        uw[0] = 1; uw[3] = 28; uw[4] = 1; uw[5] = 32; uw[6] = 2;
        uw[7] = 0x2040;                             /* personality: the __got slot */
        uw[8] = 0x1000; uw[9] = 0x48; uw[10] = 56;  /* f1; its page; LSDA from 56 */
        uw[11] = 0x1100; uw[12] = 0; uw[13] = 64;   /* the sentinel: the end of f2 */
        uw[14] = 0x1010; uw[15] = 0x1180;           /* f2's LSDA, in __gcc_except_tab */
        uw[18] = 3; ((uint16_t *)(buf + 0x1800 + 0x48))[2] = 8;
        ((uint16_t *)(buf + 0x1800 + 0x48))[3] = 2;
        uw[20] = 0x00000000u | (1u << 24); uw[21] = 0x00000010u | (1u << 24);
    }

    uint64_t ptrs[3];
    for (int i = 0; i < 3; i++) ptrs[i] = base + dy_ptrs[i];
    memcpy(buf + 0x2000, ptrs, sizeof ptrs);
    uint64_t init = base + 0x1010, lazy = base + 0x1100;
    memcpy(buf + 0x2030, &init, 8);
    memcpy(buf + 0x2038, &lazy, 8);

    memcpy(buf + 0x3000, rebase, sizeof rebase);
    memcpy(buf + 0x3010, bind, sizeof bind);
    memcpy(buf + 0x3040, trie, sizeof trie);
    memcpy(buf + 0x3080, starts, sizeof starts);
    struct nlist_64 *nl = (struct nlist_64 *)(buf + 0x30a0);
    static const struct { uint32_t strx; uint8_t type, sect; uint64_t value; } syms[5] = {
        { 1, N_SECT | N_PEXT, 1, 0 }, { 19, N_SECT | N_EXT, 1, 0x1000 },
        { 23, N_SECT | N_EXT, 1, 0x1010 }, { 27, N_SECT | N_EXT, 0, 0x2020 },
        { 30, N_UNDF | N_EXT, 0, 0 } };
    for (int i = 0; i < 5; i++) {
        nl[i].n_un.n_strx = syms[i].strx;
        nl[i].n_type = syms[i].type;
        nl[i].n_sect = i == 3 ? (uint8_t)(ntext + 1) : syms[i].sect;
        nl[i].n_value = syms[i].type == (N_UNDF | N_EXT) ? 0 : base + syms[i].value;
    }
    memcpy(buf + 0x3200, strs, sizeof strs);
    if (opts & DY_STABS) {
        memcpy(buf + 0x3200 + sizeof strs, "x.h\0a.o", 8);
        st->strsize += 8;
        st->nsyms = 20;
        for (int i = 0; i < 15; i++) {
            nl[5 + i].n_un.n_strx = dy_stabs[i].strx;
            nl[5 + i].n_type = dy_stabs[i].type;
            nl[5 + i].n_sect = dy_stabs[i].sect;
            nl[5 + i].n_value = dy_stabs[i].moves ? base + dy_stabs[i].at : dy_stabs[i].at;
        }
    }
    *fsize = DY_FSIZE;
    return buf;
}

static uint8_t *build_dylib(size_t *fsize, int opts) { return build_dylib_at(0, fsize, opts); }

/* The dylib's `cmd` command, or NULL. */
static uint8_t *dy_find(uint8_t *buf, uint32_t cmd) { return (uint8_t *)find_lc(buf, DY_FSIZE, cmd); }
static struct section_64 *dy_section(uint8_t *buf, const char *seg, const char *name) {
    mi_image im;
    return mi_wrap(buf, DY_FSIZE, &im) == 0 ? mi_find_section(&im, seg, name) : NULL;
}

/* Each way a raise refuses before it changes anything: `poke` breaks
 * build_dylib's image, and the refusal must say `why`. */
typedef void (*dy_poke)(uint8_t *buf);
static void dy_no_info(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_DYLD_INFO_ONLY))->cmd = LC_SOURCE_VERSION; }
static void dy_unixthread(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_UUID))->cmd = LC_UNIXTHREAD; }
static void dy_thread(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_UUID))->cmd = LC_THREAD; }
static void dy_encrypted(uint8_t *buf) {
    struct encryption_info_command_64 *e = (struct encryption_info_command_64 *)dy_find(buf, LC_UUID);
    e->cmd = LC_ENCRYPTION_INFO_64;
    e->cryptid = 1;
}
static void dy_short_crypt(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_ENCRYPTION_INFO; }
static void dy_short_routines(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_ROUTINES_64; }
static void dy_protected(uint8_t *buf) { seg_named(buf, DY_FSIZE, "__DATA")->flags |= SG_PROTECTED_VERSION_1; }
static void dy_misplaced(uint8_t *buf) { dy_section(buf, "__TEXT", "__stub_helper")->addr += 0x10; }
static void dy_below(uint8_t *buf) {
    dy_section(buf, "__DATA", "__bss")->addr = seg_named(buf, DY_FSIZE, "__TEXT")->vmaddr + 0xfff;
}
static void dy_early(uint8_t *buf) { seg_named(buf, DY_FSIZE, "__DATA")->fileoff = 0xfff; }
static void dy_short_symtab(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_SYMTAB; }
static void dy_short_dysymtab(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_DYSYMTAB; }
static struct dysymtab_command *dy_dysymtab(uint8_t *buf) { return (struct dysymtab_command *)dy_find(buf, LC_DYSYMTAB); }
static void dy_toc(uint8_t *buf) { dy_dysymtab(buf)->ntoc = 1; }
static void dy_modtab(uint8_t *buf) { dy_dysymtab(buf)->nmodtab = 1; }
static void dy_extrel(uint8_t *buf) { dy_dysymtab(buf)->nextrel = 1; }
static void dy_locrel(uint8_t *buf) { dy_dysymtab(buf)->nlocrel = 1; }
/* The real LC_DYSYMTAB's one local relocation, then an all-zero second
 * LC_DYSYMTAB appended into the header's own pad (well short of DY_F): an
 * assignment instead of an accumulation would let the second, all-zero
 * command's read reset the first's count back to 0. */
static void dy_second_dysymtab(uint8_t *buf) {
    dy_dysymtab(buf)->nlocrel = 1;
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct load_command *l = (struct load_command *)(buf + sizeof *h + h->sizeofcmds);
    l->cmd = LC_DYSYMTAB;
    l->cmdsize = sizeof(struct dysymtab_command);
    h->ncmds++;
    h->sizeofcmds += (uint32_t)sizeof(struct dysymtab_command);
}
static void dy_no_info_locrel(uint8_t *buf) { dy_no_info(buf); dy_locrel(buf); }
static void dy_overaligned(uint8_t *buf) { dy_section(buf, "__DATA", "__data")->align = 13; }
static void dy_not_x86_64(uint8_t *buf) { ((struct mach_header_64 *)buf)->cputype = CPU_TYPE_POWERPC64; }
static void dy_chained_fixups(uint8_t *buf) { ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_DYLD_CHAINED_FIXUPS; }
/* __LINKEDIT, at fileoff 0 too: a second segment mg_raise_header_seg_cb's
 * identity check must NOT mistake for the header (__TEXT already is it). */
static void dy_second_header_seg(uint8_t *buf) { seg_named(buf, DY_FSIZE, "__LINKEDIT")->fileoff = 0; }
static const struct { const char *what; dy_poke poke; const char *why; } dy_unraisable[] = {
    { "no LC_DYLD_INFO", dy_no_info,
      "ERROR: a dylib or bundle with no LC_DYLD_INFO[_ONLY]: only its rebase opcodes list every "
      "pointer a raise moves; refusing to grow" },
    { "LC_UNIXTHREAD", dy_unixthread,
      "ERROR: a dylib or bundle with a thread command (0x5), whose register state a raise does "
      "not move; refusing to grow" },
    { "LC_THREAD", dy_thread, "ERROR: a dylib or bundle with a thread command (0x4)" },
    { "an encrypted image", dy_encrypted,
      "ERROR: the image is encrypted (cryptid 1), and a raise would move its encrypted pages; "
      "refusing to grow" },
    { "a short encryption command", dy_short_crypt,
      "ERROR: an encryption command is 16 bytes, too short to hold cryptid; refusing to grow" },
    { "a short LC_ROUTINES_64", dy_short_routines,
      "ERROR: LC_ROUTINES_64 is 16 bytes, too short to hold init_address; refusing to grow" },
    { "a protected segment", dy_protected,
      "ERROR: segment __DATA is protected (SG_PROTECTED_VERSION_1), and a raise would move its "
      "encrypted pages; refusing to grow" },
    { "a __TEXT section whose address and offset disagree", dy_misplaced,
      "ERROR: section __TEXT,__stub_helper lies 0x1110 past the image base in memory and 0x1100 "
      "in the file; refusing to grow" },
    { "a section below the first content", dy_below,
      "ERROR: section __DATA,__bss lies at 0xfff, below the first content at 0x1000; refusing "
      "to grow" },
    { "a segment whose file data starts before the first content", dy_early,
      "ERROR: segment __DATA's file data starts at 4095, before the first content at 4096; "
      "refusing to grow" },
    { "a short LC_DYSYMTAB", dy_short_dysymtab,
      "ERROR: LC_DYSYMTAB is 16 bytes, too short to hold its tables' counts; refusing to grow" },
    { "a short LC_SYMTAB", dy_short_symtab,
      "ERROR: LC_SYMTAB is 16 bytes, too short to hold its symbol and string tables' offsets "
      "and sizes; refusing to grow" },
    { "a table of contents", dy_toc,
      "ERROR: LC_DYSYMTAB lists 1 table-of-contents entries, 0 modules, 0 external and 0 local "
      "relocations beside LC_DYLD_INFO, whose addresses a raise does not move; refusing to grow" },
    { "a module table", dy_modtab, "ERROR: LC_DYSYMTAB lists 0 table-of-contents entries, 1 modules" },
    { "external relocations", dy_extrel, "0 modules, 1 external and 0 local relocations" },
    { "local relocations", dy_locrel, "0 external and 1 local relocations" },
    { "local relocations and no LC_DYLD_INFO", dy_no_info_locrel,
      "ERROR: a dylib or bundle with no LC_DYLD_INFO[_ONLY]: only its rebase opcodes" },
    { "a section aligned past a page", dy_overaligned,
      "ERROR: section __DATA,__data is aligned to 2^13 bytes, more than the page a raise moves it "
      "by; refusing to grow" },
    { "a dylib that is not x86_64", dy_not_x86_64,
      "ERROR: only an x86_64 dylib or bundle can be grown (cputype=0x1000012): its code is "
      "decoded to find what addresses its header" },
    { "LC_DYLD_CHAINED_FIXUPS", dy_chained_fixups,
      "ERROR: LC_DYLD_CHAINED_FIXUPS: chained pointers encode offsets from the image base, which "
      "growing moves; convert them first (`fixups set classic` in an edit script)." },
    { "a second segment at fileoff 0", dy_second_header_seg,
      "ERROR: segment __LINKEDIT's file data starts at 0, before the first content at 4096; "
      "refusing to grow" },
    { "a second, all-zero LC_DYSYMTAB", dy_second_dysymtab,
      "ERROR: LC_DYSYMTAB lists 0 table-of-contents entries, 0 modules, 0 external and 1 local "
      "relocations beside LC_DYLD_INFO, whose addresses a raise does not move; refusing to grow" },
};

/* Like check_grow_refuses_header_refs, but also insists stderr holds exactly
 * one ERROR, catching a refusal that prints its reason without stopping the
 * walk (mi_each_lc's callback returning 0 where it should return 1). */
static void check_grow_refuses_raise(const char *what, uint8_t *buf, size_t fsize,
                                     const char *needle) {
    size_t fsize0 = fsize;
    uint8_t *before = (uint8_t *)malloc(fsize0);
    memcpy(before, buf, fsize0);
    int r;
    char *err = stderr_during(mg_grow_header, &buf, &fsize, 0x1000, &r);
    int errors = 0;
    for (const char *p = err; (p = strstr(p, "ERROR")) != NULL; p++) errors++;
    CHECK(r == -1 && strstr(err, needle) != NULL,
          "mg_grow_header REFUSES %s, saying '%s' (got %d):\n%s", what, needle, r, err);
    CHECK(errors == 1, "%s: mg_grow_header prints one ERROR, not %d:\n%s", what, errors, err);
    CHECK(fsize == fsize0 && memcmp(before, buf, fsize0) == 0, "%s: nothing changed", what);
    free(err);
    free(before);
    free(buf);
}

/* Each image carries split info (DY_SPLIT), which a raise drops once it
 * will go ahead: so every refusal is also shown to leave it in place. */
static void test_grow_refuses_what_it_cannot_raise(void) {
    for (size_t i = 0; i < sizeof dy_unraisable / sizeof dy_unraisable[0]; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib(&fsize, DY_SPLIT);
        dy_unraisable[i].poke(buf);
        check_grow_refuses_raise(dy_unraisable[i].what, buf, fsize, dy_unraisable[i].why);
    }
    size_t fsize;
    uint8_t *buf = build_dylib_at(0x10000000, &fsize, DY_SPLIT);
    dy_below(buf);
    check_grow_refuses_raise("a section below the first content, above base 0", buf, fsize,
        "ERROR: section __DATA,__bss lies at 0x10000fff, below the first content at 0x10001000; "
        "refusing to grow");
}

/* An unencrypted image's encryption command, an LC_ROUTINES_64 long enough
 * to read, and a zero-fill segment at file offset 0 are no reason to refuse,
 * at base 0 or above it. */
static void test_grow_raises_past_what_it_can_vouch_for(void) {
    static const uint32_t filetype[3] = { MH_DYLIB, MH_BUNDLE, MH_DYLIB };
    static const uint64_t base[3] = { 0, 0, 0x10000000 };
    for (int i = 0; i < 3; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib_at(base[i], &fsize, DY_ROUTINES | DY_ZEROSEG);
        struct encryption_info_command_64 *e =
            (struct encryption_info_command_64 *)dy_find(buf, LC_UUID);
        ((struct mach_header_64 *)buf)->filetype = filetype[i];
        e->cmd = LC_ENCRYPTION_INFO_64;
        e->cryptoff = e->cryptsize = e->cryptid = 0;
        dy_section(buf, "__DATA", "__data")->align = 12;
        int r = mg_grow_header(&buf, &fsize, 0x1000);
        CHECK(r == 0 && fsize == DY_FSIZE + 0x1000, "raise: filetype %u at base %#llx grows "
              "(got %d, %zu bytes)", filetype[i], (unsigned long long)base[i], r, fsize);
        free(buf);
    }
}

/* ---- what a raise moves ----
 * Each test raises build_dylib_at(DY_RAISED_AT, ...) by one page and reads
 * the result back. */
#define DY_RAISED_AT 0x10000000ull
#define DY_ALL (DY_UNWIND | DY_DIC | DY_ROUTINES | DY_ZEROSEG)
static uint8_t *raised_dylib(size_t *fsize, int opts, uint32_t grow_req) {
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, fsize, opts);
    int r = mg_grow_header(&buf, fsize, grow_req);
    CHECK(r == 0, "raise: the grow succeeds (got %d)", r);
    if (r == 0) return buf;
    free(buf);
    return NULL;
}
static struct nlist_64 *dy_syms(uint8_t *buf, size_t fsize) {
    struct symtab_command *st = (struct symtab_command *)find_lc(buf, fsize, LC_SYMTAB);
    return (struct nlist_64 *)(buf + st->symoff);
}

static void test_raise_moves_the_segments_and_sections(void) {
    static const struct { const char *seg; uint64_t vmaddr, vmsize, fileoff, filesize; } segs[4] = {
        { "__TEXT", 0, 0x3000, 0, 0x3000 },
        { "__DATA", 0x3000, 0x2000, 0x3000, 0x1000 },
        { "__LINKEDIT", 0x5000, 0x1000, 0x4000, DY_FSIZE - 0x3000 },
        { "__ZERO", 0x7000, 0x1000, 0, 0 },
    };
    static const struct { const char *seg, *sect; uint64_t addr; uint32_t offset; } sects[4] = {
        { "__TEXT", "__text", 0x2000, 0x2000 }, { "__TEXT", "__unwind_info", 0x2800, 0x2800 },
        { "__DATA", "__la_symbol_ptr", 0x3038, 0x3038 }, { "__DATA", "__bss", 0x4000, 0 },
    };
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    for (int i = 0; i < 4; i++) {
        struct segment_command_64 *s = seg_named(buf, fsize, segs[i].seg);
        CHECK(s && s->vmaddr == DY_RAISED_AT + segs[i].vmaddr && s->vmsize == segs[i].vmsize &&
              s->fileoff == segs[i].fileoff && s->filesize == segs[i].filesize,
              "raise: %s is vm %#llx+%#llx, file %#llx+%#llx after it", segs[i].seg,
              s ? (unsigned long long)s->vmaddr : 0, s ? (unsigned long long)s->vmsize : 0,
              s ? (unsigned long long)s->fileoff : 0, s ? (unsigned long long)s->filesize : 0);
    }
    for (int i = 0; i < 4; i++) {
        mi_image im;
        struct section_64 *s = mi_wrap(buf, fsize, &im) == 0 ?
            mi_find_section(&im, sects[i].seg, sects[i].sect) : NULL;
        CHECK(s && s->addr == DY_RAISED_AT + sects[i].addr && s->offset == sects[i].offset,
              "raise: %s,%s is at %#llx, file %u after it", sects[i].seg, sects[i].sect,
              s ? (unsigned long long)s->addr : 0, s ? s->offset : 0);
    }
    struct routines_command_64 *rt = (struct routines_command_64 *)find_lc(buf, fsize, LC_ROUTINES_64);
    CHECK(rt && rt->init_address == DY_RAISED_AT + 0x2010,
          "raise: LC_ROUTINES_64's initializer is f2, raised (%#llx)",
          rt ? (unsigned long long)rt->init_address : 0);
    CHECK(buf[0x2010] == 0x55 && buf[0x2000] == 0x48, "raise: the code is in the file a page on");
    free(buf);
}

/* A pointer to the header stays; every other one follows the content. */
static void test_raise_moves_the_pointers_that_name_content(void) {
    static const uint64_t want[5] = { 0, 0x2010, 0x3020, 0x2010, 0x2100 };
    static const uint32_t at[5] = { 0x3000, 0x3008, 0x3010, 0x3030, 0x3038 };
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    for (int i = 0; i < 5; i++) {
        uint64_t v;
        memcpy(&v, buf + at[i], sizeof v);
        CHECK(v == DY_RAISED_AT + want[i], "raise: the pointer at file %#x holds %#llx, want %#llx",
              at[i], (unsigned long long)v, (unsigned long long)(DY_RAISED_AT + want[i]));
    }
    free(buf);
}

/* __mh_dylib_header names the header, and stays; the defined symbols
 * follow the content; the undefined one is not an address. */
static void test_raise_moves_the_symbols_that_name_content(void) {
    static const uint64_t want[5] = { DY_RAISED_AT, DY_RAISED_AT + 0x2000, DY_RAISED_AT + 0x2010,
                                      DY_RAISED_AT + 0x3020, 0 };
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    struct nlist_64 *nl = dy_syms(buf, fsize);
    for (int i = 0; i < 5; i++)
        CHECK(nl[i].n_value == want[i], "raise: symbol %d is %#llx, want %#llx", i,
              (unsigned long long)nl[i].n_value, (unsigned long long)want[i]);
    free(buf);
}

/* What is measured from the base gains the grow, as on the executable
 * route: the export trie, the leading function start, data in code and
 * compact unwind. */
static void test_raise_moves_what_is_measured_from_the_base(void) {
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    uint32_t toff = 0, tsize = 0;
    uint64_t a[3] = { 0, 0, 0 }, d0 = 0;
    static const uint32_t leaf[3] = { 16, 21, 26 };
    static const uint64_t want[3] = { 0x2000, 0x2010, 0x3020 };
    mg_find_trie(buf, fsize, &toff, &tsize);
    for (int i = 0; i < 3; i++) {
        mu_decode(buf + toff + leaf[i] + 2, buf + toff + tsize, &a[i]);
        CHECK(a[i] == want[i], "raise: export %d is %#llx, want %#llx", i,
              (unsigned long long)a[i], (unsigned long long)want[i]);
    }
    struct linkedit_data_command *fs =
        (struct linkedit_data_command *)find_lc(buf, fsize, LC_FUNCTION_STARTS);
    mu_decode(buf + fs->dataoff, buf + fs->dataoff + fs->datasize, &d0);
    CHECK(d0 == 0x2000, "raise: the first function start is %#llx, want 0x2000", (unsigned long long)d0);
    struct linkedit_data_command *dc = (struct linkedit_data_command *)find_lc(buf, fsize, LC_DATA_IN_CODE);
    CHECK(UW32(buf, dc->dataoff, 0) == 0x2020 && UW32(buf, dc->dataoff, 4) == 0x10008,
          "raise: data in code starts at %#x, length and kind unchanged", UW32(buf, dc->dataoff, 0));
    CHECK(UW32(buf, 0x2800, 28) == 0x3040 && UW32(buf, 0x2800, 32) == 0x2000 &&
          UW32(buf, 0x2800, 44) == 0x2100 && UW32(buf, 0x2800, 56) == 0x2010 &&
          UW32(buf, 0x2800, 60) == 0x2180 && UW32(buf, 0x2800, 80) == (1u << 24),
          "raise: compact unwind's personality, functions, sentinel and LSDA are raised, its "
          "compressed entries are not");
    free(buf);
}

/* f1's lea names the header, which stays, from code a page further on. */
static void test_raise_repairs_code_that_addresses_the_header(void) {
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1000);
    if (!buf) return;
    struct hr_seen s = { { { 0 } }, 0, 0 };
    int64_t n = mhr_scan(buf, fsize, DY_RAISED_AT, hr_record, &s);
    CHECK(n == 1 && s.c[0].addr == DY_RAISED_AT + 0x2003 && s.c[0].immlen == 0,
          "raise: f1's lea still addresses the header (%lld)", (long long)n);
    free(buf);
}

/* Two pages: _d, 0x2020 + 0x2000, needs a wider ULEB, so the export trie is
 * rebuilt at the end of __LINKEDIT. */
static void test_raise_rebuilds_a_widening_export_trie(void) {
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL, 0x1001);
    if (!buf) return;
    uint32_t toff = 0, tsize = 0;
    mg_find_trie(buf, fsize, &toff, &tsize);
    CHECK(toff == DY_FSIZE + 0x2000 && fsize == DY_FSIZE + 0x2000 + tsize,
          "raise: the rebuilt trie is at the end (%#x, %u bytes, file %zu)", toff, tsize, fsize);
    free(buf);
}

/* A value strictly inside (base, base + F), or that no segment maps, cannot
 * be raised. */
static void test_raise_refuses_what_it_cannot_move(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    uint64_t v = DY_RAISED_AT + 16;
    memcpy(buf + 0x2008, &v, sizeof v);
    check_grow_refuses_header_refs("a pointer inside the header", buf, fsize,
        "ERROR: the pointer at 0x10002008 names 0x10000010, between the header at 0x10000000 and "
        "its first content at 0x10001000, which a grow moves apart; refusing to grow");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    v = DY_RAISED_AT + 0x5001;
    memcpy(buf + 0x2008, &v, sizeof v);
    check_grow_refuses_header_refs("a pointer past every segment", buf, fsize,
        "ERROR: the pointer at 0x10002008 names 0x10005001, which no segment maps; refusing to grow");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    v = DY_RAISED_AT - 1;
    memcpy(buf + 0x2008, &v, sizeof v);
    check_grow_refuses_header_refs("a pointer below every segment", buf, fsize,
        "ERROR: the pointer at 0x10002008 names 0xfffffff, which no segment maps");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    dy_syms(buf, fsize)[3].n_value = DY_RAISED_AT + 16;
    check_grow_refuses_header_refs("a symbol inside the header", buf, fsize,
        "ERROR: symbol 3, \"_d\", names 0x10000010, between the header at 0x10000000");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    hr_plant(buf + 0x1000, DY_RAISED_AT + 0x1000, 2, 0x05, 0, DY_RAISED_AT + 16);
    check_grow_refuses_header_refs("code inside the header", buf, fsize,
        "ERROR: the code at 0x10001003 names 0x10000010, between the header");
}

/* An N_SECT symbol below the base names nothing a raise moves. */
static void test_raise_leaves_a_symbol_below_the_base(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    dy_syms(buf, fsize)[3].n_value = 0x10;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && dy_syms(buf, fsize)[3].n_value == 0x10,
          "raise: a symbol below the base stays (got %d, %#llx)", r,
          (unsigned long long)dy_syms(buf, fsize)[3].n_value);
    free(buf);
}

/* _d, made absolute, is a value, 0x2020: the raise leaves it, and verify
 * expects it left. */
static void test_raise_leaves_an_absolute_export_alone(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    uint32_t toff = 0, tsize = 0;
    uint64_t a = 0;
    buf[0x3040 + 27] = 0x02;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    mg_find_trie(buf, fsize, &toff, &tsize);
    mu_decode(buf + toff + 28, buf + toff + tsize, &a);
    CHECK(r == 0 && a == 0x2020, "raise: an absolute export stays 0x2020 (got %d, %#llx)", r,
          (unsigned long long)a);
    free(buf);
}

/* A pointer to the first content, into a segment past a gap in memory
 * (__ZERO, a page past __LINKEDIT, or two with DY_ZEROFAR), or to the end of
 * a segment names content. Which segment maps it is decided before the raise
 * moves any: afterward, __ZERO + 8 lies in the gap a one-page raise opens. */
static void test_raise_moves_pointers_to_the_edges_of_content(void) {
    static const struct { const char *what; uint64_t v; int opts; } p[6] = {
        { "the first content", 0x1000, 0 },
        { "__ZERO's start", 0x6000, 0 },
        { "__ZERO + 8", 0x6008, 0 },
        { "__LINKEDIT's end", 0x5000, 0 },
        { "__ZERO's start, past a two-page gap", 0x7000, DY_ZEROFAR },
        { "__ZERO + 8, past a two-page gap", 0x7008, DY_ZEROFAR },
    };
    for (int i = 0; i < 6; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ZEROSEG | p[i].opts);
        uint64_t v = DY_RAISED_AT + p[i].v;
        memcpy(buf + 0x2008, &v, sizeof v);
        int r = mg_grow_header(&buf, &fsize, 0x1000);
        memcpy(&v, buf + 0x3008, sizeof v);
        CHECK(r == 0 && v == DY_RAISED_AT + p[i].v + 0x1000, "raise: a pointer to %s is raised "
              "(got %d, %#llx)", p[i].what, r, (unsigned long long)v);
        free(buf);
    }
}

/* An export at offset 0 names the header, and stays. */
static void test_raise_leaves_an_export_at_offset_0(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    uint32_t toff = 0, tsize = 0;
    uint64_t a = 1;
    buf[0x3040 + 28] = 0x80;                           /* _d: 0, in its two bytes */
    buf[0x3040 + 29] = 0x00;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    mg_find_trie(buf, fsize, &toff, &tsize);
    mu_decode(buf + toff + 28, buf + toff + tsize, &a);
    CHECK(r == 0 && a == 0, "raise: an export at offset 0 stays 0 (got %d, %#llx)", r,
          (unsigned long long)a);
    free(buf);
}

/* __LINKEDIT cut short of the string table: its offset maps nowhere, before
 * the raise and after it. */
static void test_raise_keeps_an_offset_no_segment_maps(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    seg_named(buf, fsize, "__LINKEDIT")->filesize = 0xf0;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "raise: an offset no segment maps stays unmapped (got %d)", r);
    free(buf);
}

/* Verification, on the raise: each check_verify_rejects_raise undoes one
 * thing a correct raise did. */
typedef void (*dy_undo)(uint8_t *buf, size_t fsize);
/* `unsnap`, where given, changes the snapshot's copy of the image as it was
 * instead, so that only what reads that copy sees it. */
static void check_verify_rejects_raise_of(const char *what, uint8_t *buf, size_t fsize,
                                          uint32_t grow_req, dy_undo undo, dy_undo unsnap,
                                          const char *needle) {
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) { CHECK(0, "%s: snapshot", what); free(buf); return; }
    if (mg_grow_header(&buf, &fsize, grow_req) != 0) {
        CHECK(0, "%s: grow", what); mg_snapshot_free(&snap); free(buf); return;
    }
    CHECK(mg_verify(buf, fsize, &snap) == 0, "%s: verify accepts the raise as made", what);
    if (undo) undo(buf, fsize);
    if (unsnap) unsnap(snap.old, snap.oldsize);
    int r;
    verify_snap = &snap;
    char *err = stderr_during(verify_thunk, &buf, &fsize, 0, &r);
    CHECK(r == -1 && strstr(err, needle) != NULL, "verify REJECTS %s, saying '%s' (got %d):\n%s",
          what, needle, r, err);
    free(err);
    mg_snapshot_free(&snap);
    free(buf);
}
static void check_verify_rejects_raise_with(const char *what, int opts, dy_undo undo,
                                            const char *needle) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL | opts);
    check_verify_rejects_raise_of(what, buf, fsize, 0x1000, undo, NULL, needle);
}
static void check_verify_rejects_raise(const char *what, dy_undo undo, const char *needle) {
    check_verify_rejects_raise_with(what, 0, undo, needle);
}
static void dy_unraise_pointer(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x3009] -= 0x10; }
static void dy_raise_header_pointer(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x3001] += 0x10; }
static void dy_unraise_symbol(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[3].n_value -= 0x1000; }
static void dy_raise_header_symbol(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[0].n_value += 0x1000; }
static void dy_unraise_unwind(uint8_t *buf, size_t fsize) { (void)fsize; UW32(buf, 0x2800, 32) -= 0x1000; }
static void dy_unrepair(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x2004] += 0x10; }
static void dy_unraise_linkedit(uint8_t *buf, size_t fsize) { seg_named(buf, fsize, "__LINKEDIT")->vmaddr -= 0x1000; }

static void test_verify_watches_the_raise(void) {
    check_verify_rejects_raise("a pointer to content left where it was", dy_unraise_pointer,
        "ERROR: verify FAILED -- the pointer at 0x10003008 holds 0x10001010 after the grow, and "
        "must hold 0x10002010; refusing.");
    check_verify_rejects_raise("a pointer to the header raised", dy_raise_header_pointer,
        "the pointer at 0x10003000 holds 0x10001000 after the grow, and must hold 0x10000000");
    check_verify_rejects_raise("a symbol left where it was", dy_unraise_symbol,
        "ERROR: verify FAILED -- symbol 3 is type 0xf, value 0x10002020 after the grow, and must "
        "be type 0xf, value 0x10003020; refusing.");
    check_verify_rejects_raise("the header's symbol raised", dy_raise_header_symbol,
        "symbol 0 is type 0x1e, value 0x10001000 after the grow, and must be type 0x1e, value "
        "0x10000000");
    check_verify_rejects_raise("an unwind entry left where it was", dy_unraise_unwind,
        "resolved to 0x10001000 before the grow and 0x10001000 after (moved +0 bytes), and must "
        "resolve to 0x10002000");
    check_verify_rejects_raise("code that addresses the header, unrepaired", dy_unrepair,
        "ERROR: verify FAILED -- code at 0x10002003 addresses 0x10001000, as a reference to the "
        "header the grow did not repair would; refusing.");
    check_verify_rejects_raise("__LINKEDIT left where it was", dy_unraise_linkedit,
        "and must resolve to 0x");
}

/* mg_ensure_pad says the contents were raised, and counts the code it
 * repaired; a pointer to the header, left where it is, is not repaired. */
static void test_ensure_pad_announces_a_raise(void) {
    size_t fsize;
    int r;
    uint8_t *buf = build_dylib(&fsize, 0);
    uint32_t lc_end = (uint32_t)sizeof(struct mach_header_64) +
                      ((struct mach_header_64 *)buf)->sizeofcmds;
    char want[160];
    snprintf(want, sizeof want, "t: grew the header pad by 4096 bytes (%u -> %u available); "
             "contents raised by 0x1000; new UUID; repaired 1 reference to the header\n",
             DY_F - lc_end, DY_F + 0x1000 - lc_end);
    char *err = ensure_pad_stderr(&buf, &fsize, DY_F + 1, &r);
    CHECK(r == 0 && strcmp(err, want) == 0, "ensure_pad on a dylib: announced as '%s' (got %d):\n%s",
          want, r, err);
    free(err);
    free(buf);
}

/* ---- stabs on a raise ----
 * A stab that holds an address names content, which moves, or the header,
 * which does not; one that holds a size, a timestamp or nothing stays. The
 * closing N_SO holds 0, the base of a dylib linked at 0. */
static void check_raise_moves_the_stabs(uint64_t base) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(base, &fsize, DY_STABS);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "stabs: a raise at base %#llx succeeds (got %d)", (unsigned long long)base, r);
    struct nlist_64 *nl = r == 0 ? dy_syms(buf, fsize) : NULL;
    for (int i = 0; nl && i < 15; i++) {
        uint64_t want = dy_stabs[i].moves ? base + dy_stabs[i].at + 0x1000 : dy_stabs[i].at;
        CHECK(nl[5 + i].n_value == want, "stabs: at base %#llx, stab %d (type %#x) is %#llx, "
              "want %#llx", (unsigned long long)base, i, dy_stabs[i].type,
              (unsigned long long)nl[5 + i].n_value, (unsigned long long)want);
    }
    free(buf);
}

static void test_raise_moves_the_stabs_that_hold_addresses(void) {
    check_raise_moves_the_stabs(0);
    check_raise_moves_the_stabs(DY_RAISED_AT);
}

/* N_LSYM is a stab this does not know; an N_STSYM naming the header's
 * inside names what a raise moves apart. */
static void test_raise_refuses_stabs_it_cannot_move(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_STABS);
    dy_syms(buf, fsize)[17].n_type = N_LSYM;
    check_grow_refuses_header_refs("an N_LSYM", buf, fsize,
        "ERROR: symbol 17, \"\", is a stab of type 0x80, which a raise does not know how to "
        "move; refusing to grow");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_STABS);
    dy_syms(buf, fsize)[12].n_value = DY_RAISED_AT + 16;
    check_grow_refuses_header_refs("an N_STSYM inside the header", buf, fsize,
        "ERROR: symbol 12, \"_d\", names 0x10000010, between the header at 0x10000000");
}

/* A lowered executable's stabs stay, whatever they hold. */
static void test_lowering_leaves_the_stabs(void) {
    size_t fsize;
    uint8_t *buf = build_symbol_image(&fsize, 4, 0);
    hsym(buf, fsize, 1)->n_type = N_FUN;
    hsym(buf, fsize, 1)->n_un.n_strx = 1;
    hsym(buf, fsize, 1)->n_value = 0x100000000ull;
    memcpy(buf + 6720, "\0_f", 4);
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0 && hsym(buf, fsize, 1)->n_value == 0x100000000ull,
          "stabs: a lowering leaves a named N_FUN (got %d, %#llx)", r,
          (unsigned long long)hsym(buf, fsize, 1)->n_value);
    free(buf);
}

static void dy_unraise_stab(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[8].n_value -= 0x1000; }
static void dy_raise_ensym(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[10].n_value += 0x1000; }

static void test_verify_watches_the_stabs(void) {
    check_verify_rejects_raise_with("a named N_FUN left where it was", DY_STABS, dy_unraise_stab,
        "ERROR: verify FAILED -- symbol 8 is type 0x24, value 0x10001010 after the grow, and must "
        "be type 0x24, value 0x10002010; refusing.");
    check_verify_rejects_raise_with("an N_ENSYM's size raised", DY_STABS, dy_raise_ensym,
        "symbol 10 is type 0x4e, value 0x1002 after the grow, and must be type 0x4e, value 0x2");
}

/* ---- split info ----
 * A raise leaves LC_SEGMENT_SPLIT_INFO's offsets stale, so it deletes the
 * command, and its payload (DY_SPLIT: 8 bytes of 0x5a) stays, unreferenced.
 * A lowering refuses it, as before. */
static void test_raise_drops_split_info(void) {
    size_t fsize;
    uint8_t *buf = build_dylib(&fsize, DY_SPLIT | DY_ROUTINES);
    struct mach_header_64 h0 = *(struct mach_header_64 *)buf;
    uint8_t *after = dy_find(buf, LC_SEGMENT_SPLIT_INFO) + sizeof(struct linkedit_data_command);
    ((struct routines_command_64 *)after)->reserved6 = 0x5a5a5a5a5a5a5a5aull;   /* the last 8 bytes */
    struct routines_command_64 rt0 = *(struct routines_command_64 *)after;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct routines_command_64 *rt = (struct routines_command_64 *)find_lc(buf, fsize, LC_ROUTINES_64);
    static const uint8_t payload[8] = { 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a, 0x5a };
    CHECK(r == 0 && !find_lc(buf, fsize, LC_SEGMENT_SPLIT_INFO) && h->ncmds == h0.ncmds - 1 &&
          h->sizeofcmds == h0.sizeofcmds - sizeof(struct linkedit_data_command),
          "split info: the raise deletes the command (got %d, %u commands, %u bytes)", r,
          h->ncmds, h->sizeofcmds);
    CHECK(rt && rt->cmdsize == rt0.cmdsize && rt->init_address == rt0.init_address + 0x1000 &&
          rt->reserved6 == rt0.reserved6, "split info: the command after it moved down whole");
    CHECK(memcmp(buf + 0x3098 + 0x1000, payload, sizeof payload) == 0,
          "split info: its payload stays where it was");
    CHECK(buf[sizeof *h + h->sizeofcmds] == 0 &&
          memcmp(buf + sizeof *h + h->sizeofcmds, buf + sizeof *h + h->sizeofcmds + 1,
                 sizeof(struct linkedit_data_command) - 1) == 0,
          "split info: the bytes it held are zero");
    free(buf);
}

static void test_raise_drops_every_split_info(void) {
    size_t fsize;
    uint8_t *buf = build_dylib(&fsize, DY_SPLIT);
    hr_add_lc(buf, LC_SEGMENT_SPLIT_INFO, 0x3098, "\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a", 8);
    struct mach_header_64 h0 = *(struct mach_header_64 *)buf;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    CHECK(r == 0 && !find_lc(buf, fsize, LC_SEGMENT_SPLIT_INFO) && h->ncmds == h0.ncmds - 2 &&
          h->sizeofcmds == h0.sizeofcmds - 2 * sizeof(struct linkedit_data_command),
          "split info: a raise deletes both of two (got %d, %u commands, %u bytes, from %u and %u)",
          r, h->ncmds, h->sizeofcmds, h0.ncmds, h0.sizeofcmds);
    free(buf);
}

/* Check 3 expects the load commands a raise makes from them as they were
 * before the split-info drop, which it restates for itself: the snapshot's
 * copy of the image is taken after the drop, and holds whatever the drop
 * did. Each planted change here lands in both the raised image and that
 * copy, as a drop that did it would leave them. */
static void dy_flip_reexports(uint8_t *buf, size_t fsize) {
    (void)fsize;
    ((struct mach_header_64 *)buf)->flags ^= MH_NO_REEXPORTED_DYLIBS;
}
static void dy_scribble_last(uint8_t *buf, size_t fsize) {
    struct routines_command_64 *rt = (struct routines_command_64 *)find_lc(buf, fsize, LC_ROUTINES_64);
    memset(&rt->reserved6, 0x41, 4);
}
static void dy_as_split(uint8_t *buf, size_t fsize) {
    ((struct load_command *)find_lc(buf, fsize, LC_DYLIB_CODE_SIGN_DRS))->cmd = LC_SEGMENT_SPLIT_INFO;
}
static void test_verify_watches_the_split_info_drop(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    check_verify_rejects_raise_of("the header's flags changed with the snapshot's", buf, fsize,
        0x1000, dy_flip_reexports, dy_flip_reexports,
        "ERROR: verify FAILED -- the grown image's header, or its size (17152 bytes), is not the "
        "original's with 4096 more; refusing.");
    buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    check_verify_rejects_raise_of("a load command changed with the snapshot's", buf, fsize,
        0x1000, dy_scribble_last, dy_scribble_last,
        "ERROR: verify FAILED -- load-command byte ");
    /* Split info the raise kept: LC_DYLIB_CODE_SIGN_DRS has its shape and
     * is kept, and is split info again in the raised image and the
     * snapshot's copy of the image as it was. */
    buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL | DY_SPLIT);
    ((struct load_command *)find_lc(buf, fsize, LC_SEGMENT_SPLIT_INFO))->cmd = LC_DYLIB_CODE_SIGN_DRS;
    check_verify_rejects_raise_of("split info the raise kept", buf, fsize, 0x1000, dy_as_split,
        dy_as_split, "ERROR: verify FAILED -- the raised image carries LC_SEGMENT_SPLIT_INFO, "
        "whose offsets a raise leaves stale; refusing.");

    /* As mg_grow_header has it: the snapshot of the image after the drop
     * (build_dylib's without DY_SPLIT, with the payload the drop leaves),
     * told the load commands from before it. The bytes the dropped command
     * held must be zero, whatever the snapshot's copy says. */
    size_t n;
    uint8_t *pre = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL | DY_SPLIT);
    uint8_t *post = build_dylib_at(DY_RAISED_AT, &n, DY_ALL);
    memset(post + 0x3098, 0x5a, 8);
    size_t had = sizeof(struct mach_header_64) + ((struct mach_header_64 *)pre)->sizeofcmds;
    size_t lcend = sizeof(struct mach_header_64) + ((struct mach_header_64 *)post)->sizeofcmds;
    uint8_t *lcs = (uint8_t *)malloc(had);
    memcpy(lcs, pre, had);
    mg_snapshot snap;
    if (mg_snapshot_take(post, n, &snap) != 0 || mg_grow_header(&pre, &fsize, 0x1000) != 0) {
        CHECK(0, "split info: snapshot and raise");
        free(lcs);
    } else {
        free(snap.lcs);
        snap.lcs = lcs;
        CHECK(mg_verify(pre, fsize, &snap) == 0 && had == lcend + 16,
              "split info: verify accepts the raise that dropped it, told the commands before it");
        pre[lcend + 4] = snap.old[lcend + 4] = 0x77;
        int r;
        verify_snap = &snap;
        char *err = stderr_during(verify_thunk, &pre, &fsize, 0, &r);
        char want[128];
        snprintf(want, sizeof want, "ERROR: verify FAILED -- header pad byte %#zx holds 0x77 after "
                 "the grow, and must hold 0; refusing.", lcend + 4);
        CHECK(r == -1 && strstr(err, want), "verify REJECTS a byte the dropped command held, left "
              "set in the snapshot's copy too, saying '%s' (got %d):\n%s", want, r, err);
        free(err);
    }
    mg_snapshot_free(&snap);
    free(pre);
    free(post);
}

static void test_lowering_refuses_split_info(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, 0);
    hr_add_lc(buf, LC_SEGMENT_SPLIT_INFO, 6656, "\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a", 8);
    check_grow_refuses_header_refs("split info on an executable", buf, fsize,
        "ERROR: LC_SEGMENT_SPLIT_INFO carries base-relative offsets that are not re-based");
}

/* LC_LOAD_UPWARD_DYLIB names a dylib, as LC_LOAD_DYLIB does, and nothing a
 * grow moves; AppKit, HIToolbox, Metadata and ten of libSystem's parts carry
 * one. */
static void test_grow_takes_an_upward_dylib(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_dylib(&fsize, 0);
    ((struct load_command *)dy_find(buf, LC_LOAD_DYLIB))->cmd = LC_LOAD_UPWARD_DYLIB;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "upward: a dylib with an upward dylib is raised (got %d)", r);
    free(buf);
    buf = build_image(&fsize, &sect_off, 0);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct dylib_command *d = (struct dylib_command *)((uint8_t *)(h + 1) + h->sizeofcmds);
    d->cmd = LC_LOAD_UPWARD_DYLIB;
    d->cmdsize = 32;
    d->dylib.name.offset = sizeof *d;
    memcpy(d + 1, "/x", 3);
    h->ncmds++;
    h->sizeofcmds += 32;
    r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "upward: an executable with an upward dylib is lowered (got %d)", r);
    free(buf);
}

static void test_ensure_pad_announces_dropped_split_info(void) {
    size_t fsize;
    int r;
    uint8_t *buf = build_dylib(&fsize, DY_SPLIT);
    uint32_t lc_end = (uint32_t)sizeof(struct mach_header_64) +
                      ((struct mach_header_64 *)buf)->sizeofcmds;
    char want[192];
    snprintf(want, sizeof want, "t: grew the header pad by 4096 bytes (%u -> %u available); "
             "contents raised by 0x1000; new UUID; dropped LC_SEGMENT_SPLIT_INFO; repaired 1 "
             "reference to the header\n", DY_F - lc_end, DY_F + 0x1000 - lc_end + 16);
    char *err = ensure_pad_stderr(&buf, &fsize, DY_F + 1, &r);
    CHECK(r == 0 && strcmp(err, want) == 0, "ensure_pad on a dylib with split info: announced "
          "as '%s' (got %d):\n%s", want, r, err);
    free(err);
    free(buf);
}

/* ---- the UUID ----
 * build_dylib's UUID is 10 11 ... 1f. The digests, taken with shasum -a 256
 * over those 16 bytes and then 00 10 00 00 00 00 00 00 (or 00 20 ...), begin
 * 02990cf9 272abb54 62af123c 32f75b2f and e5407efb 8d35fadb 31323fb6
 * 50fa04b5; the version nibble and variant bits make them these. */
static const uint8_t dy_uuid_raised[2][16] = {
    { 0x02, 0x99, 0x0c, 0xf9, 0x27, 0x2a, 0x4b, 0x54, 0xa2, 0xaf, 0x12, 0x3c, 0x32, 0xf7, 0x5b, 0x2f },
    { 0xe5, 0x40, 0x7e, 0xfb, 0x8d, 0x35, 0x4a, 0xdb, 0xb1, 0x32, 0x3f, 0xb6, 0x50, 0xfa, 0x04, 0xb5 },
};

static void test_raised_uuid_is_derived(void) {
    uint8_t old[16], out[16];
    for (int i = 0; i < 16; i++) old[i] = (uint8_t)(0x10 + i);
    mg_raised_uuid(old, 0x1000, out);
    CHECK(memcmp(out, dy_uuid_raised[0], 16) == 0, "uuid: raised by 0x1000");
    mg_raised_uuid(old, 0x2000, out);
    CHECK(memcmp(out, dy_uuid_raised[1], 16) == 0, "uuid: raised by 0x2000");
    memcpy(out, old, 16);
    mg_raised_uuid(out, 0x1000, out);
    CHECK(memcmp(out, dy_uuid_raised[0], 16) == 0, "uuid: derived in place");
}

static void test_raise_replaces_the_uuid(void) {
    static const uint32_t req[2] = { 0x1000, 0x1001 };
    for (int i = 0; i < 2; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib(&fsize, 0);
        int r = mg_grow_header(&buf, &fsize, req[i]);
        struct uuid_command *u = (struct uuid_command *)find_lc(buf, fsize, LC_UUID);
        CHECK(r == 0 && u && memcmp(u->uuid, dy_uuid_raised[i], 16) == 0,
              "uuid: a raise by %#x replaces it (got %d)", i ? 0x2000 : 0x1000, r);
        free(buf);
    }
}

/* A lowering moves no address a dSYM holds, so it keeps its UUID. */
static void test_lowering_keeps_the_uuid(void) {
    size_t fsize; uint32_t sect_off;
    uint8_t *buf = build_image(&fsize, &sect_off, 0);
    struct mach_header_64 *h = (struct mach_header_64 *)buf;
    struct uuid_command *u = (struct uuid_command *)((uint8_t *)(h + 1) + h->sizeofcmds);
    u->cmd = LC_UUID;
    u->cmdsize = sizeof *u;
    for (int i = 0; i < 16; i++) u->uuid[i] = (uint8_t)(0x10 + i);
    h->ncmds++;
    h->sizeofcmds += sizeof *u;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    u = (struct uuid_command *)find_lc(buf, fsize, LC_UUID);
    CHECK(r == 0 && u && u->uuid[0] == 0x10 && u->uuid[15] == 0x1f,
          "uuid: a lowering keeps it (got %d)", r);
    free(buf);
}

static void test_raise_refuses_a_short_uuid(void) {
    size_t fsize;
    uint8_t *buf = build_dylib(&fsize, 0);
    ((struct load_command *)dy_find(buf, LC_FUNCTION_STARTS))->cmd = LC_UUID;
    check_grow_refuses_header_refs("a short LC_UUID", buf, fsize,
        "ERROR: LC_UUID is 16 bytes, too short to hold its UUID; refusing to grow");
}

/* Without an LC_UUID, a raise has none to replace, and says nothing of one. */
static void test_ensure_pad_announces_no_uuid_it_has_not(void) {
    size_t fsize;
    int r;
    uint8_t *buf = build_dylib(&fsize, 0);
    ((struct load_command *)dy_find(buf, LC_UUID))->cmd = LC_SOURCE_VERSION;
    char *err = ensure_pad_stderr(&buf, &fsize, DY_F + 1, &r);
    CHECK(r == 0 && strstr(err, "contents raised by 0x1000; repaired 1 reference") != NULL,
          "ensure_pad on a dylib with no UUID: says no new one (got %d):\n%s", r, err);
    free(err);
    free(buf);
}

/* ---- verification: the raise's bytes ----
 * A correct raise, then one planted change that only the byte check sees. */
static void dy_flip_code(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x2011] ^= 1; }
static void dy_realign(uint8_t *buf, size_t fsize) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) == 0) mi_find_section(&im, "__TEXT", "__stub_helper")->align = 4;
}
static void dy_move_stub_helper(uint8_t *buf, size_t fsize) {
    mi_image im;
    if (mi_wrap(buf, fsize, &im) == 0) mi_find_section(&im, "__TEXT", "__stub_helper")->addr++;
}
static void dy_reprotect(uint8_t *buf, size_t fsize) { seg_named(buf, fsize, "__DATA")->maxprot = 7; }
static void dy_misroute(uint8_t *buf, size_t fsize) {
    ((struct routines_command_64 *)find_lc(buf, fsize, LC_ROUTINES_64))->init_address++;
}
static void dy_keep_uuid(uint8_t *buf, size_t fsize) {
    struct uuid_command *u = (struct uuid_command *)find_lc(buf, fsize, LC_UUID);
    for (int i = 0; i < 16; i++) u->uuid[i] = (uint8_t)(0x10 + i);
}
static void dy_dirty_pad(uint8_t *buf, size_t fsize) { (void)fsize; buf[DY_F + 0x10] = 1; }
static void dy_dirty_old_pad(uint8_t *buf, size_t fsize) { (void)fsize; buf[DY_F - 1] = 1; }
static void dy_redesc(uint8_t *buf, size_t fsize) { dy_syms(buf, fsize)[1].n_desc = 0x10; }
static void dy_relength_dic(uint8_t *buf, size_t fsize) {
    struct linkedit_data_command *dc = (struct linkedit_data_command *)find_lc(buf, fsize, LC_DATA_IN_CODE);
    buf[dc->dataoff + 4]++;
}
static void dy_restart(uint8_t *buf, size_t fsize) {
    struct linkedit_data_command *fs = (struct linkedit_data_command *)find_lc(buf, fsize, LC_FUNCTION_STARTS);
    buf[fs->dataoff + 2]++;                            /* the second start */
}
static void dy_reflag(uint8_t *buf, size_t fsize) { (void)fsize; ((struct mach_header_64 *)buf)->flags |= MH_PIE; }

static void test_verify_watches_the_raised_bytes(void) {
    check_verify_rejects_raise("a byte of code changed", dy_flip_code,
        "ERROR: verify FAILED -- file offset 0x2011 holds 0xc2 after the grow, and must hold 0xc3, "
        "as file offset 0x1011 did before it; refusing.");
    check_verify_rejects_raise("a section's alignment changed", dy_realign,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("a section's address off by one", dy_move_stub_helper,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("a segment's protection changed", dy_reprotect,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("LC_ROUTINES_64 off by one", dy_misroute,
        "ERROR: verify FAILED -- load-command byte ");
    check_verify_rejects_raise("the UUID kept", dy_keep_uuid,
        "ERROR: verify FAILED -- the raised image's UUID is the original's; refusing.");
    check_verify_rejects_raise("a byte of the inserted pad set", dy_dirty_pad,
        "ERROR: verify FAILED -- header pad byte 0x1010 holds 0x1 after the grow, and must hold "
        "0; refusing.");
    check_verify_rejects_raise("a byte of the original pad set", dy_dirty_old_pad,
        "ERROR: verify FAILED -- header pad byte 0xfff holds 0x1 after the grow, and must hold 0");
    check_verify_rejects_raise("a symbol's n_desc changed", dy_redesc, "as file offset 0x30b6 did");
    check_verify_rejects_raise("data in code's length changed", dy_relength_dic,
        "as file offset 0x3094 did");
    check_verify_rejects_raise("a later function start changed", dy_restart,
        "as file offset 0x3082 did");
    check_verify_rejects_raise("the header's flags changed", dy_reflag,
        "ERROR: verify FAILED -- the grown image's header, or its size (17152 bytes), is not the "
        "original's with 4096 more; refusing.");
}

/* The raise moves a section's relocation offset with the file, and keeps
 * the pad it found, whatever it held. */
static void test_raise_moves_a_relocation_offset_and_keeps_the_pad(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
    mi_image im;
    mi_wrap(buf, fsize, &im);
    mi_find_section(&im, "__DATA", "__data")->reloff = 0x3000;
    buf[DY_F - 1] = 0xaa;
    int r = mg_grow_header(&buf, &fsize, 0x1000);
    mi_wrap(buf, fsize, &im);
    CHECK(r == 0 && mi_find_section(&im, "__DATA", "__data")->reloff == 0x4000 &&
          buf[DY_F - 1] == 0xaa, "raise: a relocation offset moves, and the pad stays (got %d)", r);
    free(buf);
}

/* What the byte check leaves to the others it does not see as a change:
 * S_INIT_FUNC_OFFSETS raised, as mg_collect watches. */
static void test_raise_moves_the_initializer_offsets(void) {
    size_t fsize;
    uint8_t *buf = raised_dylib(&fsize, DY_ALL | DY_INITOFF, 0x1000);
    if (!buf) return;
    uint32_t v;
    memcpy(&v, buf + 0x2120, sizeof v);
    CHECK(v == 0x2010, "raise: the initializer offset is %#x, want 0x2010", v);
    free(buf);
}

/* ---- verification: what a raise makes of compact unwind, the export trie,
 * __LINKEDIT and the UUID ----
 * One page moves the export trie in place. Two widen _d, and the trie is
 * rebuilt: appended past __LINKEDIT, or, from dy_rich_trie, in its place. */

/* _f1 (with a spare byte after its address), _f2 (a stub at 0x1100, its
 * resolver f2), _d, and _r (a re-export of libSystem's _x): 45 bytes, as its
 * rebuild two pages up is, without the spare byte and with _d wider. */
static void dy_rich_trie(uint8_t *buf) {
    static const uint8_t trie[45] = {
        0x00, 0x04, '_', 'f', '1', 0, 20, '_', 'f', '2', 0, 26, '_', 'd', 0, 33, '_', 'r', 0, 38,
        0x04, 0x00, 0x80, 0x20, 0x00, 0x00,
        0x05, 0x10, 0x80, 0x22, 0x90, 0x20, 0x00,
        0x03, 0x00, 0xa0, 0x40, 0x00,
        0x05, 0x08, 0x01, '_', 'x', 0x00, 0x00 };
    memcpy(buf + 0x3040, trie, sizeof trie);
    ((struct dyld_info_command *)dy_find(buf, LC_DYLD_INFO_ONLY))->export_size = sizeof trie;
}
static void check_verify_rejects_trie_raise(const char *what, int rich, dy_undo undo,
                                            dy_undo unsnap, const char *needle) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    if (rich) dy_rich_trie(buf);
    check_verify_rejects_raise_of(what, buf, fsize, 0x1001, undo, unsnap, needle);
}

static uint8_t *dy_trie(uint8_t *buf, size_t fsize) {
    uint32_t off = 0, size = 0;
    mg_find_trie(buf, fsize, &off, &size);
    return buf + off;
}
static void dy_recommon(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x2804] ^= 1; }
static void dy_old_unwind_later(uint8_t *old, size_t n) { (void)n; old[0x1821]++; }  /* f1: 0x1100 */
static void dy_rename_export(uint8_t *buf, size_t fsize) { dy_trie(buf, fsize)[4] ^= 2; }  /* _f3 */
static void dy_weaken_export(uint8_t *buf, size_t fsize) { dy_trie(buf, fsize)[21] = 0x04; }
static void dy_reordinal(uint8_t *buf, size_t fsize) { dy_trie(buf, fsize)[40] = 2; }
static void dy_reimport(uint8_t *buf, size_t fsize) { dy_trie(buf, fsize)[42] = 'y'; }
static void dy_old_export_later(uint8_t *old, size_t n) { (void)n; old[0x3040 + 22]++; }
static void dy_old_resolver_later(uint8_t *old, size_t n) { (void)n; old[0x3040 + 30]++; }
static void dy_old_three_exports(uint8_t *old, size_t n) { (void)n; old[0x3040 + 1] = 3; }
static void dy_old_shared_node(uint8_t *old, size_t n) { (void)n; old[0x3040 + 19] = 33; }
static void dy_old_unterminated(uint8_t *old, size_t n) { (void)n; old[0x3040 + 43] = 'z'; }
static void dy_old_narrow_d(uint8_t *old, size_t n) { (void)n; old[0x3040 + 29] = 0x20; }  /* 0x1020 */
static void dy_rename_replaced(uint8_t *buf, size_t fsize) { (void)fsize; buf[0x5044] ^= 2; }
static void dy_relazy(uint8_t *buf, size_t fsize) {
    ((struct dyld_info_command *)find_lc(buf, fsize, LC_DYLD_INFO_ONLY))->lazy_bind_size += 16;
}
static void dy_revm_linkedit(uint8_t *buf, size_t fsize) {
    seg_named(buf, fsize, "__LINKEDIT")->vmsize += 0x1000;
}
static void dy_refile_linkedit(uint8_t *buf, size_t fsize) {
    seg_named(buf, fsize, "__LINKEDIT")->filesize--;
}
static void dy_old_linkedit_shorter(uint8_t *old, size_t n) {
    seg_named(old, n, "__LINKEDIT")->filesize -= 0x10;
}
static void dy_uuid_v3(uint8_t *buf, size_t fsize) {
    uint8_t *u = ((struct uuid_command *)find_lc(buf, fsize, LC_UUID))->uuid;
    u[6] = (uint8_t)((u[6] & 0x0f) | 0x30);
}
static void dy_uuid_ncs(uint8_t *buf, size_t fsize) {
    ((struct uuid_command *)find_lc(buf, fsize, LC_UUID))->uuid[8] &= 0x3f;
}
static void dy_uuid_other(uint8_t *buf, size_t fsize) {
    ((struct uuid_command *)find_lc(buf, fsize, LC_UUID))->uuid[0] ^= 1;
}

static void test_verify_watches_what_the_raise_derives(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    check_verify_rejects_raise("a byte of compact unwind's header changed", dy_recommon,
        "ERROR: verify FAILED -- file offset 0x2804 holds 0x1 after the grow, and must hold 0, "
        "as file offset 0x1804 did before it; refusing.");
    check_verify_rejects_raise_of("an unwind entry the snapshot says was later", buf, fsize,
        0x1000, NULL, dy_old_unwind_later,
        "ERROR: verify FAILED -- file offset 0x2821 holds 0x20 after the grow, and must hold "
        "0x21, file offset 0x1821's 0x11 raised; refusing.");
    check_verify_rejects_raise("an export renamed in place", dy_rename_export,
        "ERROR: verify FAILED -- file offset 0x4044 holds 0x33 after the grow, and must hold "
        "0x31, as file offset 0x3044 did before it; refusing.");

    check_verify_rejects_trie_raise("an export renamed in the appended trie", 0, dy_rename_export,
        NULL, "ERROR: verify FAILED -- export 0 of the raised trie, \"_f3\", differs in its name "
        "from what the raise makes of the old one, \"_f1\"; refusing.");
    check_verify_rejects_trie_raise("an export weakened in the rebuilt trie", 1, dy_weaken_export,
        NULL, "ERROR: verify FAILED -- export 0 of the raised trie, \"_f1\", differs in its flags "
        "from what the raise makes of the old one, \"_f1\"; refusing.");
    check_verify_rejects_trie_raise("a re-export's ordinal changed", 1, dy_reordinal, NULL,
        "ERROR: verify FAILED -- export 3 of the raised trie, \"_r\", differs in its re-export "
        "ordinal from what the raise makes of the old one, \"_r\"; refusing.");
    check_verify_rejects_trie_raise("a re-export's imported name changed", 1, dy_reimport, NULL,
        "ERROR: verify FAILED -- export 3 of the raised trie, \"_r\", differs in its imported "
        "name from what the raise makes of the old one, \"_r\"; refusing.");
    check_verify_rejects_trie_raise("an export the snapshot says was later", 1, NULL,
        dy_old_export_later, "ERROR: verify FAILED -- export 0 of the raised trie, \"_f1\", "
        "differs in its address from what the raise makes of the old one, \"_f1\"; refusing.");
    check_verify_rejects_trie_raise("a resolver the snapshot says was later", 1, NULL,
        dy_old_resolver_later, "ERROR: verify FAILED -- export 1 of the raised trie, \"_f2\", "
        "differs in its resolver from what the raise makes of the old one, \"_f2\"; refusing.");
    check_verify_rejects_trie_raise("an export the snapshot never had", 1, NULL,
        dy_old_three_exports, "ERROR: verify FAILED -- the raised export trie holds 4 exports, "
        "and the old one 3; refusing.");
    check_verify_rejects_trie_raise("a trie the snapshot says shared a node", 1, NULL,
        dy_old_shared_node, "ERROR: verify FAILED -- the old export trie could not be read: a "
        "node is reachable more than one way; refusing.");
    check_verify_rejects_trie_raise("a re-export the snapshot says was unterminated", 1, NULL,
        dy_old_unterminated, "ERROR: verify FAILED -- the old export trie could not be read: an "
        "export's terminal is malformed; refusing.");
    check_verify_rejects_trie_raise("a trie appended that the snapshot says fit", 0, NULL,
        dy_old_narrow_d, "ERROR: verify FAILED -- the grown image's header, or its size (21280 "
        "bytes), is not the original's with 8192 more; refusing.");
    check_verify_rejects_trie_raise("a byte of the trie an appended one replaced", 0,
        dy_rename_replaced, NULL, "ERROR: verify FAILED -- file offset 0x5044 holds 0x33 after "
        "the grow, and must hold 0x31, as file offset 0x3044 did before it; refusing.");

    check_verify_rejects_trie_raise("lazy_bind_size changed beside an appended trie", 0,
        dy_relazy, NULL, "ERROR: verify FAILED -- load-command byte 0x4ec holds 0x10 after the "
        "grow, and must hold 0; refusing.");
    check_verify_rejects_trie_raise("__LINKEDIT's vm size changed beside an appended trie", 0,
        dy_revm_linkedit, NULL, "ERROR: verify FAILED -- load-command byte 0x3a1 holds 0x20 "
        "after the grow, and must hold 0x10; refusing.");
    check_verify_rejects_trie_raise("__LINKEDIT's file size short of an appended trie", 0,
        dy_refile_linkedit, NULL, "ERROR: verify FAILED -- load-command byte 0x3b0 holds 0x1f "
        "after the grow, and must hold 0x20; refusing.");
    check_verify_rejects_trie_raise("an appended trie past where the snapshot's __LINKEDIT ended",
        0, NULL, dy_old_linkedit_shorter, "ERROR: verify FAILED -- load-command byte 0x4f0 holds "
        "0 after the grow, and must hold 0xf0; refusing.");

    check_verify_rejects_raise("a UUID of version 3", dy_uuid_v3,
        "ERROR: verify FAILED -- the raised image's UUID is not version 4; refusing.");
    check_verify_rejects_raise("a UUID of the NCS variant", dy_uuid_ncs,
        "ERROR: verify FAILED -- the raised image's UUID is not RFC 4122's variant; refusing.");
    check_verify_rejects_raise("a UUID not the raise's", dy_uuid_other,
        "ERROR: verify FAILED -- load-command byte 0x568 holds ");
}

/* A rebuilt trie keeps an absolute export's value, and an export at offset
 * 0, as the in-place walk does. */
static void test_raise_rebuilds_a_trie_with_what_stays(void) {
    static const struct { const char *what; uint8_t at, v; uint64_t want; } p[2] = {
        { "an absolute export", 21, 0x02, 0x1000 }, { "an export at offset 0", 23, 0x00, 0 } };
    for (int i = 0; i < 2; i++) {
        size_t fsize;
        uint64_t a = 1;
        uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
        dy_rich_trie(buf);
        buf[0x3040 + p[i].at] = p[i].v;
        if (p[i].at == 23) buf[0x3040 + 22] = 0x80;       /* _f1: 0, in its two bytes */
        int r = mg_grow_header(&buf, &fsize, 0x1001);
        mu_decode(dy_trie(buf, fsize) + 22, buf + fsize, &a);
        CHECK(r == 0 && a == p[i].want, "raise: a rebuilt trie keeps %s at %#llx (got %d, %#llx)",
              p[i].what, (unsigned long long)p[i].want, r, (unsigned long long)a);
        free(buf);
    }
}

/* A rebuilt trie appended to __LINKEDIT: its vm size covers its file size,
 * rounded up to a page, and never shrinks. */
static void test_raise_appends_a_trie_to_linkedit_of_any_vmsize(void) {
    static const uint64_t was[2] = { 0x300, 0x2000 }, want[2] = { 0x1000, 0x2000 };
    for (int i = 0; i < 2; i++) {
        size_t fsize;
        uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, 0);
        seg_named(buf, fsize, "__LINKEDIT")->vmsize = was[i];
        int r = mg_grow_header(&buf, &fsize, 0x1001);
        struct segment_command_64 *le = seg_named(buf, fsize, "__LINKEDIT");
        CHECK(r == 0 && le && le->vmsize == want[i] && le->filesize == fsize - le->fileoff,
              "raise: an appended trie leaves __LINKEDIT's vm size %#llx at %#llx, want %#llx "
              "(got %d)", (unsigned long long)was[i], le ? (unsigned long long)le->vmsize : 0,
              (unsigned long long)want[i], r);
        free(buf);
    }
}

/* ---- check 4: the oracles ---- */
static void dy_poke64(uint8_t *buf, uint32_t at, uint64_t v) { memcpy(buf + at, &v, sizeof v); }

static void check_oracle(const char *what, uint8_t *buf, unsigned want, const char *why) {
    char got[256] = "";
    unsigned holds = mg_oracles(buf, DY_FSIZE, MG_OR_ALL, got, sizeof got);
    CHECK(holds == want && (!why || strcmp(got, why) == 0),
          "oracles: %s: %#x hold, want %#x; said '%s', want '%s'", what, holds, want, got,
          why ? why : "");
    free(buf);
}

static void test_oracles_judge_the_fixture(void) {
    size_t fsize;
    uint8_t *buf;
    check_oracle("the fixture", build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL | DY_INITOFF),
                 MG_OR_ALL, NULL);
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2030, 0x1011);
    check_oracle("an initializer mid-function", buf, MG_OR_ALL & ~MG_OR_INITS,
                 "the initializer 0x1011 is not a function start");
    buf = build_dylib(&fsize, DY_ROUTINES);
    ((struct routines_command_64 *)dy_find(buf, LC_ROUTINES_64))->init_address = 0x1012;
    check_oracle("LC_ROUTINES_64 mid-function", buf, MG_OR_ALL & ~MG_OR_INITS,
                 "the initializer 0x1012 is not a function start");
    buf = build_dylib(&fsize, 0);
    dy_section(buf, "__DATA", "__mod_init_func")->flags = S_MOD_TERM_FUNC_POINTERS;
    dy_poke64(buf, 0x2030, 0x1013);
    check_oracle("a terminator mid-function", buf, MG_OR_ALL & ~MG_OR_INITS,
                 "the initializer 0x1013 is not a function start");
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2030, 0x1011);
    ((struct linkedit_data_command *)dy_find(buf, LC_FUNCTION_STARTS))->datasize = 0;
    check_oracle("an initializer, and no function starts", buf, MG_OR_ALL, NULL);
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2038, 0x1110);
    check_oracle("a lazy pointer at __stub_helper's end", buf, MG_OR_ALL & ~MG_OR_LAZY,
                 "the lazy pointer 0x1110 lies outside __stub_helper");
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2038, 0x10ff);
    check_oracle("a lazy pointer before __stub_helper", buf, MG_OR_ALL & ~MG_OR_LAZY,
                 "the lazy pointer 0x10ff lies outside __stub_helper");
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2038, 0x110f);
    check_oracle("a lazy pointer at __stub_helper's last byte", buf, MG_OR_ALL, NULL);
    buf = build_dylib(&fsize, 0);
    buf[0x3040 + 18] = 0x81;                           /* _f1: 0x1001 */
    check_oracle("an export off by one", buf, MG_OR_ALL & ~MG_OR_EXPORTS,
                 "the export _f1 names 0x1001, and its symbol 0x1000");
    buf = build_dylib(&fsize, 0);
    buf[0x3040 + 18] = 0x81;
    dy_syms(buf, DY_FSIZE)[1].n_type = N_SECT;         /* _f1 is not external */
    check_oracle("an export with no external symbol", buf, MG_OR_ALL, NULL);

    /* Compact unwind (DY_UNWIND): its personality at word 7, f2's LSDA at 15. */
    static const struct { const char *what; int word; uint32_t v; const char *why; } uw[6] = {
        { "an LSDA outside __gcc_except_tab", 15, 0x1010,
          "the LSDA 0x1010 lies outside __gcc_except_tab" },
        { "an LSDA at __gcc_except_tab's end", 15, 0x1190,
          "the LSDA 0x1190 lies outside __gcc_except_tab" },
        { "an LSDA at __gcc_except_tab's last byte", 15, 0x118f, NULL },
        { "a personality in __data", 7, 0x2000,
          "the personality 0x2000 names no __got or __nl_symbol_ptr slot" },
        { "a personality mid-slot", 7, 0x2044,
          "the personality 0x2044 names no __got or __nl_symbol_ptr slot" },
        { "compact unwind of a version it does not read", 0, 2, "__unwind_info could not be read" },
    };
    for (int i = 0; i < 6; i++) {
        buf = build_dylib(&fsize, DY_UNWIND);
        ((uint32_t *)(buf + 0x1800))[uw[i].word] = uw[i].v;
        check_oracle(uw[i].what, buf, uw[i].why ? MG_OR_ALL & ~MG_OR_UNWIND : MG_OR_ALL,
                     uw[i].why);
    }

    /* Two fail; `why` is the first of those asked about. */
    char why[256] = "";
    buf = build_dylib(&fsize, 0);
    dy_poke64(buf, 0x2030, 0x1011);
    dy_poke64(buf, 0x2038, 0x1110);
    unsigned holds = mg_oracles(buf, fsize, MG_OR_LAZY | MG_OR_EXPORTS, why, sizeof why);
    CHECK(holds == (MG_OR_EXPORTS | MG_OR_UNWIND) &&
          strcmp(why, "the lazy pointer 0x1110 lies outside __stub_helper") == 0,
          "oracles: asked about the lazy pointers alone, says why they fail (%#x, '%s')", holds, why);
    free(buf);
}

/* A lazy pointer moved outside __stub_helper, and the snapshot told it
 * moved there too: only check 4 sees it. And what did not hold before is
 * not asked after. */
static void test_verify_watches_the_oracles(void) {
    size_t fsize;
    uint8_t *buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    mg_snapshot snap;
    if (mg_snapshot_take(buf, fsize, &snap) != 0) { CHECK(0, "oracles: snapshot"); free(buf); return; }
    CHECK(snap.oracles == MG_OR_ALL, "oracles: the snapshot says all hold (%#x)", snap.oracles);
    if (mg_grow_header(&buf, &fsize, 0x1000) != 0) {
        CHECK(0, "oracles: grow"); mg_snapshot_free(&snap); free(buf); return;
    }
    dy_poke64(buf, 0x3038, DY_RAISED_AT + 0x3000);
    snap.rb.v[4].value = DY_RAISED_AT + 0x2000;
    int r;
    verify_snap = &snap;
    char *err = stderr_during(verify_thunk, &buf, &fsize, 0, &r);
    CHECK(r == -1 && strstr(err, "ERROR: verify FAILED -- the lazy pointer 0x10003000 lies outside "
                                 "__stub_helper after the grow, which held before it; refusing.\n"),
          "oracles: verify REJECTS a lazy pointer outside __stub_helper (got %d):\n%s", r, err);
    free(err);
    mg_snapshot_free(&snap);
    free(buf);

    buf = build_dylib_at(DY_RAISED_AT, &fsize, DY_ALL);
    dy_poke64(buf, 0x2038, DY_RAISED_AT + 0x2000);
    r = mg_grow_header(&buf, &fsize, 0x1000);
    CHECK(r == 0, "oracles: a raise of an image one did not hold of succeeds (got %d)", r);
    free(buf);
}

int main(void) {
    test_uleb_decode();
    test_uleb_minlen();
    test_uleb_encode_fixed();
    test_reencode_same_width();
    test_reencode_widen_refuses();
    test_reencode_nonminimal_original_preserved();
    test_reencode_malformed();
    test_invariant_addresses_preserved();
    test_init_offsets_rebase();
    test_grow_applies_init_offsets_once();
    test_grow_rebases_data_in_code();
    test_grow_rebases_export_trie();
    test_grow_rebuilds_widening_export_trie();
    test_grow_refuses_unknown_load_command();
    test_grow_refuses_linker_optimization_hint();
    test_grow_refuses_unknown_section_type();
    test_grow_refuses_note();
    test_grow_refuses_atom_info();
    test_grow_refuses_32bit_mach_header();
    test_plausible_accepts_a_well_formed_image();
    test_plausible_rejects_an_offset_that_names_no_function();
    test_plausible_rejects_an_unrebased_initializer();
    test_grow_rebases_unwind_info();
    test_grow_handles_zero_size_unwind_info();
    test_grow_refuses_overflowing_unwind_info();
    test_grow_uses_first_unwind_info_not_last();
    test_grow_refuses_missing_pagezero();
    test_grow_refuses_undersized_pagezero();
    test_grow_refuses_no_text_segment();
    test_verify_watches_unwind_info();
    test_verify_accepts_a_correct_grow();
    test_verify_rejects_double_apply();
    test_verify_rejects_handler_that_never_ran();
    test_grow_refuses_overflowing_section_offset();
    test_grow_refuses_overflowing_reloff();
    test_grow_refuses_overflowing_entryoff();
    test_verify_watches_every_adjusted_field();
    test_ensure_pad_fits_is_a_noop();
    test_ensure_pad_grows_and_announces();
    test_ensure_pad_refuses_what_cannot_grow();
    test_ensure_pad_refuses_arm64();
    test_first_sect_off_reports_no_section_data();
    test_ensure_pad_refuses_an_image_with_no_section_data();
    test_ensure_pad_refuses_a_section_past_the_image();
    test_grow_refuses_an_image_with_no_section_data();
    test_grow_refuses_a_section_past_the_image();
    test_grow_diagnostics_name_no_program();
    test_scan_finds_every_immediate_length();
    test_scan_ignores_a_target_one_byte_past_the_base();
    test_scan_ignores_forms_that_are_not_rip_relative();
    test_scan_stops_at_the_section_end();
    test_scan_reports_a_lookalike_inside_another_instruction();
    test_scan_stops_when_asked();
    test_scan_reads_every_instruction_section_and_no_other();
    test_scan_refuses_an_instruction_section_past_the_image();
    test_scan_continues_after_a_bad_instruction_section();
    test_grow_repairs_header_references();
    test_grow_refuses_a_header_reference_it_cannot_confirm();
    test_grow_refuses_a_header_reference_without_function_starts();
    test_grow_refuses_code_it_cannot_scan();
    test_verify_watches_header_references();
    test_grow_refuses_a_reference_the_grow_would_put_out_of_reach();
    test_verify_says_when_it_cannot_search_the_image();
    test_ensure_pad_repairs_each_header_reference();
    test_ensure_pad_repairs_one_header_reference();
    test_ensure_pad_repairs_across_a_two_page_grow();
    test_ensure_pad_announces_no_repair_without_a_header_reference();
    test_ensure_pad_refuses_code_it_cannot_scan();
    test_ensure_pad_fits_despite_a_header_reference();
    test_grow_leaves_an_absolute_export_alone();
    test_verify_watches_an_absolute_export();
    test_reencode_leaves_an_empty_list_alone();
    test_grow_leaves_an_empty_function_starts_list_alone();
    test_confirm_a_lea_of_the_header();
    test_confirm_an_operand_with_an_immediate();
    test_confirm_rejects_a_lookalike_inside_an_immediate();
    test_confirm_rejects_an_absolute_address_that_looks_rip_relative();
    test_confirm_rejects_a_lookalike_inside_a_rip_relative_instruction();
    test_confirm_rejects_an_operand_whose_immediate_moves_its_target();
    test_confirm_needs_function_starts();
    test_confirm_ignores_function_starts_past_the_image();
    test_confirm_stops_at_the_function_starts_terminator();
    test_confirm_reads_the_first_of_each_command();
    test_confirm_needs_a_function_in_the_candidates_section();
    test_confirm_steps_over_data_in_code();
    test_confirm_orders_data_in_code();
    test_confirm_rejects_a_candidate_inside_data_in_code();
    test_confirm_rejects_what_the_decoder_cannot_decode();
    test_confirm_reports_an_image_it_cannot_scan();
    test_grow_moves_the_symbols_that_name_the_header();
    test_verify_watches_the_symbols();
    test_snapshot_and_verify_refuse_a_symbol_table_past_the_image();
    test_grow_refuses_two_symbol_tables();
    test_grow_refuses_a_symbol_table_past_the_image();
    test_grow_moves_no_symbol_when_it_refuses();
    test_confirm_reports_a_bad_section_before_a_good_one();
    test_confirm_rejects_data_in_code_starting_mid_instruction();
    test_confirm_rejects_an_eip_relative_operand();
    test_confirm_ignores_a_malformed_function_starts_list();
    test_confirm_ignores_an_overlong_function_starts_terminator();
    test_confirm_resumes_within_a_function();
    test_confirm_resumes_across_data_in_code();
    test_confirm_resumes_only_in_its_own_function();
    test_confirm_resumes_only_in_its_own_section();
    test_confirm_carries_data_in_code_only_forward();
    test_confirm_carries_data_in_code_only_from_where_it_was_passed();
    test_confirm_ignores_a_wrapping_function_starts_delta();
    test_confirm_ignores_empty_data_in_code_past_the_image();
    test_confirm_reports_data_in_code_past_the_image();
    test_confirm_reports_data_in_code_not_a_multiple_of_8();
    test_confirm_needs_function_starts_when_the_list_is_empty();
    test_rebases_read_every_target();
    test_rebases_read_a_target_ending_at_the_segments_file_data();
    test_rebases_read_none_without_rebase_opcodes();
    test_rebases_read_refuses_what_it_cannot_read();
    test_rebases_read_refuses_a_short_command_before_reading_it();
    test_grow_refuses_rebases_it_cannot_read();
    test_grow_accepts_readable_rebases();
    test_grow_moves_the_pointers_that_name_the_header();
    test_grow_refuses_a_pointer_inside_the_header();
    test_grow_refuses_a_pointer_below_the_header();
    test_header_pointers_counts_without_moving();
    test_ensure_pad_announces_the_pointers_it_moves();
    test_verify_watches_the_pointers();
    test_snapshot_refuses_rebases_it_cannot_read();
    test_rebases_read_refuses_local_relocations();
    test_grow_refuses_local_relocations();
    test_rebases_read_refuses_a_malformed_image();
    test_find_trie_refuses_a_short_dyld_info();
    test_scan_reports_each_candidates_target();
    test_scan_range_takes_its_bounds_inclusively();
    test_confirm_each_gives_each_candidate_its_verdict();
    test_confirm_each_resumes_the_sweep_across_candidates();
    test_confirm_each_stops_when_asked();
    test_confirm_each_reports_an_image_it_cannot_scan();
    test_grow_refuses_code_that_names_the_inside_of_the_header();
    test_grow_leaves_code_that_names_the_first_content();
    test_grow_decides_what_decoding_does_not_confirm_inside_the_header();
    test_grow_refuses_a_symbol_inside_the_header();
    test_grow_leaves_other_symbols_that_name_the_inside_of_the_header();
    test_grow_refuses_an_export_inside_the_header();
    test_grow_leaves_an_absolute_export_inside_the_header();
    test_grow_refuses_a_bind_in_the_segment_that_maps_the_header();
    test_grow_refuses_binds_it_cannot_read();
    test_grow_accepts_binds_outside_the_header_segment();
    test_grow_refuses_what_it_cannot_raise();
    test_grow_raises_past_what_it_can_vouch_for();
    test_raise_moves_the_segments_and_sections();
    test_raise_moves_the_pointers_that_name_content();
    test_raise_moves_the_symbols_that_name_content();
    test_raise_moves_what_is_measured_from_the_base();
    test_raise_repairs_code_that_addresses_the_header();
    test_raise_rebuilds_a_widening_export_trie();
    test_raise_refuses_what_it_cannot_move();
    test_raise_moves_pointers_to_the_edges_of_content();
    test_raise_keeps_an_offset_no_segment_maps();
    test_raise_leaves_an_export_at_offset_0();
    test_raise_leaves_an_absolute_export_alone();
    test_raise_leaves_a_symbol_below_the_base();
    test_raise_moves_the_stabs_that_hold_addresses();
    test_raise_refuses_stabs_it_cannot_move();
    test_lowering_leaves_the_stabs();
    test_verify_watches_the_stabs();
    test_raise_drops_split_info();
    test_raise_drops_every_split_info();
    test_verify_watches_the_split_info_drop();
    test_lowering_refuses_split_info();
    test_ensure_pad_announces_dropped_split_info();
    test_grow_takes_an_upward_dylib();
    test_raised_uuid_is_derived();
    test_raise_replaces_the_uuid();
    test_lowering_keeps_the_uuid();
    test_raise_refuses_a_short_uuid();
    test_ensure_pad_announces_no_uuid_it_has_not();
    test_verify_watches_the_raised_bytes();
    test_verify_watches_what_the_raise_derives();
    test_raise_appends_a_trie_to_linkedit_of_any_vmsize();
    test_raise_rebuilds_a_trie_with_what_stays();
    test_raise_moves_the_initializer_offsets();
    test_raise_moves_a_relocation_offset_and_keeps_the_pad();
    test_oracles_judge_the_fixture();
    test_verify_watches_the_oracles();
    test_verify_watches_the_raise();
    test_ensure_pad_announces_a_raise();
    if (fails) { printf("macho_grow_test: %d FAILURE(S)\n", fails); return 1; }
    printf("macho_grow_test: all cases pass\n");
    return 0;
}
