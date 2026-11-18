/* binding.c -- map objc2 cache statics to their Rust binding path, and recognise objc2's
 * supported cache fetch functions.
 *
 * Profile: objc2 0.6 without the unstable-static-* features. sel!/class! expand to a
 * `static CACHED_SEL: CachedSel` / `static CACHED_CLASS: CachedClass` inside the calling item,
 * filled by `<CachedSel>::fetch(&CACHED_SEL, name)` / `<CachedClass>::fetch(&CACHED_CLASS, name,
 * caller)` with a NUL-terminated literal (objc2-0.6.3 src/__macro_helpers/cache.rs). The selector
 * itself comes from the bytes the reader recovered at that fetch call, never from the Rust
 * function name: generated names drop colons, and hand-written ones (NSData::bytes_raw ->
 * "bytes") need not resemble the selector at all.
 *
 * Receiver class and method kind are NOT derivable from a symbol: a static's path names the
 * Rust item that contains the sel!, which may be a shared helper. They are filled only from an
 * explicit binding receipt row (a TSV file, or the analyzer's build evidence), and stay NULL otherwise. A receipt row may name only a cache
 * inside an inherent method; one naming a free function, closure or trait method -- a helper
 * whose single cache serves unrelated callers -- is refused. Receiver closure for each dispatch
 * site is at the end of this file.
 *
 * Symbols are Rust v0 mangling, parsed by demangle-v0.c: anything it does not implement is refused,
 * never approximated. */
#include "report.h"
#include "demangle-v0.h"
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *crate_of(const V0Path *q) { const V0Path *c = v0_crate_root(q); return c ? c->ident : NULL; }

/* ---- public binding API ----------------------------------------------------------------- */

char *objc_binding_demangle(const char *symbol, char *why, size_t whysz) {
    V0 p; V0Path *top = v0_parse(&p, symbol); char *out = NULL;
    if (top) out = strdup(top->text);
    else if (why) snprintf(why, whysz, "%s", p.why);
    v0_release(&p);
    return out;
}

static int append0(char *buf, size_t bufsz, size_t *at, const char *s) {
    size_t k = strlen(s) + 1;
    if (*at + k + 1 > bufsz) return -1;
    memcpy(buf + *at, s, k); *at += k; buf[*at] = 0;
    return 0;
}

int objc_binding_symbol_types(const char *symbol, char *buf, size_t bufsz, char *cbuf, size_t cbufsz,
                              char *why, size_t whysz) {
    V0 p; V0Path *top, *q;
    size_t at = 0, cat_ = 0;
    int i, rc = 0;
    if (bufsz < 2 || cbufsz < 2) return -1;
    buf[0] = buf[1] = cbuf[0] = cbuf[1] = 0;
    if (!(top = v0_parse(&p, symbol))) { snprintf(why, whysz, "%s", p.why); v0_release(&p); return -1; }
    if (p.crates_overflow) { snprintf(why, whysz, "more crate roots than this reader records"); v0_release(&p); return -1; }
    /* The function's own path, outward: the first impl it is in names the self type. */
    for (q = top; q && !rc; ) {
        if (q->kind == 'M' || q->kind == 'X' || q->kind == 'Y') { if (q->self_text) rc = append0(buf, bufsz, &at, q->self_text); break; }
        if (q->kind == 'N' || q->kind == 'I') q = q->parent; else break;
    }
    for (i = 0; i < p.ncrates && !rc; i++) {
        char d[16], pair[256];
        v0_dis_text(p.crates[i].dis, d, sizeof d);
        snprintf(pair, sizeof pair, "%s=%s", p.crates[i].id, d);
        rc = append0(cbuf, cbufsz, &cat_, pair);
    }
    if (rc) snprintf(why, whysz, "symbol types too long");
    v0_release(&p);
    return rc;
}

