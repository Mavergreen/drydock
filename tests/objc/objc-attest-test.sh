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

# spec: tests/objc/lib/objc_fixture_sweep.sh -- fixture_sweep DIR, SWEEP_WINDOW and SWEEP_TARGET.
. "$HERE/lib/objc_fixture_sweep.sh"
SW="$T/sweep"
fixture_sweep "$SW"
evidence "$SW/root/bin/sweep" "$SW/sweep.map" "$T/ev/sweep.json"
exit_is 0 'evidence for the sweep fixture'
# spec: src/objc/main.c usage -- analyze NAME [ARGS]: the sweep fixture, strict, its report at $T/out/NAME.json; rc set.
mkdir -p "$T/out" "$T/dirs/empty"
# IMG is the fixture analyzed: $SW, or a variant's directory.
IMG=$SW
analyze() {
  rep="$T/out/$1.json"; shift
  rc=0; "$DRYDOCK_OBJC" analyze --artifact "$IMG/root/bin/sweep" --root "$IMG/root" --references "$REF" --report "$rep" \
    --mode strict --analyzer-id fixture "$@" 2>"$T/err" || rc=$?
}
attested() { analyze "$1" --build-evidence "$T/ev/${3:-sweep}.json" --link-map "$IMG/${4:-sweep}.map" --object-dir "$2"; }
# spec: src/objc/macho-reader.c sweep_undecodable -- the refusal, as the report's error and stderr carry it.
WINDOW=$SWEEP_WINDOW
REFUSAL="possible reference to $SWEEP_TARGET"
refused_because() {
  exit_is 4 "$2"
  grep -F "{\"code\": \"undecodable-objc-reference\", \"slice\": \"x86_64\", \"address\": \"$WINDOW\", \"detail\": \"$REFUSAL (not attested: $1)\"}" "$rep" >/dev/null ||
    fail "$2: the refusal does not say '(not attested: $1)'"
  grep -xF "objc-compat: undecodable-objc-reference: $REFUSAL (not attested: $1)" "$T/err" >/dev/null || fail "$2: stderr does not name why"
}
# spec: src/objc/main.c report -- a clean run's attested count, and the limit only a link map adds.
LIMIT_ATTESTED="undecoded bytes are cleared only where their object file shows the assembler fixed them and they name nothing outside that object's section"
clean_attested() {
  exit_is 0 "$1"
  n=$(sed -n 's/.*"undecoded_code_bytes_attested": \([0-9]*\).*/\1/p' "$rep")
  [ -n "$n" ] && [ "$n" -gt 0 ] || fail "$1: undecoded_code_bytes_attested is '$n'"
  grep -F "\"$LIMIT_ATTESTED\"" "$rep" >/dev/null || fail "$1: the limits do not say how undecoded bytes are cleared"
}
# variant NAME: the sweep-table.S variant's image, map, archive and evidence; IMG, WINDOW and REFUSAL name it.
variant() {
  IMG=$T/v-$1
  if [ ! -f "$IMG/hit" ]; then
    (fixture_sweep "$IMG" "$1" && printf '%s %s\n' "$SWEEP_WINDOW" "$SWEEP_TARGET" >"$IMG/hit") || fail "the $1 fixture"
    evidence "$IMG/root/bin/sweep" "$IMG/sweep.map" "$T/ev/$1.json"; exit_is 0 "evidence for the $1 fixture"
  fi
  read -r WINDOW _target <"$IMG/hit"; REFUSAL="possible reference to $_target"
}
base() { IMG=$SW; WINDOW=$SWEEP_WINDOW; REFUSAL="possible reference to $SWEEP_TARGET"; }

test_link_map_needs_evidence() {
  analyze needs-evidence --link-map "$SW/sweep.map"
  exit_is 2 '--link-map without --build-evidence'
  grep 'link-map needs --build-evidence' "$T/err" >/dev/null || fail '--link-map without evidence does not say why'
}

test_link_map_hash_mismatch() {
  analyze hash-mismatch --build-evidence "$T/ev/sweep.json" --link-map "$T/maps/plain.map"
  exit_is 4 'a link map the evidence did not record'
  grep "link-map-mismatch: .*plain.map does not hash to the build evidence's link_map.sha256" "$T/err" >/dev/null ||
    fail 'a link map the evidence did not record is not link-map-mismatch'
}

