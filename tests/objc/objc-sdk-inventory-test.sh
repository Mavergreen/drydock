#!/bin/sh
# platform: host-agnostic -- the wrapper checks its arguments before it touches a compiler, so none runs here
# spec: scripts/objc-sdk-inventory.sh usage -- an option without a value, an unknown one, a missing --sdk or --header,
#       and a repeated --clang-prefix or --sdk are usage errors, exit 2, with no output. The facts it extracts from
#       real SDKs are objc-sdk-inventory-macos-test.sh's, which runs the Mach-O libclang reader.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-inventory-args.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }
run() { rc=0; sh "$ROOT/scripts/objc-sdk-inventory.sh" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
usage_error() {
  want=$1; shift; run "$@"
  [ "$rc" = 2 ] && [ ! -s "$T/out" ] || fail "$want: exit $rc, want 2 and no output"
}
usage_error 'an unknown option' --unknown value
usage_error 'a bare unknown option' --unknown
usage_error 'an option with no value' --sdk
usage_error 'no --header' --clang-prefix "$T/none" --sdk "$T/sdk"
usage_error 'no --sdk' --clang-prefix "$T/none" --header "$T/h.h"
usage_error 'no --clang-prefix' --sdk "$T/sdk" --header "$T/h.h"
usage_error 'a repeated --sdk' --clang-prefix "$T/none" --sdk "$T/a" --sdk "$T/b" --header "$T/h.h"
usage_error 'a repeated --clang-prefix' --clang-prefix "$T/a" --clang-prefix "$T/b" --sdk "$T/sdk" --header "$T/h.h"
usage_error 'a value that is an option' --clang-prefix "$T/none" --sdk --header --header "$T/h.h"
run --clang-prefix "$T/none" --sdk "$T/sdk" --header "$T/h.h"
[ "$rc" = 4 ] && [ ! -s "$T/out" ] && grep -F "missing compiler: $T/none/bin/clang" "$T/err" >/dev/null ||
  fail "well-formed arguments are not read as such: exit $rc"
echo 'objc-sdk-inventory: the wrapper'"'"'s argument checks pass'
