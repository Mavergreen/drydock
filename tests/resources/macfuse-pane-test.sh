#!/bin/sh
# platform: macOS-only -- a maintainer test: macFUSE's compiled preference pane nib, which is not committed, is read from
#   DRYDOCK_RESOURCES_MACFUSE_NIB; it SKIPs (77) when that is unset or names no file. On 10.9 it also instantiates the converted
#   nib with AppKit, compiled at test time with clang22 against the pinned 10.9 SDK, and SKIPs (77) there, its earlier
#   checks passing, when clang22 cannot build against AppKit.
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
R=$DRYDOCK_RESOURCES
NIB=${DRYDOCK_RESOURCES_MACFUSE_NIB:-}
[ -n "$NIB" ] || {
  echo "SKIP: resources_macfuse_pane: set DRYDOCK_RESOURCES_MACFUSE_NIB (environment or CMake cache) to the NIBArchive nib of the macFUSE pane"
  exit 77; }
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
EXC=$ROOT/tests/resources/macfuse-pane.exceptions
[ -f "$NIB" ] || { echo "SKIP: resources_macfuse_pane: no macFUSE pane nib at $NIB"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/tmp}/macfuse-pane-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
refs() { echo --references "$ROOT/reference/objc" --resource-references "$ROOT/reference/resources"; }
fresh() { rm -rf "$T/$1" && mkdir "$T/$1" && cp "$NIB" "$T/$1/MFPreferencePane.nib" && echo "$T/$1/MFPreferencePane.nib"; }
convert() {  # NAME ARG...: converts a fresh copy at $T/NAME/MFPreferencePane.nib; stdout, stderr and status beside it
  name=$1; shift
  nib=$(fresh "$name")
  "$R" convert $(refs) "$@" "$nib" > "$T/$name/out" 2>"$T/$name/err"; echo $? > "$T/$name/rc"
}
rc() { cat "$T/$1/rc"; }

[ "$(head -c 8 "$NIB")" = NIBArchi ] && pass "macfuse: the pane nib is a NIBArchive" || fail "macfuse: $NIB is not a NIBArchive"

"$R" check $(refs) "$NIB" > "$T/check" 2>"$T/check.err"; crc=$?
sed 's/^[^:]*: //; s/ (.*//' "$T/check" | sort > "$T/kinds"
cat > "$T/want" <<'EOF'
finding: named-color-missing labelColor
finding: unknown-key NSChildControllerCreationSelectorName
finding: unknown-key NSImageAnimation
finding: unknown-key NSImageViewPlaceholderPrecedence
finding: unknown-key NSProgressIndicatorDoubleValue
will-adapt: nibarchive-format NIBArchive
will-adapt: wrapping-width NSTextField
will-adapt: wrapping-width NSTextField
EOF
[ "$crc" = 1 ] && cmp -s "$T/kinds" "$T/want" \
  && pass "macfuse: check exits 1 with labelColor, four keys 10.9 never reads, and two wrapping labels to adapt" \
  || fail "macfuse: check exited $crc: $(diff "$T/want" "$T/kinds" | tr '\n' '|')"
# spec: every view of the pane already carries NSDoNotTranslateAutoresizingMask true, and both wrapping labels are
#   549 wide, the width of their box (585) less 18 on each side.
[ "$(grep -c 'translate-autoresizing' "$T/check")" = 0 ] \
  && [ "$(grep -c 'wrapping-width NSTextField (@[0-9]* NSPreferredMaxLayoutWidth absent, NSFrame width 549)' "$T/check")" = 2 ] \
  && pass "macfuse: no view needs translate-autoresizing, and both labels are 549 wide" \
  || fail "macfuse: adaptation findings: $(grep -E 'translate|wrapping' "$T/check" | tr '\n' '|')"

convert accepted --exceptions "$EXC"
grep -q 'accepts nothing\|unused' "$T/accepted/err"; unused=$?
[ "$(rc accepted)" = 0 ] && [ "$(head -c 8 "$T/accepted/MFPreferencePane.nib")" = bplist00 ] && [ "$unused" = 1 ] \
  && [ "$(grep -c ' accepted as ' "$T/accepted/out")" = 5 ] \
  && pass "macfuse: convert with the pane's five accepted gaps exits 0 and writes a keyed archive" \
  || fail "macfuse: convert --exceptions exited $(rc accepted): $(head -3 "$T/accepted/err" | tr '\n' '|')"
"$R" dump --references "$ROOT/reference/objc" "$T/accepted/MFPreferencePane.nib" > "$T/accepted.rez" 2>&1
[ "$(grep -c '^  NSPreferredMaxLayoutWidth = f64 .*# 545$' "$T/accepted.rez")" = 2 ] \
  && pass "macfuse: both labels get a preferred width of 545, their frame width less 4" \
  || fail "macfuse: preferred widths: $(grep NSPreferredMaxLayoutWidth "$T/accepted.rez" | tr '\n' '|')"

i=0
while IFS= read -r line; do
  i=$((i + 1))
  grep -vxF "$line" "$EXC" > "$T/less-$i.exceptions"
  convert "less-$i" --exceptions "$T/less-$i.exceptions"
  item=$(printf '%s\n' "$line" | cut -f3)
  [ "$(rc "less-$i")" = 1 ] && cmp -s "$NIB" "$T/less-$i/MFPreferencePane.nib" \
    && pass "macfuse: without the $item line, strict convert exits 1 and leaves the nib as it was" \
    || fail "macfuse: without the $item line, convert exited $(rc "less-$i")"
