#!/bin/sh
# platform: host-agnostic -- runs drydock-resources on committed nibs, and a copy of it under a made-up prefix
set -u
: "${DRYDOCK_RESOURCES:?names the built drydock-resources (CTest sets it)}"
R=$DRYDOCK_RESOURCES
LC_ALL=C; export LC_ALL
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIX=$ROOT/tests/resources/fixtures
T=$(mktemp -d "${TMPDIR:-/tmp}/cli-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; echo "$1" >> "$T/failed"; }
exits() {  # NAME RC ERR-PATTERN ARG...: drydock-resources ARG... exits RC with stderr's first line matching ERR-PATTERN
  name=$1 want=$2 pat=$3; shift 3
  "$R" "$@" > "$T/out" 2>"$T/err"; rc=$?
  first=$(sed -n 1p "$T/err")
  case "$rc:$first" in
    "$want:"$pat) pass "$name: exit $rc, '$first'" ;;
    *) fail "$name: wanted exit $want and '$pat', got exit $rc, '$first'" ;;
  esac
}
USAGE='usage: drydock-resources check|convert|dump|build *'
exits cli_usage 2 "$USAGE"
exits cli_usage 2 "$USAGE" frobnicate
exits cli_usage 2 "$USAGE" dump
exits cli_usage 2 "$USAGE" dump a.nib b.nib
exits cli_usage 2 "$USAGE" dump --frob
exits cli_usage 2 "$USAGE" dump --references
exits cli_target 2 'drydock-resources: unsupported target: 10.6' dump --target 10.6 "$FIX/nib/values.nib"
exits cli_target 2 'drydock-resources: unsupported target: 10.6' check --target 10.6 "$FIX/nib/values.nib"
exits cli_target 2 'drydock-resources: unsupported target: 10.6' convert --target 10.6 "$FIX/nib/values.nib"
exits cli_target 2 'drydock-resources: unsupported target: 10.6' build --target 10.6 x.txt
exits cli_target 0 '' dump --target 10.9 "$FIX/nib/values.nib"
[ -s "$T/out" ] && pass "cli_target: --target 10.9 dumps" || fail "cli_target: --target 10.9 printed nothing"
exits cli_dump 4 "drydock-resources: *: unsupported format" dump "$FIX/MANIFEST.tsv"
[ -s "$T/out" ] && fail "cli_dump: an unsupported format printed a dump" || pass "cli_dump: an unsupported format prints nothing"
exits cli_dump 4 "drydock-resources: *Info.plist: malformed-keyed: the archive holds the key *" dump "$FIX/nib/Main.storyboardc/Info.plist"
[ -s "$T/out" ] && fail "cli_dump: a plist that is no keyed archive printed a dump" || pass "cli_dump: a plist that is no keyed archive prints nothing"
exits cli_dump 4 "drydock-resources: *: cannot read: *" dump "$T/missing.nib"
head -c 60 "$FIX/nib/values.nib" > "$T/short.nib"
exits cli_dump 4 "drydock-resources: *: malformed-nibarchive: * at *" dump "$T/short.nib"
exits cli_dump 4 "drydock-resources: cannot read the references in $T/none" dump --references "$T/none" "$FIX/nib/values.nib"

le32() { printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)))"; }
{ printf 'NIBArchive'; le32 1; le32 10; le32 1; le32 50; le32 1; le32 53; le32 1; le32 300056; le32 1; le32 300058
  printf '\200\200\201\140\047\222'; head -c 300000 /dev/zero | tr '\000' '\001'; printf '\200\011\211\200NSObject\000'; } > "$T/longkey.nib"
[ "$(wc -c < "$T/longkey.nib" | tr -d ' ')" = 300069 ] || fail "cli_dump: longkey.nib is not 300069 bytes"
exits cli_dump 4 "drydock-resources: *longkey.nib: a name too long to dump: line * would be longer than 1048576 bytes" dump "$T/longkey.nib"
[ -s "$T/out" ] && fail "cli_dump: an over-long name printed a dump" || pass "cli_dump: an over-long name refuses at dump, printing nothing"
mkdir "$T/dir.nib" && cp "$FIX/nib/values.nib" "$T/dir.nib/keyedobjects.nib"
"$R" dump "$T/dir.nib" > "$T/dir.rez" 2>"$T/err" && "$R" dump "$FIX/nib/values.nib" > "$T/file.rez" \
  && cmp -s "$T/dir.rez" "$T/file.rez" && pass "cli_dump: a nib directory dumps its keyedobjects.nib" \
  || fail "cli_dump: a nib directory: $(cat "$T/err")"

mkdir -p "$T/prefix/bin" && cp "$R" "$T/prefix/bin/drydock-resources" && chmod +x "$T/prefix/bin/drydock-resources"
"$T/prefix/bin/drydock-resources" dump "$FIX/nib/layout.nib" > "$T/bare.rez" 2>"$T/err" || fail "cli_references: exit $?: $(cat "$T/err")"
grep -q '^chain NSObject ?$' "$T/bare.rez" && grep -q '^chain NSTextField ?$' "$T/bare.rez" \
  && pass "cli_references: with no reference set beside it, chains are unresolved" \
  || fail "cli_references: with no reference set, chains are: $(grep '^chain' "$T/bare.rez" | head -3)"
grep -q '^chain IBClassReference : NSObject$' "$T/bare.rez" \
  && pass "cli_references: an object's own IB* class is nib-internal with no reference set" \
  || fail "cli_references: IBClassReference is: $(grep '^chain IBClassReference' "$T/bare.rez")"
mkdir -p "$T/prefix/share/drydock/objc" && ln -s "$ROOT/reference/objc" "$T/prefix/share/drydock/objc/reference"
"$T/prefix/bin/drydock-resources" dump "$FIX/nib/layout.nib" > "$T/found.rez" 2>"$T/err" || fail "cli_references: exit $?: $(cat "$T/err")"
grep -q '^chain NSTextField : NSControl : NSView : NSResponder : NSObject$' "$T/found.rez" \
  && pass "cli_references: the reference set at ../../share/drydock/objc/reference resolves chains" \
  || fail "cli_references: with share/ beside it, chains are: $(grep '^chain' "$T/found.rez" | head -3)"
"$R" dump --references "$ROOT/reference/objc" "$FIX/nib/layout.nib" > "$T/explicit.rez" 2>"$T/err" \
  && cmp -s "$T/found.rez" "$T/explicit.rez" && pass "cli_references: --references gives the same dump" \
  || fail "cli_references: --references differs: $(cat "$T/err")"
"$T/prefix/bin/drydock-resources" dump --references "$T/none" "$FIX/nib/layout.nib" > /dev/null 2>&1 \
  && fail "cli_references: an unreadable --references fell back to the default" \
  || pass "cli_references: an unreadable --references is refused even with a default beside it"

[ -s "$T/failed" ] && { echo "$(wc -l < "$T/failed" | tr -d ' ') failed"; exit 1; }
echo "all passed"
