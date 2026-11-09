/* Fixture: the source of -[RecaulkTabPSMTabBarControl setDelegate:] (PSMTabBarControl), several sends
 * across a branch with a one-parameter send among them. Alacritty's compat probe ships it with
 * objc_msgSend copied through rcx (`movq %r15,%rcx` / `movq %rcx,%rbx`) and rcx still holding it at
 * the respondsToSelector: send; the pinned clang22 at -Os and -O3 reloads the GOT slot in each block
 * instead (checked when this fixture was written), so tests/objc/objc-reader-test.sh reads both builds
 * as measured, and the copied shape itself is hand-assembled in tests/objc/fixtures/entry-copy.S. Never run. */
#import <AppKit/AppKit.h>

@interface Bar : NSView {
    id delegate;
    NSTabView *tabView;
}
- (id)delegate;
@end

@protocol BarDelegate
- (NSArray *)allowedDraggedTypesForTabView:(NSTabView *)tabView;
@end

@implementation Bar
- (id)delegate { return delegate; }
- (void)setDelegate:(id)object {
    delegate = object;
    NSMutableArray *types = [NSMutableArray arrayWithObject:@"PSMTabBarControlItemPBType"];
    if ([self delegate] && [[self delegate] respondsToSelector:@selector(allowedDraggedTypesForTabView:)])
        [types addObjectsFromArray:[[self delegate] allowedDraggedTypesForTabView:tabView]];
    [self unregisterDraggedTypes];
    [self registerForDraggedTypes:types];
}
@end

int main(void) { return [[Bar alloc] init] != nil; }
