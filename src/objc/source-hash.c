/* source-hash.c -- the analyzer's own hashes of the source a schema-2 record cites: the prepared
 * tree's digest (source.tree_sha256) and the SHA-256 of one cited file. It reads only the roots it
 * is given and never trusts a hash a caller supplies.
 *
 * The digest covers every entry under the root except any named .git: "d PATH" for a directory,
 * "l PATH TARGET" for a symlink (not followed), "f PATH SHA256" for a file, PATH relative to the
 * root. The lines are sorted bytewise and each is hashed with a trailing newline. Any other file
 * type is refused.
 *
 * The floor SDK's header digest (reference/objc/manifest.json floor_sdk.header_tree_sha256) lists
 * the regular files under the SDK root -- symlinks not followed -- whose path holds /Headers/,
 * lies under usr/include or include, or ends .modulemap, as ./PATH, sorted bytewise; each line is
 * what `shasum -a 256 ./PATH` prints, and the digest is the SHA-256 of that listing.
 *
 * A cite resolves tree:PATH under the source root, crate:NAME-VERSION/PATH under
 * <crate sources>/NAME-VERSION, sdk:PATH under the SDK root. It is uncheckable (-1) when the root
 * is not given or missing, the path has a .. component, its real path leaves its root, or it is not
 * a regular file; a crate: cite also when no crates[] entry pins that NAME and VERSION. */
/* platform: lstat, readlink and realpath under -std=c99: _XOPEN_SOURCE on glibc, _DARWIN_C_SOURCE keeps the rest visible on a Mac */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "report.h"
#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <CommonCrypto/CommonDigest.h>

#define TREE_ENTRIES_MAX 1000000

static void hex(const unsigned char *d, char out[65]) {
    int i;
    for (i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(out + 2 * i, 3, "%02x", d[i]);
}

static int file_sha256(const char *path, char out[65]) {
    FILE *f = fopen(path, "rb");
    CC_SHA256_CTX c;
    unsigned char buf[65536], d[CC_SHA256_DIGEST_LENGTH];
    size_t n;
    int bad;
    if (!f) return -1;
    CC_SHA256_Init(&c);
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) CC_SHA256_Update(&c, buf, (CC_LONG)n);
    bad = ferror(f);
    fclose(f);
    if (bad) return -1;
    CC_SHA256_Final(d, &c);
    hex(d, out);
    return 0;
}

typedef struct { char **v; size_t n, cap; } Lines;

static int push(Lines *l, char *s) {
    if (!s || l->n >= TREE_ENTRIES_MAX) { free(s); return -1; }
    if (l->n == l->cap) {
        char **g = realloc(l->v, (l->cap = l->cap ? l->cap * 2 : 1024) * sizeof *g);
        if (!g) { free(s); return -1; }
        l->v = g;
    }
    l->v[l->n++] = s;
    return 0;
}

static int add_line(Lines *l, const char *kind, const char *rel, const char *extra) {
    size_t k = strlen(kind) + strlen(rel) + (extra ? strlen(extra) + 1 : 0) + 2;
    char *s = malloc(k);
    if (s && extra) snprintf(s, k, "%s %s %s", kind, rel, extra);
    else if (s) snprintf(s, k, "%s %s", kind, rel);
    return push(l, s);
}

/* sdk: the header tree's selection, files only: a path holding /Headers/, under usr/include or
 * include, or a name ending .modulemap; nothing else is refused or listed, symlinks are not
 * followed, and .git is not special. */
static int sdk_header(const char *rel, const char *name) {
    size_t k = strlen(name);
    return strstr(rel, "/Headers/") || !strncmp(rel, "Headers/", 8) || !strncmp(rel, "usr/include/", 12) ||
           !strncmp(rel, "include/", 8) || (k >= 10 && !strcmp(name + k - 10, ".modulemap"));
}

static int add_path(Lines *l, const char *rel) {
    size_t k = strlen(rel) + 3;
    char *s = malloc(k);
    if (s) snprintf(s, k, "./%s", rel);
    return push(l, s);
}

/* One file's line as `shasum -a 256 ./REL` prints it: a name holding a backslash is escaped and
 * the line marked with a leading backslash. */
static void sdk_hash(CC_SHA256_CTX *c, const char *h, const char *path) {
    const char *p;
    if (strchr(path, '\\')) CC_SHA256_Update(c, "\\", 1);
    CC_SHA256_Update(c, h, 64);
    CC_SHA256_Update(c, "  ", 2);
    for (p = path; *p; p++) { if (*p == '\\') CC_SHA256_Update(c, "\\", 1); CC_SHA256_Update(c, p, 1); }
}

