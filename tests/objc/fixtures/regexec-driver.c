/* Test-only harness: objc-regexec-driver IMAGE ENTRY_SYMBOL [ARG0_CLASS] [--table SYMBOL] [--track SYMBOL]...
 * [--max-paths N] runs the registration executor (src/objc/regexec.c) from ENTRY_SYMBOL's address, rdi bound to
 * Class(ARG0_CLASS) when given, stores held to SYMBOL's extent (its address to the next symbol in its section) with
 * --table, each --track SYMBOL's address tracked, every function of IMAGE's __TEXT,__text as provider code, the
 * default budgets but N paths with --max-paths, and prints, in
 * exploration order:
 *   paths N
 *   null-paths K                                 (paths on which objc_getClass returned NULL)
 *   path I found F null 0|1 adds A uforks U tforks T trapped 0|1   (each path with adds, then its lookups and adds:)
 *     found CLS|META SEL
 *     add CLS|META SEL IMP TYPES OK
 *   sites 0xSITE ...
 *   called 0xTARGET ...
 *   explored 0xLO-0xHI ...
 *   executed N
 *   escaped 0xVA@0xSITE ...
 *   selreg 0xSITE:ALL_LITERAL ...
 *   reads 0xVA+LEN@0xSITE ...
 *   stores 0xVA+LEN@0xSITE ...
 * an unnamed value as "?"; or, refused, "refused CODE: why" alone. Exit 0 explored, 1 refused, 2 usage, 4 the
 * image or symbol could not be read. */
#include "regexec.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *s(const char *v) { return v ? v : "?"; }
/* The defined, non-stab symbol name's address; 0 none. */
static uint64_t sym_addr(const ObjcImage *im, const char *name) {
    size_t i; uint8_t type; uint64_t v; const char *nm;
    for (i = 0; (nm = objc_image_nlist(im, i, &type, &v)); i++)
        if ((type & 0xe0) == 0 && (type & 0x0e) == 0x0e && !strcmp(nm, name)) return v;
    return 0;
}
/* The end of the symbol at a: the next symbol's address in its section, or the section's end. */
static uint64_t sym_end(const ObjcImage *im, uint64_t a) {
    size_t i; uint8_t type; uint64_t v, sa = 0, ss = 0, end; const char *nm;
    if (!objc_image_section_of(im, a, &sa, &ss, NULL)) return a;
    end = sa + ss;
    for (i = 0; (nm = objc_image_nlist(im, i, &type, &v)); i++)
        if ((type & 0xe0) == 0 && (type & 0x0e) == 0x0e && v > a && v < end) end = v;
    return end;
}

