#!/bin/sh
# platform: host-agnostic -- git grep over the checkout; needs a real git, which stock 10.9 lacks (not-in-guest).
#   The control's launches live in tests/data/arch-launch-probes.txt, which the family's Rosetta scan does not read.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PATTERN='arch[[:space:]]+-(x86_64|arm64)'
PROBES=tests/data/arch-launch-probes.txt

rc=0
leftovers=$(git -C "$ROOT" grep -n -E "$PATTERN" -- tests ":!$PROBES") || rc=$?
[ "$rc" -le 1 ] || { echo "FAIL git grep exited $rc: the sweep could not run"; exit 1; }
[ -z "$leftovers" ] || { echo "FAIL a test launches through arch(1) with -x86_64 or -arm64: $leftovers"; exit 1; }
echo "ok no test launches through arch(1) with -x86_64 or -arm64"

n=$(git -C "$ROOT" grep -c -E "$PATTERN" -- "$PROBES" | cut -d: -f2)
[ "$n" = 3 ] || { echo "FAIL the sweep sees ${n:-0} of the 3 launches in $PROBES"; exit 1; }
echo "ok the sweep sees both launches in $PROBES"
