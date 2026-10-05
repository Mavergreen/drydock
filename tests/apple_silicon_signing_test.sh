#!/bin/sh
# tests/apple_silicon_signing_test.sh -- what an Apple Silicon Mac does with
# Drydock's edited outputs, where the kernel enforces code signing for every
# process: the rows behind the per-arch re-signing rule in
# drydock-macho-rewrite(1) and docs/apple-silicon-signing.md.
#
#   sh tests/apple_silicon_signing_test.sh <bindir>
#
# A dylib, a program linked against it and a program alone are built here for
# arm64 and x86_64 with a 16 KB header pad, and each case edits a fresh copy
# with `dylib append /usr/lib/libz.1.dylib`:
#
# - arm64: left with its stale signature, the edit is SIGKILLed (137); with
#   the signature removed by `load-command delete codesig`, it is refused,
#   by SIGKILL or by dyld's abort (134); re-signed by `codesign -s - -f`, it
#   runs. Linked dylib and program alike.
# - x86_64 under Rosetta: stale, removed and re-signed all run in an
#   ordinary process. A host signed `-o kill` SIGKILLs the stale dylib and
#   runs the stripped and re-signed ones.
# - Built without the pad (32 bytes is ld's), an arm64 dylib or program is
#   refused by Drydock itself, saying why, and nothing is written.
#
# The unedited subjects must run on each arch, saying whether they were
# translated, before any death is believed; each state's signature is
# checked (stale: present and failing `codesign -v`; stripped: absent;
# re-signed: valid) before its row is run.
#
# A real Mac gives every arm64 process CS_KILL (0x200 in its csops status)
# and refuses an unsigned arm64 program. GitHub's macos-26 runner, a VM,
# does neither. Where the unedited arm64 program lacks CS_KILL, the arm64
# stale rows sign their program `-o kill` before the edit, and the stripped
# program is run and reported, not judged. INFO lines give the status,
# `csrutil status` and kern.bootargs.
#
# It SKIPs, saying why, except on an Apple Silicon Mac (CI's macos-26 runner
# is one) with codesign and a compiler that builds both arches. Without
# Rosetta, the x86_64 rows are skipped, or the whole test if Drydock is x86_64.
set -u

BIN="${1:?usage: apple_silicon_signing_test.sh <bindir>}"
BIN=$(cd "$BIN" && pwd) || exit 1
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "apple_silicon_signing_test: $DMR not found or not executable" >&2; exit 1; }
CC="${CC:-cc}"
PAD=-Wl,-headerpad,0x4000
APPEND='dylib append /usr/lib/libz.1.dylib'

[ "$(uname -s)" = Darwin ] || { echo "SKIP: not macOS"; exit 77; }
[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] ||
    { echo "SKIP: not an Apple Silicon Mac (hw.optional.arm64 is not 1)"; exit 77; }
command -v codesign >/dev/null 2>&1 || { echo "SKIP: no codesign here"; exit 77; }

T=$(mktemp -d "${TMPDIR:-/tmp}/apple-silicon-signing.XXXXXX") || exit 1
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT INT TERM
cd "$T" || exit 1

printf 'int main(void) { return 0; }\n' >probe.c
for a in arm64 x86_64; do
    "$CC" -arch $a -o probe-$a probe.c >/dev/null 2>&1 ||
        { echo "SKIP: $CC cannot build -arch $a"; exit 77; }
done

rosetta=yes
arch -x86_64 /usr/bin/true >/dev/null 2>&1 || rosetta=
"$DMR" --capabilities >/dev/null 2>&1 || {
    [ -n "$rosetta" ] || { echo "SKIP: no Rosetta, and $DMR needs it to run"; exit 77; }
    echo "apple_silicon_signing_test: $DMR does not run" >&2
    exit 1
}

cat >translated.h <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <sys/sysctl.h>
int csops(pid_t, unsigned int, void *, size_t);
static void say_translated(void)
{
    int t = 0;
    unsigned int st = 0;
    size_t n = sizeof t;
    if (sysctlbyname("sysctl.proc_translated", &t, &n, NULL, 0) != 0) t = 0;
    printf("translated=%d\n", t);
    if (csops(getpid(), 0, &st, sizeof st) == 0) printf("csops=0x%08x\n", st);
    fflush(stdout);
}
EOF
cat >foo.c <<'EOF'
int foo(void) { return 42; }
EOF
cat >main.c <<'EOF'
#include "translated.h"
extern int foo(void);
int main(void) { say_translated(); printf("foo=%d\n", foo()); return 0; }
EOF
cat >self.c <<'EOF'
#include "translated.h"
int main(void) { say_translated(); printf("ok\n"); return 0; }
EOF

