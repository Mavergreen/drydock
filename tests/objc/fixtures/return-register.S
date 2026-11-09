/* Fixture: an objc entry point left in a return register at a method's return, the shape of
 * upstream iTerm2 3.0.15's -[VT100Screen clearBuffer] (0x100196431: `mov rax, r13` before a branch
 * that either tail-calls through rax or returns) and -[iTermRecentDirectoryMO(Additions) compare:]
 * (0x10005c5ea: a copy left in rdx). Still cannot-measure ("is returned"); the detail names what the
 * method's own type encoding says of the register. The class metadata is Apple clang 6's -S output for
 * an empty ReturnProbe; the method bodies are hand-assembled. Never executed.
 *   -[ReturnProbe tick:]   v24@0:8@16: rax holds the entry point at a ret of a method returning void
 *   -[ReturnProbe rank]    q16@0:8: rdx holds it at a ret of a method returning one integer
 *   -[ReturnProbe thing]   @16@0:8: rax holds it at a ret of a method returning an object, which it
 *                          may be: the detail stays "is returned"
 */
	.section	__TEXT,__objc_methname,cstring_literals
L_sel_description:
	.asciz	"description"
	.section	__DATA,__objc_selrefs,literal_pointers,no_dead_strip
	.align	3
L_selref_description:
	.quad	L_sel_description

	.text
	.align	4, 0x90
"-[ReturnProbe tick:]":
	pushq	%rbp
	movq	%rsp, %rbp
	movq	_objc_msgSend@GOTPCREL(%rip), %rax
	testq	%rdx, %rdx
	je	Ltick_ret
	movq	%rdx, %rdi
	movq	L_selref_description(%rip), %rsi
	popq	%rbp
	jmpq	*%rax
Ltick_ret:
	popq	%rbp
	retq

	.align	4, 0x90
"-[ReturnProbe rank]":
	pushq	%rbp
	movq	%rsp, %rbp
	movq	_objc_msgSend@GOTPCREL(%rip), %rdx
	xorl	%eax, %eax
	popq	%rbp
	retq

	.align	4, 0x90
"-[ReturnProbe thing]":
	pushq	%rbp
	movq	%rsp, %rbp
	movq	_objc_msgSend@GOTPCREL(%rip), %rax
	popq	%rbp
	retq

	.globl	_main
	.align	4, 0x90
_main:
	xorl	%eax, %eax
	retq

	.section	__TEXT,__objc_classname,cstring_literals
L_OBJC_CLASS_NAME_:                     ## @"\01L_OBJC_CLASS_NAME_"
	.asciz	"ReturnProbe"

	.section	__DATA,__objc_const
	.align	3                       ## @"\01l_OBJC_METACLASS_RO_$_ReturnProbe"
l_OBJC_METACLASS_RO_$_ReturnProbe:
	.long	1                       ## 0x1
	.long	40                      ## 0x28
	.long	40                      ## 0x28
	.space	4
	.quad	0
	.quad	L_OBJC_CLASS_NAME_
	.quad	0
	.quad	0
	.quad	0
	.quad	0
	.quad	0

	.section	__DATA,__objc_data
	.globl	_OBJC_METACLASS_$_ReturnProbe ## @"OBJC_METACLASS_$_ReturnProbe"
	.align	3
_OBJC_METACLASS_$_ReturnProbe:
	.quad	_OBJC_METACLASS_$_NSObject
	.quad	_OBJC_METACLASS_$_NSObject
	.quad	__objc_empty_cache
	.quad	0
	.quad	l_OBJC_METACLASS_RO_$_ReturnProbe

	.section	__TEXT,__objc_methname,cstring_literals
L_OBJC_METH_VAR_NAME_:                  ## @"\01L_OBJC_METH_VAR_NAME_"
	.asciz	"tick:"

	.section	__TEXT,__objc_methtype,cstring_literals
L_OBJC_METH_VAR_TYPE_:                  ## @"\01L_OBJC_METH_VAR_TYPE_"
	.asciz	"v24@0:8@16"

	.section	__TEXT,__objc_methname,cstring_literals
L_OBJC_METH_VAR_NAME_1:                 ## @"\01L_OBJC_METH_VAR_NAME_1"
	.asciz	"rank"

	.section	__TEXT,__objc_methtype,cstring_literals
L_OBJC_METH_VAR_TYPE_2:                 ## @"\01L_OBJC_METH_VAR_TYPE_2"
	.asciz	"q16@0:8"

	.section	__TEXT,__objc_methname,cstring_literals
L_OBJC_METH_VAR_NAME_3:                 ## @"\01L_OBJC_METH_VAR_NAME_3"
	.asciz	"thing"

	.section	__TEXT,__objc_methtype,cstring_literals
L_OBJC_METH_VAR_TYPE_4:                 ## @"\01L_OBJC_METH_VAR_TYPE_4"
	.asciz	"@16@0:8"

	.section	__DATA,__objc_const
	.align	3                       ## @"\01l_OBJC_$_INSTANCE_METHODS_ReturnProbe"
l_OBJC_$_INSTANCE_METHODS_ReturnProbe:
	.long	24                      ## 0x18
	.long	3                       ## 0x3
	.quad	L_OBJC_METH_VAR_NAME_
	.quad	L_OBJC_METH_VAR_TYPE_
	.quad	"-[ReturnProbe tick:]"
	.quad	L_OBJC_METH_VAR_NAME_1
	.quad	L_OBJC_METH_VAR_TYPE_2
	.quad	"-[ReturnProbe rank]"
	.quad	L_OBJC_METH_VAR_NAME_3
	.quad	L_OBJC_METH_VAR_TYPE_4
	.quad	"-[ReturnProbe thing]"

	.align	3                       ## @"\01l_OBJC_CLASS_RO_$_ReturnProbe"
l_OBJC_CLASS_RO_$_ReturnProbe:
	.long	0                       ## 0x0
	.long	8                       ## 0x8
	.long	8                       ## 0x8
	.space	4
	.quad	0
	.quad	L_OBJC_CLASS_NAME_
	.quad	l_OBJC_$_INSTANCE_METHODS_ReturnProbe
	.quad	0
	.quad	0
	.quad	0
	.quad	0

	.section	__DATA,__objc_data
	.globl	_OBJC_CLASS_$_ReturnProbe ## @"OBJC_CLASS_$_ReturnProbe"
	.align	3
_OBJC_CLASS_$_ReturnProbe:
	.quad	_OBJC_METACLASS_$_ReturnProbe
	.quad	_OBJC_CLASS_$_NSObject
	.quad	__objc_empty_cache
	.quad	0
	.quad	l_OBJC_CLASS_RO_$_ReturnProbe

	.section	__DATA,__objc_classlist,regular,no_dead_strip
	.align	3                       ## @"\01L_OBJC_LABEL_CLASS_$"
L_OBJC_LABEL_CLASS_$:
	.quad	_OBJC_CLASS_$_ReturnProbe

	.section	__DATA,__objc_imageinfo,regular,no_dead_strip
L_OBJC_IMAGE_INFO:
	.long	0
	.long	0


.subsections_via_symbols
