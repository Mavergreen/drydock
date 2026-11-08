/* binding.c -- map objc2 cache statics to their Rust binding path, and recognise objc2's
 * supported cache fetch functions.
 *
 * Profile: objc2 0.6 without the unstable-static-* features. sel!/class! expand to a
 * `static CACHED_SEL: CachedSel` / `static CACHED_CLASS: CachedClass` inside the calling item,
 * filled by `<CachedSel>::fetch(&CACHED_SEL, name)` / `<CachedClass>::fetch(&CACHED_CLASS, name,
 * caller)` with a NUL-terminated literal (objc2-0.6.3 src/__macro_helpers/cache.rs). The selector
 * itself comes from the bytes the reader recovered at that fetch call, never from the Rust
 * function name: generated names drop colons, and hand-written ones (NSData::bytes_raw ->
 * "bytes") need not resemble the selector at all.
 *
 * Receiver class and method kind are NOT derivable from a symbol: a static's path names the
 * Rust item that contains the sel!, which may be a shared helper. They are filled only from an
 * explicit binding receipt row (a TSV file, or the analyzer's build evidence), and stay NULL otherwise. A receipt row may name only a cache
 * inside an inherent method; one naming a free function, closure or trait method -- a helper
 * whose single cache serves unrelated callers -- is refused. Receiver closure for each dispatch
 * site is at the end of this file.
 *
 * Symbols are Rust v0 mangling (rustc -C symbol-mangling-version=v0). Punycode identifiers and
 * anything else this parser does not implement are refused, never approximated. */
#include "report.h"
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- v0 parsing ------------------------------------------------------------------------- */

typedef struct V0Path {
    char kind, ns;               /* C N M X Y I */
    const char *ident;
    uint64_t dis;
    struct V0Path *parent;       /* N, I: the inner path */
    struct V0Path *impl_path;    /* M, X: where the impl lives */
    struct V0Path *self_type;    /* M, X, Y: the self type when it is a path, else NULL */
    const char *self_text;       /* M, X, Y: the self type's display text */
    const char *text;
} V0Path;

typedef struct Block { struct Block *next; } Block;
typedef struct {
    const char *s; size_t n, pos;
    Block *blocks;
    unsigned depth, steps;
    int in_type;                 /* generic args print "<..>" in a type, "::<..>" in a value path */
    char why[160];
    struct { const char *id; uint64_t dis; } crates[64];   /* every crate root parsed */
    int ncrates, crates_overflow;
} V0;

#define V0_MAX_DEPTH 200u
#define V0_MAX_STEPS 200000u

static void *v0_alloc(V0 *p, size_t n) {
    Block *b = malloc(sizeof(Block) + n);
    if (!b) { snprintf(p->why, sizeof p->why, "out of memory"); return NULL; }
    b->next = p->blocks; p->blocks = b;
    return memset(b + 1, 0, n);
}

static void v0_release(V0 *p) {
    while (p->blocks) { Block *n = p->blocks->next; free(p->blocks); p->blocks = n; }
}

static int v0_bad(V0 *p, const char *what) {
    if (!p->why[0]) snprintf(p->why, sizeof p->why, "%s at offset %zu", what, p->pos);
    return -1;
}

/* Concatenate NULL-terminated pieces into an arena string. */
static const char *cat(V0 *p, ...) {
    va_list ap; const char *x; size_t len = 0; char *out, *w;
    va_start(ap, p);
    while ((x = va_arg(ap, const char *))) len += strlen(x);
    va_end(ap);
    if (!(out = v0_alloc(p, len + 1))) return NULL;
    w = out;
    va_start(ap, p);
    while ((x = va_arg(ap, const char *))) { size_t k = strlen(x); memcpy(w, x, k); w += k; }
    va_end(ap);
    *w = 0;
    return out;
}

static int peek(V0 *p) { return p->pos < p->n ? (unsigned char)p->s[p->pos] : -1; }
static int eat(V0 *p, char c) { if (peek(p) == c) { p->pos++; return 1; } return 0; }

static int base62(V0 *p, uint64_t *out) {
    uint64_t v = 0; int c;
    if (eat(p, '_')) { *out = 0; return 0; }
    while ((c = peek(p)) != '_') {
        int d;
        if (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'Z') d = c - 'A' + 36;
        else return v0_bad(p, "bad base-62 number");
        if (v > (UINT64_MAX - (uint64_t)d) / 62) return v0_bad(p, "base-62 overflow");
        v = v * 62 + (uint64_t)d; p->pos++;
    }
    p->pos++;
    if (v == UINT64_MAX) return v0_bad(p, "base-62 overflow");
    *out = v + 1;
    return 0;
}

static int decimal(V0 *p, size_t *out) {
    size_t v = 0; int c = peek(p);
    if (c == '0') { p->pos++; *out = 0; return 0; }
    if (c < '1' || c > '9') return v0_bad(p, "expected decimal");
    while ((c = peek(p)) >= '0' && c <= '9') {
        if (v > (p->n - (size_t)(c - '0')) / 10) return v0_bad(p, "length past end");
        v = v * 10 + (size_t)(c - '0'); p->pos++;
    }
    *out = v;
    return 0;
}

static int disambiguator(V0 *p, uint64_t *dis) {
    *dis = 0;
    if (!eat(p, 's')) return 0;
    if (base62(p, dis)) return -1;
    (*dis)++;
    return 0;
}

static int undis_ident(V0 *p, const char **out) {
    size_t len; char *id;
    if (peek(p) == 'u') return v0_bad(p, "punycode identifier not supported");
    if (decimal(p, &len)) return -1;
    eat(p, '_');
    if (len > p->n - p->pos) return v0_bad(p, "identifier past end");
    if (!(id = v0_alloc(p, len + 1))) return -1;
    memcpy(id, p->s + p->pos, len);
    p->pos += len;
    *out = id;
    return 0;
}

static int ident(V0 *p, const char **out, uint64_t *dis) {
    return disambiguator(p, dis) || undis_ident(p, out) ? -1 : 0;
}

