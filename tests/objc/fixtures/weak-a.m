// A two-member provider, with tests/objc/fixtures/weak-b.m, whose members both define the weak protocol record
// __OBJC_PROTOCOL_$_NSObject: each has a class adopting <NSObject>, reached from its member's implementation, and the
// linker keeps one copy. This member holds the activation root, which registers -tabbingIdentifier (here) and
// -tabbingMode (weak-b.m) on NSWindow as table-provider.m registers its rows. Built with -fobjc-arc.
#import <Foundation/Foundation.h>
#include <objc/runtime.h>

typedef struct { const char *selector; const char *types; IMP imp; } FixtureWeakMethod;

@interface FixtureWeakA : NSObject <NSObject>
@end
@implementation FixtureWeakA
@end
extern char FixtureWeakAClass[] __asm__("_OBJC_CLASS_$_FixtureWeakA");

void *FixtureWeak_tabbingIdentifier(void *self, SEL _cmd) { (void)self; (void)_cmd; return FixtureWeakAClass; }
extern long FixtureWeak_tabbingMode(void *self, SEL _cmd);

const FixtureWeakMethod FixtureWeakMethods[] = {
  { "tabbingIdentifier", "@16@0:8", (IMP)(void *)FixtureWeak_tabbingIdentifier },
  { "tabbingMode", "q16@0:8", (IMP)(void *)FixtureWeak_tabbingMode },
};

typedef enum { FixtureNotRun, FixtureRegistered, FixturePartialRefused, FixtureAddFailed } FixtureState;
static FixtureState state = FixtureNotRun;

__attribute__((noinline)) static FixtureState FixtureWeakRegister(Class cls, const FixtureWeakMethod *table, size_t count) {
  for (size_t i = 0; i < count; ++i)
    if (class_getInstanceMethod(cls, sel_registerName(table[i].selector))) return FixturePartialRefused;
  for (size_t i = 0; i < count; ++i)
    if (!class_addMethod(cls, sel_registerName(table[i].selector), table[i].imp, table[i].types)) return FixtureAddFailed;
  return FixtureRegistered;
}

void __fixture_objc_activate_weak(void) {
  if (state != FixtureNotRun) return;
  Class window = objc_getClass("NSWindow");
  if (!window) { state = FixtureAddFailed; return; }
  state = FixtureWeakRegister(window, FixtureWeakMethods, sizeof FixtureWeakMethods / sizeof *FixtureWeakMethods);
}

#ifdef WEAK_TABLE
// The kept copy of a weak table tests/objc/fixtures/weak-table.m also defines, WEAK_TABLE longs; weak-b.m reads it.
__attribute__((weak, visibility("hidden"), section("__DATA,__fxweak"))) long FixtureWeakTable[WEAK_TABLE] = { 1 };
#endif

__attribute__((constructor)) static void fixture_weak_start(void) { __fixture_objc_activate_weak(); }
