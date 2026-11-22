// Entries that each reach one limit of the registration executor (tests/objc/objc-regexec-test.sh).
	.text
	.globl	_lim_unverified           // an 8-byte read of a nonzero slot no rebase covers
_lim_unverified:
	movq	_lim_quad(%rip), %rax
	retq
	.globl	_lim_store                // a store through an address nothing names
_lim_store:
	movq	%rax, (%rbx)
	retq
	.globl	_lim_foreign              // a direct call to code outside the provider's ranges, no import
_lim_foreign:
	callq	_lim_elsewhere
	retq
	.globl	_lim_depth                // followed calls without end (each reaches a modelled import)
_lim_depth:
	callq	_lim_depth
	callq	_objc_getClass
	retq
	.globl	_lim_loop                 // a loop without end
_lim_loop:
	jmp	_lim_loop
	.globl	_lim_ret                  // a return to an address no followed call pushed
_lim_ret:
	pushq	%rax
	retq
	.section	__TEXT,__text_other,regular,pure_instructions
	.globl	_lim_elsewhere
_lim_elsewhere:
	retq
	.section	__TEXT,__const
	.p2align	3
_lim_quad:
	.quad	0x123456789
