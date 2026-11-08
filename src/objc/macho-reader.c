/* macho-reader.c -- bounded observation of Objective-C producers in a shipped x86_64 slice.
 *
 * What this module observes, and nothing more:
 *   - conventional metadata: classes, metaclasses and categories with their methods (through
 *     the pinned Drydock mml_* walker), selector and class reference slots, and code that
 *     reads those slots;
 *   - objc2 0.6 caches: each CACHED_SEL/CACHED_CLASS static, the literal its fetch call site
 *     passes, and every other code reference to the static (its consumers);
 *   - runtime registration/lookup calls (sel_registerName, NSSelectorFromString,
 *     objc_getClass, ...) whose name argument is a literal in the image;
 *   - calls and jumps into dispatch/allocation entry points;
 *   - calls to class_addMethod, a run-time method registration, which provider.c must attest;
 *   - calls that make or reparent a class at run time (objc_allocateClassPair and its family),
 *     refused as runtime-class-creation wherever they are: such a class has no root this
 *     reader can measure.
 * A class record says when its superclass slot is a measured null (symbol "root": a root class
 * of the artifact's own) or could not be read (symbol "unmeasured"); classify.c decides what that
 * means for R1.
 * It does not decide receivers, guards or availability; those are later stages.
 *
 * Every refusal is a cannot-measure error: no x86_64 slice, malformed/truncated or chained
 * images, an unclassified libobjc/Foundation runtime import, a producer whose argument is not a
 * recognisable literal, a cache whose fetch site is not the supported form, an objc entry point
 * whose address is taken, and undecodable code that a byte sweep cannot clear of references to
 * any of those. Machine code is decoded with Drydock's mx_decode_evex; nothing is executed.
 * An EVEX (AVX-512) instruction is opaque here: it may read and write every general-purpose
 * register, and a store through a one-byte displacement (disp8*N, N unknown) may reach any
 * frame slot.
 *
 * Literal recovery is per-function value propagation over the control-flow graph that direct
 * branches describe: `lea reg, [rip+X]`, register copies, small immediates, and the results of
 * recognised producers (Sel::register_unchecked, objc_getClass, NSString::from_str) and of GOT
 * loads of objc entry points. A value counts only when every direct path agrees -- except at a
 * dispatch call whose paths disagree on its selector or receiver, which is read once per incoming
 * path when every path names both ("Merged calls", path_states); a block
 * reached only indirectly (a switch case) starts unknown. Two indirect entries are modelled:
 * an inline jump table in __text of the one form jump_table_at takes apart whole (its cases
 * start from the state at its jmp, and its bytes are data), and an LSDA landing pad
 * (lsda_sites; its state is what the calls its call-site ranges cover leave, as the unwinder
 * restores callee-saved registers and the frame), unless the function also has an indirect jump
 * that may be some other jump table. Stated limits, not proofs: a switch case that is ALSO
 * reached directly is analysed from its direct predecessors only (jump-table targets in
 * __const are not modelled), and a landing pad in a function whose LSDA this reader cannot
 * take apart (a DWARF-only FDE's, another encoding) stays reached only indirectly. A
 * GOT-loaded entry point held in a register is followed only while every use of it is a call
 * through it (entry_escapes) or a 64-bit spill to a frame slot no escaped frame address reaches,
 * inside a fixed frame, whose only reads are 64-bit reloads into registers the same rule then
 * governs; a store anywhere else, a read of the slot of any other kind, a frame-address escape
 * reaching it, or another value in it at a reload that is called through is cannot-measure.
 * Values spilled to frame slots carry a further stated limit, given with the value kinds below.
 *
 * Each dispatch call also carries its receiver, selector and first-argument operands as the same
 * propagation measured them at the call (report.h ObjcValueForm): which cache, reference slot or
 * literal they came from, which earlier dispatch returned them, or which incoming argument they
 * are -- and "unknown" for anything else, never a guess. Cache uses, selref reads and fetch sites
 * stay separate records; the operand names the cache, so one shared cache read by several
 * callers yields one dispatch row per call site. Receivers are joined to classes later
 * (binding.c, objc_close_sends).
 *
 * Each dispatch call also carries its path conditions (report.h ObjcCond): which earlier
 * dispatches' BOOL results were tested -- `test r8, r8` of that result or a byte copy of it,
 * then jz/jnz -- with which outcome, on every direct path to the call. That is what a
 * respondsToSelector: guard or an isKindOfClass: downcast is made of; deciding that it is one is
 * classify.c's. The dylib load commands of the slice are recorded for the closure check. */
#include "report.h"
#include "image.h"
#include "fat.h"
#include "x86len.h"
#include "ordinals.h"
#include "objc_meth.h"
#include "arch_names.h"
#include "mach_compat.h"
#include "uleb.h"

#include <errno.h>
#include <limits.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifndef LC_DYLD_CHAINED_FIXUPS
#define LC_DYLD_CHAINED_FIXUPS 0x80000034
#endif
#ifndef CPU_SUBTYPE_X86_64_H
#define CPU_SUBTYPE_X86_64_H 8
#endif

#define MAX_LITERAL 4096

enum { REG_RAX = 0, REG_RCX = 1, REG_RDX = 2, REG_RSP = 4, REG_RBP = 5, REG_RSI = 6, REG_RDI = 7 };

/* How a runtime import participates. Anything from libobjc or Foundation's NS*FromString
 * family that is absent from this table is refused rather than assumed harmless. */
typedef enum { IMP_OTHER, IMP_SEL_PRODUCER, IMP_SEL_PRODUCER_NSSTRING, IMP_CLASS_PRODUCER,
               IMP_CLASS_PRODUCER_NSSTRING, IMP_DISPATCH, IMP_MEMORY, IMP_PASSTHROUGH, IMP_INTROSPECT,
               IMP_REGISTRATION, IMP_CLASS_CREATION, IMP_UNCLASSIFIED } ImportRole;

static const struct { const char *name; ImportRole role; } ROLES[] = {
    { "_sel_registerName", IMP_SEL_PRODUCER }, { "_sel_getUid", IMP_SEL_PRODUCER },
    { "_NSSelectorFromString", IMP_SEL_PRODUCER_NSSTRING },
    { "_objc_getClass", IMP_CLASS_PRODUCER }, { "_objc_lookUpClass", IMP_CLASS_PRODUCER },
    { "_objc_getRequiredClass", IMP_CLASS_PRODUCER }, { "_objc_getMetaClass", IMP_CLASS_PRODUCER },
    { "_NSClassFromString", IMP_CLASS_PRODUCER_NSSTRING },
    { "_objc_msgSend", IMP_DISPATCH }, { "_objc_msgSend_stret", IMP_DISPATCH },
    { "_objc_msgSend_fpret", IMP_DISPATCH }, { "_objc_msgSend_fp2ret", IMP_DISPATCH },
    { "_objc_msgSendSuper", IMP_DISPATCH }, { "_objc_msgSendSuper2", IMP_DISPATCH },
    { "_objc_msgSendSuper_stret", IMP_DISPATCH }, { "_objc_msgSendSuper2_stret", IMP_DISPATCH },
    { "_objc_alloc", IMP_DISPATCH }, { "_objc_alloc_init", IMP_DISPATCH },
    { "_objc_allocWithZone", IMP_DISPATCH }, { "_objc_opt_new", IMP_DISPATCH },
    { "_objc_opt_class", IMP_DISPATCH }, { "_objc_opt_self", IMP_DISPATCH },
    { "_objc_opt_isKindOfClass", IMP_DISPATCH }, { "_objc_opt_respondsToSelector", IMP_DISPATCH },
    { "_objc_retain", IMP_PASSTHROUGH }, { "_objc_release", IMP_MEMORY },
    { "_objc_autorelease", IMP_PASSTHROUGH }, { "_objc_retainAutorelease", IMP_PASSTHROUGH },
    { "_objc_retainAutoreleasedReturnValue", IMP_PASSTHROUGH },
    { "_objc_autoreleaseReturnValue", IMP_PASSTHROUGH },
    { "_objc_retainAutoreleaseReturnValue", IMP_PASSTHROUGH },
    { "_objc_unsafeClaimAutoreleasedReturnValue", IMP_PASSTHROUGH },
    { "_objc_claimAutoreleasedReturnValue", IMP_PASSTHROUGH },
    { "_objc_storeStrong", IMP_MEMORY }, { "_objc_retainBlock", IMP_MEMORY },
    { "_objc_autoreleasePoolPush", IMP_MEMORY }, { "_objc_autoreleasePoolPop", IMP_MEMORY },
    { "_objc_loadWeakRetained", IMP_MEMORY }, { "_objc_initWeak", IMP_MEMORY },
    { "_objc_destroyWeak", IMP_MEMORY }, { "_objc_storeWeak", IMP_MEMORY },
    { "_objc_copyWeak", IMP_MEMORY }, { "_objc_moveWeak", IMP_MEMORY },
    { "_objc_enumerationMutation", IMP_MEMORY }, { "_objc_terminate", IMP_MEMORY },
    { "_objc_begin_catch", IMP_MEMORY }, { "_objc_end_catch", IMP_MEMORY },
    { "_objc_exception_throw", IMP_MEMORY }, { "_objc_exception_rethrow", IMP_MEMORY },
    { "_objc_sync_enter", IMP_MEMORY }, { "_objc_sync_exit", IMP_MEMORY },
    { "_sel_getName", IMP_INTROSPECT }, { "_class_getName", IMP_INTROSPECT },
    { "_class_isMetaClass", IMP_INTROSPECT }, { "_object_getClass", IMP_INTROSPECT },
    { "_object_getClassName", IMP_INTROSPECT }, { "_class_getSuperclass", IMP_INTROSPECT },
    { "_sel_isEqual", IMP_INTROSPECT }, { "_NSStringFromSelector", IMP_INTROSPECT },
    { "_NSStringFromClass", IMP_INTROSPECT },
    { "_class_copyMethodList", IMP_INTROSPECT }, { "_method_getName", IMP_INTROSPECT },
    /* Adds a method at run time: recorded, and cannot-measure unless provider.c attests the code. */
    { "_class_addMethod", IMP_REGISTRATION },
    /* Makes or reparents a class at run time: its root is unmeasurable, so always cannot-measure. */
    { "_objc_allocateClassPair", IMP_CLASS_CREATION }, { "_objc_registerClassPair", IMP_CLASS_CREATION },
    { "_objc_duplicateClass", IMP_CLASS_CREATION }, { "_objc_readClassPair", IMP_CLASS_CREATION },
    { "_class_setSuperclass", IMP_CLASS_CREATION },
};

static ImportRole role_of(const char *sym, const char *dylib) {
    size_t i;
    for (i = 0; i < sizeof ROLES / sizeof ROLES[0]; i++)
        if (!strcmp(ROLES[i].name, sym)) return ROLES[i].role;
    if (dylib && strstr(dylib, "/libobjc.")) return IMP_UNCLASSIFIED;
    if (!strncmp(sym, "_objc_", 6) || !strncmp(sym, "_sel_", 5) || !strncmp(sym, "_class_", 7) ||
        !strncmp(sym, "_method_", 8) || !strncmp(sym, "_imp_", 5) || !strncmp(sym, "_object_", 8) ||
        !strncmp(sym, "_protocol_", 10) || !strncmp(sym, "_ivar_", 6) ||
        (!strncmp(sym, "_NS", 3) && strstr(sym, "FromString")))
        return IMP_UNCLASSIFIED;
    return IMP_OTHER;
}

/* ---- slice model ------------------------------------------------------------------------ */

typedef struct { uint64_t addr; const char *name; } Sym;
typedef struct { uint64_t addr; const char *name; ImportRole role; const char *lib; } Ptr;  /* stub/GOT/bind; lib: lib_of */
typedef struct { uint64_t addr, size, off; uint32_t flags; char seg[17], sect[17]; } Sect;
typedef struct {
    uint64_t addr; const char *symbol; int kind;   /* 1 selector, 2 class */
    char *literal; uint64_t fetch_site; int conflict;
} Cache;

typedef struct {
    ObjcAnalysis *a;
    char slice[32];
    mi_image im;
    mml_resolver res;
    int res_open;
    Sect *sects; size_t nsects;
    struct nlist_64 *nl; uint32_t nsyms; const char *strtab; uint32_t strsize;
    Sym *syms; size_t nsym;             /* defined, sorted by address */
    Ptr *ptrs; size_t nptrs;            /* stub/GOT/lazy pointer -> import, sorted */
    Ptr *binds; size_t nbinds;          /* bound data slot -> symbol, sorted */
    Cache *caches; size_t ncaches;      /* sorted by addr */
    uint64_t fetch_sel[8], fetch_class[8]; size_t nfetch_sel, nfetch_class;
    uint64_t wrap_sel[8], wrap_nsstr[8]; size_t nwrap_sel, nwrap_nsstr;   /* register_unchecked, from_str */
    uint64_t *starts; size_t nstarts;   /* function starts, sorted */
    struct { uint64_t lo, hi; } *dice; size_t ndice;
    uint64_t *fetch_arg_sites; size_t nfas, capfas;
    const char *cur_fn;                 /* symbol of the function being scanned, or NULL */
    struct { uint64_t jmp, target; } *jt; size_t njt, capjt;   /* the scanned function's inline jump tables */
    int status;
    int quiet;                          /* an image view: record no dylibs */
} Slice;

static int fail(Slice *s, const char *code, uint64_t addr, const char *fmt, const char *arg) {
    s->status = objc_fail(s->a, code, s->slice, addr, fmt, arg ? arg : "");
    return OBJC_CANNOT_MEASURE;
}

static const Sect *sect_of(const Slice *s, uint64_t va) {
    size_t i;
    for (i = 0; i < s->nsects; i++)
        if (va >= s->sects[i].addr && va - s->sects[i].addr < s->sects[i].size) return &s->sects[i];
    return NULL;
}

/* File bytes for [va, va+len) inside one section that has file backing, or NULL. */
static const uint8_t *bytes_at(const Slice *s, uint64_t va, uint64_t len) {
    const Sect *x = sect_of(s, va);
    uint8_t type;
    if (!x) return NULL;
    type = x->flags & SECTION_TYPE;
    if (type == S_ZEROFILL || type == S_GB_ZEROFILL || type == S_THREAD_LOCAL_ZEROFILL) return NULL;
    if (len > x->size - (va - x->addr)) return NULL;
    if (x->off + (va - x->addr) > s->im.size || len > s->im.size - (x->off + (va - x->addr))) return NULL;
    return s->im.buf + x->off + (va - x->addr);
}

static int read64(const Slice *s, uint64_t va, uint64_t *out) {
    const uint8_t *p = bytes_at(s, va, 8);
    if (!p) return -1;
    memcpy(out, p, 8);
    return 0;
}

/* A NUL-terminated printable literal at va, within its section. */
static int literal_at(const Slice *s, uint64_t va, char *out, size_t outsz) {
    const Sect *x = sect_of(s, va);
    const uint8_t *p;
    uint64_t room, i;
    if (!x || !(p = bytes_at(s, va, 1))) return -1;
    room = x->size - (va - x->addr);
    for (i = 0; i < room && i < outsz; i++) {
        if (!p[i]) { if (!i) return -1; out[i] = 0; return 0; }
        if (p[i] < 0x21 || p[i] > 0x7e) return -1;
        out[i] = (char)p[i];
    }
    return -1;
}

/* A constant CFString (__cfstring: isa, flags, ptr, length) holding 8-bit printable text. */
static int cfstring_at(const Slice *s, uint64_t va, char *out, size_t outsz) {
    const Sect *x = sect_of(s, va);
    const uint8_t *p = bytes_at(s, va, 32);
    uint64_t flags, ptr, len;
    if (!x || !p || strcmp(x->sect, "__cfstring")) return -1;
    memcpy(&flags, p + 8, 8); memcpy(&ptr, p + 16, 8); memcpy(&len, p + 24, 8);
    if ((flags & 0xff) != 0xc8 || len == 0 || len >= outsz) return -1;
    if (literal_at(s, ptr, out, outsz) || strlen(out) != len) return -1;
    return 0;
}

static int cmp_u64(const void *x, const void *y) {
    uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y;
    return a < b ? -1 : a > b;
}
static int cmp_sym(const void *x, const void *y) {
    const Sym *a = x, *b = y;
    if (a->addr != b->addr) return a->addr < b->addr ? -1 : 1;
    return strcmp(a->name, b->name);
}
static int cmp_ptr(const void *x, const void *y) {
    const Ptr *a = x, *b = y;
    return a->addr < b->addr ? -1 : a->addr > b->addr;
}
static int cmp_cache(const void *x, const void *y) {
    const Cache *a = x, *b = y;
    return a->addr < b->addr ? -1 : a->addr > b->addr;
}

static const Ptr *find_ptr(const Ptr *v, size_t n, uint64_t addr) {
    size_t lo = 0, hi = n;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (v[mid].addr == addr) return &v[mid];
        if (v[mid].addr < addr) lo = mid + 1; else hi = mid;
    }
    return NULL;
}
static Cache *find_cache(Slice *s, uint64_t addr) {
    size_t lo = 0, hi = s->ncaches;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (s->caches[mid].addr == addr) return &s->caches[mid];
        if (s->caches[mid].addr < addr) lo = mid + 1; else hi = mid;
    }
    return NULL;
}
static int is_fetch(const Slice *s, uint64_t addr) {
    size_t i;
    for (i = 0; i < s->nfetch_sel; i++) if (s->fetch_sel[i] == addr) return OBJC_FETCH_SEL;
    for (i = 0; i < s->nfetch_class; i++) if (s->fetch_class[i] == addr) return OBJC_FETCH_CLASS;
    return 0;
}
/* Whether `site` lies inside a recognised fetch or producer-wrapper function body, whose name
 * argument is a parameter attributed at each call site instead. */
static int inside_fetch(const Slice *s, uint64_t site) {
    size_t i, lo = 0, hi = s->nstarts;
    uint64_t start;
    while (lo < hi) { size_t mid = lo + (hi - lo) / 2; if (s->starts[mid] <= site) lo = mid + 1; else hi = mid; }
    if (!lo) return 0;
    start = s->starts[lo - 1];
    for (i = 0; i < s->nfetch_sel; i++) if (s->fetch_sel[i] == start) return 1;
    for (i = 0; i < s->nfetch_class; i++) if (s->fetch_class[i] == start) return 1;
    for (i = 0; i < s->nwrap_sel; i++) if (s->wrap_sel[i] == start) return 1;
    return 0;
}

static int add_ev(Slice *s, ObjcEvidenceKind kind, uint64_t addr, uint64_t target,
                  const char *owner, const char *mkind, const char *sel, const char *name,
                  const char *symbol) {
    ObjcEvidence e;
    memset(&e, 0, sizeof e);
    e.kind = kind; e.slice = s->slice; e.address = addr; e.target = target;
    e.owner = (char *)owner; e.method_kind = (char *)mkind; e.selector = (char *)sel;
    e.name = (char *)name; e.symbol = (char *)symbol; e.function = (char *)s->cur_fn;
    e.receiver.form = e.sel.form = e.arg.form = OBJC_VAL_NONE;
    if (objc_add_evidence(s->a, &e)) { s->status = OBJC_CANNOT_MEASURE; return -1; }
    return 0;
}

/* A dispatch call with its receiver, selector and first-argument operands; `incoming` is the
 * predecessor path's last instruction for one path of a split call, else 0. */
static int add_dispatch(Slice *s, uint64_t addr, uint64_t target, const char *callee, const char *tail,
                        const ObjcValue *recv, const ObjcValue *sel, const ObjcValue *arg,
                        const ObjcCond *conds, size_t nconds, uint64_t incoming) {
    ObjcEvidence e;
    memset(&e, 0, sizeof e);
    memcpy(e.conds, conds, nconds * sizeof *conds); e.nconds = nconds;
    e.incoming = incoming;
    e.kind = OBJC_EV_DISPATCH_CALL; e.slice = s->slice; e.address = addr; e.target = target;
    e.name = (char *)callee; e.symbol = (char *)tail; e.function = (char *)s->cur_fn;
    e.receiver = *recv; e.sel = *sel; e.arg = *arg;
    if (objc_add_evidence(s->a, &e)) { s->status = OBJC_CANNOT_MEASURE; return -1; }
    return 0;
}

/* ---- load commands, symbols, pointers --------------------------------------------------- */

typedef struct {
    Slice *s;
    const struct symtab_command *st;
    const struct dysymtab_command *dst;
    const struct dyld_info_command *di;
    const struct linkedit_data_command *dice;
    const char *dylibs[256]; int ndylibs;
    int chained, bad;
} LcCtx;

static int lc_cb(const struct load_command *lc, void *ctx_) {
    LcCtx *c = ctx_;
    Slice *s = c->s;
    switch (lc->cmd) {
    case LC_SEGMENT_64: {
        const struct segment_command_64 *sg = (const void *)lc;
        const struct section_64 *x = (const void *)(sg + 1);
        uint32_t i;
        Sect *g = realloc(s->sects, (s->nsects + sg->nsects + 1) * sizeof *g);
        if (!g) { c->bad = 1; return 1; }
        s->sects = g;
        for (i = 0; i < sg->nsects; i++) {
            Sect *d = &s->sects[s->nsects++];
            d->addr = x[i].addr; d->size = x[i].size; d->off = x[i].offset; d->flags = x[i].flags;
            memcpy(d->seg, x[i].segname, 16); d->seg[16] = 0;
            memcpy(d->sect, x[i].sectname, 16); d->sect[16] = 0;
        }
        break;
    }
    case LC_SYMTAB: c->st = (const void *)lc; break;
    case LC_DYSYMTAB: c->dst = (const void *)lc; break;
    case LC_DYLD_INFO: case LC_DYLD_INFO_ONLY: c->di = (const void *)lc; break;
    case LC_DATA_IN_CODE: c->dice = (const void *)lc; break;
    case LC_DYLD_CHAINED_FIXUPS: c->chained = 1; break;
    case LC_LOAD_DYLIB: case LC_LOAD_WEAK_DYLIB: case LC_REEXPORT_DYLIB: case LC_LAZY_LOAD_DYLIB:
    case LC_LOAD_UPWARD_DYLIB: {
        const struct dylib_command *d = (const void *)lc;
        const char *name = mo_lc_str_at(lc, d->dylib.name.offset);
        const char *how = lc->cmd == LC_LOAD_DYLIB ? "load" : lc->cmd == LC_LOAD_WEAK_DYLIB ? "weak" :
                          lc->cmd == LC_REEXPORT_DYLIB ? "reexport" : lc->cmd == LC_LAZY_LOAD_DYLIB ? "lazy" : "upward";
        if (c->ndylibs < 256) c->dylibs[c->ndylibs++] = name;
        if (!s->quiet && objc_add_dylib(s->a, s->slice, name ? name : "", how)) { c->bad = 1; return 1; }
        break;
    }
    case LC_RPATH: {
        const struct rpath_command *r = (const void *)lc;
        const char *p = mo_lc_str_at(lc, r->path.offset);
        if (!s->quiet && objc_strv_push(&s->a->rpaths, &s->a->n_rpaths, p ? p : "")) { c->bad = 1; return 1; }
        break;
    }
    }
    return 0;
}

