#!/bin/sh
# platform: host-agnostic -- clang22 links x86_64 consumers of an Objective-C provider archive against the pinned 10.9 SDK, then reads them as bytes
# spec: src/objc/provider.c header -- a send is `provided` only when the provider's attested
#       archive member is linked into the final artifact byte for byte, its constructor is in the
#       initializer table, its registration names the declared class, selector and ABI, and its
#       frameworks are strongly loaded; every mutation below is nonzero.
#       The provider is MAVERGREEN_OBJC_RECAULK_PREFIX when set (a prefix from Recaulk's
#       build/build-objc.sh: lib/librecaulk-objc.a and share/recaulk/objc-providers.json), else the
#       fixture provider built here in the same shape. MAVERGREEN_OBJC_CODEX_ARTIFACT, when set, is
#       the original Codex 0.165.0 binary, which must still fail. MAVERGREEN_OBJC_RECAULK_RECEIPT, with the Recaulk
#       prefix, is that provider's source receipt (drydock-objc receipt): its body's sends then close where
#       their static types name a class, every one is mapped, and the rest stay open. Nothing built here is executed.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
. "$ROOT/tests/lib/toolchain.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-provider-test.XXXXXX")
trap 'chmod -R u+rw "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
fxcc() { env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 "$@"; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
mkdir -p "$T/root/bin" "$T/maps" "$T/ev" "$T/out" "$T/src"

# spec: tests/objc/lib/objc_fixture_provider.sh -- fixture_prefix DIR [CC-FLAGS] and declare_prefix DIR RECEIPT.
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

# spec: cli/drydock-objc.c header (link-args) -- link-args PREFIX MAP: the helper's lines into $T/args.
link_args() { rc=0; "$DRYDOCK_OBJC" link-args --prefix "$1" --link-map "$2" >"$T/args" 2>"$T/err" || rc=$?; }
# spec: cli/drydock-objc.c header (link-args) -- consumer OUT FILTER [cc args]: the fixture consumer
#       linked with the helper's lines after FILTER (an awk program over them), and a link map at OUT.map.
consumer() {
  out=$1 filter=$2 src=${SRC:-$FX/provider-consumer.m}; shift 2
  link_args "$PFX" "$out.map"; [ "$rc" = 0 ] || fail "link args for $PFX: exit $rc"
  awk "$filter" "$T/args" >"$T/args.f"
  while IFS= read -r line; do set -- "$@" "$line"; done <"$T/args.f"
  fxcc -O1 "$src" "$@" -o "$out" || fail "linking $out"
}
ALL='{print}'
NO_ROOT='!/^-Wl,-u,/'
NO_ARCHIVE='!/\.a$/ && !/^-Wl,-u,/'
# spec: cli/drydock-objc.c header (link-args) -- fwflag NAME FLAG: rewrite "-framework" "NAME" as the one argument
#       FLAG,NAME (a linker flag the compiler driver passes through), or drop it.
fwflag() {
  printf '{l[NR]=$0} END{for(i=1;i<=NR;i++){if(l[i]=="-framework" && l[i+1]=="%s"){if("%s"!="") print "%s,%s"; i++; continue} print l[i]}}' "$1" "$2" "$2" "$1"
}
# spec: cli/drydock-objc.c header (evidence) -- evidence ARTIFACT PRESTRIP MAP OUT [PREFIX]: rc set.
evidence() {
  rm -f "$T/report"
  rc=0; "$DRYDOCK_OBJC" evidence --artifact "$1" --prestrip "$2" --source-root "$FX" --link-map "$3" \
    --provider-prefix "${5:-$PFX}" --references "$REF" --output "$4" 2>"$T/err" || rc=$?
}
n=0
# spec: cli/drydock-objc.c header (analyze) -- analyze ARTIFACT [options]: strict, with this provider prefix; rc and $T/report.
analyze() {
  art=$1; shift; n=$((n + 1)); rep="$T/out/report.$n"
  rc=0; "$DRYDOCK_OBJC" analyze --artifact "$art" --root "$T/root" --references "$REF" --report "$rep" --mode strict "$@" 2>"$T/err" || rc=$?
  ln -sf "$rep" "$T/report"
}
verdict() { grep "\"selector\": \"$SEL\"" "$T/report" | sed -n 's/.*"verdict": "\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' '; }
want_verdict() { got=$(verdict); [ "$got" = "$1 " ] || fail "$2: openURLs is '${got:-no finding}', want $1 (exit $rc)"; }
nonzero() { [ "$rc" != 0 ] || fail "$1: exit 0"; [ "$(verdict)" != "provided " ] || fail "$1: openURLs became provided"; }
reason_has() { grep -F "\"reason\": \"$1" "$T/report" >/dev/null || grep -F "$1" "$T/report" | grep '"reason"' >/dev/null || fail "$2: the provider reason does not say '$1'"; }
exit_is() { [ "$rc" = "$1" ] || fail "$2: exit $rc, want $1"; }
error_is() { grep "\"code\": \"$1\"" "$T/report" >/dev/null || fail "$2: no $1 error"; }
# spec: src/objc/provider.c header -- full ARTIFACT PRESTRIP MAP NAME: evidence then a strict analysis.
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
# spec: src/objc/provider.c header -- put32/put64 FILE OFFSET VALUE: little-endian patch in place.
putn() {
  f=$1 off=$2 v=$3 k=$4 i=0 b=''
  while [ "$i" -lt "$k" ]; do b="$b$(printf '\\%03o' $(( (v >> (8 * i)) & 255 )))"; i=$((i + 1)); done
  printf "$b" | dd of="$f" bs=1 seek="$off" conv=notrunc 2>/dev/null
}
# spec: src/objc/provider.c header -- fileoff FILE VA: the file offset of a mapped address.
fileoff() {
  "$OTOOL" -l "$1" | awk -v va="$2" '
    $1=="addr" {a=hx($2)} $1=="size" && a {s=hx($2)} $1=="offset" && a {
      if (va+0 >= a && va+0 < a+s) {print $2 + (va - a); exit} a=0 }
    function hx(h,  i,c,n) {n=0; h=tolower(h); sub(/^0x/,"",h); for(i=1;i<=length(h);i++){c=index("0123456789abcdef",substr(h,i,1))-1; n=n*16+c} return n}'
}
symaddr() { "$NM" "$1" | awk -v s="$2" '$3==s {print "0x" $1; exit}'; }

# spec: cli/drydock-objc.c header (link-args) -- one argument per line from the validated declaration;
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


fixture_prefix "$T/multi"
EXTRA=',
    { "provider_id" : "fixture.nslocale.language-code.v1", "class" : "NSLocale", "method_kind" : "-",
      "selector" : "languageCode", "encoding" : "@16@0:8", "implementation_symbol" : "__fixture_objc_locale_language_code",
      "activation_root" : "__fixture_objc_activate_foundation", "required_frameworks" : [ "Foundation" ],
      "framework_policy" : "strong-linked-before-root" },
    { "provider_id" : "fixture.nslocale.country-code.v1", "class" : "NSLocale", "method_kind" : "-",
      "selector" : "countryCode", "encoding" : "@16@0:8", "implementation_symbol" : "__fixture_objc_locale_country_code",
      "activation_root" : "__fixture_objc_activate_foundation", "required_frameworks" : [ "Foundation", "CoreFoundation" ],
      "framework_policy" : "strong-linked-before-root" }'
declare_prefix "$T/multi" "$T/fixture-receipt" "$EXTRA"
MA=$(CDPATH= cd -- "$T/multi" && pwd -P)/lib/libfixture-objc.a
M="$T/maps/m.map"
LANG_ID=fixture.nslocale.language-code.v1
COUNTRY_ID=fixture.nslocale.country-code.v1
WS_ID=fixture.nsworkspace.open-urls.v1
# spec: cli/drydock-objc.c header (link-args) -- sel_args WANT-RC [--provider ID]...: link-args on the three-provider prefix into $T/args.
sel_args() {
  want=$1; shift; rc=0
  "$DRYDOCK_OBJC" link-args --prefix "$T/multi" --link-map "$M" "$@" >"$T/args" 2>"$T/err" || rc=$?
  [ "$rc" = "$want" ] || fail "link-args $*: exit $rc, want $want"
}
# spec: cli/drydock-objc.c header (link-args) -- sel_want NAME ARG...: $T/args is exactly the lines ARG...
sel_want() {
  tname=$1; shift; printf '%s\n' "$@" >"$T/args.want"
  cmp -s "$T/args" "$T/args.want" || fail "$tname: got $(tr '\n' '|' <"$T/args"), want $(tr '\n' '|' <"$T/args.want")"
}
sel_args 0 --provider "$LANG_ID"
sel_want test_select_foundation "$MA" -Wl,-u,___fixture_objc_activate_foundation -framework Foundation -Xlinker -map -Xlinker "$M"
sel_args 0 --provider "$COUNTRY_ID" --provider "$LANG_ID"
sel_want test_shared_root_once "$MA" -Wl,-u,___fixture_objc_activate_foundation -framework Foundation -framework CoreFoundation -Xlinker -map -Xlinker "$M"
sel_args 0 --provider "$WS_ID"
sel_want test_select_workspace "$MA" -Wl,-u,___fixture_objc_activate -framework AppKit -framework Carbon -Xlinker -map -Xlinker "$M"
sel_args 0
sel_want test_all_equals_none "$MA" -Wl,-u,___fixture_objc_activate -Wl,-u,___fixture_objc_activate_foundation -framework AppKit -framework Carbon -framework Foundation -framework CoreFoundation -Xlinker -map -Xlinker "$M"
cp "$T/args" "$T/args.none"
sel_args 0 --provider "$WS_ID" --provider "$LANG_ID" --provider "$COUNTRY_ID"
cmp -s "$T/args" "$T/args.none" || fail "test_all_equals_none: naming every provider differs from naming none"
sel_args 0 --provider "$LANG_ID" --provider "$LANG_ID"
sel_want test_repeat_is_once "$MA" -Wl,-u,___fixture_objc_activate_foundation -framework Foundation -Xlinker -map -Xlinker "$M"
rc=0; "$DRYDOCK_OBJC" link-args --provider "$LANG_ID" --prefix "$T/multi" --link-map "$M" >"$T/args" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "test_order_free: exit $rc"
sel_want test_order_free "$MA" -Wl,-u,___fixture_objc_activate_foundation -framework Foundation -Xlinker -map -Xlinker "$M"
sel_args 2 --provider "$LANG_ID" --provider no.such.v1
[ ! -s "$T/args" ] || fail "test_unknown_id: stdout not empty"
for id in no.such.v1 "$LANG_ID" "$COUNTRY_ID" "$WS_ID"; do
  grep -F "$id" "$T/err" >/dev/null || fail "test_unknown_id: stderr lacks $id"
done
sel_args 2 --provider ""
[ ! -s "$T/args" ] || fail "test_empty_id: stdout not empty"
sel_args 2 --provider
[ ! -s "$T/args" ] || fail "test_trailing_provider: stdout not empty"
sel_args 2 --provider "$(printf 'a\tb')"
[ ! -s "$T/args" ] || fail "test_control_id: stdout not empty"
sel_args 2 --provider "$(printf 'a\377b')"
[ ! -s "$T/args" ] || fail "test_bad_utf8_id: stdout not empty"
rm -rf "$T/multi-bad"; cp -R "$T/multi" "$T/multi-bad"
sed 's/"archive_sha256" : "[0-9a-f]*"/"archive_sha256" : "0000000000000000000000000000000000000000000000000000000000000000"/' "$T/multi/share/recaulk/objc-providers.json" >"$T/multi-bad/share/recaulk/objc-providers.json"
rc=0; "$DRYDOCK_OBJC" link-args --prefix "$T/multi-bad" --link-map "$M" --provider no.such.v1 >"$T/args" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] || fail "test_invalid_decl_first: exit $rc, want 4"
consumer "$T/root/bin/rooted" "$ALL"
cp "$T/root/bin/rooted.map" "$T/maps/rooted.map"
# spec: cli/drydock-objc.c header (link-args) -- the helper's own output never attests activation:
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
"$STRIP" -o "$T/root/bin/rooted" "$T/rooted.prestrip"
full "$T/root/bin/rooted" "$T/rooted.prestrip" "$T/maps/rooted.map" stripped
positive 'stripped final artifact with prestrip evidence'
cp "$T/rooted.prestrip" "$T/root/bin/rooted"

# spec: src/objc/main.c (load_provider_prefix) -- schema 2: groups under `providers`, schema-1-shaped entries under
#       `legacy_providers`, exact key sets, no (class, kind, selector) claimed twice; evidence records a group once.
G_LOC='{ "provider_id" : "fixture.nslocale.group.v1", "class" : "NSLocale", "guard" : "absent-only",
      "activation_root" : "__fixture_objc_activate", "required_frameworks" : [ "AppKit", "Foundation" ],
      "framework_policy" : "strong-linked-before-root", "methods" : [
        { "kind" : "-", "selector" : "languageCode", "encoding" : "@16@0:8", "implementation_symbol" : "__fixture_objc_locale_language_code" },
        { "kind" : "+", "selector" : "countryCode", "encoding" : "@16@0:8", "implementation_symbol" : "__fixture_objc_locale_country_code" } ] }'
