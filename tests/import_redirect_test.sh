#!/bin/sh
# tests/import_redirect_test.sh -- the `import redirect SYMBOL FROM-LIB TO-LIB`
# statement and the `exports` verb.
#
# Fixtures are linked on this host with -mmacosx-version-min=10.9, so they
# carry LC_DYLD_INFO rather than chained fixups everywhere. Where a case needs a
# bind-stream shape no linker can be asked for -- one lazy ordinal opcode
# serving two symbols, one symbol bound from two libraries, a stream with no
# room to grow into -- tests/mkbindstream.c writes it by hand into a linked
# binary, which keeps the load commands real. Facts about a result come from
# `drydock-macho-rewrite imports`/`exports`/`info` and mkbindstream's `info`,
# read by column name; never from otool or nm text, and never an exact count or
# ordinal the host's linker chose.
set -eu
BIN="${1:?usage: import_redirect_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "import_redirect_test: $DMR not found" >&2; exit 1; }
[ -x "$BIN/makefat" ] || { echo "import_redirect_test: need makefat in $BIN" >&2; exit 1; }
CC="${CC:-clang}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FF="-mmacosx-version-min=10.9"
T=$(mktemp -d "${TMPDIR:-/tmp}/import_redirect_test.XXXXXX")
T=$(cd "$T" && pwd -P)

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }
reached_end=0
trap 'rc=$?; rm -rf "$T"; if [ "$reached_end" -eq 0 ]; then
    echo "import_redirect_test: FATAL -- aborted early (exit $rc); everything after the last PASS/FAIL line never ran" >&2
fi' EXIT

"$CC" -O2 -o "$T/mkbindstream" "$HERE/mkbindstream.c"
MKB="$T/mkbindstream"

# has_import FILE SYMBOL INSTALL_NAME STREAM -- does `imports` report that row?
has_import() {
    "$DMR" imports "$1" 2>/dev/null | awk -F'\t' -v s="$2" -v l="$3" -v st="$4" '
        NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
        $c["symbol"] == s && $c["install_name"] == l && $c["stream"] == st { f = 1 }
        END { exit !f }'
}
# ordinal_of FILE INSTALL_NAME -- the ordinal `info` gives that library.
ordinal_of() {
    "$DMR" info "$1" | awk -v p="$2" 'index($0, "  ordinal=") == 1 {
        split($0, a, " path="); o = a[1]; sub("  ordinal=", "", o)
        if (a[2] == p) { print o; exit } }'
}
field() { "$MKB" info "$1" | awk -v k="$2" -v n="$3" '$1 == k { print $n }'; }

# run FILE OUT STATEMENT... -- the statements, one per line, on stdin.
run() {
    run_in=$1 run_out=$2; shift 2
    rm -f "$run_out"
    run_rc=0
    printf '%s\n' "$@" | "$DMR" "$run_in" "$run_out" >"$T/run.out" 2>"$T/run.err" || run_rc=$?
    return 0
}

# --- libraries ----------------------------------------------------------------
cat >"$T/a.c" <<'EOF'
int a_data(void) { return 7; }
int a_fn(void) { return 8; }
int a_fn2(void) { return 9; }
int dup(void) { return 10; }
EOF
cat >"$T/b.c" <<'EOF'
int dup(void) { return 20; }
EOF
# helper is a local symbol: in the symbol table, and not an export.
cat >"$T/shim.c" <<'EOF'
static int helper(void) { return 41; }
int a_data(void) { return helper() + 1; }
int a_fn(void) { return 43; }
int f1(void) { return 101; }
int f16(void) { return 116; }
EOF
LIBA="$T/liba.dylib" LIBB="$T/libb.dylib" SHIM="$T/libshim.dylib"
"$CC" -dynamiclib $FF -install_name "$LIBA" -o "$LIBA" "$T/a.c"
"$CC" -dynamiclib $FF -install_name "$LIBB" -o "$LIBB" "$T/b.c"
"$CC" -dynamiclib $FF -install_name "$SHIM" -o "$SHIM" "$T/shim.c"

cat >"$T/reg.c" <<'EOF'
int a_data(void);
int (*p)(void) = a_data;
int main(void) { return p(); }
EOF
cat >"$T/lazy.c" <<'EOF'
int a_fn(void);
int main(void) { return a_fn(); }
EOF
cat >"$T/two.c" <<'EOF'
int a_fn(void); int a_fn2(void); int dup(void);
int main(void) { return a_fn() + a_fn2() + dup(); }
EOF
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/reg" "$T/reg.c" "$LIBA"
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/lazy" "$T/lazy.c" "$LIBA"
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/two" "$T/two.c" "$LIBA" "$LIBB"

