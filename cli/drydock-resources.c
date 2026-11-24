/*
 * drydock-resources -- checks, converts and dumps the nibs an app carries, so OS X 10.9 can load them.
 *
 *   drydock-resources dump [--target 10.9] [--references DIR] NIB
 *     prints NIB (a NIBArchive file, or a nib directory's keyedobjects.nib) as Rez-style text a person can read,
 *     diff and edit. Superclass chains come from the reference set: --references DIR, else
 *     <realpath(this binary)>/../../share/drydock/objc/reference when it exists; with neither, the
 *     chains are marked unresolved.
 *
 * Every verb takes --target, and 10.9 is the only target. Exit 0; 2 usage; 4 a nib or reference set that cannot be
 * read, or out of memory.
 */
/* platform: realpath and readlink under -std=c99: _XOPEN_SOURCE on glibc, _DARWIN_C_SOURCE keeps the rest visible on a Mac */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "chains.h"
#include "nibarchive.h"
#include "rez.h"

#ifdef __APPLE__
#include <mach-o/dyld.h>
#else
#include <unistd.h>
#endif

#define NIB_MAX ((size_t)1 << 28)

static int usage(void) {
    fprintf(stderr,
            "usage: drydock-resources check|convert|dump|build [--target 10.9] ...\n"
            "       drydock-resources dump [--target 10.9] [--references DIR] NIB\n");
    return 2;
}

/* The reference set beside the real binary, or NULL when it is not a directory. */
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

/* The whole file in a buffer of exactly its size; NULL with a reason printed. */
static uint8_t *read_nib(const char *path, size_t *outn) {
    FILE *f;
    uint8_t *buf = NULL, *more;
    size_t n = 0, cap = 1 << 16;
    if (!(f = fopen(path, "rb"))) {
        fprintf(stderr, "drydock-resources: %s: cannot read: %s\n", path, strerror(errno));
        return NULL;
    }
    for (;;) {
        if (!(more = realloc(buf, cap))) { fprintf(stderr, "drydock-resources: out of memory\n"); goto fail; }
        buf = more;
        n += fread(buf + n, 1, cap - n, f);
        if (n < cap) break;
        if (cap >= NIB_MAX) {
            fprintf(stderr, "drydock-resources: %s: larger than %lu bytes\n", path, (unsigned long)NIB_MAX);
            goto fail;
        }
        cap *= 2;
    }
    if (ferror(f)) { fprintf(stderr, "drydock-resources: %s: cannot read: %s\n", path, strerror(errno)); goto fail; }
    fclose(f);
    *outn = n;
    return buf;
fail:
    free(buf);
    fclose(f);
    return NULL;
}

static int dump(const char *arg, const char *refdir) {
    char path[PATH_MAX], refs[PATH_MAX], why[512], *text;
    struct stat st;
    uint8_t *buf;
    size_t n, textn;
    RGraph g;
    RChainSrc *s;
    int rc;
    if (stat(arg, &st) == 0 && S_ISDIR(st.st_mode)) {
        if ((size_t)snprintf(path, sizeof path, "%s/keyedobjects.nib", arg) >= sizeof path) {
            fprintf(stderr, "drydock-resources: %s: path too long\n", arg);
            return 4;
        }
        arg = path;
    }
    if (!(buf = read_nib(arg, &n))) return 4;
    if (n < 10 || memcmp(buf, "NIBArchive", 10)) {
        fprintf(stderr, "drydock-resources: %s: unsupported format\n", arg);
        free(buf);
        return 4;
    }
    rc = na_read(buf, n, &g, why, sizeof why);
    free(buf);
    if (rc) { fprintf(stderr, "drydock-resources: %s: %s\n", arg, why); return rc; }
    if (!refdir) refdir = default_references(refs, sizeof refs);
    if (!(s = rc_open(refdir, "10.9"))) {
        if (refdir) fprintf(stderr, "drydock-resources: cannot read the references in %s\n", refdir);
        else fprintf(stderr, "drydock-resources: out of memory\n");
        rg_free(&g);
        return 4;
    }
    rc = rc_resolve(s, &g);
    rc_close(s);
    if (rc) {
        fprintf(stderr, "drydock-resources: out of memory\n");
        rg_free(&g);
        return 4;
    }
    if (rez_write(&g, &text, &textn, why, sizeof why)) {
        fprintf(stderr, "drydock-resources: %s: %s\n", arg, why);
        rg_free(&g);
        return 4;
    }
    rg_free(&g);
    rc = fwrite(text, 1, textn, stdout) != textn || fflush(stdout) ? 4 : 0;
    free(text);
    if (rc) fprintf(stderr, "drydock-resources: cannot write the dump\n");
    return rc;
}

int main(int argc, char **argv) {
    const char *verb, *refdir = NULL, **args;
    int i, n = 0, rc;
    if (argc < 2) return usage();
    verb = argv[1];
    if (strcmp(verb, "check") && strcmp(verb, "convert") && strcmp(verb, "dump") && strcmp(verb, "build")) return usage();
    if (!(args = calloc((size_t)argc, sizeof *args))) { fprintf(stderr, "drydock-resources: out of memory\n"); return 4; }
    for (i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--target") || !strcmp(argv[i], "--references")) {
            if (i + 1 >= argc || !*argv[i + 1]) { free(args); return usage(); }
            if (argv[i][2] == 'r') refdir = argv[++i];
            else if (strcmp(argv[++i], "10.9")) {
                fprintf(stderr, "drydock-resources: unsupported target: %s\n", argv[i]);
                free(args);
                return 2;
            }
        } else if (argv[i][0] == '-' && argv[i][1]) {
            free(args);
            return usage();
        } else
            args[n++] = argv[i];
    }
    if (strcmp(verb, "dump")) {
        fprintf(stderr, "drydock-resources: %s is not implemented yet\n", verb);
        rc = 2;
    } else if (n != 1)
        rc = usage();
    else
        rc = dump(args[0], refdir);
    free(args);
    return rc;
}
