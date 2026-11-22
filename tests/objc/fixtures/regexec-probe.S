// Entries that probe the registration executor's soundness (tests/objc/objc-regexec-test.sh), from its review.
	.text
	.globl	_p_xor                    // xor of a symbol with itself is zero: the add below is reached
_p_xor:
	pushq	%rbx
	leaq	Lname(%rip), %rdi
	callq	_objc_getClass
	movq	%rax, %rbx
	movq	%rax, %rcx
	xorq	%rbx, %rcx
	jne	Lne
	movq	%rbx, %rdi
	leaq	Lname(%rip), %rsi
	xorl	%edx, %edx
	xorl	%ecx, %ecx
	callq	_class_addMethod
Lne:
	popq	%rbx
	retq
	.globl	_p_storeread              // a value stored into image data reads back as stored
_p_storeread:
	movl	$5, _g(%rip)
	movl	_g(%rip), %eax
	cmpl	$5, %eax
	jne	Lsr
	retq
Lsr:
	retq
	.globl	_p_foreign                // a callee reaching class_addMethod through code outside the ranges
_p_foreign:
	callq	_p_helper
	retq
	.globl	_p_helper
_p_helper:
	jmp	_p_far
	.globl	_p_indirect               // a callee reaching class_addMethod through a computed jump
_p_indirect:
	callq	_p_helper2
	retq
	.globl	_p_helper2
_p_helper2:
	leaq	_p_adder(%rip), %rax
	jmpq	*%rax
	.globl	_p_adder
_p_adder:
	xorl	%edi, %edi
	jmp	_class_addMethod
	.globl	_p_cbw                    // cbw sign-extends al: 0xff becomes 0xffff, and the add is reached
_p_cbw:
	movl	$0xff, %eax
	cbtw
	cmpw	$-1, %ax
	jne	Lcbw
	xorl	%edi, %edi
	callq	_class_addMethod
Lcbw:
	retq
	.globl	_p_uforks                 // a guard on an unmodelled call's answer: decided by forking
_p_uforks:
	callq	_objc_msgSend
	testb	%al, %al
	jne	Luf
	xorl	%edi, %edi
	callq	_class_addMethod
Luf:
	retq
	.globl	_p_trap                   // a path that adds, then traps
_p_trap:
	xorl	%edi, %edi
	callq	_class_addMethod
	ud2
	.globl	_p_clobber                // a summarised callee clobbers the caller-saved registers
_p_clobber:
	leaq	Lname(%rip), %rdi
	callq	_objc_getClass
	movq	%rax, %rcx
	callq	_p_plain
	movq	%rcx, %rdi
	callq	_class_addMethod
	retq
	.globl	_p_plain
_p_plain:
	retq
	.globl	_p_chain                  // a mutator two direct calls down is followed
_p_chain:
	callq	_p_mid
	retq
	.globl	_p_mid
_p_mid:
	callq	_p_leaf
	retq
	.globl	_p_leaf
_p_leaf:
	xorl	%edi, %edi
	jmp	_class_addMethod
	.globl	_p_hoist                  // objc_msgSend hoisted from its GOT slot into a register, then called through it
_p_hoist:
	pushq	%r12
	movq	_objc_msgSend@GOTPCREL(%rip), %r12
	callq	*%r12
	xorl	%edi, %edi
	callq	_class_addMethod
	popq	%r12
	retq
	.section	__TEXT,__text_other,regular,pure_instructions
	.globl	_p_far
_p_far:
	xorl	%edi, %edi
	jmp	_class_addMethod
	.section	__TEXT,__cstring,cstring_literals
Lname:	.asciz	"NSWindow"
	.data
	.p2align 2
_g:	.long 0
