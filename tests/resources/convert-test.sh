#!/bin/sh
# platform: host-agnostic -- converts scratch bundles of committed nibs, one nib byte-patched to carry an unknown key;
#   the read-only directory case is skipped when running as root
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

LC="*.nib${TAB}named-color-missing${TAB}labelColor${TAB}10.9 draws it opaque black"
printf '%s\n' "$LC" > "$T/lc"

cp "$FIX/nib/layout.nib" "$T/bad.nib"
patch "$T/bad.nib" NSBoxType DDNotAKey && "$R" check $(refs) "$T/bad.nib" > "$T/bad.check" 2>&1
[ "$(grep -c ': finding: unknown-key DDNotAKey (NSBox @17)$' "$T/bad.check")" = 1 ] \
  || fail "setup: bad.nib does not carry DDNotAKey: $(head -3 "$T/bad.check")"

L=$(bundle layout)
cp "$FIX/nib/layout.nib" "$L/Base.lproj/layout.nib"
cp -R "$FIX/nib-10.9/int64.nib" "$FIX/nib-10.9/layout.nib" "$L/"
mv "$L/layout.nib" "$L/apple.nib"
convert layout --exceptions "$T/lc" --report "$T/layout.json" "$T/layout.app"
keyed "$L/Base.lproj/layout.nib" && [ "$(rc layout)" = 0 ] \
  && pass "convert_layout: a bundle's NIBArchive nib is now a keyed archive, and the strict convert exits 0" \
  || fail "convert_layout: exit $(rc layout), $(err layout)"
grep -q '"adapt":\["translate-autoresizing","wrapping-width"\]' "$T/layout.json" \
  && [ "$(grep -c '"kind":"adapted","nib":"Contents/Resources/Base.lproj/layout.nib","item":"wrapping-width","detail":"@21 NSPreferredMaxLayoutWidth","severity":"adapted"' "$T/layout.json")" = 1 ] \
  && pass "convert_layout: the report lists both rules on and the wrapping label adapted" \
  || fail "convert_layout: adapt: $(grep -e '"adapt"' -e adapted "$T/layout.json" | head -3)"
grep -q -e '"severity":"finding","deviation":null' -e '"severity":"blocks-write"' "$T/layout.json" \
  && fail "convert_layout: the report has findings: $(grep -e '"severity":"finding"' -e blocks-write "$T/layout.json" | head -2)" \
  || pass "convert_layout: the report has no finding but the accepted labelColor"
grep -q '"kind":"named-color-missing","nib":"Contents/Resources/Base.lproj/layout.nib","item":"labelColor","detail":"10.10","severity":"finding","deviation":"named-color-missing:labelColor"' "$T/layout.json" \
  && pass "convert_layout: labelColor is a finding, accepted by the exceptions file" \
  || fail "convert_layout: labelColor: $(grep labelColor "$T/layout.json" | head -2)"
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
convert again --exceptions "$T/lc" "$T/layout.app"
[ "$(rc again)" = 0 ] && cmp -s "$T/layout.keyed" "$L/Base.lproj/layout.nib" \
  && pass "convert_layout: a keyed nib needing no adaptation is left byte-identical" \
  || fail "convert_layout: again: exit $(rc again), $(err again)"

S=$(bundle strict)
cp "$FIX/nib/layout.nib" "$S/Base.lproj/layout.nib"
cp "$T/bad.nib" "$S/bad.nib"
convert strict --exceptions "$T/lc" --report "$T/strict.json" "$T/strict.app"
[ "$(rc strict)" = 1 ] && cmp -s "$FIX/nib/layout.nib" "$S/Base.lproj/layout.nib" && cmp -s "$T/bad.nib" "$S/bad.nib" \
  && pass "convert_strict_blocks: an unknown key in one nib leaves both nibs byte-unchanged, exit 1" \
  || fail "convert_strict_blocks: exit $(rc strict), $(err strict)"
