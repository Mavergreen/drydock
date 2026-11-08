/* runtime-roots.m -- fixture classes for the R1 root-method witness (tests/objc-reference-set-test.sh).
 * Built as a dylib for the host arch and loaded into tools/objc-runtime-inventory.m through
 * --allow-image. MRC; no class here is ever instantiated except by --behavior-class MGProxy.
 *   MGBareRoot      a root other than NSObject that answers no root selector
 *   MGPartialRoot   a root that implements isKindOfClass: and description but not respondsToSelector:
 *   MGPartialChild  inherits MGPartialRoot's gap
 *   MGProxy         an NSProxy subclass that overrides nothing
 *   MGObject        an ordinary NSObject subclass; its Shadow category replaces -ping
 *   MGReparented    an NSObject subclass whose +initialize moves it under MGLateParent, as 10.9.5's
 *                   Foundation moves NSURLSession under CFNetwork's __NSCFURLSession; only through
 *                   MGLateParent does it answer +lateFactory
 * -DMG_BACKFILL adds -[NSObject mavergreenFixtureBackfill] at load, as a provider would;
 * -DMG_ACTIVATION_ROOT also defines Recaulk's activation root symbol.
 * -DMG_INIT_CRASH adds MGInitCrash, whose +initialize never returns normally. */
#import <Foundation/Foundation.h>
#include <objc/runtime.h>

__attribute__((objc_root_class))
@interface MGBareRoot { Class isa; }
- (void)ping;
@end
@implementation MGBareRoot
- (void)ping {}
@end

__attribute__((objc_root_class))
@interface MGPartialRoot { Class isa; }
- (BOOL)isKindOfClass:(Class)c;
- (NSString *)description;
+ (NSString *)description;
@end
@implementation MGPartialRoot
- (BOOL)isKindOfClass:(Class)c { return c == object_getClass(self); }
- (NSString *)description { return @"MGPartialRoot"; }
+ (NSString *)description { return @"MGPartialRoot class"; }
@end

@interface MGPartialChild : MGPartialRoot
@end
@implementation MGPartialChild
@end

@interface MGProxy : NSProxy
@end
@implementation MGProxy
@end

@interface MGObject : NSObject
- (void)ping;
@end
@implementation MGObject
- (void)ping {}
@end
@interface MGObject (Shadow)
- (void)ping;
@end
@implementation MGObject (Shadow)
- (void)ping {}
@end

@interface MGLateParent : NSObject
+ (id)lateFactory;
@end
@implementation MGLateParent
+ (id)lateFactory { return nil; }
@end
@interface MGReparented : NSObject
@end
@implementation MGReparented
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
+ (void)initialize { if (self == objc_getClass("MGReparented")) class_setSuperclass(self, objc_getClass("MGLateParent")); }
#pragma clang diagnostic pop
@end

#ifdef MG_INIT_CRASH
@interface MGInitCrash : NSObject
@end
@implementation MGInitCrash
+ (void)initialize { abort(); }
@end
#endif

#ifdef MG_BACKFILL
static void mgBackfilled(id self, SEL _cmd) { (void)self; (void)_cmd; }
__attribute__((constructor)) static void mgInstall(void) {
    class_addMethod(objc_getClass("NSObject"), sel_registerName("mavergreenFixtureBackfill"), (IMP)mgBackfilled, "v16@0:8");
}
#endif
#ifdef MG_ACTIVATION_ROOT
void __recaulk_objc_activate(void);
void __recaulk_objc_activate(void) {}
#endif
