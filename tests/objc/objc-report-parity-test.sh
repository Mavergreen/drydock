#!/bin/sh
# platform: host-agnostic -- builds its corpus with the pinned clang22 against the pinned 10.9 SDK, then reports on it
# spec: src/objc/main.c header -- host-independent bytes: fixtures from each suite (report, classification, closure,
#       guard-evidence, provider, attest, regexec), each analyzed in inventory mode against the committed reference
#       set under a pinned analyzer id, gives the report whose sha256 tests/objc/parity/digests.tsv holds.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$ROOT/build/msc.sh"
. "$ROOT/tests/lib/toolchain.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
P="$HERE/parity"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-report-parity-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
row() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$2"; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
fxcc() { env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@"; }
B="$T/root/bin"
mkdir -p "$B"
printf 'int main(void) { return 0; }\n' >"$T/main.c"
fxcc "$FX/classify.c" -o "$B/classify" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_fixture_use
fxcc -DFORM=4 "$FX/merged-send.S" -o "$B/merged" -framework Foundation -lobjc
fxcc "$FX/r2.c" -o "$B/r2" -lobjc
fxcc "$FX/closure.c" -o "$B/closure" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_NSSelectorFromString -Wl,-U,_fixture_nsstring \
  -Wl,-U,_fixture_use -Wl,-U,_objc_retainAutoreleasedReturnValue -Wl,-U,_objc_release
fxcc "$FX/guard-coverage.c" -o "$B/guard-coverage" -lobjc -Wl,-U,_fixture_use
fxcc "$T/main.c" "$FX/provider-impl.c" "$FX/provider-register.c" -o "$B/provider" -lobjc
fxcc "$FX/sweep-main.c" "$FX/sweep-table.S" -o "$B/sweep" -lobjc
fxcc -Os -fobjc-arc -fno-modules -fno-autolink -fPIC "$T/main.c" "$FX/table-provider.m" -o "$B/table-provider" -lobjc
fxcc "$T/main.c" "$FX/regexec-launder.S" -o "$B/launder" -lobjc
# NAME:EXIT, where 4 (cannot measure) still writes a report: a class_addMethod outside any declared provider, or
# selectors and classes computed where the analyzer reads only literals.
CORPUS='classify:0 merged:0 r2:0 closure:0 guard-coverage:0 provider:4 sweep:0 table-provider:4 launder:4'

for f in objects.tsv digests.tsv; do
  [ "$(wc -l <"$P/$f" | tr -d ' ')" = 9 ] || fail "$P/$f has not one row for each of the 9 fixtures"
done
bad=0
for e in $CORPUS; do
  n=${e%:*} x=${e#*:}
  want=$(row "$n" "$P/objects.tsv") got=$(sha "$B/$n")
  if [ "$got" != "$want" ]; then
    echo "FAIL: $n: clang22 built an object with sha256 $got here, and objects.tsv says $want. The corpus is built at test time because the pinned clang22 built byte-identical objects on 10.9 and Linux; where it no longer does, commit the 10.9-built objects under tests/objc/parity/ instead" >&2
    bad=1; continue
  fi
  rc=0
  "$DRYDOCK_OBJC" analyze --artifact "$B/$n" --root "$T/root" --references "$ROOT/reference/objc" --mode inventory \
    --analyzer-id drydock-objc-parity --report "$T/$n.json" 2>"$T/err" || rc=$?
  [ "$rc" = "$x" ] || fail "$n: analyze exited $rc, want $x: $(tail -3 "$T/err")"
  want=$(row "$n" "$P/digests.tsv") got=$(sha "$T/$n.json")
  if [ "$got" != "$want" ]; then
    echo "FAIL: $n: its report's sha256 is $got here, and digests.tsv says $want: a report must be byte-identical on every host; regenerate digests.tsv only in a commit that says what changed in the report" >&2
    bad=1; continue
  fi
  echo "PASS: $n: report $got"
done
[ "$bad" = 0 ] || exit 1