int main(int argc, char **argv) {
    ObjcAnalysis *a; ObjcImage *im; ObjcRegResult r; ObjcRegStart st; ObjcRegBudget b; uint64_t tracked[16];
    uint64_t lo = 0, hi = 0, *ranges; size_t i, j, n = 0, nf; int k;
    const char *usage = "usage: objc-regexec-driver IMAGE ENTRY_SYMBOL [ARG0_CLASS] [--table SYMBOL] [--track SYMBOL]... [--max-paths N]\n";
    if (argc < 3) { fputs(usage, stderr); return 2; }
    if (!(a = objc_analysis_create()) || objc_image_open(a, argv[1], &im)) { fprintf(stderr, "cannot open %s\n", argv[1]); return 4; }
    memset(&st, 0, sizeof st); st.tracked = tracked; memset(&b, 0, sizeof b);
    st.entry = sym_addr(im, argv[2]);
    for (k = 3; k < argc; k++) {
        if (!strcmp(argv[k], "--max-paths") && k + 1 < argc) b.max_paths = strtoul(argv[++k], NULL, 10);
        else if ((!strcmp(argv[k], "--table") || !strcmp(argv[k], "--track")) && k + 1 < argc) {
            uint64_t at = sym_addr(im, argv[k + 1]);
            if (!at) { fprintf(stderr, "no %s in %s\n", argv[k + 1], argv[1]); return 4; }
            if (!strcmp(argv[k], "--table")) { st.own_stores = 1; st.table_lo = at; st.table_hi = sym_end(im, at); }
            else if (st.n_tracked < sizeof tracked / sizeof *tracked) tracked[st.n_tracked++] = at;
            else { fputs(usage, stderr); return 2; }
            k++;
        } else if (k == 3 && argv[k][0] != '-') st.arg0_class = argv[k];
        else { fputs(usage, stderr); return 2; }
    }
    for (i = 0; i < objc_image_nsections(im); i++) {
        uint32_t fl; const char *sn = objc_image_section(im, i, &lo, &hi, &fl);
        if (sn && !strcmp(sn, "__TEXT,__text")) { hi += lo; break; }
        lo = hi = 0;
    }
    if (!st.entry || hi <= lo) { fprintf(stderr, "no %s or no __TEXT,__text in %s\n", argv[2], argv[1]); return 4; }
    nf = objc_image_nfunctions(im);
    if (!(ranges = calloc(2 * nf + 2, sizeof *ranges))) return 4;
    for (i = 0; i < nf; i++) {
        uint64_t f = objc_image_function(im, i), e = i + 1 < nf ? objc_image_function(im, i + 1) : hi;
        if (f < lo || f >= hi) continue;
        ranges[2 * n] = f; ranges[2 * n + 1] = e < hi ? e : hi; n++;
    }
    if (objc_derive_registration_from(im, &st, ranges, n, &b, &r)) {
        printf("refused %s: %s\n", r.code, r.why);
        objc_reg_free(&r);
        return 1;
    }
    printf("paths %zu\n", r.n_paths);
    for (i = 0, j = 0; i < r.n_paths; i++) j += r.paths[i].class_null != 0;
    printf("null-paths %zu\n", j);
    for (i = 0; i < r.n_paths; i++) {
        const ObjcRegPath *p = &r.paths[i];
        if (!p->n_adds) continue;
        printf("path %zu found %zu null %d adds %zu uforks %zu tforks %zu trapped %d\n", i, p->n_found, p->class_null, p->n_adds,
               p->unknown_forks, p->table_forks, p->trapped);
        for (j = 0; j < p->n_found; j++)
            printf("  found %s|%d %s\n", s(p->found[j].cls), p->found[j].meta, s(p->found[j].sel));
        for (j = 0; j < p->n_adds; j++)
            printf("  add %s|%d %s %s %s %d\n", s(p->adds[j].cls), p->adds[j].meta, s(p->adds[j].sel), s(p->adds[j].imp),
                   s(p->adds[j].types), p->adds[j].ok);
    }
    printf("sites");
    for (i = 0; i < r.n_sites; i++) printf(" 0x%llx", (unsigned long long)r.mutator_sites[i]);
    printf("\ncalled");
    for (i = 0; i < r.n_called; i++) printf(" 0x%llx", (unsigned long long)r.called[i]);
    printf("\nexplored");
    for (i = 0; i < r.n_explored; i++) printf(" 0x%llx-0x%llx", (unsigned long long)r.explored[2 * i], (unsigned long long)r.explored[2 * i + 1]);
    printf("\nexecuted %zu\nescaped", r.n_executed);
    for (i = 0; i < r.n_escaped; i++) printf(" 0x%llx@0x%llx", (unsigned long long)r.escaped[i].va, (unsigned long long)r.escaped[i].site);
    printf("\nselreg");
    for (i = 0; i < r.n_selreg; i++) printf(" 0x%llx:%d", (unsigned long long)r.selreg[i].site, r.selreg[i].all_literal);
    printf("\nreads");
    for (i = 0; i < r.n_reads; i++)
        printf(" 0x%llx+%llu@0x%llx", (unsigned long long)r.const_reads[i].va, (unsigned long long)r.const_reads[i].len,
               (unsigned long long)r.const_reads[i].site);
    printf("\nstores");
    for (i = 0; i < r.n_stores; i++)
        printf(" 0x%llx+%llu@0x%llx", (unsigned long long)r.image_stores[i].va, (unsigned long long)r.image_stores[i].len,
               (unsigned long long)r.image_stores[i].site);
    printf("\n");
    objc_reg_free(&r);
    free(ranges);
    objc_image_close(im);
    objc_analysis_destroy(a);
    return 0;
}
