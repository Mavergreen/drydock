#!/bin/sh
# tests/pkg_payload_test.sh -- what the .pkg installs, read from its payload with pkgutil
#   usage: pkg_payload_test.sh DRYDOCK.pkg CMAKE BUILDDIR
#          The package installs exactly what this build's install rules install -- the files
#          installed_layout_test ran through a farm -- plus the docs, and the updater where the
#          family puts it. Uses only tools Mac OS X 10.9 ships (pkgutil, gzip, cpio).
set -eu
pkg=${1:?usage: pkg_payload_test.sh DRYDOCK.pkg CMAKE BUILDDIR}
CMAKE=${2:?usage: pkg_payload_test.sh DRYDOCK.pkg CMAKE BUILDDIR}
B=${3:?usage: pkg_payload_test.sh DRYDOCK.pkg CMAKE BUILDDIR}
tree=usr/local/mavergreen/drydock
t=$(mktemp -d "${TMPDIR:-/tmp}/pkg-payload.XXXXXX")
trap 'rm -rf "$t"' EXIT

pkgutil --expand "$pkg" "$t/x"
found=0; n=0
for pl in "$t"/x/*/Payload "$t"/x/Payload; do
  [ -f "$pl" ] || continue
  n=$((n + 1))
  mkdir "$t/p$n"
  gzip -dc "$pl" > "$t/p$n.cpio"
  (cd "$t/p$n" && cpio -id --quiet < "$t/p$n.cpio")
  if [ -d "$t/p$n/$tree" ]; then found=$((found + 1)); got="$t/p$n"; fi
done
[ "$found" -eq 1 ] || { echo "FAIL: $found of $n payloads in $pkg carry $tree (want exactly 1)"; exit 1; }

"$CMAKE" --install "$B" --prefix "$t/want" >/dev/null
for d in bin share/man; do
  diff -r "$t/want/$d" "$got/$tree/$d" \
    || { echo "FAIL: the package's $tree/$d is not what the build installs"; exit 1; }
done
for f in LICENSE README.md PROVENANCE.md; do
  [ -f "$got/$tree/share/doc/drydock/$f" ] || { echo "FAIL: the package has no share/doc/drydock/$f"; exit 1; }
done
[ -f "$got/$tree/mavergreen.plist" ] || { echo "FAIL: the package has no manifest"; exit 1; }
upd="$got/Library/Application Support/Mavergreen/drydock-updater.app"
[ -d "$upd" ] || { echo "FAIL: the package has no drydock-updater.app"; exit 1; }
echo "PASS: pkg_payload_test (the package installs what the build installs, the docs, and the updater)"
