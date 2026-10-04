#!/bin/sh
# tests/hdrref_table_rule_test.sh -- what src/hdrref.c's jump-table rule
# changes over this host's own Mach-Os, by tests/hdrref_ab: the x86_64 slice
# of every dylib and bundle under /usr/lib, /System/Library/Frameworks and
# /System/Library/PrivateFrameworks, and every MH_EXECUTE under /Applications,
# /System/Library/CoreServices, /bin, /sbin, /usr/bin, /usr/libexec and
# /usr/sbin, each read in memory and never written.
#
#   (a) mhr_confirm's answer and bad.addr, for a grow's header, are the same
#       with the rule and without it, in every file;
#   (b) over every target, the rule changes a verdict only from MHR_CONFIRMED
#       to MHR_UNCONFIRMED, and both walks pass the same candidates;
#   (c) it changes at least one, or the build without it is not without it.
#
# Local only: it SKIPs, saying why, anywhere but Mac OS X 10.9 on x86_64.
set -u

BIN="${1:?usage: hdrref_table_rule_test.sh <bindir>}"
AB="$BIN/hdrref_ab"
[ -x "$AB" ] || { echo "hdrref_table_rule_test: $AB not found or not executable" >&2; exit 1; }
[ -f /usr/lib/libSystem.B.dylib ] || { echo "SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own"; exit 77; }
os=$(sw_vers -productVersion 2>/dev/null)
case "$os" in
    10.9|10.9.*) ;;
    *) echo "SKIP: the corpus is Mac OS X 10.9's binaries; this is ${os:-not Mac OS X}"; exit 77 ;;
esac
[ "$(uname -m)" = x86_64 ] || { echo "SKIP: the corpus is x86_64 slices run here; this is $(uname -m)"; exit 77; }

T=$(mktemp -d "${TMPDIR:-/tmp}/hdrref-table.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

find /usr/lib /System/Library/Frameworks /System/Library/PrivateFrameworks -type f 2>/dev/null |
    LC_ALL=C sort | "$AB" dylibs >"$T/out" || { echo "FAIL: hdrref_ab dylibs exited nonzero"; exit 1; }
find /Applications /System/Library/CoreServices /bin /sbin /usr/bin /usr/libexec /usr/sbin \
    -type f 2>/dev/null | LC_ALL=C sort | "$AB" execs >>"$T/out" ||
    { echo "FAIL: hdrref_ab execs exited nonzero"; exit 1; }

awk -F'\t' '
    $1 == "F" {
        files++; cands += $9
        if ($3 != $5 || $4 != $6) { print "FAIL (a) " $2 ": mhr_confirm answers " $3 " at 0x" $4 " with the rule, " $5 " at 0x" $6 " without"; fail++ }
        if ($7 != $8) { print "FAIL (b) " $2 ": mhr_confirm_each answers " $7 " with the rule, " $8 " without"; fail++ }
    }
    $1 == "X" { print "FAIL (b) " $2 ": the two walks part at candidate " $3; fail++ }
    $1 == "D" {
        changed++; if (!($2 in seen)) { seen[$2] = 1; cfiles++ }
        if ($6 != 3 || $7 != 0) { print "FAIL (b) " $2 ": the candidate at 0x" $3 " is " $7 " without the rule and " $6 " with it, not CONFIRMED (0) then UNCONFIRMED (3)"; fail++ }
    }
    END {
        printf "%d files, %d candidates; the rule changes %d verdicts, in %d files\n", files, cands, changed, cfiles
        if (files == 0) { print "FAIL: no file was read"; fail++ }
        if (changed == 0) { print "FAIL (c): the rule changed no verdict, so the build without it is not without it"; fail++ }
        if (fail) { printf "hdrref_table_rule_test: %d failure(s)\n", fail; exit 1 }
        print "hdrref_table_rule_test: (a), (b) and (c) hold"
    }' "$T/out"
