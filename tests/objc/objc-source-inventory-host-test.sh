#!/bin/sh
# platform: host-agnostic -- the source receipt is written on x86_64 Linux (Recaulk's release host) and on a Mac alike
# spec: cli/drydock-objc.c header (receipt) -- drydock-objc receipt loads PREFIX's libclang at run time, takes the
#       single PREFIX/lib/clang/* directory as the resource directory, and the receipt of one prepared source is the
#       same on every host: tests/objc/fixtures/provider-body.receipt, apart from its libclang line (the pinned
#       release's own version string), with a tool line naming tools/objc-source-inventory.c as IMPORTED.sha256 does.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
. "$ROOT/tests/lib/toolchain.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-source-inventory-host-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; [ ! -f "$T/err" ] || tail -15 "$T/err"; fails=$((fails + 1)); }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }

# spec: CMakeLists.txt -- DRYDOCK_OBJC_ARCH is drydock-objc's own architecture (CTest sets it); a standalone run takes the shell's.
ARCH=${DRYDOCK_OBJC_ARCH:-$(uname -m)}
# platform: drydock-objc dlopens PREFIX's libclang, so the pkg fetch_clang22.sh takes follows drydock-objc's architecture;
#           on a Mac it must also be able to run here, which the exec gate decides.
if [ "$(uname -s)" = Darwin ]; then . "$ROOT/tests/lib/exec-arch.sh"; gate_test "$ARCH"; fi
CLANG=$(sh "$SHIPYARD_SCRIPTS/fetch_clang22.sh" "$ROOT/components/objc-receipt-clang") ||
  { echo 'FAIL: cannot fetch the pinned receipt clang'; exit 1; }
# spec: tools/objc-source-inventory.c header -- the profile parses against the floor SDK Recaulk's build uses.
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64) || { echo 'FAIL: cannot fetch the pinned floor SDK'; exit 1; }
# platform: a Mac's libclang is a .dylib, Linux's a .so.
lib=libclang.dylib; [ "$(uname -s)" = Darwin ] || lib=libclang.so

mkdir -p "$T/src"
cp "$FX/provider-body.m" "$FX/provider-register.c" "$T/src/"
printf '%s  provider-body.m\n%s  provider-register.c\n' "$(sha "$T/src/provider-body.m")" "$(sha "$T/src/provider-register.c")" >"$T/inputs"
umask 022
receipt() { "$DRYDOCK_OBJC" receipt "$@" --inputs "$T/inputs" --root "$T/src" --unit provider-body.m --unit provider-register.c; }

tool=$(awk '$2 == "tools/objc-source-inventory.c" { print $1 }' "$HERE/IMPORTED.sha256")
# spec: tools/objc-source-inventory.c header -- the recorded receipt, with the tool line where the producer writes it (after sdk).
awk -v t="$tool" '{ print } /^sdk\t/ { print "tool\t" t }' "$FX/provider-body.receipt" >"$T/expected"
rc=0; receipt --clang-prefix "$CLANG" --sdk "$SDK" --output "$T/fetched.receipt" 2>"$T/err" || rc=$?
if [ "$rc" = 0 ]; then
  pass 'the receipt is written with the pinned reference clang'
  grep -v '^libclang	' "$T/fetched.receipt" >"$T/fetched.body"
  if cmp -s "$T/fetched.body" "$T/expected"; then pass "the receipt matches the recorded one on $(uname -s) $(uname -m)"
  else fail "the receipt differs from tests/objc/fixtures/provider-body.receipt on $(uname -s) $(uname -m):"; diff "$T/expected" "$T/fetched.body" | head -20; fi
  grep -q '^libclang	clang version 22\.' "$T/fetched.receipt" && pass 'the receipt names clang 22' ||
    fail "the receipt's libclang line: $(grep '^libclang' "$T/fetched.receipt")"
  [ -n "$tool" ] && grep -Fxq "$(printf 'tool\t%s' "$tool")" "$T/fetched.receipt" &&
    pass "the receipt's tool line is IMPORTED.sha256's tools/objc-source-inventory.c" || fail "the receipt's tool line: $(grep '^tool' "$T/fetched.receipt")"
  [ "$(ls -ln "$T/fetched.receipt" | cut -c1-10)" = -rw-r--r-- ] && pass "receipt_mode: under umask 022 the receipt is 0644, readable by every consumer" ||
    fail "receipt_mode: under umask 022 the receipt is $(ls -ln "$T/fetched.receipt" | cut -c1-10), not -rw-r--r--"
  rc=0; ( umask 027; receipt --clang-prefix "$CLANG" --sdk "$SDK" --output "$T/masked.receipt" ) 2>"$T/err" || rc=$?
  [ "$rc" = 0 ] && [ "$(ls -ln "$T/masked.receipt" | cut -c1-10)" = -rw-r----- ] && pass "receipt_mode_umask: under umask 027 the receipt is 0640" ||
    fail "receipt_mode_umask: exit $rc, mode $(ls -ln "$T/masked.receipt" 2>/dev/null | cut -c1-10)"
