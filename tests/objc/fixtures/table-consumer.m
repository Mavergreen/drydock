/* Fixture: a consumer of tests/objc/fixtures/table-provider.m's six NSWindow tabbing methods (10.12), sending each
 * as declared -- four to an NSWindow instance, two to the class -- and naming no provider symbol. KIND_CROSS sends
 * instead one instance member to the class and one class member to an instance; COMPUTED_SEL also registers a
 * selector named by its argument, outside any provider; CALL_REGISTER calls the provider's FixtureTabRegisterTable
 * with a table of its own; VIEW_A11Y sends instead the newer SDK's -setAccessibilityLabel: and -accessibilityLabel
 * (NSAccessibility protocol) to an NSButton, an NSControl. BRIDGE calls tests/objc/fixtures/bridge-provider.m's
 * FixtureBridge(cls) with FixtureBridgedView, an NSView, and FixtureBridgedCell, an NSActionCell, each implementing
 * -accessibilityRole: an objc_getClass literal and a +class result each, one of the four a tail jump from
 * bridgeCell. With BRIDGE, BRIDGE_COMPUTED adds FixtureBridge([c class]), c a send's result; BRIDGE_NOT_OWN adds NSButton;
 * BRIDGE_OWN_MEMBER has FixtureBridgedView implement -accessibilityIsIgnored too; BRIDGE_ANCESTOR_MEMBER adds
 * FixtureBridgedSub, under a FixtureBridgedBase : NSView implementing -accessibilityAttributeNames; BRIDGE_ROOTLESS
 * adds FixtureBridgedRoot, a root class; BRIDGE_POINTER adds a call through a function pointer; BRIDGE_UNUSED makes
 * no call at all; BRIDGE_CELL_LACKS leaves -accessibilityRole off FixtureBridgedCell. Built for x86_64 against the
 * pinned 10.9 SDK (MRC); read as bytes, never executed. */
#import <AppKit/AppKit.h>
#include <objc/runtime.h>

@interface NSWindow (LaterTabbing)
- (NSString *)tabbingIdentifier;
- (void)setTabbingIdentifier:(NSString *)identifier;
- (NSInteger)tabbingMode;
- (void)setTabbingMode:(NSInteger)mode;
+ (BOOL)allowsAutomaticWindowTabbing;
+ (void)setAllowsAutomaticWindowTabbing:(BOOL)allow;
#ifdef KIND_CROSS
+ (NSInteger)tabbingMode;
- (BOOL)allowsAutomaticWindowTabbing;
#endif
@end

#ifdef VIEW_A11Y
@interface NSView (LaterAccessibility)
- (void)setAccessibilityLabel:(NSString *)label;
- (NSString *)accessibilityLabel;
@end
#endif

#ifdef BRIDGE
extern void FixtureBridge(Class cls);
@interface FixtureBridgedView : NSView
@end
@implementation FixtureBridgedView
- (id)accessibilityRole { return nil; }
#ifdef BRIDGE_OWN_MEMBER
- (BOOL)accessibilityIsIgnored { return NO; }
#endif
@end
@interface FixtureBridgedCell : NSActionCell
@end
@implementation FixtureBridgedCell
#ifndef BRIDGE_CELL_LACKS
- (id)accessibilityRole { return nil; }
#endif
@end
#ifdef BRIDGE_ANCESTOR_MEMBER
@interface FixtureBridgedBase : NSView
@end
@implementation FixtureBridgedBase
- (NSArray *)accessibilityAttributeNames { return nil; }
@end
@interface FixtureBridgedSub : FixtureBridgedBase
@end
@implementation FixtureBridgedSub
- (id)accessibilityRole { return nil; }
@end
#endif
#ifdef BRIDGE_ROOTLESS
__attribute__((objc_root_class))
@interface FixtureBridgedRoot { Class isa; }
@end
@implementation FixtureBridgedRoot
- (id)accessibilityRole { return nil; }
@end
#endif
#ifndef BRIDGE_UNUSED
__attribute__((noinline)) static void bridgeCell(void) { FixtureBridge(objc_getClass("FixtureBridgedCell")); }
#endif
#endif

#ifdef CALL_REGISTER
typedef struct { const char *selector; const char *types; BOOL classMethod; IMP imp; } ConsumerTabMethod;
extern int FixtureTabRegisterTable(Class cls, const ConsumerTabMethod *table, size_t count, const char **detail);
static void consumerAdded(id self, SEL _cmd) { (void)self; (void)_cmd; }
static const ConsumerTabMethod consumerRows[] = { { "fixtureConsumerAdded", "v16@0:8", NO, (IMP)consumerAdded } };
#endif

int main(int argc, char **argv) {
    if (argc > 99) {
#if defined(BRIDGE) && !defined(BRIDGE_UNUSED)
        FixtureBridge(objc_getClass("FixtureBridgedView"));
        FixtureBridge([FixtureBridgedView class]);
        FixtureBridge([FixtureBridgedCell class]);
        bridgeCell();
#ifdef BRIDGE_COMPUTED
        FixtureBridge([[NSApplication sharedApplication] class]);
#endif
#ifdef BRIDGE_NOT_OWN
        FixtureBridge(objc_getClass("NSButton"));
#endif
#ifdef BRIDGE_ANCESTOR_MEMBER
        FixtureBridge(objc_getClass("FixtureBridgedSub"));
#endif
#ifdef BRIDGE_ROOTLESS
        FixtureBridge(objc_getClass("FixtureBridgedRoot"));
#endif
#ifdef BRIDGE_POINTER
        {
            void (*volatile bridge)(Class) = FixtureBridge;
            bridge(objc_getClass("FixtureBridgedView"));
        }
#endif
#endif
#ifdef CALL_REGISTER
        const char *detail;
        if (FixtureTabRegisterTable(objc_getClass("NSWindow"), consumerRows, 1, &detail) != 1) return 3;
#endif
#ifdef COMPUTED_SEL
        if (sel_registerName(argv[1]) == NULL) return 2;
#endif
        NSWindow *w = [[NSApplication sharedApplication] keyWindow];
#if defined(VIEW_A11Y)
        NSButton *c = [w standardWindowButton:NSWindowCloseButton];
        [c setAccessibilityLabel:@"fixture"];
        return [c accessibilityLabel] != nil;
#elif defined(KIND_CROSS)
        return (int)[NSWindow tabbingMode] + [w allowsAutomaticWindowTabbing];
#else
        [w setTabbingIdentifier:@"fixture"];
        [w setTabbingMode:[w tabbingMode]];
        [NSWindow setAllowsAutomaticWindowTabbing:![NSWindow allowsAutomaticWindowTabbing]];
        return [w tabbingIdentifier] != nil;
#endif
    }
    return 0;
}
