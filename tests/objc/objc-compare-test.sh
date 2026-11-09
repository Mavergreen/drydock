#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then runs compare.sh over doctored baselines
# spec: tests/objc/baseline/compare.sh header -- COMPARE_MODE=fewer-unmeasured lets a report lose only the error kinds
#       it names, table-byte errors only inside a table the reader lists, "different value" and "read other" errors
#       only in a function holding one it follows, "not followed" only at such a function's start, "address taken"
#       only at a weak import's check, and undecoded bytes only by what the listed tables hold; an added error, or
#       any other lost error, fails. fewer-passed-arguments and the default identical mode refuse all of these.
#       COMPARE_RENAMED=1 maps a detail's ": reason" back to the baseline's detail, and nothing else.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
COMPARE="$HERE/baseline/compare.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-compare-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/log" ] || tail -20 "$T/log" >&2; exit 1; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 "$@"; }
# spec: tests/objc/fixtures/jt-reject-clobber.S header -- CLOBBER 0 a followed table, CLOBBER 1 the refused twin
# CLOBBER 14 is 0 with a register copy in its first case
for c in 0 1 14; do
  cc -DCLOBBER=$c "$FX/jt-reject-clobber.S" -o "$T/jt$c" -framework Foundation -lobjc -Wl,-no_data_in_code_info
done
# spec: tests/objc/fixtures/weak-import-check.S header -- FORM 0 a weak import's check, measured
cc -DFORM=0 "$FX/weak-import-check.S" -o "$T/weak" -lobjc -Wl,-U,_objc_readClassPair
# spec: tests/objc/fixtures/swizzle.m header -- FORM 1 method_setImplementation, FORM 4 class_addProtocol;
#       tests/objc/fixtures/unsupported.c FORM 6 objc_allocateClassPair
for f in 1 4; do cc -O1 -DFORM=$f "$FX/swizzle.m" -o "$T/sw$f" -framework Foundation -lobjc; done
cc -O1 -DFORM=6 "$FX/unsupported.c" -o "$T/made" -lobjc
# spec: tests/objc/fixtures/imp-lookup.c header -- FORM 1 method_getImplementation
cc -O1 -DFORM=1 "$FX/imp-lookup.c" -o "$T/imp" -lobjc
sh "$HERE/baseline/record-artifacts.sh" "$DRYDOCK_OBJC" "$ROOT/reference/objc" "$T/base" \
  jt0 "$T/jt0" - jt1 "$T/jt1" - jt14 "$T/jt14" - weak "$T/weak" - sw1 "$T/sw1" - sw4 "$T/sw4" - made "$T/made" - imp "$T/imp" - 2>/dev/null

# the table the reader lists for jt0: jmp, table, entries, function start, end
DRYDOCK_OBJC_JUMP_TABLES=1 "$DRYDOCK_OBJC" analyze --artifact "$T/jt0" --root "$T" --references "$ROOT/reference/objc" \
  --report "$T/jt0.json" --mode strict 2> "$T/jt0.stderr" || fail "jt0 is not measured"
