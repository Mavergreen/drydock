/* objc-source-inventory.c -- a receipt of every Objective-C message a provider's prepared source
 * sends, with the receiver's static type, via libclang. Generation only: the analyzer
 * (tools/objc-compat/source-evidence.c) reads the receipt and never loads libclang.
 *
 *   objc-source-inventory --resource-dir DIR --sdk SDKROOT --tool-id HEX --inputs FILE --root DIR [--root DIR ...]
 *                         --unit LABEL [--unit LABEL ...] [--include LABELDIR ...] --output NEW_FILE
 *
 * Inputs are bounded and verified before anything is parsed. FILE lists the prepared source as
 * `SHA256  LABEL` lines (shasum's format; Recaulk's build writes exactly this receipt and its
 * provider declaration carries it as source_inputs_receipt). Each LABEL is a relative path with no
 * "..", found under exactly one --root, a regular file whose bytes hash to SHA256. Every input is
 * copied into a private staging tree at its label, so what is parsed is what was hashed, and the
 * units (--unit, each an input) are parsed from there. Include directories (--include) are
 * staged label directories. Nothing is executed: there is no compile command, plugin or response
 * file to take, and the compile arguments are one fixed profile, recaulk-objc-x86_64-10.9:
 *
 *   -x objective-c -target x86_64-apple-macos10.9 -isysroot SDK -resource-dir DIR -nostdinc
 *   -isystem DIR/include -isystem SDK/usr/include -iframework SDK/System/Library/Frameworks
 *   -fno-objc-arc -fblocks -Os -fPIC -Wall -Wno-deprecated-declarations [-I STAGE/LABELDIR ...]
 *
 * which mirrors Recaulk's build/build-objc.sh (-arch x86_64 -mmacosx-version-min=10.9 -fno-objc-arc
 * -Os -fPIC -Wall -Wno-deprecated-declarations -I WORK/generated). An error diagnostic, or an
 * included file outside the staging tree, the SDK and the compiler's resource headers, refuses.
 *
 * The receipt, schema 1, is TAB-separated text, written exclusively and atomically:
 *   # objc-source-receipt 1
 *   profile  recaulk-objc-x86_64-10.9
 *   args     the argument vector, the SDK, resource and staging paths written <sdk> <resource> <stage>
 *   libclang clang_getClangVersion()
 *   sdk      SHA-256 of SDK/SDKSettings.plist
 *   tool     --tool-id (the wrapper's digest of this file)
 *   input    LABEL SHA256           (every input, sorted)
 *   unit     LABEL                  (sorted)
 *   send     LABEL SPAN ANCHORS FORM KIND SELECTOR RECEIVER TYPE OWNER   (sorted, unique)
 * One send row per message the compiler emits for source in a staged input:
 *   SPAN      SL:SC-EL:EC, the expression's extent (for-in: the whole statement)
 *   ANCHORS   L:C,... the starts of the statements and full expressions enclosing it, innermost
 *             last; a compiler that attributes code to a statement's first line lands on one
 *   FORM      message, super, property-get, property-set, for-in, dictionary-literal,
 *             array-literal, or unmodelled (a boxed expression, @(x) @1 @YES: its selector is "-",
 *             so no binary send maps to it). Subscripts and any other send the compiler makes that
 *             this walk does not model get no row, so the analyzer refuses their sends (unmapped)
 *   KIND      + or -, from the referenced declaration, else the receiver (a class or Class is +)
 *   RECEIVER  the class of the receiver's static type -- an interface pointer (protocol
 *             qualifiers and typedefs looked through) or a class name -- or "-" for id, Class,
 *             id<P>, a type parameter, super or anything else: never a guess
 *   TYPE      libclang's spelling of the receiver's static type
 *   OWNER     the referenced method's container -- CLASS, CLASS(CATEGORY), <PROTOCOL> -- or "-";
 *             recorded apart from RECEIVER, never used for it
 * Exit 0 written, 2 usage, 4 an unverifiable input, a parse error or an unwritable output. */
/* platform: realpath, mkdtemp and lstat under -std=c99: _XOPEN_SOURCE on glibc, _DARWIN_C_SOURCE keeps the rest visible on a Mac */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include <clang-c/Index.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define INPUT_MAX (4u << 20)
#define INPUTS_MAX 256
#define ANCHORS_MAX 64

