#ifndef DRYDOCK_X86LEN_H
#define DRYDOCK_X86LEN_H
/*
 * mx_ -- the length of one x86-64 instruction, and where its operands lie.
 *
 * Legacy and REX prefixes, the one-byte map, 0F, 0F 38, 0F 3A, and VEX
 * (C4, C5): everything the 10.9 toolchain emits and 10.9's otool
 * disassembles. EVEX (62), XOP (8F with map 8 or above), 3DNow! (0F 0F),
 * and every opcode that is invalid in 64-bit mode are not decoded, so a
 * caller never trusts a length for them.
 */
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int len;      /* 1 to 15 */
    int modrm;    /* offset of the ModRM byte, or -1 if there is none */
    int disp;     /* offset of the displacement, or -1 */
    int displen;  /* 0, 1, 4 or 8 (a moffs) */
    int immlen;   /* bytes of immediate, relative branch offset included */
} mx_insn;

/* Decodes the instruction at code[0, avail). Returns 1 with *out filled, or
 * 0 if it is not one this decoder knows or it runs past `avail`. */
int mx_decode(const uint8_t *code, size_t avail, mx_insn *out);

#endif /* DRYDOCK_X86LEN_H */
