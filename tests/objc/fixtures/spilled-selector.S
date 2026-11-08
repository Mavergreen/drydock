/* Fixture: the shape Apple clang 21 emits at -Os for Recaulk's provider body, transcribed
 * instruction for instruction from llvm-objdump output of the arm64-built x86_64 archive
 * member workspace-events.o (Recaulk d19d528, __recaulk_workspace_url_events and the static
 * event() it calls; relocations replaced by the local references below). Before each of its
 * three for-in loops the function loads the loop body's selector references once and spills
 * them to frame slots, then reloads each into rsi for its send; the loops pass frame addresses
 * (an NSFastEnumerationState and a 16-object buffer) to countByEnumeratingWithState:objects:count:,
 * a slot is reused across loops, and a send in the last loop stores a stack argument through rsp.
 * Hand-assembled so the shape does not depend on which compiler builds it. Never executed.
 *
 *   FORM 0  as compiled: every send's selector is followed through its slot
 *   FORM 1  the third loop's slot for appleEventWithEventClass:... has its own address passed to a call:
 *           that slot and setParamDescriptor:forKeyword:'s, above it, are lost; the three below are kept
 *   FORM 2  a write through the third loop's enumeration-state address reaches addObject:'s slot
 *   FORM 3  the back edge of the third loop rewrites setParamDescriptor:forKeyword:'s slot
 *   FORM 4  the third loop's enumeration state, below every slot, is also passed to a function outside
 *           the contract: the callee may write anywhere above it, so all five slots are lost
 *   FORM 5  a push in the third loop's body: rsp no longer has one known offset in the frame
 *   FORM 6  a frame address above every slot (the stack guard's copy) is passed to a function outside
 *           the contract: the callee never writes below it, so all five slots are kept
 */
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
L_name_16:
	.asciz "listDescriptor"
L_name_18:
	.asciz "absoluteString"
L_name_20:
	.asciz "dataUsingEncoding:"
L_name_22:
	.asciz "descriptorWithDescriptorType:data:"
L_name_24:
	.asciz "numberOfItems"
L_name_26:
	.asciz "insertDescriptor:atIndex:"
L_name_28:
	.asciz "descriptorWithString:"
L_name_32:
	.asciz "dictionaryWithObjects:forKeys:count:"
L_name_34:
	.asciz "errorWithDomain:code:userInfo:"
L_name_36:
	.asciz "appleEventWithEventClass:eventID:targetDescriptor:returnID:transactionID:"
L_name_38:
	.asciz "setParamDescriptor:forKeyword:"
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
L_selref_16:
	.quad L_name_16
L_selref_18:
	.quad L_name_18
L_selref_20:
	.quad L_name_20
L_selref_22:
	.quad L_name_22
L_selref_24:
	.quad L_name_24
L_selref_26:
	.quad L_name_26
L_selref_28:
	.quad L_name_28
L_selref_32:
	.quad L_name_32
L_selref_34:
	.quad L_name_34
L_selref_36:
	.quad L_name_36
L_selref_38:
	.quad L_name_38
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_classref_0:
	.quad _OBJC_CLASS_$_NSMutableArray
L_classref_3:
	.quad _OBJC_CLASS_$_NSURL
L_classref_14:
	.quad _OBJC_CLASS_$_NSAppleEventDescriptor
L_classref_29:
	.quad _OBJC_CLASS_$_NSError
L_classref_30:
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

	.globl _url_events
	.p2align 4

