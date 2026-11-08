#!/bin/sh
# platform: macOS-only -- compares the archive with the .pkg's payload, read with pkgutil
# tests/standalone_archive_test.sh -- the standalone archive is the .pkg's tree, and runs from anywhere
#   usage: standalone_archive_test.sh ARCHIVE DRYDOCK.pkg
#          ARCHIVE is drydock-<v>-macos-universal.tar.gz: one top directory, drydock-<v>/, holding
#          exactly what the .pkg installs under usr/local/mavergreen/drydock except its manifest,
#          owned by root:wheel, with no AppleDouble entries, stored xattrs or bundle, and with the
#          .pkg's file modes. Every Mach-O carries both slices and loads nothing from outside
#          /usr/lib, /System/Library or itself. Unpacked under a path with a space, with a decoy
#          drydock-macho-rewrite first on PATH, the tool and every wrapper give the same results as
#          the .pkg's own copies. A wrapper reached through a symlink asks for
#          DRYDOCK_MACHO_REWRITE_COMPAT_DIR, and works once given it. Without a cc to build the bake
#          shim it skips that one case, except under GitHub Actions. Uses only tools Mac OS X 10.9
#          ships (tar, pkgutil, gzip, cpio, lipo, otool, shasum, stat).
set -eu
usage='usage: standalone_archive_test.sh ARCHIVE DRYDOCK.pkg'
[ $# -eq 2 ] || { echo "$usage" >&2; exit 2; }
archive=$1 pkg=$2
REPO=$(cd "$(dirname "$0")/.." && pwd)
fixture=$REPO/tests/fixture.macho
tree=usr/local/mavergreen/drydock
fail() { echo "FAIL: $*"; exit 1; }

[ -f "$archive" ] || fail "no archive at $archive"
[ -f "$pkg" ] || fail "no package at $pkg"
b=${archive##*/}
case "$b" in
  drydock-*-macos-universal.tar.gz) v=${b#drydock-}; v=${v%-macos-universal.tar.gz} ;;
  *) fail "$b is not named drydock-<version>-macos-universal.tar.gz" ;;
esac
top=drydock-$v
t=$(mktemp -d "${TMPDIR:-/tmp}/standalone-archive.XXXXXX")
trap 'rm -rf "$t"' EXIT

tar -tzf "$archive" > "$t/list" || fail "tar cannot list $b"
while IFS= read -r e; do
  case "$e" in "$top"|"$top"/*) ;; *) fail "$b holds $e, outside $top/" ;; esac
  n=${e%/}; n=${n##*/}
  case "$n" in ._*) fail "$b holds an AppleDouble entry: $e" ;; esac
  case "$n" in mavergreen.plist) fail "$b holds the package manager's manifest: $e" ;; esac
  case "$e" in *.app|*.app/*) fail "$b holds a bundle: $e" ;; esac
done < "$t/list"
tar -tvzf "$archive" | awk '$3 != "root" || $4 != "wheel" { print; exit 1 }' > "$t/owner" \
  || fail "$b records an owner other than root:wheel: $(cat "$t/owner")"
gzip -dc "$archive" | grep -a -q -E 'LIBARCHIVE\.xattr\.|SCHILY\.xattr\.' \
  && fail "$b stores extended attributes in its pax headers"

u="$t/with space"
mkdir "$u"
tar -xzf "$archive" -C "$u" || fail "tar cannot unpack $b"
A="$u/$top"
[ -x "$A/bin/drydock-macho-rewrite" ] || fail "$top/bin/drydock-macho-rewrite is missing or not executable"

pkgutil --expand "$pkg" "$t/x"
found=0
for pl in "$t"/x/*/Payload "$t"/x/Payload; do
  [ -f "$pl" ] || continue
  d="$t/p$found"
  mkdir "$d"
  gzip -dc "$pl" > "$d.cpio"
  (cd "$d" && cpio -id --quiet < "$d.cpio")
  if [ -d "$d/$tree" ]; then P="$d/$tree"; found=$((found + 1)); fi
done
[ "$found" -eq 1 ] || fail "$found payloads in $pkg carry $tree (want exactly 1)"
diff -r -x mavergreen.plist "$P" "$A" > "$t/diff" \
  || fail "$top/ is not the package's $tree without its manifest: $(head -5 "$t/diff")"
modes() { (cd "$1" && find . ! -name mavergreen.plist -exec stat -f '%Lp %N' {} + | sort); }
modes "$P" > "$t/modes-pkg"
modes "$A" > "$t/modes-archive"
diff "$t/modes-pkg" "$t/modes-archive" > "$t/diff" \
  || fail "$top/'s file modes differ from the package's: $(head -5 "$t/diff")"