static void cannot(const char *format, ...) __attribute__((noreturn, format(printf, 1, 2)));
static void cannot(const char *format, ...) {
    va_list ap;
    fprintf(stderr, "objc-source-inventory: ");
    va_start(ap, format);
    vfprintf(stderr, format, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(4);
}
static void *allocate(size_t size) {
    void *p = calloc(1, size ? size : 1);
    if (!p) cannot("out of memory");
    return p;
}
static char *copy(const char *s) { char *p = allocate(strlen(s) + 1); strcpy(p, s); return p; }
static char *format(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static char *format(const char *fmt, ...) {
    va_list ap;
    char *p;
    va_start(ap, fmt);
    if (vasprintf(&p, fmt, ap) < 0) cannot("out of memory");
    va_end(ap);
    return p;
}
static int usage(void) {
    fprintf(stderr, "usage: objc-source-inventory --resource-dir DIR --sdk SDKROOT --tool-id HEX --inputs FILE --root DIR "
                    "[--root DIR ...] --unit LABEL [--unit LABEL ...] [--include LABELDIR ...] --output NEW_FILE\n");
    return 2;
}

static int hex64(const char *s) {
    size_t i;
    for (i = 0; i < 64; i++) if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return 0;
    return s[64] == 0;
}
static int read_bounded(const char *path, size_t max, char **buf, size_t *size) {
    struct stat st;
    FILE *f = NULL;
    *buf = NULL;
    if (lstat(path, &st) || !S_ISREG(st.st_mode) || (uint64_t)st.st_size > max || !(f = fopen(path, "rb"))) { if (f) fclose(f); return -1; }
    *size = (size_t)st.st_size;
    *buf = allocate(*size + 1);
    if (fread(*buf, 1, *size, f) != *size) { fclose(f); free(*buf); *buf = NULL; return -1; }
    fclose(f);
    return 0;
}
/* spec: FIPS 180-4 section 6.2 -- SHA-256, here so the producer builds on Linux as on a Mac (no CommonCrypto). */
static const uint32_t SHA_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha_block(uint32_t h[8], const unsigned char *b) {
    uint32_t w[64], a[8], t1, t2;
    int i;
    for (i = 0; i < 16; i++) w[i] = (uint32_t)b[4 * i] << 24 | (uint32_t)b[4 * i + 1] << 16 | (uint32_t)b[4 * i + 2] << 8 | b[4 * i + 3];
    for (; i < 64; i++)
        w[i] = (ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10)) + w[i - 7] +
               (ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 16];
    memcpy(a, h, sizeof a);
    for (i = 0; i < 64; i++) {
        t1 = a[7] + (ROR(a[4], 6) ^ ROR(a[4], 11) ^ ROR(a[4], 25)) + ((a[4] & a[5]) ^ (~a[4] & a[6])) + SHA_K[i] + w[i];
        t2 = (ROR(a[0], 2) ^ ROR(a[0], 13) ^ ROR(a[0], 22)) + ((a[0] & a[1]) ^ (a[0] & a[2]) ^ (a[1] & a[2]));
        memmove(a + 1, a, 7 * sizeof *a);
        a[4] += t1; a[0] = t1 + t2;
    }
    for (i = 0; i < 8; i++) h[i] += a[i];
}
static void sha256(const void *p, size_t n, char out[65]) {
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    const unsigned char *s = p;
    unsigned char tail[128];
    uint64_t bits = (uint64_t)n * 8;
    size_t i, left, len;
    for (i = 0; i + 64 <= n; i += 64) sha_block(h, s + i);
    left = n - i;
    memset(tail, 0, sizeof tail);
    if (left) memcpy(tail, s + i, left);
    tail[left] = 0x80;
    len = left < 56 ? 64 : 128;
    for (i = 0; i < 8; i++) tail[len - 1 - i] = (unsigned char)(bits >> (8 * i));
    sha_block(h, tail);
    if (len == 128) sha_block(h, tail + 64);
    for (i = 0; i < 8; i++) snprintf(out + 8 * i, 9, "%08x", (unsigned)h[i]);
}
/* A relative label: [A-Za-z0-9._+-] components joined by '/', none empty, "." or "..". */
static int label_ok(const char *s) {
    const char *c = s;
    if (!*s || *s == '/' || strlen(s) > 400) return 0;
    while (*c) {
        const char *e = strchr(c, '/');
        size_t n = e ? (size_t)(e - c) : strlen(c), i;
        if (!n || (n == 1 && c[0] == '.') || (n == 2 && c[0] == '.' && c[1] == '.')) return 0;
        for (i = 0; i < n; i++) {
            char ch = c[i];
            if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '.' || ch == '_' ||
                  ch == '-' || ch == '+'))
                return 0;
        }
        c += n; if (*c == '/') c++; else break;
    }
    return s[strlen(s) - 1] != '/';
}
static void make_dirs(const char *path) {   /* every directory above path */
    char *p = copy(path), *s;
    for (s = p + 1; (s = strchr(s, '/')); s++) {
        *s = 0;
        if (mkdir(p, 0700) && errno != EEXIST) cannot("cannot create %s", p);
        *s = '/';
    }
    free(p);
}

