/* classify.c -- one verdict per dispatch site, with the proof or the reason it is unproven.
 *
 * Receivers close first (binding.c: measured operands, then the reviewed receipt), then through
 * reviewed R2 type evidence (source-evidence.c), then by downcast refinement: a send whose
 * receiver operand is the very value an earlier `isKindOfClass:` was sent with a class operand,
 * on a path where that send answered YES (the reader's path conditions, report.h ObjcCond), is
 * sent to an instance of that class or a subclass. A different value, a NO path or a value
 * produced again since does not refine.
 *
 * Verdicts (exactly the spec's five; `provided` belongs to provider verification, not here):
 *   floor-supported  the floor runtime capture resolves KIND SELECTOR on the receiver's class
 *                    chain -- an implementation measured on 10.9.5 with its image -- or the
 *                    artifact itself implements it on that chain (its own class or category), or
 *                    a shipped image of its closure does (main.m "The shipped closure": the
 *                    finding then names that image), or
 *                    a cluster witness shows the concrete class +alloc returns implements it, or
 *                    R1 below holds.
 *   guarded          the method is absent from the floor chain, the reader measured a
 *                    respondsToSelector: of exactly this selector, sent to exactly this receiver
 *                    value, answering YES on every path to the send, and the build evidence
 *                    holds a reviewed guard record for this function and selector. A measured
 *                    guard without a reviewed record, or a record without a measured guard, is not.
 *   unsupported      the receiver's class chain is fully measured on the floor and none of it,
 *                    nor the artifact, implements the method, no subclass on the floor does either,
 *                    and no guard was measured; or the receiver's class is a later one the newer
 *                    SDK declares. A later API need not be on any list: absence is measured.
 *   unresolved       anything this module cannot prove either way: an open receiver or selector,
 *                    a class from an image whose methods the capture did not record, a framework
 *                    outside the reference closure, a subclass that implements the method (class
 *                    cluster or private), a measured guard awaiting review, or R1 not applying.
 *
 * R1, root-method witness (design revision R1 in the plan, as amended): a reviewed root selector
 * (the capture's "check root-selector" rows, which must be the manifest's list) on a receiver
 * whose class the floor runtime alone does not give. The witness measures method existence, not
 * behaviour: an NSProxy-rooted class resolves the root selectors (that NSProxy forwards or
 * raises is behaviour) and counts as implementing them. (a) An application-defined class whose
 * superclass chain, through the artifact's own class records, reaches a floor class: R1 holds
 * when that class's witness row resolves the selector for the kind. A chain that ends at an
 * artifact root, or leaves the artifact for a class outside the reference, has no root proof.
 * (b) A receiver of unknown class -- an incoming argument, a collection element, an `id` result,
 * anything the receiver closure left open, but not a super send: R1 holds when the witness
 * resolves the selector, for both kinds, on every captured floor class except the measured
 * non-implementing ones, which reference.c has already held to the reviewed root_exceptions (any
 * other set is cannot-measure), and when the analyzed closure's own classes are measured too
 * (objc_measure_class_roots below): every class the artifact defines, provider code linked into
 * it included, reaches through its superclass chain -- the artifact's own class records, then the
 * floor capture's class rows -- an NSObject or NSProxy root, and every dependency is in the floor
 * capture, whose witness then covers each class it brings. A class with any other root, an
 * unreadable superclass or one outside the reference, or a dependency the capture did not load,
 * keeps R1 off every receiver of unknown class in that artifact, and the report names it. Run-time
 * class creation is refused by the reader (macho-reader.c). The measured non-implementing floor
 * classes are the accepted residual risk: such a receiver could be one of them. The proof names
 * them, and every report lists them with the witness identity (main.m). The plan's R1 selector set
 * adds retain, release, autorelease and +class, whose measured exception sets are strict subsets of
 * those classes, recorded per selector (reference.c holds each to its record): a send of one of them
 * names its own set as the residual risk. -class has no recorded set and is held to the six it
 * measures, so class closes on a receiver of unknown class, which could be sent either kind, with
 * both kinds' sets together -- the six -- as its risk. Classes loaded later
 * (bundles, plug-ins) are outside the measurement, a stated limit. With no witness rows R1 never
 * applies. */
#include "report.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHAIN_MAX 64

static const char *VERDICT[] = { "floor-supported", "provided", "guarded", "unsupported", "unresolved" };
const char *objc_verdict_name(ObjcVerdict v) { return VERDICT[v]; }

