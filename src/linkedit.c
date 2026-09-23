/* linkedit.c — see linkedit.h for the contract. */

#include "linkedit.h"

#include <stdint.h>
#include <stdio.h>

#include "mach_compat.h"

int ml_bump(uint32_t *off, uint32_t insert, uint32_t grow) {
    if (*off < insert) return 0;
    if (*off > UINT32_MAX - grow) {
        fprintf(stderr, "ERROR: a __LINKEDIT file offset (%#x) would overflow a "
                        "32-bit field after growing by %#x; refusing rather than wrap\n",
                *off, grow);
        return -1;
    }
    *off += grow;
    return 0;
}

/* One function per member of linkedit.h's ML_PLAIN_OFFSET_LCS, named
 * ml_each_<cmd> by the SAME macro that names it in grow.c's accept bucket
 * (see linkedit.h's own comment on the macro for why). Forward-declared
 * here via the macro too: add a member to ML_PLAIN_OFFSET_LCS without
 * defining its ml_each_<cmd> body below and the build fails at link time
 * (undefined symbol) -- not silently, and not merely a test someone could
 * forget to run. That is what makes this coupling real rather than
 * advisory: grow.c's accept-bucket case labels for this group (see
 * mg_classify_cb) are generated from this same list, so a load command
 * cannot join grow.c's "safe, plain offset" bucket without a matching,
 * present ml_each_<cmd> definition existing right here. */
struct ml_each_ctx {
    ml_off_fn fn;
    void *ctx;
};
#define ML_VISIT(cmd, field, flags) \
    do { if (e->fn(&(field), (cmd), (flags), e->ctx) != 0) return 1; } while (0)

#define ML_DECLARE(cmd) static int ml_each_##cmd(struct load_command *m, struct ml_each_ctx *e);
ML_PLAIN_OFFSET_LCS(ML_DECLARE)
#undef ML_DECLARE

static int ml_each_LC_SYMTAB(struct load_command *m, struct ml_each_ctx *e) {
    struct symtab_command *c = (struct symtab_command *)m;
    ML_VISIT(m->cmd, c->symoff, 0);
    ML_VISIT(m->cmd, c->stroff, 0);
    return 0;
}

static int ml_each_LC_DYSYMTAB(struct load_command *m, struct ml_each_ctx *e) {
    struct dysymtab_command *c = (struct dysymtab_command *)m;
    ML_VISIT(m->cmd, c->tocoff, 0);
    ML_VISIT(m->cmd, c->modtaboff, 0);
    ML_VISIT(m->cmd, c->extrefsymoff, 0);
    ML_VISIT(m->cmd, c->indirectsymoff, 0);
    ML_VISIT(m->cmd, c->extreloff, 0);
    ML_VISIT(m->cmd, c->locreloff, 0);
    return 0;
}

static int ml_each_LC_CODE_SIGNATURE(struct load_command *m, struct ml_each_ctx *e) {
    ML_VISIT(m->cmd, ((struct linkedit_data_command *)m)->dataoff, 0);
    return 0;
}

static int ml_each_LC_DYLIB_CODE_SIGN_DRS(struct load_command *m, struct ml_each_ctx *e) {
    ML_VISIT(m->cmd, ((struct linkedit_data_command *)m)->dataoff, 0);
    return 0;
}

static int ml_each_LC_TWOLEVEL_HINTS(struct load_command *m, struct ml_each_ctx *e) {
    ML_VISIT(m->cmd, ((struct twolevel_hints_command *)m)->offset, 0);
    return 0;
}

static int ml_each_LC_ENCRYPTION_INFO(struct load_command *m, struct ml_each_ctx *e) {
    ML_VISIT(m->cmd, ((struct encryption_info_command *)m)->cryptoff, 0);
    return 0;
}

static int ml_each_LC_ENCRYPTION_INFO_64(struct load_command *m, struct ml_each_ctx *e) {
    ML_VISIT(m->cmd, ((struct encryption_info_command_64 *)m)->cryptoff, 0);
    return 0;
}

/* mi_each_lc callback: visit the __LINKEDIT-resident offset field(s) of one
 * load command. Returns 0 to keep walking, or 1 to stop the walk the instant
 * the visitor does -- for ml_bump_all, an overflow: once one field cannot be
 * trusted, there is no reason to keep patching the rest into what will be a
 * discarded, refused buffer anyway. */
static int ml_each_lc(const struct load_command *lc, void *vctx) {
    struct ml_each_ctx *e = (struct ml_each_ctx *)vctx;
    /* Cast away const so the visitor may write through the command's own
     * fields: permitted by mi_each_lc's contract (see image.h) for anything
     * except cmd/cmdsize/hdr->ncmds, none of which is ever visited. */
    struct load_command *m = (struct load_command *)lc;

    switch (m->cmd) {
    /* Case labels generated from linkedit.h's ML_PLAIN_OFFSET_LCS, dispatch
     * to the like-named ml_each_<cmd> functions defined above -- see that
     * macro's own comment for what this couples and what it deliberately
     * does not. */
#define ML_CASE(cmd) case cmd: return ml_each_##cmd(m, e);
    ML_PLAIN_OFFSET_LCS(ML_CASE)
#undef ML_CASE
    case LC_DYLD_INFO:
    case LC_DYLD_INFO_ONLY: {
        struct dyld_info_command *c = (struct dyld_info_command *)m;
        ML_VISIT(m->cmd, c->rebase_off, 0);
        ML_VISIT(m->cmd, c->bind_off, 0);
        ML_VISIT(m->cmd, c->weak_bind_off, 0);
        ML_VISIT(m->cmd, c->lazy_bind_off, 0);
        ML_VISIT(m->cmd, c->export_off, ML_OFF_EXPORT_TRIE);
        return 0;
    }
    case LC_DYLD_EXPORTS_TRIE:
        ML_VISIT(m->cmd, ((struct linkedit_data_command *)m)->dataoff, ML_OFF_EXPORT_TRIE);
        return 0;
    case LC_FUNCTION_STARTS:
    case LC_DATA_IN_CODE:
    case LC_SEGMENT_SPLIT_INFO:
    case LC_LINKER_OPTIMIZATION_HINT:
    case LC_DYLD_CHAINED_FIXUPS:
        ML_VISIT(m->cmd, ((struct linkedit_data_command *)m)->dataoff, 0);
        return 0;
    default:
        return 0;  /* not a field this table knows about (segments and
                    * LC_MAIN are grow.c's mg_each_fileoff; LC_NOTE and
                    * LC_ATOM_INFO are refused before this ever runs -- see
                    * linkedit.h) */
    }
}
#undef ML_VISIT

int ml_each_off(mi_image *im, ml_off_fn fn, void *ctx) {
    struct ml_each_ctx e = { fn, ctx };
    return mi_each_lc(im, ml_each_lc, &e) ? 0 : -1;
}

struct ml_bump_ctx {
    uint32_t insert;
    uint32_t grow;
};

static int ml_bump_one(uint32_t *off, uint32_t cmd, int flags, void *vctx) {
    struct ml_bump_ctx *ctx = (struct ml_bump_ctx *)vctx;
    (void)cmd; (void)flags;
    return ml_bump(off, ctx->insert, ctx->grow);
}

int ml_bump_all(mi_image *im, uint32_t insert, uint32_t grow) {
    struct ml_bump_ctx ctx = { insert, grow };
    return ml_each_off(im, ml_bump_one, &ctx);
}
