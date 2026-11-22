/* Fixture: one section holding a pointer dyld must rebase and a word it must not. */
static int target;
__attribute__((used, section("__DATA,__const"))) void *const rebased_ptr = &target;
__attribute__((used, section("__DATA,__const"))) const unsigned long long unrebased_word = 0x1122334455667788ULL;

int main(void) { return target; }
