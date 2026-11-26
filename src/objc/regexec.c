/* regexec.c -- the registration executor: what a provider's activation code adds to the Objective-C runtime,
 * derived from the linked image's bytes by path-forking execution from an entry (a provider's constructor).
 *
 * Values are concrete integers, image addresses (relocatable: an address as linked, which dyld slides), symbols for
 * runtime results -- Class(name), Meta(name), Sel(name), an opaque non-NULL Method or IMP -- or unknown. Only what no
 * slide changes is known of an image address: it plus or minus a constant (an image address), its difference from or
 * comparison with another, and that it is not NULL; any other operation on it (a compare with anything else, a shift,
 * mask or multiply, a partial read) is unknown. Only an image address or a stack address is a known memory operand. Every path starts with every register
 * unknown but rsp, and the image's initial bytes as memory. Execution forks, and both outcomes are explored, at:
 *   - objc_getClass: Class(literal), or NULL (the path's class_null, the literal in its null_classes);
 *   - the lookups (found, or not): class_getInstanceMethod, class_getClassMethod, class_respondsToSelector,
 *     class_getMethodImplementation (not found answers an opaque forwarding IMP). Recaulk's tabbing units import
 *     the first (llvm-nm -u of their archive: class_addMethod, class_getInstanceMethod, class_getName,
 *     object_getClass, objc_getClass, sel_getName, sel_registerName, and ARC, exception, associated-object and
 *     send entry points); the other three are the brief's. A lookup on a NULL class answers not found;
 *   - class_addMethod: success or failure, each recorded as an add (class, selector, IMP symbol, types, site); a
 *     failure fork exists only where the path read the result; an add whose result no instruction read has no failed
 *     twin. The failure forks before the first instruction that may read rax (x86.h's read set; a form it does not
 *     classify reads it) and at a return; a call, a tail jump, or a write of rax reading none of it drops it, but a
 *     tail jump to class_addMethod returns both ways;
 *   - a conditional branch, cmov or setcc whose flags are not known: both ways, each path counting it
 *     (unknown_forks: such a path may be infeasible; table_forks instead when the flags derive from the class table
 *     of "Start"). A path ending at int3 or ud2 is complete and trapped.
 * object_getClass(Class(n)) is Meta(n); sel_registerName(literal) is Sel(literal). Any other import -- the
 * mutators class_replaceMethod, method_setImplementation, method_exchangeImplementations, class_addProtocol,
 * objc_allocateClassPair, objc_registerClassPair, class_addIvar among them, and objc_msgSend, dispatch_once and
 * other callback-taking calls, which are never followed -- answers unknown and clobbers rax, rcx, rdx, rsi,
 * rdi, r8-r11 and the flags. Every mutator's call site on an explored path is recorded (mutator_sites), as is
 * the target in the ranges of every call or tail jump there, followed or summarised (called), and each
 * sel_registerName site with whether every arrival's argument was a literal read from the image (selreg), and
 * every function an explored path executed in (explored) and every instruction it executed (executed).
 *
 * Start (ObjcRegStart): a run from a root the app calls with a class may bind rdi, on every path, to Class(arg0_class),
 * as objc_getClass's result, so a test of it for NULL is known. Each tracked address (a member IMP's) is followed as
 * writable data is below, and its escapes are recorded with itself as va -- except as class_addMethod's IMP argument
 * at an add. An own-stores run allows a store into image data only of 8 bytes, at a known address within
 * [table_lo, table_hi), of Class(arg0_class); any other refuses image-store. Its root runs once per class, each call
 * seeing the stores of the calls before it, so a load overlapping that table is unknown -- never an initial value, nor
 * a path's own store -- carrying the table's contents, a base apart from its address; a fork on flags derived from
 * those contents counts in table_forks, not unknown_forks. The contents are never recorded as escaped; the table's
 * address is, as any writable address is.
 *
 * Provenance: every value carries the set of writable image addresses (any section outside __TEXT), and of tracked
 * addresses, it derives from. A lea yielding such an address, or a load of a rebased pointer to one (or of part of
 * it), adds that address; a result carries the union of the sets of the operands that flow into it, even when it is unknown -- a cmov the
 * selected one's, an xchg each the other's, a shift by cl its count's too. Flags carry the set of the operands that set
 * them, and setcc, cmov and adc/sbb add it to their result; a fork on flags with a set adds it to the path's, and every
 * escape on that path carries the path's too. A load through a known pointer carries the cell's set, not the
 * pointer's: one cell's, or every overlapping cell's when it spans several. Every set stored to the stack joins the
 * frame residue, which a return never drops; a stack load no one live cell holds (a dead frame, the red zone, bytes
 * spanning cells), or a load through an unknown address, carries it, the latter with the address registers' -- but not
 * a load through an import's address plus a constant, another image's memory. More than 8 addresses is any (~0 in
 * escaped). A value escapes (escaped: each address of its set, and itself when it points into
 * writable image data; the site; how) when it is in a modelled import's declared argument registers, or in any of
 * the 16 registers or any frame cell at an unknown import or a summarised callee; when it is stored anywhere but a
 * frame cell; and when it is returned from the entry or a function it called.
 * An instruction reading through an address no register makes known never touches a cell. The threat model is
 * good-faith compiled code: gadgets built by hand to launder an address are a stated limit, as is a callee that is
 * not followed reading the dead stack below rsp.
 *
 * Calls: a direct call or tail jump to an import stub, or a call or jump through an import's GOT slot or through
 * the address an 8-byte load of that slot gave (clang hoists objc_msgSend into a callee-saved register), is the
 * import's model; that address may be NULL (a weak import absent), so a test of it forks. A direct call into the given provider ranges is followed when a modelled import or a mutator
 * is reachable from its target by direct calls and jumps (a linear scan of each function, LC_FUNCTION_STARTS
 * bounding them; undecodable bytes, a computed call or jump, and a direct target outside the ranges that is no
 * import count as reaching, so execution meets and refuses them); otherwise it is summarised as an unknown import. A direct
 * target outside every range that is not an import refuses foreign-call, as does execution leaving the ranges;
 * any other indirect call or jump, and a return to an address not pushed by a followed call, refuses
 * indirect-call.
 *
 * Memory: a path's own stores are cells over the stack and writable image data, newest first; bytes no cell
 * covers read as the image's initial bytes (zero in a zerofill section) or, on the stack, unknown. A read of
 * initial bytes is recorded (const_reads), as is each C string a model reads as a literal. An 8-byte read must be
 * of a slot a REBASE_TYPE_POINTER entry covers, or of zero, else it refuses unverified-pointer; a read overlapping
 * a rebased, bound or imported slot otherwise is unknown, since dyld rewrites it. A store through an unknown
 * address, to any other address, or over a pushed return address refuses unknown-store; a store into __TEXT or
 * over a rebased, bound or imported slot refuses image-store (a table written at run time), as does, in an own-stores
 * run, any store but the root's class into its class table; other stores into image data are recorded
 * (image_stores). Frame addresses follow src/objc/macho-reader.c's frame-slot rule: one
 * that escapes -- in an argument register or a stack argument (any cell from rsp up to the nearest return address)
 * at an unknown call or summarised callee, or stored anywhere but by a push -- exposes every stack cell at or above the lowest such address, and every later unknown call makes the
 * exposed cells unknown. Stated limit, as there: code holding a frame address writes nothing below it, and no
 * callee writes a pushed register or return address. Every unknown call also makes the path's image-data
 * cells unknown (a summarised callee may write any global); initial bytes such a callee may write are what
 * const_reads lets a caller sweep for.
 *
 * Budgets (each refuses, naming it): paths started (path-budget), followed-call depth (depth-budget), and
 * instructions executed over all paths (insn-budget). An instruction form not modelled refuses
 * unsupported-instruction naming its address and bytes. A refusal stops everything: nothing in the result may
 * then be trusted. Nothing is executed natively. */
#include "regexec.h"
#include "x86.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { VU, VC, VS };
/* pw: only the low pw bytes are known (0: all). A symbol (VS) is nonzero, except one with v 1: an import's address,
 * which a weak import's absence makes NULL. */
/* rel: v is an image address as linked, which dyld slides at run time; ts: its provenance set (Ex's ts), 0 none. */
typedef struct { uint8_t k, pw, rel; uint32_t sym, ts; uint64_t v; } Val;
enum { SY_CLASS, SY_META, SY_SEL, SY_OPAQUE, SY_IMPORT };   /* SY_IMPORT: the address an import's GOT slot holds */
typedef struct { uint64_t a; uint8_t w, ret, push; Val v; } Cell;
typedef struct { const char *cls; int meta; const char *sel; } Look;
typedef struct { const char *cls; int meta; const char *sel, *imp, *types; uint64_t imp_va, site; int ok; } Add;
struct Ex;
typedef struct {
    struct Ex *ex;
    Val r[16]; uint64_t rip;
    int fop, fw; Val fa, fb, fr;              /* flags, lazily: 0 unknown, 1 add, 2 sub, 3 logic, 4 inc, 5 dec */
    uint32_t fts;                             /* the flags' provenance */
    uint32_t pts;                             /* the path's: every set a fork on flags decided it by */
    uint32_t res;                             /* the frame residue: every set ever stored to the stack */
    Cell *m; size_t nm, capm;
    uint64_t esc;                             /* lowest escaped frame address; 0 none */
    uint32_t tin;                             /* the provenance of what this instruction has read so far */
    size_t depth;
    Look *found; size_t nfound, capf;
    Add *adds; size_t nadds, capa;
    int class_null, trapped;
    const char **nulls; size_t nnull, capnull;   /* the classes objc_getClass returned NULL for (NULL: unnamed) */
    size_t uforks;                            /* decisions forked on unknown flags */
    size_t tforks;                            /* decisions forked on flags derived from the class table, not uforks */
    uint64_t tailret;                         /* a tail jump's site whose return this path, forked in its import, owes */
    size_t addfork;                           /* 1 + the index in adds of the add whose failed twin rax owes; 0 none */
} St;
#define TS_CAP 8
#define TS_ALL 1u                             /* more than TS_CAP bases: any writable address */
#define TABLE_BYTES (~1ULL)                   /* the base of a value loaded from the class table: no address */
typedef struct { uint8_t n; uint64_t b[TS_CAP]; } Tset;   /* ascending, distinct */
typedef struct Ex {
    const ObjcImage *im; ObjcRegBudget b; ObjcRegResult *out;
    const ObjcRegStart *start;
    Tset *ts; size_t nts, capts;              /* interned provenance sets: 0 empty, TS_ALL */
    uint64_t *rg; size_t nrg;                 /* sorted [lo, hi) pairs */
    size_t capescaped;
    size_t nfn; int8_t *reach;                /* per function start: 0 unknown, 1 summarised, 2 followed */
    size_t npaths, ninsns, cappaths, capsites, capselreg, capcalled, capreads, capstores, capexplored;
    uint64_t last_lo, last_hi;                /* the explored function the last instruction was in */
    uint64_t *exec; size_t capexec, nexec;    /* open-addressed set of executed instructions (0: empty) */
    struct { int kind; char *name; } *sym; size_t nsym, capsym;
    St **work; size_t nwork, capwork;
    uint32_t unread;                          /* the symbol standing in rax while an instruction not reading it runs */
} Ex;

