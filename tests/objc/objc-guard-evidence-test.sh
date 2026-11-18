#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then analyzes them with schema-2 evidence
# spec: src/objc/source-evidence.c header -- a schema-2 guard or R3 row closes a send only while every file
#       it cites hashes as recorded, its function is the send's resolved symbol, and (a guard) the guarded
#       sends classify.c measures in that function are exactly the ones it covers and the guard is measured.
#       Revision, patches and features are provenance: reported, never compared.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$ROOT/build/msc.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-guard-evidence-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@"; }
mkdir -p "$T/root/bin"
cc "$FX/guard-coverage.c" -o "$T/root/bin/gc" -lobjc -Wl,-U,_fixture_use
cc "$FX/r3.c" -o "$T/root/bin/r3" -lobjc
G="$T/root/bin/gc"
R3B="$T/root/bin/r3"

S="$T/src"
mkdir -p "$S/tui/src"
printf 'if !workspace.respondsToSelector(selector) { return false; }\n' >"$S/tui/src/system_motion.rs"
printf 'let d = obj.description();\n' >"$S/tui/src/run.rs"
MOTION=$(sha "$S/tui/src/system_motion.rs")
RUN=$(sha "$S/tui/src/run.rs")
STALE=0000000000000000000000000000000000000000000000000000000000000000
TREE=$("$DRYDOCK_OBJC" evidence --tree-digest-only --source-root "$S") || fail "--tree-digest-only: exit $?"
SEL=accessibilityDisplayShouldReduceMotion

CRATES='{"name": "objc2", "version": "0.6.3", "checksum": "c1", "disambiguator": "2WYrep5oUp8"}, {"name": "objc2_foundation", "version": "0.3.2", "checksum": "c2", "disambiguator": "dIImX2SWmg2"}'
# ev2 ARTIFACT OUT GUARDS POSITIONS: schema-2 evidence for ARTIFACT, built at a revision no record was reviewed at.
ev2() {
  cat >"$2" <<EOF
{"schema": 2, "kind": "objc-build-evidence",
 "artifact": {"path": "bin/x", "sha256": "$(sha "$1")"},
 "source": {"tree_sha256": "$TREE", "revision": "new-revision", "patches_sha256": "new-patches", "features": "new-features"},
 "crates": [$CRATES], "type_map": [], "type_evidence": [], "binding_receipt": [],
 "position_evidence": [$4],
 "guards": [$3]}
EOF
}
cite() { printf '{"cite": "%s", "sha256": "%s"}' "$1" "$2"; }
cover() { printf '{"selector": "%s", "count": %s}' "$1" "$2"; }
guard2() {  # guard2 ID SYMBOL-JSON SOURCES COVERS
  printf '{"id": "%s", "path": "fixture::f", %s"selector": "%s", "guard": "respondsToSelector:", "fallback": "returns 0", "sources": [%s], "covers": [%s], "provenance": {"revision": "old-revision", "patches_sha256": "old-patches", "features": "old-features"}, "review": {"status": "reviewed", "reviewer": "A. Reviewer", "reason": "NO falls back to 0"}}' \
    "$1" "$2" "$SEL" "$3" "$4"
}
sym() { printf '"symbol": "%s", ' "$1"; }
FNR=__RNvXs6_NtNtCs2WYrep5oUp8_5objc27runtime15protocol_objectINtB5_14ProtocolObjectDNtNtB7_8nsobject16NSObjectProtocolEL_ENtNtCs5hICDV8pRVn_4core3fmt5Debug3fmtCsdIImX2SWmg2_16objc2_foundation
pos2() {  # pos2 ID SYMBOL-JSON SOURCES
  printf '{"id": "%s", "path": "<objc2::runtime::protocol_object::ProtocolObject<dyn objc2::runtime::nsobject::NSObjectProtocol> as core::fmt::Debug>::fmt", %s"selectors": ["UTF8String"], "kind": "-", "class": "NSString", "position": {"form": "result", "selector": "description"}, "sources": [%s], "note": "description returns an NSString"}' "$1" "$2" "$3"
}
n=0
analyze() {  # analyze ARTIFACT EVIDENCE: rc, $T/report, $T/err
  n=$((n + 1))
  rc=0; "$DRYDOCK_OBJC" analyze --artifact "$1" --root "$T/root" --references "$REF" --report "$T/report.$n" \
    --mode strict --build-evidence "$2" --source-root "$S" 2>"$T/err" || rc=$?
  ln -sf "$T/report.$n" "$T/report"
}
codes() { sed -n 's/.*"code": "\([^"]*\)".*/\1/p' "$T/report" | sort -u | tr '\n' ' '; }
only() {  # only NAME CODE DETAIL...: exit 4, exactly CODE, one CODE error holding every DETAIL
  name=$1 code=$2; shift 2
  [ "$rc" = 4 ] || fail "$name: exit $rc, want 4"
  [ "$(codes)" = "$code " ] || fail "$name: errors '$(codes)', want '$code '"
  grep "\"code\": \"$code\"" "$T/report" >"$T/lines"
  for d in "$@"; do grep -F -- "$d" "$T/lines" >"$T/lines.next" || fail "$name: no $code detail with '$d'"; mv "$T/lines.next" "$T/lines"; done
}
verdicts() { grep "\"function\": \"$1\"" "$T/report" | grep "\"selector\": \"$2\"" | sed -n 's/.*"verdict": "\([^"]*\)".*/\1/p' | sort -u | tr '\n' ' '; }
want() {  # want NAME FUNCTION SELECTOR VERDICT [PROOF-FRAGMENT]...
  name=$1 fn=$2 sel=$3 v=$4; shift 4
  [ "$(verdicts "$fn" "$sel")" = "$v " ] || fail "$name: $fn $sel is '$(verdicts "$fn" "$sel")', want '$v '"
  for d in "$@"; do
    grep "\"function\": \"$fn\"" "$T/report" | grep "\"selector\": \"$sel\"" | grep -F -- "$d" >/dev/null ||
      fail "$name: $fn $sel proof lacks '$d'"
  done
}
clean() {  # clean NAME: no error; exit 1 only for the fixture's own unguarded send
  [ -z "$(codes)" ] || fail "$1: errors '$(codes)'"
  [ "$rc" = "${2:-1}" ] || fail "$1: exit $rc, want ${2:-1}"
}
MOTION_CITE=$(cite tree:tui/src/system_motion.rs "$MOTION")