test_link_map_unrecorded() {
  "$DRYDOCK_OBJC" evidence --artifact "$SW/root/bin/sweep" --prestrip "$SW/root/bin/sweep" --source-root "$FX" \
    --references "$REF" --output "$T/ev/sweep-nomap.json" 2>"$T/err" || fail 'evidence without a link map'
  analyze unrecorded --build-evidence "$T/ev/sweep-nomap.json" --link-map "$SW/sweep.map"
  exit_is 4 'a link map when the evidence records none'
  grep 'link-map-mismatch: .* records no link map' "$T/err" >/dev/null || fail 'evidence without a map is not link-map-mismatch'
}

test_object_dir_missing() {
  analyze nope --build-evidence "$T/ev/sweep.json" --link-map "$SW/sweep.map" --object-dir "$T/nope"
  exit_is 2 'a missing --object-dir'
  grep -e '--object-dir is not a directory' "$T/err" >/dev/null || fail 'a missing --object-dir does not say why'
  analyze file --build-evidence "$T/ev/sweep.json" --link-map "$SW/sweep.map" --object-dir "$SW/sweep.map"
  exit_is 2 'an --object-dir naming a file'
  analyze no-map --build-evidence "$T/ev/sweep.json" --object-dir "$T/dirs/empty"
  exit_is 2 '--object-dir without --link-map'
  analyze twice --build-evidence "$T/ev/sweep.json" --link-map "$SW/sweep.map" --link-map "$SW/sweep.map"
  exit_is 2 '--link-map given twice'
}

test_unattested_reason_not_found() {
  attested not-found "$T/dirs/empty"
  refused_because 'libsweep.a not found in --object-dir' 'an archive in no --object-dir'
}

test_unattested_reason_ambiguous() {
  mkdir -p "$T/dirs/a" "$T/dirs/b"
  cp "$SW/obj/libsweep.a" "$T/dirs/a/"; cp "$SW/obj/libsweep.a" "$T/dirs/b/"
  analyze ambiguous --build-evidence "$T/ev/sweep.json" --link-map "$SW/sweep.map" --object-dir "$T/dirs/a" --object-dir "$T/dirs/empty" --object-dir "$T/dirs/b"
  refused_because 'libsweep.a found in 2 --object-dirs' 'an archive in two --object-dirs'
}

test_unattested_member_twice() {
  mkdir -p "$T/dirs/twice"
  "$AR" qc "$T/dirs/twice/libsweep.a" "$SW/obj/sweep.o"; "$AR" qc "$T/dirs/twice/libsweep.a" "$SW/obj/sweep.o"
  attested twice "$T/dirs/twice"
  refused_because 'sweep.o appears twice in libsweep.a' 'an archive with two members of that name'
}

test_unattested_member_absent() {
  mkdir -p "$T/dirs/other"
  cp "$SW/obj/main.o" "$T/dirs/other/sweep-other.o"
  "$AR" rc "$T/dirs/other/libsweep.a" "$T/dirs/other/sweep-other.o"
  attested absent "$T/dirs/other"
  refused_because 'sweep.o is not a member of libsweep.a' 'an archive without that member'
}

test_unattested_not_x86_64() {
  mkdir -p "$T/dirs/i386/m"
  # One -arch only: fxcc's x86_64 plus i386 would make clang call lipo, which a guest without Xcode lacks.
  env -i PATH=/usr/bin:/bin "$CC" -arch i386 -isysroot "$SDK" -mmacosx-version-min=10.9 -c "$FX/sweep-table.S" -o "$T/dirs/i386/m/sweep.o"
  [ "$(od -An -tx1 -N8 "$T/dirs/i386/m/sweep.o" | tr -d ' \n')" = cefaedfe07000000 ] || fail 'the i386 member is not a thin i386 object'
  "$AR" rc "$T/dirs/i386/libsweep.a" "$T/dirs/i386/m/sweep.o"
  attested i386 "$T/dirs/i386"
  refused_because 'not an x86_64 object' 'an i386 member'
}

# spec: src/objc/attest.c objc_obj_parse -- a second LC_SYMTAB is a malformed object, refused before it allocates:
#       the member's LC_DYSYMTAB rewritten as a copy of its LC_SYMTAB.
test_unattested_two_symtabs() {
  mkdir -p "$T/dirs/symtabs/m"
  perl -0777 -e '$_ = <STDIN>; ($ncmds) = unpack("x16 V", $_); $off = 32;
    for my $i (1 .. $ncmds) { ($cmd, $size) = unpack("V V", substr($_, $off, 8)); $st = $off if $cmd == 2; $dy = $off if $cmd == 11; $off += $size }
    defined $st && defined $dy or die "no LC_SYMTAB and LC_DYSYMTAB";
    substr($_, $dy, 4) = pack("V", 2); substr($_, $dy + 8, 16) = substr($_, $st + 8, 16); print' \
    <"$SW/obj/sweep.o" >"$T/dirs/symtabs/m/sweep.o" || fail 'the object has no LC_SYMTAB and LC_DYSYMTAB to patch'
  "$OTOOL" -l "$T/dirs/symtabs/m/sweep.o" 2>&1 | grep -F 'more than one LC_SYMTAB command' >/dev/null || fail 'llvm-otool does not see two LC_SYMTABs'
  "$AR" rcS --format=darwin "$T/dirs/symtabs/libsweep.a" "$T/dirs/symtabs/m/sweep.o"
  attested symtabs "$T/dirs/symtabs"
  refused_because 'member sweep.o: two symbol tables' 'a member with two symbol tables'
}

