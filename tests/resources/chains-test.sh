#!/bin/sh
# platform: host-agnostic -- reads committed nibs and reference tables, and builds its one Mach-O fixture with the
#   pinned clang22 against the pinned 10.9 SDK (tests/lib/toolchain.sh), which links but never runs it; with
#   DRYDOCK_RESOURCES_GMALLOC=1 the driver runs under macOS guard malloc, and the test SKIPs (77) without it
set -u
: "${DRYDOCK_RESOURCES_CHAINS_DRIVER:?names the built resources-chains-driver (CTest sets it)}"
D=$DRYDOCK_RESOURCES_CHAINS_DRIVER
GMALLOC=/usr/lib/libgmalloc.dylib
if [ "${DRYDOCK_RESOURCES_GMALLOC:-}" = 1 ]; then
  [ -f "$GMALLOC" ] || { echo "SKIP: no $GMALLOC"; exit 77; }
  run() { DYLD_INSERT_LIBRARIES=$GMALLOC MALLOC_STRICT_SIZE=1 "$D" "$@"; }
else
  run() { "$D" "$@"; }
fi
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
REF=$ROOT/reference/objc
T=$(mktemp -d "${TMPDIR:-/tmp}/chains-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
row() { awk -F'\t' -v c="$1" '$1 == c { print $2 "|" $3 "|" $4 }' "$2"; }
expect() {  # NAME CLASS OUT WANT
  got=$(row "$2" "$3") c=$(printf '%.40s' "$2")
  [ "$got" = "$4" ] && pass "$1: $c is $(printf '%.80s' "$4")" || fail "$1: $c is '$got', not '$(printf '%.80s' "$4")'"
}
drive() {  # OUT ARG...: the driver over the floor tables, for 10.9
  out=$1; shift
  run "$REF" 10.9 "$@" > "$T/$out" 2>"$T/err" || { fail "$out: driver exit $?: $(cat "$T/err")"; : > "$T/$out"; }
}

drive layout --nib "$FIX/nib/layout.nib"
expect chains_system NSTextField "$T/layout" "resolved|-|NSTextField NSControl NSView NSResponder NSObject"
expect chains_system NSObject "$T/layout" "resolved|-|NSObject"
expect chains_system IBClassReference "$T/layout" "resolved|-|IBClassReference NSObject"
n=$(grep -c . "$T/layout")
want=$("$DRYDOCK_RESOURCES_GRAPH_DRIVER" "$FIX/nib/layout.nib" | sed -n 's/^#[0-9]* //p' | LC_ALL=C sort -u | grep -c .)
[ "$n" -ge 1 ] && [ "$n" = "$want" ] && pass "chains_system: one chain per class, $n" \
  || fail "chains_system: $n chains for $want classes"
unres=$(awk -F'\t' '$2 != "resolved"' "$T/layout")
[ -z "$unres" ] && pass "chains_system: every layout.nib class resolves" || fail "chains_system: unresolved: $unres"
LC_ALL=C sort -c "$T/layout" 2>/dev/null && pass "chains_system: chains sorted by class" || fail "chains_system: chains not sorted"

drive newer --class NSGridView
expect chains_newer NSGridView "$T/newer" "resolved|10.12|NSGridView NSView NSResponder NSObject"

drive custom-none --nib "$FIX/nib/values.nib"
expect chains_custom DDFixtureView "$T/custom-none" "unresolved|-|DDFixtureView"
expect chains_custom NSView "$T/custom-none" "resolved|-|NSView NSResponder NSObject"
expect chains_custom NSClassSwapper "$T/custom-none" "resolved|-|NSClassSwapper NSObject"

drive unreadable --nib "$FIX/nib/values.nib" --binary "$ROOT/tests/not-a-macho.txt"
case $(cat "$T/unreadable") in
  *"binary $ROOT/tests/not-a-macho.txt: unreadable: "?*) pass "chains_unreadable_binary: refused with a reason" ;;
  *) fail "chains_unreadable_binary: no refusal with a reason: $(head -1 "$T/unreadable")" ;;
esac
expect chains_unreadable_binary DDFixtureView "$T/unreadable" "unresolved|-|DDFixtureView"

drive missing --nib "$FIX/nib/values.nib" --binary "$T/no-such-binary"
grep -q "^binary $T/no-such-binary: unreadable: ." "$T/missing" && pass "chains_unreadable_binary: a missing binary too" \
  || fail "chains_unreadable_binary: a missing binary: $(head -1 "$T/missing")"

printf 'int dd_classless(void) { return 0; }\n' > "$T/classless.c"
if ( . "$ROOT/tests/lib/toolchain.sh" &&
     for src in "$FIX/objc/DDFixtureView.m" "$FIX/objc/DDUnmeasured.c" "$T/classless.c"; do
       out=$(basename "$src"); out=$T/${out%.*}.dylib
       env -i PATH=/usr/bin:/bin "$CC" -arch x86_64 -mmacosx-version-min=10.9 -O1 -dynamiclib -fno-objc-arc \
         "$src" -framework AppKit -o "$out" || exit 1
     done ) > "$T/build" 2>&1; then
  drive custom --nib "$FIX/nib/values.nib" --binary "$T/DDFixtureView.dylib"
  expect chains_custom DDFixtureView "$T/custom" "resolved|-|DDFixtureView NSView NSResponder NSObject"
  grep -q '^binary ' "$T/custom" && fail "chains_custom: the fixture was refused: $(grep '^binary ' "$T/custom")" \
    || pass "chains_custom: the fixture reads"
  drive unmeasured --class DDUnmeasured --binary "$T/DDUnmeasured.dylib"
  expect chains_unmeasured DDUnmeasured "$T/unmeasured" "unresolved|-|DDUnmeasured"
  grep -q '^binary ' "$T/unmeasured" && fail "chains_unmeasured: the fixture was refused: $(grep '^binary ' "$T/unmeasured")" \
    || pass "chains_unmeasured: the fixture reads"
  drive classless --class NSView --binary "$T/classless.dylib"
  grep -q '^binary ' "$T/classless" && fail "chains_unreadable_binary: a class-less x86_64 image was refused: $(grep '^binary ' "$T/classless")" \
    || pass "chains_unreadable_binary: a class-less x86_64 image is read, and adds nothing"
  expect chains_unreadable_binary NSView "$T/classless" "resolved|-|NSView NSResponder NSObject"
