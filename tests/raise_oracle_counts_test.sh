#!/bin/sh
# tests/raise_oracle_counts_test.sh -- over raise_corpus_test.sh's corpus, what
# each of a grow's five independent oracles (mg_oracles: inits, lazy, exports,
# unwind, rebases) says of every original, held to
# tests/data/raise_oracle_counts.tsv.
#
#   sh tests/raise_oracle_counts_test.sh <bindir>          compare with the table
#   sh tests/raise_oracle_counts_test.sh <bindir> update   rewrite the table
#   sh tests/raise_oracle_counts_test.sh <bindir> recount  rewrite its count lines from its rows
#
# An oracle that does not hold of an image before a grow is not asked after
# it, so a decoder slip that stops one holding turns it off without a word.
# Per oracle and file: "held", "skipped" (does not hold) or "nothing" (holds,
# with nothing to check).
#
# Rows are keyed on the sha256 of each file's x86_64 slice, as
# raise_corpus_test.sh's are (tests/golden_match.awk): only unchanged files
# are compared, the counts compared are those of the matched rows, and a file
# missing, added or changed is reported, not failed.
#
# Local only: it SKIPs, saying why, unless this is the 10.9 build the table
# was measured on, and unless at least half the table's files are here with
# the contents it was measured on.
set -u

BIN="${1:?usage: raise_oracle_counts_test.sh <bindir> [update|recount]}"
MODE="${2:-check}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TABLE="$HERE/data/raise_oracle_counts.tsv"
RC="$BIN/raise_corpus"
[ -x "$RC" ] || { echo "raise_oracle_counts_test: $RC not found or not executable" >&2; exit 1; }
[ -f /usr/lib/libSystem.B.dylib ] || { echo "SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own"; exit 77; }
build=$(sw_vers -buildVersion 2>/dev/null)
want=$(awk -F'\t' '$1 == "build" { print $2; exit }' "$TABLE" 2>/dev/null)
[ "$MODE" != check ] || [ "$build" = "$want" ] ||
    { echo "SKIP: the table pins Mac OS X build $want's files; this is ${build:-not Mac OS X}"; exit 77; }

T=$(mktemp -d "${TMPDIR:-/tmp}/raise-oracles.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# table ROWS: the counts derived from ROWS, then ROWS.
table() {
    printf 'count\tfiles\t%s\n' "$(wc -l <"$1" | tr -d ' ')"
    for o in inits lazy exports unwind rebases; do
        for v in held skipped nothing; do
            printf 'count\t%s %s\t%s\n' "$o" "$v" "$(grep -c "[	 ]$o=$v" "$1")"
        done
    done
    printf 'count\tall five hold\t%s\n' "$(grep -vc '=skipped' "$1")"
    cat "$1"
}

if [ "$MODE" = recount ]; then
    grep '^file	' "$TABLE" >"$T/rows"
    { grep -v -e '^count	' -e '^file	' "$TABLE"; table "$T/rows"; } >"$T/new" && cp "$T/new" "$TABLE" &&
        echo "raise_oracle_counts_test: recounted $TABLE"
    exit 0
fi

find /usr/lib /System/Library/Frameworks /System/Library/PrivateFrameworks -type f 2>/dev/null |
    LC_ALL=C sort | "$RC" list | "$RC" oracles | sed 's/^/file	/' >"$T/rows"
nu=$(grep -c "	unreadable\$" "$T/rows")
[ "$nu" -eq 0 ] || bad "$nu file(s)" "raise_corpus could not read them: $(grep "	unreadable\$" "$T/rows" | head -3 | tr "\\n" " ")"

if [ "$MODE" = update ]; then
    { echo "# written by: sh tests/raise_oracle_counts_test.sh <bindir> update -- say in the commit why a row changed"
      printf 'build\t%s\n' "$build"
      table "$T/rows"; } >"$TABLE" && echo "raise_oracle_counts_test: wrote $TABLE"
    exit 0
fi

awk -f "$HERE/golden_match.awk" -v tm="$T/tm" -v rm="$T/rm" "$TABLE" "$T/rows" >"$T/match"
set -- $(tail -1 "$T/match")
matched=$2 total=$4 missing=$8 added=${10} changed=${12}
sed '$d' "$T/match"
echo "INFO $(tail -1 "$T/match")"
if [ $((matched * 2)) -lt "$total" ]; then
    echo "SKIP: only $matched of the table's $total files are here with the contents it was measured on; below half, this is not its corpus"
    exit 77
fi
table "$T/tm" >"$T/want"
table "$T/rm" >"$T/got"
if diff "$T/want" "$T/got" >"$T/diff"; then
    echo "PASS $(awk -F'\t' '$1 == "count" { printf "%s: %s, ", $2, $3 }' "$T/got")as the table has them, of the $matched files it was measured on"
else
    bad "the table" "what the oracles say of the files it was measured on differs from $TABLE (< the table, > this run):"
    head -40 "$T/diff"
fi
if [ $((missing + added + changed)) -eq 0 ]; then
    grep '^count	' "$TABLE" >"$T/wantc"
    table "$T/rows" | grep '^count	' >"$T/gotc"
    diff "$T/wantc" "$T/gotc" >/dev/null && echo "PASS every file matched, and so do the table's own counts" ||
        bad "the table's counts" "every file matched, but its count lines do not: $(diff "$T/wantc" "$T/gotc" | head -6 | tr '\n' ' ')"
fi

# The positive control: one matched file's oracle turned off is a difference.
awk 'BEGIN { FS = OFS = "\t" } !d && sub(/ exports=held/, " exports=skipped") { d = 1 } { print }' \
    "$T/rm" >"$T/rm9"
table "$T/rm9" >"$T/got9"
if cmp -s "$T/rm" "$T/rm9" || diff "$T/want" "$T/got9" >/dev/null; then
    bad "the positive control" "with one file's export oracle turned off, the comparison still matched"
else
    echo "PASS the positive control: one file's export oracle turned off is a difference"
fi

[ "$fail" -eq 0 ] || { echo "raise_oracle_counts_test: $fail failure(s)"; exit 1; }
echo "raise_oracle_counts_test: all passed"
