/* attest.h -- the bounded MH_OBJECT and ar(5) readers provider.c and the undecoded-bytes sweep share, and the
 * objects a link map names, found for the sweep. Nothing is executed or loaded. */
#ifndef OBJC_ATTEST_H
#define OBJC_ATTEST_H
#include "report.h"
#include <mach-o/nlist.h>

#define OBJC_ARCHIVE_MAX (256u << 20)

typedef struct { char seg[17], sect[17], name[36]; uint64_t addr, size; uint32_t off, flags, reloff, nreloc; } OSect;
typedef struct {
    char name[256], sha[65];
    const uint8_t *buf; size_t size;
    OSect *sects; uint32_t nsects;
    struct nlist_64 *nl; uint32_t nsyms;
    const char *strtab; uint32_t strsize;
} OMember;
typedef struct { uint8_t *buf; size_t size; OMember *m; size_t n; } OArchive;

const char *objc_obj_sym_name(const OMember *m, uint32_t i);
int objc_obj_defined(const struct nlist_64 *n);
enum { OBJC_OBJ_NOT_X86_64 = 1, OBJC_OBJ_MALFORMED = 2 };
/* Parses m->buf: 0; OBJC_OBJ_NOT_X86_64 or OBJC_OBJ_MALFORMED with WHY ("member NAME ..."); -1 out of memory,
 * WHY naming what. Whatever it allocated is m->sects and m->nl, freed by the caller either way. */
int objc_obj_parse(OMember *m, char *why, size_t n);
/* A provider archive: every member parsed, two of one name refused (malformed-provider-archive). 0 or 4. */
int objc_archive_open(ObjcAnalysis *a, const char *path, OArchive *ar);
void objc_archive_free(OArchive *ar);
OMember *objc_archive_member(OArchive *ar, const char *name);

typedef struct ObjcObject ObjcObject;
/* The parsed x86_64 MH_OBJECT behind map file index FILE: 0 with *out set, or 0 with *out NULL and *why a
 * short reason. A plain path or ARCHIVE that exists is used as is; otherwise its basename must be in exactly
 * one --object-dir. Cached per file index. Nonzero only for out-of-memory and I/O errors. */
int objc_attest_object(ObjcAnalysis *a, long file, const ObjcObject **out, const char **why);
/* Whether the 4 image BYTES at VA, read as a reference to TARGET, were fixed by their object's assembler and
 * name nothing of that object's section: 1 when they are; 0 with *why saying why not; -1 out of memory or an
 * I/O error, recorded. */
int objc_attest_window(ObjcAnalysis *a, uint64_t va, const uint8_t *bytes, uint64_t target, const char **why);
/* Frees the link map, the object directories and every cached object. */
void objc_attest_free(ObjcAnalysis *a);

#endif
