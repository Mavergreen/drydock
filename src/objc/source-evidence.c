/* source-evidence.c -- check reviewed build evidence against the artifact it claims to describe.
 *
 * Build evidence, schema 1, is parsed by the front end (main.m); this module decides what of it
 * may close a send. Nothing here reads source files: the evidence records the prepared source's
 * revision, patch digest and features, and each row cites file:line plus the SHA-256 of that
 * file, so a reviewer (or a test with the prepared tree) can recompute every citation. What this
 * module checks is the binding between those rows and the artifact's bytes:
 *
 *   - The evidence names the artifact's SHA-256; any other artifact is cannot-measure
 *     (stale-build-evidence), never a partial reuse.
 *   - R2, Rust monomorphized type evidence (design revision R2 in the plan). A row names a
 *     function by its exact v0 symbol, the Rust type that the row says those sends go to, its
 *     position (the impl self type, or a generic argument within it), the selectors, the method
 *     kind and a source citation. It closes an open send only when the send's function symbol
 *     is the row's (an LLVM ".suffix" ignored), the selector is listed, the Rust type occurs as a
 *     whole path in that symbol's impl self type, and the type map -- objc2's declared
 *     extern_class! mapping, each entry cited -- maps the type to an Objective-C class. Every
 *     crate root in the artifact's cache statics and dispatching functions whose name the evidence pins must carry
 *     the pinned disambiguator: rustc derives it from the crate's version and source, so a
 *     different objc2 revision is cannot-measure (crate-revision-mismatch). An unparsable
 *     symbol, a type the map does not name, or a mapped type whose crate is not pinned is
 *     cannot-measure. A stripped artifact has no function symbol to match: its sends stay open.
 *   - R3, positional type evidence (design ../../.superpowers/specs/2026-11-07-objc-r3-positional-evidence-design.md
 *     in the shipyard source tree's history). A row names a function by its exact v0 symbol (an LLVM
 *     ".suffix" ignored), its selectors and kind, a floor class, and where the receiver comes from:
 *     `result` (a send of a named selector in this function returned it), `downcast` (a checked
 *     downcast to a Rust type the type map maps to that class) or `field` (an object field of a
 *     value whose Rust type occurs in the symbol's impl self type or its generic arguments), with a
 *     source citation. Every non-toolchain crate root the symbol names must be pinned and agree
 *     (core, alloc and std have no registry checksum: the toolchain identity binds them). It acts
 *     after receipts, R2, source receipts and downcast: on an open send it closes the send unless
 *     the reader's model of the receiver contradicts the position -- for `result`, a receiver the
 *     reader knows is another selector's result, an argument or anything else it models; one it does
 *     not model passes on the citation and the basis says "position not checked"; a downcast or
 *     field position is never compared with the binary and says so too. All of a send's rows are
 *     judged together: two that differ in class or kind are contradicted, whatever their order. On a
 *     send another rule already closed the rows are used when that closure names their class or a
 *     subclass, with the same kind, and contradicted otherwise. An unknown form, a missing field, an unknown class, an
 *     unpinned crate or a contradiction is cannot-measure; a row no send matches is reported unused.
 *   - Guard records. A record names the function and the guarded selector, the guard selector,
 *     the fallback, the source citation and the source identity it was reviewed under, and a
 *     review (status, reviewer, reason). A record reviewed under another revision, patch set or
 *     feature list than the evidence's own is cannot-measure (guard-evidence-stale). Whether a
 *     record makes a send guarded is classify.c's decision: it also needs the measured guard.
 *   - Source receipts (--source-receipt; tools/objc-source-inventory.c writes them with libclang,
 *     this module only reads them). They apply to an Objective-C provider's own code and nothing
 *     else: a send closes from a receipt only when it lies in an atom provider.c verified byte for
 *     byte against the provider's archive. The mapping is the archive member's own DWARF line table
 *     (__DWARF,__debug_line, DWARF 2-5, each DW_LNE_set_address checked against its relocation),
 *     carried to final addresses through the build evidence's verified atom placement: the call
 *     instruction's row names a file, line and (when the compiler records one) column. The file
 *     must be exactly one receipt input; the candidates are the receipt's send rows of that file
 *     and selector whose extent covers the position, or one of whose enclosing statements starts
 *     there (a compiler that attributes a statement's code to its first line, as Apple clang 6
 *     does, lands on one of those). The receipt must describe the declared prepared source: every
 *     input's label and SHA-256 in the declaration's source_inputs_receipt, and its SDK the one
 *     the archive was built against; otherwise cannot-measure (source-receipt-stale). Its `tool`
 *     line must be the SHA-256 of this analyzer's own tools/objc-source-inventory.c, which
 *     scripts/objc-compat-build.sh compiles in: a receipt from an edited or other copy of the tool
 *     is cannot-measure (source-receipt-tool-mismatch). Each send
 *     in verified provider code needs a line row and at least one candidate, or the artifact is
 *     cannot-measure (no-line-table, unmapped-source-send): an unknown compiler pattern or changed
 *     source never silently leaves the inventory. Two sends the receipt cannot speak for stay open
 *     instead, each an unresolved, blocking finding that says why, and other evidence (R1) may still
 *     close them: one whose selector the binary does not give (two sends a compiler merged into one
 *     call, a selector chosen at run time), and one the line table puts at line 0 (merged code).
 *     Neither can be matched to a receipt row, and neither hides anything: the send is reported. A send the artifact already closed must agree
 *     with a candidate's method kind (source-binary-disagreement). An open send closes, to the
 *     class of its static type (or a subclass), only when every candidate names the same class and
 *     kind; a static type of id, Class, id<P>, super or a type parameter, or candidates that
 *     disagree, leave it open and say so. A receipt never closes the consumer's own sends.
 */
#include "report.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>

#define TYPES_MAX 16384

/* `symbol` without an LLVM/linker suffix (".llvm.N", ".0"), copied into buf. */
static void base_symbol(const char *symbol, char *buf, size_t bufsz) {
    size_t n = strcspn(symbol, ".$");
    if (n >= bufsz) n = bufsz - 1;
    memcpy(buf, symbol, n); buf[n] = 0;
}

/* Whether `type` occurs in `text` as a whole path: not preceded or followed by an identifier
 * byte or a path separator. */
static int has_type(const char *text, const char *type) {
    size_t k = strlen(type);
    const char *p = text;
    if (!k) return 0;
    while ((p = strstr(p, type))) {
        char before = p == text ? ' ' : p[-1], after = p[k];
        int idb = (before >= 'a' && before <= 'z') || (before >= 'A' && before <= 'Z') ||
                  (before >= '0' && before <= '9') || before == '_' || before == ':';
        int ida = (after >= 'a' && after <= 'z') || (after >= 'A' && after <= 'Z') ||
                  (after >= '0' && after <= '9') || after == '_' || after == ':';
        if (!idb && !ida) return 1;
        p++;
    }
    return 0;
}