# build DIR ARCH [LDFLAGS]: libfoo.dylib, main (linked to it) and self
build() {
    mkdir -p "$1" &&
    "$CC" -arch "$2" -O1 ${3:-} -dynamiclib \
        -install_name @executable_path/libfoo.dylib -o "$1/libfoo.dylib" foo.c &&
    "$CC" -arch "$2" -O1 ${3:-} -o "$1/main" main.c -L"$1" -lfoo &&
    "$CC" -arch "$2" -O1 ${3:-} -o "$1/self" self.c
}

fail=0 n=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=$((fail + 1)); }

signed() { codesign -dv "$1" 2>&1 | grep -q 'flags='; }
valid()  { codesign -v "$1" >/dev/null 2>&1; }
edit()   { printf '%s\n' "$3" | "$DMR" "$1" "$2" >"$2.dd" 2>&1; }

# state STATE IN OUT: OUT from the signed, unedited IN, its signature checked
state() {
    case $1 in
    base)     cp "$2" "$3" && valid "$3" ;;
    stale)    edit "$2" "$3" "$APPEND" && signed "$3" && { valid "$3" && return 1; return 0; } ;;
    stripped) edit "$2" "$3.e" "$APPEND" && edit "$3.e" "$3" 'load-command delete codesig' &&
              { signed "$3" && return 1; return 0; } ;;
    resigned) edit "$2" "$3" "$APPEND" && codesign -s - -f "$3" >/dev/null 2>&1 && valid "$3" ;;
    esac
}

# run DIR PROG: rc is its exit status, 128 + the signal that killed it
run() {
    rc=0
    { (cd "$1" && exec "./$2") >"$1/stdout" 2>"$1/stderr"; } 2>/dev/null || rc=$?
}

# is OUTCOME DIR WANT: runs (and prints WANT), killed (137), or refused
# (137 or 134, and does not print WANT)
is() {
    case $1 in
    runs)    [ "$rc" = 0 ] && grep -qx "$3" "$2/stdout" ;;
    killed)  [ "$rc" = 137 ] ;;
    refused) { [ "$rc" = 137 ] || [ "$rc" = 134 ]; } && { grep -qx "$3" "$2/stdout" && return 1; return 0; } ;;
    esac
}

# expect NAME DIR PROG OUTCOME
expect() {
    case $3 in main) want=foo=42 ;; *) want=ok ;; esac
    run "$2" "$3"
    if is "$4" "$2" "$want"; then
        ok "$1: $4 (exit $rc)"
    else
        bad "$1" "expected $4, got exit $rc, stdout '$(tr '\n' ' ' <"$2/stdout")', stderr '$(head -c 300 "$2/stderr" | tr '\n' ' ')'"
    fi
}

# linked NAME ARCH STATE OUTCOME [HOSTOPTS]: main, as built or signed with
# HOSTOPTS, loading libfoo.dylib in STATE
linked() {
    n=$((n + 1)); d=$T/case/$n; mkdir -p "$d" || exit 1
    cp "$T/build/$2/main" "$d/main"
    if [ -n "${5:-}" ]; then
        codesign -s - -f -o "$5" "$d/main" >/dev/null 2>&1 &&
            codesign -dv "$d/main" 2>&1 | grep -qE "flags=.*$5" ||
            { bad "$1" "could not sign the host -o $5"; return; }
    fi
    state "$3" "$T/base/$2/libfoo.dylib" "$d/libfoo.dylib" ||
        { bad "$1" "could not make a $3 libfoo.dylib: $(cat "$d"/*.dd 2>/dev/null)"; return; }
    expect "$1" "$d" main "$4"
}

# alone NAME ARCH STATE OUTCOME [OPTS]: the program self, signed with OPTS
# if given, then put in STATE
alone() {
    n=$((n + 1)); d=$T/case/$n; mkdir -p "$d" || exit 1
    src=$T/base/$2/self
    if [ -n "${5:-}" ]; then
        cp "$src" "$d/signed" && codesign -s - -f -o "$5" "$d/signed" >/dev/null 2>&1 &&
            codesign -dv "$d/signed" 2>&1 | grep -qE "flags=.*$5" ||
            { bad "$1" "could not sign the program -o $5"; return; }
        src=$d/signed
    fi
    state "$3" "$src" "$d/self" ||
        { bad "$1" "could not make a $3 self: $(cat "$d"/*.dd 2>/dev/null)"; return; }
    expect "$1" "$d" self "$4"
}