static V0Path *path(V0 *p);
static int type(V0 *p, const char **text, V0Path **as_path);
static V0Path *trait_path(V0 *p) { V0Path *q; p->in_type++; q = path(p); p->in_type--; return q; }

static int enter(V0 *p) {
    if (++p->depth > V0_MAX_DEPTH || ++p->steps > V0_MAX_STEPS)
        return v0_bad(p, "symbol too deeply nested");
    return 0;
}

/* Run `fn` at a backref's target, then resume after the backref. */
static int backref_pos(V0 *p, size_t *save) {
    uint64_t off;
    size_t at = p->pos - 1;
    if (base62(p, &off)) return -1;
    if (off >= at) return v0_bad(p, "backref does not point backwards");
    *save = p->pos;
    p->pos = (size_t)off;
    return 0;
}

static int lifetime_skip(V0 *p) { uint64_t v; return base62(p, &v); }

static int const_val(V0 *p, const char **text) {
    int c = peek(p);
    if (c == 'p') { p->pos++; *text = "_"; return 0; }
    if (c == 'B') {
        size_t save; int r;
        p->pos++;
        if (backref_pos(p, &save)) return -1;
        r = const_val(p, text);
        p->pos = save;
        return r;
    }
    {
        const char *ty; size_t start; int neg;
        if (type(p, &ty, NULL)) return -1;
        neg = eat(p, 'n');
        start = p->pos;
        while ((c = peek(p)) != '_') {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return v0_bad(p, "bad const");
            p->pos++;
        }
        {
            size_t k = p->pos - start;
            char *hex = v0_alloc(p, k + 4);
            if (!hex) return -1;
            snprintf(hex, k + 4, "%s0x%.*s", neg ? "-" : "", (int)k, p->s + start);
            *text = hex;
        }
        p->pos++;
        return 0;
    }
}

static int generic_args(V0 *p, const char **text) {
    const char *acc = "";
    int first = 1;
    while (!eat(p, 'E')) {
        const char *one;
        if (peek(p) < 0) return v0_bad(p, "unterminated generic arguments");
        if (eat(p, 'L')) { if (lifetime_skip(p)) return -1; one = "'_"; }
        else if (eat(p, 'K')) { if (const_val(p, &one)) return -1; }
        else if (type(p, &one, NULL)) return -1;
        acc = cat(p, acc, first ? "" : ", ", one, (char *)NULL);
        if (!acc) return -1;
        first = 0;
    }
    *text = acc;
    return 0;
}

static int fn_sig(V0 *p, const char **text) {
    const char *args = "", *ret, *abi = "";
    int first = 1, uns;
    if (eat(p, 'G')) { if (lifetime_skip(p)) return -1; }
    uns = eat(p, 'U');
    if (eat(p, 'K')) {
        if (eat(p, 'C')) abi = "extern \"C\" ";
        else { const char *a; if (undis_ident(p, &a)) return -1; abi = cat(p, "extern \"", a, "\" ", (char *)NULL); }
    }
    while (!eat(p, 'E')) {
        const char *one;
        if (peek(p) < 0) return v0_bad(p, "unterminated fn signature");
        if (type(p, &one, NULL)) return -1;
        args = cat(p, args, first ? "" : ", ", one, (char *)NULL);
        if (!args) return -1;
        first = 0;
    }
    if (type(p, &ret, NULL)) return -1;
    *text = cat(p, uns ? "unsafe " : "", abi, "fn(", args, ") -> ", ret, (char *)NULL);
    return *text ? 0 : -1;
}

static int dyn_bounds(V0 *p, const char **text) {
    const char *acc = "dyn ";
    int first = 1;
    if (eat(p, 'G')) { if (lifetime_skip(p)) return -1; }
    while (!eat(p, 'E')) {
        V0Path *tr;
        if (peek(p) < 0) return v0_bad(p, "unterminated dyn bounds");
        if (!(tr = trait_path(p))) return -1;
        acc = cat(p, acc, first ? "" : " + ", tr->text, (char *)NULL);
        while (acc && peek(p) == 'p') {
            const char *name, *ty;
            p->pos++;
            if (undis_ident(p, &name) || type(p, &ty, NULL)) return -1;
            acc = cat(p, acc, "<", name, " = ", ty, ">", (char *)NULL);
        }
        if (!acc) return -1;
        first = 0;
    }
    if (!eat(p, 'L') || lifetime_skip(p)) return v0_bad(p, "dyn bounds without lifetime");
    *text = acc;
    return 0;
}

static const char *basic(int c) {
    switch (c) {
    case 'a': return "i8"; case 'b': return "bool"; case 'c': return "char"; case 'd': return "f64";
    case 'e': return "str"; case 'f': return "f32"; case 'h': return "u8"; case 'i': return "isize";
    case 'j': return "usize"; case 'l': return "i32"; case 'm': return "u32"; case 'n': return "i128";
    case 'o': return "u128"; case 's': return "i16"; case 't': return "u16"; case 'u': return "()";
    case 'v': return "..."; case 'x': return "i64"; case 'y': return "u64"; case 'z': return "!";
    case 'p': return "_";
    }
    return NULL;
}