#define STACK_TOP 0x7ff000100000ULL
#define STACK_SPAN 0x1000000ULL
#define SENTINEL 0xfffffffffffff000ULL
static int is_stack(uint64_t a) { return a <= STACK_TOP && a > STACK_TOP - STACK_SPAN; }
static uint64_t mask(int w) { return w >= 8 ? ~0ULL : (1ULL << (w * 8)) - 1; }
static Val U(void) { Val x; memset(&x, 0, sizeof x); return x; }
static Val C(uint64_t v) { Val x = U(); x.k = VC; x.v = v; return x; }
static Val Cp(uint64_t v, int pw) { Val x = C(v & mask(pw)); x.pw = (uint8_t)pw; return x; }
static Val S(uint32_t id) { Val x = U(); x.k = VS; x.sym = id; return x; }
static Val R(uint64_t v) { Val x = C(v); x.rel = 1; return x; }
static int is0(Val a) { return a.k == VC && !a.pw && !a.rel && !a.v; }
static int nonzero(Val a) { return a.k == VS && !a.v; }
static int same(Val a, Val b) { return a.k == b.k && a.k != VU && a.pw == b.pw && a.rel == b.rel && (a.k == VC ? a.v == b.v : a.sym == b.sym); }

static int grow(void **p, size_t *cap, size_t need, size_t sz) {
    void *q; size_t c = *cap ? *cap : 16;
    if (need <= *cap) return 0;
    while (c < need) c *= 2;
    if (!(q = realloc(*p, c * sz))) return -1;
    *p = q; *cap = c;
    return 0;
}
static int refuse(Ex *e, const char *code, const char *fmt, ...) {
    va_list ap;
    if (e->out->refused) return -1;
    e->out->refused = 1;
    snprintf(e->out->code, sizeof e->out->code, "%s", code);
    va_start(ap, fmt); vsnprintf(e->out->why, sizeof e->out->why, fmt, ap); va_end(ap);
    return -1;
}
static int oom(Ex *e) { return refuse(e, "insn-budget", "out of memory"); }

static uint32_t sym_new(Ex *e, int kind, const char *name) {
    size_t i;
    if (name && kind != SY_OPAQUE)
        for (i = 0; i < e->nsym; i++) if (e->sym[i].kind == kind && e->sym[i].name && !strcmp(e->sym[i].name, name)) return (uint32_t)i;
    if (grow((void **)&e->sym, &e->capsym, e->nsym + 1, sizeof *e->sym)) { oom(e); return UINT32_MAX; }
    e->sym[e->nsym].kind = kind; e->sym[e->nsym].name = name ? strdup(name) : NULL;
    return (uint32_t)e->nsym++;
}

/* ---- the image ---- */
static int in_ranges(const Ex *e, uint64_t a) {
    size_t lo = 0, hi = e->nrg;
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (e->rg[2 * mid + 1] <= a) lo = mid + 1; else hi = mid; }
    return lo < e->nrg && e->rg[2 * lo] <= a;
}
static uint64_t range_end(const Ex *e, uint64_t a) {
    size_t i;
    for (i = 0; i < e->nrg; i++) if (e->rg[2 * i] <= a && a < e->rg[2 * i + 1]) return e->rg[2 * i + 1];
    return a;
}
/* Index of the function start at or below a, or nfn. */
static size_t fn_at(const Ex *e, uint64_t a) {
    size_t lo = 0, hi = e->nfn;
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (objc_image_function(e->im, mid) <= a) lo = mid + 1; else hi = mid; }
    return lo ? lo - 1 : e->nfn;
}
static uint64_t fn_end(const Ex *e, uint64_t a) {
    size_t i = fn_at(e, a); uint64_t end = range_end(e, a), n;
    i = i == e->nfn ? 0 : i + 1;
    for (; i < e->nfn; i++) if ((n = objc_image_function(e->im, i)) > a) return n < end ? n : end;
    return end;
}
static int note_executed(Ex *e, uint64_t ip) {
    size_t i, h;
    if (2 * (e->nexec + 1) > e->capexec) {
        size_t c = e->capexec ? 2 * e->capexec : 4096; uint64_t *g = calloc(c, sizeof *g);
        if (!g) return oom(e);
        for (i = 0; i < e->capexec; i++)
            if (e->exec[i]) { for (h = (size_t)(e->exec[i] * 0x9E3779B97F4A7C15ULL) & (c - 1); g[h]; h = (h + 1) & (c - 1)) {} g[h] = e->exec[i]; }
        free(e->exec); e->exec = g; e->capexec = c;
    }
    for (h = (size_t)(ip * 0x9E3779B97F4A7C15ULL) & (e->capexec - 1); e->exec[h]; h = (h + 1) & (e->capexec - 1))
        if (e->exec[h] == ip) return 0;
    e->exec[h] = ip; e->nexec++;
    return 0;
}
/* The function holding ip, as out->explored records it. */
static int note_explored(Ex *e, uint64_t ip) {
    ObjcRegResult *o = e->out; size_t i, lo = 0, hi = e->nrg, fi; uint64_t a, b;
    if (note_executed(e, ip)) return -1;
    if (ip >= e->last_lo && ip < e->last_hi) return 0;
    while (lo < hi) { size_t mid = (lo + hi) / 2; if (e->rg[2 * mid + 1] <= ip) lo = mid + 1; else hi = mid; }
    if (lo == e->nrg || e->rg[2 * lo] > ip) return 0;   /* outside the ranges: execution refuses there */
    a = e->rg[2 * lo];
    if ((fi = fn_at(e, ip)) < e->nfn && objc_image_function(e->im, fi) > a) a = objc_image_function(e->im, fi);
    b = fn_end(e, ip);
    e->last_lo = a; e->last_hi = b;
    for (i = 0; i < o->n_explored; i++) if (o->explored[2 * i] == a) return 0;
    if (grow((void **)&o->explored, &e->capexplored, 2 * (o->n_explored + 1), sizeof *o->explored)) return oom(e);
    o->explored[2 * o->n_explored] = a; o->explored[2 * o->n_explored + 1] = b; o->n_explored++;
    return 0;
}
static int is_fn_start(const Ex *e, uint64_t a) { size_t i = fn_at(e, a); return i < e->nfn && objc_image_function(e->im, i) == a; }

static const char *const MUTATORS[] = { "class_addMethod", "class_replaceMethod", "method_setImplementation",
    "method_exchangeImplementations", "class_addProtocol", "objc_allocateClassPair", "objc_registerClassPair",
    "class_addIvar", NULL };
static const char *const MODELLED[] = { "objc_getClass", "object_getClass", "sel_registerName", "class_getInstanceMethod",
    "class_getClassMethod", "class_respondsToSelector", "class_getMethodImplementation", NULL };
static int listed(const char *const *l, const char *n) { for (; *l; l++) if (!strcmp(*l, n)) return 1; return 0; }
static const char *import_name(const Ex *e, uint64_t a) {
    const char *n = objc_image_import_at(e->im, a);
    return n && n[0] == '_' ? n + 1 : n;
}

/* Bytes for decoding at ip: up to 15, inside ip's section. */
static const uint8_t *code_at(const Ex *e, uint64_t ip, size_t *avail) {
    uint64_t sa, ss; uint32_t fl;
    if (!objc_image_section_of(e->im, ip, &sa, &ss, &fl)) return NULL;
    *avail = sa + ss - ip < 15 ? (size_t)(sa + ss - ip) : 15;
    return objc_image_bytes(e->im, ip, *avail);
}

/* Whether a modelled import or a mutator is reachable from a by direct calls and jumps. */
static int reaches(const Ex *e, uint64_t a, uint8_t *seen, int depth) {
    uint64_t ip, end; size_t fi = fn_at(e, a);
    if (depth > 256) return 1;
    if (fi < e->nfn) {   /* the whole function holding a, so a function seen is a function scanned */
        if (seen[fi]) return 0;
        seen[fi] = 1;
        if (in_ranges(e, objc_image_function(e->im, fi))) a = objc_image_function(e->im, fi);
    }
    ip = a; end = fn_end(e, a);
    while (ip < end) {
        size_t av; const uint8_t *p = code_at(e, ip, &av); ObjcIns x; const char *n; uint64_t t = 0; int has = 0;
        if (!p || objc_x86_decode(p, av, ip, &x)) return 1;
        if (objc_x86_is_call_rel(&x) || objc_x86_is_jmp_rel(&x) || objc_x86_is_jcc(&x)) { t = (uint64_t)objc_x86_rel_target(p, &x, ip); has = 1; }
        else if ((objc_x86_is_ff(&x, 2) || objc_x86_is_ff(&x, 4)) && x.riprel) { t = x.riptarget; has = 1; }
        if (has) {
            if ((n = import_name(e, t))) { if (listed(MUTATORS, n) || listed(MODELLED, n)) return 1; }
            else if (!x.riprel && !in_ranges(e, t)) return 1;   /* foreign code: followed, so it refuses */
            else if (x.riprel) return 1;                          /* through a slot no import names: likewise */
            else if ((t < a || t >= end) && reaches(e, t, seen, depth + 1)) return 1;
        } else if (objc_x86_is_ff(&x, 2) || objc_x86_is_ff(&x, 4)) return 1;   /* a computed call or jump */
        ip = x.next;
    }
    return 0;
}
static int follow(Ex *e, uint64_t t) {
    size_t fi = fn_at(e, t); uint8_t *seen; int r;
    if (fi < e->nfn && objc_image_function(e->im, fi) == t && e->reach[fi]) return e->reach[fi] == 2;
    if (!(seen = calloc(e->nfn + 1, 1))) return 1;
    r = reaches(e, t, seen, 0);
    free(seen);
    if (fi < e->nfn && objc_image_function(e->im, fi) == t) e->reach[fi] = (int8_t)(r ? 2 : 1);
    return r;
}

/* A rebased (1: exactly the 8-byte slot at a, when w is 8), partly rebased, bound or imported (2) slot in [a, a+w). */
static int relocated(const Ex *e, uint64_t a, int w) {
    uint64_t o; int exact = 0;
    for (o = a >= 7 ? a - 7 : 0; o < a + (uint64_t)w; o++) {
        if (objc_image_rebased(e->im, o)) { if (o == a && w == 8) exact = 1; else return 2; }
        if (objc_image_bound_at(e->im, o) || objc_image_import_at(e->im, o)) return 2;
    }
    return exact;
}

