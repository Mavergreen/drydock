// A second unit of tests/objc/fixtures/table-provider.m's group, in the shape of Recaulk's RecaulkTabWindowLink.m: its own
// initializer calls the root first, then does its own work, so the order dyld runs the two initializers in does not
// matter. table-provider.m built with -DSECOND reaches it from an IMP, so linking the group links this too. PAST_ENTRY
// calls into the root past its entry instead; ROOT_POINTER keeps a pointer to the root in data as well; ROOT_ALT calls
// the root as table-provider.m's ROOT_ALT declares it, with an argument the root's own constructor never passes.
#include <stdint.h>

int fixtureSecondInstalled;

#if defined(ROOT_ALT)
extern void __fixture_objc_activate_table(int alt);
#else
extern void __fixture_objc_activate_table(void);
#endif

#ifdef ROOT_POINTER
__attribute__((used)) void (*const volatile fixtureRootPointer)(void) = __fixture_objc_activate_table;
#endif

__attribute__((constructor)) static void fixture_second_start(void) {
#if defined(PAST_ENTRY)
  __asm__ volatile("callq ___fixture_objc_activate_table+4" : : : "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "memory", "cc");
#elif defined(ROOT_ALT)
  __fixture_objc_activate_table(1);
#else
  __fixture_objc_activate_table();
#endif
  fixtureSecondInstalled = 1;
}
