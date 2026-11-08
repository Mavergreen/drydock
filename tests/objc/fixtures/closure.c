/* Fixture: receiver/use closure over the objc2 0.6.3 shapes Codex 0.165.0 ships, reproduced in C
 * (as objc2-pattern.c is) with the exact v0 cache symbols of the six shared helper caches and the
 * Codex call shapes that consume them. Linked, read as bytes, never executed.
 *
 * The default build is the strict positive: every send has a recoverable selector and a receiver
 * that a class cache, a literal class lookup, an allocation or a typed result closes -- or, for
 * the one generated method whose receiver is its own argument, the binding receipt. Each
 * -DOPEN_FORM=N adds exactly one send whose receiver stays unknown, as in the real binary:
 *   1  isKindOfClass: on an `id` result (os_info's property-list downcast)
 *   2  description on a protocol-typed argument (ProtocolObject<dyn NSObjectProtocol> Debug)
 *   3  countByEnumeratingWithState:objects:count: on an iterator field (FilterMap::next)
 *   4  a send whose selector register holds no recoverable selector
 *   5  a receiver spilled to a frame slot whose address then escapes to an opaque call */
#include <stddef.h>
#include <stdio.h>
#include <objc/runtime.h>
#include <objc/message.h>

#define SYM(s) __asm__(s)
typedef void *obj_t;
typedef struct { unsigned long state; obj_t *items; unsigned long *mut; unsigned long extra[5]; } FastState;
extern obj_t objc_alloc(obj_t cls);
extern obj_t objc_retainAutoreleasedReturnValue(obj_t o);
extern void objc_release(obj_t o);
extern SEL NSSelectorFromString(obj_t name);
extern void fixture_use(void *p);   /* resolved never: an opaque Rust callee */

__attribute__((section("__TEXT,__const"), used))
static const char packed[] =
    "NSWorkspace\0" "sharedWorkspace\0" "respondsToSelector:\0" "isVoiceOverEnabled"
    "NSDictionary\0" "new\0" "init\0" "NSPasteboard\0" "generalPasteboard\0" "pasteboardItems\0"
    "countByEnumeratingWithState:objects:count:\0" "NSString\0" "initWithBytes:length:encoding:\0"
    "stringWithUTF8String:\0" "NSError\0" "errorWithDomain:code:userInfo:\0" "description\0"
    "isKindOfClass:\0" "propertyListWithData:options:format:error:\0"
    "NSPropertyListSerialization\0" "isVoiceOverEnabled\0";
#define AT(off) (packed + (off))
#define P_NSWORKSPACE 0
#define P_SHARED 12
#define P_RESPONDS 28
#define P_VOICEOVER 48
#define P_NSDICTIONARY 66
#define P_NEW 79
#define P_INIT 83
#define P_NSPASTEBOARD 88
#define P_GENERAL 101
#define P_ITEMS 119
#define P_COUNTBY 135
#define P_NSSTRING 178
#define P_INITBYTES 187
#define P_UTF8 218
#define P_NSERROR 240
#define P_ERROR 248
#define P_DESCRIPTION 279
#define P_KINDOF 291
#define P_PLIST 306
#define P_NSPLIST 349
#define P_VOICEOVER_SEL 377

