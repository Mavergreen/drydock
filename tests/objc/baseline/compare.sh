#!/bin/sh
# platform: macOS-only -- reruns the analyzer on binaries built on the maintainer's 10.9 box
#   usage: compare.sh BASELINE_DIR DRYDOCK_OBJC
#          Proves a change to the Objective-C analyzer or its reference set changed no verdict. For
#          each artifact record.sh (or record-artifacts.sh) recorded in BASELINE_DIR, it checks the
#          artifact's SHA-256 still equals INPUTS, reruns the artifact through DRYDOCK_OBJC analyze
#          with the recorded arguments, and compares the exit status and the report with the
#          baseline's. The reports are compared byte for byte after blanking two identities in each,
#          each of which must appear exactly once: the "analyzer" key's value, which names the
#          analyzer's source (objc-compat-src-* before, drydock-*-objc-src-* after), and the
#          "references" object's manifest_sha256 and file list, which name the reference set's
#          files and hashes (a regenerated set changes them, and may add a file). Nothing else is
#          altered. Any other difference fails and prints its diff.
#          A baseline whose INPUTS starts with a "drydock-objc" row (record-artifacts.sh) is rerun
#          from its "artifact" rows, each with its recorded provider prefix, against this
#          checkout's reference/objc unless COMPARE_REFERENCES names another set.
#          Environment: COMPARE_PROVIDER_PREFIX (or CODEX_DEV_RECAULK_PREFIX; required: INPUTS does not
#          record the provider prefix codex-rebuilt was analyzed with), COMPARE_REFERENCES (the reference set, instead of the one beside the shipyard
#          INPUTS names; a negative control points it at an edited copy), COMPARE_WORK (scratch
#          directory, default a fresh mktemp one, removed on exit unless set).
#          COMPARE_MODE=fewer-passed-arguments (default: identical) also lets a report's "errors" list,
#          its last key, lose indirect-objc-entry entries whose detail ends "is passed as an argument"
#          -- what bounding a call's argument registers by its declarations may remove
#          (src/objc/macho-reader.c "Argument registers") -- and nothing else: everything before
#          that list must still be byte for byte the baseline's after the blanking above, the remaining errors must be the
#          baseline's in the baseline's order, and no error may be new or changed. The exit status
#          must still match. Each artifact's line then says how many such errors it lost.
#          Exit 0 identical, 1 a difference, 2 usage, 4 a stale or missing baseline or input.
#          Prints "compare: N of N identical apart from analyzer and reference identity" on success.
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

# spec: record-artifacts.sh -- its INPUTS starts with a "drydock-objc" row
if [ "$(awk -F "$tab" 'NR == 1 { print $1 }' "$INPUTS")" = drydock-objc ]; then
  ARTIFACTS=1
  HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  REFS=${COMPARE_REFERENCES:-$HERE/../../../reference/objc}
else
  ARTIFACTS=0
  SHIPYARD_SCRIPTS=$(field shipyard 3)
  [ -n "$SHIPYARD_SCRIPTS" ] || fail "$INPUTS names no shipyard"
  REFS=${COMPARE_REFERENCES:-$SHIPYARD_SCRIPTS/../reference/objc}
fi
REFS=$(CDPATH= cd -- "$REFS" 2>/dev/null && pwd) || fail "no reference set $REFS"

if [ -n "${COMPARE_WORK:-}" ]; then
  WORK=$COMPARE_WORK; mkdir -p "$WORK"
else
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/compare.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
fi

# the baseline is stale if any recorded input changed
if [ "$ARTIFACTS" = 1 ]; then
  [ -n "$(awk -F "$tab" '$1 == "artifact"' "$INPUTS")" ] || fail "$INPUTS records no artifact"
  # spec: record-artifacts.sh -- artifact rows: NAME, SHA-256, path, provider prefix ("-" for none)
  awk -F "$tab" '$1 == "artifact" { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$INPUTS" > "$WORK/artifacts"
  while IFS="$tab" read -r name want art prefix; do
    [ -f "$art" ] || fail "baseline is stale: no $art"
    [ "$(sha "$art")" = "$want" ] || fail "baseline is stale: $art no longer has SHA-256 $want"
  done < "$WORK/artifacts"
