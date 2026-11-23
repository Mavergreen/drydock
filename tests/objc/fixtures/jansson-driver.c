#include <jansson.h>
#include <stdio.h>
#include <stdlib.h>

static const char *type_name(const json_t *v) {
    switch (json_typeof(v)) {
    case JSON_OBJECT: return "object";
    case JSON_ARRAY: return "array";
    case JSON_STRING: return "string";
    case JSON_INTEGER: return "integer";
    case JSON_REAL: return "real";
    case JSON_TRUE: return "true";
    case JSON_FALSE: return "false";
    case JSON_NULL: return "null";
    }
    return "unknown";
}

int main(void) {
    size_t len = 0, cap = 4096;
    char *buf = malloc(cap);
    size_t n;
    if (!buf) return 1;
    while ((n = fread(buf + len, 1, cap - len, stdin)) > 0) {
        len += n;
        if (len == cap) {
            char *bigger = realloc(buf, cap *= 2);
            if (!bigger) return 1;
            buf = bigger;
        }
    }
    if (ferror(stdin)) return 1;
    json_object_seed(1);
    json_error_t err;
    json_t *v = json_loadb(buf, len, JSON_REJECT_DUPLICATES, &err);
    if (!v) {
        printf("error %d:%d %s\n", err.line, err.column, err.text);
        free(buf);
        return 0;
    }
    printf("ok %s\n", type_name(v));
    json_decref(v);
    free(buf);
    return 0;
}
