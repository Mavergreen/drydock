/* Test-only harness: runs the reader/binding stage and prints its records as TSV, each dispatch
 * row ending in its path conditions ("SITE:YES|NO" joined by commas, or "-") and, for one path of a call
 * read once per incoming path, that path's last instruction (else "-"); a send row ends in it too. Verdicts are the
 * analyzer's (tools/objc-compat/main.m); this harness never classifies.
 * With --close it also runs receiver/use closure over the loaded references. --references DIR first
 * loads DIR's argument-register catalogs alone (objc_load_gprs_catalogs), as the analyzer's reference
 * set would, so the reader bounds a call's argument registers by them. --shipped FILE then reads FILE's
 * metadata alone and adds its method definitions, as src/objc/main.c add_shipped does for a shipped
 * image after the artifact's code has been read.
 * --bridge-root VA (repeatable) names an own-absent provider's root, so calls to it are bridge-call rows.
 * --link-map prints objc_linkmap_read's parse instead (link_map below).
 * --functions FILE prints objc_image_function's answers, one per line.
 * --rebased FILE VA prints 1 or 0: whether objc_image_rebased says a rebase entry covers the slot at VA.
 * --bound-lib FILE VA prints objc_image_bound_lib_at's library for the slot at VA, or "-".
 * Exit 0 measured (and, with --close, every send closed), 4 cannot-measure, 2 usage. */
#include "report.h"
#include "linkmap.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *KIND[] = {
    "class", "category", "method", "selref", "classref", "metadata-use", "sel-cache",
    "class-cache", "cache-fetch", "cache-use", "sel-register", "class-lookup", "dispatch-call",
    "method-registration", "sel-computed", "bridge-call",
};
static const char *FORM[] = {
    "none", "unknown", "argument", "sel-cache", "class-cache", "selref", "classref", "sel-literal",
    "class-literal", "sel-nsstring", "result",
};

static const char *s(const char *v) { return v ? v : "-"; }

/* An operand as "form:0xref:text" ("-" text when unnamed); "-" for a non-dispatch row but a bridge call's receiver. */
static void value(const ObjcEvidence *e, const ObjcValue *v) {
    if (e->kind != OBJC_EV_DISPATCH_CALL && !(e->kind == OBJC_EV_BRIDGE_CALL && v == &e->receiver)) { printf("\t-"); return; }
    printf("\t%s:0x%llx:%s", FORM[v->form], (unsigned long long)v->ref, s(v->text));
}

/* --demangle: one symbol per stdin line -> "symbol<TAB>demangled<TAB>cache-kind<TAB>form", or
 * "symbol<TAB>refused<TAB>why"; exit 4 when any is refused. */
static int demangle(void) {
    static const char *FETCH[] = { "-", "sel-fetch", "class-fetch", "sel-wrapper", "nsstring-wrapper" };
    char line[8192], why[200];
    int rc = 0;
    while (fgets(line, sizeof line, stdin)) {
        char *d;
        line[strcspn(line, "\n")] = 0;
        if (!line[0]) continue;
        if ((d = objc_binding_demangle(line, why, sizeof why))) {
            int k = objc_binding_cache_kind(line);
            printf("%s\t%s\t%s\t%s\n", line, d, k == 1 ? "sel-cache" : k == 2 ? "class-cache" : "-",
                   FETCH[objc_binding_fetch_form(line)]);
            free(d);
        } else {
            printf("%s\trefused\t%s\n", line, why);
            rc = 4;
        }
    }
    return rc;
}

/* --link-map MAP [VA]...: the parse as "arch", "file", "sect" and "atom" rows (file is -1 when unlisted), then
 * "at VA ADDR NAME" for the atom objc_linkmap_atom_at finds, or "at VA -"; errors as "error" rows, exit 4. */
