/* Fixture: the objc2 0.6.3 / objc2-foundation 0.3.2 / objc2-app-kit 0.3.2 dispatch shape that
 * Codex 0.165.0 ships, reproduced in C so the reader test needs no Rust toolchain. Symbols are
 * the exact v0 names from that build; selector names live in packed ordinary data, never in
 * conventional __objc_selrefs. Never executed: the reader test only links and reads it.
 *
 * Forms: CachedSel::fetch(&CACHED_SEL, "sel\0") with consumers that load the static;
 * CachedClass::fetch(&CACHED_CLASS, "Class\0", caller); an inlined fetch through
 * Sel::register_unchecked followed by a store; NSSelectorFromString(NSString::from_str(p, n))
 * guard queries; literal objc_getClass; objc_alloc; and incidental prose naming a later selector
 * that nothing produces. */
#include <stddef.h>
#include <stdio.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define SYM(s) __asm__(s)
/* Overridable so the binding test can rename one producer or static and expect a refusal. */
#ifndef FETCH_SEL_SYM
#define FETCH_SEL_SYM "__RNvMNtNtCs2ucXwfqiSr7_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch"
#endif
#ifndef CACHE_OPEN_SYM
#define CACHE_OPEN_SYM "__RNvNvMsj_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated13___NSWorkspaceNtB7_11NSWorkspace57openURLs_withApplicationAtURL_options_configuration_error10CACHED_SEL.llvm.14758197362344036277"
#endif

typedef void *obj_t;
extern obj_t objc_alloc(obj_t cls);
extern SEL NSSelectorFromString(obj_t name);

/* Packed: several selector/class names back to back in one constant, as rustc lays out
 * concat!(name, '\0') literals; the reader must use the fetch site's address, not a scan. */
__attribute__((section("__TEXT,__const"), used))
static const char packed[] =
    "NSWorkspace\0"
    "sharedWorkspace\0"
    "openURLs:withApplicationAtURL:options:configuration:error:\0"
    "stringWithUTF8String:\0"
    "errorWithDomain:code:userInfo:\0"
    "isVoiceOverEnabled"          /* from_str bytes: no NUL of their own */
    "NSString\0";
#define AT(off) (packed + (off))
#define P_NSWORKSPACE 0
#define P_SHARED 12
#define P_OPENURLS 28
#define P_UTF8 87
#define P_ERROR 109
#define P_VOICEOVER 140
#define P_NSSTRING 158

void *cache_shared SYM("__RNvNvMs0_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated13___NSWorkspaceNtB7_11NSWorkspace15sharedWorkspace10CACHED_SEL.llvm.14758197362344036277");
void *cache_open SYM(CACHE_OPEN_SYM);
void *cache_ws SYM("__RNvNvXsv_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated13___NSWorkspaceNtB7_11NSWorkspaceNtNtCs2ucXwfqiSr7_5objc216top_level_traits9ClassType5class12CACHED_CLASS");
void *cache_utf8 SYM("__RNvNCNvNtNtCs2ucXwfqiSr7_5objc215___macro_helpers10null_error17create_null_error010CACHED_SEL.0.llvm.17947433011947877056");
void *cache_error SYM("__RNvNCNvNtNtCs2ucXwfqiSr7_5objc215___macro_helpers10null_error17create_null_error0s_10CACHED_SEL.0.llvm.17947433011947877056");

__attribute__((noinline, used)) SEL sel_fetch(void **cache, const char *name) SYM(FETCH_SEL_SYM);
__attribute__((noinline, used)) SEL sel_fetch(void **cache, const char *name) {
    SEL s = sel_registerName(name);
    *cache = (void *)s;
    return s;
}

__attribute__((noinline, used)) obj_t class_fetch(void **cache, const char *name, const void *caller)
    SYM("__RNvMs_NtNtCs2ucXwfqiSr7_5objc215___macro_helpers5cacheNtB4_11CachedClass5fetch");
__attribute__((noinline, used)) obj_t class_fetch(void **cache, const char *name, const void *caller) {
    obj_t c = (obj_t)objc_getClass(name);
    (void)caller;
    *cache = c;
    return c;
}

__attribute__((noinline, used)) SEL register_unchecked(const char *name)
    SYM("__RNvMs2_NtCs2ucXwfqiSr7_5objc27runtimeNtB5_3Sel18register_unchecked");
__attribute__((noinline, used)) SEL register_unchecked(const char *name) { return sel_registerName(name); }

__attribute__((noinline, used)) obj_t from_str(const char *bytes, size_t len)
    SYM("__RNvMs0_NtCsltbaDnwDLUa_16objc2_foundation6stringNtNtNtB7_9generated10___NSString8NSString8from_str");
extern obj_t fixture_nsstring(const char *bytes, size_t len);   /* resolved never: not executed */
__attribute__((noinline, used)) obj_t from_str(const char *bytes, size_t len) {
    return fixture_nsstring(bytes, len);
}

static const int caller_location = 0;

/* webbrowser 1.2.4's launch path: NSWorkspace.sharedWorkspace, then the 10.10 method. */
__attribute__((noinline, used)) obj_t open_browser(obj_t urls, obj_t app) {
    obj_t cls = cache_ws ? cache_ws : class_fetch(&cache_ws, AT(P_NSWORKSPACE), &caller_location);
    SEL shared = cache_shared ? (SEL)cache_shared : sel_fetch(&cache_shared, AT(P_SHARED));
    obj_t ws = ((obj_t (*)(obj_t, SEL))objc_msgSend)(cls, shared);
    SEL open = cache_open ? (SEL)cache_open : sel_fetch(&cache_open, AT(P_OPENURLS));
    return ((obj_t (*)(obj_t, SEL, obj_t, obj_t, unsigned long, obj_t, obj_t *))objc_msgSend)(ws, open, urls, app, 0, NULL, NULL);
}

/* null_error: literal class lookups plus an inlined fetch storing into each cache. */
__attribute__((noinline, used)) obj_t null_error(void) {
    obj_t str = (obj_t)objc_getClass(AT(P_NSSTRING));
    SEL utf8 = (SEL)cache_utf8;
    SEL err;
    if (!utf8) { utf8 = register_unchecked(AT(P_UTF8)); cache_utf8 = (void *)utf8; }
    str = ((obj_t (*)(obj_t, SEL, const char *))objc_msgSend)(str, utf8, "");
    err = (SEL)cache_error;
    if (!err) { err = register_unchecked(AT(P_ERROR)); cache_error = (void *)err; }
    return ((obj_t (*)(obj_t, SEL, obj_t))objc_msgSend)(str, err, NULL);
}

/* The screen-reader guard query: build the selector, then ask respondsToSelector:. */
__attribute__((noinline, used)) SEL voiceover_query(void) {
    obj_t name = from_str(AT(P_VOICEOVER), 18);
    return NSSelectorFromString(name);
}

__attribute__((noinline, used)) obj_t alloc_one(void) {
    obj_t cls = cache_ws ? cache_ws : class_fetch(&cache_ws, AT(P_NSWORKSPACE), &caller_location);
    return objc_alloc(cls);
}

int main(int argc, char **argv) {
    /* Incidental prose: the reader must not turn this into a producer. */
    if (argc > 5) puts("Call accessibilityDisplayShouldReduceMotion when you can.");
    if (argc > 9) { open_browser(NULL, NULL); null_error(); voiceover_query(); alloc_one(); }
    (void)argv;
    return 0;
}
