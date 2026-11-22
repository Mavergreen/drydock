/* Fixture provider member with the assembler-local atoms clang gives an Objective-C class and a
 * switch lowered to a table: l_OBJC_LABEL_CLASS_$, l_OBJC_CLASSLIST_SUP_REFS_$_ and l_switch.table.*.
 * The linker drops such linker-private symbols, so the prestrip image can never be asked for them
 * by name; objc-provider-test.sh archives this with provider-register.c and expects each atom
 * verified by its bytes. It also defines the declared implementation symbol. Built for x86_64
 * against the pinned 10.9 SDK (MRC), compiled -Os; read as bytes, never executed. */
#import <Foundation/Foundation.h>

@interface FixtureLocalsBase : NSObject
@end
@implementation FixtureLocalsBase
@end

@interface FixtureLocals : FixtureLocalsBase
- (long)weight:(unsigned)kind;
- (NSUInteger)hash;
@end

@implementation FixtureLocals
- (NSUInteger)hash { return [super hash] + 1; }
- (long)weight:(unsigned)kind {
    switch (kind) {
    case 0: return 11;
    case 1: return 23;
    case 2: return 37;
    case 3: return 41;
    case 4: return 59;
    case 5: return 61;
    case 6: return 73;
    case 7: return 89;
    default: return 97;
    }
}
@end

void *__fixture_objc_workspace_open_urls(void *self, SEL cmd, void *urls, void *app, unsigned long options,
                                         void *configuration, void **error) {
    (void)self; (void)cmd; (void)urls; (void)app; (void)configuration;
    if (error) *error = (void *)(long)(options + [[FixtureLocals new] weight:(unsigned)options]);
    return 0;
}
