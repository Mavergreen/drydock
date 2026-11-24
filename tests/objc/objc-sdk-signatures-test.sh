#!/bin/sh
# platform: host-agnostic -- the wrapper checks its arguments before it touches a compiler, so none runs here
# spec: tools/objc-sdk-inventory.c header -- the --signature-output and --function-output companions are
#       exclusive: one without a destination, or given twice, is a usage error, exit 2, with no output. What they
#       write is objc-sdk-signatures-macos-test.sh's, which runs the Mach-O libclang reader.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-signatures-args.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }
run() { rc=0; sh "$ROOT/scripts/objc-sdk-inventory.sh" --clang-prefix "$T/none" --sdk "$T/sdk" --header "$T/h.h" "$@" >"$T/out" 2>"$T/err" || rc=$?; }
usage_error() {
  want=$1; shift; run "$@"
  [ "$rc" = 2 ] && [ ! -s "$T/out" ] && [ ! -e "$T/a" ] && [ ! -e "$T/b" ] || fail "$want: exit $rc, want 2, no output and no file"
}
usage_error 'a signature destination missing' --signature-output
usage_error 'a signature destination twice' --signature-output "$T/a" --signature-output "$T/b"
usage_error 'a function destination missing' --function-output
usage_error 'a function destination twice' --function-output "$T/a" --function-output "$T/b"
run --signature-output "$T/a" --function-output "$T/b"
[ "$rc" = 4 ] && grep -F "missing compiler: $T/none/bin/clang" "$T/err" >/dev/null ||
  fail "well-formed companion arguments are not read as such: exit $rc"
echo 'objc-sdk-signatures: the wrapper'"'"'s output-option argument checks pass'
