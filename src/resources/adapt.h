/* adapt.h -- the named Auto Layout adaptation rules: mechanical rewrites of values an older AppKit takes literally.
 *
 *   translate-autoresizing: NSDoNotTranslateAutoresizingMask = true on every view a constraint names, where it is
 *     false or absent; not on a window's content view or a box's content view, which their container sizes.
 *   wrapping-width: an NSTextField a constraint names, whose cell wraps on 10.9, with no or a zero
 *     NSPreferredMaxLayoutWidth, gets f64 (NSFrame width - 4). A frame that cannot be read is a finding.
 *
 * adapt.tsv says which targets each rule applies to: target < applies_below. */

#ifndef DRYDOCK_RESOURCES_ADAPT_H
#define DRYDOCK_RESOURCES_ADAPT_H

#include "findings.h"

/* Every rule adapt.tsv in refdir_resources applies to target, on. NULL if the table is unreadable, a row malformed
 * or a rule missing or unknown, or out of memory. */
RAdaptSet *ra_default(const char *refdir_resources, const char *target);
void ra_free(RAdaptSet *s);
int  ra_known(const char *rule);                        /* 1 when rule names a rule */
int  ra_disable(RAdaptSet *s, const char *rule);        /* 0, or 2 unknown rule; NULL turns every rule off */
/* Rewrites g by every rule that applies and is on, logging each rewrite as kind "adapted" (item the rule, detail
 * "@N KEY"), and each object a rule cannot judge (an unreadable frame or cell flags) as an RF_FINDING of the rule's
 * kind, which it leaves as it was. 0, or 4 out of memory. */
int  ra_apply(const RAdaptSet *s, RGraph *g, RFindings *log);
/* What ra_apply would rewrite, as findings of the rule's kind: RF_WILL_ADAPT when the rule is on, RF_FINDING when
 * --no-adapt turned it off; nothing for a rule the target doesn't need. 0, or 4 out of memory. */
int  ra_check(const RAdaptSet *s, const RGraph *g, const char *nib, RFindings *out);

#endif
