#!/bin/sh
# platform: host-agnostic -- analyzes objects committed under tests/objc/parity/, built on 10.9 by the pinned clang22 against the pinned 10.9 SDK
# spec: src/objc/main.c header -- host-independent bytes: fixtures from each suite (report, classification, closure,
#       guard-evidence, provider, attest, regexec), each analyzed in inventory mode against the committed reference
#       set under a pinned analyzer id, gives the report whose sha256 tests/objc/parity/digests.tsv holds.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
PAR="$HERE/parity"
B="$PAR/root/bin"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-report-parity-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
row() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$2"; }

# NAME:EXIT, where 4 (cannot measure) still writes a report: a class_addMethod outside any declared provider, or
# selectors and classes computed where the analyzer reads only literals.
CORPUS='body:0 classify:0 merged:0 r2:0 closure:0 guard-coverage:0 provider:4 sweep:0 table-provider:4 launder:4'

[ "$(wc -l <"$PAR/digests.tsv" | tr -d ' ')" = 10 ] || fail "$PAR/digests.tsv has not one row for each of the 10 fixtures"
bad=0
for e in $CORPUS; do
  n=${e%:*} x=${e#*:}
  [ -f "$B/$n" ] || fail "$B/$n is missing"
  set --
  [ "$n" != body ] || set -- --build-evidence "$PAR/body.evidence" --provider-prefix "$PAR/pfx" --source-receipt "$PAR/pfx.receipt"
  rc=0
  "$DRYDOCK_OBJC" analyze --artifact "$B/$n" --root "$PAR/root" --references "$ROOT/reference/objc" --mode inventory \
    --analyzer-id drydock-objc-parity --report "$T/$n.json" "$@" 2>"$T/err" || rc=$?
  [ "$rc" = "$x" ] || fail "$n: analyze exited $rc, want $x: $(tail -3 "$T/err")"
  want=$(row "$n" "$PAR/digests.tsv") got=$(sha "$T/$n.json")
  if [ "$got" != "$want" ]; then
    echo "FAIL: $n: its report's sha256 is $got here, and digests.tsv says $want. The fixtures are committed under tests/objc/parity/, built on 10.9, so that reports are compared on identical inputs whatever host compiler is installed: a mismatch means the analyzer's report changed, or a committed object did. To regenerate them, rebuild on 10.9 (objc_parity_build.sh builds them), commit the objects, then regenerate digests.tsv in a commit that says what changed" >&2
    bad=1; continue
  fi
  echo "PASS: $n: report $got"
done
[ "$bad" = 0 ] || exit 1

# platform: informational only -- where clang22 and the receipt clang are fetchable, rebuild the fixtures from tests/objc/fixtures and say
#           which committed files that compiler no longer reproduces; a compiler that cannot be had here, or one that has moved, never fails the test.
if sh "$HERE/lib/objc_parity_build.sh" "$T/rebuilt" >"$T/rebuild.out" 2>"$T/rebuild.err"; then
  drift=
  for f in $(cd "$PAR" && find root pfx body.evidence pfx.receipt -type f | sort); do
    cmp -s "$PAR/$f" "$T/rebuilt/$f" || drift="$drift $f"
  done
  if [ -n "$drift" ]; then echo "NOTE: the compiler here builds these fixtures differently from the committed objects (not a failure):$drift"
  else echo "NOTE: the compiler here rebuilds every committed fixture byte for byte"; fi
else
  echo "NOTE: drift check skipped, the fixtures cannot be rebuilt here: $(tail -1 "$T/rebuild.err")"
fi