typedef struct { char *label, *sha, *staged; } Input;
static Input inputs[INPUTS_MAX];
static size_t ninputs;

/* ---- send rows ------------------------------------------------------------------------------ */

typedef struct { unsigned line, col; } Pos;
typedef struct { Pos a[ANCHORS_MAX]; size_t n; } Anchors;
static char **rows;
static size_t nrows, caprows;

static void add_row(char *row) {
    if (nrows == caprows) {
        char **g = realloc(rows, (caprows = caprows ? caprows * 2 : 256) * sizeof *g);
        if (!g) cannot("out of memory");
        rows = g;
    }
    rows[nrows++] = row;
}
static int compare(const void *x, const void *y) { return strcmp(*(char *const *)x, *(char *const *)y); }

/* The staged input a location lies in (by expansion), or NULL. */
static const Input *input_of(CXSourceLocation loc, unsigned *line, unsigned *col) {
    CXFile f;
    CXString name;
    const char *s;
    const Input *found = NULL;
    size_t i;
    clang_getExpansionLocation(loc, &f, line, col, NULL);
    if (!f) return NULL;
    name = clang_getFileName(f);
    s = clang_getCString(name);
    for (i = 0; s && i < ninputs; i++) if (!strcmp(s, inputs[i].staged)) { found = &inputs[i]; break; }
    clang_disposeString(name);
    return found;
}

/* The class of a receiver's static type, or NULL; *meta is set for a class receiver. */
static char *receiver_class(CXType t, int *meta) {
    CXType c = clang_getCanonicalType(t), p;
    *meta = 0;
    if (c.kind == CXType_ObjCInterface) { *meta = 1; p = c; }
    else if (c.kind == CXType_ObjCObjectPointer) {
        p = clang_getPointeeType(c);
        if (p.kind == CXType_ObjCObject) p = clang_Type_getObjCObjectBaseType(p);
        if (p.kind != CXType_ObjCInterface) return NULL;
    } else {
        if (c.kind == CXType_ObjCClass) *meta = 1;
        return NULL;
    }
    {
        CXCursor d = clang_getTypeDeclaration(p);
        CXString n = clang_getCursorSpelling(d);
        char *r = clang_getCString(n) && *clang_getCString(n) ? copy(clang_getCString(n)) : NULL;
        clang_disposeString(n);
        return r;
    }
}

static enum CXChildVisitResult first_child(CXCursor c, CXCursor parent, CXClientData data) {
    (void)parent;
    *(CXCursor *)data = c;
    return CXChildVisit_Break;
}
static enum CXChildVisitResult category_class(CXCursor c, CXCursor parent, CXClientData data) {
    (void)parent;
    if (clang_getCursorKind(c) == CXCursor_ObjCClassRef) {
        CXString n = clang_getCursorSpelling(c);
        *(char **)data = copy(clang_getCString(n));
        clang_disposeString(n);
        return CXChildVisit_Break;
    }
    return CXChildVisit_Continue;
}
static char *owner(CXCursor method) {
    CXCursor parent;
    CXString n;
    char *r, *cls = NULL;
    if (clang_Cursor_isNull(method) || clang_isInvalid(clang_getCursorKind(method))) return copy("-");
    parent = clang_getCursorSemanticParent(method);
    n = clang_getCursorSpelling(parent);
    switch (clang_getCursorKind(parent)) {
    case CXCursor_ObjCInterfaceDecl: case CXCursor_ObjCImplementationDecl: r = copy(clang_getCString(n)); break;
    case CXCursor_ObjCProtocolDecl: r = format("<%s>", clang_getCString(n)); break;
    case CXCursor_ObjCCategoryDecl: case CXCursor_ObjCCategoryImplDecl:
        clang_visitChildren(parent, category_class, &cls);
        r = format("%s(%s)", cls ? cls : "?", clang_getCString(n));
        free(cls);
        break;
    default: r = copy("-"); break;
    }
    clang_disposeString(n);
    return r;
}

