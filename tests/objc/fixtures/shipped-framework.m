/* shipped-framework.m -- a framework an application ships inside its bundle (tests/objc-closure-test.sh).
 * Built as MGShipped.framework/Versions/A/MGShipped, install name @rpath/MGShipped.framework/Versions/A/MGShipped.
 * MRC. Never executed.
 *   MGShipped                 an NSObject subclass that implements +sharedShipped and -ping
 *   NSObject (MGShippedExtras)  a category on a floor class: +mgShippedHello
 *   MGShippedChild            (-DMG_INNER) a subclass of MGInner, which libMGInner.dylib beside it
 *                             defines (loaded @loader_path/libMGInner.dylib)
 *   MGAppOwn                  (-DMG_DUPLICATE) a class the application defines too */
#import <Foundation/Foundation.h>

@interface MGShipped : NSObject
+ (id)sharedShipped;
- (void)ping;
@end
@implementation MGShipped
+ (id)sharedShipped { return nil; }
- (void)ping {}
@end

@interface NSObject (MGShippedExtras)
+ (id)mgShippedHello;
@end
@implementation NSObject (MGShippedExtras)
+ (id)mgShippedHello { return nil; }
@end

#ifdef MG_INNER
@interface MGInner : NSObject
+ (id)innerThing;
@end
@interface MGShippedChild : MGInner
@end
@implementation MGShippedChild
@end
#endif

#ifdef MG_DUPLICATE
@interface MGAppOwn : NSObject
@end
@implementation MGAppOwn
@end
#endif
