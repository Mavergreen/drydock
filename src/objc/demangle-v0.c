/* demangle-v0.c -- Rust v0 symbols (rustc -C symbol-mangling-version=v0), parsed into paths.
 *
 * One parser, two printings. v0_parse keeps the text binding.c has always matched receipts and
 * type evidence against. v0_parse_rust prints what rustc-demangle's alternate form ("{:#}") prints:
 * crate disambiguators dropped, generic arguments kept, integer, bool and ASCII char constants in
 * decimal or as literals, bound lifetimes named, dyn associated bindings inside the trait's
 * brackets. That is the `path` a reviewed record names. Punycode identifiers, string, reference,
 * aggregate and non-ASCII char constants, pattern types and anything else not implemented are
 * refused, never approximated: tests/objc/fixtures/rustc-demangle-v0.tsv holds rustc-demangle's own
 * test vectors and which of them this parser refuses.
 *
 * objc_demangle_v0 is rustc-demangle's whole demangling of one symbol; objc_v0_function is what
 * drydock-objc resolve needs of a function symbol. */
#include "report.h"
#include "demangle-v0.h"
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct V0Block { struct V0Block *next; };

#define V0_MAX_DEPTH 200u
#define V0_MAX_STEPS 200000u
#define V0_MAX_TEXT (16u << 20)
#define V0_MAX_BOUND 1000u

static int v0_bad(V0 *p, const char *what) {
    if (!p->why[0]) snprintf(p->why, sizeof p->why, "%s at offset %zu", what, p->pos);
    return -1;
}

static void *v0_alloc(V0 *p, size_t n) {
    V0Block *b;
    if (p->rust && (n > V0_MAX_TEXT || (p->used += n) > V0_MAX_TEXT)) { v0_bad(p, "demangling too long"); return NULL; }
    if (!(b = malloc(sizeof(V0Block) + n))) { snprintf(p->why, sizeof p->why, "out of memory"); return NULL; }
    b->next = p->blocks; p->blocks = b;
    return memset(b + 1, 0, n);
}