# spec: src/objc/attest.c read_object -- an archive the sweep cannot read, or one too large to read, is the window's
#       reason, not an error: rustc's rlibs run to 755 MB. A sparse file past OBJC_ARCHIVE_MAX (256 MiB) is never read.
test_unattested_unreadable() {
  if [ "$(id -u)" = 0 ]; then echo 'skip: root reads a mode-000 archive' >&2; return 0; fi
  mkdir -p "$T/dirs/unreadable"; cp "$SW/obj/libsweep.a" "$T/dirs/unreadable/"; chmod 000 "$T/dirs/unreadable/libsweep.a"
  attested unreadable "$T/dirs/unreadable"
  refused_because 'libsweep.a unreadable' 'an archive the sweep cannot open'
}
test_unattested_oversized() {
  mkdir -p "$T/dirs/oversized"
  dd if=/dev/null of="$T/dirs/oversized/libsweep.a" bs=1 count=0 seek=268435457 2>/dev/null
  [ "$(wc -c <"$T/dirs/oversized/libsweep.a" | tr -d ' ')" = 268435457 ] || fail 'the oversized archive is not 256 MiB + 1'
  attested oversized "$T/dirs/oversized"
  refused_because 'libsweep.a too large to read' 'an archive past the size cap'
  rm -f "$T/dirs/oversized/libsweep.a"
}

# spec: src/objc/attest.h objc_attest_object -- a map atom from file 0 is the linker's own; one whose [N] has
#       no Object files line has no object. The map is edited before the evidence records it.
test_unattested_no_object() {
  sed 's/\[  2\] _sweep_fn$/[  0] _sweep_fn/' "$SW/sweep.map" >"$SW/synth.map"
  sed 's/\[  2\] _sweep_fn$/[ 77] _sweep_fn/' "$SW/sweep.map" >"$SW/nofile.map"
  for m in synth nofile; do
    ! cmp -s "$SW/sweep.map" "$SW/$m.map" || fail "the $m map is the fixture's"
    evidence "$SW/root/bin/sweep" "$SW/$m.map" "$T/ev/$m.json"; exit_is 0 "evidence for the $m map"
  done
  mkdir -p "$T/dirs/synth"; cp "$SW/obj/libsweep.a" "$T/dirs/synth/"
  attested synth "$T/dirs/synth" synth synth
  refused_because 'linker synthesized' 'an atom the linker synthesized'
  attested nofile "$T/dirs/synth" nofile nofile
  refused_because 'no object file line' 'an atom with no object file line'
}

test_inputs_record_link_map() {
  mkdir -p "$T/dirs/one"; cp "$SW/obj/libsweep.a" "$T/dirs/one/"
  attested one "$T/dirs/one"
  clean_attested 'the sweep fixture with its archive found'
  grep -F "\"link_map\": {\"sha256\": \"$(sha "$SW/sweep.map")\"}" "$rep" >/dev/null || fail 'inputs do not record the link map'
}

test_attested_clean() {
  mkdir -p "$T/dirs/clean"; cp "$SW/obj/libsweep.a" "$T/dirs/clean/"
  attested clean "$T/dirs/clean"
  clean_attested 'the sweep fixture attested from its archive'
  n=$(sed -n 's/.*"undecoded_code_bytes": \([0-9]*\).*/\1/p' "$rep")
  [ "$n" = 16 ] || fail "undecoded_code_bytes is '$n', not _sweep_fn's 16"
  if grep -F 'undecodable-objc-reference' "$rep" >/dev/null; then fail 'an attested window is still a finding'; fi
}

test_without_inputs_refuses() {
  analyze without
  exit_is 4 'the sweep fixture without a link map'
  grep -F "\"detail\": \"$REFUSAL\"}" "$rep" >/dev/null || fail 'the sweep fixture without a link map is not undecodable-objc-reference'
  if grep -e 'undecoded_code_bytes_attested' -e "$LIMIT_ATTESTED" "$rep" >/dev/null; then fail 'a report without a link map counts attested bytes'; fi
}

