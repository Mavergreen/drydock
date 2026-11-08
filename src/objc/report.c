/* report.c -- storage lifetime for the records report.h declares. */
#include "report.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

ObjcAnalysis *objc_analysis_create(void) { return calloc(1, sizeof(ObjcAnalysis)); }

static void free_evidence(ObjcEvidence *e) {
    free(e->slice); free(e->owner); free(e->method_kind); free(e->selector); free(e->name);
    free(e->symbol); free(e->receiver.text); free(e->sel.text); free(e->arg.text); free(e->function);
}

static void free_signature(ObjcSignature *s) {
    free(s->record); free(s->owner); free(s->method_kind); free(s->selector); free(s->result_kind);
    free(s->result_class); free(s->source);
}

static void free_send(ObjcSend *s) {
    free(s->selector); free(s->receiver); free(s->method_kind); free(s->basis); free(s->reason);
    free(s->provenance);
}

static void free_strv(char **v, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) free(v[i]);
    free(v);
}

static void destroy_pipeline(ObjcAnalysis *a) {
    size_t i;
    for (i = 0; i < a->n_dylibs; i++) { free(a->dylibs[i].slice); free(a->dylibs[i].path); free(a->dylibs[i].how); }
    free(a->dylibs);
    for (i = 0; i < a->n_rt_classes; i++) {
        free(a->rt_classes[i].name); free(a->rt_classes[i].super); free(a->rt_classes[i].root); free(a->rt_classes[i].image);
    }
    free(a->rt_classes);
    objc_map_destroy(a->rt_class); objc_map_destroy(a->rt_method); objc_map_destroy(a->rt_witness);
    objc_map_destroy(a->rt_behavior); objc_map_destroy(a->rt_image_role); objc_map_destroy(a->rt_override);
    objc_map_destroy(a->nw_method); objc_map_destroy(a->nw_class); objc_map_destroy(a->fl_method);
    objc_map_destroy(a->fl_class); objc_map_destroy(a->nw_later_sel); objc_map_destroy(a->nw_encoding);
    free_strv(a->root_selectors, a->n_root_selectors);
    free_strv(a->class_roots, a->n_class_roots);
    free_strv(a->roots_blocking, a->n_roots_blocking);
    free_strv(a->uncaptured_deps, a->n_uncaptured_deps);
    free_strv(a->manifest_roots, a->n_manifest_roots);
    free_strv(a->manifest_exceptions, a->n_manifest_exceptions);
    free_strv(a->manifest_subsets, a->n_manifest_subsets);
    free_strv(a->r1_exceptions, a->n_r1_exceptions);
    free(a->runtime_tool_sha256);
    for (i = 0; i < a->n_probes; i++) {
        ObjcClusterProbe *p = &a->probes[i];
        free(p->id); free(p->cls); free(p->construction); free(p->concrete);
        free_strv(p->chain, p->nchain); free_strv(p->below, p->nbelow);
    }
    free(a->probes);
    free(a->references_dir); free(a->runtime_os); free(a->runtime_build); free(a->runtime_arch);
    free(a->be_artifact_sha256); free(a->be_source_revision); free(a->be_patches_sha256); free(a->be_features);
    free(a->artifact_sha256);
    for (i = 0; i < a->n_receipt; i++) {
        ObjcReceiptRow *r = &a->receipt[i];
        free(r->demangled); free(r->selector); free(r->receiver); free(r->kind); free(r->provenance);
    }
    free(a->receipt);
    for (i = 0; i < a->n_crates; i++) {
        free(a->crates[i].name); free(a->crates[i].version); free(a->crates[i].checksum); free(a->crates[i].disambiguator);
    }
    free(a->crates);
    for (i = 0; i < a->n_typemap; i++) { free(a->typemap[i].rust_type); free(a->typemap[i].cls); free(a->typemap[i].source); }
    free(a->typemap);
    for (i = 0; i < a->n_types; i++) {
        ObjcTypeEvidence *t = &a->types[i];
        free(t->id); free(t->symbol); free(t->rust_type); free(t->position); free(t->kind); free(t->source);
        free_strv(t->selectors, t->nselectors);
    }
    free(a->types);
    for (i = 0; i < a->n_positions; i++) {
        ObjcPositionEvidence *t = &a->positions[i];
        free(t->id); free(t->symbol); free(t->kind); free(t->cls); free(t->form); free(t->position_selector);
        free(t->rust_type); free(t->field); free(t->source);
        free_strv(t->selectors, t->nselectors);
    }
    free(a->positions);
    for (i = 0; i < a->n_guards; i++) {
        ObjcGuardRecord *g = &a->guards[i];
        free(g->id); free(g->symbol); free(g->selector); free(g->guard_selector); free(g->fallback);
        free(g->source_file); free(g->source_sha256); free(g->source_revision); free(g->patches_sha256);
        free(g->features); free(g->review_status); free(g->reviewer); free(g->review_reason);
    }
    free(a->guards);
    for (i = 0; i < a->n_src_inputs; i++) { free(a->src_inputs[i].label); free(a->src_inputs[i].sha256); }
    for (i = 0; i < a->n_src_rows; i++) {
        ObjcSourceRow *r = &a->src_rows[i];
        free(r->file); free(r->form); free(r->kind); free(r->selector); free(r->receiver); free(r->type); free(r->owner); free(r->anchors);
    }
    free(a->src_inputs); free(a->src_rows); free(a->src_path); free(a->src_sha256); free(a->src_sdk); free(a->src_libclang);
    for (i = 0; i < a->n_findings; i++) {
        ObjcFinding *f = &a->findings[i];
        free(f->id); free(f->framework); free(f->closure); free(f->proof); free(f->alternatives); free(f->deviation);
    }
    free(a->findings);
    for (i = 0; i < a->n_providers; i++) {
        ObjcProvider *p = &a->providers[i];
        size_t k;
        free(p->provider_id); free(p->cls); free(p->method_kind); free(p->selector); free(p->encoding);
        free(p->impl_symbol); free(p->root_symbol); free_strv(p->frameworks, p->nframeworks);
        free(p->archive); free(p->archive_sha256); free(p->declaration_sha256);
        free(p->ev_declaration_sha256); free(p->ev_archive_sha256);
        for (k = 0; k < p->n_members; k++) { free(p->members[k].name); free(p->members[k].sha256); }
        for (k = 0; k < p->n_atoms; k++) { free(p->atoms[k].member); free(p->atoms[k].symbol); }
        free(p->members); free(p->atoms); free(p->reason); free(p->ranges);
        free(p->sdk_settings_sha256); free(p->source_inputs);
        for (k = 0; k < p->n_lines; k++) free(p->lines[k].file);
        free(p->lines);
    }
    free(a->providers);
}

