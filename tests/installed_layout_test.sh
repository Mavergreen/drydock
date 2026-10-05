#!/bin/sh
# tests/installed_layout_test.sh -- the tools as the .pkg lays them out: installed
# into a prefix by this build's own install rules, then reached through a farm
# of symlinks, the way /usr/local/mavergreen/bin reaches every family product.
# A wrapper looks for drydock-macho-rewrite and its two support files beside
# the name it was run by, so the farm must carry all of bin/; the pipeline run
# through it must give the digest recorded on 10.9, with no wrapper falling
# back to another drydock-macho-rewrite on PATH.
#
#   sh tests/installed_layout_test.sh <cmake> <builddir>
set -eu
CMAKE=${1:?usage: installed_layout_test.sh CMAKE BUILDDIR}
B=${2:?usage: installed_layout_test.sh CMAKE BUILDDIR}
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/installed-layout.XXXXXX")
trap 'rm -rf "$t"' EXIT

"$CMAKE" --install "$B" --prefix "$t/tree" >/dev/null
[ -f "$t/tree/share/man/man1/drydock-macho-rewrite.1" ] \
  || { echo "FAIL: the install has no share/man/man1/drydock-macho-rewrite.1"; exit 1; }
mkdir "$t/farm"
for f in "$t/tree/bin/"*; do ln -s "$f" "$t/farm/${f##*/}"; done

sh "$here/characterize.sh" "$t/farm" check >"$t/out" 2>"$t/err" \
  || { cat "$t/out" "$t/err"; echo "FAIL: the pipeline run through the farm does not give tests/EXPECTED"; exit 1; }

# Every wrapper characterize.sh does not run is run bare through the farm: its
# usage error comes after it has found what it sources.
for f in "$t/farm/"*; do
  case ${f##*/} in drydock-macho-rewrite|*.sh) continue ;; esac
  "$f" >/dev/null 2>>"$t/err" || :
done
if grep -E 'cannot find|not next to me' "$t/err"; then
  echo "FAIL: a wrapper run through the farm did not find what sits beside it"; exit 1
fi
echo "PASS: installed_layout_test ($(ls "$t/farm" | wc -l | tr -d ' ') names in the farm)"
