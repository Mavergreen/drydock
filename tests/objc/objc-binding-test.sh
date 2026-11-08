#!/bin/sh
# platform: macOS-only -- links x86_64 objc2-shaped fixtures against the pinned 10.9 SDK, then binds them
# spec: tools/objc-compat/binding.c header -- binding
#       forms from exact v0 symbols and fetch-site bytes, never selector spellings guessed from
#       Rust underscores; receiver/kind only from an explicit receipt; unknown forms cannot-measure.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
FX="$HERE/fixtures/objc-api"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-binding-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/out" ] || tail -20 "$T/out" >&2; exit 1; }

sh "$ROOT/scripts/objc-compat-build.sh" --reader-driver "$T/reader" || fail "binding harness did not build"
SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch x86_64)
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@"; }
objc2() {
  out=$1; shift
  cc "$@" "$FX/objc2-pattern.c" -o "$out" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_NSSelectorFromString -Wl,-U,_fixture_nsstring
}
bind() { rc=0; "$T/reader" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
refused() {
  [ "$rc" = 4 ] || fail "$1: expected cannot-measure exit 4, got $rc"
  grep "^error	$2	" "$T/out" >/dev/null || fail "$1: expected error $2"
}
# spec: tools/objc-compat/binding.c header -- binding row: 1 tag 2 demangled 3 form 4 crate 5 rust owner 6 rust fn 7 recovered name 8 receiver 9 kind 10 provenance
row() { awk -F '\t' -v d="$1" -v n="$2" '$1 == "binding" && $2 == d && $7 == n' "$T/out"; }
OPEN='openURLs:withApplicationAtURL:options:configuration:error:'
WS='<objc2_app_kit::generated::__NSWorkspace::NSWorkspace>'

# spec: tools/objc-compat/binding.c header -- v0 grammar: exact display, cache-static and producer-form recognition for real Codex symbols.
grep -v '^#' "$FX/binding-symbols.tsv" | cut -f1 >"$T/symbols"
"$T/reader" --demangle <"$T/symbols" >"$T/demangled" || fail 'a real Codex symbol was refused'
grep -v '^#' "$FX/binding-symbols.tsv" | cmp -s - "$T/demangled" || {
  grep -v '^#' "$FX/binding-symbols.tsv" | diff - "$T/demangled" >&2; fail 'v0 demangling changed'; }
rc=0; "$T/reader" --demangle <"$FX/binding-refused.txt" >"$T/out" || rc=$?
[ "$rc" = 4 ] || fail "unsupported v0 grammar exit $rc, want 4"
[ "$(grep -c '	refused	' "$T/out")" = "$(wc -l <"$FX/binding-refused.txt" | tr -d ' ')" ] ||
  fail 'an unsupported symbol was demangled instead of refused'

# spec: tools/objc-compat/binding.c header -- Forms without a receipt: owner/fn from the static's path, selector from bytes, receiver unknown.
objc2 "$T/objc2"
bind --artifact "$T/objc2"
[ "$rc" = 0 ] || fail "objc2 fixture exit $rc"
r=$(row "$WS::openURLs_withApplicationAtURL_options_configuration_error::CACHED_SEL" "$OPEN")
[ "$(printf '%s\n' "$r" | cut -f3-6,8-10)" = "inherent-method	objc2_app_kit	$WS	openURLs_withApplicationAtURL_options_configuration_error	-	-	-" ] ||
  fail "launch binding wrong: $r"
r=$(row '<objc2_app_kit::generated::__NSWorkspace::NSWorkspace as objc2::top_level_traits::ClassType>::class::CACHED_CLASS' NSWorkspace)
[ "$(printf '%s\n' "$r" | cut -f3,4,6)" = "trait-method	objc2_app_kit	class" ] || fail "class binding wrong: $r"
# platform: two statics in one closure share a display path; their bytes keep them apart, as a
#           pair of alternatives rather than an owner x selector cross-product.
NE='objc2::__macro_helpers::null_error::create_null_error::{closure#0}::CACHED_SEL'
[ "$(row "$NE" stringWithUTF8String: | cut -f3)" = closure ] && [ "$(row "$NE" errorWithDomain:code:userInfo: | cut -f3)" = closure ] ||
  fail 'null_error closure pair not bound by bytes'
[ "$(awk -F '\t' -v d="$NE" '$1 == "binding" && $2 == d' "$T/out" | wc -l | tr -d ' ')" = 2 ] || fail 'null_error pair miscounted'

# spec: tools/objc-compat/binding.c header -- A receipt supplies receiver and kind for exactly the rows it names.
{
  echo '# objc-binding-receipt 1'
  printf '%s\t%s\t%s\t%s\t%s\n' "$WS::openURLs_withApplicationAtURL_options_configuration_error::CACHED_SEL" "$OPEN" NSWorkspace - 'objc2-app-kit-0.3.2 src/generated/NSWorkspace.rs'
  printf '%s\t%s\t%s\t%s\t%s\n' "$WS::sharedWorkspace::CACHED_SEL" sharedWorkspace NSWorkspace + 'objc2-app-kit-0.3.2 src/generated/NSWorkspace.rs'
} >"$T/receipt"
bind --artifact "$T/objc2" --binding-receipt "$T/receipt"
[ "$rc" = 0 ] || fail "receipt join exit $rc"
[ "$(row "$WS::openURLs_withApplicationAtURL_options_configuration_error::CACHED_SEL" "$OPEN" | cut -f8,9)" = "NSWorkspace	-" ] || fail 'receipt receiver/kind not applied'
[ "$(row "$WS::sharedWorkspace::CACHED_SEL" sharedWorkspace | cut -f8,9)" = "NSWorkspace	+" ] || fail 'class-method kind not applied'
[ "$(row "$NE" stringWithUTF8String: | cut -f8)" = - ] || fail 'receipt leaked onto an unnamed row'

# spec: tools/objc-compat/binding.c header -- A receipt that disagrees with the artifact's bytes, or is malformed, is cannot-measure.
{ echo '# objc-binding-receipt 1'
  printf '%s\t%s\t%s\t%s\t%s\n' "$WS::openURLs_withApplicationAtURL_options_configuration_error::CACHED_SEL" 'openURLs:withApplicationAtURL:options:configuration:' NSWorkspace - guess; } >"$T/conflict"
bind --artifact "$T/objc2" --binding-receipt "$T/conflict"; refused 'receipt conflict' binding-receipt-conflict
printf 'no header\n' >"$T/bad"
bind --artifact "$T/objc2" --binding-receipt "$T/bad"; refused 'receipt header' malformed-binding-receipt
{ echo '# objc-binding-receipt 1'; printf 'a\tb\tc\t*\td\n'; } >"$T/bad"
bind --artifact "$T/objc2" --binding-receipt "$T/bad"; refused 'receipt kind' malformed-binding-receipt
bind --artifact "$T/objc2" --binding-receipt "$T/missing"; refused 'receipt missing' unreadable-binding-receipt

# spec: tools/objc-compat/binding.c header -- Renamed producers and statics are unknown forms: refused, not silently dropped.
objc2 "$T/renamed-fetch" -DFETCH_SEL_SYM='"__RNvMNtNtCs2ucXwfqiSr7_5objc215___macro_helpers5cacheNtB2_9CachedSel6fetch2"'
bind --artifact "$T/renamed-fetch"; refused 'renamed fetch' computed-selector-producer
grep '^error	cache-without-fetch	' "$T/out" >/dev/null || fail 'renamed fetch left caches silently unnamed'
objc2 "$T/renamed-static" -DCACHE_OPEN_SYM='"__RNvNvMsj_NtNtCsc3rn5Z0uvZ2_13objc2_app_kit9generated13___NSWorkspaceNtB7_11NSWorkspace57openURLs_withApplicationAtURL_options_configuration_error10CACHED_SEX"'
bind --artifact "$T/renamed-static"; refused 'renamed static' unrecognized-fetch-site
objc2 "$T/root-static" -DCACHE_OPEN_SYM='"__RNvCs2ucXwfqiSr7_5objc210CACHED_SEL"'
bind --artifact "$T/root-static"; refused 'unknown enclosing item' unsupported-binding-form
# spec: tools/objc-compat/binding.c header -- Receiver/use closure. send row: 1 tag 2 site 3 callee 4 selector 5 receiver 6 kind 7 closed|open 8 basis 9 reason. 10 incoming path (a merged call's) or -.
SIGS="$FX/closure-signatures.tsv" FACTS="$FX/closure-facts.tsv"
closure_fixture() {
  cc -DOPEN_FORM="$1" "$FX/closure.c" -o "$2" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_NSSelectorFromString -Wl,-U,_fixture_nsstring \
    -Wl,-U,_fixture_use -Wl,-U,_objc_retainAutoreleasedReturnValue -Wl,-U,_objc_release
}
close_sends() { art=$1; shift; bind --artifact "$art" "$@" --close --signatures "$SIGS" --sdk-facts "$FACTS"; }
closed() {
  got=$(awk -F '\t' -v s="$1" '$1 == "send" && $4 == s' "$T/out")
  [ "$(printf '%s\n' "$got" | grep -c .)" = "$4" ] &&
    [ -z "$(printf '%s\n' "$got" | awk -F '\t' -v r="$2" -v k="$3" 'NF && !($5 == r && $6 == k && $7 == "closed")')" ] ||
    fail "want $4 closed $1 to $3$2, got: $got"
}
opened() {
  awk -F '\t' -v s="$1" -v why="$2" '$1 == "send" && $4 == s && $7 == "open" && $5 == "-" && index($9, why) {f = 1} END {exit !f}' "$T/out" ||
    fail "no open $1 send because '$2': $(grep '^send' "$T/out" | grep -F "$1")"
}
PB='<objc2_app_kit::generated::__NSPasteboard::NSPasteboard>'
{ echo '# objc-binding-receipt 1'
  printf '%s\t%s\t%s\t%s\t%s\n' "$PB::pasteboardItems::CACHED_SEL" pasteboardItems NSPasteboard - 'objc2-app-kit-0.3.2 src/generated/NSPasteboard.rs:382'
} >"$T/items-receipt"
closure_fixture 0 "$T/closure"

# spec: tools/objc-compat/binding.c header -- The strict positive: every send closes, through measured class operands, allocation, declared results and one receipt.
close_sends "$T/closure" --binding-receipt "$T/items-receipt"
[ "$rc" = 0 ] && ! grep '^error' "$T/out" >/dev/null || fail "positive closure exit $rc"
closed sharedWorkspace NSWorkspace + 2
closed respondsToSelector: NSWorkspace - 1
closed isVoiceOverEnabled NSWorkspace - 2
[ "$(awk -F '\t' '$1 == "send" && $4 == "isVoiceOverEnabled" {print $2}' "$T/out" | sort -u | wc -l | tr -d ' ')" = 2 ] ||
  fail 'the unguarded second caller of a shared cache was merged into the guarded one'
closed new NSDictionary + 1
closed init - - 0
closed generalPasteboard NSPasteboard + 1
closed pasteboardItems NSPasteboard - 2
closed countByEnumeratingWithState:objects:count: NSArray - 1
closed alloc NSString + 1
closed initWithBytes:length:encoding: NSString - 1
closed stringWithUTF8String: NSString + 1
closed errorWithDomain:code:userInfo: NSError + 1
closed description NSDictionary + 1
awk -F '\t' '$1 == "send" && $4 == "countByEnumeratingWithState:objects:count:" && index($8, "-[NSPasteboard pasteboardItems]") && index($8, "declared NSArray")' "$T/out" |
  grep . >/dev/null || fail 'the enumerated array is not closed through the declared -pasteboardItems result'
awk -F '\t' '$1 == "send" && $4 == "initWithBytes:length:encoding:" && index($8, "allocated NSString")' "$T/out" | grep . >/dev/null ||
  fail 'the class-cluster init is not tied to its allocation'
awk -F '\t' '$1 == "send" && $4 == "pasteboardItems" && index($8, "receipt ") && index($8, "incoming argument")' "$T/out" | grep . >/dev/null ||
  fail 'the argument receiver did not close through its receipt, or hid what was measured'

# spec: tools/objc-compat/binding.c header -- Without the receipt, or without declared results, those receivers stay open: an input requirement, not a pass.
close_sends "$T/closure"
refused 'no receipt' unresolved-receiver
opened pasteboardItems 'incoming argument 0 of _items_of'
[ "$(grep -c '^error	' "$T/out")" = 1 ] || fail 'a missing receipt opened more than its own send'
bind --artifact "$T/closure" --binding-receipt "$T/items-receipt" --close
refused 'no signatures' unresolved-receiver
opened respondsToSelector: 'no signature facts loaded'
opened countByEnumeratingWithState:objects:count: 'no signature facts loaded'

# spec: tools/objc-compat/binding.c header -- Each Codex-shaped unknown stays open with its reason; nothing is guessed from a protocol or NSObject.
for form in '1:isKindOfClass::is declared id by NSPropertyListSerialization' '2:description:incoming argument 0 of _protocol_debug' \
            '3:countByEnumeratingWithState:objects:count::not modelled' '5:description:not modelled'; do
  n=${form%%:*}; rest=${form#*:}; why=${rest##*:}; sel=${rest%:*}
  closure_fixture "$n" "$T/open$n"
  close_sends "$T/open$n" --binding-receipt "$T/items-receipt"
  refused "open form $n" unresolved-receiver
  opened "$sel" "$why"
  [ "$(grep -c '^error	' "$T/out")" = 1 ] || fail "open form $n opened more than one send"
done
closure_fixture 4 "$T/open4"
close_sends "$T/open4" --binding-receipt "$T/items-receipt"
refused 'computed selector' unresolved-selector

# spec: tools/objc-compat/binding.c header -- a call read once per incoming path (tests/fixtures/objc-api/merged-send.S)
#       gives one send per path, each closed on its own; its result closes only when every path's result closes to the
#       same class and kind. A send split by receiver alone stays one send per path, each with its own receiver.
{ echo '# objc-signatures 1'
  printf 'method\tNSArray\t+\tarray\tinstancetype\t-\tfixture.h:1\tinterface\n'
  printf 'method\tNSArray\t+\tarrayWithObject:\tinstancetype\t-\tfixture.h:2\tinterface\n'
  printf 'method\tNSDictionary\t+\tdictionary\tinstancetype\t-\tfixture.h:3\tinterface\n'
} >"$T/merged-sigs"
merged() { cc -DFORM="$1" "$FX/merged-send.S" -o "$T/merged$1" -framework Foundation -lobjc
           bind --artifact "$T/merged$1" --close --signatures "$T/merged-sigs" --sdk-facts "$FACTS"; }
merged 0
[ "$rc" = 0 ] && ! grep '^error' "$T/out" >/dev/null || fail "merged send form 0: exit $rc"
closed array NSArray + 1
closed arrayWithObject: NSArray + 1
closed count NSArray - 1
awk -F '\t' '$1 == "send" && $4 == "count" && index($8, "every incoming path of merged send")' "$T/out" | grep . >/dev/null ||
  fail 'the merged result did not close through every incoming path'
[ "$(awk -F '\t' '$1 == "send" && $10 != "-"' "$T/out" | wc -l | tr -d ' ')" = 2 ] || fail 'merged send form 0: the paths do not name themselves'
merged 1
refused 'merged send form 1' unresolved-selector
opened count 'result of open send'
merged 2
refused 'merged send form 2' unresolved-receiver
closed dictionary NSDictionary + 1
opened count 'its paths give -NSArray and -NSDictionary'
merged 3
[ "$rc" = 0 ] && ! grep '^error' "$T/out" >/dev/null || fail "merged send form 3: exit $rc"
awk -F '\t' '$1 == "send" && $4 == "count" {print $5, $6, $7}' "$T/out" | sort | tr '\n' ';' |
  grep -x 'NSArray - closed;NSDictionary - closed;' >/dev/null || fail "merged send form 3: $(grep '^send' "$T/out" | grep count)"
[ "$(awk -F '\t' '$1 == "send" && $4 == "count" {print $10}' "$T/out" | sort -u | grep -vc '^-$')" = 2 ] ||
  fail 'merged send form 3: the two count sends do not name their paths'

# spec: tools/objc-compat/binding.c header -- A receipt must agree with what was measured, and may not describe a shared helper's cache.
WS='<objc2_app_kit::generated::__NSWorkspace::NSWorkspace>'
{ cat "$T/items-receipt"
  printf '%s\t%s\t%s\t%s\t%s\n' "$WS::isVoiceOverEnabled::CACHED_SEL" isVoiceOverEnabled NSPasteboard - wrong; } >"$T/wrong-receipt"
close_sends "$T/closure" --binding-receipt "$T/wrong-receipt"
refused 'receipt contradicts measurement' receiver-receipt-conflict
{ cat "$T/items-receipt"
  printf '%s\t%s\t%s\t%s\t%s\n' "$WS::isVoiceOverEnabled::CACHED_SEL" isVoiceOverEnabled NSWorkspace - 'objc2-app-kit-0.3.2 src/generated/NSAccessibility.rs:180'; } >"$T/agree-receipt"
close_sends "$T/closure" --binding-receipt "$T/agree-receipt"
[ "$rc" = 0 ] || fail "an agreeing receipt exit $rc"
{ cat "$T/items-receipt"
  printf '%s\t%s\t%s\t%s\t%s\n' 'objc2::runtime::nsobject::NSObjectProtocol::description::CACHED_SEL' description NSObject - guess; } >"$T/helper-receipt"
closure_fixture 2 "$T/open2"
close_sends "$T/open2" --binding-receipt "$T/helper-receipt"
refused 'receipt on a shared helper' receipt-on-shared-helper

# spec: tools/objc-compat/reference.c header -- Unreadable or malformed references are cannot-measure, never a partial load.
tail -n +2 "$SIGS" >"$T/headless"
bind --artifact "$T/closure" --close --signatures "$T/headless"; refused 'signatures without header' malformed-reference
bind --artifact "$T/closure" --close --signatures "$T/missing"; refused 'missing signatures' unreadable-reference
{ head -1 "$SIGS"; printf 'method\tNSX\t+\tx\tsometimes\t-\ts\tc\n'; } >"$T/badkind"
bind --artifact "$T/closure" --close --signatures "$T/badkind"; refused 'unknown result kind' malformed-reference
bind --artifact "$T/closure" --signatures "$SIGS"
[ "$rc" = 2 ] || fail "references without --close exit $rc, want usage 2"

# spec: tools/objc-compat/binding.c header -- The real defective artifact: per-site closure of the six helper caches with the floor SDK's declared results.
if [ -n "${MAVERGREEN_OBJC_CODEX_ARTIFACT:-}" ]; then
  sum=$(shasum -a 256 "$MAVERGREEN_OBJC_CODEX_ARTIFACT" | cut -d' ' -f1)
  [ "$sum" = 1d056b0d4ada3d74b4c0f4c5450bc06856bfdbc504320fa430a4249f640f6c40 ] || fail "unexpected Codex artifact $sum"
  PREFIX=${MAVERGREEN_OBJC_CLANG_PREFIX:-}
  if [ -z "$PREFIX" ]; then
    case "$(uname -m)" in x86_64) short=clang22; flavor=native ;; arm64) short=clang22-cross; flavor=cross ;; *) exit 4 ;; esac
    version=$(tr -d '[:space:]' < "$ROOT/components/objc-reference-clang/version")
    PREFIX=$(sh "$ROOT/scripts/fetch_product_pkg.sh" --asset "mavericks-clang-22-$flavor-$version.pkg" "$short" "$version" "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/objc-reference-$short-$version")
  fi
  sh "$ROOT/scripts/objc-sdk-inventory.sh" --clang-prefix "$PREFIX" --sdk "$SDK" \
    --header "$SDK/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h" --signature-output "$T/floor-sigs" >"$T/floor-facts" 2>"$T/err" ||
    fail 'floor SDK signatures failed'
  SIGS="$T/floor-sigs" FACTS="$T/floor-facts"
  close_sends "$MAVERGREEN_OBJC_CODEX_ARTIFACT" --binding-receipt "$FX/codex-0.165.0-receipt.tsv"
  refused 'Codex 0.165.0 closure' unresolved-receiver
  ! grep -E '^error	(binding-receipt-conflict|receiver-receipt-conflict|receipt-on-shared-helper|unresolved-selector)	' "$T/out" >/dev/null ||
    fail 'Codex closure refused its receipt or a selector'
  [ "$(grep -c '^send	' "$T/out")" = 87 ] && [ "$(awk -F '\t' '$1 == "send" && $7 == "open"' "$T/out" | wc -l | tr -d ' ')" = 15 ] ||
    fail 'Codex send closure counts changed'
  # platform: the six helper caches, per send. 41 new and 42 init close (one class-cache send; no
  #           send at all); 46 closes through +[NSWorkspace sharedWorkspace]; 36 and 45 stay open; 47
  #           closes once and stays open once.
  [ "$(awk -F '\t' '$1 == "send" && $4 == "isKindOfClass:" && $7 == "open"' "$T/out" | wc -l | tr -d ' ')" = 3 ] || fail 'cache 36 changed'
  closed new NSDictionary + 1
  closed init - - 0
  opened description 'incoming argument 0 of'
  closed respondsToSelector: NSWorkspace - 2
  awk -F '\t' '$1 == "send" && $4 == "countByEnumeratingWithState:objects:count:" {print $7, $5}' "$T/out" | sort | tr '\n' ';' |
    grep -x 'closed NSArray;open -;' >/dev/null || fail 'cache 47 changed'
  opened isKindOfClass: 'is declared id by NSDictionary'
  opened isKindOfClass: 'not modelled'
  closed 'openURLs:withApplicationAtURL:options:configuration:error:' NSWorkspace - 1
  echo "objc-binding: real Codex 0.165.0 closure: $(awk -F '\t' '$1 == "send" && $7 == "closed"' "$T/out" | wc -l | tr -d ' ') closed, 15 open"
fi
echo 'objc-binding: v0 forms, byte-derived selectors, receipts, refusals and receiver closure pass'