# spec: src/objc/attest.c objc_attest_window -- the window's bytes are the object's: one table byte flipped in the
#       member refuses, as an object that is not the one linked would.
flipped_archive() {
  mkdir -p "$1"
  K=$((SWEEP_TARGET - SWEEP_WINDOW - 4)) perl -0777 -pe 'BEGIN { $v = pack("l<", $ENV{K}) } s/\x06\Q$v\E/"\x06" . chr(ord(substr($v, 0, 1)) ^ 1) . substr($v, 1)/e == 1 or die "no table"' \
    "$SW/obj/libsweep.a" >"$1/libsweep.a" || fail 'the table is not once in the archive'
  ! cmp -s "$SW/obj/libsweep.a" "$1/libsweep.a" || fail 'the flipped archive is the fixture'"'"'s'
}
test_changed_byte() {
  flipped_archive "$T/dirs/flipped"
  attested flipped "$T/dirs/flipped"
  refused_because 'bytes differ from the object' 'a member whose table byte differs from the image'
}

# spec: src/objc/attest.c locate -- an archive at the map's own path is used, with no --object-dir and ahead of
#       one: it attests through its bytes, and a different file there refuses though --object-dir holds the right one.
test_map_path_wins() {
  mkdir -p "$SW/link"; cp "$SW/obj/libsweep.a" "$SW/link/libsweep.a"
  analyze map-path --build-evidence "$T/ev/sweep.json" --link-map "$SW/sweep.map"
  clean_attested 'the archive at the map'"'"'s own path'
  flipped_archive "$T/dirs/flipped-link"
  cp "$T/dirs/flipped-link/libsweep.a" "$SW/link/libsweep.a"
  mkdir -p "$T/dirs/good"; cp "$SW/obj/libsweep.a" "$T/dirs/good/"
  attested map-path-differs "$T/dirs/good"
  refused_because 'bytes differ from the object' 'a different archive at the map'"'"'s own path'
  rm -rf "$SW/link"
}

test_relocation() {
  variant reloc
  mkdir -p "$T/dirs/reloc"; cp "$IMG/obj/libsweep.a" "$T/dirs/reloc/"
  attested reloc "$T/dirs/reloc" reloc
  refused_because 'a relocation covers the window' 'a table entry the linker relocates'
  base
}

test_same_section() {
  variant same
  mkdir -p "$T/dirs/same"; cp "$IMG/obj/libsweep.a" "$T/dirs/same/"
  attested same "$T/dirs/same" same
  refused_because "target inside the same object's section" 'a target in the member'"'"'s own section'
  base
}

# spec: src/objc/attest.c objc_attest_window -- condition 5 has two halves, each refusing alone. The map edited so
#       the member also places the lazy pointer: outside where its __text would lie, inside an atom of its own.
test_target_in_own_atom() {
  t=$(printf '0x%X' "$((SWEEP_TARGET))")
  sed "s/^$t\(	0x[0-9A-F]*	\)\[  3\] _method_getName\$/$t\1[  2] _method_getName/" "$SW/sweep.map" >"$SW/own.map"
  [ "$(diff "$SW/sweep.map" "$SW/own.map" | grep -c '^>')" = 1 ] || fail 'the own map does not re-attribute the lazy pointer alone'
  evidence "$SW/root/bin/sweep" "$SW/own.map" "$T/ev/own.json"; exit_is 0 'evidence for the own map'
  mkdir -p "$T/dirs/own"; cp "$SW/obj/libsweep.a" "$T/dirs/own/"
  attested own "$T/dirs/own" own own
  refused_because "target inside the same object's section" 'a target in an atom the member places elsewhere'
}

# The same fixture's map edited so the fetch function is main.o's and _sweep_fn ends 8 bytes before it: no atom of
# the member reaches the target, but the member's whole __text, placed where _sweep_fn starts, does.
test_target_in_own_section_span() {
  variant same
  f=$(printf '0x%X' "$((WINDOW - 1))")
  sed -e "s/^$f	0x00000010	\[  2\] _sweep_fn\$/$f	0x00000008	[  2] _sweep_fn/" \
      -e 's/\[  2\] \(__RN.*CachedSel5fetch\)$/[  1] \1/' "$IMG/sweep.map" >"$IMG/span.map"
  [ "$(diff "$IMG/sweep.map" "$IMG/span.map" | grep -c '^>')" = 2 ] || fail 'the span map does not edit _sweep_fn and the fetch atom'
  evidence "$IMG/root/bin/sweep" "$IMG/span.map" "$T/ev/span.json"; exit_is 0 'evidence for the span map'
  mkdir -p "$T/dirs/span"; cp "$IMG/obj/libsweep.a" "$T/dirs/span/"
  attested span "$T/dirs/span" span span
  refused_because "target inside the same object's section" 'a target in the member'"'"'s section past its atoms'
  base
}

