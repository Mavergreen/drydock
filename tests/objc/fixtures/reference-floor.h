/* reference-floor.h -- floor-side declarations for tests/objc-reference-set-test.sh. */
__attribute__((objc_root_class, availability(macos,introduced=10.0)))
@interface RefRoot
+ (long)shared;
- (long)shared;
- (void)rootMethod;
@end

__attribute__((availability(macos,introduced=10.8)))
@interface RefOld : RefRoot
- (void)oldMethod;
@end

@interface RefOld (Extras)
- (void)categoryMethod;
@end

@protocol RefProtocol
- (void)requiredThing;
@optional
- (void)optionalThing;
@end

@interface RefAdopter : RefRoot <RefProtocol>
@end

#include <stddef.h>
typedef size_t RefSize;
