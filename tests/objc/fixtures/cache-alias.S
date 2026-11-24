/* Fixture: two objc2 selector caches at one address, which the reader refuses as cache-alias, its
 * detail naming the later of the two symbols in strcmp order on every host. Never executed. */
	.section __DATA,__data
	.p2align 3
	.globl __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL
	.globl __RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol4hash10CACHED_SEL
__RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol7isEqual10CACHED_SEL:
__RNvNvNtNtNtCs2WYrep5oUp8_5objc27runtime8nsobject16NSObjectProtocol4hash10CACHED_SEL:
	.quad 0

	.text
	.globl _main
_main:
	xorl %eax, %eax
	ret
