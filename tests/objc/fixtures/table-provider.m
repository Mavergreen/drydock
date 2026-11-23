// A table provider in the shape of Recaulk's NSWindow tabbing provider (RecaulkTabActivation.m, RecaulkTabAPI.m), in
// miniature: a const table of rows, an absent-only register function walked by its base and count, a root guarded by
// a state global, and a constructor calling the root. Built with -fobjc-arc, as Recaulk's tabbing units are.
// Each -D variant (REORDER, SHORT, NOGUARD, NOPARTIAL, RUNTIME_WRITE, INDIRECT, VIA_MSGSEND, SETIMP, EXTRA_ROW, WRONG_IMP,
// WRONG_TYPES, KIND_SWAP, MANY, FRAME_ESCAPE) is a mutant tests/objc/objc-regexec-test.sh names; tests/objc/objc-provider-test.sh
// names NULL_CLASS (the table registered on objc_getClass's NULL too), OTHER_NULL (the last three rows only when another
// class exists), UNRELATED_EARLY (nothing registered when an unrelated method is found), FAIL_EXTRA (an undeclared add
// after a failed one), GUESSED (a branch on an unknown value before registering), TRAPPED (a trap after registering),
// COMPUTED_SEL (a selector registered from a run-time string), ESCAPE (a function no path runs takes the table's
// address), READ_TABLE (one only reads the table and the state), UNEXPLORED_SEL (a run-time string registered in
// a method reached only by a message send), BUMP (the state's address handed to a helper no path follows, which
// writes it), PASS_TABLE (the table's address handed to one), CFG_PTR (a pointer the root reads, to a field it reads,
// written through by a function no path runs), PRUNED_WRITE (a state write on a branch no path takes), PRUNED_CALL
// (class_addMethod's GOT slot loaded on an explored path, called through a register on a branch no path takes), TRY
// (the root catches exceptions), BOUND_ADD (class_addMethod through a bound data pointer, in a method reached only by
// a message send), TWO_INIT (the constructor in the initializer table twice), UNK_OFF (the state's address plus an
// unknown offset handed to a helper), ADJ (the address of a global next to one the root reads, handed to a helper)
// MANY_ARGS (the state's address as a helper's fifteenth argument, on the stack), CLS_FIELD (the root branches on its
// own class object's isa), CLS_RO (on a field of its class's read-only data, in __objc_const), CMOV3 (a cmov,
// its flags known, selects the state's address over another global's for a helper), UNK_LOAD (the state's address
// loaded back from a frame array at an unknown index, for a helper) and XCHG (an xchg swaps the two addresses).
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

#ifdef BUMP
__attribute__((noinline, used)) void fixture_bump(FixtureState *p) { *p = FixtureNativePresent; }
#endif
#ifdef UNK_OFF
__attribute__((noinline, used)) void fixture_bumpu(FixtureState *p) { *p = FixtureNativePresent; }
#endif
#ifdef ADJ
int fixtureA = 1;
int fixtureB = 2;
__attribute__((noinline, used)) void fixture_bumpl(int *p) { *p = 3; }
#endif
#ifdef MANY_ARGS
__attribute__((noinline, used)) void fixture_many(long a, long b, long c, long d, long e, long f, long g, long h, long i,
                                                  long j, long k, long l, long m, long n, FixtureState *p) {
  *p = FixtureNativePresent;
  __asm__ volatile("" : : "r"(a + b + c + d + e + f + g + h + i + j + k + l + m + n));
}
#endif
#if defined(CMOV3) || defined(UNK_LOAD) || defined(XCHG)
__attribute__((noinline, used)) void fixture_bumpx(FixtureState *p) { *p = FixtureNativePresent; }
#endif
#if defined(CMOV3) || defined(XCHG)
FixtureState fixtureOther;
#endif
#ifdef CMOV3
static volatile int fixtureSel1 = 1;
#endif
#ifdef PASS_TABLE
__attribute__((noinline, used)) void fixture_note(const void *p) { __asm__ volatile("" : : "r"(p)); }
#endif
#ifdef CFG_PTR
int fixture_cfg_field;
int *fixture_cfgp = &fixture_cfg_field;
__attribute__((used)) void fixture_cfg_set(void) { *fixture_cfgp = 1; }
#endif
#if defined(PRUNED_WRITE) || defined(PRUNED_CALL)
static volatile int fixturePruned;   // reads 0 on every path: what it guards is never run
#endif
#ifdef BOUND_ADD
static BOOL (*const volatile fixtureAdd)(Class, SEL, IMP, const char *) = class_addMethod;
@interface FixtureTabBound : NSObject
+ (void)addExtra:(Class)cls;
@end
@implementation FixtureTabBound
+ (void)addExtra:(Class)cls {
  fixtureAdd(cls, sel_registerName("tabbedWindows"), (IMP)(void *)FixtureTab_tabbedWindows, "@16@0:8");
}
@end
#endif

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
#ifdef OTHER_NULL
    if (i == 3 && !objc_getClass("NSPanel")) break;
