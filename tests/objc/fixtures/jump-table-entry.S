/* Fixture: a switch whose jump table sits inline in __text with no data-in-code entry marking
 * it, as Apple clang 6 writes one at -O0 for shipyard's own updater (updater/main.m.in, main):
 *     cmp idx, N-1 ; ja default ; lea R, [rip + table] ; movsxd D, dword [R + idx*4] ;
 *     add D, R ; jmp D
 * with the objc entry point held across the switch and called in every case. Hand-assembled so
 * the shape does not depend on which compiler builds it. Never executed.
 *
 *   FORM 0  the entry point in a callee-saved register, called through in each case: four sends
 *   FORM 1  as FORM 0, spilled to a frame slot and reloaded in each case (the -O0 shape): four
 *   FORM 2  as FORM 0, but the bound says four cases and the table holds three: not a table this
 *           reader takes apart, so the cases stay reached only indirectly: cannot-measure
 */
	.section __TEXT,__objc_methname,cstring_literals
L_sel_description:
	.asciz "description"
L_sel_hash:
	.asciz "hash"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_selref_description:
	.quad L_sel_description
L_selref_hash:
	.quad L_sel_hash
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref_NSObject:
	.quad _OBJC_CLASS_$_NSObject
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0

	.text
	.globl _main
	.p2align 4
_main:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r12
	pushq %rbx
	subq $16, %rsp
	movl %edi, %ebx
	movq _objc_msgSend@GOTPCREL(%rip), %r12
#if FORM == 1
	movq %r12, -24(%rbp)
#endif
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
	callq *%r12
	movl %ebx, %eax
#if FORM == 2
	cmpl $3, %eax
#else
	cmpl $2, %eax
#endif
	ja Ldefault
	leaq Ltable(%rip), %rcx
	movslq (%rcx,%rax,4), %rax
	addq %rcx, %rax
	jmpq *%rax
Lcase0:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
#if FORM == 1
	movq -24(%rbp), %rax
	callq *%rax
#else
	callq *%r12
#endif
	jmp Ldefault
Lcase1:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
#if FORM == 1
	movq -24(%rbp), %rax
	callq *%rax
#else
	callq *%r12
#endif
	jmp Ldefault
Lcase2:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
#if FORM == 1
	movq -24(%rbp), %rax
	callq *%rax
#else
	callq *%r12
#endif
Ldefault:
	xorl %eax, %eax
	addq $16, %rsp
	popq %rbx
	popq %r12
	popq %rbp
	retq
	.p2align 2
Ltable:
	.long Lcase0-Ltable
	.long Lcase1-Ltable
	.long Lcase2-Ltable
