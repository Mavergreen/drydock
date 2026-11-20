#!/bin/sh
# platform: host-agnostic -- kexts from tests/mkkext.c, a CMake-built host helper
# tests/vnodeop_replace_test.sh -- `vnodeop replace OLD NEW` through the CLI,
# and the gate that keeps it to x86_64 kexts and to scripts of its own.
#
#   sh tests/vnodeop_replace_test.sh <bindir>
set -u

BIN="${1:?usage: vnodeop_replace_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
for t in "$DMR" "$BIN/mkkext" "$BIN/fatcheck"; do
    [ -x "$t" ] || { echo "vnodeop_replace_test: $t not found or not executable" >&2; exit 1; }
done
ROOT=$(cd "$(dirname "$0")/.." && pwd)

T=$(mktemp -d "${TMPDIR:-/tmp}/vnodeop_replace_test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

# run IN OUT LINE... -- the script on stdin; rc in run_rc, stderr in $T/run.err.
run() {
    run_in=$1 run_out=$2; shift 2
    rm -f "$run_out"
    run_rc=0
    printf '%s\n' "$@" | "$DMR" "$run_in" "$run_out" >"$T/run.out" 2>"$T/run.err" || run_rc=$?
}
said() { grep -qF -- "$1" "$T/run.err"; }
# refused [RC]: exit RC (1, refused, by default) with nothing written.
# gate WORDS: the gate's refusal of the run's input, before any statement ran.
gate() { said "drydock-macho-rewrite edit: $run_in: vnodeop replace $1"; }
refused() { [ "$run_rc" -eq "${1:-1}" ] && [ ! -e "$run_out" ]; }
why() { echo "rc $run_rc, output $( [ -e "$run_out" ] && echo written || echo absent): $(cat "$T/run.err")"; }

for c in ok ok-fat bundle bundle-fat; do
    "$BIN/mkkext" "$c" "$T/$c" || { echo "vnodeop_replace_test: mkkext $c failed" >&2; exit 1; }
done
OLD=_vnop_renamex_desc NEW=_vnop_rename_desc
STMT="vnodeop replace $OLD $NEW"
REPORT="      vnodeop replace $OLD -> $NEW: 2 entries; removed undefined symbol #5; 2 external relocations renumbered"
STMT_LOG="  load-command delete uuid"

# ---- the gate's positive control: a kext still takes other statements ------
run "$T/ok" "$T/ctl" allow-unmatched 'load-command delete uuid'
[ "$run_rc" -eq 0 ] && [ -f "$T/ctl" ] && said "$STMT_LOG" && ! said "vnodeop replace" \
    && ok "control: a kext with only load-command delete uuid still runs it" || bad "control" "$(why)"

# ---- ok ---------------------------------------------------------------------
before=$(cksum <"$T/ok")
run "$T/ok" "$T/ok.out" "$STMT"
[ "$run_rc" -eq 0 ] && [ -f "$T/ok.out" ] && ok "ok: exits 0 and writes OUT" || bad "ok" "$(why)"
said "$REPORT" && ok "ok: the report line" || bad "ok report" "$(why)"
[ "$(cksum <"$T/ok")" = "$before" ] && ok "ok: the input is untouched" || bad "ok" "the input changed"
[ -f "$T/ok.out" ] && [ "$(wc -c <"$T/ok")" -eq "$(wc -c <"$T/ok.out")" ] && ! cmp -s "$T/ok" "$T/ok.out" \
    && ok "ok: OUT differs from FILE at the same size" || bad "ok" "OUT is the same bytes, or another size"

# ---- second_run: OLD is gone ---------------------------------------------------
run "$T/ok.out" "$T/again" "$STMT"
refused && said "$STMT matched nothing (no symbol is named $OLD)" \
    && ok "second_run: refused, matched nothing" || bad "second_run" "$(why)"
run "$T/ok.out" "$T/again" allow-unmatched "$STMT"
[ "$run_rc" -eq 0 ] && said "$STMT matched nothing" && cmp -s "$T/ok.out" "$T/again" \
    && ok "second_run: allow-unmatched writes its input's bytes" || bad "second_run allow-unmatched" "$(why)"

# ---- fat: every selected slice must be an x86_64 kext ------------------------
run "$T/ok-fat" "$T/fat.out" "$STMT"
refused && gate "takes only x86_64 kexts" && said "the arm64e slice is not one" && said "arch x86_64" \
    && ok "fat_without_arch: refused, suggesting arch x86_64" || bad "fat_without_arch" "$(why)"

# The advice is only for a script with no arch directive, on a file whose
# x86_64 slice is a kext.
run "$T/ok-fat" "$T/fat.out" 'arch x86_64' 'arch arm64e' "$STMT"
refused && gate "takes only x86_64 kexts" && said "the selected arm64e slice is not one" && ! said "arch x86_64" \
    && ok "fat_arch_given: refused, naming the arm64e slice, with no arch advice" || bad "fat_arch_given" "$(why)"
run "$T/bundle-fat" "$T/fat.out" "$STMT"
refused && gate "takes only x86_64 kexts" && said "the selected x86_64 slice is not one" && ! said "arch x86_64" \
    && ok "fat_no_kext_slice: refused, naming the x86_64 slice, with no arch advice" || bad "fat_no_kext_slice" "$(why)"

run "$T/ok-fat" "$T/fat.out" 'arch x86_64' "$STMT"
if [ "$run_rc" -eq 0 ] && [ -f "$T/fat.out" ]; then
    ok "fat_with_arch: exits 0"
    for f in ok-fat fat.out; do
        "$BIN/fatcheck" dump "$T/$f" 0 "$T/$f.0" && "$BIN/fatcheck" dump "$T/$f" 1 "$T/$f.1" || bad "fatcheck" "$f"
    done
    cmp -s "$T/ok.out" "$T/fat.out.0" && ! cmp -s "$T/ok-fat.0" "$T/fat.out.0" \
        && ok "fat_with_arch: the x86_64 slice is the thin run's output" || bad "fat_with_arch" "x86_64 slice"
    cmp -s "$T/ok-fat.1" "$T/fat.out.1" \
        && ok "fat_with_arch: the arm64e slice is unchanged" || bad "fat_with_arch" "the arm64e slice changed"
    LIPO=$( (. "$ROOT/tests/lib/toolchain.sh" >/dev/null 2>&1 && [ -x "$LIPO" ] && printf '%s' "$LIPO") ) || LIPO=
    if [ -n "$LIPO" ]; then
        archs=$(echo $("$LIPO" -info "$T/fat.out" | sed -n 's/.*: //p'))
        [ "$archs" = "x86_64 arm64e" ] && ok "fat_with_arch: llvm-lipo -info lists both" \
            || bad "fat_with_arch lipo" "got '$archs'"
    else
        "$DMR" info "$T/fat.out" >"$T/info" 2>&1
        grep -q x86_64 "$T/info" && grep -q arm64e "$T/info" \
            && ok "fat_with_arch: info lists both slices (no llvm-lipo here)" || bad "fat_with_arch info" "$(cat "$T/info")"
    fi
else
    bad "fat_with_arch" "$(why)"
fi

# ---- not an x86_64 kext --------------------------------------------------------
run "$T/bundle" "$T/x" "$STMT"
refused && gate "takes only x86_64 kexts" && ok "bundle: refused, naming vnodeop replace" || bad "bundle" "$(why)"
run "$T/ok-fat.1" "$T/x" "$STMT"
refused && gate "takes only x86_64 kexts" && ! said "arch x86_64" \
    && ok "thin arm64e kext: refused, with no arch advice" || bad "thin arm64e" "$(why)"

# ---- mixed_script: refused before any statement runs ---------------------------
run "$T/ok" "$T/x" allow-unmatched 'load-command delete uuid' "$STMT"
refused && gate "takes a script of its own" && said "line 2 is \`load-command delete\`" && ! said "$STMT_LOG" \
    && ok "mixed_script: refused before load-command delete ran" || bad "mixed_script" "$(why)"

# ---- empty_name ------------------------------------------------------------------
run "$T/ok" "$T/x" "vnodeop replace $OLD ''"
refused 2 && said "line 1" && said "vnodeop replace: NEW is empty" \
    && ok "empty_name: a parse error" || bad "empty_name" "$(why)"

[ "$fail" -eq 0 ] || { echo "vnodeop_replace_test: $fail failure(s)"; exit 1; }
echo "vnodeop_replace_test: all passed"