# ============================================================================
# the regular bind stream, in place
# ============================================================================
# liba's only regular bind is _a_data, so its ordinal opcode serves nothing
# that stays: it is replaced where it stands, and nothing moves.
has_import "$T/reg" _a_data "$LIBA" bind \
    && ok "regular: precondition -- _a_data is a regular bind from liba" \
    || bad "regular: precondition" "$("$DMR" imports "$T/reg")"
run "$T/reg" "$T/reg.out" "dylib append $SHIM" "import redirect _a_data $LIBA $SHIM"
[ "$run_rc" -eq 0 ] && ok "regular: import redirect succeeds" \
    || bad "regular: redirect" "exit $run_rc: $(cat "$T/run.err")"
has_import "$T/reg.out" _a_data "$SHIM" bind \
    && ok "regular: ... _a_data now binds to the shim" \
    || bad "regular: moved" "$("$DMR" imports "$T/reg.out")"
[ "$(field "$T/reg" bind 2)" = "$(field "$T/reg.out" bind 2)" ] &&
    [ "$(field "$T/reg" bind 3)" = "$(field "$T/reg.out" bind 3)" ] &&
    [ "$(wc -c <"$T/reg")" = "$(wc -c <"$T/reg.out")" ] \
    && ok "regular: ... in place: the bind stream's offset and size, and the file's size, are unchanged" \
    || bad "regular: in place" "bind $(field "$T/reg" bind 2)+$(field "$T/reg" bind 3) -> $(field "$T/reg.out" bind 2)+$(field "$T/reg.out" bind 3)"
[ "$("$MKB" nlist "$T/reg.out" _a_data)" = "$(ordinal_of "$T/reg.out" "$SHIM")" ] &&
    [ "$("$MKB" nlist "$T/reg" _a_data)" = "$(ordinal_of "$T/reg" "$LIBA")" ] \
    && ok "regular: ... and the symbol table's undefined _a_data names the shim's ordinal too" \
    || bad "regular: nlist" "was $("$MKB" nlist "$T/reg" _a_data), now $("$MKB" nlist "$T/reg.out" _a_data)"
grep -q "bind stream rewritten in place" "$T/run.err" \
    && ok "regular: ... and the report says so" \
    || bad "regular: report" "$(cat "$T/run.err")"
rc=0; "$T/reg" || rc=$?; rc2=0; "$T/reg.out" || rc2=$?
[ "$rc" -eq 7 ] && [ "$rc2" -eq 42 ] \
    && ok "regular: ... and the program now calls the shim's a_data (7 before, 42 after)" \
    || bad "regular: runs" "exit $rc before, $rc2 after"

# ============================================================================
# the lazy bind stream
# ============================================================================
has_import "$T/lazy" _a_fn "$LIBA" lazy \
    && ok "lazy: precondition -- _a_fn is a lazy bind from liba" \
    || bad "lazy: precondition" "$("$DMR" imports "$T/lazy")"
run "$T/lazy" "$T/lazy.out" "dylib append $SHIM" "import redirect _a_fn $LIBA $SHIM"
[ "$run_rc" -eq 0 ] && has_import "$T/lazy.out" _a_fn "$SHIM" lazy \
    && ok "lazy: _a_fn's lazy bind now names the shim" \
    || bad "lazy: moved" "exit $run_rc: $(cat "$T/run.err")"
[ "$(field "$T/lazy" lazy 2)" = "$(field "$T/lazy.out" lazy 2)" ] &&
    [ "$(field "$T/lazy" lazy 3)" = "$(field "$T/lazy.out" lazy 3)" ] \
    && ok "lazy: ... and the lazy stream did not move or change size" \
    || bad "lazy: in place" "lazy $(field "$T/lazy" lazy 2)+$(field "$T/lazy" lazy 3) -> $(field "$T/lazy.out" lazy 2)+$(field "$T/lazy.out" lazy 3)"
rc=0; "$T/lazy.out" || rc=$?
[ "$rc" -eq 43 ] && ok "lazy: ... and the program calls the shim's a_fn (exit 43)" \
    || bad "lazy: runs" "exit $rc"

