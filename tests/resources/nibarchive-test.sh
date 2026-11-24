#!/bin/sh
# platform: host-agnostic -- reads committed NIBArchive fixtures, and copies of one corrupted with dd and printf;
#   with DRYDOCK_RESOURCES_GMALLOC=1 the driver runs under macOS guard malloc, and the test SKIPs (77) without it
set -u
: "${DRYDOCK_RESOURCES_GRAPH_DRIVER:?names the built resources-graph-driver (CTest sets it)}"
D=$DRYDOCK_RESOURCES_GRAPH_DRIVER
GMALLOC=/usr/lib/libgmalloc.dylib
if [ "${DRYDOCK_RESOURCES_GMALLOC:-}" = 1 ]; then
  [ -f "$GMALLOC" ] || { echo "SKIP: no $GMALLOC"; exit 77; }
  run() { DYLD_INSERT_LIBRARIES=$GMALLOC MALLOC_STRICT_SIZE=1 "$D" "$@"; }
else
  run() { "$D" "$@"; }
fi
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures/nib"
T=$(mktemp -d "${TMPDIR:-/tmp}/nibarchive-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
u32() { od -An -tu4 -j "$2" -N4 "$1" | tr -d ' '; }

if run "$FIX/values.nib" > "$T/values.txt" 2>"$T/err"; then
  want=$(u32 "$FIX/values.nib" 18)
  got=$(grep -c '^#[0-9][0-9]* ' "$T/values.txt")
  [ -n "$want" ] && [ "$got" = "$want" ] && pass "nibarchive_values: $got objects, as the header says" \
    || fail "nibarchive_values: $got objects printed, header says '$want'"
  first=$(awk '/^#1 /{exit} /^  IB\.objectdata /{print}' "$T/values.txt")
  case "$first" in
    "  IB.objectdata (ref) = @"*) pass "nibarchive_values: object 0 has IB.objectdata as a ref" ;;
    *) fail "nibarchive_values: object 0's IB.objectdata is '$first'" ;;
  esac
else
  fail "nibarchive_values: driver exit $? on values.nib: $(cat "$T/err")"
fi
: > "$T/all.txt"
for f in "$FIX"/*.nib "$FIX"/Main.storyboardc/*.nib; do
  run "$f" >> "$T/all.txt" 2>"$T/err" || fail "nibarchive_values: driver exit $? on $f: $(cat "$T/err")"
done
for t in i8 i16 i32 i64 true false f32 f64 data nil ref; do
  n=$(grep -c "^  [^ ]* ($t) = " "$T/all.txt")
  [ "$n" -ge 1 ] && pass "nibarchive_values: type $t appears ($n)" || fail "nibarchive_values: type $t never appears"
done

swapped=$(awk '
  /^#/ { obj = substr($1, 2); cls[obj] = $2; next }
  $1 == "NS.bytes" { bytes[obj] = $4 }
  cls[obj] == "NSClassSwapper" && $1 == "NSClassName" && $2 == "(ref)" { ref[obj] = substr($4, 2); sub(/<.*/, "", ref[obj]) }
  END { for (o in ref) print bytes[ref[o]] }' "$T/values.txt")
case "$swapped" in
  *'"DDFixtureView"'*) pass "nibarchive_custom_class: an NSClassSwapper's NSClassName is DDFixtureView" ;;
  *) fail "nibarchive_custom_class: NSClassSwapper class names are: $swapped" ;;
esac

SRC="$FIX/values.nib"
SIZE=$(wc -c < "$SRC" | tr -d ' ')
le32() { printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"; }
corrupt() { cp "$SRC" "$T/$1.nib" && dd of="$T/$1.nib" bs=1 seek="$2" conv=notrunc 2>/dev/null; }
refused() {
  run "$T/$1.nib" > "$T/out" 2>"$T/err"; rc=$?
  err=$(grep -v '^GuardMalloc' "$T/err")
  [ -s "$T/out" ] && rc="$rc, stdout not empty"
  case "$rc:$err" in
    "4:malformed-nibarchive: $2 at "[0-9]*) pass "nibarchive_malformed: $1 ($err)" ;;
    *) fail "nibarchive_malformed: $1: wanted exit 4 and 'malformed-nibarchive: $2 at N', got exit $rc, '$err'" ;;
  esac
}
byte() { od -An -tx1 -j "$1" -N1 "$SRC" | tr -d ' '; }
TYPE=$(($(u32 "$SRC" 38) + 1)) EXTRAS=$(($(u32 "$SRC" 46) + 1))
[ "$(byte $TYPE)" = 0a ] || fail "nibarchive_malformed: values.nib's first value type is not a ref at $TYPE"
[ "$(byte $EXTRAS)" = 80 ] || fail "nibarchive_malformed: values.nib's first class extras is not 0 at $EXTRAS"
head -c 30 "$SRC" > "$T/header.nib"
refused header header
le32 1073741824 | corrupt objects 18; refused objects objects
{ le32 1; le32 $((SIZE - 2)); } | corrupt varint 42
printf '\000\000' | dd of="$T/varint.nib" bs=1 seek=$((SIZE - 2)) conv=notrunc 2>/dev/null; refused varint varint
le32 1 | corrupt keyindex 26; refused keyindex 'key index'
le32 1 | corrupt ref 18; refused ref ref
printf '\013' | corrupt type11 $TYPE; refused type11 'value type 11'
printf '\010\177\177\177\217' | corrupt data $TYPE; refused data data
printf '\000\000\000\000\204' | corrupt extras $EXTRAS; refused extras 'class extras'
KEY=$(u32 "$SRC" 30)
[ "$(byte $KEY)" = 99 ] || fail "nibarchive_malformed: values.nib's first key is not 25 bytes at $KEY"
printf '\000' | corrupt keynul $((KEY + 2)); refused keynul 'key NUL'
printf '\000' | corrupt classnul $((EXTRAS + 2)); refused classnul 'class NUL'

