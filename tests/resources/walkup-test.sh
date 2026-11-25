#!/bin/sh
# platform: host-agnostic -- builds its one Mach-O fixture with the pinned clang22 against the pinned 10.9 SDK
#   (tests/lib/toolchain.sh), which links but never runs it; SKIPs (77) where there is no clang22
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
R=$DRYDOCK_RESOURCES
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
T=$(mktemp -d "${TMPDIR:-/tmp}/walkup-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
refs() { echo --references "$ROOT/reference/objc" --resource-references "$ROOT/reference/resources"; }
convert() {  # OUT ARG...: drydock-resources convert ARG..., stdout in $T/OUT, stderr in $T/OUT.err, status in $T/OUT.rc
  out=$1; shift
  "$R" convert $(refs) "$@" > "$T/$out" 2>"$T/$out.err"; echo $? > "$T/$out.rc"
}
rc() { cat "$T/$1.rc"; }
err() { head -3 "$T/$1.err"; }
keyed() { [ "$(head -c 8 "$1")" = bplist00 ]; }

( . "$ROOT/tests/lib/toolchain.sh" ) > "$T/toolchain" 2>&1 || { echo "SKIP: no clang22: $(tail -1 "$T/toolchain")"; exit 77; }

W=$T/walkup.app/Contents/Resources
mkdir -p "$W/Base.lproj" "$T/walkup.app/Contents/Frameworks/DD.framework/Versions/A" "$T/walkup.app/Contents/MacOS"
cp "$FIX/nib/values.nib" "$W/values.nib"
printf 'int dd_classless(void) { return 0; }\n' > "$T/classless.c"
if ( . "$ROOT/tests/lib/toolchain.sh" &&
     env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -mmacosx-version-min=10.9 -O1 -dynamiclib -fno-objc-arc \
       "$FIX/objc/DDFixtureView.m" -framework AppKit -o "$T/walkup.app/Contents/Frameworks/DD.framework/Versions/A/DD" &&
     env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -mmacosx-version-min=10.9 -O1 -dynamiclib "$T/classless.c" \
       -o "$T/walkup.app/Contents/MacOS/walkup" ) > "$T/build" 2>&1; then
  ln -s Versions/A/DD "$T/walkup.app/Contents/Frameworks/DD.framework/DD"
  "$R" dump --references "$ROOT/reference/objc" "$W/values.nib" > "$T/walkup.rez" 2>"$T/walkup.err"
  grep -q '^chain DDFixtureView : NSView : NSResponder : NSObject$' "$T/walkup.rez" \
    && pass "walker_walk_up: dump finds a custom class's chain in the enclosing bundle's frameworks" \
    || fail "walker_walk_up: dump: $(grep DDFixtureView "$T/walkup.rez" | head -2) $(head -2 "$T/walkup.err")"
  convert walkup --no-strict "$T/walkup.app"
  keyed "$W/values.nib" && ! grep -q 'unresolved-chain' "$T/walkup" \
    && pass "walker_walk_up: convert of the bundle resolves it too, so the nib is written" \
    || fail "walker_walk_up: convert: exit $(rc walkup), $(grep -e unresolved -e unencodable "$T/walkup") $(err walkup)"
  printf 'garbage' > "$T/walkup.app/Contents/MacOS/notes"
  cp "$FIX/nib/values.nib" "$W/values.nib"
  convert walkup2 --no-strict "$W/values.nib"
  keyed "$W/values.nib" && ! grep -q 'its classes are not used' "$T/walkup2.err" \
    && pass "walker_walk_up: convert of a lone nib walks up to its bundle, reading only Mach-O files" \
    || fail "walker_walk_up: lone nib: exit $(rc walkup2), $(err walkup2)"
else
  fail "walker_walk_up: cannot build the fixtures: $(tail -3 "$T/build")"
fi

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
