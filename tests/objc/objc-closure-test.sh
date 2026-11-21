#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then reports on them
# spec: src/objc/main.m "The shipped closure" -- a non-system image the artifact loads is
#       found inside --root and measured by its interface: its classes and methods close the
#       artifact's sends into it, its own code stays exempt by its pinned bytes, and anything that
#       cannot be found exactly once inside the root, or is loaded weak, lazy or upward, is
#       cannot-measure.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
. "$ROOT/tests/lib/toolchain.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-closure-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
fxcc() { env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@" 2>>"$T/cc.log"; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
n=0
analyze() {   # analyze ROOT ARTIFACT [OPTION VALUE]...
  n=$((n + 1)); rep="$T/report.$n"; r=$1; art=$2; shift 2
  rc=0; "$DRYDOCK_OBJC" analyze --artifact "$art" --root "$r" --references "$REF" --report "$rep" --mode strict "$@" 2>"$T/err" || rc=$?
  ln -sf "$rep" "$T/report"
}
analyze_vol() { r=$1; art=$2; shift 2; analyze "$r" "$art" --root-kind volume "$@"; }
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
  fxcc -dynamiclib "$FX/shipped-inner.m" -framework Foundation -install_name @loader_path/libMGInner.dylib -o "$fw/Versions/A/libMGInner.dylib" ||
    fail 'inner dylib did not build'
  # shellcheck disable=SC2086  # ff is a flag list
  fxcc -dynamiclib -DMG_INNER $ff "$FX/shipped-framework.m" -framework Foundation "$fw/Versions/A/libMGInner.dylib" \
    -install_name @rpath/MGShipped.framework/Versions/A/MGShipped -o "$fw/Versions/A/MGShipped" || fail 'framework did not build'
  fxcc -DMG_INNER "$FX/shipped-app.m" -framework Foundation -F"$d/App.app/Contents/Frameworks" "$@" -o "$d/App.app/Contents/MacOS/App" ||
    fail 'app did not build'
}
FWREL=App.app/Contents/Frameworks/MGShipped.framework/Versions/A/MGShipped
INREL=App.app/Contents/Frameworks/MGShipped.framework/Versions/A/libMGInner.dylib

# spec: src/objc/main.m "The shipped closure" -- @rpath and @loader_path resolve inside the root; the
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
# spec: src/objc/main.m "The shipped closure" -- a finding closed in a shipped image names it in its id.
finding _shipped_class sharedShipped | grep -F "\"id\": \"x86_64@0x" | grep -F ":+[MGShipped sharedShipped]@$FWREL\"" >/dev/null ||
  fail "the framework's finding id is not image-qualified: $(finding _shipped_class sharedShipped)"
finding _shipped_missing notShipped | grep -F ':+[MGShipped notShipped]", ' >/dev/null || fail 'a finding closed nowhere gained an image in its id'
# spec: src/objc/main.m "The shipped closure" -- every image is hashed into the report, and each one's
#       own code is listed as exempt by those bytes.
for p in "$FWREL" "$INREL"; do
  s=$(sha "$T/ok/$p")
  grep -F "{\"path\": \"$p\", \"sha256\": \"$s\"" "$T/report" >/dev/null || fail "shipped image $p is not hashed into the report"
  grep -F "\"shipped image $p (sha256 $s) is measured by its interface" "$T/report" >/dev/null || fail "the exemption of $p is not a stated limit"
done
grep -F "{\"path\": \"$INREL\", \"sha256\": \"$(sha "$T/ok/$INREL")\", \"slices\": [\"x86_64\"], \"loaded_by\": \"$FWREL\", \"load\": \"load\", \"install_name\": \"@loader_path/libMGInner.dylib\"" \
  "$T/report" >/dev/null || fail "libMGInner.dylib's artifact entry does not say what loads it"
# spec: src/objc/classify.c header -- R1 counts the shipped images' classes, and their system
#       dependencies must be captured.
grep -F '"closure_class_roots": {"defined_classes": 4, "roots": {"NSObject": 4, "NSProxy": 0}, "runtime_class_creation_sites": 0, "uncaptured_dependencies": [], "blocking": [], "r1_unknown_receivers": true}' \
  "$T/report" >/dev/null || fail "the shipped classes are not in the class roots: $(grep -o '"closure_class_roots": {[^}]*}[^}]*}' "$T/report")"

