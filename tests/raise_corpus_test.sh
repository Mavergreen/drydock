#!/bin/sh
# tests/raise_corpus_test.sh -- raise a copy of every x86_64 dylib and bundle
# under 10.9's /usr/lib, /System/Library/Frameworks and
# /System/Library/PrivateFrameworks, and hold what happens to
# tests/data/raise_corpus.tsv: per file, the sha256 of its x86_64 slice, the
# exit status and the announcement or the first refusal, and the counts of
# each.
#
#   sh tests/raise_corpus_test.sh <bindir>          compare with the table
#   sh tests/raise_corpus_test.sh <bindir> update   rewrite the table
#
# Each copy gets enough 900-byte LC_RPATHs to outgrow its pad, then loses them
# again, so the raise is the only lasting change. A raised copy must announce
# the raise and pass `verify`; a refused one must leave no output; every tenth
# raised copy must re-sign on 10.9 by `info`'s verdict.
#
# Rows are keyed on contents (tests/golden_match.awk): only a file whose
# slice has the sha256 the table holds is compared, and a change to such a
# row is a failure until the table is updated on purpose. A file missing,
# added, or with other contents (an update to Safari, iTunes or the command
# line tools replaces some) is reported, not failed. The counts compared are
# those of the matched rows; when every row matches, the table's own count
# lines must match too.
#
# Local only: it SKIPs, saying why, unless this is the 10.9 build the table
# was measured on, and unless at least half the table's files are here with
# the contents it was measured on: below that, it is not this corpus.
set -u

BIN="${1:?usage: raise_corpus_test.sh <bindir> [update]}"
MODE="${2:-check}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TABLE="$HERE/data/raise_corpus.tsv"
DMR="$BIN/drydock-macho-rewrite"
RC="$BIN/raise_corpus"
for x in "$DMR" "$RC"; do
    [ -x "$x" ] || { echo "raise_corpus_test: $x not found or not executable" >&2; exit 1; }
done
[ -f /usr/lib/libSystem.B.dylib ] || { echo "SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own"; exit 77; }
build=$(sw_vers -buildVersion 2>/dev/null)
want=$(awk -F'\t' '$1 == "build" { print $2; exit }' "$TABLE" 2>/dev/null)
[ "$MODE" = update ] || [ "$build" = "$want" ] ||
    { echo "SKIP: the table pins Mac OS X build $want's files; this is ${build:-not Mac OS X}"; exit 77; }

