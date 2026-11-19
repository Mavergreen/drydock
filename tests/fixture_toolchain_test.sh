#!/bin/sh
# platform: host-agnostic -- no test builds or inspects a fixture with the host's compiler or binutils.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SELF=tests/fixture_toolchain_test.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fixture-toolchain.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0
fail() { printf "%s\n" "FAIL $*"; fails=$((fails + 1)); }

# Reads one shell script on stdin; prints each line that runs a host tool, skipping comments and heredoc bodies.
scan() {
  awk '
    function endword(s) { gsub(/^[ \t]*<<-?[ \t]*/, "", s); gsub(/^["\x27\\]/, "", s); gsub(/["\x27].*$/, "", s); gsub(/[ \t;&|)].*$/, "", s); return s }
    heredoc != "" { l = $0; sub(/^\t+/, "", l); if (l == heredoc) heredoc = ""; next }
    /^[ \t]*#/ { next }
    {
      h = $0; gsub(/<<</, "", h); gsub(/\$?\(\([^)]*\)\)/, "", h)
      if (match(h, /<<-?[ \t]*["\x27\\]?[A-Za-z_][A-Za-z_0-9]*/)) heredoc = endword(substr(h, RSTART, RLENGTH))
      if ($0 ~ /\/usr\/bin\/(clang|clang\+\+|cc|gcc|libtool|ld|ar|ranlib|otool|lipo|nm|strings|strip|xcrun)([^A-Za-z0-9_-]|$)/ ||
          $0 ~ /\$\{(CC|CXX|AR|NM|OTOOL|LIPO|LIBTOOL|STRIP):-/ ||
          $0 ~ /xcrun/ ||
          $0 ~ /(^|[;&|(`{!]|\$\(|(^|[ \t])(then|do|else|elif|if|while|until|exec|env|command|command[ \t]+-v)|^[ \t]*([A-Za-z_]+=[^ \t]*[ \t]+)+)[ \t]*(libtool|ld|ar|ranlib|otool|lipo|nm|strings|strip|clang|clang\+\+|cc|gcc|c\+\+)([ \t]|$)/)
        print FNR ": " $0
    }'
}

# Not yet convertible, each for a reason a conversion would have to answer, not paper over (named, so the list
# cannot grow silently; the test fails if an exempt file no longer exists):
#   x86len_oracle_test.sh: its oracle is cctools' otool, whose linear sweep its allow-list follows (llvm-otool sweeps
#     differently: prefixes, jump-table data). It runs the developer tools' own otool and lipo, never /usr/bin's stub,
#     and skips, saying why, where they are absent (the 10.9 guest) or the otool is not cctools'.
EXEMPT="tests/x86len_oracle_test.sh"

hits() { # DIR: scans every tests/**.sh under DIR, except the helper, this test and EXEMPT
  (cd "$1" && find tests -name '*.sh' ! -path tests/lib/toolchain.sh ! -path "$SELF" | sort | while read -r f; do
    case " $(echo $EXEMPT) " in *" $f "*) continue ;; esac
    scan <"$f" | sed "s|^|$f:|"
  done)
}

for e in $EXEMPT; do
  [ -f "$ROOT/$e" ] && echo "ok exempt $e exists" || fail "exempt $e does not exist; drop it from EXEMPT"
done

cat >"$TMP/control.sh" <<'CTL'
# ar x in a comment
echo ok
n=$((1 << shift))
ar rcs libx.a x.o
cc -c x.c
x=$(otool -L foo)
/usr/bin/clang -c y.c
"${CC:-cc}" -c z.c
cat >x.c <<'C'
int main(void) { nm(); ar(); return 0; }
C
"$CC" -c w.c
echo "needs libtool"
x=1; strip -x a.out
"$STRIP" -x b.out
CTL
got=$(scan <"$TMP/control.sh" | cut -d: -f1 | tr '\n' ' ')
[ "$got" = "4 5 6 7 8 14 " ] && echo "ok control flags exactly its six host-tool lines, past an arithmetic shift" ||
  fail "control: flagged lines '$got', expected '4 5 6 7 8 14 '"

if git -C "$ROOT" cat-file -e c7c0f56 2>/dev/null; then
  mkdir "$TMP/old" && git -C "$ROOT" archive c7c0f56 tests | tar -x -C "$TMP/old"
  n=$(hits "$TMP/old" | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && echo "ok positive control: $n host-tool lines in c7c0f56's tests" ||
    fail "positive control: no hits in c7c0f56's tests, so the scan cannot be trusted"
else
  echo "N/A positive control against c7c0f56: no git that can read it here (the synthetic control above still ran)"
fi

# toolchain.sh resolves a fetched prefix from fetch_clang22.sh's stdout alone; its stderr chatter must not join the path
mkdir -p "$TMP/stub/scripts" "$TMP/stub/prefix/bin" "$TMP/stub/root/components/objc-receipt-clang"
printf '#!/bin/sh\necho "clang22: already extracted" >&2\necho "%s"\n' "$TMP/stub/prefix" >"$TMP/stub/scripts/fetch_clang22.sh"
printf '#!/bin/sh\necho ld64.lld\n' >"$TMP/stub/prefix/bin/clang"
chmod +x "$TMP/stub/prefix/bin/clang"
got=$(CLANG22= ROOT="$ROOT" SHIPYARD_SCRIPTS="$TMP/stub/scripts" TMPDIR="$TMP" sh -c '. "$ROOT/tests/lib/toolchain.sh" && printf "%s" "$CC"' 2>/dev/null)
[ "$got" = "$TMP/stub/prefix/bin/clang" ] && [ -x "$got" ] &&
  echo "ok CLANG22 unset: the fetched prefix is fetch_clang22.sh's stdout, not its stderr" ||
  fail "CLANG22 unset: CC resolved to '$got', expected $TMP/stub/prefix/bin/clang (stderr joined the path?)"

found=$(hits "$ROOT")
[ -z "$found" ] && echo "ok no test names a host compiler or binutil" ||
  fail "tests run the host's tools; use \$CC, \$AR, \$LIBTOOL, \$NM, \$OTOOL, \$LIPO, \$STRINGS, \$STRIP from tests/lib/toolchain.sh:
$found"

# Reads one shell script twice (runs FILE FILE); prints each line that runs, unguarded by gate_row, gate_test or
# can_exec, a program the script built with "$CC" or "$CXX": those build x86_64 fixtures, and a helper the script
# runs on this host is built with "$HOST_CC". Also each line building with "$CC" or "$CXX" for an arch that is not
# x86_64 or i386: their cfg's SDK has no arm64, so "$CC_ARM64" builds arm64, and "$HOST_CC" the host's arch.
runs() {
  awk '
    function ind(s) { match(s, /^[ \t]*/); return RLENGTH }
    function endword(s) { gsub(/^[ \t]*<<-?[ \t]*/, "", s); gsub(/^["\x27\\]/, "", s); gsub(/["\x27].*$/, "", s); gsub(/[ \t;&|)].*$/, "", s); return s }
    function gated(k,    lim, j, t, i, chain) {
      if (text[k] ~ /gate_row|gate_test|can_exec/) return 1
      lim = ind(text[k]); chain = -1
      for (j = k - 1; j >= 1; j--) {
        t = text[j]
        if (t ~ /^[ \t]*$/ || t ~ /^[ \t]*#/) continue
        i = ind(t)
        if (i == 0 && t ~ /(^|[ \t;])gate_test[ \t]/) return 1
        if (chain >= 0) {
          if (i == chain) { if (t ~ /gate_row|can_exec/) return 1; if (t ~ /^[ \t]*if[ \t]/) { chain = -1; lim = i }; continue }
          if (i > chain) continue
          chain = -1
        }
        if (i == lim && t ~ /(gate_row|gate_test|can_exec)[^|]*\|\|[ \t]*(return|continue|exit|break)/) return 1
        if (i < lim) {
          if (t ~ /gate_row|gate_test|can_exec/) return 1
          if (t ~ /^[ \t]*[A-Za-z_][A-Za-z_0-9]*[ \t]*\(\)/) return 0
          if (t ~ /^[ \t]*(else|elif)([ \t;]|$)/) { chain = i; continue }
          lim = i
          if (i == 0) return 0
        }
      }
      return 0
    }
    FNR == 1 { pass++; heredoc = ""; cont = 0 }
    heredoc != "" { l = $0; sub(/^\t+/, "", l); if (l == heredoc) heredoc = ""; next }
    {
      h = $0; gsub(/<<</, "", h); gsub(/\$?\(\([^)]*\)\)/, "", h)
      if ($0 !~ /^[ \t]*#/ && match(h, /<<-?[ \t]*["\x27\\]?[A-Za-z_][A-Za-z_0-9]*/)) heredoc = endword(substr(h, RSTART, RLENGTH))
    }
    pass == 1 {
      logical = cont ? logical " " $0 : $0
      if (!cont) first = FNR
      cont = ($0 ~ /\\$/)
      if (cont || logical ~ /^[ \t]*#/) next
      if (match(logical, /(^|[;&|][ \t]*)for[ \t]+[A-Za-z_][A-Za-z_0-9]*[ \t]+in[ \t][^;$`"]*;/)) {
        split(substr(logical, RSTART, RLENGTH), w, /[ \t;&|]+/)
        for (i = 1; w[i] != "for"; i++) ;
        loopvar = w[i + 1]; loopwords = ""
        for (i += 3; w[i] != ""; i++) loopwords = loopwords " " w[i]
      }
      if (logical ~ /"\$(CC|CXX)"/) {
        a = logical; other = (a ~ /\$A64/)
        while (match(a, /-arch[ \t]+[^ \t]+/)) {
          if (substr(a, RSTART, RLENGTH) !~ /-arch[ \t]+(x86_64h?|i386)$/) other = 1
          a = substr(a, RSTART + RLENGTH)
        }
        if (other) print first ": " logical
      }
      if (logical ~ /"\$(CC|CXX)"/ && match(logical, /-o[ \t]+"?[^ "]+"?/)) {
        o = substr(logical, RSTART, RLENGTH); sub(/^-o[ \t]+/, "", o); gsub(/"/, "", o)
        if (o ~ /\.(o|a|dylib|bundle)$/ || o ~ /^(\/dev\/null|\$[0-9@*])$/) next
        if (loopvar != "" && index(o, "$" loopvar)) {
          nw = split(loopwords, w, " ")
          for (i = 1; i <= nw; i++) { e = o; gsub("\\$(" loopvar "|\\{" loopvar "\\})", w[i], e); built[e] = 1 }
        } else built[o] = 1
      }
      next
    }
    {
      n++; text[n] = $0
      if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) next
      for (o in built) {
        q = o; gsub(/[][\\.$*+?(){}|^\/]/, "\\\\&", q)
        if (o !~ /\//) q = "(\\./)?" q
        re = "(^|[;&|`!{]|\\([ \t]|\\$\\(|(then|do|else|if|elif|exec)[ \t])[ \t]*\"?" q "\"?([ \t]|$|[);<>])"
        if ($0 ~ re && !gated(n)) { print FNR ": " $0; break }
      }
    }' "$1" "$1"
}
unguarded() { # DIR: runs over every tests/**.sh under DIR, except this test
  (cd "$1" && find tests -name '*.sh' ! -path "$SELF" | sort | while read -r f; do
    runs "$f" | sed "s|^|$f:|"
  done)
}

cat >"$TMP/runs.sh" <<'CTL'
"$CC" -o "$T/helper" helper.c
"$HOST_CC" -o "$T/tool" tool.c
"$CC" -o "$T/fixture" fixture.c
"$T/helper" in out
"$T/tool" in out
if gate_row x86_64 "fixture runs"; then
    "$T/fixture"
fi
if [ -e "$T/x" ]; then :
elif ! gate_row x86_64 "fixture still runs"; then :
else
    v=$("$T/fixture")
fi
for p in one two; do "$CC" -o "$T/$p" "$T/$p.c"; done
"$T/two"
same() {
    gate_row x86_64 "$1 behaves" || return 0
    "$T/fixture" >out
}
x=$("$T/helper")
"$CC" -c -arch arm64 -o arm.o arm.c
"$CC_ARM64" -c -o arm.o arm.c
"$CC" -arch "$2" -c -o x.o x.c
"$CC" -arch x86_64 -arch i386 -c -o y.o y.c
"$CC" -O2 -o stabs stabs.c
./stabs lib
CTL
got=$(runs "$TMP/runs.sh" | cut -d: -f1 | tr '\n' ' ')
[ "$got" = "21 23 4 15 20 26 " ] && echo "ok control flags the ungated runs of what \$CC built, and its builds for arm64 or an unnamed arch, only" ||
  fail "runs control: flagged lines '$got', expected '21 23 4 15 20 26 '"

if git -C "$ROOT" cat-file -e abe8d68 2>/dev/null; then
  mkdir "$TMP/ab" && git -C "$ROOT" archive abe8d68 tests | tar -x -C "$TMP/ab"
  n=$(unguarded "$TMP/ab" | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && echo "ok positive control: $n unguarded runs of \$CC's programs in abe8d68's tests" ||
    fail "positive control: no unguarded runs in abe8d68's tests, so the scan cannot be trusted"
else
  echo "N/A positive control against abe8d68: this clone lacks that commit, or its git cannot read it (the synthetic control above still ran)"
fi

found=$(unguarded "$ROOT")
[ -z "$found" ] && echo "ok every program a test runs ungated is built with \$HOST_CC, and no arm64 with \$CC" ||
  fail "tests run what \$CC built (x86_64, under clang22's cfg) on this host, or build arm64 with it; build helpers with \$HOST_CC, arm64 with \$CC_ARM64, or gate the row:
$found"

HOSTDEFAULT='cc = "cc"|snprintf\(cmd, sizeof cmd, "(cc|nm) '
printf '    const char *cc = "cc";\n' >"$TMP/control.c"
grep -q -E "$HOSTDEFAULT" "$TMP/control.c" && echo "ok the live_test.c scan sees a host compiler default" ||
  fail "control: the live_test.c scan misses 'const char *cc = \"cc\"'"
rc=0
c=$(grep -n -E "$HOSTDEFAULT" "$ROOT/tests/live_test.c") || rc=$?
if [ "$rc" -ge 2 ]; then fail "grep exited $rc reading tests/live_test.c"
elif [ -z "$c" ]; then echo "ok live_test.c takes no host compiler default"
else fail "live_test.c: $c"; fi

[ "$fails" = 0 ]
