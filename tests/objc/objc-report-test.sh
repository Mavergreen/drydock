#!/bin/sh
# platform: macOS-only -- links x86_64 fixtures against the pinned 10.9 SDK, then reports on them
# spec: tools/objc-compat/main.m header -- the schema-1 report and the command contract: canonical
#       bytes, deterministic IDs, exit 0/1/2/4, exclusive atomic output, bounded inputs and no
#       partial clean report.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
FX="$HERE/fixtures/objc-api"
REF="$ROOT/reference/objc"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-report-test.XXXXXX")
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; [ ! -f "$T/err" ] || tail -5 "$T/err" >&2; exit 1; }

SDK=$(sh "$ROOT/scripts/fetch_sdk.sh" --arch x86_64)
# platform: env -i keeps CPATH and SDKROOT from steering the fixtures away from the pinned SDK.
cc() { env -i PATH=/usr/bin:/bin /usr/bin/clang -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=10.9 -O1 "$@"; }
mkdir -p "$T/root/bin" "$T/out"
cc "$FX/classify.c" -o "$T/root/bin/classify" -lobjc -Wl,-U,_objc_alloc -Wl,-U,_fixture_use
cc "$FX/plain.c" -o "$T/root/bin/plain"
C="$T/root/bin/classify"
# spec: scripts/objc-compat.sh header -- run REPORT ARGS...: the wrapper with --report REPORT; rc set.
run() { rep=$1; shift; rc=0; sh "$ROOT/scripts/objc-compat.sh" "$@" --report "$rep" 2>"$T/err" || rc=$?; }
std() { printf '%s\n' --artifact "$1" --root "$T/root" --references "${2:-$REF}"; }
exit_is() { [ "$rc" = "$1" ] || fail "$2: exit $rc, want $1"; }
complete_is() { grep "\"complete_within_boundary\": $1," "$2" >/dev/null || fail "$3: complete_within_boundary is not $1"; }
error_in() { grep "\"code\": \"$1\"" "$2" >/dev/null || fail "$3: no $1 error in the report"; }
sha() { shasum -a 256 "$1" | cut -c1-64; }

# spec: tools/objc-compat/main.m header -- a measured artifact without Objective-C passes strict; prose is no finding.
run "$T/out/plain" --artifact "$T/root/bin/plain" --root "$T/root" --references "$REF" --mode strict
exit_is 0 'plain C strict'
complete_is true "$T/out/plain" 'plain C'
grep '"findings": \[\]' "$T/out/plain" >/dev/null || fail 'prose became a finding'
grep '"path": "bin/plain"' "$T/out/plain" >/dev/null || fail 'the artifact is not named relative to the root'

# spec: tools/objc-compat/main.m header -- inventory reports without failing; strict fails on blocking findings.
run "$T/out/inventory" --artifact "$C" --root "$T/root" --references "$REF"
exit_is 0 'inventory'
grep '"mode": "inventory"' "$T/out/inventory" >/dev/null && grep '"verdict": "unsupported"' "$T/out/inventory" >/dev/null ||
  fail 'inventory hid its findings'
run "$T/out/strict1" --artifact "$C" --root "$T/root" --references "$REF" --mode strict
exit_is 1 'strict with blocking findings'

# spec: tools/objc-compat/main.m header -- deterministic bytes and IDs: two runs, one report.
run "$T/out/strict2" --artifact "$C" --root "$T/root" --references "$REF" --mode strict
exit_is 1 'second strict run'
cmp -s "$T/out/strict1" "$T/out/strict2" || fail 'two runs over the same inputs differ'
ids=$(sed -n 's/^  {"id": "\([^"]*\)".*/\1/p' "$T/out/strict1")
[ -n "$ids" ] && [ "$(printf '%s\n' "$ids" | sort | uniq -d)" = "" ] || fail 'finding IDs are missing or not unique'
printf '%s\n' "$ids" | grep -E '^x86_64@0x[0-9a-f]+:[-+?]\[' >/dev/null || fail 'IDs do not carry site and API identity'
for k in '"schema": 1' '"observation_boundary": ' '"limits": \[' '"inputs": {' '"artifacts": \[' '"findings": \[' '"errors": \[' \
         "\"manifest_sha256\": \"$(sha "$REF/manifest.json")\"" "\"sha256\": \"$(sha "$C")\"" '"analyzer": "objc-compat-'; do
  grep "$k" "$T/out/strict1" >/dev/null || fail "report lacks $k"
