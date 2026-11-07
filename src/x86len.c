/* mx_ -- see x86len.h. */
#include "x86len.h"

/* One letter per opcode, sixteen to a row:
 *   m  ModRM                      b  ModRM, imm8
 *   z  ModRM, imm16/32 (66: 16)   g  ModRM, imm8 if ModRM.reg is 0 (F6)
 *   G  ModRM, imm16/32 if ModRM.reg is 0 (F7)
 *   -  nothing more               1  imm8 or rel8
 *   2  imm16                      3  imm16, imm8 (enter)
 *   4  rel32                      Z  imm16/32 (66: 16)
 *   V  imm16/32/64 (REX.W: 64, 66: 16)
 *   A  moffs: an 8-byte address (67: 4)
 *   p  a prefix                   x  not decoded
 *   T  0F                         S  0F 38            U  0F 3A
 *   X  VEX (C4, C5) */
static const char mx_map0[] =
    "mmmm1Zxxmmmm1ZxT" "mmmm1Zxxmmmm1Zxx" "mmmm1Zpxmmmm1Zpx" "mmmm1Zpxmmmm1Zpx"
    "pppppppppppppppp" "----------------" "xxxmppppZz1b----" "1111111111111111"
    "bzxbmmmmmmmmmmmm" "----------x-----" "AAAA----1Z------" "11111111VVVVVVVV"
    "bb2-XXbz3-2--1x-" "mmmmxxx-mmmmmmmm" "1111111144x1----" "pxpp--gG------mm";

static const char mx_map1[] =
    "mmmmx-----x-xm-x" "mmmmmmmmmmmmmmmm" "xxxxxxxxmmmmmmmm" "------x-SxUxxxxx"
    "mmmmmmmmmmmmmmmm" "mmmmmmmmmmmmmmmm" "mmmmmmmmmmmmmmmm" "bbbbmmm-xmxxmmmm"
    "4444444444444444" "mmmmmmmmmmmmmmmm" "---mbmxx---mbmmm" "mmmmmmmmmmbmmmmm"
    "mmbmbbbm--------" "mmmmmmmmmmmmmmmm" "mmmmmmmmmmmmmmmm" "mmmmmmmmmmmmmmmm";
_Static_assert(sizeof mx_map0 == 257 && sizeof mx_map1 == 257, "sixteen rows of sixteen");

/* Decodes the ModRM at code[at] and whatever SIB and displacement follow it
 * into *o; returns the offset just past them, or -1 past `avail`. */
static int mx_modrm(const uint8_t *code, size_t avail, int at, mx_insn *o) {
    if ((size_t)at >= avail) return -1;
    int mod = code[at] >> 6, rm = code[at] & 7, n = at + 1;
    o->modrm = at;
    if (mod == 3) return n;
    if (rm == 4) {
        if ((size_t)n >= avail) return -1;
        if (mod == 0 && (code[n] & 7) == 5) o->displen = 4;
        n++;
    } else if (mod == 0 && rm == 5) {
        o->displen = 4;
    }
    if (mod == 1) o->displen = 1;
    if (mod == 2) o->displen = 4;
    if (o->displen) o->disp = n;
    return n + o->displen;
}

/* The one-byte groups whose ModRM.reg leaves some encodings undefined, or,
 * for F6 /1 and F7 /1, an alias of TEST that neither otool nor LLVM decodes.
 * XOP (8F with a map of 8 or more) always has a nonzero reg field here. */
static int mx_group_ok(uint8_t op, uint8_t modrm) {
    int reg = (modrm >> 3) & 7;
    switch (op) {
    case 0x8F: return reg == 0;
    case 0xF6: case 0xF7: return reg != 1;
    case 0xC6: case 0xC7: return reg == 0 || modrm == 0xF8;
    case 0xFE: return reg < 2;
    case 0xFF: return reg < 7;
    }
    return 1;
}

/* Whether an EVEX opcode takes an imm8: all of map 3, and in map 1 the
 * shifts and shuffles by an immediate (70-73) and C2, C4, C5 and C6. */
static int mx_evex_imm8(int map, uint8_t op) {
    if (map == 3) return 1;
    return map == 1 && ((op >= 0x70 && op <= 0x73) || op == 0xC2 || op == 0xC4 || op == 0xC5 || op == 0xC6);
}

