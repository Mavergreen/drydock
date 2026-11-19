#!/bin/sh
# platform: macOS-only -- symbol_rename_test's x86_64 run rows, forced onto an arm64-only host and into strict mode.
BIN="${1:?usage: exec_gate_rows_test.sh <bindir>}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SUT="$ROOT/tests/symbol_rename_test.sh"
[ "$(uname -s)" = Darwin ] || { echo "SKIP: not macOS"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/tmp}/exec-gate-rows.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi; }

(unset DRYDOCK_REQUIRE_EXEC; DRYDOCK_HOST_ARM64=1 sh "$SUT" "$BIN") >"$T/skip.out" 2>&1
check "forced arm64: symbol_rename_test exits 0" 0 "$?"
sites=$(grep -c 'gate_row x86_64' "$SUT")
grep -q '^SKIP sort order ld -r' "$T/skip.out" && sites=$((sites - 1))
check "forced arm64: one SKIP per x86_64 gate reached" "$sites" "$(grep -c '^SKIP .*: cannot execute x86_64' "$T/skip.out")"
check "forced arm64: no fixture ran, so no row printed what one prints" 0 "$(grep -c -E '^PASS .*(links and prints|prints [0-9]+)' "$T/skip.out")"

env DRYDOCK_HOST_ARM64=1 DRYDOCK_REQUIRE_EXEC=x86_64 sh "$SUT" "$BIN" >"$T/strict.out" 2>&1
check "strict: symbol_rename_test exits 1" 1 "$?"
check "strict: a FAIL line names the row" 1 "$(grep -c '^FAIL forwarding: links and prints 43: cannot execute x86_64' "$T/strict.out")"

[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
