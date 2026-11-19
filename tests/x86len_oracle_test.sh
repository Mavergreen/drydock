#!/bin/sh
# platform: macOS-only -- 10.9's otool over a corpus of 10.9's own images
# tests/x86len_oracle_test.sh -- src/x86len.h's instruction boundaries must
# be otool's, over every function of a corpus of real 10.9 images.
#
#   sh tests/x86len_oracle_test.sh <bindir>
#
# The corpus covers C, C++ and Objective-C, SSE through AVX2, FMA and AES-NI.
# Local only: it SKIPs, saying why, where cctools' otool or a corpus image is
# absent: /usr/bin/otool is only a stub without the Command Line Tools (the
# 10.9 guest), modern Xcode's otool is llvm-otool, and CI's macos-26 runner
# keeps its libraries in the shared cache.
set -u

BIN="${1:?usage: x86len_oracle_test.sh <bindir>}"
ORACLE="$BIN/x86len_oracle"
[ -x "$ORACLE" ] || { echo "x86len_oracle_test: $ORACLE not found or not executable" >&2; exit 1; }

DEV=$(xcode-select -p 2>/dev/null) || DEV=
TOOLS=
for d in "$DEV/usr/bin" "$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin"; do
    [ -n "$DEV" ] && [ -x "$d/otool" ] && [ -x "$d/lipo" ] && { TOOLS=$d; break; }
done
[ -n "$TOOLS" ] || { echo "SKIP: no cctools otool here: no developer tools at '${DEV:-(none)}', and /usr/bin/otool is only their stub"; exit 77; }
CCTOOLS_OTOOL=$TOOLS/otool CCTOOLS_LIPO=$TOOLS/lipo
v=$("$CCTOOLS_OTOOL" --version 2>&1 | head -1)
case $v in "otool(1): Apple Inc. version cctools-"*) ;;
    *) echo "SKIP: $CCTOOLS_OTOOL is not cctools' otool, whose linear sweep is the oracle: ${v:-no version}"; exit 77 ;; esac
