/* Fixture: the shape Apple clang 21 emits at -Os for Recaulk's __recaulk_workspace_note_recent_files,
 * transcribed instruction for instruction from llvm-objdump output of the arm64-built x86_64 archive
 * member workspace-recents.o (Recaulk d19d528; relocations replaced by the local references below).
 * Unlike spilled-selector.S, both countByEnumeratingWithState:objects:count: calls of the first for-in
 * loop go through a register holding the GOT-loaded objc_msgSend (`call *%r13`), and the loop body
 * reloads its spilled selectors for sends through another such register (`call *%r15`). A second
 * for-in loop later passes the address of an unrelated slot (-0x158) to CFNumberGetValue and writes a
 * stack argument through rsp; no path from there reaches the first loop again.
 * Hand-assembled so the shape does not depend on which compiler builds it. Never executed.
 *
 *   FORM 0  as compiled: both spilled selectors are followed to their reloads
 *   FORM 1  the first loop's back edge passes -0x178's own address to a function: an unbounded escape,
 *           after which no selector slot is kept on that path, so both reloads are unknown
 *   FORM 2  bts/btr write rbp after the prologue (btl only tests a bit): no conventional frame, both unknown
 * The function opens with `btl $0x8, %esi`, a bit test that writes no register; it must not cost the frame. */
	.section __TEXT,__objc_methname,cstring_literals
L_name_0:
	.asciz "array"
L_name_2:
	.asciz "countByEnumeratingWithState:objects:count:"
L_name_5:
	.asciz "class"
L_name_7:
	.asciz "isKindOfClass:"
L_name_9:
	.asciz "isFileURL"
L_name_11:
	.asciz "addObject:"
L_name_13:
	.asciz "count"
L_name_17:
	.asciz "errorWithDomain:code:userInfo:"
L_name_19:
	.asciz "dictionaryWithObjects:forKeys:count:"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_selref_0:
	.quad L_name_0
L_selref_2:
	.quad L_name_2
L_selref_5:
	.quad L_name_5
L_selref_7:
	.quad L_name_7
L_selref_9:
	.quad L_name_9
L_selref_11:
	.quad L_name_11
L_selref_13:
	.quad L_name_13
L_selref_17:
	.quad L_name_17
L_selref_19:
	.quad L_name_19
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref_0:
	.quad _OBJC_CLASS_$_NSMutableArray
L_classref_3:
	.quad _OBJC_CLASS_$_NSURL
L_classref_14:
	.quad _OBJC_CLASS_$_NSError
L_classref_15:
	.quad _OBJC_CLASS_$_NSDictionary
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0
	.section __DATA,__data
	.p2align 3
L_cfstr:
	.quad 0, 0, 0, 0

	.text
	.globl _main
	.p2align 4
_main:
	xorl %eax, %eax
	retq

	.globl _note_recent_files
	.p2align 4
_note_recent_files:
L_0:	pushq	%rbp
L_1:	movq	%rsp, %rbp
L_4:	pushq	%r15
L_6:	pushq	%r14
L_8:	pushq	%r13
L_a:	pushq	%r12
L_c:	pushq	%rbx
L_d:	subq	$0x1e8, %rsp
#if FORM == 2
	btsq	$0x1, %rbp
	btrq	$0x1, %rbp
