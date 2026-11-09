/* Fixture: the libobjc calls compiled Objective-C makes for synthesized properties, associated
 * objects and introspection, each classified (src/objc/macho-reader.c ROLES): manual retain/release,
 * so the synthesized accessors call the property functions. Never executed.
 *   atomic retain:     objc_getProperty, objc_setProperty_atomic
 *   nonatomic retain:  objc_setProperty_nonatomic
 *   atomic copy:       objc_getProperty, objc_setProperty_atomic_copy
 *   nonatomic copy:    objc_setProperty_nonatomic_copy
 * and each other IMP_MEMORY and IMP_INTROSPECT import this piece classifies, called directly. */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/* spec: objc4-551.1 runtime/objc-abi.h -- the compiler's property entry points, not in the SDK's headers */
extern id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic);
extern void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, signed char shouldCopy);

@protocol MGPropsProtocol
- (void)mgPropsRequired;
@end

@interface MGProps : NSObject <MGPropsProtocol> {
    id _raw;
}
@property (retain) id atomicRetained;
@property (nonatomic, retain) id nonatomicRetained;
@property (copy) NSString *atomicCopied;
@property (nonatomic, copy) NSString *nonatomicCopied;
@end

@implementation MGProps
@synthesize atomicRetained, nonatomicRetained, atomicCopied, nonatomicCopied;
- (void)mgPropsRequired {}
@end

static char key;
void *volatile sink;

int main(int argc, char **argv) {
    MGProps *p = [[MGProps alloc] init];
    Class c = object_getClass(p);
    Ivar iv = class_getInstanceVariable(c, "_raw");
    objc_property_t prop = (objc_property_t)sink;   /* class_getProperty is not classified */
    unsigned int n = 0;
    char buf[64] = { 0 };
    if (argc < 9) return 0;
    p.atomicRetained = p; p.nonatomicRetained = p;
    p.atomicCopied = @"a"; p.nonatomicCopied = @"b";
    sink = p.atomicRetained; sink = p.atomicCopied;
    objc_setProperty(p, @selector(setAtomicRetained:), ivar_getOffset(iv), p, YES, 0);
    sink = objc_getProperty(p, @selector(atomicRetained), ivar_getOffset(iv), YES);
    objc_setAssociatedObject(p, &key, p, OBJC_ASSOCIATION_RETAIN);
    sink = objc_getAssociatedObject(p, &key);
    objc_removeAssociatedObjects(p);
    sink = (void *)(uintptr_t)class_respondsToSelector(c, @selector(mgPropsRequired));
    sink = protocol_getMethodDescription(objc_getProtocol("MGPropsProtocol"), @selector(mgPropsRequired), YES, YES).name;
    sink = (void *)protocol_getName(objc_getProtocol("MGPropsProtocol"));
    sink = (void *)(uintptr_t)class_conformsToProtocol(c, objc_getProtocol("MGPropsProtocol"));
    sink = (void *)class_getIvarLayout(c);
    sink = property_copyAttributeList(prop, &n);
    sink = class_getInstanceMethod(c, @selector(mgPropsRequired));
    sink = class_getClassMethod(c, @selector(alloc));
    sink = (void *)ivar_getName(iv);
    sink = object_getIvar(p, iv);
    object_setIvar(p, iv, p);
    sink = (void *)class_getInstanceSize(c);
    sink = objc_constructInstance(c, buf);
    objc_disposeClassPair(objc_getClass("MGProps"));
    return 0;
}
