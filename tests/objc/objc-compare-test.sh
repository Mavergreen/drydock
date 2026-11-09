#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then runs compare.sh over doctored baselines
# spec: tests/objc/baseline/compare.sh header -- COMPARE_MODE=fewer-unmeasured lets a report lose only the error kinds
#       it names, table-byte errors only inside a table the reader lists and "different value" errors only in a
#       function holding one it follows; an added error, or any other lost error, fails.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
COMPARE="$HERE/baseline/compare.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-compare-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/log" ] || tail -20 "$T/log" >&2; exit 1; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 "$@"; }
# spec: tests/objc/fixtures/jt-reject-clobber.S header -- CLOBBER 0 a followed table, CLOBBER 1 the refused twin
for c in 0 1; do
  cc -DCLOBBER=$c "$FX/jt-reject-clobber.S" -o "$T/jt$c" -framework Foundation -lobjc -Wl,-no_data_in_code_info
done
sh "$HERE/baseline/record-artifacts.sh" "$DRYDOCK_OBJC" "$ROOT/reference/objc" "$T/base" \
  jt0 "$T/jt0" - jt1 "$T/jt1" - 2>/dev/null

# the table the reader lists for jt0: jmp, table, entries, function start, end
DRYDOCK_OBJC_JUMP_TABLES=1 "$DRYDOCK_OBJC" analyze --artifact "$T/jt0" --root "$T" --references "$ROOT/reference/objc" \
  --report "$T/jt0.json" --mode strict 2> "$T/jt0.stderr" || fail "jt0 is not measured"
line=$(grep '^drydock-objc-jump-table	' "$T/jt0.stderr") || fail "the reader lists no jump table in jt0"
[ "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" = 1 ] || fail "the reader lists more than jt0's one table"
table=$(printf '%s\n' "$line" | cut -f3)
fn=$(printf '%s\n' "$line" | cut -f5)
[ "$(printf '%s\n' "$line" | cut -f7)" = followed ] || fail "jt0's table is not followed"

# doctor FILE PROGRAM [ERROR]: a copy of the baseline whose FILE report awk PROGRAM rewrote (ERROR in its variable e)
n=0
doctor() {
  n=$((n + 1)); d="$T/doc$n"
  cp -R "$T/base" "$d"
  awk -v e="${3:-}" "$2" "$d/$1.objc-compat.json" > "$d/x" && mv "$d/x" "$d/$1.objc-compat.json"
}
err() { printf '{"code": "%s", "slice": "x86_64", "address": "%s", "detail": "%s"}' "$1" "$2" "$3"; }
passes() { COMPARE_MODE=fewer-unmeasured sh "$COMPARE" "$d" "$DRYDOCK_OBJC" > "$T/log" 2>&1 || fail "$1: compare refused it"; }
refuses() { ! COMPARE_MODE=fewer-unmeasured sh "$COMPARE" "$d" "$DRYDOCK_OBJC" > "$T/log" 2>&1 || fail "$1: compare let it pass"; }
# spec: tests/objc/baseline/compare.sh split_errors -- an empty list is "errors": []}; a full one opens at the end
#       of its line, one error per line after it
ONLY='{ if (sub(/"errors": \[\]}$/, "\"errors\": [" e "]}")) n++; print } END { exit n != 1 }'
FIRST='{ print } /"errors": \[$/ { print "  " e ","; n++ } END { exit n != 1 }'
DROP='k == 1 { k = 2; next } { print } /"errors": \[$/ { k = 1 } END { exit k != 2 }'
READ='objc entry point in r12 is read other than to call through it (a spill, a copy or an escape)'
MERGED='objc entry point in r12 is called through where another path left a different value'

d="$T/base"; passes 'the recorded baseline'
grep -q '^compare: jt0: exit 0, identical apart from analyzer and reference identity$' "$T/log" || fail "the recorded baseline: not identical"

doctor jt0 "$ONLY" "$(err indirect-objc-entry "$table" "$READ")"; passes 'a lost table error inside the listed table'
grep -q '1 fewer errors inside a jump table' "$T/log" || fail 'a lost table error inside the listed table: not counted'
doctor jt0 "$ONLY" "$(err indirect-objc-entry "$fn" "$READ")"; refuses 'a lost table error outside any table'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost table error outside any table: refused for another reason'
doctor jt0 "$ONLY" "$(err indirect-objc-entry "$fn" "$MERGED")"; passes 'a lost "different value" error in the function of a followed table'
doctor jt0 "$ONLY" "$(err unclassified-objc-runtime-import "$fn" _objc_getProperty)"; refuses 'a lost unrelated error'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost unrelated error: refused for another reason'
# jt1's table is not followed: its "different value" errors may not vanish
doctor jt1 "$FIRST" "$(err indirect-objc-entry "$fn" "$MERGED")"
refuses 'a lost "different value" error in a function holding no followed table'
grep -q '^compare: lost error ' "$T/log" || fail 'a lost "different value" error with no followed table: refused for another reason'
doctor jt1 "$DROP"; refuses 'an added error'
grep -q 'new, changed or reordered error' "$T/log" || fail 'an added error: refused for another reason'
echo "PASS: objc-compare-test"
