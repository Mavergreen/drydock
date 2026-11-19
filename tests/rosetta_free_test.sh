#!/bin/sh
# platform: host-agnostic -- git grep over the checkout; needs a real git, which stock 10.9 lacks (not-in-guest).
#   exec_arch_sweep_test owns tests/ for arch(1) launches; this owns the rest, and what no test launches.
#   The controls' planted rows live in tests/data/arch-launch-probes.txt, which neither scan reads.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SELF=tests/rosetta_free_test.sh
PROBES=tests/data/arch-launch-probes.txt
fail=0
say() { echo "FAIL $*"; fail=1; }

launches='arch[[:space:]]+-(x86_64|arm64)'
installs='install-rosetta'
rosetta_bullet='^- rosetta:'
hw='hw\.optional\.arm64'
cross_runs='run-repo-tests\.sh"?[[:space:]]+cross([[:space:]]|$)|ctest[[:space:]].*--preset[[:space:]]+cross([[:space:]"]|$)|(chained-fixups|apple_silicon_signing_test|characterize)\.sh"?[[:space:]]+"?\$\{?CROSS_BUILD_DIR|equivalence\.sh"?[[:space:]]+produce[[:space:]]+"?\$\{?CROSS_BUILD_DIR'
configure_runs='check_(c|cxx|objc|objcxx)_source_runs|check_source_runs|try_run[[:space:]]*\('
GATED=build/drydock-check-runs.cmake

CODE_SPEC=":(glob)**/*.sh :(glob)**/*.yml :(glob)**/*.cmake CMakeLists.txt"
OUTSIDE_TESTS="$CODE_SPEC :!tests/"
OUTSIDE_EXEC_ARCH="$CODE_SPEC :!tests/lib/exec-arch.sh"
YML=.github/workflows/release.yml

# scan PATTERN PATHSPEC... leaves the live (non-comment) hits in $hits; returns 2, saying why, when git grep fails.
scan() {
  pat=$1; shift
  hits=; rc=0
  out=$(git -C "$ROOT" grep -n -E "$pat" -- "$@" ":!$SELF") || rc=$?
  if [ "$rc" -gt 1 ]; then say "git grep exited $rc: the scan for '$pat' could not run"; return 2; fi
  hits=$(printf '%s\n' "$out" | grep -Ev '^[^:]*:[0-9]+:[[:space:]]*#' | grep . || true)
}
# forbid WHAT PATTERN PATHSPEC... fails when the scan finds anything.
forbid() {
  what=$1; shift
  scan "$@" || return 0
  [ -z "$hits" ] || say "$what: $hits"
}
# expect N WHAT PATTERN PATHSPEC... demands exactly N live hits.
expect() {
  n=$1; what=$2; shift 2
  scan "$@" || return 0
  got=$(printf '%s\n' "$hits" | grep -c . || true)
  [ "$got" = "$n" ] || say "control: $what, saw $got of $n in $*"
}

# shellcheck disable=SC2086
{
forbid "something launches through arch(1) with -x86_64 or -arm64 outside tests/" "$launches" $OUTSIDE_TESTS
forbid "something installs Rosetta" "$installs" $CODE_SPEC
forbid "hw.optional.arm64 is read outside tests/lib/exec-arch.sh, so something picks a path by Apple Silicon" "$hw" $OUTSIDE_EXEC_ARCH
forbid "INGREDIENTS.md still declares a Rosetta use" "$rosetta_bullet" INGREDIENTS.md
forbid "release.yml runs the x86_64 build's suite or proof on the arm64 runner" "$cross_runs" $YML
if scan "$configure_runs" $CODE_SPEC; then
  other=$(printf '%s\n' "$hits" | grep -v "^$GATED:" | grep . || true)
  [ -z "$other" ] || say "a configure-time run bypasses $GATED, so an x86_64 configure on Apple Silicon runs under Rosetta: $other"
  n=$(printf '%s\n' "$hits" | grep -c "^$GATED:" || true)
  [ "$n" = 1 ] || say "$GATED's own check_c_source_runs: saw $n, expected 1"
fi
expect 1 "drydock_check_runs asks exec-arch.sh's can_exec before it runs anything" 'can_exec \\"\$2\\"' "$GATED"

# Controls: each real pattern, through scan(), counts exactly its planted rows in the probe file.
expect 2 "the launch scan sees both launches and not the commented one" "$launches" "$PROBES"
expect 1 "the install scan sees the install" "$installs" "$PROBES"
expect 1 "the INGREDIENTS scan sees a planted deviation" "$rosetta_bullet" "$PROBES"
expect 3 "the configure-run scan sees check_c_source_runs, check_cxx_source_runs and try_run" "$configure_runs" "$PROBES"
expect 4 "the cross scan sees run-repo-tests cross, ctest --preset cross, equivalence and chained-fixups, not cross-arm64" "$cross_runs" "$PROBES"

# Controls: the pathspecs match what they are for, and exclude what they exclude.
listed() { git -C "$ROOT" ls-files -- "$@" ":!$SELF"; }
for f in build/msc.sh CMakeLists.txt $YML; do
  listed $OUTSIDE_EXEC_ARCH | grep -qx "$f" || say "control: the exec-arch pathspec does not list $f"
  listed $OUTSIDE_TESTS | grep -qx "$f" || say "control: the outside-tests pathspec does not list $f"
done
listed $CODE_SPEC | grep -qx tests/lib/exec-arch.sh || say "control: the code pathspec does not list tests/lib/exec-arch.sh"
listed $OUTSIDE_EXEC_ARCH | grep -qx tests/lib/exec-arch.sh && say "control: the exec-arch exclusion excludes nothing"
listed $OUTSIDE_TESTS | grep -q '^tests/' && say "control: the tests/ exclusion excludes nothing"
expect 1 "git grep reads hw.optional.arm64 in tests/lib/exec-arch.sh" "$hw" tests/lib/exec-arch.sh
n=$(git -C "$ROOT" grep -c -E 'CROSS_BUILD_DIR' -- $YML | cut -d: -f2)
[ "${n:-0}" -gt 0 ] || say "control: git grep finds no CROSS_BUILD_DIR in release.yml, so its scan reads nothing"
n=$(git -C "$ROOT" grep -c -E '^- ' -- INGREDIENTS.md | cut -d: -f2)
[ "${n:-0}" -gt 0 ] || say "control: git grep reads no bullet of INGREDIENTS.md"
}

[ "$fail" = 0 ] && echo "ok nothing in the repo runs x86_64 code under Rosetta"
exit "$fail"