static const char *rt_get3(const ObjcMap *m, const char *x, const char *y, const char *z) {
    char key[1024];
    snprintf(key, sizeof key, "%s\t%s\t%s", x, y, z);
    return objc_map_get(m, key);
}

static const ObjcRtClass *rt_class(const ObjcAnalysis *a, const char *name) {
    const char *i = objc_map_get(a->rt_class, name);
    return i ? &a->rt_classes[strtoul(i, NULL, 10)] : NULL;
}

/* The floor capture recorded this class's method lists: its image is required (or a fixture). */
static int rt_measured(const ObjcAnalysis *a, const ObjcRtClass *c) {
    const char *role = objc_map_get(a->rt_image_role, c->image);
    return role && (!strcmp(role, "required") || !strcmp(role, "fixture"));
}

static const ObjcEvidence *app_class(const ObjcAnalysis *a, const char *name) {
    size_t i;
    for (i = 0; i < a->n_evidence; i++)
        if (a->evidence[i].kind == OBJC_EV_CLASS_DEF && a->evidence[i].name && !strcmp(a->evidence[i].name, name))
            return &a->evidence[i];
    return NULL;
}

/* The artifact implements kind/sel on cls itself (class body or one of its categories). */
static const ObjcEvidence *app_method(const ObjcAnalysis *a, const char *cls, const char *kind, const char *sel) {
    size_t i;
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        if (e->kind == OBJC_EV_METHOD_DEF && e->owner && e->method_kind && e->selector && !strcmp(e->owner, cls) &&
            !strcmp(e->method_kind, kind) && !strcmp(e->selector, sel))
            return e;
    }
    return NULL;
}

static int is_root_selector(const ObjcAnalysis *a, const char *sel) {
    size_t i;
    for (i = 0; i < a->n_root_selectors; i++) if (!strcmp(a->root_selectors[i], sel)) return 1;
    return 0;
}

/* The one dispatch record at site, or NULL -- also for a call read once per incoming path
 * (macho-reader.c): which path's send a later test or receiver is about is not known, so a
 * condition or result naming that site proves nothing here (binding.c types such a result only
 * when every path agrees). */
static const ObjcEvidence *dispatch_at(const ObjcAnalysis *a, const char *slice, uint64_t site, size_t *idx) {
    size_t i;
    const ObjcEvidence *hit = NULL;
    for (i = 0; i < a->n_evidence; i++)
        if (a->evidence[i].kind == OBJC_EV_DISPATCH_CALL && a->evidence[i].address == site && !strcmp(a->evidence[i].slice, slice)) {
            if (hit || a->evidence[i].incoming) return NULL;
            if (idx) *idx = i;
            hit = &a->evidence[i];
        }
    return hit;
}

static ObjcSend *send_of(ObjcAnalysis *a, size_t ev) {
    size_t i;
    for (i = 0; i < a->n_sends; i++) if (a->sends[i].evidence == ev) return &a->sends[i];
    return NULL;
}

/* Two operands are the same value only when the reader named its producer: a dispatch result,
 * an incoming argument, or a class operand. */
static int same_value(const ObjcValue *x, const ObjcValue *y) {
    if (x->form != y->form || x->ref != y->ref) return 0;
    return x->form == OBJC_VAL_RESULT || x->form == OBJC_VAL_ARGUMENT || x->form == OBJC_VAL_CLASS_CACHE ||
           x->form == OBJC_VAL_CLASSREF || x->form == OBJC_VAL_CLASS_LITERAL;
}

static int sel_operand_is(const ObjcValue *v, const char *sel) {
    return v->text && !strcmp(v->text, sel) &&
           (v->form == OBJC_VAL_SEL_CACHE || v->form == OBJC_VAL_SELREF || v->form == OBJC_VAL_SEL_LITERAL ||
            v->form == OBJC_VAL_SEL_NSSTRING);
}

/* ---- downcast refinement ---------------------------------------------------------------- */

