/* Fixture: Recaulk's __recaulk_workspace_open_urls_with_ops (d19d528) as Apple clang 21 emits it at -Os,
 * with openWithLaunchServices inlined. Transcribed mechanically from llvm-objdump output of the
 * arm64-built x86_64 archive member workspace.o: every instruction at its own offset (label L_<offset>),
 * each relocation replaced by a local reference, and each selector and class reference named as the
 * reader read the linked probe. Calls to other functions of that member go to the stubs below.
 * Hand-assembled so the shape does not depend on which compiler builds it. Never executed.
 * What the reader must make of it (tests/objc-reader-test.sh):
 *   - the function opens with `btl $0x8, %esi`, which writes no register: the frame stays conventional,
 *     and the selectors spilled to -0x1f0 reach their reloads at +0x24d (line 88), +0x54f (line 63)
 *     and +0x6af (line 65);
 *   - +0x775 is a join where clang merged two sends of line 97: from +0x313, `+[NSMutableDictionary
 *     dictionary]` (rax = &selref, rdi = the class); from +0x333, `-autorelease` of a mutableCopy. The
 *     one call at +0x778 has a different selector and receiver on each path: unknown, correctly;
 *   - -0x1e8's reload at +0xa23 (line 125; b0f7ef3's line 129, x86_64@0x10000150a in its build)
 *     follows the only store reaching it (+0xa07). Two frame addresses escape to callees first on
 *     every path: -0xb0 in r8 to a call through a function pointer (+0x915) and -0x130 to an objc
 *     send that is not an enumeration (+0x9cb). The slot lies below both, and a callee never writes
 *     below what it is given: the reload gives setAttributeDescriptor:forKeyword:. */
	.section __TEXT,__objc_methname,cstring_literals
L_name_4310:
	.asciz "isFileURL"
L_name_4390:
	.asciz "bundleURL"
L_name_4340:
	.asciz "setObject:forKey:"
L_name_42f0:
	.asciz "isKindOfClass:"
L_name_4370:
	.asciz "dataUsingEncoding:"
L_name_4320:
	.asciz "mutableCopy"
L_name_4378:
	.asciz "descriptorWithDescriptorType:data:"
L_name_4328:
	.asciz "autorelease"
L_name_4358:
	.asciz "bundleWithURL:"
L_name_4308:
	.asciz "addObject:"
L_name_4388:
	.asciz "processIdentifier"
L_name_4338:
	.asciz "copy"
L_name_42e8:
	.asciz "class"
L_name_4368:
	.asciz "length"
L_name_4318:
	.asciz "objectForKey:"
L_name_4398:
	.asciz "executableArchitecture"
L_name_4348:
	.asciz "count"
L_name_42f8:
	.asciz "array"
L_name_43a0:
	.asciz "dataWithBytes:length:"
L_name_4350:
	.asciz "objectAtIndex:"
L_name_4300:
	.asciz "countByEnumeratingWithState:objects:count:"
L_name_4380:
	.asciz "setAttributeDescriptor:forKeyword:"
L_name_4330:
	.asciz "dictionary"
L_name_42e0:
	.asciz "raise:format:"
L_name_4360:
	.asciz "bundleIdentifier"
	.section __DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.p2align 3
L_sel_4310:
	.quad L_name_4310
L_sel_4390:
	.quad L_name_4390
L_sel_4340:
	.quad L_name_4340
L_sel_42f0:
	.quad L_name_42f0
L_sel_4370:
	.quad L_name_4370
L_sel_4320:
	.quad L_name_4320
L_sel_4378:
	.quad L_name_4378
L_sel_4328:
	.quad L_name_4328
L_sel_4358:
	.quad L_name_4358
L_sel_4308:
	.quad L_name_4308
L_sel_4388:
	.quad L_name_4388
L_sel_4338:
	.quad L_name_4338
L_sel_42e8:
	.quad L_name_42e8
L_sel_4368:
	.quad L_name_4368
L_sel_4318:
	.quad L_name_4318
L_sel_4398:
	.quad L_name_4398
L_sel_4348:
	.quad L_name_4348
L_sel_42f8:
	.quad L_name_42f8
L_sel_43a0:
	.quad L_name_43a0
L_sel_4350:
	.quad L_name_4350
L_sel_4300:
	.quad L_name_4300
L_sel_4380:
	.quad L_name_4380
L_sel_4330:
	.quad L_name_4330
L_sel_42e0:
	.quad L_name_42e0
L_sel_4360:
	.quad L_name_4360
	.section __DATA,__objc_classrefs,regular,no_dead_strip
	.p2align 3
L_cls_4430:
	.quad _OBJC_CLASS_$_NSURL
L_cls_4460:
	.quad _OBJC_CLASS_$_NSData
L_cls_4448:
	.quad _OBJC_CLASS_$_NSMutableDictionary
L_cls_4428:
	.quad _OBJC_CLASS_$_NSArray
L_cls_4458:
	.quad _OBJC_CLASS_$_NSBundle
L_cls_4438:
	.quad _OBJC_CLASS_$_NSDictionary
L_cls_4440:
	.quad _OBJC_CLASS_$_NSMutableArray
