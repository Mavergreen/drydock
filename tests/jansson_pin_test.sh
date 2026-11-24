#!/bin/sh
# platform: host-agnostic -- a file:// codeload tree and a scratch git upstream stand in for GitHub
#   usage: jansson_pin_test.sh
#          scripts/pin-jansson.sh writes components/jansson/version's SHA256 line only from a tarball
#          whose tree equals the pinned commit's git archive, and fill answers only when REF or
#          DIGEST moved and SHA256 is stale
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
git --version >/dev/null 2>&1 || { echo "SKIP jansson_pin_test: no git that runs"; exit 77; }
[ -f "$ROOT/scripts/pin-jansson.sh" ] || { echo "FAIL: scripts/pin-jansson.sh does not exist"; exit 1; }
fail() { echo "FAIL: $1"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/drydock-jansson-pin.XXXXXX")"; trap 'rm -rf "$t"' EXIT INT TERM
PIN=components/jansson
up="$t/up/akheron/jansson.git"
cl="$t/cl/akheron/jansson/tar.gz"
mkdir -p "$up" "$cl" "$t/repo/scripts" "$t/repo/build" "$t/repo/$PIN"
cp "$ROOT/scripts/pin-jansson.sh" "$t/repo/scripts/"
cp "$ROOT/build/msc.sh" "$t/repo/build/"
u() { git -C "$up" -c user.name=t -c user.email=t@t "$@"; }
u init -q; u config uploadpack.allowAnySHA1InWant true
printf 'one\n' > "$up/a.c"; u add a.c; u commit -q -m one; d1="$(u rev-parse HEAD)"
printf 'two\n' > "$up/a.c"; printf 'x\n' > "$up/b.c"; u add a.c b.c; u commit -q -m two; d2="$(u rev-parse HEAD)"
for d in "$d1" "$d2"; do u archive --format=tar.gz --prefix="jansson-$d/" -o "$cl/$d" "$d"; done
sha_of() { s="$(shasum -a 256 "$1" 2>/dev/null || sha256sum "$1")"; echo "${s%% *}"; }
sha1="$(sha_of "$cl/$d1")"; sha2="$(sha_of "$cl/$d2")"
version() { printf 'REPO=https://github.com/akheron/jansson.git\nREF=%s\nDIGEST=%s\nSHA256=%s\n' "$1" "$2" "$3"; }
version v1 "$d1" "$sha1" > "$t/repo/$PIN/version"
export MAVERICKS_CODELOAD="file://$t/cl" DRYDOCK_PIN_GIT_BASE="file://$t/up" MAVERICKS_BUILD_ROOT="$t/work"
P="$t/repo/scripts/pin-jansson.sh"
g() { git -C "$t/repo" -c user.name=t -c user.email=t@t "$@"; }
g init -q; g add -A; g commit -q -m base; g branch -q base

out="$(sh "$P" fill base)" && [ -z "$out" ] || fail "fill must succeed and print nothing when $PIN/version did not move"
version v2 "$d2" "$sha1" > "$t/repo/$PIN/version"; g commit -q -am bump
[ "$(sh "$P" values)" = "$sha2" ] || fail "values must print the tarball's sha256"
[ "$(sh "$P" fill base)" = "$sha2" ] || fail "fill must print the tarball's sha256 when DIGEST moved and SHA256 is stale"
before="$(cat "$t/repo/$PIN/version")"
sh "$P" apply "$sha2"
after="$(cat "$t/repo/$PIN/version")"
[ "$(printf '%s\n' "$before" | grep -v '^SHA256=')" = "$(printf '%s\n' "$after" | grep -v '^SHA256=')" ] || fail "apply must change only the SHA256= line"
[ "$(printf '%s\n' "$after" | grep '^SHA256=')" = "SHA256=$sha2" ] || fail "apply must write the SHA256= line"
g commit -q -am pin
out="$(sh "$P" fill base)" && [ -z "$out" ] || fail "fill must succeed and print nothing once SHA256 is current"
cp "$t/repo/$PIN/version" "$t/kept"
if sh "$P" apply nothex 2>/dev/null; then fail "apply must refuse a value that is not a SHA-256"; fi
cmp -s "$t/kept" "$t/repo/$PIN/version" || fail "a refused apply must leave the pin as it was"

version v2 "$d2" "$sha1" > "$t/repo/$PIN/version"; g commit -q -am stale
mkdir "$t/evil"; tar -xzf "$cl/$d2" -C "$t/evil"; printf 'evil\n' >> "$t/evil/jansson-$d2/a.c"
tar -czf "$cl/$d2" -C "$t/evil" "jansson-$d2"
out="$(sh "$P" fill base 2>/dev/null)" && fail "fill must refuse a tarball whose tree differs from the commit's git archive"
[ -z "$out" ] || fail "a refused fill must print nothing"
if sh "$P" values >/dev/null 2>&1; then fail "values must refuse a tarball whose tree differs from the commit's git archive"; fi
rm -rf "$up"
if sh "$P" values >/dev/null 2>&1; then fail "values must fail closed when the commit cannot be fetched"; fi
echo "PASS: jansson_pin_test"
