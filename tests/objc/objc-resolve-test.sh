#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then resolves reviewed evidence against them
# spec: src/objc/main.m resolve_main -- drydock-objc resolve fills each schema-2 record's symbol(s) and each
#       crate's disambiguator from the artifact: one function, or the copies of one generic instance; any other
#       repeated path, or a crate the debug map cannot tie to its version, is resolve-ambiguous; a missing path
#       is named. src/objc/demangle-v0.c prints paths as rustc-demangle does, checked against its own vectors.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$ROOT/build/msc.sh"
. "$ROOT/tests/lib/toolchain.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
: "${DRYDOCK_OBJC_DEMANGLE_DRIVER:?names the built objc-demangle-driver (CTest sets it)}"
FX="$HERE/fixtures/resolve"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-resolve-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
TAB=$(printf '\t')

# The demangler against rustc-demangle's own test vectors: exactly its text, or a refusal where marked.
grep -v '^#' "$HERE/fixtures/rustc-demangle-v0.tsv" >"$T/vectors"
cut -f3 "$T/vectors" | "$DRYDOCK_OBJC_DEMANGLE_DRIVER" >"$T/demangled" || fail "demangle-driver: exit $?"
[ "$(wc -l <"$T/vectors")" = "$(wc -l <"$T/demangled")" ] || fail 'demangle-driver answered a different number of lines'
paste "$T/vectors" "$T/demangled" | awk -F "$TAB" '
  $5 == "refused" && $6 != "NO" { print $1 ": " $3 " demangled to \"" $7 "\"; this demangler refuses it" }
  $5 != "refused" && $6 != "OK" { print $1 ": " $3 " refused: " $7 }
  $5 != "refused" && $6 == "OK" && $7 != $4 { print $1 ": " $3 " is \"" $7 "\", rustc-demangle says \"" $4 "\"" }' >"$T/mismatch"
[ ! -s "$T/mismatch" ] || fail "$(cat "$T/mismatch")"
[ "$(cut -f5 "$T/vectors" | grep -c '^$')" -gt 20 ] || fail 'fewer than 21 vectors are printed exactly'
# rustc-demangle accepts "R..." as well as "_R..."; its limit symbols are refused either way.
cut -f3 "$T/vectors" | grep '^R' | sed 's/^/_/' | "$DRYDOCK_OBJC_DEMANGLE_DRIVER" | grep -v "^NO$TAB" &&
  fail 'an underscored limit vector demangled'
# recursion_limit_leaks: 1000 leaves after "_RIC0p" do not exhaust the depth limit.
for leaf in 'p _' 'Rp &_' 'C1x x'; do
  set -- $leaf
  awk -v m="$1" -v d="$2" 'BEGIN { s = "_RIC0p"; e = "::<_"; for (i = 0; i < 1000; i++) { s = s m; e = e ", " d } print s "E"; print e ">" > "/dev/stderr" }' \
    2>"$T/leak-want" | "$DRYDOCK_OBJC_DEMANGLE_DRIVER" >"$T/leak-got"
  [ "$(cat "$T/leak-got")" = "OK$TAB$(cat "$T/leak-want")" ] || fail "recursion_limit_leaks: leaf $1"
