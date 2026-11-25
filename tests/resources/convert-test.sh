#!/bin/sh
# platform: host-agnostic -- converts scratch bundles of committed nibs, one nib byte-patched to carry an unknown key,
#   and builds its one Mach-O fixture with the pinned clang22 against the pinned 10.9 SDK (tests/lib/toolchain.sh),
#   which links but never runs it; the read-only directory case is skipped when running as root
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
R=$DRYDOCK_RESOURCES
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
T=$(mktemp -d "${TMPDIR:-/tmp}/convert-test.XXXXXX") || exit 1
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
TAB=$(printf '\t')
refs() { echo --references "$ROOT/reference/objc" --resource-references "$ROOT/reference/resources"; }
convert() {  # OUT ARG...: drydock-resources convert ARG..., stdout in $T/OUT, stderr in $T/OUT.err, status in $T/OUT.rc
  out=$1; shift
  "$R" convert $(refs) "$@" > "$T/$out" 2>"$T/$out.err"; echo $? > "$T/$out.rc"
}
rc() { cat "$T/$1.rc"; }
err() { head -3 "$T/$1.err"; }
keyed() { [ "$(head -c 8 "$1")" = bplist00 ]; }
bundle() {  # NAME: an empty app bundle at $T/NAME.app, its resources dir printed
  mkdir -p "$T/$1.app/Contents/Resources/Base.lproj" && echo "$T/$1.app/Contents/Resources"
}
# spec: od prints each byte in decimal; the first run of the bytes of OLD is overwritten with NEW, of the same length.
patch() {  # FILE OLD NEW
  want=$(printf '%s' "$2" | od -An -v -tu1 | tr -s ' \n' '  ')
  at=$(od -An -v -tu1 "$1" | tr -s ' \n' '\n\n' | sed '/^$/d' | awk -v want="$want" '
    BEGIN { n = split(want, w, " ") }
    { b[NR] = $1 }
    END { for (i = 1; i <= NR - n + 1; i++) { for (j = 1; j <= n && b[i + j - 1] == w[j]; j++) ; if (j > n) { print i - 1; found++ } }
          if (found != 1) exit 1 }') || return 1
  printf '%s' "$3" | dd of="$1" bs=1 seek="$at" conv=notrunc 2>/dev/null
}

cp "$FIX/nib/layout.nib" "$T/bad.nib"
patch "$T/bad.nib" NSBoxType DDNotAKey && "$R" check $(refs) "$T/bad.nib" > "$T/bad.check" 2>&1
[ "$(grep -c ': finding: unknown-key DDNotAKey (NSBox @17)$' "$T/bad.check")" = 1 ] \
  || fail "setup: bad.nib does not carry DDNotAKey: $(head -3 "$T/bad.check")"

L=$(bundle layout)
cp "$FIX/nib/layout.nib" "$L/Base.lproj/layout.nib"
cp -R "$FIX/nib-10.9/int64.nib" "$FIX/nib-10.9/layout.nib" "$L/"
mv "$L/layout.nib" "$L/apple.nib"
convert layout --report "$T/layout.json" "$T/layout.app"
keyed "$L/Base.lproj/layout.nib" && [ "$(rc layout)" = 0 ] \
  && pass "convert_layout: a bundle's NIBArchive nib is now a keyed archive, and the strict convert exits 0" \
  || fail "convert_layout: exit $(rc layout), $(err layout)"
grep -q '"adapt":\["translate-autoresizing","wrapping-width"\]' "$T/layout.json" \
  && [ "$(grep -c '"kind":"adapted","nib":"Contents/Resources/Base.lproj/layout.nib","item":"wrapping-width","detail":"@21 NSPreferredMaxLayoutWidth","severity":"adapted"' "$T/layout.json")" = 1 ] \
  && pass "convert_layout: the report lists both rules on and the wrapping label adapted" \
  || fail "convert_layout: adapt: $(grep -e '"adapt"' -e adapted "$T/layout.json" | head -3)"
grep -q -e '"severity":"finding"' -e '"severity":"blocks-write"' "$T/layout.json" \
  && fail "convert_layout: the report has findings: $(grep -e '"severity":"finding"' -e blocks-write "$T/layout.json" | head -2)" \
  || pass "convert_layout: the report has no findings"
sha() { { shasum -a 256 "$1" 2>/dev/null || sha256sum "$1"; } | cut -d' ' -f1; }
grep -q "{\"path\":\"Contents/Resources/Base.lproj/layout.nib\",\"format\":\"nibarchive\",\"sha256_in\":\"$(sha "$FIX/nib/layout.nib")\",\"sha256_out\":\"$(sha "$L/Base.lproj/layout.nib")\",\"written\":true}" "$T/layout.json" \
  && pass "convert_layout: the report names the nib bundle-relative, with both digests, as written" \
  || fail "convert_layout: nibs: $(grep '"path"' "$T/layout.json")"
cmp -s "$FIX/nib-10.9/int64.nib/keyedobjects.nib" "$L/int64.nib/keyedobjects.nib" \
  && cmp -s "$FIX/nib-10.9/int64.nib/keyedobjects-101300.nib" "$L/int64.nib/keyedobjects-101300.nib" \
  && grep -q '{"path":"Contents/Resources/int64.nib/keyedobjects.nib","format":"keyed","sha256_in":"[0-9a-f]\{64\}","sha256_out":null,"written":false}' "$T/layout.json" \
  && pass "convert_layout: Apple's keyed nib needing no adaptation, and its variant, are left byte-identical" \
  || fail "convert_layout: int64.nib: $(grep int64 "$T/layout.json")"
"$R" dump "$L/apple.nib/keyedobjects.nib" > "$T/apple.rez" 2>&1
grep -q '^  NSPreferredMaxLayoutWidth = f64 [^ ]*  # 1426$' "$T/apple.rez" && cmp -s "$FIX/nib-10.9/layout.nib/keyedobjects-101300.nib" "$L/apple.nib/keyedobjects-101300.nib" \
  && grep -q '"kind":"adapted","nib":"Contents/Resources/apple.nib/keyedobjects.nib","item":"wrapping-width"' "$T/layout.json" \
  && pass "convert_layout: Apple's keyed nib that a rule adapts is rebuilt with the rewrite, its variant left alone" \
  || fail "convert_layout: apple.nib: $(grep PreferredMax "$T/apple.rez") $(grep apple.nib "$T/layout.json" | head -2)"
sed -n "s/^ {\"kind\":\"\([^\"]*\)\",\"nib\":\"\([^\"]*\)\",\"item\":\"\([^\"]*\)\",\"detail\":\"\([^\"]*\)\".*/\2$TAB\1$TAB\3$TAB\4/p" "$T/layout.json" > "$T/order"
sort -c -t "$TAB" -k1,1 -k2,2 -k3,3 -k4,4 "$T/order" 2>/dev/null && grep -q "${TAB}adapted$TAB" "$T/order" \
  && pass "convert_layout: the report's findings, adapted ones too, are sorted by nib, kind, item and detail" \
  || fail "convert_layout: unsorted: $(sort -c -t "$TAB" -k1,1 -k2,2 -k3,3 -k4,4 "$T/order" 2>&1)"
cp "$T/layout.app/Contents/Resources/Base.lproj/layout.nib" "$T/layout.keyed"
convert again "$T/layout.app"
[ "$(rc again)" = 0 ] && cmp -s "$T/layout.keyed" "$L/Base.lproj/layout.nib" \
  && pass "convert_layout: a keyed nib needing no adaptation is left byte-identical" \
  || fail "convert_layout: again: exit $(rc again), $(err again)"

S=$(bundle strict)
cp "$FIX/nib/layout.nib" "$S/Base.lproj/layout.nib"
cp "$T/bad.nib" "$S/bad.nib"
convert strict --report "$T/strict.json" "$T/strict.app"
[ "$(rc strict)" = 1 ] && cmp -s "$FIX/nib/layout.nib" "$S/Base.lproj/layout.nib" && cmp -s "$T/bad.nib" "$S/bad.nib" \
  && pass "convert_strict_blocks: an unknown key in one nib leaves both nibs byte-unchanged, exit 1" \
  || fail "convert_strict_blocks: exit $(rc strict), $(err strict)"
[ "$(grep -c '"written":false' "$T/strict.json")" = 2 ] && grep -q ': finding: unknown-key DDNotAKey (NSBox @17)$' "$T/strict" \
  && ! grep -q '"severity":"adapted"' "$T/strict.json" && grep -q '"severity":"will-adapt"' "$T/strict.json" \
  && pass "convert_strict_blocks: the report and stdout say why, that nothing was written, and that nothing was adapted" \
  || fail "convert_strict_blocks: report: $(grep '"path"' "$T/strict.json")"

cp "$FIX/nib/values.nib" "$S/values.nib"
convert loose --no-strict --report "$T/loose.json" "$T/strict.app"
[ "$(rc loose)" = 1 ] && keyed "$S/Base.lproj/layout.nib" && keyed "$S/bad.nib" && cmp -s "$FIX/nib/values.nib" "$S/values.nib" \
  && pass "convert_no_strict: what can be encoded is written, an unresolved chain's nib is left byte-unchanged, exit 1" \
  || fail "convert_no_strict: exit $(rc loose), $(err loose)"
grep -q '{"path":"Contents/Resources/values.nib","format":"nibarchive","sha256_in":"[0-9a-f]*","sha256_out":null,"written":false}' "$T/loose.json" \
  && grep -q '"strict":false' "$T/loose.json" \
  && pass "convert_no_strict: the report marks the unresolved nib unwritten, with nothing built" \
  || fail "convert_no_strict: report: $(grep -e '"path"' -e strict "$T/loose.json" | head -4)"
"$R" dump "$S/bad.nib" | grep -q '^  DDNotAKey = ' \
  && pass "convert_no_strict: the unknown key is carried into the keyed nib" || fail "convert_no_strict: DDNotAKey was dropped"

E=$(bundle except)
cp "$FIX/nib/layout.nib" "$E/Base.lproj/layout.nib"
cp "$T/bad.nib" "$E/bad.nib"
printf '*/bad.nib\tunknown-key\tDDNotAKey\treviewed\n' > "$T/ex"
convert except --exceptions "$T/ex" --report "$T/except.json" "$T/except.app"
[ "$(rc except)" = 0 ] && keyed "$E/bad.nib" && keyed "$E/Base.lproj/layout.nib" \
  && pass "convert_exceptions: an accepted unknown key no longer blocks the strict convert" \
  || fail "convert_exceptions: exit $(rc except), $(err except)"
grep -q '"kind":"unknown-key","nib":"Contents/Resources/bad.nib","item":"DDNotAKey","detail":"NSBox @17","severity":"finding","deviation":"unknown-key:DDNotAKey"' "$T/except.json" \
  && grep -q '{"line":"\*/bad.nib\\tunknown-key\\tDDNotAKey\\treviewed","applied":\["Contents/Resources/bad.nib: unknown-key DDNotAKey"\]}' "$T/except.json" \
  && grep -q ': finding: unknown-key DDNotAKey (NSBox @17) accepted as unknown-key:DDNotAKey$' "$T/except" \
  && pass "convert_exceptions: the report marks the deviation, and the line the finding it covers" \
  || fail "convert_exceptions: report: $(grep -e DDNotAKey "$T/except.json" | head -3)"
cp "$FIX/nib/layout.nib" "$E/Base.lproj/layout.nib"
cp "$T/bad.nib" "$E/bad.nib"
printf '*/bad.nib\tunknown-key\tDDNotAKey\treviewed\n*/gone.nib\tunknown-key\tDDNotAKey\tstale\n' > "$T/ex2"
convert unused --exceptions "$T/ex2" --report "$T/unused.json" "$T/except.app"
[ "$(rc unused)" = 0 ] && grep -q "^drydock-resources: unused exception: \*/gone.nib${TAB}unknown-key${TAB}DDNotAKey${TAB}stale$" "$T/unused.err" \
  && grep -q '{"line":"\*/gone.nib\\tunknown-key\\tDDNotAKey\\tstale","applied":\[\]}' "$T/unused.json" \
  && pass "convert_exceptions: a line that matches nothing is reported as unused, on stderr and in the report, and exit is 0" \
  || fail "convert_exceptions: unused: exit $(rc unused), $(err unused)"
for line in "*/layout.nib${TAB}unknown-key${TAB}DDNotAKey${TAB}another nib" "*/bad.nib${TAB}unknown-key${TAB}DDNotAKeyX${TAB}another key" \
            "*/bad.nib${TAB}class-missing${TAB}DDNotAKey${TAB}another kind"; do
  printf '%s\n' "$line" > "$T/miss.ex"
  cp "$FIX/nib/layout.nib" "$E/Base.lproj/layout.nib"
  cp "$T/bad.nib" "$E/bad.nib"
  convert miss --exceptions "$T/miss.ex" "$T/except.app"
  [ "$(rc miss)" = 1 ] && cmp -s "$T/bad.nib" "$E/bad.nib" && grep -q 'unused exception' "$T/miss.err" \
    && pass "convert_exceptions: a line for $(printf '%s' "$line" | cut -f4) accepts nothing, so the strict convert still exits 1" \
    || fail "convert_exceptions: $(printf '%s' "$line" | tr '\t' ' '): exit $(rc miss)"
done
cp "$FIX/nib/layout.nib" "$E/Base.lproj/layout.nib"
for line in "*${TAB}unknown-key${TAB}DDNotAKey${TAB}everything" "*/*${TAB}unknown-key${TAB}DDNotAKey${TAB}everything" \
            "*/bad.nib${TAB}unknown-key${TAB}DDNotAKey" "*/bad.nib${TAB}no-such-kind${TAB}DDNotAKey${TAB}typo" \
            "*/bad.nib${TAB}unknown-key${TAB}${TAB}empty" "*/bad.nib${TAB}unknown-key${TAB}DDNotAKey${TAB}reason${TAB}extra"; do
  printf '%s\n' "$line" > "$T/bad.ex"
  rm -f "$T/badex.json"
  convert badex --exceptions "$T/bad.ex" --report "$T/badex.json" "$T/except.app"
  [ "$(rc badex)" = 4 ] && [ -s "$T/badex.err" ] && [ ! -e "$T/badex.json" ] && cmp -s "$FIX/nib/layout.nib" "$E/Base.lproj/layout.nib" \
    && pass "convert_exceptions: a malformed line exits 4, writing nothing ($(printf '%s' "$line" | tr '\t' ' '))" \
    || fail "convert_exceptions: malformed: exit $(rc badex): $(printf '%s' "$line" | tr '\t' ' ') $(err badex)"
done

convert noex --exceptions "$T/no-such-exceptions" "$T/except.app"
[ "$(rc noex)" = 4 ] && grep -q 'cannot read the exceptions' "$T/noex.err" \
  && pass "convert_exceptions: an exceptions file that cannot be read exits 4" || fail "convert_exceptions: unreadable: exit $(rc noex)"

B=$(bundle board)
cp -R "$FIX/nib/Main.storyboardc" "$B/Base.lproj/"
SB=$B/Base.lproj/Main.storyboardc
convert board --report "$T/board.json" "$T/board.app"
[ "$(rc board)" = 1 ] && cmp -s "$FIX/nib/Main.storyboardc/Svc-aa-001-view-Svw-aa-003.nib" "$SB/Svc-aa-001-view-Svw-aa-003.nib" \
  && grep -q '^Contents/Resources/Base.lproj/Main.storyboardc: finding: storyboard NSStoryboard (10.10)$' "$T/board" \
  && pass "convert_storyboard: a storyboard is a finding, so the strict convert writes nothing, exit 1" \
  || fail "convert_storyboard: exit $(rc board), $(head -2 "$T/board") $(err board)"
printf '*/Main.storyboardc\tstoryboard\tNSStoryboard\tno storyboard loads on 10.9\n' > "$T/sb.ex"
convert boardok --exceptions "$T/sb.ex" --report "$T/boardok.json" "$T/board.app"
[ "$(rc boardok)" = 0 ] && keyed "$SB/Svc-aa-001-view-Svw-aa-003.nib" \
  && cmp -s "$FIX/nib/Main.storyboardc/DDFixtureScene.nib" "$SB/DDFixtureScene.nib" \
  && pass "convert_storyboard: with storyboard accepted, its encodable inner nib is converted, the unencodable one left, exit 0" \
  || fail "convert_storyboard: accepted: exit $(rc boardok), $(err boardok)"
[ "$(grep -c '"deviation":"storyboard:NSStoryboard"' "$T/boardok.json")" -ge 3 ] \
  && grep -q '"kind":"unresolved-chain","nib":"Contents/Resources/Base.lproj/Main.storyboardc/DDFixtureScene.nib",.*"deviation":"storyboard:NSStoryboard"' "$T/boardok.json" \
  && pass "convert_storyboard: the accepted storyboard covers its inner nibs' findings, marked as its deviation" \
  || fail "convert_storyboard: deviations: $(grep -c storyboard:NSStoryboard "$T/boardok.json")"

V=$(bundle variant)
mkdir -p "$V/v.nib"
cp "$FIX/nib-10.9/layout.nib/keyedobjects-101300.nib" "$V/v.nib/"
cp "$FIX/nib-10.9/layout.nib/keyedobjects-101300.nib" "$V/v.nib/keyedobjects-100900.nib"
convert variant --report "$T/variant.json" "$T/variant.app"
[ "$(rc variant)" = 0 ] && keyed "$V/v.nib/keyedobjects.nib" \
  && cmp -s "$FIX/nib-10.9/layout.nib/keyedobjects-101300.nib" "$V/v.nib/keyedobjects-101300.nib" \
  && grep -q '^Contents/Resources/v.nib/keyedobjects-101300.nib: will-adapt: no-floor-nib keyedobjects.nib (keyedobjects-101300.nib stands in for it)$' "$T/variant" \
  && pass "walker_variant_only: a nib directory with only variants gets keyedobjects.nib from the highest, reporting no-floor-nib" \
  || fail "walker_variant_only: exit $(rc variant), $(cat "$T/variant") $(err variant)"
"$R" dump "$V/v.nib/keyedobjects.nib" > "$T/v.rez" 2>&1 && grep -q "^  NSPreferredMaxLayoutWidth = f64 [^ ]*  # 1426$" "$T/v.rez" \
  && pass "walker_variant_only: the written keyedobjects.nib is the variant converted and adapted" \
  || fail "walker_variant_only: $(head -3 "$T/v.rez")"

P=$(bundle partial)
for d in a b c; do mkdir -p "$P/$d" && cp "$FIX/nib/layout.nib" "$P/$d/$d.nib"; done
if [ "$(id -u)" = 0 ]; then
  echo "SKIP: convert_partial_io: running as root, a read-only directory stops nothing"
else
  chmod a-w "$P/b"
  convert partial --report "$T/partial.json" "$T/partial.app"
  chmod u+w "$P/b"
  same=0; for d in a b c; do cmp -s "$FIX/nib/layout.nib" "$P/$d/$d.nib" && same=$((same + 1)); done
  left=0; for d in a b c; do left=$((left + $(ls -A "$P/$d" | wc -l))); done
  [ "$(rc partial)" = 4 ] && [ "$same" = 3 ] && [ "$left" = 3 ] \
    && pass "convert_partial_io: a nib that cannot be staged leaves all three byte-identical, no temp files, exit 4" \
    || fail "convert_partial_io: exit $(rc partial), $same unchanged, $left entries, $(err partial)"
  [ "$(grep -c '"written":false' "$T/partial.json")" = 3 ] && ! grep -q '"written":true' "$T/partial.json" \
    && pass "convert_partial_io: the report marks none as written" || fail "convert_partial_io: report: $(grep '"path"' "$T/partial.json")"
fi

W=$(bundle walkup)
cp "$FIX/nib/values.nib" "$W/values.nib"
printf 'int dd_classless(void) { return 0; }\n' > "$T/classless.c"
if ( . "$ROOT/tests/lib/toolchain.sh" &&
     mkdir -p "$T/walkup.app/Contents/Frameworks/DD.framework/Versions/A" "$T/walkup.app/Contents/MacOS" &&
     env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -mmacosx-version-min=10.9 -O1 -dynamiclib -fno-objc-arc \
       "$FIX/objc/DDFixtureView.m" -framework AppKit -o "$T/walkup.app/Contents/Frameworks/DD.framework/Versions/A/DD" &&
     env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -mmacosx-version-min=10.9 -O1 -dynamiclib "$T/classless.c" \
       -o "$T/walkup.app/Contents/MacOS/walkup" ) > "$T/build" 2>&1; then
  ln -s Versions/A/DD "$T/walkup.app/Contents/Frameworks/DD.framework/DD"
  "$R" dump --references "$ROOT/reference/objc" "$W/values.nib" > "$T/walkup.rez" 2>"$T/walkup.err"
  grep -q '^chain DDFixtureView : NSView : NSResponder : NSObject$' "$T/walkup.rez" \
    && pass "walker_walk_up: dump finds a custom class's chain in the enclosing bundle's frameworks" \
    || fail "walker_walk_up: dump: $(grep DDFixtureView "$T/walkup.rez" | head -2) $(head -2 "$T/walkup.err")"
  convert walkup --no-strict "$T/walkup.app"
  keyed "$W/values.nib" && ! grep -q 'unresolved-chain' "$T/walkup" \
    && pass "walker_walk_up: convert of the bundle resolves it too, so the nib is written" \
    || fail "walker_walk_up: convert: exit $(rc walkup), $(grep -e unresolved -e unencodable "$T/walkup") $(err walkup)"
  printf 'garbage' > "$T/walkup.app/Contents/MacOS/notes"
  cp "$FIX/nib/values.nib" "$W/values.nib"
  convert walkup2 --no-strict "$W/values.nib"
  keyed "$W/values.nib" && ! grep -q 'its classes are not used' "$T/walkup2.err" \
    && pass "walker_walk_up: convert of a lone nib walks up to its bundle, reading only Mach-O files" \
    || fail "walker_walk_up: lone nib: exit $(rc walkup2), $(err walkup2)"
else
  fail "walker_walk_up: cannot build the fixtures: $(tail -3 "$T/build")"
fi

cp "$FIX/nib/layout.nib" "$T/lone.nib"
convert lone --report "$T/lone.json" "$T/lone.nib"
[ "$(rc lone)" = 0 ] && keyed "$T/lone.nib" && grep -q '"path":"lone.nib"' "$T/lone.json" \
  && pass "convert: a lone nib converts in place, named by its file name" || fail "convert: lone nib: exit $(rc lone), $(err lone)"
: > "$T/taken.json"
cp "$FIX/nib/layout.nib" "$T/lone.nib"
convert taken --report "$T/taken.json" "$T/lone.nib"
[ "$(rc taken)" = 2 ] && [ ! -s "$T/taken.json" ] && cmp -s "$FIX/nib/layout.nib" "$T/lone.nib" \
  && pass "convert: an existing report file is refused, exit 2, writing nothing" || fail "convert: taken report: exit $(rc taken)"
convert text "$T/layout.json"
[ "$(rc text)" = 4 ] && grep -q 'unsupported format' "$T/text.err" \
  && pass "convert: a file that is no nib exits 4" || fail "convert: not a nib: exit $(rc text), $(err text)"

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
