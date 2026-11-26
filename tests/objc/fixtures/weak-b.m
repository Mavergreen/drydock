// The second member of tests/objc/fixtures/weak-a.m's provider: a class adopting <NSObject>, so this object defines
// the weak __OBJC_PROTOCOL_$_NSObject too, and -tabbingMode's implementation, which reaches that class.
#import <Foundation/Foundation.h>

@interface FixtureWeakB : NSObject <NSObject>
@end
@implementation FixtureWeakB
@end
extern char FixtureWeakBClass[] __asm__("_OBJC_CLASS_$_FixtureWeakB");

long FixtureWeak_tabbingMode(void *self, SEL _cmd) { (void)self; (void)_cmd; return (long)FixtureWeakBClass; }
