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

