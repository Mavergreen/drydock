/* Fixture: a merged send with a copy of objc_msgSend in an argument register, the shape of
 * upstream iTerm2 3.0.15's -[iTermEditKeyActionWindowController ok:] at 0x1001b1772: each path
 * loads its own selector, every path leaves a copy of the entry point in rdx (`movq %rdx, %rbx`
 * there; here `movq %rbx, %rdx`), and the join calls through rbx. At the join the paths disagree
 * on the selector, so the meet has none and all six registers would count as arguments. Read per
 * path ("Merged calls"), each path's selector bounds them. Hand-assembled so the shape does not
 * depend on which compiler builds it. Never executed.
 *   FORM 0  +[NSArray array] on one path, +[NSArray description] on the other: no parameters, so
 *           rdx is no argument on either path: measured
 *   FORM 1  the twin: the second path sends arrayWithObject:, whose one parameter is rdx: the entry
 *           point is passed as an argument on that path: cannot-measure
 *   FORM 2  the twin: the second path's selector comes from __data, a value the reader does not
 *           model: that path's bound is unknown: cannot-measure
 */
	.section __TEXT,__objc_methname,cstring_literals
L_name_array:
	.asciz "array"
L_name_description:
	.asciz "description"
L_name_awo:
	.asciz "arrayWithObject:"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_sel_array:
	.quad L_name_array
L_sel_description:
	.quad L_name_description
L_sel_awo:
	.quad L_name_awo
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_cls_NSArray:
	.quad _OBJC_CLASS_$_NSArray
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0
	.section __DATA,__data
	.p2align 3
L_opaque:
	.quad 0

	.text
	.globl _main
	.p2align 4
_main:
	xorl	%eax, %eax
	retq

/* id merged_arg(int which) */
	.globl _merged_arg
	.p2align 4
_merged_arg:
	pushq	%rbp
	movq	%rsp, %rbp
	pushq	%rbx
	pushq	%rax
	movq	_objc_msgSend@GOTPCREL(%rip), %rbx
	movq	L_cls_NSArray(%rip), %rdi
	testl	%edi, %edi
	je	L_second
	movq	L_sel_array(%rip), %rsi
	movq	%rbx, %rdx
	jmp	L_join
L_second:
#if FORM == 1
	movq	L_sel_awo(%rip), %rsi
#elif FORM == 2
	movq	L_opaque(%rip), %rsi
#else
	movq	L_sel_description(%rip), %rsi
#endif
	movq	%rbx, %rdx
L_join:
	callq	*%rbx
	addq	$8, %rsp
	popq	%rbx
	popq	%rbp
	retq
