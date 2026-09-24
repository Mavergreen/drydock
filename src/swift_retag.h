#ifndef DRYDOCK_SWIFT_RETAG_H
#define DRYDOCK_SWIFT_RETAG_H
/*
 * mswift_ -- moving an Objective-C class record's is-Swift tag from the
 * stable-ABI bit to the legacy one, so a Swift runtime built for a
 * pre-10.14.4 deployment target recognises the class.
 *
 * WHY THE TWO BITS EXIST, and what a mismatch does at runtime. A class
 * record's data word carries a tag in its low two bits saying whether the
 * class is a Swift class, and which bit is used depends on the deployment
 * target of whatever produced it:
 *
 *   bit 1 (value 2)  stable ABI  -- emitted when targeting macOS 10.14.4+
 *   bit 0 (value 1)  legacy      -- emitted when targeting anything older
 *
 * The Swift runtime checks whichever bit its *own* deployment target implies.
 * A runtime built for 10.9 therefore tests bit 0, while an application built
 * for 10.15 tags its classes with bit 1. Nothing rejects the mismatch: the
 * runtime simply concludes that none of the application's classes are Swift
 * classes, treats each as a plain Objective-C class, and takes the
 * ObjC-class-wrapper path in swift_getObjCClassMetadata. For a Swift class
 * that overrides an Objective-C initialiser, that turns super.init() into a
 * call to itself, and the process dies of an infinite recursion long before
 * anything is drawn.
 *
 * Objective-C itself is indifferent: objc masks both bits off before using the
 * pointer, and on 10.9 pure Objective-C classes leave them zero, so moving the
 * tag from one bit to the other changes nothing for the Objective-C runtime.
 */
#include "image.h"

#define MSWIFT_CHAINED    (-3)  /* the image has LC_DYLD_CHAINED_FIXUPS, so its class
                                 * records' pointers are chain links this walk cannot
                                 * follow; nothing printed, nothing changed */

/*
 * Retag every class record reachable from __objc_classlist and
 * __objc_nlclslist (in either __DATA or __DATA_CONST), and the metaclass each
 * one's isa points at, in the buffer `im` views -- no open, no write.
 *
 * Returns the number of class records retagged, 0 or more, or MSWIFT_CHAINED
 * having changed nothing; it prints nothing. Only tag bits in __DATA's (or
 * __DATA_CONST's) class records change, so im->size does not.
 */
int mswift_retag_image(mi_image *im);

/*
 * How many of those class records carry the stable-ABI tag right now --
 * mswift_retag_image's walk, counting instead of writing. MSWIFT_CHAINED on a
 * chained image. Nothing in `im` changes, which is why it is taken by const
 * pointer -- though that is a statement of intent rather than a guarantee the
 * compiler can make here, since C's const is shallow and the buf a
 * `const mi_image *` yields still points at writable bytes. What actually
 * decides is the shared walk's `apply` flag (src/swift_retag.c), which this
 * passes as 0.
 *
 * This is what `target 10.9` detects on (src/script.h's MS_TARGET): a tag
 * bit is set or it is not, so the detection is exact rather than a guess, and
 * it is exact about the same records the retag would move, because it IS that
 * walk.
 * A separate reimplementation that agreed by inspection is the shape of
 * defect this repo keeps finding.
 */
int mswift_stable_tagged_image(const mi_image *im);

#endif /* DRYDOCK_SWIFT_RETAG_H */
