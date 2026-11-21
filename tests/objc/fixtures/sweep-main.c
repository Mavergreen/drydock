/* Fixture: imports method_getName, whose lazy pointer sweep-table.S's table names, and pulls in
 * _sweep_fn's archive member. Never executed. */
#include <objc/runtime.h>

extern void sweep_fn(void);

int main(int argc, char **argv) {
    (void)argv;
    return (int)(long)method_getName((Method)(long)argc) + (int)(long)&sweep_fn;
}
