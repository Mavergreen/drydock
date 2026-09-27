#!/bin/sh
# tests/codesign_order_test.sh -- `info`'s resign lines (src/linkedit_order.h)
# must be 10.9's own codesign_allocate's verdict: on every
# tests/linkedit_fixture.h variant and on each after the pass has packed it,
# and on what the CLI suites pack -- the lowering, objc-methods, a grown bind
# stream and a fat file.
#
#   sh tests/codesign_order_test.sh <bindir>
#
# For a file the tool refuses, `resign 10.9:` must be its message ("…" stands
# for words that name offsets or files). For one it accepts, `resign 10.9:`
# must say ok, and the pieces `resign corrupt:` names must be exactly the ones
# the tool's output no longer holds at the offsets the load commands give,
# with "sig" for a signature the output could not hold where its load command
# says. A fat file is compared slice by slice.
#
# Local only: it SKIPs, saying why, unless the codesign_allocate here is
# cctools-862's (10.9's Command Line Tools). Any other tool's verdicts
# legitimately differ.
set -u

BIN="${1:?usage: codesign_order_test.sh <bindir>}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DMR="$BIN/drydock-macho-rewrite"
MK="$BIN/mklinkedit"
for x in "$DMR" "$MK" "$BIN/makefat"; do
    [ -x "$x" ] || { echo "codesign_order_test: $x not found or not executable" >&2; exit 1; }
done
CA=$(xcrun -f codesign_allocate 2>/dev/null) || CA=$(command -v codesign_allocate 2>/dev/null) || CA=
[ -n "$CA" ] && [ -x "$CA" ] || { echo "SKIP: no codesign_allocate here"; exit 77; }
strings "$CA" | grep -qx 'cctools-862' ||
    { echo "SKIP: $CA is not cctools-862's, whose verdicts this test pins"; exit 77; }
CC=${CC:-cc}

