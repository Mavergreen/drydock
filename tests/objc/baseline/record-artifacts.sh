#!/bin/sh
# platform: macOS-only -- runs a built drydock-objc on binaries built or kept on the maintainer's 10.9 box
#   usage: record-artifacts.sh DRYDOCK_OBJC REFERENCES BASELINE_DIR NAME ARTIFACT PROVIDER_PREFIX [NAME ARTIFACT PROVIDER_PREFIX]...
#          record.sh's counterpart for a bare drydock-objc: records what DRYDOCK_OBJC analyze --mode strict
#          says about each ARTIFACT (with --provider-prefix PROVIDER_PREFIX unless it is "-") against the
#          reference set REFERENCES, so compare.sh can rerun a later drydock-objc over the same artifacts.
#          Use it when record.sh's Codex build products are gone. Writes, under BASELINE_DIR (created if
#          absent; INPUTS must not exist yet):
#            NAME.objc-compat.json   the report
#            NAME.exit               the run's exit status: data, never a failure of this script
#            NAME.stderr             the run's stderr
#            INPUTS                  the analyzer and reference set that ran, then one "artifact" row per
#                                    ARTIFACT: NAME, SHA-256, path, provider prefix ("-" for none)
#          Exit 0 recorded, 2 usage, 4 a missing artifact or input. Refuses an existing report.
set -eu

usage() { echo "usage: record-artifacts.sh DRYDOCK_OBJC REFERENCES BASELINE_DIR NAME ARTIFACT PROVIDER_PREFIX..." >&2; exit 2; }
[ $# -ge 6 ] && [ $(( ($# - 3) % 3 )) -eq 0 ] || usage
DRYDOCK_OBJC=$1
REFS=$(CDPATH= cd -- "$2" 2>/dev/null && pwd) || { echo "record-artifacts.sh: no $2" >&2; exit 4; }
BASELINE_DIR=$3
shift 3
fail() { echo "record-artifacts.sh: $*" >&2; exit 4; }
sha() { shasum -a 256 "$1" | cut -c1-64; }
[ -x "$DRYDOCK_OBJC" ] || fail "no executable $DRYDOCK_OBJC"
[ -f "$REFS/manifest.json" ] || fail "$REFS has no manifest.json"

mkdir -p "$BASELINE_DIR"
INPUTS="$BASELINE_DIR/INPUTS"
[ ! -e "$INPUTS" ] || fail "$INPUTS exists: record into an empty BASELINE_DIR"
# spec: compare.sh -- a "drydock-objc" first row marks a baseline of "artifact" rows, not record.sh's Codex set
printf 'drydock-objc\t%s\t%s\n' "$(sha "$DRYDOCK_OBJC")" "$DRYDOCK_OBJC" > "$INPUTS"
printf 'references\t%s\t%s\n' "$(sha "$REFS/manifest.json")" "$REFS" >> "$INPUTS"

# record NAME ARTIFACT PREFIX: run the analyzer, keep report, exit and stderr
record() {
  name=$1 art=$2 prefix=$3
  case "$name" in *[!A-Za-z0-9._-]*|'') fail "bad name $name" ;; esac
  [ -f "$art" ] || fail "no $art"
  [ "$prefix" = - ] || [ -d "$prefix" ] || fail "no provider prefix $prefix"
  report="$BASELINE_DIR/$name.objc-compat.json"
  [ ! -e "$report" ] || fail "$report exists: a report is never replaced"
  set -- --artifact "$art" --root "$(dirname "$art")" --references "$REFS" --report "$report" --mode strict
  [ "$prefix" = - ] || set -- "$@" --provider-prefix "$prefix"
  rc=0
  "$DRYDOCK_OBJC" analyze "$@" 2> "$BASELINE_DIR/$name.stderr" || rc=$?
  printf '%s\n' "$rc" > "$BASELINE_DIR/$name.exit"
  printf 'artifact\t%s\t%s\t%s\t%s\n' "$name" "$(sha "$art")" "$art" "$prefix" >> "$INPUTS"
  echo "record-artifacts.sh: $name: exit $rc" >&2
}

while [ $# -gt 0 ]; do
  record "$1" "$2" "$3"
  shift 3
done
