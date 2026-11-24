#!/bin/sh
# platform: host-agnostic -- dumps committed NIBArchive fixtures and parses hand-written dumps; with
#   DRYDOCK_RESOURCES_GMALLOC=1 the driver runs under macOS guard malloc, and the test SKIPs (77) without it
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
: "${DRYDOCK_RESOURCES_REZ_DRIVER:?names the built resources-rez-driver (CTest sets it)}"
R=$DRYDOCK_RESOURCES D=$DRYDOCK_RESOURCES_REZ_DRIVER
GMALLOC=/usr/lib/libgmalloc.dylib
if [ "${DRYDOCK_RESOURCES_GMALLOC:-}" = 1 ]; then
  [ -f "$GMALLOC" ] || { echo "SKIP: no $GMALLOC"; exit 77; }
  run() { DYLD_INSERT_LIBRARIES=$GMALLOC MALLOC_STRICT_SIZE=1 "$D" "$@"; }
else
  run() { "$D" "$@"; }
fi
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures/nib
GOLDEN=$ROOT/tests/resources/golden/values.rez
REF=$ROOT/reference/objc
T=$(mktemp -d "${TMPDIR:-/tmp}/rez-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
dump() { "$R" dump --references "$REF" "$1"; }

if dump "$FIX/values.nib" > "$T/values.rez" 2>"$T/err"; then
  cmp -s "$T/values.rez" "$GOLDEN" && pass "rez_golden: values.nib dumps to golden/values.rez" \
    || fail "rez_golden: values.nib's dump differs from golden/values.rez: $(diff "$GOLDEN" "$T/values.rez" | head -5)"
else
  fail "rez_golden: dump exit $?: $(cat "$T/err")"
fi
for t in i8 i16 i32 i64 true false f64 data nil ref; do
  grep -q "^  [^ ]* = $t\( \|\$\)" "$GOLDEN" && pass "rez_golden: type $t appears" || fail "rez_golden: type $t never appears"
done
grep -q '^chain NSButton : NSControl : NSView : NSResponder : NSObject$' "$GOLDEN" \
  && pass "rez_golden: a resolved chain" || fail "rez_golden: no resolved NSButton chain"
grep -q '^chain DDFixtureView ?$' "$GOLDEN" && pass "rez_golden: an unresolved chain" || fail "rez_golden: DDFixtureView is not unresolved"
grep -q "$ROOT\|$HOME\|/tmp/\|/var/" "$GOLDEN" && fail "rez_golden: the golden holds a host path" || pass "rez_golden: no host path"

dump "$FIX/collections.nib" > "$T/c1" 2>&1; dump "$FIX/collections.nib" > "$T/c2" 2>&1
[ -s "$T/c1" ] && cmp -s "$T/c1" "$T/c2" && pass "rez_stable: two dumps of collections.nib are identical" \
  || fail "rez_stable: two dumps of collections.nib differ or are empty"

n=0
for f in "$FIX"/*.nib "$FIX"/Main.storyboardc/*.nib "$FIX"/../nib-10.9/*.nib/keyedobjects-101300.nib; do
  b=${f#"$FIX"/}
  if ! dump "$f" > "$T/d" 2>"$T/err"; then fail "rez_reparse: dump $b exit $?: $(cat "$T/err")"; continue; fi
  run "$T/d" > "$T/r" 2>"$T/err" && cmp -s "$T/d" "$T/r" && n=$((n + 1)) \
    || fail "rez_reparse: $b: $(cat "$T/err") $(diff "$T/d" "$T/r" | head -4)"
  grep -v '^chain ' "$T/d" > "$T/nochain"
  run --nib "$f" > "$T/w" 2>"$T/err" && cmp -s "$T/nochain" "$T/w" \
    || fail "rez_reparse: $b written by the driver differs from the dump: $(cat "$T/err") $(diff "$T/nochain" "$T/w" | head -4)"
  awk '{ print "# why"; print ""; print $0 "   # because" }' "$T/d" > "$T/commented"
  run "$T/commented" > "$T/r" 2>"$T/err" && cmp -s "$T/d" "$T/r" \
    || fail "rez_comments: $b: $(cat "$T/err") $(diff "$T/d" "$T/r" | head -4)"
done
[ "$n" -ge 12 ] && pass "rez_reparse: $n fixtures reparse to their own dump" || fail "rez_reparse: only $n fixtures reparse"
dump "$FIX/collections-alt.nib" | grep -q '^  [^ ]* = f32 0x' && pass "rez_reparse: f32 appears in collections-alt.nib" \
  || fail "rez_reparse: no f32 in collections-alt.nib's dump"

HEAD='drydock-resources dump 1
format nibarchive 1 10
'
rez() { printf '%s' "$HEAD" > "$T/$1.rez"; cat >> "$T/$1.rez"; }
reparsed() {  # NAME: TEXT on stdin is $T/NAME.rez's expected rewrite
  cat > "$T/$1.want"
  run "$T/$1.rez" > "$T/out" 2>"$T/err" && cmp -s "$T/out" "$T/$1.want" && pass "$2" \
    || fail "$2: exit $?, $(grep -v '^GuardMalloc' "$T/err") $(diff "$T/$1.want" "$T/out" | head -8)"
}
rez floats <<'EOF'
@0 NSObject
  a = f64 0x0p+0
  b = f64 -0x0p+0
  c = f64 0x1p-1074
  d = f64 0x1.fffffffffffffp+1023
  e = f64 inf
  f = f64 -inf
  g = f64 nan
  h = f64 0x1.5555555555555p-2
  i = f64 0x1p-1023
  j = f64 0.1
  k = f64 nan(0x7ff0000000000001)
  l = f64 nan(0xfff8000000000000)
  m = f64 0x1.8p+1
  A = f32 0x0p+0
  B = f32 -0x0p+0
  C = f32 0x1p-149
  D = f32 0x1.fffffep+127
  E = f32 inf
  F = f32 -inf
  G = f32 nan
  H = f32 0x1.555556p-2
  I = f32 0x1p-127
  J = f32 0.1
  K = f32 0.333333343
  L = f32 nan(0x7f800001)
  M = f32 nan(0xff800001)
EOF
reparsed floats "rez_floats: f32 and f64 edge values print canonically and reparse exactly" <<'EOF'
drydock-resources dump 1
format nibarchive 1 10

@0 NSObject
  a = f64 0x0p+0  # 0
  b = f64 -0x0p+0  # -0
  c = f64 0x1p-1074  # 4.9406564584124654e-324
  d = f64 0x1.fffffffffffffp+1023  # 1.7976931348623157e+308
  e = f64 inf
  f = f64 -inf
  g = f64 nan
  h = f64 0x1.5555555555555p-2  # 0.33333333333333331
  i = f64 0x1p-1023  # 1.1125369292536007e-308
  j = f64 0x1.999999999999ap-4  # 0.10000000000000001
  k = f64 nan(0x7ff0000000000001)
  l = f64 nan(0xfff8000000000000)
  m = f64 0x1.8p+1  # 3
  A = f32 0x0p+0  # 0
  B = f32 -0x0p+0  # -0
  C = f32 0x1p-149  # 1.40129846e-45
  D = f32 0x1.fffffep+127  # 3.40282347e+38
  E = f32 inf
  F = f32 -inf
  G = f32 nan
  H = f32 0x1.555556p-2  # 0.333333343
  I = f32 0x1p-127  # 5.87747175e-39
  J = f32 0x1.99999ap-4  # 0.100000001
  K = f32 0x1.555556p-2  # 0.333333343
  L = f32 nan(0x7f800001)
  M = f32 nan(0xff800001)
EOF
cp "$T/floats.want" "$T/floats2.rez"
run "$T/floats2.rez" > "$T/out" 2>"$T/err" && cmp -s "$T/out" "$T/floats.want" \
  && pass "rez_floats: the canonical text is a fixed point" || fail "rez_floats: the canonical text rewrites: $(diff "$T/floats.want" "$T/out" | head -4)"

rez strings <<'EOF'
@0 NSObject
  "a key" = data "tab\there \"q\" back\\slash"
  "k=v" = data x"00ff10"
  "caf\xc3\xa9" = data "caf\xc3\xa9 \xe2\x9c\x93"
  bin = data "\x80abc"
  ctl = data "\x01"
  empty = data ""
  hexempty = data x""
  multi = data "line one\nline two"
  long = data "0123456789012345678901234567890123456789012345678901234567890123456789"
  longhex = data x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"
  joined = data "ab"   # pieces on following lines are one value
    x"6364"
    # a comment between pieces
    "ef"
  UINibEncoderEmptyKey = ref @1
  UINibEncoderEmptyKey = ref @1
@1 "my class"
  "@0" = i8 -128
  "?" = i16 32767
  x = i32 -2147483648
  y = i64 -9223372036854775808
  z = i64 9223372036854775807
  t = true
  u = false
  v = nil
EOF
reparsed strings "rez_strings: names, escapes, hex data, continuation pieces and repeated UINibEncoderEmptyKey" <<'EOF'
drydock-resources dump 1
format nibarchive 1 10

@0 NSObject
  "a key" = data "tab\there \"q\" back\\slash"
  "k=v" = data x"00ff10"
  "café" = data "café ✓"
  bin = data x"80616263"
  ctl = data x"01"
  empty = data ""
  hexempty = data ""
  multi = data "line one\n"
    "line two"
  long = data "0123456789012345678901234567890123456789012345678901234567890123"
    "456789"
  longhex = data x"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    x"20"
  joined = data "abcdef"
  UINibEncoderEmptyKey = ref @1
  UINibEncoderEmptyKey = ref @1

@1 "my class"
  "@0" = i8 -128
  "?" = i16 32767
  x = i32 -2147483648
  y = i64 -9223372036854775808
  z = i64 9223372036854775807
  t = true
  u = false
  v = nil
EOF

{ printf 'drydock-resources dump 1\nformat keyed\nchain A : B newer 10.11\nchain C\nchain "a b" ?\n\n@0 C\n'
  printf '  s = string "x"\n  u = uids @0 @0\n  e = uids\n'; } > "$T/keyed.rez"
reparsed keyed "rez_keyed: keyed format, chains with newer, strings and uids" <<'EOF'
drydock-resources dump 1
format keyed
chain A : B newer 10.11
chain C
chain "a b" ?

@0 C
  s = string "x"
  u = uids @0 @0
  e = uids
EOF

le32() { printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"; }
{ printf 'NIBArchive'; le32 1; le32 10; le32 1; le32 50; le32 1; le32 53; le32 1; le32 55; le32 1; le32 61
  printf '\200\200\201\201k\200\006\001\000\200\177\211\200NSObject\000'; } > "$T/snan.nib"
run --nib "$T/snan.nib" > "$T/out" 2>"$T/err" && grep -qx '  k = f32 nan(0x7f800001)' "$T/out" \
  && pass "rez_floats: a NIBArchive f32 signalling NaN dumps with its own bits" \
  || fail "rez_floats: a NIBArchive f32 signalling NaN: $(cat "$T/err") $(grep ' k = ' "$T/out")"

{ printf 'drydock-resources dump 1\nformat keyed\n\n@0 A\n  u = uids'
  awk 'BEGIN { for (i = 0; i < 400000; i++) printf "%s @0", (i && i % 10 == 0) ? "\n   " : "" }'; printf '\n'; } > "$T/uids.rez"
if run "$T/uids.rez" > "$T/uids.out" 2>"$T/err"; then
  long=$(awk 'length > 1048576' "$T/uids.out" | wc -l | tr -d ' ')
  n=$(sed -n '5,$p' "$T/uids.out" | tr ' ' '\n' | grep -c '^@0$')
  [ "$long" = 0 ] && [ "$n" = 400000 ] && [ "$(sed -n 5p "$T/uids.out")" = "  u = uids @0 @0 @0 @0 @0 @0 @0 @0 @0 @0 @0 @0 @0 @0 @0 @0" ] \
    && pass "rez_uids: 400000 refs wrap 16 to a line" || fail "rez_uids: $n refs, $long lines over the limit, line 5 '$(sed -n 5p "$T/uids.out" | head -c 80)'"
  cp "$T/uids.out" "$T/uids2.rez"
  run "$T/uids2.rez" > "$T/out" 2>"$T/err" && cmp -s "$T/out" "$T/uids.out" && pass "rez_uids: the wrapped array reparses to itself" \
    || fail "rez_uids: the wrapped array: $(cat "$T/err")"
else
  fail "rez_uids: a 400000-ref array: $(cat "$T/err")"
fi
printf 'drydock-resources dump 1\nformat keyed\n@0 A\n  u = uids @0\n  @0 @1\n@1 B\n  v = uids\n@2 "@3"\n' > "$T/uidsobj.rez"
run "$T/uidsobj.rez" > "$T/out" 2>"$T/err" && grep -qx '  u = uids @0 @0 @1' "$T/out" && grep -qx '@2 "@3"' "$T/out" \
  && pass "rez_uids: continuation refs join the pending array; '@N NAME' is still an object" \
  || fail "rez_uids: continuation: $(cat "$T/err") $(cat "$T/out")"

{ printf 'drydock-resources dump 1\nformat keyed\n@0 A\n  "'; head -c 300000 /dev/zero | tr '\000' '\001'; printf '" = i8 1\n'; } > "$T/longname.rez"
run "$T/longname.rez" > "$T/out" 2>"$T/err"; rc=$?
[ "$rc" = 4 ] && [ ! -s "$T/out" ] && [ "$(grep -v '^GuardMalloc' "$T/err")" = "a name too long to dump: line 5 would be longer than 1048576 bytes" ] \
  && pass "rez_write: a name whose line would pass the limit is refused when writing" \
  || fail "rez_write: an over-long name: exit $rc, '$(grep -v '^GuardMalloc' "$T/err")'"

refused() {  # NAME LINE WHAT: $T/NAME.rez exits 4 saying "malformed-dump: line LINE: WHAT", with nothing on stdout
  run "$T/$1.rez" > "$T/out" 2>"$T/err"; rc=$?
  err=$(grep -v '^GuardMalloc' "$T/err")
  [ -s "$T/out" ] && rc="$rc, stdout not empty"
  case "$rc:$err" in
    "4:malformed-dump: line $2: $3") pass "rez_parse_errors: $1 ($err)" ;;
    *) fail "rez_parse_errors: $1: wanted exit 4 and 'malformed-dump: line $2: $3', got exit $rc, '$err'" ;;
  esac
}
BODY='@0 NSObject
  IB.objectdata = ref @1
@1 NSView
  NSFrame = data "{{0, 0}, {1, 1}}"
@2 NSString
  NS.bytes = data "x"
'
bad() { rez "$1"; refused "$1" "$2" "$3"; }
printf '%s' "$BODY" | rez ok; run "$T/ok.rez" > /dev/null 2>"$T/err" && pass "rez_parse_errors: the base text parses" \
  || fail "rez_parse_errors: the base text is refused: $(cat "$T/err")"
printf '%s' "$BODY" | sed 's/ref @1/ref @99/' | bad ref99 4 'ref @99 names no object; the last is @2'
printf 'drydock-resources dump 1\nformat keyed\n@0 A\n  u = uids @0 @1\n' > "$T/uids1.rez"; refused uids1 4 'ref @1 names no object; the last is @0'
printf '%s  x = i8 300\n' "$BODY" | bad i8 9 'i8 300 is out of range'
printf '%s  x = i8 -129\n' "$BODY" | bad i8neg 9 'i8 -129 is out of range'
printf '%s  x = i16 32768\n' "$BODY" | bad i16 9 'i16 32768 is out of range'
printf '%s  x = i32 2147483648\n' "$BODY" | bad i32 9 'i32 2147483648 is out of range'
printf '%s  x = i64 9223372036854775808\n' "$BODY" | bad i64 9 'i64 9223372036854775808 is out of range'
printf '%s  x = i8 12a\n' "$BODY" | bad i8junk 9 "i8 12a is not a number"
printf '%s  x = i8\n' "$BODY" | bad i8none 9 "i8 needs a value"
printf '%s' "$BODY" | sed 's/{{0, 0}, {1, 1}}"/{{0, 0}/' | bad unterminated 6 'unterminated string'
printf '%s  NSFrame = data "y"\n' "$BODY" | sed 's/^@2.*//; s/^  NS.bytes.*//' | bad dupkey 9 'duplicate key NSFrame'
printf '%s  x = i9 1\n' "$BODY" | bad i9 9 'unknown type i9'
printf '%s@4 NSObject\n' "$BODY" | bad gap 9 'missing @3 before @4'
printf '%s@1 NSObject\n' "$BODY" | bad dupobj 9 'duplicate @1'
printf '  x = i8 1\n%s' "$BODY" | bad noobj 3 'a value before any object'
printf '%s  x = data "\\q"\n' "$BODY" | bad escape 9 'unknown escape \q'
printf '%s  x = data "\\x4"\n' "$BODY" | bad xescape 9 'bad \x escape'
printf '%s  x = data x"abc"\n' "$BODY" | bad hexodd 9 'odd number of hex digits'
printf '%s  x = data x"zz"\n' "$BODY" | bad hexdigit 9 'bad hex digit'
printf '%s  x = data x"00\n' "$BODY" | bad hexunterminated 9 'unterminated string'
printf '%s  "x\\x00" = i8 1\n' "$BODY" | bad nulname 9 'a name holds a NUL'
printf '%s  x = i8 1 2\n' "$BODY" | bad extra 9 "unexpected '2'"
printf '%s  x = f64 0x1p+1024\n' "$BODY" | bad f64big 9 'f64 0x1p+1024 is out of range'
printf '%s  x = f64 0x1p-1075\n' "$BODY" | bad f64small 9 'f64 0x1p-1075 is out of range'
printf '%s  x = f64 0x1.00000000000008p+0\n' "$BODY" | bad f64digits 9 'f64 0x1.00000000000008p+0 has more digits than an f64'
printf '%s  x = f64 0x1.0000000000001p-1070\n' "$BODY" | bad f64inexact 9 'f64 0x1.0000000000001p-1070 is not exact'
printf '%s  x = f32 0x1p+128\n' "$BODY" | bad f32big 9 'f32 0x1p+128 is out of range'
printf '%s  x = f32 0x1.000001p+0\n' "$BODY" | bad f32inexact 9 'f32 0x1.000001p+0 is not exact'
printf '%s  x = f64 1e999\n' "$BODY" | bad f64range 9 'f64 1e999 is out of range'
printf '%s  x = f64 0x0.8p+2\n' "$BODY" | bad f64lead 9 'f64 0x0.8p+2 is not a number'
printf '%s  x = f64 -nan(0xfff8000000000000)\n' "$BODY" | bad f64negnan 9 'f64 -nan(0xfff8000000000000) is not a number'
printf '%s  x = f64 1.5x\n' "$BODY" | bad f64junk 9 'f64 1.5x is not a number'
printf '%s  x = f64 0X1p3\n' "$BODY" | bad f64hexdecimal 9 'f64 0X1p3 is not a number'
printf '%s  x = data "\\\033[31m"\n' "$BODY" | bad escctl 9 'unknown escape \\x1b'
printf '%s  "a\033" = i8 1\n  "a\033" = i8 2\n' "$BODY" | bad dupesc 10 'duplicate key a\x1b'
printf '%s  x = f64 .5\n' "$BODY" | bad f64dot 9 'f64 .5 is not a number'
printf '%s  x = f64 infinity\n' "$BODY" | bad f64infinity 9 'f64 infinity is not a number'
printf '%s  x = f64 nan(0x7ff0000000000000)\n' "$BODY" | bad f64notnan 9 'f64 nan(0x7ff0000000000000) is not a NaN'
printf '%s  x = data\n' "$BODY" | bad datanone 9 'data needs a quoted string or x"hex"'
printf '%s  x = ref 1\n' "$BODY" | bad refbare 9 "ref needs @N, not '1'"
printf '%s  x = ref @1x\n' "$BODY" | bad refjunk 9 "ref needs @N, not '@1x'"
printf '%s  x = ref @4294967296\n' "$BODY" | bad refhuge 9 "ref needs @N, not '@4294967296'"
printf '%s  x = string "s"\n' "$BODY" | bad nastring 9 'string is not a NIBArchive type'
printf '%s  x = uids\n' "$BODY" | bad nauids 9 'uids is not a NIBArchive type'
printf '%s    "piece"\n' "$BODY" | sed 's/^  NS.bytes.*/  n = i8 1/' | bad piece 9 'a quoted piece that follows no data or string value'
printf '%schain A ?\n' "$BODY" | bad lateChain 9 'chain after the first object'
{ printf 'drydock-resources dump 1\nformat keyed\nchain B\nchain A\n'; } > "$T/chainorder.rez"; refused chainorder 4 'chain A is out of order or repeated'
{ printf 'drydock-resources dump 1\nformat keyed\nchain A ? newer 10.11\n'; } > "$T/chainq.rez"; refused chainq 3 "unexpected 'newer'"
{ printf 'drydock-resources dump 1\nformat keyed\nchain A : \n'; } > "$T/chainend.rez"; refused chainend 3 "a name must follow ':'"
printf 'drydock-resources dump 2\n' > "$T/version.rez"; refused version 1 'unsupported dump version 2'
printf '# only a comment\n\n' > "$T/empty.rez"; refused empty 2 "expected 'drydock-resources dump 1'"
printf 'drydock-resources dump 1\nformat nibarchive 1\n' > "$T/fmt.rez"; refused fmt 2 "expected 'format nibarchive V1 V2' or 'format keyed'"
printf 'drydock-resources dump 1\nformat nibarchive -1 10\n' > "$T/fmtneg.rez"; refused fmtneg 2 "nibarchive version -1 is not a 32-bit unsigned number"
printf 'drydock-resources dump 1\nformat nibarchive 4294967296 10\n' > "$T/fmtbig.rez"; refused fmtbig 2 "nibarchive version 4294967296 is not a 32-bit unsigned number"
printf 'drydock-resources dump 1\nformat nibarchive -18446744073709551615 10\n' > "$T/fmtwrap.rez"; refused fmtwrap 2 "nibarchive version -18446744073709551615 is not a 32-bit unsigned number"
printf 'drydock-resources dump 1\n' > "$T/fmteof.rez"; refused fmteof 1 "expected 'format nibarchive V1 V2' or 'format keyed'"
printf 'drydock-resources dump 1\n@0 NSObject\n' > "$T/nofmt.rez"; refused nofmt 2 "expected 'format nibarchive V1 V2' or 'format keyed'"
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  a = i8 1\001\n'; } > "$T/ctl.rez"; refused ctl 4 'a control character outside quotes'
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  a = data "\000"\n'; } > "$T/nul.rez"; refused nul 4 'a NUL byte'
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  caf\303\251 = i8 1\n'; } > "$T/utf8.rez"; refused utf8 4 'a non-ASCII byte outside quotes'
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  a = data "abc\\'; } > "$T/eofslash.rez"; refused eofslash 4 'unterminated string'
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  a = data x"0'; } > "$T/eofhex.rez"; refused eofhex 4 'unterminated string'
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  a = f64 0x1.8p'; } > "$T/eofreal.rez"; refused eofreal 4 'f64 0x1.8p is not a number'
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  a = i8 1'; } > "$T/eofok.rez"
run "$T/eofok.rez" > "$T/out" 2>"$T/err" && grep -q '^  a = i8 1$' "$T/out" && pass "rez_parse_errors: a last line with no newline parses" \
  || fail "rez_parse_errors: a last line with no newline: $(cat "$T/err")"
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  a = data x"'; head -c 1048576 /dev/zero | tr '\000' 0; printf '"\n'; } > "$T/long.rez"
refused long 4 'longer than 1048576 bytes'
{ printf '%s' "$HEAD"; printf '@0 NSObject\n  a = data x"'; head -c 1048500 /dev/zero | tr '\000' 0; printf '"\n'; } > "$T/longok.rez"
run "$T/longok.rez" > /dev/null 2>"$T/err" && pass "rez_parse_errors: a line just under the limit parses" \
  || fail "rez_parse_errors: a line just under the limit: $(cat "$T/err")"

if [ "${DRYDOCK_RESOURCES_GMALLOC:-}" != 1 ]; then
  { printf '%s@0 NSObject\n' "$HEAD"; awk 'BEGIN { for (i = 0; i < 200000; i++) printf "  k%06d = ref @%d\n", i, i }'
    awk 'BEGIN { for (i = 1; i < 200000; i++) printf "@%d NSObject\n  a = i8 1\n", i }'; } > "$T/big.rez"
  start=$(date +%s)
  lines=$(run "$T/big.rez" 2>"$T/err" | wc -l | tr -d ' ')
  secs=$(($(date +%s) - start))
  [ "$lines" = 800001 ] && [ "$secs" -lt 10 ] && pass "rez_scale: 200000 keys on one object and 200000 objects in ${secs}s" \
    || fail "rez_scale: $lines lines in ${secs}s: $(cat "$T/err")"
fi

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