/* Generated inherent-method caches, as in objc2-app-kit 0.3.2 / objc2-foundation 0.3.2. */
void *c_shared SYM("__RNvNvMs0_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated13___NSWorkspaceNtB7_11NSWorkspace15sharedWorkspace10CACHED_SEL.llvm.14758197362344036277");
void *c_voiceover SYM("__RNvNvMs1_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated17___NSAccessibilityNtNtB9_13___NSWorkspace11NSWorkspace18isVoiceOverEnabled10CACHED_SEL");
void *c_general SYM("__RNvNvMs2_NtNtCshvDjvTOIJ7r_7arboard8platform3osxNtB7_9Clipboard3new10CACHED_SEL.llvm.16184367201632699273");
void *c_items SYM("__RNvNvMs3_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated14___NSPasteboardNtB7_12NSPasteboard15pasteboardItems10CACHED_SEL.llvm.10206980812815461896");
void *c_plist SYM("__RNvNvMs3_NtNtCsltbaDnwDLUa_16objc2_foundation9generated16___NSPropertyListNtB7_27NSPropertyListSerialization41propertyListWithData_options_format_error10CACHED_SEL.llvm.42470404241539981");
/* Class caches. */
void *k_ws SYM("__RNvNvXsv_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated13___NSWorkspaceNtB7_11NSWorkspaceNtNtCs2ucXwfqiSr7_5objc216top_level_traits9ClassType5class12CACHED_CLASS");
void *k_dict SYM("__RNvNvXso_NtNtCsltbaDnwDLUa_16objc2_foundation9generated14___NSDictionaryINtB7_12NSDictionaryppENtNtCs2ucXwfqiSr7_5objc216top_level_traits9ClassType5class12CACHED_CLASS");
void *k_pb SYM("__RNvNvXsz_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated14___NSPasteboardNtB7_12NSPasteboardNtNtCs2ucXwfqiSr7_5objc216top_level_traits9ClassType5class12CACHED_CLASS");
void *k_str SYM("__RNvNvXsU_NtNtCsltbaDnwDLUa_16objc2_foundation9generated10___NSStringNtB7_8NSStringNtNtCs2ucXwfqiSr7_5objc216top_level_traits9ClassType5class12CACHED_CLASS");
void *k_plist SYM("__RNvNvXsr_NtNtCsltbaDnwDLUa_16objc2_foundation9generated16___NSPropertyListNtB7_27NSPropertyListSerializationNtNtCs2ucXwfqiSr7_5objc216top_level_traits9ClassType5class12CACHED_CLASS");
/* The six shared helper caches, by their exact Codex 0.165.0 statics. */
void *h_kindof SYM("__RNvNvMsO_NtCs2ucXwfqiSr7_5objc27runtimeNtB7_9AnyObject16is_kind_of_class10CACHED_SEL.llvm.4503674262171288378");
void *h_new SYM("__RNvNvNtNtCs2ucXwfqiSr7_5objc215___macro_helpers16common_selectors7new_sel10CACHED_SEL");
void *h_init SYM("__RNvNvNtNtCs2ucXwfqiSr7_5objc215___macro_helpers16common_selectors8init_sel10CACHED_SEL");
void *h_description SYM("__RNvNvNtNtNtCs2ucXwfqiSr7_5objc27runtime8nsobject16NSObjectProtocol11description10CACHED_SEL");
void *h_responds SYM("__RNvNvNtNtNtCs2ucXwfqiSr7_5objc27runtime8nsobject16NSObjectProtocol18respondsToSelector10CACHED_SEL");
void *h_countby SYM("__RNvNvNtNtNtCsltbaDnwDLUa_16objc2_foundation9generated14___NSEnumerator17NSFastEnumeration41countByEnumeratingWithState_objects_count10CACHED_SEL");
/* Generic private helpers. */
void *g_initbytes SYM("__RNvNvNtCsltbaDnwDLUa_16objc2_foundation6string13init_with_str10CACHED_SEL.llvm.2359793684871636677");
void *g_utf8 SYM("__RNvNCNvNtNtCs2ucXwfqiSr7_5objc215___macro_helpers10null_error17create_null_error010CACHED_SEL.0.llvm.17947433011947877056");
void *g_error SYM("__RNvNCNvNtNtCs2ucXwfqiSr7_5objc215___macro_helpers10null_error17create_null_error0s_10CACHED_SEL.0.llvm.17947433011947877056");

__attribute__((noinline, used)) SEL sel_fetch(void **cache, const char *name)
    SYM("__RNvMNtNtCs2ucXwfqiSr7_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch");
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
extern obj_t fixture_nsstring(const char *bytes, size_t len);
__attribute__((noinline, used)) obj_t from_str(const char *bytes, size_t len) { return fixture_nsstring(bytes, len); }

