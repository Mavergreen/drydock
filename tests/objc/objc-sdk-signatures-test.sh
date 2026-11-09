#!/bin/sh
# platform: macOS-only -- compiles and runs a real host libclang semantic reader against pinned SDKs
# spec: tools/objc-sdk-inventory.c header -- the --signature-output companion records each method's
#       declared result as class/instancetype/id/other/unknown from libclang types, never from the
#       ABI encoding, without changing the eleven fact columns; output is exclusive and atomic.
# spec: tools/objc-sdk-inventory.c header -- schema 2 adds each declaration's parameter GPRs (SysV x86_64,
#       "-" when unclassifiable) and variadic; --function-output catalogs C prototypes the same way, plus noreturn.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-signatures-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
NEW_SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch arm64)
PREFIX=${MAVERGREEN_OBJC_CLANG_PREFIX:-}
if [ -z "$PREFIX" ]; then
  case "$(uname -m)" in x86_64) short=clang22; flavor=native ;; arm64) short=clang22-cross; flavor=cross ;; *) exit 4 ;; esac
  version=$(tr -d '[:space:]' < "$ROOT/components/objc-reference-clang/version")
  PREFIX=$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "mavericks-clang-22-$flavor-$version.pkg" "$short" "$version" "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/objc-reference-$short-$version")
