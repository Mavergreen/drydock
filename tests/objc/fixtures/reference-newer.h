/* reference-newer.h -- newer-side declarations for tests/objc-reference-set-test.sh: the floor's,
 * plus a later class with an unannotated property and a later category method. */
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

@interface RefOld (Later)
- (void)laterMethod __attribute__((availability(macos,introduced=10.11)));
@end

__attribute__((availability(macos,introduced=10.12)))
@interface RefLater : RefOld
@property(readonly) long unannotated;
@end

@protocol RefProtocol
- (void)requiredThing;
@optional
- (void)optionalThing;
@end

@interface RefAdopter : RefRoot <RefProtocol>
@end
