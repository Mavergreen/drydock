/* Fixture: a consumer of the NSWorkspace openURLs backfill. It sends the 10.10 method to the
 * shared workspace and names no provider symbol; whether the send is provided depends only on how
 * it was linked (tests/objc-provider-test.sh). Built for x86_64 against the pinned 10.9 SDK (MRC);
 * read as bytes, never executed. */
#import <AppKit/AppKit.h>

@interface NSWorkspace (LaterLaunch)
- (id)openURLs:(NSArray *)urls withApplicationAtURL:(NSURL *)app options:(NSUInteger)options
    configuration:(NSDictionary *)configuration error:(NSError **)error;
@end

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 99)
        return [[NSWorkspace sharedWorkspace] openURLs:nil withApplicationAtURL:nil options:0 configuration:nil error:NULL] != nil;
    return 0;
}
