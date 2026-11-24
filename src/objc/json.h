#ifndef DRYDOCK_OBJC_JSON_H
#define DRYDOCK_OBJC_JSON_H
/* json.h -- strict JSON input on Jansson: UTF-8 only, no duplicate key, integers within long long. */
#include "report.h"
#include <jansson.h>
#include <stddef.h>
#include <stdint.h>

/* PATH, a regular file of at most MAX bytes holding one JSON object: a new reference to it, or NULL after
 * objc_fail(unreadable-input|oversized-input|malformed-input). WHAT names it in the error. */
json_t *objc_read_json(ObjcAnalysis *a, const char *path, size_t max, const char *what);
/* O's member K when it is a string (UTF-8), an array or an object, else NULL. The latter two are borrowed. */
const char *objc_jstr(const json_t *o, const char *k);
json_t *objc_jarr(const json_t *o, const char *k);
json_t *objc_jobj(const json_t *o, const char *k);
/* V is an integer (not a real, not a boolean) equal to N. */
int objc_jis_int(const json_t *v, long long n);
/* V is an integer above 0, stored in *OUT. */
int objc_jcount(const json_t *v, uint64_t *out);
/* O is an object whose keys are exactly the N distinct KEYS, in any order. */
int objc_jexact_keys(const json_t *o, const char *const *keys, size_t n);
/* O's first key, in document order, that is not among the N ALLOWED; NULL if none. */
const char *objc_jfirst_unknown(const json_t *o, const char *const *allowed, size_t n);
#endif
