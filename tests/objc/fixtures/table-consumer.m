/* Fixture: a consumer of tests/objc/fixtures/table-provider.m's six NSWindow tabbing methods (10.12), sending each
 * as declared -- four to an NSWindow instance, two to the class -- and naming no provider symbol. KIND_CROSS sends
 * instead one instance member to the class and one class member to an instance; COMPUTED_SEL also registers a
 * selector named by its argument, outside any provider. Built for x86_64 against the
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

int main(int argc, char **argv) {
    if (argc > 99) {
#ifdef COMPUTED_SEL
        if (sel_registerName(argv[1]) == NULL) return 2;
#endif
        NSWindow *w = [[NSApplication sharedApplication] keyWindow];
#ifdef KIND_CROSS
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
