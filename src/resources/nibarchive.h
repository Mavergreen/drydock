/* nibarchive.h -- read a NIBArchive nib (ibtool's output for 10.13 and later) into an RGraph. */

#ifndef DRYDOCK_RESOURCES_NIBARCHIVE_H
#define DRYDOCK_RESOURCES_NIBARCHIVE_H

#include "graph.h"

/* 0; or 4 with *out empty and why = "malformed-nibarchive: <what> at <offset>", or another reason on out of memory. */
int na_read(const uint8_t *buf, size_t n, RGraph *out, char *why, size_t whysz);

#endif
