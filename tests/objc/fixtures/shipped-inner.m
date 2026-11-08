/* shipped-inner.m -- libMGInner.dylib, a second shipped image that MGShipped.framework loads through
 * @loader_path (tests/objc-closure-test.sh). MRC. Never executed.
 *   MGInner   an NSObject subclass that implements +innerThing */
#import <Foundation/Foundation.h>

@interface MGInner : NSObject
+ (id)innerThing;
@end
@implementation MGInner
+ (id)innerThing { return nil; }
@end