static char *anchors_text(const Anchors *an) {
    size_t i, len = 1;
    char *s, *p;
    for (i = 0; i < an->n; i++) len += 24;
    p = s = allocate(len + 2);
    for (i = 0; i < an->n; i++) p += sprintf(p, "%s%u:%u", i ? "," : "", an->a[i].line, an->a[i].col);
    if (!an->n) strcpy(s, "-");
    return s;
}

static void emit(const Input *in, CXCursor span, const Anchors *an, const char *form, const char *kind, const char *sel,
                 CXType recv, int have_recv, const char *forced_class, CXCursor method) {
    CXSourceRange r = clang_getCursorExtent(span);
    unsigned sl, sc, el, ec;
    int meta = 0;
    char *cls = NULL, *own, *anc, *spelled;
    const char *k = kind;
    CXString ts;
    input_of(clang_getRangeStart(r), &sl, &sc);
    input_of(clang_getRangeEnd(r), &el, &ec);
    if (forced_class) cls = copy(forced_class);
    else if (have_recv) cls = receiver_class(recv, &meta);
    if (!k) k = meta ? "+" : "-";
    ts = have_recv ? clang_getTypeSpelling(recv) : clang_getCursorSpelling(span);
    spelled = copy(have_recv ? clang_getCString(ts) : "-");
    clang_disposeString(ts);
    {
        char *t;
        for (t = spelled; *t; t++) if (*t == '\t' || *t == '\n') *t = ' ';
    }
    own = owner(method);
    anc = anchors_text(an);
    add_row(format("send\t%s\t%u:%u-%u:%u\t%s\t%s\t%s\t%s\t%s\t%s\t%s", in->label, sl, sc, el, ec, anc, form, k, sel,
                   cls ? cls : "-", have_recv ? spelled : "-", own));
    free(cls); free(own); free(anc); free(spelled);
}

/* The first two token spellings of a cursor's extent, for literal and super detection. */
static void lead_tokens(CXTranslationUnit tu, CXCursor c, char *t0, char *t1, size_t n) {
    CXToken *toks = NULL;
    unsigned nt = 0;
    t0[0] = t1[0] = 0;
    clang_tokenize(tu, clang_getCursorExtent(c), &toks, &nt);
    if (nt > 0) { CXString s = clang_getTokenSpelling(tu, toks[0]); snprintf(t0, n, "%s", clang_getCString(s)); clang_disposeString(s); }
    if (nt > 1) { CXString s = clang_getTokenSpelling(tu, toks[1]); snprintf(t1, n, "%s", clang_getCString(s)); clang_disposeString(s); }
    if (toks) clang_disposeTokens(tu, toks, nt);
}

typedef struct { CXCursor k[3]; int n; } Kids;
static enum CXChildVisitResult collect_kids(CXCursor c, CXCursor parent, CXClientData data) {
    Kids *kd = data;
    (void)parent;
    if (kd->n < 3) kd->k[kd->n] = c;
    kd->n++;
    return CXChildVisit_Continue;
}

typedef struct Walk {
    CXTranslationUnit tu;
    Anchors an;
    CXCursor parent;
    int parent_is_stmt;
} Walk;

static enum CXChildVisitResult walk(CXCursor c, CXCursor parent, CXClientData data);

static int is_stmt(enum CXCursorKind k) { return clang_isStatement(k) || k == CXCursor_DeclStmt; }

