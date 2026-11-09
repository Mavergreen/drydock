/* objc-sdk-inventory.c -- semantic Objective-C declaration facts from SDK headers, via libclang.
 *
 * Standard output: the eleven TAB-separated fact columns (record, framework, owner, kind, name,
 * ABI encoding, introduced, deprecated, unavailable, source, container), sorted and unique.
 *
 * --signature-output FILE: a companion, schema 2, for the declared result and parameters of every
 * method and property getter. First line "# objc-signatures 2", then sorted unique rows:
 *   1 record (method, property-get, protocol-method, protocol-property-get) 2 owner 3 kind
 *   4 selector 5 result kind 6 result class or "-" 7 source 8 container 9 gprs 10 variadic.
 * The result kind comes from the declared libclang type, never from the ABI encoding (which
 * spells every object "@"): "class" for a pointer to a named interface (protocol qualifiers and
 * typedef aliases looked through, a forward @class included), "instancetype", "id" for id and
 * id<Protocol>, "other" for anything that is not an object pointer, and "unknown" for what this
 * producer does not resolve (an Objective-C type parameter, an unexposed type). The companion
 * never changes the eleven columns. It is exclusive and atomic: an existing destination,
 * symlink or not, is refused before parsing; signatures are written to a temporary beside it
 * and linked into place only after the facts succeeded, so a failure leaves nothing behind.
 *
 * gprs is the number of general-purpose argument registers the declared parameters take under the
 * SysV x86_64 calling convention, not counting self and _cmd (a getter takes 0). Each parameter's
 * canonical type: a pointer, integer, enum, BOOL, block or Objective-C object takes 1 (an __int128
 * takes 2); float and double take 0; a struct of at most 16 bytes takes one per eightbyte holding
 * an integer or pointer (an NSRange takes 2, a struct of two doubles 0); a larger aggregate is
 * passed in memory and takes 0. Whatever this producer cannot classify with certainty (a union, a
 * bitfield, a misaligned field, long double, a vector, a complex, an unprototyped function) makes
 * the whole count "-", which consumers read as unbounded. variadic is 1 for a "..." declaration.
 *
 * --function-output FILE: a catalog, schema 1, of the C function prototypes the parsed headers
 * declare (the SDK's and the explicit headers'; the compiler resource directory's are left out).
 * First line "# objc-functions 1", then one row per name, sorted:
 *   1 function (the C name as the source spells it, no Mach-O underscore) 2 gprs 3 variadic
 *   4 noreturn 5 source (of the first declaration in sorted order).
 * Redeclarations are merged: gprs is "-" unless every declaration agrees, and variadic or noreturn is
 * 1 if any declaration says so. It is exclusive and atomic, as the signature companion is.
 *
 * After a successful parse, stderr carries one "objc-sdk-inventory: resource-header PATH" line per
 * file included from below the compiler resource directory, PATH relative to it, sorted. */
#define _DARWIN_C_SOURCE
#include <clang-c/Index.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>

struct inventory {
    char *sdk;
    char **headers;
    size_t nheaders;
    char **rows;
    size_t nrows, capacity;
    const char *signatures;   /* --signature-output destination, or NULL */
    char **sigs;
    size_t nsigs, sigcapacity;
    const char *functions;    /* --function-output destination, or NULL */
    char **fns;
    size_t nfns, fncapacity;
};
struct context {
    struct inventory *inventory;
    const char *owner, *container;
    int protocol;
};
struct availability { char introduced[48], deprecated[48]; int unavailable; };