#endif
L_14:	movq	___stack_chk_guard@GOTPCREL(%rip), %rax
L_1b:	movq	(%rax), %rax
L_1e:	movq	%rax, -0x30(%rbp)
L_22:	movb	$0x1, %bl
L_24:	btl	$0x8, %esi
L_28:	jb	L_3f2
L_2e:	movq	%rdi, %r14
L_31:	movq	%rdx, -0x150(%rbp)
L_38:	movq	L_classref_0(%rip), %rdi
L_3f:	movq	L_selref_0(%rip), %rsi
L_46:	movq	_objc_msgSend@GOTPCREL(%rip), %r13
L_4d:	callq	*%r13
L_50:	movq	%rax, -0x148(%rbp)
L_57:	xorps	%xmm0, %xmm0
L_5a:	leaq	-0x200(%rbp), %rdx
L_61:	movaps	%xmm0, (%rdx)
L_64:	movaps	%xmm0, 0x10(%rdx)
L_68:	movaps	%xmm0, 0x20(%rdx)
L_6c:	movaps	%xmm0, 0x30(%rdx)
L_70:	movq	L_selref_2(%rip), %rsi
L_77:	leaq	-0xb0(%rbp), %rcx
L_7e:	movl	$0x10, %r8d
L_84:	movq	%r14, %rdi
L_87:	callq	*%r13
L_8a:	movq	%rax, -0x168(%rbp)
L_91:	testq	%rax, %rax
L_94:	je	L_19e
L_9a:	leaq	-0x200(%rbp), %rax
L_a1:	movq	0x10(%rax), %rax
L_a5:	movq	(%rax), %rax
L_a8:	movq	%rax, -0x180(%rbp)
L_af:	movq	%r14, -0x160(%rbp)
L_b6:	movq	L_selref_5(%rip), %r13
L_bd:	movq	L_selref_7(%rip), %rbx
L_c4:	movq	L_selref_9(%rip), %rax
L_cb:	movq	%rax, -0x178(%rbp)
L_d2:	movq	L_selref_11(%rip), %rax
L_d9:	movq	%rax, -0x170(%rbp)
L_e0:	xorl	%r14d, %r14d
L_e3:	movq	-0x1f0(%rbp), %rax
L_ea:	movq	-0x180(%rbp), %rcx
L_f1:	cmpq	%rcx, (%rax)
L_f4:	je	L_102
L_f6:	movq	-0x160(%rbp), %rdi
L_fd:	callq	_objc_enumerationMutation
L_102:	movq	-0x1f8(%rbp), %rax
L_109:	movq	(%rax,%r14,8), %r12
L_10d:	movq	L_classref_3(%rip), %rdi
L_114:	movq	%r13, %rsi
L_117:	movq	_objc_msgSend@GOTPCREL(%rip), %r15
L_11e:	callq	*%r15
L_121:	movq	%r12, %rdi
L_124:	movq	%rbx, %rsi
L_127:	movq	%rax, %rdx
L_12a:	callq	*%r15
L_12d:	testb	%al, %al
L_12f:	je	L_156
L_131:	movq	%r12, %rdi
L_134:	movq	-0x178(%rbp), %rsi
L_13b:	callq	*%r15
L_13e:	testb	%al, %al
L_140:	je	L_156
L_142:	movq	-0x148(%rbp), %rdi
L_149:	movq	-0x170(%rbp), %rsi
L_150:	movq	%r12, %rdx
L_153:	callq	*%r15
L_156:	incq	%r14
L_159:	cmpq	%r14, -0x168(%rbp)
L_160:	jne	L_e3
L_162:	movl	$0x10, %r8d
L_168:	movq	-0x160(%rbp), %rdi
L_16f:	movq	L_selref_2(%rip), %rsi
L_176:	leaq	-0x200(%rbp), %rdx
L_17d:	leaq	-0xb0(%rbp), %rcx
L_184:	movq	_objc_msgSend@GOTPCREL(%rip), %r13
#if FORM == 1
	leaq	-0x178(%rbp), %rdi
	callq	_CFRelease
	movl	$0x10, %r8d
	movq	-0x160(%rbp), %rdi
	movq	L_selref_2(%rip), %rsi
	leaq	-0x200(%rbp), %rdx
	leaq	-0xb0(%rbp), %rcx
