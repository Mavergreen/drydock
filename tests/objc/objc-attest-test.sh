#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK with a link map, then reads them as bytes
# spec: src/objc/linkmap.c header -- one link-map parser for the provider mapping and the sweep's attestation;
#       emit-build-evidence binds a link map to this link without a provider. Nothing built here is executed.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
. "$ROOT/tests/lib/toolchain.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
: "${DRYDOCK_OBJC_READER_DRIVER:?names the built objc-reader-driver (CTest sets it)}"
FX="$HERE/fixtures"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-attest-test.XXXXXX")
trap 'chmod -R u+rw "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
fxcc() { env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 "$@"; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
mkdir -p "$T/bin" "$T/maps" "$T/ev"

# spec: cli/drydock-objc.c header (evidence) -- evidence ARTIFACT MAP OUT: the artifact is its own prestrip; rc set.
evidence() {
  rc=0; "$DRYDOCK_OBJC" evidence --artifact "$1" --prestrip "$1" --source-root "$FX" --link-map "$2" \
    --references "$REF" --output "$3" 2>"$T/err" || rc=$?
}
exit_is() { [ "$rc" = "$1" ] || fail "$2: exit $rc, want $1"; }

fxcc -O1 "$FX/plain.c" -Xlinker -map -Xlinker "$T/maps/plain.map" -o "$T/bin/plain"
fxcc -O0 "$FX/plain.c" -Xlinker -map -Xlinker "$T/maps/other.map" -o "$T/bin/other"

test_evidence_link_map_alone() {
  evidence "$T/bin/plain" "$T/maps/plain.map" "$T/ev/plain.json"
  exit_is 0 'a link map without a provider prefix'
  got=$(tr -d '\n' <"$T/ev/plain.json" | sed -n 's/.*"link_map": {"sha256": "\([0-9a-f]*\)"}.*/\1/p')
  [ "$got" = "$(sha "$T/maps/plain.map")" ] || fail "link_map.sha256 is '$got', not the map's"
  grep '"providers": \[\]' "$T/ev/plain.json" >/dev/null || fail 'provider-less evidence lists providers'
}

test_evidence_link_map_wrong_image() {
  evidence "$T/bin/other" "$T/maps/plain.map" "$T/ev/wrong.json"
  exit_is 4 'a link map from another link'
  grep link-map-mismatch "$T/err" >/dev/null || fail 'a link map from another link is not link-map-mismatch'
  [ ! -e "$T/ev/wrong.json" ] || fail 'a mismatched link map wrote evidence'
}

test_evidence_crlf_map() {
  perl -pe 's/\n/\r\n/' "$T/maps/plain.map" >"$T/maps/crlf.map"
  [ "$(grep -c "$(printf '\r')\$" "$T/maps/crlf.map")" = "$(wc -l <"$T/maps/plain.map" | tr -d ' ')" ] || fail 'the CRLF map has lines without CR'
  evidence "$T/bin/plain" "$T/maps/crlf.map" "$T/ev/crlf.json"
  exit_is 0 'a CRLF link map'
  sed "s/$(sha "$T/maps/crlf.map")/MAP/" "$T/ev/crlf.json" >"$T/ev/crlf.norm"
  sed "s/$(sha "$T/maps/plain.map")/MAP/" "$T/ev/plain.json" >"$T/ev/plain.norm"
  cmp -s "$T/ev/crlf.norm" "$T/ev/plain.norm" || fail 'a CRLF map gives other evidence than its LF copy'
}

test_evidence_link_map_not_x86_64() {
  sed 's/^# Arch: x86_64$/# Arch: i386/' "$T/maps/plain.map" >"$T/maps/i386.map"
  evidence "$T/bin/plain" "$T/maps/i386.map" "$T/ev/i386.json"
  exit_is 4 'an i386 link map'
  grep 'link-map-mismatch: .* is not an x86_64 link map' "$T/err" >/dev/null || fail 'an i386 map is not named'
}

test_evidence_link_map_malformed() {
  { cat "$T/maps/plain.map"; echo 'zz not a symbol'; } >"$T/maps/bad.map"
  evidence "$T/bin/plain" "$T/maps/bad.map" "$T/ev/bad.json"
  exit_is 4 'a malformed link map'
  grep 'malformed-link-map: symbol line: zz not a symbol' "$T/err" >/dev/null || fail 'a malformed symbol line is not named'
}

# spec: src/objc/linkmap.h -- the parse, as objc-reader-driver --link-map MAP [VA]... prints it.
parse() { rc=0; "$DRYDOCK_OBJC_READER_DRIVER" --link-map "$@" >"$T/parse" 2>"$T/err" || rc=$?; }
want_parse() { printf '%s\n' "$@" >"$T/parse.want"; diff "$T/parse.want" "$T/parse" >&2 || fail 'the parse differs'; }

test_parse_paths() {
  printf '%s\r\n' '# Path: x' '# Arch: x86_64' '# Object files:' '[  0] linker synthesized' \
    '[  1] /tmp/a dir (v2)/lib(x).a(m o.o)' '[  2] /tmp/plain (1).o' '[  3] /tmp/libz.a(z.o)' \
    '# Sections:' '# Address	Size    	Segment	Section' '0x1000	0x00000030	__TEXT	__text' \
    '# Symbols:' '# Address	Size    	File  Name' \
    '0x1020	0x00000010	[  3] _z' '0x1000	0x00000010	[  1] _a b' '0x1010	0x00000000	[  2] _empty' \
    '0x1010	0x00000008	[  2] literal string: (x)' '0x1040	0x00000004	[  9] _nofile' \
    '# Dead Stripped Symbols:' '<<dead>> 	0x00000004	[  1] _gone' >"$T/maps/paths.map"
  parse "$T/maps/paths.map" 0x1000 0x1017 0x1018 0x102f 0x1030 0x1043
  exit_is 0 'parsing a CRLF map with spaces and parentheses'
  want_parse 'arch	x86_64' \
    'file	0	linker synthesized	-	-' 'file	1	-	/tmp/a dir (v2)/lib(x).a	m o.o' \
    'file	2	/tmp/plain (1).o	-	-' 'file	3	-	/tmp/libz.a	z.o' \
    'sect	0x1000	0x30	__TEXT	__text' \
    'atom	0x1000	0x10	1	_a b' 'atom	0x1010	0x0	2	_empty' 'atom	0x1010	0x8	2	literal string: (x)' \
    'atom	0x1020	0x10	3	_z' 'atom	0x1040	0x4	-1	_nofile' \
    'at	0x1000	0x1000	_a b' 'at	0x1017	0x1010	literal string: (x)' 'at	0x1018	-' \
    'at	0x102f	0x1020	_z' 'at	0x1030	-' 'at	0x1043	0x1040	_nofile'
}

test_parse_real_map() {
  parse "$T/maps/plain.map"
  exit_is 0 'parsing a real ld64 map'
  grep -x 'arch	x86_64' "$T/parse" >/dev/null || fail 'the real map has no x86_64 arch'
  [ "$(grep -c '^sect	' "$T/parse")" = "$(grep -c '^0x[0-9A-Fa-f]*	0x[0-9A-Fa-f]*	__' "$T/maps/plain.map")" ] ||
    fail 'the real map'"'"'s sections are not all parsed'
  grep '^atom	0x[0-9a-f]*	0x[0-9a-f]*	1	_main$' "$T/parse" >/dev/null || fail 'the real map'"'"'s _main is not an atom of file 1'
}

test_parse_malformed() {
  printf '%s\n' '# Arch: x86_64' '# Object files:' 'not an index' >"$T/maps/badfile.map"
  parse "$T/maps/badfile.map"
  exit_is 4 'a malformed object file line'
  grep -x 'error	malformed-link-map	-	0x0	object file line: not an index' "$T/parse" >/dev/null || fail 'a malformed object file line is not named'
  printf '%s\n' '# Arch: x86_64' '# Sections:' '0x1000 0x10 __TEXT_SEGMENT_TOO_LONG __text' >"$T/maps/longseg.map"
  parse "$T/maps/longseg.map"
  exit_is 4 'a segment name past 16 bytes'
  grep '^error	malformed-link-map	-	0x0	section line: ' "$T/parse" >/dev/null || fail 'a long segment name is not malformed'
  printf '# Arch: x86_64\n# Symbols:\n0x1000\t0x4\t[  1] _a\000\n' >"$T/maps/nul.map"
  parse "$T/maps/nul.map"
  exit_is 4 'a map with a NUL byte'
  grep 'holds a NUL byte' "$T/parse" >/dev/null || fail 'a NUL byte is not named'
}

# spec: src/objc/linkmap.h -- sorting by address keeps the map's order among atoms at one address.
test_parse_stable_sort() {
  { printf '%s\n' '# Arch: x86_64' '# Object files:' '[  0] linker synthesized' '# Symbols:' '0x3000	0x4	[  0] _last'
    i=100; while [ "$i" -lt 300 ]; do printf '0x2000\t0x0\t[  0] _s%d\n' "$i"; i=$((i + 1)); done; } >"$T/maps/ties.map"
  parse "$T/maps/ties.map"
  exit_is 0 'parsing atoms that share an address'
  { i=100; while [ "$i" -lt 300 ]; do echo "_s$i"; i=$((i + 1)); done; echo _last; } >"$T/ties.want"
  sed -n 's/^atom	.*	//p' "$T/parse" | diff "$T/ties.want" - >/dev/null || fail 'atoms at one address left the map'"'"'s order'
}

test_evidence_link_map_alone
test_evidence_link_map_wrong_image
test_evidence_crlf_map
test_evidence_link_map_not_x86_64
test_evidence_link_map_malformed
test_parse_paths
test_parse_real_map
test_parse_malformed
test_parse_stable_sort
echo "objc-attest: link-map parse and provider-less evidence pass"