line=$(grep '^drydock-objc-jump-table	' "$T/jt0.stderr") || fail "the reader lists no jump table in jt0"
[ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" = 1 ] || fail "the reader lists more than jt0's one table"
jmp=$(printf '%s\n' "$line" | cut -f2)
table=$(printf '%s\n' "$line" | cut -f3)
fn=$(printf '%s\n' "$line" | cut -f5)
[ "$(printf '%s\n' "$line" | cut -f7)" = followed ] || fail "jt0's table is not followed"

# doctor FILE PROGRAM [ERROR]: a copy of the baseline whose FILE report awk PROGRAM rewrote (ERROR in its variable e)
n=0
doctor() {
  n=$((n + 1)); d="$T/doc$n"
  cp -R "$T/base" "$d"
  awk -v e="${3:-}" "$2" "$d/$1.objc-compat.json" > "$d/x" && mv "$d/x" "$d/$1.objc-compat.json"
}
err() { printf '{"code": "%s", "slice": "x86_64", "address": "%s", "detail": "%s"}' "$1" "$2" "$3"; }
# passes|refuses WHAT [MODE]: compare.sh over the doctored copy $d, in MODE (default fewer-unmeasured)
# RN: COMPARE_RENAMED for them (0 unless a line sets it)
RN=0
passes() { COMPARE_RENAMED=$RN COMPARE_MODE=${2:-fewer-unmeasured} sh "$COMPARE" "$d" "$DRYDOCK_OBJC" > "$T/log" 2>&1 || fail "$1: compare refused it"; }
refuses() { ! COMPARE_RENAMED=$RN COMPARE_MODE=${2:-fewer-unmeasured} sh "$COMPARE" "$d" "$DRYDOCK_OBJC" > "$T/log" 2>&1 || fail "$1 (${2:-fewer-unmeasured}): compare let it pass"; }
# spec: tests/objc/baseline/compare.sh split_errors -- an empty list is "errors": []}; a full one opens at the end
#       of its line, one error per line after it
ONLY='{ if (sub(/"errors": \[\]}$/, "\"errors\": [" e "]}")) n++; print } END { exit n != 1 }'
FIRST='{ print } /"errors": \[$/ { print "  " e ","; n++ } END { exit n != 1 }'
DROP='k == 1 { k = 2; next } { print } /"errors": \[$/ { k = 1 } END { exit k != 2 }'
READ='objc entry point in r12 is read other than to call through it (a spill, a copy or an escape)'
MERGED='objc entry point in r12 is called through where another path left a different value'

d="$T/base"; passes 'the recorded baseline'
grep -q '^compare: jt0: exit 0, identical apart from analyzer and reference identity$' "$T/log" || fail "the recorded baseline: not identical"

doctor jt0 "$ONLY" "$(err indirect-objc-entry "$table" "$READ")"; passes 'a lost table error inside the listed table'
grep -q '1 fewer errors inside a jump table' "$T/log" || fail 'a lost table error inside the listed table: not counted'
refuses 'a lost table error' fewer-passed-arguments
refuses 'a lost table error' identical
doctor jt1 "$FIRST" "$(err indirect-objc-entry "$fn" "$READ")"; refuses 'a lost table error outside any table'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost table error outside any table: refused for another reason'
# spec: tests/objc/baseline/compare.sh header -- a "read other" error may vanish only at a 64-bit register copy in a
#       followed table's cases, [jmp, T)
copy=$(otool -tV "$T/jt14" | awk '$2 == "movq" && $3 == "%r12," && $4 == "%rax" { print $1; exit }' | sed 's/^0*/0x/')
[ -n "$copy" ] || fail 'jt14: no movq %r12, %rax'
doctor jt14 "$ONLY" "$(err indirect-objc-entry "$copy" "$READ")"; passes 'a lost "read other" error at a register copy in a followed table'"'"'s cases'
grep -q '1 fewer "read other" errors at a register copy' "$T/log" || fail 'a lost "read other" error at a copy: not counted'
refuses 'a lost "read other" error at a copy' fewer-passed-arguments
doctor jt0 "$ONLY" "$(err indirect-objc-entry "$fn" "$READ")"; refuses 'a lost "read other" error outside the cases'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost "read other" error outside the cases: refused for another reason'
doctor jt0 "$ONLY" "$(err indirect-objc-entry "$jmp" "$READ")"; refuses 'a lost "read other" error in the cases, not at a copy'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost "read other" error not at a copy: refused for another reason'
NOTFOLLOWED='objc entry point loaded in a function whose control flow is not followed'
doctor jt0 "$ONLY" "$(err indirect-objc-entry "$fn" "$NOTFOLLOWED")"; passes 'a lost "not followed" error at a followed table'"'"'s function'
grep -q '1 fewer functions whose control flow is not followed' "$T/log" || fail 'a lost "not followed" error: not counted'
doctor jt0 "$ONLY" "$(err indirect-objc-entry "$(printf '0x%x' $((fn + 1)))" "$NOTFOLLOWED")"
refuses 'a lost "not followed" error off its function'"'"'s start'
# spec: tests/objc/baseline/compare.sh header -- an "address taken" error may vanish only at a weak import's check
check=$(otool -tV "$T/weak" | awk '$2 ~ /^cmpq$/ && $4 ~ /\(%rip\)$/ { printf "0x%s", $1; exit }' | sed 's/^0x0*/0x/')
[ -n "$check" ] || fail 'weak: otool shows no cmpq of a rip-relative slot'
doctor weak "$ONLY" "$(err indirect-objc-entry "$check" '_objc_readClassPair address taken')"; passes 'a lost "address taken" error at a weak import'"'"'s check'
grep -q '1 fewer "address taken" errors at a weak import' "$T/log" || fail 'a lost "address taken" error at the check: not counted'
refuses 'a lost "address taken" error at the check' fewer-passed-arguments
wfn=$(nm "$T/weak" | awk '$3 == "_main" { print $1 }' | sed 's/^0*/0x/')
doctor weak "$ONLY" "$(err indirect-objc-entry "$wfn" '_objc_readClassPair address taken')"; refuses 'a lost "address taken" error elsewhere'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost "address taken" error elsewhere: refused for another reason'
doctor weak "$ONLY" "$(err indirect-objc-entry "$check" 'fetch function address taken')"; refuses 'a lost "fetch function address taken" error at the check'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost "address taken" error elsewhere: refused for another reason'
# spec: tests/objc/baseline/compare.sh header -- COMPARE_RENAMED=1: a detail may gain only its own ": reason". jt1's
#       cases are refused "in code reached only through an indirect jump this reader does not follow"; its baseline is
#       doctored back to the detail before it.
SEED=': in code reached only through an indirect jump this reader does not follow'
grep -q "$MERGED$SEED" "$T/base/jt1.objc-compat.json" || fail "jt1's cases are not refused by name"
doctor jt1 '{ n += gsub(/: in code reached only through an indirect jump this reader does not follow"/, "\""); print } END { exit !n }'
refuses 'a renamed error' fewer-unmeasured
grep -q 'new, changed or reordered error' "$T/log" || fail 'a renamed error: refused for another reason'
RN=1
passes 'a renamed error, mapped'
grep -q "^compare: jt1: exit 4, identical apart from analyzer and reference identity and 3 errors renamed\$" "$T/log" || fail 'a renamed error, mapped: not counted as 3'
passes 'a renamed error, mapped' identical
doctor jt1 '{ n += gsub(/: in code reached only through an indirect jump this reader does not follow"/, ": stored to memory at 0x1\""); print } END { exit !n }'
refuses 'a renamed error whose baseline names another reason'
doctor jt1 '{ n += gsub(/where another path left a different value: in code reached only through an indirect jump this reader does not follow"/, "is returned\""); print } END { exit !n }'
refuses 'a renamed error whose baseline is another error'
RN=0
doctor jt0 "$ONLY" "$(err indirect-objc-entry "$fn" "$MERGED")"; refuses 'a lost "different value" error outside the cases'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost "different value" error outside the cases: refused for another reason'
doctor jt0 "$ONLY" "$(err indirect-objc-entry "$jmp" "$MERGED")"; passes 'a lost "different value" error in a followed table'"'"'s cases'
refuses 'a lost "different value" error' fewer-passed-arguments
refuses 'a lost "different value" error' identical
doctor jt0 "$ONLY" "$(err unclassified-objc-runtime-import "$fn" _class_getMethodImplementation)"; refuses 'a lost unrelated error'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost unrelated error: refused for another reason'
# spec: tests/objc/baseline/compare.sh header -- an unclassified-objc-runtime-import error may vanish when its symbol is
#       one src/objc/macho-reader.c ROLES now classifies as memory or introspection, and only in fewer-unmeasured
for sym in _objc_getProperty _objc_setProperty_nonatomic_copy _objc_setAssociatedObject _class_respondsToSelector \
           _object_setIvar _objc_constructInstance _objc_disposeClassPair; do
  doctor jt0 "$ONLY" "$(err unclassified-objc-runtime-import "$fn" "$sym")"; passes "a lost unclassified $sym"
  grep -q '1 fewer unclassified-objc-runtime-import errors for imports now classified' "$T/log" || fail "a lost unclassified $sym: not counted"
done
refuses 'a lost unclassified _objc_disposeClassPair' fewer-passed-arguments
refuses 'a lost unclassified _objc_disposeClassPair' identical
# the ones this piece makes runtime-method-swizzle or runtime-class-creation are renamed, never lost
for sym in _method_setImplementation _method_exchangeImplementations _class_replaceMethod _class_addProtocol _class_addIvar \
           _class_addProperty _objc_initializeClassPair _class_addMethod _method_getImplementation \
           _class_getMethodImplementation_stret; do
  doctor jt0 "$ONLY" "$(err unclassified-objc-runtime-import "$fn" "$sym")"; refuses "a lost unclassified $sym"
  grep -q '^compare: lost error ' "$T/log" || fail "a lost unclassified $sym: refused for another reason"
done
# spec: tests/objc/baseline/compare.sh header -- COMPARE_RENAMED=1: an unclassified-objc-runtime-import error may become
#       runtime-method-swizzle (method_setImplementation, method_exchangeImplementations, class_replaceMethod) or
#       runtime-class-creation (class_addProtocol, class_addIvar, class_addProperty, objc_initializeClassPair) or
#       runtime-imp-lookup (method_getImplementation, class_getMethodImplementation[_stret]) at the same
#       place, its detail the symbol's; nothing else. Each baseline is doctored back to the unclassified error.
# unclassify NAME CODE SYMBOL [AS]: NAME's CODE error naming SYMBOL becomes unclassified AS (default SYMBOL); a
#       runtime-class-creation error leaves "runtime_class_creation_sites" one lower unless KEEP_SITES is set
unclassify() {
  n=$((n + 1)); d="$T/doc$n"
  cp -R "$T/base" "$d"
  if [ "$2" = runtime-class-creation ] && [ -z "${KEEP_SITES:-}" ]; then
    awk '{ if (match($0, /"runtime_class_creation_sites": [0-9]+/)) { v = substr($0, RSTART + 32, RLENGTH - 32) - 1
             $0 = substr($0, 1, RSTART - 1) "\"runtime_class_creation_sites\": " v substr($0, RSTART + RLENGTH); k++ } print }
         END { exit k != 1 }' "$d/$1.objc-compat.json" > "$d/x" || fail "unclassify $1: no runtime_class_creation_sites"
    mv "$d/x" "$d/$1.objc-compat.json"
  fi
  sed -E "s/\{\"code\": \"$2\", (\"slice\": \"[^\"]*\", \"address\": \"0x[0-9a-f]+\"), \"detail\": \"$3: [^\"]*\"\}/{\"code\": \"unclassified-objc-runtime-import\", \1, \"detail\": \"${4:-$3}\"}/" \
    "$d/$1.objc-compat.json" > "$d/x"
  ! cmp -s "$d/x" "$d/$1.objc-compat.json" || fail "unclassify $1 $2 $3: no such error"
  mv "$d/x" "$d/$1.objc-compat.json"
}
grep -q '"code": "runtime-method-swizzle", .*"detail": "_method_setImplementation: ' "$T/base/sw1.objc-compat.json" ||
  fail 'sw1: method_setImplementation is not runtime-method-swizzle'
