/* x86.c -- the decoder declared in x86.h, moved out of macho-reader.c unchanged. */
#include "x86.h"
#include "x86len.h"
#include <string.h>

int objc_x86_decode(const uint8_t *code, size_t avail, uint64_t ip, ObjcIns *o) {
    mx_insn m;
    int i = 0;
    memset(o, 0, sizeof *o);
    if (mx_decode_evex(code, avail, &m) != 1 || m.len <= 0) return -1;
    o->len = m.len; o->next = ip + (uint64_t)m.len;
    while (i < m.len) {
        uint8_t b = code[i];
        if (b == 0x66) o->p66 = 1;
        else if (b == 0xF2) o->f2 = 1;
        else if (b == 0xF3) o->f3 = 1;
        else if (!(b == 0x67 || b == 0x2E || b == 0x36 || b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65 || b == 0xF0)) break;
        i++;
    }
    if (i < m.len && code[i] >= 0x40 && code[i] <= 0x4F) o->rex = code[i++];
    if (m.evex && i + 4 < m.len && code[i] == 0x62) {
        /* map 5: no map 0..4 rule matches it, so every query below takes its conservative default.
         * P0's inverted R, X and B and P1's W, as a REX would carry them, name the address registers. */
        uint8_t p0 = code[i + 1], p1 = code[i + 2];
        o->map = 5; o->vexmap = p0 & 7; o->op = code[i + 4];
        o->rex = 0x40 | (p1 & 0x80 ? 8 : 0) | (p0 & 0x80 ? 0 : 4) | (p0 & 0x40 ? 0 : 2) | (p0 & 0x20 ? 0 : 1);
        o->dispscaled = m.displen == 1;
    } else if (i + 2 < m.len && code[i] == 0xC5) { o->map = 4; o->vexmap = 1; o->op = code[i + 2]; }
    else if (i + 3 < m.len && code[i] == 0xC4) { o->map = 4; o->vexmap = code[i + 1] & 0x1F; o->op = code[i + 3]; }
    else if (i < m.len && code[i] == 0x0F) {
        i++;
        if (i < m.len && code[i] == 0x38) { o->map = 2; i++; }
        else if (i < m.len && code[i] == 0x3A) { o->map = 3; i++; }
        else o->map = 1;
        o->op = i < m.len ? code[i] : -1;
    } else o->op = i < m.len ? code[i] : -1;
    o->immlen = m.immlen;
    if (m.immlen == 1) { int8_t v; memcpy(&v, code + m.len - 1, 1); o->imm = v; }
    else if (m.immlen == 2) { int16_t v; memcpy(&v, code + m.len - 2, 2); o->imm = v; }
    else if (m.immlen == 4) { int32_t v; memcpy(&v, code + m.len - 4, 4); o->imm = v; }
    else if (m.immlen == 8) { int64_t v; memcpy(&v, code + m.len - 8, 8); o->imm = v; }
    o->modrm = m.modrm >= 0;
    if (o->modrm) {
        uint8_t mr = code[m.modrm];
        o->mod = mr >> 6;
        o->reg = ((mr >> 3) & 7) | (o->rex & 4 ? 8 : 0);
        o->rm = (mr & 7) | (o->rex & 1 ? 8 : 0);
        o->sib = o->mod != 3 && (mr & 7) == 4;
        if (o->sib && m.modrm + 1 < m.len) {
            uint8_t sb = code[m.modrm + 1];
            o->sibbase = (sb & 7) == 5 && o->mod == 0 ? -1 : (sb & 7) | (o->rex & 1 ? 8 : 0);
            o->sibindex = ((sb >> 3) & 7) == 4 && !(o->rex & 2) ? -1 : ((sb >> 3) & 7) | (o->rex & 2 ? 8 : 0);
            o->sibscale = sb >> 6;
        }
        if (m.disp >= 0 && m.displen == 1) { int8_t v; memcpy(&v, code + m.disp, 1); o->mdisp = v; }
        else if (m.disp >= 0 && m.displen == 4) { int32_t v; memcpy(&v, code + m.disp, 4); o->mdisp = v; }
        if (o->mod == 0 && (mr & 7) == 5 && !m.adsize && m.disp >= 0 && m.displen == 4) {
            int32_t d;
            memcpy(&d, code + m.disp, 4);
            o->riprel = 1; o->disp = d;
            o->riptarget = o->next + (uint64_t)(int64_t)d;
        }
    }
    return 0;
}

int objc_x86_is_call_rel(const ObjcIns *x) { return x->map == 0 && x->op == 0xE8; }
int objc_x86_is_jmp_rel(const ObjcIns *x) { return x->map == 0 && (x->op == 0xE9 || x->op == 0xEB); }
int objc_x86_is_jcc(const ObjcIns *x) {
    return (x->map == 0 && ((x->op >= 0x70 && x->op <= 0x7F) || x->op == 0xE3)) ||
           (x->map == 1 && x->op >= 0x80 && x->op <= 0x8F);
}
int objc_x86_is_ff(const ObjcIns *x, int r) { return x->map == 0 && x->op == 0xFF && x->modrm && (x->reg & 7) == r; }

