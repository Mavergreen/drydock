#!/bin/sh
# platform: macOS-only -- Mach-O fixtures linked with the host's clang and ld64
# tests/uuid_stamp_test.sh -- the `uuid set stamped` statement and the
# `uuid:` line of `info`.
#
# Every fixture is x86_64 and 10.9, the slice Drydock exists to rewrite, but
# nothing here executes one: what a stamp changes is sixteen bytes of LC_UUID,
# so every fact comes from `drydock-macho-rewrite info`, and the test needs no
# Rosetta on an Apple Silicon host. The expected version comes from
# UPSTREAM_VERSION, never a literal, so a release bump cannot redden it.
set -eu
BIN="${1:?usage: uuid_stamp_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "uuid_stamp_test: $DMR not found" >&2; exit 1; }
[ -x "$BIN/makefat" ] || { echo "uuid_stamp_test: need makefat in $BIN" >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lib/toolchain.sh"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FF="-arch x86_64 -mmacosx-version-min=10.9"
T=$(mktemp -d "${TMPDIR:-/tmp}/uuid_stamp_test.XXXXXX")
T=$(cd "$T" && pwd -P)

fails=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fails=$((fails + 1)); }
reached_end=0
trap 'rc=$?; rm -rf "$T"; if [ "$reached_end" -eq 0 ]; then
    echo "uuid_stamp_test: FATAL -- aborted early (exit $rc); everything after the last PASS/FAIL line never ran" >&2
fi' EXIT

VER=$(sed -n '1s/^\([0-9]*\)\.\([0-9]*\).*/\1.\2/p' "$HERE/../UPSTREAM_VERSION")
[ -n "$VER" ] || { echo "uuid_stamp_test: cannot read MAJOR.MINOR from UPSTREAM_VERSION" >&2; exit 1; }
PREFIX=$(printf 'DD0C%02X%02X' "${VER%%.*}" "${VER#*.}")

# uuid_line FILE [SLICE] -- the `uuid:` line info prints, for SLICE of a fat file.
uuid_line() {
    if [ $# -eq 1 ]; then
        "$DMR" info "$1" | sed -n 's/^uuid: //p'
    else
        "$DMR" info "$1" | awk -v s="slice $2:" '
            index($0, "slice ") == 1 { here = (index($0, s) == 1) }
            here && index($0, "uuid: ") == 1 { print substr($0, 7) }'
    fi
}
uuid_of() { uuid_line "$@" | awk '{ sub(/,$/, "", $1); print $1 }'; }

# run FILE OUT STATEMENT... -- the statements, one per line, on stdin.
run() {
    run_in=$1 run_out=$2; shift 2
    rm -f "$run_out"
    run_rc=0
    printf '%s\n' "$@" | "$DMR" "$run_in" "$run_out" >"$T/run.out" 2>"$T/run.err" || run_rc=$?
    return 0
}

printf 'int main(void) { return 0; }\n' >"$T/main.c"
printf 'int lib_answer(void) { return 42; }\n' >"$T/lib.c"
"$CC" $FF -o "$T/prog" "$T/main.c"
"$CC" $FF -Wl,-no_uuid -o "$T/nouuid" "$T/main.c"
"$CC" $FF -dynamiclib -install_name /usr/local/lib/libtight.dylib -o "$T/libtight.dylib" "$T/lib.c"

# ---- info reports the UUID, and whether Drydock stamped it ------------------
before=$(uuid_line "$T/prog")
case "$before" in
    [0-9A-F]*-*-*-*-*) case "$before" in *stamped*) bad "info: unstamped" "says stamped: $before" ;;
                                           *) ok "info: an ordinary UUID, printed and not called stamped" ;; esac ;;
    *) bad "info: unstamped" "no uuid: line, or not a UUID: '$before'" ;;
esac
case "$(uuid_line "$T/nouuid")" in
    none) ok "info: an image with no LC_UUID says uuid: none" ;;
    *) bad "info: no LC_UUID" "got '$(uuid_line "$T/nouuid")'" ;;
esac

# ---- the stamp: marker, version, and the rest derived from the old UUID ------
run "$T/prog" "$T/prog.s1" "uuid set stamped"
if [ "$run_rc" -ne 0 ]; then
    bad "stamp" "exit $run_rc: $(cat "$T/run.err")"
else
    after=$(uuid_line "$T/prog.s1")
    case "$after" in
        "$PREFIX"-*", stamped by drydock $VER") ok "stamp: $after" ;;
        *) bad "stamp" "expected $PREFIX-..., stamped by drydock $VER; got '$after'" ;;
    esac
    grep -q "$(uuid_of "$T/prog") -> $(uuid_of "$T/prog.s1")" "$T/run.err" &&
        ok "stamp: the report names the old UUID and the new" ||
        bad "stamp report" "no 'OLD -> NEW' line: $(cat "$T/run.err")"
