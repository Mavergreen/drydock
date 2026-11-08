#!/bin/sh
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
needs=$(sh "$HERE/../packaging/elf-needs.sh" "$BIN/drydock-macho-rewrite") || needs=
isa=$(printf '%s\n' "$needs" | sed -n 's/^isa-needed=//p')
[ "$isa" = x86-64-baseline ] \
  && ok "drydock-macho-rewrite needs no x86 ISA level above the baseline" \
  || bad "drydock-macho-rewrite needs x86 ISA level ${isa:-unknown}, above the x86-64 baseline every x86_64 host has"
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
    [ "$p" = "drydock-$V/bin/drydock-macho-rewrite" ] && continue
    if cmp -s "$a" "$b"; then same=$((same + 1)); else differ=$((differ + 1)); bad "$p differs from the macOS archive's"; fi
  done < "$T/linux.list"
  [ "$same" -ge 10 ] && [ "$differ" -eq 0 ] \
    && ok "every file but drydock-macho-rewrite is the macOS archive's, byte for byte ($same files)" \
    || bad "$same files the same, $differ different"
fi

echo "linux_archive_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