LC_ALL=C; export LC_ALL
repeat() { printf "$1" > "$T/unit"; i=0
  while [ $i -lt "$2" ]; do cat "$T/unit" "$T/unit" > "$T/unit2"; mv "$T/unit2" "$T/unit"; i=$((i + 1)); done; cat "$T/unit"; }
fill() { head -c "$2" /dev/zero | tr '\000' "$1"; }
built() { [ "$(wc -c < "$T/$1.nib" | tr -d ' ')" = "$2" ] || fail "nibarchive_malformed: $1.nib is not $2 bytes"; }
bounded() {
  got=$(run --summary "$T/$1.nib" 2>"$T/err"); rc=$?
  rss=${got##*maxrss_kb }
  case "$rc:$got" in
    "0:$2 maxrss_kb "[0-9]*)
      [ "$rss" -lt 262144 ] && pass "nibarchive_malformed: $1, $3, peaks at $rss KiB" \
        || fail "nibarchive_malformed: $1 peaks at $rss KiB: $4" ;;
    *) fail "nibarchive_malformed: $1: wanted exit 0 and '$2', got exit $rc, '$got', '$(cat "$T/err")'" ;;
  esac
}
{ printf 'NIBArchive'; le32 1; le32 10; le32 1; le32 98357; le32 1; le32 50; le32 16384; le32 65589; le32 1; le32 98362
  printf '\000\000\204'; fill k 65536
  repeat '\200\004' 14
  printf '\200\200\000\000\201'
  printf '\211\200NSObject\000'; } > "$T/sharedkey.nib"
built sharedkey 98373
bounded sharedkey 'objects 1 values 16384' 'one 64 KiB key under 16384 values' 'the key is copied per value'
{ printf 'NIBArchive'; le32 1; le32 10; le32 16384; le32 50; le32 0; le32 50; le32 0; le32 50; le32 1; le32 49202
  repeat '\200\200\200' 14
  printf '\001\000\204\200'; fill c 65536; printf '\000'; } > "$T/sharedclass.nib"
built sharedclass 114743
bounded sharedclass 'objects 16384 values 0' 'one 64 KiB class name under 16384 objects' 'the class name is copied per object'
{ printf 'NIBArchive'; le32 1; le32 10; le32 4096; le32 73783; le32 1; le32 50; le32 4096; le32 52; le32 1; le32 86071
  printf '\201k'
  printf '\200\010\000\000\204'; fill d 65536; repeat '\200\004' 12 | head -c 8190
  repeat '\200\200\201' 12
  printf '\211\200NSObject\000'; } > "$T/overlap.nib"
built overlap 86082
refused overlap 'object values'
if [ "${DRYDOCK_RESOURCES_GMALLOC:-}" != 1 ]; then
  { printf 'NIBArchive'; le32 1; le32 10; le32 1; le32 1050061; le32 150000; le32 50; le32 0; le32 1050064; le32 1; le32 1050050
    awk 'BEGIN { for (i = 0; i < 150000; i++) printf "\206%06d", i }'
    printf '\211\200NSObject\000\200\200\200'; } > "$T/manykeys.nib"
  built manykeys 1050064
  start=$(date +%s)
  bounded manykeys 'objects 1 values 0' '150000 distinct 6-byte keys' 'impossible at 1 MB'
  secs=$(($(date +%s) - start))
  [ "$secs" -lt 10 ] && pass "nibarchive_malformed: manykeys read in ${secs}s" \
    || fail "nibarchive_malformed: manykeys took ${secs}s: interning is no longer linear in the key count"
fi

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