static const ObjcTypeMap *type_map(const ObjcAnalysis *a, const char *rust_type) {
    size_t i;
    for (i = 0; i < a->n_typemap; i++) if (!strcmp(a->typemap[i].rust_type, rust_type)) return &a->typemap[i];
    return NULL;
}

static const ObjcCrate *pinned(const ObjcAnalysis *a, const char *name) {
    size_t i;
    for (i = 0; i < a->n_crates; i++) if (!strcmp(a->crates[i].name, name)) return &a->crates[i];
    return NULL;
}

/* Each "name=dis" crate root in a symbol must agree with the pinned crate of that name. */
static int crates_agree(ObjcAnalysis *a, const char *cbuf, const char *where) {
    const char *c;
    for (c = cbuf; *c; c += strlen(c) + 1) {
        char name[256];
        const char *eq = strchr(c, '=');
        const ObjcCrate *p;
        size_t n = eq ? (size_t)(eq - c) : 0;
        if (!eq || n >= sizeof name) continue;
        memcpy(name, c, n); name[n] = 0;
        if ((p = pinned(a, name)) && strcmp(p->disambiguator, eq + 1))
            return objc_fail(a, "crate-revision-mismatch", NULL, 0, "%s: crate %s has disambiguator %s, the build evidence pins %s %s (%s)",
                             where, name, eq + 1, p->version, p->disambiguator, p->checksum);
    }
    return OBJC_OK;
}

static int nonempty(const char *s) { return s && *s; }

int objc_check_build_evidence(ObjcAnalysis *a) {
    size_t i;
    int status = OBJC_OK;
    char *types = NULL, *crates = NULL, why[200];
    if (!a->have_build_evidence) return OBJC_OK;
    if (!a->artifact_sha256 || !a->be_artifact_sha256 || strcmp(a->artifact_sha256, a->be_artifact_sha256))
        return objc_fail(a, "stale-build-evidence", NULL, 0, "build evidence is for artifact %s, this one is %s",
                         a->be_artifact_sha256 ? a->be_artifact_sha256 : "(none)", a->artifact_sha256 ? a->artifact_sha256 : "(unhashed)");
    if (!(types = malloc(TYPES_MAX)) || !(crates = malloc(TYPES_MAX))) {
        free(types); free(crates);
        return objc_fail(a, "out-of-memory", NULL, 0, "type evidence");
    }
    for (i = 0; i < a->n_crates; i++)
        if (!nonempty(a->crates[i].name) || !nonempty(a->crates[i].version) || !nonempty(a->crates[i].checksum) ||
            !nonempty(a->crates[i].disambiguator))
            status = objc_fail(a, "malformed-build-evidence", NULL, 0, "crate %zu lacks name, version, checksum or disambiguator", i + 1);
    for (i = 0; i < a->n_typemap; i++) {
        const ObjcTypeMap *m = &a->typemap[i];
        char crate[256];
        size_t n = m->rust_type ? strcspn(m->rust_type, ":") : 0;
        if (!nonempty(m->rust_type) || !nonempty(m->cls) || !nonempty(m->source) || n >= sizeof crate) {
            status = objc_fail(a, "malformed-build-evidence", NULL, 0, "type map entry %zu incomplete", i + 1);
            continue;
        }
        memcpy(crate, m->rust_type, n); crate[n] = 0;
        if (!pinned(a, crate))
            status = objc_fail(a, "unpinned-type-map", NULL, 0, "%s maps through crate %s, which the evidence does not pin", m->rust_type, crate);
    }
    /* The crate roots of every Rust symbol the reader attributed a record to -- cache statics
     * and the functions containing dispatch sites -- against the pins. */
    for (i = 0; i < a->n_evidence && status == OBJC_OK; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        const char *sym[2];
        int s;
        sym[0] = e->kind == OBJC_EV_DISPATCH_CALL ? e->function : NULL;
        sym[1] = e->kind == OBJC_EV_SEL_CACHE || e->kind == OBJC_EV_CLASS_CACHE ? e->symbol : NULL;
        for (s = 0; s < 2 && status == OBJC_OK; s++) {
            if (!sym[s] || strncmp(sym[s], "__R", 3)) continue;
            if (objc_binding_symbol_types(sym[s], types, TYPES_MAX, crates, TYPES_MAX, why, sizeof why)) continue;
            status = crates_agree(a, crates, sym[s]);
        }
    }
    for (i = 0; i < a->n_types && status == OBJC_OK; i++) {
        ObjcTypeEvidence *t = &a->types[i];
        const ObjcTypeMap *m;
        size_t j;
        if (!nonempty(t->id) || !nonempty(t->symbol) || !nonempty(t->rust_type) || !nonempty(t->source) ||
            !t->nselectors || !t->kind || (strcmp(t->kind, "+") && strcmp(t->kind, "-")) || !t->position ||
            (strcmp(t->position, "self") && strcmp(t->position, "generic"))) {
            status = objc_fail(a, "malformed-build-evidence", NULL, 0, "type evidence %zu incomplete", i + 1);
            break;
        }
        for (j = 0; j < t->nselectors; j++)
            if (!nonempty(t->selectors[j])) status = objc_fail(a, "malformed-build-evidence", NULL, 0, "%s: empty selector", t->id);
        if (strncmp(t->symbol, "__R", 3) && strncmp(t->symbol, "_R", 2)) {
            status = objc_fail(a, "unsupported-type-evidence", NULL, 0, "%s: %s is not a Rust v0 symbol", t->id, t->symbol);
            break;
        }
        if (objc_binding_symbol_types(t->symbol, types, TYPES_MAX, crates, TYPES_MAX, why, sizeof why)) {
            status = objc_fail(a, "unsupported-type-evidence", NULL, 0, "%s: %s", t->id, why);
            break;
        }
        if (!(m = type_map(a, t->rust_type))) {
            status = objc_fail(a, "unmapped-rust-type", NULL, 0, "%s: %s has no declared Objective-C class in the type map", t->id, t->rust_type);
            break;
        }
        if (!types[0] || !has_type(types, t->rust_type)) {
            status = objc_fail(a, "type-evidence-not-in-symbol", NULL, 0, "%s: %s is not in the impl self type of %s", t->id, t->rust_type, t->symbol);
            break;
        }
        status = crates_agree(a, crates, t->id);
    }
    /* R3 rows: complete, a known form, a floor class, every non-toolchain crate root pinned and agreeing. */
    for (i = 0; i < a->n_positions && status == OBJC_OK; i++) {
        ObjcPositionEvidence *t = &a->positions[i];
        const char *c;
        size_t j;
        int result, downcast, field;
        if (!nonempty(t->id) || !nonempty(t->symbol) || !nonempty(t->cls) || !nonempty(t->source) || !t->nselectors ||
            !t->kind || (strcmp(t->kind, "+") && strcmp(t->kind, "-")) || !nonempty(t->form)) {
            status = objc_fail(a, "malformed-build-evidence", NULL, 0, "position evidence %zu incomplete", i + 1);
            break;
        }
        result = !strcmp(t->form, "result"); downcast = !strcmp(t->form, "downcast"); field = !strcmp(t->form, "field");
        if ((!result && !downcast && !field) || (result && !nonempty(t->position_selector)) ||
            ((downcast || field) && !nonempty(t->rust_type)) || (field && !nonempty(t->field))) {
            status = objc_fail(a, "malformed-build-evidence", NULL, 0, "%s: position form %s or its fields", t->id, t->form);
            break;
        }
        for (j = 0; j < t->nselectors; j++)
            if (!nonempty(t->selectors[j])) status = objc_fail(a, "malformed-build-evidence", NULL, 0, "%s: empty selector", t->id);
        if (status) break;
        if (!objc_map_get(a->rt_class, t->cls)) {
            status = objc_fail(a, "unknown-class", NULL, 0, "%s: %s is not a class of the floor capture", t->id, t->cls);
            break;
        }
        if (strncmp(t->symbol, "__R", 3) && strncmp(t->symbol, "_R", 2)) {
            status = objc_fail(a, "unsupported-type-evidence", NULL, 0, "%s: %s is not a Rust v0 symbol", t->id, t->symbol);
            break;
        }
        if (objc_binding_symbol_types(t->symbol, types, TYPES_MAX, crates, TYPES_MAX, why, sizeof why)) {
            status = objc_fail(a, "unsupported-type-evidence", NULL, 0, "%s: %s", t->id, why);
            break;
        }
        for (c = crates; *c && status == OBJC_OK; c += strlen(c) + 1) {
            char name[256];
            const char *eq = strchr(c, '=');
            size_t n = eq ? (size_t)(eq - c) : 0;
            if (!eq || n >= sizeof name) continue;
            memcpy(name, c, n); name[n] = 0;
            /* the toolchain's crates have no registry checksum; the toolchain identity binds them */
            if (strcmp(name, "core") && strcmp(name, "alloc") && strcmp(name, "std") && !pinned(a, name))
                status = objc_fail(a, "unpinned-crate", NULL, 0, "%s: %s names crate %s, which the evidence does not pin", t->id, t->symbol, name);
        }
        if (status == OBJC_OK) status = crates_agree(a, crates, t->id);
        if (status) break;
        if (downcast) {
            const ObjcTypeMap *m = type_map(a, t->rust_type);
            if (!m) status = objc_fail(a, "unmapped-rust-type", NULL, 0, "%s: %s has no declared Objective-C class in the type map", t->id, t->rust_type);
            else if (strcmp(m->cls, t->cls))
                status = objc_fail(a, "position-contradicted", NULL, 0, "%s: a downcast to %s yields %s, not %s", t->id, t->rust_type, m->cls, t->cls);
        }
        if (field && !has_type(types, t->rust_type))
            status = objc_fail(a, "type-evidence-not-in-symbol", NULL, 0, "%s: %s is not in the impl self type of %s", t->id, t->rust_type, t->symbol);
    }
    for (i = 0; i < a->n_guards && status == OBJC_OK; i++) {
        const ObjcGuardRecord *g = &a->guards[i];
        if (!nonempty(g->id) || !nonempty(g->symbol) || !nonempty(g->selector) || !nonempty(g->guard_selector) ||
            !nonempty(g->fallback) || !nonempty(g->source_file) || !nonempty(g->source_sha256) || !g->source_line ||
            !nonempty(g->review_status)) {
            status = objc_fail(a, "malformed-build-evidence", NULL, 0, "guard record %zu incomplete", i + 1);
            break;
        }
        if (!nonempty(a->be_source_revision) || !g->source_revision || strcmp(g->source_revision, a->be_source_revision) ||
            !g->patches_sha256 || !a->be_patches_sha256 || strcmp(g->patches_sha256, a->be_patches_sha256) ||
            !g->features || !a->be_features || strcmp(g->features, a->be_features))
            status = objc_fail(a, "guard-evidence-stale", NULL, 0, "%s was reviewed under %s/%s/%s; this build is %s/%s/%s", g->id,
                               g->source_revision ? g->source_revision : "-", g->patches_sha256 ? g->patches_sha256 : "-",
                               g->features ? g->features : "-", a->be_source_revision ? a->be_source_revision : "-",
                               a->be_patches_sha256 ? a->be_patches_sha256 : "-", a->be_features ? a->be_features : "-");
    }
    free(types); free(crates);
    return status;
}

