#ifndef DRYDOCK_OBJC_X86_H
#define DRYDOCK_OBJC_X86_H
/* x86.h -- the x86_64 decoder the Objective-C reader and the symbolic executor share.
 *
 * A decoded instruction is Drydock's mx_decode_evex length decode plus the fields both consumers
 * ask of it: prefixes, opcode map and byte, modrm, sib, displacement, immediate and the target of
 * a rip-relative operand. Nothing here executes anything or follows a branch. An EVEX instruction
 * decodes with map 5 and an opcode no rule matches, so a query that does not know it answers
 * conservatively. */
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int len, map, vexmap, rex, op, modrm, mod, reg, rm, riprel, f2, f3, p66;
    int dispscaled;   /* an EVEX disp8: mdisp is the raw byte, the offset disp8*N for an unknown N */
    int64_t disp, imm, mdisp;
    int immlen, sib, sibbase, sibindex, sibscale;   /* sibbase -1: none (disp32); sibindex -1: none */
    uint64_t next, riptarget;
} ObjcIns;

/* 0, or -1 when the bytes do not decode as one instruction (*o is then zeroed). */
int objc_x86_decode(const uint8_t *code, size_t avail, uint64_t ip, ObjcIns *o);
/* The target of a relative call, jmp or jcc `x`, decoded from `code` at `ip`. */
int64_t objc_x86_rel_target(const uint8_t *code, const ObjcIns *x, uint64_t ip);
/* X with its modrm byte registers 4..7 named by the register they are part of when no REX makes
 * them spl, bpl, sil and dil (Intel SDM vol. 2, 2.1.5). */
ObjcIns objc_x86_byte_regs(const ObjcIns *x);
int objc_x86_is_call_rel(const ObjcIns *x);
int objc_x86_is_jmp_rel(const ObjcIns *x);
int objc_x86_is_jcc(const ObjcIns *x);
/* 1 for opcode FF with modrm.reg == r (2: call r/m, 4: jmp r/m). */
int objc_x86_is_ff(const ObjcIns *x, int r);
/* 1 when x's memory operand is only read: a load, compare, test, or an operation whose result goes to a register
 * (Intel SDM vol. 2's mov, movzx/movsx/movsxd, cmovcc, cmp, test, push r/m, the r <- r op r/m forms, and the SSE
 * loads movups/movss/movsd, movaps, movdqa/movdqu/movq and ucomis/comis); 0 for every other form, writes among
 * them -- conservatively, including forms that only read but are not listed. */
int objc_x86_reads_only(const ObjcIns *x);
/* Bit r set when x may read general-purpose register r (excluding the register a call/jmp *reg transfers through);
 * mem 0 leaves out the memory operand's base and index. 0xFFFF for any form not classified. */
uint16_t objc_x86_gpr_reads(const ObjcIns *x, int mem);

#endif
