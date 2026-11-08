#!/bin/sh
# platform: macOS-only -- runs shipyard's Objective-C analyzer on binaries built on the maintainer's 10.9 box
#   usage: record.sh SHIPYARD_SCRIPTS BASELINE_DIR
#          Records, before the analyzer moves into Drydock, what shipyard's scripts/objc-compat.sh
#          --mode strict says about each artifact below, so a later task can compare the moved
#          analyzer's reports with these. Writes, under BASELINE_DIR (created if absent):
#            NAME.objc-compat.json   the report
#            NAME.exit               the run's exit status: data, never a failure of this script
#            NAME.stderr             the run's stderr
#            INPUTS                  each artifact's path and SHA-256, and the shipyard that ran
#          NAME is codex-original (only when MAVERGREEN_OBJC_CODEX_ARTIFACT names the 0.165.0
#          binary; skipped with a note otherwise), codex-rebuilt, code-mode-host, alacritty-probe.
#          Environment: CODEX_CLI_DIR (default ~/Library/Caches/codex-int-work/codex-cli),
#          CODEX_BUILD_DIR (default ~/Library/Caches/codex-int-build),
#          CODEX_DEV_RECAULK_PREFIX (passed to fetch-recaulk-objc.sh, which needs it until a
#          Recaulk is pinned), CODEX_SOURCE_RECEIPT (the source receipt for codex-rebuilt, instead
#          of the prefix's own: the analyzer refuses a receipt written by another inventory tool,
#          so one is generated with this shipyard's objc-source-inventory.sh), ALACRITTY_PROBE.
#          Exit 0 recorded, 2 usage, 4 a missing artifact or input. Refuses an existing report.
set -eu

usage() { echo "usage: record.sh SHIPYARD_SCRIPTS BASELINE_DIR" >&2; exit 2; }
[ $# -eq 2 ] || usage
SHIPYARD_SCRIPTS=$(CDPATH= cd -- "$1" 2>/dev/null && pwd) || { echo "record.sh: no $1" >&2; exit 4; }
BASELINE_DIR=$2
fail() { echo "record.sh: $*" >&2; exit 4; }
sha() { shasum -a 256 "$1" | cut -c1-64; }

CODEX_CLI_DIR=${CODEX_CLI_DIR:-$HOME/Library/Caches/codex-int-work/codex-cli}
CODEX_BUILD_DIR=${CODEX_BUILD_DIR:-$HOME/Library/Caches/codex-int-build}
ALACRITTY_PROBE=${ALACRITTY_PROBE:-$HOME/Library/Caches/alacritty-port.U9AoTJ/build/compat-probe/alacritty}
ORIGINAL_SHA256=1d056b0d4ada3d74b4c0f4c5450bc06856bfdbc504320fa430a4249f640f6c40

REFS=$(CDPATH= cd -- "$SHIPYARD_SCRIPTS/../reference/objc" 2>/dev/null && pwd) || fail "shipyard at $SHIPYARD_SCRIPTS has no reference/objc"
NATIVE="$CODEX_BUILD_DIR/codex-native"
EVIDENCE="$CODEX_BUILD_DIR/objc-native/evidence"
ORIGINAL_EVIDENCE="$SHIPYARD_SCRIPTS/../tests/fixtures/objc-api/codex-0.165.0-build-evidence.json"

# spec: shipyard's version is the commit of the checkout the scripts live in
SHIPYARD_REV=$(git -C "$SHIPYARD_SCRIPTS" rev-parse HEAD 2>/dev/null) || fail "$SHIPYARD_SCRIPTS is not in a git checkout"

for f in "$NATIVE/codex" "$NATIVE/codex-code-mode-host" "$EVIDENCE/codex.json" "$EVIDENCE/codex-code-mode-host.json" "$ALACRITTY_PROBE"; do
  [ -f "$f" ] || fail "no $f"
done

# spec: build/fetch-recaulk-objc.sh -- line 1 of its stdout is the provider prefix
PREFIX=$(SHIPYARD_SCRIPTS=$SHIPYARD_SCRIPTS sh "$CODEX_CLI_DIR/build/fetch-recaulk-objc.sh" 2>/dev/null | sed -n 1p) || PREFIX=
[ -n "$PREFIX" ] && [ -d "$PREFIX" ] || fail "no provider prefix from $CODEX_CLI_DIR/build/fetch-recaulk-objc.sh (set CODEX_DEV_RECAULK_PREFIX)"
RECEIPT=${CODEX_SOURCE_RECEIPT:-$PREFIX/share/recaulk/objc-source.receipt}
[ -f "$RECEIPT" ] || { [ -z "${CODEX_SOURCE_RECEIPT:-}" ] || fail "no $CODEX_SOURCE_RECEIPT"; RECEIPT=; }

mkdir -p "$BASELINE_DIR"
INPUTS="$BASELINE_DIR/INPUTS"
[ ! -e "$INPUTS" ] || fail "$INPUTS exists: record into an empty BASELINE_DIR"
printf 'shipyard\t%s\t%s\n' "$SHIPYARD_REV" "$SHIPYARD_SCRIPTS" > "$INPUTS"
[ -z "$RECEIPT" ] || printf 'source-receipt\t%s\t%s\n' "$(sha "$RECEIPT")" "$RECEIPT" >> "$INPUTS"

# record NAME ARTIFACT ARGS...: run the analyzer, keep report, exit and stderr
record() {
  name=$1; art=$2; shift 2
  report="$BASELINE_DIR/$name.objc-compat.json"
  [ ! -e "$report" ] || fail "$report exists: shipyard never replaces a report"
  # spec: shipyard scripts/objc-compat.sh -- each report names its binary relative to --root, here its directory
  rc=0
  sh "$SHIPYARD_SCRIPTS/objc-compat.sh" --artifact "$art" --root "$(dirname "$art")" --references "$REFS" \
    --report "$report" --mode strict "$@" 2> "$BASELINE_DIR/$name.stderr" || rc=$?
  printf '%s\n' "$rc" > "$BASELINE_DIR/$name.exit"
  printf '%s\t%s\t%s\n' "$name" "$(sha "$art")" "$art" >> "$INPUTS"
  echo "record.sh: $name: exit $rc" >&2
}

if [ -n "${MAVERGREEN_OBJC_CODEX_ARTIFACT:-}" ] && [ -f "$MAVERGREEN_OBJC_CODEX_ARTIFACT" ] &&
   [ "$(sha "$MAVERGREEN_OBJC_CODEX_ARTIFACT")" = "$ORIGINAL_SHA256" ]; then
  [ -f "$ORIGINAL_EVIDENCE" ] || fail "no $ORIGINAL_EVIDENCE"
  record codex-original "$MAVERGREEN_OBJC_CODEX_ARTIFACT" --build-evidence "$ORIGINAL_EVIDENCE"
else
  echo "record.sh: note: skipping codex-original: MAVERGREEN_OBJC_CODEX_ARTIFACT does not name the 0.165.0 binary" >&2
fi
if [ -n "$RECEIPT" ]; then
  record codex-rebuilt "$NATIVE/codex" --build-evidence "$EVIDENCE/codex.json" --provider-prefix "$PREFIX" --source-receipt "$RECEIPT"
else
  record codex-rebuilt "$NATIVE/codex" --build-evidence "$EVIDENCE/codex.json" --provider-prefix "$PREFIX"
fi
record code-mode-host "$NATIVE/codex-code-mode-host" --build-evidence "$EVIDENCE/codex-code-mode-host.json"
record alacritty-probe "$ALACRITTY_PROBE"
