/* Fixture: objc_loadWeak is a classified runtime import (src/objc/macho-reader.c ROLES), not
 * unclassified-objc-runtime-import. Hand-assembled so no SDK declaration is needed. Never executed. */
	.text
	.globl _main
	.p2align 4
_main:
	pushq %rbp
	movq %rsp, %rbp
	xorl %edi, %edi
	callq *_objc_loadWeak@GOTPCREL(%rip)
	xorl %eax, %eax
	popq %rbp
	retq
