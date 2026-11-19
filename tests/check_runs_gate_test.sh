#!/bin/sh
# platform: macOS-only -- drydock_check_runs runs its program only where exec-arch.sh's can_exec allows; forced through
#   DRYDOCK_HOST_ARM64 the other way, it runs nothing. Launched for ARCH, so the row that runs runs natively.
#   usage: check_runs_gate_test.sh CMAKE C_COMPILER SYSROOT ARCH
CMAKE=${1:?usage: check_runs_gate_test.sh CMAKE C_COMPILER SYSROOT ARCH}
CCOMP=${2:?}
SYSROOT=${3-}
ARCH=${4:?}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo "SKIP: not macOS"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/tmp}/check-runs-gate.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok $1"; else echo "FAIL $1: expected '$2', got '$3'"; fails=$((fails + 1)); fi; }

mkdir "$T/src"
cat >"$T/src/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(check_runs_gate C)
include("${DRYDOCK_ROOT}/build/drydock-check-runs.cmake")
drydock_check_runs("#include <stdio.h>\nint main(void) { return fopen(\"${MARK}\", \"w\") == 0; }" GATE_RAN)
file(WRITE "${CMAKE_BINARY_DIR}/result" "${GATE_RAN}")
EOF

# configure NAME: configures the probe project into $T/NAME; leaves its log there
configure() {
  "$CMAKE" -S "$T/src" -B "$T/$1" -DDRYDOCK_ROOT="$ROOT" -DMARK="$T/$1.ran" -DDRYDOCK_TEST_ARCH="$ARCH" \
    -DCMAKE_C_COMPILER="$CCOMP" -DCMAKE_OSX_ARCHITECTURES="$ARCH" ${SYSROOT:+-DCMAKE_OSX_SYSROOT="$SYSROOT"} \
    >"$T/$1.log" 2>&1 || { echo "FAIL $1: configure exited nonzero:"; tail -20 "$T/$1.log"; fails=$((fails + 1)); }
}

case $ARCH in arm64) other=0 ;; *) other=1 ;; esac
(DRYDOCK_HOST_ARM64=$other; export DRYDOCK_HOST_ARM64; configure denied)
check "denied: nothing ran" no "$([ -e "$T/denied.ran" ] && echo yes || echo no)"
check "denied: the result is false" FALSE "$(cat "$T/denied/result" 2>/dev/null)"
check "denied: configure says why" 1 "$(grep -c "GATE_RAN - not run: this host cannot execute $ARCH" "$T/denied.log")"

(unset DRYDOCK_HOST_ARM64; configure allowed)
check "allowed: the program ran" yes "$([ -e "$T/allowed.ran" ] && echo yes || echo no)"
check "allowed: the result is true" 1 "$(cat "$T/allowed/result" 2>/dev/null)"

[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
