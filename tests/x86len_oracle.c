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
 * stops at bytes either side cannot decode, such as a jump table. The 10.9
 * toolchain writes no LC_DATA_IN_CODE entries, so there are none to skip.
 *
 * Prints one summary line, and one line per mismatch (the first ten); exits 1
 * on a mismatch or when no instruction was compared, 2 on bad input.
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
    uint64_t *starts = (uint64_t *)malloc((f.fs->datasize + 1) * sizeof *starts);
    if (!starts) { fprintf(stderr, "x86len_oracle: out of memory\n"); return 2; }
    size_t nstarts = 0;
    const uint8_t *p = im.buf + f.fs->dataoff, *pe = p + f.fs->datasize;
    for (uint64_t a = base, d; p < pe; ) {
        int c = mu_decode(p, pe, &d);
        if (c == 0 || d == 0) break;
        p += c; a += d;
        if (a >= lo && a < hi) starts[nstarts++] = a;
    }

    unsigned long compared = 0, insns = 0, out_of_step = 0, stopped = 0, bad = 0;
    for (size_t i = 0; i < nstarts; i++) {
        uint64_t s = starts[i], e = i + 1 < nstarts ? starts[i + 1] : hi;
        size_t j = line_at(s);
        if (j == nlines || lines[j].addr != s) { out_of_step++; continue; }
        compared++;
        for (uint64_t pc = s; pc < e; ) {
            mx_insn in;
            j = line_at(pc);
            if (lines[j].bad || !mx_decode(code + (pc - lo), (size_t)(hi - pc), &in)) { stopped++; break; }
            insns++;
            uint64_t next = pc + (uint64_t)in.len;
            if (next < e && (j + 1 == nlines || lines[j + 1].addr != next)) {
                if (bad++ < 10) {
                    printf("MISMATCH at %#llx: the decoder says %d bytes, otool %lld:",
                           (unsigned long long)pc, in.len,
                           j + 1 < nlines ? (long long)(lines[j + 1].addr - pc) : -1LL);
                    for (uint64_t b = pc; b < pc + 15 && b < hi; b++) printf(" %02x", code[b - lo]);
                    printf("\n");
                }
                break;
            }
            pc = next;
        }
    }
    printf("x86len_oracle: %s: %lu of %zu functions compared, %lu instructions, %lu mismatches "
           "(%lu out of step with otool at their start; %lu stopped at bytes either cannot "
           "decode)\n", argv[1], compared, nstarts, insns, bad, out_of_step, stopped);
    return bad || insns == 0;
}
