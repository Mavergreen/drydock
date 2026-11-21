/* Fixture provider, implementation member in place of provider-impl.c: the same declared ABI and no
 * message send, but a body that takes the address of two functions provider-register.c defines, as
 * Recaulk's register.m loads two of its archive's functions. Each is a GOT load in this one atom, and
 * lld relaxes both to leaq. Read as bytes, never executed. */
#include <objc/runtime.h>

extern void __fixture_objc_activate(void);
extern void __fixture_objc_register_workspace_class(Class);

void *__fixture_objc_workspace_open_urls(void *self, SEL cmd, void *urls, void *app, unsigned long options,
                                         void *configuration, void **error) {
    (void)self; (void)cmd; (void)urls; (void)app; (void)configuration;
    if (error) *error = options ? (void *)__fixture_objc_activate : (void *)__fixture_objc_register_workspace_class;
    return 0;
}
