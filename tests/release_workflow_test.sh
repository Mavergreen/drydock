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

echo "release_workflow_test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
