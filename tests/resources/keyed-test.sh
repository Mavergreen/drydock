#!/bin/sh
# platform: host-agnostic -- builds keyed archives from dumps of committed nibs, reads Apple's committed 10.9 keyed
#   compiles and hand-edited hostile archives as bytes; with DRYDOCK_RESOURCES_GMALLOC=1 the driver runs under macOS
#   guard malloc, and the test SKIPs (77) without it
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
: "${DRYDOCK_RESOURCES_KEYED_DRIVER:?names the built resources-keyed-driver (CTest sets it)}"
: "${DRYDOCK_RESOURCES_BPLIST_DRIVER:?names the built resources-bplist-driver (CTest sets it)}"
R=$DRYDOCK_RESOURCES K=$DRYDOCK_RESOURCES_KEYED_DRIVER B=$DRYDOCK_RESOURCES_BPLIST_DRIVER
GMALLOC=/usr/lib/libgmalloc.dylib
if [ "${DRYDOCK_RESOURCES_GMALLOC:-}" = 1 ]; then
  [ -f "$GMALLOC" ] || { echo "SKIP: no $GMALLOC"; exit 77; }
  run() { DYLD_INSERT_LIBRARIES=$GMALLOC MALLOC_STRICT_SIZE=1 "$K" "$@"; }
else
  run() { "$K" "$@"; }
fi
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
REF=$ROOT/reference/objc
T=$(mktemp -d "${TMPDIR:-/tmp}/keyed-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
err() { grep -v '^GuardMalloc' "$T/err" | head -3; }
dump() { "$R" dump --references "$REF" "$1"; }
# spec: DDFixtureView's own binary is not beside a lone fixture nib, so its chain is written in as the class declares it.
custom() { sed 's/^chain DDFixtureView ?$/chain DDFixtureView : NSView : NSResponder : NSObject/'; }

n=0
for f in "$FIX"/nib/*.nib "$FIX"/nib-10.9/*.nib/keyedobjects-101300.nib; do
  b=${f#"$FIX"/}
  dump "$f" | custom > "$T/t1"
  if ! run build "$T/t1" > "$T/y" 2>"$T/err"; then fail "keyed_fixed_point_dump: build $b: $(err)"; continue; fi
  run read "$T/y" > "$T/t2" 2>"$T/err" && run build "$T/t2" > "$T/y2" 2>>"$T/err" && run read "$T/y2" > "$T/t3" 2>>"$T/err" \
    && run build "$T/t3" > "$T/y3" 2>>"$T/err" || { fail "keyed_fixed_point_dump: $b: $(err)"; continue; }
  if cmp -s "$T/t2" "$T/t3" && cmp -s "$T/y2" "$T/y3"; then n=$((n + 1))
  else fail "keyed_fixed_point_dump: $b: $(diff "$T/t2" "$T/t3" | head -4)"; fi
  "$R" build --no-adapt "$T/t1" -o "$T/cli.nib" 2>"$T/err" && cmp -s "$T/cli.nib" "$T/y" \
    || fail "keyed_fixed_point_dump: $b: drydock-resources build differs from the driver's: $(err)"
  "$R" dump "$T/cli.nib" > "$T/cli.rez" 2>"$T/err" && cmp -s "$T/cli.rez" "$T/t2" \
    || fail "keyed_fixed_point_dump: $b: drydock-resources dump of keyed input differs from the driver's: $(err)"
done
[ "$n" -ge 14 ] && pass "keyed_fixed_point_dump: $n NIBArchive fixtures: dump of build of dump is a fixed point" \
  || fail "keyed_fixed_point_dump: only $n fixtures reach a fixed point"
# spec: storyboard inner nibs are left out: their NSNibExternalObjectPlaceholder has no chain anywhere.
dump "$FIX/nib/Main.storyboardc/DDFixtureScene.nib" > "$T/scene"
run build "$T/scene" > "$T/y" 2>"$T/err"; rc=$?
[ "$rc:$(err)" = "1:unencodable: unresolved chain for NSNibExternalObjectPlaceholder" ] \
  && pass "keyed_fixed_point_dump: a storyboard scene is unencodable for its external object placeholder" \
  || fail "keyed_fixed_point_dump: the storyboard scene: exit $rc, $(err)"

n=0
for f in "$FIX"/nib-10.9/*.nib/keyedobjects.nib; do
  b=${f#"$FIX"/}
  run read "$f" > "$T/a1" 2>"$T/err" && run build "$T/a1" > "$T/y" 2>>"$T/err" && run read "$T/y" > "$T/a2" 2>>"$T/err" \
    && cmp -s "$T/a1" "$T/a2" && n=$((n + 1)) || fail "keyed_fixed_point_apple: $b: $(err) $(diff "$T/a1" "$T/a2" | head -4)"
done
[ "$n" = 7 ] && pass "keyed_fixed_point_apple: Apple's 7 keyed nibs: dump of build of dump is their dump" \
  || fail "keyed_fixed_point_apple: only $n of 7"

# spec: --no-strict, since collections.nib carries keys 10.9 is not known to read.
n=0
for f in "$FIX"/nib/*.nib; do
  b=${f#"$FIX"/}
  cp "$f" "$T/conv.nib"
  "$R" convert --no-strict --no-adapt --references "$REF" --resource-references "$ROOT/reference/resources" "$T/conv.nib" \
    > /dev/null 2>"$T/err"
  dump "$f" > "$T/c.rez" && "$R" build --no-adapt "$T/c.rez" -o "$T/built.nib" 2>/dev/null; built=$?
  if [ "$built" = 0 ]; then
    head -c 8 "$T/conv.nib" | grep -q bplist00 && cmp -s "$T/built.nib" "$T/conv.nib" && n=$((n + 1)) \
      || fail "keyed_matches_convert: $b: convert --no-adapt differs from build --no-adapt of its dump: $(err)"
  else
    cmp -s "$f" "$T/conv.nib" || fail "keyed_matches_convert: $b: convert wrote a nib build cannot"
  fi
done
[ "$n" -ge 6 ] && pass "keyed_matches_convert: for $n NIBArchive fixtures, convert --no-adapt is build --no-adapt of the dump, byte for byte" \
  || fail "keyed_matches_convert: only $n fixtures"

dump "$FIX/nib/collections.nib" > "$T/c.rez"
"$R" build --no-adapt "$T/c.rez" -o "$T/c.nib" 2>"$T/err" || fail "keyed_rules: build collections: $(err)"
"$B" dump "$T/c.nib" > "$T/c.plist"
run read "$T/c.nib" > "$T/c.keyed"
objects=$(grep -c '^@' "$T/c.rez")
at() {  # FILE N [LINES]: the first LINES (1) lines of $objects[N] in a bplist driver dump
  awk -v want="$2" -v lines="${3:-1}" '/^  "\$objects" = array/ { on = 1; next }
    on && /^    [^ ]/ { i++ } on && i == want + 1 && k++ < lines { print }' "$1"
}
index_of() {  # FILE PATTERN: the $objects index whose element first has a line matching PATTERN
  awk -v pat="$2" '/^  "\$objects" = array/ { on = 1; next } on && /^    [^ ]/ { i++ } on && $0 ~ pat { print i - 1; exit }' "$1"
}
[ "$(grep '^  "' "$T/c.plist" | cut -d'"' -f2 | tr '\n' ' ')" = '$version $archiver $top $objects ' ] \
  && grep -q '^  "\$version" = int 100000$' "$T/c.plist" && grep -q '^  "\$archiver" = string "NSKeyedArchiver"$' "$T/c.plist" \
  && pass "keyed_rules: \$version, \$archiver, \$top, \$objects, in that order" || fail "keyed_rules: top-level keys: $(grep '^  "' "$T/c.plist" | head -5)"
[ "$(at "$T/c.plist" 0)" = '    string "$null"' ] && pass "keyed_rules: \$objects[0] is \$null" || fail "keyed_rules: \$objects[0] is $(at "$T/c.plist" 0)"
sed -n '/^  "\$top" = dict/,/^  "\$objects"/p' "$T/c.plist" | grep -q '"IB.objectdata" = uid 1$' \
  && pass "keyed_rules: object 0's values are \$top" || fail "keyed_rules: \$top: $(sed -n '/\$top/,/objects/p' "$T/c.plist" | head -4)"
nclasses=$(grep -c '^      "\$classname"' "$T/c.plist")
[ "$(index_of "$T/c.plist" '"[$]classname"')" = "$objects" ] && [ "$(at "$T/c.plist" "$((objects + nclasses - 1))" 2 | sed -n 2p | cut -c1-20)" = '      "$classname" =' ] \
  && pass "keyed_rules: the $nclasses class entries follow the $objects objects" || fail "keyed_rules: the first class entry is \$objects[$(index_of "$T/c.plist" '"[$]classname"')]"
awk '/^    dict/ { want = 1; next } want { if ($0 !~ /^      "\$class(name)?" =/) bad++; want = 0 } END { exit bad > 0 }' "$T/c.plist" \
  && pass "keyed_rules: every object dict has \$class first" || fail "keyed_rules: an object dict without \$class first"
awk '{ ind = match($0, /[^ ]/) - 1 }
     /^ *"[^"]*" = / { key = $0; sub(/ = .*/, "", key); if (seen[id[ind - 2] SUBSEP key]++) { print; bad++ } }
     / = dict [0-9]+$|^ *dict [0-9]+$/ { id[ind] = ++top }
     END { exit bad > 0 }' "$T/c.plist" > "$T/dups" && grep -q '"NS.objects"' "$T/c.plist" \
  && pass "keyed_rules: no dict holds a key twice" || fail "keyed_rules: repeated keys: $(head -3 "$T/dups")"