#endif
L_18b:	callq	*%r13
L_18e:	movq	%rax, -0x168(%rbp)
L_195:	testq	%rax, %rax
L_198:	jne	L_b6
L_19e:	movq	L_selref_13(%rip), %rsi
L_1a5:	movq	-0x148(%rbp), %rdi
L_1ac:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_1b2:	testq	%rax, %rax
L_1b5:	movq	-0x150(%rbp), %r15
L_1bc:	movb	$0x1, %bl
L_1be:	je	L_3f2
L_1c4:	movq	_kCFAllocatorDefault@GOTPCREL(%rip), %rax
L_1cb:	movq	(%rax), %rdi
L_1ce:	movq	_kLSSharedFileListRecentDocumentItems@GOTPCREL(%rip), %rax
L_1d5:	movq	(%rax), %rsi
L_1d8:	xorl	%ebx, %ebx
L_1da:	xorl	%edx, %edx
L_1dc:	callq	_LSSharedFileListCreate
L_1e1:	testq	%rax, %rax
L_1e4:	je	L_37e
L_1ea:	movq	%rax, %r12
L_1ed:	movq	_kLSSharedFileListRecentItemsMaxAmount@GOTPCREL(%rip), %rax
L_1f4:	movq	(%rax), %rsi
L_1f7:	movq	%r12, %rdi
L_1fa:	callq	_LSSharedFileListCopyProperty
L_1ff:	movq	$-0x1, -0x158(%rbp)
L_20a:	testq	%rax, %rax
L_20d:	je	L_374
L_213:	movq	%rax, %rbx
L_216:	movq	%rax, %rdi
L_219:	callq	_CFGetTypeID
L_21e:	movq	%rax, %r14
L_221:	callq	_CFNumberGetTypeID
L_226:	cmpq	%rax, %r14
L_229:	jne	L_36c
L_22f:	leaq	-0x158(%rbp), %rdx
L_236:	movl	$0x4, %esi
L_23b:	movq	%rbx, %rdi
L_23e:	callq	_CFNumberGetValue
L_243:	testb	%al, %al
L_245:	je	L_36c
L_24b:	movq	-0x158(%rbp), %r14
L_252:	movq	%rbx, %rdi
L_255:	callq	_CFRelease
L_25a:	testq	%r14, %r14
L_25d:	js	L_374
L_263:	movb	$0x1, %bl
L_265:	cmpq	$0x0, -0x158(%rbp)
L_26d:	jle	L_376
L_273:	xorps	%xmm0, %xmm0
L_276:	leaq	-0x1c0(%rbp), %rdx
L_27d:	movaps	%xmm0, 0x30(%rdx)
L_281:	movaps	%xmm0, 0x20(%rdx)
L_285:	movaps	%xmm0, 0x10(%rdx)
L_289:	movaps	%xmm0, (%rdx)
L_28c:	leaq	-0x130(%rbp), %rcx
L_293:	movl	$0x10, %r8d
L_299:	movq	-0x148(%rbp), %rdi
L_2a0:	movq	L_selref_2(%rip), %rsi
L_2a7:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_2ad:	testq	%rax, %rax
L_2b0:	je	L_420
L_2b6:	movq	%rax, %r13
L_2b9:	leaq	-0x1c0(%rbp), %rax
L_2c0:	movq	0x10(%rax), %rax
L_2c4:	movq	(%rax), %r14
L_2c7:	movq	_kLSSharedFileListItemBeforeFirst@GOTPCREL(%rip), %r15
L_2ce:	xorl	%ebx, %ebx
L_2d0:	movq	-0x1b0(%rbp), %rax
L_2d7:	cmpq	%r14, (%rax)
L_2da:	je	L_2e8
L_2dc:	movq	-0x148(%rbp), %rdi
L_2e3:	callq	_objc_enumerationMutation
L_2e8:	movq	-0x1b8(%rbp), %rax
L_2ef:	movq	(%rax,%rbx,8), %r8
L_2f3:	movq	(%r15), %rsi
L_2f6:	movq	$0x0, (%rsp)
L_2fe:	movq	%r12, %rdi
L_301:	xorl	%edx, %edx
L_303:	xorl	%ecx, %ecx
L_305:	xorl	%r9d, %r9d
L_308:	callq	_LSSharedFileListInsertItemURL
L_30d:	testq	%rax, %rax
L_310:	je	L_417
L_316:	movq	%rax, %rdi
L_319:	callq	_CFRelease
L_31e:	incq	%rbx
L_321:	cmpq	%rbx, %r13
L_324:	jne	L_2d0
L_326:	movl	$0x10, %r8d
L_32c:	movq	-0x148(%rbp), %rdi
L_333:	movq	L_selref_2(%rip), %rsi
L_33a:	leaq	-0x1c0(%rbp), %rdx
L_341:	leaq	-0x130(%rbp), %rcx
L_348:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_34e:	movq	%rax, %r13
L_351:	testq	%rax, %rax
L_354:	jne	L_2ce
L_35a:	movq	-0x150(%rbp), %r15
L_361:	movq	_objc_msgSend@GOTPCREL(%rip), %r13
L_368:	movb	$0x1, %bl
L_36a:	jmp	L_376
L_36c:	movq	%rbx, %rdi
L_36f:	callq	_CFRelease
L_374:	xorl	%ebx, %ebx
L_376:	movq	%r12, %rdi
L_379:	callq	_CFRelease
L_37e:	testq	%r15, %r15
L_381:	sete	%al
L_384:	orb	%bl, %al
L_386:	jne	L_3f2
L_388:	movq	L_classref_14(%rip), %rbx
L_38f:	movq	_NSCocoaErrorDomain@GOTPCREL(%rip), %rax
L_396:	movq	(%rax), %r14
L_399:	movq	_NSLocalizedDescriptionKey@GOTPCREL(%rip), %rax
L_3a0:	movq	(%rax), %rax
L_3a3:	leaq	-0x140(%rbp), %rcx
L_3aa:	movq	%rax, (%rcx)
L_3ad:	leaq	L_cfstr(%rip), %rax
L_3b4:	leaq	-0x138(%rbp), %rdx
L_3bb:	movq	%rax, (%rdx)
L_3be:	movq	L_classref_15(%rip), %rdi
L_3c5:	movq	L_selref_19(%rip), %rsi
L_3cc:	movl	$0x1, %r8d
L_3d2:	callq	*%r13
L_3d5:	movq	L_selref_17(%rip), %rsi
L_3dc:	movl	$0x200, %ecx
L_3e1:	movq	%rbx, %rdi
L_3e4:	movq	%r14, %rdx
L_3e7:	movq	%rax, %r8
L_3ea:	callq	*%r13
L_3ed:	movq	%rax, (%r15)
L_3f0:	xorl	%ebx, %ebx
L_3f2:	movq	___stack_chk_guard@GOTPCREL(%rip), %rax
L_3f9:	movq	(%rax), %rax
L_3fc:	cmpq	-0x30(%rbp), %rax
L_400:	jne	L_42c
L_402:	movzbl	%bl, %eax
L_405:	addq	$0x1e8, %rsp
L_40c:	popq	%rbx
L_40d:	popq	%r12
L_40f:	popq	%r13
L_411:	popq	%r14
L_413:	popq	%r15
L_415:	popq	%rbp
L_416:	retq
L_417:	xorl	%ebx, %ebx
L_419:	movq	-0x150(%rbp), %r15
L_420:	movq	_objc_msgSend@GOTPCREL(%rip), %r13
L_427:	jmp	L_376
L_42c:	callq	___stack_chk_fail
