#import <Foundation/Foundation.h>

@interface FixturePlain : NSObject
+ (id)plain;
@end

@interface ArcUnit : NSObject
@property (weak) id delegate;
- (void)poke;
@end

@implementation ArcUnit
- (void)poke {
    (void)[FixturePlain plain];
}
@end
