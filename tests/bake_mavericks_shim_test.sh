#!/bin/sh
# tests/bake_mavericks_shim_test.sh -- compat/bake-mavericks-shim.sh end to end:
# Wowfunhappy's bake-mavericks-shim.py command line, its summary, the one
# edit script it composes, and the divergences compat/README.md's
# bake-mavericks-shim table declares.
#
#   sh tests/bake_mavericks_shim_test.sh <bindir>
#
# The central case RUNS what it bakes: a program that calls getpid() and
# getppid() from libSystem, baked against a shim that defines both, must call
# the shim's with no DYLD_* variable set. Facts about a binary come from
# `drydock-macho-rewrite imports`/`info`, read by column name, never from
# otool text or a count this host's linker chose.
set -u

BIN="${1:?usage: bake_mavericks_shim_test.sh <bindir>}"
BIN=$(cd "$BIN" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
CC="${CC:-clang}"
FF="-mmacosx-version-min=10.9"
# platform: a modern ld leaves 64 bytes of header pad by default, too few for
# a shim path under $TMPDIR; 10.9's leaves thousands. Ask for room explicitly.
PAD="-Wl,-headerpad,0x400"
BAKE="$BIN/bake-mavericks-shim"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$BAKE" ] || { echo "bake_mavericks_shim_test: $BAKE not found or not executable" >&2; exit 1; }
[ -x "$DMR" ] || { echo "bake_mavericks_shim_test: $DMR not found or not executable" >&2; exit 1; }

fail=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=$((fail + 1)); }
skip() { echo "SKIP $1: $2"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/bake-shim-test.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT INT TERM
sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }
# has_import FILE SYMBOL -- does FILE bind SYMBOL to the library $HI_LIB names?
# The path reaches awk through the environment, which does not escape-process it.
has_import() {
    "$DMR" imports "$1" 2>/dev/null | awk -F'\t' -v s="$2" '
        NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
        $c["symbol"] == s && $c["install_name"] == ENVIRON["HI_LIB"] { f = 1 }
        END { exit !f }'
}
# bake ARG... -- run the wrapper in $T; stdout, stderr and status land in
# $T/b.out, $T/b.err and $brc.
bake() {
    brc=0
    ( cd "$T" && "$BAKE" "$@" ) >"$T/b.out" 2>"$T/b.err" || brc=$?
}

for sh in /bin/sh /bin/ksh; do
    if [ -x "$sh" ]; then
        "$sh" -n "$ROOT/compat/bake-mavericks-shim.sh" 2>"$T/synerr" \
            && ok "$sh -n bake-mavericks-shim.sh" \
            || bad "$sh -n bake-mavericks-shim.sh" "$(cat "$T/synerr")"
    else
        skip "$sh -n bake-mavericks-shim.sh" "$sh is not present on this host"
    fi
done

# ---- fixtures ------------------------------------------------------------
cat >"$T/shim.c" <<'EOF'
int getpid(void) { return 4242; }
int getppid(void) { return 777; }
int a_fn(void) { return 43; }
int shim_only(void) { return 5; }
EOF
cat >"$T/a.c" <<'EOF'
int a_fn(void) { return 8; }
EOF
cat >"$T/prog.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
int a_fn(void);
int (*fp)(void) = getppid;
int main(void) { printf("%d %d %d\n", (int)getpid(), fp(), a_fn()); return 0; }
EOF
cat >"$T/reuse.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
int shim_only(void);
int main(void) { printf("%d %d\n", (int)getpid(), shim_only()); return 0; }
EOF
cat >"$T/other.c" <<'EOF'
int main(void) { return 0; }
EOF
SHIM="$T/libshim.dylib" LIBA="$T/liba.dylib"
"$CC" -dynamiclib $FF -install_name "$SHIM" -o "$SHIM" "$T/shim.c"
"$CC" -dynamiclib $FF -install_name "$LIBA" -o "$LIBA" "$T/a.c"
"$CC" $FF $PAD -o "$T/prog" "$T/prog.c" "$LIBA"
# -lSystem ahead of the shim, so getpid resolves to libSystem and the shim
# is loaded for shim_only alone.
"$CC" $FF $PAD -o "$T/reuse" "$T/reuse.c" -lSystem "$SHIM"
"$CC" $FF $PAD -o "$T/other" "$T/other.c"
HI_LIB=$SHIM; export HI_LIB

