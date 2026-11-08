#!/bin/sh
# platform: macOS-only -- builds and runs the native runtime capture tool and real host libclang over pinned SDKs
# spec: scripts/objc-reference-set.sh header -- the versioned reference set: SDK facts, the floor
#       runtime capture with its R1 root-method witness, and the manifest that binds them.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
FX="$HERE/fixtures/objc-api"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-reference-set-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
REFSET="$ROOT/scripts/objc-reference-set.sh"
PREFIX=${MAVERGREEN_OBJC_CLANG_PREFIX:-}
if [ -z "$PREFIX" ]; then
  case "$(uname -m)" in x86_64) short=clang22; flavor=native ;; arm64) short=clang22-cross; flavor=cross ;; *) exit 4 ;; esac
  version=$(tr -d '[:space:]' < "$ROOT/components/objc-reference-clang/version")
  PREFIX=$(sh "$ROOT/scripts/fetch_product_pkg.sh" --asset "mavericks-clang-22-$flavor-$version.pkg" "$short" "$version" "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/objc-reference-$short-$version")
fi
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -15 "$T/err" >&2; exit 1; }
OPEN='openURLs:withApplicationAtURL:options:configuration:error:'

# spec: tools/objc-runtime-inventory.m header -- the capture tool, over fixture classes loaded into it.
sh "$REFSET" capture-tool --output "$T/capture" 2>"$T/err" || fail 'capture tool did not build'
case "$(uname -m)" in x86_64) HOST_SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch x86_64); HOST_MIN=10.9 ;;
  arm64) HOST_SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch arm64); HOST_MIN=11.0 ;; esac
fixture() {  # $1 output, then -D flags
  out=$1; shift
  env -i PATH=/usr/bin:/bin /usr/bin/clang -arch "$(uname -m)" -isysroot "$HOST_SDK" -mmacosx-version-min="$HOST_MIN" -O1 \
    -Wno-objc-protocol-method-implementation "$@" -dynamiclib "$FX/runtime-roots.m" -framework Foundation -lobjc -o "$out" 2>"$T/err" ||
    fail "fixture $out did not build"
}
fixture "$T/roots.dylib"
fixture "$T/backfill.dylib" -DMG_BACKFILL
fixture "$T/activation.dylib" -DMG_BACKFILL -DMG_ACTIVATION_ROOT
fixture "$T/initcrash.dylib" -DMG_INIT_CRASH
HOST="--os $(sw_vers -productVersion) --build $(sw_vers -buildVersion) --arch $(uname -m)"
BASE="--require /usr/lib/libobjc.A.dylib --require /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation
  --root-selector description --root-selector isKindOfClass: --root-selector respondsToSelector:"
PROBES="--behavior-selector description --behavior-selector isKindOfClass: --behavior-selector respondsToSelector:"
capture() {  # runs the tool with $HOST $BASE and the arguments; rc, $T/rt.tsv, $T/cl.json, $T/err
  rm -f "$T/rt.tsv" "$T/cl.json"; rc=0
  # shellcheck disable=SC2086  # HOST and BASE are option lists
  "$T/capture" $HOST $BASE "$@" --runtime-output "$T/rt.tsv" --cluster-output "$T/cl.json" 2>"$T/err" || rc=$?
}
refused() {  # $1 what, $2 a fixed string the reasons must contain
  [ "$rc" = 4 ] || fail "$1: exit $rc, want 4"
  [ ! -e "$T/rt.tsv" ] && [ ! -e "$T/cl.json" ] || fail "$1: a refused capture left output"
  grep -F "$2" "$T/err" >/dev/null || fail "$1: no reason '$2'"
}
row() {  # the exact TAB-joined row must be in $T/rt.tsv
  want=$(printf '%s\t' "$@"); want=${want%?}
  grep -Fx "$want" "$T/rt.tsv" >/dev/null || fail "missing runtime row: $*"
}

# spec: tools/objc-runtime-inventory.m header -- Fixture classes in --diagnostic mode, which a host
#       that is not clean still answers; production is exercised by the refusals below.
# shellcheck disable=SC2086  # PROBES is an option list
capture --diagnostic --allow-image "$T/roots.dylib" --behavior-class MGProxy --behavior-class NSProxy $PROBES \
  --absent NSObject - mavergreenFixtureBackfill
[ "$rc" = 0 ] || fail "fixture capture exits $rc"
[ "$(head -1 "$T/rt.tsv")" = '# objc-runtime 1' ] || fail 'missing schema line'
tail -n +2 "$T/rt.tsv" | awk -F '\t' 'NF != 7 {exit 1}' || fail 'a runtime row without seven columns'
tail -n +2 "$T/rt.tsv" >"$T/body"
LC_ALL=C sort -u "$T/body" | cmp -s - "$T/body" || fail 'runtime rows are not sorted and unique'
row check mode - - diagnostic - -
row check fixture-images - - present - -
row check absent - mavergreenFixtureBackfill absent - -NSObject
row image roots.dylib - - "$(otool -arch "$(uname -m)" -l "$T/roots.dylib" | awk '$1 == "uuid" {print $2}')" fixture not-checked
# spec: tools/objc-runtime-inventory.m header -- R1: a root that is not NSObject answers nothing.
for k in + -; do for s in description isKindOfClass: respondsToSelector:; do
  row witness MGBareRoot "$k" "$s" - - MGBareRoot
done; done
# spec: tools/objc-runtime-inventory.m header -- R1: a root lacking one selector; the gap is inherited, and a class message finds the root's instance method last.
row witness MGPartialChild - isKindOfClass: -MGPartialRoot roots.dylib MGPartialRoot
row witness MGPartialChild + isKindOfClass: -MGPartialRoot roots.dylib MGPartialRoot
row witness MGPartialChild + description +MGPartialRoot roots.dylib MGPartialRoot
row witness MGPartialChild - respondsToSelector: - - MGPartialRoot
row witness MGPartialChild + respondsToSelector: - - MGPartialRoot
# spec: tools/objc-runtime-inventory.m header -- R1: an NSProxy subclass resolves through NSProxy, and what that does is measured, not assumed.
# platform: which system image implements NSProxy and NSObject is the host's fact, not the fixture's.
awk -F '\t' '$1 == "witness" && $2 == "MGProxy" && $3 == "-" && $4 == "isKindOfClass:" && $5 == "-NSProxy" && $6 != "-" && $7 == "NSProxy"' "$T/rt.tsv" | grep . >/dev/null ||
  fail 'MGProxy does not resolve isKindOfClass: through NSProxy'
awk -F '\t' '$1 == "witness" && $2 == "MGObject" && $3 == "-" && $4 == "respondsToSelector:" && $5 == "-NSObject" && $6 != "-" && $7 == "NSObject"' "$T/rt.tsv" | grep . >/dev/null ||
  fail 'MGObject does not resolve respondsToSelector: through NSObject'
row class MGProxy - NSProxy NSProxy roots.dylib -
row class MGPartialChild - MGPartialRoot MGPartialRoot roots.dylib -
for c in MGProxy NSProxy; do for s in description isKindOfClass: respondsToSelector:; do
  awk -F '\t' -v c="$c" -v s="$s" '$1 == "behavior" && $2 == c && $4 == s && ($5 == "returns" || $5 ~ /^raises:/) {ok=1} END {exit !ok}' "$T/rt.tsv" ||
    fail "behavior of -[$c $s] not measured"
done; done
# spec: tools/objc-runtime-inventory.m header -- Method rows: a category's replacement is active, the class's own entry shadowed.
row method MGObject - ping v16@0:8 roots.dylib active
row method MGObject - ping v16@0:8 roots.dylib shadowed
# platform: BOOL is signed char (c) in the x86_64 ABI and bool (B) in the arm64 one.
case "$(uname -m)" in x86_64) bool=c ;; *) bool=B ;; esac
row method MGPartialRoot - isKindOfClass: "${bool}24@0:8#16" roots.dylib active
awk -F '\t' '$1 == "class" && $6 == "Foundation" {f[$2] = 1} $1 == "method" && f[$2]' "$T/rt.tsv" | grep . >/dev/null || fail 'required image classes have no method rows'
# spec: tools/objc-runtime-inventory.m header -- a class whose +initialize changes its superclass or its
#       method lists is measured as a program that messages it sees it: initialized, and recorded so.
row check initialize - MGReparented changes - -
row class MGReparented - MGLateParent NSObject roots.dylib -
row method MGLateParent + lateFactory @16@0:8 roots.dylib active
awk -F '\t' '$1 == "witness" && $2 == "MGReparented" && $3 == "-" && $4 == "isKindOfClass:" && $5 == "-NSObject" && $7 == "NSObject"' "$T/rt.tsv" | grep . >/dev/null ||
  fail 'the reparented class has no witness through its new chain'