ObjcFetchForm objc_binding_fetch_form(const char *symbol) {
    V0 p; V0Path *top; ObjcFetchForm f = OBJC_FETCH_NONE;
    if (strncmp(symbol, "__R", 3) && strncmp(symbol, "_R", 2)) return f;
    if ((top = v0_parse(&p, symbol)) && top->kind == 'N' && top->ns == 'v' && top->parent->kind == 'M') {
        if (!strcmp(top->text, "<objc2::__macro_helpers::cache::CachedSel>::fetch")) f = OBJC_FETCH_SEL;
        else if (!strcmp(top->text, "<objc2::__macro_helpers::cache::CachedClass>::fetch")) f = OBJC_FETCH_CLASS;
        else if (!strcmp(top->text, "<objc2::runtime::Sel>::register_unchecked")) f = OBJC_WRAP_SEL_CSTR;
        else if (!strcmp(top->text, "<objc2_foundation::generated::__NSString::NSString>::from_str")) f = OBJC_WRAP_NSSTRING;
    }
    v0_release(&p);
    return f;
}

int objc_binding_cache_kind(const char *symbol) {
    V0 p; V0Path *top; int k = 0;
    if (strncmp(symbol, "__R", 3) && strncmp(symbol, "_R", 2)) return 0;
    /* Cheap filter before a full parse: the static's identifier is the last path element. */
    if (!strstr(symbol, "10CACHED_SEL") && !strstr(symbol, "12CACHED_CLASS")) return 0;
    if ((top = v0_parse(&p, symbol)) && top->kind == 'N' && top->ns == 'v') {
        if (!strcmp(top->ident, "CACHED_SEL")) k = 1;
        else if (!strcmp(top->ident, "CACHED_CLASS")) k = 2;
    }
    v0_release(&p);
    return k;
}

typedef struct { char *demangled, *selector, *receiver, *kind, *provenance; int used; } Receipt;

static void free_receipts(Receipt *r, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        free(r[i].demangled); free(r[i].selector); free(r[i].receiver); free(r[i].kind);
        free(r[i].provenance);
    }
    free(r);
}

/* Receipt schema 1: first line "# objc-binding-receipt 1", then TAB-separated
 * demangled-cache-path, selector, receiver class, method kind (+/-), provenance. */
