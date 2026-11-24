/* Fixture: a consumer of tests/objc/fixtures/table-provider.m's six NSWindow tabbing methods (10.12), sending each
 * as declared -- four to an NSWindow instance, two to the class -- and naming no provider symbol. KIND_CROSS sends
 * instead one instance member to the class and one class member to an instance; COMPUTED_SEL also registers a
 * selector named by its argument, outside any provider; CALL_REGISTER calls the provider's FixtureTabRegisterTable
 * with a table of its own; VIEW_A11Y sends instead the newer SDK's -setAccessibilityLabel: and -accessibilityLabel
 * (NSAccessibility protocol) to an NSButton, an NSControl. Built for x86_64 against the
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

#ifdef CALL_REGISTER
typedef struct { const char *selector; const char *types; BOOL classMethod; IMP imp; } ConsumerTabMethod;
extern int FixtureTabRegisterTable(Class cls, const ConsumerTabMethod *table, size_t count, const char **detail);
static void consumerAdded(id self, SEL _cmd) { (void)self; (void)_cmd; }
static const ConsumerTabMethod consumerRows[] = { { "fixtureConsumerAdded", "v16@0:8", NO, (IMP)consumerAdded } };
#endif

int main(int argc, char **argv) {
    if (argc > 99) {
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
