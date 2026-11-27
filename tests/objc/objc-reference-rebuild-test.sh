#!/bin/sh
# platform: macOS-only -- real host libclang from the pinned clang22 over the pinned SDKs; skips (77) without them
# spec: scripts/objc-reference-set.sh header -- reference/objc is exactly what build makes from the committed
#       recipe and the committed capture, byte for byte.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
skip() { echo "SKIP objc_reference_rebuild: $*"; exit 77; }
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -15 "$T/err" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || skip 'the pinned clang22 libclang that parses the SDKs is a Mach-O'
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-reference-rebuild-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
[ -n "${DRYDOCK_OBJC:-}" ] && [ -x "$DRYDOCK_OBJC" ] || fail 'DRYDOCK_OBJC (CTest passes it) names no built drydock-objc'
. "$HERE/lib/objc_staged_scripts.sh"
REFSET="$(stage_objc_scripts "$T/staged")/objc-reference-set.sh"
REF="$ROOT/reference/objc"
RECIPE="$ROOT/reference/objc-recipes/mavericks-10.9.recipe"
PREFIX=${MAVERGREEN_OBJC_CLANG_PREFIX:-}
if [ -z "$PREFIX" ]; then
  case "$(uname -m)" in x86_64) short=clang22; flavor=native ;; arm64) short=clang22-cross; flavor=cross ;; *) skip "no pinned clang22 for $(uname -m)" ;; esac
  version=$(tr -d '[:space:]' <"$ROOT/components/objc-reference-clang/version")
  PREFIX=$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "mavericks-clang-22-$flavor-$version.pkg" "$short" "$version" \
    "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/objc-reference-$short-$version" 2>"$T/err") || skip "the pinned $short $version cannot be fetched"
fi
for a in $(awk '$1 == "floor-sdk-arch" || $1 == "newer-sdk-arch" { print $2 }' "$RECIPE"); do
  sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch "$a" >/dev/null 2>"$T/err" || skip "the pinned $a SDK cannot be fetched"
done
mkdir "$T/capture"
cp "$REF/floor-runtime.tsv" "$REF/cluster-witnesses.json" "$T/capture/"
sh "$REFSET" build --recipe "$RECIPE" --clang-prefix "$PREFIX" --runtime "$T/capture" --output "$T/rebuilt" >"$T/out" 2>"$T/err" ||
  fail 'building from the committed recipe and capture failed'
diff -r "$T/rebuilt" "$REF" >"$T/diff" 2>&1 || fail "the rebuild from the committed recipe differs from reference/objc: $(head -20 "$T/diff")"
echo "objc-reference-rebuild: reference/objc rebuilds byte-identical from $RECIPE"
