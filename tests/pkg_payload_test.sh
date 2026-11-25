#!/bin/sh
# platform: host-agnostic -- reads the .pkg with shipyard's pkg_read.sh and its Mach-O with clang22's llvm tools
# tests/pkg_payload_test.sh -- what the .pkg installs, read from its payload with pkg_read.sh
#   usage: pkg_payload_test.sh DRYDOCK.pkg CMAKE BUILD-X86_64 BUILD-ARM64
#          DRYDOCK.pkg may also be a directory `pkg_read.sh expand` made.
#          The package installs exactly what the two builds' install rules install, merged into
#          one universal tree -- the files installed_layout_test ran through a farm -- plus the
#          docs, and the two updaters merged where the family puts them. Its Distribution names
#          both host arches. Every Mach-O it ships carries both slices, and, where codesign knows
#          arm64 (macOS 11 and later), the arm64 slice of drydock-macho-rewrite and of the updater
#          keeps a valid signature. A fat file may differ from the expected one in how lipo laid out
#          the container, never in its arches or any slice. Uses shipyard's pkg_read.sh and
#          lipo-merge-tree.sh, clang22's llvm-lipo and llvm-otool, and gzip, cpio, od and cmp.
set -eu
usage='usage: pkg_payload_test.sh DRYDOCK.pkg CMAKE BUILD-X86_64 BUILD-ARM64'
[ $# -eq 4 ] || { echo "$usage" >&2; exit 2; }
pkg=$1 CMAKE=$2 BX=$3 BA=$4
REPO=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$REPO
. "$ROOT/tests/lib/toolchain.sh"
. "$REPO/build/msc.sh"
tree=usr/local/mavergreen/drydock
t=$(mktemp -d "${TMPDIR:-/tmp}/pkg-payload.XXXXXX")
trap 'rm -rf "$t"' EXIT

fat_archs() { "$LIPO" -info "$1" 2>/dev/null | sed -n 's/^Architectures in the fat file: .* are: //p'; }
fat_layout() {   # fat_layout FILE: each slice's offset and alignment, read from the fat header
  set -- "$1" $(fat_archs "$1")
  f=$1; shift; i=0
  hx=$(od -An -v -tx1 -N$((8 + 20 * $#)) "$f" | tr -d ' \n')
  for a in "$@"; do
    b=$((16 + 40 * i)); i=$((i + 1))
    e=$((0x$(echo "$hx" | cut -c$((b + 33))-$((b + 40)))))
    printf '%s at %s align 2^%s; ' "$a" "$(printf '%#x' $((0x$(echo "$hx" | cut -c$((b + 17))-$((b + 24))))))" "$e"
  done
}
same_fat() {   # same_fat WANT GOT: both fat, the same arches, each arch's slice byte for byte alike
  wa=$(fat_archs "$1"); ga=$(fat_archs "$2")
  [ -n "$wa" ] && [ "$wa" = "$ga" ] || return 1
  for a in $wa; do
    "$LIPO" "$1" -thin "$a" -output "$t/sw.$a" && "$LIPO" "$2" -thin "$a" -output "$t/sg.$a" \
      && cmp -s "$t/sw.$a" "$t/sg.$a" || { rm -f "$t"/sw.* "$t"/sg.*; return 1; }
  done
  rm -f "$t"/sw.* "$t"/sg.*
  echo "INFO: ${3:-$1} differs only in its fat container (slices byte-identical): want $(fat_layout "$1")got $(fat_layout "$2")"
}
same_tree() {   # same_tree WANT GOT: diff -r, except that a fat file may differ in container layout alone
  diff -rq "$1" "$2" >"$t/dd" 2>&1 && return 0
  rc=0
  while IFS= read -r l; do
    case $l in
      Files\ *\ differ) ;;
      *) cat "$t/dd"; return 1 ;;
    esac
    dw=${l#Files }; dw=${dw%% and *}; dg=${l#* and }; dg=${dg% differ}
    same_fat "$dw" "$dg" "${dg#"$2"/}" || { echo "$l"; rc=1; }
  done <"$t/dd"
  return $rc
}

mkdir "$t/fc"
cp "$REPO/tests/fixture.macho" "$t/fc/x"; cp "$t/fc/x" "$t/fc/a"
printf '\014\000\000\001\000\000\000\000' | dd of="$t/fc/a" bs=1 seek=4 conv=notrunc 2>/dev/null
"$LIPO" -create -arch x86_64 "$t/fc/x" -arch arm64 "$t/fc/a" -segalign x86_64 1000 -segalign arm64 1000 -output "$t/fc/fat.1000"
"$LIPO" -create -arch x86_64 "$t/fc/x" -arch arm64 "$t/fc/a" -segalign x86_64 4000 -segalign arm64 4000 -output "$t/fc/fat.4000"
cmp -s "$t/fc/fat.1000" "$t/fc/fat.4000" && { echo "FAIL: self-check: -segalign did not change the container"; exit 1; }
same_fat "$t/fc/fat.1000" "$t/fc/fat.4000" >/dev/null || { echo "FAIL: self-check: two layouts of the same slices were refused"; exit 1; }
printf '\377' | dd of="$t/fc/a" bs=1 seek=4000 conv=notrunc 2>/dev/null
"$LIPO" -create -arch x86_64 "$t/fc/x" -arch arm64 "$t/fc/a" -segalign x86_64 4000 -segalign arm64 4000 -output "$t/fc/fat.mut"
same_fat "$t/fc/fat.1000" "$t/fc/fat.mut" >/dev/null && { echo "FAIL: self-check: a one-byte difference in one slice was accepted"; exit 1; }
same_fat "$t/fc/x" "$t/fc/x" >/dev/null && { echo "FAIL: self-check: a thin file was taken for a fat one"; exit 1; }
rm -rf "$t/fc"

PR=$SHIPYARD/pkg_read.sh
if [ -d "$pkg" ]; then x=$pkg; else sh "$PR" expand "$pkg" "$t/x"; x=$t/x; fi
sh "$PR" facts "$x" > "$t/facts"
grep -qx 'distribution host-architectures x86_64,arm64' "$t/facts" \
  || { echo "FAIL: the Distribution does not name both host arches, so Installer on Apple Silicon offers Rosetta: $(grep host-architectures "$t/facts")"; exit 1; }
found=0; n=0
for c in $(sed -n 's/^component \([^ ]*\) version .*/\1/p' "$t/facts"); do
  n=$((n + 1))
  sh "$PR" list "$x" "$c" > "$t/list.$c"
  grep -q "^\./$tree/" "$t/list.$c" || continue
  found=$((found + 1))
  sh "$PR" payload "$x" "$c" "$t/p"
  got=$t/p
done
[ "$found" -eq 1 ] || { echo "FAIL: $found of $n payloads in $pkg carry $tree (want exactly 1)"; exit 1; }

"$CMAKE" --install "$BX" --prefix "$t/x86_64" >"$t/install.x86_64.log" 2>&1
"$CMAKE" --install "$BA" --prefix "$t/arm64" >"$t/install.arm64.log" 2>&1
env -u LIPO sh "$SHIPYARD/lipo-merge-tree.sh" --a "$t/x86_64" --b "$t/arm64" --out "$t/want"
# Says how a differing binary differs, slice by slice, so a failure on a runner is diagnosable without its artifacts.
explain() {   # explain WANT GOT
  for a in x86_64 arm64; do
    for side in want:"$1" pkg:"$2"; do
      k=${side%%:*} f=${side#*:}
      "$LIPO" "$f" -thin "$a" -output "$t/slice.$k" 2>/dev/null || { echo "  $a: no slice in $k"; continue; }
      echo "  $a $k: $(wc -c <"$t/slice.$k" | tr -d ' ') bytes, sha256 $(shasum -a 256 "$t/slice.$k" | cut -c1-16)"
      "$OTOOL" -l "$t/slice.$k" >"$t/lc.$k" 2>&1
    done
    [ -f "$t/lc.want" ] && [ -f "$t/lc.pkg" ] && { echo "  $a load commands, want vs pkg:"; diff "$t/lc.want" "$t/lc.pkg" | head -30; }
    rm -f "$t/lc.want" "$t/lc.pkg"
  done
  echo "  first differing bytes (offset, want, pkg; octal):"; cmp -l "$1" "$2" | head -8
  for a in x86_64 arm64; do echo "  $a install of it:"; grep -F "$(basename "$1")" "$t/install.$a.log"; done
}
for d in bin share/man; do
  if ! same_tree "$t/want/$d" "$got/$tree/$d"; then
    for w in "$t/want/$d"/*; do
      [ -f "$w" ] && ! cmp -s "$w" "$got/$tree/$d/$(basename "$w")" && { echo "how $(basename "$w") differs:"; explain "$w" "$got/$tree/$d/$(basename "$w")"; }
    done
    echo "FAIL: the package's $tree/$d is not the two builds' installs merged"; exit 1
  fi
done
for f in LICENSE README.md PROVENANCE.md; do
  [ -f "$got/$tree/share/doc/drydock/$f" ] || { echo "FAIL: the package has no share/doc/drydock/$f"; exit 1; }
done
[ -f "$got/$tree/mavergreen.plist" ] || { echo "FAIL: the package has no manifest"; exit 1; }
upd="$got/Library/Application Support/Mavergreen/drydock-updater.app"
[ -d "$upd" ] || { echo "FAIL: the package has no drydock-updater.app"; exit 1; }
env -u LIPO sh "$SHIPYARD/lipo-merge-tree.sh" --a "$BX/drydock-updater.app" --b "$BA/drydock-updater.app" \
  --out "$t/drydock-updater.app"
same_tree "$t/drydock-updater.app" "$upd" \
  || { echo "FAIL: the package's drydock-updater.app is not the two builds' updaters merged"; exit 1; }

machos=0
find "$got" -type f > "$t/files"
while IFS= read -r f; do
  "$LIPO" -info "$f" >/dev/null 2>&1 || continue
  machos=$((machos + 1))
  "$LIPO" "$f" -verify_arch x86_64 arm64 \
    || { echo "FAIL: ${f#"$got"/} lacks a slice: $("$LIPO" -info "$f" 2>&1 | sed 's/.*: //')"; exit 1; }
done < "$t/files"
[ "$machos" -ge 3 ] || { echo "FAIL: only $machos Mach-O files in the payload; drydock-macho-rewrite, the updater and Sparkle at least"; exit 1; }

case "$(uname -s) $(sw_vers -productVersion 2>/dev/null || :)" in
  Darwin\ 10.*) echo "INFO: this codesign predates arm64; the arm64 slices' signatures are checked on 11 and later" ;;
  Darwin\ *)
    for f in "$got/$tree/bin/drydock-macho-rewrite" "$upd/Contents/MacOS/drydock-updater"; do
      "$LIPO" "$f" -thin arm64 -output "$t/arm64-slice"
      codesign -v "$t/arm64-slice" \
        || { echo "FAIL: the arm64 slice of ${f#"$got"/} has no valid signature"; exit 1; }
      rm -f "$t/arm64-slice"
    done ;;
  *) echo "INFO: no codesign off macOS; the arm64 slices' signatures are checked on macOS 11 and later" ;;
esac
echo "PASS: pkg_payload_test (the package installs the two builds merged, $machos Mach-O files with both slices, the docs, and the updater)"
