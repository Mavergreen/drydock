#!/bin/sh
# platform: macOS-only -- reruns the analyzer on binaries built on the maintainer's 10.9 box
#   usage: compare.sh BASELINE_DIR DRYDOCK_OBJC
#          Proves moving shipyard's Objective-C analyzer into Drydock changed no verdict. For each
#          artifact record.sh recorded in BASELINE_DIR, it checks the artifact's SHA-256 still equals
#          INPUTS, reruns the artifact through DRYDOCK_OBJC analyze with record.sh's arguments, and
#          compares the exit status and the report with the baseline's. The reports are compared
#          byte for byte after blanking one value in each: the "analyzer" key's, which names the
#          analyzer's source (objc-compat-src-* before, drydock-*-objc-src-* after). Nothing else is
#          altered. Any other difference fails and prints its diff.
#          Environment: COMPARE_PROVIDER_PREFIX (or CODEX_DEV_RECAULK_PREFIX; required: INPUTS does not
#          record the provider prefix codex-rebuilt was analyzed with), COMPARE_REFERENCES (the reference set, instead of the one beside the shipyard
#          INPUTS names; a negative control points it at an edited copy), COMPARE_WORK (scratch
#          directory, default a fresh mktemp one, removed on exit unless set).
#          Exit 0 identical, 1 a difference, 2 usage, 4 a stale or missing baseline or input.
#          Prints "compare: N of N identical apart from analyzer identity" on success.
set -eu

usage() { echo "usage: compare.sh BASELINE_DIR DRYDOCK_OBJC" >&2; exit 2; }
[ $# -eq 2 ] || usage
BASELINE_DIR=$(CDPATH= cd -- "$1" 2>/dev/null && pwd) || { echo "compare.sh: no $1" >&2; exit 4; }
DRYDOCK_OBJC=$2
[ -x "$DRYDOCK_OBJC" ] || { echo "compare.sh: no executable $DRYDOCK_OBJC" >&2; exit 4; }
fail() { echo "compare.sh: $*" >&2; exit 4; }
sha() { shasum -a 256 "$1" | cut -c1-64; }

INPUTS="$BASELINE_DIR/INPUTS"
[ -f "$INPUTS" ] || fail "no $INPUTS"
tab=$(printf '\t')
field() { awk -F "$tab" -v k="$1" -v n="$2" '$1 == k { print $n; exit }' "$INPUTS"; }

SHIPYARD_SCRIPTS=$(field shipyard 3)
[ -n "$SHIPYARD_SCRIPTS" ] || fail "$INPUTS names no shipyard"
REFS=${COMPARE_REFERENCES:-$SHIPYARD_SCRIPTS/../reference/objc}
REFS=$(CDPATH= cd -- "$REFS" 2>/dev/null && pwd) || fail "no reference set $REFS"

if [ -n "${COMPARE_WORK:-}" ]; then
  WORK=$COMPARE_WORK; mkdir -p "$WORK"
else
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/compare.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
fi

# the baseline is stale if any recorded input changed
RECEIPT=$(field source-receipt 3)
for name in codex-rebuilt code-mode-host alacritty-probe; do
  art=$(field "$name" 3); want=$(field "$name" 2)
  [ -f "$art" ] || fail "baseline is stale: no $art"
  [ "$(sha "$art")" = "$want" ] || fail "baseline is stale: $art no longer has SHA-256 $want"
done
if [ -n "$RECEIPT" ]; then
  [ -f "$RECEIPT" ] || fail "baseline is stale: no $RECEIPT"
  [ "$(sha "$RECEIPT")" = "$(field source-receipt 2)" ] || fail "baseline is stale: $RECEIPT changed"
fi

# blank only the "analyzer" key's value: the report is JSON with that key appearing once
blank() {
  n=$(grep -c '"analyzer": "' "$1" || true)
  [ "$n" = 1 ] || { echo "compare.sh: $1 has $n analyzer keys, not 1" >&2; return 1; }
  sed 's/"analyzer": "[^"]*"/"analyzer": ""/' "$1" > "$2"
}

# spec: record.sh -- the same arguments per artifact; the compiled analyzer id applies
NATIVE=$(dirname "$(field codex-rebuilt 3)")
EVIDENCE=$(dirname "$NATIVE")/objc-native/evidence
status=0; total=0; same=0
check() {
  name=$1; art=$2; shift 2
  total=$((total + 1))
  [ -f "$BASELINE_DIR/$name.objc-compat.json" ] || fail "no baseline report for $name"
  rc=0
  "$DRYDOCK_OBJC" analyze --artifact "$art" --root "$(dirname "$art")" --references "$REFS" \
    --report "$WORK/$name.json" --mode strict "$@" 2> "$WORK/$name.stderr" || rc=$?
  was=$(cat "$BASELINE_DIR/$name.exit")
  ok=1
  if [ "$rc" != "$was" ]; then
    echo "compare: $name: exit $rc, baseline $was" >&2; ok=0
  fi
  if [ ! -f "$WORK/$name.json" ]; then
    echo "compare: $name: no report written" >&2; ok=0
  else
    blank "$BASELINE_DIR/$name.objc-compat.json" "$WORK/$name.base" || ok=0
    blank "$WORK/$name.json" "$WORK/$name.new" || ok=0
    if [ -f "$WORK/$name.new" ] && ! cmp -s "$WORK/$name.base" "$WORK/$name.new"; then
      echo "compare: $name: reports differ:" >&2
      diff "$WORK/$name.base" "$WORK/$name.new" | cut -c1-300 | head -40 >&2 || true
      ok=0
    fi
  fi
  if [ "$ok" = 1 ]; then
    same=$((same + 1)); echo "compare: $name: exit $rc, identical apart from analyzer identity"
  else
    status=1; echo "compare: $name: DIFFERS" >&2
  fi
}

# INPUTS does not hold the provider prefix record.sh took from fetch-recaulk-objc.sh: name it
if [ -n "$RECEIPT" ]; then
  PREFIX=${COMPARE_PROVIDER_PREFIX:-${CODEX_DEV_RECAULK_PREFIX:-}}
  [ -n "$PREFIX" ] && [ -d "$PREFIX" ] || fail "no provider prefix: set COMPARE_PROVIDER_PREFIX to the one record.sh used"
  check codex-rebuilt "$NATIVE/codex" --build-evidence "$EVIDENCE/codex.json" --provider-prefix "$PREFIX" --source-receipt "$RECEIPT"
else
  fail "INPUTS holds no source-receipt, so codex-rebuilt's provider prefix is unknown"
fi
check code-mode-host "$(field code-mode-host 3)" --build-evidence "$EVIDENCE/codex-code-mode-host.json"
check alacritty-probe "$(field alacritty-probe 3)"

if [ "$status" = 0 ]; then
  echo "compare: $same of $total identical apart from analyzer identity"
else
  echo "compare: only $same of $total identical apart from analyzer identity" >&2
fi
exit "$status"