# ============================================================================
# a regular stream that has to grow
# ============================================================================
# mkbindstream leaves no byte of slack after the stream, and _x shares its
# ordinal opcode with _y, which stays -- so the redirect needs two more opcodes
# and there is nowhere in place to put them.
A=$(ordinal_of "$T/reg" "$LIBA")
"$MKB" set "$T/reg" "$T/grow" bind "ord:$A" sym:_x type:1 seg:2:0 do sym:_y do done
run "$T/grow" "$T/grow.out" "dylib append $SHIM" "import redirect _x $LIBA $SHIM"
[ "$run_rc" -eq 0 ] && ok "grow: a redirect that must grow the bind stream succeeds, with no directive" \
    || bad "grow: redirect" "exit $run_rc: $(cat "$T/run.err")"
has_import "$T/grow.out" _x "$SHIM" bind && has_import "$T/grow.out" _y "$LIBA" bind \
    && ok "grow: ... _x names the shim and _y still names liba" \
    || bad "grow: binds" "$("$DMR" imports "$T/grow.out")"
grep -q "bind stream grew from [0-9,]* to [0-9,]* bytes; it now lives at file offset 0x" "$T/run.err" \
    && ok "grow: ... and stderr announces how much it grew and where it now lives" \
    || bad "grow: announced" "$(cat "$T/run.err")"
[ "$(field "$T/grow.out" bind 2)" != "$(field "$T/grow" bind 2)" ] &&
    [ "$(field "$T/grow.out" linkedit 2)" -gt "$(field "$T/grow" linkedit 2)" ] \
    && ok "grow: ... it moved, and __LINKEDIT grew to cover it" \
    || bad "grow: moved" "$("$MKB" info "$T/grow.out")"

# ============================================================================
# ordinals above 15
# ============================================================================
# Sixteen libraries ahead of libSystem put the shim above 15, where only
# SET_DYLIB_ORDINAL_ULEB can name it.
i=1; libs=""; calls=""; decls=""
while [ "$i" -le 16 ]; do
    printf 'int f%d(void) { return %d; }\n' "$i" "$i" >"$T/f$i.c"
    "$CC" -dynamiclib $FF -install_name "$T/libf$i.dylib" -o "$T/libf$i.dylib" "$T/f$i.c"
    libs="$libs $T/libf$i.dylib"; decls="$decls int f$i(void);"; calls="$calls + f$i()"
    i=$((i + 1))
done
printf '%s\nint (*p)(void) = f1;\nint main(void) { return (p() %s) & 0; }\n' "$decls" "$calls" >"$T/many.c"
# shellcheck disable=SC2086
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/many" "$T/many.c" $libs
cat >"$T/many_main.c" <<'EOF'
#include <stdio.h>
int f1(void); int f16(void);
int (*p)(void) = f1;
int main(void) { printf("%d %d\n", p(), f16()); return 0; }
EOF
# shellcheck disable=SC2086
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/many2" "$T/many_main.c" $libs
F16=$(ordinal_of "$T/many2" "$T/libf16.dylib")
[ "${F16:-0}" -gt 15 ] && has_import "$T/many2" _f16 "$T/libf16.dylib" lazy \
    && ok "ordinal>15: precondition -- libf16 is ordinal $F16 and _f16 binds lazily" \
    || bad "ordinal>15: precondition" "ordinal ${F16:-none}: $("$DMR" imports "$T/many2")"
run "$T/many2" "$T/many2.out" "dylib append $SHIM" \
    "import redirect _f16 $T/libf16.dylib $SHIM" "import redirect _f1 $T/libf1.dylib $SHIM"
[ "$run_rc" -eq 0 ] && [ "$(ordinal_of "$T/many2.out" "$SHIM")" -gt 15 ] \
    && ok "ordinal>15: redirecting to the shim at ordinal $(ordinal_of "$T/many2.out" "$SHIM") succeeds" \
    || bad "ordinal>15: redirect" "exit $run_rc: $(cat "$T/run.err")"
has_import "$T/many2.out" _f16 "$SHIM" lazy && has_import "$T/many2.out" _f1 "$SHIM" bind \
    && ok "ordinal>15: ... a lazy and a regular bind both name it" \
    || bad "ordinal>15: binds" "$("$DMR" imports "$T/many2.out")"
[ "$("$T/many2.out")" = "101 116" ] \
    && ok "ordinal>15: ... and the program calls both of the shim's functions" \
    || bad "ordinal>15: runs" "printed '$("$T/many2.out" 2>&1)', wanted '101 116'"
