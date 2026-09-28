#!/bin/sh
# tests/raise_oracle_counts_test.sh -- over raise_corpus_test.sh's corpus, what
# each of a grow's four independent oracles (mg_oracles: inits, lazy, exports,
# unwind) says of every original, held to tests/data/raise_oracle_counts.tsv.
#
#   sh tests/raise_oracle_counts_test.sh <bindir>          compare with the table
#   sh tests/raise_oracle_counts_test.sh <bindir> update   rewrite the table
#
# An oracle that does not hold of an image before a grow is not asked after
# it, so a decoder slip that stops one holding turns it off without a word.
# Per oracle and file: "held", "skipped" (does not hold) or "nothing" (holds,
# with nothing to check).
#
# Local only: it SKIPs, saying why, unless this is the 10.9 build the table
# was measured on.
set -u

BIN="${1:?usage: raise_oracle_counts_test.sh <bindir> [update]}"
MODE="${2:-check}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TABLE="$HERE/data/raise_oracle_counts.tsv"
RC="$BIN/raise_corpus"
[ -x "$RC" ] || { echo "raise_oracle_counts_test: $RC not found or not executable" >&2; exit 1; }
[ -f /usr/lib/libSystem.B.dylib ] || { echo "SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own"; exit 77; }
build=$(sw_vers -buildVersion 2>/dev/null)
want=$(awk -F'\t' '$1 == "build" { print $2; exit }' "$TABLE" 2>/dev/null)
[ "$MODE" = update ] || [ "$build" = "$want" ] ||
    { echo "SKIP: the table pins Mac OS X build $want's files; this is ${build:-not Mac OS X}"; exit 77; }

T=$(mktemp -d "${TMPDIR:-/tmp}/raise-oracles.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

find /usr/lib /System/Library/Frameworks /System/Library/PrivateFrameworks -type f 2>/dev/null |
    LC_ALL=C sort | "$RC" list | "$RC" oracles >"$T/rows"
nu=$(grep -c " unreadable\$" "$T/rows")
[ "$nu" -eq 0 ] || bad "$nu file(s)" "raise_corpus could not read them: $(grep " unreadable\$" "$T/rows" | head -3 | tr "\\n" " ")"

{
    printf 'build\t%s\n' "$build"
    printf 'count\tfiles\t%s\n' "$(wc -l <"$T/rows" | tr -d ' ')"
    for o in inits lazy exports unwind; do
        for v in held skipped nothing; do
            printf 'count\t%s %s\t%s\n' "$o" "$v" "$(grep -c " $o=$v" "$T/rows")"
        done
    done
    printf 'count\tall four hold\t%s\n' "$(grep -vc '=skipped' "$T/rows")"
    sed 's/^/file	/' "$T/rows"
} >"$T/table"

if [ "$MODE" = update ]; then
    { echo "# written by: sh tests/raise_oracle_counts_test.sh <bindir> update -- say in the commit why a row changed"
      cat "$T/table"; } >"$TABLE" && echo "raise_oracle_counts_test: wrote $TABLE"
    exit 0
fi

grep -v '^#' "$TABLE" >"$T/want"
if diff "$T/want" "$T/table" >"$T/diff"; then
    echo "PASS $(awk -F'\t' '$1 == "count" { printf "%s: %s, ", $2, $3 }' "$T/table")as the table has them"
else
    bad "the table" "what the oracles say differs from $TABLE (< the table, > this run):"
    head -40 "$T/diff"
fi

# The positive control: one file's oracle turned off is a difference.
awk 'BEGIN { FS = OFS = "\t" } $1 == "file" && !d && sub(/ exports=held/, " exports=skipped") { d = 1 } { print }' \
    "$T/table" >"$T/changed"
if cmp -s "$T/table" "$T/changed" || diff "$T/want" "$T/changed" >/dev/null; then
    bad "the positive control" "with one file's export oracle turned off, the comparison still matched"
else
    echo "PASS the positive control: one file's export oracle turned off is a difference"
fi

[ "$fail" -eq 0 ] || { echo "raise_oracle_counts_test: $fail failure(s)"; exit 1; }
echo "raise_oracle_counts_test: all passed"