static int refine_downcasts(ObjcAnalysis *a) {
    size_t i, c;
    for (i = 0; i < a->n_sends; i++) {
        ObjcSend *s = &a->sends[i];
        const ObjcEvidence *e = &a->evidence[s->evidence];
        if (s->origin != OBJC_ORIGIN_OPEN || !s->selector) continue;
        for (c = 0; c < e->nconds; c++) {
            size_t kidx;
            const ObjcEvidence *k;
            const ObjcSend *ks;
            char basis[1024];
            if (!e->conds[c].value || !(k = dispatch_at(a, e->slice, e->conds[c].site, &kidx))) continue;
            if (!(ks = send_of(a, kidx)) || !ks->selector || strcmp(ks->selector, "isKindOfClass:")) continue;
            if (!same_value(&k->receiver, &e->receiver)) continue;
            if (!(k->arg.form == OBJC_VAL_CLASS_CACHE || k->arg.form == OBJC_VAL_CLASSREF ||
                  k->arg.form == OBJC_VAL_CLASS_LITERAL) || !k->arg.text) continue;
            snprintf(basis, sizeof basis, "downcast: isKindOfClass: %s at 0x%llx answered YES for this value; measured: %s",
                     k->arg.text, (unsigned long long)k->address, s->reason ? s->reason : "-");
            if (objc_set_string(&s->receiver, k->arg.text) || objc_set_string(&s->method_kind, "-") ||
                objc_set_string(&s->basis, basis) || objc_set_string(&s->reason, NULL))
                return objc_fail(a, "out-of-memory", NULL, 0, "downcast");
            s->origin = OBJC_ORIGIN_DOWNCAST; s->exact = 0; s->allocated = 0;
            break;
        }
    }
    return OBJC_OK;
}

/* ---- verdicts ------------------------------------------------------------------------------ */

typedef struct {
    ObjcVerdict v;
    char framework[256], proof[2048], alternatives[1024];
    int r1;
    size_t image;   /* ObjcFinding.image: 0 none, 1 the artifact, k + 1 shipped image k */
} Verdict;

static void set(Verdict *o, ObjcVerdict v, const char *fw, const char *fmt, const char *x, const char *y, const char *z) {
    o->v = v;
    snprintf(o->framework, sizeof o->framework, "%s", fw ? fw : "");
    snprintf(o->proof, sizeof o->proof, fmt, x ? x : "", y ? y : "", z ? z : "");
}

/* Whether kind/sel resolves on floor class cls's runtime chain: 1 yes (owner/image set), 0 no
 * with every class on the chain measured, -1 an unmeasured class on the way (owner = it). A
 * category of the closure's own answers with *artifact 1 + its image (0 the artifact). */
static int floor_resolves(const ObjcAnalysis *a, const char *cls, const char *kind, const char *sel,
                          char *owner, size_t ownersz, const char **image, int *artifact) {
    const ObjcRtClass *c = rt_class(a, cls);
    int depth;
    *artifact = 0;
    for (depth = 0; c && depth < CHAIN_MAX; depth++) {
        const char *img;
        const ObjcEvidence *m;
        if ((m = app_method(a, c->name, kind, sel))) { snprintf(owner, ownersz, "%s", c->name); *image = NULL; *artifact = 1 + (int)m->image; return 1; }
        if (!rt_measured(a, c)) { snprintf(owner, ownersz, "%s", c->name); *image = c->image; return -1; }
        if ((img = rt_get3(a->rt_method, c->name, kind, sel))) { snprintf(owner, ownersz, "%s%s", kind, c->name); *image = img; return 1; }
        if (!c->super && !strcmp(kind, "+") && (img = rt_get3(a->rt_method, c->name, "-", sel))) {
            snprintf(owner, ownersz, "-%s", c->name); *image = img; return 1;   /* a root's instance methods answer class messages */
        }
        c = c->super ? rt_class(a, c->super) : NULL;
    }
    return 0;
}

/* A floor class below cls (not cls itself) that implements kind/sel, or NULL. */
static const char *floor_subclass_with(const ObjcAnalysis *a, const char *cls, const char *kind, const char *sel) {
    size_t i;
    for (i = 0; i < a->n_rt_classes; i++) {
        const ObjcRtClass *c = &a->rt_classes[i], *p;
        int depth;
        if (!strcmp(c->name, cls) || !rt_get3(a->rt_method, c->name, kind, sel)) continue;
        for (p = c, depth = 0; p && p->super && depth < CHAIN_MAX; depth++) {
            if (!strcmp(p->super, cls)) return c->name;
            p = rt_class(a, p->super);
        }
    }
    return NULL;
}

