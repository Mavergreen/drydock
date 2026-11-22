// A weakly imported class_addMethod, tested for NULL through its GOT slot: absent, the slot holds 0, so both ways.
	.weak_reference _class_addMethod
	.text
	.globl	_q_weak
_q_weak:
	movq	_class_addMethod@GOTPCREL(%rip), %rax
	testq	%rax, %rax
	je	Lw
	xorl	%edi, %edi
	callq	*%rax
Lw:	retq
