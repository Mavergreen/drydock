#!/bin/sh
# platform: macOS-only -- links x86_64 consumers of an Objective-C provider archive against the pinned 10.9 SDK, then reads them as bytes
# spec: tools/objc-compat/provider.c header -- a send is `provided` only when the provider's attested
#       archive member is linked into the final artifact byte for byte, its constructor is in the
#       initializer table, its registration names the declared class, selector and ABI, and its
#       frameworks are strongly loaded; every mutation below is nonzero.
#       The provider is MAVERGREEN_OBJC_RECAULK_PREFIX when set (a prefix from Recaulk's
#       build/build-objc.sh: lib/librecaulk-objc.a and share/recaulk/objc-providers.json), else the
#       fixture provider built here in the same shape. MAVERGREEN_OBJC_CODEX_ARTIFACT, when set, is
#       the original Codex 0.165.0 binary, which must still fail. MAVERGREEN_OBJC_RECAULK_RECEIPT, with the Recaulk
#       prefix, is that provider's source receipt (scripts/objc-source-inventory.sh): its body's sends then close where
#       their static types name a class, every one is mapped, and the rest stay open. Nothing built here is executed.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
FX="$HERE/fixtures/objc-api"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-provider-test.XXXXXX")
trap 'chmod -R u+rw "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 "$@"; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
mkdir -p "$T/root/bin" "$T/maps" "$T/ev" "$T/out" "$T/src"

# spec: tests/lib/objc_fixture_provider.sh -- fixture_prefix DIR [CC-FLAGS] and declare_prefix DIR RECEIPT.
. "$HERE/lib/objc_fixture_provider.sh"
if [ -n "${MAVERGREEN_OBJC_RECAULK_PREFIX:-}" ]; then
  PFX=$MAVERGREEN_OBJC_RECAULK_PREFIX
  [ -f "$PFX/share/recaulk/objc-providers.json" ] || fail "MAVERGREEN_OBJC_RECAULK_PREFIX has no share/recaulk/objc-providers.json"
  real=1
else
  PFX="$T/fixture-prefix"; fixture_prefix "$PFX"; real=0
fi
DECL="$PFX/share/recaulk/objc-providers.json"
field() { sed -n "s/^ *\"$1\" : \"\\(.*\\)\",*\$/\\1/p" "$DECL" | head -1 | sed 's,\\/,/,g'; }
ARCHIVE="$PFX/$(field archive_path)"
IMPL=$(field implementation_symbol)
ACTIVATE=$(field activation_root)
[ -f "$ARCHIVE" ] && [ -n "$IMPL" ] && [ -n "$ACTIVATE" ] || fail "cannot read the provider declaration $DECL"
SEL='openURLs:withApplicationAtURL:options:configuration:error:'

