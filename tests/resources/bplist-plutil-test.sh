#!/bin/sh
# platform: macOS-only -- Apple's plutil judges the writer's output and re-encodes it, and Apple's keyed archives,
#   through XML; registered with drydock_macos_test, so elsewhere it SKIPs (77)
set -u
: "${DRYDOCK_RESOURCES_BPLIST_DRIVER:?names the built resources-bplist-driver (CTest sets it)}"
D=$DRYDOCK_RESOURCES_BPLIST_DRIVER
command -v plutil > /dev/null || { echo "SKIP: no plutil"; exit 77; }
LC_ALL=C; export LC_ALL
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures"
T=$(mktemp -d "${TMPDIR:-/tmp}/bplist-plutil-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }

"$D" build "$T/full.bplist" && "$D" build --xml-safe "$T/safe.bplist" && "$D" build --wide 300 "$T/wide.bplist" \
  && "$D" build --wide 255 "$T/wide256.bplist" || fail "bplist_plutil: build exit $?"
"$D" rewrite "$FIX/nib-10.9/values.nib/keyedobjects.nib" "$T/values.bplist" || fail "bplist_plutil: rewrite exit $?"
"$D" rewrite "$FIX/nib/Main.storyboardc/Info.plist" "$T/info.bplist" || fail "bplist_plutil: rewrite exit $?"
for f in full safe wide wide256 values info; do
  out=$(plutil -lint "$T/$f.bplist" 2>&1)
  case $out in
    *": OK") pass "bplist_plutil: plutil -lint accepts the $f tree" ;;
    *) fail "bplist_plutil: plutil -lint on the $f tree: $out" ;;
  esac
done
roundtrip() {
  if plutil -convert xml1 -o - "$1" | plutil -convert binary1 -o "$T/apple.bplist" - \
     && "$D" dump --as-xml "$1" > "$T/ours.txt" && "$D" dump --as-xml "$T/apple.bplist" > "$T/apple.txt"; then
    cmp -s "$T/ours.txt" "$T/apple.txt" && pass "bplist_plutil: $2 reads the same after plutil's XML round trip" \
      || fail "bplist_plutil: $2 differs after plutil's XML round trip: $(diff "$T/ours.txt" "$T/apple.txt" | head -5)"
  else
    fail "bplist_plutil: $2: plutil or dump failed"
  fi
}
for f in "$T/safe.bplist" "$T/wide.bplist" "$T/values.bplist" "$T/info.bplist" "$FIX"/nib-10.9/*.nib/keyedobjects.nib; do
  name=${f#"$FIX"/}; name=${name#"$T"/}
  roundtrip "$f" "$name"
done
"$D" dump "$T/safe.bplist" > "$T/safe.txt" || fail "bplist_plutil: dump of the safe tree exit $?"
sed -n 's/^  "\(.*\)" = .*/\1/p' "$T/safe.txt" > "$T/keys"
[ "$(wc -l < "$T/keys" | tr -d ' ')" = "$(sed -n '1s/^dict //p' "$T/safe.txt")" ] \
  || fail "bplist_plutil: not every root key of the safe tree reads back as plain text"
[ -z "$(sort "$T/keys" | uniq -d)" ] || fail "bplist_plutil: the safe tree repeats a root key: $(sort "$T/keys" | uniq -d)"
i=0
while IFS= read -r k; do
  i=$((i + 1))
  if "$D" build --xml-safe --only "$k" "$T/entry$i.bplist"; then
    roundtrip "$T/entry$i.bplist" "safe tree entry \"$k\""
  else
    fail "bplist_plutil: safe tree entry \"$k\": build --only exit $?"
  fi
done < "$T/keys"
[ "$i" = "$(wc -l < "$T/keys" | tr -d ' ')" ] || fail "bplist_plutil: probed $i of the safe tree's root entries"

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
