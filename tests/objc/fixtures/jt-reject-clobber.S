/* Fixture: the shape of upstream iTerm2 3.0.15's +[PseudoTerminal drawArrangementPreview:screenFrames:]
 * (its table at 0x1001c1f4c): objc_msgSend loaded from its GOT slot into r12 before the switch and
 * called through in every case, the index copied before its bound check, and SSE arithmetic between
 * the ja and the table's lea:
 *     mov eax, r14d ; cmp r14d, N-1 ; ja default ; movapd ; divpd ;
 *     lea rcx, [rip + table] ; movsxd rax, dword [rcx + rax*4] ; add rax, rcx ; jmp rax
 * No data-in-code entry marks the table (tests/objc/objc-reader-test.sh links -no_data_in_code_info).
 * Hand-assembled so the shape does not depend on which compiler builds it. Never executed.
 *
 *   CLOBBER 0  as above: a jump table, its three cases start from the state at its jmp: four sends
 *   CLOBBER 1  the twin: a cvttsd2si between the ja and the lea writes eax, the table's index, so the
 *              bound no longer bounds it: not a table this reader takes apart, so the cases stay
 *              reached only indirectly: cannot-measure
 *   CLOBBER 2  the twin by a move: `movl %ebx, %eax` between the ja and the lea writes the index from a
 *              register that is not the compared one (r14) nor a copy of it: cannot-measure
 *   CLOBBER 3  the bound by `subl $2, %eax` on the index itself: eax then holds the difference, not
 *              the bounded value, so the index is unbound: cannot-measure
 *   CLOBBER 4  the bound by `subl $2, %r14d` after the copy to eax: the copy is the bounded value,
 *              a table as in CLOBBER 0: four sends
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
	pushq %r14
	pushq %r12
	movl %edi, %r14d
	movq _objc_msgSend@GOTPCREL(%rip), %r12
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
	callq *%r12
	movl %r14d, %eax
#if CLOBBER == 3
	subl $2, %eax
#elif CLOBBER == 4
	subl $2, %r14d
#else
	cmpl $2, %r14d
#endif
	ja Ldefault
	movapd %xmm0, %xmm2
	divpd %xmm1, %xmm2
#if CLOBBER == 1
	cvttsd2si %xmm2, %eax
#elif CLOBBER == 2
	movl %ebx, %eax
#endif
	leaq Ltable(%rip), %rcx
	movslq (%rcx,%rax,4), %rax
	addq %rcx, %rax
	jmpq *%rax
Lcase0:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	callq *%r12
	jmp Ldefault
Lcase1:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
	callq *%r12
	jmp Ldefault
Lcase2:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	callq *%r12
Ldefault:
	xorl %eax, %eax
	popq %r12
	popq %r14
	popq %rbp
	retq
	.p2align 2
Ltable:
	.long Lcase0-Ltable
	.long Lcase1-Ltable
	.long Lcase2-Ltable
