/* Fixture: producer and dispatch forms the reader must refuse as cannot-measure, one per build
 * (-DFORM=N), each otherwise a measurable program. Never executed. */
#include <stdio.h>
#include <stdlib.h>
#include <objc/runtime.h>
#include <objc/message.h>

extern void *NSSelectorFromString(void *name);
void *volatile escaped_entry;

int main(int argc, char **argv) {
    char buf[64];
    if (argc < 9) return 0;
    snprintf(buf, sizeof buf, "%s:", argv[1]);
#if FORM == 1
    /* A selector computed at runtime. */
    return sel_registerName(buf) != NULL;
#elif FORM == 2
    /* A class name computed at runtime. */
    return objc_getClass(getenv("CLASS")) != NULL;
#elif FORM == 3
    /* An IMP fetched for an arbitrary send: a dispatch path this reader does not model. */
    return method_getImplementation(class_getInstanceMethod(objc_getClass("NSObject"), sel_registerName("description"))) != NULL;
#elif FORM == 4
    /* objc_msgSend's address escapes into data: sends through it are unexaminable. */
    escaped_entry = (void *)objc_msgSend;
    return escaped_entry != NULL;
#elif FORM == 5
    /* NSSelectorFromString over an NSString this reader cannot see the bytes of. */
    return NSSelectorFromString((void *)buf) != NULL;
#elif FORM == 6
    /* A class made at run time: its root is in no image this reader can measure. */
    return objc_allocateClassPair(objc_getClass("NSObject"), "MGRuntimeMade", 0) != NULL;
#else
#error FORM
#endif
}