schema2() {  # schema2 NAME GROUPS [SED]: a copy of the prefix whose declaration is schema 2, its entries legacy, GROUPS the groups
  rm -rf "$T/s2-$1"; cp -R "$PFX" "$T/s2-$1"
  sed -e 's/"schema" : 1,/"schema" : 2, "providers" : ['"$(printf '%s' "$2" | tr '\n' ' ' | sed 's/[&|\\]/\\&/g')"'],/' \
      -e 's/"providers" : \[$/"legacy_providers" : [/' -e "${3:-s/@@@@//}" "$DECL" >"$T/s2-$1/share/recaulk/objc-providers.json"
}
s2_refused() {  # s2_refused WHY NAME: link-args refuses the prefix as a malformed declaration
  link_args "$T/s2-$2" "$T/maps/s2.map"; [ "$rc" = 4 ] || fail "schema2: $1 accepted (exit $rc)"
  grep -F malformed-provider "$T/err" >/dev/null || fail "schema2: $1 not refused as malformed-provider: $(tail -2 "$T/err")"
  [ -z "${3:-}" ] || grep -F "$3" "$T/err" >/dev/null || fail "schema2: $1 refused for another reason: $(tail -2 "$T/err")"
}
schema2 legacy ''
s2consumer() {  # s2consumer NAME: the rooted consumer linked against schema2 prefix s2-NAME, its evidence at $T/ev/s2-NAME.json
  save=$PFX; PFX="$T/s2-$1"
  consumer "$T/root/bin/s2-$1" "$ALL"
  evidence "$T/root/bin/s2-$1" "$T/root/bin/s2-$1" "$T/root/bin/s2-$1.map" "$T/ev/s2-$1.json"
  PFX=$save
}
s2consumer legacy; [ "$rc" = 0 ] || fail "schema2: evidence over a legacy entry: exit $rc"
analyze "$T/root/bin/s2-legacy" --build-evidence "$T/ev/s2-legacy.json" --provider-prefix "$T/s2-legacy"
positive 'schema2: the fixture'"'"'s provider as a legacy entry is still provided'
[ "$(grep -c '"provider_id"' "$T/ev/s2-legacy.json")" = 1 ] || fail 'schema2: a legacy entry is not one evidence record'
schema2 group "$G_LOC"
s2consumer group
[ "$rc" = 0 ] || fail "schema2: a group's build evidence: exit $rc"
[ "$(grep -c '"provider_id"' "$T/ev/s2-group.json")" = 2 ] || fail 'schema2: group plus legacy entry are not two evidence records'
[ "$(grep -c '"provider_id": "fixture.nslocale.group.v1"' "$T/ev/s2-group.json")" = 1 ] || fail 'schema2: a group is not recorded exactly once'
analyze "$T/root/bin/s2-group" --build-evidence "$T/ev/s2-group.json" --provider-prefix "$T/s2-group"
exit_is 4 'schema2: a group declaring +[NSLocale countryCode], which the newer SDK does not'
error_is provider-abi-mismatch 'schema2: a group declaring +[NSLocale countryCode]'
grep -F 'fixture.nslocale.group.v1: declared +NSLocale countryCode' "$T/report" >/dev/null || fail 'schema2: the ABI refusal does not name the group and member'
link_args "$T/s2-group" "$T/maps/s2.map" ; rc=0
"$DRYDOCK_OBJC" link-args --prefix "$T/s2-group" --link-map "$T/maps/s2.map" --provider fixture.nslocale.group.v1 >"$T/args" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "schema2: link-args for a group: exit $rc"
S2A=$(CDPATH= cd -- "$T/s2-group" && pwd -P)/$(field archive_path)
printf '%s\n' "$S2A" -Wl,-u,___fixture_objc_activate -framework AppKit -framework Foundation \
  -Xlinker -map -Xlinker "$T/maps/s2.map" >"$T/args.want"
cmp -s "$T/args" "$T/args.want" || fail "schema2: link-args for a group: got $(tr '\n' '|' <"$T/args")"
schema2 unknown-key "$G_LOC" 's/"guard" : "absent-only"/"guard" : "absent-only", "extra" : 1/'
s2_refused 'an unknown key' unknown-key
schema2 unknown-method-key "$(printf '%s' "$G_LOC" | sed 's/"kind" : "+",/"kind" : "+", "extra" : 1,/')"
s2_refused 'an unknown method key' unknown-method-key
schema2 guard "$(printf '%s' "$G_LOC" | sed 's/"absent-only"/"always"/')"
s2_refused 'a guard other than absent-only' guard 'provider group is not a valid'
schema2 no-methods '{ "provider_id" : "fixture.nslocale.group.v1", "class" : "NSLocale", "guard" : "absent-only",
      "activation_root" : "__fixture_objc_activate", "required_frameworks" : [ "AppKit" ],
      "framework_policy" : "strong-linked-before-root", "methods" : [] }'
s2_refused 'an empty methods list' no-methods 'provider group is not a valid'
schema2 dup-groups "$G_LOC, $(printf '%s' "$G_LOC" | sed 's/group\.v1/other.v1/')"
s2_refused 'a selector claimed by two groups' dup-groups 'declared twice'
schema2 dup-in-group "$(printf '%s' "$G_LOC" | sed 's/"kind" : "+"/"kind" : "-"/; s/"selector" : "countryCode"/"selector" : "languageCode"/')"
s2_refused 'a selector claimed twice in a group' dup-in-group 'declared twice'
schema2 dup-legacy "$(printf '%s' "$G_LOC" | sed 's/"class" : "NSLocale"/"class" : "NSWorkspace"/; s/"selector" : "languageCode"/"selector" : "'"$SEL"'"/')"
s2_refused 'a selector claimed by a group and a legacy entry' dup-legacy 'declared twice'

# spec: src/objc/main.c (load_group) -- an own-absent group names no class (its classes come from the root's call
#       sites), only instance members, an optional class_table data symbol and optional super_fallbacks records, each
#       naming one member's IMP and that member's selector; link-args roots nothing for it.
OWN_GROUP='{ "provider_id" : "fixture.bridge.accessibility.v1", "guard" : "own-absent",
      "activation_root" : "FixtureBridge", "required_frameworks" : [ "AppKit" ],
      "framework_policy" : "strong-linked-before-root", "class_table" : "FixtureBridgeClasses", "methods" : [
        { "kind" : "-", "selector" : "accessibilityAttributeNames", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureBridge_attributeNames" },
        { "kind" : "-", "selector" : "accessibilityAttributeValue:", "encoding" : "@24@0:8@16", "implementation_symbol" : "FixtureBridge_attributeValue" },
        { "kind" : "-", "selector" : "accessibilityIsIgnored", "encoding" : "c16@0:8", "implementation_symbol" : "FixtureBridge_isIgnored" } ],
      "super_fallbacks" : [ { "implementation_symbol" : "FixtureBridge_attributeNames", "selector" : "accessibilityAttributeNames" }, { "implementation_symbol" : "FixtureBridge_isIgnored", "selector" : "accessibilityIsIgnored" }, { "implementation_symbol" : "FixtureBridge_attributeValue", "selector" : "accessibilityAttributeValue:" } ] }'
own_sed() { printf '%s' "$OWN_GROUP" | sed "$1"; }
schema2 own "$OWN_GROUP"
link_args "$T/s2-own" "$T/maps/s2.map"
[ "$rc" = 0 ] || fail "own-absent: link-args: exit $rc: $(tail -2 "$T/err")"
! grep -x -- '-Wl,-u,_FixtureBridge' "$T/args" >/dev/null || fail 'own-absent: link-args roots the bridge'
grep -x -- "-Wl,-u,_$ACTIVATE" "$T/args" >/dev/null || fail 'own-absent: link-args no longer roots the legacy entry beside it'
grep -x -- "$(CDPATH= cd -- "$T/s2-own" && pwd -P)/$(field archive_path)" "$T/args" >/dev/null || fail 'own-absent: link-args roots nothing but names no archive'
awk 'p && $0 == "AppKit" { f = 1 } { p = $0 == "-framework" } END { exit !f }' "$T/args" || fail 'own-absent: link-args roots nothing but loads no AppKit'
schema2 own-class "$(own_sed 's/"guard" : "own-absent",/"guard" : "own-absent", "class" : "NSView",/')"
s2_refused 'own-absent: a group that names a class' own-class 'provider group is not a valid'
schema2 absent-noclass "$(own_sed 's/"own-absent"/"absent-only"/; /"super_fallbacks"/d; s/, "class_table" : "FixtureBridgeClasses"//; s/} ],$/} ] }/')"
s2_refused 'absent-only: a group that names no class' absent-noclass 'provider group is not a valid'
schema2 own-classmethod "$(own_sed 's/"kind" : "-", "selector" : "accessibilityIsIgnored"/"kind" : "+", "selector" : "accessibilityIsIgnored"/')"
s2_refused 'own-absent: a class-method member' own-classmethod 'a method of group'
schema2 own-struct "$(own_sed 's/"@16@0:8", "implementation_symbol" : "FixtureBridge_attributeNames"/"r{_NSRange=QQ}16@0:8", "implementation_symbol" : "FixtureBridge_attributeNames"/')"
s2_refused 'own-absent: a member returning a struct' own-struct 'returns a struct or union'
A11Y_ABSENT='{ "provider_id" : "fixture.nsview.a11y.v1", "class" : "NSView", "guard" : "absent-only",
      "activation_root" : "__fixture_objc_activate_table", "required_frameworks" : [ "AppKit" ],
      "framework_policy" : "strong-linked-before-root", "methods" : [
        { "kind" : "-", "selector" : "accessibilityLabel", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureA11y_accessibilityLabel" } ] }'
schema2 absent-fallbacks "$(printf '%s' "$A11Y_ABSENT" | sed 's/} ] }$/} ], "super_fallbacks" : [ { "implementation_symbol" : "FixtureA11y_accessibilityLabel", "selector" : "accessibilityLabel" } ] }/')"
s2_refused 'absent-only: super_fallbacks' absent-fallbacks 'provider group is not a valid'
schema2 absent-table "$(printf '%s' "$A11Y_ABSENT" | sed 's/"guard" : "absent-only",/"guard" : "absent-only", "class_table" : "FixtureBridgeClasses",/')"
s2_refused 'absent-only: class_table' absent-table 'provider group is not a valid'
schema2 own-badtable "$(own_sed 's/"FixtureBridgeClasses"/"Fixture-Bridge"/')"
s2_refused 'own-absent: a class_table that is not an identifier' own-badtable 'provider group is not a valid'
schema2 own-fallback-sel "$(own_sed 's/"selector" : "accessibilityAttributeValue:" } ]/"selector" : "accessibilityIsIgnored" } ]/')"
s2_refused "own-absent: a super_fallbacks record for another member's selector" own-fallback-sel super_fallbacks
schema2 own-fallback-shared "$(own_sed 's/"implementation_symbol" : "FixtureBridge_attributeNames"/"implementation_symbol" : "FixtureBridge_attributeValue"/')"
s2_refused 'own-absent: a super_fallbacks record whose IMP implements two members' own-fallback-shared super_fallbacks
schema2 own-fallback-dup "$(own_sed 's/} ] }$/}, { "implementation_symbol" : "FixtureBridge_attributeValue", "selector" : "accessibilityAttributeValue:" } ] }/')"
s2_refused 'own-absent: a super_fallbacks record declared twice' own-fallback-dup 'super_fallbacks record FixtureBridge_attributeValue accessibilityAttributeValue: is declared twice'
schema2 own-dup "$OWN_GROUP, $(own_sed 's/accessibility\.v1/other.v1/')"
s2_refused 'own-absent: a selector claimed by two own-absent groups' own-dup 'declared twice'
schema2 own-and-absent "$OWN_GROUP, $(printf '%s' "$A11Y_ABSENT" | sed 's/} ] }$/}, { "kind" : "-", "selector" : "accessibilityAttributeNames", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureA11y_accessibilityLabel" } ] }/')"
link_args "$T/s2-own-and-absent" "$T/maps/s2.map"
[ "$rc" = 0 ] || fail "own-absent and absent-only may name the same selector: exit $rc: $(tail -2 "$T/err")"

# spec: src/objc/provider.c header, "Groups" -- a schema-2 group is credited, as a whole, only from the registration
#       its constructor derives (src/objc/regexec.c): the root reached, nothing added where a member was found, exactly
#       the members added where nothing was, nothing else added anywhere, and that without a guess; every member absent
#       from 10.9 and declared with the newer SDK's encoding. tests/objc/fixtures/table-provider.m is the provider.
TAB_GROUP='{ "provider_id" : "fixture.nswindow.tabbing.v1", "class" : "NSWindow", "guard" : "absent-only",
      "activation_root" : "__fixture_objc_activate_table", "required_frameworks" : [ "AppKit" ],
      "framework_policy" : "strong-linked-before-root", "methods" : [
        { "kind" : "-", "selector" : "tabbingIdentifier", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureTab_tabbingIdentifier" },
        { "kind" : "-", "selector" : "setTabbingIdentifier:", "encoding" : "v24@0:8@16", "implementation_symbol" : "FixtureTab_setTabbingIdentifier" },
        { "kind" : "-", "selector" : "tabbingMode", "encoding" : "q16@0:8", "implementation_symbol" : "FixtureTab_tabbingMode" },
        { "kind" : "-", "selector" : "setTabbingMode:", "encoding" : "v24@0:8q16", "implementation_symbol" : "FixtureTab_setTabbingMode" },
        { "kind" : "+", "selector" : "allowsAutomaticWindowTabbing", "encoding" : "c16@0:8", "implementation_symbol" : "FixtureTab_allowsAutomaticWindowTabbing" },
        { "kind" : "+", "selector" : "setAllowsAutomaticWindowTabbing:", "encoding" : "v20@0:8c16", "implementation_symbol" : "FixtureTab_setAllowsAutomaticWindowTabbing" } ] }'
