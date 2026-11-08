#!/bin/sh
# platform: macOS-only -- compiles and runs a real host libclang semantic reader against pinned SDKs
# spec: tools/objc-sdk-inventory.c header -- the --signature-output companion records each method's
#       declared result as class/instancetype/id/other/unknown from libclang types, never from the
#       ABI encoding, without changing the eleven fact columns; output is exclusive and atomic.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-signatures-test.XXXXXX")
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
FX="$HERE/fixtures/objc-api/signatures.h"
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -15 "$T/err" >&2; exit 1; }
run() { rc=0; sh "$WRAPPER" --clang-prefix "$PREFIX" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
# spec: tools/objc-sdk-inventory.c header -- Signature row: 1 record 2 owner 3 kind 4 selector 5 result kind 6 result class 7 source 8 container.
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
[ "$(head -1 "$T/sig")" = '# objc-signatures 1' ] || fail 'missing schema-1 header'
tail -n +2 "$T/sig" | awk -F '\t' 'NF!=8 {exit 1}' || fail 'ambiguous signature field count'

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
tail -n +2 "$T/sig" >"$T/sig.body"
LC_ALL=C sort -u "$T/sig.body" | cmp -s - "$T/sig.body" || fail 'signatures are not sorted and deduplicated'
cp "$T/sig" "$T/first"
rm "$T/sig"
run --sdk "$SDK" --header "$FX" --signature-output "$T/sig"
cmp -s "$T/sig" "$T/first" || fail 'signatures vary across identical invocations'

# spec: tools/objc-sdk-inventory.c header -- Exclusive and atomic: an existing destination is refused untouched, and a failed parse leaves no file.
printf 'keep\n' >"$T/existing"
run --sdk "$SDK" --header "$FX" --signature-output "$T/existing"
[ "$rc" = 4 ] && [ ! -s "$T/out" ] && [ "$(cat "$T/existing")" = keep ] || fail "existing destination: exit $rc or overwritten"
ln -s "$T/elsewhere" "$T/dangling"
run --sdk "$SDK" --header "$FX" --signature-output "$T/dangling"
[ "$rc" = 4 ] && [ ! -e "$T/elsewhere" ] || fail 'a symlinked destination was followed'
printf '@interface Broken\nthis is not valid;\n' >"$T/broken.h"
run --sdk "$SDK" --header "$FX" --header "$T/broken.h" --signature-output "$T/partial"
[ "$rc" = 4 ] && [ ! -e "$T/partial" ] && [ ! -s "$T/out" ] || fail 'failed parse left partial signatures'
[ -z "$(ls "$T" | grep '^partial')" ] || fail 'failed parse left a temporary'
run --sdk "$SDK" --header "$FX" --signature-output
[ "$rc" = 2 ] || fail "missing destination exit $rc, want 2"
run --sdk "$SDK" --header "$FX" --signature-output "$T/a" --signature-output "$T/b"
[ "$rc" = 2 ] || fail "repeated destination exit $rc, want 2"

# spec: tools/objc-sdk-inventory.c header -- Real floor and newer SDK results that receiver closure consumes.
rm "$T/sig"
run --sdk "$SDK" --header "$SDK/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h" --signature-output "$T/sig"
[ "$rc" = 0 ] || fail "floor SDK failed ($rc)"
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
echo 'objc-sdk-signatures: typed/instancetype/id/alias results, atomic output and real SDKs pass'
