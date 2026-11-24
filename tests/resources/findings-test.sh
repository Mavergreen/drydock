#!/bin/sh
# platform: host-agnostic -- checks committed nibs, and edited dumps of them, against the committed reference data
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
R=$DRYDOCK_RESOURCES
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
T=$(mktemp -d "${TMPDIR:-/tmp}/findings-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
refs() { echo --references "$ROOT/reference/objc" --resource-references "$ROOT/reference/resources"; }
dump() { "$R" dump --references "$ROOT/reference/objc" "$1"; }
check() {  # OUT ARG...: drydock-resources check ARG... into $T/OUT, its exit status in $T/OUT.rc
  out=$1; shift
  "$R" check $(refs) "$@" > "$T/$out" 2>"$T/$out.err"; echo $? > "$T/$out.rc"
}
rc() { cat "$T/$1.rc"; }
lines() { grep -c "$2" "$T/$1"; }   # how many finding lines of $T/$1 match $2
# spec: an object's lines run from its "@N CLASS" line to the blank line after it.
in_obj() {  # N SED [FILE]: SED applied within object N
  n=$1 cmd=$2; shift 2
  sed "/^@$n /,/^\$/{
$cmd
}" "$@"
}
add_chain() {  # FILE LINE: FILE's dump with chain LINE added in order
  { sed -n 1,2p "$1"; { grep '^chain ' "$1"; echo "$2"; } | sort; sed -n '/^$/,$p' "$1"; }
}

dump "$FIX/nib/layout.nib" > "$T/layout.rez"
check plain --no-adapt "$FIX/nib/layout.nib"
[ "$(rc plain)" = 1 ] && [ "$(lines plain ': translate-autoresizing ')" = 0 ] \
  && pass "findings_layout: layout.nib's constrained views already carry NSDoNotTranslateAutoresizingMask = true" \
  || fail "findings_layout: unedited layout.nib: exit $(rc plain), $(grep translate "$T/plain" | head -2) $(cat "$T/plain.err")"
[ "$(lines plain '^[^ ]*layout.nib: finding: wrapping-width NSTextField (@21 NSPreferredMaxLayoutWidth absent, NSFrame width 1430)$')" = 1 ] \
  && [ "$(lines plain ': wrapping-width ')" = 1 ] \
  && pass "findings_layout: --no-adapt reports the wrapping label as a finding" \
  || fail "findings_layout: --no-adapt wrapping-width: $(grep wrapping "$T/plain")"
check adapting "$FIX/nib/layout.nib"
[ "$(lines adapting ': will-adapt: wrapping-width NSTextField (@21 ')" = 1 ] && [ "$(lines adapting ': finding: wrapping-width')" = 0 ] \
  && pass "findings_layout: with adaptation on, the wrapping label will adapt" \
  || fail "findings_layout: adapting: $(grep wrapping "$T/adapting")"
[ "$(lines adapting ': will-adapt: nibarchive-format NIBArchive (')" = 1 ] && [ "$(lines plain ': will-adapt: nibarchive-format ')" = 1 ] \
  && pass "findings_layout: a NIBArchive nib will be converted, with or without --no-adapt" \
  || fail "findings_layout: nibarchive-format: $(grep nibarchive "$T/adapting" "$T/plain")"
check apple "$FIX/nib-10.9/layout.nib"
[ "$(lines apple 'nibarchive-format')" = 0 ] && [ "$(lines apple ': will-adapt: wrapping-width NSTextField (@22 ')" = 1 ] \
  && pass "findings_layout: Apple's 10.9 compile is no NIBArchive, and its wrapping label has no preferred width either" \
  || fail "findings_layout: Apple's 10.9 layout.nib: exit $(rc apple), $(head -3 "$T/apple") $(cat "$T/apple.err")"

# spec: views 17, 21, 37 and 45 say false, 50 has no key; 15 (the window's content view) and 19 (the box's) are items too.
in_obj 17 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' "$T/layout.rez" \
  | in_obj 21 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' \
  | in_obj 37 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' \
  | in_obj 45 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' \
  | in_obj 50 '/^  NSDoNotTranslateAutoresizingMask = true$/d' > "$T/untranslated.rez"