# carries: built at another revision, patch series and features than the review, its sources unchanged and
# its guard measured: guarded, and the proof shows the provenance it was reviewed under.
ev2 "$G" "$T/ev-carries" "$(guard2 g-carries "$(sym _guarded)" "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-carries"
clean carries
want carries _guarded $SEL guarded 'guard record g-carries' "tree:tui/src/system_motion.rs sha256:$MOTION" \
  'old-revision' 'old-patches' 'old-features' 'not compared' 'reviewed by A. Reviewer'
grep -F '"unused_guard_records": []' "$T/report" >/dev/null || fail 'carries: the record was not used'

# source_changed: a cited file is not the one reviewed.
ev2 "$G" "$T/ev-changed" "$(guard2 g-changed "$(sym _guarded)" "$(cite tree:tui/src/system_motion.rs "$STALE")" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-changed"
only source_changed guard-source-changed g-changed "$STALE" "$MOTION"
want source_changed _guarded $SEL unresolved

# Two records on one send: one that no longer holds keeps the other from guarding it.
ev2 "$G" "$T/ev-pair" "$(guard2 g-good "$(sym _guarded)" "$MOTION_CITE" "$(cover $SEL 1)"), $(guard2 g-bad "$(sym _guarded)" "$(cite tree:tui/src/system_motion.rs "$STALE")" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-pair"
only pair guard-source-changed g-bad
want pair _guarded $SEL unresolved

# coverage_added: a second guarded send in a reviewed function is one nobody reviewed.
ev2 "$G" "$T/ev-added" "$(guard2 g-added "$(sym _guarded_twice)" "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-added"
only coverage_added guard-coverage-changed g-added _guarded_twice $SEL 'measures 2' 'covers 1'
want coverage_added _guarded_twice $SEL unresolved

