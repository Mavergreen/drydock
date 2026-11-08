#!/bin/sh
# platform: macOS-only -- links an x86_64 fixture against the pinned 10.9 SDK, then runs drydock-objc on it
# spec: cli/drydock-objc.c header -- the defaults drydock-objc adds and nothing else: --references from the binary's
#       real path (an installed tree, and nothing else), --analyzer-id from the compiled-in
#       identity unless the caller names one, and usage (exit 2) for no subcommand or an unknown one.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
# spec: build/msc.sh -- SHIPYARD_SCRIPTS, where shipyard's fetchers are (CTest passes it; a standalone run finds it).
. "$ROOT/build/msc.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-cli-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixture away from the pinned SDK.
env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 \
  "$FX/plain.c" -o "$T/plain" || fail 'plain.c did not build'
mkdir -p "$T/root/bin" "$T/out"
cp "$T/plain" "$T/root/bin/plain"

# spec: cli/drydock-objc.c header -- no subcommand, or an unknown one: usage on stderr, exit 2.
rc=0; "$DRYDOCK_OBJC" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] && grep '^usage: drydock-objc' "$T/err" >/dev/null || fail "no subcommand: exit $rc, want 2 with usage"
rc=0; "$DRYDOCK_OBJC" frobnicate 2>"$T/err" || rc=$?
[ "$rc" = 2 ] && grep '^usage: drydock-objc' "$T/err" >/dev/null || fail "an unknown subcommand: exit $rc, want 2 with usage"
echo 'PASS: usage'

# spec: cli/drydock-objc.c header -- references_from_symlink: reached through a symlink in another directory, the
#       binary resolves its real path and finds share/drydock/objc/reference beside its own bin/.
mkdir -p "$T/inst/bin" "$T/inst/share/drydock/objc" "$T/link"
cp "$DRYDOCK_OBJC" "$T/inst/bin/drydock-objc"
cp -R "$REF" "$T/inst/share/drydock/objc/reference"
ln -s "$T/inst/bin/drydock-objc" "$T/link/drydock-objc"
rc=0; "$T/link/drydock-objc" analyze --artifact "$T/root/bin/plain" --root "$T/root" --report "$T/out/symlink" --mode strict 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "references_from_symlink: exit $rc, want 0"
grep -F '"manifest_sha256"' "$T/out/symlink" >/dev/null || fail 'references_from_symlink: the report names no reference manifest'
# spec: cli/drydock-objc.c header -- it is the installed set that is read, not the source tree's: a tampered copy is
#       cannot-measure.
printf 'class\tAppKit\tNSFake\t-\tNSObject\t-\t-\t-\t0\tx.h:1\t-\n' >>"$T/inst/share/drydock/objc/reference/floor-sdk.tsv"
rc=0; "$T/link/drydock-objc" analyze --artifact "$T/root/bin/plain" --root "$T/root" --report "$T/out/symlink-tampered" --mode strict 2>"$T/err" || rc=$?
[ "$rc" = 4 ] && grep '"code": "reference-hash-mismatch"' "$T/out/symlink-tampered" >/dev/null ||
  fail "references_from_symlink: exit $rc with the installed set tampered, want 4 (reference-hash-mismatch)"
echo 'PASS: references_from_symlink'

# spec: cli/drydock-objc.c header -- no_shipped_references: a copy with no share/drydock/objc/reference beside it, and no
#       --references, falls back to nothing; main.m refuses the missing option and writes no report.
mkdir -p "$T/bare/bin"
cp "$DRYDOCK_OBJC" "$T/bare/bin/drydock-objc"
rc=0; "$T/bare/bin/drydock-objc" analyze --artifact "$T/root/bin/plain" --root "$T/root" --report "$T/out/bare" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] || fail "no_shipped_references: exit $rc, want 2"
grep -F -- --references "$T/err" >/dev/null || fail 'no_shipped_references: the refusal does not name --references'
[ ! -e "$T/out/bare" ] || fail 'no_shipped_references: a report was written'
rc=0; "$T/bare/bin/drydock-objc" evidence --artifact "$T/root/bin/plain" --prestrip "$T/root/bin/plain" --source-root "$FX" \
  --output "$T/out/bare-ev" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] && [ ! -e "$T/out/bare-ev" ] || fail "no_shipped_references: evidence exit $rc, want 2 and no output"
echo 'PASS: no_shipped_references'

# spec: cli/drydock-objc.c header -- analyzer_id_override: an explicit --analyzer-id is the one the report names.
rc=0; "$DRYDOCK_OBJC" analyze --artifact "$T/root/bin/plain" --root "$T/root" --references "$REF" --report "$T/out/override" \
  --analyzer-id X 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "analyzer_id_override: exit $rc, want 0"
grep '"analyzer": "X"' "$T/out/override" >/dev/null || fail 'analyzer_id_override: the report does not name X'
echo 'PASS: analyzer_id_override'

# spec: cli/drydock-objc.c header -- default_id: without one, the report names exactly DRYDOCK_OBJC_ANALYZER_ID, the id
#       CMakeLists.txt computed (drydock-VERSION-objc-src- and 16 hex), which CTest passes.
: "${DRYDOCK_OBJC_ANALYZER_ID:?names the analyzer id CMakeLists.txt computed (CTest sets it)}"
printf '%s\n' "$DRYDOCK_OBJC_ANALYZER_ID" | grep -E '^drydock-[0-9]+\.[0-9]+\.[0-9]+[^ ]*-objc-src-[0-9a-f]{16}$' >/dev/null ||
  fail "default_id: DRYDOCK_OBJC_ANALYZER_ID is $DRYDOCK_OBJC_ANALYZER_ID, not drydock-VERSION-objc-src- and 16 hex"
rc=0; "$DRYDOCK_OBJC" analyze --artifact "$T/root/bin/plain" --root "$T/root" --references "$REF" --report "$T/out/default" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "default_id: exit $rc, want 0"
grep -F "\"analyzer\": \"$DRYDOCK_OBJC_ANALYZER_ID\"" "$T/out/default" >/dev/null ||
  fail "default_id: the report names $(grep -o '"analyzer": "[^"]*"' "$T/out/default")"
echo 'PASS: default_id'
echo 'objc-cli: usage, references_from_symlink, no_shipped_references, analyzer_id_override and default_id pass'
