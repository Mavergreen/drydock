/* tests/rebase_oracle.c -- src/rebase.h's decode of a thin 64-bit image's
 * rebase stream, printed as `dyldinfo -rebase` prints its own, less the
 * section column: one "SEGMENT ADDRESS TYPE" line per slot, in stream order.
 *   rebase_oracle FILE */
#include <stdio.h>
#include <string.h>
#include <mach-o/loader.h>

#include "image.h"
#include "rebase.h"

typedef struct {
    char name[64][17];
    uint64_t vmaddr[64];
    int n;
    const struct dyld_info_command *di;
} ro_lcs;

static int ro_lc(const struct load_command *lc, void *ctx_) {
    ro_lcs *c = ctx_;
    if (lc->cmd == LC_SEGMENT_64 && c->n < 64) {
        const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
        snprintf(c->name[c->n], sizeof c->name[c->n], "%.16s", sc->segname);
        c->vmaddr[c->n++] = sc->vmaddr;
    } else if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
        c->di = (const struct dyld_info_command *)lc;
    }
    return 0;
}

static const char *ro_type(uint8_t t) {
    return t == REBASE_TYPE_POINTER ? "pointer" : t == REBASE_TYPE_TEXT_ABSOLUTE32 ? "text abs32"
         : t == REBASE_TYPE_TEXT_PCREL32 ? "text rel32" : "??";
}

int main(int argc, char **argv) {
    mi_image im;
    ro_lcs c;
    mrb_set set;
    char why[160] = "";
    if (argc != 2) { fprintf(stderr, "usage: rebase_oracle FILE\n"); return 2; }
    if (mi_open(argv[1], &im) != 0) { fprintf(stderr, "rebase_oracle: %s: not a 64-bit Mach-O\n", argv[1]); return 2; }
    memset(&c, 0, sizeof c);
    mi_each_lc(&im, ro_lc, &c);
    if (!c.di || !c.di->rebase_size) { mi_close(&im); return 0; }
    if (c.di->rebase_off > im.size || c.di->rebase_size > im.size - c.di->rebase_off) {
        fprintf(stderr, "rebase_oracle: %s: the rebase stream lies outside the file\n", argv[1]);
        mi_close(&im);
        return 1;
    }
    if (mrb_decode(im.buf + c.di->rebase_off, c.di->rebase_size, c.n, &set, why, sizeof why) != MRB_OK) {
        printf("MALFORMED %s\n", why);
        mi_close(&im);
        return 1;
    }
    for (size_t i = 0; i < set.n; i++)
        printf("%s 0x%08llX %s\n", c.name[set.v[i].seg],
               (unsigned long long)(c.vmaddr[set.v[i].seg] + set.v[i].off), ro_type(set.v[i].type));
    mrb_free(&set);
    mi_close(&im);
    return 0;
}