static int mx_decode_ex(const uint8_t *code, size_t avail, mx_insn *out, int evex_ok) {
    mx_insn o = { 0, -1, -1, 0, 0, 0, 0 };
    int n = 0, opsize = 0, adsize = 0, rexw = 0, noevex = 0;
    for (;; n++) {
        if (n >= 15 || (size_t)n >= avail) return 0;
        uint8_t b = code[n];
        if (b == 0x66) opsize = noevex = 1;
        else if (b == 0x67) adsize = 1;
        else if (b == 0xF0 || b == 0xF2 || b == 0xF3) noevex = 1;
        else if (b == 0x2E || b == 0x36 || b == 0x3E || b == 0x26 || b == 0x64 || b == 0x65) ;
        else if ((b & 0xF0) == 0x40) { rexw = (b & 8) != 0; noevex = 1; continue; }
        else break;
        rexw = 0;
    }
    uint8_t op = code[n++];
    char c = mx_map0[op];
    int map = 0;
    if (op == 0x62 && evex_ok) {   /* 62 P0 P1 P2, opcode, ModRM [SIB] [disp] [imm8] */
        if (noevex || (size_t)n + 3 >= avail) return 0;
        uint8_t p0 = code[n], p1 = code[n + 1];
        map = p0 & 7;
        if ((p0 & 8) || !(p1 & 4) || !(map == 1 || map == 2 || map == 3 || map == 5 || map == 6)) return 0;
        op = code[n + 3];
        n = mx_modrm(code, avail, n + 4, &o);
        if (n < 0) return 0;
        if (mx_evex_imm8(map, op)) o.immlen = 1;
        o.evex = 1;
        c = 'e';
    } else if (c == 'X') {
        if ((size_t)n + (op == 0xC4 ? 2 : 1) >= avail) return 0;
        map = op == 0xC4 ? code[n] & 0x1F : 1;
        n += op == 0xC4 ? 2 : 1;
        uint8_t vop = code[n++];
        if (map == 1 && vop == 0x77) c = '-';
        else if (map == 1) c = mx_map1[vop] == 'm' || mx_map1[vop] == 'b' ? mx_map1[vop] : 'x';
        else if (map == 2) c = 'm';
        else if (map == 3) c = 'b';
    } else if (c == 'T') {
        if ((size_t)n >= avail) return 0;
        op = code[n++];
        c = mx_map1[op];
        map = 1;
        if (c == 'S' || c == 'U') { n++; c = c == 'S' ? 'm' : 'b'; }
    }
    int immz = opsize && !rexw ? 2 : 4;
    switch (c) {
    case 'm': case 'b': case 'z': case 'g': case 'G':
        n = mx_modrm(code, avail, n, &o);
        if (n < 0) return 0;
        if (map == 0 && !mx_group_ok(op, code[o.modrm])) return 0;
        if (map == 0 && op == 0xC7 && code[o.modrm] == 0xF8 && opsize) return 0;
        if (c == 'b') o.immlen = 1;
        if (c == 'z') o.immlen = immz;
        if (c == 'g' && ((code[o.modrm] >> 3) & 7) == 0) o.immlen = 1;
        if (c == 'G' && ((code[o.modrm] >> 3) & 7) == 0) o.immlen = immz;
        break;
    case '-': case 'e': break;
    case '1': o.immlen = 1; break;
    case '2': o.immlen = 2; break;
    case '3': o.immlen = 3; break;
    case '4': if (opsize) return 0; o.immlen = 4; break;
    case 'Z': o.immlen = immz; break;
    case 'V': o.immlen = rexw ? 8 : immz; break;
    case 'A': o.disp = n; o.displen = adsize ? 4 : 8; n += o.displen; break;
    default: return 0;
    }
    n += o.immlen;
    if (n > 15 || (size_t)n > avail) return 0;
    o.len = n;
    o.adsize = adsize;
    *out = o;
    return 1;
}

int mx_decode(const uint8_t *code, size_t avail, mx_insn *out) { return mx_decode_ex(code, avail, out, 0); }
int mx_decode_evex(const uint8_t *code, size_t avail, mx_insn *out) { return mx_decode_ex(code, avail, out, 1); }