/* The newer SDK's declaration of kind/sel on cls's declared chain: "introduced\tframework..." */
static const char *later_declaration(const ObjcAnalysis *a, const char *cls, const char *kind, const char *sel, char *owner, size_t ownersz) {
    int depth;
    for (depth = 0; cls && depth < CHAIN_MAX; depth++) {
        const char *d = rt_get3(a->nw_method, cls, kind, sel), *c;
        static char sup[256];
        if (d) { snprintf(owner, ownersz, "%s", cls); return d; }
        if (!(c = objc_map_get(a->nw_class, cls))) return NULL;
        snprintf(sup, sizeof sup, "%.*s", (int)strcspn(c, "\t"), c);
        cls = strcmp(sup, "-") ? sup : NULL;
    }
    return NULL;
}

static void field(const char *tsv, int n, char *out, size_t outsz) {
    while (n-- > 0 && tsv) { tsv = strchr(tsv, '\t'); if (tsv) tsv++; }
    if (!tsv) { snprintf(out, outsz, "-"); return; }
    snprintf(out, outsz, "%.*s", (int)strcspn(tsv, "\t"), tsv);
}

static int r1_exception(const ObjcAnalysis *a, const char *cls) {
    size_t i;
    for (i = 0; i < a->n_r1_exceptions; i++) if (!strcmp(a->r1_exceptions[i], cls)) return 1;
    return 0;
}

/* R1 (b): every captured class resolves kind/sel but the reviewed exceptions; 0 names one that does not. */
static int witness_universal(const ObjcAnalysis *a, const char *kind, const char *sel, const char **odd) {
    size_t i;
    *odd = NULL;
    if (!a->n_r1_exceptions) return 0;   /* the witness was not held to a reviewed exception set */
    for (i = 0; i < a->n_rt_classes; i++) {
        const char *w = rt_get3(a->rt_witness, a->rt_classes[i].name, kind, sel);
        if ((!w || (w[0] == '-' && w[1] == '\t')) && !r1_exception(a, a->rt_classes[i].name)) { *odd = a->rt_classes[i].name; return 0; }
    }
    return 1;
}

/* R1 (a): the floor ancestor's witness row resolves kind/sel -- existence, whatever its root. */
static int witness_holds(const ObjcAnalysis *a, const char *floor_cls, const char *kind, const char *sel, char *why, size_t whysz) {
    const char *w = rt_get3(a->rt_witness, floor_cls, kind, sel);
    char impl[256], image[256], root[256];
    if (!a->n_witness) { snprintf(why, whysz, "the reference set has no R1 witness"); return 0; }
    if (!w) { snprintf(why, whysz, "no witness row for %s%s %s", kind, floor_cls, sel); return 0; }
    field(w, 0, impl, sizeof impl); field(w, 1, image, sizeof image); field(w, 2, root, sizeof root);
    if (!strcmp(impl, "-")) {
        snprintf(why, whysz, "the witness says %s%s does not resolve %s (root %s, an accepted witness exception)", kind, floor_cls, sel, root);
        return 0;
    }
    snprintf(why, whysz, "witness %s%s %s -> %s in %s, root %s (method existence, measured on the floor)", kind, floor_cls, sel, impl, image, root);
    return 1;
}

/* ---- the analyzed closure's own classes (R1 b) -------------------------------------------- */

/* The floor role of a system dependency: its captured image row, or an override of its name. */
const char *objc_floor_role(const ObjcAnalysis *a, const char *path) {
    char key[4096 + 2];
    const char *r, *base = strrchr(path, '/');
    snprintf(key, sizeof key, "@%s", path);
    if ((r = objc_map_get(a->rt_image_role, key))) return r;
    if (base && objc_map_get(a->rt_override, base + 1) && strstr(path, ".framework/")) return "override";
    return NULL;
}

static int note(ObjcAnalysis *a, char ***v, size_t *n, const char *fmt, const char *x, const char *y, const char *z) {
    char buf[1024];
    snprintf(buf, sizeof buf, fmt, x ? x : "", y ? y : "", z ? z : "");
    return objc_strv_push(v, n, buf) ? objc_fail(a, "out-of-memory", NULL, 0, "class roots") : OBJC_OK;
}

/* For every class the artifact defines: follow its superclass through the artifact's own class
 * records, then through the floor capture's class rows, to a root. NSObject and NSProxy roots are
 * measured facts ("CLASS\tROOT"); any other root, an unreadable superclass, a superclass outside the
 * reference or a chain too long names the class in roots_blocking. Every dependency must be one
 * the floor capture loaded. R1 (b) applies only when nothing blocks and a witness is loaded. */