static int load_receipt(ObjcAnalysis *a, Receipt **out, size_t *nout) {
    FILE *f;
    char line[4096];
    size_t n = 0, cap = 0, lineno = 0;
    Receipt *r = NULL;
    *out = NULL; *nout = 0;
    if (a->n_receipt) {   /* rows the front end took from build evidence */
        if (a->binding_receipt_path) return objc_fail(a, "binding-receipt-conflict", NULL, 0, "two receipts given");
        if (!(r = calloc(a->n_receipt, sizeof *r))) return objc_fail(a, "out-of-memory", NULL, 0, "receipt");
        for (n = 0; n < a->n_receipt; n++) {
            const ObjcReceiptRow *x = &a->receipt[n];
            if (!x->demangled || !x->selector || !x->receiver || !x->provenance || !x->kind ||
                (strcmp(x->kind, "+") && strcmp(x->kind, "-"))) {
                free_receipts(r, n);
                return objc_fail(a, "malformed-binding-receipt", NULL, 0, "build evidence receipt row %zu", n + 1);
            }
            if (!(r[n].demangled = strdup(x->demangled)) || !(r[n].selector = strdup(x->selector)) ||
                !(r[n].receiver = strdup(x->receiver)) || !(r[n].kind = strdup(x->kind)) ||
                !(r[n].provenance = strdup(x->provenance))) {
                free_receipts(r, n + 1);
                return objc_fail(a, "out-of-memory", NULL, 0, "receipt");
            }
        }
        *out = r; *nout = n;
        return 0;
    }
    if (!a->binding_receipt_path) return 0;
    if (!(f = fopen(a->binding_receipt_path, "r")))
        return objc_fail(a, "unreadable-binding-receipt", NULL, 0, "%s: %s",
                         a->binding_receipt_path, strerror(errno));
    while (fgets(line, sizeof line, f)) {
        char *field[6], *c = line;
        int nf = 0;
        size_t len = strlen(line);
        lineno++;
        if (len == 0 || line[len - 1] != '\n') {
            fclose(f); free_receipts(r, n);
            return objc_fail(a, "malformed-binding-receipt", NULL, 0, "line %zu unterminated or too long", lineno);
        }
        line[len - 1] = 0;
        if (lineno == 1) {
            if (strcmp(line, "# objc-binding-receipt 1")) {
                fclose(f); free_receipts(r, n);
                return objc_fail(a, "malformed-binding-receipt", NULL, 0, "missing schema-1 header");
            }
            continue;
        }
        if (!line[0] || line[0] == '#') continue;
        field[nf++] = c;
        while (*c) { if (*c == '\t') { *c = 0; if (nf == 6) break; field[nf++] = c + 1; } c++; }
        if (nf != 5 || !*field[0] || !*field[1] || !*field[2] || !*field[4] ||
            (strcmp(field[3], "+") && strcmp(field[3], "-"))) {
            fclose(f); free_receipts(r, n);
            return objc_fail(a, "malformed-binding-receipt", NULL, 0, "line %zu: want 5 fields, kind + or -", lineno);
        }
        if (n == cap) {
            Receipt *g = realloc(r, (cap = cap ? cap * 2 : 32) * sizeof *r);
            if (!g) { fclose(f); free_receipts(r, n); return objc_fail(a, "out-of-memory", NULL, 0, "receipt"); }
            r = g;
        }
        memset(&r[n], 0, sizeof *r);
        if (!(r[n].demangled = strdup(field[0])) || !(r[n].selector = strdup(field[1])) ||
            !(r[n].receiver = strdup(field[2])) || !(r[n].kind = strdup(field[3])) ||
            !(r[n].provenance = strdup(field[4]))) {
            n++; fclose(f); free_receipts(r, n);
            return objc_fail(a, "out-of-memory", NULL, 0, "receipt");
        }
        n++;
    }
    if (ferror(f)) { fclose(f); free_receipts(r, n); return objc_fail(a, "unreadable-binding-receipt", NULL, 0, "read error"); }
    fclose(f);
    *out = r; *nout = n;
    return 0;
}

