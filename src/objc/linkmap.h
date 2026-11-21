/* linkmap.h -- an ld64/lld -map file, parsed once for the provider mapping and the sweep's attestation. */
#ifndef OBJC_LINKMAP_H
#define OBJC_LINKMAP_H
#include "report.h"

typedef struct { char *path; char *archive; char *member; } ObjcMapFile;
typedef struct { uint64_t addr, size; char seg[17], sect[17]; } ObjcMapSect;
/* Sorted by addr; file indexes ObjcLinkMap.files (-1 when the map lists no such object file). */
typedef struct { uint64_t addr, size; long file; char *name; } ObjcMapAtom;
typedef struct ObjcLinkMap {
    char arch[16];
    ObjcMapFile *files; size_t nfiles;
    ObjcMapSect *sects; size_t nsects;
    ObjcMapAtom *atoms; size_t natoms;
    char *path;
} ObjcLinkMap;

int objc_linkmap_read(ObjcAnalysis *a, const char *path, ObjcLinkMap *out);
void objc_linkmap_free(ObjcLinkMap *m);
const ObjcMapAtom *objc_linkmap_atom_at(const ObjcLinkMap *m, uint64_t va);
int objc_linkmap_check_image(ObjcAnalysis *a, const ObjcLinkMap *m, const char *final, const char *prestrip);

#endif