# ---- 1. the central case: bake, then run with no DYLD_* at all ------------
before=$(sha "$T/prog")
bake prog --shim "$SHIM"
[ "$brc" -eq 0 ] && ok "bake: exits 0" || bad "bake" "exit $brc: $(cat "$T/b.err")"
[ -x "$T/prog.selfcontained" ] && ok "bake: OUTPUT defaults to INPUT.selfcontained" \
    || bad "bake: default output" "no $T/prog.selfcontained"
[ "$(sha "$T/prog")" = "$before" ] && ok "bake: INPUT is untouched" || bad "bake: input" "changed"
run=$(env -i PATH=/usr/bin:/bin "$T/prog.selfcontained" 2>&1)
set -- $run
[ "${1:-}" = 4242 ] && [ "${2:-}" = 777 ] && [ "${3:-}" = 43 ] \
    && ok "bake: the baked binary calls the shim's getpid, getppid and a_fn with no DYLD_* set" \
    || bad "bake: runs" "printed '$run', wanted '4242 777 43'"
run0=$(env -i PATH=/usr/bin:/bin "$T/prog" 2>&1)
set -- $run0
[ "${1:-}" != 4242 ] && [ "${2:-}" != 777 ] && [ "${3:-}" = 8 ] \
    && ok "bake: ... where the input called libSystem's and liba's" \
    || bad "bake: control" "the unbaked input printed '$run0'"
HI_LIB=/usr/lib/libSystem.B.dylib; export HI_LIB
has_import "$T/prog.selfcontained" _printf \
    && ok "bake: ... and _printf, which the shim does not export, still binds to libSystem" \
    || bad "bake: printf untouched" "$("$DMR" imports "$T/prog.selfcontained")"
HI_LIB=$SHIM; export HI_LIB
# platform: a modern ld signs what it links, 10.9's does not -- so which line
# is right is read off the input, not assumed.
sig='none present'
"$DMR" info "$T/prog" | grep -q ' LC_CODE_SIGNATURE ' && sig=stripped
grep -qxF "shim exports 4 symbols ($SHIM)" "$T/b.out" &&
    grep -qx "code signature: $sig" "$T/b.out" &&
    grep -qx 'shim linked as ordinal [0-9]* (newly added)' "$T/b.out" &&
    grep -qx 'redirected 3 imports to the shim; bind data: .*:' "$T/b.out" &&
    grep -qx '    _getppid' "$T/b.out" &&
    grep -qxF "wrote self-contained binary: prog.selfcontained" "$T/b.out" \
    && ok "bake: the Python's summary lines, with this fixture's facts" \
    || bad "bake: summary" "$(cat "$T/b.out")"
cp "$T/prog" "$T/plain"
chmod 644 "$T/plain"
bake plain --shim "$SHIM"
[ "$brc" -eq 0 ] && [ "$(stat -f %Lp "$T/plain.selfcontained")" = 755 ] \
    && ok "bake: OUTPUT is mode 755 whatever INPUT's mode, as the Python leaves it" \
    || bad "bake: mode" "exit $brc, mode $(stat -f %Lp "$T/plain.selfcontained" 2>&1)"

# ---- 2. OUTPUT, --shim=PATH, and OUTPUT naming INPUT ---------------------
bake --shim="$SHIM" prog named
[ "$brc" -eq 0 ] && [ -f "$T/named" ] && [ ! -e "$T/named.selfcontained" ] \
    && ok "args: an explicit OUTPUT, with --shim=PATH before the positionals" \
    || bad "args: OUTPUT" "exit $brc: $(cat "$T/b.err")"
cp "$T/prog" "$T/inplace"
bake inplace inplace --shim "$SHIM"
[ "$brc" -eq 0 ] && has_import "$T/inplace" _getpid \
    && ok "args: OUTPUT may be INPUT, which is then replaced" \
    || bad "args: in place" "exit $brc: $(cat "$T/b.err")"

