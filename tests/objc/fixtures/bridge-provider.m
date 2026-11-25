// An app-named runtime bridge in the shape of an own-absent provider group: a root the app calls once per class,
// FixtureBridge(cls), that records cls in its class table and class_addMethod's three old-API accessibility methods
// onto it. Each IMP answers from the newer getter when the receiver responds to it, else sends its own selector to
// the superclass of the first bridged class above the receiver's. No constructor. Built with -fobjc-arc.
// Each -D variant is a mutant the objc tests name: TABLE_OTHER (the metaclass, not cls, into the table),
// TABLE_ELSEWHERE (cls also into FixtureBridgeLast), LOOKUP (class_getInstanceMethod before the adds), REPLACE
// (class_replaceMethod for one member), UNGUARDED (the getter sent without its respondsToSelector:), IMP_ELSEWHERE
// (FixtureBridgeLeak returns a member IMP's address, FixtureBridgeLeakMasked and FixtureBridgeLeakSlot it, from a lea and
// from a pointer in data, xor an argument), IMP_LEA (FixtureBridgeLeak alone), NO_FALLBACK (no super send in _attributeValue), SUPER_OTHER
// (_attributeValue super-sends accessibilityAttributeNames, not its own selector) and
// EXTRA_MEMBER (a fourth add, accessibilityRole), UNBOUNDED_SCAN (the slot search not bounded by the table's size) and
// TABLE_DEPENDENT_IMP (the first add's IMP chosen by whether the table's slot 1 is taken), TABLE_LITERAL (the table, in
// __DATA,__data, its bytes registered as a selector name), SELF_CALL (_attributeNames calls itself with another object),
// SUPER_STRET (_attributeValue's super send through objc_msgSendSuper_stret), HELPER_ADD (the third add in
// FixtureBridgeAdd, which the root calls), CONSTRUCTOR (the root's member has an initializer) and ROOT_LEAK (the root
// passes a member IMP's address to printf). A full table adds all the
// same: every path from the root must add exactly the members.
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdio.h>

@protocol FixtureBridgeRole
- (id)accessibilityRole;
@end

#define FIXTURE_BRIDGE_SLOTS 8
#ifdef TABLE_LITERAL
__attribute__((section("__DATA,__data")))
#endif
__unsafe_unretained Class FixtureBridgeClasses[FIXTURE_BRIDGE_SLOTS];
#ifdef TABLE_ELSEWHERE
__unsafe_unretained Class FixtureBridgeLast;
#endif

static Class FixtureBridge_superOf(id self) {
  Class c; int i;
  for (c = object_getClass(self); c; c = class_getSuperclass(c))
    for (i = 0; i < FIXTURE_BRIDGE_SLOTS; i++)
      if (FixtureBridgeClasses[i] == c) return class_getSuperclass(c);
  return Nil;
}

// Inlined, so that each super send is inside its IMP, in every variant.
static inline __attribute__((always_inline)) id FixtureBridge_super(id self, SEL _cmd) {
  struct objc_super sup;
  sup.receiver = self;
  sup.super_class = FixtureBridge_superOf(self);
  return sup.super_class ? ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, _cmd) : nil;
}

#ifdef UNGUARDED
#define RESPONDS(self) 1
#else
#define RESPONDS(self) [self respondsToSelector:@selector(accessibilityRole)]
#endif

id FixtureBridge_attributeNames(id self, SEL _cmd) {
#ifdef SELF_CALL
  if (self != (id)[NSProcessInfo processInfo]) return [FixtureBridge_attributeNames([NSProcessInfo processInfo], _cmd) description];
#endif
  if (RESPONDS(self)) return [(id<FixtureBridgeRole>)self accessibilityRole];
  return FixtureBridge_super(self, _cmd);
}

