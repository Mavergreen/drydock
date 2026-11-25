// An app-named runtime bridge in the shape of an own-absent provider group: a root the app calls once per class,
// FixtureBridge(cls), that records cls in its class table and class_addMethod's three old-API accessibility methods
// onto it. Each IMP answers from the newer getter when the receiver responds to it, else sends its own selector to
// the superclass of the first bridged class above the receiver's. No constructor. Built with -fobjc-arc.
// Each -D variant is a mutant the objc tests name: TABLE_OTHER (the metaclass, not cls, into the table),
// TABLE_ELSEWHERE (cls also into FixtureBridgeLast), LOOKUP (class_getInstanceMethod before the adds), REPLACE
// (class_replaceMethod for one member), UNGUARDED (the getter sent without its respondsToSelector:), IMP_ELSEWHERE
// (FixtureBridgeLeak returns a member IMP's address, FixtureBridgeLeakMasked and FixtureBridgeLeakSlot it, from a lea and
// from a pointer in data, xor an argument), NO_FALLBACK (no super send in _attributeValue) and
// EXTRA_MEMBER (a fourth add, accessibilityRole).
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>

@protocol FixtureBridgeRole
- (id)accessibilityRole;
@end

#define FIXTURE_BRIDGE_SLOTS 8
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

static id FixtureBridge_super(id self, SEL _cmd) {
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
    return sup.super_class ? ((id (*)(struct objc_super *, SEL, id))objc_msgSendSuper)(&sup, _cmd, attribute) : nil;
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

#ifdef IMP_ELSEWHERE
void *FixtureBridgeLeak(void) { return (void *)FixtureBridge_isIgnored; }
uintptr_t FixtureBridgeLeakMasked(uintptr_t key) { return (uintptr_t)(void *)FixtureBridge_isIgnored ^ key; }
void *FixtureBridgeImpSlot = (void *)FixtureBridge_isIgnored;
uintptr_t FixtureBridgeLeakSlot(uintptr_t key) { return (uintptr_t)FixtureBridgeImpSlot ^ key; }
#endif

void FixtureBridge(Class cls) {
  int i;
  if (!cls) return;
  // The executor models no SSE: clang22 vectorizes this search otherwise.
#pragma clang loop vectorize(disable) interleave(disable)
  for (i = 0; i < FIXTURE_BRIDGE_SLOTS && FixtureBridgeClasses[i]; i++) {}
  if (i == FIXTURE_BRIDGE_SLOTS) return;
#ifdef TABLE_OTHER
  FixtureBridgeClasses[i] = object_getClass(cls);
#else
  FixtureBridgeClasses[i] = cls;
#endif
#ifdef TABLE_ELSEWHERE
  FixtureBridgeLast = cls;
#endif
#ifdef LOOKUP
  if (class_getInstanceMethod(cls, sel_registerName("accessibilityAttributeNames"))) return;
#endif
  class_addMethod(cls, sel_registerName("accessibilityAttributeNames"), (IMP)(void *)FixtureBridge_attributeNames, "@16@0:8");
  class_addMethod(cls, sel_registerName("accessibilityAttributeValue:"), (IMP)(void *)FixtureBridge_attributeValue, "@24@0:8@16");
#ifdef REPLACE
  class_replaceMethod(cls, sel_registerName("accessibilityIsIgnored"), (IMP)(void *)FixtureBridge_isIgnored, "c16@0:8");
#else
  class_addMethod(cls, sel_registerName("accessibilityIsIgnored"), (IMP)(void *)FixtureBridge_isIgnored, "c16@0:8");
#endif
#ifdef EXTRA_MEMBER
  class_addMethod(cls, sel_registerName("accessibilityRole"), (IMP)(void *)FixtureBridge_role, "@16@0:8");
#endif
}