static int cmp_read(const void *a, const void *b) {
    const uint64_t *x = a, *y = b; int i;
    for (i = 0; i < 3; i++) if (x[i] != y[i]) return x[i] < y[i] ? -1 : 1;
    return 0;
}
static void uniq_reads(ObjcRegResult *o) {
    size_t i, j;
    if (!o->n_reads) return;
    qsort(o->const_reads, o->n_reads, sizeof *o->const_reads, cmp_read);
    for (i = 1, j = 1; i < o->n_reads; i++) if (cmp_read(&o->const_reads[i], &o->const_reads[j - 1])) o->const_reads[j++] = o->const_reads[i];
    o->n_reads = j;
}
static int note_read(Ex *e, uint64_t va, uint64_t len, uint64_t site, int how) {
    ObjcRegResult *o = e->out;
    if (o->n_reads && o->const_reads[o->n_reads - 1].va == va && o->const_reads[o->n_reads - 1].site == site) return 0;
    if (o->n_reads == e->capreads && o->n_reads >= 65536) uniq_reads(o);
    if (grow((void **)&o->const_reads, &e->capreads, o->n_reads + 1, sizeof *o->const_reads)) return oom(e);
    o->const_reads[o->n_reads].va = va; o->const_reads[o->n_reads].len = len;
    o->const_reads[o->n_reads].site = site; o->const_reads[o->n_reads].how = how; o->n_reads++;
    return 0;
}

/* ---- path memory ---- */
static Cell *cell_over(St *t, uint64_t a, int w) {
    size_t i = t->nm;
    while (i--) if (t->m[i].a < a + (uint64_t)w && a < t->m[i].a + t->m[i].w) return &t->m[i];
    return NULL;
}
static int cell_put(Ex *e, St *t, uint64_t a, int w, Val v, int ret, int push) {
    size_t i, j = 0;
    for (i = 0; i < t->nm; i++)
        if (!(t->m[i].a >= a && t->m[i].a + t->m[i].w <= a + (uint64_t)w)) t->m[j++] = t->m[i];
    t->nm = j;
    if (grow((void **)&t->m, &t->capm, t->nm + 1, sizeof *t->m)) return oom(e);
    if (v.k == VC && w < 8 && v.rel) { uint32_t ts = v.ts; v = U(); v.ts = ts; }
    if (v.k == VC && w < 8) { v.v &= mask(w); if (v.pw >= w) v.pw = 0; }
    t->m[t->nm].a = a; t->m[t->nm].w = (uint8_t)w; t->m[t->nm].v = v;
    t->m[t->nm].ret = (uint8_t)ret; t->m[t->nm].push = (uint8_t)push; t->nm++;
    return 0;
}
static int writable(const Ex *e, uint64_t a) {
    const char *sn;
    return !is_stack(a) && (sn = objc_image_section_of(e->im, a, NULL, NULL, NULL)) && strncmp(sn, "__TEXT,", 7);
}
static int tracked(const Ex *e, uint64_t a) {
    size_t i;
    for (i = 0; i < e->start->n_tracked; i++) if (e->start->tracked[i] == a) return 1;
    return 0;
}
/* An address provenance follows: writable image data, or a tracked address. */
static int traced(const Ex *e, uint64_t a) { return writable(e, a) || tracked(e, a); }
static uint32_t ts_intern(Ex *e, const Tset *s) {
    size_t i;
    if (!s->n) return 0;
    for (i = 2; i < e->nts; i++) if (e->ts[i].n == s->n && !memcmp(e->ts[i].b, s->b, s->n * sizeof *s->b)) return (uint32_t)i;
    if (e->nts < 2 || grow((void **)&e->ts, &e->capts, e->nts + 1, sizeof *e->ts)) { oom(e); return TS_ALL; }
    e->ts[e->nts] = *s;
    return (uint32_t)e->nts++;
}
static uint32_t ts_one(Ex *e, uint64_t a) { Tset s; memset(&s, 0, sizeof s); s.n = 1; s.b[0] = a; return ts_intern(e, &s); }
static uint32_t ts_union(Ex *e, uint32_t x, uint32_t y) {
    Tset s; const Tset *a, *b; size_t i = 0, j = 0;
    if (!x || x == y) return y;
    if (!y) return x;
    if (x == TS_ALL || y == TS_ALL) return TS_ALL;
    a = &e->ts[x]; b = &e->ts[y]; memset(&s, 0, sizeof s);
    while (i < a->n || j < b->n) {
        uint64_t v = j == b->n || (i < a->n && a->b[i] < b->b[j]) ? a->b[i++] : b->b[j++];
        if (s.n && s.b[s.n - 1] == v) continue;
        if (s.n == TS_CAP) return TS_ALL;
        s.b[s.n++] = v;
    }
    return ts_intern(e, &s);
}
static void taint(St *t, Val v) { if (v.ts) t->tin = ts_union(t->ex, t->tin, v.ts); }
/* In an own-stores run, whether [a, a+w) overlaps the class table, which every call of the root rewrites. */
static int in_table(const Ex *e, uint64_t a, uint64_t w) {
    return e->start->own_stores && a < e->start->table_hi && a + w > e->start->table_lo;
}
/* Whether provenance set ts holds the class table's contents (TABLE_BYTES). */
static int table_set(const Ex *e, uint32_t ts) {
    size_t i;
    if (!ts || ts == TS_ALL) return 0;
    for (i = 0; i < e->ts[ts].n; i++) if (e->ts[ts].b[i] == TABLE_BYTES) return 1;
    return 0;
}
/* v escapes at site on t's path: each base of its provenance and of the path's, and v itself when it points into
 * writable image data or is tracked; an_imp: no tracked base escapes (class_addMethod's IMP argument). */
static int escapes(Ex *e, St *t, Val v, uint64_t site, int how, int an_imp) {
    ObjcRegResult *o = e->out; size_t i, k; uint32_t ts = ts_union(e, v.ts, t->pts); const Tset *s;
    if (v.k == VC && !v.pw && traced(e, v.v)) ts = ts_union(e, ts, ts_one(e, v.v));
    if (!ts) return 0;
    s = &e->ts[ts];
    for (k = 0; k < (ts == TS_ALL ? 1 : s->n); k++) {
        uint64_t va = ts == TS_ALL ? ~0ULL : s->b[k];
        if (ts != TS_ALL && ((an_imp && tracked(e, va)) || va == TABLE_BYTES)) continue;
        for (i = 0; i < o->n_escaped; i++) if (o->escaped[i].va == va && o->escaped[i].site == site && o->escaped[i].how == how) break;
        if (i < o->n_escaped) continue;
        if (grow((void **)&o->escaped, &e->capescaped, o->n_escaped + 1, sizeof *o->escaped)) return oom(e);
        o->escaped[o->n_escaped].va = va; o->escaped[o->n_escaped].site = site; o->escaped[o->n_escaped].how = how; o->n_escaped++;
    }
    return 0;
}
static void escape(St *t, Val v) { if (v.k == VC && !v.pw && !v.rel && is_stack(v.v) && (!t->esc || v.v < t->esc)) t->esc = v.v; }

static int load(Ex *e, St *t, uint64_t site, int known, uint64_t a, int w, Val *out) {
    Cell *c; uint64_t sa, ss, v = 0; uint32_t fl; const char *sn; const uint8_t *p; int rel, ty;
    *out = U();
    if (!known) return 0;
    if (in_table(e, a, (uint64_t)w)) { out->ts = ts_one(e, TABLE_BYTES); taint(t, *out); return 0; }
    if ((c = cell_over(t, a, w))) {
        uint32_t ts = c->v.ts; size_t i;
        if (c->a == a && c->w == w) { *out = c->v; if (out->k == VS && w != 8) *out = U(); }
        else if (c->a <= a && a + (uint64_t)w <= c->a + c->w) {   /* inside the newest cell: its bytes */
            if (c->v.k == VC && !c->v.pw && !c->v.rel) *out = C((c->v.v >> (8 * (a - c->a))) & mask(w));
        } else {   /* across cells: every one's, and on the stack the residue for bytes none covers */
            for (i = 0; i < t->nm; i++) if (t->m[i].a < a + (uint64_t)w && a < t->m[i].a + t->m[i].w) ts = ts_union(e, ts, t->m[i].v.ts);
            if (is_stack(a)) ts = ts_union(e, ts, t->res);
        }
        out->ts = ts; taint(t, *out);
        return 0;
    }
    if (is_stack(a)) { out->ts = t->res; taint(t, *out); return 0; }   /* a dead, red-zone or unwritten slot */
    if (!(sn = objc_image_section_of(e->im, a, &sa, &ss, &fl)) || a + (uint64_t)w > sa + ss) return 0;
    if (w == 8 && import_name(e, a)) {
        uint32_t id = sym_new(e, SY_IMPORT, import_name(e, a));
        if (id == UINT32_MAX) return -1;
        *out = S(id); out->v = 1;
        return 0;
    }
    if ((rel = relocated(e, a, w)) == 2) {   /* part of a pointer dyld rewrites: unknown, carrying what it points to */
        uint64_t o, q;
        for (o = a >= 7 ? a - 7 : 0; o < a + (uint64_t)w; o++)
            if (objc_image_rebased(e->im, o) && (p = objc_image_bytes(e->im, o, 8)) && (memcpy(&q, p, 8), traced(e, q)))
                out->ts = ts_union(e, out->ts, ts_one(e, q));
        taint(t, *out);
        return 0;
    }
    ty = (int)(fl & 0xff);
    if (ty == 0x1 || ty == 0xc) v = 0;
    else if (ty == 0x12 || !(p = objc_image_bytes(e->im, a, (uint64_t)w))) return 0;
    else memcpy(&v, p, (size_t)w);
    if (w == 8 && v && !rel)
        return refuse(e, "unverified-pointer", "the 8 bytes at 0x%llx (%s), read at 0x%llx, are no rebased pointer",
                      (unsigned long long)a, sn, (unsigned long long)site);
    *out = rel == 1 && v ? R(v) : C(v);
    if (rel == 1 && traced(e, v)) { out->ts = ts_one(e, v); taint(t, *out); }
    return note_read(e, a, (uint64_t)w, site, 0);
}
static int store(Ex *e, St *t, uint64_t site, int known, uint64_t a, int w, Val v, int push) {
    uint64_t sa, ss; uint32_t fl; const char *sn; size_t i; ObjcRegResult *o = e->out;
    if (!known) return refuse(e, "unknown-store", "a store through an unknown address at 0x%llx", (unsigned long long)site);
    v.ts = ts_union(e, v.ts, t->tin);
    if (is_stack(a)) {
        t->res = ts_union(e, t->res, v.ts);
        for (i = 0; i < t->nm; i++)
            if (t->m[i].ret && t->m[i].a < a + (uint64_t)w && a < t->m[i].a + 8)
                return refuse(e, "unknown-store", "a store over a return address at 0x%llx", (unsigned long long)site);
        if (!push && w == 8) escape(t, v);
        return cell_put(e, t, a, w, v, 0, push);
    }
    if (!(sn = objc_image_section_of(e->im, a, &sa, &ss, &fl)) || a + (uint64_t)w > sa + ss)
        return refuse(e, "unknown-store", "a store to 0x%llx, outside the stack and the image, at 0x%llx",
                      (unsigned long long)a, (unsigned long long)site);
    if (!strncmp(sn, "__TEXT,", 7) || relocated(e, a, w))
        return refuse(e, "image-store", "a store to 0x%llx (%s%s) at 0x%llx", (unsigned long long)a, sn,
                      strncmp(sn, "__TEXT,", 7) ? ", a pointer slot dyld rewrites" : "", (unsigned long long)site);
    if (e->start->own_stores && !(w == 8 && a >= e->start->table_lo && a + 8 <= e->start->table_hi && e->start->arg0_class &&
                                  v.k == VS && e->sym[v.sym].kind == SY_CLASS && e->sym[v.sym].name &&
                                  !strcmp(e->sym[v.sym].name, e->start->arg0_class)))
        return refuse(e, "image-store", "a store to 0x%llx (%s), not the root's class into its class table, at 0x%llx",
                      (unsigned long long)a, sn, (unsigned long long)site);
    if (escapes(e, t, v, site, OBJC_ESC_STORE, 0)) return -1;
    if (w == 8) escape(t, v);
    if (grow((void **)&o->image_stores, &e->capstores, o->n_stores + 1, sizeof *o->image_stores)) return oom(e);
    o->image_stores[o->n_stores].va = a; o->image_stores[o->n_stores].len = (uint64_t)w; o->image_stores[o->n_stores].site = site;
    o->n_stores++;
    return cell_put(e, t, a, w, v, 0, 0);
}