else
  fail "chains_custom: cannot build the fixtures: $(tail -3 "$T/build")"
fi

H=$T/ref
mkdir -p "$H"
{ printf 'class\tNSObject\t-\t-\tNSObject\tlibobjc.A.dylib\t-\n'
  printf 'class\tCycA\t-\tCycB\tNSObject\tX\t-\n'
  printf 'class\tCycB\t-\tCycA\tNSObject\tX\t-\n'
  printf 'class\tSelf\t-\tSelf\tNSObject\tX\t-\n'
  i=0; while [ $i -lt 70 ]; do printf 'class\tDeep%d\t-\tDeep%d\tNSObject\tX\t-\n' $i $((i + 1)); i=$((i + 1)); done
  printf 'class\tDeep70\t-\tNSObject\tNSObject\tX\t-\n'
  i=0; while [ $i -lt 62 ]; do printf 'class\tOk%d\t-\tOk%d\tNSObject\tX\t-\n' $i $((i + 1)); i=$((i + 1)); done
  printf 'class\tOk62\t-\tNSObject\tNSObject\tX\t-\n'
  printf 'class\tOrphan\t-\tNowhere\tNSObject\tX\t-\n'
} > "$H/floor-runtime.tsv"
{ printf 'class\tAppKit\tLater\t-\tCycA\t-\t10.15\t-\t0\tx.h:1\t-\n'
  printf 'class\tAppKit\tEarly\t-\tNSObject\t-\t10.8\t-\t0\tx.h:2\t-\n'
  printf 'class\tAppKit\tUnstated\t-\tNSObject\t-\t-\t-\t1\tx.h:3\t-\n'
  printf 'class\tAppKit\tNewer\t-\tUnstated\t-\t10.10.3\t-\t0\tx.h:4\t-\n'
  printf 'class\tAppKit\tTen\t-\tNSObject\t-\t10.10\t-\t0\tx.h:5\t-\n'
  printf 'class\tAppKit\tTwelve\t-\tTen\t-\t10.12\t-\t0\tx.h:6\t-\n'
} > "$H/newer-sdk.tsv"
long=$(awk 'BEGIN { for (i = 0; i < 1024; i++) printf "41" }')
run "$H" 10.9 --class CycA --class Self --class Deep0 --class Ok0 --class Orphan --class Later --class Early \
  --class Unstated --class Newer --class Twelve --class IBBar --swapper-hex 4942466f6f --swapper-hex 4942426172 \
  --swapper-hex "" --swapper-hex 4100 --swapper-hex 00 --swapper-hex "${long}41" --swapper-hex "$long" \
  > "$T/hostile" 2>"$T/err" || fail "chains_hostile: driver exit $?: $(cat "$T/err")"
for c in CycA Self Deep0 Orphan Later; do expect chains_hostile $c "$T/hostile" "unresolved|-|$c"; done
[ "$(row Ok0 "$T/hostile" | cut -d'|' -f1)" = resolved ] && pass "chains_hostile: a 64-class chain resolves" \
  || fail "chains_hostile: Ok0 is '$(row Ok0 "$T/hostile")'"
expect chains_hostile IBFoo "$T/hostile" "unresolved|-|IBFoo"
expect chains_hostile IBBar "$T/hostile" "resolved|-|IBBar NSObject"
expect chains_newer Early "$T/hostile" "resolved|-|Early NSObject"
expect chains_newer Unstated "$T/hostile" "resolved|?|Unstated NSObject"
expect chains_newer Newer "$T/hostile" "resolved|?|Newer Unstated NSObject"
expect chains_newer Twelve "$T/hostile" "resolved|10.12|Twelve Ten NSObject"
a1024=$(printf '%1024s' '' | tr ' ' A)
expect chains_hostile "$a1024" "$T/hostile" "unresolved|-|$a1024"
n=$(grep -c . "$T/hostile")
[ "$n" = 15 ] && pass "chains_hostile: swapper names empty, with a NUL or over 1024 bytes are not classes" \
  || fail "chains_hostile: $n chains, not 15: $(cut -c1-40 "$T/hostile")"

printf 'class\tAppKit\tOdd\t-\tNSObject\t-\t10.x\t-\t0\tx.h:1\t-\n' > "$H/newer-sdk.tsv"
run "$H" 10.9 > "$T/out" 2>&1 && fail "chains_malformed: a version that is not a version was accepted" \
  || pass "chains_malformed: a version that is not a version is refused"
run "$REF" 10.x > "$T/out" 2>&1 && fail "chains_malformed: a target that is not a version was accepted" \
  || pass "chains_malformed: a target that is not a version is refused"
printf 'class\tShort\t-\n' > "$H/floor-runtime.tsv"
run "$H" 10.9 > "$T/out" 2>&1 && fail "chains_malformed: a short class row was accepted" \
  || pass "chains_malformed: a short class row is refused"
run "$T/no-such-dir" 10.9 > "$T/out" 2>&1 && fail "chains_malformed: a missing reference directory was accepted" \
  || pass "chains_malformed: a missing reference directory is refused"

[ "$fails" -eq 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all chains tests passed"
