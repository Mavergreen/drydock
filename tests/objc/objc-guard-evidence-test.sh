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

GD=__RNvCs1Fx_7fixture7guarded
GA=__RNvCs1Fx_7fixture7guardedCs9Zz_5other
GM=__RNvCs1Fx_7fixture7guardedCs8Yy_6other2
GT=__RNvCs1Fx_7fixture13guarded_twice
GU=__RNvCs1Fx_7fixture9unguarded
FIXTURE='{"name": "fixture", "version": "0.1.0", "checksum": "c0", "disambiguator": "1Fx"}'
OBJC2='{"name": "objc2", "version": "0.6.3", "checksum": "c1", "disambiguator": "2WYrep5oUp8"}, {"name": "objc2_foundation", "version": "0.3.2", "checksum": "c2", "disambiguator": "dIImX2SWmg2"}'
CRATES="$OBJC2, $FIXTURE"
# ev2 ARTIFACT OUT GUARDS POSITIONS [CRATES]: schema-2 evidence for ARTIFACT, built at a revision no record was reviewed at.
ev2() {
  cat >"$2" <<EOF
{"schema": 2, "kind": "objc-build-evidence",
 "artifact": {"path": "bin/x", "sha256": "$(sha "$1")"},
 "source": {"tree_sha256": "$TREE", "revision": "new-revision", "patches_sha256": "new-patches", "features": "new-features"},
 "crates": [${5:-$CRATES}], "type_map": [], "type_evidence": [], "binding_receipt": [],
 "position_evidence": [$4],
 "guards": [$3]}
EOF
}
cite() { printf '{"cite": "%s", "sha256": "%s"}' "$1" "$2"; }
cover() { printf '{"selector": "%s", "count": %s}' "$1" "$2"; }
guard2() {  # guard2 ID SYMBOL-JSON SOURCES COVERS [PATH]
  printf '{"id": "%s", "path": "%s", %s"selector": "%s", "guard": "respondsToSelector:", "fallback": "returns 0", "sources": [%s], "covers": [%s], "provenance": {"revision": "old-revision", "patches_sha256": "old-patches", "features": "old-features"}, "review": {"status": "reviewed", "reviewer": "A. Reviewer", "reason": "NO falls back to 0"}}' \
    "$1" "${5:-fixture::guarded}" "$2" "$SEL" "$3" "$4"
}
sym() { printf '"symbol": "%s", ' "$1"; }
FNR=__RNvXs6_NtNtCs2WYrep5oUp8_5objc27runtime15protocol_objectINtB5_14ProtocolObjectDNtNtB7_8nsobject16NSObjectProtocolEL_ENtNtCs5hICDV8pRVn_4core3fmt5Debug3fmtCsdIImX2SWmg2_16objc2_foundation
pos2() {  # pos2 ID SYMBOL-JSON SOURCES
  printf '{"id": "%s", "path": "<objc2::runtime::protocol_object::ProtocolObject<dyn objc2::runtime::nsobject::NSObjectProtocol> as core::fmt::Debug>::fmt", %s"selectors": ["UTF8String"], "kind": "-", "class": "NSString", "position": {"form": "result", "selector": "description"}, "sources": [%s], "note": "description returns an NSString"}' "$1" "$2" "$3"
}
n=0
analyze() {  # analyze ARTIFACT EVIDENCE [OPTION VALUE]...: rc, $T/report, $T/err
  art=$1 ev=$2; shift 2
  n=$((n + 1))
  rc=0; "$DRYDOCK_OBJC" analyze --artifact "$art" --root "$T/root" --references "$REF" --report "$T/report.$n" \
    --mode strict --build-evidence "$ev" --source-root "$S" "$@" 2>"$T/err" || rc=$?
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
ev2 "$G" "$T/ev-carries" "$(guard2 g-carries "$(sym $GD)" "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-carries"
clean carries
want carries $GD $SEL guarded 'guard record g-carries' "tree:tui/src/system_motion.rs sha256:$MOTION" \
  'old-revision' 'old-patches' 'old-features' 'not compared' 'reviewed by A. Reviewer'
grep -F '"unused_guard_records": []' "$T/report" >/dev/null || fail 'carries: the record was not used'

# sdk: cites hold under the pinned floor SDK (its header digest is the reference manifest's), not under
# another SDK root holding the same file.
HDR=System/Library/Frameworks/AppKit.framework/Headers/NSWorkspace.h
SDK_CITE=$(cite "sdk:$HDR" "$(sha "$SDK/$HDR")")
ev2 "$G" "$T/ev-sdk" "$(guard2 g-sdk "$(sym $GD)" "$MOTION_CITE, $SDK_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-sdk" --sdk-root "$SDK"
clean sdk_cite_match
want sdk_cite_match $GD $SEL guarded 'guard record g-sdk' "sdk:$HDR"
mkdir -p "$T/othersdk/$(dirname "$HDR")"; cp "$SDK/$HDR" "$T/othersdk/$HDR"
analyze "$G" "$T/ev-sdk" --sdk-root "$T/othersdk"
only sdk_cite_mismatch citation-unverifiable g-sdk "sdk:$HDR" 'pinned floor SDK' "$T/othersdk"
want sdk_cite_mismatch $GD $SEL unresolved

# source_changed: a cited file is not the one reviewed.
ev2 "$G" "$T/ev-changed" "$(guard2 g-changed "$(sym $GD)" "$(cite tree:tui/src/system_motion.rs "$STALE")" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-changed"
only source_changed guard-source-changed g-changed "$STALE" "$MOTION"
want source_changed $GD $SEL unresolved

# Two records on one send: one that no longer holds keeps the other from guarding it.
ev2 "$G" "$T/ev-pair" "$(guard2 g-good "$(sym $GD)" "$MOTION_CITE" "$(cover $SEL 1)"), $(guard2 g-bad "$(sym $GD)" "$(cite tree:tui/src/system_motion.rs "$STALE")" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-pair"
only pair guard-source-changed g-bad
want pair $GD $SEL unresolved

# coverage_added: a second guarded send in a reviewed function is one nobody reviewed.
ev2 "$G" "$T/ev-added" "$(guard2 g-added "$(sym $GT)" "$MOTION_CITE" "$(cover $SEL 1)" fixture::guarded_twice)" ''
analyze "$G" "$T/ev-added"
only coverage_added guard-coverage-changed g-added $GT $SEL 'measures 2' 'covers 1'
want coverage_added $GT $SEL unresolved

# coverage_removed: fewer guarded sends than the review covers, or a covered selector gone.
ev2 "$G" "$T/ev-removed" "$(guard2 g-removed "$(sym $GD)" "$MOTION_CITE" "$(cover $SEL 2)")" ''
analyze "$G" "$T/ev-removed"
only coverage_removed guard-coverage-changed g-removed $GD 'measures 1' 'covers 2'
ev2 "$G" "$T/ev-gone-sel" "$(guard2 g-gone-sel "$(sym $GD)" "$MOTION_CITE" "$(cover $SEL 1), $(cover isVoiceOverEnabled 1)")" ''
analyze "$G" "$T/ev-gone-sel"
only coverage_selector_removed guard-coverage-changed g-gone-sel isVoiceOverEnabled 'measures 0' 'covers 1'
# A cover that names another selector than the guarded one leaves the guarded send uncovered.
ev2 "$G" "$T/ev-other" "$(guard2 g-other "$(sym $GD)" "$MOTION_CITE" "$(cover isVoiceOverEnabled 1)")" ''
analyze "$G" "$T/ev-other"
[ "$rc" = 4 ] || fail "coverage_uncovered: exit $rc, want 4"
grep '"code": "guard-coverage-changed"' "$T/report" | grep -F g-other | grep -F $SEL >/dev/null ||
  fail "coverage_uncovered: errors '$(codes)'"
want coverage_uncovered $GD $SEL unresolved

# Each copy of one generic instance is measured: a copy with another count is a coverage change.
ev2 "$G" "$T/ev-copies" "$(guard2 g-copies '"symbols": ["'"$GD"'", "'"$GM"'"], ' "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-copies"
only copies guard-coverage-changed g-copies "$GM" 'measures 2'
want copies $GD $SEL unresolved
want copies $GM $SEL unresolved
# Copies that each measure the guard and the covered count close every send.
ev2 "$G" "$T/ev-copies-ok" "$(guard2 g-copies-ok '"symbols": ["'"$GD"'", "'"$GA"'"], ' "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-copies-ok"
clean copies_close
want copies_close $GD $SEL guarded 'guard record g-copies-ok'
want copies_close $GA $SEL guarded 'guard record g-copies-ok'
grep -F '"unused_guard_records": []' "$T/report" >/dev/null || fail 'copies_close: the record was not used'

# guard_gone: the binary no longer measures the guard: not guarded, as today, and the record goes unused.
ev2 "$G" "$T/ev-gone" "$(guard2 g-gone "$(sym $GU)" "$MOTION_CITE" "$(cover $SEL 1)" fixture::unguarded)" ''
analyze "$G" "$T/ev-gone"
clean guard_gone
want guard_gone $GU $SEL unsupported unguarded
grep -F '"unused_guard_records": ["g-gone"]' "$T/report" >/dev/null || fail 'guard_gone: g-gone not reported unused'

# unresolved: a record a send would use, with no resolved symbol.
ev2 "$G" "$T/ev-unresolved" "$(guard2 g-unresolved '' "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-unresolved"
only unresolved malformed-build-evidence g-unresolved fixture::guarded 'run drydock-objc resolve'

# A record's symbols are what resolve writes for its path, or the record is refused before its sources are read.
ev2 "$G" "$T/ev-elsewhere" "$(guard2 g-elsewhere "$(sym $GT)" "$MOTION_CITE" "$(cover $SEL 2)")" ''
analyze "$G" "$T/ev-elsewhere"
only symbol_elsewhere malformed-build-evidence g-elsewhere "symbol $GT demangles to fixture::guarded_twice" \
  'path fixture::guarded;' 'run drydock-objc resolve'
want symbol_elsewhere $GT $SEL unresolved
ev2 "$G" "$T/ev-not-v0" "$(guard2 g-not-v0 "$(sym _plain_guarded)" "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-not-v0"
only symbol_not_v0 malformed-build-evidence g-not-v0 'symbol _plain_guarded does not demangle' 'path fixture::guarded;' \
  'run drydock-objc resolve'
ev2 "$G" "$T/ev-twins" "$(guard2 g-twins '"symbols": ["'"$GD"'", "__RNvCs2Gy_7fixture7guarded"], ' "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-twins"
only two_functions malformed-build-evidence g-twins "symbols $GD and __RNvCs2Gy_7fixture7guarded are not copies" \
  'path fixture::guarded;' 'run drydock-objc resolve'
want two_functions $GD $SEL unresolved
ev2 "$G" "$T/ev-part" "$(guard2 g-part '"symbols": ["'"$GD"'", "'"$GD"'.part.0"], ' "$MOTION_CITE" "$(cover $SEL 1)")" ''
analyze "$G" "$T/ev-part"
only two_functions_suffix malformed-build-evidence g-part "$GD.part.0 are not copies" 'run drydock-objc resolve'
ev2 "$G" "$T/ev-unpinned" "$(guard2 g-unpinned "$(sym $GD)" "$MOTION_CITE" "$(cover $SEL 1)")" '' "$OBJC2"
analyze "$G" "$T/ev-unpinned"
only unpinned_root malformed-build-evidence g-unpinned "symbol $GD names crate fixture with disambiguator 1Fx" \
  'does not pin' 'run drydock-objc resolve'
ev2 "$G" "$T/ev-other-dis" "$(guard2 g-other-dis "$(sym $GD)" "$MOTION_CITE" "$(cover $SEL 1)")" '' "$OBJC2, $(echo "$FIXTURE" | sed 's/1Fx/2Gy/')"
analyze "$G" "$T/ev-other-dis"
# The artifact's own fixture crate disagrees with the pin, so the whole-artifact crate check refuses first.
only wrong_disambiguator crate-revision-mismatch "$GD: crate fixture has disambiguator 1Fx" '0.1.0 2Gy'
ev2 "$R3B" "$T/ev-pos-elsewhere" '' "$(pos2 p-elsewhere "$(sym "$FNR")" "$(cite tree:tui/src/run.rs "$RUN")" | sed 's/core::fmt::Debug>::fmt"/core::fmt::Display>::fmt"/')"
analyze "$R3B" "$T/ev-pos-elsewhere"
only position_symbol_elsewhere malformed-build-evidence p-elsewhere "demangles to <objc2::runtime::protocol_object::ProtocolObject" \
  'as core::fmt::Debug>::fmt, not' 'as core::fmt::Display>::fmt;' 'run drydock-objc resolve'
grep '"receiver_closure": "R3"' "$T/report" >/dev/null && fail 'position_symbol_elsewhere: a send was closed'

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
