#include "rez.h"

#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define LINE_MAX_BYTES ((size_t)1 << 20)
#define HEX_PIECE 32
#define QUOTED_PIECE 64
#define UIDS_PIECE 16

static const char *const type_names[] = { "i8", "i16", "i32", "i64", "false", "true", "f32", "f64",
                                          "data", "nil", "ref", "string", "uids" };

static void *grown(void *p, size_t n, size_t size) {
    if (n & (n - 1)) return p;
    if (n > SIZE_MAX / 2 / size) return NULL;
    return realloc(p, (n ? 2 * n : 1) * size);
}

/* ---- writing ---- */

/* long_line: the first line longer than rez_parse reads, or 0. */
typedef struct { char *p; size_t n, cap, line_start, line, long_line; int oom; } Buf;

static void put(Buf *b, const char *s, size_t n) {
    const char *nl;
    if (b->oom || !n) return;
    if (n > b->cap - b->n) {
        size_t cap = b->cap ? b->cap : 4096;
        char *p;
        while (n > cap - b->n) {
            if (cap > SIZE_MAX / 2) { b->oom = 1; return; }
            cap *= 2;
        }
        if (!(p = realloc(b->p, cap))) { b->oom = 1; return; }
        b->p = p;
        b->cap = cap;
    }
    memcpy(b->p + b->n, s, n);
    for (nl = memchr(s, '\n', n); nl; nl = memchr(nl + 1, '\n', n - (size_t)(nl + 1 - s))) {
        size_t at = b->n + (size_t)(nl - s);
        b->line++;
        if (at - b->line_start > LINE_MAX_BYTES && !b->long_line) b->long_line = b->line;
        b->line_start = at + 1;
    }
    b->n += n;
}

static void puts_(Buf *b, const char *s) { put(b, s, strlen(s)); }

static void putf(Buf *b, const char *fmt, ...) {
    char tmp[128];
    va_list ap;
    int k;
    va_start(ap, fmt);
    k = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (k < 0 || (size_t)k >= sizeof tmp) { b->oom = 1; return; }
    put(b, tmp, (size_t)k);
}

/* The length of the UTF-8 sequence at p (at most n bytes) when it is one well-formed, printable character: no C0
 * control but tab, newline and return, no DEL, no C1 control. 0 otherwise. */
static size_t printable_char(const uint8_t *p, size_t n) {
    uint32_t c;
    size_t k, i;
    if (p[0] < 0x80) return p[0] >= 0x20 ? (p[0] != 0x7f) : (p[0] == '\t' || p[0] == '\n' || p[0] == '\r');
    if (p[0] >= 0xc2 && p[0] <= 0xdf) k = 2, c = p[0] & 0x1f;
    else if (p[0] >= 0xe0 && p[0] <= 0xef) k = 3, c = p[0] & 0x0f;
    else if (p[0] >= 0xf0 && p[0] <= 0xf4) k = 4, c = p[0] & 0x07;
    else return 0;
    if (k > n) return 0;
    for (i = 1; i < k; i++) {
        if ((p[i] & 0xc0) != 0x80) return 0;
        c = c << 6 | (p[i] & 0x3f);
    }
    if ((k == 3 && c < 0x800) || (k == 4 && (c < 0x10000 || c > 0x10ffff)) || (c >= 0xd800 && c <= 0xdfff)
        || (c >= 0x80 && c <= 0x9f))
        return 0;
    return k;
}

static int printable(const uint8_t *p, size_t n) {
    size_t i, k;
    for (i = 0; i < n; i += k)
        if (!(k = printable_char(p + i, n - i))) return 0;
    return 1;
}

/* p[0..n) inside double quotes, with C escapes; bytes past ASCII are written as they are only when utf8 says the
 * whole value is printable UTF-8. */
static void put_quoted(Buf *b, const uint8_t *p, size_t n, int utf8) {
    size_t i;
    put(b, "\"", 1);
    for (i = 0; i < n; i++) {
        uint8_t c = p[i];
        if (c == '"') puts_(b, "\\\"");
        else if (c == '\\') puts_(b, "\\\\");
        else if (c == '\n') puts_(b, "\\n");
        else if (c == '\t') puts_(b, "\\t");
        else if (c == '\r') puts_(b, "\\r");
        else if (c < 0x20 || c == 0x7f || (c >= 0x80 && !utf8)) putf(b, "\\x%02x", c);
        else put(b, (const char *)&c, 1);
    }
    put(b, "\"", 1);
}

static int bare_char(uint8_t c) {
    return c > 0x20 && c < 0x7f && !strchr("\"#=:\\@?", c);
}

/* A key, class name or version: bare when it is plain ASCII the parser reads back as one word, else quoted. */
static void put_name(Buf *b, const char *s) {
    size_t n = strlen(s), i;
    for (i = 0; i < n && bare_char((uint8_t)s[i]); i++) {}
    if (n && i == n) put(b, s, n);
    else put_quoted(b, (const uint8_t *)s, n, printable((const uint8_t *)s, n));
}

