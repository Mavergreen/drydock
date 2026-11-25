#!/bin/sh
# platform: host-agnostic -- needs a git checkout; without .git or a git that runs (the guest, an archive build) it
#   SKIPs (77)
# spec: .superpowers is gitignored and ephemeral, so no committed file may cite a path in it. .gitignore's own
#   ignore rule is the one allowed hit, and it must be found, so a grep that matches nothing cannot pass. This
#   script names the directory itself, so it is left out of the sweep.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
git --version >/dev/null 2>&1 || { echo "SKIP no_superpowers_citations_test: no git that runs"; exit 77; }
[ -e "$ROOT/.git" ] || { echo "SKIP no_superpowers_citations_test: $ROOT is not a git checkout"; exit 77; }
hits=$(cd "$ROOT" && git grep -n '\.superpowers' -- . ':!.superpowers' ':!tests/no_superpowers_citations_test.sh') || [ $? = 1 ] \
  || { echo "FAIL: git grep failed"; exit 1; }
control=$(printf '%s\n' "$hits" | grep -c '^\.gitignore:[0-9]*:/\.superpowers/$')
others=$(printf '%s\n' "$hits" | grep -v '^\.gitignore:[0-9]*:/\.superpowers/$' | grep -v '^$')
[ "$control" = 1 ] || { echo "FAIL: the positive control, .gitignore's /.superpowers/ rule, was found $control times"; exit 1; }
[ -z "$others" ] || { echo "FAIL: committed files cite .superpowers:"; printf '%s\n' "$others"; exit 1; }
echo "PASS: no committed file cites .superpowers; .gitignore's rule is the one hit"
