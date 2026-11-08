#!/bin/sh
# platform: macOS-only -- native Apple compiler, the pinned SDKs and libclang for generation
#   usage: objc-reference-set.sh capture --output NEW_DIR [--diagnostic]
#                                        [--floor-framework-override NAME=BINARY --override-reason TEXT]
#          objc-reference-set.sh capture-tool --output FILE
#          objc-reference-set.sh dyld-check   (environment lines on stdin)
#          objc-reference-set.sh build --clang-prefix PREFIX --output NEW_DIR [--runtime CAPTURE_DIR]
#                                      [--floor-header FILE]... [--newer-header FILE]...
#          objc-reference-set.sh verify REF_DIR
#          objc-reference-set.sh lookup REF_DIR CLASS KIND SELECTOR
#          The versioned Objective-C reference set: SDK declaration facts from the pinned floor (10.9)
#          and newer (11.3) SDKs, and a runtime capture from a real clean floor host, bound together by
#          manifest.json. Apple bytes never enter it, only derived facts and the identities of what
#          they were derived from.
#          capture runs tools/objc-runtime-inventory.m on the floor host (FLOOR_* below) with the
#          reviewed image closure, root selectors, behavior classes and selectors and absent targets, and writes
#          NEW_DIR/{floor-runtime.tsv,cluster-witnesses.json}. It refuses a DYLD_* environment before
#          building anything; the tool refuses everything else it documents. --diagnostic keeps an
#          --floor-framework-override is the one sanctioned exception, for a floor host whose system
#          framework NAME was replaced (on the reference host AquaTransport replaced Security): BINARY
#          (there, the preserved Security.original) goes into a private copy of the system
#          framework in the work directory, must verify there as Apple-signed code, and is loaded
#          through DYLD_FRAMEWORK_PATH set by this wrapper alone; the tool then proves it loaded
#          from that copy with the recorded SHA-256 and that no system copy or injected image did.
#          The override, its source, hash, signature and the reason go into the manifest.
#          unclean host's capture for inspection; build never accepts one. capture-tool only builds the
#          tool (the tests drive it with fixtures). dyld-check applies capture's DYLD_* refusal
#          to NAME=VALUE lines on stdin: a SIP host strips DYLD_* from any protected exec, /bin/sh
#          included, so the tests show it an environment that way.
#          build writes NEW_DIR/{floor-sdk.tsv,floor-signatures.tsv,newer-sdk.tsv,newer-signatures.tsv,
#          manifest.json}, plus floor-runtime.tsv and cluster-witnesses.json when --runtime names a
#          capture that is production, clean, from the floor identity and from the current tool source, whose
#          classes changed by +initialize are exactly the reviewed INITIALIZE_CHANGES, and whose
#          R1 witness exceptions are exactly the reviewed ROOT_EXCEPTIONS for every root selector and kind,
#          but for the selectors and kinds of ROOT_SUBSETS, each held exactly to its own recorded set
#          (the manifest records them as root_exceptions and root_subset_exceptions).
#          Without --runtime the manifest says runtime "not-captured": the runtime facts, the R1 root
#          witness among them, are then absent, and absent evidence cannot close anything. The headers
#          default to each SDK's AppKit.h; the --*-header options replace that list (fixtures). Each SDK
#          is identified by its pinned archive's SHA-256 (recomputed from the cached archive) and a digest
#          of its extracted header tree, so a cache edited after extraction does not keep the pin's name.
#          The extractor identity names, and digests, only the compiler resource headers the parse
#          consumed (the producer reports them): host packages that ship different extra headers
#          (clang22-cross adds arm_*.h) are the same input, and an edit to a consumed one is not.
#          verify recomputes every hash and row count the manifest lists and refuses an unlisted file.
#          lookup prints what the reference says about CLASS KIND SELECTOR: one floor-sdk, one
#          floor-runtime and one newer-sdk line. It is a reading aid for reviewers and tests, not the
#          classifier: it walks declared superclasses only and treats protocol members as declarations.
#          Exit 0 done, 2 usage, 4 cannot measure (nothing is left at NEW_DIR).
set -eu
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH SDKROOT CCC_OVERRIDE_OPTIONS
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
. "$HERE/sdk-pins.sh"

