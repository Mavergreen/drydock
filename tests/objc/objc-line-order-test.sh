#!/bin/sh
# platform: host-agnostic -- the harness sorts with this host's qsort, which orders equal keys differently on Apple's
#           libc and glibc
# spec: src/objc/report.h objc_sort_lines -- of several line-table rows at one address, the last one emitted governs it,
#       on every host: 120 rows at three addresses, emitted in a scrambled order, each address's last row a line that
#       is neither its first, its least nor its greatest.
set -eu
: "${DRYDOCK_OBJC_LINES_DRIVER:?names the built objc-lines-driver (CTest sets it)}"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-line-order-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Rows: address A(i) = 0x1000 + 0x10 * (i % 3) with line 1 + (i * 37) % 120, in an LCG's order; want: each address's
# last row emitted, at the address, inside its span, and past the last.
awk 'BEGIN {
  for (i = 0; i < 120; i++) { o[i] = i }
  s = 12345
  for (i = 119; i > 0; i--) { s = (s * 1103515245 + 12345) % 2147483648; j = s % (i + 1); t = o[i]; o[i] = o[j]; o[j] = t }
  for (k = 0; k < 120; k++) {
    i = o[k]; a = 4096 + 16 * (i % 3); l = 1 + (i * 37) % 120
    printf "%x %d %d f%d.m\n", a, l, i % 7, i % 3 > "'"$T/rows"'"
    last[a] = l ":" i % 7 " f" i % 3 ".m"
  }
  for (a = 4096; a <= 4128; a += 16) { print last[a] > "'"$T/want"'"; print last[a] > "'"$T/want"'" }
  print last[4128] > "'"$T/want"'"; print "none" > "'"$T/want"'"
}'
"$DRYDOCK_OBJC_LINES_DRIVER" 1000 100f 1010 101f 1020 102f 1fff fff <"$T/rows" >"$T/got" || fail "lines-driver: exit $?"
cmp -s "$T/want" "$T/got" || fail "rows at one address are not answered by the last one emitted: want $(tr '\n' '|' <"$T/want"), got $(tr '\n' '|' <"$T/got")"
for a in 4096 4112 4128; do
  x=$(printf '%x' "$a")
  awk -v x="$x" '$1 == x { n++; l[n] = $2; if (min == "" || $2 < min) min = $2; if ($2 > max) max = $2 }
    END { exit !(n == 40 && l[n] != l[1] && l[n] != min && l[n] != max) }' "$T/rows" ||
    fail "0x$x: its last row is its first, least or greatest line, so this would not tell emission order from those"
done
echo "PASS: line-order: of rows at one address, the last emitted governs it"