static int type(V0 *p, const char **text, V0Path **as_path) {
    int c = peek(p), r = 0;
    const char *inner, *k;
    if (as_path) *as_path = NULL;
    if (enter(p)) return -1;
    if (c >= 0 && basic(c)) { p->pos++; *text = basic(c); p->depth--; return 0; }
    switch (c) {
    case 'A':
        p->pos++;
        if (type(p, &inner, NULL) || const_val(p, &k)) r = -1;
        else *text = cat(p, "[", inner, "; ", k, "]", (char *)NULL);
        break;
    case 'S':
        p->pos++;
        if (type(p, &inner, NULL)) r = -1; else *text = cat(p, "[", inner, "]", (char *)NULL);
        break;
    case 'T': {
        const char *acc = "("; int first = 1, n1 = 0;
        p->pos++;
        while (!eat(p, 'E')) {
            if (peek(p) < 0 || type(p, &inner, NULL)) { r = v0_bad(p, "bad tuple"); break; }
            acc = cat(p, acc, first ? "" : ", ", inner, (char *)NULL);
            if (!acc) { r = -1; break; }
            n1++;
            first = 0;
        }
        if (!r) *text = cat(p, acc, n1 == 1 ? ",)" : ")", (char *)NULL);
        break;
    }
    case 'R': case 'Q':
        p->pos++;
        if (eat(p, 'L') && lifetime_skip(p)) { r = -1; break; }
        if (type(p, &inner, NULL)) r = -1;
        else *text = cat(p, c == 'R' ? "&" : "&mut ", inner, (char *)NULL);
        break;
    case 'P': case 'O':
        p->pos++;
        if (type(p, &inner, NULL)) r = -1;
        else *text = cat(p, c == 'P' ? "*const " : "*mut ", inner, (char *)NULL);
        break;
    case 'F': p->pos++; r = fn_sig(p, text); break;
    case 'D': p->pos++; r = dyn_bounds(p, text); break;
    case 'B': {
        size_t save;
        p->pos++;
        if (backref_pos(p, &save)) { r = -1; break; }
        r = type(p, text, as_path);
        p->pos = save;
        break;
    }
    default: {
        V0Path *q;
        p->in_type++;
        q = path(p);
        p->in_type--;
        if (!q) r = -1;
        else { *text = q->text; if (as_path) *as_path = q; }
    }
    }
    if (!r && !*text) r = -1;
    p->depth--;
    return r;
}

static const char *ns_text(V0 *p, char ns, const char *id, uint64_t dis) {
    char num[32];
    snprintf(num, sizeof num, "%llu", (unsigned long long)dis);
    if (ns == 'C') return cat(p, "{closure", *id ? ":" : "", id, "#", num, "}", (char *)NULL);
    if (ns == 'S') return cat(p, "{shim", *id ? ":" : "", id, "#", num, "}", (char *)NULL);
    if (ns >= 'A' && ns <= 'Z') {
        char tag[2] = { ns, 0 };
        return cat(p, "{", tag, *id ? ":" : "", id, "#", num, "}", (char *)NULL);
    }
    return id;
}

static V0Path *path(V0 *p) {
    int c = peek(p);
    V0Path *q;
    if (enter(p)) return NULL;
    if (c == 'B') {
        size_t save;
        p->pos++;
        if (backref_pos(p, &save)) return NULL;
        q = path(p);
        p->pos = save;
        p->depth--;
        return q;
    }
    if (!(q = v0_alloc(p, sizeof *q))) return NULL;
    q->kind = (char)c;
    p->pos++;
    switch (c) {
    case 'C':
        if (ident(p, &q->ident, &q->dis)) return NULL;
        q->text = q->ident;
        {
            int k;
            for (k = 0; k < p->ncrates && !(p->crates[k].dis == q->dis && !strcmp(p->crates[k].id, q->ident)); k++) ;
            if (k == p->ncrates) {
                if (p->ncrates < 64) { p->crates[k].id = q->ident; p->crates[k].dis = q->dis; p->ncrates++; }
                else p->crates_overflow = 1;
            }
        }
        break;
    case 'M': case 'X': {
        const char *ty; uint64_t d;
        if (disambiguator(p, &d) || !(q->impl_path = path(p)) || type(p, &ty, &q->self_type))
            return NULL;
        q->self_text = ty;
        if (c == 'M') q->text = cat(p, "<", ty, ">", (char *)NULL);
        else {
            V0Path *tr = trait_path(p);
            if (!tr) return NULL;
            q->parent = tr;
            q->text = cat(p, "<", ty, " as ", tr->text, ">", (char *)NULL);
        }
        break;
    }
    case 'Y': {
        const char *ty; V0Path *tr;
        if (type(p, &ty, &q->self_type) || !(tr = trait_path(p))) return NULL;
        q->self_text = ty;
        q->parent = tr;
        q->text = cat(p, "<", ty, " as ", tr->text, ">", (char *)NULL);
        break;
    }
    case 'N': {
        int ns = peek(p);
        if (!((ns >= 'a' && ns <= 'z') || (ns >= 'A' && ns <= 'Z'))) { v0_bad(p, "bad namespace"); return NULL; }
        p->pos++;
        q->ns = (char)ns;
        if (!(q->parent = path(p)) || ident(p, &q->ident, &q->dis)) return NULL;
        if (!*q->ident && q->ns >= 'a' && q->ns <= 'z') q->text = q->parent->text;
        else q->text = cat(p, q->parent->text, "::", ns_text(p, q->ns, q->ident, q->dis), (char *)NULL);
        break;
    }
    case 'I': {
        const char *args;
        int in_type = p->in_type;
        if (!(q->parent = path(p)) || generic_args(p, &args)) return NULL;
        q->text = cat(p, q->parent->text, in_type ? "<" : "::<", args, ">", (char *)NULL);
        break;
    }
    default:
        v0_bad(p, "unsupported path tag");
        return NULL;
    }
    if (!q->text) return NULL;
    p->depth--;
    return q;
}

/* Parse `symbol` (Mach-O form "__R..." or "_R..."); a trailing ".suffix" (LLVM's ".llvm.N",
 * ".0") and an instantiating-crate path are accepted and ignored. */
static V0Path *v0_parse(V0 *p, const char *symbol) {
    const char *s = symbol, *dot;
    V0Path *top;
    memset(p, 0, sizeof *p);
    if (s[0] == '_' && s[1] == '_' && s[2] == 'R') s += 3;
    else if (s[0] == '_' && s[1] == 'R') s += 2;
    else { snprintf(p->why, sizeof p->why, "not a Rust v0 symbol"); return NULL; }
    dot = s + strcspn(s, ".$");  /* ".llvm.N", ".0", Mach-O "$tlv$init" */
    p->s = s; p->n = (size_t)(dot - s);
    if (p->pos < p->n && p->s[p->pos] >= '0' && p->s[p->pos] <= '9') {
        snprintf(p->why, sizeof p->why, "versioned v0 encoding not supported");
        return NULL;
    }
    if (!(top = path(p))) { v0_bad(p, "unparsable path"); return NULL; }
    if (p->pos < p->n && !path(p)) { v0_bad(p, "unparsable instantiating crate"); return NULL; }
    if (p->pos != p->n) { v0_bad(p, "trailing bytes"); return NULL; }
    return top;
}

