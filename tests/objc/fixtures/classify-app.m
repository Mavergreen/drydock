/* Fixture: application-defined Objective-C ownership. An NSObject subclass, a root class of its
 * own, an NSProxy subclass and a category on a floor class, each defined here, and sends whose
 * receivers are their class references. Linked against the pinned 10.9 SDK (MRC), never executed. */
#import <AppKit/AppKit.h>

@interface Probe : NSObject
+ (id)probe;
+ (id)missingEverywhere;
@end
@implementation Probe
+ (id)probe { return nil; }
@end

__attribute__((objc_root_class))
@interface Rootless
+ (id)make;
+ (id)description;
@end
@implementation Rootless
+ (id)make { return nil; }
@end

@interface Forwarder : NSProxy
@end
@implementation Forwarder
@end

@interface NSWorkspace (MavergreenProbe)
- (BOOL)mavergreenProbe;
@end
@implementation NSWorkspace (MavergreenProbe)
- (BOOL)mavergreenProbe { return YES; }
@end

__attribute__((noinline, used)) void app_cases(void) {
    [Probe probe];                                         /* the artifact's own method */
    [Probe respondsToSelector:@selector(probe)];           /* R1: NSObject root proof */
    [Probe missingEverywhere];                             /* nobody implements it */
    [Rootless description];                                /* no NSObject root */
    [Forwarder isKindOfClass:[NSObject class]];            /* NSProxy root: a witness exception */
    [[NSWorkspace sharedWorkspace] mavergreenProbe];       /* the artifact's category */
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 99) app_cases();
    return 0;
}
