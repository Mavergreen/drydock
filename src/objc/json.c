/* json.c -- strict JSON input on Jansson (json.h). */
#include "json.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

json_t *objc_read_json(ObjcAnalysis *a, const char *path, size_t max, const char *what) {
    static int seeded;
    struct stat st;
    json_error_t err;
    FILE *f = NULL;
    char *buf;
    size_t len;
    json_t *v;
    if (stat(path, &st) != 0) {
        objc_fail(a, "unreadable-input", NULL, 0, "%s %s: %s", what, path, strerror(errno ? errno : EINVAL));
        return NULL;
    }
    if (!S_ISREG(st.st_mode)) {
        objc_fail(a, "unreadable-input", NULL, 0, "%s %s: %s", what, path, strerror(EINVAL));
        return NULL;
    }
    if ((unsigned long long)st.st_size > max) {
        objc_fail(a, "oversized-input", NULL, 0, "%s %s: %lld bytes, limit %zu", what, path, (long long)st.st_size, max);
        return NULL;
    }
    len = (size_t)st.st_size;
    if (!(buf = malloc(len + 1))) { objc_fail(a, "out-of-memory", NULL, 0, "%s %s", what, path); return NULL; }
    if (!(f = fopen(path, "rb")) || fread(buf, 1, len + 1, f) != len || ferror(f)) {
        if (f) fclose(f);
        free(buf);
        objc_fail(a, "unreadable-input", NULL, 0, "%s %s: read failed", what, path);
        return NULL;
    }
    fclose(f);
    if (!seeded) { json_object_seed(1); seeded = 1; }
    v = json_loadb(buf, len, JSON_REJECT_DUPLICATES, &err);
    free(buf);
    if (!v) {
        objc_fail(a, "malformed-input", NULL, 0, "%s %s: not a JSON object (%s at line %d column %d)", what, path,
                  err.text, err.line, err.column);
        return NULL;
    }
    if (!json_is_object(v)) {
        json_decref(v);
        objc_fail(a, "malformed-input", NULL, 0, "%s %s: not a JSON object (wrong type)", what, path);
        return NULL;
    }
    return v;
}

const char *objc_jstr(const json_t *o, const char *k) {
    json_t *v = json_is_object(o) ? json_object_get(o, k) : NULL;
    return json_is_string(v) ? json_string_value(v) : NULL;
}
json_t *objc_jarr(const json_t *o, const char *k) {
    json_t *v = json_is_object(o) ? json_object_get(o, k) : NULL;
    return json_is_array(v) ? v : NULL;
}
json_t *objc_jobj(const json_t *o, const char *k) {
    json_t *v = json_is_object(o) ? json_object_get(o, k) : NULL;
    return json_is_object(v) ? v : NULL;
}

int objc_jis_int(const json_t *v, long long n) {
    return json_is_integer(v) && json_integer_value(v) == n;
}
int objc_jcount(const json_t *v, uint64_t *out) {
    if (!json_is_integer(v) || json_integer_value(v) <= 0) return 0;
    *out = (uint64_t)json_integer_value(v);
    return 1;
}

static int among(const char *k, const char *const *keys, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) if (!strcmp(k, keys[i])) return 1;
    return 0;
}
int objc_jexact_keys(const json_t *o, const char *const *keys, size_t n) {
    size_t i;
    if (!json_is_object(o) || json_object_size(o) != n) return 0;
    for (i = 0; i < n; i++) if (!json_object_get(o, keys[i])) return 0;
    return 1;
}
const char *objc_jfirst_unknown(const json_t *o, const char *const *allowed, size_t n) {
    void *it;
    if (!json_is_object(o)) return NULL;
    for (it = json_object_iter((json_t *)o); it; it = json_object_iter_next((json_t *)o, it))
        if (!among(json_object_iter_key(it), allowed, n)) return json_object_iter_key(it);
    return NULL;
}
