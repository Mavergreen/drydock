// class_addMethod results read or discarded, one shape per variant (TEN, CHECKED, COPIED, PARTIAL, HELPER, TAIL, NULLCLS),
// each entered at lazy_start with rdi bound to a class (tests/objc/objc-regexec-test.sh).
#include <objc/runtime.h>
#include <unistd.h>
static void impA(id s, SEL c) { (void)s; (void)c; }
static volatile int lazySink;
#define ADD(c, s) class_addMethod((c), sel_registerName(s), (IMP)impA, "v16@0:8")
#ifdef TEN
void lazy_start(Class cls) {
  if (getpid() & 1) lazySink = 1;
  ADD(cls, "a0"); ADD(cls, "a1"); ADD(cls, "a2"); ADD(cls, "a3"); ADD(cls, "a4");
  ADD(cls, "a5"); ADD(cls, "a6"); ADD(cls, "a7"); ADD(cls, "a8"); ADD(cls, "a9");
  (void)getpid();
}
#endif
#ifdef CHECKED
void lazy_start(Class cls) {
  if (!ADD(cls, "c0")) ADD(cls, "c1");
  (void)getpid();
}
#endif
#ifdef COPIED
void lazy_start(Class cls) {
  volatile BOOL r = ADD(cls, "p0");
  ADD(cls, "p1");
  if (!r) lazySink = 1;
  (void)getpid();
}
#endif
#ifdef PARTIAL
void lazy_start(Class cls) {
  BOOL b = ADD(cls, "b0");
  if (b) lazySink = 2;
  (void)getpid();
}
#endif
#ifdef HELPER
__attribute__((noinline)) BOOL lazy_add(Class c) { return ADD(c, "h0"); }
void lazy_start(Class cls) {
  if (!lazy_add(cls)) lazySink = 3;
  (void)getpid();
}
#endif
#ifdef TAIL
BOOL lazy_start(Class cls) {
  if (getpid() & 1) lazySink = 1;
  return ADD(cls, "t0");
}
#endif
#ifdef NULLCLS
void lazy_start(Class cls) {
  (void)cls;
  ADD(objc_getClass("NSView"), "n0");
  (void)getpid();
}
#endif
