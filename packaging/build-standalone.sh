#!/bin/sh
# platform: macOS-only -- tars merge-tree.sh's universal tree, which lipo makes
# packaging/build-standalone.sh -- the standalone archive: merge-tree.sh's universal tree, tarred
#   usage: build-standalone.sh BUILD-X86_64 BUILD-ARM64 VERSION OUT.tar.gz
#          OUT is drydock-VERSION-macos-universal.tar.gz, one top directory drydock-VERSION/
#          holding bin/ and share/ exactly as the .pkg installs them, without its updater, manifest
#          or scripts: unpacked anywhere, it needs nothing else from Mavergreen. Entries are
#          root:wheel with no Mac metadata where this tar can say so (bsdtar 3; not 10.9's 2.8).
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
flags="--uid 0 --gid 0 --uname root --gname wheel --no-mac-metadata"
if ! COPYFILE_DISABLE=1 tar $flags -cf /dev/null -C "$work" "drydock-$V" 2>/dev/null; then
  echo "build-standalone: this tar ($(tar --version | head -1)) cannot record root:wheel or omit Mac metadata; the archive keeps this machine's owner" >&2
  flags=""
fi
COPYFILE_DISABLE=1 tar $flags -czf "$OUT" -C "$work" "drydock-$V"
echo "built $OUT"
