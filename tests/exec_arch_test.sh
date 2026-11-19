#!/bin/sh
# platform: host-agnostic -- the hardware gate, forced through DRYDOCK_HOST_ARM64; one row reads this host's own answer.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
unset DRYDOCK_REQUIRE_EXEC DRYDOCK_HOST_ARM64
HELPER="$ROOT/tests/lib/exec-arch.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/exec-arch.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
fails=0

check() { # NAME EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi
}
contains() { # NAME NEEDLE HAYSTACK
  case "$3" in *"$2"*) echo "ok $1" ;; *) echo "FAIL $1: '$2' not in '$3'"; fails=$((fails + 1)) ;; esac
}
rc_of() { ( . "$HELPER"; "$@" ) >/dev/null 2>&1; echo $?; }

for spec in "1 arm64 0" "1 x86_64 1" "0 x86_64 0" "0 arm64 1" "none x86_64 1" "none arm64 1"; do
  set -- $spec
  check "can_exec $2 with DRYDOCK_HOST_ARM64=$1" "$3" "$(DRYDOCK_HOST_ARM64=$1 rc_of can_exec "$2")"
done

check "gate_test x86_64 on Apple Silicon exits 77" 77 "$(DRYDOCK_HOST_ARM64=1 rc_of gate_test x86_64)"
check "gate_test x86_64 on Intel returns" 0 "$(DRYDOCK_HOST_ARM64=0 rc_of gate_test x86_64)"
out=$(DRYDOCK_HOST_ARM64=1 DRYDOCK_REQUIRE_EXEC=x86_64 sh -c ". '$HELPER'; gate_test x86_64" 2>&1)
check "strict gate_test exits 1" 1 "$(DRYDOCK_HOST_ARM64=1 DRYDOCK_REQUIRE_EXEC=x86_64 rc_of gate_test x86_64)"
contains "strict gate_test prints FAIL" FAIL "$out"
check "strict mode for another arch still skips" 77 "$(DRYDOCK_HOST_ARM64=1 DRYDOCK_REQUIRE_EXEC=arm64 rc_of gate_test x86_64)"

out=$(DRYDOCK_HOST_ARM64=1 sh -c ". '$HELPER'; gate_row x86_64 demo" 2>&1)
check "gate_row skips with 1" 1 "$(DRYDOCK_HOST_ARM64=1 rc_of gate_row x86_64 demo)"
contains "gate_row says why" "SKIP demo: cannot execute x86_64" "$out"
check "gate_row runs with 0" 0 "$(DRYDOCK_HOST_ARM64=0 rc_of gate_row x86_64 demo)"
check "strict gate_row exits 1" 1 "$(DRYDOCK_HOST_ARM64=1 DRYDOCK_REQUIRE_EXEC=x86_64 rc_of gate_row x86_64 demo)"
out=$(DRYDOCK_HOST_ARM64=1 DRYDOCK_REQUIRE_EXEC=x86_64 sh -c ". '$HELPER'; gate_row x86_64 demo" 2>&1)
contains "strict gate_row prints FAIL" "FAIL demo: cannot execute x86_64" "$out"

DRYDOCK_HOST_ARM64=1 sh "$HELPER" --launch x86_64 -- sh -c "touch '$TMP/marker'; exit 0" >/dev/null 2>&1
check "launch on Apple Silicon exits 77" 77 "$?"
[ ! -e "$TMP/marker" ]; check "launch on Apple Silicon does not run the command" 0 "$?"
DRYDOCK_HOST_ARM64=0 sh "$HELPER" --launch x86_64 -- sh -c "touch '$TMP/marker'; exit 3" >/dev/null 2>&1
check "launch on Intel passes the exit status through" 3 "$?"
[ -e "$TMP/marker" ]; check "launch on Intel runs the command" 0 "$?"
DRYDOCK_HOST_ARM64=1 DRYDOCK_REQUIRE_EXEC=x86_64 sh "$HELPER" --launch x86_64 -- true >/dev/null 2>&1
check "strict launch exits 1" 1 "$?"

EXECUTORS="apple_silicon_signing_test archive_rename_test bake_mavericks_shim_test change_dylib_test cli_test
grown_binary_runs_test import_redirect_test legacysupport_rename_test raise_rich_test symbol_rename_test"
NEVER_EXEC="chained-fixups codesign_order_test equivalence fixture_toolchain_test insert_dylib_test leaf-tool-crashes
standalone_archive_test uuid_stamp_test wrapper_test"
TEN_NINE_ONLY="raise_runs_test"

for t in $EXECUTORS; do
  grep -q 'tests/lib/exec-arch.sh' "$ROOT/tests/$t.sh"; check "$t.sh sources the hardware gate" 0 "$?"
done

unlisted=
for f in "$ROOT"/tests/*.sh; do
  n=$(basename "$f" .sh)
  grep -q -E '"\$(CC|CXX)"' "$f" || continue
  case " $(echo $EXECUTORS $NEVER_EXEC $TEN_NINE_ONLY exec_arch_test) " in *" $n "*) ;; *) unlisted="$unlisted $n" ;; esac
done
check "every test that builds with CC or CXX is classed as running its fixtures or not" "" "$unlisted"
printf '"$CC" -o a a.c\n' >"$TMP/control.sh"
grep -q -E '"\$(CC|CXX)"' "$TMP/control.sh"; check "the CC/CXX sweep sees a test that builds a fixture" 0 "$?"

if [ "$(uname -s)" = Darwin ] && [ "$(uname -r | cut -d. -f1)" = 13 ]; then
  check "this host (10.9) can exec x86_64" 0 "$(sh -c ". '$HELPER'; can_exec x86_64; echo \$?")"
  check "hardware_arch says x86_64 here, though DRYDOCK_HOST_ARM64 says arm64" x86_64 \
    "$(DRYDOCK_HOST_ARM64=1 sh -c ". '$HELPER'; hardware_arch")"
else
  echo "SKIP this-host: not 10.9"
fi

[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