int objc_apply_type_evidence(ObjcAnalysis *a) {
    size_t i, j, k;
    char fn[4096], row[4096];
    for (i = 0; i < a->n_sends; i++) {
        ObjcSend *s = &a->sends[i];
        const ObjcEvidence *e = &a->evidence[s->evidence];
        if (s->origin != OBJC_ORIGIN_OPEN || !s->selector || !e->function) continue;
        base_symbol(e->function, fn, sizeof fn);
        for (j = 0; j < a->n_types; j++) {
            ObjcTypeEvidence *t = &a->types[j];
            const ObjcTypeMap *m = type_map(a, t->rust_type);
            char basis[2048], prov[2048];
            base_symbol(t->symbol, row, sizeof row);
            if (strcmp(fn, row) || !m) continue;
            for (k = 0; k < t->nselectors && strcmp(t->selectors[k], s->selector); k++) ;
            if (k == t->nselectors) continue;
            snprintf(basis, sizeof basis, "R2 %s: %s %s of %s, objc2 maps it to %s", t->id, t->position, t->rust_type,
                     e->function, m->cls);
            snprintf(prov, sizeof prov, "%s; %s", t->source, m->source);
            if (objc_set_string(&s->receiver, m->cls) || objc_set_string(&s->method_kind, t->kind) ||
                objc_set_string(&s->basis, basis) || objc_set_string(&s->provenance, prov) ||
                objc_set_string(&s->reason, NULL))
                return objc_fail(a, "out-of-memory", NULL, 0, "R2");
            s->origin = OBJC_ORIGIN_R2; s->exact = 0; s->allocated = 0;
            t->used = 1;
            break;
        }
    }
    return OBJC_OK;
}

/* Whether floor class `cls` is `owner` or descends from it. */
static int is_or_descends(const ObjcAnalysis *a, const char *cls, const char *owner) {
    int depth;
    for (depth = 0; cls && depth < 64; depth++) {
        const char *i;
        if (!strcmp(cls, owner)) return 1;
        if (!(i = objc_map_get(a->rt_class, cls))) return 0;
        cls = a->rt_classes[strtoul(i, NULL, 10)].super;
    }
    return 0;
}

