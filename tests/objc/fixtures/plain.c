/* Fixture: a genuinely measured image with no Objective-C use; its prose mentions a selector. */
#include <stdio.h>

int main(int argc, char **argv) {
    (void)argv;
    if (argc > 3) puts("openURLs:withApplicationAtURL:options:configuration:error: is prose here");
    return 0;
}