/* A C string at a concrete image address no path store covers, as the runtime would read it; NULL otherwise. */
static const char *literal(Ex *e, St *t, Val v, uint64_t site, char *buf, size_t n) {
    uint64_t sa, ss; uint32_t fl; const uint8_t *p; size_t i, max;
    if (v.k != VC || v.pw || !v.rel || !objc_image_section_of(e->im, v.v, &sa, &ss, &fl) || (fl & 0xff) == 0x1 || (fl & 0xff) == 0xc) return NULL;
    max = sa + ss - v.v < n ? (size_t)(sa + ss - v.v) : n;
    if (!(p = objc_image_bytes(e->im, v.v, max))) return NULL;
    for (i = 0; i < max && p[i]; i++) {}
    if (i == max || cell_over(t, v.v, (int)(i + 1)) || relocated(e, v.v, (int)(i + 1)) || in_table(e, v.v, i + 1)) return NULL;
    memcpy(buf, p, i + 1);
    return note_read(e, v.v, i + 1, site, 1) ? NULL : buf;
}

/* ---- registers and flags ---- */
static Val reg_get(St *t, int r, int w) {
    Val v = t->r[r], u = U();
    taint(t, v); u.ts = v.ts;
    if (v.k == VC) { if ((v.pw && w > v.pw) || (v.rel && w < 8)) return u; v.v &= mask(w); if (v.pw >= w) v.pw = 0; return v; }
    return v.k == VS && w == 8 ? v : u;
}
/* r = v (w bytes), its provenance the instruction's reads (t->tin), v's own, and for a 1- or 2-byte write the bytes kept. */
static void reg_set(St *t, int r, Val v, int w) {
    Val o = t->r[r]; uint32_t ts = ts_union(t->ex, t->tin, v.ts);
    if (w < 4) ts = ts_union(t->ex, ts, o.ts);
    if (w == 8) t->r[r] = v;
    else if (w == 4) { if (v.k == VC && !v.rel) { v.v &= 0xffffffffULL; v.pw = v.pw && v.pw < 4 ? v.pw : 0; t->r[r] = v; } else t->r[r] = U(); }
    else if (v.k != VC || v.rel || (v.pw && v.pw < w)) t->r[r] = U();
    else if (o.k == VC && !o.rel) { o.v = (o.v & ~mask(w)) | (v.v & mask(w)); if (o.pw && o.pw < w) o.pw = (uint8_t)w; t->r[r] = o; }
    else t->r[r] = Cp(v.v, w);
    t->r[r].ts = ts;
}
static void flags(St *t, int op, Val a, Val b, Val r, int w) {
    t->fop = op; t->fw = w; t->fa = a; t->fb = b; t->fr = r;
    t->fts = ts_union(t->ex, ts_union(t->ex, t->tin, a.ts), b.ts);
}
/* Flags no model decides, set from what this instruction read (and, for adc and sbb, the carry it consumed). */
static void flags_unknown(St *t) { t->fop = 0; t->fts = ts_union(t->ex, t->fts, t->tin); }
static int t_or(int a, int b) { return a == 1 || b == 1 ? 1 : a == 0 && b == 0 ? 0 : -1; }
static int t_not(int a) { return a < 0 ? -1 : !a; }
static int t_ne(int a, int b) { return a < 0 || b < 0 ? -1 : a != b; }
/* A value no slide makes NULL: a non-NULL symbol, or an image address inside the image. */
static int nz(const St *t, Val a) {
    return nonzero(a) || (a.k == VC && a.rel && !a.pw && objc_image_section_of(t->ex->im, a.v, NULL, NULL, NULL));
}
/* Condition cc: 1, 0, or -1 when the flags do not decide it. An image address compared with another decides them; with
 * NULL, only that it is not; with anything else, nothing. */
static void flagbits(const St *t, int *zfp, int *sfp, int *cfp, int *ofp) {
    int zf = -1, sf = -1, cf = -1, of = -1;
    Val a = t->fa, b = t->fb;
    *zfp = *sfp = *cfp = *ofp = -1;
    if (!t->fop) return;
    if (a.k == VC && b.k == VC && t->fr.k == VC && !a.pw && !b.pw && (a.rel == b.rel ? !a.rel || t->fop == 2 : 0)) {
        uint64_t m = mask(t->fw), x = a.v & m, y = b.v & m, z = t->fr.v & m, sb = 1ULL << (t->fw * 8 - 1);
        zf = z == 0; sf = (z & sb) != 0;
        if (t->fop == 1) { cf = z < x; of = (~(x ^ y) & (x ^ z) & sb) != 0; }
        else if (t->fop == 2) { cf = x < y; of = ((x ^ y) & (x ^ z) & sb) != 0; }
        else if (t->fop == 3) cf = of = 0;
        else of = t->fop == 4 ? z == sb : z == sb - 1;
    } else if (t->fw == 8 && t->fop == 2 && a.k == VS && same(a, b)) { zf = 1; cf = of = sf = 0; }
    else if (t->fw == 8 && t->fop == 3 && nz(t, a) && same(a, b)) { zf = 0; cf = of = 0; }
    else if (t->fw == 8 && t->fop == 2 && nz(t, a) && is0(b)) { zf = 0; cf = of = 0; }
    else if (t->fw == 8 && t->fop == 2 && nonzero(a) && b.k == VC && !b.pw && !b.rel && b.v == 1) cf = 0;
    else if (t->fw == 8 && t->fop == 2 && nz(t, b) && is0(a)) { zf = 0; cf = 1; }
    *zfp = zf; *sfp = sf; *cfp = cf; *ofp = of;
}
static int cond(const St *t, int cc) {
    int zf, sf, cf, of, r = -1;
    flagbits(t, &zf, &sf, &cf, &of);
    switch (cc) {
    case 0: r = of; break; case 1: r = t_not(of); break; case 2: r = cf; break; case 3: r = t_not(cf); break;
    case 4: r = zf; break; case 5: r = t_not(zf); break; case 6: r = t_or(cf, zf); break;
    case 7: r = t_not(t_or(cf, zf)); break; case 8: r = sf; break; case 9: r = t_not(sf); break;
    case 12: r = t_ne(sf, of); break; case 13: r = t_not(t_ne(sf, of)); break;
    case 14: r = t_or(zf, t_ne(sf, of)); break; case 15: r = t_not(t_or(zf, t_ne(sf, of))); break;
    }
    return r;
}
static Val alu(St *t, int op, Val a, Val b, int w) {   /* op: 0 add 1 or 4 and 5 sub 6 xor 7 cmp */
    Val r = U();
    if (a.k == VC && b.k == VC && !a.pw && !b.pw && !a.rel && !b.rel) {
        uint64_t x = a.v, y = b.v, z = 0;
        switch (op) { case 0: z = x + y; break; case 1: z = x | y; break; case 4: z = x & y; break;
                      case 5: case 7: z = x - y; break; case 6: z = x ^ y; break; }
        r = C(z & mask(w));
    } else if (a.k == VC && b.k == VC && !a.pw && !b.pw && w == 8) {   /* an image address: only what no slide changes */
        if (op == 0 && a.rel != b.rel) r = R(a.v + b.v);
        else if ((op == 5 || op == 7) && a.rel && !b.rel) r = R(a.v - b.v);
        else if ((op == 5 || op == 7) && a.rel && b.rel) r = C(a.v - b.v);
    }
    if (op == 6 && same(a, b)) { r = C(0); a = b = r; }   /* a value xor itself, a symbol's too */
    flags(t, op == 0 ? 1 : (op == 5 || op == 7) ? 2 : 3, a, b, r, w);
    return r;
}

/* adc (sbb: sub) of a and b with the carry flag, carrying the flags' provenance; unknown when the carry is. The flags
 * after it are not modelled. */
static Val carry(St *t, int sub, Val a, Val b, int w) {
    int zf, sf, cf, of;
    flagbits(t, &zf, &sf, &cf, &of);
    t->tin = ts_union(t->ex, t->tin, t->fts);
    flags_unknown(t);
    if (cf < 0 || a.k != VC || b.k != VC || a.pw || b.pw || a.rel || b.rel) return U();
    return C((sub ? a.v - b.v - (uint64_t)cf : a.v + b.v + (uint64_t)cf) & mask(w));
}

