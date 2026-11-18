#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then analyzes them with schema-2 evidence
# spec: src/objc/source-evidence.c header -- a schema-2 guard or R3 row that a send uses has every cited file
#       hashed by the analyzer itself, under --source-root, --crate-sources or --sdk-root; the source root's
#       digest must be the evidence's source.tree_sha256. A record no send uses is reported unused, not checked.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$ROOT/build/msc.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-source-hash-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }
sha() { shasum -a 256 "$1" | cut -c1-64; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@"; }
mkdir -p "$T/root/bin"
cc "$FX/guard-coverage.c" -o "$T/root/bin/gc" -lobjc -Wl,-U,_fixture_use
cc "$FX/r3.c" -o "$T/root/bin/r3" -lobjc
C="$T/root/bin/gc"
GD=__RNvCs1Fx_7fixture7guarded
R3B="$T/root/bin/r3"

# The prepared tree, with a .git the digest leaves out, a symlink that stays inside and one that leaves.
S="$T/src"
mkdir -p "$S/tui/src" "$S/.git" "$T/outside"
printf 'if !workspace.respondsToSelector(selector) { return false; }\n' >"$S/tui/src/system_motion.rs"
printf 'let d = obj.description();\n' >"$S/tui/src/run.rs"
printf 'ref: refs/heads/main\n' >"$S/.git/HEAD"
printf 'outside the tree\n' >"$T/outside/x.rs"
ln -s tui "$S/inside"
ln -s ../outside "$S/out"
ln -s .git "$S/gitlink"
CR="$T/crates"
mkdir -p "$CR/objc2-app-kit-0.3.1/src/generated" "$CR/foo-1.0.0-beta.1/src"
printf 'pub fn subviews() {}\n' >"$CR/objc2-app-kit-0.3.1/src/generated/NSView.rs"
printf 'pub fn x() {}\n' >"$CR/foo-1.0.0-beta.1/src/x.rs"
# Another version of a pinned crate, and a crate nobody pins, each holding a file with the cited hash.
mkdir -p "$CR/objc2-app-kit-0.3.0/src/generated" "$CR/stray-0.3.1/src/generated"
cp "$CR/objc2-app-kit-0.3.1/src/generated/NSView.rs" "$CR/objc2-app-kit-0.3.0/src/generated/NSView.rs"
cp "$CR/objc2-app-kit-0.3.1/src/generated/NSView.rs" "$CR/stray-0.3.1/src/generated/NSView.rs"
HDR=System/Library/Frameworks/AppKit.framework/Headers/NSWorkspace.h
[ -f "$SDK/$HDR" ] || fail "the pinned SDK has no $HDR"

MOTION=$(sha "$S/tui/src/system_motion.rs")
RUN=$(sha "$S/tui/src/run.rs")
VIEW=$(sha "$CR/objc2-app-kit-0.3.1/src/generated/NSView.rs")
PRE=$(sha "$CR/foo-1.0.0-beta.1/src/x.rs")
WS=$(sha "$SDK/$HDR")
OUT=$(sha "$T/outside/x.rs")
STALE=0000000000000000000000000000000000000000000000000000000000000000

# The digest, computed here independently: every entry but .git, sorted bytewise, one line each.
expect_digest() {
  (cd "$1" && find . -name .git -prune -o -mindepth 1 -print | sed 's|^\./||' | while IFS= read -r p; do
    if [ -L "$p" ]; then printf 'l %s %s\n' "$p" "$(readlink "$p")"
    elif [ -d "$p" ]; then printf 'd %s\n' "$p"
    else printf 'f %s %s\n' "$p" "$(sha "$p")"; fi
  done | LC_ALL=C sort | shasum -a 256 | cut -c1-64)
}
TREE=$("$DRYDOCK_OBJC" evidence --tree-digest-only --source-root "$S") || fail "--tree-digest-only: exit $?"
[ "$TREE" = "$(expect_digest "$S")" ] || fail "--tree-digest-only gave $TREE, the algorithm gives $(expect_digest "$S")"
printf 'objects\n' >"$S/.git/HEAD"
[ "$("$DRYDOCK_OBJC" evidence --tree-digest-only --source-root "$S")" = "$TREE" ] || fail 'the digest read .git'
rc=0; "$DRYDOCK_OBJC" evidence --tree-digest-only --source-root "$T/none" >/dev/null 2>&1 || rc=$?
[ "$rc" = 4 ] || fail "--tree-digest-only on a missing root: exit $rc, want 4"
rc=0; "$DRYDOCK_OBJC" evidence --tree-digest-only >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "--tree-digest-only without --source-root: exit $rc, want 2"
# emit-build-evidence records the same digest: one algorithm, not two.
"$DRYDOCK_OBJC" evidence --artifact "$C" --prestrip "$C" --source-root "$S" --references "$REF" --output "$T/emitted.json" 2>"$T/err" ||
  fail 'emit-build-evidence failed'
grep -F "\"tree_sha256\": \"$TREE\"" "$T/emitted.json" >/dev/null || fail 'emit-build-evidence records another tree digest'

# The SDK header digest: drydock-objc's, compared live with the formula the reference manifest's
# header_tree_sha256 was first made with, and with a frozen value, on a tree that has every case.
K="$T/sdk"
mkdir -p "$K/System/Library/Frameworks/F.framework/Versions/A/Headers" "$K/usr/include/sub" "$K/include" "$K/usr/lib" \
  "$K/HeadersX" "$K/.git/Headers" "$K/System/Library/Frameworks/F.framework/Modules"
printf 'f\n' >"$K/System/Library/Frameworks/F.framework/Versions/A/Headers/F.h"
ln -s A "$K/System/Library/Frameworks/F.framework/Versions/Current"
ln -s Versions/Current/Headers "$K/System/Library/Frameworks/F.framework/Headers"
printf 'module F {}\n' >"$K/System/Library/Frameworks/F.framework/Modules/module.modulemap"
printf 'a\n' >"$K/usr/include/a.h"; printf 'b\n' >"$K/usr/include/sub/b.h"; printf 'h\n' >"$K/usr/include/.hidden.h"
printf 's\n' >"$K/usr/include/with space.h"; printf 'k\n' >"$K/usr/include/back\\slash.h"
printf 'B\n' >"$K/usr/include/B.h"; printf 'c\n' >"$K/include/c.h"; printf 'g\n' >"$K/.git/Headers/g.h"
printf 'm\n' >"$K/usr/lib/x.modulemap"; printf 't\n' >"$K/usr/lib/libfoo.tbd"; printf 'p\n' >"$K/SDKSettings.plist"
printf 'y\n' >"$K/HeadersX/y.h"; ln -s a.h "$K/usr/include/link.h"
shell_sdk_digest() {
  (cd "$1" && find . -type f \( -path '*/Headers/*' -o -path './usr/include/*' -o -path './include/*' -o -name '*.modulemap' \) |
    LC_ALL=C sort | tr '\n' '\0' | xargs -0 shasum -a 256) | shasum -a 256 | cut -c1-64
}
SDKD=$("$DRYDOCK_OBJC" evidence --sdk-digest-only --sdk-root "$K") || fail "--sdk-digest-only: exit $?"
[ "$SDKD" = "$(shell_sdk_digest "$K")" ] || fail "--sdk-digest-only gave $SDKD, the shell formula $(shell_sdk_digest "$K")"
[ "$SDKD" = 48a51e8e6382d038400903e8a49afc82a8ade699f5f70ef1218b076856a1aac4 ] || fail "--sdk-digest-only gave $SDKD, not the frozen value"
printf 'changed\n' >"$K/usr/lib/libfoo.tbd"
[ "$("$DRYDOCK_OBJC" evidence --sdk-digest-only --sdk-root "$K")" = "$SDKD" ] || fail 'the SDK digest read an unselected file'
printf 'changed\n' >"$K/usr/include/sub/b.h"
[ "$("$DRYDOCK_OBJC" evidence --sdk-digest-only --sdk-root "$K")" != "$SDKD" ] || fail 'the SDK digest missed a header'
rc=0; "$DRYDOCK_OBJC" evidence --sdk-digest-only --sdk-root "$T/none" >/dev/null 2>&1 || rc=$?
[ "$rc" = 4 ] || fail "--sdk-digest-only on a missing root: exit $rc, want 4"
rc=0; "$DRYDOCK_OBJC" evidence --sdk-digest-only >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "--sdk-digest-only without --sdk-root: exit $rc, want 2"
# The pinned floor SDK has the reference manifest's digest.
[ "$("$DRYDOCK_OBJC" evidence --sdk-digest-only --sdk-root "$SDK")" = "$(sed -n 's/.*"header_tree_sha256": "\([0-9a-f]*\)".*/\1/p' "$REF/manifest.json" | head -1)" ] ||
  fail 'the pinned floor SDK does not have the manifest header_tree_sha256'

# A crate: cite holds only for a pinned crate's version; a name's "_" matches the directory's "-".
CRATES='{"name": "fixture", "version": "0.1.0", "checksum": "c0", "disambiguator": "1Fx"}, {"name": "objc2", "version": "0.6.3", "checksum": "c1", "disambiguator": "2WYrep5oUp8"}, {"name": "objc2_app_kit", "version": "0.3.1", "checksum": "c2", "disambiguator": "3Ak"}, {"name": "foo", "version": "1.0.0-beta.1", "checksum": "c3", "disambiguator": "4Fo"}'
# ev2 ARTIFACT OUT TREE GUARDS POSITIONS: schema-2 evidence bound to ARTIFACT.
ev2() {
  cat >"$2" <<EOF
{"schema": 2, "kind": "objc-build-evidence",
 "artifact": {"path": "bin/x", "sha256": "$(sha "$1")"},
 "source": {"tree_sha256": "$3"},
 "crates": [$CRATES], "type_map": [], "type_evidence": [], "binding_receipt": [],
 "position_evidence": [$5],
 "guards": [$4]}
EOF
}
cite() { printf '{"cite": "%s", "sha256": "%s"}' "$1" "$2"; }
guard2() {  # guard2 ID FUNCTION SOURCES
  printf '{"id": "%s", "path": "fixture::guarded", "symbol": "%s", "selector": "accessibilityDisplayShouldReduceMotion", "guard": "respondsToSelector:", "fallback": "returns 0", "sources": [%s], "covers": [{"selector": "accessibilityDisplayShouldReduceMotion", "count": 1}], "provenance": {"revision": "r", "patches_sha256": "p", "features": "f"}, "review": {"status": "reviewed", "reviewer": "A. Reviewer", "reason": "NO falls back to 0"}}' "$1" "$2" "$3"
}
FNR=__RNvXs6_NtNtCs2WYrep5oUp8_5objc27runtime15protocol_objectINtB5_14ProtocolObjectDNtNtB7_8nsobject16NSObjectProtocolEL_ENtNtCs5hICDV8pRVn_4core3fmt5Debug3fmtCsdIImX2SWmg2_16objc2_foundation
pos2() {  # pos2 ID SOURCES
  printf '{"id": "%s", "path": "<objc2::runtime::protocol_object::ProtocolObject<dyn objc2::runtime::nsobject::NSObjectProtocol> as core::fmt::Debug>::fmt", "symbol": "%s", "selectors": ["UTF8String"], "kind": "-", "class": "NSString", "position": {"form": "result", "selector": "description"}, "sources": [%s]}' "$1" "$FNR" "$2"
}
n=0
analyze() {  # analyze ARTIFACT EVIDENCE [OPTION VALUE]...: rc, $T/report, $T/err
  art=$1 ev=$2; shift 2
  n=$((n + 1))
  rc=0; "$DRYDOCK_OBJC" analyze --artifact "$art" --root "$T/root" --references "$REF" --report "$T/report.$n" \
    --mode strict --build-evidence "$ev" "$@" 2>"$T/err" || rc=$?
  ln -sf "$T/report.$n" "$T/report"
}
ROOTS() { echo --source-root "$S" --crate-sources "$CR" --sdk-root "$SDK"; }
codes() { sed -n 's/.*"code": "\([^"]*\)".*/\1/p' "$T/report" | sort -u | tr '\n' ' '; }
only() {  # only NAME CODE DETAIL...: exit 4, exactly CODE, one CODE error holding every DETAIL
  name=$1 code=$2; shift 2
  [ "$rc" = 4 ] || fail "$name: exit $rc, want 4"
  [ "$(codes)" = "$code " ] || fail "$name: errors '$(codes)', want '$code '"
  grep "\"code\": \"$code\"" "$T/report" >"$T/lines"
  for d in "$@"; do grep -F -- "$d" "$T/lines" >"$T/lines.next" || fail "$name: no $code detail with '$d'"; mv "$T/lines.next" "$T/lines"; done
}
guarded() {  # guarded NAME: no error, fixture::guarded guarded by its record (exit 1: the fixture's own unguarded send)
  [ "$rc" = 1 ] || fail "$1: exit $rc, want 1, errors '$(codes)'"
  [ -z "$(codes)" ] || fail "$1: errors '$(codes)'"
  grep "\"function\": \"$GD\"" "$T/report" | grep '"verdict": "guarded"' | grep -F "guard record g-$1" >/dev/null ||
    fail "$1: fixture::guarded is not guarded by g-$1"
}
guard_case() {  # guard_case NAME SOURCES [TREE]: the guard fixture, its fixture::guarded send's record citing SOURCES
  ev2 "$C" "$T/ev-$1" "${3:-$TREE}" "$(guard2 "g-$1" "$GD" "$2")" ''
  # shellcheck disable=SC2046
  analyze "$C" "$T/ev-$1" $(ROOTS)
}

# matches: every cited file has its recorded hash.
guard_case matches "$(cite tree:tui/src/system_motion.rs "$MOTION")"
guarded matches
grep -F '"unused_guard_records": []' "$T/report" >/dev/null || fail 'matches: the record was not used'

# changed_file: the cited file is not the one reviewed; the error names the cite and both hashes.
guard_case changed_file "$(cite tree:tui/src/run.rs "$RUN"), $(cite tree:tui/src/system_motion.rs "$STALE")"
only changed_file guard-source-changed g-changed_file tui/src/system_motion.rs "$STALE" "$MOTION"
grep -F 'tui/src/run.rs' "$T/report" >/dev/null && fail 'changed_file: the unchanged file was reported'

# Every record a send uses is checked, not only the first.
ev2 "$C" "$T/ev-two" "$TREE" "$(guard2 g-first "$GD" "$(cite tree:tui/src/system_motion.rs "$MOTION")"), $(guard2 g-second "$GD" "$(cite tree:tui/src/run.rs "$STALE")")" ''
# shellcheck disable=SC2046
analyze "$C" "$T/ev-two" $(ROOTS)
grep '"code": "guard-source-changed"' "$T/report" | grep -F g-second >/dev/null || fail 'two records: the second was not checked'

# moved_file: the cited file is gone.
guard_case moved_file "$(cite tree:tui/src/old_motion.rs "$MOTION")"
only moved_file citation-unverifiable g-moved_file tree:tui/src/old_motion.rs

# tree_swapped: another tree than the evidence describes.
guard_case tree_swapped "$(cite tree:tui/src/system_motion.rs "$MOTION")" "$STALE"
only tree_swapped source-tree-mismatch "$STALE" "$TREE"

# escape: a cite may not leave its root, by .. or by a symlink, even to a file with the recorded hash.
guard_case escape_dotdot "$(cite tree:../outside/x.rs "$OUT")"
only escape_dotdot citation-unverifiable g-escape_dotdot tree:../outside/x.rs
guard_case escape_symlink "$(cite tree:out/x.rs "$OUT")"
only escape_symlink citation-unverifiable g-escape_symlink tree:out/x.rs
guard_case inside_symlink "$(cite tree:inside/src/system_motion.rs "$MOTION")"
guarded inside_symlink
# .git is not part of the tree's digest, so a cite into it, by name or through a symlink, is refused.
guard_case tree_git "$(cite tree:.git/HEAD "$(sha "$S/.git/HEAD")")"
only tree_git citation-unverifiable g-tree_git tree:.git/HEAD
guard_case tree_gitlink "$(cite tree:gitlink/HEAD "$(sha "$S/.git/HEAD")")"
only tree_gitlink citation-unverifiable g-tree_gitlink tree:gitlink/HEAD

# crate_cite resolves under --crate-sources, and matches.
guard_case crate_cite "$(cite crate:objc2-app-kit-0.3.1/src/generated/NSView.rs "$VIEW")"
guarded crate_cite
guard_case crate_prerelease "$(cite crate:foo-1.0.0-beta.1/src/x.rs "$PRE")"
guarded crate_prerelease
# A crate directory the evidence does not pin is refused, even holding a file with the recorded hash.
guard_case crate_unpinned_version "$(cite crate:objc2-app-kit-0.3.0/src/generated/NSView.rs "$VIEW")"
only crate_unpinned_version citation-unverifiable g-crate_unpinned_version crate:objc2-app-kit-0.3.0/src/generated/NSView.rs 'pins no crate'
guard_case crate_unpinned_name "$(cite crate:stray-0.3.1/src/generated/NSView.rs "$VIEW")"
only crate_unpinned_name citation-unverifiable g-crate_unpinned_name crate:stray-0.3.1/src/generated/NSView.rs 'pins no crate'
# An sdk: cite verifies under the pinned floor SDK, and is refused under any other SDK root.
guard_case sdk_cite "$(cite "sdk:$HDR" "$WS")"
guarded sdk_cite
# The pinned SDK's digest covers its headers only: a file outside that selection is not pinned by it.
guard_case sdk_unselected "$(cite sdk:SDKSettings.plist "$(sha "$SDK/SDKSettings.plist")")"
only sdk_unselected citation-unverifiable g-sdk_unselected sdk:SDKSettings.plist
mkdir -p "$K/$(dirname "$HDR")"; cp "$SDK/$HDR" "$K/$HDR"
ev2 "$C" "$T/ev-sdk-other" "$TREE" "$(guard2 g-sdk_other "$GD" "$(cite "sdk:$HDR" "$WS")")" ''
analyze "$C" "$T/ev-sdk-other" --source-root "$S" --sdk-root "$K"
only sdk_other citation-unverifiable g-sdk_other "sdk:$HDR" 'pinned floor SDK' "$K"
guard_case crate_changed "$(cite crate:objc2-app-kit-0.3.1/src/generated/NSView.rs "$STALE")"
only crate_changed guard-source-changed g-crate_changed "$STALE" "$VIEW"

# A root not given leaves its cites uncheckable.
ev2 "$C" "$T/ev-noroot" "$TREE" "$(guard2 g-noroot "$GD" "$(cite crate:objc2-app-kit-0.3.1/src/generated/NSView.rs "$VIEW")")" ''
analyze "$C" "$T/ev-noroot" --source-root "$S"
only noroot citation-unverifiable g-noroot crate:objc2-app-kit-0.3.1/src/generated/NSView.rs

# No row is used against a tree nobody verified, even one that cites no tree: file.
ev2 "$C" "$T/ev-notree" "$TREE" "$(guard2 g-notree "$GD" "$(cite crate:objc2-app-kit-0.3.1/src/generated/NSView.rs "$VIEW")")" ''
analyze "$C" "$T/ev-notree" --crate-sources "$CR"
only notree source-tree-mismatch g-notree --source-root
grep '"verdict": "guarded"' "$T/report" >/dev/null && fail 'notree: the row closed a send without a verified tree'

# A record no send uses is reported unused and fails nothing, whatever it cites.
ev2 "$C" "$T/ev-unused" "$TREE" "$(guard2 g-unused _no_such_function "$(cite tree:tui/src/system_motion.rs "$STALE")")" ''
# shellcheck disable=SC2046
analyze "$C" "$T/ev-unused" $(ROOTS)
[ "$rc" = 1 ] || fail "unused: exit $rc, want 1 (the fixture's own unsupported sends), errors '$(codes)'"
[ -z "$(codes)" ] || fail "unused: errors '$(codes)'"
grep -F '"unused_guard_records": ["g-unused"]' "$T/report" >/dev/null || fail 'unused: g-unused not reported unused'

# R3 rows are checked the same way when a send uses them.
ev2 "$R3B" "$T/ev-pos-changed" "$TREE" '' "$(pos2 p-changed "$(cite tree:tui/src/run.rs "$STALE")")"
# shellcheck disable=SC2046
analyze "$R3B" "$T/ev-pos-changed" $(ROOTS)
only pos_changed position-source-changed p-changed tui/src/run.rs "$STALE" "$RUN"
ev2 "$R3B" "$T/ev-pos-match" "$TREE" '' "$(pos2 p-match "$(cite tree:tui/src/run.rs "$RUN")")"
# shellcheck disable=SC2046
analyze "$R3B" "$T/ev-pos-match" $(ROOTS)
# Its sources verify, so the row's binary-side checks run: this evidence pins no crate the symbol names.
only pos_match unpinned-crate p-match
grep '"receiver_closure": "R3"' "$T/report" >/dev/null && fail 'pos_match: a schema-2 row closed a send'

# The roots belong to build evidence.
rc=0; "$DRYDOCK_OBJC" analyze --artifact "$C" --root "$T/root" --references "$REF" --report "$T/report.lone" --source-root "$S" 2>"$T/err" || rc=$?
[ "$rc" = 2 ] || fail "--source-root without --build-evidence: exit $rc, want 2"

echo "PASS: objc-source-hash"
