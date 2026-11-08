#!/bin/sh
# platform: host-agnostic -- the source receipt is written on x86_64 Linux (Recaulk's release host) and on a Mac alike
# spec: scripts/objc-source-inventory.sh header -- with no --clang-prefix the pinned reference clang is fetched, and the
#       receipt of one prepared source is the same on every host: tests/fixtures/objc-api/provider-body.receipt, apart
#       from its libclang line (the pinned release's own version string) and its tool line (this checkout's tool digest).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
FX="$HERE/fixtures/objc-api"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-source-inventory-host-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
MAVERICKS_BUILD_ROOT="$T/build"; export MAVERICKS_BUILD_ROOT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; [ ! -f "$T/err" ] || tail -15 "$T/err"; fails=$((fails + 1)); }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }

mkdir -p "$T/src"
cp "$FX/provider-body.m" "$FX/provider-register.c" "$T/src/"
printf '%s  provider-body.m\n%s  provider-register.c\n' "$(sha "$T/src/provider-body.m")" "$(sha "$T/src/provider-register.c")" >"$T/inputs"
inventory() { sh "$ROOT/scripts/objc-source-inventory.sh" "$@" --inputs "$T/inputs" --root "$T/src" \
  --unit provider-body.m --unit provider-register.c; }

rc=0; inventory --output "$T/fetched.receipt" 2>"$T/err" || rc=$?
if [ "$rc" = 0 ]; then
  pass 'with no --clang-prefix, the pinned reference clang is fetched and the receipt written'
  grep -v -e '^libclang	' -e '^tool	' "$T/fetched.receipt" >"$T/fetched.body"
  if cmp -s "$T/fetched.body" "$FX/provider-body.receipt"; then pass "the receipt matches the recorded one on $(uname -s) $(uname -m)"
  else fail "the receipt differs from tests/fixtures/objc-api/provider-body.receipt on $(uname -s) $(uname -m):"; diff "$FX/provider-body.receipt" "$T/fetched.body" | head -20; fi
  grep -q '^libclang	clang version 22\.' "$T/fetched.receipt" && pass 'the receipt names clang 22' ||
    fail "the receipt's libclang line: $(grep '^libclang' "$T/fetched.receipt")"
  grep -Fxq "$(printf 'tool\t%s' "$(sha "$ROOT/tools/objc-source-inventory.c")")" "$T/fetched.receipt" &&
    pass 'the receipt names this checkout'\''s inventory tool' || fail "the receipt's tool line: $(grep '^tool' "$T/fetched.receipt")"
else
  fail "inventory with the fetched clang exits $rc"
fi

rc=0; inventory --clang-prefix "$T/no-such-clang" --output "$T/named.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && grep -q 'missing compiler' "$T/err" && [ ! -e "$T/named.receipt" ] &&
  pass 'a named --clang-prefix is used, not replaced by the fetched one' || fail "a missing named prefix exits $rc"

[ "$fails" = 0 ] && echo 'objc-source-inventory-host-test: all passed' || { echo "objc-source-inventory-host-test: $fails failed"; exit 1; }