[ "$(grep -c '"written":false' "$T/strict.json")" = 2 ] && grep -q ': finding: unknown-key DDNotAKey (NSBox @17)$' "$T/strict" \
  && ! grep -q '"severity":"adapted"' "$T/strict.json" && grep -q '"severity":"will-adapt"' "$T/strict.json" \
  && pass "convert_strict_blocks: the report and stdout say why, that nothing was written, and that nothing was adapted" \
  || fail "convert_strict_blocks: report: $(grep '"path"' "$T/strict.json")"

cp "$FIX/nib/Main.storyboardc/DDFixtureScene.nib" "$S/scene.nib"
cp "$FIX/nib/values.nib" "$S/values.nib"
convert loose --no-strict --report "$T/loose.json" "$T/strict.app"
[ "$(rc loose)" = 1 ] && keyed "$S/Base.lproj/layout.nib" && keyed "$S/bad.nib" && cmp -s "$FIX/nib/Main.storyboardc/DDFixtureScene.nib" "$S/scene.nib" \
  && pass "convert_no_strict: what can be encoded is written, an object's unresolved chain leaves its nib byte-unchanged, exit 1" \
  || fail "convert_no_strict: exit $(rc loose), $(err loose)"
grep -q '{"path":"Contents/Resources/scene.nib","format":"nibarchive","sha256_in":"[0-9a-f]*","sha256_out":null,"written":false}' "$T/loose.json" \
  && grep -q '"strict":false' "$T/loose.json" \
  && pass "convert_no_strict: the report marks the unresolved nib unwritten, with nothing built" \
  || fail "convert_no_strict: report: $(grep -e '"path"' -e strict "$T/loose.json" | head -4)"
keyed "$S/values.nib" && grep -q '^Contents/Resources/values.nib: finding: unresolved-chain DDFixtureView (' "$T/loose" \
  && pass "convert_swapper_target: --no-strict writes a nib whose only unresolved class is an NSClassSwapper's target, reporting it" \
  || fail "convert_swapper_target: loose: $(grep values.nib "$T/loose" | head -2)"
W=$(bundle swapper)
cp "$FIX/nib/values.nib" "$W/values.nib"
convert swap "$T/swapper.app"
[ "$(rc swap)" = 1 ] && cmp -s "$FIX/nib/values.nib" "$W/values.nib" \
  && grep -q '^Contents/Resources/values.nib: finding: unresolved-chain DDFixtureView (' "$T/swap" \
  && pass "convert_swapper_target: strict, the swapper target's unresolved chain is a finding, so nothing is written, exit 1" \
  || fail "convert_swapper_target: strict: exit $(rc swap), $(grep values.nib "$T/swap" | head -2) $(err swap)"
printf '*/values.nib\t%s\t%s\t%s\n' unresolved-chain DDFixtureView 'its class is in a plug-in' \
  unknown-key NSChildControllerCreationSelectorName 'not in this test' > "$T/swap.ex"
convert swapok --exceptions "$T/swap.ex" "$T/swapper.app"
[ "$(rc swapok)" = 0 ] && keyed "$W/values.nib" \
  && grep -q 'unresolved-chain DDFixtureView (.*) accepted as unresolved-chain:DDFixtureView$' "$T/swapok" \
  && pass "convert_swapper_target: an exception accepts the swapper target's unresolved chain, and the strict convert writes the nib" \
  || fail "convert_swapper_target: accepted: exit $(rc swapok), $(grep values.nib "$T/swapok" | head -2) $(err swapok)"
"$R" dump "$S/bad.nib" | grep -q '^  DDNotAKey = ' \
  && pass "convert_no_strict: the unknown key is carried into the keyed nib" || fail "convert_no_strict: DDNotAKey was dropped"

