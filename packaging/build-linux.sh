#!/bin/sh
# platform: host-agnostic -- runs in the Linux job, with GNU tar
# packaging/build-linux.sh -- the Linux archive: the standalone archive's tree, built for Linux
#   usage: build-linux.sh BUILD VERSION OUT.tar.gz
#          OUT is drydock-VERSION-linux-x86_64.tar.gz, one top directory drydock-VERSION/ holding
#          bin/ and share/ as the standalone archive has them, installed by BUILD's own install
#          rules, its executables ELF for x86_64 Linux. Entries are root:root.
set -eu
usage='usage: build-linux.sh BUILD VERSION OUT.tar.gz'
[ $# -eq 3 ] || { echo "$usage" >&2; exit 2; }
B=$1 V=$2 OUT=$3
[ "${OUT##*/}" = "drydock-$V-linux-x86_64.tar.gz" ] \
  || { echo "build-linux: $OUT must be named drydock-$V-linux-x86_64.tar.gz" >&2; exit 2; }
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] \
  || { echo "build-linux: builds on x86_64 Linux only (this is $(uname -s) $(uname -m))" >&2; exit 1; }
[ -x "$B/drydock-macho-rewrite" ] || { echo "build-linux: no $B/drydock-macho-rewrite" >&2; exit 1; }
CM=$(sed -n 's/^CMAKE_COMMAND:INTERNAL=//p' "$B/CMakeCache.txt")
[ -x "$CM" ] || { echo "build-linux: $B/CMakeCache.txt names no runnable cmake" >&2; exit 1; }
REPO=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/drydock-linux.XXXXXX")
trap 'rm -rf "$work"' EXIT
"$CM" --install "$B" --prefix "$work/drydock-$V" >/dev/null
install -d "$work/drydock-$V/share/doc/drydock"
cp "$REPO/LICENSE" "$REPO/README.md" "$REPO/PROVENANCE.md" "$work/drydock-$V/share/doc/drydock/"
mkdir -p "$(dirname "$OUT")"
tar --owner=root:0 --group=root:0 -czf "$OUT" -C "$work" "drydock-$V"
echo "built $OUT"