! awk -F '\t' '$1 == "check" && $2 == "initialize" && $4 != "MGReparented" && $4 !~ /^NSURLSession/' "$T/rt.tsv" | grep . >/dev/null ||
  fail 'a class that +initialize leaves alone is recorded as changing'
# platform: on 10.9.5, +[NSURLSession initialize] and its siblings' move each class under CFNetwork's
#           __NSCFURLSession family, where their factory methods live.
if [ "$(sw_vers -productVersion)" = 10.9.5 ]; then
  for c in NSURLSession NSURLSessionConfiguration NSURLSessionDataTask NSURLSessionDownloadTask NSURLSessionTask NSURLSessionUploadTask; do
    row check initialize - "$c" changes - -
    row class "$c" - "__NSCF${c#NS}" NSObject Foundation -
  done
fi
awk -F '\t' '$1 == "witness" && $2 == "NSString" && $3 == "-" && $4 == "isKindOfClass:" && $7 == "NSObject"' "$T/rt.tsv" | grep . >/dev/null ||
  fail 'a framework class has no witness'
! grep -F "$T" "$T/rt.tsv" "$T/cl.json" >/dev/null || fail 'a host path leaked into the capture'
! grep -F "$HOME" "$T/rt.tsv" "$T/cl.json" >/dev/null || fail 'a home path leaked into the capture'
# spec: tools/objc-runtime-inventory.m header -- Cluster probes: the concrete receiver, its chain and what it implements below the public class.
for p in 'NSString +alloc' 'NSString +alloc -initWithUTF8String:' 'NSString +stringWithUTF8String:' \
         'NSMutableString +alloc' 'NSMutableString +alloc -initWithUTF8String:' 'NSMutableString +stringWithUTF8String:'; do
  grep -F "{\"id\": \"$p\", " "$T/cl.json" >/dev/null || fail "cluster probe $p missing"
done
grep -F '"id": "NSString +alloc", "class": "NSString", "construction": ["+alloc"], "concrete": "NSPlaceholderString"' "$T/cl.json" >/dev/null ||
  fail 'NSString +alloc is not measured as its placeholder'
# platform: the floor SDK declares -[NSString initWithBytes:length:encoding:] (objc-sdk-inventory-test.sh
#           asserts it), yet on 10.9.5 neither NSString nor NSObject implements it: the allocated
#           placeholder does. That is the missing-base-method case the witness must not call unsupported.
if [ "$(sw_vers -productVersion)" = 10.9.5 ]; then
  sed -n '/"id": "NSString +alloc",/p' "$T/cl.json" | grep -F '{"selector": "initWithBytes:length:encoding:", "owner": "NSPlaceholderString"}' >/dev/null ||
    fail 'the NSString placeholder witness lacks initWithBytes:length:encoding:'
  ! awk -F '\t' '$1 == "method" && ($2 == "NSString" || $2 == "NSObject") && $3 == "-" && $4 == "initWithBytes:length:encoding:"' "$T/rt.tsv" | grep . >/dev/null ||
    fail 'NSString itself implements initWithBytes:length:encoding: after all'
fi
cp "$T/rt.tsv" "$T/first.tsv"; cp "$T/cl.json" "$T/first.json"
# shellcheck disable=SC2086  # PROBES is an option list
capture --diagnostic --allow-image "$T/roots.dylib" --behavior-class MGProxy --behavior-class NSProxy $PROBES \
  --absent NSObject - mavergreenFixtureBackfill
cmp -s "$T/rt.tsv" "$T/first.tsv" && cmp -s "$T/cl.json" "$T/first.json" || fail 'captures vary across identical runs'
# spec: tools/objc-runtime-inventory.m header -- every root selector gets a witness, measured without a send;
#       behavior rows send only the --behavior-selector list, which must be root selectors safe to send.
# shellcheck disable=SC2086  # PROBES is an option list
capture --diagnostic --root-selector retain --root-selector performSelector: --behavior-class NSProxy $PROBES
[ "$rc" = 0 ] || fail "a capture with more root selectors than behavior selectors exits $rc"
awk -F '\t' '$1 == "witness" && $2 == "NSProxy" && $3 == "-" && $4 == "performSelector:" && $7 == "NSProxy"' "$T/rt.tsv" | grep . >/dev/null ||
  fail 'performSelector: has no witness row'
! awk -F '\t' '$1 == "behavior" && ($4 == "retain" || $4 == "performSelector:")' "$T/rt.tsv" | grep . >/dev/null ||
  fail 'a root selector outside the behavior list was sent'
# spec: tools/objc-runtime-inventory.m header -- a class whose +initialize does not return in its probe
#       cannot be measured; the capture itself goes on, and the reason is a refusal.
capture --diagnostic --allow-image "$T/initcrash.dylib"
[ "$rc" = 0 ] || fail "a capture beside a crashing +initialize exits $rc"
grep -F "$(printf 'check\trefusal\t-\t-\tclass MGInitCrash: +initialize did not return in its probe')" "$T/rt.tsv" >/dev/null ||
  fail 'a crashing +initialize is not a refusal'
! awk -F '\t' '$1 == "check" && $2 == "initialize" && $4 == "MGInitCrash"' "$T/rt.tsv" | grep . >/dev/null || fail 'a crashing class was initialized'
capture --diagnostic --behavior-class NSProxy
[ "$rc" = 2 ] || fail "a behavior class without behavior selectors exits $rc, want 2"
capture --diagnostic --root-selector release --behavior-class NSProxy --behavior-selector release
[ "$rc" = 2 ] || fail "release as a behavior selector exits $rc, want 2"
capture --diagnostic --behavior-class NSProxy --behavior-selector hash
[ "$rc" = 2 ] || fail "a behavior selector that is not a root selector exits $rc, want 2"

