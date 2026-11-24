#!/bin/sh
# platform: host-agnostic -- hashes committed files only; ibtool never runs here
#   usage: fixtures-current-test.sh
#          every XIB under tests/resources/fixtures/xib has a MANIFEST.tsv row, and every row's XIB and
#          output still hash as they did when nib-fixtures.yml compiled them; a row whose output_sha256
#          is "refused" records an ibtool refusal, and its output must not exist
set -u
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures"
MAN="$FIX/MANIFEST.tsv"
status=0
stale() { echo "FAIL: $1 changed since its nib was compiled: dispatch nib-fixtures.yml (ask shipyard for a macOS slot) and commit its outputs"; status=1; }
sha() { { shasum -a 256 < "$1" 2>/dev/null || sha256sum < "$1"; } | cut -d' ' -f1; }

xibs="$(cd "$FIX" && ls xib/*.xib xib/*.storyboard 2>/dev/null)"
[ -n "$xibs" ] || { echo "FAIL: no XIBs under $FIX/xib"; exit 1; }
if [ ! -f "$MAN" ]; then
  for x in $xibs; do stale "$x"; done
  echo "FAIL: no $MAN"
  exit 1
fi

TAB="$(printf '\t')"
for x in $xibs; do
  awk -F"$TAB" -v x="$x" 'NR > 1 && $1 == x { found = 1 } END { exit !found }' "$MAN" || stale "$x"
done

rows=0
while IFS="$TAB" read -r xib xsha out osha _ver _args; do
  [ "$xib" = xib_path ] && continue
  rows=$((rows + 1))
  if [ ! -f "$FIX/$xib" ] || [ "$(sha "$FIX/$xib")" != "$xsha" ]; then stale "$xib"; continue; fi
  if [ "$osha" = refused ]; then
    [ ! -e "$FIX/$out" ] || { echo "FAIL: $out exists, but MANIFEST.tsv records that ibtool refused it"; status=1; }
    continue
  fi
  if [ ! -f "$FIX/$out" ] || [ "$(sha "$FIX/$out")" != "$osha" ]; then
    echo "FAIL: $out is not the output MANIFEST.tsv records for $xib: commit nib-fixtures.yml's outputs as they came"
    status=1
  fi
done < "$MAN"
[ "$rows" -gt 0 ] || { echo "FAIL: $MAN has no rows"; status=1; }

[ "$status" -ne 0 ] || echo "PASS: $rows MANIFEST.tsv rows match their XIBs and outputs"
exit "$status"