static const char *ordinal_dylib(const LcCtx *c, int ordinal) {
    return ordinal >= 1 && ordinal <= c->ndylibs ? c->dylibs[ordinal - 1] : NULL;
}
/* What an import binds to: its library's install name, or, for a special ordinal, a parenthesized
 * account of the lookup (never a path, so it never matches a load command). */
static const char *lib_of(const LcCtx *c, int ordinal) {
    const char *d = ordinal_dylib(c, ordinal);
    if (d) return d;
    if (ordinal == 0) return "(this image)";
    if (ordinal == -1 || ordinal == EXECUTABLE_ORDINAL) return "(the main executable)";
    if (ordinal == -2 || ordinal == DYNAMIC_LOOKUP_ORDINAL) return "(flat lookup)";
    return "(no library)";
}

typedef struct { Slice *s; LcCtx *c; size_t cap; int oom; } BindCtx;

static void bind_cb(const mo_bind_state *st, void *ctx_) {
    BindCtx *b = ctx_;
    Slice *s = b->s;
    uint64_t seg_va, k;
    if (b->oom || !st->symbol || st->seg < 0 || st->seg >= s->res.nsegs || st->count > MRB_MAX_SLOTS) return;
    seg_va = s->res.segs[st->seg].vmaddr;
    for (k = 0; k < (st->count ? st->count : 1); k++) {
        Ptr *p;
        if (s->nbinds == b->cap) {
            Ptr *g = realloc(s->binds, (b->cap = b->cap ? b->cap * 2 : 1024) * sizeof *g);
            if (!g) { b->oom = 1; return; }
            s->binds = g;
        }
        p = &s->binds[s->nbinds++];
        p->addr = seg_va + st->offset + k * (8 + st->skip);
        p->name = st->symbol;
        p->role = role_of(st->symbol, ordinal_dylib(b->c, st->ordinal));
        p->lib = lib_of(b->c, st->ordinal);
    }
}

static int load_tables(Slice *s, LcCtx *c) {
    size_t i, cap = 0;
    char why[200] = "";
    mi_each_lc(&s->im, lc_cb, c);
    if (c->bad) return fail(s, "out-of-memory", 0, "%s", "sections");
    if (c->chained) return fail(s, "unsupported-chained-fixups", 0, "%s", "LC_DYLD_CHAINED_FIXUPS");
    if (mml_resolver_open(&s->im, &s->res, why, sizeof why) != MML_OK)
        return fail(s, "malformed-macho", 0, "%s", why);
    s->res_open = 1;
    if (!c->st) return fail(s, "no-symbol-table", 0, "%s", "LC_SYMTAB absent");
    if (!mo_fits(c->st->symoff, (uint64_t)c->st->nsyms * sizeof(struct nlist_64), s->im.size) ||
        !mo_fits(c->st->stroff, c->st->strsize, s->im.size))
        return fail(s, "malformed-macho", 0, "%s", "symbol table outside the file");
    s->nl = (struct nlist_64 *)(s->im.buf + c->st->symoff);
    s->nsyms = c->st->nsyms;
    s->strtab = (const char *)s->im.buf + c->st->stroff;
    s->strsize = c->st->strsize;
    if (s->strsize == 0 || s->strtab[s->strsize - 1] != 0)
        return fail(s, "malformed-macho", 0, "%s", "string table is not NUL-terminated");
    if (!(s->syms = malloc((s->nsyms + 1) * sizeof *s->syms))) return fail(s, "out-of-memory", 0, "%s", "symbols");
    for (i = 0; i < s->nsyms; i++) {
        const struct nlist_64 *n = &s->nl[i];
        if (n->n_type & N_STAB || (n->n_type & N_TYPE) != N_SECT) continue;
        if (n->n_un.n_strx >= s->strsize) return fail(s, "malformed-macho", 0, "%s", "symbol name outside string table");
        s->syms[s->nsym].addr = n->n_value;
        s->syms[s->nsym].name = s->strtab + n->n_un.n_strx;
        s->nsym++;
    }
    qsort(s->syms, s->nsym, sizeof *s->syms, cmp_sym);

    /* Stubs, GOT and lazy pointers through the indirect symbol table. */
    if (c->dst) {
        const uint32_t *ind;
        if (!mo_fits(c->dst->indirectsymoff, (uint64_t)c->dst->nindirectsyms * 4, s->im.size))
            return fail(s, "malformed-macho", 0, "%s", "indirect symbol table outside the file");
        ind = (const uint32_t *)(s->im.buf + c->dst->indirectsymoff);
        for (i = 0; i < s->nsects; i++) {
            const Sect *x = &s->sects[i];
            uint8_t type = x->flags & SECTION_TYPE;
            uint64_t stride, n, k;
            uint32_t first;
            if (type == S_SYMBOL_STUBS) {
                const struct section_64 *raw = mi_find_section(&s->im, x->seg, x->sect);
                stride = raw ? raw->reserved2 : 0;
                first = raw ? raw->reserved1 : 0;
                if (!stride) return fail(s, "malformed-macho", x->addr, "%s", "stub section without stub size");
            } else if (type == S_NON_LAZY_SYMBOL_POINTERS || type == S_LAZY_SYMBOL_POINTERS) {
                const struct section_64 *raw = mi_find_section(&s->im, x->seg, x->sect);
                stride = 8; first = raw ? raw->reserved1 : 0;
            } else continue;
            n = x->size / stride;
            for (k = 0; k < n; k++) {
                uint32_t idx;
                const char *name; int ord;
                Ptr *p;
                if (first + k >= c->dst->nindirectsyms)
                    return fail(s, "malformed-macho", x->addr, "%s", "indirect index past table");
                idx = ind[first + k];
                if (idx & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                if (idx >= s->nsyms || s->nl[idx].n_un.n_strx >= s->strsize)
                    return fail(s, "malformed-macho", x->addr, "%s", "indirect symbol out of range");
                name = s->strtab + s->nl[idx].n_un.n_strx;
                ord = GET_LIBRARY_ORDINAL(s->nl[idx].n_desc);
                if (s->nptrs == cap) {
                    Ptr *g = realloc(s->ptrs, (cap = cap ? cap * 2 : 256) * sizeof *g);
                    if (!g) return fail(s, "out-of-memory", 0, "%s", "stubs");
                    s->ptrs = g;
                }
                p = &s->ptrs[s->nptrs++];
                p->addr = x->addr + k * stride; p->name = name;
                p->role = role_of(name, ordinal_dylib(c, ord));
                p->lib = lib_of(c, ord);
            }
        }
        qsort(s->ptrs, s->nptrs, sizeof *s->ptrs, cmp_ptr);
    }

    /* Data slots bound to symbols: external class references, among others. */
    if (c->di) {
        BindCtx b; b.s = s; b.c = c; b.cap = 0; b.oom = 0;
        if ((c->di->bind_size && (!mo_fits(c->di->bind_off, c->di->bind_size, s->im.size) ||
             mo_bind_observe(s->im.buf + c->di->bind_off, c->di->bind_size, "bind", bind_cb, &b))) ||
            (c->di->weak_bind_size && (!mo_fits(c->di->weak_bind_off, c->di->weak_bind_size, s->im.size) ||
             mo_bind_observe(s->im.buf + c->di->weak_bind_off, c->di->weak_bind_size, "weak bind", bind_cb, &b))))
            return fail(s, "malformed-macho", 0, "%s", "bind stream does not decode");
        if (b.oom) return fail(s, "out-of-memory", 0, "%s", "binds");
        qsort(s->binds, s->nbinds, sizeof *s->binds, cmp_ptr);
    }

    if (c->dice && c->dice->datasize) {
        const struct data_in_code_entry *d;
        uint64_t text_va = 0, text_off = 0;
        const struct segment_command_64 *t = mi_find_segment(&s->im, "__TEXT");
        if (!t || !mo_fits(c->dice->dataoff, c->dice->datasize, s->im.size))
            return fail(s, "malformed-macho", 0, "%s", "LC_DATA_IN_CODE outside the file");
        text_va = t->vmaddr; text_off = t->fileoff;
        d = (const void *)(s->im.buf + c->dice->dataoff);
        s->ndice = c->dice->datasize / sizeof *d;
        if (!(s->dice = malloc((s->ndice + 1) * sizeof *s->dice))) return fail(s, "out-of-memory", 0, "%s", "dice");
        for (i = 0; i < s->ndice; i++) {
            s->dice[i].lo = text_va + (d[i].offset - text_off);
            s->dice[i].hi = s->dice[i].lo + d[i].length;
        }
        qsort(s->dice, s->ndice, sizeof *s->dice, cmp_u64);
    }

    /* Function starts: decoded by the resolver; else every instruction section starts one. */
    {
        size_t n = s->res.nstarts > 0 ? (size_t)s->res.nstarts : 0;
        if (!(s->starts = malloc((n + s->nsects + 1) * sizeof *s->starts))) return fail(s, "out-of-memory", 0, "%s", "starts");
        if (n) memcpy(s->starts, s->res.starts, n * sizeof *s->starts);
        for (i = 0; i < s->nsects; i++)
            if (s->sects[i].flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS))
                s->starts[n++] = s->sects[i].addr;
        qsort(s->starts, n, sizeof *s->starts, cmp_u64);
        s->nstarts = 0;
        for (i = 0; i < n; i++)
            if (!s->nstarts || s->starts[s->nstarts - 1] != s->starts[i]) s->starts[s->nstarts++] = s->starts[i];
    }

    /* objc2 caches and fetch functions, by symbol. */
    {
        size_t capc = 0;
        for (i = 0; i < s->nsym; i++) {
            const char *nm = s->syms[i].name;
            int k;
            if (nm[0] != '_' || nm[1] != '_' || nm[2] != 'R') continue;
            if ((k = objc_binding_cache_kind(nm))) {
                if (s->ncaches == capc) {
                    Cache *g = realloc(s->caches, (capc = capc ? capc * 2 : 64) * sizeof *g);
                    if (!g) return fail(s, "out-of-memory", 0, "%s", "caches");
                    s->caches = g;
                }
                memset(&s->caches[s->ncaches], 0, sizeof *s->caches);
                s->caches[s->ncaches].addr = s->syms[i].addr;
                s->caches[s->ncaches].symbol = nm;
                s->caches[s->ncaches].kind = k;
                s->ncaches++;
            } else if (strstr(nm, "5fetch") || strstr(nm, "18register_unchecked") || strstr(nm, "8from_str")) {
                ObjcFetchForm f = objc_binding_fetch_form(nm);
                uint64_t ad = s->syms[i].addr;
                if (f == OBJC_FETCH_SEL && s->nfetch_sel < 8) s->fetch_sel[s->nfetch_sel++] = ad;
                if (f == OBJC_FETCH_CLASS && s->nfetch_class < 8) s->fetch_class[s->nfetch_class++] = ad;
                if (f == OBJC_WRAP_SEL_CSTR && s->nwrap_sel < 8) s->wrap_sel[s->nwrap_sel++] = ad;
                if (f == OBJC_WRAP_NSSTRING && s->nwrap_nsstr < 8) s->wrap_nsstr[s->nwrap_nsstr++] = ad;
            }
        }
        qsort(s->caches, s->ncaches, sizeof *s->caches, cmp_cache);
        for (i = 1; i < s->ncaches; i++)
            if (s->caches[i].addr == s->caches[i - 1].addr)
                return fail(s, "cache-alias", s->caches[i].addr, "%s", s->caches[i].symbol);
    }
    return s->status;
}

/* ---- conventional Objective-C metadata -------------------------------------------------- */

static const char *bound_name(const Slice *s, uint64_t slot) {
    const Ptr *p = find_ptr(s->binds, s->nbinds, slot);
    return p ? p->name : NULL;
}

/* The class name a class_t at va carries (through class_ro_t), or NULL. */
static int class_name(const Slice *s, uint64_t cls, char *out, size_t outsz) {
    uint64_t data, name;
    if (read64(s, cls + 32, &data)) return -1;
    data &= 0x00007ffffffffff8ULL;
    if (read64(s, data + 24, &name)) return -1;
    return literal_at(s, name, out, outsz);
}

/* A class reference: a bound "_OBJC_CLASS_$_Name" / "_OBJC_METACLASS_$_Name", or a local class. */
static int class_ref_name(const Slice *s, uint64_t slot, char *out, size_t outsz, int *meta) {
    const char *b = bound_name(s, slot);
    uint64_t v;
    *meta = 0;
    if (b) {
        if (!strncmp(b, "_OBJC_CLASS_$_", 14)) { snprintf(out, outsz, "%s", b + 14); return 0; }
        if (!strncmp(b, "_OBJC_METACLASS_$_", 18)) { *meta = 1; snprintf(out, outsz, "%s", b + 18); return 0; }
        return -1;
    }
    if (read64(s, slot, &v) || !v) return -1;
    return class_name(s, v, out, outsz);
}

typedef struct { uint64_t slot; char owner[MAX_LITERAL]; const char *kind; char category[MAX_LITERAL]; } ListOwner;

static int metadata(Slice *s) {
    size_t i, j;
    char name[MAX_LITERAL], other[MAX_LITERAL], sel[MAX_LITERAL];
    mml_walk w;
    ListOwner *own = NULL; size_t nown = 0, capown = 0;
    int rc, meta;

    for (i = 0; i < s->nsects; i++) {
        const Sect *x = &s->sects[i];
        int classlist = !strcmp(x->sect, "__objc_classlist") || !strcmp(x->sect, "__objc_nlclslist");
        int catlist = !strcmp(x->sect, "__objc_catlist") || !strcmp(x->sect, "__objc_nlcatlist");
        int selrefs = !strcmp(x->sect, "__objc_selrefs");
        int classrefs = !strcmp(x->sect, "__objc_classrefs") || !strcmp(x->sect, "__objc_superrefs");
        uint64_t k;
        if (!strncmp(x->sect, "__objc_", 7) && strcmp(x->seg, "__DATA") && strcmp(x->seg, "__DATA_CONST") &&
            strcmp(x->seg, "__TEXT"))
            return fail(s, "unsupported-objc-metadata", x->addr, "objc section in segment %s", x->seg);
        if (!strcmp(x->sect, "__objc_imageinfo") && x->size >= 8) {
            const uint8_t *p = bytes_at(s, x->addr, 8);
            uint32_t flags;
            if (!p) return fail(s, "malformed-macho", x->addr, "%s", "__objc_imageinfo");
            memcpy(&flags, p + 4, 4);
            if (flags & 1) return fail(s, "unsupported-objc-metadata", x->addr, "%s", "fix-and-continue image");
        }
        if (!(classlist || catlist || selrefs || classrefs)) continue;
        if (x->size % 8) return fail(s, "malformed-objc-metadata", x->addr, "%s", x->sect);
        for (k = 0; k < x->size; k += 8) {
            uint64_t slot = x->addr + k, v;
            if (read64(s, slot, &v)) return fail(s, "malformed-objc-metadata", slot, "%s", x->sect);
            if (selrefs) {
                if (literal_at(s, v, sel, sizeof sel))
                    return fail(s, "malformed-objc-metadata", slot, "%s", "selector reference without a name");
                if (add_ev(s, OBJC_EV_SELREF, slot, 0, NULL, NULL, sel, NULL, NULL)) return s->status;
            } else if (classrefs) {
                if (class_ref_name(s, slot, name, sizeof name, &meta))
                    return fail(s, "malformed-objc-metadata", slot, "%s", "class reference without a class");
                if (add_ev(s, OBJC_EV_CLASSREF, slot, 0, NULL, meta ? "+" : "-", NULL, name, NULL)) return s->status;
            } else if (classlist) {
                uint64_t data, ro, isa, super;
                const char *sup = NULL, *rootness = NULL;
                if (class_name(s, v, name, sizeof name))
                    return fail(s, "malformed-objc-metadata", slot, "%s", "class without a name");
                if (bound_name(s, v + 8)) {
                    const char *b = bound_name(s, v + 8);
                    sup = !strncmp(b, "_OBJC_CLASS_$_", 14) ? b + 14 : NULL;
                    if (!sup) rootness = "unmeasured";
                } else if (read64(s, v + 8, &super)) rootness = "unmeasured";
                else if (!super) rootness = "root";
                else if (!class_name(s, super, other, sizeof other)) sup = other;
                else rootness = "unmeasured";
                if (add_ev(s, OBJC_EV_CLASS_DEF, v, 0, sup, NULL, NULL, name, rootness)) return s->status;
                if (read64(s, v + 32, &data)) return fail(s, "malformed-objc-metadata", v, "%s", "class data");
                ro = data & 0x00007ffffffffff8ULL;
                if (nown + 2 > capown) {
                    ListOwner *g = realloc(own, (capown = capown ? capown * 2 : 64) * sizeof *g);
                    if (!g) { free(own); return fail(s, "out-of-memory", 0, "%s", "owners"); }
                    own = g;
                }
                own[nown].slot = ro + 32; snprintf(own[nown].owner, MAX_LITERAL, "%s", name);
                own[nown].kind = "-"; own[nown].category[0] = 0; nown++;
                if (!read64(s, v, &isa) && isa && !read64(s, isa + 32, &data)) {
                    own[nown].slot = (data & 0x00007ffffffffff8ULL) + 32;
                    snprintf(own[nown].owner, MAX_LITERAL, "%s", name);
                    own[nown].kind = "+"; own[nown].category[0] = 0; nown++;
                }
            } else {
                uint64_t nm;
                if (read64(s, v, &nm) || literal_at(s, nm, other, sizeof other))
                    return fail(s, "malformed-objc-metadata", v, "%s", "category without a name");
                if (class_ref_name(s, v + 8, name, sizeof name, &meta))
                    return fail(s, "malformed-objc-metadata", v, "%s", "category without a target class");
                if (add_ev(s, OBJC_EV_CATEGORY_DEF, v, 0, name, NULL, NULL, other, NULL)) return s->status;
                if (nown + 2 > capown) {
                    ListOwner *g = realloc(own, (capown = capown ? capown * 2 : 64) * sizeof *g);
                    if (!g) { free(own); return fail(s, "out-of-memory", 0, "%s", "owners"); }
                    own = g;
                }
                for (j = 0; j < 2; j++) {
                    own[nown].slot = v + (j ? 24 : 16);
                    snprintf(own[nown].owner, MAX_LITERAL, "%s", name);
                    own[nown].kind = j ? "+" : "-";
                    snprintf(own[nown].category, MAX_LITERAL, "%s", other);
                    nown++;
                }
            }
        }
    }

    /* Methods through Drydock's walker; each list is attributed by the slot that names it. */
    memset(&w, 0, sizeof w);
    if ((rc = mml_walk_image(&s->im, &w)) != MML_OK) {
        free(own);
        return fail(s, rc == MML_CHAINED ? "unsupported-chained-fixups" : "malformed-objc-metadata", 0,
                    "%s", w.why);
    }
    for (i = 0; i < w.n; i++) {
        const mml_ref *r = &w.refs[i];
        const ListOwner *o = NULL;
        uint32_t e;
        char why[160];
        if (r->owner == MML_PROTOCOL) continue;   /* declarations, not implementations */
        for (j = 0; j < nown; j++) {
            const uint8_t *p = bytes_at(s, own[j].slot, 8);
            if (p && (uint64_t)(p - s->im.buf) == r->slot_off) { o = &own[j]; break; }
        }
        if (!o) { free(own); mml_walk_free(&w); return fail(s, "malformed-objc-metadata", r->list_va, "%s", "method list without an owner"); }
        for (e = 0; e < r->count; e++) {
            mml_entry me;
            if (mml_entry_at(&s->res, r, e, &me, why, sizeof why) != MML_OK ||
                literal_at(s, me.name, sel, sizeof sel)) {
                free(own); mml_walk_free(&w);
                return fail(s, "malformed-objc-metadata", r->list_va, "%s", "method entry");
            }
            if (add_ev(s, OBJC_EV_METHOD_DEF, r->list_va, me.imp, o->owner, o->kind, sel,
                       o->category[0] ? o->category : NULL, NULL)) { free(own); mml_walk_free(&w); return s->status; }
        }
    }
    free(own);
    mml_walk_free(&w);
    return s->status;
}

/* ---- machine code ----------------------------------------------------------------------- */

typedef struct {
    int len, map, vexmap, rex, op, modrm, mod, reg, rm, riprel, f2, f3, p66;
    int dispscaled;   /* an EVEX disp8: mdisp is the raw byte, the offset disp8*N for an unknown N */
    int64_t disp, imm, mdisp;
    int immlen, sib, sibbase, sibindex, sibscale;   /* sibbase -1: none (disp32); sibindex -1: none */
    uint64_t next, riptarget;
} Ins;

