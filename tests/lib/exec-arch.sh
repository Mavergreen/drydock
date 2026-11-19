# platform: host-agnostic -- decides from the hardware which architectures this host can execute.
# Sourced for can_exec, gate_row, gate_test, hardware_arch; run as `sh exec-arch.sh --launch ARCH -- COMMAND...` to exec
# COMMAND, or to skip (77) when this host cannot execute ARCH. Never executes a binary to find out.

# hardware_arch: what this hardware executes (arm64, x86_64, or none off Darwin), whatever DRYDOCK_HOST_ARM64 says
hardware_arch() {
  [ "$(uname -s)" = Darwin ] || { echo none; return; }
  if [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ]; then echo arm64; else echo x86_64; fi
}

can_exec() {
  case "${DRYDOCK_HOST_ARM64:-}" in
    1) [ "$1" = arm64 ]; return ;;
    0) [ "$1" = x86_64 ]; return ;;
    none) return 1 ;;
  esac
  [ "$(hardware_arch)" = "$1" ]
}

_exec_arch_why() {
  if [ "$(uname -s)" = Darwin ] && [ "$1" = x86_64 ] && ! can_exec x86_64; then
    echo "cannot execute $1 on this host (Apple Silicon, no Rosetta by policy)"
  else
    echo "cannot execute $1 on this host"
  fi
}

gate_row() {
  can_exec "$1" && return 0
  if [ "${DRYDOCK_REQUIRE_EXEC:-}" = "$1" ]; then
    echo "FAIL $2: $(_exec_arch_why "$1")"
    exit 1
  fi
  echo "SKIP $2: $(_exec_arch_why "$1")"
  return 1
}

gate_test() {
  can_exec "$1" && return 0
  if [ "${DRYDOCK_REQUIRE_EXEC:-}" = "$1" ]; then
    echo "FAIL: $(_exec_arch_why "$1")"
    exit 1
  fi
  echo "SKIP: $(_exec_arch_why "$1")"
  exit 77
}

case "$0" in
  */exec-arch.sh|exec-arch.sh)
    if [ "${1:-}" = --launch ] && [ $# -ge 4 ] && [ "$3" = -- ]; then
      arch=$2
      shift 3
      gate_test "$arch"
      exec "$@"
    fi
    echo "usage: sh exec-arch.sh --launch ARCH -- COMMAND..." >&2
    exit 2
    ;;
esac
