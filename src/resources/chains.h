/* chains.h -- superclass chains for every class a nib names, from the 10.9 reference tables and the bundle's own
 * Mach-O Objective-C metadata. A chain that cannot be walked to a root is unresolved, never guessed. */

#ifndef DRYDOCK_RESOURCES_CHAINS_H
#define DRYDOCK_RESOURCES_CHAINS_H

#include "graph.h"

typedef struct RChainSrc RChainSrc;

/* refdir holds floor-runtime.tsv and newer-sdk.tsv (share/drydock/objc/reference); NULL if either is unreadable
 * or a class row is malformed, or out of memory. A NULL refdir reads no tables, so only the binaries resolve. */
RChainSrc *rc_open(const char *refdir, const char *target);
/* 0; 1 with why set when the reader refuses the binary (no x86_64 slice, malformed, unreadable); -1 out of memory.
 * A readable binary that defines no classes adds nothing. */
int  rc_add_binary(RChainSrc *s, const char *macho_path, char *why, size_t whysz);
/* Replaces g->chains with one chain per class, sorted by class: each object's class, and each NSClassSwapper's
 * NSClassName and NSOriginalClassName. Classes come first from the binaries, then floor-runtime.tsv, then
 * newer-sdk.tsv, which sets the chain's newer to the newest version it needed. 0, or -1 out of memory. */
int  rc_resolve(RChainSrc *s, RGraph *g);
/* Sets newer on each resolved chain of g that has none, as rc_resolve would, from the classes the chain already
 * names; the chains themselves are kept, as a keyed archive stores them. 0, or -1 out of memory. */
int  rc_mark_newer(RChainSrc *s, RGraph *g);
void rc_close(RChainSrc *s);

#endif
