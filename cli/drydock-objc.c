/*
 * drydock-objc — the Objective-C send analyzer imported from shipyard, as one
 * program with one subcommand per interface shipyard's scripts had.
 *
 * The grammar this build implements, verbatim:
 *
 *   drydock-objc analyze ARGS...     shipyard's scripts/objc-compat.sh: --artifact FILE
 *                                    --root DIR --report NEW_FILE [--references DIR]
 *                                    [--build-evidence FILE [--source-root DIR]
 *                                    [--crate-sources DIR] [--sdk-root DIR]
 *                                    [--link-map FILE [--object-dir DIR]...]]
 *                                    [--provider-prefix DIR
 *                                    [--source-receipt FILE]] [--mode inventory|strict]
 *                                    [--exceptions FILE] [--analyzer-id ID]
 *                                    [--root-kind tree|volume]
 *   drydock-objc evidence ARGS...    shipyard's scripts/objc-build-evidence.sh:
 *                                    --artifact FILE --prestrip FILE --source-root DIR
 *                                    [--link-map FILE [--provider-prefix DIR]]
 *                                    [--references DIR] --output NEW_FILE
 *   drydock-objc evidence --tree-digest-only --source-root DIR
 *                                    prints the prepared tree's digest, the
 *                                    source.tree_sha256 evidence records
 *                                    (src/objc/source-hash.c); 0, 2 usage, 4 unreadable
 *   drydock-objc evidence --sdk-digest-only --sdk-root DIR
 *                                    prints the SDK's header tree digest, the
 *                                    reference manifest's header_tree_sha256
 *                                    (src/objc/source-hash.c); 0, 2 usage, 4 unreadable
 *   drydock-objc link-args ARGS...   shipyard's scripts/objc-provider-link-args.sh:
 *                                    --prefix PREFIX --link-map FILE [--provider ID]...
 *                                    only the named providers' roots and frameworks; none names every one
 *                                    roots no own-absent group: the app's call to its root does
 *   (analyze)                       verifies each own-absent group per class its app names;
 *                                    the report's unused_super_fallbacks lists records excusing no send
 *   drydock-objc resolve --artifact FILE --reviewed FILE --output NEW_FILE
 *                                    schema-2 reviewed evidence with each record's
 *                                    path resolved to FILE's function symbols and
 *                                    each crate's disambiguator filled in
 *                                    (src/objc/main.c resolve_main); 0, 2 usage, 4
 *                                    unresolvable (resolve-ambiguous, a missing path)
 *   drydock-objc receipt ARGS...     shipyard's scripts/objc-source-inventory.sh, with the
 *                                    clang and the floor SDK named: --clang-prefix PREFIX
 *                                    --sdk FLOOR_SDK --inputs FILE --root DIR [--root DIR...]
 *                                    --unit LABEL [--unit LABEL...] [--include LABELDIR...]
 *                                    --output NEW_FILE
 *
 * DELEGATION: analyze, evidence, link-args and resolve call objc_compat_main -- src/objc/main.c, the
 * C front end on every host, compiled with -Dmain=objc_compat_main -- with the arguments the shell
 * wrapper passed it. main.c validates every option, value, repeat and destination itself, as
 * it did behind the wrappers, so exits are unchanged: analyze 0/1/2/4,
 * evidence 0/2/4, link-args 0/2/4, resolve 0/2/4.
 *
 * TWO DEFAULTS are added, and only when the caller did not give the option:
 *   --analyzer-id (analyze only): DRYDOCK_OBJC_ANALYZER_ID, the release version
 *     plus a digest over every analyzer source byte, computed by CMake. It took
 *     the place of objc-compat.sh's "objc-compat-src-KEY"; an explicit one wins,
 *     so a caller that passes its own gets the report it got before.
 *   --references (analyze, evidence): the shipped reference set,
 *     <realpath(this binary)>/../../share/drydock/objc/reference, resolved from
 *     the real path so a symlinked or unpacked copy still finds its own. There
 *     is no other fallback: without that directory (a build tree, or a copy
 *     moved away from its share/) and without --references, main.c refuses
 *     the missing option (exit 2). No build-machine path is compiled in.
 *     link-args takes no reference set.
 *
 * RECEIPT writes an Objective-C provider's source receipt by calling
 * objc_source_inventory_main -- tools/objc-source-inventory.c, compiled with
 * -Dmain=objc_source_inventory_main and otherwise unchanged -- as the wrapper ran
 * the tool it built: --resource-dir R --sdk FLOOR_SDK --tool-id ID, then the
 * caller's other options in order. ID is OBJC_SOURCE_INVENTORY_SHA256, the
 * SHA-256 of that source, computed by CMake. libclang is not linked: receipt
 * loads PREFIX/lib/libclang.dylib (a Mac) or PREFIX/lib/libclang.so (Linux)
 * through src/objc/libclang_shim.c, and R is the one directory in PREFIX/lib/clang,
 * which must be named for the major version clang_getClangVersion() reports (for
 * the pinned clang22, lib/clang/22: the directory its clang -print-resource-dir
 * names).
 * Option names are the seven above, each followed by its value; any other name,
 * a repeated --clang-prefix or --sdk, or either one missing is usage (exit 2).
 * A libclang that does not load or lacks a function, or no single resource
 * directory with an include/ in it and libclang's major version for a name, is
 * exit 4, before anything is written.
 * As the wrapper did, receipt clears CPATH, C_INCLUDE_PATH, CPLUS_INCLUDE_PATH,
 * OBJC_INCLUDE_PATH, SDKROOT and CCC_OVERRIDE_OPTIONS (libclang's driver reads
 * them) and sets LC_ALL=C. The tool's exits are kept: 0 written, 2 usage or an
 * existing destination, 4 an unverifiable input or a parse failure; any other
 * exit status the producer returns is 4. The producer runs in this process, so
 * a crash inside libclang kills drydock-objc with a signal and no status of
 * its own: a caller that needs a status should map death by signal to 4.
 *
 * Nothing is fetched or executed: the analyzer and the receipt tool read their
 * inputs as data.
 */
