#!/bin/sh
# tests/rebase_oracle_test.sh -- src/rebase.h's decode must be dyldinfo's,
# slot for slot and in stream order, over every x86_64 dylib under 10.9's
# /usr/lib.
#
#   sh tests/rebase_oracle_test.sh <bindir>
#
# Local only: it SKIPs, saying why, where dyldinfo or 10.9's dylibs are
# absent; CI's macos-26 runner keeps its libraries in the shared cache.
set -u

BIN="${1:?usage: rebase_oracle_test.sh <bindir>}"
ORACLE="$BIN/rebase_oracle"
[ -x "$ORACLE" ] || { echo "rebase_oracle_test: $ORACLE not found or not executable" >&2; exit 1; }

DYLDINFO=/Library/Developer/CommandLineTools/usr/bin/dyldinfo
[ -x "$DYLDINFO" ] || { echo "SKIP: no $DYLDINFO here"; exit 77; }
command -v lipo >/dev/null 2>&1 || { echo "SKIP: no lipo here"; exit 77; }
[ -f /usr/lib/libSystem.B.dylib ] || { echo "SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own"; exit 77; }

T=$(mktemp -d "${TMPDIR:-/tmp}/rebase-oracle.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

# dyldinfo's rows are "SEGMENT SECTION ADDRESS TYPE"; the type may be two
# words, and the section may be blank, so the address is found by its 0x.
theirs() {
    "$DYLDINFO" -arch x86_64 -rebase "$1" 2>/dev/null | awk 'NR > 2 {
        for (i = 2; i <= NF && $i !~ /^0x/; i++) ;
        t = ""; for (j = i + 1; j <= NF; j++) t = t (t == "" ? "" : " ") $j
        print $1, $i, t }'
}

fail=0 files=0 slots=0
find /usr/lib -name "*.dylib" -type f >"$T/corpus"
while read -r f; do
    [ -f "$f" ] || continue
    lipo "$f" -verify_arch x86_64 2>/dev/null || continue
    thin="$T/thin"
    lipo "$f" -thin x86_64 -output "$thin" 2>/dev/null || cp "$f" "$thin"
    theirs "$thin" >"$T/theirs"
    rc=0; "$ORACLE" "$thin" >"$T/ours" || rc=$?
    files=$((files + 1))
    slots=$((slots + $(wc -l <"$T/ours")))
    if [ "$rc" -ne 0 ] || ! cmp -s "$T/theirs" "$T/ours"; then
        echo "FAIL $f: exit $rc; first difference:"
        diff "$T/theirs" "$T/ours" | head -4
        fail=$((fail + 1))
    fi
done <"$T/corpus"
if [ "$files" -eq 0 ] || [ "$slots" -eq 0 ]; then
    echo "FAIL: compared $files dylibs and $slots rebases; comparing nothing is a failure"
    fail=$((fail + 1))
else
    echo "PASS $files dylibs, $slots rebases, each where and as dyldinfo has it"
fi

# The positive controls: with one of dyldinfo's rows gone, or two swapped, the
# comparison fails.
lib=/usr/lib/libz.1.dylib
lipo "$lib" -thin x86_64 -output "$T/thin" 2>/dev/null || cp "$lib" "$T/thin"
"$ORACLE" "$T/thin" >"$T/ours"
theirs "$T/thin" | awk 'NR != 3' >"$T/theirs"
if cmp -s "$T/theirs" "$T/ours"; then
    echo "FAIL the positive control: with dyldinfo's third row gone, the comparison still matched"
    fail=$((fail + 1))
else
    echo "PASS the positive control: a rebase dyldinfo does not have is a difference"
fi
theirs "$T/thin" | awk 'NR == 2 { held = $0; next } { print } NR == 3 { print held }' >"$T/theirs"
if cmp -s "$T/theirs" "$T/ours"; then
    echo "FAIL the positive control: with two of dyldinfo's rows swapped, the comparison still matched"
    fail=$((fail + 1))
else
    echo "PASS the positive control: the same rebases in another order is a difference"
fi

[ "$fail" -eq 0 ] || { echo "rebase_oracle_test: $fail failure(s)"; exit 1; }
echo "rebase_oracle_test: all passed"