static const char *crate_of(const V0Path *q) {
    while (q) {
        switch (q->kind) {
        case 'C': return q->ident;
        case 'N': case 'I': q = q->parent; break;
        case 'M': case 'X': q = q->impl_path; break;
        case 'Y': q = q->self_type; break;
        default: return NULL;
        }
    }
    return NULL;
}

/* ---- public binding API ----------------------------------------------------------------- */

char *objc_binding_demangle(const char *symbol, char *why, size_t whysz) {
    V0 p; V0Path *top = v0_parse(&p, symbol); char *out = NULL;
    if (top) out = strdup(top->text);
    else if (why) snprintf(why, whysz, "%s", p.why);
    v0_release(&p);
    return out;
}

/* A disambiguator as rustc spells it between "s" and "_" (base-62, offset by one); "" for none. */
static void dis_text(uint64_t dis, char *out, size_t outsz) {
    char tmp[16];
    int n = 0;
    uint64_t v;
    if (dis <= 1) { snprintf(out, outsz, "%s", dis ? "_" : ""); return; }
    v = dis - 2;
    do { int d = (int)(v % 62); tmp[n++] = (char)(d < 10 ? '0' + d : d < 36 ? 'a' + d - 10 : 'A' + d - 36); v /= 62; } while (v && n < 15);
    { int i; for (i = 0; i < n && (size_t)i + 1 < outsz; i++) out[i] = tmp[n - 1 - i]; out[i] = 0; }
}

static int append0(char *buf, size_t bufsz, size_t *at, const char *s) {
    size_t k = strlen(s) + 1;
    if (*at + k + 1 > bufsz) return -1;
    memcpy(buf + *at, s, k); *at += k; buf[*at] = 0;
    return 0;
}

int objc_binding_symbol_types(const char *symbol, char *buf, size_t bufsz, char *cbuf, size_t cbufsz,
                              char *why, size_t whysz) {
    V0 p; V0Path *top, *q;
    size_t at = 0, cat_ = 0;
    int i, rc = 0;
    if (bufsz < 2 || cbufsz < 2) return -1;
    buf[0] = buf[1] = cbuf[0] = cbuf[1] = 0;
    if (!(top = v0_parse(&p, symbol))) { snprintf(why, whysz, "%s", p.why); v0_release(&p); return -1; }
    if (p.crates_overflow) { snprintf(why, whysz, "more crate roots than this reader records"); v0_release(&p); return -1; }
    /* The function's own path, outward: the first impl it is in names the self type. */
    for (q = top; q && !rc; ) {
        if (q->kind == 'M' || q->kind == 'X' || q->kind == 'Y') { if (q->self_text) rc = append0(buf, bufsz, &at, q->self_text); break; }
        if (q->kind == 'N' || q->kind == 'I') q = q->parent; else break;
    }
    for (i = 0; i < p.ncrates && !rc; i++) {
        char d[16], pair[256];
        dis_text(p.crates[i].dis, d, sizeof d);
        snprintf(pair, sizeof pair, "%s=%s", p.crates[i].id, d);
        rc = append0(cbuf, cbufsz, &cat_, pair);
    }
    if (rc) snprintf(why, whysz, "symbol types too long");
    v0_release(&p);
    return rc;
}

ObjcFetchForm objc_binding_fetch_form(const char *symbol) {
    V0 p; V0Path *top; ObjcFetchForm f = OBJC_FETCH_NONE;
    if (strncmp(symbol, "__R", 3) && strncmp(symbol, "_R", 2)) return f;
    if ((top = v0_parse(&p, symbol)) && top->kind == 'N' && top->ns == 'v' && top->parent->kind == 'M') {
        if (!strcmp(top->text, "<objc2::__macro_helpers::cache::CachedSel>::fetch")) f = OBJC_FETCH_SEL;
        else if (!strcmp(top->text, "<objc2::__macro_helpers::cache::CachedClass>::fetch")) f = OBJC_FETCH_CLASS;
        else if (!strcmp(top->text, "<objc2::runtime::Sel>::register_unchecked")) f = OBJC_WRAP_SEL_CSTR;
        else if (!strcmp(top->text, "<objc2_foundation::generated::__NSString::NSString>::from_str")) f = OBJC_WRAP_NSSTRING;
    }
    v0_release(&p);
    return f;
}

int objc_binding_cache_kind(const char *symbol) {
    V0 p; V0Path *top; int k = 0;
    if (strncmp(symbol, "__R", 3) && strncmp(symbol, "_R", 2)) return 0;
    /* Cheap filter before a full parse: the static's identifier is the last path element. */
    if (!strstr(symbol, "10CACHED_SEL") && !strstr(symbol, "12CACHED_CLASS")) return 0;
    if ((top = v0_parse(&p, symbol)) && top->kind == 'N' && top->ns == 'v') {
        if (!strcmp(top->ident, "CACHED_SEL")) k = 1;
        else if (!strcmp(top->ident, "CACHED_CLASS")) k = 2;
    }
    v0_release(&p);
    return k;
}

typedef struct { char *demangled, *selector, *receiver, *kind, *provenance; int used; } Receipt;

static void free_receipts(Receipt *r, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        free(r[i].demangled); free(r[i].selector); free(r[i].receiver); free(r[i].kind);
        free(r[i].provenance);
    }
    free(r);
}

/* Receipt schema 1: first line "# objc-binding-receipt 1", then TAB-separated
 * demangled-cache-path, selector, receiver class, method kind (+/-), provenance. */
