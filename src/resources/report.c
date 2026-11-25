/* platform: mkstemp, fsync and link under -std=c99: _XOPEN_SOURCE on glibc, _DARWIN_C_SOURCE keeps the rest visible on a Mac */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "report.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <CommonCrypto/CommonDigest.h>

void rr_sha256(const void *buf, size_t n, char out[65]) {
    CC_SHA256_CTX c;
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    const unsigned char *p = buf;
    int i;
    CC_SHA256_Init(&c);
    while (n) {
        CC_LONG k = n > 0x40000000u ? 0x40000000u : (CC_LONG)n;
        CC_SHA256_Update(&c, p, k);
        p += k;
        n -= k;
    }
    CC_SHA256_Final(d, &c);
    for (i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(out + 2 * i, 3, "%02x", d[i]);
}

static void dir_of(const char *path, char dir[PATH_MAX]) {
    const char *slash = strrchr(path, '/');
    if (!slash) snprintf(dir, PATH_MAX, ".");
    else if (slash == path) snprintf(dir, PATH_MAX, "/");
    else snprintf(dir, PATH_MAX, "%.*s", (int)(slash - path), path);
}

int rr_check_dest(const char *path) {
    char dir[PATH_MAX];
    struct stat st;
    if (lstat(path, &st) == 0) {
        fprintf(stderr, "drydock-resources: %s: the report destination already exists; it is never replaced\n", path);
        return 2;
    }
    dir_of(path, dir);
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "drydock-resources: %s: the report destination's directory does not exist\n", path);
        return 2;
    }
    return 0;
}

typedef struct { char *b; size_t n, cap; int bad; } Out;

static void put(Out *o, const char *s, size_t n) {
    char *more;
    if (o->bad) return;
    if (o->n + n + 1 > o->cap) {
        size_t cap = o->cap ? o->cap : 4096;
        while (cap < o->n + n + 1) {
            if (cap > SIZE_MAX / 2) { o->bad = 1; return; }
            cap *= 2;
        }
        if (!(more = realloc(o->b, cap))) { o->bad = 1; return; }
        o->b = more;
        o->cap = cap;
    }
    memcpy(o->b + o->n, s, n);
    o->n += n;
}

static void raw(Out *o, const char *s) { put(o, s, strlen(s)); }

/* A JSON string; a byte that is not part of valid UTF-8 is written as the code point of the same value. */
static void str(Out *o, const char *s) {
    const unsigned char *p = (const unsigned char *)s;
    char esc[8];
    raw(o, "\"");
    while (*p) {
        size_t len = 0, k;
        if (*p == '"' || *p == '\\') { put(o, "\\", 1); put(o, (const char *)p++, 1); continue; }
        if (*p == '\t') { raw(o, "\\t"); p++; continue; }
        if (*p == '\n') { raw(o, "\\n"); p++; continue; }
        if (*p < 0x20) { snprintf(esc, sizeof esc, "\\u%04x", *p++); raw(o, esc); continue; }
        if (*p < 0x80) { put(o, (const char *)p++, 1); continue; }
        if (*p >= 0xc2 && *p <= 0xdf) len = 2;
        else if (*p >= 0xe0 && *p <= 0xef) len = 3;
        else if (*p >= 0xf0 && *p <= 0xf4) len = 4;
        for (k = 1; k < len; k++)
            if ((p[k] & 0xc0) != 0x80) len = 0;
        if (len == 3 && ((*p == 0xe0 && p[1] < 0xa0) || (*p == 0xed && p[1] > 0x9f))) len = 0;
        if (len == 4 && ((*p == 0xf0 && p[1] < 0x90) || (*p == 0xf4 && p[1] > 0x8f))) len = 0;
        if (!len) { snprintf(esc, sizeof esc, "\\u%04x", *p++); raw(o, esc); continue; }
        put(o, (const char *)p, len);
        p += len;
    }
    raw(o, "\"");
}

static void key(Out *o, const char *k, int first) {
    if (!first) raw(o, ",");
    str(o, k);
    raw(o, ":");
}

static void kstr(Out *o, const char *k, const char *v, int first) {
    key(o, k, first);
    if (v) str(o, v);
    else raw(o, "null");
}