# spec: src/objc/main.m "The shipped closure" -- a report of one image is unchanged: no image key,
#       no shipped images, the old limit.
mkdir -p "$T/one/bin"
fxcc "$FX/classify.c" -o "$T/one/bin/app" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_fixture_use || fail 'single-image fixture did not build'
analyze "$T/one" "$T/one/bin/app"
! grep -F '"image": ' "$T/report" >/dev/null && ! grep -F '"shipped_images"' "$T/report" >/dev/null || fail 'a single-image report changed shape'
grep -F '"the shipped closure is the artifact alone: a non-system dependency is cannot-measure"' "$T/report" >/dev/null ||
  fail 'a single-image report lost its limit'

# spec: src/objc/main.m "The shipped closure" -- missing, ambiguous, escaping, weak and duplicate-class closures are cannot-measure.
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
# spec: src/objc/main.m "The shipped closure" -- with --root-kind volume, --root is a staged volume as
#       installed at /: an absolute install name and every symlink resolve inside it, never on the host.
#       The names are unique, so no pass can come from the host's /usr/local or /Library.
VLIB=usr/local/mavergreen/mgp/lib/libMGShipped.dylib
vol() {   # vol DIR: DIR/root holds the app, the dylib it loads by absolute install name, and the absolute link to it
  v=$1/root; mkdir -p "$v/usr/local/mavergreen/mgp/lib" "$v/usr/local/mavergreen/mgp/bin" "$v/usr/local/lib"
  fxcc -dynamiclib "$FX/shipped-framework.m" -framework Foundation -install_name /usr/local/lib/libMGShipped.dylib -o "$v/$VLIB" ||
    fail 'volume dylib did not build'
  ln -s /$VLIB "$v/usr/local/lib/libMGShipped.dylib"
  fxcc "$FX/shipped-app.m" -framework Foundation "$v/$VLIB" -o "$v/usr/local/mavergreen/mgp/bin/App" || fail 'volume app did not build'
}
vol "$T/vol.1"
analyze_vol "$T/vol.1/root" "$T/vol.1/root/usr/local/mavergreen/mgp/bin/App"
exit_is 1 'volume absolute install name'
grep -F '"complete_within_boundary": true,' "$T/report" >/dev/null || fail "volume absolute install name: not measured: $(grep '"code"' "$T/report")"
# spec: mavergreen-shipyard scripts/assert_binary_compatible.sh accepts exit 0 only with this literal.
grep -F '"mode": "strict", "complete_within_boundary": true,' "$T/report" >/dev/null || fail 'volume absolute install name: breaks the strict-report literal shipyard requires'
want _shipped_class sharedShipped floor-supported "$VLIB"
grep -F '"root_kind": "volume"' "$T/report" >/dev/null || fail 'volume absolute install name: no root_kind'
grep -F '"absolute paths were resolved inside the root as installed at /"' "$T/report" >/dev/null || fail 'volume absolute install name: no volume limit'
analyze "$T/vol.1/root" "$T/vol.1/root/usr/local/mavergreen/mgp/bin/App"
exit_is 4 'tree mode unchanged'; error_is escaping-dependency 'tree mode unchanged'
grep -F 'a non-system path outside the shipped root' "$T/err" >/dev/null || fail 'tree mode unchanged: the refusal changed'
! grep -F '"root_kind"' "$T/report" >/dev/null || fail 'tree mode unchanged: the report gained root_kind'
analyze "$T/vol.1/root" "$T/vol.1/root/usr/local/mavergreen/mgp/bin/App" --root-kind tree
exit_is 4 'explicit tree mode'; error_is escaping-dependency 'explicit tree mode'
! grep -F '"root_kind"' "$T/report" >/dev/null || fail 'explicit tree mode: the report gained root_kind'
# platform: every --root is under /, so / is a root: the host has no /usr/local/lib/libMGShipped.dylib.
analyze_vol / "$T/vol.1/root/usr/local/mavergreen/mgp/bin/App"
exit_is 4 'root slash'; error_is missing-dependency 'root slash'
analyze "$T/vol.1/root" "$T/vol.1/root/usr/local/mavergreen/mgp/bin/App" --root-kind sysroot
exit_is 2 'bad root kind'