check off --no-adapt "$T/untranslated.rez"
grep ': translate-autoresizing ' "$T/off" | sed 's/.*: \(finding\): translate-autoresizing \([^ ]*\) (\(@[0-9]*\) NSDoNotTranslateAutoresizingMask \([a-z]*\))$/\1 \2 \3 \4/' > "$T/off.ta"
printf '%s\n' 'finding NSBox @17 false' 'finding NSTextField @21 false' 'finding NSButton @37 false' \
  'finding NSButton @45 false' 'finding NSButton @50 absent' > "$T/want.ta"
cmp -s "$T/off.ta" "$T/want.ta" \
  && pass "findings_layout: --no-adapt reports every constrained view whose key is false or absent, and no content view" \
  || fail "findings_layout: translate-autoresizing: $(diff "$T/want.ta" "$T/off.ta" | tr '\n' '|') $(cat "$T/off.err")"
check on "$T/untranslated.rez"
[ "$(lines on ': will-adapt: translate-autoresizing ')" = 5 ] && [ "$(lines on ': finding: translate-autoresizing ')" = 0 ] \
  && pass "findings_layout: with adaptation on, the same five will adapt" \
  || fail "findings_layout: adapting translate-autoresizing: $(grep translate "$T/on" | head -3)"
check one --no-adapt=wrapping-width "$T/untranslated.rez"
[ "$(lines one ': will-adapt: translate-autoresizing ')" = 5 ] && [ "$(lines one ': finding: wrapping-width ')" = 1 ] \
  && pass "findings_layout: --no-adapt=wrapping-width turns only that rule into a finding" \
  || fail "findings_layout: --no-adapt=wrapping-width: $(grep -e translate -e wrapping "$T/one" | head -3)"

dump "$FIX/nib/values.nib" | in_obj 14 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' > "$T/swapper.rez"
check swapper "$T/swapper.rez"
[ "$(lines swapper ': will-adapt: translate-autoresizing NSView (@14 NSDoNotTranslateAutoresizingMask false)$')" = 1 ] \
  && pass "findings_layout: a custom view (an NSClassSwapper for NSView) is judged as its original class" \
  || fail "findings_layout: swapper: $(grep translate "$T/swapper") $(cat "$T/swapper.err")"
[ "$(lines swapper ': unknown-key NSNibTouchBar (NSView ')" = 1 ] && [ "$(lines swapper ': unknown-key NSNibTouchBar (NSView @12)$')" = 1 ] \
  && pass "findings_unknown_key: a key is reported once per class, at its first object, the swapper's under its original class" \
  || fail "findings_unknown_key: per class: $(grep NSNibTouchBar "$T/swapper")"

check color "$FIX/nib/layout.nib"
[ "$(lines color ': finding: named-color-missing labelColor (10.10)$')" = 1 ] \
  && pass "findings_color: layout.nib's System labelColor is missing on 10.9, since 10.10" \
  || fail "findings_color: layout.nib: $(grep color "$T/color")"
in_obj 30 's/^  NS.bytes = data "textBackgroundColor"$/  NS.bytes = data "labelColor"/' "$T/layout.rez" \
  | in_obj 35 's/^  NS.bytes = data "labelColor"$/  NS.bytes = data "controlTextColor"/' > "$T/swapped.rez"
check swapped "$T/swapped.rez"
[ "$(lines swapped 'named-color-missing')" = 1 ] && [ "$(lines swapped ': finding: named-color-missing labelColor (10.10)$')" = 1 ] \
  && pass "findings_color: a colour 10.9 has (controlTextColor) is no finding, the one it lacks is" \
  || fail "findings_color: swapped: $(grep color "$T/swapped")"
in_obj 35 's/^  NS.bytes = data "labelColor"$/  NS.bytes = data "DDNotAColor"/' "$T/layout.rez" > "$T/invented.rez"
check invented "$T/invented.rez"
[ "$(lines invented ': finding: named-color-missing DDNotAColor (?)$')" = 1 ] \
  && pass "findings_color: a colour name no SDK declares is missing, version unknown" \
  || fail "findings_color: invented: $(grep color "$T/invented")"
