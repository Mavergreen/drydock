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
 *   CLOBBER 5  the table's base copied after its lea, and the load and add through the copy, the
 *              lea's register then reused for the target (iTerm2 3.0.15's _CoreSearch, its table at
 *              0x1000cc7ec): lea rax, [rip + table] ; mov rdx, rax ; movsxd rax, dword [rdx + rcx*4] ;
 *              add rax, rdx ; jmp rax: a table as in CLOBBER 0: four sends
 *   CLOBBER 6  the twin: as 5, but `addq $4, %rdx` after the copy, so rdx no longer holds the
 *              table's address: cannot-measure
 *   CLOBBER 7  a byte move of an immediate into a register the table does not use between the ja and
 *              the lea (iTerm2 3.0.15's -[PseudoTerminal canonicalizeWindowFrame], its table at
 *              0x1001c6644: movb $0x1, %r14b): a table as in CLOBBER 0: four sends
 *   CLOBBER 8  the twin: `movl $1, %eax` there writes the index: cannot-measure
 *   CLOBBER 9  the load into the table's own register: movsxd rcx, [rcx + rax*4] ; add rcx, rcx ;
 *              jmp rcx adds the entry to itself, not to the table's address: cannot-measure
 *   CLOBBER 10 the table's lea hoisted out of a loop, into another block than its jmp (iTerm2
 *              3.0.15's -[iTermTipCardViewController performLayoutForWidth:dry:origin:], its table
 *              at 0x1001e3180): not a table this reader takes apart, so each case's call through r12
 *              is cannot-measure "in code reached only through an indirect jump this reader does
 *              not follow"
 *   CLOBBER 11 the twin: `movb $1, %ah` between the ja and the lea writes bits 8..15 of eax, the
 *              index (no REX: register 4 is ah, not spl): cannot-measure
 *   CLOBBER 12 the twin: `movb %bl, %ah` in its 8A form there, the same: cannot-measure
 *   CLOBBER 13 the twin: a 32-bit copy of the table's address, `movl %eax, %edx`, and the load and
 *              add through it: the copy drops the address's upper half: cannot-measure
 *   CLOBBER 14 as 0, with the first case copying r12 to rax (`movq %r12, %rax`), for
 *              tests/objc/objc-compare-test.sh's register copy in a table's cases: four sends
 *   CLOBBER 15 the twin: `movl %r14d, %eax ; cmpl $2, %eax` and the load indexed by r14: the cmp bounds
 *              r14's lower half only, its upper half is whatever it was: cannot-measure
 *   CLOBBER 16 the twin: `movq %rdi, %r14 ; cmpl $2, %r14d` and the load indexed by r14: a 32-bit cmp
 *              of a register whose last write did not zero-extend it: cannot-measure
 *   CLOBBER 17 the twin: `movq %r14, %rax ; cmpl $2, %eax` and the load indexed by rax: the same, by a
 *              64-bit copy: cannot-measure
 *   CLOBBER 18 as 16, but `movl %edi, %r14d`, which zeroes r14's upper half: a table as in CLOBBER 0:
 *              four sends
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
#if CLOBBER == 10
	leaq Ltable(%rip), %rcx
Lloop:
#endif
#if CLOBBER == 15
	movl %r14d, %eax
	cmpl $2, %eax
#elif CLOBBER == 16
	movq %rdi, %r14
	cmpl $2, %r14d
#elif CLOBBER == 17
	movq %r14, %rax
	cmpl $2, %eax
#elif CLOBBER == 18
	movl %edi, %r14d
	cmpl $2, %r14d
#else
	movl %r14d, %eax
#if CLOBBER == 3
	subl $2, %eax
#elif CLOBBER == 4
	subl $2, %r14d
#else
	cmpl $2, %r14d
#endif
#endif
	ja Ldefault
	movapd %xmm0, %xmm2
	divpd %xmm1, %xmm2
#if CLOBBER == 1
	cvttsd2si %xmm2, %eax
#elif CLOBBER == 2
	movl %ebx, %eax
#elif CLOBBER == 7
	movb $1, %bl
#elif CLOBBER == 8
	movl $1, %eax
#elif CLOBBER == 11
	movb $1, %ah
#elif CLOBBER == 12
	.byte 0x8a, 0xe3		/* movb %bl, %ah */
#endif
#if CLOBBER == 5 || CLOBBER == 6 || CLOBBER == 13
	movl %eax, %ecx
	leaq Ltable(%rip), %rax
#if CLOBBER == 13
	movl %eax, %edx
#else
	movq %rax, %rdx
#endif
#if CLOBBER == 6
	addq $4, %rdx
#endif
	movslq (%rdx,%rcx,4), %rax
	addq %rdx, %rax
#elif CLOBBER == 9
	leaq Ltable(%rip), %rcx
	movslq (%rcx,%rax,4), %rcx
	addq %rcx, %rcx
	jmpq *%rcx
#else
#if CLOBBER != 10
	leaq Ltable(%rip), %rcx
#endif
#if CLOBBER == 15 || CLOBBER == 16 || CLOBBER == 18
	movslq (%rcx,%r14,4), %rax
#else
	movslq (%rcx,%rax,4), %rax
#endif
	addq %rcx, %rax
#endif
#if CLOBBER != 9
	jmpq *%rax
#endif
Lcase0:
#if CLOBBER == 14
	movq %r12, %rax
#endif
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
#if CLOBBER == 10
	jmp Lloop
#endif
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
