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
#          what recognising -O3 jump tables may remove (src/objc/macho-reader.c jump_table_at). The reader
#          is the authority on tables: the analyzer runs with DRYDOCK_OBJC_JUMP_TABLES=1 and lists each
#          table it took apart on stderr (jt_settle), and only these are excused:
#            - an indirect-objc-entry error whose detail ends "is called through where another path
#              left a different value", at an address from the jmp of a listed table whose cases it follows
#              up to that table's bytes [jmp, T) (where its cases lie);
#            - one that ends "is returned" or "is read other than to call through it (a spill, a copy or
#              an escape)", or an undecodable-objc-reference error, at an address inside a listed
#              table's bytes (the reader decoded that data as code before);
#            - one that ends "is read other than to call through it (a spill, a copy or an escape)" in such
#              a [jmp, T), at an instruction otool -tV shows as a 64-bit register copy `movq %R, %S` (a copy of a
#              register such a table's cases started unknown in);
#            - "objc entry point loaded in a function whose control flow is not followed" at the start of a
#              function holding a listed table whose cases it follows (its table bytes were decoded as code);
#            - "_SYMBOL address taken" at an instruction otool -tV shows as a `cmp $0x0` of a rip-relative
#              slot (a weak import's check, src/objc/macho-reader.c scan_function);
#            - an unclassified-objc-runtime-import error whose detail is one of the imports
#              src/objc/macho-reader.c ROLES classifies as memory or introspection (each with its cited
#              reason there): objc_getProperty, objc_setProperty, objc_setProperty_atomic,
#              objc_setProperty_nonatomic, objc_setProperty_atomic_copy, objc_setProperty_nonatomic_copy,
#              objc_getAssociatedObject, objc_setAssociatedObject, objc_removeAssociatedObjects, object_getIvar,
#              object_setIvar, objc_constructInstance, objc_disposeClassPair, class_respondsToSelector,
#              protocol_getMethodDescription, class_getInstanceVariable, class_getIvarLayout,
#              property_copyAttributeList, class_getInstanceMethod, class_getClassMethod,
#              ivar_getOffset, objc_getProtocol, protocol_getName, class_conformsToProtocol, ivar_getName and
#              class_getInstanceSize (each with its leading underscore);
#            - before the errors list, a fall in an artifact's "undecoded_code_bytes" of no more than
#              the listed tables' bytes in all; nothing else there may change.
#          As a cross-check, otool -tV must show every listed table: a `cmp $N-1; ja` (or `cmp $N; jae`),
#          a `leaq T(%rip)` and a `jmpq *reg` (the whole text, or else the table's function alone, as
#          otool's linear sweep can lose step after data). Each artifact's line counts what it lost by
#          kind, and names a fall in undecoded bytes.
#          COMPARE_RENAMED=1, in any mode, lets an indirect-objc-entry error's detail gain a ": reason" that names
#          its pattern (src/objc/macho-reader.c entry_escapes), and nothing else: the renamed error must be the
#          baseline's at the same place with the same code, slice and address, its detail the baseline's plus
#          one of these, each only after the detail it names:
#            - "is passed as an argument": "this send's selector is not known", "this send's selector is not
#              known on every path", "a declaration of SEL is variadic", "a declaration of SEL takes more than six
#              argument registers", "a declaration of SEL takes argument registers this reader does not count",
#              "no declaration of SEL was known when this send was read";
#            - "is returned": "the method's type encoding returns nothing in rax|rdx";
#            - "is read other than to call through it (a spill, a copy or an escape)": "stored to memory at 0xADDR";
#            - any of those three, or "is called through where another path left a different value": "in code
#              reached only through an indirect jump this reader does not follow".
#          It also lets an unclassified-objc-runtime-import error become, at the same place and slice, the code
#          src/objc/macho-reader.c ROLES now gives its import, the detail that import's name plus that code's message:
#            - runtime-method-swizzle, "SYM: a method implementation replaced at run time is not measured", for
#              _method_setImplementation, _method_exchangeImplementations and _class_replaceMethod;
#            - runtime-class-creation, "SYM: a class changed at run time is not the class measured", for
#              _class_addProtocol, _class_addIvar and _class_addProperty, and "SYM: a class made or reparented at
#              run time has no measured root" for _objc_initializeClassPair;
#            - runtime-imp-lookup, "SYM: the implementation it returns may be called directly, a send this reader
#              does not see", for _method_getImplementation, _class_getMethodImplementation and
#              _class_getMethodImplementation_stret.
#          The report's "runtime_class_creation_sites" may then rise by exactly the runtime-class-creation errors gained,
#          no more than those that name one of these four imports.
#          Each artifact's line then counts the renamed errors.
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
RENAMED=${COMPARE_RENAMED:-0}
case $RENAMED in 0|1) ;; *) fail "COMPARE_RENAMED is 0 or 1, not $RENAMED" ;; esac

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