void objc_analysis_destroy(ObjcAnalysis *a) {
    size_t i;
    if (!a) return;
    for (i = 0; i < a->n_evidence; i++) free_evidence(&a->evidence[i]);
    for (i = 0; i < a->n_bindings; i++) {
        ObjcBinding *b = &a->bindings[i];
        free(b->form); free(b->crate); free(b->rust_owner); free(b->rust_fn); free(b->demangled);
        free(b->receiver); free(b->method_kind); free(b->provenance);
    }
    for (i = 0; i < a->n_errors; i++) {
        free(a->errors[i].code); free(a->errors[i].slice); free(a->errors[i].detail);
    }
    for (i = 0; i < a->n_signatures; i++) free_signature(&a->signatures[i]);
    for (i = 0; i < a->n_classes; i++) { free(a->classes[i].name); free(a->classes[i].super); }
    for (i = 0; i < a->n_sends; i++) free_send(&a->sends[i]);
    free(a->evidence); free(a->bindings); free(a->errors); free(a->signatures); free(a->classes);
    free(a->sends);
    destroy_pipeline(a);
    free(a->artifact_path); free(a->binding_receipt_path); free(a->signatures_path); free(a->facts_path);
    for (i = 0; i < a->n_rpaths; i++) free(a->rpaths[i]);
    free(a->rpaths);
    for (i = 0; i < a->n_image_paths; i++) free(a->image_paths[i]);
    free(a->image_paths);
    for (i = 0; i < a->n_shipped; i++) {
        ObjcShipped *d = &a->shipped[i];
        size_t j;
        free(d->path); free(d->abs); free(d->sha256); free(d->install); free(d->how);
        for (j = 0; j < d->n_dylibs; j++) { free(d->dylibs[j].slice); free(d->dylibs[j].path); free(d->dylibs[j].how); }
        free(d->dylibs);
        for (j = 0; j < d->n_rpaths; j++) free(d->rpaths[j]);
        free(d->rpaths);
    }
    free(a->shipped);
    free(a);
}