TAB_SELS='tabbingIdentifier setTabbingIdentifier: tabbingMode setTabbingMode: allowsAutomaticWindowTabbing setAllowsAutomaticWindowTabbing:'
# spec: src/objc/provider.c header, "Groups" -- group_prefix NAME [CC-FLAGS...]: UNIT (default table-provider.m; a list,
#       each SOURCE.m or SOURCE.m:MEMBER, MEMBER.o its object) built as Recaulk builds its tabbing units (ARC, -Os),
#       archived at $T/g-NAME and declared in schema 2 with GROUP (default TAB_GROUP) its one group.
group_prefix() {
  P="$T/g-$1"; shift
  rm -rf "$P" "$P.objects"; mkdir -p "$P/lib" "$P/share/recaulk" "$P.objects"; : >"$P.inputs"
  for u in ${UNIT:-table-provider.m}; do
    us=${u%%:*} uo=${u#*:}; [ "$uo" != "$u" ] || uo=${us%.m}
    fxcc -Os -fobjc-arc -fno-modules -fno-autolink -fPIC -Wall "$@" -c "$FX/$us" -o "$P.objects/$uo.o" ||
      fail "compiling $us $*"
    grep -F "  $us" "$P.inputs" >/dev/null || printf '%s  %s\n' "$(sha "$FX/$us")" "$us" >>"$P.inputs"
  done
  static_lib "$P/lib/libfixture-objc.a" "$P.objects"/*.o
  declare_prefix "$P" "$P.inputs"
  awk -v g="$(printf '%s' "${GROUP:-$TAB_GROUP}" | tr '\n' ' ')" '
    /"schema" : 1,/ { sub(/1,/, "2,") }
    /"providers" : \[$/ { print "  \"providers\" : [ " g " ],"; skip = 1; next }
    skip && /^  \],$/ { skip = 0; next }
    !skip' "$P/share/recaulk/objc-providers.json" >"$P.decl" && mv "$P.decl" "$P/share/recaulk/objc-providers.json"
}
# spec: src/objc/provider.c header, "Groups" -- group NAME PREFIX [CC-FLAGS...]: tests/objc/fixtures/table-consumer.m (with
#       CC-FLAGS) linked with $T/g-PREFIX at $T/root/bin/g-NAME, its build evidence, and a strict analysis.
group() {
  save=$PFX; PFX="$T/g-$2"; gn=$1; shift 2
  SRC="$FX/table-consumer.m"; consumer "$T/root/bin/g-$gn" "$ALL" "$@"; unset SRC
  evidence "$T/root/bin/g-$gn" "$T/root/bin/g-$gn" "$T/root/bin/g-$gn.map" "$T/ev/g-$gn.json"; [ "$rc" = 0 ] || fail "group $gn: build evidence exit $rc"
  analyze "$T/root/bin/g-$gn" --build-evidence "$T/ev/g-$gn.json" --provider-prefix "$PFX"
  PFX=$save
}
tab_verdict() { grep "\"selector\": \"$1\"" "$T/report" | grep '"function": "_main"' | sed -n 's/.*"verdict": "\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' '; }
tab_all() {  # tab_all VERDICT WHY: the consumer's send of each of the six members is VERDICT
  for s in $TAB_SELS; do got=$(tab_verdict "$s"); [ "$got" = "$1 " ] || fail "$2: $s is '${got:-no finding}', want $1 (exit $rc)"; done
}
says() { grep -F -- "$1" "$T/report" >/dev/null || fail "$2: the report does not say '$1': $(grep -F '"code"' "$T/report" | head -3)"; }
group_refused() {  # group_refused WHY CODE TEXT: cannot-measure with CODE saying TEXT, and no member provided
  exit_is 4 "$1"; error_is "$2" "$1"; says "$3" "$1"; tab_all unsupported "$1"
}
# spec: src/objc/provider.c header, "Groups" (own-absent) -- bridge NAME VARIANT [CONSUMER-FLAGS...]: bridge-provider.m built
#       with -DVARIANT (none for "-") and declared with GROUP (default OWN_GROUP), and table-consumer.m -DBRIDGE with
#       CONSUMER-FLAGS linked with it and analyzed as `group` does.
bridge() {
  b_n=$1 b_v=$2; shift 2
  GROUP=${GROUP:-$OWN_GROUP}; UNIT=bridge-provider.m; group_prefix "b-$b_n" $([ "$b_v" = - ] || echo "-D$b_v"); unset GROUP UNIT
  group "b-$b_n" "b-$b_n" -DBRIDGE "$@"
}
only_imps_block() {  # only_imps_block WHY: some send blocks, and every one that does is in a bridge IMP
  grep -E '"verdict": "(unresolved|unsupported)"' "$T/report" >/dev/null || fail "$1: no send blocks"
  ! grep -E '"verdict": "(unresolved|unsupported)"' "$T/report" | grep -v '"function": "_FixtureBridge_' >/dev/null ||
    fail "$1: a send outside the bridge IMPs blocks"
}
no_provided() { ! grep '"verdict": "provided"' "$T/report" >/dev/null || fail "$1: a send is provided"; }
imp_sends() {  # imp_sends SEL VERDICT TEXT WHY: the three bridge IMPs' sends of SEL are each VERDICT, the proof saying TEXT
  got=$(grep '"function": "_FixtureBridge_' "$T/report" | grep -F "\"selector\": \"$1\"" | sed -n 's/.*"verdict": "\([^"]*\)".*/\1/p' |
        sort | uniq -c | sed 's/^ *//' | tr '\n' ' ')
  [ "$got" = "3 $2 " ] || fail "$4: the IMPs' $1 sends are '${got:-none}', want 3 $2"
  ! grep '"function": "_FixtureBridge_' "$T/report" | grep -F "\"selector\": \"$1\"" | grep -vF -- "$3" >/dev/null ||
    fail "$4: an IMP's $1 send's proof does not say '$3'"
}
bridge_refused() {  # bridge_refused WHY CODE TEXT: cannot-measure with CODE saying TEXT, and nothing provided
  exit_is 4 "$1"; error_is "$2" "$1"; says "$3" "$1"; no_provided "$1"
}

group_prefix tab; group tab tab
exit_is 0 'group: the table provider is provided, all six'; tab_all provided 'group: the table provider is provided, all six'
grep '"status": "active"' "$T/report" >/dev/null || fail 'group: the table provider is not reported active'
says 'registers its 6 methods on NSWindow (71 paths from the constructor, 1 registering without a guess' 'group: the table provider'
! grep -F unused_super_fallbacks "$T/report" >/dev/null || fail 'report: unused_super_fallbacks without an own-absent group'
group_prefix reorder -DREORDER; group reorder reorder
exit_is 0 'group: REORDER provided'; tab_all provided 'group: REORDER provided'

group_prefix short -DSHORT; group short short
group_refused 'group: SHORT' provider-registration-mismatch 'missing +[NSWindow setAllowsAutomaticWindowTabbing:]'
group_prefix extra -DEXTRA_ROW; group extra extra
group_refused 'group: EXTRA_ROW' provider-registration-mismatch 'extra -[NSWindow tabbedWindows]'
group_prefix wrongimp -DWRONG_IMP; group wrongimp wrongimp
group_refused 'group: no member is provided when one check fails (WRONG_IMP)' provider-registration-mismatch \
  '-[NSWindow tabbingMode] implemented by _FixtureTab_tabbedWindows, declared _FixtureTab_tabbingMode'
group_prefix wrongtypes -DWRONG_TYPES; group wrongtypes wrongtypes
group_refused 'group: WRONG_TYPES' provider-registration-mismatch '-[NSWindow tabbingMode] typed i16@0:8, declared q16@0:8'
group_prefix kindswap -DKIND_SWAP; group kindswap kindswap
group_refused 'group: KIND_SWAP' provider-registration-mismatch \
  'missing +[NSWindow setAllowsAutomaticWindowTabbing:]; extra -[NSWindow setAllowsAutomaticWindowTabbing:]'
for v in NOGUARD NOPARTIAL; do
  group_prefix "$v" "-D$v"; group "$v" "$v"
  group_refused "group: $v" provider-guard-violation 'times after these lookups were found: +[NSWindow setAllowsAutomaticWindowTabbing:]'
done
group_prefix indirect -DINDIRECT; group indirect indirect
group_refused 'group: an executor refusal is cannot-measure' provider-unmeasurable 'fixture.nswindow.tabbing.v1: indirect-call: '

GROUP=$(printf '%s' "$TAB_GROUP" | sed 's/} ] }$/}, { "kind" : "-", "selector" : "title", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureTab_tabbedWindows" } ] }/')
group_prefix floor; unset GROUP; group floor floor
group_refused 'group: a member present on 10.9' provider-present-on-floor '-[NSWindow title] is present on 10.9, answered by NSWindow'
GROUP=$(printf '%s' "$TAB_GROUP" | sed 's/"q16@0:8"/"i16@0:8"/')
group_prefix abi; unset GROUP; group abi abi
group_refused 'group: a member declared with another encoding than the newer SDK' provider-abi-mismatch 'declared -NSWindow tabbingMode as i16@0:8'
# spec: src/objc/provider.c header, 2 -- a weak definition several members carry (each class adopting <NSObject> emits
#       __OBJC_PROTOCOL_$_NSObject) is linked from one copy: a reference to a copy the evidence does not place is
#       attested from the one other member's copy it places, and refused when it places none (the app's copy kept) or
#       two. tests/objc/fixtures/weak-a.m and weak-b.m are the provider; weak-c, weak-b.m again, is never linked.
WEAK_GROUP='{ "provider_id" : "fixture.nswindow.weak.v1", "class" : "NSWindow", "guard" : "absent-only",
      "activation_root" : "__fixture_objc_activate_weak", "required_frameworks" : [ "AppKit" ],
      "framework_policy" : "strong-linked-before-root", "methods" : [
        { "kind" : "-", "selector" : "tabbingIdentifier", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureWeak_tabbingIdentifier" },
        { "kind" : "-", "selector" : "tabbingMode", "encoding" : "q16@0:8", "implementation_symbol" : "FixtureWeak_tabbingMode" } ] }'