vol "$T/vol.2"; rm "$T/vol.2/root/$VLIB"
analyze_vol "$T/vol.2/root" "$T/vol.2/root/usr/local/mavergreen/mgp/bin/App"
exit_is 4 'volume missing'; error_is missing-dependency 'volume missing'
vol "$T/vol.3"; rm "$T/vol.3/root/$VLIB"; mkdir "$T/vol.3/root/$VLIB"
analyze_vol "$T/vol.3/root" "$T/vol.3/root/usr/local/mavergreen/mgp/bin/App"
exit_is 4 'volume directory'; error_is missing-dependency 'volume directory'
# The escaping file is both where the host would find it and where clamping `..` at the root would.
vol "$T/vol.4"; rm "$T/vol.4/root/usr/local/lib/libMGShipped.dylib"
ln -s /../../outside/libMGShipped.dylib "$T/vol.4/root/usr/local/lib/libMGShipped.dylib"
mkdir -p "$T/outside" "$T/vol.4/root/outside"
cp "$T/vol.4/root/$VLIB" "$T/outside/"; cp "$T/vol.4/root/$VLIB" "$T/vol.4/root/outside/"
analyze_vol "$T/vol.4/root" "$T/vol.4/root/usr/local/mavergreen/mgp/bin/App"
exit_is 4 'volume dotdot escape'; error_is escaping-dependency 'volume dotdot escape'
grep -F 'climbs above the root' "$T/report" >/dev/null || fail 'volume dotdot escape: the reason is not the climb'
vol "$T/vol.5"; rm "$T/vol.5/root/usr/local/lib/libMGShipped.dylib"
ln -s /usr/local/lib/libMGLoopB.dylib "$T/vol.5/root/usr/local/lib/libMGShipped.dylib"
ln -s /usr/local/lib/libMGShipped.dylib "$T/vol.5/root/usr/local/lib/libMGLoopB.dylib"
analyze_vol "$T/vol.5/root" "$T/vol.5/root/usr/local/mavergreen/mgp/bin/App"
exit_is 4 'volume loop'; error_is escaping-dependency 'volume loop'
grep -F 'passes through more than 32 symbolic links' "$T/report" >/dev/null || fail 'volume loop: the reason is not the link limit'

vfw() {   # vfw DIR INSTALL-NAME [APP FLAGS]...: MGShipped.framework staged in mgp, with libMGInner beside it
  v=$1/root; inst=$2; shift 2
  fw="$v/usr/local/mavergreen/mgp/Frameworks/MGShipped.framework"
  mkdir -p "$fw/Versions/A" "$v/Library/Frameworks"
  ln -s A "$fw/Versions/Current"; ln -s Versions/Current/MGShipped "$fw/MGShipped"
  ln -s /usr/local/mavergreen/mgp/Frameworks/MGShipped.framework "$v/Library/Frameworks/MGShipped.framework"
  fxcc -dynamiclib "$FX/shipped-inner.m" -framework Foundation -install_name @loader_path/libMGInner.dylib -o "$fw/Versions/A/libMGInner.dylib" ||
    fail 'volume inner dylib did not build'
  fxcc -dynamiclib -DMG_INNER "$FX/shipped-framework.m" -framework Foundation "$fw/Versions/A/libMGInner.dylib" \
    -install_name "$inst" -o "$fw/Versions/A/MGShipped" || fail 'volume framework did not build'
  fxcc -DMG_INNER "$FX/shipped-app.m" -framework Foundation -F"$v/usr/local/mavergreen/mgp/Frameworks" -framework MGShipped "$@" ||
    fail 'volume framework app did not build'
}
VFW=usr/local/mavergreen/mgp/Frameworks/MGShipped.framework/Versions/A/MGShipped
VIN=usr/local/mavergreen/mgp/Frameworks/MGShipped.framework/Versions/A/libMGInner.dylib
mkdir -p "$T/vol.6/root/usr/local/mavergreen/mgp/bin"
vfw "$T/vol.6" /Library/Frameworks/MGShipped.framework/Versions/A/MGShipped -o "$T/vol.6/root/usr/local/mavergreen/mgp/bin/App"
analyze_vol "$T/vol.6/root" "$T/vol.6/root/usr/local/mavergreen/mgp/bin/App"
exit_is 1 'volume framework chain'
grep -F '"complete_within_boundary": true,' "$T/report" >/dev/null || fail "volume framework chain: not measured: $(grep '"code"' "$T/report")"
want _shipped_class sharedShipped floor-supported "$VFW"
want _inner_inherited innerThing floor-supported "$VIN"
# The app's product is mgapp; its ../Frameworks is an absolute link into mgp's, which only the volume can follow.
mkdir -p "$T/vol.7/root/usr/local/mavergreen/mgapp/bin"
ln -s /usr/local/mavergreen/mgp/Frameworks "$T/vol.7/root/usr/local/mavergreen/mgapp/Frameworks"
vfw "$T/vol.7" @rpath/MGShipped.framework/Versions/A/MGShipped -Wl,-rpath,@executable_path/../Frameworks \
  -o "$T/vol.7/root/usr/local/mavergreen/mgapp/bin/App"
