/* Fixture: the classes an artifact defines, and the sends to receivers of unknown class that R1
 * closes only when every such class has a measured NSObject or NSProxy root
 * (tools/objc-compat/classify.c header). Linked against the pinned 10.9 SDK (MRC), read as bytes,
 * never executed. -DFORM=N adds one class:
 *   0  none: only an NSObject subclass and an NSProxy subclass
 *   1  MGOwnRoot, a root class of the artifact's own
 *   2  MGSwiftish, whose superclass SwiftObject lives in another image the reference does not know
 *      (Swift classes have that root); linked with -U, never resolved
 *   3  MGLeaf, whose superclass is the floor's NSLeafProxy, a root other than NSObject and NSProxy;
 *      linked with -U, never resolved */
#import <Foundation/Foundation.h>

@interface MGPlain : NSObject
@end
@implementation MGPlain
@end

@interface MGForward : NSProxy
@end
@implementation MGForward
@end

#if FORM == 1
__attribute__((objc_root_class))
@interface MGOwnRoot { Class isa; }
@end
@implementation MGOwnRoot
@end
#elif FORM == 2
__attribute__((objc_root_class))
@interface SwiftObject { Class isa; }
@end
@interface MGSwiftish : SwiftObject
@end
@implementation MGSwiftish
@end
#elif FORM == 3
__attribute__((objc_root_class))
@interface NSLeafProxy { Class isa; }
@end
@interface MGLeaf : NSLeafProxy
@end
@implementation MGLeaf
@end
#elif FORM != 0
#error FORM
#endif

/* An incoming argument and a collection element: receivers whose class nothing here gives. */
__attribute__((noinline, used)) BOOL argument_root(id x) { return [x isKindOfClass:[NSString class]]; }
__attribute__((noinline, used)) NSUInteger argument_hash(id x) { return [x hash]; }
__attribute__((noinline, used)) NSUInteger argument_nonroot(id x) { return [x count]; }
__attribute__((noinline, used)) NSUInteger element_root(NSArray *a) {
    NSUInteger n = 0;
    for (id e in a) n += [e respondsToSelector:@selector(count)];
    return n;
}

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 99) {
        id x = [MGPlain new];
        return (int)(argument_root(x) + argument_hash(x) + argument_nonroot(x) + element_root(x));
    }
    return 0;
}
