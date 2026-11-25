#!/bin/sh
# platform: macOS-only -- 10.9 only: AppKit on the floor itself, compiled at test time with clang22 against the pinned
#   10.9 SDK; elsewhere it SKIPs (77)
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
R=$DRYDOCK_RESOURCES
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
case "$(uname -s) $(uname -r)" in
  "Darwin 13."*) ;;
  *) echo "SKIP: resources_instantiate: AppKit on OS X 10.9, and this is $(uname -s) $(uname -r)"; exit 77 ;;
esac
. "$ROOT/tests/lib/toolchain.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/instantiate-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
TAB=$(printf '\t')

printf '#import <AppKit/AppKit.h>\nint main(void) { return [NSApplication sharedApplication] == nil; }\n' > "$T/probe.m"
"$HOST_CC" -framework AppKit -o "$T/probe" "$T/probe.m" > "$T/probe.err" 2>&1 \
  || { echo "SKIP: resources_instantiate: $HOST_CC cannot build against AppKit: $(head -1 "$T/probe.err")"; exit 77; }
"$HOST_CC" -fobjc-arc -Wall -Wextra -Werror -framework AppKit -o "$T/instantiate" "$FIX/instantiate.m" || exit 1

in_obj() {  # N SED [FILE]: SED applied within object N
  n=$1 cmd=$2; shift 2
  sed "/^@$n /,/^\$/{
$cmd
}" "$@"
}
dump() { "$R" dump --references "$ROOT/reference/objc" "$1"; }
build() {  # NAME TEXT ARG...: builds TEXT to $T/NAME.nib, its stderr in $T/NAME.err
  name=$1 text=$2; shift 2
  "$R" build --resource-references "$ROOT/reference/resources" "$@" "$text" -o "$T/$name.nib" > /dev/null 2>"$T/$name.err" \
    || fail "build $name: $(head -2 "$T/$name.err")"
}
measure() {  # NAME NIB: instantiate's conflicts, label_height and line_height for NIB, as $T/NAME.{conflicts,label,line}
  "$T/instantiate" "$2" > "$T/$1.out" 2>"$T/$1.stderr" || fail "instantiate $1: $(tail -1 "$T/$1.stderr")"
  for k in conflicts label_height line_height; do sed -n "s/^$k=//p" "$T/$1.out" > "$T/$1.$k"; done
}
v() { cat "$T/$1.$2"; }
two_lines() { awk -v h="$(v "$1" label_height)" -v l="$(v "$1" line_height)" 'BEGIN { exit !(l > 0 && h >= 2 * l) }'; }
says() { echo "conflicts=$(v "$1" conflicts) label_height=$(v "$1" label_height) line_height=$(v "$1" line_height)"; }

# spec: macFUSE's shape from the committed layout.nib: the box and the label carry NSDoNotTranslateAutoresizingMask
#   false, and the label's frame is about as wide as macFUSE's, so its text has to wrap.
dump "$FIX/nib/layout.nib" > "$T/layout.rez"
in_obj 17 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' "$T/layout.rez" \
  | in_obj 21 's/^  NSDoNotTranslateAutoresizingMask = true$/  NSDoNotTranslateAutoresizingMask = false/' \
  | sed 's/^  NS.bytes = data "{{14, 128}, {1430, 16}}"$/  NS.bytes = data "{{14, 128}, {551, 16}}"/' > "$T/macfuse.rez"
[ "$(diff "$T/layout.rez" "$T/macfuse.rez" | grep -c '^>')" = 3 ] \
  && pass "instantiate: the macFUSE-shaped dump differs from layout.nib's in exactly three lines" \
  || fail "instantiate: the edits to layout.nib's dump did not all apply: $(diff "$T/layout.rez" "$T/macfuse.rez" | tr '\n' '|')"

build plain "$T/macfuse.rez" --no-adapt
measure plain "$T/plain.nib"
[ "$(v plain conflicts)" -gt 0 ] 2>/dev/null && ! two_lines plain \
  && pass "instantiate: --no-adapt reproduces macFUSE on 10.9: constraint conflicts and an unwrapped label ($(says plain))" \
  || fail "instantiate: --no-adapt does not reproduce macFUSE: $(says plain)"

build adapted "$T/macfuse.rez"
measure adapted "$T/adapted.nib"
[ "$(v adapted conflicts)" = 0 ] && two_lines adapted \
  && pass "instantiate: adapted, it lays out with no conflicts and the label wraps ($(says adapted))" \
  || fail "instantiate: adapted: $(says adapted)"

