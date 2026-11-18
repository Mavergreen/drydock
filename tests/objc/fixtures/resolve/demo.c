/* Fixture: drydock-objc resolve, crate demo's own code (app.c), built once per version with DIS its
 * disambiguator. */
#define S2(x) #x
#define S(x) S2(x)
long helper(void) __asm__("__RNvCs" S(DIS) "_4demo6helper");   /* demo::helper */
__attribute__((noinline, used)) long helper(void) { return 1; }