WEAK_PROTO='"symbol": "__OBJC_PROTOCOL_$_NSObject"'
weak_sends() {  # weak_sends VERDICT WHY: the consumer's sends of both members are VERDICT
  for s in tabbingIdentifier tabbingMode; do got=$(tab_verdict "$s"); [ "$got" = "$1 " ] || fail "$2: $s is '${got:-no finding}', want $1 (exit $rc)"; done
}
weak_refused() {  # weak_refused WHY TEXT: cannot-measure, the mapping refused saying TEXT, and neither member provided
  exit_is 4 "$1"; error_is provider-mapping-mismatch "$1"; says "$2" "$1"; weak_sends unsupported "$1"
}
GROUP=$WEAK_GROUP UNIT='weak-a.m weak-b.m weak-b.m:weak-c'; group_prefix weak; unset GROUP UNIT
group weak weak -DWEAK
exit_is 0 'weak: the kept copy attests'; weak_sends provided 'weak: the kept copy attests'
grep '"status": "active"' "$T/report" >/dev/null || fail 'weak: the kept copy attests: the group is not reported active'
[ "$(grep -F "$WEAK_PROTO" "$T/ev/g-weak.json" | sed -n 's/.*"member": "\([^"]*\)".*/\1/p' | sort -u)" = weak-a.o ] ||
  fail 'weak: the evidence does not place __OBJC_PROTOCOL_$_NSObject from weak-a.o alone'
sed "/\"member\": \"weak-a.o\", $WEAK_PROTO/{h;s/weak-a\.o/weak-c.o/;s/,*\$/,/;p;g;}" "$T/ev/g-weak.json" >"$T/ev/g-weak-twice.json"
analyze "$T/root/bin/g-weak" --build-evidence "$T/ev/g-weak-twice.json" --provider-prefix "$T/g-weak"
weak_refused 'weak: placed twice' \
  'weak-b.o(__OBJC_PROTOCOL_$_NSObject) is a weak definition the evidence places from 2 members'
sed 's/"symbol": "__OBJC_CLASS_RO_\$_FixtureWeakB"/"symbol": "__OBJC_CLASS_RO_$_FixtureWeakX"/' "$T/ev/g-weak.json" >"$T/ev/g-weak-lacks.json"
cmp -s "$T/ev/g-weak.json" "$T/ev/g-weak-lacks.json" && fail 'weak: the evidence does not place __OBJC_CLASS_RO_$_FixtureWeakB'
analyze "$T/root/bin/g-weak" --build-evidence "$T/ev/g-weak-lacks.json" --provider-prefix "$T/g-weak"
weak_refused 'weak: a non-weak symbol the evidence lacks' \
  'the evidence places no atom weak-b.o(__OBJC_CLASS_RO_$_FixtureWeakB)'
group weak-app weak -DWEAK -DWEAK_APP
weak_refused 'weak: kept from the app' 'is a weak definition the evidence places from 0 members'
# spec: src/objc/provider.c header, 2 -- weak_table NAME LONGS OTHER READ: weak-b.m reads long READ of weak-a.m's kept
#       LONGS-long FixtureWeakTable through the archive's first copy, weak-table.m's unloaded OTHER-long weak-0.o.
weak_table() {
  GROUP=$WEAK_GROUP UNIT='weak-a.m weak-b.m weak-table.m:weak-0'; group_prefix "$1" -DWEAK_TABLE="$2" -DWEAK_OTHER="$3" -DWEAK_READ="$4"
  unset GROUP UNIT; group "$1" "$1" -DWEAK
}
weak_table weak-table 4 4 3
exit_is 0 'weak: a reference through a discarded copy attests'; weak_sends provided 'weak: a reference through a discarded copy attests'
weak_table weak-size 2 4 1
weak_refused 'weak: a discarded copy of another size' 'weak-0.o(_FixtureWeakTable) is 32 bytes, its kept copy weak-a.o(_FixtureWeakTable) 16'
weak_table weak-past 2 2 2
weak_refused 'weak: a reference past the kept copy' \
  'reference to weak-0.o(_FixtureWeakTable)+16 lies past its kept copy weak-a.o(_FixtureWeakTable), 16 bytes'
# spec: src/objc/provider.c header, "Groups" -- a member the newer SDK declares as a required method of a protocol its class
#       adopts there (itself or by a superclass, directly or through an inherited protocol) is declared with that
#       protocol's encoding: NSView and NSCell adopt NSAccessibility, whose 10.10 methods Recaulk back-fills. A protocol
#       the class does not adopt, an optional method, another encoding or a method on the 10.9 floor is still refused.
A11Y_GROUP='{ "provider_id" : "fixture.nsview.accessibility.v1", "class" : "NSView", "guard" : "absent-only",
      "activation_root" : "__fixture_objc_activate_table", "required_frameworks" : [ "AppKit" ],
      "framework_policy" : "strong-linked-before-root", "methods" : [
        { "kind" : "-", "selector" : "setAccessibilityLabel:", "encoding" : "v24@0:8@16", "implementation_symbol" : "FixtureA11y_setAccessibilityLabel" },
        { "kind" : "-", "selector" : "accessibilityLabel", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureA11y_accessibilityLabel" } ] }'
a11y_all() {  # a11y_all VERDICT WHY: the consumer's send of each NSAccessibility member, to an NSButton, is VERDICT
  for s in setAccessibilityLabel: accessibilityLabel; do got=$(tab_verdict "$s"); [ "$got" = "$1 " ] || fail "$2: $s is '${got:-no finding}', want $1 (exit $rc)"; done
}
a11y() {  # a11y NAME WHY [CC-FLAGS...]: GROUP (default A11Y_GROUP) from table-provider.m's VIEW_A11Y, provided
  a_n=$1 a_w=$2; shift 2
  GROUP=${GROUP:-$A11Y_GROUP}; group_prefix "$a_n" -DVIEW_A11Y "$@"; unset GROUP; group "$a_n" "$a_n" -DVIEW_A11Y
  exit_is 0 "$a_w"; a11y_all provided "$a_w"
}
a11y view 'protocol: NSView adopts NSAccessibility'
says 'registers its 2 methods on NSView' 'protocol: NSView adopts NSAccessibility'
GROUP=$(printf '%s' "$A11Y_GROUP" | sed 's/"class" : "NSView"/"class" : "NSControl"/')
a11y control 'protocol: NSControl adopts NSAccessibility through NSView' '-DA11Y_CLASS="NSControl"'
says 'registers its 2 methods on NSControl' 'protocol: NSControl adopts NSAccessibility through NSView'
# spec: src/objc/reference.c load_sdk -- ref_with NAME AWK: $T/ref-NAME, the reference with newer-sdk.tsv rewritten by
#       the awk program AWK (tab-separated in and out) and its manifest digest recomputed.
ref_with() {
  rm -rf "$T/ref-$1"; mkdir -p "$T/ref-$1"; cp "$REF"/* "$T/ref-$1"/
  awk -F '\t' "BEGIN { OFS = \"\\t\" } $2" "$REF/newer-sdk.tsv" >"$T/ref-$1/newer-sdk.tsv" || fail "ref_with $1: rewriting newer-sdk.tsv"
  ! cmp -s "$REF/newer-sdk.tsv" "$T/ref-$1/newer-sdk.tsv" || fail "ref_with $1: newer-sdk.tsv is unchanged"
  sed "s|\(\"name\": \"newer-sdk.tsv\", \"sha256\": \"\)[0-9a-f]*|\1$(sha "$T/ref-$1/newer-sdk.tsv")|" "$REF/manifest.json" >"$T/ref-$1/manifest.json"
  ! cmp -s "$REF/manifest.json" "$T/ref-$1/manifest.json" || fail "ref_with $1: the manifest was not re-hashed"
}
ref_with inherit '$1 == "conformance" && $3 == "NSView" && $5 == "NSAccessibility" { $3 = "FixtureNotAClass"; n++ }
  $1 == "protocol-inherits" && $3 == "NSAccessibilityElement" && $5 == "NSObject" { $5 = "NSAccessibility"; n++ }
  { print } END { if (n != 2) exit 1 }'
REF_SAVE=$REF; REF="$T/ref-inherit"
a11y inherit 'protocol: NSView adopts NSAccessibility only through NSAccessibilityElement, which inherits it'
REF=$REF_SAVE
ref_with clsproto '{ print } END { print "method", "AppKit", "NSView", "-", "setAccessibilityLabel:", "v24@0:8q16", "-", "-", "0", "fixture.h:1", "interface" }'
REF_SAVE=$REF; REF="$T/ref-clsproto"; GROUP=$(printf '%s' "$A11Y_GROUP" | sed 's/"v24@0:8@16"/"v24@0:8q16"/'); group_prefix clsproto; unset GROUP; group clsproto clsproto; REF=$REF_SAVE
group_refused 'protocol: the class and an adopted protocol declare different encodings' provider-abi-mismatch \
  '-NSView setAccessibilityLabel:: the newer SDK declares it as v24@0:8q16 on the class and as v24@0:8@16 in protocol NSAccessibility'
ref_with protoproto '{ print } END { print "protocol-method", "AppKit", "NSAccessibilityElement", "-", "setAccessibilityLabel:", "v24@0:8q16", "-", "-", "0", "fixture.h:1", "protocol:required" }'
REF_SAVE=$REF; REF="$T/ref-protoproto"; GROUP=$A11Y_GROUP; group_prefix protoproto; unset GROUP; group protoproto protoproto; REF=$REF_SAVE
group_refused 'protocol: two adopted protocols declare different encodings' provider-abi-mismatch \
  'the newer SDK declares it as v24@0:8@16 in protocol NSAccessibility and as v24@0:8q16 in protocol NSAccessibilityElement'
GROUP=$(printf '%s' "$A11Y_GROUP" | sed 's/"class" : "NSView"/"class" : "NSResponder"/')
group_prefix notadopted; unset GROUP; group notadopted notadopted
group_refused 'protocol: a class that does not adopt the protocol' provider-abi-mismatch \
  'declared -NSResponder setAccessibilityLabel: as v24@0:8@16; the newer SDK does not declare it'
GROUP=$(printf '%s' "$A11Y_GROUP" | sed 's/"v24@0:8@16"/"v24@0:8q16"/')
group_prefix protoabi; unset GROUP; group protoabi protoabi
group_refused 'protocol: a member declared with another encoding than the protocol' provider-abi-mismatch \
  'declared -NSView setAccessibilityLabel: as v24@0:8q16; the newer SDK declares v24@0:8@16 in protocol NSAccessibility'
GROUP=$(printf '%s' "$A11Y_GROUP" | sed 's/} ] }$/}, { "kind" : "-", "selector" : "wantsPeriodicDraggingUpdates", "encoding" : "c16@0:8", "implementation_symbol" : "FixtureTab_tabbedWindows" } ] }/')
group_prefix protoopt; unset GROUP; group protoopt protoopt
group_refused "protocol: an optional method of NSDraggingDestination, which NSView adopts" provider-abi-mismatch \
  'declared -NSView wantsPeriodicDraggingUpdates as c16@0:8; the newer SDK does not declare it'
GROUP=$(printf '%s' "$A11Y_GROUP" | sed 's/} ] }$/}, { "kind" : "-", "selector" : "identifier", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureTab_tabbedWindows" } ] }/')
group_prefix protofloor; unset GROUP; group protofloor protofloor
group_refused 'protocol: a member of NSUserInterfaceItemIdentification present on 10.9' provider-present-on-floor \
  '-[NSView identifier] is present on 10.9, answered by NSView'
GROUP=$(printf '%s' "$TAB_GROUP" | sed 's/"__fixture_objc_activate_table"/"fixture_tabbing_activation_state"/')
group_prefix noroot; unset GROUP; group noroot noroot
group_refused 'group: a root the constructor never calls' provider-registration-mismatch 'the constructor never reaches fixture_tabbing_activation_state'

group_prefix nullcls -DNULL_CLASS; group nullcls nullcls
exit_is 0 'group: a NULL class path neither credits nor refuses'; tab_all provided 'group: a NULL class path neither credits nor refuses'
says '1 registering without a guess, 1 with objc_getClass NULL' 'group: a NULL class path neither credits nor refuses'

# spec: src/objc/provider.c header, "Groups" -- only a path where the group's own class is NULL, a member (or an unnamed
#       lookup) was found, or an add failed may add other than exactly the members; one that adds nothing is a mismatch.
group_prefix othernull -DOTHER_NULL; group othernull othernull
group_refused "group: another class's NULL path registers only some members" provider-registration-mismatch \
  'registers other than the declaration: missing -[NSWindow setTabbingMode:]'
group_prefix unrelated -DUNRELATED_EARLY; group unrelated unrelated
group_refused 'group: a found non-member lookup that returns early' provider-registration-mismatch \
  'registers other than the declaration: missing -[NSWindow tabbingIdentifier]'
group_prefix failextra -DFAIL_EXTRA; group failextra failextra
group_refused 'group: an undeclared add after a failed add' provider-registration-mismatch \
  'adds -[NSWindow fixtureUndeclared] (_FixtureTab_'
for v in GUESSED TRAPPED; do
  group_prefix "$v" "-D$v"; group "$v" "$v"
  group_refused "group: $v: every registering path guessed or trapped" provider-registration-mismatch 'no path registers the group without a guess'
done
# spec: src/objc/provider.c header -- a computed sel_registerName is explained only by a group whose registration verified
#       and whose executor read a literal there on every arrival, and by nothing once any provider refuses.
group_prefix gcompsel -DCOMPUTED_SEL; group gcompsel gcompsel
exit_is 4 'group: a computed sel_registerName in group code'; error_is computed-selector-producer 'group: a computed sel_registerName in group code'
GROUP="$TAB_GROUP, $(printf '%s' "$G_LOC" | sed 's/"__fixture_objc_activate"/"__fixture_objc_activate_table"/')"
group_prefix tworefuse; unset GROUP; group tworefuse tworefuse
exit_is 4 'group: a verified group beside a refused provider'; error_is provider-abi-mismatch 'group: a verified group beside a refused provider'
error_is computed-selector-producer "group: a verified group's literal sites once another provider refuses"
# spec: src/objc/provider.c header, "Groups" -- every runtime mutator call in a group's verified code is on an explored
#       path, and one other than class_addMethod there refuses; no code or data outside the explored functions writes or
#       passes on what the executor read as a constant, or enters the functions it explored.
group_prefix viamsg -DVIA_MSGSEND; group viamsg viamsg
group_refused 'coverage: VIA_MSGSEND' provider-unexplored-mutation 'class_addMethod at 0x'
says '+[FixtureTabExtra addExtra:]' 'coverage: VIA_MSGSEND names the function'
group_prefix setimp -DSETIMP; group setimp setimp
W='coverage: SETIMP (the reader refuses method_setImplementation anywhere, before providers)'
exit_is 4 "$W"; error_is runtime-method-swizzle "$W"; says '_method_setImplementation' "$W"
! grep '"verdict": "provided"' "$T/report" >/dev/null || fail "$W: a member is provided"
group_prefix rtwrite -DRUNTIME_WRITE; group rtwrite rtwrite
group_refused 'sweep: RUNTIME_WRITE' provider-unmeasurable 'image-store: '
group_prefix escape -DESCAPE; group escape escape
group_refused 'sweep: ESCAPE' provider-mutable-constant 'in _fixture_tab_rows'
group_prefix readtab -DREAD_TABLE; group readtab readtab
exit_is 0 'sweep: a function no path runs only reads the table and the state'
tab_all provided 'sweep: a function no path runs only reads the table and the state'
group_prefix unexsel -DUNEXPLORED_SEL; group unexsel unexsel
exit_is 4 'coverage: a computed sel_registerName in group code no path explored'
error_is computed-selector-producer 'coverage: a computed sel_registerName in group code no path explored'
says 'on no path the executor explored' 'coverage: a computed sel_registerName in group code no path explored'
group callreg tab -DCALL_REGISTER
group_refused 'entry: a consumer calling the register function with its own table' provider-foreign-entry 'in _main'
says 'from its own entry, unknown-store: ' 'entry: a consumer calling the register function with its own table'
# spec: src/objc/provider.c header, "Groups" -- an address the executor read as a constant must not escape to code it
#       does not follow, nor be pointed to from writable data; a reference counts as explored only where a path
#       executed it; every class_addMethod site the reader sees in group code, through a register or a bound pointer
#       too, is an explored one; an explored function catches no exception; the constructor is one initializer entry.
group_prefix bump -DBUMP; group bump bump
group_refused 'sweep: BUMP (the state handed to a helper no path follows)' provider-mutable-constant 'to code it does not follow'
group_prefix passtab -DPASS_TABLE; group passtab passtab
group_refused 'sweep: PASS_TABLE (the table handed to a helper no path follows)' provider-mutable-constant 'to code it does not follow'
# spec: src/objc/provider.c "Coverage" -- a value derived from data read as initial values (the range, or any atom
#       overlapping it) must not reach a call the executor does not follow (any register or frame cell).
group_prefix unkoff -DUNK_OFF; group unkoff unkoff
group_refused 'sweep: UNK_OFF (the state plus an unknown offset handed to a helper)' provider-mutable-constant 'to code it does not follow'
group_prefix adj -DADJ; group adj adj
group_refused 'sweep: ADJ (a global beside a read one handed to a helper)' provider-mutable-constant 'to code it does not follow'
group_prefix manyargs -DMANY_ARGS -mllvm -no-x86-call-frame-opt; group manyargs manyargs
group_refused 'sweep: MANY_ARGS (the state as a stack argument)' provider-mutable-constant 'to code it does not follow'
group_prefix cmov3 -DCMOV3; group cmov3 cmov3
group_refused 'sweep: CMOV3 (a cmov selects the state over another global)' provider-mutable-constant 'to code it does not follow'
group_prefix unkload -DUNK_LOAD -fno-stack-protector; group unkload unkload
group_refused 'sweep: UNK_LOAD (the state loaded back at an unknown index)' provider-mutable-constant 'to code it does not follow'
group_prefix xchg -DXCHG; group xchg xchg
group_refused 'sweep: XCHG (an xchg swaps the state and another global)' provider-mutable-constant 'to code it does not follow'
# spec: src/objc/regexec.c header, "Provenance" -- an image address is relocatable: an operation inspecting its bits is
#       unknown at analysis time and carries its provenance, flags included.
group_prefix shcl -DSHCL; group shcl shcl
group_refused 'sweep: SHCL (the state rebuilt through a shift count)' provider-mutable-constant 'to code it does not follow'
group_prefix sbbv -DSBBV; group sbbv sbbv
group_refused 'sweep: SBBV (the state rebuilt through the carry flag)' provider-mutable-constant 'to code it does not follow'
# spec: src/objc/regexec.c header, "Memory" -- a frame address among a call's stack arguments escapes like one in rdi.
group_prefix pusharg -DPUSH_ARG; group pusharg pusharg
exit_is 4 'group: PUSH_ARG (the row count trimmed through a pushed argument)'; tab_all unsupported 'group: PUSH_ARG'
group_prefix walkend -DWALK_END; group walkend walkend
exit_is 0 'group: WALK_END (a row pointer compared to the table end) provided'; tab_all provided 'group: WALK_END provided'
# spec: src/objc/provider.c "Coverage" -- class metadata the runtime writes is never read as a constant.
group_prefix clsfield -DCLS_FIELD; group clsfield clsfield
group_refused 'sweep: CLS_FIELD (the root branches on its own class object)' provider-mutable-constant 'in __DATA,__objc_data), read at'
group_prefix clsro -DCLS_RO; group clsro clsro
group_refused 'sweep: CLS_RO (the root branches on its class read-only data)' provider-mutable-constant 'in __DATA,__objc_const), read at'
group_prefix cfgptr -DCFG_PTR; group cfgptr cfgptr
group_refused 'sweep: CFG_PTR (a constant pointer to a constant, written through elsewhere)' provider-mutable-constant 'points to'
group_prefix prunedw -DPRUNED_WRITE; group prunedw prunedw
group_refused 'sweep: PRUNED_WRITE (a state write on a branch no path takes)' provider-mutable-constant 'writes or uses'
group_prefix prunedc -DPRUNED_CALL; group prunedc prunedc
group_refused 'coverage: PRUNED_CALL (class_addMethod through a register on a branch no path takes)' provider-unexplored-mutation 'class_addMethod at 0x'
group_prefix try -DTRY; group try try
group_refused 'coverage: TRY (an explored function with an LSDA)' provider-unmeasurable 'exceptional control flow'
group_prefix boundadd -DBOUND_ADD; group boundadd boundadd
group_refused 'coverage: BOUND_ADD (class_addMethod through a bound pointer)' provider-unexplored-mutation 'class_addMethod at 0x'
group_prefix twoinit -DTWO_INIT; group twoinit twoinit
group_refused 'entry: TWO_INIT (the constructor twice in the initializer table)' provider-foreign-entry '__DATA,__mod_init_func'
# spec: src/objc/provider.c "Coverage" -- a branch from code the executor did not explore to an explored function's
#       entry is accepted when that function, run from its own entry with nothing bound, verifies as the group's root
#       and reaches nothing new; tests/objc/fixtures/table-second.m is the second unit, its initializer the caller.
second() {  # second NAME [CC-FLAGS...]: table-provider.m and table-second.m built with -DSECOND and CC-FLAGS, and analyzed
  sn=$1; shift; UNIT='table-provider.m table-second.m'; group_prefix "$sn" -DSECOND "$@"; unset UNIT; group "$sn" "$sn"
}
second second
exit_is 0 'entry: a second initializer calling the root first'; tab_all provided 'entry: a second initializer calling the root first'
grep '"status": "active"' "$T/report" >/dev/null || fail 'entry: a second initializer calling the root first: the group is not active'
! grep -F '"code"' "$T/report" >/dev/null || fail 'entry: a second initializer calling the root first: the report has an error'
second pastentry -DPAST_ENTRY
group_refused 'entry: a call into the root past its entry' provider-foreign-entry 'branches to 0x'
! grep -F 'from its own entry' "$T/report" >/dev/null || fail 'entry: a call into the root past its entry: it was run as an entry'
second rootptr -DROOT_POINTER
group_refused 'entry: a pointer to the root in data' provider-foreign-entry 'points to 0x'
second rootalt -DROOT_ALT=1
group_refused 'entry: a root whose own run adds another implementation' provider-foreign-entry \
  "from its own entry, the constructor's run and its own differ in adding -[NSWindow tabbingMode] (_FixtureTab_tabbedWindows)"
second altread -DROOT_ALT=2
group_refused 'entry: a root whose own run reads another table' provider-foreign-entry \
  "from its own entry, it reads 0x"
second altfn -DROOT_ALT=3
group_refused 'entry: a root whose own run explores another function' provider-foreign-entry \
  "from its own entry, it explores _fixture_alt_extra, which the constructor's run does not"
second altsel -DROOT_ALT=4
group_refused 'entry: a root whose own run registers a computed selector' provider-foreign-entry \
  "not read from the image's initial bytes"
second altesc -DROOT_ALT=5
group_refused 'entry: a root whose own run lets the state escape' provider-foreign-entry \
  "data read as initial values, escapes at 0x"
second altguess -DROOT_ALT=6
group_refused 'entry: a root whose own run registers only after a guess' provider-foreign-entry \
  'from its own entry, fixture.nswindow.tabbing.v1: no path registers the group without a guess'
# spec: src/objc/provider.c header, "Groups" (own-absent) -- an own-absent group is verified for each literal class its
#       root's call sites name: one run from the root per class with the class bound, each class's members absent from
#       the class and its app ancestors, present on its floor ancestor's 10.9 chain with that ancestor's encoding; no
#       lookup, no store but the class into its table, no entry but the call sites; nothing is provided.
bridge plain -
exit_is 0 'bridge: two classes, four sites'
grep '"status": "active"' "$T/report" >/dev/null || fail 'bridge: two classes, four sites: the group is not reported active'
says 'bridges 2 classes from 4 call sites' 'bridge: two classes, four sites'
no_provided 'bridge: two classes, four sites'
# spec: src/objc/provider.c header, "Groups" (own-absent) (5) -- inside a verified IMP, argument 0 is an instance of a
#       bridged class: a send to it answers when every bridged class does, else a respondsToSelector: guard closes it.
imp_sends accessibilityRole floor-supported 'every bridged class answers -accessibilityRole (' 'bridge: a getter every bridged class implements'
imp_sends respondsToSelector: floor-supported 'FixtureBridgedCell: floor -NSObject' 'bridge: a getter every bridged class implements'
# spec: src/objc/provider.c header, "Groups" (own-absent (6)) -- a super send of an IMP's own selector, a literal or its
#       _cmd, is excused by the group's super_fallbacks record for that IMP; no other send is, and an unused record is listed.
super_send() {  # super_send IMP: the verdict of the IMP's objc_msgSendSuper* send
  grep "\"function\": \"_$1\"" "$T/report" | grep '"evidence_kind": "objc_msgSendSuper' | sed -n 's/.*"verdict": "\([^"]*\)".*/\1/p' | tr '\n' ' '
}
[ "$(super_send FixtureBridge_attributeValue)" = 'floor-supported ' ] || fail "bridge: the super fallback is excused: $(super_send FixtureBridge_attributeValue)"
says 'super fallback record fixture.bridge.accessibility.v1/FixtureBridge_attributeValue: -accessibilityAttributeValue: is on every bridged class' \
  'bridge: the super fallback is excused'
says '"unused_super_fallbacks": []' 'bridge: the super fallback is excused'
! grep '"function": "_FixtureBridge_' "$T/report" | grep '"verdict": "unresolved"' | grep 'incoming argument 0' >/dev/null ||
  fail 'bridge: a getter every bridged class implements: an argument-0 send is unresolved'
bridge nofallback NO_FALLBACK
exit_is 0 'bridge: a super_fallbacks record that excuses nothing'
says '"unused_super_fallbacks": ["FixtureBridge_attributeValue:accessibilityAttributeValue:"]' 'bridge: a super_fallbacks record that excuses nothing'
GROUP=$(own_sed '/"super_fallbacks"/d; s/} ],$/} ] }/')
bridge norecord -
exit_is 1 'bridge: no record, the super send blocks'; only_imps_block 'bridge: no record, the super send blocks'
[ "$(super_send FixtureBridge_attributeValue)" = 'unresolved ' ] || fail "bridge: no record, the super send blocks: $(super_send FixtureBridge_attributeValue)"
bridge superother SUPER_OTHER
exit_is 1 'bridge: a super send of another member'; only_imps_block 'bridge: a super send of another member'
[ "$(super_send FixtureBridge_attributeValue)" = 'unresolved ' ] || fail "bridge: a super send of another member: $(super_send FixtureBridge_attributeValue)"
bridge lacks - -DBRIDGE_CELL_LACKS
exit_is 0 'bridge: a getter one class lacks, guarded'
imp_sends accessibilityRole guarded 'guards it; FixtureBridgedCell lacks it' 'bridge: a getter one class lacks, guarded'
bridge unguarded UNGUARDED -DBRIDGE_CELL_LACKS
exit_is 1 'bridge: a getter one class lacks, unguarded'
imp_sends accessibilityRole unsupported 'bridged class FixtureBridgedCell lacks -accessibilityRole and nothing guards it' \
  'bridge: a getter one class lacks, unguarded'
bridge elsewhere IMP_ELSEWHERE
grep '"status": "active"' "$T/report" >/dev/null || fail 'bridge: an IMP whose address is taken elsewhere: the group is not reported active'
imp_sends accessibilityRole unresolved 'receiver is incoming argument 0' 'bridge: an IMP whose address is taken elsewhere'
bridge lea IMP_LEA
imp_sends accessibilityRole unresolved 'receiver is incoming argument 0' 'bridge: an IMP whose address a function no run explores takes'
bridge computed - -DBRIDGE_COMPUTED
bridge_refused 'bridge: a class sent from a computed receiver' computed-class-producer 'FixtureBridge argument is not a recognised literal class'
bridge unknown - -DBRIDGE_UNKNOWN
bridge_refused 'bridge: a class the reader cannot name' computed-class-producer 'FixtureBridge argument is not a recognised literal class'
bridge notown - -DBRIDGE_NOT_OWN
bridge_refused 'bridge: a class the artifact does not define' bridge-class-not-own 'NSButton is not a class the artifact defines'
bridge ownmember - -DBRIDGE_OWN_MEMBER
bridge_refused 'bridge: a class that has a member' provider-guard-violation \
  "-[FixtureBridgedView accessibilityIsIgnored] is already the app's own (on FixtureBridgedView)"
bridge ancestor - -DBRIDGE_ANCESTOR_MEMBER
bridge_refused 'bridge: an app ancestor that has a member' provider-guard-violation \
  "-[FixtureBridgedSub accessibilityAttributeNames] is already the app's own (on FixtureBridgedBase)"
bridge rootless - -DBRIDGE_ROOTLESS
bridge_refused 'bridge: a class with no floor ancestor' provider-absent-from-floor 'FixtureBridgedRoot: no floor ancestor: the chain leaves at FixtureBridgedRoot'
GROUP=$(own_sed 's/} ],$/}, { "kind" : "-", "selector" : "accessibilityRole", "encoding" : "@16@0:8", "implementation_symbol" : "FixtureBridge_role" } ],/')
bridge extra EXTRA_MEMBER
bridge_refused "bridge: a member absent from the floor ancestor's chain" provider-absent-from-floor '-[NSActionCell accessibilityRole] is absent from 10.9'
GROUP=$(own_sed 's/"c16@0:8"/"i16@0:8"/')
bridge abi -
bridge_refused "bridge: an encoding other than the floor ancestor's" provider-abi-mismatch 'declared -NSActionCell accessibilityIsIgnored as i16@0:8; the newer SDK declares c16@0:8'
bridge lookup LOOKUP
bridge_refused 'bridge: a root that looks a method up' provider-guard-violation 'an own-absent root looks up nothing'
bridge replace REPLACE
exit_is 4 'bridge: a root that replaces a method'; error_is runtime-method-swizzle 'bridge: a root that replaces a method'
no_provided 'bridge: a root that replaces a method'
bridge pointer - -DBRIDGE_POINTER
bridge_refused 'bridge: a call through a function pointer' provider-foreign-entry 'code the executor explored, from code or data it did not'
bridge tableother TABLE_OTHER
bridge_refused 'bridge: another class into the class table' provider-unmeasurable 'fixture.bridge.accessibility.v1: image-store: '
bridge tableelse TABLE_ELSEWHERE
bridge_refused 'bridge: the class stored outside the class table' provider-unmeasurable 'fixture.bridge.accessibility.v1: image-store: '
bridge unused - -DBRIDGE_UNUSED -Wl,-u,_FixtureBridge
exit_is 0 'bridge: a root linked but never called'
imp_sends accessibilityRole floor-supported 'inside dormant bridge IMP FixtureBridge_' 'bridge: a root linked but never called'
! grep '"function": "_FixtureBridge_' "$T/report" | grep -vF ': nothing reaches it"' >/dev/null ||
  fail 'bridge: a root linked but never called: an IMP send is not closed as unreachable'
grep '"status": "inactive"' "$T/report" >/dev/null || fail 'bridge: a root linked but never called: the group is not reported inactive'
says 'no call site names a class' 'bridge: a root linked but never called'
! grep '"code": "provider-unexplored-mutation"' "$T/report" >/dev/null || fail 'bridge: a root linked but never called: its class_addMethod is unexplored'
bridge unusedelse IMP_ELSEWHERE -DBRIDGE_UNUSED -Wl,-u,_FixtureBridge
exit_is 1 'bridge: a root never called, an IMP whose address is taken elsewhere'
grep '"status": "inactive"' "$T/report" >/dev/null || fail 'bridge: a root never called, an IMP taken elsewhere: the group is not reported inactive'
imp_sends accessibilityRole unresolved 'receiver is incoming argument 0' 'bridge: a root never called, an IMP whose address is taken elsewhere'
bridge unusedlea IMP_LEA -DBRIDGE_UNUSED -Wl,-u,_FixtureBridge
exit_is 1 'bridge: a root never called, an IMP whose address another function takes'
imp_sends accessibilityRole unresolved 'receiver is incoming argument 0' 'bridge: a root never called, an IMP whose address another function takes'
bridge unusedptr - -DBRIDGE_UNUSED -DBRIDGE_POINTER
bridge_refused 'bridge: a root no call site names, its address taken' provider-foreign-entry 'a root no call site names a class for'
# spec: src/objc/regexec.c header, "Start" -- each call of a root sees the stores of the calls before it, so a run reads
#       its class table as unknown: a slot search the table's size does not bound stores past it, and an add the table
#       decides is explored both ways.
bridge unbounded UNBOUNDED_SCAN
bridge_refused 'bridge: a slot search the table size does not bound' provider-unmeasurable 'fixture.bridge.accessibility.v1: '
grep -E 'fixture\.bridge\.accessibility\.v1: (image|unknown)-store: a store to ' "$T/report" >/dev/null ||
  fail "bridge: a slot search the table size does not bound: $(grep -F '"code"' "$T/report" | head -3)"
bridge tabledep TABLE_DEPENDENT_IMP
bridge_refused 'bridge: an add whose IMP the class table decides' provider-registration-mismatch \
  'accessibilityAttributeNames] implemented by _FixtureBridge_isIgnored, declared _FixtureBridge_attributeNames'
# spec: src/objc/regexec.c header, "Start" -- the table's address escapes as any writable address does, and code the
#       executor does not follow may store through it.
bridge tableescape TABLE_ESCAPE
bridge_refused 'bridge: the class table passed to memset' provider-unmeasurable \
  'fixture.bridge.accessibility.v1: image-store: the address of FixtureBridgeClasses+0 is passed to code it does not follow at 0x'
# spec: src/objc/provider.c header, "Groups" (own-absent) (1) -- a class that may be a metaclass, or a [X class] that X
#       or an app ancestor answers itself, is no literal class.
bridge meta - -DBRIDGE_META
bridge_refused 'bridge: objc_getMetaClass' computed-class-producer 'FixtureBridge argument may be the metaclass of FixtureBridgedMeta'
bridge metaclass - -DBRIDGE_META_CLASS
bridge_refused 'bridge: [objc_getMetaClass(...) class]' computed-class-producer 'FixtureBridge argument may be the metaclass of FixtureBridgedMeta'
bridge superref - -DBRIDGE_SUPERREF
bridge_refused 'bridge: a superref slot' computed-class-producer 'FixtureBridge argument may be the metaclass of FixtureBridgedView'
bridge classoverride - -DBRIDGE_CLASS_OVERRIDE
bridge_refused 'bridge: a class implementing +class' computed-class-producer 'FixtureBridge argument is [FixtureBridgedOdd class], and FixtureBridgedOdd implements +class'
# spec: src/objc/provider.c header, "Groups" (own-absent) (2) -- a dormant group explains only its root's own adds.
bridge helper HELPER_ADD -DBRIDGE_UNUSED -DBRIDGE_HELPER -Wl,-u,_FixtureBridge
exit_is 4 'bridge: a dormant root, its helper called directly'
error_is provider-unexplored-mutation 'bridge: a dormant root, its helper called directly'
says 'class_addMethod at 0x' 'bridge: a dormant root, its helper called directly'
# spec: src/objc/provider.c header, "Groups" (own-absent) (3) -- a class with a bridged app ancestor would shadow it.
bridge nested - -DBRIDGE_NESTED
bridge_refused 'bridge: a class and its app subclass' provider-guard-violation \
  '-[FixtureBridgedNested accessibilityAttributeNames] is bridged on FixtureBridgedView as well'
# spec: src/objc/provider.c header, "Groups" (own-absent) (4), (5) -- a member IMP's address escaping a run is a foreign
#       entry, as is a branch inside an IMP to its own entry: argument 0 is then open.
bridge rootleak ROOT_LEAK
bridge_refused 'bridge: the root passes a member IMP to printf' provider-foreign-entry 'the address of _FixtureBridge_isIgnored escapes at'
bridge selfcall SELF_CALL
grep '"status": "active"' "$T/report" >/dev/null || fail 'bridge: an IMP that calls itself: the group is not reported active'
imp_sends accessibilityRole unresolved 'receiver is incoming argument 0' 'bridge: an IMP that calls itself with another object'
# spec: src/objc/provider.c header, "Groups" (own-absent) (6) -- a super send of _cmd through a _stret entry is not excused.
bridge superstret SUPER_STRET
exit_is 1 'bridge: a _stret super send of _cmd'
[ "$(super_send FixtureBridge_attributeValue)" = 'unresolved ' ] || fail "bridge: a _stret super send of _cmd: $(super_send FixtureBridge_attributeValue)"
# spec: src/objc/provider.c header, "Groups" (own-absent) -- the root's member has no initializer.
bridge constructor CONSTRUCTOR
bridge_refused 'bridge: an initializer in the root member' unsupported-provider 'has an initializer: an own-absent root is activated by its call sites alone'
# spec: src/objc/reference.c load_runtime -- ref_floor_with NAME AWK: $T/ref-NAME, the reference with floor-runtime.tsv
#       rewritten by AWK (as ref_with does newer-sdk.tsv) and its manifest digest recomputed.
ref_floor_with() {
  rm -rf "$T/ref-$1"; mkdir -p "$T/ref-$1"; cp "$REF"/* "$T/ref-$1"/
  awk -F '\t' "BEGIN { OFS = \"\\t\" } $2" "$REF/floor-runtime.tsv" >"$T/ref-$1/floor-runtime.tsv" || fail "ref_floor_with $1: rewriting floor-runtime.tsv"
  sed "s|\(\"name\": \"floor-runtime.tsv\", \"sha256\": \"\)[0-9a-f]*|\1$(sha "$T/ref-$1/floor-runtime.tsv")|" "$REF/manifest.json" >"$T/ref-$1/manifest.json"
  ! cmp -s "$REF/manifest.json" "$T/ref-$1/manifest.json" || fail "ref_floor_with $1: the manifest was not re-hashed"
}
# spec: src/objc/provider.c header, "Groups" (own-absent) (3) -- a member found past a class the capture does not measure
#       is not found; a member's providing image is strongly loaded, as its floor ancestor's home is.
ref_floor_with unmeasured '$1 == "method" && $2 == "NSView" && $4 == "accessibilityIsIgnored" { $4 = "fixtureMoved"; n++ }
  $1 == "class" && $2 == "NSResponder" { $6 = "CoreText"; n++ } { print } END { if (n != 2) exit 1 }'
REF_SAVE=$REF; REF="$T/ref-unmeasured"; bridge unmeasured -; REF=$REF_SAVE
bridge_refused 'bridge: a member past an unmeasured class' provider-absent-from-floor \
  '-[NSView accessibilityIsIgnored] is absent from 10.9 up to NSResponder, which the floor capture does not measure'
ref_floor_with category '$1 == "method" && $2 == "NSView" && $4 == "accessibilityIsIgnored" { $6 = "CoreText"; n++ } { print } END { if (n != 1) exit 1 }'
REF_SAVE=$REF; REF="$T/ref-category"; bridge category -; REF=$REF_SAVE
grep '"status": "inactive"' "$T/report" >/dev/null || fail 'bridge: a member from an image the artifact does not load: the group is not reported inactive'
says 'CoreText (providing -[NSView accessibilityIsIgnored] to NSView) is not linked' 'bridge: a member from an image the artifact does not load'
no_provided 'bridge: a member from an image the artifact does not load'

# spec: src/objc/provider.c drain -- a zerofill atom is accepted only inside a zerofill final section.
cp "$T/root/bin/g-tab" "$T/root/bin/g-bss"
perl -e 'open my $f, "+<", $ARGV[0] or die; binmode $f; read $f, my $h, 8192;
  my $i = index($h, "__bss" . ("\0" x 11) . "__DATA"); die "no __bss" if $i < 0;
  seek $f, $i + 64, 0; read $f, my $fl, 4; $fl = pack("V", unpack("V", $fl) & ~0xff); seek $f, $i + 64, 0; print $f $fl' \
  "$T/root/bin/g-bss" || fail 'retyping __bss'
evidence "$T/root/bin/g-bss" "$T/root/bin/g-bss" "$T/root/bin/g-tab.map" "$T/ev/g-bss.json" "$T/g-tab"
[ "$rc" = 0 ] || fail "group: a zerofill atom in a regular section: build evidence exit $rc"
analyze "$T/root/bin/g-bss" --build-evidence "$T/ev/g-bss.json" --provider-prefix "$T/g-tab"
group_refused 'group: a zerofill atom whose final section is not zerofill' provider-mapping-mismatch 'is zerofill, its final section is not'
# spec: src/objc/main.c (analyze) -- with schema-1 providers only, a computed sel_registerName stops the reader as before:
#       no provider is verified.
SRC="$FX/table-consumer.m"; consumer "$T/root/bin/s1-compsel" "$ALL" -DCOMPUTED_SEL; unset SRC
full "$T/root/bin/s1-compsel" "$T/root/bin/s1-compsel" "$T/root/bin/s1-compsel.map" s1-compsel
exit_is 4 'schema 1: a computed sel_registerName'; error_is computed-selector-producer 'schema 1: a computed sel_registerName'
grep '"constructor": null' "$T/report" >/dev/null || fail 'schema 1: a computed sel_registerName: the provider was verified, the reader did not stop'

group compsel tab -DCOMPUTED_SEL
exit_is 4 'group: a computed sel_registerName outside the group'; error_is computed-selector-producer 'group: a computed sel_registerName outside the group'
says 'sel_registerName argument is not a recognised literal' 'group: a computed sel_registerName outside the group'
grep '"status": "active"' "$T/report" >/dev/null || fail 'group: a computed sel_registerName outside the group: the group itself is not active'

group cross tab -DKIND_CROSS
exit_is 1 'group: kind decides which sends are provided'
for s in tabbingMode allowsAutomaticWindowTabbing; do
  got=$(tab_verdict "$s"); [ -n "$got" ] && [ "$got" != "provided " ] || fail "group: kind decides which sends are provided: $s is '${got:-no finding}'"
done

# spec: src/objc/provider.c header, "Groups" -- a universal consumer: its x86_64 slice is the one verified. The slices are
#       built single-arch and joined by this repo's makefat (never lipo, which the guest lacks).
# platform: the arm64 slice is built by $CC_ARM64 where clang22 targets arm64; elsewhere (10.9's clang22) it is an x86_64
#           image under arm64's cputype, as objc-reader-test.sh's noslice is: only the x86_64 slice is ever read.
# platform: makefat runs here, so CTest hands over this build's (DRYDOCK_MAKEFAT); a standalone run builds it with HOST_CC.
if [ -x "${DRYDOCK_MAKEFAT:-}" ]; then cp "$DRYDOCK_MAKEFAT" "$T/makefat"
else "$HOST_CC" -O2 -o "$T/makefat" "$ROOT/tests/makefat.c" || fail 'building makefat'; fi
env -i PATH=/usr/bin:/bin "$CC_ARM64" -O1 "$FX/plain.c" -o "$T/arm64-slice" 2>/dev/null || fxcc -O1 "$FX/plain.c" -o "$T/arm64-slice"
"$T/makefat" "$T/root/bin/g-fat" "$T/root/bin/g-tab" 0x1000007 3 12 "$T/arm64-slice" 0x100000c 0 14 >/dev/null || fail 'makefat'
evidence "$T/root/bin/g-fat" "$T/root/bin/g-fat" "$T/root/bin/g-tab.map" "$T/ev/g-fat.json" "$T/g-tab"
[ "$rc" = 0 ] || fail "group: a fat consumer's build evidence: exit $rc"
analyze "$T/root/bin/g-fat" --build-evidence "$T/ev/g-fat.json" --provider-prefix "$T/g-tab"
exit_is 0 'group: a fat consumer verifies its x86_64 slice'; tab_all provided 'group: a fat consumer verifies its x86_64 slice'

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

# spec: src/objc/provider.c header, 4 -- what the provider needs loaded is what it binds and its class's home, not
#       every framework it declares: Carbon, whose functions the provider reaches through CoreServices and
#       ApplicationServices (and lld leaves out when nothing binds to it), need not be loaded.
consumer "$T/root/bin/no-carbon" "$(fwflag Carbon '')" -framework CoreServices -framework ApplicationServices
full "$T/root/bin/no-carbon" "$T/root/bin/no-carbon" "$T/root/bin/no-carbon.map" no-carbon
positive 'Carbon not linked, nothing bound to it'
# spec: src/objc/provider.c header, 4 -- the declared class's home (AppKit for NSWorkspace, from the floor capture)
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
  "$OTOOL" -l "$1" | awk -v fw="/$2.framework/" '/^Load command/ {if (seen) off += size; seen = 1} $1 == "cmdsize" {size = $2}
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

# spec: src/objc/provider.c header -- the root kept, its constructor dropped from the initializer table.
cp "$T/root/bin/rooted" "$T/root/bin/noinit"
off=$("$OTOOL" -l "$T/root/bin/noinit" | awk '/sectname __mod_init_func/{f=1} f && $1=="offset" {print $2; exit}')
[ -n "$off" ] || fail 'the rooted consumer has no __mod_init_func'
putn "$T/root/bin/noinit" "$off" "$(symaddr "$T/root/bin/noinit" _main)" 8
symaddr "$T/root/bin/noinit" "_$ACTIVATE" | grep . >/dev/null || fail 'the root symbol is gone'
full "$T/root/bin/noinit" "$T/root/bin/noinit" "$T/maps/rooted.map" noinit
nonzero 'root present, constructor not in the initializer table'
reason_has 'not in the final initializer table' 'constructor dropped'

# spec: src/objc/provider.c header -- the registration's IMP reference retargeted by one byte.
member=$("$NM" -A "$ARCHIVE" 2>/dev/null | awk -v s="_$ACTIVATE" '$NF==s && $(NF-1)=="T" {m=$1; sub(/:$/,"",m); if (m ~ /\(.*\)$/) {sub(/.*\(/,"",m); sub(/\)$/,"",m)} else sub(/.*:/,"",m); print m; exit}')
[ -n "$member" ] || fail "no archive member defines _$ACTIVATE"
(cd "$T/src" && "$AR" x "$ARCHIVE" "$member") || fail "cannot extract $member"
r=$("$OTOOL" -rv "$T/src/$member" | awk -v s="_$IMPL" '$NF==s && $3=="long" {print $1; exit}')
[ -n "$r" ] || fail "$member has no reference to _$IMPL"
atom=$("$NM" -n "$T/src/$member" | awk -v r="0x$r" 'function h(x, i,c,n){n=0;x=tolower(x);sub(/^0x/,"",x);for(i=1;i<=length(x);i++){c=index("0123456789abcdef",substr(x,i,1))-1;n=n*16+c}return n}
  $2 ~ /^[Tt]$/ && h($1) <= h(r) {name=$3; base=h($1)} END{print name, h(r) - base}')
set -- $atom
va=$(( $(symaddr "$T/root/bin/rooted" "$1") + $2 ))
cp "$T/root/bin/rooted" "$T/root/bin/retarget"
off=$(fileoff "$T/root/bin/retarget" "$va")
d=$(od -An -tu4 -j "$off" -N4 "$T/root/bin/retarget" | tr -d ' ')
putn "$T/root/bin/retarget" "$off" "$(( (d + 1) & 4294967295 ))" 4
full "$T/root/bin/retarget" "$T/root/bin/retarget" "$T/maps/rooted.map" retarget
nonzero 'implementation reference retargeted'

# spec: src/objc/provider.c header -- a declaration that disagrees with the registered class, kind, selector or ABI.
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
# spec: src/objc/provider.c header -- an archive whose code registers another class than its declaration says.
fixture_prefix "$T/pfx-wrongcode" -DFIXTURE_REGISTERED_CLASS='"NSFileManager"'
save=$PFX; PFX="$T/pfx-wrongcode"
consumer "$T/root/bin/wrongcode" "$ALL"
full "$T/root/bin/wrongcode" "$T/root/bin/wrongcode" "$T/root/bin/wrongcode.map" wrongcode
PFX=$save
nonzero 'code registering another class than declared'; error_is provider-registration-mismatch 'code registering another class'

# spec: src/objc/provider.c header -- stale provider inputs: the archive or declaration changed after the evidence.
rm -rf "$T/pfx-stale"; cp -R "$PFX" "$T/pfx-stale"
printf '\n' >>"$T/pfx-stale/share/recaulk/objc-providers.json"
analyze "$T/root/bin/rooted" --build-evidence "$T/ev/rooted.json" --provider-prefix "$T/pfx-stale"
nonzero 'declaration changed after the evidence'; exit_is 4 'declaration changed after the evidence'
rm -rf "$T/pfx-stale"; cp -R "$PFX" "$T/pfx-stale"
printf '!<arch>\n' >"$T/pfx-stale/$(field archive_path)"
analyze "$T/root/bin/rooted" --build-evidence "$T/ev/rooted.json" --provider-prefix "$T/pfx-stale"
nonzero 'archive replaced'; exit_is 4 'archive replaced'
rm -rf "$T/pfx-gone"; cp -R "$PFX" "$T/pfx-gone"
(cd "$T/src" && "$AR" x "$ARCHIVE")
"$AR" d "$T/pfx-gone/$(field archive_path)" "$member" 2>/dev/null && "$RANLIB" "$T/pfx-gone/$(field archive_path)" 2>/dev/null
sed "s/\"archive_sha256\" : \"[0-9a-f]*\"/\"archive_sha256\" : \"$(sha "$T/pfx-gone/$(field archive_path)")\"/" "$DECL" >"$T/pfx-gone/share/recaulk/objc-providers.json"
evidence "$T/root/bin/omitted" "$T/root/bin/omitted" "$T/root/bin/omitted.map" "$T/ev/gone.json" "$T/pfx-gone"
[ "$rc" = 0 ] && analyze "$T/root/bin/omitted" --build-evidence "$T/ev/gone.json" --provider-prefix "$T/pfx-gone"
nonzero 'archive without the root member'

# spec: src/objc/main.c header -- a changed final binary or dependency after the evidence.
analyze "$T/root/bin/deadstrip" --build-evidence "$T/ev/rooted.json" --provider-prefix "$PFX"
nonzero 'evidence for another final binary'; exit_is 4 'evidence for another final binary'

# spec: cli/drydock-objc.c header (evidence) -- an artifact that links no provider: no --provider-prefix;
#       evidence with no provider mapping. A link map alone must be this link's; a prefix needs a link map.
fxcc -O1 "$FX/plain.c" -o "$T/root/bin/plain-consumer"
noprov() {
  rc=0; "$DRYDOCK_OBJC" evidence --artifact "$T/root/bin/plain-consumer" --prestrip "$T/root/bin/plain-consumer" \
    --source-root "$FX" --references "$REF" "$@" 2>"$T/err" || rc=$?
}
noprov --output "$T/ev/noprov.json"
exit_is 0 'evidence for a binary that links no provider'
grep '"providers": \[\]' "$T/ev/noprov.json" >/dev/null || fail 'provider-less evidence lists providers'
grep "\"sha256\": \"$(sha "$T/root/bin/plain-consumer")\"" "$T/ev/noprov.json" >/dev/null || fail 'provider-less evidence does not name its artifact'
noprov --link-map "$T/maps/rooted.map" --output "$T/ev/noprov-map.json"
exit_is 4 'another link'"'"'s map without a provider prefix'; grep link-map-mismatch "$T/err" >/dev/null || fail 'another link'"'"'s map is not link-map-mismatch'
noprov --provider-prefix "$PFX" --output "$T/ev/noprov-pfx.json"
exit_is 2 'a provider prefix without a link map'
analyze "$T/root/bin/plain-consumer" --build-evidence "$T/ev/noprov.json"
exit_is 0 'provider-less evidence analyzed with no prefix'
# spec: src/objc/main.c "The shipped closure" -- a dependency inside the root is measured by its
#       interface; one that loads from outside it is not, so nothing it might replace can be provided.
fxcc -dynamiclib -O1 "$FX/plain.c" -o "$T/root/bin/libextra.dylib" -install_name /Library/Mavergreen/libextra.dylib
consumer "$T/root/bin/extra-dep" "$ALL" -Wl,-needed_library,"$T/root/bin/libextra.dylib"
"$OTOOL" -L "$T/root/bin/extra-dep" | grep -q /Library/Mavergreen/libextra.dylib || fail "extra-dep: libextra.dylib is not a dependency"
full "$T/root/bin/extra-dep" "$T/root/bin/extra-dep" "$T/root/bin/extra-dep.map" extra-dep
nonzero 'a dependency outside the shipped root'; exit_is 4 'a dependency outside the shipped root'

# spec: cli/drydock-objc.c header (evidence) -- prestrip evidence absent, from another link, or without the atoms' symbols.
rc=0; "$DRYDOCK_OBJC" evidence --artifact "$T/root/bin/rooted" --source-root "$FX" --link-map "$T/maps/rooted.map" \
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
if [ "$(id -u)" = 0 ]; then echo 'skip: root reads a mode-000 link map' >&2; else
  chmod 000 "$T/maps/rooted.map"
  evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/rooted.map" "$T/ev/unreadable.json"
  exit_is 4 'an unreadable link map'; chmod 644 "$T/maps/rooted.map"
fi
# spec: src/objc/linkmap.c LINKMAP_MAX -- a real consumer's map (Codex's is 174 MB) is read up to 256 MiB;
#       past that it is refused before it is read.
cp "$T/maps/rooted.map" "$T/maps/big.map"
perl -e 'my $l = "#" . ("p" x 1022) . "\n"; print $l for 1 .. 65537' >>"$T/maps/big.map"
evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/big.map" "$T/ev/big.json"
[ "$rc" = 0 ] || fail "a link map over 64 MiB: exit $rc"
dd if=/dev/null of="$T/maps/huge.map" bs=1 seek=268435457 2>/dev/null
evidence "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/maps/huge.map" "$T/ev/huge.json"
exit_is 4 'a link map over 256 MiB'; grep oversized-input "$T/err" >/dev/null || fail 'the oversized link map is not named'
rm -f "$T/maps/big.map" "$T/maps/huge.map"

# spec: src/objc/provider.c header -- a root name and a class_addMethod with no attested provider behind them.
SRC="$FX/provider-impostor.c"; consumer "$T/root/bin/impostor" "$ALL"; SRC=
full "$T/root/bin/impostor" "$T/root/bin/impostor" "$T/root/bin/impostor.map" impostor
nonzero 'an impostor root and its own registration'; error_is unattested-method-registration 'impostor'

# spec: src/objc/main.c header -- removal after an earlier successful report: the old report is no token.
consumer "$T/root/bin/rooted" "$NO_ARCHIVE"
analyze "$T/root/bin/rooted" --build-evidence "$T/ev/rooted.json" --provider-prefix "$PFX"
nonzero 'provider removed, earlier evidence reused'; exit_is 4 'provider removed, earlier evidence reused'
full "$T/root/bin/rooted" "$T/root/bin/rooted" "$T/root/bin/rooted.map" removed
nonzero 'provider removed, fresh evidence'; want_verdict unsupported 'provider removed, fresh evidence'
old=$(sed -n 's/.*"inputs": {"artifact": {"path": "[^"]*", "sha256": "\([0-9a-f]*\)".*/\1/p' "$T/cached-positive.json")
[ -n "$old" ] && [ "$old" != "$(sha "$T/root/bin/rooted")" ] || fail 'the cached positive report does not show it described another binary'

# spec: src/objc/source-evidence.c header -- source receipts. A provider body's sends to its own typed arguments
#       close only through the receipt of its verified prepared source (tools/objc-source-inventory.c), mapped to each
#       call instruction by the archive member's own line table and the evidence's atom mapping; an `id` receiver stays
#       open; a send added to the source is its own block; changed source, no line table, a send the receipt does not
#       explain, or a malformed receipt is cannot-measure. The consumer's code is never closed by a provider's receipt.
# spec: components/objc-receipt-clang -- `drydock-objc receipt` takes the receipt's own clang pin (the first clang22 whose
#       libclang ships everywhere), not the analyzer's: $CC builds the fixtures.
# platform: drydock-objc dlopens RECEIPT_CLANG's libclang, so it is picked by drydock-objc's architecture (DRYDOCK_OBJC_ARCH,
#           which CTest sets; a standalone run takes the shell's), not the shell's: x86_64 takes 10.9's native clang22
#           pkg, arm64 the clang22-cross pkg.
RECEIPT_CLANG=${MAVERGREEN_OBJC_RECEIPT_CLANG_PREFIX:-${MAVERGREEN_OBJC_CLANG_PREFIX:-}}
if [ -z "$RECEIPT_CLANG" ] && [ "$(uname -s)" != Darwin ]; then
  # platform: off Darwin the pinned clang22's libclang is the Linux archive's libclang.so, whatever DRYDOCK_OBJC_ARCH says.
  RECEIPT_CLANG=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/objc-receipt-clang") || fail 'cannot fetch the pinned receipt clang'
fi
if [ -z "$RECEIPT_CLANG" ]; then
  case "${DRYDOCK_OBJC_ARCH:-$(uname -m)}" in x86_64) short=clang22; flavor=native ;; arm64) short=clang22-cross; flavor=cross ;; *) exit 4 ;; esac
  version=$(tr -d '[:space:]' < "$ROOT/components/objc-receipt-clang/version")
  RECEIPT_CLANG=$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "mavericks-clang-22-$flavor-$version.pkg" "$short" "$version" "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/objc-receipt-$short-$version")
fi

# spec: src/objc/provider.c obj_target -- a provider's 8-byte literal is matched where the linker merged it:
#       lld (which links Codex) into __TEXT,__literals, linked here; ld64 into __TEXT,__const, in a consumer ld64-241
#       linked once (tests/data/objc_provider_literal_ld64-241, with its archive and link map; the commit that added
#       it records the command), because no ld64 runs here.
if [ "$real" = 0 ]; then
  PFX_MAIN=$PFX; PFX="$T/pfx-literal"; fixture_prefix "$PFX" -DFIXTURE_LITERAL
  consumer "$T/root/bin/lit-lld" "$ALL"
  "$OTOOL" -l "$T/root/bin/lit-lld" | grep 'sectname __literals' >/dev/null || fail 'lld did not merge the literal into __TEXT,__literals'
  full "$T/root/bin/lit-lld" "$T/root/bin/lit-lld" "$T/root/bin/lit-lld.map" lit-lld; positive 'a literal, linked by lld'
  LD64=$ROOT/tests/data/objc_provider_literal_ld64-241
  PFX="$T/pfx-literal-ld64"; mkdir -p "$PFX/lib" "$PFX/share/recaulk"
  cp "$LD64/libfixture-objc.a" "$PFX/lib/"; cp "$LD64/lit-ld64" "$T/root/bin/lit-ld64"
  sed -e "s|@SDK@|$SDK|g" -e "s|@PFX@|$PFX|g" -e "s|@OUT@|$T/root/bin/lit-ld64|" -e 's|@CONSUMER_O@|provider-consumer.o|' \
    "$LD64/lit-ld64.map" >"$T/root/bin/lit-ld64.map"
  printf '%s  provider-register.c\n%s  provider-impl.c\n' "$(sha "$FX/provider-register.c")" "$(sha "$FX/provider-impl.c")" >"$T/ld64-receipt"
  declare_prefix "$PFX" "$T/ld64-receipt"
  "$OTOOL" -l "$T/root/bin/lit-ld64" | grep 'sectname __const' >/dev/null || fail 'the committed ld64 consumer has no __TEXT,__const'
  ! "$OTOOL" -l "$T/root/bin/lit-ld64" | grep 'sectname __literals' >/dev/null || fail 'the committed ld64 consumer merged into __literals'
  full "$T/root/bin/lit-ld64" "$T/root/bin/lit-ld64" "$T/root/bin/lit-ld64.map" lit-ld64; positive 'a literal, linked by ld64'
  PFX=$PFX_MAIN
fi
# spec: src/objc/provider.c header, 2 -- every GOT load of a provider-defined symbol that lld relaxed in one atom
#       is allowed (Recaulk's register.o has two), and an opcode byte changed any other way is still a mismatch.
if [ "$real" = 0 ]; then
  PFX_MAIN=$PFX; PFX="$T/pfx-two-got"; mkdir -p "$PFX/lib" "$PFX/share/recaulk" "$PFX.objects"
  for m in provider-register provider-two-got; do fxcc -Os -fPIC -Wall -c "$FX/$m.c" -o "$PFX.objects/$m.o"; done
  static_lib "$PFX/lib/libfixture-objc.a" "$PFX.objects/provider-two-got.o" "$PFX.objects/provider-register.o"
  printf '%s  provider-register.c\n%s  provider-two-got.c\n' "$(sha "$FX/provider-register.c")" "$(sha "$FX/provider-two-got.c")" >"$T/two-got-receipt"
  declare_prefix "$PFX" "$T/two-got-receipt"
  O="$PFX.objects/provider-two-got.o"
  sites=$("$OTOOL" -rv "$O" | awk '$5=="GOT_LD" {print $1}')
  [ "$(echo $sites | wc -w | tr -d ' ')" = 2 ] || fail "provider-two-got.o: GOT loads at '$sites', want two"
  [ "$("$NM" "$O" | awk '$2=="T" {print $3}')" = "_$IMPL" ] || fail 'provider-two-got.o is not the one atom _'"$IMPL"
  text=$("$OTOOL" -l "$O" | awk '/sectname __text/ {f=1} f && $1=="offset" {print $2; exit}')
  consumer "$T/root/bin/two-got" "$ALL"
  base=$(symaddr "$T/root/bin/two-got" "_$IMPL")
  for r in $sites; do
    [ "$(od -An -tx1 -j $((text + 0x$r - 2)) -N1 "$O" | tr -d ' ')" = 8b ] || fail "provider-two-got.o: no movq at 0x$r"
    [ "$(od -An -tx1 -j "$(fileoff "$T/root/bin/two-got" $((base + 0x$r - 2)))" -N1 "$T/root/bin/two-got" | tr -d ' ')" = 8d ] ||
      fail "two-got: lld did not relax the GOT load at 0x$r to leaq"
  done
  full "$T/root/bin/two-got" "$T/root/bin/two-got" "$T/root/bin/two-got.map" two-got
  positive 'two relaxed GOT loads in one atom'
  set -- $sites; site=$1   # either GOT load would do
  cp "$T/root/bin/two-got" "$T/root/bin/two-got-movl"
  putn "$T/root/bin/two-got-movl" "$(fileoff "$T/root/bin/two-got-movl" $((base + 0x$site - 2)))" $((0x89)) 1
  full "$T/root/bin/two-got-movl" "$T/root/bin/two-got-movl" "$T/root/bin/two-got.map" two-got-movl
  nonzero 'a relaxed GOT load whose opcode is then changed'; error_is provider-mapping-mismatch 'a changed opcode byte'
  cp "$T/root/bin/two-got" "$T/root/bin/two-got-rex"
  rex=$(fileoff "$T/root/bin/two-got-rex" $((base + 0x$site - 3)))
  [ "$(od -An -tx1 -j "$rex" -N1 "$T/root/bin/two-got-rex" | tr -d ' ')" = 48 ] || fail "two-got: no REX.W before the leaq at 0x$site"
  putn "$T/root/bin/two-got-rex" "$rex" $((0x4c)) 1
  full "$T/root/bin/two-got-rex" "$T/root/bin/two-got-rex" "$T/root/bin/two-got.map" two-got-rex
  nonzero 'a changed byte neither masked nor relocated'; error_is provider-mapping-mismatch 'a changed REX byte'
  grep -F 'differs from the final image' "$T/report" >/dev/null || fail 'a changed REX byte: not reported as differing from the final image'
  PFX=$PFX_MAIN
fi
# spec: src/objc/provider.c header, build side -- an assembler-local atom (l_OBJC_LABEL_CLASS_$, l_switch.table.*), whose symbol the
#       linker drops, is verified by its bytes in the prestrip image, not by name; a byte changed in one is prestrip-mismatch.
#       tests/objc/fixtures/provider-locals.m is the member that has them (and l_OBJC_CLASSLIST_SUP_REFS_$_, a slot compared by content).
if [ "$real" = 0 ]; then
  PFX_MAIN=$PFX; PFX="$T/pfx-locals"; mkdir -p "$PFX/lib" "$PFX/share/recaulk" "$PFX.objects"
  fxcc -Os -fPIC -Wall -fno-objc-arc -c "$FX/provider-locals.m" -o "$PFX.objects/provider-locals.o"
  fxcc -Os -fPIC -Wall -c "$FX/provider-register.c" -o "$PFX.objects/provider-register.o"
  static_lib "$PFX/lib/libfixture-objc.a" "$PFX.objects/provider-locals.o" "$PFX.objects/provider-register.o"
  printf '%s  provider-locals.m\n%s  provider-register.c\n' "$(sha "$FX/provider-locals.m")" "$(sha "$FX/provider-register.c")" >"$T/locals-receipt"
  declare_prefix "$PFX" "$T/locals-receipt"
  for sym in 'l_OBJC_LABEL_CLASS_$' 'l_switch.table.' 'l_OBJC_CLASSLIST_SUP_REFS_$_'; do
    "$NM" "$PFX.objects/provider-locals.o" | grep -F -- " s $sym" >/dev/null || fail "provider-locals.o has no $sym"
  done
  consumer "$T/root/bin/locals" "$ALL"
  for sym in 'l_OBJC_LABEL_CLASS_$' 'l_switch.table.' 'l_OBJC_CLASSLIST_SUP_REFS_$_'; do
    ! "$NM" "$T/root/bin/locals" | grep -F -- " $sym" >/dev/null || fail "locals: the linker kept $sym, so the prestrip image has it by name"
  done
  evidence "$T/root/bin/locals" "$T/root/bin/locals" "$T/root/bin/locals.map" "$T/ev/locals.json"
  exit_is 0 'atoms: assembler-local atoms of a provider member'
  for sym in 'l_OBJC_LABEL_CLASS_$' 'l_switch.table.'; do
    grep -F "\"symbol\": \"$sym" "$T/ev/locals.json" >/dev/null || fail "atoms: $sym passes by bytes, but the evidence does not place it"
  done
  grep -F '"symbol": "l_OBJC_CLASSLIST_SUP_REFS_$_' "$T/ev/locals.json" >/dev/null &&
    fail 'atoms: l_OBJC_CLASSLIST_SUP_REFS_$_ is a slot, not a placed atom'
  sw=$(sed -n 's/.*"address": "\(0x[0-9a-f]*\)".*"symbol": "l_switch.table[^"]*".*/\1/p;s/.*"symbol": "l_switch.table[^"]*".*"address": "\(0x[0-9a-f]*\)".*/\1/p' "$T/ev/locals.json" | head -1)
  [ -n "$sw" ] || fail 'atoms: no address for l_switch.table in the evidence'
  cp "$T/root/bin/locals" "$T/root/bin/locals-flip"
  off=$(fileoff "$T/root/bin/locals-flip" $((sw + 8)))
  old=$(od -An -tu1 -j "$off" -N1 "$T/root/bin/locals-flip" | tr -d ' ')
  putn "$T/root/bin/locals-flip" "$off" $(( (old + 1) % 256 )) 1
  evidence "$T/root/bin/locals-flip" "$T/root/bin/locals-flip" "$T/root/bin/locals.map" "$T/ev/locals-flip.json"
  exit_is 4 'atoms: a byte flipped in an l_ atom'
  grep -F 'prestrip-mismatch' "$T/err" >/dev/null || fail 'atoms: a flipped l_ atom byte is not a prestrip-mismatch'
  grep -F 'l_switch.table' "$T/err" >/dev/null || fail 'atoms: the refusal does not name the l_switch.table atom'
  PFX=$PFX_MAIN
fi
# spec: tests/objc/fixtures/provider-body.m header -- body_source DIR [DEFINE...]: the body, with each DEFINE turned on
#       by a line added to the source itself (a different file, not a compiler flag), and the registration member beside it.
body_source() {
  d=$1; shift; mkdir -p "$d"; : >"$d/provider-body.m"
  for def in "$@"; do printf '#define %s 1\n' "$def" >>"$d/provider-body.m"; done
  cat "$FX/provider-body.m" >>"$d/provider-body.m"; cp "$FX/provider-register.c" "$d/provider-register.c"
}
# spec: tests/objc/fixtures/provider-body.m header -- body_prefix PREFIX SRCDIR [CC-FLAGS]: that source archived and
#       declared as fixture_prefix declares its own, with its source receipt at PREFIX.receipt (none when RECEIPT=0).
body_prefix() {
  P=$1 D=$2; shift 2
  rm -rf "$P" "$P.objects"; mkdir -p "$P/lib" "$P/share/recaulk" "$P.objects"
  fxcc -Os -fPIC -Wall -fno-objc-arc "$@" -c "$D/provider-body.m" -o "$P.objects/provider-body.o" || fail "compiling $D/provider-body.m"
  fxcc -Os -fPIC -Wall "$@" -c "$D/provider-register.c" -o "$P.objects/provider-register.o"
  static_lib "$P/lib/libfixture-objc.a" "$P.objects/provider-body.o" "$P.objects/provider-register.o"
  printf '%s  provider-body.m\n%s  provider-register.c\n' "$(sha "$D/provider-body.m")" "$(sha "$D/provider-register.c")" >"$P.inputs"
  declare_prefix "$P" "$P.inputs"
  if [ "${RECEIPT:-1}" = 1 ]; then
    rm -f "$P.receipt"
    "$DRYDOCK_OBJC" receipt --clang-prefix "$RECEIPT_CLANG" --sdk "$SDK" --inputs "$P.inputs" --root "$D" \
      --unit provider-body.m --unit provider-register.c --output "$P.receipt" 2>"$T/err" || fail "source inventory of $D"
  fi
}
# spec: src/objc/source-evidence.c header -- body NAME PREFIX [RECEIPT]: link the consumer with PREFIX, build its
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
# spec: src/objc/classify.c header -- R1 (b), amended: the same id local, vended by -[NSDictionary objectForKey:],
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

# spec: src/objc/source-evidence.c header -- a body send the receipt cannot speak for, because the binary gives no
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
# spec: src/objc/source-evidence.c header -- the receipt's tool line must be this analyzer's own
#       tools/objc-source-inventory.c: a receipt written by an edited or other tool is cannot-measure.
grep -Fx "$(printf 'tool\t%s' "$(sha "$ROOT/tools/objc-source-inventory.c")")" "$T/pfx-body.receipt" >/dev/null ||
  fail 'the source receipt does not name the committed inventory tool'
sed 's/^tool	.*/tool	0ed0bd43e87a32b32aafb495a459e2248e2136ae1b7358e725fc654b2c33b676/' "$T/pfx-body.receipt" >"$T/tool.receipt"
body other-tool "$T/pfx-body" "$T/tool.receipt"
exit_is 4 'a receipt from another tool source'; error_is source-receipt-tool-mismatch 'a receipt from another tool source'
rc=0; "$DRYDOCK_OBJC" analyze --artifact "$T/root/bin/sourced-body" --root "$T/root" --references "$REF" --report "$T/out/noprefix" \
  --mode strict --source-receipt "$T/pfx-body.receipt" 2>"$T/err" || rc=$?
exit_is 2 'a source receipt without a provider prefix'
rm -f "$T/again.receipt"
"$DRYDOCK_OBJC" receipt --clang-prefix "$RECEIPT_CLANG" --sdk "$SDK" --inputs "$T/pfx-body.inputs" --root "$T/body" \
  --unit provider-body.m --unit provider-register.c --output "$T/again.receipt" 2>"$T/err" || fail 'second inventory'
cmp -s "$T/again.receipt" "$T/pfx-body.receipt" || fail 'the source receipt is not deterministic'
printf '\n' >>"$T/body/provider-body.m"
rc=0; "$DRYDOCK_OBJC" receipt --clang-prefix "$RECEIPT_CLANG" --sdk "$SDK" --inputs "$T/pfx-body.inputs" --root "$T/body" \
  --unit provider-body.m --unit provider-register.c --output "$T/changed.receipt" 2>"$T/err" || rc=$?
exit_is 4 'inventory of a source that no longer hashes to its input list'; [ ! -e "$T/changed.receipt" ] || fail 'a refused inventory wrote a receipt'
rc=0; "$DRYDOCK_OBJC" receipt --clang-prefix "$RECEIPT_CLANG" --sdk "$SDK" --inputs "$T/pfx-body.inputs" --root "$T/body" \
  --unit provider-body.m --output "$T/pfx-body.receipt" 2>"$T/err" || rc=$?
exit_is 2 'inventory onto an existing receipt'

# spec: src/objc/source-evidence.c header -- a schema-2 receipt (receipt --unit-flags) is read as schema 1 is: a body
#       built ARC with a prefix header closes its sends; a unit row with a flag or path the tool cannot have written is
#       malformed-source-receipt. The analyzer's allowed flags are the tool's, compared here as text.
flag_set() { awk '/UNIT_FLAGS\[\] = \{/ {f=1} f {print} f && /\};/ {exit}' "$1" | grep -o '"[^"]*"' | tr '\n' ' '; }
tool_flags=$(flag_set "$ROOT/tools/objc-source-inventory.c"); analyzer_flags=$(flag_set "$ROOT/src/objc/source-evidence.c")
case "$tool_flags" in '"-fobjc-arc" '*'"-Wno-deprecated-declarations" ') ;; *) fail "the tool's UNIT_FLAGS did not extract: '$tool_flags'" ;; esac
[ "$analyzer_flags" = "$tool_flags" ] || fail "receipt flags: the analyzer allows '$analyzer_flags', the tool '$tool_flags'"
body_source "$T/body-arc"; mkdir -p "$T/body-arc/inc"; printf '#import <Foundation/Foundation.h>\n' >"$T/body-arc/inc/prefix.h"
printf 'provider-body.m\t-fobjc-arc\t-Wall\t-include\tinc/prefix.h\t-I\tinc\nprovider-register.c\t-w\n' >"$T/body-arc/unit.flags"
P="$T/pfx-arc"; rm -rf "$P" "$P.objects"; mkdir -p "$P/lib" "$P/share/recaulk" "$P.objects"
fxcc -Os -fPIC -Wall -g -fobjc-arc -include "$T/body-arc/inc/prefix.h" -I "$T/body-arc/inc" -c "$T/body-arc/provider-body.m" -o "$P.objects/provider-body.o" ||
  fail 'compiling the ARC body'
