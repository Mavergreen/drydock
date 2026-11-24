#!/bin/sh
# platform: host-agnostic -- a farm of symlinks and the CTestTestfile.cmake this build wrote.
#   usage: tool_dir_test.sh BIN BUILD_BIN TOOLDIR CTESTFILE HANDED
#          BIN is the bindir the suites are handed, BUILD_BIN this build's own, TOOLDIR the configured
#          DRYDOCK_TOOL_DIR (empty when unset), HANDED the tests CMake registered with BIN as an argument.
#          With DRYDOCK_TOOL_DIR in the environment, as on-target's installed pass sets it, a build that
#          ignored it fails here.
set -u
BIN=${1?usage: tool_dir_test.sh BIN BUILD_BIN TOOLDIR CTESTFILE HANDED}
BUILD_BIN=${2?} TOOLDIR=${3?} CTESTFILE=${4?} HANDED=${5?}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/tool-dir-test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }

# A stub of every installed name, each exiting 99: run through a farm of it, the suites must fail.
mkdir "$T/stub" "$T/helper"
stub() { printf '#!/bin/sh\necho "stub $0" >&2\nexit 99\n' >"$T/stub/$1" && chmod +x "$T/stub/$1"; }
stub drydock-macho-rewrite; stub drydock-objc; stub drydock-resources; stub drydock-macho-rewrite-compat.sh; stub drydock-macho-rewrite-translate.sh
for w in "$ROOT"/compat/*.sh; do
  case ${w##*/} in translate.sh|drydock-macho-rewrite-compat.sh) ;; *) n=${w##*/}; stub "${n%.sh}" ;; esac
done
: >"$T/helper/makefat"
sh "$ROOT/tests/lib/tool-dir.sh" "$T/farm" "$T/stub" "$T/helper/makefat" >/dev/null 2>"$T/err" \
  && [ "$T/farm/patch_macho" -ef "$T/stub/patch_macho" ] && [ "$T/farm/makefat" -ef "$T/helper/makefat" ] \
  && ok "the farm holds the tool dir's tools and the build's helpers" || bad "the farm: $(cat "$T/err")"
rc=0; "$T/farm/drydock-macho-rewrite" --capabilities 2>/dev/null || rc=$?
[ "$rc" = 99 ] && ok "the farm's drydock-macho-rewrite is the stub (99)" || bad "the farm's drydock-macho-rewrite exited $rc, not the stub's 99"
stubbed() {  # SCRIPT WANT [ARG]: SCRIPT, handed the stub farm, fails saying WANT
  rc=0; sh "$ROOT/tests/$1" "$T/farm" ${3:+"$3"} >"$T/out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 77 ] && grep -q "$2" "$T/out" \
    && ok "$1, handed the stub farm, runs the stub and fails ($rc)" || bad "$1, handed the stub farm, exited $rc: $(tail -3 "$T/out")"
}
stubbed characterize.sh "^stub .*/farm/" check
stubbed known-callers.sh "exit 99"
mkdir "$T/empty"
sh "$ROOT/tests/lib/tool-dir.sh" "$T/farm2" "$T/empty" >"$T/out" 2>&1 \
  && bad "a tool dir with no drydock-macho-rewrite made a farm" || ok "a tool dir with no drydock-macho-rewrite is refused"
: >"$T/helper/patch_macho"
sh "$ROOT/tests/lib/tool-dir.sh" "$T/farm3" "$T/stub" "$T/helper/patch_macho" >"$T/out" 2>&1 \
  && bad "a helper the tool dir also has was linked" || ok "a helper the tool dir also has is refused, so the tool dir's is not shadowed"

# What this build hands its tests. The oracles, raise_corpus, hdrref and installed_layout_test test this build
# itself; this test is handed its bindir only to name it.
BUILD_ONLY="hdrref_table_rule_test installed_layout_test raise_oracle_counts_test rebase_oracle_test tool_dir_test x86len_oracle_test"
tests_with() {  # the tests whose add_test line holds the text $1
  awk -v s="$1" '/^add_test\(/ && index($0, s) { n = $1; sub(/^add_test\(/, "", n); print n }' "$CTESTFILE" | LC_ALL=C sort
}
but_build_only() { for t in $1; do case " $BUILD_ONLY " in *" $t "*) ;; *) echo "$t" ;; esac; done | LC_ALL=C sort | tr '\n' ' '; }
want=$(but_build_only "$HANDED") got=$(but_build_only "$(tests_with " \"$BIN\"")")
[ -n "$want" ] && [ "$got" = "$want" ] && ok "the tests handed $BIN are the ones CMake registered with it: $want" \
  || bad "handed $BIN: '$got', but CMake registered '$want'"
for t in characterize translate_test known_callers; do  # registered with the bindir on every platform
  case " $got" in *" $t "*) ok "the parse finds $t" ;; *) bad "the parse of $CTESTFILE misses $t" ;; esac
done
if [ -n "${DRYDOCK_TOOL_DIR:-}" ] && [ "$TOOLDIR" != "$DRYDOCK_TOOL_DIR" ]; then
  bad "DRYDOCK_TOOL_DIR is $DRYDOCK_TOOL_DIR, but this build was configured with '$TOOLDIR': the build ignores it"
fi
if [ -z "$TOOLDIR" ]; then
  [ "$BIN" = "$BUILD_BIN" ] && ok "no DRYDOCK_TOOL_DIR: the suites run this build's tools" || bad "no DRYDOCK_TOOL_DIR, yet the suites are handed $BIN"
  echo "N/A the installed tools: no DRYDOCK_TOOL_DIR"
else
  [ "$BIN" != "$BUILD_BIN" ] && ok "the suites are not handed this build's bindir" || bad "DRYDOCK_TOOL_DIR is set, yet the suites are handed $BUILD_BIN"
  n=0
  for f in "$TOOLDIR"/*; do
    n=$((n + 1))
    [ "$BIN/${f##*/}" -ef "$f" ] || bad "$BIN/${f##*/} is not $f"
  done
  [ "$n" -ge 10 ] && ok "each of $TOOLDIR's $n tools is the one in $BIN" || bad "$TOOLDIR holds $n tools"
  got=$(tests_with " \"$BUILD_BIN\"" | tr '\n' ' ')
  [ "$got" = "$BUILD_ONLY " ] && ok "only $BUILD_ONLY are handed this build's bindir" || bad "handed this build's bindir: '$got', not '$BUILD_ONLY '"
  for t in drydock-macho-rewrite drydock-objc drydock-resources; do
    if [ -n "$(tests_with " \"$BUILD_BIN/$t\"")" ] || grep -F -e "=$BUILD_BIN/$t;" -e "=$BUILD_BIN/$t\"" "$CTESTFILE" >/dev/null; then
      bad "a test still runs $BUILD_BIN/$t"
    else
      ok "no test runs this build's $t"
    fi
  done
  echo "INFO this build's own programs, run by: $(tests_with " \"$BUILD_BIN/" | tr '\n' ' ')"
fi

echo "tool_dir_test: $fail failed"
[ "$fail" -eq 0 ]
