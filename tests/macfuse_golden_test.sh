#!/bin/sh
# platform: host-agnostic -- reads a pinned upstream tarball with clang22's LLVM tools; executes nothing from it
# tests/macfuse_golden_test.sh -- `vnodeop replace` on real upstream bytes:
# macFUSE 5.5.0's debug kext, thinned to x86_64, comes out byte-identical to
# what mavergreen-fuse's spike made and loaded on 10.9.
#
#   sh tests/macfuse_golden_test.sh <bindir>
#
# Takes the tarball from $MACFUSE_DEBUG_TBZ, else
# ~/Library/Caches/mavergreen-drydock/macfuse-<version>-debug.tbz. Exits 77
# when the variable is unset and that file is absent; fails when the variable
# names a missing file.
set -u

BIN="${1:?usage: macfuse_golden_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "macfuse_golden_test: $DMR not found or not executable" >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
V=$(tr -d '[:space:]' < "$ROOT/components/macfuse-debug/version")
PIN=$(tr -d '[:space:]' < "$ROOT/components/macfuse-debug/sha256")
GOLDEN=73300026cc73eeef324774c9dd2e44dee4b4799566e7b1f61d38016d6f94e836
MEMBER=macfuse-$V-debug/KernelExtension-12/macfuse.kext/Contents/MacOS/macfuse

if [ -n "${MACFUSE_DEBUG_TBZ:-}" ]; then
    TBZ=$MACFUSE_DEBUG_TBZ
    [ -f "$TBZ" ] || { echo "FAIL: macfuse_golden_test: MACFUSE_DEBUG_TBZ names $TBZ, which is not a file"; exit 1; }
else
    TBZ=$HOME/Library/Caches/mavergreen-drydock/macfuse-$V-debug.tbz
    [ -f "$TBZ" ] || { echo "SKIP: macfuse_golden_test: no MACFUSE_DEBUG_TBZ, and no $TBZ"; exit 77; }
fi
echo "INFO: macfuse_golden_test: using $TBZ"

. "$ROOT/tests/lib/toolchain.sh"
OBJDUMP=$(dirname "$NM")/llvm-objdump
[ -x "$OBJDUMP" ] || { echo "macfuse_golden_test: no $OBJDUMP beside $NM" >&2; exit 1; }

sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | awk '{ print $1 }'
}

T=$(mktemp -d "${TMPDIR:-/tmp}/macfuse_golden_test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

got=$(sha256 "$TBZ")
[ "$got" = "$PIN" ] || { echo "FAIL tarball: $TBZ has sha256 $got, not the pinned $PIN"; exit 1; }
ok "the tarball is the pinned $V"

tar -xjf "$TBZ" -C "$T" "$MEMBER" || { echo "FAIL extract: $TBZ holds no $MEMBER"; exit 1; }
"$LIPO" -thin x86_64 -output "$T/in" "$T/$MEMBER" || { echo "FAIL thin: no x86_64 slice in $MEMBER"; exit 1; }
size=$(wc -c < "$T/in" | tr -d ' ')
[ "$size" = 182592 ] && ok "the x86_64 slice is 182592 bytes" || bad "slice size" "$size bytes"

printf 'arch x86_64\nvnodeop replace _vnop_renamex_desc _vnop_rename_desc\n' \
    | "$DMR" "$T/in" "$T/out" >"$T/run.out" 2>"$T/run.err" \
    && ok "vnodeop replace exits 0" || bad "vnodeop replace" "$(cat "$T/run.err")"
grep -qx '      vnodeop replace _vnop_renamex_desc -> _vnop_rename_desc: 2 entries; removed undefined symbol #2347; 42 external relocations renumbered' "$T/run.err" \
    && ok "it reports 2 entries, symbol #2347 removed, 42 relocations renumbered" || bad "report" "$(cat "$T/run.err")"

got=$(sha256 "$T/out")
[ "$got" = "$GOLDEN" ] && ok "the output is the golden kext" || bad "golden" "sha256 $got, not $GOLDEN"

"$NM" -u "$T/in" >"$T/nm.in" && "$NM" -u "$T/out" >"$T/nm.out" || bad "nm" "llvm-nm -u failed"
n_in=$(wc -l < "$T/nm.in" | tr -d ' ') n_out=$(wc -l < "$T/nm.out" | tr -d ' ')
[ "$n_in" = 272 ] && [ "$n_out" = 271 ] && ok "undefined symbols: 272 -> 271" || bad "nm -u counts" "$n_in -> $n_out"
gone=$(diff "$T/nm.in" "$T/nm.out" | grep -v '^[0-9]')
[ "$gone" = "< _vnop_renamex_desc" ] && ok "only _vnop_renamex_desc is gone" || bad "nm -u diff" "$gone"

relocs() { "$OBJDUMP" --macho -r "$1" | tail -n +2; }  # past the line naming the file
relocs "$T/in" >"$T/r.in" && relocs "$T/out" >"$T/r.out" || bad "objdump" "llvm-objdump --macho -r failed"
n=$(grep -c '_vnop_rename_desc$' "$T/r.in")
[ "$n" = 2 ] && ok "before: 2 relocations name _vnop_rename_desc" || bad "before" "$n relocations name _vnop_rename_desc"
n=$(grep -c '_vnop_rename_desc$' "$T/r.out")
[ "$n" = 4 ] && ok "after: 4 relocations name _vnop_rename_desc" || bad "after" "$n relocations name _vnop_rename_desc"
n=$(grep -c '_vnop_renamex_desc' "$T/r.in")
[ "$n" = 2 ] && ok "before: 2 relocations name _vnop_renamex_desc" || bad "before" "$n relocations name _vnop_renamex_desc"
n=$(grep -c '_vnop_renamex_desc' "$T/r.out")
[ "$n" = 0 ] && ok "after: none names _vnop_renamex_desc" || bad "after" "$n relocations name _vnop_renamex_desc"
n=$(diff "$T/r.in" "$T/r.out" | grep -c '^>')
m=$(diff "$T/r.in" "$T/r.out" | grep -c '^<')
[ "$n" = 2 ] && [ "$m" = 2 ] && ok "the relocation listings differ in exactly 2 lines" || bad "-r diff" "$m lines out, $n in"

[ "$fail" -eq 0 ]
