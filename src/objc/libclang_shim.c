/* libclang_shim.c -- see libclang_shim.h. The list below is every clang_* function
 * tools/objc-source-inventory.c calls (grep -o 'clang_[A-Za-z0-9_]*' | sort -u), each with its
 * clang-c header prototype; including <clang-c/Index.h> here makes the compiler hold every
 * definition to that prototype. */
/* platform: dlopen and RTLD_LOCAL under -std=c99: _XOPEN_SOURCE on glibc, _DARWIN_C_SOURCE keeps the rest visible on a Mac */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "libclang_shim.h"

#include <clang-c/Index.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* X(RETURN, NAME, PARAMETERS, ARGUMENTS) for a function with a result, V(...) for a void one. */
#define DRYDOCK_LIBCLANG_FUNCTIONS(X, V) \
    X(CXString, clang_Cursor_getObjCPropertyGetterName, (CXCursor c), (c)) \
    X(CXString, clang_Cursor_getObjCPropertySetterName, (CXCursor c), (c)) \
    X(CXType, clang_Cursor_getReceiverType, (CXCursor c), (c)) \
    X(int, clang_Cursor_isNull, (CXCursor c), (c)) \
    X(CXType, clang_Type_getObjCObjectBaseType, (CXType t), (t)) \
    X(CXIndex, clang_createIndex, (int exclude, int display), (exclude, display)) \
    X(unsigned, clang_defaultDiagnosticDisplayOptions, (void), ()) \
    V(clang_disposeDiagnostic, (CXDiagnostic d), (d)) \
    V(clang_disposeIndex, (CXIndex index), (index)) \
    V(clang_disposeString, (CXString s), (s)) \
    V(clang_disposeTokens, (CXTranslationUnit tu, CXToken *tokens, unsigned n), (tu, tokens, n)) \
    V(clang_disposeTranslationUnit, (CXTranslationUnit tu), (tu)) \
    X(unsigned, clang_equalCursors, (CXCursor a, CXCursor b), (a, b)) \
    X(CXString, clang_formatDiagnostic, (CXDiagnostic d, unsigned options), (d, options)) \
    X(const char *, clang_getCString, (CXString s), (s)) \
    X(CXType, clang_getCanonicalType, (CXType t), (t)) \
    X(CXString, clang_getClangVersion, (void), ()) \
    X(enum CXBinaryOperatorKind, clang_getCursorBinaryOperatorKind, (CXCursor c), (c)) \
    X(CXSourceRange, clang_getCursorExtent, (CXCursor c), (c)) \
    X(enum CXCursorKind, clang_getCursorKind, (CXCursor c), (c)) \
    X(CXSourceLocation, clang_getCursorLocation, (CXCursor c), (c)) \
    X(CXCursor, clang_getCursorReferenced, (CXCursor c), (c)) \
    X(CXCursor, clang_getCursorSemanticParent, (CXCursor c), (c)) \
    X(CXString, clang_getCursorSpelling, (CXCursor c), (c)) \
    X(CXType, clang_getCursorType, (CXCursor c), (c)) \
    X(enum CXUnaryOperatorKind, clang_getCursorUnaryOperatorKind, (CXCursor c), (c)) \
    X(CXDiagnostic, clang_getDiagnostic, (CXTranslationUnit tu, unsigned i), (tu, i)) \
    X(enum CXDiagnosticSeverity, clang_getDiagnosticSeverity, (CXDiagnostic d), (d)) \
    V(clang_getExpansionLocation, (CXSourceLocation l, CXFile *file, unsigned *line, unsigned *column, unsigned *offset), \
      (l, file, line, column, offset)) \
    X(CXString, clang_getFileName, (CXFile f), (f)) \
    V(clang_getInclusions, (CXTranslationUnit tu, CXInclusionVisitor visitor, CXClientData data), (tu, visitor, data)) \
    X(CXCursor, clang_getNullCursor, (void), ()) \
    X(unsigned, clang_getNumDiagnostics, (CXTranslationUnit tu), (tu)) \
    X(CXType, clang_getPointeeType, (CXType t), (t)) \
    X(CXSourceLocation, clang_getRangeEnd, (CXSourceRange r), (r)) \
    X(CXSourceLocation, clang_getRangeStart, (CXSourceRange r), (r)) \
    X(CXString, clang_getTokenSpelling, (CXTranslationUnit tu, CXToken t), (tu, t)) \
    X(CXCursor, clang_getTranslationUnitCursor, (CXTranslationUnit tu), (tu)) \
    X(CXCursor, clang_getTypeDeclaration, (CXType t), (t)) \
    X(CXString, clang_getTypeSpelling, (CXType t), (t)) \
    X(unsigned, clang_isExpression, (enum CXCursorKind k), (k)) \
    X(unsigned, clang_isInvalid, (enum CXCursorKind k), (k)) \
    X(unsigned, clang_isStatement, (enum CXCursorKind k), (k)) \
    X(enum CXErrorCode, clang_parseTranslationUnit2, \
      (CXIndex index, const char *source, const char *const *args, int nargs, struct CXUnsavedFile *unsaved, \
       unsigned nunsaved, unsigned options, CXTranslationUnit *tu), \
      (index, source, args, nargs, unsaved, nunsaved, options, tu)) \
    V(clang_tokenize, (CXTranslationUnit tu, CXSourceRange r, CXToken **tokens, unsigned *n), (tu, r, tokens, n)) \
    X(unsigned, clang_visitChildren, (CXCursor parent, CXCursorVisitor visitor, CXClientData data), (parent, visitor, data))