# spec: scripts/objc-provider-link-args.sh header -- link-args PREFIX MAP: the helper's lines into $T/args.
link_args() { rc=0; sh "$ROOT/scripts/objc-provider-link-args.sh" --prefix "$1" --link-map "$2" >"$T/args" 2>"$T/err" || rc=$?; }
# spec: scripts/objc-provider-link-args.sh header -- consumer OUT FILTER [cc args]: the fixture consumer
#       linked with the helper's lines after FILTER (an awk program over them), and a link map at OUT.map.
consumer() {
  out=$1 filter=$2 src=${SRC:-$FX/provider-consumer.m}; shift 2
  link_args "$PFX" "$out.map"; [ "$rc" = 0 ] || fail "link args for $PFX: exit $rc"
  awk "$filter" "$T/args" >"$T/args.f"
  while IFS= read -r line; do set -- "$@" "$line"; done <"$T/args.f"
  cc -O1 "$src" "$@" -o "$out" || fail "linking $out"
}
ALL='{print}'
NO_ROOT='!/^-Wl,-u,/'
NO_ARCHIVE='!/\.a$/ && !/^-Wl,-u,/'
# spec: scripts/objc-provider-link-args.sh header -- fwflag NAME FLAG: rewrite "-framework" "NAME" as the one argument
#       FLAG,NAME (a linker flag the compiler driver passes through), or drop it.
fwflag() {
  printf '{l[NR]=$0} END{for(i=1;i<=NR;i++){if(l[i]=="-framework" && l[i+1]=="%s"){if("%s"!="") print "%s,%s"; i++; continue} print l[i]}}' "$1" "$2" "$2" "$1"
}
# spec: scripts/objc-build-evidence.sh header -- evidence ARTIFACT PRESTRIP MAP OUT [PREFIX]: rc set.
evidence() {
  rm -f "$T/report"
  rc=0; sh "$ROOT/scripts/objc-build-evidence.sh" --artifact "$1" --prestrip "$2" --source-root "$FX" --link-map "$3" \
    --provider-prefix "${5:-$PFX}" --references "$REF" --output "$4" 2>"$T/err" || rc=$?
}
n=0
# spec: scripts/objc-compat.sh header -- analyze ARTIFACT [options]: strict, with this provider prefix; rc and $T/report.
analyze() {
  art=$1; shift; n=$((n + 1)); rep="$T/out/report.$n"
  rc=0; sh "$ROOT/scripts/objc-compat.sh" --artifact "$art" --root "$T/root" --references "$REF" --report "$rep" --mode strict "$@" 2>"$T/err" || rc=$?
  ln -sf "$rep" "$T/report"
}
verdict() { grep "\"selector\": \"$SEL\"" "$T/report" | sed -n 's/.*"verdict": "\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' '; }
want_verdict() { got=$(verdict); [ "$got" = "$1 " ] || fail "$2: openURLs is '${got:-no finding}', want $1 (exit $rc)"; }
nonzero() { [ "$rc" != 0 ] || fail "$1: exit 0"; [ "$(verdict)" != "provided " ] || fail "$1: openURLs became provided"; }
reason_has() { grep -F "\"reason\": \"$1" "$T/report" >/dev/null || grep -F "$1" "$T/report" | grep '"reason"' >/dev/null || fail "$2: the provider reason does not say '$1'"; }
exit_is() { [ "$rc" = "$1" ] || fail "$2: exit $rc, want $1"; }
error_is() { grep "\"code\": \"$1\"" "$T/report" >/dev/null || fail "$2: no $1 error"; }
# spec: tools/objc-compat/provider.c header -- full ARTIFACT PRESTRIP MAP NAME: evidence then a strict analysis.
full() {
  evidence "$1" "$2" "$3" "$T/ev/$4.json"; [ "$rc" = 0 ] || fail "$4: build evidence exit $rc"
  analyze "$1" --build-evidence "$T/ev/$4.json" --provider-prefix "$PFX"
}
positive() {   # positive NAME: openURLs provided; strict passes for the fixture; for the real provider strict exits 1 exactly when its body leaves a blocking send
  want_verdict provided "$1"
  grep '"status": "active"' "$T/report" >/dev/null || fail "$1: the provider is not reported active"
  if [ "$real" = 0 ]; then exit_is 0 "$1 (fixture provider: every send closes)"
  else
    if grep -E '"verdict": "(unsupported|unresolved)"' "$T/report" >/dev/null; then
      exit_is 1 "$1 (real provider: its own body's open sends block, never exempted)"
    else
      exit_is 0 "$1 (real provider: every body send closed by evidence)"
    fi
    ! grep '"function": "_main"' "$T/report" | grep -E '"verdict": "(unsupported|unresolved)"' >/dev/null || fail "$1: the consumer's own send blocks"
  fi
}
# spec: tools/objc-compat/provider.c header -- put32/put64 FILE OFFSET VALUE: little-endian patch in place.
putn() {
  f=$1 off=$2 v=$3 k=$4 i=0 b=''
  while [ "$i" -lt "$k" ]; do b="$b$(printf '\\%03o' $(( (v >> (8 * i)) & 255 )))"; i=$((i + 1)); done
  printf "$b" | dd of="$f" bs=1 seek="$off" conv=notrunc 2>/dev/null
}
# spec: tools/objc-compat/provider.c header -- fileoff FILE VA: the file offset of a mapped address.
fileoff() {
  otool -l "$1" | awk -v va="$2" '
    $1=="addr" {a=hx($2)} $1=="size" && a {s=hx($2)} $1=="offset" && a {
      if (va+0 >= a && va+0 < a+s) {print $2 + (va - a); exit} a=0 }
    function hx(h,  i,c,n) {n=0; h=tolower(h); sub(/^0x/,"",h); for(i=1;i<=length(h);i++){c=index("0123456789abcdef",substr(h,i,1))-1; n=n*16+c} return n}'
}
symaddr() { nm "$1" | awk -v s="$2" '$3==s {print "0x" $1; exit}'; }

# spec: scripts/objc-provider-link-args.sh header -- one argument per line from the validated declaration;
#       a prefix with a space survives because nothing is word-split or evaluated.
mkdir -p "$T/pre fix"; cp -R "$PFX/." "$T/pre fix/"
link_args "$T/pre fix" "$T/maps/a b.map"; [ "$rc" = 0 ] || fail "link args with a space in the prefix: exit $rc"
abs=$(CDPATH= cd -- "$T/pre fix" && pwd -P)
printf '%s\n' "$abs/$(field archive_path)" "-Wl,-u,_$ACTIVATE" -framework AppKit -framework Carbon -Xlinker -map -Xlinker "$T/maps/a b.map" >"$T/args.want"
cmp -s "$T/args" "$T/args.want" || fail "link args: got $(tr '\n' '|' <"$T/args"), want $(tr '\n' '|' <"$T/args.want")"
bad_decl() {  # bad_decl WHY SED-EXPRESSION: a copied prefix whose declaration is edited is refused.
  rm -rf "$T/bad"; cp -R "$PFX" "$T/bad"; sed "$2" "$DECL" >"$T/bad/share/recaulk/objc-providers.json"
  link_args "$T/bad" "$T/maps/bad.map"; [ "$rc" = 4 ] || fail "link args accepted $1 (exit $rc)"
}
bad_decl "a shell metacharacter in the root" "s|\"$ACTIVATE\"|\"x;touch owned\"|"
bad_decl 'a framework that is not an identifier' 's/"Carbon"/"Car bon"/'
bad_decl 'a stale archive digest' 's/"archive_sha256" : "[0-9a-f]*"/"archive_sha256" : "0000000000000000000000000000000000000000000000000000000000000000"/'
bad_decl "an unknown key" "s/\"schema\" : 1/\"schema\" : 1, \"unexpected\" : 1/"
bad_decl 'a weak framework policy' 's/strong-linked-before-root/weak-linked/'
bad_decl 'malformed JSON' 's/"schema" : 1,/"schema" : 1/'
cr=$(printf 'x\ry')
link_args "$T/pre fix" "$T/maps/$cr.map"; [ "$rc" != 0 ] || fail 'a CR in the link-map path was accepted'
mkdir -p "$T/nl
prefix"; cp -R "$PFX/." "$T/nl
prefix/"
link_args "$T/nl
prefix" "$T/maps/nl.map"; [ "$rc" != 0 ] || fail 'a newline in the prefix path was accepted'

consumer "$T/root/bin/rooted" "$ALL"
cp "$T/root/bin/rooted.map" "$T/maps/rooted.map"
# spec: scripts/objc-provider-link-args.sh header -- the helper's own output never attests activation:
#       without build evidence the provider's class_addMethod is an unattested runtime mutation.
analyze "$T/root/bin/rooted" --provider-prefix "$PFX"
exit_is 4 'rooted without build evidence'; error_is unattested-method-registration 'rooted without build evidence'
full "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/rooted.map" rooted
positive 'rooted plain link'
if [ "$real" = 1 ] && [ -n "${MAVERGREEN_OBJC_RECAULK_RECEIPT:-}" ]; then
  analyze "$T/root/bin/rooted" --build-evidence "$T/ev/rooted.json" --provider-prefix "$PFX" --source-receipt "$MAVERGREEN_OBJC_RECAULK_RECEIPT"
  # platform: every error, not the last lines of stderr: a refused receipt usually refuses many sends at once.
  ! grep '"code": ' "$T/report" >/dev/null ||
    fail "the provider's source receipt: $(grep -c '"code": ' "$T/report") errors: $(sed -n 's/.*"code": "\([a-z-]*\)".*"detail": "\(.*\)"}.*/\1: \2/p' "$T/report" | tr '\n' ';')"
  positive 'rooted plain link with the provider source receipt'
  closed=$(sed -n 's/.*"receiver_closure": {[^}]*"source": \([0-9]*\)[,}].*/\1/p' "$T/report")
  [ "${closed:-0}" -gt 0 ] || fail 'the provider source receipt closed no send'
  echo "objc-provider: the Recaulk source receipt closes $closed sends; $(grep -c '"verdict": "unresolved"' "$T/report") stay open"
fi
cp "$T/report" "$T/cached-positive.json"
grep "\"declaration_sha256\": \"$(sha "$DECL")\"" "$T/report" >/dev/null && grep "\"archive_sha256\": \"$(sha "$ARCHIVE")\"" "$T/report" >/dev/null ||
  fail 'the report does not identify the provider declaration and archive'
consumer "$T/root/bin/deadstrip" "$ALL" -Wl,-dead_strip
full "$T/root/bin/deadstrip" "$T/root/bin/deadstrip" "$T/root/bin/deadstrip.map" deadstrip
positive 'rooted with -dead_strip'
consumer "$T/root/bin/lto" "$ALL" -flto -Wl,-dead_strip
full "$T/root/bin/lto" "$T/root/bin/lto" "$T/root/bin/lto.map" lto
positive 'rooted with consumer LTO'
mv "$T/root/bin/rooted" "$T/rooted.prestrip"
strip -o "$T/root/bin/rooted" "$T/rooted.prestrip"
full "$T/root/bin/rooted" "$T/rooted.prestrip" "$T/maps/rooted.map" stripped
positive 'stripped final artifact with prestrip evidence'
cp "$T/rooted.prestrip" "$T/root/bin/rooted"

consumer "$T/root/bin/omitted" "$NO_ROOT"
full "$T/root/bin/omitted" "$T/root/bin/omitted" "$T/root/bin/omitted.map" omitted
nonzero 'archive linked without the root'; want_verdict unsupported 'archive linked without the root'
consumer "$T/root/bin/installed" "$NO_ARCHIVE"
full "$T/root/bin/installed" "$T/root/bin/installed" "$T/root/bin/installed.map" installed
nonzero 'provider installed, not linked'; want_verdict unsupported 'provider installed, not linked'
consumer "$T/root/bin/ds-unrooted" "$NO_ROOT" -Wl,-dead_strip
full "$T/root/bin/ds-unrooted" "$T/root/bin/ds-unrooted" "$T/root/bin/ds-unrooted.map" ds-unrooted
nonzero 'dead stripping without the root'
consumer "$T/root/bin/lto-unrooted" "$NO_ROOT" -flto -Wl,-dead_strip
full "$T/root/bin/lto-unrooted" "$T/root/bin/lto-unrooted" "$T/root/bin/lto-unrooted.map" lto-unrooted
nonzero 'consumer LTO without the root'

# spec: tools/objc-compat/provider.c header, 4 -- what the provider needs loaded is what it binds and its class's home, not
#       every framework it declares: Carbon, whose functions the provider reaches through CoreServices and
#       ApplicationServices (and lld leaves out when nothing binds to it), need not be loaded.
consumer "$T/root/bin/no-carbon" "$(fwflag Carbon '')" -framework CoreServices -framework ApplicationServices
full "$T/root/bin/no-carbon" "$T/root/bin/no-carbon" "$T/root/bin/no-carbon.map" no-carbon
positive 'Carbon not linked, nothing bound to it'
# spec: tools/objc-compat/provider.c header, 4 -- the declared class's home (AppKit for NSWorkspace, from the floor capture)
#       loaded weakly, upward or lazily, or an import the provider calls bound to a weakly loaded library, is inactive.
consumer "$T/root/bin/weak-appkit" "$(fwflag AppKit -Wl,-weak_framework)"
full "$T/root/bin/weak-appkit" "$T/root/bin/weak-appkit" "$T/root/bin/weak-appkit.map" weak-appkit
nonzero 'AppKit weakly linked'
reason_has 'AppKit (home of NSWorkspace) is weakly linked' 'AppKit weakly linked'
consumer "$T/root/bin/weak-objc" "$ALL" -weak-lobjc
full "$T/root/bin/weak-objc" "$T/root/bin/weak-objc" "$T/root/bin/weak-objc.map" weak-objc
nonzero 'libobjc weakly linked'
reason_has 'binds to /usr/lib/libobjc.A.dylib, which is weakly linked' 'libobjc weakly linked'
# platform: ld64 ignores -upward_framework for an executable and current linkers drop -lazy_framework, so the
#           late loads are made by rewriting AppKit's load command in place (the sections stay identical).
lc_offset() {  # lc_offset FILE FRAMEWORK: the file offset of the dylib load command naming FRAMEWORK
  otool -l "$1" | awk -v fw="/$2.framework/" '/^Load command/ {if (seen) off += size; seen = 1} $1 == "cmdsize" {size = $2}
    $1 == "name" && index($2, fw) {print 32 + off; exit}'
}
for late in upward:2147483683 lazy:32; do
  cp "$T/root/bin/rooted" "$T/root/bin/${late%%:*}-appkit"
  off=$(lc_offset "$T/root/bin/${late%%:*}-appkit" AppKit); [ -n "$off" ] || fail 'no AppKit load command'
  putn "$T/root/bin/${late%%:*}-appkit" "$off" "${late#*:}" 4
  full "$T/root/bin/${late%%:*}-appkit" "$T/root/bin/${late%%:*}-appkit" "$T/maps/rooted.map" "${late%%:*}-appkit"
  nonzero "AppKit loaded ${late%%:*} (initialized late)"
  reason_has "AppKit (home of NSWorkspace) is $([ "${late%%:*}" = lazy ] && echo lazily || echo 'linked upward')" "AppKit loaded ${late%%:*}"
done

# spec: tools/objc-compat/provider.c header -- the root kept, its constructor dropped from the initializer table.
cp "$T/root/bin/rooted" "$T/root/bin/noinit"
off=$(otool -l "$T/root/bin/noinit" | awk '/sectname __mod_init_func/{f=1} f && $1=="offset" {print $2; exit}')
[ -n "$off" ] || fail 'the rooted consumer has no __mod_init_func'
putn "$T/root/bin/noinit" "$off" "$(symaddr "$T/root/bin/noinit" _main)" 8
symaddr "$T/root/bin/noinit" "_$ACTIVATE" | grep . >/dev/null || fail 'the root symbol is gone'
full "$T/root/bin/noinit" "$T/root/bin/noinit" "$T/maps/rooted.map" noinit
nonzero 'root present, constructor not in the initializer table'
reason_has 'not in the final initializer table' 'constructor dropped'

# spec: tools/objc-compat/provider.c header -- the registration's IMP reference retargeted by one byte.
member=$(nm -A "$ARCHIVE" 2>/dev/null | awk -v s="_$ACTIVATE" '$NF==s && $(NF-1)=="T" {m=$1; sub(/:$/,"",m); if (m ~ /\(.*\)$/) {sub(/.*\(/,"",m); sub(/\)$/,"",m)} else sub(/.*:/,"",m); print m; exit}')
[ -n "$member" ] || fail "no archive member defines _$ACTIVATE"
(cd "$T/src" && ar -x "$ARCHIVE" "$member") || fail "cannot extract $member"
r=$(otool -rv "$T/src/$member" | awk -v s="_$IMPL" '$NF==s && $3=="long" {print $1; exit}')
[ -n "$r" ] || fail "$member has no reference to _$IMPL"
atom=$(nm -n "$T/src/$member" | awk -v r="0x$r" 'function h(x, i,c,n){n=0;x=tolower(x);sub(/^0x/,"",x);for(i=1;i<=length(x);i++){c=index("0123456789abcdef",substr(x,i,1))-1;n=n*16+c}return n}
  $2 ~ /^[Tt]$/ && h($1) <= h(r) {name=$3; base=h($1)} END{print name, h(r) - base}')
set -- $atom
va=$(( $(symaddr "$T/root/bin/rooted" "$1") + $2 ))
cp "$T/root/bin/rooted" "$T/root/bin/retarget"
off=$(fileoff "$T/root/bin/retarget" "$va")
d=$(od -An -tu4 -j "$off" -N4 "$T/root/bin/retarget" | tr -d ' ')
putn "$T/root/bin/retarget" "$off" "$(( (d + 1) & 4294967295 ))" 4
full "$T/root/bin/retarget" "$T/root/bin/retarget" "$T/maps/rooted.map" retarget
nonzero 'implementation reference retargeted'

# spec: tools/objc-compat/provider.c header -- a declaration that disagrees with the registered class, kind, selector or ABI.
decl_variant() {   # decl_variant NAME SED: the rooted consumer against a prefix whose declaration is edited
  rm -rf "$T/pfx-$1"; cp -R "$PFX" "$T/pfx-$1"
  sed "$2" "$DECL" >"$T/pfx-$1/share/recaulk/objc-providers.json"
  evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/rooted.map" "$T/ev/$1.json" "$T/pfx-$1"
  if [ "$rc" = 0 ]; then analyze "$T/root/bin/rooted" --build-evidence "$T/ev/$1.json" --provider-prefix "$T/pfx-$1"; fi
  nonzero "declared $1"
}
decl_variant class 's/"NSWorkspace"/"NSFileManager"/'
decl_variant kind 's/"method_kind" : "-"/"method_kind" : "+"/'
decl_variant selector "s/\"$SEL\"/\"openURLs:withAppBundleIdentifier:options:additionalEventParamDescriptor:launchIdentifiers:\"/"
decl_variant abi 's/"@56@0:8@16@24Q32@40^@48"/"c56@0:8@16@24Q32@40^@48"/'
# spec: tools/objc-compat/provider.c header -- an archive whose code registers another class than its declaration says.
fixture_prefix "$T/pfx-wrongcode" -DFIXTURE_REGISTERED_CLASS='"NSFileManager"'
save=$PFX; PFX="$T/pfx-wrongcode"
consumer "$T/root/bin/wrongcode" "$ALL"
full "$T/root/bin/wrongcode" "$T/root/bin/wrongcode" "$T/root/bin/wrongcode.map" wrongcode
PFX=$save
nonzero 'code registering another class than declared'; error_is provider-registration-mismatch 'code registering another class'

# spec: tools/objc-compat/provider.c header -- stale provider inputs: the archive or declaration changed after the evidence.
rm -rf "$T/pfx-stale"; cp -R "$PFX" "$T/pfx-stale"
printf '\n' >>"$T/pfx-stale/share/recaulk/objc-providers.json"
analyze "$T/root/bin/rooted" --build-evidence "$T/ev/rooted.json" --provider-prefix "$T/pfx-stale"
nonzero 'declaration changed after the evidence'; exit_is 4 'declaration changed after the evidence'
rm -rf "$T/pfx-stale"; cp -R "$PFX" "$T/pfx-stale"
printf '!<arch>\n' >"$T/pfx-stale/$(field archive_path)"
analyze "$T/root/bin/rooted" --build-evidence "$T/ev/rooted.json" --provider-prefix "$T/pfx-stale"
nonzero 'archive replaced'; exit_is 4 'archive replaced'
rm -rf "$T/pfx-gone"; cp -R "$PFX" "$T/pfx-gone"
(cd "$T/src" && ar -x "$ARCHIVE")
ar -d "$T/pfx-gone/$(field archive_path)" "$member" 2>/dev/null && ranlib "$T/pfx-gone/$(field archive_path)" 2>/dev/null
sed "s/\"archive_sha256\" : \"[0-9a-f]*\"/\"archive_sha256\" : \"$(sha "$T/pfx-gone/$(field archive_path)")\"/" "$DECL" >"$T/pfx-gone/share/recaulk/objc-providers.json"
evidence "$T/root/bin/omitted" "$T/root/bin/omitted" "$T/root/bin/omitted.map" "$T/ev/gone.json" "$T/pfx-gone"
[ "$rc" = 0 ] && analyze "$T/root/bin/omitted" --build-evidence "$T/ev/gone.json" --provider-prefix "$T/pfx-gone"
nonzero 'archive without the root member'

# spec: tools/objc-compat/main.m header -- a changed final binary or dependency after the evidence.
analyze "$T/root/bin/deadstrip" --build-evidence "$T/ev/rooted.json" --provider-prefix "$PFX"
nonzero 'evidence for another final binary'; exit_is 4 'evidence for another final binary'

# spec: scripts/objc-build-evidence.sh header -- an artifact that links no provider: neither --link-map nor
#       --provider-prefix; evidence with no provider mapping. One without the other is a usage error.
cc -O1 "$FX/plain.c" -o "$T/root/bin/plain-consumer"
noprov() {
  rc=0; sh "$ROOT/scripts/objc-build-evidence.sh" --artifact "$T/root/bin/plain-consumer" --prestrip "$T/root/bin/plain-consumer" \
    --source-root "$FX" --references "$REF" "$@" 2>"$T/err" || rc=$?
}
noprov --output "$T/ev/noprov.json"
exit_is 0 'evidence for a binary that links no provider'
grep '"providers": \[\]' "$T/ev/noprov.json" >/dev/null || fail 'provider-less evidence lists providers'
grep "\"sha256\": \"$(sha "$T/root/bin/plain-consumer")\"" "$T/ev/noprov.json" >/dev/null || fail 'provider-less evidence does not name its artifact'
noprov --link-map "$T/maps/rooted.map" --output "$T/ev/noprov-map.json"
exit_is 2 'a link map without a provider prefix'
noprov --provider-prefix "$PFX" --output "$T/ev/noprov-pfx.json"
exit_is 2 'a provider prefix without a link map'
analyze "$T/root/bin/plain-consumer" --build-evidence "$T/ev/noprov.json"
exit_is 0 'provider-less evidence analyzed with no prefix'
# spec: tools/objc-compat/main.m "The shipped closure" -- a dependency inside the root is measured by its
#       interface; one that loads from outside it is not, so nothing it might replace can be provided.
cc -dynamiclib -O1 "$FX/plain.c" -o "$T/root/bin/libextra.dylib" -install_name /Library/Mavergreen/libextra.dylib
consumer "$T/root/bin/extra-dep" "$ALL" "$T/root/bin/libextra.dylib"
full "$T/root/bin/extra-dep" "$T/root/bin/extra-dep" "$T/root/bin/extra-dep.map" extra-dep
nonzero 'a dependency outside the shipped root'; exit_is 4 'a dependency outside the shipped root'

# spec: scripts/objc-build-evidence.sh header -- prestrip evidence absent, from another link, or without the atoms' symbols.
rc=0; sh "$ROOT/scripts/objc-build-evidence.sh" --artifact "$T/root/bin/rooted" --source-root "$FX" --link-map "$T/maps/rooted.map" \
  --provider-prefix "$PFX" --references "$REF" --output "$T/ev/noprestrip.json" 2>"$T/err" || rc=$?
exit_is 2 'build evidence without --prestrip'; [ ! -e "$T/ev/noprestrip.json" ] || fail 'a refused evidence run wrote output'
evidence "$T/root/bin/rooted" "$T/root/bin/omitted" "$T/maps/rooted.map" "$T/ev/wrongprestrip.json"
exit_is 4 'prestrip from another link'; [ ! -e "$T/ev/wrongprestrip.json" ] || fail 'mismatched prestrip wrote evidence'
evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/root/bin/omitted.map" "$T/ev/wrongmap.json"
exit_is 4 'link map from another link'
consumer "$T/root/bin/nolocals" "$ALL" -Wl,-x
evidence "$T/root/bin/nolocals" "$T/root/bin/nolocals" "$T/root/bin/nolocals.map" "$T/ev/nolocals.json"
exit_is 4 'prestrip without the provider atoms'"'"' symbols'
printf '{"schema": 1, "kind": "objc-build-evidence", "artifact": {"sha256": "%s"}, "source": {}, "providers": []}\n' "$(sha "$T/root/bin/rooted")" >"$T/ev/empty.json"
analyze "$T/root/bin/rooted" --build-evidence "$T/ev/empty.json" --provider-prefix "$PFX"
nonzero 'evidence naming no provider'; error_is unattested-method-registration 'evidence naming no provider'
sed 's/"address": "0x[0-9a-f]*"/"address": "0x1000"/' "$T/ev/rooted.json" >"$T/ev/forged.json"
analyze "$T/root/bin/rooted" --build-evidence "$T/ev/forged.json" --provider-prefix "$PFX"
nonzero 'atom addresses that are not where the evidence says'; exit_is 4 'forged atom addresses'
evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/rooted.map" "$T/ev/rooted.json"
exit_is 2 'an existing evidence destination'
chmod 000 "$T/maps/rooted.map"
evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/rooted.map" "$T/ev/unreadable.json"
exit_is 4 'an unreadable link map'; chmod 644 "$T/maps/rooted.map"
# spec: tools/objc-compat/provider.c LINKMAP_MAX -- a real consumer's map (Codex's is 174 MB) is read up to 256 MiB;
#       past that it is refused before it is read.
cp "$T/maps/rooted.map" "$T/maps/big.map"
perl -e 'my $l = "#" . ("p" x 1022) . "\n"; print $l for 1 .. 65537' >>"$T/maps/big.map"
evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/big.map" "$T/ev/big.json"
[ "$rc" = 0 ] || fail "a link map over 64 MiB: exit $rc"
dd if=/dev/null of="$T/maps/huge.map" bs=1 seek=268435457 2>/dev/null
evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/huge.map" "$T/ev/huge.json"
exit_is 4 'a link map over 256 MiB'; grep oversized-input "$T/err" >/dev/null || fail 'the oversized link map is not named'
rm -f "$T/maps/big.map" "$T/maps/huge.map"

# spec: scripts/objc-compat-build.sh header -- an unusable tool (a Drydock tarball that is not the pinned one, with no way to
#       fetch the right one) is cannot-measure, for each script that builds it.
DIGEST=$(sed -n 's/^DIGEST=//p' "$ROOT/components/objc-reader-drydock/version")
src_cache=${MAVERICKS_SOURCE_CACHE:-$HOME/Library/Caches/mavericks-sources}
[ -f "$src_cache/drydock-$DIGEST.tar.gz" ] || fail "the verified Drydock tarball is not in $src_cache"
mkdir -p "$T/tampered-sources" "$T/no-codeload"
cp "$src_cache/drydock-$DIGEST.tar.gz" "$T/tampered-sources/"
printf 'x' | dd of="$T/tampered-sources/drydock-$DIGEST.tar.gz" bs=1 seek=100 conv=notrunc 2>/dev/null
tampered() { MAVERICKS_SOURCE_CACHE="$T/tampered-sources" MAVERICKS_CODELOAD="file://$T/no-codeload" MAVERGREEN_OBJC_COMPAT_CACHE="$T/tampered-cache" "$@"; }
rc=0; tampered sh "$ROOT/scripts/objc-build-evidence.sh" --artifact "$T/root/bin/rooted" \
  --prestrip "$T/root/bin/rooted" --source-root "$FX" --link-map "$T/maps/rooted.map" --provider-prefix "$PFX" \
  --references "$REF" --output "$T/ev/tampered.json" 2>"$T/err" || rc=$?
exit_is 4 'build evidence with a tampered tool'
cp "$src_cache/drydock-$DIGEST.tar.gz" "$T/tampered-sources/" && printf 'x' | dd of="$T/tampered-sources/drydock-$DIGEST.tar.gz" bs=1 seek=100 conv=notrunc 2>/dev/null
rc=0; tampered sh "$ROOT/scripts/objc-compat.sh" --artifact "$T/root/bin/rooted" --root "$T/root" \
  --references "$REF" --report "$T/out/tampered" --mode strict --build-evidence "$T/ev/rooted.json" --provider-prefix "$PFX" 2>"$T/err" || rc=$?
exit_is 4 'analysis with a tampered tool'
cp "$src_cache/drydock-$DIGEST.tar.gz" "$T/tampered-sources/" && printf 'x' | dd of="$T/tampered-sources/drydock-$DIGEST.tar.gz" bs=1 seek=100 conv=notrunc 2>/dev/null
rc=0; tampered sh "$ROOT/scripts/objc-provider-link-args.sh" --prefix "$PFX" --link-map "$T/maps/t.map" >/dev/null 2>"$T/err" || rc=$?
exit_is 4 'link args with a tampered tool'

# spec: tools/objc-compat/provider.c header -- a root name and a class_addMethod with no attested provider behind them.
SRC="$FX/provider-impostor.c"; consumer "$T/root/bin/impostor" "$ALL"; SRC=
full "$T/root/bin/impostor" "$T/root/bin/impostor" "$T/root/bin/impostor.map" impostor
nonzero 'an impostor root and its own registration'; error_is unattested-method-registration 'impostor'

# spec: tools/objc-compat/main.m header -- removal after an earlier successful report: the old report is no token.
consumer "$T/root/bin/rooted" "$NO_ARCHIVE"
analyze "$T/root/bin/rooted" --build-evidence "$T/ev/rooted.json" --provider-prefix "$PFX"
nonzero 'provider removed, earlier evidence reused'; exit_is 4 'provider removed, earlier evidence reused'
full "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/root/bin/rooted.map" removed
nonzero 'provider removed, fresh evidence'; want_verdict unsupported 'provider removed, fresh evidence'
old=$(sed -n 's/.*"inputs": {"artifact": {"path": "[^"]*", "sha256": "\([0-9a-f]*\)".*/\1/p' "$T/cached-positive.json")
[ -n "$old" ] && [ "$old" != "$(sha "$T/root/bin/rooted")" ] || fail 'the cached positive report does not show it described another binary'

# spec: tools/objc-compat/source-evidence.c header -- source receipts. A provider body's sends to its own typed arguments
#       close only through the receipt of its verified prepared source (tools/objc-source-inventory.c), mapped to each
#       call instruction by the archive member's own line table and the evidence's atom mapping; an `id` receiver stays
#       open; a send added to the source is its own block; changed source, no line table, a send the receipt does not
#       explain, or a malformed receipt is cannot-measure. The consumer's code is never closed by a provider's receipt.
CLANG=${MAVERGREEN_OBJC_CLANG_PREFIX:-}
if [ -z "$CLANG" ]; then
  case "$(uname -m)" in x86_64) short=clang22; flavor=native ;; arm64) short=clang22-cross; flavor=cross ;; *) exit 4 ;; esac
  version=$(tr -d '[:space:]' < "$ROOT/components/objc-reference-clang/version")
  CLANG=$(sh "$ROOT/scripts/fetch_product_pkg.sh" --asset "mavericks-clang-22-$flavor-$version.pkg" "$short" "$version" "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/objc-reference-$short-$version")