static int load_receipt(ObjcAnalysis *a, Receipt **out, size_t *nout) {
    FILE *f;
    char line[4096];
    size_t n = 0, cap = 0, lineno = 0;
    Receipt *r = NULL;
    *out = NULL; *nout = 0;
    if (a->n_receipt) {   /* rows the front end took from build evidence */
        if (a->binding_receipt_path) return objc_fail(a, "binding-receipt-conflict", NULL, 0, "two receipts given");
        if (!(r = calloc(a->n_receipt, sizeof *r))) return objc_fail(a, "out-of-memory", NULL, 0, "receipt");
        for (n = 0; n < a->n_receipt; n++) {
            const ObjcReceiptRow *x = &a->receipt[n];
            if (!x->demangled || !x->selector || !x->receiver || !x->provenance || !x->kind ||
                (strcmp(x->kind, "+") && strcmp(x->kind, "-"))) {
                free_receipts(r, n);
                return objc_fail(a, "malformed-binding-receipt", NULL, 0, "build evidence receipt row %zu", n + 1);
            }
            if (!(r[n].demangled = strdup(x->demangled)) || !(r[n].selector = strdup(x->selector)) ||
                !(r[n].receiver = strdup(x->receiver)) || !(r[n].kind = strdup(x->kind)) ||
                !(r[n].provenance = strdup(x->provenance))) {
                free_receipts(r, n + 1);
                return objc_fail(a, "out-of-memory", NULL, 0, "receipt");
            }
        }
        *out = r; *nout = n;
        return 0;
    }
    if (!a->binding_receipt_path) return 0;
    if (!(f = fopen(a->binding_receipt_path, "r")))
        return objc_fail(a, "unreadable-binding-receipt", NULL, 0, "%s: %s",
                         a->binding_receipt_path, strerror(errno));
    while (fgets(line, sizeof line, f)) {
        char *field[6], *c = line;
        int nf = 0;
        size_t len = strlen(line);
        lineno++;
        if (len == 0 || line[len - 1] != '\n') {
            fclose(f); free_receipts(r, n);
            return objc_fail(a, "malformed-binding-receipt", NULL, 0, "line %zu unterminated or too long", lineno);
        }
        line[len - 1] = 0;
        if (lineno == 1) {
            if (strcmp(line, "# objc-binding-receipt 1")) {
                fclose(f); free_receipts(r, n);
                return objc_fail(a, "malformed-binding-receipt", NULL, 0, "missing schema-1 header");
            }
            continue;
        }
        if (!line[0] || line[0] == '#') continue;
        field[nf++] = c;
        while (*c) { if (*c == '\t') { *c = 0; if (nf == 6) break; field[nf++] = c + 1; } c++; }
        if (nf != 5 || !*field[0] || !*field[1] || !*field[2] || !*field[4] ||
            (strcmp(field[3], "+") && strcmp(field[3], "-"))) {
            fclose(f); free_receipts(r, n);
            return objc_fail(a, "malformed-binding-receipt", NULL, 0, "line %zu: want 5 fields, kind + or -", lineno);
        }
        if (n == cap) {
            Receipt *g = realloc(r, (cap = cap ? cap * 2 : 32) * sizeof *r);
            if (!g) { fclose(f); free_receipts(r, n); return objc_fail(a, "out-of-memory", NULL, 0, "receipt"); }
            r = g;
        }
        memset(&r[n], 0, sizeof *r);
        if (!(r[n].demangled = strdup(field[0])) || !(r[n].selector = strdup(field[1])) ||
            !(r[n].receiver = strdup(field[2])) || !(r[n].kind = strdup(field[3])) ||
            !(r[n].provenance = strdup(field[4]))) {
            n++; fclose(f); free_receipts(r, n);
            return objc_fail(a, "out-of-memory", NULL, 0, "receipt");
        }
        n++;
    }
    if (ferror(f)) { fclose(f); free_receipts(r, n); return objc_fail(a, "unreadable-binding-receipt", NULL, 0, "read error"); }
    fclose(f);
    *out = r; *nout = n;
    return 0;
}

int objc_bind_caches(ObjcAnalysis *a) {
    Receipt *rc; size_t nrc, i, j;
    int status = OBJC_OK;
    if (load_receipt(a, &rc, &nrc)) return OBJC_CANNOT_MEASURE;
    for (i = 0; i < a->n_evidence; i++) {
        ObjcEvidence *e = &a->evidence[i];
        ObjcBinding b;
        V0 p; V0Path *top, *fp, *gp;
        const char *recovered;
        if (e->kind != OBJC_EV_SEL_CACHE && e->kind != OBJC_EV_CLASS_CACHE) continue;
        memset(&b, 0, sizeof b);
        b.evidence = i;
        recovered = e->kind == OBJC_EV_SEL_CACHE ? e->selector : e->name;
        if (!(top = v0_parse(&p, e->symbol)) || top->kind != 'N' || top->ns != 'v' || !(fp = top->parent)) {
            status = objc_fail(a, "unsupported-binding-form", e->slice, e->address, "%s: %s",
                               e->symbol, top ? "cache static outside a value item" : p.why);
            v0_release(&p);
            continue;
        }
        b.demangled = (char *)top->text;
        gp = fp->parent;
        if (fp->kind == 'N' && fp->ns == 'v' && gp && gp->kind == 'M') {
            b.form = "inherent-method"; b.rust_owner = (char *)gp->text; b.rust_fn = (char *)fp->ident;
        } else if (fp->kind == 'N' && fp->ns == 'v' && gp && gp->kind == 'X') {
            b.form = "trait-method"; b.rust_owner = (char *)gp->text; b.rust_fn = (char *)fp->ident;
        } else if (fp->kind == 'N' && fp->ns == 'v' && gp && (gp->kind == 'N' || gp->kind == 'C')) {
            b.form = "free-fn"; b.rust_owner = (char *)gp->text; b.rust_fn = (char *)fp->ident;
        } else if (fp->kind == 'N' && fp->ns == 'C' && gp) {
            b.form = "closure"; b.rust_owner = (char *)gp->text;
            b.rust_fn = (char *)ns_text(&p, 'C', fp->ident, fp->dis);
        } else {
            status = objc_fail(a, "unsupported-binding-form", e->slice, e->address,
                               "%s: unrecognised enclosing item", top->text);
            v0_release(&p);
            continue;
        }
        b.crate = (char *)crate_of(fp);
        for (j = 0; j < nrc; j++) {
            if (strcmp(rc[j].demangled, top->text)) continue;
            if (!recovered || strcmp(rc[j].selector, recovered)) continue;
            if (rc[j].used) {
                status = objc_fail(a, "binding-receipt-conflict", e->slice, e->address,
                                   "%s %s mapped twice", top->text, rc[j].selector);
                break;
            }
            if (strcmp(b.form, "inherent-method")) {
                /* A free function, closure or trait default method is a shared helper: its
                 * cache serves every caller, so no one source receiver describes it. */
                status = objc_fail(a, "receipt-on-shared-helper", e->slice, e->address,
                                   "%s is a %s; its receivers close per send or not at all", top->text, b.form);
                rc[j].used = 1;
                break;
            }
            rc[j].used = 1;
            b.receiver = rc[j].receiver; b.method_kind = rc[j].kind; b.provenance = rc[j].provenance;
            break;
        }
        if (objc_add_binding(a, &b)) status = OBJC_CANNOT_MEASURE;
        v0_release(&p);
    }
    /* A receipt row that matches a cache path but not its recovered bytes is a contradiction
     * between source and binary, not an unused row. */
    for (j = 0; j < nrc; j++) {
        if (rc[j].used) continue;
        for (i = 0; i < a->n_bindings; i++)
            if (!strcmp(a->bindings[i].demangled, rc[j].demangled)) {
                ObjcEvidence *e = &a->evidence[a->bindings[i].evidence];
                const char *got = e->kind == OBJC_EV_SEL_CACHE ? e->selector : e->name;
                status = objc_fail(a, "binding-receipt-conflict", e->slice, e->address,
                                   "%s: receipt says %s, artifact bytes say %s",
                                   rc[j].demangled, rc[j].selector, got ? got : "(none)");
                break;
            }
    }
    free_receipts(rc, nrc);
    return status;
}

