/* Test-only harness for keyed.c, each input handed over in a buffer of exactly its size so guard malloc and ASan see
 * a read past its last byte:
 *   resources-keyed-driver read NIB              ka_read, then rez_write to stdout
 *   resources-keyed-driver build TEXT            rez_parse, ka_from_graph, then bp_write to stdout
 *   resources-keyed-driver plist TEXT            a plist written from resources-bplist-driver's dump format, so a
 *                                                test can edit an archive's dump and write it back
 *   resources-keyed-driver shared WHAT K BYTES   an archive whose one BYTES-long string is shared by K references:
 *                                                K bare $objects entries (bare), K object values (value), or K
 *                                                names in one class entry's $classes (chain)
 * Exit 0; 1 unencodable; 4 malformed (why on stderr, nothing on stdout); 2 usage, unreadable or out of memory. */
#include "bplist.h"
#include "keyed.h"
#include "rez.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *slurp(const char *path, size_t *outn) {
    FILE *f;
    uint8_t *buf, *more;
    size_t n = 0, cap = 1 << 16;
    if (!(f = fopen(path, "rb"))) { perror(path); return NULL; }
    if (!(buf = malloc(cap))) { fclose(f); fprintf(stderr, "%s: out of memory\n", path); return NULL; }
    for (;;) {
        n += fread(buf + n, 1, cap - n, f);
        if (n < cap) break;
        if (cap >= (size_t)1 << 28 || !(more = realloc(buf, cap * 2))) {
            fprintf(stderr, "%s: %s\n", path, cap >= (size_t)1 << 28 ? "larger than 256 MiB" : "out of memory");
            free(buf);
            fclose(f);
            return NULL;
        }
        buf = more;
        cap *= 2;
    }
    if (ferror(f)) { perror(path); free(buf); fclose(f); return NULL; }
    fclose(f);
    if (!(more = malloc(n ? n : 1))) { free(buf); fprintf(stderr, "%s: out of memory\n", path); return NULL; }
    memcpy(more, buf, n);
    free(buf);
    *outn = n;
    return more;
}

static int emit(BpNode *root) {
    uint8_t *out;
    size_t n;
    int rc;
    if (!root || bp_write(root, &out, &n)) { bp_free(root); fprintf(stderr, "out of memory\n"); return 2; }
    bp_free(root);
    rc = fwrite(out, 1, n, stdout) != n || fflush(stdout) ? 2 : 0;
    free(out);
    return rc;
}

/* ---- the bplist driver's dump format, read back ---- */

typedef struct { char **lines; size_t n, at; } Lines;

static int depth_of(const char *s) {
    int d = 0;
    while (s[d] == ' ') d++;
    return d / 2;
}

static int hexv(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1; }

/* "..." or bytesN:hex at *p into a malloc'd buffer; advances *p. */
static uint8_t *bytes(const char **p, size_t *n) {
    const char *s = *p, *e;
    uint8_t *b;
    size_t i;
    if (*s == '"') {
        if (!(e = strchr(s + 1, '"'))) return NULL;
        *n = (size_t)(e - s - 1);
        if (!(b = malloc(*n + 1))) return NULL;
        memcpy(b, s + 1, *n);
        b[*n] = 0;
        *p = e + 1;
        return b;
    }
    if (strncmp(s, "bytes", 5)) return NULL;
    *n = strtoul(s + 5, (char **)&e, 10);
    if (*e++ != ':' || !(b = malloc(*n + 1))) return NULL;
    for (i = 0; i < *n; i++) {
        if (hexv(e[2 * i]) < 0 || hexv(e[2 * i + 1]) < 0) { free(b); return NULL; }
        b[i] = (uint8_t)(hexv(e[2 * i]) << 4 | hexv(e[2 * i + 1]));
    }
    b[*n] = 0;
    *p = e + 2 * *n;
    return b;
}

static BpNode *node(Lines *L, int depth);

static int children(Lines *L, int depth, BpNode *c, int dict) {
    while (L->at < L->n && depth_of(L->lines[L->at]) == depth + 1) {
        const char *s = L->lines[L->at] + 2 * (depth + 1);
        BpNode *v;
        if (dict) {
            size_t kn;
            uint8_t *k = bytes(&s, &kn);
            if (!k || strncmp(s, " = ", 3)) { free(k); return -1; }
            L->lines[L->at] = (char *)s + 3 - 2 * (depth + 1);
            v = node(L, depth + 1);
            if (!v || bp_set(c, (const char *)k, v)) { free(k); return -1; }
            free(k);
        } else if (!(v = node(L, depth + 1)) || bp_push(c, v))
            return -1;
    }
    return 0;
}

static BpNode *node(Lines *L, int depth) {
    const char *s = L->lines[L->at++] + 2 * depth;
    BpNode *v = NULL;
    uint8_t *b;
    size_t n;
    if (!strncmp(s, "dict ", 5)) { if ((v = bp_dict()) && children(L, depth, v, 1)) { bp_free(v); v = NULL; } }
    else if (!strncmp(s, "array ", 6)) { if ((v = bp_array()) && children(L, depth, v, 0)) { bp_free(v); v = NULL; } }
    else if (!strncmp(s, "int ", 4)) v = bp_int(strtoll(s + 4, NULL, 10));
    else if (!strncmp(s, "uid ", 4)) v = bp_uid(strtoull(s + 4, NULL, 10));
    else if (!strncmp(s, "bool ", 5)) v = bp_bool(atoi(s + 5));
    else if (!strncmp(s, "real32 ", 7)) v = bp_real32((uint32_t)strtoul(s + 7, NULL, 16));
    else if (!strncmp(s, "real ", 5)) v = bp_real(strtod(s + 5, NULL));
    else if (!strcmp(s, "null")) v = bp_null();
    else if (!strncmp(s, "string ", 7) || !strncmp(s, "data ", 5)) {
        int str = s[0] == 's';
        s += str ? 7 : 5;
        if ((b = bytes(&s, &n))) {
            v = str ? bp_string((const char *)b, n) : bp_data(b, n);
            free(b);
        }
    }
    if (!v) fprintf(stderr, "plist: cannot read line %lu: %s\n", (unsigned long)L->at, s);
    return v;
}