/* R3, after receipts, R2, source receipts and downcast. A row names one function (suffix ignored),
 * its selectors and kind, a class and the receiver's position. On an open send it closes the send
 * when the reader's model of the receiver does not contradict the position: for `result`, a
 * receiver the reader knows is another send's result must be that selector's, and one it knows is
 * an argument or anything else contradicts; one it does not model passes on the citation, and the
 * basis says so; a downcast or field position is never compared and says so too. A send's rows are
 * judged together (two that differ in class or kind are contradicted, whatever their order); on a
 * send another rule closed they are used when it names their class or a subclass, with their kind. */
int objc_apply_position_evidence(ObjcAnalysis *a) {
    size_t i, j, k;
    char fn[4096], row[4096];
    for (i = 0; i < a->n_sends; i++) {
        ObjcSend *s = &a->sends[i];
        const ObjcEvidence *e = &a->evidence[s->evidence];
        ObjcPositionEvidence *t = NULL;   /* the first matching row; every other must agree with it */
        char basis[2048];
        const char *checked = "";
        if (!s->selector || !e->function) continue;
        base_symbol(e->function, fn, sizeof fn);
        /* All of a send's rows together, so their order never decides: any two that differ in class
         * or kind are refused, whichever comes first and even when one class descends from the other. */
        for (j = 0; j < a->n_positions; j++) {
            ObjcPositionEvidence *u = &a->positions[j];
            base_symbol(u->symbol, row, sizeof row);
            if (strcmp(fn, row)) continue;
            for (k = 0; k < u->nselectors && strcmp(u->selectors[k], s->selector); k++) ;
            if (k == u->nselectors) continue;
            if (!t) { t = u; continue; }
            if (strcmp(t->cls, u->cls) || strcmp(t->kind, u->kind))
                return objc_fail(a, "position-contradicted", e->slice, e->address, "%s and %s: %s in %s is %s%s by one and %s%s by the other",
                                 t->id, u->id, s->selector, e->function, t->kind, t->cls, u->kind, u->cls);
        }
        if (!t) continue;
        if (s->origin != OBJC_ORIGIN_OPEN) {
            if (!s->receiver || !s->method_kind || strcmp(s->method_kind, t->kind) || !is_or_descends(a, s->receiver, t->cls))
                return objc_fail(a, "position-contradicted", e->slice, e->address, "%s: %s in %s is already closed to %s%s, not %s%s",
                                 t->id, s->selector, e->function, s->method_kind ? s->method_kind : "?",
                                 s->receiver ? s->receiver : "(nothing)", t->kind, t->cls);
        } else if (!strcmp(t->form, "result")) {
            if (s->recv_from == OBJC_RECV_RESULT) {
                const char *got = s->recv_send < a->n_evidence ? a->evidence[s->recv_send].sel.text : NULL;
                if (!got || strcmp(got, t->position_selector))
                    return objc_fail(a, "position-contradicted", e->slice, e->address, "%s: the receiver of %s in %s is the result of %s, not %s",
                                     t->id, s->selector, e->function, got ? got : "an unknown send", t->position_selector);
                checked = " (position checked)";
            } else if (s->recv_from == OBJC_RECV_UNMODELLED) {
                checked = " (position not checked: the receiver value is not modelled)";
            } else {
                return objc_fail(a, "position-contradicted", e->slice, e->address, "%s: the receiver of %s in %s is %s, not the result of %s",
                                 t->id, s->selector, e->function, s->reason ? s->reason : "something else", t->position_selector);
            }
        } else {
            /* a downcast or field position is never compared with the binary's receiver */
            checked = " (position not checked: a downcast or field position is taken on its citation)";
        }
        for (j = 0; j < a->n_positions; j++) {   /* every agreeing row is used */
            ObjcPositionEvidence *u = &a->positions[j];
            base_symbol(u->symbol, row, sizeof row);
            if (strcmp(fn, row)) continue;
            for (k = 0; k < u->nselectors && strcmp(u->selectors[k], s->selector); k++) ;
            if (k < u->nselectors) u->used = 1;
        }
        if (s->origin != OBJC_ORIGIN_OPEN) continue;
        if (!strcmp(t->form, "result"))
            snprintf(basis, sizeof basis, "R3 %s: the result of %s in %s is %s%s", t->id, t->position_selector, e->function, t->cls, checked);
        else if (!strcmp(t->form, "downcast"))
            snprintf(basis, sizeof basis, "R3 %s: a downcast to %s in %s is %s%s", t->id, t->rust_type, e->function, t->cls, checked);
        else
            snprintf(basis, sizeof basis, "R3 %s: field %s of %s in %s is %s%s", t->id, t->field, t->rust_type, e->function, t->cls, checked);
        if (objc_set_string(&s->receiver, t->cls) || objc_set_string(&s->method_kind, t->kind) ||
            objc_set_string(&s->basis, basis) || objc_set_string(&s->provenance, t->source) ||
            objc_set_string(&s->reason, NULL))
            return objc_fail(a, "out-of-memory", NULL, 0, "R3");
        s->origin = OBJC_ORIGIN_R3; s->exact = 0; s->allocated = 0;
    }
    return OBJC_OK;
}

const ObjcGuardRecord *objc_guard_record(ObjcAnalysis *a, size_t ev) {
    const ObjcEvidence *e = &a->evidence[ev];
    char fn[4096], row[4096];
    size_t i, s;
    const char *sel = NULL;
    for (s = 0; s < a->n_sends; s++) if (a->sends[s].evidence == ev) { sel = a->sends[s].selector; break; }
    if (!e->function || !sel) return NULL;
    base_symbol(e->function, fn, sizeof fn);
    for (i = 0; i < a->n_guards; i++) {
        ObjcGuardRecord *g = &a->guards[i];
        base_symbol(g->symbol, row, sizeof row);
        if (!strcmp(fn, row) && !strcmp(g->selector, sel)) { g->used = 1; return g; }
    }
    return NULL;
}

/* ---- DWARF .debug_line ------------------------------------------------------------------------ */

typedef struct { const uint8_t *p, *end; int bad; } Rd;
static uint64_t rd_n(Rd *r, int n) {
    uint64_t v = 0;
    int i;
    if (r->bad || r->end - r->p < n) { r->bad = 1; return 0; }
    for (i = 0; i < n; i++) v |= (uint64_t)r->p[i] << (8 * i);
    r->p += n;
    return v;
}
static uint64_t rd_uleb(Rd *r) {
    uint64_t v = 0;
    int shift = 0;
    while (!r->bad) {
        uint8_t b;
        if (r->p >= r->end || shift > 63) { r->bad = 1; return 0; }
        b = *r->p++;
        v |= (uint64_t)(b & 0x7f) << shift;
        shift += 7;
        if (!(b & 0x80)) break;
    }
    return v;
}
static int64_t rd_sleb(Rd *r) {
    int64_t v = 0;
    int shift = 0;
    uint8_t b = 0;
    while (!r->bad) {
        if (r->p >= r->end || shift > 63) { r->bad = 1; return 0; }
        b = *r->p++;
        v |= (int64_t)(b & 0x7f) << shift;
        shift += 7;
        if (!(b & 0x80)) break;
    }
    if (shift < 64 && (b & 0x40)) v |= -((int64_t)1 << shift);
    return v;
}
static const char *rd_str(Rd *r) {
    const uint8_t *s = r->p;
    while (!r->bad && r->p < r->end && *r->p) r->p++;
    if (r->bad || r->p >= r->end) { r->bad = 1; return NULL; }
    r->p++;
    return (const char *)s;
}