int objc_set_string(char **slot, const char *value) {
    char *copy = NULL;
    if (value && !(copy = strdup(value))) return -1;
    free(*slot);
    *slot = copy;
    return 0;
}

static int grow(void **v, size_t *cap, size_t n, size_t each) {
    void *p;
    size_t want;
    if (n < *cap) return 0;
    want = *cap ? *cap * 2 : 64;
    if (want < *cap || want > ((size_t)-1) / each) return -1;
    if (!(p = realloc(*v, want * each))) return -1;
    *v = p; *cap = want;
    return 0;
}

static int copy_value(ObjcValue *to, const ObjcValue *from) {
    to->form = from->form; to->ref = from->ref; to->text = NULL;
    return objc_set_string(&to->text, from->text);
}

int objc_add_evidence(ObjcAnalysis *a, const ObjcEvidence *ev) {
    ObjcEvidence e;
    memset(&e, 0, sizeof e);
    e.kind = ev->kind; e.address = ev->address; e.target = ev->target;
    e.incoming = ev->incoming; e.image = ev->image;
    e.nconds = ev->nconds <= OBJC_MAX_CONDS ? ev->nconds : OBJC_MAX_CONDS;
    memcpy(e.conds, ev->conds, sizeof e.conds);
    if (grow((void **)&a->evidence, &a->cap_evidence, a->n_evidence, sizeof e) ||
        objc_set_string(&e.slice, ev->slice) || objc_set_string(&e.owner, ev->owner) ||
        objc_set_string(&e.method_kind, ev->method_kind) ||
        objc_set_string(&e.selector, ev->selector) || objc_set_string(&e.name, ev->name) ||
        objc_set_string(&e.symbol, ev->symbol) || copy_value(&e.receiver, &ev->receiver) ||
        copy_value(&e.sel, &ev->sel) || copy_value(&e.arg, &ev->arg) ||
        objc_set_string(&e.function, ev->function)) {
        free_evidence(&e);
        objc_fail(a, "out-of-memory", ev->slice, ev->address, "storing evidence");
        return -1;
    }
    a->evidence[a->n_evidence++] = e;
    return 0;
}

int objc_add_binding(ObjcAnalysis *a, const ObjcBinding *src) {
    ObjcBinding b;
    memset(&b, 0, sizeof b);
    b.evidence = src->evidence;
    if (grow((void **)&a->bindings, &a->cap_bindings, a->n_bindings, sizeof b) ||
        objc_set_string(&b.form, src->form) || objc_set_string(&b.crate, src->crate) ||
        objc_set_string(&b.rust_owner, src->rust_owner) ||
        objc_set_string(&b.rust_fn, src->rust_fn) ||
        objc_set_string(&b.demangled, src->demangled) ||
        objc_set_string(&b.receiver, src->receiver) ||
        objc_set_string(&b.method_kind, src->method_kind) ||
        objc_set_string(&b.provenance, src->provenance)) {
        free(b.form); free(b.crate); free(b.rust_owner); free(b.rust_fn); free(b.demangled);
        free(b.receiver); free(b.method_kind); free(b.provenance);
        objc_fail(a, "out-of-memory", NULL, 0, "storing binding");
        return -1;
    }
    a->bindings[a->n_bindings++] = b;
    return 0;
}

int objc_add_signature(ObjcAnalysis *a, const ObjcSignature *src) {
    ObjcSignature s;
    memset(&s, 0, sizeof s);
    if (grow((void **)&a->signatures, &a->cap_signatures, a->n_signatures, sizeof s) ||
        objc_set_string(&s.record, src->record) || objc_set_string(&s.owner, src->owner) ||
        objc_set_string(&s.method_kind, src->method_kind) ||
        objc_set_string(&s.selector, src->selector) ||
        objc_set_string(&s.result_kind, src->result_kind) ||
        objc_set_string(&s.result_class, src->result_class) ||
        objc_set_string(&s.source, src->source)) {
        free_signature(&s);
        objc_fail(a, "out-of-memory", NULL, 0, "storing signature");
        return -1;
    }
    a->signatures[a->n_signatures++] = s;
    return 0;
}

int objc_add_class_fact(ObjcAnalysis *a, const ObjcClassFact *src) {
    ObjcClassFact c;
    memset(&c, 0, sizeof c);
    if (grow((void **)&a->classes, &a->cap_classes, a->n_classes, sizeof c) ||
        objc_set_string(&c.name, src->name) || objc_set_string(&c.super, src->super)) {
        free(c.name); free(c.super);
        objc_fail(a, "out-of-memory", NULL, 0, "storing class fact");
        return -1;
    }
    a->classes[a->n_classes++] = c;
    return 0;
}