/* ---- paths ---- */
static void st_free(St *t) { if (t) { free(t->m); free(t->found); free(t->adds); free(t->nulls); free(t); } }
static St *fork_st(Ex *e, St *t) {
    St *u;
    if (++e->npaths > e->b.max_paths) { refuse(e, "path-budget", "more than %zu paths, forking at 0x%llx", e->b.max_paths, (unsigned long long)t->rip); return NULL; }
    if (!(u = malloc(sizeof *u))) { oom(e); return NULL; }
    *u = *t; u->m = NULL; u->found = NULL; u->adds = NULL; u->nulls = NULL;
    if ((t->nm && !(u->m = malloc(t->capm * sizeof *u->m))) || (t->nfound && !(u->found = malloc(t->capf * sizeof *u->found))) ||
        (t->nnull && !(u->nulls = malloc(t->capnull * sizeof *u->nulls))) ||
        (t->nadds && !(u->adds = malloc(t->capa * sizeof *u->adds))) ||
        grow((void **)&e->work, &e->capwork, e->nwork + 1, sizeof *e->work)) { st_free(u); oom(e); return NULL; }
    if (t->nm) memcpy(u->m, t->m, t->nm * sizeof *u->m); else u->capm = 0;
    if (t->nfound) memcpy(u->found, t->found, t->nfound * sizeof *u->found); else u->capf = 0;
    if (t->nadds) memcpy(u->adds, t->adds, t->nadds * sizeof *u->adds); else u->capa = 0;
    if (t->nnull) memcpy(u->nulls, t->nulls, t->nnull * sizeof *u->nulls); else u->capnull = 0;
    e->work[e->nwork++] = u;
    return u;
}
/* The failed twin of the add rax still holds: forked now, as the add's result is about to be read. */
static int owe_fork(Ex *e, St *t) {
    size_t k = t->addfork; St *u;
    t->addfork = 0;
    if (!k) return 0;
    if (!(u = fork_st(e, t))) return -1;
    u->adds[k - 1].ok = 0; u->r[0] = Cp(0, 1);
    return 0;
}
static char *dup0(const char *s) { return s ? strdup(s) : NULL; }
static int complete(Ex *e, St *t) {
    ObjcRegResult *o = e->out; ObjcRegPath *p; size_t i;
    if (grow((void **)&o->paths, &e->cappaths, o->n_paths + 1, sizeof *o->paths)) return oom(e);
    p = &o->paths[o->n_paths++]; memset(p, 0, sizeof *p);
    p->class_null = t->class_null; p->trapped = t->trapped; p->unknown_forks = t->uforks; p->table_forks = t->tforks;
    if ((t->nfound && !(p->found = calloc(t->nfound, sizeof *p->found))) || (t->nadds && !(p->adds = calloc(t->nadds, sizeof *p->adds))) ||
        (t->nnull && !(p->null_classes = calloc(t->nnull, sizeof *p->null_classes)))) return oom(e);
    for (i = 0; i < t->nnull; i++) p->null_classes[i] = dup0(t->nulls[i]);
    p->n_null_classes = t->nnull;
    for (i = 0; i < t->nfound; i++) {
        p->found[i].cls = dup0(t->found[i].cls); p->found[i].meta = t->found[i].meta; p->found[i].sel = dup0(t->found[i].sel);
    }
    p->n_found = t->nfound;
    for (i = 0; i < t->nadds; i++) {
        const Add *a = &t->adds[i]; ObjcRegAdd *d = &p->adds[i];
        d->cls = dup0(a->cls); d->meta = a->meta; d->sel = dup0(a->sel); d->imp = dup0(a->imp); d->types = dup0(a->types);
        d->imp_va = a->imp_va; d->site = a->site; d->ok = a->ok;
    }
    p->n_adds = t->nadds;
    return 0;
}

/* ---- calls ---- */
static void clobber(St *t) {
    static const int cs[] = { 0, 1, 2, 6, 7, 8, 9, 10, 11 }; size_t i;
    for (i = 0; i < sizeof cs / sizeof *cs; i++) t->r[cs[i]] = U();
    t->fop = 0; t->fts = 0;
}
static void unknown_call(St *t) {
    static const int args[] = { 7, 6, 2, 1, 8, 9 }; size_t i; uint64_t sp = t->r[4].v, top = 0;
    for (i = 0; i < 6; i++) escape(t, t->r[args[i]]);
    if (t->r[4].k == VC && !t->r[4].pw) {   /* the stack arguments: every cell from rsp up to the return address above it */
        for (i = 0; i < t->nm; i++) if (t->m[i].ret && t->m[i].a > sp && (!top || t->m[i].a < top)) top = t->m[i].a;
        for (i = 0; i < t->nm; i++) if (is_stack(t->m[i].a) && t->m[i].a >= sp && (!top || t->m[i].a < top)) escape(t, t->m[i].v);
    }
    for (i = 0; i < t->nm; i++) {
        Cell *c = &t->m[i];
        if (is_stack(c->a) ? !c->ret && !c->push && t->esc && c->a + c->w > t->esc : 1) c->v = U();
    }
    clobber(t);
}
static void cls_of(const Ex *e, Val v, const char **name, int *meta) {
    *name = NULL; *meta = 0;
    if (v.k != VS) return;
    if (e->sym[v.sym].kind == SY_CLASS) *name = e->sym[v.sym].name;
    else if (e->sym[v.sym].kind == SY_META) { *name = e->sym[v.sym].name; *meta = 1; }
}
static const char *sel_of(const Ex *e, Val v) { return v.k == VS && e->sym[v.sym].kind == SY_SEL ? e->sym[v.sym].name : NULL; }
static int add_look(Ex *e, St *t, const char *cls, int meta, const char *sel) {
    if (grow((void **)&t->found, &t->capf, t->nfound + 1, sizeof *t->found)) return oom(e);
    t->found[t->nfound].cls = cls; t->found[t->nfound].meta = meta; t->found[t->nfound].sel = sel; t->nfound++;
    return 0;
}
static int note_site(Ex *e, uint64_t site) {
    ObjcRegResult *o = e->out; size_t i;
    for (i = 0; i < o->n_sites; i++) if (o->mutator_sites[i] == site) return 0;
    if (grow((void **)&o->mutator_sites, &e->capsites, o->n_sites + 1, sizeof *o->mutator_sites)) return oom(e);
    o->mutator_sites[o->n_sites++] = site;
    return 0;
}
static int note_selreg(Ex *e, uint64_t site, int lit) {
    ObjcRegResult *o = e->out; size_t i;
    for (i = 0; i < o->n_selreg; i++) if (o->selreg[i].site == site) { o->selreg[i].all_literal &= lit; return 0; }
    if (grow((void **)&o->selreg, &e->capselreg, o->n_selreg + 1, sizeof *o->selreg)) return oom(e);
    o->selreg[o->n_selreg].site = site; o->selreg[o->n_selreg].all_literal = lit; o->n_selreg++;
    return 0;
}
static int note_called(Ex *e, uint64_t target) {
    ObjcRegResult *o = e->out; size_t i;
    for (i = 0; i < o->n_called; i++) if (o->called[i] == target) return 0;
    if (grow((void **)&o->called, &e->capcalled, o->n_called + 1, sizeof *o->called)) return oom(e);
    o->called[o->n_called++] = target;
    return 0;
}
static uint32_t opaque(Ex *e) { return sym_new(e, SY_OPAQUE, NULL); }

/* A call at site to code not followed: a tainted value among a modelled import's nargs declared arguments, or
 * (nargs < 0) in any register or frame cell, escapes; register imp (or -1) is an add's IMP argument. */
static int call_taint(Ex *e, St *t, int nargs, uint64_t site, int imp) {
    static const int args[] = { 7, 6, 2, 1, 8, 9 };
    int i; size_t k;
    for (i = 0; i < (nargs < 0 ? 16 : nargs); i++) {
        int r = nargs < 0 ? i : args[i];
        if (escapes(e, t, t->r[r], site, OBJC_ESC_CALL, r == imp)) return -1;
    }
    if (nargs >= 0) return 0;
    for (k = 0; k < t->nm; k++)
        if (is_stack(t->m[k].a) && !t->m[k].ret && escapes(e, t, t->m[k].v, site, OBJC_ESC_CALL, 0)) return -1;
    return 0;
}
/* A modelled import's declared argument count; -1 for any other import. */
static int import_arity(const char *n) {
    if (!strcmp(n, "objc_getClass") || !strcmp(n, "object_getClass") || !strcmp(n, "sel_registerName")) return 1;
    if (!strcmp(n, "class_getInstanceMethod") || !strcmp(n, "class_getClassMethod") || !strcmp(n, "class_respondsToSelector") ||
        !strcmp(n, "class_getMethodImplementation")) return 2;
    if (!strcmp(n, "class_addMethod")) return 4;
    return -1;
}
/* The import n's model at the call or jump at site; rax and the flags as it leaves them. */
static int call_import(Ex *e, St *t, const char *n, uint64_t site) {
    Val rdi = t->r[7], rsi = t->r[6], rdx = t->r[2], rcx = t->r[1], ret = U();
    char b1[256], b2[256]; const char *s1, *cn; int meta; uint32_t id; St *u;
    if (call_taint(e, t, import_arity(n), site, strcmp(n, "class_addMethod") ? -1 : 2)) return -1;
    if (listed(MUTATORS, n) && note_site(e, site)) return -1;
    if (!strcmp(n, "objc_getClass")) {
        s1 = literal(e, t, rdi, site, b1, sizeof b1);
        if (e->out->refused || (id = sym_new(e, SY_CLASS, s1)) == UINT32_MAX) return -1;
        clobber(t); t->r[0] = S(id);
        if (!(u = fork_st(e, t))) return -1;
        u->r[0] = C(0); u->class_null = 1;
        if (grow((void **)&u->nulls, &u->capnull, u->nnull + 1, sizeof *u->nulls)) return oom(e);
        u->nulls[u->nnull++] = s1 ? e->sym[id].name : NULL;
        return 0;
    }
    if (!strcmp(n, "object_getClass")) {
        cls_of(e, rdi, &cn, &meta);
        if (is0(rdi)) ret = C(0);
        else if (rdi.k == VS && e->sym[rdi.sym].kind == SY_CLASS) {
            if ((id = sym_new(e, SY_META, cn)) == UINT32_MAX) return -1;
            ret = S(id);
        }
        clobber(t); t->r[0] = ret;
        return 0;
    }
    if (!strcmp(n, "sel_registerName")) {
        s1 = literal(e, t, rdi, site, b1, sizeof b1);
        if (e->out->refused || note_selreg(e, site, s1 != NULL) || (id = sym_new(e, SY_SEL, s1)) == UINT32_MAX) return -1;
        clobber(t); t->r[0] = S(id);
        return 0;
    }
    if (!strcmp(n, "class_getInstanceMethod") || !strcmp(n, "class_getClassMethod") ||
        !strcmp(n, "class_respondsToSelector") || !strcmp(n, "class_getMethodImplementation")) {
        int bool_ = !strcmp(n, "class_respondsToSelector"), imp = !strcmp(n, "class_getMethodImplementation");
        cls_of(e, rdi, &cn, &meta);
        if (!strcmp(n, "class_getClassMethod")) { if (meta) cn = NULL; meta = 1; }
        clobber(t);
        if (is0(rdi)) { t->r[0] = bool_ ? Cp(0, 1) : C(0); return 0; }
        if (imp) { if ((id = opaque(e)) == UINT32_MAX) return -1; t->r[0] = S(id); }
        else t->r[0] = bool_ ? Cp(0, 1) : C(0);
        if (!(u = fork_st(e, t))) return -1;
        if (bool_) u->r[0] = Cp(1, 1);
        else { if ((id = opaque(e)) == UINT32_MAX) return -1; u->r[0] = S(id); }
        return add_look(e, u, cn, meta, sel_of(e, rsi));
    }
    if (!strcmp(n, "class_addMethod")) {
        Add a; const char *im;
        memset(&a, 0, sizeof a);
        cls_of(e, rdi, &a.cls, &a.meta);
        a.sel = sel_of(e, rsi);
        im = rdx.k == VC && !rdx.pw && rdx.rel ? objc_image_symbol_at(e->im, rdx.v) : NULL;
        a.imp = im; a.imp_va = rdx.k == VC && !rdx.pw && rdx.rel ? rdx.v : 0;
        if ((s1 = literal(e, t, rcx, site, b2, sizeof b2))) {
            if ((id = sym_new(e, SY_OPAQUE, s1)) == UINT32_MAX) return -1;
            a.types = e->sym[id].name;
        }
        if (e->out->refused) return -1;
        a.site = site; a.ok = !is0(rdi);
        if (grow((void **)&t->adds, &t->capa, t->nadds + 1, sizeof *t->adds)) return oom(e);
        t->adds[t->nadds++] = a;
        clobber(t); t->r[0] = Cp(a.ok, 1);
        t->addfork = a.ok ? t->nadds : 0;
        return 0;
    }
    unknown_call(t);
    return 0;
}

