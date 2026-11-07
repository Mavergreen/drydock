#!/bin/sh
#   usage: elf-needs.sh ELF
#          prints what ELF asks of the host that loads it, as build-info key=value lines:
#          isa-needed=<the highest x86 ISA level its GNU property note names, or none>
#          glibc-needed=<the newest GLIBC_ symbol version it references>
set -eu
[ $# -eq 1 ] || { echo "usage: elf-needs.sh ELF" >&2; exit 2; }
f=$1
[ -f "$f" ] || { echo "elf-needs: no $f" >&2; exit 1; }
notes=$(readelf -n "$f") || { echo "elf-needs: readelf -n $f failed" >&2; exit 1; }
isa=$(printf '%s\n' "$notes" | sed -n 's/.*x86 ISA needed: //p' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | sed -n '$p')
versions=$(readelf -V "$f") || { echo "elf-needs: readelf -V $f failed" >&2; exit 1; }
glibc=$(printf '%s\n' "$versions" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -t. -k1,1n -k2,2n -k3,3n | sed -n '$p')
[ -n "$glibc" ] || { echo "elf-needs: $f names no GLIBC_ version" >&2; exit 1; }
echo "isa-needed=${isa:-none}"
echo "glibc-needed=$glibc"