# spec: tools/objc-runtime-inventory.m header -- Refusals: exit 4, every reason named, nothing written.
capture --allow-image "$T/roots.dylib"
refused 'a fixture image in production' 'fixture image loaded outside --diagnostic'
DYLD_FALLBACK_LIBRARY_PATH=/usr/lib; export DYLD_FALLBACK_LIBRARY_PATH
capture
unset DYLD_FALLBACK_LIBRARY_PATH
refused 'a DYLD variable' 'dyld environment variable DYLD_FALLBACK_LIBRARY_PATH is set'
DYLD_INSERT_LIBRARIES="$T/roots.dylib"; export DYLD_INSERT_LIBRARIES
capture
unset DYLD_INSERT_LIBRARIES
refused 'an injected image' 'non-system image loaded:'
grep -F 'dyld environment variable DYLD_INSERT_LIBRARIES is set' "$T/err" >/dev/null || fail 'injection by DYLD_INSERT_LIBRARIES not named'
capture --allow-image "$T/backfill.dylib" --absent NSObject - mavergreenFixtureBackfill
refused 'a preexisting backfill' 'preexisting backfill: -[NSObject mavergreenFixtureBackfill] already resolves'
capture --diagnostic --allow-image "$T/activation.dylib"
[ "$rc" = 0 ] && row check recaulk - - present - - || fail 'diagnostic capture did not record the Recaulk root'
capture --allow-image "$T/activation.dylib"
refused 'a loaded Recaulk activation root' 'the Recaulk activation root __recaulk_objc_activate is loaded'
capture --require /System/Library/Frameworks/MavergreenNoSuch.framework/Versions/A/MavergreenNoSuch
refused 'a failed required framework load' 'required image failed to load'
capture --require "$T/roots.dylib"
refused 'a required image outside the system' 'is not a system path'
capture --absent MavergreenNoSuchClass - x
refused 'an absent-target class that is not loaded' 'class MavergreenNoSuchClass is not loaded'
rc=0; "$T/capture" --os 10.0.0 --build X --arch "$(uname -m)" $BASE --runtime-output "$T/rt.tsv" --cluster-output "$T/cl.json" 2>"$T/err" || rc=$?
refused 'an unexpected OS' 'OS version'
grep -F 'OS build' "$T/err" >/dev/null || fail 'an unexpected build is not named'
rc=0; "$T/capture" --os "$(sw_vers -productVersion)" --build "$(sw_vers -buildVersion)" --arch i386 $BASE --runtime-output "$T/rt.tsv" --cluster-output "$T/cl.json" 2>"$T/err" || rc=$?
refused 'an unexpected architecture' 'architecture'
printf 'keep\n' >"$T/rt.tsv"
rc=0; "$T/capture" $HOST $BASE --runtime-output "$T/rt.tsv" --cluster-output "$T/cl.json" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && [ "$(cat "$T/rt.tsv")" = keep ] && [ ! -e "$T/cl.json" ] || fail 'an existing output was not refused untouched'
rm -f "$T/rt.tsv"
rc=0; "$T/capture" $HOST --runtime-output "$T/rt.tsv" --cluster-output "$T/cl.json" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] || fail "missing required options exit $rc, want 2"
# spec: tools/objc-runtime-inventory.m header -- --override: DYLD_FRAMEWORK_PATH is accepted only as the
#       declared override directory, alone, and the framework must then load from there and nowhere else.
ZERO=0000000000000000000000000000000000000000000000000000000000000000
SECSYS=/System/Library/Frameworks/Security.framework/Versions/A/Security
mkdir "$T/fw" "$T/fw-other"
DYLD_FRAMEWORK_PATH="$T/fw"; export DYLD_FRAMEWORK_PATH
capture --override Security "$T/fw" "$ZERO" "$SECSYS" 'fixture reason'
refused 'an override that does not load' 'override Security did not load from'
grep -F "Security is loaded from the system ($SECSYS)" "$T/err" >/dev/null || fail 'a system Security beside an override is not named'
capture
refused 'DYLD_FRAMEWORK_PATH without an override' 'dyld environment variable DYLD_FRAMEWORK_PATH is set'
DYLD_FALLBACK_LIBRARY_PATH=/usr/lib; export DYLD_FALLBACK_LIBRARY_PATH
capture --override Security "$T/fw" "$ZERO" "$SECSYS" 'fixture reason'
unset DYLD_FALLBACK_LIBRARY_PATH
refused 'a stray dyld variable beside an override' 'dyld environment variable DYLD_FALLBACK_LIBRARY_PATH is set'
! grep -F 'dyld environment variable DYLD_FRAMEWORK_PATH is set' "$T/err" >/dev/null || fail 'the declared override directory was itself refused'
DYLD_INSERT_LIBRARIES="$T/roots.dylib"; export DYLD_INSERT_LIBRARIES
capture --override Security "$T/fw" "$ZERO" "$SECSYS" 'fixture reason'
unset DYLD_INSERT_LIBRARIES
refused 'an injected image beside an override' 'non-system image loaded:'
DYLD_FRAMEWORK_PATH="$T/fw-other"
capture --override Security "$T/fw" "$ZERO" "$SECSYS" 'fixture reason'
refused 'a DYLD_FRAMEWORK_PATH other than the override' 'dyld environment variable DYLD_FRAMEWORK_PATH is set'
unset DYLD_FRAMEWORK_PATH
# platform: on the floor host AquaTransport's Security is unsigned and loads its own dylibs; overriding
#           Security with that very binary must still refuse the images it brings in.
if [ -f /usr/share/aquatransport/aquatransport.dylib ] && [ -f "$SECSYS" ]; then
  mkdir -p "$T/fw-aqua/Security.framework/Versions/A"
  cp "$SECSYS" "$T/fw-aqua/Security.framework/Versions/A/Security"
  DYLD_FRAMEWORK_PATH="$T/fw-aqua"; export DYLD_FRAMEWORK_PATH
  capture --require-signed --override Security "$T/fw-aqua" "$(shasum -a 256 "$SECSYS" | cut -c1-64)" "$SECSYS" 'fixture reason'
  unset DYLD_FRAMEWORK_PATH
  refused 'an override that still brings in an injected image' 'non-system image loaded: /usr/share/aquatransport/aquatransport.dylib'
  grep -F 'image Security is invalid, not anchor-apple' "$T/err" >/dev/null || fail 'an unsigned override binary was not refused'
fi
# spec: scripts/objc-reference-set.sh header -- capture refuses a DYLD_* environment before building anything.
# platform: with SIP on, the kernel strips DYLD_* when it execs a protected binary such as /bin/sh, so
#           the wrapper can only be shown a dyld variable where one survives that exec. dyld-check is
#           the same refusal fed an environment on stdin, which every host can exercise.
printf 'PATH=/bin\nDYLD_FALLBACK_LIBRARY_PATH=/usr/lib\n' >"$T/env"
rc=0; sh "$REFSET" dyld-check <"$T/env" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && grep -F 'dyld variables set: DYLD_FALLBACK_LIBRARY_PATH' "$T/err" >/dev/null || fail "dyld-check did not refuse a dyld variable ($rc)"
printf 'PATH=/bin\nNOT_DYLD_X=1\nX=DYLD_Y=1\n' | sh "$REFSET" dyld-check >"$T/out" 2>"$T/err" || fail 'dyld-check refused an environment without dyld variables'
# spec: scripts/objc-reference-set.sh header -- --floor-framework-override: the source must verify as
#       Apple-signed code in its private bundle copy, a reason is required, and nothing is left behind.
rc=0; sh "$REFSET" capture --floor-framework-override "Security=$T/roots.dylib" --override-reason 'fixture reason' --output "$T/ov1" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && [ ! -e "$T/ov1" ] && grep -F 'is not Apple-signed code' "$T/err" >/dev/null || fail "an unsigned override source was not refused ($rc)"
[ -z "$(ls -A "$T" | grep '^\.objc-reference')" ] || fail 'a refused override left its work directory'
rc=0; sh "$REFSET" capture --floor-framework-override "Security=$T/roots.dylib" --output "$T/ov1" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] || fail "an override without a reason exits $rc, want 2"
rc=0; sh "$REFSET" capture --floor-framework-override "../Security=$T/roots.dylib" --override-reason x --output "$T/ov1" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] || fail "a malformed override name exits $rc, want 2"
UNEXERCISED=
if DYLD_FALLBACK_LIBRARY_PATH=/usr/lib sh -c env | grep '^DYLD_FALLBACK_LIBRARY_PATH=' >/dev/null; then
  DYLD_FALLBACK_LIBRARY_PATH=/usr/lib; export DYLD_FALLBACK_LIBRARY_PATH
  rc=0; sh "$REFSET" capture --output "$T/cap" 2>"$T/err" || rc=$?
  unset DYLD_FALLBACK_LIBRARY_PATH
  [ "$rc" = 4 ] && [ ! -e "$T/cap" ] && grep -F 'dyld variables set: DYLD_FALLBACK_LIBRARY_PATH' "$T/err" >/dev/null ||
    fail "capture wrapper did not refuse a dyld environment ($rc)"
  DYLD_FALLBACK_LIBRARY_PATH=/usr/lib; export DYLD_FALLBACK_LIBRARY_PATH
  rc=0; sh "$REFSET" capture --floor-framework-override "Security=$T/roots.dylib" --override-reason x --output "$T/cap" 2>"$T/err" || rc=$?
  unset DYLD_FALLBACK_LIBRARY_PATH
  [ "$rc" = 4 ] && [ ! -e "$T/cap" ] && grep -F 'dyld variables set: DYLD_FALLBACK_LIBRARY_PATH' "$T/err" >/dev/null ||
    fail "capture wrapper did not refuse a dyld environment beside an override ($rc)"
else
  UNEXERCISED="the wrapper's live DYLD_* refusal: this host strips DYLD_* when it execs /bin/sh"
fi
# spec: scripts/objc-reference-set.sh header -- capture --diagnostic runs the reviewed floor closure on
#       any host, keeps whatever it refused as rows and records the wrapper's identities; build
#       refuses the result.
rc=0; sh "$REFSET" capture --diagnostic --output "$T/diag" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] && [ -f "$T/diag/floor-runtime.tsv" ] && [ -f "$T/diag/cluster-witnesses.json" ] ||
  fail "a diagnostic capture through the wrapper exits $rc"