else
  fail "receipt with the fetched clang exits $rc"
fi

# receipt_bad_libclang: a prefix whose libclang is an empty file is a prerequisite failure, and writes nothing.
mkdir -p "$T/bad/lib/clang/22/include"
: >"$T/bad/lib/libclang.dylib"; : >"$T/bad/lib/libclang.so"
rc=0; receipt --clang-prefix "$T/bad" --sdk "$SDK" --output "$T/bad.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && grep -q "^drydock-objc: cannot load libclang $T/bad/lib/$lib: " "$T/err" && [ ! -e "$T/bad.receipt" ] &&
  pass 'receipt_bad_libclang: an empty libclang exits 4, says it cannot load it, and writes nothing' || fail "receipt_bad_libclang: exit $rc"

# receipt_needs_prefix, and its twin for the SDK: either one missing is a usage error, with receipt's usage.
usage_line='       drydock-objc receipt --clang-prefix PREFIX --sdk FLOOR_SDK --inputs FILE'
rc=0; receipt --sdk "$SDK" --output "$T/noprefix.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] && grep -Fq "$usage_line" "$T/err" && [ ! -e "$T/noprefix.receipt" ] &&
  pass 'receipt_needs_prefix: no --clang-prefix exits 2 with the usage' || fail "receipt_needs_prefix: exit $rc"
rc=0; receipt --clang-prefix "$CLANG" --output "$T/nosdk.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] && grep -Fq "$usage_line" "$T/err" && [ ! -e "$T/nosdk.receipt" ] &&
  pass 'receipt_needs_sdk: no --sdk exits 2 with the usage' || fail "receipt_needs_sdk: exit $rc"

