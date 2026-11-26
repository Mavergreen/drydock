// The second member of tests/objc/fixtures/weak-a.m's provider: a class adopting <NSObject>, so this object defines
// the weak __OBJC_PROTOCOL_$_NSObject too, and -tabbingMode's implementation, which reaches that class.
#import <Foundation/Foundation.h>

@interface FixtureWeakB : NSObject <NSObject>
@end
@implementation FixtureWeakB
@end
extern char FixtureWeakBClass[] __asm__("_OBJC_CLASS_$_FixtureWeakB");

#ifdef WEAK_TABLE
// The long at index WEAK_READ of weak-a.m's FixtureWeakTable, reached through the symbol this member does not define.
extern long FixtureWeakTable[] __attribute__((visibility("hidden")));
long FixtureWeak_tabbingMode(void *self, SEL _cmd) { (void)self; (void)_cmd; return (long)FixtureWeakBClass + FixtureWeakTable[WEAK_READ]; }
#else
long FixtureWeak_tabbingMode(void *self, SEL _cmd) { (void)self; (void)_cmd; return (long)FixtureWeakBClass; }
#endif
