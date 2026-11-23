// Entries that each take bits of a writable image address (_ls) by a route other than arithmetic on it, and hand the
// result to _lh, a helper the executor does not follow (tests/objc/objc-regexec-test.sh): each must escape _ls.
// _l_base is the direct hand-off; _l_walk walks a table by comparing a row pointer to its end, which stays known.
	.text
	.globl	_lh
_lh:	movl	$3, (%rdi)
	retq

	.globl	_l_base
_l_base:
	leaq	_ls(%rip), %rdi
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_l_shcl                 // each bit of an address plus an unknown zero copied through a shift count
_l_shcl:
	callq	_arc4random
	shrq	$40, %rax
	leaq	_ls(%rip), %r10
	addq	%rax, %r10
	xorl	%edx, %edx
	xorl	%r9d, %r9d
1:	movq	%r9, %rcx
	movq	%r10, %rax
	shrq	%cl, %rax
	andl	$1, %eax
	movl	%eax, %ecx
	movl	$1, %r8d
	shlq	%cl, %r8
	decq	%r8
	movq	%r9, %rcx
	shlq	%cl, %r8
	orq	%r8, %rdx
	incq	%r9
	cmpq	$48, %r9
	jne	1b
	xorl	%r10d, %r10d
	xorl	%eax, %eax
	xorl	%ecx, %ecx
	movq	%rdx, %rdi
	xorl	%edx, %edx
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_l_sbb                  // each bit of an address plus an unknown zero copied through the carry flag
_l_sbb:
	callq	_arc4random
	shrq	$40, %rax
	leaq	_ls(%rip), %r10
	addq	%rax, %r10
	xorl	%edx, %edx
	xorl	%r9d, %r9d
1:	movq	%r9, %rcx
	movq	%r10, %rax
	shrq	%cl, %rax
	andl	$1, %eax
	movl	$0, %r8d
	cmpq	$1, %rax
	sbbq	%r8, %r8
	incq	%r8
	shlq	%cl, %r8
	orq	%r8, %rdx
	incq	%r9
	cmpq	$48, %r9
	jne	1b
	xorl	%r10d, %r10d
	xorl	%eax, %eax
	xorl	%ecx, %ecx
	movq	%rdx, %rdi
	xorl	%edx, %edx
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_l_setcc                // two bits of an address through setcc, plus an unknown zero
_l_setcc:
	callq	_arc4random
	shrq	$40, %rax
	movq	%rax, %rbx
	leaq	_ls(%rip), %rsi
	movq	%rsi, %rax
	shrq	$8, %rax
	testb	$1, %al
	movl	$0, %edx
	setne	%dl
	shlq	$8, %rdx
	movq	%rsi, %rax
	shrq	$9, %rax
	testb	$1, %al
	movl	$0, %r8d
	setne	%r8b
	shlq	$9, %r8
	orq	%r8, %rdx
	xorl	%esi, %esi
	xorl	%eax, %eax
	addq	%rbx, %rdx
	movq	%rdx, %rdi
	xorl	%edx, %edx
	xorl	%r8d, %r8d
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_l_ctl                  // a bit of an address rebuilt by a branch on it and a constant
_l_ctl:
	leaq	_ls(%rip), %rsi
	xorl	%edx, %edx
	testl	$0x100, %esi
	je	1f
	orq	$0x100, %rdx
1:	xorl	%esi, %esi
	movq	%rdx, %rdi
	xorl	%edx, %edx
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_l_overlap              // a frame cell holding an address, its low byte overwritten, read back whole
_l_overlap:
	subq	$24, %rsp
	leaq	_ls(%rip), %rax
	movq	%rax, (%rsp)
	movb	$0, (%rsp)
	movq	(%rsp), %rdi
	movq	$0, (%rsp)
	xorl	%eax, %eax
	callq	_lh
	addq	$24, %rsp
	xorl	%eax, %eax
	retq

	.globl	_l_dead                 // a followed callee leaves an address in its dead frame; the caller reads it back
_l_dead:
	callq	_lf
	movq	-16(%rsp), %rdi
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_l_dead2                // likewise, at an unknown index
_l_dead2:
	callq	_arc4random
	shrq	$40, %rax
	movq	%rax, %rbx
	callq	_lf
	movq	-16(%rsp,%rbx,8), %rdi
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_l_import               // after the same spill, an imported datum read through its GOT slot: no escape
_l_import:
	callq	_lf
	movq	___stderrp@GOTPCREL(%rip), %rax
	movq	8(%rax), %rdi
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_l_impidx               // likewise at an unknown index from it: the dead frame may be read
_l_impidx:
	callq	_arc4random
	shrq	$40, %rax
	movq	%rax, %rbx
	callq	_lf
	movq	___stderrp@GOTPCREL(%rip), %rax
	movq	(%rax,%rbx,8), %rdi
	callq	_lh
	xorl	%eax, %eax
	retq

	.globl	_lf
_lf:	leaq	_ls(%rip), %rax
	movq	%rax, -8(%rsp)
	xorl	%eax, %eax
	retq
	callq	_objc_getClass          // never run: makes _lf a function the executor follows

	.globl	_l_walk                 // rows walked to the table's end, each tested non-NULL: one path
_l_walk:
	leaq	_lt(%rip), %rbx
	leaq	_lt+32(%rip), %r12
1:	testq	%rbx, %rbx
	je	2f
	movq	(%rbx), %rax
	addq	$8, %rbx
	cmpq	%r12, %rbx
	jne	1b
	xorl	%eax, %eax
	xorl	%ebx, %ebx
	xorl	%r12d, %r12d
	retq
2:	ud2

	.section	__DATA,__const
	.p2align	3
_lt:	.quad	0, 0, 0, 0
	.data
	.p2align	8
	.globl	_ls
_ls:	.quad	0