fi
RECEIPT=$(field source-receipt 3)
[ "$ARTIFACTS" = 1 ] || for name in codex-rebuilt code-mode-host alacritty-probe; do
  art=$(field "$name" 3); want=$(field "$name" 2)
  [ -f "$art" ] || fail "baseline is stale: no $art"
  [ "$(sha "$art")" = "$want" ] || fail "baseline is stale: $art no longer has SHA-256 $want"
done
if [ -n "$RECEIPT" ]; then
  [ -f "$RECEIPT" ] || fail "baseline is stale: no $RECEIPT"
  [ "$(sha "$RECEIPT")" = "$(field source-receipt 2)" ] || fail "baseline is stale: $RECEIPT changed"
fi

# blank only the "analyzer" key's value and the "references" object's manifest_sha256 and file
# list: the report is JSON with each appearing once
REFS_RE='"references": {"manifest_sha256": "[0-9a-f]*", "files": \[[^]]*]}'
blank() {
  n=$(grep -c '"analyzer": "' "$1" || true)
  [ "$n" = 1 ] || { echo "compare.sh: $1 has $n analyzer keys, not 1" >&2; return 1; }
  n=$(grep -o "$REFS_RE" "$1" | wc -l | tr -d ' ')
  [ "$n" = 1 ] && [ "$(grep -c '"manifest_sha256": "' "$1")" = 1 ] ||
    { echo "compare.sh: $1 has $n references identities, not 1" >&2; return 1; }
  sed -e 's/"analyzer": "[^"]*"/"analyzer": ""/' \
      -e "s/$REFS_RE/\"references\": {\"manifest_sha256\": \"\", \"files\": []}/" "$1" > "$2"
}

MODE=${COMPARE_MODE:-identical}
case $MODE in identical|fewer-passed-arguments) ;; *) fail "unknown COMPARE_MODE $MODE" ;; esac

# split_errors REPORT HEAD ERRORS: HEAD gets REPORT up to and including the '"errors": [' that opens
# its last key, ERRORS one error object per line. The writer puts each error after the first on its
# own line, separated by ",<newline>  ", and closes the list with "]}"; a JSON string holds no raw newline.
split_errors() {
  awk -v head="$2" -v errs="$3" '
    { line[NR] = $0 }
    END {
      for (i = NR; i >= 1 && !(k = index(line[i], "\"errors\": [")); i--) ;
      if (!i) exit 1
      for (j = 1; j < i; j++) print line[j] > head
      print substr(line[i], 1, k + 10) > head
      rest[0] = substr(line[i], k + 11); n = 0
      for (j = i + 1; j <= NR; j++) rest[++n] = line[j]
      printf "" > errs
      for (j = 0; j <= n; j++) {
        e = rest[j]; sub(/^  /, "", e)
        if (e == "" && j < n) continue   # the list opens at the end of its line
        if (j == n) { if (!sub(/]}$/, "", e)) exit 1 } else if (!sub(/,$/, "", e)) exit 1
        if (e != "") print e > errs
      }
    }' "$1"
}

# fewer_passed BASE NEW: 0 when NEW's report differs from BASE's only by errors it lost whose detail ends
# "is passed as an argument"; prints how many. Otherwise 1, with what differs on stderr.
fewer_passed() {
  split_errors "$1" "$1.head" "$1.errs" && split_errors "$2" "$2.head" "$2.errs" ||
    { echo "compare.sh: $1 or $2 does not end in an errors list" >&2; return 1; }
  if ! cmp -s "$1.head" "$2.head"; then
    echo "compare: reports differ before their errors:" >&2
    diff "$1.head" "$2.head" | cut -c1-300 | head -40 >&2 || true
    return 1
  fi
  awk 'NR == FNR { base[++nb] = $0; next }
       function drop(e) { return e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "[^"]*is passed as an argument"}$/ }
       { for (q = p + 1; q <= nb && base[q] != $0; q++) ;
         if (q > nb) { print "compare: new, changed or reordered error " $0 > "/dev/stderr"; bad = 1; next }
         while (p + 1 < q) { if (!drop(base[++p])) { print "compare: lost error " base[p] > "/dev/stderr"; bad = 1 } else lost++ }
         p = q }
       END { while (p < nb) { if (!drop(base[++p])) { print "compare: lost error " base[p] > "/dev/stderr"; bad = 1 } else lost++ }
             if (bad) exit 1; print lost + 0 }' "$1.errs" "$2.errs"
}

