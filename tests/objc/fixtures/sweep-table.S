/* Fixture: a function the decoder stops in at once (0x06 is no x86_64 instruction), then a constant
 * table. SWEEP_VALUE is chosen after a first link so that, as a rel32 at _sweep_fn + 1, it names the
 * image's _method_getName lazy pointer: tests/objc/lib/objc_fixture_sweep.sh. Never executed.
 * The variants (one -D each) refuse attestation for one reason apiece:
 *   SWEEP_STRADDLE  the rel32 crosses into the next atom (linked without function starts, so one remainder
 *                   spans both);
 *   SWEEP_RELOC     the rel32 is a relocation, naming _method_getName's GOT entry;
 *   SWEEP_SAME      the rel32 names a fetch function in this member's own section: no fetch-like target
 *                   can sit inside _sweep_fn's own atom, so it is the next function of the member;
 *   SWEEP_RELAX     a GOT load lld relaxes to a leaq, so its opcode window over 8d 05 01 00 differs from the
 *                   object's 8b with no relocation covering it; it names the _method_getName stub, which the
 *                   two spaces place 0x10594 bytes past _sweep_fn. */
#ifndef SWEEP_VALUE
#define SWEEP_VALUE 0
#endif
	.text
	.globl _sweep_fn
	.p2align 4
_sweep_fn:
	.byte 0x06
#if defined(SWEEP_STRADDLE)
	.byte (SWEEP_VALUE) & 0xff, ((SWEEP_VALUE) >> 8) & 0xff
	.globl _sweep_next
_sweep_next:
	.byte ((SWEEP_VALUE) >> 16) & 0xff, ((SWEEP_VALUE) >> 24) & 0xff
	.space 11, 0x90
#elif defined(SWEEP_RELOC)
	.long _method_getName@GOTPCREL
	.space 11, 0x90
#elif defined(SWEEP_SAME)
	.long 11
	.space 11, 0x90
	.globl __RNvMNtNtCs2ucXwfqiSr7_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch
__RNvMNtNtCs2ucXwfqiSr7_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch:
	ret
#elif defined(SWEEP_RELAX)
	movq _sweep_x@GOTPCREL(%rip), %rax
	.space 0x10001, 0x90
	.globl _sweep_x
_sweep_x:
	.space 0x58a, 0x90
	ret
#else
	.long SWEEP_VALUE
	.space 11, 0x90
#endif
