/* Fixture provider, implementation member: a body with the declared ABI
 * (@56@0:8@16@24Q32@40^@48) that sends no message, so a consumer linking only this provider can
 * close every send. See provider-register.c. Read as bytes, never executed.
 * With FIXTURE_LITERAL the body also reads an 8-byte literal (__TEXT,__literal8), as Recaulk's
 * workspace.o does: ld64 merges it into __TEXT,__const, lld into __TEXT,__literals. */
#include <objc/runtime.h>

void *__fixture_objc_workspace_open_urls(void *self, SEL cmd, void *urls, void *app, unsigned long options,
                                         void *configuration, void **error) {
    (void)self; (void)cmd; (void)urls; (void)app; (void)options; (void)configuration;
#ifdef FIXTURE_LITERAL
    if (error) *error = (void *)(long)((double)(long)options * 0.0123456789);
#else
    if (error) *error = 0;
#endif
    return 0;
}
