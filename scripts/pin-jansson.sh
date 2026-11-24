#!/bin/sh
# platform: host-agnostic
#   usage: pin-jansson.sh values | apply SHA256 | fill BASE_REF
#          values: prints the sha256 of GitHub's tarball of the commit components/jansson/version
#          pins, after checking that the tarball's tree is exactly the commit's git archive (a
#          shallow fetch of DIGEST from REPO); fails, printing nothing, on a mismatch or a failed fetch.
#          apply: rewrites only the SHA256= line of components/jansson/version.
#          fill: when REF or DIGEST moved since BASE_REF and SHA256 is stale, prints what values
#          prints; else nothing.
#          .github/workflows/pins-bot.yml runs fill in a read-only job and apply in the one that pushes.
#          MAVERICKS_CODELOAD (shipyard's fetch_pinned_source.sh) and DRYDOCK_PIN_GIT_BASE (replaces
#          https://github.com for the git fetch) let a test serve file:// trees.
set -eu
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$REPO_ROOT/build/msc.sh"
. "$SHIPYARD_SCRIPTS/mavericks_fetch.sh"
pin="$REPO_ROOT/components/jansson/version"
field() { sed -n "s/^$1=//p" "$pin"; }
valid_sha() { case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -eq 64 ]; }
values() {
  repo="$(field REPO)"; digest="$(field DIGEST)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/drydock-jansson-pin.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
  url="$("$SHIPYARD_SCRIPTS/fetch_pinned_source.sh" --url "$repo" "$digest")" || exit 1
  shipyard_curl "$url" "$tmp/tarball" || { echo "pin-jansson.sh: cannot fetch $url" >&2; exit 1; }
  sha="$(shasum -a 256 "$tmp/tarball" 2>/dev/null || sha256sum "$tmp/tarball")"; sha="${sha%% *}"
  valid_sha "$sha" || { echo "pin-jansson.sh: cannot digest $url" >&2; exit 1; }
  git_url="${DRYDOCK_PIN_GIT_BASE:-https://github.com}/${repo#https://github.com/}"
  mkdir "$tmp/git" "$tmp/commit" "$tmp/tar"
  git -C "$tmp/git" init -q
  git -C "$tmp/git" fetch -q --depth 1 "$git_url" "$digest" || { echo "pin-jansson.sh: cannot fetch $digest from $git_url" >&2; exit 1; }
  [ "$(git -C "$tmp/git" rev-parse FETCH_HEAD)" = "$digest" ] || { echo "pin-jansson.sh: $git_url served another commit than $digest" >&2; exit 1; }
  git -C "$tmp/git" archive FETCH_HEAD | tar -xf - -C "$tmp/commit"
  tar -xzf "$tmp/tarball" -C "$tmp/tar" || { echo "pin-jansson.sh: $url is not a tarball" >&2; exit 1; }
  [ "$(ls -A "$tmp/tar" | wc -l | tr -d ' ')" -eq 1 ] || { echo "pin-jansson.sh: $url does not hold one top-level directory" >&2; exit 1; }
  diff -r "$tmp/commit" "$tmp/tar"/* >/dev/null || { echo "pin-jansson.sh: the tarball's tree is not the tree of $digest" >&2; exit 1; }
  printf '%s\n' "$sha"
}
case "${1:-}" in
  values) [ $# -eq 1 ] || exit 2; values ;;
  apply)
    [ $# -eq 2 ] && valid_sha "$2" || { echo "pin-jansson.sh: apply takes a SHA-256" >&2; exit 2; }
    new="$(mktemp "${TMPDIR:-/tmp}/drydock-jansson-pin.XXXXXX")"
    awk -v sha="$2" '/^SHA256=/ { print "SHA256=" sha; next } { print }' "$pin" > "$new" && cat "$new" > "$pin"
    rm -f "$new" ;;
  fill)
    [ $# -eq 2 ] || exit 2
    base="$(git -C "$REPO_ROOT" merge-base "$2" HEAD)"
    git -C "$REPO_ROOT" diff "$base" HEAD -- components/jansson/version | grep -q '^[-+]\(REF\|DIGEST\)=' || exit 0
    new="$(values)"
    [ "$(field SHA256)" != "$new" ] || exit 0
    printf '%s\n' "$new" ;;
  *) echo 'usage: pin-jansson.sh values | apply SHA256 | fill BASE_REF' >&2; exit 2 ;;
esac