fi

# spec: tools/objc-compat/provider.c obj_target -- a provider's 8-byte literal is matched where the linker merged it:
#       ld64 into __TEXT,__const, lld (which links Codex) into __TEXT,__literals.
if [ "$real" = 0 ]; then
  PFX_MAIN=$PFX; PFX="$T/pfx-literal"; fixture_prefix "$PFX" -DFIXTURE_LITERAL
  consumer "$T/root/bin/lit-ld64" "$ALL"
  full "$T/root/bin/lit-ld64" "$T/root/bin/lit-ld64" "$T/root/bin/lit-ld64.map" lit-ld64; positive 'a literal, linked by ld64'
  cc() { env -i PATH=/usr/bin:/bin "$CLANG/bin/clang" -fuse-ld=lld -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 "$@"; }
  consumer "$T/root/bin/lit-lld" "$ALL"
  cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 "$@"; }
  otool -l "$T/root/bin/lit-lld" | grep 'sectname __literals' >/dev/null || fail 'lld did not merge the literal into __TEXT,__literals'
  full "$T/root/bin/lit-lld" "$T/root/bin/lit-lld" "$T/root/bin/lit-lld.map" lit-lld; positive 'a literal, linked by lld'
  PFX=$PFX_MAIN
fi
# spec: tests/fixtures/objc-api/provider-body.m header -- body_source DIR [DEFINE...]: the body, with each DEFINE turned on
#       by a line added to the source itself (a different file, not a compiler flag), and the registration member beside it.
body_source() {
  d=$1; shift; mkdir -p "$d"; : >"$d/provider-body.m"
  for def in "$@"; do printf '#define %s 1\n' "$def" >>"$d/provider-body.m"; done
  cat "$FX/provider-body.m" >>"$d/provider-body.m"; cp "$FX/provider-register.c" "$d/provider-register.c"
}
# spec: tests/fixtures/objc-api/provider-body.m header -- body_prefix PREFIX SRCDIR [CC-FLAGS]: that source archived and
#       declared as fixture_prefix declares its own, with its source receipt at PREFIX.receipt (none when RECEIPT=0).
body_prefix() {
  P=$1 D=$2; shift 2
  rm -rf "$P" "$P.objects"; mkdir -p "$P/lib" "$P/share/recaulk" "$P.objects"
  cc -Os -fPIC -Wall -fno-objc-arc "$@" -c "$D/provider-body.m" -o "$P.objects/provider-body.o" || fail "compiling $D/provider-body.m"
  cc -Os -fPIC -Wall "$@" -c "$D/provider-register.c" -o "$P.objects/provider-register.o"
  /usr/bin/libtool -static -o "$P/lib/libfixture-objc.a" "$P.objects/provider-body.o" "$P.objects/provider-register.o" 2>/dev/null
  printf '%s  provider-body.m\n%s  provider-register.c\n' "$(sha "$D/provider-body.m")" "$(sha "$D/provider-register.c")" >"$P.inputs"
  declare_prefix "$P" "$P.inputs"
  if [ "${RECEIPT:-1}" = 1 ]; then
    rm -f "$P.receipt"
    sh "$ROOT/scripts/objc-source-inventory.sh" --clang-prefix "$CLANG" --inputs "$P.inputs" --root "$D" \
      --unit provider-body.m --unit provider-register.c --output "$P.receipt" 2>"$T/err" || fail "source inventory of $D"
  fi
}
# spec: tools/objc-compat/source-evidence.c header -- body NAME PREFIX [RECEIPT]: link the consumer with PREFIX, build its
#       evidence and analyze it strictly, with RECEIPT as --source-receipt when given.
body() {
  save=$PFX; PFX=$2
  consumer "$T/root/bin/$1" "$ALL"
  evidence "$T/root/bin/$1" "$T/root/bin/$1" "$T/root/bin/$1.map" "$T/ev/$1.json" "$2"; [ "$rc" = 0 ] || fail "$1: build evidence exit $rc"
  if [ -n "${3:-}" ]; then analyze "$T/root/bin/$1" --build-evidence "$T/ev/$1.json" --provider-prefix "$2" --source-receipt "$3"
  else analyze "$T/root/bin/$1" --build-evidence "$T/ev/$1.json" --provider-prefix "$2"; fi
  PFX=$save
}
finding() { grep "\"selector\": \"$1\"" "$T/report" | grep '"function": "___fixture_objc_workspace_open_urls"' || :; }
finding_is() {   # finding_is SELECTOR VERDICT CLOSURE WHY: every body send of SELECTOR has VERDICT and receiver_closure CLOSURE
  got=$(finding "$1"); [ -n "$got" ] || fail "$4: no body send of $1"
  ! printf '%s\n' "$got" | grep -v "\"verdict\": \"$2\"" >/dev/null || fail "$4: a body send of $1 is not $2"
  ! printf '%s\n' "$got" | grep -v "\"receiver_closure\": $3" >/dev/null || fail "$4: a body send of $1 is not closed by $3"
}
body_source "$T/body"; body_prefix "$T/pfx-body" "$T/body" -g
body plain-body "$T/pfx-body"
exit_is 1 'body without its source receipt'; want_verdict provided 'body without its source receipt'
finding_is isFileURL unresolved null 'body without its source receipt'
body sourced-body "$T/pfx-body" "$T/pfx-body.receipt"
exit_is 0 'body with its source receipt'; want_verdict provided 'body with its source receipt'
for s in isFileURL count objectForKey:; do finding_is "$s" floor-supported '"source"' 'body with its source receipt'; done
grep "\"source_receipt\": {\"sha256\": \"$(sha "$T/pfx-body.receipt")\"}" "$T/report" >/dev/null || fail 'the report does not identify the source receipt'
grep '"function": "_main"' "$T/report" | grep '"receiver_closure": "source"' >/dev/null && fail "the consumer's own send was closed by the provider's receipt"

