/* platform: realpath and lstat under -std=c99: _XOPEN_SOURCE on glibc, _DARWIN_C_SOURCE keeps the rest visible on a Mac */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "walk.h"

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

typedef struct {
    RNib *nibs; size_t n;
    char **bins; size_t nb;
    const char *base; size_t baselen;   /* relpaths are relative to base */
    char *why; size_t whysz;
} Walk;

static int fail(Walk *w, const char *fmt, const char *path) {
    snprintf(w->why, w->whysz, fmt, path, strerror(errno));
    return 4;
}

static int oom(Walk *w) {
    snprintf(w->why, w->whysz, "out of memory");
    return 4;
}

static char *dup_s(const char *s) {
    char *c = malloc(strlen(s) + 1);
    if (c) strcpy(c, s);
    return c;
}

static int ends(const char *s, const char *suffix) {
    size_t n = strlen(s), k = strlen(suffix);
    return n > k && !strcmp(s + n - k, suffix);
}

static int join(Walk *w, char *out, const char *dir, const char *name) {
    if ((size_t)snprintf(out, PATH_MAX, "%s/%s", dir, name) >= PATH_MAX) {
        snprintf(w->why, w->whysz, "%s/%s: path too long", dir, name);
        return 4;
    }
    return 0;
}

/* v, an array of n elements of size bytes, with room for one more: v itself, or a larger copy, or NULL. */
static void *grown(void *v, size_t n, size_t size) {
    if (n & (n - 1)) return v;
    if (n > SIZE_MAX / 2 / size) return NULL;
    return realloc(v, (n ? 2 * n : 1) * size);
}

static int add_nib(Walk *w, const char *abspath, int in_storyboard, int is_variant) {
    RNib *x;
    const char *rel = abspath;
    if (w->baselen && !strncmp(abspath, w->base, w->baselen) && abspath[w->baselen] == '/') rel = abspath + w->baselen + 1;
    if (!(x = grown(w->nibs, w->n, sizeof *w->nibs))) return oom(w);
    w->nibs = x;
    x = &w->nibs[w->n];
    if (!(x->relpath = dup_s(rel)) || !(x->abspath = dup_s(abspath))) { free(x->relpath); return oom(w); }
    x->in_storyboard = in_storyboard;
    x->is_variant = is_variant;
    w->n++;
    return 0;
}

/* The sorted names in dir, less . and ..; NULL with why set. */
static char **names(Walk *w, const char *dir, size_t *n) {
    DIR *d;
    struct dirent *e;
    char **v = NULL, **more;
    *n = 0;
    if (!(d = opendir(dir))) { fail(w, "%s: cannot read: %s", dir); return NULL; }
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if ((more = grown(v, *n, sizeof *v))) v = more;
        if (!more || !(v[*n] = dup_s(e->d_name))) {
            while (*n) free(v[--*n]);
            free(v);
            closedir(d);
            oom(w);
            return NULL;
        }
        ++*n;
    }
    closedir(d);
    if (!v && !(v = malloc(sizeof *v))) { oom(w); return NULL; }
    return v;
}

static void free_names(char **v, size_t n) {
    while (n) free(v[--n]);
    free(v);
}

/* keyedobjects-NNN.nib: NNN, else -1. */
static long variant(const char *name) {
    const char *p;
    char *end;
    long v;
    if (strncmp(name, "keyedobjects-", 13) || !ends(name, ".nib")) return -1;
    p = name + 13;
    if (*p < '0' || *p > '9') return -1;
    errno = 0;
    v = strtol(p, &end, 10);
    return errno || strcmp(end, ".nib") ? -1 : v;
}

static int nib_dir(Walk *w, const char *dir, int in_storyboard) {
    char path[PATH_MAX], **v;
    size_t n, i, best = 0;
    long high = -1, k;
    int rc = 0, floor = 0;
    if (!(v = names(w, dir, &n))) return 4;
    for (i = 0; i < n; i++) {
        if (!strcmp(v[i], "keyedobjects.nib")) floor = 1;
        else if ((k = variant(v[i])) > high || (k >= 0 && k == high && strcmp(v[i], v[best]) > 0)) { high = k; best = i; }
    }
    if (floor) rc = (join(w, path, dir, "keyedobjects.nib") || add_nib(w, path, in_storyboard, 0)) ? 4 : 0;
    else if (high >= 0) rc = (join(w, path, dir, v[best]) || add_nib(w, path, in_storyboard, 1)) ? 4 : 0;
    free_names(v, n);
    return rc;
}

static int storyboard(Walk *w, const char *dir) {
    char path[PATH_MAX], **v;
    size_t n, i;
    struct stat st;
    int rc = 0;
    if (!(v = names(w, dir, &n))) return 4;
    for (i = 0; i < n && !rc; i++) {
        if (!ends(v[i], ".nib") || (rc = join(w, path, dir, v[i]))) continue;
        if (lstat(path, &st)) rc = fail(w, "%s: cannot read: %s", path);
        else if (S_ISDIR(st.st_mode)) rc = nib_dir(w, path, 1);
        else if (S_ISREG(st.st_mode)) rc = add_nib(w, path, 1, 0);
    }
    free_names(v, n);
    return rc;
}