fi
MAVERICKS_BUILD_ROOT="$T/build"; export MAVERICKS_BUILD_ROOT
. "$HERE/lib/objc_staged_scripts.sh"
WRAPPER="$(stage_objc_scripts "$T/staged")/objc-sdk-inventory.sh"
FX="$HERE/fixtures/signatures.h"
printf '@interface Broken\nthis is not valid;\n' >"$T/broken.h"
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -15 "$T/err" >&2; exit 1; }
run() { rc=0; sh "$WRAPPER" --clang-prefix "$PREFIX" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
# spec: tools/objc-sdk-inventory.c header -- Signature row: 1 record 2 owner 3 kind 4 selector 5 result kind 6 result class 7 source 8 container 9 gprs 10 variadic.
sig() {
  awk -F '\t' -v r="$1" -v o="$2" -v k="$3" -v s="$4" -v rk="$5" -v rc="$6" '
    $1==r && $2==o && $3==k && $4==s && $5==rk && $6==rc {found=1} END {exit !found}' "$T/sig" ||
    fail "missing signature: $*"
}

run --sdk "$SDK" --header "$FX"
[ "$rc" = 0 ] || fail "facts without the companion exit $rc"
cp "$T/out" "$T/facts-only"
run --sdk "$SDK" --header "$FX" --signature-output "$T/sig"
[ "$rc" = 0 ] || fail "companion run exits $rc"
cmp -s "$T/out" "$T/facts-only" || fail 'the companion changed the eleven-column facts'
[ "$(head -1 "$T/sig")" = '# objc-signatures 2' ] || fail 'missing schema-2 header'
tail -n +2 "$T/sig" | awk -F '\t' 'NF!=10 {exit 1}' || fail 'ambiguous signature field count'

sig method Root + make instancetype -
sig method Root - initPlain instancetype -
sig method Root + sharedRoot class Root
sig method Root - anything id -
sig method Root - qualifiedAnything id -
sig method Root - qualifiedRoot class Root
sig method Root - scalar other -
sig method Root - classValue other -
sig method Root - nothing other -
sig method Root - aliased class Root
sig method Root - aliasedAnything id -
sig method Root - forwardLeaf class Leaf
sig property-get Root - child class Root
sig property-get Root + defaultRoot class Root
sig method Leaf - initLeaf instancetype -
sig protocol-method Copying - copyThing id -
awk -F '\t' '$2=="Root" && $4=="aliased" && $7=="input/1:25" && $8=="category:Aliases" {ok=1} END {exit !ok}' "$T/sig" ||
  fail 'signature source/container evidence lost'
awk -F '\t' '$2=="Root" && $4=="scalar" && $9=="0" && $10=="0" {ok=1} END {exit !ok}' "$T/sig" ||
  fail 'a method without parameters must take 0 GPRs and not be variadic'
tail -n +2 "$T/sig" >"$T/sig.body"
LC_ALL=C sort -u "$T/sig.body" | cmp -s - "$T/sig.body" || fail 'signatures are not sorted and deduplicated'
cp "$T/sig" "$T/first"
rm "$T/sig"
run --sdk "$SDK" --header "$FX" --signature-output "$T/sig"
cmp -s "$T/sig" "$T/first" || fail 'signatures vary across identical invocations'

# spec: tools/objc-sdk-inventory.c header -- Exact parameter facts: an aggregate of 16 bytes or less takes one
#       GPR per INTEGER eightbyte, one over 16 bytes is in memory (0), floating point takes none, and a union,
#       bitfield or long double is "-". The function catalog is deduplicated by name; disagreeing prototypes
#       (an unprototyped redeclaration) give "-".
CAT="$HERE/fixtures/catalog.h"
run --sdk "$SDK" --header "$CAT"
[ "$rc" = 0 ] || fail "catalog facts exit $rc"
cp "$T/out" "$T/catalog-facts"
run --sdk "$SDK" --header "$CAT" --signature-output "$T/csig" --function-output "$T/fn"
[ "$rc" = 0 ] || fail "catalog companion run exits $rc"
cmp -s "$T/out" "$T/catalog-facts" || fail 'the function catalog changed the eleven-column facts'
row() { grep -Fx "$(printf "$1")" "$T/csig" >/dev/null || fail "missing exact signature row: $1"; }
row 'method\tProbe\t-\tr:\tother\t-\tinput/1:47\tinterface\t2\t0'
row 'method\tProbe\t-\td:\tother\t-\tinput/1:48\tinterface\t0\t0'
row 'method\tProbe\t-\tf:\tid\t-\tinput/1:49\tinterface\t1\t1'
row 'method\tProbe\t-\tpoint:\tother\t-\tinput/1:50\tinterface\t0\t0'
row 'method\tProbe\t-\ttriple:\tother\t-\tinput/1:51\tinterface\t0\t0'
row 'method\tProbe\t-\tmixed:\tother\t-\tinput/1:52\tinterface\t1\t0'
row 'method\tProbe\t-\teither:\tother\t-\tinput/1:53\tinterface\t-\t0'
row 'method\tProbe\t-\tbits:\tother\t-\tinput/1:54\tinterface\t-\t0'
row 'method\tProbe\t-\twide:\tother\t-\tinput/1:55\tinterface\t-\t0'
row 'method\tProbe\t-\to:at:count:flag:\tother\t-\tinput/1:56\tinterface\t5\t0'
row 'property-get\tProbe\t-\tprobeReading\tother\t-\tinput/1:57\tinterface\t0\t0'
row 'method\tOldBase\t-\tscalar:\tother\t-\tinput/1:6\tinterface\t1\t0'
printf '# objc-functions 1\n' >"$T/fn.want"
printf 'dd_c11\t1\t0\t1\tinput/1:62\n' >>"$T/fn.want"
printf 'dd_fatal\t2\t0\t1\tinput/1:60\n' >>"$T/fn.want"
printf 'dd_log\t1\t1\t0\tinput/1:63\n' >>"$T/fn.want"
printf 'dd_none\t0\t0\t0\tinput/1:67\n' >>"$T/fn.want"
printf 'dd_round\t0\t0\t0\tinput/1:66\n' >>"$T/fn.want"
printf 'dd_twice\t-\t0\t0\tinput/1:64\n' >>"$T/fn.want"
cmp -s "$T/fn" "$T/fn.want" || { diff "$T/fn.want" "$T/fn" >&2 || :; fail 'function catalog is not exactly the fixture prototypes'; }
cp "$T/fn" "$T/fn.first"; rm "$T/fn" "$T/csig"
run --sdk "$SDK" --header "$CAT" --function-output "$T/fn"
[ "$rc" = 0 ] && cmp -s "$T/fn" "$T/fn.first" && [ ! -e "$T/csig" ] || fail 'the function catalog alone differs or failed'
printf 'keep\n' >"$T/fn-existing"
run --sdk "$SDK" --header "$CAT" --function-output "$T/fn-existing"
[ "$rc" = 4 ] && [ ! -s "$T/out" ] && [ "$(cat "$T/fn-existing")" = keep ] || fail "existing function destination: exit $rc or overwritten"
ln -s "$T/fn-elsewhere" "$T/fn-dangling"
run --sdk "$SDK" --header "$CAT" --function-output "$T/fn-dangling"
[ "$rc" = 4 ] && [ ! -e "$T/fn-elsewhere" ] || fail 'a symlinked function destination was followed'
run --sdk "$SDK" --header "$CAT" --header "$T/broken.h" --function-output "$T/fn-partial" --signature-output "$T/sig-partial"
[ "$rc" = 4 ] && [ ! -e "$T/fn-partial" ] && [ ! -e "$T/sig-partial" ] && [ ! -s "$T/out" ] || fail 'failed parse left a partial function catalog'
[ -z "$(ls "$T" | grep -e '^fn-partial' -e '^sig-partial')" ] || fail 'failed parse left a function temporary'
run --sdk "$SDK" --header "$CAT" --function-output
[ "$rc" = 2 ] || fail "missing function destination exit $rc, want 2"
run --sdk "$SDK" --header "$CAT" --function-output "$T/fa" --function-output "$T/fb"
[ "$rc" = 2 ] || fail "repeated function destination exit $rc, want 2"

# spec: tools/objc-sdk-inventory.c header -- Exclusive and atomic: an existing destination is refused untouched, and a failed parse leaves no file.
printf 'keep\n' >"$T/existing"
run --sdk "$SDK" --header "$FX" --signature-output "$T/existing"
[ "$rc" = 4 ] && [ ! -s "$T/out" ] && [ "$(cat "$T/existing")" = keep ] || fail "existing destination: exit $rc or overwritten"
ln -s "$T/elsewhere" "$T/dangling"
run --sdk "$SDK" --header "$FX" --signature-output "$T/dangling"
[ "$rc" = 4 ] && [ ! -e "$T/elsewhere" ] || fail 'a symlinked destination was followed'
run --sdk "$SDK" --header "$FX" --header "$T/broken.h" --signature-output "$T/partial"
[ "$rc" = 4 ] && [ ! -e "$T/partial" ] && [ ! -s "$T/out" ] || fail 'failed parse left partial signatures'
[ -z "$(ls "$T" | grep '^partial')" ] || fail 'failed parse left a temporary'
run --sdk "$SDK" --header "$FX" --signature-output
[ "$rc" = 2 ] || fail "missing destination exit $rc, want 2"
run --sdk "$SDK" --header "$FX" --signature-output "$T/a" --signature-output "$T/b"
[ "$rc" = 2 ] || fail "repeated destination exit $rc, want 2"

# spec: tools/objc-sdk-inventory.c header -- Real floor and newer SDK results that receiver closure consumes.
rm "$T/sig"
run --sdk "$SDK" --header "$SDK/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h" --signature-output "$T/sig" --function-output "$T/floor-fn"
[ "$rc" = 0 ] || fail "floor SDK failed ($rc)"
fn() {
  awk -F '\t' -v f="$1" -v g="$2" -v v="$3" -v n="$4" 'NR>1 && $1==f && $2==g && $3==v && $4==n && NF==5 {found=1} END {exit !found}' "$T/floor-fn" ||
    fail "missing floor function: $*"
}
[ "$(head -1 "$T/floor-fn")" = '# objc-functions 1' ] || fail 'missing functions schema-1 header'
fn NSLog 1 1 0
fn NSBeep 0 0 0
fn lround 0 0 0
fn __assert_rtn 4 0 1
fn abort 0 0 1
sig method NSTextView - setSelectedRange: other -
awk -F '\t' '$2=="NSTextView" && $4=="setSelectedRange:" && $9=="2" && $10=="0" {ok=1} END {exit !ok}' "$T/sig" ||
  fail 'NSRange parameter is not 2 GPRs on the floor SDK'
awk -F '\t' '$2=="NSString" && $4=="stringWithFormat:" && $10=="1" {ok=1} END {exit !ok}' "$T/sig" ||
  fail 'stringWithFormat: is not variadic on the floor SDK'
sig method NSWorkspace + sharedWorkspace class NSWorkspace
sig method NSPasteboard - pasteboardItems class NSArray
sig method NSPasteboard + generalPasteboard class NSPasteboard
sig method NSPropertyListSerialization + propertyListWithData:options:format:error: id -
sig method NSDictionary - objectForKey: id -
# platform: the 10.9 SDK declares +new/+alloc as returning id; the related-result-type rule is the
#           compiler's inference, not a declaration, and the companion reports only declarations.
sig method NSObject + new id -
sig method NSObject + alloc id -
rm "$T/sig"
run --sdk "$NEW_SDK" --header "$NEW_SDK/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h" --signature-output "$T/sig"
[ "$rc" = 0 ] || fail "new SDK failed ($rc)"
sig property-get NSWorkspace + sharedWorkspace class NSWorkspace
sig property-get NSPasteboard - pasteboardItems class NSArray
sig method NSObject + new instancetype -
echo 'objc-sdk-signatures: typed/instancetype/id/alias results, parameter GPRs, C prototypes, atomic output and real SDKs pass'