analyze_vol "$T/vol.7/root" "$T/vol.7/root/usr/local/mavergreen/mgapp/bin/App"
exit_is 1 'volume loader_path through an absolute link'
grep -F '"complete_within_boundary": true,' "$T/report" >/dev/null || fail "volume loader_path through an absolute link: not measured: $(grep '"code"' "$T/report")"
want _shipped_class sharedShipped floor-supported "$VFW"
want _inner_inherited innerThing floor-supported "$VIN"
# On the host the absolute link dangles, so tree mode finds nothing.
analyze "$T/vol.7/root" "$T/vol.7/root/usr/local/mavergreen/mgapp/bin/App"
exit_is 4 'tree loader_path through an absolute link'; error_is missing-dependency 'tree loader_path through an absolute link'
# After the absolute link, relative ones resolve from each link's directory: lib/../Frameworks, then the
# framework's MGShipped -> Versions/Current/MGShipped and Current -> A, as a versioned stage links them.
vrel() {   # vrel DIR CURRENT: the framework reached by /usr/local/lib/libMGShippedFw.dylib, Versions/Current -> CURRENT
  mkdir -p "$1/root/usr/local/mavergreen/mgp/bin" "$1/root/usr/local/mavergreen/mgp/lib" "$1/root/usr/local/lib"
  vfw "$1" /usr/local/lib/libMGShippedFw.dylib -o "$1/root/usr/local/mavergreen/mgp/bin/App"
  ln -s /usr/local/mavergreen/mgp/lib/libMGShippedFw.dylib "$1/root/usr/local/lib/libMGShippedFw.dylib"
  ln -s ../Frameworks/MGShipped.framework/MGShipped "$1/root/usr/local/mavergreen/mgp/lib/libMGShippedFw.dylib"
  ln -sfh "$2" "$1/root/usr/local/mavergreen/mgp/Frameworks/MGShipped.framework/Versions/Current"
}
vrel "$T/vol.8" A
analyze_vol "$T/vol.8/root" "$T/vol.8/root/usr/local/mavergreen/mgp/bin/App"
exit_is 1 'volume relative links after an absolute one'
grep -F '"complete_within_boundary": true,' "$T/report" >/dev/null || fail "volume relative links after an absolute one: not measured: $(grep '"code"' "$T/report")"
want _shipped_class sharedShipped floor-supported "$VFW"
want _inner_inherited innerThing floor-supported "$VIN"
vrel "$T/vol.9" B
analyze_vol "$T/vol.9/root" "$T/vol.9/root/usr/local/mavergreen/mgp/bin/App"
exit_is 4 'volume relative link to nothing'; error_is missing-dependency 'volume relative link to nothing'
echo "objc-closure: shipped images by interface, image-qualified findings, unchanged single-image reports and every refusal pass, in a tree and in a volume"