# control ARCH TRANSLATED: the unedited subjects run, translated or not
control() {
    linked "$1 linked, unedited" "$1" base runs
    grep -qx "translated=$2" "$d/stdout" || bad "$1 linked, unedited" "expected translated=$2"
    alone "$1 program, unedited" "$1" base runs
    grep -qx "translated=$2" "$d/stdout" || bad "$1 program, unedited" "expected translated=$2"
}

# The x86_64 linker leaves its output unsigned: sign it, so there is a
# signature for an edit to leave stale.
for a in arm64 x86_64; do
    build "$T/build/$a" $a "$PAD" || { echo "apple_silicon_signing_test: building the $a subjects failed" >&2; exit 1; }
    mkdir -p "$T/base/$a"
    for f in libfoo.dylib self; do
        cp "$T/build/$a/$f" "$T/base/$a/$f"
        signed "$T/base/$a/$f" || codesign -s - -f "$T/base/$a/$f" >/dev/null 2>&1
    done
done

echo "INFO csrutil status: $(csrutil status 2>&1 | head -1)"
echo "INFO kern.bootargs: '$(sysctl -n kern.bootargs 2>&1)'"
control arm64 0
st=$(sed -n 's/^csops=//p' "$d/stdout")
case $st in
0x????????) ;;
*) bad "arm64 program, unedited" "printed no csops status"; st=0x00000200 ;;
esac
if [ $((st & 0x200)) -ne 0 ]; then
    echo "INFO arm64: an unedited program's csops status is $st, with CS_KILL (0x200)"
    killopt=
else
    echo "INFO arm64: an unedited program's csops status is $st, without CS_KILL (0x200), unlike a real Mac: the stale rows sign their program -o kill"
    killopt=kill
fi
linked "arm64 linked, stale${killopt:+, host -o kill}"   arm64 stale killed $killopt
alone  "arm64 program, stale${killopt:+, -o kill}"       arm64 stale killed $killopt
linked "arm64 linked, stripped"    arm64 stripped refused
if [ -z "$killopt" ]; then
    alone "arm64 program, stripped" arm64 stripped refused
else
    n=$((n + 1)); d=$T/case/$n; mkdir -p "$d" || exit 1
    if state stripped "$T/base/arm64/self" "$d/self"; then
        run "$d" self
        echo "INFO arm64 program, stripped: not judged; it exits $rc here, where a real Mac's AMFI refuses an unsigned arm64 program"
    else
        bad "arm64 program, stripped" "could not make a stripped self: $(cat "$d"/*.dd 2>/dev/null)"
    fi
fi
linked "arm64 linked, re-signed"   arm64 resigned runs
alone  "arm64 program, re-signed"  arm64 resigned runs

build "$T/build/arm64-nopad" arm64 || { echo "apple_silicon_signing_test: building the unpadded arm64 subjects failed" >&2; exit 1; }
for f in libfoo.dylib:'only an x86_64 dylib or bundle can be grown' self:'which arm64 cannot load'; do
    name="arm64 ${f%%:*} without a header pad"
    n=$((n + 1)); mkdir -p "$T/case/$n" || exit 1
    in=$T/build/arm64-nopad/${f%%:*} out=$T/case/$n/${f%%:*}
    if edit "$in" "$out" "$APPEND"; then
        echo "SKIP $name: the linker left room for the command: $(grep 'header pad' "$out.dd")"
    elif grep -qF -- "${f#*:}" "$out.dd" && [ ! -e "$out" ]; then
        ok "$name: refused, saying '${f#*:}'"
    else
        bad "$name" "expected a refusal saying '${f#*:}' and no output: $(cat "$out.dd")"
    fi
done

if [ -z "$rosetta" ]; then
    echo "SKIP x86_64: no Rosetta (arch -x86_64 /usr/bin/true fails)"
else
    control x86_64 1
    linked "x86_64 linked, stale"       x86_64 stale    runs
    alone  "x86_64 program, stale"      x86_64 stale    runs
    linked "x86_64 linked, stripped"    x86_64 stripped runs
    alone  "x86_64 program, stripped"   x86_64 stripped runs
    linked "x86_64 linked, re-signed"   x86_64 resigned runs
    alone  "x86_64 program, re-signed"  x86_64 resigned runs
    linked "x86_64 kill host, re-signed" x86_64 resigned runs   kill
    linked "x86_64 kill host, stale"    x86_64 stale    killed  kill
    linked "x86_64 kill host, stripped" x86_64 stripped runs    kill
fi

[ "$fail" -eq 0 ] || { echo "$fail failed"; exit 1; }
echo "all passed"