/* Data and strings: printable UTF-8 quoted, else hex, in pieces of a line each so a long value diffs line by line. */
static void put_bytes(Buf *b, const uint8_t *p, size_t n) {
    size_t i, j, k;
    if (printable(p, n)) {
        i = 0;
        do {
            for (j = i; j < n && j - i < QUOTED_PIECE; j += k) {
                k = printable_char(p + j, n - j);
                if (j > i && j + k - i > QUOTED_PIECE) break;
                if (p[j] == '\n') { j += k; break; }
            }
            if (i) puts_(b, "\n    ");
            put_quoted(b, p + i, j - i, 1);
            i = j;
        } while (i < n);
        return;
    }
    for (i = 0; i < n; i += HEX_PIECE) {
        if (i) puts_(b, "\n    ");
        puts_(b, "x\"");
        for (j = i; j < n && j < i + HEX_PIECE; j++) putf(b, "%02x", p[j]);
        puts_(b, "\"");
    }
}

/* Hex floats with digits and exponent computed from the bits, so every host prints the same: 0x1.<hex>p<exp> with
 * trailing zeros dropped (subnormals normalized), 0x0p+0, inf, nan for the default quiet NaN, nan(0x<bits>) for any
 * other; then the decimal value as a comment. */
static void put_real(Buf *b, uint64_t bits, int f32) {
    uint64_t m, top;
    int e, exp, mbits = f32 ? 23 : 52, bias = f32 ? 127 : 1023, emax = f32 ? 0xff : 0x7ff, digits;
    int neg;
    char hex[16];
    neg = (int)(bits >> (mbits + (f32 ? 8 : 11)) & 1);
    e = (int)(bits >> mbits & (uint64_t)emax);
    m = bits & (((uint64_t)1 << mbits) - 1);
    if (e == emax) {
        if (m) {
            if (bits == (f32 ? 0x7fc00000u : 0x7ff8000000000000ull)) puts_(b, "nan");
            else if (f32) putf(b, "nan(0x%08lx)", (unsigned long)bits);
            else putf(b, "nan(0x%08lx%08lx)", (unsigned long)(bits >> 32), (unsigned long)(bits & 0xffffffffu));
        } else
            puts_(b, neg ? "-inf" : "inf");
        return;
    }
    if (neg) puts_(b, "-");
    if (!e && !m) {
        puts_(b, "0x0p+0");
    } else {
        top = (uint64_t)1 << mbits;
        if (e) exp = e - bias;
        else {
            exp = 1 - bias;
            while (!(m & top)) { m <<= 1; exp--; }
            m &= top - 1;
        }
        if (f32) m <<= 1;   /* 24 bits: six hex digits */
        digits = f32 ? 6 : 13;
        while (digits && !(m & 0xf)) { m >>= 4; digits--; }
        puts_(b, "0x1");
        if (digits) {
            int i;
            for (i = digits - 1; i >= 0; i--) { hex[i] = "0123456789abcdef"[m & 0xf]; m >>= 4; }
            puts_(b, ".");
            put(b, hex, (size_t)digits);
        }
        putf(b, "p%c%d", exp < 0 ? '-' : '+', exp < 0 ? -exp : exp);
    }
    if (f32) {
        uint32_t u = (uint32_t)bits;
        float f;
        memcpy(&f, &u, 4);
        putf(b, "  # %.9g", (double)f);
    } else {
        double d;
        memcpy(&d, &bits, 8);
        putf(b, "  # %.17g", d);
    }
}

int rez_write(const RGraph *g, char **out, size_t *outn, char *why, size_t whysz) {
    Buf b = { NULL, 0, 0, 0, 0, 0, 0 };
    size_t i, j, k;
    puts_(&b, "drydock-resources dump 1\n");
    if (g->format == RF_NIBARCHIVE)
        putf(&b, "format nibarchive %lu %lu\n", (unsigned long)g->na_header[0], (unsigned long)g->na_header[1]);
    else
        puts_(&b, "format keyed\n");
    for (i = 0; i < g->n_chains; i++) {
        const RChain *c = &g->chains[i];
        puts_(&b, "chain ");
        put_name(&b, c->cls);
        if (!c->resolved) puts_(&b, " ?");
        else
            for (j = 1; j < c->n_chain; j++) { puts_(&b, " : "); put_name(&b, c->chain[j]); }
        if (c->resolved && c->newer) { puts_(&b, " newer "); put_name(&b, c->newer); }
        if (c->n_hints) puts_(&b, " hints");
        for (j = 0; j < c->n_hints; j++) { puts_(&b, " "); put_name(&b, c->hints[j]); }
        puts_(&b, "\n");
    }
    for (i = 0; i < g->n_objs; i++) {
        putf(&b, "\n@%lu ", (unsigned long)i);
        put_name(&b, g->objs[i].cls);
        if (g->objs[i].bare) puts_(&b, " bare");
        puts_(&b, "\n");
        for (j = 0; j < g->objs[i].n_vals; j++) {
            const RValue *v = &g->objs[i].vals[j];
            puts_(&b, "  ");
            put_name(&b, v->key);
            puts_(&b, " = ");
            puts_(&b, type_names[v->type]);
            switch (v->type) {
            case RV_I8: case RV_I16: case RV_I32: case RV_I64: putf(&b, " %lld", (long long)v->u.i); break;
            case RV_F32: puts_(&b, " "); put_real(&b, v->u.f32, 1); break;
            case RV_F64: {
                uint64_t bits;
                memcpy(&bits, &v->u.f, 8);
                puts_(&b, " ");
                put_real(&b, bits, 0);
                break;
            }
            case RV_DATA: case RV_STRING: puts_(&b, " "); put_bytes(&b, v->u.d.p, v->u.d.n); break;
            case RV_REF: putf(&b, " @%lu", (unsigned long)v->u.ref); break;
            case RV_UID_ARRAY:
                for (k = 0; k < v->u.refs.n; k++)
                    putf(&b, "%s@%lu", k && !(k % UIDS_PIECE) ? "\n    " : " ", (unsigned long)v->u.refs.v[k]);
                break;
            default: break;
            }
            puts_(&b, "\n");
        }
    }
    if (b.oom) snprintf(why, whysz, "out of memory writing a dump");
    else if (b.long_line)
        snprintf(why, whysz, "a name too long to dump: line %lu would be longer than %lu bytes", (unsigned long)b.long_line,
                 (unsigned long)LINE_MAX_BYTES);
    if (b.oom || b.long_line) { free(b.p); return 4; }
    *out = b.p;
    *outn = b.n;
    return 0;
}