L_cls_4420:
	.quad _OBJC_CLASS_$_NSException
L_cls_4450:
	.quad _OBJC_CLASS_$_NSAppleEventDescriptor
L_cls_4480:
	.quad _OBJC_CLASS_$_NSString
	.section __DATA,__objc_imageinfo,regular,no_dead_strip
	.long 0
	.long 0
	.section __DATA,__data
	.p2align 3
L_cfstr:
	.quad 0, 0, 0, 0
L_data_publicOps:
	.quad 0, 0, 0, 0

	.text
	.globl _main
	.p2align 4
_main:
	xorl %eax, %eax
	retq
	.p2align 4
_failure:
	retq
	.p2align 4
___recaulk_workspace_url_events:
	retq

	.globl _open_urls_with_ops
	.p2align 4
_open_urls_with_ops:
L_0:	pushq	%rbp
L_1:	movq	%rsp, %rbp
L_4:	pushq	%r15
L_6:	pushq	%r14
L_8:	pushq	%r13
L_a:	pushq	%r12
L_c:	pushq	%rbx
L_d:	subq	$0x2b8, %rsp
L_14:	movq	%r9, -0x1c0(%rbp)
L_1b:	movq	%r8, %r15
L_1e:	movq	%rcx, -0x1d0(%rbp)
L_25:	movq	%rdx, %r14
L_28:	movq	%rdi, -0x1c8(%rbp)
L_2f:	movq	___stack_chk_guard@GOTPCREL(%rip), %rax
L_36:	movq	(%rax), %rax
L_39:	movq	%rax, -0x30(%rbp)
L_3d:	movq	%rsi, -0x200(%rbp)
L_44:	testq	%rsi, %rsi
L_47:	setne	%al
L_4a:	testq	%rdx, %rdx
L_4d:	setne	%cl
L_50:	testb	%cl, %al
L_52:	jne	L_7b
L_54:	movq	L_cls_4420(%rip), %rdi
L_5b:	movq	_NSInternalInconsistencyException@GOTPCREL(%rip), %rax
L_62:	movq	(%rax), %rdx
L_65:	movq	L_sel_42e0(%rip), %rsi
L_6c:	leaq	L_cfstr(%rip), %rcx
L_73:	xorl	%eax, %eax
L_75:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_7b:	movq	0x10(%rbp), %rbx
L_7f:	movq	L_cls_4428(%rip), %rdi
L_86:	movq	L_sel_42e8(%rip), %rsi
L_8d:	movq	_objc_msgSend@GOTPCREL(%rip), %r12
L_94:	callq	*%r12
L_97:	movq	L_sel_42f0(%rip), %rsi
L_9e:	movq	-0x200(%rbp), %rdi
L_a5:	movq	%rax, %rdx
L_a8:	callq	*%r12
L_ab:	testb	%al, %al
L_ad:	je	L_fe
L_af:	movq	L_cls_4430(%rip), %rdi
L_b6:	movq	L_sel_42e8(%rip), %rsi
L_bd:	callq	*%r12
L_c0:	movq	%r14, %rdi
L_c3:	movq	L_sel_42f0(%rip), %rsi
L_ca:	movq	%rax, %rdx
L_cd:	callq	*%r12
L_d0:	testb	%al, %al
L_d2:	je	L_fe
L_d4:	testq	%r15, %r15
L_d7:	je	L_125
L_d9:	movq	L_cls_4438(%rip), %rdi
L_e0:	movq	L_sel_42e8(%rip), %rsi
L_e7:	callq	*%r12
L_ea:	movq	%r15, %rdi
L_ed:	movq	L_sel_42f0(%rip), %rsi
L_f4:	movq	%rax, %rdx
L_f7:	callq	*%r12
L_fa:	testb	%al, %al
L_fc:	jne	L_125
L_fe:	movq	L_cls_4420(%rip), %rdi
L_105:	movq	_NSInvalidArgumentException@GOTPCREL(%rip), %rax
L_10c:	movq	(%rax), %rdx
L_10f:	movq	L_sel_42e0(%rip), %rsi
L_116:	leaq	L_cfstr(%rip), %rcx
L_11d:	xorl	%eax, %eax
L_11f:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_125:	movq	%r15, -0x210(%rbp)
L_12c:	movq	%r14, -0x208(%rbp)
L_133:	testq	%rbx, %rbx
L_136:	leaq	L_data_publicOps(%rip), %rax
L_13d:	cmovneq	%rbx, %rax
L_141:	movq	%rax, -0x1d8(%rbp)
L_148:	movq	L_cls_4440(%rip), %rdi
L_14f:	movq	L_sel_42f8(%rip), %r14
L_156:	movq	%r14, %rsi
L_159:	callq	*%r12
L_15c:	movq	%rax, -0x1e8(%rbp)
L_163:	movq	L_cls_4440(%rip), %rdi
L_16a:	movq	%r14, %rsi
L_16d:	callq	*%r12
L_170:	movq	%rax, -0x1e0(%rbp)
L_177:	xorps	%xmm0, %xmm0
L_17a:	leaq	-0x250(%rbp), %rdx
L_181:	movaps	%xmm0, (%rdx)
L_184:	movaps	%xmm0, 0x10(%rdx)
L_188:	movaps	%xmm0, 0x20(%rdx)
L_18c:	movaps	%xmm0, 0x30(%rdx)
L_190:	movq	L_sel_4300(%rip), %rsi
L_197:	leaq	-0x1b0(%rbp), %rcx
L_19e:	movl	$0x10, %r8d
L_1a4:	movq	-0x200(%rbp), %rdi
L_1ab:	callq	*%r12
L_1ae:	testq	%rax, %rax
L_1b1:	je	L_2ad
L_1b7:	movq	%rax, %r14
L_1ba:	leaq	-0x250(%rbp), %rax
L_1c1:	movq	0x10(%rax), %rax
L_1c5:	movq	(%rax), %rax
L_1c8:	movq	%rax, -0x1b8(%rbp)
L_1cf:	movq	L_sel_4308(%rip), %r15
L_1d6:	movq	L_sel_4310(%rip), %rax
L_1dd:	movq	%rax, -0x1f0(%rbp)
L_1e4:	xorl	%r12d, %r12d
L_1e7:	movq	-0x240(%rbp), %rax
L_1ee:	movq	-0x1b8(%rbp), %rcx
L_1f5:	cmpq	%rcx, (%rax)
L_1f8:	je	L_206
L_1fa:	movq	-0x200(%rbp), %rdi
L_201:	callq	_objc_enumerationMutation
L_206:	movq	-0x248(%rbp), %rax
L_20d:	movq	(%rax,%r12,8), %r13
L_211:	movq	L_cls_4430(%rip), %rdi
L_218:	movq	L_sel_42e8(%rip), %rsi
L_21f:	movq	_objc_msgSend@GOTPCREL(%rip), %rbx
L_226:	callq	*%rbx
L_228:	movq	%r13, %rdi
L_22b:	movq	L_sel_42f0(%rip), %rsi
L_232:	movq	%rax, %rdx
L_235:	callq	*%rbx
L_237:	testb	%al, %al
L_239:	je	L_269
L_23b:	movq	-0x1e8(%rbp), %rdi
L_242:	movq	%r15, %rsi
L_245:	movq	%r13, %rdx
L_248:	callq	*%rbx
L_24a:	movq	%r13, %rdi
L_24d:	movq	-0x1f0(%rbp), %rsi
L_254:	callq	*%rbx
L_256:	testb	%al, %al
L_258:	je	L_269
L_25a:	movq	-0x1e0(%rbp), %rdi
L_261:	movq	%r15, %rsi
L_264:	movq	%r13, %rdx
L_267:	callq	*%rbx
L_269:	incq	%r12
L_26c:	cmpq	%r12, %r14
L_26f:	jne	L_1e7
L_275:	movl	$0x10, %r8d
L_27b:	movq	-0x200(%rbp), %rdi
L_282:	movq	L_sel_4300(%rip), %rsi
L_289:	leaq	-0x250(%rbp), %rdx
L_290:	leaq	-0x1b0(%rbp), %rcx
L_297:	movq	_objc_msgSend@GOTPCREL(%rip), %r12
L_29e:	callq	*%r12
L_2a1:	movq	%rax, %r14
L_2a4:	testq	%rax, %rax
L_2a7:	jne	L_1cf
L_2ad:	movq	-0x1d8(%rbp), %rax
L_2b4:	cmpq	$0x0, 0x20(%rax)
L_2b9:	movq	-0x210(%rbp), %r14
L_2c0:	je	L_2e4
L_2c2:	movq	_NSWorkspaceLaunchConfigurationArchitecture@GOTPCREL(%rip), %rax
L_2c9:	movq	(%rax), %rdx
L_2cc:	movq	L_sel_4318(%rip), %rbx
L_2d3:	movq	%r14, %rdi
L_2d6:	movq	%rbx, %rsi
L_2d9:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_2df:	testq	%rax, %rax
L_2e2:	je	L_354
L_2e4:	leaq	-0xb0(%rbp), %rdx
L_2eb:	movq	$0x0, (%rdx)
L_2f2:	movq	-0x1e8(%rbp), %rdi
L_2f9:	movq	-0x1d0(%rbp), %rbx
L_300:	movq	%rbx, %rsi
L_303:	callq	___recaulk_workspace_url_events
L_308:	testq	%rax, %rax
L_30b:	je	L_338
L_30d:	movq	%rax, %r13
L_310:	testq	%r14, %r14
L_313:	je	L_767
L_319:	movq	L_sel_4320(%rip), %rsi
L_320:	movq	%r14, %rdi
L_323:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_329:	movq	%rax, %rdi
L_32c:	leaq	L_sel_4328(%rip), %rax
L_333:	jmp	L_775
L_338:	movq	-0x1c0(%rbp), %rcx
L_33f:	testq	%rcx, %rcx
L_342:	je	L_c26
L_348:	movq	-0xb0(%rbp), %rax
L_34f:	jmp	L_af7
L_354:	movq	_NSWorkspaceLaunchConfigurationEnvironment@GOTPCREL(%rip), %rax
L_35b:	movq	(%rax), %rdx
L_35e:	movq	%r14, %rdi
L_361:	movq	%rbx, %rsi
L_364:	callq	*%r12
L_367:	movq	%rax, -0x1b8(%rbp)
L_36e:	movq	_NSWorkspaceLaunchConfigurationArguments@GOTPCREL(%rip), %rax
L_375:	movq	(%rax), %rdx
L_378:	movq	%r14, %rdi
L_37b:	movq	%rbx, %rsi
L_37e:	callq	*%r12
L_381:	movq	%rax, -0x1c8(%rbp)
L_388:	movq	_NSWorkspaceLaunchConfigurationAppleEvent@GOTPCREL(%rip), %rax
L_38f:	movq	(%rax), %rdx
L_392:	movq	%r14, %rdi
L_395:	movq	%rbx, %rsi
L_398:	callq	*%r12
L_39b:	movq	%rax, %rbx
L_39e:	testq	%rax, %rax
L_3a1:	je	L_3ef
L_3a3:	movq	L_cls_4450(%rip), %rdi
L_3aa:	movq	L_sel_42e8(%rip), %rsi
L_3b1:	callq	*%r12
L_3b4:	movq	%rbx, %rdi
L_3b7:	movq	L_sel_42f0(%rip), %rsi
L_3be:	movq	%rax, %rdx
L_3c1:	callq	*%r12
L_3c4:	testb	%al, %al
L_3c6:	jne	L_3ef
L_3c8:	movq	L_cls_4420(%rip), %rdi
L_3cf:	movq	_NSInvalidArgumentException@GOTPCREL(%rip), %rax
L_3d6:	movq	(%rax), %rdx
L_3d9:	movq	L_sel_42e0(%rip), %rsi
L_3e0:	leaq	L_cfstr(%rip), %rcx
L_3e7:	xorl	%eax, %eax
L_3e9:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_3ef:	movq	%rbx, -0x210(%rbp)
L_3f6:	cmpq	$0x0, -0x1b8(%rbp)
L_3fe:	je	L_429
L_400:	movq	L_cls_4438(%rip), %rdi
L_407:	movq	L_sel_42e8(%rip), %rsi
L_40e:	callq	*%r12
L_411:	movq	-0x1b8(%rbp), %rdi
L_418:	movq	L_sel_42f0(%rip), %rsi
L_41f:	movq	%rax, %rdx
L_422:	callq	*%r12
L_425:	testb	%al, %al
L_427:	je	L_45c
L_429:	cmpq	$0x0, -0x1c8(%rbp)
L_431:	je	L_483
L_433:	movq	L_cls_4428(%rip), %rdi
L_43a:	movq	L_sel_42e8(%rip), %rsi
L_441:	callq	*%r12
L_444:	movq	-0x1c8(%rbp), %rdi
L_44b:	movq	L_sel_42f0(%rip), %rsi
L_452:	movq	%rax, %rdx
L_455:	callq	*%r12
L_458:	testb	%al, %al
L_45a:	jne	L_483
L_45c:	movq	L_cls_4420(%rip), %rdi
L_463:	movq	_NSInvalidArgumentException@GOTPCREL(%rip), %rax
L_46a:	movq	(%rax), %rdx
L_46d:	movq	L_sel_42e0(%rip), %rsi
L_474:	leaq	L_cfstr(%rip), %rcx
L_47b:	xorl	%eax, %eax
L_47d:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_483:	xorps	%xmm0, %xmm0
L_486:	leaq	-0x2d0(%rbp), %rdx
L_48d:	movaps	%xmm0, 0x30(%rdx)
L_491:	movaps	%xmm0, 0x20(%rdx)
L_495:	movaps	%xmm0, 0x10(%rdx)
L_499:	movaps	%xmm0, (%rdx)
L_49c:	leaq	-0xb0(%rbp), %rcx
L_4a3:	movl	$0x10, %r8d
L_4a9:	movq	-0x1c8(%rbp), %rdi
L_4b0:	movq	L_sel_4300(%rip), %rsi
L_4b7:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_4bd:	testq	%rax, %rax
L_4c0:	je	L_5a8
L_4c6:	movq	%rax, %r14
L_4c9:	leaq	-0x2d0(%rbp), %rax
L_4d0:	movq	0x10(%rax), %rax
L_4d4:	movq	(%rax), %rbx
L_4d7:	movq	_NSInvalidArgumentException@GOTPCREL(%rip), %rax
L_4de:	movq	(%rax), %rax
L_4e1:	movq	%rax, -0x1e0(%rbp)
L_4e8:	movq	L_sel_42e0(%rip), %rax
L_4ef:	movq	%rax, -0x1f0(%rbp)
L_4f6:	xorl	%r12d, %r12d
L_4f9:	movq	-0x2c0(%rbp), %rax
L_500:	cmpq	%rbx, (%rax)
L_503:	je	L_511
L_505:	movq	-0x1c8(%rbp), %rdi
L_50c:	callq	_objc_enumerationMutation
L_511:	movq	-0x2c8(%rbp), %rax
L_518:	movq	(%rax,%r12,8), %r13
L_51c:	movq	L_cls_4480(%rip), %rdi
L_523:	movq	L_sel_42e8(%rip), %rsi
L_52a:	movq	_objc_msgSend@GOTPCREL(%rip), %r15
L_531:	callq	*%r15
L_534:	movq	%r13, %rdi
L_537:	movq	L_sel_42f0(%rip), %rsi
L_53e:	movq	%rax, %rdx
L_541:	callq	*%r15
L_544:	testb	%al, %al
L_546:	jne	L_56c
L_548:	movq	L_cls_4420(%rip), %rdi
L_54f:	movq	-0x1f0(%rbp), %rsi
L_556:	movq	-0x1e0(%rbp), %rdx
L_55d:	leaq	L_cfstr(%rip), %rcx
L_564:	xorl	%eax, %eax
L_566:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_56c:	incq	%r12
L_56f:	cmpq	%r12, %r14
L_572:	jne	L_4f9
L_574:	movl	$0x10, %r8d
L_57a:	movq	-0x1c8(%rbp), %rdi
L_581:	movq	L_sel_4300(%rip), %rsi
L_588:	leaq	-0x2d0(%rbp), %rdx
L_58f:	leaq	-0xb0(%rbp), %rcx
L_596:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_59c:	movq	%rax, %r14
L_59f:	testq	%rax, %rax
L_5a2:	jne	L_4e8
L_5a8:	leaq	-0x290(%rbp), %rdx
L_5af:	xorps	%xmm0, %xmm0
L_5b2:	movaps	%xmm0, 0x30(%rdx)
L_5b6:	movaps	%xmm0, 0x20(%rdx)
L_5ba:	movaps	%xmm0, 0x10(%rdx)
L_5be:	movaps	%xmm0, (%rdx)
L_5c1:	leaq	-0x130(%rbp), %rcx
L_5c8:	movl	$0x10, %r8d
L_5ce:	movq	-0x1b8(%rbp), %rdi
L_5d5:	movq	L_sel_4300(%rip), %rsi
L_5dc:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_5e2:	testq	%rax, %rax
L_5e5:	je	L_709
L_5eb:	movq	%rax, %r12
L_5ee:	leaq	-0x290(%rbp), %rax
L_5f5:	movq	0x10(%rax), %rax
L_5f9:	movq	(%rax), %r14
L_5fc:	movq	_NSInvalidArgumentException@GOTPCREL(%rip), %rax
L_603:	movq	(%rax), %rax
L_606:	movq	%rax, -0x1e0(%rbp)
L_60d:	movq	L_sel_42e0(%rip), %rax
L_614:	movq	%rax, -0x1f0(%rbp)
L_61b:	xorl	%ebx, %ebx
L_61d:	movq	-0x280(%rbp), %rax
L_624:	cmpq	%r14, (%rax)
L_627:	je	L_635
L_629:	movq	-0x1b8(%rbp), %rdi
L_630:	callq	_objc_enumerationMutation
L_635:	movq	-0x288(%rbp), %rax
L_63c:	movq	(%rax,%rbx,8), %r13
L_640:	movq	L_cls_4480(%rip), %rdi
L_647:	movq	L_sel_42e8(%rip), %rsi
L_64e:	movq	_objc_msgSend@GOTPCREL(%rip), %r15
L_655:	callq	*%r15
L_658:	movq	%r13, %rdi
L_65b:	movq	L_sel_42f0(%rip), %rsi
L_662:	movq	%rax, %rdx
L_665:	callq	*%r15
L_668:	testb	%al, %al
L_66a:	je	L_6a8
L_66c:	movq	-0x1b8(%rbp), %rdi
L_673:	movq	L_sel_4318(%rip), %rsi
L_67a:	movq	%r13, %rdx
L_67d:	callq	*%r15
L_680:	movq	%rax, %r13
L_683:	movq	L_cls_4480(%rip), %rdi
L_68a:	movq	L_sel_42e8(%rip), %rsi
L_691:	callq	*%r15
L_694:	movq	%r13, %rdi
L_697:	movq	L_sel_42f0(%rip), %rsi
L_69e:	movq	%rax, %rdx
L_6a1:	callq	*%r15
L_6a4:	testb	%al, %al
L_6a6:	jne	L_6c9
L_6a8:	movq	L_cls_4420(%rip), %rdi
L_6af:	movq	-0x1f0(%rbp), %rsi
L_6b6:	movq	-0x1e0(%rbp), %rdx
L_6bd:	leaq	L_cfstr(%rip), %rcx
L_6c4:	xorl	%eax, %eax
L_6c6:	callq	*%r15
L_6c9:	incq	%rbx
L_6cc:	cmpq	%rbx, %r12
L_6cf:	jne	L_61d
L_6d5:	movl	$0x10, %r8d
L_6db:	movq	-0x1b8(%rbp), %rdi
L_6e2:	movq	L_sel_4300(%rip), %rsi
L_6e9:	leaq	-0x290(%rbp), %rdx
L_6f0:	leaq	-0x130(%rbp), %rcx
L_6f7:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_6fd:	movq	%rax, %r12
L_700:	testq	%rax, %rax
L_703:	jne	L_60d
L_709:	movq	-0x1d0(%rbp), %rax
L_710:	andl	$0x3903c2, %eax
L_715:	movq	%rax, -0x1d0(%rbp)
L_71c:	movl	$0x0, -0x1f4(%rbp)
L_726:	movq	-0x1d8(%rbp), %rax
L_72d:	movq	0x20(%rax), %rbx
L_731:	movq	-0x210(%rbp), %rdi
L_738:	testq	%rdi, %rdi
L_73b:	je	L_aff
L_741:	movq	L_sel_4338(%rip), %rsi
L_748:	movq	_objc_msgSend@GOTPCREL(%rip), %r14
L_74f:	callq	*%r14
L_752:	movq	L_sel_4328(%rip), %rsi
L_759:	movq	%rax, %rdi
L_75c:	callq	*%r14
L_75f:	movq	%rax, %r9
L_762:	jmp	L_b02
L_767:	leaq	L_sel_4330(%rip), %rax
L_76e:	movq	L_cls_4448(%rip), %rdi
L_775:	movq	(%rax), %rsi
L_778:	callq	*%r12
L_77b:	movq	%rax, %r15
L_77e:	movq	_NSWorkspaceLaunchConfigurationAppleEvent@GOTPCREL(%rip), %rax
L_785:	movq	(%rax), %rdx
L_788:	movq	L_sel_4318(%rip), %rsi
L_78f:	movq	%r15, %rdi
L_792:	movq	%rdx, -0x1b8(%rbp)
L_799:	callq	*%r12
L_79c:	testq	%rax, %rax
L_79f:	movq	%r13, -0x1f0(%rbp)
L_7a6:	je	L_81c
L_7a8:	movq	%rax, %r14
L_7ab:	movq	L_cls_4450(%rip), %rdi
L_7b2:	movq	L_sel_42e8(%rip), %rsi
L_7b9:	callq	*%r12
L_7bc:	movq	%r14, %rdi
L_7bf:	movq	L_sel_42f0(%rip), %rsi
L_7c6:	movq	%rax, %rdx
L_7c9:	callq	*%r12
L_7cc:	testb	%al, %al
L_7ce:	jne	L_7f7
L_7d0:	movq	L_cls_4420(%rip), %rdi
L_7d7:	movq	_NSInvalidArgumentException@GOTPCREL(%rip), %rax
L_7de:	movq	(%rax), %rdx
L_7e1:	movq	L_sel_42e0(%rip), %rsi
L_7e8:	leaq	L_cfstr(%rip), %rcx
L_7ef:	xorl	%eax, %eax
L_7f1:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_7f7:	movq	L_sel_4338(%rip), %rsi
L_7fe:	movq	%r14, %rdi
L_801:	callq	*%r12
L_804:	movq	L_sel_4328(%rip), %rsi
L_80b:	movq	%rax, %rdi
L_80e:	callq	*%r12
L_811:	movq	%rax, %r12
L_814:	xorl	%r13d, %r13d
L_817:	jmp	L_8d9
L_81c:	movq	L_sel_4348(%rip), %rsi
L_823:	movq	%r13, %rdi
L_826:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_82c:	testq	%rax, %rax
L_82f:	je	L_c4e
L_835:	movq	L_sel_4350(%rip), %rsi
L_83c:	movq	%r13, %rdi
L_83f:	xorl	%edx, %edx
L_841:	callq	*%r12
L_844:	movq	%r12, %rbx
L_847:	movq	%rax, %r12
L_84a:	movq	L_cls_4458(%rip), %rdi
L_851:	movq	L_sel_4358(%rip), %rsi
L_858:	movq	-0x208(%rbp), %rdx
L_85f:	callq	*%rbx
L_861:	movq	L_sel_4360(%rip), %rsi
L_868:	movq	%rax, %rdi
L_86b:	callq	*%rbx
L_86d:	movq	%rax, %r14
L_870:	movq	L_sel_4368(%rip), %rsi
L_877:	movq	%rax, %rdi
L_87a:	callq	*%rbx
L_87c:	movl	$0x1, %r13d
L_882:	testq	%rax, %rax
L_885:	je	L_8d2
L_887:	movq	L_cls_4450(%rip), %rax
L_88e:	movq	%rax, -0x1e8(%rbp)
L_895:	movq	L_sel_4370(%rip), %rsi
L_89c:	movl	$0x4, %edx
L_8a1:	movq	%r14, %rdi
L_8a4:	callq	*%rbx
L_8a6:	movq	L_sel_4378(%rip), %rsi
L_8ad:	movq	-0x1e8(%rbp), %rdi
L_8b4:	movl	$0x62756e64, %edx
L_8b9:	movq	%rax, %rcx
L_8bc:	callq	*%rbx
L_8be:	movq	L_sel_4380(%rip), %rsi
L_8c5:	movq	%r12, %rdi
L_8c8:	movq	%rax, %rdx
L_8cb:	movl	$0x61646472, %ecx
L_8d0:	callq	*%rbx
L_8d2:	movq	-0x1d0(%rbp), %rbx
L_8d9:	movq	L_sel_4340(%rip), %rsi
L_8e0:	movq	%r15, %rdi
L_8e3:	movq	%r12, %rdx
L_8e6:	movq	-0x1b8(%rbp), %rcx
L_8ed:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_8f3:	movq	-0x208(%rbp), %rsi
L_8fa:	leaq	-0xb0(%rbp), %r8
L_901:	movq	-0x1c8(%rbp), %rdi
L_908:	movq	%rbx, %rdx
L_90b:	movq	%r15, %rcx
L_90e:	movq	-0x1d8(%rbp), %rax
L_915:	callq	*(%rax)
L_917:	testq	%rax, %rax
L_91a:	je	L_ad7
L_920:	movq	L_sel_4388(%rip), %r12
L_927:	movq	%rax, %rdi
L_92a:	movq	%r12, %rsi
L_92d:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_933:	movl	%eax, -0x130(%rbp)
L_939:	testl	%eax, %eax
L_93b:	jle	L_ac1
L_941:	movl	%eax, %r15d
L_944:	movl	%eax, %edi
L_946:	movq	-0x1d8(%rbp), %rax
L_94d:	callq	*0x8(%rax)
L_950:	testq	%rax, %rax
L_953:	je	L_ac1
L_959:	movq	%rax, %r14
L_95c:	movq	%rax, %rdi
L_95f:	movq	%r12, %rsi
L_962:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_968:	cmpl	%r15d, %eax
L_96b:	jne	L_ac1
L_971:	movq	L_sel_4390(%rip), %rsi
L_978:	movq	%r14, %rdi
L_97b:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_981:	testq	%rax, %rax
L_984:	je	L_ac1
L_98a:	movq	L_sel_4398(%rip), %rsi
L_991:	movq	%r14, %rdi
L_994:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_99a:	testq	%rax, %rax
L_99d:	jle	L_ac1
L_9a3:	movq	L_cls_4450(%rip), %r15
L_9aa:	movq	L_cls_4460(%rip), %rdi
L_9b1:	movq	L_sel_43a0(%rip), %rsi
L_9b8:	leaq	-0x130(%rbp), %rdx
L_9bf:	movl	$0x4, %ecx
L_9c4:	movq	_objc_msgSend@GOTPCREL(%rip), %rbx
L_9cb:	callq	*%rbx
L_9cd:	movq	L_sel_4378(%rip), %rsi
L_9d4:	movq	%r15, %rdi
L_9d7:	movl	$0x6b706964, %edx
L_9dc:	movq	%rax, %rcx
L_9df:	callq	*%rbx
L_9e1:	movq	%rax, -0x1b8(%rbp)
L_9e8:	movq	L_sel_4348(%rip), %rsi
L_9ef:	movq	-0x1f0(%rbp), %r15
L_9f6:	movq	%r15, %rdi
L_9f9:	callq	*%rbx
L_9fb:	cmpq	%rax, %r13
L_9fe:	jae	L_a61
L_a00:	movq	L_sel_4380(%rip), %rax
L_a07:	movq	%rax, -0x1e8(%rbp)
L_a0e:	movq	%r15, %rdi
L_a11:	movq	L_sel_4350(%rip), %rsi
L_a18:	movq	%r13, %rdx
L_a1b:	callq	*%rbx
L_a1d:	movq	%rax, %r12
L_a20:	movq	%rax, %rdi
L_a23:	movq	-0x1e8(%rbp), %rsi
L_a2a:	movq	-0x1b8(%rbp), %rdx
L_a31:	movl	$0x61646472, %ecx
L_a36:	callq	*%rbx
L_a38:	movq	%r12, %rdi
L_a3b:	movq	-0x1d8(%rbp), %rax
L_a42:	callq	*0x10(%rax)
L_a45:	testl	%eax, %eax
L_a47:	jne	L_c6e
L_a4d:	incq	%r13
L_a50:	movq	%r15, %rdi
L_a53:	movq	L_sel_4348(%rip), %rsi
L_a5a:	callq	*%rbx
L_a5c:	cmpq	%rax, %r13
L_a5f:	jb	L_a0e
L_a61:	movq	-0x1e0(%rbp), %rdi
L_a68:	movq	L_sel_4348(%rip), %rsi
L_a6f:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_a75:	movq	-0x1d0(%rbp), %rsi
L_a7c:	btl	$0x8, %esi
L_a80:	jb	L_aae
L_a82:	testq	%rax, %rax
L_a85:	je	L_aae
L_a87:	leaq	-0xb0(%rbp), %rdx
L_a8e:	movq	$0x0, (%rdx)
L_a95:	movq	-0x1e0(%rbp), %rdi
L_a9c:	movq	-0x1d8(%rbp), %rax
L_aa3:	callq	*0x18(%rax)
L_aa6:	testb	%al, %al
L_aa8:	je	L_c84
L_aae:	movq	-0x200(%rbp), %rdi
L_ab5:	movq	L_sel_4348(%rip), %rsi
L_abc:	jmp	L_bd0
L_ac1:	movq	_NSPOSIXErrorDomain@GOTPCREL(%rip), %rax
L_ac8:	movq	(%rax), %rsi
L_acb:	leaq	L_cfstr(%rip), %rcx
L_ad2:	jmp	L_c15
L_ad7:	movq	-0xb0(%rbp), %rax
L_ade:	testq	%rax, %rax
L_ae1:	je	L_c56
L_ae7:	movq	-0x1c0(%rbp), %rcx
L_aee:	testq	%rcx, %rcx
L_af1:	je	L_c26
L_af7:	movq	%rax, (%rcx)
L_afa:	jmp	L_c26
L_aff:	xorl	%r9d, %r9d
L_b02:	leaq	-0x1f4(%rbp), %rax
L_b09:	movq	%rax, (%rsp)
L_b0d:	movq	-0x1e8(%rbp), %rdi
L_b14:	movq	-0x208(%rbp), %rsi
L_b1b:	movq	-0x1d0(%rbp), %rdx
L_b22:	movq	-0x1b8(%rbp), %rcx
L_b29:	movq	-0x1c8(%rbp), %r8
L_b30:	callq	*%rbx
L_b32:	testl	%eax, %eax
L_b34:	je	L_b5c
L_b36:	cmpl	$0xffe1e10f, %eax
L_b3b:	jne	L_bee
L_b41:	movq	_NSCocoaErrorDomain@GOTPCREL(%rip), %rax
L_b48:	movq	(%rax), %rsi
L_b4b:	leaq	L_cfstr(%rip), %rcx
L_b52:	movl	$0x104, %edx
L_b57:	jmp	L_c1a
L_b5c:	movl	-0x1f4(%rbp), %edi
L_b62:	testl	%edi, %edi
L_b64:	jle	L_c04
L_b6a:	movq	-0x1d8(%rbp), %rax
L_b71:	callq	*0x8(%rax)
L_b74:	testq	%rax, %rax
L_b77:	je	L_c04
L_b7d:	movq	%rax, %r14
L_b80:	movq	L_sel_4388(%rip), %rsi
L_b87:	movq	%rax, %rdi
L_b8a:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_b90:	cmpl	-0x1f4(%rbp), %eax
L_b96:	jne	L_c04
L_b98:	movq	L_sel_4390(%rip), %rsi
L_b9f:	movq	%r14, %rdi
L_ba2:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_ba8:	testq	%rax, %rax
L_bab:	je	L_c04
L_bad:	movq	L_sel_4398(%rip), %rsi
L_bb4:	movq	%r14, %rdi
L_bb7:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_bbd:	testq	%rax, %rax
L_bc0:	jle	L_c04
L_bc2:	movq	L_sel_4348(%rip), %rsi
L_bc9:	movq	-0x200(%rbp), %rdi
L_bd0:	callq	*_objc_msgSend@GOTPCREL(%rip)
L_bd6:	testq	%rax, %rax
L_bd9:	jne	L_c29
L_bdb:	movq	_NSCocoaErrorDomain@GOTPCREL(%rip), %rax
L_be2:	movq	(%rax), %rsi
L_be5:	leaq	L_cfstr(%rip), %rcx
L_bec:	jmp	L_c67
L_bee:	movq	_NSOSStatusErrorDomain@GOTPCREL(%rip), %rcx
L_bf5:	movq	(%rcx), %rsi
L_bf8:	movslq	%eax, %rdx
L_bfb:	leaq	L_cfstr(%rip), %rcx
L_c02:	jmp	L_c1a
L_c04:	movq	_NSPOSIXErrorDomain@GOTPCREL(%rip), %rax
L_c0b:	movq	(%rax), %rsi
L_c0e:	leaq	L_cfstr(%rip), %rcx
L_c15:	movl	$0x3, %edx
L_c1a:	movq	-0x1c0(%rbp), %rdi
L_c21:	callq	_failure
L_c26:	xorl	%r14d, %r14d
L_c29:	movq	___stack_chk_guard@GOTPCREL(%rip), %rax
L_c30:	movq	(%rax), %rax
L_c33:	cmpq	-0x30(%rbp), %rax
L_c37:	jne	L_caf
L_c39:	movq	%r14, %rax
L_c3c:	addq	$0x2b8, %rsp
L_c43:	popq	%rbx
L_c44:	popq	%r12
L_c46:	popq	%r13
L_c48:	popq	%r14
L_c4a:	popq	%r15
L_c4c:	popq	%rbp
L_c4d:	retq	
L_c4e:	xorl	%r13d, %r13d
L_c51:	jmp	L_8f3
L_c56:	movq	_NSCocoaErrorDomain@GOTPCREL(%rip), %rax
L_c5d:	movq	(%rax), %rsi
L_c60:	leaq	L_cfstr(%rip), %rcx
L_c67:	movl	$0x100, %edx
L_c6c:	jmp	L_c1a
L_c6e:	movq	_NSOSStatusErrorDomain@GOTPCREL(%rip), %rcx
L_c75:	movq	(%rcx), %rsi
L_c78:	movslq	%eax, %rdx
L_c7b:	leaq	L_cfstr(%rip), %rcx
L_c82:	jmp	L_c1a
L_c84:	movq	-0xb0(%rbp), %rax
L_c8b:	testq	%rax, %rax
L_c8e:	jne	L_ae7
L_c94:	movq	_NSCocoaErrorDomain@GOTPCREL(%rip), %rax
L_c9b:	movq	(%rax), %rsi
L_c9e:	leaq	L_cfstr(%rip), %rcx
L_ca5:	movl	$0x200, %edx
L_caa:	jmp	L_c1a
L_caf:	callq	___stack_chk_fail
