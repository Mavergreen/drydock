/* Fixture provider, registration member: the shape of the Recaulk companion's register.m (an
 * add-only class_addMethod reached from a constructor and from a named activation root, with no
 * message sends), under fixture names. tests/objc-provider-test.sh archives it with
 * provider-impl.c, declares it the way Recaulk's objc-providers.json does and links consumers
 * through scripts/objc-provider-link-args.sh. Built for x86_64 against the pinned 10.9 SDK; read as
 * bytes, never executed. FIXTURE_REGISTERED_CLASS lets the test build an archive whose code
 * registers a different class than its declaration names. */
#include <objc/runtime.h>
#include <stdlib.h>

#ifndef FIXTURE_REGISTERED_CLASS
#define FIXTURE_REGISTERED_CLASS "NSWorkspace"
#endif

extern void *__fixture_objc_workspace_open_urls(void *, SEL, void *, void *, unsigned long, void *, void **);

__attribute__((noinline)) void __fixture_objc_register_workspace_class(Class receiver) {
    SEL selector;
    Class owner;
    if (!receiver) return;
    selector = sel_registerName("openURLs:withApplicationAtURL:options:configuration:error:");
    for (owner = receiver; owner; owner = class_getSuperclass(owner)) {
        unsigned count = 0, i;
        Method *methods = class_copyMethodList(owner, &count);
        int present = 0;
        for (i = 0; i < count; i++) if (method_getName(methods[i]) == selector) { present = 1; break; }
        free(methods);
        if (present) return;
    }
    class_addMethod(receiver, selector, (IMP)__fixture_objc_workspace_open_urls, "@56@0:8@16@24Q32@40^@48");
}

void __fixture_objc_activate(void) { __fixture_objc_register_workspace_class(objc_getClass(FIXTURE_REGISTERED_CLASS)); }

__attribute__((constructor)) static void activate_at_load(void) { __fixture_objc_activate(); }