/* ---- parsing ---- */

enum { T_END, T_WORD, T_STR, T_HEX, T_EQ, T_COLON };
enum { PENDING_BYTES = 1, PENDING_UIDS };
typedef struct { int kind; const char *p; size_t n; } Tok;
typedef struct { uint32_t ref; size_t line; } PendingRef;
typedef struct { const char *key; size_t gen; } Slot;

typedef struct {
    RGraph *g;
    char *why;
    size_t whysz, line;
    const char *lp; size_t ln, pos;       /* the current line, without its newline, and the lexer's place in it */
    int state;                            /* 0 header, 1 format, 2 chains, 3 objects */
    PendingRef *refs; size_t n_refs;
    Slot *keys; size_t keys_cap, keys_n, gen;
    uint8_t *scratch; size_t scratch_n, scratch_cap;
    int pending;                          /* a value continuing on later lines: data or string pieces in scratch,
                                           * or uids refs in uids */
    RValue pv;
    uint32_t *uids; size_t n_uids;
    int oom;
    char show[4 * 40 + 1];
} P;

static int fail(P *p, const char *fmt, ...) {
    va_list ap;
    int k = snprintf(p->why, p->whysz, "malformed-dump: line %lu: ", (unsigned long)p->line);
    if (k >= 0 && (size_t)k < p->whysz) {
        va_start(ap, fmt);
        vsnprintf(p->why + k, p->whysz - (size_t)k, fmt, ap);
        va_end(ap);
    }
    return -1;
}

static int oom(P *p) { p->oom = 1; return -1; }

/* At most 40 bytes of hostile text for a message, every byte outside printable ASCII as \xHH, so a reason neither
 * floods nor carries terminal escapes. One per message: it reuses p->show. */
static const char *show_bytes(P *p, const char *s, size_t n) {
    size_t i, o = 0;
    for (i = 0; i < n && i < 40; i++) {
        uint8_t c = (uint8_t)s[i];
        if (c >= 0x20 && c < 0x7f) p->show[o++] = (char)c;
        else o += (size_t)snprintf(p->show + o, sizeof p->show - o, "\\x%02x", c);
    }
    p->show[o] = 0;
    return p->show;
}
#define SHOW(t) show_bytes(p, (t)->p, (t)->n)

static int lex(P *p, Tok *t) {
    const char *s = p->lp;
    size_t n = p->ln, i;
    while (p->pos < n && (s[p->pos] == ' ' || s[p->pos] == '\t')) p->pos++;
    if (p->pos >= n || s[p->pos] == '#') { t->kind = T_END; t->p = s + n; t->n = 0; return 0; }
    i = p->pos;
    if (s[i] == '=' || s[i] == ':') {
        t->kind = s[i] == '=' ? T_EQ : T_COLON;
        t->p = s + i; t->n = 1; p->pos = i + 1;
        return 0;
    }
    if (s[i] == '"' || (s[i] == 'x' && i + 1 < n && s[i + 1] == '"')) {
        size_t j;
        t->kind = s[i] == '"' ? T_STR : T_HEX;
        i += t->kind == T_HEX ? 2 : 1;
        for (j = i; j < n && s[j] != '"'; j++)
            if (s[j] == '\\') j++;
        if (j >= n) return fail(p, "unterminated string");
        t->p = s + i; t->n = j - i; p->pos = j + 1;
        return 0;
    }
    for (; i < n && s[i] != ' ' && s[i] != '\t' && s[i] != '"' && s[i] != '#' && s[i] != '=' && s[i] != ':'; i++) {
        if ((uint8_t)s[i] < 0x20 || s[i] == 0x7f) return fail(p, "a control character outside quotes");
        if ((uint8_t)s[i] >= 0x80) return fail(p, "a non-ASCII byte outside quotes");
    }
    t->kind = T_WORD; t->p = s + p->pos; t->n = i - p->pos; p->pos = i;
    return 0;
}

