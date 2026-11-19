#!/bin/sh
# platform: host-agnostic -- reads release.yml, as ctest runs it on Linux too
#   usage: release_workflow_test.sh [release.yml]
#          the signing-key scan reads every artifact that holds release files, the signed macOS
#          dist included, so a release run that fails after signing still has its files scanned
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=${1:-$HERE/../.github/workflows/release.yml}
pass=0 fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1" >&2; fail=$((fail + 1)); }

job_field() {
  awk -v job="$1" -v key="$2" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { injob = ($1 == job ":") ; next }
    injob && $1 == key ":" { v = $2; gsub(/^["'\'']|["'\'']$/, "", v); print v; exit }
  ' "$W"
}

uploads=$(awk '/uses: actions\/upload-artifact@/ { up = 1; next } up && $1 == "name:" { print $2; up = 0 }' "$W")
for want in drydock drydock-release; do
  printf '%s\n' "$uploads" | grep -qx "$want" && ok "a job uploads the $want artifact" || bad "no job uploads $want"
done

pattern=$(job_field scan artifact)
[ -n "$pattern" ] && ok "scan names its artifact pattern: $pattern" || bad "scan names no artifact"
for name in drydock drydock-release; do
  case "$name" in
    $pattern) ok "scan's pattern $pattern takes the $name artifact" ;;
    *) bad "scan's pattern ${pattern:-<none>} misses the $name artifact, so its release files go unscanned" ;;
  esac
done
[ "$(job_field publish artifact)" = drydock-release ] && ok "publish publishes drydock-release" \
  || bad "publish publishes $(job_field publish artifact), not drydock-release"