E=$(bundle except)
cp "$FIX/nib/layout.nib" "$E/Base.lproj/layout.nib"
cp "$T/bad.nib" "$E/bad.nib"
{ printf '*/bad.nib\tunknown-key\tDDNotAKey\treviewed\n'; cat "$T/lc"; } > "$T/ex"
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
{ printf '*/bad.nib\tunknown-key\tDDNotAKey\treviewed\n*/gone.nib\tunknown-key\tDDNotAKey\tstale\n'; cat "$T/lc"; } > "$T/ex2"
convert unused --exceptions "$T/ex2" --report "$T/unused.json" "$T/except.app"
[ "$(rc unused)" = 0 ] && grep -q "^drydock-resources: unused exception: \*/gone.nib${TAB}unknown-key${TAB}DDNotAKey${TAB}stale$" "$T/unused.err" \
  && grep -q '{"line":"\*/gone.nib\\tunknown-key\\tDDNotAKey\\tstale","applied":\[\]}' "$T/unused.json" \
  && pass "convert_exceptions: a line that matches nothing is reported as unused, on stderr and in the report, and exit is 0" \
  || fail "convert_exceptions: unused: exit $(rc unused), $(err unused)"
for line in "*/layout.nib${TAB}unknown-key${TAB}DDNotAKey${TAB}another nib" "*/bad.nib${TAB}unknown-key${TAB}DDNotAKeyX${TAB}another key" \
            "*/bad.nib${TAB}class-missing${TAB}DDNotAKey${TAB}another kind"; do
  printf '%s\n' "$line" "$LC" > "$T/miss.ex"
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
  && grep -q '^Contents/Resources/Base.lproj/Main.storyboardc/DDFixtureScene.nib: finding: nibarchive-format NIBArchive (stays NIBArchive: .*) accepted as storyboard:NSStoryboard$' "$T/boardok" \
  && pass "convert_storyboard: with storyboard accepted, its encodable inner nib is converted, the unencodable one left, saying so, exit 0" \
  || fail "convert_storyboard: accepted: exit $(rc boardok), $(err boardok)"
[ "$(grep -c '"deviation":"storyboard:NSStoryboard"' "$T/boardok.json")" -ge 3 ] \
  && grep -q '"kind":"unresolved-chain","nib":"Contents/Resources/Base.lproj/Main.storyboardc/DDFixtureScene.nib",.*"deviation":"storyboard:NSStoryboard"' "$T/boardok.json" \
  && pass "convert_storyboard: the accepted storyboard covers its inner nibs' findings, marked as its deviation" \
  || fail "convert_storyboard: deviations: $(grep -c storyboard:NSStoryboard "$T/boardok.json")"

V=$(bundle variant)
mkdir -p "$V/v.nib"
cp "$FIX/nib-10.9/layout.nib/keyedobjects-101300.nib" "$V/v.nib/"
cp "$FIX/nib-10.9/layout.nib/keyedobjects-101300.nib" "$V/v.nib/keyedobjects-100900.nib"
convert variant --exceptions "$T/lc" --report "$T/variant.json" "$T/variant.app"
[ "$(rc variant)" = 0 ] && keyed "$V/v.nib/keyedobjects.nib" \
  && cmp -s "$FIX/nib-10.9/layout.nib/keyedobjects-101300.nib" "$V/v.nib/keyedobjects-101300.nib" \
  && grep -q '^Contents/Resources/v.nib/keyedobjects-101300.nib: will-adapt: no-floor-nib keyedobjects.nib (keyedobjects-101300.nib stands in for it)$' "$T/variant" \
  && pass "walker_variant_only: a nib directory with only variants gets keyedobjects.nib from the highest, reporting no-floor-nib" \
  || fail "walker_variant_only: exit $(rc variant), $(cat "$T/variant") $(err variant)"
"$R" dump "$V/v.nib/keyedobjects.nib" > "$T/v.rez" 2>&1 && grep -q "^  NSPreferredMaxLayoutWidth = f64 [^ ]*  # 1426$" "$T/v.rez" \
  && pass "walker_variant_only: the written keyedobjects.nib is the variant converted and adapted" \
  || fail "walker_variant_only: $(head -3 "$T/v.rez")"
