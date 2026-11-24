/* Test-only harness for objc_sort_lines and objc_line_at (objc-line-order-test.sh).
 *
 *   lines-driver VA... < ROWS
 *
 * Each stdin line is one line-table row, "ADDR LINE COL FILE" (ADDR in hex), in the order a line table emits
 * them, all inside one atom. The rows are sorted as provider.c sorts a member's rows, then each VA is answered
 * by one line: "LINE:COL FILE" of the row governing it, or "none". Exit 0, 2 usage or a bad row, 4 out of memory. */
#include "report.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    ObjcLine *rows = NULL, *g;
    size_t n = 0, i;
    unsigned long long addr;
    unsigned line, col;
    char file[256];
    int k;
    if (argc < 2) { fprintf(stderr, "usage: lines-driver VA... < ROWS\n"); return 2; }
    while ((k = scanf("%llx %u %u %255s", &addr, &line, &col, file)) == 4) {
        if (!(g = realloc(rows, (n + 1) * sizeof *rows))) return 4;
        rows = g; g = &rows[n];
        g->addr = addr; g->lo = 0; g->hi = UINT64_MAX; g->line = line; g->col = col; g->seq = n;
        if (!(g->file = strdup(file))) return 4;
        n++;
    }
    if (k != EOF) { fprintf(stderr, "lines-driver: row %lu is not ADDR LINE COL FILE\n", (unsigned long)n + 1); return 2; }
    objc_sort_lines(rows, n);
    for (k = 1; k < argc; k++) {
        const ObjcLine *ln = objc_line_at(rows, n, strtoull(argv[k], NULL, 16));
        if (ln) printf("%u:%u %s\n", ln->line, ln->col, ln->file);
        else printf("none\n");
    }
    for (i = 0; i < n; i++) free(rows[i].file);
    free(rows);
    return fflush(stdout) || ferror(stdout) ? 4 : 0;
}