status=0; total=0; same=0
check() {
  name=$1; art=$2; shift 2
  total=$((total + 1))
  [ -f "$BASELINE_DIR/$name.objc-compat.json" ] || fail "no baseline report for $name"
  rc=0
  "$DRYDOCK_OBJC" analyze --artifact "$art" --root "$(dirname "$art")" --references "$REFS" \
    --report "$WORK/$name.json" --mode strict "$@" 2> "$WORK/$name.stderr" || rc=$?
  was=$(cat "$BASELINE_DIR/$name.exit")
  ok=1; lost=0
  if [ "$rc" != "$was" ]; then
    echo "compare: $name: exit $rc, baseline $was" >&2; ok=0
  fi
  if [ ! -f "$WORK/$name.json" ]; then
    echo "compare: $name: no report written" >&2; ok=0
  else
    blank "$BASELINE_DIR/$name.objc-compat.json" "$WORK/$name.base" || ok=0
    blank "$WORK/$name.json" "$WORK/$name.new" || ok=0
    if [ -f "$WORK/$name.new" ] && ! cmp -s "$WORK/$name.base" "$WORK/$name.new"; then
      if [ "$MODE" = fewer-passed-arguments ]; then
        lost=$(fewer_passed "$WORK/$name.base" "$WORK/$name.new") || { echo "compare: $name: reports differ" >&2; ok=0; }
      else
        echo "compare: $name: reports differ:" >&2
        diff "$WORK/$name.base" "$WORK/$name.new" | cut -c1-300 | head -40 >&2 || true
        ok=0
      fi
    fi
  fi
  if [ "$ok" = 1 ] && [ "$lost" != 0 ]; then
    same=$((same + 1)); echo "compare: $name: exit $rc, identical apart from analyzer and reference identity and $lost fewer \"is passed as an argument\" errors"
  elif [ "$ok" = 1 ]; then
    same=$((same + 1)); echo "compare: $name: exit $rc, identical apart from analyzer and reference identity"
  else
    status=1; echo "compare: $name: DIFFERS" >&2
  fi
}

if [ "$ARTIFACTS" = 1 ]; then
  while IFS="$tab" read -r name want art prefix; do
    if [ "$prefix" = - ]; then check "$name" "$art" </dev/null
    else check "$name" "$art" --provider-prefix "$prefix" </dev/null; fi
  done < "$WORK/artifacts"
# INPUTS does not hold the provider prefix record.sh took from fetch-recaulk-objc.sh: name it
elif [ -n "$RECEIPT" ]; then
  # spec: record.sh -- the same arguments per artifact; the compiled analyzer id applies
  NATIVE=$(dirname "$(field codex-rebuilt 3)")
  EVIDENCE=$(dirname "$NATIVE")/objc-native/evidence
  PREFIX=${COMPARE_PROVIDER_PREFIX:-${CODEX_DEV_RECAULK_PREFIX:-}}
  [ -n "$PREFIX" ] && [ -d "$PREFIX" ] || fail "no provider prefix: set COMPARE_PROVIDER_PREFIX to the one record.sh used"
  check codex-rebuilt "$NATIVE/codex" --build-evidence "$EVIDENCE/codex.json" --provider-prefix "$PREFIX" --source-receipt "$RECEIPT"
  check code-mode-host "$(field code-mode-host 3)" --build-evidence "$EVIDENCE/codex-code-mode-host.json"
  check alacritty-probe "$(field alacritty-probe 3)"
else
  fail "INPUTS holds no source-receipt, so codex-rebuilt's provider prefix is unknown"
fi

if [ "$status" = 0 ]; then
  echo "compare: $same of $total identical apart from analyzer and reference identity"
else
  echo "compare: only $same of $total identical apart from analyzer and reference identity" >&2
fi
exit "$status"