/* ---- receiver/use closure ----------------------------------------------------------------
 *
 * One ObjcSend per dispatch call. The selector is the operand's recovered name (a cache, a
 * reference slot or a literal) or the one an allocation/opt entry point implies; anything else
 * leaves the send open. The receiver closes, in this order, through:
 *   1. the reader's measured operand: a class cache, class reference or literal class lookup
 *      (a class-method send, "+"); the result of objc_alloc of such a class (an instance of it,
 *      "-"); or the result of another closed send, typed by that method's DECLARED result in the
 *      signature companion -- found on the receiver's class or its declared superclasses -- where
 *      a named class gives an instance of it and instancetype an instance of the sender's class;
 *      a call read once per incoming path (a compiler merged its sends) returns what the path that ran
 *      returned, so its result closes only when every path's result closes to the same class and kind;
 *   2. otherwise, the binding receipt row for the selector's cache, when it names the source-
 *      declared receiver of the binding method that owns that cache.
 * When both apply they must agree (same kind, and the measured class the receipt's class or a
 * declared subclass of it); a disagreement is cannot-measure. A result declared id, an incoming
 * argument, a value the reader did not model, a super send or a send with no receipt stays open:
 * receiver NULL, the reason recorded, and the stage returns 4 -- or, in the analyzer's findings
 * mode, the send becomes an unresolved finding (classify.c). A protocol declaration or some
 * root class's implementation is never used as a receiver. */

#define CLOSE_MAX_DEPTH 64

typedef struct {
    int state;                  /* 0 unvisited, 1 in progress, 2 done */
    const char *selector;       /* borrowed from evidence/bindings */
    char receiver[256], kind[2], basis[768], reason[768];
    ObjcOrigin origin;
    int allocated, exact;
    const char *provenance;     /* borrowed from bindings */
    ObjcRecvFrom recv_from;     /* an open receiver's modelled origin (R3 checks positions against it) */
    size_t recv_send;
} Closure;

static const ObjcEvidence *dispatch_at(const ObjcAnalysis *a, const char *slice, uint64_t site, size_t *index) {
    size_t i;
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        if (e->kind == OBJC_EV_DISPATCH_CALL && e->address == site && !strcmp(e->slice, slice)) {
            *index = i;
            return e;
        }
    }
    return NULL;
}

/* The binding of the selector cache at `addr`, or NULL. */
static const ObjcBinding *cache_binding(const ObjcAnalysis *a, const char *slice, uint64_t addr) {
    size_t i;
    for (i = 0; i < a->n_bindings; i++) {
        const ObjcEvidence *e = &a->evidence[a->bindings[i].evidence];
        if (e->kind == OBJC_EV_SEL_CACHE && e->address == addr && !strcmp(e->slice, slice)) return &a->bindings[i];
    }
    return NULL;
}

static const char *super_of(const ObjcAnalysis *a, const char *cls, int *known) {
    size_t i;
    for (i = 0; i < a->n_classes; i++)
        if (!strcmp(a->classes[i].name, cls)) { *known = 1; return a->classes[i].super; }
    *known = 0;
    return NULL;
}

/* Whether `cls` is `ancestor` or a declared subclass of it. */
static int descends(const ObjcAnalysis *a, const char *cls, const char *ancestor) {
    int depth, known;
    for (depth = 0; cls && depth < CLOSE_MAX_DEPTH; depth++) {
        if (!strcmp(cls, ancestor)) return 1;
        cls = super_of(a, cls, &known);
    }
    return 0;
}

/* The declared result of kind/selector on cls or its first declaring superclass: 1 found (rk,
 * rc set), 0 none declared, -1 conflicting declarations at the first declaring class. */
static int declared_result(const ObjcAnalysis *a, const char *cls, const char *kind, const char *sel,
                           const char **rk, const char **rc, const char **owner) {
    int depth, known;
    for (depth = 0; cls && depth < CLOSE_MAX_DEPTH; depth++) {
        size_t i;
        int found = 0;
        for (i = 0; i < a->n_signatures; i++) {
            const ObjcSignature *s = &a->signatures[i];
            if (strcmp(s->owner, cls) || strcmp(s->method_kind, kind) || strcmp(s->selector, sel) ||
                (strcmp(s->record, "method") && strcmp(s->record, "property-get"))) continue;
            if (found && (strcmp(*rk, s->result_kind) || (!*rc) != (!s->result_class) ||
                          (*rc && strcmp(*rc, s->result_class)))) return -1;
            *rk = s->result_kind; *rc = s->result_class; *owner = s->owner; found = 1;
        }
        if (found) return 1;
        cls = super_of(a, cls, &known);
    }
    return 0;
}

