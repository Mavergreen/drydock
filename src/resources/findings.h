/* findings.h -- what a target can't honour in a nib's graph, found exhaustively and never stopping at the first. */

#ifndef DRYDOCK_RESOURCES_FINDINGS_H
#define DRYDOCK_RESOURCES_FINDINGS_H

#include "graph.h"

/* RF_ADAPTED: a rewrite an adaptation rule made, logged as kind "adapted". */
typedef enum { RF_BLOCK_WRITE, RF_FINDING, RF_WILL_ADAPT, RF_ADAPTED } RfSeverity;
/* kind: nibarchive-format, class-missing, unresolved-chain, unknown-key, named-color-missing, storyboard, unencodable,
 * translate-autoresizing, wrapping-width, no-floor-nib, no-nib or adapted. item: the class, key, colour name or rule. nib: as the caller
 * named it (NULL from ra_apply, which has none). deviation: the accepted gap that covers it, or NULL. */
typedef struct { char *kind, *nib, *item, *detail; RfSeverity sev; char *deviation; } RFinding;
typedef struct { RFinding *v; size_t n; } RFindings;
typedef struct RAdaptSet RAdaptSet;
typedef struct RfRefs RfRefs;

/* The reference data findings are judged against: refdir_resources' keys-10.9.tsv, and refdir_objc's
 * floor-runtime.tsv and newer-sdk.tsv for named colours and NSStoryboard. NULL if a table is unreadable or a row
 * malformed, or out of memory. */
RfRefs *rf_open(const char *refdir_resources, const char *refdir_objc);
void rf_close(RfRefs *r);
/* Appends every finding for g, a nib at nib_relpath, on target, with adapt saying which rules will rewrite what:
 * 0, or 4 out of memory. g's chains are used as they are (rc_resolve's, a dump's, or a keyed archive's own). An
 * unresolved chain blocks writing when an object the keyed archive stores has its class (ka_stores); one only an
 * NSClassSwapper names is an ordinary finding, since the archive never carries it. */
int rf_check(const RfRefs *r, const RGraph *g, const char *nib_relpath, const char *target, const RAdaptSet *adapt,
             RFindings *out);
/* Appends the storyboard finding for a .storyboardc at relpath when the target has no NSStoryboard: 0, or 4. */
int rf_storyboard(const RfRefs *r, const char *relpath, const char *target, RFindings *out);

#define RF_CLASS_MAX 1025
/* The class obj stands for: an NSClassSwapper's NSOriginalClassName (copied into buf), else its own class. */
const char *rf_class_of(const RGraph *g, uint32_t obj, char buf[RF_CLASS_MAX]);
/* 0, or -1 out of memory; detail is printf-formatted. */
int rf_add(RFindings *f, const char *kind, const char *nib, const char *item, RfSeverity sev, const char *fmt, ...);
const char *rf_severity_name(RfSeverity s);   /* blocks-write, finding, will-adapt, adapted */
void rf_free(RFindings *f);
/* Sorts f by (nib, kind, item, detail). */
void rf_sort(RFindings *f);
/* 1 when x blocks: an RF_FINDING or RF_BLOCK_WRITE no accepted gap covers. */
int  rf_blocks(const RFinding *x);

/* Accepted gaps, one per line of an exceptions file: NIB_GLOB<TAB>KIND<TAB>ITEM<TAB>REASON. line: the line as written;
 * applied: "NIB: KIND ITEM" for each finding it covers. */
typedef struct { char *line, *glob, *kind, *item, *reason; char **applied; size_t n_applied; } RfException;
typedef struct { RfException *v; size_t n; } RfExceptions;
/* 0; or 4 with why set when the file is unreadable, a line is not four non-empty fields, its NIB_GLOB is wildcards
 * alone, or its KIND is no finding kind; or out of memory. Empty lines are skipped. */
int  rf_exceptions_read(const char *path, RfExceptions *out, char *why, size_t whysz);
/* Marks each RF_FINDING or RF_BLOCK_WRITE in f that a line matches (NIB_GLOB fnmatch'ed against its nib, KIND and ITEM
 * exact) with deviation "KIND:ITEM". An accepted storyboard finding covers every finding in that .storyboardc's nibs
 * too, since 10.9 loads none of them. 0, or 4 out of memory. */
int  rf_except(RfExceptions *ex, RFindings *f);
void rf_exceptions_free(RfExceptions *ex);

#endif