int objc_x86_reads_only(const ObjcIns *x) {
    int op = x->op, r = x->reg & 7;
    if (!x->modrm || x->mod == 3) return 0;
    if (x->map == 0) {
        if (op <= 0x3F && (op & 7) >= 2 && (op & 7) <= 3) return 1;   /* add/or/adc/sbb/and/sub/xor/cmp r, r/m */
        if (op == 0x38 || op == 0x39 || op == 0x84 || op == 0x85 || op == 0x8A || op == 0x8B || op == 0x63) return 1;
        if ((op == 0x80 || op == 0x81 || op == 0x83) && r == 7) return 1;                  /* cmp r/m, imm */
        if ((op == 0xF6 || op == 0xF7) && r <= 1) return 1;                                /* test r/m, imm */
        if (op == 0xFF && r == 6) return 1;                                                /* push r/m */
        return 0;
    }
    if (x->map == 1)
        return op == 0xB6 || op == 0xB7 || op == 0xBE || op == 0xBF || (op >= 0x40 && op <= 0x4F) || op == 0xAF ||
               op == 0x10 || op == 0x28 || op == 0x6F || op == 0x2E || op == 0x2F;
    return 0;
}

int64_t objc_x86_rel_target(const uint8_t *code, const ObjcIns *x, uint64_t ip) {
    int32_t d32; int8_t d8;
    (void)ip;
    if (x->map == 0 && (x->op == 0xEB || (x->op >= 0x70 && x->op <= 0x7F) || x->op == 0xE3)) {
        memcpy(&d8, code + x->len - 1, 1);
        return (int64_t)(x->next + (uint64_t)(int64_t)d8);
    }
    memcpy(&d32, code + x->len - 4, 4);
    return (int64_t)(x->next + (uint64_t)(int64_t)d32);
}

/* spec: Intel SDM vol. 2, 2.1.5 (table 2-2) and 3.1.1.1 -- with no REX prefix, byte registers 4..7 are
 * ah, ch, dh and bh: bits 8..15 of rax, rcx, rdx and rbx, not spl, bpl, sil and dil. X's modrm fields
 * with any such byte register named by the register it is part of (an rm field only when mod is 3). */
ObjcIns objc_x86_byte_regs(const ObjcIns *x) {
    ObjcIns y = *x;
    int op = x->op, both = 0, rmonly = 0;
    if (x->rex || !x->modrm) return y;
    if (x->map == 0) {
        both = (op <= 0x3F && !(op & 1) && (op & 7) <= 3) || op == 0x84 || op == 0x86 || op == 0x88 || op == 0x8A;
        rmonly = op == 0x80 || op == 0x82 || op == 0xC0 || op == 0xC6 || op == 0xD0 || op == 0xD2 || op == 0xF6 || op == 0xFE;
    } else if (x->map == 1) {
        both = op == 0xB0 || op == 0xC0;                                    /* cmpxchg, xadd r/m8, r8 */
        rmonly = (op >= 0x90 && op <= 0x9F) || op == 0xB6 || op == 0xBE;     /* setcc; movzx/movsx from r/m8 */
    }
    if ((both || rmonly) && x->mod == 3 && y.rm >= 4 && y.rm <= 7) y.rm -= 4;
    if (both && y.reg >= 4 && y.reg <= 7) y.reg -= 4;
    return y;
}


/* The general-purpose registers instruction x reads as data or to form an address, excluding the
 * register a `call/jmp *reg` transfers through (entry_escapes checks that one). An opcode this
 * table does not know reads every register: an entry point held across it is refused, not missed. */