_url_events:
L_0:	pushq	%rbp
L_1:	movq	%rsp, %rbp
L_4:	pushq	%r15
L_6:	pushq	%r14
L_8:	pushq	%r13
L_a:	pushq	%r12
L_c:	pushq	%rbx
L_d:	subq	$0x2c8, %rsp
L_14:	movq	%rdx, -0x218(%rbp)
L_1b:	movq	%rsi, -0x210(%rbp)
L_22:	movq	%rdi, %r14
L_25:	movq	___stack_chk_guard@GOTPCREL(%rip), %rax
L_2c:	movq	(%rax), %rax
L_2f:	movq	%rax, -0x30(%rbp)
L_33:	movq	L_classref_0(%rip), %rdi
L_3a:	movq	L_selref_0(%rip), %rbx
L_41:	movq	_objc_msgSend@GOTPCREL(%rip), %r12
L_48:	movq	%rbx, %rsi
L_4b:	callq	*%r12
L_4e:	movq	%rax, -0x1d0(%rbp)
L_55:	movq	L_classref_0(%rip), %rdi
L_5c:	movq	%rbx, %rsi
L_5f:	callq	*%r12
L_62:	movq	%rax, -0x200(%rbp)
L_69:	movq	L_classref_0(%rip), %rdi
L_70:	movq	%rbx, %rsi
L_73:	callq	*%r12
L_76:	movq	%rax, -0x1f0(%rbp)
L_7d:	xorps	%xmm0, %xmm0
L_80:	leaq	-0x2e0(%rbp), %rdx
L_87:	movaps	%xmm0, (%rdx)
L_8a:	movaps	%xmm0, 0x10(%rdx)
L_8e:	movaps	%xmm0, 0x20(%rdx)
L_92:	movaps	%xmm0, 0x30(%rdx)
L_96:	movq	L_selref_2(%rip), %rsi
L_9d:	leaq	-0xb0(%rbp), %rcx
L_a4:	movl	$0x10, %r8d
L_aa:	movq	%r14, -0x1c8(%rbp)
L_b1:	movq	%r14, %rdi
L_b4:	callq	*%r12
L_b7:	movq	%rax, -0x1e8(%rbp)
L_be:	testq	%rax, %rax
L_c1:	je	L_1ce
L_c7:	leaq	-0x2e0(%rbp), %rax
L_ce:	movq	0x10(%rax), %rax
L_d2:	movq	(%rax), %rax
L_d5:	movq	%rax, -0x1e0(%rbp)
L_dc:	movq	L_selref_5(%rip), %r12
L_e3:	movq	L_selref_7(%rip), %r15
L_ea:	movq	L_selref_9(%rip), %rax
L_f1:	movq	%rax, -0x1f8(%rbp)
L_f8:	movq	L_selref_11(%rip), %rax
L_ff:	movq	%rax, -0x1d8(%rbp)
L_106:	xorl	%r13d, %r13d
L_109:	movq	-0x2d0(%rbp), %rax
L_110:	movq	-0x1e0(%rbp), %rcx
L_117:	cmpq	%rcx, (%rax)
L_11a:	je	L_128
L_11c:	movq	-0x1c8(%rbp), %rdi
L_123:	callq	_objc_enumerationMutation
L_128:	movq	-0x2d8(%rbp), %rax
L_12f:	movq	(%rax,%r13,8), %rbx
L_133:	movq	L_classref_3(%rip), %rdi
L_13a:	movq	%r12, %rsi
L_13d:	movq	_objc_msgSend@GOTPCREL(%rip), %r14
L_144:	callq	*%r14
L_147:	movq	%rbx, %rdi
L_14a:	movq	%r15, %rsi
L_14d:	movq	%rax, %rdx
L_150:	callq	*%r14
L_153:	testb	%al, %al
L_155:	je	L_182
L_157:	movq	%rbx, %rdi
L_15a:	movq	-0x1f8(%rbp), %rsi
L_161:	callq	*%r14
L_164:	testb	%al, %al
L_166:	movq	-0x1d0(%rbp), %rdi
L_16d:	cmoveq	-0x200(%rbp), %rdi
L_175:	movq	-0x1d8(%rbp), %rsi
L_17c:	movq	%rbx, %rdx
L_17f:	callq	*%r14
L_182:	incq	%r13
L_185:	cmpq	%r13, -0x1e8(%rbp)
L_18c:	jne	L_109
L_192:	movl	$0x10, %r8d
L_198:	movq	-0x1c8(%rbp), %rdi
L_19f:	movq	L_selref_2(%rip), %rsi
L_1a6:	leaq	-0x2e0(%rbp), %rdx
L_1ad:	leaq	-0xb0(%rbp), %rcx
L_1b4:	movq	_objc_msgSend@GOTPCREL(%rip), %r12
L_1bb:	callq	*%r12
L_1be:	movq	%rax, -0x1e8(%rbp)
L_1c5:	testq	%rax, %rax
L_1c8:	jne	L_dc
L_1ce:	movq	L_selref_13(%rip), %rsi
L_1d5:	movq	-0x1d0(%rbp), %rbx
L_1dc:	movq	%rbx, %rdi
L_1df:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_1e5:	testq	%rax, %rax
L_1e8:	je	L_3ba
L_1ee:	movq	L_classref_14(%rip), %rdi
L_1f5:	movq	L_selref_16(%rip), %rsi
L_1fc:	callq	*%r12
L_1ff:	movq	%rax, %r13
L_202:	xorps	%xmm0, %xmm0
L_205:	leaq	-0x2a0(%rbp), %rdx
L_20c:	movaps	%xmm0, (%rdx)
L_20f:	movaps	%xmm0, 0x10(%rdx)
L_213:	movaps	%xmm0, 0x20(%rdx)
L_217:	movaps	%xmm0, 0x30(%rdx)
L_21b:	leaq	-0x130(%rbp), %rcx
L_222:	movl	$0x10, %r8d
L_228:	movq	%rbx, %rdi
L_22b:	movq	L_selref_2(%rip), %rsi
L_232:	callq	*%r12
L_235:	movq	%rax, -0x1e0(%rbp)
L_23c:	testq	%rax, %rax
L_23f:	je	L_37a
L_245:	leaq	-0x2a0(%rbp), %rax
L_24c:	movq	0x10(%rax), %rax
L_250:	movq	(%rax), %rax
L_253:	movq	%rax, -0x1f8(%rbp)
L_25a:	movq	L_selref_18(%rip), %rax
L_261:	movq	%rax, -0x1e8(%rbp)
L_268:	movq	L_selref_20(%rip), %r14
L_26f:	movq	L_selref_22(%rip), %rax
L_276:	movq	%rax, -0x1c8(%rbp)
L_27d:	movq	L_selref_24(%rip), %rax
L_284:	movq	%rax, -0x208(%rbp)
L_28b:	movq	L_selref_26(%rip), %rax
L_292:	movq	%rax, -0x220(%rbp)
L_299:	xorl	%r15d, %r15d
L_29c:	movq	-0x290(%rbp), %rax
L_2a3:	movq	-0x1f8(%rbp), %rcx
L_2aa:	cmpq	%rcx, (%rax)
L_2ad:	je	L_2bb
L_2af:	movq	-0x1d0(%rbp), %rdi
L_2b6:	callq	_objc_enumerationMutation
L_2bb:	movq	-0x298(%rbp), %rax
L_2c2:	movq	(%rax,%r15,8), %rdi
L_2c6:	movq	-0x1e8(%rbp), %rsi
L_2cd:	callq	*%r12
L_2d0:	movl	$0x4, %edx
L_2d5:	movq	%rax, %rdi
L_2d8:	movq	%r14, %rsi
L_2db:	callq	*%r12
L_2de:	movb	$0x1, %cl
L_2e0:	movl	%ecx, -0x1d8(%rbp)
L_2e6:	testq	%rax, %rax
L_2e9:	je	L_3c4
L_2ef:	movq	L_classref_14(%rip), %rdi
L_2f6:	movq	-0x1c8(%rbp), %rsi
L_2fd:	movl	$0x6675726c, %edx
L_302:	movq	%rax, %rcx
L_305:	callq	*%r12
L_308:	testq	%rax, %rax
L_30b:	je	L_3c4
L_311:	movq	%rax, %rbx
L_314:	movq	%r13, %rdi
L_317:	movq	-0x208(%rbp), %rsi
L_31e:	callq	*%r12
L_321:	leaq	0x1(%rax), %rcx
L_325:	movq	%r13, %rdi
L_328:	movq	-0x220(%rbp), %rsi
L_32f:	movq	%rbx, %rdx
L_332:	callq	*%r12
L_335:	incq	%r15
L_338:	cmpq	%r15, -0x1e0(%rbp)
L_33f:	jne	L_29c
L_345:	movl	$0x10, %r8d
L_34b:	movq	-0x1d0(%rbp), %rdi
L_352:	movq	L_selref_2(%rip), %rsi
L_359:	leaq	-0x2a0(%rbp), %rdx
L_360:	leaq	-0x130(%rbp), %rcx
L_367:	callq	*%r12
L_36a:	movq	%rax, -0x1e0(%rbp)
L_371:	testq	%rax, %rax
L_374:	jne	L_25a
L_37a:	movq	-0x210(%rbp), %rsi
L_381:	andl	$0x2, %esi
L_384:	shll	$0x17, %esi
L_387:	addl	$0x6f646f63, %esi
L_38d:	movl	$0x61657674, %edi
L_392:	movq	%r13, %rdx
L_395:	callq	_event
L_39a:	testq	%rax, %rax
L_39d:	je	L_624
L_3a3:	movq	L_selref_11(%rip), %rsi
L_3aa:	movq	-0x1f0(%rbp), %rdi
L_3b1:	movq	%rax, %rdx
L_3b4:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_3ba:	movl	$0x0, -0x1d8(%rbp)
L_3c4:	xorps	%xmm0, %xmm0
L_3c7:	leaq	-0x260(%rbp), %rdx
L_3ce:	movaps	%xmm0, 0x30(%rdx)
L_3d2:	movaps	%xmm0, 0x20(%rdx)
L_3d6:	movaps	%xmm0, 0x10(%rdx)
L_3da:	movaps	%xmm0, (%rdx)
L_3dd:	leaq	-0x1b0(%rbp), %rcx
L_3e4:	movl	$0x10, %r8d
L_3ea:	movq	-0x200(%rbp), %rdi
L_3f1:	movq	L_selref_2(%rip), %rsi
L_3f8:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_3fe:	testq	%rax, %rax
L_401:	je	L_568
L_407:	movq	%rax, %r12
L_40a:	leaq	-0x260(%rbp), %rax
L_411:	movq	0x10(%rax), %rax
L_415:	movq	(%rax), %rax
L_418:	movq	%rax, -0x1e0(%rbp)
L_41f:	movq	L_selref_18(%rip), %rax
L_426:	movq	%rax, -0x1e8(%rbp)
L_42d:	movq	L_selref_28(%rip), %rax
L_434:	movq	%rax, -0x1f8(%rbp)
L_43b:	movq	L_selref_36(%rip), %rax
L_442:	movq	%rax, -0x1d0(%rbp)
L_449:	movq	L_selref_38(%rip), %rax
L_450:	movq	%rax, -0x1c8(%rbp)
L_457:	movq	L_selref_11(%rip), %rax
L_45e:	movq	%rax, -0x208(%rbp)
#if FORM == 1
leaq	-0x1d0(%rbp), %rdi
callq	_objc_enumerationMutation
#elif FORM == 4
leaq	-0x260(%rbp), %rdi
callq	_objc_enumerationMutation
#elif FORM == 6
leaq	-0x30(%rbp), %rdi
callq	_objc_enumerationMutation
#endif
L_465:	xorl	%r13d, %r13d
L_468:	movq	-0x250(%rbp), %rax
L_46f:	movq	-0x1e0(%rbp), %rcx
L_476:	cmpq	%rcx, (%rax)
L_479:	je	L_487
L_47b:	movq	-0x200(%rbp), %rdi
L_482:	callq	_objc_enumerationMutation
L_487:	movq	-0x258(%rbp), %rax
L_48e:	movq	(%rax,%r13,8), %rdi
L_492:	movq	-0x1e8(%rbp), %rsi
L_499:	movq	_objc_msgSend@GOTPCREL(%rip), %r14
L_4a0:	callq	*%r14
L_4a3:	testq	%rax, %rax
L_4a6:	je	L_575
L_4ac:	movq	L_classref_14(%rip), %rdi
L_4b3:	movq	-0x1f8(%rbp), %rsi
L_4ba:	movq	%rax, %rdx
L_4bd:	callq	*%r14
L_4c0:	testq	%rax, %rax
L_4c3:	je	L_575
L_4c9:	movq	%rax, %r15
L_4cc:	movq	L_classref_14(%rip), %rdi
#if FORM == 5
pushq	%rax
popq	%rax
#endif
L_4d3:	movl	$0x0, (%rsp)
L_4da:	movq	-0x1d0(%rbp), %rsi
L_4e1:	movl	$0x4755524c, %edx
L_4e6:	movl	$0x4755524c, %ecx
L_4eb:	xorl	%r8d, %r8d
L_4ee:	movl	$0xffffffff, %r9d
L_4f4:	callq	*%r14
L_4f7:	testq	%rax, %rax
L_4fa:	je	L_575
L_4fc:	movq	%rax, %rbx
L_4ff:	movq	%rax, %rdi
L_502:	movq	-0x1c8(%rbp), %rsi
L_509:	movq	%r15, %rdx
L_50c:	movl	$0x2d2d2d2d, %ecx
L_511:	callq	*%r14
#if FORM == 2
leaq	-0x260(%rbp), %rax
movq	%rbx, 0x58(%rax)
#endif
L_514:	movq	-0x1f0(%rbp), %rdi
L_51b:	movq	-0x208(%rbp), %rsi
L_522:	movq	%rbx, %rdx
L_525:	callq	*%r14
#if FORM == 3
movq	%r15, -0x1c8(%rbp)
#endif
L_528:	incq	%r13
L_52b:	cmpq	%r13, %r12
L_52e:	jne	L_468
L_534:	movl	$0x10, %r8d
L_53a:	movq	-0x200(%rbp), %rdi
L_541:	movq	L_selref_2(%rip), %rsi
L_548:	leaq	-0x260(%rbp), %rdx
L_54f:	leaq	-0x1b0(%rbp), %rcx
L_556:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_55c:	movq	%rax, %r12
L_55f:	testq	%rax, %rax
L_562:	jne	L_41f
L_568:	cmpb	$0x0, -0x1d8(%rbp)
L_56f:	je	L_5fb
L_575:	movq	-0x218(%rbp), %r15
L_57c:	testq	%r15, %r15
L_57f:	je	L_5f0
L_581:	movq	L_classref_29(%rip), %rbx
L_588:	movq	_NSCocoaErrorDomain@GOTPCREL(%rip), %rax
L_58f:	movq	(%rax), %r14
L_592:	movq	_NSLocalizedDescriptionKey@GOTPCREL(%rip), %rax
L_599:	movq	(%rax), %rax
L_59c:	leaq	-0x1c0(%rbp), %rcx
L_5a3:	movq	%rax, (%rcx)
L_5a6:	leaq	L_cfstr(%rip), %rax
L_5ad:	leaq	-0x1b8(%rbp), %rdx
L_5b4:	movq	%rax, (%rdx)
L_5b7:	movq	L_classref_30(%rip), %rdi
L_5be:	movq	L_selref_32(%rip), %rsi
L_5c5:	movl	$0x1, %r8d
L_5cb:	movq	_objc_msgSend@GOTPCREL(%rip), %r12
L_5d2:	callq	*%r12
L_5d5:	movq	L_selref_34(%rip), %rsi
L_5dc:	movl	$0x100, %ecx
L_5e1:	movq	%rbx, %rdi
L_5e4:	movq	%r14, %rdx
L_5e7:	movq	%rax, %r8
L_5ea:	callq	*%r12
L_5ed:	movq	%rax, (%r15)
L_5f0:	movq	$0x0, -0x1f0(%rbp)
L_5fb:	movq	___stack_chk_guard@GOTPCREL(%rip), %rax
L_602:	movq	(%rax), %rax
L_605:	cmpq	-0x30(%rbp), %rax
L_609:	jne	L_631
L_60b:	movq	-0x1f0(%rbp), %rax
L_612:	addq	$0x2c8, %rsp
L_619:	popq	%rbx
L_61a:	popq	%r12
L_61c:	popq	%r13
L_61e:	popq	%r14
L_620:	popq	%r15
L_622:	popq	%rbp
L_623:	retq
L_624:	movb	$0x1, %al
L_626:	movl	%eax, -0x1d8(%rbp)
L_62c:	jmp	L_3c4
L_631:	callq	___stack_chk_fail

