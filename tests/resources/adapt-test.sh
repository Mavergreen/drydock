#!/bin/sh
# platform: host-agnostic -- builds edited dumps of committed nibs with the adaptation rules, and reads the results back
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
R=$DRYDOCK_RESOURCES
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
RES=$ROOT/reference/resources
T=$(mktemp -d "${TMPDIR:-/tmp}/adapt-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
dump() { "$R" dump --references "$ROOT/reference/objc" "$1"; }
in_obj() {  # N SED [FILE]: SED applied within object N
  n=$1 cmd=$2; shift 2
  sed "/^@$n /,/^\$/{
$cmd
}" "$@"
}
build() {  # NAME TEXT ARG...: builds TEXT to $T/NAME.nib and dumps it to $T/NAME.out; exit status in $T/NAME.rc
  name=$1 text=$2; shift 2
  "$R" build "$@" "$text" -o "$T/$name.nib" > "$T/$name.log" 2>"$T/$name.err"; echo $? > "$T/$name.rc"
  : > "$T/$name.out"
  [ -f "$T/$name.nib" ] && dump "$T/$name.nib" > "$T/$name.out"
}
rc() { cat "$T/$1.rc"; }
err() { head -3 "$T/$1.err"; }
# spec: one line per view a constraint names: "CLASS STATE", STATE the view's NSDoNotTranslateAutoresizingMask (or
#   "absent"), prefixed "content:" for a window's or a box's content view.
views() {
  awk '
    /^@[0-9]+ / { o = $1; cls[o] = $2; next }
    $1 == "NSFirstItem" || $1 == "NSSecondItem" { item[$4] = 1 }
    $1 == "NSWindowView" || $1 == "NSContentView" { content[$4] = 1 }
    $1 == "NSDoNotTranslateAutoresizingMask" { dnt[o] = $3 }
    END { for (v in item) print cls[v], ((v in content) ? "content:" : "") ((v in dnt) ? dnt[v] : "absent") }' "$1" | sort
}
label() {  # the NSTextField's NSPreferredMaxLayoutWidth line, and its NSFrame's width minus 4
  awk '
    /^@[0-9]+ / { o = $1; cls[o] = $2; next }
    $1 == "NSPreferredMaxLayoutWidth" && cls[o] == "NSTextField" { pw = $0 }
    $1 == "NSFrame" && cls[o] == "NSTextField" { fr = $4 }
    $1 == "NS.bytes" { s[o] = $0 }
    END { split(s[fr], a, ", "); w = a[3]; sub(/^\{/, "", w); print pw "|" (w - 4) }' "$1"
}

dump "$FIX/nib/layout.nib" > "$T/layout.rez"
in_obj 17 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' "$T/layout.rez" \
  | in_obj 21 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' \
  | in_obj 50 '/^  NSDoNotTranslateAutoresizingMask = true$/d' \
  | in_obj 15 's/^  NSvFlags = i16 256$/  NSvFlags = i16 256\
  NSDoNotTranslateAutoresizingMask = false/' \
  | in_obj 19 's/^  NSvFlags = i16 274$/  NSvFlags = i16 274\
  NSDoNotTranslateAutoresizingMask = false/' > "$T/untranslated.rez"
build plain "$T/untranslated.rez" --no-adapt
printf '%s\n' 'NSBox false' 'NSButton absent' 'NSButton true' 'NSButton true' 'NSTextField false' 'NSView content:false' 'NSView content:false' > "$T/want.before"
views "$T/plain.out" > "$T/got.before"
cmp -s "$T/want.before" "$T/got.before" && pass "adapt_layout: --no-adapt keeps the edited views false and absent, both content views false" \
  || fail "adapt_layout: --no-adapt: exit $(rc plain), $(err plain) $(diff "$T/want.before" "$T/got.before" | tr '\n' '|')"
[ ! -s "$T/plain.log" ] && [ "$(label "$T/plain.out")" = "|1426" ] \
  && pass "adapt_layout: --no-adapt logs nothing and leaves the label without a preferred width" \
  || fail "adapt_layout: --no-adapt: log $(head -2 "$T/plain.log"), label $(label "$T/plain.out")"

build on "$T/untranslated.rez" --resource-references "$RES"
printf '%s\n' 'NSBox true' 'NSButton absent' 'NSButton true' 'NSButton true' 'NSTextField true' 'NSView content:false' 'NSView content:false' > "$T/want.after"
views "$T/on.out" > "$T/got.after"
[ "$(rc on)" = 0 ] && cmp -s "$T/want.after" "$T/got.after" \
  && pass "adapt_layout: build turns NSDoNotTranslateAutoresizingMask false into true on constrained views, leaves true and absent alone, and no content view" \
  || fail "adapt_layout: translate-autoresizing: exit $(rc on), $(err on) $(diff "$T/want.after" "$T/got.after" | tr '\n' '|')"
[ "$(grep -c '^NSView content:false$' "$T/got.after")" = 2 ] && [ "$(grep -c '^NSButton absent$' "$T/got.after")" = 1 ] \
  && pass "adapt_layout: the window's and the box's content views stay false, and an absent key stays absent" \
  || fail "adapt_layout: content views or absent key changed: $(tr '\n' '|' < "$T/got.after")"
[ "$(label "$T/on.out")" = "  NSPreferredMaxLayoutWidth = f64 0x1.648p+10  # 1426|1426" ] \
  && pass "adapt_layout: the wrapping label gets NSPreferredMaxLayoutWidth = f64 its NSFrame width - 4" \
  || fail "adapt_layout: wrapping-width: $(label "$T/on.out")"
printf '%s\n' "$T/untranslated.rez: adapted: translate-autoresizing (@17 NSDoNotTranslateAutoresizingMask)" \
  "$T/untranslated.rez: adapted: translate-autoresizing (@21 NSDoNotTranslateAutoresizingMask)" \
  "$T/untranslated.rez: adapted: wrapping-width (@21 NSPreferredMaxLayoutWidth)" > "$T/want.log"
cmp -s "$T/want.log" "$T/on.log" && pass "adapt_layout: every rewrite is logged in object order, rule and object and key" \
  || fail "adapt_layout: log: $(diff "$T/want.log" "$T/on.log" | tr '\n' '|')"
build again "$T/untranslated.rez" --resource-references "$RES"
cmp -s "$T/on.nib" "$T/again.nib" && pass "adapt_layout: an adapted build is the same bytes every time" || fail "adapt_layout: adapted builds differ"

build nowrap "$T/untranslated.rez" --resource-references "$RES" --no-adapt=wrapping-width
views "$T/nowrap.out" > "$T/got.nowrap"
[ "$(rc nowrap)" = 0 ] && [ "$(label "$T/nowrap.out")" = "|1426" ] && cmp -s "$T/want.after" "$T/got.nowrap" \
  && pass "adapt_layout: --no-adapt=wrapping-width leaves the label alone and still translates" \
  || fail "adapt_layout: --no-adapt=wrapping-width: exit $(rc nowrap), label $(label "$T/nowrap.out"), $(diff "$T/want.after" "$T/got.nowrap" | tr '\n' '|')"
build notrans "$T/untranslated.rez" --resource-references "$RES" --no-adapt=translate-autoresizing
views "$T/notrans.out" > "$T/got.notrans"
[ "$(rc notrans)" = 0 ] && cmp -s "$T/want.before" "$T/got.notrans" && [ "$(label "$T/notrans.out")" = "  NSPreferredMaxLayoutWidth = f64 0x1.648p+10  # 1426|1426" ] \
  && pass "adapt_layout: --no-adapt=translate-autoresizing leaves the views alone and still sets the width" \
  || fail "adapt_layout: --no-adapt=translate-autoresizing: exit $(rc notrans), $(diff "$T/want.before" "$T/got.notrans" | tr '\n' '|')"
build bogus "$T/untranslated.rez" --resource-references "$RES" --no-adapt=bogus
[ "$(rc bogus)" = 2 ] && [ ! -e "$T/bogus.nib" ] && grep -q 'unknown adaptation rule: bogus' "$T/bogus.err" \
  && pass "adapt_layout: --no-adapt=bogus exits 2 and writes nothing" || fail "adapt_layout: --no-adapt=bogus: exit $(rc bogus), $(err bogus)"
mkdir -p "$T/bare" && cp "$R" "$T/bare/drydock-resources" && installed=$R && R=$T/bare/drydock-resources
build norefs "$T/untranslated.rez"
R=$installed
[ "$(rc norefs)" = 4 ] && [ ! -e "$T/norefs.nib" ] && grep -q 'resource references' "$T/norefs.err" \
  && pass "adapt_layout: with no resource references to judge by, an adapting build exits 4 and writes nothing" \
  || fail "adapt_layout: no references: exit $(rc norefs), $(err norefs)"

mkdir -p "$T/prefix/bin" "$T/prefix/share/drydock/resources" && cp "$R" "$T/prefix/bin/drydock-resources" \
  && ln -s "$RES" "$T/prefix/share/drydock/resources/reference"
"$T/prefix/bin/drydock-resources" build "$T/untranslated.rez" -o "$T/beside.nib" > /dev/null 2>"$T/err" && cmp -s "$T/beside.nib" "$T/on.nib" \
  && pass "adapt_layout: the resource references at ../../share/drydock/resources/reference are found" \
  || fail "adapt_layout: references beside the binary: $(cat "$T/err")"

flags() {  # NAME CELLFLAGS CELLFLAGS2: the label's cell flags edited, then built with adaptation
  in_obj 24 "s/^  NSCellFlags = i32 69206017\$/  NSCellFlags = i32 $2/" "$T/layout.rez" \
    | in_obj 24 "s/^  NSCellFlags2 = i32 268435456\$/  NSCellFlags2 = i32 $3/" > "$T/$1.rez"
  build "$1" "$T/$1.rez" --resource-references "$RES"
}
flags wraps 69206017 268435456       # 0x04200001, 10.9 wraps it
flags scrolls 68157504 268435456     # 0x04100040, a scrolling field: clips
flags tail 67108864 268437504        # NSCellFlags2 line break mode 4: truncates
flags charwrap 67108928 268435968    # 0x04000040 says clip, NSCellFlags2's mode 1 says character wrap, and wins
[ "$(label "$T/wraps.out")" != "|1426" ] && [ "$(label "$T/scrolls.out")" = "|1426" ] && [ "$(label "$T/tail.out")" = "|1426" ] \
  && [ "$(label "$T/charwrap.out")" != "|1426" ] \
  && pass "adapt_layout: wrapping is read from the cell flags as 10.9 reads it" \
  || fail "adapt_layout: cell flags: wraps $(label "$T/wraps.out"), scrolls $(label "$T/scrolls.out"), tail $(label "$T/tail.out"), charwrap $(label "$T/charwrap.out")"

in_obj 21 's/^  NSEnabled = true$/  NSEnabled = true\
  NSPreferredMaxLayoutWidth = f64 0x1.9p+6/' "$T/layout.rez" > "$T/set.rez"
build set "$T/set.rez" --resource-references "$RES"
in_obj 21 's/^  NSEnabled = true$/  NSEnabled = true\
  NSPreferredMaxLayoutWidth = i8 0/' "$T/layout.rez" > "$T/zero.rez"
build zero "$T/zero.rez" --resource-references "$RES"
[ "$(label "$T/set.out")" = "  NSPreferredMaxLayoutWidth = f64 0x1.9p+6  # 100|1426" ] \
  && [ "$(label "$T/zero.out")" = "  NSPreferredMaxLayoutWidth = f64 0x1.648p+10  # 1426|1426" ] \
  && [ "$(grep -c NSPreferredMaxLayoutWidth "$T/zero.out")" = 1 ] \
  && pass "adapt_layout: a preferred width already set is kept, and a zero one is replaced" \
  || fail "adapt_layout: set $(label "$T/set.out"), zero $(label "$T/zero.out")"
in_obj 22 's/^  NS.bytes = data "{{14, 128}, {1430, 16}}"$/  NS.bytes = data "{1430, 16}"/' "$T/layout.rez" \
  | in_obj 21 's/^  NSFrame = ref @22$/  NSFrameSize = ref @22/' > "$T/size.rez"
build size "$T/size.rez" --resource-references "$RES"
grep -q '^  NSPreferredMaxLayoutWidth = f64 0x1.648p+10  # 1426$' "$T/size.out" \
  && pass "adapt_layout: a label with only an NSFrameSize gets its width - 4 too" || fail "adapt_layout: NSFrameSize: exit $(rc size), $(err size)"
for bad in '{{14, 128}, {wide, 16}}' '{{14, 128}, {1430}}' '{{14, 128}, {4, 16}}' '{{14, 128}, {0x10, 16}}'; do
  in_obj 22 "s/^  NS.bytes = data \"{{14, 128}, {1430, 16}}\"\$/  NS.bytes = data \"$bad\"/" "$T/layout.rez" > "$T/bad.rez"
  build bad "$T/bad.rez" --resource-references "$RES"
  [ "$(rc bad)" = 1 ] && [ ! -e "$T/bad.nib" ] && grep -q ': finding: wrapping-width NSTextField (@21 ' "$T/bad.log" \
    && pass "adapt_layout: an unusable frame \"$bad\" is a finding, not a guess, and nothing is written" \
    || fail "adapt_layout: frame \"$bad\": exit $(rc bad), $(head -2 "$T/bad.log") $(err bad)"
done
build badoff "$T/bad.rez" --resource-references "$RES" --no-adapt=wrapping-width
[ "$(rc badoff)" = 0 ] && pass "adapt_layout: --no-adapt=wrapping-width builds past an unusable frame" || fail "adapt_layout: badoff exit $(rc badoff)"

mkdir -p "$T/res"
printf '# test\ntranslate-autoresizing\t10.10\tt\nwrapping-width\t10.9\tt\n' > "$T/res/adapt.tsv"
build target "$T/untranslated.rez" --resource-references "$T/res"
views "$T/target.out" > "$T/got.target"
[ "$(rc target)" = 0 ] && [ "$(label "$T/target.out")" = "|1426" ] && cmp -s "$T/want.after" "$T/got.target" \
  && pass "adapt_target_data: with wrapping-width applying below 10.9, it does not apply to target 10.9" \
  || fail "adapt_target_data: exit $(rc target), $(err target), label $(label "$T/target.out")"
printf 'translate-autoresizing\t10.9\tt\nwrapping-width\t10.9.1\tt\n' > "$T/res/adapt.tsv"
build target2 "$T/untranslated.rez" --resource-references "$T/res"
views "$T/target2.out" > "$T/got.target2"
[ "$(rc target2)" = 0 ] && [ "$(label "$T/target2.out")" != "|1426" ] && cmp -s "$T/want.before" "$T/got.target2" \
  && pass "adapt_target_data: 10.9 is below 10.9.1 and not below 10.9" \
  || fail "adapt_target_data: exit $(rc target2), $(err target2), label $(label "$T/target2.out")"
for table in 'wrapping-width	10.11	t' 'translate-autoresizing	10.10	t
wrapping-width	10.11	t
frobnicate	10.11	t' 'translate-autoresizing	10.10
wrapping-width	10.11	t' 'translate-autoresizing	ten	t
wrapping-width	10.11	t' 'translate-autoresizing	10.10	t
translate-autoresizing	10.10	t
wrapping-width	10.11	t'; do
  printf '%s\n' "$table" > "$T/res/adapt.tsv"
  build broken "$T/untranslated.rez" --resource-references "$T/res"
  [ "$(rc broken)" = 4 ] && [ ! -e "$T/broken.nib" ] \
    && pass "adapt_target_data: a malformed adapt.tsv exits 4 ($(printf '%s' "$table" | tr '\t\n' ' |'))" \
    || fail "adapt_target_data: malformed adapt.tsv exit $(rc broken): $(printf '%s' "$table" | tr '\t\n' ' |')"
done

dump "$FIX/nib-10.9/layout.nib/keyedobjects-101300.nib" > "$T/same.rez"
build ours "$T/same.rez" --resource-references "$RES"
dump "$FIX/nib-10.9/layout.nib/keyedobjects.nib" > "$T/apple.out"
views "$T/apple.out" > "$T/apple.views"
views "$T/ours.out" > "$T/ours.views"
[ "$(rc ours)" = 0 ] && cmp -s "$T/apple.views" "$T/ours.views" && ! grep -q translate "$T/ours.log" \
  && pass "adapt_oracle: our adapted build of Apple's 10.9 compile translates exactly the views Apple's keyed nib does" \
  || fail "adapt_oracle: views: exit $(rc ours), $(diff "$T/apple.views" "$T/ours.views" | tr '\n' '|')"
[ "$(label "$T/apple.out")" = "|1426" ] && [ "$(label "$T/ours.out")" = "  NSPreferredMaxLayoutWidth = f64 0x1.648p+10  # 1426|1426" ] \
  && pass "adapt_oracle: Apple's 10.9 compile leaves the wrapping label at preferred width 0, which 10.9 measures as one line; ours sets 1426" \
  || fail "adapt_oracle: label: Apple $(label "$T/apple.out"), ours $(label "$T/ours.out")"

build keyed "$T/apple.out" --resource-references "$RES"
[ "$(rc keyed)" = 0 ] && [ "$(label "$T/keyed.out")" = "  NSPreferredMaxLayoutWidth = f64 0x1.648p+10  # 1426|1426" ] \
  && pass "adapt_layout: a keyed nib's dump adapts too" || fail "adapt_layout: keyed input: exit $(rc keyed), $(err keyed), $(label "$T/keyed.out")"

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