# spec: tools/objc-runtime-inventory.m header -- the floor host and the capture's reviewed inputs.
FLOOR_OS=10.9.5
FLOOR_BUILD=13F1911
FLOOR_ARCH=x86_64
FLOOR_IMAGES='/usr/lib/libobjc.A.dylib
/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation
/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit
/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon
/System/Library/Frameworks/CoreData.framework/Versions/A/CoreData
/System/Library/Frameworks/QuartzCore.framework/Versions/A/QuartzCore
/System/Library/Frameworks/QuartzCore.framework/Versions/A/Frameworks/CoreImage.framework/Versions/A/CoreImage
/System/Library/Frameworks/CFNetwork.framework/Versions/A/CFNetwork'
# platform: Carbon is in the closure because a Recaulk provider links it (AppKit, Carbon strongly loaded),
#           so its consumers depend on it; capturing it puts every class it brings into the witness.
#           CFNetwork is in it because Foundation's NSURLSession classes dispatch to CFNetwork's
#           __NSCFURLSession family once initialized (INITIALIZE_CHANGES); its methods are measured.
# platform: the classes whose +initialize changes their superclass or method lists on 10.9.5 13F1911,
#           in byte order. Foundation's six NSURLSession classes each move under CFNetwork's
#           __NSCF-prefixed class of the same name; CFNetwork's three in-memory stores move under
#           NSHTTPCookieStorage, NSURLCache and NSURLCredentialStorage. The capture measures them
#           initialized (tools/objc-runtime-inventory.m header); a capture whose set differs is
#           refused, never auto-accepted.
INITIALIZE_CHANGES='NSURLSession NSURLSessionConfiguration NSURLSessionDataTask NSURLSessionDownloadTask NSURLSessionTask NSURLSessionUploadTask __NSCFMemoryHTTPCookieStorage __NSCFMemoryURLCache __NSCFMemoryURLCredentialStorage'
# platform: the R1 root-method witness's reviewed selector list (design revision R1 in the plan, its
#           "R1 selector set"), in byte order. The capture measures both kinds of each. A selector is on
#           it only when the witness measured, for each kind, exactly the reviewed ROOT_EXCEPTIONS as the
#           floor classes that do not resolve it, or the selector is in ROOT_SUBSETS. copy and mutableCopy
#           are off it: NSObject has them, but they answer only through a copyWithZone: the witness does
#           not measure.
ROOT_SELECTORS='autorelease class conformsToProtocol: description hash isEqual: isKindOfClass: isMemberOfClass: performSelector: release respondsToSelector: retain self'
# platform: root selectors whose measured exception sets are strict subsets of ROOT_EXCEPTIONS, one line
#           each: SELECTOR, the reviewed kinds, then the set in byte order, measured on 10.9.5 13F1911.
#           Each listed kind is held to exactly that set; the manifest records it per selector. Object
#           resolves +class but not -class, so only +class is listed: a kind not listed here (-class)
#           is held to ROOT_EXCEPTIONS like every other root selector, and -class measures exactly them.
ROOT_SUBSETS='autorelease +- _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder
class + NSLeafProxy _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder
release +- _NSZombie_ __NSAtom __NSMessageBuilder
retain +- _NSZombie_ __NSAtom __NSMessageBuilder'
# platform: the R1 amendment's accepted residual risk: the floor classes the witness measured as not
#           resolving the root selectors (Object, NSLeafProxy and CoreFoundation's other roots), in
#           byte order. The witness measures existence, so NSProxy-rooted classes are not on it. A
#           capture whose exception set differs from this list is refused, never auto-accepted.
ROOT_EXCEPTIONS='NSLeafProxy Object _NSZombie_ __NSAtom __NSGenericDeallocHandler __NSMessageBuilder'
BEHAVIOR_CLASSES='NSProxy'
# platform: what the behavior rows send each BEHAVIOR_CLASSES instance: root selectors that are safe to
#           send a bare instance (tools/objc-runtime-inventory.m header). The facts are kept; R1 rests on
#           existence alone.
BEHAVIOR_SELECTORS='description isKindOfClass: respondsToSelector:'
# platform: methods the floor must not answer before a provider is linked; one that already resolves
#           on the capture host means a backfill is loaded, and the capture is refused.
ABSENT_TARGETS='NSWorkspace - openURLs:withApplicationAtURL:options:configuration:error:'
TOOL_SRC="$ROOT/tools/objc-runtime-inventory.m"

usage() { echo "usage: objc-reference-set.sh capture|capture-tool|dyld-check|build|verify|lookup ... (see the header)" >&2; exit 2; }
fail() { echo "objc-reference-set: $*" >&2; exit 4; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
# spec: scripts/objc-reference-set.sh header -- a manifest value must be plain: no quote,
#       backslash or control byte to escape.
plain() { printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9 ._:;/()+,=-]*$' || fail "unexpected byte in manifest value: $1"; }

host_build() {  # $1 output; builds the capture tool for this host's arch against its pinned SDK
  case "$(uname -m)" in
    x86_64) a=x86_64; f=10.9 ;;
    arm64) a=arm64; f=11.0 ;;
    *) fail 'unsupported host architecture' ;;
  esac
  [ -x /usr/bin/clang ] || fail '/usr/bin/clang is required'
  host_sdk=$(sh "$HERE/fetch_sdk.sh" --arch "$a") || fail 'cannot fetch the pinned host SDK'
  # platform: env -i keeps CPATH, SDKROOT and every DYLD_* variable away from the compiler.
  env -i PATH=/usr/bin:/bin /usr/bin/clang -std=gnu99 -Wall -Wextra -Werror -arch "$a" \
    -mmacosx-version-min="$f" -isysroot "$host_sdk" "$TOOL_SRC" \
    -framework Foundation -framework Security -lobjc -o "$1" || fail 'capture tool build failed'
}

new_dir() {  # $1 destination; prints a fresh sibling to fill and rename into place
  [ -n "$1" ] || usage
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "refusing an existing destination: $1"
  parent=$(dirname -- "$1")
  [ -d "$parent" ] || fail "no such directory: $parent"
  mktemp -d "$parent/.objc-reference.XXXXXX" || fail "cannot create beside $1"
}

