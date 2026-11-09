#!/bin/sh
# platform: macOS-only -- runs the built drydock-objc on upstream iTerm2 3.0.15's x86_64 binary, a maintainer test
#       (it needs the cached upstream zip; it skips with exit 77 where that is absent).
# spec: src/objc/main.m header -- inventory reports every error and exits 4 when the artifact is not measured
#       completely. The residue is exactly tests/objc/fixtures/iterm2-3.0.15.expected-errors, one
#       code<TAB>detail<TAB>address line per error, sorted: a new error and a vanished one both fail.
#       Every line is a computed producer, run-time class creation, swizzling or an IMP lookup, or a named
#       indirect-objc-entry refusal (variadic, uncounted, not known on every path, a hoisted table load, a store to a
#       global, or the method's own encoding returning nothing in that register).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
SHA=90e6f2bd3eb2d245f4ab2c9f856c627c8a1536bac024fb3989db417bc3147565
ZIP="${HOME}/Library/Caches/mavericks-sources/iTerm2-resources-3.0.15-$SHA.zip"
[ -f "$ZIP" ] || { echo "SKIP objc_iterm2_acceptance: $ZIP is not cached"; exit 77; }
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-iterm2-acceptance.XXXXXX")
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
EXPECTED=${ITERM2_EXPECTED_ERRORS:-$HERE/fixtures/iterm2-3.0.15.expected-errors}

# platform: the zip is untrusted input; it is extracted into this test's own directory.
[ "$(shasum -a 256 "$ZIP" | cut -c1-64)" = "$SHA" ] || fail 'the cached zip is not the one its name says'
mkdir "$T/x"
unzip -q "$ZIP" 'iTerm.app/*' -d "$T/x" || fail 'iTerm.app does not extract'
BIN="$T/x/iTerm.app/Contents/MacOS/iTerm2"
[ -f "$BIN" ] || fail 'no iTerm.app/Contents/MacOS/iTerm2'

rc=0
"$DRYDOCK_OBJC" analyze --artifact "$BIN" --root "$T/x" --references "$ROOT/reference/objc" --mode inventory \
  --report "$T/report" 2>"$T/err" || rc=$?
[ "$rc" = 4 ] || { tail -5 "$T/err" >&2; fail "inventory exits $rc, want 4 (not measured completely)"; }

# spec: src/objc/main.m header -- the report's errors list is its last key, one error per line.
tab=$(printf '\t')
sed -n 's/^ *{"code": "\([^"]*\)", "slice": [^,]*, "address": "\([^"]*\)", "detail": "\(.*\)"}[],}]*$/\1'"$tab"'\3'"$tab"'\2/p' "$T/report" |
  LC_ALL=C sort >"$T/got"
[ -s "$T/got" ] || fail 'no errors were read from the report'
[ "$(grep -c '^ *{"code": ' "$T/report")" -eq "$(wc -l <"$T/got")" ] || fail 'an error of the report was not read'
if ! cmp -s "$EXPECTED" "$T/got"; then
  diff "$EXPECTED" "$T/got" >&2 || true
  fail "iTerm2 3.0.15's errors are not those of $EXPECTED"
fi
echo "PASS: iTerm2 3.0.15 has exactly its $(wc -l <"$T/got" | tr -d ' ') expected errors"