awk -F '\t' -v tool="$(shasum -a 256 "$ROOT/tools/objc-runtime-inventory.m" | cut -c1-64)" '
  $1 == "identity" && $2 == "tool-source-sha256" && $5 == tool {a = 1}
  $1 == "identity" && $2 == "tool-compiler" && $5 != "-" && $5 != "" {b = 1}
  $1 == "identity" && $2 == "host-sdk-sha256" && length($5) == 64 && $5 !~ /[^0-9a-f]/ {c = 1}
  $1 == "check" && $2 == "mode" && $5 == "diagnostic" {d = 1}
  $1 == "image" && $4 == "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit" && $6 == "required" {e = 1}
  $1 == "check" && $2 == "absent" && $4 == "openURLs:withApplicationAtURL:options:configuration:error:" && $7 == "-NSWorkspace" {f = 1}
  $1 == "image" && $4 == "/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork" && $6 == "required" {g = 1}
  END {exit !(a && b && c && d && e && f && g)}' "$T/diag/floor-runtime.tsv" ||
  fail 'the wrapper capture lacks its identities, closure or absent target'
if [ "$(sw_vers -productVersion)" = 10.9.5 ]; then
  awk -F '\t' '$1 == "method" && $2 == "__NSCFURLSessionConfiguration" && $3 == "+" && $4 == "defaultSessionConfiguration" && $6 == "CFNetwork" && $7 == "active"' \
    "$T/diag/floor-runtime.tsv" | grep . >/dev/null || fail 'the wrapper capture lacks the CFNetwork methods NSURLSessionConfiguration dispatches to'
  # platform: with CFNetwork required, its three in-memory stores move under Foundation's public classes too.
  [ "$(awk -F '\t' '$1 == "check" && $2 == "initialize" {print $4}' "$T/diag/floor-runtime.tsv" | tr '\n' ' ')" = "NSURLSession NSURLSessionConfiguration NSURLSessionDataTask NSURLSessionDownloadTask NSURLSessionTask NSURLSessionUploadTask __NSCFMemoryHTTPCookieStorage __NSCFMemoryURLCache __NSCFMemoryURLCredentialStorage " ] ||
    fail 'the wrapper capture does not record the nine classes +initialize changes on 10.9.5'
fi

