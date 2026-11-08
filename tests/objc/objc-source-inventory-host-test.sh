#!/bin/sh
# platform: host-agnostic -- the source receipt is written on x86_64 Linux (Recaulk's release host) and on a Mac alike
# spec: cli/drydock-objc.c header (receipt) -- drydock-objc receipt loads PREFIX's libclang at run time, takes the
#       single PREFIX/lib/clang/* directory as the resource directory, and the receipt of one prepared source is the
#       same on every host: tests/objc/fixtures/provider-body.receipt, apart from its libclang line (the pinned
#       release's own version string), with a tool line naming tools/objc-source-inventory.c as IMPORTED.sha256 does.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-source-inventory-host-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; [ ! -f "$T/err" ] || tail -15 "$T/err"; fails=$((fails + 1)); }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }

CLANG=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/objc-reference-clang") || { echo 'FAIL: cannot fetch the pinned reference clang'; exit 1; }
# spec: tools/objc-source-inventory.c header -- the profile parses against the floor SDK Recaulk's build uses.
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64) || { echo 'FAIL: cannot fetch the pinned floor SDK'; exit 1; }
# platform: a Mac's libclang is a .dylib, Linux's a .so.
lib=libclang.dylib; [ "$(uname -s)" = Darwin ] || lib=libclang.so

mkdir -p "$T/src"
cp "$FX/provider-body.m" "$FX/provider-register.c" "$T/src/"
printf '%s  provider-body.m\n%s  provider-register.c\n' "$(sha "$T/src/provider-body.m")" "$(sha "$T/src/provider-register.c")" >"$T/inputs"
receipt() { "$DRYDOCK_OBJC" receipt "$@" --inputs "$T/inputs" --root "$T/src" --unit provider-body.m --unit provider-register.c; }

tool=$(awk '$2 == "tools/objc-source-inventory.c" { print $1 }' "$HERE/IMPORTED.sha256")
# spec: tools/objc-source-inventory.c header -- the recorded receipt, with the tool line where the producer writes it (after sdk).
awk -v t="$tool" '{ print } /^sdk\t/ { print "tool\t" t }' "$FX/provider-body.receipt" >"$T/expected"
rc=0; receipt --clang-prefix "$CLANG" --sdk "$SDK" --output "$T/fetched.receipt" 2>"$T/err" || rc=$?
if [ "$rc" = 0 ]; then
  pass 'the receipt is written with the pinned reference clang'
  grep -v '^libclang	' "$T/fetched.receipt" >"$T/fetched.body"
  if cmp -s "$T/fetched.body" "$T/expected"; then pass "the receipt matches the recorded one on $(uname -s) $(uname -m)"
  else fail "the receipt differs from tests/objc/fixtures/provider-body.receipt on $(uname -s) $(uname -m):"; diff "$T/expected" "$T/fetched.body" | head -20; fi
  grep -q '^libclang	clang version 22\.' "$T/fetched.receipt" && pass 'the receipt names clang 22' ||
    fail "the receipt's libclang line: $(grep '^libclang' "$T/fetched.receipt")"
  [ -n "$tool" ] && grep -Fxq "$(printf 'tool\t%s' "$tool")" "$T/fetched.receipt" &&
    pass "the receipt's tool line is IMPORTED.sha256's tools/objc-source-inventory.c" || fail "the receipt's tool line: $(grep '^tool' "$T/fetched.receipt")"
else
  fail "receipt with the fetched clang exits $rc"
fi

# receipt_bad_libclang: a prefix whose libclang is an empty file is a prerequisite failure, and writes nothing.
mkdir -p "$T/bad/lib/clang/22/include"
: >"$T/bad/lib/libclang.dylib"; : >"$T/bad/lib/libclang.so"
rc=0; receipt --clang-prefix "$T/bad" --sdk "$SDK" --output "$T/bad.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && grep -q libclang "$T/err" && [ ! -e "$T/bad.receipt" ] &&
  pass 'receipt_bad_libclang: an empty libclang exits 4, names libclang and writes nothing' || fail "receipt_bad_libclang: exit $rc"

# receipt_needs_prefix, and its twin for the SDK: either one missing is a usage error.
rc=0; receipt --sdk "$SDK" --output "$T/noprefix.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] && [ ! -e "$T/noprefix.receipt" ] && pass 'receipt_needs_prefix: no --clang-prefix exits 2' || fail "receipt_needs_prefix: exit $rc"
rc=0; receipt --clang-prefix "$CLANG" --output "$T/nosdk.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] && [ ! -e "$T/nosdk.receipt" ] && pass 'receipt_needs_sdk: no --sdk exits 2' || fail "receipt_needs_sdk: exit $rc"

# receipt_resource_dir: the resource directory is the one PREFIX/lib/clang/* directory; none, or two, exits 4.
resource=$(ls -d "$CLANG"/lib/clang/* | head -1)
mkdir -p "$T/none/lib/clang"; ln -s "$CLANG/lib/$lib" "$T/none/lib/$lib"
rc=0; receipt --clang-prefix "$T/none" --sdk "$SDK" --output "$T/none.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && [ ! -e "$T/none.receipt" ] && pass 'receipt_resource_dir: no PREFIX/lib/clang/* directory exits 4' || fail "receipt_resource_dir (none): exit $rc"
mkdir -p "$T/two/lib/clang"; ln -s "$CLANG/lib/$lib" "$T/two/lib/$lib"
ln -s "$resource" "$T/two/lib/clang/a"; ln -s "$resource" "$T/two/lib/clang/b"
rc=0; receipt --clang-prefix "$T/two" --sdk "$SDK" --output "$T/two.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && [ ! -e "$T/two.receipt" ] && pass 'receipt_resource_dir: two PREFIX/lib/clang/* directories exit 4' || fail "receipt_resource_dir (two): exit $rc"

# linux_analyze_refused: the Foundation front end is not built for Linux.
if [ "$(uname -s)" = Linux ]; then
  rc=0; "$DRYDOCK_OBJC" analyze --artifact /bin/sh --root / --report "$T/report" 2>"$T/err" || rc=$?
  [ "$rc" = 2 ] && grep -Fxq 'drydock-objc: analyze is not built for Linux yet (the Foundation front end; see README)' "$T/err" &&
    pass 'linux_analyze_refused: analyze exits 2 and says why' || fail "linux_analyze_refused: exit $rc"
fi

[ "$fails" = 0 ] && echo 'objc-source-inventory-host-test: all passed' || { echo "objc-source-inventory-host-test: $fails failed"; exit 1; }
