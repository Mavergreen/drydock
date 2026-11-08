#!/bin/sh
# platform: macOS-only -- compiles and runs a real host libclang semantic reader against pinned SDKs
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-inventory-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch x86_64)
NEW_SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch arm64)
PREFIX=${MAVERGREEN_OBJC_CLANG_PREFIX:-}
if [ -z "$PREFIX" ]; then
  case "$(uname -m)" in x86_64) short=clang22; flavor=native ;; arm64) short=clang22-cross; flavor=cross ;; *) exit 4 ;; esac
  version=$(tr -d '[:space:]' < "$ROOT/components/objc-reference-clang/version")
  PREFIX=$(sh "$ROOT/scripts/fetch_product_pkg.sh" --asset "mavericks-clang-22-$flavor-$version.pkg" "$short" "$version" "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/objc-reference-$short-$version")
fi
MAVERICKS_BUILD_ROOT="$T/build"; export MAVERICKS_BUILD_ROOT
WRAPPER="$ROOT/scripts/objc-sdk-inventory.sh"
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -15 "$T/err" >&2; exit 1; }
run() { rc=0; sh "$WRAPPER" --clang-prefix "$PREFIX" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
has() {
  awk -F '\t' -v r="$1" -v o="$2" -v k="$3" -v n="$4" -v enc="$5" -v intro="$6" -v dep="$7" -v unavail="$8" '
    $1==r && $3==o && $4==k && $5==n && (enc=="*" || $6==enc) &&
    (intro=="*" || $7==intro) && (dep=="*" || $8==dep) && $9==unavail {found=1}
    END {exit !found}' "$T/out" || fail "missing fact: $*"
}
run --sdk "$SDK" --header "$HERE/fixtures/objc-api/catalog.h"
[ "$rc" = 0 ] || fail "semantic extraction exits $rc"
awk -F '\t' 'NF!=11 {exit 1}' "$T/out" || fail 'ambiguous TSV field count'
has class OldBase - - - 10.0 - 0
has class LaterClass - OldBase - 10.10 - 0
has method OldBase + sharedName 'q16@0:8' 10.0 - 0
has method OldBase - sharedName 'q16@0:8' 10.0 - 0
has method OldBase - oldMethod 'v16@0:8' 10.0 - 0
has method OldBase - scalar: 'q24@0:8q16' 10.0 - 0
has method OldBase - futureMethod 'v16@0:8' 10.12 - 0
has method OldBase - deprecatedMethod 'v16@0:8' 10.1 10.8 0
has method OldBase - unavailableMethod 'v16@0:8' 10.0 - 1
has category OldBase - Extras - 10.0 - 0
has property-get LaterClass - reading - 10.10 - 0
has property-get LaterClass - currentValue - 10.10 - 0
has property-set LaterClass - updateValue: - 10.10 - 0
has protocol-method ProbeProtocol - maybe 'v16@0:8' - - 0
has protocol-property-get ChildProtocol - protocolReading - - - 0
has protocol-inherits ChildProtocol - ParentProtocol - - - 0
awk -F '\t' '$1=="protocol-method" && $3=="ProbeProtocol" && $5=="maybe" && $11=="protocol:optional" {optional=1} $1=="protocol-method" && $3=="ParentProtocol" && $5=="requiredMethod" && $11=="protocol:required" {required=1} END {exit !(optional && required)}' "$T/out" || fail 'protocol optionality erased'
has conformance Adopter - ProbeProtocol - - - 0
awk -F '\t' '($1=="class" && $3=="ForwardOnly") || ($1=="protocol" && $3=="ForwardProtocol") || ($1=="method" && $3=="LaterClass" && $5=="oldMethod") || ($1=="property-set" && $5=="setReading:") {bad=1} END {exit bad}' "$T/out" || fail 'forward declaration, inherited method or readonly setter invented'
awk -F '\t' '$1=="method" && $3=="OldBase" && $5=="futureMethod" && $10=="input/1:16" && $11=="category:Extras" {ok=1} END {exit !ok}' "$T/out" || fail 'category/source evidence lost'
! grep -F "$HOME" "$T/out" >/dev/null || fail 'host paths leaked into facts'
LC_ALL=C sort -u "$T/out" >"$T/sorted"
cmp -s "$T/out" "$T/sorted" || fail 'facts are not sorted and deduplicated'
cp "$T/out" "$T/first"
run --sdk "$SDK" --header "$HERE/fixtures/objc-api/catalog.h"
cmp -s "$T/out" "$T/first" || fail 'facts vary across identical invocations'

ln -s "$PREFIX" "$T/compiler prefix"
cp "$HERE/fixtures/objc-api/catalog.h" "$T/header with spaces.h"
PREFIX="$T/compiler prefix"
run --sdk "$SDK" --header "$T/header with spaces.h"
[ "$rc" = 0 ] && cmp -s "$T/out" "$T/first" || fail 'whitespace paths change facts or fail'

expect_failure() { want=$1; shift; run "$@"; [ "$rc" = "$want" ] && [ ! -s "$T/out" ] || fail "expected exit $want and no partial facts, got $rc"; }
expect_failure 2 --unknown
expect_failure 2 --sdk
expect_failure 2 --sdk "$SDK"
expect_failure 4 --sdk "$T/missing" --header "$T/header with spaces.h"
expect_failure 4 --sdk "$T" --header "$T/header with spaces.h"
expect_failure 4 --sdk "$SDK" --header "$T/missing.h"
printf '@interface Broken\nthis is not valid;\n' >"$T/broken.h"
expect_failure 4 --sdk "$SDK" --header "$T/header with spaces.h" --header "$T/broken.h"
printf 'typedef int not_an_objc_api;\n' >"$T/empty.h"
run --sdk "$SDK" --header "$T/empty.h"
[ "$rc" = 0 ] && [ ! -s "$T/out" ] || fail 'valid empty input treated as failure or invented facts'

case "$(uname -m)" in x86_64) host_sdk=$SDK; host_floor=10.9 ;; arm64) host_sdk=$NEW_SDK; host_floor=11.0 ;; esac
/usr/bin/clang -std=c99 -arch "$(uname -m)" -isysroot "$host_sdk" -mmacosx-version-min="$host_floor" \
  -I"$PREFIX/include" "$ROOT/tools/objc-sdk-inventory.c" -L"$PREFIX/lib" \
  -Xlinker -rpath -Xlinker "$PREFIX/lib" -lclang -o "$T/producer"
