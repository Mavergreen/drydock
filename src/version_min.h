#ifndef DRYDOCK_VERSION_MIN_H
#define DRYDOCK_VERSION_MIN_H
/*
 * mv_ -- the minimum OS a Mach-O declares. mv_declare_minos is `minos
 * at-most` and `minos if-absent` against an image in memory;
 * mv_format_version prints a packed version the way every report does.
 */
#include "image.h"

#define MV_PLATFORM_MACOS 1   /* LC_BUILD_VERSION.platform */
#define MV_10_9 0x000A0900u

void mv_format_version(uint32_t v, char out[16]);

#define MV_PLATFORM_MACCATALYST 6   /* LC_BUILD_VERSION.platform */

enum { MV_AT_MOST, MV_IF_ABSENT };                                /* the rule */
enum { MV_FROM_NONE, MV_FROM_VERSION_MIN, MV_FROM_BUILD_VERSION };  /* where D was read */

/* What mv_declare_minos read and wrote, for the report. */
typedef struct {
    int      from;           /* MV_FROM_* */
    uint32_t declared;       /* D, when from is not MV_FROM_NONE */
    int      above;          /* D is above VERSION, at VERSION's precision */
    uint32_t minos, sdk;     /* the LC_VERSION_MIN_MACOSX the slice ends with */
    int      dropped_macos;  /* a macOS LC_BUILD_VERSION removed beside a version-min */
    uint32_t dropped_minos;  /* ... and its minos */
    int      catalyst;       /* Mac Catalyst LC_BUILD_VERSIONs removed */
    int      changed;        /* any byte of the slice changed */
} mv_decl_report;

/* Leave the image in *pbuf with exactly one LC_VERSION_MIN_MACOSX and no
 * LC_BUILD_VERSION. `rule` and `version` (with the mask ms_parse_version gave)
 * decide the minimum; the sdk is the declaring command's, or 10.9 when
 * nothing was declared. Returns 0, or MR_REFUSED with the reason on stderr
 * prefixed by `label`. A grow may reallocate *pbuf. */
int mv_declare_minos(uint8_t **pbuf, size_t *psize, const char *label, int rule,
                     uint32_t version, uint32_t mask, mv_decl_report *r);

#endif /* DRYDOCK_VERSION_MIN_H */