static int measure_class_roots(ObjcAnalysis *a) {
    size_t i, j;
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i], *c = e;
        const char *root = NULL;
        int depth;
        char row[1024];
        if (e->kind != OBJC_EV_CLASS_DEF || !e->name) continue;
        for (depth = 0; depth < CHAIN_MAX; depth++) {
            const ObjcRtClass *f;
            const ObjcEvidence *next;
            if (c->symbol && !strcmp(c->symbol, "root")) {
                if (note(a, &a->roots_blocking, &a->n_roots_blocking, "%s: %s is a root class of the artifact's own", e->name, c->name, NULL)) return OBJC_CANNOT_MEASURE;
                break;
            }
            if (!c->owner) {
                if (note(a, &a->roots_blocking, &a->n_roots_blocking, "%s: the superclass of %s cannot be read", e->name, c->name, NULL)) return OBJC_CANNOT_MEASURE;
                break;
            }
            if ((next = app_class(a, c->owner)) && next != c) { c = next; continue; }
            if (!(f = rt_class(a, c->owner))) {
                if (note(a, &a->roots_blocking, &a->n_roots_blocking, "%s: superclass %s is outside the reference (no floor runtime class)", e->name, c->owner, NULL)) return OBJC_CANNOT_MEASURE;
                break;
            }
            if (strcmp(f->root, "NSObject") && strcmp(f->root, "NSProxy")) {
                if (note(a, &a->roots_blocking, &a->n_roots_blocking, "%s: floor superclass %s has root %s, not NSObject or NSProxy", e->name, c->owner, f->root)) return OBJC_CANNOT_MEASURE;
                break;
            }
            root = f->root;
            break;
        }
        if (depth == CHAIN_MAX && note(a, &a->roots_blocking, &a->n_roots_blocking, "%s: the superclass chain does not end", e->name, NULL, NULL))
            return OBJC_CANNOT_MEASURE;
        if (root) {
            snprintf(row, sizeof row, "%s\t%s", e->name, root);
            if (objc_strv_push(&a->class_roots, &a->n_class_roots, row)) return objc_fail(a, "out-of-memory", NULL, 0, "class roots");
        }
    }
    for (i = 0; i < a->n_dylibs + a->n_shipped; i++) {
        size_t d;
        /* Every image's system loads; a non-system one is shipped, read above (main.m). */
        for (d = 0; d < (i < a->n_dylibs ? 1 : a->shipped[i - a->n_dylibs].n_dylibs); d++) {
        const char *p = i < a->n_dylibs ? a->dylibs[i].path : a->shipped[i - a->n_dylibs].dylibs[d].path;
        if (a->n_shipped && strncmp(p, "/usr/lib/", 9) && strncmp(p, "/System/Library/", 16)) continue;
        if (objc_floor_role(a, p)) continue;
        for (j = 0; j < a->n_uncaptured_deps && strcmp(a->uncaptured_deps[j], p); j++) ;
        if (j < a->n_uncaptured_deps) continue;
        if (objc_strv_push(&a->uncaptured_deps, &a->n_uncaptured_deps, p) ||
            note(a, &a->roots_blocking, &a->n_roots_blocking, "dependency %s is not in the floor capture", p, NULL, NULL))
            return objc_fail(a, "out-of-memory", NULL, 0, "class roots");
        }
    }
    a->r1_unknown = a->n_witness && !a->n_roots_blocking;
    return OBJC_OK;
}

/* The measured respondsToSelector: guard of send `ev`, or NULL. */
static const ObjcEvidence *measured_guard(ObjcAnalysis *a, size_t ev, const char *sel) {
    const ObjcEvidence *e = &a->evidence[ev];
    size_t c;
    for (c = 0; c < e->nconds; c++) {
        size_t gidx;
        const ObjcEvidence *g;
        const ObjcSend *gs;
        if (!e->conds[c].value || !(g = dispatch_at(a, e->slice, e->conds[c].site, &gidx))) continue;
        if (!(gs = send_of(a, gidx)) || !gs->selector || strcmp(gs->selector, "respondsToSelector:")) continue;
        if (same_value(&g->receiver, &e->receiver) && sel_operand_is(&g->arg, sel)) return g;
    }
    return NULL;
}

