#!/bin/sh
# tests/mantle_raise_test.sh -- a real chained-fixups dylib, taken to classic
# fixups, given a load command it has no room for, and given a long rpath.
#
#   sh tests/mantle_raise_test.sh <bindir>
#
# The subject is the Mantle framework in ~/Downloads/OpenCode.app. It works on
# copies in $TMPDIR and never writes the app. Each step is run on the result
# of the one before: `fixups set classic`, `dylib append /usr/lib/libz.1.dylib`
# (the header has no room, so the image is raised), then `rpath replace` of
# the binary's first LC_RPATH -- appended first, where it has none -- by a
# 120-byte path.
#
# Local only: it SKIPs (77), saying why, where the app is absent or its binary
# is not x86_64.
set -u

BIN="${1:?usage: mantle_raise_test.sh <bindir>}"
DMR="$BIN/drydock-macho-rewrite"
[ -x "$DMR" ] || { echo "mantle_raise_test: $DMR not found or not executable" >&2; exit 1; }

SRC="$HOME/Downloads/OpenCode.app/Contents/Frameworks/Mantle.framework/Versions/A/Mantle"
[ -f "$SRC" ] || { echo "SKIP: $SRC is absent"; exit 77; }
case $(lipo -info "$SRC" 2>/dev/null) in
    *x86_64*) ;;
    *) echo "SKIP: $SRC has no x86_64 slice"; exit 77 ;;
esac

T=$(mktemp -d "${TMPDIR:-/tmp}/mantle-raise.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

before=$(cksum <"$SRC")
cp "$SRC" "$T/m0" || exit 1

fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=$((fail + 1)); }
pad() { "$DMR" info "$1" | sed -n 's/^header pad: \([0-9]*\) bytes.*/\1/p'; }

echo 'fixups set classic' | "$DMR" "$T/m0" "$T/m1" >"$T/o1" 2>&1 \
    && ok "fixups set classic: exit 0" || { bad "fixups set classic" "$(cat "$T/o1")"; exit 1; }
"$DMR" info "$T/m1" | grep -q 'LC_DYLD_CHAINED_FIXUPS' \
    && bad "classic" "info still shows LC_DYLD_CHAINED_FIXUPS" || ok "classic: no chained fixups left"
pad0=$(pad "$T/m1")

echo 'dylib append /usr/lib/libz.1.dylib' | "$DMR" "$T/m1" "$T/m2" >"$T/o2" 2>&1 \
    && ok "dylib append: exit 0" || { bad "dylib append" "$(cat "$T/o2")"; exit 1; }
grep -q 'grew the header pad.*contents raised by 0x[0-9a-f]*; new UUID' "$T/o2" \
    && ok "dylib append: the header grew by a raise" || bad "dylib append" "no raise reported: $(cat "$T/o2")"
"$DMR" info "$T/m2" | grep -A1 'LC_LOAD_DYLIB' | grep -q 'path=/usr/lib/libz.1.dylib$' \
    && ok "info shows the new LC_LOAD_DYLIB" || bad "info" "no LC_LOAD_DYLIB for libz"
pad2=$(pad "$T/m2")
[ "${pad0:-0}" -lt 48 ] && [ "${pad2:-0}" -gt "${pad0:-0}" ] \
    && ok "info shows the pad grew ($pad0 -> $pad2 bytes)" || bad "info" "pad $pad0 -> $pad2"
"$DMR" verify "$T/m2" >"$T/v2" 2>&1 && ok "verify after dylib append" || bad "verify" "$(cat "$T/v2")"

old=$("$DMR" info "$T/m2" | sed -n 's/^  rpath=//p' | head -1)
if [ -z "$old" ]; then
    old=@loader_path/../Frameworks
    echo "rpath append $old" | "$DMR" "$T/m2" "$T/m2b" >"$T/o2b" 2>&1 \
        && mv "$T/m2b" "$T/m2" || { bad "rpath append" "$(cat "$T/o2b")"; exit 1; }
fi
new=@loader_path/$(awk 'BEGIN { for (i = 0; i < 103; i++) printf "y" }')/lib
[ ${#new} -eq 120 ] || { echo "mantle_raise_test: bad path length ${#new}" >&2; exit 1; }

echo "rpath replace $old $new" | "$DMR" "$T/m2" "$T/m3" >"$T/o3" 2>&1 \
    && ok "rpath replace: exit 0" || { bad "rpath replace" "$(cat "$T/o3")"; exit 1; }
info3=$("$DMR" info "$T/m3")
printf '%s\n' "$info3" | grep -q "^  rpath=$new\$" \
    && ok "info shows the replaced rpath" || bad "info" "no rpath=$new"
printf '%s\n' "$info3" | grep -q "^  rpath=$old\$" \
    && bad "info" "the old rpath is still there" || ok "info: the old rpath is gone"
printf '%s\n' "$info3" | grep -A1 'LC_LOAD_DYLIB' | grep -q 'path=/usr/lib/libz.1.dylib$' \
    && ok "info still shows libz" || bad "info" "libz lost"
"$DMR" verify "$T/m3" >"$T/v3" 2>&1 && ok "verify after rpath replace" || bad "verify" "$(cat "$T/v3")"

[ "$(cksum <"$SRC")" = "$before" ] \
    && ok "the original is untouched" || bad "original" "changed"

[ "$fail" -eq 0 ]
