/* Test-only harness: runs the reader/binding stage and prints its records as TSV, each dispatch
 * row ending in its path conditions ("SITE:YES|NO" joined by commas, or "-") and, for one path of a call
 * read once per incoming path, that path's last instruction (else "-"); a send row ends in it too. Verdicts are the
 * analyzer's (tools/objc-compat/main.m); this harness never classifies.
 * With --close it also runs receiver/use closure over the loaded references.
 * Exit 0 measured (and, with --close, every send closed), 4 cannot-measure, 2 usage. */
#include "report.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *KIND[] = {
    "class", "category", "method", "selref", "classref", "metadata-use", "sel-cache",
    "class-cache", "cache-fetch", "cache-use", "sel-register", "class-lookup", "dispatch-call",
    "method-registration",
};
static const char *FORM[] = {
    "none", "unknown", "argument", "sel-cache", "class-cache", "selref", "classref", "sel-literal",
    "class-literal", "sel-nsstring", "result",
};

static const char *s(const char *v) { return v ? v : "-"; }

/* An operand as "form:0xref:text" ("-" text when unnamed); "-" for a non-dispatch row. */
static void value(const ObjcEvidence *e, const ObjcValue *v) {
    if (e->kind != OBJC_EV_DISPATCH_CALL) { printf("\t-"); return; }
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

static int usage(void) {
    fprintf(stderr, "usage: reader-driver --artifact FILE [--binding-receipt FILE] "
                    "[--close --signatures FILE [--sdk-facts FILE]]\n");
    return 2;
}

int main(int argc, char **argv) {
    ObjcAnalysis *a;
    int i, rc, close = 0;
    size_t k;
    const char *artifact = NULL, *receipt = NULL, *sigs = NULL, *facts = NULL;
    if (argc == 2 && !strcmp(argv[1], "--demangle")) return demangle();
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--artifact") && i + 1 < argc) artifact = argv[++i];
        else if (!strcmp(argv[i], "--binding-receipt") && i + 1 < argc) receipt = argv[++i];
        else if (!strcmp(argv[i], "--signatures") && i + 1 < argc) sigs = argv[++i];
        else if (!strcmp(argv[i], "--sdk-facts") && i + 1 < argc) facts = argv[++i];
        else if (!strcmp(argv[i], "--close")) close = 1;
        else return usage();
    }
    if (!artifact || ((sigs || facts) && !close)) return usage();
    if (!(a = objc_analysis_create()) || objc_set_string(&a->artifact_path, artifact) ||
        objc_set_string(&a->binding_receipt_path, receipt) || objc_set_string(&a->signatures_path, sigs) ||
        objc_set_string(&a->facts_path, facts)) { fprintf(stderr, "out of memory\n"); return 4; }
    rc = objc_load_references(a);
    if (rc == 0) rc = objc_collect_artifacts(a);
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
