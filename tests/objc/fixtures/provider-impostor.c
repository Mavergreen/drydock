/* Fixture: a consumer that names the activation root itself and registers its own method with
 * class_addMethod from a constructor -- a symbol name and a runtime mutation with no attested
 * provider behind them. tests/objc-provider-test.sh expects neither to make the send provided.
 * Read as bytes, never executed. */
#include <objc/runtime.h>
#include <objc/message.h>

static void *impostor(void *self, SEL cmd) { (void)self; (void)cmd; return 0; }

void __fixture_objc_activate(void) {}
void __recaulk_objc_activate(void) {}

__attribute__((constructor)) static void install(void) {
    class_addMethod(objc_getClass("NSWorkspace"), sel_registerName("openURLs:withApplicationAtURL:options:configuration:error:"),
                    (IMP)impostor, "@56@0:8@16@24Q32@40^@48");
}

int main(int argc, char **argv) {
    void *ws;
    (void)argv;
    if (argc <= 99) return 0;
    ws = ((void *(*)(void *, SEL))objc_msgSend)((void *)objc_getClass("NSWorkspace"), sel_registerName("sharedWorkspace"));
    return ((void *(*)(void *, SEL, void *, void *, unsigned long, void *, void *))objc_msgSend)(
               ws, sel_registerName("openURLs:withApplicationAtURL:options:configuration:error:"), 0, 0, 0, 0, 0) != 0;
}