#endif
    Class c = table[i].classMethod ? object_getClass(cls) : cls;
    if (!class_addMethod(c, sel_registerName(table[i].selector), table[i].imp, table[i].types)) {
#ifdef FAIL_EXTRA
      class_addMethod(cls, sel_registerName("fixtureUndeclared"), table[i].imp, table[i].types);
#endif
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

#if defined(CLS_FIELD) || defined(CLS_RO)
@interface FixtureTabOwn : NSObject
@end
@implementation FixtureTabOwn
@end
extern char FixtureTabOwnClass[] __asm__("_OBJC_CLASS_$_FixtureTabOwn");
#endif

#ifdef UNEXPLORED_SEL
@interface FixtureTabSel : NSObject
+ (void)touch:(const char *)name;
@end
@implementation FixtureTabSel
+ (void)touch:(const char *)name { (void)sel_registerName(name); }
@end
#endif

#ifdef ESCAPE
__attribute__((used)) const FixtureTabMethod *fixture_tab_rows(void) { return FixtureTabMethods; }
#endif
#ifdef READ_TABLE
__attribute__((used)) BOOL fixture_tab_reads(void) {
  return *(const volatile BOOL *)&FixtureTabMethods[4].classMethod && *(volatile FixtureState *)&state == FixtureRegistered;
}
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
#ifndef NULL_CLASS
  if (!window) { state = FixtureAddFailed; stateDetail = "NSWindow"; return; }
#endif
#ifdef BUMP
  fixture_bump(&state);
  if (state != FixtureNotRun) return;
#endif
#ifdef PASS_TABLE
  fixture_note(FixtureTabMethods);
#endif
#ifdef CLS_FIELD
  if (!((void *volatile *)FixtureTabOwnClass)[0]) return;
#endif
#ifdef CLS_RO
  if (((const volatile uint32_t *)((void *const *)FixtureTabOwnClass)[4])[1] == 0x7fffffff) return;
#endif
#ifdef CMOV3
  {
    FixtureState *p = fixtureSel1 ? &state : &fixtureOther;
    fixture_bumpx(p);
    if (state != FixtureNotRun) return;
  }
#endif
#ifdef UNK_LOAD
  {
    FixtureState *volatile arr[2];
    unsigned ui = arc4random_uniform(1);
    arr[0] = &state; arr[1] = 0;
    FixtureState *p = arr[ui];
    arr[0] = 0; arr[1] = 0;
    fixture_bumpx(p);
    if (state != FixtureNotRun) return;
  }
#endif
#ifdef XCHG
  {
    FixtureState *p = &fixtureOther, *q = &state;
    __asm__ volatile(".byte 0x48, 0x87, 0xf8" : "+D"(p), "+a"(q));   // xchgq: reg rdi, r/m rax
    fixture_bumpx(p);
    if (state != FixtureNotRun) return;
  }
#endif
#ifdef UNK_OFF
  fixture_bumpu((FixtureState *)((char *)&state + arc4random_uniform(1)));
  if (state != FixtureNotRun) return;
#endif
#ifdef ADJ
  if (fixtureA != 1) return;
  fixture_bumpl(&fixtureB);
  if (fixtureB != 2) return;
#endif
#ifdef MANY_ARGS
  fixture_many(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, &state);
  if (state != FixtureNotRun) return;
#endif
#ifdef CFG_PTR
  if (*fixture_cfgp) return;
#endif
#ifdef PRUNED_WRITE
  if (fixturePruned) state = FixtureNativePresent;
#endif
#ifdef PRUNED_CALL
  __asm__ volatile("movq _class_addMethod@GOTPCREL(%%rip), %%rbx\n\t"
                   "cmpl $0, %0\n\t"
                   "je 1f\n\t"
                   "call *%%rbx\n"
                   "1:"
                   : : "m"(fixturePruned) : "rbx", "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "memory", "cc");
#endif
#ifdef FRAME_ESCAPE
  Class held = window;
  arc4random_buf(&held, 0);   // an import given a frame address: what it held may have changed
  window = held;
#endif
#ifdef RUNTIME_WRITE
  FixtureTabMethods[2].imp = (IMP)(void *)FixtureTab_tabbedWindows;
#endif
#ifdef UNRELATED_EARLY
  if (class_getInstanceMethod(window, sel_registerName("fixtureUnrelated"))) return;
#endif
#ifdef GUESSED
  if (arc4random() == 7) stateDetail = "seven";
#endif
#ifdef COMPUTED_SEL
  (void)sel_registerName(getenv("FIXTURE_SEL"));
#endif
#ifdef TRY
  @try {
    state = REGISTER(window, FixtureTabMethods, sizeof FixtureTabMethods / sizeof *FixtureTabMethods, &stateDetail);
  } @catch (id e) {
    state = FixtureAddFailed;
  }
#else
  state = REGISTER(window, FixtureTabMethods, sizeof FixtureTabMethods / sizeof *FixtureTabMethods, &stateDetail);
#endif
#ifdef TRAPPED
  __builtin_trap();
#endif
#ifdef VIA_MSGSEND
  if (state == FixtureRegistered) [FixtureTabExtra addExtra:window];
#endif
#ifdef UNEXPLORED_SEL
  if (state == FixtureRegistered) [FixtureTabSel touch:getenv("FIXTURE_SEL")];
#endif
#ifdef BOUND_ADD
  if (state == FixtureRegistered) [FixtureTabBound addExtra:window];
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
#ifdef TWO_INIT
__attribute__((used, section("__DATA,__mod_init_func,mod_init_funcs"))) static void (*const fixtureSecondInit)(void) =
    fixture_tabbing_start;
#endif
