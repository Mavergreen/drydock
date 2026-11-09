/* Fixture: the unsafe twins of tests/objc/fixtures/entry-copy.S. Each function holds objc_msgSend
 * (or objc_msgSend_stret) from its GOT slot in r15, copies it to rcx and on to rbx, as
 * -[RecaulkTabPSMTabBarControl setDelegate:] does, and then makes one call at which rcx, still the
 * entry point, may be read as an argument. Each is cannot-measure at that call: "objc entry point
 * in rcx is passed as an argument". Never executed.
 *
 *   _unknown_colon      a send of a colon selector no catalog or method list declares: unbounded
 *   _format             a send of stringWithFormat:, which is variadic: unbounded
 *   _uncounted          a send of NSBitmapImageRep's initWithBitmapDataPlanes:...bitsPerPixel:,
 *                       whose eleven parameter GPRs are more than six: unbounded, by name
 *   _stret_shift        an objc_msgSend_stret send of rectOfRow: (one parameter): the hidden
 *                       result pointer shifts it, so rdi, rsi, rdx and rcx -- rcx IS its argument
 *   _c_noreturn_params  a call to __assert_rtn, which never returns and takes four parameters:
 *                       rcx is its fourth (spec: usr/include/assert.h)
 *
 * The fifth twin, objc_msgSend passed as a real function pointer to qsort, is compiled C:
 * tests/objc/fixtures/entry-escape.m. */
	.section __TEXT,__cstring,cstring_literals
L_func:
	.asciz "c_noreturn_params"
L_file:
	.asciz "entry-escape.S"
	.section __TEXT,__objc_methname,cstring_literals
L_sel_unknown:
	.asciz "zzNoSuchSelector:"
L_sel_format:
	.asciz "stringWithFormat:"
L_sel_rectOfRow:
	.asciz "rectOfRow:"
L_sel_uncounted:
	.asciz "initWithBitmapDataPlanes:pixelsWide:pixelsHigh:bitsPerSample:samplesPerPixel:hasAlpha:isPlanar:colorSpaceName:bitmapFormat:bytesPerRow:bitsPerPixel:"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_selref_unknown:
	.quad L_sel_unknown
L_selref_format:
	.quad L_sel_format
L_selref_rectOfRow:
	.quad L_sel_rectOfRow
L_selref_uncounted:
	.quad L_sel_uncounted
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref_NSString:
	.quad _OBJC_CLASS_$_NSString
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0

	.text
	.globl _main
	.p2align 4
_main:
	pushq %rbp
	movq %rsp, %rbp
	callq _unknown_colon
	callq _format
	callq _uncounted
	callq _stret_shift
	callq _c_noreturn_params
	xorl %eax, %eax
	popq %rbp
	retq

	.p2align 4
_unknown_colon:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r15
	pushq %rbx
	movq _objc_msgSend@GOTPCREL(%rip), %r15
	movq %r15, %rcx
	movq %rcx, %rbx
	movq L_classref_NSString(%rip), %rdi
	movq L_selref_unknown(%rip), %rsi
	xorl %edx, %edx
	callq *%rbx
	popq %rbx
	popq %r15
	popq %rbp
	retq

	.p2align 4
_format:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r15
	pushq %rbx
	movq _objc_msgSend@GOTPCREL(%rip), %r15
	movq %r15, %rcx
	movq %rcx, %rbx
	movq L_classref_NSString(%rip), %rdi
	movq L_selref_format(%rip), %rsi
	xorl %edx, %edx
	xorl %eax, %eax
	callq *%rbx
	popq %rbx
	popq %r15
	popq %rbp
	retq

	.p2align 4
_uncounted:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r15
	pushq %rbx
	movq _objc_msgSend@GOTPCREL(%rip), %r15
	movq %r15, %rcx
	movq %rcx, %rbx
	movq L_classref_NSString(%rip), %rdi
	movq L_selref_uncounted(%rip), %rsi
	xorl %edx, %edx
	callq *%rbx
	popq %rbx
	popq %r15
	popq %rbp
	retq

	.p2align 4
_stret_shift:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r15
	pushq %r14
	pushq %rbx
	pushq %rax
	movq %rdi, %r14
	movq _objc_msgSend_stret@GOTPCREL(%rip), %r15
	movq %r15, %rcx
	movq %rcx, %rbx
	movq %r14, %rdi
	movq L_classref_NSString(%rip), %rsi
	movq L_selref_rectOfRow(%rip), %rdx
	callq *%rbx
	addq $8, %rsp
	popq %rbx
	popq %r14
	popq %r15
	popq %rbp
	retq

	.p2align 4
_c_noreturn_params:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r15
	pushq %rbx
	movq _objc_msgSend@GOTPCREL(%rip), %r15
	movq %r15, %rcx
	movq %rcx, %rbx
	leaq L_func(%rip), %rdi
	leaq L_file(%rip), %rsi
	movl $1, %edx
	callq ___assert_rtn
