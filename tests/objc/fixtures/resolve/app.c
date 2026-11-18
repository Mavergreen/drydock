/* Fixture: drydock-objc resolve. Functions named by hand-written Rust v0 symbols (asm labels), so the
 * test needs no Rust toolchain. Crate disambiguators: app 7Ab; demo 1V1 (1.0.0) and 2V2 (2.0.0),
 * whose own code is demo.c, built once per version; other 9Zz and other2 8Yy instantiate generics.
 * Linked against the pinned 10.9 SDK, read as bytes, never executed. */
#define F(c, sym) long c(void) __asm__(sym); __attribute__((noinline, used)) long c(void) { return __LINE__; }

F(unique, "__RNvCs7Ab_3app6unique")                                  /* app::unique */

/* app::id::<u8>: one generic instance, four copies */
F(id_local, "__RINvCs7Ab_3app2idhE")
F(id_other, "__RINvCs7Ab_3app2idhECs9Zz_5other")
F(id_other_llvm, "__RINvCs7Ab_3app2idhECs9Zz_5other.llvm.1234ABCD")
F(id_other2_cold, "__RINvCs7Ab_3app2idhECs8Yy_6other2.cold")

/* app::dup: two functions, the second's identifier disambiguated (s_) */
F(dup, "__RNvCs7Ab_3app3dup")
F(dup_again, "__RNvCs7Ab_3apps_3dup")

/* app::part: one mangling, but a suffix that is neither .llvm.N nor .cold */
F(part, "__RNvCs7Ab_3app4part")
F(part_split, "__RNvCs7Ab_3app4part.part.0")

/* demo::wrap::<u8>: copies under demo 1.0.0 and demo 2.0.0 */
F(wrap_v1, "__RINvCs1V1_4demo4wraphECs7Ab_3app")
F(wrap_v2, "__RINvCs2V2_4demo4wraphECs7Ab_3app")
F(wrap_v2_other, "__RINvCs2V2_4demo4wraphECs9Zz_5other")

/* app::table: data, not a function */
__attribute__((used)) long table[2] __asm__("__RNvCs7Ab_3app5table") = { 1, 2 };

extern long demo_helper_v1(void) __asm__("__RNvCs1V1_4demo6helper");
extern long demo_helper_v2(void) __asm__("__RNvCs2V2_4demo6helper");
int main(int argc, char **argv) {
    (void)argv;
    if (argc > 99) return (int)(unique() + id_local() + id_other() + id_other_llvm() + id_other2_cold() + dup() + dup_again() + part() + part_split() +
                                wrap_v1() + wrap_v2() + wrap_v2_other() + table[1] + demo_helper_v1() + demo_helper_v2());
    return 0;
}
