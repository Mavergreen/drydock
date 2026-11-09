/* Fixture: objc_msgSend passed as a real function-pointer argument -- qsort's comparator, its fourth
 * parameter (rcx) -- to a C function the floor catalog knows (spec: usr/include/stdlib.h). The
 * reader's bound for qsort is four argument registers, so rcx still counts: cannot-measure,
 * "objc entry point in rcx is passed as an argument". Built -Os by tests/objc/objc-reader-test.sh with
 * the pinned clang22; the other twins of entry-copy are hand-assembled (entry-escape.S). Never run. */
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <stdlib.h>

typedef int (*compare_fn)(const void *, const void *);

void sort_with_entry(void *base, size_t n) {
    qsort(base, n, sizeof(id), (compare_fn)objc_msgSend);
}

int main(void) {
    id v[2] = { @"b", @"a" };
    sort_with_entry(v, 2);
    return 0;
}
