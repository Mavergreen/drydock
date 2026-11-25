#!/bin/sh
# platform: host-agnostic -- writes, reads and rewrites binary plists as bytes, including Apple's committed keyed
#   archives and hand-built hostile ones; with DRYDOCK_RESOURCES_GMALLOC=1 the driver runs under macOS guard malloc,
#   and the test SKIPs (77) without it
set -u
: "${DRYDOCK_RESOURCES_BPLIST_DRIVER:?names the built resources-bplist-driver (CTest sets it)}"
D=$DRYDOCK_RESOURCES_BPLIST_DRIVER
GMALLOC=/usr/lib/libgmalloc.dylib
if [ "${DRYDOCK_RESOURCES_GMALLOC:-}" = 1 ]; then
  [ -f "$GMALLOC" ] || { echo "SKIP: no $GMALLOC"; exit 77; }
  run() { DYLD_INSERT_LIBRARIES=$GMALLOC MALLOC_STRICT_SIZE=1 "$D" "$@"; }
else
  run() { "$D" "$@"; }
fi
LC_ALL=C; export LC_ALL
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures"
T=$(mktemp -d "${TMPDIR:-/tmp}/bplist-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
size() { wc -c < "$1" | tr -d ' '; }
hx() { od -An -v -tx1 "$1" | tr -d ' \n'; }
u8() { od -An -tu1 -j "$2" -N1 "$1" | tr -d ' '; }
be() { od -An -v -tu1 -j "$2" -N "$3" "$1" | awk '{ for (i = 1; i <= NF; i++) v = v * 256 + $i } END { printf "%.0f\n", v }'; }
occurrences() { hx "$1" | awk -v s="$2" '{ print gsub(s, "") }'; }
unhex() {
  fold -w 512 | awk 'BEGIN { h = "0123456789abcdef" }
    { n = length($0); for (i = 1; i < n; i += 2) {
        line = line sprintf("\\%03o", (index(h, substr($0, i, 1)) - 1) * 16 + index(h, substr($0, i + 1, 1)) - 1)
        if (++k == 256) { print line; line = ""; k = 0 } } }
    END { if (k) print line }' | while IFS= read -r l; do printf "$l"; done
}
mk() {
  awk -v rs="$1" -v os="$2" -v top="${3:-0}" '
    function hexn(v, w,   s, i) { s = ""; for (i = 0; i < w; i++) { s = sprintf("%02x", v % 256) s; v = int(v / 256) }; return s }
    BEGIN { pos = 8; printf "62706c6973743030" }
    { off[NR] = pos; pos += length($0) / 2; printf "%s", $0 }
    END { for (i = 1; i <= NR; i++) printf "%s", hexn(off[i], os)
          printf "000000000000%s%s%s%s%s\n", hexn(os, 1), hexn(rs, 1), hexn(NR, 8), hexn(top, 8), hexn(pos, 8) }'
}

run build "$T/full.bplist" 2>"$T/err" || fail "bplist_roundtrip: build exit $?: $(cat "$T/err")"
if run rewrite "$T/full.bplist" "$T/again.bplist" 2>"$T/err"; then
  cmp -s "$T/full.bplist" "$T/again.bplist" && pass "bplist_roundtrip: write, read, write is byte-identical" \
    || fail "bplist_roundtrip: the rewrite differs from the first write"
else
  fail "bplist_roundtrip: rewrite exit $?: $(cat "$T/err")"
fi
run dump "$T/full.bplist" > "$T/full.txt" 2>"$T/err" || fail "bplist_roundtrip: dump exit $?: $(cat "$T/err")"
for t in null 'bool 1' 'bool 0' int uid real real32 string data array dict; do
  grep -Eq "(^ *|= )$t( |\$)" "$T/full.txt" && pass "bplist_roundtrip: type $t appears" \
    || fail "bplist_roundtrip: type $t never appears"
done
for want in 'int -9223372036854775808' 'int 9223372036854775807' 'int 4294967296' 'uid 4294967295' \
            'real32 7f800001' 'real32 3fc00000' 'real -1.0000000000000001e+300' '"nul" = string bytes3:610062' \
            '"astral" = string bytes14:736d696c6520f09f988020e282ac' '"latin" = string bytes5:636166c3a9' \
            '"long data" = data bytes300:00070e' '"wide array" = array 20' '"wide dict" = dict 17' \
            '"deeper" = array 2' '"repeated string" = string "repeated string"'; do
  grep -qF "$want" "$T/full.txt" && pass "bplist_roundtrip: reads back $want" \
    || fail "bplist_roundtrip: '$want' not in the dump"
done
for bits in 227f800001 237ff4000000000123 238000000000000000 0073006d0069006c00650020d83dde00002020ac; do
  [ "$(occurrences "$T/full.bplist" "$bits")" -ge 1 ] && pass "bplist_roundtrip: bytes $bits are written" \
    || fail "bplist_roundtrip: bytes $bits are not in the file"
done
n=$(occurrences "$T/full.bplist" 726570656174656420737472696e67)
[ "$n" = 1 ] && pass "bplist_roundtrip: 'repeated string', a key and four values, is written once" \
  || fail "bplist_roundtrip: 'repeated string' is written $n times"
run build "$T/full2.bplist" 2>/dev/null
cmp -s "$T/full.bplist" "$T/full2.bplist" && pass "bplist_roundtrip: two builds are byte-identical" \
  || fail "bplist_roundtrip: two builds differ"

trailer() { s=$(size "$1"); echo "$(be "$1" $((s - 32)) 6) $(u8 "$1" $((s - 26))) $(u8 "$1" $((s - 25))) $(be "$1" $((s - 24)) 8) $(be "$1" $((s - 16)) 8) $(be "$1" $((s - 8)) 8)"; }
run build --small "$T/small.bplist" 2>"$T/err" || fail "bplist_minimal_sizes: build exit $?: $(cat "$T/err")"
s=$(size "$T/small.bplist")
got=$(trailer "$T/small.bplist")
[ "$s" -lt 256 ] && [ "$got" = "0 1 1 5 0 $((s - 32 - 5))" ] \
  && pass "bplist_minimal_sizes: a 5-object, $s-byte plist has 1-byte offsets and refs ($got)" \
  || fail "bplist_minimal_sizes: a 5-object, $s-byte plist has trailer '$got'"
[ "$(hx "$T/small.bplist")" = 62706c6973743030d2010302045161100151625178080d0f11130000000000000101000000000000000500000000000000000000000000000015 ] \
  && pass "bplist_minimal_sizes: {a: 1, b: x} is numbered depth-first, a key then its value" \
  || fail "bplist_minimal_sizes: {a: 1, b: x} is $(hx "$T/small.bplist")"
for w in 254:1:2 255:2:2 256:2:2; do
  n=${w%%:*} r=${w#*:}; o=${r#*:}; r=${r%%:*}
  run build --wide "$n" "$T/wide.bplist" 2>"$T/err" || fail "bplist_minimal_sizes: build --wide $n exit $?"
  got=$(trailer "$T/wide.bplist")
  set -- $got
  [ "$2" = "$o" ] && [ "$3" = "$r" ] && [ "$4" = $((n + 1)) ] \
    && pass "bplist_minimal_sizes: $((n + 1)) objects take $r-byte refs, $(size "$T/wide.bplist") bytes $o-byte offsets" \
    || fail "bplist_minimal_sizes: $((n + 1)) objects: trailer '$got', wanted $o-byte offsets, $r-byte refs"
  run dump "$T/wide.bplist" > /dev/null 2>"$T/err" && pass "bplist_minimal_sizes: $((n + 1)) objects read back" \
    || fail "bplist_minimal_sizes: $((n + 1)) objects: dump exit $?: $(cat "$T/err")"
done
run build --xml-safe --only "long data" "$T/long.bplist" 2>"$T/err" || fail "bplist_minimal_sizes: build --only exit $?"
set -- $(trailer "$T/long.bplist")
[ "$2" = 2 ] && [ "$6" -gt 255 ] && [ "$(be "$T/long.bplist" $(($6 + 2 * 2)) 2)" -lt 256 ] \
  && pass "bplist_minimal_sizes: a $6-byte object region takes 2-byte offsets though every offset fits in one" \
  || fail "bplist_minimal_sizes: offsets must reach the offset table, as CoreFoundation checks: trailer '$*'"

for f in "$FIX"/nib-10.9/*.nib/keyedobjects.nib "$FIX"/nib/Main.storyboardc/Info.plist; do
  name=${f#"$FIX"/}
  if run dump "$f" > "$T/apple.txt" 2>"$T/err"; then
    case $f in
      *.plist) grep -q '^  "[A-Za-z]*" = ' "$T/apple.txt" ;;
      *) grep -q '^  "\$archiver" = string "NSKeyedArchiver"$' "$T/apple.txt" && grep -q '^  "\$objects" = array ' "$T/apple.txt" ;;
    esac && pass "bplist_reads_apple: $name" || fail "bplist_reads_apple: $name dumps without its top keys"
    run rewrite "$f" "$T/ours.bplist" 2>"$T/err" && run rewrite "$T/ours.bplist" "$T/ours2.bplist" 2>>"$T/err" \
      && run dump "$T/ours.bplist" > "$T/ours.txt" 2>>"$T/err" \
      && cmp -s "$T/apple.txt" "$T/ours.txt" && cmp -s "$T/ours.bplist" "$T/ours2.bplist" \
      && pass "bplist_reads_apple: $name rewrites to the same tree, then byte-identically" \
      || fail "bplist_reads_apple: $name rewrite: $(cat "$T/err") $(diff "$T/apple.txt" "$T/ours.txt" | head -3)"
  else
    fail "bplist_reads_apple: $name: dump exit $?: $(cat "$T/err")"
  fi
done
run dump "$FIX/nib-10.9/collections-alt.nib/keyedobjects.nib" | grep -q ' real32 ' \
  && pass "bplist_reads_apple: collections-alt's 4-byte reals stay 4-byte" \
  || fail "bplist_reads_apple: collections-alt has no real32 in its dump"

refused() {
  unhex > "$T/$1.bplist"
  run dump "$T/$1.bplist" > "$T/out" 2>"$T/err"; rc=$?
  err=$(grep -v '^GuardMalloc' "$T/err")
  [ -s "$T/out" ] && rc="$rc, stdout not empty"
  case "$rc:$err" in
    "4:malformed-bplist: $2 at "[0-9]*) pass "bplist_malformed: $1 ($err)" ;;
    *) fail "bplist_malformed: $1: wanted exit 4 and 'malformed-bplist: $2 at N', got exit $rc, '$err'" ;;
  esac
}
accepted() {
  unhex > "$T/$1.bplist"
  got=$(run dump "$T/$1.bplist" 2>"$T/err"); rc=$?
  [ "$rc:$got" = "0:$2" ] && pass "bplist_malformed: $1 is accepted as $2" \
    || fail "bplist_malformed: $1: wanted exit 0 and '$2', got exit $rc, '$got' '$(cat "$T/err")'"
}
GOOD=$(printf 'a20102\n1001\n5161\n' | mk 1 1)
printf '%s\n' "$GOOD" | accepted good "array 2
  int 1
  string \"a\""
printf '%s\n' "$GOOD" | sed 's/^62706c6973743030/62706c6973743031/' | refused magic header
printf '%s\n' "$GOOD" | cut -c 1-78 | refused short 'short file'
printf '62706c69737430300102\n' | refused tiny 'short file'
printf '%s\n' "$GOOD" | sed 's/..$//' | refused truncated trailer
printf '%s\n' "$GOOD" | sed 's/0000000000000000000000000000000f$/0000000000000003000000000000000f/' | refused top trailer
printf 'a20102\n1001\n5161\n' | mk 1 9 | refused offsetsize trailer
printf 'a20102\n1001\n5161\n' | mk 0 1 | refused refsize trailer
printf '%s\n' "$GOOD" | sed 's/00000000000000030000000000000000000000000000000f$/00000000000000040000000000000000000000000000000f/' \
  | refused offsettable 'offset table'
printf '%s\n' "$GOOD" | sed 's/000000000000000f$/0000000000000004/' | refused tablelow 'offset table'
printf 'a101\n4f110100%0512d\n' 0 | mk 1 1 | refused offsetsnarrow 'offset table'
printf 'a101\n4f10f3%0486d\n' 0 | mk 1 1 | refused offsets256 'offset table'
printf 'a101\n4f10f2%0484d\n' 0 | mk 1 1 | accepted offsets255 "array 1
  data bytes242:$(printf '%0484d' 0)"
for t in 255:1 256:2; do
  printf 'a101\n4f10%x%0*d\n' $((${t%:*} - 13)) $((2 * (${t%:*} - 13))) 0 | mk 1 2 | unhex > "$T/in.bplist"
  run rewrite "$T/in.bplist" "$T/out.bplist" 2>"$T/err"; set -- $(trailer "$T/out.bplist")
  [ "$6" = "${t%:*}" ] && [ "$2" = "${t#*:}" ] \
    && pass "bplist_minimal_sizes: an offset table at ${t%:*} takes ${t#*:}-byte offsets" \
    || fail "bplist_minimal_sizes: an offset table at ${t%:*}: trailer '$*' $(cat "$T/err")"
done
refs() { awk -v n="$1" -v w="$2" 'BEGIN { printf "af1%d%0*x", (n > 255), (n > 255) ? 4 : 2, n
  for (i = 1; i <= n; i++) printf "%0*x", 2 * w, i; print ""; for (i = 1; i <= n; i++) print "1001" }'; }
refs 255 1 | mk 1 2 | refused refsnarrow trailer
printf '%s\n' "$GOOD" | sed 's/080b0d\(000000000000\)/080b0d00\1/' | refused slack 'offset table'
printf 'a101\n4f10f3%0486d\n' 0 | mk 1 2 | sed 's/\(.\{64\}\)$/00\1/' | refused slackodd 'offset table'
printf 'a20105\n1001\n5161\n' | mk 1 1 | refused ref ref
printf '%s\n' "$GOOD" | sed 's/080b0d\(000000000000\)/080b0f\1/' | refused offset offset
printf '%s\n' "$GOOD" | sed 's/080b0d\(000000000000\)/080b07\1/' | refused offsetlow offset
printf 'a101\na100\n' | mk 1 1 | refused cycle 'cyclic container'
printf 'a100\n' | mk 1 1 | refused selfcycle 'cyclic container'
printf 'a20101\na102\n5161\n' | mk 1 1 | refused shared 'shared container'
printf 'a20101\nd10202\n5161\n' | mk 1 1 | refused shareddict 'shared container'
for e in a0 d0; do
  printf 'a30101%s\n%s\n5161\n' 02 "$e" | mk 1 1 | unhex > "$T/empty$e.bplist"
  want=$(printf 'array 3\n  %s 0\n  %s 0\n  string "a"' "$([ "$e" = a0 ] && echo array || echo dict)" "$([ "$e" = a0 ] && echo array || echo dict)")
  run dump "$T/empty$e.bplist" > "$T/out" 2>"$T/err" && [ "$(cat "$T/out")" = "$want" ] \
    && run rewrite "$T/empty$e.bplist" "$T/empty$e.2" 2>>"$T/err" && run dump "$T/empty$e.2" > "$T/out2" && cmp -s "$T/out" "$T/out2" \
    && pass "bplist_shared_empty: an empty $([ "$e" = a0 ] && echo array || echo dict) referenced twice reads, as Apple's writer makes it" \
    || fail "bplist_shared_empty: $e: $(grep -v '^GuardMalloc' "$T/err") $(cat "$T/out")"
done
awk 'BEGIN { for (i = 1; i <= 40; i++) printf "a2%02x%02x\n", i, i; print "a0" }' | mk 1 1 | refused laughs 'shared container'
awk 'BEGIN { for (i = 1; i <= 513; i++) printf "a1%04x\n", i; print "a0" }' | mk 2 2 | refused deep depth
awk 'BEGIN { for (i = 1; i <= 512; i++) printf "a1%04x\n", i; print "a0" }' | mk 2 2 | unhex > "$T/deep512.bplist"
run dump "$T/deep512.bplist" > /dev/null 2>"$T/err" && pass "bplist_malformed: 512 nested arrays are read" \
  || fail "bplist_malformed: 512 nested arrays: exit $?, $(cat "$T/err")"
printf 'af10ff\n' | mk 1 1 | refused count array
printf 'af1400000000000000000000000000000001\n1001\n' | mk 1 1 | refused count16 length
printf 'a101\n5f13ffffffffffffffff\n' | mk 1 1 | refused negcount length
printf 'a101\n51ff\n' | mk 1 1 | refused ascii 'ascii string'
printf 'a101\n61d800\n' | mk 1 1 | refused lonehigh 'utf-16 string'
printf 'a101\n61dc00\n' | mk 1 1 | refused lonelow 'utf-16 string'
printf 'a101\n62d8000041\n' | mk 1 1 | refused unpaired 'utf-16 string'
printf 'a101\n6241\n' | mk 1 1 | refused utf16short 'utf-16 string'
printf 'a101\n62d83dde00\n' | mk 1 1 | accepted pair 'array 1
  string bytes4:f09f9880'
printf 'a101\n14ffffffffffffffffffffffffffffffff\n' | mk 1 1 | accepted int16neg 'array 1
  int -1'
printf 'a101\n140000000000000000000000000000002a\n' | mk 1 1 | accepted int16 'array 1
  int 42'
printf 'a101\n1400000000000000007fffffffffffffff\n' | mk 1 1 | accepted int16max 'array 1
  int 9223372036854775807'
printf 'a101\n14000000000000000080000000000000ff\n' | mk 1 1 | refused int16big int
printf 'a101\n14ffffffffffffffff0000000000000000\n' | mk 1 1 | refused int16small int
printf 'a101\n15000000000000000000000000000000000000000000000000000000000000002a\n' | mk 1 1 | refused int32bytes 'marker 15'
printf 'a101\n13ffffffffffffffff\n' | mk 1 1 | accepted int8neg 'array 1
  int -1'
printf 'a101\n12ffffffff\n' | mk 1 1 | accepted int4 'array 1
  int 4294967295'
printf 'd10102\n1001\n5161\n' | mk 1 1 | refused key 'dict key'
printf 'd10102\n5161\n1001\n' | mk 1 1 | accepted dict 'dict 1
  "a" = int 1'
printf 'd10102\n610061\n1001\n' | mk 1 1 | accepted utf16key 'dict 1
  "a" = int 1'
printf 'a101\n330000000000000000\n' | mk 1 1 | refused date 'marker 33'
printf 'a101\n210000\n' | mk 1 1 | refused real2 'marker 21'
printf 'a101\nc0\n' | mk 1 1 | refused set 'marker c0'
printf 'a101\n88000000000000000001\n' | mk 1 1 | accepted uid9 'array 1
  uid 1'
printf 'a101\n8f000000000000000000000000ffffffff\n' | mk 1 1 | accepted uid16 'array 1
  uid 4294967295'
printf 'a101\n840100000000\n' | mk 1 1 | refused uidbig uid
printf 'a101\n8f010000000000000000000000ffffffff\n' | mk 1 1 | refused uid16big uid
printf 'a101\n8700000000000000ff\n' | mk 1 1 | accepted uid8 'array 1
  uid 255'
printf 'a101\n1000\n' | mk 1 1 | accepted int1 'array 1
  int 0'
printf 'a101\n430001\n' | mk 1 1 | refused data data
printf 'a101\n230000\n' | mk 1 1 | refused real real
printf 'a101\n12ffff\n' | mk 1 1 | refused int int
printf 'a101\n84000000\n' | mk 1 1 | refused uid uid
printf 'a101\n0f\n' | mk 1 1 | refused fill 'marker 0f'
printf 'a20102\n00\n0001\n' | mk 1 1 | accepted null 'array 2
  null
  null'
printf 'a101\n22\n' | mk 1 1 | refused real4 real
printf 'a101\n5f1001\n' | mk 1 1 | refused counted 'ascii string'

N=2000 K=16384
{ printf '62706c6973743030af11%04x' $N; awk -v n=$N 'BEGIN { for (i = 1; i <= n; i++) printf "%04x", i }'
  printf 'af11%04x' $K; awk -v n=$N -v k=$K 'BEGIN { for (i = 0; i < k; i++) printf "%04x", n + 1 }'; printf '00'
  P=$((8 + 4 + 2 * N)) Z=$((8 + 4 + 2 * N + 4 + 2 * K))
  awk -v n=$N -v p=$P -v z=$Z 'BEGIN { printf "%08x", 8; for (i = 1; i <= n; i++) printf "%08x", p; printf "%08x", z }'
  printf '00000000000004020000000000000%03x0000000000000000%016x\n' $((N + 2)) $((Z + 1)); } | refused aliasarray 'overlapping objects'
{ printf '62706c6973743030af11%04x' $N; awk -v n=$N 'BEGIN { for (i = 1; i <= n; i++) printf "%04x", i }'
  printf '4f1200010000'; head -c 65536 /dev/zero | od -An -v -tx1 | tr -d ' \n'
  P=$((8 + 4 + 2 * N))
  awk -v n=$N -v p=$P 'BEGIN { printf "%08x", 8; for (i = 1; i <= n; i++) printf "%08x", p }'
  printf '00000000000004020000000000000%03x0000000000000000%016x\n' $((N + 1)) $((P + 6 + 65536)); } | refused aliasdata 'overlapping objects'
for f in "$FIX"/nib-10.9/values.nib/keyedobjects.nib "$FIX"/nib-10.9/layout.nib/keyedobjects.nib; do
  got=$(run graft "$f" 2>"$T/err" | head -3 | tr '\n' '|'); rc=$?
  case "$got" in
    'array 2|  string "NSKeyedArchiver"|  dict '*) pass "bplist_retain: ${f#"$FIX"/}'s \$archiver and \$top outlive their tree" ;;
    *) fail "bplist_retain: ${f#"$FIX"/}: graft printed '$got', $(grep -v '^GuardMalloc' "$T/err")" ;;
  esac
done

bounded() {
  start=$(date +%s)
  got=$(run summary "$T/$1.bplist" 2>"$T/err"); rc=$?
  secs=$(($(date +%s) - start))
  rss=${got##*maxrss_kb }
  written=${got#written }; written=${written%% *}
  case "$rc:$got" in
    "0:written "[0-9]*" maxrss_kb "[0-9]*)
      [ "$rss" -lt 262144 ] && [ "$written" -lt "$3" ] && [ "$secs" -lt 10 ] \
        && pass "bplist_malformed: $1, $2, peaks at $rss KiB, rewrites to $written bytes in ${secs}s" \
        || fail "bplist_malformed: $1 peaks at $rss KiB, rewrites to $written bytes in ${secs}s: $4" ;;
    *) fail "bplist_malformed: $1: wanted exit 0 and 'written N maxrss_kb N', got exit $rc, '$got', '$(cat "$T/err")'" ;;
  esac
}
N=262144
{ printf '62706c6973743030af1200040000'; head -c $N /dev/zero | tr '\000' '\001' | od -An -v -tx1 | tr -d ' \n'
  printf '4f1200010000'; head -c 65536 /dev/zero | od -An -v -tx1 | tr -d ' \n'
  printf '%08x%08x' 8 $((8 + 6 + N))
  printf '000000000000040100000000000000020000000000000000%016x' $((8 + 6 + N + 6 + 65536)); } | unhex > "$T/shareddata.bplist"
bounded shareddata "one 64 KiB data object under $N refs" 400000 'the data is copied or written per reference'
{ printf '62706c6973743030af1200040000'; head -c $N /dev/zero | tr '\000' '\001' | od -An -v -tx1 | tr -d ' \n'
  printf '5f1200010000'; head -c 65536 /dev/zero | tr '\000' s | od -An -v -tx1 | tr -d ' \n'
  printf '%08x%08x' 8 $((8 + 6 + N))
  printf '000000000000040100000000000000020000000000000000%016x' $((8 + 6 + N + 6 + 65536)); } | unhex > "$T/sharedstring.bplist"
bounded sharedstring "one 64 KiB string under $N refs" 400000 'the string is copied or compared per reference'
if [ "${DRYDOCK_RESOURCES_GMALLOC:-}" != 1 ]; then
  M=65536
  { printf '62706c6973743030af1200010000'; awk -v m=$M 'BEGIN { for (i = 1; i <= m; i++) printf "%08x", i }'
    awk -v m=$M 'BEGIN { for (i = 0; i < m; i++) printf "54%02x%02x%02x%02x", 65 + int(i / 4096) % 16, 65 + int(i / 256) % 16, 65 + int(i / 16) % 16, 65 + i % 16 }'
    awk -v m=$M 'BEGIN { printf "%08x", 8; for (i = 0; i < m; i++) printf "%08x", 8 + 6 + 4 * m + 5 * i }'
    printf '000000000000040400000000%08x0000000000000000%016x' $((M + 1)) $((8 + 6 + 9 * M)); } | unhex > "$T/manystrings.bplist"
  bounded manystrings "$M distinct 4-byte strings" 1000000 'string uniquing is no longer n log n'
fi

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