test_straddle() {
  variant straddle
  mkdir -p "$T/dirs/straddle"; cp "$IMG/obj/libsweep.a" "$T/dirs/straddle/"
  attested straddle "$T/dirs/straddle" straddle
  refused_because 'no single atom covers the window' 'a window across two atoms'
  base
}

test_got_relax_opcode() {
  variant relax
  mkdir -p "$T/dirs/relax"; cp "$IMG/obj/libsweep.a" "$T/dirs/relax/"
  attested relax "$T/dirs/relax" relax
  refused_because 'bytes differ from the object' 'a window over a relaxed GOT load'"'"'s opcode'
  base
}

# spec: src/objc/linkmap.h objc_linkmap_cover -- atoms nest in a map: a zero-size atom where the window starts
#       hides nothing, and a sized atom of another file inside _sweep_fn leaves no single atom covering it.
test_nested_atoms() {
  w=$(printf '0x%X' "$((SWEEP_WINDOW))")
  awk -v w="$w" '{ print } /\[  2\] _sweep_fn$/ { print w "\t0x00000000\t[  2] ltmp_nested" }' "$SW/sweep.map" >"$SW/zero.map"
  awk -v w="$w" '{ print } /\[  2\] _sweep_fn$/ { print w "\t0x00000004\t[  1] _nested" }' "$SW/sweep.map" >"$SW/inner.map"
  mkdir -p "$T/dirs/nest"; cp "$SW/obj/libsweep.a" "$T/dirs/nest/"
  for m in zero inner; do
    [ "$(wc -l <"$SW/$m.map")" -gt "$(wc -l <"$SW/sweep.map")" ] || fail "the $m map adds no atom"
    evidence "$SW/root/bin/sweep" "$SW/$m.map" "$T/ev/$m.json"; exit_is 0 "evidence for the $m map"
  done
  "$DRYDOCK_OBJC_READER_DRIVER" --link-map "$SW/zero.map" "$w" | grep -x "at	$w	-" >/dev/null ||
    fail 'objc_linkmap_atom_at no longer hides _sweep_fn behind a zero-size atom; this test no longer tests the widening'
  attested zero "$T/dirs/nest" zero zero
  clean_attested 'a zero-size atom where the window starts'
  attested inner "$T/dirs/nest" inner inner
  refused_because 'no single atom covers the window' 'a sized atom nested in _sweep_fn'
}

# spec: src/objc/main.c -- without --link-map the sweep's refusal is today's, byte for byte (what 433bed6 printed).
test_no_inputs_identical() {
  analyze plain-sweep
  exit_is 4 'the sweep fixture without a link map'
  printf 'objc-compat: undecodable-objc-reference: %s\n' "$REFUSAL" | diff - "$T/err" >&2 || fail 'stderr without a link map differs'
  grep -F "{\"code\": \"undecodable-objc-reference\", \"slice\": \"x86_64\", \"address\": \"$SWEEP_WINDOW\", \"detail\": \"$REFUSAL\"}]}" "$rep" >/dev/null ||
    fail 'the refusal without a link map differs'
  if grep -e '"link_map"' -e 'not attested' -e 'bytes_attested' "$rep" >/dev/null; then fail 'a report without a link map mentions one'; fi
  analyze plain-sweep-ev --build-evidence "$T/ev/sweep.json"
  exit_is 4 'the sweep fixture with evidence that records a map, given none'
  if grep -e '"link_map"' -e 'not attested' -e 'bytes_attested' "$rep" >/dev/null; then fail 'a report given no link map mentions one'; fi
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
test_link_map_needs_evidence
test_link_map_hash_mismatch
test_link_map_unrecorded
test_object_dir_missing
test_unattested_reason_not_found
test_unattested_reason_ambiguous
test_unattested_member_twice
test_unattested_member_absent
test_unattested_not_x86_64
test_unattested_two_symtabs
test_unattested_unreadable
test_unattested_oversized
test_unattested_no_object
test_inputs_record_link_map
test_no_inputs_identical
test_attested_clean
test_without_inputs_refuses
test_changed_byte
test_map_path_wins
test_relocation
test_same_section
test_target_in_own_atom
test_target_in_own_section_span
test_straddle
test_got_relax_opcode
test_nested_atoms
echo "objc-attest: link-map parse, provider-less evidence, the sweep's object resolution and its windows attested pass"