job() { awk -v job="$1" '/^  [A-Za-z0-9_-]+:[[:space:]]*$/ { injob = ($1 == job ":"); next } /^[^ ]/ { injob = 0 } injob' "$W"; }
step() {  # JOB TEXT: each step of JOB whose text holds TEXT
  job "$1" | awk -v t="$2" '
    /^      - / { if (index(s, t)) printf "%s--\n", s; s = "" }
    { s = s $0 "\n" }
    END { if (index(s, t)) printf "%s--\n", s }'
}
needs() { job "$1" | sed -n 's/^    needs: *\[\(.*\)\] *$/\1/p' | tr -d ' ' | tr ',' '\n'; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" ;; *) ok "$1" ;; esac; }

g=$(job on-target)
has "the on-target job runs on ubuntu-latest" "$g" "runs-on: ubuntu-latest"
has "on-target reads contents" "$g" "contents: read"
has "on-target may write packages, mavericks-vm's image cache" "$g" "packages: write"
has "on-target boots Mavergreen/mavericks-vm@v1" "$g" "uses: Mavergreen/mavericks-vm@v1"
has "on-target passes the image key" "$g" 'image-key: ${{ secrets.MAVERICKS_VM_KEY }}'
has "on-target asks for 4 CPUs" "$g" "cpu: '4'"
has "on-target asks for 8192 MiB" "$g" "mem: '8192'"
needs on-target | grep -qx build && ok "on-target needs build" || bad "on-target does not need build"
for j in publish required equivalence; do
  needs "$j" | grep -qx on-target && ok "$j needs on-target" || bad "$j does not need on-target"
done

above() { awk -v job="$1" '/^  #/ { c = c $0 "\n"; next } $1 == job ":" && /^  [^ ]/ { printf "%s", c; exit } { c = "" }' "$W"; }
gc=$(above on-target)
NOT_IN_GUEST="exec_arch_sweep_test family_conventions linux_pin_test mantle_raise_test objc_iterm2_acceptance objc_reference_set rosetta_free_test"
for t in $NOT_IN_GUEST; do
  has "on-target's comment says why $t is not-in-guest" "$gc" "$t"
done
if [ -n "${DRYDOCK_BUILD_DIR:-}" ]; then
  got=$("${DRYDOCK_CTEST:-ctest}" --test-dir "$DRYDOCK_BUILD_DIR" -N -L not-in-guest | sed -n 's/^ *Test *#[0-9]*: //p' | LC_ALL=C sort | tr '\n' ' ')
  [ "$got" = "$NOT_IN_GUEST " ] && ok "ctest's not-in-guest set is exactly: $NOT_IN_GUEST" \
    || bad "ctest's not-in-guest set is '$got', not '$NOT_IN_GUEST '"
else
  echo "N/A ctest's not-in-guest set: no DRYDOCK_BUILD_DIR (ctest passes it)"
fi

vm=$(step on-target "Mavergreen/mavericks-vm@v1")
has "the guest makes a skip (77) fail" "$vm" 'must() { status=0; "$@" || status=$?;'
has "the guest installs this run's pkg" "$vm" 'sudo installer -pkg "dist/drydock-$V.pkg" -target /'
has "the guest asserts the installed manifest's version" "$vm" "Print :version"
has "the guest's suite runs with x86_64 skips fatal, the not-in-guest tests excluded" "$vm" \
  'env DRYDOCK_REQUIRE_EXEC=x86_64 "$@" shipyard-ctest --preset native -LE not-in-guest --output-on-failure > "$log" 2>&1 || status=$?'
has "the guest's suite fails the job when ctest fails" "$vm" '[ "$status" -eq 0 ] || {'
has "the guest runs the suite on its native build" "$vm" "must suite native
"
has "the guest configures the native build to hand the suites the installed tools" "$vm" \
  'shipyard-cmake --preset native -DDRYDOCK_TOOL_DIR="$INSTALLED"'
has "the guest runs the suite again on the installed tools, telling tool_dir_test" "$vm" \
  'must suite installed DRYDOCK_TOOL_DIR="$INSTALLED"'
has "a test that did not run in the guest fails the job unless allowed" "$vm" "/did not run:/"
has "the did-not-run parse has a positive control: apple_silicon_signing_test, which no Intel Mac runs" "$vm" \
  'grep -qx apple_silicon_signing_test "$TMPDIR/skipped"'
has "an allowed test must have skipped for its stated reason, its last SKIP line in LastTest.log" "$vm" \
  'f && /^SKIP/ { s = $0 } END { print s }'"' \"\$NATIVE/Testing/Temporary/LastTest.log\""
allowed=$(printf '%s\n' "$vm" | sed -n 's/^ *\([a-z0-9_]*\)) echo "\(SKIP: [^"]*\)" ;;$/\1: \2/p')
want_allowed="x86len_oracle_test: SKIP: no cctools otool here
rebase_oracle_test: SKIP: no dyldinfo here
apple_silicon_signing_test: SKIP: cannot execute arm64 on this host"
[ "$allowed" = "$want_allowed" ] && ok "the guest allows exactly three tests not to run, each for one reason" \
  || bad "the guest's allow-list is '$allowed'"
has "a row that says SKIP or N/A in a test that ran fails the job unless allowed" "$vm" \
  'row_allowed "$r" || { echo "$r: a row did not run, and the guest does not allow that"; return 1; }'
has "the row parse reads each test's SKIP and N/A lines from LastTest.log" "$vm" "t != \"\" && /^(SKIP|N\\/A) /"
has "the row parse has a positive control: symbol_rename_test's arm64 row, which no 10.9 clang22 builds" "$vm" \
  "grep -qx 'symbol_rename_test: SKIP arm64' \"\$TMPDIR/rows\""
rows=$(printf '%s\n' "$vm" | awk '/^ *row_allowed\(\) \{/ { f = 1; next } f && /case "\$1" in/ { next } f && /^ *\*\) return 1 ;;/ { exit } f' |
  grep -o '"[^"]*"' | tr -d '"' | LC_ALL=C sort | tr '\n' '|')
want_rows="bake_mavericks_shim_test: N/A signed|codesign_order_test: N/A resign 10.9 against the oracle|fixture_toolchain_test: N/A positive control against abe8d68|fixture_toolchain_test: N/A positive control against c7c0f56|insert_dylib_test: SKIP --strip-codesig|insert_dylib_test: SKIP no tty, no --all-yes|objc_report: SKIP no x86_64 slice|symbol_rename_test: SKIP arm64|tool_dir_test: N/A the installed tools|wrapper_test: SKIP rename_segment|"
[ "$rows" = "$want_rows" ] && ok "the guest allows exactly ten rows not to run" || bad "the guest's row allow-list is '$rows'"
why_rows=$(printf '%s\n' "$vm" | awk '/^ *# Rows of tests that ran, allowed/ { f = 1 } f && !/^ *#/ { exit } f')
for t in bake_mavericks_shim_test codesign_order_test insert_dylib_test fixture_toolchain_test objc_report symbol_rename_test tool_dir_test wrapper_test; do
  has "the guest says why $t's rows may not run" "$why_rows" "$t "
done
for t in x86len_oracle_test rebase_oracle_test apple_silicon_signing_test; do
  has "the guest says why $t may not run" "$vm" "#   $t: "
done
lacks "legacysupport_rename_test must run in the guest" "$vm" "legacysupport_rename_test)"
has "the guest hands legacysupport_rename_test MacPorts' library" "$vm" \
  'export LEGACYSUPPORT_A="$mls/usr/local/mavergreen/legacysupport/lib/libMacportsLegacySupport.a"'
has "the runner fetches the pinned legacy-support pkg from Mavergreen/recaulk" "$(step on-target fetch-release-pkg.sh)" \
  'fetch recaulk "$mls" "macports-legacy-support-$mls.pkg"'
[ -s "$HERE/../components/macports-legacy-support/version" ] && ok "components/macports-legacy-support/version pins it" \
  || bad "no components/macports-legacy-support/version"
grep -F '`components/macports-legacy-support/version`' "$HERE/../INGREDIENTS.md" | grep -q '❌ \*\*untrackable\*\*' \
  && ok "INGREDIENTS.md says why no bot moves the legacy-support pin" || bad "INGREDIENTS.md does not mark the legacy-support pin untrackable"
if printf %s "$vm" | grep -q 'drydock-updater'; then
  grep -q '^- on-target:updater: ' "$HERE/../INGREDIENTS.md" && bad "the guest runs the updater; drop INGREDIENTS.md's on-target:updater line" \
    || ok "the guest runs the updater"
else
  grep -q '^- on-target:updater: .*Reconsider when ' "$HERE/../INGREDIENTS.md" \
    && ok "the guest runs no updater, and INGREDIENTS.md declares that gap with when to reconsider it" \
    || bad "the guest runs no updater, and INGREDIENTS.md has no '- on-target:updater:' line saying why and when to reconsider"
fi
lacks "the job claims no more than the guest enforces" "$(above on-target)" "A 77 from any of these fails the job"
has "the guest characterizes the native build" "$vm" 'must sh tests/characterize.sh "$NATIVE" check'
has "the guest characterizes the installed tools" "$vm" 'must sh tests/characterize.sh "$INSTALLED" check'
has "the installed tools produce equivalence's macos-x86_64 outputs" "$vm" \
  'must sh tests/equivalence.sh produce "$INSTALLED" eq/inputs out/macos-x86_64'
lacks "the guest never falls back to fetching clang22" "$vm" "fetch_clang22"
has "on-target uploads the macos-x86_64 outputs" "$(step on-target upload-artifact)" "name: drydock-equivalence-x86_64"
has "equivalence downloads on-target's macos-x86_64 outputs" "$(step equivalence download-artifact)" \
  "name: drydock-equivalence-x86_64"
e=$(step equivalence "equivalence.sh compare")
has "equivalence compares macos-x86_64 with macos-arm64" "$e" 'compare "$EQ/macos-x86_64" "$EQ/macos-arm64"'
has "equivalence compares macos-x86_64 with linux-x86_64" "$e" 'compare "$EQ/macos-x86_64" "$EQ/linux-x86_64"'

b=$(job build)
for gone in 'run-repo-tests.sh" cross
' 'chained-fixups.sh "$CROSS_BUILD_DIR"' 'apple_silicon_signing_test.sh "$CROSS_BUILD_DIR"' \
            'characterize.sh "$CROSS_BUILD_DIR"' 'equivalence.sh produce "$CROSS_BUILD_DIR"' 'macos-x86_64'; do
  lacks "the runner runs no x86_64: no $(printf %s "$gone" | tr '\n' ' ')" "$b" "$gone"
done
has "the runner still cross-builds x86_64" "$b" "shipyard-cmake --preset cross -DDRYDOCK_BUILD_UPDATER=ON"
has "the runner still runs the x86_64 compat guard" "$b" "shipyard-cmake --build --preset cross
"
has "the arm64 suite still runs" "$(step build 'run-repo-tests.sh" cross-arm64')" 'run-repo-tests.sh" cross-arm64'
steps=$(job build | sed -n -E 's/^      - (name|uses): //p')
first=$(printf '%s\n' "$steps" | sed -n 2p) last=$(printf '%s\n' "$steps" | tail -2 | head -1)
[ "$(printf '%s\n' "$steps" | sed -n 1p)" = actions/checkout@v7 ] && [ "$first" = "Snapshot Rosetta's translations, before this job runs anything" ] \
  && ok "build snapshots /var/db/oah right after checkout, before it runs anything" || bad "build's second step is '$first'"
[ "$last" = "Nothing this job ran was translated by Rosetta" ] && [ "$(printf '%s\n' "$steps" | tail -1)" = actions/upload-artifact@v7 ] \
  && ok "build compares /var/db/oah just before its last upload" || bad "build's step before its last upload is '$last'"
o=$(step build "Snapshot Rosetta's translations") c=$(step build "Nothing this job ran was translated by Rosetta")
for x in "$o" "$c"; do
  has "a snapshot of /var/db/oah goes through a symlinked root" "$x" "sudo find /var/db/oah/ -type f"
done
has "the comparison runs even when an earlier step failed" "$c" "if: always()"
has "a new translation fails the job, naming it" "$c" '::error::Rosetta translated $f during this job'
has "a missing snapshot is not read as nothing translated" "$c" '[ -f "$RUNNER_TEMP/oah-before" ] || {'
has "no /var/db/oah says Rosetta is not installed" "$o" "Rosetta is not installed"
before_test=$(printf %s "$o" | sed -n '/sudo test -d/q;p')
has "a sudo that fails is not read as Rosetta absent" "$before_test" "sudo -n true || "

m=$(job modern-smoke)
has "modern-smoke runs on Apple Silicon (macos-26)" "$m" "runs-on: macos-26"
[ "$(needs modern-smoke | tr '\n' ' ')" = "build " ] && ok "modern-smoke needs build alone" \
  || bad "modern-smoke needs '$(needs modern-smoke | tr '\n' ' ')', not 'build '"
for j in publish required; do
  needs "$j" | grep -qx modern-smoke && ok "$j needs modern-smoke" || bad "$j does not need modern-smoke"
done
has "modern-smoke downloads this run's drydock artifact" "$(step modern-smoke download-artifact)" "name: drydock
"
ms=$(step modern-smoke 'installer -pkg')
has "modern-smoke refuses a runner not running arm64 natively" "$ms" '[ "$(uname -m)" = arm64 ] && [ "$(arch)" = arm64 ]'
has "modern-smoke installs this run's pkg" "$ms" 'sudo installer -pkg "dist/drydock-$V.pkg" -target /'
has "modern-smoke asserts the installed manifest's version" "$ms" \
  '[ "$got" = "$V" ] || { echo "::error::the installed manifest says version $got, not $V"; exit 1; }'
has "modern-smoke asserts the installed drydock-objc carries arm64" "$ms" 'lipo -info "$OBJC" | sed -n'
has "modern-smoke runs the installed drydock-objc bare, expecting its usage and 2" "$ms" '[ "$rc" -eq 2 ]'
has "modern-smoke runs a real subcommand on a committed fixture" "$ms" \
  '"$OBJC" evidence --tree-digest-only --source-root tests/objc/fixtures'
has "modern-smoke computes the fixtures' digest independently" "$ms" \
  '. tests/lib/tree-digest.sh && want="$(tree_digest tests/objc/fixtures)"'
has "modern-smoke requires the installed drydock-objc's digest to equal it" "$ms" '[ "$digest" = "$want" ] ||'
has "modern-smoke refuses an empty digest, which two failures would agree on" "$ms" '[ -n "$want" ] ||'
lacks "modern-smoke does not settle for a digest's format" "$ms" "{64}"
lacks "modern-smoke runs nothing x86_64" "$ms" "x86_64"

echo "release_workflow_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