int objc_bind_caches(ObjcAnalysis *a) {
    Receipt *rc; size_t nrc, i, j;
    int status = OBJC_OK;
    if (load_receipt(a, &rc, &nrc)) return OBJC_CANNOT_MEASURE;
    for (i = 0; i < a->n_evidence; i++) {
        ObjcEvidence *e = &a->evidence[i];
        ObjcBinding b;
        V0 p; V0Path *top, *fp, *gp;
        const char *recovered;
        if (e->kind != OBJC_EV_SEL_CACHE && e->kind != OBJC_EV_CLASS_CACHE) continue;
        memset(&b, 0, sizeof b);
        b.evidence = i;
        recovered = e->kind == OBJC_EV_SEL_CACHE ? e->selector : e->name;
        if (!(top = v0_parse(&p, e->symbol)) || top->kind != 'N' || top->ns != 'v' || !(fp = top->parent)) {
            status = objc_fail(a, "unsupported-binding-form", e->slice, e->address, "%s: %s",
                               e->symbol, top ? "cache static outside a value item" : p.why);
            v0_release(&p);
            continue;
        }
        b.demangled = (char *)top->text;
        gp = fp->parent;
        if (fp->kind == 'N' && fp->ns == 'v' && gp && gp->kind == 'M') {
            b.form = "inherent-method"; b.rust_owner = (char *)gp->text; b.rust_fn = (char *)fp->ident;
        } else if (fp->kind == 'N' && fp->ns == 'v' && gp && gp->kind == 'X') {
            b.form = "trait-method"; b.rust_owner = (char *)gp->text; b.rust_fn = (char *)fp->ident;
        } else if (fp->kind == 'N' && fp->ns == 'v' && gp && (gp->kind == 'N' || gp->kind == 'C')) {
            b.form = "free-fn"; b.rust_owner = (char *)gp->text; b.rust_fn = (char *)fp->ident;
        } else if (fp->kind == 'N' && fp->ns == 'C' && gp) {
            b.form = "closure"; b.rust_owner = (char *)gp->text;
            b.rust_fn = (char *)v0_ns_text(&p, 'C', fp->ident, fp->dis);
        } else {
            status = objc_fail(a, "unsupported-binding-form", e->slice, e->address,
                               "%s: unrecognised enclosing item", top->text);
            v0_release(&p);
            continue;
        }
        b.crate = (char *)crate_of(fp);
        for (j = 0; j < nrc; j++) {
            if (strcmp(rc[j].demangled, top->text)) continue;
            if (!recovered || strcmp(rc[j].selector, recovered)) continue;
            if (rc[j].used) {
                status = objc_fail(a, "binding-receipt-conflict", e->slice, e->address,
                                   "%s %s mapped twice", top->text, rc[j].selector);
                break;
            }
            if (strcmp(b.form, "inherent-method")) {
                /* A free function, closure or trait default method is a shared helper: its
                 * cache serves every caller, so no one source receiver describes it. */
                status = objc_fail(a, "receipt-on-shared-helper", e->slice, e->address,
                                   "%s is a %s; its receivers close per send or not at all", top->text, b.form);
                rc[j].used = 1;
                break;
            }
            rc[j].used = 1;
            b.receiver = rc[j].receiver; b.method_kind = rc[j].kind; b.provenance = rc[j].provenance;
            break;
        }
        if (objc_add_binding(a, &b)) status = OBJC_CANNOT_MEASURE;
        v0_release(&p);
    }
    /* A receipt row that matches a cache path but not its recovered bytes is a contradiction
     * between source and binary, not an unused row. */
    for (j = 0; j < nrc; j++) {
        if (rc[j].used) continue;
        for (i = 0; i < a->n_bindings; i++)
            if (!strcmp(a->bindings[i].demangled, rc[j].demangled)) {
                ObjcEvidence *e = &a->evidence[a->bindings[i].evidence];
                const char *got = e->kind == OBJC_EV_SEL_CACHE ? e->selector : e->name;
                status = objc_fail(a, "binding-receipt-conflict", e->slice, e->address,
                                   "%s: receipt says %s, artifact bytes say %s",
                                   rc[j].demangled, rc[j].selector, got ? got : "(none)");
                break;
            }
    }
    free_receipts(rc, nrc);
    return status;
}

/* ---- receiver/use closure ----------------------------------------------------------------
 *
 * One ObjcSend per dispatch call. The selector is the operand's recovered name (a cache, a
 * reference slot or a literal) or the one an allocation/opt entry point implies; anything else
 * leaves the send open. The receiver closes, in this order, through:
 *   1. the reader's measured operand: a class cache, class reference or literal class lookup
 *      (a class-method send, "+"); the result of objc_alloc of such a class (an instance of it,
 *      "-"); or the result of another closed send, typed by that method's DECLARED result in the
 *      signature companion -- found on the receiver's class or its declared superclasses -- where
 *      a named class gives an instance of it and instancetype an instance of the sender's class;
 *      a call read once per incoming path (a compiler merged its sends) returns what the path that ran
 *      returned, so its result closes only when every path's result closes to the same class and kind;
 *   2. otherwise, the binding receipt row for the selector's cache, when it names the source-
 *      declared receiver of the binding method that owns that cache.
 * When both apply they must agree (same kind, and the measured class the receipt's class or a
 * declared subclass of it); a disagreement is cannot-measure. A result declared id, an incoming
 * argument, a value the reader did not model, a super send or a send with no receipt stays open:
 * receiver NULL, the reason recorded, and the stage returns 4 -- or, in the analyzer's findings
 * mode, the send becomes an unresolved finding (classify.c). A protocol declaration or some
 * root class's implementation is never used as a receiver. */