in_obj 34 's/^  NSCatalogName = ref @29$/  NSCatalogName = ref @35/' "$T/layout.rez" > "$T/catalog.rez"
check catalog "$T/catalog.rez"
[ "$(lines catalog 'named-color-missing')" = 0 ] \
  && pass "findings_color: a colour outside the System catalog is no named-color finding" \
  || fail "findings_color: catalog: $(grep color "$T/catalog")"
dump "$FIX/nib-10.9/layout.nib" > "$T/keyed.rez"
num=$(sed -n 's/^  NSColorName = ref @\([0-9]*\)$/\1/p' "$T/keyed.rez" | head -1)
sed "s/^  NSColorName = ref @$num\$/  NSColorName = string \"labelColor\"/" "$T/keyed.rez" > "$T/direct.rez"
grep -q '^  NSColorName = string "labelColor"$' "$T/direct.rez" || fail "findings_color: the direct string edit did not apply"
check direct "$T/direct.rez"
[ "$(lines direct ': finding: named-color-missing labelColor (10.10)$')" = 1 ] \
  && pass "findings_color: NSColorName = string \"labelColor\" with NSCatalogName \"System\" is missing since 10.10" \
  || fail "findings_color: direct string: exit $(rc direct), $(grep color "$T/direct") $(cat "$T/direct.err")"

in_obj 21 's/^  NSEnabled = true$/  NSEnabled = true\
  DDNotAKey = i8 1/' "$T/layout.rez" > "$T/unknown.rez"
check unknown "$T/unknown.rez"
[ "$(lines unknown ': finding: unknown-key DDNotAKey (NSTextField @21)$')" = 1 ] \
  && pass "findings_unknown_key: a key 10.9 is not known to read is a finding" \
  || fail "findings_unknown_key: DDNotAKey: $(grep DDNot "$T/unknown") $(cat "$T/unknown.err")"
[ "$(lines unknown 'unknown-key IBNSClipsToBounds ')" = 0 ] && [ "$(lines unknown 'unknown-key UINibEncoderEmptyKey ')" = 0 ] \
  && [ "$(lines unknown 'unknown-key NSControlUsesSingleLineMode ')" = 0 ] && [ "$(lines unknown 'unknown-key NSFrame ')" = 0 ] \
  && pass "findings_unknown_key: ignored keys (IBNSClipsToBounds, UINibEncoderEmptyKey, NSControlUsesSingleLineMode) and read keys report nothing" \
  || fail "findings_unknown_key: $(grep -e IBNS -e UINib -e SingleLine -e NSFrame "$T/unknown" | head -3)"
[ "$(lines unknown ': finding: unknown-key NSAllowsWritingTools (NSTextField @21)$')" = 1 ] \
  && pass "findings_unknown_key: a key from after 10.9 (NSAllowsWritingTools) is a finding" \
  || fail "findings_unknown_key: NSAllowsWritingTools: $(grep WritingTools "$T/unknown")"
add_chain "$T/unknown.rez" 'chain NSSecureTextField : NSTextField : NSControl : NSView : NSResponder : NSObject' \
  | sed 's/^@21 NSTextField$/@21 NSSecureTextField/' > "$T/sub.rez"
check sub "$T/sub.rez"
[ "$(lines sub ': unknown-key DDNotAKey (NSSecureTextField @21)$')" = 1 ] && [ "$(lines sub ': unknown-key .* (NSSecureTextField @21)$')" = "$(lines unknown ': unknown-key .* (NSTextField @21)$')" ] \
  && pass "findings_unknown_key: a subclass is known to read what its superclasses read" \
  || fail "findings_unknown_key: subclass: exit $(rc sub), $(grep NSSecure "$T/sub" | head -3) $(cat "$T/sub.err")"

check board "$FIX/nib/Main.storyboardc"
[ "$(rc board)" = 1 ] && [ "$(lines board '^[^ ]*Main.storyboardc: finding: storyboard NSStoryboard (10.10)$')" = 1 ] \
  && pass "findings_storyboard: a .storyboardc on 10.9, which has no NSStoryboard, is a finding" \
  || fail "findings_storyboard: exit $(rc board), $(head -3 "$T/board") $(cat "$T/board.err")"