typedef struct { char **v; size_t n; } Strs;
static int strs_add(Strs *s, char *x) {
    char **g;
    if (!x || !(g = realloc(s->v, (s->n + 1) * sizeof *g))) { free(x); return -1; }
    s->v = g; s->v[s->n++] = x;
    return 0;
}
static void strs_free(Strs *s) { size_t i; for (i = 0; i < s->n; i++) free(s->v[i]); free(s->v); memset(s, 0, sizeof *s); }
static char *dup_join(const char *dir, const char *name) {
    size_t a = dir ? strlen(dir) : 0, b = strlen(name);
    char *r = malloc(a + b + 2);
    if (!r) return NULL;
    if (name[0] == '/' || !a) memcpy(r, name, b + 1);
    else { memcpy(r, dir, a); r[a] = '/'; memcpy(r + a + 1, name, b + 1); }
    return r;
}

/* One DWARF 5 entry-format list: path and directory index only (timestamps, sizes, MD5 skipped). */
static int v5_entries(Rd *r, const uint8_t *ls, size_t lsz, const Strs *dirs, Strs *out, int is_dir, char *why, size_t whysz) {
    uint64_t fmt[16][2], count, i;
    unsigned nfmt = (unsigned)rd_n(r, 1), k;
    if (nfmt > 16) { snprintf(why, whysz, "a DWARF 5 entry format with %u fields", nfmt); return -1; }
    for (k = 0; k < nfmt; k++) { fmt[k][0] = rd_uleb(r); fmt[k][1] = rd_uleb(r); }
    count = rd_uleb(r);
    if (r->bad || count > 100000) { snprintf(why, whysz, "truncated DWARF 5 entry formats"); return -1; }
    for (i = 0; i < count; i++) {
        const char *path = NULL;
        uint64_t dir = 0;
        for (k = 0; k < nfmt; k++) {
            uint64_t ct = fmt[k][0], form = fmt[k][1], v = 0;
            const char *s = NULL;
            switch (form) {
            case 0x08: s = rd_str(r); break;                                  /* DW_FORM_string */
            case 0x1f: v = rd_n(r, 4);                                        /* DW_FORM_line_strp */
                if (!ls || v >= lsz || !memchr(ls + v, 0, lsz - v)) { snprintf(why, whysz, "a line_strp outside __debug_line_str"); return -1; }
                s = (const char *)ls + v; break;
            case 0x0f: v = rd_uleb(r); break;                                 /* DW_FORM_udata */
            case 0x0b: v = rd_n(r, 1); break;
            case 0x05: v = rd_n(r, 2); break;
            case 0x06: v = rd_n(r, 4); break;
            case 0x07: v = rd_n(r, 8); break;
            case 0x1e: rd_n(r, 8); rd_n(r, 8); break;                         /* DW_FORM_data16 (MD5) */
            case 0x09: { uint64_t n = rd_uleb(r); if ((uint64_t)(r->end - r->p) < n) r->bad = 1; else r->p += n; break; }
            default: snprintf(why, whysz, "DWARF 5 form 0x%llx in a file table", (unsigned long long)form); return -1;
            }
            if (ct == 1) path = s;
            else if (ct == 2) dir = v;
        }
        if (r->bad || !path) { snprintf(why, whysz, "a DWARF 5 %s entry without a path", is_dir ? "directory" : "file"); return -1; }
        if (is_dir) { if (strs_add(out, strdup(path))) return -1; }
        else {
            if (dir >= dirs->n) { snprintf(why, whysz, "a file entry naming directory %llu of %zu", (unsigned long long)dir, dirs->n); return -1; }
            if (strs_add(out, dup_join(dirs->v[dir], path))) return -1;
        }
    }
    return 0;
}

static int add_row_(ObjcDwarfRow **rows, size_t *n, size_t *cap, uint64_t addr, const Strs *files, uint64_t file, int v5,
                    uint64_t line, uint64_t col, int end, char *why, size_t whysz) {
    ObjcDwarfRow *g;
    uint64_t fi = v5 ? file : file - 1;
    if ((!v5 && !file) || fi >= files->n) { snprintf(why, whysz, "a row naming file %llu of %zu", (unsigned long long)file, files->n); return -1; }
    if (*n == *cap) {
        if (!(g = realloc(*rows, (*cap = *cap ? *cap * 2 : 256) * sizeof *g))) return -1;
        *rows = g;
    }
    g = &(*rows)[(*n)++];
    g->addr = addr; g->line = (uint32_t)line; g->col = (uint32_t)col; g->end = end;
    if (!(g->file = strdup(files->v[fi]))) { (*n)--; return -1; }
    return 0;
}