body_source "$T/body-id" FIXTURE_ID_SEND; body_prefix "$T/pfx-id" "$T/body-id" -g
body id-body "$T/pfx-id" "$T/pfx-id.receipt"
exit_is 1 'an id receiver in the body'; finding_is allKeys unresolved null 'an id receiver in the body'
finding allKeys | grep 'static type id' >/dev/null || fail 'the open id send does not say its static type is id'
# spec: tools/objc-compat/classify.c header -- R1 (b), amended: the same id local, vended by -[NSDictionary objectForKey:],
#       closes for isKindOfClass:, a reviewed root selector, and for nothing else.
finding_is isKindOfClass: floor-supported null 'an id receiver in the body'
finding isKindOfClass: | grep '"r1": true' | grep -F 'accepted residual risk: NSLeafProxy Object' >/dev/null ||
  fail "the id local's isKindOfClass: is not closed by R1 with its residual risk"
finding_is isFileURL floor-supported '"source"' 'an id receiver in the body'

body_source "$T/body-mut" FIXTURE_MUTATION; body_prefix "$T/pfx-mut" "$T/body-mut" -g
body mutated-body "$T/pfx-mut" "$T/pfx-mut.receipt"
exit_is 1 'an unguarded send added to the body'; finding_is hasDirectoryPath unsupported '"source"' 'an unguarded send added to the body'
finding hasDirectoryPath | grep '"id": "x86_64@0x[0-9a-f]*:-\[NSURL hasDirectoryPath\]"' >/dev/null || fail 'the added send is not its own block'
finding_is isFileURL floor-supported '"source"' 'an unguarded send added to the body'
cp "$T/report" "$T/mutated-report"

