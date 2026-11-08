#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then reports on them
# spec: tools/objc-compat/main.m "The shipped closure" -- a non-system image the artifact loads is
#       found inside --root and measured by its interface: its classes and methods close the
#       artifact's sends into it, its own code stays exempt by its pinned bytes, and anything that
#       cannot be found exactly once inside the root, or is loaded weak, lazy or upward, is
#       cannot-measure.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
FX="$HERE/fixtures/objc-api"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-closure-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@" 2>>"$T/cc.log"; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
n=0
analyze() {
  n=$((n + 1)); rep="$T/report.$n"
  rc=0; sh "$ROOT/scripts/objc-compat.sh" --artifact "$2" --root "$1" --references "$REF" --report "$rep" --mode strict 2>"$T/err" || rc=$?
  ln -sf "$rep" "$T/report"
}
exit_is() { [ "$rc" = "$1" ] || fail "$2: exit $rc, want $1"; }
error_is() { grep "\"code\": \"$1\"" "$T/report" >/dev/null || fail "$2: no $1 error"; }
finding() { grep "\"function\": \"$1\"" "$T/report" | grep "\"selector\": \"$2\""; }
want() {   # want FUNCTION SELECTOR VERDICT IMAGE [PROOF-FRAGMENT]
  f=$(finding "$1" "$2") || fail "$1 $2: no finding"
  printf '%s\n' "$f" | grep -F "\"verdict\": \"$3\"" >/dev/null || fail "$1 $2: want $3: $f"
  if [ "$4" = - ]; then printf '%s\n' "$f" | grep -F '"image": null' >/dev/null || fail "$1 $2: want no image: $f"
  else printf '%s\n' "$f" | grep -F "\"image\": \"$4\"" >/dev/null || fail "$1 $2: want image $4: $f"; fi
  [ -z "${5:-}" ] || printf '%s\n' "$f" | grep -F -- "$5" >/dev/null || fail "$1 $2: proof lacks '$5': $f"
}

bundle() {
  d=$1; shift
  ff=; while [ "$#" -gt 0 ] && [ "$1" != -- ]; do ff="$ff $1"; shift; done
  [ "$#" -gt 0 ] && shift
  fw="$d/App.app/Contents/Frameworks/MGShipped.framework"
  mkdir -p "$fw/Versions/A" "$d/App.app/Contents/MacOS"
  ln -s A "$fw/Versions/Current"; ln -s Versions/Current/MGShipped "$fw/MGShipped"
  cc -dynamiclib "$FX/shipped-inner.m" -framework Foundation -install_name @loader_path/libMGInner.dylib -o "$fw/Versions/A/libMGInner.dylib" ||
    fail 'inner dylib did not build'
  # shellcheck disable=SC2086  # ff is a flag list
  cc -dynamiclib -DMG_INNER $ff "$FX/shipped-framework.m" -framework Foundation "$fw/Versions/A/libMGInner.dylib" \
    -install_name @rpath/MGShipped.framework/Versions/A/MGShipped -o "$fw/Versions/A/MGShipped" || fail 'framework did not build'
  cc -DMG_INNER "$FX/shipped-app.m" -framework Foundation -F"$d/App.app/Contents/Frameworks" "$@" -o "$d/App.app/Contents/MacOS/App" ||
    fail 'app did not build'
}
FWREL=App.app/Contents/Frameworks/MGShipped.framework/Versions/A/MGShipped
INREL=App.app/Contents/Frameworks/MGShipped.framework/Versions/A/libMGInner.dylib

# spec: tools/objc-compat/main.m "The shipped closure" -- @rpath and @loader_path resolve inside the root; the
#       artifact's sends into the framework close against the framework's own implementations.
bundle "$T/ok" -- -framework MGShipped -Wl,-rpath,@executable_path/../Frameworks
APP="$T/ok/App.app/Contents/MacOS/App"
analyze "$T/ok" "$APP"
exit_is 1 'shipped closure strict'
grep -F '"complete_within_boundary": true,' "$T/report" >/dev/null || fail "the shipped closure was not measured: $(grep '"code"' "$T/report")"
want _shipped_class sharedShipped floor-supported "$FWREL" "implemented by shipped image $FWREL's own +MGShipped"
want _shipped_missing notShipped unsupported -
want _shipped_inherited description floor-supported - 'floor'
want _shipped_category mgShippedHello floor-supported "$FWREL" "implemented by shipped image $FWREL on floor class NSObject (a category)"
want _inner_inherited innerThing floor-supported "$INREL" "implemented by shipped image $INREL's own +MGInner"
# spec: tools/objc-compat/main.m "The shipped closure" -- a finding closed in a shipped image names it in its id.
finding _shipped_class sharedShipped | grep -F "\"id\": \"x86_64@0x" | grep -F ":+[MGShipped sharedShipped]@$FWREL\"" >/dev/null ||
  fail "the framework's finding id is not image-qualified: $(finding _shipped_class sharedShipped)"
