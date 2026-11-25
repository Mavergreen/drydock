#!/bin/sh
# platform: host-agnostic -- runs equivalence.sh compare on hand-made output directories
# spec: compare refuses two outputs made by one drydock-macho-rewrite running one arch, and accepts one universal
#   file run as two arches, as the 10.9 guest and modern-smoke both run the installed universal tool.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/eqcmp.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
mk() {  # DIR IDENTITY: an output directory of 25 outputs, the fewest compare accepts, made by IDENTITY
  mkdir -p "$T/$1" && for f in $(seq 1 25); do echo "$f" > "$T/$1/o$f"; done && echo "$2" > "$T/$1/drydock.sha256"
}
mk x86 "abc x86_64"; mk arm "abc arm64"; mk again "abc x86_64"
sh "$HERE/equivalence.sh" compare "$T/x86" "$T/arm" > "$T/ok.out" 2>&1 \
  && echo "PASS one universal file run as two arches is compared" \
  || { echo "FAIL one universal file run as two arches was refused: $(cat "$T/ok.out")"; fails=$((fails + 1)); }
sh "$HERE/equivalence.sh" compare "$T/x86" "$T/again" > "$T/same.out" 2>&1 \
  && { echo "FAIL one file running one arch was compared with itself"; fails=$((fails + 1)); } \
  || { grep -q 'were made by the same drydock-macho-rewrite binary, running the same arch' "$T/same.out" \
    && echo "PASS one file running one arch is refused, saying why" \
    || { echo "FAIL the refusal does not say why: $(cat "$T/same.out")"; fails=$((fails + 1)); }; }
[ "$fails" = 0 ]