static void cannot(const char *format, ...) {
    va_list ap;
    fprintf(stderr, "objc-sdk-inventory: ");
    va_start(ap, format);
    vfprintf(stderr, format, ap);
    va_end(ap);
    fputc('\n', stderr);
    exit(4);
}
static void *allocate(size_t size) {
    void *p = malloc(size);
    if (!p) cannot("out of memory");
    return p;
}
static char *copy(const char *s) {
    char *p = allocate(strlen(s) + 1);
    strcpy(p, s);
    return p;
}
static char *join(const char *a, const char *b) {
    char *p = allocate(strlen(a) + strlen(b) + 1);
    strcpy(p, a); strcat(p, b);
    return p;
}
static char *cursor_name(CXCursor c) {
    CXString s = clang_getCursorSpelling(c);
    char *p = copy(clang_getCString(s) ? clang_getCString(s) : "");
    clang_disposeString(s);
    return p;
}
static char *directory(const char *path) {
    struct stat st;
    char *p = realpath(path, NULL);
    if (!p || stat(p, &st) || !S_ISDIR(st.st_mode) || access(p, R_OK | X_OK))
        cannot("unreadable directory: %s", path);
    return p;
}
static void version(char *out, size_t size, CXVersion v) {
    if (v.Major < 0) snprintf(out, size, "-");
    else if (v.Subminor >= 0) snprintf(out, size, "%d.%d.%d", v.Major, v.Minor, v.Subminor);
    else if (v.Minor >= 0) snprintf(out, size, "%d.%d", v.Major, v.Minor);
    else snprintf(out, size, "%d", v.Major);
}
static struct availability availability(CXCursor c) {
    struct availability result = {"-", "-", 0};
    int deprecated = 0, unavailable = 0;
    int count = clang_getCursorPlatformAvailability(c, &deprecated, NULL, &unavailable, NULL, NULL, 0);
    if (count < 0 || count > 65536) cannot("invalid availability count");
    CXPlatformAvailability *platforms = allocate((size_t)(count + 1) * sizeof(*platforms));
    int measured = clang_getCursorPlatformAvailability(c, &deprecated, NULL, &unavailable, NULL, platforms, count);
    if (measured < 0 || measured > count) cannot("truncated availability data");
    result.unavailable = unavailable;
    for (int i = 0; i < measured; ++i) {
        const char *platform = clang_getCString(platforms[i].Platform);
        if (platform && !strcmp(platform, "macos")) {
            version(result.introduced, sizeof(result.introduced), platforms[i].Introduced);
            version(result.deprecated, sizeof(result.deprecated), platforms[i].Deprecated);
            result.unavailable |= platforms[i].Unavailable;
        }
        clang_disposeCXPlatformAvailability(&platforms[i]);
    }
    free(platforms);
    return result;
}
static void field(const char *s) {
    if (strpbrk(s, "\t\r\n")) cannot("control character in a fact field");
}
static char *type_name(CXType t) {
    CXString s = clang_getTypeSpelling(t);
    char *p = copy(clang_getCString(s) ? clang_getCString(s) : "");
    clang_disposeString(s);
    return p;
}
/* Looks through sugar that does not change which object a pointer names. */
static CXType desugar(CXType t) {
    for (int depth = 0; depth < 32; ++depth) {
        if (t.kind == CXType_Elaborated) t = clang_Type_getNamedType(t);
        else if (t.kind == CXType_Attributed) t = clang_Type_getModifiedType(t);
        else return t;
    }
    cannot("type sugar nested too deeply");
    return t;
}
/* The declared result as the companion's (kind, class): see the header. */
static void result_of(CXType t, const char **kind, char **class_name) {
    *class_name = copy("-");
    for (int depth = 0; depth < 32; ++depth) {
        t = desugar(t);
        if (t.kind == CXType_Typedef) {
            char *name = type_name(t);
            int instancetype = !strcmp(name, "instancetype");
            free(name);
            if (instancetype) { *kind = "instancetype"; return; }
            t = clang_getTypedefDeclUnderlyingType(clang_getTypeDeclaration(t));
            continue;
        }
        if (t.kind == CXType_ObjCId) { *kind = "id"; return; }
        if (t.kind == CXType_ObjCObjectPointer) {
            CXType p = desugar(clang_getPointeeType(t));
            if (p.kind == CXType_ObjCObject) p = desugar(clang_Type_getObjCObjectBaseType(p));
            if (p.kind == CXType_ObjCId) { *kind = "id"; return; }
            if (p.kind == CXType_ObjCInterface) {
                CXCursor decl = clang_getTypeDeclaration(p);
                char *name = cursor_name(decl);
                if (!*name) { free(name); *kind = "unknown"; return; }
                free(*class_name); *class_name = name;
                *kind = "class";
                return;
            }
            *kind = "unknown";
            return;
        }
        if (t.kind == CXType_Invalid || t.kind == CXType_Unexposed || t.kind == CXType_ObjCTypeParam) {
            *kind = "unknown";
            return;
        }
        *kind = "other";
        return;
    }
    cannot("typedef chain nested too deeply");
}
static void push(char ***rows, size_t *n, size_t *capacity, char *row) {
    if (*n == *capacity) {
        size_t more = *capacity ? *capacity * 2 : 1024;
        char **grown = realloc(*rows, more * sizeof(*grown));
        if (!grown) cannot("out of memory");
        *rows = grown; *capacity = more;
    }
    (*rows)[(*n)++] = row;
}
/* SysV x86_64 eightbyte classes, as far as this producer classifies them. */
enum eightbyte { EB_NONE, EB_SSE, EB_INTEGER };
struct layout { enum eightbyte classes[2]; int failed; };
static void classify_at(CXType t, long long bits, struct layout *layout);
static enum CXVisitorResult classify_field(CXCursor c, CXClientData data) {
    struct layout *layout = ((void **)data)[0];
    long long base = *(long long *)((void **)data)[1];
    long long offset = clang_Cursor_getOffsetOfField(c);
    if (clang_Cursor_isBitField(c) || offset < 0) { layout->failed = 1; return CXVisit_Break; }
    classify_at(clang_getCanonicalType(clang_getCursorType(c)), base + offset, layout);
    return layout->failed ? CXVisit_Break : CXVisit_Continue;
}
/* Integer-class scalars (pointers, integers, enums, objects) are 1; float and double are 0; else -1. */
static int scalar_class(CXType t) {
    switch (t.kind) {
    case CXType_Pointer: case CXType_BlockPointer: case CXType_ObjCObjectPointer: case CXType_ObjCId:
    case CXType_ObjCClass: case CXType_ObjCSel: case CXType_NullPtr: case CXType_Enum:
    case CXType_Bool: case CXType_Char_U: case CXType_UChar: case CXType_Char16: case CXType_Char32:
    case CXType_UShort: case CXType_UInt: case CXType_ULong: case CXType_ULongLong: case CXType_Char_S:
    case CXType_SChar: case CXType_WChar: case CXType_Short: case CXType_Int: case CXType_Long:
    case CXType_LongLong:
        return 1;
    case CXType_Float: case CXType_Double:
        return 0;
    default:
        return -1;
    }
}
static void classify_at(CXType t, long long bits, struct layout *layout) {
    long long size = clang_Type_getSizeOf(t), align = clang_Type_getAlignOf(t), byte = bits / 8;
    if (bits % 8 || size < 0 || align <= 0 || byte % align || byte + size > 16) { layout->failed = 1; return; }
    if (t.kind == CXType_Record) {
        void *data[2] = {layout, &bits};
        if (clang_getCursorKind(clang_getTypeDeclaration(t)) != CXCursor_StructDecl) { layout->failed = 1; return; }
        clang_Type_visitFields(t, classify_field, data);
        return;
    }
    if (t.kind == CXType_ConstantArray) {
        CXType element = clang_getCanonicalType(clang_getArrayElementType(t));
        long long count = clang_getNumElements(t), step = clang_Type_getSizeOf(element);
        if (count < 0 || step <= 0) { layout->failed = 1; return; }
        for (long long i = 0; i < count && !layout->failed; ++i) classify_at(element, bits + i * step * 8, layout);
        return;
    }
    int integer = scalar_class(t);
    if (integer < 0 || byte / 8 != (byte + size - 1) / 8) { layout->failed = 1; return; }
    enum eightbyte *slot = &layout->classes[byte / 8];
    if (integer) *slot = EB_INTEGER;
    else if (*slot == EB_NONE) *slot = EB_SSE;
}
/* One parameter's GPRs (see the header), or -1 when it cannot be classified with certainty. */
static int parameter_gprs(CXType t) {
    t = clang_getCanonicalType(t);
    /* spec: C adjusts an array or function parameter to a pointer (C99 6.7.5.3); libclang reports
     * the declared type, as in "const id objects[]" or va_list (an array of __va_list_tag). */
    if (t.kind == CXType_ConstantArray || t.kind == CXType_IncompleteArray || t.kind == CXType_VariableArray ||
        t.kind == CXType_FunctionProto || t.kind == CXType_FunctionNoProto) return 1;
    if (t.kind == CXType_Int128 || t.kind == CXType_UInt128) return 2;
    if (t.kind == CXType_Record) {
        long long size = clang_Type_getSizeOf(t);
        struct layout layout = {{EB_NONE, EB_NONE}, 0};
        if (size < 0) return -1;
        if (clang_getCursorKind(clang_getTypeDeclaration(t)) != CXCursor_StructDecl) return -1;
        if (size > 16) return 0;
        classify_at(t, 0, &layout);
        if (layout.failed) return -1;
        return (layout.classes[0] == EB_INTEGER) + (layout.classes[1] == EB_INTEGER);
    }
    return scalar_class(t);
}
/* The declaration's parameter GPRs into out ("-" when unbounded) and whether it is variadic. */
static int parameters(CXCursor c, char *out, size_t size) {
    int n = clang_Cursor_getNumArguments(c), total = 0;
    if (n < 0 || clang_getCanonicalType(clang_getCursorType(c)).kind == CXType_FunctionNoProto) total = -1;
    for (int i = 0; i < n && total >= 0; ++i) {
        int g = parameter_gprs(clang_getCursorType(clang_Cursor_getArgument(c, (unsigned)i)));
        total = g < 0 ? -1 : total + g;
    }
    if (total < 0) snprintf(out, size, "-");
    else snprintf(out, size, "%d", total);
    return !!clang_Cursor_isVariadic(c);
}
static enum CXChildVisitResult noreturn_attribute(CXCursor c, CXCursor parent, CXClientData data) {
    (void)parent;
    if (clang_isAttribute(clang_getCursorKind(c))) {
        CXTranslationUnit tu = clang_Cursor_getTranslationUnit(c);
        CXToken *tokens = NULL;
        unsigned count = 0;
        clang_tokenize(tu, clang_getCursorExtent(c), &tokens, &count);
        for (unsigned i = 0; i < count; ++i) {
            CXString spelling = clang_getTokenSpelling(tu, tokens[i]);
            const char *t = clang_getCString(spelling);
            if (t && (!strcmp(t, "_Noreturn") || !strcmp(t, "noreturn") || !strcmp(t, "__noreturn__")))
                *(int *)data = 1;
            clang_disposeString(spelling);
        }
        if (tokens) clang_disposeTokens(tu, tokens, count);
    }
    return CXChildVisit_Continue;
}
/* spec: libclang 22 has no noreturn query and no noreturn attribute cursor kind. GNU
 * __attribute__((noreturn)) (the SDK's __dead2) is part of the function type, so it shows only as
 * the canonical type spelling's " __attribute__((noreturn))" suffix -- unless the result type, a
 * pointer to a noreturn function, is what spells it. C11 _Noreturn is a declaration attribute that
 * libclang exposes only as an UnexposedAttr child, recognized by its token. */