unclassify sw1 runtime-method-swizzle _method_setImplementation
RN=0; refuses 'a swizzle renamed from unclassified, unmapped'
grep -q 'new, changed or reordered error' "$T/log" || fail 'a swizzle renamed from unclassified, unmapped: refused for another reason'
RN=1; passes 'a swizzle renamed from unclassified'
grep -q '^compare: sw1: exit 4, identical apart from analyzer and reference identity and 1 errors renamed$' "$T/log" ||
  fail 'a swizzle renamed from unclassified: not counted as 1'
passes 'a swizzle renamed from unclassified' identical
unclassify sw1 runtime-method-swizzle _method_setImplementation _class_addMethod; refuses 'a swizzle renamed from another symbol'
unclassify sw4 runtime-class-creation _class_addProtocol; passes 'a class change renamed from unclassified'
grep -q '^compare: sw4: exit 4, identical apart from analyzer and reference identity and 1 errors renamed$' "$T/log" ||
  fail 'a class change renamed from unclassified: not counted as 1'
KEEP_SITES=1 unclassify sw4 runtime-class-creation _class_addProtocol
refuses 'a class change renamed from unclassified, runtime_class_creation_sites not risen with it'
grep -q 'runtime_class_creation_sites 1 -> 1 is not the 1 runtime-class-creation errors renamed' "$T/log" ||
  fail 'runtime_class_creation_sites not risen: refused for another reason'