# otool_tables [STOP]: from otool -tV on stdin, "LO HI" per line, decimal: the bytes [LO, HI) of each jump table it
# shows -- a `leaq T(%rip), reg` with a `jmpq *reg` at most six instructions on, after a `ja`/`jae` within twelve
# instructions before it that follows a `cmp $IMM` within five: N = IMM + 1 (ja) or IMM (jae) entries at T. It
# stops at the first instruction at or past STOP (decimal), when given.
otool_tables() {
  awk -v stop="${1:-}" '
    function hex(v,   i, c, x) { v = tolower(v); sub(/^0x/, "", v); x = 0
      for (i = 1; i <= length(v); i++) { c = index("0123456789abcdef", substr(v, i, 1)); if (!c) return -1; x = x * 16 + c - 1 }
      return x }
    $1 ~ /^[0-9a-f]+$/ && NF >= 2 {
      n++; ad[n] = hex($1); op[n] = $2; arg[n] = $3
      if (stop != "" && ad[n] >= stop + 0) exit
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

# reader_tables STDERR ART OUT: OUT gets "LO HI FLO FHI STATUS JMP" per table the reader listed in STDERR (decimal: the
# table's bytes, its function's extent, followed|data, its jmp). 1, saying why, when otool does not show one of them.
reader_tables() {
  awk -F '\t' '
    function hex(v,   i, c, x) { v = tolower(v); sub(/^0x/, "", v); x = 0
      for (i = 1; i <= length(v); i++) { c = index("0123456789abcdef", substr(v, i, 1)); if (!c) return -1; x = x * 16 + c - 1 }
      return x }
    # spec: src/objc/macho-reader.c jt_settle -- jmp, table, entries, function start, end, followed|data, name
    $1 == "drydock-objc-jump-table" && NF == 8 { t = hex($3); printf "%.0f %.0f %.0f %.0f %s %.0f\n", t, t + 4 * $4, hex($5), hex($6), $7, hex($2) }' "$1" > "$3"
  [ -s "$3" ] || return 0
  otool -tV "$2" | otool_tables > "$3.otool" || { echo "compare.sh: otool cannot read $2" >&2; return 1; }
  while read -r lo hi flo fhi st jmp; do
    grep -qx "$lo $hi" "$3.otool" && continue
    fn=$(awk -F '\t' -v t="$lo" '
      function hex(v,   i, c, x) { v = tolower(v); sub(/^0x/, "", v); x = 0
        for (i = 1; i <= length(v); i++) { c = index("0123456789abcdef", substr(v, i, 1)); if (!c) return -1; x = x * 16 + c - 1 }
        return x }
      $1 == "drydock-objc-jump-table" && sprintf("%.0f", hex($3)) == t { print $8; exit }' "$1")
    if [ -n "$fn" ] && [ "$fn" != - ] &&
       otool -tV -p "$fn" "$2" | otool_tables "$fhi" | grep -qx "$lo $hi"; then continue; fi
    echo "compare: otool does not show the jump table the reader listed at $lo ($fn)" >&2
    return 1
  done < "$3"
}

# fewer_errors BASE NEW STDERR ART: 0 when NEW's report differs from BASE's only by what MODE lets it lose (the
# header); prints what it lost. Otherwise 1, with what differs on stderr.
fewer_errors() {
  split_errors "$1" "$1.head" "$1.errs" && split_errors "$2" "$2.head" "$2.errs" ||
    { echo "compare.sh: $1 or $2 does not end in an errors list" >&2; return 1; }
  : > "$1.tables"; : > "$1.cmps"; fell=0
  if [ "$MODE" = fewer-unmeasured ]; then
    reader_tables "$3" "$4" "$1.tables" || return 1
    # spec: src/objc/macho-reader.c scan_function -- a weak import's check: the decimal address of each baseline
    #       "address taken" error that otool shows as a cmp of an immediate with a rip-relative slot
    sed -n 's/^{"code": "indirect-objc-entry", "slice": "[^"]*", "address": "0x\([0-9a-f]*\)", "detail": "_[A-Za-z0-9_$.]* address taken"}$/\1/p' "$1.errs" > "$1.taken"
    # spec: src/objc/macho-reader.c entry_escapes -- a "read other" error at a register copy in a table's cases
    sed -n 's/^{"code": "indirect-objc-entry", "slice": "[^"]*", "address": "0x\([0-9a-f]*\)", "detail": "objc entry point in [a-z0-9]* is read other than to call through it (a spill, a copy or an escape)"}$/\1/p' "$1.errs" > "$1.read"
    : > "$1.movs"
    if [ -s "$1.taken" ] || [ -s "$1.read" ]; then
      otool -tV "$4" > "$1.otv" || { echo "compare.sh: otool cannot read $4" >&2; return 1; }
      awk 'NR == FNR { want[$1] = 1; next }
        { a = $1; sub(/^0+/, "", a) } (a in want) && $2 ~ /^cmp[bwlq]$/ && $3 == "$0x0," && $4 ~ /\(%rip\)$/ { print a }' "$1.taken" "$1.otv" |
        while read -r a; do printf '%.0f\n' "$((0x$a))"; done > "$1.cmps"
      awk 'NR == FNR { want[$1] = 1; next }
        { a = $1; sub(/^0+/, "", a) } (a in want) && $2 == "movq" && $3 ~ /^%r[a-z0-9]+,$/ && $4 ~ /^%r[a-z0-9]+$/ && NF == 4 { print a }' "$1.read" "$1.otv" |
        while read -r a; do printf '%.0f\n' "$((0x$a))"; done > "$1.movs"
    fi
    # spec: src/objc/main.m -- "undecoded_code_bytes" is the reader's limit_undecoded_bytes; a table read as
    #       data is no longer decoded as code, so it may fall, by at most the listed tables' bytes
    grep -o '"undecoded_code_bytes": [0-9]*' "$1.head" | awk '{ print $2 }' > "$1.ub"
    grep -o '"undecoded_code_bytes": [0-9]*' "$2.head" | awk '{ print $2 }' > "$2.ub"
    room=$(awk '{ r += $2 - $1 } END { printf "%.0f", r }' "$1.tables")
    if [ "$(wc -l < "$1.ub")" != "$(wc -l < "$2.ub")" ] ||
       ! fell=$(paste -d ' ' "$1.ub" "$2.ub" | awk -v room="$room" '
           $2 + 0 > $1 + 0 { bad = 1 } { f += $1 - $2 } END { if (bad || f > room + 0) exit 1; printf "%.0f", f }')
    then
      echo "compare: undecoded_code_bytes rose, or fell by more than the listed jump tables' $room bytes:" $(cat "$1.ub") "->" $(cat "$2.ub") >&2
      return 1
    fi
    sed 's/"undecoded_code_bytes": [0-9]*/"undecoded_code_bytes": 0/' "$1.head" > "$1.head.u" && mv "$1.head.u" "$1.head"
    sed 's/"undecoded_code_bytes": [0-9]*/"undecoded_code_bytes": 0/' "$2.head" > "$2.head.u" && mv "$2.head.u" "$2.head"
  fi
  if [ "$RENAMED" = 1 ]; then
    # spec: src/objc/main.m -- "runtime_class_creation_sites" counts the report's runtime-class-creation errors; it
    #       may rise by exactly the runtime-class-creation errors gained, each of which the errors check below must
    #       map back to a baseline unclassified-objc-runtime-import error, and by no more than those that name an
    #       import this piece made runtime-class-creation
    rs1=$(grep -o '"runtime_class_creation_sites": [0-9]*' "$1.head" | awk '{ print $2 }')
    rs2=$(grep -o '"runtime_class_creation_sites": [0-9]*' "$2.head" | awk '{ print $2 }')
    rc1=$(grep -c '^{"code": "runtime-class-creation", ' "$1.errs" || true)
    rc2=$(grep -c '^{"code": "runtime-class-creation", ' "$2.errs" || true)
    rcn=$(grep -cE '^\{"code": "runtime-class-creation", .*"detail": "(_class_add(Protocol|Ivar|Property): a class changed at run time is not the class measured|_objc_initializeClassPair: a class made or reparented at run time has no measured root)"\}$' "$2.errs" || true)
    if [ -z "$rs1$rs2" ]; then :   # neither report reached its closure facts
    elif [ "$(printf '%s\n' "$rs1" | wc -l | tr -d ' ')" != 1 ] || [ "$(printf '%s\n' "$rs2" | wc -l | tr -d ' ')" != 1 ] || [ -z "$rs1" ] || [ -z "$rs2" ] ||
       [ $((rs2 - rs1)) != $((rc2 - rc1)) ] || [ $((rc2 - rc1)) -lt 0 ] || [ $((rc2 - rc1)) -gt "$rcn" ]; then
      echo "compare: runtime_class_creation_sites $rs1 -> $rs2 is not the $((rc2 - rc1)) runtime-class-creation errors renamed" >&2
      return 1
    fi
    sed 's/"runtime_class_creation_sites": [0-9]*/"runtime_class_creation_sites": 0/' "$1.head" > "$1.head.r" && mv "$1.head.r" "$1.head"
    sed 's/"runtime_class_creation_sites": [0-9]*/"runtime_class_creation_sites": 0/' "$2.head" > "$2.head.r" && mv "$2.head.r" "$2.head"
  fi
  if ! cmp -s "$1.head" "$2.head"; then
    echo "compare: reports differ before their errors:" >&2
    diff "$1.head" "$2.head" | cut -c1-300 | head -40 >&2 || true
    return 1
  fi
  awk -v mode="$MODE" -v renamed="$RENAMED" -v tables="$1.tables" -v cmps="$1.cmps" -v movs="$1.movs" -v fell="$fell" '
       BEGIN { while ((getline l < tables) > 0) { split(l, r, " "); nt++; tlo[nt] = r[1]; thi[nt] = r[2]; flo[nt] = r[3]; fhi[nt] = r[4]; st[nt] = r[5]; tj[nt] = r[6] }
               while ((getline l < cmps) > 0) cmp[l + 0] = 1
               while ((getline l < movs) > 0) mov[l + 0] = 1
               # spec: src/objc/macho-reader.c ROLES -- the imports this piece classified, by the role they now have
               n = split("_objc_getProperty _objc_setProperty _objc_setProperty_atomic _objc_setProperty_nonatomic " \
                         "_objc_setProperty_atomic_copy _objc_setProperty_nonatomic_copy _objc_getAssociatedObject " \
                         "_objc_setAssociatedObject _objc_removeAssociatedObjects _object_getIvar _object_setIvar " \
                         "_objc_constructInstance _objc_disposeClassPair _class_respondsToSelector " \
                         "_protocol_getMethodDescription _class_getInstanceVariable _class_getIvarLayout " \
                         "_property_copyAttributeList _class_getInstanceMethod _class_getClassMethod " \
                         "_ivar_getOffset _objc_getProtocol _protocol_getName " \
                         "_class_conformsToProtocol _ivar_getName _class_getInstanceSize", w, " ")
               for (i = 1; i <= n; i++) classified[w[i]] = 1
               n = split("_method_setImplementation _method_exchangeImplementations _class_replaceMethod", w, " ")
               for (i = 1; i <= n; i++) swizzle[w[i]] = 1
               n = split("_class_addProtocol _class_addIvar _class_addProperty", w, " ")
               for (i = 1; i <= n; i++) changed[w[i]] = 1
               n = split("_method_getImplementation _class_getMethodImplementation _class_getMethodImplementation_stret", w, " ")
               for (i = 1; i <= n; i++) implookup[w[i]] = 1 }
       function hex(v,   i, c, x) { v = tolower(v); sub(/^0x/, "", v); x = 0
         for (i = 1; i <= length(v); i++) { c = index("0123456789abcdef", substr(v, i, 1)); if (!c) return -1; x = x * 16 + c - 1 }
         return x }
       function addr(e) { return match(e, /"address": "0x[0-9a-f]+"/) ? hex(substr(e, RSTART + 12, RLENGTH - 13)) : -1 }
       function in_table(e,   a, i) { a = addr(e); for (i = 1; i <= nt; i++) if (tlo[i] + 0 <= a && a < thi[i] + 0) return 1; return 0 }
       function in_cases(e,   a, i) {
         a = addr(e); for (i = 1; i <= nt; i++) if (st[i] == "followed" && tj[i] + 0 <= a && a < tlo[i] + 0) return 1; return 0 }
       function in_start(e,   a, i) {
         a = addr(e); for (i = 1; i <= nt; i++) if (st[i] == "followed" && flo[i] + 0 == a) return 1; return 0 }
       # spec: src/objc/macho-reader.c ROLES -- the code and message each import this piece classified as swizzling
       #       or class creation is refused with, mapped back to its unclassified-objc-runtime-import error
       function unrole(e,   c, d, j, sym, r) {
         if (e !~ /^\{"code": "(runtime-method-swizzle|runtime-class-creation|runtime-imp-lookup)", "slice": "[^"]*", "address": "0x[0-9a-f]+", "detail": "[^"]*"}$/) return e
         c = substr(e, 11); c = substr(c, 1, index(c, "\"") - 1)
         d = substr(e, index(e, "\"detail\": \"") + 11); d = substr(d, 1, length(d) - 2)
         if ((j = index(d, ": ")) == 0) return e
         sym = substr(d, 1, j - 1); r = substr(d, j + 2)
         if (!((c == "runtime-method-swizzle" && (sym in swizzle) && r == "a method implementation replaced at run time is not measured") ||
               (c == "runtime-class-creation" && (sym in changed) && r == "a class changed at run time is not the class measured") ||
               (c == "runtime-class-creation" && sym == "_objc_initializeClassPair" && r == "a class made or reparented at run time has no measured root") ||
               (c == "runtime-imp-lookup" && (sym in implookup) && r == "the implementation it returns may be called directly, a send this reader does not see")))
           return e
         return "{\"code\": \"unclassified-objc-runtime-import\", " substr(e, index(e, "\"slice\": "), index(e, ", \"detail\": ") - index(e, "\"slice\": ")) ", \"detail\": \"" sym "\"}" }
       # spec: src/objc/macho-reader.c entry_escapes -- the ": reason" each refusal may name, after its own detail
       function unrename(e,   d, w, r, j) {
         if (e !~ /^\{"code": "indirect-objc-entry", "slice": "[^"]*", "address": "0x[0-9a-f]+", "detail": "objc entry point in [a-z0-9]+ [^"]*"}$/) return e
         d = substr(e, index(e, "\"detail\": \"") + 11); d = substr(d, 1, length(d) - 2)
         if ((j = index(d, ": ")) == 0) return e
         w = substr(d, 1, j - 1); r = substr(d, j + 2)
         if (w !~ /^objc entry point in [a-z0-9]+ (is passed as an argument|is returned|is read other than to call through it \(a spill, a copy or an escape\)|is called through where another path left a different value)$/) return e
         if (!(r == "in code reached only through an indirect jump this reader does not follow" ||
               (w ~ / is passed as an argument$/ && (r == "this send\047s selector is not known" ||
                  r == "this send\047s selector is not known on every path" ||
                  r ~ /^a declaration of [^ ]+ (is variadic|takes more than six argument registers|takes argument registers this reader does not count)$/ ||
                  r ~ /^no declaration of [^ ]+ was known when this send was read$/)) ||
               (w ~ / is returned$/ && r ~ /^the method\047s type encoding returns nothing in (rax|rdx)$/) ||
               (w ~ / is read other than / && r ~ /^stored to memory at 0x[0-9a-f]+$/))) return e
         return substr(e, 1, index(e, "\"detail\": \"") + 10) w "\"}" }
       function kind(e) {
         if (mode == "identical") return ""
         if (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "[^"]*is passed as an argument"}$/) return "passed"
         if (mode != "fewer-unmeasured") return ""
         if (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "[^"]*is called through where another path left a different value"}$/ && in_cases(e))
           return "merged"
         if (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "objc entry point loaded in a function whose control flow is not followed"}$/ && in_start(e))
           return "unfollowed"
         if (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "_[A-Za-z0-9_$.]+ address taken"}$/ && ((addr(e) + 0) in cmp))
           return "weak"
         if ((e ~ /^\{"code": "undecodable-objc-reference", / ||
              (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "[^"]*(is returned|is read other than to call through it \(a spill, a copy or an escape\))"}$/)) && in_table(e))
           return "table"
         if (e ~ /^\{"code": "indirect-objc-entry", / && e ~ /"detail": "[^"]*is read other than to call through it \(a spill, a copy or an escape\)"}$/ && in_cases(e) && ((addr(e) + 0) in mov))
           return "copied"
         if (e ~ /^\{"code": "unclassified-objc-runtime-import", "slice": "[^"]*", "address": "0x[0-9a-f]+", "detail": "[^"]*"}$/ &&
             (substr(e, index(e, "\"detail\": \"") + 11, length(e) - index(e, "\"detail\": \"") - 12) in classified))
           return "classified"
         return "" }
       function drop(e,   k) { k = kind(e); if (k == "") { print "compare: lost error " e > "/dev/stderr"; bad = 1 } else lost[k]++ }
       NR == FNR { base[++nb] = $0; next }
       { e = $0
         if (renamed) { e = unrename(unrole($0)); if (e != $0) nren++ }
         for (q = p + 1; q <= nb && base[q] != e; q++) ;
         if (q > nb) { print "compare: new, changed or reordered error " $0 > "/dev/stderr"; bad = 1; next }
         while (p + 1 < q) drop(base[++p])
         p = q }
       END { while (p < nb) drop(base[++p])
             if (bad) exit 1
             s = ""
             if (lost["passed"]) s = s ", " lost["passed"] " fewer \"is passed as an argument\" errors"
             if (lost["merged"]) s = s ", " lost["merged"] " fewer \"where another path left a different value\" errors"
             if (lost["copied"]) s = s ", " lost["copied"] " fewer \"read other\" errors at a register copy in a followed jump table\047s cases"
             if (lost["unfollowed"]) s = s ", " lost["unfollowed"] " fewer functions whose control flow is not followed"
             if (lost["weak"]) s = s ", " lost["weak"] " fewer \"address taken\" errors at a weak import\047s check"
             if (lost["table"]) s = s ", " lost["table"] " fewer errors inside a jump table"
             if (lost["classified"]) s = s ", " lost["classified"] " fewer unclassified-objc-runtime-import errors for imports now classified"
             if (fell + 0) s = s ", " fell " fewer undecoded bytes"
             if (nren) s = s ", " nren " errors renamed"
             print substr(s, 3) }' "$1.errs" "$2.errs"
}

status=0; total=0; same=0
check() {
  name=$1; art=$2; shift 2
  total=$((total + 1))
  [ -f "$BASELINE_DIR/$name.objc-compat.json" ] || fail "no baseline report for $name"
  rc=0
  # spec: src/objc/macho-reader.c jt_settle -- DRYDOCK_OBJC_JUMP_TABLES lists the reader's tables on stderr
  DRYDOCK_OBJC_JUMP_TABLES=1 "$DRYDOCK_OBJC" analyze --artifact "$art" --root "$(dirname "$art")" --references "$REFS" \
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
      if [ "$MODE" != identical ] || [ "$RENAMED" = 1 ]; then
        lost=$(fewer_errors "$WORK/$name.base" "$WORK/$name.new" "$WORK/$name.stderr" "$art") || { echo "compare: $name: reports differ" >&2; ok=0; }
      else
        echo "compare: $name: reports differ:" >&2
        diff "$WORK/$name.base" "$WORK/$name.new" | cut -c1-300 | head -40 >&2 || true
        ok=0
      fi
    fi
  fi
  if [ "$ok" = 1 ] && [ -n "$lost" ] && [ "$lost" != 0 ]; then
    same=$((same + 1)); echo "compare: $name: exit $rc, identical apart from analyzer and reference identity and $lost"
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