grep -q NSInlinedValue "$T/c.plist" && fail "keyed_rules: NSInlinedValue remains" || pass "keyed_rules: no NSInlinedValue remains"
grep -q '^      "NS.objects" = array 0$' "$T/c.plist" && pass "keyed_rules: an empty array has NS.objects = []" \
  || fail "keyed_rules: no empty NS.objects"
colls=$(grep -cE '^@[0-9]+ NS(Mutable)?(Array|Set|Dictionary)$' "$T/c.rez")
nsobj=$(grep -c '^      "NS.objects" = array' "$T/c.plist")
[ "$colls" -ge 10 ] && [ "$nsobj" = $((colls + 4)) ] \
  && pass "keyed_rules: each of $colls collections, and the 4 synthesized arrays, has NS.objects" \
  || fail "keyed_rules: $colls collections, $nsobj NS.objects"
awk '/^      "NS.keys" = array/ { k = $NF; want = 1; next }
     want && /^      "NS.objects" = array/ { print k, $NF; want = 0 }' "$T/c.plist" > "$T/pairs"
[ -s "$T/pairs" ] && awk '$1 != $2 { bad++ } END { exit bad > 0 }' "$T/pairs" && grep -q '^19 19$' "$T/pairs" \
  && [ "$(wc -l < "$T/pairs" | tr -d ' ')" = "$(grep -cE '^@[0-9]+ NS(Mutable)?Dictionary$' "$T/c.rez")" ] \
  && pass "keyed_rules: each dictionary has NS.keys and NS.objects of equal length ($(tr '\n' ' ' < "$T/pairs"))" \
  || fail "keyed_rules: dictionary NS.keys/NS.objects lengths: $(tr '\n' ' ' < "$T/pairs")"
block() { sed -n "/^@$2 /,/^\$/p" "$1" | tr '\n' ' ' | tr -s ' '; }
refs() { sed -n "/^@$2 /,/^\$/p" "$1" | sed -n 's/^  UINibEncoderEmptyKey = ref //p' | awk -v every="${3:-1}" -v from="${4:-0}" '(NR - 1) % every == from' | tr '\n' ' '; }
case "$(block "$T/c.keyed" 35)" in
  *" NS.keys = uids $(refs "$T/c.rez" 35 2 0)NS.objects = uids $(refs "$T/c.rez" 35 2 1)") \
    pass "keyed_rules: a dictionary's even members are its keys and its odd ones its objects, in order" ;;
  *) fail "keyed_rules: @35 is $(block "$T/c.keyed" 35 | head -c 200)" ;;
esac
grep -q '^      "NSNextOid" = int 1000000$' "$T/c.plist" && grep -q '^      "NSFontManager" = uid 0$' "$T/c.plist" \
  && pass "keyed_rules: NSIBObjectData has NSNextOid 1000000 and a nil NSFontManager" || fail "keyed_rules: no NSNextOid 1000000 or NSFontManager nil"
fw=$(sed -n 's/^      "NSFramework" = uid //p' "$T/c.plist")
[ -n "$fw" ] && [ "$(at "$T/c.plist" "$fw")" = '    string "IBCocoaFramework"' ] \
  && pass "keyed_rules: NSFramework is the string IBCocoaFramework" || fail "keyed_rules: NSFramework is uid '$fw': $(at "$T/c.plist" "${fw:-0}")"
sed -n '/^@1 NSIBObjectData$/,/^$/p' "$T/c.keyed" > "$T/od"
tail -8 "$T/od" | sed 's/ = .*//' | tr -d ' ' | tr '\n' ' ' > "$T/odkeys"
[ "$(cat "$T/odkeys")" = 'NSFramework NSFontManager NSNextOid NSClassesKeys NSClassesValues NSNamesKeys NSNamesValues  ' ] \
  && pass "keyed_rules: the synthesized NSIBObjectData fields come last, in order" || fail "keyed_rules: NSIBObjectData ends: $(cat "$T/odkeys")"
[ "$fw" = $((objects + nclasses)) ] \
  && pass "keyed_rules: the synthesized objects follow the class entries" || fail "keyed_rules: NSFramework is \$objects[$fw]"