static int decode(const uint8_t *code, size_t avail, uint64_t ip, Ins *o) {
    mx_insn m;
    int i = 0;
    memset(o, 0, sizeof *o);
    if (mx_decode_evex(code, avail, &m) != 1 || m.len <= 0) return -1;
    o->len = m.len; o->next = ip + (uint64_t)m.len;
    while (i < m.len) {
        uint8_t b = code[i];
        if (b == 0x66) o->p66 = 1;
        else if (b == 0xF2) o->f2 = 1;
        else if (b == 0xF3) o->f3 = 1;
        else if (!(b == 0x67 || b == 0x2E || b == 0x36 || b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65 || b == 0xF0)) break;
        i++;
    }
    if (i < m.len && code[i] >= 0x40 && code[i] <= 0x4F) o->rex = code[i++];
    if (m.evex && i + 4 < m.len && code[i] == 0x62) {
        /* map 5: no map 0..4 rule matches it, so every query below takes its conservative default.
         * P0's inverted R, X and B and P1's W, as a REX would carry them, name the address registers. */
        uint8_t p0 = code[i + 1], p1 = code[i + 2];
        o->map = 5; o->vexmap = p0 & 7; o->op = code[i + 4];
        o->rex = 0x40 | (p1 & 0x80 ? 8 : 0) | (p0 & 0x80 ? 0 : 4) | (p0 & 0x40 ? 0 : 2) | (p0 & 0x20 ? 0 : 1);
        o->dispscaled = m.displen == 1;
    } else if (i + 2 < m.len && code[i] == 0xC5) { o->map = 4; o->vexmap = 1; o->op = code[i + 2]; }
    else if (i + 3 < m.len && code[i] == 0xC4) { o->map = 4; o->vexmap = code[i + 1] & 0x1F; o->op = code[i + 3]; }
    else if (i < m.len && code[i] == 0x0F) {
        i++;
        if (i < m.len && code[i] == 0x38) { o->map = 2; i++; }
        else if (i < m.len && code[i] == 0x3A) { o->map = 3; i++; }
        else o->map = 1;
        o->op = i < m.len ? code[i] : -1;
    } else o->op = i < m.len ? code[i] : -1;
    o->immlen = m.immlen;
    if (m.immlen == 1) { int8_t v; memcpy(&v, code + m.len - 1, 1); o->imm = v; }
    else if (m.immlen == 2) { int16_t v; memcpy(&v, code + m.len - 2, 2); o->imm = v; }
    else if (m.immlen == 4) { int32_t v; memcpy(&v, code + m.len - 4, 4); o->imm = v; }
    else if (m.immlen == 8) { int64_t v; memcpy(&v, code + m.len - 8, 8); o->imm = v; }
    o->modrm = m.modrm >= 0;
    if (o->modrm) {
        uint8_t mr = code[m.modrm];
        o->mod = mr >> 6;
        o->reg = ((mr >> 3) & 7) | (o->rex & 4 ? 8 : 0);
        o->rm = (mr & 7) | (o->rex & 1 ? 8 : 0);
        o->sib = o->mod != 3 && (mr & 7) == 4;
        if (o->sib && m.modrm + 1 < m.len) {
            uint8_t sb = code[m.modrm + 1];
            o->sibbase = (sb & 7) == 5 && o->mod == 0 ? -1 : (sb & 7) | (o->rex & 1 ? 8 : 0);
            o->sibindex = ((sb >> 3) & 7) == 4 && !(o->rex & 2) ? -1 : ((sb >> 3) & 7) | (o->rex & 2 ? 8 : 0);
            o->sibscale = sb >> 6;
        }
        if (m.disp >= 0 && m.displen == 1) { int8_t v; memcpy(&v, code + m.disp, 1); o->mdisp = v; }
        else if (m.disp >= 0 && m.displen == 4) { int32_t v; memcpy(&v, code + m.disp, 4); o->mdisp = v; }
        if (o->mod == 0 && (mr & 7) == 5 && !m.adsize && m.disp >= 0 && m.displen == 4) {
            int32_t d;
            memcpy(&d, code + m.disp, 4);
            o->riprel = 1; o->disp = d;
            o->riptarget = o->next + (uint64_t)(int64_t)d;
        }
    }
    return 0;
}

static int is_call_rel(const Ins *x) { return x->map == 0 && x->op == 0xE8; }
static int is_jmp_rel(const Ins *x) { return x->map == 0 && (x->op == 0xE9 || x->op == 0xEB); }
static int is_jcc(const Ins *x) {
    return (x->map == 0 && ((x->op >= 0x70 && x->op <= 0x7F) || x->op == 0xE3)) ||
           (x->map == 1 && x->op >= 0x80 && x->op <= 0x8F);
}
static int is_ff(const Ins *x, int r) { return x->map == 0 && x->op == 0xFF && x->modrm && (x->reg & 7) == r; }

static int64_t rel_target(const uint8_t *code, const Ins *x, uint64_t ip) {
    int32_t d32; int8_t d8;
    (void)ip;
    if (x->map == 0 && (x->op == 0xEB || (x->op >= 0x70 && x->op <= 0x7F) || x->op == 0xE3)) {
        memcpy(&d8, code + x->len - 1, 1);
        return (int64_t)(x->next + (uint64_t)(int64_t)d8);
    }
    memcpy(&d32, code + x->len - 4, 4);
    return (int64_t)(x->next + (uint64_t)(int64_t)d32);
}

/* 0 only when this instruction provably does not write register r. */
static int may_write(const Ins *x, int r) {
    int op = x->op, low3 = op & 7, dst_rm = x->modrm && x->mod == 3 && x->rm == r;
    int dst_reg = x->modrm && x->reg == r, opreg = (op & 7) | (x->rex & 1 ? 8 : 0);
    if (x->map == 0) {
        if (op <= 0x3F && low3 <= 5 && op != 0x0F && op != 0x26 && op != 0x2E && op != 0x36 && op != 0x3E) {
            if (op >= 0x38 && op <= 0x3D) return 0;             /* cmp */
            if (low3 <= 1) return dst_rm;
            if (low3 <= 3) return dst_reg;
            return r == REG_RAX;
        }
        switch (op) {
        case 0x88: case 0x89: return dst_rm;
        case 0x8A: case 0x8B: case 0x8D: case 0x63: case 0x69: case 0x6B: return dst_reg;
        case 0xC6: case 0xC7: return (x->reg & 7) ? 1 : dst_rm;
        case 0x80: case 0x81: case 0x83: return (x->reg & 7) == 7 ? 0 : dst_rm;
        case 0x84: case 0x85: case 0xA8: case 0xA9: return 0;
        case 0xC0: case 0xC1: case 0xD0: case 0xD1: case 0xD2: case 0xD3: return dst_rm;
        case 0xF6: case 0xF7:
            if ((x->reg & 7) == 0) return 0;
            if ((x->reg & 7) <= 3) return dst_rm;
            return r == REG_RAX || r == REG_RDX || dst_rm;
        case 0xFE: case 0xFF:
            if ((x->reg & 7) <= 1) return dst_rm;
            if ((x->reg & 7) == 6) return 0;
            return 1;
        case 0x90: return x->rex & 1 ? r == 8 || r == REG_RAX : 0;
        case 0x98: return r == REG_RAX;
        case 0x99: return r == REG_RDX;
        }
        if (op >= 0x50 && op <= 0x57) return 0;
        if (op >= 0x58 && op <= 0x5F) return opreg == r;
        if (op >= 0xB0 && op <= 0xBF) return opreg == r;
        if ((op >= 0x70 && op <= 0x7F) || op == 0xEB || op == 0xE9) return 0;
        return 1;
    }
    if (x->map == 1) {
        if (op == 0x1F || op == 0x18 || op == 0x0D) return 0;
        if (op >= 0x80 && op <= 0x8F) return 0;
        if (op >= 0x40 && op <= 0x4F) return dst_reg;
        if (op >= 0x90 && op <= 0x9F) return dst_rm;
        if (op == 0xAF || op == 0xB6 || op == 0xB7 || op == 0xBE || op == 0xBF || op == 0xBC ||
            op == 0xBD || op == 0xB8 || op == 0x50 || op == 0xD7 || op == 0xC5 || op == 0x2C || op == 0x2D)
            return dst_reg;
        if (op == 0x7E) return x->f3 ? 0 : dst_rm;
        if (op == 0xA3) return 0;
        if (op == 0xBA) return (x->reg & 7) == 4 ? 0 : dst_rm;   /* bt imm8 tests a bit; bts/btr/btc write it */
        if (op == 0xAB || op == 0xB3 || op == 0xBB || op == 0xA4 || op == 0xA5 || op == 0xAC || op == 0xAD) return dst_rm;
        if (op >= 0xC8 && op <= 0xCF) return opreg == r;
        if ((op >= 0x10 && op <= 0x17) || (op >= 0x28 && op <= 0x2B) || op == 0x2E || op == 0x2F ||
            (op >= 0x51 && op <= 0x7F && op != 0x77 && op != 0x7E) || (op >= 0xD0 && op <= 0xFE && op != 0xD7) ||
            op == 0xC2 || op == 0xC6 || op == 0xAE)
            return 0;
        return 1;
    }
    /* 0F 38 / 0F 3A and VEX: only these write a general-purpose register (movbe, crc32, pextr*,
     * extractps, the BMI group, movmsk, movd/movq to r/m, pextrw, cvt*2si); treat them as
     * writing any register. Everything else in these maps writes vector registers or memory. */
    if (x->map == 2) return op == 0xF0 || op == 0xF1;
    if (x->map == 3) return op >= 0x14 && op <= 0x17;
    if (x->map == 4) {
        if (x->vexmap == 1) return op == 0x50 || op == 0xD7 || op == 0x7E || op == 0xC5 || op == 0x2C || op == 0x2D;
        if (x->vexmap == 2) return op >= 0xF0;
        if (x->vexmap == 3) return (op >= 0x14 && op <= 0x17) || op == 0xF0;
        return 1;
    }
    /* EVEX: only these write a general-purpose register (movd/movq/movw to r/m, pextrw, pextr*,
     * extractps, and the float-to-int conversions). EVEX has no other GPR destination. */
    if (x->map == 5) {
        if (x->vexmap == 1) return op == 0x7E || op == 0xC5 || op == 0x2C || op == 0x2D || op == 0x78 || op == 0x79;
        if (x->vexmap == 3) return op >= 0x14 && op <= 0x17;
        if (x->vexmap == 5) return op == 0x7E || op == 0x2C || op == 0x2D || op == 0x78 || op == 0x79;
        return x->vexmap != 2 && x->vexmap != 6;
    }
    return 1;
}


/* Per-function value propagation over the CFG that direct branches describe. A block nothing
 * branches to directly and nothing falls into (a switch case, say) starts with every register
 * and frame slot unknown; calls clobber the caller-saved registers; any instruction this module
 * cannot prove leaves a register alone makes it unknown; a direct branch into the middle of an
 * instruction abandons the function.
 *
 * Values: an address loaded by `lea reg, [rip+X]` (CONST, def = the lea), a small immediate
 * (IMM), the result of a recognised literal producer (SELLIT/CLASSLIT: va = the name's address),
 * NSString::from_str(literal, len) (NSSTR: va = bytes, def = len) and NSSelectorFromString of
 * that (SELNS), an objc entry point loaded from its GOT slot (ENTRY: va = the slot, def = the
 * load), the content of an objc2 cache static -- loaded, or returned by its fetch (CACHEVAL:
 * va = the static) -- or of a selector/class reference slot (SELREFV/CLASSREFV: va = the slot),
 * the return value of a dispatch call (SEND: va = the call site; the retain/autorelease entry
 * points return their argument unchanged), and the function's incoming argument registers (ARG:
 * va = 0 for rdi .. 5 for r9) in its entry block.
 *
 * Frame slots: in a function with a conventional frame (`push rbp; mov rbp, rsp`, rbp written
 * nowhere else but its restore; a bit test writes no register), the 8-byte slots `mov [rbp+d], r64` stores to also carry values.
 * Any other write whose memory operand is [rbp+d] kills the slots its store width reaches (64
 * bytes when the form is not known); a write
 * through rsp, or a string store, kills every slot. A frame address that escapes -- `lea r,
 * [rbp+d]` -- makes every slot at or above the lowest such d "exposed": every call and every
 * write through a register other than rbp kills the exposed slots. Stated limit, not a proof:
 * code holding a frame address is assumed never to write below it, as compiled Rust and C index
 * from an object's base upward; an address formed from rsp or copied from rbp/rsp exposes all.
 * A write through rbp with an index register kills every slot.
 *
 * Bounded frames (frame_scan): Apple clang 21 at -Os spills a for-in loop body's selector
 * references to slots before the loop and reloads each for its send, while the loop passes an
 * NSFastEnumerationState and an object buffer on the frame to countByEnumeratingWithState:
 * objects:count:. When some path spills a selector reference, a first solution finds every place
 * a frame address (a lea of [rbp+d], tracked as RS_FRAME and by `mf` on some path) is used. Bounded
 * uses: a base at a constant offset, a register copy, or the state (rdx, 64 bytes) and buffer (rcx,
 * 8 x the immediate count in r8) of an objc_msgSend of exactly that selector -- the NSFastEnumeration
 * contract says the callee writes those extents and nothing else of the caller's frame. Any other
 * use (frame_scan's list) is unbounded. A frame address given to another callee is bounded below:
 * by the stated limit above, the callee writes at or above the lowest address it was given, never
 * below. Every other unbounded use (stored, combined, derived, returned, made from rsp) reaches
 * anywhere. A second solution then keeps a slot holding a selector reference across calls and
 * other writes when no escaped extent covers it and it lies wholly below every frame address an
 * unbounded escape behind it on any path may reach. A write through a
 * frame address at a known offset, and a stack-argument write through rsp when the prologue fixes
 * rsp's offset from rbp and only epilogues move it, kill only the slots they reach. So a reload
 * gives the selector exactly when the one store reaching it on every path is still intact; another
 * value on some path, a write that reaches the slot, the slot's own address or one below it
 * escaping, or an unbounded escape that may reach anywhere leaves it unknown. Other slot values
 * keep the general rule above. */
enum { RS_UNDEF, RS_CONST, RS_IMM, RS_SELLIT, RS_CLASSLIT, RS_NSSTR, RS_ENTRY, RS_CACHEVAL, RS_SELREFV,
       RS_CLASSREFV, RS_SELNS, RS_SEND, RS_ARG, RS_BOOL, RS_FRAME, RS_UNKNOWN };
#define NSLOT 48
#define NEXT 32
#define NVAL (16 + NSLOT)
#define LO_NONE INT32_MAX
#define LO_ALL INT32_MIN
/* Path conditions (report.h ObjcCond): `p` holds what is known about earlier BOOL dispatch results
 * on every path here, each with the receiver value (kind sk, va sva) that dispatch was sent to;
 * lsite/lk/lva remember the last dispatch call and its receiver, so the `test al, al` that ends a
 * block can be tied to it. A dispatch at a site retires every condition about that site and
 * every condition whose receiver was that site's result: the value it named is gone. */
typedef struct { uint64_t site, sva; uint8_t val, sk; } Pred;
#define NPRED OBJC_MAX_CONDS
typedef struct {
    uint64_t va[NVAL], def[NVAL]; uint8_t k[NVAL]; int32_t lo; uint8_t reached;
    uint16_t me;                     /* registers that may hold a GOT-loaded objc entry point */
    uint16_t mf;                     /* registers that may hold a frame address (RS_FRAME on some path) */
    int32_t wlo;                     /* the lowest frame offset an unbounded escape on some path here may
                                      * reach: LO_NONE none, LO_ALL any (frame_scan) */
    uint64_t ms;                     /* slots that may hold a GOT-loaded objc entry point (bit i: slot[i]) */
    Pred p[NPRED]; uint8_t np;
    struct { uint64_t site, va; uint8_t k; } ls[4];   /* recent dispatches and their receivers */
} RS;
typedef struct {
    int built, ok;
    size_t n, nb;
    size_t *blk, *bstart;
    RS *in;
    int frame;                       /* conventional rbp frame: slots are tracked */
    int32_t slot[NSLOT]; size_t nslot;
    int bounded;                     /* selector slots outside the escaped extents survive (frame_scan) */
    int rsp_fixed; int64_t rsp_off;  /* rsp == rbp + rsp_off everywhere but in the epilogues */
    int64_t ext[NEXT][2]; size_t next;   /* frame extents escaped under the enumeration contract */
    struct Wild { uint64_t ip; int32_t lo; } *wild; size_t nwild, capwild;   /* instructions that escape a frame
                                      * address otherwise, and the lowest offset each may reach (LO_ALL: any) */
    struct CallSite { uint64_t lo, hi, pad; } *cs; size_t ncs;   /* LSDA ranges that land (lsda_sites) */
    uint8_t *lpad;                   /* per block: an LSDA landing pad */
    uint8_t *plain;                  /* per block: entered only by the direct edges block_edges gives */
    int ijump;                       /* the function has an indirect jump that may be a jump table */
} Flow;

static void rs_all(RS *r, int k, int32_t lo) {
    int i;
    for (i = 0; i < NVAL; i++) { r->k[i] = (uint8_t)k; r->va[i] = r->def[i] = 0; }
    r->lo = lo; r->reached = k != RS_UNDEF;
    r->np = 0; memset(r->ls, 0, sizeof r->ls); r->me = 0; r->mf = 0; r->wlo = LO_NONE; r->ms = 0;
}

static int pred_eq(const Pred *x, const Pred *y) {
    return x->site == y->site && x->val == y->val && x->sk == y->sk && x->sva == y->sva;
}

/* Adds a condition, dropping the oldest when full: fewer conditions only means fewer claims. */
static void pred_add(RS *r, uint64_t site, int val, uint8_t sk, uint64_t sva) {
    Pred q;
    int i;
    q.site = site; q.val = (uint8_t)val; q.sk = sk; q.sva = sva;
    for (i = 0; i < r->np; i++) if (pred_eq(&r->p[i], &q)) return;
    if (r->np == NPRED) { memmove(r->p, r->p + 1, (NPRED - 1) * sizeof *r->p); r->np--; }
    r->p[r->np++] = q;
}

/* A dispatch at `site` ran: conditions about it, or about a receiver it produced, are stale. */
static void pred_retire(RS *r, uint64_t site) {
    int i, j = 0;
    for (i = 0; i < r->np; i++)
        if (!(r->p[i].site == site || (r->p[i].sk == RS_SEND && r->p[i].sva == site))) r->p[j++] = r->p[i];
    r->np = (uint8_t)j;
}

/* Kinds whose identity is va alone; def only remembers one producing instruction. */
static int def_free(int k) {
    return k == RS_CONST || k == RS_ENTRY || k == RS_CACHEVAL || k == RS_SELREFV || k == RS_CLASSREFV ||
           k == RS_SEND || k == RS_ARG || k == RS_BOOL || k == RS_FRAME;
}

static int rs_meet(RS *into, const RS *from) {
    int i, changed = 0;
    if (!from->reached) return 0;
    if (!into->reached) { *into = *from; return 1; }
    for (i = 0; i < NVAL; i++) {
        if (from->k[i] == RS_UNDEF || into->k[i] == RS_UNKNOWN) continue;
        if (into->k[i] == RS_UNDEF) { into->k[i] = from->k[i]; into->va[i] = from->va[i]; into->def[i] = from->def[i]; changed = 1; }
        else if (from->k[i] != into->k[i] || from->va[i] != into->va[i] ||
                 (!def_free(into->k[i]) && from->def[i] != into->def[i])) { into->k[i] = RS_UNKNOWN; changed = 1; }
        else if (from->def[i] != into->def[i] && into->def[i]) { into->def[i] = 0; changed = 1; }
    }
    if (from->lo < into->lo) { into->lo = from->lo; changed = 1; }
    if ((into->me | from->me) != into->me) { into->me |= from->me; changed = 1; }
    if ((into->mf | from->mf) != into->mf) { into->mf |= from->mf; changed = 1; }
    if (from->wlo < into->wlo) { into->wlo = from->wlo; changed = 1; }
    if ((into->ms | from->ms) != into->ms) { into->ms |= from->ms; changed = 1; }
    {   /* keep only the conditions both carry */
        int a, b, j = 0;
        for (a = 0; a < into->np; a++) {
            for (b = 0; b < from->np && !pred_eq(&into->p[a], &from->p[b]); b++) ;
            if (b < from->np) into->p[j++] = into->p[a];
        }
        if (j != into->np) { into->np = (uint8_t)j; changed = 1; }
    }
    {   /* keep only the recent dispatches both agree on */
        int a;
        for (a = 0; a < 4; a++)
            if (into->ls[a].site != from->ls[a].site || into->ls[a].k != from->ls[a].k || into->ls[a].va != from->ls[a].va)
                into->ls[a].site = 0;
    }
    return changed;
}

static int64_t rel_target(const uint8_t *code, const Ins *x, uint64_t ip);
static void dispatch_regs(const char *callee, int *recv, int *sel, int *arg);

/* What a direct call's target is, for value tracking: 1 selector-from-C-string producer,
 * 2 class-from-C-string producer, 3 NSString::from_str, 0 anything else. */
static int call_kind(const Slice *s, uint64_t target) {
    const Ptr *p;
    size_t i;
    for (i = 0; i < s->nwrap_sel; i++) if (s->wrap_sel[i] == target) return 1;
    for (i = 0; i < s->nwrap_nsstr; i++) if (s->wrap_nsstr[i] == target) return 3;
    p = find_ptr(s->ptrs, s->nptrs, target);
    if (p && p->role == IMP_SEL_PRODUCER) return 1;
    if (p && p->role == IMP_CLASS_PRODUCER) return 2;
    return 0;
}

static const Cache *cache_at(const Slice *s, uint64_t addr) {
    size_t lo = 0, hi = s->ncaches;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (s->caches[mid].addr == addr) return &s->caches[mid];
        if (s->caches[mid].addr < addr) lo = mid + 1; else hi = mid;
    }
    return NULL;
}

/* A memory operand [rbp + disp] with no index, in a conventional frame. */
static int frame_operand(const Flow *f, const Ins *x) {
    if (!f->frame || !x->modrm || x->mod == 3 || x->riprel) return 0;
    if (!x->sib) return x->rm == 5;
    return x->sibbase == 5 && x->sibindex == -1;
}

static int slot_of(const Flow *f, int64_t d) {
    size_t i;
    for (i = 0; i < f->nslot; i++) if (f->slot[i] == d) return (int)i;
    return -1;
}

static void kill_range(const Flow *f, RS *r, int64_t lo, int64_t hi, int keep) {
    size_t i;
    for (i = 0; i < f->nslot; i++)
        if ((int)i != keep && f->slot[i] + 8 > lo && f->slot[i] < hi) r->k[16 + i] = RS_UNKNOWN;
}
/* A bounded frame's selector slot: a selector reference spilled where no escaped extent reaches,
 * wholly below every frame address an unbounded escape behind it on any path may have passed on.
 * What reaches only the extents leaves it alone. */
static int sel_kept(const Flow *f, const RS *r, size_t i) {
    size_t e;
    if (!f->bounded || r->k[16 + i] != RS_SELREFV || (int64_t)f->slot[i] + 8 > (int64_t)r->wlo) return 0;
    for (e = 0; e < f->next; e++) if (f->slot[i] + 8 > f->ext[e][0] && f->slot[i] < f->ext[e][1]) return 0;
    return 1;
}
static void kill_exposed(const Flow *f, RS *r) {
    size_t i;
    for (i = 0; i < f->nslot; i++) if (f->slot[i] >= r->lo && !sel_kept(f, r, i)) r->k[16 + i] = RS_UNKNOWN;
}
/* A write known to reach only [lo, hi) of the frame: kept selector slots die only where it
 * overlaps them; every other slot as before, all of them (every) or the exposed ones. */
static void kill_write(const Flow *f, RS *r, int64_t lo, int64_t hi, int every) {
    size_t i;
    for (i = 0; i < f->nslot; i++) {
        int hit = f->slot[i] + 8 > lo && f->slot[i] < hi;
        if (sel_kept(f, r, i) ? hit : (every || hit || f->slot[i] >= r->lo)) r->k[16 + i] = RS_UNKNOWN;
    }
}
/* The lowest frame offset the unbounded escape at ip may reach, or LO_NONE when ip is none. */
static int32_t wild_at(const Flow *f, uint64_t ip) {
    size_t lo = 0, hi = f->nwild;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (f->wild[mid].ip == ip) return f->wild[mid].lo;
        if (f->wild[mid].ip < ip) lo = mid + 1; else hi = mid;
    }
    return LO_NONE;
}

