#!/bin/sh
# platform: host-agnostic -- a file:// release and a scratch git repo stand in for GitHub
#   usage: linux_pin_test.sh
#          scripts/pin-linux-clang.sh writes components/objc-receipt-clang/linux-sha256 only from bytes
#          it verified against the pinned release's SHA256SUMS, only for the version this checkout
#          pins, and fill answers only when that version moved and the digest is stale
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
git --version >/dev/null 2>&1 || { echo "SKIP linux_pin_test: no git that runs"; exit 77; }
[ -f "$ROOT/scripts/pin-linux-clang.sh" ] || { echo "FAIL: scripts/pin-linux-clang.sh does not exist"; exit 1; }
fail() { echo "FAIL: $1"; exit 1; }
t="$(mktemp -d "${TMPDIR:-/tmp}/drydock-linux-pin.XXXXXX")"; trap 'rm -rf "$t"' EXIT INT TERM
V=22.1.8-mavericks.99
PIN=components/objc-receipt-clang
rel="$t/rel/Mavergreen/clang-22/releases/download/$V"
mkdir -p "$t/repo/scripts" "$t/repo/build" "$t/repo/$PIN" "$rel"
cp "$ROOT/scripts/pin-linux-clang.sh" "$t/repo/scripts/"
cp "$ROOT/build/msc.sh" "$t/repo/build/"
cp "$ROOT/$PIN/version" "$ROOT/$PIN/linux-sha256" "$t/repo/$PIN/"
asset="clang22-$V-linux-x86_64.tar.gz"
printf fixture > "$rel/$asset"
sha="$(shasum -a 256 "$rel/$asset" 2>/dev/null || sha256sum "$rel/$asset")"; sha="${sha%% *}"
{ printf '%064d  %s\n' 1 "clang22-$V-macos.pkg"; printf '%s  %s\n' "$sha" "$asset"; } > "$rel/SHA256SUMS"
export MAVERGREEN_RELEASES="file://$t/rel" MAVERICKS_BUILD_ROOT="$t/work"
P="$t/repo/scripts/pin-linux-clang.sh"
g() { git -C "$t/repo" -c user.name=t -c user.email=t@t "$@"; }
g init -q; g add -A; g commit -q -m base; g branch -q base

out="$(sh "$P" fill base)" && [ -z "$out" ] || fail "fill must succeed and print nothing when $PIN/version did not move"
printf '%s\n' "$V" > "$t/repo/$PIN/version"; g commit -q -am bump
[ "$(sh "$P" values)" = "$V $sha" ] || fail "values must print the version and its verified digest"
[ "$(sh "$P" fill base)" = "$V $sha" ] || fail "fill must print the new pin when the version moved and the digest is stale"
sh "$P" apply "$V" "$sha"
[ "$(cat "$t/repo/$PIN/linux-sha256")" = "$sha  $asset" ] || fail "apply must write the SHA256SUMS line for $asset"
g commit -q -am pin
out="$(sh "$P" fill base)" && [ -z "$out" ] || fail "fill must succeed and print nothing once the digest is current"
if sh "$P" apply 22.1.8-mavericks.98 "$sha" 2>/dev/null; then fail "apply must refuse a version this checkout does not pin"; fi
if sh "$P" apply "$V" nothex 2>/dev/null; then fail "apply must refuse a value that is not a SHA-256"; fi
[ "$(cat "$t/repo/$PIN/linux-sha256")" = "$sha  $asset" ] || fail "a refused apply must leave linux-sha256 as it was"
rm -rf "$t/work"
printf '%064d  %s\n' 0 "$asset" > "$rel/SHA256SUMS"
if sh "$P" values >/dev/null 2>&1; then fail "values must refuse a digest the release's bytes do not match"; fi
printf '%064d  %s\n' 1 "clang22-$V-macos.pkg" > "$rel/SHA256SUMS"
if sh "$P" values >/dev/null 2>&1; then fail "values must refuse a release whose SHA256SUMS does not list $asset"; fi
echo "PASS: linux_pin_test"