fxcc -Os -fPIC -Wall -g -c "$T/body-arc/provider-register.c" -o "$P.objects/provider-register.o"
static_lib "$P/lib/libfixture-objc.a" "$P.objects/provider-body.o" "$P.objects/provider-register.o"
for f in inc/prefix.h provider-body.m provider-register.c unit.flags; do printf '%s  %s\n' "$(sha "$T/body-arc/$f")" "$f"; done >"$P.inputs"
declare_prefix "$P" "$P.inputs"
"$DRYDOCK_OBJC" receipt --clang-prefix "$RECEIPT_CLANG" --sdk "$SDK" --inputs "$P.inputs" --root "$T/body-arc" \
  --unit provider-body.m --unit provider-register.c --unit-flags unit.flags --output "$P.receipt" 2>"$T/err" || fail 'source inventory with unit flags'
[ "$(head -1 "$P.receipt")" = '# objc-source-receipt 2' ] || fail 'the receipt with unit flags is not schema 2'
body arc-body "$P" "$P.receipt"
exit_is 0 'receipt: schema 2 closes sends'; want_verdict provided 'receipt: schema 2 closes sends'
for s in isFileURL count objectForKey:; do finding_is "$s" floor-supported '"source"' 'receipt: schema 2 closes sends'; done
# spec: src/objc/source-evidence.c header -- bad_unit WHY SED-EXPRESSION: the schema-2 receipt so edited is malformed-source-receipt.
bad_unit() {
  sed "$2" "$P.receipt" >"$T/unit.receipt"; ! cmp -s "$T/unit.receipt" "$P.receipt" || fail "receipt: $1: the edit changed nothing"
  analyze "$T/root/bin/arc-body" --build-evidence "$T/ev/arc-body.json" --provider-prefix "$P" --source-receipt "$T/unit.receipt"
  exit_is 4 "receipt: $1"; error_is malformed-source-receipt "receipt: $1"
}
bad_unit 'a schema-2 unit row with -fplugin=' '/^unit	provider-body.m	/s/$/ -fplugin=x/'
bad_unit 'a unit row -I outside <stage>' 's,-I <stage>/inc,-I /tmp,'
bad_unit 'a unit row -I of a label prefix, not a directory' 's,-I <stage>/inc,-I <stage>/in,'
bad_unit 'a unit row -include of no input' 's,-include <stage>/inc/prefix.h,-include <stage>/inc/absent.h,'
bad_unit 'a unit row -I with no value' '/^unit	provider-body.m	/s/$/ -I/'
bad_unit 'a unit row -I of the empty directory above an input not relative' \
  '/^input	inc\/prefix.h	/{p;s,inc/prefix.h,/abs/prefix.h,;}