done
# recursion_limit_backref_free_bypass: 100000 nested references reached through a backref are refused.
awk 'BEGIN { s = "_RIC100000"; for (i = 0; i < 100000; i++) s = s "R"; print s "B7_E" }' | "$DRYDOCK_OBJC_DEMANGLE_DRIVER" |
  grep "^NO$TAB" >/dev/null || fail 'recursion_limit_backref_free_bypass: demangled'

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
fxcc() { env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@"; }
# demo's own code, built with debug info in a registry-style NAME-VERSION directory per version: the debug
# map is what ties a disambiguator to a version.
for v in 1 2; do
  mkdir -p "$T/reg/demo-$v.0.0/src"
  cp "$FX/demo.c" "$T/reg/demo-$v.0.0/src/lib.c"
  (cd "$T/reg/demo-$v.0.0" && fxcc -g -c src/lib.c -DDIS=${v}V$v -o lib.o)
done
mkdir -p "$T/root/bin"
fxcc -c "$FX/app.c" -o "$T/app.o"
fxcc "$T/app.o" "$T/reg/demo-1.0.0/lib.o" "$T/reg/demo-2.0.0/lib.o" -o "$T/root/bin/r"
fxcc "$T/app.o" "$T/reg/demo-1.0.0/lib.o" "$T/reg/demo-2.0.0/lib.o" -Wl,-S -o "$T/root/bin/r-nodebug"
A="$T/root/bin/r"

mkdir -p "$T/src"
printf 'pub fn unique() {}\n' >"$T/src/lib.rs"
TREE=$("$DRYDOCK_OBJC" evidence --tree-digest-only --source-root "$T/src") || fail "--tree-digest-only: exit $?"
LIB=$(sha "$T/src/lib.rs")
APP='{"name": "app", "version": "0.1.0", "checksum": "c-app", "disambiguator": "old"}'
DEMO1='{"name": "demo", "version": "1.0.0", "checksum": "c-demo1"}'
DEMO2='{"name": "demo", "version": "2.0.0", "checksum": "c-demo2"}'
# ev OUT CRATES GUARDS [POSITIONS]: schema-2 reviewed evidence for $A.
ev() {
  cat >"$1" <<EOF
{"schema": 2, "kind": "objc-build-evidence",
 "artifact": {"path": "bin/r", "sha256": "$(sha "$A")"},
 "source": {"tree_sha256": "$TREE", "revision": "r", "patches_sha256": "p", "features": "f"},
 "crates": [$2], "type_map": [], "type_evidence": [], "binding_receipt": [],
 "position_evidence": [${4:-}],
 "guards": [$3]}
EOF
}
guard() {  # guard ID PATH [EXTRA-KEYS]
  printf '{"id": "%s", "path": "%s", %s"selector": "accessibilityDisplayShouldReduceMotion", "guard": "respondsToSelector:", "fallback": "returns 0", "sources": [{"cite": "tree:lib.rs", "sha256": "%s"}], "covers": [{"selector": "accessibilityDisplayShouldReduceMotion", "count": 1}], "provenance": {"revision": "r", "patches_sha256": "p", "features": "f"}, "review": {"status": "reviewed", "reviewer": "A. Reviewer", "reason": "NO falls back to 0"}}' \
    "$1" "$2" "${3:-}" "$LIB"
}
pos() {  # pos ID PATH
  printf '{"id": "%s", "path": "%s", "selectors": ["UTF8String"], "kind": "-", "class": "NSString", "position": {"form": "result", "selector": "description"}, "sources": [{"cite": "tree:lib.rs", "sha256": "%s"}], "note": "n"}' \
    "$1" "$2" "$LIB"
}
resolve() {  # resolve NAME EVIDENCE [ARTIFACT]: rc, $T/out.NAME, $T/err
  rc=0; "$DRYDOCK_OBJC" resolve --artifact "${3:-$A}" --reviewed "$2" --output "$T/out.$1" 2>"$T/err" || rc=$?
}
resolved() {  # resolved NAME: exit 0 and an output
  [ "$rc" = 0 ] || fail "$1: exit $rc, want 0"
  [ -f "$T/out.$1" ] || fail "$1: no output"
}
refused() {  # refused NAME CODE DETAIL...: exit 4, no output, CODE on stderr with every DETAIL
  name=$1 code=$2; shift 2
  [ "$rc" = 4 ] || fail "$name: exit $rc, want 4"
  [ ! -e "$T/out.$name" ] || fail "$name: wrote an output"
  grep -F "resolve: $code: " "$T/err" >"$T/lines" || fail "$name: no $code"
  for d in "$@"; do grep -F -- "$d" "$T/lines" >"$T/lines.next" || fail "$name: no $code detail with '$d'"; mv "$T/lines.next" "$T/lines"; done
}
# symbols NAME ID: the symbol(s) record ID resolved to, one per line, in the output's order.
symbols() {
  sed -n "/\"id\": \"$2\"/,/^    }/p" "$T/out.$1" | sed -n -e 's/^      "symbol": "\(.*\)",*$/\1/p' -e '/"symbols": \[/,/\]/s/^        "\(.*\)",*$/\1/p'
}
want_symbols() {  # want_symbols NAME ID SYMBOL...
  name=$1 id=$2; shift 2
  [ "$(symbols "$name" "$id" | tr '\n' ' ')" = "$* " ] || fail "$name: $id resolved to '$(symbols "$name" "$id" | tr '\n' ' ')', want '$* '"
}
disambiguator() {  # disambiguator NAME CRATE VERSION: the output's pin for that crate
  awk -v c="$2" -v v="$3" '/^    {/ { d = n = "" } /"disambiguator": / { d = $2 } /"name": / { n = $2 }
    /"version": / && n == "\"" c "\"," && $2 == "\"" v "\"" { gsub(/[",]/, "", d); print d }' "$T/out.$1"
}

# unique: one function; a stale symbol(s) and crate pin are replaced; everything else is carried, keys sorted.
ev "$T/ev-unique" "$APP" "$(guard g-unique app::unique '"symbols": ["old1", "old2"], ')" "$(pos p-unique app::unique)"
resolve unique "$T/ev-unique"
resolved unique
want_symbols unique g-unique __RNvCs7Ab_3app6unique
want_symbols unique p-unique __RNvCs7Ab_3app6unique
grep -F '"old1"' "$T/out.unique" >/dev/null && fail 'unique: the stale symbols survived'
cat >"$T/want.unique" <<EOF
{
  "artifact": {
    "path": "bin/r",
    "sha256": "$(sha "$A")"
  },
  "binding_receipt": [],
  "crates": [
    {
      "checksum": "c-app",
      "disambiguator": "7Ab",
      "name": "app",
      "version": "0.1.0"
    }
  ],
  "guards": [
    {
      "covers": [
        {
          "count": 1,
          "selector": "accessibilityDisplayShouldReduceMotion"
        }
      ],
      "fallback": "returns 0",
      "guard": "respondsToSelector:",
      "id": "g-unique",
      "path": "app::unique",
      "provenance": {
        "features": "f",
        "patches_sha256": "p",
        "revision": "r"
      },
      "review": {
        "reason": "NO falls back to 0",
        "reviewer": "A. Reviewer",
        "status": "reviewed"
      },
      "selector": "accessibilityDisplayShouldReduceMotion",
      "sources": [
        {
          "cite": "tree:lib.rs",
          "sha256": "$LIB"
        }
      ],
      "symbol": "__RNvCs7Ab_3app6unique"
    }
  ],
  "kind": "objc-build-evidence",
  "position_evidence": [
    {
      "class": "NSString",
      "id": "p-unique",
      "kind": "-",
      "note": "n",
      "path": "app::unique",
      "position": {
        "form": "result",
        "selector": "description"
      },
      "selectors": [
        "UTF8String"
      ],
      "sources": [
        {
          "cite": "tree:lib.rs",
          "sha256": "$LIB"
        }
      ],
      "symbol": "__RNvCs7Ab_3app6unique"
    }
  ],
  "schema": 2,
  "source": {
    "features": "f",
    "patches_sha256": "p",
    "revision": "r",
    "tree_sha256": "$TREE"
  },
  "type_evidence": [],
  "type_map": []
}
EOF
diff "$T/want.unique" "$T/out.unique" >"$T/diff" || { cat "$T/diff" >&2; fail 'unique: the output is not the input with symbols and pins filled in'; }

# generic_copies: one instance's copies, across instantiating crates and .llvm.N / .cold clones, are all of it.
ev "$T/ev-copies" "$APP" "$(guard g-copies 'app::id::<u8>' '"symbol": "stale", ')"
resolve generic_copies "$T/ev-copies"
resolved generic_copies
want_symbols generic_copies g-copies __RINvCs7Ab_3app2idhE __RINvCs7Ab_3app2idhECs8Yy_6other2.cold \
  __RINvCs7Ab_3app2idhECs9Zz_5other __RINvCs7Ab_3app2idhECs9Zz_5other.llvm.1234ABCD
grep -F '"stale"' "$T/out.generic_copies" >/dev/null && fail 'generic_copies: the stale symbol survived'

# two_versions: demo is linked at 1.0.0 and 2.0.0. Each pin resolves to its own version's disambiguator, by the
# debug map, and its paths to that version's functions alone, never the other's.
ev "$T/ev-v2" "$APP, $DEMO2" "$(guard g-helper demo::helper), $(guard g-wrap 'demo::wrap::<u8>')"
resolve two_versions "$T/ev-v2"
resolved two_versions
[ "$(disambiguator two_versions demo 2.0.0)" = 2V2 ] || fail "two_versions: demo 2.0.0 got '$(disambiguator two_versions demo 2.0.0)'"
want_symbols two_versions g-helper __RNvCs2V2_4demo6helper
want_symbols two_versions g-wrap __RINvCs2V2_4demo4wraphECs7Ab_3app __RINvCs2V2_4demo4wraphECs9Zz_5other
ev "$T/ev-v1" "$APP, $DEMO1" "$(guard g-helper demo::helper), $(guard g-wrap 'demo::wrap::<u8>')"
resolve two_versions_1 "$T/ev-v1"
resolved two_versions_1
[ "$(disambiguator two_versions_1 demo 1.0.0)" = 1V1 ] || fail "two_versions_1: demo 1.0.0 got '$(disambiguator two_versions_1 demo 1.0.0)'"
want_symbols two_versions_1 g-helper __RNvCs1V1_4demo6helper
want_symbols two_versions_1 g-wrap __RINvCs1V1_4demo4wraphECs7Ab_3app
# Both versions pinned: demo::helper is two functions, one per version.
ev "$T/ev-both" "$APP, $DEMO1, $DEMO2" "$(guard g-helper demo::helper)"
resolve two_versions_both "$T/ev-both"
refused two_versions_both resolve-ambiguous g-helper demo::helper __RNvCs1V1_4demo6helper __RNvCs2V2_4demo6helper
# Without a debug map nothing ties a disambiguator to a version.
resolve two_versions_nodebug "$T/ev-v2" "$T/root/bin/r-nodebug"
refused two_versions_nodebug resolve-ambiguous 'crate demo 2.0.0' 1V1 2V2

# ambiguous: two functions with one path that are not copies of one instance.
ev "$T/ev-dup" "$APP" "$(guard g-dup app::dup)"
resolve ambiguous "$T/ev-dup"
refused ambiguous resolve-ambiguous g-dup app::dup __RNvCs7Ab_3app3dup __RNvCs7Ab_3apps_3dup
# Copies differ only in instantiating crate, .llvm.N or .cold: another suffix is another function.
ev "$T/ev-part" "$APP" "$(guard g-part app::part)"
resolve ambiguous_suffix "$T/ev-part"
refused ambiguous_suffix resolve-ambiguous g-part app::part __RNvCs7Ab_3app4part.part.0

# missing_path: a path no function has is named; so is a path only data has.
ev "$T/ev-missing" "$APP" "$(guard g-unique app::unique), $(guard g-missing app::nowhere)"
resolve missing_path "$T/ev-missing"
refused missing_path stale-build-evidence g-missing app::nowhere
ev "$T/ev-data" "$APP" "$(guard g-data app::table)"
resolve data_path "$T/ev-data"
refused data_path stale-build-evidence g-data app::table
# A pinned crate the artifact does not name.
ev "$T/ev-nocrate" "$APP, {\"name\": \"absent\", \"version\": \"1.0.0\", \"checksum\": \"c\"}" "$(guard g-unique app::unique)"
resolve missing_crate "$T/ev-nocrate"
refused missing_crate stale-build-evidence 'crate absent 1.0.0'

# Usage: a missing option, an existing destination; schema-1 evidence is not resolvable.
rc=0; "$DRYDOCK_OBJC" resolve --artifact "$A" --reviewed "$T/ev-unique" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] || fail "no --output: exit $rc, want 2"
resolve unique "$T/ev-unique"
[ "$rc" = 2 ] || fail "an existing output: exit $rc, want 2"
printf '{"schema": 1, "kind": "objc-build-evidence"}\n' >"$T/ev-schema1"
resolve schema1 "$T/ev-schema1"
refused schema1 malformed-build-evidence 'not schema-2'

# What resolve writes, the analyzer reads: the resolved records parse and pin every crate.
REF="$ROOT/reference/objc"
rc=0; "$DRYDOCK_OBJC" analyze --artifact "$A" --root "$T/root" --references "$REF" --report "$T/report" \
  --build-evidence "$T/out.two_versions" --source-root "$T/src" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "analyzing resolved evidence: exit $rc, want 0"
! grep '"code": ' "$T/report" >/dev/null || fail "analyzing resolved evidence: $(grep '"code": ' "$T/report")"

echo "PASS: objc-resolve"
