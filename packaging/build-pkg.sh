#!/bin/sh
# packaging/build-pkg.sh -- the .pkg, through shipyard's lipo-merge-tree.sh, stage_product.sh, build_component_pkg.sh and set_install_floor.sh
#   usage: build-pkg.sh BUILD-X86_64 BUILD-ARM64 VERSION OUT.pkg
#          Builds merge-tree.sh's universal tree (the tools, manual page and docs the standalone
#          archive also ships) under /usr/local/mavergreen/drydock, merges the two updaters, and
#          wraps them in a 10.9.5-floored product archive whose Distribution names both host
#          arches, so Installer on Apple Silicon runs its scripts natively instead of offering Rosetta.
set -eu
usage='usage: build-pkg.sh BUILD-X86_64 BUILD-ARM64 VERSION OUT.pkg'
[ $# -eq 4 ] || { echo "$usage" >&2; exit 2; }
BX=$1 BA=$2 V=$3 OUT=$4
REPO=$(cd "$(dirname "$0")/.." && pwd)
for b in "$BX" "$BA"; do
  [ -d "$b" ] || { echo "build-pkg: no build directory $b (the .pkg is universal: it needs an x86_64 build and an arm64 one)" >&2; exit 1; }
  [ -x "$b/drydock-macho-rewrite" ] || { echo "build-pkg: no $b/drydock-macho-rewrite" >&2; exit 1; }
  [ -d "$b/drydock-updater.app" ] || { echo "build-pkg: no updater in $b; configure with -DDRYDOCK_BUILD_UPDATER=ON" >&2; exit 1; }
done
. "$REPO/build/msc.sh"
SHIPYARD=$SHIPYARD_SCRIPTS
work=$(mktemp -d "${TMPDIR:-/tmp}/drydock-pkg.XXXXXX")
trap 'rm -rf "$work"' EXIT
ROOT=$work/root
T=$ROOT/usr/local/mavergreen/drydock
sh "$REPO/packaging/merge-tree.sh" "$BX" "$BA" "$T"
mkdir -p "$work/updater"
sh "$SHIPYARD/lipo-merge-tree.sh" --a "$BX/drydock-updater.app" --b "$BA/drydock-updater.app" \
  --out "$work/updater/drydock-updater.app" --require-archs "x86_64 arm64"
find "$ROOT" -name '._*' -delete
sh "$SHIPYARD/stage_product.sh" --stage "$ROOT" --product drydock --name Drydock --version "$V" \
  --scripts-out "$work/scripts" --updater-app "$work/updater/drydock-updater.app"
sh "$SHIPYARD/build_component_pkg.sh" --root "$ROOT" --identifier dev.mavergreen.drydock \
  --version "$V" --install-location / --scripts "$work/scripts" --out "$work/drydock-component.pkg" >&2
mkdir -p "$(dirname "$OUT")"
sh "$SHIPYARD/set_install_floor.sh" --identifier dev.mavergreen.drydock --title Drydock \
  --component "$work/drydock-component.pkg" --out "$OUT" --require-scripts --host-arch x86_64,arm64 >&2
echo "built $OUT"