/* Whether an instruction with a memory operand only reads it (or does not access it at all). */
static int mem_read_only(const Ins *x) {
    int op = x->op, reg = x->reg & 7;
    if (x->map == 0) {
        if (op <= 0x3F && (op & 7) <= 5 && ((op & 7) == 2 || (op & 7) == 3)) return 1;   /* op r, r/m */
        if (op >= 0x38 && op <= 0x3B) return 1;                                         /* cmp */
        switch (op) {
        case 0x8A: case 0x8B: case 0x8D: case 0x63: case 0x69: case 0x6B: case 0x84: case 0x85: return 1;
        case 0x80: case 0x81: case 0x83: return reg == 7;
        case 0xF6: case 0xF7: return reg == 0 || reg >= 4;
        case 0xFF: return reg == 2 || reg == 3 || reg == 4 || reg == 5 || reg == 6;
        }
        return 0;
    }
    if (x->map == 1) {
        if ((op >= 0x40 && op <= 0x4F) || op == 0xAF || op == 0xB6 || op == 0xB7 || op == 0xBE || op == 0xBF ||
            op == 0xBC || op == 0xBD || op == 0xB8 || op == 0xA3 || op == 0x18 || op == 0x1F || op == 0x0D ||
            op == 0x10 || op == 0x12 || op == 0x16 || op == 0x28 || op == 0x2E || op == 0x2F || op == 0x6E ||
            op == 0x6F || (op >= 0x51 && op <= 0x5F) || (op >= 0x60 && op <= 0x6D) || (op >= 0x74 && op <= 0x76) ||
            (op >= 0xD8 && op <= 0xEF && op != 0xE7) || op == 0xC2)
            return 1;
        if (op == 0x7E) return x->f3;   /* F3 0F 7E loads; 66 0F 7E stores */
        return 0;
    }
    if (x->map == 4 && x->vexmap == 1)
        return op == 0x10 || op == 0x12 || op == 0x16 || op == 0x28 || op == 0x2E || op == 0x2F || op == 0x6F ||
               (op >= 0x51 && op <= 0x5F) || (op >= 0x60 && op <= 0x6D) || (op >= 0x74 && op <= 0x76) ||
               (op >= 0xD8 && op <= 0xEF && op != 0xE7);
    return 0;
}

/* Bytes a memory-writing instruction may store at its operand; 64 when this module does not
 * know the form (wider than any store the x86-64 targets here emit). */
static int64_t store_width(const Ins *x) {
    int op = x->op;
    if (x->map == 0) {
        if ((op <= 0x3F && (op & 7) == 0) || op == 0x88 || op == 0xC6 || op == 0x80 || op == 0xC0 ||
            op == 0xD0 || op == 0xD2 || op == 0xF6 || op == 0xFE || op == 0x86)
            return 1;
        if ((op <= 0x3F && (op & 7) == 1) || op == 0x89 || op == 0xC7 || op == 0x81 || op == 0x83 || op == 0xC1 ||
            op == 0xD1 || op == 0xD3 || op == 0xF7 || op == 0xFF || op == 0x87 || op == 0x8F)
            return x->rex & 8 ? 8 : x->p66 ? 2 : 4;
        return 64;
    }
    if (x->map == 1) {
        if (op >= 0x90 && op <= 0x9F) return 1;
        if (op == 0x11 || op == 0x29 || op == 0x2B || op == 0x7F || op == 0xE7) return 16;
        if (op == 0x13 || op == 0x17 || op == 0xD6 || op == 0x7E) return 8;
        return 64;
    }
    if (x->map == 4 && x->vexmap == 1 && (op == 0x11 || op == 0x29 || op == 0x2B || op == 0x7F || op == 0xE7))
        return 32;
    return 64;
}

static void transfer_values(const Slice *s, const Flow *f, RS *r, const Ins *x, uint64_t ip, const uint8_t *at) {
    int i;
    if (f->bounded && f->nwild) {   /* an escape frame_scan could not bound */
        int32_t w = wild_at(f, ip);
        if (w < r->wlo) r->wlo = w;
    }
    /* Frame bookkeeping: escaping frame addresses and writes that may reach a slot. */
    if (x->map == 0 && x->op == 0x8D && x->modrm && x->mod != 3) {
        if (frame_operand(f, x)) { if (x->mdisp < r->lo) r->lo = (int32_t)x->mdisp; }
        else if (!x->riprel && ((!x->sib && (x->rm == 4 || x->rm == 5)) ||
                                (x->sib && (x->sibbase == 4 || x->sibbase == 5 || x->sibindex == 5))))
            r->lo = LO_ALL;
    } else if (x->map == 0 && (x->op == 0x89 || x->op == 0x8B) && x->modrm && x->mod == 3) {
        int src = x->op == 0x89 ? x->reg : x->rm, dst = x->op == 0x89 ? x->rm : x->reg;
        if ((src == 4 || src == 5) && !(src == 4 && dst == 5)) r->lo = LO_ALL;
    } else if (x->modrm && x->mod != 3 && !mem_read_only(x)) {
        if (x->dispscaled) {
            int base = x->sib ? x->sibbase : x->rm, idx = x->sib ? x->sibindex : -1;
            if (base == 4 || base == 5 || idx == 4 || idx == 5 || (base >= 0 && r->k[base] == RS_FRAME))
                kill_range(f, r, INT64_MIN / 2, INT64_MAX / 2, -1);   /* the frame, somewhere */
            else kill_exposed(f, r);
        } else if (frame_operand(f, x)) {
            if (!(x->map == 0 && x->op == 0x89 && (x->rex & 8))) kill_range(f, r, x->mdisp, x->mdisp + store_width(x), -1);
        } else if (!x->riprel) {
            int base = x->sib ? x->sibbase : x->rm, idx = x->sib ? x->sibindex : -1;
            if (base == 4 && idx < 0 && f->bounded && f->rsp_fixed)   /* a stack argument: [rsp+d] is [rbp+rsp_off+d] */
                kill_write(f, r, f->rsp_off + x->mdisp, f->rsp_off + x->mdisp + store_width(x), 1);
            else if (base == 4 || base == 5) kill_range(f, r, INT64_MIN / 2, INT64_MAX / 2, -1);   /* rsp, or rbp indexed */
            else if (base >= 0 && idx < 0 && f->bounded && r->k[base] == RS_FRAME)   /* through a frame address, at a known offset */
                kill_write(f, r, (int64_t)r->va[base] + x->mdisp, (int64_t)r->va[base] + x->mdisp + store_width(x), 0);
            else kill_exposed(f, r);
        }
    } else if (x->map == 0 && (x->op == 0xA4 || x->op == 0xA5 || x->op == 0xAA || x->op == 0xAB)) {
        kill_range(f, r, INT64_MIN / 2, INT64_MAX / 2, -1);
    }

    if (x->map == 0 && x->op == 0x8D && x->modrm && (x->rex & 8) && x->riprel) {
        r->k[x->reg] = RS_CONST; r->va[x->reg] = x->riptarget; r->def[x->reg] = ip;
        return;
    }
    if (x->map == 0 && x->op == 0x8D && x->modrm && (x->rex & 8) && x->mod != 3 && frame_operand(f, x)) {
        r->k[x->reg] = RS_FRAME; r->va[x->reg] = (uint64_t)x->mdisp; r->def[x->reg] = 0;   /* rbp + mdisp */
        return;
    }
    /* A byte copy (mov r8, r8 / movzx r32, r8) of a dispatch's BOOL keeps only that BOOL. */
    if (x->modrm && x->mod == 3 && ((x->map == 0 && (x->op == 0x88 || x->op == 0x8A)) || (x->map == 1 && x->op == 0xB6))) {
        int st = x->map == 0 && x->op == 0x88, dst = st ? x->rm : x->reg, src = st ? x->reg : x->rm;
        if ((x->rex || src < 4) && (r->k[src] == RS_SEND || r->k[src] == RS_BOOL)) {
            r->k[dst] = RS_BOOL; r->va[dst] = r->va[src]; r->def[dst] = 0;
            return;
        }
    }
    if (x->map == 0 && (x->op == 0x89 || x->op == 0x8B) && x->modrm && x->mod == 3 && (x->rex & 8)) {
        int dst = x->op == 0x89 ? x->rm : x->reg, src = x->op == 0x89 ? x->reg : x->rm;
        r->k[dst] = r->k[src]; r->va[dst] = r->va[src]; r->def[dst] = r->def[src];
        return;
    }
    if (x->map == 0 && x->op == 0x8B && x->modrm && (x->rex & 8) && x->mod != 3) {   /* 64-bit load */
        uint64_t addr = 0;
        int known = 0, d = x->reg;
        if (x->riprel) { addr = x->riptarget; known = 1; }
        else if (!x->sib && r->k[x->rm] == RS_CONST) { addr = r->va[x->rm] + (uint64_t)x->mdisp; known = 1; }
        if (known) {
            const Ptr *p = find_ptr(s->ptrs, s->nptrs, addr);
            const Sect *t = sect_of(s, addr);
            if (x->riprel && p && p->role != IMP_OTHER) {
                r->k[d] = RS_ENTRY; r->va[d] = addr; r->def[d] = ip;
                return;
            }
            r->va[d] = addr; r->def[d] = ip;
            if (cache_at(s, addr)) r->k[d] = RS_CACHEVAL;
            else if (t && !strcmp(t->sect, "__objc_selrefs")) r->k[d] = RS_SELREFV;
            else if (t && (!strcmp(t->sect, "__objc_classrefs") || !strcmp(t->sect, "__objc_superrefs"))) r->k[d] = RS_CLASSREFV;
            else r->k[d] = RS_UNKNOWN;
            return;
        }
        if (frame_operand(f, x)) {
            int si = slot_of(f, x->mdisp);
            if (si >= 0) { r->k[d] = r->k[16 + si]; r->va[d] = r->va[16 + si]; r->def[d] = r->def[16 + si]; return; }
        }
        r->k[d] = RS_UNKNOWN;
        return;
    }
    if (x->map == 0 && x->op == 0x89 && (x->rex & 8) && x->modrm && x->mod != 3 &&
        (r->k[x->reg] == RS_SELLIT || r->k[x->reg] == RS_CLASSLIT)) {
        /* An inlined fetch storing its producer's result: the register now holds what the
         * cache holds (cache_store checks the literal against the cache's other fetches). */
        uint64_t addr = 0;
        int known = 0;
        if (x->riprel) { addr = x->riptarget; known = 1; }
        else if (!x->sib && r->k[x->rm] == RS_CONST) { addr = r->va[x->rm] + (uint64_t)x->mdisp; known = 1; }
        if (known && cache_at(s, addr)) {
            /* Every copy of the same producer result now equals the cache's content too. */
            int k0 = r->k[x->reg];
            uint64_t v0 = r->va[x->reg];
            for (i = 0; i < NVAL; i++)
                if (r->k[i] == k0 && r->va[i] == v0) { r->k[i] = RS_CACHEVAL; r->va[i] = addr; r->def[i] = ip; }
            return;
        }
    }
    if (x->map == 0 && x->op == 0x89 && (x->rex & 8) && frame_operand(f, x)) {      /* spill */
        int si = slot_of(f, x->mdisp);
        kill_range(f, r, x->mdisp, x->mdisp + 8, si);
        if (si >= 0) { r->k[16 + si] = r->k[x->reg]; r->va[16 + si] = r->va[x->reg]; r->def[16 + si] = r->def[x->reg]; }
        return;
    }
    if (x->map == 0 && x->op >= 0xB8 && x->op <= 0xBF && x->imm >= 0) {
        int d = (x->op & 7) | (x->rex & 1 ? 8 : 0);
        r->k[d] = RS_IMM; r->va[d] = (uint64_t)x->imm; r->def[d] = 0;
        return;
    }
    if (is_call_rel(x) || is_ff(x, 2) || is_ff(x, 3)) {
        static const int clobber[] = { 0, 1, 2, 6, 7, 8, 9, 10, 11 };
        int kind = 0, rk = RS_UNKNOWN, have = 0;
        uint64_t va = 0, def = 0, target = 0;
        const Ptr *p = NULL;
        if (is_call_rel(x)) { target = (uint64_t)rel_target(at, x, ip); have = 1; }
        else if (is_ff(x, 2) && x->riprel) { target = x->riptarget; have = 1; }
        else if (is_ff(x, 2) && x->mod == 3 && r->k[x->rm] == RS_ENTRY) { target = r->va[x->rm]; have = 1; }
        if (have) { kind = call_kind(s, target); p = find_ptr(s->ptrs, s->nptrs, target); }
        if ((kind == 1 || kind == 2) && r->k[REG_RDI] == RS_CONST) {
            rk = kind == 1 ? RS_SELLIT : RS_CLASSLIT; va = r->va[REG_RDI];
        } else if (kind == 3 && r->k[REG_RDI] == RS_CONST && r->k[REG_RSI] == RS_IMM) {
            rk = RS_NSSTR; va = r->va[REG_RDI]; def = r->va[REG_RSI];
        } else if (have && is_fetch(s, target) && r->k[REG_RDI] == RS_CONST && cache_at(s, r->va[REG_RDI])) {
            rk = RS_CACHEVAL; va = r->va[REG_RDI]; def = ip;
        } else if (p && p->role == IMP_DISPATCH) {
            int rr, rs_, ra;
            dispatch_regs(p->name, &rr, &rs_, &ra);
            rk = RS_SEND; va = ip;
            pred_retire(r, ip);
            /* What this site returned before is no longer its result. */
            for (i = 0; i < NVAL; i++) if ((r->k[i] == RS_SEND || r->k[i] == RS_BOOL) && r->va[i] == ip) r->k[i] = RS_UNKNOWN;
            memmove(r->ls + 1, r->ls, 3 * sizeof *r->ls);
            r->ls[0].site = ip; r->ls[0].k = r->k[rr]; r->ls[0].va = r->va[rr];
        } else if (p && p->role == IMP_PASSTHROUGH) {
            rk = r->k[REG_RDI]; va = r->va[REG_RDI]; def = r->def[REG_RDI];
        } else if (p && p->role == IMP_SEL_PRODUCER_NSSTRING && r->k[REG_RDI] == RS_NSSTR) {
            rk = RS_SELNS; va = r->va[REG_RDI]; def = r->def[REG_RDI];
        }
        kill_exposed(f, r);
        for (i = 0; i < 9; i++) r->k[clobber[i]] = RS_UNKNOWN;
        r->k[REG_RAX] = (uint8_t)rk; r->va[REG_RAX] = va; r->def[REG_RAX] = def;
        return;
    }
    if (is_jmp_rel(x) || is_ff(x, 4) || is_ff(x, 5)) kill_exposed(f, r);   /* a tail call */
    for (i = 0; i < 16; i++) if (may_write(x, i)) r->k[i] = RS_UNKNOWN;
}

static int is_call_any(const Ins *x) { return is_call_rel(x) || is_ff(x, 2) || is_ff(x, 3); }

/* The values above, plus `me`: the registers that may hold a GOT-loaded objc entry point on SOME
 * path (rs_meet unions it), where k[] says what they hold on every path. A call keeps the
 * callee-saved registers; any other write the instruction may make clears the bit. */
static void transfer(const Slice *s, const Flow *f, RS *r, const Ins *x, uint64_t ip, const uint8_t *at) {
    static const int clobber[] = { 0, 1, 2, 6, 7, 8, 9, 10, 11 };
    uint16_t me = r->me, mf = r->mf;
    uint64_t ms = r->ms;
    int i, reload = -1;
    /* `ms`, the slots that may hold an entry point on some path, as `me` is for registers: a
     * 64-bit spill to a slot replaces its bit with the stored register's, a 64-bit reload of a
     * slot whose bit is set may load one. Any other write leaves the bit: it may not overwrite
     * all eight bytes, and entry_escapes refuses the reload's call when the value is not known. */
    if (f->frame && x->map == 0 && (x->rex & 8) && x->modrm && x->mod != 3 && frame_operand(f, x)) {
        int si = slot_of(f, x->mdisp);
        if (si >= 0 && x->op == 0x89) {
            ms &= ~(1ull << si);
            if (me & (1u << x->reg)) ms |= 1ull << si;
        } else if (si >= 0 && x->op == 0x8B && (ms & (1ull << si))) reload = x->reg;
    }
    transfer_values(s, f, r, x, ip, at);
    if (is_call_any(x)) for (i = 0; i < 9; i++) { me &= (uint16_t)~(1u << clobber[i]); mf &= (uint16_t)~(1u << clobber[i]); }
    else for (i = 0; i < 16; i++) if (may_write(x, i)) { me &= (uint16_t)~(1u << i); mf &= (uint16_t)~(1u << i); }
    if (reload >= 0) me |= (uint16_t)(1u << reload);
    for (i = 0; i < 16; i++) if (r->k[i] == RS_ENTRY) me |= (uint16_t)(1u << i);
    for (i = 0; i < 16; i++) if (r->k[i] == RS_FRAME) mf |= (uint16_t)(1u << i);
    for (i = 0; (size_t)i < f->nslot; i++) if (r->k[16 + i] == RS_ENTRY) ms |= 1ull << i;
    r->me = me; r->mf = mf; r->ms = ms;
}

/* The general-purpose registers instruction x reads as data or to form an address, excluding the
 * register a `call/jmp *reg` transfers through (entry_escapes checks that one). An opcode this
 * table does not know reads every register: an entry point held across it is refused, not missed. */
static uint16_t gpr_reads_ex(const Ins *x, int mem) {   /* mem 0: not the memory operand's base and index */
    uint16_t m = 0;
    int op = x->op, low3 = op & 7, rm = x->modrm && x->mod == 3, opreg = (op & 7) | (x->rex & 1 ? 8 : 0);
#define R(n) (m |= (uint16_t)(1u << ((n) & 15)))
    int nomem = x->map == 1 && (op == 0x1F || op == 0x18 || op == 0x0D);   /* nop/prefetch operands are not read */
    if (mem && x->modrm && x->mod != 3 && !x->riprel && !nomem) {
        if (!x->sib) R(x->rm);
        else { if (x->sibbase >= 0) R(x->sibbase); if (x->sibindex >= 0) R(x->sibindex); }
    }
    if (x->map == 0) {
        if (op <= 0x3F && low3 <= 5 && op != 0x0F && op != 0x26 && op != 0x2E && op != 0x36 && op != 0x3E) {
            if (low3 >= 4) { R(0); return m; }
            /* xor/sub of a register with itself only zeroes it */
            if (rm && x->reg == x->rm && (op == 0x31 || op == 0x33 || op == 0x29 || op == 0x2B)) return m;
            R(x->reg); if (rm) R(x->rm);
            return m;
        }
        switch (op) {
        case 0x84: case 0x85: case 0x86: case 0x87: R(x->reg); if (rm) R(x->rm); return m;
        case 0xA8: case 0xA9: case 0x98: case 0x99: case 0xA0: case 0xA1: case 0xA2: case 0xA3: R(0); return m;
        case 0x88: case 0x89: R(x->reg); return m;
        case 0x8A: case 0x8B: case 0x8D: case 0x63: case 0x69: case 0x6B: if (rm) R(x->rm); return m;
        case 0x80: case 0x81: case 0x83: case 0xC0: case 0xC1: case 0xD0: case 0xD1: if (rm) R(x->rm); return m;
        case 0xD2: case 0xD3: R(1); if (rm) R(x->rm); return m;
        case 0xC6: case 0xC7: case 0x8F: return m;
        case 0xF6: case 0xF7: R(0); R(2); if (rm) R(x->rm); return m;
        case 0xFE: if (rm) R(x->rm); return m;
        case 0xFF: if (rm && (x->reg & 7) != 2 && (x->reg & 7) != 4) R(x->rm); return m;
        case 0xA4: case 0xA5: case 0xAA: case 0xAB: R(0); R(1); R(6); R(7); return m;
        case 0xC2: case 0xC3: case 0xC9: case 0xCC: case 0xE8: case 0xE9: case 0xEB: case 0xF4:
        case 0x68: case 0x6A: case 0x9C: case 0x9D: return m;
        case 0xE3: R(1); return m;
        }
        if (op >= 0x50 && op <= 0x57) { R(opreg); return m; }
        if (op >= 0x90 && op <= 0x97) { if (op != 0x90 || (x->rex & 1)) { R(opreg); R(0); } return m; }
        if ((op >= 0x58 && op <= 0x5F) || (op >= 0xB0 && op <= 0xBF) || (op >= 0x70 && op <= 0x7F)) return m;
        return 0xFFFF;
    }
    if (x->map == 1) {
        if ((op >= 0x40 && op <= 0x4F) || op == 0xAF || op == 0xA3 || op == 0xAB || op == 0xB3 || op == 0xBB ||
            op == 0xA4 || op == 0xAC || op == 0xC0 || op == 0xC1) { R(x->reg); if (rm) R(x->rm); return m; }
        if (op == 0xA5 || op == 0xAD) { R(1); R(x->reg); if (rm) R(x->rm); return m; }
        if (op == 0xB0 || op == 0xB1) { R(0); R(x->reg); if (rm) R(x->rm); return m; }
        if (op == 0xB6 || op == 0xB7 || op == 0xBE || op == 0xBF || op == 0xBC || op == 0xBD || op == 0xB8 ||
            op == 0xBA || op == 0x6E || op == 0x2A || op == 0xC4) { if (rm) R(x->rm); return m; }
        if (op >= 0xC8 && op <= 0xCF) { R(opreg); return m; }
        if (op == 0xA2) { R(0); R(1); return m; }
        if ((op >= 0x80 && op <= 0x9F) || op == 0x1F || op == 0x18 || op == 0x0D || op == 0x0B || op == 0x7E ||
            (op >= 0x10 && op <= 0x17) || (op >= 0x28 && op <= 0x2F) || (op >= 0x50 && op <= 0x7F) ||
            (op >= 0xD0 && op <= 0xFE) || op == 0xC2 || op == 0xC6 || op == 0xAE)
            return m;   /* vector registers in reg/rm */
        return 0xFFFF;
    }
    if (x->map == 2) { if ((op == 0xF0 || op == 0xF1) && rm) R(x->rm); return m; }
    if (x->map == 3 || (x->map == 4 && x->vexmap == 3 && op != 0xF0)) { if ((op == 0x20 || op == 0x22) && rm) R(x->rm); return m; }
    if (x->map == 4 && (x->vexmap == 1 || (x->vexmap == 2 && op < 0xF0))) return m;
    /* EVEX reads a general-purpose register only as an address, or as the r/m source of these:
     * movd/movq/movw to a vector, the int-to-float conversions, pinsr*, and broadcasts from a GPR. */
    if (x->map == 5) {
        int src = (x->vexmap == 1 && (op == 0x6E || op == 0x2A || op == 0x7B || op == 0xC4)) ||
                  (x->vexmap == 2 && op >= 0x7A && op <= 0x7C) ||
                  (x->vexmap == 3 && (op == 0x20 || op == 0x22)) ||
                  (x->vexmap == 5 && (op == 0x6E || op == 0x2A || op == 0x7B));
        if (src && rm) R(x->rm);
        return m;
    }
    return 0xFFFF;
#undef R
}
static uint16_t gpr_reads(const Ins *x) { return gpr_reads_ex(x, 1); }

