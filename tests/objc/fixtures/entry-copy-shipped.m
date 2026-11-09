/* Fixture: a shipped image's own declaration of respondsToSelector: taking a 16-byte INTEGER struct --
 * two argument registers, rdx and rcx -- read after the artifact's code (src/objc/main.m "The shipped
 * closure"). It raises the bound entry-copy.S's `_responds` send was measured with past rcx, so that
 * send is cannot-measure (src/objc/reference.c objc_rely_selector_gprs). Never run. */
struct pair { long a, b; };

__attribute__((objc_root_class))
@interface Odd
- (signed char)respondsToSelector:(struct pair)p;
@end

@implementation Odd
- (signed char)respondsToSelector:(struct pair)p { return p.a == p.b; }
@end
