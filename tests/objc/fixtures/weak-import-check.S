/* Fixture: the weak-import check libarclite (linked into upstream iTerm2 3.0.15, __ARCLite__load at
 * 0x1001f5da1) makes before it patches the runtime: `cmpq $0, GOT(_objc_readClassPair)` asks only
 * whether the weak import bound, and writes nothing but the flags. Then a send, so the function
 * holds an objc entry point. Hand-assembled so the shape does not depend on which compiler builds
 * it. Never executed.
 *   FORM 0  the check: measured
 *   FORM 1  the twin: `addq GOT(_objc_readClassPair), %rdi` mixes the entry point into rdi, an
 *           argument of the send that follows: cannot-measure, "_objc_readClassPair address taken"
 */
	.section __TEXT,__objc_methname,cstring_literals
L_sel_description:
	.asciz "description"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_selref_description:
	.quad L_sel_description
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref_NSObject:
	.quad _OBJC_CLASS_$_NSObject
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0

	.weak_reference _objc_readClassPair
	.text
	.globl _main
	.p2align 4
_main:
	pushq %rbp
	movq %rsp, %rbp
	movq L_classref_NSObject(%rip), %rdi
#if FORM == 0
	cmpq $0, _objc_readClassPair@GOTPCREL(%rip)
	je Ldone
#else
	addq _objc_readClassPair@GOTPCREL(%rip), %rdi
#endif
	movq L_selref_description(%rip), %rsi
	callq *_objc_msgSend@GOTPCREL(%rip)
Ldone:
	xorl %eax, %eax
	popq %rbp
	retq