int objc_dwarf_lines(const uint8_t *sect, size_t size, const uint8_t *line_str, size_t line_str_size,
                     int (*reloc)(void *ctx, uint64_t off, uint64_t *addr), void *ctx,
                     ObjcDwarfRow **rows, size_t *nrows, char *why, size_t whysz) {
    size_t off = 0, cap = 0;
    *rows = NULL; *nrows = 0;
    while (off < size) {
        Rd r, prog;
        uint64_t len, hlen, version;
        unsigned min_inst, line_range, opcode_base, k;
        int line_base, have_addr = 0;
        uint8_t std_len[256];
        Strs dirs = {0}, files = {0};
        uint64_t addr = 0, file = 1, line = 1, col = 0;
        r.p = sect + off; r.end = sect + size; r.bad = 0;
        len = rd_n(&r, 4);
        if (r.bad || len == 0xffffffff || len > (uint64_t)(r.end - r.p)) { snprintf(why, whysz, "a line program unit at 0x%zx is truncated or 64-bit DWARF", off); goto refuse; }
        r.end = r.p + len;
        off = (size_t)(r.end - sect);
        version = rd_n(&r, 2);
        if (version < 2 || version > 5) { snprintf(why, whysz, "DWARF line table version %llu", (unsigned long long)version); goto refuse; }
        if (version == 5 && (rd_n(&r, 1) != 8 || rd_n(&r, 1) != 0)) { snprintf(why, whysz, "a DWARF 5 line table not for 8-byte addresses"); goto refuse; }
        hlen = rd_n(&r, 4);
        if (r.bad || hlen > (uint64_t)(r.end - r.p)) { snprintf(why, whysz, "a line table header past its unit"); goto refuse; }
        prog = r; prog.p = r.p + hlen;
        min_inst = (unsigned)rd_n(&r, 1);
        if (version >= 4 && rd_n(&r, 1) != 1) { snprintf(why, whysz, "a VLIW line table"); goto refuse; }
        rd_n(&r, 1);   /* default_is_stmt */
        line_base = (int8_t)rd_n(&r, 1);
        line_range = (unsigned)rd_n(&r, 1);
        opcode_base = (unsigned)rd_n(&r, 1);
        if (r.bad || !line_range || !opcode_base) { snprintf(why, whysz, "a malformed line table header"); goto refuse; }
        for (k = 1; k < opcode_base; k++) std_len[k] = (uint8_t)rd_n(&r, 1);
        if (version < 5) {
            const char *s;
            while ((s = rd_str(&r)) && *s) if (strs_add(&dirs, strdup(s))) goto oom;
            while ((s = rd_str(&r)) && *s) {
                uint64_t d = rd_uleb(&r);
                rd_uleb(&r); rd_uleb(&r);
                if (d > dirs.n) { snprintf(why, whysz, "a file entry naming directory %llu", (unsigned long long)d); goto refuse; }
                if (strs_add(&files, dup_join(d ? dirs.v[d - 1] : NULL, s))) goto oom;
            }
            if (r.bad) { snprintf(why, whysz, "a truncated file table"); goto refuse; }
        } else if (v5_entries(&r, line_str, line_str_size, NULL, &dirs, 1, why, whysz) ||
                   v5_entries(&r, line_str, line_str_size, &dirs, &files, 0, why, whysz))
            goto refuse;
        file = version == 5 ? 0 : 1;
        while (prog.p < prog.end && !prog.bad) {
            unsigned op = (unsigned)rd_n(&prog, 1);
            if (op >= opcode_base) {
                unsigned adj = op - opcode_base;
                addr += (uint64_t)(adj / line_range) * min_inst;
                line = (uint64_t)((int64_t)line + line_base + (int)(adj % line_range));
                if (!have_addr) { snprintf(why, whysz, "a row before any DW_LNE_set_address"); goto refuse; }
                if (add_row_(rows, nrows, &cap, addr, &files, file, version == 5, line, col, 0, why, whysz)) goto refuse;
                continue;
            }
            switch (op) {
            case 0: {
                uint64_t n = rd_uleb(&prog);
                const uint8_t *next = prog.p + n;
                unsigned sub;
                if (prog.bad || !n || n > (uint64_t)(prog.end - prog.p)) { snprintf(why, whysz, "a truncated extended opcode"); goto refuse; }
                sub = (unsigned)rd_n(&prog, 1);
                if (sub == 1) {
                    if (!have_addr) { snprintf(why, whysz, "a sequence without DW_LNE_set_address"); goto refuse; }
                    if (add_row_(rows, nrows, &cap, addr, &files, file, version == 5, line, col, 1, why, whysz)) goto refuse;
                    addr = 0; file = version == 5 ? 0 : 1; line = 1; col = 0; have_addr = 0;
                } else if (sub == 2) {
                    uint64_t at = (uint64_t)(prog.p - sect);
                    if (n != 9) { snprintf(why, whysz, "a DW_LNE_set_address not of 8 bytes"); goto refuse; }
                    rd_n(&prog, 8);
                    if (reloc(ctx, at, &addr)) { snprintf(why, whysz, "the DW_LNE_set_address at 0x%llx has no supported relocation", (unsigned long long)at); goto refuse; }
                    have_addr = 1;
                } else if (sub == 3 && version < 5) {
                    const char *s = rd_str(&prog);
                    uint64_t d = rd_uleb(&prog);
                    if (!s || d > dirs.n || strs_add(&files, dup_join(d ? dirs.v[d - 1] : NULL, s))) { snprintf(why, whysz, "a bad DW_LNE_define_file"); goto refuse; }
                }
                prog.p = next;
                break;
            }
            case 1:
                if (!have_addr) { snprintf(why, whysz, "a row before any DW_LNE_set_address"); goto refuse; }
                if (add_row_(rows, nrows, &cap, addr, &files, file, version == 5, line, col, 0, why, whysz)) goto refuse;
                break;
            case 2: addr += rd_uleb(&prog) * min_inst; break;
            case 3: line = (uint64_t)((int64_t)line + rd_sleb(&prog)); break;
            case 4: file = rd_uleb(&prog); break;
            case 5: col = rd_uleb(&prog); break;
            case 8: addr += (uint64_t)((255 - opcode_base) / line_range) * min_inst; break;
            case 9: addr += rd_n(&prog, 2); break;
            case 6: case 7: case 10: case 11: break;
            default:
                for (k = 0; op < opcode_base && k < std_len[op]; k++) rd_uleb(&prog);
                break;
            }
        }
        if (prog.bad) { snprintf(why, whysz, "a truncated line program"); goto refuse; }
        strs_free(&dirs); strs_free(&files);
        continue;
    oom:
        snprintf(why, whysz, "out of memory");
    refuse:
        strs_free(&dirs); strs_free(&files);
        { size_t i; for (i = 0; i < *nrows; i++) free((*rows)[i].file); }
        free(*rows); *rows = NULL; *nrows = 0;
        return -1;
    }
    return 0;
}

/* ---- the source receipt ----------------------------------------------------------------------- */

#define RECEIPT_MAX (16u << 20)
#define RECEIPT_PROFILE "recaulk-objc-x86_64-10.9"
/* scripts/objc-compat-build.sh defines it: the SHA-256 of tools/objc-source-inventory.c in the tree
 * this analyzer was built from, the only tool whose receipts it reads. */
#ifndef OBJC_SOURCE_INVENTORY_SHA256
#error "OBJC_SOURCE_INVENTORY_SHA256 is defined by scripts/objc-compat-build.sh"
#endif