static int ends_flow(const Ins *x) {   /* no fallthrough successor */
    return is_jmp_rel(x) || is_ff(x, 4) || is_ff(x, 5) ||
           (x->map == 0 && (x->op == 0xC3 || x->op == 0xC2 || x->op == 0xCB || x->op == 0xCA || x->op == 0xF4)) ||
           (x->map == 1 && x->op == 0x0B);
}

static void flow_free(Flow *f) { free(f->blk); free(f->bstart); free(f->in); free(f->wild); free(f->cs); free(f->lpad); free(f->plain); memset(f, 0, sizeof *f); }

static long index_of(const uint64_t *ips, size_t n, uint64_t va) {
    size_t lo = 0, hi = n;
    while (lo < hi) { size_t mid = lo + (hi - lo) / 2; if (ips[mid] == va) return (long)mid; if (ips[mid] < va) lo = mid + 1; else hi = mid; }
    return -1;
}

/* A conventional frame: `push rbp; mov rbp, rsp` first, and rbp otherwise written only by the
 * epilogue's pop/leave. The slots are the distinct displacements 64-bit stores spill to. */
static void frame_setup(Flow *f, const Ins *ins, size_t n) {
    size_t i;
    f->frame = 0; f->nslot = 0;
    if (n < 2 || !(ins[0].map == 0 && ins[0].op == 0x55 && !(ins[0].rex & 1))) return;
    if (!(ins[1].map == 0 && ins[1].modrm && ins[1].mod == 3 && (ins[1].rex & 8) &&
          ((ins[1].op == 0x89 && ins[1].reg == 4 && ins[1].rm == 5) || (ins[1].op == 0x8B && ins[1].reg == 5 && ins[1].rm == 4))))
        return;
    for (i = 2; i < n; i++) {
        const Ins *x = &ins[i];
        if (x->map == 0 && ((x->op == 0x5D && !(x->rex & 1)) || x->op == 0xC9 || x->op == 0xCC)) continue;
        if (is_call_rel(x) || is_ff(x, 2) || is_ff(x, 3) || ends_flow(x)) continue;
        if (may_write(x, 5)) return;
    }
    f->frame = 1;
    for (i = 2; i < n && f->nslot < NSLOT; i++) {
        const Ins *x = &ins[i];
        if (x->map == 0 && x->op == 0x89 && (x->rex & 8) && frame_operand(f, x) && slot_of(f, x->mdisp) < 0)
            f->slot[f->nslot++] = (int32_t)x->mdisp;
    }
}

/* Whether x may change rsp: a push or pop of any kind, enter/leave, or any other write to it. */
static int writes_rsp(const Ins *x) {
    if (x->map == 0 && ((x->op >= 0x50 && x->op <= 0x5F) || x->op == 0x68 || x->op == 0x6A || x->op == 0x8F ||
                        x->op == 0x9C || x->op == 0x9D || x->op == 0xC8 || x->op == 0xC9))
        return 1;
    if (is_ff(x, 6)) return 1;
    if (is_call_any(x) || ends_flow(x)) return 0;   /* a call returns with rsp as it was */
    return may_write(x, REG_RSP);
}

/* Whether ins[i..] is an epilogue: only pops, `add rsp, imm`, `lea rsp, [rbp+d]`, `mov rsp, rbp`
 * and leave, up to the return or tail jump that ends it. */
static int epilogue_at(const Ins *ins, size_t i, size_t n) {
    for (; i < n; i++) {
        const Ins *x = &ins[i];
        if (ends_flow(x)) return x->map == 0 && (x->op == 0xC3 || x->op == 0xC2 || x->op == 0xE9 || x->op == 0xEB || x->op == 0xFF);
        if (x->map == 0 && ((x->op >= 0x58 && x->op <= 0x5F) || x->op == 0xC9)) continue;
        if (x->map == 0 && (x->op == 0x81 || x->op == 0x83) && x->modrm && x->mod == 3 && x->rm == REG_RSP && (x->reg & 7) == 0) continue;
        if (x->map == 0 && x->op == 0x8D && x->modrm && x->mod != 3 && x->reg == REG_RSP) continue;
        if (x->map == 0 && x->modrm && x->mod == 3 && (x->rex & 8) &&
            ((x->op == 0x89 && x->reg == REG_RBP && x->rm == REG_RSP) || (x->op == 0x8B && x->reg == REG_RSP && x->rm == REG_RBP)))
            continue;
        return 0;
    }
    return 0;
}

/* rsp's place in a conventional frame: the prologue's pushes and `sub rsp, imm` after
 * `push rbp; mov rbp, rsp` put it at rbp + rsp_off, and nothing but an epilogue moves it. */
static void rsp_setup(Flow *f, const Ins *ins, size_t n) {
    size_t i = 2, j;
    int64_t off = 0;
    f->rsp_fixed = 0; f->rsp_off = 0;
    while (i < n && ins[i].map == 0 && ins[i].op >= 0x50 && ins[i].op <= 0x57) { off -= 8; i++; }
    if (i < n && ins[i].map == 0 && (ins[i].op == 0x81 || ins[i].op == 0x83) && ins[i].modrm && ins[i].mod == 3 &&
        ins[i].rm == REG_RSP && (ins[i].reg & 7) == 5 && (ins[i].rex & 8) && ins[i].imm > 0 && ins[i].imm < (1 << 24)) {
        off -= ins[i].imm; i++;
    }
    for (j = i; j < n; j++) if (writes_rsp(&ins[j]) && !epilogue_at(ins, j, n)) return;
    f->rsp_fixed = 1; f->rsp_off = off;
}

/* Imports that never return: their call has no fallthrough, so a stale register state after a
 * failed stack check (say) does not reach the code laid out next. */
static int no_fallthrough(const Slice *s, const uint8_t *base, uint64_t sect_addr, const uint64_t *ips, const Ins *ins, size_t i) {
    static const char *NORETURN[] = { "___stack_chk_fail", "_abort", "_exit", "__exit", "___assert_rtn", "_objc_exception_throw",
                                      "__Unwind_Resume", "___cxa_throw", "___cxa_rethrow", "_pthread_exit", "_longjmp", "_siglongjmp" };
    const Ins *x = &ins[i];
    const Ptr *p = NULL;
    size_t k;
    if (ends_flow(x)) return 1;
    if (is_call_rel(x)) p = find_ptr(s->ptrs, s->nptrs, (uint64_t)rel_target(base + (ips[i] - sect_addr), x, ips[i]));
    else if (is_ff(x, 2) && x->riprel) p = find_ptr(s->ptrs, s->nptrs, x->riptarget);
    if (!p || !p->name) return 0;
    for (k = 0; k < sizeof NORETURN / sizeof *NORETURN; k++) if (!strcmp(p->name, NORETURN[k])) return 1;
    return 0;
}

static int tail_jump(const uint8_t *base, uint64_t sect_addr, const uint64_t *ips, const Ins *ins, size_t n, size_t i);
#define ARG_REGS ((1u << REG_RDI) | (1u << REG_RSI) | (1u << REG_RDX) | (1u << REG_RCX) | (1u << 8) | (1u << 9))

/* A call that passes frame addresses only under the NSFastEnumeration contract:
 * objc_msgSend(..., countByEnumeratingWithState:objects:count:, state, buffer, count) with the
 * state (rdx, an NSFastEnumerationState: 64 bytes) and the buffer (rcx, count objects; count an
 * immediate in r8) on the frame. The callee writes those and nothing else of the caller's frame;
 * their extents are recorded. Any other frame address in an argument register: 0. */
static int enumeration_call(const Slice *s, Flow *f, const RS *st, const Ins *x, uint64_t ip, const uint8_t *at) {
    uint16_t live = st->mf & ARG_REGS;
    uint64_t target = 0, v;
    const Ptr *p;
    char name[64];
    if (is_call_rel(x)) target = (uint64_t)rel_target(at, x, ip);
    else if (is_ff(x, 2) && x->riprel) target = x->riptarget;
    else if (is_ff(x, 2) && x->mod == 3 && st->k[x->rm] == RS_ENTRY) target = st->va[x->rm];
    else return 0;
    if (!(p = find_ptr(s->ptrs, s->nptrs, target)) || p->role != IMP_DISPATCH || !p->name || strcmp(p->name, "_objc_msgSend")) return 0;
    if (st->k[REG_RSI] != RS_SELREFV || read64(s, st->va[REG_RSI], &v) || literal_at(s, v, name, sizeof name) ||
        strcmp(name, "countByEnumeratingWithState:objects:count:"))
        return 0;
    if (live & ~((1u << REG_RDX) | (1u << REG_RCX))) return 0;
    if (f->next + 2 > NEXT) return 0;
    if (live & (1u << REG_RDX)) {
        if (st->k[REG_RDX] != RS_FRAME) return 0;
        f->ext[f->next][0] = (int64_t)st->va[REG_RDX]; f->ext[f->next][1] = (int64_t)st->va[REG_RDX] + 64; f->next++;
    }
    if (live & (1u << REG_RCX)) {
        if (st->k[REG_RCX] != RS_FRAME || st->k[8] != RS_IMM || !st->va[8] || st->va[8] > 1024) return 0;
        f->ext[f->next][0] = (int64_t)st->va[REG_RCX]; f->ext[f->next][1] = (int64_t)st->va[REG_RCX] + 8 * (int64_t)st->va[8]; f->next++;
    }
    return 1;
}

static int by_va(const void *x, const void *y) {
    uint64_t a = *(const uint64_t *)x, b = *(const uint64_t *)y;
    return a < b ? -1 : a > b;
}

/* Frame addresses, once the first solution of a conventional frame is in: every instruction that
 * forms or passes one is either bounded -- a lea of [rbp+d] used as a base at a constant offset,
 * copied register to register, or given to an enumeration_call -- or it is recorded in f->wild with
 * the lowest frame offset it may reach, after which, on that path, only selector slots wholly below
 * that offset are kept (wlo in RS). A frame address given to any other callee (in an argument
 * register at a call or tail jump) reaches the lowest such address, when every argument register
 * that may hold one holds a known one; everything else reaches any offset (LO_ALL). Recorded: a frame address read
 * as data (stored, combined, compared), used as an index, or as a base where some path left
 * another value; one in an argument register at any other call or tail jump, or returned; an
 * address formed from rsp, or from rbp other than as [rbp+d]; rsp or rbp copied or read as data.
 * *spills is set when some path spills a selector reference to a slot (else nothing to keep). */
static int frame_scan(const Slice *s, Flow *f, const uint8_t *base, uint64_t sect_addr, const uint64_t *ips, const Ins *ins, size_t n, int *spills) {
    size_t b, i;
    (void)n;
    *spills = 0; f->next = 0; f->nwild = 0;
    for (b = 0; b < f->nb; b++) {
        RS st = f->in[b];
        if (!st.reached) continue;
        for (i = f->bstart[b]; i < f->bstart[b + 1]; i++) {
            const Ins *x = &ins[i];
            const uint8_t *at = base + (ips[i] - sect_addr);
            uint16_t live = st.mf, data;
            int wild = 0, mem = x->modrm && x->mod != 3 && !x->riprel;
            int32_t call_lo = LO_NONE;   /* the lowest offset this instruction's escape may reach */
            int mbase = mem ? (x->sib ? x->sibbase : x->rm) : -1, midx = mem && x->sib ? x->sibindex : -1;
            if (i >= 2 && (gpr_reads_ex(x, 0) & ((1u << REG_RSP) | (1u << REG_RBP))) &&
                !(x->map == 0 && (x->op == 0x81 || x->op == 0x83) && x->modrm && x->mod == 3 && x->rm == REG_RSP))
                wild = 1;   /* rsp or rbp as data (a frame address made some other way) */
            if (x->map == 0 && x->op == 0x8D && mem && !frame_operand(f, x) &&
                (mbase == REG_RSP || mbase == REG_RBP || midx == REG_RSP || midx == REG_RBP))
                wild = 1;   /* lea from rsp, or from rbp with an index */
            if (mem && midx >= 0 && (live & (1u << midx))) wild = 1;
            if (mem && mbase >= 0 && (live & (1u << mbase)) && (st.k[mbase] != RS_FRAME || (x->map == 0 && x->op == 0x8D)))
                wild = 1;   /* a base some path left otherwise, or an address derived from a frame address */
            data = (uint16_t)(gpr_reads_ex(x, 0) & live);
            if (x->map == 0 && (x->op == 0x89 || x->op == 0x8B) && x->modrm && x->mod == 3 && (x->rex & 8)) {
                int src = x->op == 0x89 ? x->reg : x->rm;
                if (st.k[src] == RS_FRAME) data &= (uint16_t)~(1u << src);   /* a copy: its uses are checked in turn */
            }
            if (data) wild = 1;
            if ((is_ff(x, 2) || is_ff(x, 4)) && x->mod == 3 && (live & (1u << x->rm))) wild = 1;
            if ((is_call_any(x) || is_ff(x, 4) || is_ff(x, 5) || (is_jmp_rel(x) && tail_jump(base, sect_addr, ips, ins, n, i))) &&
                (live & ARG_REGS) && !(is_call_any(x) && enumeration_call(s, f, &st, x, ips[i], at))) {
                /* Given to a callee: it may write at and above each address it is given, never below
                 * (the stated limit every slot rests on), so the lowest of them bounds it -- when each
                 * argument register that may hold a frame address holds a known one on every path. */
                int r;
                for (r = 0; r < 16; r++) {
                    if (!(live & ARG_REGS & (1u << r))) continue;
                    if (st.k[r] != RS_FRAME) { call_lo = LO_ALL; break; }
                    if ((int64_t)st.va[r] < (int64_t)call_lo) call_lo = (int32_t)(int64_t)st.va[r];
                }
            }
            if (x->map == 0 && (x->op == 0xC3 || x->op == 0xC2) && (live & ((1u << REG_RAX) | (1u << REG_RDX)))) wild = 1;
            if (wild) call_lo = LO_ALL;
            if (x->map == 0 && x->op == 0x89 && (x->rex & 8) && frame_operand(f, x) && st.k[x->reg] == RS_SELREFV) *spills = 1;
            if (call_lo != LO_NONE) {
                if (f->nwild == f->capwild) {
                    struct Wild *g = realloc(f->wild, (f->capwild = f->capwild ? f->capwild * 2 : 64) * sizeof *g);
                    if (!g) return -1;
                    f->wild = g;
                }
                f->wild[f->nwild].ip = ips[i]; f->wild[f->nwild].lo = call_lo; f->nwild++;
            }
            transfer(s, f, &st, x, ips[i], at);
        }
    }
    if (f->nwild) {
        size_t j = 0;
        qsort(f->wild, f->nwild, sizeof *f->wild, by_va);   /* ip first: a struct Wild sorts by it */
        for (i = 0; i < f->nwild; i++) {
            if (j && f->wild[j - 1].ip == f->wild[i].ip) { if (f->wild[i].lo < f->wild[j - 1].lo) f->wild[j - 1].lo = f->wild[i].lo; }
            else f->wild[j++] = f->wild[i];
        }
        f->nwild = j;
    }
    return 0;
}

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

/* Whether the indirect jump at ip is an inline jump table's (jump_table_at). */
static int jt_has(const Slice *s, uint64_t ip) {
    size_t i;
    for (i = 0; i < s->njt; i++) if (s->jt[i].jmp == ip) return 1;
    return 0;
}

/* Whether code at ips[a..b) leaves the flags of ins[a-1] (only moves between them). */
static int flags_kept(const Ins *ins, size_t a, size_t b) {
    for (; a < b; a++) {
        const Ins *x = &ins[a];
        if (x->map == 0 && (x->op == 0x88 || x->op == 0x89 || x->op == 0x8A || x->op == 0x8B || x->op == 0x8D ||
                            x->op == 0xC6 || x->op == 0xC7 || x->op == 0x63))
            continue;
        if (x->map == 1 && (x->op == 0xB6 || x->op == 0xB7 || x->op == 0xBE || x->op == 0xBF)) continue;
        return 0;
    }
    return 1;
}

/* An inline jump table at T, the form clang writes into __text for a switch when no data-in-code
 * entry marks it (Apple clang 6 at -O0: shipyard's own updater, updater/main.m.in):
 *     cmp|sub idx, N-1 ; (moves) ; ja default
 *     lea R, [rip + T] ; movsxd D, dword [R + I*4] ; add D, R ; jmp D
 * with N int32 entries at T, each T plus itself an instruction start already decoded in this
 * function before T. Recognised only whole: the bound, the four instructions (nothing between
 * them writing R or D) and every entry; then each target is recorded as the jmp's successor and
 * the 4N bytes are data, so the reader does not decode them as code. Returns 4N, or 0 when the
 * bytes at T are not such a table (they are then decoded as before). -1 out of memory. */
static int64_t jump_table_at(Slice *s, uint64_t lo, uint64_t hi, uint64_t t, const uint8_t *at,
                             const uint64_t *ips, const Ins *ins, size_t n) {
    size_t a, b, c, d, e, j;
    for (a = 0; a < n; a++) {
        const Ins *l = &ins[a];
        int R, D, ja = -1;
        int64_t N = -1;
        if (!(l->map == 0 && l->op == 0x8D && (l->rex & 8) && l->riprel && l->riptarget == t)) continue;
        R = l->reg;
        for (b = a + 1; b < n && b < a + 12; b++) {
            const Ins *m = &ins[b];
            if (m->map == 0 && m->op == 0x63 && (m->rex & 8) && m->modrm && m->mod != 3 && m->sib &&
                m->sibbase == R && m->sibindex >= 0 && m->sibscale == 2 && m->mdisp == 0)
                break;
            if (may_write(m, R)) { b = n; break; }
        }
        if (b >= n || b >= a + 12) continue;
        D = ins[b].reg;
        c = b + 1;
        if (!(c < n && ins[c].map == 0 && ins[c].modrm && ins[c].mod == 3 && (ins[c].rex & 8) &&
              ((ins[c].op == 0x01 && ins[c].reg == R && ins[c].rm == D) || (ins[c].op == 0x03 && ins[c].reg == D && ins[c].rm == R))))
            continue;
        d = c + 1;
        if (!(d < n && is_ff(&ins[d], 4) && ins[d].mod == 3 && ins[d].rm == D)) continue;
        /* The bound: the nearest ja/jae before the lea, after a cmp/sub of an immediate with only
         * moves between. */
        for (j = a; j-- > 0 && j + 12 > a; ) {
            const Ins *x = &ins[j];
            if ((x->map == 0 && (x->op == 0x77 || x->op == 0x73)) || (x->map == 1 && (x->op == 0x87 || x->op == 0x83))) { ja = (int)j; break; }
            if (ends_flow(x) || is_call_any(x)) break;
        }
        if (ja < 0 || !flags_kept(ins, (size_t)ja + 1, a)) continue;
        for (j = (size_t)ja; j-- > 0 && j + 6 > (size_t)ja; ) {
            const Ins *x = &ins[j];
            if (x->map == 0 && (x->op == 0x81 || x->op == 0x83) && x->modrm && x->mod == 3 &&
                ((x->reg & 7) == 7 || (x->reg & 7) == 5) && x->imm >= 0) {
                if (!flags_kept(ins, j + 1, (size_t)ja)) break;
                N = x->imm + ((ins[ja].op == 0x77 || ins[ja].op == 0x87) ? 1 : 0);
                break;
            }
            if (x->map == 0 && x->op == 0x3D && x->imm >= 0) {
                if (!flags_kept(ins, j + 1, (size_t)ja)) break;
                N = x->imm + ((ins[ja].op == 0x77 || ins[ja].op == 0x87) ? 1 : 0);
                break;
            }
        }
        if (N < 1 || N > 4096 || (uint64_t)N * 4 > hi - t) continue;
        for (e = 0; e < (size_t)N; e++) {
            int32_t off;
            uint64_t tg;
            memcpy(&off, at + 4 * e, 4);
            tg = t + (uint64_t)(int64_t)off;
            if (tg < lo || tg >= t || index_of(ips, n, tg) < 0) break;
        }
        if (e < (size_t)N) continue;
        for (e = 0; e < (size_t)N; e++) {
            int32_t off;
            memcpy(&off, at + 4 * e, 4);
            if (s->njt == s->capjt) {
                void *g = realloc(s->jt, (s->capjt = s->capjt ? s->capjt * 2 : 64) * sizeof *s->jt);
                if (!g) return -1;
                s->jt = g;
            }
            s->jt[s->njt].jmp = ips[d]; s->jt[s->njt].target = t + (uint64_t)(int64_t)off; s->njt++;
        }
        return N * 4;
    }
    return 0;
}

/* The landing pads of the function [fn, end), from its LSDA: __TEXT,__unwind_info's LSDA index
 * names it, and its call-site table (lpStart omitted, the udata4 or uleb128 encoding) lists the
 * ranges whose calls unwind to each pad. Each range that lands is appended to f->cs. 0 with
 * f->ncs = 0 when the function has no LSDA there, or one this reader does not take apart (a
 * DWARF-only FDE's, another encoding, a pad outside the function): its pads then stay blocks
 * reached only indirectly. -1 out of memory. */