# spec: tools/objc-compat/source-evidence.c header -- a body send the receipt cannot speak for, because the binary gives no
#       selector there or the line table gives it no source line, stays open: an unresolved, blocking finding with its reason,
#       not cannot-measure, so the rest of the report stands. Other evidence may still close it.
body_source "$T/body-merged" FIXTURE_MERGED; body_prefix "$T/pfx-merged" "$T/body-merged" -g
body merged-body "$T/pfx-merged" "$T/pfx-merged.receipt"
exit_is 1 'a send with a merged selector in the body'
! grep -F unmapped-source-send "$T/report" >/dev/null || fail 'a send with a merged selector in the body is cannot-measure'
grep '"function": "___fixture_objc_workspace_open_urls"' "$T/report" | grep '"selector": null' | grep '"verdict": "unresolved"' |
  grep -F 'the binary gives no selector here, so the source receipt cannot close it' >/dev/null ||
  fail 'the send with a merged selector is not an unresolved finding that says why'
finding_is isFileURL floor-supported '"source"' 'a send with a merged selector in the body'
body_source "$T/body-line0" FIXTURE_LINE0; body_prefix "$T/pfx-line0" "$T/body-line0" -g
body line0-body "$T/pfx-line0" "$T/pfx-line0.receipt"
exit_is 1 'a send at line 0 in the body'
! grep -F unmapped-source-send "$T/report" >/dev/null || fail 'a send at line 0 in the body is cannot-measure'
grep '"function": "_line0"' "$T/report" | grep '"selector": "lastObject"' | grep '"verdict": "unresolved"' |
  grep -F 'the line table attributes this send to no source line, so the source receipt cannot close it' >/dev/null ||
  fail 'the line-0 send does not say why it stays open'