static int do_ret(Ex *e, St *t, uint64_t site) {
    Cell *c; uint64_t sp = t->r[4].v; size_t i, j = 0;
    if (t->r[4].k != VC || t->r[4].pw || !(c = cell_over(t, sp, 8)) || !c->ret || c->a != sp || c->v.k != VC)
        return refuse(e, "indirect-call", "a return at 0x%llx to an address no followed call pushed", (unsigned long long)site);
    if ((c->v.v == SENTINEL || t->depth == 1) && escapes(e, t, t->r[0], site, OBJC_ESC_RETURN, 0)) return -1;
    if (c->v.v == SENTINEL) return 1;
    t->rip = c->v.v; t->r[4] = C(sp + 8); t->depth--;
    for (i = 0; i < t->nm; i++) if (t->m[i].a >= sp + 8) t->m[j++] = t->m[i];
    t->nm = j;
    return 0;
}
/* An import reached by a tail jump at site: its model, then a return, on every path it forks. */
static int tail_import(Ex *e, St *t, const char *n, uint64_t site) {
    size_t w = e->nwork, i;
    if (call_import(e, t, n, site) || owe_fork(e, t)) return -1;
    for (i = w; i < e->nwork; i++) e->work[i]->tailret = site;
    return do_ret(e, t, site);
}
/* A call (tail: a jump) at site to target; next is the return address. */
static int do_call(Ex *e, St *t, uint64_t site, uint64_t target, int tail, uint64_t next) {
    const char *n = import_name(e, target);
    if (n) return tail ? tail_import(e, t, n, site) : call_import(e, t, n, site);
    if (!in_ranges(e, target))
        return refuse(e, "foreign-call", "a call at 0x%llx to 0x%llx, outside the provider's code and no import",
                      (unsigned long long)site, (unsigned long long)target);
    if (note_called(e, target)) return -1;
    if (!follow(e, target)) {
        if (call_taint(e, t, -1, site, -1)) return -1;
        unknown_call(t); return tail ? do_ret(e, t, site) : 0;
    }
    if (!tail) {
        if (t->depth + 1 > e->b.max_depth)
            return refuse(e, "depth-budget", "a call at 0x%llx deeper than %zu followed calls", (unsigned long long)site, e->b.max_depth);
        if (t->r[4].k != VC || t->r[4].pw) return refuse(e, "unknown-store", "a call at 0x%llx with rsp unknown", (unsigned long long)site);
        t->r[4].v -= 8;
        if (store(e, t, site, 1, t->r[4].v, 8, C(next), 1)) return -1;
        t->m[t->nm - 1].ret = 1; t->m[t->nm - 1].push = 0;
        t->depth++;
    }
    t->rip = target;
    return 0;
}

/* ---- instructions ---- */
static int width(const ObjcIns *x, int bytewide) { return bytewide ? 1 : (x->rex & 8) ? 8 : x->p66 ? 2 : 4; }
/* The operand's address, and in *rel whether it is an image address; 0 when unknown, as when it adds two image
 * addresses or scales one. */
static int ea_rel(const St *t, const ObjcIns *x, uint64_t *a, int *rel) {
    uint64_t v = 0; const Val *b = NULL, *i = NULL;
    *rel = 0;
    if (x->riprel) { *a = x->riptarget; *rel = 1; return 1; }
    if (x->sib) { if (x->sibbase >= 0) b = &t->r[x->sibbase]; if (x->sibindex >= 0) i = &t->r[x->sibindex]; }
    else b = &t->r[x->rm];
    if (b) { if (b->k != VC || b->pw) return 0; v = b->v; *rel += b->rel; }
    if (i) { if (i->k != VC || i->pw || (i->rel && x->sibscale)) return 0; v += i->v << x->sibscale; *rel += i->rel; }
    *a = v + (uint64_t)x->mdisp;
    return *rel <= 1;
}
/* A memory operand's address: known when it is an image address or on the stack. */
static int ea(const St *t, const ObjcIns *x, uint64_t *a) {
    int rel;
    return ea_rel(t, x, a, &rel) && (rel || is_stack(*a));
}
/* A load from an unknown address: unknown, its provenance the frame residue and the address registers'; through an
 * import's address plus a constant (a field of another image's object, never the stack), the address register's only. */
static Val unknown_load(St *t, const ObjcIns *x) {
    Val u = U(); int b = x->riprel ? -1 : x->sib ? (x->sibindex < 0 ? x->sibbase : -1) : x->rm;
    u.ts = b >= 0 && t->r[b].k == VS && t->r[b].v == 1 && t->ex->sym[t->r[b].sym].kind == SY_IMPORT ? 0 : t->res;
    if (x->sib) {
        if (x->sibbase >= 0) u.ts = ts_union(t->ex, u.ts, t->r[x->sibbase].ts);
        if (x->sibindex >= 0) u.ts = ts_union(t->ex, u.ts, t->r[x->sibindex].ts);
    } else if (!x->riprel) u.ts = ts_union(t->ex, u.ts, t->r[x->rm].ts);
    taint(t, u);
    return u;
}
static int rm_get(Ex *e, St *t, const ObjcIns *x, int w, uint64_t site, Val *v) {
    uint64_t a = 0;
    if (x->mod == 3) { *v = reg_get(t, x->rm, w); return 0; }
    if (!ea(t, x, &a)) { *v = unknown_load(t, x); return 0; }
    return load(e, t, site, 1, a, w, v);
}
static int rm_set(Ex *e, St *t, const ObjcIns *x, Val v, int w, uint64_t site) {
    uint64_t a = 0; int k;
    if (x->mod == 3) { reg_set(t, x->rm, v, w); return 0; }
    k = ea(t, x, &a);
    return store(e, t, site, k, a, w, v, 0);
}
static int push(Ex *e, St *t, uint64_t site, Val v) {
    if (t->r[4].k != VC || t->r[4].pw) return refuse(e, "unknown-store", "a push at 0x%llx with rsp unknown", (unsigned long long)site);
    t->r[4].v -= 8;
    return store(e, t, site, 1, t->r[4].v, 8, v, 1);
}
static int pop(Ex *e, St *t, uint64_t site, Val *v) {
    if (t->r[4].k != VC || t->r[4].pw) return refuse(e, "unknown-store", "a pop at 0x%llx with rsp unknown", (unsigned long long)site);
    if (load(e, t, site, 1, t->r[4].v, 8, v)) return -1;
    t->r[4].v += 8;
    return 0;
}
static int unsupported(Ex *e, uint64_t ip, const ObjcIns *x, const uint8_t *p, const char *what) {
    char hex[64]; int i, n = 0;
    for (i = 0; i < x->len && n < (int)sizeof hex - 3; i++) n += snprintf(hex + n, sizeof hex - (size_t)n, "%02x", p[i]);
    return refuse(e, "unsupported-instruction", "%s at 0x%llx (map %d opcode 0x%02x, bytes %s)", what,
                  (unsigned long long)ip, x->map, x->op & 0xff, hex);
}
/* A fork on t's unknown flags: a guess, unless they derive from the class table, whose contents differ per call. */
static void guessed(const Ex *e, St *t) { if (table_set(e, t->fts)) t->tforks++; else t->uforks++; }
/* A conditional transfer whose flags do not decide it: the other way on a forked path. */
static int branch(Ex *e, St *t, int c, uint64_t taken) {
    St *u;
    if (c >= 0) { if (c) t->rip = taken; return 0; }
    t->pts = ts_union(e, t->pts, t->fts);
    if (!(u = fork_st(e, t))) return -1;
    u->rip = taken; guessed(e, u); guessed(e, t);
    return 0;
}