static int lsda_sites(const Slice *s, Flow *f, uint64_t fn, uint64_t end) {
    const Sect *ui = NULL, *lx;
    const uint8_t *u, *p, *q, *cse;
    uint64_t text = UINT64_MAX, lva, len, v[3];
    uint32_t idxoff, idxn, lo_off, hi_off, k;
    size_t i;
    int enc, j, c;
    f->ncs = 0;
    for (i = 0; i < s->nsects; i++)
        if (!strcmp(s->sects[i].seg, "__TEXT") && !strcmp(s->sects[i].sect, "__unwind_info")) ui = &s->sects[i];
    for (j = 0; j < s->res.nsegs; j++)
        if (s->res.segs[j].fileoff == 0 && s->res.segs[j].filesize) { text = s->res.segs[j].vmaddr; break; }
    if (!ui || text == UINT64_MAX || fn < text || fn - text > UINT32_MAX || !(u = bytes_at(s, ui->addr, ui->size)) || ui->size < 28)
        return 0;
    if (rd32(u) != 1) return 0;
    idxoff = rd32(u + 20); idxn = rd32(u + 24);
    if (idxn < 2 || idxoff > ui->size || (uint64_t)idxn * 12 > ui->size - idxoff) return 0;
    lo_off = rd32(u + idxoff + 8); hi_off = rd32(u + idxoff + (uint64_t)(idxn - 1) * 12 + 8);
    if (lo_off > hi_off || hi_off > ui->size || (hi_off - lo_off) % 8) return 0;
    for (k = lo_off; k < hi_off && rd32(u + k) != (uint32_t)(fn - text); k += 8) ;
    if (k >= hi_off) return 0;
    lva = text + rd32(u + k + 4);
    if (!(lx = sect_of(s, lva)) || !(p = bytes_at(s, lva, lx->size - (lva - lx->addr)))) return 0;
    q = p + (lx->size - (lva - lx->addr));
    if (q - p < 3 || *p++ != 0xff) return 0;                   /* lpStart: the function's start */
    if (*p++ != 0xff) { if (!(c = mu_decode(p, q, &len))) return 0; p += c; }   /* the type table */
    if (p >= q) return 0;
    enc = *p++;
    if (enc != 0x01 && enc != 0x03) return 0;
    if (!(c = mu_decode(p, q, &len)) || len > (uint64_t)(q - p - c)) return 0;
    p += c; cse = p + len;
    while (p < cse) {
        for (j = 0; j < 3; j++) {
            if (enc == 0x03) { if (cse - p < 4) goto bad; v[j] = rd32(p); p += 4; }
            else { if (!(c = mu_decode(p, cse, &v[j]))) goto bad; p += c; }
        }
        if (!(c = mu_decode(p, cse, &len))) goto bad;          /* the action */
        p += c;
        if (!v[2]) continue;                                    /* no landing pad: unwinding passes on */
        if (v[0] > end - fn || v[1] > end - fn - v[0] || v[2] >= end - fn) goto bad;
        if (f->ncs % 16 == 0) {
            struct CallSite *g = realloc(f->cs, (f->ncs + 16) * sizeof *g);
            if (!g) return -1;
            f->cs = g;
        }
        f->cs[f->ncs].lo = fn + v[0]; f->cs[f->ncs].hi = fn + v[0] + v[1]; f->cs[f->ncs].pad = fn + v[2]; f->ncs++;
    }
    if (p == cse) return 0;
bad:
    f->ncs = 0;
    return 0;
}

/* The state a call leaves for the landing pad it may unwind to: what transfer() leaves after the
 * call (the callee may have written exposed slots before it threw), with rax and rdx (the
 * exception object and selector) unknown and no path conditions. */
static void unwind_state(RS *e) {
    e->k[REG_RAX] = e->k[REG_RDX] = RS_UNKNOWN;
    e->me &= (uint16_t)~((1u << REG_RAX) | (1u << REG_RDX));
    e->mf &= (uint16_t)~((1u << REG_RAX) | (1u << REG_RDX));
    e->np = 0; memset(e->ls, 0, sizeof e->ls);
}

/* The direct edges out of block b, given st, the state after its last instruction: up to two
 * successors (fallthrough first, then the branch target) and the state each edge carries. A BOOL
 * test -- `test r8, r8` of a register holding a recent dispatch's result (or a byte copy of it),
 * then jz/jnz -- adds its outcome: the taken edge of jz is NO, of jnz YES, the fallthrough the
 * other. ah..bh (no REX, register 4..7) are not low bytes. Jump-table and landing-pad entries are
 * not direct edges (flow_build adds them). */
static int block_edges(const Slice *s, const Flow *f, const uint8_t *base, uint64_t sect_addr, const uint64_t *ips,
                       const Ins *ins, size_t n, size_t b, const RS *st, size_t succ[2], RS edge[2]) {
    size_t last = f->bstart[b + 1] - 1;
    int ns = 0, taken_val = -1, li = -1;
    uint64_t gsite = 0;
    const Ins *x = &ins[last];
    if (last > f->bstart[b]) {
        const Ins *t = &ins[last - 1];
        int jz = (x->map == 0 && x->op == 0x74) || (x->map == 1 && x->op == 0x84);
        int jnz = (x->map == 0 && x->op == 0x75) || (x->map == 1 && x->op == 0x85);
        if ((jz || jnz) && t->map == 0 && t->op == 0x84 && t->modrm && t->mod == 3 && t->reg == t->rm &&
            !(t->rex & 8) && (t->rex || t->rm < 4) && (st->k[t->rm] == RS_SEND || st->k[t->rm] == RS_BOOL)) {
            int q;
            gsite = st->va[t->rm];
            for (q = 0; q < 4; q++) if (st->ls[q].site && st->ls[q].site == gsite) { li = q; break; }
            if (li >= 0) taken_val = jnz;
        }
    }
    if (!no_fallthrough(s, base, sect_addr, ips, ins, last) && b + 1 < f->nb) {
        edge[ns] = *st;
        if (taken_val >= 0) pred_add(&edge[ns], gsite, !taken_val, st->ls[li].k, st->ls[li].va);
        succ[ns++] = b + 1;
    }
    if (is_jcc(x) || is_jmp_rel(x)) {
        uint64_t t = (uint64_t)rel_target(base + (ips[last] - sect_addr), x, ips[last]);
        long j = t >= ips[0] && t < ins[n - 1].next ? index_of(ips, n, t) : -1;
        if (j >= 0) {
            edge[ns] = *st;
            if (taken_val >= 0) pred_add(&edge[ns], gsite, taken_val, st->ls[li].k, st->ls[li].va);
            succ[ns++] = f->blk[j];
        }
    }
    return ns;
}

static int flow_build(const Slice *s, Flow *f, const uint8_t *base, uint64_t sect_addr, const uint64_t *ips, const Ins *ins, size_t n) {
    uint8_t *leader = calloc(n + 1, 1), *direct = NULL, *inq = NULL;
    size_t i, b, *queue = NULL, qh = 0, qt = 0, qn = 0;   /* ring of nb slots; inq keeps qn <= nb */
    int pass;
    f->built = 1; f->ok = 0; f->n = n; f->ijump = 0;
    if (!leader) return -1;
    frame_setup(f, ins, n);
    f->bounded = 0; f->next = 0; f->nwild = 0;
    if (f->frame) rsp_setup(f, ins, n);
    leader[0] = 1;
    for (i = 0; i < n; i++) {
        const Ins *x = &ins[i];
        if (is_jcc(x) || is_jmp_rel(x)) {
            uint64_t t = (uint64_t)rel_target(base + (ips[i] - sect_addr), x, ips[i]);
            if (t >= ips[0] && t < ins[n - 1].next) {
                long j = index_of(ips, n, t);
                if (j < 0) { free(leader); return 0; }
                leader[j] = 1;
            }
        }
        if (i + 1 < n && (is_jcc(x) || no_fallthrough(s, base, sect_addr, ips, ins, i))) leader[i + 1] = 1;
        if ((is_ff(x, 4) || is_ff(x, 5)) && !x->riprel && !jt_has(s, ips[i])) f->ijump = 1;
    }
    for (i = 0; i < s->njt; i++) {
        long j = index_of(ips, n, s->jt[i].target);
        if (j >= 0) leader[j] = 1;
    }
    if (lsda_sites(s, f, ips[0], ins[n - 1].next) < 0) { free(leader); return -1; }
    for (i = 0; i < f->ncs; i++) {   /* a pad that is not an instruction here: the LSDA is not this code's */
        long j = index_of(ips, n, f->cs[i].pad);
        if (j < 0) { f->ncs = 0; break; }
        leader[j] = 1;
    }
    f->blk = malloc(n * sizeof *f->blk); f->bstart = malloc((n + 1) * sizeof *f->bstart);
    if (!f->blk || !f->bstart) { free(leader); return -1; }
    for (i = 0, b = 0; i < n; i++) { if (leader[i]) f->bstart[b++] = i; f->blk[i] = b - 1; }
    f->nb = b; f->bstart[b] = n;
    if (!(f->lpad = calloc(f->nb, 1)) || !(f->plain = calloc(f->nb, 1))) { free(leader); return -1; }
    for (i = 0; i < f->ncs; i++) f->lpad[f->blk[index_of(ips, n, f->cs[i].pad)]] = 1;
    f->in = malloc(f->nb * sizeof *f->in);
    direct = calloc(f->nb, 1); inq = calloc(f->nb, 1); queue = malloc(f->nb * sizeof *queue);
    if (!f->in || !direct || !inq || !queue) { free(leader); free(direct); free(inq); free(queue); return -1; }
    for (pass = 0; ; pass++) {
    for (b = 0; b < f->nb; b++) rs_all(&f->in[b], RS_UNDEF, LO_NONE);
    for (i = 0; i < n; i++) {   /* blocks something reaches by a direct edge or fallthrough */
        const Ins *x = &ins[i];
        if (is_jcc(x) || is_jmp_rel(x)) {
            uint64_t t = (uint64_t)rel_target(base + (ips[i] - sect_addr), x, ips[i]);
            long j = t >= ips[0] && t < ins[n - 1].next ? index_of(ips, n, t) : -1;
            if (j >= 0) direct[f->blk[j]] = 1;
        }
        if (i + 1 < n && leader[i + 1] && !no_fallthrough(s, base, sect_addr, ips, ins, i)) direct[f->blk[i + 1]] = 1;
    }
    for (i = 0; i < s->njt; i++) {   /* an inline jump table's targets: reached from its jmp */
        long j = index_of(ips, n, s->jt[i].target);
        if (j >= 0) direct[f->blk[j]] = 1;
    }
    /* Seed the entry -- its argument registers named, no frame address escaped yet -- and every
     * block nothing reaches directly, which starts fully unknown with the whole frame exposed;
     * except alignment padding (only NOPs) after an unconditional transfer, which is unreachable
     * rather than unknown, and an LSDA landing pad in a function with no indirect jump that could
     * be a jump table: only the unwinder enters it, from the calls its call-site ranges cover,
     * so it starts from what those calls leave (below) and nothing else. */
    for (b = 0; b < f->nb; b++) {
        int pad = b != 0;
        for (i = f->bstart[b]; pad && i < f->bstart[b + 1]; i++)
            pad = (ins[i].map == 0 && ins[i].op == 0x90 && !(ins[i].rex & 1)) || (ins[i].map == 1 && ins[i].op == 0x1F);
        if (b == 0 || (!direct[b] && !pad && !(f->lpad[b] && !f->ijump))) {
            rs_all(&f->in[b], RS_UNKNOWN, b == 0 ? LO_NONE : LO_ALL);
            f->in[b].wlo = b != 0 ? LO_ALL : LO_NONE;   /* a frame address may arrive unseen */
            if (b) leader[f->bstart[b]] = 2;   /* seeded: reached only indirectly */
            if (b == 0) {
                static const int args[] = { REG_RDI, REG_RSI, REG_RDX, REG_RCX, 8, 9 };
                for (i = 0; i < 6; i++) { f->in[0].k[args[i]] = RS_ARG; f->in[0].va[args[i]] = i; }
            }
            queue[qt] = b; qt = (qt + 1) % f->nb; qn++; inq[b] = 1;
        }
    }
    for (b = 0; b < f->nb; b++) f->plain[b] = b != 0 && leader[f->bstart[b]] != 2 && !f->lpad[b];
    for (i = 0; i < s->njt; i++) {
        long j = index_of(ips, n, s->jt[i].target);
        if (j >= 0) f->plain[f->blk[j]] = 0;
    }
    for (;;) {
    uint16_t u = 0;
    uint64_t ums = 0;
    while (qn) {
        RS st, pre;
        size_t last;
        b = queue[qh]; qh = (qh + 1) % f->nb; qn--; inq[b] = 0;
        st = f->in[b];
        pre = st;
        for (i = f->bstart[b]; i < f->bstart[b + 1]; i++) {
            if (i + 1 == f->bstart[b + 1]) pre = st;   /* before the block's last instruction */
            transfer(s, f, &st, &ins[i], ips[i], base + (ips[i] - sect_addr));
        }
        last = f->bstart[b + 1] - 1;
        {
            size_t succ[2]; int ns, k;
            RS edge[2];
            const Ins *x = &ins[last];
            ns = block_edges(s, f, base, sect_addr, ips, ins, n, b, &st, succ, edge);
            for (k = 0; k < ns; k++)
                if (rs_meet(&f->in[succ[k]], &edge[k]) && !inq[succ[k]]) {
                    queue[qt] = succ[k]; qt = (qt + 1) % f->nb; qn++; inq[succ[k]] = 1;
                }
            if (is_ff(x, 4) && x->mod == 3) {   /* an inline jump table: every target gets the state at its jmp */
                size_t c;
                for (c = 0; c < s->njt; c++) {
                    long j;
                    size_t tb;
                    if (s->jt[c].jmp != ips[last] || (j = index_of(ips, n, s->jt[c].target)) < 0) continue;
                    tb = f->blk[j];
                    if (rs_meet(&f->in[tb], &pre) && !inq[tb]) { queue[qt] = tb; qt = (qt + 1) % f->nb; qn++; inq[tb] = 1; }
                }
            }
        }
    }
    /* An in-function indirect jump (a jump table) may carry an entry point in a register to the
     * blocks seeded unknown: they start with every register some such jump may carry it in, so
     * entry_escapes sees the uses there. A jump through a register holding an entry point on every
     * path, or through a GOT slot, is a tail call, not a jump table. */
    for (b = 0; b < f->nb; b++) {
        RS st = f->in[b];
        const Ins *x = &ins[f->bstart[b + 1] - 1];
        if (!st.reached || !(st.me || st.ms) || !is_ff(x, 4) || x->riprel || jt_has(s, ips[f->bstart[b + 1] - 1])) continue;
        for (i = f->bstart[b]; i + 1 < f->bstart[b + 1]; i++) transfer(s, f, &st, &ins[i], ips[i], base + (ips[i] - sect_addr));
        if (x->mod == 3 && st.k[x->rm] == RS_ENTRY) continue;
        u |= st.me; ums |= st.ms;
    }
    for (b = 1; b < f->nb; b++)
        if (leader[f->bstart[b]] == 2 && ((f->in[b].me | u) != f->in[b].me || (f->in[b].ms | ums) != f->in[b].ms)) {
            f->in[b].me |= u; f->in[b].ms |= ums;
            if (!inq[b]) { queue[qt] = b; qt = (qt + 1) % f->nb; qn++; inq[b] = 1; }
        }
    /* Landing pads: the unwinder enters one from a call inside a call-site range that names it
     * (the return address less one lies in the range), with the callee-saved registers and the
     * frame as that call left them (System V ABI; the LSDA is the function's own table). Each
     * such call's state after it, less rax/rdx and path conditions, meets into the pad. */
    for (b = 0; f->ncs && b < f->nb; b++) {
        RS st = f->in[b];
        if (!st.reached) continue;
        for (i = f->bstart[b]; i < f->bstart[b + 1]; i++) {
            const Ins *x = &ins[i];
            transfer(s, f, &st, x, ips[i], base + (ips[i] - sect_addr));
            if (is_call_any(x)) {
                size_t c;
                for (c = 0; c < f->ncs; c++)
                    if (x->next - 1 >= f->cs[c].lo && x->next - 1 < f->cs[c].hi) {
                        size_t pb = f->blk[index_of(ips, n, f->cs[c].pad)];
                        RS e = st;
                        unwind_state(&e);
                        if (rs_meet(&f->in[pb], &e) && !inq[pb]) { queue[qt] = pb; qt = (qt + 1) % f->nb; qn++; inq[pb] = 1; }
                    }
            }
        }
    }
    if (!qn) break;
    }
    if (pass || !f->frame) break;
    {   /* the frame's escapes, from this solution; only spilled selectors are worth a second one */
        int spills = 0;
        if (frame_scan(s, f, base, sect_addr, ips, ins, n, &spills) < 0) { free(leader); free(direct); free(inq); free(queue); return -1; }
        if (!spills) break;
        f->bounded = 1;
    }
    }
    free(leader); free(direct); free(inq); free(queue);
    f->ok = 1;
    return 0;
}

/* The value register r holds on entry to instruction `at`: its RS_* kind (RS_UNKNOWN when
 * nothing is known), with *va and *def set; -1 when out of memory. */
static int reg_value(const Slice *s, Flow *f, const uint8_t *base, uint64_t sect_addr,
                     const uint64_t *ips, const Ins *ins, size_t n, size_t at, int r,
                     uint64_t *va, uint64_t *def) {
    RS st;
    size_t i, b;
    if (!f->built && flow_build(s, f, base, sect_addr, ips, ins, n) < 0) return -1;
    if (!f->ok) return RS_UNKNOWN;
    b = f->blk[at];
    st = f->in[b];
    if (!st.reached) return RS_UNKNOWN;
    for (i = f->bstart[b]; i < at; i++) transfer(s, f, &st, &ins[i], ips[i], base + (ips[i] - sect_addr));
    *va = st.va[r]; *def = st.def[r];
    return st.k[r] == RS_UNDEF ? RS_UNKNOWN : st.k[r];
}

/* The path conditions on entry to instruction `at` (report.h ObjcCond); 0, or -1 out of memory. */
static int conds_at(const Slice *s, Flow *f, const uint8_t *base, uint64_t sect_addr,
                    const uint64_t *ips, const Ins *ins, size_t n, size_t at, ObjcCond *out, size_t *nout) {
    RS st;
    size_t i, b;
    *nout = 0;
    if (!f->built && flow_build(s, f, base, sect_addr, ips, ins, n) < 0) return -1;
    if (!f->ok) return 0;
    b = f->blk[at];
    st = f->in[b];
    if (!st.reached) return 0;
    for (i = f->bstart[b]; i < at; i++) transfer(s, f, &st, &ins[i], ips[i], base + (ips[i] - sect_addr));
    for (i = 0; i < st.np; i++) { out[i].site = st.p[i].site; out[i].value = st.p[i].val; }
    *nout = st.np;
    return 0;
}

/* Merged calls. A compiler may merge sends from several paths into one call (Apple clang 21 -Os
 * tail-merges `c ? [[x mutableCopy] autorelease] : [NSMutableDictionary dictionary]`: each path
 * loads its own selector reference's address and receiver, and the join loads the selector
 * through that address and calls). At the join the paths disagree, so the meet has no selector or
 * no receiver. The call is then read once per incoming path instead: the state on entry to it
 * along each direct edge into its block -- the predecessor's state on that edge, conditions
 * included, carried through the block -- when that block is entered by direct edges only
 * (not the entry, a block reached only indirectly, a landing pad or a jump-table case), by 2 to
 * NPATH of them from distinct instructions. The edges are exactly those the meet took, so each
 * path's operands are what that path brings, and together they are every way the call is reached.
 * Sorted by the predecessor's last instruction, which names the path. */
#define NPATH 8
typedef struct { uint64_t from; RS st; } PathIn;
static int path_states(const Slice *s, Flow *f, const uint8_t *base, uint64_t sect_addr,
                       const uint64_t *ips, const Ins *ins, size_t n, size_t at, PathIn *out, size_t *nout) {
    size_t b, p, i, np = 0;
    *nout = 0;
    if (!f->built && flow_build(s, f, base, sect_addr, ips, ins, n) < 0) return -1;
    if (!f->ok) return 0;
    b = f->blk[at];
    if (!f->plain[b] || !f->in[b].reached) return 0;
    for (p = 0; p < f->nb; p++) {
        RS st, edge[2];
        size_t succ[2], q;
        int ns, e;
        uint64_t from;
        if (!f->in[p].reached) continue;
        st = f->in[p];
        for (i = f->bstart[p]; i < f->bstart[p + 1]; i++) transfer(s, f, &st, &ins[i], ips[i], base + (ips[i] - sect_addr));
        ns = block_edges(s, f, base, sect_addr, ips, ins, n, p, &st, succ, edge);
        from = ips[f->bstart[p + 1] - 1];
        for (e = 0; e < ns; e++) {
            if (succ[e] != b) continue;
            if (np == NPATH) return 0;
            for (q = 0; q < np; q++) if (out[q].from == from) return 0;   /* a branch to the next instruction */
            out[np].from = from; out[np].st = edge[e]; np++;
        }
    }
    if (np < 2) return 0;
    for (p = 0; p < np; p++)
        for (i = f->bstart[b]; i < at; i++) transfer(s, f, &out[p].st, &ins[i], ips[i], base + (ips[i] - sect_addr));
    for (p = 1; p < np; p++) {
        PathIn t = out[p];
        for (i = p; i > 0 && out[i - 1].from > t.from; i--) out[i] = out[i - 1];
        out[i] = t;
    }
    *nout = np;
    return 0;
}

/* A selector operand the report can name. */
static int sel_named(const ObjcValue *v) {
    return v->form == OBJC_VAL_SEL_CACHE || ((v->form == OBJC_VAL_SELREF || v->form == OBJC_VAL_SEL_LITERAL ||
                                              v->form == OBJC_VAL_SEL_NSSTRING) && v->text);
}

