/* Fixture: the shape rustc 1.99 emits for Codex 0.171's clipboard_image (first_image inlined): the
 * address of objc2's isEqual: CACHED_SEL loaded once into a callee-saved register before an
 * NSFastEnumeration loop, its CachedSel::fetch taking the cache from that register on the slow path
 * inside the loop, beside a lazily made NSString cached with `xchg %rax, CACHED_NSSTRING(%rip)`.
 * Symbols are the exact v0 names from that build. Hand-assembled so the shape does not depend on
 * which compiler builds it. Never executed.
 *
 *   FORM 0  the hoisted cache register, a loop with calls: one fetch site, measured
 *   FORM 1  as FORM 0, with the xchg into another static in the loop (it writes rax, not r12): measured
 *   FORM 2  as FORM 1, the cache address also spilled to a frame slot and the fetch taking the reload: measured
 *   FORM 3  the loop exchanges r12 itself with a static
 *   FORM 4  the loop exchanges r12 with rbx (r12 in the ModRM reg field)
 *   FORM 5  the loop exchanges rbx with r12 (r12 in the ModRM r/m field)
 *   FORM 6  on one path through the loop r12 is overwritten
 *   FORM 7  two paths load two different caches into r12, which merge before the loop
 * FORMS 3..7 are cannot-measure: the fetch's cache argument is not one cache static on every path. */
	.section __TEXT,__const
L_isEqual:
	.asciz "isEqual:"

	.section __DATA,__data
	.p2align 3
	.globl __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL
__RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL:
	.quad 0
#if FORM == 7
	.globl __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol4hash10CACHED_SEL
__RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol4hash10CACHED_SEL:
	.quad 0
#endif
L_nsstring:
	.quad 0
#define CACHE_ISEQUAL __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL
#define CACHE_HASH __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol4hash10CACHED_SEL
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

	.globl _first_image
	.p2align 4
_first_image:
	pushq	%rbp
	movq	%rsp, %rbp
	pushq	%r15
	pushq	%r14
	pushq	%r13
	pushq	%r12
	pushq	%rbx
	subq	$0x18, %rsp
	movq	%rdi, %r15
	xorl	%r13d, %r13d
#if FORM == 7
	testq	%rsi, %rsi
	je	L_other_cache
	leaq	CACHE_ISEQUAL(%rip), %r12
	jmp	L_loop
L_other_cache:
	leaq	CACHE_HASH(%rip), %r12
#else
	leaq	CACHE_ISEQUAL(%rip), %r12
#endif
#if FORM == 2
	movq	%r12, -0x30(%rbp)
#endif
L_loop:
	movq	%r15, %rdi
	callq	_fixture_next
	testq	%rax, %rax
	je	L_done
	movq	%rax, %rbx
#if FORM >= 1
	movq	L_nsstring(%rip), %r14
	testq	%r14, %r14
	jne	L_have_string
	callq	_fixture_string
	movq	%rax, %r14
	xchgq	%rax, L_nsstring(%rip)
L_have_string:
#endif
#if FORM == 3
	xchgq	%r12, L_nsstring(%rip)
#elif FORM == 4
	.byte	0x4c, 0x87, 0xe3	/* xchgq %r12, %rbx: REX.W+R, 87, ModRM reg=r12 rm=rbx */
#elif FORM == 5
	.byte	0x49, 0x87, 0xdc	/* xchgq %rbx, %r12: REX.W+B, 87, ModRM reg=rbx rm=r12 */
#elif FORM == 6
	testq	%r13, %r13
	je	L_keep
	movq	%rbx, %r12
L_keep:
#endif
	movq	(%r12), %rsi
	testq	%rsi, %rsi
	je	L_fetch
L_send:
	movq	%rbx, %rdi
	movq	%r14, %rdx
	callq	_objc_msgSend
	incq	%r13
	testb	%al, %al
	je	L_loop
L_done:
	movq	%r13, %rax
	addq	$0x18, %rsp
	popq	%rbx
	popq	%r12
	popq	%r13
	popq	%r14
	popq	%r15
	popq	%rbp
	retq
L_fetch:
#if FORM == 2
	movq	-0x30(%rbp), %rdi
#else
	movq	%r12, %rdi
#endif
	leaq	L_isEqual(%rip), %rsi
	callq	FETCH
	movq	%rax, %rsi
	jmp	L_send
