#!/bin/sh
# packaging/build-standalone.sh -- the standalone archive: merge-tree.sh's universal tree, tarred
#   usage: build-standalone.sh BUILD-X86_64 BUILD-ARM64 VERSION OUT.tar.gz
#          OUT is drydock-VERSION-macos-universal.tar.gz, one top directory drydock-VERSION/
#          holding bin/ and share/ exactly as the .pkg installs them, without its updater, manifest
#          or scripts: unpacked anywhere, it needs nothing else from Mavergreen.
set -eu
usage='usage: build-standalone.sh BUILD-X86_64 BUILD-ARM64 VERSION OUT.tar.gz'
[ $# -eq 4 ] || { echo "$usage" >&2; exit 2; }
BX=$1 BA=$2 V=$3 OUT=$4
[ "${OUT##*/}" = "drydock-$V-macos-universal.tar.gz" ] \
  || { echo "build-standalone: $OUT must be named drydock-$V-macos-universal.tar.gz" >&2; exit 2; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/drydock-standalone.XXXXXX")
trap 'rm -rf "$work"' EXIT
sh "$REPO/packaging/merge-tree.sh" "$BX" "$BA" "$work/drydock-$V"
mkdir -p "$(dirname "$OUT")"
COPYFILE_DISABLE=1 tar -czf "$OUT" -C "$work" "drydock-$V"
echo "built $OUT"
