#!/bin/sh
# platform: host-agnostic -- json.c and the pinned Jansson are compiled on every host
set -u
: "${DRYDOCK_OBJC_JSON_DRIVER:?names the built objc-json-driver (CTest sets it)}"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-json-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
put() { printf '%s' "$1" > "$T/in.json"; }
# answer NAME WANT OP [ARG...]: stdout of OP on $T/in.json, exit 0, is exactly WANT
answer() {
  name=$1 want=$2; shift 2
  got=$("$DRYDOCK_OBJC_JSON_DRIVER" "$T/in.json" "$@" 2>"$T/err"); rc=$?
  if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then pass "$name ($got)"
  else fail "$name: wanted '$want', got exit $rc, '$got', stderr '$(cat "$T/err")'"; fi
}
# refused NAME FILE CODE [SUBSTRING]: exit 4, and stderr names CODE, FILE and SUBSTRING
refused() {
  name=$1 file=$2 code=$3 sub=${4:-}
  got=$("$DRYDOCK_OBJC_JSON_DRIVER" "$file" read 2>"$T/err"); rc=$?
  err=$(cat "$T/err")
  case "$rc:$err" in
    "4:$code: test input $file:"*"$sub"*) pass "$name ($err)" ;;
    *) fail "$name: wanted exit 4 and '$code: test input $file:...$sub...', got exit $rc, stdout '$got', stderr '$err'" ;;
  esac
}
nest() { awk -v n="$1" 'BEGIN { printf "{\"k\":"; for (i = 1; i < n; i++) printf "["; for (i = 1; i < n; i++) printf "]"; printf "}" }'; }

# json_dup_key
put '{"a":1,"a":2}'; refused "a duplicate key is malformed" "$T/in.json" malformed-input "duplicate"
put '{"a":1,"b":2}'; answer "distinct keys are read" ok read

# json_caps
{ printf '{"p":"'; head -c $((16 * 1024 * 1024 - 8)) /dev/zero | tr '\000' x; printf '"}'; } > "$T/cap.json"
[ "$(wc -c < "$T/cap.json" | tr -d ' ')" = 16777216 ] || fail "the 16 MiB fixture is not 16777216 bytes"
cp "$T/cap.json" "$T/in.json"; answer "exactly 16 MiB is read" ok read
printf ' ' >> "$T/cap.json"
refused "16 MiB + 1 byte is oversized" "$T/cap.json" oversized-input "16777217 bytes, limit 16777216"
rm -f "$T/cap.json"
nest 513 > "$T/in.json"; answer "513 levels of nesting are read (10.9's Foundation read them)" ok read
nest 514 > "$T/in.json"; refused "514 levels of nesting are malformed (10.9's Foundation refused them)" "$T/in.json" malformed-input "maximum parsing depth"

# json_schema_real
put '{"schema":1.0}'; answer "schema 1.0 is not the integer 1" 0 is_int schema 1
put '{"schema":true}'; answer "schema true is not the integer 1" 0 is_int schema 1
put '{"schema":"1"}'; answer "schema \"1\" is not the integer 1" 0 is_int schema 1
put '{"schema":2}'; answer "schema 2 is not the integer 1" 0 is_int schema 1
put '{"schema":1}'; answer "schema 1 is the integer 1" 1 is_int schema 1
put '{"other":1}'; answer "an absent schema is not the integer 1" 0 is_int schema 1

# json_count
for v in 1.5 0 -1 true '"7"' 7.0 null; do
  put "{\"n\":$v}"; answer "count $v is refused" 0 count n
done
put '{"n":7}'; answer "count 7 is taken" "1 7" count n
put '{"n":9223372036854775807}'; answer "count LLONG_MAX is taken" "1 9223372036854775807" count n
put '{"n":9223372036854775808}'; refused "an integer past long long is malformed" "$T/in.json" malformed-input "too big"
put '{"m":7}'; answer "an absent count is refused" 0 count n

# json_first_unknown
put '{"b":1,"z":2,"y":3}'; answer "the first unknown key in document order (z before y)" z first_unknown b
put '{"b":1,"y":3,"z":2}'; answer "the first unknown key in document order (y before z)" y first_unknown b
put '{"b":1,"y":3}'; answer "no unknown key" "(none)" first_unknown b y
put '{}'; answer "an empty object has no unknown key" "(none)" first_unknown

# json_exact_keys
put '{"a":1,"b":2}'; answer "exact keys in order" 1 exact_keys a b
put '{"b":2,"a":1}'; answer "exact keys out of order" 1 exact_keys a b
put '{"a":1}'; answer "a missing key is not exact" 0 exact_keys a b
put '{"a":1,"b":2,"c":3}'; answer "an extra key is not exact" 0 exact_keys a b
put '{"a":1,"c":3}'; answer "a substituted key is not exact" 0 exact_keys a b

# json_utf8_roundtrip
printf '{"p":"dir/\303\251\303\251"}' > "$T/in.json"
"$DRYDOCK_OBJC_JSON_DRIVER" "$T/in.json" str p > "$T/out" 2>"$T/err"; rc=$?
printf 'dir/\303\251\303\251' > "$T/want"
if [ "$rc" = 0 ] && cmp -s "$T/out" "$T/want"; then pass "a UTF-8 string comes back as its bytes"
else fail "a UTF-8 string: exit $rc, got '$(od -An -c "$T/out")', stderr '$(cat "$T/err")'"; fi
put '{"s":"x","a":[],"o":{},"n":1}'
answer "objc_jstr takes a string alone" "s--" kind s
answer "objc_jarr takes an array alone" "-a-" kind a
answer "objc_jobj takes an object alone" "--o" kind o
answer "a number is none of them" "---" kind n
answer "an absent key is none of them" "---" kind missing

# json_not_object
put '[1]'; refused "a top-level array is the wrong type" "$T/in.json" malformed-input "not a JSON object (wrong type)"
put '{"a":'; refused "truncated JSON is malformed, with Jansson's position" "$T/in.json" malformed-input "not a JSON object ("
put '{"s":"\u0000"}'; refused "\\u0000 is malformed" "$T/in.json" malformed-input
printf '\357\273\277{}' > "$T/in.json"; refused "a UTF-8 BOM is malformed" "$T/in.json" malformed-input

# json_not_regular
mkdir "$T/dir"; refused "a directory is unreadable" "$T/dir" unreadable-input
refused "a missing file is unreadable" "$T/missing.json" unreadable-input

[ "$fails" -eq 0 ] || { echo "objc-json-test: $fails failed"; exit 1; }
echo "objc-json-test: all passed"