static void property(Walk *w, const Input *in, CXCursor c, CXCursor ref) {
    CXCursor base = clang_getNullCursor();
    enum CXCursorKind pk = clang_getCursorKind(w->parent);
    int get = 1, set = 0, haveb;
    char *getter = NULL, *setter = NULL;
    CXString g;
    clang_visitChildren(c, first_child, &base);
    haveb = !clang_Cursor_isNull(base);
    if ((pk == CXCursor_BinaryOperator && clang_getCursorBinaryOperatorKind(w->parent) == CXBinaryOperator_Assign) ||
        pk == CXCursor_CompoundAssignOperator) {
        CXCursor lhs = clang_getNullCursor();
        clang_visitChildren(w->parent, first_child, &lhs);
        if (clang_equalCursors(lhs, c)) {
            set = 1;
            get = pk == CXCursor_CompoundAssignOperator;
        }
    } else if (pk == CXCursor_UnaryOperator) {
        enum CXUnaryOperatorKind u = clang_getCursorUnaryOperatorKind(w->parent);
        if (u == CXUnaryOperator_PostInc || u == CXUnaryOperator_PostDec || u == CXUnaryOperator_PreInc || u == CXUnaryOperator_PreDec) set = 1;
    }
    if (clang_getCursorKind(ref) == CXCursor_ObjCPropertyDecl) {
        g = clang_Cursor_getObjCPropertyGetterName(ref); getter = copy(clang_getCString(g)); clang_disposeString(g);
        g = clang_Cursor_getObjCPropertySetterName(ref); setter = copy(clang_getCString(g)); clang_disposeString(g);
    } else {   /* an implicit property: the getter or setter method itself */
        g = clang_getCursorSpelling(ref);
        getter = copy(clang_getCString(g)); setter = copy(clang_getCString(g));
        clang_disposeString(g);
    }
    if (haveb && clang_getCursorKind(base) == CXCursor_ObjCClassRef) {   /* Class.property */
        CXString n = clang_getCursorSpelling(base);
        if (get) emit(in, c, &w->an, "property-get", "+", getter, clang_getCursorType(base), 0, clang_getCString(n), ref);
        if (set) emit(in, c, &w->an, "property-set", "+", setter, clang_getCursorType(base), 0, clang_getCString(n), ref);
        clang_disposeString(n);
    } else {
        CXType t = haveb ? clang_getCursorType(base) : clang_getCursorType(c);
        if (get) emit(in, c, &w->an, "property-get", NULL, getter, t, haveb, NULL, ref);
        if (set) emit(in, c, &w->an, "property-set", NULL, setter, t, haveb, NULL, ref);
    }
    free(getter); free(setter);
}

static enum CXChildVisitResult walk(CXCursor c, CXCursor parent, CXClientData data) {
    Walk *w = data, sub;
    enum CXCursorKind k = clang_getCursorKind(c);
    unsigned line = 0, col = 0;
    const Input *in = input_of(clang_getCursorLocation(c), &line, &col);
    (void)parent;
    sub = *w;
    sub.parent = c;
    sub.parent_is_stmt = is_stmt(k);
    if (in && (is_stmt(k) || (clang_isExpression(k) && w->parent_is_stmt))) {
        CXSourceRange r = clang_getCursorExtent(c);
        unsigned l, cc;
        input_of(clang_getRangeStart(r), &l, &cc);
        if (sub.an.n == ANCHORS_MAX) cannot("statements nested deeper than %d", ANCHORS_MAX);
        sub.an.a[sub.an.n].line = l; sub.an.a[sub.an.n].col = cc; sub.an.n++;
    }
    if (in) {
        if (k == CXCursor_ObjCMessageExpr) {
            CXString s = clang_getCursorSpelling(c);
            CXCursor m = clang_getCursorReferenced(c);
            enum CXCursorKind mk = clang_getCursorKind(m);
            const char *kind = mk == CXCursor_ObjCClassMethodDecl ? "+" : mk == CXCursor_ObjCInstanceMethodDecl ? "-" : NULL;
            char t0[64], t1[64];
            lead_tokens(w->tu, c, t0, t1, sizeof t0);
            if (!strcmp(t0, "[") && !strcmp(t1, "super"))
                emit(in, c, &sub.an, "super", kind, clang_getCString(s), clang_getCursorType(c), 0, NULL, m);
            else
                emit(in, c, &sub.an, "message", kind, clang_getCString(s), clang_Cursor_getReceiverType(c), 1, NULL, m);
            clang_disposeString(s);
        } else if (k == CXCursor_MemberRefExpr) {
            CXCursor ref = clang_getCursorReferenced(c);
            enum CXCursorKind rk = clang_getCursorKind(ref);
            if (rk == CXCursor_ObjCPropertyDecl || rk == CXCursor_ObjCInstanceMethodDecl || rk == CXCursor_ObjCClassMethodDecl)
                property(w, in, c, ref);
        } else if (k == CXCursor_ObjCForCollectionStmt) {
            /* Children: the element (a declaration or an expression), the collection, the body. */
            Kids kids;
            memset(&kids, 0, sizeof kids);
            clang_visitChildren(c, collect_kids, &kids);
            if (kids.n < 2) cannot("a for-in statement without a collection at %s:%u", in->label, line);
            emit(in, c, &sub.an, "for-in", "-", "countByEnumeratingWithState:objects:count:", clang_getCursorType(kids.k[1]), 1,
                 NULL, clang_getNullCursor());
        } else if (k == CXCursor_UnexposedExpr || k == CXCursor_ObjCStringLiteral) {
            char t0[64], t1[64];
            lead_tokens(w->tu, c, t0, t1, sizeof t0);
            if (!strcmp(t0, "@") && !strcmp(t1, "{"))
                emit(in, c, &sub.an, "dictionary-literal", "+", "dictionaryWithObjects:forKeys:count:", clang_getCursorType(c), 0,
                     "NSDictionary", clang_getNullCursor());
            else if (!strcmp(t0, "@") && !strcmp(t1, "["))
                emit(in, c, &sub.an, "array-literal", "+", "arrayWithObjects:count:", clang_getCursorType(c), 0, "NSArray",
                     clang_getNullCursor());
            else if (!strcmp(t0, "@") && strcmp(t1, "\"") && t1[0] != '"' && strcmp(t1, "selector") && strcmp(t1, "encode") &&
                     strcmp(t1, "protocol") && strcmp(t1, "available"))
                emit(in, c, &sub.an, "unmodelled", "-", "-", clang_getCursorType(c), 0, NULL, clang_getNullCursor());
        }
    }
    clang_visitChildren(c, walk, &sub);
    return CXChildVisit_Continue;
}