static int plist(const char *path) {
    size_t n, i;
    char *text = (char *)slurp(path, &n), *p, **lines;
    Lines L;
    BpNode *root;
    if (!text || !(p = realloc(text, n + 1))) { free(text); return 2; }
    text = p;
    text[n] = 0;
    for (L.n = 0, i = 0; i < n; i++) L.n += text[i] == '\n';
    if (!(lines = calloc(L.n + 1, sizeof *lines))) { free(text); return 2; }
    for (L.n = 0, p = strtok(text, "\n"); p; p = strtok(NULL, "\n")) lines[L.n++] = p;
    L.lines = lines;
    L.at = 0;
    root = L.n ? node(&L, 0) : NULL;
    free(lines);
    free(text);
    if (!root) return 2;
    return emit(root);
}

/* ---- hostile sharing ---- */

static int shared(const char *what, long k, long size) {
    BpNode *root = bp_dict(), *top = bp_dict(), *objs = bp_array(), *s, *d, *a;
    char *big = malloc((size_t)size);
    long i;
    int ok = root && top && objs && big;
    if (ok) memset(big, 'x', (size_t)size);
    s = ok ? bp_string(big, (size_t)size) : NULL;
    free(big);
    ok = ok && s && !bp_set(root, "$version", bp_int(100000)) && !bp_set(root, "$archiver", bp_string("NSKeyedArchiver", 15)) &&
         !bp_set(root, "$top", top) && !bp_set(root, "$objects", objs) &&
         !bp_push(objs, bp_string("$null", 5));
    top = NULL;
    if (ok && !strcmp(what, "bare")) {
        for (i = 0; ok && i < k; i++) ok = !bp_push(objs, bp_retain(s));
    } else if (ok && !strcmp(what, "value")) {
        ok = (d = bp_dict()) && !bp_set(d, "$classname", bp_string("C", 1)) && (a = bp_array()) &&
             !bp_push(a, bp_string("C", 1)) && !bp_set(d, "$classes", a);
        ok = ok && !bp_push(objs, d);   /* $objects[1] is the class: root refers to object 2 instead */
        ok = ok && (d = bp_dict()) && !bp_set(d, "$class", bp_uid(1));
        for (i = 0; ok && i < k; i++) {
            char key[32];
            snprintf(key, sizeof key, "k%ld", i);
            ok = !bp_set(d, key, bp_retain(s));
        }
        ok = ok && !bp_push(objs, d);
    } else if (ok && !strcmp(what, "chain")) {
        ok = (d = bp_dict()) && !bp_set(d, "$classname", bp_string("C", 1)) && (a = bp_array()) &&
             !bp_push(a, bp_string("C", 1));
        for (i = 0; ok && i < k; i++) ok = !bp_push(a, bp_retain(s));
        ok = ok && !bp_set(d, "$classes", a) && !bp_push(objs, d);
        ok = ok && (d = bp_dict()) && !bp_set(d, "$class", bp_uid(1)) && !bp_push(objs, d);
    } else
        ok = 0;
    bp_free(s);
    bp_free(top);
    if (!ok) { bp_free(root); fprintf(stderr, "shared: cannot build\n"); return 2; }
    return emit(root);
}

int main(int argc, char **argv) {
    uint8_t *in;
    char *out, why[512];
    size_t n, outn;
    RGraph g;
    BpNode *archive;
    int rc;
    if (argc == 5 && !strcmp(argv[1], "shared")) return shared(argv[2], atol(argv[3]), atol(argv[4]));
    if (argc != 3 || (strcmp(argv[1], "read") && strcmp(argv[1], "build") && strcmp(argv[1], "plist"))) {
        fprintf(stderr, "usage: resources-keyed-driver read NIB | build TEXT | plist TEXT | shared bare|value|chain K BYTES\n");
        return 2;
    }
    if (!strcmp(argv[1], "plist")) return plist(argv[2]);
    if (!(in = slurp(argv[2], &n))) return 2;
    if (!strcmp(argv[1], "read")) {
        rc = ka_read(in, n, &g, why, sizeof why);
        free(in);
        if (rc) { fprintf(stderr, "%s\n", why); return rc; }
        rc = rez_write(&g, &out, &outn, why, sizeof why);
        rg_free(&g);
        if (rc) { fprintf(stderr, "%s\n", why); return rc; }
        rc = fwrite(out, 1, outn, stdout) != outn || fflush(stdout) ? 2 : 0;
        if (rc) perror("stdout");
        free(out);
        return rc;
    }
    rc = rez_parse((const char *)in, n, &g, why, sizeof why);
    free(in);
    if (rc) { fprintf(stderr, "%s\n", why); return rc; }
    rc = ka_from_graph(&g, &archive, why, sizeof why);
    rg_free(&g);
    if (rc) { fprintf(stderr, "%s\n", why); return rc; }
    return emit(archive);
}
