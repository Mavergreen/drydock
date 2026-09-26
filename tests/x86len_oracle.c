/*
 * x86len_oracle.c -- src/x86len.h's instruction boundaries against otool's,
 * over every function of a real image.
 *
 *   otool -tv FILE | x86len_oracle FILE
 *
 * FILE is a thin x86_64 image. otool disassembles __TEXT,__text in one sweep
 * from its start; for each function LC_FUNCTION_STARTS names there, the
 * decoder sweeps from the function's start to the next function's, and each
 * instruction must end where otool's next one starts. otool is out of step at
 * a function whose start it has no line for (padding before it ended
 * mid-instruction): that function is not compared. A function's comparison
 * stops at bytes either side cannot decode: either otool itself has no
 * usable line there (a jump table's data, which otool marks `.byte`, or
 * a line neither side can pair up -- both sides agree there's nothing to
 * compare), or otool decoded a real instruction there and the length
 * decoder refused it -- which is the more serious of the two, since it is
 * the decoder disagreeing with otool about bytes otool says ARE code.
 * That second kind fails unless the exact site (image, address) is in
 * ALLOWED below; each such site was individually confirmed (by inspecting
 * the bytes) to be a jump table that otool's own linear sweep misreads as
 * an opcode invalid in 64-bit mode, not real code the decoder actually
 * needed to handle. The 10.9 toolchain writes no LC_DATA_IN_CODE entries,
 * so there are none to skip up front, and it's what forces this comparison
 * to keep discovering jump tables by running into them from both sides.
 *
 * Prints one summary line, and up to ten lines each of MISMATCH (a boundary
 * disagreement, including a decode that runs past its function's end) and
 * REFUSED (an unlisted site where otool decodes and the length decoder does
 * not); exits 1 on any of those, when no instruction was compared, or when
 * an allow-listed site no longer occurs (see below), 2 on bad input. Set
 * X86LEN_ORACLE_NO_ALLOWLIST to any non-empty value to treat every REFUSED
 * site as unlisted, allow-list included.
 *
 * Two test-only knobs exercise paths the corpus does not reach on its own.
 * X86LEN_ORACLE_EXTRA_ALLOW: an address, added to the allow-list for the
 * current image, that this corpus never produces -- proves a stale
 * allow-listed site fails by name. X86LEN_ORACLE_TEST_SHRINK: a byte count
 * taken off the first compared function's end -- proves a decode that then
 * runs past it is a MISMATCH.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach-o/loader.h>

#include "image.h"
#include "uleb.h"
#include "x86len.h"

struct line { uint64_t addr; int bad; };
static struct line *lines;
static size_t nlines, caplines;

/* otool prints these prefixes as instructions of their own, at the prefix's
 * address; the instruction they prefix follows, on the next line. */
static int is_prefix(const char *m) {
    static const char *const p[] = { "lock", "rep", "repne", "data16", "cs", "ds", "es",
                                     "fs", "gs", "ss", "xacquire", "xrelease", NULL };
    for (int i = 0; p[i]; i++) if (strcmp(m, p[i]) == 0) return 1;
    return 0;
}

/* Every "ADDRESS<tab>MNEMONIC ..." line, a prefix's line joined to the next. */
static void read_otool(FILE *f) {
    char buf[4096];
    int joining = 0;
    while (fgets(buf, sizeof buf, f)) {
        char *end, m[32];
        uint64_t a = strtoull(buf, &end, 16);
        if (end == buf || *end != '\t' || sscanf(end, "%31s", m) != 1) continue;
        int bad = strcmp(m, ".byte") == 0;
        if (joining) { lines[nlines - 1].bad = bad; joining = is_prefix(m); continue; }
        joining = is_prefix(m);
        if (nlines == caplines) {
            caplines = caplines ? 2 * caplines : 1 << 16;
            lines = (struct line *)realloc(lines, caplines * sizeof *lines);
            if (!lines) { fprintf(stderr, "x86len_oracle: out of memory\n"); exit(2); }
        }
        lines[nlines].addr = a;
        lines[nlines++].bad = bad;
    }
}