int objc_add_send(ObjcAnalysis *a, const ObjcSend *src) {
    ObjcSend s;
    memset(&s, 0, sizeof s);
    s.evidence = src->evidence; s.origin = src->origin; s.allocated = src->allocated; s.exact = src->exact;
    s.recv_from = src->recv_from; s.recv_send = src->recv_send;
    if (grow((void **)&a->sends, &a->cap_sends, a->n_sends, sizeof s) ||
        objc_set_string(&s.selector, src->selector) || objc_set_string(&s.receiver, src->receiver) ||
        objc_set_string(&s.method_kind, src->method_kind) || objc_set_string(&s.basis, src->basis) ||
        objc_set_string(&s.reason, src->reason) || objc_set_string(&s.provenance, src->provenance)) {
        free_send(&s);
        objc_fail(a, "out-of-memory", NULL, 0, "storing send");
        return -1;
    }
    a->sends[a->n_sends++] = s;
    return 0;
}

int objc_fail(ObjcAnalysis *a, const char *code, const char *slice, uint64_t address,
              const char *fmt, ...) {
    char buf[1024];
    ObjcError e;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    memset(&e, 0, sizeof e);
    e.address = address;
    /* An error that cannot itself be stored still leaves n_errors > 0 via the static record,
     * so a stage can never report success after a failure it could not describe. */
    if (grow((void **)&a->errors, &a->cap_errors, a->n_errors, sizeof e) ||
        objc_set_string(&e.code, code) || objc_set_string(&e.slice, slice) ||
        objc_set_string(&e.detail, buf)) {
        free(e.code); free(e.slice); free(e.detail);
        if (a->n_errors < a->cap_errors) {
            memset(&a->errors[a->n_errors], 0, sizeof e);
            a->n_errors++;
        } else {
            fprintf(stderr, "objc-compat: %s (unrecorded: out of memory)\n", code);
            abort();
        }
        return OBJC_CANNOT_MEASURE;
    }
    a->errors[a->n_errors++] = e;
    return OBJC_CANNOT_MEASURE;
}

int objc_strv_push(char ***v, size_t *n, const char *s) {
    char **g, *c = strdup(s);
    if (!c || !(g = realloc(*v, (*n + 1) * sizeof *g))) { free(c); return -1; }
    g[(*n)++] = c;
    *v = g;
    return 0;
}

int objc_add_dylib(ObjcAnalysis *a, const char *slice, const char *path, const char *how) {
    ObjcDylib d;
    memset(&d, 0, sizeof d);
    if (grow((void **)&a->dylibs, &a->cap_dylibs, a->n_dylibs, sizeof d) ||
        objc_set_string(&d.slice, slice) || objc_set_string(&d.path, path) || objc_set_string(&d.how, how)) {
        free(d.slice); free(d.path); free(d.how);
        objc_fail(a, "out-of-memory", slice, 0, "storing dylib");
        return -1;
    }
    a->dylibs[a->n_dylibs++] = d;
    return 0;
}

int objc_add_finding(ObjcAnalysis *a, const ObjcFinding *src) {
    ObjcFinding f;
    memset(&f, 0, sizeof f);
    f.send = src->send; f.verdict = src->verdict; f.r1 = src->r1; f.image = src->image;
    if (grow((void **)&a->findings, &a->cap_findings, a->n_findings, sizeof f) ||
        objc_set_string(&f.id, src->id) || objc_set_string(&f.framework, src->framework) ||
        objc_set_string(&f.closure, src->closure) || objc_set_string(&f.proof, src->proof) ||
        objc_set_string(&f.alternatives, src->alternatives)) {
        free(f.id); free(f.framework); free(f.closure); free(f.proof); free(f.alternatives);
        objc_fail(a, "out-of-memory", NULL, 0, "storing finding");
        return -1;
    }
    a->findings[a->n_findings++] = f;
    return 0;
}

int objc_add_provider(ObjcAnalysis *a, ObjcProvider **out) {
    ObjcProvider *g = realloc(a->providers, (a->n_providers + 1) * sizeof *g);
    if (!g) return objc_fail(a, "out-of-memory", NULL, 0, "provider");
    a->providers = g;
    memset(&g[a->n_providers], 0, sizeof *g);
    *out = &g[a->n_providers++];
    return OBJC_OK;
}
