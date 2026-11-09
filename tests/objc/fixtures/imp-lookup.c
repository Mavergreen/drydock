/* Fixture: libobjc calls that answer a method's implementation, one per build (-DFORM=N): a call
 * through the answer is a send no dispatch entry point carries, so each is runtime-imp-lookup.
 * Never executed.
 *   FORM 1  method_getImplementation
 *   FORM 2  class_getMethodImplementation
 *   FORM 3  class_getMethodImplementation_stret */
#include <objc/runtime.h>
#include <objc/message.h>

int main(int argc, char **argv) {
    Class c = objc_getClass("NSObject");
    SEL s = sel_registerName("description");
    IMP imp;
    if (argc < 9) return 0;
#if FORM == 1
    imp = method_getImplementation(class_getInstanceMethod(c, s));
#elif FORM == 2
    imp = class_getMethodImplementation(c, s);
#elif FORM == 3
    imp = class_getMethodImplementation_stret(c, s);
#else
#error FORM
#endif
    return ((id (*)(id, SEL))imp)((id)c, s) != 0;
}