# spec: scripts/objc-reference-set.sh header -- the builder. A capture shaped as production would be,
#       from the floor identity and the current tool source: build can only check content; provenance
#       is the review of a real capture (tools/objc-runtime-inventory.m).
synthetic() {  # $1 dir
  mkdir "$1"
  {
    printf 'identity\tos\t-\t-\t10.9.5\t-\t-\nidentity\tbuild\t-\t-\t13F1911\t-\t-\nidentity\tarch\t-\t-\tx86_64\t-\t-\n'
    printf 'identity\ttool-source-sha256\t-\t-\t%s\t-\t-\n' "$(shasum -a 256 "$ROOT/tools/objc-runtime-inventory.m" | cut -c1-64)"
    printf 'identity\ttool-compiler\t-\t-\tfixture\t-\t-\nidentity\thost-sdk-sha256\t-\t-\tfixture\t-\t-\n'
    for c in dyld-environment:none nonsystem-images:none fixture-images:none recaulk:absent signatures:required mode:production; do
      printf 'check\t%s\t-\t-\t%s\t-\t-\n' "${c%%:*}" "${c#*:}"
    done
    for s in description isKindOfClass: respondsToSelector:; do
      printf 'behavior\tNSProxy\t-\t%s\treturns\t-\tinstance\n' "$s"
    done
    for s in autorelease class conformsToProtocol: description hash isEqual: isKindOfClass: isMemberOfClass: performSelector: \
      release respondsToSelector: retain self; do
      printf 'check\troot-selector\t-\t%s\treviewed\t-\t-\n' "$s"
      # spec: tools/objc-compat/reference.c root_exceptions -- the reviewed non-implementing classes, exactly: the R1 amendment's accepted residual risk;
      #       retain, release and autorelease as measured on the floor, each its own strict subset
      for c in NSLeafProxy Object _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder; do
        case "$s:$c" in
          retain:NSLeafProxy | retain:Object | release:NSLeafProxy | release:Object | release:__NSGenericDeallocHandler | \
            retain:__NSGenericDeallocHandler | autorelease:NSLeafProxy | autorelease:Object)
            printf 'witness\t%s\t-\t%s\t-%s\tFoundation\t%s\n' "$c" "$s" "$c" "$c" ;;
          *) printf 'witness\t%s\t-\t%s\t-\t-\t%s\n' "$c" "$s" "$c" ;;
        esac
      done
      printf 'witness\tRefRoot\t-\t%s\t-RefRoot\tFoundation\tRefRoot\n' "$s"
    done
    # spec: tools/objc-compat/reference.c root_exceptions -- +class: Object resolves it, so its set is the six but Object; -class above is the six, held to them
    for c in NSLeafProxy Object _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder; do
      if [ "$c" = Object ]; then printf 'witness\tObject\t+\tclass\t+Object\tFoundation\tObject\n'
      else printf 'witness\t%s\t+\tclass\t-\t-\t%s\n' "$c" "$c"; fi
    done
    printf 'witness\tRefRoot\t+\tclass\t-RefRoot\tFoundation\tRefRoot\n'
    printf 'check\tabsent\t-\t%s\tabsent\t-\t-NSWorkspace\n' "$OPEN"
    for c in NSURLSession NSURLSessionConfiguration NSURLSessionDataTask NSURLSessionDownloadTask NSURLSessionTask NSURLSessionUploadTask __NSCFMemoryHTTPCookieStorage __NSCFMemoryURLCache __NSCFMemoryURLCredentialStorage; do
      printf 'check\tinitialize\t-\t%s\tchanges\t-\t-\n' "$c"
    done
    printf 'image\tobjc-runtime-inventory\t-\t-\t-\tself\tnot-checked\n'
    n=0
    for i in /usr/lib/libobjc.A.dylib /System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation \
      /System/Library/Frameworks/Foundation.framework/Versions/C/Foundation /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit \
      /System/Library/Frameworks/Carbon.framework/Versions/A/Carbon /System/Library/Frameworks/CoreData.framework/Versions/A/CoreData /System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore \
      /System/Library/Frameworks/QuartzCore.framework/Versions/A/Frameworks/CoreImage.framework/Versions/A/CoreImage \
      /System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork; do
      n=$((n + 1))
      printf 'image\t%s\t-\t%s\t00000000-0000-0000-0000-00000000000%s\trequired\tanchor-apple\n' "$(basename "$i")" "$i" "$n"
    done
    printf 'class\tRefRoot\t-\t-\tRefRoot\tFoundation\t-\nclass\tRefOld\t-\tRefRoot\tRefRoot\tFoundation\t-\n'
    printf 'method\tRefRoot\t-\trootMethod\tv16@0:8\tFoundation\tactive\nmethod\tRefOld\t-\toldMethod\tv16@0:8\tFoundation\tactive\n'
  } | LC_ALL=C sort -u >"$1/body"
  { printf '# objc-runtime 1\n'; cat "$1/body"; } >"$1/floor-runtime.tsv"
  rm "$1/body"
  printf '{\n  "schema": 1,\n  "argument": "fixture",\n  "probes": [\n    {"id": "fixture"}\n  ]\n}\n' >"$1/cluster-witnesses.json"
}
synthetic "$T/runtime"
build() { rc=0; sh "$REFSET" build --clang-prefix "$PREFIX" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
FIXTURES="--floor-header $FX/reference-floor.h --newer-header $FX/reference-newer.h"
# shellcheck disable=SC2086  # option list
build --output "$T/ref" --runtime "$T/runtime" $FIXTURES
[ "$rc" = 0 ] || fail "fixture reference build exits $rc"
for f in manifest.json floor-sdk.tsv floor-signatures.tsv newer-sdk.tsv newer-signatures.tsv floor-runtime.tsv cluster-witnesses.json; do
  [ -f "$T/ref/$f" ] || fail "reference lacks $f"
done
[ "$(ls -A "$T/ref" | wc -l | tr -d ' ')" = 7 ] || fail 'reference has unexpected files'
sh "$REFSET" verify "$T/ref" >"$T/out" 2>"$T/err" || fail 'a fresh reference does not verify'
# spec: scripts/objc-reference-set.sh header -- The manifest binds SDK archives, header trees, extractor, runtime identity and every file.
M="$T/ref/manifest.json"
mget() { sed -n "s/^ *\"$1\": \"\\([^\"]*\\)\",\\{0,1\\}\$/\\1/p" "$M"; }
pinsha() { . "$ROOT/scripts/sdk-pins.sh"; shipyard_sdk_pin "$1" | cut -d' ' -f2; }
[ "$(mget archive_sha256 | head -1)" = "$(pinsha x86_64)" ] && [ "$(mget archive_sha256 | tail -1)" = "$(pinsha arm64)" ] || fail 'SDK archive identities missing'
mget header_tree_sha256 | grep -Eq '^[0-9a-f]{64}$' || fail 'no header tree digest'
[ "$(mget producer_sha256)" = "$(shasum -a 256 "$ROOT/tools/objc-sdk-inventory.c" | cut -c1-64)" ] || fail 'producer identity missing'
[ "$(mget clang_package)" = "$(tr -d '[:space:]' < "$ROOT/components/objc-reference-clang/version")" ] || fail 'clang package identity missing'
mget consumed_resource_headers_sha256 | grep -Eq '^[0-9a-f]{64}$' || fail 'no consumed resource header digest'
[ "$(mget runtime_status)" = captured ] && [ "$(mget os)" = 10.9.5 ] && [ "$(mget build)" = 13F1911 ] && [ "$(mget arch)" = x86_64 ] || fail 'runtime identity missing'
grep -F '"root_selectors": ["autorelease", "class", "conformsToProtocol:", "description", "hash", "isEqual:", "isKindOfClass:", "isMemberOfClass:", "performSelector:", "release", "respondsToSelector:", "retain", "self"],' "$M" >/dev/null || fail 'reviewed root selectors not in the manifest'
# spec: scripts/objc-reference-set.sh header -- retain, release, autorelease and +class: each one's measured
#       exception set, a strict subset of root_exceptions, recorded per selector with its reviewed kinds.
grep -F '"root_subset_exceptions": [{"selector": "autorelease", "kinds": ["+", "-"], "exceptions": ["_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]}, {"selector": "class", "kinds": ["+"], "exceptions": ["NSLeafProxy", "_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"]}, {"selector": "release", "kinds": ["+", "-"], "exceptions": ["_NSZombie_", "__NSAtom", "__NSMessageBuilder"]}, {"selector": "retain", "kinds": ["+", "-"], "exceptions": ["_NSZombie_", "__NSAtom", "__NSMessageBuilder"]}],' "$M" >/dev/null ||
  fail 'the per-selector exception sets are not in the manifest'
# spec: scripts/objc-reference-set.sh header -- the R1 amendment: the witness's non-implementing classes are the
#       reviewed set, recorded in the manifest as the accepted residual risk.
grep -F '"root_exceptions": ["NSLeafProxy", "Object", "_NSZombie_", "__NSAtom", "__NSGenericDeallocHandler", "__NSMessageBuilder"],' "$M" >/dev/null ||
  fail 'the reviewed witness exceptions are not in the manifest'
grep -F "{\"path\": \"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit\", \"uuid\": \"00000000-0000-0000-0000-000000000004\"}" "$M" >/dev/null ||
  fail 'framework load identity not in the manifest'
grep -F "\"headers\": [\"input/1 sha256:$(shasum -a 256 "$FX/reference-floor.h" | cut -c1-64)\"]," "$M" >/dev/null || fail 'explicit header identity missing'
grep -F "{\"name\": \"floor-runtime.tsv\", \"sha256\": \"$(shasum -a 256 "$T/ref/floor-runtime.tsv" | cut -c1-64)\", \"rows\": $(($(wc -l <"$T/ref/floor-runtime.tsv") - 1))}" "$M" >/dev/null ||
  fail 'runtime file identity or row count missing'
! grep -F "$T" "$T/ref/"* >/dev/null || fail 'a host path leaked into the reference set'
for f in "$T/ref/"*; do cp "$f" "$T/first-$(basename "$f")"; done
# shellcheck disable=SC2086  # option list
build --output "$T/ref2" --runtime "$T/runtime" $FIXTURES
[ "$rc" = 0 ] || fail "second fixture build exits $rc"
for f in "$T/ref/"*; do cmp -s "$f" "$T/ref2/$(basename "$f")" || fail "$(basename "$f") varies across identical builds"; done
# spec: scripts/objc-reference-set.sh header -- the extractor identity digests only the resource headers
#       the parse consumed, as the producer reports them: a host package that merely ships more
#       headers (clang22-cross adds arm_*.h) is the same input; a changed consumed header is not.
RES=$("$PREFIX/bin/clang" -print-resource-dir)
grep -F '"consumed_resource_headers": [' "$M" | grep -F '"include/stddef.h"' >/dev/null || fail 'stddef.h is not recorded as consumed'
consumed=$(sed -n 's/^    "consumed_resource_headers": \[\(.*\)\],$/\1/p' "$M" | tr -d '"' | tr ',' '\n' | sed 's/^ *//')
want=$(cd "$RES" && printf '%s\n' "$consumed" | while IFS= read -r f; do shasum -a 256 "./$f"; done | shasum -a 256 | cut -c1-64)
[ "$(mget consumed_resource_headers_sha256)" = "$want" ] || fail 'the consumed resource digest is not over the listed headers'
! grep -F '"resource_headers_sha256"' "$M" >/dev/null || fail 'the whole-package resource digest is still in the manifest'
mkdir -p "$T/pfx/bin" "$T/res"
ln -s "$PREFIX/include" "$T/pfx/include"; ln -s "$PREFIX/lib" "$T/pfx/lib"
cp -R "$RES/include" "$T/res/include"
printf '#!/bin/sh\ncase "$1" in -print-resource-dir) printf "%%s\\n" "%s"; exit 0 ;; esac\nexec "%s/bin/clang" "$@"\n' "$T/res" "$PREFIX" >"$T/pfx/bin/clang"
chmod +x "$T/pfx/bin/clang"
REAL_PREFIX=$PREFIX
build --output "$T/refnr" $FIXTURES
[ "$rc" = 0 ] || fail "fixture build without runtime exits $rc"
printf '/* not consumed by an x86_64 parse */\n' >"$T/res/include/arm_unconsumed_extra.h"
PREFIX="$T/pfx"
build --output "$T/refpfx" $FIXTURES
[ "$rc" = 0 ] || fail "fixture build through the extra-header prefix exits $rc"
cmp -s "$T/refnr/manifest.json" "$T/refpfx/manifest.json" || fail 'an unconsumed resource header changed the manifest'
printf '/* a changed consumed header */\n' >>"$T/res/include/stddef.h"
build --output "$T/refchg" $FIXTURES
[ "$rc" = 0 ] || fail "fixture build with a changed stddef.h exits $rc"
M2="$T/refchg/manifest.json"
[ "$(sed -n 's/^    "consumed_resource_headers_sha256": "\(.*\)",$/\1/p' "$M2")" != "$(mget consumed_resource_headers_sha256)" ] ||
  fail 'a changed consumed resource header kept the extractor identity'
PREFIX=$REAL_PREFIX

# spec: scripts/objc-reference-set.sh header -- lookup over the fixture facts. Fields: side, verdict, owner, then the SDK columns.
look() { sh "$REFSET" lookup "$T/ref" "$@" >"$T/out" 2>"$T/err" || fail "lookup $* failed"; }
says() { grep -F "$(printf '%s' "$1" | tr '|' '\t')" "$T/out" >/dev/null || fail "lookup: no '$1' in $(tr '\t' '|' <"$T/out")"; }
# spec: scripts/objc-reference-set.sh header -- inherited effective availability: the 10.0 method
#       reaches a 10.12 receiver through its superclass, whose own availability still binds.
look RefLater - rootMethod
says 'newer-sdk|declared|RefRoot|10.0|'; says 'class-introduced|10.12'; says 'floor-sdk|no-class|RefLater'
# spec: tools/README.objc-sdk-inventory.md -- a later owning class with an unannotated property:
#       libclang gives the property its class's availability.
look RefLater - unannotated
says 'newer-sdk|declared|RefLater|10.12|'
awk -F '\t' '$1 == "property-get" && $3 == "RefLater" && $5 == "unannotated" && $7 == "10.12"' "$T/ref/newer-sdk.tsv" | grep . >/dev/null ||
  fail 'unannotated property lost its owning class availability'
# spec: tools/README.objc-sdk-inventory.md -- category ownership: the semantic owner, with the
#       category kept as the container.
look RefOld - categoryMethod
says 'floor-sdk|declared|RefOld|'; says 'category:Extras'
look RefOld - laterMethod
says 'floor-sdk|absent'; says 'newer-sdk|declared|RefOld|10.11|'; says 'category:Later'
# spec: tools/README.objc-sdk-inventory.md -- class (+) and instance (-) members are distinct.
look RefRoot + shared
says 'floor-sdk|declared|RefRoot|'
look RefRoot + rootMethod
says 'floor-sdk|absent'
# spec: tools/README.objc-sdk-inventory.md -- protocol members are declarations with their
#       optionality, never an implementation for an adopter.
awk -F '\t' '$1 == "protocol-method" && $3 == "RefProtocol" && $5 == "requiredThing" && $11 == "protocol:required"' "$T/ref/floor-sdk.tsv" | grep . >/dev/null &&
  awk -F '\t' '$1 == "protocol-method" && $3 == "RefProtocol" && $5 == "optionalThing" && $11 == "protocol:optional"' "$T/ref/floor-sdk.tsv" | grep . >/dev/null ||
  fail 'protocol required/optional facts lost'
look RefAdopter - requiredThing
says 'floor-sdk|absent'
# spec: scripts/objc-reference-set.sh header -- a witness row answers directly; other runtime
#       lookups walk measured method rows.
look Object - isKindOfClass:
says 'floor-runtime|absent|-|-|root|Object|witness'
look RefRoot - isKindOfClass:
says 'floor-runtime|resolves|-RefRoot|Foundation|root|RefRoot|witness'
look RefOld - rootMethod
says 'floor-runtime|resolves|-RefRoot|Foundation'
look RefOld - laterMethod
says 'floor-runtime|absent'

# spec: scripts/objc-reference-set.sh header -- build refuses every capture that is not production, clean, floor and current.
MUTBASE="$T/runtime"
mutant() {  # $1 what $2 expected reason $3 sed over the rows (kept sorted unless $4 is raw)
  rm -rf "$T/mut" "$T/ref3"
  cp -R "$MUTBASE" "$T/mut"
  if [ "${4:-}" = raw ]; then sed "$3" "$MUTBASE/floor-runtime.tsv" >"$T/mut/floor-runtime.tsv"
  else { echo "# objc-runtime 1"; tail -n +2 "$MUTBASE/floor-runtime.tsv" | sed "$3" | LC_ALL=C sort -u; } >"$T/mut/floor-runtime.tsv"
  fi
  cmp -s "$T/mut/floor-runtime.tsv" "$MUTBASE/floor-runtime.tsv" && fail "mutation '$1' changed nothing"
  # shellcheck disable=SC2086  # option list
  build --output "$T/ref3" --runtime "$T/mut" $FIXTURES
  [ "$rc" = 4 ] && [ ! -e "$T/ref3" ] || fail "build accepted a capture with $1 ($rc)"
  grep -F "$2" "$T/err" >/dev/null || fail "a capture with $1 was refused, but not for: $2"
}
TAB=$(printf '\t')
mutant 'diagnostic mode' 'mode is diagnostic' "s/^check${TAB}mode${TAB}-${TAB}-${TAB}production/check${TAB}mode${TAB}-${TAB}-${TAB}diagnostic/"
mutant 'a refusal' 'capture records a refusal: x' "s/^check${TAB}recaulk${TAB}/check${TAB}refusal${TAB}-${TAB}-${TAB}x${TAB}-${TAB}-\\
check${TAB}recaulk${TAB}/"
mutant 'fixture images' 'loaded non-system images' "s/fixture-images${TAB}-${TAB}-${TAB}none/fixture-images${TAB}-${TAB}-${TAB}present/"
mutant 'a fixture image row' 'loaded fixture image AppKit' "s/${TAB}required${TAB}anchor-apple\$/${TAB}fixture${TAB}anchor-apple/"
mutant 'a dyld environment' 'saw a dyld environment' "s/dyld-environment${TAB}-${TAB}-${TAB}none/dyld-environment${TAB}-${TAB}-${TAB}present/"
mutant 'Recaulk' 'saw Recaulk' "s/recaulk${TAB}-${TAB}-${TAB}absent/recaulk${TAB}-${TAB}-${TAB}present/"
mutant 'unrequired signatures' 'did not require signatures' "s/signatures${TAB}-${TAB}-${TAB}required/signatures${TAB}-${TAB}-${TAB}not-required/"
mutant 'an unsigned image' 'is invalid, not anchor-apple' "/^image${TAB}AppKit${TAB}/s/anchor-apple\$/invalid/"
mutant 'another OS' 'capture identity 10.9.4' "s/^identity${TAB}os${TAB}-${TAB}-${TAB}10.9.5/identity${TAB}os${TAB}-${TAB}-${TAB}10.9.4/"
mutant 'another build' 'capture identity 10.9.5 13F34' "s/13F1911/13F34/"
mutant 'another arch' 'capture identity 10.9.5 13F1911 arm64' "s/^identity${TAB}arch${TAB}-${TAB}-${TAB}x86_64/identity${TAB}arch${TAB}-${TAB}-${TAB}arm64/"
mutant 'a stale tool' 'another tool source (00)' "s/^identity${TAB}tool-source-sha256${TAB}-${TAB}-${TAB}[0-9a-f]*/identity${TAB}tool-source-sha256${TAB}-${TAB}-${TAB}00/"
mutant 'a missing required image' 'AppKit.framework/Versions/C/AppKit not loaded' "/^image${TAB}AppKit${TAB}/d"
mutant 'a missing root selector' 'root selector respondsToSelector: not captured' "/root-selector${TAB}-${TAB}respondsToSelector:/d"
mutant 'an extra root selector' 'a different root selector list' "s/^check${TAB}recaulk${TAB}/check${TAB}root-selector${TAB}-${TAB}zzz${TAB}reviewed${TAB}-${TAB}-\\
check${TAB}recaulk${TAB}/"
mutant 'a present target' 'absent target not checked absent' "s/${OPEN}${TAB}absent/${OPEN}${TAB}present/"
mutant 'no behavior' 'behavior of NSProxy not captured' "/^behavior/d"
mutant 'no witness' 'no root witness' "/^witness/d"
# spec: scripts/objc-reference-set.sh header -- the classes +initialize changed are exactly the reviewed INITIALIZE_CHANGES.
mutant 'an unreviewed +initialize change' 'classes changed by +initialize NSURLSession NSURLSessionConfiguration NSURLSessionDataTask NSURLSessionDownloadTask NSURLSessionTask NSURLSessionUploadTask RefOld __NSCFMemoryHTTPCookieStorage __NSCFMemoryURLCache __NSCFMemoryURLCredentialStorage are not the reviewed' \
  "s/^check${TAB}recaulk${TAB}/check${TAB}initialize${TAB}-${TAB}RefOld${TAB}changes${TAB}-${TAB}-\\
check${TAB}recaulk${TAB}/"
mutant 'a reviewed +initialize change missing' 'classes changed by +initialize NSURLSession NSURLSessionConfiguration NSURLSessionDataTask NSURLSessionDownloadTask NSURLSessionUploadTask __NSCFMemoryHTTPCookieStorage __NSCFMemoryURLCache __NSCFMemoryURLCredentialStorage are not the reviewed' \
  "/^check${TAB}initialize${TAB}-${TAB}NSURLSessionTask${TAB}/d"
mutant 'one exception fewer' 'witness exceptions NSLeafProxy _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder are not the reviewed' \
  "/^witness${TAB}Object${TAB}/s/${TAB}-${TAB}-${TAB}Object\$/${TAB}-NSObject${TAB}libobjc.A.dylib${TAB}Object/"
mutant 'one exception more' 'witness exceptions NSLeafProxy Object RefRoot' "s/${TAB}-RefRoot${TAB}Foundation${TAB}RefRoot\$/${TAB}-${TAB}-${TAB}RefRoot/"
# spec: scripts/objc-reference-set.sh header -- per selector and kind, not only in union: one reviewed exception that
#       resolves one root selector makes that selector's exception set another one.
mutant 'an exception that resolves one selector' 'its -hash witness exceptions NSLeafProxy _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder are not the reviewed' \
  "/^witness${TAB}Object${TAB}-${TAB}hash${TAB}/s/${TAB}-${TAB}-${TAB}Object\$/${TAB}-NSObject${TAB}libobjc.A.dylib${TAB}Object/"
# spec: scripts/objc-reference-set.sh header -- a selector with a recorded set is held to that set, smaller or larger;
#       a kind without one (-class) is held to the six.
mutant 'a retain set one smaller' 'its -retain witness exceptions _NSZombie_ __NSMessageBuilder are not the reviewed _NSZombie_ __NSAtom __NSMessageBuilder' \
  "/^witness${TAB}__NSAtom${TAB}-${TAB}retain${TAB}/s/${TAB}-${TAB}-${TAB}__NSAtom\$/${TAB}-NSObject${TAB}libobjc.A.dylib${TAB}__NSAtom/"
mutant 'an autorelease set one larger' 'its -autorelease witness exceptions NSLeafProxy _NSZombie_' \
  "/^witness${TAB}NSLeafProxy${TAB}-${TAB}autorelease${TAB}/s/${TAB}-NSLeafProxy${TAB}Foundation${TAB}NSLeafProxy\$/${TAB}-${TAB}-${TAB}NSLeafProxy/"
mutant 'a +class set without NSLeafProxy' 'its +class witness exceptions _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder are not the reviewed' \
  "/^witness${TAB}NSLeafProxy${TAB}+${TAB}class${TAB}/s/${TAB}-${TAB}-${TAB}NSLeafProxy\$/${TAB}-NSObject${TAB}libobjc.A.dylib${TAB}NSLeafProxy/"
mutant 'a -class set without Object' 'its -class witness exceptions NSLeafProxy _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder are not the reviewed NSLeafProxy Object' \
  "/^witness${TAB}Object${TAB}-${TAB}class${TAB}/s/${TAB}-${TAB}-${TAB}Object\$/${TAB}-NSObject${TAB}libobjc.A.dylib${TAB}Object/"
mutant 'unsorted rows' 'not sorted and unique' '2{h;d;};3G' raw
mutant 'a short row' 'without exactly seven columns' "s/^class${TAB}RefRoot${TAB}-${TAB}-${TAB}RefRoot${TAB}Foundation${TAB}-\$/class${TAB}RefRoot/"
mutant 'no schema line' 'not an objc-runtime 1 capture' '1d' raw
# shellcheck disable=SC2086  # option list
build --output "$T/ref3" --runtime "$T/diag" $FIXTURES
[ "$rc" = 4 ] && [ ! -e "$T/ref3" ] && grep -F 'mode is diagnostic' "$T/err" >/dev/null || fail "build accepted a diagnostic wrapper capture ($rc)"
# spec: scripts/objc-reference-set.sh header -- on the floor host, a capture with the Security override
#       is production, loads Security only from the private copy, and build accepts it with the override
#       recorded. The source is AquaTransport's preserved Security.original when present.
SECSRC=/System/Library/Frameworks/Security.framework/Versions/A/Security.original
[ -f "$SECSRC" ] || SECSRC=/System/Library/Frameworks/Security.framework/Versions/A/Security
if [ "$(sw_vers -productVersion)" = 10.9.5 ] && [ "$(sw_vers -buildVersion)" = 13F1911 ] && [ -f "$SECSRC" ]; then
  rc=0; sh "$REFSET" capture --floor-framework-override "Security=$SECSRC" --override-reason 'fixture reason; test' --output "$T/ovcap" >"$T/out" 2>"$T/err" || rc=$?
  [ "$rc" = 0 ] || fail "the floor capture with a Security override exits $rc"
  [ "$(ls "$T/ovcap")" = "$(printf 'cluster-witnesses.json\nfloor-runtime.tsv')" ] || fail 'the override capture kept more than its two files'
  OR="$T/ovcap/floor-runtime.tsv"
  awk -F '\t' -v src="$SECSRC" -v sha="$(shasum -a 256 "$SECSRC" | cut -c1-64)" '
    $1 == "override" && $2 == "Security" && $4 == src && $5 == sha && $6 == "Security" && $7 == "anchor-apple" {o = 1}
    $1 == "image" && $2 == "Security" && $4 == "-" && $6 == "override" && $7 == "anchor-apple" {i = 1}
    $1 == "image" && $4 ~ /\/Security\.framework\// {sys = 1}
    $1 == "image" && $6 != "self" && $6 != "override" && $4 == "-" {stray = 1}
    $1 == "check" && $2 == "override-reason" && $4 == "Security" && $5 == "fixture reason; test" {r = 1}
    $1 == "check" && $2 == "dyld-environment" && $5 == "framework-override" {d = 1}
    $1 == "check" && $2 == "mode" && $5 == "production" {m = 1}
    END {exit !(o && i && !sys && !stray && r && d && m)}' "$OR" || fail 'the override capture does not prove where Security came from'
  # shellcheck disable=SC2086  # option list
  build --output "$T/refov" --runtime "$T/ovcap" $FIXTURES
  [ "$rc" = 0 ] || fail "build refused a verified override capture ($rc)"
  grep -F "{\"framework\": \"Security\", \"source\": \"$SECSRC\", \"sha256\": \"$(shasum -a 256 "$SECSRC" | cut -c1-64)\", \"signature\": \"anchor-apple\", \"reason\": \"fixture reason; test\"}" "$T/refov/manifest.json" >/dev/null ||
    fail 'the manifest does not record the override'
fi
# spec: scripts/objc-reference-set.sh header -- build accepts an override only when it is recorded,
#       Apple-signed, reasoned, and the only Security loaded.
OVSHA=1111111111111111111111111111111111111111111111111111111111111111
mkdir "$T/runtime-ov"; cp "$T/runtime/cluster-witnesses.json" "$T/runtime-ov/"
{ echo '# objc-runtime 1'
  { tail -n +2 "$T/runtime/floor-runtime.tsv" | sed "s/^check${TAB}dyld-environment${TAB}-${TAB}-${TAB}none/check${TAB}dyld-environment${TAB}-${TAB}-${TAB}framework-override/"
    printf 'image\tSecurity\t-\t-\t00000000-0000-0000-0000-0000000000AA\toverride\tanchor-apple\n'
    printf 'override\tSecurity\t-\t/System/Library/Frameworks/Security.framework/Versions/A/Security.original\t%s\tSecurity\tanchor-apple\n' "$OVSHA"
    printf 'check\toverride-reason\t-\tSecurity\tsystem Security replaced by AquaTransport; original binary used\t-\t-\n'
  } | LC_ALL=C sort -u; } >"$T/runtime-ov/floor-runtime.tsv"
build --output "$T/refov2" --runtime "$T/runtime-ov" $FIXTURES
[ "$rc" = 0 ] || fail "build refused a recorded override ($rc)"
grep -F "\"framework_overrides\": [{\"framework\": \"Security\", \"source\": \"/System/Library/Frameworks/Security.framework/Versions/A/Security.original\", \"sha256\": \"$OVSHA\", \"signature\": \"anchor-apple\", \"reason\": \"system Security replaced by AquaTransport; original binary used\"}]," "$T/refov2/manifest.json" >/dev/null ||
  fail 'the manifest does not record the synthetic override'
grep -F '"framework_overrides": [],' "$T/ref/manifest.json" >/dev/null || fail 'a capture without overrides does not say so'
MUTBASE="$T/runtime-ov"
mutant 'an unsigned override' 'override Security is invalid, not anchor-apple' "s/^\(override${TAB}.*${TAB}\)anchor-apple\$/\1invalid/"
mutant 'an override without a reason' 'override Security has no reason' "/^check${TAB}override-reason/d"
mutant 'an unrecorded override image' 'image Security is an unrecorded override' "/^override${TAB}/d"
mutant 'an override with a malformed hash' 'override Security has no SHA-256' "s/${OVSHA}/abc/"
mutant 'an override that never loaded' 'override Security did not load' "/^image${TAB}Security${TAB}/d"
mutant 'a system Security beside the override' 'Security is also loaded from the system' "s|^image${TAB}Security${TAB}-${TAB}-${TAB}|image${TAB}Security${TAB}-${TAB}/System/Library/Frameworks/Security.framework/Versions/A/Security${TAB}|;s|${TAB}override${TAB}anchor-apple\$|${TAB}loaded${TAB}anchor-apple|"
mutant 'a framework-override environment without an override' 'framework-override environment without a recorded override' "/^override${TAB}/d;/^check${TAB}override-reason/d;/^image${TAB}Security${TAB}/d"
MUTBASE="$T/runtime"
mutant 'a framework-override environment in a plain capture' 'framework-override environment without a recorded override' "s/^check${TAB}dyld-environment${TAB}-${TAB}-${TAB}none/check${TAB}dyld-environment${TAB}-${TAB}-${TAB}framework-override/"
rm -rf "$T/ref3"
build --output "$T/ref3" --runtime "$T/missing" $FIXTURES
[ "$rc" = 4 ] && [ ! -e "$T/ref3" ] || fail "an unreadable capture was accepted ($rc)"
mkdir "$T/keep"
build --output "$T/keep" $FIXTURES
[ "$rc" = 4 ] && [ -z "$(ls -A "$T/keep")" ] || fail 'an existing destination was not refused'
printf '@interface Broken\nthis is not valid;\n' >"$T/broken.h"
build --output "$T/ref3" --floor-header "$T/broken.h" --newer-header "$FX/reference-newer.h"
[ "$rc" = 4 ] && [ ! -e "$T/ref3" ] || fail "a parse failure left a reference ($rc)"
[ -z "$(ls -A "$T" | grep '^\.objc-reference')" ] || fail 'a failed build left its work directory'
build --output "$T/ref3" --floor-header "$T/missing.h" --newer-header "$FX/reference-newer.h"
[ "$rc" = 4 ] && [ ! -e "$T/ref3" ] || fail "an unreadable header was accepted ($rc)"
rc=0; sh "$REFSET" build --output "$T/ref3" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] || fail "a build without --clang-prefix exits $rc, want 2"
# spec: scripts/objc-reference-set.sh header -- a genuinely measured empty C header is an empty,
#       successful SDK side; no runtime is "not-captured".
printf 'typedef int not_an_objc_api;\n' >"$T/empty.h"
build --output "$T/ref3" --floor-header "$T/empty.h" --newer-header "$FX/reference-newer.h"
[ "$rc" = 0 ] && [ ! -s "$T/ref3/floor-sdk.tsv" ] && [ "$(cat "$T/ref3/floor-signatures.tsv")" = '# objc-signatures 1' ] || fail "an empty header did not measure empty ($rc)"
grep -F '{"name": "floor-sdk.tsv", "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "rows": 0}' "$T/ref3/manifest.json" >/dev/null ||
  fail 'the empty side is not recorded as zero rows'