T=$(mktemp -d "${TMPDIR:-/tmp}/codesign-order.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0 files=0 refused=0 corrupt=0 fat=0

# Does every "…"-separated part of $1 appear in file $2? An empty $1, which
# is `info` printing no verdict at all, does not.
matches() {
    [ -n "$1" ] || return 1
    printf '%s\n' "$1" | sed 's/…/\
/g' | while IFS= read -r part; do
        [ -z "$part" ] || grep -qF -- "$part" "$2" || exit 1
    done
}

# moved IN OUT: the pieces of thin IN whose bytes OUT no longer holds at their
# offsets, as sorted "0xOFF" words, and "sig" when OUT's signature runs past
# OUT or over one of IN's pieces.
moved() {
    "$MK" pieces "$1" | grep -v '^sig ' >"$T/pieces"
    osize=$(wc -c <"$2" | tr -d ' ')
    {
        while read -r name off size; do
            dd if="$1" of="$T/a" bs=1 skip="$off" count="$size" 2>/dev/null
            dd if="$2" of="$T/b" bs=1 skip="$off" count="$size" 2>/dev/null
            cmp -s "$T/a" "$T/b" || printf '0x%x\n' "$off"
        done <"$T/pieces"
        "$MK" pieces "$2" | awk -v n="$osize" -v pf="$T/pieces" '
            $1 == "sig" { so = $2; se = $2 + $3; s = 1 }
            END {
                if (!s) exit
                if (se > n) { print "sig"; exit }
                while ((getline l < pf) > 0) { split(l, f, " ")
                    if (f[2] < se && so < f[2] + f[3]) { print "sig"; exit } } }'
    } | sort -u | tr '\n' ' '
}

# said FILE: the pieces `info`'s resign corrupt line names, the same way.
said() {
    "$DMR" info "$1" 2>/dev/null | sed -n 's/^resign corrupt: //p' >"$T/said"
    {
        grep -o '(0x[0-9a-f]*,' "$T/said" | tr -d '(,'
        grep -q 'code signature' "$T/said" && echo sig
    } | sort -u | tr '\n' ' '
}

check_thin() {   # check_thin FILE OUT: the pieces, for a file the tool accepted
    m=$(moved "$1" "$2"); w=$(said "$1")
    [ -n "$m" ] && corrupt=$((corrupt + 1))
    if [ "$m" != "$w" ]; then
        echo "FAIL $1: the tool moved [$m]; resign corrupt names [$w]"
        fail=$((fail + 1))
    fi
}

check() {
    f=$1
    [ -f "$f" ] || return 0
    files=$((files + 1))
    ours=$("$DMR" info "$f" 2>/dev/null | sed -n 's/^resign 10\.9: //p')
    rm -f "$T/out"
    rc=0; "$CA" -i "$f" -a x86_64 16384 -o "$T/out" 2>"$T/err" || rc=$?
    if [ "$rc" -ne 0 ]; then
        refused=$((refused + 1))
        if [ "$ours" = ok ] || ! matches "$ours" "$T/err"; then
            echo "FAIL $f: the tool says [$(cat "$T/err")], resign 10.9 says [$ours]"
            fail=$((fail + 1))
        fi
        return
    fi
    if [ "$ours" != ok ]; then
        echo "FAIL $f: the tool accepts it, resign 10.9 says [$ours]"
        fail=$((fail + 1))
        return
    fi
    if [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' ')" = cafebabe ]; then
        fat=$((fat + 1))
        for a in $(lipo -info "$f" | sed 's/.*: //'); do
            lipo -thin "$a" "$f" -output "$T/in.$a" && lipo -thin "$a" "$T/out" -output "$T/out.$a" &&
                check_thin "$T/in.$a" "$T/out.$a"
        done
    else
        check_thin "$f" "$T/out"
    fi
}

# ---- the fixture's variants, and each packed ---------------------------------
"$MK" list | while IFS='	' read -r name c tool; do echo "$name"; done >"$T/names"
while read -r name; do
    "$MK" make "$name" "$T/$name" || { echo "FAIL mklinkedit make $name"; fail=$((fail + 1)); continue; }
    check "$T/$name"
    # deleting the signature changes a piece, so the pass runs
    rc=0; printf 'allow-unmatched\nload-command delete codesig\n' |
        "$DMR" "$T/$name" "$T/$name.packed" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && check "$T/$name.packed"
done <"$T/names"

# ---- a load command of the wrong size, of each kind the verdict reads --------
for c in 0x2:24 0xb:80 0x16:16 0x1e:16 0x1d:16 0x26:16 0x29:16 0x2b:16 0x2e:16 0x22:48 \
         0x80000022:48 0xd:24; do
    "$MK" lone "${c%%:*}" 8 "$T/short-${c%%:*}" && check "$T/short-${c%%:*}"
    [ "${c%%:*}" = 0xd ] && continue   # an LC_ID_DYLIB may be longer than its struct
    "$MK" lone "${c%%:*}" $((${c#*:} + 8)) "$T/long-${c%%:*}" && check "$T/long-${c%%:*}"
done
"$MK" short-last "$T/short-last" && check "$T/short-last"

# ---- what the CLI suites pack -------------------------------------------------
run() {   # run IN OUT STATEMENT...
    r_in=$1 r_out=$2; shift 2
    rm -f "$r_out"
    printf '%s\n' "$@" | "$DMR" "$r_in" "$r_out" >/dev/null 2>&1
    check "$r_in"
    check "$r_out"
}
"$CC" -O2 -I "$HERE/../src" -o "$T/mkchained" "$HERE/mkchained.c"
"$T/mkchained" make-signable "$T/chained"
run "$T/chained" "$T/chained.out" 'fixups set classic'
"$CC" -O2 -o "$T/mkrelmeth" "$HERE/mkrelmeth.c"
"$T/mkrelmeth" make codesig+dysymtab "$T/relmeth"
run "$T/relmeth" "$T/relmeth.out" 'objc-methods set absolute'
# import_redirect_test.sh's grown bind stream
"$CC" -O2 -o "$T/mkbindstream" "$HERE/mkbindstream.c"
printf 'int a_data(void) { return 7; }\n' >"$T/a.c"
printf 'int x(void) { return 1; }\n' >"$T/shim.c"
printf 'int a_data(void);\nint (*p)(void) = a_data;\nint main(void) { return p(); }\n' >"$T/reg.c"
FF="-arch x86_64 -mmacosx-version-min=10.9"
"$CC" -dynamiclib $FF -install_name "$T/liba.dylib" -o "$T/liba.dylib" "$T/a.c"
"$CC" -dynamiclib $FF -install_name "$T/libshim.dylib" -o "$T/libshim.dylib" "$T/shim.c"
"$CC" $FF -Wl,-headerpad,0x400 -o "$T/reg" "$T/reg.c" "$T/liba.dylib"
A=$("$DMR" info "$T/reg" | awk -v p="$T/liba.dylib" 'index($0, "  ordinal=") == 1 {
    split($0, a, " path="); o = a[1]; sub("  ordinal=", "", o); if (a[2] == p) { print o; exit } }')
"$T/mkbindstream" set "$T/reg" "$T/grow" bind "ord:$A" sym:_x type:1 seg:2:0 do sym:_y do done
run "$T/grow" "$T/grow.out" "dylib append $T/libshim.dylib" "import redirect _x $T/liba.dylib $T/libshim.dylib"
# a header grow whose rebuilt export trie no longer fits
"$MK" grow-trie "$T/grow-trie"
run "$T/grow-trie" "$T/grow-trie.out" "rpath append /$(printf '%500s' '' | tr ' ' x)"
# a fat file: one slice in order, one that would re-sign corrupt
"$BIN/makefat" "$T/fat" "$T/canonical" 0x1000007 3 12 "$T/hole-16" 0x1000007 8 12
run "$T/fat" "$T/fat.out" 'load-command delete codesig'

if [ "$files" -lt 100 ] || [ "$refused" -eq 0 ] || [ "$corrupt" -eq 0 ] || [ "$fat" -eq 0 ]; then
    echo "FAIL: the corpus is too thin to mean anything: $files files, $refused refused, $corrupt corrupting, $fat fat"
    fail=$((fail + 1))
fi
echo "codesign_order_test: $files files ($refused refused by the tool, $corrupt written corrupt, $fat fat), $fail failure(s)"
[ "$fail" -eq 0 ]