static int hex64s(const char *s) {
    size_t i;
    for (i = 0; i < 64; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return !s[64];
}
static int pos_pair(const char *s, uint32_t *l, uint32_t *c) {
    char *e;
    unsigned long a = strtoul(s, &e, 10), b;
    if (e == s || *e != ':') return -1;
    s = e + 1; b = strtoul(s, &e, 10);
    if (e == s || a > 10000000 || b > 100000) return -1;
    *l = (uint32_t)a; *c = (uint32_t)b;
    return (int)(e - s) + 0;
}

int objc_load_source_receipt(ObjcAnalysis *a, const char *path) {
    FILE *f = fopen(path, "rb");
    char *buf, *line, *save = NULL, h[65];
    size_t size, nl = 0;
    int header = 0, rc = OBJC_OK;
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    int i;
    if (!f) return objc_fail(a, "unreadable-input", NULL, 0, "source receipt %s", path);
    if (!(buf = malloc(RECEIPT_MAX + 1))) { fclose(f); return objc_fail(a, "out-of-memory", NULL, 0, "receipt"); }
    size = fread(buf, 1, RECEIPT_MAX + 1, f);
    if (ferror(f) || size > RECEIPT_MAX) { fclose(f); free(buf); return objc_fail(a, "oversized-input", NULL, 0, "source receipt %s", path); }
    fclose(f);
    buf[size] = 0;
    CC_SHA256(buf, (CC_LONG)size, d);
    for (i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(h + 2 * i, 3, "%02x", d[i]);
    if (objc_set_string(&a->src_path, path) || objc_set_string(&a->src_sha256, h)) { free(buf); return OBJC_CANNOT_MEASURE; }
    if (memchr(buf, 0, size) || !size || buf[size - 1] != '\n') { free(buf); return objc_fail(a, "malformed-source-receipt", NULL, 0, "%s is not newline-terminated text", path); }
    for (line = strtok_r(buf, "\n", &save); line && rc == OBJC_OK; line = strtok_r(NULL, "\n", &save)) {
        char *col[12];
        int n = 0;
        char *p = line;
        nl++;
        while (n < 12) { col[n++] = p; if (!(p = strchr(p, '\t'))) break; *p++ = 0; }
        if (p) { rc = objc_fail(a, "malformed-source-receipt", NULL, 0, "%s:%zu: too many fields", path, nl); break; }
        /* The header, in order. */
        if (header < 6) {
            static const char *KEY[] = { "# objc-source-receipt 1", "profile", "args", "libclang", "sdk", "tool" };
            int ok = header == 0 ? n == 1 && !strcmp(col[0], KEY[0]) : n == 2 && !strcmp(col[0], KEY[header]);
            if (ok && header == 1) ok = !strcmp(col[1], RECEIPT_PROFILE);
            if (ok && (header == 4 || header == 5)) ok = hex64s(col[1]);
            if (ok && header == 3) ok = objc_set_string(&a->src_libclang, col[1]) == 0;
            if (ok && header == 4) ok = objc_set_string(&a->src_sdk, col[1]) == 0;
            if (!ok) { rc = objc_fail(a, "malformed-source-receipt", NULL, 0, "%s:%zu: not the schema-1 %s profile header", path, nl, RECEIPT_PROFILE); break; }
            if (header == 5 && strcmp(col[1], OBJC_SOURCE_INVENTORY_SHA256)) {
                rc = objc_fail(a, "source-receipt-tool-mismatch", NULL, 0, "the source receipt was written by inventory tool source %.16s..., not this analyzer's tools/objc-source-inventory.c (%.16s...)",
                               col[1], OBJC_SOURCE_INVENTORY_SHA256);
                break;
            }
            header++;
            continue;
        }
        if (!strcmp(col[0], "input") && n == 3 && hex64s(col[2])) {
            ObjcSourceInput *g = realloc(a->src_inputs, (a->n_src_inputs + 1) * sizeof *g);
            if (!g) { rc = objc_fail(a, "out-of-memory", NULL, 0, "receipt"); break; }
            a->src_inputs = g; g = &g[a->n_src_inputs++]; memset(g, 0, sizeof *g);
            if (objc_set_string(&g->label, col[1]) || objc_set_string(&g->sha256, col[2])) rc = OBJC_CANNOT_MEASURE;
        } else if (!strcmp(col[0], "unit") && n == 2) {
            continue;
        } else if (!strcmp(col[0], "send") && n == 10) {
            ObjcSourceRow *g = realloc(a->src_rows, (a->n_src_rows + 1) * sizeof *g), *r;
            char *q, *anc;
            uint32_t l, c;
            int k;
            if (!g) { rc = objc_fail(a, "out-of-memory", NULL, 0, "receipt"); break; }
            a->src_rows = g; r = &g[a->n_src_rows++]; memset(r, 0, sizeof *r);
            if ((k = pos_pair(col[2], &r->sl, &r->sc)) < 0 || col[2][strcspn(col[2], "-")] != '-' ||
                pos_pair(strchr(col[2], '-') + 1, &r->el, &r->ec) < 0 ||
                (strcmp(col[5], "+") && strcmp(col[5], "-")) || !*col[6] || !*col[7]) {
                rc = objc_fail(a, "malformed-source-receipt", NULL, 0, "%s:%zu: a malformed send row", path, nl); break;
            }
            if (objc_set_string(&r->file, col[1]) || objc_set_string(&r->form, col[4]) || objc_set_string(&r->kind, col[5]) ||
                objc_set_string(&r->selector, col[6]) || objc_set_string(&r->receiver, col[7]) || objc_set_string(&r->type, col[8]) ||
                objc_set_string(&r->owner, col[9])) { rc = OBJC_CANNOT_MEASURE; break; }
            for (anc = col[3]; strcmp(anc, "-") && anc && *anc; anc = q ? q + 1 : NULL) {
                uint32_t *ga;
                q = strchr(anc, ',');
                if (pos_pair(anc, &l, &c) < 0 || !(ga = realloc(r->anchors, (r->nanchors + 1) * 2 * sizeof *ga))) {
                    rc = objc_fail(a, "malformed-source-receipt", NULL, 0, "%s:%zu: malformed anchors", path, nl); break;
                }
                r->anchors = ga; ga[2 * r->nanchors] = l; ga[2 * r->nanchors + 1] = c; r->nanchors++;
                if (!q) break;
            }
        } else rc = objc_fail(a, "malformed-source-receipt", NULL, 0, "%s:%zu: an unknown row", path, nl);
    }
    free(buf);
    if (rc == OBJC_OK && header < 6) rc = objc_fail(a, "malformed-source-receipt", NULL, 0, "%s: no complete header", path);
    if (rc == OBJC_OK && !a->n_src_inputs) rc = objc_fail(a, "malformed-source-receipt", NULL, 0, "%s: no inputs", path);
    return rc;
}

/* The receipt input a line table's file names: the one label that is the path or its tail after
 * a '/'; NULL for none or several. */
static const ObjcSourceInput *input_named(const ObjcAnalysis *a, const char *file) {
    const ObjcSourceInput *hit = NULL;
    size_t i, n = strlen(file);
    for (i = 0; i < a->n_src_inputs; i++) {
        const char *l = a->src_inputs[i].label;
        size_t k = strlen(l);
        if (k > n || strcmp(file + n - k, l) || (k < n && file[n - k - 1] != '/')) continue;
        if (hit) return NULL;
        hit = &a->src_inputs[i];
    }
    return hit;
}

/* Whether the declaration's source_inputs_receipt lists LABEL with SHA. */
static int declared(const char *receipt, const char *label, const char *sha) {
    const char *p = receipt;
    size_t k = strlen(label);
    while (p && *p) {
        const char *e = strchr(p, '\n');
        size_t n = e ? (size_t)(e - p) : strlen(p);
        if (n == 66 + k && !strncmp(p, sha, 64) && p[64] == ' ' && p[65] == ' ' && !strncmp(p + 66, label, k)) return 1;
        p = e ? e + 1 : NULL;
    }
    return 0;
}

static int covers(const ObjcSourceRow *r, uint32_t line, uint32_t col) {
    size_t i;
    if (!col) {
        if (line >= r->sl && line <= r->el) return 1;
        for (i = 0; i < r->nanchors; i++) if (r->anchors[2 * i] == line) return 1;
        return 0;
    }
    if ((line > r->sl || (line == r->sl && col >= r->sc)) && (line < r->el || (line == r->el && col <= r->ec))) return 1;
    for (i = 0; i < r->nanchors; i++) if (r->anchors[2 * i] == line && r->anchors[2 * i + 1] == col) return 1;
    return 0;
}

static const ObjcLine *line_at(const ObjcProvider *p, uint64_t va) {
    size_t lo = 0, hi = p->n_lines;
    const ObjcLine *best = NULL;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (p->lines[mid].addr <= va) { best = &p->lines[mid]; lo = mid + 1; } else hi = mid;
    }
    return best && va >= best->lo && va < best->hi ? best : NULL;
}

int objc_apply_source_receipt(ObjcAnalysis *a) {
    size_t i, j, k;
    int status = OBJC_OK;
    if (!a->src_sha256) return OBJC_OK;
    /* The receipt must describe exactly the prepared source each provider declares. */
    for (j = 0; j < a->n_providers; j++) {
        const ObjcProvider *p = &a->providers[j];
        if (!p->n_ranges) continue;
        if (!p->sdk_settings_sha256 || strcmp(p->sdk_settings_sha256, a->src_sdk))
            return objc_fail(a, "source-receipt-stale", NULL, 0, "%s was built against SDK %s; the receipt parsed SDK %s", p->provider_id,
                             p->sdk_settings_sha256 ? p->sdk_settings_sha256 : "-", a->src_sdk);
        for (k = 0; k < a->n_src_inputs; k++)
            if (!p->source_inputs || !declared(p->source_inputs, a->src_inputs[k].label, a->src_inputs[k].sha256))
                return objc_fail(a, "source-receipt-stale", NULL, 0, "%s: the receipt's %s (%s) is not the prepared source the declaration records",
                                 p->provider_id, a->src_inputs[k].label, a->src_inputs[k].sha256);
    }
    for (i = 0; i < a->n_sends; i++) {
        ObjcSend *s = &a->sends[i];
        const ObjcEvidence *e = &a->evidence[s->evidence];
        const ObjcProvider *p = NULL;
        const ObjcLine *ln = NULL;
        const ObjcSourceInput *in;
        const ObjcSourceRow *first = NULL;
        size_t ncand = 0, nkind = 0;
        int agree = 1;
        char where[600], basis[1200], prov[800];
        for (j = 0; j < a->n_providers && !p; j++)
            for (k = 0; k < a->providers[j].n_ranges; k++)
                if (e->address >= a->providers[j].ranges[2 * k] && e->address < a->providers[j].ranges[2 * k + 1]) { p = &a->providers[j]; break; }
        if (!p) continue;
        if (!p->n_lines) { status = objc_fail(a, "no-line-table", e->slice, e->address, "%s: the linked archive members carry no line table to map this send to its source", p->provider_id); continue; }
        if (!(ln = line_at(p, e->address))) {
            status = objc_fail(a, "unmapped-source-send", e->slice, e->address, "%s: the line table has no row for this send", p->provider_id);
            continue;
        }
        if (!ln->line || !s->selector) {
            char reason[1400];
            snprintf(reason, sizeof reason, "%s%s%s", !ln->line ? "the line table attributes this send to no source line"
                                                                 : "the binary gives no selector here",
                     ", so the source receipt cannot close it; ", s->reason ? s->reason : "no other evidence closes it");
            if (s->origin == OBJC_ORIGIN_OPEN || !s->selector)
                if (objc_set_string(&s->reason, reason)) return objc_fail(a, "out-of-memory", NULL, 0, "source");
            continue;
        }
        if (!(in = input_named(a, ln->file))) {
            status = objc_fail(a, "unmapped-source-send", e->slice, e->address, "%s: the line table names %s, which is no single input of the receipt", p->provider_id, ln->file);
            continue;
        }
        snprintf(where, sizeof where, "%s:%u%s", in->label, ln->line, "");
        if (ln->col) snprintf(where + strlen(where), sizeof where - strlen(where), ":%u", ln->col);
        for (k = 0; k < a->n_src_rows; k++) {
            const ObjcSourceRow *r = &a->src_rows[k];
            if (strcmp(r->file, in->label) || !s->selector || strcmp(r->selector, s->selector) || !covers(r, ln->line, ln->col)) continue;
            ncand++;
            if (s->method_kind && !strcmp(r->kind, s->method_kind)) nkind++;
            if (!first) first = r;
            else if (strcmp(first->receiver, r->receiver) || strcmp(first->kind, r->kind)) agree = 0;
        }
        if (!ncand) {
            status = objc_fail(a, "unmapped-source-send", e->slice, e->address, "%s: no %s send of the receipt is at %s", p->provider_id,
                               s->selector ? s->selector : "(unresolved selector)", where);
            continue;
        }
        if (s->origin != OBJC_ORIGIN_OPEN) {
            if (s->method_kind && !nkind)
                status = objc_fail(a, "source-binary-disagreement", e->slice, e->address, "the artifact measures %s%s %s; the receipt at %s says %s",
                                   s->method_kind, s->receiver ? s->receiver : "?", s->selector, where, first->kind);
            continue;
        }
        snprintf(prov, sizeof prov, "%s (sha256 %s), source receipt %.16s", where, in->sha256, a->src_sha256);
        if (!agree || !strcmp(first->receiver, "-")) {
            char reason[1400];
            if (!agree) snprintf(reason, sizeof reason, "the source receipt has %zu %s sends at %s with different receivers",
                                 ncand, s->selector, where);
            else snprintf(reason, sizeof reason, "at %s the source receipt gives the receiver static type %s (%s), which names no class",
                          where, first->type, first->form);
            if (objc_set_string(&s->reason, reason) || objc_set_string(&s->provenance, prov)) return objc_fail(a, "out-of-memory", NULL, 0, "source");
            continue;
        }
        snprintf(basis, sizeof basis, "source receipt %.16s: %s %s at %s, static type %s", a->src_sha256, first->form, s->selector, where, first->type);
        if (objc_set_string(&s->receiver, first->receiver) || objc_set_string(&s->method_kind, first->kind) ||
            objc_set_string(&s->basis, basis) || objc_set_string(&s->provenance, prov) || objc_set_string(&s->reason, NULL))
            return objc_fail(a, "out-of-memory", NULL, 0, "source");
        s->origin = OBJC_ORIGIN_SOURCE; s->exact = 0; s->allocated = 0;
    }
    return status;
}
