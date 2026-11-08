/* Fixture: one function per classification case, each sending with literal sel_registerName /
 * objc_getClass producers (the reader's noncache forms) so every receiver closes by measurement
 * and the verdict is the only question. The floor facts are the committed 10.9.5 reference set.
 * Linked against the pinned 10.9 SDK, read as bytes, never executed.
 *
 * Nothing here names a later API in a list: each later method or class is found absent by the
 * floor runtime capture, so the analogous future method is caught the same way. */
#include <stddef.h>
#include <objc/runtime.h>
#include <objc/message.h>

typedef void *obj_t;
typedef signed char BOOLish;
extern obj_t objc_alloc(obj_t cls);
extern void fixture_use(void *p);   /* resolved never: keeps a result alive */

#define CLS(n) ((obj_t)objc_getClass(n))
#define SEL_(n) sel_registerName(n)
#define SEND0(r, s) ((obj_t (*)(obj_t, SEL))objc_msgSend)((r), SEL_(s))
#define SEND1(r, s, a) ((obj_t (*)(obj_t, SEL, void *))objc_msgSend)((r), SEL_(s), (void *)(a))
#define ASK(r, s, a) ((BOOLish (*)(obj_t, SEL, void *))objc_msgSend)((r), SEL_(s), (void *)(a))
#define N __attribute__((noinline, used))

static inline __attribute__((always_inline)) obj_t workspace(void) { return SEND0(CLS("NSWorkspace"), "sharedWorkspace"); }
static inline __attribute__((always_inline)) obj_t string(void) { return SEND1(CLS("NSString"), "stringWithUTF8String:", ""); }

/* Exact class, kind and inheritance. */
N obj_t class_method(void) { return workspace(); }
N obj_t instance_kind(void) { return SEND0(workspace(), "sharedWorkspace"); }
N obj_t inherited(void) { return SEND0(workspace(), "description"); }
/* The same selector on an unrelated class (NSArray -count) does not make it available here. */
N obj_t unrelated(void) { return SEND0(workspace(), "count"); }
/* A later method and a later class: absent on the floor, on no list anywhere. */
N obj_t later_method(void) { obj_t s = string(); return SEND1(s, "containsString:", s); }
N obj_t later_class(void) { return objc_alloc(CLS("NSVisualEffectView")); }
/* A class outside the reference closure, and one whose image the capture did not record. */
N obj_t outside(void) { return SEND0(CLS("AVPlayer"), "new"); }
N obj_t uncaptured(void) { return SEND0(CLS("ODSession"), "defaultSession"); }
/* A category implemented by another image (AppKit's NSStringDrawing on Foundation's NSString). */
N obj_t category(void) { return SEND1(string(), "sizeWithAttributes:", 0); }
/* Class clusters: the concrete +alloc result's own method, versus a subclass-only method. */
N obj_t cluster_alloc(void) {
    obj_t s = objc_alloc(CLS("NSString"));
    return ((obj_t (*)(obj_t, SEL, const char *, unsigned long, unsigned long))objc_msgSend)(s, SEL_("initWithBytes:length:encoding:"), "", 0, 4);
}
N obj_t cluster_uncertain(void) { obj_t s = string(); return SEND1(s, "appendString:", s); }

/* Selector construction used only as a query, and an introspection import: not sends of it. */
N long query_only(void) { return ASK(workspace(), "respondsToSelector:", SEL_("isVoiceOverEnabled")); }
N const char *introspect(void) { return sel_getName(SEL_("openURLs:withApplicationAtURL:options:configuration:error:")); }

/* Guards: exact, wrong selector, wrong receiver, ineffective fallback, none. */
N long guarded(void) {
    obj_t ws = workspace();
    if (ASK(ws, "respondsToSelector:", SEL_("accessibilityDisplayShouldReduceMotion")))
        return (long)SEND0(ws, "accessibilityDisplayShouldReduceMotion");
    return 0;
}
N long wrong_selector(void) {
    obj_t ws = workspace();
    if (ASK(ws, "respondsToSelector:", SEL_("isVoiceOverEnabled")))
        return (long)SEND0(ws, "accessibilityDisplayShouldReduceMotion");
    return 0;
}
N long wrong_receiver(void) {
    obj_t ws = workspace(), other = workspace();
    if (ASK(other, "respondsToSelector:", SEL_("accessibilityDisplayShouldReduceMotion")))
        return (long)SEND0(ws, "accessibilityDisplayShouldReduceMotion");
    return 0;
}
N long ineffective(void) {
    obj_t ws = workspace();
    volatile long asked = ASK(ws, "respondsToSelector:", SEL_("accessibilityDisplayShouldReduceMotion"));
    (void)asked;
    return (long)SEND0(ws, "accessibilityDisplayShouldReduceMotion");
}

/* R1 (b): root and non-root selectors on an `id` a floor class vends. */
static inline __attribute__((always_inline)) obj_t vended(void) { return SEND1(SEND0(CLS("NSDictionary"), "dictionary"), "objectForKey:", 0); }
N obj_t vended_root(void) { return SEND0(vended(), "description"); }
N obj_t vended_nonroot(void) { return SEND0(vended(), "count"); }
N obj_t vended_hash(void) { return SEND0(vended(), "hash"); }
N obj_t vended_retain(void) { return SEND0(vended(), "retain"); }
N obj_t vended_autorelease(void) { return SEND0(vended(), "autorelease"); }
N obj_t vended_class(void) { return SEND0(vended(), "class"); }

/* Downcast refinement: YES on the same value, on a different value, and the NO path. */
N obj_t downcast_same(void) {
    obj_t v = vended();
    if (ASK(v, "isKindOfClass:", CLS("NSString"))) return SEND0(v, "UTF8String");
    return 0;
}
N obj_t downcast_other(void) {
    obj_t v = vended(), w = vended();
    if (ASK(v, "isKindOfClass:", CLS("NSString"))) return SEND0(w, "UTF8String");
    return 0;
}
N obj_t downcast_no(void) {
    obj_t v = vended();
    if (!ASK(v, "isKindOfClass:", CLS("NSString"))) return SEND0(v, "UTF8String");
    return 0;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 99) {
        fixture_use(class_method()); fixture_use(instance_kind()); fixture_use(inherited()); fixture_use(unrelated());
        fixture_use(later_method()); fixture_use(later_class()); fixture_use(outside()); fixture_use(uncaptured());
        fixture_use(category()); fixture_use(cluster_alloc()); fixture_use(cluster_uncertain());
        fixture_use((void *)query_only()); fixture_use((void *)introspect()); fixture_use((void *)guarded());
        fixture_use((void *)wrong_selector()); fixture_use((void *)wrong_receiver()); fixture_use((void *)ineffective());
        fixture_use(vended_root()); fixture_use(vended_nonroot()); fixture_use(vended_hash()); fixture_use(vended_retain()); fixture_use(vended_autorelease()); fixture_use(vended_class()); fixture_use(downcast_same());
        fixture_use(downcast_other()); fixture_use(downcast_no());
    }
    return 0;
}
