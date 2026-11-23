// A frame local's address passed as a pushed stack argument (the eighth) to a helper the executor does not follow,
// which changes it: the add after it depends on a value the executor cannot know (tests/objc/objc-regexec-test.sh).
#include <objc/runtime.h>
static void impA(id s, SEL c) { (void)s; (void)c; }
static volatile int pushargAdded;
__attribute__((noinline)) void pusharg_trim(long a, long b, long c, long d, long e, long f, long g, unsigned *p) {
  __asm__ volatile("" : : "r"(a + b + c + d + e + f + g));
  *p = *p - 1;
}
__attribute__((noinline)) void pusharg_root(void) {
  unsigned count = 2;
  Class cls;
  pusharg_trim(1, 2, 3, 4, 5, 6, 7, &count);
  cls = objc_getClass("NSWindow");
  if (!cls) return;
  if (count == 2 && class_addMethod(cls, sel_registerName("fixtureA"), (IMP)impA, "v16@0:8")) pushargAdded = 1;
}
__attribute__((constructor)) static void pusharg_start(void) { pusharg_root(); }
