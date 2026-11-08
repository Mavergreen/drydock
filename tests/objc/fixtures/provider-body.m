/* Fixture provider, Objective-C implementation member: the declared ABI (@56@0:8@16@24Q32@40^@48)
 * with a body that sends messages the way Recaulk's workspace.m does -- to its own typed
 * arguments, which only the prepared source's static types close, and to framework results the
 * artifact measures. tests/objc-provider-test.sh archives it with provider-register.c (in place of
 * provider-impl.c), compiled with -g so the archive member carries its line table, and inventories
 * it with scripts/objc-source-inventory.sh. Built for x86_64 against the pinned 10.9 SDK (MRC);
 * read as bytes, never executed.
 *   FIXTURE_ID_SEND    adds sends to an `id` local that -[NSDictionary objectForKey:] vends: isKindOfClass:,
 *                      a reviewed root selector that R1 closes, and allKeys, which no static type closes
 *   FIXTURE_MUTATION   adds an unguarded send of a 10.11 NSURL method to the typed argument
 *   FIXTURE_MERGED     adds a send whose selector is one of two on different paths (through a volatile local),
 *                      as when a compiler merges two sends into one call, and one of them a value the binary
 *                      does not name (an incoming argument): the call is not split per path (macho-reader.c),
 *                      and the binary gives no selector
 *   FIXTURE_LINE0      adds a send the line table attributes to line 0, as merged code is */
#import <AppKit/AppKit.h>
#include <objc/message.h>

#ifdef FIXTURE_MUTATION
@interface NSURL (FixtureLater)
- (BOOL)hasDirectoryPath;
@end
#endif

static NSUInteger counted(NSArray *urls) { return [urls count]; }
#ifdef FIXTURE_LINE0
static id line0(NSArray *urls);   /* at the end: nothing after its #line 0 needs renumbering */
#endif

id __fixture_objc_workspace_open_urls(id receiver, SEL command, NSArray *urls, NSURL *app, NSUInteger options,
                                      NSDictionary *configuration, NSError **error) {
    (void)receiver; (void)command;
    if (error) *error = nil;
    if (![app isFileURL] || !counted(urls)) return nil;
    id environment = [configuration objectForKey:@"environment"];
#ifdef FIXTURE_ID_SEND
    if (environment && (![environment isKindOfClass:[NSDictionary class]] || ![environment allKeys])) return nil;
#endif
#ifdef FIXTURE_MUTATION
    if ([app hasDirectoryPath]) return nil;
#endif
#ifdef FIXTURE_MERGED
    {
        SEL volatile pick = @selector(firstObject);
        if (options & 1) pick = (SEL)(uintptr_t)options;   /* never executed: a selector no reference names */
        if (!((id (*)(id, SEL))objc_msgSend)(urls, pick)) return nil;
    }
#endif
#ifdef FIXTURE_LINE0
    if (!line0(urls)) return nil;
#endif
    if (environment) options |= NSWorkspaceLaunchNewInstance;
    return [[NSWorkspace sharedWorkspace] launchApplicationAtURL:app options:options configuration:configuration error:error];
}
#ifdef FIXTURE_LINE0
__attribute__((noinline)) static id line0(NSArray *urls) {
#line 0
    return [urls lastObject];
}
#endif
