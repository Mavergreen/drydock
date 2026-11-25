/* keyed.h -- an RGraph as an NSKeyedArchiver archive, the keyed-archive nib OS X 10.9 loads, and such an archive read
 * back into a graph. */

#ifndef DRYDOCK_RESOURCES_KEYED_H
#define DRYDOCK_RESOURCES_KEYED_H

#include "bplist.h"
#include "graph.h"

/* 0 with *archive a new tree for bp_write; 1 with why = "unencodable: <what>" when the graph cannot be written as a
 * keyed archive without guessing (an unresolved chain of a class it stores, invalid UTF-8 in a string, an odd
 * dictionary, ...); 4 with why = "out of memory". A NIBArchive graph is mapped by the NIBArchive-to-keyed rules; a keyed graph, which ka_read
 * made, is written back in its own shape, so keyed -> dump -> build is a fixed point. */
int ka_from_graph(const RGraph *g, BpNode **archive, char *why, size_t whysz);
/* Whether ka_from_graph stores object obj as a dictionary whose class entry carries its chain: every object but the
 * top and the plain strings, numbers and data. Of the chains no such object names, only NSArray's is ever written. */
int ka_stores(const RGraph *g, uint32_t obj);
/* 0; or 4 with *out empty and why = "malformed-keyed: <what>", or bp_read's "malformed-bplist: ..." reason, or "out of
 * memory". Memory and time stay linear in n: names are interned once per plist object, and a string or data value
 * the plist shares between many references is copied for each only within a budget proportional to n. */
int ka_read(const uint8_t *buf, size_t n, RGraph *out, char *why, size_t whysz);

#endif