static const int here = 0;
#define SEL_OF(c, p) ((c) ? (SEL)(c) : sel_fetch(&(c), AT(p)))
#define CLASS_OF(c, p) ((c) ? (c) : class_fetch(&(c), AT(p), &here))
#define SEND0(r, s) ((obj_t (*)(obj_t, SEL))objc_msgSend)((r), (s))
#define SEND1(r, s, a) ((obj_t (*)(obj_t, SEL, void *))objc_msgSend)((r), (s), (void *)(a))

/* codex_tui::screen_reader::detect: sharedWorkspace (typed result), then a guarded query whose
 * receiver is that result. Cache 46's receiver closes through the typed +sharedWorkspace result. */
__attribute__((noinline, used)) long voiceover_guarded(void) {
    obj_t ws = objc_retainAutoreleasedReturnValue(SEND0(CLASS_OF(k_ws, P_NSWORKSPACE), SEL_OF(c_shared, P_SHARED)));
    SEL query = NSSelectorFromString(from_str(AT(P_VOICEOVER), 18));
    long on = 0;
    if (((signed char (*)(obj_t, SEL, SEL))objc_msgSend)(ws, SEL_OF(h_responds, P_RESPONDS), query))
        on = (long)SEND0(ws, SEL_OF(c_voiceover, P_VOICEOVER_SEL));
    objc_release(ws);
    return on;
}

/* A second caller of the same isVoiceOverEnabled cache with no guard: a distinct site. */
__attribute__((noinline, used)) long voiceover_unguarded(void) {
    obj_t ws = objc_retainAutoreleasedReturnValue(SEND0(CLASS_OF(k_ws, P_NSWORKSPACE), SEL_OF(c_shared, P_SHARED)));
    long on = (long)SEND0(ws, SEL_OF(c_voiceover, P_VOICEOVER_SEL));
    objc_release(ws);
    return on;
}

/* NSDictionary::new() as webbrowser builds launch options: cache 41's receiver is a class cache. */
__attribute__((noinline, used)) obj_t empty_options(void) {
    return SEND0(CLASS_OF(k_dict, P_NSDICTIONARY), SEL_OF(h_new, P_NEW));
}

/* retain_semantics::new_fail / init_fail: the selector is compared, never sent. */
__attribute__((noinline, used)) int is_plain_new(SEL sel) { return sel == SEL_OF(h_new, P_NEW); }
__attribute__((noinline, used)) int is_plain_init(SEL sel) { return sel == SEL_OF(h_init, P_INIT); }

/* arboard Clipboard::string_from_type: the item array is spilled to a frame slot below every
 * frame address the loop hands out (the enumeration state and buffer), then reloaded for each
 * countByEnumeratingWithState:objects:count: across calls that receive only those higher
 * addresses. Cache 47's receiver closes through the typed -pasteboardItems result. */
typedef struct { obj_t spilled; FastState st; obj_t buf[16]; } EnumFrame;
__attribute__((noinline, used)) unsigned long enumerate_items(void) {
    obj_t pb = objc_retainAutoreleasedReturnValue(SEND0(CLASS_OF(k_pb, P_NSPASTEBOARD), SEL_OF(c_general, P_GENERAL)));
    obj_t items = objc_retainAutoreleasedReturnValue(SEND0(pb, SEL_OF(c_items, P_ITEMS)));
    volatile EnumFrame f;
    unsigned long n, total = 0;
    f.spilled = items;
    fixture_use((void *)&f.st);
    do {
        n = ((unsigned long (*)(obj_t, SEL, volatile FastState *, volatile obj_t *, unsigned long))objc_msgSend)(
            f.spilled, SEL_OF(h_countby, P_COUNTBY), &f.st, f.buf, 16);
        total += n;
        fixture_use((void *)f.buf);
    } while (n);
    objc_release(items);
    objc_release(pb);
    return total;
}

