// A member of tests/objc/fixtures/weak-a.m's provider the link never loads, archived first: its copy of the weak
// FixtureWeakTable, WEAK_OTHER longs, is the archive's first definition, and weak-a.m's copy the one kept.
#ifdef WEAK_TABLE
__attribute__((weak, visibility("hidden"), section("__DATA,__fxweak"))) long FixtureWeakTable[WEAK_OTHER] = { 1 };
#endif
