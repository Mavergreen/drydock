#ifndef DRYDOCK_LINKEDIT_ORDER_H
#define DRYDOCK_LINKEDIT_ORDER_H
/*
 * mlo_ -- whether 10.9's codesign_allocate (cctools-862) can re-sign an
 * image, and whether it would re-sign it correctly; and the pass that puts
 * __LINKEDIT in the order it wants.
 *
 * mlo_check mirrors codesign_allocate's own checks (libstuff/ofile.c's load
 * command loop, libstuff/checkout.c's check_object, dyld_order and
 * symbol_string_at_end, misc/codesign_allocate.c's header room) and
 * simulates its writer (setup_code_signature, libstuff/writeout.c's
 * copy_new_symbol_info), which never updates an offset in a load command and
 * so must put every piece back exactly where it was. It evaluates every rule
 * and records every finding. It reads the image and allocates nothing.
 */
#include <stddef.h>
#include <stdint.h>

#include "image.h"

/* A finding's kind. */
enum {
    MLO_REFUSES = 1,   /* codesign_allocate refuses the image with `text` */
    MLO_CORRUPTS,      /* its writer would put a piece somewhere else */
    MLO_NOTE           /* neither, but worth saying (see mlo_check) */
};

#define MLO_MAX 32

typedef struct {
    int  kind;
    int  newer;        /* MLO_REFUSES only: a newer codesign_allocate may not
                        * refuse it (an unknown load command, header room) */
    int  order;        /* MLO_REFUSES only: a rule about where the pieces
                        * lie (dyld_order, symbol_string_at_end) */
    char text[200];    /* codesign_allocate's own words, where it has any; a
                        * "…" stands for words that name offsets or files */
} mlo_finding;

typedef struct {
    int         n;          /* findings kept, in the tool's order */
    int         dropped;    /* findings past MLO_MAX, counted only */
    mlo_finding f[MLO_MAX];
    int         refusal;    /* index of the first MLO_REFUSES finding, or -1 */
    int         corrupting; /* every MLO_REFUSES finding is `newer`, and the
                             * writer would move a piece */
} mlo_verdict;

/* Checks `im`, a 64-bit slice, into *v. */
void mlo_check(const mi_image *im, mlo_verdict *v);

/* One line for a whole file, thin or fat: every slice is checked, as
 * codesign_allocate checks every slice whatever it signs. `refusal` gets
 * "ok", the first slice's refusal ("slice x86_64h: " before it in a fat
 * file), or "not checked: …" for a slice mlo_check does not model; `corrupt`
 * gets "" or the pieces a corrupting slice's writer would move. Returns 0 when
 * the file would re-sign correctly on 10.9, 1 when 10.9 refuses it, 2 when
 * some slice is corrupting, -1 when `buf` is neither a 64-bit Mach-O nor a
 * fat container of them. */
int mlo_file_verdict(const uint8_t *buf, size_t size, char *refusal, size_t rsz,
                     char *corrupt, size_t csz);

/* mlo_pack's returns. */
enum { MLO_PACKED = 0, MLO_UNCHANGED = 1, MLO_DECLINED = 2, MLO_FAILED = -1, MLO_NOMEM = -2 };

typedef struct {
    uint64_t before, after;   /* __LINKEDIT's filesize */
    uint64_t dropped;         /* bytes of the old __LINKEDIT no piece covered */
} mlo_pack_report;

/* Rewrites the 64-bit slice buf[0..size) so its __LINKEDIT holds its pieces
 * in ld64's order: the dyld-info streams, a chained-fixups and an
 * exports-trie blob if any, local relocations, split info, function starts,
 * data in code, code-signing DRs, linker hints, the symbol table, two-level
 * hints, external relocations, the indirect table, the table of contents,
 * module and reference tables, the string table, and the code signature at
 * the next multiple of 16. Each piece keeps its bytes and its size; bytes no
 * piece covers are dropped; nothing below __LINKEDIT moves.
 *
 * MLO_PACKED: *pbuf and *psize are the packed image, and the old buffer is
 * freed. MLO_UNCHANGED: the image was already in that order, and is left
 * alone. MLO_DECLINED: `why` says what the pass cannot account for, and the
 * image is left alone. MLO_FAILED: a postcondition failed (`why`); the image
 * is left alone. MLO_NOMEM: likewise, for an allocation. */
int mlo_pack(uint8_t **pbuf, size_t *psize, mlo_pack_report *rep, char *why, size_t whysz);

/* Whether a run changed a piece of a slice: its set of pieces, any piece's
 * offset, size or bytes, or __LINKEDIT's fileoff or filesize. `a` is the
 * slice as read, `b` as the statements left it. */
int mlo_changed(const uint8_t *a, size_t asize, const uint8_t *b, size_t bsize);

#endif /* DRYDOCK_LINKEDIT_ORDER_H */