# A lazy program whose one-byte ordinal opcode cannot hold 16 or more: the
# stub helpers address every lazy program by its offset, so it cannot grow.
has_import "$T/many" _f2 "$T/libf2.dylib" lazy || bad "ordinal>15: precondition" "_f2 not lazy"
run "$T/many" "$T/many.out" "dylib append $SHIM" "import redirect _f2 $T/libf2.dylib $SHIM"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/many.out" ] && grep -q "cannot encode ordinal" "$T/run.err" \
    && ok "ordinal>15: a one-byte lazy ordinal that cannot hold the shim's is refused, nothing written" \
    || bad "ordinal>15: IMM lazy" "exit $run_rc: $(cat "$T/run.err")"

# ============================================================================
# refusals and non-matches
# ============================================================================
# One lazy ordinal opcode serving _a_fn, which moves, and _a_fn2, which stays.
A=$(ordinal_of "$T/two" "$LIBA")
"$MKB" set "$T/two" "$T/shared" lazy seg:2:0 "ord:$A" sym:_a_fn do sym:_a_fn2 do done
run "$T/shared" "$T/shared.out" "dylib append $SHIM" "import redirect _a_fn $LIBA $SHIM"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/shared.out" ] && grep -q "share one library-ordinal opcode" "$T/run.err" \
    && ok "shared lazy: a lazy opcode serving a moved and an unmoved symbol is refused, nothing written" \
    || bad "shared lazy" "exit $run_rc: $(cat "$T/run.err")"

# _dup bound once from liba and once from libb: only liba's may move.
B=$(ordinal_of "$T/two" "$LIBB")
"$MKB" set "$T/two" "$T/dup" bind "ord:$A" sym:_dup type:1 seg:2:0 do "ord:$B" sym:_dup do done
run "$T/dup" "$T/dup.out" "dylib append $SHIM" "import redirect _dup $LIBA $SHIM"
[ "$run_rc" -eq 0 ] && has_import "$T/dup.out" _dup "$SHIM" bind &&
    has_import "$T/dup.out" _dup "$LIBB" bind && ! has_import "$T/dup.out" _dup "$LIBA" bind \
    && ok "same name, other library: libb's _dup stays, liba's moves" \
    || bad "same name, other library" "exit $run_rc: $("$DMR" imports "$T/dup.out" 2>&1)"

run "$T/lazy" "$T/nolib.out" "import redirect _a_fn $LIBA $SHIM"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/nolib.out" ] && grep -q "is not a library this image loads" "$T/run.err" \
    && ok "TO-LIB not loaded: refused, nothing written" \
    || bad "TO-LIB not loaded" "exit $run_rc: $(cat "$T/run.err")"

"$MKB" set "$T/reg" "$T/weak" weak sym:_a_data type:1 seg:2:0 do done
run "$T/weak" "$T/weak.out" "dylib append $SHIM" "import redirect _a_data $LIBA $SHIM"
[ "$run_rc" -eq 0 ] && grep -q "WARNING: _a_data appears in the weak-bind table" "$T/run.err" \
    && ok "weak: a weak bind of the symbol is warned about" \
    || bad "weak: warning" "exit $run_rc: $(cat "$T/run.err")"
"$DMR" imports "$T/weak.out" | awk -F'\t' 'NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["symbol"] == "_a_data" && $c["stream"] == "weak" && $c["install_name"] == "-" { f = 1 }
    END { exit !f }' && has_import "$T/weak.out" _a_data "$SHIM" bind \
    && ok "weak: ... and left alone, while the regular bind moved" \
    || bad "weak: untouched" "$("$DMR" imports "$T/weak.out")"

# Nothing in the rewrite writes the weak-bind table, but one that overlaps the
# bind stream changes with it -- and only the verification after the rewrite
# can see that.
"$MKB" alias "$T/reg" "$T/alias"
run "$T/alias" "$T/alias.out" "dylib append $SHIM" "import redirect _a_data $LIBA $SHIM"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/alias.out" ] && grep -q "verification failed" "$T/run.err" \
    && ok "verification: a weak-bind table overlapping the bind stream is caught after the rewrite, nothing written" \
    || bad "verification: overlap" "exit $run_rc: $(cat "$T/run.err")"

run "$T/lazy" "$T/none.out" "dylib append $SHIM" "import redirect _nosuch $LIBA $SHIM"
[ "$run_rc" -eq 0 ] && grep -q "import redirect _nosuch .* matched nothing" "$T/run.err" \
    && ok "matched nothing: reported, not refused" \
    || bad "matched nothing" "exit $run_rc: $(cat "$T/run.err")"
