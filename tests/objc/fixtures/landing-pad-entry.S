/* Fixture: the shape clang emits at -O2 for shipyard's own updater (updater/main.m.in, whose
 * @try/@catch around the update check gives main a landing pad): an objc entry point loaded from
 * its GOT slot into a callee-saved register before a call that may throw, then called through in
 * the landing pad and where the pad's path rejoins the normal one. Nothing branches to a landing
 * pad; the unwinder enters it from a call the LSDA's call-site table lists, with the callee-saved
 * registers as they were at that call. Hand-assembled, with its own LSDA, so the shape does not
 * depend on which compiler builds it. Never executed.
 *
 *   CSENC 3 (default) the call-site table in udata4, as Apple clang 6 and the updater's build write it
 *   CSENC 1           the call-site table in uleb128, as newer clangs write it
 *
 *   FORM 0  r12 holds objc_msgSend at the throwing send, the pad sends through it and rejoins
 *           the normal path, which sends through it again: followed, three sends
 *   FORM 1  as FORM 0, but the pad leaves through its own epilogue instead: three sends
 *   FORM 2  on one path r12 holds something else at the throwing call: the pad's call is not
 *           provably a send
 *   FORM 3  as FORM 1, but the pad passes a copy of r12 as an argument
 * FORMS 2 and 3 are cannot-measure.
 */
#ifndef CSENC
#define CSENC 3
#endif
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
Lfunc_begin0:
	.cfi_startproc
	.cfi_personality 155, ___objc_personality_v0
	.cfi_lsda 16, Lexception0
	pushq %rbp
	.cfi_def_cfa_offset 16
	.cfi_offset %rbp, -16
	movq %rsp, %rbp
	.cfi_def_cfa_register %rbp
	pushq %r12
	pushq %rbx
	.cfi_offset %rbx, -32
	.cfi_offset %r12, -24
	movl %edi, %ebx
	movq _objc_msgSend@GOTPCREL(%rip), %r12
#if FORM == 2
	testl %ebx, %ebx
	je 1f
	leaq _main(%rip), %r12
1:
#endif
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
Ltmp0:
	callq *%r12
Ltmp1:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
Ljoin:
	callq *%r12
Lout:
	xorl %eax, %eax
	popq %rbx
	popq %r12
	popq %rbp
	retq
/* The landing pad: reached only from Ltmp0's call, by the unwinder. */
Ltmp2:
	movq %rax, %rdi
	callq _objc_begin_catch
	movq %rax, %rdi
	movq L_selref_description(%rip), %rsi
#if FORM == 3
	movq %r12, %rdx
#endif
	callq *%r12
	callq _objc_end_catch
#if FORM == 1 || FORM == 3
	movl $1, %eax
	popq %rbx
	popq %r12
	popq %rbp
	retq
#else
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	jmp Ljoin
#endif
Lfunc_end0:
	.cfi_endproc

	.section __TEXT,__gcc_except_tab
	.p2align 2
Lexception0:
	.byte 255
	.byte 155
	.uleb128 Lttbase0-Lttbaseref0
Lttbaseref0:
	.byte CSENC
	.uleb128 Lcst_end0-Lcst_begin0
Lcst_begin0:
#if CSENC == 1
	.uleb128 Ltmp0-Lfunc_begin0
	.uleb128 Ltmp1-Ltmp0
	.uleb128 Ltmp2-Lfunc_begin0
#else
	.long Ltmp0-Lfunc_begin0
	.long Ltmp1-Ltmp0
	.long Ltmp2-Lfunc_begin0
#endif
	.byte 1
Lcst_end0:
	.byte 1
	.byte 0
	.p2align 2
	.long 0
Lttbase0:
