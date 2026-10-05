#!/bin/sh
# packaging/build-pkg.sh -- the .pkg, through shipyard's stage_product.sh, build_component_pkg.sh and set_install_floor.sh
#   usage: build-pkg.sh BUILD-DIR VERSION OUT.pkg
#          Installs the tools and the manual page by the build's own install rules (byte for byte as
#          built and tested) under /usr/local/mavergreen/drydock, adds the docs and the updater, and
#          wraps them in a 10.9.5-floored product archive.
set -eu
B=${1:?usage: build-pkg.sh BUILD-DIR VERSION OUT.pkg}
V=${2:?usage: build-pkg.sh BUILD-DIR VERSION OUT.pkg}
OUT=${3:?usage: build-pkg.sh BUILD-DIR VERSION OUT.pkg}
REPO=$(cd "$(dirname "$0")/.." && pwd)
. "$REPO/build/msc.sh"
SHIPYARD=$SHIPYARD_SCRIPTS
[ -x "$B/drydock-macho-rewrite" ] || { echo "build-pkg: no $B/drydock-macho-rewrite" >&2; exit 1; }
[ -d "$B/drydock-updater.app" ] || { echo "build-pkg: no updater; configure with -DDRYDOCK_BUILD_UPDATER=ON" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/tmp}/drydock-pkg.XXXXXX")
trap 'rm -rf "$work"' EXIT
ROOT=$work/root
T=$ROOT/usr/local/mavergreen/drydock
shipyard-cmake --install "$B" --prefix "$T" >/dev/null
install -d "$T/share/doc/drydock"
cp "$REPO/LICENSE" "$REPO/README.md" "$REPO/PROVENANCE.md" "$T/share/doc/drydock/"
find "$ROOT" -name '._*' -delete
sh "$SHIPYARD/stage_product.sh" --stage "$ROOT" --product drydock --name Drydock --version "$V" \
  --scripts-out "$work/scripts" --updater-app "$B/drydock-updater.app"
sh "$SHIPYARD/build_component_pkg.sh" --root "$ROOT" --identifier dev.mavergreen.drydock \
  --version "$V" --install-location / --scripts "$work/scripts" --out "$work/drydock-component.pkg" >&2
mkdir -p "$(dirname "$OUT")"
sh "$SHIPYARD/set_install_floor.sh" --identifier dev.mavergreen.drydock --title Drydock \
  --component "$work/drydock-component.pkg" --out "$OUT" --require-scripts --host-arch x86_64 >&2
echo "built $OUT"