okeys=$(sed -n '/^@87 NSArray$/,/^$/p' "$T/c.rez" | grep -c UINibEncoderEmptyKey)
nk=$(sed -n 's/^  NSNamesKeys = ref @//p' "$T/od"); nv=$(sed -n 's/^  NSNamesValues = ref @//p' "$T/od")
[ "$okeys" -ge 10 ] && [ "$(block "$T/c.keyed" "$nk")" = "@$nk NSArray NS.objects = uids $(refs "$T/c.rez" 87)" ] \
  && pass "keyed_rules: NSNamesKeys holds NSObjectsKeys' $okeys members" || fail "keyed_rules: NSNamesKeys @$nk: $(sed -n "/^@$nk /,/^\$/p" "$T/c.keyed" | head -3)"
v1=$((nv + 1)); vn=$((nv + okeys))
sed -n "/^@$nv NSArray\$/,/^\$/p" "$T/c.keyed" | grep -q "^  NS.objects = uids @$v1 " \
  && sed -n "/^@$v1 NSString bare\$/,/^\$/p" "$T/c.keyed" | grep -q '^  NS.bytes = string "obj0"$' \
  && sed -n "/^@$vn NSString bare\$/,/^\$/p" "$T/c.keyed" | grep -q "^  NS.bytes = string \"obj$((okeys - 1))\"\$" \
  && pass "keyed_rules: NSNamesValues holds obj0..obj$((okeys - 1))" || fail "keyed_rules: NSNamesValues @$nv"
sed -n '/^@33 NSNumber bare$/,/^$/p' "$T/c.keyed" | grep -q '^  NS.dblval = f64 0x1.34ap+10  # 1234.5$' \
  && [ "$(at "$T/c.plist" 33)" = '    real 1234.5' ] && [ "$(at "$T/c.plist" 50)" = '    int 2000000000' ] \
  && [ "$(at "$T/c.plist" 37)" = '    bool 1' ] && [ "$(at "$T/c.plist" 39)" = '    bool 0' ] && [ "$(at "$T/c.plist" 7)" = '    string "Collections"' ] \
  && pass "keyed_rules: NSNumber and NSString objects are bare plist values" || fail "keyed_rules: bare values: $(at "$T/c.plist" 33) $(at "$T/c.plist" 50) $(at "$T/c.plist" 7)"
at "$T/c.plist" 22 | grep -q '^    data bytes4508:0000119c' && pass "keyed_rules: an NSData object is bare data, as Apple's 10.9 archive has it" \
  || fail "keyed_rules: \$objects[22] is $(at "$T/c.plist" 22 | head -c 60)"
sed -n '/^@86 NSMutableArray$/,/^$/p' "$T/c.keyed" | grep -q '^  NS.objects = uids$' \
  && pass "keyed_rules: an empty array dumps back as empty uids" || fail "keyed_rules: @86 is $(sed -n '/^@86 /,/^$/p' "$T/c.keyed")"
{ sed -n 1,2p "$T/c.rez"; { grep '^chain ' "$T/c.rez"; echo 'chain NSSet : NSObject'; } | sort
  sed -n '/^$/,$p' "$T/c.rez" | sed 's/^@4 NSMutableSet$/@4 NSSet/'; } > "$T/set.rez"
"$R" build --no-adapt "$T/set.rez" -o "$T/set.nib" 2>"$T/err" && run read "$T/set.nib" > "$T/set.keyed" \
  && sed -n '/^@4 NSSet$/,/^$/p' "$T/set.keyed" | grep -q '^  NS.objects = uids @5$' \
  && pass "keyed_rules: an NSSet's members become NS.objects" || fail "keyed_rules: NSSet: $(err) $(sed -n '/^@4 /,/^$/p' "$T/set.keyed")"
dump "$FIX/nib/collections-alt.nib" > "$T/alt.rez"
"$R" build --no-adapt "$T/alt.rez" -o "$T/alt.nib" 2>"$T/err" && run read "$T/alt.nib" > "$T/alt.keyed" \
  && grep -q '^  NSStackViewSpacing = f32 0x1p+3  # 8$' "$T/alt.keyed" && "$B" dump "$T/alt.nib" | grep -q '"NSStackViewSpacing" = real32 41000000$' \
  && [ "$(grep -c ' = f32 ' "$T/alt.rez")" = "$(grep -c ' = f32 ' "$T/alt.keyed")" ] \
  && pass "keyed_rules: an f32 stays a 4-byte real through the archive and back" || fail "keyed_rules: f32: $(err) $(grep Spacing "$T/alt.keyed")"
"$B" dump "$T/alt.nib" | grep -q '^      "NS.string" = string ""$' && sed -n '/NSMutableString$/,/^$/p' "$T/alt.keyed" | grep -q '^  NS.string = string ""$' \
  && pass "keyed_rules: an NSMutableString is a dict with an NS.string, as Apple's 10.9 archive has it" \
  || fail "keyed_rules: NSMutableString: $(sed -n '/NSMutableString$/,/^$/p' "$T/alt.keyed")"
dump "$FIX/nib/int64.nib" > "$T/i64.rez"
"$R" build --no-adapt "$T/i64.rez" -o "$T/i64.nib" 2>"$T/err" && run read "$T/i64.nib" | grep -q ' = i64 5000000000$' \
  && pass "keyed_rules: a 64-bit integer survives" || fail "keyed_rules: int64: $(err)"

{ cat <<'EOF'
drydock-resources dump 1
format nibarchive 1 10
chain NSArray : NSObject
chain NSIBObjectData : NSObject
chain NSMutableDictionary : NSDictionary : NSObject
chain NSObject
chain NSView : NSResponder : NSObject
@0 NSObject
  IB.objectdata = ref @1
  IB.systemFontUpdateVersion = i8 1
@1 NSIBObjectData
  NSRoot = ref @2
  NSObjectsKeys = ref @3
  NSClassesKeys = nil
@2 NSView
  NSSubviews = ref @3
  NSNextResponder = nil
  NSFrameSize = ref @4
  NSHidden = true
  NSAlpha = f32 0x1p-1
@3 NSArray
  NSInlinedValue = false
  UINibEncoderEmptyKey = ref @2
  UINibEncoderEmptyKey = ref @4
@4 NSString
  NS.bytes = data "{1, 2}"
@5 NSNumber
  NS.boolval = false
@6 NSMutableDictionary
  UINibEncoderEmptyKey = ref @4
  NSInlinedValue = true
  UINibEncoderEmptyKey = ref @5
EOF
} > "$T/small.rez"
cat > "$T/small.want" <<'EOF'
drydock-resources dump 1
format keyed
chain NSArray : NSObject
chain NSIBObjectData : NSObject
chain NSMutableDictionary : NSDictionary : NSObject
chain NSView : NSResponder : NSObject

@0 NSObject
  IB.objectdata = ref @1
  IB.systemFontUpdateVersion = i64 1

@1 NSIBObjectData
  NSRoot = ref @2
  NSObjectsKeys = ref @3
  NSClassesKeys = nil
  NSFramework = ref @7
  NSFontManager = nil
  NSNextOid = i64 1000000
  NSClassesValues = ref @8
  NSNamesKeys = ref @9
  NSNamesValues = ref @10

@2 NSView
  NSSubviews = ref @3
  NSNextResponder = nil
  NSFrameSize = ref @4
  NSHidden = true
  NSAlpha = f32 0x1p-1  # 0.5

@3 NSArray
  NS.objects = uids @2 @4

