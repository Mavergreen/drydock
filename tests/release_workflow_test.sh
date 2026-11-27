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
NOT_IN_GUEST="exec_arch_sweep_test family_conventions jansson_pin_test linux_pin_test mantle_raise_test no_superpowers_citations_test objc_attest_codex objc_iterm2_acceptance objc_reference_set resources_instantiate resources_macfuse_pane rosetta_free_test"
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
  'env DRYDOCK_REQUIRE_EXEC=x86_64 "$@" shipyard-ctest --preset x86_64 -LE not-in-guest --output-on-failure > "$log" 2>&1 || status=$?'
has "the guest's suite fails the job when ctest fails" "$vm" '[ "$status" -eq 0 ] || {'
has "the guest runs the suite on its native build" "$vm" "must suite native
"
has "the guest configures the native build to hand the suites the installed tools" "$vm" \
  'shipyard-cmake --preset x86_64 -DDRYDOCK_TOOL_DIR="$INSTALLED"'
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
apple_silicon_signing_test: SKIP: cannot execute arm64 on this host
macfuse_golden_test: SKIP: macfuse_golden_test: no MACFUSE_DEBUG_TBZ"
[ "$allowed" = "$want_allowed" ] && ok "the guest allows exactly four tests not to run, each for one reason" \
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
for t in x86len_oracle_test rebase_oracle_test apple_silicon_signing_test macfuse_golden_test; do
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
for j in modern-smoke linux; do
  f=$(step "$j" "for macfuse_golden_test")
  has "$j fetches macFUSE's pinned debug tarball" "$f" \
    'https://github.com/macfuse/macfuse/releases/download/macfuse-$v/macfuse-$v-debug.tbz'
  has "$j verifies it against components/macfuse-debug/sha256" "$f" \
    '$(tr -d '"'[:space:]'"' < components/macfuse-debug/sha256)  $tbz" | shasum -a 256 -c'
  has "$j hands it to the suite" "$f" 'echo "MACFUSE_DEBUG_TBZ=$tbz" >> "$GITHUB_ENV"'
  has "$j caches it by its pin" "$(step "$j" actions/cache@)" "key: macfuse-debug-\${{ hashFiles('components/macfuse-debug/sha256') }}"
done
for f in version sha256; do
  [ -s "$HERE/../components/macfuse-debug/$f" ] && ok "components/macfuse-debug/$f pins it" || bad "no components/macfuse-debug/$f"
done
grep -F '`components/macfuse-debug/sha256`' "$HERE/../INGREDIENTS.md" | grep -q '❌ \*\*untrackable\*\*' \
  && ok "INGREDIENTS.md says why no bot moves the macFUSE pin" || bad "INGREDIENTS.md does not mark the macFUSE pin untrackable"
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
has "build runs on Linux" "$b" "runs-on: ubuntu-latest"
for gone in 'run-repo-tests.sh" x86_64
' 'chained-fixups.sh "$X86_64_BUILD_DIR"' 'apple_silicon_signing_test.sh "$X86_64_BUILD_DIR"' \
            'characterize.sh "$X86_64_BUILD_DIR"' 'equivalence.sh produce "$X86_64_BUILD_DIR"' 'macos-x86_64'; do
  lacks "the build runs no x86_64: no $(printf %s "$gone" | tr '\n' ' ')" "$b" "$gone"
done
for gone in run-repo-tests.sh chained-fixups.sh apple_silicon_signing_test.sh macfuse_golden_test.sh characterize.sh \
            'equivalence.sh produce' /var/db/oah; do
  lacks "build, on Linux, runs no Mach-O tool: no $gone" "$b" "$gone"
done
has "build cross-builds x86_64" "$b" "shipyard-cmake --preset x86_64 -DDRYDOCK_BUILD_UPDATER=ON"
has "build runs the x86_64 compat guard" "$b" "shipyard-cmake --build --preset x86_64
"
has "build cross-builds arm64" "$b" "shipyard-cmake --preset arm64 -DDRYDOCK_BUILD_UPDATER=ON"
has "build makes the equivalence inputs with shipyard's clang22" "$(step build 'equivalence.sh inputs')" \
  'CLANG22="$CL" sh tests/equivalence.sh inputs "$RUNNER_TEMP/equivalence/inputs"'
