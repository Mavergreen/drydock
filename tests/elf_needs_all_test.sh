#!/bin/sh
# platform: host-agnostic -- a stub readelf stands in for binutils
#   usage: elf_needs_all_test.sh
#          packaging/elf-needs-all.sh reports the highest ISA level and glibc version over every ELF in
#          a directory, not one binary's, and says what it cannot measure
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S="$HERE/../packaging/elf-needs-all.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/elf-needs-all.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1" >&2; fails=$((fails + 1)); }

# platform: this test runs on a Mac with no readelf, so a stub readelf stands in for binutils: it prints,
# for a file whose text names its needs, the lines elf-needs.sh reads.
mkdir "$T/stub" "$T/bin" "$T/none"
cat >"$T/stub/readelf" <<'STUB'
#!/bin/sh
f=$2
case $1 in
  -n) sed -n 's/^isa=/      x86 ISA needed: /p' "$f" ;;
  -V) sed -n 's/^glibc=/  0x0010: Name: GLIBC_/p' "$f" ;;
esac
STUB
chmod +x "$T/stub/readelf"
elf() { printf '\177ELF\nisa=%s\nglibc=%s\n' "$2" "$3" >"$1"; }
elf "$T/bin/a" x86-64-baseline 2.2.5
elf "$T/bin/b" x86-64-baseline 2.34
elf "$T/bin/c" x86-64-v2 2.9
echo 'not an elf' >"$T/bin/README"

out=$(PATH="$T/stub:$PATH" sh "$S" "$T/bin" 2>"$T/err"); rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | sed -n 's/^glibc-needed=//p')" = 2.34 ] \
  && ok "the highest glibc over every ELF, by number (2.34 over 2.9)" || bad "glibc: rc $rc, $out"
[ "$(printf '%s\n' "$out" | sed -n 's/^isa-needed=//p')" = x86-64-v2 ] \
  && ok "the highest ISA level over every ELF" || bad "isa: $out"
printf '%s\n' "$out" | grep -qx 'elf-count=3' && ok "counts the ELFs it measured, skipping non-ELF files" || bad "count: $out"

rm "$T/bin/c"
out=$(PATH="$T/stub:$PATH" sh "$S" "$T/bin" 2>/dev/null)
[ "$(printf '%s\n' "$out" | sed -n 's/^isa-needed=//p')" = x86-64-baseline ] \
  && ok "baseline when every ELF is baseline" || bad "baseline: $out"

PATH="$T/stub:$PATH" sh "$S" "$T/none" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "a directory with no ELF is an error" || bad "no ELF: rc $rc"
printf '\177ELF\nisa=x86-64-baseline\n' >"$T/bin/d"
PATH="$T/stub:$PATH" sh "$S" "$T/bin" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "an ELF that cannot be measured fails the whole directory" || bad "unmeasurable: rc $rc"

[ "$fails" -eq 0 ]
