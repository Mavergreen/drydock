#!/bin/sh
# platform: host-agnostic -- every input is JSON written here; no fixture is compiled
# spec: README.md (drydock-objc input strictness) -- a duplicate key, an integer past long long, \u0000, a UTF-16
#       document, a schema that is not the integer 1, and a real source line or probe size are cannot-measure (exit 4)
#       with a malformed-* code, from analyze and link-args alike; the same inputs with the value written as an
#       integer are taken.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
: "${DRYDOCK_OBJC:?names the built drydock-objc (CTest sets it)}"
T=$(mktemp -d "${TMPDIR:-/tmp}/objc-strict-input-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0 n=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -c1-64; }
H=$(printf '%064d' 0)

mkdir -p "$T/root" "$T/ref"
printf 'not a Mach-O\n' > "$T/root/art"
cp "$ROOT"/reference/objc/* "$T/ref/"
# analyze ARGS...: a fresh report; rc, $T/err and $rep set
analyze() {
  n=$((n + 1)); rep="$T/report.$n"; rc=0
  "$DRYDOCK_OBJC" analyze --artifact "$T/root/art" --root "$T/root" --analyzer-id strict-input-test --report "$rep" "$@" \
    2>"$T/err" >/dev/null || rc=$?
}
# refused NAME CODE [SUBSTRING]: exit 4, stderr names CODE (with SUBSTRING), and the report is the cannot-measure one
refused() {
  if [ "$rc" = 4 ] && grep "^objc-compat: $2: " "$T/err" | grep -qF -- "${3:-}" && grep -q '"complete_within_boundary": false,' "$rep" 2>/dev/null &&
     grep -q "\"code\": \"$2\"" "$rep"; then pass "$1 ($(grep -m1 "^objc-compat: $2: " "$T/err"))"
  else fail "$1: wanted exit 4, $2 ${3:+$3 }on stderr and in a cannot-measure report; got exit $rc, stderr '$(cat "$T/err")'"; fi
}
# taken NAME CODE: CODE is not among the run's errors (the artifact, not a Mach-O, is still cannot-measure)
taken() {
  if [ -f "$rep" ] && ! grep -q "^objc-compat: $2: " "$T/err"; then pass "$1"
  else fail "$1: wanted no $2; got exit $rc, stderr '$(cat "$T/err")'"; fi
}

# strict_dup_key: a reference manifest with a duplicate key.
sed 's/"schema": *1,/"schema": 1, "schema": 1,/' "$ROOT/reference/objc/manifest.json" > "$T/ref/manifest.json"
grep -q '"schema": 1, "schema": 1,' "$T/ref/manifest.json" || fail "strict_dup_key: the fixture has no duplicate key"
analyze --references "$T/ref"; refused "strict_dup_key: a manifest with a duplicate key" malformed-input duplicate
cp "$ROOT/reference/objc/manifest.json" "$T/ref/manifest.json"

# strict_utf16: a manifest in UTF-16 is not read as JSON.
if command -v iconv >/dev/null 2>&1; then
  iconv -f UTF-8 -t UTF-16 "$ROOT/reference/objc/manifest.json" > "$T/ref/manifest.json"
  analyze --references "$T/ref"; refused "strict_utf16: a UTF-16 manifest" malformed-input
  cp "$ROOT/reference/objc/manifest.json" "$T/ref/manifest.json"
else echo "SKIP: strict_utf16: no iconv"; fi

# strict_schema_real: schema 1.0 or true is not the integer 1.
exc() { printf '{"schema":%s,"kind":"objc-exceptions","records":[{"id":"r"}]}\n' "$1" > "$T/exc.json"
        printf '%s\tr\treason\n' "$T/exc.json" > "$T/exc.list"; }
exc 1.0; analyze --references "$T/ref" --exceptions "$T/exc.list"; refused "strict_schema_real: exceptions schema 1.0" malformed-exception 'not schema-1 objc-exceptions'
exc true; analyze --references "$T/ref" --exceptions "$T/exc.list"; refused "strict_schema_real: exceptions schema true" malformed-exception 'not schema-1 objc-exceptions'
exc 1; analyze --references "$T/ref" --exceptions "$T/exc.list"
grep -q 'not schema-1 objc-exceptions' "$T/err" && fail "strict_schema_real: exceptions schema 1 was refused: $(cat "$T/err")" ||
  pass "strict_schema_real: exceptions schema 1 is schema 1"
ev() { printf '{"schema":%s,"kind":"objc-build-evidence","artifact":{"sha256":"%s"},"source":{}%s}\n' "$1" "$H" "${2:-}" > "$T/ev.json"; }
ev 1.0; analyze --references "$T/ref" --build-evidence "$T/ev.json"; refused "strict_schema_real: build evidence schema 1.0" malformed-build-evidence 'not schema-1 or schema-2'
ev 1; analyze --references "$T/ref" --build-evidence "$T/ev.json"; taken "strict_schema_real: build evidence schema 1 is taken" malformed-build-evidence

# strict_bigint: an integer past long long is malformed, not wrapped.
ev 18446744073709551617; analyze --references "$T/ref" --build-evidence "$T/ev.json"; refused "strict_bigint: schema 2^64+1" malformed-input 'too big'

# strict_source_line: a schema-1 guard's source line is an integer; a real is refused, not truncated.
ev 1 ',"guards":[{"id":"g","source":{"line":12.5}}]'
analyze --references "$T/ref" --build-evidence "$T/ev.json"; refused "strict_source_line: source line 12.5" malformed-build-evidence 'source line is not an integer'
ev 1 ',"guards":[{"id":"g","source":{"line":12}}]'
analyze --references "$T/ref" --build-evidence "$T/ev.json"; taken "strict_source_line: source line 12 is taken" malformed-build-evidence
ev 1 ',"guards":[{"id":"g","source":{}}]'
analyze --references "$T/ref" --build-evidence "$T/ev.json"; taken "strict_source_line: an absent source line is taken" malformed-build-evidence

# strict_probe_size: a provider atom's size is an integer; a real is refused, not truncated.
P="$T/prefix"; mkdir -p "$P/share/recaulk" "$P/lib"
printf 'archive\n' > "$P/lib/libp.a"; printf 'r' > "$T/receipt"
decl() { printf '{"schema":1,"providers":[{"provider_id":"%s","class":"Foo","method_kind":"-","selector":"bar","encoding":"v16@0:8","implementation_symbol":"foo_bar","activation_root":"foo_root","required_frameworks":["Foundation"],"framework_policy":"strong-linked-before-root"}],"build":{"archive_path":"lib/libp.a","archive_sha256":"%s","architecture":"x86_64","artifact_role":"shipping","minimum_macos":"10.9","sdk_settings_sha256":"%s","compiler_identity":"cc","source_inputs_receipt":"r","source_inputs_sha256":"%s"}}\n' \
  "$1" "$(sha "$P/lib/libp.a")" "$H" "$(sha "$T/receipt")" > "$P/share/recaulk/objc-providers.json"; }
decl p.one
atom() { ev 1 ",\"providers\":[{\"provider_id\":\"p.one\",\"declaration_sha256\":\"$H\",\"archive_sha256\":\"$H\",\"members\":[],\"atoms\":[{\"member\":\"m.o\",\"symbol\":\"_s\",\"address\":\"0x10\",\"size\":$1}]}]"; }
atom 12.5; analyze --references "$T/ref" --provider-prefix "$P" --build-evidence "$T/ev.json"
refused "strict_probe_size: atom size 12.5" malformed-build-evidence 'provider p.one atom'
atom 12; analyze --references "$T/ref" --provider-prefix "$P" --build-evidence "$T/ev.json"
taken "strict_probe_size: atom size 12 is taken" malformed-build-evidence

# strict_nul: link-args refuses a declaration holding \u0000 and prints nothing.
decl 'p\u0000x'
rc=0; "$DRYDOCK_OBJC" link-args --prefix "$P" --link-map "$T/map" >"$T/out" 2>"$T/err" || rc=$?
if [ "$rc" = 4 ] && grep -q '^objc-compat: malformed-input: provider declaration ' "$T/err" && [ ! -s "$T/out" ]; then
  pass "strict_nul: a provider declaration with \\u0000 ($(cat "$T/err"))"
else fail "strict_nul: wanted exit 4, malformed-input and no output; got exit $rc, stdout '$(cat "$T/out")', stderr '$(cat "$T/err")'"; fi
decl p.one
rc=0; "$DRYDOCK_OBJC" link-args --prefix "$P" --link-map "$T/map" >"$T/out" 2>"$T/err" || rc=$?
[ "$rc" = 0 ] && grep -qx -- '-Wl,-u,_foo_root' "$T/out" && pass "strict_nul: the same declaration without it is read" ||
  fail "strict_nul: the clean declaration: exit $rc, stdout '$(cat "$T/out")', stderr '$(cat "$T/err")'"

[ "$fails" -eq 0 ] || { echo "objc-strict-input-test: $fails failed"; exit 1; }
echo "objc-strict-input-test: all passed"