finding _shipped_missing notShipped | grep -F ':+[MGShipped notShipped]", ' >/dev/null || fail 'a finding closed nowhere gained an image in its id'
# spec: tools/objc-compat/main.m "The shipped closure" -- every image is hashed into the report, and each one's
#       own code is listed as exempt by those bytes.
for p in "$FWREL" "$INREL"; do
  s=$(sha "$T/ok/$p")
  grep -F "{\"path\": \"$p\", \"sha256\": \"$s\"" "$T/report" >/dev/null || fail "shipped image $p is not hashed into the report"
  grep -F "\"shipped image $p (sha256 $s) is measured by its interface" "$T/report" >/dev/null || fail "the exemption of $p is not a stated limit"
done
grep -F "{\"path\": \"$INREL\", \"sha256\": \"$(sha "$T/ok/$INREL")\", \"slices\": [\"x86_64\"], \"loaded_by\": \"$FWREL\", \"load\": \"load\", \"install_name\": \"@loader_path/libMGInner.dylib\"" \
  "$T/report" >/dev/null || fail "libMGInner.dylib's artifact entry does not say what loads it"
# spec: tools/objc-compat/classify.c header -- R1 counts the shipped images' classes, and their system
#       dependencies must be captured.
grep -F '"closure_class_roots": {"defined_classes": 4, "roots": {"NSObject": 4, "NSProxy": 0}, "runtime_class_creation_sites": 0, "uncaptured_dependencies": [], "blocking": [], "r1_unknown_receivers": true}' \
  "$T/report" >/dev/null || fail "the shipped classes are not in the class roots: $(grep -o '"closure_class_roots": {[^}]*}[^}]*}' "$T/report")"

# spec: tools/objc-compat/main.m "The shipped closure" -- a report of one image is unchanged: no image key,
#       no shipped images, the old limit.
mkdir -p "$T/one/bin"
cc "$FX/classify.c" -o "$T/one/bin/app" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_fixture_use || fail 'single-image fixture did not build'
analyze "$T/one" "$T/one/bin/app"
! grep -F '"image": ' "$T/report" >/dev/null && ! grep -F '"shipped_images"' "$T/report" >/dev/null || fail 'a single-image report changed shape'
grep -F '"the shipped closure is the artifact alone: a non-system dependency is cannot-measure"' "$T/report" >/dev/null ||
  fail 'a single-image report lost its limit'

# spec: tools/objc-compat/main.m "The shipped closure" -- missing, ambiguous, escaping, weak and duplicate-class closures are cannot-measure.
bundle "$T/missing" -- -framework MGShipped -Wl,-rpath,@executable_path/../Frameworks
rm "$T/missing/$INREL"
analyze "$T/missing" "$T/missing/App.app/Contents/MacOS/App"
exit_is 4 'a missing shipped dependency'; error_is missing-dependency 'a missing shipped dependency'
bundle "$T/two" -- -framework MGShipped -Wl,-rpath,@executable_path/../Frameworks -Wl,-rpath,@executable_path/../Alt
cp -R "$T/two/App.app/Contents/Frameworks" "$T/two/App.app/Contents/Alt"
analyze "$T/two" "$T/two/App.app/Contents/MacOS/App"
exit_is 4 'a dependency found twice'; error_is ambiguous-dependency 'a dependency found twice'
bundle "$T/esc" -- -framework MGShipped -Wl,-rpath,@executable_path/../../../../outside
mkdir -p "$T/esc/outside"; mv "$T/esc/App.app/Contents/Frameworks/MGShipped.framework" "$T/esc/outside/"
mkdir -p "$T/esc/root"; mv "$T/esc/App.app" "$T/esc/root/"
analyze "$T/esc/root" "$T/esc/root/App.app/Contents/MacOS/App"
exit_is 4 'a dependency outside the root'; error_is escaping-dependency 'a dependency outside the root'
bundle "$T/abs" -- -framework MGShipped -Wl,-rpath,/Library/Frameworks
analyze "$T/abs" "$T/abs/App.app/Contents/MacOS/App"
exit_is 4 'an absolute non-system run path'; error_is escaping-dependency 'an absolute non-system run path'
bundle "$T/weak" -- -weak_framework MGShipped -Wl,-rpath,@executable_path/../Frameworks
analyze "$T/weak" "$T/weak/App.app/Contents/MacOS/App"
exit_is 4 'a weakly loaded shipped dependency'; error_is unsupported-dependency 'a weakly loaded shipped dependency'
grep -F '(weak)' "$T/report" >/dev/null || fail 'the weak load is not named'
bundle "$T/dup" -DMG_DUPLICATE -- -framework MGShipped -Wl,-rpath,@executable_path/../Frameworks
analyze "$T/dup" "$T/dup/App.app/Contents/MacOS/App"
exit_is 4 'a class defined twice in the closure'; error_is ambiguous-class 'a class defined twice in the closure'
echo "objc-closure: shipped images by interface, image-qualified findings, unchanged single-image reports and every refusal pass"