static int link_map(int argc, char **argv) {
    ObjcAnalysis *a = objc_analysis_create();
    ObjcLinkMap m;
    size_t k;
    int i, rc;
    if (!a) return 4;
    if (!(rc = objc_linkmap_read(a, argv[0], &m))) {
        printf("arch\t%s\n", m.arch);
        for (k = 0; k < m.nfiles; k++)
            printf("file\t%zu\t%s\t%s\t%s\n", k, s(m.files[k].path), s(m.files[k].archive), s(m.files[k].member));
        for (k = 0; k < m.nsects; k++)
            printf("sect\t0x%llx\t0x%llx\t%s\t%s\n", (unsigned long long)m.sects[k].addr, (unsigned long long)m.sects[k].size, m.sects[k].seg, m.sects[k].sect);
        for (k = 0; k < m.natoms; k++)
            printf("atom\t0x%llx\t0x%llx\t%ld\t%s\n", (unsigned long long)m.atoms[k].addr, (unsigned long long)m.atoms[k].size, m.atoms[k].file, m.atoms[k].name);
        for (i = 1; i < argc; i++) {
            const ObjcMapAtom *t = objc_linkmap_atom_at(&m, strtoull(argv[i], NULL, 16));
            if (t) printf("at\t%s\t0x%llx\t%s\n", argv[i], (unsigned long long)t->addr, t->name);
            else printf("at\t%s\t-\n", argv[i]);
        }
        objc_linkmap_free(&m);
    }
    for (k = 0; k < a->n_errors; k++)
        printf("error\t%s\t%s\t0x%llx\t%s\n", s(a->errors[k].code), s(a->errors[k].slice),
               (unsigned long long)a->errors[k].address, s(a->errors[k].detail));
    objc_analysis_destroy(a);
    return rc ? 4 : 0;
}

/* --rebased FILE VA: "1" or "0" from objc_image_rebased; exit 4 when FILE does not open as an image. */
static int rebased(const char *file, const char *va) {
    ObjcAnalysis *a = objc_analysis_create();
    ObjcImage *im;
    if (!a) return 4;
    if (objc_image_open(a, file, &im)) { objc_analysis_destroy(a); return 4; }
    printf("%d\n", objc_image_rebased(im, strtoull(va, NULL, 16)));
    objc_image_close(im);
    objc_analysis_destroy(a);
    return 0;
}

/* --bound-lib FILE VA: the library objc_image_bound_lib_at names for VA, or "-"; exit 4 when FILE does not open. */
static int bound_lib(const char *file, const char *va) {
    ObjcAnalysis *a = objc_analysis_create();
    ObjcImage *im;
    if (!a) return 4;
    if (objc_image_open(a, file, &im)) { objc_analysis_destroy(a); return 4; }
    printf("%s\n", s(objc_image_bound_lib_at(im, strtoull(va, NULL, 16))));
    objc_image_close(im);
    objc_analysis_destroy(a);
    return 0;
}

/* --functions FILE: one decimal VA per objc_image_function, in the order it answers; exit 4 when FILE does not open. */
static int functions(const char *file) {
    ObjcAnalysis *a = objc_analysis_create();
    ObjcImage *im;
    size_t i;
    if (!a) return 4;
    if (objc_image_open(a, file, &im)) { objc_analysis_destroy(a); return 4; }
    for (i = 0; i < objc_image_nfunctions(im); i++) printf("%llu\n", (unsigned long long)objc_image_function(im, i));
    objc_image_close(im);
    objc_analysis_destroy(a);
    return 0;
}

static int usage(void) {
    fprintf(stderr, "usage: reader-driver --artifact FILE [--references DIR] [--shipped FILE] [--binding-receipt FILE] "
                    "[--bridge-root VA]... [--close --signatures FILE [--sdk-facts FILE]]\n");
    return 2;
}