# spec: scripts/objc-reference-set.sh header -- dyld-check: NAME=VALUE lines on stdin, any DYLD_* refused.
dyld_check() {
  dyld=$(sed -n 's/^\(DYLD_[A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' ')
  [ -z "$dyld" ] || fail "refusing to capture with dyld variables set: $dyld"
}

capture() {
  out= diagnostic= overrides= reason=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output) [ "$#" -ge 2 ] && [ -z "$out" ] || usage; out=$2; shift 2 ;;
      --diagnostic) diagnostic=--diagnostic; shift ;;
      --floor-framework-override)
        [ "$#" -ge 2 ] || usage
        ov_name=${2%%=*} ov_src=${2#*=}
        printf '%s' "$ov_name" | LC_ALL=C grep -Eq '^[A-Za-z0-9]+$' || usage
        case "$ov_src" in /*) ;; *) usage ;; esac
        case "$2" in *=*) ;; *) usage ;; esac
        case " $overrides " in *" $ov_name="*) usage ;; esac
        overrides="${overrides:+$overrides
}$ov_name=$ov_src"
        shift 2 ;;
      --override-reason) [ "$#" -ge 2 ] && [ -z "$reason" ] && [ -n "$2" ] || usage; reason=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$out" ] || usage
  [ -z "$overrides" ] && [ -z "$reason" ] || { [ -n "$overrides" ] && [ -n "$reason" ]; } || usage
  [ -z "$reason" ] || plain "$reason"
  env | dyld_check || exit 4
  work=$(new_dir "$out")
  trap 'rm -rf "$work"' EXIT
  host_build "$work/objc-runtime-inventory"
  # platform: the first line of `clang --version`, every byte outside the plain set made `_`; a
  #           `sed -n s///p` would print nothing for Apple's clang-600 line, which needs no change.
  compiler=$(/usr/bin/clang --version 2>/dev/null | sed -n '1{s/[^A-Za-z0-9._()+-]/_/g;p;}')
  [ -n "$compiler" ] || fail 'cannot identify /usr/bin/clang'
  set -- --os "$FLOOR_OS" --build "$FLOOR_BUILD" --arch "$FLOOR_ARCH" --require-signed $diagnostic \
    --identity tool-source-sha256 "$(sha "$TOOL_SRC")" \
    --identity tool-compiler "$compiler" \
    --identity host-sdk-sha256 "$(shipyard_sdk_pin "$FLOOR_ARCH" | cut -d' ' -f2)"
  for i in $FLOOR_IMAGES; do set -- "$@" --require "$i"; done
  for s in $ROOT_SELECTORS; do set -- "$@" --root-selector "$s"; done
  for c in $BEHAVIOR_CLASSES; do set -- "$@" --behavior-class "$c"; done
  for s in $BEHAVIOR_SELECTORS; do set -- "$@" --behavior-selector "$s"; done
  # shellcheck disable=SC2086  # three words: CLASS KIND SELECTOR
  set -- "$@" --absent $ABSENT_TARGETS
  fwdir=
  if [ -n "$overrides" ]; then
    fwdir="$(cd "$work" && pwd -P)/frameworks"
    while IFS= read -r ov; do
      ov_name=${ov%%=*} ov_src=${ov#*=}
      [ -f "$ov_src" ] && [ -r "$ov_src" ] || fail "override source $ov_src is not a readable file"
      plain "$ov_src"
      # spec: scripts/objc-reference-set.sh header -- the private bundle is the system framework's
      #       Versions/A (resources, Info.plist and all) with the override binary in place of the
      #       system one; nothing is written outside the work directory.
      sys="/System/Library/Frameworks/$ov_name.framework/Versions/A"
      dest="$fwdir/$ov_name.framework/Versions/A"
      mkdir -p "$fwdir/$ov_name.framework/Versions" || fail 'cannot create the private framework'
      if [ -d "$sys" ]; then cp -R "$sys" "$dest" || fail "cannot copy $sys"
      else mkdir "$dest" || fail 'cannot create the private framework'
      fi
      rm -f "$dest/$ov_name" "$dest/$ov_name.original"
      cp "$ov_src" "$dest/$ov_name" || fail "cannot copy $ov_src"
      ln -s A "$fwdir/$ov_name.framework/Versions/Current"
      # platform: Security compiles requirement text through its PlugIns/csparser.bundle, found via the
      #           bundle's top-level PlugIns link; without that link SecRequirementCreateWithString
      #           fails with paramErr (-50). So every top-level link and file is mirrored.
      for e in "/System/Library/Frameworks/$ov_name.framework"/*; do
        [ -e "$e" ] || [ -L "$e" ] || continue
        b=${e##*/}
        [ "$b" != Versions ] || continue
        if [ -L "$e" ]; then ln -s "$(readlink "$e")" "$fwdir/$ov_name.framework/$b"
        elif [ -f "$e" ]; then cp "$e" "$fwdir/$ov_name.framework/$b"
        fi || fail "cannot mirror $e"
      done
      [ -e "$fwdir/$ov_name.framework/$ov_name" ] || ln -s "Versions/Current/$ov_name" "$fwdir/$ov_name.framework/$ov_name"
      # platform: 10.9.5's codesign rejects its own system frameworks' bundle resources ("resource
      #           envelope is obsolete"), and a framework binary verified under any other file name
      #           cannot bind its Info.plist. So the code is checked in the private bundle, under its
      #           own name, with the Info.plist binding and every code page, resources aside. codesign
      #           links the very framework being replaced, so the check runs under the system copy and
      #           again under the private one; both must pass.
      codesign -v --ignore-resources -R='anchor apple' "$dest/$ov_name" 2>"$work/codesign.log" &&
        env DYLD_FRAMEWORK_PATH="$fwdir" codesign -v --ignore-resources -R='anchor apple' "$dest/$ov_name" 2>>"$work/codesign.log" ||
        { cat "$work/codesign.log" >&2; fail "override source $ov_src is not Apple-signed code"; }
      ov_sha=$(sha "$ov_src")
      [ "$(sha "$dest/$ov_name")" = "$ov_sha" ] || fail "the private copy of $ov_src differs from it"
      set -- "$@" --override "$ov_name" "$fwdir" "$ov_sha" "$ov_src" "$reason"
    done <<EOF_OVERRIDES