/* ---- inclusions ----------------------------------------------------------------------------- */

typedef struct { const char *sdk, *resource; char *bad; } Allowed;
static int under(const char *path, const char *dir) {
    size_t n = strlen(dir);
    return !strncmp(path, dir, n) && path[n] == '/';
}
static void included(CXFile f, CXSourceLocation *stack, unsigned depth, CXClientData data) {
    Allowed *al = data;
    CXString n = clang_getFileName(f);
    const char *s = clang_getCString(n);
    size_t i;
    int ok = 0;
    (void)stack; (void)depth;
    char *real = s ? realpath(s, NULL) : NULL;
    if (real && (under(real, al->sdk) || under(real, al->resource))) ok = 1;
    for (i = 0; !ok && s && i < ninputs; i++) if (!strcmp(s, inputs[i].staged)) ok = 1;
    if (!ok && !al->bad) al->bad = copy(s ? s : "(unnamed)");
    free(real);
    clang_disposeString(n);
}

/* ---- main ----------------------------------------------------------------------------------- */

static char stage[PATH_MAX];
/* The private staging tree, on every exit: each staged file, then its directories up to the stage. */
static void remove_stage(void) {
    size_t i;
    if (!stage[0]) return;
    for (i = 0; i < ninputs; i++) {
        char *p, *s;
        if (!inputs[i].staged) continue;
        unlink(inputs[i].staged);
        p = copy(inputs[i].staged);
        while ((s = strrchr(p, '/')) && (size_t)(s - p) > strlen(stage)) { *s = 0; rmdir(p); }
        free(p);
    }
    rmdir(stage);
}