finding_is isFileURL floor-supported '"source"' 'a send at line 0 in the body'

body mutated-stale "$T/pfx-mut" "$T/pfx-body.receipt"
exit_is 4 'the receipt of the unchanged source'; error_is source-receipt-stale 'the receipt of the unchanged source'
RECEIPT=0 body_prefix "$T/pfx-nog" "$T/body"
body no-lines "$T/pfx-nog" "$T/pfx-body.receipt"
exit_is 4 'an archive without line tables'; error_is no-line-table 'an archive without line tables'
grep -v "	isFileURL	" "$T/pfx-body.receipt" >"$T/short.receipt"
body unexplained "$T/pfx-body" "$T/short.receipt"
exit_is 4 'a send the receipt does not explain'; error_is unmapped-source-send 'a send the receipt does not explain'
sed 's/^profile	.*/profile	something-else/' "$T/pfx-body.receipt" >"$T/profile.receipt"
body other-profile "$T/pfx-body" "$T/profile.receipt"
exit_is 4 'a receipt from another profile'; error_is malformed-source-receipt 'a receipt from another profile'
# spec: tools/objc-compat/source-evidence.c header -- the receipt's tool line must be this analyzer's own
#       tools/objc-source-inventory.c: a receipt written by an edited or other tool is cannot-measure.
grep -Fx "$(printf 'tool\t%s' "$(sha "$ROOT/tools/objc-source-inventory.c")")" "$T/pfx-body.receipt" >/dev/null ||
  fail 'the source receipt does not name the committed inventory tool'