@4 NSString bare
  NS.bytes = string "{1, 2}"

@5 NSNumber bare
  NS.boolval = false

@6 NSMutableDictionary
  NS.keys = uids @4
  NS.objects = uids @5

@7 NSString bare
  NS.bytes = string "IBCocoaFramework"

@8 NSArray
  NS.objects = uids

@9 NSArray
  NS.objects = uids @2 @4

@10 NSArray
  NS.objects = uids @11 @12

@11 NSString bare
  NS.bytes = string "obj0"

@12 NSString bare
  NS.bytes = string "obj1"
EOF
run build "$T/small.rez" > "$T/small.nib" 2>"$T/err" && run read "$T/small.nib" > "$T/small.got" 2>"$T/err" \
  && cmp -s "$T/small.got" "$T/small.want" \
  && pass "keyed_small: a hand-written dump builds to exactly the archive the seven rules describe" \
  || fail "keyed_small: $(err) $(diff "$T/small.want" "$T/small.got" | head -10)"
classes=$("$B" dump "$T/small.nib" | grep '^      "\$classname"' | cut -d'"' -f4 | tr '\n' ' ')
[ "$classes" = 'NSIBObjectData NSView NSArray NSMutableDictionary ' ] \
  && pass "keyed_small: class entries in first-use order" || fail "keyed_small: class entries are $classes"

unencodable() {  # NAME WHAT: $T/NAME.rez exits 1 from the driver with "unencodable: WHAT" and nothing on stdout
  run build "$T/$1.rez" > "$T/out" 2>"$T/err"; rc=$?
  [ -s "$T/out" ] && rc="$rc, stdout not empty"
  case "$rc:$(err)" in
    "1:unencodable: $2") pass "keyed_unencodable: $1 ($2)" ;;
    *) fail "keyed_unencodable: $1: wanted exit 1 and 'unencodable: $2', got exit $rc, '$(err)'" ;;
  esac
}
edit() { sed "$2" "$T/small.rez" > "$T/$1.rez"; unencodable "$1" "$3"; }
dump "$FIX/nib/values.nib" > "$T/values.rez"
custom < "$T/values.rez" > "$T/values-custom.rez"
"$R" build --no-adapt "$T/values.rez" -o "$T/swapper.nib" > "$T/out" 2>"$T/err"; rc=$?
"$R" build --no-adapt "$T/values-custom.rez" -o "$T/swapper-custom.nib" 2>>"$T/err"
[ "$rc" = 0 ] && grep -q '^chain DDFixtureView ?$' "$T/values.rez" && cmp -s "$T/swapper.nib" "$T/swapper-custom.nib" \
  && pass "keyed_swapper_target: DDFixtureView, unresolved and only an NSClassSwapper's target, builds the same bytes as with its chain" \
  || fail "keyed_swapper_target: exit $rc, $(err), $(cmp "$T/swapper.nib" "$T/swapper-custom.nib" 2>&1)"
echo old > "$T/kept.nib"
"$R" build --no-adapt "$T/scene" -o "$T/kept.nib" > "$T/out" 2>"$T/err"; rc=$?
[ "$rc:$(err)" = "1:drydock-resources: $T/scene: unencodable: unresolved chain for NSNibExternalObjectPlaceholder" ] \
  && [ "$(cat "$T/kept.nib")" = old ] && [ ! -s "$T/out" ] && [ "$(ls "$T" | grep -c '^kept')" = 1 ] \
  && pass "keyed_unencodable: an object's unresolved chain exits 1 and leaves the output as it was" \
  || fail "keyed_unencodable: NSNibExternalObjectPlaceholder: exit $rc, $(err), output now '$(head -c 20 "$T/kept.nib")'"
"$R" build --no-adapt "$T/scene" -o "$T/none.nib" 2>/dev/null; [ -e "$T/none.nib" ] \
  && fail "keyed_unencodable: an unencodable dump wrote its output" || pass "keyed_unencodable: an unencodable dump writes nothing"
grep -v '^  UINibEncoderEmptyKey = ref @64$' "$T/c.rez" > "$T/odd.rez"
"$R" build --no-adapt "$T/odd.rez" -o "$T/odd.nib" > "$T/out" 2>"$T/err"; rc=$?
[ "$rc:$(err)" = "1:drydock-resources: $T/odd.rez: unencodable: @35 NSMutableDictionary has an odd number (37) of UINibEncoderEmptyKey values" ] \
  && [ ! -e "$T/odd.nib" ] && pass "keyed_unencodable: an odd dictionary exits 1 and writes nothing" \
  || fail "keyed_unencodable: odd dictionary: exit $rc, $(err)"
edit unresolved 's/^chain NSView : .*/chain NSView ?/' 'unresolved chain for NSView'
edit nochain '/^chain NSView /d' 'unresolved chain for NSView'
edit notutf8 's/^  NS.bytes = data "{1, 2}"$/  NS.bytes = data x"7bc3"/' '@4 NS.bytes is not UTF-8'
edit keyutf8 's/^  NSHidden = true$/  "\\xc3" = true/' '@2 has a key that is not UTF-8: \xc3'
edit classutf8 's/^chain NSView : NSResponder : NSObject$/chain NSView : "\\xff" : NSObject/' 'the chain of NSView names a class that is not UTF-8'
edit numnone 's/^  NS.boolval = false$/  NS.boolval = i8 0/' '@5 NSNumber holds no single NS.intval, NS.boolval, NS.dblval or NS.floatval'
edit numtwo 's/^  NS.boolval = false$/  NS.boolval = false\
  NS.intval = i8 1/' '@5 NSNumber holds no single NS.intval, NS.boolval, NS.dblval or NS.floatval'
edit strnone 's/^  NS.bytes = data "{1, 2}"$/  NS.string = data "x"/' '@4 NSString holds no single NS.bytes'
edit datanone 's/^@4 NSString$/@4 NSData/; s/^  NS.bytes = data "{1, 2}"$/  NS.bytes = i8 1/' '@4 NSData holds no single NS.bytes'
edit emptyview 's/^  NSHidden = true$/  UINibEncoderEmptyKey = ref @4/' '@2 NSView has UINibEncoderEmptyKey values, which only arrays, sets and dictionaries hold'
edit emptynil 's/^  UINibEncoderEmptyKey = ref @4$/  UINibEncoderEmptyKey = nil/' '@3 NSArray has a UINibEncoderEmptyKey value that is not a ref to an object'
edit oddsmall '/^  UINibEncoderEmptyKey = ref @5$/d' '@6 NSMutableDictionary has an odd number (1) of UINibEncoderEmptyKey values'
edit refzero 's/^  NSRoot = ref @2$/  NSRoot = ref @0/' "@1 NSRoot refers to @0, the archive's top, which nothing in a keyed archive can refer to"
edit topclass 's/^@0 NSObject$/@0 NSView/' "@0 is NSView, but a keyed archive's top is a plain NSObject"
edit twice 's/^  NSInlinedValue = false$/  NS.objects = nil/' '@3 would hold the key NS.objects twice'
edit dollar 's/^  NSHidden = true$/  $class = true/' '@2 would hold the key $class twice'
edit objkeys 's/^  NSObjectsKeys = ref @3$/  NSObjectsKeys = ref @2/' "@1 NSIBObjectData's NSObjectsKeys is not a ref to an array"
edit mutstr 's/^@4 NSString$/@4 NSMutableString/; s/^chain NSObject$/chain NSMutableString : NSString : NSObject\
chain NSObject/; s/^  NS.bytes = data "{1, 2}"$/  NS.string = data "x"/' '@4 NSMutableString holds no single NS.bytes'
sed 's/^@4 NSString$/@4 NSMutableString/; s/^chain NSObject$/chain NSMutableString : NSString : NSObject\
chain NSObject/' "$T/small.rez" > "$T/mutok.rez"
run build "$T/mutok.rez" > "$T/out" 2>"$T/err" && "$B" dump "$T/out" | grep -q '"NS.string" = string "{1, 2}"' \
  && pass "keyed_unencodable: the base for mutstr builds" || fail "keyed_unencodable: mutstr's base: $(err)"