machos=0
find "$A" -type f > "$t/files"
while IFS= read -r f; do
  lipo -info "$f" >/dev/null 2>&1 || continue
  machos=$((machos + 1))
  r=${f#"$A"/}
  lipo "$f" -verify_arch x86_64 arm64 || fail "$r lacks a slice: $(lipo -info "$f" 2>&1 | sed 's/.*: //')"
  otool -arch all -L "$f" | sed -n 's/^[[:space:]]\{1,\}\(.*\) (compatibility version .*/\1/p' > "$t/deps"
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/Library/*|@loader_path/*|@executable_path/*|@rpath/*) ;;
      *) fail "$r loads $dep, outside the system and the archive" ;;
    esac
  done < "$t/deps"
  otool -arch all -l "$f" | sed -n 's/^[[:space:]]*path \(.*\) (offset .*/\1/p' > "$t/rpaths"
  while IFS= read -r rp; do
    case "$rp" in /*) fail "$r has an absolute LC_RPATH $rp" ;; esac
  done < "$t/rpaths"
done < "$t/files"
[ "$machos" -ge 1 ] || fail "no Mach-O in $top/"

mkdir "$t/decoy"
printf '#!/bin/sh\necho DECOY\nexit 99\n' > "$t/decoy/drydock-macho-rewrite"
chmod +x "$t/decoy/drydock-macho-rewrite"
clean() { env -i HOME="$t" PATH="$t/decoy:/usr/bin:/bin" "$@"; }

clean "$A/bin/drydock-macho-rewrite" --capabilities > "$t/caps" 2>&1 \
  || fail "drydock-macho-rewrite --capabilities from the unpacked archive: $(head -3 "$t/caps")"

# run_case NAME CMD... -- CMD runs in a fresh directory holding the fixture as f, once with the
# archive's bin/ as BIN and once with the package's; both must exit 0, neither may reach the decoy,
# and the directories must end with the same contents.
run_case() {
  name=$1; shift
  for side in archive pkg; do
    if [ "$side" = archive ]; then BIN="$A/bin"; else BIN="$P/bin"; fi
    w="$t/run-$name-$side"
    mkdir "$w"
    cp "$fixture" "$w/f"
    rc=0
    (cd "$w" && clean sh -c "$*" sh "$BIN") > "$t/out" 2>&1 || rc=$?
    grep -q DECOY "$t/out" && fail "$name from the $side reached the decoy on PATH"
    [ "$rc" -eq 0 ] || fail "$name from the $side exited $rc: $(head -5 "$t/out")"
    (cd "$w" && find . -type f | sort | while IFS= read -r g; do shasum "$g"; done) > "$t/sum-$side"
  done
  cmp -s "$t/sum-archive" "$t/sum-pkg" || fail "$name: the archive's result differs from the package's"
}
run_case drydock-macho-rewrite 'printf "minos at-most 10.9\n" | "$1/drydock-macho-rewrite" f o'
run_case patch_macho '"$1/patch_macho" f o'
run_case change_dylib '"$1/change_dylib" f -strip-lc uuid -change /usr/lib/libSystem.B.dylib @loader_path/../S.dylib'
run_case add_version_min '"$1/add_version_min" f'
run_case fix_macho '"$1/fix_macho" f -change /usr/lib/libSystem.B.dylib @loader_path/../S.dylib'
run_case rename_segment '"$1/rename_segment" f __DATA __DATB'
run_case retag_swift_classes '"$1/retag_swift_classes" f'
run_case insert_dylib '"$1/insert_dylib" --all-yes /usr/lib/libfoo.dylib f o'
printf 'int printf(const char *f, ...) { return 0; }\n' > "$t/shim.c"
if ${CC:-cc} -dynamiclib -arch x86_64 -mmacosx-version-min=10.9 -o "$t/shim.dylib" "$t/shim.c" 2>"$t/cc.err"; then
  run_case bake-mavericks-shim "\"\$1/bake-mavericks-shim\" f o --shim '$t/shim.dylib'"
elif [ -n "${GITHUB_ACTIONS:-}" ]; then
  fail "${CC:-cc} could not build the shim, so bake-mavericks-shim would go unproven: $(head -3 "$t/cc.err")"
else
  echo "INFO: ${CC:-cc} could not build a shim here, so bake-mavericks-shim did not run from the archive"
fi

mkdir "$t/linkbin" "$t/run-link"
ln -s "$A/bin/insert_dylib" "$t/linkbin/insert_dylib"
cp "$fixture" "$t/run-link/f"
if (cd "$t/run-link" && clean "$t/linkbin/insert_dylib" --all-yes /usr/lib/libfoo.dylib f o) > "$t/out" 2>&1; then
  fail "insert_dylib through a symlink ran without DRYDOCK_MACHO_REWRITE_COMPAT_DIR"
fi
grep -q DRYDOCK_MACHO_REWRITE_COMPAT_DIR "$t/out" \
  || fail "insert_dylib through a symlink failed without naming DRYDOCK_MACHO_REWRITE_COMPAT_DIR: $(head -3 "$t/out")"
(cd "$t/run-link" && clean DRYDOCK_MACHO_REWRITE_COMPAT_DIR="$A/bin" "$t/linkbin/insert_dylib" --all-yes /usr/lib/libfoo.dylib f o) > "$t/out" 2>&1 \
  || fail "insert_dylib through a symlink, given DRYDOCK_MACHO_REWRITE_COMPAT_DIR, failed: $(head -3 "$t/out")"

echo "PASS: standalone_archive_test ($b is the package's tree without its manifest, $machos Mach-O files with both slices and no outside loads, and runs from anywhere)"
