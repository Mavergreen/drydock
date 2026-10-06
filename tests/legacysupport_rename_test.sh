#!/bin/sh
# tests/legacysupport_rename_test.sh -- `symbol rename` across a real static
# archive, MacPorts' libMacportsLegacySupport.a: _clock_gettime becomes
# ___recaulk_impl_clock_gettime, a stub defines clock_gettime on top of it,
# and a program that calls it links and runs.
#
#   sh tests/legacysupport_rename_test.sh <bindir>
#
# Looks for the library at $LEGACYSUPPORT_A, /opt/local/lib, then Mavergreen
# products' bundled copies. Exits 77 where there is none.
set -u

BIN="${1:?usage: legacysupport_rename_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "legacysupport_rename_test: $DMR not found or not executable" >&2; exit 1; }
command -v ranlib >/dev/null 2>&1 && command -v lipo >/dev/null 2>&1 \
    || { echo "SKIP: legacysupport_rename_test: no ranlib or lipo on this host"; exit 77; }
CC="${CC:-clang}"
ZERO_AR_DATE=1
export ZERO_AR_DATE

LIB=
if [ -n "${LEGACYSUPPORT_A:-}" ]; then
    LIB=$LEGACYSUPPORT_A
else
    for f in /opt/local/lib/libMacportsLegacySupport.a \
             /usr/local/mavergreen/*/lib/libMacportsLegacySupport.a \
             /usr/local/mavergreen/*/lib/rustlib/*/lib/libMacportsLegacySupport.a; do
        [ -f "$f" ] && { LIB=$f; break; }
    done
fi
[ -n "$LIB" ] && [ -f "$LIB" ] \
    || { echo "SKIP: legacysupport_rename_test: no libMacportsLegacySupport.a (set LEGACYSUPPORT_A)"; exit 77; }
echo "INFO: legacysupport_rename_test: using $LIB"

T=$(mktemp -d "${TMPDIR:-/tmp}/legacysupport_rename_test.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }

if lipo -info "$LIB" 2>/dev/null | grep -q '^Architectures in the fat file'; then
    lipo -thin x86_64 -output "$T/in.a" "$LIB" 2>"$T/lipo.err" \
        || { echo "SKIP: legacysupport_rename_test: $LIB has no x86_64 slice"; exit 77; }
else
    cp "$LIB" "$T/in.a" || exit 1
fi
nm -gU "$T/in.a" 2>/dev/null | awk '$NF == "_clock_gettime" && $(NF-1) == "T" { f = 1 } END { exit !f }' \
    || { echo "SKIP: legacysupport_rename_test: $LIB does not define _clock_gettime"; exit 77; }

printf '%s\n' 'symbol rename _clock_gettime ___recaulk_impl_clock_gettime' \
    | "$DMR" "$T/in.a" "$T/out.a" >"$T/run.out" 2>"$T/run.err" \
    && ok "rename exits 0" || bad "rename" "$(cat "$T/run.err")"
grep -q 'symbol rename _clock_gettime -> ___recaulk_impl_clock_gettime: [1-9]' "$T/run.err" \
    && ok "rename reports entries" || bad "report" "$(cat "$T/run.err")"
nm -gU "$T/out.a" 2>/dev/null | awk '$NF == "___recaulk_impl_clock_gettime" && $(NF-1) == "T" { d = 1 } $NF == "_clock_gettime" { o = 1 } END { exit !(d && !o) }' \
    && ok "archive defines the new name and no longer the old" || bad "nm archive" "$(nm -gU "$T/out.a" 2>&1 | grep clock_gettime)"

cat >"$T/stub.c" <<'EOT'
struct timespec;
int __recaulk_impl_clock_gettime(int, struct timespec *);
int clock_gettime(int clk, struct timespec *ts) { return __recaulk_impl_clock_gettime(clk, ts); }
EOT
cat >"$T/main.c" <<'EOT'
#include <stdio.h>
#include <time.h>
#ifndef CLOCK_REALTIME
#define CLOCK_REALTIME 0
int clock_gettime(int, struct timespec *);
#endif
int main(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return 2;
    printf("%ld\n", (long)ts.tv_sec);
    return 0;
}
EOT
"$CC" -arch x86_64 -mmacosx-version-min=10.9 -c -o "$T/stub.o" "$T/stub.c" \
    && "$CC" -arch x86_64 -mmacosx-version-min=10.9 -c -o "$T/main.o" "$T/main.c" \
    || { echo "legacysupport_rename_test: cannot compile the fixtures" >&2; exit 1; }
if "$CC" -arch x86_64 -mmacosx-version-min=10.9 -o "$T/prog" "$T/main.o" "$T/stub.o" "$T/out.a" >"$T/link.err" 2>&1; then
    ok "links against the stub and the renamed archive"
    sec=$("$T/prog") && [ "${sec:-0}" -gt 1600000000 ] \
        && ok "runs and prints a plausible time ($sec)" || bad "run" "printed '${sec:-}'"
    nm "$T/prog" | awk '$NF == "___recaulk_impl_clock_gettime" && $(NF-1) == "T" { a = 1 } $NF == "_clock_gettime" && $(NF-1) == "T" { b = 1 } END { exit !(a && b) }' \
        && ok "the program defines the stub's _clock_gettime and legacy-support's implementation" \
        || bad "nm program" "$(nm "$T/prog" | grep clock_gettime)"
else
    bad "link" "$(cat "$T/link.err")"
fi

# The index, as in archive_rename_test.sh: 10.9's ranlib leaves the string
# pool's padding uninitialised, so there the date and padding are masked.
index() {
    od -An -v -tu1 "$1" | awk -v mode="$2" -v mask="${MASK:-0}" '
        { for (i = 1; i <= NF; i++) b[n++] = $i }
        function le(o) { return b[o] + 256 * (b[o+1] + 256 * (b[o+2] + 256 * b[o+3])) }
        function str(o,   s) { s = ""; while (b[o] != 0) s = s sprintf("%c", b[o++]); return s }
        END {
            if (str(8) !~ /^#1\//) { print "no #1/N index header"; exit 1 }
            nl = 0; for (i = 11; b[i] >= 48 && b[i] <= 57; i++) nl = nl * 10 + b[i] - 48
            sz = 0; for (i = 56; b[i] >= 48 && b[i] <= 57; i++) sz = sz * 10 + b[i] - 48
            if (str(68) !~ /^__\.SYMDEF/) { print "first member is not an index"; exit 1 }
            body = 68 + nl; nb = le(body); pool = body + 8 + nb; strsize = le(body + 4 + nb)
            used = 0
            for (e = 0; e < nb / 8; e++) {
                x = le(body + 4 + 8 * e)
                if (mode == "names") print str(pool + x), le(body + 8 + 8 * e)
                end = pool + x + length(str(pool + x)) + 1
                if (end - pool > used) used = end - pool
            }
            if (mode == "padding") { if (used < strsize) print pool + strsize - 1; exit 0 }
            if (mode != "bytes") exit 0
            for (i = 8; i < 68 + sz; i++) {
                if (mask && ((i >= 24 && i < 36) || (i >= pool + used && i < pool + strsize))) print "masked"
                else print b[i]
            }
        }'
}

cp "$T/out.a" "$T/ranlibbed.a" && ranlib "$T/ranlibbed.a" || exit 1
MASK=0
[ "$(uname -s)" = Darwin ] && [ "$(uname -r | cut -d. -f1)" = 13 ] && MASK=1
index "$T/out.a" bytes >"$T/idx_ours" && index "$T/ranlibbed.a" bytes >"$T/idx_ranlib" \
    || bad "index" "cannot read an index: $(cat "$T/idx_ours" "$T/idx_ranlib")"
if cmp -s "$T/idx_ours" "$T/idx_ranlib"; then
    ok "index: byte-identical to ranlib's $( [ $MASK = 1 ] && echo '(date and string padding masked)' || echo '(strict)')"
else
    bad "index" "differs from ranlib's: $(diff "$T/idx_ours" "$T/idx_ranlib" | head -5 | tr '\n' ' ')"
fi

[ "$fail" -eq 0 ]