build no_translate "$T/macfuse.rez" --no-adapt=translate-autoresizing
measure no_translate "$T/no_translate.nib"
[ "$(v no_translate conflicts)" -gt 0 ] 2>/dev/null \
  && pass "instantiate: without translate-autoresizing alone, the conflicts come back ($(says no_translate))" \
  || fail "instantiate: --no-adapt=translate-autoresizing: $(says no_translate)"

build no_wrap "$T/macfuse.rez" --no-adapt=wrapping-width
measure no_wrap "$T/no_wrap.nib"
[ "$(v no_wrap conflicts)" = 0 ] && ! two_lines no_wrap \
  && pass "instantiate: without wrapping-width alone, no conflicts but the label stays one line ($(says no_wrap))" \
  || fail "instantiate: --no-adapt=wrapping-width: $(says no_wrap)"

measure apple "$FIX/nib-10.9/layout.nib"
[ "$(v apple conflicts)" = 0 ] && [ -n "$(v apple label_height)" ] \
  && pass "instantiate: Apple's own 10.9 compile of layout.xib lays out with no conflicts ($(says apple))" \
  || fail "instantiate: Apple's 10.9 layout.nib: $(says apple)"

# spec: keys-10.9.tsv's "check unread-on-10.9": every committed seed drydock-resources converts instantiates on 10.9
#   to the same window, views, frames, text and cells with and without those keys, and as Apple's own 10.9 compile.
UNREAD=$(awk -F "$TAB" '!/^#/ && $3 == "ignored" && $4 ~ /^unread-on-10\.9:/ { print $2 }' "$ROOT/reference/resources/keys-10.9.tsv" \
  | sort -u | tr '\n' '|' | sed 's/|$//; s/\./\\./g')
[ "$UNREAD" = 'NS\.resolvesNaturalAlignmentWithBaseWritingDirection|NSAllowsWritingTools|NSAuxButtonType|NSLinearExposure|NSMaxFullScreenContentSize|NSMinFullScreenContentSize|NSNibTouchBar|NSTextFieldAllowsWritingToolsAffordance|NSWindowSubtitle' ] \
  && pass "instantiate: keys-10.9.tsv marks nine keys unread-on-10.9" \
  || fail "instantiate: unread-on-10.9 keys: $UNREAD"
printf '*.nib%snamed-color-missing%slabelColor%s10.9 draws it opaque black\n' "$TAB" "$TAB" "$TAB" > "$T/lc"
for n in attributed-title attributed-value collections-alt collections int64 layout; do
  cp "$FIX/nib/$n.nib" "$T/$n.nib"
  "$R" convert --references "$ROOT/reference/objc" --resource-references "$ROOT/reference/resources" \
    --exceptions "$T/lc" --no-strict "$T/$n.nib" > "$T/$n.convert" 2>&1
  dump "$FIX/nib/$n.nib" | grep -Ev "^  ($UNREAD) = " > "$T/$n-unread.rez"
  build "$n-unread" "$T/$n-unread.rez"
  "$T/instantiate" --tree "$T/$n.nib" > "$T/$n.tree" 2>/dev/null || fail "instantiate --tree $n: does not instantiate"
  "$T/instantiate" --tree "$T/$n-unread.nib" > "$T/$n-unread.tree" 2>/dev/null || fail "instantiate --tree $n without the keys"
  "$T/instantiate" --tree "$FIX/nib-10.9/$n.nib" > "$T/$n-apple.tree" 2>/dev/null || fail "instantiate --tree Apple's $n"
  dropped=$(( $(dump "$FIX/nib/$n.nib" | wc -l) - $(wc -l < "$T/$n-unread.rez") ))
  [ "$dropped" -gt 0 ] && [ "$(head -c 8 "$T/$n.nib")" = bplist00 ] && grep -q '^NSWindow ' "$T/$n.tree" \
    && grep -q '^    NS[A-Za-z]* frame=' "$T/$n.tree" && cmp -s "$T/$n.tree" "$T/$n-unread.tree" \
    && cmp -s "$T/$n.tree" "$T/$n-apple.tree" \
    && pass "instantiate: $n.nib converted, and built without its $dropped unread-on-10.9 key lines, instantiates as Apple's 10.9 compile does" \
    || fail "instantiate: $n: dropped $dropped; $(diff "$T/$n.tree" "$T/$n-unread.tree" | head -4 | tr '\n' '|') apple: $(diff "$T/$n.tree" "$T/$n-apple.tree" | head -4 | tr '\n' '|')"
done

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
