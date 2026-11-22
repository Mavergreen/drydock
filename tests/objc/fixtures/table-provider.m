// A table provider in the shape of Recaulk's NSWindow tabbing provider (RecaulkTabActivation.m, RecaulkTabAPI.m), in
// miniature: a const table of rows, an absent-only register function walked by its base and count, a root guarded by
// a state global, and a constructor calling the root. Built with -fobjc-arc, as Recaulk's tabbing units are.
// Each -D variant (REORDER, SHORT, NOGUARD, NOPARTIAL, RUNTIME_WRITE, INDIRECT, VIA_MSGSEND, SETIMP, EXTRA_ROW, WRONG_IMP,
// WRONG_TYPES, KIND_SWAP, MANY, FRAME_ESCAPE) is a mutant tests/objc/objc-regexec-test.sh names.
#import <Foundation/Foundation.h>
#include <objc/runtime.h>
#include <stdlib.h>

#ifdef REORDER
typedef struct { IMP imp; BOOL classMethod; const char *types; const char *selector; } FixtureTabMethod;
#define ROW(s, t, c, i) { (IMP)(void *)(i), c, t, s }
#else
typedef struct { const char *selector; const char *types; BOOL classMethod; IMP imp; } FixtureTabMethod;
#define ROW(s, t, c, i) { s, t, c, (IMP)(void *)(i) }
#endif

void *FixtureTab_tabbingIdentifier(void *self, SEL _cmd) { (void)self; (void)_cmd; return 0; }
void FixtureTab_setTabbingIdentifier(void *self, SEL _cmd, void *ident) { (void)self; (void)_cmd; (void)ident; }
long FixtureTab_tabbingMode(void *self, SEL _cmd) { (void)self; (void)_cmd; return 0; }
void FixtureTab_setTabbingMode(void *self, SEL _cmd, long mode) { (void)self; (void)_cmd; (void)mode; }
static BOOL allowsAutomatic = YES;
BOOL FixtureTab_allowsAutomaticWindowTabbing(void *cls, SEL _cmd) { (void)cls; (void)_cmd; return allowsAutomatic; }
void FixtureTab_setAllowsAutomaticWindowTabbing(void *cls, SEL _cmd, BOOL allow) { (void)cls; (void)_cmd; allowsAutomatic = allow; }
void *FixtureTab_tabbedWindows(void *self, SEL _cmd) { (void)self; (void)_cmd; return 0; }

#ifdef WRONG_IMP
#define MODE_IMP FixtureTab_tabbedWindows
#else
#define MODE_IMP FixtureTab_tabbingMode
#endif
#ifdef WRONG_TYPES
#define MODE_TYPES "i16@0:8"
#else
#define MODE_TYPES "q16@0:8"
#endif
#ifdef KIND_SWAP
#define SET_ALLOWS_KIND NO
#else
#define SET_ALLOWS_KIND YES
#endif

#define SIX_ROWS \
  ROW("tabbingIdentifier", "@16@0:8", NO, FixtureTab_tabbingIdentifier), \
  ROW("setTabbingIdentifier:", "v24@0:8@16", NO, FixtureTab_setTabbingIdentifier), \
  ROW("tabbingMode", MODE_TYPES, NO, MODE_IMP), \
  ROW("setTabbingMode:", "v24@0:8q16", NO, FixtureTab_setTabbingMode), \
  ROW("allowsAutomaticWindowTabbing", "c16@0:8", YES, FixtureTab_allowsAutomaticWindowTabbing), \
  ROW("setAllowsAutomaticWindowTabbing:", "v20@0:8c16", SET_ALLOWS_KIND, FixtureTab_setAllowsAutomaticWindowTabbing)

