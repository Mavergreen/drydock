/* Fixture: explicit runtime sends, the way a C-function IMP makes them. tests/objc/objc-source-inventory-host-test.sh
 * receipts it: an @selector literal through the runtime's send functions is a row; one naming a macro, a SEL variable,
 * sel_registerName, a lookalike or the runtime's redeclared outside the SDK is none. Parsed only, never built. */
#import <Foundation/Foundation.h>
#include <objc/message.h>

static id my_send(id self, SEL op) { (void)op; return self; }

id explicit_sends(id self, id x, NSString *obj) {
    struct objc_super up = { self, Nil };
    SEL s = @selector(hash);
    ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&up, @selector(description));
    ((id (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&up, @selector(isEqual:), x);
    ((id (*)(id, SEL))objc_msgSend)(obj, (@selector(copy)));
    ((id (*)(id, SEL))objc_msgSend)(obj, s);
    ((id (*)(id, SEL))objc_msgSend)(obj, sel_registerName("length"));
    ((id (*)(id, SEL, SEL, id))objc_msgSend)(obj, @selector(performSelector: withObject:), s, x);
    return my_send(obj, @selector(retain));
}

#define S description
id explicit_macro_send(id self) {
    struct objc_super up = { self, Nil };
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&up, @selector(S));
}

id objc_msgSend(id, SEL, ...);
id redeclared_send(NSString *obj) {
    return objc_msgSend(obj, @selector(mutableCopy));
}