run "$T/lazy" "$T/none.out" fatal-warnings "dylib append $SHIM" "import redirect _nosuch $LIBA $SHIM"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/none.out" ] \
    && ok "matched nothing: ... and refused under fatal-warnings" \
    || bad "matched nothing: fatal" "exit $run_rc"

run "$T/lazy" "$T/same.out" "import redirect _a_fn $LIBA $LIBA"
[ "$run_rc" -eq 2 ] && grep -q "FROM-LIB and TO-LIB are both" "$T/run.err" \
    && ok "parse: FROM-LIB and TO-LIB the same is a parse error (2)" \
    || bad "parse: same lib" "exit $run_rc: $(cat "$T/run.err")"

cc_chained_src="$HERE/mkchained.c"
"$CC" -O2 -I "$HERE/../src" -o "$T/mkchained" "$cc_chained_src"
"$T/mkchained" make "$T/chained"
run "$T/chained" "$T/chained.out" "import redirect _mkchained_sym /a /b"
[ "$run_rc" -eq 1 ] && grep -q "put \`fixups set classic\` before this statement" "$T/run.err" \
    && ok "chained fixups: refused, naming fixups set classic as the remedy" \
    || bad "chained fixups" "exit $run_rc: $(cat "$T/run.err")"

# ============================================================================
# fat: every slice
# ============================================================================
"$BIN/makefat" "$T/fat" "$T/lazy" 0x1000007 3 12 "$T/lazy" 0x1000007 8 12
run "$T/fat" "$T/fat.out" "dylib append $SHIM" "import redirect _a_fn $LIBA $SHIM"
n=$("$DMR" imports "$T/fat.out" | awk -F'\t' -v s="$SHIM" 'NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["symbol"] == "_a_fn" && $c["install_name"] == s { n++ } END { print n + 0 }')
[ "$run_rc" -eq 0 ] && [ "$n" -eq 2 ] \
    && ok "fat: both slices' _a_fn name the shim" \
    || bad "fat" "exit $run_rc, $n slices moved: $(cat "$T/run.err")"

# ============================================================================
# exports
# ============================================================================
"$DMR" exports "$SHIM" >"$T/exp.out" 2>"$T/exp.err" || bad "exports: shim" "$(cat "$T/exp.err")"
[ "$(head -1 "$T/exp.out")" = "$(printf 'arch\tsymbol\tkind\tweak\tsource')" ] \
    && ok "exports: header row names the five columns, in order" \
    || bad "exports: header" "$(head -1 "$T/exp.out")"
syms=$(awk -F'\t' 'NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["kind"] == "regular" && $c["source"] == "trie" { print $c["symbol"] }' "$T/exp.out" | sort | tr '\n' ' ')
[ "$syms" = "_a_data _a_fn _f1 _f16 " ] \
    && ok "exports: a linked dylib's four functions, from its export trie" \
    || bad "exports: shim symbols" "got '$syms'"
"$MKB" noexports "$SHIM" "$T/shim_notrie"
"$DMR" exports "$T/shim_notrie" >"$T/exp2.out" 2>"$T/exp2.err" || bad "exports: symtab" "$(cat "$T/exp2.err")"
syms2=$(awk -F'\t' 'NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["source"] == "symtab" { print $c["symbol"] }' "$T/exp2.out" | sort | tr '\n' ' ')
[ "$syms2" = "$syms" ] \
    && ok "exports: with no export trie, the same symbols from the symbol table" \
    || bad "exports: symtab fallback" "got '$syms2', wanted '$syms'"
"$BIN/makefat" "$T/shim_fat" "$SHIM" 0x1000007 3 12 "$SHIM" 0x1000007 8 12
nf=$("$DMR" exports "$T/shim_fat" | awk -F'\t' 'NR>1 && $2 == "_a_fn" { n++ } END { print n + 0 }')
[ "$nf" -eq 2 ] && ok "exports: a fat dylib reports each slice" \
    || bad "exports: fat" "_a_fn in $nf slices"
rc=0; "$DMR" exports "$HERE/not-a-macho.txt" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok "exports: refuses a non-Mach-O (exit 1)" || bad "exports: non-Mach-O" "exit $rc"

reached_end=1
echo "import_redirect_test: $fails failure(s)"
[ "$fails" -eq 0 ]