for x in build-pkg.sh build-standalone.sh pkg_payload_test.sh standalone_archive_test.sh release-notes.sh \
         stand-in-feeds.sh sign_and_appcast.sh check-artifact-conformance.sh assert_appcast_upgradeable.sh; do
  has "build runs $x" "$b" "$x"
done
needs on-target | grep -qx modern-smoke && bad "on-target needs modern-smoke, so it waits on macOS" \
  || ok "on-target does not need modern-smoke"

m=$(job modern-smoke)
has "modern-smoke runs on Apple Silicon (macos-26)" "$m" "runs-on: macos-26"
[ "$(needs modern-smoke | tr '\n' ' ')" = "build " ] && ok "modern-smoke needs build alone" \
  || bad "modern-smoke needs '$(needs modern-smoke | tr '\n' ' ')', not 'build '"
for j in publish required equivalence; do
  needs "$j" | grep -qx modern-smoke && ok "$j needs modern-smoke" || bad "$j does not need modern-smoke"
done
has "modern-smoke parses ctest's logs as bytes, which hold non-UTF-8 output" \
  "$(step modern-smoke 'run-repo-tests.sh" arm64')" "export LC_ALL=C"
has "modern-smoke runs only on a publishing run, the family's publish-only smoke" "$m" "
    if: needs.build.outputs.publish == 'yes'"
for j in equivalence assemble; do
  has "$j runs when modern-smoke is skipped, on a push that publishes nothing" "$(job $j)" "
    if: \${{ !failure() && !cancelled() }}"
done
for t in "name: drydock-equivalence-arm64" 'compare "$EQ/macos-x86_64" "$EQ/macos-arm64"'; do
  has "equivalence reads the arm64 outputs only when modern-smoke ran: $t" "$(step equivalence "$t")" \
    "if: needs.modern-smoke.result == 'success'"
done
lacks "the Linux-against-x86_64 compare does not wait on modern-smoke" \
  "$(step equivalence 'compare "$EQ/macos-x86_64" "$EQ/linux-x86_64"')" "needs.modern-smoke"
for x in build-pkg.sh build-standalone.sh sign_and_appcast.sh release-notes.sh; do
  lacks "modern-smoke packages nothing: no $x" "$m" "$x"
done
steps=$(job modern-smoke | sed -n -E 's/^      - (name|uses): //p')
first=$(printf '%s\n' "$steps" | sed -n 1p) last=$(printf '%s\n' "$steps" | tail -1)
[ "$first" = "Snapshot Rosetta's translations, before this job runs anything" ] \
  && ok "modern-smoke snapshots /var/db/oah first, before it runs anything" || bad "modern-smoke's first step is '$first'"
[ "$last" = "Nothing this job ran was translated by Rosetta" ] \
  && ok "modern-smoke compares /var/db/oah last" || bad "modern-smoke's last step is '$last'"
o=$(step modern-smoke "Snapshot Rosetta's translations") c=$(step modern-smoke "Nothing this job ran was translated by Rosetta")
for x in "$o" "$c"; do
  has "a snapshot of /var/db/oah goes through a symlinked root" "$x" "sudo find /var/db/oah/ -type f"
done
has "the comparison runs even when an earlier step failed" "$c" "if: always()"
has "a new translation fails the job, naming it" "$c" '::error::Rosetta translated $f during this job'
has "a missing snapshot is not read as nothing translated" "$c" '[ -f "$RUNNER_TEMP/oah-before" ] || {'
has "no /var/db/oah says Rosetta is not installed" "$o" "Rosetta is not installed"
before_test=$(printf %s "$o" | sed -n '/sudo test -d/q;p')
has "a sudo that fails is not read as Rosetta absent" "$before_test" "sudo -n true || "

