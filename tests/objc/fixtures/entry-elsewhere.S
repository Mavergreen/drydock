/* Fixture: the unsafe twins of entry-copy.S's `_beep` -- objc_msgSend in rcx at a call to a name the
 * floor function catalog knows, bound somewhere other than the system library that declares it, so
 * the name may be another function that reads rcx. Each is cannot-measure at its call: "objc entry
 * point in rcx is passed as an argument". Never executed.
 *
 *   _write_elsewhere  `write` (three parameters in the catalog: rdi, rsi, rdx), bound to
 *                     entry-elsewhere-lib.c's libelsewhere.dylib, linked ahead of libSystem
 *   _beep_flat        NSBeep (no parameter in the catalog), bound by flat lookup (-Wl,-U,_NSBeep,
 *                     AppKit not linked)
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

	.text
	.globl _main
	.p2align 4
_main:
	pushq %rbp
	movq %rsp, %rbp
	callq _write_elsewhere
	callq _beep_flat
	xorl %eax, %eax
	popq %rbp
	retq

	.p2align 4
_write_elsewhere:
	pushq %rbp
	movq %rsp, %rbp
	pushq %rbx
	pushq %rax
	movq _objc_msgSend@GOTPCREL(%rip), %rbx
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
	callq *%rbx
	movq %rbx, %rcx
	movl $1, %edi
	xorl %esi, %esi
	xorl %edx, %edx
	callq _write
	addq $8, %rsp
	popq %rbx
	popq %rbp
	retq

	.p2align 4
_beep_flat:
	pushq %rbp
	movq %rsp, %rbp
	pushq %rbx
	pushq %rax
	movq _objc_msgSend@GOTPCREL(%rip), %rbx
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
	callq *%rbx
	movq %rbx, %rcx
	callq _NSBeep
	addq $8, %rsp
	popq %rbx
	popq %rbp
	retq
