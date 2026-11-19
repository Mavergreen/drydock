# platform: host-agnostic -- every fixture a test builds comes from clang22 and its LLVM tools, never the host's.
# Sourced; needs ROOT. CLANG22 (a prefix; ctest passes it) or, unset, shipyard's fetch_clang22.sh over the pin.
# Exports CC CXX AR RANLIB LIBTOOL NM OTOOL LIPO STRINGS STRIP, each only if not already set. Where clang does not link
# with ld64.lld unasked, CC and CXX are one-line wrappers adding -fuse-ld=lld. CC and CXX build x86_64 fixtures under
# clang22's own cfg (x86_64, 10.9), whose SDK has no arm64. CC_ARM64 builds arm64 fixtures, and HOST_CC the helpers a
# test runs on this host, for the hardware's arch (exec-arch.sh's hardware_arch, never DRYDOCK_HOST_ARM64): both are clang22
# without its cfg, against shipyard's pinned SDK for their arch (fetch_sdk.sh), arm64 at 11.0 and x86_64 at 10.9.

_tc_scripts=${SHIPYARD_SCRIPTS:-/usr/local/mavergreen/shipyard/share/cmake/MavericksShipyard/scripts}
_toolchain_prefix() {
  [ -n "${CLANG22:-}" ] && { printf '%s\n' "$CLANG22"; return; }
  _tc_out=$(sh "$_tc_scripts/fetch_clang22.sh" "$ROOT/components/objc-receipt-clang" 2>&1) && {
    printf '%s\n' "$_tc_out"; return; }
  echo "toolchain: no clang22 (fetch_clang22.sh: $_tc_out)" >&2
  return 1
}

_toolchain_prefix_dir=$(_toolchain_prefix) || exit 1
if [ ! -x "$_toolchain_prefix_dir/bin/clang" ]; then
  echo "toolchain: no clang22 ($_toolchain_prefix_dir/bin/clang is not executable)" >&2
  exit 1
fi
_tc_bin=$_toolchain_prefix_dir/bin

_tc_cc=$_tc_bin/clang
_tc_cxx=$_tc_bin/clang++
_tc_w=${TMPDIR:-/tmp}/drydock-toolchain-$(id -u)
mkdir -p "$_tc_w" || exit 1

_tc_ld=
"$_tc_cc" --no-default-config -### -x c /dev/null -o /dev/null 2>&1 | grep ld64.lld >/dev/null || _tc_ld=' -fuse-ld=lld'
# _tc_bare NAME ARCH MIN: a wrapper running clang22 with no cfg, for ARCH against its pinned SDK, also under env -i
_tc_bare() {
  { printf '#!/bin/sh\n: "${HOME:=%s}"; export HOME\n' "${HOME:-}"
    [ -z "${MAVERICKS_SDK_CACHE:-}" ] ||
      printf ': "${MAVERICKS_SDK_CACHE:=%s}"; export MAVERICKS_SDK_CACHE\n' "$MAVERICKS_SDK_CACHE"
    printf 'sdk=$(sh "%s/fetch_sdk.sh" --arch %s) || { echo "%s: no pinned %s SDK from %s/fetch_sdk.sh" >&2; exit 1; }\n' \
      "$_tc_scripts" "$2" "$1" "$2" "$_tc_scripts"
    printf 'exec "%s" --no-default-config%s -arch %s -mmacosx-version-min=%s -isysroot "$sdk" "$@"\n' \
      "$_tc_cc" "$_tc_ld" "$2" "$3"
  } >"$_tc_w/$1.$$" && chmod +x "$_tc_w/$1.$$" && mv "$_tc_w/$1.$$" "$_tc_w/$1"
}
_tc_bare cc-arm64 arm64 11.0 || exit 1
. "$ROOT/tests/lib/exec-arch.sh"
case $(hardware_arch) in
  arm64) _tc_bare host-cc arm64 11.0 || exit 1 ;;
  x86_64) _tc_bare host-cc x86_64 10.9 || exit 1 ;;
  *) printf '#!/bin/sh\necho "host-cc: the helpers a test runs are Mach-O, and this host is %s" >&2\nexit 1\n' "$(uname -s)" \
       >"$_tc_w/host-cc.$$" && chmod +x "$_tc_w/host-cc.$$" && mv "$_tc_w/host-cc.$$" "$_tc_w/host-cc" || exit 1 ;;
esac

if ! "$_tc_cc" -### -x c /dev/null -o /dev/null 2>&1 | grep ld64.lld >/dev/null; then
  for _tc_n in cc cxx; do
    case $_tc_n in cc) _tc_c=$_tc_cc ;; cxx) _tc_c=$_tc_cxx ;; esac
    printf '#!/bin/sh\nexec "%s" -fuse-ld=lld "$@"\n' "$_tc_c" >"$_tc_w/$_tc_n.$$" && chmod +x "$_tc_w/$_tc_n.$$" &&
      mv "$_tc_w/$_tc_n.$$" "$_tc_w/$_tc_n" || exit 1
  done
  _tc_cc=$_tc_w/cc
  _tc_cxx=$_tc_w/cxx
fi

: "${CC:=$_tc_cc}"
: "${CC_ARM64:=$_tc_w/cc-arm64}"
: "${HOST_CC:=$_tc_w/host-cc}"
: "${CXX:=$_tc_cxx}"
: "${AR:=$_tc_bin/llvm-ar}"
: "${RANLIB:=$_tc_bin/llvm-ranlib}"
: "${LIBTOOL:=$_tc_bin/llvm-libtool-darwin}"
: "${NM:=$_tc_bin/llvm-nm}"
: "${OTOOL:=$_tc_bin/llvm-otool}"
: "${LIPO:=$_tc_bin/llvm-lipo}"
: "${STRINGS:=$_tc_bin/llvm-strings}"
: "${STRIP:=$_tc_bin/llvm-strip}"
export CC CC_ARM64 HOST_CC CXX AR RANLIB LIBTOOL NM OTOOL LIPO STRINGS STRIP
unset _tc_cc _tc_cxx _tc_bin _tc_scripts _tc_out _tc_ld _tc_w _tc_n _tc_c _toolchain_prefix_dir
unset -f _tc_bare
