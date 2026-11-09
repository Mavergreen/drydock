/* Test-only harness for the argument-register bounds (src/objc/reference.c "argument registers").
 *
 *   arity-driver [--references DIR] [--artifact FILE] < QUERIES
 *
 * --references loads DIR's signature and function catalogs alone (objc_load_gprs_catalogs), not the
 * whole versioned set; --artifact reads FILE's metadata, so its own method encodings join the table.
 * Each stdin line is one TAB-separated query, answered by one line holding a count or -1:
 *   sel SELECTOR STRET   objc_selector_gprs (STRET 0 or 1)
 *   fn SYMBOL            objc_function_gprs
 *   enc TYPES            objc_encoding_gprs
 *   imp SYMBOL LIB       objc_import_gprs: SYMBOL bound to install name LIB
 *   rely SEL STRET INDEX objc_rely_selector_gprs for an entry point in argument register INDEX (named
 *                        "rcx", at 0x1000 of slice x86_64): its status
 *   note SEL PARAMS      objc_note_selector_gprs: the analysis's error count after it
 * Exit 0, 4 when loading or reading failed (its errors on stderr), 2 usage. */
#include "report.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int usage(void) {
    fprintf(stderr, "usage: arity-driver [--references DIR] [--artifact FILE] < QUERIES\n");
    return 2;
}

int main(int argc, char **argv) {
    ObjcAnalysis *a;
    const char *refs = NULL, *artifact = NULL;
    char line[8192];
    int i, rc = 0;
    size_t k;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--references") && i + 1 < argc) refs = argv[++i];
        else if (!strcmp(argv[i], "--artifact") && i + 1 < argc) artifact = argv[++i];
        else return usage();
    }
    if (!(a = objc_analysis_create()) || objc_set_string(&a->references_dir, refs) ||
        objc_set_string(&a->artifact_path, artifact)) { fprintf(stderr, "out of memory\n"); return 4; }
    if (refs) rc = objc_load_gprs_catalogs(a);
    if (!rc && artifact) { a->metadata_only = 1; rc = objc_collect_artifacts(a); }
    if (!rc && a->n_errors) rc = 4;
    for (k = 0; k < a->n_errors; k++)
        fprintf(stderr, "error\t%s\t%s\n", a->errors[k].code, a->errors[k].detail ? a->errors[k].detail : "-");
    while (!rc && fgets(line, sizeof line, stdin)) {
        char *f[4] = { line, NULL, NULL, NULL }, *p;
        int n = 1;
        line[strcspn(line, "\n")] = 0;
        for (p = line; n < 4 && (p = strchr(p, '\t')); n++) { *p++ = 0; f[n] = p; }
        if (!strcmp(f[0], "sel") && n == 3) printf("%d\n", objc_selector_gprs(a, f[1], atoi(f[2])));
        else if (!strcmp(f[0], "fn") && n == 2) printf("%d\n", objc_function_gprs(a, f[1]));
        else if (!strcmp(f[0], "imp") && n == 3) printf("%d\n", objc_import_gprs(a, f[1], f[2]));
        else if (!strcmp(f[0], "enc") && n == 2) printf("%d\n", objc_encoding_gprs(f[1]));
        else if (!strcmp(f[0], "rely") && n == 4)
            printf("%d\n", objc_rely_selector_gprs(a, f[1], atoi(f[2]), atoi(f[3]), "rcx", "x86_64", 0x1000));
        else if (!strcmp(f[0], "note") && n == 3) {
            objc_note_selector_gprs(a, f[1], atoi(f[2]));
            printf("%zu\n", a->n_errors);
        }
        else { objc_analysis_destroy(a); return usage(); }
    }
    for (k = 0; !rc && k < a->n_errors; k++)   /* recorded by the queries (note) */
        fprintf(stderr, "error\t%s\t%s\n", a->errors[k].code, a->errors[k].detail ? a->errors[k].detail : "-");
    objc_analysis_destroy(a);
    return rc;
}