static int walk(const char *root, const char *rel, Lines *l, int sdk) {
    char dirpath[PATH_MAX];
    DIR *d;
    struct dirent *e;
    int rc = 0;
    if ((size_t)snprintf(dirpath, sizeof dirpath, "%s%s%s", root, *rel ? "/" : "", rel) >= sizeof dirpath || !(d = opendir(dirpath)))
        return -1;
    while (!rc && (e = readdir(d))) {
        char sub[PATH_MAX], full[PATH_MAX], h[65];
        struct stat st;
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..") || (!sdk && !strcmp(e->d_name, ".git"))) continue;
        if ((size_t)snprintf(sub, sizeof sub, "%s%s%s", rel, *rel ? "/" : "", e->d_name) >= sizeof sub ||
            (size_t)snprintf(full, sizeof full, "%s/%s", root, sub) >= sizeof full || lstat(full, &st) != 0 ||
            (sdk && strchr(sub, '\n'))) {
            rc = -1;
        } else if (sdk) {
            if (S_ISDIR(st.st_mode)) rc = walk(root, sub, l, sdk);
            else if (S_ISREG(st.st_mode) && sdk_header(sub, e->d_name)) rc = add_path(l, sub);
        } else if (S_ISDIR(st.st_mode)) {
            rc = add_line(l, "d", sub, NULL) || walk(root, sub, l, sdk) ? -1 : 0;
        } else if (S_ISLNK(st.st_mode)) {
            char target[PATH_MAX];
            ssize_t k = readlink(full, target, sizeof target - 1);
            if (k < 0) rc = -1;
            else { target[k] = 0; rc = add_line(l, "l", sub, target); }
        } else if (S_ISREG(st.st_mode)) {
            rc = file_sha256(full, h) || add_line(l, "f", sub, h) ? -1 : 0;
        } else rc = -1;
    }
    closedir(d);
    return rc;
}

static int by_bytes(const void *x, const void *y) { return strcmp(*(char *const *)x, *(char *const *)y); }

static int digest(const char *root, int sdk, char out[65]) {
    Lines l = { NULL, 0, 0 };
    CC_SHA256_CTX c;
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    struct stat st;
    size_t i;
    int rc = -1;
    if (root && stat(root, &st) == 0 && S_ISDIR(st.st_mode) && !walk(root, "", &l, sdk)) {
        qsort(l.v, l.n, sizeof *l.v, by_bytes);
        CC_SHA256_Init(&c);
        rc = 0;
        for (i = 0; i < l.n && !rc; i++) {
            char full[PATH_MAX], h[65];
            if (!sdk) CC_SHA256_Update(&c, l.v[i], (CC_LONG)strlen(l.v[i]));
            else if ((size_t)snprintf(full, sizeof full, "%s/%s", root, l.v[i] + 2) >= sizeof full || file_sha256(full, h)) rc = -1;
            else sdk_hash(&c, h, l.v[i]);
            CC_SHA256_Update(&c, "\n", 1);
        }
        CC_SHA256_Final(d, &c);
        if (!rc) hex(d, out);
    }
    for (i = 0; i < l.n; i++) free(l.v[i]);
    free(l.v);
    return rc;
}

int objc_tree_digest(const char *root, char out[65]) { return digest(root, 0, out); }
int objc_sdk_header_digest(const char *root, char out[65]) { return digest(root, 1, out); }

/* `rel` under `root`, into `real` (PATH_MAX): no .. component, and its real path inside root's. */
static int inside(const char *root, const char *rel, char *real) {
    char rroot[PATH_MAX], full[PATH_MAX];
    const char *p;
    size_t k;
    for (p = rel; *p; p += strcspn(p, "/"), p += *p == '/') {
        if (!strncmp(p, "..", 2) && (p[2] == '/' || !p[2])) return -1;
    }
    if (!root || !realpath(root, rroot) || (size_t)snprintf(full, sizeof full, "%s/%s", rroot, rel) >= sizeof full ||
        !realpath(full, real))
        return -1;
    k = strlen(rroot);
    if (!strcmp(rroot, "/")) return 0;
    return !strncmp(real, rroot, k) && real[k] == '/' ? 0 : -1;
}

const ObjcCrate *objc_cite_crate(const ObjcAnalysis *a, const char *cite) {
    const char *dir = cite + 6, *slash = strchr(dir, '/');
    size_t i, k, n;
    if (strncmp(cite, "crate:", 6) || !slash) return NULL;
    for (i = 0; i < a->n_crates; i++) {
        const ObjcCrate *c = &a->crates[i];
        if (!c->name || !c->version || (n = strlen(c->name)) + 1 + strlen(c->version) != (size_t)(slash - dir) || dir[n] != '-') continue;
        for (k = 0; k < n && (dir[k] == c->name[k] || (strchr("-_", dir[k]) && strchr("-_", c->name[k]))); k++) ;
        if (k == n && !strncmp(dir + n + 1, c->version, strlen(c->version))) return c;
    }
    return NULL;
}

int objc_cite_sha256(const ObjcAnalysis *a, const char *cite, char out[65]) {
    char real[PATH_MAX], crate[PATH_MAX], dir[PATH_MAX];
    struct stat st;
    if (!strncmp(cite, "tree:", 5)) {
        if (inside(a->source_root, cite + 5, real)) return -1;
    } else if (!strncmp(cite, "sdk:", 4)) {
        if (inside(a->sdk_root, cite + 4, real)) return -1;
    } else if (!strncmp(cite, "crate:", 6)) {
        const char *slash = strchr(cite + 6, '/');
        size_t n = slash ? (size_t)(slash - (cite + 6)) : 0;
        if (!n || n >= sizeof crate || !objc_cite_crate(a, cite)) return -1;
        memcpy(crate, cite + 6, n); crate[n] = 0;
        if (inside(a->crate_sources, crate, dir) || inside(dir, slash + 1, real)) return -1;
    } else return -1;
    if (stat(real, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    return file_sha256(real, out);
}
