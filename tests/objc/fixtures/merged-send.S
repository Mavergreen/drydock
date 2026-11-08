/* Fixture: one objc_msgSend call that a compiler merged from the sends of two paths, the shape
 * Apple clang 21 -Os gives Recaulk's `c ? [[x mutableCopy] autorelease] : [NSMutableDictionary
 * dictionary]` (tests/fixtures/objc-api/open-urls-merge.S +0x775): each path loads the address of
 * its own selector reference and its receiver, and the join loads the selector through that
 * address and calls. Then a send to the merged call's result. Hand-assembled so the shape does
 * not depend on which compiler builds it. Never executed.
 *   FORM 0  +[NSArray array] on one path, +[NSArray arrayWithObject:] on the other; both results
 *           are NSArray, so the count sent to the result closes
 *   FORM 1  as 0, but the second path's selector comes from __data, a value the reader does not
 *           model: the call is not split, its selector stays unknown
 *   FORM 2  as 0, but the second path is +[NSDictionary dictionary]: the result is NSArray on one
 *           path and NSDictionary on the other, so its count stays open
 *   FORM 3  the paths make two different sends, and the join sends count to whichever result
 *           arrived: one selector, two receivers, one count per path
 *   FORM 4  as 3, but the paths make +[NSArray array] and +[NSArray arrayWithObject:]: two sends of
 *           -[NSArray count] at one call, which only their paths tell apart */
	.section __TEXT,__objc_methname,cstring_literals
L_name_array:
	.asciz "array"
L_name_awo:
	.asciz "arrayWithObject:"
L_name_dictionary:
	.asciz "dictionary"
L_name_count:
	.asciz "count"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_sel_array:
	.quad L_name_array
L_sel_awo:
	.quad L_name_awo
L_sel_dictionary:
	.quad L_name_dictionary
L_sel_count:
	.quad L_name_count
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_cls_NSArray:
	.quad _OBJC_CLASS_$_NSArray
L_cls_NSDictionary:
	.quad _OBJC_CLASS_$_NSDictionary
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

/* id merged(int which, id object) */
	.globl _merged
	.p2align 4
_merged:
	pushq	%rbp
	movq	%rsp, %rbp
	pushq	%rbx
	pushq	%rax
	movq	%rsi, %rdx
	testl	%edi, %edi
	je	L_second
#if FORM >= 3
	movq	L_cls_NSArray(%rip), %rdi
	movq	L_sel_array(%rip), %rsi
	callq	*_objc_msgSend@GOTPCREL(%rip)
	jmp	L_join
L_second:
#if FORM == 4
	movq	L_cls_NSArray(%rip), %rdi
	movq	L_sel_awo(%rip), %rsi
#else
	movq	L_cls_NSDictionary(%rip), %rdi
	movq	L_sel_dictionary(%rip), %rsi
#endif
	callq	*_objc_msgSend@GOTPCREL(%rip)
L_join:
#else
	leaq	L_sel_array(%rip), %rax
	movq	L_cls_NSArray(%rip), %rdi
	jmp	L_join
L_second:
#if FORM == 1
	leaq	L_opaque(%rip), %rax
	movq	L_cls_NSArray(%rip), %rdi
#elif FORM == 2
	leaq	L_sel_dictionary(%rip), %rax
	movq	L_cls_NSDictionary(%rip), %rdi
#else
	leaq	L_sel_awo(%rip), %rax
	movq	L_cls_NSArray(%rip), %rdi
#endif
L_join:
	movq	(%rax), %rsi
	callq	*_objc_msgSend@GOTPCREL(%rip)
#endif
	movq	%rax, %rdi
	movq	L_sel_count(%rip), %rsi
	callq	*_objc_msgSend@GOTPCREL(%rip)
	addq	$8, %rsp
	popq	%rbx
	popq	%rbp
	retq