static int noreturn_function(CXCursor c) {
    static const char suffix[] = " __attribute__((noreturn))";
    char *type = type_name(clang_getCanonicalType(clang_getCursorType(c)));
    char *result = type_name(clang_getCanonicalType(clang_getCursorResultType(c)));
    size_t length = strlen(type);
    int noreturn = length >= sizeof(suffix) - 1 && !strcmp(type + length - (sizeof(suffix) - 1), suffix) &&
                   !strstr(result, "noreturn");
    free(type); free(result);
    if (!noreturn) clang_visitChildren(c, noreturn_attribute, &noreturn);
    return noreturn;
}
static void signature(struct inventory *inventory, CXCursor c, const char *record, const char *owner,
                      const char *method_kind, const char *name, const char *source, const char *container) {
    const char *kind;
    char *class_name, *row, gprs[16] = "0";
    size_t size;
    int property = strstr(record, "property") != NULL, variadic = 0;
    CXType t = property ? clang_getCursorType(c) : clang_getCursorResultType(c);
    result_of(t, &kind, &class_name);
    field(class_name);
    if (!property) variadic = parameters(c, gprs, sizeof(gprs));
    size = strlen(record) + strlen(owner) + strlen(method_kind) + strlen(name) + strlen(kind) +
           strlen(class_name) + strlen(source) + strlen(container) + strlen(gprs) + 32;
    row = allocate(size);
    snprintf(row, size, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d", record, owner, method_kind, name, kind,
             class_name, source, container, gprs, variadic);
    free(class_name);
    push(&inventory->sigs, &inventory->nsigs, &inventory->sigcapacity, row);
}
/* The declaration's file relative to the SDK, or "input/N" for the Nth explicit header, and its
 * line. NULL when it has no location, or (unless required) when it lies elsewhere. */