#define CLOSE_MAX_DEPTH 64

typedef struct {
    int state;                  /* 0 unvisited, 1 in progress, 2 done */
    const char *selector;       /* borrowed from evidence/bindings */
    char receiver[256], kind[2], basis[768], reason[768];
    ObjcOrigin origin;
    int allocated, exact;
    const char *provenance;     /* borrowed from bindings */
    ObjcRecvFrom recv_from;     /* an open receiver's modelled origin (R3 checks positions against it) */
    size_t recv_send;
} Closure;

static const ObjcEvidence *dispatch_at(const ObjcAnalysis *a, const char *slice, uint64_t site, size_t *index) {
    size_t i;
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        if (e->kind == OBJC_EV_DISPATCH_CALL && e->address == site && !strcmp(e->slice, slice)) {
            *index = i;
            return e;
        }
    }
    return NULL;
}

/* The binding of the selector cache at `addr`, or NULL. */
static const ObjcBinding *cache_binding(const ObjcAnalysis *a, const char *slice, uint64_t addr) {
    size_t i;
    for (i = 0; i < a->n_bindings; i++) {
        const ObjcEvidence *e = &a->evidence[a->bindings[i].evidence];
        if (e->kind == OBJC_EV_SEL_CACHE && e->address == addr && !strcmp(e->slice, slice)) return &a->bindings[i];
    }
    return NULL;
}

static const char *super_of(const ObjcAnalysis *a, const char *cls, int *known) {
    size_t i;
    for (i = 0; i < a->n_classes; i++)
        if (!strcmp(a->classes[i].name, cls)) { *known = 1; return a->classes[i].super; }
    *known = 0;
    return NULL;
}

/* Whether `cls` is `ancestor` or a declared subclass of it. */
static int descends(const ObjcAnalysis *a, const char *cls, const char *ancestor) {
    int depth, known;
    for (depth = 0; cls && depth < CLOSE_MAX_DEPTH; depth++) {
        if (!strcmp(cls, ancestor)) return 1;
        cls = super_of(a, cls, &known);
    }
    return 0;
}

/* The declared result of kind/selector on cls or its first declaring superclass: 1 found (rk,
 * rc set), 0 none declared, -1 conflicting declarations at the first declaring class. */
static int declared_result(const ObjcAnalysis *a, const char *cls, const char *kind, const char *sel,
                           const char **rk, const char **rc, const char **owner) {
    int depth, known;
    for (depth = 0; cls && depth < CLOSE_MAX_DEPTH; depth++) {
        size_t i;
        int found = 0;
        for (i = 0; i < a->n_signatures; i++) {
            const ObjcSignature *s = &a->signatures[i];
            if (strcmp(s->owner, cls) || strcmp(s->method_kind, kind) || strcmp(s->selector, sel) ||
                (strcmp(s->record, "method") && strcmp(s->record, "property-get"))) continue;
            if (found && (strcmp(*rk, s->result_kind) || (!*rc) != (!s->result_class) ||
                          (*rc && strcmp(*rc, s->result_class)))) return -1;
            *rk = s->result_kind; *rc = s->result_class; *owner = s->owner; found = 1;
        }
        if (found) return 1;
        cls = super_of(a, cls, &known);
    }
    return 0;
}

static const char *implied_selector(const char *callee) {
    if (!strcmp(callee, "objc_alloc") || !strcmp(callee, "objc_allocWithZone")) return "alloc";
    if (!strcmp(callee, "objc_opt_new")) return "new";
    if (!strcmp(callee, "objc_opt_class")) return "class";
    if (!strcmp(callee, "objc_opt_self")) return "self";
    if (!strcmp(callee, "objc_opt_isKindOfClass")) return "isKindOfClass:";
    if (!strcmp(callee, "objc_opt_respondsToSelector")) return "respondsToSelector:";
    return NULL;
}