_event:
L_636:	pushq	%rbp
L_637:	movq	%rsp, %rbp
L_63a:	pushq	%r14
L_63c:	pushq	%rbx
L_63d:	subq	$0x10, %rsp
L_641:	movq	%rdx, %rbx
L_644:	movl	%esi, %ecx
L_646:	movl	%edi, %edx
L_648:	movq	L_classref_14(%rip), %rdi
L_64f:	movq	L_selref_36(%rip), %rsi
L_656:	movl	$0x0, (%rsp)
L_65d:	xorl	%r8d, %r8d
L_660:	movl	$0xffffffff, %r9d
L_666:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_66c:	movq	%rax, %r14
L_66f:	testq	%rax, %rax
L_672:	sete	%al
L_675:	testq	%rbx, %rbx
L_678:	sete	%cl
L_67b:	orb	%al, %cl
L_67d:	jne	L_697
L_67f:	movq	L_selref_38(%rip), %rsi
L_686:	movq	%r14, %rdi
L_689:	movq	%rbx, %rdx
L_68c:	movl	$0x2d2d2d2d, %ecx
L_691:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_697:	movq	%r14, %rax
L_69a:	addq	$0x10, %rsp
L_69e:	popq	%rbx
L_69f:	popq	%r14
L_6a1:	popq	%rbp
L_6a2:	retq