int main(int argc, char **argv) {
    const char *resource = NULL, *sdk_arg = NULL, *tool = NULL, *inputs_path = NULL, *output = NULL;
    const char *roots[16], *units[INPUTS_MAX], *includes[16];
    size_t nroots = 0, nunits = 0, nincludes = 0, i, j;
    char *sdk, *resource_dir, *buf, *line, *save = NULL, sdk_sha[65], *temporary;
    size_t size;
    struct stat st;
    int fd;
    FILE *out;
    CXIndex index;
    for (i = 1; i < (size_t)argc; i++) {
        const char *o = argv[i], *v;
        if (i + 1 >= (size_t)argc || !*argv[i + 1]) return usage();
        v = argv[++i];
        if (!strcmp(o, "--resource-dir") && !resource) resource = v;
        else if (!strcmp(o, "--sdk") && !sdk_arg) sdk_arg = v;
        else if (!strcmp(o, "--tool-id") && !tool) tool = v;
        else if (!strcmp(o, "--inputs") && !inputs_path) inputs_path = v;
        else if (!strcmp(o, "--output") && !output) output = v;
        else if (!strcmp(o, "--root") && nroots < 16) roots[nroots++] = v;
        else if (!strcmp(o, "--unit") && nunits < INPUTS_MAX) units[nunits++] = v;
        else if (!strcmp(o, "--include") && nincludes < 16) includes[nincludes++] = v;
        else return usage();
    }
    if (!resource || !sdk_arg || !tool || !inputs_path || !output || !nroots || !nunits) return usage();
    if (!hex64(tool)) return usage();
    if (!lstat(output, &st) || errno != ENOENT) { fprintf(stderr, "objc-source-inventory: the output exists or is unusable: %s\n", output); return 2; }
    if (!(sdk = realpath(sdk_arg, NULL)) || !(resource_dir = realpath(resource, NULL)))
        cannot("the SDK or resource directory does not exist");
    {
        char *settings = format("%s/SDKSettings.plist", sdk);
        if (read_bounded(settings, INPUT_MAX, &buf, &size)) cannot("unreadable %s", settings);
        sha256(buf, size, sdk_sha);
        free(buf); free(settings);
    }

    /* The verified inputs. */
    if (read_bounded(inputs_path, 1u << 20, &buf, &size)) cannot("unreadable input list %s", inputs_path);
    if (memchr(buf, 0, size)) cannot("a NUL byte in %s", inputs_path);
    for (line = strtok_r(buf, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        char *sha = line, *label;
        if (strlen(line) < 67 || line[64] != ' ' || line[65] != ' ') cannot("not a `SHA256  LABEL` line: %s", line);
        line[64] = 0; label = line + 66;
        if (!hex64(sha) || !label_ok(label)) cannot("bad input line for %s", label);
        if (ninputs == INPUTS_MAX) cannot("over %d inputs", INPUTS_MAX);
        for (j = 0; j < ninputs; j++) if (!strcmp(inputs[j].label, label)) cannot("%s listed twice", label);
        inputs[ninputs].label = copy(label); inputs[ninputs].sha = copy(sha); ninputs++;
    }
    free(buf);
    if (!ninputs) cannot("no inputs in %s", inputs_path);
    {
        const char *tmp = getenv("TMPDIR");
        snprintf(stage, sizeof stage, "%s/objc-source-inventory.XXXXXX", tmp && *tmp ? tmp : "/tmp");
        if (!mkdtemp(stage)) { stage[0] = 0; cannot("cannot create a staging directory"); }
        atexit(remove_stage);
        {
            char *r = realpath(stage, NULL);
            if (!r) cannot("cannot resolve the staging directory");
            snprintf(stage, sizeof stage, "%s", r);
            free(r);
        }
    }
    for (i = 0; i < ninputs; i++) {
        const char *found = NULL;
        char *path = NULL, got[65];
        FILE *w;
        for (j = 0; j < nroots; j++) {
            char *p = format("%s/%s", roots[j], inputs[i].label);
            if (!lstat(p, &st)) {
                if (found) cannot("%s is under more than one --root", inputs[i].label);
                found = roots[j]; free(path); path = p;
            } else free(p);
        }
        if (!found) cannot("%s is under no --root", inputs[i].label);
        if (read_bounded(path, INPUT_MAX, &buf, &size)) cannot("%s is not a readable regular file", path);
        sha256(buf, size, got);
        if (strcmp(got, inputs[i].sha)) cannot("%s hashes to %s, the input list says %s", inputs[i].label, got, inputs[i].sha);
        inputs[i].staged = format("%s/%s", stage, inputs[i].label);
        make_dirs(inputs[i].staged);
        if (!(w = fopen(inputs[i].staged, "wx")) || fwrite(buf, 1, size, w) != size || fclose(w))
            cannot("cannot stage %s", inputs[i].label);
        free(buf); free(path);
    }
    for (i = 0; i < nunits; i++) {
        for (j = 0; j < ninputs && strcmp(inputs[j].label, units[i]); j++) ;
        if (j == ninputs) cannot("unit %s is not an input", units[i]);
    }
    for (i = 0; i < nincludes; i++) {
        char *d = format("%s/%s", stage, includes[i]);
        if (!label_ok(includes[i]) || stat(d, &st) || !S_ISDIR(st.st_mode)) cannot("include %s is not a staged input directory", includes[i]);
        free(d);
    }

    /* The profile. */
    {
        const char *ambient[] = {"CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "SDKROOT", "CCC_OVERRIDE_OPTIONS"};
        for (i = 0; i < sizeof ambient / sizeof *ambient; i++) if (unsetenv(ambient[i])) cannot("cannot clear the ambient compiler environment");
    }
    char *resource_include = format("%s/include", resource_dir), *sdk_include = format("%s/usr/include", sdk),
         *frameworks = format("%s/System/Library/Frameworks", sdk);
    const char *fixed[] = {"-x", "objective-c", "-target", "x86_64-apple-macos10.9", "-isysroot", sdk, "-resource-dir", resource_dir,
                           "-nostdinc", "-isystem", resource_include, "-isystem", sdk_include, "-iframework", frameworks,
                           "-fno-objc-arc", "-fblocks", "-Os", "-fPIC", "-Wall", "-Wno-deprecated-declarations"};
    size_t nfixed = sizeof fixed / sizeof *fixed, nargs = nfixed + 2 * nincludes;
    const char **args = allocate(nargs * sizeof *args);
    char *argtext = copy("");
    for (i = 0; i < nfixed; i++) args[i] = fixed[i];
    for (i = 0; i < nincludes; i++) { args[nfixed + 2 * i] = "-I"; args[nfixed + 2 * i + 1] = format("%s/%s", stage, includes[i]); }
    for (i = 0; i < nargs; i++) {
        const char *s = args[i];
        char *piece, *next;
        if (!strncmp(s, resource_dir, strlen(resource_dir))) piece = format("<resource>%s", s + strlen(resource_dir));
        else if (!strncmp(s, sdk, strlen(sdk))) piece = format("<sdk>%s", s + strlen(sdk));
        else if (!strncmp(s, stage, strlen(stage))) piece = format("<stage>%s", s + strlen(stage));
        else piece = copy(s);
        next = format("%s%s%s", argtext, i ? " " : "", piece);
        free(argtext); free(piece); argtext = next;
    }

    index = clang_createIndex(0, 0);
    if (!index) cannot("cannot create a libclang index");
    for (i = 0; i < nunits; i++) {
        CXTranslationUnit tu = NULL;
        char *path = format("%s/%s", stage, units[i]);
        Allowed al = { sdk, resource_dir, NULL };
        Walk w;
        unsigned d;
        int failed = 0;
        enum CXErrorCode e = clang_parseTranslationUnit2(index, path, args, (int)nargs, NULL, 0, CXTranslationUnit_None, &tu);
        if (e != CXError_Success || !tu) cannot("libclang could not parse %s (%d)", units[i], e);
        for (d = 0; d < clang_getNumDiagnostics(tu); d++) {
            CXDiagnostic g = clang_getDiagnostic(tu, d);
            if (clang_getDiagnosticSeverity(g) >= CXDiagnostic_Error) {
                CXString t = clang_formatDiagnostic(g, clang_defaultDiagnosticDisplayOptions());
                fprintf(stderr, "%s\n", clang_getCString(t));
                clang_disposeString(t);
                failed = 1;
            }
            clang_disposeDiagnostic(g);
        }
        if (failed) cannot("%s: error-level diagnostics; no receipt written", units[i]);
        clang_getInclusions(tu, included, &al);
        if (al.bad) cannot("%s includes %s, which is outside the staged inputs, the SDK and the compiler's resource headers", units[i], al.bad);
        memset(&w, 0, sizeof w);
        w.tu = tu; w.parent = clang_getTranslationUnitCursor(tu);
        clang_visitChildren(clang_getTranslationUnitCursor(tu), walk, &w);
        clang_disposeTranslationUnit(tu);
        free(path);
    }
    clang_disposeIndex(index);

    /* The receipt. */
    for (i = 0; i < ninputs; i++) add_row(format("input\t%s\t%s", inputs[i].label, inputs[i].sha));
    for (i = 0; i < nunits; i++) add_row(format("unit\t%s", units[i]));
    if (nrows > 1) qsort(rows, nrows, sizeof *rows, compare);
    temporary = format("%s.XXXXXX", output);
    if ((fd = mkstemp(temporary)) < 0 || !(out = fdopen(fd, "w"))) cannot("cannot create a temporary beside %s", output);
    {
        CXString v = clang_getClangVersion();
        fprintf(out, "# objc-source-receipt 1\nprofile\trecaulk-objc-x86_64-10.9\nargs\t%s\nlibclang\t%s\nsdk\t%s\ntool\t%s\n",
                argtext, clang_getCString(v), sdk_sha, tool);
        clang_disposeString(v);
    }
    {   /* input, unit, send: in that order, each sorted and unique */
        static const char *ORDER[] = { "input\t", "unit\t", "send\t" };
        size_t o;
        for (o = 0; o < 3; o++)
            for (i = 0; i < nrows; i++)
                if (!strncmp(rows[i], ORDER[o], strlen(ORDER[o])) && (!i || strcmp(rows[i], rows[i - 1]))) fprintf(out, "%s\n", rows[i]);
    }
    if (fflush(out) || ferror(out) || fsync(fileno(out)) || fclose(out)) { unlink(temporary); cannot("cannot write the receipt"); }
    /* link(2) refuses an existing destination, so a racing writer is never overwritten. */
    if (link(temporary, output)) { int e = errno; unlink(temporary); cannot("cannot place the receipt at %s: %s", output, strerror(e)); }
    unlink(temporary);
    fprintf(stderr, "objc-source-inventory: %zu inputs, %zu units, receipt %s\n", ninputs, nunits, output);
    return 0;
}