producer_failure() {
  want=$1; shift; rc=0
  "$T/producer" "$@" >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" = "$want" ] && [ ! -s "$T/out" ] || fail "direct producer: expected exit $want and no facts, got $rc"
}
producer_failure 2 --unknown value
producer_failure 2 --sdk "$SDK" --header "$T/empty.h"
producer_failure 4 --sdk "$SDK" --resource-dir "$T" --header "$T/empty.h"

mkdir "$T/poison"
printf '#error ambient include path must not influence a pinned SDK measurement\n' >"$T/poison/stddef.h"
printf '#include <stddef.h>\n' >"$T/ambient.h"
CPATH="$T/poison"; export CPATH
run --sdk "$SDK" --header "$T/ambient.h"
unset CPATH
[ "$rc" = 0 ] && [ ! -s "$T/out" ] || fail 'ambient include paths changed the host build or SDK measurement'
resource=$("$PREFIX/bin/clang" -print-resource-dir)
CPATH="$T/poison" "$T/producer" --sdk "$SDK" --resource-dir "$resource" --header "$T/ambient.h" >"$T/out" 2>"$T/err" || fail 'direct producer inherited ambient includes'
[ ! -s "$T/out" ] || fail 'direct producer invented ObjC facts in a plain C header'

run --sdk "$NEW_SDK" --header "$NEW_SDK/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h"
[ "$rc" = 0 ] || fail "new SDK failed ($rc)"
has method NSWorkspace - openURLs:withApplicationAtURL:options:configuration:error: '@56@0:8@16@24Q32@40^@48' 10.10 '*' 0
run --sdk "$SDK" --header "$SDK/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h"
[ "$rc" = 0 ] || fail "floor SDK failed ($rc)"
! grep -F 'openURLs:withApplicationAtURL:options:configuration:error:' "$T/out" >/dev/null || fail 'new launch method appears in floor catalog'
has method NSString - initWithBytes:length:encoding: '*' '*' - 0

mkdir -p "$T/bad-resource/bin"
ln -s "$PREFIX/include" "$T/bad-resource/include"
ln -s "$PREFIX/lib" "$T/bad-resource/lib"
printf '#!/bin/sh\nprintf "%%s\\n" /no/such/resource-directory\n' >"$T/bad-resource/bin/clang"
chmod +x "$T/bad-resource/bin/clang"
PREFIX="$T/bad-resource"
expect_failure 4 --sdk "$SDK" --header "$T/empty.h"
PREFIX="$T/no compiler"
expect_failure 4 --sdk "$SDK" --header "$T/empty.h"
echo 'objc-sdk-inventory: semantic fixtures, failures, path isolation and real SDKs pass'
