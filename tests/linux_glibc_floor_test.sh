#!/bin/sh
# platform: host-agnostic -- measures ELF only on Linux, where ctest registers it (not on Apple); SKIPs (77)
#   off Linux, and where the host's glibc is no newer than the floor
#   usage: linux_glibc_floor_test.sh EXE...
#          every EXE asks for no glibc above the Linux archive's stated floor, which this reads from
#          tests/linux_archive_test.sh, so the build tree fails here before a release packages it
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
[ $# -ge 1 ] || { echo "usage: linux_glibc_floor_test.sh EXE..." >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo "SKIP linux_glibc_floor_test: needs Linux: the executables measured are this build's, and only a Linux build makes ELF"; exit 77; }
FLOOR=$(sed -n 's/^GLIBC_FLOOR=//p' "$HERE/linux_archive_test.sh")
[ -n "$FLOOR" ] || { echo "FAIL tests/linux_archive_test.sh states no GLIBC_FLOOR=" >&2; exit 1; }
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | sed -n '$p')" = "$1" ]; }
bites="the check bites only where the host's glibc is newer than the floor $FLOOR, as on every CI Linux runner"
host=$(getconf GNU_LIBC_VERSION 2>/dev/null | sed -n 's/^glibc //p')
[ -n "$host" ] && newer "$host" "$FLOOR" \
  || { echo "SKIP linux_glibc_floor_test: host glibc ${host:-unknown} is not newer than $FLOOR, so nothing built here can ask for more; $bites"; exit 77; }
fails=0
for exe in "$@"; do
  g=$(sh "$HERE/../packaging/elf-needs.sh" "$exe" | sed -n 's/^glibc-needed=//p')
  if [ -n "$g" ] && ! newer "$g" "$FLOOR"; then
    echo "PASS ${exe##*/} needs glibc $g, within the floor $FLOOR (host glibc $host)"
  else
    echo "FAIL ${exe##*/} needs glibc ${g:-unknown}, above the Linux archive's floor $FLOOR; $bites" >&2
    fails=$((fails + 1))
  fi
done
[ "$fails" -eq 0 ]
