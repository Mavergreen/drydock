/* Fixture: an entry point left in a register no call reads as an argument. Hand-assembled from the
 * code Alacritty's compat probe ships for -[RecaulkTabPSMTabBarControl setDelegate:]
 * (`otool -tV -p '-[RecaulkTabPSMTabBarControl setDelegate:]'` of
 * alacritty-port build/compat-probe/alacritty, 0x1003a5b52), which the pinned clang22 does not
 * reproduce from entry-copy.m at -Os or -O3: it reloads the GOT slot in each block instead.
 * Never executed.
 *
 *   _set_delegate   objc_msgSend's GOT slot in r15, copied `movq %r15,%rcx` before a branch and
 *                   `movq %rcx,%rbx` on both paths, then called through rbx. At the two `delegate`
 *                   sends and `unregisterDraggedTypes` (no colon: rdi and rsi only) rcx still holds
 *                   the entry point and rdx a stale value; each send clobbers rcx, and the copy back
 *                   (`movq %rbx,%rcx`) restores it for the next. No call reads rcx.
 *   _responds       the same copies, then a respondsToSelector: send (one parameter: rdi, rsi and
 *                   rdx) with rcx still holding the entry point.
 *   _beep           the entry point in rcx at a call to NSBeep, which takes no parameter.
 *
 * Both are measured once the reader bounds a call's argument registers by its declarations
 * (src/objc/reference.c "argument registers"); before that, rcx counted at every call. Their
 * unsafe twins are tests/objc/fixtures/entry-escape.S. */
	.section __TEXT,__cstring,cstring_literals
L_pbtype:
	.asciz "PSMTabBarControlItemPBType"
	.section __TEXT,__objc_methname,cstring_literals
L_sel_arrayWithObject:
	.asciz "arrayWithObject:"
L_sel_delegate:
	.asciz "delegate"
L_sel_allowed:
	.asciz "allowedDraggedTypesForTabView:"
L_sel_respondsToSelector:
	.asciz "respondsToSelector:"
L_sel_addObjectsFromArray:
	.asciz "addObjectsFromArray:"
L_sel_unregister:
	.asciz "unregisterDraggedTypes"
L_sel_register:
	.asciz "registerForDraggedTypes:"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_selref_arrayWithObject:
	.quad L_sel_arrayWithObject
L_selref_delegate:
	.quad L_sel_delegate
L_selref_allowed:
	.quad L_sel_allowed
L_selref_respondsToSelector:
	.quad L_sel_respondsToSelector
L_selref_addObjectsFromArray:
	.quad L_sel_addObjectsFromArray
L_selref_unregister:
	.quad L_sel_unregister
L_selref_register:
	.quad L_sel_register
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref_NSMutableArray:
	.quad _OBJC_CLASS_$_NSMutableArray
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0
	.section __DATA,__data
	.p2align 3
L_ivar_delegate:
	.quad 8
L_ivar_tabView:
	.quad 16

	.text
	.globl _main
	.p2align 4
_main:
	pushq %rbp
	movq %rsp, %rbp
	callq _set_delegate
	callq _responds
	callq _beep
	xorl %eax, %eax
	popq %rbp
	retq

	.p2align 4
_set_delegate:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r15
	pushq %r14
	pushq %r12
	pushq %rbx
	movq %rdi, %r12
	movq L_ivar_delegate(%rip), %rax
	movq %rdx, (%r12,%rax)
	movq L_classref_NSMutableArray(%rip), %rdi
	movq L_selref_arrayWithObject(%rip), %rsi
	leaq L_pbtype(%rip), %rdx
	movq _objc_msgSend@GOTPCREL(%rip), %r15
	callq *%r15
	movq %rax, %r14
	movq L_selref_delegate(%rip), %rsi
	movq %r12, %rdi
	callq *%r15
	movq %r15, %rcx
	testq %rax, %rax
	je 1f
	movq L_selref_delegate(%rip), %rsi
	movq %r12, %rdi
	movq %rcx, %rbx
	callq *%rbx
	movq L_selref_allowed(%rip), %rdx
	movq L_selref_respondsToSelector(%rip), %rsi
	movq %rax, %rdi
	callq *%rbx
	movq %rbx, %rcx
	testb %al, %al
	je 1f
	movq L_selref_delegate(%rip), %rsi
	movq %r12, %rdi
	movq %rcx, %rbx
	callq *%rbx
	movq L_ivar_tabView(%rip), %rcx
	movq (%r12,%rcx), %rdx
	movq L_selref_allowed(%rip), %rsi
	movq %rax, %rdi
	callq *%rbx
	movq L_selref_addObjectsFromArray(%rip), %rsi
	movq %r14, %rdi
	movq %rax, %rdx
	callq *%rbx
	movq %rbx, %rcx
1:
	movq L_selref_unregister(%rip), %rsi
	movq %r12, %rdi
	movq %rcx, %rbx
	callq *%rbx
	movq L_selref_register(%rip), %rsi
	movq %r12, %rdi
	movq %r14, %rdx
	movq %rbx, %rax
	popq %rbx
	popq %r12
	popq %r14
	popq %r15
	popq %rbp
	jmpq *%rax

	.p2align 4
_responds:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r15
	pushq %rbx
	movq _objc_msgSend@GOTPCREL(%rip), %r15
	movq %r15, %rcx
	movq %rcx, %rbx
	movq L_classref_NSMutableArray(%rip), %rdi
	movq L_selref_respondsToSelector(%rip), %rsi
	movq L_selref_allowed(%rip), %rdx
	callq *%rbx
	popq %rbx
	popq %r15
	popq %rbp
	retq

	.p2align 4
_beep:
	pushq %rbp
	movq %rsp, %rbp
	pushq %rbx
	pushq %rax
	movq _objc_msgSend@GOTPCREL(%rip), %rbx
	movq L_classref_NSMutableArray(%rip), %rdi
	movq L_selref_delegate(%rip), %rsi
	callq *%rbx
	movq %rbx, %rcx
	callq _NSBeep
	addq $8, %rsp
	popq %rbx
	popq %rbp
	retq