int main(int argc, char **argv) {
    ObjcAnalysis *a;
    int i, rc, close = 0;
    size_t k;
    uint64_t *roots = NULL;
    size_t nroots = 0;
    const char *artifact = NULL, *receipt = NULL, *sigs = NULL, *facts = NULL, *refs = NULL, *shipped = NULL;
    if (argc == 2 && !strcmp(argv[1], "--demangle")) return demangle();
    if (argc == 3 && !strcmp(argv[1], "--functions")) return functions(argv[2]);
    if (argc == 4 && !strcmp(argv[1], "--rebased")) return rebased(argv[2], argv[3]);
    if (argc == 4 && !strcmp(argv[1], "--bound-lib")) return bound_lib(argv[2], argv[3]);
    if (argc >= 3 && !strcmp(argv[1], "--link-map")) return link_map(argc - 2, argv + 2);
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--artifact") && i + 1 < argc) artifact = argv[++i];
        else if (!strcmp(argv[i], "--references") && i + 1 < argc) refs = argv[++i];
        else if (!strcmp(argv[i], "--shipped") && i + 1 < argc) shipped = argv[++i];
        else if (!strcmp(argv[i], "--binding-receipt") && i + 1 < argc) receipt = argv[++i];
        else if (!strcmp(argv[i], "--signatures") && i + 1 < argc) sigs = argv[++i];
        else if (!strcmp(argv[i], "--sdk-facts") && i + 1 < argc) facts = argv[++i];
        else if (!strcmp(argv[i], "--close")) close = 1;
        else if (!strcmp(argv[i], "--bridge-root") && i + 1 < argc) {
            uint64_t *g = realloc(roots, (nroots + 1) * sizeof *g);
            if (!g) { fprintf(stderr, "out of memory\n"); return 4; }
            roots = g; roots[nroots++] = strtoull(argv[++i], NULL, 16);
        }
        else return usage();
    }
    if (!artifact || ((sigs || facts) && !close)) return usage();
    if (!(a = objc_analysis_create()) || objc_set_string(&a->artifact_path, artifact) ||
        objc_set_string(&a->binding_receipt_path, receipt) || objc_set_string(&a->signatures_path, sigs) ||
        objc_set_string(&a->facts_path, facts) || objc_set_string(&a->references_dir, refs)) { fprintf(stderr, "out of memory\n"); return 4; }
    a->bridge_roots = roots; a->n_bridge_roots = nroots;
    rc = refs ? objc_load_gprs_catalogs(a) : 0;
    if (rc == 0) rc = objc_load_references(a);
    if (rc == 0) rc = objc_collect_artifacts(a);
    if (rc == 0 && shipped) {
        ObjcAnalysis *sub = objc_analysis_create();
        if (!sub || objc_set_string(&sub->artifact_path, shipped)) { fprintf(stderr, "out of memory\n"); return 4; }
        sub->metadata_only = 1;
        rc = objc_collect_artifacts(sub);
        for (k = 0; rc == 0 && k < sub->n_evidence; k++) {
            ObjcEvidence e = sub->evidence[k];
            if (e.kind != OBJC_EV_METHOD_DEF) continue;
            e.image = 1;
            if (objc_add_evidence(a, &e)) rc = 4;
        }
        objc_analysis_destroy(sub);
    }
    if (rc == 0 && close) rc = objc_close_sends(a);
    if (rc == 0 && a->n_errors) rc = 4;   /* a stage can never report success past an error */
    for (k = 0; k < a->n_evidence; k++) {
        const ObjcEvidence *e = &a->evidence[k];
        printf("evidence\t%s\t%s\t0x%llx\t0x%llx\t%s\t%s\t%s\t%s\t%s\t%s", KIND[e->kind], s(e->slice),
               (unsigned long long)e->address, (unsigned long long)e->target, s(e->owner),
               s(e->method_kind), s(e->selector), s(e->name), s(e->symbol), s(e->function));
        value(e, &e->receiver); value(e, &e->sel); value(e, &e->arg);
        if (e->kind != OBJC_EV_DISPATCH_CALL || !e->nconds) printf("\t-");
        else {
            size_t c;
            for (c = 0; c < e->nconds; c++)
                printf("%s0x%llx:%s", c ? "," : "\t", (unsigned long long)e->conds[c].site, e->conds[c].value ? "YES" : "NO");
        }
        if (e->kind == OBJC_EV_DISPATCH_CALL && e->incoming) printf("\t0x%llx", (unsigned long long)e->incoming);
        else if (e->kind == OBJC_EV_DISPATCH_CALL) printf("\t-");
        putchar('\n');
    }
    for (k = 0; k < a->n_bindings; k++) {
        const ObjcBinding *b = &a->bindings[k];
        const ObjcEvidence *e = &a->evidence[b->evidence];
        printf("binding\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", s(b->demangled), s(b->form), s(b->crate),
               s(b->rust_owner), s(b->rust_fn), s(e->kind == OBJC_EV_SEL_CACHE ? e->selector : e->name),
               s(b->receiver), s(b->method_kind), s(b->provenance));
    }
    for (k = 0; k < a->n_sends; k++) {
        const ObjcSend *x = &a->sends[k];
        const ObjcEvidence *e = &a->evidence[x->evidence];
        char inc[32] = "-";
        if (e->incoming) snprintf(inc, sizeof inc, "0x%llx", (unsigned long long)e->incoming);
        printf("send\t0x%llx\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", (unsigned long long)e->address, s(e->name),
               s(x->selector), s(x->receiver), s(x->method_kind), x->reason ? "open" : "closed", s(x->basis),
               s(x->reason), inc);
    }
    for (k = 0; k < a->n_errors; k++)
        printf("error\t%s\t%s\t0x%llx\t%s\n", s(a->errors[k].code), s(a->errors[k].slice),
               (unsigned long long)a->errors[k].address, s(a->errors[k].detail));
    printf("limit\tundecoded-bytes\t%llu\n", (unsigned long long)a->limit_undecoded_bytes);
    objc_analysis_destroy(a);
    return rc;
}