/* 1 when a jump at ip to tg leaves its function: a tail call. */
static int tail_target(const Ex *e, uint64_t ip, uint64_t tg) {
    size_t here = fn_at(e, ip);
    return import_name(e, tg) || !in_ranges(e, tg) || (is_fn_start(e, tg) && (here == e->nfn || objc_image_function(e->im, here) != tg));
}
static int execute(Ex *e, St *t) {
    uint64_t ip = t->rip, a = 0; size_t av; const uint8_t *p; ObjcIns x0, x; int w, op, i, r;
    Val v, l, z;
    if (!in_ranges(e, ip)) return refuse(e, "foreign-call", "execution reached 0x%llx, outside the provider's code", (unsigned long long)ip);
    if (!(p = code_at(e, ip, &av)) || objc_x86_decode(p, av, ip, &x0))
        return refuse(e, "unsupported-instruction", "undecodable bytes at 0x%llx", (unsigned long long)ip);
    x = objc_x86_byte_regs(&x0); op = x.op; t->rip = x.next; t->tin = 0;
    if (x.rm != x0.rm || x.reg != x0.reg) return unsupported(e, ip, &x, p, "a high byte register (ah, ch, dh, bh)");
    for (i = 0; i < x.len && (p[i] == 0x66 || p[i] == 0xF2 || p[i] == 0xF3 || p[i] == 0x2E || p[i] == 0x3E || p[i] == 0x26 ||
                              p[i] == 0x36 || p[i] == 0x64 || p[i] == 0x65 || p[i] == 0x67 || p[i] == 0xF0); i++)
        if (p[i] == 0x64 || p[i] == 0x65 || p[i] == 0x67 || p[i] == 0xF0 || ((p[i] == 0xF2 || p[i] == 0xF3) && x.map == 0))
            return unsupported(e, ip, &x, p, "a segment, address-size, lock or rep prefix");
    if (x.map == 0) {
        if (op >= 0x50 && op <= 0x57) return x.p66 ? unsupported(e, ip, &x, p, "a 16-bit push") : push(e, t, ip, t->r[(op & 7) | (x.rex & 1 ? 8 : 0)]);
        if (op >= 0x58 && op <= 0x5F) {
            if (x.p66) return unsupported(e, ip, &x, p, "a 16-bit pop");
            if (pop(e, t, ip, &v)) return -1;
            t->r[(op & 7) | (x.rex & 1 ? 8 : 0)] = v;
            return 0;
        }
        if (op == 0x68 || op == 0x6A) return push(e, t, ip, C((uint64_t)x.imm));
        if (op == 0x88 || op == 0x89) { w = width(&x, op == 0x88); return rm_set(e, t, &x, reg_get(t, x.reg, w), w, ip); }
        if (op == 0x8A || op == 0x8B) { w = width(&x, op == 0x8A); if (rm_get(e, t, &x, w, ip, &v)) return -1; reg_set(t, x.reg, v, w); return 0; }
        if ((op == 0xC6 || op == 0xC7) && (x.reg & 7) == 0) { w = width(&x, op == 0xC6); return rm_set(e, t, &x, C((uint64_t)x.imm & mask(w)), w, ip); }
        if (op >= 0xB0 && op <= 0xB7) {
            if (!x.rex && (op & 7) >= 4) return unsupported(e, ip, &x, p, "a high byte register (ah, ch, dh, bh)");
            reg_set(t, (op & 7) | (x.rex & 1 ? 8 : 0), C((uint64_t)x.imm), 1); return 0;
        }
        if (op >= 0xB8 && op <= 0xBF) { w = width(&x, 0); reg_set(t, (op & 7) | (x.rex & 1 ? 8 : 0), C((uint64_t)x.imm & mask(w)), w); return 0; }
        if (op == 0x8D && x.mod != 3) {
            int rel, k = ea_rel(t, &x, &a, &rel);
            w = width(&x, 0);
            if (x.sib) { if (x.sibbase >= 0) taint(t, t->r[x.sibbase]); if (x.sibindex >= 0) taint(t, t->r[x.sibindex]); }
            else if (!x.riprel) taint(t, t->r[x.rm]);
            if (k && traced(e, a)) t->tin = ts_union(e, t->tin, ts_one(e, a));
            reg_set(t, x.reg, !k || (rel && w < 8) ? U() : rel ? R(a) : C(a & mask(w)), w); return 0;
        }
        if (op == 0x63 && (x.rex & 8)) {
            if (rm_get(e, t, &x, 4, ip, &v)) return -1;
            reg_set(t, x.reg, v.k == VC && !v.pw ? C((uint64_t)(int64_t)(int32_t)v.v) : U(), 8); return 0;
        }
        if (op >= 0x10 && op <= 0x1D && (op & 7) <= 5) {   /* adc, sbb */
            w = width(&x, !(op & 1));
            if ((op & 7) >= 4) { l = reg_get(t, 0, w); v = C((uint64_t)x.imm & mask(w)); }
            else if (op & 2) { l = reg_get(t, x.reg, w); if (rm_get(e, t, &x, w, ip, &v)) return -1; }
            else { if (rm_get(e, t, &x, w, ip, &l)) return -1; v = reg_get(t, x.reg, w); }
            z = carry(t, op >= 0x18, l, v, w);
            if ((op & 7) >= 4) { reg_set(t, 0, z, w); return 0; }
            if (op & 2) { reg_set(t, x.reg, z, w); return 0; }
            return rm_set(e, t, &x, z, w, ip);
        }
        if (op <= 0x3D && (op & 7) <= 5 && op != 0x0F && ((op >> 3) & 7) != 2 && ((op >> 3) & 7) != 3) {
            int k = (op >> 3) & 7, dir = op & 2;
            if ((op & 7) >= 4) {   /* al/ax/eax/rax, imm */
                w = width(&x, !(op & 1)); z = alu(t, k, reg_get(t, 0, w), C((uint64_t)x.imm & mask(w)), w);
                if (k != 7) reg_set(t, 0, z, w);
                return 0;
            }
            w = width(&x, !(op & 1));
            if (dir) { l = reg_get(t, x.reg, w); if (rm_get(e, t, &x, w, ip, &v)) return -1; }
            else { if (rm_get(e, t, &x, w, ip, &l)) return -1; v = reg_get(t, x.reg, w); }
            z = alu(t, k, l, v, w);
            if ((k == 6 || k == 5) && x.mod == 3 && x.reg == x.rm) { z = C(0); t->tin = 0; flags(t, 3, z, z, z, w); }
            if (k == 7) return 0;
            if (dir) { reg_set(t, x.reg, z, w); return 0; }
            return rm_set(e, t, &x, z, w, ip);
        }
        if (op == 0x80 || op == 0x81 || op == 0x83) {
            w = width(&x, op == 0x80);
            if (rm_get(e, t, &x, w, ip, &l)) return -1;
            if ((x.reg & 7) == 2 || (x.reg & 7) == 3) return rm_set(e, t, &x, carry(t, (x.reg & 7) == 3, l, C((uint64_t)x.imm & mask(w)), w), w, ip);
            z = alu(t, x.reg & 7, l, C((uint64_t)x.imm & mask(w)), w);
            return (x.reg & 7) == 7 ? 0 : rm_set(e, t, &x, z, w, ip);
        }
        if (op == 0x84 || op == 0x85) { w = width(&x, op == 0x84); if (rm_get(e, t, &x, w, ip, &l)) return -1; alu(t, 4, l, reg_get(t, x.reg, w), w); return 0; }
        if (op == 0xA8 || op == 0xA9) { w = width(&x, op == 0xA8); alu(t, 4, reg_get(t, 0, w), C((uint64_t)x.imm & mask(w)), w); return 0; }
        if ((op == 0xF6 || op == 0xF7) && (x.reg & 7) <= 3 && (x.reg & 7) != 1) {
            w = width(&x, op == 0xF6);
            if (rm_get(e, t, &x, w, ip, &l)) return -1;
            if ((x.reg & 7) == 0) { alu(t, 4, l, C((uint64_t)x.imm & mask(w)), w); return 0; }
            if ((x.reg & 7) == 2) return rm_set(e, t, &x, l.k == VC && !l.pw && !l.rel ? C(~l.v & mask(w)) : U(), w, ip);
            z = alu(t, 5, C(0), l, w);
            return rm_set(e, t, &x, z, w, ip);
        }
        if ((op == 0xFE || op == 0xFF) && (x.reg & 7) <= 1) {
            w = width(&x, op == 0xFE);
            if (rm_get(e, t, &x, w, ip, &l)) return -1;
            z = l.k == VC && !l.pw ? C((l.v + ((x.reg & 7) ? ~0ULL : 1)) & mask(w)) : U();
            z.rel = l.k == VC && !l.pw && l.rel;
            flags(t, (x.reg & 7) ? 5 : 4, l, C(1), z, w);
            return rm_set(e, t, &x, z, w, ip);
        }
        if ((op == 0xC0 || op == 0xC1 || op == 0xD0 || op == 0xD1 || op == 0xD2 || op == 0xD3) &&
            ((x.reg & 7) == 4 || (x.reg & 7) == 5 || (x.reg & 7) == 7)) {
            int sh; Val cl = op == 0xD2 || op == 0xD3 ? reg_get(t, 1, 1) : U();   /* a count by cl flows into the result */
            w = width(&x, op == 0xC0 || op == 0xD0 || op == 0xD2);
            if (op == 0xD2 || op == 0xD3) { if (cl.k != VC) sh = -1; else sh = (int)(cl.v & (w == 8 ? 63 : 31)); }
            else sh = op == 0xD0 || op == 0xD1 ? 1 : (int)(x.imm & (w == 8 ? 63 : 31));
            if (rm_get(e, t, &x, w, ip, &l)) return -1;
            z = U();
            if (sh >= 0 && l.k == VC && !l.pw && !l.rel) {
                uint64_t q = l.v & mask(w);
                if ((x.reg & 7) == 4) q <<= sh;
                else if ((x.reg & 7) == 5) q >>= sh;
                else q = (uint64_t)(((int64_t)(q << (64 - w * 8)) >> (64 - w * 8)) >> sh);
                z = C(q & mask(w));
            }
            if (sh) flags_unknown(t);
            return rm_set(e, t, &x, z, w, ip);
        }
        if (op == 0x69 || op == 0x6B) {
            w = width(&x, 0);
            if (rm_get(e, t, &x, w, ip, &l)) return -1;
            reg_set(t, x.reg, l.k == VC && !l.pw && !l.rel ? C((l.v * (uint64_t)x.imm) & mask(w)) : U(), w); flags_unknown(t); return 0;
        }
        if (op == 0x90 && !(x.rex & 1)) return 0;
        if (op == 0x98) {   /* cbw, cwde, cdqe */
            int64_t sx;
            w = width(&x, 0); v = reg_get(t, 0, w / 2);
            sx = w == 8 ? (int64_t)(int32_t)v.v : w == 4 ? (int64_t)(int16_t)v.v : (int64_t)(int8_t)v.v;
            reg_set(t, 0, v.k == VC ? C((uint64_t)sx & mask(w)) : U(), w); return 0;
        }
        if (op == 0x99) { w = width(&x, 0); v = reg_get(t, 0, w);
            reg_set(t, 2, v.k == VC && !v.rel ? C(v.v >> (w * 8 - 1) & 1 ? mask(w) : 0) : U(), w); return 0; }
        if (op == 0x87 && x.mod == 3) { w = width(&x, 0); l = reg_get(t, x.reg, w); v = reg_get(t, x.rm, w);
            t->tin = v.ts; reg_set(t, x.reg, v, w); t->tin = l.ts; reg_set(t, x.rm, l, w); return 0; }
        if (op == 0xC9) {
            t->r[4] = t->r[5];
            return pop(e, t, ip, &t->r[5]);
        }
        if (op == 0xCC) { t->trapped = 1; return 1; }   /* a trap: the path ends here */
        if (op == 0xC3) return do_ret(e, t, ip);
        if (op == 0xE8) return do_call(e, t, ip, (uint64_t)objc_x86_rel_target(p, &x, ip), 0, x.next);
        if (op == 0xE9 || op == 0xEB) {
            uint64_t tg = (uint64_t)objc_x86_rel_target(p, &x, ip);
            if (tail_target(e, ip, tg)) return do_call(e, t, ip, tg, 1, 0);
            t->rip = tg;
            return 0;
        }
        if (op >= 0x70 && op <= 0x7F) return branch(e, t, cond(t, op & 15), (uint64_t)objc_x86_rel_target(p, &x, ip));
        if (op == 0xFF && ((x.reg & 7) == 2 || (x.reg & 7) == 4)) {
            const char *n = NULL;
            if (rm_get(e, t, &x, 8, ip, &v)) return -1;
            if (v.k == VS && e->sym[v.sym].kind == SY_IMPORT) n = e->sym[v.sym].name;
            if (!n) return refuse(e, "indirect-call", "an indirect %s at 0x%llx", (x.reg & 7) == 2 ? "call" : "jump", (unsigned long long)ip);
            return (x.reg & 7) == 4 ? tail_import(e, t, n, ip) : call_import(e, t, n, ip);
        }
        if (op == 0xFF && (x.reg & 7) == 6) { if (rm_get(e, t, &x, 8, ip, &v)) return -1; return push(e, t, ip, v); }
    } else if (x.map == 1) {
        if (op >= 0x80 && op <= 0x8F) return branch(e, t, cond(t, op & 15), (uint64_t)objc_x86_rel_target(p, &x, ip));
        if (op == 0x1F) return 0;
        if (op == 0x0B) { t->trapped = 1; return 1; }   /* ud2: the path ends here */
        if (op == 0xB6 || op == 0xB7 || op == 0xBE || op == 0xBF) {
            int sw = op == 0xB7 || op == 0xBF ? 2 : 1;
            if (rm_get(e, t, &x, sw, ip, &v)) return -1;
            if (v.k == VC && (op == 0xBE || op == 0xBF)) v = C(sw == 1 ? (uint64_t)(int64_t)(int8_t)v.v : (uint64_t)(int64_t)(int16_t)v.v);
            else if (v.k != VC) v = U();
            w = width(&x, 0);
            reg_set(t, x.reg, v.k == VC ? C(v.v & mask(w)) : U(), w == 2 ? 2 : w < 4 ? 4 : w);
            return 0;
        }
        if (op >= 0x90 && op <= 0x9F) {
            int c = cond(t, op & 15);
            St *u;
            t->tin = ts_union(e, t->tin, t->fts);
            if (c >= 0) return rm_set(e, t, &x, C((uint64_t)c), 1, ip);
            t->pts = ts_union(e, t->pts, t->fts);
            if (!(u = fork_st(e, t))) return -1;
            guessed(e, u); guessed(e, t);
            if (rm_set(e, u, &x, C(1), 1, ip)) return -1;
            return rm_set(e, t, &x, C(0), 1, ip);
        }
        if (op >= 0x40 && op <= 0x4F) {
            int c = cond(t, op & 15);
            w = width(&x, 0);
            if (rm_get(e, t, &x, w, ip, &v)) return -1;
            l = reg_get(t, x.reg, w);
            if (c < 0) {
                St *u;
                t->pts = ts_union(e, t->pts, t->fts);
                if (!(u = fork_st(e, t))) return -1;
                guessed(e, u); guessed(e, t);
                u->tin = ts_union(e, v.ts, t->fts); reg_set(u, x.reg, v, w);
                t->tin = ts_union(e, l.ts, t->fts); reg_set(t, x.reg, l, w); return 0;
            }
            t->tin = ts_union(e, c ? v.ts : l.ts, t->fts);   /* the selected operand flows, and the flags that chose it */
            reg_set(t, x.reg, c ? v : l, w);
            return 0;
        }
        if (op == 0xAF) {
            w = width(&x, 0); l = reg_get(t, x.reg, w);
            if (rm_get(e, t, &x, w, ip, &v)) return -1;
            reg_set(t, x.reg, l.k == VC && v.k == VC && !l.pw && !v.pw && !l.rel && !v.rel ? C((l.v * v.v) & mask(w)) : U(), w); flags_unknown(t);
            return 0;
        }
    }
    r = unsupported(e, ip, &x, p, "an instruction the executor does not model");
    return r;
}
/* After an instruction that did not read rax while a stand-in held it: the add's result back where rax was not
 * written, else no twin is owed. */
