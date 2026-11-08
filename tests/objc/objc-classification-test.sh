#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then classifies their sends
# spec: tools/objc-compat/classify.c header -- one verdict per send from measured receivers, the
#       versioned 10.9.5 reference set and reviewed build-bound evidence; R1, R2 and downcast
#       refinement close only what they prove; no denylist anywhere.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
FX="$HERE/fixtures/objc-api"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-classification-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@"; }
mkdir -p "$T/root/bin"
n=0
# spec: scripts/objc-compat.sh header -- analyze ARTIFACT MODE [options]: rc and $T/report; REFS, when set, replaces the reference set.
analyze() {
  art=$1 mode=$2; shift 2
  n=$((n + 1)); rep="$T/report.$n"
  rc=0; sh "$ROOT/scripts/objc-compat.sh" --artifact "$art" --root "$T/root" --references "${REFS:-$REF}" --report "$rep" --mode "$mode" "$@" 2>"$T/err" || rc=$?
  ln -sf "$rep" "$T/report"
}
# spec: tools/objc-compat/main.m header -- verdict FUNCTION SELECTOR: the verdicts of that function's sends of SELECTOR, one per line.
verdicts() {
  grep "\"function\": \"$1\"" "$T/report" | grep "\"selector\": \"$2\"" | sed -n 's/.*"verdict": "\([^"]*\)".*/\1/p'
}
want() {   # want FUNCTION SELECTOR VERDICT [PROOF-FRAGMENT]
  got=$(verdicts "$1" "$2" | sort -u | tr '\n' ' ')
  [ "$got" = "$3 " ] || fail "$1 $2: want $3, got '${got:-no finding}'"
  [ -z "${4:-}" ] || grep "\"function\": \"$1\"" "$T/report" | grep "\"selector\": \"$2\"" | grep -F -- "$4" >/dev/null ||
    fail "$1 $2: proof lacks '$4': $(grep "\"function\": \"$1\"" "$T/report" | grep "\"selector\": \"$2\"" | sed -n 's/.*"proof": //p')"
}
none() { ! grep "\"function\": \"$1\"" "$T/report" | grep "\"selector\": \"$2\"" >/dev/null || fail "$1 $2: a finding where only a selector was constructed"; }
exit_is() { [ "$rc" = "$1" ] || fail "$2: exit $rc, want $1"; }
error_is() { grep "\"code\": \"$1\"" "$T/report" >/dev/null || fail "$2: no $1 error"; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
# spec: tools/objc-compat/source-evidence.c header -- evidence ARTIFACT OUT [GUARDS] [TYPES] [CRATES] [TYPEMAP] [SOURCE]: schema-1 build evidence bound to ARTIFACT.
SRCID='"revision": "0000000000000000000000000000000000000001", "patches_sha256": "p", "features": "f"'
evidence() {
  pe=; [ -z "${8:-}" ] || pe=" \"position_evidence\": [$8],"
  cat >"$2" <<EOF
{"schema": 1, "kind": "objc-build-evidence",
 "artifact": {"path": "bin/x", "sha256": "$(sha "$1")"},
 "source": {${7:-$SRCID}},
 "crates": [${5:-}],
 "type_map": [${6:-}],
 "type_evidence": [${4:-}],
 "binding_receipt": [],$pe
 "guards": [${3:-}]}
EOF
}
guard() {  # guard FUNCTION SELECTOR STATUS [SOURCE-IDENTITY]
  printf '{"id": "g-%s", "function": "%s", "selector": "%s", "guard": "respondsToSelector:", "fallback": "returns 0", "source": {"file": "x.c", "line": 7, "sha256": "s", %s}, "review": {"status": "%s", "reviewer": "%s", "reason": "%s"}}' \
    "$1" "$1" "$2" "${4:-$SRCID}" "$3" "$([ "$3" = reviewed ] && echo 'A. Reviewer' || echo '')" "$([ "$3" = reviewed ] && echo 'NO falls back to 0' || echo '')"
}

cc "$FX/classify.c" -o "$T/root/bin/classify" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_fixture_use
C="$T/root/bin/classify"

# spec: tools/objc-compat/classify.c header -- exact class, kind and inheritance from the floor runtime capture.
analyze "$C" strict
exit_is 1 'classify fixture strict'
want _class_method sharedWorkspace floor-supported 'floor runtime: +NSWorkspace sharedWorkspace in AppKit'
want _instance_kind sharedWorkspace 'floor-supported unsupported'
grep '"function": "_instance_kind"' "$T/report" | grep '"method_kind": "-"' | grep '"verdict": "unsupported"' >/dev/null ||
  fail 'an instance send of a class method was not unsupported'
want _inherited description floor-supported '-NSObject description'
# spec: tools/objc-compat/classify.c header -- a selector some unrelated class implements is not availability here.
want _unrelated count unsupported 'absent from the floor runtime for -NSWorkspace'
# spec: tools/objc-compat/classify.c header -- later methods and classes are caught without a list: an analogous missing method.
want _later_method containsString: unsupported 'introduced 10.10'
want _later_class alloc unsupported 'NSVisualEffectView is not on the floor'
# spec: tools/objc-compat/classify.c header -- outside the reference closure, or an image whose methods were not captured: unresolved.
want _outside new unresolved 'outside the reference closure'
want _uncaptured defaultSession unresolved 'did not record the methods of ODSession'
# spec: tools/objc-compat/classify.c header -- a category in another image counts with that image as framework.
want _category sizeWithAttributes: floor-supported 'in AppKit'
grep '"function": "_category"' "$T/report" | grep '"selector": "sizeWithAttributes:"' | grep '"framework": "AppKit"' >/dev/null ||
  fail 'the category method is not attributed to AppKit'
# spec: tools/objc-compat/classify.c header -- class clusters: the +alloc witness closes its concrete method; a subclass-only one stays uncertain.
want _cluster_alloc initWithBytes:length:encoding: floor-supported 'cluster witness'
want _cluster_uncertain appendString: unresolved 'NSMutableString implements it'
# spec: tools/objc-compat/classify.c header -- a selector built only to ask respondsToSelector:, or only for introspection, is not a send of it.
none _query_only isVoiceOverEnabled
want _query_only respondsToSelector: floor-supported
none _introspect 'openURLs:withApplicationAtURL:options:configuration:error:'
grep '"kind": "sel-register", "selector": "isVoiceOverEnabled"' "$T/report" >/dev/null ||
  fail 'the queried selector is not kept as an observation'
# spec: tools/objc-compat/classify.c header -- guards: a measured guard needs reviewed evidence; wrong selector/receiver or an ineffective fallback is no guard.
want _guarded accessibilityDisplayShouldReduceMotion unresolved 'no build evidence holds a reviewed guard record'
want _wrong_selector accessibilityDisplayShouldReduceMotion unsupported unguarded
want _wrong_receiver accessibilityDisplayShouldReduceMotion unsupported unguarded
want _ineffective accessibilityDisplayShouldReduceMotion unsupported unguarded
# spec: tools/objc-compat/classify.c header -- downcast refinement: YES on the same value only.
want _downcast_same UTF8String floor-supported
grep '"function": "_downcast_same"' "$T/report" | grep '"selector": "UTF8String"' | grep '"receiver_closure": "downcast"' >/dev/null ||
  fail 'the same-value downcast did not close the receiver'
want _downcast_other UTF8String unresolved 'receiver not closed'
want _downcast_no UTF8String unresolved 'receiver not closed'
# spec: tools/objc-compat/classify.c header -- R1 (b), amended: the witness measures existence, NSProxy-rooted classes
#       implement the root selectors, and the real witness's exceptions are exactly the reviewed residual risk, so an
#       unknown floor-vended receiver of a reviewed root selector closes; a non-root selector does not.
want _vended_root description floor-supported 'R1: receiver vended by -[NSDictionary'
grep '"function": "_vended_root"' "$T/report" | grep '"selector": "description"' | grep '"r1": true' >/dev/null ||
  fail 'the R1 closure is not marked'
want _vended_root description floor-supported 'accepted residual risk: NSLeafProxy Object _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder'
want _vended_nonroot count unresolved 'receiver not closed'
# spec: scripts/objc-reference-set.sh header -- the witness covers hash, measured with exactly the reviewed exceptions.
want _vended_hash hash floor-supported 'R1: receiver vended by -[NSDictionary'
# spec: tools/objc-compat/classify.c header -- retain, release, autorelease and +class are root selectors whose own
#       measured exception sets, strict subsets of the six, are recorded per selector: the proof names that set.
want _vended_retain retain floor-supported 'R1: receiver vended by -[NSDictionary'
want _vended_retain retain floor-supported 'accepted residual risk: _NSZombie_ __NSAtom __NSMessageBuilder'
want _vended_autorelease autorelease floor-supported 'accepted residual risk: _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder'
# spec: tools/objc-compat/classify.c header -- -class is reviewed too, held to the six it measures, so a receiver of
#       unknown class, which could be sent either kind, closes class with both kinds' sets as the residual risk.
want _vended_class class floor-supported 'R1: receiver vended by -[NSDictionary'
want _vended_class class floor-supported 'accepted residual risk: NSLeafProxy Object _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder'
# spec: tools/objc-compat/main.m header -- every report lists the measured non-implementing floor classes as an
#       accepted residual risk, with the witness identity.
residual() {
  grep -F '"accepted_residual_risk": [{"kind": "r1-root-method-witness", ' "$T/report" >/dev/null &&
    grep -F "\"witness\": {\"os\": \"10.9.5\", \"build\": \"13F1911\", \"arch\": \"x86_64\", \"floor_runtime_sha256\": \"$(sha "${REFS:-$REF}/floor-runtime.tsv")\", \"tool_source_sha256\": \"" "$T/report" >/dev/null &&
    grep -F '"root_selectors": ["autorelease", "class", "conformsToProtocol:", "description", "hash", "isEqual:", "isKindOfClass:", "isMemberOfClass:", "performSelector:", "release", "respondsToSelector:", "retain", "self"], "non_implementing_floor_classes": ["NSLeafProxy", "Object", "_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]' "$T/report" >/dev/null ||
    fail "$1: the report does not list the R1 residual risk with the witness identity"
  # spec: tools/objc-compat/main.m header -- and each root selector's own non-implementing classes, with its reviewed kinds.
  grep -F '"per_selector": [{"selector": "autorelease", "kinds": ["+", "-"], "non_implementing_floor_classes": ["_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]}, {"selector": "class", "kinds": ["+"], "non_implementing_floor_classes": ["NSLeafProxy", "_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]}, {"selector": "class", "kinds": ["-"], "non_implementing_floor_classes": ["NSLeafProxy", "Object", "_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]}, {"selector": "conformsToProtocol:", "kinds": ["+", "-"], "non_implementing_floor_classes": ["NSLeafProxy", "Object", "_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]}, ' "$T/report" >/dev/null &&
    grep -F '{"selector": "release", "kinds": ["+", "-"], "non_implementing_floor_classes": ["_NSZombie_", "__NSAtom", "__NSMessageBuilder"]}, {"selector": "respondsToSelector:", "kinds": ["+", "-"], "non_implementing_floor_classes": ["NSLeafProxy", "Object", "_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]}, {"selector": "retain", "kinds": ["+", "-"], "non_implementing_floor_classes": ["_NSZombie_", "__NSAtom", "__NSMessageBuilder"]}, {"selector": "self", ' "$T/report" >/dev/null ||
    fail "$1: the report does not list each root selector's own exception set"
}
residual 'classify fixture'

# spec: tools/objc-compat/source-evidence.c header -- reviewed guard records: exact function and selector, reviewed, under the build's own source identity.
G=$(guard _guarded accessibilityDisplayShouldReduceMotion reviewed)
W=$(guard _wrong_selector accessibilityDisplayShouldReduceMotion reviewed)
I=$(guard _ineffective accessibilityDisplayShouldReduceMotion reviewed)
evidence "$C" "$T/ev-guards" "$G, $W, $I"
analyze "$C" strict --build-evidence "$T/ev-guards"
exit_is 1 'reviewed guards'
want _guarded accessibilityDisplayShouldReduceMotion guarded 'reviewed by A. Reviewer'
want _wrong_selector accessibilityDisplayShouldReduceMotion unsupported unguarded
want _ineffective accessibilityDisplayShouldReduceMotion unsupported unguarded
evidence "$C" "$T/ev-pending" "$(guard _guarded accessibilityDisplayShouldReduceMotion required)"
analyze "$C" strict --build-evidence "$T/ev-pending"
want _guarded accessibilityDisplayShouldReduceMotion unresolved 'its guard record is not reviewed'
# spec: tools/objc-compat/source-evidence.c header -- changed source or features: a record reviewed under another identity is cannot-measure.
evidence "$C" "$T/ev-stale" "$(guard _guarded accessibilityDisplayShouldReduceMotion reviewed '"revision": "0000000000000000000000000000000000000001", "patches_sha256": "p", "features": "other-features"')"
analyze "$C" strict --build-evidence "$T/ev-stale"
exit_is 4 'guard reviewed under other features'; error_is guard-evidence-stale 'changed features'
evidence "$C" "$T/ev-stale2" "$G" '' '' '' '"revision": "0000000000000000000000000000000000000002", "patches_sha256": "p", "features": "f"'
analyze "$C" strict --build-evidence "$T/ev-stale2"
exit_is 4 'guard reviewed under another revision'; error_is guard-evidence-stale 'changed source'
# spec: tools/objc-compat/source-evidence.c header -- evidence for a different artifact is stale.
evidence "$FX/classify.c" "$T/ev-other" "$G"
analyze "$C" strict --build-evidence "$T/ev-other"
exit_is 4 'evidence for another artifact'; error_is stale-build-evidence 'another artifact'

# spec: tools/objc-compat/classify.c header -- the second, unguarded caller of a guarded shared objc2 cache is its own blocking finding.
closure_fixture() {
  cc "$FX/closure.c" -o "$1" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_NSSelectorFromString -Wl,-U,_fixture_nsstring \
    -Wl,-U,_fixture_use -Wl,-U,_objc_retainAutoreleasedReturnValue -Wl,-U,_objc_release
}
closure_fixture "$T/root/bin/closure"
evidence "$T/root/bin/closure" "$T/ev-closure" "$(guard _voiceover_guarded isVoiceOverEnabled reviewed), $(guard _voiceover_unguarded isVoiceOverEnabled reviewed)"
analyze "$T/root/bin/closure" strict --build-evidence "$T/ev-closure"
exit_is 1 'shared cache'
want _voiceover_guarded isVoiceOverEnabled guarded
want _voiceover_unguarded isVoiceOverEnabled unsupported 'introduced 10.13'

# spec: tools/objc-compat/classify.c header -- application-defined ownership and R1 (a): root proof through the artifact's own classes.
cc -c "$FX/classify-app.m" -o "$T/app.o" 2>/dev/null
cc "$T/app.o" -o "$T/root/bin/app" -framework AppKit -framework Foundation -lobjc
analyze "$T/root/bin/app" strict
exit_is 1 'application classes'
want _app_cases probe floor-supported "the artifact's own +Probe"
want _app_cases respondsToSelector: floor-supported 'R1: application class Probe has floor ancestor NSObject'
grep '"selector": "respondsToSelector:"' "$T/report" | grep '"r1": true' >/dev/null || fail 'R1 not marked on the root-proved send'
want _app_cases missingEverywhere unsupported
want _app_cases description unresolved 'without an NSObject root proof'
want _app_cases isKindOfClass: floor-supported 'R1: application class Forwarder has floor ancestor NSProxy; witness +NSProxy isKindOfClass: -> +NSProxy'
want _app_cases mavergreenProbe floor-supported '(a category)'
residual 'application classes'

# spec: tools/objc-compat/classify.c header -- R1 (b) on receivers of unknown class (arguments, collection elements):
#       only when every class the artifact defines has a measured NSObject or NSProxy root and every dependency is
#       in the floor capture; the report records that fact and names whatever keeps R1 off.
roots_fixture() {  # roots_fixture FORM OUTPUT [LINK-OPTIONS]
  f=$1 out=$2; shift 2
  cc -DFORM="$f" -c "$FX/class-roots.m" -o "$T/roots$f.o" 2>/dev/null
  cc "$T/roots$f.o" -o "$out" -framework Foundation -lobjc "$@"
}
roots_fact() {  # roots_fact FRAGMENT: the closure_class_roots record contains it
  grep -o '"closure_class_roots": {[^}]*}[^}]*}' "$T/report" | grep -F -- "$1" >/dev/null ||
    fail "closure_class_roots lacks '$1': $(grep -o '"closure_class_roots": {[^}]*}[^}]*}' "$T/report")"
}
roots_fixture 0 "$T/root/bin/roots0"
analyze "$T/root/bin/roots0" strict
exit_is 1 'NSObject and NSProxy subclasses only'
roots_fact '"defined_classes": 2, "roots": {"NSObject": 1, "NSProxy": 1}, "runtime_class_creation_sites": 0, "uncaptured_dependencies": [], "blocking": [], "r1_unknown_receivers": true'
want _argument_root isKindOfClass: floor-supported 'R1: receiver of unknown class (receiver is incoming argument 0 of _argument_root); every class the artifact defines has a measured NSObject or NSProxy root (2)'
want _argument_hash hash floor-supported 'accepted residual risk: NSLeafProxy Object _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder'
want _element_root respondsToSelector: floor-supported 'R1: receiver of unknown class'
want _argument_nonroot count unresolved 'receiver not closed'
residual 'NSObject and NSProxy subclasses only'
blocked() {  # blocked WHAT FRAGMENT: R1 is off receivers of unknown class, and the report names why
  exit_is 1 "$1"
  roots_fact '"r1_unknown_receivers": false'
  roots_fact "$2"
  for s in _argument_root:isKindOfClass: _argument_hash:hash _element_root:respondsToSelector:; do
    want "${s%%:*}" "${s#*:}" unresolved "R1 does not apply to receivers of unknown class in this artifact: $2"
  done
}
roots_fixture 1 "$T/root/bin/roots1"
analyze "$T/root/bin/roots1" strict
blocked 'a root class of its own' 'MGOwnRoot: MGOwnRoot is a root class of the artifact'"'"'s own'
roots_fixture 2 "$T/root/bin/roots2" -Wl,-U,'_OBJC_CLASS_$_SwiftObject' -Wl,-U,'_OBJC_METACLASS_$_SwiftObject'
analyze "$T/root/bin/roots2" strict
blocked 'a Swift-style root in another image' 'MGSwiftish: superclass SwiftObject is outside the reference'
roots_fixture 3 "$T/root/bin/roots3" -Wl,-U,'_OBJC_CLASS_$_NSLeafProxy' -Wl,-U,'_OBJC_METACLASS_$_NSLeafProxy'
analyze "$T/root/bin/roots3" strict
blocked 'a floor superclass with another root' 'MGLeaf: floor superclass NSLeafProxy has root NSLeafProxy, not NSObject or NSProxy'
roots_fixture 0 "$T/root/bin/roots0w" -framework WebKit
analyze "$T/root/bin/roots0w" strict
blocked 'a dependency outside the floor capture' 'dependency /System/Library/Frameworks/WebKit.framework/Versions/A/WebKit is not in the floor capture'
# spec: tools/objc-compat/macho-reader.c header -- run-time class creation is cannot-measure, and the report counts it.
cc -DFORM=6 "$FX/unsupported.c" -o "$T/root/bin/made" -lobjc
analyze "$T/root/bin/made" strict
exit_is 4 'objc_allocateClassPair'; error_is runtime-class-creation 'objc_allocateClassPair'
roots_fact '"runtime_class_creation_sites": 1'

# spec: tools/objc-compat/reference.c header -- R1's witness: a missing witness leaves R1 off; an exception set other than
#       the reviewed one, or a manifest that does not list the reviewed one, is cannot-measure.
copy_refs() {  # copy_refs DIR: a writable copy of the reference set whose manifest is re-hashed by rehash
  rm -rf "$1"; mkdir -p "$1"; cp "$REF"/* "$1"/
}
rehash() {  # rehash DIR FILE: the manifest's SHA-256 for FILE, recomputed
  h=$(sha "$1/$2")
  sed "s|\(\"name\": \"$2\", \"sha256\": \"\)[0-9a-f]*|\1$h|" "$1/manifest.json" >"$1/manifest.new" && mv "$1/manifest.new" "$1/manifest.json"
}
copy_refs "$T/universal"
awk -F '\t' 'BEGIN {OFS = "\t"} $1 == "witness" {$5 = $3 "NSObject"; $6 = "libobjc.A.dylib"; $7 = "NSObject"} {print}' \
  "$REF/floor-runtime.tsv" >"$T/universal/floor-runtime.tsv"
rehash "$T/universal" floor-runtime.tsv
REFS="$T/universal"; analyze "$C" strict; REFS=
exit_is 4 'a witness with no exceptions'; error_is witness-exceptions-mismatch 'a witness with no exceptions'
copy_refs "$T/moreexc"
awk -F '\t' 'BEGIN {OFS = "\t"} $1 == "witness" && $2 == "NSWorkspace" && $3 == "-" && $4 == "description" {$5 = "-"; $6 = "-"} {print}' \
  "$REF/floor-runtime.tsv" >"$T/moreexc/floor-runtime.tsv"
rehash "$T/moreexc" floor-runtime.tsv
REFS="$T/moreexc"; analyze "$C" strict; REFS=
exit_is 4 'a witness with an exception more'; error_is witness-exceptions-mismatch 'a witness with an exception more'
grep -F 'NSWorkspace' "$T/report" | grep -F 'witness-exceptions-mismatch' >/dev/null || fail 'the mismatch does not name the new exception'
copy_refs "$T/manexc"
sed 's/"root_exceptions": \["NSLeafProxy", /"root_exceptions": [/' "$REF/manifest.json" >"$T/manexc/manifest.json"
REFS="$T/manexc"; analyze "$C" strict; REFS=
exit_is 4 'a manifest with another exception set'; error_is witness-exceptions-mismatch 'a manifest with another exception set'
# spec: tools/objc-compat/reference.c header -- per selector and kind: a reviewed exception that resolves one root
#       selector leaves the union unchanged but makes that selector's exception set another one.
copy_refs "$T/oneexc"
awk -F '\t' 'BEGIN {OFS = "\t"} $1 == "witness" && $2 == "Object" && $3 == "-" && $4 == "description" {$5 = "-NSObject"; $6 = "libobjc.A.dylib"} {print}' \
  "$REF/floor-runtime.tsv" >"$T/oneexc/floor-runtime.tsv"
rehash "$T/oneexc" floor-runtime.tsv
REFS="$T/oneexc"; analyze "$C" strict; REFS=
exit_is 4 'an exception that resolves one selector'; error_is witness-exceptions-mismatch 'an exception that resolves one selector'
grep -F 'resolves -Object description on reviewed exception Object' "$T/report" >/dev/null || fail 'the per-selector mismatch does not name the selector'
# spec: tools/objc-compat/reference.c header -- a recorded per-selector set is held exactly: a witness whose retain
#       set differs from the recorded one, smaller or larger, or a manifest that records another one or none, is
#       cannot-measure; a recorded set must be a strict subset of root_exceptions.
copy_refs "$T/retainless"
awk -F '\t' 'BEGIN {OFS = "\t"} $1 == "witness" && $2 == "__NSAtom" && $3 == "-" && $4 == "retain" {$5 = "-NSObject"; $6 = "libobjc.A.dylib"} {print}' \
  "$REF/floor-runtime.tsv" >"$T/retainless/floor-runtime.tsv"
rehash "$T/retainless" floor-runtime.tsv
REFS="$T/retainless"; analyze "$C" strict; REFS=
exit_is 4 'a retain set one smaller'; error_is witness-exceptions-mismatch 'a retain set one smaller'
grep -F 'the witness measures -retain exceptions (_NSZombie_ __NSMessageBuilder), not the recorded (_NSZombie_ __NSAtom __NSMessageBuilder)' "$T/report" >/dev/null ||
  fail 'the retain mismatch does not name the selector and both sets'
copy_refs "$T/retainmore"
awk -F '\t' 'BEGIN {OFS = "\t"} $1 == "witness" && $2 == "Object" && $3 == "+" && $4 == "retain" {$5 = "-"; $6 = "-"} {print}' \
  "$REF/floor-runtime.tsv" >"$T/retainmore/floor-runtime.tsv"
rehash "$T/retainmore" floor-runtime.tsv
REFS="$T/retainmore"; analyze "$C" strict; REFS=
exit_is 4 'a retain set one larger'; error_is witness-exceptions-mismatch 'a retain set one larger'
# spec: tools/objc-compat/reference.c header -- -class has no recorded set, so it is held to the six: a witness in
#       which Object resolves -class is cannot-measure, not a smaller residual risk.
copy_refs "$T/classless"
awk -F '\t' 'BEGIN {OFS = "\t"} $1 == "witness" && $2 == "Object" && $3 == "-" && $4 == "class" {$5 = "-NSObject"; $6 = "libobjc.A.dylib"} {print}' \
  "$REF/floor-runtime.tsv" >"$T/classless/floor-runtime.tsv"
rehash "$T/classless" floor-runtime.tsv
REFS="$T/classless"; analyze "$C" strict; REFS=
exit_is 4 'a -class set without Object'; error_is witness-exceptions-mismatch 'a -class set without Object'
grep -F 'resolves -Object class on reviewed exception Object' "$T/report" >/dev/null || fail 'the -class mismatch does not name the selector'
copy_refs "$T/recorded"
sed 's/{"selector": "release", "kinds": \["+", "-"\], "exceptions": \["_NSZombie_", /{"selector": "release", "kinds": ["+", "-"], "exceptions": [/' \
  "$REF/manifest.json" >"$T/recorded/manifest.json"
cmp -s "$REF/manifest.json" "$T/recorded/manifest.json" && fail 'the release record was not edited'
REFS="$T/recorded"; analyze "$C" strict; REFS=
exit_is 4 'another recorded release set'; error_is witness-exceptions-mismatch 'another recorded release set'
copy_refs "$T/unrecorded"
grep -v '"root_subset_exceptions": ' "$REF/manifest.json" >"$T/unrecorded/manifest.json"
REFS="$T/unrecorded"; analyze "$C" strict; REFS=
exit_is 4 'no recorded per-selector sets'; error_is witness-exceptions-mismatch 'no recorded per-selector sets'
copy_refs "$T/notstrict"
awk -F '\t' 'BEGIN {OFS = "\t"} $1 == "witness" && ($2 == "NSLeafProxy" || $2 == "Object") && $4 == "retain" {$5 = "-"; $6 = "-"} {print}' \
  "$REF/floor-runtime.tsv" >"$T/notstrict/floor-runtime.tsv"
rehash "$T/notstrict" floor-runtime.tsv
sed 's/{"selector": "retain", "kinds": \["+", "-"\], "exceptions": \[[^]]*\]}/{"selector": "retain", "kinds": ["+", "-"], "exceptions": ["NSLeafProxy", "Object", "_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]}/' \
  "$REF/manifest.json" >"$T/notstrict/manifest.json.new"
sed "s|\(\"name\": \"floor-runtime.tsv\", \"sha256\": \"\)[0-9a-f]*|\1$(sha "$T/notstrict/floor-runtime.tsv")|" "$T/notstrict/manifest.json.new" >"$T/notstrict/manifest.json"
rm "$T/notstrict/manifest.json.new"
REFS="$T/notstrict"; analyze "$C" strict; REFS=
exit_is 4 'a recorded set that is all six'; error_is witness-exceptions-mismatch 'a recorded set that is all six'
grep -F 'the recorded retain exceptions are not a strict subset of root_exceptions' "$T/report" >/dev/null ||
  fail 'a recorded set that is not a strict subset was not refused as such'
copy_refs "$T/noexc"
grep -v '"root_exceptions": ' "$REF/manifest.json" >"$T/noexc/manifest.json"
REFS="$T/noexc"; analyze "$C" strict; REFS=
exit_is 4 'a manifest without the reviewed exceptions'; error_is witness-exceptions-mismatch 'a manifest without the reviewed exceptions'
copy_refs "$T/nowitness"
grep -v '^witness	' "$REF/floor-runtime.tsv" >"$T/nowitness/floor-runtime.tsv"
rehash "$T/nowitness" floor-runtime.tsv
REFS="$T/nowitness"; analyze "$C" strict; REFS=
exit_is 1 'no witness'
want _vended_root description unresolved 'no root-method witness'
copy_refs "$T/badroots"
sed 's/"root_selectors": \[/"root_selectors": ["class", /' "$REF/manifest.json" >"$T/badroots/manifest.json"
REFS="$T/badroots"; analyze "$C" strict; REFS=
exit_is 4 'mismatched witness'; error_is witness-mismatch 'manifest root selectors'
copy_refs "$T/badid"
sed 's/^identity	build	-	-	13F1911/identity	build	-	-	13F34/' "$REF/floor-runtime.tsv" >"$T/badid/floor-runtime.tsv"
rehash "$T/badid" floor-runtime.tsv
REFS="$T/badid"; analyze "$C" strict; REFS=
exit_is 4 'runtime identity'; error_is reference-identity-mismatch 'runtime build'

# spec: tools/objc-compat/source-evidence.c header -- R2: exact v0 symbol, mapped type in its self type, pinned crate revisions.
cc "$FX/r2.c" -o "$T/root/bin/r2" -lobjc
R2="$T/root/bin/r2"
NSS=objc2_foundation::generated::__NSString::NSString
FN=__RNvXs1g_NtCs5hICDV8pRVn_4core3fmtRNtNtNtCsltbaDnwDLUa_16objc2_foundation9generated10___NSString8NSStringNtB6_5Debug3fmtBC_
CRATES='{"name": "objc2", "version": "0.6.3", "checksum": "c1", "disambiguator": "2ucXwfqiSr7"}, {"name": "objc2_foundation", "version": "0.3.2", "checksum": "c2", "disambiguator": "ltbaDnwDLUa"}'
MAP="{\"rust_type\": \"$NSS\", \"class\": \"NSString\", \"source\": \"objc2-foundation-0.3.2 src/generated/NSString.rs:126\"}"
row() { printf '{"id": "r2", "symbol": "%s", "rust_type": "%s", "position": "self", "kind": "-", "selectors": ["UTF8String", "lengthOfBytesUsingEncoding:"], "source": "objc2-foundation-0.3.2 src/string.rs:222"}' "$1" "$2"; }
analyze "$R2" strict
want "$FN" UTF8String unresolved 'receiver not closed'
evidence "$R2" "$T/ev-r2" '' "$(row "$FN" "$NSS")" "$CRATES" "$MAP"
analyze "$R2" strict --build-evidence "$T/ev-r2"
exit_is 0 'R2 closes both sends'
want "$FN" UTF8String floor-supported '-NSString UTF8String'
want "$FN" lengthOfBytesUsingEncoding: floor-supported
grep '"receiver_closure": "R2"' "$T/report" | grep '"source_provenance": "objc2-foundation-0.3.2 src/string.rs:222' >/dev/null ||
  fail 'R2 closure lacks its citation'
evidence "$R2" "$T/ev-r2rev" '' "$(row "$FN" "$NSS")" "$(printf '%s' "$CRATES" | sed 's/2ucXwfqiSr7/3aaaaaaaaaa/')" "$MAP"
analyze "$R2" strict --build-evidence "$T/ev-r2rev"
exit_is 4 'a different objc2 revision'; error_is crate-revision-mismatch 'objc2 revision'
evidence "$R2" "$T/ev-r2mangle" '' "$(row _ZN4core3fmt5Debug3fmt17h0123456789abcdefE "$NSS")" "$CRATES" "$MAP"
analyze "$R2" strict --build-evidence "$T/ev-r2mangle"
exit_is 4 'unknown mangling'; error_is unsupported-type-evidence 'legacy mangling'
evidence "$R2" "$T/ev-r2unmapped" '' "$(row "$FN" objc2::runtime::AnyObject)" "$CRATES" "$MAP"
analyze "$R2" strict --build-evidence "$T/ev-r2unmapped"
exit_is 4 'unmapped Rust type'; error_is unmapped-rust-type 'AnyObject'
evidence "$R2" "$T/ev-r2nottype" '' "$(row "$FN" "$NSS")" "$CRATES" \
  "$MAP, {\"rust_type\": \"objc2_foundation::generated::__NSArray::NSArray\", \"class\": \"NSArray\", \"source\": \"s\"}"
sed 's/"rust_type": "objc2_foundation::generated::__NSString::NSString", "position"/"rust_type": "objc2_foundation::generated::__NSArray::NSArray", "position"/' \
  "$T/ev-r2nottype" >"$T/ev-r2nottype2"
analyze "$R2" strict --build-evidence "$T/ev-r2nottype2"
exit_is 4 'a mapped type the symbol does not name'; error_is type-evidence-not-in-symbol 'NSArray in an NSString impl'
cc -DLOCAL_FN "$FX/r2.c" -o "$T/root/bin/r2-stripped" -lobjc
strip -x "$T/root/bin/r2-stripped"
evidence "$T/root/bin/r2-stripped" "$T/ev-r2strip" '' "$(row "$FN" "$NSS")" "$CRATES" "$MAP"
analyze "$T/root/bin/r2-stripped" strict --build-evidence "$T/ev-r2strip"
exit_is 1 'stripped artifact'
! grep '"receiver_closure": "R2"' "$T/report" >/dev/null || fail 'R2 closed a send in a stripped artifact'
grep '"unused_type_evidence": \["r2"\]' "$T/report" >/dev/null || fail 'unused R2 evidence not reported'

# spec: tools/objc-compat/source-evidence.c header -- R3: a row names a function, its selectors, a class and the
#       position the receiver comes from (result, downcast, field), with pinned crates; shipyard checks the
#       position where the reader models the receiver and refuses a row the binary contradicts.
cc "$FX/r3.c" -o "$T/root/bin/r3" -lobjc
R3B="$T/root/bin/r3"
FNR=__RNvXs6_NtNtCs2WYrep5oUp8_5objc27runtime15protocol_objectINtB5_14ProtocolObjectDNtNtB7_8nsobject16NSObjectProtocolEL_ENtNtCs5hICDV8pRVn_4core3fmt5Debug3fmtCsdIImX2SWmg2_16objc2_foundation
FNF=__RNvXs0_NtNtNtCs5hICDV8pRVn_4core4iter8adapters10filter_mapINtB5_9FilterMapINtNtCsdIImX2SWmg2_16objc2_foundation5array4IterNtNtCs2WYrep5oUp8_5objc27runtime9AnyObjectENCNCNCNvMs3_NtNtCsIwpAeRmYHq_7arboard8platform3osxNtB2P_3Get9file_list000ENtNtNtB9_6traits8iterator8Iterator4nextB2T_
FND=__RNvNtCslTKFwgOQWRM_7os_info3imp16current_platform
FNM=__RNvNtCslTKFwgOQWRM_7os_info3imp6merged
ENUM='countByEnumeratingWithState:objects:count:'
NSD=objc2_foundation::generated::__NSDictionary::NSDictionary
C3='{"name": "objc2", "version": "0.6.3", "checksum": "c1", "disambiguator": "2WYrep5oUp8"}, {"name": "objc2_foundation", "version": "0.3.2", "checksum": "c2", "disambiguator": "dIImX2SWmg2"}, {"name": "arboard", "version": "3.6.1", "checksum": "c3", "disambiguator": "IwpAeRmYHq"}, {"name": "os_info", "version": "3.14.0", "checksum": "c4", "disambiguator": "lTKFwgOQWRM"}'
M3="{\"rust_type\": \"$NSS\", \"class\": \"NSString\", \"source\": \"s1\"}, {\"rust_type\": \"objc2_foundation::generated::__NSArray::NSArray\", \"class\": \"NSArray\", \"source\": \"s2\"}, {\"rust_type\": \"$NSD\", \"class\": \"NSDictionary\", \"source\": \"s3\"}"
prow() {  # prow ID SYMBOL SELECTORS-JSON CLASS POSITION-JSON
  printf '{"id": "%s", "symbol": "%s", "selectors": [%s], "kind": "-", "class": "%s", "position": %s, "source": "cite-%s"}' "$1" "$2" "$3" "$4" "$5" "$1"
}
RES="$(prow res "$FNR" '"UTF8String", "lengthOfBytesUsingEncoding:"' NSString '{"form": "result", "selector": "description"}')"
FLD="$(prow fld "$FNF" "\"$ENUM\"" NSArray '{"form": "field", "rust_type": "objc2_foundation::array::Iter", "field": "0"}')"
POSD="{\"form\": \"downcast\", \"rust_type\": \"$NSD\"}"
DWN="$(prow dwn "$FND" '"objectForKey:"' NSDictionary "$POSD")"
r3() { evidence "$R3B" "$T/ev-$1" '' '' "${3:-$C3}" "$M3" '' "$2"; analyze "$R3B" strict --build-evidence "$T/ev-$1"; }
r3 res "$RES"
want "$FNR" UTF8String floor-supported; want "$FNR" lengthOfBytesUsingEncoding: floor-supported
grep '"receiver_closure": "R3"' "$T/report" | grep '"source_provenance": "cite-res' >/dev/null || fail 'R3 closure lacks its citation'
r3 contradicted "$(prow res "$FNR" '"UTF8String"' NSString '{"form": "result", "selector": "hash"}')"
exit_is 4 'a result row naming another send'; error_is position-contradicted 'result of description, not hash'
r3 fld "$FLD"
want "$FNF.llvm.1" "$ENUM" floor-supported
r3 fldother "$(prow fld "$FNF" "\"$ENUM\"" NSArray '{"form": "field", "rust_type": "objc2_foundation::array::IntoIter", "field": "0"}')"
exit_is 4 'a field type the symbol does not name'; error_is type-evidence-not-in-symbol 'IntoIter'
r3 dwn "$DWN"
want "$FND" objectForKey: floor-supported
r3 dwnother "$(prow dwn "$FND" '"objectForKey:"' NSArray "$POSD")"
exit_is 4 'a downcast type that maps to another class'; error_is position-contradicted 'NSDictionary is not NSArray'
r3 unpinned "$DWN" "$(printf '%s' "$C3" | sed 's/, {"name": "os_info"[^}]*}//')"
exit_is 4 'an unpinned crate'; error_is unpinned-crate 'os_info'
r3 core "$RES"
! grep '"code": "unpinned-crate"' "$T/report" >/dev/null || fail 'core needed a pin'
r3 unknown "$(prow res "$FNR" '"UTF8String"' NoSuchClass '{"form": "result", "selector": "description"}')"
exit_is 4 'an unknown class'; error_is unknown-class 'NoSuchClass'
r3 elsewhere "$(prow res "$FNR" '"UTF8String"' NSString '{"form": "elsewhere"}')"
exit_is 4 'an unknown form'; error_is malformed-build-evidence 'form elsewhere'
r3 unused "$RES, $(prow gone __RNvNtCslTKFwgOQWRM_7os_info3imp4gone '"UTF8String"' NSString '{"form": "result", "selector": "description"}')"
grep '"unused_position_evidence": \["gone"\]' "$T/report" >/dev/null || fail 'unused R3 row not reported'
r3 othersel "$(prow res "$FNR" '"lengthOfBytesUsingEncoding:"' NSString '{"form": "result", "selector": "description"}')"
want "$FNR" UTF8String unresolved; want "$FNR" lengthOfBytesUsingEncoding: floor-supported
r3 tworows "$RES, $(prow res2 "$FNR" '"UTF8String"' NSArray '{"form": "result", "selector": "description"}')"
exit_is 4 'two rows, two classes, one send'; error_is position-contradicted 'NSString and NSArray'
r3 merged "$(prow mrg "$FNM" '"UTF8String"' NSString '{"form": "result", "selector": "description"}')"
want "$FNM" UTF8String floor-supported
grep "\"function\": \"$FNM\"" "$T/report" | grep '"selector": "UTF8String"' | grep 'position not checked' >/dev/null ||
  fail 'a merged receiver closed by R3 does not say its position was not checked'
# spec: tools/objc-compat/source-evidence.c objc_apply_position_evidence -- R2 first: an R3 row agreeing with an R2 closure is used; one naming another class is refused.
PO=objc2::runtime::protocol_object::ProtocolObject
R2ROW="{\"id\": \"r2r\", \"symbol\": \"$FNR\", \"rust_type\": \"$PO\", \"position\": \"self\", \"kind\": \"-\", \"selectors\": [\"UTF8String\"], \"source\": \"r2cite\"}"
evidence "$R3B" "$T/ev-after" '' "$R2ROW" "$C3" "$M3, {\"rust_type\": \"$PO\", \"class\": \"NSString\", \"source\": \"s4\"}" '' "$RES"
analyze "$R3B" strict --build-evidence "$T/ev-after"
grep '"selector": "UTF8String"' "$T/report" | grep "\"function\": \"$FNR\"" | grep '"receiver_closure": "R2"' >/dev/null || fail 'R3 displaced an R2 closure'
! grep '"unused_position_evidence": \[[^]]*"res"' "$T/report" >/dev/null || fail 'an R3 row agreeing with R2 was reported unused'
evidence "$R3B" "$T/ev-after2" '' "$R2ROW" "$C3" "$M3, {\"rust_type\": \"$PO\", \"class\": \"NSString\", \"source\": \"s4\"}" '' \
  "$(prow res "$FNR" '"UTF8String"' NSArray '{"form": "result", "selector": "description"}')"
analyze "$R3B" strict --build-evidence "$T/ev-after2"
exit_is 4 'R3 disagreeing with R2'; error_is position-contradicted 'R2 says NSString'
# spec: tools/objc-compat/source-evidence.c objc_apply_position_evidence -- Rows for one send are judged together: any two that differ in class or kind are refused, in either order,
#       even when one class descends from the other.
OBJ="$(prow obj "$FNR" '"UTF8String"' NSObject '{"form": "result", "selector": "description"}')"
r3 sub-first "$RES, $OBJ"
exit_is 4 'NSString then NSObject'; error_is position-contradicted 'NSString then NSObject'
r3 sub-last "$OBJ, $RES"
exit_is 4 'NSObject then NSString'; error_is position-contradicted 'NSObject then NSString'
# spec: tools/objc-compat/source-evidence.c objc_apply_position_evidence -- A row meeting a send another rule closed must agree on the kind, not only the class.
evidence "$R3B" "$T/ev-kind" '' "$R2ROW" "$C3" "$M3, {\"rust_type\": \"$PO\", \"class\": \"NSString\", \"source\": \"s4\"}" '' \
  "$(prow res "$FNR" '"UTF8String"' NSString '{"form": "result", "selector": "description"}' | sed 's/"kind": "-"/"kind": "+"/')"
analyze "$R3B" strict --build-evidence "$T/ev-kind"
exit_is 4 'R3 + against R2 -'; error_is position-contradicted 'kind + against -'
# spec: tools/objc-compat/source-evidence.c objc_apply_position_evidence -- A downcast or field row is never checked against the binary's receiver: its basis says so.
r3 fldnote "$FLD"
grep "\"function\": \"$FNF.llvm.1\"" "$T/report" | grep 'position not checked' >/dev/null || fail 'a field closure does not say its position was not checked'
r3 dwnnote "$DWN"
grep "\"function\": \"$FND\"" "$T/report" | grep 'position not checked' >/dev/null || fail 'a downcast closure does not say its position was not checked'
# spec: tools/objc-compat/main.m build-evidence parser -- Evidence with no position_evidence reads as before.
evidence "$R3B" "$T/ev-none" '' '' "$C3" "$M3"
analyze "$R3B" strict --build-evidence "$T/ev-none"
want "$FNR" UTF8String unresolved

# spec: tools/objc-compat/classify.c header -- the real defective artifact: unsupported launch, guards only with review, every send classified.
if [ -n "${MAVERGREEN_OBJC_CODEX_ARTIFACT:-}" ]; then
  [ "$(sha "$MAVERGREEN_OBJC_CODEX_ARTIFACT")" = 1d056b0d4ada3d74b4c0f4c5450bc06856bfdbc504320fa430a4249f640f6c40 ] ||
    fail "unexpected Codex artifact"
  mkdir -p "$T/root/codex"
  ln "$MAVERGREEN_OBJC_CODEX_ARTIFACT" "$T/root/codex/codex" 2>/dev/null || cp "$MAVERGREEN_OBJC_CODEX_ARTIFACT" "$T/root/codex/codex"
  EV="$FX/codex-0.165.0-build-evidence.json"
  analyze "$T/root/codex/codex" strict --build-evidence "$EV"
  exit_is 1 'Codex 0.165.0 strict'
  committed=$(grep -o '"verdicts": {[^}]*}' "$T/report" | head -1)
  grep '"id": "x86_64@0x10d52d65f:-\[NSWorkspace openURLs:withApplicationAtURL:options:configuration:error:\]"' "$T/report" |
    grep '"verdict": "unsupported"' >/dev/null || fail 'the NSWorkspace launch is not unsupported'
  for s in accessibilityDisplayShouldReduceMotion isVoiceOverEnabled; do
    grep "\"selector\": \"$s\"" "$T/report" | grep '"verdict": "unresolved"' | grep -F 'its guard record is not reviewed' >/dev/null ||
      fail "$s is not unresolved pending review"
  done
  [ "$(grep -c '"verdict": ' "$T/report")" = 87 ] || fail 'not every Codex send has a finding'
  grep -F '"receiver_closure": {"open": 7, "measured": 42, "receipt": 30, "R2": 6, "downcast": 2, "source": 0, "R3": 0}' "$T/report" >/dev/null ||
    fail "Codex closure counts changed: $(grep -o '"receiver_closure": {[^}]*}' "$T/report")"
  # spec: tools/objc-compat/classify.c header -- R1 (b) closes the root-selector sends on receivers of unknown class:
  #       Codex defines no class and every dependency is captured. Their receivers stay open, so the closure counts
  #       above do not move.
  grep -F '"closure_class_roots": {"defined_classes": 0, "roots": {"NSObject": 0, "NSProxy": 0}, "runtime_class_creation_sites": 0, "uncaptured_dependencies": [], "blocking": [], "r1_unknown_receivers": true}' "$T/report" >/dev/null ||
    fail "Codex class roots changed: $(grep -o '"closure_class_roots": {[^}]*}[^}]*}' "$T/report")"
  grep -F '"verdicts": {"floor-supported": 81, "provided": 0, "guarded": 0, "unsupported": 1, "unresolved": 5}' "$T/report" >/dev/null ||
    fail "Codex verdicts changed: $(grep -o '"verdicts": {[^}]*}' "$T/report")"
  grep -F '"R1": 4,' "$T/report" >/dev/null || fail "Codex R1 closures changed: $(grep -o '"R1": [0-9]*' "$T/report")"
  residual 'Codex 0.165.0 strict'
  # spec: tools/objc-compat/source-evidence.c header -- with a review, the same build-bound records make both accessibility calls guarded.
  sed 's/"status": "required", "reviewer": null, "reason": null/"status": "reviewed", "reviewer": "test reviewer", "reason": "test-only review"/' "$EV" >"$T/codex-reviewed"
  analyze "$T/root/codex/codex" strict --build-evidence "$T/codex-reviewed"
  exit_is 1 'Codex with reviewed guards still fails on the launch'
  for s in accessibilityDisplayShouldReduceMotion isVoiceOverEnabled; do
    grep "\"selector\": \"$s\"" "$T/report" | grep '"verdict": "guarded"' >/dev/null || fail "$s not guarded with a reviewed record"
  done
  # spec: tools/objc-compat/source-evidence.c header -- every citation recomputes against the prepared source and the pinned crates.
  if [ -n "${MAVERGREEN_OBJC_CODEX_SOURCE:-}" ]; then
    for f in codex-rs/tui/src/system_motion.rs codex-rs/tui/src/screen_reader.rs; do
      h=$(sha "$MAVERGREEN_OBJC_CODEX_SOURCE/$f")
      grep -F "\"file\": \"$f\"" "$EV" | grep -F "\"sha256\": \"$h\"" >/dev/null || fail "$f does not match its guard citation"
    done
    grep -F 'if !workspace.respondsToSelector(selector) {' "$MAVERGREEN_OBJC_CODEX_SOURCE/codex-rs/tui/src/system_motion.rs" >/dev/null &&
      sed -n 130p "$MAVERGREEN_OBJC_CODEX_SOURCE/codex-rs/tui/src/screen_reader.rs" | grep -F 'workspace.respondsToSelector(selector) && workspace.isVoiceOverEnabled()' >/dev/null ||
      fail 'the prepared source no longer has the cited guards'
  fi
  echo "objc-classification: real Codex 0.165.0 with its committed build evidence: $committed"
fi
echo 'objc-classification: availability, ownership, guards, R1, R2, R3 and downcast fixtures pass'
