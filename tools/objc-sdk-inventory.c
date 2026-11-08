/* objc-sdk-inventory.c -- semantic Objective-C declaration facts from SDK headers, via libclang.
 *
 * Standard output: the eleven TAB-separated fact columns (record, framework, owner, kind, name,
 * ABI encoding, introduced, deprecated, unavailable, source, container), sorted and unique.
 *
 * --signature-output FILE: a companion, schema 1, for the declared result of every method and
 * property getter. First line "# objc-signatures 1", then sorted unique rows:
 *   1 record (method, property-get, protocol-method, protocol-property-get) 2 owner 3 kind
 *   4 selector 5 result kind 6 result class or "-" 7 source 8 container.
 * The result kind comes from the declared libclang type, never from the ABI encoding (which
 * spells every object "@"): "class" for a pointer to a named interface (protocol qualifiers and
 * typedef aliases looked through, a forward @class included), "instancetype", "id" for id and
 * id<Protocol>, "other" for anything that is not an object pointer, and "unknown" for what this
 * producer does not resolve (an Objective-C type parameter, an unexposed type). The companion
 * never changes the eleven columns. It is exclusive and atomic: an existing destination,
 * symlink or not, is refused before parsing; signatures are written to a temporary beside it
 * and linked into place only after the facts succeeded, so a failure leaves nothing behind.
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
static void signature(struct inventory *inventory, CXCursor c, const char *record, const char *owner,
                      const char *method_kind, const char *name, const char *source, const char *container) {
    const char *kind;
    char *class_name, *row;
    size_t size;
    CXType t = strstr(record, "property") ? clang_getCursorType(c) : clang_getCursorResultType(c);
    result_of(t, &kind, &class_name);
    field(class_name);
    size = strlen(record) + strlen(owner) + strlen(method_kind) + strlen(name) + strlen(kind) +
           strlen(class_name) + strlen(source) + strlen(container) + 16;
    row = allocate(size);
    snprintf(row, size, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", record, owner, method_kind, name, kind,
             class_name, source, container);
    free(class_name);
    if (inventory->nsigs == inventory->sigcapacity) {
        size_t capacity = inventory->sigcapacity ? inventory->sigcapacity * 2 : 1024;
        char **sigs = realloc(inventory->sigs, capacity * sizeof(*sigs));
        if (!sigs) cannot("out of memory");
        inventory->sigs = sigs; inventory->sigcapacity = capacity;
    }
    inventory->sigs[inventory->nsigs++] = row;
}
static void record(struct context *ctx, CXCursor c, const char *kind, const char *method_kind,
                   const char *name, const char *encoding) {
    CXFile file;
    unsigned line;
    clang_getSpellingLocation(clang_getCursorLocation(c), &file, &line, NULL, NULL);
    if (!file || !line) return;
    CXString filename = clang_getFileName(file);
    const char *raw = clang_getCString(filename);
    char *path = raw ? realpath(raw, NULL) : NULL;
    if (!path) cannot("unreadable declaration location");
    clang_disposeString(filename);
    struct inventory *inventory = ctx->inventory;
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
    if (!relative) cannot("declaration outside the SDK and explicit headers: %s", path);
    free(path);
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
    if (inventory->nrows == inventory->capacity) {
        size_t capacity = inventory->capacity ? inventory->capacity * 2 : 1024;
        char **rows = realloc(inventory->rows, capacity * sizeof(*rows));
        if (!rows) cannot("out of memory");
        inventory->rows = rows; inventory->capacity = capacity;
    }
    inventory->rows[inventory->nrows++] = row;
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
    if (!ctx->owner) return CXChildVisit_Recurse;
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
static int usage(void) {
    fprintf(stderr, "usage: objc-sdk-inventory --sdk SDKROOT --resource-dir DIR --header HEADER [--header HEADER ...] [--signature-output FILE]\n");
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
        else return usage();
    }
    if (!sdk || !resource || !inventory.nheaders) return usage();
    if (inventory.signatures) {
        struct stat st;
        if (!lstat(inventory.signatures, &st) || errno != ENOENT)
            cannot("signature destination exists or is unusable: %s", inventory.signatures);
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
    char *temporary = NULL;
    if (inventory.signatures) {
        FILE *out = NULL;
        int fd;
        temporary = join(inventory.signatures, ".XXXXXX");
        if ((fd = mkstemp(temporary)) < 0 || !(out = fdopen(fd, "w")))
            cannot("cannot create signature temporary beside %s", inventory.signatures);
        if (inventory.nsigs > 1) qsort(inventory.sigs, inventory.nsigs, sizeof(*inventory.sigs), compare);
        fputs("# objc-signatures 1\n", out);
        for (size_t i = 0; i < inventory.nsigs; ++i)
            if (!i || strcmp(inventory.sigs[i], inventory.sigs[i - 1])) fprintf(out, "%s\n", inventory.sigs[i]);
        if (fflush(out) || ferror(out) || fsync(fileno(out)) || fclose(out)) {
            unlink(temporary);
            cannot("cannot write signatures");
        }
    }
    for (size_t i = 0; i < inventory.nrows; ++i)
        if (!i || strcmp(inventory.rows[i], inventory.rows[i - 1])) puts(inventory.rows[i]);
    if (fflush(stdout) || ferror(stdout)) {
        if (temporary) unlink(temporary);
        cannot("cannot write facts");
    }
    if (temporary) {
        /* link(2) refuses an existing destination, so a racing writer is never overwritten. */
        int linked = link(temporary, inventory.signatures);
        unlink(temporary);
        if (linked) cannot("cannot place signatures at %s: %s", inventory.signatures, strerror(errno));
        free(temporary);
        for (size_t i = 0; i < inventory.nsigs; ++i) free(inventory.sigs[i]);
        free(inventory.sigs);
    }
    for (size_t i = 0; i < inventory.nrows; ++i) free(inventory.rows[i]);
    for (size_t i = 0; i < inventory.nheaders; ++i) free(inventory.headers[i]);
    free(inventory.rows); free(inventory.headers); free(inventory.sdk);
    free(resource_dir); free(resource_include); free(sdk_include); free(frameworks); free(input);
    clang_disposeTranslationUnit(tu); clang_disposeIndex(index);
    return 0;
}