static void close_one(ObjcAnalysis *a, Closure *c, size_t idx, int depth);

/* What dispatch record j (at site) returns, typed (step 1 for a result operand): reason set when not. */
static void result_of(ObjcAnalysis *a, Closure *c, size_t j, uint64_t site, Closure *out, int depth) {
    const ObjcEvidence *d = &a->evidence[j];
    Closure *p;
    const char *rk = NULL, *rc = NULL, *owner = NULL;
    int got;
    close_one(a, c, j, depth + 1);
    p = &c[j];
    if (p->state != 2 || p->reason[0]) {
        snprintf(out->reason, sizeof out->reason, "result of open send 0x%llx", (unsigned long long)site);
        out->recv_from = OBJC_RECV_RESULT; out->recv_send = j;
        return;
    }
    if (!strcmp(d->name, "objc_alloc") || !strcmp(d->name, "objc_allocWithZone")) {
        if (strcmp(p->kind, "+")) { snprintf(out->reason, sizeof out->reason, "allocation from a non-class receiver"); return; }
        snprintf(out->receiver, sizeof out->receiver, "%s", p->receiver);
        strcpy(out->kind, "-");
        out->allocated = 1; out->exact = 1;
        snprintf(out->basis, sizeof out->basis, "allocated %s (0x%llx)", p->receiver, (unsigned long long)site);
        return;
    }
    if (!a->n_signatures) {
        snprintf(out->reason, sizeof out->reason, "result of %s[%s %s]: no signature facts loaded", p->kind, p->receiver, p->selector);
        return;
    }
    got = declared_result(a, p->receiver, p->kind, p->selector, &rk, &rc, &owner);
    if (got <= 0) {
        snprintf(out->reason, sizeof out->reason, "result of %s[%s %s]: %s", p->kind, p->receiver, p->selector,
                 got < 0 ? "conflicting declarations" : "no declared signature");
        return;
    }
    if (!strcmp(rk, "class") || !strcmp(rk, "instancetype")) {
        snprintf(out->receiver, sizeof out->receiver, "%s", !strcmp(rk, "class") ? rc : p->receiver);
        strcpy(out->kind, "-");
        snprintf(out->basis, sizeof out->basis, "result of %s[%s %s] (0x%llx) declared %s by %s", p->kind, p->receiver,
                 p->selector, (unsigned long long)site, !strcmp(rk, "class") ? rc : "instancetype", owner);
        return;
    }
    snprintf(out->reason, sizeof out->reason, "result of %s[%s %s] (0x%llx) is declared %s by %s", p->kind, p->receiver,
             p->selector, (unsigned long long)site, rk, owner);
}