grep -F '"runtime_status": "not-captured",' "$T/ref3/manifest.json" >/dev/null && [ ! -e "$T/ref3/floor-runtime.tsv" ] || fail 'no runtime is not recorded as not-captured'
sh "$REFSET" lookup "$T/ref3" RefRoot - isKindOfClass: >"$T/out" 2>"$T/err" || fail 'lookup without runtime failed'
grep -Fx "$(printf 'floor-runtime\tnot-captured')" "$T/out" >/dev/null || fail 'lookup without runtime claims a runtime fact'
# spec: tools/README.objc-sdk-inventory.md -- ambient include paths cannot reach the measurement.
mkdir "$T/poison"
printf '#error ambient include path must not influence a pinned SDK measurement\n' >"$T/poison/stddef.h"
CPATH="$T/poison"; OBJC_INCLUDE_PATH="$T/poison"; export CPATH OBJC_INCLUDE_PATH
# shellcheck disable=SC2086  # option list
build --output "$T/ref4" --runtime "$T/runtime" $FIXTURES
unset CPATH OBJC_INCLUDE_PATH
[ "$rc" = 0 ] || fail "ambient include paths broke the build ($rc)"
for f in "$T/ref/"*; do cmp -s "$f" "$T/ref4/$(basename "$f")" || fail "ambient include paths changed $(basename "$f")"; done