[ "$(lines board 'Main.storyboardc/DDFixtureScene.nib: blocks-write: unresolved-chain NSNibExternalObjectPlaceholder (')" = 1 ] \
  && [ "$(lines board 'unencodable')" = 0 ] && [ "$(lines board 'Main.storyboardc/Svc-aa-001-view-Svw-aa-003.nib: ')" -ge 1 ] \
  && pass "findings_storyboard: its inner nibs are checked too, and an unresolved chain is no second unencodable finding" \
  || fail "findings_storyboard: inner nibs: $(grep -e unresolved -e unencodable "$T/board" | head -3)"

add_chain "$T/layout.rez" 'chain NSGridView : NSView : NSResponder : NSObject newer 10.12' \
  | sed 's/^@19 NSView$/@19 NSGridView/' > "$T/grid.rez"
check grid "$T/grid.rez"
[ "$(lines grid ': finding: class-missing NSGridView (10.12)$')" = 1 ] \
  && pass "findings_class: a class newer than the target is missing, with its version" \
  || fail "findings_class: exit $(rc grid), $(grep -e Grid "$T/grid" | head -2) $(cat "$T/grid.err")"
dump "$FIX/nib/collections.nib" | grep -v '^  UINibEncoderEmptyKey = ref @64$' > "$T/odd.rez"
check odd "$T/odd.rez"
[ "$(rc odd)" = 1 ] && [ "$(lines odd ': blocks-write: unencodable keyed-archive (@35 NSMutableDictionary has an odd number (37) of UINibEncoderEmptyKey values)$')" = 1 ] \
  && pass "findings_unencodable: what the keyed writer refuses blocks the write" \
  || fail "findings_unencodable: exit $(rc odd), $(grep unencodable "$T/odd") $(cat "$T/odd.err")"

in_obj 21 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false\
  DDNotAKey = i8 1/' "$T/layout.rez" > "$T/all.rez"
check all --no-adapt "$T/all.rez"
n=0
for k in translate-autoresizing wrapping-width named-color-missing unknown-key; do
  [ "$(lines all ": finding: $k ")" -ge 1 ] && n=$((n + 1))
done
[ "$n" = 4 ] && [ "$(rc all)" = 1 ] \
  && pass "findings_exhaustive: one nib with four problems reports all four" \
  || fail "findings_exhaustive: $n of 4 kinds, exit $(rc all): $(cut -d: -f3 "$T/all" | sort -u | tr '\n' '|')"

check clean --no-adapt "$FIX/nib/int64.nib"
want=0; grep -q -e ': finding: ' -e ': blocks-write: ' "$T/clean" && want=1
[ "$(rc clean)" = "$want" ] && [ "$want" = 1 ] \
  && pass "findings_exit: exit 1 when there is a finding" || fail "findings_exit: int64.nib: exit $(rc clean), wanted $want"
sed -n 's/.*: finding: unknown-key \([^ ]*\) .*/  \1 = /p' "$T/color" | sort -u > "$T/unknown.keys"
grep -v -F -f "$T/unknown.keys" "$T/layout.rez" | in_obj 35 's/"labelColor"/"controlTextColor"/' > "$T/willonly.rez"
check willonly "$T/willonly.rez"
[ "$(rc willonly)" = 0 ] && [ "$(lines willonly ': will-adapt: ')" -ge 2 ] && [ "$(lines willonly ': finding: ')" = 0 ] \
  && pass "findings_exit: only will-adapt findings exit 0" \
  || fail "findings_exit: will-adapt only: exit $(rc willonly), $(grep -v will-adapt "$T/willonly" | head -3) $(cat "$T/willonly.err")"
check missing "$T/none.nib"
[ "$(rc missing)" = 4 ] && pass "findings_exit: a nib that cannot be read exits 4" || fail "findings_exit: missing nib exit $(rc missing)"
"$R" check --references "$ROOT/reference/objc" --resource-references "$T/none" "$FIX/nib/layout.nib" > "$T/out" 2>"$T/err"; r=$?
[ "$r" = 4 ] && grep -q "cannot read the resource references in $T/none" "$T/err" && [ ! -s "$T/out" ] \
  && pass "findings_exit: unreadable resource references exit 4" || fail "findings_exit: resource references: exit $r, $(cat "$T/err")"