done

# spec: tools/objc-compat/classify.c objc_classify_findings -- one finding per path of a call read once per incoming path
#       (tests/fixtures/objc-api/merged-send.S form 4: two -[NSArray count] at one call): the id and "incoming" carry the
#       predecessor path's last instruction, so the two stay two findings; a call measured once has "incoming": null.
cc -DFORM=4 "$FX/merged-send.S" -o "$T/root/bin/merged" -framework Foundation -lobjc
run "$T/out/merged" --artifact "$T/root/bin/merged" --root "$T/root" --references "$REF" --mode strict
exit_is 0 'two paths of one merged call'
mids=$(sed -n 's/^  {"id": "\([^"]*\)".*/\1/p' "$T/out/merged")
[ "$(printf '%s\n' "$mids" | grep -c '^x86_64@0x[0-9a-f]*/0x[0-9a-f]*:-\[NSArray count\]$')" = 2 ] &&
  [ "$(printf '%s\n' "$mids" | sort | uniq -d)" = "" ] || fail "the paths of a merged call are not two findings: $mids"
[ "$(grep -c '"incoming": "0x[0-9a-f]*"' "$T/out/merged")" = 2 ] && grep '"incoming": null' "$T/out/merged" >/dev/null ||
  fail 'findings do not say which incoming path they are'

# spec: tools/objc-compat/main.m header -- host-independent bytes: the same artifact, references and
#       evidence under other absolute paths (another host's clone and temp dirs) give one report, which
#       names no absolute path and identifies the analyzer by its sources, not this host's build.
mkdir -p "$T/hostA/root/bin" "$T/host B/root/bin" "$T/hostA/refs" "$T/host B/refs"
cp "$C" "$T/hostA/root/bin/classify"; cp "$C" "$T/host B/root/bin/classify"
cp "$REF"/* "$T/hostA/refs"/; cp "$REF"/* "$T/host B/refs"/
printf '{"schema": 1, "kind": "objc-build-evidence", "artifact": {"sha256": "%s"}, "source": {"revision": "r", "patches_sha256": "p", "features": "f"}}\n' "$(sha "$C")" >"$T/hostA/ev.json"
cp "$T/hostA/ev.json" "$T/host B/ev.json"
for h in hostA 'host B'; do
  run "$T/out/cross-$(printf '%s' "$h" | tr -d ' ')" --artifact "$T/$h/root/bin/classify" --root "$T/$h/root" \
    --references "$T/$h/refs" --build-evidence "$T/$h/ev.json" --mode strict
  exit_is 1 "cross-host run in $h"
done
cmp -s "$T/out/cross-hostA" "$T/out/cross-hostB" || fail 'reports differ only by the hosts'"'"' absolute paths'
! grep -F "$T" "$T/out/cross-hostA" >/dev/null || fail 'the report names an absolute path'
sh "$ROOT/scripts/objc-compat-build.sh" --analyzer "$T/analyzer-id" 2>"$T/build-id.log" || fail 'analyzer did not build'
src_id=$(sed -n 's/.* source \([0-9a-f]*\) .*/\1/p' "$T/build-id.log")
[ -n "$src_id" ] || fail "the analyzer build reports no source identity: $(cat "$T/build-id.log")"
grep "\"analyzer\": \"objc-compat-src-$src_id\"" "$T/out/cross-hostA" >/dev/null || fail 'inputs.analyzer is not the source identity'
# spec: scripts/objc-compat-build.sh header -- the source identity does not depend on the locale: a
#       collation that orders linkedit_order.h before linkedit.h (en_US.UTF-8 on a modern host,
#       et_EE.ISO8859-15 on 10.9) must still give the C-locale identity. Locales a host lacks are skipped.
for loc in C en_US.UTF-8 et_EE.ISO8859-15 sv_SE.UTF-8; do
  locale -a 2>/dev/null | grep -qx "$loc" || [ "$loc" = C ] || continue
  LC_ALL=$loc LANG=$loc sh "$ROOT/scripts/objc-compat-build.sh" --analyzer "$T/analyzer-id" 2>"$T/build-id.log" || fail "analyzer did not build under $loc"
  got=$(sed -n 's/.* source \([0-9a-f]*\) .*/\1/p' "$T/build-id.log")
  [ "$got" = "$src_id" ] || fail "the analyzer's source identity under $loc is $got, not $src_id"