static size_t line_at(uint64_t a) {           /* the first line at or after a */
    size_t lo = 0, hi = nlines;
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (lines[mid].addr < a) lo = mid + 1; else hi = mid; }
    return lo;
}

/* The last path component, so a site names the same image whether argv[1]
 * is the corpus original or a thin copy under a temp dir -- the shell test
 * always names the thin copy after basename(original). */
static const char *basename_of(const char *path) {
    const char *b = strrchr(path, '/');
    return b ? b + 1 : path;
}

/* Sites where otool decodes a real instruction and the length decoder
 * refuses it -- confirmed, each one, to be a jump table's raw data that
 * otool's own linear sweep (falling out of step after the switch it
 * follows) misreads as an opcode invalid in 64-bit mode, not code the
 * decoder needed to get right. The list is exact: a site the corpus stops
 * producing is a failure below, not a silent match -- the corpus is fixed,
 * so that means this list has gone stale, not that anything got fixed. */
struct allowed { const char *image; uint64_t addr; };
static const struct allowed ALLOWED[] = {
    { "libsystem_c.dylib", 0x492b4 },  /* ce fe ff ff ...: INTO, invalid in 64-bit mode */
    { "vImage", 0x164444 },            /* ea d6 ff ff ...: far JMP, invalid in 64-bit mode */
    { "vImage", 0x208175 },            /* ce ff ff a8 ...: INTO, invalid in 64-bit mode */
};
#define NALLOWED (sizeof(ALLOWED) / sizeof(ALLOWED[0]))
static int allowed_hit[NALLOWED];

/* X86LEN_ORACLE_EXTRA_ALLOW: an address the test adds to the allow-list for
 * the current image, on top of ALLOWED, to prove a site that never occurs
 * is reported as such and fails the run (see main). */
static uint64_t extra_allow_addr;
static int has_extra_allow, extra_allow_hit;

static int is_allowed(const char *image, uint64_t addr) {
    for (size_t i = 0; i < NALLOWED; i++)
        if (strcmp(ALLOWED[i].image, image) == 0 && ALLOWED[i].addr == addr) { allowed_hit[i] = 1; return 1; }
    if (has_extra_allow && addr == extra_allow_addr) { extra_allow_hit = 1; return 1; }
    return 0;
}