has "modern-smoke downloads this run's drydock artifact" "$(step modern-smoke download-artifact)" "name: drydock
"
ms=$(step modern-smoke 'installer -pkg')
has "modern-smoke refuses a runner not running arm64 natively" "$ms" '[ "$(uname -m)" = arm64 ] && [ "$(arch)" = arm64 ]'
has "modern-smoke installs this run's pkg" "$ms" 'sudo installer -pkg "dist/drydock-$V.pkg" -target /'
has "modern-smoke asserts the installed manifest's version" "$ms" \
  '[ "$got" = "$V" ] || { echo "::error::the installed manifest says version $got, not $V"; exit 1; }'
has "modern-smoke runs every installed tool bare, as the guest does" "$ms" 'for f in /usr/local/mavergreen/drydock/bin/*; do'
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
has "modern-smoke runs the downloaded archive's tools from anywhere" "$(step modern-smoke standalone_archive_test.sh)" \
  'sh tests/standalone_archive_test.sh "dist/drydock-$V-macos-universal.tar.gz" "dist/drydock-$V.pkg"'

has "modern-smoke checks the installed updater's arm64 signature" "$ms" \
  'for f in /usr/local/mavergreen/drydock/bin/* "/Library/Application Support/Mavergreen/drydock-updater.app/Contents/MacOS/drydock-updater"; do'
has "modern-smoke requires the installed updater be there to check" "$ms" \
  '[ -f "/Library/Application Support/Mavergreen/drydock-updater.app/Contents/MacOS/drydock-updater" ] ||'
has "modern-smoke codesign-verifies each installed Mach-O's arm64 slice" "$ms" 'codesign -v "$RUNNER_TEMP/arm64-slice" ||'
at() { job modern-smoke | grep -n -F -- "$1" | head -1 | cut -d: -f1; }
rec=$(at 'assert-tree-clean.sh" --record') prod=$(at 'equivalence.sh produce') upl=$(at 'name: drydock-equivalence-arm64')
dl=$(job modern-smoke | grep -n -x '          name: drydock-equivalence' | head -1 | cut -d: -f1)
chk=$(job modern-smoke | grep -n -x '        run: sh "$SHIPYARD_SCRIPTS/assert-tree-clean.sh"' | head -1 | cut -d: -f1)
[ -n "$rec" ] && [ -n "$dl" ] && [ "$rec" -gt "$dl" ] && ok "modern-smoke records the source tree after its downloads" \
  || bad "modern-smoke records the source tree at line '${rec:-none}', its last download is at '${dl:-none}'"
[ -n "$chk" ] && [ -n "$prod" ] && [ -n "$upl" ] && [ "$chk" -gt "$prod" ] && [ "$chk" -lt "$upl" ] \
  && ok "modern-smoke checks the source tree after its last test and before its upload" \
  || bad "modern-smoke's tree check is at line '${chk:-none}', not between produce ($prod) and upload ($upl)"

cfg=$(step modern-smoke 'shipyard-cmake --preset arm64')
has "modern-smoke builds the suite's helpers with shipyard's clang22, as the guest does" "$cfg" \
  '-DMAVERICKS_REQUIRE_APPLECLANG=OFF -DCMAKE_C_COMPILER="$CLANG22/bin/clang"'
has "modern-smoke hands the suite the installed tools" "$cfg" '-DDRYDOCK_TOOL_DIR=/usr/local/mavergreen/drydock/bin'
lacks "modern-smoke builds no updater" "$cfg" "DRYDOCK_BUILD_UPDATER"
su=$(step modern-smoke 'run-repo-tests.sh" arm64')
has "modern-smoke runs the arm64 suite, arm64 skips fatal" "$su" \
  'DRYDOCK_REQUIRE_EXEC=arm64 sh "$SHIPYARD_SCRIPTS/run-repo-tests.sh" arm64 > "$log" 2>&1 || status=$?'
has "a test that did not run on the runner fails the job unless allowed" "$su" "/did not run:/"
has "the did-not-run parse has a positive control: raise_runs_test, which runs only on 10.9" "$su" \
  'grep -qx raise_runs_test "$RUNNER_TEMP/skipped"'