static void unread_back(const Ex *e, St *u, size_t k, Val held) {
    if (u->addfork != k) return;
    if (u->r[0].k == VS && u->r[0].sym == e->unread && !u->r[0].ts && !u->r[0].pw) u->r[0] = held;
    else u->addfork = 0;
}
static int leaked(const Ex *e, const St *u) {
    size_t j;
    for (j = 1; j < 16; j++) if (u->r[j].k == VS && u->r[j].sym == e->unread) return 1;
    for (j = 0; j < u->nm; j++) if (u->m[j].v.k == VS && u->m[j].v.sym == e->unread) return 1;
    return 0;
}
/* One instruction; and an add's failed twin, which rax owes until an instruction may read it (or returns), is then
 * forked; a call or tail jump, or a write of rax that reads nothing of it, drops it. */
static int step(Ex *e, St *t) {
    size_t av, w = e->nwork, i, k = t->addfork; const uint8_t *p; ObjcIns x; Val held; int rc, bad; uint64_t ip = t->rip;
    char what[160];
    if (!k || !(p = code_at(e, t->rip, &av)) || objc_x86_decode(p, av, t->rip, &x)) return execute(e, t);
    if ((objc_x86_gpr_reads(&x, 1) & 1) || (x.map == 0 && x.op == 0xC3)) return owe_fork(e, t) ? -1 : execute(e, t);
    if (objc_x86_is_call_rel(&x) || objc_x86_is_ff(&x, 2) || objc_x86_is_ff(&x, 4) ||
        (objc_x86_is_jmp_rel(&x) && tail_target(e, t->rip, (uint64_t)objc_x86_rel_target(p, &x, t->rip)))) {
        t->addfork = 0;
        return execute(e, t);
    }
    if (e->unread == UINT32_MAX && (e->unread = opaque(e)) == UINT32_MAX) return -1;
    held = t->r[0]; t->r[0] = S(e->unread);
    if ((rc = execute(e, t)) < 0) return rc;
    bad = leaked(e, t);
    for (i = w; i < e->nwork; i++) bad |= leaked(e, e->work[i]);
    if (bad) {
        snprintf(what, sizeof what, "the result of class_addMethod at 0x%llx reached a register or memory through a form "
                 "the read set does not mark", (unsigned long long)t->adds[k - 1].site);
        return unsupported(e, ip, &x, p, what);
    }
    unread_back(e, t, k, held);
    for (i = w; i < e->nwork; i++) unread_back(e, e->work[i], k, held);
    return rc;
}

static int cmp_esc(const void *a, const void *b) {
    const uint64_t *x = a, *y = b;
    return x[0] != y[0] ? (x[0] < y[0] ? -1 : 1) : x[1] < y[1] ? -1 : x[1] > y[1];
}
static int cmp_range(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

int objc_derive_registration(const ObjcImage *im, uint64_t entry, const uint64_t *ranges, size_t n_ranges,
                             const ObjcRegBudget *b, ObjcRegResult *out) {
    ObjcRegStart s;
    memset(&s, 0, sizeof s); s.entry = entry;
    return objc_derive_registration_from(im, &s, ranges, n_ranges, b, out);
}
int objc_derive_registration_from(const ObjcImage *im, const ObjcRegStart *start, const uint64_t *ranges,
                                  size_t n_ranges, const ObjcRegBudget *b, ObjcRegResult *out) {
    Ex e; St *t; size_t i, j; uint64_t entry = start->entry;
    memset(out, 0, sizeof *out); memset(&e, 0, sizeof e);
    e.im = im; e.out = out; e.start = start; e.unread = UINT32_MAX;
    e.b.max_paths = b && b->max_paths ? b->max_paths : OBJC_REG_MAX_PATHS;
    e.b.max_depth = b && b->max_depth ? b->max_depth : OBJC_REG_MAX_DEPTH;
    e.b.max_insns = b && b->max_insns ? b->max_insns : OBJC_REG_MAX_INSNS;
    e.nfn = objc_image_nfunctions(im);
    if (!(e.rg = malloc((2 * n_ranges + 1) * sizeof *e.rg)) || !(e.reach = calloc(e.nfn + 1, 1)) || !(t = calloc(1, sizeof *t))) {
        free(e.rg); free(e.reach); oom(&e); return 1;
    }
    if (n_ranges) memcpy(e.rg, ranges, 2 * n_ranges * sizeof *e.rg);
    qsort(e.rg, n_ranges, 2 * sizeof *e.rg, cmp_range);
    for (i = 0, j = 0; i < n_ranges; i++) if (e.rg[2 * i] < e.rg[2 * i + 1]) { e.rg[2 * j] = e.rg[2 * i]; e.rg[2 * j + 1] = e.rg[2 * i + 1]; j++; }
    e.nrg = j;
    if (!(e.ts = calloc(2, sizeof *e.ts))) { free(e.rg); free(e.reach); free(t); oom(&e); return 1; }
    e.nts = e.capts = 2;
    t->ex = &e; t->r[4] = C(STACK_TOP); t->rip = entry; e.npaths = 1;
    if (!push(&e, t, entry, C(SENTINEL))) { t->m[t->nm - 1].ret = 1; t->m[t->nm - 1].push = 0; }
    if (start->arg0_class && (j = sym_new(&e, SY_CLASS, start->arg0_class)) != UINT32_MAX) t->r[7] = S((uint32_t)j);
    while (!out->refused) {
        int rc = 0;
        if (t->tailret) { uint64_t site = t->tailret; t->tailret = 0; rc = do_ret(&e, t, site); }
        while (!rc) {
            if (++e.ninsns > e.b.max_insns) { refuse(&e, "insn-budget", "more than %zu instructions, at 0x%llx", e.b.max_insns, (unsigned long long)t->rip); rc = -1; break; }
            rc = note_explored(&e, t->rip) ? -1 : step(&e, t);
        }
        if (rc == 1 && complete(&e, t)) rc = -1;
        st_free(t);
        if (rc < 0 || !e.nwork) break;
        t = e.work[--e.nwork];
    }
    while (e.nwork) st_free(e.work[--e.nwork]);
    free(e.work); free(e.rg); free(e.reach); free(e.ts);
    for (i = 0; i < e.nsym; i++) free(e.sym[i].name);
    free(e.sym);
    qsort(out->mutator_sites, out->n_sites, sizeof *out->mutator_sites, cmp_range);
    qsort(out->called, out->n_called, sizeof *out->called, cmp_range);
    qsort(out->explored, out->n_explored, 2 * sizeof *out->explored, cmp_range);
    if (e.nexec && (out->executed = malloc(e.nexec * sizeof *out->executed))) {
        for (i = 0; i < e.capexec; i++) if (e.exec[i]) out->executed[out->n_executed++] = e.exec[i];
        qsort(out->executed, out->n_executed, sizeof *out->executed, cmp_range);
    } else if (e.nexec) oom(&e);
    free(e.exec);
    if (out->n_escaped) qsort(out->escaped, out->n_escaped, sizeof *out->escaped, cmp_esc);
    qsort(out->selreg, out->n_selreg, sizeof *out->selreg, cmp_range);
    uniq_reads(out);
    if (out->n_stores) {
        qsort(out->image_stores, out->n_stores, sizeof *out->image_stores, cmp_read);
        for (i = 1, j = 1; i < out->n_stores; i++) if (cmp_read(&out->image_stores[i], &out->image_stores[j - 1])) out->image_stores[j++] = out->image_stores[i];
        out->n_stores = j;
    }
    return out->refused ? 1 : 0;
}

int objc_reg_mutator(const char *import) { return import && listed(MUTATORS, import + (import[0] == '_')); }

void objc_reg_free(ObjcRegResult *r) {
    size_t i, j;
    for (i = 0; i < r->n_paths; i++) {
        ObjcRegPath *p = &r->paths[i];
        for (j = 0; j < p->n_found; j++) { free(p->found[j].cls); free(p->found[j].sel); }
        for (j = 0; j < p->n_adds; j++) { free(p->adds[j].cls); free(p->adds[j].sel); free(p->adds[j].imp); free(p->adds[j].types); }
        for (j = 0; j < p->n_null_classes; j++) free(p->null_classes[j]);
        free(p->found); free(p->adds); free(p->null_classes);
    }
    free(r->paths); free(r->mutator_sites); free(r->called); free(r->explored); free(r->executed); free(r->escaped); free(r->selreg); free(r->const_reads); free(r->image_stores);
    memset(r, 0, sizeof *r);
}
