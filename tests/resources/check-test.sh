#!/bin/sh
# platform: host-agnostic -- checks scratch bundles of committed nibs against the committed reference data
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
R=$DRYDOCK_RESOURCES
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
T=$(mktemp -d "${TMPDIR:-/tmp}/check-test.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
refs() { echo --references "$ROOT/reference/objc" --resource-references "$ROOT/reference/resources"; }
run() {  # OUT VERB ARG...: drydock-resources VERB ARG..., stdout in $T/OUT, stderr in $T/OUT.err, status in $T/OUT.rc
  out=$1 verb=$2; shift 2
  "$R" "$verb" $(refs) "$@" > "$T/$out" 2>"$T/$out.err"; echo $? > "$T/$out.rc"
}
rc() { cat "$T/$1.rc"; }
err() { head -3 "$T/$1.err"; }

B=$T/app.app/Contents/Resources
mkdir -p "$B/Base.lproj" "$B/en.lproj"
cp "$FIX/nib/layout.nib" "$B/Base.lproj/layout.nib"
cp "$FIX/nib/values.nib" "$B/en.lproj/values.nib"
cp -R "$FIX/nib/Main.storyboardc" "$B/Base.lproj/"
cp -R "$FIX/nib-10.9/collections.nib" "$B/Base.lproj/"
mkdir -p "$T/outside/far.nib"
cp "$FIX/nib/layout.nib" "$T/outside/far.nib/keyedobjects.nib"
cp "$FIX/nib/layout.nib" "$T/outside/near.nib"
ln -s "$T/outside" "$B/linked"
ln -s "$T/outside/near.nib" "$B/Base.lproj/linked.nib"
ln -s .. "$B/en.lproj/loop"
snapshot() { (cd "$1" && find . \( -type f -o -type l \) -exec cksum {} \; 2>/dev/null | sort); }
snapshot "$B" > "$T/before"

cd "$T" || exit 1
run one check --report "$T/one.json" "$T/app.app"
run two check --report "$T/two.json" "$T/app.app"
[ "$(rc one)" = 1 ] && [ -s "$T/one.json" ] && cmp -s "$T/one.json" "$T/two.json" && cmp -s "$T/one" "$T/two" \
  && pass "check_report_bytes: two checks of a bundle give the same report, byte for byte" \
  || fail "check_report_bytes: exit $(rc one), $(err one) $(cmp "$T/one.json" "$T/two.json")"
[ "$(grep -c "$PWD" "$T/one.json")" = 0 ] && [ "$(grep -c "$T" "$T/one.json")" = 0 ] && [ "$(grep -c "$ROOT" "$T/one.json")" = 0 ] \
  && pass "check_report_bytes: the report has no absolute path" || fail "check_report_bytes: $(grep -o "\"$T[^\"]*\"" "$T/one.json" | head -2)"
snapshot "$B" > "$T/after"
cmp -s "$T/before" "$T/after" && [ "$(ls "$T" | grep -c '\.json$')" = 2 ] \
  && pass "check: writes nothing but the report" || fail "check: the bundle changed: $(diff "$T/before" "$T/after" | head -2)"
head -c 200 "$T/one.json" | grep -q '^{"schema":1,"kind":"drydock-resources-report","tool":"drydock-resources [^"]*","verb":"check","target":"10.9","strict":true,"adapt":\["translate-autoresizing","wrapping-width"\],"nibs":\[$' \
  && grep -q '^ {"kind":"[^"]*","nib":"[^"]*","item":"[^"]*","detail":"[^"]*","severity":"[a-z-]*","deviation":null}' "$T/one.json" \
  && grep -q '\],"findings":\[$' "$T/one.json" && grep -q '\],"exceptions":\[\]}$' "$T/one.json" \
  && pass "check_report_bytes: the report's keys come in the documented order" || fail "check_report_bytes: key order: $(head -c 300 "$T/one.json")"
