/* Fixture: an objc2 cache static addressed through a register that needs a SIB byte. r12 (like rsp)
 * as a base is always encoded with one, index none: `movq (%r12), %rsi` is 49 8b 34 24, as Codex
 * 0.171's clipboard_image loads isEqual:'s cached selector. Symbols are the exact v0 names from that
 * build. Hand-assembled so the encoding does not depend on which compiler builds it. Never executed.
 *
 *   FORM 0  the selector loaded through (%r12) on the fast path, the fetch on the slow: the send's
 *           selector is the cache's on both paths
 *   FORM 1  as FORM 0, loaded through (%r12,%rcx,8): a real index, the selector is not followed
 *   FORM 2  an unknown value stored into the cache through (%r12): unrecognized-cache-store
 *   FORM 3  as FORM 2, through (%rbx), which needs no SIB byte: unrecognized-cache-store
 *   FORM 4  an inlined fetch, Sel::register_unchecked("isEqual:") stored through (%r12): the cache's fetch
 *   FORM 5  as FORM 4, through (%rbx) */
	.section __TEXT,__const
L_isEqual:
	.asciz "isEqual:"

	.section __DATA,__data
	.p2align 3
	.globl __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL
__RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL:
	.quad 0
#define CACHE __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL
#define FETCH __RNvMNtNtCs2WYrep5oUp8_5objc215___macro_helpers5cacheNtB2_9CachedSel5fetch
#define REGISTER __RNvMs2_NtCs2WYrep5oUp8_5objc27runtimeNtB5_3Sel18register_unchecked

	.text
	.globl FETCH
	.p2align 4
FETCH:
	xorl	%eax, %eax
	retq

	.globl REGISTER
	.p2align 4
REGISTER:
	xorl	%eax, %eax
	retq

	.globl _main
	.p2align 4
_main:
	xorl	%eax, %eax
	retq

	.globl _is_equal
	.p2align 4
_is_equal:
	pushq	%rbp
	movq	%rsp, %rbp
	pushq	%r12
	pushq	%rbx
	movq	%rdi, %rbx
	movq	%rsi, %rdx
	leaq	CACHE(%rip), %r12
#if FORM <= 1
#if FORM == 0
	movq	(%r12), %rsi
#else
	xorl	%ecx, %ecx
	movq	(%r12,%rcx,8), %rsi
#endif
	testq	%rsi, %rsi
	jne	L_send
	pushq	%rdx
	pushq	%rdx
	movq	%r12, %rdi
	leaq	L_isEqual(%rip), %rsi
	callq	FETCH
	popq	%rdx
	popq	%rdx
	movq	%rax, %rsi
#else
	movq	CACHE(%rip), %rsi
	testq	%rsi, %rsi
	jne	L_send
	pushq	%rdx
	pushq	%rdx
#if FORM == 2 || FORM == 3
	movq	%rdx, %rax
#else
	leaq	L_isEqual(%rip), %rdi
	callq	REGISTER
#endif
#if FORM == 3 || FORM == 5
	movq	%r12, %rcx
	movq	%rax, (%rcx)
#else
	movq	%rax, (%r12)
#endif
	popq	%rdx
	popq	%rdx
	movq	%rax, %rsi
#endif
L_send:
	movq	%rbx, %rdi
	callq	_objc_msgSend
	popq	%rbx
	popq	%r12
	popq	%rbp
	retq
