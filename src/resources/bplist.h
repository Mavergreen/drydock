/* bplist.h -- read and write binary property lists (bplist00), the container of a keyed-archive nib. */

#ifndef DRYDOCK_RESOURCES_BPLIST_H
#define DRYDOCK_RESOURCES_BPLIST_H

#include <stddef.h>
#include <stdint.h>

typedef enum { BP_NULL, BP_BOOL, BP_INT, BP_REAL, BP_STRING, BP_DATA, BP_UID, BP_ARRAY, BP_DICT } BpType;
typedef struct BpNode BpNode;   /* tree; dict keys kept in insertion order */

/* Constructors return NULL when out of memory. A string is UTF-8 (NUL allowed); bp_string returns NULL for bytes that
 * are not valid UTF-8 (overlong, a surrogate, past U+10FFFF). bp_real is written as an 8-byte real (0x23); bp_real32
 * keeps a 4-byte real's 32 raw bits and is written back as 0x22 with exactly those bits. bp_uid returns NULL past
 * UINT32_MAX, which CoreFoundation refuses to read. */
BpNode *bp_null(void), *bp_int(int64_t), *bp_real(double), *bp_real32(uint32_t bits), *bp_bool(int),
       *bp_string(const char *, size_t), *bp_data(const uint8_t *, size_t), *bp_uid(uint64_t), *bp_array(void),
       *bp_dict(void);
/* Both take ownership of v, even on failure (then v is freed); 0, or -1 if v is NULL, the container is the wrong
 * type, or out of memory. bp_set appends: it never looks for an earlier entry with the same key. A node already in a
 * tree (one from bp_read, say) goes into another as bp_retain(v), which adds a reference and returns v; each tree's
 * bp_free then drops its own. */
BpNode *bp_retain(BpNode *v);
int bp_push(BpNode *array, BpNode *v);
int bp_set(BpNode *dict, const char *key, BpNode *v);
/* 0 with a malloc'd *out, or -1 when out of memory. Objects are numbered depth-first in insertion order (a dict's
 * key, then its value). Strings, keys included, are written once per distinct content; any other node is written
 * once per node, so numbers and UIDs built separately are not merged, while a leaf the reader shared stays shared. */
int bp_write(const BpNode *root, uint8_t **out, size_t *n);
/* 0, or 4 with *root NULL and why = "malformed-bplist: <what> at <offset>" ("out of memory" when it is that).
 * Memory and time stay linear in n: a string, number, data or UID object referenced from several places is read
 * once and shared (bp_free counts the references), as is an empty array or dict (Apple's writer shares those), while
 * any other array or dict referenced twice is refused as a shared or cyclic container, as is nesting deeper than BP_MAX_DEPTH. Each object's bytes are charged once against the
 * object region, so offset-table entries that alias or overlap one object are refused as overlapping objects.
 * Accepted: null, bools, ints of 1/2/4/8 bytes and of 16 bytes when the value fits int64_t, 4- and 8-byte reals,
 * data, ASCII and UTF-16 strings (validated: ASCII bytes under 0x80, surrogates paired), UIDs of 1-16 bytes up to
 * UINT32_MAX, arrays, and dicts with string keys. Refused: dates, sets and any other marker. Objects the top object
 * never reaches are not read. */
#define BP_MAX_DEPTH 512
int bp_read(const uint8_t *buf, size_t n, BpNode **root, char *why, size_t whysz);
void bp_free(BpNode *);

/* Accessors; each expects the named type. A string's bytes are UTF-8 and NUL-terminated past n. */
BpType bp_type(const BpNode *);
int64_t bp_int_value(const BpNode *);        /* BP_INT */
int bp_bool_value(const BpNode *);           /* BP_BOOL */
uint64_t bp_uid_value(const BpNode *);       /* BP_UID */
int bp_real_width(const BpNode *);           /* BP_REAL: 4 or 8 */
uint64_t bp_real_bits(const BpNode *);       /* BP_REAL: raw bits, the low 32 when the width is 4 */
double bp_real_value(const BpNode *);        /* BP_REAL, a 4-byte one widened */
const uint8_t *bp_bytes(const BpNode *, size_t *n);   /* BP_STRING or BP_DATA */
size_t bp_count(const BpNode *);             /* BP_ARRAY elements or BP_DICT entries */
BpNode *bp_at(const BpNode *array, size_t i);
const BpNode *bp_key_at(const BpNode *dict, size_t i);   /* a BP_STRING */
BpNode *bp_value_at(const BpNode *dict, size_t i);
BpNode *bp_get(const BpNode *dict, const char *key);     /* first entry whose key is exactly key, or NULL */
/* The object number a node was read from, so a caller can index per object rather than per reference; -1 if built. */
int64_t bp_object_index(const BpNode *);

#endif