# spec: scripts/objc-reference-set.sh header -- verify recomputes every hash and count and refuses unlisted files.
cp -R "$T/ref" "$T/tamper"
printf 'x\n' >>"$T/tamper/floor-sdk.tsv"
rc=0; sh "$REFSET" verify "$T/tamper" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] || fail "a tampered file verified ($rc)"
rm -rf "$T/tamper"; cp -R "$T/ref" "$T/tamper"; printf 'x\n' >"$T/tamper/extra.tsv"
rc=0; sh "$REFSET" verify "$T/tamper" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] || fail "an unlisted file verified ($rc)"
rm -rf "$T/tamper"; cp -R "$T/ref" "$T/tamper"; rm "$T/tamper/cluster-witnesses.json"
rc=0; sh "$REFSET" verify "$T/tamper" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] || fail "a missing file verified ($rc)"
rc=0; sh "$REFSET" verify "$T/missing" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] || fail "an absent reference verified ($rc)"

# spec: scripts/objc-reference-set.sh header -- reference/objc is exactly what build regenerates from the pinned inputs.
REF="$ROOT/reference/objc"
sh "$REFSET" verify "$REF" >"$T/out" 2>"$T/err" || fail 'the committed reference set does not verify'
runtime_args=
[ ! -f "$REF/floor-runtime.tsv" ] || { mkdir "$T/committed-runtime"; cp "$REF/floor-runtime.tsv" "$REF/cluster-witnesses.json" "$T/committed-runtime/"; runtime_args="--runtime $T/committed-runtime"; }
# shellcheck disable=SC2086  # option list
build --output "$T/regen" $runtime_args
[ "$rc" = 0 ] || fail "regenerating the committed reference exits $rc"
for f in "$REF/"* "$T/regen/"*; do
  cmp -s "$REF/$(basename "$f")" "$T/regen/$(basename "$f")" || fail "regenerated $(basename "$f") differs from the committed one"