grep -q "{\"path\":\"Contents/Resources/v.nib/keyedobjects.nib\",\"format\":\"nibarchive\",\"sha256_in\":\"$(sha "$V/v.nib/keyedobjects-101300.nib")\",\"sha256_out\":\"$(sha "$V/v.nib/keyedobjects.nib")\",\"written\":true}" "$T/variant.json" \
  && ! grep -q '"path":"Contents/Resources/v.nib/keyedobjects-101300.nib"' "$T/variant.json" \
  && grep -q '"kind":"adapted","nib":"Contents/Resources/v.nib/keyedobjects.nib","item":"wrapping-width"' "$T/variant.json" \
  && pass "walker_variant_only: the report names the keyedobjects.nib written, digesting the variant it came from" \
  || fail "walker_variant_only: report: $(grep -e '"path"' -e adapted "$T/variant.json" | head -3)"
rm "$V/v.nib/keyedobjects.nib" "$V/v.nib/keyedobjects-100900.nib"
convert unaccepted --report "$T/unaccepted.json" "$T/variant.app"
[ "$(rc unaccepted)" = 1 ] && [ ! -e "$V/v.nib/keyedobjects.nib" ] \
  && grep -q '{"path":"Contents/Resources/v.nib/keyedobjects-101300.nib","format":"nibarchive","sha256_in":"[0-9a-f]\{64\}","sha256_out":"[0-9a-f]\{64\}","written":false}' "$T/unaccepted.json" \
  && pass "walker_variant_only: a variant built but not written, the strict convert refusing, is named as itself" \
  || fail "walker_variant_only: unaccepted: exit $(rc unaccepted), $(grep '"path"' "$T/unaccepted.json")"
cp "$FIX/nib/Main.storyboardc/DDFixtureScene.nib" "$V/v.nib/keyedobjects-101300.nib"
convert held --no-strict --report "$T/held.json" "$T/variant.app"
[ "$(rc held)" = 1 ] && [ ! -e "$V/v.nib/keyedobjects.nib" ] && [ "$(ls "$V/v.nib")" = keyedobjects-101300.nib ] \
  && grep -q '^Contents/Resources/v.nib/keyedobjects-101300.nib: blocks-write: ' "$T/held" \
  && grep -q '"path":"Contents/Resources/v.nib/keyedobjects-101300.nib","format":"nibarchive","sha256_in":"[0-9a-f]\{64\}","sha256_out":null,"written":false' "$T/held.json" \
  && pass "convert_no_strict: a nib with a blocks-write finding is never built or written, even with --no-strict" \
  || fail "convert_no_strict: held: exit $(rc held), $(ls "$V/v.nib" | tr '\n' ' ') $(grep blocks-write "$T/held")"

A=$(bundle accepted)
cp "$FIX/nib/Main.storyboardc/DDFixtureScene.nib" "$A/scene.nib"
for k in NSChildControllerCreationSelectorName NSExternalObjectPlaceholderIdentifier NSExternalObjectsTableForViewLoading \
         NSStoryboardIdentifier connectionsRequireClassSwapperForStoryboardCompilation showSeguePresentationStyle \
         uniqueIdentifierForStoryboardCompilation; do
  printf '*/scene.nib\tunknown-key\t%s\tnot in this test\n' "$k"
done > "$T/scene.ex"
printf '*/scene.nib\tunresolved-chain\tNSNibExternalObjectPlaceholder\treviewed\n' >> "$T/scene.ex"
convert sceneex --exceptions "$T/scene.ex" --report "$T/sceneex.json" "$T/accepted.app"
[ "$(rc sceneex)" = 1 ] && cmp -s "$FIX/nib/Main.storyboardc/DDFixtureScene.nib" "$A/scene.nib" \
  && grep -q '^Contents/Resources/scene.nib: finding: nibarchive-format NIBArchive (stays NIBArchive: a blocks-write finding holds it back)$' "$T/sceneex" \
  && ! grep -q 'converts to a keyed archive' "$T/sceneex" \
  && grep -q '"kind":"nibarchive-format","nib":"Contents/Resources/scene.nib","item":"NIBArchive","detail":"stays NIBArchive: a blocks-write finding holds it back","severity":"finding","deviation":null' "$T/sceneex.json" \
  && pass "convert_accepted_block: an accepted blocks-write finding leaves the nib NIBArchive, which stdout and the report say, exit 1" \
  || fail "convert_accepted_block: exit $(rc sceneex), $(grep nibarchive-format "$T/sceneex") $(err sceneex)"