static const char *implied_selector(const char *callee) {
    if (!strcmp(callee, "objc_alloc") || !strcmp(callee, "objc_allocWithZone")) return "alloc";
    if (!strcmp(callee, "objc_opt_new")) return "new";
    if (!strcmp(callee, "objc_opt_class")) return "class";
    if (!strcmp(callee, "objc_opt_self")) return "self";
    if (!strcmp(callee, "objc_opt_isKindOfClass")) return "isKindOfClass:";
    if (!strcmp(callee, "objc_opt_respondsToSelector")) return "respondsToSelector:";
    return NULL;
}

static void close_one(ObjcAnalysis *a, Closure *c, size_t idx, int depth);

/* What dispatch record j (at site) returns, typed (step 1 for a result operand): reason set when not. */
static void result_of(ObjcAnalysis *a, Closure *c, size_t j, uint64_t site, Closure *out, int depth) {
    const ObjcEvidence *d = &a->evidence[j];
    Closure *p;
    const char *rk = NULL, *rc = NULL, *owner = NULL;
    int got;
    close_one(a, c, j, depth + 1);
    p = &c[j];
    if (p->state != 2 || p->reason[0]) {
        snprintf(out->reason, sizeof out->reason, "result of open send 0x%llx", (unsigned long long)site);
        out->recv_from = OBJC_RECV_RESULT; out->recv_send = j;
        return;
    }
    if (!strcmp(d->name, "objc_alloc") || !strcmp(d->name, "objc_allocWithZone")) {
        if (strcmp(p->kind, "+")) { snprintf(out->reason, sizeof out->reason, "allocation from a non-class receiver"); return; }
        snprintf(out->receiver, sizeof out->receiver, "%s", p->receiver);
        strcpy(out->kind, "-");
        out->allocated = 1; out->exact = 1;
        snprintf(out->basis, sizeof out->basis, "allocated %s (0x%llx)", p->receiver, (unsigned long long)site);
        return;
    }
    if (!a->n_signatures) {
        snprintf(out->reason, sizeof out->reason, "result of %s[%s %s]: no signature facts loaded", p->kind, p->receiver, p->selector);
        return;
    }
    got = declared_result(a, p->receiver, p->kind, p->selector, &rk, &rc, &owner);
    if (got <= 0) {
        snprintf(out->reason, sizeof out->reason, "result of %s[%s %s]: %s", p->kind, p->receiver, p->selector,
                 got < 0 ? "conflicting declarations" : "no declared signature");
        return;
    }
    if (!strcmp(rk, "class") || !strcmp(rk, "instancetype")) {
        snprintf(out->receiver, sizeof out->receiver, "%s", !strcmp(rk, "class") ? rc : p->receiver);
        strcpy(out->kind, "-");
        snprintf(out->basis, sizeof out->basis, "result of %s[%s %s] (0x%llx) declared %s by %s", p->kind, p->receiver,
                 p->selector, (unsigned long long)site, !strcmp(rk, "class") ? rc : "instancetype", owner);
        return;
    }
    snprintf(out->reason, sizeof out->reason, "result of %s[%s %s] (0x%llx) is declared %s by %s", p->kind, p->receiver,
             p->selector, (unsigned long long)site, rk, owner);
}

/* Closes the receiver operand of dispatch `e` through the measured value (step 1). */
static void measured_receiver(ObjcAnalysis *a, Closure *c, const ObjcEvidence *e, Closure *out, int depth) {
    const ObjcValue *v = &e->receiver;
    switch (v->form) {
    case OBJC_VAL_CLASS_CACHE: case OBJC_VAL_CLASSREF: case OBJC_VAL_CLASS_LITERAL:
        if (!v->text) { snprintf(out->reason, sizeof out->reason, "class operand without a name"); return; }
        snprintf(out->receiver, sizeof out->receiver, "%s", v->text);
        strcpy(out->kind, "+");
        out->exact = 1;
        snprintf(out->basis, sizeof out->basis, "%s %s",
                 v->form == OBJC_VAL_CLASS_CACHE ? "class-cache" : v->form == OBJC_VAL_CLASSREF ? "classref" : "class-lookup",
                 v->text);
        return;
    case OBJC_VAL_RESULT: {
        /* A call read once per incoming path (macho-reader.c) returns what the path that ran
         * returned: its result closes only when every path's does, to the same class and kind. */
        size_t j, npath = 0;
        Closure first;
        if (!dispatch_at(a, e->slice, v->ref, &j)) { snprintf(out->reason, sizeof out->reason, "result of 0x%llx, not a dispatch", (unsigned long long)v->ref); return; }
        if (depth >= CLOSE_MAX_DEPTH) { snprintf(out->reason, sizeof out->reason, "result chain too deep"); return; }
        memset(&first, 0, sizeof first);
        for (j = 0; j < a->n_evidence; j++) {
            const ObjcEvidence *d = &a->evidence[j];
            Closure r;
            if (d->kind != OBJC_EV_DISPATCH_CALL || d->address != v->ref || strcmp(d->slice, e->slice)) continue;
            memset(&r, 0, sizeof r);
            result_of(a, c, j, v->ref, &r, depth);
            if (r.reason[0]) {
                if (d->incoming) snprintf(out->reason, sizeof out->reason, "result of merged send 0x%llx: on its path from 0x%llx, %s",
                                          (unsigned long long)v->ref, (unsigned long long)d->incoming, r.reason);
                else { memcpy(out->reason, r.reason, sizeof out->reason); out->recv_from = r.recv_from; out->recv_send = r.recv_send; }
                return;
            }
            if (npath++ && (strcmp(first.receiver, r.receiver) || strcmp(first.kind, r.kind) || first.allocated != r.allocated ||
                            first.exact != r.exact)) {
                snprintf(out->reason, sizeof out->reason, "result of merged send 0x%llx: its paths give %s%s and %s%s",
                         (unsigned long long)v->ref, first.kind, first.receiver, r.kind, r.receiver);
                return;
            }
            if (npath == 1) first = r;
            else {
                size_t at = strlen(first.basis);
                snprintf(first.basis + at, sizeof first.basis - at, "; %s", r.basis);
            }
        }
        memcpy(out->receiver, first.receiver, sizeof out->receiver);
        memcpy(out->kind, first.kind, sizeof out->kind);
        out->allocated = first.allocated; out->exact = first.exact;
        if (npath > 1) snprintf(out->basis, sizeof out->basis, "every incoming path of merged send 0x%llx: %s", (unsigned long long)v->ref, first.basis);
        else memcpy(out->basis, first.basis, sizeof out->basis);
        return;
    }
    case OBJC_VAL_ARGUMENT:
        snprintf(out->reason, sizeof out->reason, "receiver is incoming argument %llu of %s",
                 (unsigned long long)v->ref, e->function ? e->function : "an unnamed function");
        out->recv_from = OBJC_RECV_ARGUMENT;
        return;
    default:
        snprintf(out->reason, sizeof out->reason, "receiver value not modelled (a field, merge or computed value)");
        out->recv_from = OBJC_RECV_UNMODELLED;
        return;
    }
}

