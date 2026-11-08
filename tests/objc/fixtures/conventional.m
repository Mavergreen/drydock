/* Fixture: conventional compiler-emitted Objective-C metadata -- a class with instance and class
 * methods, its metaclass, a category on a framework class, selector/class/super references and
 * message sends, including one to a later method only declared here. Linked, never executed. */
#import <AppKit/AppKit.h>

@interface NSWorkspace (LaterLaunch)
- (id)openURLs:(NSArray *)urls withApplicationAtURL:(NSURL *)app options:(NSUInteger)options
    configuration:(NSDictionary *)configuration error:(NSError **)error;
@end

@interface NSWorkspace (MavergreenProbe)
- (BOOL)mavergreenProbe;
@end

@implementation NSWorkspace (MavergreenProbe)
- (BOOL)mavergreenProbe { return YES; }
@end

@interface Probe : NSObject
+ (instancetype)probe;
- (id)launch:(NSURL *)url;
@end

@implementation Probe
+ (instancetype)probe { return [[self alloc] init]; }
- (id)init { return [super init]; }
- (id)launch:(NSURL *)url {
    return [[NSWorkspace sharedWorkspace] openURLs:@[ url ] withApplicationAtURL:url options:0
                                     configuration:@{} error:NULL];
}
@end

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 9) [[Probe probe] launch:nil];
    return 0;
}