done < "$EXC"
[ "$i" = 5 ] || fail "macfuse: $EXC has $i lines, not 5"

host="$(uname -s) $(uname -r)"
case $host in "Darwin 13."*) on_floor=1 ;; *) on_floor=0 ;; esac
if [ "$on_floor" = 0 ]; then
  [ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
  echo "all passed (AppKit's half needs 10.9, and this is $host)"; exit 0
fi

skip_floor() {
  [ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
  echo "SKIP: resources_macfuse_pane: AppKit's half: $1"; exit 77
}
( . "$ROOT/tests/lib/toolchain.sh" ) > "$T/toolchain" 2>&1 || skip_floor "no clang22: $(tail -1 "$T/toolchain")"
. "$ROOT/tests/lib/toolchain.sh"
printf '#import <AppKit/AppKit.h>\nint main(void) { return [NSApplication sharedApplication] == nil; }\n' > "$T/probe.m"
"$HOST_CC" -framework AppKit -o "$T/probe" "$T/probe.m" > "$T/probe.err" 2>&1 \
  || skip_floor "$HOST_CC cannot build against AppKit: $(head -1 "$T/probe.err")"
"$HOST_CC" -fobjc-arc -Wall -Wextra -Werror -framework AppKit -o "$T/instantiate" "$ROOT/tests/resources/fixtures/instantiate.m" \
  || exit 1
measure() {  # NAME NIB: conflicts, label_height and line_height with a stub MFPreferencePane owner, as $T/NAME.*
  "$T/instantiate" --owner MFPreferencePane "$2" > "$T/$1.out" 2>"$T/$1.stderr" || fail "instantiate $1: $(tail -1 "$T/$1.stderr")"
  for k in conflicts label_height line_height; do sed -n "s/^$k=//p" "$T/$1.out" > "$T/$1.$k"; done
}
v() { cat "$T/$1.$2"; }
two_lines() { awk -v h="$(v "$1" label_height)" -v l="$(v "$1" line_height)" 'BEGIN { exit !(l > 0 && h >= 2 * l) }'; }
says() { echo "conflicts=$(v "$1" conflicts) label_height=$(v "$1" label_height) line_height=$(v "$1" line_height)"; }

measure adapted "$T/accepted/MFPreferencePane.nib"
[ "$(v adapted conflicts)" = 0 ] && two_lines adapted \
  && ! grep -q 'Could not connect\|uncaught exception\|not key value coding-compliant' "$T/adapted.stderr" \
  && pass "macfuse: on 10.9 the converted pane connects to its owner, lays out with no conflicts, and its description wraps ($(says adapted))" \
  || fail "macfuse: converted pane on 10.9: $(says adapted); $(grep -v 'Could not find image\|labelColor' "$T/adapted.stderr" | head -3 | tr '\n' '|')"

convert plain --exceptions "$EXC" --no-adapt --no-strict
measure plain "$T/plain/MFPreferencePane.nib"
[ "$(rc plain)" = 1 ] && [ "$(grep -c '^MFPreferencePane.nib: finding: wrapping-width ' "$T/plain/out")" = 2 ] && [ "$(v plain conflicts)" = 0 ] && ! two_lines plain \
  && pass "macfuse: converted --no-adapt, the description stays one line, as the spike saw ($(says plain))" \
  || fail "macfuse: --no-adapt on 10.9: rc $(rc plain), $(says plain)"

# spec: the accepted keys are unread on 10.9: built without them, the pane instantiates to the same views and values.
grep -Ev '^  (NSChildControllerCreationSelectorName|NSImageAnimation|NSImageViewPlaceholderPrecedence|NSProgressIndicatorDoubleValue) = ' \
  "$T/accepted.rez" > "$T/unread.rez"
"$R" build --resource-references "$ROOT/reference/resources" "$T/unread.rez" -o "$T/unread.nib" > /dev/null 2>"$T/unread.err" \
  || fail "macfuse: build without the four keys: $(head -2 "$T/unread.err")"
"$T/instantiate" --owner MFPreferencePane --tree "$T/accepted/MFPreferencePane.nib" > "$T/accepted.tree" 2>/dev/null
"$T/instantiate" --owner MFPreferencePane --tree "$T/unread.nib" > "$T/unread.tree" 2>/dev/null
dropped=$(( $(wc -l < "$T/accepted.rez") - $(wc -l < "$T/unread.rez") ))
[ "$dropped" = 8 ] && grep -q '^    NSProgressIndicator .* value=16 min=16 max=100 indeterminate=1' "$T/accepted.tree" \
  && grep -q '^        NSImageView .* animates=0$' "$T/accepted.tree" && cmp -s "$T/accepted.tree" "$T/unread.tree" \
  && pass "macfuse: without its $dropped lines of the four accepted keys, the pane instantiates the same on 10.9" \
  || fail "macfuse: dropped $dropped; $(diff "$T/accepted.tree" "$T/unread.tree" | head -4 | tr '\n' '|')"

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
