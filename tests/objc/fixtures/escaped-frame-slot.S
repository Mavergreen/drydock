/* Fixture: the shape of Recaulk's workspace.m:126-132 (b0f7ef3; d19d528's lines 122-128) as Apple
 * clang 21 emits it at -Os, where the arm64 run read x86_64@0x10000150a as `?[? ?]`. The function's
 * first for-in (line 90) gives its enumeration state and buffer, the lowest frame addresses formed,
 * to countByEnumeratingWithState:objects:count:, so every slot above them is exposed. The launch
 * passes &local (a frame address) to a call through a function pointer (ops->launch), then
 * +[NSData dataWithBytes:&pid length:] passes &pid to an objc send that is no enumeration. Only
 * then are the loop body's selectors spilled to frame slots below both addresses, and each send
 * of the loop reloads its selector from its slot. Hand-assembled so the shape does not depend on
 * which compiler builds it; open-urls-merge.S has the same lines inside the whole d19d528
 * function, transcribed. Never executed.
 *
 *   FORM 0  as compiled: both escaped addresses lie above the slots, so the reloads give
 *           objectAtIndex: and setAttributeDescriptor:forKeyword:
 *   FORM 1  &pid is a frame address below both slots: neither selector is kept
 *   FORM 2  the escaped address is objectAtIndex:'s slot itself: that one is lost, and
 *           setAttributeDescriptor:forKeyword:'s slot, wholly below it, is kept
 *   FORM 3  the address passed to the send is derived from an escaped one by a lea: it could
 *           point anywhere, so no slot is kept
 *   FORM 4  &local is also stored to a global: an escape that is no call, so no slot is kept
 */
	.section __TEXT,__objc_methname,cstring_literals
L_name_data:
	.asciz "dataWithBytes:length:"
L_name_desc:
	.asciz "descriptorWithDescriptorType:data:"
L_name_at:
	.asciz "objectAtIndex:"
L_name_attr:
	.asciz "setAttributeDescriptor:forKeyword:"
L_name_count:
	.asciz "count"
L_name_enum:
	.asciz "countByEnumeratingWithState:objects:count:"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_selref_data:
	.quad L_name_data
L_selref_desc:
	.quad L_name_desc
L_selref_at:
	.quad L_name_at
L_selref_attr:
	.quad L_name_attr
L_selref_count:
	.quad L_name_count
L_selref_enum:
	.quad L_name_enum
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref_data:
	.quad _OBJC_CLASS_$_NSData
L_classref_desc:
	.quad _OBJC_CLASS_$_NSAppleEventDescriptor
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0
	.section __DATA,__data
	.p2align 3
L_global:
	.quad 0

	.text
	.globl _main
	.p2align 4
_main:
	xorl	%eax, %eax
	retq

/* NSRunningApplication *target_loop(NSArray *events, launch_fn launch, id workspace) */
	.globl _target_loop
	.p2align 4
_target_loop:
	pushq	%rbp
	movq	%rsp, %rbp
	pushq	%r15
	pushq	%r14
	pushq	%r13
	pushq	%r12
	pushq	%rbx
	subq	$0x158, %rsp
	movq	%rdi, %r14
	movq	%rsi, %r15
	movq	%rdx, %r13
	movq	%r14, %rdi
	movq	L_selref_enum(%rip), %rsi
	leaq	-0x170(%rbp), %rdx
	leaq	-0x130(%rbp), %rcx
	movl	$0x10, %r8d
	callq	*_objc_msgSend@GOTPCREL(%rip)
	movq	$0x0, -0x30(%rbp)
	movq	%r13, %rdi
	leaq	-0x30(%rbp), %r8
#if FORM == 4
	movq	%r8, L_global(%rip)
#endif
	callq	*%r15
	movl	%eax, -0x34(%rbp)
	movq	L_classref_data(%rip), %rdi
	movq	L_selref_data(%rip), %rsi
#if FORM == 1
	leaq	-0x58(%rbp), %rdx
#elif FORM == 2
	leaq	-0x48(%rbp), %rdx
#elif FORM == 3
	leaq	-0x34(%rbp), %rax
	leaq	-0x24(%rax), %rdx
#else
	leaq	-0x34(%rbp), %rdx
#endif
	movl	$0x4, %ecx
	callq	*_objc_msgSend@GOTPCREL(%rip)
	movq	L_classref_desc(%rip), %rdi
	movq	L_selref_desc(%rip), %rsi
	movl	$0x6b706964, %edx
	movq	%rax, %rcx
	callq	*_objc_msgSend@GOTPCREL(%rip)
	movq	%rax, %rbx
	movq	L_selref_at(%rip), %rax
	movq	%rax, -0x48(%rbp)
	movq	L_selref_attr(%rip), %rax
	movq	%rax, -0x50(%rbp)
	xorl	%r12d, %r12d
L_loop:
	movq	%r14, %rdi
	movq	-0x48(%rbp), %rsi
	movq	%r12, %rdx
	callq	*_objc_msgSend@GOTPCREL(%rip)
	movq	%rax, %rdi
	movq	-0x50(%rbp), %rsi
	movq	%rbx, %rdx
	movl	$0x61646472, %ecx
	callq	*_objc_msgSend@GOTPCREL(%rip)
	incq	%r12
	movq	%r14, %rdi
	movq	L_selref_count(%rip), %rsi
	callq	*_objc_msgSend@GOTPCREL(%rip)
	cmpq	%rax, %r12
	jb	L_loop
	movq	%rbx, %rax
	addq	$0x158, %rsp
	popq	%rbx
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	popq	%rbp
	retq
