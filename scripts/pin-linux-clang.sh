#!/bin/sh
# platform: host-agnostic
#   usage: pin-linux-clang.sh values | apply VERSION SHA256 | fill BASE_REF
#          values: prints the version components/objc-receipt-clang pins and its Linux archive's
#          digest, after verifying the archive against that release's SHA256SUMS.
#          apply: writes components/objc-receipt-clang/linux-sha256, for this checkout's version only.
#          fill: when components/objc-receipt-clang/version moved since BASE_REF and linux-sha256 is
#          stale, prints what values prints; else nothing.
#          .github/workflows/pins-bot.yml runs fill in a read-only job and apply in the one that pushes.
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/build/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
PIN_DIR="$REPO_ROOT/components/objc-receipt-clang"
VERSION="$(tr -d ' \t\n' < "$PIN_DIR/version")"
case "$VERSION" in ''|*[!a-zA-Z0-9._-]*) echo "pin-linux-clang.sh: invalid version '$VERSION' in $PIN_DIR/version" >&2; exit 2 ;; esac
asset="clang22-$VERSION-linux-x86_64.tar.gz"
pin="$PIN_DIR/linux-sha256"
valid_sha() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }
values() {
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/drydock-linux-pin.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
  base="${MAVERGREEN_RELEASES:-https://github.com}/Mavergreen/clang-22/releases/download/$VERSION"
  shipyard_curl "$base/SHA256SUMS" "$tmp/sums"
  sha="$(awk -v asset="$asset" '$2 == asset || $2 == "*" asset { print $1 }' "$tmp/sums")"
  valid_sha "$sha" || { echo "pin-linux-clang.sh: SHA256SUMS of $VERSION lists no valid digest for $asset" >&2; exit 1; }
  shipyard_fetch_verified "$base/$asset" "$sha" "${MAVERICKS_BUILD_ROOT:-${TMPDIR:-/tmp}/mm-build}/drydock-linux-pin/$VERSION" "$asset"
  printf '%s %s\n' "$VERSION" "$sha"
}
case "${1:-}" in
  values) [ $# -eq 1 ] || exit 2; values ;;
  apply)
    [ $# -eq 3 ] && [ "$2" = "$VERSION" ] && valid_sha "$3" || { echo "pin-linux-clang.sh: apply takes this checkout's version ($VERSION) and a SHA-256" >&2; exit 2; }
    printf '%s  %s\n' "$3" "$asset" > "$pin" ;;
  fill)
    [ $# -eq 2 ] || exit 2
    base="$(git -C "$REPO_ROOT" merge-base "$2" HEAD)"
    [ -n "$(git -C "$REPO_ROOT" diff "$base" HEAD -- components/objc-receipt-clang/version)" ] || exit 0
    new="$(values)"; hash=${new#* }
    [ ! -f "$pin" ] || [ "$(cat "$pin")" != "$hash  $asset" ] || exit 0
    printf '%s\n' "$new" ;;
  *) echo 'usage: pin-linux-clang.sh values | apply VERSION SHA256 | fill BASE_REF' >&2; exit 2 ;;
esac
