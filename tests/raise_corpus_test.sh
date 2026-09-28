#!/bin/sh
# tests/raise_corpus_test.sh -- raise a copy of every x86_64 dylib and bundle
# under 10.9's /usr/lib, /System/Library/Frameworks and
# /System/Library/PrivateFrameworks, and hold what happens to
# tests/data/raise_corpus.tsv: per file, the exit status and the announcement
# or the first refusal, and the counts of each.
#
#   sh tests/raise_corpus_test.sh <bindir>          compare with the table
#   sh tests/raise_corpus_test.sh <bindir> update   rewrite the table
#
# Each copy gets enough 900-byte LC_RPATHs to outgrow its pad, then loses them
# again, so the raise is the only lasting change. A raised copy must announce
# the raise and pass `verify`; a refused one must leave no output; every tenth
# raised copy must re-sign on 10.9 by `info`'s verdict. A change to any row is
# a failure until the table is updated on purpose.
#
# Local only: it SKIPs, saying why, unless this is the 10.9 build the table
# was measured on.
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
    LC_ALL=C sort | "$RC" list >"$T/corpus"

fill=$(printf '%0890d' 0)
raised=0
: >"$T/rows"
while IFS= read -r f; do
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
    printf 'file\t%s\t%s\t%s\n' "$f" "$rc" "$said" >>"$T/rows"
done <"$T/corpus"

# The counts, derived from the rows; the table holds both, so a row changed
# without its count, or a count without its rows, is a difference too.
reason() { sed 's/^ERROR: //; s/0x[0-9a-f]*/0x#/g; s/[(;,].*//; s/ *$//'; }
{
    printf 'build\t%s\n' "$build"
    printf 'count\tfiles\t%s\n' "$(wc -l <"$T/rows" | tr -d ' ')"
    printf 'count\traised\t%s\n' "$(awk -F'\t' '$3 == 0' "$T/rows" | wc -l | tr -d ' ')"
    printf 'count\trefused\t%s\n' "$(awk -F'\t' '$3 != 0' "$T/rows" | wc -l | tr -d ' ')"
    printf 'count\tdropped split info\t%s\n' "$(grep -c 'dropped LC_SEGMENT_SPLIT_INFO' "$T/rows")"
    printf 'count\trepaired references\t%s\n' "$(grep -c '; repaired [0-9]* reference' "$T/rows")"
    printf 'count\treferences repaired\t%s\n' \
        "$(grep -o '; repaired [0-9]* reference' "$T/rows" | awk '{ s += $3 } END { print s + 0 }')"
    awk -F'\t' '$3 != 0 { print $4 }' "$T/rows" | reason | LC_ALL=C sort | uniq -c |
        awk '{ n = $1; sub(/^ *[0-9]+ /, ""); printf "reason\t%s\t%s\n", n, $0 }'
    cat "$T/rows"
} >"$T/table"

if [ "$MODE" = update ]; then
    { echo "# written by: sh tests/raise_corpus_test.sh <bindir> update -- say in the commit why a row changed"
      cat "$T/table"; } >"$TABLE" && echo "raise_corpus_test: wrote $TABLE"
    exit 0
fi

grep -v '^#' "$TABLE" >"$T/want"
if diff "$T/want" "$T/table" >"$T/diff"; then
    echo "PASS $(awk -F'\t' '$1 == "count" { printf "%s %s, ", $3, $2 }' "$T/table")as the table has them"
else
    bad "the table" "what happened differs from $TABLE (< the table, > this run):"
    head -40 "$T/diff"
fi
nres=$(wc -l <"$T/resigned" 2>/dev/null | tr -d ' ')
[ "${nres:-0}" -ge 100 ] && echo "PASS $nres raised copies (every tenth) re-sign on 10.9" ||
    bad "resign" "only ${nres:-0} raised copies were checked; a sample under 100 means little"

# The positive control: the comparison sees a single changed row.
awk -F'\t' 'BEGIN { OFS = "\t" } $1 == "file" && !done { $3 = 9; done = 1 } { print }' "$T/table" >"$T/changed"
if diff "$T/want" "$T/changed" >/dev/null; then
    bad "the positive control" "with one row's exit status changed, the comparison still matched"
else
    echo "PASS the positive control: one row's exit status changed is a difference"
fi

[ "$fail" -eq 0 ] || { echo "raise_corpus_test: $fail failure(s)"; exit 1; }
echo "raise_corpus_test: all passed"