void v0_release(V0 *p) {
    while (p->blocks) { V0Block *n = p->blocks->next; free(p->blocks); p->blocks = n; }
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

/* rust: a lifetime's index, already read, as rustc-demangle names it. */
static int lifetime_name(V0 *p, uint64_t lt, const char **text) {
    char buf[32];
    if (lt == 0) { *text = "'_"; return 0; }
    if (lt > p->bound) return v0_bad(p, "lifetime not bound");
    if (p->bound - lt < 26) snprintf(buf, sizeof buf, "'%c", (char)('a' + (p->bound - lt)));
    else snprintf(buf, sizeof buf, "'_%llu", (unsigned long long)(p->bound - lt));
    return (*text = cat(p, buf, (char *)NULL)) ? 0 : -1;
}

/* An optional binder ("G"): rust names its lifetimes ("for<'a, 'b> ") and brings them into scope
 * until the caller subtracts *n from p->bound. */
static int binder(V0 *p, const char **text, uint64_t *n) {
    uint64_t i;
    const char *acc = "for<", *one;
    *text = ""; *n = 0;
    if (!eat(p, 'G')) return 0;
    if (base62(p, n)) return -1;
    (*n)++;
    if (!p->rust) { *n = 0; return 0; }
    if (*n > V0_MAX_BOUND) return v0_bad(p, "too many bound lifetimes");
    for (i = 0; i < *n; i++) {
        p->bound++;
        if (lifetime_name(p, 1, &one) || !(acc = cat(p, acc, i ? ", " : "", one, (char *)NULL))) return -1;
    }
    return (*text = cat(p, acc, "> ", (char *)NULL)) ? 0 : -1;
}

/* rust: a constant: a placeholder, an integer, bool or ASCII char, or a backref to one. */
static int const_rust(V0 *p, const char **text) {
    int tag = peek(p), neg = 0, c;
    size_t start, k;
    uint64_t v = 0;
    char buf[48];
    if (tag < 0) return v0_bad(p, "constant past end");
    p->pos++;
    if (tag == 'p') { *text = "_"; return 0; }
    if (tag == 'B') {
        size_t save; int r;
        if (enter(p) || backref_pos(p, &save)) return -1;
        r = const_rust(p, text);
        p->pos = save; p->depth--;
        return r;
    }
    if (!strchr("htmyojaslxnibc", tag)) { p->pos--; return v0_bad(p, "constant not supported"); }
    if (strchr("aslxni", tag)) neg = eat(p, 'n');
    start = p->pos;
    while ((c = peek(p)) != '_') {
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return v0_bad(p, "bad constant");
        p->pos++;
    }
    k = p->pos++ - start;
    if (k > 16) {
        size_t all = k;
        char *h;
        while (k && p->s[start + all - k] == '0') k--;
        if (k > 16) {
            if (tag == 'b' || tag == 'c') return v0_bad(p, "bad constant");
            if (!(h = v0_alloc(p, all + 4))) return -1;
            snprintf(h, all + 4, "%s0x%.*s", neg ? "-" : "", (int)all, p->s + start);
            *text = h;
            return 0;
        }
        start += all - k;
    }
    for (; k; k--, start++) v = v << 4 | (uint64_t)(p->s[start] <= '9' ? p->s[start] - '0' : p->s[start] - 'a' + 10);
    if (tag == 'b') {
        if (v > 1) return v0_bad(p, "bad bool constant");
        *text = v ? "true" : "false";
        return 0;
    }
    if (tag == 'c') {
        if (v > 0x7f) return v0_bad(p, "non-ASCII char constant not supported");
        if (v == '\t') snprintf(buf, sizeof buf, "'\\t'");
        else if (v == '\r') snprintf(buf, sizeof buf, "'\\r'");
        else if (v == '\n') snprintf(buf, sizeof buf, "'\\n'");
        else if (v == '\'' || v == '\\') snprintf(buf, sizeof buf, "'\\%c'", (char)v);
        else if (v == 0) snprintf(buf, sizeof buf, "'\\0'");
        else if (v < 0x20 || v == 0x7f) snprintf(buf, sizeof buf, "'\\u{%llx}'", (unsigned long long)v);
        else snprintf(buf, sizeof buf, "'%c'", (char)v);
    } else snprintf(buf, sizeof buf, "%s%llu", neg ? "-" : "", (unsigned long long)v);
    return (*text = cat(p, buf, (char *)NULL)) ? 0 : -1;
}

static int const_val(V0 *p, const char **text) {
    int c = peek(p);
    if (p->rust) return const_rust(p, text);
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
        if (eat(p, 'L')) {
            uint64_t lt;
            if (base62(p, &lt)) return -1;
            if (!p->rust) one = "'_";
            else if (lifetime_name(p, lt, &one)) return -1;
        }
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
    const char *args = "", *ret = "", *abi = "", *for_ = "";
    uint64_t nb;
    int first = 1, uns;
    if (binder(p, &for_, &nb)) return -1;
    uns = eat(p, 'U');
    if (eat(p, 'K')) {
        if (eat(p, 'C')) abi = "extern \"C\" ";
        else {
            const char *a; char *b;
            if (undis_ident(p, &a)) return -1;
            if (p->rust) {
                if (!*a || !(b = v0_alloc(p, strlen(a) + 1))) return v0_bad(p, "bad ABI");
                for (a = strcpy(b, a); *b; b++) if (*b == '_') *b = '-';
            }
            abi = cat(p, "extern \"", a, "\" ", (char *)NULL);
        }
    }
    while (!eat(p, 'E')) {
        const char *one;
        if (peek(p) < 0) return v0_bad(p, "unterminated fn signature");
        if (type(p, &one, NULL)) return -1;
        args = cat(p, args, first ? "" : ", ", one, (char *)NULL);
        if (!args) return -1;
        first = 0;
    }
    if (p->rust && eat(p, 'u')) ret = "";
    else if (type(p, &ret, NULL) || !(ret = cat(p, " -> ", ret, (char *)NULL))) return -1;
    p->bound -= nb;
    *text = cat(p, for_, uns ? "unsafe " : "", abi, "fn(", args, ")", ret, (char *)NULL);
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

/* rust: a dyn bound's trait, its generic arguments left open ("Trait<A") for associated bindings. */
static int trait_open(V0 *p, const char **text, int *open) {
    V0Path *q;
    const char *args;
    if (enter(p)) return -1;
    if (eat(p, 'B')) {
        size_t save;
        if (backref_pos(p, &save) || trait_open(p, text, open)) return -1;
        p->pos = save;
    } else if (eat(p, 'I')) {
        if (!(q = trait_path(p)) || generic_args(p, &args) || !(*text = cat(p, q->text, "<", args, (char *)NULL))) return -1;
        *open = 1;
    } else {
        if (!(q = trait_path(p))) return -1;
        *text = q->text; *open = 0;
    }
    p->depth--;
    return 0;
}

static int dyn_rust(V0 *p, const char **text) {
    const char *acc, *for_, *one;
    uint64_t nb, lt;
    int first = 1;
    if (binder(p, &for_, &nb) || !(acc = cat(p, "dyn ", for_, (char *)NULL))) return -1;
    while (!eat(p, 'E')) {
        int open;
        if (peek(p) < 0) return v0_bad(p, "unterminated dyn bounds");
        if (trait_open(p, &one, &open) || !(acc = cat(p, acc, first ? "" : " + ", one, (char *)NULL))) return -1;
        while (eat(p, 'p')) {
            const char *name, *ty;
            if (undis_ident(p, &name)) return -1;
            if (eat(p, 'K') ? const_rust(p, &ty) : type(p, &ty, NULL)) return -1;
            if (!(acc = cat(p, acc, open ? ", " : "<", name, " = ", ty, (char *)NULL))) return -1;
            open = 1;
        }
        if (open && !(acc = cat(p, acc, ">", (char *)NULL))) return -1;
        first = 0;
    }
    p->bound -= nb;
    if (!eat(p, 'L') || base62(p, &lt)) return v0_bad(p, "dyn bounds without lifetime");
    if (lt && (lifetime_name(p, lt, &one) || !(acc = cat(p, acc, " + ", one, (char *)NULL)))) return -1;
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
    case 'R': case 'Q': {
        const char *lt = "";
        p->pos++;
        if (p->rust) {
            uint64_t v = 0;
            if (eat(p, 'L') && base62(p, &v)) { r = -1; break; }
            if (v && (lifetime_name(p, v, &lt) || !(lt = cat(p, lt, " ", (char *)NULL)))) { r = -1; break; }
        } else if (eat(p, 'L') && lifetime_skip(p)) { r = -1; break; }
        if (type(p, &inner, NULL)) r = -1;
        else *text = cat(p, "&", lt, c == 'R' ? "" : "mut ", inner, (char *)NULL);
        break;
    }
    case 'P': case 'O':
        p->pos++;
        if (type(p, &inner, NULL)) r = -1;
        else *text = cat(p, c == 'P' ? "*const " : "*mut ", inner, (char *)NULL);
        break;
    case 'F': p->pos++; r = fn_sig(p, text); break;
    case 'D': p->pos++; r = p->rust ? dyn_rust(p, text) : dyn_bounds(p, text); break;
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

const char *v0_ns_text(V0 *p, char ns, const char *id, uint64_t dis) {
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
        else q->text = cat(p, q->parent->text, "::", v0_ns_text(p, q->ns, q->ident, q->dis), (char *)NULL);
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

static V0Path *parse(V0 *p, const char *symbol, int rust) {
    const char *s = symbol, *dot;
    V0Path *top;
    memset(p, 0, sizeof *p);
    p->rust = rust;
    if (s[0] == '_' && s[1] == '_' && s[2] == 'R') s += 3;
    else if (s[0] == '_' && s[1] == 'R') s += 2;
    else { snprintf(p->why, sizeof p->why, "not a Rust v0 symbol"); return NULL; }
    dot = s + strcspn(s, ".$");  /* ".llvm.N", ".0", Mach-O "$tlv$init" */
    p->s = s; p->n = (size_t)(dot - s);
    if (p->pos < p->n && p->s[p->pos] >= '0' && p->s[p->pos] <= '9') {
        snprintf(p->why, sizeof p->why, "versioned v0 encoding not supported");
        return NULL;
    }
    if (rust) {
        const char *b;
        for (b = symbol; *b; b++) if ((unsigned char)*b >= 0x80) { snprintf(p->why, sizeof p->why, "not ASCII"); return NULL; }
    }
    if (!(top = path(p))) { v0_bad(p, "unparsable path"); return NULL; }
    p->top_end = p->pos;
    p->ncrates_top = p->ncrates;
    if (p->pos < p->n && !path(p)) { v0_bad(p, "unparsable instantiating crate"); return NULL; }
    if (p->pos != p->n) { v0_bad(p, "trailing bytes"); return NULL; }
    return top;
}

V0Path *v0_parse(V0 *p, const char *symbol) { return parse(p, symbol, 0); }
V0Path *v0_parse_rust(V0 *p, const char *symbol) { return parse(p, symbol, 1); }

const V0Path *v0_crate_root(const V0Path *q) {
    while (q) {
        switch (q->kind) {
        case 'C': return q;
        case 'N': case 'I': q = q->parent; break;
        case 'M': case 'X': q = q->impl_path; break;
        case 'Y': q = q->self_type; break;
        default: return NULL;
        }
    }
    return NULL;
}

void v0_dis_text(uint64_t dis, char *out, size_t outsz) {
    char tmp[16];
    int n = 0;
    uint64_t v;
    if (dis <= 1) { snprintf(out, outsz, "%s", dis ? "_" : ""); return; }
    v = dis - 2;
    do { int d = (int)(v % 62); tmp[n++] = (char)(d < 10 ? '0' + d : d < 36 ? 'a' + d - 10 : 'A' + d - 36); v /= 62; } while (v && n < 15);
    { int i; for (i = 0; i < n && (size_t)i + 1 < outsz; i++) out[i] = tmp[n - 1 - i]; out[i] = 0; }
}

/* ---- the public API (report.h) -------------------------------------------------------------- */

char *objc_demangle_v0(const char *symbol, char *why, size_t whysz) {
    V0 p;
    V0Path *top;
    const char *llvm = strstr(symbol, ".llvm."), *suffix, *x;
    char *out = NULL, *cut = NULL;
    /* rustc-demangle drops a ".llvm." suffix of hex digits and "@" alone, and keeps any other
     * suffix that starts with "." and is ASCII letters, digits and punctuation. */
    if (llvm) {
        for (x = llvm + 6; *x && ((*x >= '0' && *x <= '9') || (*x >= 'A' && *x <= 'F') || *x == '@'); x++) ;
        if (!*x && (cut = strdup(symbol))) cut[llvm - symbol] = 0;
        else if (!*x) { snprintf(why, whysz, "out of memory"); return NULL; }
    }
    if (!(top = v0_parse_rust(&p, cut ? cut : symbol))) {
        snprintf(why, whysz, "%s", p.why);
    } else {
        suffix = p.s + p.n;
        for (x = suffix; *x && *x > 0x20 && *x < 0x7f; x++) ;
        if (*suffix && (*suffix != '.' || *x)) snprintf(why, whysz, "suffix %s is not symbol-like", suffix);
        else if (!(out = malloc(strlen(top->text) + strlen(suffix) + 1))) snprintf(why, whysz, "out of memory");
        else strcat(strcpy(out, top->text), suffix);
    }
    v0_release(&p);
    free(cut);
    return out;
}

int objc_v0_copy_suffix(const char *s) {
    while (*s) {
        if (!strncmp(s, ".llvm.", 6) && isalnum((unsigned char)s[6])) for (s += 6; isalnum((unsigned char)*s); s++) ;
        else if (!strncmp(s, ".cold", 5)) {
            s += 5;
            if (*s == '.' && isdigit((unsigned char)s[1])) for (s++; isdigit((unsigned char)*s); s++) ;
        } else return 0;
    }
    return 1;
}

void objc_v0_function_free(ObjcV0Function *f) {
    free(f->path); free(f->own); free(f->suffix); free(f->roots); free(f->crate); free(f->crate_dis);
    memset(f, 0, sizeof *f);
}

int objc_v0_function(const char *symbol, ObjcV0Function *f, char *why, size_t whysz) {
    V0 p;
    V0Path *top;
    const V0Path *root;
    size_t at = 0, k;
    int i, rc = -1;
    memset(f, 0, sizeof *f);
    if (!(top = v0_parse_rust(&p, symbol))) { snprintf(why, whysz, "%s", p.why); v0_release(&p); return -1; }
    root = v0_crate_root(top);
    if (p.crates_overflow) snprintf(why, whysz, "more crate roots than this reader records");
    else if (!root) snprintf(why, whysz, "no crate root");
    else if (!(f->path = strdup(top->text)) || !(f->own = malloc(p.top_end + 1)) || !(f->suffix = strdup(p.s + p.n)) ||
             !(f->crate = strdup(root->ident)) || !(f->crate_dis = malloc(16)) || !(f->roots = malloc(1)))
        snprintf(why, whysz, "out of memory");
    else {
        memcpy(f->own, p.s, p.top_end); f->own[p.top_end] = 0;
        f->instantiated = p.top_end < p.n;
        v0_dis_text(root->dis, f->crate_dis, 16);
        f->roots[0] = 0;
        rc = 0;
        for (i = 0; i < p.ncrates_top && !rc; i++) {
            char d[16], *g;
            v0_dis_text(p.crates[i].dis, d, sizeof d);
            k = strlen(p.crates[i].id) + strlen(d) + 2;
            if (!(g = realloc(f->roots, at + k + 1))) { snprintf(why, whysz, "out of memory"); rc = -1; break; }
            f->roots = g;
            snprintf(f->roots + at, k, "%s=%s", p.crates[i].id, d);
            at += k; f->roots[at] = 0;
        }
    }
    v0_release(&p);
    if (rc) objc_v0_function_free(f);
    return rc;
}