TAB=$(printf '\t')
sed -n "s/^ {\"kind\":\"\([^\"]*\)\",\"nib\":\"\([^\"]*\)\",\"item\":\"\([^\"]*\)\",\"detail\":\"\([^\"]*\)\".*/\2$TAB\1$TAB\3$TAB\4/p" "$T/one.json" > "$T/order"
sort -c -t "$TAB" -k1,1 -k2,2 -k3,3 -k4,4 "$T/order" 2>/dev/null && [ "$(wc -l < "$T/order")" -ge 10 ] \
  && pass "check_report_bytes: findings are sorted by nib, kind, item and detail" || fail "check_report_bytes: unsorted: $(sort -c -t "$TAB" -k1,1 -k2,2 -k3,3 -k4,4 "$T/order" 2>&1)"
sed -n 's/^ {"path":"\([^"]*\)".*/\1/p' "$T/one.json" > "$T/paths"
printf '%s\n' Contents/Resources/Base.lproj/Main.storyboardc/DDFixtureScene.nib \
  Contents/Resources/Base.lproj/Main.storyboardc/Svc-aa-001-view-Svw-aa-003.nib \
  Contents/Resources/Base.lproj/collections.nib/keyedobjects.nib Contents/Resources/Base.lproj/layout.nib \
  Contents/Resources/en.lproj/values.nib > "$T/want"
cmp -s "$T/paths" "$T/want" \
  && pass "check: the walk finds nib files, nib directories' keyedobjects.nib and storyboard nibs, sorted bytewise, following no symbolic link" \
  || fail "check: walk: $(diff "$T/want" "$T/paths" | tr '\n' '|')"
grep -q '"path":"Contents/Resources/Base.lproj/collections.nib/keyedobjects.nib","format":"keyed","sha256_in":"[0-9a-f]\{64\}","sha256_out":null,"written":false' "$T/one.json" \
  && pass "check: a keyed nib is listed as keyed, nothing built" || fail "check: keyed entry: $(grep collections "$T/one.json" | head -1)"

run noreport check "$T/app.app"
cmp -s "$T/one" "$T/noreport" && [ "$(rc noreport)" = 1 ] \
  && pass "check: without --report it prints the same findings" || fail "check: no report: exit $(rc noreport)"
run taken check --report "$T/one.json" "$T/app.app"
[ "$(rc taken)" = 2 ] && cmp -s "$T/one.json" "$T/two.json" && grep -q 'already exists' "$T/taken.err" \
  && pass "check: an existing report is refused, exit 2, and left as it was" || fail "check: taken: exit $(rc taken), $(err taken)"
run nodir check --report "$T/no/such/dir.json" "$T/app.app"
[ "$(rc nodir)" = 2 ] && pass "check: a report in a missing directory is refused, exit 2" || fail "check: no dir: exit $(rc nodir)"
run strictness check --no-strict "$T/app.app"
[ "$(rc strictness)" = 2 ] && pass "check: --no-strict is convert's alone, exit 2" || fail "check: --no-strict: exit $(rc strictness)"
mkdir "$T/locked" && cp "$FIX/nib/layout.nib" "$T/locked/" && cp "$FIX/nib/values.nib" "$T/locked/" && chmod 000 "$T/locked/layout.nib"
if [ "$(id -u)" != 0 ]; then
  run unreadable check --report "$T/unreadable.json" "$T/locked"
  [ "$(rc unreadable)" = 4 ] && grep -q 'layout.nib: cannot read' "$T/unreadable.err" \
    && grep -q '"path":"layout.nib","format":null,"sha256_in":null' "$T/unreadable.json" \
    && grep -q '^values.nib: finding: unresolved-chain DDFixtureView ' "$T/unreadable" \
    && pass "check: a nib that cannot be read exits 4, its report entry empty, and the next nib is still checked" \
    || fail "check: unreadable: exit $(rc unreadable), $(err unreadable)"
fi
chmod 644 "$T/locked/layout.nib"

