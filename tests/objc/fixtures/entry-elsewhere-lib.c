/* Fixture: a non-system library exporting a name the floor function catalog knows (write), with a
 * signature of its own that reads rcx: tests/objc/fixtures/entry-elsewhere.S binds to it. Never run. */
long write(long a, long b, long c, long d) { return a + b + c + d; }
