/* Fixture: R3, positional type evidence. Each function carries the exact v0 symbol of a Codex
 * 0.165.0 (rebuilt, codex-cli objc-provider-integration) function whose receiver class only a
 * cited position in library source fixes, and sends through objc2-style CACHED_SEL caches, as
 * r2.c does:
 *   r3_result    <ProtocolObject<dyn NSObjectProtocol> as Debug>::fmt: UTF8String and
 *                lengthOfBytesUsingEncoding: to the result of a description send.
 *   r3_field     <FilterMap<objc2_foundation::array::Iter<AnyObject>, arboard ...> as Iterator>::next
 *                (with ThinLTO's .llvm.1 suffix): countByEnumeratingWithState:objects:count: to an
 *                object loaded from a field of its argument.
 *   r3_downcast  os_info::imp::current_platform: objectForKey: to an object loaded from a field.
 *   r3_merged    os_info::imp::merged: UTF8String at one call site whose receiver is, on one path,
 *                the result of description and, on the other, the result of hash.
 * Linked, read as bytes, never executed. */
#include <stddef.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define SYM(s) __asm__(s)
typedef void *obj_t;

__attribute__((section("__TEXT,__const"), used))
static const char packed[] = "UTF8String\0" "lengthOfBytesUsingEncoding:\0" "description\0" "hash\0"
                             "countByEnumeratingWithState:objects:count:\0" "objectForKey:\0";
#define P_UTF8 0
#define P_LEN 11
#define P_DESC 39
#define P_HASH 51
#define P_ENUM 56
#define P_OBJ 99

void *c_utf8 SYM("__RNvNvNtNtCs2WYrep5oUp8_5objc27runtime10___nsstring15nsstring_to_str10CACHED_SEL");
void *c_len SYM("__RNvNvNtNtCs2WYrep5oUp8_5objc27runtime10___nsstring12nsstring_len10CACHED_SEL");
void *c_desc SYM("__RNvNvNtCs2WYrep5oUp8_5objc23fix4desc10CACHED_SEL");
void *c_hash SYM("__RNvNvNtCs2WYrep5oUp8_5objc23fix4hash10CACHED_SEL");
void *c_enum SYM("__RNvNvNtCs2WYrep5oUp8_5objc23fix4enum10CACHED_SEL");
void *c_obj SYM("__RNvNvNtCs2WYrep5oUp8_5objc23fix3obj10CACHED_SEL");

__attribute__((noinline, used)) SEL sel_fetch(void **cache, const char *name)
    SYM("__RNvMNtNtCs2WYrep5oUp8_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch");
__attribute__((noinline, used)) SEL sel_fetch(void **cache, const char *name) {
    SEL s = sel_registerName(name);
    *cache = (void *)s;
    return s;
}
#define SEL_OF(c, p) ((c) ? (SEL)(c) : sel_fetch(&(c), packed + (p)))
#define SEND0(r, c, p) ((obj_t (*)(obj_t, SEL))objc_msgSend)((r), SEL_OF(c, p))

unsigned long r3_result(obj_t *self)
    SYM("__RNvXs6_NtNtCs2WYrep5oUp8_5objc27runtime15protocol_objectINtB5_14ProtocolObjectDNtNtB7_8nsobject16NSObjectProtocolEL_ENtNtCs5hICDV8pRVn_4core3fmt5Debug3fmtCsdIImX2SWmg2_16objc2_foundation");
__attribute__((noinline, used)) unsigned long r3_result(obj_t *self) {
    obj_t d = SEND0(*self, c_desc, P_DESC);
    const char *bytes = ((const char *(*)(obj_t, SEL))objc_msgSend)(d, SEL_OF(c_utf8, P_UTF8));
    unsigned long len = ((unsigned long (*)(obj_t, SEL, unsigned long))objc_msgSend)(d, SEL_OF(c_len, P_LEN), 4);
    return len + (bytes != NULL);
}

unsigned long r3_field(obj_t *it)
    SYM("__RNvXs0_NtNtNtCs5hICDV8pRVn_4core4iter8adapters10filter_mapINtB5_9FilterMapINtNtCsdIImX2SWmg2_16objc2_foundation5array4IterNtNtCs2WYrep5oUp8_5objc27runtime9AnyObjectENCNCNCNvMs3_NtNtCsIwpAeRmYHq_7arboard8platform3osxNtB2P_3Get9file_list000ENtNtNtB9_6traits8iterator8Iterator4nextB2T_.llvm.1");
__attribute__((noinline, used)) unsigned long r3_field(obj_t *it) {
    void *state[8] = { 0 };
    obj_t buf[16];
    return ((unsigned long (*)(obj_t, SEL, void *, obj_t *, unsigned long))objc_msgSend)(it[2], SEL_OF(c_enum, P_ENUM), state, buf, 16);
}

obj_t r3_downcast(obj_t *holder)
    SYM("__RNvNtCslTKFwgOQWRM_7os_info3imp16current_platform");
__attribute__((noinline, used)) obj_t r3_downcast(obj_t *holder) {
    return ((obj_t (*)(obj_t, SEL, obj_t))objc_msgSend)(holder[1], SEL_OF(c_obj, P_OBJ), holder[2]);
}

unsigned long r3_merged(obj_t *self, int which)
    SYM("__RNvNtCslTKFwgOQWRM_7os_info3imp6merged");
__attribute__((noinline, used)) unsigned long r3_merged(obj_t *self, int which) {
    obj_t r;
    /* distinct barriers keep the compiler from merging the two fetch calls into one */
    if (which) { r = SEND0(*self, c_desc, P_DESC); __asm__ volatile("# description path" ::: "memory"); }
    else { r = SEND0(*self, c_hash, P_HASH); __asm__ volatile("# hash path" ::: "memory"); }
    return (unsigned long)((const char *(*)(obj_t, SEL))objc_msgSend)(r, SEL_OF(c_utf8, P_UTF8));
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 99) return (int)(r3_result(NULL) + r3_field(NULL) + (unsigned long)r3_downcast(NULL) + r3_merged(NULL, argc));
    return 0;
}