#define POINTER(R, N, P, A) static R (*p_##N) P;
#define VPOINTER(N, P, A) static void (*p_##N) P;
DRYDOCK_LIBCLANG_FUNCTIONS(POINTER, VPOINTER)

static void *handle;

static void unloaded(const char *name) __attribute__((noreturn));
static void unloaded(const char *name) {
    fprintf(stderr, "drydock-objc: %s called before libclang was loaded\n", name);
    abort();
}

#define FORWARD(R, N, P, A) R N P { if (!p_##N) unloaded(#N); return p_##N A; }
#define VFORWARD(N, P, A) void N P { if (!p_##N) unloaded(#N); p_##N A; }
DRYDOCK_LIBCLANG_FUNCTIONS(FORWARD, VFORWARD)

/* platform: POSIX (dlsym) returns a data pointer that may be converted to a function pointer;
 *           assigning through void ** is the conversion it documents. */
#define RESOLVE(R, N, P, A) if (!missing && !(*(void **)&p_##N = dlsym(h, #N))) missing = #N;
#define VRESOLVE(N, P, A) RESOLVE(void, N, P, A)
#define CLEAR(R, N, P, A) p_##N = NULL;
#define VCLEAR(N, P, A) p_##N = NULL;

int drydock_libclang_load(const char *path, char *err, size_t errlen) {
    const char *missing = NULL;
    const char *why;
    void *h;
    if (handle) {
        snprintf(err, errlen, "libclang is already loaded");
        return -1;
    }
    if (!(h = dlopen(path, RTLD_NOW | RTLD_LOCAL))) {
        why = dlerror();
        snprintf(err, errlen, "cannot load libclang %s: %s", path, why ? why : "dlopen failed");
        return -1;
    }
    DRYDOCK_LIBCLANG_FUNCTIONS(RESOLVE, VRESOLVE)
    if (missing) {
        snprintf(err, errlen, "libclang %s has no %s", path, missing);
        DRYDOCK_LIBCLANG_FUNCTIONS(CLEAR, VCLEAR)
        dlclose(h);
        return -1;
    }
    handle = h;
    return 0;
}

int drydock_libclang_major(char *out, size_t outlen) {
    CXString v = clang_getClangVersion();
    const char *text = clang_getCString(v), *p;
    int major = -1;
    snprintf(out, outlen, "%s", text ? text : "");
    clang_disposeString(v);
    if ((p = strstr(out, "version ")) && (p += 8, *p >= '0' && *p <= '9'))
        for (major = 0; *p >= '0' && *p <= '9' && major < 100000; p++) major = major * 10 + (*p - '0');
    return major;
}