has "an allowed test must have skipped for its stated reason, its last SKIP line in LastTest.log" "$su" \
  'f && /^SKIP/ { s = $0 } END { print s }'"' \"\$ARM64/Testing/Temporary/LastTest.log\""
allowed=$(printf '%s\n' "$su" | sed -n 's/^ *\([a-z0-9_]*\)) echo "\(SKIP[^"]*\)" ;;$/\1: \2/p')
want_allowed="resources_instantiate: SKIP resources_instantiate: AppKit on 10.9
resources_macfuse_pane: SKIP: resources_macfuse_pane: set DRYDOCK_RESOURCES_MACFUSE_NIB *
objc_attest_codex: SKIP objc_attest_codex: */Library/Caches/mm-build/codex-native-sweep-repro is absent
objc_reference_set: SKIP objc_reference_set: a maintainer test -- it runs on 10.9, or here with DRYDOCK_OBJC_MAINTAINER=1
objc_iterm2_acceptance: SKIP objc_iterm2_acceptance: a maintainer test -- it runs on 10.9, or here with DRYDOCK_OBJC_MAINTAINER=1
codesign_order_test: SKIP: * is not cctools-862's, whose verdicts this test pins
raise_corpus_test: SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own
raise_oracle_counts_test: SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own
hdrref_table_rule_test: SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own
raise_runs_test: SKIP: these are 10.9's libraries and programs; this is not 10.9
mantle_raise_test: SKIP: */Downloads/OpenCode.app/Contents/Frameworks/Mantle.framework/Versions/A/Mantle is absent
legacysupport_rename_test: SKIP: legacysupport_rename_test: no libMacportsLegacySupport.a (set LEGACYSUPPORT_A)"
[ "$allowed" = "$want_allowed" ] && ok "the runner allows exactly these tests not to run, each for one reason" \
  || bad "the runner's allow-list is '$allowed'"
two=$(printf '%s\n' "$su" | sed -n '/^ *x86len_oracle_test)/,/;;$/p;/^ *rebase_oracle_test)/,/;;$/p')
has "x86len_oracle_test may not run, for want of cctools' otool" "$two" "is not cctools' otool, whose linear sweep is the oracle"
has "... or of 10.9's corpus" "$two" "is absent; the corpus is 10.9's own images"
has "rebase_oracle_test may not run, for want of dyldinfo" "$two" "SKIP: no dyldinfo here"
has "... or of 10.9's corpus" "$two" "SKIP: /usr/lib holds no dylibs here; the corpus is 10.9's own"
for t in resources_instantiate resources_macfuse_pane objc_attest_codex objc_reference_set objc_iterm2_acceptance codesign_order_test \
         raise_corpus_test raise_oracle_counts_test hdrref_table_rule_test raise_runs_test mantle_raise_test \
         legacysupport_rename_test x86len_oracle_test rebase_oracle_test; do
  has "the runner says why $t may not run" "$su" "#   $t: "
done
for t in apple_silicon_signing_test macfuse_golden_test installed_bin_test tool_dir_test; do
  lacks "$t must run on the runner" "$su" "$t)"
done
has "a row that says SKIP or N/A in a test that ran fails the job unless allowed" "$su" \
  'row_allowed "$r" || { echo "::error::$r: a row did not run, and the runner does not allow that"; badrows=$((badrows + 1)); continue; }'
has "the runner names every disallowed row before it fails, not only the first" "$su" \
  '[ "$badrows" -eq 0 ] || { echo "::error::$badrows row(s) did not run, and the runner does not allow them"; exit 1; }'
has "exec_arch_test's 10.9-only row may skip: on-target runs it" "$su" \
  '"exec_arch_test: SKIP this-host: not 10.9") ;;'
has "the row parse reads each test's whole SKIP and N/A lines from LastTest.log" "$su" \
  't != "" && /^(SKIP|N\/A) / { print t ": " $0 }'