$overrides
EOF_OVERRIDES
  fi
  # platform: DYLD_FRAMEWORK_PATH is set here, by the wrapper, only for a declared and verified
  #           override; the tool accepts exactly that directory and refuses any other dyld variable.
  env -i PATH=/usr/bin:/bin ${fwdir:+"DYLD_FRAMEWORK_PATH=$fwdir"} "$work/objc-runtime-inventory" "$@" \
    --runtime-output "$work/floor-runtime.tsv" --cluster-output "$work/cluster-witnesses.json" ||
    fail 'the runtime capture was refused (reasons above)'
  rm -rf "$work/objc-runtime-inventory" "$work/frameworks" "$work/codesign.log"
  mv "$work" "$out" || fail "cannot move the capture into $out"
  trap - EXIT
  echo "objc-reference-set: captured $(($(wc -l <"$out/floor-runtime.tsv") - 1)) runtime rows into $out" >&2
}

# spec: scripts/objc-reference-set.sh header -- build accepts a capture only when it is production,
#       has no refusal, the floor identity and the current tool source, every reviewed input, and
#       only signed system images, and whose witness exceptions are the reviewed ROOT_EXCEPTIONS for
#       every root selector and kind, or for a ROOT_SUBSETS selector's listed kinds its own set.
check_runtime() {  # $1 capture dir
  rt="$1/floor-runtime.tsv" cw="$1/cluster-witnesses.json"
  [ -r "$rt" ] && [ -r "$cw" ] || fail "unreadable runtime capture in $1"
  [ "$(head -1 "$rt")" = '# objc-runtime 1' ] || fail "$rt: not an objc-runtime 1 capture"
  tail -n +2 "$rt" | awk -F '\t' 'NF != 7 {exit 1}' || fail "$rt: a row without exactly seven columns"
  body=$(mktemp "${TMPDIR:-/tmp}/objc-runtime-body.XXXXXX") || fail "cannot create a temporary"
  tail -n +2 "$rt" >"$body"
  LC_ALL=C sort -u "$body" | cmp -s - "$body" || { rm -f "$body"; fail "$rt: rows are not sorted and unique"; }
  rm -f "$body"
  head -c 64 "$cw" | grep -q '^{' && grep -q '^  "schema": 1,$' "$cw" || fail "$cw: not a schema-1 cluster witness"
  want_images=$(printf '%s\n' "$FLOOR_IMAGES" | tr '\n' ' ')
  awk -F '\t' -v os="$FLOOR_OS" -v build="$FLOOR_BUILD" -v arch="$FLOOR_ARCH" -v tool="$(sha "$TOOL_SRC")" \
      -v roots="$ROOT_SELECTORS" -v behave="$BEHAVIOR_CLASSES" -v probes="$BEHAVIOR_SELECTORS" -v absent="$ABSENT_TARGETS" -v images="$want_images" '
    function bad(m) { print m > "/dev/stderr"; failed = 1 }
    NR == 1 { next }
    $1 == "identity" { id[$2] = $5 }
    $1 == "check" && $2 == "refusal" { bad("capture records a refusal: " $5) }
    $1 == "check" && $2 != "refusal" && $2 != "root-selector" && $2 != "absent" { chk[$2] = $5 }
    $1 == "check" && $2 == "root-selector" { gotroot[$4] = 1; nroot++ }
    $1 == "check" && $2 == "absent" { gotabsent[substr($7, 2) " " substr($7, 1, 1) " " $4] = $5 }
    $1 == "image" && $6 == "required" { req[$4] = 1 }
    $1 == "image" && $6 == "fixture" { bad("capture loaded fixture image " $2) }
    $1 == "image" && $6 != "self" && $7 != "anchor-apple" { bad("image " $2 " is " $7 ", not anchor-apple") }
    $1 == "image" && $6 == "override" { ovimage[$2] = 1 }
    $1 == "image" && $6 != "override" { sysimage[$2] = $4 }
    $1 == "override" { ov[$2] = $7; ovsha[$2] = $5; nov++ }
    $1 == "check" && $2 == "override-reason" { ovreason[$4] = $5 }
    $1 == "behavior" { gotbehave[$2 " " $4]++ }
    $1 == "witness" { witnesses++ }
    END {
      if (id["os"] != os || id["build"] != build || id["arch"] != arch)
        bad("capture identity " id["os"] " " id["build"] " " id["arch"] ", floor is " os " " build " " arch)
      if (id["tool-source-sha256"] != tool) bad("capture came from another tool source (" id["tool-source-sha256"] "); recapture")
      if (chk["mode"] != "production") bad("capture mode is " chk["mode"] ", not production")
      if (chk["dyld-environment"] == "framework-override") { if (!nov) bad("capture has a framework-override environment without a recorded override") }
      else if (chk["dyld-environment"] != "none") bad("capture saw a dyld environment")
      for (o in ov) {
        if (ov[o] != "anchor-apple") bad("override " o " is " ov[o] ", not anchor-apple")
        if (length(ovsha[o]) != 64 || ovsha[o] ~ /[^0-9a-f]/) bad("override " o " has no SHA-256")
        if (ovreason[o] == "") bad("override " o " has no reason")
        if (!ovimage[o]) bad("override " o " did not load")
        if (sysimage[o] ~ ("/" o "\\.framework/")) bad(o " is also loaded from the system")
      }
      for (o in ovimage) if (!(o in ov)) bad("image " o " is an unrecorded override")
      if (chk["nonsystem-images"] != "none" || chk["fixture-images"] != "none") bad("capture loaded non-system images")
      if (chk["recaulk"] != "absent") bad("capture saw Recaulk")
      if (chk["signatures"] != "required") bad("capture did not require signatures")
      n = split(roots, r, " "); for (i = 1; i <= n; i++) if (!gotroot[r[i]]) bad("root selector " r[i] " not captured")
      if (nroot != n) bad("capture has a different root selector list")
      n = split(behave, b, " "); k = split(probes, p, " ")
      for (i = 1; i <= n; i++) for (j = 1; j <= k; j++) if (!gotbehave[b[i] " " p[j]]) bad("behavior of " b[i] " not captured for " p[j])
      if (gotabsent[absent] != "absent") bad("absent target not checked absent: " absent)
      n = split(images, m, " "); for (i = 1; i <= n; i++) if (!req[m[i]]) bad("required image " m[i] " not loaded")
      if (!witnesses) bad("capture has no root witness")
      exit failed
    }' "$rt" || fail "refusing runtime capture $1"
  changes=$(awk -F '\t' '$1 == "check" && $2 == "initialize" {print $4}' "$rt" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')
  [ "$changes" = "$INITIALIZE_CHANGES" ] ||
    fail "refusing runtime capture $1: its classes changed by +initialize $changes are not the reviewed $INITIALIZE_CHANGES"
  exceptions=$(awk -F '\t' '$1 == "witness" && $5 == "-" {print $2}' "$rt" | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')
  [ "$exceptions" = "$ROOT_EXCEPTIONS" ] ||
    fail "refusing runtime capture $1: its witness exceptions $exceptions are not the reviewed $ROOT_EXCEPTIONS"
  # platform: the same set for every selector and kind, not only in union: a selector whose own exception
  #           set is another one, smaller or larger, is not the reviewed residual risk for that selector.
  #           A ROOT_SUBSETS selector's listed kinds are held to its recorded set instead; a kind it does
  #           not list is held to the six.
  printf '%s\n' "$ROOT_SUBSETS" | awk -v six="$ROOT_EXCEPTIONS" -v roots="$ROOT_SELECTORS" '
    BEGIN { n = split(six, x, " "); for (i = 1; i <= n; i++) reviewed[x[i]] = 1
            m = split(roots, r, " "); for (i = 1; i <= m; i++) root[r[i]] = 1 }
    { if (!root[$1] || ($2 != "+-" && $2 != "+" && $2 != "-") || NF - 2 >= n || seen[$1]++) bad = 1
      for (i = 3; i <= NF; i++) if (!reviewed[$i]) bad = 1 }
    END { exit bad }' || fail 'ROOT_SUBSETS must give root selectors strict subsets of ROOT_EXCEPTIONS'
  for s in $ROOT_SELECTORS; do for k in + -; do
    want=$ROOT_EXCEPTIONS
    sub=$(printf '%s\n' "$ROOT_SUBSETS" | awk -v s="$s" '$1 == s')
    if [ -n "$sub" ]; then
      case "$(printf '%s\n' "$sub" | cut -d' ' -f2)" in *"$k"*) want=$(printf '%s\n' "$sub" | cut -d' ' -f3-) ;; esac
    fi
    got=$(awk -F '\t' -v s="$s" -v k="$k" '$1 == "witness" && $3 == k && $4 == s && $5 == "-" {print $2}' "$rt" |
      LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//')
    awk -F '\t' -v s="$s" -v k="$k" '$1 == "witness" && $3 == k && $4 == s {f = 1} END {exit !f}' "$rt" || continue
    [ "$got" = "$want" ] ||
      fail "refusing runtime capture $1: its $k$s witness exceptions $got are not the reviewed $want"
  done; done
}

tree_digest() {  # $1 directory; digest of every header-like file, by relative path
  (cd "$1" && find . -type f \( -path '*/Headers/*' -o -path './usr/include/*' -o -path './include/*' -o -name '*.modulemap' \) |
    LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum -a 256) | shasum -a 256 | cut -c1-64
}

sdk_facts() {  # $1 arch  $2 floor|newer  $3 work  $4 header list file (empty: AppKit.h)
  sf_arch=$1 sf_side=$2 sf_work=$3 sf_list=$4
  sf_pin=$(shipyard_sdk_pin "$sf_arch") || fail "no SDK pin for $sf_arch"
  sf_sha=$(printf '%s\n' "$sf_pin" | cut -d' ' -f2)
  sf_tarball=$(printf '%s\n' "$sf_pin" | cut -d' ' -f3)
  sf_sdk=$(sh "$HERE/fetch_sdk.sh" --arch "$sf_arch") || fail "cannot fetch the pinned $sf_arch SDK"
  sf_archive="$(dirname -- "$sf_sdk")/$sf_tarball"
  [ -r "$sf_archive" ] || fail "the pinned archive $sf_tarball is not beside $sf_sdk; it cannot be attested"
  [ "$(sha "$sf_archive")" = "$sf_sha" ] || fail "$sf_archive does not match its pin"
  if [ -s "$sf_list" ]; then cp "$sf_list" "$sf_work/$sf_side.args"
  else printf '%s\n' "$sf_sdk/System/Library/Frameworks/AppKit.framework/Headers/AppKit.h" >"$sf_work/$sf_side.args"
  fi
  : >"$sf_work/$sf_side.headers"
  sf_n=0
  set -- --clang-prefix "$prefix" --sdk "$sf_sdk" --signature-output "$sf_work/$sf_side-signatures.tsv"
  while IFS= read -r sf_h; do
    sf_n=$((sf_n + 1))
    [ -r "$sf_h" ] && [ -f "$sf_h" ] || fail "unreadable header $sf_h"
    case "$sf_h" in
      "$sf_sdk"/*) printf '%s\n' "${sf_h#"$sf_sdk"/}" >>"$sf_work/$sf_side.headers" ;;
      *) printf 'input/%s sha256:%s\n' "$sf_n" "$(sha "$sf_h")" >>"$sf_work/$sf_side.headers" ;;
    esac
    set -- "$@" --header "$sf_h"
  done <"$sf_work/$sf_side.args"
  sh "$HERE/objc-sdk-inventory.sh" "$@" >"$sf_work/$sf_side-sdk.tsv" 2>"$sf_work/$sf_side.log" ||
    { tail -5 "$sf_work/$sf_side.log" >&2; fail "the $sf_side SDK producer failed"; }
  sed -n 's/^objc-sdk-inventory: resource-header //p' "$sf_work/$sf_side.log" >"$sf_work/$sf_side.resources"
  printf '%s %s %s\n' "$sf_tarball" "$sf_sha" "$(tree_digest "$sf_sdk")" >"$sf_work/$sf_side.identity"
}

json_list() {  # lines on stdin -> "a", "b"
  first=1
  while IFS= read -r v; do
    plain "$v"
    [ "$first" = 1 ] || printf ', '
    printf '"%s"' "$v"
    first=0
  done
}

rows() { if [ "$(head -c 1 "$1")" = '#' ]; then echo $(($(wc -l <"$1") - 1)); else wc -l <"$1" | tr -d ' '; fi; }

build() {
  prefix= out= runtime=
  floor_list= newer_list=
  tmpl=$(mktemp -d "${TMPDIR:-/tmp}/objc-reference-args.XXXXXX") || fail 'cannot create a temporary'
  trap 'rm -rf "$tmpl"' EXIT
  : >"$tmpl/floor"; : >"$tmpl/newer"
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --clang-prefix) [ -z "$prefix" ] || usage; prefix=$2 ;;
      --output) [ -z "$out" ] || usage; out=$2 ;;
      --runtime) [ -z "$runtime" ] || usage; runtime=$2 ;;
      --floor-header) printf '%s\n' "$2" >>"$tmpl/floor" ;;
      --newer-header) printf '%s\n' "$2" >>"$tmpl/newer" ;;
      *) usage ;;
    esac
    shift 2
  done
  [ -n "$prefix" ] && [ -n "$out" ] || usage
  [ -z "$runtime" ] || check_runtime "$runtime"
  work=$(new_dir "$out")
  trap 'rm -rf "$tmpl" "$work"' EXIT
  sdk_facts x86_64 floor "$work" "$tmpl/floor"
  sdk_facts arm64 newer "$work" "$tmpl/newer"
  resource=$("$prefix/bin/clang" -print-resource-dir) || fail 'cannot query the compiler resource directory'
  clang_version=$("$prefix/bin/clang" --version | head -1)
  package=$(tr -d '[:space:]' <"$ROOT/components/objc-reference-clang/version")
  if [ -n "$runtime" ]; then
    cp "$runtime/floor-runtime.tsv" "$runtime/cluster-witnesses.json" "$work/" || fail 'cannot copy the runtime capture'
  fi
  m="$work/manifest.json.new"
  {
    printf '{\n  "schema": 1,\n'
    for side in floor newer; do
      read -r archive archive_sha tree <"$work/$side.identity"
      # spec: tools/README.objc-sdk-inventory.md -- the parsed target is x86_64-apple-macos10.9 for both SDKs.
      target=x86_64-apple-macos10.9
      plain "$archive"
      printf '  "%s_sdk": {\n' "$side"
      printf '    "archive": "%s",\n    "archive_sha256": "%s",\n    "header_tree_sha256": "%s",\n' "$archive" "$archive_sha" "$tree"
      printf '    "headers": [%s],\n' "$(json_list <"$work/$side.headers")"
      printf '    "parsed_target": "%s",\n    "facts": "%s-sdk.tsv",\n    "signatures": "%s-signatures.tsv"\n  },\n' "$target" "$side" "$side"
    done
    plain "$clang_version"; plain "$package"
    printf '  "extractor": {\n'
    printf '    "producer_sha256": "%s",\n' "$(sha "$ROOT/tools/objc-sdk-inventory.c")"
    printf '    "wrapper_sha256": "%s",\n' "$(sha "$HERE/objc-sdk-inventory.sh")"
    printf '    "clang_package": "%s",\n    "clang_version": "%s",\n' "$package" "$clang_version"
    LC_ALL=C sort -u "$work/floor.resources" "$work/newer.resources" >"$work/consumed.resources"
    printf '    "consumed_resource_headers": [%s],\n' "$(json_list <"$work/consumed.resources")"
    printf '    "consumed_resource_headers_sha256": "%s"\n  },\n' "$(while IFS= read -r f; do (cd "$resource" && shasum -a 256 "./$f"); done <"$work/consumed.resources" | shasum -a 256 | cut -c1-64)"
    if [ -n "$runtime" ]; then
      rt="$work/floor-runtime.tsv"
      ident() { awk -F '\t' -v k="$1" '$1 == "identity" && $2 == k {print $5}' "$rt"; }
      printf '  "runtime_status": "captured",\n  "runtime": {\n'
      for k in os build arch tool-source-sha256 tool-compiler host-sdk-sha256; do
        v=$(ident "$k"); plain "$v"
        printf '    "%s": "%s",\n' "$(printf '%s' "$k" | tr '-' '_')" "$v"
      done
      printf '    "root_selectors": [%s],\n' "$(printf '%s\n' $ROOT_SELECTORS | json_list)"
      printf '    "root_exceptions": [%s],\n' "$(printf '%s\n' $ROOT_EXCEPTIONS | json_list)"
      subjson=$(printf '%s\n' "$ROOT_SUBSETS" | while read -r s k e; do
        printf '{"selector": "%s", "kinds": [%s], "exceptions": [%s]}\n' "$s" \
          "$(printf '%s\n' "$k" | fold -w1 | json_list)" "$(printf '%s\n' $e | json_list)"
      done | awk '{printf "%s%s", (NR > 1 ? ", " : ""), $0}')
      printf '    "root_subset_exceptions": [%s],\n' "$subjson"
      printf '    "behavior_classes": [%s],\n' "$(printf '%s\n' $BEHAVIOR_CLASSES | json_list)"
      printf '    "absent_targets": [%s],\n' "$(printf '%s\n' "$ABSENT_TARGETS" | json_list)"
      awk -F '\t' '$1 == "override" || ($1 == "check" && $2 == "override-reason")' "$rt" | cut -f2,4,5,7 | tr '\t' '\n' |
        while IFS= read -r v; do plain "$v"; done || exit 4
      # platform: bash 3.2 splits a "$(...)" whose awk program holds \" into several words, so the
      #           quote is made from its code (34) and the result taken by plain assignment.
      ovjson=$(awk -F '\t' '
        BEGIN { q = sprintf("%c", 34) }
        $1 == "check" && $2 == "override-reason" { r[$4] = $5 }
        $1 == "override" {
          printf "%s{%sframework%s: %s%s%s, %ssource%s: %s%s%s, %ssha256%s: %s%s%s, %ssignature%s: %s%s%s, %sreason%s: %s%s%s}",
            (n++ ? ", " : ""), q, q, q, $2, q, q, q, q, $4, q, q, q, q, $5, q, q, q, q, $7, q, q, q, q, r[$2], q }' "$rt")
      printf '    "framework_overrides": [%s],\n' "$ovjson"
      printf '    "required_images": [\n'
      awk -F '\t' '$1 == "image" && $6 == "required" {print $4 " " $5}' "$rt" | LC_ALL=C sort | {
        first=1
        while read -r p u; do
          plain "$p"; plain "$u"
          [ "$first" = 1 ] || printf ',\n'
          printf '      {"path": "%s", "uuid": "%s"}' "$p" "$u"
          first=0
        done
        printf '\n'
      }
      printf '    ],\n'
      printf '    "loaded_images": %s,\n' "$(awk -F '\t' '$1 == "image"' "$rt" | wc -l | tr -d ' ')"
      printf '    "loaded_images_sha256": "%s",\n' "$(awk -F '\t' '$1 == "image"' "$rt" | shasum -a 256 | cut -c1-64)"
      printf '    "facts": "floor-runtime.tsv",\n    "cluster_witnesses": "cluster-witnesses.json"\n  },\n'
    else
      printf '  "runtime_status": "not-captured",\n  "runtime": null,\n'
    fi
    printf '  "files": [\n'
    first=1
    for f in cluster-witnesses.json floor-runtime.tsv floor-sdk.tsv floor-signatures.tsv newer-sdk.tsv newer-signatures.tsv; do
      [ -f "$work/$f" ] || continue
      [ "$first" = 1 ] || printf ',\n'
      case "$f" in
        *.json) n=$(grep -c '"id": ' "$work/$f" || :) ;;
        *) n=$(rows "$work/$f") ;;
      esac
      printf '    {"name": "%s", "sha256": "%s", "rows": %s}' "$f" "$(sha "$work/$f")" "$n"
      first=0
    done
    printf '\n  ]\n}\n'
  } >"$m"
  rm -f "$work"/*.identity "$work"/*.args "$work"/*.headers "$work"/*.log "$work"/*.resources
  mv "$m" "$work/manifest.json"
  verify "$work" >/dev/null
  mv "$work" "$out" || fail "cannot move the reference set into $out"
  trap - EXIT
  rm -rf "$tmpl"
  echo "objc-reference-set: built $out" >&2
}

verify() {
  [ "$#" = 1 ] || usage
  d=$1
  [ -r "$d/manifest.json" ] || fail "no readable manifest in $d"
  grep -q '^  "schema": 1,$' "$d/manifest.json" || fail "$d/manifest.json is not schema 1"
  listed=$(sed -n 's/^    {"name": "\([^"]*\)", "sha256": "\([0-9a-f]\{64\}\)", "rows": \([0-9]*\)},\{0,1\}$/\1 \2 \3/p' "$d/manifest.json")
  [ -n "$listed" ] || fail "$d/manifest.json lists no files"
  printf '%s\n' "$listed" | while read -r f h n; do
    [ -f "$d/$f" ] && [ ! -L "$d/$f" ] || fail "$d/$f is missing"
    [ "$(sha "$d/$f")" = "$h" ] || fail "$d/$f does not match the manifest"
    case "$f" in
      *.json) got=$(grep -c '"id": ' "$d/$f" || :) ;;
      *) got=$(rows "$d/$f") ;;
    esac
    [ "$got" = "$n" ] || fail "$d/$f has $got rows, the manifest says $n"
    case "$f" in
      *-signatures.tsv) [ "$(head -1 "$d/$f")" = '# objc-signatures 1' ] || fail "$d/$f lacks its schema line" ;;
      *-sdk.tsv) awk -F '\t' 'NF != 11 {exit 1}' "$d/$f" || fail "$d/$f is not eleven-column facts" ;;
      floor-runtime.tsv) [ "$(head -1 "$d/$f")" = '# objc-runtime 1' ] || fail "$d/$f lacks its schema line" ;;
    esac
  done || exit 4
  for f in "$d"/* "$d"/.[!.]*; do
    [ -e "$f" ] || continue
    b=$(basename -- "$f")
    [ "$b" = manifest.json ] && continue
    printf '%s\n' "$listed" | cut -d' ' -f1 | grep -qxF "$b" || fail "$d/$b is not in the manifest"
  done
  case "$(sed -n 's/^  "runtime_status": "\(.*\)",$/\1/p' "$d/manifest.json")" in
    captured) printf '%s\n' "$listed" | grep -q '^floor-runtime.tsv ' || fail 'runtime captured but not listed' ;;
    not-captured) ! printf '%s\n' "$listed" | grep -q '^floor-runtime.tsv ' || fail 'runtime listed but not captured' ;;
    *) fail "$d/manifest.json has no runtime_status" ;;
  esac
  echo "objc-reference-set: $d verified"
}

lookup() {
  [ "$#" = 4 ] || usage
  d=$1 cls=$2 kind=$3 sel=$4
  case "$kind" in +|-) ;; *) usage ;; esac
  verify "$d" 2>/dev/null || fail "$d does not verify"
  for side in floor newer; do
    awk -F '\t' -v side="$side" -v c="$cls" -v k="$kind" -v s="$sel" '
      $1 == "class" { sup[$3] = $5; intro[$3] = $7; known[$3] = 1 }
      ($1 == "method" || $1 == "property-get" || $1 == "property-set") && $4 == k && $5 == s {
        hit[$3] = $7 "\t" $8 "\t" $9 "\t" $10 "\t" $11 }
      END {
        if (!known[c]) { print side "-sdk\tno-class\t" c; exit }
        for (o = c; o != "-" && o != ""; o = sup[o])
          if (o in hit) { print side "-sdk\tdeclared\t" o "\t" hit[o] "\tclass-introduced\t" intro[c]; exit }
        print side "-sdk\tabsent\t-\tclass-introduced\t" intro[c]
      }' "$d/$side-sdk.tsv"
    if [ "$side" = floor ]; then
      if [ ! -f "$d/floor-runtime.tsv" ]; then
        printf 'floor-runtime\tnot-captured\n'
      else
        awk -F '\t' -v c="$cls" -v k="$kind" -v s="$sel" '
          $1 == "class" { sup[$2] = $4; root[$2] = $5; known[$2] = 1 }
          $1 == "method" { measured[$2] = 1; if ($4 == s && $7 == "active") impl[$2 SUBSEP $3] = $6 }
          $1 == "witness" && $2 == c && $3 == k && $4 == s { w = $5 "\t" $6 "\troot\t" $7 }
          END {
            if (w != "") { split(w, p, "\t"); print "floor-runtime\t" (p[1] == "-" ? "absent" : "resolves") "\t" w "\twitness"; exit }
            if (!known[c]) { print "floor-runtime\tno-class\t" c; exit }
            for (o = c; o != "-"; o = sup[o]) {
              if (!measured[o]) { print "floor-runtime\tunmeasured\t" o; exit }
              if ((o SUBSEP k) in impl) { print "floor-runtime\tresolves\t" k o "\t" impl[o SUBSEP k]; exit }
              if (k == "+" && sup[o] == "-" && ((o SUBSEP "-") in impl)) { print "floor-runtime\tresolves\t-" o "\t" impl[o SUBSEP "-"]; exit }
            }
            print "floor-runtime\tabsent\t-"
          }' "$d/floor-runtime.tsv"
      fi
    fi
  done
}

[ "$#" -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
  capture) capture "$@" ;;
  dyld-check) [ "$#" = 0 ] || usage; dyld_check ;;
  capture-tool) [ "$#" = 2 ] && [ "$1" = --output ] || usage; host_build "$2" ;;
  build) build "$@" ;;
  verify) verify "$@" ;;
  lookup) lookup "$@" ;;
  *) usage ;;
esac