static char *located(struct inventory *inventory, CXCursor c, unsigned *line, int required) {
    CXFile file;
    clang_getSpellingLocation(clang_getCursorLocation(c), &file, line, NULL, NULL);
    if (!file || !*line) return NULL;
    CXString filename = clang_getFileName(file);
    const char *raw = clang_getCString(filename);
    char *path = raw ? realpath(raw, NULL) : NULL;
    if (!path) cannot("unreadable declaration location");
    clang_disposeString(filename);
    char *relative = NULL;
    size_t sdklen = strlen(inventory->sdk);
    if (!strncmp(path, inventory->sdk, sdklen) && path[sdklen] == '/')
        relative = copy(path + sdklen + 1);
    else {
        for (size_t i = 0; i < inventory->nheaders; ++i) {
            if (!strcmp(path, inventory->headers[i])) {
                char input[64];
                snprintf(input, sizeof(input), "input/%zu", i + 1);
                relative = copy(input);
                break;
            }
        }
    }
    if (!relative && required) cannot("declaration outside the SDK and explicit headers: %s", path);
    free(path);
    return relative;
}
static void function(struct inventory *inventory, CXCursor c) {
    unsigned line;
    char *relative = located(inventory, c, &line, 0), *name, *row, gprs[16];
    if (!relative) return;
    name = cursor_name(c);
    field(name); field(relative);
    int variadic = parameters(c, gprs, sizeof(gprs)), noreturn = noreturn_function(c);
    size_t size = strlen(name) + strlen(gprs) + strlen(relative) + 64;
    row = allocate(size);
    snprintf(row, size, "%s\t%s\t%d\t%d\t%s:%u", name, gprs, variadic, noreturn, relative, line);
    free(name); free(relative);
    push(&inventory->fns, &inventory->nfns, &inventory->fncapacity, row);
}
static void record(struct context *ctx, CXCursor c, const char *kind, const char *method_kind,
                   const char *name, const char *encoding) {
    unsigned line;
    struct inventory *inventory = ctx->inventory;
    char *relative = located(inventory, c, &line, 1);
    if (!relative) return;
    char *framework = copy("-");
    const char *start = relative, *match;
    while ((match = strstr(start, ".framework/")) != NULL) {
        const char *begin = match;
        while (begin > relative && begin[-1] != '/') --begin;
        free(framework);
        framework = allocate((size_t)(match - begin) + 1);
        memcpy(framework, begin, (size_t)(match - begin));
        framework[match - begin] = '\0';
        start = match + strlen(".framework/");
    }
    struct availability a = availability(c);
    const char *owner = ctx->owner ? ctx->owner : "-";
    const char *container = ctx->container ? ctx->container : "-";
    if (ctx->protocol && (!strcmp(kind, "protocol-method") || !strncmp(kind, "protocol-property-", 18)))
        container = clang_Cursor_isObjCOptional(c) ? "protocol:optional" : "protocol:required";
    field(kind); field(framework); field(owner); field(method_kind); field(name);
    field(encoding); field(relative); field(container);
    size_t size = strlen(kind) + strlen(framework) + strlen(owner) + strlen(method_kind) +
                  strlen(name) + strlen(encoding) + strlen(relative) + strlen(container) + 192;
    char *row = allocate(size);
    snprintf(row, size, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s:%u\t%s",
             kind, framework, owner, method_kind, name, encoding, a.introduced, a.deprecated,
             !!a.unavailable, relative, line, container);
    if (inventory->signatures && (!strcmp(kind, "method") || !strcmp(kind, "property-get") ||
                                  !strcmp(kind, "protocol-method") || !strcmp(kind, "protocol-property-get"))) {
        char source[4096];
        snprintf(source, sizeof(source), "%s:%u", relative, line);
        signature(inventory, c, kind, owner, method_kind, name, source, container);
    }
    free(relative); free(framework);
    push(&inventory->rows, &inventory->nrows, &inventory->capacity, row);
}
static enum CXChildVisitResult superclass(CXCursor c, CXCursor parent, CXClientData data) {
    (void)parent;
    if (clang_getCursorKind(c) == CXCursor_ObjCSuperClassRef) {
        char **name = data;
        free(*name); *name = cursor_name(c);
    }
    return CXChildVisit_Continue;
}
static enum CXChildVisitResult category_owner(CXCursor c, CXCursor parent, CXClientData data) {
    (void)parent;
    if (clang_getCursorKind(c) == CXCursor_ObjCClassRef) {
        char **name = data;
        free(*name); *name = cursor_name(clang_getCursorReferenced(c));
    }
    return CXChildVisit_Continue;
}
static enum CXChildVisitResult visit(CXCursor c, CXCursor parent, CXClientData data) {
    (void)parent;
    struct context *ctx = data;
    enum CXCursorKind kind = clang_getCursorKind(c);
    if (kind == CXCursor_ObjCInterfaceDecl || kind == CXCursor_ObjCProtocolDecl ||
        kind == CXCursor_ObjCCategoryDecl) {
        if (kind == CXCursor_ObjCProtocolDecl && !clang_isCursorDefinition(c))
            return CXChildVisit_Continue;
        char *name = cursor_name(c), *owner = copy(name), *container = NULL;
        struct context child = {ctx->inventory, owner, NULL, kind == CXCursor_ObjCProtocolDecl};
        if (kind == CXCursor_ObjCCategoryDecl) {
            free(owner); owner = NULL;
            clang_visitChildren(c, category_owner, &owner);
            if (!owner || !*owner) cannot("unresolved category owner: %s", name);
            child.owner = owner;
            record(&child, c, "category", "-", *name ? name : "(extension)", "-");
            container = join("category:", *name ? name : "(extension)");
        } else if (kind == CXCursor_ObjCInterfaceDecl) {
            char *base = copy("-");
            clang_visitChildren(c, superclass, &base);
            record(&child, c, "class", "-", base, "-");
            free(base);
            container = copy("interface");
        } else {
            record(&child, c, "protocol", "-", "-", "-");
            container = copy("protocol");
        }
        child.container = container;
        clang_visitChildren(c, visit, &child);
        free(container); free(owner); free(name);
        return CXChildVisit_Continue;
    }
    if (!ctx->owner) {
        if (kind == CXCursor_FunctionDecl && ctx->inventory->functions) function(ctx->inventory, c);
        return CXChildVisit_Recurse;
    }
    if (kind == CXCursor_ObjCClassMethodDecl || kind == CXCursor_ObjCInstanceMethodDecl) {
        char *name = cursor_name(c);
        CXString encoding = clang_getDeclObjCTypeEncoding(c);
        const char *e = clang_getCString(encoding);
        if (!e || !*e) cannot("unmeasured method encoding: %s %s", ctx->owner, name);
        record(ctx, c, ctx->protocol ? "protocol-method" : "method",
               kind == CXCursor_ObjCClassMethodDecl ? "+" : "-", name, e);
        clang_disposeString(encoding); free(name);
    } else if (kind == CXCursor_ObjCPropertyDecl) {
        unsigned attributes = clang_Cursor_getObjCPropertyAttributes(c, 0);
        const char *method_kind = attributes & CXObjCPropertyAttr_class ? "+" : "-";
        CXString getter = clang_Cursor_getObjCPropertyGetterName(c);
        const char *name = clang_getCString(getter);
        if (!name || !*name) cannot("unresolved property getter");
        record(ctx, c, ctx->protocol ? "protocol-property-get" : "property-get", method_kind, name, "-");
        clang_disposeString(getter);
        if (!(attributes & CXObjCPropertyAttr_readonly)) {
            CXString setter = clang_Cursor_getObjCPropertySetterName(c);
            name = clang_getCString(setter);
            if (!name || !*name) cannot("unresolved property setter");
            record(ctx, c, ctx->protocol ? "protocol-property-set" : "property-set", method_kind, name, "-");
            clang_disposeString(setter);
        }
    } else if (kind == CXCursor_ObjCProtocolRef) {
        char *name = cursor_name(c);
        record(ctx, c, ctx->protocol ? "protocol-inherits" : "conformance", "-", name, "-");
        free(name);
    }
    return CXChildVisit_Continue;
}
static int compare(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
/* Each file the parse included from below the compiler resource directory, relative to it. */
struct inclusions { const char *root; size_t length; char **paths; size_t n, capacity; };
static void included(CXFile file, CXSourceLocation *stack, unsigned depth, CXClientData data) {
    struct inclusions *in = data;
    CXString name = clang_getFileName(file);
    const char *s = clang_getCString(name);
    char *resolved = s ? realpath(s, NULL) : NULL;
    (void)stack; (void)depth;
    if (resolved && !strncmp(resolved, in->root, in->length) && resolved[in->length] == '/') {
        if (strpbrk(resolved, "\r\n")) cannot("newline in a resource header path");
        if (in->n == in->capacity) {
            in->capacity = in->capacity ? 2 * in->capacity : 64;
            if (!(in->paths = realloc(in->paths, in->capacity * sizeof *in->paths))) cannot("out of memory");
        }
        in->paths[in->n++] = copy(resolved + in->length + 1);
    }
    free(resolved);
    clang_disposeString(name);
}
/* Temporaries not yet linked into place; a failure exit removes them. */
static char *pending[2];
static void remove_pending(void) {
    for (size_t i = 0; i < 2; ++i) if (pending[i]) unlink(pending[i]);
}
/* Sorted rows written, deduplicated, to a temporary beside dest; NULL when dest is NULL. */
static char *companion(const char *dest, const char *header, char **rows, size_t n) {
    FILE *out = NULL;
    int fd;
    if (!dest) return NULL;
    char *temporary = join(dest, ".XXXXXX");
    if ((fd = mkstemp(temporary)) < 0 || !(out = fdopen(fd, "w")))
        cannot("cannot create a temporary beside %s", dest);
    if (n > 1) qsort(rows, n, sizeof(*rows), compare);
    fputs(header, out);
    for (size_t i = 0; i < n; ++i)
        if (!i || strcmp(rows[i], rows[i - 1])) fprintf(out, "%s\n", rows[i]);
    if (fflush(out) || ferror(out) || fsync(fileno(out)) || fclose(out)) {
        unlink(temporary);
        free(temporary);
        cannot("cannot write %s", dest);
    }
    pending[pending[0] ? 1 : 0] = temporary;
    return temporary;
}
/* Sorted function rows merged to one per name, as the header describes. */
static void merge_functions(struct inventory *inventory) {
    size_t kept = 0;
    for (size_t i = 0; i < inventory->nfns;) {
        char *first = inventory->fns[i], *columns[5], *mine = copy(first), *cursor = mine;
        for (int k = 0; k < 5; ++k) columns[k] = strsep(&cursor, "\t");
        if (!columns[4]) cannot("malformed function row");
        int same = 1, variadic = !strcmp(columns[2], "1"), noreturn = !strcmp(columns[3], "1");
        size_t j = i + 1, name = strlen(columns[0]);
        for (; j < inventory->nfns && !strncmp(inventory->fns[j], first, name) && inventory->fns[j][name] == '\t'; ++j) {
            char *other = copy(inventory->fns[j]), *at = other, *theirs[5];
            for (int k = 0; k < 5; ++k) theirs[k] = strsep(&at, "\t");
            if (!theirs[4]) cannot("malformed function row");
            same &= !strcmp(theirs[1], columns[1]);
            variadic |= !strcmp(theirs[2], "1");
            noreturn |= !strcmp(theirs[3], "1");
            free(other); free(inventory->fns[j]);
        }
        size_t size = strlen(first) + 8;
        char *row = allocate(size);
        snprintf(row, size, "%s\t%s\t%d\t%d\t%s", columns[0], same ? columns[1] : "-", variadic, noreturn, columns[4]);
        free(mine); free(first);
        inventory->fns[kept++] = row;
        i = j;
    }
    inventory->nfns = kept;
}
static int usage(void) {
    fprintf(stderr, "usage: objc-sdk-inventory --sdk SDKROOT --resource-dir DIR --header HEADER [--header HEADER ...] [--signature-output FILE] [--function-output FILE]\n");
    return 2;
}
int main(int argc, char **argv) {
    const char *sdk = NULL, *resource = NULL;
    struct inventory inventory;
    memset(&inventory, 0, sizeof(inventory));
    inventory.headers = allocate((size_t)argc * sizeof(*inventory.headers));
    for (int i = 1; i < argc; ++i) {
        if (i + 1 >= argc || argv[i + 1][0] == '-') return usage();
        if (!strcmp(argv[i], "--sdk") && !sdk) sdk = argv[++i];
        else if (!strcmp(argv[i], "--resource-dir") && !resource) resource = argv[++i];
        else if (!strcmp(argv[i], "--header")) inventory.headers[inventory.nheaders++] = argv[++i];
        else if (!strcmp(argv[i], "--signature-output") && !inventory.signatures) inventory.signatures = argv[++i];
        else if (!strcmp(argv[i], "--function-output") && !inventory.functions) inventory.functions = argv[++i];
        else return usage();
    }
    if (!sdk || !resource || !inventory.nheaders) return usage();
    if (inventory.signatures && inventory.functions && !strcmp(inventory.signatures, inventory.functions)) return usage();
    const char *destinations[] = {inventory.signatures, inventory.functions};
    for (size_t i = 0; i < 2; ++i) {
        struct stat st;
        if (destinations[i] && (!lstat(destinations[i], &st) || errno != ENOENT))
            cannot("%s destination exists or is unusable: %s", i ? "function" : "signature", destinations[i]);
    }
    inventory.sdk = directory(sdk);
    char *resource_dir = directory(resource);
    char *resource_include = join(resource_dir, "/include");
    char *checked = directory(resource_include); free(checked);
    char *sdk_include = join(inventory.sdk, "/usr/include");
    checked = directory(sdk_include); free(checked);
    char *frameworks = join(inventory.sdk, "/System/Library/Frameworks");
    checked = directory(frameworks); free(checked);
    size_t input_size = 1;
    for (size_t i = 0; i < inventory.nheaders; ++i) {
        const char *path = inventory.headers[i];
        char *resolved = realpath(path, NULL);
        struct stat st;
        if (!resolved || stat(resolved, &st) || !S_ISREG(st.st_mode) || access(resolved, R_OK))
            cannot("unreadable header: %s", path);
        if (strpbrk(resolved, "\r\n")) cannot("newline in header path");
        inventory.headers[i] = resolved;
        input_size += strlen(resolved) * 2 + 16;
    }
    char *input = allocate(input_size), *p = input;
    for (size_t i = 0; i < inventory.nheaders; ++i) {
        memcpy(p, "#import \"", 9); p += 9;
        for (const char *h = inventory.headers[i]; *h; ++h) {
            if (*h == '\\' || *h == '"') *p++ = '\\';
            *p++ = *h;
        }
        *p++ = '"'; *p++ = '\n';
    }
    *p = '\0';
    const char *args[] = {"-x", "objective-c", "-target", "x86_64-apple-macos10.9", "-isysroot", inventory.sdk,
        "-resource-dir", resource_dir, "-nostdinc", "-isystem", resource_include, "-isystem", sdk_include,
        "-iframework", frameworks, "-fblocks", "-Wno-deprecated-declarations", "-Wno-nullability-completeness"};
    const char *virtual_file = "/__shipyard_objc_inventory__.m";
    struct CXUnsavedFile unsaved = {virtual_file, input, (unsigned long)(p - input)};
    const char *ambient[] = {"CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "SDKROOT", "CCC_OVERRIDE_OPTIONS"};
    for (size_t i = 0; i < sizeof(ambient) / sizeof(*ambient); ++i)
        if (unsetenv(ambient[i])) cannot("cannot clear ambient compiler environment");
    CXIndex index = clang_createIndex(0, 0);
    if (!index) cannot("cannot create libclang index");
    CXTranslationUnit tu = NULL;
    enum CXErrorCode error = clang_parseTranslationUnit2(index, virtual_file, args,
        (int)(sizeof(args) / sizeof(*args)), &unsaved, 1,
        CXTranslationUnit_SkipFunctionBodies | CXTranslationUnit_KeepGoing, &tu);
    if (error != CXError_Success || !tu) cannot("libclang parse failure (%d)", error);
    int failed = 0;
    for (unsigned i = 0; i < clang_getNumDiagnostics(tu); ++i) {
        CXDiagnostic d = clang_getDiagnostic(tu, i);
        if (clang_getDiagnosticSeverity(d) >= CXDiagnostic_Error) failed = 1;
        CXString text = clang_formatDiagnostic(d, clang_defaultDiagnosticDisplayOptions());
        fprintf(stderr, "%s\n", clang_getCString(text));
        clang_disposeString(text); clang_disposeDiagnostic(d);
    }
    if (failed) cannot("error-level parser diagnostic; no facts emitted");
    struct context root = {&inventory, NULL, NULL, 0};
    clang_visitChildren(clang_getTranslationUnitCursor(tu), visit, &root);
    if (inventory.nrows > 1) qsort(inventory.rows, inventory.nrows, sizeof(*inventory.rows), compare);
    CXString clang_version = clang_getClangVersion();
    fprintf(stderr, "objc-sdk-inventory: schema=1; libclang=%s; sdk=%s; target=x86_64-apple-macos10.9\n",
            clang_getCString(clang_version), inventory.sdk);
    clang_disposeString(clang_version);
    {
        struct inclusions in = {resource_dir, strlen(resource_dir), NULL, 0, 0};
        clang_getInclusions(tu, included, &in);
        if (in.n > 1) qsort(in.paths, in.n, sizeof *in.paths, compare);
        for (size_t i = 0; i < in.n; ++i) {
            if (!i || strcmp(in.paths[i], in.paths[i - 1])) fprintf(stderr, "objc-sdk-inventory: resource-header %s\n", in.paths[i]);
            free(in.paths[i]);
        }
        free(in.paths);
    }
    if (inventory.nfns > 1) qsort(inventory.fns, inventory.nfns, sizeof(*inventory.fns), compare);
    merge_functions(&inventory);
    if (atexit(remove_pending)) cannot("cannot register temporary cleanup");
    char *sig_temporary = companion(inventory.signatures, "# objc-signatures 2\n", inventory.sigs, inventory.nsigs);
    char *fn_temporary = companion(inventory.functions, "# objc-functions 1\n", inventory.fns, inventory.nfns);
    for (size_t i = 0; i < inventory.nrows; ++i)
        if (!i || strcmp(inventory.rows[i], inventory.rows[i - 1])) puts(inventory.rows[i]);
    if (fflush(stdout) || ferror(stdout)) cannot("cannot write facts");
    /* link(2) refuses an existing destination, so a racing writer is never overwritten. A function
     * catalog that cannot be placed takes back the signatures this run placed. */
    if (sig_temporary) {
        if (link(sig_temporary, inventory.signatures))
            cannot("cannot place signatures at %s: %s", inventory.signatures, strerror(errno));
        unlink(sig_temporary);
        pending[0] = NULL;
        free(sig_temporary);
    }
    if (fn_temporary) {
        int linked = link(fn_temporary, inventory.functions);
        if (linked) {
            int saved = errno;
            if (inventory.signatures) unlink(inventory.signatures);
            cannot("cannot place functions at %s: %s", inventory.functions, strerror(saved));
        }
        unlink(fn_temporary);
        pending[0] = pending[1] = NULL;
        free(fn_temporary);
    }
    for (size_t i = 0; i < inventory.nsigs; ++i) free(inventory.sigs[i]);
    for (size_t i = 0; i < inventory.nfns; ++i) free(inventory.fns[i]);
    free(inventory.sigs); free(inventory.fns);
    for (size_t i = 0; i < inventory.nrows; ++i) free(inventory.rows[i]);
    for (size_t i = 0; i < inventory.nheaders; ++i) free(inventory.headers[i]);
    free(inventory.rows); free(inventory.headers); free(inventory.sdk);
    free(resource_dir); free(resource_include); free(sdk_include); free(frameworks); free(input);
    clang_disposeTranslationUnit(tu); clang_disposeIndex(index);
    return 0;
}