/* NSString::from_str: objc_alloc of a class cache, then the generic init helper on the result. */
__attribute__((noinline, used)) obj_t string_from(const char *bytes, unsigned long len) {
    obj_t fresh = objc_alloc(CLASS_OF(k_str, P_NSSTRING));
    return ((obj_t (*)(obj_t, SEL, const char *, unsigned long, unsigned long))objc_msgSend)(
        fresh, SEL_OF(g_initbytes, P_INITBYTES), bytes, len, 4);
}

/* null_error: two literal class lookups, each paired with its own inlined selector cache. */
__attribute__((noinline, used)) obj_t null_error(void) {
    obj_t str = (obj_t)objc_getClass(AT(P_NSSTRING));
    obj_t errc = (obj_t)objc_getClass(AT(P_NSERROR));
    SEL utf8 = (SEL)g_utf8, err;
    if (!utf8) { utf8 = register_unchecked(AT(P_UTF8)); g_utf8 = (void *)utf8; }
    str = SEND1(str, utf8, "");
    err = (SEL)g_error;
    if (!err) { err = register_unchecked(AT(P_ERROR)); g_error = (void *)err; }
    return SEND1(errc, err, str);
}

/* Class versus instance: +description on a class cache is a class-method send. */
__attribute__((noinline, used)) obj_t class_description(void) {
    return SEND0(CLASS_OF(k_dict, P_NSDICTIONARY), SEL_OF(h_description, P_DESCRIPTION));
}

/* A generated inherent method whose receiver is its own argument (`&self`): the binary says only
 * "argument", so its receiver closes through the binding receipt for that method's cache. */
__attribute__((noinline, used)) obj_t items_of(obj_t pasteboard) {
    return SEND0(pasteboard, SEL_OF(c_items, P_ITEMS));
}


#if OPEN_FORM == 1
__attribute__((noinline, used)) long plist_is_dictionary(obj_t data) {
    obj_t plist = objc_retainAutoreleasedReturnValue(
        ((obj_t (*)(obj_t, SEL, obj_t, unsigned long, void *, void *))objc_msgSend)(
            CLASS_OF(k_plist, P_NSPLIST), SEL_OF(c_plist, P_PLIST), data, 0, NULL, NULL));
    return (long)SEND1(plist, SEL_OF(h_kindof, P_KINDOF), CLASS_OF(k_dict, P_NSDICTIONARY));
}
#elif OPEN_FORM == 2
__attribute__((noinline, used)) obj_t protocol_debug(obj_t self) {
    return SEND0(self, SEL_OF(h_description, P_DESCRIPTION));
}
#elif OPEN_FORM == 3
typedef struct { unsigned long pad[2]; obj_t array; FastState st; obj_t buf[16]; } Iter;
__attribute__((noinline, used)) unsigned long iter_next(Iter *it) {
    return ((unsigned long (*)(obj_t, SEL, FastState *, obj_t *, unsigned long))objc_msgSend)(
        it->array, SEL_OF(h_countby, P_COUNTBY), &it->st, it->buf, 16);
}
#elif OPEN_FORM == 4
__attribute__((noinline, used)) obj_t computed_send(obj_t ws, SEL any) { return SEND0(ws, any); }
#elif OPEN_FORM == 5
__attribute__((noinline, used)) obj_t escaped_spill(void) {
    volatile obj_t slot = objc_retainAutoreleasedReturnValue(SEND0(CLASS_OF(k_ws, P_NSWORKSPACE), SEL_OF(c_shared, P_SHARED)));
    fixture_use((void *)&slot);
    return SEND0(slot, SEL_OF(h_description, P_DESCRIPTION));
}
#endif

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 9) {
        voiceover_guarded(); voiceover_unguarded(); empty_options(); is_plain_new(0); is_plain_init(0);
        enumerate_items(); string_from("", 0); null_error(); class_description(); items_of(0);
    }
    return 0;
}
