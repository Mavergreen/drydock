#!/bin/sh
# platform: macOS-only -- reads the .pkg's payload with pkgutil
# tests/pkg_payload_test.sh -- what the .pkg installs, read from its payload with pkgutil
#   usage: pkg_payload_test.sh DRYDOCK.pkg CMAKE BUILD-X86_64 BUILD-ARM64
#          The package installs exactly what the two builds' install rules install, merged into
#          one universal tree -- the files installed_layout_test ran through a farm -- plus the
#          docs, and the two updaters merged where the family puts them. Its Distribution names
#          both host arches. Every Mach-O it ships carries both slices, and, where codesign knows
#          arm64 (not on 10.9), the arm64 slice of drydock-macho-rewrite and of the updater keeps a
#          valid signature. Uses only tools Mac OS X 10.9 ships (pkgutil, gzip, cpio, lipo) and
#          shipyard's lipo-merge-tree.sh.
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

pkgutil --expand "$pkg" "$t/x"
grep -q 'hostArchitectures="x86_64,arm64"' "$t/x/Distribution" \
  || { echo "FAIL: the Distribution does not name both host arches, so Installer on Apple Silicon offers Rosetta: $(grep '<options' "$t/x/Distribution")"; exit 1; }
found=0; n=0
for pl in "$t"/x/*/Payload "$t"/x/Payload; do
  [ -f "$pl" ] || continue
  n=$((n + 1))
  mkdir "$t/p$n"
  gzip -dc "$pl" > "$t/p$n.cpio"
  (cd "$t/p$n" && cpio -id --quiet < "$t/p$n.cpio")
  if [ -d "$t/p$n/$tree" ]; then found=$((found + 1)); got="$t/p$n"; fi
done
[ "$found" -eq 1 ] || { echo "FAIL: $found of $n payloads in $pkg carry $tree (want exactly 1)"; exit 1; }

"$CMAKE" --install "$BX" --prefix "$t/x86_64" >"$t/install.x86_64.log" 2>&1
"$CMAKE" --install "$BA" --prefix "$t/arm64" >"$t/install.arm64.log" 2>&1
sh "$SHIPYARD/lipo-merge-tree.sh" --a "$t/x86_64" --b "$t/arm64" --out "$t/want"
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
  if ! diff -r "$t/want/$d" "$got/$tree/$d"; then
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
sh "$SHIPYARD/lipo-merge-tree.sh" --a "$BX/drydock-updater.app" --b "$BA/drydock-updater.app" \
  --out "$t/drydock-updater.app"
diff -r "$t/drydock-updater.app" "$upd" \
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

case "$(sw_vers -productVersion)" in
  10.*) echo "INFO: this codesign predates arm64; the arm64 slices' signatures are checked on 11 and later" ;;
  *)
    for f in "$got/$tree/bin/drydock-macho-rewrite" "$upd/Contents/MacOS/drydock-updater"; do
      "$LIPO" "$f" -thin arm64 -output "$t/arm64-slice"
      codesign -v "$t/arm64-slice" \
        || { echo "FAIL: the arm64 slice of ${f#"$got"/} has no valid signature"; exit 1; }
      rm -f "$t/arm64-slice"
    done ;;
esac
echo "PASS: pkg_payload_test (the package installs the two builds merged, $machos Mach-O files with both slices, the docs, and the updater)"
