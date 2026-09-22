#!/bin/sh
# tests/grown_binary_runs_test.sh -- a header grow must not change what a
# program DOES. Every other grow test checks structure; this one runs the
# grown binary and its input with the same arguments and environment and
# compares stdout, stderr and exit status.
#
#   sh tests/grown_binary_runs_test.sh <bindir>
#
# The subjects: a PIE executable linked here with -headerpad 0, and a system
# executable when one qualifies (a 64-bit PIE MH_EXECUTE the grow accepts as
# it is; a slice with chained fixups does not, and is reported as a SKIP).
# Each gets enough distinct LC_RPATHs to outgrow its header pad, measured from
# `drydock-macho-rewrite info` -- never a pad size this host's linker chose.
# Fixtures are x86_64 with a 10.9 floor, which runs on 10.9 and under Rosetta.
set -u

BIN="${1:?usage: grown_binary_runs_test.sh <bindir>}"
BIN=$(cd "$BIN" && pwd)
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "grown_binary_runs_test: $DMR not found or not executable" >&2; exit 1; }
CC="${CC:-clang}"
FF="-arch x86_64 -mmacosx-version-min=10.9"

fail=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=$((fail + 1)); }
skip() { echo "SKIP $1: $2"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/grown-binary-runs.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT INT TERM

cat >"$T/prog.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int from_ctor;
__attribute__((constructor)) static void ctor(void) { from_ctor = 41; }
static int by_name(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}
static int (*const pick[2])(const void *, const void *) = { by_name, 0 };
int main(int argc, char **argv) {
    const char *e = getenv("GROW_PROBE");
    qsort(argv + 1, (size_t)argc - 1, sizeof *argv, pick[0]);
    for (int i = 1; i < argc; i++) printf("%s\n", argv[i]);
    fprintf(stderr, "env=%s ctor=%d\n", e ? e : "(unset)", from_ctor + 1);
    return argc + 3;
}
EOF
"$CC" $FF -Wl,-headerpad,0 -o "$T/prog" "$T/prog.c" \
    || { echo "grown_binary_runs_test: could not link the fixture" >&2; exit 1; }

pad_of() { "$DMR" info "$1" | awk '/^header pad: / { print $3; exit }'; }
text_vmaddr() {
    "$DMR" info "$1" | awk '/segname=__TEXT / {
        for (i = 1; i <= NF; i++) if ($i ~ /^vmaddr=/) { sub("vmaddr=", "", $i); print $i; exit } }'
}

# rpaths FILE -- distinct LC_RPATH statements whose commands outgrow FILE's pad.
rpaths() {
    pad=$(pad_of "$1")
    n=$(( ${pad:-0} / 200 + 2 ))
    fill=$(printf '%0180d' 0)
    i=0
    while [ "$i" -lt "$n" ]; do
        printf 'rpath append /nonexistent/grow-probe-%d/%s\n' "$i" "$fill"
        i=$((i + 1))
    done
}

# grow NAME IN OUT -- grow IN into OUT; status in $grc.
grow() {
    { "$DMR" info "$2" | grep -q ' LC_CODE_SIGNATURE ' && printf 'load-command delete codesig\n'
      rpaths "$2"; } >"$T/$1.edits"
    grc=0
    "$DMR" "$2" "$3" <"$T/$1.edits" >"$T/$1.grow.out" 2>"$T/$1.grow.err" || grc=$?
}

# lowered NAME IN OUT -- the grow really happened: the image base went down.
lowered() {
    b0=$(text_vmaddr "$2") b1=$(text_vmaddr "$3")
    [ -n "$b0" ] && [ -n "$b1" ] && [ "$b0" != "$b1" ] \
        && ok "$1: ... and lowered the image base ($b0 -> $b1), so it really grew" \
        || bad "$1: grew" "__TEXT vmaddr '$b0' -> '$b1'"
}

# same NAME IN OUT ARG... -- run both under the same environment; they
# must agree on stdout, stderr and exit status.
same() {
    name=$1 in=$2 out=$3; shift 3
    irc=0; orc=0
    env -i PATH=/usr/bin:/bin GROW_PROBE=probe "$in" "$@" \
        >"$T/$name.in.out" 2>"$T/$name.in.err" || irc=$?
    env -i PATH=/usr/bin:/bin GROW_PROBE=probe "$out" "$@" \
        >"$T/$name.out.out" 2>"$T/$name.out.err" || orc=$?
    cmp -s "$T/$name.in.out" "$T/$name.out.out" \
        && ok "$name: the grown binary's stdout is the input's" \
        || bad "$name: stdout" "input '$(cat "$T/$name.in.out")', grown '$(cat "$T/$name.out.out")'"
    cmp -s "$T/$name.in.err" "$T/$name.out.err" \
        && ok "$name: ... its stderr is the input's" \
        || bad "$name: stderr" "input '$(cat "$T/$name.in.err")', grown '$(cat "$T/$name.out.err")'"
    [ "$irc" -eq "$orc" ] \
        && ok "$name: ... and so is its exit status ($irc)" \
        || bad "$name: exit status" "input $irc, grown $orc"
}

# ---- 1. the linked fixture --------------------------------------------------
grow prog "$T/prog" "$T/prog.grown"
[ "$grc" -eq 0 ] && ok "prog: the grow succeeds" \
    || bad "prog: grow" "exit $grc: $(cat "$T/prog.grow.err")"
grep -q "^$T/prog: grew the header pad by " "$T/prog.grow.err" \
    && ok "prog: ... and announces itself" || bad "prog: announced" "$(cat "$T/prog.grow.err")"
lowered prog "$T/prog" "$T/prog.grown"
"$DMR" verify "$T/prog.grown" >/dev/null 2>&1 \
    && ok "prog: ... and the result verifies" || bad "prog: verify" "refused"
same prog "$T/prog" "$T/prog.grown" pear apple "fig tree"
same prog-noargs "$T/prog" "$T/prog.grown"

# ---- 2. a system executable, when one qualifies ------------------------------
# platform: 10.9 ships thin x86_64 PIE executables with classic fixups; a
# modern macOS ships fat ones whose x86_64 slice has chained fixups, which the
# grow refuses -- so there the case is a SKIP, and the fixture above carries it.
# A fat one is thinned to its x86_64 slice first.
sys=/usr/bin/printf
if [ ! -x "$sys" ]; then
    skip "system: $sys" "not present"
else
    sin=$sys
    : >"$T/sys.grow.err"
    if [ "$(od -An -tx1 -N4 "$sys" | tr -d ' \n')" = cafebabe ]; then
        sin=$T/sys.x86_64
        lipo "$sys" -thin x86_64 -output "$sin" 2>"$T/sys.grow.err" || sin=
    fi
    grc=1
    [ -n "$sin" ] && grow sys "$sin" "$T/sys.grown"
    if [ "$grc" -ne 0 ]; then
        skip "system: $sys" "does not qualify here: $(tr '\n' ' ' <"$T/sys.grow.err")"
    else
        ok "system: $sys grows"
        lowered system "$sin" "$T/sys.grown"
        same system "$sin" "$T/sys.grown" '%s|%5d|%x\n' grown 42 255
    fi
fi

[ "$fail" -eq 0 ] || { echo "grown_binary_runs_test: $fail failure(s)"; exit 1; }
echo "grown_binary_runs_test: all passed"