printf '*/scene.nib\tnibarchive-format\tNIBArchive\t10.9 never loads this nib\n' >> "$T/scene.ex"
convert sceneok --exceptions "$T/scene.ex" "$T/accepted.app"
[ "$(rc sceneok)" = 0 ] && cmp -s "$FIX/nib/Main.storyboardc/DDFixtureScene.nib" "$A/scene.nib" \
  && grep -q '^Contents/Resources/scene.nib: finding: nibarchive-format NIBArchive (stays NIBArchive: .*) accepted as nibarchive-format:NIBArchive$' "$T/sceneok" \
  && pass "convert_accepted_block: accepting that the nib stays NIBArchive too lets the strict convert exit 0" \
  || fail "convert_accepted_block: accepted: exit $(rc sceneok), $(grep nibarchive-format "$T/sceneok") $(err sceneok)"

N=$(bundle nonib)
mkdir -p "$N/old.nib"
cp "$FIX/nib/layout.nib" "$N/old.nib/designable.nib"
cp "$FIX/nib/layout.nib" "$N/Base.lproj/layout.nib"
convert nonib --exceptions "$T/lc" --report "$T/nonib.json" "$T/nonib.app"
[ "$(rc nonib)" = 1 ] && cmp -s "$FIX/nib/layout.nib" "$N/Base.lproj/layout.nib" \
  && [ "$(ls "$N/old.nib")" = designable.nib ] \
  && grep -q '^Contents/Resources/old.nib: finding: no-nib keyedobjects.nib (no keyedobjects.nib or keyedobjects-NNN.nib)$' "$T/nonib" \
  && grep -q '{"path":"Contents/Resources/old.nib","format":null,"sha256_in":null,"sha256_out":null,"written":false}' "$T/nonib.json" \
  && pass "walker_no_nib: a nib directory with no keyedobjects nib is a finding with a report entry, so nothing is written, exit 1" \
  || fail "walker_no_nib: exit $(rc nonib), $(grep old.nib "$T/nonib" "$T/nonib.json" | head -2) $(err nonib)"

P=$(bundle partial)
for d in a b c; do mkdir -p "$P/$d" && cp "$FIX/nib/layout.nib" "$P/$d/$d.nib"; done
if [ "$(id -u)" = 0 ]; then
  echo "SKIP: convert_partial_io: running as root, a read-only directory stops nothing"
else
  chmod a-w "$P/b"
  convert partial --exceptions "$T/lc" --report "$T/partial.json" "$T/partial.app"
  chmod u+w "$P/b"
  same=0; for d in a b c; do cmp -s "$FIX/nib/layout.nib" "$P/$d/$d.nib" && same=$((same + 1)); done
  left=0; for d in a b c; do left=$((left + $(ls -A "$P/$d" | wc -l))); done
  [ "$(rc partial)" = 4 ] && [ "$same" = 3 ] && [ "$left" = 3 ] \
    && pass "convert_partial_io: a nib that cannot be staged leaves all three byte-identical, no temp files, exit 4" \
    || fail "convert_partial_io: exit $(rc partial), $same unchanged, $left entries, $(err partial)"
  [ "$(grep -c '"written":false' "$T/partial.json")" = 3 ] && ! grep -q '"written":true' "$T/partial.json" \
    && pass "convert_partial_io: the report marks none as written" || fail "convert_partial_io: report: $(grep '"path"' "$T/partial.json")"
fi

cp "$FIX/nib/layout.nib" "$T/lone.nib"
convert lone --exceptions "$T/lc" --report "$T/lone.json" "$T/lone.nib"
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