/* platform: opendir, realpath and setenv under -std=c99: _XOPEN_SOURCE on glibc, _DARWIN_C_SOURCE keeps the rest visible on a Mac */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>
#include <dirent.h>
#include <sys/stat.h>
#include "libclang_shim.h"

#ifndef OBJC_SOURCE_INVENTORY_SHA256
#error "OBJC_SOURCE_INVENTORY_SHA256 is computed by CMakeLists.txt"
#endif

int objc_source_inventory_main(int argc, char **argv);

static void usage(void) {
    fprintf(stderr,
            "usage: drydock-objc analyze --artifact FILE --root DIR --report NEW_FILE [--references DIR] [--root-kind tree|volume] [option VALUE]...\n"
            "       drydock-objc evidence --artifact FILE --prestrip FILE --source-root DIR [--link-map FILE [--provider-prefix DIR]]"
            " [--references DIR] --output NEW_FILE\n"
            "       drydock-objc evidence --tree-digest-only --source-root DIR\n"
            "       drydock-objc evidence --sdk-digest-only --sdk-root DIR\n"
            "       drydock-objc link-args --prefix PREFIX --link-map FILE [--provider ID]...\n"
            "       drydock-objc resolve --artifact FILE --reviewed FILE --output NEW_FILE\n"
            "       drydock-objc receipt --clang-prefix PREFIX --sdk FLOOR_SDK --inputs FILE --root DIR [--root DIR]..."
            " --unit LABEL [--unit LABEL]... [--include LABELDIR]... --output NEW_FILE\n");
}

#ifdef __APPLE__
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif

#ifndef DRYDOCK_OBJC_ANALYZER_ID
#error "DRYDOCK_OBJC_ANALYZER_ID is computed by CMakeLists.txt"
#endif

int objc_compat_main(int argc, char **argv);
int objc_tree_digest(const char *root, char out[65]);
int objc_sdk_header_digest(const char *root, char out[65]);

/* evidence --tree-digest-only --source-root DIR, or --sdk-digest-only --sdk-root DIR: ARGS are the
 * words after evidence. */
static int digest_only(int argc, char **argv, const char *mode, const char *option, int (*digest)(const char *, char[65])) {
    const char *root = NULL;
    char out[65];
    int i, modes = 0;
    for (i = 0; i < argc; i++) {
        if (!strcmp(argv[i], mode)) { if (modes++) { usage(); return 2; } continue; }
        if (strcmp(argv[i], option) || root || i + 1 >= argc || !*argv[i + 1]) { usage(); return 2; }
        root = argv[++i];
    }
    if (!root) { usage(); return 2; }
    if (digest(root, out)) { fprintf(stderr, "drydock-objc: cannot digest %s\n", root); return 4; }
    printf("%s\n", out);
    return fflush(stdout) || ferror(stdout) ? 4 : 0;
}

