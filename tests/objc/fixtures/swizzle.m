/* Fixture: libobjc calls that change a class at run time, one per build (-DFORM=N). Never executed.
 *   FORM 1-3  replace a method's implementation: runtime-method-swizzle
 *             (method_setImplementation, method_exchangeImplementations, class_replaceMethod)
 *   FORM 4-7  change or make a class: runtime-class-creation
 *             (class_addProtocol, class_addIvar, class_addProperty, objc_initializeClassPair)
 *   FORM 8    class_addMethod: a method registration, which provider.c must attest; no reader error */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/* spec: objc4-551.1 runtime/objc-internal.h -- objc_initializeClassPair, not in the SDK's headers */
extern Class objc_initializeClassPair(Class superclass, const char *name, Class cls, Class metacls);

static id replacement(id self, SEL _cmd) { return self; }

int main(int argc, char **argv) {
    Class c = objc_getClass("NSObject");
    Method m = class_getInstanceMethod(c, @selector(description));
    if (argc < 9) return 0;
#if FORM == 1
    return method_setImplementation(m, (IMP)replacement) != NULL;
#elif FORM == 2
    method_exchangeImplementations(m, class_getInstanceMethod(c, @selector(debugDescription)));
    return 0;
#elif FORM == 3
    return class_replaceMethod(c, @selector(description), (IMP)replacement, "@@:") != NULL;
#elif FORM == 4
    return class_addProtocol(c, objc_getProtocol("NSCopying"));
#elif FORM == 5
    return class_addIvar(c, "mgIvar", sizeof(id), 3, "@");
#elif FORM == 6
    objc_property_attribute_t a = { "T", "@" };
    return class_addProperty(c, "mgProperty", &a, 1);
#elif FORM == 7
    return objc_initializeClassPair(c, argv[1], (Class)argv[2], (Class)argv[3]) != NULL;
#elif FORM == 8
    return class_addMethod(c, @selector(mgAdded), (IMP)replacement, "@@:") && m;
#else
#error FORM
#endif
}