#ifdef RUNTIME_WRITE
FixtureTabMethod FixtureTabMethods[] = { SIX_ROWS };   // writable: the root patches a row before registering
#else
const FixtureTabMethod FixtureTabMethods[] = {
  SIX_ROWS,
#ifdef EXTRA_ROW
  ROW("tabbedWindows", "@16@0:8", NO, FixtureTab_tabbedWindows),
#endif
#ifdef MANY
#define M(n) ROW("fixtureMany" #n, "v16@0:8", NO, FixtureTab_setTabbingMode)
  M(0), M(1), M(2), M(3), M(4), M(5), M(6), M(7), M(8), M(9), M(10), M(11), M(12), M(13), M(14), M(15), M(16), M(17),
#endif
};
#endif

typedef enum { FixtureNotRun, FixtureRegistered, FixtureNativePresent, FixturePartialRefused, FixtureAddFailed } FixtureState;
static FixtureState state = FixtureNotRun;
static const char *stateDetail;

static BOOL ownsSelector(Class c, SEL sel) { return class_getInstanceMethod(c, sel) != NULL; }

__attribute__((noinline)) FixtureState FixtureTabRegisterTable(Class cls, const FixtureTabMethod *table, size_t count,
                                                                const char **detail) {
  size_t present = 0;
  for (size_t i = 0; i < count; ++i) {
    Class c = table[i].classMethod ? object_getClass(cls) : cls;
    if (ownsSelector(c, sel_registerName(table[i].selector))) ++present;
  }
  *detail = NULL;
#ifdef NOGUARD
  (void)present;
#else
  if (present == count) return FixtureNativePresent;
#ifndef NOPARTIAL
  if (present) return FixturePartialRefused;
#endif
#endif
#ifdef SHORT
  count -= 1;
#endif
  for (size_t i = 0; i < count; ++i) {
    Class c = table[i].classMethod ? object_getClass(cls) : cls;
    if (!class_addMethod(c, sel_registerName(table[i].selector), table[i].imp, table[i].types)) {
      *detail = table[i].selector;
      return FixtureAddFailed;
    }
  }
  return FixtureRegistered;
}

#ifdef VIA_MSGSEND
@interface FixtureTabExtra : NSObject
+ (void)addExtra:(Class)cls;
@end
@implementation FixtureTabExtra
+ (void)addExtra:(Class)cls {
  class_addMethod(cls, sel_registerName("tabbedWindows"), (IMP)(void *)FixtureTab_tabbedWindows, "@16@0:8");
}
@end
#endif

#ifdef INDIRECT
FixtureState (*volatile FixtureTabRegister)(Class, const FixtureTabMethod *, size_t, const char **) = FixtureTabRegisterTable;
#define REGISTER FixtureTabRegister
#else
#define REGISTER FixtureTabRegisterTable
#endif

void __fixture_objc_activate_table(void) {
  if (state != FixtureNotRun) return;
  Class window = objc_getClass("NSWindow");
  if (!window) { state = FixtureAddFailed; stateDetail = "NSWindow"; return; }
#ifdef FRAME_ESCAPE
  Class held = window;
  arc4random_buf(&held, 0);   // an import given a frame address: what it held may have changed
  window = held;
#endif
#ifdef RUNTIME_WRITE
  FixtureTabMethods[2].imp = (IMP)(void *)FixtureTab_tabbedWindows;
#endif
  state = REGISTER(window, FixtureTabMethods, sizeof FixtureTabMethods / sizeof *FixtureTabMethods, &stateDetail);
#ifdef VIA_MSGSEND
  if (state == FixtureRegistered) [FixtureTabExtra addExtra:window];
#endif
#ifdef SETIMP
  if (state == FixtureRegistered)
    method_setImplementation(class_getInstanceMethod(window, sel_registerName("tabbingMode")),
                             (IMP)(void *)FixtureTab_tabbedWindows);
#endif
}

FixtureState fixture_tabbing_activation_state(const char **detail) {
  if (detail) *detail = stateDetail;
  return state;
}

__attribute__((constructor)) static void fixture_tabbing_start(void) { __fixture_objc_activate_table(); }
