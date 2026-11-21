#!/bin/sh
# platform: macOS-only -- runs the built drydock-objc on codex-cli 0.165.0's native x86_64 build, a maintainer test
#       (it needs codex's repro set and the inputs its build used; it skips with exit 77 where any is absent).
# spec: src/objc/attest.c objc_attest_window -- an int32 in aws-lc's edwards25519 table, inside code at
#       0x10da61141, lands on _method_getName's lazy pointer 0x10feff070. Without the link map and the object
#       files the sweep refuses there; with them the window is attested and the refusal is gone.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
skip() { echo "SKIP objc_attest_codex: $*"; exit 77; }
fail() { echo "FAIL: $*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }

R=$HOME/Library/Caches/mm-build/codex-native-sweep-repro
[ -d "$R" ] || skip "$R is absent"
# spec: codex-cli build/objc-build-evidence.sh -- the strict run's inputs, beside the repro in mm-build.
MM=$(dirname "$R")
ART=$R/codex-native
MAP=$R/objc-native/linkmaps/codex.map
SAVED=$R/objc-native/evidence/codex.json
for f in "$ART/codex" "$ART/build-manifest" "$MAP" "$SAVED"; do [ -f "$f" ] || skip "$f is absent"; done
[ -d "$R/deps" ] || skip "$R/deps is absent"
field() { sed -n "s/^$1=//p" "$ART/build-manifest"; }
SOURCE=$MM/codex-src
CRATES=$(field crate_sources)
PREFIX=$MM/recaulk-$(field recaulk_version)
ARCHIVE=$PREFIX/lib/librecaulk-objc.a
[ -d "$SOURCE/codex-rs" ] || skip "no prepared source at $SOURCE"
[ -n "$CRATES" ] && [ -d "$CRATES" ] || skip "no crate sources at '$CRATES'"
[ -f "$ARCHIVE" ] && [ "$(sha "$ARCHIVE")" = "$(field recaulk_archive_sha256)" ] || skip "no provider at $PREFIX that codex linked"
RECEIPT=$PREFIX/share/recaulk/objc-source.receipt
[ -f "$RECEIPT" ] || skip "no source receipt at $RECEIPT"
. "$ROOT/build/msc.sh" || skip 'no shipyard for the pinned SDK'
SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64) || skip 'no pinned 10.9 SDK'

T=$(mktemp -d "${TMPDIR:-/tmp}/objc-attest-codex.XXXXXX")
trap 'rm -rf "$T"' EXIT
REF=$ROOT/reference/objc

EV=$SAVED
saved_map=$(tr -d ' \n' <"$SAVED" | sed -n 's/.*"link_map":{"sha256":"\([0-9a-f]*\)"}.*/\1/p')
if [ "$saved_map" = "$(sha "$MAP")" ]; then
  echo "objc-attest-codex: the saved evidence binds this link map; analyzing with it"
else
  echo "objc-attest-codex: the saved evidence binds no link map, or another; emitting fresh evidence"
  EV=$T/codex.json
  "$DRYDOCK_OBJC" evidence --artifact "$ART/codex" --prestrip "$ART/codex" --source-root "$SOURCE" \
    --link-map "$MAP" --provider-prefix "$PREFIX" --references "$REF" --output "$EV" 2>"$T/ev.err" ||
    { tail -5 "$T/ev.err" >&2; fail 'fresh evidence for codex'; }
fi

# analyze REPORT [OPTION VALUE]...: strict, with the inputs codex's build passed; rc set, stderr in REPORT.err.
analyze() {
  rep=$1; shift; rc=0
  "$DRYDOCK_OBJC" analyze --artifact "$ART/codex" --root "$ART" --references "$REF" --report "$rep" --mode strict \
    --build-evidence "$EV" --provider-prefix "$PREFIX" --source-receipt "$RECEIPT" --source-root "$SOURCE" \
    --crate-sources "$CRATES" --sdk-root "$SDK" "$@" 2>"$rep.err" || rc=$?
  case "$rc" in 0|1|4) ;; *) tail -5 "$rep.err" >&2; fail "analyze exits $rc" ;; esac
  [ -f "$rep" ] || fail "analyze exits $rc and writes no report"
}
refuses_at_table() {
  grep -F '{"code": "undecodable-objc-reference", "slice": "x86_64", "address": "0x10da61141", ' "$1" >/dev/null
}

analyze "$T/plain.json"
refuses_at_table "$T/plain.json" || fail 'without a link map and object files the sweep no longer refuses at 0x10da61141'

analyze "$T/attested.json" --link-map "$MAP" --object-dir "$R/deps"
if refuses_at_table "$T/attested.json"; then
  grep -F '"0x10da61141"' "$T/attested.json" >&2
  fail 'with the link map and object files the sweep still refuses at 0x10da61141'
fi
echo "objc-attest-codex: attested run exits $rc; its other findings, not judged here:"
cat "$T/attested.json.err"
echo "objc-attest-codex: codex's edwards25519 table at 0x10da61141 is attested, and refused without the inputs"