has "the row parse leaves out the tests that did not run, whose own SKIP lines the first list judged" "$su" \
  'NR == FNR { skipped[$0] = 1; next } /^[0-9]+\/[0-9]+ Test: / { t = ($3 in skipped) ? "" : $3; next }'
has "the row parse has a positive control: an x86_64 row of symbol_rename_test, which no arm64 Mac runs" "$su" \
  "grep -qxF 'symbol_rename_test: SKIP forwarding: links and prints 43: cannot execute x86_64 on this host (Apple Silicon, no Rosetta by policy)' \"\$RUNNER_TEMP/rows\""
lacks "libgmalloc rows must run: macos-26 has /usr/lib/libgmalloc.dylib (the resources_*_gmalloc tests pass there)" "$su" libgmalloc
has "x86_64 rows may skip: on-target runs them" "$su" \
  '*": SKIP "*": cannot execute x86_64 on this host (Apple Silicon, no Rosetta by policy)") ;;'
has "the suite runs with the fetched macFUSE tarball" "$(step modern-smoke 'for macfuse_golden_test')" 'MACFUSE_DEBUG_TBZ='

I=/usr/local/mavergreen/drydock/bin
for s in apple_silicon_signing_test chained-fixups macfuse_golden_test; do
  x=$(step modern-smoke "tests/$s.sh")
  has "modern-smoke runs $s on the installed tools" "$x" "sh tests/$s.sh $I && rc=0 || rc=\$?"
  has "modern-smoke fails a 77 from $s" "$x" 'if [ "$rc" = 77 ]; then'
done
has "modern-smoke fails if chained-fixups skips" "$(step modern-smoke tests/chained-fixups.sh)" \
  'echo "::error::chained-fixups SKIPPED on a modern runner — it should be able to emit them"'
has "modern-smoke fails if apple_silicon_signing_test skips" "$(step modern-smoke tests/apple_silicon_signing_test.sh)" \
  'echo "::error::apple_silicon_signing_test SKIPPED on the arm64 runner -- it should run here"'
has "modern-smoke fails if macfuse_golden_test skips" "$(step modern-smoke tests/macfuse_golden_test.sh)" \
  'echo "::error::macfuse_golden_test SKIPPED on the arm64 runner -- it should run here"'
has "modern-smoke characterizes the installed tools" "$(step modern-smoke tests/characterize.sh)" \
  "sh tests/characterize.sh $I check"
has "the installed arm64 tools produce equivalence's macos-arm64 outputs" "$(step modern-smoke 'equivalence.sh produce')" \
  "sh tests/equivalence.sh produce $I eq/inputs \"\$RUNNER_TEMP/macos-arm64\""
has "modern-smoke downloads build's equivalence inputs" "$(step modern-smoke download-artifact)" "name: drydock-equivalence
"
has "modern-smoke uploads the macos-arm64 outputs" "$(step modern-smoke upload-artifact)" "name: drydock-equivalence-arm64"
has "equivalence downloads modern-smoke's macos-arm64 outputs into macos-arm64" "$(step equivalence download-artifact)" \
  'name: drydock-equivalence-arm64
          path: ${{ runner.temp }}/equivalence/macos-arm64'

PB=${PINS_BOT:-$HERE/../.github/workflows/pins-bot.yml}
pb=$(cat "$PB")
has "pins-bot's pins job runs the Jansson fill against origin/main" "$pb" 'sh scripts/pin-jansson.sh fill origin/main'
has "pins-bot's pins job exports a jansson_pin output" "$pb" 'jansson_pin: ${{ steps.jansson.outputs.jansson_pin }}'
has "pins-bot's push job runs when the Jansson digest moved" "$pb" "|| needs.pins.outputs.jansson_pin != ''"
has "pins-bot's push job applies the Jansson digest" "$pb" 'sh scripts/pin-jansson.sh apply "$JANSSON_PIN"'
has "pins-bot's push job commits components/jansson/version" "$pb" 'components/objc-receipt-clang/linux-sha256 components/jansson/version'

echo "release_workflow_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