/* A temp file beside path, fsynced, then linked to path, which fails rather than replace anything there. */
static int publish(const char *path, const Out *o) {
    char dir[PATH_MAX], tmp[PATH_MAX];
    const char *slash = strrchr(path, '/');
    size_t off = 0;
    int fd;
    dir_of(path, dir);
    if ((size_t)snprintf(tmp, sizeof tmp, "%s/.%s.XXXXXX", dir, slash ? slash + 1 : path) >= sizeof tmp) {
        fprintf(stderr, "drydock-resources: %s: path too long\n", path);
        return 4;
    }
    if ((fd = mkstemp(tmp)) < 0) {
        fprintf(stderr, "drydock-resources: cannot create a temporary file in %s: %s\n", dir, strerror(errno));
        return 4;
    }
    while (off < o->n) {
        ssize_t w = write(fd, o->b + off, o->n - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) {
            fprintf(stderr, "drydock-resources: writing %s: %s\n", tmp, strerror(errno));
            close(fd);
            unlink(tmp);
            return 4;
        }
        off += (size_t)w;
    }
    if (fsync(fd) != 0 || close(fd) != 0) {
        fprintf(stderr, "drydock-resources: flushing %s: %s\n", tmp, strerror(errno));
        unlink(tmp);
        return 4;
    }
    if (link(tmp, path) != 0) {
        fprintf(stderr, "drydock-resources: %s: %s (not replaced)\n", path, strerror(errno));
        unlink(tmp);
        return 4;
    }
    unlink(tmp);
    return 0;
}

int rr_write(const char *path, const char *tool, const char *verb, const char *target, int strict, const char *const *adapt,
             size_t n_adapt, const RrNib *nibs, size_t n_nibs, const RFindings *f, const RfExceptions *ex) {
    Out o = { NULL, 0, 0, 0 };
    size_t i, j;
    int rc;
    raw(&o, "{");
    key(&o, "schema", 1); raw(&o, "1");
    kstr(&o, "kind", "drydock-resources-report", 0);
    kstr(&o, "tool", tool, 0);
    kstr(&o, "verb", verb, 0);
    kstr(&o, "target", target, 0);
    key(&o, "strict", 0); raw(&o, strict ? "true" : "false");
    key(&o, "adapt", 0); raw(&o, "[");
    for (i = 0; i < n_adapt; i++) { if (i) raw(&o, ","); str(&o, adapt[i]); }
    raw(&o, "]");
    key(&o, "nibs", 0); raw(&o, "[");
    for (i = 0; i < n_nibs; i++) {
        const RrNib *x = &nibs[i];
        raw(&o, i ? ",\n {" : "\n {");
        kstr(&o, "path", x->path, 1);
        kstr(&o, "format", x->format, 0);
        kstr(&o, "sha256_in", x->sha256_in, 0);
        kstr(&o, "sha256_out", x->sha256_out, 0);
        key(&o, "written", 0); raw(&o, x->written ? "true" : "false");
        raw(&o, "}");
    }
    raw(&o, "]");
    key(&o, "findings", 0); raw(&o, "[");
    for (i = 0; i < f->n; i++) {
        const RFinding *x = &f->v[i];
        raw(&o, i ? ",\n {" : "\n {");
        kstr(&o, "kind", x->kind, 1);
        kstr(&o, "nib", x->nib, 0);
        kstr(&o, "item", x->item, 0);
        kstr(&o, "detail", x->detail, 0);
        kstr(&o, "severity", rf_severity_name(x->sev), 0);
        kstr(&o, "deviation", x->deviation, 0);
        raw(&o, "}");
    }
    raw(&o, "]");
    key(&o, "exceptions", 0); raw(&o, "[");
    for (i = 0; ex && i < ex->n; i++) {
        raw(&o, i ? ",\n {" : "\n {");
        kstr(&o, "line", ex->v[i].line, 1);
        key(&o, "applied", 0); raw(&o, "[");
        for (j = 0; j < ex->v[i].n_applied; j++) { if (j) raw(&o, ","); str(&o, ex->v[i].applied[j]); }
        raw(&o, "]}");
    }
    raw(&o, "]}\n");
    if (o.bad) {
        free(o.b);
        fprintf(stderr, "drydock-resources: out of memory; no report written\n");
        return 4;
    }
    rc = publish(path, &o);
    free(o.b);
    return rc;
}