# coverage_removed: fewer guarded sends than the review covers, or a covered selector gone.
ev2 "$G" "$T/ev-removed" "$(guard2 g-removed "$(sym _guarded)" "$MOTION_CITE" "$(cover $SEL 2)")" ''
analyze "$G" "$T/ev-removed"
only coverage_removed guard-coverage-changed g-removed _guarded 'measures 1' 'covers 2'
ev2 "$G" "$T/ev-gone-sel" "$(guard2 g-gone-sel "$(sym _guarded)" "$MOTION_CITE" "$(cover $SEL 1), $(cover isVoiceOverEnabled 1)")" ''
analyze "$G" "$T/ev-gone-sel"
only coverage_selector_removed guard-coverage-changed g-gone-sel isVoiceOverEnabled 'measures 0' 'covers 1'
# A cover that names another selector than the guarded one leaves the guarded send uncovered.
ev2 "$G" "$T/ev-other" "$(guard2 g-other "$(sym _guarded)" "$MOTION_CITE" "$(cover isVoiceOverEnabled 1)")" ''
analyze "$G" "$T/ev-other"
grep '"code": "guard-coverage-changed"' "$T/report" | grep -F g-other | grep -F $SEL >/dev/null ||
  fail "coverage_uncovered: errors '$(codes)'"

# Each copy of one generic instance is measured: a copy with another count is a coverage change.
ev2 "$G" "$T/ev-copies" "$(guard2 g-copies '"symbols": ["_guarded", "_guarded_twice"], ' "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-copies"
only copies guard-coverage-changed g-copies _guarded_twice 'measures 2'

# guard_gone: the binary no longer measures the guard: not guarded, as today, and the record goes unused.
ev2 "$G" "$T/ev-gone" "$(guard2 g-gone "$(sym _unguarded)" "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-gone"
clean guard_gone
want guard_gone _unguarded $SEL unsupported unguarded
grep -F '"unused_guard_records": ["g-gone"]' "$T/report" >/dev/null || fail 'guard_gone: g-gone not reported unused'

# unresolved: a record a send would use, with no resolved symbol.
ev2 "$G" "$T/ev-unresolved" "$(guard2 g-unresolved '' "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-unresolved"
only unresolved malformed-build-evidence g-unresolved fixture::f 'run drydock-objc resolve'

# R3: position_carries closes the send; position_source_changed refuses.
ev2 "$R3B" "$T/ev-pos" '' "$(pos2 p-carries "$(sym "$FNR")" "$(cite tree:tui/src/run.rs "$RUN")")"
analyze "$R3B" "$T/ev-pos"
[ -z "$(codes)" ] || fail "position_carries: errors '$(codes)'"
grep "\"function\": \"$FNR\"" "$T/report" | grep '"selector": "UTF8String"' | grep '"receiver_closure": "R3"' |
  grep -F 'R3 p-carries' | grep -F "tree:tui/src/run.rs sha256:$RUN" | grep -F 'description returns an NSString' >/dev/null ||
  fail 'position_carries: UTF8String was not closed by p-carries with its sources and note'
grep -F '"unused_position_evidence": []' "$T/report" >/dev/null || fail 'position_carries: the row was not used'
ev2 "$R3B" "$T/ev-pos-changed" '' "$(pos2 p-changed "$(sym "$FNR")" "$(cite tree:tui/src/run.rs "$STALE")")"
analyze "$R3B" "$T/ev-pos-changed"
only position_source_changed position-source-changed p-changed tui/src/run.rs "$STALE" "$RUN"
grep '"receiver_closure": "R3"' "$T/report" >/dev/null && fail 'position_source_changed: a send was closed'
ev2 "$R3B" "$T/ev-pos-unresolved" '' "$(pos2 p-unresolved '' "$(cite tree:tui/src/run.rs "$RUN")")"
analyze "$R3B" "$T/ev-pos-unresolved"
only position_unresolved malformed-build-evidence p-unresolved 'run drydock-objc resolve'
# A row's binary-side checks still hold: a class the floor does not know is refused.
ev2 "$R3B" "$T/ev-pos-class" '' "$(pos2 p-class "$(sym "$FNR")" "$(cite tree:tui/src/run.rs "$RUN")" | sed 's/"NSString"/"NoSuchClass"/')"
analyze "$R3B" "$T/ev-pos-class"
only position_unknown_class unknown-class p-class NoSuchClass

echo "PASS: objc-guard-evidence"