unclassify made runtime-class-creation _objc_allocateClassPair; refuses 'a class creation this piece did not classify, renamed'
unclassify imp runtime-imp-lookup _method_getImplementation; passes 'an imp lookup renamed from unclassified'
grep -q '^compare: imp: exit 4, identical apart from analyzer and reference identity and 1 errors renamed$' "$T/log" ||
  fail 'an imp lookup renamed from unclassified: not counted as 1'
unclassify imp runtime-imp-lookup _method_getImplementation _class_getInstanceMethod; refuses 'an imp lookup renamed from another symbol'
RN=0
# jt1's table is not followed: its "different value" errors may not vanish
doctor jt1 "$FIRST" "$(err indirect-objc-entry "$jmp" "$MERGED")"
refuses 'a lost "different value" error in a function holding no followed table'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost "different value" error with no followed table: refused for another reason'
doctor jt1 "$DROP"; refuses 'an added error'
grep -q 'new, changed or reordered error' "$T/log" || fail 'an added error: refused for another reason'
# spec: tests/objc/baseline/compare.sh header -- undecoded_code_bytes may only fall, by at most the listed tables' bytes
ub=$(grep -o '"undecoded_code_bytes": [0-9]*' "$T/base/jt0.objc-compat.json" | awk '{ print $2 }')
room=$(( 4 * $(printf '%s\n' "$line" | cut -f4) ))
UB='{ n += gsub(/"undecoded_code_bytes": [0-9]+/, "\"undecoded_code_bytes\": " e); print } END { exit n != 1 }'
# a rise: jt1 decodes its unrecognised table as code, so it has undecoded bytes to lower in its baseline
ub1=$(grep -o '"undecoded_code_bytes": [0-9]*' "$T/base/jt1.objc-compat.json" | awk '{ print $2 }')
[ "$ub1" -ge 1 ] || fail "jt1 decodes every byte: no rise to doctor"
doctor jt1 "$UB" $((ub1 - 1)); refuses 'undecoded bytes that rose'
grep -q 'undecoded_code_bytes rose' "$T/log" || fail 'undecoded bytes that rose: refused for another reason'
doctor jt0 "$UB" $((ub + room + 1)); refuses 'undecoded bytes that fell by more than the listed tables hold'
grep -q 'undecoded_code_bytes rose, or fell by more' "$T/log" || fail 'undecoded bytes that fell too far: refused for another reason'
doctor jt0 "$UB" $((ub + room)); passes 'undecoded bytes that fell by exactly the listed tables'"'"' bytes'
grep -q "^compare: jt0: exit 0, identical apart from analyzer and reference identity and $room fewer undecoded bytes\$" "$T/log" ||
  fail "undecoded bytes that fell by the tables' bytes: not reported as $room fewer"
refuses 'undecoded bytes that fell' fewer-passed-arguments
refuses 'undecoded bytes that fell' identical
echo "PASS: objc-compare-test"
