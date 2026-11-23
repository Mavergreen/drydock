#!/bin/sh
# platform: host-agnostic -- the pinned Jansson is compiled on every host, so it refuses the same input everywhere
set -u
: "${DRYDOCK_OBJC_JANSSON_DRIVER:?names the built objc-jansson-driver (CTest sets it)}"
T=$(mktemp -d "${TMPDIR:-/tmp}/jansson-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
parse() { "$DRYDOCK_OBJC_JANSSON_DRIVER" < "$T/in"; }
expect() {  # expect NAME PREFIX [SUBSTRING]
  out=$(parse); rc=$?
  case "$rc:$out" in
    "0:$2"*"${3:-}"*) echo "PASS: $1 ($out)" ;;
    *) echo "FAIL: $1: wanted '$2'${3:+ containing '$3'}, got exit $rc, '$out'"; fails=$((fails + 1)) ;;
  esac
}
nest() { awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) printf "["; for (i = 0; i < n; i++) printf "]" }'; }

printf '%s' '{"a":1,"a":2}' > "$T/in"; expect "a duplicate key is refused" error duplicate
printf '%s' '{"n":9223372036854775807}' > "$T/in"; expect "LLONG_MAX is taken" "ok object"
printf '%s' '{"n":9223372036854775808}' > "$T/in"; expect "LLONG_MAX + 1 is refused" error "too big"
printf '%s' '{"s":"\u0000"}' > "$T/in"; expect "\\u0000 is refused" error
printf '\357\273\277{}' > "$T/in"; expect "a UTF-8 BOM is refused" error
printf '{\000}\000' > "$T/in"; expect "UTF-16LE is refused" error
nest 2048 > "$T/in"; expect "2048 levels of nesting are taken" "ok array"
nest 2049 > "$T/in"; expect "2049 levels of nesting are refused" error
printf '{"k":"\303\251"}' > "$T/in"; expect "UTF-8 in a string is taken" "ok object"
printf '%s' '[]' > "$T/in"; expect "a top-level array is the caller's to refuse" "ok array"

[ "$fails" -eq 0 ] || { echo "jansson-test: $fails failed"; exit 1; }
echo "jansson-test: all passed"