# receipt_resource_dir: the resource directory is the one PREFIX/lib/clang/* directory; none, or two, exits 4.
resource=$(ls -d "$CLANG"/lib/clang/* | head -1)
mkdir -p "$T/none/lib/clang"; ln -s "$CLANG/lib/$lib" "$T/none/lib/$lib"
rc=0; receipt --clang-prefix "$T/none" --sdk "$SDK" --output "$T/none.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && [ ! -e "$T/none.receipt" ] && pass 'receipt_resource_dir: no PREFIX/lib/clang/* directory exits 4' || fail "receipt_resource_dir (none): exit $rc"
mkdir -p "$T/two/lib/clang"; ln -s "$CLANG/lib/$lib" "$T/two/lib/$lib"
ln -s "$resource" "$T/two/lib/clang/a"; ln -s "$resource" "$T/two/lib/clang/b"
rc=0; receipt --clang-prefix "$T/two" --sdk "$SDK" --output "$T/two.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && [ ! -e "$T/two.receipt" ] && pass 'receipt_resource_dir: two PREFIX/lib/clang/* directories exit 4' || fail "receipt_resource_dir (two): exit $rc"
# receipt_stale_resource_dir: the one directory must be libclang's own major version; lib/clang/21 beside clang 22 exits 4.
mkdir -p "$T/stale/lib/clang/21/include"; ln -s "$CLANG/lib/$lib" "$T/stale/lib/$lib"
rc=0; receipt --clang-prefix "$T/stale" --sdk "$SDK" --output "$T/stale.receipt" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && grep -q 'clang/21' "$T/err" && grep -q 'clang version 22' "$T/err" && [ ! -e "$T/stale.receipt" ] &&
  pass 'receipt_stale_resource_dir: lib/clang/21 beside libclang 22 exits 4 and writes nothing' || fail "receipt_stale_resource_dir: exit $rc"

# receipt_missing_symbol: a libclang that loads but exports only clang_getClangVersion is a prerequisite failure
# naming the first clang_ function it lacks, exit 4, and writes nothing.
# platform: the stub is a Mach-O dylib built with clang22, so this runs on a Mac only. It is drydock-objc's
#           architecture, for drydock-objc to load: x86_64 by $CC, against the floor SDK, arm64 by $CC_ARM64, against
#           the arm64 SDK (the floor SDK has no arm64 libSystem).
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$T/stubprefix/lib/clang/22/include"
  printf 'int clang_getClangVersion(void) { return 0; }\n' >"$T/stub.c"
  case "$ARCH" in arm64) STUB_CC=$CC_ARM64 ;; *) STUB_CC=$CC ;; esac
  env -i PATH=/usr/bin:/bin "$STUB_CC" -dynamiclib \
    -o "$T/stubprefix/lib/libclang.dylib" "$T/stub.c" 2>"$T/err" ||
    { echo 'FAIL: cannot build the stub libclang'; cat "$T/err"; exit 1; }
  # spec: src/objc/libclang_shim.c -- the functions are resolved in the order DRYDOCK_LIBCLANG_FUNCTIONS lists them.
  first=$(sed -n 's/^    X([A-Za-z ]*, \(clang_[A-Za-z0-9_]*\),.*/\1/p' "$ROOT/src/objc/libclang_shim.c" | head -1)
  rc=0; receipt --clang-prefix "$T/stubprefix" --sdk "$SDK" --output "$T/stub.receipt" 2>"$T/err" || rc=$?
  [ "$rc" = 4 ] && [ -n "$first" ] && grep -Fq "has no $first" "$T/err" && [ ! -e "$T/stub.receipt" ] &&
    pass "receipt_missing_symbol: a libclang without $first exits 4, names it, and writes nothing" || fail "receipt_missing_symbol: exit $rc, first symbol '$first'"
else
  echo "SKIP: receipt_missing_symbol: needs a Mac to build the stub dylib ($(uname -s))"
fi

# spec: tools/objc-source-inventory.c header (--unit-flags) -- each unit parses with its own flags from a hashed file, schema 2.
UF="$T/uf"
mkdir -p "$UF"
cp "$FX/unit-flags/arc-unit.m" "$FX/unit-flags/mrc-unit.m" "$FX/unit-flags/prefix.h" "$UF/"
mkdir "$UF/sub"; : >"$UF/sub/empty.h"
ok_mrc='mrc-unit.m\t-fno-objc-arc\t-w\n'
uf_run() {
  printf '%b' "$2" >"$UF/unit.flags"
  : >"$T/uf-inputs"
  for f in arc-unit.m mrc-unit.m prefix.h sub/empty.h unit.flags; do
    [ "$f" = unit.flags ] && [ "${3:-}" = unlisted ] && continue
    printf '%s  %s\n' "$(sha "$UF/$f")" "$f" >>"$T/uf-inputs"
  done
  "$DRYDOCK_OBJC" receipt --clang-prefix "$CLANG" --sdk "$SDK" --inputs "$T/uf-inputs" --root "$UF" \
    --unit arc-unit.m --unit mrc-unit.m --unit-flags unit.flags --output "$T/$1.receipt" 2>"$T/err"
}
rc=0; uf_run schema2 "$(cat "$FX/unit-flags/unit.flags")\n" || rc=$?
if [ "$rc" = 0 ] && [ "$(head -1 "$T/schema2.receipt")" = '# objc-source-receipt 2' ] &&
   grep -Fxq "$(printf 'unit\tarc-unit.m\t-fobjc-arc -include <stage>/prefix.h -Werror')" "$T/schema2.receipt" &&
   grep -Fxq "$(printf 'unit\tmrc-unit.m\t-fno-objc-arc -w')" "$T/schema2.receipt" &&
   awk -F'\t' '$1 == "send" && $2 == "arc-unit.m" && $7 == "plain" && $8 == "FixtureRenamed" { f = 1 } END { exit !f }' "$T/schema2.receipt" &&
   grep -q "^input	unit.flags	$(sha "$UF/unit.flags")\$" "$T/schema2.receipt"; then
  pass 'unit-flags: schema 2 -- each unit row carries its flags, the prefix renames the receiver, the flags file is an input'
else
  fail "unit-flags: schema 2: exit $rc"; [ ! -f "$T/schema2.receipt" ] || cat "$T/schema2.receipt"
fi
rc=0; uf_run include-dir "arc-unit.m\t-fobjc-arc\t-I\tsub\t-include\tprefix.h\n$ok_mrc" || rc=$?
[ "$rc" = 0 ] && grep -Fxq "$(printf 'unit\tarc-unit.m\t-fobjc-arc -I <stage>/sub -include <stage>/prefix.h')" "$T/include-dir.receipt" &&
  pass 'unit-flags: -I of a directory an input lies under is taken, as <stage>/LABELDIR' || fail "unit-flags: -I of a staged directory: exit $rc"
uf_refused() {
  rc=0; uf_run "$1" "$3" "${4:-}" || rc=$?
  if [ "$rc" = 4 ] && grep -Fq -- "$2" "$T/err" && [ ! -e "$T/$1.receipt" ]; then pass "unit-flags: $1 exits 4 before any parse"
  else fail "unit-flags: $1: exit $rc"; fi
}
uf_refused 'a flag outside the set' 'unit flags: arc-unit.m: -fplugin=x is not an allowed flag' "arc-unit.m\t-fobjc-arc\t-fplugin=x\n$ok_mrc"
uf_refused '-include of a non-input' 'unit flags: arc-unit.m: -include absent.h is not an input' "arc-unit.m\t-fobjc-arc\t-include\tabsent.h\n$ok_mrc"
uf_refused '-include without a value' 'unit flags: arc-unit.m: -include takes a value' "arc-unit.m\t-fobjc-arc\t-include\n$ok_mrc"
uf_refused '-I outside the stage (/tmp)' 'unit flags: arc-unit.m: -I /tmp is no staged input directory' "arc-unit.m\t-fobjc-arc\t-I\t/tmp\n$ok_mrc"
uf_refused '-I outside the stage (../x)' 'unit flags: arc-unit.m: -I ../x is no staged input directory' "arc-unit.m\t-fobjc-arc\t-I\t../x\n$ok_mrc"
uf_refused '-I of a directory no input lies under' 'unit flags: arc-unit.m: -I nodir is no staged input directory' "arc-unit.m\t-fobjc-arc\t-I\tnodir\n$ok_mrc"
uf_refused '-I of a label prefix, not a directory' 'unit flags: arc-unit.m: -I arc is no staged input directory' "arc-unit.m\t-fobjc-arc\t-I\tarc\n$ok_mrc"
uf_refused 'a --unit with no line' 'unit flags: no line for unit mrc-unit.m' "arc-unit.m\t-fobjc-arc\n"
uf_refused 'a line for a non-unit' 'unit flags: prefix.h is not a --unit' "arc-unit.m\t-fobjc-arc\n${ok_mrc}prefix.h\t-w\n"
uf_refused 'a unit listed twice' 'unit flags: arc-unit.m listed twice' "arc-unit.m\t-fobjc-arc\n${ok_mrc}arc-unit.m\t-fobjc-arc\n"
uf_refused 'a line with no flags' 'unit flags: arc-unit.m has no flags' "arc-unit.m\n$ok_mrc"
uf_refused 'an empty line' 'unit flags: an empty line in unit.flags' "arc-unit.m\t-fobjc-arc\n\n$ok_mrc"
uf_refused 'no final newline' 'unit flags: unit.flags does not end in a newline' "arc-unit.m\t-fobjc-arc\nmrc-unit.m\t-w"
uf_refused 'the flags file not among the inputs' 'unit flags: unit.flags is not an input' "arc-unit.m\t-fobjc-arc\n$ok_mrc" unlisted
uf_refused 'CRLF' 'unit flags: a carriage return in unit.flags' "arc-unit.m\t-fobjc-arc\r\n$ok_mrc"
uf_refused 'a NUL byte' 'unit flags: a NUL byte in unit.flags' "arc-unit.m\t-fobjc-arc\0\n$ok_mrc"
big=$(awk 'BEGIN { for (i = 0; i < 80000; i++) printf "arc-unit.m\\t-w\\n" }')
uf_refused 'over 1 MiB' 'unit flags: unit.flags is over 1 MiB or unreadable' "$big"

[ "$fails" = 0 ] && echo 'objc-source-inventory-host-test: all passed' || { echo "objc-source-inventory-host-test: $fails failed"; exit 1; }