sed 's/^@4 NSString$/@4 NSMutableData/; s/^chain NSMutableDictionary /chain NSMutableData : NSData : NSObject\
&/' "$T/small.rez" > "$T/mutdata.rez"
run build "$T/mutdata.rez" > "$T/out" 2>"$T/err" && "$B" dump "$T/out" > "$T/mutdata.dump" \
  && grep -q '^      "NS.data" = data "{1, 2}"$' "$T/mutdata.dump" && ! grep -q NS.bytes "$T/mutdata.dump" \
  && run read "$T/out" | grep -A1 '^@4 NSMutableData$' | grep -q '^  NS.data = data "{1, 2}"$' \
  && pass "keyed_rules: NSMutableData holds its bytes inline under NS.data, as Apple's 10.9 compile writes it" \
  || fail "keyed_rules: NSMutableData: $(err) $(grep -A3 '"NS.data"' "$T/mutdata.dump")"
sed 's/^  NS.bytes = data "{1, 2}"$/  NS.data = data "x"/' "$T/mutdata.rez" > "$T/mutdatanone.rez"
unencodable mutdatanone '@4 NSMutableData holds no single NS.bytes'
sed 's/^  NS.bytes = data "{1, 2}"$/  NS.bytes = data "$null"/; s/^chain NSObject$/chain NSObject\
chain NSString : NSObject/' "$T/small.rez" > "$T/nulltext.rez"
run build "$T/nulltext.rez" > "$T/out" 2>"$T/err" && run read "$T/out" > "$T/nulltext.got" \
  && grep -A1 '^@4 NSString$' "$T/nulltext.got" | grep -q '^  NS.string = string "\$null"$' \
  && [ "$(grep -c '^@.* bare$' "$T/nulltext.got")" = 4 ] \
  && pass "keyed_rules: an NSString whose text is \$null is a dict with NS.string, as NSKeyedArchiver writes it, not a nil" \
  || fail "keyed_rules: \$null text: $(err) $(grep -A1 '^@4 ' "$T/nulltext.got")"
sed 's/^  NS.bytes = data "\$null"$/  NS.bytes = data "$nullx"/' "$T/nulltext.rez" > "$T/nullx.rez"
run build "$T/nullx.rez" > "$T/out" 2>"$T/err" && run read "$T/out" | grep -A1 '^@4 NSString bare$' | grep -q '^  NS.bytes = string "\$nullx"$' \
  && pass "keyed_rules: an NSString whose text only starts with \$null stays a plain string" || fail "keyed_rules: \$nullx: $(err)"
sed '/^chain NSString : NSObject$/d' "$T/nulltext.rez" > "$T/nullnochain.rez"
unencodable nullnochain 'unresolved chain for NSString'
{ printf 'drydock-resources dump 1\nformat keyed\nchain C\n@0 NSObject\n  r = ref @1\n@1 C\n'
  printf '  UINibEncoderEmptyKey = nil\n  UINibEncoderEmptyKey = nil\n'; } > "$T/keyedtwice.rez"
unencodable keyedtwice '@1 would hold the key UINibEncoderEmptyKey twice'
printf 'drydock-resources dump 1\nformat keyed\n@0 NSObject\n  r = ref @1\n@1 NSView bare\n  NS.bytes = string "x"\n' > "$T/barecls.rez"
unencodable barecls '@1 is bare, but a NSView is never a plain plist value'
printf 'drydock-resources dump 1\nformat keyed\n@0 NSObject bare\n' > "$T/baretop.rez"
unencodable baretop "@0 is a bare NSObject, but a keyed archive's top is a plain NSObject"
printf 'drydock-resources dump 1\nformat keyed\n@0 NSObject\n  r = ref @1\n@1 NSString bare\n  NS.bytes = string "x"\n  UINibEncoderEmptyKey = nil\n' > "$T/baretwo.rez"
unencodable baretwo '@1 NSString holds no single NS.bytes'
printf 'drydock-resources dump 1\nformat keyed\n@0 NSObject\n  r = ref @1\n@1 NSString\n  NS.bytes = string "x"\n' > "$T/keyedchain.rez"
unencodable keyedchain 'unresolved chain for NSString'
printf 'drydock-resources dump 1\nformat keyed\n@0 NSObject\n  r = ref @1\n@1 NSNumber bare\n  NS.floatval = f32 0x1p+0\n' > "$T/barefloat.rez"
run build "$T/barefloat.rez" > "$T/out" 2>"$T/err" && "$B" dump "$T/out" | grep -q '^    real32 3f800000$' \
  && run read "$T/out" | grep -q '^  NS.floatval = f32 0x1p+0  # 1$' \
  && pass "keyed_rules: a bare 4-byte real is NS.floatval, and stays 4 bytes" || fail "keyed_rules: bare f32: $(err)"