/* Closes the receiver operand of dispatch `e` through the measured value (step 1). */
static void measured_receiver(ObjcAnalysis *a, Closure *c, const ObjcEvidence *e, Closure *out, int depth) {
    const ObjcValue *v = &e->receiver;
    switch (v->form) {
    case OBJC_VAL_CLASS_CACHE: case OBJC_VAL_CLASSREF: case OBJC_VAL_CLASS_LITERAL:
        if (!v->text) { snprintf(out->reason, sizeof out->reason, "class operand without a name"); return; }
        snprintf(out->receiver, sizeof out->receiver, "%s", v->text);
        strcpy(out->kind, "+");
        out->exact = 1;
        snprintf(out->basis, sizeof out->basis, "%s %s",
                 v->form == OBJC_VAL_CLASS_CACHE ? "class-cache" : v->form == OBJC_VAL_CLASSREF ? "classref" : "class-lookup",
                 v->text);
        return;
    case OBJC_VAL_RESULT: {
        /* A call read once per incoming path (macho-reader.c) returns what the path that ran
         * returned: its result closes only when every path's does, to the same class and kind. */
        size_t j, npath = 0;
        Closure first;
        if (!dispatch_at(a, e->slice, v->ref, &j)) { snprintf(out->reason, sizeof out->reason, "result of 0x%llx, not a dispatch", (unsigned long long)v->ref); return; }
        if (depth >= CLOSE_MAX_DEPTH) { snprintf(out->reason, sizeof out->reason, "result chain too deep"); return; }
        memset(&first, 0, sizeof first);
        for (j = 0; j < a->n_evidence; j++) {
            const ObjcEvidence *d = &a->evidence[j];
            Closure r;
            if (d->kind != OBJC_EV_DISPATCH_CALL || d->address != v->ref || strcmp(d->slice, e->slice)) continue;
            memset(&r, 0, sizeof r);
            result_of(a, c, j, v->ref, &r, depth);
            if (r.reason[0]) {
                if (d->incoming) snprintf(out->reason, sizeof out->reason, "result of merged send 0x%llx: on its path from 0x%llx, %s",
                                          (unsigned long long)v->ref, (unsigned long long)d->incoming, r.reason);
                else { memcpy(out->reason, r.reason, sizeof out->reason); out->recv_from = r.recv_from; out->recv_send = r.recv_send; }
                return;
            }
            if (npath++ && (strcmp(first.receiver, r.receiver) || strcmp(first.kind, r.kind) || first.allocated != r.allocated ||
                            first.exact != r.exact)) {
                snprintf(out->reason, sizeof out->reason, "result of merged send 0x%llx: its paths give %s%s and %s%s",
                         (unsigned long long)v->ref, first.kind, first.receiver, r.kind, r.receiver);
                return;
            }
            if (npath == 1) first = r;
            else {
                size_t at = strlen(first.basis);
                snprintf(first.basis + at, sizeof first.basis - at, "; %s", r.basis);
            }
        }
        memcpy(out->receiver, first.receiver, sizeof out->receiver);
        memcpy(out->kind, first.kind, sizeof out->kind);
        out->allocated = first.allocated; out->exact = first.exact;
        if (npath > 1) snprintf(out->basis, sizeof out->basis, "every incoming path of merged send 0x%llx: %s", (unsigned long long)v->ref, first.basis);
        else memcpy(out->basis, first.basis, sizeof out->basis);
        return;
    }
    case OBJC_VAL_ARGUMENT:
        snprintf(out->reason, sizeof out->reason, "receiver is incoming argument %llu of %s",
                 (unsigned long long)v->ref, e->function ? e->function : "an unnamed function");
        out->recv_from = OBJC_RECV_ARGUMENT;
        return;
    default:
        snprintf(out->reason, sizeof out->reason, "receiver value not modelled (a field, merge or computed value)");
        out->recv_from = OBJC_RECV_UNMODELLED;
        return;
    }
}