static int tree(Walk *w, const char *dir) {
    char path[PATH_MAX], **v;
    size_t n, i;
    struct stat st;
    int rc = 0;
    if (!(v = names(w, dir, &n))) return 4;
    for (i = 0; i < n && !rc; i++) {
        if ((rc = join(w, path, dir, v[i]))) break;
        if (lstat(path, &st)) rc = fail(w, "%s: cannot read: %s", path);
        else if (S_ISDIR(st.st_mode))
            rc = ends(v[i], ".nib") ? nib_dir(w, path, 0) : ends(v[i], ".storyboardc") ? storyboard(w, path) : tree(w, path);
        else if (S_ISREG(st.st_mode) && ends(v[i], ".nib"))
            rc = add_nib(w, path, 0, 0);
    }
    free_names(v, n);
    return rc;
}

static int macho(const char *path) {
    unsigned char m[4];
    uint32_t be;
    FILE *f = fopen(path, "rb");
    size_t got;
    if (!f) return 0;
    got = fread(m, 1, 4, f);
    fclose(f);
    if (got != 4) return 0;
    be = (uint32_t)m[0] << 24 | (uint32_t)m[1] << 16 | (uint32_t)m[2] << 8 | m[3];
    return be == 0xfeedfaceu || be == 0xfeedfacfu || be == 0xcefaedfeu || be == 0xcffaedfeu || be == 0xcafebabeu;
}

static int binaries(Walk *w, const char *dir) {
    char path[PATH_MAX], **v, **more;
    size_t n, i;
    struct stat st;
    int rc = 0;
    if (lstat(dir, &st) || !S_ISDIR(st.st_mode)) return 0;
    if (!(v = names(w, dir, &n))) return 4;
    for (i = 0; i < n && !rc; i++) {
        if ((rc = join(w, path, dir, v[i]))) break;
        if (lstat(path, &st)) rc = fail(w, "%s: cannot read: %s", path);
        else if (S_ISDIR(st.st_mode)) rc = binaries(w, path);
        else if (S_ISREG(st.st_mode) && macho(path)) {
            if ((more = grown(w->bins, w->nb, sizeof *w->bins))) w->bins = more;
            if (!more || !(w->bins[w->nb] = dup_s(path))) rc = oom(w);
            else w->nb++;
        }
    }
    free_names(v, n);
    return rc;
}

static int has_contents(const char *dir) {
    char path[PATH_MAX];
    struct stat st;
    return (size_t)snprintf(path, sizeof path, "%s/Contents", dir) < sizeof path && !lstat(path, &st) && S_ISDIR(st.st_mode);
}

static int rel_cmp(const void *a, const void *b) { return strcmp(((const RNib *)a)->relpath, ((const RNib *)b)->relpath); }
static int str_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

void rw_free(RNib *nibs, size_t n, char **bins, size_t nb) {
    size_t i;
    for (i = 0; i < n; i++) { free(nibs[i].relpath); free(nibs[i].abspath); }
    free(nibs);
    for (i = 0; i < nb; i++) free(bins[i]);
    free(bins);
}

int rw_walk(const char *arg, RNib **nibs, size_t *n, char ***bins, size_t *nb, char *why, size_t whysz) {
    char real[PATH_MAX], bundle[PATH_MAX], parent[PATH_MAX], path[PATH_MAX], *slash;
    struct stat st;
    Walk w;
    int rc, dir, found = 0;
    memset(&w, 0, sizeof w);
    w.why = why;
    w.whysz = whysz;
    *nibs = NULL; *n = 0; *bins = NULL; *nb = 0;
    if (!realpath(arg, real) || stat(real, &st)) return fail(&w, "%s: cannot read: %s", arg);
    dir = S_ISDIR(st.st_mode) && !ends(real, ".nib") && !ends(real, ".storyboardc");
    strcpy(parent, real);
    if ((slash = strrchr(parent, '/'))) *(slash == parent ? slash + 1 : slash) = 0;
    strcpy(bundle, dir ? real : parent);
    for (;;) {
        if ((found = has_contents(bundle))) break;
        if (!(slash = strrchr(bundle, '/')) || slash == bundle) break;
        *slash = 0;
    }
    w.base = found ? bundle : dir ? real : parent;
    w.baselen = strcmp(w.base, "/") ? strlen(w.base) : 0;
    if (dir) rc = tree(&w, real);
    else if (S_ISDIR(st.st_mode)) rc = ends(real, ".nib") ? nib_dir(&w, real, 0) : storyboard(&w, real);
    else rc = add_nib(&w, real, 0, 0);
    if (!rc && found) rc = (join(&w, path, bundle, "Contents/MacOS") || binaries(&w, path)) ? 4 : 0;
    if (!rc && found) rc = (join(&w, path, bundle, "Contents/Frameworks") || binaries(&w, path)) ? 4 : 0;
    if (rc) { rw_free(w.nibs, w.n, w.bins, w.nb); return rc; }
    if (w.n) qsort(w.nibs, w.n, sizeof *w.nibs, rel_cmp);
    if (w.nb) qsort(w.bins, w.nb, sizeof *w.bins, str_cmp);
    *nibs = w.nibs; *n = w.n; *bins = w.bins; *nb = w.nb;
    return 0;
}