mkdir "$T/quoted" && cp "$FIX/nib/layout.nib" "$T/quoted/a\"b\\c.nib"
run q check --report "$T/q.json" "$T/quoted"
grep -q '"path":"a\\"b\\\\c.nib"' "$T/q.json" && grep -q '"nib":"a\\"b\\\\c.nib"' "$T/q.json" \
  && pass "check_report_bytes: a quote and a backslash in a nib's name are escaped in the report" \
  || fail "check_report_bytes: escapes: exit $(rc q), $(err q), $(head -c 300 "$T/q.json")"

printf '*.nib\tnamed-color-missing\tlabelColor\t10.9 draws it opaque black\n' > "$T/lc"
run convert convert --exceptions "$T/lc" "$T/app.app/Contents/Resources/Base.lproj/layout.nib"
run idem check --exceptions "$T/lc" --report "$T/idem.json" "$T/app.app/Contents/Resources/Base.lproj/layout.nib"
[ "$(rc convert)" = 0 ] && [ "$(rc idem)" = 0 ] && ! grep -q nibarchive-format "$T/idem" "$T/idem.json" \
  && [ "$(wc -l < "$T/idem" | tr -d ' ')" = 1 ] && grep -q ': finding: named-color-missing labelColor (10.10) accepted as named-color-missing:labelColor$' "$T/idem" \
  && pass "check_idempotent: check of convert's output exits 0, with no nibarchive-format and nothing but the accepted labelColor" \
  || fail "check_idempotent: convert $(rc convert), check $(rc idem): $(head -3 "$T/idem") $(err idem)"
grep -q '"path":"Contents/Resources/Base.lproj/layout.nib","format":"keyed"' "$T/idem.json" \
  && pass "check: a lone nib inside a bundle is named relative to the bundle" || fail "check: relpath: $(grep '"path"' "$T/idem.json")"

"$R" dump "$FIX/nib-10.9/int64.nib/keyedobjects.nib" > "$T/int64.rez" 2>"$T/int64.err"
sed -e 's/^@16 NSView$/@16 NSGridView/' -e 's/^chain NSIBObjectData : NSObject$/chain NSGridView : NSView : NSResponder : NSObject\
&/' "$T/int64.rez" > "$T/grid.rez"
[ "$(grep -c -e '^@16 NSGridView$' -e '^chain NSGridView : ' "$T/grid.rez")" = 2 ] || fail "check_keyed_newer: setup: $(head -3 "$T/int64.err")"
"$R" build --no-adapt "$T/grid.rez" -o "$T/grid.nib" 2>"$T/grid.err" || fail "check_keyed_newer: setup: build: $(head -3 "$T/grid.err")"
for f in grid.rez grid.nib; do
  run "c-$f" check "$T/$f"
  [ "$(rc "c-$f")" = 1 ] && grep -q "^$f: finding: class-missing NSGridView (10.12)\$" "$T/c-$f" \
    && ! grep -q 'class-missing NS[A-FH-Z]' "$T/c-$f" \
    && pass "check_keyed_newer: a keyed $f using a class 10.9 lacks is class-missing, with the version that added it" \
    || fail "check_keyed_newer: $f: exit $(rc "c-$f"), $(grep class-missing "$T/c-$f") $(err "c-$f")"
done
"$R" dump --references "$ROOT/reference/objc" "$T/grid.nib" > "$T/grid.dump" 2>"$T/grid.err"
grep -q '^chain NSGridView : NSView : NSResponder : NSObject newer 10.12$' "$T/grid.dump" \
  && grep -q '^chain NSButton : NSControl : NSView : NSResponder : NSObject$' "$T/grid.dump" \
  && pass "check_keyed_newer: a keyed nib's dump marks the archive's own chain newer from --references" \
  || fail "check_keyed_newer: dump: $(grep '^chain NS[GV]' "$T/grid.dump") $(head -2 "$T/grid.err")"

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