AF=/System/Library/Frameworks/Accelerate.framework/Versions/A/Frameworks
CORPUS="/usr/lib/system/libsystem_c.dylib /usr/lib/system/libsystem_m.dylib
/usr/lib/system/libsystem_platform.dylib /usr/lib/system/libcorecrypto.dylib
/usr/lib/libobjc.A.dylib /usr/lib/libc++.1.dylib
$AF/vImage.framework/Versions/A/vImage $AF/vecLib.framework/Versions/A/libBLAS.dylib
$AF/vecLib.framework/Versions/A/libvDSP.dylib $AF/vecLib.framework/Versions/A/libvMisc.dylib
/usr/bin/groff /bin/ls"
for f in $CORPUS; do
    [ -f "$f" ] || { echo "SKIP: $f is absent; the corpus is 10.9's own images"; exit 77; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/x86len-oracle.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
for f in $CORPUS; do
    thin="$T/$(basename "$f")"
    "$CCTOOLS_LIPO" "$f" -thin x86_64 -output "$thin" 2>/dev/null || cp "$f" "$thin"
    rc=0; "$CCTOOLS_OTOOL" -tv "$thin" | "$ORACLE" "$thin" >"$T/out" || rc=$?
    sed "s|$thin|$f|" "$T/out"
    [ "$rc" -eq 0 ] || fail=$((fail + 1))
done

# The positive controls: with one of otool's lines gone, or all of them, the
# comparison fails.
thin="$T/libsystem_m.dylib"
rc=0; "$CCTOOLS_OTOOL" -tv "$thin" | awk 'NR != 10' | "$ORACLE" "$thin" >"$T/out" || rc=$?
if [ "$rc" -eq 1 ] && grep -q '^MISMATCH' "$T/out"; then
    echo "PASS the positive control: a boundary otool does not have is a mismatch"
else
    echo "FAIL the positive control: with otool's tenth line gone, the oracle said (exit $rc):"
    cat "$T/out"
    fail=$((fail + 1))
fi

rc=0; : | "$ORACLE" "$thin" >"$T/out" || rc=$?
if [ "$rc" -eq 1 ] && grep -q ' 0 instructions' "$T/out"; then
    echo "PASS the positive control: comparing nothing is a failure"
else
    echo "FAIL the positive control: with no otool output, the oracle said (exit $rc): $(cat "$T/out")"
    fail=$((fail + 1))
fi

# The third positive control: a decoder refusal on bytes otool decodes as
# real code is a failure unless the exact site is allow-listed. libsystem_c
# has exactly one such site; with the allow-list disabled, it must surface
# as an unlisted REFUSED, not silently pass.
thin="$T/libsystem_c.dylib"
rc=0; "$CCTOOLS_OTOOL" -tv "$thin" | X86LEN_ORACLE_NO_ALLOWLIST=1 "$ORACLE" "$thin" >"$T/out" || rc=$?
if [ "$rc" -eq 1 ] && grep -q '^REFUSED' "$T/out"; then
    echo "PASS the positive control: an unlisted decoder refusal on real code is a failure"
else
    echo "FAIL the positive control: with the allow-list disabled, the oracle said (exit $rc):"
    cat "$T/out"
    fail=$((fail + 1))
fi

# The fourth positive control: an allow-listed site that stops occurring is
# a failure, not a note (X86LEN_ORACLE_EXTRA_ALLOW adds one that this corpus
# never produces).
thin="$T/libsystem_m.dylib"
rc=0; "$CCTOOLS_OTOOL" -tv "$thin" | X86LEN_ORACLE_EXTRA_ALLOW=0xdeadbeefdeadbeef "$ORACLE" "$thin" >"$T/out" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'did not occur' "$T/out"; then
    echo "PASS the positive control: a stale allow-listed site is a failure"
else
    echo "FAIL the positive control: with a bogus allow-listed site, the oracle said (exit $rc):"
    cat "$T/out"
    fail=$((fail + 1))
fi

# The fifth positive control: a decode that runs past its function's end is
# a mismatch (X86LEN_ORACLE_TEST_SHRINK moves that end earlier by 3 bytes,
# landing inside libsystem_m.dylib's first compared function's last
# instruction; the corpus has no function boundary this actually happens
# at today).
rc=0; "$CCTOOLS_OTOOL" -tv "$thin" | X86LEN_ORACLE_TEST_SHRINK=3 "$ORACLE" "$thin" >"$T/out" || rc=$?
if [ "$rc" -eq 1 ] && grep -q '^MISMATCH' "$T/out"; then
    echo "PASS the positive control: a decode past its function's end is a mismatch"
else
    echo "FAIL the positive control: with the first function's end shrunk by 3, the oracle said (exit $rc):"
    cat "$T/out"
    fail=$((fail + 1))
fi

# The oracle's own controls: with no developer tools (the guest: /usr/bin/otool
# is a stub) or with an otool that is not cctools', this test skips, saying why.
skips() { # skips WHAT DEVELOPER_DIR REASON
    rc=0; DEVELOPER_DIR=$2 sh "$0" "$BIN" >"$T/skip" 2>&1 || rc=$?
    if [ "$rc" -eq 77 ] && grep -q "^SKIP: .*$3" "$T/skip"; then echo "PASS the positive control: $1 is a skip"
    else echo "FAIL the positive control: $1: exit $rc, $(cat "$T/skip")"; fail=$((fail + 1)); fi
}
skips 'no developer tools' "$T/nodev" 'no cctools otool here'
mkdir -p "$T/llvm/usr/bin"
printf '#!/bin/sh\necho "llvm-otool(1): Apple Inc. version cctools-1010.6"\n' >"$T/llvm/usr/bin/otool"
cp "$CCTOOLS_LIPO" "$T/llvm/usr/bin/lipo"; chmod +x "$T/llvm/usr/bin/otool"
skips "llvm-otool" "$T/llvm" "is not cctools' otool"

[ "$fail" -eq 0 ] || { echo "x86len_oracle_test: $fail failure(s)"; exit 1; }
echo "x86len_oracle_test: all passed"
