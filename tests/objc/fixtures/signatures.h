/* Fixture: declared result types the signature companion must report as written, never from
 * the ABI encoding (which spells every object result "@"). */
@protocol Copying
- (id)copyThing;
@end

__attribute__((objc_root_class))
@interface Root
+ (instancetype)make;
- (instancetype)initPlain;
+ (Root *)sharedRoot;
- (id)anything;
- (id<Copying>)qualifiedAnything;
- (Root<Copying> *)qualifiedRoot;
- (long)scalar;
- (Class)classValue;
- (void)nothing;
@end

typedef Root *RootRef;
typedef id AnyRef;
@class Leaf;

@interface Root (Aliases)
- (RootRef)aliased;
- (AnyRef)aliasedAnything;
- (Leaf *)forwardLeaf;
@property(readonly) Root *child;
@property(class, readonly) Root *defaultRoot;
@end

@interface Leaf : Root
- (instancetype)initLeaf;
@end
