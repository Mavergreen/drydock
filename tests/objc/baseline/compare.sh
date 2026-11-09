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
#          COMPARE_MODE=fewer-unmeasured is that mode with these too, and no other kind, allowed to vanish --
#          what recognising -O3 jump tables may remove (src/objc/macho-reader.c jump_table_at): an
#          indirect-objc-entry error whose detail ends "is called through where another path left a
#          different value", anywhere; and one that ends "is returned" or "is read other than to call
#          through it (a spill, a copy or an escape)", or an undecodable-objc-reference error, only at an
#          address inside a jump table's bytes: the 4N bytes at T after a `cmp $N-1; ja` (or `cmp $N; jae`)
#          and a `leaq T(%rip)` followed by a `jmpq *reg`, as otool -tV disassembles the artifact (the
#          reader decoded that data as code before). Before the errors list, only each artifact's
#          "undecoded_code_bytes" may change, and only fall, by no more than those tables' bytes in all.
#          Each artifact's line counts the lost errors by kind.
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
case $MODE in identical|fewer-passed-arguments|fewer-unmeasured) ;; *) fail "unknown COMPARE_MODE $MODE" ;; esac

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

# jump_tables ART: "LO HI" per line, decimal: the bytes [LO, HI) of each jump table otool -tV shows in ART --
# a `leaq T(%rip), reg` with a `jmpq *reg` at most six instructions on, after a `ja`/`jae` within twelve
# instructions before it that follows a `cmp $IMM` within five: N = IMM + 1 (ja) or IMM (jae) entries at T.
jump_tables() {
  otool -tV "$1" | awk '
    function hex(v,   i, c, x) { v = tolower(v); sub(/^0x/, "", v); x = 0
      for (i = 1; i <= length(v); i++) { c = index("0123456789abcdef", substr(v, i, 1)); if (!c) return -1; x = x * 16 + c - 1 }
      return x }
    $1 ~ /^[0-9a-f]+$/ && NF >= 2 {
      n++; ad[n] = hex($1); op[n] = $2; arg[n] = $3
      if (pend && n == pend + 1) { t = ad[n] + off; pend = 0 }   # rip-relative: from the next instruction
      if (op[n] == "leaq" && arg[n] ~ /^0x[0-9a-f]+\(%rip\),$/) { off = hex(substr(arg[n], 1, index(arg[n], "(") - 1)); pend = n; lea = n; t = -1 }
      if (op[n] == "jmpq" && arg[n] ~ /^\*%r/ && t >= 0 && n - lea <= 6) {
        N = -1
        for (j = lea - 1; j > lea - 12 && j > 0; j--) if (op[j] == "ja" || op[j] == "jae") {
          for (k = j - 1; k > j - 6 && k > 0; k--) if (op[k] ~ /^cmp[lq]$/ && arg[k] ~ /^\$0x[0-9a-f]+,$/) { N = hex(substr(arg[k], 2, length(arg[k]) - 2)) + (op[j] == "ja"); break }
          break
        }
        if (N > 0) printf "%.0f %.0f\n", t, t + 4 * N
        t = -1
      }
    }'
}

