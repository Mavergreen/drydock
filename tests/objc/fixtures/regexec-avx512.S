// An AVX-512 instruction on the explored path of an entry: the registration executor refuses it by address.
	.text
	.globl	_avx512_entry
_avx512_entry:
	pushq	%rbp
	movq	%rsp, %rbp
	.globl	_avx512_here
_avx512_here:
	vpaddd	%zmm1, %zmm2, %zmm3
	popq	%rbp
	retq
