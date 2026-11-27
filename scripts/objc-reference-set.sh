#!/bin/sh
# platform: macOS-only -- native Apple compiler, the pinned SDKs and libclang for generation
#   usage: objc-reference-set.sh capture --output NEW_DIR [--recipe FILE] [--diagnostic]
#                                        [--floor-framework-override NAME=BINARY --override-reason TEXT]
#          objc-reference-set.sh capture-tool --output FILE
#          objc-reference-set.sh dyld-check   (environment lines on stdin)
#          objc-reference-set.sh build --clang-prefix PREFIX --output NEW_DIR [--recipe FILE] [--runtime CAPTURE_DIR]
#                                      [--floor-header FILE]... [--newer-header FILE]...
#          objc-reference-set.sh verify [--recipe FILE] REF_DIR
#          objc-reference-set.sh lookup REF_DIR CLASS KIND SELECTOR
#          objc-reference-set.sh coverage REF_DIR SDK_ROOT floor|newer
#          objc-reference-set.sh diff OLD_DIR NEW_DIR
#          The versioned Objective-C reference set: SDK declaration facts from the pinned floor (10.9)
#          and newer (11.3) SDKs, and a runtime capture from a real clean floor host, bound together by
#          manifest.json. Apple bytes never enter it, only derived facts and the identities of what
#          they were derived from.
#          Every reviewed input comes from a recipe, --recipe FILE, by default the committed
#          reference/objc-recipes/mavericks-10.9.recipe. A recipe is data, read and never sourced: one
#          KEY VALUE per line (a single space between them, the value to the end of the line), a key
#          repeated for a list, a line starting with # a comment. The keys: name; floor-os, floor-build
#          and floor-arch, the floor host's identity; floor-image, each image of the reviewed closure;
#          floor-sdk-arch and newer-sdk-arch, the arch whose pinned SDK each side parses; floor-header and
#          newer-header, each header parsed, relative to its SDK (or absolute, for fixtures);
#          initialize-change, root-selector, root-exception, behavior-class and behavior-selector, each a
#          member of that reviewed list; root-subset, one line per selector (SELECTOR KINDS CLASS...);
#          absent-target (CLASS KIND SELECTOR); and floor-framework-override (NAME=BINARY), as the
#          option. All but initialize-change, root-subset and floor-framework-override are required, and
#          name, the floor identity, the SDK arches and absent-target are given once. Each value has one
#          form (a selector, a class, an absolute image path, a path without .. and so on); a recipe with
#          an unknown key, a missing or repeated one, or a value outside its key's form is refused whole.
#          capture runs tools/objc-runtime-inventory.m on the recipe's floor host with its image
#          closure, root selectors, behavior classes and selectors and absent target, and writes
#          NEW_DIR/{floor-runtime.tsv,cluster-witnesses.json}. It refuses a DYLD_* environment before
#          building anything; the tool refuses everything else it documents. --diagnostic keeps an
#          unclean host's capture for inspection; build never accepts one.
#          --floor-framework-override is the one sanctioned exception, for a floor host whose system
#          framework NAME was replaced (on the reference host AquaTransport replaced Security): BINARY
#          (there, the preserved Security.original) goes into a private copy of the system
#          framework in the work directory, must verify there as Apple-signed code, and is loaded
#          through DYLD_FRAMEWORK_PATH set by this wrapper alone; the tool then proves it loaded
#          from that copy with the recorded SHA-256 and that no system copy or injected image did.
#          The override, its source, hash, signature and the reason go into the manifest. The
#          recipe's overrides join the option's; either needs --override-reason. capture-tool only builds the
#          tool (the tests drive it with fixtures). dyld-check applies capture's DYLD_* refusal
#          to NAME=VALUE lines on stdin: a SIP host strips DYLD_* from any protected exec, /bin/sh
#          included, so the tests show it an environment that way.
#          build writes NEW_DIR/{floor-sdk.tsv,floor-signatures.tsv,floor-functions.tsv,newer-sdk.tsv,
#          newer-signatures.tsv,manifest.json}, plus floor-runtime.tsv and cluster-witnesses.json when
#          --runtime names a capture that is production, clean, from the recipe's floor identity and from the
#          current tool source, whose classes changed by +initialize are exactly the recipe's initialize-change,
#          and whose R1 witness exceptions are exactly its root-exception for every root selector and kind,
#          but for the selectors and kinds of a root-subset, each held exactly to its own recorded set
#          (the manifest records them as root_exceptions and root_subset_exceptions), and whose framework
#          overrides (NAME=SOURCE) are exactly the recipe's floor-framework-override list.
#          The manifest names the recipe as recipe {name, sha256}, and each SDK side lists as
#          reached_headers every header below its SDK the parse entered (the producer reports them),
#          resolved and SDK-relative, sorted: what the facts can speak for.
#          Without --runtime the manifest says runtime "not-captured": the runtime facts, the R1 root
#          witness among them, are then absent, and absent evidence cannot close anything. The headers
#          are the recipe's floor-header and newer-header lists; the --*-header options replace a
#          side's list (fixtures). The signature companions are schema 2; the floor
#          side alone also writes the C prototype catalog (floor-functions.tsv, "# objc-functions 1"):
#          every function its parse declares, outside the compiler's own resource headers. Beside it goes
#          floor-functions-builtin.tsv, the same five columns, copied verbatim from the committed
#          reference/objc and never generated: the reviewed runtime calls the compiler emits, which no
#          header declares. A name in both catalogs is refused (verify, and the analyzer's loader).
#          Each SDK is identified by its pinned archive's SHA-256 (recomputed from the cached archive) and a digest
#          of its extracted header tree, so a cache edited after extraction does not keep the pin's name. The digest
#          is drydock-objc's (evidence --sdk-digest-only), the one analyze checks sdk: citations against; build
#          runs the drydock-objc that DRYDOCK_OBJC names.
#          The extractor identity names, and digests, only the compiler resource headers the parse
#          consumed (the producer reports them): host packages that ship different extra headers
#          (clang22-cross adds arm_*.h) are the same input, and an edit to a consumed one is not.
#          verify recomputes every hash and row count the manifest lists and refuses an unlisted file;
#          given --recipe, it also refuses a manifest that names another recipe's SHA-256.
#          lookup prints what the reference says about CLASS KIND SELECTOR: one floor-sdk, one
#          floor-runtime and one newer-sdk line. It is a reading aid for reviewers and tests, not the
#          classifier: it walks declared superclasses only and treats protocol members as declarations.
#          coverage prints, for the side's SDK tree under SDK_ROOT (the directory its archive name
#          names, without .tar.xz), one row per unit: UNIT, its .h files, how many of them the side
#          reached, and the first in byte order it did not (or -), TAB-separated and sorted by UNIT. A
#          unit is the innermost NAME.framework holding the file, else the file's directory. A reached
#          header missing from that tree is refused: the tree is not the one parsed.
#          diff reports what changed between two reference sets (OLD_DIR, NEW_DIR), each file read as a
#          set, so a reordering alone reports nothing. One line per change, TAB-separated:
#          ADDED|REMOVED|CHANGED, FILE, KEY, DETAIL, sorted by FILE then KEY (LC_ALL=C). KEY is the
#          row's identity, its fields joined by spaces: for floor-sdk.tsv and newer-sdk.tsv, kind, unit,
#          class, method kind, selector and container; for the signature files the same five and the
#          container; for the function files, the name; for floor-runtime.tsv, class and kind and
#          selector (and image) per row kind (class, method, witness, check, behavior, image,
#          override, identity). A row's other columns are its DETAIL: CHANGED shows each differing
#          one as NAME old -> new (an availability change among them), ADDED and REMOVED show them all.
#          A key a file repeats takes #2, #3 and so on in row order. A file one set lacks reads as empty.
#          The JSON files compare by top-level key (a block's entries named by name or id): manifest.json
#          reports each changed identity (recipe, SDK pins, clang, runtime) as KEY old -> new, a block
#          such as reached_headers as one line of counts. A summary line per changed FILE follows, FILE,
#          +ADDED, -REMOVED, ~CHANGED. Exit 0 whatever it found: a diff is a report, not a failure.
#          Exit 0 done, 2 usage, 4 cannot measure (nothing is left at NEW_DIR).
set -eu
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH SDKROOT CCC_OVERRIDE_OPTIONS
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
. "$HERE/sdk-pins.sh"

