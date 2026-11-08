#!/bin/sh
# platform: host-agnostic -- reads the archives with tar, and runs the Linux tools in the Linux job
#   usage: linux_archive_test.sh LINUX.tar.gz [MACOS.tar.gz]
#          the Linux archive holds the standalone archive's tree with Linux x86_64 executables, owned
#          by root, and runs from anywhere; given the macOS archive, it holds the same paths with the
#          same modes, and every file but the executable byte for byte
set -u
[ $# -eq 1 ] || [ $# -eq 2 ] || { echo "usage: linux_archive_test.sh LINUX.tar.gz [MACOS.tar.gz]" >&2; exit 2; }
L=$1 M=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
pass=0 fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1" >&2; fail=$((fail + 1)); }

name=${L##*/}
V=${name#drydock-}; V=${V%-linux-x86_64.tar.gz}
[ "drydock-$V-linux-x86_64.tar.gz" = "$name" ] && [ -n "$V" ] \
  && ok "named drydock-$V-linux-x86_64.tar.gz" || bad "named $name"

T=$(mktemp -d "${TMPDIR:-/tmp}/linux-archive.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
tar -tzf "$L" | sed 's|/$||' | LC_ALL=C sort > "$T/linux.list"
[ "$(cut -d/ -f1 "$T/linux.list" | sort -u)" = "drydock-$V" ] \
  && ok "one top directory, drydock-$V" || bad "top directories: $(cut -d/ -f1 "$T/linux.list" | sort -u | tr '\n' ' ')"
grep -q '/\._' "$T/linux.list" && bad "carries ._ entries" || ok "no ._ entries"
grep -Eq '\.app(/|$)|mavergreen\.plist' "$T/linux.list" && bad "carries an updater or a manifest" || ok "no updater, no manifest"
owners=$(tar -tvzf "$L" | awk '{print $2}' | sort -u)
[ "$owners" = root/root ] && ok "every entry is root/root" || bad "owners: $owners"

mkdir "$T/a dir"
tar -xzf "$L" -C "$T/a dir"
BIN="$T/a dir/drydock-$V/bin"
magic=$(od -An -tx1 -N4 "$BIN/drydock-macho-rewrite" | tr -d ' \n')
machine=$(od -An -tx1 -j18 -N2 "$BIN/drydock-macho-rewrite" | tr -d ' \n')
[ "$magic" = 7f454c46 ] && [ "$machine" = 3e00 ] \
  && ok "drydock-macho-rewrite is an x86_64 ELF executable" || bad "drydock-macho-rewrite: magic $magic, machine $machine"
# spec: README -- every ELF in bin/ is measured, drydock-objc as much as drydock-macho-rewrite: the archive's floor is the
# x86-64 baseline and glibc 2.34, and no executable may ask for more.
GLIBC_FLOOR=2.34
needs=$(sh "$HERE/../packaging/elf-needs-all.sh" "$BIN") || needs=
isa=$(printf '%s\n' "$needs" | sed -n 's/^isa-needed=//p')
glibc=$(printf '%s\n' "$needs" | sed -n 's/^glibc-needed=//p')
count=$(printf '%s\n' "$needs" | sed -n 's/^elf-count=//p')
[ "$isa" = x86-64-baseline ] \
  && ok "no executable in bin/ needs an x86 ISA level above the baseline" \
  || bad "bin/ needs x86 ISA level ${isa:-unknown}, above the x86-64 baseline every x86_64 host has"
top=$(printf '%s\n%s\n' "$GLIBC_FLOOR" "$glibc" | sort -t. -k1,1n -k2,2n -k3,3n | sed -n '$p')
[ -n "$glibc" ] && [ "$top" = "$GLIBC_FLOOR" ] \
  && ok "no executable in bin/ needs glibc above $GLIBC_FLOOR (highest: $glibc)" \
  || bad "bin/ needs glibc ${glibc:-unknown}, above the archive's stated floor $GLIBC_FLOOR"
for exe in drydock-macho-rewrite drydock-objc; do
  one=$(sh "$HERE/../packaging/elf-needs.sh" "$BIN/$exe") || one=
  oi=$(printf '%s\n' "$one" | sed -n 's/^isa-needed=//p')
  og=$(printf '%s\n' "$one" | sed -n 's/^glibc-needed=//p')
  ot=$(printf '%s\n%s\n' "$GLIBC_FLOOR" "$og" | sort -t. -k1,1n -k2,2n -k3,3n | sed -n '$p')
  [ "$oi" = x86-64-baseline ] && [ -n "$og" ] && [ "$ot" = "$GLIBC_FLOOR" ] \
    && ok "$exe needs the baseline ISA and glibc $og, within the floor" \
    || bad "$exe needs ISA ${oi:-unknown} and glibc ${og:-unknown}, beyond the baseline and glibc $GLIBC_FLOOR"
done
[ "${count:-0}" -ge 2 ] && ok "$count ELF executables measured" || bad "only ${count:-0} ELF executables measured"
"$BIN/drydock-macho-rewrite" --capabilities | grep -q '^statement symbol rename' \
  && ok "drydock-macho-rewrite runs from the unpacked archive" || bad "drydock-macho-rewrite --capabilities"
[ -f "$T/a dir/drydock-$V/share/drydock/objc/reference/manifest.json" ] \
  && ok "the archive carries the objc reference set" || bad "no share/drydock/objc/reference/manifest.json"
# platform: the Linux drydock-objc does receipt alone; receipt with no arguments is a usage error, exit 2.
"$BIN/drydock-objc" receipt >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "drydock-objc receipt without arguments exits 2" || bad "drydock-objc receipt without arguments exited $rc, not 2"
(cd / && sh "$HERE/characterize.sh" "$BIN" check) && ok "the unpacked archive's tools match the 10.9 reference digest" \
  || bad "characterize against the unpacked archive"
(cd / && sh "$HERE/known-callers.sh" "$BIN" >/dev/null) && ok "the known callers replay against the unpacked archive" \
  || bad "known-callers against the unpacked archive"

if [ -n "$M" ]; then
  tar -tzf "$M" | sed 's|/$||' | LC_ALL=C sort > "$T/macos.list"
  if cmp -s "$T/linux.list" "$T/macos.list"; then
    ok "the same paths as ${M##*/}"
  else
    bad "paths differ from ${M##*/}: $(diff "$T/macos.list" "$T/linux.list" | grep '^[<>]' | tr '\n' ' ')"
  fi
  mkdir "$T/m"
  tar -xzf "$M" -C "$T/m"
  same=0 differ=0
  while IFS= read -r p; do
    a="$T/m/$p" b="$T/a dir/$p"
    [ -f "$b" ] || continue
    [ "$(ls -ld "$a" | cut -c1-10)" = "$(ls -ld "$b" | cut -c1-10)" ] || { bad "$p: mode differs"; continue; }
    # spec: README -- the executables are built per host (ELF here, Mach-O there); every other file is shared
    case "$p" in "drydock-$V/bin/drydock-macho-rewrite"|"drydock-$V/bin/drydock-objc") continue ;; esac
    if cmp -s "$a" "$b"; then same=$((same + 1)); else differ=$((differ + 1)); bad "$p differs from the macOS archive's"; fi
  done < "$T/linux.list"
  [ "$same" -ge 10 ] && [ "$differ" -eq 0 ] \
    && ok "every file but the two executables is the macOS archive's, byte for byte ($same files)" \
    || bad "$same files the same, $differ different"
fi

echo "linux_archive_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
