/* shipped-app.m -- an application whose sends go into the framework it ships
 * (shipped-framework.m; tests/objc-closure-test.sh). MRC. Never executed.
 *   shipped_class      +[MGShipped sharedShipped]: the framework implements it
 *   shipped_missing    +[MGShipped notShipped]: nothing implements it, on the framework or the floor
 *   shipped_inherited  +[MGShipped description]: the floor's NSObject answers it
 *   shipped_category   +[NSObject mgShippedHello]: the framework's category on a floor class
 *   inner_inherited    (-DMG_INNER) +[MGShippedChild innerThing]: implemented by libMGInner.dylib,
 *                      the framework's own dependency
 *   MGAppOwn           a class the application defines (the framework too, with -DMG_DUPLICATE) */
#import <Foundation/Foundation.h>

@interface MGShipped : NSObject
+ (id)sharedShipped;
+ (id)notShipped;
@end
@interface NSObject (MGShippedExtras)
+ (id)mgShippedHello;
@end
#ifdef MG_INNER
@interface MGShippedChild : NSObject
+ (id)innerThing;
@end
#endif
@interface MGAppOwn : NSObject
@end
@implementation MGAppOwn
@end

__attribute__((noinline)) id shipped_class(void) { return [MGShipped sharedShipped]; }
__attribute__((noinline)) id shipped_missing(void) { return [MGShipped notShipped]; }
__attribute__((noinline)) id shipped_inherited(void) { return [MGShipped description]; }
__attribute__((noinline)) id shipped_category(void) { return [NSObject mgShippedHello]; }
#ifdef MG_INNER
__attribute__((noinline)) id inner_inherited(void) { return [MGShippedChild innerThing]; }
#endif

int main(void) {
    shipped_class(); shipped_missing(); shipped_inherited(); shipped_category();
#ifdef MG_INNER
    inner_inherited();
#endif
    return 0;
}