# ---- 3. the shim already loaded is reused --------------------------------
bake reuse --shim "$SHIM"
n=$("$DMR" info "$T/reuse.selfcontained" | grep -c "^  ordinal=[0-9]* path=$SHIM\$")
[ "$brc" -eq 0 ] && grep -qx 'shim linked as ordinal [0-9]* (already present, reused)' "$T/b.out" &&
    [ "$n" -eq 1 ] \
    && ok "reuse: a shim INPUT already loads is reused, not loaded twice" \
    || bad "reuse" "exit $brc, $n load commands: $(cat "$T/b.out" "$T/b.err")"

# ---- 4. a signed INPUT ---------------------------------------------------
cp "$T/prog" "$T/signed"
if codesign -s - "$T/signed" 2>"$T/cs.err" &&
   "$DMR" info "$T/signed" | grep -q ' LC_CODE_SIGNATURE '; then
    bake signed --shim "$SHIM"
    [ "$brc" -eq 0 ] && grep -qx 'code signature: stripped' "$T/b.out" &&
        ! "$DMR" info "$T/signed.selfcontained" | grep -q ' LC_CODE_SIGNATURE ' \
        && ok "signed: the code signature is stripped" \
        || bad "signed" "exit $brc: $(cat "$T/b.out" "$T/b.err")"
else
    bad "signed: precondition" "codesign -s - left no LC_CODE_SIGNATURE: $(cat "$T/cs.err")"
fi

# ---- 5. refusals ---------------------------------------------------------
bake other --shim "$SHIM"
[ "$brc" -eq 1 ] && [ ! -e "$T/other.selfcontained" ] &&
    grep -q "none of the binary's imports are provided by the shim" "$T/b.err" \
    && ok "refuse: nothing the shim provides -- exit 1, nothing written" \
    || bad "refuse: nothing to do" "exit $brc: $(cat "$T/b.err")"
bake nosuch --shim "$SHIM"
[ "$brc" -eq 1 ] && grep -qx 'error: input not found: nosuch' "$T/b.err" \
    && ok "refuse: input not found" || bad "refuse: no input" "exit $brc: $(cat "$T/b.err")"
bake prog --shim "$T/nosuch.dylib"
[ "$brc" -eq 1 ] && grep -qxF "error: shim not found: $T/nosuch.dylib" "$T/b.err" \
    && ok "refuse: shim not found" || bad "refuse: no shim" "exit $brc: $(cat "$T/b.err")"
bake
[ "$brc" -eq 2 ] && grep -q 'the following arguments are required: input' "$T/b.err" \
    && ok "usage: no INPUT is a usage error (2)" || bad "usage: none" "exit $brc: $(cat "$T/b.err")"
bake --bogus prog
[ "$brc" -eq 2 ] && grep -q 'unrecognized arguments: --bogus' "$T/b.err" \
    && ok "usage: an unknown option is a usage error (2)" || bad "usage: bogus" "exit $brc"