struct find { const struct linkedit_data_command *fs; const struct section_64 *text; };
static int find_cb(const struct load_command *lc, void *ctx_) {
    struct find *c = (struct find *)ctx_;
    if (lc->cmd == LC_FUNCTION_STARTS) c->fs = (const struct linkedit_data_command *)lc;
    if (lc->cmd == LC_SEGMENT_64) {
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        const struct section_64 *s = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++)
            if (strncmp(s[j].segname, "__TEXT", 16) == 0 && strncmp(s[j].sectname, "__text", 16) == 0)
                c->text = &s[j];
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: otool -tv FILE | x86len_oracle FILE\n"); return 2; }
    int no_allowlist = getenv("X86LEN_ORACLE_NO_ALLOWLIST") && *getenv("X86LEN_ORACLE_NO_ALLOWLIST");
    const char *extra_allow_env = getenv("X86LEN_ORACLE_EXTRA_ALLOW");
    if (extra_allow_env && *extra_allow_env) {
        has_extra_allow = 1;
        extra_allow_addr = strtoull(extra_allow_env, NULL, 0);
    }
    uint64_t shrink = 0;
    const char *shrink_env = getenv("X86LEN_ORACLE_TEST_SHRINK");
    if (shrink_env && *shrink_env) shrink = strtoull(shrink_env, NULL, 0);
    const char *image = basename_of(argv[1]);
    mi_image im;
    uint64_t base;
    struct find f = { NULL, NULL };
    if (mi_open(argv[1], &im) != 0 || mi_image_base(&im, &base) != 0) {
        fprintf(stderr, "x86len_oracle: %s: not an image this can read\n", argv[1]);
        return 2;
    }
    mi_each_lc(&im, find_cb, &f);
    if (!f.text || !f.fs || (uint64_t)f.text->offset + f.text->size > im.size ||
        (uint64_t)f.fs->dataoff + f.fs->datasize > im.size) {
        fprintf(stderr, "x86len_oracle: %s: no __text and LC_FUNCTION_STARTS to compare\n", argv[1]);
        return 2;
    }
    read_otool(stdin);

    uint64_t lo = f.text->addr, hi = f.text->addr + f.text->size;
    const uint8_t *code = im.buf + f.text->offset;
    uint64_t *starts = (uint64_t *)malloc(((size_t)f.fs->datasize + 1) * sizeof *starts);
    if (!starts) { fprintf(stderr, "x86len_oracle: out of memory\n"); return 2; }
    size_t nstarts = 0;
    const uint8_t *p = im.buf + f.fs->dataoff, *pe = p + f.fs->datasize;
    for (uint64_t a = base, d; p < pe; ) {
        int c = mu_decode(p, pe, &d);
        if (c == 0 || d == 0) break;
        p += c; a += d;
        if (a >= lo && a < hi) starts[nstarts++] = a;
    }

    unsigned long compared = 0, insns = 0, out_of_step = 0, stopped_otool = 0, stopped_decoder = 0,
                  bad = 0, refused = 0;
    int shrunk = 0;
    for (size_t i = 0; i < nstarts; i++) {
        uint64_t s = starts[i], e = i + 1 < nstarts ? starts[i + 1] : hi;
        size_t j = line_at(s);
        if (j == nlines || lines[j].addr != s) { out_of_step++; continue; }
        if (shrink && !shrunk) { e -= shrink; shrunk = 1; }
        compared++;
        for (uint64_t pc = s; pc < e; ) {
            mx_insn in;
            j = line_at(pc);
            if (lines[j].bad) { stopped_otool++; break; }
            if (!mx_decode(code + (pc - lo), (size_t)(hi - pc), &in)) {
                stopped_decoder++;
                if (no_allowlist || !is_allowed(image, pc)) {
                    if (refused++ < 10) {
                        printf("REFUSED at %#llx: otool decodes here, the decoder does not:",
                               (unsigned long long)pc);
                        for (uint64_t b = pc; b < pc + 15 && b < hi; b++) printf(" %02x", code[b - lo]);
                        printf("\n");
                    }
                }
                break;
            }
            insns++;
            uint64_t next = pc + (uint64_t)in.len;
            int overrun = next > e;
            if (overrun || (next < e && (j + 1 == nlines || lines[j + 1].addr != next))) {
                if (bad++ < 10) {
                    printf("MISMATCH at %#llx: the decoder says %d bytes, otool %lld:",
                           (unsigned long long)pc, in.len,
                           overrun ? (long long)(e - pc) :
                           j + 1 < nlines ? (long long)(lines[j + 1].addr - pc) : -1LL);
                    for (uint64_t b = pc; b < pc + 15 && b < hi; b++) printf(" %02x", code[b - lo]);
                    printf("\n");
                }
                break;
            }
            pc = next;
        }
    }
    int stale = 0;
    for (size_t i = 0; i < NALLOWED; i++)
        if (!no_allowlist && strcmp(ALLOWED[i].image, image) == 0 && !allowed_hit[i]) {
            printf("x86len_oracle: FAIL: allow-listed site %s %#llx did not occur\n",
                   ALLOWED[i].image, (unsigned long long)ALLOWED[i].addr);
            stale = 1;
        }
    if (!no_allowlist && has_extra_allow && !extra_allow_hit) {
        printf("x86len_oracle: FAIL: allow-listed site %s %#llx did not occur\n",
               image, (unsigned long long)extra_allow_addr);
        stale = 1;
    }
    printf("x86len_oracle: %s: %lu of %zu functions compared, %lu instructions, %lu mismatches, "
           "%lu unlisted refusals (%lu out of step with otool at their start; %lu stopped where "
           "otool also has nothing; %lu stopped where otool decodes and the decoder refused, "
           "%lu of them allow-listed)\n",
           argv[1], compared, nstarts, insns, bad, refused, out_of_step, stopped_otool,
           stopped_decoder, stopped_decoder - refused);
    return bad || refused || insns == 0 || stale;
}
