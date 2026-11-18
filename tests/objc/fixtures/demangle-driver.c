/* Test-only harness for src/objc/demangle-v0.c (objc-resolve-test.sh).
 *
 *   demangle-driver < SYMBOLS
 *
 * Each stdin line is one symbol, answered by one line: "OK<TAB>" and objc_demangle_v0's text, or
 * "NO<TAB>" and why it refused. Exit 0, 2 usage, 4 a line too long or out of memory. */
#include "report.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE_MAX_ (1u << 20)

int main(int argc, char **argv) {
    char *line = malloc(LINE_MAX_ + 2), why[200], *out;
    (void)argv;
    if (argc != 1) { fprintf(stderr, "usage: demangle-driver < SYMBOLS\n"); return 2; }
    if (!line) return 4;
    while (fgets(line, LINE_MAX_ + 2, stdin)) {
        size_t k = strlen(line);
        if (k && line[k - 1] == '\n') line[--k] = 0;
        else if (!feof(stdin)) { fprintf(stderr, "demangle-driver: a line longer than %u bytes\n", LINE_MAX_); return 4; }
        why[0] = 0;
        if ((out = objc_demangle_v0(line, why, sizeof why))) { printf("OK\t%s\n", out); free(out); }
        else printf("NO\t%s\n", why);
    }
    free(line);
    return fflush(stdout) || ferror(stdout) ? 4 : 0;
}
