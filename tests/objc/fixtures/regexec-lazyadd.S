// An add whose result rax holds, an instruction not reading it, then: cmc (reading no register, but a form the read
// set does not classify), a write of rax, or a return. Each is entered with rdi bound to a class
// (tests/objc/objc-regexec-test.sh).
	.text
	.globl	_u_cmc, _u_cmc_here, _u_write, _u_ret, _u_ret_here
_u_cmc:
	callq	_class_addMethod
	movl	$0, %ecx
_u_cmc_here:
	cmc
	xorl	%eax, %eax
	retq
_u_write:
	callq	_class_addMethod
	movl	$0, %ecx
	movl	$0, %eax
	retq
_u_ret:
	callq	_class_addMethod
	movl	$0, %ecx
_u_ret_here:
	retq