static void close_one(ObjcAnalysis *a, Closure *c, size_t idx, int depth) {
    const ObjcEvidence *e = &a->evidence[idx];
    Closure *out = &c[idx], m;
    const ObjcBinding *b = NULL;
    const char *implied = implied_selector(e->name);
    if (out->state == 2) return;
    if (out->state == 1) { snprintf(out->reason, sizeof out->reason, "cyclic result chain"); out->state = 2; return; }
    out->state = 1;
    out->receiver[0] = out->kind[0] = out->basis[0] = out->reason[0] = 0;
    out->origin = OBJC_ORIGIN_OPEN; out->allocated = out->exact = 0; out->provenance = NULL;
    out->recv_from = OBJC_RECV_OTHER; out->recv_send = 0;
    if (implied) out->selector = implied;
    else if ((e->sel.form == OBJC_VAL_SEL_CACHE || e->sel.form == OBJC_VAL_SELREF || e->sel.form == OBJC_VAL_SEL_LITERAL) && e->sel.text)
        out->selector = e->sel.text;
    else out->selector = NULL;
    if (!out->selector) {
        snprintf(out->reason, sizeof out->reason, strncmp(e->name, "objc_msgSend", 12) ?
                 "unmodelled dispatch entry point" : "selector operand not recovered");
        out->state = 2;
        return;
    }
    if (strstr(e->name, "Super")) {
        snprintf(out->reason, sizeof out->reason, "super send: the enclosing method's class is not modelled");
        out->state = 2;
        return;
    }
    memset(&m, 0, sizeof m);
    measured_receiver(a, c, e, &m, depth);
    if (e->sel.form == OBJC_VAL_SEL_CACHE) b = cache_binding(a, e->slice, e->sel.ref);
    if (!m.reason[0]) {
        if (b && b->receiver) {
            if (strcmp(b->method_kind, m.kind) || !descends(a, m.receiver, b->receiver)) {
                objc_fail(a, "receiver-receipt-conflict", e->slice, e->address, "measured %s%s, receipt %s%s (%s)",
                          m.kind, m.receiver, b->method_kind, b->receiver, b->provenance ? b->provenance : "-");
                snprintf(out->reason, sizeof out->reason, "measured %s%s contradicts receipt %s%s", m.kind, m.receiver,
                         b->method_kind, b->receiver);
                out->state = 2;
                return;
            }
        }
        memcpy(out->receiver, m.receiver, sizeof out->receiver);
        memcpy(out->kind, m.kind, sizeof out->kind);
        memcpy(out->basis, m.basis, sizeof out->basis);
        out->origin = OBJC_ORIGIN_MEASURED; out->allocated = m.allocated; out->exact = m.exact;
    } else if (b && b->receiver) {
        snprintf(out->receiver, sizeof out->receiver, "%s", b->receiver);
        snprintf(out->kind, sizeof out->kind, "%s", b->method_kind);
        snprintf(out->basis, sizeof out->basis, "receipt %s (%s); measured: %s", b->demangled,
                 b->provenance ? b->provenance : "-", m.reason);
        out->origin = OBJC_ORIGIN_RECEIPT; out->provenance = b->provenance;
    } else {
        memcpy(out->reason, m.reason, sizeof out->reason);
        out->recv_from = m.recv_from; out->recv_send = m.recv_send;
    }
    out->state = 2;
}

int objc_close_sends(ObjcAnalysis *a) {
    Closure *c;
    size_t i;
    int status = OBJC_OK;
    if (!(c = calloc(a->n_evidence ? a->n_evidence : 1, sizeof *c))) return objc_fail(a, "out-of-memory", NULL, 0, "closure");
    for (i = 0; i < a->n_evidence; i++) {
        const ObjcEvidence *e = &a->evidence[i];
        ObjcSend s;
        if (e->kind != OBJC_EV_DISPATCH_CALL) continue;
        close_one(a, c, i, 0);
        memset(&s, 0, sizeof s);
        s.evidence = i;
        s.selector = (char *)c[i].selector;
        if (c[i].reason[0]) {
            s.reason = c[i].reason;
            s.basis = NULL;
            s.recv_from = c[i].recv_from; s.recv_send = c[i].recv_send;
            if (!a->findings_mode) status = objc_fail(a, c[i].selector ? "unresolved-receiver" : "unresolved-selector", e->slice, e->address,
                               "%s %s: %s", e->function ? e->function : "-", c[i].selector ? c[i].selector : "-", c[i].reason);
        } else {
            s.receiver = c[i].receiver; s.method_kind = c[i].kind; s.basis = c[i].basis;
            s.origin = c[i].origin; s.allocated = c[i].allocated; s.exact = c[i].exact;
            s.provenance = (char *)c[i].provenance;
        }
        if (objc_add_send(a, &s)) status = OBJC_CANNOT_MEASURE;
    }
    free(c);
    for (i = 0; i < a->n_errors; i++)
        if (!strcmp(a->errors[i].code, "receiver-receipt-conflict")) status = OBJC_CANNOT_MEASURE;
    return status;
}
