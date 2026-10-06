#!/bin/sh
# tests/symbol_rename_test.sh -- `symbol rename OLD NEW` on relocatable
# objects, linked with this host's ld64 and run; the object gate's refusals.
#
#   sh tests/symbol_rename_test.sh <bindir>
#
# Hermetic. The fat case prints a SKIP line and goes on where this host's
# compiler cannot make a second 64-bit x86 slice, and the arm64 case where
# this host cannot build or run arm64.
set -u

BIN="${1:?usage: symbol_rename_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "symbol_rename_test: $DMR not found or not executable" >&2; exit 1; }
CC="${CC:-clang}"
FIXTURE_FLAGS="-arch x86_64 -mmacosx-version-min=10.9"

T=$(mktemp -d "${TMPDIR:-/tmp}/symbol_rename_test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

REFUSED=$("$DMR" --capabilities | sed -n 's/^exitcodes .*refused=\([0-9]*\).*/\1/p')
[ -n "$REFUSED" ] || { echo "symbol_rename_test: no refused= in --capabilities' exitcodes line" >&2; exit 1; }

cc_o() { "$CC" $FIXTURE_FLAGS -c -o "$T/$1.o" "$T/$1.c" || exit 1; }
link() { out=$1; shift; "$CC" $FIXTURE_FLAGS -o "$T/$out" "$@" >"$T/link.err" 2>&1; }

# run IN OUT LINE... -- the script on stdin; rc in run_rc, stderr in $T/run.err.
run() {
    run_in=$1 run_out=$2; shift 2
    rm -f "$run_out"
    run_rc=0
    printf '%s\n' "$@" | "$DMR" "$run_in" "$run_out" >"$T/run.out" 2>"$T/run.err" || run_rc=$?
}
said() { grep -qF -- "$1" "$T/run.err"; }
has_sym() { nm -p "$1" | awk -v s="$2" '$NF == s { f = 1 } END { exit !f }'; }

# ---- forwarding: the definition moves aside, a stub takes its name --------
cat >"$T/impl.c" <<'EOF'
int foo(void) { return 42; }
EOF
cat >"$T/stub.c" <<'EOF'
int foo(void) { extern int impl_foo(void); return impl_foo() + 1; }
EOF
cat >"$T/main.c" <<'EOF'
#include <stdio.h>
int foo(void);
int main(void) { printf("%d\n", foo()); return 0; }
EOF
cc_o impl; cc_o stub; cc_o main
before=$(cksum <"$T/impl.o")
run "$T/impl.o" "$T/impl_r.o" 'symbol rename _foo _impl_foo'
[ "$run_rc" -eq 0 ] && ok "forwarding: rename exits 0" || bad "forwarding" "rc $run_rc: $(cat "$T/run.err")"
said "symbol rename _foo -> _impl_foo: 1 entry" \
    && ok "forwarding: the report counts one entry" || bad "forwarding report" "$(cat "$T/run.err")"
said "$T/impl.o: an object is not verified as an image" && ! said "disturbed nothing" \
    && ok "forwarding: the report says an object is not verified, not that nothing was disturbed" \
    || bad "forwarding report" "$(cat "$T/run.err")"
[ "$(cksum <"$T/impl.o")" = "$before" ] && ok "forwarding: the input is untouched" || bad "forwarding" "impl.o changed"
has_sym "$T/impl_r.o" _impl_foo && ! has_sym "$T/impl_r.o" _foo \
    && ok "forwarding: nm shows _impl_foo and no _foo" || bad "forwarding nm" "$(nm -p "$T/impl_r.o")"
if link fwd "$T/main.o" "$T/stub.o" "$T/impl_r.o"; then
    [ "$("$T/fwd")" = 43 ] && ok "forwarding: links and prints 43" || bad "forwarding run" "printed $("$T/fwd")"
else
    bad "forwarding link" "$(cat "$T/link.err")"
fi

# ---- an undefined reference follows the rename ---------------------------
cat >"$T/caller.c" <<'EOF'
#include <stdio.h>
int foo(void);
int main(void) { printf("%d\n", foo()); return 0; }
EOF
cat >"$T/bar.c" <<'EOF'
int bar(void) { return 7; }
EOF
cc_o caller; cc_o bar
run "$T/caller.o" "$T/caller_r.o" 'symbol rename _foo _bar'
[ "$run_rc" -eq 0 ] && ok "undefined: rename exits 0" || bad "undefined" "rc $run_rc: $(cat "$T/run.err")"
if link undef "$T/caller_r.o" "$T/bar.o"; then
    [ "$("$T/undef")" = 7 ] && ok "undefined: the call reaches _bar and prints 7" || bad "undefined run" "printed $("$T/undef")"
else
    bad "undefined link" "$(cat "$T/link.err")"
fi

# ---- a local symbol ------------------------------------------------------
cat >"$T/local.c" <<'EOF'
#include <stdio.h>
static int helper(void) { return 5; }
int main(void) { printf("%d\n", helper()); return 0; }
EOF
cc_o local
nm -p "$T/local.o" | grep -q ' t _helper$' || bad "local" "the fixture has no local _helper: $(nm -p "$T/local.o")"
run "$T/local.o" "$T/local_r.o" 'symbol rename _helper _kept_local'
[ "$run_rc" -eq 0 ] && nm -p "$T/local_r.o" | grep -q ' t _kept_local$' && ! has_sym "$T/local_r.o" _helper \
    && ok "local: nm shows the local symbol under NEW" || bad "local" "rc $run_rc: $(cat "$T/run.err"; nm -p "$T/local_r.o")"
if link local "$T/local_r.o"; then
    [ "$("$T/local")" = 5 ] && ok "local: links and prints 5" || bad "local run" "printed $("$T/local")"
else
    bad "local link" "$(cat "$T/link.err")"
fi

# ---- a 4096-character NEW, defined in one object and referenced in another
LONG=_$(awk 'BEGIN { for (i = 0; i < 4095; i++) printf "x" }')
[ ${#LONG} -eq 4096 ] || { echo "symbol_rename_test: bad name length ${#LONG}" >&2; exit 1; }
cat >"$T/def.c" <<'EOF'
int foo(void) { return 9; }
EOF
cc_o def
run "$T/def.o" "$T/def_r.o" "symbol rename _foo $LONG"
r1=$run_rc
run "$T/caller.o" "$T/caller_long.o" "symbol rename _foo $LONG"
if [ "$r1" -eq 0 ] && [ "$run_rc" -eq 0 ]; then
    ok "long NEW: both renames exit 0"
    if link long "$T/caller_long.o" "$T/def_r.o"; then
        [ "$("$T/long")" = 9 ] && ok "long NEW: links and prints 9" || bad "long NEW run" "printed $("$T/long")"
    else
        bad "long NEW link" "$(cat "$T/link.err")"
    fi
else
    bad "long NEW" "rc $r1/$run_rc: $(cat "$T/run.err")"
fi

# ---- names that move across sort order (does ld64 need them re-sorted?) ---
cat >"$T/sort.c" <<'EOF'
int bb_u(void); int mm_u(void); int zzz(void);
int bb(void) { return 100; }
int mm(void) { return 200; }
int zz(void) { return 3; }
int sum_u(void) { return bb_u() + mm_u() + zzz(); }
EOF
cat >"$T/sortmain.c" <<'EOF'
#include <stdio.h>
int aa(void); int bb(void); int mm(void); int sum_u(void);
int bb_u(void) { return 10; }
int mm_u(void) { return 20; }
int aaa(void) { return 30; }
int main(void) { printf("%d\n", aa() + bb() + mm() + sum_u()); return 0; }
EOF
cc_o sort; cc_o sortmain
run "$T/sort.o" "$T/sort_r.o" 'symbol rename _zz _aa' 'symbol rename _zzz _aaa'
[ "$run_rc" -eq 0 ] && ok "sort order: both renames exit 0" || bad "sort order" "rc $run_rc: $(cat "$T/run.err")"
order=$(nm -p "$T/sort_r.o" | awk '$NF == "_sum_u" || $NF == "_aa" || $NF == "_mm_u" || $NF == "_aaa" { printf "%s ", $NF }')
[ "$order" = "_sum_u _aa _mm_u _aaa " ] \
    && ok "sort order: _aa follows _sum_u and _aaa follows _mm_u in the table" \
    || bad "sort order" "the renamed names are not out of order, so this proves nothing: $order"
if link sorted "$T/sortmain.o" "$T/sort_r.o"; then
    [ "$("$T/sorted")" = 363 ] && ok "sort order: links and prints 363" || bad "sort order run" "printed $("$T/sorted")"
else
    bad "sort order link" "$(cat "$T/link.err")"
fi
if ld -r -arch x86_64 -o "$T/sort_lr.o" "$T/sort_r.o" >"$T/link.err" 2>&1 && link sorted2 "$T/sort_lr.o" "$T/sortmain.o"; then
    [ "$("$T/sorted2")" = 363 ] && ok "sort order: ld -r takes it, and the result links and prints 363" \
        || bad "sort order ld -r run" "printed $("$T/sorted2")"
else
    bad "sort order ld -r" "$(cat "$T/link.err")"
fi

# ---- a fat object: the selected slice renamed, the other byte-identical ---
if "$CC" -arch x86_64h -mmacosx-version-min=10.9 -c -o "$T/impl_h.o" "$T/impl.c" 2>"$T/h.err"; then
    lipo -create -output "$T/fat.o" "$T/impl.o" "$T/impl_h.o" || exit 1
    run "$T/fat.o" "$T/fat_r.o" 'arch x86_64' 'symbol rename _foo _impl_foo'
    [ "$run_rc" -eq 0 ] && ok "fat: rename exits 0" || bad "fat" "rc $run_rc: $(cat "$T/run.err")"
    said "slice x86_64: an object is not verified as an image" && said "$T/fat.o: an object is not verified as an image" \
        && ! grep -q 'verified$' "$T/run.err" && ! said "disturbed nothing" \
        && ok "fat: the report says the object slice and the container are not verified" \
        || bad "fat report" "$(cat "$T/run.err")"
    lipo -thin x86_64 -output "$T/fat_x.o" "$T/fat_r.o" && lipo -thin x86_64h -output "$T/fat_h.o" "$T/fat_r.o" \
        || bad "fat" "lipo cannot split the output"
    has_sym "$T/fat_x.o" _impl_foo && ! has_sym "$T/fat_x.o" _foo \
        && ok "fat: the x86_64 slice is renamed" || bad "fat x86_64" "$(nm -p "$T/fat_x.o")"
    cmp -s "$T/fat_h.o" "$T/impl_h.o" \
        && ok "fat: the x86_64h slice is byte-identical" || bad "fat x86_64h" "the unselected slice changed"
    if link fatfwd "$T/main.o" "$T/stub.o" "$T/fat_x.o"; then
        [ "$("$T/fatfwd")" = 43 ] && ok "fat: the renamed slice links and prints 43" || bad "fat run" "printed $("$T/fatfwd")"
    else
        bad "fat link" "$(cat "$T/link.err")"
    fi
else
    echo "SKIP fat: $CC cannot build an x86_64h object: $(head -1 "$T/h.err")"
fi

# ---- arm64: renamed, linked and run natively --------------------------------
A64="-arch arm64 -mmacosx-version-min=11.0"
if ! arch -arm64 /usr/bin/true >/dev/null 2>&1; then
    echo "SKIP arm64: this host cannot run arm64 (arch -arm64 /usr/bin/true fails)"
elif ! { "$CC" $A64 -c -o "$T/impl64.o" "$T/impl.c" && "$CC" $A64 -c -o "$T/stub64.o" "$T/stub.c" \
         && "$CC" $A64 -c -o "$T/main64.o" "$T/main.c"; } 2>"$T/a64.err"; then
    echo "SKIP arm64: $CC cannot build an arm64 object: $(head -1 "$T/a64.err")"
else
    run "$T/impl64.o" "$T/impl64_r.o" 'symbol rename _foo _impl_foo'
    [ "$run_rc" -eq 0 ] && said "symbol rename _foo -> _impl_foo: 1 entry" \
        && has_sym "$T/impl64_r.o" _impl_foo && ! has_sym "$T/impl64_r.o" _foo \
        && ok "arm64: the object is renamed" || bad "arm64" "rc $run_rc: $(cat "$T/run.err"; nm -p "$T/impl64_r.o")"
    if "$CC" $A64 -o "$T/fwd64" "$T/main64.o" "$T/stub64.o" "$T/impl64_r.o" >"$T/link.err" 2>&1; then
        [ "$("$T/fwd64")" = 43 ] && ok "arm64: links and prints 43" || bad "arm64 run" "printed $("$T/fwd64")"
    else
        bad "arm64 link" "$(cat "$T/link.err")"
    fi
fi

# ---- refusals --------------------------------------------------------------
refused() {   # refused LABEL MESSAGE -- the last run refused, saying MESSAGE, and wrote nothing
    if [ "$run_rc" -eq "$REFUSED" ] && said "$2" && [ ! -e "$run_out" ]; then
        ok "refused: $1"
    else
        bad "refused: $1" "rc $run_rc (want $REFUSED), out $( [ -e "$run_out" ] && echo written || echo absent): $(cat "$T/run.err")"
    fi
}

run "$T/impl.o" "$T/x.o" 'symbol rename _nosuch _other'
refused "OLD absent" "symbol rename _nosuch _other matched nothing (no symbol is named _nosuch)"

run "$T/impl.o" "$T/x.o" 'allow-unmatched' 'symbol rename _nosuch _other'
[ "$run_rc" -eq 0 ] && said "symbol rename _nosuch _other matched nothing" && cmp -s "$T/impl.o" "$T/x.o" \
    && ok "allow-unmatched: reported, exit 0, OUT byte-identical to IN" \
    || bad "allow-unmatched" "rc $run_rc: $(cat "$T/run.err")"

cat >"$T/both.c" <<'EOF'
int foo(void) { return 1; }
int bar(void) { return 2; }
EOF
cc_o both
run "$T/both.o" "$T/x.o" 'symbol rename _foo _bar'
refused "NEW exists" "symbol rename _foo _bar: a symbol is already named _bar"

run "$T/impl.o" "$T/x.o" 'symbol rename _foo _foo'
refused "OLD == NEW" "symbol rename _foo _foo: OLD and NEW are the same name (_foo)"

run "$T/impl.o" "$T/x.o" "symbol rename _foo ''"
[ "$run_rc" -ne 0 ] && said "symbol rename: NEW is empty" && [ ! -e "$T/x.o" ] \
    && ok "refused: an empty NEW" || bad "empty NEW" "rc $run_rc: $(cat "$T/run.err")"

if [ -x "$T/fwd" ]; then
    run "$T/fwd" "$T/x" 'symbol rename _foo _impl_foo'
    refused "on a linked executable" "symbol rename renames symbols in .o and .a files; a linked image is not supported"
else
    bad "refused: on a linked executable" "the forwarding case built no executable"
fi

run "$T/impl.o" "$T/x.o" 'rpath append /x'
refused "rpath append on an object" \
    "\`rpath append\` is for linked images; a relocatable object or archive takes only \`symbol rename\`"

run "$T/impl.o" "$T/x.o" 'symbol rename _foo _impl_foo' 'target 10.9'
refused "target 10.9 after symbol rename on an object" \
    "\`target 10.9\` is for linked images; a relocatable object or archive takes only \`symbol rename\`"

# What `ar -x` leaves of a libtool-built member: its archive padding after the
# string table. Taken as a thin object takes it inside an archive.
cp "$T/impl.o" "$T/padded.o"
printf '\n\n\n\n\n\n\n\n\n\n\n\n' >>"$T/padded.o"
run "$T/padded.o" "$T/padded-out.o" 'symbol rename _foo _impl_foo'
if [ "$run_rc" -eq 0 ] && link padded "$T/main.o" "$T/stub.o" "$T/padded-out.o" && [ "$("$T/padded")" = 43 ]; then
    ok "an object with archive padding after its string table renames, links and runs"
else
    bad "archive padding" "rc $run_rc: $(cat "$T/run.err" "$T/link.err" 2>/dev/null)"
fi

cp "$T/impl.o" "$T/tail.o"
printf 'drydock!' >>"$T/tail.o"
run "$T/tail.o" "$T/x.o" 'symbol rename _foo _impl_foo'
refused "string table not last" "symbol rename _foo _impl_foo: the string table is not the last thing in the file"

[ "$fail" -eq 0 ]
