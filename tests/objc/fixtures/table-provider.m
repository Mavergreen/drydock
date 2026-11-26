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
// loaded back from a frame array at an unknown index, for a helper), XCHG (an xchg swaps the two addresses),
// SHCL and SBBV (the state's address plus an unknown zero, rebuilt bit by bit through a shift count or the carry flag,
// for a helper), WALK_END (the register function walks the table by comparing a row pointer to its end) and PUSH_ARG
// (the row count, a local, trimmed by a helper that takes its address as a pushed eighth argument). VIEW_A11Y registers
// instead two rows of the newer SDK's NSAccessibility protocol, setAccessibilityLabel: and accessibilityLabel, on
// A11Y_CLASS (default NSView). SECOND has -tabbingIdentifier's implementation reach tests/objc/fixtures/table-second.m,
// which then links. ROOT_ALT gives the root an argument the constructor passes as 0, which otherwise chooses (1) a table
// with another tabbingMode implementation, (2) a copy of the table, (3) a call of a function nothing else calls, (4) a
// selector registered from it, (5) the state's address handed to a helper, or (6) a detail recorded. RERUN registers
// another row when the state says the table is registered: what a second call of the root would do. STATELESS has a root
// that keeps no state and stores nothing into the image, only registering the table; with it, ENTER_HELPER moves its
// objc_getClass into a function of its own, ROOT_ALT=7 records a mark when the class is missing and the argument is set,
// and ENTER_CTOR makes the constructor external.
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

#ifdef SECOND
extern int fixtureSecondInstalled;
void *FixtureTab_tabbingIdentifier(void *self, SEL _cmd) { (void)self; (void)_cmd; return &fixtureSecondInstalled; }
#else
void *FixtureTab_tabbingIdentifier(void *self, SEL _cmd) { (void)self; (void)_cmd; return 0; }
#endif
void FixtureTab_setTabbingIdentifier(void *self, SEL _cmd, void *ident) { (void)self; (void)_cmd; (void)ident; }
long FixtureTab_tabbingMode(void *self, SEL _cmd) { (void)self; (void)_cmd; return 0; }
void FixtureTab_setTabbingMode(void *self, SEL _cmd, long mode) { (void)self; (void)_cmd; (void)mode; }
static BOOL allowsAutomatic = YES;
BOOL FixtureTab_allowsAutomaticWindowTabbing(void *cls, SEL _cmd) { (void)cls; (void)_cmd; return allowsAutomatic; }
void FixtureTab_setAllowsAutomaticWindowTabbing(void *cls, SEL _cmd, BOOL allow) { (void)cls; (void)_cmd; allowsAutomatic = allow; }
void *FixtureTab_tabbedWindows(void *self, SEL _cmd) { (void)self; (void)_cmd; return 0; }
void *FixtureA11y_accessibilityLabel(void *self, SEL _cmd) { (void)self; (void)_cmd; return 0; }
void FixtureA11y_setAccessibilityLabel(void *self, SEL _cmd, void *label) { (void)self; (void)_cmd; (void)label; }

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

#ifdef VIEW_A11Y
#define TABLE_ROWS \
  ROW("setAccessibilityLabel:", "v24@0:8@16", NO, FixtureA11y_setAccessibilityLabel), \
  ROW("accessibilityLabel", "@16@0:8", NO, FixtureA11y_accessibilityLabel)
#ifndef A11Y_CLASS
#define A11Y_CLASS "NSView"
#endif
#define TABLE_CLASS A11Y_CLASS
#else
#define TABLE_ROWS SIX_ROWS
#define TABLE_CLASS "NSWindow"
#endif

#ifdef RUNTIME_WRITE
FixtureTabMethod FixtureTabMethods[] = { TABLE_ROWS };   // writable: the root patches a row before registering
#else
const FixtureTabMethod FixtureTabMethods[] = {
  TABLE_ROWS,
#ifdef EXTRA_ROW
  ROW("tabbedWindows", "@16@0:8", NO, FixtureTab_tabbedWindows),
#endif
#ifdef MANY
#define M(n) ROW("fixtureMany" #n, "v16@0:8", NO, FixtureTab_setTabbingMode)
  M(0), M(1), M(2), M(3), M(4), M(5), M(6), M(7), M(8), M(9), M(10), M(11), M(12), M(13), M(14), M(15), M(16), M(17),
#endif
};
#endif