static void absent_verdict(ObjcAnalysis *a, size_t ev, const ObjcSend *s, const char *chain, Verdict *o) {
    const ObjcEvidence *g = measured_guard(a, ev, s->selector);
    const char *sub = s->exact ? NULL : floor_subclass_with(a, s->receiver, s->method_kind, s->selector);
    char owner[256], intro[64], fw[256], buf[512];
    const char *later = later_declaration(a, s->receiver, s->method_kind, s->selector, owner, sizeof owner);
    if (later) { field(later, 0, intro, sizeof intro); field(later, 1, fw, sizeof fw); }
    if (g) {
        const ObjcGuardRecord *r = objc_guard_record(a, ev);
        snprintf(buf, sizeof buf, "0x%llx", (unsigned long long)g->address);
        if (r && !strcmp(r->review_status, "reviewed") && r->reviewer && *r->reviewer && r->review_reason && *r->review_reason) {
            char cite[1024];
            snprintf(cite, sizeof cite, "%s:%llu sha256:%s; fallback: %s; reviewed by %s: %s", r->source_file,
                     (unsigned long long)r->source_line, r->source_sha256, r->fallback, r->reviewer, r->review_reason);
            set(o, OBJC_GUARDED, later ? fw : NULL, "absent from the floor; respondsToSelector: at %s answers YES on every path here, for this receiver and selector; guard record %s: %s",
                buf, r->id, cite);
            return;
        }
        set(o, OBJC_UNRESOLVED, later ? fw : NULL,
            "absent from the floor; a respondsToSelector: guard is measured at %s but %s", buf,
            r ? "its guard record is not reviewed" : "no build evidence holds a reviewed guard record for it", NULL);
        return;
    }
    if (sub) {
        set(o, OBJC_UNRESOLVED, NULL, "absent from %s on the floor, but its floor subclass %s implements it: a class cluster or private subclass may answer", chain, sub, NULL);
        return;
    }
    if (later) {
        snprintf(buf, sizeof buf, "%s%s %s introduced %s", s->method_kind, owner, s->selector, intro);
        set(o, OBJC_UNSUPPORTED, fw, "unguarded; absent from the floor runtime for %s; the newer SDK declares %s", chain, buf, NULL);
    } else {
        set(o, OBJC_UNSUPPORTED, NULL, "unguarded; absent from the floor runtime for %s and declared by neither SDK", chain, NULL, NULL);
    }
}

