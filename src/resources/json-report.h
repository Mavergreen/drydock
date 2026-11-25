/* json-report.h -- the JSON report of a check or convert, written by hand, the same bytes on every host. */

#ifndef DRYDOCK_RESOURCES_REPORT_H
#define DRYDOCK_RESOURCES_REPORT_H

#include "findings.h"

/* One nib as the report lists it. format: "nibarchive" or "keyed"; sha256_out NULL when nothing was built. */
typedef struct { const char *path, *format, *sha256_in, *sha256_out; int written; } RrNib;

/* 0 when path names nothing yet and its directory exists; else 2 with the reason printed. */
int rr_check_dest(const char *path);
/* Writes the report as the new file path, never replacing one and never in part; f must be rf_sort'ed. tool:
 * "drydock-resources VERSION"; adapt: the rules on. 0, or 4 with the reason printed. */
int rr_write(const char *path, const char *tool, const char *verb, const char *target, int strict, const char *const *adapt,
             size_t n_adapt, const RrNib *nibs, size_t n_nibs, const RFindings *f, const RfExceptions *ex);
/* The lowercase hex SHA-256 of n bytes. */
void rr_sha256(const void *buf, size_t n, char out[65]);

#endif