mkdir -p "$T/badkeys" && cp "$ROOT/reference/resources/adapt.tsv" "$T/badkeys/"
for row in 'NSView	NSFrame	maybe	AppKit:s1' 'NSView	NSFrame	read' 'NSView		read	AppKit:s1'; do
  { cat "$ROOT/reference/resources/keys-10.9.tsv"; printf '%s\n' "$row"; } > "$T/badkeys/keys-10.9.tsv"
  "$R" check --references "$ROOT/reference/objc" --resource-references "$T/badkeys" "$FIX/nib/layout.nib" > "$T/out" 2>"$T/err"; r=$?
  [ "$r" = 4 ] && [ ! -s "$T/out" ] && pass "findings_exit: a malformed keys-10.9.tsv row exits 4 ($(printf '%s' "$row" | tr '\t' ' '))" \
    || fail "findings_exit: malformed keys row: exit $r: $(printf '%s' "$row" | tr '\t' ' ')"
done
KEYS=$ROOT/reference/resources/keys-10.9.tsv
grep -q '^NSView	NSDoNotTranslateAutoresizingMask	read	' "$KEYS" && grep -q '^NSTextField	NSPreferredMaxLayoutWidth	read	' "$KEYS" \
  && pass "keys_table: NSDoNotTranslateAutoresizingMask and NSPreferredMaxLayoutWidth are read" || fail "keys_table: a positive control is not read"
bad=$(grep -v '^#' "$KEYS" | awk -F '\t' 'NF != 4 || ($3 != "read" && $3 != "ignored") || $4 !~ /:s[0-9]/' | head -1)
[ -z "$bad" ] && pass "keys_table: every row is CLASS KEY read|ignored REASON:SEEDS" || fail "keys_table: malformed row: $bad"
read_absent=$(grep -v '^#' "$KEYS" | awk -F '\t' '$3 == "read"' | cut -f2 | grep -x -e 'IB.*' -e UINibEncoderEmptyKey -e NSInlinedValue \
  -e NSConstantV2 -e NSFirstAttributeV2 -e NSSecondAttributeV2 -e NSControlSize -e NSControlContinuous -e NSControlRefusesFirstResponder -e NSControlUsesSingleLineMode \
  -e NSControlTextAlignment -e NSControlLineBreakMode -e NSControlWritingDirection -e NSControlSendActionMask -e NSControlBorderShape -e NSAllowsWritingTools \
  -e NSTextFieldAllowsWritingToolsAffordance -e NS.resolvesNaturalAlignmentWithBaseWritingDirection -e NSNibTouchBar -e NSWindowSubtitle \
  -e 'NS[MinMax]*FullScreenContentSize' -e NSImageViewPlaceholderPrecedence -e NSImageAnimation -e NSLinearExposure \
  -e NSProgressIndicatorDoubleValue -e NSAuxButtonType -e NSChildControllerCreationSelectorName | grep -v -x -e IB.objectdata | sort -u)
[ -z "$read_absent" ] && pass "keys_table: no key 10.9's frameworks lack is marked read" || fail "keys_table: marked read: $read_absent"
[ "$(grep -c '^# seed s[0-9]* [^ ]* sha256 [0-9a-f]\{64\}$' "$KEYS")" -ge 1 ] \
  && pass "keys_table: the header records each seed with its sha256" || fail "keys_table: no seed lines in the header"
DRYDOCK_RESOURCES_KEYS_TEST_HOST_VERSION=10.15.7 sh "$ROOT/scripts/resources-keys.sh" x=y > "$T/out" 2>"$T/err"; r=$?
[ "$r" = 1 ] && grep -q "needs OS X 10.9's frameworks, and this host is 10.15.7" "$T/err" && [ ! -s "$T/out" ] \
  && pass "keys_script: resources-keys.sh refuses a host that is not OS X 10.9" || fail "keys_script: 10.15.7: exit $r, $(cat "$T/err")"
DRYDOCK_RESOURCES_KEYS_TEST_HOST_VERSION=10.9.5 sh "$ROOT/scripts/resources-keys.sh" > "$T/out" 2>"$T/err"; r=$?
[ "$r" = 2 ] && grep -q '^usage: resources-keys.sh LABEL=NIB' "$T/err" \
  && pass "keys_script: on 10.9.5 it gets past the host check to its usage" || fail "keys_script: 10.9.5: exit $r, $(cat "$T/err")"

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