static void verdict_of(ObjcAnalysis *a, size_t si, Verdict *o) {
    ObjcSend *s = &a->sends[si];
    const ObjcEvidence *e = &a->evidence[s->evidence];
    char owner[256], why[512], chain[512];
    const char *image = NULL;
    int r, artifact;
    memset(o, 0, sizeof *o);
    if (!s->selector) { set(o, OBJC_UNRESOLVED, NULL, "selector not recovered: %s", s->reason, NULL, NULL); return; }
    if (!s->receiver) {
        /* R1 (b): a receiver of unknown class, not a super send. */
        if (is_root_selector(a, s->selector) && e->name && !strstr(e->name, "Super")) {
            size_t pidx;
            const ObjcEvidence *pe = e->receiver.form == OBJC_VAL_RESULT ? dispatch_at(a, e->slice, e->receiver.ref, &pidx) : NULL;
            const ObjcSend *ps = pe ? send_of(a, pidx) : NULL;
            const char *odd = NULL;
            char risk[1024], who[512], buf[2048], blocking[1024];
            size_t i, at = 0;
            if (ps && ps->receiver)
                snprintf(who, sizeof who, "receiver vended by %s[%s %s]", ps->method_kind ? ps->method_kind : "?", ps->receiver,
                         ps->selector ? ps->selector : "?");
            else snprintf(who, sizeof who, "receiver of unknown class (%s)", s->reason ? s->reason : "-");
            if (!a->n_witness) {
                set(o, OBJC_UNRESOLVED, NULL, "%s; R1 cannot apply: the reference set has no root-method witness", s->reason, NULL, NULL);
            } else if (!a->r1_unknown) {
                blocking[0] = 0;
                for (i = 0; i < a->n_roots_blocking && at + 4 < sizeof blocking; i++)
                    at += (size_t)snprintf(blocking + at, sizeof blocking - at, "%s%s", i ? "; " : "", a->roots_blocking[i]);
                set(o, OBJC_UNRESOLVED, NULL, "%s; R1 does not apply to receivers of unknown class in this artifact: %s", s->reason, blocking, NULL);
            } else if (witness_universal(a, "-", s->selector, &odd) && witness_universal(a, "+", s->selector, &odd)) {
                /* either kind could be sent: both kinds' measured sets are the risk */
                objc_r1_selector_exceptions(a, NULL, s->selector, risk, sizeof risk);
                snprintf(buf, sizeof buf, "R1: %s; every class the artifact defines has a measured NSObject or NSProxy root (%zu), and every "
                         "dependency is in the floor capture; the witness resolves -%s and +%s on every captured floor class, NSProxy-rooted "
                         "ones included (it measures existence), but the accepted residual risk: %s",
                         who, a->n_class_roots, s->selector, s->selector, risk);
                set(o, OBJC_FLOOR_SUPPORTED, NULL, "%s", buf, NULL, NULL);
                o->r1 = 1;
            } else {
                set(o, OBJC_UNRESOLVED, NULL, "%s; R1 does not close it: the witness says floor class %s, not an accepted exception, does not resolve %s",
                    s->reason, odd ? odd : "-", s->selector);
            }
            return;
        }
        set(o, OBJC_UNRESOLVED, NULL, "receiver not closed: %s", s->reason, NULL, NULL);
        return;
    }
    /* An application-defined class: its own methods, then its chain into the floor (R1 a). */
    if (!rt_class(a, s->receiver) && app_class(a, s->receiver)) {
        const char *cls = s->receiver;
        const ObjcEvidence *m;
        int depth;
        for (depth = 0; cls && depth < CHAIN_MAX; depth++) {
            const ObjcEvidence *c = app_class(a, cls);
            if (rt_class(a, cls)) break;
            if (!c) { set(o, OBJC_UNRESOLVED, NULL, "%s's superclass chain leaves the artifact at %s, which the floor reference does not know", s->receiver, cls, NULL); return; }
            if ((m = app_method(a, cls, s->method_kind, s->selector))) {
                if (m->image) set(o, OBJC_FLOOR_SUPPORTED, a->image_paths[m->image], "implemented by shipped image %s's own %s%s",
                                  a->image_paths[m->image], s->method_kind, cls);
                else set(o, OBJC_FLOOR_SUPPORTED, NULL, "implemented by the artifact's own %s%s", s->method_kind, cls, NULL);
                o->image = 1 + m->image;
                return;
            }
            if (!c->owner) {
                set(o, is_root_selector(a, s->selector) ? OBJC_UNRESOLVED : OBJC_UNSUPPORTED, NULL,
                    "%s is an application root class without %s and without an NSObject root proof", cls, s->selector, NULL);
                return;
            }
            cls = c->owner;
        }
        r = cls ? floor_resolves(a, cls, s->method_kind, s->selector, owner, sizeof owner, &image, &artifact) : 0;
        if (r > 0 && objc_r1_reviewed(a, s->method_kind, s->selector)) {
            if (!witness_holds(a, cls, s->method_kind, s->selector, why, sizeof why)) {
                set(o, OBJC_UNRESOLVED, NULL, "application class %s reaches floor class %s, but R1 does not hold: %s", s->receiver, cls, why);
                return;
            }
            set(o, OBJC_FLOOR_SUPPORTED, image, "R1: application class %s has floor ancestor %s; %s", s->receiver, cls, why);
            o->r1 = 1;
            return;
        }
        if (r > 0) { set(o, OBJC_FLOOR_SUPPORTED, image, "inherited from floor %s by application class %s", owner, s->receiver, NULL); o->image = (size_t)artifact; return; }
        if (r < 0) { set(o, OBJC_UNRESOLVED, NULL, "the floor capture did not record %s's methods (image %s)", owner, image, NULL); return; }
        snprintf(chain, sizeof chain, "%s%s (application) via %s", s->method_kind, s->receiver, cls ? cls : "-");
        absent_verdict(a, s->evidence, s, chain, o);
        return;
    }
    if (!rt_class(a, s->receiver)) {
        const char *nw = objc_map_get(a->nw_class, s->receiver);
        char intro[64], fw[256];
        if (nw) { field(nw, 1, intro, sizeof intro); field(nw, 2, fw, sizeof fw); }
        if (nw && strcmp(intro, "-") && !objc_map_get(a->fl_class, s->receiver)) {
            set(o, OBJC_UNSUPPORTED, fw, "class %s is not on the floor: the newer SDK declares it introduced %s", s->receiver, intro, NULL);
            return;
        }
        if (objc_map_get(a->fl_class, s->receiver)) {
            set(o, OBJC_UNRESOLVED, NULL, "class %s is declared by the floor SDK but its image is outside the captured floor runtime", s->receiver, NULL, NULL);
            return;
        }
        set(o, OBJC_UNRESOLVED, NULL, "class %s is outside the reference closure (no floor runtime or SDK declaration)", s->receiver, NULL, NULL);
        return;
    }
    r = floor_resolves(a, s->receiver, s->method_kind, s->selector, owner, sizeof owner, &image, &artifact);
    if (r > 0) {
        if (artifact > 1)
            set(o, OBJC_FLOOR_SUPPORTED, a->image_paths[artifact - 1], "implemented by shipped image %s on floor class %s (a category)",
                a->image_paths[artifact - 1], owner, NULL);
        else if (artifact) set(o, OBJC_FLOOR_SUPPORTED, NULL, "implemented by the artifact on floor class %s (a category)", owner, NULL, NULL);
        else set(o, OBJC_FLOOR_SUPPORTED, image, "floor runtime: %s %s in %s", owner, s->selector, image);
        o->image = (size_t)artifact;
        return;
    }
    if (r < 0) {
        set(o, OBJC_UNRESOLVED, NULL, "the floor capture did not record the methods of %s (image %s)", owner, image, NULL);
        return;
    }
    if (s->allocated) {
        size_t p, b;
        for (p = 0; p < a->n_probes; p++) {
            const ObjcClusterProbe *q = &a->probes[p];
            if (strcmp(q->cls, s->receiver) || strcmp(q->construction, "+alloc")) continue;
            for (b = 0; b < q->nbelow && strcmp(q->below[b], s->selector); b++) ;
            if (b < q->nbelow) {
                set(o, OBJC_FLOOR_SUPPORTED, NULL, "cluster witness \"%s\": +alloc returns %s, which implements %s", q->id, q->concrete, s->selector);
                return;
            }
        }
    }
    snprintf(chain, sizeof chain, "%s%s", s->method_kind, s->receiver);
    absent_verdict(a, s->evidence, s, chain, o);
}