RECIPE="$ROOT/reference/objc-recipes/mavericks-10.9.recipe"
TOOL_SRC="$ROOT/tools/objc-runtime-inventory.m"

usage() { echo "usage: objc-reference-set.sh capture|capture-tool|dyld-check|build|verify|lookup|coverage|diff ... (see the header)" >&2; exit 2; }
fail() { echo "objc-reference-set: $*" >&2; exit 4; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
# spec: scripts/objc-reference-set.sh header -- a manifest value must be plain: no quote,
#       backslash or control byte to escape.
plain() { printf '%s' "$1" | LC_ALL=C grep -Eq '^[A-Za-z0-9 ._:;/()+,=-]*$' || fail "unexpected byte in manifest value: $1"; }

# spec: scripts/objc-reference-set.sh header -- a recipe is data: every key has one form, and a line
#       outside it, an unknown key, a missing key or a repeated single key refuses the whole recipe.
recipe_check() {
  [ -f "$RECIPE" ] && [ -r "$RECIPE" ] || fail "unreadable recipe $RECIPE"
  LC_ALL=C awk -v file="$RECIPE" '
    function bad(m) { print "objc-reference-set: " file ": " m > "/dev/stderr"; failed = 1 }
    BEGIN {
      id = "[A-Za-z_][A-Za-z0-9_]*"; sel = "[A-Za-z_][A-Za-z0-9_:]*"; path = "[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*"
      form["name"] = "[A-Za-z0-9._-]+"
      form["floor-os"] = "[0-9]+(\\.[0-9]+)*"
      form["floor-build"] = "[A-Za-z0-9]+"
      form["floor-arch"] = form["floor-sdk-arch"] = form["newer-sdk-arch"] = "[a-z0-9_]+"
      form["floor-image"] = "/" path
      form["floor-header"] = form["newer-header"] = "/?" path
      form["initialize-change"] = form["root-exception"] = form["behavior-class"] = id
      form["root-selector"] = form["behavior-selector"] = sel
      form["root-subset"] = sel " (\\+-|\\+|-)( " id ")+"
      form["absent-target"] = id " [+-] " sel
      form["floor-framework-override"] = "[A-Za-z0-9]+=/" path
      n = split("name floor-os floor-build floor-arch floor-sdk-arch newer-sdk-arch absent-target", s, " ")
      for (i = 1; i <= n; i++) single[s[i]] = 1
      n = split("floor-image floor-header newer-header root-selector root-exception behavior-class behavior-selector", s, " ")
      for (i = 1; i <= n; i++) listed[s[i]] = 1
    }
    /^#/ || /^$/ { next }
    {
      k = $0; sub(/ .*/, "", k); v = substr($0, length(k) + 2)
      if (!(k in form)) { bad("unknown key " k); next }
      if (v !~ ("^(" form[k] ")$") || (k ~ /(image|header|override)$/ && ("/" v "/") ~ /\/\.\.?\//)) { bad("unexpected value: " $0); next }
      seen[k]++
    }
    END {
      for (k in single) if (seen[k] > 1) bad("repeated " k)
      for (k in single) if (!seen[k]) bad("missing " k)
      for (k in listed) if (!seen[k]) bad("missing " k)
      exit failed
    }' "$RECIPE" || fail "refusing recipe $RECIPE"
}
recipe_list() {  # $1 key: each value, one per line, possibly none
  awk -v k="$1" '/^#/ || /^$/ { next } substr($0, 1, length(k) + 1) == k " " { print substr($0, length(k) + 2) }' "$RECIPE"
}
recipe_get() {  # $1 key: its one value
  rg_v=$(recipe_list "$1")
  [ -n "$rg_v" ] && [ "$(printf '%s\n' "$rg_v" | wc -l | tr -d ' ')" = 1 ] || fail "$RECIPE: $1 must be given once"
  printf '%s\n' "$rg_v"
}
recipe_words() { recipe_list "$1" | tr '\n' ' ' | sed 's/ $//'; }
recipe_load() {
  recipe_check
  FLOOR_OS=$(recipe_get floor-os)
  FLOOR_BUILD=$(recipe_get floor-build)
  FLOOR_ARCH=$(recipe_get floor-arch)
  FLOOR_IMAGES=$(recipe_list floor-image)
  FLOOR_SDK_ARCH=$(recipe_get floor-sdk-arch)
  NEWER_SDK_ARCH=$(recipe_get newer-sdk-arch)
  INITIALIZE_CHANGES=$(recipe_words initialize-change)
  ROOT_SELECTORS=$(recipe_words root-selector)
  ROOT_SUBSETS=$(recipe_list root-subset)
  ROOT_EXCEPTIONS=$(recipe_words root-exception)
  BEHAVIOR_CLASSES=$(recipe_words behavior-class)
  BEHAVIOR_SELECTORS=$(recipe_words behavior-selector)
  ABSENT_TARGETS=$(recipe_get absent-target)
}

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
  out= diagnostic= overrides= reason= recipe_opt=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --output) [ "$#" -ge 2 ] && [ -z "$out" ] || usage; out=$2; shift 2 ;;
      --recipe) [ "$#" -ge 2 ] && [ -z "$recipe_opt" ] || usage; recipe_opt=1 RECIPE=$2; shift 2 ;;
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
  recipe_load
  recipe_overrides=$(recipe_list floor-framework-override)
  if [ -n "$recipe_overrides" ]; then
    while IFS= read -r ov; do
      ! printf '%s\n' "$overrides" | grep -q "^${ov%%=*}=" || fail "$RECIPE: ${ov%%=*} is overridden twice"
      overrides="${overrides:+$overrides
}$ov"
    done <<EOF_RECIPE_OVERRIDES