# No room in the header for the shim's load command: the wrapper declares no
# allow-grow, so it refuses, as the Python does. These links take the default
# pad, not $PAD, which is a floor. platform: the linker packs __TEXT's sections
# against the end of a page, so filler costs the pad byte for byte, less an
# alignment `k` measured from the first attempt, modulo the page; the second
# attempt aims 40 bytes above the commands.
pad() { "$DMR" info "$1" | sed -n 's/^header pad: \([0-9]*\) bytes available.*/\1/p'; }
tight() {
    printf '__attribute__((used)) static const char filler[%d] = { 1 };\n' "$1" >"$T/filler.c"
    "$CC" $FF -o "$T/tight" "$T/prog.c" "$T/filler.c" "$LIBA"
    pad "$T/tight"
}
"$CC" $FF -o "$T/loose" "$T/prog.c" "$LIBA"
p0=$(pad "$T/loose")
fill=$((p0 - 40))
p1=$(tight "$fill")
k=$(( ((p0 - fill - p1) % 4096 + 4096) % 4096 ))
fill=$((p0 - k - 40))
[ "$fill" -gt 0 ] && p1=$(tight "$fill")
need=$(( (24 + ${#SHIM} + 1 + 7) / 8 * 8 ))
if [ -n "$p1" ] && [ "$p1" -lt "$need" ]; then
    bake tight --shim "$SHIM"
    [ "$brc" -eq 1 ] && [ ! -e "$T/tight.selfcontained" ] && ! grep -q 'shim linked' "$T/b.out" \
        && ok "refuse: no header room for the shim ($p1 bytes, $need needed) -- exit 1, nothing written" \
        || bad "refuse: no room" "exit $brc: $(cat "$T/b.err")"
else
    bad "refuse: no room: precondition" "pad went from $p0 to ${p1:-unknown}; wanted under $need"
fi

# ---- 6. the weak-bind table ---------------------------------------------
"$CC" -O2 -o "$T/mkbindstream" "$HERE/mkbindstream.c"
"$T/mkbindstream" set "$T/prog" "$T/weak" weak sym:_getpid type:1 seg:2:0 do done
bake weak --shim "$SHIM"
[ "$brc" -eq 0 ] &&
    grep -qx 'WARNING: these shim symbols appear in the weak-bind table and were NOT redirected:' "$T/b.err" &&
    grep -qx '  _getpid' "$T/b.err" \
    && ok "weak: a shim symbol in the weak-bind table is warned about, in the Python's words" \
    || bad "weak" "exit $brc: $(cat "$T/b.err")"

# ---- 7. a flat-lookup bind names no library, so nothing redirects it -----
# (a divergence: the Python re-points every regular bind of a shim symbol,
# whatever ordinal it had, flat lookup included)
"$T/mkbindstream" set "$T/prog" "$T/flat" bind flat sym:_getuid type:1 seg:2:0 do done
bake flat --shim "$SHIM"
"$DMR" imports "$T/flat.selfcontained" 2>/dev/null | awk -F'\t' '
    NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["symbol"] == "_getuid" && $c["ordinal"] == "flat" && $c["stream"] == "bind" { f = 1 }
    END { exit !f }'
flat_rc=$?
[ "$brc" -eq 0 ] && [ "$flat_rc" -eq 0 ] && has_import "$T/flat.selfcontained" _getpid \
    && ok "flat: a flat-lookup bind of a shim symbol is left flat, while the rest are baked" \
    || bad "flat" "exit $brc: $("$DMR" imports "$T/flat.selfcontained" 2>&1)"

# ---- 8. fat, which the Python refuses ------------------------------------
"$BIN/makefat" "$T/fat" "$T/prog" 0x1000007 3 12 "$T/prog" 0x1000007 8 12
bake fat --shim "$SHIM"
nf=$("$DMR" imports "$T/fat.selfcontained" 2>/dev/null | awk -F'\t' 'NR==1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
    $c["symbol"] == "_getpid" && $c["install_name"] == ENVIRON["HI_LIB"] { n++ } END { print n + 0 }')
[ "$brc" -eq 0 ] && [ "$nf" -eq 2 ] \
    && ok "fat: every slice is baked (a divergence: the Python refuses fat input)" \
    || bad "fat" "exit $brc, $nf slices: $(cat "$T/b.err")"

# ---- 9. chained fixups, which the Python refuses -------------------------
"$CC" -mmacosx-version-min=12.0 $PAD -o "$T/chained" "$T/prog.c" "$LIBA" 2>/dev/null
if [ -f "$T/chained" ] && "$DMR" info "$T/chained" 2>/dev/null | grep -q ' LC_DYLD_CHAINED_FIXUPS '; then
    bake chained --shim "$SHIM"
    [ "$brc" -eq 0 ] && has_import "$T/chained.selfcontained" _getpid &&
        ! "$DMR" info "$T/chained.selfcontained" | grep -q ' LC_DYLD_CHAINED_FIXUPS ' \
        && ok "chained: converted with fixups set classic, then baked (a divergence: the Python refuses)" \
        || bad "chained" "exit $brc: $(cat "$T/b.err")"
else
    skip "chained: converted, then baked" "this host's linker cannot emit chained fixups"
fi

echo "bake_mavericks_shim_test: $fail failure(s)"
[ "$fail" -eq 0 ]