sed 's/^tool	.*/tool	0ed0bd43e87a32b32aafb495a459e2248e2136ae1b7358e725fc654b2c33b676/' "$T/pfx-body.receipt" >"$T/tool.receipt"
body other-tool "$T/pfx-body" "$T/tool.receipt"
exit_is 4 'a receipt from another tool source'; error_is source-receipt-tool-mismatch 'a receipt from another tool source'
rc=0; sh "$ROOT/scripts/objc-compat.sh" --artifact "$T/root/bin/sourced-body" --root "$T/root" --references "$REF" --report "$T/out/noprefix" \
  --mode strict --source-receipt "$T/pfx-body.receipt" 2>"$T/err" || rc=$?
exit_is 2 'a source receipt without a provider prefix'
rm -f "$T/again.receipt"
sh "$ROOT/scripts/objc-source-inventory.sh" --clang-prefix "$CLANG" --inputs "$T/pfx-body.inputs" --root "$T/body" \
  --unit provider-body.m --unit provider-register.c --output "$T/again.receipt" 2>"$T/err" || fail 'second inventory'
cmp -s "$T/again.receipt" "$T/pfx-body.receipt" || fail 'the source receipt is not deterministic'
printf '\n' >>"$T/body/provider-body.m"
rc=0; sh "$ROOT/scripts/objc-source-inventory.sh" --clang-prefix "$CLANG" --inputs "$T/pfx-body.inputs" --root "$T/body" \
  --unit provider-body.m --unit provider-register.c --output "$T/changed.receipt" 2>"$T/err" || rc=$?