uint16_t objc_x86_gpr_reads(const ObjcIns *x0, int mem) {   /* mem 0: not the memory operand's base and index */
    ObjcIns y = objc_x86_byte_regs(x0);   /* ah..bh read the register they are part of */
    const ObjcIns *x = &y;
    uint16_t m = 0;
    int op = x->op, low3 = op & 7, rm = x->modrm && x->mod == 3, opreg = (op & 7) | (x->rex & 1 ? 8 : 0);
#define R(n) (m |= (uint16_t)(1u << ((n) & 15)))
    int nomem = x->map == 1 && (op == 0x1F || op == 0x18 || op == 0x0D);   /* nop/prefetch operands are not read */
    if (mem && x->modrm && x->mod != 3 && !x->riprel && !nomem) {
        if (!x->sib) R(x->rm);
        else { if (x->sibbase >= 0) R(x->sibbase); if (x->sibindex >= 0) R(x->sibindex); }
    }
    if (x->map == 0) {
        if (op <= 0x3F && low3 <= 5 && op != 0x0F && op != 0x26 && op != 0x2E && op != 0x36 && op != 0x3E) {
            if (low3 >= 4) { R(0); return m; }
            /* xor/sub of a register with itself only zeroes it */
            if (rm && x->reg == x->rm && (op == 0x31 || op == 0x33 || op == 0x29 || op == 0x2B)) return m;
            R(x->reg); if (rm) R(x->rm);
            return m;
        }
        switch (op) {
        case 0x84: case 0x85: case 0x86: case 0x87: R(x->reg); if (rm) R(x->rm); return m;
        case 0xA8: case 0xA9: case 0x98: case 0x99: case 0xA0: case 0xA1: case 0xA2: case 0xA3: R(0); return m;
        case 0x88: case 0x89: R(x->reg); return m;
        case 0x8A: case 0x8B: case 0x8D: case 0x63: case 0x69: case 0x6B: if (rm) R(x->rm); return m;
        case 0x80: case 0x81: case 0x83: case 0xC0: case 0xC1: case 0xD0: case 0xD1: if (rm) R(x->rm); return m;
        case 0xD2: case 0xD3: R(1); if (rm) R(x->rm); return m;
        case 0xC6: case 0xC7: case 0x8F: return m;
        case 0xF6: case 0xF7: R(0); R(2); if (rm) R(x->rm); return m;
        case 0xFE: if (rm) R(x->rm); return m;
        case 0xFF: if (rm && (x->reg & 7) != 2 && (x->reg & 7) != 4) R(x->rm); return m;
        case 0xA4: case 0xA5: case 0xAA: case 0xAB: R(0); R(1); R(6); R(7); return m;
        case 0xC2: case 0xC3: case 0xC9: case 0xCC: case 0xE8: case 0xE9: case 0xEB: case 0xF4:
        case 0x68: case 0x6A: case 0x9C: case 0x9D: return m;
        case 0xE3: R(1); return m;
        }
        if (op >= 0x50 && op <= 0x57) { R(opreg); return m; }
        if (op >= 0x90 && op <= 0x97) { if (op != 0x90 || (x->rex & 1)) { R(opreg); R(0); } return m; }
        if ((op >= 0x58 && op <= 0x5F) || (op >= 0xB0 && op <= 0xBF) || (op >= 0x70 && op <= 0x7F)) return m;
        return 0xFFFF;
    }
    if (x->map == 1) {
        if ((op >= 0x40 && op <= 0x4F) || op == 0xAF || op == 0xA3 || op == 0xAB || op == 0xB3 || op == 0xBB ||
            op == 0xA4 || op == 0xAC || op == 0xC0 || op == 0xC1) { R(x->reg); if (rm) R(x->rm); return m; }
        if (op == 0xA5 || op == 0xAD) { R(1); R(x->reg); if (rm) R(x->rm); return m; }
        if (op == 0xB0 || op == 0xB1) { R(0); R(x->reg); if (rm) R(x->rm); return m; }
        if (op == 0xB6 || op == 0xB7 || op == 0xBE || op == 0xBF || op == 0xBC || op == 0xBD || op == 0xB8 ||
            op == 0xBA || op == 0x6E || op == 0x2A || op == 0xC4) { if (rm) R(x->rm); return m; }
        if (op >= 0xC8 && op <= 0xCF) { R(opreg); return m; }
        if (op == 0xA2) { R(0); R(1); return m; }
        if ((op >= 0x80 && op <= 0x9F) || op == 0x1F || op == 0x18 || op == 0x0D || op == 0x0B || op == 0x7E ||
            (op >= 0x10 && op <= 0x17) || (op >= 0x28 && op <= 0x2F) || (op >= 0x50 && op <= 0x7F) ||
            (op >= 0xD0 && op <= 0xFE) || op == 0xC2 || op == 0xC6 || op == 0xAE)
            return m;   /* vector registers in reg/rm */
        return 0xFFFF;
    }
    if (x->map == 2) { if ((op == 0xF0 || op == 0xF1) && rm) R(x->rm); return m; }
    if (x->map == 3 || (x->map == 4 && x->vexmap == 3 && op != 0xF0)) { if ((op == 0x20 || op == 0x22) && rm) R(x->rm); return m; }
    if (x->map == 4 && (x->vexmap == 1 || (x->vexmap == 2 && op < 0xF0))) return m;
    /* EVEX reads a general-purpose register only as an address, or as the r/m source of these:
     * movd/movq/movw to a vector, the int-to-float conversions, pinsr*, and broadcasts from a GPR. */
    if (x->map == 5) {
        int src = (x->vexmap == 1 && (op == 0x6E || op == 0x2A || op == 0x7B || op == 0xC4)) ||
                  (x->vexmap == 2 && op >= 0x7A && op <= 0x7C) ||
                  (x->vexmap == 3 && (op == 0x20 || op == 0x22)) ||
                  (x->vexmap == 5 && (op == 0x6E || op == 0x2A || op == 0x7B));
        if (src && rm) R(x->rm);
        return m;
    }
    return 0xFFFF;
#undef R
}