done

# spec: tools/objc-compat/main.m header -- misuse is 2 and writes nothing.
usage_case() {  # usage_case WHY REPORT ARGS...
  why=$1 rep=$2; shift 2
  rc=0; sh "$ROOT/scripts/objc-compat.sh" "$@" --report "$rep" 2>"$T/err" || rc=$?
  [ "$rc" = 2 ] || fail "$why: exit $rc, want 2"
}
usage_case 'missing --references' "$T/out/u1" --artifact "$C" --root "$T/root"
[ ! -e "$T/out/u1" ] || fail 'a usage error wrote a report'
usage_case 'unknown option' "$T/out/u2" --artifact "$C" --root "$T/root" --references "$REF" --fast yes
usage_case 'repeated option' "$T/out/u3" --artifact "$C" --root "$T/root" --references "$REF" --mode strict --mode strict
usage_case 'bad mode' "$T/out/u4" --artifact "$C" --root "$T/root" --references "$REF" --mode lenient
usage_case 'artifact outside the root' "$T/out/u5" --artifact "$FX/classify.c" --root "$T/root" --references "$REF"
usage_case 'missing destination directory' "$T/out/no/such/report" --artifact "$C" --root "$T/root" --references "$REF"

# spec: tools/objc-compat/main.m header -- an existing destination in any form is refused and left alone.
echo keep >"$T/out/existing"
ln -s "$T/out/existing" "$T/out/symlink"
ln -s "$T/out/nowhere" "$T/out/dangling"
ln "$T/out/existing" "$T/out/hardlink"
for d in existing symlink dangling hardlink; do
  usage_case "existing destination ($d)" "$T/out/$d" --artifact "$C" --root "$T/root" --references "$REF"
done
[ "$(cat "$T/out/existing")" = keep ] && [ ! -e "$T/out/nowhere" ] || fail 'a refused destination was written through'

