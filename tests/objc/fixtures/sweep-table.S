/* Fixture: a function the decoder stops in at once (0x06 is no x86_64 instruction), then a constant
 * table. SWEEP_VALUE is chosen after a first link so that, as a rel32 at _sweep_fn + 1, it names the
 * image's _method_getName lazy pointer: tests/objc/lib/objc_fixture_sweep.sh. Never executed. */
#ifndef SWEEP_VALUE
#define SWEEP_VALUE 0
#endif
	.text
	.globl _sweep_fn
	.p2align 4
_sweep_fn:
	.byte 0x06
	.long SWEEP_VALUE
	.space 11, 0x90
