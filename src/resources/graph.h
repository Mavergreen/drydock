/* graph.h -- the in-memory object graph every nib format is read into and written from. */

#ifndef DRYDOCK_RESOURCES_GRAPH_H
#define DRYDOCK_RESOURCES_GRAPH_H

#include <stddef.h>
#include <stdint.h>

typedef enum { RV_I8, RV_I16, RV_I32, RV_I64, RV_TRUE, RV_FALSE, RV_F32, RV_F64,
               RV_DATA, RV_NIL, RV_REF, RV_STRING, RV_UID_ARRAY } RvType;   /* order = NIBArchive type codes 0..10, then keyed-only */
typedef struct { const char *key; RvType type; union { int64_t i; double f; struct { uint8_t *p; size_t n; } d; uint32_t ref;
                 struct { uint32_t *v; size_t n; } refs; } u; } RValue;
typedef struct { const char *cls; RValue *vals; size_t n_vals; } RObject;
typedef struct { char *cls; char **chain; size_t n_chain; int resolved; char *newer; } RChain;   /* chain[0] == cls; newer: the
                * newest newer-sdk.tsv version past the target the chain needed ("?" unstated), or NULL */
typedef enum { RF_NIBARCHIVE, RF_KEYED } RFormat;
typedef struct { RFormat format; uint32_t na_header[2]; RObject *objs; size_t n_objs;
                 RChain *chains; size_t n_chains; char **strs; size_t n_strs; } RGraph;

/* Keys and class names live in the graph's string table. rg_intern appends a copy of n bytes and returns it (NULL
 * if out of memory or the bytes hold a NUL); it never looks for an earlier copy, so a reader interns once per entry
 * of its source's own name table, never once per use. rg_add_object's cls and rg_add_value's v->key must be such
 * copies; only rg_free frees them. */
void rg_free(RGraph *g);
const char *rg_intern(RGraph *g, const char *s, size_t n);
int  rg_add_object(RGraph *g, const char *cls);                   /* returns index or -1 */
int  rg_add_value(RGraph *g, uint32_t obj, const RValue *v);      /* copies all but the key */
const RValue *rg_get(const RGraph *g, uint32_t obj, const char *key);   /* first match or NULL */
const RChain *rg_chain(const RGraph *g, const char *cls);        /* g->chains is sorted by cls (rc_resolve) */

#endif