int objc_classify_findings(ObjcAnalysis *a) {
    size_t i;
    int rc;
    a->findings_mode = 1;
    if ((rc = objc_close_sends(a))) return rc;
    if ((rc = objc_check_build_evidence(a))) return rc;
    if ((rc = objc_apply_type_evidence(a))) return rc;
    if ((rc = objc_apply_source_receipt(a))) return rc;
    if ((rc = refine_downcasts(a))) return rc;
    if ((rc = objc_apply_position_evidence(a))) return rc;
    if ((rc = measure_class_roots(a))) return rc;
    for (i = 0; i < a->n_sends; i++) {
        const ObjcSend *s = &a->sends[i];
        const ObjcEvidence *e = &a->evidence[s->evidence];
        Verdict v;
        ObjcFinding f;
        char id[1024];
        static const char *CLOSURE[] = { NULL, "measured", "receipt", "R2", "downcast", "source", "R3" };
        verdict_of(a, i, &v);
        /* One path of a merged call: the predecessor's last instruction keeps the id one finding's. */
        if (e->incoming) snprintf(id, sizeof id, "%s@0x%llx/0x%llx:%s[%s %s]", e->slice, (unsigned long long)e->address,
                                  (unsigned long long)e->incoming, s->method_kind ? s->method_kind : "?",
                                  s->receiver ? s->receiver : "?", s->selector ? s->selector : "?");
        else snprintf(id, sizeof id, "%s@0x%llx:%s[%s %s]", e->slice, (unsigned long long)e->address,
                      s->method_kind ? s->method_kind : "?", s->receiver ? s->receiver : "?", s->selector ? s->selector : "?");
        /* Closed in a shipped image: the id names it (main.m "The shipped closure"). */
        if (v.image > 1) {
            size_t at = strlen(id);
            snprintf(id + at, sizeof id - at, "@%s", a->image_paths[v.image - 1]);
        }
        memset(&f, 0, sizeof f);
        f.id = id; f.send = i; f.verdict = v.v; f.r1 = v.r1; f.image = v.image;
        f.framework = v.framework[0] ? v.framework : NULL;
        f.closure = (char *)CLOSURE[s->origin];
        f.proof = v.proof;
        f.alternatives = v.alternatives[0] ? v.alternatives : NULL;
        if (objc_add_finding(a, &f)) return OBJC_CANNOT_MEASURE;
    }
    return a->n_errors ? OBJC_CANNOT_MEASURE : OBJC_OK;
}