$recipe_overrides
EOF_RECIPE_OVERRIDES
  fi
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
  got_ov=$(awk -F '\t' '$1 == "override" {print $2 "=" $4}' "$rt" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  want_ov=$(recipe_list floor-framework-override | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
  [ "$got_ov" = "$want_ov" ] ||
    fail "refusing runtime capture $1: its framework overrides ${got_ov:-none} are not the recipe's ${want_ov:-none}"
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
  [ -z "$ROOT_SUBSETS" ] || printf '%s\n' "$ROOT_SUBSETS" | awk -v six="$ROOT_EXCEPTIONS" -v roots="$ROOT_SELECTORS" '
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

sdk_facts() {  # $1 arch  $2 floor|newer  $3 work  $4 header list file (empty: the recipe's SIDE-header list)
  sf_arch=$1 sf_side=$2 sf_work=$3 sf_list=$4
  sf_pin=$(shipyard_sdk_pin "$sf_arch") || fail "no SDK pin for $sf_arch"
  sf_sha=$(printf '%s\n' "$sf_pin" | cut -d' ' -f2)
  sf_tarball=$(printf '%s\n' "$sf_pin" | cut -d' ' -f3)
  sf_sdk=$(sh "$HERE/fetch_sdk.sh" --arch "$sf_arch") || fail "cannot fetch the pinned $sf_arch SDK"
  sf_archive="$(dirname -- "$sf_sdk")/$sf_tarball"
  [ -r "$sf_archive" ] || fail "the pinned archive $sf_tarball is not beside $sf_sdk; it cannot be attested"
  [ "$(sha "$sf_archive")" = "$sf_sha" ] || fail "$sf_archive does not match its pin"
  if [ -s "$sf_list" ]; then cp "$sf_list" "$sf_work/$sf_side.args"
  else
    recipe_list "$sf_side-header" | while IFS= read -r sf_h; do
      case "$sf_h" in /*) printf '%s\n' "$sf_h" ;; *) printf '%s/%s\n' "$sf_sdk" "$sf_h" ;; esac
    done >"$sf_work/$sf_side.args"
  fi
  : >"$sf_work/$sf_side.headers"
  sf_n=0
  set -- --clang-prefix "$prefix" --sdk "$sf_sdk" --signature-output "$sf_work/$sf_side-signatures.tsv"
  [ "$sf_side" != floor ] || set -- "$@" --function-output "$sf_work/floor-functions.tsv"
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
  sed -n 's/^objc-sdk-inventory: sdk-header //p' "$sf_work/$sf_side.log" >"$sf_work/$sf_side.reached"
  sf_tree=$("$DRYDOCK_OBJC" evidence --sdk-digest-only --sdk-root "$sf_sdk") || fail "cannot digest the $sf_side SDK's header tree"
  printf '%s %s %s\n' "$sf_tarball" "$sf_sha" "$sf_tree" >"$sf_work/$sf_side.identity"
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
  prefix= out= runtime= recipe_opt=
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
      --recipe) [ -z "$recipe_opt" ] || usage; recipe_opt=1 RECIPE=$2 ;;
      --floor-header) printf '%s\n' "$2" >>"$tmpl/floor" ;;
      --newer-header) printf '%s\n' "$2" >>"$tmpl/newer" ;;
      *) usage ;;
    esac
    shift 2
  done
  [ -n "$prefix" ] && [ -n "$out" ] || usage
  recipe_load
  [ -n "${DRYDOCK_OBJC:-}" ] && [ -x "$DRYDOCK_OBJC" ] || fail 'build needs DRYDOCK_OBJC, the built drydock-objc, to digest each SDK header tree'
  [ -z "$runtime" ] || check_runtime "$runtime"
  work=$(new_dir "$out")
  trap 'rm -rf "$tmpl" "$work"' EXIT
  sdk_facts "$FLOOR_SDK_ARCH" floor "$work" "$tmpl/floor"
  sdk_facts "$NEWER_SDK_ARCH" newer "$work" "$tmpl/newer"
  # spec: the compiled-reader design's "Argument registers at a C call" -- no SDK header declares the
  #       runtime calls the compiler itself emits (__stack_chk_fail), so they are reviewed by hand in
  #       floor-functions-builtin.tsv and copied, never generated.
  cp "$ROOT/reference/objc/floor-functions-builtin.tsv" "$work/" || fail 'cannot copy the builtin function catalog'
  resource=$("$prefix/bin/clang" -print-resource-dir) || fail 'cannot query the compiler resource directory'
  clang_version=$("$prefix/bin/clang" --version | head -1)
  package=$(tr -d '[:space:]' <"$ROOT/components/objc-reference-clang/version")
  if [ -n "$runtime" ]; then
    cp "$runtime/floor-runtime.tsv" "$runtime/cluster-witnesses.json" "$work/" || fail 'cannot copy the runtime capture'
  fi
  m="$work/manifest.json.new"
  {
    printf '{\n  "schema": 1,\n'
    printf '  "recipe": {"name": "%s", "sha256": "%s"},\n' "$(recipe_get name)" "$(sha "$RECIPE")"
    for side in floor newer; do
      read -r archive archive_sha tree <"$work/$side.identity"
      # spec: tools/README.objc-sdk-inventory.md -- the parsed target is x86_64-apple-macos10.9 for both SDKs.
      target=x86_64-apple-macos10.9
      plain "$archive"
      printf '  "%s_sdk": {\n' "$side"
      printf '    "archive": "%s",\n    "archive_sha256": "%s",\n    "header_tree_sha256": "%s",\n' "$archive" "$archive_sha" "$tree"
      printf '    "headers": [%s],\n' "$(json_list <"$work/$side.headers")"
      if [ -s "$work/$side.reached" ]; then
        printf '    "reached_headers": [\n'
        while IFS= read -r v; do plain "$v"; done <"$work/$side.reached"
        sed 's/.*/      "&"/;$!s/$/,/' "$work/$side.reached"
        printf '    ],\n'
      else printf '    "reached_headers": [],\n'
      fi
      printf '    "parsed_target": "%s",\n    "facts": "%s-sdk.tsv",\n    "signatures": "%s-signatures.tsv"' "$target" "$side" "$side"
      [ "$side" != floor ] || printf ',\n    "functions": "floor-functions.tsv",\n    "builtin_functions": "floor-functions-builtin.tsv"'
      printf '\n  },\n'
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
      subjson=$([ -z "$ROOT_SUBSETS" ] || printf '%s\n' "$ROOT_SUBSETS" | while read -r s k e; do
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
    for f in cluster-witnesses.json floor-functions-builtin.tsv floor-functions.tsv floor-runtime.tsv floor-sdk.tsv floor-signatures.tsv newer-sdk.tsv newer-signatures.tsv; do
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
  rm -f "$work"/*.identity "$work"/*.args "$work"/*.headers "$work"/*.log "$work"/*.resources "$work"/*.reached
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
      *-signatures.tsv) [ "$(head -1 "$d/$f")" = '# objc-signatures 2' ] || fail "$d/$f lacks its schema line" ;;
      *-functions.tsv)
        [ "$(head -1 "$d/$f")" = '# objc-functions 1' ] || fail "$d/$f lacks its schema line"
        awk -F '\t' 'NR > 1 && NF != 5 {exit 1}' "$d/$f" || fail "$d/$f is not five-column functions" ;;
      *-sdk.tsv) awk -F '\t' 'NF != 11 {exit 1}' "$d/$f" || fail "$d/$f is not eleven-column facts" ;;
      floor-runtime.tsv) [ "$(head -1 "$d/$f")" = '# objc-runtime 1' ] || fail "$d/$f lacks its schema line" ;;
    esac
  done || exit 4
  if [ -f "$d/floor-functions-builtin.tsv" ] && [ -f "$d/floor-functions.tsv" ]; then
    dup=$(awk -F '\t' 'FNR == 1 { f++; next } f == 1 { a[$1] = 1 } f == 2 && ($1 in a) { print $1; exit }' \
      "$d/floor-functions.tsv" "$d/floor-functions-builtin.tsv")
    [ -z "$dup" ] || fail "$d: $dup is in both floor-functions.tsv and floor-functions-builtin.tsv"
  fi
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
  if [ -n "${verify_recipe:-}" ]; then
    named=$(sed -n 's/^  "recipe": {"name": "\([^"]*\)", "sha256": "\([0-9a-f]\{64\}\)"},$/\1 \2/p' "$d/manifest.json")
    [ -n "$named" ] || fail "$d/manifest.json names no recipe"
    [ "${named#* }" = "$(sha "$RECIPE")" ] || fail "$d/manifest.json was built from recipe $named, not $RECIPE ($(sha "$RECIPE"))"
  fi
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

coverage() {
  [ "$#" = 3 ] || usage
  d=$1 root=$2 side=$3
  case "$side" in floor|newer) ;; *) usage ;; esac
  verify "$d" >/dev/null || exit 4
  block() { awk -v side="$side" '$0 == "  \"" side "_sdk\": {" {b = 1; next} b && $0 ~ /^  }/ {exit} b' "$d/manifest.json"; }
  archive=$(block | sed -n 's/^    "archive": "\(.*\)\.tar\.xz",$/\1/p')
  [ -n "$archive" ] || fail "$d/manifest.json names no $side SDK archive"
  tree="$root/$archive"
  [ -d "$tree" ] || fail "no $side SDK tree at $tree"
  cv=$(mktemp -d "${TMPDIR:-/tmp}/objc-reference-coverage.XXXXXX") || fail 'cannot create a temporary'
  trap 'rm -rf "$cv"' EXIT
  block | awk '/^    \]/ {exit} r {gsub(/^ *"|",?$/, ""); print} $0 == "    \"reached_headers\": [" {r = 1}' | LC_ALL=C sort >"$cv/reached"
  block | grep -q '^    "reached_headers": ' || fail "$d/manifest.json lists no $side reached_headers"
  (cd "$tree" && find . -type f -name '*.h') | sed 's|^\./||' | LC_ALL=C sort >"$cv/all"
  stray=$(LC_ALL=C comm -13 "$cv/all" "$cv/reached" | head -1)
  [ -z "$stray" ] || fail "reached header $stray is not in $tree"
  LC_ALL=C awk -F '\t' -v reached="$cv/reached" '
    function unit(p) { if (match(p, /.*\.framework\//)) return substr(p, 1, RLENGTH - 1); if (sub(/\/[^\/]*$/, "", p)) return p; return "." }
    BEGIN { while ((getline line < reached) > 0) r[line] = 1 }
    { u = unit($0); if (!(u in total)) miss[u] = "-"; total[u]++
      if ($0 in r) got[u]++; else if (miss[u] == "-") miss[u] = $0 }
    END { for (u in total) print u "\t" total[u] "\t" (got[u] + 0) "\t" miss[u] }' "$cv/all" | LC_ALL=C sort
  rm -rf "$cv"; trap - EXIT
}

diff_sets() {
  [ "$#" = 2 ] || usage
  [ -d "$1" ] || fail "no reference set at $1"
  [ -d "$2" ] || fail "no reference set at $2"
  dw=$(mktemp -d "${TMPDIR:-/tmp}/objc-reference-diff.XXXXXX") || fail 'cannot create a temporary'
  trap 'rm -rf "$dw"' EXIT
  : >"$dw/changes"; : >"$dw/summary"
  for f in cluster-witnesses.json floor-functions-builtin.tsv floor-functions.tsv floor-runtime.tsv floor-sdk.tsv floor-signatures.tsv manifest.json newer-sdk.tsv newer-signatures.tsv; do
    [ -f "$1/$f" ] || [ -f "$2/$f" ] || continue
    case "$f" in
      *.tsv)
        for side in 1 2; do : >"$dw/s$side"; done
        [ ! -f "$1/$f" ] || LC_ALL=C sort -u "$1/$f" >"$dw/s1"
        [ ! -f "$2/$f" ] || LC_ALL=C sort -u "$2/$f" >"$dw/s2"
        LC_ALL=C awk -F '\t' -v OFS='\t' -v file="$f" -v changes="$dw/changes" -v summary="$dw/summary" '
          function spec(kind) {
            if (file ~ /-sdk\.tsv$/) return "1 2 3 4 5 11"
            if (file ~ /-signatures\.tsv$/) return "1 2 3 4 5 8"
            if (file ~ /^floor-functions/) return "1"
            if (kind == "method") return "1 2 3 4 6"
            if (kind == "behavior") return "1 2 3 4 7"
            if (kind == "class" || kind == "image" || kind == "override" || kind == "identity") return "1 2"
            return "1 2 3 4"
          }
          function iskey(sp, i) { return index(" " sp " ", " " i " ") > 0 }
          function colname(i) {
            if (file ~ /-sdk\.tsv$/) { split("kind unit class method-kind name encoding introduced deprecated unavailable source container", nm, " "); return nm[i] }
            return "col" i
          }
          function keyof(row,   f, nf, sp, nk, c, i, k) {
            if (row ~ /^#/) return "#header"
            nf = split(row, f, "\t"); sp = spec(f[1]); nk = split(sp, c, " ")
            k = f[c[1]]
            for (i = 2; i <= nk; i++) k = k " " f[c[i]]
            return k
          }
          function values(row,   f, nf, sp, i, v) {
            if (row ~ /^#/) return row
            nf = split(row, f, "\t"); sp = spec(f[1]); v = ""
            for (i = 1; i <= nf; i++) if (!iskey(sp, i)) v = v (v == "" ? "" : " ") f[i]
            return v
          }
          function detail(a, b,   fa, fb, na, nb, n, i, sp, d) {
            if (a ~ /^#/) return a " -> " b
            na = split(a, fa, "\t"); nb = split(b, fb, "\t"); n = na > nb ? na : nb; sp = spec(fa[1]); d = ""
            for (i = 1; i <= n; i++) if (!iskey(sp, i) && fa[i] != fb[i])
              d = d (d == "" ? "" : "; ") colname(i) " " fa[i] " -> " fb[i]
            return d
          }
          { side = (FILENAME == ARGV[1]) ? 1 : 2 }
          {
            k = keyof($0); n = ++seen[side, k]
            if (n > 1) k = k " #" n
            row[side, k] = $0; keys[k] = 1
          }
          END {
            for (k in keys) {
              if (!((1, k) in row)) { print "ADDED", file, k, values(row[2, k]) >> changes; add++ }
              else if (!((2, k) in row)) { print "REMOVED", file, k, values(row[1, k]) >> changes; rem++ }
              else if (row[1, k] != row[2, k]) { print "CHANGED", file, k, detail(row[1, k], row[2, k]) >> changes; chg++ }
            }
            if (add + rem + chg > 0) print file, "+" add + 0, "-" rem + 0, "~" chg + 0 >> summary
          }' "$dw/s1" "$dw/s2"
        ;;
      *.json)
        for side in 1 2; do : >"$dw/s$side"; done
        [ ! -f "$1/$f" ] || json_flatten <"$1/$f" >"$dw/s1"
        [ ! -f "$2/$f" ] || json_flatten <"$2/$f" >"$dw/s2"
        LC_ALL=C awk -F '\t' -v OFS='\t' -v file="$f" -v changes="$dw/changes" -v summary="$dw/summary" '
          { side = (FILENAME == ARGV[1]) ? 1 : 2 }
          $1 == "K" { v[side, $2] = $3; keys[$2] = 1; next }
          $1 == "B" { b[side, $2, $3] = 1; bl[$2 SUBSEP $3] = 1; has[side, $2] = 1; paths[$2] = 1 }
          END {
            for (k in keys) {
              if (!((1, k) in v)) { print "ADDED", file, k, v[2, k] >> changes; add++ }
              else if (!((2, k) in v)) { print "REMOVED", file, k, v[1, k] >> changes; rem++ }
              else if (v[1, k] != v[2, k]) { print "CHANGED", file, k, v[1, k] " -> " v[2, k] >> changes; chg++ }
            }
            for (k in bl) { split(k, p, SUBSEP); if (!((1, p[1], p[2]) in b)) added[p[1]]++; if (!((2, p[1], p[2]) in b)) removed[p[1]]++ }
            for (q in paths) {
              a = added[q] + 0; r = removed[q] + 0
              unit = q ~ /reached_headers$/ ? "headers" : "lines"
              if (!((1, q) in has)) { print "ADDED", file, q, "+" a " " unit >> changes; add++ }
              else if (!((2, q) in has)) { print "REMOVED", file, q, "-" r " " unit >> changes; rem++ }
              else if (a + r > 0) { print "CHANGED", file, q, "+" a " -" r " " unit >> changes; chg++ }
            }
            if (add + rem + chg > 0) print file, "+" add + 0, "-" rem + 0, "~" chg + 0 >> summary
          }' "$dw/s1" "$dw/s2"
        ;;
    esac
  done
  LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 -k1,1 "$dw/changes"
  LC_ALL=C sort "$dw/summary"
  rm -rf "$dw"; trap - EXIT
}

json_flatten() {
  awk '
    function strip(s) { sub(/^ +/, "", s); sub(/,$/, "", s); return s }
    function keyname(line, indent,   k) { k = line; sub("^" indent "\"", "", k); sub(/".*/, "", k); return k }
    function valueof(line, indent,   r) { r = line; sub("^" indent "\"[^\"]*\": ", "", r); return r }
    /^  "[^"]*": / {
      top = keyname($0, "  "); r = valueof($0, "  "); cur = ""
      if (r ~ /[\[{]$/) cur = top; else print "K\t" top "\t" strip(r)
      next
    }
    /^    "[^"]*": / && top != "" {
      path = top "." keyname($0, "    "); r = valueof($0, "    "); cur = ""
      if (r ~ /[\[{]$/) cur = path; else print "K\t" path "\t" strip(r)
      next
    }
    /^ *[\]}],?$/ { next }
    cur == top && cur != "" && /^ *\{"(name|id)": "/ {
      e = $0; sub(/^ *\{"(name|id)": "/, "", e); sub(/".*/, "", e)
      print "K\t" top " " e "\t" strip($0); next
    }
    cur != "" { print "B\t" cur "\t" strip($0) }'
}

[ "$#" -ge 1 ] || usage
cmd=$1; shift
case "$cmd" in
  capture) capture "$@" ;;
  dyld-check) [ "$#" = 0 ] || usage; dyld_check ;;
  capture-tool) [ "$#" = 2 ] && [ "$1" = --output ] || usage; host_build "$2" ;;
  build) build "$@" ;;
  verify)
    if [ "${1:-}" = --recipe ]; then [ "$#" -ge 2 ] || usage; RECIPE=$2 verify_recipe=1; shift 2; fi
    recipe_load; verify "$@" ;;
  lookup) lookup "$@" ;;
  coverage) coverage "$@" ;;
  diff) diff_sets "$@" ;;
  *) usage ;;
esac