s,-I <stage>/inc,-I <stage>/,'
bad_unit 'a schema-2 unit row with no flags' 's/^unit	provider-register.c	.*/unit	provider-register.c	/'
bad_unit 'a unit row for no input' 's/^unit	provider-register.c	/unit	other.c	/'
bad_unit 'a schema-1 header over unit rows with flags' '1s/2$/1/'

if [ -n "${MAVERGREEN_OBJC_CODEX_ARTIFACT:-}" ]; then
  mkdir -p "$T/root/codex"
  ln "$MAVERGREEN_OBJC_CODEX_ARTIFACT" "$T/root/codex/codex" 2>/dev/null || cp "$MAVERGREEN_OBJC_CODEX_ARTIFACT" "$T/root/codex/codex"
  analyze "$T/root/codex/codex" --build-evidence "$FX/codex-0.165.0-build-evidence.json" --provider-prefix "$PFX"
  exit_is 1 'original Codex with the provider installed'; want_verdict unsupported 'original Codex'
  grep '"status": "inactive"' "$T/report" >/dev/null || fail 'original Codex: the provider is not reported inactive'
fi
echo "objc-provider: link arguments, positive and every mutation pass ($([ "$real" = 1 ] && echo "Recaulk provider $PFX" || echo 'fixture provider'))"