id FixtureBridge_attributeValue(id self, SEL _cmd, id attribute) {
  if (RESPONDS(self)) return attribute ? [(id<FixtureBridgeRole>)self accessibilityRole] : nil;
#ifdef NO_FALLBACK
  (void)_cmd;
  return nil;
#else
  {
    struct objc_super sup;
    sup.receiver = self;
    sup.super_class = FixtureBridge_superOf(self);
#if defined(SUPER_OTHER)
    (void)_cmd;
    return sup.super_class ? ((id (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&sup, @selector(accessibilityAttributeNames), attribute) : nil;
#elif defined(SUPER_STRET)
    {
      NSRect r = sup.super_class ? ((NSRect (*)(struct objc_super *, SEL, id))objc_msgSendSuper_stret)(&sup, _cmd, attribute) : NSZeroRect;
      return r.size.width > 0 ? attribute : nil;
    }
#else
    return sup.super_class ? ((id (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&sup, _cmd, attribute) : nil;
#endif
  }
#endif
}

BOOL FixtureBridge_isIgnored(id self, SEL _cmd) {
  if (RESPONDS(self)) return [(id<FixtureBridgeRole>)self accessibilityRole] == nil;
  return FixtureBridge_super(self, _cmd) != nil;
}

#ifdef EXTRA_MEMBER
id FixtureBridge_role(id self, SEL _cmd) { (void)self; (void)_cmd; return nil; }
#endif

#ifdef HELPER_ADD
__attribute__((noinline)) void FixtureBridgeAdd(Class cls) {
  class_addMethod(cls, sel_registerName("accessibilityIsIgnored"), (IMP)(void *)FixtureBridge_isIgnored, "c16@0:8");
}
#endif
#ifdef CONSTRUCTOR
__attribute__((constructor, used)) static void FixtureBridgeInit(void) { (void)objc_getClass("NSObject"); }
#endif

#if defined(IMP_ELSEWHERE) || defined(IMP_LEA)
void *FixtureBridgeLeak(void) { return (void *)FixtureBridge_isIgnored; }
#endif
#ifdef IMP_ELSEWHERE
uintptr_t FixtureBridgeLeakMasked(uintptr_t key) { return (uintptr_t)(void *)FixtureBridge_isIgnored ^ key; }
void *FixtureBridgeImpSlot = (void *)FixtureBridge_isIgnored;
uintptr_t FixtureBridgeLeakSlot(uintptr_t key) { return (uintptr_t)FixtureBridgeImpSlot ^ key; }
#endif

void FixtureBridge(Class cls) {
  int i;
  if (!cls) return;
#ifdef TABLE_LITERAL
  if (sel_registerName((const char *)(void *)FixtureBridgeClasses) == NULL) return;
#endif
  // The executor models no SSE: clang22 vectorizes this search otherwise.
#pragma clang loop vectorize(disable) interleave(disable)
#ifdef UNBOUNDED_SCAN
  for (i = 0; FixtureBridgeClasses[i]; i++) {}
#else
  for (i = 0; i < FIXTURE_BRIDGE_SLOTS && FixtureBridgeClasses[i]; i++) {}
  if (i < FIXTURE_BRIDGE_SLOTS)
#endif
#ifdef TABLE_OTHER
    FixtureBridgeClasses[i] = object_getClass(cls);
#else
    FixtureBridgeClasses[i] = cls;
#endif
#ifdef TABLE_ELSEWHERE
  FixtureBridgeLast = cls;
#endif
#ifdef ROOT_LEAK
  printf("%p\n", (void *)FixtureBridge_isIgnored);
#endif
#ifdef LOOKUP
  if (class_getInstanceMethod(cls, sel_registerName("accessibilityAttributeNames"))) return;
#endif
#ifdef TABLE_DEPENDENT_IMP
  class_addMethod(cls, sel_registerName("accessibilityAttributeNames"),
                  FixtureBridgeClasses[1] ? (IMP)(void *)FixtureBridge_isIgnored : (IMP)(void *)FixtureBridge_attributeNames, "@16@0:8");
#else
  class_addMethod(cls, sel_registerName("accessibilityAttributeNames"), (IMP)(void *)FixtureBridge_attributeNames, "@16@0:8");
#endif
  class_addMethod(cls, sel_registerName("accessibilityAttributeValue:"), (IMP)(void *)FixtureBridge_attributeValue, "@24@0:8@16");
#if defined(REPLACE)
  class_replaceMethod(cls, sel_registerName("accessibilityIsIgnored"), (IMP)(void *)FixtureBridge_isIgnored, "c16@0:8");
#elif defined(HELPER_ADD)
  FixtureBridgeAdd(cls);
#else
  class_addMethod(cls, sel_registerName("accessibilityIsIgnored"), (IMP)(void *)FixtureBridge_isIgnored, "c16@0:8");
#endif
#ifdef EXTRA_MEMBER
  class_addMethod(cls, sel_registerName("accessibilityRole"), (IMP)(void *)FixtureBridge_role, "@16@0:8");
#endif
}
