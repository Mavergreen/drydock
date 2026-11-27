/* Fixture: the shape Apple clang 21 emits at -Os for Recaulk's provider (arm64-built x86_64
 * archive, from codex-cli's disassembly):
 * objc_msgSend's GOT slot loaded once into a callee-saved register, then `callq *%r12` again and
 * again, across other calls, after a join of two such loads, and in a loop. Hand-assembled so the
 * shape does not depend on which compiler builds it. Never executed.
 *
 *   FORM 0  every use of the register is a call through it, or a copy that is then only jumped
 *           through (Apple clang 6 ends a function `mov rax, r12; pop r12; jmp rax`), and a block
 *           laid out after a call to ___stack_chk_fail, which never returns: five sends
 *   FORM 1  the register is also spilled to a frame slot (clang -O0 keeps every value there:
 *           shipyard's own updater, updater/main.m.in, spills objc_msgSend this way) and
 *           called from the reload: followed, five sends, as in FORM 0
 *   FORM 2  a copy of the register is passed as the argument (rdx) of an isEqual: send through it
 *   FORM 3  on one path the register holds something else when the join calls through it
 *   FORM 4  as FORM 1, but the slot's own address escapes to a call (the callee may read it)
 *   FORM 5  as FORM 1, but one path stores another value to the slot before the reload's call
 *   FORM 6  as FORM 1, but the slot is also read into a vector register (a copy that escapes)
 *   FORM 7  the register is stored to a global
 *   FORM 8  the register is stored through another register (to the heap, say)
 *   FORM 9  as FORM 1, but a second reload of the slot is passed as the argument (rdx) of an
 *           isEqual: send
 *   FORM 10 as FORM 1, with an AVX-512 (EVEX) instruction before the reload, as BLAKE3's
 *           assembly in Codex has: decoded, so the function is read past it, five sends
 *   FORM 11 as FORM 1, but an EVEX store, vmovdqu32 %zmm0, -64(%rbp), overwrites the slot: its
 *           disp8 is -1, scaled by 64, so read unscaled it would seem to miss the slot
 *   FORM 12 as FORM 0, with pushes of immediates and of the flags before a call through the register
 *           (clang -Os ends a long varargs send with `pushq $0`, Recaulk's bridge): they write no
 *           register, five sends
 *   FORM 13 as FORM 0, with pop through 8F, moves between rax and an absolute address, movs, stos and
 *           rep stos, jrcxz, xchg eax, ecx and leave: none writes r12, five sends
 *   FORM 14 as FORM 0, with the entry point also loaded into rcx, then rep stos (which reads and
 *           counts down rcx) before a call through rcx
 *   FORM 15 as FORM 0, with cpuid, whose register writes the reader does not classify, before a
 *           call through the register: what r12 holds there is unknown, so that call is refused, not lost
 *   FORM 16 as FORM 0, with the entry point also loaded into r13 and called through, then
 *           xchg rax, r13 (which reads r13 into rax) before a second call through r13
 *   FORM 17 as FORM 0, with the entry point also loaded into rax, then pop %rax through 8F, then a
 *           call through rax
 *   FORM 18 likewise in rax, with movabs moffs, %rax
 *   FORM 19 likewise in rax, with movabs moffs, %al
 *   FORM 20 likewise in rsi, with movsq
 *   FORM 21 likewise in rdi, with movsq
 *   FORM 22 likewise in rdi, with stosq
 *   FORM 23 likewise in rbp, with leave
 *   FORM 24 likewise in rax, with xchg %eax, %ecx
 *   FORM 25 as FORM 0, with pinsrw from ecx (iTerm2 3.0.15 packs bytes into xmm0 between sends): it
 *           writes only a vector register, five sends
 * FORMS 2..9, 11, 14..16 and 18..24 are cannot-measure: the entry point escapes, or a call through it may not be one.
 */
	.section __TEXT,__objc_methname,cstring_literals
L_sel_description:
	.asciz "description"
L_sel_hash:
	.asciz "hash"
L_sel_isEqual:
	.asciz "isEqual:"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_selref_description:
	.quad L_sel_description
L_selref_hash:
	.quad L_sel_hash
L_selref_isEqual:
	.quad L_sel_isEqual
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref_NSObject:
	.quad _OBJC_CLASS_$_NSObject
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0

#if FORM == 17 || FORM == 18 || FORM == 19 || FORM == 24
#define WREG %rax
#elif FORM == 20
#define WREG %rsi
#elif FORM == 21 || FORM == 22
#define WREG %rdi
#elif FORM == 23
#define WREG %rbp
#endif

	.text
	.globl _main
	.p2align 4
_main:
	pushq %rbp
	movq %rsp, %rbp
	pushq %r12
	pushq %rbx
	subq $16, %rsp
	movl %edi, %ebx
	movq _objc_msgSend@GOTPCREL(%rip), %r12
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
	callq *%r12
#if FORM == 1 || FORM == 4 || FORM == 5 || FORM == 6 || FORM == 9 || FORM == 10 || FORM == 11
	movq %r12, -24(%rbp)
