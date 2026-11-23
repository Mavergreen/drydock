/* Fixture: a receiver kept in a frame slot across objc2's countByEnumeratingWithState:objects:count:,
 * the shape of Codex 0.171's clipboard_image outer loop: the array a send returned is spilled, and
 * each pass of the loop reloads it as the receiver of the send that refills the state and object
 * buffers, both on the frame. The selector comes from objc2's NSFastEnumeration CACHED_SEL, fetched
 * in this function. Symbols are the exact v0 names from that build. Hand-assembled. Never executed.
 *
 * Frame: receiver slot -0x30; state [-0x70, -0x30) (64 bytes); objects [-0xf0, -0x70) (16 x 8).
 *   FORM 0  the receiver slot lies outside both buffers: it survives the send, and the reload on the
 *           back edge is the spilled result
 *   FORM 1  the receiver is spilled inside the state buffer (-0x50): the send may write it, unknown
 *   FORM 2  the count is a register (the incoming rcx), not an immediate: the extent is unknown, every
 *           exposed slot dies
 *   FORM 3  before the loop, the address of a slot below the receiver's (-0x100) goes to another callee
 *   FORM 4  before the loop, the address of a slot above the receiver's (-0x20) goes to another callee,
 *           which writes only at and above it: the receiver survives, as in FORM 0
 *   FORM 5  the same send shape with isEqual:'s cache: not the enumeration contract, every exposed slot dies
 *   FORM 6  before the loop, the receiver slot's own address (-0x30) goes to another callee: it may write it */
#if FORM == 1
#define RSLOT -0x50
#else
#define RSLOT -0x30
#endif
	.section __TEXT,__objc_methname,cstring_literals
L_sel_array:
	.asciz "array"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_selref_array:
	.quad L_sel_array
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref:
	.quad _OBJC_CLASS_$_NSArray
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0

	.section __TEXT,__const
L_lit:
#if FORM == 5
	.asciz "isEqual:"
#else
	.asciz "countByEnumeratingWithState:objects:count:"
#endif

	.section __DATA,__data
	.p2align 3
#if FORM == 5
#define CACHE __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL
#else
#define CACHE __RNvNvNtNtNtCsdIImX2SWmg2_16objc2_foundation9generated14___NSEnumerator17NSFastEnumeration41countByEnumeratingWithState_objects_count10CACHED_SEL
#endif
	.globl CACHE
CACHE:
	.quad 0
#define FETCH __RNvMNtNtCs2WYrep5oUp8_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch

	.text
	.globl FETCH
	.p2align 4
FETCH:
	xorl	%eax, %eax
	retq

	.globl _main
	.p2align 4
_main:
	xorl	%eax, %eax
	retq

	.globl _enumerate
	.p2align 4
_enumerate:
	pushq	%rbp
	movq	%rsp, %rbp
	pushq	%r13
	pushq	%rbx
	subq	$0x100, %rsp
	movq	%rcx, %r13
	movq	L_classref(%rip), %rdi
	movq	L_selref_array(%rip), %rsi
	callq	_objc_msgSend
	movq	%rax, RSLOT(%rbp)
#if FORM == 3
	leaq	-0x100(%rbp), %rdi
	callq	_fixture_use
#elif FORM == 4
	leaq	-0x20(%rbp), %rdi
	callq	_fixture_use
#elif FORM == 6
	leaq	-0x30(%rbp), %rdi
	callq	_fixture_use
#endif
	xorl	%ebx, %ebx
L_loop:
	movq	RSLOT(%rbp), %rdi
	leaq	CACHE(%rip), %rax
	movq	(%rax), %rsi
	testq	%rsi, %rsi
	je	L_fetch
L_send:
	leaq	-0x70(%rbp), %rdx
	leaq	-0xf0(%rbp), %rcx
#if FORM == 2
	movq	%r13, %r8
#else
	movl	$0x10, %r8d
#endif
	callq	_objc_msgSend
	addq	%rax, %rbx
	testq	%rax, %rax
	jne	L_loop
	movq	%rbx, %rax
	addq	$0x100, %rsp
	popq	%rbx
	popq	%r13
	popq	%rbp
	retq
L_fetch:
	movq	%rdi, %rbx
	leaq	CACHE(%rip), %rdi
	leaq	L_lit(%rip), %rsi
	callq	FETCH
	movq	%rax, %rsi
	movq	%rbx, %rdi
	xorl	%ebx, %ebx
	jmp	L_send
