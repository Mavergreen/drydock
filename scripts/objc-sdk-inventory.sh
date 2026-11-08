#!/bin/sh
# platform: macOS-only -- native Apple compiler and libclang host library
set -eu
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH SDKROOT CCC_OVERRIDE_OPTIONS
fail() { echo "objc-sdk-inventory: $*" >&2; exit 4; }
usage() { echo 'usage: objc-sdk-inventory.sh --clang-prefix PREFIX --sdk SDKROOT --header HEADER [--header HEADER ...] [--signature-output FILE]' >&2; exit 2; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix= sdk= headers=0 signatures=
parse() {
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$2" in -*) usage ;; esac
  case "$1" in
    --clang-prefix) [ -z "$prefix" ] || usage; prefix=$2 ;;
    --sdk) [ -z "$sdk" ] || usage; sdk=$2 ;;
    --signature-output) [ -z "$signatures" ] || usage; signatures=$2 ;;
    --header) headers=$((headers + 1)) ;;
    *) usage ;;
  esac
  shift 2
done
}
parse "$@"
[ -n "$prefix" ] && [ -n "$sdk" ] && [ "$headers" -gt 0 ] || usage
[ -x "$prefix/bin/clang" ] || fail "missing compiler: $prefix/bin/clang"
[ -r "$prefix/include/clang-c/Index.h" ] && [ -r "$prefix/lib/libclang.dylib" ] || fail 'missing libclang headers/library'
resource=$("$prefix/bin/clang" -print-resource-dir) || fail 'cannot query compiler resource directory'
[ -d "$resource/include" ] || fail "missing compiler resource directory: $resource"
case "$(uname -m)" in
  x86_64) arch=x86_64; floor=10.9 ;;
  arm64) arch=arm64; floor=11.0 ;;
  *) fail 'unsupported host architecture' ;;
esac
host_sdk=$(sh "$HERE/fetch_sdk.sh" --arch "$arch") || fail 'cannot fetch pinned host SDK'
root=${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}
mkdir -p "$root" || fail 'cannot create build root'
build=$(mktemp -d "$root/objc-sdk-inventory.XXXXXX") || fail 'cannot create build directory'
trap 'rm -rf "$build"' EXIT
/usr/bin/clang -std=c99 -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min="$floor" \
  -isysroot "$host_sdk" -I"$prefix/include" "$HERE/../tools/objc-sdk-inventory.c" \
  -L"$prefix/lib" -Xlinker -rpath -Xlinker "$prefix/lib" -lclang -o "$build/objc-sdk-inventory" || fail 'host producer build failed'
"$prefix/bin/clang" --version >&2 || fail 'cannot identify compiler'
remaining=$#
while [ "$remaining" -gt 0 ]; do
  case "$1" in
    --clang-prefix) shift 2 ;;
    *) option=$1; value=$2; shift 2; set -- "$@" "$option" "$value" ;;
  esac
  remaining=$((remaining - 2))
done
rc=0
"$build/objc-sdk-inventory" --resource-dir "$resource" "$@" || rc=$?
case "$rc" in 0|2|4) exit "$rc" ;; *) fail "producer failed (exit $rc)" ;; esac
