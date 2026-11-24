/* Test-only harness for json.c: objc-json-driver PATH OP [ARG...] reads PATH as objc_read_json does
 * (16 MiB cap) and prints OP's answer. Ops: read; is_int KEY N; count KEY; str KEY; kind KEY
 * (which of objc_jstr/jarr/jobj accept it); exact_keys KEY...; first_unknown KEY....
 * Errors go to stderr as "CODE: DETAIL". Exit 0 answered, 4 cannot-measure, 2 usage. */
#include "json.h"
#include "report.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    ObjcAnalysis *a;
    json_t *o;
    const char *op;
    size_t k;
    int rc = 0;
    if (argc < 3) { fprintf(stderr, "usage: objc-json-driver PATH OP [ARG...]\n"); return 2; }
    op = argv[2];
    if (!(a = objc_analysis_create())) return 4;
    if (!(o = objc_read_json(a, argv[1], 16u << 20, "test input"))) {
        rc = 4;
    } else if (!strcmp(op, "read")) {
        printf("ok\n");
    } else if (!strcmp(op, "is_int") && argc == 5) {
        printf("%d\n", objc_jis_int(json_object_get(o, argv[3]), strtoll(argv[4], NULL, 10)));
    } else if (!strcmp(op, "count") && argc == 4) {
        uint64_t n = 0;
        if (objc_jcount(json_object_get(o, argv[3]), &n)) printf("1 %llu\n", (unsigned long long)n);
        else printf("0\n");
    } else if (!strcmp(op, "str") && argc == 4) {
        const char *s = objc_jstr(o, argv[3]);
        if (s) fputs(s, stdout); else { printf("(null)\n"); rc = 1; }
    } else if (!strcmp(op, "kind") && argc == 4) {
        printf("%s%s%s\n", objc_jstr(o, argv[3]) ? "s" : "-", objc_jarr(o, argv[3]) ? "a" : "-",
               objc_jobj(o, argv[3]) ? "o" : "-");
    } else if (!strcmp(op, "exact_keys")) {
        printf("%d\n", objc_jexact_keys(o, (const char *const *)argv + 3, (size_t)(argc - 3)));
    } else if (!strcmp(op, "first_unknown")) {
        const char *u = objc_jfirst_unknown(o, (const char *const *)argv + 3, (size_t)(argc - 3));
        printf("%s\n", u ? u : "(none)");
    } else {
        fprintf(stderr, "objc-json-driver: unknown op %s\n", op);
        rc = 2;
    }
    for (k = 0; k < a->n_errors; k++)
        fprintf(stderr, "%s: %s\n", a->errors[k].code, a->errors[k].detail ? a->errors[k].detail : "");
    json_decref(o);
    objc_analysis_destroy(a);
    return rc;
}