done
sh "$REFSET" lookup "$REF" NSWorkspace - "$OPEN" >"$T/out" 2>"$T/err" || fail 'openURLs lookup failed'
grep -F "$(printf 'floor-sdk\tabsent\t')" "$T/out" >/dev/null || fail 'openURLs appears in the floor SDK'
grep -F "$(printf 'newer-sdk\tdeclared\tNSWorkspace\t10.10\t')" "$T/out" >/dev/null || fail 'openURLs is not cataloged as a 10.10 NSWorkspace method'
grep -E "^floor-runtime	(absent|not-captured)" "$T/out" >/dev/null || fail 'the floor runtime claims openURLs'
# spec: tools/objc-runtime-inventory.m header -- 10.9.5's NSURLSession factories, measured where +initialize puts them.
if [ -f "$REF/floor-runtime.tsv" ]; then
  sh "$REFSET" lookup "$REF" NSURLSessionConfiguration + defaultSessionConfiguration >"$T/out" 2>"$T/err" || fail 'defaultSessionConfiguration lookup failed'
  grep -F "$(printf 'floor-runtime\tresolves\t+__NSCFURLSessionConfiguration\tCFNetwork')" "$T/out" >/dev/null ||
    fail "the floor runtime does not answer +[NSURLSessionConfiguration defaultSessionConfiguration]: $(tr '\t' '|' <"$T/out")"
  sh "$REFSET" lookup "$REF" NSURLSession + sessionWithConfiguration:delegate:delegateQueue: >"$T/out" 2>"$T/err" || fail 'sessionWithConfiguration lookup failed'
  grep -F "$(printf 'floor-runtime\tresolves\t+__NSCFURLSession\tCFNetwork')" "$T/out" >/dev/null ||
    fail "the floor runtime does not answer +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]: $(tr '\t' '|' <"$T/out")"
fi
echo "objc-reference-set: capture fixtures and refusals, builder identities/refusals, lookup and committed reference pass"
# platform: a path this host cannot exercise is reported, never counted as passed (exit 77 is SKIP).
if [ -n "$UNEXERCISED" ]; then
  echo "objc-reference-set: everything else passed, but NOT EXERCISED on this host: $UNEXERCISED" >&2
  exit 77
fi
