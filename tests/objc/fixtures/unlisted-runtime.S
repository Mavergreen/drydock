/* Fixture: a libobjc import absent from src/objc/macho-reader.c ROLES stays refused,
 * unclassified-objc-runtime-import. objc_setHook_getClass is a later runtime's (10.14) and is
 * not in the table; linked with -U, the reader knows it only by its name. Hand-assembled so no
 * SDK declaration is needed. Never executed. */
	.text
	.globl _main
	.p2align 4
_main:
	pushq %rbp
	movq %rsp, %rbp
	xorl %edi, %edi
	xorl %esi, %esi
	callq *_objc_setHook_getClass@GOTPCREL(%rip)
	xorl %eax, %eax
	popq %rbp
	retq
