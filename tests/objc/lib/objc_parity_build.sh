#!/bin/sh
# platform: host-agnostic -- builds the parity corpus with the pinned clang22 against the pinned 10.9 SDK, as objc-report-parity-test.sh's drift check
# spec: tests/objc/objc-report-parity-test.sh header -- usage: objc_parity_build.sh DIR; leaves the ten fixtures at DIR/root/bin, and body's
#       provider prefix, build evidence and source receipt at DIR/pfx, DIR/body.evidence and DIR/pfx.receipt. Exits non-zero where it cannot build.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$ROOT/build/msc.sh"
. "$ROOT/tests/lib/toolchain.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
T=$1
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }

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
# The verified provider with its source receipt: provider-body.m and provider-register.c archived (-g, so the member
# carries a line table) and declared as objc_fixture_provider.sh declares its own, provider-consumer.m linked through
# link-args, its build evidence made, and analyzed with --provider-prefix and --source-receipt.
# platform: built in $T by relative paths, the SDK through the link $T/sdk, with $AR on every host (llvm-libtool-darwin is
#           Mac-only), so neither the objects, the link map nor the evidence (which carries the map's sha256) names
#           this host's directories.
. "$HERE/lib/objc_fixture_provider.sh"
RECEIPT_CLANG=${MAVERGREEN_OBJC_RECEIPT_CLANG_PREFIX:-}
if [ -z "$RECEIPT_CLANG" ] && [ "$(uname -s)" != Darwin ]; then
  RECEIPT_CLANG=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/objc-receipt-clang") || fail 'cannot fetch the pinned receipt clang'
elif [ -z "$RECEIPT_CLANG" ]; then
  case "${DRYDOCK_OBJC_ARCH:-$(uname -m)}" in x86_64) short=clang22; flavor=native ;; arm64) short=clang22-cross; flavor=cross ;;
    *) fail "no receipt clang for ${DRYDOCK_OBJC_ARCH:-$(uname -m)}" ;; esac
  version=$(tr -d '[:space:]' <"$ROOT/components/objc-receipt-clang/version")
  RECEIPT_CLANG=$(sh "$SHIPYARD_SCRIPTS/fetch_product_pkg.sh" --asset "mavericks-clang-22-$flavor-$version.pkg" "$short" "$version" \
    "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/objc-receipt-$short-$version") || fail 'cannot fetch the pinned receipt clang'
fi
(
  cd "$T"
  ln -s "$SDK" sdk
  relcc() { env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -isysroot sdk -mmacosx-version-min=10.9 "$@"; }
  mkdir -p body pfx/lib pfx/share/recaulk pfx.objects
  cp "$FX/provider-body.m" "$FX/provider-register.c" body/
  relcc -Os -fPIC -Wall -fno-objc-arc -g -fdebug-compilation-dir=/parity -c body/provider-body.m -o pfx.objects/provider-body.o
  relcc -Os -fPIC -Wall -g -fdebug-compilation-dir=/parity -c body/provider-register.c -o pfx.objects/provider-register.o
  "$AR" --format=darwin rcs pfx/lib/libfixture-objc.a pfx.objects/provider-body.o pfx.objects/provider-register.o
  printf '%s  provider-body.m\n%s  provider-register.c\n' "$(sha body/provider-body.m)" "$(sha body/provider-register.c)" >pfx.inputs
  declare_prefix pfx pfx.inputs
  "$DRYDOCK_OBJC" receipt --clang-prefix "$RECEIPT_CLANG" --sdk "$SDK" --inputs pfx.inputs --root body \
    --unit provider-body.m --unit provider-register.c --output pfx.receipt 2>err || fail "receipt: $(tail -3 err)"
  "$DRYDOCK_OBJC" link-args --prefix pfx --link-map root/bin/body.map >args 2>err || fail "link-args: $(tail -3 err)"
  abs="$(pwd -P)/pfx/lib/libfixture-objc.a"
  grep -Fx "$abs" args >/dev/null || fail "link-args names no $abs"
  set --; while IFS= read -r line; do [ "$line" = "$abs" ] && line=pfx/lib/libfixture-objc.a; set -- "$@" "$line"; done <args
  relcc -O1 -c "$FX/provider-consumer.m" -o consumer.o
  relcc consumer.o "$@" -Wl,-oso_prefix,"$(pwd -P)/" -o root/bin/body
  "$DRYDOCK_OBJC" evidence --artifact root/bin/body --prestrip root/bin/body --source-root body --link-map root/bin/body.map \
    --provider-prefix pfx --references "$ROOT/reference/objc" --output body.evidence 2>err || fail "evidence: $(tail -3 err)"
)