static const char *REGNAME[16] = { "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
                                   "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };

/* Whether the direct jump at i leaves the function. */
static int tail_jump(const uint8_t *base, uint64_t sect_addr, const uint64_t *ips, const Ins *ins, size_t n, size_t i) {
    uint64_t t = (uint64_t)rel_target(base + (ips[i] - sect_addr), &ins[i], ips[i]);
    return t < ips[0] || t >= ins[n - 1].next;
}

/* A function that loads an objc entry point from its GOT slot into a register (modern -Os code
 * hoists the load and calls through the register again and again) is followed only when every
 * use of that register, on every path, is a call or jump through it while it holds that entry
 * point on every path, or a 64-bit copy of it to another register (Apple clang 6 tail-calls
 * `mov rax, rbx; pop rbx; jmp rax`), whose uses the same rule then governs. Refused, at the
 * instruction: any other read -- a spill, an address formed from it, an operand of anything else,
 * a copy where some path left another value --, a call through it where some path left another
 * value, the value in an argument register at another call or jump, or in
 * rax/rdx at a return. Without the function's direct control flow nothing is followed. */
/* Bytes an instruction may read at its memory operand; 64 when this module does not know the
 * form (more than any read here). */
static int64_t read_width(const Ins *x) {
    int op = x->op;
    if (x->map == 0) {
        if ((op <= 0x3F && !(op & 1) && (op & 7) <= 3) || op == 0x84 || op == 0x86 || op == 0x8A || op == 0x80 ||
            op == 0xC0 || op == 0xD0 || op == 0xD2 || op == 0xF6 || op == 0xFE)
            return 1;
        if ((op <= 0x3F && (op & 1) && (op & 7) <= 3) || op == 0x85 || op == 0x87 || op == 0x8B || op == 0x81 ||
            op == 0x83 || op == 0xC1 || op == 0xD1 || op == 0xD3 || op == 0xF7 || op == 0xFF || op == 0x69 || op == 0x6B)
            return x->rex & 8 ? 8 : x->p66 ? 2 : 4;
        if (op == 0x63) return 4;
        return 64;
    }
    if (x->map == 1) {
        if (op == 0xB6 || op == 0xBE) return 1;
        if (op == 0xB7 || op == 0xBF) return 2;
        if ((op >= 0x40 && op <= 0x4F) || op == 0xAF) return x->rex & 8 ? 8 : x->p66 ? 2 : 4;
        if (op == 0x10 || (op >= 0x51 && op <= 0x5F)) return x->f2 ? 8 : x->f3 ? 4 : 16;
        if (op == 0x2E || op == 0x2F) return x->p66 ? 8 : 4;
        if (op == 0x12 || op == 0x16 || (op == 0x7E && x->f3)) return 8;
        if (op == 0x6E) return x->rex & 8 ? 8 : 4;
        if (op == 0x28 || op == 0x6F) return 16;
    }
    return 64;
}

/* Whether an instruction with a memory operand writes it and never reads it. */
static int mem_write_only(const Ins *x) {
    if (x->map == 0) return x->op == 0x88 || x->op == 0x89 || x->op == 0xC6 || x->op == 0xC7 || x->op == 0x8D;
    if (x->map == 1) return x->op == 0x11 || x->op == 0x29 || x->op == 0x2B || x->op == 0x7F || x->op == 0xE7 ||
                            x->op == 0x13 || x->op == 0x17 || x->op == 0xD6 || (x->op >= 0x90 && x->op <= 0x9F);
    return 0;
}

/* The lowest slot index with an `ms` bit at or above the escaped extent `lo`, or -1. */
static int exposed_entry_slot(const Flow *f, const RS *r) {
    size_t i;
    for (i = 0; i < f->nslot; i++) if ((r->ms & (1ull << i)) && f->slot[i] >= r->lo) return (int)i;
    return -1;
}

static void entry_escapes(Slice *s, Flow *f, const uint8_t *base, uint64_t sect_addr, uint64_t fn_start,
                          const uint64_t *ips, const Ins *ins, size_t n) {
    static const int args[] = { REG_RDI, REG_RSI, REG_RDX, REG_RCX, 8, 9 };
    size_t b, i;
    if (!f->built && flow_build(s, f, base, sect_addr, ips, ins, n) < 0) { fail(s, "out-of-memory", fn_start, "%s", "flow"); return; }
    if (!f->ok) { fail(s, "indirect-objc-entry", fn_start, "%s", "objc entry point loaded in a function whose control flow is not followed"); return; }
    for (b = 0; b < f->nb; b++) {
        RS st = f->in[b];
        if (!st.reached) continue;
        if (exposed_entry_slot(f, &st) >= 0)
            fail(s, "indirect-objc-entry", ips[f->bstart[b]], "%s",
                 "objc entry point spilled to a frame slot that a frame address escaped on some path may reach");
        for (i = f->bstart[b]; i < f->bstart[b + 1]; i++) {
            const Ins *x = &ins[i];
            uint16_t live = st.me, through = 0, hit;
            int j, r = -1, was_exposed = exposed_entry_slot(f, &st) >= 0;
            const char *how = NULL;
            if (st.ms && x->modrm && x->mod != 3 && !x->riprel && !mem_write_only(x)) {
                /* A spilled entry point leaves its slot only through a 64-bit reload into a register. */
                int mb = x->sib ? x->sibbase : x->rm, mi = x->sib ? x->sibindex : -1, si = -1;
                int64_t lo = 0, hi = 0;
                int known = 1;
                size_t q;
                if (x->dispscaled && (mb == REG_RSP || mb == REG_RBP || mi == REG_RSP || mi == REG_RBP)) { lo = INT64_MIN / 2; hi = INT64_MAX / 2; }
                else if (x->dispscaled) known = 0;
                else if (frame_operand(f, x)) { lo = x->mdisp; hi = lo + read_width(x); si = slot_of(f, x->mdisp); }
                else if (mb == REG_RSP && mi < 0 && f->rsp_fixed) { lo = f->rsp_off + x->mdisp; hi = lo + read_width(x); }
                else if (mb == REG_RSP || mb == REG_RBP || mi == REG_RSP || mi == REG_RBP) { lo = INT64_MIN / 2; hi = INT64_MAX / 2; }
                else known = 0;   /* through another register: the escaped-extent check below governs */
                if (known && !(x->map == 0 && x->op == 0x8B && (x->rex & 8) && si >= 0 && (st.ms & (1ull << si))))
                    for (q = 0; q < f->nslot; q++)
                        if ((st.ms & (1ull << q)) && f->slot[q] + 8 > lo && f->slot[q] < hi) {
                            char msg[160];
                            snprintf(msg, sizeof msg, "objc entry point spilled to [rbp%+d] is read other than by a reload into a register", (int)f->slot[q]);
                            fail(s, "indirect-objc-entry", ips[i], "%s", msg);
                            break;
                        }
            }
            if (live) {
                if (x->map == 0 && x->op == 0x89 && (x->rex & 8) && x->modrm && x->mod != 3 && frame_operand(f, x) &&
                    (live & (1u << x->reg))) {
                    /* A spill: the slot then carries the entry point (transfer, `ms`) to its reloads. */
                    int si = slot_of(f, x->mdisp);
                    r = x->reg;
                    if (si < 0) how = "is spilled to a frame slot this reader does not follow";
                    else if (st.k[x->reg] != RS_ENTRY) how = "is spilled where another path left a different value";
                    else if (!f->rsp_fixed || f->slot[si] < f->rsp_off) how = "is spilled outside the function's fixed frame";
                    else if (f->slot[si] >= st.lo) how = "is spilled to a frame slot an escaped frame address may reach";
                    else live &= (uint16_t)~(1u << x->reg);
                }
            }
            if (live) {
                if (!how && (is_ff(x, 2) || is_ff(x, 4)) && x->mod == 3) {
                    through = (uint16_t)(1u << x->rm);
                    if ((live & through) && st.k[x->rm] != RS_ENTRY) { r = x->rm; how = "is called through where another path left a different value"; }
                }
                if (!how && x->map == 0 && (x->op == 0x89 || x->op == 0x8B) && x->modrm && x->mod == 3 && (x->rex & 8)) {
                    int src = x->op == 0x89 ? x->reg : x->rm;   /* a register copy (an epilogue's tail call) */
                    if (st.k[src] == RS_ENTRY) live &= (uint16_t)~(1u << src);
                }
                if (!how && (hit = gpr_reads(x) & live)) {
                    for (r = 0; !(hit & (1u << r)); r++) ;
                    how = "is read other than to call through it (a spill, a copy or an escape)";
                }
                if (!how && (is_call_any(x) || (is_ff(x, 4) && !jt_has(s, ips[i])) || is_ff(x, 5) ||
                             (is_jmp_rel(x) && tail_jump(base, sect_addr, ips, ins, n, i))))
                    for (j = 0; j < 6 && !how; j++)
                        if ((live & (1u << args[j])) && !(through & (1u << args[j]))) { r = args[j]; how = "is passed as an argument"; }
                if (!how && x->map == 0 && (x->op == 0xC3 || x->op == 0xC2) && (live & ((1u << REG_RAX) | (1u << REG_RDX)))) {
                    r = live & (1u << REG_RAX) ? REG_RAX : REG_RDX; how = "is returned";
                }
            }
            if (how) {
                char msg[160];
                snprintf(msg, sizeof msg, "objc entry point in %s %s", REGNAME[r], how);
                fail(s, "indirect-objc-entry", ips[i], "%s", msg);
            }
            transfer(s, f, &st, x, ips[i], base + (ips[i] - sect_addr));
            /* A frame address escaping (a lea at or below the slot) while the slot may hold an entry
             * point: code holding the address may read it (macho-reader.c header, frame slots). */
            if (!was_exposed && exposed_entry_slot(f, &st) >= 0)
                fail(s, "indirect-objc-entry", ips[i], "%s",
                     "objc entry point spilled to a frame slot that this frame address escape may reach");
        }
    }
}

static int note_fetch_arg(Slice *s, uint64_t ip) {
    if (s->nfas == s->capfas) {
        uint64_t *g = realloc(s->fetch_arg_sites, (s->capfas = s->capfas ? s->capfas * 2 : 128) * sizeof *g);
        if (!g) return fail(s, "out-of-memory", ip, "%s", "fetch sites");
        s->fetch_arg_sites = g;
    }
    s->fetch_arg_sites[s->nfas++] = ip;
    return 0;
}

static int is_code_sect(const Sect *x) {
    uint8_t type = x->flags & SECTION_TYPE;
    return (x->flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)) && type != S_SYMBOL_STUBS;
}

/* The objc-relevant thing an address names: stub/GOT entry with a non-OTHER role, a cache, a
 * fetch function, or a selref/classref slot. */
static int interesting_target(Slice *s, uint64_t t) {
    const Ptr *p = find_ptr(s->ptrs, s->nptrs, t);
    const Sect *x;
    if (p && p->role != IMP_OTHER) return 1;
    if (find_cache(s, t) || is_fetch(s, t)) return 1;
    x = sect_of(s, t);
    return x && (!strcmp(x->sect, "__objc_selrefs") || !strcmp(x->sect, "__objc_classrefs") ||
                 !strcmp(x->sect, "__objc_superrefs"));
}

/* Undecodable bytes: refuse if any rel32 or rip-relative disp32 alignment could name an
 * objc-relevant address. The over-approximation is sound for direct references. */
static int sweep_undecodable(Slice *s, uint64_t lo, const uint8_t *code, uint64_t len) {
    uint64_t i;
    static const int tails[] = { 0, 1, 2, 4 };
    for (i = 0; i + 4 <= len; i++) {
        int32_t d; int t;
        memcpy(&d, code + i, 4);
        for (t = 0; t < 4; t++) {
            uint64_t target = lo + i + 4 + (uint64_t)tails[t] + (uint64_t)(int64_t)d;
            if (interesting_target(s, target)) {
                char msg[64];
                snprintf(msg, sizeof msg, "0x%llx", (unsigned long long)target);
                return fail(s, "undecodable-objc-reference", lo + i, "possible reference to %s", msg);
            }
        }
    }
    s->a->limit_undecoded_bytes += len;
    return 0;
}

static uint64_t dice_end(const Slice *s, uint64_t ip) {
    size_t lo = 0, hi = s->ndice;
    while (lo < hi) { size_t mid = lo + (hi - lo) / 2; if (s->dice[mid].lo <= ip) lo = mid + 1; else hi = mid; }
    if (lo && ip < s->dice[lo - 1].hi) return s->dice[lo - 1].hi;
    return 0;
}

/* A cache's literal, from a fetch call or an inlined fetch's store. Conflicting literals for
 * one static are refused. */
static int record_fetch(Slice *s, Cache *c, uint64_t site, const char *lit) {
    if (!c->literal) {
        if (!(c->literal = strdup(lit))) return fail(s, "out-of-memory", site, "%s", "literal");
        c->fetch_site = site;
    } else if (strcmp(c->literal, lit)) {
        c->conflict = 1;
        fail(s, "cache-literal-conflict", site, "%s", c->symbol);
        return 0;
    }
    return add_ev(s, OBJC_EV_CACHE_FETCH, site, c->addr, NULL, NULL, c->kind == 1 ? lit : NULL,
                  c->kind == 2 ? lit : NULL, c->symbol) ? -1 : 0;
}

/* A selector/class producer call: its name argument must be a C-string literal, a constant
 * CFString, or (for NS*FromString) NSString::from_str over literal bytes. */
static int producer_site(Slice *s, Flow *flow, const uint8_t *base, const Sect *x, const uint64_t *ips,
                         const Ins *ins, size_t n, size_t k, ImportRole role, const char *callee, uint64_t target) {
    char lit[MAX_LITERAL];
    uint64_t va = 0, def = 0, site = ips[k];
    int ns = role == IMP_SEL_PRODUCER_NSSTRING || role == IMP_CLASS_PRODUCER_NSSTRING;
    int sel = role == IMP_SEL_PRODUCER || role == IMP_SEL_PRODUCER_NSSTRING, ok = 0;
    int kd = reg_value(s, flow, base, x->addr, ips, ins, n, k, REG_RDI, &va, &def);
    if (kd < 0) return fail(s, "out-of-memory", site, "%s", "flow"), -1;
    if (!ns && kd == RS_CONST) ok = !literal_at(s, va, lit, sizeof lit);
    else if (ns && kd == RS_CONST) ok = !cfstring_at(s, va, lit, sizeof lit);
    else if (ns && kd == RS_NSSTR && def > 0 && def < sizeof lit) {
        const uint8_t *p = bytes_at(s, va, def);
        uint64_t i;
        ok = p != NULL;
        for (i = 0; ok && i < def; i++) ok = p[i] >= 0x21 && p[i] <= 0x7e;
        if (ok) { memcpy(lit, p, def); lit[def] = 0; }
    }
    if (!ok) {
        fail(s, sel ? "computed-selector-producer" : "computed-class-producer", site,
             "%s argument is not a recognised literal", callee);
        return 0;
    }
    (void)target;
    return add_ev(s, sel ? OBJC_EV_SEL_REGISTER : OBJC_EV_CLASS_LOOKUP, site, va, sel ? NULL : lit, NULL,
                  sel ? lit : NULL, callee, NULL) ? -1 : 0;
}

/* A store into a cache static: only the result of a recognised literal producer of the
 * matching kind (an inlined fetch) is supported. */
static int cache_store(Slice *s, Flow *flow, const uint8_t *base, const Sect *x, const uint64_t *ips,
                       const Ins *ins, size_t n, size_t k, Cache *c) {
    uint64_t va, def, site = ips[k];
    char lit[MAX_LITERAL];
    int kd = reg_value(s, flow, base, x->addr, ips, ins, n, k, ins[k].reg, &va, &def);
    if (kd < 0) return fail(s, "out-of-memory", site, "%s", "flow"), -1;
    if ((kd != RS_SELLIT && kd != RS_CLASSLIT) || (kd == RS_SELLIT) != (c->kind == 1) ||
        literal_at(s, va, lit, sizeof lit)) {
        fail(s, "unrecognized-cache-store", site, "%s", c->symbol);
        return 0;
    }
    return record_fetch(s, c, site, lit) || note_fetch_arg(s, site) ? -1 : 0;
}

/* GOT loads of objc entry points into a register: a function with any is checked by entry_escapes. */
typedef struct { uint64_t ip; } Entry;

static int pending_entry(Slice *s, Entry **v, size_t *n, uint64_t ip) {
    Entry *g;
    size_t i;
    for (i = 0; i < *n; i++) if ((*v)[i].ip == ip) return 0;
    g = realloc(*v, (*n + 1) * sizeof **v);
    if (!g) return fail(s, "out-of-memory", ip, "%s", "entries");
    *v = g; g[*n].ip = ip; (*n)++;
    return 0;
}

/* A propagated register value as a report operand. Cache names are filled in after every fetch
 * site has been read (code()); reference slots and literals are named here. */
static void operand_of(const Slice *s, int kd, uint64_t va, uint64_t def, ObjcValue *v, char *buf, size_t bufsz) {
    const Cache *c;
    uint64_t p;
    int meta;
    v->ref = va; v->text = NULL;
    switch (kd) {
    case RS_CACHEVAL:
        c = cache_at(s, va);
        v->form = c && c->kind == 2 ? OBJC_VAL_CLASS_CACHE : OBJC_VAL_SEL_CACHE;
        break;
    case RS_SELREFV:
        v->form = OBJC_VAL_SELREF;
        if (!read64(s, va, &p) && !literal_at(s, p, buf, bufsz)) v->text = buf;
        break;
    case RS_CLASSREFV:
        v->form = OBJC_VAL_CLASSREF;
        if (!class_ref_name(s, va, buf, bufsz, &meta)) v->text = buf;
        break;
    case RS_SELLIT: case RS_CLASSLIT:
        v->form = kd == RS_SELLIT ? OBJC_VAL_SEL_LITERAL : OBJC_VAL_CLASS_LITERAL;
        if (!literal_at(s, va, buf, bufsz)) v->text = buf;
        break;
    case RS_SELNS: {
        const uint8_t *b = def > 0 && def < bufsz ? bytes_at(s, va, def) : NULL;
        uint64_t i;
        v->form = OBJC_VAL_SEL_NSSTRING;
        for (i = 0; b && i < def; i++) if (b[i] < 0x21 || b[i] > 0x7e) b = NULL;
        if (b) { memcpy(buf, b, def); buf[def] = 0; v->text = buf; }
        break;
    }
    case RS_SEND: v->form = OBJC_VAL_RESULT; break;
    case RS_ARG: v->form = OBJC_VAL_ARGUMENT; break;
    default: v->form = OBJC_VAL_UNKNOWN; v->ref = 0; break;
    }
}

/* Which registers a dispatch entry point takes its receiver, selector and first argument in:
 * the _stret forms shift by one; allocation/opt entry points have an implied selector. */
static void dispatch_regs(const char *callee, int *recv, int *sel, int *arg) {
    *recv = REG_RDI; *sel = REG_RSI; *arg = REG_RDX;
    if (strstr(callee, "_stret")) { *recv = REG_RSI; *sel = REG_RDX; *arg = REG_RCX; }
    else if (!strncmp(callee, "_objc_alloc", 11) || !strcmp(callee, "_objc_opt_new") ||
             !strcmp(callee, "_objc_opt_class") || !strcmp(callee, "_objc_opt_self")) { *sel = -1; *arg = -1; }
    else if (!strcmp(callee, "_objc_opt_isKindOfClass") || !strcmp(callee, "_objc_opt_respondsToSelector")) {
        *sel = -1; *arg = REG_RSI;
    }
}

/* The symbol naming the function that starts at `start`, or NULL. */
static const char *function_name(const Slice *s, uint64_t start) {
    size_t lo = 0, hi = s->nsym;
    while (lo < hi) { size_t mid = lo + (hi - lo) / 2; if (s->syms[mid].addr < start) lo = mid + 1; else hi = mid; }
    return lo < s->nsym && s->syms[lo].addr == start ? s->syms[lo].name : NULL;
}

/* One function [lo, hi) of code section x. Site-level refusals are recorded and the scan
 * continues, so one report lists every unsupported form; any of them still fails the stage. */
