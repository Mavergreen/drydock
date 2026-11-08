/* Fixture: R2, Rust monomorphized type evidence. One function carries the exact v0 symbol of
 * Codex 0.165.0's <&objc2_foundation::NSString as core::fmt::Debug>::fmt and, like it, sends
 * UTF8String and lengthOfBytesUsingEncoding: through objc2's shared nsstring_to_str/nsstring_len
 * caches to the NSString its argument points at -- a receiver the binary alone cannot type.
 * -DLOCAL_FN makes that function a local symbol, so `strip -x` leaves the sends without the
 * symbol evidence R2 needs. Linked, read as bytes, never executed. */
#include <stddef.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define SYM(s) __asm__(s)
typedef void *obj_t;

__attribute__((section("__TEXT,__const"), used))
static const char packed[] = "UTF8String\0" "lengthOfBytesUsingEncoding:\0";
#define P_UTF8 0
#define P_LEN 11

void *c_utf8 SYM("__RNvNvNtNtCs2ucXwfqiSr7_5objc27runtime10___nsstring15nsstring_to_str10CACHED_SEL.llvm.13656251981681071778");
void *c_len SYM("__RNvNvNtNtCs2ucXwfqiSr7_5objc27runtime10___nsstring12nsstring_len10CACHED_SEL");

__attribute__((noinline, used)) SEL sel_fetch(void **cache, const char *name)
    SYM("__RNvMNtNtCs2ucXwfqiSr7_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch");
__attribute__((noinline, used)) SEL sel_fetch(void **cache, const char *name) {
    SEL s = sel_registerName(name);
    *cache = (void *)s;
    return s;
}
#define SEL_OF(c, p) ((c) ? (SEL)(c) : sel_fetch(&(c), packed + (p)))

#ifdef LOCAL_FN
#define LINKAGE static
#else
#define LINKAGE
#endif

LINKAGE unsigned long nsstring_debug(obj_t *self)
    SYM("__RNvXs1g_NtCs5hICDV8pRVn_4core3fmtRNtNtNtCsltbaDnwDLUa_16objc2_foundation9generated10___NSString8NSStringNtB6_5Debug3fmtBC_");
__attribute__((noinline, used)) LINKAGE unsigned long nsstring_debug(obj_t *self) {
    const char *bytes = ((const char *(*)(obj_t, SEL))objc_msgSend)(*self, SEL_OF(c_utf8, P_UTF8));
    unsigned long len = ((unsigned long (*)(obj_t, SEL, unsigned long))objc_msgSend)(*self, SEL_OF(c_len, P_LEN), 4);
    return len + (bytes != NULL);
}

int main(int argc, char **argv) {
    (void)argv;
    return argc > 99 ? (int)nsstring_debug(NULL) : 0;
}
