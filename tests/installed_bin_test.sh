#!/bin/sh
# platform: host-agnostic -- symlinks and the scripts it runs; chained-fixups and apple_silicon_signing run only on macOS
#   usage: installed_bin_test.sh BINDIR
#          The arm64 checks CI runs on a Mac against the installed pkg take an installed bin/ as well as a build dir.
#          Hands each one a farm of only the names `install` puts in bin/, none of this build's fixture helpers,
#          and runs it from a directory with no build in it.
set -u
BIN=${1?usage: installed_bin_test.sh BINDIR}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/installed-bin-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

mkdir "$T/bin" "$T/cwd"
names="drydock-macho-rewrite drydock-objc drydock-resources drydock-macho-rewrite-compat.sh drydock-macho-rewrite-translate.sh"
for w in "$ROOT"/compat/*.sh; do
  case ${w##*/} in translate.sh|drydock-macho-rewrite-compat.sh|bake-mavericks-shim.sh) ;; *) n=${w##*/}; names="$names ${n%.sh}" ;; esac
done
for n in $names; do
  [ -e "$BIN/$n" ] && ln -s "$BIN/$n" "$T/bin/$n"
done
[ -x "$T/bin/drydock-macho-rewrite" ] || { echo "installed_bin_test: $BIN has no drydock-macho-rewrite" >&2; exit 1; }
for h in makefat fatcheck mklinkedit raise_corpus mkkext; do
  [ -e "$T/bin/$h" ] && bad "the farm holds the build helper $h"
done

for s in chained-fixups.sh macfuse_golden_test.sh apple_silicon_signing_test.sh; do
  sed -n '1,45p' "$ROOT/tests/$s" | grep -q 'installed bin/' \
    && ok "$s's usage names an installed bin/" || bad "$s's usage does not name an installed bin/"
done

runs() {  # SCRIPT [DIR]: run it on the farm from a directory with no build in it; 0 ran, 77 not exercised, else fail
  rc=0; (cd "$T/cwd" && sh "${2:-$ROOT/tests}/$1" "$T/bin") >"$T/out" 2>&1 || rc=$?
  case $rc in
    0) ok "$1 ran on an installed bin/ and exited 0" ;;
    77) why=$(grep -m1 '^SKIP' "$T/out" | cut -c1-120)
        if [ "${DRYDOCK_REQUIRE_EXEC:-}" = arm64 ]; then bad "$1 was not exercised (77) with DRYDOCK_REQUIRE_EXEC=arm64: $why"
        else echo "INFO $1 not exercised here (77: ${why:-no reason given})"; fi ;;
    *) bad "$1 on an installed bin/ exited $rc: $(tail -3 "$T/out")" ;;
  esac
}
mkdir "$T/stubs"
printf 'echo "SKIP: stubbed"\nexit 77\n' >"$T/stubs/skips.sh"
(unset DRYDOCK_REQUIRE_EXEC; runs skips.sh "$T/stubs") >"$T/pin.out" 2>&1 && ! grep -q '^FAIL' "$T/pin.out" \
  && ok "an inner 77 is reported, not failed, without DRYDOCK_REQUIRE_EXEC" || bad "an inner 77 failed without DRYDOCK_REQUIRE_EXEC: $(cat "$T/pin.out")"
(DRYDOCK_REQUIRE_EXEC=arm64; export DRYDOCK_REQUIRE_EXEC; runs skips.sh "$T/stubs") >"$T/pin.out" 2>&1
grep -q '^FAIL skips.sh was not exercised' "$T/pin.out" && ok "an inner 77 fails, naming the script, with DRYDOCK_REQUIRE_EXEC=arm64" \
  || bad "an inner 77 did not fail with DRYDOCK_REQUIRE_EXEC=arm64: $(cat "$T/pin.out")"
runs macfuse_golden_test.sh
if [ "$(uname -s)" = Darwin ]; then
  runs chained-fixups.sh
  runs apple_silicon_signing_test.sh
else
  echo "INFO chained-fixups.sh and apple_silicon_signing_test.sh: not macOS"
fi

echo "installed_bin_test: $fail failed"
[ "$fail" -eq 0 ]
