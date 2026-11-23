// regexec-pusharg.c's shape, but the frame local's address reaches the helper through a function that forwards its own
// incoming stack argument by a tail call (a sibcall at -Os and -Oz): it must escape there too
// (tests/objc/objc-regexec-test.sh).
#include <objc/runtime.h>
static void impA(id s, SEL c) { (void)s; (void)c; }
static volatile int sibcallAdded;
__attribute__((noinline)) void sibcall_trim(long a, long b, long c, long d, long e, long f, long g, unsigned *p) {
  __asm__ volatile("" : : "r"(a + b + c + d + e + f + g));
  *p = *p - 1;
}
__attribute__((noinline)) void sibcall_fwd(long a, long b, long c, long d, long e, long f, long g, unsigned *p) {
  if (a == 99) class_addMethod(objc_getClass("NSView"), sel_registerName("x"), (IMP)impA, "v16@0:8");
  sibcall_trim(a, b, c, d, e, f, g, p);
}
__attribute__((noinline)) void sibcall_root(void) {
  unsigned count = 2;
  Class cls;
  sibcall_fwd(1, 2, 3, 4, 5, 6, 7, &count);
  cls = objc_getClass("NSWindow");
  if (!cls) return;
  if (count == 2 && class_addMethod(cls, sel_registerName("fixtureA"), (IMP)impA, "v16@0:8")) sibcallAdded = 1;
}
__attribute__((constructor)) static void sibcall_start(void) { sibcall_root(); }