static void close_one(ObjcAnalysis *a, Closure *c, size_t idx, int depth) {
    const ObjcEvidence *e = &a->evidence[idx];
    Closure *out = &c[idx], m;
    const ObjcBinding *b = NULL;
    const char *implied = implied_selector(e->name);
    if (out->state == 2) return;
    if (out->state == 1) { snprintf(out->reason, sizeof out->reason, "cyclic result chain"); out->state = 2; return; }
    out->state = 1;
    out->receiver[0] = out->kind[0] = out->basis[0] = out->reason[0] = 0;
    out->origin = OBJC_ORIGIN_OPEN; out->allocated = out->exact = 0; out->provenance = NULL;
    out->recv_from = OBJC_RECV_OTHER; out->recv_send = 0;
    if (implied) out->selector = implied;
    else if ((e->sel.form == OBJC_VAL_SEL_CACHE || e->sel.form == OBJC_VAL_SELREF || e->sel.form == OBJC_VAL_SEL_LITERAL) && e->sel.text)
        out->selector = e->sel.text;
    else out->selector = NULL;
    if (!out->selector) {
        snprintf(out->reason, sizeof out->reason, strncmp(e->name, "objc_msgSend", 12) ?
                 "unmodelled dispatch entry point" : "selector operand not recovered");
        out->state = 2;
        return;
    }
    if (strstr(e->name, "Super")) {
        snprintf(out->reason, sizeof out->reason, "super send: the enclosing method's class is not modelled");
        out->state = 2;
        return;
    }
    memset(&m, 0, sizeof m);
    measured_receiver(a, c, e, &m, depth);
    if (e->sel.form == OBJC_VAL_SEL_CACHE) b = cache_binding(a, e->slice, e->sel.ref);
    if (!m.reason[0]) {
        if (b && b->receiver) {
            if (strcmp(b->method_kind, m.kind) || !descends(a, m.receiver, b->receiver)) {
                objc_fail(a, "receiver-receipt-conflict", e->slice, e->address, "measured %s%s, receipt %s%s (%s)",
                          m.kind, m.receiver, b->method_kind, b->receiver, b->provenance ? b->provenance : "-");
                snprintf(out->reason, sizeof out->reason, "measured %s%s contradicts receipt %s%s", m.kind, m.receiver,
                         b->method_kind, b->receiver);
                out->state = 2;
                return;
            }
        }
        memcpy(out->receiver, m.receiver, sizeof out->receiver);
        memcpy(out->kind, m.kind, sizeof out->kind);
        memcpy(out->basis, m.basis, sizeof out->basis);
        out->origin = OBJC_ORIGIN_MEASURED; out->allocated = m.allocated; out->exact = m.exact;
    } else if (b && b->receiver) {
        snprintf(out->receiver, sizeof out->receiver, "%s", b->receiver);
        snprintf(out->kind, sizeof out->kind, "%s", b->method_kind);
        snprintf(out->basis, sizeof out->basis, "receipt %s (%s); measured: %s", b->demangled,
                 b->provenance ? b->provenance : "-", m.reason);
        out->origin = OBJC_ORIGIN_RECEIPT; out->provenance = b->provenance;
    } else {
        memcpy(out->reason, m.reason, sizeof out->reason);
        out->recv_from = m.recv_from; out->recv_send = m.recv_send;
    }
    out->state = 2;
}

int objc_close_sends(ObjcAnalysis *a) {
    Closure *c;
    size_t i;
    int status = OBJC_OK;
    if (!(c = calloc(a->n_evidence ? a->n_evidence : 1, sizeof *c))) return objc_fail(a, "out-of-memory", NULL, 0, "closure");
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        ObjcSend s;
        if (e->kind != OBJC_EV_DISPATCH_CALL) continue;
        close_one(a, c, i, 0);
        memset(&s, 0, sizeof s);
        s.evidence = i;
        s.selector = (char *)c[i].selector;
        if (c[i].reason[0]) {
            s.reason = c[i].reason;
            s.basis = NULL;
            s.recv_from = c[i].recv_from; s.recv_send = c[i].recv_send;
            if (!a->findings_mode) status = objc_fail(a, c[i].selector ? "unresolved-receiver" : "unresolved-selector", e->slice, e->address,
                               "%s %s: %s", e->function ? e->function : "-", c[i].selector ? c[i].selector : "-", c[i].reason);
        } else {
            s.receiver = c[i].receiver; s.method_kind = c[i].kind; s.basis = c[i].basis;
            s.origin = c[i].origin; s.allocated = c[i].allocated; s.exact = c[i].exact;
            s.provenance = (char *)c[i].provenance;
        }
        if (objc_add_send(a, &s)) status = OBJC_CANNOT_MEASURE;
    }
    free(c);
    for (i = 0; i < a->n_errors; i++)
        if (!strcmp(a->errors[i].code, "receiver-receipt-conflict")) status = OBJC_CANNOT_MEASURE;
    return status;
}