# spec: tools/objc-compat/main.m header -- cannot-measure is 4 with an incomplete report naming the error, never a clean one.
mkdir -p "$T/refs-tampered"; cp "$REF"/* "$T/refs-tampered"/
printf 'class\tAppKit\tNSFake\t-\tNSObject\t-\t-\t-\t0\tx.h:1\t-\n' >>"$T/refs-tampered/floor-sdk.tsv"
run "$T/out/tampered" --artifact "$C" --root "$T/root" --references "$T/refs-tampered" --mode strict
exit_is 4 'tampered reference'; complete_is false "$T/out/tampered" 'tampered'; error_in reference-hash-mismatch "$T/out/tampered" 'tampered'
grep '"findings": \[\]' "$T/out/tampered" >/dev/null || fail 'an unverified reference produced findings'
mkdir -p "$T/refs-extra"; cp "$REF"/* "$T/refs-extra"/; echo stray >"$T/refs-extra/stray.tsv"
run "$T/out/extra" --artifact "$C" --root "$T/root" --references "$T/refs-extra" --mode strict
exit_is 4 'unlisted reference file'; error_in malformed-reference "$T/out/extra" 'unlisted'
head -c 3000 "$C" >"$T/root/bin/truncated"
run "$T/out/truncated" --artifact "$T/root/bin/truncated" --root "$T/root" --references "$REF" --mode strict
exit_is 4 'truncated artifact'; complete_is false "$T/out/truncated" 'truncated'
grep '"findings": \[\]' "$T/out/truncated" >/dev/null || fail 'a truncated artifact produced findings'
cc -arch arm64 "$FX/plain.c" -o "$T/root/bin/arm64-only" 2>/dev/null || cp /usr/bin/true "$T/root/bin/arm64-only"
if lipo -info "$T/root/bin/arm64-only" 2>/dev/null | grep -q 'architecture: arm64$'; then
  run "$T/out/arm64" --artifact "$T/root/bin/arm64-only" --root "$T/root" --references "$REF" --mode strict
  exit_is 4 'no x86_64 slice'; error_in no-x86_64-slice "$T/out/arm64" 'arm64 only'
fi

# spec: tools/objc-compat/main.m header -- malformed UTF-8: in an input it is cannot-measure; where the report would carry it, no report.
printf '{"schema": 1, "kind": "objc-build-evidence", "artifact": {"sha256": "\377"}, "source": {}}\n' >"$T/bad-utf8.json"
run "$T/out/badutf8" --artifact "$C" --root "$T/root" --references "$REF" --mode strict --build-evidence "$T/bad-utf8.json"
exit_is 4 'malformed UTF-8 evidence'; error_in malformed-input "$T/out/badutf8" 'malformed UTF-8 evidence'
printf '#include <objc/runtime.h>\n#include <objc/message.h>\n__attribute__((used, noinline)) void *odd(void) __asm__("_odd\\377name");\nvoid *odd(void) { return ((void *(*)(void *, SEL))objc_msgSend)((void *)objc_getClass("NSObject"), sel_registerName("new")); }\nint main(int c, char **v) { (void)v; return c > 99 ? odd() != 0 : 0; }\n' >"$T/odd.c"
cc "$T/odd.c" -o "$T/root/bin/odd" -lobjc
run "$T/out/odd" --artifact "$T/root/bin/odd" --root "$T/root" --references "$REF" --mode strict
exit_is 4 'a non-UTF-8 symbol'
[ ! -e "$T/out/odd" ] || fail 'a report carrying malformed UTF-8 was written'
grep 'malformed UTF-8' "$T/err" >/dev/null || fail 'the malformed UTF-8 refusal is not explained'

# spec: tools/objc-compat/main.m header -- oversized inputs are refused before they are parsed.
{ printf '{"schema": 1, "pad": "'; head -c 17000000 /dev/zero | tr '\0' 'a'; printf '"}\n'; } >"$T/huge.json"
run "$T/out/huge" --artifact "$C" --root "$T/root" --references "$REF" --mode strict --build-evidence "$T/huge.json"
exit_is 4 'oversized build evidence'; error_in oversized-input "$T/out/huge" 'oversized'
{ printf '{"schema": 1, "kind": "objc-build-evidence", "artifact": {"sha256": "%s"}, "source": {}, "extra": 1}\n' "$(sha "$C")"; } >"$T/extra.json"
run "$T/out/extrakey" --artifact "$C" --root "$T/root" --references "$REF" --mode strict --build-evidence "$T/extra.json"
exit_is 4 'unknown evidence key'; error_in malformed-build-evidence "$T/out/extrakey" 'unknown key'

# spec: tools/objc-compat/main.m header -- an unwritable destination directory: 4, nothing left behind.
mkdir -p "$T/ro"; chmod a-w "$T/ro"
run "$T/ro/report" --artifact "$C" --root "$T/root" --references "$REF" --mode strict
exit_is 4 'unwritable destination'
[ -z "$(ls -A "$T/ro")" ] || fail 'a failed write left something behind'
chmod u+w "$T/ro"

# spec: tools/objc-compat/main.m header -- a run killed mid-analysis leaves no report (the large real artifact gives time to kill it).
if [ -n "${MAVERGREEN_OBJC_CODEX_ARTIFACT:-}" ]; then
  sh "$ROOT/scripts/objc-compat-build.sh" --analyzer "$T/analyzer" 2>/dev/null || fail 'analyzer did not build'
  mkdir -p "$T/root/codex" "$T/killed"
  ln "$MAVERGREEN_OBJC_CODEX_ARTIFACT" "$T/root/codex/codex" 2>/dev/null || cp "$MAVERGREEN_OBJC_CODEX_ARTIFACT" "$T/root/codex/codex"
  "$T/analyzer" --artifact "$T/root/codex/codex" --root "$T/root" --references "$REF" --report "$T/killed/report" --mode strict 2>/dev/null &
  pid=$!
  # platform: the fixed delay only needs to land inside a run that takes many seconds.
  sleep 3
  kill -9 "$pid" 2>/dev/null || :
  wait "$pid" 2>/dev/null || :
  [ ! -e "$T/killed/report" ] || fail 'a killed run left a report'
fi
echo 'objc-report: canonical schema-1 reports, exit codes, destinations and input bounds pass'