/* Whether OPT is one of ARGS' option names. Options and values alternate, as
 * main.c reads them; a malformed list is main.c's to refuse. */
static int has_option(int argc, char **argv, const char *opt) {
    int i;
    for (i = 0; i < argc; i += 2)
        if (!strcmp(argv[i], opt)) return 1;
    return 0;
}

/* The reference set beside the real binary; NULL when it is not a directory
 * (main.c then says --references is required). */
static const char *default_references(char *out, size_t outlen) {
    char self[PATH_MAX], real[PATH_MAX];
    struct stat st;
    char *slash;
    int up, found;
#ifdef __APPLE__
    uint32_t len = sizeof self;
    found = _NSGetExecutablePath(self, &len) == 0;
#else
    /* platform: Linux names the running binary in /proc. */
    ssize_t len = readlink("/proc/self/exe", self, sizeof self - 1);
    if ((found = len > 0)) self[len] = 0;
#endif
    if (found && realpath(self, real)) {
        for (up = 0; up < 2; up++) {
            if (!(slash = strrchr(real, '/'))) break;
            *slash = '\0';
        }
        if (up == 2 && (size_t)snprintf(out, outlen, "%s/share/drydock/objc/reference", real) < outlen &&
            stat(out, &st) == 0 && S_ISDIR(st.st_mode))
            return out;
    }
    return NULL;
}

/* objc_compat_main(MODE?, ARGS..., defaults...). MODE is main.c's own word for
 * the subcommand, or NULL for its default (analysis) mode. */
