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

runs() {  # SCRIPT: run it on the farm, from a directory with no build in it; 0 and 77 pass
  rc=0; (cd "$T/cwd" && sh "$ROOT/tests/$1" "$T/bin") >"$T/out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 77 ]; then ok "$1 runs on an installed bin/ and exits $rc"
  else bad "$1 on an installed bin/ exited $rc: $(tail -3 "$T/out")"; fi
}
runs macfuse_golden_test.sh
if [ "$(uname -s)" = Darwin ]; then
  runs chained-fixups.sh
  runs apple_silicon_signing_test.sh
else
  echo "N/A chained-fixups.sh and apple_silicon_signing_test.sh: not macOS"
fi

echo "installed_bin_test: $fail failed"
[ "$fail" -eq 0 ]