# spec: allowed to differ: $objects order, UID numbering, NSInlinedValue and NSIBObjectData's synthesized fields;
#   a plain plist value compares by its value wherever it is referred to, since a plist writer may share equal ones;
#   sets and dictionaries compare unordered; a ref to the string $null is nil, as NSKeyedUnarchiver decodes it.
canon() {
  awk '
    function flush() { if (cur != "" && val != "") { vals[cur] = vals[cur] val "\n"; val = "" } }
    function isref(w) { return w ~ /^@[0-9]+$/ }
    function plain(r,   b) { b = vals[r]; sub(/^  [^ ]* = /, "", b); sub(/  # .*/, "", b); gsub(/\n/, "", b); return b }
    function tok(w,   r) { if (!isref(w)) return w; r = substr(w, 2); return bare[r] ? "<" cls[r] " " plain(r) ">" : w }
    function isnull(w) { return isref(w) && bare[substr(w, 2)] && plain(substr(w, 2)) == "string \"$null\"" }
    function sorted(A, n,   i, j, t) { for (i = 2; i <= n; i++) for (j = i; j > 1 && A[j - 1] > A[j]; j--) { t = A[j]; A[j] = A[j - 1]; A[j - 1] = t } }
    /^chain / { c = $2; sub(/^chain [^ ]*/, ""); chain[c] = $0; next }
    /^@[0-9]+ / { flush(); cur = substr($1, 2); cls[cur] = $2; bare[cur] = ($3 == "bare"); next }
    /^    / { sub(/^ +/, " "); val = val $0; next }
    /^  / { flush(); val = $0; next }
    END {
      flush()
      q[0] = 0; id[0] = 0; nq = 1; synth = " NSFramework NSFontManager NSNextOid NSClassesKeys NSClassesValues NSNamesKeys NSNamesValues "
      for (h = 0; h < nq; h++) {
        o = q[h]; n = split(vals[o], L, "\n"); m = 0; ki = 0; oi = 0
        for (i = 1; i < n; i++) {
          k = L[i]; sub(/^  /, "", k); key = k; sub(/ = .*/, "", key)
          if (key == "NSInlinedValue") continue
          if (cls[o] == "NSIBObjectData" && index(synth, " " key " ")) continue
          S[++m] = k
          if (key == "NS.keys") ki = m
          if (key == "NS.objects") oi = m
        }
        if (cls[o] ~ /^NS(Mutable)?(Set|Dictionary)$/ && oi) {
          no = split(S[oi], OB, " ") - 3; nk = ki ? split(S[ki], KB, " ") - 3 : 0
          for (i = 1; i <= no; i++) P[i] = (ki ? tok(KB[i + 3]) "\001" KB[i + 3] "\001" : "\001\001") tok(OB[i + 3]) "\001" OB[i + 3]
          sorted(P, no); S[oi] = "NS.objects = uids"; if (ki) S[ki] = "NS.keys = uids"
          for (i = 1; i <= no; i++) { split(P[i], W, "\001"); S[oi] = S[oi] " " W[4]; if (ki) S[ki] = S[ki] " " W[2] }
        }
        sorted(S, m)
        printf "#%d %s%s%s\n", h, cls[o], bare[o] ? " bare" : "", bare[o] || !h ? "" : chain[cls[o]]
        for (i = 1; i <= m; i++) {
          nf = split(S[i], F, " "); out = ""
          if (nf == 4 && F[3] == "ref" && isnull(F[4])) { print "  " F[1] " = nil"; continue }
          for (f = 1; f <= nf; f++) {
            w = F[f]
            if (w == "#") break
            if (isref(w) && bare[substr(w, 2)]) w = tok(w)
            else if (isref(w)) { r = substr(w, 2); if (!(r in id)) { id[r] = nq; q[nq++] = r }; w = "#" id[r] }
            out = out (f > 1 ? " " : "") w
          }
          print "  " out
        }
      }
    }'
}
# spec: collections-alt.nib's 10.9 compile lays its table out narrower and leaves out NSViewIsLayerTreeHost, a key
#   10.9 does not read; those are ibtool's own choices for the target, not the mapping's, so that diff is pinned.
cat > "$T/collections-alt.nib.diff" <<'EOF'
89c89
<   NSFrameSize = ref <NSString string "{263, 90}">
---
>   NSFrameSize = ref <NSString string "{280, 90}">
102c102
<   NSFrameSize = ref <NSString string "{263, 90}">
---
>   NSFrameSize = ref <NSString string "{280, 90}">
133a134
>   NSViewIsLayerTreeHost = true
157a159
>   NSViewIsLayerTreeHost = true
308c310
<   NSWidth = f64 0x1.07p+8
---
>   NSWidth = f64 0x1.18p+8
EOF
n=0
for d in "$FIX"/nib-10.9/*.nib; do
  b=$(basename "$d")
  run read "$d/keyedobjects.nib" | canon > "$T/apple.canon"
  dump "$FIX/nib/$b" | custom > "$T/ours.rez"
  "$R" build --no-adapt "$T/ours.rez" -o "$T/ours.nib" 2>"$T/err" || { fail "keyed_graph_equal_10_9: build $b: $(err)"; continue; }
  run read "$T/ours.nib" | canon > "$T/ours.canon"
  diff "$T/apple.canon" "$T/ours.canon" > "$T/got.diff"
  if [ -f "$T/$b.diff" ] && cmp -s "$T/got.diff" "$T/$b.diff"; then n=$((n + 1)); echo "NOTE: keyed_graph_equal_10_9: $b differs from Apple's compile only as pinned"
  elif cmp -s "$T/apple.canon" "$T/ours.canon"; then n=$((n + 1))
  else fail "keyed_graph_equal_10_9: $b: $(diff "$T/apple.canon" "$T/ours.canon" | head -6 | tr '\n' '|')"; fi
done
[ "$n" = 7 ] && pass "keyed_graph_equal_10_9: all 7 builds decode to the graph of Apple's 10.9 compile" \
  || fail "keyed_graph_equal_10_9: $n of 7 equal"
n=0
for d in "$FIX"/nib-10.9/*.nib; do
  b=$(basename "$d")
  run read "$d/keyedobjects.nib" | canon > "$T/apple.canon"
  dump "$d/keyedobjects-101300.nib" | custom > "$T/same.rez"
  "$R" build --no-adapt "$T/same.rez" -o "$T/same.nib" 2>"$T/err" || { fail "keyed_graph_equal_same_compile: build $b: $(err)"; continue; }
  run read "$T/same.nib" | canon > "$T/same.canon"
  cmp -s "$T/apple.canon" "$T/same.canon" && n=$((n + 1)) \
    || fail "keyed_graph_equal_same_compile: $b: $(diff "$T/apple.canon" "$T/same.canon" | head -6 | tr '\n' '|')"
done
[ "$n" = 7 ] && pass "keyed_graph_equal_same_compile: built from the NIBArchive of each 10.9 compile, all 7 decode to the graph of its keyed nib" \
  || fail "keyed_graph_equal_same_compile: $n of 7 equal"

"$B" dump "$FIX/nib-10.9/values.nib/keyedobjects.nib" > "$T/v.plist"
run plist "$T/v.plist" > "$T/v.nib" 2>"$T/err" && run read "$T/v.nib" > "$T/v1" && run read "$FIX/nib-10.9/values.nib/keyedobjects.nib" > "$T/v2" \
  && cmp -s "$T/v1" "$T/v2" && pass "keyed_malformed: the plist driver writes Apple's dumped archive back" \
  || fail "keyed_malformed: the unedited base: $(err)"
malformed() {  # NAME WHAT: $T/NAME.nib exits 4 from the driver with "WHAT", and nothing on stdout
  run read "$T/$1.nib" > "$T/out" 2>"$T/err"; rc=$?
  [ -s "$T/out" ] && rc="$rc, stdout not empty"
  case "$rc:$(err)" in
    "4:$2") pass "keyed_malformed: $1 ($(err))" ;;
    *) fail "keyed_malformed: $1: wanted exit 4 and '$2', got exit $rc, '$(err)'" ;;
  esac
}
written() { run plist "$T/$1.plist" > "$T/$1.nib" 2>"$T/err" || fail "keyed_malformed: $1: plist: $(err)"; malformed "$1" "$2"; }
bad() { sed "$2" "$T/v.plist" > "$T/$1.plist"; written "$1" "$3"; }
once() {  # NAME LINE NEW WHAT: the first line that is exactly LINE becomes NEW (and NEW2 after it when set)
  awk -v a="$2" -v b="$3" '!done && $0 == a { print b; done = 1; next } { print }' "$T/v.plist" > "$T/$1.plist"; written "$1" "$4"
}
last=$(($(sed -n 's/^  "\$objects" = array //p' "$T/v.plist") - 1))
cls=$(index_of "$T/v.plist" '^      "[$]classname"')
str=$(index_of "$T/v.plist" '^    string "NSObject"$')
arr=$(index_of "$T/v.plist" '^        uid ')
bad archiver 's/^  "\$archiver" = string "NSKeyedArchiver"$/  "$archiver" = string "NSKeyedArchiveX"/' 'malformed-keyed: $archiver is not NSKeyedArchiver'
bad version 's/^  "\$version" = int 100000$/  "$version" = int 100001/' 'malformed-keyed: $version is not 100000'
bad extra 's/^  "\$version" = int 100000$/  "$version" = int 100000\
  "$extra" = int 1/' 'malformed-keyed: the archive holds the key $extra'
bad twotops 's/^  "\$version" = int 100000$/  "$version" = int 100000\
  "$version" = int 100000/' 'malformed-keyed: the archive holds $version twice'
bad notop 's/^  "\$top" = dict/  "$tip" = dict/' 'malformed-keyed: the archive holds the key $tip'
bad noversion 's/^  "\$version" = int 100000$//' 'malformed-keyed: the archive has no $version'
awk '/^  "\$top" = dict 2$/ { print "  \"$top\" = int 1"; getline; getline; next } { print }' "$T/v.plist" > "$T/topdict.plist"
written topdict 'malformed-keyed: $top is not a dict'
bad nonull 's/^    string "\$null"$/    string "$nul"/' 'malformed-keyed: $objects is not an array with $null first'
printf 'array 0\n' > "$T/notdict.plist"; written notdict 'malformed-keyed: the top object is a plist array, not a dict'
bad pastend 's/^      "NSRoot" = uid 2$/      "NSRoot" = uid 99999/' "malformed-keyed: \$objects[1] NSRoot: uid 99999 is past the last object, $last"
bad classref "s/^      \"NSRoot\" = uid 2\$/      \"NSRoot\" = uid $cls/" "malformed-keyed: \$objects[1] NSRoot: uid $cls names a class entry"
bad classnot 's/^      "\$class" = uid [0-9]*$/      "$class" = uid 2/' 'malformed-keyed: $objects[1]: $class is not the uid of a class entry'
once neither '      "$classname" = string "NSCustomObject"' '      "$classnome" = string "NSCustomObject"' \
  "malformed-keyed: \$objects[$cls] is a dict with neither \$class nor \$classname"
once nullobj '    string "NSObject"' '    null' "malformed-keyed: \$objects[$str] is a plist null"
once arrobj '    string "NSObject"' '    array 0' "malformed-keyed: \$objects[$str] is a plist array"
once uidobj '    string "NSObject"' '    uid 1' "malformed-keyed: \$objects[$str] is a plist uid"
awk '!done && /^      "\$classes" = array/ { print "      \"$classhintz\" = array 0"; done = 1 } { print }' "$T/v.plist" > "$T/classkey.plist"
written classkey "malformed-keyed: \$objects[$cls]: a class entry holds \$classhintz"
hints() {  # NAME WHAT LINE...: the first class entry gains $classhints, the plist lines given; WHAT is the refusal
  n=$1 w=$2; shift 2
  H=$(printf '%s\n' "$@") awk '!done && /^      "\$classes" = array/ { print ENVIRON["H"]; done = 1 } { print }' \
    "$T/v.plist" > "$T/$n.plist"
  written "$n" "$w"
}
hints hintsempty "malformed-keyed: \$objects[$cls]: \$classhints is empty" '      "$classhints" = array 0'
hints hintstype "malformed-keyed: \$objects[$cls]: \$classhints holds a plist int" '      "$classhints" = array 1' '        int 1'
hints hintsstr "malformed-keyed: \$objects[$cls]: a class entry holds \$classhints" '      "$classhints" = string "NSView"'
hints hintstwice "malformed-keyed: \$objects[$cls]: a class entry holds \$classhints" '      "$classhints" = array 1' \
  '        string "NSView"' '      "$classhints" = array 1' '        string "NSView"'
awk '!done && /^      "\$classes" = array/ { print "      \"$classhints\" = array 2\n        string \"NSLayoutConstraint\"\n        string \"a b\""; done = 1 } { print }' \
  "$T/v.plist" > "$T/hinted.plist"
run plist "$T/hinted.plist" > "$T/hinted.nib" && run read "$T/hinted.nib" > "$T/hinted.rez" 2>"$T/err" \
  && grep -q '^chain NSCustomObject : NSObject hints NSLayoutConstraint "a b"$' "$T/hinted.rez" \
  && run build "$T/hinted.rez" > "$T/hinted2.nib" 2>"$T/err" && run read "$T/hinted2.nib" > "$T/hinted2.rez" 2>"$T/err" \
  && cmp -s "$T/hinted.rez" "$T/hinted2.rez" \
  && "$B" dump "$T/hinted2.nib" | grep -A3 '"\$classhints" = array 2' | grep -q 'string "a b"' \
  && pass "keyed_hints: \$classhints, as IB writes for NSIBPrototypingLayoutConstraint, reads, dumps and builds back" \
  || fail "keyed_hints: $(err) $(grep '^chain NSCustomObject' "$T/hinted.rez") $(diff "$T/hinted.rez" "$T/hinted2.rez" | head -4)"
awk '!done && /^      "\$classes" = array/ { print; getline; print "        string \"Other\""; done = 1; next } { print }' "$T/v.plist" > "$T/classfirst.plist"
written classfirst "malformed-keyed: \$objects[$cls]: \$classes does not start with NSCustomObject"
awk '!done && /^      "\$classes" = array/ { print; getline; print "        int 1"; done = 1; next } { print }' "$T/v.plist" > "$T/classtype.plist"
written classtype "malformed-keyed: \$objects[$cls]: \$classes holds a plist int"
awk '!done && /^      "\$classes" = array/ { print "      \"$classes\" = array 0"; done = 1; skip = 1; next }
     skip && /^        / { next } { skip = 0; print }' "$T/v.plist" > "$T/classempty.plist"
written classempty "malformed-keyed: \$objects[$cls]: a class entry needs \$classname and \$classes"
first=$(awk '/"\$classname" = string/ { print $NF; exit }' "$T/v.plist")
second=$(awk '/"\$classname" = string/ { if (++n == 2) { print $NF; exit } }' "$T/v.plist")
bad classtwice "s/^      \"\\\$classname\" = string $second\$/      \"\$classname\" = string $first/; s/^        string $second\$/        string $first/" \
  "malformed-keyed: the class $(echo "$first" | tr -d '"') has two entries"
awk '!done && /^        uid / { sub(/uid/, "int"); done = 1 } { print }' "$T/v.plist" > "$T/nonuid.plist"
written nonuid "malformed-keyed: \$objects[$arr] NS.objects: an array holding a plist int, not only uids"
awk '!done && /^        uid / { $0 = "        uid 99999"; done = 1 } { print }' "$T/v.plist" > "$T/arrpast.plist"
written arrpast "malformed-keyed: \$objects[$arr] NS.objects: uid 99999 is past the last object, $last"
bad dupkey 's/^      "NSRoot" = uid 2$/      "NSRoot" = uid 2\
      "NSRoot" = uid 2/' 'malformed-keyed: $objects[1] holds the key NSRoot twice'
bad nested 's/^      "NSRoot" = uid 2$/      "NSRoot" = dict 0/' 'malformed-keyed: $objects[1] NSRoot: a plist dict as a value'
bad nullval 's/^      "NSRoot" = uid 2$/      "NSRoot" = null/' 'malformed-keyed: $objects[1] NSRoot: a plist null as a value'
patch() {  # NAME FROM TO: a copy of $T/NAME.nib with the one occurrence of the string FROM changed to TO, as bytes
  hex=$(od -An -v -tx1 "$T/$1.nib" | tr -d ' \n')
  at=$(printf '%s' "$2" | od -An -v -tx1 | tr -d ' \n' | awk -v h="$hex" '{ i = index(h, $0); print i ? (i - 1) / 2 : -1 }')
  [ "$at" -ge 0 ] && printf "$3" | dd of="$T/$1.nib" bs=1 seek="$at" conv=notrunc 2>/dev/null
}
sed 's/^        string "NSLayoutConstraint"$/        string "NSLayoutConstrainZ"/' "$T/hinted.plist" > "$T/nulhint.plist"
run plist "$T/nulhint.plist" > "$T/nulhint.nib" && patch nulhint NSLayoutConstrainZ 'NSLayoutConstrain\000' \
  && malformed nulhint "malformed-keyed: \$objects[$cls]: \$classhints holds a name with a NUL"
sed 's/^      "NSRoot" = uid 2$/      "NSRooZ" = uid 2/' "$T/v.plist" > "$T/nulkey.plist"
run plist "$T/nulkey.plist" > "$T/nulkey.nib" && patch nulkey NSRooZ 'NSRoo\000' && malformed nulkey 'malformed-keyed: a key holds a NUL'
sed 's/^      "\$classname" = string "NSCustomObject"$/      "$classname" = string "NSCustomObjecZ"/; s/^        string "NSCustomObject"$/        string "NSCustomObjecZ"/' \
  "$T/v.plist" > "$T/nulclass.plist"
run plist "$T/nulclass.plist" > "$T/nulclass.nib" && patch nulclass NSCustomObjecZ 'NSCustomObjec\000' \
  && malformed nulclass 'malformed-keyed: a class name holds a NUL'
head -c 100 "$FIX/nib-10.9/values.nib/keyedobjects.nib" > "$T/short.nib"
run read "$T/short.nib" > "$T/out" 2>"$T/err"; rc=$?
case "$rc:$(err)" in "4:malformed-bplist: "*) pass "keyed_malformed: a truncated archive is a malformed bplist" ;;
  *) fail "keyed_malformed: truncated: exit $rc, $(err)" ;; esac
for what in bare value chain; do
  run shared "$what" 10 100 > "$T/ok.nib" 2>"$T/err" && run read "$T/ok.nib" > /dev/null 2>"$T/err" \
    || fail "keyed_shared: a little $what sharing is refused: $(err)"
  run shared "$what" 4000 65536 > "$T/$what.nib" 2>"$T/err" || fail "keyed_shared: shared $what: $(err)"
  [ "$(wc -c < "$T/$what.nib" | tr -d ' ')" -lt 200000 ] || fail "keyed_shared: $what.nib is not small"
  malformed "$what" "malformed-keyed: values shared so often that copying them would pass $((16 * $(wc -c < "$T/$what.nib" | tr -d ' ') + 1048576)) bytes"
done

cli() {  # NAME RC ERR-PATTERN ARG...
  name=$1 want=$2 pat=$3; shift 3
  "$R" "$@" > "$T/out" 2>"$T/err"; rc=$?
  case "$rc:$(sed -n 1p "$T/err")" in
    "$want:"$pat) pass "keyed_cli: $name" ;;
    *) fail "keyed_cli: $name: wanted exit $want and '$pat', got exit $rc, '$(sed -n 1p "$T/err")'" ;;
  esac
}
USAGE='usage: drydock-resources check|convert|dump|build *'
cli "build needs -o" 2 "$USAGE" build "$T/small.rez"
cli "build needs one text" 2 "$USAGE" build "$T/small.rez" "$T/small.rez" -o "$T/x.nib"
cli "-o needs a path" 2 "$USAGE" build "$T/small.rez" -o
cli "-o twice" 2 "$USAGE" build "$T/small.rez" -o "$T/x.nib" -o "$T/y.nib"
cli "--no-adapt is build's" 2 "$USAGE" dump --no-adapt "$FIX/nib/values.nib"
cli "-o is build's" 2 "$USAGE" dump -o "$T/x.nib" "$FIX/nib/values.nib"
cli "--no-adapt=RULE" 0 '' build --resource-references "$ROOT/reference/resources" --no-adapt=wrapping-width "$T/small.rez" -o "$T/x.nib"
cli "--target 10.9" 0 '' build --target 10.9 --no-adapt "$T/small.rez" -o "$T/x.nib"
cmp -s "$T/x.nib" "$T/small.nib" && pass "keyed_cli: build writes the driver's bytes" || fail "keyed_cli: build's output differs"
cli "build over its own input" 2 "*small.rez: the output is the input; refusing to write it" build --no-adapt "$T/small.rez" -o "$T/small.rez"
printf 'drydock-resources dump 1\nformat keyed\n@0 NSObject\n  x = i8 300\n' > "$T/baddump.rez"
cli "a malformed dump" 4 "drydock-resources: $T/baddump.rez: malformed-dump: line 4: i8 300 is out of range" build --no-adapt "$T/baddump.rez" -o "$T/bad.nib"
[ -e "$T/bad.nib" ] && fail "keyed_cli: a malformed dump wrote its output" || pass "keyed_cli: a malformed dump writes nothing"
cli "a missing dump" 4 "drydock-resources: $T/missing.rez: cannot read: *" build --no-adapt "$T/missing.rez" -o "$T/bad.nib"
cli "an unwritable output" 4 "*" build --no-adapt "$T/small.rez" -o "$T/no/such/dir/x.nib"
cli "dump of a keyed nib" 0 '' dump "$FIX/nib-10.9/values.nib"
grep -q '^format keyed$' "$T/out" && pass "keyed_cli: a nib directory's keyed archive dumps as keyed" || fail "keyed_cli: keyed dump: $(head -2 "$T/out")"
cli "dump of a malformed keyed nib" 4 "drydock-resources: $T/pastend.nib: malformed-keyed: \$objects\[1\] NSRoot: uid 99999 is past the last object, *" dump "$T/pastend.nib"
[ -s "$T/out" ] && fail "keyed_cli: a malformed keyed nib printed a dump" || pass "keyed_cli: a malformed keyed nib prints nothing"

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
