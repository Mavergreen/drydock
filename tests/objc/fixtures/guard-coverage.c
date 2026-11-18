/* Fixture: schema-2 guard coverage. Literal sel_registerName / objc_getClass producers, as in
 * classify.c, so every receiver closes by measurement. Linked against the pinned 10.9 SDK, read
 * as bytes, never executed.
 * Each function is named by a Rust v0 symbol (asm label) in crate fixture, disambiguator 1Fx:
 *   guarded        fixture::guarded, one guarded send of a later method
 *   guarded_again  a copy of it, instantiated in crate other
 *   guarded_more   another copy, instantiated in crate other2, with two guarded sends
 *   guarded_twice  fixture::guarded_twice, two guarded sends of it in one function
 *   unguarded      fixture::unguarded, the same send with no guard
 * and one C function, plain_guarded, a copy of guarded under a name that is no Rust symbol.
 * -DEXTRA_SEND gives guarded a second guarded send, for one slice of a fat fixture. */
#include <objc/runtime.h>
#include <objc/message.h>

typedef void *obj_t;
typedef signed char BOOLish;
extern void fixture_use(void *p);

#define CLS(n) ((obj_t)objc_getClass(n))
#define SEL_(n) sel_registerName(n)
#define SEND0(r, s) ((obj_t (*)(obj_t, SEL))objc_msgSend)((r), SEL_(s))
#define ASK(r, s, a) ((BOOLish (*)(obj_t, SEL, void *))objc_msgSend)((r), SEL_(s), (void *)(a))
#define N __attribute__((noinline, used))
#define LATER "accessibilityDisplayShouldReduceMotion"

long guarded(void) __asm__("__RNvCs1Fx_7fixture7guarded");
long guarded_again(void) __asm__("__RNvCs1Fx_7fixture7guardedCs9Zz_5other");
long guarded_more(void) __asm__("__RNvCs1Fx_7fixture7guardedCs8Yy_6other2");
long guarded_twice(void) __asm__("__RNvCs1Fx_7fixture13guarded_twice");
long unguarded(void) __asm__("__RNvCs1Fx_7fixture9unguarded");

static inline __attribute__((always_inline)) obj_t workspace(void) { return SEND0(CLS("NSWorkspace"), "sharedWorkspace"); }

N long guarded(void) {
    obj_t ws = workspace();
#ifdef EXTRA_SEND
    long r = 0;
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) r += (long)SEND0(ws, LATER);
    fixture_use(&r);
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) r += (long)SEND0(ws, LATER);
    return r;
#endif
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) return (long)SEND0(ws, LATER);
    return 0;
}
N long guarded_again(void) {
    obj_t ws = workspace();
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) return (long)SEND0(ws, LATER);
    return 0;
}
N long plain_guarded(void) {
    obj_t ws = workspace();
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) return (long)SEND0(ws, LATER);
    return 0;
}
N long guarded_more(void) {
    obj_t ws = workspace();
    long r = 0;
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) r += (long)SEND0(ws, LATER);
    fixture_use(&r);
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) r += (long)SEND0(ws, LATER);
    return r;
}
N long guarded_twice(void) {
    obj_t ws = workspace();
    long r = 0;
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) r += (long)SEND0(ws, LATER);
    fixture_use(&r);
    if (ASK(ws, "respondsToSelector:", SEL_(LATER))) r += (long)SEND0(ws, LATER);
    return r;
}
N long unguarded(void) { return (long)SEND0(workspace(), LATER); }

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 99) return (int)(guarded() + guarded_again() + plain_guarded() + guarded_more() + guarded_twice() + unguarded());
    return 0;
}