exit_is 4 'inventory of a source that no longer hashes to its input list'; [ ! -e "$T/changed.receipt" ] || fail 'a refused inventory wrote a receipt'
rc=0; sh "$ROOT/scripts/objc-source-inventory.sh" --clang-prefix "$CLANG" --inputs "$T/pfx-body.inputs" --root "$T/body" \
  --unit provider-body.m --output "$T/pfx-body.receipt" 2>"$T/err" || rc=$?
exit_is 2 'inventory onto an existing receipt'

if [ -n "${MAVERGREEN_OBJC_CODEX_ARTIFACT:-}" ]; then
  mkdir -p "$T/root/codex"
  ln "$MAVERGREEN_OBJC_CODEX_ARTIFACT" "$T/root/codex/codex" 2>/dev/null || cp "$MAVERGREEN_OBJC_CODEX_ARTIFACT" "$T/root/codex/codex"
  analyze "$T/root/codex/codex" --build-evidence "$FX/codex-0.165.0-build-evidence.json" --provider-prefix "$PFX"
  exit_is 1 'original Codex with the provider installed'; want_verdict unsupported 'original Codex'
  grep '"status": "inactive"' "$T/report" >/dev/null || fail 'original Codex: the provider is not reported inactive'
fi
echo "objc-provider: link arguments, positive and every mutation pass ($([ "$real" = 1 ] && echo "Recaulk provider $PFX" || echo 'fixture provider'))"