static int scan_function(Slice *s, const Sect *x, uint64_t lo, uint64_t hi,
                         uint64_t **ipbuf, Ins **insbuf, size_t *cap) {
    uint64_t ip = lo;
    size_t n = 0, k;
    int touches_cache = 0;   /* only a function that names a cache can store into one via a register */
    Entry *entries = NULL; size_t nentries = 0;
    uint64_t *cand = NULL; size_t ncand = 0;   /* forward rip-relative lea targets in this function */
    Flow flow;
    const uint8_t *base = bytes_at(s, x->addr, x->size);
    if (!base) return fail(s, "malformed-macho", x->addr, "%s", "code section outside the file");
    s->cur_fn = function_name(s, lo);
    s->njt = 0;
    while (ip < hi) {
        uint64_t skip = dice_end(s, ip);
        Ins in;
        if (skip) { ip = skip < hi ? skip : hi; continue; }
        for (k = 0; k < ncand && cand[k] != ip; k++) ;
        if (k < ncand) {   /* a forward lea's target: an inline jump table's data, or code after all */
            int64_t t = jump_table_at(s, lo, hi, ip, base + (ip - x->addr), *ipbuf, *insbuf, n);
            if (t < 0) { free(cand); return fail(s, "out-of-memory", ip, "%s", "jump tables"); }
            if (t > 0) { ip += (uint64_t)t; continue; }
        }
        if (decode(base + (ip - x->addr), (size_t)(hi - ip), ip, &in) != 0) {
            sweep_undecodable(s, ip, base + (ip - x->addr), hi - ip);
            break;
        }
        if (n == *cap) {
            size_t c2 = *cap ? *cap * 2 : 4096;
            uint64_t *g1 = realloc(*ipbuf, c2 * sizeof **ipbuf);
            Ins *g2;
            if (g1) *ipbuf = g1;
            g2 = g1 ? realloc(*insbuf, c2 * sizeof **insbuf) : NULL;
            if (!g1 || !g2) { free(cand); return fail(s, "out-of-memory", ip, "%s", "instructions"); }
            *insbuf = g2; *cap = c2;
        }
        (*ipbuf)[n] = ip; (*insbuf)[n] = in; n++;
        if (in.riprel && find_cache(s, in.riptarget)) touches_cache = 1;
        if (in.map == 0 && in.op == 0x8D && in.riprel && in.riptarget > ip && in.riptarget < hi) {
            if (ncand % 16 == 0) {
                uint64_t *g = realloc(cand, (ncand + 16) * sizeof *g);
                if (!g) { free(cand); return fail(s, "out-of-memory", ip, "%s", "jump tables"); }
                cand = g;
            }
            cand[ncand++] = in.riptarget;
        }
        ip = in.next;
    }
    free(cand);
    if (!n) return s->status;
    memset(&flow, 0, sizeof flow);

#define REG_VAL(reg, va, def) reg_value(s, &flow, base, x->addr, *ipbuf, *insbuf, n, k, reg, va, def)
    for (k = 0; k < n; k++) {
        const Ins *in = &(*insbuf)[k];
        uint64_t site = (*ipbuf)[k], target = 0;
        int call = 0, jump = 0, through_ptr = 0;
        const Ptr *p = NULL;
        if (is_call_rel(in) || (in->map == 0 && in->op == 0xE9)) {
            target = (uint64_t)rel_target(base + (site - x->addr), in, site);
            call = is_call_rel(in); jump = !call;
        } else if ((is_ff(in, 2) || is_ff(in, 4)) && in->riprel) {
            target = in->riptarget; call = is_ff(in, 2); jump = !call; through_ptr = 1;
        } else if ((is_ff(in, 2) || is_ff(in, 4)) && in->mod == 3) {
            uint64_t eva, edef;             /* call reg, reg loaded from an objc GOT slot */
            int ke = REG_VAL(in->rm, &eva, &edef);
            if (ke < 0) { flow_free(&flow); return fail(s, "out-of-memory", site, "%s", "flow"); }
            if (ke == RS_ENTRY) {
                target = eva; call = is_ff(in, 2); jump = !call; through_ptr = 1;
            }
        }
        if (call || jump) {
            int f = is_fetch(s, target);
            p = find_ptr(s->ptrs, s->nptrs, target);
            if (f) {
                uint64_t cva, lva, cdef, ldef;
                Cache *c = NULL;
                char lit[MAX_LITERAL];
                int r1 = REG_VAL(REG_RDI, &cva, &cdef), r2 = r1 == RS_CONST ? REG_VAL(REG_RSI, &lva, &ldef) : 0;
                if (r1 < 0 || r2 < 0) { flow_free(&flow); return fail(s, "out-of-memory", site, "%s", "flow"); }
                if (jump || r1 != RS_CONST || !(c = find_cache(s, cva)) || c->kind != f || r2 != RS_CONST ||
                    literal_at(s, lva, lit, sizeof lit)) {
                    fail(s, "unrecognized-fetch-site", site, "%s",
                         f == OBJC_FETCH_SEL ? "CachedSel::fetch arguments are not a cache static and a literal"
                                             : "CachedClass::fetch arguments are not a cache static and a literal");
                    continue;
                }
                if ((cdef && note_fetch_arg(s, cdef)) || record_fetch(s, c, site, lit)) { flow_free(&flow); return s->status; }
                continue;
            }
            if (!f && call_kind(s, target) == 1 && !p) {   /* Sel::register_unchecked(name) */
                if (producer_site(s, &flow, base, x, *ipbuf, *insbuf, n, k, IMP_SEL_PRODUCER,
                                  "objc2::runtime::Sel::register_unchecked", target) < 0)
                    { flow_free(&flow); return s->status; }
                continue;
            }
            if (p && p->role != IMP_OTHER) {
                switch (p->role) {
                case IMP_UNCLASSIFIED:
                    fail(s, "unclassified-objc-runtime-import", site, "%s", p->name);
                    break;
                case IMP_CLASS_CREATION:
                    fail(s, "runtime-class-creation", site, "%s: a class made or reparented at run time has no measured root", p->name);
                    break;
                case IMP_REGISTRATION:
                    if (add_ev(s, OBJC_EV_METHOD_REGISTRATION, site, target, NULL, NULL, NULL, p->name + 1, NULL))
                        { flow_free(&flow); return s->status; }
                    break;
                case IMP_DISPATCH: {
                    ObjcValue ov[3];
                    char text[3][MAX_LITERAL];
                    int regs[3], j;
                    dispatch_regs(p->name, &regs[0], &regs[1], &regs[2]);
                    for (j = 0; j < 3; j++) {
                        uint64_t va = 0, def = 0;
                        int kd = regs[j] < 0 ? RS_UNDEF : REG_VAL(regs[j], &va, &def);
                        if (kd < 0) { flow_free(&flow); return fail(s, "out-of-memory", site, "%s", "flow"); }
                        if (regs[j] < 0) { ov[j].form = OBJC_VAL_NONE; ov[j].ref = 0; ov[j].text = NULL; }
                        else operand_of(s, kd, va, def, &ov[j], text[j], sizeof text[j]);
                    }
                    /* A merged call: one record per incoming path, when every path names its
                     * selector and its receiver; otherwise the one record below says what the
                     * meet lost. */
                    if ((regs[1] >= 0 && !sel_named(&ov[1])) || ov[0].form == OBJC_VAL_UNKNOWN) {
                        PathIn pv[NPATH];
                        ObjcValue pov[NPATH][3];
                        char ptext[3][MAX_LITERAL];
                        size_t np = 0, q;
                        int all = 1;
                        if (path_states(s, &flow, base, x->addr, *ipbuf, *insbuf, n, k, pv, &np) < 0)
                            { flow_free(&flow); return fail(s, "out-of-memory", site, "%s", "flow"); }
                        /* operand_of names reference slots and literals into ptext: check them now,
                         * record them (one path at a time, while ptext holds them) below. */
                        for (q = 0; q < np && all; q++)
                            for (j = 0; j < 2; j++) {
                                const RS *st = &pv[q].st;
                                int kd = regs[j] < 0 ? RS_UNDEF : st->k[regs[j]];
                                if (regs[j] < 0) continue;
                                operand_of(s, kd == RS_UNDEF ? RS_UNKNOWN : kd, st->va[regs[j]], st->def[regs[j]], &pov[q][j],
                                           ptext[j], sizeof ptext[j]);
                                if (j == 0 ? pov[q][j].form == OBJC_VAL_UNKNOWN : !sel_named(&pov[q][j])) all = 0;
                            }
                        if (np && all) {
                            for (q = 0; q < np; q++) {
                                ObjcCond cv[OBJC_MAX_CONDS];
                                size_t c, nc = pv[q].st.np;
                                for (j = 0; j < 3; j++) {
                                    const RS *st = &pv[q].st;
                                    int kd = regs[j] < 0 ? RS_UNDEF : st->k[regs[j]];
                                    if (regs[j] < 0) { pov[q][j].form = OBJC_VAL_NONE; pov[q][j].ref = 0; pov[q][j].text = NULL; }
                                    else operand_of(s, kd == RS_UNDEF ? RS_UNKNOWN : kd, st->va[regs[j]], st->def[regs[j]],
                                                    &pov[q][j], ptext[j], sizeof ptext[j]);
                                }
                                for (c = 0; c < nc; c++) { cv[c].site = pv[q].st.p[c].site; cv[c].value = pv[q].st.p[c].val; }
                                if (add_dispatch(s, site, target, p->name + 1, jump ? "tail" : NULL, &pov[q][0], &pov[q][1], &pov[q][2],
                                                 cv, nc, pv[q].from))
                                    { flow_free(&flow); return s->status; }
                            }
                            break;
                        }
                    }
                    {
                        ObjcCond cv[OBJC_MAX_CONDS];
                        size_t nc = 0;
                        if (conds_at(s, &flow, base, x->addr, *ipbuf, *insbuf, n, k, cv, &nc) < 0)
                            { flow_free(&flow); return fail(s, "out-of-memory", site, "%s", "flow"); }
                        if (add_dispatch(s, site, target, p->name + 1, jump ? "tail" : NULL, &ov[0], &ov[1], &ov[2], cv, nc, 0))
                        { flow_free(&flow); return s->status; }
                    }
                    break;
                }
                case IMP_SEL_PRODUCER: case IMP_SEL_PRODUCER_NSSTRING:
                case IMP_CLASS_PRODUCER: case IMP_CLASS_PRODUCER_NSSTRING:
                    if (inside_fetch(s, site)) break;   /* attributed to each fetch/wrapper call site */
                    if (producer_site(s, &flow, base, x, *ipbuf, *insbuf, n, k, p->role, p->name + 1, target) < 0)
                        { flow_free(&flow); return s->status; }
                    break;
                default: break;
                }
                continue;
            }
            if (!through_ptr) continue;
        }
        if (touches_cache && in->map == 0 && in->op == 0x89 && (in->rex & 8) && in->modrm && in->mod != 3 && !in->riprel && !in->sib) {
            uint64_t bva, bdef;          /* mov [reg+disp], src where reg holds a cache's address */
            int kb = REG_VAL(in->rm, &bva, &bdef);
            Cache *c;
            if (kb < 0) { flow_free(&flow); return fail(s, "out-of-memory", site, "%s", "flow"); }
            if (kb == RS_CONST && (c = find_cache(s, bva + (uint64_t)in->mdisp))) {
                if (cache_store(s, &flow, base, x, *ipbuf, *insbuf, n, k, c) < 0) { flow_free(&flow); return s->status; }
                continue;
            }
        }
        if (in->riprel) {
            uint64_t t = in->riptarget;
            Cache *c = find_cache(s, t);
            const Sect *tx;
            const Ptr *q;
            if (c && in->map == 0 && in->op == 0x89 && (in->rex & 8)) {   /* mov [rip+cache], reg */
                if (cache_store(s, &flow, base, x, *ipbuf, *insbuf, n, k, c) < 0) { flow_free(&flow); return s->status; }
                continue;
            }
            if (c) {
                int lea = in->map == 0 && in->op == 0x8D;
                if (add_ev(s, OBJC_EV_CACHE_USE, site, t, NULL, NULL, NULL, lea ? "address" : "load", c->symbol))
                    { flow_free(&flow); return s->status; }
                continue;
            }
            if (is_fetch(s, t)) { fail(s, "indirect-objc-entry", site, "%s", "fetch function address taken"); continue; }
            q = find_ptr(s->ptrs, s->nptrs, t);
            if (q && q->role != IMP_OTHER && q->role != IMP_MEMORY && q->role != IMP_PASSTHROUGH && q->role != IMP_INTROSPECT) {
                if (in->map == 0 && in->op == 0x8B && (in->rex & 8)) {   /* settled by a call reg below */
                    if (pending_entry(s, &entries, &nentries, site)) { flow_free(&flow); return s->status; }
                } else fail(s, "indirect-objc-entry", site, "%s address taken", q->name);
                continue;
            }
            tx = sect_of(s, t);
            if (tx && (!strcmp(tx->sect, "__objc_selrefs") || !strcmp(tx->sect, "__objc_classrefs") ||
                       !strcmp(tx->sect, "__objc_superrefs")))
                if (add_ev(s, OBJC_EV_METADATA_USE, site, t, NULL, NULL, NULL, tx->sect, NULL))
                    { flow_free(&flow); return s->status; }
        }
    }
#undef REG_VAL
    if (nentries) entry_escapes(s, &flow, base, x->addr, lo, *ipbuf, *insbuf, n);
    free(entries);
    flow_free(&flow);
    return s->status;
}

static int code(Slice *s) {
    size_t i, f, cap = 0;
    uint64_t *ips = NULL;
    Ins *ins = NULL;
    for (i = 0; i < s->nsects; i++) {
        const Sect *x = &s->sects[i];
        uint64_t end = x->addr + x->size;
        if (!is_code_sect(x)) continue;
        for (f = 0; f < s->nstarts; f++) {
            uint64_t lo = s->starts[f], hi = f + 1 < s->nstarts ? s->starts[f + 1] : end;
            if (lo < x->addr || lo >= end) continue;
            if (hi > end) hi = end;
            if (scan_function(s, x, lo, hi, &ips, &ins, &cap) && s->a->n_errors &&
                !strcmp(s->a->errors[s->a->n_errors - 1].code, "out-of-memory")) break;
        }
    }
    free(ips); free(ins);

    s->cur_fn = NULL;
    /* Cache records, and uses that are not fetch arguments. */
    qsort(s->fetch_arg_sites, s->nfas, sizeof *s->fetch_arg_sites, cmp_u64);
    for (i = 0; i < s->ncaches; i++) {
        Cache *c = &s->caches[i];
        if (add_ev(s, c->kind == 1 ? OBJC_EV_SEL_CACHE : OBJC_EV_CLASS_CACHE, c->addr, c->fetch_site, NULL,
                   NULL, c->kind == 1 ? c->literal : NULL, c->kind == 2 ? c->literal : NULL, c->symbol))
            return s->status;
    }
    {
        /* Drop the CACHE_USE rows that are a fetch call's own `lea rdi`. */
        size_t w = 0, n = s->a->n_evidence;
        ObjcEvidence *v = s->a->evidence;
        for (i = 0; i < n; i++) {
            if (v[i].kind == OBJC_EV_CACHE_USE && !strcmp(v[i].slice, s->slice) &&
                bsearch(&v[i].address, s->fetch_arg_sites, s->nfas, sizeof *s->fetch_arg_sites, cmp_u64)) {
                free(v[i].slice); free(v[i].owner); free(v[i].method_kind); free(v[i].selector);
                free(v[i].name); free(v[i].symbol); free(v[i].function);
                free(v[i].receiver.text); free(v[i].sel.text); free(v[i].arg.text);
                continue;
            }
            v[w++] = v[i];
        }
        s->a->n_evidence = w;
        /* A cache consumed but never fetched has no recoverable name. */
        for (i = 0; i < w; i++)
            if (v[i].kind == OBJC_EV_CACHE_USE && !strcmp(v[i].slice, s->slice)) {
                Cache *c = find_cache(s, v[i].target);
                if (c && !c->literal) return fail(s, "cache-without-fetch", v[i].address, "%s", c->symbol);
            }
        /* Name the cache operands of each dispatch now that every fetch site has been read. */
        for (i = 0; i < w; i++) {
            ObjcValue *ops[3];
            int j;
            if (v[i].kind != OBJC_EV_DISPATCH_CALL || strcmp(v[i].slice, s->slice)) continue;
            ops[0] = &v[i].receiver; ops[1] = &v[i].sel; ops[2] = &v[i].arg;
            for (j = 0; j < 3; j++) {
                Cache *c;
                if (ops[j]->form != OBJC_VAL_SEL_CACHE && ops[j]->form != OBJC_VAL_CLASS_CACHE) continue;
                if (!(c = find_cache(s, ops[j]->ref)) || !c->literal)
                    return fail(s, "cache-without-fetch", v[i].address, "%s", c ? c->symbol : "cache operand");
                if (objc_set_string(&ops[j]->text, c->literal))
                    return fail(s, "out-of-memory", v[i].address, "%s", "operand");
            }
        }
    }
    return 0;
}

/* ---- slices ----------------------------------------------------------------------------- */

static void slice_close(Slice *s) {
    size_t i;
    if (s->res_open) mml_resolver_close(&s->res);
    for (i = 0; i < s->ncaches; i++) free(s->caches[i].literal);
    free(s->jt); free(s->caches); free(s->sects); free(s->syms); free(s->ptrs); free(s->binds); free(s->starts);
    free(s->dice); free(s->fetch_arg_sites);
}

static int analyze_slice(ObjcAnalysis *a, uint8_t *buf, size_t size, uint32_t cputype, uint32_t cpusub) {
    Slice s;
    LcCtx c;
    memset(&s, 0, sizeof s);
    memset(&c, 0, sizeof c);
    s.a = a; c.s = &s;
    ma_describe(cputype, cpusub, s.slice);
    if (mi_wrap(buf, size, &s.im) != 0)
        return objc_fail(a, "malformed-macho", s.slice, 0, "slice does not validate as a 64-bit Mach-O");
    if (s.im.hdr->filetype == MH_OBJECT)
        return objc_fail(a, "unsupported-macho-type", s.slice, 0, "relocatable object, not a linked image");
    /* metadata_only: a shipped image read for its interface (main.m "The shipped closure"). */
    if (!load_tables(&s, &c) && !metadata(&s) && !a->metadata_only) code(&s);
    slice_close(&s);
    return s.status;
}

int objc_collect_artifacts(ObjcAnalysis *a) {
    FILE *f;
    struct stat st;
    uint8_t *buf;
    size_t size;
    uint32_t magic;
    int status = OBJC_OK, measured = 0;
    if (!a->artifact_path) return objc_fail(a, "no-artifact", NULL, 0, "no artifact path");
    if (!(f = fopen(a->artifact_path, "rb")) || fstat(fileno(f), &st) != 0 || !S_ISREG(st.st_mode)) {
        int e = errno;
        if (f) fclose(f);
        return objc_fail(a, "unreadable-artifact", NULL, 0, "%s: %s", a->artifact_path, strerror(e ? e : EINVAL));
    }
    if (st.st_size < 4 || (uint64_t)st.st_size > (uint64_t)SIZE_MAX / 2) {
        fclose(f);
        return objc_fail(a, "malformed-macho", NULL, 0, "%s: implausible size", a->artifact_path);
    }
    size = (size_t)st.st_size;
    if (!(buf = malloc(size))) { fclose(f); return objc_fail(a, "out-of-memory", NULL, 0, "artifact"); }
    if (fread(buf, 1, size, f) != size) {
        free(buf); fclose(f);
        return objc_fail(a, "unreadable-artifact", NULL, 0, "%s: short read", a->artifact_path);
    }
    fclose(f);
    memcpy(&magic, buf, 4);
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        uint32_t narch, i;
        int swapped;
        if (mfat_parse(buf, size, &narch, &swapped) != 0) {
            free(buf);
            return objc_fail(a, "malformed-macho", NULL, 0, "fat header does not validate");
        }
        for (i = 0; i < narch; i++) {
            mfat_arch ar;
            char name[32];
            mfat_get(buf, swapped, i, &ar);
            ma_describe(ar.cputype, ar.cpusubtype, name);
            if (ar.cputype == CPU_TYPE_X86_64) {
                int r = analyze_slice(a, buf + ar.offset, ar.size, ar.cputype, ar.cpusubtype);
                if (r) status = r;
                measured++;
            } else if (ar.cputype == CPU_TYPE_I386 && !a->metadata_only) {
                status = objc_fail(a, "unsupported-slice", name, 0, "i386 code runs on 10.9 and is not read");
            }
        }
    } else if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64 || magic == MH_MAGIC || magic == MH_CIGAM) {
        uint32_t cpu = 0, sub = 0;
        if (size >= 12) { memcpy(&cpu, buf + 4, 4); memcpy(&sub, buf + 8, 4); }
        if (magic == MH_MAGIC_64 && cpu == CPU_TYPE_X86_64) {
            status = analyze_slice(a, buf, size, cpu, sub);
            measured++;
        } else if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
            char name[32];
            ma_describe(cpu, sub, name);
            free(buf);
            return objc_fail(a, "no-x86_64-slice", name, 0, "thin %s image", name);
        } else {
            free(buf);
            return objc_fail(a, "malformed-macho", NULL, 0, "byte-swapped thin Mach-O");
        }
    } else {
        free(buf);
        return objc_fail(a, "malformed-macho", NULL, 0, "%s: not a Mach-O file", a->artifact_path);
    }
    free(buf);
    if (!measured && !status) status = objc_fail(a, "no-x86_64-slice", NULL, 0, "fat file without an x86_64 slice");
    if (status) return OBJC_CANNOT_MEASURE;
    return objc_bind_caches(a);
}

/* ---- image view (report.h ObjcImage) ---------------------------------------------------------- */

struct ObjcImage { Slice s; LcCtx c; uint8_t *buf; };

int objc_image_open(ObjcAnalysis *a, const char *path, ObjcImage **out) {
    FILE *f;
    struct stat st;
    ObjcImage *im;
    uint8_t *buf, *slice = NULL;
    size_t size, len = 0;
    uint32_t magic, cpu = 0, sub = 0;
    *out = NULL;
    if (!(f = fopen(path, "rb")) || fstat(fileno(f), &st) != 0 || !S_ISREG(st.st_mode)) {
        int e = errno;
        if (f) fclose(f);
        return objc_fail(a, "unreadable-artifact", NULL, 0, "%s: %s", path, strerror(e ? e : EINVAL));
    }
    if (st.st_size < 4 || (uint64_t)st.st_size > (uint64_t)SIZE_MAX / 2) { fclose(f); return objc_fail(a, "malformed-macho", NULL, 0, "%s: implausible size", path); }
    size = (size_t)st.st_size;
    if (!(buf = malloc(size))) { fclose(f); return objc_fail(a, "out-of-memory", NULL, 0, "image"); }
    if (fread(buf, 1, size, f) != size) { free(buf); fclose(f); return objc_fail(a, "unreadable-artifact", NULL, 0, "%s: short read", path); }
    fclose(f);
    memcpy(&magic, buf, 4);
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
        uint32_t narch, i;
        int swapped;
        if (mfat_parse(buf, size, &narch, &swapped) != 0) { free(buf); return objc_fail(a, "malformed-macho", NULL, 0, "%s: fat header does not validate", path); }
        for (i = 0; i < narch; i++) {
            mfat_arch ar;
            mfat_get(buf, swapped, i, &ar);
            if (ar.cputype == CPU_TYPE_X86_64) { slice = buf + ar.offset; len = ar.size; cpu = ar.cputype; sub = ar.cpusubtype; }
        }
    } else if (magic == MH_MAGIC_64 && size >= 12) {
        memcpy(&cpu, buf + 4, 4); memcpy(&sub, buf + 8, 4);
        if (cpu == CPU_TYPE_X86_64) { slice = buf; len = size; }
    }
    if (!slice) { free(buf); return objc_fail(a, "no-x86_64-slice", NULL, 0, "%s has no x86_64 slice", path); }
    if (!(im = calloc(1, sizeof *im))) { free(buf); return objc_fail(a, "out-of-memory", NULL, 0, "image"); }
    im->buf = buf; im->s.a = a; im->s.quiet = 1; im->c.s = &im->s;
    ma_describe(cpu, sub, im->s.slice);
    if (mi_wrap(slice, len, &im->s.im) != 0 || im->s.im.hdr->filetype == MH_OBJECT) {
        free(buf); free(im);
        return objc_fail(a, "malformed-macho", "x86_64", 0, "%s: not a linked 64-bit Mach-O image", path);
    }
    if (load_tables(&im->s, &im->c)) { objc_image_close(im); return OBJC_CANNOT_MEASURE; }
    *out = im;
    return OBJC_OK;
}

void objc_image_close(ObjcImage *im) {
    if (!im) return;
    slice_close(&im->s);
    free(im->buf);
    free(im);
}

const uint8_t *objc_image_bytes(const ObjcImage *im, uint64_t va, uint64_t len) { return bytes_at(&im->s, va, len); }

size_t objc_image_nsections(const ObjcImage *im) { return im->s.nsects; }

static const char *sect_name(const Sect *x, uint64_t *addr, uint64_t *size, uint32_t *flags) {
    static char name[40];
    if (addr) *addr = x->addr;
    if (size) *size = x->size;
    if (flags) *flags = x->flags;
    snprintf(name, sizeof name, "%s,%s", x->seg, x->sect);
    return name;
}

const char *objc_image_section(const ObjcImage *im, size_t i, uint64_t *addr, uint64_t *size, uint32_t *flags) {
    return i < im->s.nsects ? sect_name(&im->s.sects[i], addr, size, flags) : NULL;
}

const char *objc_image_section_of(const ObjcImage *im, uint64_t va, uint64_t *addr, uint64_t *size, uint32_t *flags) {
    const Sect *x = sect_of(&im->s, va);
    return x ? sect_name(x, addr, size, flags) : NULL;
}

const char *objc_image_import_at(const ObjcImage *im, uint64_t va) {
    const Ptr *p = find_ptr(im->s.ptrs, im->s.nptrs, va);
    return p ? p->name : NULL;
}

const char *objc_image_bound_at(const ObjcImage *im, uint64_t va) { return bound_name(&im->s, va); }

const char *objc_image_bound_lib_at(const ObjcImage *im, uint64_t va) {
    const Ptr *p = find_ptr(im->s.binds, im->s.nbinds, va);
    return p ? p->lib : NULL;
}

const char *objc_image_import_lib_at(const ObjcImage *im, uint64_t va) {
    const Ptr *p = find_ptr(im->s.ptrs, im->s.nptrs, va);
    return p ? p->lib : NULL;
}

int objc_image_has_symbol(const ObjcImage *im, const char *name, uint64_t va) {
    size_t i;
    for (i = 0; i < im->s.nsym; i++)
        if (im->s.syms[i].addr == va && !strcmp(im->s.syms[i].name, name)) return 1;
    return 0;
}
