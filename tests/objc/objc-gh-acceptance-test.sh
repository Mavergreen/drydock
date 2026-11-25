#!/bin/sh
# platform: host-agnostic -- reads gh's x86_64 Mach-O as bytes; fetches its pkg, and skips (77) where it cannot reach
#           github.com
# spec: src/objc/main.c header -- a real binary: gh 2.105.0-mavericks.5's bin/gh, analyzed with the arguments
#       shipyard's objc-compat.sh passes, in strict mode, makes no Objective-C send, exits 0, and its report's sha256
#       is GH_REPORT on every host.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$ROOT/build/msc.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
V=2.105.0-mavericks.5
GH_REPORT=a1e6e9b9422cdebd9de6e86c66939de0060d57064c8c7391ce8cea313e08b4e2
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-gh-acceptance-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

GH="$T/root/usr/local/mavergreen/gh"
mkdir -p "$T/root/usr/local/mavergreen"
rc=0
sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "gh-$V.pkg" gh "$V" "$GH" >/dev/null 2>"$T/fetch.err" || rc=$?
if [ "$rc" != 0 ]; then
  curl -fsS -o /dev/null --max-time 30 https://github.com/ 2>/dev/null ||
    { echo "SKIP: objc_gh_acceptance: cannot reach github.com to fetch gh-$V.pkg"; exit 77; }
  fail "fetch_product_pkg.sh exited $rc fetching gh-$V.pkg: $(tail -3 "$T/fetch.err")"
fi
[ -f "$GH/bin/gh" ] || fail "gh-$V.pkg holds no usr/local/mavergreen/gh/bin/gh"

rc=0
"$DRYDOCK_OBJC" analyze --artifact "$GH/bin/gh" --root "$T/root" --references "$ROOT/reference/objc" --mode strict \
  --analyzer-id drydock-objc-parity --report "$T/r.json" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "strict analyze of gh $V exited $rc, want 0: $(tail -3 "$T/err")"
grep '"summary": {"sends": 0,' "$T/r.json" >/dev/null || fail "gh $V's report counts sends: $(grep -o '"summary": {"sends": [0-9]*' "$T/r.json")"
[ "$(grep -c '"sends": ' "$T/r.json")" = 1 ] || fail "gh $V's report has not one artifact summary"
got=$(shasum -a 256 "$T/r.json" | cut -c1-64)
[ "$got" = "$GH_REPORT" ] ||
  fail "gh $V's report has sha256 $got here, and the test says $GH_REPORT: a report must be byte-identical on every host; change GH_REPORT only in a commit that says what changed in the report"
echo "PASS: gh $V: strict, zero sends, report $got"