static int run(const char *mode, int argc, char **argv, int want_refs, int want_id) {
    char refs[PATH_MAX];
    const char *r = NULL;
    /* Slots, worst case (analyze): program name, the caller's argc words, --references and its value, --analyzer-id and its value, NULL = argc + 6; a new default adds its words here. */
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

static int receipt_fail(const char *what) {
    fprintf(stderr, "drydock-objc: %s\n", what);
    return 4;
}

/* The one directory in PREFIX/lib/clang (dot entries excepted, as the shell's glob
 * leaves them out), into OUT; -1 with WHY for none, more than one, or a long path. */
static int resource_dir(const char *prefix, char *out, size_t outlen, char *why, size_t whylen) {
    char dir[PATH_MAX], path[PATH_MAX];
    struct dirent *e;
    struct stat st;
    DIR *d;
    int found = 0;
    if ((size_t)snprintf(dir, sizeof dir, "%s/lib/clang", prefix) >= sizeof dir || !(d = opendir(dir))) {
        snprintf(why, whylen, "no compiler resource directory: cannot read %s/lib/clang", prefix);
        return -1;
    }
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        if ((size_t)snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= sizeof path) {
            closedir(d);
            snprintf(why, whylen, "a path under %s is too long", dir);
            return -1;
        }
        if (stat(path, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        if (found++) break;
        snprintf(out, outlen, "%s", path);
    }
    closedir(d);
    if (found != 1) {
        snprintf(why, whylen, "%s holds %s, not one compiler resource directory", dir, found ? "more than one directory" : "no directory");
        return -1;
    }
    if ((size_t)snprintf(path, sizeof path, "%s/include", out) >= sizeof path || stat(path, &st) != 0 || !S_ISDIR(st.st_mode)) {
        snprintf(why, whylen, "missing compiler resource directory: %s has no include", out);
        return -1;
    }
    return 0;
}

/* receipt ARGS: see the header. */
static int receipt(int argc, char **argv) {
    static const char *const names[] = {"--clang-prefix", "--sdk", "--inputs", "--root", "--unit", "--include", "--output", NULL};
    static const char *const scrub[] = {"CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "SDKROOT",
                                        "CCC_OVERRIDE_OPTIONS", NULL};
    const char *prefix = NULL, *sdk = NULL, *output = NULL;
    char lib[PATH_MAX], resource[PATH_MAX], why[2 * PATH_MAX + 512], version[256], want[16];
    const char *base;
    char **v;
    int i, k, n = 0, rc, major;
    if (argc % 2) { usage(); return 2; }
    for (i = 0; i < argc; i += 2) {
        for (k = 0; names[k] && strcmp(argv[i], names[k]); k++) ;
        if (!names[k]) { usage(); return 2; }
        if (!strcmp(argv[i], "--clang-prefix")) {
            if (prefix) { usage(); return 2; }
            prefix = argv[i + 1];
        } else if (!strcmp(argv[i], "--sdk")) {
            if (sdk) { usage(); return 2; }
            sdk = argv[i + 1];
        }
    }
    if (!prefix || !sdk) { usage(); return 2; }
#ifdef __APPLE__
    /* platform: a Mac's libclang is a .dylib. */
    if ((size_t)snprintf(lib, sizeof lib, "%s/lib/libclang.dylib", prefix) >= sizeof lib) return receipt_fail("--clang-prefix is too long");
#else
    /* platform: Linux's libclang is a .so. */
    if ((size_t)snprintf(lib, sizeof lib, "%s/lib/libclang.so", prefix) >= sizeof lib) return receipt_fail("--clang-prefix is too long");
#endif
    if (drydock_libclang_load(lib, why, sizeof why) != 0) return receipt_fail(why);
    if (resource_dir(prefix, resource, sizeof resource, why, sizeof why) != 0) return receipt_fail(why);
    /* A resource directory left from another release would give the parse another release's
     * headers: its name must be libclang's own major version. */
    major = drydock_libclang_major(version, sizeof version);
    base = strrchr(resource, '/') + 1;
    snprintf(want, sizeof want, "%d", major);
    if (major < 0 || strcmp(base, want)) {
        snprintf(why, sizeof why, "%s is not the resource directory of libclang %s (%s)", resource, lib,
                 version[0] ? version : "no version");
        return receipt_fail(why);
    }
    for (k = 0; scrub[k]; k++) unsetenv(scrub[k]);
    setenv("LC_ALL", "C", 1);
    if (!(v = calloc((size_t)argc + 8, sizeof *v))) return receipt_fail("out of memory");
    v[n++] = "objc-source-inventory";
    v[n++] = "--resource-dir";
    v[n++] = resource;
    v[n++] = "--sdk";
    v[n++] = (char *)sdk;
    v[n++] = "--tool-id";
    v[n++] = OBJC_SOURCE_INVENTORY_SHA256;
    for (i = 0; i < argc; i += 2) {
        if (!strcmp(argv[i], "--clang-prefix") || !strcmp(argv[i], "--sdk")) continue;
        if (!strcmp(argv[i], "--output")) output = argv[i + 1];
        v[n++] = argv[i];
        v[n++] = argv[i + 1];
    }
    v[n] = NULL;
    rc = objc_source_inventory_main(n, v);
    if (rc == 0 && output) {
        mode_t mask = umask(0);
        umask(mask);
        if (chmod(output, 0666 & ~mask)) return receipt_fail("cannot make the receipt readable");
    }
    if (rc == 0 || rc == 2 || rc == 4) return rc;
    snprintf(why, sizeof why, "the receipt producer failed (exit %d)", rc);
    return receipt_fail(why);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }
    if (!strcmp(argv[1], "receipt")) return receipt(argc - 2, argv + 2);
    /* objc-compat.sh accepted only option names in option positions, so main.c's
     * mode words never reached it there; they do not reach it through analyze. */
    if (!strcmp(argv[1], "analyze")) {
        if (argc > 2 && (!strcmp(argv[2], "emit-build-evidence") || !strcmp(argv[2], "provider-link-args") || !strcmp(argv[2], "resolve"))) {
            usage();
            return 2;
        }
        return run(NULL, argc - 2, argv + 2, 1, 1);
    }
    if (!strcmp(argv[1], "evidence")) {
        if (has_option(argc - 2, argv + 2, "--tree-digest-only"))
            return digest_only(argc - 2, argv + 2, "--tree-digest-only", "--source-root", objc_tree_digest);
        if (has_option(argc - 2, argv + 2, "--sdk-digest-only"))
            return digest_only(argc - 2, argv + 2, "--sdk-digest-only", "--sdk-root", objc_sdk_header_digest);
        return run("emit-build-evidence", argc - 2, argv + 2, 1, 0);
    }
    if (!strcmp(argv[1], "link-args")) return run("provider-link-args", argc - 2, argv + 2, 0, 0);
    if (!strcmp(argv[1], "resolve")) return run("resolve", argc - 2, argv + 2, 0, 0);
    usage();
    return 2;
}
