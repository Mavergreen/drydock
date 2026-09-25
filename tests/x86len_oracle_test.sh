#!/bin/sh
# tests/x86len_oracle_test.sh -- src/x86len.h's instruction boundaries must
# be otool's, over every function of a corpus of real 10.9 images.
#
#   sh tests/x86len_oracle_test.sh <bindir>
#
# The corpus covers C, C++ and Objective-C, SSE through AVX2, FMA and AES-NI.
# Local only: it SKIPs, saying why, where otool or a corpus image is absent;
# CI's macos-26 runner keeps its libraries in the shared cache.
set -u

BIN="${1:?usage: x86len_oracle_test.sh <bindir>}"
ORACLE="$BIN/x86len_oracle"
[ -x "$ORACLE" ] || { echo "x86len_oracle_test: $ORACLE not found or not executable" >&2; exit 1; }

command -v otool >/dev/null 2>&1 || { echo "SKIP: no otool here"; exit 77; }
command -v lipo >/dev/null 2>&1 || { echo "SKIP: no lipo here"; exit 77; }
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
    lipo "$f" -thin x86_64 -output "$thin" 2>/dev/null || cp "$f" "$thin"
    rc=0; otool -tv "$thin" | "$ORACLE" "$thin" >"$T/out" || rc=$?
    sed "s|$thin|$f|" "$T/out"
    [ "$rc" -eq 0 ] || fail=$((fail + 1))
done

# The positive controls: with one of otool's lines gone, or all of them, the
# comparison fails.
thin="$T/libsystem_m.dylib"
rc=0; otool -tv "$thin" | awk 'NR != 10' | "$ORACLE" "$thin" >"$T/out" || rc=$?
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
rc=0; otool -tv "$thin" | X86LEN_ORACLE_NO_ALLOWLIST=1 "$ORACLE" "$thin" >"$T/out" || rc=$?
if [ "$rc" -eq 1 ] && grep -q '^REFUSED' "$T/out"; then
    echo "PASS the positive control: an unlisted decoder refusal on real code is a failure"
else
    echo "FAIL the positive control: with the allow-list disabled, the oracle said (exit $rc):"
    cat "$T/out"
    fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] || { echo "x86len_oracle_test: $fail failure(s)"; exit 1; }
echo "x86len_oracle_test: all passed"