T=$(mktemp -d "${TMPDIR:-/tmp}/raise-corpus.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

find /usr/lib /System/Library/Frameworks /System/Library/PrivateFrameworks -type f 2>/dev/null |
    LC_ALL=C sort | "$RC" list | "$RC" shas >"$T/corpus"

tab=$(printf '\t')
fill=$(printf '%0890d' 0)
raised=0
: >"$T/rows"
while IFS="$tab" read -r f sha; do
    rm -f "$T/in" "$T/out"
    "$RC" thin "$f" "$T/in" || { bad "$f" "no x86_64 slice to raise"; continue; }
    info=$("$DMR" info "$T/in" 2>/dev/null)
    pad=$(printf '%s\n' "$info" | awk '/^header pad: / { print $3; exit }')
    n=$(( ${pad:-0} / 900 + 2 ))
    {
        printf '%s\n' "$info" | grep -q ' LC_CODE_SIGNATURE ' && echo 'load-command delete codesig'
        i=0; while [ "$i" -lt "$n" ]; do echo "rpath append /nonexistent/raise-$i/$fill"; i=$((i + 1)); done
        i=0; while [ "$i" -lt "$n" ]; do echo "rpath delete /nonexistent/raise-$i/$fill"; i=$((i + 1)); done
    } >"$T/edits"
    rc=0; "$DMR" "$T/in" "$T/out" <"$T/edits" >/dev/null 2>"$T/err" || rc=$?
    if [ "$rc" -eq 0 ]; then
        said=$(sed -n "s|^$T/in: \(grew the header pad by [0-9]* bytes .*; contents raised by 0x[0-9a-f]*; new UUID.*\)|\1|p" "$T/err" | head -1)
        [ -n "$said" ] || { bad "$f" "raised without announcing it"; said="(no announcement)"; }
        "$DMR" verify "$T/out" >/dev/null 2>&1 || bad "$f" "the raised copy does not verify"
        raised=$((raised + 1))
        if [ $((raised % 10)) -eq 1 ]; then
            v=$("$DMR" info "$T/out" 2>/dev/null | sed -n 's/^resign 10\.9: //p')
            [ "$v" = ok ] && echo "$f" >>"$T/resigned" || bad "$f" "the raised copy would not re-sign: resign 10.9: $v"
        fi
    else
        said=$(sed -n '/^ERROR: /{p;q;}' "$T/err")
        [ -n "$said" ] || said="(exit $rc, no ERROR line)"
        [ ! -e "$T/out" ] || bad "$f" "refused (exit $rc) and wrote its output anyway"
    fi
    printf 'file\t%s\t%s\t%s\t%s\n' "$f" "$sha" "$rc" "$said" >>"$T/rows"
done <"$T/corpus"

# table ROWS: the counts derived from ROWS, then ROWS.
reason() { sed 's/^ERROR: //; s/0x[0-9a-f]*/0x#/g; s/[(;,].*//; s/ *$//'; }
table() {
    printf 'count\tfiles\t%s\n' "$(wc -l <"$1" | tr -d ' ')"
    printf 'count\traised\t%s\n' "$(awk -F'\t' '$4 == 0' "$1" | wc -l | tr -d ' ')"
    printf 'count\trefused\t%s\n' "$(awk -F'\t' '$4 != 0' "$1" | wc -l | tr -d ' ')"
    printf 'count\tdropped split info\t%s\n' "$(grep -c 'dropped LC_SEGMENT_SPLIT_INFO' "$1")"
    printf 'count\trepaired references\t%s\n' "$(grep -c '; repaired [0-9]* reference' "$1")"
    printf 'count\treferences repaired\t%s\n' \
        "$(grep -o '; repaired [0-9]* reference' "$1" | awk '{ s += $3 } END { print s + 0 }')"
    awk -F'\t' '$4 != 0 { print $5 }' "$1" | reason | LC_ALL=C sort | uniq -c |
        awk '{ n = $1; sub(/^ *[0-9]+ /, ""); printf "reason\t%s\t%s\n", n, $0 }'
    cat "$1"
}

if [ "$MODE" = update ]; then
    { echo "# written by: sh tests/raise_corpus_test.sh <bindir> update -- say in the commit why a row changed"
      printf 'build\t%s\n' "$build"
      table "$T/rows"; } >"$TABLE" && echo "raise_corpus_test: wrote $TABLE"
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
    echo "PASS $(awk -F'\t' '$1 == "count" { printf "%s %s, ", $3, $2 }' "$T/got")as the table has them, of the $matched files it was measured on"
else
    bad "the table" "what happened to the files it was measured on differs from $TABLE (< the table, > this run):"
    head -40 "$T/diff"
fi
if [ $((missing + added + changed)) -eq 0 ]; then
    grep -v '^#' "$TABLE" | grep -v '^build	' | grep -v '^file	' >"$T/wantc"
    table "$T/rows" | grep -v '^file	' >"$T/gotc"
    diff "$T/wantc" "$T/gotc" >/dev/null && echo "PASS every file matched, and so do the table's own counts" ||
        bad "the table's counts" "every file matched, but its count lines do not: $(diff "$T/wantc" "$T/gotc" | head -6 | tr '\n' ' ')"
fi
nres=$(wc -l <"$T/resigned" 2>/dev/null | tr -d ' ')
[ "${nres:-0}" -ge 100 ] && echo "PASS $nres raised copies (every tenth) re-sign on 10.9" ||
    bad "resign" "only ${nres:-0} raised copies were checked; a sample under 100 means little"

# The positive controls: a matched row's exit status changed is a difference,
# and a row whose contents changed is reported, not compared.
awk -F'\t' 'BEGIN { OFS = "\t" } !done { $4 = 9; done = 1 } { print }' "$T/rm" >"$T/rm9"
table "$T/rm9" >"$T/got9"
if diff "$T/want" "$T/got9" >/dev/null; then
    bad "the positive control" "with one row's exit status changed, the comparison still matched"
else
    echo "PASS the positive control: one row's exit status changed is a difference"
fi
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "file" && !done { $3 = (substr($3, 1, 1) == "0" ? "1" : "0") substr($3, 2); $4 = 9; done = 1 } { print }' \
    "$T/rows" >"$T/rows9"
awk -f "$HERE/golden_match.awk" -v tm="$T/tm9" -v rm="$T/rm9" "$TABLE" "$T/rows9" >"$T/match9"
if grep -q '^INFO changed: ' "$T/match9" && ! grep -q '	9	' "$T/rm9"; then
    echo "PASS the positive control: a file with other contents is reported as changed, and not compared"
else
    bad "the positive control" "a file with other contents was compared, or not reported"
fi

[ "$fail" -eq 0 ] || { echo "raise_corpus_test: $fail failure(s)"; exit 1; }
echo "raise_corpus_test: all passed"