#elif FORM == 7
	movq %r12, _hoisted_global(%rip)
#elif FORM == 8
	movq %r12, (%rbx)
#endif
#if FORM == 4
	leaq -24(%rbp), %rdi
	callq _hoisted_sink
#elif FORM == 6
	movq -24(%rbp), %xmm0
#endif
	testl %ebx, %ebx
	js 3f
	je 1f
#if FORM == 3
	leaq _main(%rip), %r12
#else
	movq _objc_msgSend@GOTPCREL(%rip), %r12
#endif
#if FORM == 5
	movq %rbx, -24(%rbp)
#endif
1:
#if FORM == 10
	.byte 0x62, 0xf1, 0x6d, 0x48, 0xfe, 0xd9   /* vpaddd %zmm1, %zmm2, %zmm3 */
#elif FORM == 11
	.byte 0x62, 0xf1, 0x7e, 0x48, 0x7f, 0x45, 0xff   /* vmovdqu32 %zmm0, -64(%rbp) */
#elif FORM == 12
	pushq $0
	pushq $0x12345678
	pushfq
	popfq
	addq $16, %rsp
#elif FORM == 13
	pushq %rax
	.byte 0x8f, 0xc0                  /* popq %rax */
	.byte 0x48, 0xa1
	.quad 0                           /* movabsq 0, %rax */
	.byte 0x48, 0xa3
	.quad 0                           /* movabsq %rax, 0 */
	.byte 0xa0
	.quad 0                           /* movabsb 0, %al */
	.byte 0xa2
	.quad 0                           /* movabsb %al, 0 */
	.byte 0xa4                        /* movsb */
	.byte 0x48, 0xa5                  /* movsq */
	.byte 0xaa                        /* stosb */
	.byte 0x48, 0xab                  /* stosq */
	.byte 0xf3, 0x48, 0xab            /* rep stosq */
	.byte 0xe3, 0x00                  /* jrcxz to the next instruction */
	.byte 0x91                        /* xchgl %eax, %ecx */
	.byte 0x97                        /* xchgl %eax, %edi */
#elif FORM == 14
	movq _objc_msgSend@GOTPCREL(%rip), %rcx
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	.byte 0xf3, 0x48, 0xab            /* rep stosq */
	callq *%rcx
#elif FORM == 15
	cpuid
#elif FORM == 25
	pinsrw $4, %ecx, %xmm0
#elif FORM == 16
	movq _objc_msgSend@GOTPCREL(%rip), %r13
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	callq *%r13
	.byte 0x49, 0x95                  /* xchgq %rax, %r13 */
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	callq *%r13
#elif FORM >= 17 && FORM <= 24
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	movq _objc_msgSend@GOTPCREL(%rip), WREG
#if FORM == 17
	.byte 0x8f, 0xc0                  /* popq %rax */
#elif FORM == 18
	.byte 0x48, 0xa1
	.quad 0                           /* movabsq 0, %rax */
#elif FORM == 19
	.byte 0xa0
	.quad 0                           /* movabsb 0, %al */
#elif FORM == 20 || FORM == 21
	.byte 0x48, 0xa5                  /* movsq */
#elif FORM == 22
	.byte 0x48, 0xab                  /* stosq */
#elif FORM == 23
	.byte 0xc9                        /* leave */
#elif FORM == 24
	.byte 0x91                        /* xchgl %eax, %ecx */
#endif
	callq *WREG
#endif
	movq L_classref_NSObject(%rip), %rdi
#if FORM == 2 || FORM == 9
	movq L_selref_isEqual(%rip), %rsi   /* one parameter: rdx is an argument (hash takes none) */
#else
	movq L_selref_hash(%rip), %rsi
#endif
#if FORM == 1 || FORM == 4 || FORM == 5 || FORM == 6 || FORM == 10 || FORM == 11
	movq -24(%rbp), %rax
	callq *%rax
#elif FORM == 9
	movq -24(%rbp), %rax
	movq -24(%rbp), %rdx
	callq *%rax
#elif FORM == 2
	movq %r12, %rdx
	callq *%r12
#else
	callq *%r12
#endif
2:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_description(%rip), %rsi
	callq *%r12
	cmpl $7, %ebx
	je 4f
	decl %ebx
	jg 2b
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	movq %r12, %rax
	addq $16, %rsp
	popq %rbx
	popq %r12
#if FORM == 13
	.byte 0xc9                        /* leave */
#else
	popq %rbp
#endif
	jmpq *%rax
/* A failed check clobbers r12 and never returns; the block after it is reached only from the loop. */
3:
	xorl %r12d, %r12d
	callq ___stack_chk_fail
4:
	movq L_classref_NSObject(%rip), %rdi
	movq L_selref_hash(%rip), %rsi
	callq *%r12
	jmp 2b

/* FORM 4's callee and FORM 7's global. */
	.p2align 4
_hoisted_sink:
	retq
	.section __DATA,__data
	.p2align 3
_hoisted_global:
	.quad 0
