/*
 * drydock-objc — the Objective-C send analyzer imported from shipyard, as one
 * program with one subcommand per interface shipyard's scripts had.
 *
 * The grammar this build implements, verbatim:
 *
 *   drydock-objc analyze ARGS...     shipyard's scripts/objc-compat.sh: --artifact FILE
 *                                    --root DIR --report NEW_FILE [--references DIR]
 *                                    [--build-evidence FILE] [--provider-prefix DIR
 *                                    [--source-receipt FILE]] [--mode inventory|strict]
 *                                    [--exceptions FILE] [--analyzer-id ID]
 *   drydock-objc evidence ARGS...    shipyard's scripts/objc-build-evidence.sh:
 *                                    --artifact FILE --prestrip FILE --source-root DIR
 *                                    [--link-map FILE --provider-prefix DIR]
 *                                    [--references DIR] --output NEW_FILE
 *   drydock-objc link-args ARGS...   shipyard's scripts/objc-provider-link-args.sh:
 *                                    --prefix PREFIX --link-map FILE
 *
 * DELEGATION: each subcommand calls objc_compat_main -- src/objc/main.m, the
 * Foundation front end, compiled with -Dmain=objc_compat_main and otherwise
 * byte-identical to shipyard's -- with the arguments the shell wrapper passed
 * it. main.m validates every option, value, repeat and destination itself, as
 * it did behind the wrappers, so exits are unchanged: analyze 0/1/2/4,
 * evidence 0/2/4, link-args 0/2/4.
 *
 * TWO DEFAULTS are added, and only when the caller did not give the option:
 *   --analyzer-id (analyze only): DRYDOCK_OBJC_ANALYZER_ID, the release version
 *     plus a digest over every analyzer source byte, computed by CMake. It took
 *     the place of objc-compat.sh's "objc-compat-src-KEY"; an explicit one wins,
 *     so a caller that passes its own gets the report it got before.
 *   --references (analyze, evidence): the shipped reference set,
 *     <realpath(this binary)>/../../share/drydock/objc/reference, resolved from
 *     the real path so a symlinked or unpacked copy still finds its own; when
 *     that is not there (a build tree), DRYDOCK_OBJC_BUILD_REFERENCES, the
 *     source tree's reference/objc. link-args takes no reference set.
 *
 * Nothing is fetched or executed: the analyzer reads its inputs as data.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>
#include <sys/stat.h>
#include <mach-o/dyld.h>

#ifndef DRYDOCK_OBJC_ANALYZER_ID
#error "DRYDOCK_OBJC_ANALYZER_ID is computed by CMakeLists.txt"
#endif
#ifndef DRYDOCK_OBJC_BUILD_REFERENCES
#error "DRYDOCK_OBJC_BUILD_REFERENCES is set by CMakeLists.txt"
#endif

int objc_compat_main(int argc, char **argv);

static void usage(void) {
    fprintf(stderr,
            "usage: drydock-objc analyze --artifact FILE --root DIR --report NEW_FILE [--references DIR] [option VALUE]...\n"
            "       drydock-objc evidence --artifact FILE --prestrip FILE --source-root DIR [--link-map FILE --provider-prefix DIR]"
            " [--references DIR] --output NEW_FILE\n"
            "       drydock-objc link-args --prefix PREFIX --link-map FILE\n");
}

/* Whether OPT is one of ARGS' option names. Options and values alternate, as
 * main.m reads them; a malformed list is main.m's to refuse. */
static int has_option(int argc, char **argv, const char *opt) {
    int i;
    for (i = 0; i < argc; i += 2)
        if (!strcmp(argv[i], opt)) return 1;
    return 0;
}

/* The reference set beside the real binary, else the source tree's; NULL when
 * neither is a directory (main.m then says --references is required). */
static const char *default_references(char *out, size_t outlen) {
    char self[PATH_MAX], real[PATH_MAX];
    uint32_t len = sizeof self;
    struct stat st;
    char *slash;
    int up;
    if (_NSGetExecutablePath(self, &len) == 0 && realpath(self, real)) {
        for (up = 0; up < 2; up++) {
            if (!(slash = strrchr(real, '/'))) break;
            *slash = '\0';
        }
        if (up == 2 && (size_t)snprintf(out, outlen, "%s/share/drydock/objc/reference", real) < outlen &&
            stat(out, &st) == 0 && S_ISDIR(st.st_mode))
            return out;
    }
    if (stat(DRYDOCK_OBJC_BUILD_REFERENCES, &st) == 0 && S_ISDIR(st.st_mode)) return DRYDOCK_OBJC_BUILD_REFERENCES;
    return NULL;
}

/* objc_compat_main(MODE?, ARGS..., defaults...). MODE is main.m's own word for
 * the subcommand, or NULL for its default (analysis) mode. */
static int run(const char *mode, int argc, char **argv, int want_refs, int want_id) {
    char refs[PATH_MAX];
    const char *r = NULL;
    char **v = calloc((size_t)argc + 6, sizeof *v);
    int n = 0, i;
    if (!v) { fprintf(stderr, "drydock-objc: out of memory\n"); return 4; }
    v[n++] = "drydock-objc";
    if (mode) v[n++] = (char *)mode;
    for (i = 0; i < argc; i++) v[n++] = argv[i];
    if (want_refs && !has_option(argc, argv, "--references") && (r = default_references(refs, sizeof refs))) {
        v[n++] = "--references";
        v[n++] = (char *)r;
    }
    if (want_id && !has_option(argc, argv, "--analyzer-id")) {
        v[n++] = "--analyzer-id";
        v[n++] = DRYDOCK_OBJC_ANALYZER_ID;
    }
    v[n] = NULL;
    return objc_compat_main(n, v);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }
    /* objc-compat.sh accepted only option names in option positions, so main.m's
     * mode words never reached it there; they do not reach it through analyze. */
    if (!strcmp(argv[1], "analyze")) {
        if (argc > 2 && (!strcmp(argv[2], "emit-build-evidence") || !strcmp(argv[2], "provider-link-args"))) { usage(); return 2; }
        return run(NULL, argc - 2, argv + 2, 1, 1);
    }
    if (!strcmp(argv[1], "evidence")) return run("emit-build-evidence", argc - 2, argv + 2, 1, 0);
    if (!strcmp(argv[1], "link-args")) return run("provider-link-args", argc - 2, argv + 2, 0, 0);
    usage();
    return 2;
}
