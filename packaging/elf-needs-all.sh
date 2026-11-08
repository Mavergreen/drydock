#!/bin/sh
#   usage: elf-needs-all.sh DIR
#          measures every ELF file directly in DIR with elf-needs.sh and prints the most any of them asks:
#          isa-needed=<the highest x86 ISA level over them, none when none names one>
#          glibc-needed=<the newest GLIBC_ version over them>
#          elf-count=<how many ELF files it measured>
#          Files that are not ELF are skipped. No ELF, or one that cannot be measured, is exit 1.
set -eu
[ $# -eq 1 ] || { echo "usage: elf-needs-all.sh DIR" >&2; exit 2; }
d=$1
here=$(cd "$(dirname "$0")" && pwd)
[ -d "$d" ] || { echo "elf-needs-all: no directory $d" >&2; exit 1; }
rank() {
  case $1 in
    none) echo 0 ;;
    x86-64-baseline) echo 1 ;;
    x86-64-v2) echo 2 ;;
    x86-64-v3) echo 3 ;;
    x86-64-v4) echo 4 ;;
    *) echo "elf-needs-all: unknown x86 ISA level $1" >&2; return 1 ;;
  esac
}
isa=none glibc= n=0
for f in "$d"/*; do
  [ -f "$f" ] || continue
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  needs=$(sh "$here/elf-needs.sh" "$f") || { echo "elf-needs-all: cannot measure $f" >&2; exit 1; }
  i=$(printf '%s\n' "$needs" | sed -n 's/^isa-needed=//p')
  g=$(printf '%s\n' "$needs" | sed -n 's/^glibc-needed=//p')
  [ "$(rank "$i")" -le "$(rank "$isa")" ] || isa=$i
  glibc=$(printf '%s\n%s\n' "$glibc" "$g" | sed '/^$/d' | sort -t. -k1,1n -k2,2n -k3,3n | sed -n '$p')
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "elf-needs-all: no ELF file in $d" >&2; exit 1; }
echo "isa-needed=$isa"
echo "glibc-needed=$glibc"
echo "elf-count=$n"
