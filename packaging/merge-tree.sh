#!/bin/sh
# platform: macOS-only -- lipo merges the x86_64 and arm64 builds into one universal tree
# packaging/merge-tree.sh -- the universal tree the .pkg and the standalone archive both ship
#   usage: merge-tree.sh BUILD-X86_64 BUILD-ARM64 OUT-DIR
#          Installs each build's tools and manual page by its own install rules (byte for byte as
#          built and tested), merges the two into one universal tree at OUT-DIR, which must not
#          exist yet, and adds the docs. No updater and no manifest: those are the .pkg's.
set -eu
usage='usage: merge-tree.sh BUILD-X86_64 BUILD-ARM64 OUT-DIR'
[ $# -eq 3 ] || { echo "$usage" >&2; exit 2; }
BX=$1 BA=$2 OUT=$3
REPO=$(cd "$(dirname "$0")/.." && pwd)
for b in "$BX" "$BA"; do
  [ -d "$b" ] || { echo "merge-tree: no build directory $b (the tree is universal: it needs an x86_64 build and an arm64 one)" >&2; exit 1; }
  [ -x "$b/drydock-macho-rewrite" ] || { echo "merge-tree: no $b/drydock-macho-rewrite" >&2; exit 1; }
done
[ ! -e "$OUT" ] || { echo "merge-tree: $OUT already exists" >&2; exit 1; }
. "$REPO/build/msc.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/drydock-tree.XXXXXX")
trap 'rm -rf "$work"' EXIT
shipyard-cmake --install "$BX" --prefix "$work/x86_64" >/dev/null
shipyard-cmake --install "$BA" --prefix "$work/arm64" >/dev/null
mkdir -p "$(dirname "$OUT")"
sh "$SHIPYARD/lipo-merge-tree.sh" --a "$work/x86_64" --b "$work/arm64" --out "$OUT" \
  --require-archs "x86_64 arm64"
install -d "$OUT/share/doc/drydock"
cp "$REPO/LICENSE" "$REPO/README.md" "$REPO/PROVENANCE.md" "$OUT/share/doc/drydock/"
find "$OUT" -name '._*' -delete