fi
run "$T/prog" "$T/prog.s2" "uuid set stamped"
[ -n "$(uuid_of "$T/prog.s1")" ] && [ "$(uuid_of "$T/prog.s1")" = "$(uuid_of "$T/prog.s2")" ] &&
    ok "stamp: the same input stamps to the same UUID" ||
    bad "stamp determinism" "$(uuid_of "$T/prog.s1") then $(uuid_of "$T/prog.s2")"
cmp -s "$T/prog" "$T/prog.s1" && bad "stamp" "the output is the input, byte for byte" || true
[ -e "$T/prog.s1" ] && [ "$(wc -c <"$T/prog")" -eq "$(wc -c <"$T/prog.s1")" ] &&
    ok "stamp: the file keeps its size" || bad "stamp size" "the file changed size"

# ---- written first, applied last: a later raise does not wipe the stamp ------
# Twelve ~230-byte LC_LOAD_DYLIBs overflow any header pad a linker leaves by
# default (ld64's and lld's are both under 2.5 KB), so the image must raise.
x200=$(printf '%0200d' 0 | tr 0 x)
set -- "uuid set stamped"
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do set -- "$@" "dylib append /usr/local/lib/$n$x200.dylib"; done
run "$T/libtight.dylib" "$T/libtight.s" "$@"
if [ "$run_rc" -ne 0 ]; then
    bad "stamp then raise" "exit $run_rc: $(cat "$T/run.err")"
elif ! grep -q "new UUID" "$T/run.out" "$T/run.err"; then
    bad "stamp then raise" "precondition: the dylib append did not raise the image; the case proves nothing"
else
    case "$(uuid_line "$T/libtight.s")" in
        "$PREFIX"-*", stamped by drydock $VER") ok "stamp then raise: the stamp outlives the raise's new UUID" ;;
        *) bad "stamp then raise" "got '$(uuid_line "$T/libtight.s")'" ;;
    esac
fi

# ---- nothing to stamp ---------------------------------------------------------
run "$T/nouuid" "$T/nouuid.s" "uuid set stamped"
if [ "$run_rc" -eq 1 ] && [ ! -e "$T/nouuid.s" ] && grep -q "uuid set stamped matched nothing" "$T/run.err"; then
    ok "no LC_UUID: refused, nothing written"
else
    bad "no LC_UUID" "exit $run_rc, out $( [ -e "$T/nouuid.s" ] && echo written || echo absent): $(cat "$T/run.err")"
fi
run "$T/nouuid" "$T/nouuid.s" "allow-unmatched" "uuid set stamped"
[ "$run_rc" -eq 0 ] && [ "$(uuid_line "$T/nouuid.s")" = none ] &&
    ok "no LC_UUID, allow-unmatched: written, still no UUID" ||
    bad "no LC_UUID, allow-unmatched" "exit $run_rc: $(cat "$T/run.err")"
run "$T/prog" "$T/prog.del" "uuid set stamped" "load-command delete uuid"
[ "$run_rc" -eq 1 ] && [ ! -e "$T/prog.del" ] &&
    ok "a uuid deleted later in the script leaves nothing to stamp: refused" ||
    bad "stamp then delete" "exit $run_rc: $(cat "$T/run.err")"

# ---- a universal file: each slice from its own UUID ---------------------------
# Two x86_64 programs, the second declared x86_64h, as tests/cli_test.sh does:
# no compiler this runs under (the cross clang, 10.9's own) builds an arm64 or
# a true x86_64h slice, and what is under test is per-slice selection.
printf 'int main(void) { return 1; }\n' >"$T/main1.c"
"$CC" $FF -o "$T/prog1" "$T/main1.c"
"$BIN/makefat" "$T/fat" "$T/prog" 0x1000007 3 12 "$T/prog1" 0x1000007 8 12
run "$T/fat" "$T/fat.s" "uuid set stamped"
if [ "$run_rc" -ne 0 ]; then
    bad "fat" "exit $run_rc: $(cat "$T/run.err")"
else
    x=$(uuid_of "$T/fat.s" x86_64) a=$(uuid_of "$T/fat.s" x86_64h)
    case "$x:$a" in
        "$PREFIX"-*:"$PREFIX"-*) [ "$x" = "$(uuid_of "$T/prog.s1")" ] && [ "$x" != "$a" ] &&
            ok "fat: both slices stamped, each from its own UUID" ||
            bad "fat" "x86_64 $x (thin stamp $(uuid_of "$T/prog.s1")), x86_64h $a" ;;
        *) bad "fat" "x86_64 '$x', x86_64h '$a'" ;;
    esac
fi
run "$T/fat" "$T/fat.x" "arch x86_64" "uuid set stamped"
[ "$run_rc" -eq 0 ] && [ "$(uuid_of "$T/fat.x" x86_64h)" = "$(uuid_of "$T/fat" x86_64h)" ] &&
    ok "fat, arch x86_64: the x86_64h slice keeps its UUID" ||
    bad "fat, arch x86_64" "exit $run_rc; x86_64h $(uuid_of "$T/fat" x86_64h) -> $(uuid_of "$T/fat.x" x86_64h)"

reached_end=1
echo "uuid_stamp_test: $fails failure(s)"
[ "$fails" -eq 0 ]
