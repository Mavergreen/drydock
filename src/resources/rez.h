/* rez.h -- an RGraph as Rez-style text a person can read, diff and edit, and that text read back. */

#ifndef DRYDOCK_RESOURCES_REZ_H
#define DRYDOCK_RESOURCES_REZ_H

#include "graph.h"

/* 0 with *out a malloc'd buffer of *outn bytes (not NUL-terminated); or 4 with why set: out of memory, or a name
 * so long its line would be one rez_parse refuses. The same graph always writes the same bytes, on every host. */
int rez_write(const RGraph *g, char **out, size_t *outn, char *why, size_t whysz);
/* 0; or 4 with *out empty and why = "malformed-dump: line N: <what>", or another reason on out of memory. text
 * need not be NUL-terminated. */
int rez_parse(const char *text, size_t n, RGraph *out, char *why, size_t whysz);

#endif
