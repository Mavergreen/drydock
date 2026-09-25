#ifndef DRYDOCK_HDRREF_H
#define DRYDOCK_HDRREF_H
/*
 * mhr_ -- code that reaches its own image's header by RIP-relative distance.
 *
 * In 64-bit mode every RIP-relative operand is a ModRM byte with
 * (b & 0xC7) == 0x05, then a disp32, then 0, 1, 2 or 4 bytes of immediate.
 * Its target is the next instruction's address plus the disp32. A grow moves
 * the header relative to the code, and no rebase, bind or load command
 * records such a distance, so these are found in the code itself.
 *
 * The scan tries every byte of every instruction section as a ModRM byte,
 * with every immediate length, so it cannot miss an instruction form. It can
 * over-report: a byte inside another instruction can look like a ModRM.
 */
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint64_t addr;    /* vm address of the disp32 */
    uint64_t off;     /* file offset of the disp32 */
    int      immlen;  /* 0, 1, 2 or 4: the immediate length that makes the target exact */
} mhr_cand;

/* Called once per candidate, in address order within a section and in
 * load-command order across sections. Returning nonzero stops the scan. */
typedef int (*mhr_fn)(const mhr_cand *c, void *ctx);

/* Every candidate in `code[0, size)`, which loads at vm address `addr` from
 * file offset `off`, whose target is exactly `target`. Its disp32 lies wholly
 * inside `code`; its immediate may run past the end. `fn` may be NULL.
 * Returns how many candidates were passed to `fn`, counting one that stopped
 * the scan. */
uint64_t mhr_scan_code(const uint8_t *code, uint64_t size, uint64_t addr, uint64_t off,
                       uint64_t target, mhr_fn fn, void *ctx);

/* mhr_scan_code over every section with S_ATTR_PURE_INSTRUCTIONS or
 * S_ATTR_SOME_INSTRUCTIONS and file data. Returns the number of candidates,
 * or -1 when `buf` does not wrap or an instruction section's bytes lie past
 * `fsize`. */
int64_t mhr_scan(const uint8_t *buf, size_t fsize, uint64_t target, mhr_fn fn, void *ctx);

/* mhr_confirm's answers. */
#define MHR_CONFIRMED   0  /* every candidate is an instruction, or there is none */
#define MHR_UNSCANNABLE 1  /* an instruction section lies past the end of the image */
#define MHR_NO_STARTS   2  /* a candidate, and no LC_FUNCTION_STARTS to decode it from */
#define MHR_UNCONFIRMED 3  /* a candidate that decoding its function does not confirm */

/* Whether every candidate mhr_scan finds for the image's own base is an
 * instruction that addresses it. A candidate's function is the last
 * LC_FUNCTION_STARTS entry at or below it, in its own section. Decoding from
 * there (src/x86len.h), stepping over LC_DATA_IN_CODE ranges, must reach an
 * instruction whose RIP-relative disp32 is the candidate's and whose target
 * is the base. Returns an MHR_ answer, with *bad set to the candidate
 * MHR_NO_STARTS or MHR_UNCONFIRMED is about; or -1 if `buf` does not wrap,
 * no segment maps the header, or memory runs out. */
int mhr_confirm(const uint8_t *buf, size_t fsize, mhr_cand *bad);

#endif /* DRYDOCK_HDRREF_H */