# fewer_errors BASE NEW ART: 0 when NEW's report differs from BASE's only by errors it lost of the kinds MODE allows
# to vanish (the header); prints how many of each. Otherwise 1, with what differs on stderr.
fewer_errors() {
  split_errors "$1" "$1.head" "$1.errs" && split_errors "$2" "$2.head" "$2.errs" ||
    { echo "compare.sh: $1 or $2 does not end in an errors list" >&2; return 1; }
  : > "$1.tables"
  if [ "$MODE" = fewer-unmeasured ]; then
    jump_tables "$3" > "$1.tables" || { echo "compare.sh: otool cannot read $3" >&2; return 1; }
    # spec: src/objc/main.m -- "undecoded_code_bytes" is the reader's limit_undecoded_bytes; a table read as
    #       data is no longer decoded as code, so it may fall, by at most the bytes of the tables otool shows
    grep -o '"undecoded_code_bytes": [0-9]*' "$1.head" | awk '{ print $2 }' > "$1.ub"
    grep -o '"undecoded_code_bytes": [0-9]*' "$2.head" | awk '{ print $2 }' > "$2.ub"
    if [ "$(wc -l < "$1.ub")" != "$(wc -l < "$2.ub")" ] ||
       ! paste -d ' ' "$1.ub" "$2.ub" | awk -v tables="$1.tables" '
           BEGIN { while ((getline l < tables) > 0) { split(l, r, " "); room += r[2] - r[1] } }
           $2 + 0 > $1 + 0 || $1 - $2 > room { bad = 1 } END { exit bad }'
    then
      echo "compare: undecoded_code_bytes rose, or fell by more than the jump tables hold:" $(cat "$1.ub") "->" $(cat "$2.ub") >&2
      return 1
    fi
    sed 's/"undecoded_code_bytes": [0-9]*/"undecoded_code_bytes": 0/' "$1.head" > "$1.head.u" && mv "$1.head.u" "$1.head"
    sed 's/"undecoded_code_bytes": [0-9]*/"undecoded_code_bytes": 0/' "$2.head" > "$2.head.u" && mv "$2.head.u" "$2.head"
  fi
  if ! cmp -s "$1.head" "$2.head"; then
    echo "compare: reports differ before their errors:" >&2
    diff "$1.head" "$2.head" | cut -c1-300 | head -40 >&2 || true
    return 1
  fi
  awk -v mode="$MODE" -v tables="$1.tables" '
       BEGIN { while ((getline l < tables) > 0) { split(l, r, " "); nt++; tlo[nt] = r[1]; thi[nt] = r[2] } }
       function hex(v,   i, c, x) { v = tolower(v); sub(/^0x/, "", v); x = 0
         for (i = 1; i <= length(v); i++) { c = index("0123456789abcdef", substr(v, i, 1)); if (!c) return -1; x = x * 16 + c - 1 }
         return x }
       function in_table(e,   a, i) {
         if (!match(e, /"address": "0x[0-9a-f]+"/)) return 0
         a = hex(substr(e, RSTART + 12, RLENGTH - 13))
         for (i = 1; i <= nt; i++) if (tlo[i] + 0 <= a && a < thi[i] + 0) return 1
         return 0 }
       function kind(e) {
         if (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "[^"]*is passed as an argument"}$/) return "passed"
         if (mode != "fewer-unmeasured") return ""
         if (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "[^"]*is called through where another path left a different value"}$/) return "merged"
         if ((e ~ /^\{"code": "undecodable-objc-reference", / ||
              (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "[^"]*(is returned|is read other than to call through it \(a spill, a copy or an escape\))"}$/)) && in_table(e))
           return "table"
         return "" }
       function drop(e,   k) { k = kind(e); if (k == "") { print "compare: lost error " e > "/dev/stderr"; bad = 1 } else lost[k]++ }
       NR == FNR { base[++nb] = $0; next }
       { for (q = p + 1; q <= nb && base[q] != $0; q++) ;
         if (q > nb) { print "compare: new, changed or reordered error " $0 > "/dev/stderr"; bad = 1; next }
         while (p + 1 < q) drop(base[++p])
         p = q }
       END { while (p < nb) drop(base[++p])
             if (bad) exit 1
             s = ""
             if (lost["passed"]) s = s ", " lost["passed"] " \"is passed as an argument\""
             if (lost["merged"]) s = s ", " lost["merged"] " \"where another path left a different value\""
             if (lost["table"]) s = s ", " lost["table"] " inside a jump table"
             print substr(s, 3) }' "$1.errs" "$2.errs"
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
      if [ "$MODE" != identical ]; then
        lost=$(fewer_errors "$WORK/$name.base" "$WORK/$name.new" "$art") || { echo "compare: $name: reports differ" >&2; ok=0; }
      else
        echo "compare: $name: reports differ:" >&2
        diff "$WORK/$name.base" "$WORK/$name.new" | cut -c1-300 | head -40 >&2 || true
        ok=0
      fi
    fi
  fi
  if [ "$ok" = 1 ] && [ -n "$lost" ] && [ "$lost" != 0 ]; then
    same=$((same + 1)); echo "compare: $name: exit $rc, identical apart from analyzer and reference identity and fewer errors: $lost"
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
