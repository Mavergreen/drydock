#!/bin/sh
# platform: macOS-only -- links an x86_64 fixture against the pinned 10.9 SDK, then analyzes it with build evidence
# spec: src/objc/source-evidence.c header -- build evidence schema 2: guard and R3 rows name a function
#       path and cite every file they rest on; guards pin what they cover. Parsed strictly; a row
#       no send uses is reported unused (objc-source-hash-test.sh checks rows in use).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
. "$ROOT/build/msc.sh"
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
FX="$HERE/fixtures"
E2="$FX/evidence-schema2"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-evidence-schema2-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$SHIPYARD_SCRIPTS/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixture away from the pinned SDK.
env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 \
  "$FX/plain.c" -o "$T/plain"
mkdir -p "$T/root/bin"; mv "$T/plain" "$T/root/bin/plain"
P="$T/root/bin/plain"
SHA=$(shasum -a 256 "$P" | cut -c1-64)
n=0
analyze() {  # analyze FIXTURE: rc, $T/report and $T/err, the fixture bound to the plain artifact
  n=$((n + 1))
  sed "s/@ARTIFACT_SHA256@/$SHA/" "$1" >"$T/ev.$n"
  rc=0; "$DRYDOCK_OBJC" analyze --artifact "$P" --root "$T/root" --references "$REF" --report "$T/report.$n" \
    --mode strict --build-evidence "$T/ev.$n" 2>"$T/err" || rc=$?
  ln -sf "$T/report.$n" "$T/report"
}
codes() { sed -n 's/.*"code": "\([^"]*\)".*/\1/p' "$T/report" | sort -u | tr '\n' ' '; }
refused() {  # refused FIXTURE CODE DETAIL-FRAGMENT
  analyze "$E2/$1"
  [ "$rc" = 4 ] || fail "$1: exit $rc, want 4"
  [ "$(codes)" = "$2 " ] || fail "$1: errors '$(codes)', want '$2 '"
  grep "\"code\": \"$2\"" "$T/report" | grep -F -- "$3" >/dev/null || fail "$1: no $2 detail with '$3'"
}

# Positive control: the analyzer measures the artifact on its own, so a later exit 0 is the evidence's.
rc=0; "$DRYDOCK_OBJC" analyze --artifact "$P" --root "$T/root" --references "$REF" --report "$T/bare" --mode strict 2>"$T/err" || rc=$?
[ "$rc" = 0 ] || fail "plain without evidence: exit $rc"

# A schema-2 file with no guard or position rows parses, and the analysis measures.
analyze "$E2/no-records.json"
[ "$rc" = 0 ] || fail "no-records: exit $rc, errors '$(codes)'"

# Every record form parses; rows no send uses fail nothing and are reported unused.
analyze "$E2/valid.json"
[ "$rc" = 0 ] || fail "valid: exit $rc, errors '$(codes)'"
grep -F '"unused_position_evidence": ["p-result"], "unused_guard_records": ["g-motion"]' "$T/report" >/dev/null ||
  fail 'valid: the rows were not reported unused'
# A crate's version may carry a prerelease: it starts at the first dash before a digit.
analyze "$E2/crate-prerelease.json"
[ "$rc" = 0 ] || fail "crate-prerelease: exit $rc, errors '$(codes)'"

# A crate's disambiguator is optional to parse (resolve writes it) and required to use.
refused unresolved-crate.json malformed-build-evidence 'crate 1 lacks name, version, checksum or disambiguator'

refused missing-sources.json malformed-build-evidence 'guard g-motion: sources is missing'
refused position-missing-sources.json malformed-build-evidence 'position evidence p-result: sources is missing'
refused empty-covers.json malformed-build-evidence 'guard g-motion: covers is missing or empty'
refused bad-cite.json malformed-build-evidence 'citation tui/src/system_motion.rs is not'
refused bad-crate-cite.json malformed-build-evidence 'crate:objc2-app-kit/'
refused bad-sha.json malformed-build-evidence 'position evidence p-result: a source is not exactly {cite, sha256} with a SHA-256'
refused unknown-key.json malformed-build-evidence 'unknown key function'
refused missing-tree.json malformed-build-evidence 'source.tree_sha256 is not a SHA-256'
refused symbol-and-symbols.json malformed-build-evidence 'symbol and symbols are exclusive'

# Schema 1 still parses: a schema-1 guard keeps its own fields and is checked by its own rule.
cat >"$T/schema1.json" <<'EOF'
{"schema": 1, "kind": "objc-build-evidence",
 "artifact": {"path": "bin/plain", "sha256": "@ARTIFACT_SHA256@"},
 "source": {"revision": "r", "patches_sha256": "p", "features": "f"},
 "crates": [], "type_map": [], "type_evidence": [], "binding_receipt": [],
 "guards": [{"id": "g-1", "function": "_main", "selector": "count", "guard": "respondsToSelector:", "fallback": "returns 0",
   "source": {"file": "x.c", "line": 7, "sha256": "s", "revision": "r", "patches_sha256": "p", "features": "f"},
   "review": {"status": "reviewed", "reviewer": "A. Reviewer", "reason": "falls back"}}]}
EOF
analyze "$T/schema1.json"
[ "$rc" = 0 ] || fail "schema 1: exit $rc, errors '$(codes)'"
grep -F '"unused_guard_records": ["g-1"]' "$T/report" >/dev/null || fail 'schema 1: g-1 not parsed as a guard record'

echo "PASS: objc-evidence-schema2"