static int is_word(const Tok *t, const char *w) {
    return t->kind == T_WORD && t->n == strlen(w) && !memcmp(t->p, w, t->n);
}

static int need_end(P *p) {
    Tok t;
    if (lex(p, &t)) return -1;
    return t.kind == T_END ? 0 : fail(p, "unexpected '%s'", SHOW(&t));
}

static int hexval(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int reserve(P *p, size_t more) {
    uint8_t *s;
    size_t cap;
    if (more <= p->scratch_cap - p->scratch_n) return 0;
    cap = p->scratch_cap ? p->scratch_cap : 256;
    while (more > cap - p->scratch_n) {
        if (cap > SIZE_MAX / 2) return oom(p);
        cap *= 2;
    }
    if (!(s = realloc(p->scratch, cap))) return oom(p);
    p->scratch = s;
    p->scratch_cap = cap;
    return 0;
}

/* Appends a quoted string's or x"hex"'s bytes to scratch. */
static int decode(P *p, const Tok *t) {
    size_t i;
    if (reserve(p, t->n)) return -1;
    if (t->kind == T_HEX) {
        if (t->n % 2) return fail(p, "odd number of hex digits");
        for (i = 0; i < t->n; i += 2) {
            int hi = hexval(t->p[i]), lo = hexval(t->p[i + 1]);
            if (hi < 0 || lo < 0) return fail(p, "bad hex digit");
            p->scratch[p->scratch_n++] = (uint8_t)(hi << 4 | lo);
        }
        return 0;
    }
    for (i = 0; i < t->n; i++) {
        char c = t->p[i];
        if (c != '\\') { p->scratch[p->scratch_n++] = (uint8_t)c; continue; }
        c = t->p[++i];
        switch (c) {
        case '\\': case '"': p->scratch[p->scratch_n++] = (uint8_t)c; break;
        case 'n': p->scratch[p->scratch_n++] = '\n'; break;
        case 't': p->scratch[p->scratch_n++] = '\t'; break;
        case 'r': p->scratch[p->scratch_n++] = '\r'; break;
        case 'x': {
            int hi = i + 2 < t->n ? hexval(t->p[i + 1]) : -1, lo = hi < 0 ? -1 : hexval(t->p[i + 2]);
            if (hi < 0 || lo < 0) return fail(p, "bad \\x escape");
            p->scratch[p->scratch_n++] = (uint8_t)(hi << 4 | lo);
            i += 2;
            break;
        }
        default: return fail(p, "unknown escape \\%s", show_bytes(p, t->p + i, 1));
        }
    }
    return 0;
}

/* A name token (bare or quoted) interned into the graph, or copied to a malloc'd string when g is NULL. */
static int name(P *p, const Tok *t, const char **interned, char **owned) {
    if (t->kind != T_WORD && t->kind != T_STR) return fail(p, "expected a name, not '%s'", SHOW(t));
    p->scratch_n = 0;
    if (t->kind == T_STR) { if (decode(p, t)) return -1; }
    else {
        if (reserve(p, t->n)) return -1;
        memcpy(p->scratch, t->p, t->n);
        p->scratch_n = t->n;
    }
    if (memchr(p->scratch, 0, p->scratch_n)) return fail(p, "a name holds a NUL");
    if (interned) return (*interned = rg_intern(p->g, (const char *)p->scratch, p->scratch_n)) ? 0 : oom(p);
    if (!(*owned = malloc(p->scratch_n + 1))) return oom(p);
    memcpy(*owned, p->scratch, p->scratch_n);
    (*owned)[p->scratch_n] = 0;
    return 0;
}

/* @N with N a 32-bit unsigned decimal; -1 when t is not one, without a reason. */
static int objnum(const Tok *t, uint32_t *out) {
    uint64_t v = 0;
    size_t i;
    if (t->kind != T_WORD || t->n < 2 || t->n > 11 || t->p[0] != '@') return -1;
    for (i = 1; i < t->n; i++) {
        if (t->p[i] < '0' || t->p[i] > '9') return -1;
        v = v * 10 + (uint64_t)(t->p[i] - '0');
    }
    if (v > UINT32_MAX) return -1;
    *out = (uint32_t)v;
    return 0;
}

static int copy_tok(const Tok *t, char *buf, size_t sz) {
    if (t->kind != T_WORD || t->n >= sz) return -1;
    memcpy(buf, t->p, t->n);
    buf[t->n] = 0;
    return 0;
}

static int u32_word(P *p, const Tok *t, uint32_t *out) {
    char buf[32], *end;
    unsigned long long v;
    if (copy_tok(t, buf, sizeof buf) || buf[0] < '0' || buf[0] > '9') goto bad;
    errno = 0;
    v = strtoull(buf, &end, 10);
    if (errno || *end || v > UINT32_MAX) goto bad;
    *out = (uint32_t)v;
    return 0;
bad:
    return fail(p, "nibarchive version %s is not a 32-bit unsigned number", SHOW(t));
}

static int integer(P *p, const Tok *t, RvType type, int64_t *out) {
    static const int64_t lo[] = { INT8_MIN, INT16_MIN, INT32_MIN, INT64_MIN };
    static const int64_t hi[] = { INT8_MAX, INT16_MAX, INT32_MAX, INT64_MAX };
    char buf[32], *end;
    long long v;
    if (copy_tok(t, buf, sizeof buf) || (buf[0] != '-' && (buf[0] < '0' || buf[0] > '9')))
        return fail(p, "%s %s is not a number", type_names[type], SHOW(t));
    errno = 0;
    v = strtoll(buf, &end, 10);
    if (*end || end == buf) return fail(p, "%s %s is not a number", type_names[type], SHOW(t));
    if (errno || v < lo[type] || v > hi[type]) return fail(p, "%s %s is out of range", type_names[type], SHOW(t));
    *out = v;
    return 0;
}

/* The bits of an f32 or f64, from the forms put_real writes or a plain decimal; refuses what the type cannot hold
 * exactly. */
static int real(P *p, const Tok *t, int f32, uint64_t *out) {
    const char *tn = f32 ? "f32" : "f64";
    int mbits = f32 ? 23 : 52, bias = f32 ? 127 : 1023, digits = f32 ? 6 : 13;
    uint64_t sign, bits, m = 0, top = (uint64_t)1 << mbits;
    char buf[64], *end;
    const char *s;
    size_t i, n;
    int k = 0, neg, expneg = 0;
    long exp = 0;
    if (copy_tok(t, buf, sizeof buf)) goto nan_;
    neg = buf[0] == '-';
    s = buf + neg;
    n = strlen(s);
    sign = neg ? (uint64_t)1 << (f32 ? 31 : 63) : 0;
    if (!strcmp(s, "inf")) { bits = sign | ((uint64_t)(f32 ? 0xff : 0x7ff) << mbits); goto done; }
    if (!strcmp(s, "nan") && !neg) { bits = f32 ? 0x7fc00000u : 0x7ff8000000000000ull; goto done; }
    if (!strncmp(s, "nan(0x", 6)) {
        size_t want = f32 ? 8 : 16;
        if (neg || n != 7 + want || s[n - 1] != ')') goto nan_;
        for (bits = 0, i = 6; i < 6 + want; i++) {
            if (hexval(s[i]) < 0) goto nan_;
            bits = bits << 4 | (uint64_t)hexval(s[i]);
        }
        if ((bits >> mbits & (f32 ? 0xff : 0x7ff)) != (uint64_t)(f32 ? 0xff : 0x7ff) || !(bits & (top - 1)))
            return fail(p, "%s %s is not a NaN", tn, SHOW(t));
        goto done;
    }
    if (!strncmp(s, "0x", 2)) {
        const char *q = s + 3;
        if (s[2] == '0' && s[3] == 'p') {
            bits = sign;
            q = s + 4;
            if (*q == '+' || *q == '-') q++;
            if (!*q || strspn(q, "0123456789") != strlen(q)) goto nan_;
            goto done;
        }
        if (s[2] != '1') goto nan_;
        if (*q == '.') {
            for (q++; hexval(*q) >= 0; q++, k++)
                if (k < 16) m = m << 4 | (uint64_t)hexval(*q);
            if (!k) goto nan_;
        }
        if (*q++ != 'p') goto nan_;
        if (*q == '+' || *q == '-') expneg = *q++ == '-';
        if (!*q || strspn(q, "0123456789") != strlen(q)) goto nan_;
        if (strlen(q) > 5) return fail(p, "%s %s is out of range", tn, SHOW(t));
        exp = strtol(q, NULL, 10);
        if (expneg) exp = -exp;
        if (k > digits) return fail(p, "%s %s has more digits than an %s", tn, SHOW(t), tn);
        m <<= 4 * (digits - k);
        if (f32) {
            if (m & 1) return fail(p, "%s %s is not exact", tn, SHOW(t));
            m >>= 1;
        }
        if (exp > bias) return fail(p, "%s %s is out of range", tn, SHOW(t));
        if (exp >= 1 - bias) { bits = sign | (uint64_t)(exp + bias) << mbits | m; goto done; }
        if (1 - bias - exp > mbits) return fail(p, "%s %s is out of range", tn, SHOW(t));
        m |= top;
        k = (int)(1 - bias - exp);
        if (m & (((uint64_t)1 << k) - 1)) return fail(p, "%s %s is not exact", tn, SHOW(t));
        bits = sign | m >> k;
        goto done;
    }
    /* a decimal of digits, '.', 'e' and signs, starting with a digit (so never strtod's own inf, nan or hex), rounded
     * by strtod or strtof; a subnormal result is no error, though some libcs set ERANGE for one */
    if (!strspn(s, "0123456789") || s[strspn(s, "0123456789.eE+-")]) goto nan_;
    errno = 0;
    if (f32) {
        float f = strtof(buf, &end);
        uint32_t u;
        if (*end) goto nan_;
        if (errno && (f == 0 || isinf(f))) return fail(p, "%s %s is out of range", tn, SHOW(t));
        memcpy(&u, &f, 4);
        bits = u;
    } else {
        double d = strtod(buf, &end);
        if (*end) goto nan_;
        if (errno && (d == 0 || isinf(d))) return fail(p, "%s %s is out of range", tn, SHOW(t));
        memcpy(&bits, &d, 8);
    }
done:
    *out = bits;
    return 0;
nan_:
    return fail(p, "%s %s is not a number", tn, SHOW(t));
}

static int add_ref(P *p, uint32_t ref) {
    PendingRef *r = grown(p->refs, p->n_refs, sizeof *r);
    if (!r) return oom(p);
    p->refs = r;
    r[p->n_refs].ref = ref;
    r[p->n_refs++].line = p->line;
    return 0;
}

static size_t hash(const char *s) {
    size_t h = 2166136261u;
    for (; *s; s++) h = (h ^ (uint8_t)*s) * 16777619u;
    return h;
}

/* 1 when key was already a key of the current object; slots from earlier objects carry an older gen. */
static int seen_key(P *p, const char *key) {
    size_t i, mask;
    if (2 * (p->keys_n + 1) > p->keys_cap) {
        size_t cap = p->keys_cap ? 2 * p->keys_cap : 64, j;
        Slot *s;
        if (cap > SIZE_MAX / sizeof *s || !(s = calloc(cap, sizeof *s))) return oom(p);
        for (j = 0; j < p->keys_cap; j++) {
            if (p->keys[j].gen != p->gen) continue;
            for (i = hash(p->keys[j].key) & (cap - 1); s[i].gen == p->gen; i = (i + 1) & (cap - 1)) {}
            s[i] = p->keys[j];
        }
        free(p->keys);
        p->keys = s;
        p->keys_cap = cap;
    }
    mask = p->keys_cap - 1;
    for (i = hash(key) & mask; p->keys[i].gen == p->gen; i = (i + 1) & mask)
        if (!strcmp(p->keys[i].key, key)) return 1;
    p->keys[i].key = key;
    p->keys[i].gen = p->gen;
    p->keys_n++;
    return 0;
}

/* The rest of the line's @N refs, appended to the pending uids. */
static int uid_refs(P *p) {
    Tok op;
    for (;;) {
        uint32_t r, *u;
        if (lex(p, &op)) return -1;
        if (op.kind == T_END) return 0;
        if (objnum(&op, &r)) return fail(p, "ref needs @N, not '%s'", SHOW(&op));
        if (add_ref(p, r)) return -1;
        if (!(u = grown(p->uids, p->n_uids, sizeof *u))) return oom(p);
        p->uids = u;
        u[p->n_uids++] = r;
    }
}

static int flush(P *p) {
    int rc;
    if (!p->pending) return 0;
    if (p->pending == PENDING_UIDS) {
        p->pv.u.refs.v = p->uids;
        p->pv.u.refs.n = p->n_uids;
    } else {
        p->pv.u.d.p = p->scratch;
        p->pv.u.d.n = p->scratch_n;
    }
    p->pending = 0;
    rc = rg_add_value(p->g, (uint32_t)(p->g->n_objs - 1), &p->pv);
    return rc ? oom(p) : 0;
}

static int value_line(P *p, const Tok *keytok) {
    RValue v;
    uint64_t bits;
    Tok t, op;
    const char *key;
    int type;
    if (!p->g->n_objs) return fail(p, "a value before any object");
    if (name(p, keytok, &key, NULL) || lex(p, &t) || lex(p, &t)) return -1;
    for (type = 0; type < (int)(sizeof type_names / sizeof *type_names); type++)
        if (is_word(&t, type_names[type])) break;
    if (type == (int)(sizeof type_names / sizeof *type_names)) return fail(p, "unknown type %s", SHOW(&t));
    if (p->g->format == RF_NIBARCHIVE && (type == RV_STRING || type == RV_UID_ARRAY))
        return fail(p, "%s is not a NIBArchive type", type_names[type]);
    if (strcmp(key, "UINibEncoderEmptyKey") && seen_key(p, key)) {
        if (p->oom) return -1;
        return fail(p, "duplicate key %s", show_bytes(p, key, strlen(key)));
    }
    if (p->oom) return -1;
    memset(&v, 0, sizeof v);
    v.key = key;
    v.type = (RvType)type;
    switch (v.type) {
    case RV_I8: case RV_I16: case RV_I32: case RV_I64:
        if (lex(p, &op)) return -1;
        if (op.kind == T_END) return fail(p, "%s needs a value", type_names[type]);
        if (integer(p, &op, v.type, &v.u.i)) return -1;
        break;
    case RV_F32: case RV_F64:
        if (lex(p, &op)) return -1;
        if (op.kind == T_END) return fail(p, "%s needs a value", type_names[type]);
        if (real(p, &op, v.type == RV_F32, &bits)) return -1;
        if (v.type == RV_F32) v.u.f32 = (uint32_t)bits;
        else memcpy(&v.u.f, &bits, 8);
        break;
    case RV_DATA: case RV_STRING:
        if (lex(p, &op)) return -1;
        if (op.kind != T_STR && op.kind != T_HEX) return fail(p, "%s needs a quoted string or x\"hex\"", type_names[type]);
        p->scratch_n = 0;
        if (decode(p, &op) || need_end(p)) return -1;
        p->pv = v;
        p->pending = PENDING_BYTES;
        return 0;
    case RV_REF:
        if (lex(p, &op)) return -1;
        if (objnum(&op, &v.u.ref)) return fail(p, "ref needs @N, not '%s'", SHOW(&op));
        if (add_ref(p, v.u.ref)) return -1;
        break;
    case RV_UID_ARRAY:
        p->n_uids = 0;
        if (uid_refs(p)) return -1;
        p->pv = v;
        p->pending = PENDING_UIDS;
        return 0;
    default: break;
    }
    if (need_end(p)) return -1;
    return rg_add_value(p->g, (uint32_t)(p->g->n_objs - 1), &v) ? oom(p) : 0;
}

/* The names after a chain's `hints`, to the end of the line. */
static int hint_names(P *p, RChain *cs) {
    Tok t;
    if (p->g->format == RF_NIBARCHIVE) return fail(p, "hints are only for keyed dumps");
    for (;;) {
        char *s, **more;
        if (lex(p, &t)) return -1;
        if (t.kind == T_END) break;
        if (name(p, &t, NULL, &s)) return -1;
        if (!(more = realloc(cs->hints, (cs->n_hints + 1) * sizeof *more))) { free(s); return oom(p); }
        cs->hints = more;
        cs->hints[cs->n_hints++] = s;
    }
    return cs->n_hints ? 0 : fail(p, "hints needs a name");
}

static int chain_line(P *p) {
    RChain c, *cs;
    Tok t;
    char *s;
    memset(&c, 0, sizeof c);
    if (p->state == 3) return fail(p, "chain after the first object");
    if (lex(p, &t)) return -1;
    if (name(p, &t, NULL, &c.cls)) return -1;
    if (!(c.chain = malloc(sizeof *c.chain))) { free(c.cls); return oom(p); }
    if (!(c.chain[0] = malloc(strlen(c.cls) + 1))) { free(c.chain); free(c.cls); return oom(p); }
    strcpy(c.chain[0], c.cls);
    c.n_chain = 1;
    c.resolved = 1;
    if (!(cs = grown(p->g->chains, p->g->n_chains, sizeof *cs))) goto oom_;
    p->g->chains = cs;
    p->g->chains[p->g->n_chains++] = c;
    cs = &p->g->chains[p->g->n_chains - 1];
    if (p->g->n_chains > 1 && strcmp(cs[-1].cls, cs->cls) >= 0)
        return fail(p, "chain %s is out of order or repeated", show_bytes(p, cs->cls, strlen(cs->cls)));
    if (lex(p, &t)) return -1;
    if (is_word(&t, "?")) { cs->resolved = 0; return need_end(p); }
    while (t.kind == T_COLON) {
        char **more;
        if (lex(p, &t)) return -1;
        if (t.kind != T_WORD && t.kind != T_STR) return fail(p, "a name must follow ':'");
        if (name(p, &t, NULL, &s)) return -1;
        if (!(more = realloc(cs->chain, (cs->n_chain + 1) * sizeof *more))) { free(s); return oom(p); }
        cs->chain = more;
        cs->chain[cs->n_chain++] = s;
        if (lex(p, &t)) return -1;
    }
    if (is_word(&t, "newer")) {
        if (lex(p, &t)) return -1;
        if (name(p, &t, NULL, &cs->newer) || lex(p, &t)) return -1;
    }
    if (is_word(&t, "hints")) return hint_names(p, cs);
    return t.kind == T_END ? 0 : fail(p, "unexpected '%s'", SHOW(&t));
oom_:
    free(c.chain[0]);
    free(c.chain);
    free(c.cls);
    return oom(p);
}

static int line(P *p) {
    Tok a, b;
    size_t save;
    if (lex(p, &a)) return -1;
    if (a.kind == T_END) return 0;
    if (a.kind == T_STR || a.kind == T_HEX) {
        save = p->pos;
        if (lex(p, &b)) return -1;
        if (b.kind != T_EQ) {
            if (p->pending != PENDING_BYTES) return fail(p, "a quoted piece that follows no data or string value");
            p->pos = 0;
            for (;;) {
                if (lex(p, &a)) return -1;
                if (a.kind == T_END) return 0;
                if (a.kind != T_STR && a.kind != T_HEX) return fail(p, "unexpected '%s'", SHOW(&a));
                if (decode(p, &a)) return -1;
            }
        }
        p->pos = save;
    }
    if (p->pending == PENDING_UIDS && a.kind == T_WORD && a.p[0] == '@') {
        uint32_t num;
        save = p->pos;
        if (lex(p, &b)) return -1;
        if (b.kind == T_END || !objnum(&b, &num)) {
            p->pos = 0;
            return uid_refs(p);
        }
        p->pos = save;
    }
    if (flush(p)) return -1;
    save = p->pos;
    if (lex(p, &b)) return -1;
    if (b.kind == T_EQ) {
        if (p->state < 2) goto header;
        p->pos = save;
        return value_line(p, &a);
    }
    p->pos = save;
    if (p->state == 0) {
        Tok v;
        if (!is_word(&a, "drydock-resources") || !is_word(&b, "dump")) goto header;
        p->pos = save;
        if (lex(p, &b) || lex(p, &v)) return -1;
        if (!is_word(&v, "1")) return fail(p, "unsupported dump version %s", SHOW(&v));
        p->state = 1;
        return need_end(p);
    }
    if (p->state == 1) {
        Tok f, v1, v2;
        if (!is_word(&a, "format") || lex(p, &f)) goto format;
        if (is_word(&f, "keyed")) { p->g->format = RF_KEYED; p->state = 2; return need_end(p); }
        if (!is_word(&f, "nibarchive") || lex(p, &v1) || lex(p, &v2) || v1.kind == T_END || v2.kind == T_END) goto format;
        p->g->format = RF_NIBARCHIVE;
        if (u32_word(p, &v1, &p->g->na_header[0]) || u32_word(p, &v2, &p->g->na_header[1])) return -1;
        p->state = 2;
        return need_end(p);
    }
    if (is_word(&a, "chain")) return chain_line(p);
    {
        uint32_t num;
        const char *cls;
        if (objnum(&a, &num)) return fail(p, "unexpected '%s'", SHOW(&a));
        if (num < p->g->n_objs) return fail(p, "duplicate @%lu", (unsigned long)num);
        if (num > p->g->n_objs) return fail(p, "missing @%lu before @%lu", (unsigned long)p->g->n_objs, (unsigned long)num);
        if (lex(p, &b)) return -1;
        if (name(p, &b, &cls, NULL)) return -1;
        if (rg_add_object(p->g, cls) < 0) return oom(p);
        p->state = 3;
        p->gen++;
        p->keys_n = 0;
        if (lex(p, &b)) return -1;
        if (is_word(&b, "bare")) {
            if (p->g->format == RF_NIBARCHIVE) return fail(p, "bare is not a NIBArchive form");
            p->g->objs[p->g->n_objs - 1].bare = 1;
            return need_end(p);
        }
        return b.kind == T_END ? 0 : fail(p, "unexpected '%s'", SHOW(&b));
    }
header:
    return fail(p, "expected 'drydock-resources dump 1'");
format:
    return fail(p, "expected 'format nibarchive V1 V2' or 'format keyed'");
}

int rez_parse(const char *text, size_t n, RGraph *out, char *why, size_t whysz) {
    P p;
    size_t at = 0, i;
    int rc = 4;
    memset(out, 0, sizeof *out);
    memset(&p, 0, sizeof p);
    p.g = out; p.why = why; p.whysz = whysz; p.gen = 1;
    while (at < n) {
        const char *nl = memchr(text + at, '\n', n - at);
        size_t len = nl ? (size_t)(nl - (text + at)) : n - at;
        p.line++;
        if (len > LINE_MAX_BYTES) { fail(&p, "longer than %lu bytes", (unsigned long)LINE_MAX_BYTES); goto done; }
        if (memchr(text + at, 0, len)) { fail(&p, "a NUL byte"); goto done; }
        p.lp = text + at;
        p.ln = len && text[at + len - 1] == '\r' ? len - 1 : len;
        p.pos = 0;
        if (line(&p)) goto done;
        at += len + (nl != NULL);
    }
    if (!p.line) p.line = 1;
    if (flush(&p)) goto done;
    if (p.state == 0) { fail(&p, "expected 'drydock-resources dump 1'"); goto done; }
    if (p.state == 1) { fail(&p, "expected 'format nibarchive V1 V2' or 'format keyed'"); goto done; }
    for (i = 0; i < p.n_refs; i++)
        if (p.refs[i].ref >= out->n_objs) {
            p.line = p.refs[i].line;
            if (out->n_objs) fail(&p, "ref @%lu names no object; the last is @%lu", (unsigned long)p.refs[i].ref,
                                  (unsigned long)(out->n_objs - 1));
            else fail(&p, "ref @%lu names no object; there are none", (unsigned long)p.refs[i].ref);
            goto done;
        }
    rc = 0;
done:
    if (p.oom) snprintf(why, whysz, "out of memory parsing a dump");
    free(p.refs);
    free(p.keys);
    free(p.scratch);
    free(p.uids);
    if (rc) rg_free(out);
    return rc;
}