#if ROOT_ALT == 1 || ROOT_ALT == 2
const FixtureTabMethod FixtureTabMethodsAlt[] = {
  ROW("tabbingIdentifier", "@16@0:8", NO, FixtureTab_tabbingIdentifier),
  ROW("setTabbingIdentifier:", "v24@0:8@16", NO, FixtureTab_setTabbingIdentifier),
#if ROOT_ALT == 1
  ROW("tabbingMode", "q16@0:8", NO, FixtureTab_tabbedWindows),
#else
  ROW("tabbingMode", "q16@0:8", NO, FixtureTab_tabbingMode),
#endif
  ROW("setTabbingMode:", "v24@0:8q16", NO, FixtureTab_setTabbingMode),
  ROW("allowsAutomaticWindowTabbing", "c16@0:8", YES, FixtureTab_allowsAutomaticWindowTabbing),
  ROW("setAllowsAutomaticWindowTabbing:", "v20@0:8c16", YES, FixtureTab_setAllowsAutomaticWindowTabbing)
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
#if defined(CMOV3) || defined(UNK_LOAD) || defined(XCHG) || defined(SHCL) || defined(SBBV)
__attribute__((noinline, used)) void fixture_bumpx(FixtureState *p) { *p = FixtureNativePresent; }
#endif
#if defined(CMOV3) || defined(XCHG)
FixtureState fixtureOther;
#endif
#ifdef CMOV3
static volatile int fixtureSel1 = 1;
#endif
#ifdef PUSH_ARG
__attribute__((noinline, used)) void fixture_trim(long a, long b, long c, long d, long e, long f, long g, size_t *rows) {
  __asm__ volatile("" : : "r"(a + b + c + d + e + f + g));
  *rows = *rows - 1;
}
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
#ifdef WALK_END
  for (const FixtureTabMethod *row = table, *end = table + count; row != end; ++row) {
    __asm__("" : "+r"(row));   // keeps the walk on the row pointer, not an index
    Class c = row->classMethod ? object_getClass(cls) : cls;
    if (!class_addMethod(c, sel_registerName(row->selector), row->imp, row->types)) {
      *detail = row->selector;
      return FixtureAddFailed;
    }
  }
#else
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
#endif
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

#if ROOT_ALT == 3
__attribute__((noinline, used)) void fixture_alt_extra(void) { (void)objc_getClass("NSObject"); }
#elif ROOT_ALT == 5
__attribute__((noinline, used)) void fixture_alt_note(const void *p) { __asm__ volatile("" : : "r"(p)); }
#endif
#ifdef STATELESS
#ifdef ENTER_HELPER
__attribute__((noinline, used)) Class fixture_tab_class(void) { return objc_getClass(TABLE_CLASS); }
#else
#define fixture_tab_class() objc_getClass(TABLE_CLASS)
#endif
#if ROOT_ALT == 7
int fixtureMark;
#endif
#ifdef ROOT_ALT
__attribute__((noinline)) void __fixture_objc_activate_table(int alt) {
  (void)alt;
#else
void __fixture_objc_activate_table(void) {
#endif
  const char *d;
  Class window = fixture_tab_class();
  if (!window) {
#if ROOT_ALT == 7
    if (alt) fixtureMark = 1;
#endif
    return;
  }
  (void)REGISTER(window, FixtureTabMethods, sizeof FixtureTabMethods / sizeof *FixtureTabMethods, &d);
}
#else
#ifdef RERUN
const FixtureTabMethod FixtureTabMethodsRerun[] = { ROW("fixtureRerunExtra", "@16@0:8", NO, FixtureTab_tabbedWindows) };
#endif
#ifdef ROOT_ALT
__attribute__((noinline)) void __fixture_objc_activate_table(int alt) {
#if ROOT_ALT == 1 || ROOT_ALT == 2
#define TABLE (alt ? FixtureTabMethodsAlt : FixtureTabMethods)
#else
#define TABLE FixtureTabMethods
#endif
#else
void __fixture_objc_activate_table(void) {
#define TABLE FixtureTabMethods
#endif
#ifdef RERUN
  if (state == FixtureRegistered) {
    const char *d;
    REGISTER(objc_getClass("NSWindow"), FixtureTabMethodsRerun, 1, &d);
    return;
  }
#endif
  if (state != FixtureNotRun) return;
#if ROOT_ALT == 3
  if (alt) fixture_alt_extra();
#elif ROOT_ALT == 4
  (void)sel_registerName(alt ? (const char *)(intptr_t)alt : "fixtureAltLiteral");
#elif ROOT_ALT == 5
  {
    FixtureState *sp = &state;
    __asm__ volatile("" : "+r"(sp));   // the address taken on every path; only handed on when alt is set
    if (alt) fixture_alt_note(sp);
  }
#elif ROOT_ALT == 6
  if (alt) stateDetail = "alt";
#endif
  Class window = objc_getClass(TABLE_CLASS);
#ifndef NULL_CLASS
  if (!window) { state = FixtureAddFailed; stateDetail = TABLE_CLASS; return; }
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
#if defined(SHCL) || defined(SBBV)
  {
    FixtureState *p; void *sp_ = &state;
    unsigned long z = arc4random_uniform(1);
    __asm__ volatile(
      "addq %%rdx, %%rsi\n\t"
      "xorl %%edi, %%edi\n\t"
      "xorl %%r9d, %%r9d\n"
      "1:\n\t"
      "movq %%r9, %%rcx\n\t"
      "movq %%rsi, %%rax\n\t"
      "shrq %%cl, %%rax\n\t"
      "andl $1, %%eax\n\t"
#if defined(SHCL)
      "movl %%eax, %%ecx\n\t"
      "movl $1, %%r8d\n\t"
      "shlq %%cl, %%r8\n\t"
      "decq %%r8\n\t"
      "movq %%r9, %%rcx\n\t"
#else
      "movl $0, %%r8d\n\t"
      "cmpq $1, %%rax\n\t"
      "sbbq %%r8, %%r8\n\t"
      "incq %%r8\n\t"
#endif
      "shlq %%cl, %%r8\n\t"
      "orq %%r8, %%rdi\n\t"
      "incq %%r9\n\t"
      "cmpq $64, %%r9\n\t"
      "jne 1b\n\t"
      "xorl %%esi, %%esi\n\t"
      "xorl %%eax, %%eax\n\t"
      "xorl %%ecx, %%ecx\n\t"
      "xorl %%edx, %%edx\n\t"
      "xorl %%r8d, %%r8d\n\t"
      "xorl %%r9d, %%r9d\n\t"
      : "=D"(p), "+S"(sp_), "+d"(z) : : "rax", "rcx", "r8", "r9", "memory");
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
#ifdef PUSH_ARG
  size_t rows = sizeof FixtureTabMethods / sizeof *FixtureTabMethods;
  fixture_trim(1, 2, 3, 4, 5, 6, 7, &rows);
#define ROWS rows
#else
#define ROWS (sizeof FixtureTabMethods / sizeof *FixtureTabMethods)
#endif
#ifdef TRY
  @try {
    state = REGISTER(window, TABLE, ROWS, &stateDetail);
  } @catch (id e) {
    state = FixtureAddFailed;
  }
#else
  state = REGISTER(window, TABLE, ROWS, &stateDetail);
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
#endif

FixtureState fixture_tabbing_activation_state(const char **detail) {
  if (detail) *detail = stateDetail;
  return state;
}

#ifdef ROOT_ALT
__attribute__((constructor)) static void fixture_tabbing_start(void) { __fixture_objc_activate_table(0); }
#elif defined(ENTER_CTOR)
__attribute__((constructor)) void fixture_tabbing_start(void) { __fixture_objc_activate_table(); }
#else
__attribute__((constructor)) static void fixture_tabbing_start(void) { __fixture_objc_activate_table(); }
#endif
#ifdef TWO_INIT
__attribute__((used, section("__DATA,__mod_init_func,mod_init_funcs"))) static void (*const fixtureSecondInit)(void) =
    fixture_tabbing_start;
#endif
